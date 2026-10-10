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
--   * four painted posters (theme.poster): the RACE event card (the chosen track's Arcade tile from setup.raceArt),
--     START RACE (T_UI_FE_Tile_03), PLAYERS (T_UI_FE_Tiles_MP_Custom_01) and OPTIONS (T_UI_Difficulty_Tile_04), each
--     over an invisible ghost button (theme.ghost = ui.ghost) that keeps its ROW_ORDER id ("race", "start", "pads"; new
--     "options"), so St.ui.rows, refresh, focusedId, activate and ui.pollClicks work as before. The painted focus look
--     follows the ghosts' CommonUI focus / mouse hover every FAST tick (v2Tick, run from lobby.keepFocus);
--   * tile states (§4.2): START locked with its reason (C11; still focusable, A posts the reason as a RUST warn pill)
--     or "Launching…"; PLAYERS with the RUST "Press again to confirm" badge of the 2-press opt-in, locked while the
--     player set is frozen;
--   * the players strip (§4.3: join.slotStates; heads from racers.lastPilotThumb through an
--     M_UI_CharacterProfilePicture MID) and, while NETWORK is not OFFLINE, the network line (§4.4, net.statusText);
--     a change of that text is posted once to the pill;
--   * lobby messages (the "status" event) in theme's status pill (§4.5: 5 s; refusals and errors in the warn variant);
--   * OPTIONS (§5): a sub-page of the same page (lobby.openOptions / closeOptions; built at its first open, after the
--     page geometry was measured): hub background, "/OPTIONS" title, the §5.2 rows (theme.settingsRow; LABEL[id]() ->
--     label, value, kind, on), the help / "Default value" detail column, BACK in the command row, the back route (P1's
--     pad B edge, Backspace, BACK, a tab change; armBackGuard for the game's Exit prompt), list navigation (explicit
--     up / down chain, pad left / right through two invisible focus traps, keyboard left / right through onKey).
-- UiStyle = "classic" (and a v2 page that cannot be built) keeps the 0.11.0 rows below unchanged.
-- VERIFY ids (spec §14): V-FIN-01 (page origin measured at the show vs the build), V-FIN-04 (ghost focus, explicit
-- navigation, clicks, focus traps), V-FIN-12 (the pill, theme.lua), V-FIN-15 (OPTIONS back route).

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
local TILE_IDS = {"race", "start", "pads", "options"}                 -- the lobby ghosts (tiles mode, §4.6)
local OPT_IDS = {"layout", "gfx", "takedown", "tags", "kbp1", "net", "netact", "adv"}   -- OPTIONS list (§5.3)
local RIGHT_COLUMN = {start = true, pads = true, options = true}

-- One page instance (lobby.resetNav replaces it: the widgets die with their page). style: the UiStyle the page was
-- built for ("v2" | "classic"; a v2 build that failed falls back to the rows and keeps "v2", so no rebuild loop);
-- active: the v2 canvas is up; mode: "tiles" | "options"; geo: the page geometry the content was placed with (screen
-- su; theme's builders convert with it), geoNow: the latest measurement, shift: the canvas render translation that
-- corrects the difference (alignCanvas, V-FIN-01); posters / race / badge / strip / pill / opt: theme elements;
-- painted: the tile with the focus look; lastRight: the right-column tile focused last (race -> right, §4.6); sig:
-- refresh signatures; ghostKeys: registry keys of our ghosts (dropped when the v2 build fails); bPrev / wasCovered:
-- the OPTIONS back route's B edge; lrAtMs: last left / right step (a focus trap skips a second step of one press).
local function newV2()
  return { style = nil, active = false, mode = "tiles", ctx = nil, root = nil, geo = nil, geoNow = nil,
           shift = {0, 0}, canvas = nil, tilesCv = nil, posters = {}, race = {}, badge = {}, badgeOn = false,
           strip = nil, pill = nil, opt = nil, painted = nil, lastRight = "start", sig = {}, ghostKeys = {},
           bPrev = true, wasCovered = false, lrAtMs = -1e9, optLast = nil, headWait = false, focusSeen = false,
           raceRacers = nil, startState = nil, fitIn = nil, fitOut = nil }
end
local V2 = newV2()

local padsConfirmUntilMs = 0     -- ADD PLAYERS 2-press window (lobby.onPads); the v2 PLAYERS badge shows meanwhile
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
local function say(text, warn)
  pendingLevel = {text = tostring(text or ""), warn = warn == true}
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
}

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
}

