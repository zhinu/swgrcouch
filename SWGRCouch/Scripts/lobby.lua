-- lobby.lua (G3 Front-end UI): the Lobby page behind the SPLIT SCREEN tab: rows, labels, row actions.
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

-- Row order of §1.2 (ids are part of the contract: St.ui.rows[id]).
-- "pads" (2026-10-07): the ADD PLAYERS opt-in (join.enablePads); guests are never created by opening the tab.
local ROW_ORDER = {"hdr", "slot1", "slot2", "slot3", "slot4", "pads", "remote", "race", "adv", "layout", "gfx",
                   "takedown", "tags", "kbp1", "net", "netact", "start", "status"}

local GFX_TEXT = {auto = "AUTO", performance = "PERFORMANCE", quality = "QUALITY", off = "MY SETTINGS"}
local LAYOUT_TEXT = {["top-bottom"] = "TOP / BOTTOM", ["side-by-side"] = "SIDE BY SIDE"}

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

-- Texts of the static (settings) rows, §1.2.
local LABEL = {
  layout = function() return "2P LAYOUT: " .. (LAYOUT_TEXT[settings.get("Layout2P")] or "TOP / BOTTOM") end,
  gfx = function()
    local v = settings.get("SplitGraphics")
    return "SPLIT GRAPHICS: " .. (GFX_TEXT[v] or string.upper(tostring(v)))
  end,
  takedown = function() return "TAKEDOWN CAMERAS: " .. onOff(settings.get("TakedownCams")) end,
  tags = function() return "NAME TAGS: " .. onOff(settings.get("NameTags")) end,
  kbp1 = function() return "KEYBOARD IS P1: " .. onOff(settings.get("KeyboardIsP1")) end,
  net = function() return "NETWORK: " .. string.upper(netMode()) end,
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
    if new ~= "FRONTEND" and setupActive() then U.try(TAG, function() U.mod("setup").close("phase " .. tostring(new)) end) end
  end)
  for _, ev in ipairs({"players", "net", "race_chosen", "settings", "phase"}) do
    St.on(ev, TAG, markDirty)
  end
  -- A status line belongs to the world it was written in ("LOADING…" must not greet the post-race lobby). Cleared on
  -- the world change, i.e. before the FRONTEND listeners (join.resync, net.onFrontEnd) write the new one.
  St.on("world", TAG, function()
    St.ui.statusText = ""
    St.ui.dirty = true
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
}

