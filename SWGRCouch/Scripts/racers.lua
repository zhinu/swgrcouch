-- racers.lua (G3 Front-end UI, 0.10.0): the race setup's step 5 RACERS - one card per local player, each player on
-- its own PILOT -> VEHICLE -> PERKS -> READY. User request 2026-10-09: "A chracter should be chosen, a kart then. and
-- then we should be able to map out all the benefits and perks added to the kart (all unlocked just for this mod)",
-- "kart are horrible p1 and p2 are not similar". Binding spec: notes/design/vehicle-step-v2.md §2 (UX flow) and §5.7
-- (this module) with the review corrections RC-6 (sounds, stray mouse clicks), RC-10 (direction guard) and RC-11
-- (KeyboardIsP1 pad-1 guest), plus the optional "ring" input mode.
--
-- One state machine per player, St.racers.players[ControllerId]: cards, memory, preview bays and the persisted picks are
-- keyed by ControllerId; pnum only numbers and colours the cards. Every input source ends in dispatch():
--   guests    their own PlayerController, polled (setup.lua's readPad): d-pad / left stick with repeat on both axes, A on
--             the press edge, B on the RELEASE when held shorter than CardBackTapMaxMs (a 1 s hold leaves: join.lua);
--   P1's pad  CommonUI focus on an invisible 5-button "sink" in the footer: a move onto a neighbour is one direction and
--             the focus goes back to the centre; a click on any sink button is P1's accept, held one FAST tick and
--             dropped when a guest's A coincides (task #14);
--   P1 keys   keyq -> lobby.onKey -> setup.onKey -> M.onKey (arrows, Enter / Space, Backspace);
--   P1's B    setup.pollP1Back -> M.onP1Back (P1's PlayerController sees pad keys after a race only, CM §3.1);
--   tests     M.event(pnum | "c<ControllerId>", ev) from test.cmd.
-- cards.lua only draws: each card's view model (§5.6) is built here right before cards.render, in the tick that takes
-- its vpreview brush (GC rule). Picks are always complete, so READY is reachable from any stage. Data: pilots.lua
-- (roster, defaults, uniqueness), vehicles.lua (models, liveries), perks.lua (loadouts, pure), perkapply.lua (the class's
-- system flags, the energy costs).
-- setup.lua drives it; no init, no loop of its own: build (per page), enter / leave (step 5 shown / left), poll (its FAST
-- pollNav while the lobby is not covered), keepFocus, onKey, onP1Back, onPlayers, onPageShown, and for the race choice
-- readyState / choicePlayers / persist / restore.
-- VERIFY ids: V-RC-02 (sink), V-RC-03 (A,A,A fast, Enter, Backspace), V-RC-04 (guests), V-RC-07 (attribution guards),
-- V-RC-08 (P1 back), V-RC-09 (taken pilots, follow rules), V-RC-10 (prebuild), V-RC-14 (quick path), V-RC-25
-- (persistence), V-RC-30 (sounds, stray clicks), V-RC-31 (page owner).
--
-- 0.12.0 UI v2 (notes/design/ui-v2/ui-redesign-final.md §6.4, §6.5, §8, §9.9, §12 WI-08). The renderer is chosen at
-- page build by cfg.UiStyle: "classic" = cards.lua, fed exactly the 0.11.0 view model (perks.detail style "classic"),
-- else cards2.lua (the cards.lua API unchanged; a cards2 that cannot load or init falls back to cards.lua and the
-- classic view model for that page). The v2 view model (§9.9) adds inputMode (P1's, theme.inputMode; guests "pad"),
-- rankTag (the Pod Tour " · AGED" leaves the name for the rank line), the pilot's SCENARIOS poster (tile; SEBULBA and
-- the pods: figure = {full, crop} on the empty poster), the game's model names (vehicles.modelName) and the CHOOSE
-- MODEL window, the livery value, the kit label, POWER / ENERGY as numbers, the short detail tags (perks.detail style
-- "v2"), the READY rows by P1's input mode (pad: START / SAVE on P1's card; mouse + keyboard: they are setup's command
-- row, and P1's READY cursor paints there through setup.commandFocus) and sentence-case hints with per-class maxima.
-- Status (§6.5): the join hint and ALL READY are entries of setup's status pill; the "P1 PILOT · P2 PERKS" summary is
-- gone (every card's rail shows its stage). M.lastPilotThumb(ctrlId) gives the lobby's players strip a head shot. The
-- input model (P1 sink, guests polled, keyboard, mouse filter) is unchanged in both styles.
-- VERIFY ids (§14): V-FIN-11 (P1's READY card and the command row switch together; START never shown twice).

local C        = require("consts")
local cfg      = require("config")
local settings = require("settings")
local St       = require("state")
local U        = require("util")
local V        = require("vehicles")
local D        = require("perkdata")

local M = {}
local TAG = "racers"

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local function num(name, default)
    local v = tonumber(cfg[name])
    if v == nil then return default end
    return v
end

local floor, abs = math.floor, math.abs

-- Everything but G1, vehicles and perkdata is reached lazily (ARCH §4.0; spec §5.1 require rules).
-- 0.12.0: CD() is this page's card renderer, "cards" | "cards2" (M.build picks it by cfg.UiStyle); cards.lua before
-- the first build (every call that can come that early is guarded).
local function CD()
    local s = St.racers
    return U.mod((type(s) == "table" and s.renderer) or "cards")
end
local function K() return U.mod("perks") end
local function P() return U.mod("pilots") end
local function PA() return U.mod("perkapply") end
local function ui() return U.mod("ui") end
local function setupM() return U.mod("setup") end
local function TH() return U.mod("theme") end              -- 0.12.0 v2 only: P1's input mode (theme.inputMode)
local function Q() return U.mod("quick") end                -- 0.13.0 QUICK RACE (settings PlayMode)

-- 4-WAY GARAGE (garage4.lua, cfg.Garage4Way; docs/dev/guest-garage.md section 8): A on a card's VEHICLE stage opens
-- every player's garage area at once; while it is open every event of every player (dispatch) goes to HIS area only,
-- the cards wait (no renders) and the bays show each area's car with its livery. DONE / B closes an area; when every
-- area is done the garage closes and each card that was on VEHICLE goes on (PERKS / READY), the others stay where they
-- were. The model picked there is the card's preset; the livery goes with the pick (choicePlayers pick.livery).
local function G4()
    local ok, g = pcall(U.mod, "garage4")
    return (ok and type(g) == "table") and g or nil
end
local function g4Open()
    local g = G4()
    local ok, on = pcall(function() return g and g.isOpen() end)
    return ok and on == true
end
local function g4Wanted()
    if opt("Garage4Way", false) ~= true then return false end
    local g = G4()
    local ok, on = pcall(function() return g and g.wanted() end)
    return ok and on == true
end

-- vpreview stays optional as in setup.lua: a load error leaves every card on its 2D art.
local vpMod = nil
local function VP()
    if vpMod == nil then
        local ok, m = pcall(require, "vpreview")
        vpMod = (ok and type(m) == "table") and m or false
        if not vpMod then U.err(TAG, "vpreview.lua failed to load (%s): the cards show 2D art", tostring(m)) end
    end
    return vpMod or nil
end

---------------------------------------------------------------------------------------------------- constants
local STAGES = { "pilot", "vehicle", "perks", "ready" }
local STAGE_WORD = { pilot = "PILOT", vehicle = "VEHICLE", perks = "PERKS", ready = "READY" }
-- 0.13.0 easy builds: "surprise" (guest Y: random pilot + vehicle + kit, READY) and "copy" (guest X: P1's loadout on the
-- guest's own pilot, READY). P1's pad reaches the cards only through the 5-button sink (directions + accept), so these
-- are the guests' (friends') shortcuts; P1 keeps the KIT row and START AGAIN TO RACE ANYWAY.
local EVENTS = { up = true, down = true, left = true, right = true, accept = true, back = true, surprise = true,
                 copy = true }
local KEY_RACERS = "LastRaceRacers"
local TOAST_MS = 2000            -- a toast replaces the hint line this long (§2.9)
local SOUND_GAP_MS = 80          -- at most one card sound per 80 ms over all cards (§2.9)
local KB_DIR_MS = 300            -- a sink move this soon after a keyboard event is the arrow key's own CommonUI move
local KB_ACCEPT_MS = 1000        -- mouse+keyboard mode: a sink click is Enter / Space only this soon after its keybind
local REPEAT_MS = 250            -- P1 (sink, keyboard): the same direction again this soon is an auto-repeat
local KEEP_MS = 200              -- focus keeper period (§5.7.3)
local RECONCILE_MS = 1000        -- player list safety net (the "players" event is the normal path)
local DORMANT_MS = 1000          -- join hint refresh
local STATUS_MS = 250            -- status line refresh
local STATUS_HOLD_MS = 5000      -- another module's status (START gate, join, error) stays up this long (the 5 s window)
local SINK_LEAKS = 5             -- pad presses that left the sink before "P1 sink inactive" (§8.2)
local POLL_GAP_MS = 500          -- no poll for this long (lobby covered): the pads re-baseline, a queued click is dropped
local AUDIO_DT  = "/Game/Griffin/Audio/UI/DT_UI_Audio_ForceFeedback.DT_UI_Audio_ForceFeedback"
local AUDIO_LIB = "/Script/Griffin.Default__UIAudioLibrary"
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }

-- P1's input sink (§5.7.3): five WBP_Common_Btn as a plus in setup's W.sinkHost (96 x 96 su), 28 x 28 su each; c is the
-- centre. Ring order (CardP1Input "ring", Z5): index 0..4 = c, u, d, l, r.
local SINK_POS = { c = { 34, 34 }, u = { 34, 0 }, d = { 34, 68 }, l = { 0, 34 }, r = { 68, 34 } }
local SINK_KEYS = { "c", "u", "d", "l", "r" }
local NEIGHBOURS = { "u", "d", "l", "r" }
local NEIGHBOUR_DIR = { u = "up", d = "down", l = "left", r = "right" }
local NAV = { left = 0, right = 1, up = 2, down = 3 }          -- EUINavigation
local RULE_ESCAPE = 0                                            -- EUINavigationRule::Escape (Slate's geometric move)
-- ring: from button b, Up -> b+1, Down -> b-1, Left -> b+2, Right -> b-2 (mod 5); the index delta is the direction
local RING_DELTA = { [1] = "up", [4] = "down", [2] = "left", [3] = "right" }

-- Guests' pads (as setup.lua PADK): d-pad and left stick directions, A, B.
local PADK = {
    up = { "Gamepad_DPad_Up", "Gamepad_LeftStick_Up" }, down = { "Gamepad_DPad_Down", "Gamepad_LeftStick_Down" },
    left = { "Gamepad_DPad_Left", "Gamepad_LeftStick_Left" }, right = { "Gamepad_DPad_Right", "Gamepad_LeftStick_Right" },
    a = { C.KEY.A }, b = { C.KEY.B }, x = { C.KEY.X or "Gamepad_FaceButton_Left" }, y = { C.KEY.Y },
}

-- Hint glyph keys of cards.lua (the Xbox pad images; CardGlyphs "text" writes them as words).
local G_LR, G_UD = { "Dpad_Left", "Dpad_Right" }, { "Dpad_Top", "Dpad_Bottom" }
local G_UP, G_DN = { "Dpad_Top" }, { "Dpad_Bottom" }
local G_A, G_B, G_NONE = { "FaceButton_Bottom" }, { "FaceButton_Right" }, {}
local G_X, G_Y = { "FaceButton_Left" }, { "FaceButton_Top" }

-- 0.12.0 UI v2: hint entries per width class (§9.1 HINT.max), the CHOOSE MODEL window (§9.4; N has one title row
-- instead), the pod styles' icon (§9.3: perkdata gives them the pilot's head shot, RP6) and this module's two entries
-- of setup's status pill (§6.5).
local HINT_MAX = { W = 3, M = 3, N = 2 }
local MODEL_TILES = { W = 6, M = 4 }
local POD_STYLE_ICON = "Icons/VehicleArchetypes/T_UI_Vehicle_Plane_Icn"
local PILL_JOIN, PILL_READY = "racers.join", "racers.ready"

---------------------------------------------------------------------------------------------------- state
-- St.racers (diag: racers.status / dump / state):
--   players[ctrlId] = {ctrlId, pnum, pc, isP1, arch, stage, row = {[stage] = 0 (strip) | 1..n}, last = {[stage] = the
--     last row >= 1 (cursor memory)}, picker = nil | {slot, kind, cats, cat, items, sel (0 = category row)}, pilotId,
--     presetId, lo, follow = {vehicle, perks}, nav (a guest's pad edges and repeats), presses, toast, toastUntil,
--     backArmUntil, dirty, dirtyAt, pilotAt, view}
--   memory[ctrlId] = {pilot = {[arch] = id}, preset = {[arch] = id}, lo, last = id}: the session's picks (kept when a
--     pad leaves; last = the latest pilot pick in any class, for M.lastPilotThumb)
--   order = {ctrlId, ...}: card i shows order[i] (pnum i); p1 = P1's input counters and guards; visit = set from the
--   first enter until setup closes (MODE and back keeps every card; a new visit starts every card at PILOT)
--   0.12.0: renderer = "cards" | "cards2" and style = "classic" | "v2" (this page's, M.build); mode = P1's input mode
--   ("pad" | "mouse", the last poll's); cmdFocus = what setup.commandFocus was last told; pillJoin / pillReady = the
--   status-pill entries posted (text / signature); readySig = the READY flags the READY cards' pips show; namesFor /
--   namesWait = {[class key] = true}: the classes whose model-name read finished / reads this module waited for
local function S()
    local s = St.racers
    if type(s) ~= "table" then
        s = { active = false, built = false, visit = nil, ctx = nil, sink = nil, cls = nil, arch = nil, planet = nil,
              players = {}, memory = {}, order = {}, orderSig = nil, persisted = nil, classInfo = {}, action = nil,
              inPoll = false, allReady = nil, soundAt = -1e9, statusText = nil, statusAt = 0, statusHoldUntil = 0,
              dormant = nil, dormantV2 = nil, dormantAt = -1e9, reconcileAt = -1e9,
              renderer = nil, style = nil, mode = nil, cmdFocus = nil, pillJoin = nil, pillReady = nil, readySig = nil,
              namesFor = {}, namesWait = {},
              p1 = { acceptAt = nil, lastKbMs = -1e9, kbAcceptMs = -1e9, lastDir = nil, lastDirMs = -1e9,
                     lastKey = nil, lastKeyMs = -1e9, sawB = false, sinkEvents = 0, clicked = false, drops = 0,
                     leaks = 0, leaking = false, held = false, override = nil, ringAt = nil, keepNext = 0 } }
        St.racers = s
    end
    return s
end

-- Real milliseconds: setup.realMs (handed over in the build context), else the state clock.
local function nowMs()
    local s = St.racers
    local f = type(s) == "table" and type(s.ctx) == "table" and s.ctx.realMs or nil
    if type(f) == "function" then
        local ok, v = pcall(f)
        if ok and type(v) == "number" then return v end
    end
    return St.nowMs()
end

---------------------------------------------------------------------------------------------------- helpers
local function indexOf(list, v)
    for i = 1, #list do if list[i] == v then return i end end
    return nil
end

-- 0.13.0 QUICK RACE (quick.lua): no PERKS stage, every card races the Opponents tier kit (no traits); the player's
-- own build (pl.lo) stays as it was, for CUSTOM. A GALAXY RUN of this class (or one starting at the next launch) owns
-- the builds: quick mode stays out of it.
local function quickRace()
    local s = St.racers
    local ok, on = pcall(function() return Q().forRace(type(s) == "table" and s.arch or nil) end)
    return ok and on == true
end

-- The stage strip: PILOT / PERKS can be switched off (their defaults are used, §2.1); QUICK RACE has no PERKS.
local function stageList()
    local out = {}
    local quick = quickRace()
    for _, st in ipairs(STAGES) do
        local off = (st == "pilot" and opt("PilotStage", true) == false)
            or (st == "perks" and (quick or opt("PerkStage", true) == false))
        if not off then out[#out + 1] = st end
    end
    return out
end

local function kbP1() return settings.get("KeyboardIsP1") == true end

-- RC-11: with KeyboardIsP1 the guest on pad 1 (ControllerId 1, join.lua startOnlyFor) is also Slate user 0: its B is
-- P1's CommonUI Back ("Exit Game?"). That card ignores B and goes back through the strip.
local function padOneGuest(pl) return not pl.isP1 and pl.ctrlId == 1 and kbP1() end

local function nameOf(pl) return "P" .. tostring(pl and pl.pnum or "?") end
local function colourOf(pnum) return C.COLOURS[pnum] or C.COLOURS.Remote end
local function shortId(id) return (tostring(id):gsub("^DA_Racer_", ""):gsub("^DA_PlaneRacer_", "Pod")) end

-- The pilot-relative kits: "pilot" (the pilot's style kit) and "max" (it at level 10) follow a pilot change.
local function isPilotKit(lo) return type(lo) == "table" and (lo.kit == "pilot" or lo.kit == "max") end

local function markDirty(pl, now)
    if pl and not pl.dirty then pl.dirty, pl.dirtyAt = true, now or nowMs() end
end

local function toast(pl, text, now, ms)
    pl.toast, pl.toastUntil = text, now + (ms or TOAST_MS)
end

local function p1Player()
    local s = S()
    return s.players[s.order[1] or 0]
end

-- P1's input type (CommonInput: gamepad vs mouse + keyboard) through setup.p1Gamepad; unknown = gamepad, as there.
local function p1Gamepad()
    local okF, f = pcall(function() return setupM().p1Gamepad end)
    if okF and type(f) == "function" then
        local ok, v = pcall(f)
        if ok and type(v) == "boolean" then return v end
    end
    U.logOnce("racers.p1gamepad", TAG, "setup.p1Gamepad unavailable: P1 is treated as a gamepad user")
    return true
end

-- The class a card shows and races (pl.arch / pl.cls, set by restart): the page's class, except a GALACTIC GRAND PRIX
-- player's own speeder class (wantClass below). Every per-card read goes through these, never s.arch / s.cls: the
-- live2 bug was P2's card built from the page's (P1's) class while gp.prelaunch raced him on his own.
local function archOf(pl)
    if type(pl) == "table" and pl.arch ~= nil then return pl.arch end
    return S().arch
end
local function clsOf(pl)
    if type(pl) == "table" and type(pl.cls) == "table" then return pl.cls end
    return S().cls
end

local function pilotStyle(pl) return P().styleKey(pl.pilotId, archOf(pl)) end

-- The loadout the card's player races: QUICK RACE the tier kit (quick.loadout), else the card's own.
local function raceLo(pl)
    if quickRace() then
        local ok, lo = pcall(function() return Q().loadout(archOf(pl), pilotStyle(pl)) end)
        if ok and type(lo) == "table" then return lo end
    end
    return pl.lo
end

-- 0.13.0 GALAXY RUN (run.lua): a card whose player is in the run plays the run build (owned perks, level cap).
local function runM()
    local ok, r = pcall(U.mod, "run")
    return ok and type(r) == "table" and r or nil
end
local function inRun(pl)
    local r = runM()
    if not (r and r.active and r.active()) then return false end
    local st = r.state()
    return st ~= nil and st.players[pl.ctrlId] ~= nil and tonumber(st.arch) == tonumber(archOf(pl))
end

-- 0.16 GALACTIC GRAND PRIX (gp.lua): while a GP is on every card races the GP build: the style's kit, no parts and an
-- equal budget of stat levels (gp.cardLoadout / cardRaise); only levels and the racer style can be edited.
local function gpM()
    local ok, g = pcall(U.mod, "gp")
    return ok and type(g) == "table" and g or nil
end
local function inGP()
    local g = gpM()
    local ok, on = pcall(function() return g and g.owns() end)
    return ok and on == true
end
local function gpLoadout(pl, style, prev)
    local g = gpM()
    local ok, lo = pcall(g.cardLoadout, pl.ctrlId, pl.pnum, archOf(pl), style, prev)
    if ok and type(lo) == "table" then return lo end
    return nil
end

-- The class a player's card must show: a GALACTIC GRAND PRIX speeder race with per-player classes (gp.cardClass: the
-- class the GP races him in, "each" rule) gives each player his own speeder class, else the page's. -> arch, cls
local function wantClass(pl)
    local s = S()
    if s.arch ~= nil and tonumber(s.arch) ~= 1 and type(pl) == "table" and inGP() then
        local ok, key = pcall(function() return gpM().cardClass(pl.ctrlId) end)
        if ok and type(key) == "string" then
            local cls = V.classByKey(key)
            if type(cls) == "table" and tonumber(cls.arch) ~= 1 then return cls.arch, cls end
        end
    end
    return s.arch, s.cls
end

-- Width class of the card row ("W" 1-2 players, "M" 3, "N" 4) for the pilot crops and the roster tiles.
local function widthClass()
    local ok, c = pcall(function() return CD().cls() end)
    return (ok and c) or "W"
end

-- 0.12.0 §6.4: P1's input mode, "pad" | "mouse": theme.inputMode (P1's CommonInput type once stable for
-- InputModeDebounceMs; KeyboardIsP1 = "mouse"; setup.debugInputMode pins it through theme.forceInputMode), else
-- setup.p1Gamepad (undebounced). theme stamps the debounce with its own clock: no argument is passed. v2 pages only;
-- the input handling below keeps p1Gamepad (unchanged).
local function p1Mode()
    local ok, m = pcall(function() return TH().inputMode() end)
    if ok and (m == "pad" or m == "mouse") then return m end
    U.logOnce("racers.inputmode", TAG, "theme.inputMode unavailable (%s): P1's input mode from setup.p1Gamepad",
        tostring(m))
    return (p1Gamepad() and not kbP1()) and "pad" or "mouse"
end

-- The input mode a card shows (vm.inputMode, the READY rows, P1's hints): P1's from the last poll (read now before
-- the first one), every guest "pad".
local function modeOf(pl)
    if not pl or not pl.isP1 then return "pad" end
    local s = S()
    if s.mode == nil then s.mode = p1Mode() end
    return s.mode
end

---------------------------------------------------------------------------------------------------- memory
local function memOf(ctrlId)
    local s = S()
    local m = s.memory[ctrlId]
    if not m then
        m = { pilot = {}, preset = {}, lo = nil }
        s.memory[ctrlId] = m
    end
    return m
end

-- Every pick change: the session memory (pilot and preset per class; one loadout, validated per class on use, §2.4).
local function remember(pl)
    local arch = archOf(pl)
    if arch == nil then return end
    local m = memOf(pl.ctrlId)
    m.pilot[arch], m.preset[arch] = pl.pilotId, pl.presetId
    m.last = pl.pilotId or m.last                -- 0.12.0: the lobby strip's head shot (M.lastPilotThumb)
    -- 0.13.0: a run build never replaces the player's own build (0.16: nor a GALACTIC GRAND PRIX build)
    if not inRun(pl) and not inGP() then m.lo = K().copy(pl.lo) end
end

-- settings LastRaceRacers "<ctrlId>=<pilot>@<preset>@<loadout code>;..." (§7.1) -> {[ctrlId] = {pilot, preset, code}}.
-- A loadout code never holds ";", "=" or "@" (perks.encode). Exported as M.parseRacers (setup.deriveSetup).
local function parseRacers(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for entry in text:gmatch("[^;]+") do
        local c, pilot, preset, code = entry:match("^%s*(%d+)=([%w_]*)@([%w_]*)@(.-)%s*$")
        c = tonumber(c)
        if c then
            out[c] = { pilot = (pilot ~= "") and pilot or nil, preset = (preset ~= "") and preset or nil,
                       code = (code ~= "") and code or nil }
        end
    end
    return out
end

-- A pad's persisted picks: the second default source after the session memory (§2.4). Read once per visit.
local function persisted(ctrlId)
    local s = S()
    if s.persisted == nil then
        local ok, v = pcall(settings.get, KEY_RACERS)
        s.persisted = parseRacers(ok and v or nil)
    end
    return s.persisted[ctrlId]
end

---------------------------------------------------------------------------------------------------- picks
-- {[pilotId] = ctrlId} of every human's current pick, whatever the stage (pilots.holder skips the asker's own).
local function takenMap()
    local t = {}
    for c, pl in pairs(S().players) do
        if pl.pilotId then t[pl.pilotId] = c end
    end
    return t
end

-- The first model no other player drives (its standard livery), else vehicles.defaultPresetIndex (§2.4).
local function freePreset(pl)
    local s = S()
    local arch = archOf(pl)
    local used = {}
    for c, o in pairs(s.players) do
        if c ~= pl.ctrlId and o.presetId and archOf(o) == arch then
            local _, _, m = V.modelOf(arch, o.presetId)
            if m then used[m.base] = true end
        end
    end
    for _, m in ipairs(V.models(arch)) do
        if not used[m.base] and m.presets[1] then return m.presets[1].id end
    end
    local p = V.presets(arch)[V.defaultPresetIndex(arch, pl.pnum)]
    return p and p.id or nil
end

-- A loadout for (class, pilot style): an unedited kit of the class's KIT row is rebuilt for this class and pilot (the
-- RC-2 refills of perks.fromKit apply: a REDLINER kit taken into a pod), an edited one ("custom") is validated for the
-- class; none = the pilot's style kit. The pilot's own style kit picked as "s_<Key>" is the same loadout as "pilot" and
-- takes that name (it then follows the pilot again).
local function fitLoadout(lo, arch, style)
    local Km = K()
    if type(lo) ~= "table" then return (Km.fromKit("pilot", arch, style)) end
    local kit = lo.kit
    if kit == "s_" .. tostring(style) then kit = "pilot" end
    if kit ~= "custom" and (kit == "pilot" or indexOf(Km.kits(arch, style), kit)) then
        return (Km.fromKit(kit, arch, style, lo))
    end
    return (Km.validate(lo, arch, style))
end

-- §2.4 defaults of a (re)started card, first rule that applies:
--   pilot   session memory -> LastRaceRacers -> pilots.defaultFor (P1: SHADE / favourite; guests: the first free class
--           specialist; the first free pilot); a class change keeps the current pilot first when the class allows it
--           and nobody else holds it (§2.7);
--   vehicle memory -> persisted (same class) -> the pilot's signature -> the first model nobody else drives;
--   loadout memory -> persisted -> the pilot's style kit (each validated for the class).
-- how = "new" (joined) | "visit" (a new visit) | "class" (class change); old = the pilot before.
local function defaultPicks(pl, how, old)
    local arch, Pm, Km = archOf(pl), P(), K()
    local mem, per = memOf(pl.ctrlId), persisted(pl.ctrlId) or {}
    local remembered = {}
    local function add(id) if type(id) == "string" then remembered[#remembered + 1] = id end end
    if how == "class" then add(old) end
    add(mem.pilot[arch])
    add(per.pilot)
    if how ~= "class" then add(old) end
    local e = Pm.defaultFor(arch, pl.isP1, takenMap(), remembered, pl.ctrlId)
    pl.pilotId = e.id
    local style = Pm.styleKey(e, arch)
    local function known(id) return type(id) == "string" and V.presetById(arch, id) ~= nil end
    pl.presetId = (known(mem.preset[arch]) and mem.preset[arch]) or (known(per.preset) and per.preset)
        or Pm.signature(e, arch) or freePreset(pl)
    local lo = mem.lo
    if type(lo) ~= "table" and per.code then lo = (Km.decode(per.code, arch, style)) end
    pl.lo = fitLoadout(lo, arch, style)
    local r = runM()
    if r and r.buildFor then
        local okB, rb = pcall(r.buildFor, pl.ctrlId, arch, style)
        if okB and type(rb) == "table" then pl.lo = rb end
    end
    if inGP() then pl.lo = gpLoadout(pl, style, nil) or pl.lo end      -- 0.16 GALACTIC GRAND PRIX
end

local function freshRows() return { pilot = 1, vehicle = 1, perks = 1, ready = 1 } end

local function newPlayer(e)
    return { ctrlId = e.ctrlId, pnum = e.pnum, pc = e.pc, isP1 = e.pnum == 1, arch = nil, cls = nil, stage = nil,
             row = freshRows(), last = freshRows(), picker = nil, pilotId = nil, presetId = nil, lo = nil,
             follow = { vehicle = true, perks = true }, nav = { primed = false, prev = {}, dirMs = {} },
             presses = 0, toast = nil, toastUntil = 0, backArmUntil = 0, dirty = true, dirtyAt = 0, pilotAt = 0,
             view = "" }
end

-- A card (re)starts at the first stage with fresh rows and its default picks (a join, a new visit, a class change).
local function restart(pl, how, now, old)
    local s = S()
    pl.arch, pl.cls = wantClass(pl)
    pl.stage = stageList()[1]
    -- RC-2: a card in another class than the page (GALACTIC GRAND PRIX) gets its class's system flags first
    if pl.arch ~= s.arch then U.try(TAG, function() PA().systems(pl.arch) end) end
    pl.row, pl.last, pl.picker = freshRows(), freshRows(), nil
    pl.toast, pl.toastUntil, pl.backArmUntil, pl.presses = nil, 0, 0, 0
    pl.follow.vehicle = true                 -- "the player has not changed MODEL / LIVERY in this setup"
    defaultPicks(pl, how, old)
    pl.follow.perks = isPilotKit(pl.lo)
    pl.pilotAt = now
    if inRun(pl) then
        local okO, pk = pcall(runM().offerPicker, pl.ctrlId)
        local okS, sk = pcall(runM().shopPicker, pl.ctrlId)
        if okO and type(pk) == "table" then
            pl.stage, pl.picker = "perks", pk
            pl.toast, pl.toastUntil = "PICK YOUR RUN REWARD", now + 4000
        elseif okS and type(sk) == "table" then
            pl.stage, pl.picker = "perks", sk
            pl.toast, pl.toastUntil = "SHOP: BUY WITH A, B TO LEAVE", now + 4000
        else
            local okL, line = pcall(runM().cardLine, pl.ctrlId)
            if okL and line then pl.toast, pl.toastUntil = line, now + 4000 end
        end
    else
        local r = runM()
        local okA, on = pcall(function() return r and r.active() and tonumber(r.state().arch) == tonumber(archOf(pl)) end)
        if okA and on then   -- a late joiner: in the run from the next launch, on a starter build + one free pick
            pl.toast, pl.toastUntil = "JOINS THE GALAXY RUN ON A STARTER BUILD", now + 4000
        end
    end
    if inGP() then
        local okG, line = pcall(function() return gpM().cardLine(pl.pnum) end)
        if okG and line then pl.toast, pl.toastUntil = line, now + 4000 end
    end
    remember(pl)
    markDirty(pl, now)
    U.dbg(TAG, "%s card %s at %s: pilot %s, %s, kit %s", nameOf(pl), how, tostring(pl.stage), tostring(pl.pilotId),
        tostring(pl.presetId), tostring(pl.lo and pl.lo.kit))
end

---------------------------------------------------------------------------------------------------- players
-- P1 + the joined guests in view order (as setup.lua localPlayers): {{pnum, ctrlId, pc}, ...}.
local function localPlayers()
    local list = { { pnum = 1, ctrlId = 0, pc = U.p1() } }
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do
            list[#list + 1] = { pnum = e.pnum, ctrlId = e.ctrlId, pc = e.pc }
        end
    end)
    return list
end

-- Where each player's view will be (as setup.lua viewName / viewSlot: split.lua's layout rules, every local player's
-- position in GameInstance.LocalPlayers, dormant guests included).
local function viewName(i, n)
    if n <= 1 then return "FULL SCREEN" end
    if n == 2 then
        if settings.get("Layout2P") == "side-by-side" then return i == 1 and "LEFT" or "RIGHT" end
        return i == 1 and "TOP" or "BOTTOM"
    end
    if n == 3 then return ({ "TOP", "BOTTOM LEFT", "BOTTOM RIGHT" })[i] or "?" end
    return ({ "TOP LEFT", "TOP RIGHT", "BOTTOM LEFT", "BOTTOM RIGHT" })[i] or "?"
end

local function viewLabel(pc, i, n)
    local lps = {}
    for _, lp in ipairs(U.localPlayers()) do if U.ok(lp.pc) then lps[#lps + 1] = lp end end
    if #lps < n then return viewName(i, n) end
    for k, lp in ipairs(lps) do
        if U.same(lp.pc, pc) then return viewName(k, #lps) end
    end
    return viewName(i, #lps)
end

-- The cards follow the local players: a joiner gets a fresh card at the first stage (its join press is the input
-- baseline), a leaver's card goes and its bay is released (its picks stay in memory), restartAll (a new visit) and a
-- class change restart the cards in view order, each seeing the picks made before it. Returns true when it changed.
local function reconcile(why, restartAll, now)
    local s = S()
    local list = localPlayers()
    local ids, stale = {}, false
    for i, e in ipairs(list) do
        ids[i] = tostring(e.ctrlId)
        local pl = s.players[e.ctrlId]
        if pl and pl.arch ~= (wantClass(pl)) then stale = true end
    end
    local sig = table.concat(ids, ",")
    if not restartAll and not stale and sig == s.orderSig then
        for _, e in ipairs(list) do
            local pl = s.players[e.ctrlId]
            if pl then pl.pc = e.pc end
        end
        return false
    end
    s.orderSig = sig
    if g4Open() then U.try(TAG, G4().close, "players changed: the cards first") end
    local seen = {}
    for _, e in ipairs(list) do seen[e.ctrlId] = true end
    local gone = {}
    for c in pairs(s.players) do if not seen[c] then gone[#gone + 1] = c end end
    if #gone > 0 then
        -- every render image lets go of its target first: the card indices shift (cards.releaseRenders, then vpreview)
        pcall(function() CD().releaseRenders(nil) end)
        for _, c in ipairs(gone) do
            local pl = s.players[c]
            s.players[c] = nil
            local vp = VP()
            if vp then U.try(TAG, vp.release, c + 1, nameOf(pl) .. " left", true) end
            U.log(TAG, "%s (ControllerId %d) left: card removed, bay released, picks kept for the pad (V-RC-04)",
                nameOf(pl), c)
        end
    end
    local fresh = {}
    s.order = {}
    for i, e in ipairs(list) do
        local pl = s.players[e.ctrlId]
        local how = nil
        if not pl then
            pl = newPlayer(e)
            s.players[e.ctrlId] = pl
            how = "new"
        elseif restartAll then
            how = "visit"                        -- a new visit replays the remembered picks, whatever class came before
        elseif pl.arch ~= (wantClass(pl)) then
            how = "class"
        end
        pl.pnum, pl.pc, pl.isP1 = i, e.pc, i == 1
        s.order[i] = e.ctrlId
        if how then fresh[#fresh + 1] = { pl = pl, how = how, old = pl.pilotId } end
    end
    for _, f in ipairs(fresh) do f.pl.pilotId, f.pl.presetId = nil, nil end
    for _, f in ipairs(fresh) do restart(f.pl, f.how, now, f.old) end
    local n = #s.order
    local names = {}
    for i, c in ipairs(s.order) do
        local pl = s.players[c]
        pl.view = viewLabel(pl.pc, i, n)
        markDirty(pl, now)
        names[#names + 1] = string.format("%s c%d %s %s/%s", nameOf(pl), c, STAGE_WORD[pl.stage] or "?",
            shortId(pl.pilotId), tostring(pl.presetId))
    end
    pcall(function() CD().layout(n) end)
    s.allReady = nil
    U.log(TAG, "players (%s): %s", tostring(why), table.concat(names, ", "))
    return true
end

---------------------------------------------------------------------------------------------------- sounds
local soundObjs = { al = nil, dt = nil }
local function play(pc, row)
    pcall(function()
        if not U.ok(soundObjs.al) then soundObjs.al = U.cdo(AUDIO_LIB) end
        if not U.ok(soundObjs.dt) then soundObjs.dt = U.obj(AUDIO_DT) end
        if U.ok(soundObjs.al) and U.ok(soundObjs.dt) and U.ok(pc) then
            -- UIAudioLibrary::Play2DAudioFromTable(Object WorldContextObject, DataTable Table, Name RowName) [V JMAP, cmap]
            -- on that player's PC: the force-feedback row rumbles the right pad
            soundObjs.al:Play2DAudioFromTable(pc, soundObjs.dt, U.fname(row))
        end
    end)
end

-- §2.9 + RC-6. CardSounds "match": guests' navigation ticks + everybody's accept / equip / stage-change sound; "accept":
-- accept sounds only; "off". P1 never gets a navigation sound from here (the sink's WBP_Common_Btn plays MainNavigation
-- on every focus it receives) nor one for a sink click (its BP plays MainAccept; a keyboard Enter clicks the sink too):
-- only P1's keyboard path without the sink (src "key") gets ours. At most one sound per 80 ms over all cards.
-- VERIFY(V-RC-30): guests tick per move; two ticks per P1 sink press, one accept.
local function sound(pl, kind, src, now)
    local mode = opt("CardSounds", "match")
    if mode == "off" or (kind ~= "nav" and kind ~= "accept") then return end
    if kind == "nav" and mode ~= "match" then return end
    if pl.isP1 and (kind == "nav" or src ~= "key") then return end
    local s = S()
    if now - s.soundAt < SOUND_GAP_MS then return end
    s.soundAt = now
    play(pl.pc, kind == "nav" and "MainNavigation" or "MainAccept")
end

---------------------------------------------------------------------------------------------------- events (§2.2)
-- Handlers return nil (nothing happened) or what happened: "nav" (cursor / value move), "accept" (accept, equip, stage
-- change) or "quiet" (a toast only). P1's START / SAVE / MODE are queued in s.action and run outside the input pass
-- (flushAction): they close or leave the step.

local function setRow(pl, r)
    pl.row[pl.stage] = r
    if r >= 1 then pl.last[pl.stage] = r end
end

local function goStage(pl, st, how, now)
    local was = pl.stage
    pl.stage, pl.picker = st, nil
    if how == "forward" then
        setRow(pl, 1)                        -- A, A, A from a fresh card always reaches READY (PERKS opens on KIT)
    elseif how == "strip" then
        pl.row[st] = 0                       -- the cursor stays on the strip
    else
        setRow(pl, pl.last[st] or 1)         -- back: that stage's last row
    end
    if st == "ready" and was ~= "ready" then
        -- VERIFY(V-RC-14): "P2 READY after 3 presses" with the signature preset and the style kit from a fresh card
        U.log(TAG, "%s READY after %d presses (pilot %s, %s, kit %s) (V-RC-14)", nameOf(pl), pl.presses,
            tostring(pl.pilotId), tostring(pl.presetId), tostring(pl.lo and pl.lo.kit))
    elseif was == "ready" and st ~= "ready" then
        U.dbg(TAG, "%s not ready (%s)", nameOf(pl), st)
    end
end

-- Back from the first stage. Guests: a toast (leaving = B held 1 s, join.lua). P1 (V-RC-08): the first back arms
-- CardP1BackConfirmMs with "BACK AGAIN: MODE STEP", a second one inside it goes to MODE (setup.back; every card keeps
-- its state, §2.7).
local BACK_TOAST = "BACK AGAIN: MODE STEP"
local function backRule(pl, now)
    if not pl.isP1 then
        toast(pl, padOneGuest(pl) and "HOLD START TO LEAVE" or "HOLD B TO LEAVE", now)
        return "quiet"
    end
    pl.backHit = true                            -- dispatch keeps the window armed for this event only
    if now < pl.backArmUntil then
        pl.backArmUntil, pl.toast = 0, nil
        S().action = "back"
        U.log(TAG, "P1 back twice at %s: MODE step (V-RC-08)", STAGE_WORD[pl.stage] or "?")
        return "accept"
    end
    local ms = num("CardP1BackConfirmMs", 3000)
    pl.backArmUntil = now + ms
    toast(pl, BACK_TOAST, now, ms)
    return "quiet"
end

local function forward(pl, now)
    local list = stageList()
    local i = indexOf(list, pl.stage) or 1
    if i >= #list then return nil end
    goStage(pl, list[i + 1], "forward", now)
    return "accept"
end

local function backward(pl, now)
    local list = stageList()
    local i = indexOf(list, pl.stage) or 1
    if i <= 1 then return backRule(pl, now) end
    goStage(pl, list[i - 1], "back", now)
    return "accept"
end

-- §2.4 follow rules on a pilot change: the vehicle becomes the new pilot's signature while MODEL / LIVERY were not
-- touched in this setup or the preset is the old pilot's signature; a pilot-relative kit follows the pilot, any other
-- loadout is kept (toast LOADOUT KEPT). The other PILOT cards re-render: their rosters tag who holds what.
local function setPilot(pl, id, now)
    local s = S()
    local Pm, arch = P(), archOf(pl)
    local oldId = pl.pilotId
    local oldSig = Pm.signature(oldId, arch)
    pl.pilotId, pl.pilotAt = id, now
    local sig = Pm.signature(id, arch)
    if sig and (pl.follow.vehicle or pl.presetId == oldSig) then pl.presetId = sig end
    local style = Pm.styleKey(id, arch)
    if isPilotKit(pl.lo) then
        pl.lo = (K().fromKit(pl.lo.kit, arch, style))
    else
        if pl.lo.kit == "s_" .. style then pl.lo.kit = "pilot" end   -- the new pilot's own style kit: the same loadout
        -- 0.12.0: a kept custom loadout names the kit it came from; "pilot" / "max" would now name the new pilot's
        -- style (live 2026-10-10: TECH EXPERT traits under "FROM AFTERBURNER"), so they become the old style's kit
        if pl.lo.kit == "custom" then
            local oldStyle = oldId and Pm.styleKey(oldId, arch)
            if (pl.lo.from == "pilot" or pl.lo.from == "max") and oldStyle and oldStyle ~= style then
                pl.lo.from = "s_" .. oldStyle
            elseif pl.lo.from == "s_" .. style then
                pl.lo.from = "pilot"
            end
        end
        if not quickRace() and not inGP() then toast(pl, "LOADOUT KEPT", now) end   -- QUICK RACE: nobody's build is shown
    end
    -- 0.16 GALACTIC GRAND PRIX: the new pilot's style kit (a pod: the new pod's own build), the same levels
    if inGP() then pl.lo = gpLoadout(pl, style, pl.lo) or pl.lo end
    pl.follow.perks = isPilotKit(pl.lo)
    remember(pl)
    for _, o in pairs(s.players) do
        if o ~= pl and o.stage == "pilot" then markDirty(o, now) end
    end
end

-- PILOT row: the previous / next pilot nobody else holds (§2.8, V-RC-09).
local function stepPilot(pl, d, now)
    local e = P().step(archOf(pl), pl.pilotId, d, takenMap(), pl.ctrlId)
    if not e then
        toast(pl, "NO OTHER PILOT IS FREE", now)
        return "quiet"
    end
    setPilot(pl, e.id, now)
    return "nav"
end

-- MODEL row: the next base model, on the pilot's signature livery when it has one, else its standard livery (§4.2).
local function stepModel(pl, d)
    local arch = archOf(pl)
    local models = V.models(arch)
    if #models < 2 then return nil end
    local mi = V.modelOf(arch, pl.presetId) or 1
    mi = ((mi - 1 + d) % #models) + 1
    local p = V.modelPreset(arch, mi, P().signature(pl.pilotId, arch))
    if not p then return nil end
    pl.presetId, pl.follow.vehicle = p.id, false
    remember(pl)
    return "nav"
end

-- LIVERY row: the model's presets (standard first, then the owner liveries).
local function stepLivery(pl, d)
    local _, li, m = V.modelOf(archOf(pl), pl.presetId)
    if not m or #m.presets < 2 then return nil end
    li = ((li - 1 + d) % #m.presets) + 1
    pl.presetId, pl.follow.vehicle = m.presets[li].id, false
    remember(pl)
    return "nav"
end

-- After a PERKS edit (perks.lua made the loadout "custom" unless it was a KIT change): follow flag, memory, toast.
local function afterEdit(pl, toastText, now)
    pl.follow.perks = isPilotKit(pl.lo)
    remember(pl)
    if toastText then toast(pl, toastText, now) end
end

-- PERKS L/R quick change of the slot under the cursor (§2.5).
local function cycleSlot(pl, slot, d, now)
    local kindR, nR = K().slotKind(slot)
    local capR = nil
    if inRun(pl) then
        if kindR ~= "tune" and kindR ~= "style" then
            toast(pl, (kindR == "kit") and "GALAXY RUN: YOUR RUN BUILD" or "GALAXY RUN: PICK WITH A", now)
            return "nav"
        end
        capR = runM().capFor(pl.ctrlId)
        if kindR == "tune" and capR and d > 0 and (pl.lo.tune[nR] or 0) >= capR then
            toast(pl, "LEVEL CAP " .. tostring(capR) .. ": WIN REWARDS TO RAISE IT", now)
            return "nav"
        end
    end
    if inGP() then                                       -- 0.16 GALACTIC GRAND PRIX: levels (budget) and style only
        if kindR ~= "tune" and kindR ~= "style" then
            toast(pl, "GRAND PRIX: LEVELS AND STYLE ONLY", now)
            return "nav"
        end
        if kindR == "tune" and d > 0 then
            local okR, can, why = pcall(function() return gpM().cardRaise(pl.lo, nR, pl.pnum) end)
            if okR and can == false then toast(pl, why or "GRAND PRIX", now); return "nav" end
        end
    end
    local _, changed, toastText = K().cycle(pl.lo, slot, d, archOf(pl), pilotStyle(pl))
    if not changed then return nil end
    if inGP() and kindR == "style" then                    -- the new style's kit, the same levels
        pl.lo = gpLoadout(pl, pl.lo.style, pl.lo) or pl.lo
    end
    afterEdit(pl, toastText, now)
    return "nav"
end

-- PERKS A: the slot's picker, on the equipped item's category and row (§2.5).
local function withRunFilter(pl, fn, ...)
    local Km = K()
    if inRun(pl) then Km.itemFilter = runM().filterFor(pl.ctrlId) end
    local ok, a, b = pcall(fn, ...)
    Km.itemFilter = nil
    if not ok then error(a, 0) end
    return a, b
end

local function openPicker(pl, slot)
    if inGP() and K().slotKind(slot) ~= "style" then         -- 0.16: no parts / abilities to pick in a Grand Prix
        toast(pl, "GRAND PRIX: LEFT / RIGHT SETS THE LEVELS", nowMs())
        return "nav"
    end
    local pk = withRunFilter(pl, K().picker, pl.lo, slot, archOf(pl))
    if not pk or #pk.items == 0 then return nil end
    pl.picker = { slot = slot, kind = pk.kind, cats = pk.cats, cat = pk.cat, items = pk.items, sel = pk.sel }
    return "accept"
end

-- Picker A on an item: equip (a family / ladder / trait held by another slot is swapped) and close.
local function equip(pl, slot, id, now)
    if id == nil then id = false end
    local _, toastText, changed = K().equip(pl.lo, slot, id, archOf(pl), pilotStyle(pl))
    if changed and inGP() then pl.lo = gpLoadout(pl, pl.lo.style, pl.lo) or pl.lo end   -- 0.16: a style pick
    pl.picker = nil
    if changed then afterEdit(pl, toastText, now) elseif toastText then toast(pl, toastText, now) end
    return "accept"
end

local HANDLERS = {}
local easyBuild                                  -- 0.13.0, defined before dispatch

-- Row 0, the stage strip: left / right = previous / next stage (fresh presses only; left at the first stage = the back
-- rule), down / A = the stage's last row (cursor memory), back = as left.
local function onStrip(pl, ev, rep, now)
    if ev == "down" or ev == "accept" then
        setRow(pl, pl.last[pl.stage] or 1)
        return "nav"
    end
    if ev == "left" or ev == "right" or ev == "back" then
        if rep then return nil end
        local list = stageList()
        local j = (indexOf(list, pl.stage) or 1) + ((ev == "right") and 1 or -1)
        if j < 1 then return backRule(pl, now) end
        if j > #list then return nil end
        goStage(pl, list[j], "strip", now)
        return "accept"
    end
    return nil
end

HANDLERS.pilot = function(pl, ev, rep, now, r)
    if ev == "up" then setRow(pl, 0); return "nav" end
    if ev == "left" or ev == "right" then return stepPilot(pl, (ev == "right") and 1 or -1, now) end
    if ev == "accept" then return forward(pl, now) end
    if ev == "back" then return backward(pl, now) end
    return nil
end

local openGarage                                -- 4-way garage (defined after dispatch's helpers)

HANDLERS.vehicle = function(pl, ev, rep, now, r)
    if ev == "up" then setRow(pl, r - 1); return "nav" end
    if ev == "down" then
        if r < 2 then setRow(pl, r + 1); return "nav" end
        return nil
    end
    if ev == "left" or ev == "right" then
        local d = (ev == "right") and 1 or -1
        if r == 1 then return stepModel(pl, d) end
        return stepLivery(pl, d)
    end
    if ev == "accept" then
        if g4Wanted() then
            local what = openGarage(pl, now)
            if what then return what end
        end
        return forward(pl, now)
    end
    if ev == "back" then return backward(pl, now) end
    return nil
end

-- PERKS board (K.slots order): A on KIT = READY, on an upgrade = the next row, anywhere else = the picker; down wraps.
HANDLERS.perks = function(pl, ev, rep, now, r)
    local Km = K()
    local slots = Km.slots(archOf(pl))
    local n = #slots
    if r > n then r = n; setRow(pl, r) end
    local slot = slots[r]
    if ev == "up" then setRow(pl, r - 1); return "nav" end
    if ev == "down" then setRow(pl, (r % n) + 1); return "nav" end
    if ev == "left" or ev == "right" then return cycleSlot(pl, slot, (ev == "right") and 1 or -1, now) end
    if ev == "accept" then
        local kind = Km.slotKind(slot)
        if kind == "kit" then return forward(pl, now) end
        if kind == "tune" then setRow(pl, (r % n) + 1); return "nav" end
        return openPicker(pl, slot)
    end
    if ev == "back" then return backward(pl, now) end
    return nil
end

-- READY: P1 row 1 START RACE / row 2 SAVE AND RETURN (setup.finish runs the START gates), a guest's row has nothing
-- to start (the accept sound only); back = PERKS, un-ready (§2.6).
HANDLERS.ready = function(pl, ev, rep, now, r)
    local rows = pl.isP1 and 2 or 1
    if ev == "up" then setRow(pl, r - 1); return "nav" end
    if ev == "down" then
        if r < rows then setRow(pl, r + 1); return "nav" end
        return nil
    end
    if ev == "accept" then
        if pl.isP1 then S().action = (r == 2) and "save" or "start" end
        return "accept"
    end
    if ev == "back" then return backward(pl, now) end
    return nil
end

-- Picker: row 0 = the category row (left / right = category, wrapping; a fresh up there cancels), 1..n = items.
local function onReward(pl, ev, now)
    local pk = pl.picker
    local n = #pk.items
    if ev == "up" or ev == "down" then
        local j = pk.sel + ((ev == "up") and -1 or 1)
        if j < 1 or j > n then return nil end
        pk.sel = j
        pk.slot = pk.items[j].slot or pk.slot
        return "nav"
    end
    if ev == "accept" then
        local it = pk.items[pk.sel]
        if not it then return nil end
        local okC, lo, toastText = pcall(runM().claim, pl.ctrlId, it, archOf(pl), pilotStyle(pl))
        pl.picker = nil
        if okC and type(lo) == "table" then
            pl.lo = lo
            afterEdit(pl, toastText, now)
        end
        local okS, sk = pcall(runM().shopPicker, pl.ctrlId)       -- v2: the shop right after the free pick
        if okS and type(sk) == "table" then pl.picker = sk end
        return "accept"
    end
    if ev == "back" then toast(pl, "PICK ONE REWARD (A)", now); return "nav" end
    return nil
end

-- 0.13.0 v2 GALAXY RUN shop: up / down choose, A buys (the picker is rebuilt with the new stock and credits),
-- B or the LEAVE row closes it.
local function onShop(pl, ev, now)
    local pk = pl.picker
    local n = #pk.items
    if ev == "up" or ev == "down" then
        local j = pk.sel + ((ev == "up") and -1 or 1)
        if j < 1 or j > n then return nil end
        pk.sel = j
        pk.slot = pk.items[j].slot or pk.slot
        return "nav"
    end
    if ev == "back" then
        pcall(runM().buy, pl.ctrlId, { rkind = "leave" }, archOf(pl), pilotStyle(pl))
        pl.picker = nil
        return "nav"
    end
    if ev == "accept" then
        local it = pk.items[pk.sel]
        if not it then return nil end
        local okB, lo, toastText, nextPk = pcall(runM().buy, pl.ctrlId, it, archOf(pl), pilotStyle(pl))
        if not okB then pl.picker = nil; return "nav" end
        if type(lo) == "table" then pl.lo = lo; afterEdit(pl, nil, now) end
        if toastText then toast(pl, toastText, now) end
        if type(nextPk) == "table" then
            nextPk.sel = math.min(pk.sel, #nextPk.items)
            nextPk.slot = nextPk.items[nextPk.sel].slot or nextPk.slot
            pl.picker = nextPk
        else
            pl.picker = nil
        end
        return "accept"
    end
    return nil
end

local function onPicker(pl, ev, rep, now)
    local pk = pl.picker
    if pk.kind == "reward" then return onReward(pl, ev, now) end
    if pk.kind == "shop" then return onShop(pl, ev, now) end
    local n = #pk.items
    if ev == "up" then
        if pk.sel > 0 then pk.sel = pk.sel - 1; return "nav" end
        if rep then return nil end
        pl.picker = nil
        return "nav"
    end
    if ev == "down" then
        if pk.sel < n then pk.sel = pk.sel + 1; return "nav" end
        return nil
    end
    if ev == "left" or ev == "right" then
        if #pk.cats < 2 then return nil end
        local ci = ((pk.cat - 1 + ((ev == "right") and 1 or -1)) % #pk.cats) + 1
        local items, sel = withRunFilter(pl, K().pickerCat, pl.lo, pk.slot, archOf(pl), ci)
        pk.cat, pk.items, pk.sel = ci, items, sel
        return "nav"
    end
    if ev == "accept" then
        if pk.sel == 0 then
            if n == 0 then return nil end
            pk.sel = 1
            return "nav"
        end
        local it = pk.items[pk.sel]
        if not it then return nil end
        return equip(pl, pk.slot, it.id, now)
    end
    if ev == "back" then
        pl.picker = nil
        return "nav"
    end
    return nil
end

-- 0.13.0 easy builds for friends (task #36). surprise: a random pilot nobody else holds, its signature vehicle (else a
-- free model) and a random kit of the class's KIT row (the pilot's own kit, MAX, a tier or a racer style); copy: P1's
-- loadout validated for this guest's class and pilot style (the guest keeps its pilot and vehicle). Both close a picker
-- and go to READY with a toast; the card can still be changed (B). cfg.CardEasyBuilds = false turns them off.
local seeded = false
easyBuild = function(pl, ev, now)
    if opt("CardEasyBuilds", true) == false then return nil end
    if inRun(pl) then toast(pl, "NOT IN A GALAXY RUN", now); return "nav" end
    if inGP() then toast(pl, "NOT IN A GRAND PRIX", now); return "nav" end
    local s = S()
    local Km, Pm, arch = K(), P(), archOf(pl)
    if not seeded then seeded = true; math.randomseed(os.time() + math.floor(now or 0)) end
    pl.picker = nil
    local quick = quickRace()            -- QUICK RACE: one build for all, so no COPY and SURPRISE keeps the build
    if ev == "copy" then
        if pl.isP1 then return nil end
        if quick then toast(pl, "QUICK RACE: SAME BUILD FOR ALL", now); return "nav" end
        local p1 = s.players[0]
        if not (p1 and type(p1.lo) == "table") then toast(pl, "P1 HAS NO BUILD YET", now); return "nav" end
        pl.lo = Km.validate(Km.copy(p1.lo), arch, pilotStyle(pl))
        pl.lo.kit = (p1.lo.kit == "pilot") and "custom" or pl.lo.kit
        afterEdit(pl, nil, now)
        goStage(pl, "ready", "forward", now)
        toast(pl, "P1'S BUILD COPIED", now)
        U.log(TAG, "%s copied P1's build (kit %s) (V-RC-20)", nameOf(pl), tostring(p1.lo.kit))
        return "accept"
    end
    local taken, pool = takenMap(), {}
    for _, e in ipairs(Pm.list(arch)) do
        if e.id == pl.pilotId or not taken[e.id] then pool[#pool + 1] = e end
    end
    if #pool > 0 then
        local e = pool[math.random(#pool)]
        if e.id ~= pl.pilotId then setPilot(pl, e.id, now) end
        local sig = Pm.signature(e, arch)
        pl.presetId = (sig and V.presetById(arch, sig) and sig) or freePreset(pl) or pl.presetId
    end
    if quick then
        remember(pl)
    else
        local style = pilotStyle(pl)
        local kits = { "pilot", "max" }
        for _, k in ipairs(Km.kits(arch, style)) do if k ~= "pilot" and k ~= "max" then kits[#kits + 1] = k end end
        local kit = kits[math.random(#kits)]
        pl.lo = (Km.fromKit(kit, arch, style, pl.lo))
        afterEdit(pl, nil, now)
    end
    goStage(pl, "ready", "forward", now)
    toast(pl, quick and "SURPRISE PICK" or "SURPRISE BUILD", now)
    U.log(TAG, "%s surprise build: pilot %s, %s, kit %s (V-RC-20)", nameOf(pl), tostring(pl.pilotId),
        tostring(pl.presetId), tostring(pl.lo and pl.lo.kit))
    return "accept"
end

-- The one mutator of a card (pads, sink, keyboard, P1's B, tests). src: "pad" | "sink" | "key" | "padB" | "test".
local function dispatch(pl, ev, rep, src, now)
    local s = S()
    if not s.active or not pl or not pl.stage or not EVENTS[ev] then return false end
    now = now or nowMs()
    pl.presses = pl.presses + 1
    pl.backHit = false
    -- 4-way garage open: the event is HIS area's (no card, no easy build, no P1 back rule)
    if g4Open() then
        if ev == "surprise" or ev == "copy" then return false end
        local okE, w = pcall(G4().event, pl.ctrlId, ev, rep, now)
        if not okE then U.logEvery("racers.g4event", 5000, TAG, "garage event failed: %s", tostring(w)); return false end
        if not w then return false end
        sound(pl, w, src, now)
        return true
    end
    local what
    local r = pl.row[pl.stage] or 1
    if ev == "surprise" or ev == "copy" then
        what = easyBuild(pl, ev, now)
    elseif pl.picker then
        what = onPicker(pl, ev, rep, now)
    elseif r == 0 then
        what = onStrip(pl, ev, rep, now)
    else
        what = HANDLERS[pl.stage](pl, ev, rep, now, r)
    end
    if pl.backArmUntil > 0 and not pl.backHit then   -- any other input of P1's disarms "BACK AGAIN"
        pl.backArmUntil = 0
        if pl.toast == BACK_TOAST then pl.toast = nil; markDirty(pl, now) end
    end
    if not what then return false end
    markDirty(pl, now)
    sound(pl, what, src, now)
    return true
end

-- P1's queued START / SAVE / MODE, run outside the input pass (it closes or leaves the step).
local function flushAction()
    local s = S()
    local a = s.action
    if not a or s.inPoll then return end
    s.action = nil
    if a == "back" then U.try(TAG, function() setupM().back() end)
    elseif a == "start" then U.try(TAG, function() setupM().finish(true) end)
    elseif a == "save" then U.try(TAG, function() setupM().finish(false) end) end
end

-- 4-way garage: A on a VEHICLE card opens every card's area (view order). Each card's stage is noted: at the close a
-- card that was on VEHICLE with its area DONE goes forward, the others stay. -> "accept" | nil (not opened: the card's
-- A goes forward as before)
openGarage = function(pl, now)
    local s = S()
    local list = {}
    for _, c in ipairs(s.order) do
        local o = s.players[c]
        if o and o.presetId then
            list[#list + 1] = { ctrlId = c, pnum = o.pnum, isP1 = o.isP1, arch = archOf(o), cls = clsOf(o),
                                presetId = o.presetId }
            o.g4stage = o.stage
        end
    end
    local okO, opened, why = pcall(G4().open, list, {
        by = pl.ctrlId,
        onChange = function(A, what)
            local o = s.players[A.ctrlId]
            if not o then return end
            if what == "model" and A.preset and V.presetById(archOf(o), A.preset) then
                o.presetId, o.follow.vehicle = A.preset, false
                remember(o)
            end
            markDirty(o, nowMs())
        end,
        onClose = function(whyC, areas)
            local t = nowMs()
            for c, A in pairs(areas or {}) do
                local o = s.players[c]
                if o then
                    if A.done and o.g4stage == "vehicle" and o.stage == "vehicle" and s.active then forward(o, t) end
                    o.g4stage = nil
                    o.nav.primed = false             -- the press that closed it is no card input
                    markDirty(o, t)
                end
            end
            U.dbg(TAG, "cards back after the 4-way garage (%s)", tostring(whyC))
        end,
    })
    if okO and opened then
        U.log(TAG, "%s opened the 4-way garage for %d card(s) (G4-01)", nameOf(pl), #list)
        return "accept"
    end
    for _, c in ipairs(s.order) do local o = s.players[c]; if o then o.g4stage = nil end end
    U.logOnce("racers.g4fail", TAG, "4-way garage not opened (%s): A on VEHICLE goes on as before",
        tostring(okO and why or opened))
    return nil
end

---------------------------------------------------------------------------------------------------- guests' pads
local function readPad(pc)
    local st = {}
    for k, names in pairs(PADK) do
        st[k] = false
        for _, n in ipairs(names) do
            if ui().keyDown(pc, n) then st[k] = true; break end
        end
    end
    return st
end

local function axis(neg, pos)
    if neg and not pos then return -1 end
    if pos and not neg then return 1 end
    return 0
end

-- Edge + repeat on one axis (k = "h" | "v"): -> step (-1 | 0 | 1), isRepeat.
local function repeatAxis(n, k, dir, now, delay, rep)
    local dk, nk = k .. "dir", k .. "Next"
    if dir == 0 then n[dk] = 0; return 0, false end
    if dir ~= n[dk] then n[dk], n[nk] = dir, now + delay; return dir, false end
    if now >= (n[nk] or 0) then n[nk] = now + rep; return dir, true end
    return 0, false
end

-- §5.7.3 guests: A on the press edge (both edges time-stamped for P1's accept guard); B on the RELEASE when held
-- shorter than CardBackTapMaxMs (a hold of 1 s leaves through join.lua, guestBHoldsToLeave); directions with repeat
-- (LobbyNavRepeatDelayMs / LobbyNavRepeatMs) on both axes, each time-stamped for P1's direction guard (RC-10). The
-- first poll after an enter or a join is the baseline. VERIFY(V-RC-04): B tap = back, B hold = leave without a back.
local function pollGuest(pl, now)
    if not U.ok(pl.pc) then return end
    local st = readPad(pl.pc)
    local n = pl.nav
    local delay, rep = num("LobbyNavRepeatDelayMs", 400), num("LobbyNavRepeatMs", 140)
    if not n.primed then
        n.primed, n.prev, n.bDownMs = true, st, nil
        n.hdir, n.hNext = axis(st.left, st.right), now + delay
        n.vdir, n.vNext = axis(st.up, st.down), now + delay
        return
    end
    local prev = n.prev
    n.prev = st                                  -- first: an event that throws must not repeat its edge every tick
    local events = {}
    if st.a and not prev.a then n.aDownMs = now; events[#events + 1] = { "accept", false } end
    if not st.a and prev.a then n.aUpMs = now end
    if st.y and not prev.y then events[#events + 1] = { "surprise", false } end
    if st.x and not prev.x then events[#events + 1] = { "copy", false } end
    if not padOneGuest(pl) then                  -- RC-11: that pad's B is P1's CommonUI Back
        if st.b and not prev.b then n.bDownMs = now end
        if not st.b and prev.b then
            local held = n.bDownMs and (now - n.bDownMs) or nil
            n.bDownMs = nil
            if held and held < num("CardBackTapMaxMs", 600) then events[#events + 1] = { "back", false } end
        end
    end
    local h, hRep = repeatAxis(n, "h", axis(st.left, st.right), now, delay, rep)
    if h ~= 0 then
        local dir = (h < 0) and "left" or "right"
        n.dirMs[dir] = now
        events[#events + 1] = { dir, hRep }
    end
    local v, vRep = repeatAxis(n, "v", axis(st.up, st.down), now, delay, rep)
    if v ~= 0 then
        local dir = (v < 0) and "up" or "down"
        n.dirMs[dir] = now
        events[#events + 1] = { dir, vRep }
    end
    for _, e in ipairs(events) do dispatch(pl, e[1], e[2], "pad", now) end
end

---------------------------------------------------------------------------------------------------- P1's sink
-- P1's focus: HasUserFocusedDescendants(P1) is the check that matched live (ui.lua V-LOB-08); ui.hasFocus when it errors.
local function holds(w, p1)
    if not U.ok(w) then return false end
    local ok, v = pcall(U.callMethod, w, "HasUserFocusedDescendants", p1)
    if ok then return v == true end
    return ui().hasFocus(w, p1)
end

local function sinkHolds(p1)
    local k = S().sink
    if not k then return false end
    for _, key in ipairs(SINK_KEYS) do
        if holds(k[key], p1) then return true end
    end
    return false
end

-- setup's footer buttons (optional ctx.footer): CommonUI clicks them itself on Enter.
local function footerHolds(p1)
    local s = S()
    local f = type(s.ctx) == "table" and s.ctx.footer or nil
    if type(f) ~= "table" then return false end
    for _, w in ipairs(f) do
        if holds(w, p1) then return true end
    end
    return false
end

local function inputMode()
    local m = S().p1.override or opt("CardP1Input", "sink")
    if m ~= "geometric" and m ~= "ring" then m = "sink" end
    return m
end

-- The focus target of the step: the sink's centre (ring: the button that had the focus last).
local function target()
    local s = S()
    local k = s.sink
    if not k then return nil end
    if k.wired == "ring" and s.p1.ringAt ~= nil and U.ok(k.ring[s.p1.ringAt]) then return k.ring[s.p1.ringAt] end
    return k.c
end

-- The five buttons: ui.button with opts.noClaim (every CommonUI click reaches M.onSinkClick, no 350 ms dedup), render
-- opacity 0 but Visible and focusable (Slate's navigation needs hit-testable widgets), on a canvas in the sink host.
local function buildSink(ctx)
    if not U.ok(ctx.sinkHost) then error("no sink host") end
    local cv = ctx.newW(CANVAS)
    ctx.sinkHost:AddChild(cv)
    local k = { cv = cv, ring = {}, wired = nil }
    for i, key in ipairs(SINK_KEYS) do
        local w = ui().button(ctx.pc, "setup:sink:" .. key, "", M.onSinkClick, { noClaim = true })
        if not U.ok(w) then error("sink button " .. key .. " not created") end
        pcall(function() w:SetRenderOpacity(0) end)
        pcall(function() w:SetVisibility(C.E.Vis.Visible) end)
        pcall(function() w:BP_SetIsFocusable(true) end)
        local s = cv:AddChildToCanvas(w)                         -- -> CanvasPanelSlot (as cmap.lua place)
        if not U.ok(s) then error("AddChildToCanvas returned no slot") end
        s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        s:SetAlignment({ X = 0, Y = 0 })
        s:SetAutoSize(false)
        s:SetSize({ X = 28, Y = 28 })
        s:SetPosition({ X = SINK_POS[key][1], Y = SINK_POS[key][2] })
        k[key], k.ring[i - 1] = w, w
    end
    return k
end

-- Navigation rules per input mode (EUINavigation Left 0 / Right 1 / Up 2 / Down 3):
--   "sink"      c -> u / d / l / r explicitly, every neighbour back to c in all four directions;
--   "ring"      the Z5 wiring of RING_DELTA (no programmatic re-focus: one BP navigation tick per press, RC-6);
--   "geometric" no explicit rule: Slate's geometric move between the plus-shaped buttons.
-- A rewire first resets every rule to Escape (the default). VERIFY(V-RC-02): explicit Up / Down rules hold like
-- Left / Right; fallback CardP1Input "geometric".
local function wireSink(k, mode)
    if not k or k.wired == mode then return end
    local ok, err = pcall(function()
        if k.wired ~= nil then
            for _, key in ipairs(SINK_KEYS) do
                for _, nv in pairs(NAV) do k[key]:SetNavigationRuleBase(nv, RULE_ESCAPE) end
            end
        end
        if mode == "sink" then
            for key, dir in pairs(NEIGHBOUR_DIR) do k.c:SetNavigationRuleExplicit(NAV[dir], k[key]) end
            for _, key in ipairs(NEIGHBOURS) do
                for _, nv in pairs(NAV) do k[key]:SetNavigationRuleExplicit(nv, k.c) end
            end
        elseif mode == "ring" then
            for i = 0, 4 do
                local b = k.ring[i]
                b:SetNavigationRuleExplicit(NAV.up, k.ring[(i + 1) % 5])
                b:SetNavigationRuleExplicit(NAV.down, k.ring[(i + 4) % 5])
                b:SetNavigationRuleExplicit(NAV.left, k.ring[(i + 2) % 5])
                b:SetNavigationRuleExplicit(NAV.right, k.ring[(i + 3) % 5])
            end
        end
    end)
    if not ok then U.warn(TAG, "sink navigation rules (%s) failed: %s", mode, tostring(err)) end
    k.wired = mode
    U.log(TAG, "P1 sink wired: %s (V-RC-02)", mode)
end

-- A move of P1's sink focus = one direction event, unless it is not P1's pad: mouse + keyboard input, KeyboardIsP1
-- (pad 1 is guest 1 and Slate user 0, R4), a keyboard arrow (its keybind already gave the event), or RC-10: a guest
-- had the same direction within CardP1DirGuardMs (insurance against task #14). VERIFY(V-RC-02): one "P1 sink <dir>" per
-- press; VERIFY(V-RC-07): a guest's d-pad never moves P1's card.
local function sinkDir(dir, now)
    local s = S()
    local p = s.p1
    if not p1Gamepad() or kbP1() or now - p.lastKbMs <= KB_DIR_MS then return end
    local g = num("CardP1DirGuardMs", 50)
    if g > 0 then
        for i = 2, #s.order do
            local o = s.players[s.order[i]]
            local t = o and o.nav.dirMs[dir]
            if t and abs(now - t) <= g then
                p.drops = p.drops + 1
                U.log(TAG, "P1 %s dropped (%s %s %d ms) (V-RC-07)", dir, nameOf(o), dir, floor(abs(now - t)))
                return
            end
        end
    end
    -- CommonUI repeats a held direction by moving the focus again: a quick second move is a repeat (the strip ignores it)
    local rep = p.lastDir == dir and now - p.lastDirMs < REPEAT_MS
    p.lastDir, p.lastDirMs = dir, now
    p.sinkEvents = p.sinkEvents + 1
    if rep then U.dbg(TAG, "P1 sink %s (repeat)", dir) else U.log(TAG, "P1 sink %s (V-RC-02)", dir) end
    dispatch(p1Player(), dir, rep, "sink", now)
end

-- The focus went elsewhere: counted once per departure from a sink that held it, while P1 uses a pad (M.keepFocus brings
-- it back). No sink event or click after SINK_LEAKS such presses = the sink does not work: logged, the next enter wires
-- "geometric" (§8.2).
local function leak(now)
    local s = S()
    local p = s.p1
    if p.leaking then return end
    p.leaking = true
    if not p.held or not p1Gamepad() or kbP1() then return end
    p.leaks = p.leaks + 1
    U.dbg(TAG, "P1 focus left the sink (%d)", p.leaks)
    local mode = s.sink and s.sink.wired
    if p.sinkEvents == 0 and not p.clicked and p.leaks >= SINK_LEAKS and not p.override and mode ~= "geometric" then
        p.override = "geometric"
        U.warn(TAG, "P1 sink inactive (%d pad presses left it, no sink event): P1 keeps the keyboard and the footer; the "
            .. "next enter wires CardP1Input \"geometric\" (V-RC-02)", p.leaks)
    end
end

-- §5.7.4 step 2: where P1's focus is now. sink / geometric: on a neighbour = one direction, then back to the centre;
-- ring: the index delta to the button focused before (no re-focus).
local function pollSink(p1, now)
    local s = S()
    local k, p = s.sink, s.p1
    if not k or not U.ok(k.c) then return end
    if k.wired == "ring" then
        local at = nil
        if p.ringAt ~= nil and holds(k.ring[p.ringAt], p1) then at = p.ringAt end
        if at == nil then
            for i = 0, 4 do
                if holds(k.ring[i], p1) then at = i; break end
            end
        end
        if at == nil then return leak(now) end
        p.leaking, p.held = false, true
        if p.ringAt ~= nil and at ~= p.ringAt then
            local dir = RING_DELTA[(at - p.ringAt) % 5]
            if dir then sinkDir(dir, now) end
        end
        p.ringAt = at
        return
    end
    if holds(k.c, p1) then p.leaking, p.held = false, true; return end
    for _, key in ipairs(NEIGHBOURS) do
        if holds(k[key], p1) then
            p.leaking, p.held = false, true
            sinkDir(NEIGHBOUR_DIR[key], now)
            ui().focus(k.c, p1)
            return
        end
    end
    leak(now)
end

-- §5.7.4 step 3: P1's sink click from the previous tick, now that this tick's guest pads are read: dropped while a
-- guest's A is down or had an edge within CardGuestClickGuardMs of the click (task #14). VERIFY(V-RC-07): "P1 accept
-- dropped (P3 A 40 ms)" and P1's card does not move.
local function p1Accept(now)
    local s = S()
    local p = s.p1
    local at = p.acceptAt
    if not at then return end
    p.acceptAt = nil
    local g = num("CardGuestClickGuardMs", 150)
    for i = 2, #s.order do
        local o = s.players[s.order[i]]
        local n = o and o.nav
        if n and n.primed then
            local d = nil
            if n.prev and n.prev.a then d = 0 end
            if not d and n.aDownMs and abs(at - n.aDownMs) <= g then d = abs(at - n.aDownMs) end
            if not d and n.aUpMs and abs(at - n.aUpMs) <= g then d = abs(at - n.aUpMs) end
            if d then
                p.drops = p.drops + 1
                U.log(TAG, "P1 accept dropped (%s A %d ms) (V-RC-07)", nameOf(o), floor(d))
                return
            end
        end
    end
    dispatch(p1Player(), "accept", false, "sink", now)
end

---------------------------------------------------------------------------------------------------- view model (§5.6)
local function tex(rel) return K().tex(rel) end

local function classArt(pl)
    local s, cls = S(), clsOf(pl)
    if not cls then return nil end
    return (V.classImage and V.classImage(cls, s.planet and s.planet.art)) or cls.image
end

-- §3.3 backdrop (CardBackdrop): the style's own art, a real path from perkdata (RC-8: never derived from the key);
-- pod styles have none: the planet's Arcade pod art (setup.arcadeBg); nil = the dark backdrop.
local function backdropOf(style, pl)
    local s, cls = S(), clsOf(pl)
    local st = D.STYLES[style]
    if st and st.bg then return tex(st.bg) end
    if archOf(pl) == 1 and s.planet and cls then
        local ok, path = pcall(function() return setupM().arcadeBg(s.planet, cls) end)
        if ok and type(path) == "string" then return path end
    end
    return nil
end

-- The class traits' names from the VehicleArchetype (vehicles.classInfo: FText reads), once per class and visit.
local function classTraits(pl)
    local s, arch, cls = S(), archOf(pl), clsOf(pl)
    local c = s.classInfo[arch]
    if c == nil then
        c = ""
        U.try(TAG, function()
            local names = {}
            for _, t in ipairs(V.classInfo(cls).traits or {}) do names[#names + 1] = t:match("^([^:]+)") or t end
            c = table.concat(names, " · ")
        end)
        s.classInfo[arch] = c
    end
    return c
end

-- 0.12.0: the game's name of a model (vehicles.modelName: TH_<Model>.ItemName, the decoded table until the class's
-- read finished; each call advances that budgeted read, one theme load per 250 ms), m.name when it fails. v2 cards.
local function modelName(m)
    if m == nil then return "?" end
    local ok, n = pcall(V.modelName, m)
    if ok and type(n) == "string" and n ~= "" and n ~= "?" then return n end
    return m.name or "?"
end

-- 0.12.0 integration: the classic view model (cards.lua, UiStyle "classic" or the cards2 fallback) keeps the 0.11.0
-- model words: the codename (the upper-cased base model, "BELUGA"; vehicles.models' name is the game's name since
-- WI-09), the pods' own name in the signature and the info line.
local function classicModel(m) return m and (m.codename or m.name) or "?" end

-- §3.4 info line: the maker (badge code) or the pod's name, then the class traits. 0.12.0 v2: a pod's name is its
-- model name (vehicles.models, WI-09), shown on the card already: it is not repeated there; classic as 0.11.0.
local function infoLine(m, v2, pl)
    local parts = {}
    local who
    if v2 then
        who = m and (m.maker or ((m.podName ~= nil and m.podName ~= modelName(m)) and m.podName or nil))
    else
        who = m and (m.maker or m.podName)
    end
    if who then parts[#parts + 1] = who end
    local t = classTraits(pl)
    if t ~= "" then parts[#parts + 1] = t end
    return table.concat(parts, " · ")
end

-- vpreview's brush of the player's bay (key = ControllerId + 1), built in this tick (GC rule); nil = the 2D art.
-- -> brush, kind, dim, backdrop. 0.12.0 (§10): v2 also gets the bay's backdrop rung (VP.backdrop: "studio" |
-- "scenario" | "cutout", the rung in use after a fall), so cards2 picks the fill / wash / cut-out of the rung the
-- capture really has. The classic view model keeps cards.lua's contract (kind "material" | "texture" + a dim): a v2
-- bay's "building" frame (cards2 unusable on a v2 page) becomes its brush type at today's 0.5 dim.
local BUILDING_DIM = 0.5
local function brushOf(pl)
    local vp = VP()
    if not vp then return nil end
    local key = pl.ctrlId + 1
    local ok, b, kind, dim, _, base = U.try(TAG, vp.brush, key)
    local rung = nil
    if S().style == "v2" and type(vp.backdrop) == "function" then
        local okB, r = pcall(vp.backdrop, key)                 -- also without a frame yet: the cut-out's fill
        if okB and type(r) == "string" then rung = r end
    end
    if not (ok and b) then return nil, nil, nil, rung end
    if S().style ~= "v2" and kind == "building" then
        kind = (base == "texture") and "texture" or "material"
        dim = BUILDING_DIM
    end
    return b, kind, dim, rung
end

-- The ability's energy cost for the detail tag (perkapply: the native config CDO, RC-4).
local function abilityCost(id)
    local ok, c = U.try(TAG, function() return PA().abilityCost(id) end)
    if ok and type(c) == "number" then return c end
    return nil
end

-- §2.9 hint line (glyphs + one word each). P1 goes back through the strip ("Up STAGES") until pollP1Back saw one B in
-- this session, then the guests' B hints; the KeyboardIsP1 pad-1 guest always uses the strip and leaves with Start.
local function hint(glyphs, text) return { glyphs = glyphs, text = text } end

local function hintsFor(pl)
    local s = S()
    local strip = (pl.isP1 and not s.p1.sawB) or padOneGuest(pl)
    local function back(word) return strip and hint(G_UP, "STAGES") or hint(G_B, word) end
    local leave = padOneGuest(pl) and hint(G_NONE, "HOLD START: LEAVE") or hint(G_B, "HOLD: LEAVE")
    if pl.picker then
        return { hint(G_UD, "CHOOSE"), hint(G_LR, "GROUP"), hint(G_A, "EQUIP"),
                 strip and hint(G_UP, "TOP: CANCEL") or hint(G_B, "CANCEL") }
    end
    local r = pl.row[pl.stage] or 1
    if r == 0 then return { hint(G_LR, "STAGE"), hint(G_DN, "OPTIONS") } end
    if pl.stage == "pilot" then
        return { hint(G_LR, "PILOT"), hint(G_A, "CONFIRM"), pl.isP1 and back("BACK") or leave }
    elseif pl.stage == "vehicle" then
        return { hint(G_LR, "CHANGE"), hint(G_UD, "ROW"), hint(G_A, g4Wanted() and "GARAGE" or "CONFIRM"), back("BACK") }
    elseif pl.stage == "perks" then
        local Km = K()
        local slot = Km.slots(archOf(pl))[r]
        local kind = Km.slotKind(slot)
        if kind == "kit" then return { hint(G_LR, "KIT"), hint(G_A, "READY"), hint(G_UD, "SLOT"), back("BACK") } end
        if kind == "tune" then return { hint(G_LR, "LEVEL"), hint(G_A, "NEXT"), hint(G_UD, "SLOT"), back("BACK") } end
        local out = {}
        local lr = Km.lrMode(pl.lo, slot)               -- nil: a single part or an empty slot, L/R does nothing
        if lr then out[#out + 1] = hint(G_LR, (lr == "tier") and "TIER" or "CHANGE") end
        out[#out + 1] = hint(G_A, "PICK")
        out[#out + 1] = hint(G_UD, "SLOT")
        out[#out + 1] = back("BACK")
        return out
    end
    if pl.isP1 then return { hint(G_A, (r == 2) and "SAVE" or "START"), hint(G_UD, "ROW"), back("CHANGE") } end
    return { padOneGuest(pl) and hint(G_UP, "STAGES") or hint(G_B, "CHANGE"), leave }
end

-- The roster strip (§3.3): the class's tile count (cards.ROSTER_TILES) centred on the current pilot, wrapping; pilots
-- another human holds carry that player's number (dimmed and tagged by cards.lua).
local function rosterVm(pl)
    local s = S()
    local Pm = P()
    local list = Pm.list(archOf(pl))
    local n = #list
    if n == 0 then return {} end
    local tiles = 7
    pcall(function() tiles = CD().ROSTER_TILES[widthClass()] or 7 end)
    local m = math.min(tiles, n)
    local cur = 1
    for i, e in ipairs(list) do
        if e.id == pl.pilotId then cur = i; break end
    end
    local taken = takenMap()
    local before = floor((m - 1) / 2)
    local out = {}
    for k = 1, m do
        local idx = ((cur - 1 - before + k - 1) % n) + 1
        local e = list[idx]
        local c = Pm.holder(e, taken, pl.ctrlId)
        local o = (c ~= nil) and s.players[c] or nil
        out[k] = { thumb = e.thumb, current = idx == cur, takenBy = o and o.pnum or nil }
    end
    return out
end

local function pilotVm(pl, e, style)
    local s = S()
    local Pm = P()
    local st = D.STYLES[style] or {}
    local traits = {}
    -- QUICK RACE: nobody races traits (the AI have none), so the pilot card lists none
    for k = 1, quickRace() and 0 or 3 do
        local t = st.traits and D.TRAITS[st.traits[k]]
        if t then traits[k] = { icon = tex(t.icon), name = t.name, desc = t.desc } end
    end
    local label = clsOf(pl) and clsOf(pl).label or ""
    local sigText = "ANY " .. label
    local sig = Pm.signature(e, archOf(pl))
    if sig then
        local _, _, m = V.modelOf(archOf(pl), sig)
        if m then sigText = "SIGNATURE " .. label .. " · " .. (m.podName or classicModel(m)) end
    end
    local i, n = Pm.indexOf(archOf(pl), pl.pilotId)
    return {
        backdrop = backdropOf(style, pl), full = e.full, crop = Pm.crop(e, widthClass()), styleIcon = tex(st.icon),
        styleName = st.name or "", styleLine = "PILOT'S OWN STYLE · 3 TRAITS", styleDesc = st.short or st.desc or "",
        traits = traits, signature = sigText, name = e.name or "",
        counter = string.format("%s / %d", i and tostring(i) or "-", n or 0),
        roster = rosterVm(pl), cursor = (pl.row.pilot or 0) >= 1,
    }
end

local function vehicleVm(pl, e, live)
    local s = S()
    local models = V.models(archOf(pl))
    local mi, _, m = V.modelOf(archOf(pl), pl.presetId)
    local pr = V.presetById(archOf(pl), pl.presetId)
    local model = classicModel(m)                -- 0.11.0 words (the v2 card shows the game's name)
    local v = {
        fallback = classArt(pl), badge = m and m.badge or nil, code = m and m.code or nil,
        driver = { thumb = e.thumb, name = e.name },
        signature = pl.presetId ~= nil and pl.presetId == P().signature(e, archOf(pl)),
        model = model, counter = string.format("%d / %d", mi or 0, #models),
        modelRow = "MODEL: " .. model, liveryRow = "LIVERY: " .. (pr and pr.livery or "STANDARD"),
        info = infoLine(m, false, pl), cursor = pl.row.vehicle or 0,
    }
    if live then v.brush, v.brushKind, v.dim = brushOf(pl) end
    return v
end

-- 0.12.0 v2: the pilot's poster (§9.3) is e.tile (pilots.lua, the SCENARIOS tile); SEBULBA and the pod pilots have
-- none: their art window shows the empty poster with the full body on it, figure = {full, crop} (nil otherwise).
local function figureOf(e)
    if type(e) ~= "table" or e.tile or not e.full then return nil end
    return { full = e.full, crop = P().crop(e, widthClass()) }
end

-- 0.12.0: the v2 extras need the pilot (e: the PERKS poster column / strip, §9.5). perks.detail gets this page's style:
-- "classic" = the 0.11.0 texts cards.lua shows, "v2" = the short tag lines without prose key hints (WI-13).
local function perksVm(pl, style, e)
    local s = S()
    local Km = K()
    local v2 = s.style == "v2"
    local board = Km.board(pl.lo, archOf(pl), style)
    local slots = Km.slots(archOf(pl))
    local r = pl.row.perks or 0
    local pk = pl.picker
    local cursor = pk and pk.slot or ((r >= 1) and slots[r] or nil)
    -- the detail panel follows the slot (or the picker row) under the cursor; on the strip, the stage's last row
    local itemId = nil
    if pk and pk.sel >= 1 and pk.items[pk.sel] then itemId = pk.items[pk.sel].id end
    local d = Km.detail(cursor or slots[pl.last.perks or 1] or "kit", pl.lo, archOf(pl), itemId, style,
        v2 and "v2" or "classic")
    -- 0.13.0 GALAXY RUN: the two rewards that are no perk get their own text (not the upgrade slot's)
    local rit = pk and (pk.kind == "reward" or pk.kind == "shop") and pk.items[pk.sel] or nil
    local SHOPTXT = { reroll = "New stock for this shop. The price rises with every reroll.",
                      leave = "Close the shop. What you bought stays in your run build.",
                      repairpart = "A wreck broke this part. Repair it to equip it again." }
    if rit and SHOPTXT[rit.rkind] then
        d = { kind = "reward", id = rit.id, title = rit.name, iconKind = "glyph", plain = SHOPTXT[rit.rkind],
              tag = "GALAXY RUN" }
        d.rich = d.plain
    elseif rit and (rit.rkind == "upgrade" or rit.rkind == "repair") then
        local cap = runM() and runM().capFor(pl.ctrlId) or nil
        d = { kind = "reward", id = rit.id, title = rit.name, iconKind = "glyph",
              plain = (rit.rkind == "upgrade")
                  and string.format("Your upgrade levels may go one step higher for the rest of the run (now %s).",
                      tostring(cap or "?"))
                  or "Repairs one point of the team's hull. Every player keeps racing for the same hull.",
              tag = "GALAXY RUN" }
        d.rich = d.plain
    end
    if d.costId then                             -- v2: d-pad abilities only ("LEVEL 2 · COST 3"; a crash costs nothing)
        local c = abilityCost(d.costId)
        if c then d.tag = (d.tag or "") .. " · COST " .. tostring(c) end
    end
    board.cursor, board.detail = cursor, d
    if v2 then
        -- §9.9: POWER / ENERGY as numbers (W / M POWER block "31 / 60" + "ENERGY 12", N totals line); kitLabel /
        -- kitLabelShort / kitFrom / powerMax come with perks.board; the 0.11.0 strings stay as powerText / energyText
        board.powerText, board.energyText = board.power, board.energy
        board.power, board.energy = board.powerValue, board.energyValue
        local st = D.STYLES[pl.lo and pl.lo.style]
        if st and st.pod and board.style then board.style.icon = tex(POD_STYLE_ICON) end
        if e then board.tile, board.figure = e.tile, figureOf(e) end
    end
    if pk then
        local cat = pk.cats[pk.cat] or {}
        board.picker = { catName = cat.name, catIcon = cat.icon,
                         counter = string.format("%d / %d", math.max(1, pk.sel), #pk.items), rows = pk.items,
                         cursor = pk.sel, kind = pk.kind }
    end
    return board
end

local function readyVm(pl, e, style, live)
    local s = S()
    local Km = K()
    local lo = raceLo(pl)
    local board = Km.board(lo, archOf(pl), style)
    local sum = Km.summary(lo, archOf(pl))
    local _, _, m = V.modelOf(archOf(pl), pl.presetId)
    local rows
    if pl.isP1 then
        rows = { s.allReady and "START RACE · ALL READY" or "START RACE", "SAVE AND RETURN" }
    else
        rows = { "READY · WAITING FOR P1" }
    end
    local rp = {
        fallback = classArt(pl),
        figure = { full = e.full, crop = P().crop(e, widthClass()), backdrop = backdropOf(style, pl) },
        line = (e.name or "?") .. " · " .. classicModel(m), styleName = board.style and board.style.name or "",
        strip = { ab = board.ab, crash = board.ab.crash, parts = board.parts, style = board.style and board.style.icon,
                  traits = board.traits },
        totals = quickRace() and Q().text() or sum.totals, rows = rows, cursor = pl.row.ready or 0,
        -- §2.6: everybody READY -> P1's START row pulses (cards.tick animates it)
        pulse = (pl.isP1 and s.allReady == true and opt("CardStartPulse", true) ~= false) or nil,
    }
    if live then rp.brush, rp.brushKind, rp.dim = brushOf(pl) end
    return rp
end

---------------------------------------------------------------------------------------------------- v2 view model §9.9
-- cards2.lua's view model: the §5.6 contract of vehicle-step-v2 with the §9.9 changes. Shared with the classic one:
-- pnum, colour, isP1, view, ready, strip, stage, toast, the roster, the picker, brush / brushKind / dim. Every name
-- shown is the pilot's baseName: the Pod Tour " · AGED" is vm.rankTag (the rank line, §9.7). Extra fields beyond §9.9
-- (kept small): header.tile / figure and the same pair on perks and readyPanel (every stage that shows the poster),
-- vm.rank (the rank line's words composed), pilot.signatureModel, traits[k].rich, vehicle.models[k].index,
-- readyPanel.name / model / power / powerMax / energy.

-- The style icon (§9.3): perkdata gives pod styles the pilot's head shot (RP6); the card shows the podracer glyph.
local function styleIconOf(st)
    if type(st) ~= "table" then return nil end
    if st.pod then return tex(POD_STYLE_ICON) end
    return st.icon and tex(st.icon) or nil
end

-- §9.1 / §9.3-9.6 hints: sentence-case words, at most HINT_MAX[width class] entries (the first ones). hintsFor's back
-- rule: P1 goes back through the strip ("Stages") until pollP1Back saw a B, the KeyboardIsP1 pad-1 guest always.
-- READY: P1 with a pad "Start" / "Save" + "Row" (none in N: the rows are the prompt), P1 with mouse + keyboard the way
-- back only (START / SAVE are the command row), guests "Change" + "Hold: leave".
local function hintsV2(pl)
    local s = S()
    local strip = (pl.isP1 and not s.p1.sawB) or padOneGuest(pl)
    local function back(word) return strip and hint(G_UP, "Stages") or hint(G_B, word) end
    local leave = padOneGuest(pl) and hint(G_NONE, "Hold Start: leave") or hint(G_B, "Hold: leave")
    local cls = widthClass()
    local r = pl.row[pl.stage] or 1
    local out
    if pl.picker and pl.picker.kind == "reward" then
        out = { hint(G_UD, "Choose"), hint(G_A, "Claim reward") }     -- 0.13.0 GALAXY RUN: one must be picked
    elseif pl.picker and pl.picker.kind == "shop" then
        out = { hint(G_UD, "Choose"), hint(G_A, "Buy"), hint(G_B, "Leave shop") }
    elseif pl.picker then
        out = { hint(G_UD, "Choose"), hint(G_A, "Equip"), strip and hint(G_UP, "Top: cancel") or hint(G_B, "Cancel") }
    elseif r == 0 then
        out = { hint(G_LR, "Stage"), hint(G_DN, "Select") }      -- not "Options": v2 has an OPTIONS page (§5)
    elseif pl.stage == "pilot" then
        if not pl.isP1 and opt("CardEasyBuilds", true) ~= false and not inRun(pl) and cls ~= "N" then
            out = { hint(G_Y, "Surprise me"), hint(G_A, "Confirm"), leave }   -- 0.13.0: L/R arrows are on the card
        else
            out = { hint(G_LR, "Pilot"), hint(G_A, "Confirm"), pl.isP1 and back("Back") or leave }
        end
    elseif pl.stage == "vehicle" then
        out = { hint(G_LR, (r == 2) and "Livery" or "Model"), hint(G_UD, "Row"), hint(G_A, g4Wanted() and "Garage" or "Confirm") }
    elseif pl.stage == "perks" then
        local Km = K()
        local slot = Km.slots(archOf(pl))[r]
        local kind = Km.slotKind(slot)
        if kind == "kit" and inRun(pl) then
            out = { hint(G_A, "Ready"), back("Back") }                -- 0.13.0: the run build has no KIT choice
        elseif kind == "kit" then
            out = { hint(G_LR, "Kit"), hint(G_A, "Ready"), back("Back") }
        elseif kind == "tune" then
            out = { hint(G_LR, "Level"), hint(G_A, "Next"), back("Back") }
        else
            out = {}
            local lr = Km.lrMode(pl.lo, slot)           -- nil: a single part or an empty slot, L/R does nothing
            if lr and not inRun(pl) then out[#out + 1] = hint(G_LR, (lr == "tier") and "Tier" or "Change") end
            out[#out + 1] = hint(G_A, "Pick")
            out[#out + 1] = back("Back")
        end
    elseif pl.isP1 then
        if modeOf(pl) == "mouse" then
            out = { back("Change") }
        elseif cls == "N" then
            out = {}
        else
            out = { hint(G_A, (r == 2) and "Save" or "Start"), hint(G_UD, "Row") }
        end
    else
        out = { padOneGuest(pl) and hint(G_UP, "Stages") or hint(G_B, "Change"), leave }
        if opt("CardEasyBuilds", true) ~= false and not inRun(pl) and not quickRace() and (HINT_MAX[cls] or 3) >= 3 then
            table.insert(out, 2, hint(G_X, "Copy P1"))
        end
    end
    local maxN = HINT_MAX[cls] or 3
    while #out > maxN do table.remove(out) end
    return out
end

-- §9.4 CHOOSE MODEL: a window of MODEL_TILES[class] models around the current one, wrapping (the current tile right of
-- the middle: 4th of 6, 3rd of 4, as the mockups), each {name = the game's name, badge, code (no badge: ANTAGONIST, the
-- pods but MYTH), current, index}; nil in N (one title row). Fewer models than tiles: each model once.
local function modelsWindow(models, mi)
    local n, total = MODEL_TILES[widthClass()], #models
    if not n or total == 0 then return nil end
    local k0 = math.min(n, total)
    local before = floor(k0 / 2)
    local out = {}
    for k = 1, k0 do
        local idx = (((mi or 1) - 1 - before + k - 1) % total) + 1
        local md = models[idx]
        out[k] = { name = modelName(md), badge = md.badge, code = md.code, current = idx == mi, index = idx }
    end
    return out
end

-- READY flags of every card in view order (the READY pills' AMBER pips, §9.6).
local function readyPips()
    local s = S()
    local out = {}
    for i, c in ipairs(s.order) do
        local o = s.players[c]
        out[i] = o ~= nil and o.stage == "ready"
    end
    return out
end

-- §9.3 PILOT: the poster (tile / figure), the style column (pod styles: the podracer glyph), "PILOT'S OWN STYLE", the
-- description (W), 3 traits (rich: GOLD keywords), the signature ("SIGNATURE · ARZ 41" with the game's model name, or
-- "ANY LANDSPEEDER"; N draws a star + signatureModel), the name, the counter and the roster.
local function pilotVmV2(pl, e, style)
    local s = S()
    local Pm = P()
    local st = D.STYLES[style] or {}
    local traits = {}
    -- QUICK RACE: nobody races traits (the AI have none), so the pilot card lists none
    for k = 1, quickRace() and 0 or 3 do
        local t = st.traits and D.TRAITS[st.traits[k]]
        if t then traits[k] = { icon = tex(t.icon), name = t.name, desc = t.desc, rich = t.rich } end
    end
    local sigModel = nil
    local sig = Pm.signature(e, archOf(pl))
    if sig then
        local _, _, m = V.modelOf(archOf(pl), sig)
        if m then sigModel = modelName(m) end
    end
    local i, n = Pm.indexOf(archOf(pl), pl.pilotId)
    return {
        tile = e.tile, figure = figureOf(e), styleIcon = styleIconOf(st), styleName = st.name or "",
        styleLine = "PILOT'S OWN STYLE", styleDesc = st.short or st.desc or "", traits = traits,
        signature = sigModel and ("SIGNATURE · " .. sigModel) or ("ANY " .. (clsOf(pl) and clsOf(pl).label or "")),
        signatureModel = sigModel, name = e.baseName or e.name or "",
        counter = string.format("%s / %d", i and tostring(i) or "-", n or 0),
        roster = rosterVm(pl), cursor = (pl.row.pilot or 0) >= 1,
    }
end

-- §9.4 VEHICLE: the game's model name, the CHOOSE MODEL window (W / M), the livery value (today's labels: STANDARD,
-- the pilot's name, AGED, MYTH P1-P3), DRIVEN BY, the signature chip, the info line, the photo brush.
local function vehicleVmV2(pl, e, live)
    local s = S()
    local models = V.models(archOf(pl))
    local mi, _, m = V.modelOf(archOf(pl), pl.presetId)
    local pr = V.presetById(archOf(pl), pl.presetId)
    local v = {
        fallback = classArt(pl), badge = m and m.badge or nil, code = m and m.code or nil,
        driver = { thumb = e.thumb, name = e.baseName or e.name },
        signature = pl.presetId ~= nil and pl.presetId == P().signature(e, archOf(pl)),
        model = modelName(m), counter = string.format("%d / %d", mi or 0, #models), models = modelsWindow(models, mi),
        livery = pr and pr.livery or "STANDARD", info = infoLine(m, true, pl), cursor = pl.row.vehicle or 0,
    }
    if live then v.brush, v.brushKind, v.dim, v.backdrop = brushOf(pl) end
    return v
end

-- §9.6 READY: the poster is the hero (no figure box), the still render on a plate, model + style, the loadout strip,
-- the totals; P1 with a pad: rows START RACE / SAVE AND RETURN (+ allReady: the tick; pulse); P1 with mouse +
-- keyboard: rows nil, p1Pill (a READY pill; START / SAVE are setup's command row); guests: rows nil, waiting
-- ("WAITING FOR P1"); pips = every card's READY flag.
local function readyVmV2(pl, e, style, live)
    local s = S()
    local Km = K()
    local lo = raceLo(pl)
    local board = Km.board(lo, archOf(pl), style)
    local sum = Km.summary(lo, archOf(pl))
    local _, _, m = V.modelOf(archOf(pl), pl.presetId)
    local st = D.STYLES[lo and lo.style]
    local name, model = e.baseName or e.name or "?", modelName(m)
    local pad = modeOf(pl) == "pad"
    local rp = {
        fallback = classArt(pl), tile = e.tile, figure = figureOf(e), name = name, model = model,
        line = name .. " · " .. model, styleName = board.style and board.style.name or "",
        strip = { ab = board.ab, crash = board.ab.crash, parts = board.parts, traits = board.traits,
                  style = (st and st.pod) and tex(POD_STYLE_ICON) or (board.style and board.style.icon) },
        totals = quickRace() and Q().text() or sum.totals, power = sum.power, powerMax = board.powerMax,
        energy = sum.energy,
        allReady = s.allReady == true, pips = readyPips(), cursor = pl.row.ready or 0,
        pulse = (pl.isP1 and pad and s.allReady == true and opt("CardStartPulse", true) ~= false) or nil,
    }
    if pl.isP1 and pad then rp.rows = { "START RACE", "SAVE AND RETURN" }
    elseif pl.isP1 then rp.p1Pill = true
    else rp.waiting = true end
    if live then rp.brush, rp.brushKind, rp.dim, rp.backdrop = brushOf(pl) end
    return rp
end

-- The rank line's words (§9.3-9.6; cards2 applies the N fitting rule "MODEL dropped"): "TOP LEFT · 2 / 13",
-- "TOP · AGED · 3 / 8", "TOP · MODEL 1 / 13", "BOTTOM RIGHT · READY"; nil on PERKS (no rank line there).
local function rankOf(pl, e, vm)
    local parts = {}
    if type(pl.view) == "string" and pl.view ~= "" then parts[1] = pl.view end
    if pl.stage ~= "vehicle" and e.rankTag then parts[#parts + 1] = e.rankTag end
    if pl.stage == "pilot" and vm.pilot then parts[#parts + 1] = vm.pilot.counter
    elseif pl.stage == "vehicle" and vm.vehicle then parts[#parts + 1] = "MODEL " .. vm.vehicle.counter
    elseif pl.stage == "ready" then parts[#parts + 1] = "READY"
    else return nil end
    return table.concat(parts, " · ")
end

local function buildVmV2(pl, now, live)
    local e = P().byId(pl.pilotId) or {}
    local style = pilotStyle(pl)
    local list = stageList()
    local r = pl.row[pl.stage] or 1
    local vm = {
        pnum = pl.pnum, colour = colourOf(pl.pnum), isP1 = pl.isP1, view = pl.view, ready = pl.stage == "ready",
        inputMode = modeOf(pl), rankTag = e.rankTag,
        header = { pilotName = e.baseName or e.name or "", thumb = e.thumb, tile = e.tile, figure = figureOf(e) },
        strip = { stages = list, current = indexOf(list, pl.stage) or 1, cursor = r == 0 and not pl.picker },
        stage = pl.stage, hint = hintsV2(pl), toast = (pl.toast and now < pl.toastUntil) and pl.toast or nil,
    }
    if pl.stage == "pilot" then vm.pilot = pilotVmV2(pl, e, style)
    elseif pl.stage == "vehicle" then vm.vehicle = vehicleVmV2(pl, e, live)
    elseif pl.stage == "perks" then vm.perks = perksVm(pl, style, e)
    else vm.readyPanel = readyVmV2(pl, e, style, live) end
    vm.rank = rankOf(pl, e, vm)
    return vm
end

-- One card's view model. live = false (dump): no vpreview brush is made. 0.12.0: a v2 page gets buildVmV2's.
local function buildVm(pl, now, live)
    local s = S()
    if s.style == "v2" then return buildVmV2(pl, now, live) end
    local e = P().byId(pl.pilotId) or {}
    local style = pilotStyle(pl)
    local list = stageList()
    local r = pl.row[pl.stage] or 1
    local vm = {
        pnum = pl.pnum, colour = colourOf(pl.pnum), isP1 = pl.isP1, view = pl.view, ready = pl.stage == "ready",
        header = { pilotName = e.name or "", thumb = e.thumb },
        strip = { stages = list, current = indexOf(list, pl.stage) or 1, cursor = r == 0 and not pl.picker },
        stage = pl.stage, hint = hintsFor(pl), toast = (pl.toast and now < pl.toastUntil) and pl.toast or nil,
    }
    if pl.stage == "pilot" then vm.pilot = pilotVm(pl, e, style)
    elseif pl.stage == "vehicle" then vm.vehicle = vehicleVm(pl, e, live)
    elseif pl.stage == "perks" then vm.perks = perksVm(pl, style)
    else vm.readyPanel = readyVm(pl, e, style, live) end
    return vm
end

---------------------------------------------------------------------------------------------------- poll parts (§5.7.4)
-- 4. toasts, P1's back window, the ALL READY state (P1's START row and the status line).
local function timers(now)
    local s = S()
    local all = #s.order > 0
    for _, c in ipairs(s.order) do
        local pl = s.players[c]
        if pl then
            if pl.toast and now >= pl.toastUntil then pl.toast = nil; markDirty(pl, now) end
            if pl.backArmUntil > 0 and now >= pl.backArmUntil then pl.backArmUntil = 0 end
            if pl.stage ~= "ready" then all = false end
        end
    end
    if all ~= s.allReady then
        s.allReady = all
        markDirty(p1Player(), now)
        if all and #s.order > 1 then U.log(TAG, "all %d players READY (P1: A TO START) (V-RC-18)", #s.order) end
    end
    if s.style == "v2" then
        -- §9.6: every READY pill carries one pip per player (filled = on READY): a change re-renders the READY cards
        local flags = {}
        for i, c in ipairs(s.order) do
            local o = s.players[c]
            flags[i] = (o and o.stage == "ready") and "1" or "0"
        end
        local sig = table.concat(flags)
        if sig ~= s.readySig then
            s.readySig = sig
            for _, c in ipairs(s.order) do
                local o = s.players[c]
                if o and o.stage == "ready" then markDirty(o, now) end
            end
        end
    end
end

-- 4b (v2). P1's input mode (§6.4, theme.inputMode, debounced): a switch re-renders P1's card first in this tick (its
-- READY rows become the READY pill or back), while setup's command row shows / hides START and SAVE from the same
-- debounced mode. VERIFY(V-FIN-11): one "P1 input mode" line per real switch, START never twice on screen.
local function modeTick(now)
    local s = S()
    local m = p1Mode()
    if m == s.mode then return end
    local was = s.mode
    s.mode = m
    local pl = p1Player()
    if was == nil or not pl then return end
    pl.dirty, pl.dirtyAt = true, -1e9             -- ahead of every other dirty card (render budget, step 7)
    local what = "re-rendered"
    if pl.stage == "ready" then
        what = (m == "mouse") and "READY pill, START / SAVE in the command row" or "START / SAVE rows on the card"
    end
    U.log(TAG, "P1 input mode %s -> %s: P1's card %s (V-FIN-11)", tostring(was), m, what)
end

-- 5. previews: VEHICLE spins, PERKS / READY stills, PILOT a still prebuild of the pick once the pilot was unchanged
-- SetupPreviewPrebuildMs (VERIFY(V-RC-10): "bay n ready" before the step to VEHICLE); then vpreview's tick, whose
-- changed bays re-render their cards.
local function previews(now)
    local s = S()
    local vp = VP()
    if not vp then return end
    local g4 = g4Open()
    if g4 then
        U.tryEvery("racers.g4preview", nil, TAG, G4().previews, now)      -- each area's car + livery, its own modes
    else
        local prebuild = num("SetupPreviewPrebuildMs", 600)
        local G4m = opt("Garage4Way", false) == true and G4() or nil
        for _, c in ipairs(s.order) do
            local pl = s.players[c]
            if pl then
                U.tryEvery("racers.preview", nil, TAG, function()
                    if pl.stage == "pilot" and not (prebuild > 0 and now - pl.pilotAt >= prebuild) then return end
                    local pr = V.presetById(archOf(pl), pl.presetId)
                    -- 4-way garage on: the card's bay wears the pad's livery too
                    local liv = nil
                    if G4m then
                        local okL, l = pcall(G4m.cardLivery, c, archOf(pl), pl.presetId)
                        liv = okL and l or nil
                    end
                    if pr then vp.want(c + 1, pr, clsOf(pl), liv) end
                    vp.setMode(c + 1, vp.stageMode(pl.stage))
                end)
            end
        end
    end
    local ok, changed, keys = U.tryEvery("racers.vptick", nil, TAG, vp.tick)
    if ok and changed and type(keys) == "table" then
        for key in pairs(keys) do
            markDirty(s.players[key - 1], now)
            if g4 then pcall(G4().bayChanged, key) end
        end
    end
end

-- 5b (v2). The class's model-name read (vehicles.lua: TH_<Model>.ItemName by hard path, one theme load per 250 ms, the
-- decoded English table meanwhile) only advances when a name is asked for: this asks every poll until
-- vehicles.nameStatus no longer reports the class pending, then every card showing a model name re-renders once (a
-- localised game shows its own names without waiting for an input; VERIFY(V-FIN-10) is vehicles.lua's log line).
-- Pods have no theme names (never pending). Once per class and session; every class a card shows (a GALACTIC GRAND PRIX
-- card can be in another class than the page): namesFor / namesWait are sets by class key.
local function namesTick(now)
    local s = S()
    if type(s.namesFor) ~= "table" then s.namesFor = {} end
    if type(s.namesWait) ~= "table" then s.namesWait = {} end
    local list, seen = {}, {}
    local function add(cls)
        local key = type(cls) == "table" and tostring(cls.key) or nil
        if key and not seen[key] then seen[key] = true; list[#list + 1] = { key = key, cls = cls } end
    end
    add(s.cls)
    for _, c in ipairs(s.order) do add(clsOf(s.players[c])) end
    for _, it in ipairs(list) do
        local key = it.key
        if not s.namesFor[key] then
            local ok, st = pcall(V.nameStatus)
            if ok and type(st) == "string"
                and (st:find(key .. " pending", 1, true) or st:find(key .. " not read", 1, true)) then
                local models = V.models(it.cls.arch)
                if models[1] then pcall(V.modelName, models[1]) end
                s.namesWait[key] = true
            else
                s.namesFor[key] = true
                if s.namesWait[key] then
                    s.namesWait[key] = nil
                    for _, c in ipairs(s.order) do
                        local pl = s.players[c]
                        if pl and pl.stage ~= "perks" and tostring((clsOf(pl) or {}).key) == key then markDirty(pl, now) end
                    end
                    U.dbg(TAG, "model names of %s read: the cards re-render", key)
                end
            end
        end
    end
end

-- 7. up to CardRendersPerTick dirty cards, oldest first: view model (with this tick's brush) -> cards.render. A
-- render that waits for the build budget stays dirty (its next render carries a fresh brush).
local function renders(now)
    local s = S()
    if g4Open() then                             -- 4-way garage over the page: its areas render, the cards wait (dirty)
        G4().poll(now)
        return
    end
    local list = {}
    for i, c in ipairs(s.order) do
        local pl = s.players[c]
        if pl and pl.dirty then list[#list + 1] = { i = i, pl = pl } end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b)
        if a.pl.dirtyAt ~= b.pl.dirtyAt then return a.pl.dirtyAt < b.pl.dirtyAt end
        return a.i < b.i
    end)
    local cd = CD()
    for k = 1, math.min(#list, math.max(1, floor(num("CardRendersPerTick", 2)))) do
        local e = list[k]
        e.pl.dirty = false                       -- a render error waits for the next change, not every tick
        U.tryEvery("racers.render", nil, TAG, function()
            local done = cd.render(e.i, buildVm(e.pl, now, true))
            if not done then e.pl.dirty, e.pl.dirtyAt = true, now end
        end)
    end
end

-- Join hints (§2.6): connected pads that did not join (join.dormantList), refreshed once a second. Returns the classic
-- status-line text and (0.12.0) the v2 pill text, where "(A)" becomes the pad glyph (§6.5 "PADS 3, 4: PRESS (A) TO
-- JOIN"; start-only pads keep the word START); nil, nil when every connected pad joined.
local function dormantHint(now)
    local s = S()
    if now < s.dormantAt then return s.dormant, s.dormantV2 end
    s.dormantAt = now + DORMANT_MS
    local list = {}
    pcall(function() list = U.mod("join").dormantList() end)
    local byButton = { A = {}, START = {} }
    for _, d in ipairs(list) do
        local startOnly = cfg.JoinButtons == "start" or (d.ctrlId == 1 and kbP1())   -- join.lua startOnlyFor
        local t = byButton[startOnly and "START" or "A"]
        t[#t + 1] = (tostring(d.label or ""):gsub("^PAD ", ""))
    end
    local parts, partsV2 = {}, {}
    for _, b in ipairs({ "A", "START" }) do
        local nums = byButton[b]
        local who = nil
        if #nums == 1 then
            who = string.format("PAD %s", nums[1])
        elseif #nums > 1 then
            who = string.format("PADS %s", table.concat(nums, ", "))
        end
        if who then
            parts[#parts + 1] = string.format("%s: PRESS %s TO JOIN", who, b)
            partsV2[#partsV2 + 1] = string.format("%s: PRESS %s TO JOIN", who, (b == "A") and "(A)" or b)
        end
    end
    s.dormant = (#parts > 0) and table.concat(parts, "   ·   ") or nil
    s.dormantV2 = (#partsV2 > 0) and table.concat(partsV2, " · ") or nil
    return s.dormant, s.dormantV2
end

-- §2.9 status line under the footer: "P1 PILOT · P2 PERKS · P3 READY" or "ALL READY · P1: A TO START", the join hint
-- appended. A status of another module (START gate, joins, errors) holds the line for STATUS_HOLD_MS.
local function statusText(now)
    local s = S()
    local parts, all = {}, #s.order > 0
    for _, c in ipairs(s.order) do
        local pl = s.players[c]
        if pl then
            parts[#parts + 1] = nameOf(pl) .. " " .. (STAGE_WORD[pl.stage] or "?")
            if pl.stage ~= "ready" then all = false end
        end
    end
    local t = all and "ALL READY · P1: A TO START" or table.concat(parts, " · ")
    local d = dormantHint(now)
    if d then t = t .. "   ·   " .. d end
    return t
end

local function statusTick(now)
    local s = S()
    if now < s.statusHoldUntil or now < s.statusAt then return end
    s.statusAt = now + STATUS_MS
    local t = statusText(now)
    if t ~= s.statusText then
        s.statusText = t
        pcall(function() setupM().setStatus(t) end)
    end
end

St.on("status", TAG, function()
    local s = St.racers
    if type(s) == "table" and s.active then
        s.statusHoldUntil, s.statusText = nowMs() + STATUS_HOLD_MS, nil
    end
end)

-- 0.12.0 §6.5 (v2): this module's entries of the status pill on setup's page (theme C5; the pill picks gate 3 > all
-- ready 2 > launching 1 > the latest transient 0; other modules' St.emit("status") texts are setup's / lobby's):
--   PILL_JOIN   "PADS 3, 4: PRESS (A) TO JOIN": transient (StatusPillMs) at entry and whenever that set changes;
--   PILL_READY  "ALL READY · P1: (A) TO START" (pad) / "ALL READY · P1: START RACE" (mouse + keyboard): sticky while
--               every card is READY, one AMBER pip per player (at most 4).
-- Posted through ctx.pill (a theme status pill, when setup's racers context carries one) or setup.setStatus(text,
-- opts) (opts = the theme pill options {key, sticky, prio, pips, ms}; text "" with a key removes that entry). The
-- classic page keeps statusTick.
local function pillPost(text, o)
    local s = S()
    local p = type(s.ctx) == "table" and s.ctx.pill or nil
    if type(p) == "table" and type(p.post) == "function" then
        local ok, err = pcall(p.post, text, o)
        if not ok then U.logEvery("racers.pill", 5000, TAG, "status pill post failed: %s", tostring(err)) end
        return
    end
    local okF, f = pcall(function() return setupM().setStatus end)
    if not okF or type(f) ~= "function" then
        U.logOnce("racers.pill?", TAG, "no status pill route (ctx.pill / setup.setStatus): the join hint and ALL READY "
            .. "are not shown")
        return
    end
    local ok, err = pcall(f, text, o)
    if not ok then U.logEvery("racers.pill", 5000, TAG, "setup.setStatus failed: %s", tostring(err)) end
end

local function pillTick(now)
    local s = S()
    local _, join = dormantHint(now)
    if join ~= s.pillJoin then
        s.pillJoin = join
        pillPost(join or "", { key = PILL_JOIN, ms = num("StatusPillMs", 5000) })
        if join then U.dbg(TAG, "status pill: %s", join) end
    end
    local n = #s.order
    local text = nil
    if s.allReady == true and n > 0 then
        text = (s.mode == "mouse") and "ALL READY · P1: START RACE" or "ALL READY · P1: (A) TO START"
    end
    local sig = text and (text .. "|" .. n) or nil
    if sig == s.pillReady then return end
    s.pillReady = sig
    if not text then
        pillPost("", { key = PILL_READY })
        return
    end
    local pips = {}
    for i = 1, math.min(n, 4) do pips[i] = true end
    pillPost(text, { key = PILL_READY, sticky = true, prio = 2, pips = pips })
    U.dbg(TAG, "status pill: %s (%d pips, sticky)", text, #pips)
end

-- The page leaves the step (or another visit starts): this module's pill entries go.
local function pillClear()
    local s = S()
    if s.pillReady then pillPost("", { key = PILL_READY }) end
    if s.pillJoin then pillPost("", { key = PILL_JOIN }) end
    s.pillJoin, s.pillReady = nil, nil
end

-- 0.12.0 §6.4 (v2): with mouse + keyboard, START RACE and SAVE AND RETURN are setup's command row, and P1's READY
-- cursor (row 1 START, row 2 SAVE: keyboard Up / Down as before) is its painted focus: setup.commandFocus("start" |
-- "save"), nil once the cursor leaves READY, P1 uses a pad again or the step is left. Told only on a change;
-- setup.commandFocus may not exist (logged once, then the command row shows ghost focus / hover only).
local function commandFocus()
    local s = S()
    local want = nil
    if s.active and s.style == "v2" and s.mode == "mouse" then
        local pl = p1Player()
        local r = (pl and pl.stage == "ready" and not pl.picker) and (pl.row.ready or 0) or 0
        want = (r == 1) and "start" or ((r == 2) and "save" or nil)
    end
    if want == s.cmdFocus then return end
    s.cmdFocus = want
    local okF, f = pcall(function() return setupM().commandFocus end)
    if not okF or type(f) ~= "function" then
        U.logOnce("racers.cmdfocus?", TAG, "setup.commandFocus unavailable: P1's READY cursor does not paint the "
            .. "command row (V-FIN-11)")
        return
    end
    local ok, err = pcall(f, want)
    if ok then
        U.dbg(TAG, "command row focus %s (P1 on READY, mouse + keyboard) (V-FIN-11)", tostring(want or "released"))
    else
        U.logEvery("racers.cmdfocus", 5000, TAG, "setup.commandFocus(%s) failed: %s", tostring(want), tostring(err))
    end
end

-- RC-9: the class roster's head shots and full bodies queued at low priority (cards.lua loads one big texture a tick).
-- 0.12.0 v2 (§9.8): the SCENARIOS posters instead of the full bodies, which only SEBULBA and the pods still need (on
-- the empty poster).
local function prefetch()
    local cd = CD()
    local v2 = S().style == "v2"
    local empty = false
    local s = S()
    local archs, seen = {}, {}
    if s.arch ~= nil then seen[s.arch], archs[1] = true, s.arch end
    for _, c in ipairs(s.order) do                   -- a GALACTIC GRAND PRIX card in another class: its roster too
        local a = archOf(s.players[c])
        if a ~= nil and not seen[a] then seen[a] = true; archs[#archs + 1] = a end
    end
    local done = {}
    for _, a in ipairs(archs) do
        for _, e in ipairs(P().list(a)) do
            if not done[e.id] then
                done[e.id] = true
                cd.tex(e.thumb)
                if v2 and e.tile then
                    cd.tex(e.tile)
                else
                    cd.tex(e.full)
                    empty = v2
                end
            end
        end
    end
    if empty then pcall(function() cd.tex(P().EMPTY_TILE) end) end
end

---------------------------------------------------------------------------------------------------- API (§5.7.1)
-- setup.buildWidgets, once per page: cards.init (four collapsed card slots in ctx.row) + P1's sink in ctx.sinkHost.
-- ctx = {tree, pc, newW, row, sinkHost, realMs [, footer = {back, save, start}] [, pill = theme status pill]}. Raises
-- (setup's pcall) or returns false when the cards are unusable: that page keeps the classic columns. VERIFY(V-RC-01)
-- 0.12.0 (§8): the renderer of this page is cards2.lua unless cfg.UiStyle = "classic"; a cards2 that cannot load or
-- init falls back to cards.lua with the classic view model (logged), so the cards still work before / without it.
function M.build(ctx)
    if type(ctx) ~= "table" then error("racers.build: no context") end
    local s = S()
    local t0 = St.nowMs()
    s.built = false
    local want = (opt("UiStyle", "v2") == "classic") and "cards" or "cards2"
    local old = s.renderer
    if old and old ~= want then
        pcall(function() U.mod(old).forget() end)          -- its widgets belonged to an earlier page (UiStyle switched)
    end
    s.renderer, s.style = want, (want == "cards2") and "v2" or "classic"
    s.mode, s.cmdFocus, s.pillJoin, s.pillReady, s.readySig = nil, nil, nil, nil, nil
    if want == "cards2" then
        local ok, err = pcall(function() U.mod("cards2").init(ctx) end)
        if not ok then
            U.warn(TAG, "cards2.lua unusable (%s): this page draws the 0.11.0 cards (cards.lua, classic view model)",
                tostring(err):match("^[^\n]*") or "?")
            pcall(function() U.mod("cards2").forget() end)    -- a half-done init keeps nothing of this page
            s.renderer, s.style = "cards", "classic"
        end
    end
    if s.renderer == "cards" then CD().init(ctx) end
    s.ctx = ctx
    s.sink = buildSink(ctx)
    s.p1.ringAt = nil
    wireSink(s.sink, inputMode())
    s.built = true
    U.log(TAG, "built (4 card slots, P1 sink %s, %.1f ms; renderer %s, UiStyle %s) (V-RC-01)", tostring(s.sink.wired),
        St.nowMs() - t0, s.renderer, tostring(opt("UiStyle", "v2")))
    return true
end

-- setup.showStep("vehicles") in the cards flow: the players, their cards and previews; returns P1's focus target (the
-- sink). A new visit (the first enter since setup opened) starts every card at the first stage with the remembered
-- picks; MODE and back in the same class keeps every card's stage, rows and READY; a class change restarts every card
-- (the pilot kept when the class allows it, §2.7).
function M.enter(cls, planet)
    local s = S()
    if not s.built or type(cls) ~= "table" then return nil end
    local now = nowMs()
    local newVisit = s.visit == nil
    local classChange = s.arch ~= nil and s.arch ~= cls.arch
    s.cls, s.arch, s.planet = cls, cls.arch, planet
    s.visit = s.visit or { at = now }
    s.active, s.action, s.inPoll, s.lastPollAt = true, nil, false, nil
    s.p1.acceptAt, s.p1.leaking, s.p1.held, s.p1.keepNext = nil, false, false, 0
    -- an earlier visit's stamps go: setup.realMs restarts with each world when it falls back to the world's real time
    -- (state.lua clock on os.clock), and a stamp "in the future" would mute the sounds and drop P1's sink directions
    s.soundAt = -1e9
    s.p1.lastKbMs, s.p1.kbAcceptMs, s.p1.lastDirMs, s.p1.lastKeyMs = -1e9, -1e9, -1e9, -1e9
    s.persisted, s.classInfo, s.allReady = nil, {}, nil
    s.statusText, s.statusAt, s.statusHoldUntil, s.dormantAt, s.reconcileAt = nil, 0, 0, -1e9, now + RECONCILE_MS
    -- 0.12.0 v2: the pill entries start again (the join hint shows for StatusPillMs at entry, §6.5), the READY pips and
    -- P1's input mode are read at the first poll (before its renders)
    if s.style == "v2" then pillClear() end
    s.readySig = nil
    -- RC-2: the class's ramjet / critical-malfunction flags reach perks.lua before any loadout is built
    U.try(TAG, function() PA().systems(cls.arch) end)
    U.try(TAG, reconcile, newVisit and "new visit" or (classChange and "class change" or "same visit"), newVisit, now)
    for _, c in ipairs(s.order) do
        local pl = s.players[c]
        pl.nav.primed = false                    -- the guests' first poll is the baseline (the press that got here)
        markDirty(pl, now)
    end
    pcall(function() CD().layout(#s.order) end)
    U.try(TAG, prefetch)
    if s.sink then U.try(TAG, wireSink, s.sink, inputMode()) end
    -- VERIFY(V-RC-31): after a split race (menu owned by the last local PC) P1's pad still drives P1's card
    local owner, isP1 = "?", false
    pcall(function()
        if not U.ok(s.ctx.pc) then return end              -- a stored wrapper: U.ok before any member (ARCH 0.7.0 #8)
        owner = s.ctx.pc:GetFName():ToString()
        isP1 = U.same(s.ctx.pc, U.p1())
    end)
    U.log(TAG, "enter %s (%s, %d player(s)); page owner %s (%s) (V-RC-31)", tostring(cls.key),
        newVisit and "new visit" or (classChange and "class change" or "same visit"), #s.order, owner,
        isP1 and "P1" or "NOT P1")
    return target()
end

-- Another step, close or START (why "step <x>" keeps the visit; anything else ends it: the next open starts at
-- PILOT, READY never survives a re-open). Polling stops; the render images let go of the targets, then the bays go.
function M.leave(why)
    local s = S()
    why = tostring(why or "?")
    local was = s.active
    s.active, s.action, s.inPoll = false, nil, false
    s.p1.acceptAt = nil
    if not why:match("^step ") then s.visit = nil end
    if not was then return end
    if s.style == "v2" then
        -- 0.12.0: ALL READY / the join hint leave the pill (LAUNCHING... and the next step's texts are setup's),
        -- and P1's READY cursor lets go of the command row
        U.try(TAG, pillClear)
        U.try(TAG, commandFocus)
    end
    if g4Open() then U.try(TAG, G4().close, "racers: " .. why) end      -- the garage goes before its bays
    pcall(function() CD().releaseRenders(nil) end)
    local vp = VP()
    if vp then U.try(TAG, vp.releaseAll, "racers: " .. why, true) end
    U.log(TAG, "left (%s)%s", why, s.visit and "" or ": the visit ended")
end

-- The page died (menu replaced): every widget reference goes (its images died with it); picks stay in memory.
function M.forget()
    local s = S()
    s.active, s.built, s.visit, s.sink, s.ctx, s.action = false, false, nil, nil, nil, nil
    s.p1.acceptAt, s.p1.ringAt = nil, nil
    -- 0.12.0: the pill and the command row died with the page: nothing to clear there, only what this module recorded
    s.mode, s.cmdFocus, s.pillJoin, s.pillReady, s.readySig = nil, nil, nil, nil, nil
    for _, pl in pairs(s.players) do pl.pc = nil end
    if g4Open() then U.try(TAG, G4().close, "racers: menu replaced") end
    local vp = VP()
    if vp then U.try(TAG, vp.releaseAll, "racers: menu replaced", false) end
    pcall(function() CD().forget() end)
end

-- FAST (setup.pollNav, lobby not covered): §5.7.4 in order, each block guarded; one bad player never stops the others.
function M.poll(p1)
    local s = S()
    if not s.active then return end
    local now = nowMs()
    if now - (s.lastPollAt or now) > POLL_GAP_MS then
        -- the lobby was covered (the game's "Exit Game?" prompt, another page): what the pads did meanwhile is no edge,
        -- and a sink click queued before the gap is stale
        for _, c in ipairs(s.order) do
            local pl = s.players[c]
            if pl then pl.nav.primed = false end
        end
        s.p1.acceptAt = nil
        U.dbg(TAG, "poll resumed after %d ms: pads re-baselined", floor(now - s.lastPollAt))
    end
    s.lastPollAt = now
    s.inPoll = true
    if now >= s.reconcileAt then                 -- the "players" event is the path; this is the safety net
        s.reconcileAt = now + RECONCILE_MS
        U.tryEvery("racers.players", nil, TAG, reconcile, "poll", false, now)
    end
    -- 1. guests' pads
    for i = 2, #s.order do
        local pl = s.players[s.order[i]]
        if pl then U.tryEvery("racers.guest", nil, TAG, pollGuest, pl, now) end
    end
    -- 2. P1's sink focus
    if U.ok(p1) then U.tryEvery("racers.sink", nil, TAG, pollSink, p1, now) end
    -- 3. P1's queued accept (held one tick: this tick's guest A edges are known)
    U.tryEvery("racers.accept", nil, TAG, p1Accept, now)
    s.inPoll = false
    flushAction()
    if not s.active then return end              -- START / SAVE / MODE left the step
    -- 4. timers (+ v2: P1's input mode, before the renders that show it)
    U.tryEvery("racers.timers", nil, TAG, timers, now)
    local v2 = s.style == "v2"
    if v2 then U.tryEvery("racers.mode", nil, TAG, modeTick, now) end
    -- 5. previews (+ v2: the class's model-name read)
    U.tryEvery("racers.previews", nil, TAG, previews, now)
    if v2 then U.tryEvery("racers.names", nil, TAG, namesTick, now) end
    -- 6. cards: texture queue, deferred panels, START pulse
    U.tryEvery("racers.cards", nil, TAG, function() CD().tick() end)
    -- 7. renders
    U.tryEvery("racers.renders", nil, TAG, renders, now)
    -- 8. status line (classic) / this module's status-pill entries (v2)
    if v2 then
        U.tryEvery("racers.pill", nil, TAG, pillTick, now)
        -- 9. (v2) P1's READY cursor -> setup's command row (mouse + keyboard)
        U.tryEvery("racers.cmdfocus", nil, TAG, commandFocus)
    else
        U.tryEvery("racers.status", nil, TAG, statusTick, now)
    end
end

-- setup.keepFocus (lobby not covered): P1's focus back on the sink every KEEP_MS while P1 uses a pad and it is
-- elsewhere (mouse, modal, menu re-activation, R3).
function M.keepFocus()
    local s = S()
    if not s.active or not s.sink then return end
    local now = nowMs()
    if now < s.p1.keepNext then return end
    s.p1.keepNext = now + KEEP_MS
    if not p1Gamepad() then return end
    local p1 = U.p1()
    if not U.ok(p1) or sinkHolds(p1) then return end
    local t = target()
    if U.ok(t) then ui().focus(t, p1) end
end

-- Keyboard (keyq -> lobby.onKey -> setup.onKey, game thread): arrows = P1's directions, Enter / Space = P1's accept
-- unless a sink or footer button holds P1's focus (CommonUI clicks it itself: M.onSinkClick), Backspace ("back2") =
-- P1's back. Every key stamps lastKbMs: the CommonUI move an arrow also makes is then no sink event.
-- VERIFY(V-RC-03): Enter = 1 accept, Backspace = back.
function M.onKey(name)
    local s = S()
    if not s.active then return end
    local pl = p1Player()
    if not pl then return end
    local now = nowMs()
    local p = s.p1
    if name == "accept" then
        p.lastKbMs, p.kbAcceptMs = now, now
        local p1 = U.p1()
        if sinkHolds(p1) or footerHolds(p1) then return end
        dispatch(pl, "accept", false, "key", now)
    elseif name == "back2" then
        p.lastKbMs = now
        dispatch(pl, "back", false, "key", now)
    elseif name == "up" or name == "down" or name == "left" or name == "right" then
        p.lastKbMs = now
        local rep = p.lastKey == name and now - p.lastKeyMs < REPEAT_MS
        p.lastKey, p.lastKeyMs = name, now
        dispatch(pl, name, rep, "key", now)
    end
    flushAction()
    U.try(TAG, commandFocus)                     -- 0.12.0 v2: Up / Down on READY moves the command row's focus now
end

-- setup.pollP1Back: P1's B on its own PlayerController (after a race; never with KeyboardIsP1). From now on P1's hints
-- show B. VERIFY(V-RC-08): after a race the hints switch to B.
function M.onP1Back()
    local s = S()
    if not s.active then return end
    local pl = p1Player()
    if not pl then return end
    local now = nowMs()
    if not s.p1.sawB then
        s.p1.sawB = true
        U.log(TAG, "P1's B seen on its PlayerController: P1's hints show B from now on (V-RC-08)")
    end
    markDirty(pl, now)
    dispatch(pl, "back", false, "padB", now)
    flushAction()
    U.try(TAG, commandFocus)
end

-- ui.pollClicks (opts.noClaim) for any of the five sink buttons. The accept waits one FAST tick (p1Accept). Ignored:
-- KeyboardIsP1 with pad input (pad 1 is guest 1 and still Slate user 0, R4), and RC-6 a click in mouse + keyboard mode
-- without an Enter / Space keybind just before (a mouse click on the invisible sink area).
function M.onSinkClick(w)
    local s = S()
    if not s.active then return end
    local now = nowMs()
    local pad = p1Gamepad()
    if pad and kbP1() then
        U.logEvery("racers.kbp1click", 5000, TAG, "sink click ignored: KeyboardIsP1 and pad input (pad 1's A is guest "
            .. "1's) (V-RC-07)")
        return
    end
    if not pad and now - s.p1.kbAcceptMs > KB_ACCEPT_MS then
        U.logEvery("racers.mouseclick", 2000, TAG, "P1 sink click ignored: mouse (no Enter / Space within %d ms) "
            .. "(V-RC-30)", KB_ACCEPT_MS)
        return
    end
    s.p1.acceptAt, s.p1.clicked = now, true      -- clicked: the sink works (never "inactive")
end

-- Joins and leaves while the step shows (lobby's "players" listener -> setup.onPlayers).
function M.onPlayers()
    local s = S()
    if not s.active then return end
    U.try(TAG, reconcile, "players", false, nowMs())
end

-- [extension] setup.onPageShown (the page came back, e.g. from Settings): every card cache cleared and re-rendered
-- (a Slate rebuild may reset BP-applied colours, V-RC-06), a new still burst for every still bay (RC-12). Returns the
-- focus target.
function M.onPageShown()
    local s = S()
    if s.active then
        pcall(function() CD().clearCaches() end)
        local vp = VP()
        if vp then U.try(TAG, vp.recapture, "page shown") end
        local now = nowMs()
        for _, c in ipairs(s.order) do markDirty(s.players[c], now) end
    end
    return target()
end

-- [extension] P1's focus target (the sink's centre; ring: the last focused button).
function M.sink() return target() end

-- [extension] The LastRaceRacers parser for setup.deriveSetup: text -> {[ctrlId] = {pilot, preset, code}}.
M.parseRacers = parseRacers

-- 0.12.0 (§12.2; the lobby's players strip, §4.3): the head shot (Texture2D path) of the pad's last pilot, by
-- ControllerId (P1 = 0): this session's memory (the latest pick in any class), else the pad's LastRaceRacers entry
-- (read once per visit); nil when there is neither (the strip shows the player icon). Pure data: no engine call, cheap
-- enough for every lobby refresh.
function M.lastPilotThumb(ctrlId)
    local c = tonumber(ctrlId)
    if c == nil then return nil end
    local s = S()
    local id = nil
    local m = s.memory[c]
    if m then
        id = m.last
        if id == nil and s.arch ~= nil then id = m.pilot[s.arch] end
    end
    if type(id) ~= "string" then
        local ok, e = pcall(persisted, c)
        id = (ok and type(e) == "table") and e.pilot or nil
    end
    if type(id) ~= "string" then return nil end
    local ok, e = pcall(function() return P().byId(id) end)
    return (ok and type(e) == "table") and e.thumb or nil
end

-- The single mutator, for tests (test.cmd: require("racers").event(2, "right")): who = pnum (1..4) | "c<ctrlId>";
-- ev = up | down | left | right | accept | back; rep = an auto-repeat. -> true when the card changed.
function M.event(who, ev, rep, src)
    local s = S()
    if not s.active then return false end
    local pl = nil
    if type(who) == "number" then
        pl = s.players[s.order[who] or -1]
    elseif type(who) == "string" then
        local c = tonumber(who:match("^c(%d+)$"))
        pl = c and s.players[c] or nil
    end
    if not pl then return false end
    local ok, r = U.try(TAG, dispatch, pl, ev, rep == true, src or "test", nowMs())
    flushAction()
    U.try(TAG, commandFocus)
    return ok and r == true
end

-- setup.finish's START gate: allReady = every joined guest is on READY; waiting = {"P2", ...} (§2.6).
function M.readyState()
    local s = S()
    local waiting = {}
    for i = 2, #s.order do
        local pl = s.players[s.order[i]]
        if pl and pl.stage ~= "ready" then waiting[#waiting + 1] = nameOf(pl) end
    end
    return #waiting == 0, waiting
end

-- setup.makeChoice: {[pnum] = {ctrlId, pilotId, presetId, buildPath, loadout = lo (a copy), code}}. buildPath = the
-- class's zero base build (LastRaceVehicles keeps its format for the classic flow). 0.13.0 QUICK RACE: loadout / code
-- are the players' own builds; QUICK RACE forces copies at the launch (quick.forcePlan).
function M.choicePlayers()
    local s = S()
    local out = {}
    if s.arch == nil then return out end
    local bases = {}
    local function baseOf(arch)
        if bases[arch] == nil then
            bases[arch] = false
            pcall(function() bases[arch] = PA().basePath(arch) or false end)
        end
        return bases[arch] or nil
    end
    local Km = K()
    for i, c in ipairs(s.order) do
        local pl = s.players[c]
        -- 0.16 GALACTIC GRAND PRIX: a card in its player's own speeder class hands that class on (pick.arch: launch
        -- applyRecipe / perkapply race it; gp.prelaunch keeps the card's model)
        local want = pl and (wantClass(pl)) or nil
        if pl and want ~= nil and pl.arch == want and pl.lo then
            out[i] = { ctrlId = c, pilotId = pl.pilotId, presetId = pl.presetId, buildPath = baseOf(pl.arch),
                       loadout = Km.copy(pl.lo), code = Km.encode(pl.lo) }
            if pl.arch ~= s.arch then out[i].arch = pl.arch end
            -- 4-way garage: the pad's livery for this class and model (nil = the preset as it is; garage4.raceTick)
            local g = G4()
            if g then
                local okL, liv = pcall(g.pickLivery, c, pl.arch, pl.presetId)
                if okL and type(liv) == "table" then out[i].livery = liv end
            end
        end
    end
    -- 0.13.0 review: no QUICK forcing here (it stuck in the stored choice: a later CUSTOM "race again" raced the tier
    -- kit); quick.forcePlan forces copies at the launch
    return out
end

-- setup.persistExtras (SAVE / START): settings LastRaceRacers per ControllerId (§7.1). A pad not in this race keeps its
-- entry. VERIFY(V-RC-25): SAVE + reopen and quit + relaunch restore every pad's picks.
function M.persist(c)
    if settings.get(KEY_RACERS) == nil then return end   -- an older config without the key: nothing is saved
    local players = type(c) == "table" and type(c.setup) == "table" and c.setup.players or nil
    local hasIds = false
    for _, p in pairs(type(players) == "table" and players or {}) do
        if type(p) == "table" and tonumber(p.ctrlId) then hasIds = true end
    end
    if not hasIds then players = M.choicePlayers() end
    local entries = parseRacers(settings.get(KEY_RACERS))
    local saved = {}
    for _, p in pairs(players) do
        local cid = type(p) == "table" and tonumber(p.ctrlId) or nil
        if cid and type(p.pilotId) == "string" and type(p.presetId) == "string" then
            local code = p.code
            if type(code) ~= "string" and type(p.loadout) == "table" then code = K().encode(p.loadout) end
            -- 0.13.0: a player in the GALAXY RUN keeps the saved code of its own (non-run) build
            local r = runM()
            local okR, inR = pcall(function() return r and r.active() and r.state().players[cid] ~= nil end)
            if okR and inR and entries[cid] and entries[cid].code then code = entries[cid].code end
            -- 0.13.0 QUICK RACE: the tier kit is never saved: the card's own build, else the code on file
            if p.quick then
                local own = S().players[cid]
                code = (own and type(own.lo) == "table") and K().encode(own.lo) or (entries[cid] and entries[cid].code)
            end
            entries[cid] = { pilot = p.pilotId, preset = p.presetId, code = code }
            saved[#saved + 1] = tostring(cid)
        end
    end
    local ids = {}
    for cid in pairs(entries) do ids[#ids + 1] = cid end
    table.sort(ids)
    local parts = {}
    for _, cid in ipairs(ids) do
        local e = entries[cid]
        if e.pilot and e.preset then
            parts[#parts + 1] = string.format("%d=%s@%s@%s", cid, e.pilot, e.preset, e.code or "")
        end
    end
    local text = table.concat(parts, ";")
    settings.set(KEY_RACERS, text)
    S().persisted = nil
    table.sort(saved)
    U.log(TAG, "LastRaceRacers saved for ControllerId %s (%d pad(s) on file) (V-RC-25)", table.concat(saved, ", "), #parts)
    U.dbg(TAG, "LastRaceRacers = %s", text)
end

-- setup.preselect (setup.open with a new race choice): seeds the session memory from c.setup (St.race.choice) or from
-- setup.deriveSetup (settings): src = {arch | classKey, players = {[pnum] = {ctrlId, pilotId, presetId, loadout | code}}}.
-- A classic choice (no ControllerIds) seeds P1's preset only.
function M.restore(src)
    if type(src) ~= "table" or type(src.players) ~= "table" then return end
    local arch = tonumber(src.arch)
    if arch == nil and src.classKey then
        local cls = V.classByKey(src.classKey)
        arch = cls and cls.arch or nil
    end
    if arch == nil then return end
    local Pm, Km = P(), K()
    local n = 0
    for pnum, p in pairs(src.players) do
        local cid = type(p) == "table" and tonumber(p.ctrlId) or nil
        if cid == nil and tonumber(pnum) == 1 and type(p) == "table" then cid = 0 end
        if cid then
            local m = memOf(cid)
            if type(p.pilotId) == "string" and Pm.byId(p.pilotId) then
                m.pilot[arch], m.last = p.pilotId, p.pilotId     -- 0.12.0: the last race's pilot (M.lastPilotThumb)
            end
            if type(p.presetId) == "string" and V.presetById(arch, p.presetId) then m.preset[arch] = p.presetId end
            local style = Pm.styleKey(m.pilot[arch] or p.pilotId, arch)
            local lo = nil
            if p.quick then
                -- 0.13.0 QUICK RACE: a tier kit is not the player's build (memory keeps the own one)
            elseif type(p.loadout) == "table" then
                lo = Km.validate(p.loadout, arch, style)
            elseif type(p.code) == "string" and p.code ~= "" then
                local why
                lo, why = Km.decode(p.code, arch, style)
                if not lo then
                    U.logOnce("racers.decode." .. cid, TAG, "pad %d: loadout not decodable (%s)", cid, tostring(why))
                end
            end
            if type(lo) == "table" then m.lo = lo end
            n = n + 1
        end
    end
    U.log(TAG, "picks of %d pad(s) restored for archetype %d (V-RC-25)", n, arch)
end

-- One line for diag / test.cmd.
function M.status()
    local s = S()
    local parts = {}
    for _, c in ipairs(s.order) do
        local pl = s.players[c]
        if pl then
            local r = pl.row[pl.stage]
            local where = pl.picker and string.format("picker %s %d/%d", pl.picker.slot, pl.picker.sel, #pl.picker.items)
                or ((r == 0) and "strip" or ("row " .. tostring(r)))
            -- a card in another class than the page (GALACTIC GRAND PRIX) names it: "P2 c1 [Bike] PILOT ..."
            local own = (pl.arch ~= s.arch and clsOf(pl)) and ("[" .. tostring(clsOf(pl).key) .. "] ") or ""
            parts[#parts + 1] = string.format("%s c%d %s%s %s %s/%s/kit %s", nameOf(pl), c, own, STAGE_WORD[pl.stage] or "?",
                where, shortId(pl.pilotId), tostring(pl.presetId), tostring(pl.lo and pl.lo.kit))
        end
    end
    local p = s.p1
    local cards = "cards ?"
    pcall(function() cards = CD().status() end)
    -- 0.12.0: the renderer and view model of this page; v2: P1's input mode, the command-row focus, the pill entries
    local look = string.format("%s (%s view model)", tostring(s.renderer or "not built"), tostring(s.style or "-"))
    if s.style == "v2" then
        look = look .. string.format(", P1 mode %s, command focus %s, pill %s%s", tostring(s.mode or "?"),
            tostring(s.cmdFocus or "-"), s.pillReady and "ALL READY" or "-", s.pillJoin and " + join hint" or "")
    end
    if g4Open() then
        local okG, gs = pcall(function() return G4().status() end)
        if okG and gs then cards = cards .. " | " .. tostring(gs) end
    end
    return string.format("racers %s%s: %s | P1 input %s (sink events %d, drops %d, leaks %d, B seen %s) | %s | %s",
        s.active and "on" or "off", s.cls and (" " .. tostring(s.cls.key)) or "",
        (#parts > 0) and table.concat(parts, "; ") or "no players", s.sink and tostring(s.sink.wired) or "none",
        p.sinkEvents, p.drops, p.leaks, tostring(p.sawB), look, cards)
end

-- Text dump of a value: sorted keys, object paths shortened to their asset name, depth-limited.
local function ser(v, depth)
    local t = type(v)
    if t == "string" then
        local short = v:match("^/[%w_/]+%.([%w_]+)$")
        return string.format("%q", short or v)
    end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" then return "<" .. t .. ">" end
    if depth <= 0 then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) == "number" end
        return a < b
    end)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = ((type(k) == "number") and ("[" .. k .. "]") or tostring(k)) .. " = " .. ser(v[k], depth - 1)
    end
    return "{" .. table.concat(out, ", ") .. "}"
end

-- test.cmd: the view model a card would get now (no 3D brush is made), as text. who as in M.event (default P1).
function M.dump(who)
    local s = S()
    local pl = nil
    if type(who) == "string" then
        local c = tonumber(who:match("^c(%d+)$"))
        pl = c and s.players[c] or nil
    else
        pl = s.players[s.order[tonumber(who) or 1] or -1]
    end
    if not pl or not pl.stage then return "racers: no such player" end
    local ok, vm = pcall(buildVm, pl, nowMs(), false)
    if not ok then return "racers: view model failed: " .. tostring(vm) end
    return ser(vm, 6)
end

-- The module state (St.racers) for diag / test.cmd.
function M.state() return S() end

return M
