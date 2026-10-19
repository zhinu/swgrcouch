-- split.lua (G4 Players & launch) - engine split-screen settings, single-view control, 2P layout switch.
-- ARCHITECTURE.md §1.6 Layout, §4.2 `split`.
--
-- Engine data (verified with scripts/reflect-types.py --class UGameMapsSettings / reflect-enum.py):
--   UGameMapsSettings CDO (/Script/EngineSettings.Default__GameMapsSettings):
--     Bool bUseSplitscreen
--     Byte<ETwoPlayerSplitScreenType>  TwoPlayerSplitscreenLayout   Horizontal=0 (top/bottom), Vertical=1 (side by side)
--     Byte<EThreePlayerSplitScreenType> ThreePlayerSplitscreenLayout FavorTop=0
--     Enum<EFourPlayerSplitScreenType> FourPlayerSplitscreenLayout  Grid=0
--     Bool bOffsetPlayerGamepadIds
--   Bytes and enums are written as integers, bools as Lua booleans [API§8].
--   GameplayStatics:SetForceDisableSplitscreen(Object WorldContextObject, Bool bDisable)
--   GameplayStatics:IsSplitscreenForceDisabled(Object WorldContextObject) -> Bool

local C        = require("consts")
local settings = require("settings")
local St       = require("state")
local U        = require("util")
local sched    = require("sched")

local M = {}
local TAG = "split"

local RACE_PHASES = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }

local function gms()
    local g = U.GMS()
    if not U.ok(g) then
        U.logOnce("split.gms", TAG, "GameMapsSettings CDO not found; split-screen settings not applied")
        return nil
    end
    return g
end

local function layout2PValue()
    if settings.get("Layout2P") == "side-by-side" then return C.E.TwoP.Vertical end
    return C.E.TwoP.Horizontal
end

local function layout2PText()
    if settings.get("Layout2P") == "side-by-side" then return "SIDE BY SIDE" end
    return "TOP / BOTTOM"
end

-- Writes the layout part of the GameMapsSettings CDO. The viewport reads the CDO whenever it lays the
-- players out, so in a race the new layout is applied at once through relayout().
function M.applyLayoutSettings()
    local g = gms()
    if not g then return false end
    g.bUseSplitscreen = true
    g.TwoPlayerSplitscreenLayout = layout2PValue()
    g.ThreePlayerSplitscreenLayout = C.E.ThreeP.FavorTop
    g.FourPlayerSplitscreenLayout = C.E.FourP.Grid
    U.log(TAG, "GameMapsSettings: bUseSplitscreen=true, 2P=%s (%d), 3P=FavorTop, 4P=Grid",
        settings.get("Layout2P"), layout2PValue())
    -- VERIFY(V-SPL-02): a CDO write is picked up live (F8 in a 2P race flips the layout).
    if U.mod("phase").isRace() then M.relayout() end
    return true
end

-- KeyboardIsP1 -> bOffsetPlayerGamepadIds: pad k drives ControllerId k+1, P1 is keyboard only.
function M.applyGamepadOffset()
    local g = gms()
    if not g then return false end
    local on = (settings.get("KeyboardIsP1") == true)
    -- VERIFY(V-SPL-03): the offset is read at input-routing time (no restart needed).
    g.bOffsetPlayerGamepadIds = on
    U.log(TAG, "GameMapsSettings: bOffsetPlayerGamepadIds=%s", tostring(on))
    return true
end

