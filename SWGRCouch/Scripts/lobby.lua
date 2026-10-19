-- lobby.lua (G3 Front-end UI): the Lobby page behind our main-menu tab (FREE MODE, C.TAB_LABEL; SPLIT SCREEN before
-- 0.11.0): rows, labels, row actions.
-- Contract: notes/ARCHITECTURE.md §4.2 "G3 · lobby.lua", layout table §1.2, join rules §1.3, network rows §2.
--
-- Verified signatures (reflect-func-all.py):
--   UWidget:GetOwningPlayer() -> Object; UPanelWidget:ClearChildren(); UPanelWidget:AddChild(Object) -> Object;
--   UUserWidget:SetDesiredFocusWidget(Object Widget) -> Bool; UUserWidget.WidgetTree / UWidgetTree.RootWidget
--   (properties, reflect.tsv). Row widgets and their calls: see ui.lua.
--   UCommonActivatableWidget:RequestRefreshFocus(); PlayerController:IsInputKeyDown(Struct Key) -> Bool (via ui.keyDown).
-- Pad navigation (first live run, 2026-10-07: CommonUI focus never reached our rows): see "Pad / keyboard navigation"
-- at the end of this file.
-- RACE SETUP (2026-10-07 feedback): CHOOSE RACE opens setup.lua's flow INSIDE this page (the lobby rows are collapsed
-- while it is open, lobby.setSetupMode); input, focus keeping and status lines are forwarded to it. The game's dev
-- race builder stays reachable through the ADVANCED row (builder.open). cfg.SetupMode = "builder" restores the old
-- CHOOSE RACE behaviour.
--
-- 0.12.0 UI v2 (workflow ui-v2, 2026-10-10; the user: screens that "look like they belong to the game"). Binding spec
-- notes/design/ui-v2/ui-redesign-final.md §4 (lobby), §5 (OPTIONS), §12 WI-04; mockups work/design/ui-v2/final/
-- lobby-2p.png, lobby-1p.png, options.png. With cfg.UiStyle = "v2" (the default; read at page build, a live switch
-- rebuilds the page content at its next show) the emptied WBP_Setting_List root holds ONE FuseCanvasPanel
-- (St.ui.canvas, VerticalBoxSlot Fill) and everything is placed on it in screen su (theme.pageGeometry):
--   * five painted posters (theme.poster), 0.13.0 FREE MODE redesign (the user, 2026-10-12: "free mode should have
--     quick race, custom race and galaxy run (and add players and options)"): QUICK RACE (T_UI_FE_Tile_03), CUSTOM
--     RACE (T_UI_FE_Tile_05) and GALAXY RUN (T_UI_MapEvent_Bg) on the top row, ADD PLAYERS (T_UI_FE_Tiles_MP_Custom_01)
--     and OPTIONS (T_UI_Difficulty_Tile_04) below, each over an invisible ghost button (theme.ghost = ui.ghost) with
--     the ids "quick", "custom", "galaxy", "pads", "options", so St.ui.rows, refresh, focusedId, activate and
--     ui.pollClicks work as for the rows. QUICK / CUSTOM set PlayMode and open RACE SETUP; GALAXY RUN opens the run
--     page (runpage.lua: new run / continue / node / League); RIGHT on it does nothing (its focus trap only holds the
--     focus, 2026-10-14). The painted focus look follows the ghosts'
--     CommonUI focus / mouse hover every FAST tick (v2Tick, run from lobby.keepFocus);
--   * the START card (no ghost) under GALAXY RUN: what P1's pad Start does (race again / the run's next race / start
--     the armed run, or the C11 lock reason), read on the release of P1's Start (tilesTick);
--   * tile states (§4.2): QUICK / CUSTOM locked while a Galaxy run is on; the check badge on the mode START plays;
--     PLAYERS with the RUST "Press again to confirm" badge of the 2-press opt-in, locked while the player set is
--     frozen;
--   * the players strip (§4.3: join.slotStates; heads from racers.lastPilotThumb through an
--     M_UI_CharacterProfilePicture MID) and, while NETWORK is not OFFLINE, the network line (§4.4, net.statusText);
--     a change of that text is posted once to the pill;
--   * lobby messages (the "status" event) in theme's status pill (§4.5: 5 s; refusals and errors in the warn variant);
--   * OPTIONS (§5): a sub-page of the same page (lobby.openOptions / closeOptions; built at its first open, after the
--     page geometry was measured): hub background, "/OPTIONS" title, the §5.2 rows (theme.settingsRow; LABEL[id]() ->
--     label, value, kind, on), the help / "Default value" detail column, BACK in the command row, the back route (P1's
--     pad B edge, Backspace, BACK, a tab change; armBackGuard for the game's Exit prompt), list navigation (explicit
--     up / down chain, pad left / right through two invisible focus traps, keyboard left / right through onKey).
--   * OPTIONS > PLAYERS > Player names (2026-10-14): a sub-list of the OPTIONS page (V2.opt.sub = "names", its own
--     canvas in the list's place) with one row per slot; A opens the pad name editor in the row (nameedit.lua: up /
--     down letter, left / right cursor through four focus traps, X delete, A keep, B cancel; keyboard arrows /
--     Backspace / Enter), stored as settings Name1..Name4 and applied by nametags.lua. The players strip shows a
--     slot's custom name in its pad line. VERIFY(V-NAM-05).
--   * OPTIONS > ADVANCED > Delete all couch progress (#98, 2026-10-18: moved here from the COUCH CAMPAIGN act page):
--     the first A arms it (the RUST pill + the detail column say what goes and what stays; refused at once with the
--     reason when the COUCH save profile is not live), a second A on the same row 0.4 .. 10 s later runs
--     couchacts.deleteAll (same refusals, couchrun.wipe's dated copy, the game's RestartCampaignSelected). Moving the
--     focus off the row, closing OPTIONS or the window running out disarms it. Hidden with cfg.CouchDeleteProgress off.
-- UiStyle = "classic" (and a v2 page that cannot be built) keeps the 0.11.0 rows below unchanged.
-- VERIFY ids (spec §14): V-FIN-01 (page origin measured at the show vs the build), V-FIN-04 (ghost focus, explicit
-- navigation, clicks, focus traps), V-FIN-12 (the pill, theme.lua), V-FIN-15 (OPTIONS back route), V-FIN-17 (0.13.0:
-- P1's pad Start runs START on the FREE MODE page and opens no game screen).

local C = require("consts")
local cfg = require("config")
local settings = require("settings")
local St = require("state")
local U = require("util")
local sched = require("sched")

local lobby = {}

local TAG = "lobby"
local listenersRegistered = false
local restoredOnce = false

-- Optional config keys (ui.opt: nil -> default).
local function opt(name, default) return U.mod("ui").opt(name, default) end

-- Row order of §1.2 (ids are part of the contract: St.ui.rows[id]).
-- "pads" (2026-10-07): the ADD PLAYERS opt-in (join.enablePads); guests are never created by opening the tab.
local ROW_ORDER = {"hdr", "slot1", "slot2", "slot3", "slot4", "pads", "remote", "race", "adv", "layout", "gfx",
                   "takedown", "tags", "kbp1", "net", "netact", "start", "status"}

local GFX_TEXT = {auto = "AUTO", performance = "PERFORMANCE", quality = "QUALITY", off = "MY SETTINGS"}
local LAYOUT_TEXT = {["top-bottom"] = "TOP / BOTTOM", ["side-by-side"] = "SIDE BY SIDE"}
-- 0.12.0 UI v2: the same values in sentence case (OPTIONS tile kicker, "Default value: …"; spec §4.2, §5.2)
local GFX_WORD = {auto = "Auto", performance = "Performance", quality = "Quality", off = "My settings"}
local LAYOUT_WORD = {["top-bottom"] = "Top / bottom", ["side-by-side"] = "Side by side"}
local NET_WORD = {offline = "Offline", host = "Host", join = "Join"}
local MODE_WORD = {quick = "Quick race", custom = "Custom race"}       -- 0.13.0 settings PlayMode (quick.lua)
local RUN_PICKS = {"qualifier", "league", "kestar", "sprint"}         -- 0.14 GALAXY RUN v3 presets (settings RunPick)

-- "THE QUALIFIER (10 RACES)" for a preset key (run.presetLabel; the key upper-cased when run.lua is unavailable)
local function runLabel(key)
  local ok, t = pcall(function() return U.mod("run").presetLabel(key) end)
  return (ok and type(t) == "string") and t or string.upper(tostring(key or "?"))
end

-- the short name alone ("THE QUALIFIER"), for the poster kicker and the OPTIONS value
local function runName(key)
  local ok, t = pcall(function() return U.mod("run").presetName(key) end)
  return (ok and type(t) == "string") and t or string.upper(tostring(key or "?"))
end

local function onOff(v) return v and "ON" or "OFF" end

-- St.ui.texts[addr] = last text written, so refresh() only touches rows whose text changed.
local function texts()
  St.ui.texts = St.ui.texts or {}
  return St.ui.texts
end

-- Pad-navigation state (lobby.pollNav). hl = id of the highlighted row; marker = text prefix of that row
-- (cfg.LobbyNavMarker, or "> " automatically when ui.highlight cannot restyle the row).
-- covered: last input-target check said another screen is on top (lobbyCovered); layerBase: UIManager layer counts
-- at the lobby show; backGuard: a Back (pad B / Escape) was seen, the next accept is swallowed (it may confirm the
-- game's "Exit game?" prompt); consumed: {id, kind, untilMs} = the row run by our own accept, whose CommonUI click
-- on release is the same press; acceptUpMs: P1's accept release; keep: focus keeper window; kbBound: arrow/Enter
-- keybinds registered (then the keyboard is not polled through IsInputKeyDown).
local nav = { idx = nil, hl = nil, primed = false, prev = {}, vdir = 0, vNextMs = 0, hdir = 0, armUntilMs = 0,
              lastFocus = nil, autoMarker = false, seen = {}, keyLogged = false,
              covered = false, coverWhy = nil, layerBase = nil, backGuard = false, consumed = nil, acceptUpMs = -1e12,
              keep = { untilMs = 0, nextMs = 0, why = "", held = false }, kbBound = false }

---------------------------------------------------------------------------------------------------- UI v2 state
-- (spec §4 / §5; the code is in the "UI v2" section near the end of this file)
local TILE_IDS = {"quick", "custom", "galaxy", "pads", "options"}     -- the lobby ghosts (tiles mode, §4.6; 0.13.0)
local OPT_IDS = {"layout", "gfx", "takedown", "tags", "kbp1", "names", "run", "couch", "net", "netact", "adv",
                 "couchdel"}   -- OPTIONS (§5.3); couchdel: #98 Delete all couch progress; couch: the COUCH CAMPAIGN list
-- OPTIONS > PLAYER NAMES (2026-10-14, Jules: "in the free mode option let's add p1 p2 p3 p4 custom names"): the
-- "names" row opens a sub-list of the OPTIONS page (V2.opt.sub = "names") with one row per slot; A on a row opens the
-- pad name editor (nameedit.lua) in place. Names are settings Name1..Name4; nametags.lua applies them.
local NAME_IDS = {"name1", "name2", "name3", "name4"}
local NAME_SLOT = {name1 = 1, name2 = 2, name3 = 3, name4 = 4}
-- OPTIONS > PLAYERS > Couch campaign (couch-fix39, audit Q10): the COUCH CAMPAIGN group, a sub-list like PLAYER NAMES
-- (the OPTIONS list has no room for another group: it already ends at the status pill). One row per couch rule; every
-- row is self-contained (lobby.SUBS.couch.ids + LABEL / BUTTON_ACTIONS / LR_ACTIONS / HELP entries).
-- the OPTIONS sub-lists: V2.opt.sub -> its rows, group header, the OPTIONS row that opens it (a field of lobby, not a
-- local: lobby.lua's main chunk is at Lua's 200-locals limit)
lobby.SUBS = { names = { ids = NAME_IDS, header = "PLAYER NAMES", opener = "names", first = "name1" },
               couch = { ids = {"mystteam", "couchecon"}, header = "COUCH CAMPAIGN", opener = "couch", first = "mystteam" } }
function lobby.SUBS.idsOf(O)
  local sb = O and O.sub and lobby.SUBS[O.sub]
  return sb and sb.ids or OPT_IDS
end

-- One page instance (lobby.resetNav replaces it: the widgets die with their page). style: the UiStyle the page was
-- built for ("v2" | "classic"; a v2 build that failed falls back to the rows and keeps "v2", so no rebuild loop);
-- active: the v2 canvas is up; mode: "tiles" | "options"; geo: the page geometry the content was placed with (screen
-- su; theme's builders convert with it), geoNow: the latest measurement, shift: the canvas render translation that
-- corrects the difference (alignCanvas, V-FIN-01); posters / again / badge / strip / pill / opt: theme
-- elements (again: the START card); painted: the tile with the focus look;
-- sig: refresh signatures; ghostKeys: registry keys of our ghosts (dropped when the v2 build fails); bPrev / wasCovered:
-- the OPTIONS back route's B edge; lrAtMs: last left / right step (a focus trap skips a second step of one press);
-- trapR: GALAXY RUN's right focus trap; sPrev / sArmed: P1's pad Start (held at the last tick / pressed while nothing
-- covered the lobby: the release runs START).
local function newV2()
  return { style = nil, active = false, mode = "tiles", ctx = nil, root = nil, geo = nil, geoNow = nil,
           shift = {0, 0}, canvas = nil, tilesCv = nil, posters = {}, again = nil, badge = {},
           badgeOn = false, strip = nil, pill = nil, opt = nil, painted = nil, sig = {}, ghostKeys = {},
           bPrev = true, wasCovered = false, lrAtMs = -1e9, optLast = nil, headWait = false, focusSeen = false,
           raceRacers = nil, startState = nil, againKey = nil, againView = nil, fitIn = nil, fitOut = nil,
           trapR = nil, sPrev = true, sArmed = false }
end
local V2 = newV2()

local padsConfirmUntilMs = 0     -- ADD PLAYERS 2-press window (lobby.onPads, PADS_CONFIRM_MS); the v2 PLAYERS badge shows meanwhile
local pendingLevel = nil         -- {text, warn}: the pill level of the next "status" text this module emits (say)

local function theme() return U.mod("theme") end

-- Container visibility (our canvases): SelfHitTestInvisible (the children stay clickable) or Collapsed.
local function showW(w, on)
  if not U.ok(w) then return end
  pcall(function() w:SetVisibility(on and C.E.Vis.SelfHitTestInvisible or C.E.Vis.Collapsed) end)
end

-- Screen su -> canvas-local su: the content is placed with V2.geo (alignCanvas corrects a later measurement).
local function LP(x, y) return {x - V2.geo.x, y - V2.geo.y} end
local function LR(x, y, w, h) return {x - V2.geo.x, y - V2.geo.y, w, h} end

-- forward declarations: assigned in the UI v2 section
local buildV2, v2Refresh, v2Tick, alignCanvas, styleCheck

local function navMarker()
  local m = U.mod("ui").opt("LobbyNavMarker", "")
  if (m == nil or m == "") and nav.autoMarker then m = "> " end
  return tostring(m or "")
end

-- St.ui.baseTexts[id] = text without the highlight marker (setRowText re-decorates when the highlight moves).
local function baseTexts()
  St.ui.baseTexts = St.ui.baseTexts or {}
  return St.ui.baseTexts
end

local function setRowText(id, text)
  local w = St.ui.rows[id]
  if not U.ok(w) then return end
  text = tostring(text or "")
  baseTexts()[id] = text
  if nav.hl == id and id ~= "hdr" then text = navMarker() .. text end
  local k = U.key(w)
  if texts()[k] == text then return end
  local ui = U.mod("ui")
  local isButton = St.ui.buttons[k] ~= nil
  local ok = U.try(TAG, function()
    if id == "hdr" then
      w:SetHeaderText(U.ftext(text))     -- WBP_SectionHeaderModal_C:SetHeaderText(Text)
    elseif isButton then
      ui.setButtonText(w, text)
    else
      ui.setLabelText(w, text)
    end
  end)
  if ok then texts()[k] = text end
end

-- St.ui.shown[id] / St.ui.enabled[id]: last applied state (avoid redundant BP calls on every refresh).
local function setRowShown(id, on)
  local w = St.ui.rows[id]
  if not U.ok(w) then return end
  St.ui.shown = St.ui.shown or {}
  if St.ui.shown[id] == on then return end
  if U.try(TAG, function() U.mod("ui").setShown(w, on) end) then St.ui.shown[id] = on end
end

local function setRowEnabled(id, on)
  local w = St.ui.rows[id]
  if not U.ok(w) then return end
  St.ui.enabled = St.ui.enabled or {}
  if St.ui.enabled[id] == on then return end
  if U.try(TAG, function() U.mod("ui").setEnabled(w, on) end) then St.ui.enabled[id] = on end
end

local function status(text)
  -- User-visible message: status row (via the "status" listener) and the log.
  U.log(TAG, "%s", text)
  St.emit("status", text)
end

-- 0.12.0: status() with its pill level: warn = true for refusals and errors (the RUST warn pill, spec §4.5 / §2.6).
-- The "status" listener (lobby.setStatus) reads it; the classic status row ignores it (same text, same log).
local function say(text, warn, ms)
  pendingLevel = {text = tostring(text or ""), warn = warn == true, ms = ms}
  status(text)
end

-- Pill level of a status text another module emitted: refusals / errors take the warn variant (§4.5). The lobby's
-- own texts carry their level (say).
local WARN_WORDS = {"FIRST", "ONLY", "FAIL", "ERROR", "REFUSED", "TIMED OUT", " NOT ", "CANNOT", "COULD NOT",
                    "UNAVAILABLE", "MUST ", "GAVE UP", "DROPPED", "DISCONNECT TO CHANGE"}
local function isWarnText(s)
  s = string.upper(tostring(s or ""))
  if s:sub(1, 3) == "NO " then return true end
  for _, w in ipairs(WARN_WORDS) do
    if s:find(w, 1, true) then return true end
  end
  return false
end

-- The RACE SETUP flow (setup.lua) is open over the lobby rows.
local function setupActive()
  local ok, v = pcall(function() return U.mod("setup").isActive() end)
  return ok and v == true
end

local function validChoice()
  local okB, valid = pcall(function()
    local c = St.race.choice
    return c ~= nil and U.mod("builder").isValid(c)
  end)
  return okB and valid == true
end

-- 0.13.0 GALAXY RUN (run.lua): a run is on / between two of its races / armed (RunLength: the next launch starts one).
local function runIs(what)
  local ok, v = pcall(function()
    local run = U.mod("run")
    if what == "on" then return run.active() end
    if what == "between" then return run.betweenRaces() end
    return (not run.active()) and run.lengthSetting() ~= nil
  end)
  return ok and v == true
end

-- 0.16 GALACTIC GRAND PRIX (gp.lua): "on" (running) / "between" (between two of its races) / "done" (podium waiting)
local function gpIs(what)
  if cfg.GrandPrix == false then return false end
  local ok, v = pcall(function()
    local g = U.mod("gp")
    if what == "on" then return g.active() end
    if what == "between" then return g.betweenRaces() end
    if what == "done" then return g.done() end
    return false
  end)
  return ok and v == true
end

-- 0.13.0: the poster of the mode START plays (its check badge, the default focus): GALAXY RUN while a run is on or
-- armed, else the PlayMode's.
local function modeTile()
  if runIs("on") or runIs("armed") or gpIs("on") then return "galaxy" end
  return (settings.get("PlayMode") == "custom") and "custom" or "quick"
end

local function netMode()
  return settings.get("NetMode") or "offline"
end

local function isClient()
  local ok, v = pcall(function() return U.mod("net").isConnectedClient() end)
  return ok and v == true
end

local function isListening()
  local ok, v = pcall(function() return U.mod("net").isListening() end)
  return ok and v == true
end

-- net.lua's port / join address (a JoinAddress that already carries a port keeps it), for the OPTIONS action row.
local function port()
  return math.floor(tonumber(settings.get("Port")) or 7777)
end

local function joinAddr()
  local a = tostring(settings.get("JoinAddress") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if a:match("^[^:]+:%d+$") then return a end
  return a .. ":" .. tostring(port())
end

-- PLAYER NAMES (nametags.lua resolves the names, settings Name1..Name4 hold them, nameedit.lua is the pad editor).
-- nameEdit = {slot, e = nameedit state, def = the slot's default name} while one name row is being edited.
local NE = require("nameedit")
local nameEdit = nil
local function tagsMod()
  local ok, m = pcall(U.mod, "nametags")
  if ok and type(m) == "table" then return m end
  return nil
end
local function customName(n)
  local m = tagsMod()
  if not m then return nil end
  local ok, v = pcall(m.customName, n)
  return ok and v or nil
end
-- P1's PlayerState (its profile name in the front end), nil when unreadable
local function p1State()
  local ps = nil
  pcall(function()
    local p1 = U.p1()
    if U.ok(p1) and U.ok(p1.PlayerState) then ps = p1.PlayerState end
  end)
  return ps
end
-- The slot's name without a custom one: P1's profile name, "Player <n>" (cfg.GuestNames) for the guests.
local function defaultName(n)
  local m = tagsMod()
  if not m then return "P" .. n end
  local ok, v
  if n == 1 then
    ok, v = pcall(function()
      local ps = p1State()
      local name = ps and U.str(ps:GetPlayerName()) or nil     -- uobj: U.ok(ps) in p1State
      if name and name ~= "" and name ~= customName(1) then return name end
      return "Player 1"
    end)
  else
    ok, v = pcall(m.defaultGuestName, n)
  end
  return (ok and type(v) == "string" and v ~= "") and v or ("Player " .. n)
end
local function cutText(s, max)
  s = tostring(s or "")
  if (utf8.len(s) or #s) <= max then return s end
  local okO, o = pcall(utf8.offset, s, max)
  return ((okO and o) and s:sub(1, o - 1) or s:sub(1, max - 1)) .. "\u{2026}"
end
-- the "Player names" row: "JULES · P2 · P3 · P4" (custom names, else the P-tag), "DEFAULT" when none is set
local function namesSummary()
  local parts, any = {}, false
  for n = 1, 4 do
    local c = customName(n)
    if c then any = true end
    parts[n] = c or ("P" .. n)
  end
  if not any then return "DEFAULT" end
  return cutText(table.concat(parts, " \u{00B7} "), 44)
end
local function nameValue(n)
  if nameEdit and nameEdit.slot == n then return NE.render(nameEdit.e) end
  local c = customName(n)
  if c then return c end
  return defaultName(n) .. " (default)"
end

-- #98 OPTIONS > ADVANCED > Delete all couch progress (couchacts.deleteAll does the work and re-checks every refusal).
-- lobby.CD.armedMs / untilMs: the first A's time and the end of its confirm window (0 = not armed); prof: the cached
-- couch save profile check {live, why, atMs} (it reads files: at most once per CD.PROFILE_MS for the row text).
-- (a field of lobby, no local: the main chunk is at Lua's 200-locals limit)
lobby.CD = { armedMs = 0, untilMs = 0, focusId = nil, prof = nil, CONFIRM_MS = 10000, GUARD_MS = 400,
             PROFILE_MS = 3000 }
function lobby.CD.acts()
  local ok, m = pcall(U.mod, "couchacts")
  if ok and type(m) == "table" then return m end
  return nil
end
function lobby.CD.on() return opt("CouchDeleteProgress", true) ~= false end
function lobby.CD.profile(fresh)
  local now = St.nowMs()
  local p = lobby.CD.prof
  if fresh or not p or now - p.atMs > lobby.CD.PROFILE_MS then
    local A = lobby.CD.acts()
    local okL, live, why = false, false, "The couch campaign module is not loaded."
    if A then okL, live, why = pcall(A.couchProfileLive) end
    if not okL then live, why = false, tostring(live) end
    p = { live = live == true, why = tostring(why or ""), atMs = now }
    lobby.CD.prof = p
  end
  return p
end
function lobby.CD.armed() return lobby.CD.untilMs > 0 and St.nowMs() <= lobby.CD.untilMs end
function lobby.CD.disarm(why)
  if lobby.CD.untilMs == 0 then return end
  lobby.CD.armedMs, lobby.CD.untilMs, lobby.CD.focusId = 0, 0, nil
  U.log(TAG, "DELETE ALL COUCH PROGRESS: confirm disarmed (%s)", tostring(why))
  St.ui.dirty = true
end

-- Settings rows (§1.2; UI v2 §5.2 "LABEL -> label / value / kind"): LABEL[id]() -> label (v2, sentence case), value
-- (upper case), kind ("cycle" | "toggle" | "action"), on (toggles). The classic row text is CLASSIC_NAME[id] .. ": "
-- .. value (classicText: the 0.11.0 texts, unchanged).
local LABEL = {
  layout = function() return "2-player layout", LAYOUT_TEXT[settings.get("Layout2P")] or "TOP / BOTTOM", "cycle" end,
  gfx = function()
    local v = settings.get("SplitGraphics")
    return "Split graphics", GFX_TEXT[v] or string.upper(tostring(v)), "cycle"
  end,
  takedown = function()
    local v = settings.get("TakedownCams")
    return "Takedown cameras", onOff(v), "toggle", v and true or false
  end,
  tags = function()
    local v = settings.get("NameTags")
    return "Name tags", onOff(v), "toggle", v and true or false
  end,
  kbp1 = function()
    local v = settings.get("KeyboardIsP1")
    return "Keyboard is player 1", onOff(v), "toggle", v and true or false
  end,
  net = function() return "Network", string.upper(netMode()), "cycle" end,
  -- v2 OPTIONS action row (collapsed offline; the classic row shows net.netactLabel() itself)
  netact = function()
    local mode = netMode()
    local text = ""
    pcall(function() text = tostring(U.mod("net").netactLabel() or "") end)
    if mode == "host" then
      return "Host on port " .. tostring(port()), text:find("^STOP") and "STOP" or "START", "action"
    elseif mode == "join" then
      return "Connect to " .. joinAddr(), (text == "DISCONNECT") and "DISCONNECT" or "CONNECT", "action"
    end
    return "", "", "action"
  end,
  adv = function() return "Race builder", "OPEN", "action" end,   -- v2 OPTIONS > ADVANCED (§4.7: the word DEV goes)
  couch = function() return "Couch campaign", "OPEN", "action" end,  -- couch-fix39: opens the COUCH CAMPAIGN sub-list
  -- couch-fix39 (audit Q10) COUCH CAMPAIGN > a guest's mystery choice with a TEAM effect: greyed | allowed
  mystteam = function()
    local v = settings.get("CouchMysteryTeam")
    return "Guests' team mystery choices", (v == "allowed") and "ALLOWED" or "GREYED", "cycle"
  end,
  -- couch-fix35 (Jules's Q1) COUCH CAMPAIGN > P1's rewards: OWN PLACE (his wallet / round follow his own result) |
  -- BEST CARRIES EVERYONE (the old rule)
  couchecon = function()
    local v = settings.get("CouchEconomy")
    return "P1's rewards", (v == "best") and "BEST CARRIES EVERYONE" or "OWN PLACE", "cycle"
  end,
  names = function() return "Player names", namesSummary(), "action" end,   -- opens the PLAYER NAMES sub-list
  -- #98: armed = the second A deletes; LOCKED while the COUCH save profile is not live
  couchdel = function()
    if lobby.CD.armed() then return "Delete all couch progress", "PRESS (A) AGAIN", "action" end
    return "Delete all couch progress", lobby.CD.profile().live and "DELETE" or "LOCKED", "action"
  end,
  -- GALAXY RUN v3 (run.lua): off / a League preset; while a run is on: its race and tokens, A twice abandons it
  run = function()
    local okR, r = pcall(function() return U.mod("run") end)
    local st = okR and r and r.state and r.state() or nil
    if st and st.status == "on" then
      return "Galaxy run", string.format("RACE %d / %d · TOKENS %d", st.race or 1, st.length or 0, st.hull or 0), "action"
    end
    local v = tostring(settings.get("RunLength") or "off")
    return "Galaxy run", (v == "off") and "OFF" or runName(v), "cycle"
  end,
}

for id, n in pairs(NAME_SLOT) do
  -- the edited row shows the cycle arrows (its left / right move the cursor)
  LABEL[id] = function()
    return "Player " .. n, nameValue(n), (nameEdit and nameEdit.slot == n) and "cycle" or "action"
  end
end

local CLASSIC_NAME = {layout = "2P LAYOUT", gfx = "SPLIT GRAPHICS", takedown = "TAKEDOWN CAMERAS", tags = "NAME TAGS",
                      kbp1 = "KEYBOARD IS P1", net = "NETWORK"}

-- Texts of the classic rows that are not settings rows.
local CLASSIC_TEXT = {
  race = function()
    if validChoice() then
      local c = St.race.choice
      local extra = ""
      if type(c.setup) == "table" and c.setup.grid == "max" and tonumber(c.setup.maxRacers) then
        extra = string.format(" / %d RACERS", c.setup.maxRacers)
      end
      return "RACE: " .. tostring(c.label or "?") .. extra .. " >"
    end
    return "CHOOSE RACE >"
  end,
  adv = function() return "ADVANCED: DEV RACE BUILDER >" end,
  pads = function()
    local ok, on = pcall(function() return U.mod("join").padsEnabled() end)
    if ok and on then return "PADS ON (UNTIL GAME RESTART)" end
    return "ADD PLAYERS (PADS) >"
  end,
}

local function classicText(id)
  local f = CLASSIC_TEXT[id]
  if f then return f() end
  local _, value = LABEL[id]()
  return CLASSIC_NAME[id] .. ": " .. tostring(value)
end

-- START row: text + enabled, §1.2 / §4.2 refresh rules.
local function startState()
  if St.launch.pending then return "LAUNCHING...", false end
  local mode = netMode()
  if mode == "join" or isClient() then return "WAITING FOR HOST", false end
  if mode == "host" then
    if not isListening() then return "START HOSTING FIRST", false end
    return "START RACE", validChoice()
  end
  return "START RACE", validChoice()
end

-- 0.12.0 v2 START tile (spec §4.2 tile states), with startState's precedence: {kind, lock (the C11 reason), pill (the
-- warn text A posts)}. A locked START still takes focus.
local function startStateV2()
  if St.launch.pending then return {kind = "launching"} end
  local mode = netMode()
  if mode == "join" or isClient() then
    return {kind = "waiting", lock = "Waiting for the host", pill = "WAITING FOR THE HOST"}
  end
  if mode == "host" and not isListening() then
    return {kind = "hosting", lock = "Start hosting in Options", pill = "START HOSTING IN OPTIONS"}
  end
  if not validChoice() then
    return {kind = "norace", lock = "Choose a race first", pill = "CHOOSE A RACE FIRST"}
  end
  return {kind = "ok"}
end

local function registerListeners()
  if listenersRegistered then return end
  listenersRegistered = true
  St.on("tab", TAG, function(shown)
    if shown then lobby.onShown() else lobby.onHidden() end
  end)
  St.on("status", TAG, function(text) lobby.setStatus(text) end)
  local function markDirty() St.ui.dirty = true end
  St.on("players", TAG .. ".setup", function()
    pcall(function() U.mod("setup").onPlayers() end)
  end)
  St.on("phase", TAG .. ".setup", function(new)
    if new ~= "FRONTEND" and setupActive() then
      -- 0.12.0: in the launch hold the page is already being freed: forget it (no widget call), as on a new menu
      if St.launchHold() then U.try(TAG, function() U.mod("setup").forget() end)
      else U.try(TAG, function() U.mod("setup").close("phase " .. tostring(new)) end) end
    end
  end)
  for _, ev in ipairs({"players", "net", "race_chosen", "settings", "phase"}) do
    St.on(ev, TAG, markDirty)
  end
  -- A status line belongs to the world it was written in ("LOADING…" must not greet the post-race lobby). Cleared on
  -- the world change, i.e. before the FRONTEND listeners (join.resync, net.onFrontEnd) write the new one.
  St.on("world", TAG, function()
    St.ui.statusText = ""
    St.ui.dirty = true
    if V2.pill then pcall(V2.pill.clear) end            -- 0.12.0: the v2 status pill too (a dead page ignores it)
  end)
end

-- Page root: the emptied WBP_Setting_List_C box, or (cfg.LobbyRootMode = "own", §7) our own FuseVerticalBox.
local function pageRoot(page)
  local tree = page.WidgetTree                        -- UUserWidget.WidgetTree (property)
  if not U.ok(tree) then return nil, "page.WidgetTree invalid" end
  if cfg.LobbyRootMode == "own" then
    local boxCls = U.class("/Script/Griffin.FuseVerticalBox")
    if not U.ok(boxCls) then return nil, "class /Script/Griffin.FuseVerticalBox not found" end
    -- StaticConstructObject(UClass, Outer): a plain UObject construction (UMG panels are UObjects, not actors).
    local box = StaticConstructObject(boxCls, tree)
    if not U.ok(box) then return nil, "StaticConstructObject(FuseVerticalBox) failed" end
    tree.RootWidget = box                             -- before the page is added, i.e. before Slate is built
    return box
  end
  -- VERIFY(V-LOB-01): the Setting_List root is SettingsVerticalLayut (a FuseVerticalBox); fallback
  -- cfg.LobbyRootMode = "own".
  local root = tree.RootWidget                        -- UWidgetTree.RootWidget (property)
  if not U.ok(root) then return nil, "WidgetTree.RootWidget invalid" end
  if not U.isA(root, "/Script/UMG.VerticalBox") then
    return nil, "WidgetTree.RootWidget is not a VerticalBox (" .. tostring(root:GetFullName()) .. ")"
  end
  root:ClearChildren()                                -- UPanelWidget::ClearChildren()
  return root
end

local BUTTON_ACTIONS = {
  pads = function() lobby.onPads() end,
  race = function() lobby.onRace() end,
  adv = function() lobby.onAdvanced() end,
  layout = function() lobby.onLayout() end,
  gfx = function() lobby.onGfx() end,
  takedown = function() lobby.onTakedown() end,
  tags = function() lobby.onTags() end,
  kbp1 = function() lobby.onKbP1() end,
  net = function() lobby.onNet() end,
  netact = function() lobby.onNetAction() end,
  start = function() lobby.onStart() end,
  options = function() lobby.openOptions() end,       -- 0.12.0 v2: the OPTIONS tile
  run = function(dir) lobby.onRun(dir) end,            -- 0.13.0 OPTIONS > Galaxy run
  names = function() lobby.openNames() end,            -- OPTIONS > Player names (sub-list)
  couchdel = function() lobby.onCouchDelete() end,     -- #98 OPTIONS > Delete all couch progress (2-press confirm)
  couch = function() lobby.openCouch() end,            -- couch-fix39 OPTIONS > Couch campaign (sub-list)
  mystteam = function() lobby.onMystTeam() end,        -- couch-fix39 COUCH CAMPAIGN > Guests' team mystery choices
  couchecon = function() lobby.onCouchEcon() end,      -- couch-fix35 COUCH CAMPAIGN > P1's rewards
}
for id, n in pairs(NAME_SLOT) do BUTTON_ACTIONS[id] = function() lobby.onName(n) end end

-- 0.12.0 v2 START (0.13.0: P1's pad Start on the FREE MODE page, the START card shows what it does): locked = the
-- reason as a warn pill; launching = ignored.
local function startTile()
  local st = startStateV2()
  if st.kind == "launching" then
    U.dbg(TAG, "START tile: a launch is pending, A ignored")
    return
  end
  if st.lock then
    say(st.pill, true)
    St.ui.dirty = true
    return
  end
  -- review fix (task #14): a guest's A can also click P1's CommonUI focus (START was the 0.12.0 default focus, §4.6):
  -- a START within CardGuestClickGuardMs of a guest pad's A is that guest's join / press, not P1's START (racers.lua's
  -- V-RC-07 guard on P1's sink)
  local okG, gid, age = pcall(function()
    return U.mod("join").guestPressWithin(tonumber(opt("CardGuestClickGuardMs", 150)) or 150)
  end)
  if okG and gid ~= nil then
    U.log(TAG, "START tile click dropped: guest pad %s pressed A %d ms before it (task #14, V-RC-07)", tostring(gid),
      math.floor(tonumber(age) or 0))
    return
  end
  lobby.onStart()
end

-- 0.13.0 (task #14): the same guest-press guard on every poster (a joining guest's A also clicked RACE / ADD PLAYERS /
-- OPTIONS under P1's cursor: RACE SETUP opened on a join).
local function guarded(id, fn)
  return function(...)
    local okG, gid, age = pcall(function()
      return U.mod("join").guestPressWithin(tonumber(opt("CardGuestClickGuardMs", 150)) or 150)
    end)
    if okG and gid ~= nil then
      U.log(TAG, "%s tile click dropped: guest pad %s pressed A %d ms before it (task #14, V-RC-07)", id,
        tostring(gid), math.floor(tonumber(age) or 0))
      return
    end
    return fn(...)
  end
end

-- Actions of the v2 page that differ from the rows' (resolved per call: a page may change style after a rebuild).
local V2_ACTIONS = {quick = guarded("QUICK RACE", function() lobby.onQuick() end),
                    custom = guarded("CUSTOM RACE", function() lobby.onCustom() end),
                    galaxy = guarded("GALAXY RUN", function() lobby.onGalaxy() end),
                    pads = guarded("ADD PLAYERS", function() lobby.onPads() end),
                    options = guarded("OPTIONS", function() lobby.openOptions() end)}
local function actionOf(id)
  if V2.active and V2_ACTIONS[id] then return V2_ACTIONS[id] end
  return BUTTON_ACTIONS[id]
end

-- The click function a v2 ghost registers (ui.pollClicks / the click hook call it with the widget). The page is
-- refreshed at once, so a stepped OPTIONS value or a tile state shows in the same tick (as activate does).
local function ghostFn(id)
  return function()
    local fn = actionOf(id)
    if fn then fn() end
    St.ui.dirty = true
    if St.menu.visible == "lobby" then U.try(TAG, lobby.refresh) end
  end
end

local function wantStyle() return (opt("UiStyle", "v2") == "classic") and "classic" or "v2" end

-- The 0.11.0 rows (UiStyle "classic", or a v2 page that could not be built).
local function buildClassic(page, root, pc)
  local ui = U.mod("ui")
  for _, id in ipairs(ROW_ORDER) do
    local w
    if id == "hdr" then
      w = ui.header(pc, C.TAB_LABEL)
    elseif BUTTON_ACTIONS[id] then
      w = ui.button(pc, id, "", BUTTON_ACTIONS[id])
    else
      w = ui.label(pc, "")   -- slot1..4, remote, status
    end
    if w then
      if id ~= "hdr" then ui.styleRow(w) end         -- IsInvert before Slate builds the row (readable on the light page)
      ui.addRow(root, w, (id == "hdr") and 0 or 4, (id == "hdr") and 12 or 4)
      St.ui.rows[id] = w
    else
      U.warn(TAG, "row '%s' could not be created", id)
    end
  end

  if U.ok(St.ui.rows.race) then
    page:SetDesiredFocusWidget(St.ui.rows.race)       -- SetDesiredFocusWidget(Object Widget) -> Bool
  end
end

-- Page content into the emptied root: the v2 canvas (UiStyle "v2") or the 0.11.0 rows. -> the style built.
local function buildContent(page, root, pc)
  St.ui.rows, St.ui.texts, St.ui.shown, St.ui.enabled = {}, {}, {}, {}
  lobby.resetNav()
  V2.style = wantStyle()
  if V2.style == "v2" then
    local ok = U.try(TAG, buildV2, page, root, pc)
    if ok and V2.active then return "v2" end
    U.err(TAG, "UI v2 lobby page could not be built (see above): this page uses the classic rows")
    for _, k in ipairs(V2.ghostKeys) do St.ui.buttons[k] = nil end
    pcall(function() root:ClearChildren() end)
    if package.loaded.theme then pcall(function() package.loaded.theme.forget() end) end
    St.ui.rows, St.ui.texts, St.ui.shown, St.ui.enabled = {}, {}, {}, {}
    lobby.resetNav()
    V2.style = "v2"                                   -- the request stays: no rebuild at every show (styleCheck)
  end
  buildClassic(page, root, pc)
  return "classic"
end

-- v2 default focus (§4.6; 0.13.0): the poster of the mode START plays.
local function desiredFocusV2()
  local w = St.ui.rows[modeTile()]
  if U.ok(w) and U.ok(St.menu.lobby) then St.menu.lobby:SetDesiredFocusWidget(w) end
end

-- Live UiStyle switch (spec §13: "switched live, then re-open the page"): the content is rebuilt in place at the next
-- show of the page. The RACE SETUP panel is rebuilt with it (setup.lua picks its style at its own build).
local function rebuildContent(why)
  local page = St.menu.lobby
  if not U.ok(page) then return false end
  local root, pc
  pcall(function() root = page.WidgetTree.RootWidget end)
  if not U.ok(root) then return false end
  pcall(function() pc = page:GetOwningPlayer() end)
  U.log(TAG, "FREE MODE page rebuilt in place (%s)", tostring(why))
  -- the old content's rows / ghosts leave the click registry (they leave the tree below)
  for _, w in pairs(St.ui.rows or {}) do
    local k = U.key(w)
    if k ~= 0 then St.ui.buttons[k] = nil end
  end
  for _, k in ipairs(V2.ghostKeys) do St.ui.buttons[k] = nil end
  pcall(function() U.mod("setup").forget() end)
  if package.loaded.theme then pcall(function() package.loaded.theme.forget() end) end
  root:ClearChildren()
  local style = buildContent(page, root, pc)
  U.try(TAG, function() U.mod("setup").build(root, pc, page) end)
  if style == "v2" then U.try(TAG, desiredFocusV2) end
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)
  return true
end

-- false when a theme.forget dropped this page's elements while the page lives on: every builder of a dead generation
-- is a silent no-op (the tiles would freeze), so the page content is rebuilt at its next show (setup's v2.alive twin).
local function v2Alive()
  local p = V2.posters and V2.posters.quick
  if not (p and p.e) then return true end
  local ok, r = pcall(function() return theme().set(p.e, {}) end)
  return (not ok) or r ~= nil
end

styleCheck = function()
  if V2.style == nil then return end
  if setupActive() or St.launch.pending then return end
  if wantStyle() ~= V2.style then
    rebuildContent(string.format("UiStyle %s -> %s", tostring(V2.style), wantStyle()))
  elseif V2.active and not v2Alive() then
    U.warn(TAG, "the v2 page's theme elements were dropped (theme.forget while the page lived): content rebuilt")
    rebuildContent("theme elements dropped")
  end
end

-- Idempotent per menu instance (St.resetMenu() clears St.menu.lobby when a new menu is installed).
function lobby.build(menu)
  registerListeners()
  if U.ok(St.menu.lobby) then return St.menu.lobby end
  if not U.ok(menu) then return nil end
  local ui = U.mod("ui")
  local pc = menu:GetOwningPlayer()                   -- UWidget::GetOwningPlayer() -> Object
  local page = ui.make("SettingList", pc)
  if not page then
    status("FREE MODE PAGE COULD NOT BE CREATED")
    return nil
  end
  local root, why = pageRoot(page)
  if not root then
    U.err(TAG, "lobby root unusable: %s (LobbyRootMode=%s)", tostring(why), tostring(cfg.LobbyRootMode))
    St.emit("status", "LOBBY LAYOUT FAILED (SEE LOG)")
    return nil
  end

  local style = buildContent(page, root, pc)
  local sw = menu.WS_ScreenContent
  if U.ok(sw) then
    sw:AddChild(page)                                 -- not activated; menu_tab.showPage selects it
  else
    U.err(TAG, "menu.WS_ScreenContent invalid: page not added")
  end
  St.menu.lobby = page

  -- RACE SETUP panel (setup.lua) in the same page, collapsed until CHOOSE RACE
  U.try(TAG, function() U.mod("setup").build(root, pc, page) end)

  -- GALAXY RUN page (runpage.lua) in the same page, collapsed until the poster's A (0.14 v3)
  U.try(TAG, function() U.mod("runpage").build(root, pc, page) end)
  -- 0.15 F01: the COUCH CAMPAIGN players page (couchpage.lua), opened by the Campaign tab's COUCH CAMPAIGN tile
  U.try(TAG, function() U.mod("couchpage").build(root, pc, page) end)
  -- 0.16: the GALACTIC GRAND PRIX page (gppage.lua), opened by the poster that was GALAXY RUN
  U.try(TAG, function() U.mod("gppage").build(root, pc, page) end)

  if not restoredOnce then
    restoredOnce = true
    if St.race.choice == nil then
      U.try(TAG, function() U.mod("builder").restoreFromSettings() end)
    end
  end
  if style == "v2" then U.try(TAG, desiredFocusV2) end
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)                           -- correct texts before the page is ever shown
  if style == "v2" then
    U.log(TAG, "lobby page built (UI v2: 5 posters over the ghosts quick / custom / galaxy / pads / options, START "
      .. "card, players strip, status pill; OPTIONS is built at its first open) (V-FIN-04)")
  else
    U.log(TAG, "lobby page built (%d rows)", #ROW_ORDER)
  end
  return page
end

local lastRefreshMs = -1e9
local PERIODIC_REFRESH_MS = 2000   -- texts that age without an event (failure age, connection progress, pads)

-- MAIN loop, front end.
function lobby.tick()
  if not St.menu.visible or St.launchHold() then return end   -- 0.12.0: launch hold (main.lua gates it as well)
  local now = St.nowMs()
  if now - lastRefreshMs >= PERIODIC_REFRESH_MS then St.ui.dirty = true end
  if St.ui.dirty then
    St.ui.dirty = false
    lastRefreshMs = now
    lobby.refresh()
  end
end

-- Recompute every label (§4.2 lobby refresh rules); only changed texts/states are written to the widgets.
function lobby.refresh()
  if not U.ok(St.menu.lobby) then return end
  if setupActive() then return end                    -- rows are collapsed under the RACE SETUP panel
  if V2.active then                                   -- 0.12.0: tiles, strip, network line, OPTIONS rows
    v2Refresh()
    return
  end

  U.try(TAG, function()
    local views = U.mod("join").slotViews() or {}
    for i = 1, 4 do setRowText("slot" .. i, views[i] or "") end
  end)

  U.try(TAG, function()
    -- by the NetMode SETTING (like netact), not the engine net mode: net.statusText() has its texts exactly for the
    -- standalone states (CONNECTING, RECONNECTING (TRY n/m), NOT HOSTING, STARTING HOST, the failure line).
    local text = (netMode() ~= "offline") and U.mod("net").statusText() or ""
    local shown = text ~= ""
    setRowShown("remote", shown)
    if shown then setRowText("remote", text) end
  end)

  for _, id in ipairs({"pads", "race", "adv", "layout", "gfx", "takedown", "tags", "kbp1", "net"}) do
    U.try(TAG, function() setRowText(id, classicText(id)) end)
  end

  U.try(TAG, function()
    local offline = netMode() == "offline"
    -- VERIFY(V-LOB-04): Collapsed rows are skipped by navigation and take no space.
    setRowShown("netact", not offline)
    if not offline then setRowText("netact", U.mod("net").netactLabel()) end
  end)

  U.try(TAG, function()
    local text, enabled = startState()
    setRowText("start", text)
    setRowEnabled("start", enabled)
  end)

  U.try(TAG, function() setRowText("status", St.ui.statusText or "") end)
end

-- "status" listener. Classic: the status row. 0.12.0 v2: theme's status pill (§4.5: StatusPillMs, the warn variant for
-- refusals and errors; an empty text drops the transient message).
function lobby.setStatus(text)
  St.ui.statusText = tostring(text or "")
  St.ui.dirty = true
  local lv = pendingLevel
  pendingLevel = nil
  setRowText("status", St.ui.statusText)
  if V2.active and V2.pill then
    local warn
    local ms
    if lv and lv.text == St.ui.statusText then warn, ms = lv.warn, lv.ms else warn = isWarnText(St.ui.statusText) end
    if St.ui.statusText == "" then
      V2.pill.post("", {})
    else
      V2.pill.post(St.ui.statusText, {warn = warn, ms = ms})
    end
  end
  if setupActive() then pcall(function() U.mod("setup").setStatus(St.ui.statusText) end) end
end

-- "tab"(true): our tab was selected.
function lobby.onShown()
  local join = U.mod("join")
  if join.isFrozen() then
    status("DISCONNECT TO CHANGE PLAYERS")
  else
    join.open()
  end
  St.ui.dirty = true
  U.try(TAG, lobby.onNavShown)
end

-- "tab"(false): another tab was selected; guests never leak into the game's own modes (§1.1). A connected client's
-- guest set is frozen: it only changes through DISCONNECT (§2.3), so it is not closed here.
function lobby.onHidden()
  if V2.active and V2.mode == "options" then U.try(TAG, lobby.closeOptions, "tab left") end   -- v2 §5.3
  if setupActive() then U.try(TAG, function() U.mod("setup").close("tab left") end) end
  local join = U.mod("join")
  if not St.launch.pending and not join.isFrozen() then
    join.close()
  end
  St.ui.dirty = true
end

-- Row actions (§1.2). Each runs on the game thread from ui's click dispatch.

-- ADD PLAYERS: guest LocalPlayers can never be removed (RemovePlayer crash) and follow every flow of this game
-- session, online Multiplayer included, so the opt-in is confirmed: the first press only explains, a second press
-- within the window (PADS_CONFIRM_MS) enables the pads (join.enablePads). Once on, the row only repeats how to turn them off.
-- 0.12.0 v2: the PLAYERS tile (its RUST "Press again to confirm" badge shows during the window, v2Tick).
-- #75 (tester #5 2026-10-18 04:27:42 / :52 / 04:28:08): every A reached onPads, but 9.9 s and 16.4 s apart: each
-- press found the 5 s window over and only showed the prompt again (the long warning takes longer than 5 s to read).
-- The window is PADS_CONFIRM_MS now, and the prompt pill + badge stay up exactly as long.
local PADS_CONFIRM_MS = 15000
function lobby.onPads()
  local join = U.mod("join")
  if join.padsEnabled() then
    say("PADS STAY ON UNTIL THE GAME RESTARTS (RESTART BEFORE ONLINE PLAY)", false)
  elseif join.isFrozen() or isClient() or St.net.connecting then
    say("DISCONNECT TO CHANGE PLAYERS", true)
  else
    local now = St.nowMs()
    if now > padsConfirmUntilMs then
      padsConfirmUntilMs = now + PADS_CONFIRM_MS
      if V2.active then
        say("PADS STAY ON UNTIL THE GAME RESTARTS. NOT FOR ONLINE PLAY: PRESS (A) AGAIN", false, PADS_CONFIRM_MS)   -- §4.2
      else
        status("PADS STAY ON UNTIL GAME RESTART, NOT FOR ONLINE PLAY: PRESS AGAIN TO ADD PLAYERS")
      end
    else
      padsConfirmUntilMs = 0
      join.enablePads("lobby ADD PLAYERS")
    end
  end
  St.ui.dirty = true
end

-- CHOOSE RACE: the RACE SETUP flow (setup.lua); the dev panel when cfg.SetupMode = "builder" or the setup page could
-- not be built.
-- 0.13.0 GALAXY RUN: between run races START (and RACE) open the run's next race on the racer cards. -> "opened" |
-- "failed" (between run races, but the next race could not be opened: nothing else is launched) | nil (no run race)
local function runNext()
  -- 0.16: between GRAND PRIX races START opens its next race on the racer cards
  if gpIs("between") then
    local okG, opened = pcall(function() return U.mod("gp").openNext() end)
    if okG and opened == true then return "opened" end
    say("GRAND PRIX: THE NEXT RACE DID NOT OPEN. END IT ON THE GRAND PRIX PAGE", true)
    return "failed"
  end
  local okB, between = pcall(function() return U.mod("run").betweenRaces() end)
  if not (okB and between) then return nil end
  local ok, handled = pcall(function() return U.mod("run").openNext() end)
  if ok and handled == true then return "opened" end
  say("GALAXY RUN: THE NEXT RACE DID NOT OPEN. OPTIONS > GALAXY RUN: A TWICE ENDS THE RUN", true)
  return "failed"
end

local function openSetup()
  local useSetup = U.mod("ui").opt("SetupMode", "setup") ~= "builder"
  local opened = false
  if useSetup then
    local ok, r = U.try(TAG, function() return U.mod("setup").open() end)
    opened = ok and r == true
  end
  if not opened then
    if useSetup then U.warn(TAG, "race setup unavailable: opening the dev race builder") end
    U.mod("builder").open()
  end
  St.ui.dirty = true
end

-- The classic page's RACE row (0.13.0: between run races it switches the route; the v2 page has GALAXY RUN for that).
function lobby.onRace()
  local okR, sw = pcall(function()
    local run = U.mod("run")
    if run.betweenRaces() then
      local sw = run.switchRoute()
      if not sw then say("GALAXY RUN: ONE ROUTE LEFT, PRESS START") end
      return true
    end
    return nil
  end)
  if okR and sw then St.ui.dirty = true; return end
  if runNext() then St.ui.dirty = true; return end
  openSetup()
end

-- 0.13.0 FREE MODE posters QUICK RACE / CUSTOM RACE: the play mode (settings PlayMode), then RACE SETUP. An armed run
-- (RunLength) is disarmed (RunPick keeps its length for GALAXY RUN); while a run is on, its builds own every launch
-- (run.prelaunch), so these posters refuse.
local function playMode(mode)
  if St.launch.pending then return end
  if runIs("on") then
    say("A GALAXY RUN IS ON: PLAY IT ON GALAXY RUN, OR END IT IN OPTIONS", true)
    St.ui.dirty = true
    return
  end
  if gpIs("on") then
    say("A GRAND PRIX IS ON: PLAY IT ON GALACTIC GRAND PRIX, OR END IT THERE", true)
    St.ui.dirty = true
    return
  end
  settings.set("PlayMode", mode)
  if tostring(settings.get("RunLength") or "off") ~= "off" then settings.set("RunLength", "off") end
  U.log(TAG, "FREE MODE: %s (RACE SETUP)", MODE_WORD[mode] or mode)
  openSetup()
end

function lobby.onQuick() playMode("quick") end
function lobby.onCustom() playMode("custom") end

-- The League preset GALAXY RUN starts (settings RunPick; a preset set in OPTIONS > Galaxy run updates it).
local function runPick()
  local v = tostring(settings.get("RunPick") or "qualifier")
  for _, p in ipairs(RUN_PICKS) do if p == v then return v end end
  return RUN_PICKS[1]
end

-- 0.13.0 GALAXY RUN poster (A): between run races the run's next race on the racer cards (runNext); with no run on, the
-- run is armed with RunPick races (run.prelaunch starts it at the launch) and RACE SETUP opens for race 1.
function lobby.onGalaxy()
  if St.launch.pending then return end
  -- 0.16: A opens the GALACTIC GRAND PRIX page (gppage.lua); cfg.GrandPrix = false keeps the GALAXY RUN page
  if cfg.GrandPrix ~= false then
    local okG, gpOpen = pcall(function() return U.mod("gppage").open() end)
    if okG and gpOpen == true then St.ui.dirty = true; return end
  end
  -- 0.14 v3: A opens the GALAXY RUN page (new run / continue / node / standings; runpage.lua)
  local okO, pageOpen = pcall(function() return U.mod("runpage").open() end)
  if okO and pageOpen == true then St.ui.dirty = true; return end
  -- fallback (the page could not be built): the pre-page behaviour
  if runNext() then St.ui.dirty = true; return end
  if runIs("on") then                                 -- on, but no race to open (a race still in flight)
    local okT, t = pcall(function() return U.mod("run").statusText() end)
    say(okT and t or "GALAXY RUN", false)
    St.ui.dirty = true
    return
  end
  local len = runPick()
  settings.set("RunLength", len)
  say("GALAXY RUN: THE NEXT RACE STARTS " .. runLabel(len))
  openSetup()
end

-- Jules 2026-10-14 (playtest note): GALAXY RUN is a plain button like QUICK / CUSTOM RACE. RIGHT on it does nothing
-- (its focus trap only keeps the focus on the tile); the node and the League are picked on the run page (runpage.lua
-- NEXT NODE / LEAGUE rows).

function lobby.onAdvanced()
  U.mod("builder").open()
  St.ui.dirty = true
end

function lobby.onLayout()
  settings.cycle("Layout2P", {"top-bottom", "side-by-side"})
  U.mod("split").applyLayoutSettings()
  St.ui.dirty = true
end

-- dir: nil/1 = next value (A, click, d-pad right), -1 = previous value (d-pad left).
local function cycle(key, list, dir)
  if dir == -1 then
    local rev = {}
    for i = #list, 1, -1 do rev[#rev + 1] = list[i] end
    list = rev
  end
  settings.cycle(key, list)
end

function lobby.onGfx(dir)
  cycle("SplitGraphics", {"auto", "performance", "quality", "off"}, dir)
  St.ui.dirty = true
end

function lobby.onTakedown()
  settings.toggle("TakedownCams")
  St.ui.dirty = true
end

function lobby.onTags()
  settings.toggle("NameTags")
  St.ui.dirty = true
end

-- couch-fix39 (audit Q10): COUCH CAMPAIGN > Guests' team mystery choices GREYED <-> ALLOWED (settings.txt
-- CouchMysteryTeam; couchrun reads it at every mystery screen)
function lobby.onMystTeam()
  settings.cycle("CouchMysteryTeam", {"greyed", "allowed"})
  St.ui.dirty = true
end

-- couch-fix35 (Jules's Q1): COUCH CAMPAIGN > P1's rewards OWN PLACE <-> BEST CARRIES EVERYONE (settings.txt
-- CouchEconomy; couchrules.ownEconomy reads it at every race end)
function lobby.onCouchEcon()
  local v = settings.cycle("CouchEconomy", {"own", "best"})
  U.log(TAG, "COUCH CAMPAIGN: P1's rewards %s", (v == "best") and "BEST CARRIES EVERYONE" or "OWN PLACE")
  St.ui.dirty = true
end

function lobby.onKbP1()
  local join = U.mod("join")
  if join.isFrozen() or isClient() or St.net.connecting then
    -- a connected (or connecting) client's guest set changes only through DISCONNECT (§2.3): a guest whose PC has
    -- not replicated yet is missing from joinedList, and rebuild() would wipe the frozen bookkeeping
    say("DISCONNECT TO CHANGE PLAYERS", true)
  elseif #join.joinedList() > 0 then
    say("REMOVE GUESTS FIRST", true)
  else
    settings.toggle("KeyboardIsP1")
    U.mod("split").applyGamepadOffset()
    join.rebuild()
  end
  St.ui.dirty = true
end

function lobby.onNet(dir)
  if St.net.hosting then
    say("STOP HOSTING FIRST", true)
  elseif isClient() or St.net.connecting then
    say("DISCONNECT FIRST", true)
  else
    cycle("NetMode", {"offline", "host", "join"}, dir)
  end
  St.ui.dirty = true
end

function lobby.onNetAction()
  local mode = netMode()
  local net = U.mod("net")
  if mode == "host" then
    net.toggleHosting()
  elseif mode == "join" then
    net.toggleConnect()
  end
  St.ui.dirty = true
end

function lobby.onStart()
  if runNext() then St.ui.dirty = true; return end
  U.mod("launch").start()
  St.ui.dirty = true
end

local runAbandonUntil = 0
function lobby.onRun(dir)
  local run = U.mod("run")
  if run.active() then
    local now = St.nowMs()
    if now <= runAbandonUntil then
      runAbandonUntil = 0
      run.abandon("OPTIONS")
      settings.set("RunLength", "off")
      say("GALAXY RUN ABANDONED")
    else
      runAbandonUntil = now + U.confirmMs()              -- couch-fix59 AUTO-145e
      say("PRESS A AGAIN TO ABANDON THE GALAXY RUN", true)
    end
  else
    cycle("RunLength", {"off", "qualifier", "league", "kestar", "sprint"}, dir)
    local v = tostring(settings.get("RunLength") or "off")
    if v ~= "off" then
      settings.set("RunPick", v)                        -- the GALAXY RUN poster shows / starts this preset
      say("GALAXY RUN: THE NEXT RACE STARTS " .. runLabel(v))
    else
      say("GALAXY RUN OFF")
    end
  end
  St.ui.dirty = true
end

-- #98 OPTIONS > Delete all couch progress. First A: refused with the reason (the COUCH save profile is not live), else
-- armed for lobby.CD.CONFIRM_MS (the warning in the pill and the detail column). A second A in that window (not within
-- lobby.CD.GUARD_MS of the first: the same press) runs couchacts.deleteAll, which checks every refusal again, keeps
-- couch-run.txt in a dated copy (couchrun.wipe) and runs the game's campaign reset. OPTIONS and the join window close
-- right before that reset (the act page did the same).
function lobby.onCouchDelete()
  St.ui.dirty = true
  if not lobby.CD.on() then say("TURNED OFF (CouchDeleteProgress)", true); return end
  local A = lobby.CD.acts()
  if not A then say("THE COUCH CAMPAIGN MODULE IS NOT LOADED: NOTHING WAS CHANGED", true); return end
  local now = St.nowMs()
  if lobby.CD.armed() then
    if now - lobby.CD.armedMs < lobby.CD.GUARD_MS then
      U.log(TAG, "DELETE ALL COUCH PROGRESS: an A %d ms after the first one ignored (the same press)",
        math.floor(now - lobby.CD.armedMs))
      return
    end
    lobby.CD.disarm("confirmed")
    U.log(TAG, "DELETE ALL COUCH PROGRESS: confirmed by P1's second A in OPTIONS")
    local okD, ok, msg = pcall(A.deleteAll, function()
      lobby.closeOptions("DELETE ALL COUCH PROGRESS")
      pcall(function() U.mod("join").close("couch progress deleted") end)
    end)
    if not okD then ok, msg = false, "The delete failed (see the log): " .. tostring(ok) end
    lobby.CD.profile(true)
    if ok then say(string.upper(tostring(msg or "Couch progress deleted.")))
    else say(string.upper(tostring(msg or "Nothing was changed.")), true) end
    return
  end
  local p = lobby.CD.profile(true)
  if not p.live then
    U.log(TAG, "DELETE ALL COUCH PROGRESS refused in OPTIONS: %s", p.why)
    say("NOT AVAILABLE: " .. string.upper(p.why), true)
    return
  end
  lobby.CD.armedMs, lobby.CD.untilMs, lobby.CD.focusId = now, now + lobby.CD.CONFIRM_MS, nil   -- focusId: next tick
  U.log(TAG, "DELETE ALL COUCH PROGRESS: armed in OPTIONS (a second A within %d s deletes)",
    math.floor(lobby.CD.CONFIRM_MS / 1000))
  say("DELETES THE COUCH CAMPAIGN SAVE AND EVERY GUEST'S PROGRESS: PRESS (A) AGAIN TO DELETE", true, lobby.CD.CONFIRM_MS)
end

---------------------------------------------------------------------------------------------------
-- Pad / keyboard navigation
---------------------------------------------------------------------------------------------------
-- First live run: CommonUI focus never reached our rows (no d-pad highlight, pad A did nothing), mouse hover did.
-- So P1's input is read directly: IsInputKeyDown on P1's PlayerController (ControllerId 0), edge-detected in Lua like
-- the guests' join. Guests are other PlayerControllers (ControllerId 1..3 = pads 2-4) and join.poll never reads P1,
-- so P1's navigation cannot be taken for a guest's join press. With KeyboardIsP1, pad 1 drives ControllerId 1
-- (bOffsetPlayerGamepadIds): P1's PC sees the keyboard only and its pad keys are not polled here.
-- CommonUI focus is still attempted (ui.focus on the highlighted row). When it works, one press may arrive twice
-- (CommonUI's own navigation/click + this poll): a step is skipped when the focus already moved in the same tick
-- (navigation then follows the focus), and ui.claimAction drops the second action of one press.
-- VERIFY(V-LOB-08): the log shows "P1 nav: first press of <key>"; if never, P1's PC gets no key in the menu (CommonUI
-- Menu input mode blocks game input) and only the CommonUI focus route / mouse remain.
-- 2026-10-07 review: that block is the expected case (CommonGameViewportClient routes every key through P1's
-- CommonUI action router first; in the Menu input config it returns BlockGameInput, so P1's PlayerInput never sees
-- it - pad 2 reached ctrlId 1 only because a guest's router has no active Menu config). So:
--   * the PAD path is CommonUI focus: the focus keeper (lobby.keepFocus) gives P1's focus to the highlighted row
--     after every page show / menu re-activation; with focus on a row, d-pad moves natively and A clicks (ClickMode
--     poll sees GetSelected). pollNav stays as an optional extra;
--   * the KEYBOARD path is UE4SS RegisterKeyBind (GetAsyncKeyState, not routed through CommonUI): arrows, Enter,
--     Space (lobby.init). It acts only when no row holds CommonUI focus (otherwise CommonUI navigates/clicks itself);
--   * nothing acts while another screen covers the lobby (lobbyCovered: main menu / page deactivated, a UIManager
--     Dialog/MenuOverlay layer count above its value at the lobby show), and the first accept after a Back is
--     swallowed (it may be the one that confirms the game's "Exit game?" prompt).
-- 0.12.0 v2: the rows are the ghosts. Tiles mode navigates the §4.6 graph (explicit rules on the ghosts; GRAPH below
-- for our own poll / keybinds), left / right never change a value there; OPTIONS navigates its list (explicit up /
-- down chain) and left / right step the value: keybinds through onKey, the pad through the focus traps (v2Tick).

local NAV_IDS = {"pads", "race", "adv", "layout", "gfx", "takedown", "tags", "kbp1", "net", "netact", "start"}

-- d-pad left/right on a row with a value (dir -1 / 1). Two-value and ON/OFF rows flip either way.
local LR_ACTIONS = {
  layout = function() lobby.onLayout() end,
  gfx = function(dir) lobby.onGfx(dir) end,
  takedown = function() lobby.onTakedown() end,
  tags = function() lobby.onTags() end,
  kbp1 = function() lobby.onKbP1() end,
  net = function(dir) lobby.onNet(dir) end,
  mystteam = function() lobby.onMystTeam() end,       -- couch-fix39: two values, either way flips
  couchecon = function() lobby.onCouchEcon() end,     -- couch-fix35: two values, either way flips
}
for id, n in pairs(NAME_SLOT) do
  LR_ACTIONS[id] = function(dir) lobby.nameEditKey((dir or 1) < 0 and "left" or "right", n) end
end

local PAD_KEYS = {
  up = {"Gamepad_DPad_Up", "Gamepad_LeftStick_Up"},
  down = {"Gamepad_DPad_Down", "Gamepad_LeftStick_Down"},
  left = {"Gamepad_DPad_Left", "Gamepad_LeftStick_Left"},
  right = {"Gamepad_DPad_Right", "Gamepad_LeftStick_Right"},
  accept = {C.KEY.A},
  back = {C.KEY.B},
}
local KB_KEYS = { up = {"Up"}, down = {"Down"}, left = {"Left"}, right = {"Right"}, accept = {"Enter", "SpaceBar"},
                  back = {} }   -- Escape stays the game's (Exit Game prompt)

local function logSeen(key)
  if nav.seen[key] then return end
  nav.seen[key] = true
  U.log(TAG, "P1 nav: first press of %s seen on P1's PlayerController", key)
end

local function useKeyboard()
  local m = opt("LobbyNavKeyboard", "always")
  if m == "never" then return false end
  if m == "kbp1" then return settings.get("KeyboardIsP1") == true end
  return true
end

local function readInputs(p1)
  local ui = U.mod("ui")
  local pad = settings.get("KeyboardIsP1") ~= true
  local kb = useKeyboard()
  local st = {}
  for name, list in pairs(PAD_KEYS) do
    local down = false
    if pad then
      for i = 1, #list do
        if ui.keyDown(p1, list[i]) then down = true; logSeen(list[i]); break end
      end
    end
    if not down and kb and not nav.kbBound then        -- keybinds registered: the keyboard goes through lobby.onKey
      local kl = KB_KEYS[name]
      for i = 1, #kl do
        if ui.keyDown(p1, kl[i]) then down = true; logSeen(kl[i]); break end
      end
    end
    st[name] = down
  end
  return st
end

local function axis(neg, pos)
  if neg and not pos then return -1 end
  if pos and not neg then return 1 end
  return 0
end

-- The navigable ids of the page: the classic rows, or (v2) the tile ghosts / the OPTIONS row ghosts.
local function navIds()
  if V2.active then
    if V2.mode ~= "options" then return TILE_IDS end
    return lobby.SUBS.idsOf(V2.opt)
  end
  return NAV_IDS
end

-- Navigable rows in page order: our buttons that are not collapsed.
local function navList()
  local out = {}
  for _, id in ipairs(navIds()) do
    if U.ok(St.ui.rows[id]) and (St.ui.shown or {})[id] ~= false then out[#out + 1] = id end
  end
  return out
end

local function indexOf(list, id)
  for i = 1, #list do if list[i] == id then return i end end
  return nil
end

-- A highlighted row that disappeared (netact collapsed): the nearest navigable row above it, else the first.
local function nearest(list, id)
  local ids = navIds()
  local p = indexOf(ids, id)
  if p then
    for i = p, 1, -1 do if indexOf(list, ids[i]) then return ids[i] end end
  end
  return list[1]
end

-- First row to focus when nothing is chosen yet: v2 tiles the poster of the mode START plays (§4.6; 0.13.0); else the
-- first.
local function defaultIdx(list)
  if V2.active and V2.mode == "tiles" then
    local d = modeTile()
    if indexOf(list, d) then return d end
  end
  return list[1]
end

local function focusedId(list, p1)
  local ui = U.mod("ui")
  for i = 1, #list do
    if ui.hasFocus(St.ui.rows[list[i]], p1) then return list[i] end
  end
  return nil
end

-- 0.12.0 v2 OPTIONS: P1's focus on BACK (command row) or on a focus trap belongs to the page too -> "back" | "trap" |
-- nil (always nil in classic). 0.13.0 tiles mode: GALAXY RUN's right focus trap -> "trap".
local function heldExtra(p1)
  if V2.active and V2.mode == "tiles" then
    if U.ok(V2.trapR) and U.mod("ui").hasFocus(V2.trapR, p1) then return "trap" end
    return nil
  end
  if not (V2.active and V2.mode == "options" and V2.opt) then return nil end
  local O, ui = V2.opt, U.mod("ui")
  local back = O.cmd and O.cmd.widget("back")
  if U.ok(back) and ui.hasFocus(back, p1) then return "back" end
  if ui.hasFocus(O.trapL, p1) or ui.hasFocus(O.trapR, p1) then return "trap" end
  if (U.ok(O.trapU) and ui.hasFocus(O.trapU, p1)) or (U.ok(O.trapD) and ui.hasFocus(O.trapD, p1)) then return "trap" end
  return nil
end

local function setHighlight(id)
  if nav.hl == id then return end
  if V2.active then                                   -- v2: no row style; the painted look follows (v2Tick)
    nav.hl = id
    return
  end
  local ui = U.mod("ui")
  local old = nav.hl
  nav.hl = id
  if old ~= nil then
    ui.highlight(St.ui.rows[old], false)
    setRowText(old, baseTexts()[old] or "")           -- drops the marker
  end
  if id ~= nil then
    if not ui.highlight(St.ui.rows[id], true) and not nav.autoMarker then
      nav.autoMarker = true
      U.log(TAG, "row highlight style unavailable: the highlighted row is marked with '> ' instead")
    end
    setRowText(id, baseTexts()[id] or "")
  end
end

-- CommonUI focus on the row (cfg.LobbyNavHighlight "style": never touch focus). Returns true when it took.
local function focusRow(id)
  local w = St.ui.rows[id]
  if not U.ok(w) or opt("LobbyNavHighlight", "both") == "style" then return false end
  pcall(function() St.menu.lobby:SetDesiredFocusWidget(w) end)   -- CommonUI's restore target follows our row
  return U.mod("ui").focus(w) == true
end

-- Idle ink on every row but the highlighted/focused one (insurance against a PreConstruct that ran before IsInvert).
local function restyle()
  if V2.active then return end                        -- v2: ghosts, nothing to ink
  local ui = U.mod("ui")
  for _, id in ipairs(ROW_ORDER) do
    local w = St.ui.rows[id]
    if id ~= "hdr" and id ~= nav.hl and U.ok(w) and not ui.hasFocus(w) then ui.inkRow(w) end
  end
end

local function activate(id, dir)
  if dir == 0 then
    if not V2.active and id == "start" and (St.ui.enabled or {}).start == false then
      U.dbg(TAG, "nav: START is disabled (%s)", tostring(baseTexts().start))
      return
    end
    local fn = actionOf(id)
    if fn == nil or not U.mod("ui").claimAction("nav:" .. id) then return end
    U.dbg(TAG, "nav: A on '%s'", id)
    pcall(function()                                   -- the BP's click feedback (Common_Btn ubergraph @807)
      local w = St.ui.rows[id]
      local anim = w.Anim_Select
      if U.ok(anim) then w:PlayAnimation(anim, 0.0, 1, 0, 1.0, false) end
    end)
    U.try(TAG, fn)
  else
    local fn = LR_ACTIONS[id]
    if fn == nil then return end
    U.dbg(TAG, "nav: %s on '%s'", dir < 0 and "left" or "right", id)
    U.try(TAG, fn, dir)
  end
  St.ui.dirty = true
  if St.menu.visible == "lobby" then U.try(TAG, lobby.refresh) end   -- new value visible at once, not next MAIN tick
end

-- ui.forgetAll / lobby.build: the rows are new widgets.
function lobby.resetNav()
  pcall(function() U.mod("setup").forget() end)      -- the setup panel belonged to the same page
  pcall(function() U.mod("runpage").forget() end)    -- the GALAXY RUN page too (0.14 v3)
  pcall(function() U.mod("couchpage").forget() end)  -- the COUCH CAMPAIGN page (0.15 F01)
  pcall(function() U.mod("gppage").forget() end)     -- the GALACTIC GRAND PRIX page (0.16)
  nav.idx, nav.hl, nav.primed, nav.lastFocus = nil, nil, false, nil
  nav.covered, nav.coverWhy, nav.layerBase, nav.backGuard, nav.consumed, nav.seenAct = false, nil, nil, false, nil, {}
  nav.keep.untilMs = 0
  St.ui.baseTexts = {}
  V2 = newV2()                                        -- 0.12.0: the v2 page state belongs to the page
  nameEdit = nil                                      -- the name editor belonged to the page too
  St.ui.canvas = nil
end

-- A click seen by ui.pollClicks (mouse / CommonUI A): the highlight moves to that row.
function lobby.noteClicked(id)
  if indexOf(navIds(), id) == nil or St.menu.visible ~= "lobby" then return end
  nav.idx = id
  setHighlight(id)
end

-- Is the lobby NOT the input target right now? -> covered (bool), why. FAST loop and keybind dispatch, lobby shown.
-- Signals (any one): the main menu deactivated (IsActivated false: Settings, the dev screen, a stack modal), our page
-- deactivated, menu_tab's activation poll says covered, or a UIManager Dialog / MenuOverlay layer holds more widgets
-- than when the lobby was shown. The layers hold persistent containers from start-up (WBP_Dialog_Container,
-- WBP_MenuOverlay_Container, ui-toolkit.md), so only a count ABOVE the show-time baseline counts; a dialog pushed
-- inside a container does not change the count, and is then only seen through the activation checks (plus the
-- Back guard of pollNav / onKey).
local LAYERS = { C.E.UILayer.Dialog, C.E.UILayer.MenuOverlay }

local function layerCounts()
  local mgr = U.giSubsystem("UIManager")
  if not U.ok(mgr) then return nil end
  local out = {}
  for i, layer in ipairs(LAYERS) do
    local ok, n = pcall(U.callMethod, mgr, "GetWidgetCountInLayer", layer)   -- (Enum layer) -> Int
    if not ok or type(n) ~= "number" then return nil end
    out[i] = n
  end
  return out
end

-- An activation flag counts only after it was seen true since the page was shown (nav.seenAct): a widget whose
-- IsActivated() never reads true (not on a CommonUI stack) must not disable the lobby input for good.
local function deactivated(w, key)
  if not U.ok(w) then return false end
  local ok, a = pcall(U.callMethod, w, "IsActivated")       -- UCommonActivatableWidget::IsActivated() -> Bool
  if not ok or type(a) ~= "boolean" then return false end
  nav.seenAct = nav.seenAct or {}
  if a then nav.seenAct[key] = true; return false end
  return nav.seenAct[key] == true
end

local function lobbyCovered()
  if deactivated(St.menu.widget, "menu") then return true, "main menu deactivated" end
  local page = (St.menu.visible == "builder") and St.menu.builder or St.menu.lobby
  if deactivated(page, St.menu.visible or "page") then return true, "page deactivated" end
  local okC, cov = pcall(function() return U.mod("menu_tab").isCovered() end)
  if okC and cov == true then return true, "menu covered (tab poll)" end
  local counts = layerCounts()
  if counts then
    if nav.layerBase == nil then nav.layerBase = counts end
    for i = 1, #counts do
      if counts[i] > (nav.layerBase[i] or 0) then return true, "UI layer " .. tostring(LAYERS[i]) .. " grew" end
      if counts[i] < (nav.layerBase[i] or 0) then nav.layerBase[i] = counts[i] end
    end
  end
  return false, nil
end

-- Updates nav.covered (edges logged); on uncover the next poll re-primes (a held A does not fire) and the Back
-- guard is cleared (the screen it may have opened was seen and closed).
local function checkCovered()
  local cov, why = lobbyCovered()
  if cov ~= nav.covered then
    nav.covered = cov
    U.dbg(TAG, "lobby input %s%s", cov and "suspended: " or "resumed", cov and tostring(why) or "")
    nav.primed = false
    if not cov then nav.backGuard = false end
  end
  return cov
end

-- A press that ran a row through our own navigation: CommonUI's click of that row (on release) is the same press.
-- kind "pad": consumed while P1's accept is held and 150 ms after its release; "kb": for 1 s (a keybind sees no
-- release). Read by ui.pollClicks.
-- A "pad" record belongs to ONE press: upMs is the FIRST release after it (pollNav, lobby.notePadAccept); the record
-- expires 150 ms after that release, and a new press edge drops a stale one. Without that, a record CommonUI never
-- consumed (no click came) would swallow a later, legitimate click on the same row (its release is "< 150 ms ago").
local PAD_CONSUME_MAX_MS = 10000                       -- held longer / no release seen (page hidden): expired
local function consume(id, kind)
  local now = St.nowMs()
  nav.consumed = { id = id, kind = kind, atMs = now, upMs = nil, untilMs = now + 1000 }
end

local function consumedLive(c, now)
  if c == nil then return false end
  if c.kind == "pad" then
    if c.upMs ~= nil then return now - c.upMs < 150 end
    return now - (c.atMs or 0) < PAD_CONSUME_MAX_MS and nav.prev ~= nil and nav.prev.accept == true
  end
  return now < c.untilMs
end

-- pollNav, every tick after the baseline: release / new-press bookkeeping of the pad record.
local function notePadAccept(down, wasDown, now)
  local c = nav.consumed
  if c == nil or c.kind ~= "pad" then return end
  if wasDown and not down and c.upMs == nil then c.upMs = now end
  if (down and not wasDown and c.upMs ~= nil) or not consumedLive(c, now) then nav.consumed = nil end
end

function lobby.consumedClick(id)
  local c = nav.consumed
  if c == nil or c.id ~= id then return false end
  local hit = consumedLive(c, St.nowMs())
  nav.consumed = nil
  return hit == true
end

-- Builder page: P1's focus on its desired focus target (BP_GetDesiredFocusTarget = Btn_SetVehicle [MT§5]).
local function builderTarget(bw)
  for _, name in ipairs({"Btn_SetVehicle", "Btn_Go"}) do
    local ok, w = pcall(U.getField, bw, name)
    if ok and U.ok(w) then return w end
  end
  return nil
end

local function builderFocused(bw, p1)
  if not U.ok(p1) then return false end
  local ok, v = pcall(U.callMethod, bw, "HasUserFocusedDescendants", p1)   -- UWidget (Object) -> Bool
  return ok and v == true
end

local function focusBuilder(bw)
  pcall(function() bw:RequestRefreshFocus() end)       -- UCommonActivatableWidget (0 params)
  local p1 = U.p1()
  if builderFocused(bw, p1) then return true end
  local t = builderTarget(bw)
  if not t then return false end
  return U.mod("ui").focus(t, p1) == true or builderFocused(bw, p1)
end

-- Focus keeper window (cfg.LobbyFocusKeepMs, default 3 s): menu_tab.showPage (both pages, every show) and the main
-- menu's re-activation edge arm it; lobby.keepFocus (FAST) re-gives the focus every 200 ms while nothing of the page
-- holds P1's focus and nothing covers it.
function lobby.armFocusKeeper(why)
  local now = St.nowMs()
  nav.keep.untilMs = now + (tonumber(opt("LobbyFocusKeepMs", 3000)) or 3000)
  nav.keep.nextMs = now
  nav.keep.why = tostring(why or "?")
  nav.keep.held = false
end

function lobby.keepFocus()
  if St.launchHold() then return end                  -- 0.12.0: the front end is being torn down (state.lua)
  -- 0.12.0 v2: the painted focus looks, the status pill's timer, the OPTIONS back route and focus traps (every FAST
  -- tick while the lobby page shows; ui.pollClicks calls keepFocus whatever cfg.LobbyPadNav says)
  if V2.active and St.menu.visible == "lobby" then U.tryEvery("lobby.v2Tick", nil, TAG, v2Tick) end
  if setupActive() then
    if St.menu.visible == "lobby" and not checkCovered() then U.mod("setup").keepFocus() end
    return
  end
  local now = St.nowMs()
  local k = nav.keep
  if now > k.untilMs or now < k.nextMs then return end
  k.nextMs = now + 200
  if checkCovered() then return end
  local p1 = U.p1()
  if St.menu.visible == "builder" then
    local bw = St.menu.builder
    if not U.ok(bw) then return end
    if builderFocused(bw, p1) then
      if not k.held then k.held = true; U.dbg(TAG, "focus keeper: builder holds P1's focus (%s)", k.why) end
      return
    end
    k.held = false
    local ok = focusBuilder(bw)
    U.dbg(TAG, "focus keeper (%s): builder focus %s", k.why, ok and "given" or "not taken yet")
    return
  end
  if St.menu.visible ~= "lobby" or not U.ok(St.menu.lobby) then return end
  local list = navList()
  if #list == 0 then return end
  local f = focusedId(list, p1) or heldExtra(p1)
  if f ~= nil then
    if not k.held then k.held = true; U.dbg(TAG, "focus keeper: row '%s' holds P1's focus (%s)", f, k.why) end
    return
  end
  k.held = false
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = defaultIdx(list) end
  pcall(function() St.menu.lobby:RequestRefreshFocus() end)   -- desired focus target = our row (focusRow sets it)
  local ok = focusedId(list, p1) ~= nil or focusRow(nav.idx)
  setHighlight(nav.idx)
  U.dbg(TAG, "focus keeper (%s): row '%s' %s", k.why, tostring(nav.idx), ok and "focused" or "not taken yet")
end

-- "tab"(true): our tab was selected (after showPage, which already armed the keeper).
function lobby.onNavShown()
  nav.primed = false                                   -- next pollNav takes a baseline: a held A does not click
  local list = navList()
  if #list == 0 then return end
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = defaultIdx(list) end
  restyle()
  lobby.armFocusKeeper("tab selected")
end

-- menu_tab.showPage(which), every show (also the lobby back from the builder, without a "tab" event): synchronous
-- focus try, fresh input baseline and Back guard, layer baseline, and the focus keeper window.
-- 0.12.0 v2: a live UiStyle switch rebuilds the page content first (styleCheck); the page geometry is measured on
-- every show and a moved origin shifts the canvas (alignCanvas, V-FIN-01).
function lobby.onPageShown(which)
  nav.primed, nav.backGuard, nav.layerBase, nav.covered, nav.seenAct = false, false, nil, false, {}
  if which == "lobby" then
    U.try(TAG, styleCheck)
    if V2.active then
      U.try(TAG, alignCanvas)
      V2.bPrev, V2.wasCovered = true, false            -- a B held through the show is no edge
      V2.sPrev, V2.sArmed = true, false                -- 0.13.0: nor is a Start (the START release)
    end
  end
  if which == "builder" then
    if U.ok(St.menu.builder) then focusBuilder(St.menu.builder) end
  elseif setupActive() then
    U.try(TAG, function() U.mod("setup").onPageShown() end)
  else
    lobby.focusFirst()
  end
  lobby.armFocusKeeper("page " .. tostring(which) .. " shown")
end

-- lobby.onPageShown("lobby") (menu_tab.showPage, every show, also back from the builder page without a "tab" event):
-- the highlighted row (first row on a fresh page) gets CommonUI focus and the highlight; the next pollNav takes a
-- fresh baseline. The retries are the focus keeper's (lobby.keepFocus).
function lobby.focusFirst()
  nav.primed = false
  local list = navList()
  if #list == 0 then return false end
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = defaultIdx(list) end
  local took = focusRow(nav.idx)
  setHighlight(nav.idx)
  return took
end

local function stepRow(list, pos, step)
  return list[((pos - 1 + step) % #list) + 1]
end

-- 0.12.0 v2 tiles mode (§4.6): the tile graph for our own poll / keybinds (the ghosts carry the same explicit rules).
-- 0.13.0: QUICK / CUSTOM / GALAXY on top, PLAYERS / OPTIONS below (the START card under GALAXY takes no focus: GALAXY's
-- down is OPTIONS); GALAXY's right is no move but its RIGHT action (focus trap, LR_ACTIONS.galaxy).
local GRAPH = { quick = { right = "custom", down = "pads" },
                custom = { left = "quick", right = "galaxy", down = "options" },
                galaxy = { left = "custom", down = "options" },
                pads = { up = "quick", right = "options" },
                options = { up = "custom", left = "pads" } }
local function graphMove(id, dir)
  local e = GRAPH[id or ""]
  local t = e and e[dir]
  if t and U.ok(St.ui.rows[t]) then return t end
  return nil
end

-- One up / down step (step -1 / 1): the classic rows wrap; v2 tiles follow the graph; the OPTIONS list does not wrap
-- (its explicit chain does not either).
local function moveIdx(list, id, step)
  if V2.active and V2.mode == "tiles" then return graphMove(id, step < 0 and "up" or "down") or id end
  local p = indexOf(list, id) or 1
  if V2.active then return list[math.max(1, math.min(#list, p + step))] end
  return stepRow(list, p, step)
end

-- A / Enter on the highlighted row from our own navigation (pad poll or keybind). Skipped when the row holds CommonUI
-- focus: CommonUI clicks it itself (ClickMode poll sees GetSelected), a second action would flip toggles twice and
-- start + stop hosting. The first accept after a Back is swallowed (it may confirm the game's "Exit game?" prompt).
local function accept(p1, kind)
  local id = nav.idx
  if id == nil then return end
  if nav.backGuard then
    nav.backGuard = false
    U.dbg(TAG, "nav: accept swallowed once after Back (a game prompt may be open)")
    return
  end
  if U.mod("ui").hasFocus(St.ui.rows[id], p1) then
    U.dbg(TAG, "nav: accept on '%s' left to CommonUI (the row holds focus)", id)
    return
  end
  -- 0.12.0 v2 OPTIONS (review fix): P1's focus on BACK (command row) or a focus trap is the page's too. CommonUI clicks
  -- BACK itself (a trap has no action); the highlighted row (nav.idx, e.g. "adv" right above BACK) must not run as
  -- well: it opened the dev race builder and claimed the press, so BACK's own click was dropped (V-FIN-15 route).
  local extra = heldExtra(p1)
  if extra ~= nil then
    U.dbg(TAG, "nav: accept left to CommonUI (P1's focus is on the OPTIONS %s, not on row '%s')", extra, id)
    return
  end
  consume(id, kind)
  activate(id, 0)
end

-- setup.lua (pad B = step back): the game may also show its Back prompt; the next accept is swallowed.
function lobby.armBackGuard()
  nav.backGuard = true
end

-- FAST loop (ui.pollClicks) while the lobby page shows. Optional extra since 2026-10-07 (see the section header).
function lobby.pollNav()
  if St.launchHold() then return end                  -- 0.12.0: the front end is being torn down (state.lua)
  -- #21: a FREE MODE sub-page owns the screen (LB / RB inert, tab strip hidden, B = Back in the footer): menu_tab's
  -- lock, applied within one FAST tick of the sub-page's open and lifted on the posters
  U.try(TAG, function() U.mod("menu_tab").subPageTick() end)
  if St.menu.visible ~= "lobby" or not U.ok(St.menu.lobby) then nav.primed = false; return end
  if checkCovered() then nav.primed = false; return end
  if setupActive() then
    nav.primed = false                                 -- a fresh baseline when the lobby rows come back
    U.mod("setup").pollNav()
    return
  end
  local p1 = U.p1()
  if not U.ok(p1) then return end
  -- B04 (live 2026-10-15): P1's pad B on the GALAXY RUN page closes it (when P1's PlayerController sees pad B, after a
  -- race); before that, backprompt.lua turns the game's QuitGame prompt this B posts into the same close
  local okRP, rpOn = pcall(function() return U.mod("runpage").active() end)
  local rpB = okRP and rpOn == true and settings.get("KeyboardIsP1") ~= true and U.mod("ui").keyDown(p1, C.KEY.B) or false
  if rpB and not nav.rpBPrev then
    nav.backGuard = true
    U.try(TAG, function() U.mod("runpage").onP1Back("pad B") end)
  end
  nav.rpBPrev = rpB
  -- 0.15 F01: the COUCH CAMPAIGN page closes on P1's B the same way
  local okCP, cpOn = pcall(function() return U.mod("couchpage").active() end)
  local cpB = okCP and cpOn == true and settings.get("KeyboardIsP1") ~= true and U.mod("ui").keyDown(p1, C.KEY.B) or false
  if cpB and not nav.cpBPrev then
    nav.backGuard = true
    U.try(TAG, function() U.mod("couchpage").onP1Back("pad B") end)
  end
  nav.cpBPrev = cpB
  -- 0.16: the GALACTIC GRAND PRIX page too (its setup view steps back to the tours, the others close)
  local okGP, gpOn = pcall(function() return U.mod("gppage").active() end)
  local gpB = okGP and gpOn == true and settings.get("KeyboardIsP1") ~= true and U.mod("ui").keyDown(p1, C.KEY.B) or false
  if gpB and not nav.gpBPrev then
    nav.backGuard = true
    U.try(TAG, function() U.mod("gppage").onP1Back("pad B") end)
  end
  nav.gpBPrev = gpB
  local list = navList()
  if #list == 0 then return end
  local now = St.nowMs()
  local st = readInputs(p1)
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = nearest(list, nav.idx) end
  local focused = focusedId(list, p1)
  local held = focused ~= nil or heldExtra(p1) ~= nil  -- v2 OPTIONS: BACK / a focus trap hold the page's focus too
  local delay = tonumber(opt("LobbyNavRepeatDelayMs", 400)) or 400
  if not nav.primed then                               -- baseline after a (re)show: no edges on this tick
    nav.primed = true
    nav.prev, nav.vdir, nav.hdir = st, axis(st.up, st.down), axis(st.left, st.right)
    nav.vNextMs = now + delay
    nav.armUntilMs = now + (tonumber(opt("LobbyNavArmMs", 250)) or 250)
    if focused ~= nil then
      nav.idx = focused
    elseif not held and focusRow(nav.idx) then         -- e.g. back from the builder page (no "tab" event)
      focused = nav.idx
    end
    nav.lastFocus = focused
    setHighlight(nav.idx)
    return
  end
  -- 1. CommonUI navigation or a mouse hover moved the focus to one of our rows: follow it.
  local focusMoved = focused ~= nil and focused ~= nav.lastFocus
  nav.lastFocus = focused
  if focusMoved then nav.idx = focused end
  -- 2. Up/down with key repeat (only while no row holds focus: CommonUI navigates a focused page itself).
  local vdir, step = axis(st.up, st.down), 0
  if vdir == 0 then
    nav.vdir = 0
  elseif vdir ~= nav.vdir then
    nav.vdir, nav.vNextMs, step = vdir, now + delay, vdir
  elseif now >= nav.vNextMs then
    nav.vNextMs, step = now + (tonumber(opt("LobbyNavRepeatMs", 140)) or 140), vdir
  end
  if step ~= 0 and not focusMoved and not held and nameEdit and V2.mode == "options" then
    lobby.nameEditKey(step < 0 and "up" or "down")     -- PLAYER NAMES editor: up / down step the letter
  elseif step ~= 0 and not focusMoved and not held then
    nav.idx = moveIdx(list, nav.idx, step)
    if focusRow(nav.idx) then nav.lastFocus = nav.idx end
  end
  setHighlight(nav.idx)
  -- 3. Left/right: edge only (no repeat), rows with a value. v2: OPTIONS steps the value while no ghost holds focus
  -- (with focus, the focus traps do it); tiles move along the §4.6 graph (never a value).
  local hdir = axis(st.left, st.right)
  if hdir ~= 0 and hdir ~= nav.hdir then
    if not V2.active then
      activate(nav.idx, hdir)
    elseif not held then
      if V2.mode == "options" then
        V2.lrAtMs = now
        activate(nav.idx, hdir)
      else
        local t = graphMove(nav.idx, hdir < 0 and "left" or "right")
        if t then
          nav.idx = t
          if focusRow(t) then nav.lastFocus = t end
          setHighlight(t)
        elseif hdir > 0 and LR_ACTIONS[nav.idx] then   -- 0.13.0: RIGHT on GALAXY RUN (no tile to its right)
          V2.lrAtMs = now
          activate(nav.idx, hdir)
        end
      end
    end
  end
  nav.hdir = hdir
  -- 4. A / Enter: edge, armed a moment after the show (the press that opened the tab must not click a row).
  if nav.prev.accept and not st.accept then nav.acceptUpMs = now end
  notePadAccept(st.accept == true, nav.prev.accept == true, now)
  if st.accept and not nav.prev.accept and now >= nav.armUntilMs then accept(p1, "pad") end
  if st.back and not nav.prev.back then
    nav.backGuard = true
    U.dbg(TAG, "nav: B on P1 (left to the game's CommonUI back; next accept guarded)")
  end
  nav.prev = st
end

-- Keyboard (UE4SS keybinds, game thread through sched.run): name = "up" | "down" | "left" | "right" | "accept" |
-- "back" (Escape: only arms the Back guard; Escape itself stays the game's) | "back2" (Backspace: setup BACK; v2:
-- closes OPTIONS).
function lobby.onKey(name)
  if St.launchHold() then return end                  -- 0.12.0: no page work while the front end is torn down
  if St.menu.visible ~= "lobby" or not U.ok(St.menu.lobby) then return end
  if not useKeyboard() then return end
  if checkCovered() then return end
  if name == "back" then
    nav.backGuard = true
    return
  end
  local okRP, rpActive = pcall(function() return U.mod("runpage").active() end)
  if okRP and rpActive == true then
    U.mod("runpage").onKey(name)
    return
  end
  local okCP, cpActive = pcall(function() return U.mod("couchpage").active() end)
  if okCP and cpActive == true then
    U.mod("couchpage").onKey(name)
    return
  end
  local okGP, gpActive = pcall(function() return U.mod("gppage").active() end)
  if okGP and gpActive == true then
    U.mod("gppage").onKey(name)
    return
  end
  if setupActive() then
    U.mod("setup").onKey(name)
    return
  end
  local options = V2.active and V2.mode == "options"
  if options and nameEdit and (name == "back2" or name == "up" or name == "down" or name == "left"
                               or name == "right") then
    -- PLAYER NAMES editor: arrows step / move, Backspace deletes left of the cursor (CommonUI's own move onto a focus
    -- trap only puts the focus back for keyboard input, optionsTick); Enter is CommonUI's click on the row (A)
    V2.lrAtMs = St.nowMs()
    lobby.nameEditKey(name)
    return
  end
  if name == "back2" and options and V2.opt and V2.opt.sub then
    lobby.armBackGuard()
    lobby.closeSub("Backspace")
    return
  end
  if name == "back2" then
    if options then                                    -- 0.12.0 v2 §5.3: Backspace closes OPTIONS
      lobby.armBackGuard()
      U.log(TAG, "Backspace: OPTIONS closed (V-FIN-15)")
      lobby.closeOptions("Backspace")
    end
    return
  end
  local p1 = U.p1()
  local list = navList()
  if #list == 0 then return end
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = nearest(list, nav.idx) end
  local focused = focusedId(list, p1)
  if options and (name == "left" or name == "right") then
    -- OPTIONS: left / right step the focused row's value. CommonUI has no left / right of its own on a row, and its
    -- move onto a focus trap does not step for keyboard input (v2Tick): this is the press's one step. The focus may
    -- already sit on a trap: then the row that held it last (v2Tick's V2.optLast)
    nav.idx = focused or ((V2.optLast and U.ok(St.ui.rows[V2.optLast])) and V2.optLast) or nav.idx
    V2.lrAtMs = St.nowMs()
    activate(nav.idx, name == "left" and -1 or 1)
    return
  end
  -- 0.13.0 tiles: keyboard right on GALAXY RUN (or on its focus trap) is its RIGHT action, one step per press (the trap
  -- does not step for keyboard input, tilesTick)
  if V2.active and V2.mode == "tiles" and name == "right" then
    local id = focused or ((heldExtra(p1) == "trap") and "galaxy") or nav.idx
    if id == "galaxy" then
      nav.idx = id
      V2.lrAtMs = St.nowMs()
      activate(id, 1)
      return
    end
  end
  if focused ~= nil or heldExtra(p1) ~= nil then
    -- CommonUI holds focus on a row: it navigates and clicks with the keyboard itself; only follow its focus
    if focused ~= nil then
      nav.idx = focused
      setHighlight(focused)
    end
    return
  end
  logSeen("keybind " .. name)
  if name == "up" or name == "down" then
    nav.idx = moveIdx(list, nav.idx, name == "up" and -1 or 1)
    focusRow(nav.idx)
    setHighlight(nav.idx)
  elseif name == "left" or name == "right" then
    if V2.active then                                  -- v2 tiles: the §4.6 graph (left / right never change a value)
      local t = graphMove(nav.idx, name)
      if t then
        nav.idx = t
        focusRow(t)
      end
      setHighlight(nav.idx)
    else
      setHighlight(nav.idx)
      activate(nav.idx, name == "left" and -1 or 1)
    end
  elseif name == "accept" then
    setHighlight(nav.idx)
    accept(p1, "kb")
  end
end

-- Arrow / Enter / Space / Escape keybinds (cfg.LobbyNavKeyboard ~= "never"). UE4SS keybinds fire on the key-down
-- edge while the game window has focus and never consume the key. They run on UE4SS's event-loop thread, so they go
-- through keyq (0.10.0): the callback only bumps a counter and the FAST loop runs lobby.onKey on the game thread.
-- 0.9.x called sched.run (ExecuteInGameThread) from there, which corrupted the shared hook lua_State
-- (crash_2026_10_08_13_27_33). Note: while a bound key is held (e.g. an arrow while steering), UE4SS drops every
-- other keybind event of that frame (F5-F9 included).
function lobby.init()
  registerListeners()
  if opt("LobbyNavKeyboard", "always") == "never" or type(RegisterKeyBind) ~= "function" or Key == nil then return end
  local keyq = require("keyq")
  local binds = {
    { Key.UP_ARROW, "up" }, { Key.DOWN_ARROW, "down" }, { Key.LEFT_ARROW, "left" }, { Key.RIGHT_ARROW, "right" },
    { Key.RETURN, "accept" }, { Key.SPACE, "accept" }, { Key.ESCAPE, "back" }, { Key.BACKSPACE, "back2" },
  }
  local n = 0
  for _, b in ipairs(binds) do
    local key, name = b[1], b[2]
    if key ~= nil and keyq.bind(key, nil, "lobby." .. name, function() lobby.onKey(name) end) then n = n + 1 end
  end
  nav.kbBound = n > 0
  U.log(TAG, "lobby keyboard navigation: %d keybind(s) (arrows, Enter/Space, Escape guard, Backspace = setup BACK)", n)
end

---------------------------------------------------------------------------------------------------
-- UI v2 (0.12.0): canvas page, posters, players strip, status pill, OPTIONS (spec §4, §5; see the file header)
---------------------------------------------------------------------------------------------------
-- Tile rects, screen su (spec §4.2). 0.13.0: the 0.12.0 posters' area (x 128-2208, y 345-1515) in three columns of
-- 663 / 663 / 664 with the 45-su gaps of the mockup: QUICK / CUSTOM / GALAXY 700 tall, PLAYERS / OPTIONS and the START
-- card (AGAIN, no ghost) 425 tall below them.
local TILE = { quick = {128, 345, 663, 700}, custom = {836, 345, 663, 700}, galaxy = {1544, 345, 664, 700},
               pads = {128, 1090, 663, 425}, options = {836, 1090, 663, 425} }
local AGAIN = { x = 1544, y = 1090, w = 664, h = 425, pad = 48, glyph = 72 }
local TILE_TRAP = {40, 140, 24, 24}                    -- GALAXY RUN's right focus trap (OPTIONS' traps: y 100)
local TXM = "/Game/Griffin/UI/Library/Textures/Content/MainMenu/"
-- CUSTOM RACE's art: the chosen class's MODE strip (setup.lua MODE_V2.race)
local CLASS_STRIP = { Car = "T_UI_FE_Tile_05", Bike = "T_UI_FE_Tile_05_Bike", Skimmer = "T_UI_FE_Tile_05_Skim",
                      Plane = "T_UI_FE_Tile_05_Plane" }
-- Players strip (§4.3): white @0.42 RoundedBox r 21; 270 tall, 330 with the network line; cells at x 164 + 502 i;
-- content top = strip top + 73 (offline) / + 34 (network line). Text boxes are placed by their top = baseline - the
-- face's ascent (Moki 0.826 em, Overpass 0.883 em; em = size x 4/3).
local STRIP = { x = 128, y = 1560, w = 2080, h = 270, hNet = 330, top = 73, topNet = 34, cell = 164, pitch = 502,
                ruleX0 = 164, ruleX1 = 2172, netTextX = 438, netTextW = 1700 }
local JOINED = { host = true, ready = true, disconnected = true, leaving = true }
local CANVAS_CLS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local KML = "/Script/Engine.Default__KismetMaterialLibrary"
local MID_TRANSIENT = 1                                -- EMIDCreationFlags::Transient (cards.lua, vpreview)
local ELLIPSIS, DOT = "\u{2026}", "\u{00B7}"

---------------------------------------------------------------------------------------------------- canvases
local function newCanvas(tree)
  for _, p in ipairs(CANVAS_CLS) do
    local cls = U.class(p)
    if U.ok(cls) then
      local ok, w = pcall(StaticConstructObject, cls, tree)   -- (UClass, Outer = the page's WidgetTree)
      if ok and U.ok(w) then
        pcall(function() w:SetVisibility(C.E.Vis.SelfHitTestInvisible) end)
        return w
      end
    end
  end
  error("cannot construct a canvas panel")
end

-- A canvas filling `parent` (a canvas): full-stretch anchors, zero offsets.
local function subCanvas(parent, z)
  local cv = newCanvas(V2.ctx.tree)
  local s = parent:AddChildToCanvas(cv)               -- UCanvasPanel:AddChildToCanvas(Widget) -> CanvasPanelSlot
  if not U.ok(s) then error("AddChildToCanvas returned no slot") end
  pcall(function()
    s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })   -- FAnchors
    s:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })               -- FMargin (stretch margins)
    s:SetZOrder(z or 0)
  end)
  return cv
end

local function noteGhost(w)
  if U.ok(w) then V2.ghostKeys[#V2.ghostKeys + 1] = U.key(w) end
end

---------------------------------------------------------------------------------------------------- head shots
-- The players strip's heads: racers.lastPilotThumb(ctrlId) (a hard texture path, 256 x 256, 66 KB) through a MID of
-- M_UI_CharacterProfilePicture (parameter Texture, squircle mask; cards.lua's roster tiles). Loaded outside theme's
-- queue (the MID needs the texture object): StaticFindObject, else one LoadAsset per FAST tick.
local HEAD = { broken = false, missing = {}, loadAt = -1e9, mids = 0 }

-- -> texture | nil, "wait" (over this tick's budget) | nil, "missing"
local function headTexture(path)
  local ok, t = pcall(StaticFindObject, path)
  if ok and U.ok(t) then return t end
  if HEAD.missing[path] then return nil, "missing" end
  local now = St.nowMs()
  if now - HEAD.loadAt < 30 then return nil, "wait" end
  HEAD.loadAt = now
  local okL, err = pcall(LoadAsset, path)              -- game thread; 3 returns, re-found below (U.class idiom)
  ok, t = pcall(StaticFindObject, path)
  if ok and U.ok(t) then return t end
  HEAD.missing[path] = true
  U.logOnce("lobby.head?" .. path, TAG, "head shot missing: %s%s (the player icon is shown)", path,
    okL and "" or (" (" .. tostring(err) .. ")"))
  return nil, "missing"
end

local function newHeadMid()
  local parent, kml = U.obj(theme().MAT.ProfilePicture), U.cdo(KML)
  if not (U.ok(parent) and U.ok(kml)) then return nil, "material or KismetMaterialLibrary not found" end
  local ok, mid = pcall(function()
    -- CreateDynamicMaterialInstance(WorldContextObject, Parent, OptionalName, CreationFlags) (cards.lua, vpreview)
    return kml:CreateDynamicMaterialInstance(U.world(), parent, U.fname("None"), MID_TRANSIENT)
  end)
  if ok and U.ok(mid) then
    HEAD.mids = HEAD.mids + 1
    return mid
  end
  return nil, tostring(mid)
end

-- The head shot at `path` on cell c's image (the plain texture when no MID can be made).
-- -> true shown | false waiting for the load budget (retried by v2Tick) | nil missing / unusable.
local function applyHead(c, path)
  if c.headPath == path and c.headOn then return true end
  local t, why = headTexture(path)
  if not t then
    if why == "wait" then return false end
    return nil
  end
  local img = c.head and c.head.w
  if not U.ok(img) then return nil end
  local done = false
  if not HEAD.broken then
    local mid, err = (U.ok(c.mid) and c.mid or nil), nil
    local fresh = mid == nil
    if fresh then mid, err = newHeadMid() end
    if mid and pcall(function() mid:SetTextureParameterValue(U.fname("Texture"), t) end) then   -- (Name, Texture)
      if not fresh then
        done = true
      elseif pcall(function() img:SetBrushFromMaterial(mid) end) then
        c.mid, done = mid, true          -- the new MID's only referencer is this brush: set in the same tick (GC rule)
      end
    else
      HEAD.broken = true
      U.warn(TAG, "head-shot MID unavailable (%s): plain head shots in the players strip",
        tostring(err or "SetTextureParameterValue failed"))
    end
  end
  if not done then
    done = pcall(function() img:SetBrushFromTexture(t, false) end)   -- (Texture2D, bMatchSize)
    if done then c.mid = nil end
  end
  if done then c.headPath, c.headOn = path, true end
  return done and true or nil
end

-- racers.lua (WI-08, changed in parallel): the pilot a pad played last; nil when unknown or not available yet.
local function lastThumb(ctrlId)
  if ctrlId == nil then return nil end
  local ok, p = pcall(function()
    local R = U.mod("racers")
    if type(R.lastPilotThumb) ~= "function" then return nil end
    return R.lastPilotThumb(ctrlId)
  end)
  if ok and type(p) == "string" and p ~= "" then return p end
  return nil
end

---------------------------------------------------------------------------------------------------- race data
local function facing(o)
  if not U.ok(o) then return "" end
  local ok, t = pcall(function() return U.str(o.PlayerFacingName) end)
  if ok and type(t) == "string" and t ~= "" then return string.upper(t) end
  local ok2, n = pcall(function() return o:GetFName():ToString() end)
  if ok2 and type(n) == "string" then return string.upper(n) end
  return ""
end

-- The facts of choice c (§4.2; 0.13.0: the START card's race line): planet line + tone, "LANDSPEEDER · RACE", the
-- track name, the footer "REVERSE · SUNSET · 12 RACERS", the class key; racers = the grid size when known.
local function raceView(c)
  local T = theme()
  local S = nil
  pcall(function() S = U.mod("setup") end)
  local v = {}
  local pk, pname
  pcall(function()
    local p = S.planetFor(c.planet)
    if p then pk, pname = p.key, p.name end
  end)
  v.planet = pname or facing(c.planet)
  v.tone = T.planet(pk or v.planet) or T.COL.BEIGE
  local s = type(c.setup) == "table" and c.setup or nil
  if not s then pcall(function() s = S.deriveSetup(c) end) end     -- a dev-builder choice: setup.lua derives it
  s = type(s) == "table" and s or {}
  local arch = tonumber(s.arch)
  if arch == nil then pcall(function() arch = tonumber(c.archetype.Archetype) end) end
  local cls, mode = nil, nil
  pcall(function() cls = U.mod("vehicles").classByArch(arch) end)
  pcall(function() mode = S.modeByPath(U.pathOf(c.gameMode)) end)
  local cap = {}
  local a = (cls and cls.label) or facing(c.archetype)
  local b = (mode and mode.label) or facing(c.gameMode)
  if a ~= "" then cap[#cap + 1] = a end
  if b ~= "" then cap[#cap + 1] = b end
  v.caption = table.concat(cap, " " .. DOT .. " ")
  v.track = facing(c.track)
  local foot = {}
  local rev = false
  pcall(function() rev = c.track.bIsReverse == true end)          -- UTrackDef.bIsReverse (setup.readTrack)
  if rev then foot[#foot + 1] = "REVERSE" end
  local cond = nil
  pcall(function() cond = S.prettyCond(c.condition) end)
  if type(cond) == "string" and cond ~= "" and cond ~= "DEFAULT" then foot[#foot + 1] = cond end
  local n = nil
  if s.grid == "max" then n = tonumber(s.maxRacers) end
  local mk = s.modeKey or (mode and mode.key)
  if not n and (mk == "mixed" or mk == "eliminator") then n = 12 end   -- 4 + 4 + 4 / 12 racers (§7.5 mode texts)
  if n and n > 0 then
    n = math.floor(n)
    foot[#foot + 1] = string.format("%d RACERS", n)
  else
    n = nil
  end
  v.footer = table.concat(foot, " " .. DOT .. " ")
  v.racers = n
  v.classKey = cls and cls.key or nil
  return v
end

---------------------------------------------------------------------------------------------------- build
-- START card (AGAIN, 0.13.0): the strip's backer (white @0.42 RoundedBox r 21), P1's Start glyph, the action ("RACE
-- AGAIN" / "NEXT RACE" / "START RUN", Moki 39 INK), the track (Moki 30), its class / mode caption (the strip's NETWORK
-- label role) and the play mode / lock line (Overpass Medium Italic 30, 2 lines). No ghost: pad Start (tilesTick) is
-- its button. Placed once; refreshAgain writes the texts.
local function buildAgain()
  local T, ctx, cv = theme(), V2.ctx, V2.tilesCv
  local A, x, y, p = {}, AGAIN.x, AGAIN.y, AGAIN.pad
  A.back = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 21, size = { AGAIN.w, AGAIN.h },
                              tint = T.alpha(T.COL.WHITE, 0.42), z = 0, rect = LR(x, y, AGAIN.w, AGAIN.h) })
  if not A.back then error("START card backer not built") end
  A.glyph = T.image(ctx, cv, { tex = T.glyph("START"), tint = T.COL.INK, z = 2,
                               rect = LR(x + p, y + p, AGAIN.glyph, AGAIN.glyph) })
  A.title = T.text(ctx, cv, "statusText", { colour = T.COL.INK, z = 2, rect = LP(x + p + AGAIN.glyph + 24, y + p + 12) })
  A.line = T.text(ctx, cv, "value", { size = 30, colour = T.COL.INK, z = 2, rect = LP(x + p, y + 156) })
  A.sub = T.text(ctx, cv, "rank", { colour = T.COL.INK, z = 2, rect = LP(x + p, y + 202) })
  A.desc = T.text(ctx, cv, "posterDesc", { colour = T.COL.INK, wrapW = AGAIN.w - 2 * p, z = 2,
                                           rect = LP(x + p, y + 252) })
  V2.again = A
end

-- PLAYERS "Press again to confirm" (§4.2): MI_UI_Pill_Generic RUST + Overpass Medium Italic 30 WHITE, top-right
-- inset 24.
lobby.PADS_BADGE_BOTTOM = 24 + 66                     -- buildBadge: top inset 24, 66 tall
local function buildBadge()
  local T, ctx, p = theme(), V2.ctx, V2.posters.pads
  local w = TILE.pads[3]
  local text = "Press again to confirm"
  local bw, bh = math.floor(T.textWidth(text, "posterDesc") + 64 + 0.5), 66
  V2.badge.pill = T.image(ctx, p.cv, { mat = T.MAT.Pill, drawAs = 1, margin = 0.5, size = bh, tint = T.COL.RUST,
                                       z = 6, rect = { w - 24 - bw, 24, bw, bh }, visible = false })
  V2.badge.text = T.text(ctx, p.cv, "posterDesc", { text = text, colour = T.COL.WHITE, justify = "c",
                                                    align = { 0.5, 0.5 }, rect = { w - 24 - bw / 2, 24 + bh / 2 },
                                                    z = 7, visible = false })
end

-- Players strip (C14, §4.3): the backer, 4 cells (P-tag squircle + "Pn", lock, head squircle / player icon, pad line,
-- pad glyph, state line) and the network line (rule, NETWORK, the remote status). Placed by refreshStrip.
local function buildStrip()
  local T, ctx, cv = theme(), V2.ctx, V2.tilesCv
  local S = { cells = {}, net = {} }
  S.back = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 21, size = { STRIP.w, STRIP.h },
                              tint = T.alpha(T.COL.WHITE, 0.42), z = 0, rect = LR(STRIP.x, STRIP.y, STRIP.w, STRIP.h) })
  if not S.back then error("players strip backer not built") end
  for i = 1, 4 do
    local c = {}
    c.tag = T.image(ctx, cv, { tex = T.TEX.TileFill200, z = 2, rect = { 0, 0, 96, 96 } })
    c.tagTxt = T.text(ctx, cv, "value", { size = 36, justify = "c", align = { 0.5, 0.5 }, z = 3 })
    c.lock = T.image(ctx, cv, { tex = T.TEX.Lock, tint = T.alpha(T.COL.INK, 0.6), z = 3, visible = false,
                                rect = { 0, 0, 40, 40 } })
    c.headBack = T.image(ctx, cv, { tex = T.TEX.TileFill200, tint = T.alpha(T.COL.TILE, 0.9), z = 2, visible = false,
                                    rect = { 0, 0, 124, 124 } })
    c.head = T.image(ctx, cv, { z = 3, visible = false, rect = { 0, 0, 124, 124 } })
    c.headIcon = T.image(ctx, cv, { tex = T.TEX.Player, tint = T.COL.BEIGE, z = 3, visible = false,
                                    rect = { 0, 0, 80, 80 } })
    c.pad = T.text(ctx, cv, "statusText", { colour = T.COL.INK, z = 2 })
    c.glyph = T.image(ctx, cv, { tex = T.glyph("A"), tint = T.COL.INK, z = 2, visible = false,
                                 rect = { 0, 0, 44, 44 } })
    c.state = T.text(ctx, cv, "posterDesc", { colour = T.COL.INK, z = 2 })
    S.cells[i] = c
  end
  S.net.rule = T.image(ctx, cv, { tex = T.TEX.Divider, tint = T.alpha(T.COL.INK, 0.35), z = 2, visible = false,
                                  rect = { 0, 0, 8, 6 } })
  S.net.label = T.text(ctx, cv, "rank", { text = "NETWORK", colour = T.COL.INK, z = 2, visible = false })
  S.net.text = T.text(ctx, cv, "value", { size = 30, colour = T.COL.INK, z = 2, visible = false })
  V2.strip = S
end

-- Explicit navigation of the §4.6 graph (GRAPH) on the five ghosts (CommonUI would move geometrically), and GALAXY
-- RUN's right onto its focus trap (tilesTick runs the RIGHT action and puts the focus back). VERIFY(V-FIN-04).
local function linkTiles()
  local T, r = theme(), St.ui.rows
  local n, total = 0, 0
  for _, id in ipairs(TILE_IDS) do
    for dir, to in pairs(GRAPH[id] or {}) do
      total = total + 1
      if T.nav(r[id], dir, r[to]) then n = n + 1 end
    end
  end
  total = total + 1
  if T.nav(r.galaxy, "right", V2.trapR) then n = n + 1 end
  U.log(TAG, "tile navigation: %d of %d explicit rule(s) of the §4.6 graph on the ghosts (V-FIN-04)", n, total)
end

buildV2 = function(page, root, pc)
  local T = theme()
  local tree = page.WidgetTree
  if not U.ok(tree) then error("page.WidgetTree invalid") end
  V2.ctx = { tree = tree, pc = pc }
  V2.root = root
  local canvas = newCanvas(tree)
  local slot = root:AddChildToVerticalBox(canvas)     -- UVerticalBox:AddChildToVerticalBox(Widget) -> VerticalBoxSlot
  if not U.ok(slot) then error("AddChildToVerticalBox(canvas) returned no slot") end
  pcall(function()
    slot:SetSize({ Value = 1, SizeRule = 1 })         -- FSlateChildSize Fill (§4.1: Size Fill, HAlign / VAlign Fill)
    slot:SetHorizontalAlignment(C.E.HAlign.Fill)
    slot:SetVerticalAlignment(0)                      -- EVerticalAlignment Fill
    slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
  end)
  V2.canvas = canvas
  St.ui.canvas = canvas
  local g = T.pageGeometry(root)                      -- V-FIN-01 (logged by theme)
  V2.geo = { x = g.x, y = g.y, w = g.w, h = g.h, cmdY = g.cmdY, cardH = g.cardH, screen = g.screen, src = g.src }
  V2.geoNow = g
  V2.tilesCv = subCanvas(canvas, 1)
  local ctx = V2.ctx
  local function poster(id, o)
    o.geo, o.z = V2.geo, 1
    local p = T.poster(ctx, V2.tilesCv, TILE[id], o)
    if not p then error("poster '" .. id .. "' not built (see the [theme] log)") end
    V2.posters[id] = p
  end
  -- 0.13.0: one word per title line (the columns are 663 su wide: "CUSTOM RACE" on one line needs 763 at 60 su)
  -- 0.13.0 live: the tile's lower half is cream (title and texts unreadable): zoomed on its dark pods
  poster("quick", { art = T.TEX.LobbyStart, ax = 0.5, ay = 0.2, zoom = 2.0, title = "QUICK\nRACE", titleSize = 69 })
  poster("custom", { art = TXM .. CLASS_STRIP.Car .. "." .. CLASS_STRIP.Car, ax = 0.5, ay = 0.5,
                     title = "CUSTOM\nRACE", titleSize = 69 })
  -- 0.16: the GALACTIC GRAND PRIX poster (the GALAXY RUN's slot; cfg.GrandPrix = false: the old one)
  if cfg.GrandPrix ~= false then
    poster("galaxy", { art = TXM .. "T_UI_FE_Tile_MP_06.T_UI_FE_Tile_MP_06", ax = 0.62, ay = 0.5,
                       title = "GALACTIC\nGRAND PRIX", titleSize = 54 })
  else
    poster("galaxy", { art = T.TEX.MapEventBg, ax = 0.6, ay = 0.5, title = "GALAXY\nRUN", titleSize = 69 })
  end
  poster("pads", { art = T.TEX.LobbyPlayers, ax = 0.5, ay = 0.36, title = "ADD\nPLAYERS", titleSize = 60 })
  poster("options", { art = T.TEX.LobbyOptions, ax = 0.5, ay = 0.62, title = "OPTIONS", titleSize = 60 })
  U.try(TAG, buildBadge)
  if not U.try(TAG, buildAgain) then U.warn(TAG, "START card not built: pad Start still runs START") end
  for _, id in ipairs(TILE_IDS) do
    local w = T.ghost(ctx, V2.tilesCv, TILE[id], id, ghostFn(id), { geo = V2.geo })
    if not U.ok(w) then error("ghost '" .. id .. "' not created") end
    noteGhost(w)
    St.ui.rows[id] = w
  end
  -- GALAXY RUN's right focus trap: an invisible ghost out of every geometric sweep (above-left of the posters), reached
  -- only through GALAXY's explicit right rule (OPTIONS' traps)
  V2.trapR = T.ghost(ctx, V2.tilesCv, TILE_TRAP, "tile:trapR", function() end, { geo = V2.geo })
  noteGhost(V2.trapR)
  linkTiles()
  if not U.try(TAG, buildStrip) then U.warn(TAG, "players strip not built: the lobby works without it") end
  V2.pill = T.statusPill(ctx, canvas, V2.geo)          -- on the page canvas: tiles and OPTIONS share it
  if not V2.pill then U.warn(TAG, "status pill not built: lobby messages only reach the log (V-FIN-12)") end
  V2.active = true
end

-- Every page show (V-FIN-01): the content was placed for V2.geo; a later measurement of the page origin shifts the
-- whole canvas by the difference (a render translation also moves the hit-test geometry).
alignCanvas = function()
  if not (V2.active and U.ok(V2.canvas) and V2.geo) then return end
  local g = theme().pageGeometry(V2.root)
  if g.src == "fallback" and V2.geo.src ~= "fallback" then
    U.dbg(TAG, "page geometry fell back to the constants at this show: the build's measurement (%s) is kept",
      tostring(V2.geo.src))
    return
  end
  V2.geoNow = g
  local dx = math.floor(V2.geo.x - g.x + 0.5)
  local dy = math.floor(V2.geo.y - g.y + 0.5)
  if V2.shift[1] == dx and V2.shift[2] == dy then return end
  if pcall(function() V2.canvas:SetRenderTranslation({ X = dx, Y = dy }) end) then   -- UWidget (Vector2D)
    V2.shift = { dx, dy }
    U.log(TAG, "page origin measured at %d,%d (%s); the content was placed for %d,%d (%s): canvas shifted by %d,%d "
      .. "(V-FIN-01)", math.floor(g.x + 0.5), math.floor(g.y + 0.5), tostring(g.src), math.floor(V2.geo.x + 0.5),
      math.floor(V2.geo.y + 0.5), tostring(V2.geo.src), dx, dy)
  end
end

---------------------------------------------------------------------------------------------------- refresh: tiles
-- One line of `role` (size: nil = the role's), cut with "…" at maxW su (the network line §4.4, the GALAXY RUN / START
-- card lines). Upper-case roles: pass the upper-case text (the width is measured on what is given).
local function fitTo(s, role, size, maxW)
  s = tostring(s or "")
  local T = theme()
  if T.textWidth(s, role, size) <= maxW then return s end
  local cut = s
  while #cut > 0 do
    local shorter = (cut:gsub("[\0-\127\194-\244][\128-\191]*$", ""))   -- drop the last UTF-8 character
    -- review fix: a string ending in an invalid UTF-8 byte (0xC0, 0xC1, 0xF5-0xFF, a lone continuation byte: a
    -- Latin-1 JoinAddress in net.statusText) matches nothing above, and this loop never ended (a game-thread hang)
    if #shorter >= #cut then shorter = cut:sub(1, -2) end
    cut = shorter
    local try = (cut:gsub("[%s%p]+$", "")) .. ELLIPSIS
    if T.textWidth(try, role, size) <= maxW then return try end
  end
  return ELLIPSIS
end

-- "PRO" -> "Pro" (quick.name's difficulty words in the posters' sentence case)
local function word(s)
  s = string.lower(tostring(s or ""))
  return (s:gsub("^%l", string.upper))
end

-- 0.13.0 QUICK RACE / CUSTOM RACE: the play mode's sub-texts (kicker on focus, desc under the title), the check badge
-- on the mode START plays, CUSTOM's art = the chosen class's MODE strip; both locked while a Galaxy run is on (its
-- builds own every launch, run.prelaunch).
local function refreshModes()
  local tier, name = 1, "Rookie"
  pcall(function()
    local q = U.mod("quick")
    tier = q.quickTier()
    name = word(q.name(tier))
  end)
  local match = settings.get("OpponentMatch") == true
  local on, mt, cls = runIs("on"), modeTile(), "Car"
  local v = validChoice() and V2.againView or nil       -- the chosen race's facts (refreshAgain runs first)
  if v and CLASS_STRIP[v.classKey] then cls = v.classKey end
  local sig = table.concat({ name, tostring(tier), tostring(match), tostring(on), mt, cls }, "|")
  if V2.sig.modes == sig then return end
  V2.sig.modes = sig
  local lock = on and "A Galaxy run is on" or false
  local q, c = V2.posters.quick, V2.posters.custom
  if q then
    q.set({ kicker = name .. " difficulty", desc = "Same build for everyone", lock = lock, check = mt == "quick" })
  end
  if c then
    c.set({ art = TXM .. CLASS_STRIP[cls] .. "." .. CLASS_STRIP[cls], kicker = "Your own builds",
            desc = match and "AI match the players" or ("AI on tier " .. tier), lock = lock, check = mt == "custom" })
  end
end

-- GALAXY RUN (Jules 2026-10-14: "it should just open to a page"): a clean button like QUICK / CUSTOM RACE, the
-- title + at most ONE short status line (the kicker): "Run in progress" (always shown) while a run is on, "Starts
-- <League>" (always shown) for an armed run, else on focus the League a new run starts ("Next: ..." after a finished
-- run). No run details on the tile (they overlapped the title): node, planet, track and standings live on the run
-- page its A opens (runpage.lua).
local function galaxyLine()
  if cfg.GrandPrix ~= false then                      -- 0.16 GALACTIC GRAND PRIX: its race / podium, else the tours
    local okG, st = pcall(function() return U.mod("gp").state() end)
    st = okG and st or nil
    if st and st.status == "on" then
      return string.format("Race %d of %d", math.min(st.race or 1, #(st.races or {})), #(st.races or {})), true
    end
    if st and st.status == "done" then return "Podium waiting", true end
    return "Pods, planets, galaxy", false
  end
  local okR, ri = pcall(function()
    local run = U.mod("run")
    local st = run.state()
    return { on = run.active(), status = st and st.status or nil }
  end)
  ri = (okR and type(ri) == "table") and ri or {}
  local lbl = runName(runPick())
  if ri.on then return "Run in progress", true end
  if runIs("armed") then return "Starts " .. lbl, true end
  if ri.status == "won" or ri.status == "lost" then return "Next: " .. lbl, false end
  return lbl, false
end

local function refreshGalaxy()
  local p = V2.posters.galaxy
  if not p then return end
  local line, always = galaxyLine()
  local f = { kicker = line, kickerAlways = always, desc = "", check = modeTile() == "galaxy" }
  local sig = table.concat({ tostring(f.kicker), tostring(f.check), tostring(f.kickerAlways) }, "|")
  if V2.sig.galaxy == sig then return end
  V2.sig.galaxy = sig
  p.set(f)
  U.dbg(TAG, "GALAXY RUN poster: %s", tostring(f.kicker))
end

-- "2 players · 10 AI" (§4.2): local humans (+ remote ones while hosting) and the grid of the chosen race.
local function startKicker()
  local humans = 1
  pcall(function() humans = U.mod("join").localHumanCount() end)
  if netMode() == "host" and isListening() then
    pcall(function() humans = humans + #U.mod("roster").remoteHumans() end)
  end
  humans = math.max(1, math.floor(tonumber(humans) or 1))
  local who = string.format("%d player%s", humans, humans == 1 and "" or "s")
  local n = V2.raceRacers
  if n and n > humans then return string.format("%s %s %d AI", who, DOT, n - humans) end
  return who
end

-- 0.13.0 START card: what P1's pad Start runs now, with startStateV2's precedence (launching, the C11 lock reasons):
-- between run races the run's next race, an armed run, else the chosen race again in the current play mode.
local function refreshAgain()
  local st = startStateV2()
  V2.startState = st
  local c = validChoice() and St.race.choice or nil
  local key = c and (tostring(c) .. "|" .. tostring(c.label)) or nil
  if V2.againKey ~= key then                          -- raceView reads a dozen properties: once per choice
    V2.againKey, V2.againView = key, c and raceView(c) or nil
  end
  local v = V2.againView
  V2.raceRacers = v and v.racers or nil
  local A = V2.again
  if not A then return end
  local T = theme()
  local function join(list)
    local out = {}
    for _, s in ipairs(list) do if s and s ~= "" then out[#out + 1] = s end end
    return table.concat(out, " " .. DOT .. " ")
  end
  local title, line, sub, desc, dim = "RACE AGAIN", "", "", "", 1
  if st.kind == "launching" then
    title, dim = "LAUNCHING" .. ELLIPSIS, 0.5
    line, sub = v and v.track or "", v and v.caption or ""
  elseif gpIs("between") then
    local okN, nr = pcall(function() return U.mod("gp").nextRace() end)
    local okS, gs = pcall(function() return U.mod("gp").state() end)
    nr = (okN and type(nr) == "table") and nr or {}
    title = "NEXT RACE"
    line, sub = tostring(nr.name or ""), tostring(nr.layout or "")
    desc = (okS and gs) and string.format("Grand prix %s race %d / %d", DOT, gs.race or 1, #(gs.races or {})) or "Grand prix"
  elseif runIs("between") then
    local okV, rv = pcall(function() return U.mod("run").cardView() end)
    local okS, rs = pcall(function() return U.mod("run").state() end)
    rv = (okV and type(rv) == "table") and rv or {}
    title = "NEXT RACE"
    line, sub = tostring(rv.track or ""), tostring(rv.planet or "")   -- the route / event: on GALAXY RUN
    desc = (okS and rs) and string.format("Galaxy run %s race %d / %d", DOT, rs.race or 1, rs.length or 0)
      or "Galaxy run"
  elseif v then
    line, sub = v.track, v.caption
    if runIs("armed") then
      title = "START RUN"
      desc = "Starts " .. runLabel(tostring(settings.get("RunLength")))
    elseif runIs("on") then
      desc = "Galaxy run"
    else
      local mode = (settings.get("PlayMode") == "custom") and "custom" or "quick"
      local diff = ""
      if mode == "quick" then pcall(function() diff = word(U.mod("quick").name()) end) end
      desc = join({ MODE_WORD[mode], diff, startKicker() })
    end
  else
    title, line, desc, dim = "START", "NO RACE YET", "Choose one: Quick race or Custom race", 0.5
  end
  if st.lock and st.kind ~= "norace" then desc, dim = st.lock, 0.5 end
  line = fitTo(string.upper(line), "value", 30, AGAIN.w - 2 * AGAIN.pad)
  sub = fitTo(string.upper(sub), "rank", nil, AGAIN.w - 2 * AGAIN.pad)
  local sig = table.concat({ title, line, sub, desc, tostring(dim) }, "|")
  if V2.sig.again == sig then return end
  V2.sig.again = sig
  T.set(A.title, { text = title, opacity = dim })
  T.set(A.glyph, { opacity = dim })
  T.set(A.line, { text = line, visible = line ~= "" })
  T.set(A.sub, { text = sub, visible = sub ~= "" })
  T.set(A.desc, { text = desc, visible = desc ~= "" })
end

-- "pads 2 to 4" (KeyboardIsP1: pads 1 to 3; cfg.MaxLocalPlayers).
local function padRange()
  local guests = math.max(0, math.floor(tonumber(cfg.MaxLocalPlayers) or 4) - 1)
  if guests <= 0 then return nil end
  local first = (settings.get("KeyboardIsP1") == true) and 1 or 2
  if guests == 1 then return string.format("pad %d", first) end
  return string.format("pads %d to %d", first, first + guests - 1)
end

local function refreshPads()
  local p = V2.posters.pads
  if not p then return end
  local join = U.mod("join")
  local on = join.padsEnabled() == true
  local refused = (not on) and (join.isFrozen() or isClient() or St.net.connecting == true)
  local range = padRange()
  local sig = tostring(on) .. "|" .. tostring(refused) .. "|" .. tostring(range)
  if V2.sig.pads == sig then return end
  V2.sig.pads = sig
  -- couch-fix59 (AUTO-145c, shot r4-113): the stack [kicker / title / desc] must stay under the "Press again to
  -- confirm" badge (top 24, 66 tall): the desc goes when it would push the stack over it (it says what the confirm
  -- prompt says anyway)
  local f = { title = on and "PADS ON" or "ADD\nPLAYERS",
              kicker = on and "Until the game restarts" or (range and ("Join with " .. range) or ""),
              desc = "Pads stay on until the game restarts." }
  local T = theme()
  if T.posterStackTop(TILE.pads[3], TILE.pads[4], f) < lobby.PADS_BADGE_BOTTOM + 8 then f.desc = "" end
  f.lock = refused and "Disconnect to change players" or false
  p.set(f)
end

local function refreshOptionsTile()
  local p = V2.posters.options
  if not p then return end
  local gfx = settings.get("SplitGraphics")
  local kicker = table.concat({ LAYOUT_WORD[settings.get("Layout2P")] or "Top / bottom", GFX_WORD[gfx] or tostring(gfx),
                                NET_WORD[netMode()] or tostring(netMode()) }, " " .. DOT .. " ")
  if V2.sig.options == kicker then return end
  V2.sig.options = kicker
  p.set({ kicker = kicker })
end

---------------------------------------------------------------------------------------------------- refresh: strip
-- One line of Moki 30, cut with "…" at maxW su (the network line, §4.4). Remembers the last input.
local function fitLine(s, maxW)
  s = tostring(s or "")
  if V2.fitIn == s then return V2.fitOut end
  local out = fitTo(s, "value", 30, maxW)
  V2.fitIn, V2.fitOut = s, out
  return out
end

-- State line (and the button it names) of a cell, §4.3. A joined guest's leave line follows join's leaveHold: in the
-- lobby a quick B leaves at once (join.poll), "Hold to leave" only where leaving needs the key held.
local function stateLine(st)
  local k = st.kind
  if k == "host" then return "Host " .. DOT .. " ready" end
  if k == "ready" then return st.leaveHold and "Hold to leave" or "to leave", st.leaveKey or "B" end
  if k == "disconnected" then return "Controller disconnected" end
  if k == "leaving" then return "Leaves after this race" end
  if k == "join" then return "to join", st.joinKey or "A" end
  if k == "connect" then return "Connect " .. string.lower(tostring(st.pad or "pad")) end
  if k == "padsoff" then return "Add players first" end
  if k == "later" then return "Available after the next race" end
  if k == "frozen" then return "Disconnect to change players" end
  return "Empty"
end

local function renderCell(i, st, top)
  local T = theme()
  local c = V2.strip.cells[i]
  if not c then return end
  local kind = st.kind or "empty"
  c.kind = kind
  local joined = JOINED[kind] == true
  local pnum = math.floor(tonumber(st.pnum) or i)
  local hue = T.PLAYER[pnum] or T.COL.WHITE
  local INK = T.COL.INK
  local x = STRIP.cell + STRIP.pitch * (i - 1)
  -- P-tag: the hue (open slots @0.38, a disconnected guest @0.5) + "Pn" (INK; P4 WHITE; open: INK @0.6)
  local tagCol = joined and ((kind == "disconnected") and T.alpha(hue, 0.5) or hue) or T.alpha(hue, 0.38)
  local tagInk = joined and ((C.COLOUR_INK or {})[pnum] or INK) or T.alpha(INK, 0.6)
  T.set(c.tag, { colour = tagCol, rect = LR(x, top + 14, 96, 96) })
  T.set(c.tagTxt, { text = "P" .. pnum, colour = tagInk, rect = LP(x + 48, top + 62) })
  T.set(c.lock, { visible = kind == "frozen", rect = LR(x + 72, top - 4, 40, 40) })
  -- head (joined only): the player's last pilot, else the player icon on the TILE squircle; dimmed when disconnected
  local dim = (kind == "disconnected") and 0.5 or 1
  T.set(c.headBack, { visible = joined, opacity = dim, rect = LR(x + 114, top, 124, 124) })
  T.set(c.head, { opacity = dim, rect = LR(x + 114, top, 124, 124) })
  local shown = false
  c.wantHead = nil
  if joined then
    local path = lastThumb(st.ctrlId)
    if path then
      c.wantHead = path
      local r = applyHead(c, path)
      shown = r == true
      if r == false then V2.headWait = true end
    end
  end
  if not shown then c.headOn = false end
  T.set(c.head, { visible = shown })
  T.set(c.headIcon, { visible = joined and not shown, opacity = dim, rect = LR(x + 136, top + 22, 80, 80) })
  -- pad line (Moki 39, baseline top + 46) and state line (Overpass Medium Italic 30, baseline top + 98), a 44-su pad
  -- glyph before it when it names a button
  local tx = joined and (x + 260) or (x + 114)
  local ink = (kind == "padsoff") and T.alpha(INK, 0.5) or INK
  -- the pad line: the slot's custom name (OPTIONS > PLAYER NAMES) in its place, cut to the cell
  local cname = customName(pnum)
  local padText = cname and fitTo(cname, "statusText", nil, (x + STRIP.pitch - 24) - tx) or tostring(st.pad or ("PAD " .. pnum))
  T.set(c.pad, { text = padText, colour = ink, rect = LP(tx, top + 3) })
  local line, key = stateLine(st)
  local g = key and T.glyph(key) or nil
  if g then
    T.set(c.glyph, { tex = g, colour = ink, rect = LR(tx, top + 66, 44, 44), visible = true })
  else
    T.set(c.glyph, { visible = false })
  end
  T.set(c.state, { text = line, colour = ink, rect = LP(g and (tx + 52) or tx, top + 63) })
end

-- A head that waited for the load budget (FAST tick).
local function retryHeads()
  local T, wait = theme(), false
  for _, c in ipairs((V2.strip or {}).cells or {}) do
    if c.wantHead and not c.headOn then
      local r = applyHead(c, c.wantHead)
      if r == true then
        T.set(c.head, { visible = true })
        T.set(c.headIcon, { visible = false })
      elseif r == false then
        wait = true
      end
    end
  end
  V2.headWait = wait
end

local lastNetText = nil          -- module level: a front-end reload (start hosting) between two pages is a change too
local function noteNetChange(text)
  if text == lastNetText then return end
  local prev = lastNetText
  lastNetText = text
  if prev ~= nil and text ~= "" and V2.pill then
    -- §4.4: a change of the remote state is posted once (StatusPillMs); the pill never stays on because of the network
    V2.pill.post(text, { warn = isWarnText(text), key = "net" })
  end
end

local function refreshStrip()
  local S = V2.strip
  if not S then return end
  local T = theme()
  local netOn = netMode() ~= "offline"
  local text = ""
  if netOn then pcall(function() text = tostring(U.mod("net").statusText() or "") end) end
  noteNetChange(text)
  local h = netOn and STRIP.hNet or STRIP.h
  local top = STRIP.y + (netOn and STRIP.topNet or STRIP.top)
  T.set(S.back, { rect = LR(STRIP.x, STRIP.y, STRIP.w, h) })
  -- network line (§4.4), baseline 46 su above the strip's bottom: a 6-su rule INK @0.35 36 su higher, "NETWORK" (rank)
  -- at x 164, the remote status (Moki 30, one line, cut at 1700 su) at x 438
  local base = STRIP.y + h - 46
  T.set(S.net.rule, { visible = netOn, rect = LR(STRIP.ruleX0, base - 42, STRIP.ruleX1 - STRIP.ruleX0, 6) })
  T.set(S.net.label, { visible = netOn, rect = LP(STRIP.ruleX0, base - 32) })
  T.set(S.net.text, { visible = netOn and text ~= "", text = fitLine(text, STRIP.netTextW),
                      rect = LP(STRIP.netTextX, base - 33) })
  local states = {}
  pcall(function() states = U.mod("join").slotStates() or {} end)
  V2.headWait = false
  for i = 1, 4 do
    U.try(TAG, renderCell, i, states[i] or { kind = "empty", pnum = i, pad = "PAD " .. i }, top)
  end
end

---------------------------------------------------------------------------------------------------- OPTIONS
-- §5.1 / §5.2: groups from y 450 (header, first row 78 below its top, rows 96 tall at a pitch of 102, groups 24
-- apart), list x 128-2000, detail column at x 2190 (top 520, width 1430), BACK in the command row. The ADVANCED group
-- lives on its own canvas that moves one pitch up while the NETWORK action row is collapsed (offline).
local OPT_GROUPS = {
  { label = "SPLIT SCREEN", ids = {"layout", "gfx", "takedown", "tags"} },
  { label = "PLAYERS", ids = {"kbp1", "names", "run", "couch"} },   -- 0.13.0: Play mode left for the QUICK / CUSTOM posters
  { label = "NETWORK", ids = {"net", "netact"} },
  { label = "ADVANCED", ids = {"adv", "couchdel"}, shift = true },
}
-- #98: Delete all couch progress is the ADVANCED group's second row. Offline (the network action row collapsed, the
-- group one pitch up) the list still ends at y 1848; with the network action row shown it ends at 1950: below the
-- content bottom, but left of BACK (x 3292) and above the status pill (y >= 1995).
-- gap 24 (was 36) since the Player names row: the ten rows end at y 1848 with the network action row shown, above the
-- content bottom (FRAME.content.y1 1856) and the command row (y 1880).
-- couch-fix39: the Couch campaign row (PLAYERS): first 70 (was 78), gap 12 (was 24): the twelve rows end at y 1984 with
-- the network action row shown (still above the status pill, y >= 1995), 1882 offline.
local OPT = { x0 = 128, x1 = 2000, y0 = 450, first = 70, pitch = 102, h = 96, gap = 12, detailX = 2190, detailY = 520,
              detailW = 1430, trapL = {40, 100, 24, 24}, trapR = {72, 100, 24, 24}, trapU = {104, 100, 24, 24},
              trapD = {136, 100, 24, 24} }
local LR_KINDS = { cycle = true, toggle = true }

local NET_HELP = "<H1>Host</>: friends join your race over the network. <H1>Join</>: race on a host's grid."
local function netStatus()
  local s = ""
  pcall(function() s = tostring(U.mod("net").statusText() or "") end)
  return s
end
-- a plain text inside the rich help text: no markup characters
local function richSafe(s) return (tostring(s):gsub("<", "("):gsub(">", ")")) end

-- Help texts (§5.2) and the settings key of each row's "Default value: …".
local HELP = {
  layout = { def = "Layout2P", body = "How two players share the screen: one view above the other, or side by side." },
  gfx = { def = "SplitGraphics", body = "The graphics preset while the screen is split. <H1>Auto</> picks one by the "
    .. "number of views; <H1>My settings</> keeps your own settings." },
  takedown = { def = "TakedownCams", body = "Show the takedown cutaway camera in split races." },
  tags = { def = "NameTags", body = "Show the P1-P4 tags (or the players' own names) over the human racers." },
  names = { body = "Your own name for each player: on the tags over the cars, in the race positions and the results. "
    .. "<H1>A</> opens the four names." },
  kbp1 = { def = "KeyboardIsP1", body = "P1 plays with the keyboard and every pad becomes a guest." },
  net = { def = "NetMode", body = function()          -- the remote status in full, then the two modes
    local s = netStatus()
    if s ~= "" then return richSafe(s) .. "\n" .. NET_HELP end
    return NET_HELP
  end },
  netact = { body = netStatus },
  adv = { body = "The game's own race builder, for any race this screen cannot make." },
  couch = { body = "The couch campaign's rules for 2-4 players: the guests' choices, what pays P1. <H1>A</> opens the "
    .. "list." },
  mystteam = { def = "CouchMysteryTeam", body = "A mystery encounter's choice with a <H1>team</> effect: a League "
    .. "token, a sabotage, a debuff on P1's car, the rivals' difficulty, Hibi's prices. <H1>Greyed</>: only P1 can "
    .. "take it. <H1>Allowed</>: a guest may take it too: the team effect goes onto the shared run, whatever it does "
    .. "(a sabotage of P1's car included), his credits and parts stay his own. The same effect taken twice in one "
    .. "encounter counts once. Deals paid later in the run stay greyed for guests." },
  couchecon = { def = "CouchEconomy", body = "What P1's wallet and reward round follow after a race. <H1>Own place</>: "
    .. "his own finish, like every guest's (the team's best result still decides League Tokens, must-win events and "
    .. "the act). <H1>Best carries everyone</>: the best human's result pays P1 too (the old rule)." },
  couchdel = { body = function()
    if lobby.CD.armed() then
      return "<H1>A</> again deletes the couch campaign save and every guest's progress: the acts lock again and a "
        .. "fresh ACT I starts right away. Your solo campaign is not touched; vehicle upgrades and logbook unlocks "
        .. "stay. Move away or wait to keep everything."
    end
    local p = lobby.CD.profile()
    local base = "Deletes the couch campaign save and every guest's progress (the guests' file is kept in a dated "
      .. "copy). Your solo campaign is not touched. <H1>A</> twice deletes."
    if p.live then return base .. "\nCouch save profile live: only couch data is deleted." end
    return base .. "\nNot available: " .. richSafe(p.why)
  end },
  run = { def = "RunLength", body = "The game's own rogue mode for 1-4 players: a League across the campaign's real "
    .. "planets, everyone on a <H1>starter build</>. Each planet is a <H1>node map</>: races, eliminators, field "
    .. "tests; the boss events are <H1>must-win</>. Missed targets cost <H1>League Tokens</>; 0 tokens ends the run. "
    .. "Between races: a reward (real rarity odds), then the <H1>shop</> with the campaign's prices; a wreck turns a "
    .. "part <H1>faulty</>. The <H1>GALAXY RUN</> poster starts a run and its next races; RIGHT on it picks the next "
    .. "node. While a run is on, A twice here ends it." },
}

-- couch-fix36 (Jules's audit decision Q4; couchpenalty.lua): a COUCH CAMPAIGN row, self-contained here (ids,
-- LABEL, BUTTON_ACTIONS, LR_ACTIONS, HELP); cycle rows on settings.txt keys, the default first. A field of lobby, no
-- new local (the main chunk is at Lua's 200-locals limit). couch-fix41: the fix36 cbtokens row is gone (solo parity:
-- an unhappy backer never costs a League Token).
lobby.FIX36 = {
  cbbroker = { key = "CouchBrokerPenalty", label = "Broker penalty: Eliminators", values = { "both", "owner" },
    words = { both = "BOTH PLAYERS", owner = "OWNER ONLY" },
    body = "The Broker's penalty for a POOR rating turns the next events into <H1>Eliminators</>. <H1>Both "
      .. "players</>: a guest's Broker changes the shared map for everybody. <H1>Owner only</>: a guest's Broker is his "
      .. "own rule (his races outside the top 3 earn him no reward round). P1's own Broker is the game's and always "
      .. "changes the shared map. The Hutt's penalty (2 crashes fewer) is always the player's own car." },
}
for _, id in ipairs({ "cbbroker" }) do
  local r = lobby.FIX36[id]
  local function word(v) return r.words[v] or string.upper(tostring(v)) end
  local ids = lobby.SUBS.couch.ids
  ids[#ids + 1] = id
  LABEL[id] = function() return r.label, word(settings.get(r.key)), "cycle" end
  local function step(dir)
    cycle(r.key, r.values, dir)
    St.ui.dirty = true
    U.log(TAG, "COUCH CAMPAIGN: %s = %s", r.key, tostring(settings.get(r.key)))
  end
  BUTTON_ACTIONS[id], LR_ACTIONS[id], r.step = step, step, step
  HELP[id] = { body = r.body, foot = function()
    local d = type(cfg.Defaults) == "table" and cfg.Defaults[r.key] or nil
    -- couch-fix50 (AUTO-130a): sentence case like every other "Default value: …" (spec §5.2), not the row's CAPS
    local w = string.lower(tostring(word(d or r.values[1])))
    return "Default value: " .. richSafe((w:gsub("^%l", string.upper)))
  end }
end

local NAME_EDIT_HELP = "<H1>Up / Down</> change the letter, <H1>Left / Right</> move, <H1>X</> deletes. <H1>A</> "
  .. "keeps the name, <H1>B</> gives the old one back. Keyboard: arrows, Backspace, Enter."
for id, n in pairs(NAME_SLOT) do
  HELP[id] = {
    body = function()
      if nameEdit and nameEdit.slot == n then return NAME_EDIT_HELP end
      return "<H1>A</> edits P" .. n .. "'s name (up to " .. tostring(tonumber(cfg.PlayerNameMaxChars) or 16)
        .. " letters). An empty name gives the default back. Lower case: settings.txt <H1>Name" .. n
        .. "</> or the console couch set Name" .. n .. " ..."
    end,
    foot = function() return "Default value: " .. richSafe(defaultName(n)) end,
  }
end

-- The default value in words (config.Defaults, so the text follows a changed default).
local function defaultWord(key)
  local v = nil
  if type(cfg.Defaults) == "table" then v = cfg.Defaults[key] end
  if v == nil and type(cfg.DefaultsBuiltin) == "table" then v = cfg.DefaultsBuiltin[key] end
  if key == "Layout2P" then return LAYOUT_WORD[v] or tostring(v) end
  if key == "SplitGraphics" then return GFX_WORD[v] or tostring(v) end
  if key == "NetMode" then return NET_WORD[v] or tostring(v) end
  if key == "CouchEconomy" then return (v == "best") and "Best carries everyone" or "Own place" end   -- couch-fix35
  if type(v) == "boolean" then return v and "On" or "Off" end
  -- couch-fix50 (live round 2 AUTO-130a: COUCH CAMPAIGN "Default value: greyed"): a plain setting word in sentence case
  return (tostring(v):gsub("^%l", string.upper))
end

-- P1 uses a pad (CommonInputSubsystem:GetCurrentInputType() ~= MouseAndKeyboard; unknown = pad), undebounced (setup's
-- gamepadInput): the focus traps step only for pad input (keyboard left / right step through onKey).
local cis = nil
local function p1PadInput()
  if not U.ok(cis) then
    cis = nil
    pcall(function()
      local cls = U.class("/Script/CommonInput.CommonInputSubsystem")
      local o = U.SBL():GetLocalPlayerSubSystemFromPlayerController(U.p1(), cls)
      if U.ok(o) then cis = o end
    end)
    if not cis then return true end
  end
  local ok, t = pcall(U.callMethod, cis, "GetCurrentInputType")   -- uobj: U.ok(cis) above (or freshly found) -- 0 MouseAndKeyboard, 1 Gamepad, 2 Touch
  if not ok then return true end
  return tonumber(t) ~= 0
end

local function updateDetail(id)
  local O = V2.opt
  if not (O and O.detail and id and LABEL[id]) then return end
  local label = LABEL[id]()
  local h = HELP[id] or {}
  local body = h.body
  if type(body) == "function" then body = body() end
  body = tostring(body or "")
  local foot = h.def and ("Default value: " .. defaultWord(h.def)) or nil
  if not foot and type(h.foot) == "function" then foot = h.foot() end
  O.detailId = id
  local sig = table.concat({ id, tostring(label), body, tostring(foot) }, "|")
  if O.detailSig == sig then return end
  O.detailSig = sig
  O.detail.set({ title = label, body = body, foot = foot and { foot } or {} })
end
-- couch-fix50: the "Default value: …" foot of a row (tools/test_ui130.lua)
lobby._helpFoot = function(id)
  local h = HELP[id] or {}
  if h.def then return "Default value: " .. defaultWord(h.def) end
  if type(h.foot) == "function" then return h.foot() end
  return nil
end

-- Explicit navigation (V-FIN-04): up / down between the visible rows, the last row's down = BACK and BACK's up = the
-- last row, left / right of the value rows = the focus traps (CommonUI has no left / right on a row of its own).
local function relinkOptions()
  local O = V2.opt
  if not O then return end
  local T = theme()
  local vis = {}
  for _, id in ipairs(lobby.SUBS.idsOf(O)) do
    local r = O.rows[id]
    if r and U.ok(r.ghost) and not (id == "netact" and O.actShown == false)
       and not (id == "couchdel" and O.delShown == false) then vis[#vis + 1] = id end
  end
  local n = 0
  for i, id in ipairs(vis) do
    local w = O.rows[id].ghost
    if i > 1 and T.nav(w, "up", O.rows[vis[i - 1]].ghost) then n = n + 1 end
    if i < #vis and T.nav(w, "down", O.rows[vis[i + 1]].ghost) then n = n + 1 end
    local _, _, kind = LABEL[id]()
    if LR_KINDS[kind] then
      if T.nav(w, "left", O.trapL) then n = n + 1 end
      if T.nav(w, "right", O.trapR) then n = n + 1 end
    end
  end
  local back = O.cmd and O.cmd.widget("back")
  if U.ok(back) and #vis > 0 then
    local last = O.rows[vis[#vis]].ghost
    if T.nav(last, "down", back) then n = n + 1 end
    if T.nav(back, "up", last) then n = n + 1 end
  end
  -- PLAYER NAMES: a row's own rules after an edit (an explicit rule stays until replaced): the first row's up and the
  -- rows' left / right stay on the row itself (no rule of their own before), not on the editor's focus traps
  if O.sub == "names" and #vis > 0 then
    if T.nav(O.rows[vis[1]].ghost, "up", O.rows[vis[1]].ghost) then n = n + 1 end
    for _, id in ipairs(vis) do
      local w = O.rows[id].ghost
      if T.nav(w, "left", w) then n = n + 1 end
      if T.nav(w, "right", w) then n = n + 1 end
    end
  end
  -- the name being edited: its four directions go to the focus traps (optionsTick steps the editor)
  if nameEdit and O.sub == "names" then
    local r = O.rows["name" .. nameEdit.slot]
    if r and U.ok(r.ghost) then
      for dir, trap in pairs({ up = O.trapU, down = O.trapD, left = O.trapL, right = O.trapR }) do
        if T.nav(r.ghost, dir, trap) then n = n + 1 end
      end
    end
  end
  U.dbg(TAG, "OPTIONS navigation: %d explicit rule(s) over %d rows (%s)", n, #vis, table.concat(vis, ", "))
end

local function refreshOptionsPage()
  local O = V2.opt
  if not O then return end
  local showAct = netMode() ~= "offline"
  St.ui.shown = St.ui.shown or {}
  St.ui.shown.netact = showAct                         -- navList skips the collapsed action row
  if O.actShown ~= showAct then
    O.actShown = showAct
    if O.rows.netact then O.rows.netact.show(showAct) end
    pcall(function() O.advCv:SetRenderTranslation({ X = 0, Y = showAct and 0 or -OPT.pitch }) end)
    if not showAct and nav.idx == "netact" then
      nav.idx = "net"
      if V2.mode == "options" and St.menu.visible == "lobby" then focusRow("net") end
    end
    relinkOptions()
  end
  -- #98: the delete row only while cfg.CouchDeleteProgress is on
  local showDel = lobby.CD.on()
  St.ui.shown.couchdel = showDel
  if O.delShown ~= showDel then
    O.delShown = showDel
    if O.rows.couchdel then O.rows.couchdel.show(showDel) end
    if not showDel then
      lobby.CD.disarm("turned off")
      if nav.idx == "couchdel" then
        nav.idx = "adv"
        if V2.mode == "options" and St.menu.visible == "lobby" then focusRow("adv") end
      end
    end
    relinkOptions()
  end
  for _, id in ipairs(lobby.SUBS.idsOf(O)) do
    local r = O.rows[id]
    if r then
      local label, value, kind, on = LABEL[id]()
      local sig = table.concat({ tostring(label), tostring(value), tostring(kind), tostring(on) }, "|")
      if O.sig[id] ~= sig then
        O.sig[id] = sig
        r.set({ label = label, value = value, kind = kind, on = on == true })
      end
    end
  end
  if O.detailId then updateDetail(O.detailId) end
end

local function buildOptions()
  local T = theme()
  local ctx = V2.ctx
  local g = V2.geoNow or V2.geo
  -- placed in the canvas's coordinates (V2.geo's origin; alignCanvas shifts the canvas) with the page bottom measured
  -- at the latest show (the command row's cmdY)
  local geo = { x = V2.geo.x, y = V2.geo.y, w = g.w, h = g.h, cmdY = g.cmdY, cardH = g.cardH, screen = g.screen,
                src = g.src }
  local O = { rows = {}, headers = {}, sig = {}, actShown = nil, painted = nil, detailId = nil, detailSig = nil }
  O.cv = subCanvas(V2.canvas, 2)
  showW(O.cv, false)
  O.bg = T.pageBackground(ctx, O.cv, geo, "hub", { z = -10 })                -- C1 (V-FIN-02)
  O.title = T.screenTitle(ctx, O.cv, geo, "OPTIONS")                         -- C2 (V-FIN-03)
  O.listCv = subCanvas(O.cv, 3)                        -- the groups below (hidden while PLAYER NAMES shows)
  O.advCv = subCanvas(O.listCv, 3)
  local y, nRows = OPT.y0, 0
  for _, grp in ipairs(OPT_GROUPS) do
    local cv = grp.shift and O.advCv or O.listCv
    O.headers[#O.headers + 1] = T.groupHeader(ctx, cv, OPT.x0, OPT.x1, y, grp.label, { geo = geo })
    y = y + OPT.first
    for _, id in ipairs(grp.ids) do
      local r = T.settingsRow(ctx, cv, { OPT.x0, y, OPT.x1 - OPT.x0, OPT.h }, { geo = geo, id = id, fn = ghostFn(id) })
      if r and U.ok(r.ghost) then
        O.rows[id] = r
        St.ui.rows[id] = r.ghost                       -- the ROW_ORDER id: refresh, focusedId, activate, click poll
        noteGhost(r.ghost)
        nRows = nRows + 1
      else
        U.warn(TAG, "OPTIONS row '%s' not built", id)
      end
      y = y + OPT.pitch
    end
    y = y + OPT.gap
  end
  if nRows == 0 then error("no OPTIONS row could be built") end
  -- PLAYER NAMES: one group on its own canvas in the list's place (lobby.openNames / closeNames)
  O.namesCv = subCanvas(O.cv, 3)
  showW(O.namesCv, false)
  local yN = OPT.y0
  O.headers[#O.headers + 1] = T.groupHeader(ctx, O.namesCv, OPT.x0, OPT.x1, yN, "PLAYER NAMES", { geo = geo })
  yN = yN + OPT.first
  for _, id in ipairs(NAME_IDS) do
    local r = T.settingsRow(ctx, O.namesCv, { OPT.x0, yN, OPT.x1 - OPT.x0, OPT.h }, { geo = geo, id = id, fn = ghostFn(id) })
    if r and U.ok(r.ghost) then
      O.rows[id] = r
      St.ui.rows[id] = r.ghost
      noteGhost(r.ghost)
    else
      U.warn(TAG, "PLAYER NAMES row '%s' not built", id)
    end
    yN = yN + OPT.pitch
  end
  -- couch-fix39: COUCH CAMPAIGN, the same way (lobby.openCouch / closeSub)
  O.couchCv = subCanvas(O.cv, 3)
  showW(O.couchCv, false)
  local yC = OPT.y0
  O.headers[#O.headers + 1] = T.groupHeader(ctx, O.couchCv, OPT.x0, OPT.x1, yC, lobby.SUBS.couch.header, { geo = geo })
  yC = yC + OPT.first
  for _, id in ipairs(lobby.SUBS.couch.ids) do
    local r = T.settingsRow(ctx, O.couchCv, { OPT.x0, yC, OPT.x1 - OPT.x0, OPT.h }, { geo = geo, id = id, fn = ghostFn(id) })
    if r and U.ok(r.ghost) then
      O.rows[id] = r
      St.ui.rows[id] = r.ghost
      noteGhost(r.ghost)
    else
      U.warn(TAG, "COUCH CAMPAIGN row '%s' not built", id)
    end
    yC = yC + OPT.pitch
  end
  O.detail = T.detailColumn(ctx, O.cv, OPT.detailX, OPT.detailY, OPT.detailW, { geo = geo })   -- C12
  O.cmd = T.commandRow(ctx, O.cv, geo, { { id = "back", label = "BACK", ghostId = "opt:back",
                                           fn = function()
                                             if V2.opt and V2.opt.sub then lobby.closeSub("BACK")
                                             else lobby.closeOptions("BACK") end
                                           end } })   -- C4
  if O.cmd then
    O.cmd.show({ back = true })
    noteGhost(O.cmd.widget("back"))
  end
  -- focus traps: invisible ghosts out of every geometric sweep, reached only through the value rows' explicit left /
  -- right rules; v2Tick steps the row and puts the focus back (setup's cycler trap)
  local noop = function() end
  O.trapL = T.ghost(ctx, O.cv, OPT.trapL, "opt:trapL", noop, { geo = geo })
  O.trapR = T.ghost(ctx, O.cv, OPT.trapR, "opt:trapR", noop, { geo = geo })
  O.trapU = T.ghost(ctx, O.cv, OPT.trapU, "opt:trapU", noop, { geo = geo })   -- the name editor's up / down
  O.trapD = T.ghost(ctx, O.cv, OPT.trapD, "opt:trapD", noop, { geo = geo })
  noteGhost(O.trapL)
  noteGhost(O.trapR)
  noteGhost(O.trapU)
  noteGhost(O.trapD)
  V2.opt = O
  refreshOptionsPage()                                 -- values, the action row's visibility, the explicit navigation
  U.log(TAG, "OPTIONS page built: %d rows, detail column %s, BACK %s, focus traps %s (V-FIN-04)", nRows,
    O.detail and "ok" or "MISSING", O.cmd and "ok" or "MISSING",
    (U.ok(O.trapL) and U.ok(O.trapR)) and "ok" or "MISSING")
end

-- One painted look in the list (diffed): r.set is a dozen setters, so only the rows that change are written.
local function paintRows(painted)
  local O = V2.opt
  if O.painted == painted then return end
  local old = O.painted
  O.painted = painted
  if old and O.rows[old] then O.rows[old].set({ focused = false }) end
  if painted and O.rows[painted] then O.rows[painted].set({ focused = true }) end
  if painted then updateDetail(painted) end
end

-- OPTIONS -> tiles without focus handling (closeOptions, a setup opened over OPTIONS).
local function leaveOptions()
  local O = V2.opt
  lobby.CD.disarm("OPTIONS closed")                     -- #98: a delete confirm never outlives the page
  if nameEdit then U.try(TAG, lobby.endNameEdit, "cancel") end   -- an unfinished name is dropped
  if O and O.sub then
    O.sub = nil
    showW(O.namesCv, false)
    if O.couchCv then showW(O.couchCv, false) end
    showW(O.listCv, true)
    U.try(TAG, relinkOptions)
  end
  if NAME_SLOT[V2.optLast or ""] then V2.optLast = "names" end
  for _, id in ipairs(lobby.SUBS.couch.ids) do if V2.optLast == id then V2.optLast = "couch" end end
  V2.mode = "tiles"
  if O then
    if O.painted and O.rows[O.painted] then O.rows[O.painted].set({ focused = false }) end
    O.painted = nil
    showW(O.cv, false)
  end
  showW(V2.tilesCv, true)
  V2.painted = nil                                     -- the tiles repaint on the next tick
  V2.sPrev, V2.sArmed = true, false                    -- 0.13.0: a Start held over OPTIONS is no START
  nav.primed = false
end

---------------------------------------------------------------------------------------------------- FAST tick
local function paintTiles(painted)
  if V2.painted == painted then return end
  V2.painted = painted
  for id, p in pairs(V2.posters) do p.focus(id == painted) end
end

local function tilesTick(p1, now)
  local ui = U.mod("ui")
  local focused, hovered
  for _, id in ipairs(TILE_IDS) do
    local w = St.ui.rows[id]
    if U.ok(w) then
      if not hovered and ui.hovered(w) then hovered = id end
      if not focused and ui.hasFocus(w, p1) then focused = id end
    end
  end
  if focused and not V2.focusSeen then
    V2.focusSeen = true
    U.log(TAG, "P1's CommonUI focus is on the '%s' ghost; the painted look follows it (V-FIN-04)", focused)
  end
  if focused then nav.idx = focused end                -- the cursor follows CommonUI (also with LobbyPadNav off)
  -- 0.13.0 pad right on GALAXY RUN: CommonUI moved P1's focus onto its focus trap -> focus back (RIGHT does nothing
  -- there since 2026-10-14: no LR action on the tile)
  -- (keyboard right steps through onKey; the trap only puts the focus back then)
  if U.ok(V2.trapR) and ui.hasFocus(V2.trapR, p1) then
    if not checkCovered() and p1PadInput() and now - V2.lrAtMs > 300 then
      V2.lrAtMs = now
      U.logOnce("lobby.tileTrap", TAG, "GALAXY RUN: pad right through the focus trap (V-FIN-04)")
      activate("galaxy", 1)
    end
    nav.idx = "galaxy"
    focusRow("galaxy")
  end
  -- 0.13.0 START (no poster any more): P1's pad Start, run on its RELEASE when the press began and ends with nothing
  -- covering the lobby (a game screen Start opens covers it first). Not with KeyboardIsP1 (pad 1 is a guest then).
  -- VERIFY(V-FIN-17): pad Start on FREE MODE races again and opens no game screen.
  local kbp1 = settings.get("KeyboardIsP1") == true
  local sDown = (not kbp1) and U.ok(p1) and ui.keyDown(p1, C.KEY.Start) or false
  if sDown and not V2.sPrev then V2.sArmed = not checkCovered() end
  if V2.sPrev and not sDown and V2.sArmed then
    V2.sArmed = false
    if not checkCovered() and ui.claimAction("pad:start") then
      U.log(TAG, "P1's pad Start: START (%s)", tostring(V2.startState and V2.startState.kind or "?"))
      U.try(TAG, startTile)
      St.ui.dirty = true
      if St.menu.visible == "lobby" then U.try(TAG, lobby.refresh) end
    end
  end
  V2.sPrev = sDown
  -- one focus look per surface (rule 5): the hovered tile, else the focused one, else the poll's cursor
  paintTiles(hovered or focused or nav.idx)
  local badge = now <= padsConfirmUntilMs              -- PLAYERS 2-press window (lobby.onPads resets it on enable)
  if badge ~= V2.badgeOn then
    V2.badgeOn = badge
    theme().set(V2.badge.pill, { visible = badge })
    theme().set(V2.badge.text, { visible = badge })
  end
  if V2.headWait then retryHeads() end
end

local function optionsTick(p1, now)
  local O = V2.opt
  if not O then return end
  local ui = U.mod("ui")
  -- P1's pad B closes OPTIONS (§5.3; setup.pollP1Back's edge poll). Not with KeyboardIsP1 (pad 1's B is a guest's
  -- then), and not when another screen covered the lobby before this press (that screen owns B); the game's Exit
  -- prompt this B may open is answered by the back guard (V-FIN-15)
  local kbp1 = settings.get("KeyboardIsP1") == true
  local bDown = (not kbp1) and U.ok(p1) and ui.keyDown(p1, C.KEY.B) or false
  local edge = bDown and not V2.bPrev
  V2.bPrev = bDown
  if edge and not V2.wasCovered then
    lobby.armBackGuard()
    V2.backMs = now                                    -- backprompt.lua: this B's step is done (lastP1BackMs)
    lobby.optionsBack("pad B")
    return
  end
  local covered = checkCovered()
  V2.wasCovered = covered
  -- PLAYER NAMES editor: pad X deletes (edge; not with KeyboardIsP1, pad 1 is a guest's then)
  local xDown = nameEdit ~= nil and (not kbp1) and U.ok(p1) and ui.keyDown(p1, C.KEY.X) or false
  if xDown and not V2.xPrev and not covered and nameEdit then lobby.nameEditKey("delete") end
  V2.xPrev = xDown
  -- the edited name's up / down: CommonUI moved P1's focus onto the up / down trap (relinkOptions) -> one letter step
  if nameEdit then
    local v = nil
    if U.ok(O.trapU) and ui.hasFocus(O.trapU, p1) then v = "up" elseif U.ok(O.trapD) and ui.hasFocus(O.trapD, p1) then v = "down" end
    local tl = ui.hasFocus(O.trapL, p1) and "left" or (ui.hasFocus(O.trapR, p1) and "right") or nil
    local k = v or tl
    if k then
      local step = tonumber(opt("NameEditStepMs", 200)) or 200
      if not covered and p1PadInput() and now - V2.lrAtMs > step then
        V2.lrAtMs = now
        U.logOnce("lobby.nameTrap", TAG, "PLAYER NAMES: pad %s through the focus trap (V-NAM-05)", k)
        lobby.nameEditKey(k)
      end
      if nameEdit then focusRow("name" .. nameEdit.slot) end
    end
  end
  -- an up / down trap holds the focus with no editor open (a stale rule): back on the row
  if not nameEdit and ((U.ok(O.trapU) and ui.hasFocus(O.trapU, p1)) or (U.ok(O.trapD) and ui.hasFocus(O.trapD, p1))) then
    local id = (V2.optLast and U.ok(St.ui.rows[V2.optLast])) and V2.optLast or nav.idx
    if id then focusRow(id) end
  end
  -- pad left / right on a value row: CommonUI moved P1's focus onto a focus trap -> step that row, focus back on it
  local trap = nil
  if nameEdit then
    trap = nil                                         -- the editor took the left / right traps above
  elseif ui.hasFocus(O.trapL, p1) then trap = -1 elseif ui.hasFocus(O.trapR, p1) then trap = 1 end
  if trap then
    local id = (V2.optLast and U.ok(St.ui.rows[V2.optLast])) and V2.optLast or nav.idx
    if id and not covered and p1PadInput() and now - V2.lrAtMs > 300 then
      V2.lrAtMs = now
      U.logOnce("lobby.trap", TAG, "OPTIONS: pad %s on '%s' through the focus trap (V-FIN-04)",
        trap < 0 and "left" or "right", tostring(id))
      activate(id, trap)
    end
    if id then focusRow(id) end
  end
  -- one painted look: the hovered row, else the focused one, else the poll's cursor; none while BACK is focused or
  -- hovered (the command row paints it)
  local focused, hovered
  for _, id in ipairs(navList()) do
    local w = St.ui.rows[id]
    if not hovered and ui.hovered(w) then hovered = id end
    if not focused and ui.hasFocus(w, p1) then focused = id end
  end
  if focused then V2.optLast, nav.idx = focused, focused end   -- the cursor follows CommonUI (LobbyPadNav off too)
  -- #98: the delete confirm holds only while the window runs and P1's focus stays where it was when it armed (the
  -- delete row for the pad; a mouse click may arm it with the focus elsewhere)
  if lobby.CD.untilMs > 0 then
    local f = focused or "-"
    if lobby.CD.focusId == nil then lobby.CD.focusId = f end
    local why = (not lobby.CD.armed() and "window over") or (f ~= lobby.CD.focusId and ("focus moved to " .. f)) or nil
    if why then
      lobby.CD.disarm(why)
      say("COUCH PROGRESS KEPT")                       -- replaces the "PRESS (A) AGAIN" pill
    end
  end
  local back = O.cmd and O.cmd.poll(p1) or nil
  paintRows((back == nil) and (hovered or focused or nav.idx) or nil)
end

v2Tick = function()
  -- 0.12.0 (review ui-1): the page check pollNav has (a freed page after a travel), and no work in the launch hold
  if not V2.active or St.menu.visible ~= "lobby" or St.launchHold() or not U.ok(St.menu.lobby) then return end
  local now = St.nowMs()
  if V2.pill then V2.pill.tick(now) end                -- expires transients, drains theme's texture queue
  if setupActive() then return end
  local p1 = U.p1()
  if V2.mode == "options" then optionsTick(p1, now) else tilesTick(p1, now) end
end

v2Refresh = function()
  U.try(TAG, refreshAgain)                             -- first: the chosen race's facts (V2.againView)
  U.try(TAG, refreshModes)
  U.try(TAG, refreshGalaxy)
  U.try(TAG, refreshPads)
  U.try(TAG, refreshOptionsTile)
  U.try(TAG, refreshStrip)
  if V2.opt then U.try(TAG, refreshOptionsPage) end
end

---------------------------------------------------------------------------------------------------- public v2 API
-- OPTIONS tile (A) / test helper: the OPTIONS sub-page over the tiles (§5.1). false on the classic page (its rows are
-- the options), while the RACE SETUP is open, or when the page cannot be built.
function lobby.openOptions()
  if not V2.active then
    U.dbg(TAG, "openOptions: the classic lobby keeps its option rows on the page (UiStyle = classic)")
    return false
  end
  if setupActive() then return false end
  if V2.mode == "options" then return true end
  if not (V2.opt and U.ok(V2.opt.cv)) then
    V2.opt = nil
    local ok = U.try(TAG, buildOptions)
    if not (ok and V2.opt) then
      V2.opt = nil
      say("OPTIONS COULD NOT BE SHOWN (SEE LOG)", true)
      return false
    end
  end
  V2.mode = "options"
  showW(V2.tilesCv, false)
  showW(V2.opt.cv, true)
  nav.primed = false
  nav.idx = (V2.optLast and U.ok(St.ui.rows[V2.optLast])) and V2.optLast or "layout"
  V2.bPrev, V2.wasCovered = true, false                -- the press that opened OPTIONS is no B edge
  V2.opt.painted = nil
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)
  U.try(TAG, updateDetail, nav.idx)                    -- the help of the row about to take the focus, at once
  if St.menu.visible == "lobby" then
    focusRow(nav.idx)
    lobby.armFocusKeeper("options")
  end
  U.log(TAG, "OPTIONS opened (network %s, focus '%s')", netMode(), tostring(nav.idx))
  return true
end

-- backprompt.lua: is the v2 OPTIONS sub-page showing (on the shown lobby)?
function lobby.optionsOpen()
  return V2.active == true and V2.mode == "options" and St.menu.visible == "lobby"
end

-- BACK / P1's B / Backspace / a tab change / lobby.debugOptions(false): the tiles again, focus on the OPTIONS tile.
function lobby.closeOptions(why)
  if not (V2.active and V2.mode == "options") then return false end
  leaveOptions()
  nav.idx = "options"
  St.ui.dirty = true
  if St.menu.visible == "lobby" and not setupActive() then
    U.try(TAG, lobby.refresh)
    focusRow("options")
    lobby.armFocusKeeper("options")
  end
  U.log(TAG, "OPTIONS closed (%s): the tiles are back, focus on the OPTIONS tile (V-FIN-15)", tostring(why or "?"))
  return true
end

-- OPTIONS > PLAYER NAMES ---------------------------------------------------------------------------------------------
-- The sub-list over the OPTIONS rows (O.sub = "names"): P1's B, Backspace and BACK return to the OPTIONS list.
local function showSub(name)
  local O = V2.opt
  if not O then return false end
  O.sub = name
  showW(O.listCv, name == nil)
  showW(O.namesCv, name == "names")
  if O.couchCv then showW(O.couchCv, name == "couch") end
  if O.painted and O.rows[O.painted] then O.rows[O.painted].set({ focused = false }) end
  O.painted = nil
  relinkOptions()
  return true
end

function lobby.openNames()
  local O = V2.opt
  if not (V2.active and V2.mode == "options" and O and U.ok(O.namesCv)) then
    U.dbg(TAG, "openNames: only from the v2 OPTIONS page")
    return false
  end
  if O.sub == "names" then return true end
  showSub("names")
  nav.idx, V2.optLast = "name1", "name1"
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)
  U.try(TAG, updateDetail, "name1")
  if St.menu.visible == "lobby" then
    focusRow("name1")
    lobby.armFocusKeeper("names")
  end
  U.log(TAG, "PLAYER NAMES opened (%s)", namesSummary())
  return true
end

function lobby.closeNames(why)
  local O = V2.opt
  if not (O and O.sub == "names") then return false end
  if nameEdit then lobby.endNameEdit("cancel") end
  showSub(nil)
  nav.idx, V2.optLast = "names", "names"
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)
  if St.menu.visible == "lobby" and V2.mode == "options" then
    focusRow("names")
    lobby.armFocusKeeper("names closed")
  end
  U.log(TAG, "PLAYER NAMES closed (%s)", tostring(why or "?"))
  return true
end

-- couch-fix39: OPTIONS > PLAYERS > Couch campaign = the COUCH CAMPAIGN sub-list (B / Backspace / BACK return)
function lobby.openCouch()
  local O = V2.opt
  if not (V2.active and V2.mode == "options" and O and U.ok(O.couchCv)) then
    U.dbg(TAG, "openCouch: only from the v2 OPTIONS page")
    return false
  end
  if O.sub == "couch" then return true end
  local first = lobby.SUBS.couch.first
  showSub("couch")
  nav.idx, V2.optLast = first, first
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)
  U.try(TAG, updateDetail, first)
  if St.menu.visible == "lobby" then
    focusRow(first)
    lobby.armFocusKeeper("couch")
  end
  U.log(TAG, "COUCH CAMPAIGN opened (team mystery choices %s)", tostring(settings.get("CouchMysteryTeam")))
  return true
end

function lobby.closeCouch(why)
  local O = V2.opt
  if not (O and O.sub == "couch") then return false end
  showSub(nil)
  nav.idx, V2.optLast = "couch", "couch"
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)
  if St.menu.visible == "lobby" and V2.mode == "options" then
    focusRow("couch")
    lobby.armFocusKeeper("couch closed")
  end
  U.log(TAG, "COUCH CAMPAIGN closed (%s)", tostring(why or "?"))
  return true
end

-- the open sub-list back to the OPTIONS list
function lobby.closeSub(why)
  local O = V2.opt
  if O and O.sub == "couch" then return lobby.closeCouch(why) end
  return lobby.closeNames(why)
end

local function nameRefresh()
  St.ui.dirty = true
  if V2.opt then
    U.try(TAG, refreshOptionsPage)
    if nameEdit then U.try(TAG, updateDetail, "name" .. nameEdit.slot) end
  end
end

-- A on a name row: open its editor; A on the row being edited keeps the name (a click on another row keeps the
-- edited one and opens that row's editor).
function lobby.onName(n)
  n = math.tointeger(tonumber(n))
  if not n or n < 1 or n > 4 then return end
  if nameEdit then
    local same = nameEdit.slot == n
    lobby.endNameEdit("keep")
    if same then return end
  end
  local def = defaultName(n)
  nameEdit = { slot = n, def = def, e = NE.new(customName(n) or def, cfg.PlayerNameMaxChars) }
  V2.xPrev = true                                      -- a held X is no delete
  V2.lrAtMs = St.nowMs()
  U.try(TAG, relinkOptions)                            -- the row's four directions -> the focus traps
  nameRefresh()
  if St.menu.visible == "lobby" then focusRow("name" .. n) end
  U.log(TAG, "P%d's name: editor open on '%s'", n, NE.text(nameEdit.e))
end

-- how = "keep" (A / Enter / a click on another row) | "cancel" (B, leaving OPTIONS, the page rebuilt).
function lobby.endNameEdit(how)
  local ed = nameEdit
  if not ed then return false end
  nameEdit = nil
  if how == "keep" then
    local text = NE.text(ed.e)
    -- the default typed again (the editor writes upper case): no custom name, the default keeps its own spelling
    local stored = (string.upper(text) == string.upper(tostring(ed.def or ""))) and "" or text
    local okS, why = settings.set("Name" .. ed.slot, stored)
    if okS == false then
      say("P" .. ed.slot .. " NAME REFUSED (" .. string.upper(tostring(why)) .. ")", true)
    elseif stored == "" then
      say("P" .. ed.slot .. " USES THE DEFAULT NAME")
    else
      say("P" .. ed.slot .. " IS NOW " .. string.upper(stored))
    end
  else
    U.log(TAG, "P%d's name edit cancelled (kept '%s')", ed.slot, tostring(customName(ed.slot) or "default"))
  end
  if V2.opt then
    U.try(TAG, relinkOptions)                          -- the row's own up / down chain back
    if St.menu.visible == "lobby" and V2.mode == "options" and V2.opt.sub == "names" then
      focusRow("name" .. ed.slot)
    end
  end
  nameRefresh()
  return true
end

-- One editor key: "up" | "down" (letter), "left" | "right" (cursor), "delete" (pad X), "back2" (Backspace). slot:
-- only that slot's editor (the LR row actions name theirs).
function lobby.nameEditKey(key, slot)
  local ed = nameEdit
  if not ed or (slot ~= nil and slot ~= ed.slot) then return false end
  if key == "up" then NE.step(ed.e, 1)
  elseif key == "down" then NE.step(ed.e, -1)
  elseif key == "left" then NE.move(ed.e, -1)
  elseif key == "right" then NE.move(ed.e, 1)
  elseif key == "delete" then NE.delete(ed.e)
  elseif key == "back2" then NE.backspace(ed.e)
  else return false end
  nameRefresh()
  return true
end

-- One step back on the OPTIONS page (P1's B; backprompt.lua when the game's Quit prompt took that B): the name being
-- edited gets its old text back, else PLAYER NAMES returns to the OPTIONS list, else OPTIONS closes.
function lobby.optionsBack(why)
  if not (V2.active and V2.mode == "options") then return false end
  if nameEdit then
    U.log(TAG, "%s: P%d's name edit cancelled", tostring(why), nameEdit.slot)
    return lobby.endNameEdit("cancel")
  end
  if V2.opt and V2.opt.sub then return lobby.closeSub(why) end
  U.log(TAG, "%s: OPTIONS closed, the next accept is guarded (V-FIN-15)", tostring(why))
  return lobby.closeOptions(why)
end

-- when P1's B last stepped back on the OPTIONS page (optionsTick's edge poll; backprompt.lua skips its own step then)
function lobby.lastP1BackMs() return V2.backMs or -1e12 end

-- test helper / diag: the editor state (nil when closed)
function lobby.nameEditState()
  if not nameEdit then return nil end
  return { slot = nameEdit.slot, text = NE.text(nameEdit.e), shown = NE.render(nameEdit.e), cur = nameEdit.e.cur }
end

-- One line for diag / test.cmd: page style, mode, painted tile / row, cursor, canvas shift, strip cells, START state.
function lobby.status()
  if not V2.active then
    local what = "classic rows"
    if V2.style == nil then what = "no page yet" elseif V2.style == "v2" then what = "classic rows (the v2 build failed)" end
    return string.format("lobby: %s (UiStyle %s)", what, tostring(opt("UiStyle", "v2")))
  end
  local cells = {}
  for i, c in ipairs((V2.strip or {}).cells or {}) do
    cells[i] = tostring(c.kind or "?") .. (c.headOn and "+head" or "")
  end
  return table.concat({
    "lobby: v2 " .. V2.mode,
    "painted " .. tostring((V2.mode == "options") and (V2.opt and V2.opt.painted) or V2.painted),
    "cursor " .. tostring(nav.idx),
    string.format("shift %d,%d", V2.shift[1], V2.shift[2]),
    "strip " .. ((#cells > 0) and table.concat(cells, ",") or "not built"),
    "start " .. tostring(V2.startState and V2.startState.kind or "?"),
    "options " .. (V2.opt and "built" or "not built") .. ((V2.opt and V2.opt.sub) and (" / " .. V2.opt.sub) or "")
      .. (nameEdit and string.format(" (editing P%d)", nameEdit.slot) or ""),
    string.format("head MIDs %d%s", HEAD.mids, HEAD.broken and " (plain heads)" or ""),
    "net '" .. tostring(lastNetText or "") .. "'",
  }, " | ")
end

-- Test helper (test.cmd lua): step 1 builds theme's glyph-calibration texts on the tiles canvas, step 2 (a few ticks
-- later) returns the measured advances (theme.calibrateRead). Debug only.
local CALIB = nil
function lobby.debugCalibrate(step, roles)
  if not (V2.active and V2.ctx and U.ok(V2.tilesCv)) then return "no v2 lobby page" end
  if step == 1 then
    CALIB = theme().calibrate(V2.ctx, V2.tilesCv, roles or { "stepLabel", "rowLabel", "body", "rowValue" })
    return "calibration texts built"
  end
  if not CALIB then return "run step 1 first" end
  return theme().calibrateRead(CALIB)
end

-- Test helper (test.cmd lua, spec §13 session A): on (default true) opens OPTIONS, false closes it. -> a summary.
-- Example: lua return require("lobby").debugOptions(true)
function lobby.debugOptions(on)
  if on == nil then on = true end
  local ok
  if on then ok = lobby.openOptions() else ok = lobby.closeOptions("debug") end
  return string.format("debugOptions(%s): %s | %s", tostring(on), ok and "ok" or "no change", lobby.status())
end

---------------------------------------------------------------------------------------------------
-- RACE SETUP mode (setup.open / setup.close): the lobby rows are collapsed while the setup panel is shown.
---------------------------------------------------------------------------------------------------
-- returnTo (fix16): the tile that opened the page gets the focus back when it closes (the GRAND PRIX page: "galaxy",
-- its poster; without it the mode tile = QUICK RACE took it, live 2026-10-15)
function lobby.setSetupMode(on, returnTo)
  if V2.active then                                    -- 0.12.0 v2: the whole page canvas (tiles, strip, pill, OPTIONS)
    if on and V2.mode == "options" then leaveOptions() end   -- the setup opened over OPTIONS (debugJump)
    showW(V2.canvas, not on)
    nav.primed = false
    V2.sPrev, V2.sArmed = true, false                  -- 0.13.0: RACE SETUP's Start is no START of the page
    if not on then
      St.ui.dirty = true
      V2.painted = nil
      U.try(TAG, lobby.refresh)
      if St.menu.visible == "lobby" then
        nav.idx = (V2.mode == "tiles") and modeTile() or nav.idx   -- 0.13.0: the poster of the mode START plays
        if returnTo and V2.mode == "tiles" and U.ok(St.ui.rows[returnTo]) then nav.idx = returnTo end
        U.try(TAG, lobby.focusFirst)
        lobby.armFocusKeeper("race setup closed")
      end
    end
    return
  end
  for _, id in ipairs(ROW_ORDER) do
    local w = St.ui.rows[id]
    if U.ok(w) then
      U.try(TAG, function() U.mod("ui").setShown(w, not on) end)
    end
  end
  St.ui.shown = {}                                    -- refresh() re-decides remote / netact from scratch
  nav.primed = false
  if not on then
    St.ui.dirty = true
    U.try(TAG, lobby.refresh)
    if St.menu.visible == "lobby" then
      nav.idx = "race"
      U.try(TAG, lobby.focusFirst)
      lobby.armFocusKeeper("race setup closed")
    end
  end
end

return lobby