-- 0.12.0 v2 START tile: locked = A posts the reason as a warn pill (the tile keeps the focus); launching = A ignored.
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
  -- review fix (task #14): a guest's A can also click P1's CommonUI focus, and START is the v2 default focus (§4.6;
  -- 0.11.0 focused RACE, where the leak only opened RACE SETUP): a click within CardGuestClickGuardMs of a guest pad's
  -- A is that guest's join / press, not P1's START (racers.lua's V-RC-07 guard on P1's sink)
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

-- Actions of the v2 page that differ from the rows' (resolved per call: a page may change style after a rebuild).
local V2_ACTIONS = {start = startTile}
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

-- v2 default focus (§4.6): START with a valid race, else RACE.
local function desiredFocusV2()
  local w = St.ui.rows[validChoice() and "start" or "race"]
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
  local p = V2.posters and V2.posters.start
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
    U.log(TAG, "lobby page built (UI v2: 4 posters over the ghosts race / start / pads / options, players strip, "
      .. "status pill; OPTIONS is built at its first open) (V-FIN-04)")
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
    if lv and lv.text == St.ui.statusText then warn = lv.warn else warn = isWarnText(St.ui.statusText) end
    if St.ui.statusText == "" then
      V2.pill.post("", {})
    else
      V2.pill.post(St.ui.statusText, {warn = warn})
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
-- within 5 s enables the pads (join.enablePads). Once on, the row only repeats how to turn them off.
-- 0.12.0 v2: the PLAYERS tile (its RUST "Press again to confirm" badge shows during the window, v2Tick).
function lobby.onPads()
  local join = U.mod("join")
  if join.padsEnabled() then
    say("PADS STAY ON UNTIL THE GAME RESTARTS (RESTART BEFORE ONLINE PLAY)", false)
  elseif join.isFrozen() or isClient() or St.net.connecting then
    say("DISCONNECT TO CHANGE PLAYERS", true)
  else
    local now = St.nowMs()
    if now > padsConfirmUntilMs then
      padsConfirmUntilMs = now + 5000
      if V2.active then
        say("PADS STAY ON UNTIL THE GAME RESTARTS. NOT FOR ONLINE PLAY: PRESS (A) AGAIN", false)   -- §4.2
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
function lobby.onRace()
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
  U.mod("launch").start()
  St.ui.dirty = true
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
}

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
  if V2.active then return (V2.mode == "options") and OPT_IDS or TILE_IDS end
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

-- First row to focus when nothing is chosen yet: v2 tiles START with a valid race, else RACE (§4.6); else the first.
local function defaultIdx(list)
  if V2.active and V2.mode == "tiles" then
    local d = validChoice() and "start" or "race"
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
-- nil (always nil in classic and in tiles mode).
local function heldExtra(p1)
  if not (V2.active and V2.mode == "options" and V2.opt) then return nil end
  local O, ui = V2.opt, U.mod("ui")
  local back = O.cmd and O.cmd.widget("back")
  if U.ok(back) and ui.hasFocus(back, p1) then return "back" end
  if ui.hasFocus(O.trapL, p1) or ui.hasFocus(O.trapR, p1) then return "trap" end
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
  nav.idx, nav.hl, nav.primed, nav.lastFocus = nil, nil, false, nil
  nav.covered, nav.coverWhy, nav.layerBase, nav.backGuard, nav.consumed, nav.seenAct = false, nil, nil, false, nil, {}
  nav.keep.untilMs = 0
  St.ui.baseTexts = {}
  V2 = newV2()                                        -- 0.12.0: the v2 page state belongs to the page
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
    local ok, n = pcall(function() return mgr:GetWidgetCountInLayer(layer) end)   -- (Enum layer) -> Int
    if not ok or type(n) ~= "number" then return nil end
    out[i] = n
  end
  return out
end

-- An activation flag counts only after it was seen true since the page was shown (nav.seenAct): a widget whose
-- IsActivated() never reads true (not on a CommonUI stack) must not disable the lobby input for good.
local function deactivated(w, key)
  if not U.ok(w) then return false end
  local ok, a = pcall(function() return w:IsActivated() end)       -- UCommonActivatableWidget::IsActivated() -> Bool
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
    local ok, w = pcall(function() return bw[name] end)
    if ok and U.ok(w) then return w end
  end
  return nil
