-- nametags.lua (G5): colour and label the vehicle markers of human players in every HUD we host.
--   local humans: their player colour (consts.COLOURS[pnum]) and the label "P<n>";
--   remote humans: neutral consts.COLOURS.Remote, the game's own name kept.               [ARCH 1.6, HUD 5]
-- Static facts (reflect.tsv, exports/hud/*.props.txt, 2026-10-06):
--   UVehicleMarkerContainer.Canvas (FuseCanvasPanel); PanelWidget:GetChildrenCount() -> Int, GetChildAt(Int) ->
--   Object (primary), GetAllChildren() -> TArray (array return, fallback only)
--   UVehicleMarkerWidget.MarkerVM (UVehicleMarkerVM), .PlayerTag (UFuseUserWidget);
--   UVehicleMarkerVM.PlayerState / LocalPlayerState (AGfnPlayerState)
--   WBP_HUD_AbilityReticles_C vars: DesiredTagColour (LinearColor), HudPlayerTag (object)
--   WBP_Hud_PlayerTag_C var Txt_PlayerName (FuseTextBlock): SetText(Text InText)
--   APlayerState:GetPlayerName() -> Str;  KSL:GetConsoleVariableBoolValue(Str VariableName) -> Bool
-- Blueprint behaviour (kismet-disasm of WBP_HUD_AbilityReticles and WBP_Hud_PlayerTag):
--   * Reticle OnInit (ubergraph 1874): DesiredTagColour = PlayerTag.ColorAndOpacity; then only if the native cvar
--     UI.UseScreenSpaceCarTags is true: PlayerTag visible, HudPlayerTag = cast(PlayerTag),
--     HudPlayerTag:SetPlayerState(MarkerVM.PlayerState). If false: PlayerTag Collapsed, HudPlayerTag never set,
--     so neither tint nor label can show (see cvarCheck / cfg.ForceCarTags).
--   * Reticle OnOpacityUpdated (ubergraph 2375 -> 599) tints HudPlayerTag with DesiredTagColour: the colour we
--     write is picked up on the next opacity update.
--   * WBP_Hud_PlayerTag writes Txt_PlayerName ONLY in OnPlayerStateUpdated (ubergraph 805-931), which only
--     SetPlayerState calls (reticle OnInit). There is no periodic name refresh: our "P<n>" stays until we change
--     it, and restoreMarker must write the real name back itself (it does).
-- The marker container is located by hud.lua (it is not a Blueprint variable of the HUD; tree walk) and
-- handed over in hud.allHuds()[i].markers.

local C = require("consts")
local cfg = require("config")
local settings = require("settings")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "nametags"

local labelText = {} -- label string -> FText (Lua-side cache; every SetText still builds a new FText from its string)
local CARTAGS_CVAR = "UI.UseScreenSpaceCarTags"
local forcedCvar = nil -- {orig = bool|nil} while cfg.ForceCarTags has set the cvar (restored in the front end)

local function T()
    St.tags = St.tags or { seen = {} }
    St.tags.seen = St.tags.seen or {}
    return St.tags
end

local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

local function colourOf(m)
    local c = m.DesiredTagColour -- struct property: field access on the userdata [API 8]
    local ok, t = pcall(function() return { R = c.R, G = c.G, B = c.B, A = c.A } end)
    if ok and type(t.R) == "number" then return t end
    return nil
end

-- Children of a panel. Primary: GetChildrenCount() -> Int / GetChildAt(Int) -> Object (scalar returns only).
-- GetAllChildren() is the fallback only: UE4SS never destructs a UFunction's parameter buffer, so its TArray return
-- allocation is retained on every call (and its elements are RemoteUnrealParams into that buffer) [G5 review].
local function children(panel)
    local out = {}
    local okc, cnt = pcall(function() return panel:GetChildrenCount() end)
    if okc and type(cnt) == "number" then
        for i = 0, cnt - 1 do
            local okA, ch = pcall(function() return panel:GetChildAt(i) end)
            if okA and U.ok(ch) then out[#out + 1] = ch end
        end
        return out
    end
    U.logOnce("tags.allchildren", TAG, "GetChildrenCount unreadable on the marker canvas; using GetAllChildren")
    local ok, arr = pcall(function() return panel:GetAllChildren() end) -- VERIFY(V-CORE-08): array return
    if ok and arr ~= nil then
        local ok2, t = pcall(U.arrayToTable, arr)
        if ok2 and type(t) == "table" then out = t end
    end
    return out
end

local function tagTextOf(m)
    local tag = m.PlayerTag
    if not U.ok(tag) then tag = m.HudPlayerTag end
    if not U.ok(tag) then return nil end
    local t = tag.Txt_PlayerName
    if U.ok(t) then return t end
    return nil
end

-- Give a marker back what we changed: its colour, and (when we labelled it) the name of the PlayerState it now
-- shows, exactly as WBP_Hud_PlayerTag writes it (Conv_StringToText(PlayerState:GetPlayerName())). The BP never
-- rewrites the name by itself (no periodic refresh), so without this "P<n>" would stay for the rest of the race.
local function writeRealName(m)
    local vm = m.MarkerVM
    local ps = U.ok(vm) and vm.PlayerState or nil
    local t = tagTextOf(m)
    if t and ps and U.ok(ps) then
        local ok, name = pcall(function() return ps:GetPlayerName() end) -- APlayerState:GetPlayerName() -> Str
        if ok then t:SetText(U.ftext(U.str(name))) end
    end
end

local function restoreMarker(rec)
    local m = rec.marker
    if not U.ok(m) then return end
    if rec.orig then m.DesiredTagColour = rec.orig end
    if rec.labelled then
        writeRealName(m)
        rec.labelled, rec.labelPnum = false, nil
    end
end

-- Current text of a TextBlock (TextBlock:GetText() -> Text). Retains one reference to the CURRENT text in the
-- never-destructed param buffer (a refcount, no new text), unlike SetText which builds a new FText per call.
local function textOf(t)
    local ok, s = pcall(function() return t:GetText():ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end

-- UI.UseScreenSpaceCarTags: true / false / nil (unreadable). KSL:GetConsoleVariableBoolValue(Str) -> Bool.
local function carTagsCvar()
    local ksl = U.KSL()
    if not U.ok(ksl) then return nil end
    local ok, v = pcall(function() return ksl:GetConsoleVariableBoolValue(CARTAGS_CVAR) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- cfg.ForceCarTags: set the cvar before the markers initialise (each reticle reads it once in OnInit), i.e. on
-- LAUNCHING / LOADING / first race phase. Restored in the front end.
local function forceCvar()
    if cfg.ForceCarTags ~= true or settings.get("NameTags") ~= true then return end
    if forcedCvar then return end
    local cur = carTagsCvar()
    if cur == true then return end
    -- VERIFY(V-HUD-11b): the console write takes effect for markers created afterwards.
    if U.console(CARTAGS_CVAR .. " 1") then
        forcedCvar = { orig = cur }
        U.log(TAG, "%s was %s; set to 1 (cfg.ForceCarTags)", CARTAGS_CVAR, tostring(cur))
    end
end

local function unforceCvar()
    if not forcedCvar then return end
    local orig = forcedCvar.orig
    forcedCvar = nil
    if orig == false then U.console(CARTAGS_CVAR .. " 0") end
end

-- Apply the tags to one HUD. `humans` = roster.humanPlayerStates() (psKey -> {pnum, colour, isLocal}).
-- `markers` (optional, additive to the contract) = the HUD's marker container; resolved through hud.lua if nil.
function M.applyToHud(widget, humans, markers)
    local tags = T()
    if not U.ok(widget) then return 0 end
    if markers == nil then
        local hud = lazy("hud")
        if hud and hud._membersOf then
            local ok, mem = U.try(TAG, hud._membersOf, widget)
            if ok and mem then markers = mem.markers end
        end
    end
    if not (markers and U.ok(markers)) then
        U.logOnce("tags.nomarkers." .. U.key(widget), TAG, "no vehicle-marker container in %s", U.pathOf(widget))
        return 0
    end
    local canvas = markers.Canvas
    if not U.ok(canvas) then return 0 end
    local n = 0
    for _, m in ipairs(children(canvas)) do
        U.try(TAG, function()
            if not U.ok(m) then return end
            local mk = U.key(m)
            local vm = m.MarkerVM
            local ps = U.ok(vm) and vm.PlayerState or nil
            local h = (ps and U.ok(ps)) and humans[U.key(ps)] or nil
            local rec = tags.seen[mk]
            if not h then
                -- pooled marker now showing an AI (or nothing): give its colour and name back once
                if rec then restoreMarker(rec); tags.seen[mk] = nil end
                return
            end
            if not rec then
                rec = { marker = m, orig = colourOf(m) }
                tags.seen[mk] = rec
            end
            local psKey = U.key(ps)
            local psChanged = (rec.psKey ~= nil and rec.psKey ~= psKey)
            rec.psKey = psKey
            -- VERIFY(V-HUD-11): the BP applies DesiredTagColour on its next opacity update and our label sticks
            -- (the BP writes the name only from SetPlayerState). Fallback: NAME TAGS off in the Lobby.
            m.DesiredTagColour = h.colour or C.COLOURS.Remote
            if h.pnum then
                local t = tagTextOf(m)
                if t then
                    local want = M.labelFor(h.pnum, ps)
                    -- SetText only when needed: a new marker/player, or the BP rewrote the name (SetPlayerState on
                    -- a pooled marker). GetText of an unchanged text costs a refcount, SetText a new FText.
                    if psChanged or rec.labelPnum ~= h.pnum or textOf(t) ~= want then
                        local ft = labelText[want]
                        if not ft then ft = U.ftext(want); labelText[want] = ft end
                        t:SetText(ft)
                    end
                    rec.labelled, rec.labelPnum = true, h.pnum
                end
            elseif rec.labelled then
                -- pooled marker we labelled for a local human, now showing a remote human: give the name back
                -- (the BP may not have rewritten it; see the header)
                writeRealName(m)
                rec.labelled, rec.labelPnum = false, nil
            end
            n = n + 1
        end)
    end
    return n
end

-- Give every marker we touched its original colour and real name back (setting switched off) and forget them.
local function restoreAll()
    local tags = T()
    for _, rec in pairs(tags.seen) do U.try(TAG, restoreMarker, rec) end
    tags.seen = {}
end

-- Only races of this mod get name tags: a race it launched (launchedByUs, kept across relisten/servertravel worlds),
-- a race with split views (localViews >= 2), or a connected client of a self-hosted race (wantConnected). Never a
-- single-view race of the race_enter guard, nor a single-player Campaign/Arcade or an official online race, where the
-- game's own vehicle markers stay untouched.
function M.modRace()
    if St.race.singleView == true then return false end
    if St.race.launchedByUs == true then return true end
    if (tonumber(St.race.localViews) or 1) >= 2 then return true end
    return St.net.wantConnected == true and U.netMode() == "client"
end

-- MAIN loop, race phases (main gates it on phase.isRace()).
function M.tick()
    -- guest names (every race phase); main.lua may also call namesTick() in the front end (throttled to 1 s)
    U.try(TAG, M.namesTick)
    local ph = St.phase
    if ph ~= "PRERACE" and ph ~= "RACING" then return end
    local tags = T()
    if settings.get("NameTags") ~= true or not M.modRace() then
        if next(tags.seen) ~= nil then restoreAll() end
        return
    end
    -- VERIFY(V-HUD-11b): with UI.UseScreenSpaceCarTags false (native default unknown, no shipped ini sets it)
    -- the reticle collapses PlayerTag and never assigns HudPlayerTag: nothing we write can show.
    -- Fallback: cfg.ForceCarTags = true (sets the cvar before the markers initialise, next race).
    if tags.cvar == nil then
        local v = carTagsCvar()
        tags.cvar = (v == nil) and "unknown" or v
        if v == false then
            U.warn(TAG, "%s is false: the game hides car tags, name tags cannot show this race%s", CARTAGS_CVAR,
                cfg.ForceCarTags == true and " (forced too late?)" or "; set cfg.ForceCarTags = true")
        elseif v == nil then
            U.logOnce("tags.cvar?", TAG, "%s unreadable; applying name tags anyway", CARTAGS_CVAR)
        end
    end
    if tags.cvar == false then return end
    local hud = lazy("hud")
    local roster = lazy("roster")
    if not (hud and roster) then return end
    local okH, huds = U.try(TAG, hud.allHuds)
    if not okH or type(huds) ~= "table" or #huds == 0 then return end
    local okR, humans = U.try(TAG, roster.humanPlayerStates)
    if not okR or type(humans) ~= "table" or next(humans) == nil then return end
    -- forget records whose marker widget is gone
    for k, rec in pairs(tags.seen) do
        if not U.ok(rec.marker) then tags.seen[k] = nil end
    end
    for _, entry in ipairs(huds) do
        U.try(TAG, M.applyToHud, entry.widget, humans, entry.markers)
    end
end

function M.clear()
    St.tags = { seen = {} }
end

---------------------------------------------------------------------------------------------------- guest names
-- Feedback 5 ("Name of the racer the same"): a guest LocalPlayer shares P1's online identity, so its PlayerState gets
-- P1's persona name ("Yuval" twice in session B). Name sources read by the game (2026-10-07, static):
--   * WBP_Hud_PlayerTag: Conv_StringToText(PlayerState:GetPlayerName())  (APlayerState.PlayerNamePrivate)
--   * results rows: native EventResultsTableEntry.PlayerName (Str), filled natively from the PlayerState; whether
--     from GetPlayerName() or AGfnPlayerState:GetFilteredName() (profanity-filtered copy, refreshed when the name
--     replicates: OnPlayerNameReady) is not readable statically.                                  VERIFY(V-NAM-02)
-- Every guest PlayerState gets cfg.GuestNames[pnum - 1] (default "Player <n>") through the engine's own rename path:
--   "rpc"      APlayerController:ServerChangeName(Str) (server RPC; on the server/standalone it runs at once:
--              AGameModeBase:ChangeName(pc, name, true) -> APlayerState::SetPlayerName -> OnRep_PlayerName)
--   "gamemode" AGameModeBase:ChangeName(Controller, Str NewName, Bool bNameChange) (server only)
--   "direct"   PlayerNamePrivate written + OnRep_PlayerName() (server only; last resort)
-- cfg.GuestNameMethod = "auto" walks rpc -> gamemode -> direct while the name does not stick. Re-checked every second
-- (seamless travel copies PlayerName into the new PlayerState; the game may also rewrite it from the profile).
local DEFAULT_GUEST_NAMES = { "Player 2", "Player 3", "Player 4" }
local names = { lastMs = nil, st = {} }

function M.guestName(pnum)
    local list = cfg.GuestNames
    if type(list) ~= "table" then list = DEFAULT_GUEST_NAMES end
    local n = list[(tonumber(pnum) or 2) - 1]
    if type(n) == "string" and n ~= "" then return n end
    return "Player " .. tostring(pnum)
end

-- Tag label of a local human (cfg.NameTagLabel: "pnum" (default, "P2") | "name" ("Player 2") | "both").
function M.labelFor(pnum, ps)
    local mode = cfg.NameTagLabel
    if mode ~= "name" and mode ~= "both" then return "P" .. pnum end
    local name
    if pnum == 1 then
        local ok, s = pcall(function() return ps:GetPlayerName() end)
        name = ok and U.str(s) or nil
    else
        name = M.guestName(pnum)
    end
    if not name or name == "" then return "P" .. pnum end
    if mode == "both" then return "P" .. pnum .. " " .. name end
    return name
end

local function playerNameOf(ps)
    local ok, s = pcall(function() return ps:GetPlayerName() end) -- APlayerState:GetPlayerName() -> Str
    if ok then return U.str(s) end
    return nil
end

local METHODS = { "rpc", "gamemode", "direct" }

local function renameWith(method, pc, ps, want)
    if method == "rpc" then
        pc:ServerChangeName(want)                         -- ServerChangeName(Str S)
    elseif method == "gamemode" then
        local gm = U.gm()
        if not U.ok(gm) then return false end             -- client: no authority game mode
        gm:ChangeName(pc, want, true)                     -- ChangeName(Controller, Str NewName, Bool bNameChange)
    else
        if not U.isServer() and not U.isStandalone() then return false end
        ps.PlayerNamePrivate = want                       -- APlayerState.PlayerNamePrivate (Str)
        ps:OnRep_PlayerName()                             -- refreshes the game's name caches (GfnPlayerState)
    end
    return true
end

local function ensureName(pc, ps, want, pnum)
    local k = U.key(pc)
    local s = names.st[k]
    if not s or s.want ~= want or s.psKey ~= U.key(ps) then
        s = { want = want, psKey = U.key(ps), tries = 0, step = 1 }
        names.st[k] = s
    end
    local cur = playerNameOf(ps)
    if cur == nil or cur == want then
        if cur == want and s.tries > 0 and not s.logged then
            s.logged = true
            U.log(TAG, "P%d is now named '%s' (%s, %d attempt(s))", pnum, want, METHODS[s.step] or "?", s.tries)
        end
        return
    end
    local m = cfg.GuestNameMethod
    local method
    if m == "rpc" or m == "gamemode" or m == "direct" then
        method = m
    else
        -- auto: two tries per method, then the next one; after the last, keep it at a slow pace
        if s.tries >= 2 * s.step and s.step < #METHODS then s.step = s.step + 1 end
        method = METHODS[s.step]
    end
    if s.tries >= 8 and (s.tries % 10) ~= 0 then s.tries = s.tries + 1; return end -- slow retries, quiet log
    s.tries = s.tries + 1
    -- VERIFY(V-NAM-01): the guest's tag, position list and results show cfg.GuestNames, P1 keeps its own name.
    local ok, err = pcall(renameWith, method, pc, ps, want)
    if s.tries <= 6 or (s.tries % 10) == 0 then
        U.log(TAG, "P%d name '%s' -> '%s' via %s (attempt %d)%s", pnum, tostring(cur), want, method, s.tries,
            ok and "" or (": " .. tostring(err)))
    end
end

-- MAIN loop, every phase (front end included: the lobby and the next race read the same PlayerState chain).
function M.namesTick()
    if cfg.GuestNameMode == "off" then return end
    local now = St.nowMs()
    if names.lastMs and now - names.lastMs < 1000 then return end
    names.lastMs = now
    local join = lazy("join")
    local tko = lazy("takeover")
    for _, lp in ipairs(U.localPlayers()) do
        if lp.index >= 2 and U.ok(lp.pc) then
            U.try(TAG, function()
                local pnum
                if join and join.displayNumForPC then   -- unique also for a non-joined guest (not lp.index)
                    local ok, p = pcall(join.displayNumForPC, lp.pc)
                    if ok and type(p) == "number" then pnum = p end
                end
                pnum = pnum or lp.index
                local want = M.guestName(pnum)
                local ps = lp.pc.PlayerState
                if U.ok(ps) then ensureName(lp.pc, ps, want, pnum) end
                -- takeover with PlayerState adoption: the racer entry is the AI's PlayerState (no PC of its own)
                if tko and tko.racerPSFor and cfg.GuestNameAdopted ~= false then
                    local okR, rps = pcall(tko.racerPSFor, lp.pc)
                    if okR and U.ok(rps) and not U.same(rps, ps) and playerNameOf(rps) ~= want
                        and (U.isServer() or U.isStandalone()) then
                        pcall(renameWith, "direct", lp.pc, rps, want)
                    end
                end
            end)
        end
    end
end

-- Not in ARCHITECTURE's main init list: nametags needs no hooks. The "leaving" cleanup that §1.7 asks for is
-- registered here once at require time (event listener only, no game call).
St.on("leaving", TAG, function() M.clear() end)
St.on("phase", TAG, function(new)
    if new == "LAUNCHING" or new == "LOADING" or new == "PRERACE" then
        U.try(TAG, forceCvar)
    elseif new == "FRONTEND" then
        U.try(TAG, unforceCvar)
    end
end)

return M
