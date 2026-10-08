-- menu_tab.lua (G3 Front-end UI): the SPLIT SCREEN tab on WBP_FE_MainMenu_C and page switching.
-- Contract: notes/ARCHITECTURE.md §4.2 "G3 · menu_tab.lua", behaviour §1.1, detectors §5.3. Research: [MT§3, §6].
--
-- Verified signatures (reflect-func-all.py; WBP_* from work/bpprops):
--   UCommonTabListWidgetBase: RegisterTab(Name TabNameID, Class ButtonWidgetType, Object ContentWidget, Int TabIndex)
--     -> Bool; GetTabButtonBaseByID(Name) -> Object; GetTabCount() -> Int; SelectTabByID(Name, Bool
--     bSuppressClickFeedback) -> Bool; GetActiveTab() -> Name
--   WBP_Tab_Btn_C:SetText(const FText& InText) (BP; plain input) / GetText() -> Text (BP)
--   UPanelWidget: GetChildIndex(Object) -> Int; AddChild(Object) -> Object
--   UWidgetSwitcher (FuseWidgetSwitcher -> CommonAnimatedSwitcher): SetActiveWidget(Object), SetActiveWidgetIndex(Int)
--   UCommonActivatableWidget: ActivateWidget(), DeactivateWidget(), IsActivated() -> Bool, RequestRefreshFocus()
--   WBP_FE_MainMenu_C: RegisterTabs() (BP), CustomEvent(Name TabId) (BP, bound to WBP_Tab_List.OnTabSelected),
--     variables WBP_Tab_List, WS_ScreenContent, "Button Widget Type" (ClassProperty), IgnoreTabSelection (Bool)
--   UPanelWidget: GetChildrenCount() -> Int, GetChildAt(Int) -> Object, RemoveChildAt(Int) -> Bool
--   UWidgetSwitcher: GetActiveWidget() -> Object
-- The menu binds CustomEvent BEFORE it calls RegisterTabs (mm-disasm 471-472 bind, RegisterTabs @4828), and CommonUI
-- selects the first registered tab inside the first RegisterTab: that CustomEvent reaches our hook on a menu that has
-- one tab and is not installed yet. Such events are ignored (V-TAB-09).
--
-- POLL FIRST (live run 2026-10-06): Blueprint-function hooks register but never fire in this build (RegisterTabs,
-- CustomEvent, BP_OnClicked, the builder's Go BndEvt, UpdateCurrentLap). Every behaviour here therefore has a poll
-- path that is the DEFAULT and the only one required:
--   * install: NotifyOnNewObject + the SLOW ensure() (FindFirstOf fallback) - never the RegisterTabs hook;
--   * tab selection: the MAIN pollTab() (WBP_Tab_List:GetActiveTab edges), always on (pollWanted() == true);
--   * "RegisterTabs again while our tab was open" (dev screen Back, a screen that covered the menu): pollTab() sees
--     the main menu's IsActivated() go true -> false (>= cfg.TabReactivateMinMs) -> true, and ensure() sees our tab
--     vanish; both set the return to our tab exactly like the hook did;
--   * the builder's Go / choice capture: builder.poll(), driven from pollTab() (see builder.lua).
-- The two BP hooks stay registered as optional extras: when they fire, the poll de-duplicates against what they
-- handled (St.menu.prevTabId, lastOurEventMs, install()'s per-instance idempotence), so nothing runs twice.

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local menu_tab = {}

local TAG = "tab"
local FRONT_PHASES = {FRONTEND = true, LAUNCHING = true}
local GONE_PHASES = {LOADING = true, PRERACE = true, RACING = true, POSTRACE = true, LEAVING = true, OTHER = true}
local GAME_PANES = 5             -- WS_ScreenContent children 0..4 are the game's panes (4 = WBP_FE_Campaign) [MT§2]

local lastFindMs = -1e9          -- throttle for FindFirstOf in ensure() (<= 1 per second, rule 6)
local lastOurEventMs = -1e9      -- last CustomEvent carrying our tab id (selectOurTab's 300 ms fallback)
-- true between a "tab"(true) and its "tab"(false): the leave path keys on it (not only on St.menu.visible) so that
-- every join.open (lobby.onShown) is paired with a join.close (lobby.onHidden) [§1.1 guests never leak].
local tabOpen = false
local notifyRegistered = false
local listenersRegistered = false
-- Post-race / post-reload return to our tab: one scheduled attempt chain at a time (token), cancelled by a user's
-- choice of another tab. While it is pending, game-tab selections from the switcher->tab sync do not close guests.
local returnToken = 0
local returnPending = false
local polled = {key = 0, id = nil}   -- tab poll (pollTab): last GetActiveTab() seen per menu instance
-- Diagnostics only: set the first time selectOurTab's fallback had to act because no CustomEvent hook call followed
-- an accepted SelectTabByID (expected in this build: BP hooks do not fire). Nothing depends on it any more.
menu_tab.hookSilent = false
-- Main-menu activation edges (pollTab): {key = menu key, active = last IsActivated() (nil = never read / not
-- readable), seenActive = an activated state was observed on this instance, offAtMs = when it went inactive}.
local act = {key = 0, active = nil, seenActive = false, offAtMs = 0}
local hookFiredTabs = false      -- a CustomEvent / RegisterTabs hook call was ever seen (diagnostics)

-- Should the MAIN loop run pollTab? Always: the poll is the required path (BP hooks do not fire in this build).
-- cfg.TabDetectMode "poll" additionally makes the CustomEvent hook a no-op; "hook" / "both" keep it as an extra
-- that the poll de-duplicates against.
function menu_tab.pollWanted()
  return true
end

local function reactivateMinMs()
  local v = cfg.TabReactivateMinMs
  if type(v) == "number" and v >= 0 then return v end
  return 1000
end

local isStaleMenu   -- forward (defined with isStale below)
local lastStablePhase = "BOOT"   -- last phase other than TRANSIT (the phase listener's "from")
local closeStrayGuests   -- forward (defined below; used by the phase listener registered in init)

local function isCDOorArchetype(obj)
  local flags = EObjectFlags.RF_ClassDefaultObject | (EObjectFlags.RF_ArchetypeObject or 0x20)
  return obj:HasAnyFlags(flags)
end

local function registerMenuHooks()
  -- U.hook registers a path once; for /Game paths it queues until the class is loaded (retried in SLOW and here).
  U.hook(C.FN.MenuRegisterTabs, {post = menu_tab.onRegisterTabs}, TAG)
  U.hook(C.FN.MenuCustomEvent, {post = menu_tab.onCustomEvent}, TAG)
  St.menu.hooksMenu = true
end

function menu_tab.init()
  -- Queue both OPTIONAL BP hooks now (they register once WBP_FE_MainMenu_C is in memory; nothing requires them).
  registerMenuHooks()

  if not notifyRegistered then
    notifyRegistered = true
    -- VERIFY(V-CORE-09): NotifyOnNewObject fires for this /Game class, once per menu instance, CDO skipped;
    -- fallback = the SLOW menu_tab.ensure() poll (FindFirstOf), always active.
    NotifyOnNewObject(C.BP.MainMenu, function(obj)
      U.try(TAG, function()
        if not U.ok(obj) or isCDOorArchetype(obj) then return end
        St.menu.pendingNew = obj
        U.dbg(TAG, "new main menu constructed: %s", tostring(obj:GetFullName()))
        registerMenuHooks()
        U.retryPendingHooks()
      end)
      return nil   -- keep the notifier (returning true would unregister it)
    end)
  end

  if not listenersRegistered then
    listenersRegistered = true
    -- The pages die with the front-end world: nothing of ours is "visible" in a race, and nothing of the menu may be
    -- used there. The whole menu bookkeeping goes (St.menu, the click registry, the lobby rows): UE4SS validity is
    -- address-based, so a race widget allocated at a dead lobby button's address would pass U.ok/U.same and run a
    -- lobby action (click hook), or take a status text (lobby.setStatus). The next front-end menu is then always
    -- installed as a new instance (St.menu.key = 0). St.ui.returnToTab is kept (St.resetMenu).
    St.on("phase", TAG, function(new, old)
      if new ~= "TRANSIT" then
        local from = (old == "TRANSIT") and lastStablePhase or old
        lastStablePhase = new
        old = from
      end
      if not GONE_PHASES[new] then return end
      -- OTHER (campaign paddock, PvP flow) is entered from the menu without any tab event: guests must not follow.
      -- Also guests kept for a rematch whose return chain is still pending (St.join.active false until the lobby
      -- reopens): dropMenu below cancels that chain without its give-up close. closeStrayGuests skips a pending
      -- launch and a frozen (client) set, and does nothing without guests.
      if new == "OTHER" and FRONT_PHASES[old] then closeStrayGuests("phase OTHER entered from the menu") end
      -- LEAVING / OTHER can be marked late, by phase.tick on its first look at the NEW world (no leaving hook fired):
      -- the RegisterTabs post-hook may already have installed that world's menu and consumed St.ui.returnToTab for
      -- its return chain. A menu of the current world is alive (no address reuse possible): keep it. In a real race
      -- the menu was dropped at LOADING already, or belongs to another world (then it is dropped as before).
      if (new == "LEAVING" or new == "OTHER") and St.menu.widget ~= nil and not isStaleMenu(St.menu.widget) then
        U.dbg(TAG, "phase %s: menu of the current world kept", tostring(new))
        return
      end
      menu_tab.dropMenu("phase " .. tostring(new))
    end)
    -- A new world (also FRONTEND -> FRONTEND: `open L_FrontEnd?listen`, client connect) kills the menu: its flags
    -- must not reach the next menu's first tab event. A menu of the new world may already be installed (its
    -- RegisterTabs can run before the MAIN poll sees the world): then it is kept.
    St.on("world", TAG, function()
      if St.menu.widget ~= nil and isStaleMenu(St.menu.widget) then
        -- A front end -> front end travel while our tab was open (also one the mod did not start: the game's own
        -- reload, a failure that is not a mod connect/host action). The old menu dies without a "tab"(false), so
        -- the open tab is carried over explicitly: back to our tab in the new menu (cfg.ReturnToSplitTab: install()
        -- starts the return chain; join.resync keeps the set), else "tab"(false) closes the join session (lobby.
        -- onHidden), so guests and the join poll never outlive the lobby on the game's own pane (§1.1).
        -- St.phase is still the old world's phase here; a pending launch keeps its own bookkeeping.
        local wasOpen = tabOpen or St.menu.visible ~= nil
        if wasOpen and St.phase == "FRONTEND" and not St.launch.pending then
          if cfg.ReturnToSplitTab == true then
            St.ui.returnToTab = true
            U.dbg(TAG, "front end reloaded with our tab open: return to it in the new menu")
          else
            tabOpen = false
            St.emit("tab", false)
          end
        end
        menu_tab.dropMenu("world changed")
      end
    end)
  end
end

-- RegisterTabs post-hook (OPTIONAL extra: never fired in the 2026-10-06 runs): the four game tabs exist now
-- [MT§3.1, §6 A]. The poll equivalents are ensure() (install, tab vanished) and pollTab()'s re-activation edge.
-- install() is idempotent per instance and the return chain is single (token), so a hook that does fire after the
-- poll already acted changes nothing.
function menu_tab.onRegisterTabs(ctx)
  local menu = ctx:get()
  if not hookFiredTabs then
    hookFiredTabs = true
    U.log(TAG, "a main-menu BP hook fired (RegisterTabs): BP hooks work in this session (poll stays the main path)")
  end
  U.dbg(TAG, "RegisterTabs post-hook fired")
  -- RegisterTabs again on the instance already installed while our tab was open (the dev screen's own Back returning
  -- to the main menu, a tab-list rebuild): the game re-selects one of its tabs, and with cfg.BuilderMode "devscreen"
  -- the join set was committed (no join poll, no dormant guests). The return chain reselects our tab; its
  -- onTabSelected -> showPage -> "tab"(true) -> join.open restores the dormant guests and the poll.
  if U.ok(menu) and U.same(menu, St.menu.widget) and St.menu.key ~= 0 and (tabOpen or St.menu.visible ~= nil)
      and cfg.ReturnToSplitTab and not St.launch.pending then
    U.log(TAG, "RegisterTabs again on the installed menu while our tab was open: returning to it")
    St.menu.devscreen = nil
    St.ui.returnToTab = true
  end
  menu_tab.install(menu)
end

local function menuWorldIsCurrent(menu)
  local ok, same = pcall(function()
    local w = menu:GetWorld()
    local cur = U.world()
    if not (U.ok(w) and U.ok(cur)) then return true end   -- cannot tell: trust the instance
    return U.key(w) == U.key(cur)
  end)
  return (not ok) or same
end

local function isStale(menu)
  return not U.ok(menu) or not menuWorldIsCurrent(menu)
end
isStaleMenu = isStale

local function worldKeyOf(menu)
  local ok, w = pcall(function() return menu:GetWorld() end)
  if ok and U.ok(w) then return U.key(w) end
  return 0
end

-- Guests must never be alive on the game's own tabs (§1.1). Closes every local guest unless a launch is pending or
-- the guest set is frozen (connected client: it only changes through DISCONNECT, §2.3).
-- join.closeStray(why), when join defines it, decides instead (e.g. keeping the dormant guests for the whole
-- front-end visit, so a ControllerId is never re-created shortly after RemovePlayer: the 2026-10-06 crash).
closeStrayGuests = function(why)
  if St.launch.pending then return end
  local join = U.mod("join")
  if type(join.closeStray) == "function" then
    join.closeStray(why)
    return
  end
  if join.isFrozen() then return end
  local n = #U.localPlayers() - 1
  if n <= 0 then return end
  U.log(TAG, "%s: closing %d local guest(s)", why, n)
  join.close()
end

local function cancelReturn()
  returnToken = returnToken + 1
  returnPending = false
end

-- The installed menu is dead (front end left, or replaced by a new world): forget it and every widget of it.
-- No UFunction call (its widgets may be freed already). Idempotent.
function menu_tab.dropMenu(why)
  local had = St.menu.widget ~= nil or St.menu.key ~= 0 or next(St.ui.buttons) ~= nil or next(St.ui.rows or {}) ~= nil
  tabOpen = false
  cancelReturn()
  polled.key, polled.id = 0, nil
  St.resetMenu()                   -- keeps St.ui.returnToTab
  U.mod("ui").forgetAll()          -- buttons, labels, rows, texts, shown, enabled
  if had then U.dbg(TAG, "menu bookkeeping dropped (%s)", tostring(why)) end
end

-- Hot reload (Ctrl+F11) leaves the previous Lua state's pages in WS_ScreenContent: remove every SettingList /
-- Builder child after the game's panes, except the pages of the current state.
local function removeStalePages(menu)
  local sw = menu.WS_ScreenContent
  if not U.ok(sw) then return end
  local n = sw:GetChildrenCount()                  -- PanelWidget:GetChildrenCount() -> Int
  if type(n) ~= "number" then return end
  for i = n - 1, GAME_PANES, -1 do
    U.try(TAG, function()
      local w = sw:GetChildAt(i)                     -- PanelWidget:GetChildAt(Int) -> Object
      if not U.ok(w) or U.same(w, St.menu.lobby) or U.same(w, St.menu.builder) then return end
      if U.isA(w, "SettingList") or U.isA(w, "Builder") then
        sw:RemoveChildAt(i)                          -- PanelWidget:RemoveChildAt(Int) -> Bool
        U.warn(TAG, "removed a stale page of a previous mod instance at switcher index %d (%s)", i, U.pathOf(w))
      end
    end)
  end
end

local function ourTabButton(menu)
  local tl = menu.WBP_Tab_List
  if not U.ok(tl) then return nil end
  local btn = tl:GetTabButtonBaseByID(U.fname(C.TAB_ID))   -- GetTabButtonBaseByID(Name) -> Object
  if U.ok(btn) then return btn end
  return nil
end

-- The switcher->tab sync highlighted our tab (TabIndex 4) for the game's WBP_FE_Campaign pane (switcher index 4)
-- [MT§6 C]: our page is (correctly) not shown, but our tab is now CommonUI's selected tab, so a real click on it would
-- not re-broadcast OnTabSelected (no CustomEvent, and pollTab sees no change). cfg.OurTabSyncFix = "clear" (default)
-- un-selects our tab button (UCommonButtonBase:ClearSelection(), 0 params [reflect-func-all]) outside the
-- SelectTabByID call stack, so the next click selects it again and broadcasts. "off": nothing (F5 or another tab
-- first). St.menu.ourSelCleared lets pollTab recognise that click by the button's GetSelected() (-> Bool).
-- VERIFY(V-TAB-13): after the Campaign pane, one click on SPLIT SCREEN opens the lobby.
local function clearOurHighlight(menu, why)
  if cfg.OurTabSyncFix ~= "clear" then return end
  local token = St.menu.key
  sched.after("tab", 0, function()
    if St.menu.key ~= token or not U.same(St.menu.widget, menu) then return end
    if St.menu.visible or tabOpen then return end
    local btn = ourTabButton(menu)
    if not btn then return end
    local ok = U.try(TAG, function() btn:ClearSelection() end)
    if ok then
      St.menu.ourSelCleared = true
      U.log(TAG, "our tab un-highlighted after the switcher->tab sync (%s)", tostring(why))
    end
  end)
end

local function gameTabsRegistered(menu)
  local tl = menu.WBP_Tab_List
  return U.ok(tl) and tl:GetTabCount() >= 4
end

-- SLOW loop, front end only. Covers hot reload, a missed NotifyOnNewObject/RegisterTabs hook, a new menu instance
-- after a race, and a tab label overwritten by a tab-list rebuild.
function menu_tab.ensure()
  -- cfg.BuilderMode "devscreen": the dev screen was left without builder.close (the game's own Back ->
  -- ReturnToMainMenu) and RegisterTabs did not run again: our tab is reselected so the join set reopens.
  -- VERIFY(V-BLD-01): after the dev screen's Back the log shows "dev screen left by the game" and the lobby works.
  if St.menu.devscreen and St.phase == "FRONTEND" and not St.launch.pending then
    local active = U.csmActive(C.ASSET.CSM_QuickRaceSetup, true)
    if active == false then
      St.menu.devscreen = nil
      U.log(TAG, "dev screen left by the game: returning to our tab")
      sched.after("tab", 200, function()
        if St.phase == "FRONTEND" and not St.launch.pending then menu_tab.selectOurTab() end
      end)
    end
  end
  local menu = St.menu.widget
  if not isStale(menu) and St.menu.tabAdded then
    local btn = ourTabButton(menu)
    if btn then
      -- VERIFY(V-TAB-03): the label sticks; this re-applies it if anything (HandleTabCreation rerun) overwrote it.
      local okText, txt = pcall(function() return U.str(btn:GetText()) end)   -- WBP_Tab_Btn_C:GetText() -> Text
      if okText and txt ~= C.TAB_LABEL then
        U.log(TAG, "tab label was '%s': re-applied", tostring(txt))
        btn:SetText(U.ftext(C.TAB_LABEL))
      end
      return
    end
    U.warn(TAG, "our tab vanished from the current menu: re-adding")
    -- Poll equivalent of "RegisterTabs again while our tab was open" for a rebuilt tab list: return to our tab.
    if (tabOpen or St.menu.visible ~= nil) and cfg.ReturnToSplitTab and not St.launch.pending then
      U.log(TAG, "our tab was open when it vanished: returning to it once it is re-added")
      St.menu.devscreen = nil
      St.ui.returnToTab = true
    end
    St.menu.tabAdded = false
    menu_tab.install(menu)
    return
  end

  -- Prefer the instance NotifyOnNewObject saw (no object-array scan), once its tabs exist.
  local cand = St.menu.pendingNew
  if U.ok(cand) and not isStale(cand) and gameTabsRegistered(cand) then
    U.log(TAG, "ensure: installing on the menu seen by NotifyOnNewObject")
    menu_tab.install(cand)
    return
  end

  local now = St.nowMs()
  if now - lastFindMs < 1000 then return end
  lastFindMs = now
  -- VERIFY(V-TAB-01): FindFirstOf matches the live WBP_FE_MainMenu_C (non-CDO) instance.
  local m = FindFirstOf("WBP_FE_MainMenu_C")
  if U.ok(m) and not isStale(m) and gameTabsRegistered(m) then
    U.log(TAG, "ensure: installing on FindFirstOf result")
    menu_tab.install(m)
  end
end

-- Idempotent per menu instance: lobby page, tab, builder page; then the post-race return to our tab.
function menu_tab.install(menu)
  if not U.ok(menu) then return end
  local key = U.key(menu)
  local wk = worldKeyOf(menu)
  -- a menu whose world differs from the installed one's is a new instance even at the same address (both known)
  local otherWorld = wk ~= 0 and (St.menu.worldKey or 0) ~= 0 and wk ~= St.menu.worldKey
  if key ~= St.menu.key or otherWorld then
    -- The previous instance had our tab open (a CSM ForceNewInstance inside the same front-end world, V-TAB-11):
    -- its "tab"(true) must be paired. Preferred: the return chain reopens our tab on this instance and join.open
    -- adopts the guests that are alive; without ReturnToSplitTab the tab is closed ("tab"(false) -> join.close).
    local prev = St.menu.widget
    local wasOpen = (tabOpen or St.menu.visible ~= nil) and prev ~= nil and not isStale(prev)
    if wasOpen then
      if cfg.ReturnToSplitTab then
        St.ui.returnToTab = true
        U.log(TAG, "main menu replaced while our tab was open: returning to it on the new instance")
      else
        U.log(TAG, "main menu replaced while our tab was open: tab closed")
        tabOpen = false
        St.emit("tab", false)
      end
    end
    St.resetMenu()                 -- keeps St.ui.returnToTab
    U.mod("ui").forgetAll()
    St.menu.widget = menu
    St.menu.key = key
    St.menu.worldKey = wk          -- a new menu at a freed menu's address is still a new instance
    St.menu.hooksMenu = true       -- the hooks are registered by path (U.hook), not per instance
    tabOpen = false                -- the previous menu's open tab must not drive this menu's first tab event
    cancelReturn()                 -- a return chain of the previous menu is over (a new one starts below)
    U.log(TAG, "main menu instance installed (%s)", tostring(key))
    U.try(TAG, removeStalePages, menu)
    -- WS_ScreenContent is a FuseWidgetSwitcher (UCommonAnimatedSwitcher, reflect.tsv): its Slate switcher swaps the
    -- shown child only when the transition ends, so focus given right after SetActiveWidget finds no widget path
    -- to our page (first live run: no row was ever focused). SetDisableTransitionAnimation(Bool) makes switches
    -- immediate (also for the game's own panes: cosmetic only).  VERIFY(V-TAB-07)
    if cfg.MenuSwitcherNoTransition ~= false then
        U.try(TAG, function()
            local sw = menu.WS_ScreenContent
            if U.ok(sw) then
                sw:SetDisableTransitionAnimation(true)   -- UCommonAnimatedSwitcher (1 param)
                U.log(TAG, "WS_ScreenContent transition animation disabled (immediate page switches)")
            end
        end)
    end
    St.emit("menu", menu)
  end
  U.try(TAG, function() U.mod("lobby").build(menu) end)
  U.try(TAG, function() menu_tab.addTab(menu) end)
  U.try(TAG, function() U.mod("builder").ensure(menu) end)
  -- Deferred only while the launch is live in the front end (phase.setPhase clears pending on race entry; a menu
  -- installed in a race phase, LEAVING or TRANSIT starts the chain, whose attempt() waits for FRONTEND).
  if St.ui.returnToTab and cfg.ReturnToSplitTab
      and (St.phase == "LAUNCHING" or (St.launch.pending and FRONT_PHASES[St.phase])) then
    -- A menu (re)installed while a launch is pending: the flag belongs to the post-race menu (launch.start set it);
    -- join.open refuses during LAUNCHING, so a chain now would only spend it. Kept for the next front-end world.
    U.dbg(TAG, "install during a pending launch: return to our tab kept for after the race")
  elseif St.ui.returnToTab and cfg.ReturnToSplitTab then
    St.ui.returnToTab = false
    -- VERIFY(V-TAB-06): 200 ms after RegisterTabs the front-end CSM no longer overrides the selection.
    -- RegisterTabs can run before phase.tick has seen the new front-end world: wait for FRONTEND (<= ~5 s).
    -- The chain follows whatever menu is installed when it runs (a second menu instance may replace this one);
    -- a user's choice of another tab cancels it (token). Giving up closes the kept guests: nothing else would.
    cancelReturn()
    returnPending = true
    local token = returnToken
    local tries = 0
    local function attempt()
      if token ~= returnToken then return end
      tries = tries + 1
      if St.launch.pending then
        -- a launch started while the chain waited: the post-race menu returns to our tab instead
        returnPending = false
        St.ui.returnToTab = true
        U.dbg(TAG, "return to our tab deferred: a launch is pending")
      elseif St.phase == "FRONTEND" and not isStale(St.menu.widget) then
        returnPending = false
        menu_tab.selectOurTab()
      elseif tries < 20 then
        sched.after("tab", 250, attempt)
      else
        returnPending = false
        U.warn(TAG, "return to the SPLIT SCREEN tab dropped: phase %s, menu %s", tostring(St.phase),
          isStale(St.menu.widget) and "missing" or "ok")
        if tabOpen then
          -- pollTab kept the session open (pages hidden) for this return: pair its "tab"(true) now
          menu_tab.hidePages()
          tabOpen = false
          St.emit("tab", false)
        end
        closeStrayGuests("return to our tab failed")
      end
    end
    sched.after("tab", 200, attempt)
  end
  polled.key, polled.id = 0, nil
end

function menu_tab.addTab(menu)
  local tl = menu.WBP_Tab_List
  if not U.ok(tl) then
    U.warn(TAG, "addTab: menu.WBP_Tab_List invalid")
    return false
  end
  local id = U.fname(C.TAB_ID)
  if U.ok(tl:GetTabButtonBaseByID(id)) then
    St.menu.tabAdded = true
    return true
  end
  -- VERIFY(V-TAB-02): a property name with spaces resolves through obj["..."] and holds WBP_Tab_Btn_C.
  local btnCls = menu["Button Widget Type"]
  if not U.ok(btnCls) then
    U.warn(TAG, "addTab: menu[\"Button Widget Type\"] invalid, using %s", C.BP.TabBtn)
    btnCls = U.class(C.BP.TabBtn)
  end
  if not U.ok(btnCls) then
    U.err(TAG, "addTab: no tab button class")
    return false
  end
  local content = U.ok(St.menu.lobby) and St.menu.lobby or nil   -- ContentWidget may be null [MT§3.4 E]
  local index = tl:GetTabCount()                                   -- GetTabCount() -> Int (4: appended after Multiplayer)
  -- RegisterTab(Name TabNameID, Class ButtonWidgetType, Object ContentWidget, Int TabIndex) -> Bool
  local ok = tl:RegisterTab(id, btnCls, content, index)
  local btn = tl:GetTabButtonBaseByID(id)
  if U.ok(btn) then
    -- VERIFY(V-TAB-03): HandleTabCreation already wrote GetTabTextFromID(<unknown id>); our label replaces it.
    btn:SetText(U.ftext(C.TAB_LABEL))   -- WBP_Tab_Btn_C:SetText(const FText&): plain input
  end
  St.menu.tabAdded = (ok == true) or U.ok(btn)
  U.log(TAG, "RegisterTab(%s, index %d) -> %s; button %s", C.TAB_ID, index, tostring(ok), U.ok(btn) and "ok" or "missing")
  return St.menu.tabAdded
end

-- CustomEvent(TabId) post-hook: the game's handler already ran (ChangeStateTo for its tabs, "Unhandled state for
-- tab" for ours) [MT§3.2].
-- OPTIONAL extra (never fired in the 2026-10-06 runs); pollTab() is the required path and skips what this handled.
function menu_tab.onCustomEvent(ctx, tabIdParam)
  local menu = ctx:get()
  if not U.ok(menu) then return end
  if not hookFiredTabs then
    hookFiredTabs = true
    U.log(TAG, "a main-menu BP hook fired (CustomEvent): BP hooks work in this session (poll stays the main path)")
  end
  -- VERIFY(V-TAB-04): TabId arrives as an FName param; IgnoreTabSelection is false on real clicks.
  local id = U.str(tabIdParam:get())
  -- VERIFY(V-TAB-09): CommonUI's auto-selection of the first tab inside the first RegisterTab reaches this hook with
  -- fewer than 4 tabs registered (the menu binds CustomEvent before RegisterTabs). Installing there would give our
  -- tab TabIndex 1, and the event is not a user's choice: ignored. The RegisterTabs post-hook installs the menu.
  if not gameTabsRegistered(menu) then
    U.dbg(TAG, "CustomEvent(%s) during RegisterTabs (fewer than 4 tabs): ignored", id)
    return
  end
  -- Recorded before the mode/sync branches: selectOurTab's fallback only needs to know that the hook fired for a
  -- real selection of our tab (in "poll" mode the poll then handles it; a sync event never shows our page).
  if id == C.TAB_ID and menu.IgnoreTabSelection ~= true then lastOurEventMs = St.nowMs() end
  if cfg.TabDetectMode == "poll" then
    U.dbg(TAG, "CustomEvent(%s) ignored: TabDetectMode = poll", id)
    return
  end
  if menu.IgnoreTabSelection == true then
    -- Switcher->tab sync in progress [MT§3.3]: WS_ScreenContent already changed (CSM tab state, HandleDeepLink)
    -- and the game is only re-highlighting the matching tab. Never show our page here, but leave it when the
    -- game moved the switcher away from it.
    menu_tab.onSyncSelection(menu, id)
    return
  end
  U.dbg(TAG, "CustomEvent(%s)", id)
  if not U.same(menu, St.menu.widget) then
    menu_tab.install(menu)   -- a menu we never saw (missed RegisterTabs hook)
  end
  menu_tab.onTabSelected(menu, id)
end

-- Is one of our pages the active widget of WS_ScreenContent? nil when the switcher cannot be read.
local function ourPageIsActive(menu)
  if not U.ok(menu) then return nil end
  local sw = menu.WS_ScreenContent
  if not U.ok(sw) then return nil end
  local cur = sw:GetActiveWidget()           -- UWidgetSwitcher::GetActiveWidget() -> Object
  return U.same(cur, St.menu.lobby) or U.same(cur, St.menu.builder)
end

-- Leave path: deactivate our pages and close the join session. restoreIdx = game pane to put back (nil = the game
-- already chose its pane).
local function leaveOurTab(menu, id, restoreIdx)
  menu_tab.hidePages()
  tabOpen = false
  St.emit("tab", false)
  if restoreIdx ~= nil and U.ok(menu) then
    local sw = menu.WS_ScreenContent
    if U.ok(sw) then
      -- Side-effect free: the switcher->tab sync sees GetTabIdAtIndex(idx) == GetActiveTab() and does nothing.
      sw:SetActiveWidgetIndex(restoreIdx)   -- SetActiveWidgetIndex(Int Index)
      U.dbg(TAG, "game pane %d restored for %s", restoreIdx, tostring(id))
    end
  end
  -- VERIFY(V-TAB-12): counterpart of showPage's cfg.DeactivateGamePaneOnShow: the game pane now shown (whichever
  -- the game or restoreIdx chose) must be activated again.
  if cfg.DeactivateGamePaneOnShow == true and U.ok(menu) then
    U.try(TAG, function()
      local sw = menu.WS_ScreenContent
      if not U.ok(sw) then return end
      local cur = sw:GetActiveWidget()           -- UWidgetSwitcher::GetActiveWidget() -> Object
      if not U.ok(cur) then return end
      local idx = sw:GetChildIndex(cur)          -- GetChildIndex(Object) -> Int
      if type(idx) == "number" and idx >= 0 and idx < GAME_PANES and not cur:IsActivated() then
        cur:ActivateWidget()                     -- UCommonActivatableWidget::ActivateWidget()
        U.dbg(TAG, "game pane %d reactivated for %s", idx, tostring(id))
      end
    end)
  end
  St.menu.coveredPane = nil
  St.menu.prevTabId = id
end

-- Entry point of every detector (pollTab, the optional CustomEvent hook, selectOurTab, the return chain).
-- De-duplicated for our id: the same selection reported by two detectors within DUP_MS (lobby still shown, session
-- open) is handled once, so "tab"(true) is not emitted twice for one click. A later reselection (return chain after
-- the dev screen) is handled again on purpose: its "tab"(true) -> join.open re-creates the committed guest set.
local DUP_MS = 1000
local lastOurHandledMs = -1e9
function menu_tab.onTabSelected(menu, id)
  if id == C.TAB_ID then
    local now = St.nowMs()
    lastOurEventMs = now             -- a handled selection of our tab (selectOurTab skips its direct call)
    St.menu.ourSelCleared = false
    if tabOpen and St.menu.visible == "lobby" and now - lastOurHandledMs < DUP_MS and ourPageIsActive(menu) == true then
      St.menu.prevTabId = id
      U.dbg(TAG, "our tab selection reported twice: handled once")
      return
    end
    lastOurHandledMs = now
    if menu_tab.showPage("lobby") then
      -- "tab"(true) also when the session is still open with hidden pages (pollTab during a return chain): the
      -- re-entrant join.open re-arms the edge detectors; a "tab"(false) was not emitted in between.
      tabOpen = true
      St.emit("tab", true)
    else
      -- No "tab"(true): join.open would create dormant guests that no "tab"(false) would ever close.
      St.emit("status", "SPLIT SCREEN PAGE UNAVAILABLE")
    end
    St.menu.prevTabId = id
    return
  end
  -- A user's choice of another tab: a pending post-race return to our tab must not override it.
  cancelReturn()
  if St.menu.visible or tabOpen then
    local idx = C.GAME_TABS[id]
    local restore = nil
    if idx ~= nil then
      -- VERIFY(V-TAB-05): when the CSM is already in that tab's state (our tab never changes it), ChangeStateTo may
      -- not re-run its SetWidgetSwitcher action and our (deactivated) page would stay on screen. Restore the game
      -- pane whenever our page is still the active widget; cfg.RestoreGamePaneOnTabLeave forces it.
      if cfg.RestoreGamePaneOnTabLeave or ourPageIsActive(menu) then restore = idx end
    end
    leaveOurTab(menu, id, restore)
  else
    St.menu.prevTabId = id
  end
  -- Invariant (§1.1), independent of our bookkeeping: guests kept for a rematch whose return to our tab did not
  -- land, guests of a previous mod instance (hot reload), dormant guests made by `couch set KeyboardIsP1`.
  if C.GAME_TABS[id] ~= nil then closeStrayGuests("game tab " .. tostring(id) .. " selected") end
  -- Guest LocalPlayers cannot be removed (RemovePlayer crash) and split-join any server the game connects to: the
  -- game's own online Multiplayer would get ghost players. Warned here (log + the lobby's status row) and in the
  -- ADD PLAYERS confirmation; the README says to restart the game before online play.
  if id == "MainMenu_Multiplayer" and #U.localPlayers() > 1 then
    U.warn(TAG, "Multiplayer tab with %d split-screen guest(s) alive: they would join online sessions as extra "
      .. "players; restart the game before online play", #U.localPlayers() - 1)
    St.emit("status", "RESTART THE GAME BEFORE ONLINE PLAY (SPLIT-SCREEN PADS ACTIVE)")
  end
end

-- CustomEvent fired by the game's switcher->tab sync (IgnoreTabSelection == true, mm-disasm @5917-6196). The game's
-- own handler skips ChangeStateTo in that case (@7450), and the switcher already shows the game's choice.
-- VERIFY(V-TAB-08): the CustomEvent post-hook runs inside SelectTabByID, while IgnoreTabSelection is still true.
function menu_tab.onSyncSelection(menu, id)
  U.dbg(TAG, "CustomEvent(%s) from the switcher->tab sync", tostring(id))
  if not U.same(menu, St.menu.widget) then return end
  St.menu.prevTabId = id                    -- handled here (the TabDetectMode poll must not act on it again)
  if not (St.menu.visible or tabOpen) then
    -- The game shows one of its panes: no guest may be alive there, unless our post-race return is still pending
    -- (the CSM's first pane of a new menu syncs before our 200 ms re-selection).
    if C.GAME_TABS[id] ~= nil and not returnPending then closeStrayGuests("switcher shows " .. tostring(id)) end
    if id == C.TAB_ID then clearOurHighlight(menu, "switcher index 4") end
    return
  end
  if C.GAME_TABS[id] ~= nil then
    leaveOurTab(menu, id, nil)              -- the game already chose its pane: never touch the switcher here
  elseif ourPageIsActive(menu) == false then
    -- Our id (switcher index 4 = WBP_FE_Campaign highlights our TabIndex 4 [MT§6 C]) or an unknown id: ignored
    -- for showing, but our page is gone from the switcher, so the tab is left.
    leaveOurTab(menu, id, nil)
    if id == C.TAB_ID then clearOurHighlight(menu, "switcher index 4, our page left") end
  end
end

local function pageOf(which)
  if which == "lobby" then return St.menu.lobby end
  if which == "builder" then return St.menu.builder end
  return nil
end

-- Show one of our pages in WS_ScreenContent. Pages are always selected by widget, never by index [§1.4].
function menu_tab.showPage(which)
  local menu = St.menu.widget
  if not U.ok(menu) then
    U.warn(TAG, "showPage(%s): no main menu", tostring(which))
    return false
  end
  local w = pageOf(which)
  if not U.ok(w) then
    U.warn(TAG, "showPage(%s): page not built", tostring(which))
    return false
  end
  local sw = menu.WS_ScreenContent
  if not U.ok(sw) then
    U.err(TAG, "showPage: menu.WS_ScreenContent invalid")
    return false
  end
  if sw:GetChildIndex(w) < 0 then     -- GetChildIndex(Object) -> Int
    sw:AddChild(w)                    -- AddChild(Object) -> Object (slot)
  end
  if which == "lobby" and St.menu.visible == "builder" then
    U.try(TAG, function() U.mod("builder").onLeavePage() end)   -- Go fallback (V-BLD-06)
  end
  -- VERIFY(V-TAB-12): the game pane under our page is deactivated (FuseWidgetSwitcher.bAutoActivateOnSwitch, value
  -- unknown [MT§9]); if it stays activated its action bindings / prompts stay live -> cfg.DeactivateGamePaneOnShow.
  if cfg.DeactivateGamePaneOnShow == true then
    U.try(TAG, function()
      local prev = sw:GetActiveWidget()          -- UWidgetSwitcher::GetActiveWidget() -> Object
      if not U.ok(prev) or U.same(prev, St.menu.lobby) or U.same(prev, St.menu.builder) then return end
      local idx = sw:GetChildIndex(prev)         -- GetChildIndex(Object) -> Int
      if type(idx) == "number" and idx >= 0 and idx < GAME_PANES and prev:IsActivated() then
        prev:DeactivateWidget()                  -- UCommonActivatableWidget::DeactivateWidget()
        St.menu.coveredPane = prev
        U.dbg(TAG, "game pane %d deactivated under our page", idx)
      end
    end)
  end
  sw:SetActiveWidget(w)               -- SetActiveWidget(Object Widget)
  w:ActivateWidget()                  -- builder: BP_OnActivated runs Init* + ClearChoices [MT§5]
  local other = pageOf(which == "lobby" and "builder" or "lobby")
  if U.ok(other) and other:IsActivated() then other:DeactivateWidget() end
  St.menu.visible = which
  -- VERIFY(V-TAB-07): pad focus lands on the highlighted lobby row / the builder's Btn_SetVehicle. Synchronous try
  -- now (immediate switch: cfg.MenuSwitcherNoTransition), then lobby's focus keeper (FAST loop) re-gives it every
  -- 200 ms for cfg.LobbyFocusKeepMs while nothing on the page holds P1's focus (a transition still playing, CommonUI
  -- restoring its own target on activation) - for BOTH pages, also the lobby shown again after the builder.
  local lobby = U.mod("lobby")
  if type(lobby.onPageShown) == "function" then
    U.try(TAG, lobby.onPageShown, which)
  elseif which == "lobby" then
    U.mod("ui").focus(St.ui.rows.race)
  else
    w:RequestRefreshFocus()
  end
  U.dbg(TAG, "page shown: %s", which)
  return true
end

-- Our tab was left: the game's CSM selects its own pane [MT§4].
function menu_tab.hidePages()
  if St.menu.visible == "builder" then
    U.try(TAG, function() U.mod("builder").onLeavePage() end)   -- Go fallback (V-BLD-06)
  end
  for _, which in ipairs({"lobby", "builder"}) do
    local w = pageOf(which)            -- (not ipairs over the pages: a nil lobby would end the loop early)
    if U.ok(w) then
      U.try(TAG, function()
        if w:IsActivated() then w:DeactivateWidget() end
      end)
    end
  end
  St.menu.visible = nil
end

-- F5, join.keyboardJoin, post-race return. Selects the tab like a click; if the selection is refused or no
-- CustomEvent with our id follows within 300 ms (already selected, IgnoreTabSelection, hook not firing), the
-- page is shown directly.
function menu_tab.selectOurTab()
  if not FRONT_PHASES[St.phase] then
    U.log(TAG, "selectOurTab: not in the front end (phase %s)", tostring(St.phase))
    return false
  end
  if isStale(St.menu.widget) then menu_tab.ensure() end
  local menu = St.menu.widget
  if not U.ok(menu) then
    St.emit("status", "MAIN MENU NOT FOUND")
    U.warn(TAG, "selectOurTab: no main menu installed")
    return false
  end
  if not St.menu.tabAdded then menu_tab.addTab(menu) end
  local requestedAt = St.nowMs()
  local tl = menu.WBP_Tab_List
  local ok = false
  -- An event is only expected when our tab was not already the active one (CommonUI does not re-broadcast an
  -- unchanged selection) and the selection is not a switcher->tab sync (onSyncSelection ignores our id).
  local eventExpected = false
  if U.ok(tl) then
    local okA, active = pcall(function() return U.str(tl:GetActiveTab()) end)   -- GetActiveTab() -> Name
    local wasActive = okA and active == C.TAB_ID
    eventExpected = not wasActive and menu.IgnoreTabSelection ~= true
    -- SelectTabByID(Name TabNameID, Bool bSuppressClickFeedback) -> Bool; the broadcast reaches CustomEvent
    -- synchronously, so lastOurEventMs is already updated when the call returns.
    ok = tl:SelectTabByID(U.fname(C.TAB_ID), false)
  end
  if ok ~= true then
    U.dbg(TAG, "SelectTabByID refused: showing the lobby directly")
    menu_tab.onTabSelected(menu, C.TAB_ID)
    return true
  end
  -- VERIFY(V-TAB-06): programmatic selection highlights our tab. The optional CustomEvent hook would have handled it
  -- synchronously inside SelectTabByID (lastOurEventMs); otherwise it is handled here at once (no wait for a hook
  -- that does not fire in this build), and the poll is baselined on our tab so it does not handle it again.
  if lastOurEventMs >= requestedAt then return true end
  if eventExpected and not menu_tab.hookSilent then
    menu_tab.hookSilent = true
    U.dbg(TAG, "no CustomEvent hook call inside SelectTabByID (expected: BP hooks do not fire); handled directly")
  end
  polled.key, polled.id = St.menu.key, C.TAB_ID
  menu_tab.onTabSelected(menu, C.TAB_ID)
  return true
end

-- Main-menu activation edges (the poll equivalent of "RegisterTabs ran again while our tab was open"): the main menu
-- (FuseScreenWidget -> UCommonActivatableWidget, IsActivated() -> Bool) is deactivated while another front-end screen
-- covers it (the dev screen in BuilderMode "devscreen", Settings, a modal) and activated again when it comes back.
-- Returns true while the menu is covered; "covered" exists only after an activated state was seen on this instance,
-- so a menu whose IsActivated() always reads false (or cannot be read) is never treated as covered.
-- A cover shorter than cfg.TabReactivateMinMs (default 1000 ms) is a flicker (e.g. a CSM state change on a tab click):
-- no return, and the tab change behind it is processed normally.
local function onReactivated(menu, offForMs)
  local wasOpen = tabOpen or St.menu.visible ~= nil or St.menu.devscreen == true
  if not wasOpen or St.launch.pending then
    U.dbg(TAG, "main menu active again after %d ms (our tab was not open)", offForMs)
    return
  end
  St.menu.devscreen = nil
  if cfg.ReturnToSplitTab then
    U.log(TAG, "main menu active again after %d ms while our tab was open: returning to it", offForMs)
    St.ui.returnToTab = true
    menu_tab.install(menu)              -- same instance: only starts the (single, token-guarded) return chain
  elseif tabOpen or St.menu.visible ~= nil then
    U.log(TAG, "main menu active again after %d ms while our tab was open: tab closed (ReturnToSplitTab off)",
      offForMs)
    leaveOurTab(menu, St.menu.prevTabId, nil)
  end
end

local function pollActivation(menu, now)
  local ok, a = pcall(function() return menu:IsActivated() end)   -- UCommonActivatableWidget::IsActivated() -> Bool
  if not ok or type(a) ~= "boolean" then return false end
  if act.key ~= St.menu.key then act.key, act.active, act.seenActive, act.offAtMs = St.menu.key, nil, false, 0 end
  local prev = act.active
  act.active = a
  if a then
    if prev == false and St.menu.visible ~= nil then
      -- a covering screen closed (any duration): CommonUI restores ITS focus target; our page takes P1 back
      local lobby = U.mod("lobby")
      if type(lobby.armFocusKeeper) == "function" then U.try(TAG, lobby.armFocusKeeper, "main menu active again") end
    end
    if prev == false and act.seenActive then
      local offFor = now - act.offAtMs
      if offFor >= reactivateMinMs() then
        onReactivated(menu, offFor)
      else
        U.dbg(TAG, "main menu inactive for %d ms only: treated as a flicker", offFor)
      end
    end
    act.seenActive = true
    return false
  end
  if prev ~= false then act.offAtMs = now end
  return act.seenActive
end

-- MAIN loop, front end, ALWAYS (pollWanted() == true): the required tab detector (V-TAB-10). Acts only when
-- WBP_Tab_List:GetActiveTab() changed since the previous poll AND differs from the last tab id this module handled
-- (St.menu.prevTabId), so a selection the optional CustomEvent hook (or selectOurTab) already handled is not redone.
-- Also drives builder.poll() (Go / choice capture), which must run even while the main menu is covered.
function menu_tab.pollTab()
  U.try(TAG, function()
    local b = U.mod("builder")
    if type(b.poll) == "function" then b.poll() end
  end)
  local menu = St.menu.widget
  if isStale(menu) or not St.menu.tabAdded then return end
  local tl = menu.WBP_Tab_List
  if not U.ok(tl) then return end
  local id = U.str(tl:GetActiveTab())       -- GetActiveTab() -> Name
  local now = St.nowMs()
  if polled.key ~= St.menu.key then          -- first poll on this menu: baseline only
    polled.key, polled.id = St.menu.key, id
    pollActivation(menu, now)
    return
  end
  -- Covered by another screen: tab changes are not the user's (the change, if any, is processed once the menu is
  -- active again: polled.id is deliberately not updated here).
  if pollActivation(menu, now) then return end
  if id == C.TAB_ID and id == polled.id and St.menu.ourSelCleared == true and not (St.menu.visible or tabOpen) then
    -- our tab was un-highlighted after a Campaign-pane sync (clearOurHighlight): the active id did not change, so a
    -- click is seen as the button being selected again
    local btn = ourTabButton(menu)
    local okS, sel = false, false
    if btn then okS, sel = pcall(function() return btn:GetSelected() end) end   -- GetSelected() -> Bool
    if okS and sel == true then
      U.log(TAG, "tab poll: our tab selected again after the Campaign-pane sync")
      menu_tab.onTabSelected(menu, id)
    end
    return
  end
  if id == polled.id then return end
  polled.id = id
  if id == St.menu.prevTabId then return end
  if id == C.TAB_ID then
    -- Our TabIndex 4 is also highlighted by the switcher->tab sync when the game shows switcher index 4
    -- (WBP_FE_Campaign) [MT§6 C]: that is not a selection of our tab.
    local sw = menu.WS_ScreenContent
    if U.ok(sw) then
      local cur = sw:GetActiveWidget()
      if U.ok(cur) and sw:GetChildIndex(cur) == 4 then
        St.menu.prevTabId = id
        U.dbg(TAG, "tab poll: our id highlighted by the Campaign pane (index 4): ignored")
        clearOurHighlight(menu, "tab poll, switcher index 4")
        return
      end
    end
  end
  -- A return to our tab is pending (post-race, re-activation, tab re-added): the game re-selecting one of its tabs
  -- now is its switcher->tab sync, which the poll cannot tell from a click (IgnoreTabSelection is only true inside
  -- the sync call). Treated like the hook's onSyncSelection: pages hidden, the join session kept (no "tab"(false)
  -- -> no RemovePlayer / CreatePlayer churn), the return chain not cancelled. A real click in this window is
  -- overridden by the return (<= ~5 s); the chain's give-up closes the session.
  if returnPending and C.GAME_TABS[id] ~= nil then
    St.menu.prevTabId = id
    if St.menu.visible ~= nil then menu_tab.hidePages() end
    U.log(TAG, "tab poll: %s selected while the return to our tab is pending: treated as the game's sync", id)
    return
  end
  -- VERIFY(V-TAB-10): the normal path in this build (BP hooks do not fire): one line per tab click.
  U.log(TAG, "tab poll: active tab is now %s", id)
  menu_tab.onTabSelected(menu, id)
end

-- The main menu is covered by another screen (Settings, the dev screen, a modal that deactivates it), as last read
-- by pollTab's activation poll (MAIN). lobby's input checks read IsActivated themselves (FAST) and use this too.
function menu_tab.isCovered()
  return act.key == St.menu.key and act.key ~= 0 and act.active == false and act.seenActive == true
end

function menu_tab.menu()
  local m = St.menu.widget
  if U.ok(m) then return m end
  return nil
end

-- A post-race / post-reload return chain is scheduled and not finished. Read by main's OnUnload (pure Lua): a hot
-- reload during the chain must persist ui.returnToTab, else the reloaded state's resync closes the rematch guests.
function menu_tab.returnPending()
  return returnPending == true
end

function menu_tab.isOurTabActive()
  local m = menu_tab.menu()
  if not m then return false end
  local tl = m.WBP_Tab_List
  if not U.ok(tl) then return false end
  return U.str(tl:GetActiveTab()) == C.TAB_ID   -- GetActiveTab() -> Name
end

return menu_tab
