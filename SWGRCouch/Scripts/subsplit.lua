-- SWGRCouch · subsplit.lua (G5, 0.7.2): every subtitle / radio-chatter line shows in the half of the player it is meant
-- for. Run I (live-run-I-facts.md): "BIDDY BLAS [Huttese]: *laughs* Who taught you to race?" and "ARY QUILL: *screams*"
-- showed near the top of P2's (lower) half whoever they were for. Research (static only): notes/research/subtitles-split.md.
-- The game keeps ONE subtitle widget per race world: FuseDialogueManagerSubsystem.SubtitlesWidget (WBP_Subtitles_C),
-- created with the GameInstance as owner (= P1) and added to the WHOLE window; the race config "InEvent" puts the box
-- 450 slate units above the window bottom (y 630 of 1080) for every line.
--
-- ARMED while a split race runs (uxsplit's conditions: PRERACE / RACING, >= 2 local players, not St.race.singleView) and
-- the widget exists (looked up again every MAIN tick until the manager made it; never FindAllOf). DISARMED on POSTRACE
-- (transform reset, clones removed), "leaving" (quiet: only the hooks, BEFORE the map changes), every other non-race
-- phase, or < 2 local players. UxSplitSubtitles "log" = attribution + log lines only; "off" = nothing at all.
-- 1. POSTER: every Blueprint request is preceded by GetWorldSubsystem(self, FuseDialogueTrigger|ManagerSubsystem) in the
--    same Blueprint frame (BP_FuseVehicleNarrativeComponent_C on every pod, the race-flow CsmAction for the intro). A
--    PRE-only hook keeps that context object (class address compare only: every Blueprint's world-subsystem lookup goes
--    through it) and the next request consumes it: narrative component -> its car (.Pawn) -> controller -> local player;
--    an AI car -> the nearest local human car within UxSplitSubAiRadiusUU (else P1, the Blueprint's player 0); a
--    CsmAction -> everybody; a widget of one of hud.lua's HUDs -> that HUD's player (else everybody).
--    cfg.UxSplitSubPosterHook = false (0.8.0) leaves this hook out: requests then have no poster (6 hooks).
-- 2. REQUESTS: RequestTrigger[Delayed] / RequestEvent[Delayed] PRE-hooks add pending entries {trigger or event,
--    character, due time, player}. Rules (C.SUB_RULES, else the copy below): "both" triggers (race start, eliminations,
--    sabotage, introductions...) are for everybody, a non-delayed RequestEvent (the race intro) too; the "involved"
--    ability hits go to the hitter (PlayerHits) / the hit player (HitsPlayer), read by the optional
--    OnPlayerHitTargetWithAbility hook (UxSplitSubAbilityHook); everything else goes to the poster.
-- 3. LINE: WBP_Subtitles' OnSubtitleUpdated(true) ends with UpdateFromConfig -> UIManager:GetCurrentSubtitleConfig(), in
--    the frame the line appears. Its POST-hook (UxSplitSubDetect "hook") reads the line (widget text, GetCurrentEvent,
--    GetCurrentLineCharacter) and the config (Padding.Bottom = pad, alignment), then decides: the next line of the same
--    event (< 1.5 s later) keeps its player(s); else the matching pending request (the latest due one; two players'
--    requests due within 150 ms = both); else a "both" rule read from the event tag; else the speaker's car
--    (SubtitleSceneComponent's owner); else UxSplitSubUnmatched. The FAST poll of the widget text is the fallback
--    ("poll" = the only path, 1-2 frames late).
-- 4. PLACEMENT: render transform (pivot, scale, translation) of the game widget, which neither its Blueprint nor the
--    manager ever writes; never its visibility (the manager rewrites it), never AddToPlayerScreen (UpdateFromConfig
--    writes pad 450 at every line). The box's bottom centre moves to the same relative height in the player's view
--    (UxSplitSubHalfFrac, "auto" = pad / window height); half-width views scale it by UxSplitSubSideScale. A line for
--    everybody: the game widget in P1's view and one mod-made WBP_Subtitles per guest (owned by the guest, added to the
--    viewport at the game widget's z, fed the same text / speaker / language; its own Tick fades it on pause)
--    (UxSplitSubBoth "clone"), or the game's place ("game"). One full-screen view (present.lua): the game's place.
-- Audio stays shared (one voice line for both players, shared trigger cooldowns: a bark can suppress the other's).
-- HOOK RULES (uxsplit's, run H crash): raw RegisterHook only while armed, UnregisterHook-ed when disarming; ids in
-- _G.SWGRCouch_subsplit_hooks (a re-require in the same Lua state never double-registers), flags in
-- _G.SWGRCouch_subsplit_flags (the previous load's go off); every callback checks its flag first, runs in pcall, counts
-- and returns nil (no return override). No hook on a function carrying dialogue-line data and no read of
-- CharacterDef.MainIcon / NPCActor (soft pointers); every kept wrapper gets U.ok() first; no FindAllOf / FindFirstOf.
-- testcmd: `lua return require("subsplit").testLine(2, "VO.ML.Rager.Trigger.PlayerCrashes.Racer")` (0 = everybody),
-- `lua return require("subsplit").status()`. VERIFY ids: V-SUB-00..08 (subtitles-split.md §5); the probe line follows
-- cfg.UxSplitProbeMs. The radio portrait (V-SUB-09, UxSplitGuestHolo "route") is not built: hud.lua keeps hiding it in
-- guest HUDs (V-UX-12).

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "subsplit"

local fmt, floor, abs, min, max = string.format, math.floor, math.abs, math.min, math.max
local sfind, ssub = string.find, string.sub

---------------------------------------------------------------------------------------------------- options
-- config.lua may not list these keys yet: a missing key, a value of another type or outside its list gives the default.
local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local function pick(k, allowed, d)
    local v = cfg[k]
    for _, a in ipairs(allowed) do if v == a then return v end end
    return d
end

local function positive(k, d)
    local v = cfg[k]
    if type(v) == "number" and v > 0 then return v end
    return d
end

local function subMode() return pick("UxSplitSubtitles", { "route", "log", "off" }, "route") end
local function detectMode() return pick("UxSplitSubDetect", { "hook", "poll" }, "hook") end
local function bothMode() return pick("UxSplitSubBoth", { "clone", "game" }, "clone") end
local function unmatchedMode() return pick("UxSplitSubUnmatched", { "both", "p1" }, "both") end
local function abilityHookOn() return opt("UxSplitSubAbilityHook", true) end
-- integration 0.8.0 (review): the engine-wide GetWorldSubsystem pre-hook gets its own switch (run-H rule: one cfg switch
-- per hook family). Off: requests have no poster; lines go by the both-rules, ability hits, the speaker's car and
-- UxSplitSubUnmatched; placement and clones are unchanged (6 hooks instead of 7).
local function posterHookOn() return opt("UxSplitSubPosterHook", true) end
local function pendingMs() return positive("UxSplitSubPendingMs", 8000) end
local function aiRadius() return positive("UxSplitSubAiRadiusUU", 10000) end
local function sideScale() return min(positive("UxSplitSubSideScale", 0.75), 1.0) end
-- "auto" (pad / window height: the box sits at the single-view ratio of the view's height) or 0..1 of the view height
local function halfFrac()
    local v = cfg.UxSplitSubHalfFrac
    if type(v) == "number" and v >= 0 and v <= 1 then return v end
    return "auto"
end
local function probeMs() return tonumber(cfg.UxSplitProbeMs) or 0 end   -- uxsplit's probe period (0 = off)

local EARLY_MS = 150           -- a line may start this long before its request's due time (frame / clock jitter)
local TIE_MS = 150             -- two players' requests for one line due this close together: the line is for both
local CONT_MS = 1500           -- the same event this soon after the previous line (CommsPadding 0.71 s): same player(s)
local PENDING_MAX = 64         -- pending requests kept (the oldest is dropped)
local H_NAMES = { [0] = "Fill", "Left", "Center", "Right" }       -- EHorizontalAlignment
local V_NAMES = { [0] = "Fill", "Top", "Center", "Bottom" }       -- EVerticalAlignment
local H_CENTER, V_BOTTOM = 2, 3

-- Native objects (reflection dump + work/script-objects.tsv; subtitles-split.md §1.2).
local PATH = {
    WSS = "/Script/Engine.SubsystemBlueprintLibrary:GetWorldSubsystem",
    ReqTrig = "/Script/Griffin.FuseDialogueTriggerSubsystem:RequestTrigger",
    ReqTrigD = "/Script/Griffin.FuseDialogueTriggerSubsystem:RequestTriggerDelayed",
    ReqEv = "/Script/Griffin.FuseDialogueManagerSubsystem:RequestEvent",
    ReqEvD = "/Script/Griffin.FuseDialogueManagerSubsystem:RequestEventDelayed",
    SubCfg = "/Script/Griffin.UIManager:GetCurrentSubtitleConfig",
    AHit = "/Script/Griffin.VehicleNarrativeComponent:OnPlayerHitTargetWithAbility",
    TrigSub = "/Script/Griffin.FuseDialogueTriggerSubsystem",
    MgrSub = "/Script/Griffin.FuseDialogueManagerSubsystem",
    Narr = "/Script/Griffin.VehicleNarrativeComponent",
    Csm = "/Script/Griffin.CsmAction",
    Subs = "/Script/Griffin.Subtitles",
    Widget = "/Script/UMG.Widget",
    GVS = "/Script/UMG.GameViewportSubsystem",
    WLL = "/Script/UMG.Default__WidgetLayoutLibrary",
}

-- Trigger rules (subtitles-split.md §2.2): suffixes after "Trigger.", prefix match ("Sabotage" covers
-- "Sabotage.PlayerSabotaged"). consts.lua may define C.SUB_RULES = {both = {...}, involved = {...}} instead.
local RULES = (type(C.SUB_RULES) == "table" and C.SUB_RULES) or {
    both = { "RaceStart", "NemesisFinishes", "RacerEliminated", "AnnounceRacerEliminated", "AnnounceInvasion",
             "IntroduceEvent", "IntroduceHazard", "FinalEliminator", "RaceFinished", "Sabotage" },
    involved = { "Ability.PlayerHits", "Ability.HitsPlayer", "Vent.PlayerHits", "Vent.HitsPlayer" },
}

---------------------------------------------------------------------------------------------------- state (St.subsplit)
local function counters()
    return { wss = 0, wssDlg = 0, req = 0, reqP = {}, reqAI = 0, reqUnknown = 0, pairs = 0, lines = 0, linesP = {},
             linesBoth = 0, unmatched = 0, late = 0, cfgCalls = 0, cfgSame = 0, ahit = 0, placed = 0, clones = 0,
             cbErrors = 0 }
end

-- Plain data (testcmd `lua`, diag): St.subsplit.armed, .why, .n.<counter>, .last (the last line's log text), .widget,
-- .hooks.
local S = { armed = false, why = "never armed", since = 0, arms = 0, hooks = {}, n = counters(), last = "", widget = "" }
St.subsplit = S

-- Family flags, read first by every callback: poster (GetWorldSubsystem), req (the four requests), line (the config
-- post-hook), ahit (ability hits).
local A = { on = false, poster = false, req = false, line = false, ahit = false }
do
    -- a previous load of this file in the same Lua state: its callbacks see their flags go off at once
    local old = _G.SWGRCouch_subsplit_flags
    if type(old) == "table" and old ~= A then
        for k in pairs(old) do old[k] = false end
    end
    _G.SWGRCouch_subsplit_flags = A
end

-- The game's objects and the line / placement state of this arm. lastSeenAt: last FAST tick (or line start) the line
-- was on screen. tf / tfSet: the transform written on the game widget (nil = identity).
local G = { mgr = nil, uim = nil, w = nil, wKey = 0, z = nil, W = 1920, H = 1080, dpi = 1, n = 0, side = false,
            layout = "?", conf = nil, lastText = nil, lastEv = "", lastVerdict = nil, lastSeenAt = -1e12,
            single = false, tf = nil, tfSet = false, fastAt = nil, cloneFail = {} }
local clones = {}              -- slot -> {w, key, path, slot, pcKey, tf, tfSet, showing, vis, styleKey, bgOp}
local inClone, selfCall = false, false   -- our own calls that reach the config post-hook (clone updates, askConf)
local pending = {}             -- requests waiting for their line (section "requests")
local last = nil               -- context object of the last dialogue-subsystem GetWorldSubsystem (cleared every FAST)
local forced = nil             -- {pnum = slot | "both", why} while testLine posts
local ahit = {}                -- {inst = slot, tgt = slot} per OnPlayerHitTargetWithAbility call in progress
local K = { trig = 0, mgr = 0 }   -- UClass addresses of the two dialogue subsystems (resolved when arming)
local fastN, lastProbe, probeBase = 0, -1e12, nil   -- FAST tick count; probe period start (nil: starts at the next tick)

local function cbFail(where, err)
    S.n.cbErrors = S.n.cbErrors + 1
    U.logEvery("sub.cb." .. where, 10000, TAG, "WARN callback %s failed (%d callback error(s) so far): %s", where,
        S.n.cbErrors, tostring(err))
end

local function noop() return nil end

---------------------------------------------------------------------------------------------------- hook registry
-- path -> {pre = id, post = id, owner = INSTANCE}, kept in _G (uxsplit's registry, a separate table).
local HOOKS = _G.SWGRCouch_subsplit_hooks
if type(HOOKS) ~= "table" then
    HOOKS = {}
    _G.SWGRCouch_subsplit_hooks = HOOKS
end
local INSTANCE = {}

local function onGameThread()
    local ok, v = pcall(function() return IsInGameThread() end)
    return ok and v == true
end

local function unhook(path, why)
    local h = HOOKS[path]
    if h == nil then return false end
    HOOKS[path] = nil
    S.hooks[path] = "off (" .. tostring(why) .. ")"
    local ok, e = pcall(UnregisterHook, path, h.pre, h.post or h.pre)
    if not ok then
        U.warn(TAG, "UnregisterHook(%s, %s, %s) failed: %s", path, tostring(h.pre), tostring(h.post), tostring(e))
        return false
    end
    return true
end

-- Registers pre/post on a native UFunction once; post = nil: PRE-only (no Lua post call at all). True when in place.
local function hook(path, pre, post)
    local h = HOOKS[path]
    if h ~= nil and h.owner == INSTANCE then return true end
    if h ~= nil then unhook(path, "stale registration of an earlier load") end
    local okF, fn = pcall(StaticFindObject, path)
    if not okF or not U.ok(fn) then
        S.hooks[path] = "missing"
        U.warn(TAG, "hook %s: UFunction not found; that part stays off", path)
        return false
    end
    local ok, preId, postId
    if post == nil then
        ok, preId, postId = pcall(RegisterHook, path, pre)
    else
        ok, preId, postId = pcall(RegisterHook, path, pre, post)
    end
    if not ok or type(preId) ~= "number" then
        S.hooks[path] = "failed: " .. tostring(preId)
        U.err(TAG, "RegisterHook(%s) failed: %s; that part stays off", path, tostring(preId))
        return false
    end
    HOOKS[path] = { pre = preId, post = postId, owner = INSTANCE }
    local only = (post == nil) and ", pre only" or ""
    S.hooks[path] = fmt("on (ids %s/%s%s)", tostring(preId), tostring(postId), only)
    U.log(TAG, "hook on: %s (ids %s/%s%s)", path, tostring(preId), tostring(postId), only)
    return true
end

-- Every registration in the table (this load's and stale ones). Game thread only (UnregisterHook finds the UFunction).
local function unhookAll(why)
    if not onGameThread() then return 0 end
    local paths = {}
    for p in pairs(HOOKS) do paths[#paths + 1] = p end
    local n = 0
    for _, p in ipairs(paths) do
        if unhook(p, why) then n = n + 1 end
    end
    return n
end

local function hookCount()
    local n = 0
    for _, h in pairs(HOOKS) do if h.owner == INSTANCE then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------------------------------- players (MAIN cache)
-- Slot = GameInstance.LocalPlayers index = the split view the engine gives that player (split.lua: P1 top / left).
-- Callbacks only compare ADDRESSES with these maps (byPc / byCar / byPs -> slot, roots = hud.lua HUD widget -> slot);
-- the kept car wrappers (distances) get U.ok() before any use.
local L = { slots = {}, byPc = {}, byCar = {}, byPs = {}, roots = {} }

local function refreshRoots(byPc)
    local roots = {}
    local h = St.hud
    if type(h) == "table" and type(h.guests) == "table" then        -- hud.lua: guests[pcKey] = {pc, widget, pnum}
        for pcKey, e in pairs(h.guests) do
            local p = byPc[pcKey]
            if p and type(e) == "table" then
                local k = U.key(e.widget)
                if k ~= 0 then roots[k] = p end
            end
        end
    end
    return roots
end

local function refreshPlayers()
    local slots, byPc, byCar, byPs = {}, {}, {}, {}
    local tko
    pcall(function() tko = U.mod("takeover") end)
    local split = nil
    pcall(function() split = U.mod("split") end)
    local vf = nil                                      -- couch-livefix r2: the joined players' view order
    if type(split) == "table" and type(split.viewFractions) == "function" then pcall(function() vf = split.viewFractions() end) end
    local vslot = 0
    for _, lp in ipairs(U.localPlayersRO()) do
        local e = { slot = floor(tonumber(lp.index) or (#slots + 1)), pc = lp.pc, pcKey = U.key(lp.pc) }
        if type(vf) == "table" then
            if vf[lp.index] then vslot = vslot + 1; e.slot = vslot else e.pcKey, e.noView = 0, true end   -- dormant: no slot
        end
        if e.pcKey ~= 0 then
            byPc[e.pcKey] = e.slot
            local car, ps, cps
            pcall(function() car = lp.pc.Pawn end)
            if U.isVehicle(car) then
                e.car, e.carKey = car, U.key(car)
                byCar[e.carKey] = e.slot
                pcall(function() cps = car.PlayerState end)
                if U.ok(cps) then byPs[U.key(cps)] = e.slot end
            end
            pcall(function() ps = lp.pc.PlayerState end)
            if U.ok(ps) then byPs[U.key(ps)] = e.slot end
            if type(tko) == "table" and type(tko.racerPSFor) == "function" then
                local okR, rps = pcall(tko.racerPSFor, lp.pc)   -- the racer state a guest drives with (takeover)
                if okR and U.ok(rps) then byPs[U.key(rps)] = e.slot end
            end
        end
        if not e.noView then slots[#slots + 1] = e end
    end
    L.slots, L.byPc, L.byCar, L.byPs, L.roots = slots, byPc, byCar, byPs, refreshRoots(byPc)
end

---------------------------------------------------------------------------------------------------- posters
-- Class kind cache (class address -> {kind, name}), emptied per race (addresses repeat once a map's classes unload):
-- "narr" (a pod's narrative component), "subs" (a subtitle widget building its own text: never a poster), "csm" (a
-- race-flow state action), "widget", "other".
local KIND = {}
local function kindOf(o)
    if not U.ok(o) then return "other", "?" end   -- U.ok FIRST: GetClass on a null wrapper is a native AV (UE4SS.dll+0x2ace67 null+0x10) that pcall cannot catch
    local okC, cls = pcall(U.callMethod, o, "GetClass")
    if not okC or not U.ok(cls) then return "other", "?" end
    local ck = U.key(cls)
    local k = KIND[ck]
    if k then return k[1], k[2] end
    local name = "?"
    pcall(function() name = cls:GetFName():ToString() end)
    local kind = "other"
    if U.isA(o, PATH.Narr) then kind = "narr"
    elseif U.isA(o, PATH.Subs) then kind = "subs"
    elseif U.isA(o, PATH.Csm) then kind = "csm"
    elseif U.isA(o, PATH.Widget) then kind = "widget" end
    if ck ~= 0 then KIND[ck] = { kind, name } end
    return kind, name
end

local function slotOfCar(car)
    local k = U.key(car)
    if k == 0 then return nil end
    if L.byCar[k] then return L.byCar[k] end
    local ctrl
    pcall(function() ctrl = car.Controller end)
    local ck = U.key(ctrl)
    return (ck ~= 0) and L.byPc[ck] or nil
end

local function locOf(a)
    local ok, v = pcall(U.callMethod, a, "K2_GetActorLocation")
    if not ok or v == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z) end)
    if x and y and z then return x, y, z end
    return nil
end

-- The local human car nearest to an AI car within UxSplitSubAiRadiusUU: slot, distance (uu); nil when none.
local function nearestHuman(car)
    local x, y, z = locOf(car)
    if not x then return nil end
    local best, bestD = nil, aiRadius()
    for _, e in ipairs(L.slots) do
        if e.car and U.ok(e.car) then
            local hx, hy, hz = locOf(e.car)
            if hx then
                local d = math.sqrt((hx - x) ^ 2 + (hy - y) ^ 2 + (hz - z) ^ 2)
                if d <= bestD then best, bestD = e.slot, d end
            end
        end
    end
    if best then return best, bestD end
    return nil
end

-- A car -> its local human's slot, or (AI car) the nearest human within the radius, else P1 like the Blueprint's
-- player-0 tests. Returns slot | nil, description, ai.
local function playerOfCar(car, name)
    local p = slotOfCar(car)
    if p then return p, name .. " (car)", false end
    if not U.ok(car) then return nil, name .. " (no car)", false end
    local q, d = nearestHuman(car)
    if q then return q, fmt("%s (AI car, nearest P%s %.0f m)", name, tostring(q), d / 100), true end
    return 1, name .. " (AI car, no human within the radius: P1 like the Blueprint's player 0)", true
end

-- Poster object -> slot | "both" | nil (unknown), description, ai.
local function resolvePoster(o)
    if not U.ok(o) then return nil, "no poster", false end
    local kind, name = kindOf(o)
    if kind == "narr" then
        local car
        pcall(function() car = o.Pawn end)                       -- UVehiclePresentationComponent.Pawn
        if not U.ok(car) then pcall(function() car = o:GetOwner() end) end
        return playerOfCar(car, name)
    elseif kind == "csm" then
        return "both", name .. " (race flow)", false
    elseif kind == "widget" then
        local x = o
        for _ = 0, 8 do                                          -- member -> WidgetTree -> UserWidget (nested too)
            local k = U.key(x)
            if k == 0 then break end
            local p = L.roots[k]
            if p then return p, fmt("%s (P%s's HUD)", name, tostring(p)), false end
            local ok, nx = false, nil
            if U.ok(x) then ok, nx = pcall(U.callMethod, x, "GetOuter") end   -- null GetOuter = native AV
            if not ok or nx == nil then break end
            x = nx
        end
        return "both", name .. " (widget outside the race HUDs)", false
    end
    return nil, name .. " (unknown poster)", false
end

local function takePoster()
    local o = last
    last = nil
    if forced then return forced.pnum, forced.why, false, true end
    if o == nil then return nil, "no Blueprint poster (native)", false, false end
    local p, via, ai = resolvePoster(o)
    return p, via, ai, false
end

---------------------------------------------------------------------------------------------------- tags and rules
-- FGameplayTag (a hook param's struct, or the table a Lua call returns) -> "A.B.C"; "" for none.
local function tagOf(v)
    if v == nil then return "" end
    local ok, s = pcall(function() return v.TagName:ToString() end)
    if ok and type(s) == "string" and s ~= "None" then return s end
    return ""
end

local function prefixed(s, k)
    return s == k or ssub(s, 1, #k + 1) == k .. "."
end

-- "both" | "involved" | "poster", and the rule key that matched.
local function ruleOf(trig)
    local s = trig:match("^Trigger%.(.+)$") or trig
    for _, k in ipairs(RULES.both or {}) do if prefixed(s, k) then return "both", k end end
    for _, k in ipairs(RULES.involved or {}) do if prefixed(s, k) then return "involved", k end end
    return "poster", nil
end

-- A "both" rule read from a line's own event tag ("VO.ML.Rager.Trigger.RaceStart.Rival" -> RaceStart), or nil.
local function bothRuleOfEvent(ev)
    local s = ev:match("%.Trigger%.(.+)$")
    if not s then return nil end
    local r, k = ruleOf("Trigger." .. s)
    if r == "both" then return k end
    return nil
end

-- Request "Trigger.X" vs a line's event: ".Trigger.X" followed by "." or the end (PlayerOvertakes never matches
-- PlayerOvertakesNemesis).
local function trigInEvent(ev, trig)
    local pat = "." .. trig
    local i = 1
    while true do
        local s, e = sfind(ev, pat, i, true)
        if not s then return false end
        local nx = ssub(ev, e + 1, e + 1)
        if nx == "" or nx == "." then return true end
        i = s + 1
    end
end

local function slotName(p)
    if p == "both" then return "both" end
    if type(p) == "number" then return "P" .. tostring(p) end
    return "unknown"
end

---------------------------------------------------------------------------------------------------- requests
-- pending[i] = {trig | event, char, at, due, pnum (slot | nil), both, bothWhy, label, via, forced, used}
local function addPending(e)
    local win = pendingMs()
    local keep = {}
    for _, x in ipairs(pending) do
        if not x.used and e.at <= x.due + win then
            -- the same request from two players' components at once (a broadcast to every pod) (V-SUB-08)
            if x.label == e.label and abs(x.at - e.at) < 50 and x.pnum and e.pnum and x.pnum ~= e.pnum then
                S.n.pairs = S.n.pairs + 1
            end
            keep[#keep + 1] = x
        end
    end
    while #keep >= PENDING_MAX do table.remove(keep, 1) end
    keep[#keep + 1] = e
    pending = keep
end

-- One request seen by a PRE-hook: r = {trig | event, char, delay, intro}.
-- VERIFY(V-SUB-02): "request Trigger.PlayerCrashes char=Character.Rager delay=3.0 by BP_FuseVehicleNarrativeComponent_C
-- (car) = P2" after P2 crashes; "AI n" in the probe says whether AI pods' components post at all.
local function addRequest(r)
    local now = St.nowMs()
    local p, via, ai, isForced = takePoster()
    local label = r.trig or r.event or ""
    if label == "" then return end
    local rule, rk = "poster", nil
    if r.trig then rule, rk = ruleOf(r.trig) end
    local bothWhy = (rule == "both") and ("rule Trigger." .. tostring(rk)) or nil
    if r.intro and not isForced then rule, bothWhy = "both", "race intro (RequestEvent)" end
    if rule == "involved" and ahit[#ahit] then
        local h = ahit[#ahit]
        local hitter = sfind(r.trig, "PlayerHits", 1, true) ~= nil
        -- integration 0.8.0: an explicit choice. `hitter and h.inst or h.tgt` gave a PlayerHits line to the HIT player
        -- when the hitter's racer state was not in L.byPs (takeover state, a state change since the last MAIN tick);
        -- q = nil keeps the poster attribution.
        local q
        if hitter then q = h.inst else q = h.tgt end
        if q then p, via, ai = q, fmt("ability hit: the %s, P%s", hitter and "hitter" or "hit player", tostring(q)), false end
    end
    if p == "both" and not bothWhy then bothWhy = isForced and "forced" or tostring(via) end
    local delay = tonumber(r.delay) or 0
    local e = { trig = r.trig, event = r.event, char = r.char or "", at = now, due = now + max(delay, 0) * 1000,
                pnum = (type(p) == "number") and p or nil, both = bothWhy ~= nil, bothWhy = bothWhy, label = label,
                via = via, forced = isForced }
    addPending(e)
    local n = S.n
    n.req = n.req + 1
    if ai then n.reqAI = n.reqAI + 1 end
    if e.pnum then n.reqP[e.pnum] = (n.reqP[e.pnum] or 0) + 1 elseif not e.both then n.reqUnknown = n.reqUnknown + 1 end
    U.logEvery("sub.req." .. label .. "." .. slotName(p), 2000, TAG, "request %s char=%s delay=%.1f by %s = %s%s (V-SUB-02)",
        label, e.char ~= "" and e.char or "-", delay, tostring(via), e.both and "both" or slotName(e.pnum),
        e.both and (" (" .. tostring(bothWhy) .. ")") or "")
end

---------------------------------------------------------------------------------------------------- text and config
local function readText(w)
    local ok, s = pcall(function() return w.SubtitleText:ToString() end)   -- USubtitles.SubtitleText (Text @0x328)
    if ok and type(s) == "string" then return s end
    return ""
end

local function short(s)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    if #s > 60 then return ssub(s, 1, 57) .. "..." end
    return s
end

-- FSubtitleConfig {ConfigName, Padding (Margin), HorizontalAlignment, VerticalAlignment} (a hook's struct or the table a
-- Lua call returns) -> {name, pad, h, v}, or nil.
local function readConf(c)
    if c == nil then return nil end
    local r = {}
    local ok = pcall(function()
        r.name = c.ConfigName:ToString()
        r.pad = tonumber(c.Padding.Bottom)
        r.h = tonumber(c.HorizontalAlignment)
        r.v = tonumber(c.VerticalAlignment)
    end)
    if ok and r.pad then return r end
    return nil
end

local function confText(c)
    if not c then return "unknown" end
    return fmt("%s pad %.0f %s/%s", tostring(c.name), c.pad or -1, H_NAMES[c.h] or tostring(c.h),
        V_NAMES[c.v] or tostring(c.v))
end

local function noteConf(c)
    local old = G.conf
    G.conf = c
    if not old or old.name ~= c.name or old.pad ~= c.pad or old.h ~= c.h or old.v ~= c.v then
        U.log(TAG, "subtitle config %s (V-SUB-05)", confText(c))
    end
end

-- Our own GetCurrentSubtitleConfig call (arming; a line the config hook did not see): selfCall keeps our hook out.
local function askConf()
    local uim = G.uim
    if not U.ok(uim) then return nil end
    selfCall = true
    local ok, c = pcall(U.callMethod, uim, "GetCurrentSubtitleConfig")
    selfCall = false
    return ok and readConf(c) or nil
end

---------------------------------------------------------------------------------------------------- placement
local IDENTITY = { px = 0.5, py = 0.5, s = 1, tx = 0, ty = 0 }

local function sameTf(a, b)
    return abs(a.px - b.px) < 1e-4 and abs(a.py - b.py) < 1e-4 and abs(a.s - b.s) < 1e-4 and abs(a.tx - b.tx) < 0.5
        and abs(a.ty - b.ty) < 0.5
end

-- Writes a render transform (nil = identity) on a widget when it differs from what holder (G or a clone) wrote last.
local function setTf(holder, wd, tf)
    if not U.ok(wd) then return false end
    local t = tf or IDENTITY
    if holder.tfSet and sameTf(holder.tf or IDENTITY, t) then return true end
    local ok = pcall(function()
        wd:SetRenderTransformPivot({ X = t.px, Y = t.py })
        wd:SetRenderScale({ X = t.s, Y = t.s })
        wd:SetRenderTranslation({ X = t.tx, Y = t.ty })
    end)
    if ok then holder.tf, holder.tfSet = tf, true end
    return ok
end

-- View rectangles (fractions of the window) in GameInstance.LocalPlayers order, as the engine lays them out from
-- split.lua's GameMapsSettings: 2P top/bottom (Horizontal) or side by side (Vertical), 3P FavorTop, 4P Grid.
local function rectOf(slot, n, side)
    if n < 2 or slot < 1 or slot > n then return nil end
    if n == 2 then
        if side then return { (slot - 1) * 0.5, 0, 0.5, 1 } end
        return { 0, (slot - 1) * 0.5, 1, 0.5 }
    elseif n == 3 then
        if slot == 1 then return { 0, 0, 1, 0.5 } end
        return { (slot - 2) * 0.5, 0.5, 0.5, 0.5 }
    end
    local i = slot - 1
    return { (i % 2) * 0.5, (i // 2) * 0.5, 0.5, 0.5 }
end

-- The transform moving the box's bottom centre A = (W/2, H - pad) to B = (W(x + w/2), H(y + h) - f h H) in the slot's
-- view (f = UxSplitSubHalfFrac, "auto" = pad / H), scaled by UxSplitSubSideScale in half-width views. 1920x1080 su,
-- pad 450: top/bottom P1 (0,-315), P2 (0,+225); side by side P1 (-480,0), P2 (+480,0), x0.75. nil = the game's place.
local function tfFor(slot)
    local rect = rectOf(slot, G.n, G.side)
    local W, H, pad = G.W, G.H, G.conf and G.conf.pad
    if not rect or not (W > 0 and H > 0) or type(pad) ~= "number" or pad <= 0 or pad >= H then return nil end
    local x, y, rw, rh = rect[1], rect[2], rect[3], rect[4]
    local s = (rw >= 0.999) and 1 or sideScale()
    local f = halfFrac()
    if f == "auto" then f = pad / H end
    local ax, ay = W / 2, H - pad
    local bx, by = W * (x + rw / 2), H * (y + rh) - f * rh * H
    return { px = ax / W, py = ay / H, s = s, tx = bx - ax, ty = by - ay }
end

local function n0(x)
    local r = floor(x + 0.5)
    if r == 0 then return "0" end
    return fmt("%+.0f", r)
end

local function tfText(tf)
    if not tf then return "the game's place" end
    local s = n0(tf.tx) .. "," .. n0(tf.ty)
    if abs(tf.s - 1) > 1e-3 then s = s .. fmt(" x%.2f", tf.s) end
    return s
end

-- Window size in slate units (GetViewportSize pixels / GetViewportScale), cached by the MAIN tick.
local function refreshViewport()
    local wll, world = U.cdo(PATH.WLL), U.world()
    if not (U.ok(wll) and U.ok(world)) then return end
    local okS, sz = pcall(U.callMethod, wll, "GetViewportSize", world)
    local okD, dpi = pcall(U.callMethod, wll, "GetViewportScale", world)
    local px, py
    if okS and sz ~= nil then pcall(function() px, py = tonumber(sz.X), tonumber(sz.Y) end) end
    if not (px and py and px > 0 and py > 0) then return end
    local d = (okD and type(dpi) == "number" and dpi > 0) and dpi or 1
    G.W, G.H, G.dpi = px / d, py / d, d
end

local function refreshLayout()
    local n = min(#L.slots, 4)
    local side = false
    pcall(function() side = require("settings").get("Layout2P") == "side-by-side" end)
    G.n, G.side = n, (n == 2 and side)
    if n == 2 then G.layout = side and "side by side" or "top/bottom"
    elseif n == 3 then G.layout = "3P favor top"
    elseif n >= 4 then G.layout = "4P grid"
    else G.layout = "one view" end
end

-- The engine's flag (split.lua): present.lua runs intros / cinematics / results on ONE full-screen view.
local function isSingle()
    local ok, split = pcall(U.mod, "split")
    if ok and type(split) == "table" and type(split.isSingleView) == "function" then
        local ok2, v = pcall(split.isSingleView)
        if ok2 and type(v) == "boolean" then return v end
    end
    return false
end

---------------------------------------------------------------------------------------------------- clones
-- The game widget's viewport z-order (GameViewportSubsystem:GetWidgetSlot): the clones go on the same layer.
local function gameZ()
    if G.z ~= nil then return G.z end
    local z
    pcall(function()
        local gvs = U.SBL():GetEngineSubsystem(StaticFindObject(PATH.GVS))
        if U.ok(gvs) and U.ok(G.w) then z = tonumber(gvs:GetWidgetSlot(G.w).ZOrder) end
    end)
    G.z = z and floor(z) or nil
    return G.z
end

-- Text size (the style set the settings chose) and backer opacity of the game widget, copied when they differ.
local function syncLook(c)
    local w = G.w
    local ss, op
    pcall(function() ss = w.Txt_RichText.TextStyleSet end)
    local k = U.key(ss)
    if k ~= 0 and k ~= c.styleKey then
        pcall(function() c.w.Txt_RichText:SetTextStyleSet(ss) end)
        pcall(function() c.w.Txt_RichText_Ambient:SetTextStyleSet(ss) end)
        c.styleKey = k
    end
    pcall(function() op = w.SubtitleBackerOpacity end)
    if type(op) == "number" and op ~= c.bgOp then
        inClone = true
        pcall(function() c.w:OnBgOpacityUpdated(op) end)
        inClone = false
        c.bgOp = op
    end
end

-- The game widget's line into a clone (text, speaker, ambient flag, language; never the scene component), then the
-- clone's own Blueprint builds the text and shows its backer (OnSubtitleUpdated(true): its config call is ours).
local function fillClone(c, text)
    local w = G.w
    if not (U.ok(c.w) and U.ok(w)) then return false end
    syncLook(c)
    inClone = true
    local ok, err = pcall(function()
        local ch = w.SubtitleCharacter
        c.w.SubtitleText = w.SubtitleText
        c.w.SubtitleCharacter = U.ok(ch) and ch or nil
        c.w.IsAmbientLine = w.IsAmbientLine == true
        c.w.LanguageLabel = w.LanguageLabel
        c.w:OnSubtitleUpdated(true)
    end)
    inClone = false
    if not ok then
        U.logEvery("sub.fill", 10000, TAG, "WARN clone of P%s not filled: %s", tostring(c.slot), tostring(err))
        return false
    end
    c.showing = text
    return true
end

local function idleClone(c)
    if c.showing == nil then return end
    c.showing = nil
    if not U.ok(c.w) then return end
    inClone = true
    pcall(function()
        c.w.SubtitleText = FText("")
        c.w.SubtitleCharacter = nil
        c.w:OnSubtitleUpdated(false)                   -- backer opacity 0: nothing shows
    end)
    inClone = false
end

local function idleAll()
    for _, c in pairs(clones) do idleClone(c) end
end

-- One WBP_Subtitles for a guest view: owned by the guest's controller, on the viewport at the game widget's z, idle.
-- Its Construct calls UpdateFromConfig (inClone keeps our hook out). VERIFY(V-SUB-06): the clone shows the race-start
-- line in the guest's half and fades with the pause like the game's (its own Tick).
local function makeClone(e)
    local w = G.w
    if not (U.ok(w) and U.ok(e.pc)) then return nil end
    local cls
    pcall(function() cls = w:GetClass() end)
    if not U.ok(cls) then return nil end
    local c
    inClone = true
    local ok, err = pcall(function()
        local x = U.WBL():Create(e.pc, cls, e.pc)          -- Create(WorldContextObject, WidgetType, OwningPlayer)
        if not U.ok(x) then error("WidgetBlueprintLibrary:Create gave nothing") end
        c = { w = x, key = U.key(x), path = U.pathOf(x), slot = e.slot, pcKey = e.pcKey }
        x:AddToViewport(gameZ() or 0)
        x:OnSubtitleUpdated(false)                         -- backer opacity 0 until it gets a line
    end)
    inClone = false
    if not ok then
        U.warn(TAG, "clone for P%s not made: %s (lines for everybody stay where the game puts them)", tostring(e.slot),
            tostring(err))
        if c and U.ok(c.w) then pcall(function() c.w:RemoveFromParent() end) end
        return nil
    end
    S.n.clones = S.n.clones + 1
    return c
end

local function removeClones()
    local n = 0
    for q, c in pairs(clones) do
        if U.ok(c.w) and pcall(function() c.w:RemoveFromParent() end) then n = n + 1 end
        clones[q] = nil
    end
    return n
end

-- route + clone: one clone per guest view (a guest whose controller came later, a clone that died); 10 s between two
-- attempts for one view.
local function ensureClones()
    if subMode() ~= "route" or bothMode() ~= "clone" or not U.ok(G.w) then return end
    local now = St.nowMs()
    for _, e in ipairs(L.slots) do
        if e.slot >= 2 and e.slot <= G.n and e.pcKey ~= 0 then
            local c = clones[e.slot]
            if c and (not U.ok(c.w) or c.pcKey ~= e.pcKey) then
                if U.ok(c.w) then pcall(function() c.w:RemoveFromParent() end) end
                clones[e.slot], c = nil, nil
            end
            if not c and now - (G.cloneFail[e.slot] or -1e12) >= 10000 then
                local nc = makeClone(e)
                if nc then clones[e.slot] = nc else G.cloneFail[e.slot] = now end
            end
        end
    end
end

-- The manager sets the game widget's visibility (subtitles on/off, ShowInRaces): the clones follow (FAST).
local function mirrorVis()
    if next(clones) == nil or not U.ok(G.w) then return end
    local okV, v = pcall(function() return G.w:GetVisibility() end)
    if not okV or type(v) ~= "number" then return end
    for _, c in pairs(clones) do
        if c.vis ~= v and U.ok(c.w) and pcall(function() c.w:SetVisibility(v) end) then c.vis = v end
    end
end

-- Moves the current line into its player's view (or P1's + the clones'); returns what was done (for the log).
-- VERIFY(V-SUB-04): P2's crash taunt in the LOWER half (low middle), P1's in the upper half, no box at the old place.
local function place(v)
    local mode = subMode()
    if mode ~= "route" then return "logged only (UxSplitSubtitles " .. mode .. ")" end
    local w = G.w
    if not U.ok(w) then return "no subtitle widget" end
    G.single = isSingle()
    if G.single or G.n < 2 then
        setTf(G, w, nil)
        idleAll()
        return "one full-screen view: the game's place"
    end
    local c = G.conf
    if not c or c.h ~= H_CENTER or c.v ~= V_BOTTOM then
        setTf(G, w, nil)
        idleAll()
        U.logEvery("sub.align." .. tostring(c and c.name), 30000, TAG, "config %s is not Center/Bottom: its lines stay "
            .. "where the game puts them", confText(c))
        return "config " .. (c and tostring(c.name) or "unknown") .. ": the game's place"
    end
    S.n.placed = S.n.placed + 1
    if v.all then
        if bothMode() ~= "clone" then
            setTf(G, w, nil)
            idleAll()
            return "the game's place (UxSplitSubBoth game)"
        end
        for q = 2, G.n do
            if not (clones[q] and U.ok(clones[q].w)) then
                setTf(G, w, nil)
                idleAll()
                return fmt("no clone for P%s: the game's place", tostring(q))
            end
        end
        local tf1 = tfFor(1)
        setTf(G, w, tf1)
        local parts = { "game P1 " .. tfText(tf1) }
        for q = 2, G.n do
            local cl = clones[q]
            local tq = tfFor(q)
            setTf(cl, cl.w, tq)
            local filled = fillClone(cl, G.lastText)
            parts[#parts + 1] = fmt("clone P%s %s%s", tostring(q), tfText(tq), filled and "" or " (NOT filled)")
        end
        return table.concat(parts, ", ")
    end
    idleAll()
    local tf = tfFor(v.slot)
    setTf(G, w, tf)
    if not tf then return fmt("P%s has no view: the game's place", tostring(v.slot)) end
    return fmt("P%s rect, translate %s", tostring(v.slot), tfText(tf))
end

---------------------------------------------------------------------------------------------------- attribution
-- The line on screen now, from the manager: its event tag and line character.
local function currentLine()
    local mgr = G.mgr
    if not U.ok(mgr) then return "", "" end
    local ev, ch = "", ""
    pcall(function() ev = tagOf(mgr:GetCurrentEvent()) end)
    pcall(function() ch = tagOf(mgr:GetCurrentLineCharacter()) end)
    return ev, ch
end

local function matches(e, ev, ch, strict)
    if e.used or ev == "" then return false end
    if e.trig then
        if strict and e.char ~= "" and ch ~= "" and e.char ~= ch then return false end
        return trigInEvent(ev, e.trig)
    end
    return e.event ~= "" and (ev == e.event or ssub(ev, 1, #e.event + 1) == e.event .. ".")
end

-- Pending requests this line can come from: due - EARLY_MS .. due + UxSplitSubPendingMs; the line's own character
-- first, then any character (a conversation may open with another speaker).
local function candidates(ev, ch, now)
    local win = pendingMs()
    for pass = 1, 2 do
        local out = {}
        for _, e in ipairs(pending) do
            if now >= e.due - EARLY_MS and now <= e.due + win and matches(e, ev, ch, pass == 1) then out[#out + 1] = e end
        end
        if #out > 0 then return out end
    end
    return {}
end

local function verdictAll(why, how) return { all = true, why = why, how = how } end
local function verdictSlot(p, why, how) return { slot = p, why = why, how = how } end

-- Candidates -> verdict (nil + a note when only unknown posters asked). A "both" request wins; else the latest due one
-- (a request the cooldown swallowed is older); another player's request due within TIE_MS = both. The chosen request
-- and its duplicates (same label, within TIE_MS) are used up.
local function fromCandidates(cands, now)
    local best, both
    for _, e in ipairs(cands) do
        if e.both then both = both or e
        elseif e.pnum and (best == nil or e.due > best.due) then best = e end
    end
    local ref = both or best or cands[#cands]
    for _, e in ipairs(cands) do
        if e == ref or (e.label == ref.label and abs(e.due - ref.due) <= TIE_MS) then e.used = true end
    end
    if both then return verdictAll(tostring(both.bothWhy), "request") end
    if not best then return nil, fmt("%s by %s", ref.label, tostring(ref.via)) end
    for _, e in ipairs(cands) do
        if e ~= best and e.pnum and e.pnum ~= best.pnum and abs(e.due - best.due) <= TIE_MS then
            return verdictAll(fmt("%s requested by P%s and P%s at once", best.label, tostring(best.pnum),
                tostring(e.pnum)), "request")
        end
    end
    if best.forced then return verdictSlot(best.pnum, "forced", "request") end
    return verdictSlot(best.pnum, fmt("%s by P%s, %.1f s ago", best.label, tostring(best.pnum), (now - best.at) / 1000),
        "request")
end

-- No request: the speaker's REGISTERED scene component (null for an unregistered speaker) -> its actor, or the actor
-- it is attached to (a pilot in its pod) -> a car: a local human's, or an AI car's nearest human within the radius.
local function speakerVerdict()
    local w, sc, a = G.w, nil, nil
    pcall(function() sc = w.SubtitleSceneComponent end)
    if not U.ok(sc) then return nil, "no speaker component" end
    pcall(function() a = sc:GetOwner() end)
    for _ = 1, 3 do
        if not U.ok(a) or U.isVehicle(a) then break end
        local par
        pcall(function() par = a:GetAttachParentActor() end)
        if not U.ok(par) then break end
        a = par
    end
    if not U.isVehicle(a) then return nil, "speaker not in a car" end
    local p = slotOfCar(a)
    if p then return verdictSlot(p, fmt("no request; speaker car P%s", tostring(p)), "speaker") end
    local q, d = nearestHuman(a)
    if q then
        return verdictSlot(q, fmt("no request; speaker car AI, nearest P%s %.0f m", tostring(q), d / 100), "speaker")
    end
    return nil, "speaker car AI, no human within the radius"
end

local function attribute(ev, ch, now)
    -- the next line of the same event (lines of one event follow ~0.7 s apart): the same player(s)
    local lv = G.lastVerdict
    if lv and ev ~= "" and ev == G.lastEv and now - G.lastSeenAt <= CONT_MS then
        return { all = lv.all, slot = lv.slot, why = "same event as the previous line", how = "same event" }
    end
    local note
    local cands = candidates(ev, ch, now)
    if #cands > 0 then
        local v, why = fromCandidates(cands, now)
        if v then return v end
        note = why
    end
    local rk = bothRuleOfEvent(ev)
    if rk then return verdictAll("rule Trigger." .. rk .. " (from the event)", "rule") end
    local v, why = speakerVerdict()
    if v then return v end
    local tail = (note and (note .. "; ") or "") .. tostring(why)
    if unmatchedMode() == "p1" then return verdictSlot(1, "unmatched (" .. tail .. "): P1", "unmatched") end
    return verdictAll("unmatched (" .. tail .. ")", "unmatched")
end

-- A new line on the game widget: attribute, place, log.
-- VERIFY(V-SUB-03): `line VO.ML.Rager.Trigger.PlayerCrashes.Racer speaker=Character.Rager "..." -> P2
-- (Trigger.PlayerCrashes by P2, 3.1 s ago); P2 rect, translate 0,+225`. VERIFY(V-SUB-06): race start `-> both (rule
-- Trigger.RaceStart); game P1 0,-315, clone P2 0,+225`.
local function newLine(text, how, ev, ch, now)
    local v = attribute(ev, ch, now)
    G.lastText, G.lastEv, G.lastVerdict, G.lastSeenAt = text, ev, v, now
    local n = S.n
    n.lines = n.lines + 1
    if v.all then n.linesBoth = n.linesBoth + 1 else n.linesP[v.slot] = (n.linesP[v.slot] or 0) + 1 end
    if v.how == "unmatched" then n.unmatched = n.unmatched + 1 end
    local okP, did = pcall(place, v)
    if not okP then did = "placement failed: " .. tostring(did) end
    S.last = fmt("line %s speaker=%s \"%s\" -> %s (%s); %s", ev ~= "" and ev or "?", ch ~= "" and ch or "-", short(text),
        v.all and "both" or ("P" .. tostring(v.slot)), tostring(v.why), tostring(did))
    U.log(TAG, "%s%s (V-SUB-%s)", S.last, how == "poll" and " [FAST poll]" or "", v.all and "06" or "03/04")
end

-- A non-empty text seen by the config hook or the FAST poll. The text placed last (a repeated config call, a widget's
-- Construct, a settings preview while the line shows) is never attributed again: a waiting request of the other player
-- for the same trigger would steal the line on screen. The same text as a NEW line is seen anyway: lines are >= 0.71 s
-- apart (CommsPadding), so the FAST poll always sees the empty text in between (G.lastText = nil).
local function lineSeen(text, how)
    if text == G.lastText then
        S.n.cfgSame = S.n.cfgSame + 1
        return
    end
    local now = St.nowMs()
    local ev, ch = currentLine()
    if how == "poll" and A.line then
        S.n.late = S.n.late + 1                   -- the config hook should have seen it first (V-SUB-03)
        U.logEvery("sub.late", 30000, TAG, "a line reached the FAST poll before the config hook (%d so far)", S.n.late)
    end
    newLine(text, how, ev, ch, now)
end

---------------------------------------------------------------------------------------------------- hook callbacks
-- GetWorldSubsystem PRE (ctx, ContextObject, Class): every Blueprint world-subsystem lookup; only the class address is
-- compared. VERIFY(V-SUB-07): the probe's "wss N/s" (cost) and "dialogue N" (lookups of the two dialogue subsystems).
local function wssInner(ctxObj, clsP)
    local c = clsP:get()
    if c == nil then return end
    local a = c:GetAddress()
    if a ~= K.trig and a ~= K.mgr then return end
    S.n.wssDlg = S.n.wssDlg + 1
    local o = ctxObj:get()
    if o == nil or kindOf(o) == "subs" then return end   -- a subtitle widget building its text: not a poster
    last = o
end

local function onWssPre(ctx, ctxObj, clsP)
    if not A.poster then return nil end
    S.n.wss = S.n.wss + 1
    local ok, err = pcall(wssInner, ctxObj, clsP)
    if not ok then cbFail("GetWorldSubsystem", err) end
    return nil
end

local function paramNum(p)
    if p == nil then return 0 end
    local ok, v = pcall(U.callMethod, p, "get")
    return (ok and type(v) == "number") and v or 0
end

-- RequestTrigger PRE (ctx, trigger, character) / RequestTriggerDelayed PRE (ctx, trigger, character, delay).
local function reqTrigInner(trigP, charP, delayP)
    addRequest({ trig = tagOf(trigP:get()), char = tagOf(charP:get()), delay = paramNum(delayP) })
end

local function onReqTrigPre(ctx, trigP, charP)
    if not A.req then return nil end
    local ok, err = pcall(reqTrigInner, trigP, charP, nil)
    if not ok then cbFail("RequestTrigger", err) end
    return nil
end

local function onReqTrigDPre(ctx, trigP, charP, delayP)
    if not A.req then return nil end
    local ok, err = pcall(reqTrigInner, trigP, charP, delayP)
    if not ok then cbFail("RequestTriggerDelayed", err) end
    return nil
end

-- RequestEvent PRE (ctx, eventBase, eventCreated (out), 4 delegates, ...): only eventBase is read (never the delegates
-- or the out parameter); a non-delayed request is the race intro. RequestEventDelayed PRE (ctx, eventBase, delay,
-- subtitleOnly): a wrecked / finished player's outro, testLine.
local function reqEvInner(evP, delayP, intro)
    addRequest({ event = tagOf(evP:get()), delay = paramNum(delayP), intro = intro })
end

local function onReqEvPre(ctx, evP)
    if not A.req then return nil end
    local ok, err = pcall(reqEvInner, evP, nil, true)
    if not ok then cbFail("RequestEvent", err) end
    return nil
end

local function onReqEvDPre(ctx, evP, delayP)
    if not A.req then return nil end
    local ok, err = pcall(reqEvInner, evP, delayP, false)
    if not ok then cbFail("RequestEventDelayed", err) end
    return nil
end

-- VehicleNarrativeComponent:OnPlayerHitTargetWithAbility PRE (ctx, abilityTargetHitInfo& {Player, AffectedPlayer,
-- AbilityUsed}) / POST: requests made inside (HandleRacerHitWith{Vent,Shockwave,Disruptor}, which never compare with
-- their own pod) go to the local hitter (PlayerHits) / hit player (HitsPlayer).
-- VERIFY(V-SUB-08): "ahit N" > 0 in the probe after ability hits (0: the hook never fires, the poster rule applies).
local function ahitInner(rec, infoP)
    local info = infoP:get()
    if info == nil then return end
    local inst, tgt
    pcall(function() inst = info.Player end)
    pcall(function() tgt = info.AffectedPlayer end)
    rec.inst, rec.tgt = L.byPs[U.key(inst)], L.byPs[U.key(tgt)]
    S.n.ahit = S.n.ahit + 1
end

local function onAhitPre(ctx, infoP)
    if not A.ahit then return nil end
    local rec = {}
    ahit[#ahit + 1] = rec                          -- pushed first: the post pops exactly one per call
    local ok, err = pcall(ahitInner, rec, infoP)
    if not ok then cbFail("OnPlayerHitTargetWithAbility", err) end
    return nil
end

local function onAhitPost()
    if not A.ahit then return nil end
    ahit[#ahit] = nil
    return nil
end

-- UIManager:GetCurrentSubtitleConfig POST (ctx, ReturnValue): the game widget's UpdateFromConfig at a line start, in the
-- frame the line appears (also: our clones (inClone), our own call (selfCall), a widget's Construct, a settings
-- preview: an empty or already placed text is skipped). VERIFY(V-SUB-03): the probe's "late" stays 0.
local function cfgInner(retP)
    local w = G.w
    if not U.ok(w) then return end
    local text = readText(w)
    if text == "" then return end
    local conf = readConf(retP:get())
    if conf then noteConf(conf) end
    lineSeen(text, "hook")
end

local function onCfgPost(ctx, retP)
    if not A.line then return nil end
    S.n.cfgCalls = S.n.cfgCalls + 1
    if inClone or selfCall then return nil end
    local ok, err = pcall(cfgInner, retP)
    if not ok then cbFail("GetCurrentSubtitleConfig", err) end
    return nil
end

---------------------------------------------------------------------------------------------------- arming
local function wantArmed()
    if subMode() == "off" then return false, "UxSplitSubtitles off" end
    local ph = St.phase
    if ph ~= "PRERACE" and ph ~= "RACING" then return false, "phase " .. tostring(ph) end
    if St.race.singleView == true then return false, "single-view race" end
    local n = #U.localPlayers()
    pcall(function() n = U.mod("split").viewCount() end)   -- couch-livefix r2: dormant players hold no view
    if n < 2 then return false, fmt("%d local player", n) end
    return true, fmt("phase %s, %d local players", ph, n)
end

-- The manager makes its widget in its first tick: looked up again every MAIN tick until then (never a FindAllOf).
local function resolveWidget()
    local mgr = U.worldSubsystem(PATH.MgrSub)
    if not U.ok(mgr) then return nil, nil, "no FuseDialogueManagerSubsystem" end
    local w
    pcall(function() w = mgr.SubtitlesWidget end)                 -- Object<UUserWidget> @0xd0
    if not U.ok(w) then return mgr, nil, "the dialogue manager has no SubtitlesWidget yet" end
    return mgr, w, nil
end

local function classKey(path)
    local ok, c = pcall(StaticFindObject, path)
    return (ok and U.ok(c)) and U.key(c) or 0
end

-- Per-race tables (the counters stay readable after the race; reset when arming again).
local function clearRace()
    pending, last, forced, ahit, KIND, probeBase = {}, nil, nil, {}, {}, nil
    G.lastText, G.lastEv, G.lastVerdict, G.lastSeenAt, G.single, G.z, G.fastAt = nil, "", nil, -1e12, false, nil, nil
    G.cloneFail = {}
end

-- What a QUIET disarm (the world may be going away: nothing is touched) or the previous Lua state (hot reload) left:
-- clones on the viewport and a moved game widget. Removed / reset when the module arms again, or by the MAIN tick, in
-- the SAME world; another world's objects are dropped untouched (the viewport drops their slots with that world).
local LEFT = nil       -- {gen, clones = {wrappers}, paths = {...}, moved}
local SHARED = nil     -- from the previous Lua state: {worldKey, paths = {...}, moved}

local function keepLeftovers()
    local K2 = { gen = St.worldGen, clones = {}, paths = {}, moved = G.tf ~= nil }
    for _, c in pairs(clones) do
        K2.clones[#K2.clones + 1] = c.w
        K2.paths[#K2.paths + 1] = c.path
    end
    clones = {}
    LEFT = (#K2.clones > 0 or K2.moved) and K2 or nil
end

-- Removes what was left in THIS world; returns whether the game widget was left moved (the caller resets it).
local function giveBackLeftovers()
    local nc, moved = 0, false
    local lq = LEFT
    LEFT = nil
    if lq and lq.gen == St.worldGen then
        for _, x in ipairs(lq.clones) do
            if U.ok(x) and pcall(function() x:RemoveFromParent() end) then nc = nc + 1 end
        end
        moved = lq.moved
    end
    local sh = SHARED
    if sh and (St.worldKey or 0) ~= 0 then
        SHARED = nil
        if sh.worldKey == St.worldKey then
            for _, p in ipairs(sh.paths) do
                local okF, x = pcall(StaticFindObject, p)
                if okF and U.ok(x) and pcall(function() x:RemoveFromParent() end) then nc = nc + 1 end
            end
            moved = moved or sh.moved
        end
    end
    if nc > 0 then U.log(TAG, "%d subtitle clone(s) left by an earlier arm / Lua state removed", nc) end
    return moved
end

-- Arms the module if a split race runs and the widget exists (game thread: MAIN tick). Returns true when armed.
function M.ensureArmed(why)
    if A.on then return true end
    local want, reason = wantArmed()
    if not want then return false end
    local mgr, w, miss = resolveWidget()
    if not w then
        U.logEvery("sub.wait", 10000, TAG, "split race: waiting for the subtitle widget (%s)", tostring(miss))
        return false
    end
    clearRace()
    S.n = counters()
    G.mgr, G.w, G.wKey, G.uim = mgr, w, U.key(w), U.giSubsystem("UIManager")
    K.trig, K.mgr = classKey(PATH.TrigSub), classKey(PATH.MgrSub)
    refreshPlayers()
    refreshViewport()
    refreshLayout()
    local moved = giveBackLeftovers()
    G.tf, G.tfSet = nil, false
    setTf(G, w, nil)                     -- a position left by an earlier arm / Lua state goes first
    local c = askConf()                  -- no hook yet
    if c then G.conf = c end
    local owner, wname = nil, "?"
    pcall(function() owner = L.byPc[U.key(w:GetOwningPlayer())] end)
    if U.ok(w) then pcall(function() wname = w:GetFName():ToString() end) end
    S.widget = fmt("%s owner %s z %s", wname, owner and ("P" .. tostring(owner)) or "none", tostring(gameZ()))
    -- VERIFY(V-SUB-05): "widget WBP_Subtitles_C_... owner P1 z <n>; viewport 1920x1080 su (dpi 1.33); config InEvent
    -- pad 450 Center/Bottom; layout top/bottom"
    U.log(TAG, "widget %s; viewport %.0fx%.0f su (dpi %.2f); config %s; layout %s%s (V-SUB-05)", S.widget, G.W, G.H,
        G.dpi, confText(G.conf), G.layout, moved and "; a position left by an earlier arm was reset" or "")
    A.on = true
    local mode = subMode()
    if posterHookOn() then A.poster = hook(PATH.WSS, onWssPre, nil) end   -- PRE only: no Lua post call per lookup
    local r1 = hook(PATH.ReqTrig, onReqTrigPre, nil)
    local r2 = hook(PATH.ReqTrigD, onReqTrigDPre, nil)
    local r3 = hook(PATH.ReqEv, onReqEvPre, nil)
    local r4 = hook(PATH.ReqEvD, onReqEvDPre, nil)
    A.req = r1 or r2 or r3 or r4
    if detectMode() == "hook" then A.line = hook(PATH.SubCfg, noop, onCfgPost) end
    if abilityHookOn() then A.ahit = hook(PATH.AHit, onAhitPre, onAhitPost) end
    if mode == "route" then ensureClones() end
    S.armed, S.why, S.since, S.arms = true, fmt("%s, %s", tostring(why), reason), St.nowMs(), S.arms + 1
    local cl = {}
    for q = 2, G.n do if clones[q] then cl[#cl + 1] = "P" .. tostring(q) end end
    local what
    if mode ~= "route" then what = "logged only (UxSplitSubtitles " .. mode .. ")"
    elseif bothMode() ~= "clone" then what = "no clone (UxSplitSubBoth game)"
    elseif #cl > 0 then what = "clone for " .. table.concat(cl, ", ")
    else what = "no clone made (lines for everybody stay where the game puts them)" end
    -- VERIFY(V-SUB-01): "armed (phase RACING, 2 local players): 7 hook(s), clone for P2" in a 2P race, never in a
    -- single-player one.
    U.log(TAG, "armed (%s): %d hook(s), %s; lines seen by %s%s (V-SUB-01)", reason, hookCount(), what,
        A.line and "the config hook" or "the FAST poll",
        posterHookOn() and "" or "; poster hook off (UxSplitSubPosterHook false: requests have no poster)")
    return true
end

-- quiet: the world is going away ("leaving" fires inside the LoadMap pre-hook): only the hooks go.
-- VERIFY(V-SUB-01): "disarmed (phase POSTRACE): 7 hook(s) off; transform reset; 1 clone(s) removed; lines 9 (P1 4, P2 3,
-- both 2, unmatched 0)"; no crash on the way back to the menu.
function M.disarm(why, quiet)
    if not A.on then return end
    for k in pairs(A) do A[k] = false end
    local n = unhookAll(why)
    local parts = { fmt("%d hook(s) off", n) }
    if quiet then
        keepLeftovers()
        parts[#parts + 1] = "subtitle widgets left as they are (quiet)"
    else
        if U.ok(G.w) and setTf(G, G.w, nil) then parts[#parts + 1] = "transform reset" end
        parts[#parts + 1] = fmt("%d clone(s) removed", removeClones())
    end
    S.armed, S.why = false, "disarmed: " .. tostring(why)
    local c = S.n
    local ps = {}
    for p = 1, 4 do if c.linesP[p] then ps[#ps + 1] = fmt("P%d %d", p, c.linesP[p]) end end
    ps[#ps + 1] = fmt("both %d", c.linesBoth)
    ps[#ps + 1] = fmt("unmatched %d", c.unmatched)
    U.log(TAG, "disarmed (%s): %s; lines %d (%s), requests %d, %d callback error(s) (V-SUB-01)", tostring(why),
        table.concat(parts, "; "), c.lines, table.concat(ps, ", "), c.req, c.cbErrors)
    clearRace()
    G.mgr, G.w, G.wKey, G.uim, G.tf, G.tfSet = nil, nil, 0, nil, nil, false
end

---------------------------------------------------------------------------------------------------- ticks
-- This tick's pause state: pause.lua's (pause.poll runs earlier in the same FAST tick, main.lua), else U.csmPaused().
local function pausedNow()
    local P = St.pause
    if type(P) == "table" and P.menuWasPaused ~= nil then return P.menuWasPaused == true end
    return U.csmPaused() == true
end

local function perSlot(t)
    local parts = {}
    for p = 1, 4 do if t[p] then parts[#parts + 1] = fmt("P%d %d", p, t[p]) end end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- VERIFY(V-SUB-07/08): one line per cfg.UxSplitProbeMs while armed: GetWorldSubsystem rate and dialogue lookups,
-- requests per poster / from AI pods / in pairs, lines per verdict, late (poll before hook), ability hits.
local function probe(now)
    local every = probeMs()
    local c = S.n
    if probeBase == nil then                       -- first MAIN tick of an arm: the first line one period later
        lastProbe, probeBase = now, { at = now, wss = c.wss }
        return
    end
    if every <= 0 or now - lastProbe < every then return end
    local base = probeBase
    local secs = max((now - base.at) / 1000, 0.001)
    U.log(TAG, "probe: wss %.0f/s (dialogue %d) requests %d (%s, AI %d, unknown %d, pairs %d) lines %d (%s, both %d, "
        .. "unmatched %d, late %d) config calls %d ahit %d (V-SUB-07/08)", (c.wss - base.wss) / secs, c.wssDlg, c.req,
        perSlot(c.reqP), c.reqAI, c.reqUnknown, c.pairs, c.lines, perSlot(c.linesP), c.linesBoth, c.unmatched, c.late,
        c.cfgCalls, c.ahit)
    lastProbe, probeBase = now, { at = now, wss = c.wss }
end

-- FAST (main.lua, race phases, after uxsplit.fastTick): poster reset, pause shift, line poll / line end, clone
-- visibility, one view <-> split while a line shows.
function M.fastTick()
    if not A.on then return end
    last = nil                                     -- a GetWorldSubsystem context never serves a later tick's request
    if #ahit > 0 then
        U.logEvery("sub.ahit", 10000, TAG, "WARN %d ability-hit call(s) without their post-step dropped", #ahit)
        ahit = {}
    end
    local now = St.nowMs()
    local dt = now - (G.fastAt or now)
    G.fastAt = now
    -- the trigger subsystem does not tick while the game is paused: the waiting requests' windows wait too
    if dt > 0 and dt < 1000 and #pending > 0 and pausedNow() then
        for _, e in ipairs(pending) do e.due = e.due + dt end
    end
    local w = G.w
    if not U.ok(w) then return end
    local text = readText(w)
    if text == "" then
        if G.lastText ~= nil then
            G.lastText = nil
            idleAll()                              -- the line is over: the clones too
        end
    else
        if text ~= G.lastText then
            local c = askConf()                    -- the config hook did not see this line (or "poll")
            if c then noteConf(c) end
            lineSeen(text, "poll")
        end
        G.lastSeenAt = now
    end
    mirrorVis()
    fastN = fastN + 1
    if fastN % 3 == 0 and G.lastText ~= nil and G.lastVerdict ~= nil and subMode() == "route" then
        local single = isSingle()                  -- ~100 ms: one view <-> split while a line shows
        if single ~= G.single then
            local okP, did = pcall(place, G.lastVerdict)
            U.log(TAG, "%s while a line shows: %s", single and "ONE full-screen view" or "split views",
                okP and tostring(did) or ("placement failed: " .. tostring(did)))
        end
    end
end

-- Not armed, race phase: what an earlier arm / Lua state left in this world goes (a moved game widget is reset).
local function leftoverTick()
    if LEFT == nil and SHARED == nil then return end
    if LEFT == nil and (St.worldKey or 0) == 0 then return end
    local moved = giveBackLeftovers()
    if moved then
        local _, w = resolveWidget()
        local h = {}
        if w and setTf(h, w, nil) then U.log(TAG, "subtitle position left by an earlier arm / Lua state reset") end
    end
end

-- MAIN (main.lua, race phases, after uxsplit.tick): arm / disarm, players, viewport, layout, widget, clones, probe.
function M.tick()
    local want, reason = wantArmed()
    if want and not A.on then
        M.ensureArmed("race tick")
    elseif not want and A.on then
        M.disarm(reason, false)
    end
    if not A.on then
        leftoverTick()
        return
    end
    local now = St.nowMs()
    local sig = fmt("%d|%s|%.0f|%.0f", G.n, tostring(G.side), G.W, G.H)
    refreshPlayers()
    refreshViewport()
    refreshLayout()
    local mgr, w = resolveWidget()
    if w and U.key(w) ~= G.wKey then               -- the manager made another widget: adopted, the old one reset
        if U.ok(G.w) then setTf(G, G.w, nil) end
        local nc = removeClones()
        G.mgr, G.w, G.wKey, G.z, G.tf, G.tfSet, G.lastText = mgr, w, U.key(w), nil, nil, false, nil
        setTf(G, w, nil)
        U.log(TAG, "the dialogue manager has a new subtitle widget: adopted (%d clone(s) re-made)", nc)
    end
    if subMode() == "route" then ensureClones() end
    if sig ~= fmt("%d|%s|%.0f|%.0f", G.n, tostring(G.side), G.W, G.H) and G.lastText and G.lastVerdict then
        local okP, did = pcall(place, G.lastVerdict)
        U.log(TAG, "layout %s, viewport %.0fx%.0f su while a line shows: %s", G.layout, G.W, G.H,
            okP and tostring(did) or ("placement failed: " .. tostring(did)))
    end
    probe(now)
end

---------------------------------------------------------------------------------------------------- testcmd / diag
-- `lua return require("subsplit").testLine(2, "VO.ML.Rager.Trigger.PlayerCrashes.Racer")`: that event requested as
-- player p (0 = everybody) through RequestEventDelayed(event, 0.1, subtitleOnly = true) (no trigger cooldown); the
-- line follows ~0.1 s later: "[subsplit] line ... -> P2 (forced); P2 rect, translate 0,+225" (V-SUB-03/04/06).
function M.testLine(p, ev)
    if not A.on then return "not armed (" .. tostring(S.why) .. ")" end
    local mgr = G.mgr
    if not U.ok(mgr) then return "no dialogue manager" end
    ev = tostring(ev or "VO.ML.Rager.Trigger.PlayerCrashes.Racer")
    local q = floor(tonumber(p) or 0)
    local prev = forced
    forced = { pnum = (q >= 1) and q or "both", why = "forced" }
    local ok, err = pcall(function() mgr:RequestEventDelayed({ TagName = U.fname(ev) }, 0.1, true) end)
    forced = prev
    if not ok then return "error: " .. tostring(err) end
    return fmt("requested %s for %s%s; the line log follows in ~0.1 s", ev, (q >= 1) and ("P" .. tostring(q)) or "everybody",
        A.req and "" or " (WARNING: request hooks off: the line will not be matched)")
end

function M.status()
    local c = S.n
    return fmt("armed=%s (%s) widget=[%s] hooks=%d requests=%d (%s) lines=%d (%s, both %d, unmatched %d, late %d) "
        .. "clones=%d cbErrors=%d | last: %s", tostring(S.armed), tostring(S.why), tostring(S.widget), hookCount(), c.req,
        perSlot(c.reqP), c.lines, perSlot(c.linesP), c.linesBoth, c.unmatched, c.late, c.clones, c.cbErrors,
        tostring(S.last))
end

function M.dump(out)
    out = out or function(f, ...) U.log(TAG, f, ...) end
    out("subsplit: %s", M.status())
    out("  cfg: subtitles=%s detect=%s both=%s unmatched=%s posterHook=%s abilityHook=%s pendingMs=%s aiRadiusUU=%s "
        .. "sideScale=%s halfFrac=%s probeMs=%s", subMode(), detectMode(), bothMode(), unmatchedMode(),
        tostring(posterHookOn()), tostring(abilityHookOn()), tostring(pendingMs()), tostring(aiRadius()),
        tostring(sideScale()), tostring(halfFrac()), tostring(probeMs()))
    out("  flags: poster=%s req=%s line=%s ahit=%s; layout %s (%d views%s), viewport %.0fx%.0f su; config %s; game "
        .. "widget %s", tostring(A.poster), tostring(A.req), tostring(A.line), tostring(A.ahit), tostring(G.layout), G.n,
        G.single and ", ONE view now" or "", G.W, G.H, confText(G.conf), tfText(G.tf))
    local paths = {}
    for p in pairs(S.hooks) do paths[#paths + 1] = p end
    table.sort(paths)
    for _, p in ipairs(paths) do out("  hook %s: %s", p, tostring(S.hooks[p])) end
    for q, c in pairs(clones) do
        out("  clone P%s: %s %s%s", tostring(q), tostring(c.path), tfText(c.tf), c.showing and " (showing)" or "")
    end
    local labels = {}
    for i = max(1, #pending - 7), #pending do
        local e = pending[i]
        labels[#labels + 1] = fmt("%s=%s%s", e.label, e.both and "both" or slotName(e.pnum), e.used and "(used)" or "")
    end
    out("  pending %d: %s", #pending, #labels > 0 and table.concat(labels, " ") or "none")
end

-- Hot reload (main.lua PERSIST_MODULES): the clones on the viewport and whether the game widget is moved, so the next
-- Lua state removes / resets them in this same world. OnUnload is not on the game thread: Lua values only.
function M.persistShared(put)
    local paths = {}
    for _, c in pairs(clones) do if type(c.path) == "string" and c.path ~= "" then paths[#paths + 1] = c.path end end
    if LEFT and LEFT.gen == St.worldGen then
        for _, p in ipairs(LEFT.paths) do if type(p) == "string" and p ~= "" then paths[#paths + 1] = p end end
    end
    put("subsplit.clones", table.concat(paths, "|"))
    put("subsplit.moved", G.tf ~= nil or (LEFT ~= nil and LEFT.moved == true))
    put("subsplit.world", St.worldKey or 0)
end

function M.restoreShared(get)
    local s, paths = get("subsplit.clones"), {}
    if type(s) == "string" then for p in s:gmatch("[^|]+") do paths[#paths + 1] = p end end
    local moved = get("subsplit.moved") == true
    local wk = tonumber(get("subsplit.world")) or 0
    if (#paths > 0 or moved) and wk ~= 0 then
        SHARED = { worldKey = wk, paths = paths, moved = moved }
        U.log(TAG, "hot reload: %d subtitle clone(s)%s of the previous instance are removed in that same world",
            #paths, moved and " and its moved subtitle position" or "")
    end
end

function M.init()
    local stale = 0
    for _, h in pairs(HOOKS) do if h.owner ~= INSTANCE then stale = stale + 1 end end
    if stale > 0 and onGameThread() then
        unhookAll("stale registration of an earlier load")
        stale = 0
    end
    -- "leaving" fires synchronously inside the LoadMap / seamless-travel / RequestReturnToMenus pre-hooks: the hooks go
    -- before the map changes (run H crash rule). POSTRACE: the world is alive: position reset, clones removed.
    St.on("leaving", TAG, function(reason) M.disarm("leaving: " .. tostring(reason), true) end)
    St.on("phase", TAG, function(new)
        if new ~= "PRERACE" and new ~= "RACING" then M.disarm("phase " .. tostring(new), new ~= "POSTRACE") end
    end)
    St.on("world", TAG, function() if not A.on then clearRace() end end)
    -- VERIFY(V-SUB-00): "init: subtitles=route detect=hook both=clone unmatched=both ability-hook on; hooks only in split
    -- races"
    U.log(TAG, "init: subtitles=%s detect=%s both=%s unmatched=%s ability-hook %s%s; hooks only in split races%s "
        .. "(V-SUB-00)", subMode(), detectMode(), bothMode(), unmatchedMode(), abilityHookOn() and "on" or "off",
        posterHookOn() and "" or ", poster-hook off",
        stale > 0 and fmt("; %d stale hook registration(s) of an earlier load, replaced when arming", stale) or "")
end

return M