end

local function builderFocused(bw, p1)
  if not U.ok(p1) then return false end
  local ok, v = pcall(function() return bw:HasUserFocusedDescendants(p1) end)   -- UWidget (Object) -> Bool
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
-- "@right" = the right-column tile focused last.
local GRAPH = { race = { right = "@right" }, start = { down = "pads", left = "race" },
                pads = { up = "start", down = "options", left = "race" }, options = { up = "pads", left = "race" } }
local function graphMove(id, dir)
  local e = GRAPH[id or ""]
  local t = e and e[dir]
  if t == "@right" then t = V2.lastRight or "start" end
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
  if St.menu.visible ~= "lobby" or not U.ok(St.menu.lobby) then nav.primed = false; return end
  if checkCovered() then nav.primed = false; return end
  if setupActive() then
    nav.primed = false                                 -- a fresh baseline when the lobby rows come back
    U.mod("setup").pollNav()
    return
  end
  local p1 = U.p1()
  if not U.ok(p1) then return end
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
  if step ~= 0 and not focusMoved and not held then
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
  if setupActive() then
    U.mod("setup").onKey(name)
    return
  end
  local options = V2.active and V2.mode == "options"
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
-- Tile rects, screen su (spec §4.2; the mockup's LOBBY table, final/py/screens.py).
local TILE = { race = {128, 345, 1030, 1170}, start = {1203, 345, 1005, 420}, pads = {1203, 810, 1005, 330},
               options = {1203, 1185, 1005, 330} }
-- Event-card texts on the RACE poster, poster-local su (mockup event_card): the planet line at 70.5 % of the height,
-- the caption 70 below it, the track name 110 below it (posterTitle 54, 2 lines, wrap 902), the footer's baseline 56
-- above the bottom (box bottom = baseline + Overpass's descent 0.383 em), the focus kicker at the top.
local RACE_TXT = { x = 64, kicker = 70, planet = 825, caption = 895, name = 935, wrap = 902, footBottom = 1128 }
-- Players strip (§4.3): white @0.42 RoundedBox r 21; 270 tall, 330 with the network line; cells at x 164 + 502 i;
-- content top = strip top + 73 (offline) / + 34 (network line). Text boxes are placed by their top = baseline - the
-- face's ascent (Moki 0.826 em, Overpass 0.883 em; em = size x 4/3).
local STRIP = { x = 128, y = 1560, w = 2080, h = 270, hNet = 330, top = 73, topNet = 34, cell = 164, pitch = 502,
                ruleX0 = 164, ruleX1 = 2172, netTextX = 438, netTextW = 1700 }
local TXA = "/Game/Griffin/UI/Library/Textures/Content/Arcade/"
-- setup.raceArt fallback (setup.lua changes in parallel): the class's CLASS-step poster tile (spec §7.1)
local CLASS_TILE = { Car = "Mas_Car", Bike = "Dal_Bike", Skimmer = "Cor_Skimmer", Plane = "Spa_Plane" }
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

---------------------------------------------------------------------------------------------------- RACE card data
local function facing(o)
  if not U.ok(o) then return "" end
  local ok, t = pcall(function() return U.str(o.PlayerFacingName) end)
  if ok and type(t) == "string" and t ~= "" then return string.upper(t) end
  local ok2, n = pcall(function() return o:GetFName():ToString() end)
  if ok2 and type(n) == "string" then return string.upper(n) end
  return ""
end

-- setup.raceArt(choice) (WI-05: the track's Arcade tile, else the planet x class tile), else the class's fixed tile.
local function raceArt(c, cls)
  local ok, p = pcall(function()
    local S = U.mod("setup")
    if type(S.raceArt) == "function" then return S.raceArt(c) end
    return nil
  end)
  if ok and type(p) == "string" and p ~= "" then return p end
  U.logOnce("lobby.raceArt", TAG, "setup.raceArt %s: the RACE card shows the class's fixed Arcade tile",
    ok and "not available" or ("failed (" .. tostring(p) .. ")"))
  local k = cls and CLASS_TILE[cls.key]
  if k then return TXA .. "T_UI_Arcade_" .. k .. "_Tile.T_UI_Arcade_" .. k .. "_Tile" end
  return nil
end

-- The RACE event card's facts for choice c (§4.2): planet line + tone, "LANDSPEEDER · RACE", the track name, the
-- footer "REVERSE · SUNSET · 12 RACERS", the art; racers = the grid size when known (START's kicker).
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
  v.art = raceArt(c, cls)
  return v
end

---------------------------------------------------------------------------------------------------- build
local function buildRaceTexts()
  local T, ctx, R = theme(), V2.ctx, V2.race
  local rc, x = V2.posters.race.cv, RACE_TXT.x
  R.kicker = T.text(ctx, rc, "posterKicker", { text = "Change race", rect = { x, RACE_TXT.kicker }, z = 5,
                                               visible = false })
  R.planet = T.text(ctx, rc, "planetLine", { rect = { x, RACE_TXT.planet }, z = 5, visible = false })
  R.caption = T.text(ctx, rc, "artCaption", { rect = { x, RACE_TXT.caption }, z = 5, visible = false })
  R.name = T.text(ctx, rc, "posterTitle", { size = 54, colour = T.COL.WHITE, wrapW = RACE_TXT.wrap,
                                           rect = { x, RACE_TXT.name }, z = 5, visible = false })
  R.footer = T.text(ctx, rc, "artCaption", { align = { 0, 1 }, rect = { x, RACE_TXT.footBottom }, z = 5,
                                             visible = false })
end

-- PLAYERS "Press again to confirm" (§4.2): MI_UI_Pill_Generic RUST + Overpass Medium Italic 30 WHITE, top-right
-- inset 24.
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

-- Explicit navigation of the §4.6 graph on the four ghosts (CommonUI would move geometrically; RACE -> right must be
-- START or the right-column tile focused last, tilesTick keeps that rule current). VERIFY(V-FIN-04).
local function linkTiles()
  local T, r = theme(), St.ui.rows
  local n = 0
  local function link(a, dir, b) if T.nav(r[a], dir, r[b]) then n = n + 1 end end
  link("race", "right", "start")
  link("start", "left", "race"); link("start", "down", "pads")
  link("pads", "left", "race"); link("pads", "up", "start"); link("pads", "down", "options")
  link("options", "left", "race"); link("options", "up", "pads")
  U.log(TAG, "tile navigation: %d of 8 explicit rule(s) of the §4.6 graph on the ghosts (V-FIN-04)", n)
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
  poster("race", { titleSize = 54, ax = 0.5, ay = 0.92 })
  poster("start", { art = T.TEX.LobbyStart, ax = 0.5, ay = 0.08, title = "START RACE", titleSize = 69 })
  poster("pads", { art = T.TEX.LobbyPlayers, ax = 0.5, ay = 0.36, title = "ADD PLAYERS", titleSize = 60 })
  poster("options", { art = T.TEX.LobbyOptions, ax = 0.5, ay = 0.62, title = "OPTIONS", titleSize = 60 })
  buildRaceTexts()
  U.try(TAG, buildBadge)
  for _, id in ipairs(TILE_IDS) do
    local w = T.ghost(ctx, V2.tilesCv, TILE[id], id, ghostFn(id), { geo = V2.geo })
    if not U.ok(w) then error("ghost '" .. id .. "' not created") end
    noteGhost(w)
    St.ui.rows[id] = w
  end
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
local function refreshRace()
  local T = theme()
  local p = V2.posters.race
  if not p then return end
  local valid = validChoice()
  local c = valid and St.race.choice or nil
  local key = valid and (tostring(c) .. "|" .. tostring(c.label)) or "none"
  if V2.sig.race == key then return end
  V2.sig.race = key
  local R = V2.race
  R.valid = valid
  if not valid then
    V2.raceRacers = nil
    p.set({ art = T.TEX.ScenarioEmpty, ax = 0.5, ay = 0.5, title = "CHOOSE RACE",
            kicker = "Class, planet, track, mode" })
    for _, e in ipairs({ R.planet, R.caption, R.name, R.footer, R.kicker }) do T.set(e, { visible = false }) end
    return
  end
  local v = raceView(c)
  V2.raceRacers = v.racers
  p.set({ art = v.art or T.TEX.ScenarioEmpty, ax = 0.5, ay = v.art and 0.92 or 0.5, title = "", kicker = "" })
  T.set(R.planet, { text = v.planet, colour = v.tone, visible = v.planet ~= "" })
  T.set(R.caption, { text = v.caption, visible = v.caption ~= "" })
  T.set(R.name, { text = v.track, visible = v.track ~= "" })
  T.set(R.footer, { text = v.footer, visible = v.footer ~= "" })
  T.set(R.kicker, { visible = V2.painted == "race" })
  U.dbg(TAG, "RACE card: %s | %s | %s | %s | art %s", v.planet, v.caption, v.track, v.footer, tostring(v.art))
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

local function refreshStart()
  local p = V2.posters.start
  if not p then return end
  local st = startStateV2()
  V2.startState = st
  local launching = st.kind == "launching"
  local kicker = launching and ("Launching" .. ELLIPSIS) or startKicker()
  local sig = st.kind .. "|" .. kicker
  if V2.sig.start == sig then return end
  V2.sig.start = sig
  p.set({ kicker = kicker, kickerAlways = launching, dim = launching and 0.5 or 1, lock = st.lock or false })
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
  p.set({ title = on and "PADS ON" or "ADD PLAYERS",
          kicker = on and "Until the game restarts" or (range and ("Join with " .. range) or ""),
          desc = "Pads stay on until the game restarts.",
          lock = refused and "Disconnect to change players" or false })
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
  local T = theme()
  local out = s
  if T.textWidth(s, "value", 30) > maxW then
    local cut = s
    out = ELLIPSIS
    while #cut > 0 do
      local shorter = (cut:gsub("[\0-\127\194-\244][\128-\191]*$", ""))   -- drop the last UTF-8 character
      -- review fix: a string ending in an invalid UTF-8 byte (0xC0, 0xC1, 0xF5-0xFF, a lone continuation byte: a
      -- Latin-1 JoinAddress in net.statusText) matches nothing above, and this loop never ended (a game-thread hang)
      if #shorter >= #cut then shorter = cut:sub(1, -2) end
      cut = shorter
      local try = (cut:gsub("[%s%p]+$", "")) .. ELLIPSIS
      if T.textWidth(try, "value", 30) <= maxW then
        out = try
        break
      end
    end
  end
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
  T.set(c.pad, { text = tostring(st.pad or ("PAD " .. pnum)), colour = ink, rect = LP(tx, top + 3) })
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
-- §5.1 / §5.2: groups from y 450 (header, first row 78 below its top, rows 96 tall at a pitch of 102, groups 36
-- apart), list x 128-2000, detail column at x 2190 (top 520, width 1430), BACK in the command row. The ADVANCED group
-- lives on its own canvas that moves one pitch up while the NETWORK action row is collapsed (offline).
local OPT_GROUPS = {
  { label = "SPLIT SCREEN", ids = {"layout", "gfx", "takedown", "tags"} },
  { label = "PLAYERS", ids = {"kbp1"} },
  { label = "NETWORK", ids = {"net", "netact"} },
  { label = "ADVANCED", ids = {"adv"}, shift = true },
}
local OPT = { x0 = 128, x1 = 2000, y0 = 450, first = 78, pitch = 102, h = 96, gap = 36, detailX = 2190, detailY = 520,
              detailW = 1430, trapL = {40, 100, 24, 24}, trapR = {72, 100, 24, 24} }
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
  tags = { def = "NameTags", body = "Show the P1-P4 tags over the human racers." },
  kbp1 = { def = "KeyboardIsP1", body = "P1 plays with the keyboard and every pad becomes a guest." },
  net = { def = "NetMode", body = function()          -- the remote status in full, then the two modes
    local s = netStatus()
    if s ~= "" then return richSafe(s) .. "\n" .. NET_HELP end
    return NET_HELP
  end },
  netact = { body = netStatus },
  adv = { body = "The game's own race builder, for any race this screen cannot make." },
}

-- The default value in words (config.Defaults, so the text follows a changed default).
local function defaultWord(key)
  local v = nil
  if type(cfg.Defaults) == "table" then v = cfg.Defaults[key] end
  if v == nil and type(cfg.DefaultsBuiltin) == "table" then v = cfg.DefaultsBuiltin[key] end
  if key == "Layout2P" then return LAYOUT_WORD[v] or tostring(v) end
  if key == "SplitGraphics" then return GFX_WORD[v] or tostring(v) end
  if key == "NetMode" then return NET_WORD[v] or tostring(v) end
  if type(v) == "boolean" then return v and "On" or "Off" end
  return tostring(v)
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
  local ok, t = pcall(function() return cis:GetCurrentInputType() end)   -- 0 MouseAndKeyboard, 1 Gamepad, 2 Touch
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
  O.detailId = id
  local sig = table.concat({ id, tostring(label), body, tostring(foot) }, "|")
  if O.detailSig == sig then return end
  O.detailSig = sig
  O.detail.set({ title = label, body = body, foot = foot and { foot } or {} })
end

-- Explicit navigation (V-FIN-04): up / down between the visible rows, the last row's down = BACK and BACK's up = the
-- last row, left / right of the value rows = the focus traps (CommonUI has no left / right on a row of its own).
local function relinkOptions()
  local O = V2.opt
  if not O then return end
  local T = theme()
  local vis = {}
  for _, id in ipairs(OPT_IDS) do
    local r = O.rows[id]
    if r and U.ok(r.ghost) and not (id == "netact" and O.actShown == false) then vis[#vis + 1] = id end
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
  for _, id in ipairs(OPT_IDS) do
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
  O.advCv = subCanvas(O.cv, 3)
  local y, nRows = OPT.y0, 0
  for _, grp in ipairs(OPT_GROUPS) do
    local cv = grp.shift and O.advCv or O.cv
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
  O.detail = T.detailColumn(ctx, O.cv, OPT.detailX, OPT.detailY, OPT.detailW, { geo = geo })   -- C12
  O.cmd = T.commandRow(ctx, O.cv, geo, { { id = "back", label = "BACK", ghostId = "opt:back",
                                           fn = function() lobby.closeOptions("BACK") end } })   -- C4
  if O.cmd then
    O.cmd.show({ back = true })
    noteGhost(O.cmd.widget("back"))
  end
  -- focus traps: invisible ghosts out of every geometric sweep, reached only through the value rows' explicit left /
  -- right rules; v2Tick steps the row and puts the focus back (setup's cycler trap)
  local noop = function() end
  O.trapL = T.ghost(ctx, O.cv, OPT.trapL, "opt:trapL", noop, { geo = geo })
  O.trapR = T.ghost(ctx, O.cv, OPT.trapR, "opt:trapR", noop, { geo = geo })
  noteGhost(O.trapL)
  noteGhost(O.trapR)
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
  V2.mode = "tiles"
  if O then
    if O.painted and O.rows[O.painted] then O.rows[O.painted].set({ focused = false }) end
    O.painted = nil
    showW(O.cv, false)
  end
  showW(V2.tilesCv, true)
  V2.painted = nil                                     -- the tiles repaint on the next tick
  nav.primed = false
end

---------------------------------------------------------------------------------------------------- FAST tick
local function paintTiles(painted)
  if V2.painted == painted then return end
  V2.painted = painted
  for id, p in pairs(V2.posters) do p.focus(id == painted) end
  theme().set(V2.race.kicker, { visible = painted == "race" and V2.race.valid == true })
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
  if focused and RIGHT_COLUMN[focused] and focused ~= V2.lastRight then
    V2.lastRight = focused
    theme().nav(St.ui.rows.race, "right", St.ui.rows[focused])   -- race -> the right-column tile focused last (§4.6)
  end
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
    U.log(TAG, "P1's B: OPTIONS closed, the next accept is guarded (V-FIN-15)")
    lobby.closeOptions("pad B")
    return
  end
  local covered = checkCovered()
  V2.wasCovered = covered
  -- pad left / right on a value row: CommonUI moved P1's focus onto a focus trap -> step that row, focus back on it
  local trap = nil
  if ui.hasFocus(O.trapL, p1) then trap = -1 elseif ui.hasFocus(O.trapR, p1) then trap = 1 end
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
  U.try(TAG, refreshRace)
  U.try(TAG, refreshStart)
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
    "options " .. (V2.opt and "built" or "not built"),
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
function lobby.setSetupMode(on)
  if V2.active then                                    -- 0.12.0 v2: the whole page canvas (tiles, strip, pill, OPTIONS)
    if on and V2.mode == "options" then leaveOptions() end   -- the setup opened over OPTIONS (debugJump)
    showW(V2.canvas, not on)
    nav.primed = false
    if not on then
      St.ui.dirty = true
      V2.painted = nil
      U.try(TAG, lobby.refresh)
      if St.menu.visible == "lobby" then
        nav.idx = "race"
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