---------------------------------------------------------------------------------------------------- dormant views
-- LIVE 2026-10-16 (round 2, couch campaign, pads 3 / 4 plugged but never joined): the race showed FOUR split views
-- (4 quadrants behind the pause menu) for P1 + P2. UGameViewportClient::LayoutPlayers lays out EVERY LocalPlayer of
-- the GameInstance (the split type comes from their count, each one gets its SplitscreenInfo slot): a dormant guest
-- (a LocalPlayer kept for a plugged pad that never joined - RemovePlayer crashes, join.lua) got a view of nothing.
-- Rule: only P1 and the JOINED guests hold a view, in every race and every split layout.
--   * no joined guest (dormant PCs only): the race runs on the engine's ONE view (force-disable, kept on through
--     every split request of the race flow) - no memory write; the view count is 1 for hud / gfx / pause / uxsplit /
--     subsplit, P1 keeps his own HUD (the game's belongs to the last, dormant, PC), no HUD for the dormant ones.
--   * joined guests AND dormant PCs: the engine's per-player view rect is overridden. ULocalPlayer.Origin / Size
--     (FVector2D, doubles in UE5: 0x80 / 0x90, right after the reflected ViewportClient @0x78 - the UE4SS member dump
--     and the jmap agree: ViewportClient 0x78, AspectRatioAxisConstraint 0xB8 = 0x80 + 16 + 16 + 24) are not
--     UPROPERTYs: registered as custom double properties relative to ViewportClient. LayoutPlayers writes them on a
--     player add / remove and on SetForceDisableSplitscreen (every view change goes through M.setSingleView), and
--     ULocalPlayer::GetProjectionData skips a player whose Size is 0. The joined players get the engine's default
--     SplitscreenInfo rects for THEIR count (2P top / bottom or side by side, 3P favour top, 4P grid), a dormant one
--     Size 0. TRUST: before the first write every player's four values must read back as the engine's default layout
--     for the current player count (else the offsets are wrong: nothing is ever written, WARN once). A layout the
--     engine puts back every tick (a per-frame LayoutPlayers) stops the override (WARN): never a fight per frame.
-- cfg.SplitDormantViews = false: the old behaviour (every local player gets a view).
local VIEW_REL = { ox = 8, oy = 16, sx = 24, sy = 32 }       -- bytes after ULocalPlayer.ViewportClient
local VIEW_NAME = { ox = "SWGRCouch_LpOriginX", oy = "SWGRCouch_LpOriginY", sx = "SWGRCouch_LpSizeX",
                    sy = "SWGRCouch_LpSizeY" }
local VIEW_KEYS = { "ox", "oy", "sx", "sy" }
local V = { reg = nil, bad = nil, want = false, solo = false, trusted = false, fixTicks = 0, fixes = 0, fight = false,
            logged = nil }
M._V = V                                                      -- tests

local function cfgOpt(k, d)
    local ok, cfg = pcall(require, "config")
    if not (ok and type(cfg) == "table") or cfg[k] == nil then return d end
    return cfg[k]
end

local function dormantOn()
    local ok, cfg = pcall(require, "config")
    return not (ok and type(cfg) == "table" and cfg.SplitDormantViews == false)
end

-- pure: the engine's default SplitscreenInfo rects for n views ({ox, oy, sx, sy} per view, in view order)
function M.layoutRects(n, side)
    if n <= 1 then return { { ox = 0, oy = 0, sx = 1, sy = 1 } } end
    if n == 2 then
        if side then return { { ox = 0, oy = 0, sx = 0.5, sy = 1 }, { ox = 0.5, oy = 0, sx = 0.5, sy = 1 } } end
        return { { ox = 0, oy = 0, sx = 1, sy = 0.5 }, { ox = 0, oy = 0.5, sx = 1, sy = 0.5 } }
    end
    if n == 3 then
        return { { ox = 0, oy = 0, sx = 1, sy = 0.5 }, { ox = 0, oy = 0.5, sx = 0.5, sy = 0.5 },
                 { ox = 0.5, oy = 0.5, sx = 0.5, sy = 0.5 } }
    end
    return { { ox = 0, oy = 0, sx = 0.5, sy = 0.5 }, { ox = 0.5, oy = 0, sx = 0.5, sy = 0.5 },
             { ox = 0, oy = 0.5, sx = 0.5, sy = 0.5 }, { ox = 0.5, oy = 0.5, sx = 0.5, sy = 0.5 } }
end

local function sideBySide() return settings.get("Layout2P") == "side-by-side" end

-- { views = {lp entries holding a view, LocalPlayers order}, dormant = {lp entries without one} }: P1 + the joined
-- guests (join.joinedList: their OWN PCs, whatever pad id couch.lua gave them) hold a view
function M.viewSplit()
    local lps = U.localPlayers()
    local joined = {}
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do
            if U.ok(e.pc) then joined[U.key(e.pc)] = true end
        end
    end)
    local views, dormant = {}, {}
    for _, lp in ipairs(lps) do
        if lp.index == 1 or (U.ok(lp.pc) and joined[U.key(lp.pc)]) then views[#views + 1] = lp
        else dormant[#dormant + 1] = lp end
    end
    return { views = views, dormant = dormant }
end

-- a local PlayerController that holds NO view in this race (a dormant guest's): hud.lua makes no HUD for it
function M.noView(pc)
    if not U.ok(pc) or not U.mod("phase").isRace() then return false end
    if not (V.want or V.solo) then return false end
    local k = U.key(pc)
    for _, lp in ipairs(M.viewSplit().dormant) do
        if U.ok(lp.pc) and U.key(lp.pc) == k then return true end
    end
    return false
end

-- the number of views the race shows when split (P1 + joined guests while dormant PCs are hidden)
function M.viewCount()
    if St.race.singleView == true or V.solo then return 1 end
    -- live 2026-10-16 r3: an override that is off (bad offsets, per-frame layout) leaves EVERY player's view on
    -- screen: the count must say so (HUD / subtitle sizes followed 2 views over 4 quadrants)
    if V.want and not (V.bad or V.fight) then return #M.viewSplit().views end
    return #U.localPlayers()
end

-- lp.index -> {fw, fh} for the players holding a view while the override is on (nil = the engine's default layout)
function M.viewFractions()
    if V.solo then return { [1] = { fw = 1, fh = 1 } } end
    if not V.want or V.bad or V.fight then return nil end
    local vs = M.viewSplit()
    local rects = M.layoutRects(#vs.views, sideBySide())
    local out = {}
    for i, lp in ipairs(vs.views) do
        local r = rects[i]
        if r then out[lp.index] = { fw = r.sx, fh = r.sy } end
    end
    return out
end

-- a registered field's raw value <-> a double (V.bits: the field is an Int64Property holding the double's bits)
function M.fromRaw(v)
    if not V.bits or type(v) ~= "number" then return v end
    local ok, d = pcall(function() return (string.unpack("<d", string.pack("<i8", math.tointeger(v) or 0))) end)
    return ok and d or nil
end
function M.toRaw(d)
    if not V.bits then return d end
    return (string.unpack("<i8", string.pack("<d", d)))
end

local function regViewProps()
    if V.reg ~= nil then return V.reg end
    V.reg = false
    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        V.bad = "RegisterCustomProperty / PropertyTypes not available"
        return false
    end
    -- live 2026-10-16 round 3: this UE4SS build has no PropertyTypes.DoubleProperty: the doubles are registered as
    -- Int64Property and converted bit for bit (V.bits) with string.pack / unpack
    local dbl = PropertyTypes.DoubleProperty
    V.bits = false
    if dbl == nil then
        dbl = PropertyTypes.Int64Property
        V.bits = true
        if dbl == nil then V.bad = "PropertyTypes.DoubleProperty / Int64Property not available"; return false end
    end
    for _, k in ipairs(VIEW_KEYS) do
        local ok, e = pcall(RegisterCustomProperty, { Name = VIEW_NAME[k], Type = dbl,
            BelongsToClass = "/Script/Engine.LocalPlayer",
            OffsetInternal = { Property = "ViewportClient", RelativeOffset = VIEW_REL[k] } })
        if not ok then V.bad = "RegisterCustomProperty " .. VIEW_NAME[k] .. ": " .. tostring(e); return false end
    end
    V.reg = true
    U.log(TAG, "view rect fields registered (ULocalPlayer Origin / Size = ViewportClient + 8 / 24, doubles%s)",
        V.bits and " through int64 bits" or "")
    return true
end

M._regViewProps = regViewProps                               -- tests

-- {ox, oy, sx, sy} of a local player entry's ULocalPlayer (e.lp), nil when any value is not a plausible fraction
local function readRect(e)
    local lp = e and e.lp
    if not U.ok(lp) then return nil end
    local r = {}
    for _, k in ipairs(VIEW_KEYS) do
        local ok, v = pcall(function() return M.fromRaw(lp[VIEW_NAME[k]]) end)
        if not ok or type(v) ~= "number" or v ~= v or v < -1e-6 or v > 1 + 1e-6 then return nil end
        r[k] = v
    end
    return r
end
M._readRect = readRect

local function sameRect(a, b)
    if not (a and b) then return false end
    for _, k in ipairs(VIEW_KEYS) do if math.abs((a[k] or -1) - (b[k] or -1)) > 1e-3 then return false end end
    return true
end
local ZERO = { ox = 0, oy = 0, sx = 0, sy = 0 }

-- the target rect of every LocalPlayer (by lp.index) for the current view split
local function targets(vs)
    local rects = M.layoutRects(#vs.views, sideBySide())
    local t = {}
    for i, lp in ipairs(vs.views) do t[lp.index] = rects[i] end
    for _, lp in ipairs(vs.dormant) do t[lp.index] = ZERO end
    return t
end

-- live 2026-10-16 round 3: the engine lays the views out EVERY tick here (the rect override was undone 15 ticks in a
-- row), so the primary way is the engine's own clamp: UGameViewportClient.MaxSplitscreenPlayers (a UPROPERTY, 4).
-- LayoutPlayers uses min(local players, max) for the split type and gives every player past that count a zero size,
-- so with the dormant PCs AFTER the joined players (join order) max = #views hides exactly them, every frame, with no
-- memory write. The original value is put back at every race decision and when the race is left.
local function viewport()
    local gv = nil
    pcall(function()
        local e = FindFirstOf("GameEngine")
        if U.ok(e) then gv = e.GameViewport end
    end)
    if not U.ok(gv) then pcall(function() gv = FindFirstOf("GameViewportClient") end) end
    return U.ok(gv) and gv or nil
end

function M.restoreMaxPlayers(why)
    if V.maxOrig == nil then return end
    local gv = viewport()
    local orig = V.maxOrig
    V.maxOrig, V.clamped = nil, false
    if gv then pcall(function() gv.MaxSplitscreenPlayers = orig end) end
    U.log(TAG, "MaxSplitscreenPlayers back to %d (%s)", orig, tostring(why))
end

-- -> true when the clamp hides the dormant players (they all come after the view players)
local function clampMaxPlayers(vs, why)
    if cfgOpt("SplitDormantClamp", false) ~= true then return false end
    local lastView = 0
    for _, lp in ipairs(vs.views) do lastView = math.max(lastView, lp.index) end
    for _, lp in ipairs(vs.dormant) do if lp.index < lastView then return false end end
    local gv = viewport()
    if not gv then return false end
    local cur = nil
    pcall(function() cur = gv.MaxSplitscreenPlayers end)
    if type(cur) ~= "number" then return false end
    local want = #vs.views
    if cur == want then V.clamped = true; return true end
    if V.maxOrig == nil then V.maxOrig = cur end
    local ok = pcall(function() gv.MaxSplitscreenPlayers = want end)
    local back = nil
    pcall(function() back = gv.MaxSplitscreenPlayers end)
    if not ok or back ~= want then return false end
    V.clamped = true
    local d = {}
    for _, lp in ipairs(vs.dormant) do d[#d + 1] = "P" .. lp.index end
    U.log(TAG, "race views: %d view(s) for P1 + the joined guests, dormant %s without a view (MaxSplitscreenPlayers %d -> %d, %s)",
        want, table.concat(d, ","), V.maxOrig, want, tostring(why))
    return true
end

-- apply the override now (split views on, joined + dormant players). -> number of players rewritten, or nil
function M.applyViews(why)
    if not V.want or V.bad or V.fight then return nil end
    if not U.mod("phase").isRace() or M.isSingleView() then return nil end
    if V.clamped or clampMaxPlayers(M.viewSplit(), why) then return 0 end
    if not regViewProps() then
        U.warn(TAG, "dormant views: %s - every local player keeps a view", tostring(V.bad))
        return nil
    end
    local vs = M.viewSplit()
    local lps = U.localPlayers()
    local want = targets(vs)
    local cur = {}
    for _, lp in ipairs(lps) do cur[lp.index] = readRect(lp) end
    if not V.trusted then
        -- the engine's default layout for ALL local players (or our own layout, after a hot reload)
        -- (or the one-view layout: a LayoutPlayers that runs on the next frame instead of inside the call)
        local def = M.layoutRects(#lps, sideBySide())
        local engine, ours, one = true, true, true
        for i, lp in ipairs(lps) do
            if not sameRect(cur[lp.index], def[i] or ZERO) then engine = false end
            if not sameRect(cur[lp.index], want[lp.index]) then ours = false end
            if not sameRect(cur[lp.index], (i == 1) and M.layoutRects(1)[1] or ZERO) then one = false end
        end
        if not (engine or ours or one) then
            local got = {}
            for _, lp in ipairs(lps) do
                local r = cur[lp.index]
                got[#got + 1] = r and string.format("P%d %.2f,%.2f %.2fx%.2f", lp.index, r.ox, r.oy, r.sx, r.sy)
                    or string.format("P%d unreadable", lp.index)
            end
            V.bad = "view rects are not the engine's layout (" .. table.concat(got, "; ") .. ")"
            U.warn(TAG, "dormant views: %s - offsets not trusted, nothing written; every local player keeps a view",
                V.bad)
            return nil
        end
        V.trusted = true
    end
    local n = 0
    for _, lp in ipairs(lps) do
        local w = want[lp.index]
        if w and not sameRect(cur[lp.index], w) then
            local ok = pcall(function()
                for _, k in ipairs(VIEW_KEYS) do lp.lp[VIEW_NAME[k]] = M.toRaw(w[k] + 0.0) end
            end)
            if ok and sameRect(readRect(lp), w) then
                n = n + 1
            else
                V.bad = string.format("P%d's view rect did not take the write", lp.index)
                U.warn(TAG, "dormant views: %s - override off", V.bad)
                return nil
            end
        end
    end
    if n > 0 then
        local key = string.format("%d/%d", #vs.views, #vs.dormant)
        if V.logged ~= key then
            V.logged = key
            local d = {}
            for _, lp in ipairs(vs.dormant) do d[#d + 1] = "P" .. lp.index end
            U.log(TAG, "race views: %d view(s) for P1 + the joined guests, dormant %s without a view (%s)", #vs.views,
                table.concat(d, ","), tostring(why))
        end
    end
    return n
end

-- FAST loop, race phases (main.lua): the override back when the engine re-laid the views out (a player added /
-- removed); the engine re-laying them every tick = a per-frame layout: the override stops (no fight per frame)
function M.viewTick()
    if not V.want or V.bad or V.fight then return end
    local now = St.nowMs()
    if now - (V.tickAt or -1e12) < 90 then return end
    V.tickAt = now
    local n = M.applyViews("view tick")
    if n and n > 0 then
        V.fixTicks = V.fixTicks + 1
        V.fixes = V.fixes + 1
        if V.fixTicks >= 15 then
            V.fight = true
            U.warn(TAG, "dormant views: the engine lays the views out again every tick (%d in a row): override off, "
                .. "every local player keeps a view", V.fixTicks)
        end
    elseif n == 0 then
        V.fixTicks = 0
    end
end

-- race_enter (before every "phase" listener): the view decision of this race
function M.raceViews(new, from)
    M.restoreMaxPlayers("race decision")
    V.want, V.solo, V.trusted, V.fixTicks, V.fight, V.logged, V.clamped = false, false, false, 0, false, nil, false
    if not dormantOn() or St.race.singleView == true then return end
    local vs = M.viewSplit()
    if #vs.dormant == 0 then return end
    local d = {}
    for _, lp in ipairs(vs.dormant) do d[#d + 1] = "P" .. lp.index end
    if #vs.views <= 1 then
        -- the engine's one view (force-disable) for the whole race: every SetForceDisableSplitscreen(false) of the
        -- race flow stays one view. NOT St.race.singleView: that also stops hud.lua's P1 HUD (the game's own HUD
        -- belongs to the LAST local PC - a dormant one with no car - so P1's owner-based HUD parts need his clone)
        V.solo = true
        U.log(TAG, "race (from %s): no joined guest, %d dormant local player(s) (%s): ONE view, P1's", tostring(from),
            #vs.dormant, table.concat(d, ","))
        return
    end
    V.want = true
    U.log(TAG, "race (from %s): %d joined player(s) hold a view, %d dormant local player(s) (%s) get none", tostring(from),
        #vs.views, #vs.dormant, table.concat(d, ","))
end

-- on = true: one full-screen view whatever the number of local players.
function M.setSingleView(on)
    local world = U.world()
    if not U.ok(world) then return false end
    if V.solo and on ~= true and U.mod("phase").isRace() then on = true end   -- dormant PCs only: P1's view alone
    U.GS():SetForceDisableSplitscreen(world, on == true)
    U.dbg(TAG, "SetForceDisableSplitscreen(%s)", tostring(on == true))
    -- the engine just laid every LocalPlayer out again: the dormant players' views go at once (same frame)
    if on ~= true and V.want then U.try(TAG, M.applyViews, "split on") end
    return true
end

function M.isSingleView()
    local world = U.world()
    if not U.ok(world) then return false end
    return U.GS():IsSplitscreenForceDisabled(world) == true
end

-- present.lua's layout decision for the current race-flow state: true = one full-screen view (intro, cinematics,
-- results), false = split, nil = present.lua off / no known state (the old behaviour: split).
local function presentWantsSingle()
    local ok, present = pcall(U.mod, "present")
    if not ok or type(present) ~= "table" or type(present.decide) ~= "function" then return nil end
    local cfg = require("config")
    if cfg.PresentViewMode == "split" then return nil end
    local okD, view = pcall(present.decide)
    if not okD or view == nil then return nil end
    return view == "single"
end

-- Listener: entering a race world. Split views come on (the engine lays them out from the CDO) - except while
-- present.lua wants the race-flow state on one view (LoadingPhase/intro): then the race starts on ONE view and
-- present.tick splits it at the ignition/countdown (no one-frame split at LOADING).
function M.enterRace()
    if St.race.singleView == true then
        -- join's "race_enter" guard handed the guests' cars to the AI (race not launched by the mod): one view
        M.setSingleView(true)
        St.race.localViews = 1
        U.log(TAG, "race: single view (guests handed to the AI)")
        return
    end
    St.race.localViews = M.viewCount()
    -- At LOADING the race-flow CSM assets are usually not in memory yet: presentWantsSingle() is nil (unknown). With
    -- PresentViewMode "auto" an unknown state counts as ONE view (the intro must not start split); present.viewTick
    -- splits at the ignition/countdown, or by its safety net once the race started.
    local want = presentWantsSingle()
    local auto = false
    pcall(function()
        local present = U.mod("present")
        auto = require("config").PresentViewMode ~= "split" and type(present) == "table"
            and type(present.decide) == "function"
    end)
    local single = (St.race.localViews > 1) and (want == true or (want == nil and auto))
    M.setSingleView(single)
    if St.race.localViews > 1 and auto then
        pcall(function()
            U.mod("present").noteView(single and "single" or "split",
                want == nil and "LOADING: race-flow state not known yet" or "LOADING")
        end)
    end
    -- VERIFY(V-SPL-01): 2 local players -> 2 views in the configured 2P layout (from the ignition/countdown on when
    -- present.lua runs the intro on one view).
    U.log(TAG, "race: %d local view(s), 2P layout %s, %s", St.race.localViews, layout2PText(),
        single and "ONE view until the race-flow splits it (present.lua)" or "split views on")
end

-- Listener: phase -> FRONTEND. One view while (dormant or joined) guests exist in the menus.
function M.enterFrontEnd()
    M.setSingleView(true)
end

-- Guests now live through the whole front-end visit, also on the game's own tabs (join.lua GUEST LIFECYCLE): the
-- front end must never show their views. Called by join (session closed / guests kept) and on every "players"
-- event; a write only when the flag is actually off, so it is cheap to call often.
function M.frontEndSingleView(why)
    if not U.mod("phase").isFrontEnd() then return false end
    local world = U.world()
    if not U.ok(world) then return false end
    if U.GS():IsSplitscreenForceDisabled(world) == true then return true end
    U.GS():SetForceDisableSplitscreen(world, true)
    U.log(TAG, "front end: split screen was not force-disabled (%s); one view restored", tostring(why))
    return true
end

-- Re-run the viewport layout: force-disable on, then off one frame later (a flip inside a single
-- frame might be coalesced by the viewport). Without EngineTick the 0 ms fallback would run on the next ProcessEvent,
-- normally in the same frame: sched.nextFrame then waits RELAYOUT_FALLBACK_MS (a few frames) instead.
-- VERIFY(V-SPL-02): F8 / the lobby layout row visibly changes the 2P layout in a race (also with EngineTick off).
local RELAYOUT_FALLBACK_MS = 50
function M.relayout()
    if not U.mod("phase").isRace() or St.race.singleView == true then return end
    M.setSingleView(true)
    sched.nextFrame("split", function()
        if not U.mod("phase").isRace() then return end
        -- present.lua keeps intro/cinematic/results phases on one view: do not split those
        local keepSingle = false
        pcall(function() keepSingle = U.mod("present").isSingleView() == true end)
        M.setSingleView(keepSingle)
    end, RELAYOUT_FALLBACK_MS)
end

-- F8 and the Lobby's layout row: flip the 2P layout, persist it, apply it live.
function M.toggle2PLayout()
    settings.cycle("Layout2P", { "top-bottom", "side-by-side" })
    M.applyLayoutSettings()
    St.emit("status", "2P LAYOUT: " .. layout2PText())
end

-- Runs on the game thread at boot (main: sched.run("boot", split.init)): CDO writes + phase listeners.
function M.init()
    M.applyLayoutSettings()
    M.applyGamepadOffset()
    -- before every "phase" listener of the race's first phase (hud, pause, gfx read St.race.singleView there)
    St.on("race_enter", TAG, function(new, from) U.try(TAG, M.raceViews, new, from) end)
    St.on("phase", TAG, function(new, old)
        -- Any first race phase counts as "entering the race": the MAIN poll may skip LOADING when the
        -- grid already exists on its first look at the new world.
        if RACE_PHASES[new] and not RACE_PHASES[old] then
            M.enterRace()
        elseif new == "FRONTEND" then
            U.try(TAG, M.restoreMaxPlayers, "front end")
            M.enterFrontEnd()
        end
    end)
    -- Results -> menu: one view from the moment the race is left. The force-disable flag lives on the game viewport
    -- client (it outlives the world), so the transition map and the front-end scene are not drawn once per guest
    -- (with arbitrary guest cameras) until phase.tick sees the front end. Emitted on the game thread (hook or poll).
    St.on("leaving", TAG, function()
        U.try(TAG, M.restoreMaxPlayers, "race left")
        M.setSingleView(true)
    end)
    -- net's servertravel watchdog restored the race phase (phase.cancelLeaving): split views back, unless this race
    -- runs single-view by design (join's race_enter guard handed the guests to the AI).
    St.on("leaving_cancelled", TAG, function()
        local keepSingle = St.race.singleView == true
        if not keepSingle then pcall(function() keepSingle = U.mod("present").isSingleView() == true end) end
        M.setSingleView(keepSingle)
    end)
    -- guest set changed (join open/close/commit, a pad joined or left): in the front end, keep one view
    St.on("players", TAG, function()
        U.try(TAG, M.frontEndSingleView, "players")
    end)
end

return M
