-- ui.lua (G3 Front-end UI): widget factory over the game's own widget Blueprints + click detection.
-- Contract: notes/ARCHITECTURE.md §4.2 "G3 · ui.lua", layout rules §1.2, click detection §5.3.
-- Every function here runs on the game thread (callers: hooks, sched callbacks, lobby/menu_tab/builder).
--
-- Verified signatures (reflect-func-all.py on the Shipping exe; work/bpprops/*.txt for Blueprint functions):
--   UWidgetBlueprintLibrary:Create(Object WorldContextObject, Class WidgetType, Object OwningPlayer) -> Object
--   WBP_SectionHeaderModal_C:SetHeaderText(Text Text)                    (BP, plain Parm)
--   WBP_Vertical_Btn_C:SetText(const FText& InText)                      (BP, Parm|Out|Const|RefParm = plain input;
--                                                                         body: ButtonLabel = InText; Txt_Label->SetText)
--   WBP_Common_Btn_C:UpdateText(Text InText)                             (BP, plain Parm; PreConstruct re-reads ButtonLabel)
--   UCommonButtonBase: BP_SetIsFocusable(Bool), SetIsSelectable(Bool), SetIsToggleable(Bool), GetSelected() -> Bool,
--                      SetIsSelected(Bool InSelected, Bool bGiveClickFeedback), BP_SetIsInteractionEnabled(Bool)
--   UVerticalBox:AddChildToVerticalBox(Object Content) -> Object (UVerticalBoxSlot)
--   UVerticalBoxSlot: SetPadding(Struct FMargin), SetHorizontalAlignment(Byte)
--   UWidget: SetVisibility(Enum ESlateVisibility) (1 Lua arg; the "Byte UnderlyingType" line is the enum's inner prop),
--            SetFocus()
--   WBP_Common_Btn_C:BP_OnClicked has a Blueprint body (export 2 -> ExecuteUbergraph), so a UE4SS BP hook can see it.
--   (First live run: BP hooks never fire in this build -> cfg.ClickMode "poll" is the working path, mouse included.)
--   UWidget: SetUserFocus(Object PlayerController), SetKeyboardFocus(), HasUserFocus(Object PlayerController) -> Bool,
--            HasKeyboardFocus() -> Bool                                   (reflect-func-all, outer UWidget)
--   UUserWidget:PlayAnimation(Object InAnimation, Float StartAtTime, Int NumLoopsToPlay, Byte PlayMode,
--            Float PlaybackSpeed, Bool bRestoreState) -> Struct            (6 Lua args; PlayMode Forward=0 Reverse=1)
--   UTextBlock:SetColorAndOpacity(Struct FSlateColor)  = {SpecifiedColor = {R,G,B,A}, ColorUseRule = 0}
--   UCommonActivatableWidget:RequestRefreshFocus()
--
-- Row colours (kismet-disasm of WBP_Common_Btn / WBP_Vertical_Btn, 2026-10-07). Both BPs pick their colours from the
-- BP variable IsInvert (default false):
--   IsInvert=false: idle text = beige LinearColor(0.716, 0.708, 0.651), outline beige; hovered/focused = beige fill
--                   (WBP_ButtonBacker-Fill visible) + near-black text (0.007). Made for a DARK background: on the main
--                   menu's light page every idle row was beige-on-beige (the "faint rows" of the first live run).
--   IsInvert=true:  idle text near-black (0.007), outline dark; hovered/focused = dark fill + WHITE text.
--   PreConstruct (run when Slate builds the widget) applies IsInvert, so ui.styleRow sets it right after Create,
--   before the row is added to the page. Hover look (Common_Btn ubergraph @867): PlayAnimation(Anim_Hover, 0,1,0,1,
--   false); WBP_ButtonBacker-Fill:SetVisibility(0); Txt_Label:SetColorAndOpacity(GetSelectColor). Unhover (@1062):
--   the same with PlayMode 1, Fill:SetVisibility(2), GetUnselectSelectColor. ui.highlight reproduces both.

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local ui = {}

local TAG = "ui"
local clickHookRequested = false

-- St.ui.labels[addr] = true for widgets made by ui.label (shown with HitTestInvisible, never focusable).
local function labels()
  St.ui.labels = St.ui.labels or {}
  return St.ui.labels
end

function ui.init()
  -- Nothing to hook yet: WBP_Common_Btn_C:BP_OnClicked only exists once the class is loaded, which happens in
  -- ui.make() the first time a button is created (U.class -> LoadAsset fallback). See ui.installClickHook().
  U.dbg(TAG, "init (ClickMode=%s)", tostring(cfg.ClickMode))
end

-- Create one of the game's widget Blueprints (consts.BP key) owned by pc.
-- WorldContextObject = the owning PC [UI§3]; without a valid PC the world is the context and the owner is null.
function ui.make(bpKey, pc)
  local path = C.BP[bpKey]
  if path == nil then
    U.err(TAG, "make: unknown consts.BP key '%s'", tostring(bpKey))
    return nil
  end
  local cls = U.class(path)
  if not U.ok(cls) then
    U.err(TAG, "make: class not resolvable: %s", path)
    return nil
  end
  local owner = U.ok(pc) and pc or nil
  local ctx = owner or U.world()
  if not U.ok(ctx) then
    U.err(TAG, "make(%s): no world context", bpKey)
    return nil
  end
  -- Create(Object WorldContextObject, Class WidgetType, Object OwningPlayer) -> Object  [3 params, verified]
  local w = U.WBL():Create(ctx, cls, owner)
  if not U.ok(w) then
    U.err(TAG, "make(%s): Create returned an invalid widget", bpKey)
    return nil
  end
  return w
end

-- Section title (WBP_SectionHeaderModal_C).
function ui.header(pc, text)
  local w = ui.make("SectionHeader", pc)
  if not w then return nil end
  U.try(TAG, function()
    w:SetHeaderText(U.ftext(text)) -- SetHeaderText(Text Text), plain input [bpprops]
  end)
  return w
end

-- Display-only row (WBP_Vertical_Btn_C, the game's list-menu look), never focusable.
function ui.label(pc, text)
  local w = ui.make("VerticalBtn", pc)
  if not w then return nil end
  labels()[U.key(w)] = true
  U.try(TAG, function()
    w:SetText(U.ftext(text))        -- const FText& -> plain input [HERE LuaUObject.cpp:203-204]
    w:BP_SetIsFocusable(false)      -- UCommonButtonBase::BP_SetIsFocusable(Bool)
    -- HitTestInvisible (3), not SelfHitTestInvisible (4): the whole subtree, including CommonButtonBase's internal
    -- RootButton, must ignore hover/clicks (BP_OnHovered -> SetFocus, Anim_Hover). The game does the same
    -- (e.g. WBP_Lock->SetVisibility(3)).
    w:SetVisibility(C.E.Vis.HitTestInvisible)
    -- VERIFY(V-LOB-04): CommonUI navigation skips a non-focusable button; fallback = SetVisibility(Hidden) by hand.
  end)
  return w
end

function ui.setLabelText(w, text)
  if not U.ok(w) then return end
  w:SetText(U.ftext(text))          -- the BP body also stores ButtonLabel, so PreConstruct keeps it [disasm SetText]
end

-- Label of a WBP_Common_Btn_C: ButtonLabel first (PreConstruct re-applies it when Slate rebuilds), then UpdateText.
function ui.setButtonText(w, text)
  if not U.ok(w) then return end
  w.ButtonLabel = U.ftext(text)     -- TextProperty BP variable (BPVisible|Edit) [bpprops]
  w:UpdateText(U.ftext(text))       -- UpdateText(Text InText) -> Txt_Label->SetText  [bpprops, disasm]
  -- VERIFY(V-LOB-02): the row looks like the game's buttons and the label sticks after the page is shown.
end

-- Route clicks of an existing WBP_Common_Btn_C (ours or one inside a game widget, e.g. the builder's Btn_Go) to
-- fn(widget) through the same dispatch as our rows (BP_OnClicked post-hook, or the ClickMode poll).
-- opts (optional table, 0.10.0): noClaim = true -> every click of this button is dispatched on its own: no
-- ui.claimAction (the global LobbyNavDedupMs window would drop a fast A, A, A) and no lobby.consumedClick / noteClicked
-- (the lobby's per-press bookkeeping of its own rows). The RACERS step's P1 input sink (vehicle-step-v2.md §5.7.3,
-- §5.11) does its own attribution; VERIFY(V-RC-03): P1 A,A,A fast = 3 accepts.
function ui.registerButton(w, id, fn, opts)
  if not U.ok(w) then return false end
  St.ui.buttons[U.key(w)] = {id = id, fn = fn, widget = w, opts = type(opts) == "table" and opts or {}}
  if cfg.ClickMode == "poll" then
    U.try(TAG, function()
      -- Poll fallback [UI§3.4]: a selectable + toggleable button flips GetSelected() on every click.
      w:SetIsSelectable(true)       -- SetIsSelectable(Bool bInIsSelectable)
      w:SetIsToggleable(true)       -- SetIsToggleable(Bool bInIsToggleable)
    end)
  end
  ui.installClickHook()
  return true
end

-- Clickable row (WBP_Common_Btn_C). fn(widget) runs on the game thread when the button is clicked. opts: see
-- ui.registerButton.
function ui.button(pc, id, text, fn, opts)
  local w = ui.make("CommonBtn", pc)
  if not w then return nil end
  U.try(TAG, function() ui.setButtonText(w, text) end)
  ui.registerButton(w, id, fn, opts)
  U.dbg(TAG, "button '%s' created (%s)", tostring(id), tostring(text))
  return w
end

-- 0.12.0 UI v2 (notes/design/ui-v2/ui-redesign-final.md §3.3): the one focus mechanism of the v2 pages. A ghost is
-- ui.button with an empty label at render opacity 0: still Visible and focusable (CommonUI navigation and its
-- navigation sounds), clicked through the same selected-toggle poll / registry as every row (opts: see
-- ui.registerButton). Its own hover and focus looks are invisible, so the look Lua paints under it is the only one;
-- that look follows ui.hasFocus(ghost, p1) and ui.hovered(ghost). VERIFY(V-FIN-04): a ghost keeps CommonUI focus,
-- the navigation sounds and poll clicks; fallback SetNavigationRuleExplicit per ghost (theme.nav).
function ui.ghost(pc, id, fn, opts)
  local w = ui.button(pc, id, "", fn, opts)
  if not w then return nil end
  U.try(TAG, function()
    w:SetRenderOpacity(0)                       -- UWidget::SetRenderOpacity(Float): paint nothing, keep hit-testing
    w:SetVisibility(C.E.Vis.Visible)            -- hit-testable: Slate's focus navigation and the mouse need it
    w:BP_SetIsFocusable(true)                   -- UCommonButtonBase::BP_SetIsFocusable(Bool)
  end)
  return w
end

-- true while the mouse is over w (UWidget::IsHovered() -> Bool); false on any error or an invalid widget.
function ui.hovered(w)
  if not U.ok(w) then return false end
  local ok, v = pcall(U.callMethod, w, "IsHovered")
  return ok and v == true
end

-- Add w to a vertical box with the lobby row spacing; returns the UVerticalBoxSlot (or nil).
function ui.addRow(vbox, w, top, bottom)
  if not (U.ok(vbox) and U.ok(w)) then return nil end
  local slot = vbox:AddChildToVerticalBox(w)   -- AddChildToVerticalBox(Object Content) -> UVerticalBoxSlot
  if U.ok(slot) then
    slot:SetPadding({Left = 0, Top = top or 4, Right = 0, Bottom = bottom or 4})   -- FMargin as a Lua table
    slot:SetHorizontalAlignment(C.E.HAlign.Fill)                                     -- Byte EHorizontalAlignment
  else
    U.warn(TAG, "addRow: AddChildToVerticalBox returned no slot (is the root a VerticalBox?)")
  end
  return slot
end

function ui.setShown(w, on)
  if not U.ok(w) then return end
  local vis
  if not on then
    vis = C.E.Vis.Collapsed
  elseif labels()[U.key(w)] then
    vis = C.E.Vis.HitTestInvisible       -- labels never take hover/clicks (subtree included)
  else
    vis = C.E.Vis.Visible
  end
  w:SetVisibility(vis)                   -- SetVisibility(Enum ESlateVisibility): one integer argument
end

function ui.setEnabled(w, on)
  if not U.ok(w) then return end
  w:BP_SetIsInteractionEnabled(on and true or false)   -- UCommonButtonBase::BP_SetIsInteractionEnabled(Bool)
end

-- Optional config keys (config.lua may not define them yet): nil -> default.
local function opt(name, default)
  local v = cfg[name]
  if v == nil then return default end
  return v
end
ui.opt = opt

-- Give w the gamepad/keyboard focus of P1 (pc, default U.p1()). Every route is tried on its own (one failing call
-- must not stop the others): SetFocus (owning player's user), SetUserFocus(pc), SetKeyboardFocus (user 0).
-- Returns true when a HasUserFocus/HasKeyboardFocus query afterwards says the widget holds it.
function ui.focus(w, pc)
  if not U.ok(w) then return false end
  pcall(function() w:SetFocus() end)                       -- UWidget::SetFocus() (0 params)
  if pc == nil then pc = U.p1() end
  if U.ok(pc) then
    pcall(function() w:SetUserFocus(pc) end)               -- UWidget::SetUserFocus(Object PlayerController)
  end
  pcall(function() w:SetKeyboardFocus() end)               -- UWidget::SetKeyboardFocus() (0 params)
  return ui.hasFocus(w, pc)
end

-- true when w or one of its descendants holds P1's focus. Slate focus on a CommonButtonBase usually sits on its
-- internal RootButton (a descendant), where HasUserFocus / HasKeyboardFocus on the outer user widget read false.
-- Checks, in order: HasUserFocus(pc), HasUserFocusedDescendants(pc), HasKeyboardFocus(), HasFocusedDescendants()
-- (stock UWidget BlueprintCallable functions, all in the exe's script objects). The first check that ever matches is
-- logged once (V-LOB-08).
local focusMatchLogged = false
local function focusMatched(how)
  if focusMatchLogged then return end
  focusMatchLogged = true
  U.log(TAG, "focus detection: first match through %s (V-LOB-08)", how)
end

function ui.hasFocus(w, pc)
  if not U.ok(w) then return false end
  if pc == nil then pc = U.p1() end
  if U.ok(pc) then
    local ok, v = pcall(U.callMethod, w, "HasUserFocus", pc)                -- (Object) -> Bool
    if ok and v == true then focusMatched("HasUserFocus"); return true end
    ok, v = pcall(U.callMethod, w, "HasUserFocusedDescendants", pc)         -- (Object) -> Bool
    if ok and v == true then focusMatched("HasUserFocusedDescendants"); return true end
  end
  local ok2, v2 = pcall(U.callMethod, w, "HasKeyboardFocus")              -- () -> Bool
  if ok2 and v2 == true then focusMatched("HasKeyboardFocus"); return true end
  ok2, v2 = pcall(U.callMethod, w, "HasFocusedDescendants")               -- () -> Bool
  if ok2 and v2 == true then focusMatched("HasFocusedDescendants"); return true end
  return false
end

---------------------------------------------------------------------------------------------------- row style
local INK_DARK  = {R = 0.006995, G = 0.006995, B = 0.006995, A = 1.0}   -- the BPs' near-black
local INK_LIGHT = {R = 0.715693, G = 0.708376, B = 0.651406, A = 1.0}   -- the BPs' beige
local INK_WHITE = {R = 1.0, G = 1.0, B = 1.0, A = 1.0}

local function slateColor(c)            -- new table per call: UE4SS may keep/fill a passed struct table
  return {SpecifiedColor = {R = c.R, G = c.G, B = c.B, A = c.A}, ColorUseRule = 0}
end

-- Rows built by ui.styleRow use IsInvert (cfg.LobbyRowInvert, default true).
local function inverted() return opt("LobbyRowInvert", true) ~= false end

-- High-contrast style for a lobby row (WBP_Common_Btn_C or WBP_Vertical_Btn_C). Call right after ui.button/ui.label,
-- BEFORE ui.addRow: PreConstruct reads IsInvert when Slate builds the widget.  VERIFY(V-LOB-07)
function ui.styleRow(w)
  if not U.ok(w) or not inverted() then return end
  U.try(TAG, function()
    w.IsInvert = true                  -- BoolProperty BP variable (BPVisible|Edit) on both row classes [bpprops]
  end)
end

-- Idle text colour of a styled row, written directly (insurance when the widget was built before IsInvert was set,
-- or a rebuild reset it). Never call it on the focused/highlighted row: its text must stay the "select" ink.
function ui.inkRow(w)
  if not U.ok(w) then return false end
  return U.try(TAG, function()
    local txt = w.Txt_Label                                -- ObjectProperty (UFuseTextBlock) on both row classes
    if U.ok(txt) then txt:SetColorAndOpacity(slateColor(inverted() and INK_DARK or INK_LIGHT)) end
  end) == true
end

local function backerFill(w)
  local ok, f = pcall(function() return w["WBP_ButtonBacker-Fill"] end)   -- Common_Btn only (property name has '-')
  if ok and U.ok(f) then return f end
  return nil
end

-- Our own "hovered" look for the pad-navigation highlight (CommonUI focus may never reach our rows). Mirrors the
-- BP's hover/unhover branches. cfg.LobbyNavHighlight: "both" (style + focus, default) | "style" | "focus" (style
-- untouched: the BP's own OnFocusReceived look only). Returns false when the style could not be applied (caller
-- then falls back to the text marker).
function ui.highlight(w, on)
  if not U.ok(w) then return false end
  if opt("LobbyNavHighlight", "both") == "focus" then return true end
  local ok = true
  pcall(function()
    local anim = w.Anim_Hover                              -- ObjectProperty (WidgetAnimation) on both row classes
    if U.ok(anim) then w:PlayAnimation(anim, 0.0, 1, on and 0 or 1, 1.0, false) end
  end)
  local fill = backerFill(w)
  if fill then
    if not pcall(function() fill:SetVisibility(on and C.E.Vis.Visible or C.E.Vis.Hidden) end) then ok = false end
  else
    ok = false
  end
  local okT = pcall(function()
    local txt = w.Txt_Label
    if not U.ok(txt) then error("no Txt_Label") end
    local ink
    if on then ink = inverted() and INK_WHITE or INK_DARK else ink = inverted() and INK_DARK or INK_LIGHT end
    txt:SetColorAndOpacity(slateColor(ink))
  end)
  return ok and okT
end

---------------------------------------------------------------------------------------------------- input helpers
local fkeys = {}
-- PlayerController:IsInputKeyDown(FKey) for a key name; false on any error.
function ui.keyDown(pc, name)
  local k = fkeys[name]
  if k == nil then
    k = {KeyName = U.fname(name)}
    fkeys[name] = k
  end
  local ok, v = pcall(U.callMethod, pc, "IsInputKeyDown", k)   -- IsInputKeyDown(Struct Key) -> Bool
  return ok and v == true
end

-- One row action per press: the pad-navigation A (lobby.pollNav) and a CommonUI/mouse click seen by the poll can
-- report the SAME press. The first claimant within cfg.LobbyNavDedupMs runs, the other is dropped.
local lastActionMs, lastActionSrc = -1e9, ""
function ui.claimAction(src)
  local now = St.nowMs()
  if now - lastActionMs < (tonumber(opt("LobbyNavDedupMs", 350)) or 350) then
    U.dbg(TAG, "action '%s' dropped: same press as '%s'", tostring(src), tostring(lastActionSrc))
    return false
  end
  lastActionMs, lastActionSrc = now, tostring(src)
  return true
end

-- A registry entry made with opts.noClaim (ui.registerButton): its clicks skip the one-action-per-press dedup.
local function noClaim(e)
  return type(e.opts) == "table" and e.opts.noClaim == true
end

-- Register (once) the post-hook on WBP_Common_Btn_C:BP_OnClicked. A Blueprint-function hook needs the UFunction in
-- memory: U.hook queues the request when the class is not loaded yet and U.retryPendingHooks() completes it.
-- In "poll" mode the hook is still installed, but only logs (dispatch would double-fire with the poll).
function ui.installClickHook()
  if clickHookRequested then return end
  clickHookRequested = true
  -- VERIFY(V-CORE-07): BP hooks fire in this build (Denuvo/5.7); fallback cfg.ClickMode = "poll".
  -- VERIFY(V-LOB-03): one hook call per click, for pad A and mouse alike; fallback cfg.ClickMode = "poll".
  local ok = U.hook(C.FN.CommonBtnClicked, {post = ui.onClicked}, TAG)
  U.log(TAG, "click hook %s: %s", ok and "registered" or "queued", C.FN.CommonBtnClicked)
end

-- BP_OnClicked fires for EVERY WBP_Common_Btn_C in the game: only our registered instances are dispatched.
function ui.onClicked(ctx)
  -- Our rows (and the builder's Btn_Go) only exist in the front end. Outside it (race pause menu, results screen)
  -- the registry is empty (menu_tab drops it when the front end is left), and this guard also stops a stale entry
  -- whose address a game button reuses: UE4SS validity is address-based, so U.same cannot tell them apart.
  if not U.mod("phase").isFrontEnd() then return end
  local b = ctx:get()
  if not U.ok(b) then return end
  local e = St.ui.buttons[U.key(b)]
  if e == nil then return end
  if cfg.ClickMode == "poll" then
    U.dbg(TAG, "click hook saw '%s' (poll mode: not dispatched)", tostring(e.id))
    return
  end
  if not U.same(e.widget, b) then
    -- Address reuse after GC: the entry belongs to a dead widget.
    St.ui.buttons[U.key(b)] = nil
    return
  end
  U.dbg(TAG, "click '%s'", tostring(e.id))
  if type(e.fn) == "function" and (noClaim(e) or ui.claimAction("click:" .. tostring(e.id))) then
    sched.now("click", e.fn, e.widget)
  end
end

-- FAST loop while St.menu.visible. Two jobs:
--   1. the lobby's poll-based pad/keyboard navigation (lobby.pollNav; cfg.LobbyPadNav, default on): runs in every
--      ClickMode, because CommonUI focus never reached our rows in the first live run;
--   2. cfg.ClickMode == "poll": click detection (pad A through CommonUI, mouse) by the selected-toggle trick.
-- (main.lua's FAST loop calls this whenever St.menu.visible, in every ClickMode.)
function ui.pollClicks()
  -- focus keeper (lobby rows / builder): bounded window after every page show and menu re-activation
  if St.menu.visible == "lobby" or St.menu.visible == "builder" then
    U.tryEvery("ui.keepFocus", nil, TAG, function() U.mod("lobby").keepFocus() end)
  end
  -- the RACE SETUP flow (setup.lua) is driven by lobby.pollNav (P1 focus poll + guests' pads) even with LobbyPadNav off
  local setupOpen = false
  if St.menu.visible == "lobby" then
    local okS, a = pcall(function() return U.mod("setup").isActive() end)
    setupOpen = okS and a == true
  end
  if St.menu.visible == "lobby" and (opt("LobbyPadNav", true) ~= false or setupOpen) then
    U.tryEvery("ui.pollNav", nil, TAG, function() U.mod("lobby").pollNav() end)
  end
  if cfg.ClickMode ~= "poll" then return end
  -- Snapshot first: an action may rebuild the page (ui.forgetAll) while we iterate.
  local list = {}
  for k, e in pairs(St.ui.buttons) do list[#list + 1] = {k = k, e = e} end
  for i = 1, #list do
    local k, e = list[i].k, list[i].e
    U.tryEvery("ui.pollClicks", nil, TAG, function()
      local w = e.widget
      if not U.ok(w) then
        St.ui.buttons[k] = nil
        return
      end
      if w:GetSelected() == true then              -- GetSelected() -> Bool
        w:SetIsSelected(false, false)              -- SetIsSelected(Bool InSelected, Bool bGiveClickFeedback)
        -- 0.10.0 opts.noClaim (the RACERS P1 sink): every CommonUI click is one action; its owner attributes it
        if noClaim(e) then
          U.dbg(TAG, "poll click '%s' (noClaim)", tostring(e.id))
          if type(e.fn) == "function" then e.fn(w) end
          return
        end
        -- the same press already ran this row through the lobby's own navigation (pad A edge / Enter): CommonUI's
        -- click on release is that press, not a second one (dedup by press, not by time)
        local okC, consumed = pcall(function() return U.mod("lobby").consumedClick(e.id) end)
        if okC and consumed == true then
          U.dbg(TAG, "poll click '%s' dropped: same press as the lobby navigation action", tostring(e.id))
          return
        end
        U.dbg(TAG, "poll click '%s'", tostring(e.id))
        if type(e.fn) == "function" and ui.claimAction("click:" .. tostring(e.id)) then
          pcall(function() U.mod("lobby").noteClicked(e.id) end)   -- move the pad highlight to the clicked row
          e.fn(w)
        end
      end
    end)
  end
end

-- Called when a main-menu instance dies or is replaced: every registered widget belonged to it. The lobby's row
-- tables go too (they hold widgets of the same menu): lobby.build refills them for the next menu instance.
function ui.forgetAll()
  pcall(function() U.mod("lobby").resetNav() end)
  St.ui.buttons = {}
  St.ui.labels = {}
  St.ui.rows, St.ui.texts, St.ui.shown, St.ui.enabled = {}, {}, {}, {}
end

return ui