-- Idempotent per menu instance (St.resetMenu() clears St.menu.lobby when a new menu is installed).
function lobby.build(menu)
  registerListeners()
  if U.ok(St.menu.lobby) then return St.menu.lobby end
  if not U.ok(menu) then return nil end
  local ui = U.mod("ui")
  local pc = menu:GetOwningPlayer()                   -- UWidget::GetOwningPlayer() -> Object
  local page = ui.make("SettingList", pc)
  if not page then
    status("SPLIT SCREEN PAGE COULD NOT BE CREATED")
    return nil
  end
  local root, why = pageRoot(page)
  if not root then
    U.err(TAG, "lobby root unusable: %s (LobbyRootMode=%s)", tostring(why), tostring(cfg.LobbyRootMode))
    St.emit("status", "LOBBY LAYOUT FAILED (SEE LOG)")
    return nil
  end

  St.ui.rows, St.ui.texts, St.ui.shown, St.ui.enabled = {}, {}, {}, {}
  lobby.resetNav()
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
  St.ui.dirty = true
  U.try(TAG, lobby.refresh)                           -- correct texts before the page is ever shown
  U.log(TAG, "lobby page built (%d rows)", #ROW_ORDER)
  return page
end

local lastRefreshMs = -1e9
local PERIODIC_REFRESH_MS = 2000   -- texts that age without an event (failure age, connection progress, pads)

-- MAIN loop, front end.
function lobby.tick()
  if not St.menu.visible then return end
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
    U.try(TAG, function() setRowText(id, LABEL[id]()) end)
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

function lobby.setStatus(text)
  St.ui.statusText = tostring(text or "")
  St.ui.dirty = true
  setRowText("status", St.ui.statusText)
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
local padsConfirmUntilMs = 0
function lobby.onPads()
  local join = U.mod("join")
  if join.padsEnabled() then
    status("PADS STAY ON UNTIL THE GAME RESTARTS (RESTART BEFORE ONLINE PLAY)")
  elseif join.isFrozen() or isClient() or St.net.connecting then
    status("DISCONNECT TO CHANGE PLAYERS")
  else
    local now = St.nowMs()
    if now > padsConfirmUntilMs then
      padsConfirmUntilMs = now + 5000
      status("PADS STAY ON UNTIL GAME RESTART, NOT FOR ONLINE PLAY: PRESS AGAIN TO ADD PLAYERS")
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
    status("DISCONNECT TO CHANGE PLAYERS")
  elseif #join.joinedList() > 0 then
    status("REMOVE GUESTS FIRST")
  else
    settings.toggle("KeyboardIsP1")
    U.mod("split").applyGamepadOffset()
    join.rebuild()
  end
  St.ui.dirty = true
end

function lobby.onNet(dir)
  if St.net.hosting then
    status("STOP HOSTING FIRST")
  elseif isClient() or St.net.connecting then
    status("DISCONNECT FIRST")
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

local function opt(name, default) return U.mod("ui").opt(name, default) end

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

-- Navigable rows in page order: our buttons that are not collapsed.
local function navList()
  local out = {}
  for _, id in ipairs(NAV_IDS) do
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
  local p = indexOf(NAV_IDS, id)
  if p then
    for i = p, 1, -1 do if indexOf(list, NAV_IDS[i]) then return NAV_IDS[i] end end
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

local function setHighlight(id)
  if nav.hl == id then return end
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
  local ui = U.mod("ui")
  for _, id in ipairs(ROW_ORDER) do
    local w = St.ui.rows[id]
    if id ~= "hdr" and id ~= nav.hl and U.ok(w) and not ui.hasFocus(w) then ui.inkRow(w) end
  end
end

local function activate(id, dir)
  if dir == 0 then
    if id == "start" and (St.ui.enabled or {}).start == false then
      U.dbg(TAG, "nav: START is disabled (%s)", tostring(baseTexts().start))
      return
    end
    local fn = BUTTON_ACTIONS[id]
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
end

-- A click seen by ui.pollClicks (mouse / CommonUI A): the highlight moves to that row.
function lobby.noteClicked(id)
  if indexOf(NAV_IDS, id) == nil or St.menu.visible ~= "lobby" then return end
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
  local f = focusedId(list, p1)
  if f ~= nil then
    if not k.held then k.held = true; U.dbg(TAG, "focus keeper: row '%s' holds P1's focus (%s)", f, k.why) end
    return
  end
  k.held = false
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = list[1] end
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
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = list[1] end
  restyle()
  lobby.armFocusKeeper("tab selected")
end

-- menu_tab.showPage(which), every show (also the lobby back from the builder, without a "tab" event): synchronous
-- focus try, fresh input baseline and Back guard, layer baseline, and the focus keeper window.
function lobby.onPageShown(which)
  nav.primed, nav.backGuard, nav.layerBase, nav.covered, nav.seenAct = false, false, nil, false, {}
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
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = list[1] end
  local took = focusRow(nav.idx)
  setHighlight(nav.idx)
  return took
end

local function stepRow(list, pos, step)
  return list[((pos - 1 + step) % #list) + 1]
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
  consume(id, kind)
  activate(id, 0)
end

-- setup.lua (pad B = step back): the game may also show its Back prompt; the next accept is swallowed.
function lobby.armBackGuard()
  nav.backGuard = true
end

-- FAST loop (ui.pollClicks) while the lobby page shows. Optional extra since 2026-10-07 (see the section header).
function lobby.pollNav()
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
  local delay = tonumber(opt("LobbyNavRepeatDelayMs", 400)) or 400
  if not nav.primed then                               -- baseline after a (re)show: no edges on this tick
    nav.primed = true
    nav.prev, nav.vdir, nav.hdir = st, axis(st.up, st.down), axis(st.left, st.right)
    nav.vNextMs = now + delay
    nav.armUntilMs = now + (tonumber(opt("LobbyNavArmMs", 250)) or 250)
    if focused ~= nil then
      nav.idx = focused
    elseif focusRow(nav.idx) then                      -- e.g. back from the builder page (no "tab" event)
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
  if step ~= 0 and not focusMoved and focused == nil then
    nav.idx = stepRow(list, indexOf(list, nav.idx) or 1, step)
    if focusRow(nav.idx) then nav.lastFocus = nav.idx end
  end
  setHighlight(nav.idx)
  -- 3. Left/right: edge only (no repeat), rows with a value.
  local hdir = axis(st.left, st.right)
  if hdir ~= 0 and hdir ~= nav.hdir then activate(nav.idx, hdir) end
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
-- "back" (Escape: only arms the Back guard; Escape itself stays the game's).
function lobby.onKey(name)
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
  if name == "back2" then return end
  local p1 = U.p1()
  local list = navList()
  if #list == 0 then return end
  if nav.idx == nil or indexOf(list, nav.idx) == nil then nav.idx = nearest(list, nav.idx) end
  local focused = focusedId(list, p1)
  if focused ~= nil then
    -- CommonUI holds focus on a row: it navigates and clicks with the keyboard itself; only follow its focus
    nav.idx = focused
    setHighlight(focused)
    return
  end
  logSeen("keybind " .. name)
  if name == "up" or name == "down" then
    nav.idx = stepRow(list, indexOf(list, nav.idx) or 1, name == "up" and -1 or 1)
    focusRow(nav.idx)
    setHighlight(nav.idx)
  elseif name == "left" or name == "right" then
    setHighlight(nav.idx)
    activate(nav.idx, name == "left" and -1 or 1)
  elseif name == "accept" then
    setHighlight(nav.idx)
    accept(p1, "kb")
  end
end

-- Arrow / Enter / Space / Escape keybinds (cfg.LobbyNavKeyboard ~= "never"). UE4SS keybinds fire on the key-down
-- edge while the game window has focus, never consume the key, and run on the UE4SS input thread: the body only
-- schedules lobby.onKey on the game thread. Note: while a bound key is held (e.g. an arrow while steering), UE4SS
-- drops every other keybind event of that frame (F5-F9 included).
function lobby.init()
  registerListeners()
  if opt("LobbyNavKeyboard", "always") == "never" or type(RegisterKeyBind) ~= "function" or Key == nil then return end
  local binds = {
    { Key.UP_ARROW, "up" }, { Key.DOWN_ARROW, "down" }, { Key.LEFT_ARROW, "left" }, { Key.RIGHT_ARROW, "right" },
    { Key.RETURN, "accept" }, { Key.SPACE, "accept" }, { Key.ESCAPE, "back" }, { Key.BACKSPACE, "back2" },
  }
  local n = 0
  for _, b in ipairs(binds) do
    local key, name = b[1], b[2]
    if key ~= nil then
      local ok, err = pcall(RegisterKeyBind, key, function()
        sched.run("lobby.key", function() lobby.onKey(name) end)
      end)
      if ok then n = n + 1 else U.warn(TAG, "RegisterKeyBind(%s) failed: %s", name, tostring(err)) end
    end
  end
  nav.kbBound = n > 0
  U.log(TAG, "lobby keyboard navigation: %d keybind(s) (arrows, Enter/Space, Escape guard, Backspace = setup BACK)", n)
end

---------------------------------------------------------------------------------------------------
-- RACE SETUP mode (setup.open / setup.close): the lobby rows are collapsed while the setup panel is shown.
---------------------------------------------------------------------------------------------------
function lobby.setSetupMode(on)
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
