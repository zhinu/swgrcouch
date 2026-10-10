-- hud.lua (G5): per-player race HUDs for local split-screen.
--   * P1's HUD (the game's, created by the race CSM through UIManager) is moved into P1's view ("rehost"),
--     hidden and replaced by a P1-owned copy ("clone"), or left alone ("leave")            [ARCH 1.6, HUD 7.2]
--   * every local guest gets a HUD of P1's class owned by the guest's PlayerController       [HUD 6 #1, 7.3]
--   * guest patches: lap text from the guest's own racer PlayerState + calibrated offset,
--     collapsed global-only parts, optional boost icons, optional position (takeover w/o adoption) [HUD 2, 4, 7.5]
--   * visibility follows the CSM (pause, post-race), cleanup on leaving the race           [HUD 3, 7.4]
--
-- Revision 2026-10-07 (session B: "UX of the top player was full screen and bottom not"; log: "P1 HUD not found
-- yet" for the whole race): the game's HUD is no longer filtered by its owner (it was on screen, both lookups ran
-- without error, so the owner test rejected it); its owner is logged once (V-HUD-02c) and set to P1 before a
-- rehost; the fallback searches the exact classes WBP_Hud_Race_C / WBP_Hud_Memory_C. Recommended mode now
-- cfg.P1HudMode = "clone" (P1 gets its own HUD owned by P1 in P1's view, the game's stays alive at opacity 0, with
-- the clone's input unregistered so P1's pause is not doubled). Guest HUDs are hidden while present.lua runs the race
-- on one full-screen view. notes/research/presentation.md.
-- Revision 2026-10-07 (run E, "it lagged after me being dead"; UE4SS-E6 ends with 364x "P1 HUD instance changed"): the
-- game's HUD was "changed" on EVERY MAIN tick (3-4/s, all race long, in every run E log): two wrappers of the same
-- widget did not compare equal, so each tick released the HUD (opacity 1) and re-placed it (opacity 0) and dropped the
-- member cache. Every identity test here now compares ADDRESSES (sameObj), a stale stored wrapper at the same address
-- is refreshed instead of re-placed, the change log is rate-limited (5 s) and a thrash (> HUD_SWAP_WARN per 10 s) is
-- reported once (V-HUD-14). A local player who is out of the race (wrecked / spectating) gets its HUD hidden
-- (cfg.HudOutPlayers, V-HUD-15); while the photo mode is open every HUD we host is hidden and no HUD work runs (V-HUD-16).
-- Static facts used here (all re-checked with scripts/reflect-func-all.py and work/bpprops, 2026-10-06):
--   UIManager:GetWidgetInLayer(Class widgetClass, Enum targetLayer) -> Object
--   UserWidget:AddToPlayerScreen(Int ZOrder) -> Bool        UserWidget:Register/UnregisterInputComponent()
--   UserWidget:SetOwningPlayer(Object LocalPlayerController), AddToViewport(Int ZOrder)
--   UIManager:AddExistingWidgetToLayer(Object widgetToAdd, Enum targetLayer)  (2 args; "Byte UnderlyingType" is
--     the enum's inner property, not a parameter [API 9])
--   TextBlock:GetText() -> Text
--   FuseScreenWidget:TransitionIn()  (BlueprintEvent, no params)
--   ContentWidget:GetContent() -> Object, SetContent(Object Content) -> Object(slot)
--   Widget:GetParent() -> Object, RemoveFromParent(), SetVisibility(Enum), GetVisibility() -> Enum,
--   SetRenderOpacity(Float), GetOwningPlayer() -> Object, UserWidget:IsInViewport() -> Bool
--   PanelWidget:GetChildrenCount() -> Int, GetChildAt(Int) -> Object
--   ViewModelSubsystem:GetRaceEventVM() -> Object; URaceEventVM.CurrentLapNumber/NumLaps (Int)
--   UPlayerRaceEventComponent.CurrentLapNumber/EventPosition (Int), IsStillRacing() -> Bool
--   WBP_Hud_EventLapCounter[_Memory]_C:UpdateCurrentLap() (BP, no params); var Txt_CurrentLap (FuseTextBlock)
-- Widget-tree facts that refine ARCHITECTURE 4.2 hud (bpprops, exports/hud/WBP_Hud_Memory.txt):
--   * WBP_HUD_RaceInfo_C has NO Blueprint variables, so `ri.WBP_Hud_EventLapCounter` etc. would be invalid
--     objects. Its children are reached by walking WidgetTree.RootWidget (names from the export listing).
--   * In WBP_Hud_Race_C only WBP_HUD_RaceInfo, WBP_HUD_BotEngineInfo, EventInfo, Hud_Notification_CrashFeed
--     are variables; WBP_VehicleMarkerContainer and the other notification containers are tree-only.
--   * WBP_Hud_Memory_C keeps WBP_Hud_EventLapCounter_memory (lower-case m), WBP_Hud_PositionMap,
--     Img_1DMap_MidSection, WBP_Hud_BestLapTime, WBP_Hud_EventTakedownCounter at its own top level, and has
--     WBP_HUD_BotEngineInfo_Memory instead of WBP_HUD_BotEngineInfo.
--   * The Memory lap counter's UpdateCurrentLap rewrites Txt_CurrentLap on EVERY Tick (no compare), so the
--     UpdateCurrentLap post-hook is what keeps the guest's lap visible there. The Race variant writes only when
--     the VM lap changes. For the Race variant the hook therefore writes only when the BP just rewrote the text
--     (its "Current Lap Number" variable moved) or the guest's own lap text changed (no per-frame FText / text
--     invalidation); the Memory variant is written on every hook call. Without that hook the MAIN-poll write
--     lasts one frame: the guest's Memory lap counter is collapsed instead of showing P1's lap (V-HUD-04b).
--   * P1 finishing first puts the race CSM in CSM_RF_LocalResults, which shows WBP_PostRace_Info_C through the
--     UIManager on the whole viewport [HUD§3.3]: cfg.LocalResultsMode hides it (or re-hosts it into P1's view)
--     while a local guest is still racing (V-HUD-13).
--   * Hot reload: guest-owned FuseHudWidgets of the previous Lua state are removed once per race (orphan sweep)
--     before our guest HUDs are created.
-- Revision 0.7.0 (2026-10-07, run H: "System malfunction / perfect landing and other screen. Are shared between
-- players. Each ux should be fully autonomous"; notes/research/ux-split-*.md):
--   * uxsplit.lua owns the per-player message routing and danger visuals. hud.lua gives it every HUD we host with its
--     notification containers (M.notifEntries), names the game's hidden HUD (M.gameHudWidget) and brackets every HUD
--     creation with uxsplit.hudCreating / hudCreated: Construct runs INSIDE AddToPlayerScreen, and the index remap
--     (BotEngineInfo's GetPlayerPawn(self, 0)) must know the widget before it is added.
--   * "clone" mode: the game's own hidden HUD (owned by the UIManager's player = P2 in a split race) gets its 1D map,
--     Img_1DMap_MidSection and countdown collapsed (global map MPC writes every frame, a third countdown beep) and its
--     BotEngineInfo bindings on P1's car are REMOVED instead of moved to the guest's car (cfg.UxSplitGameHud, V-UX-10).
--     sweepOrphanHuds never removes it (a mid-race hot reload used to: ux-split-inventory §1 item 6).
--   * Guest lap (run H: P2 showed LAP 2 on lap 1): the component lap is 0 before the first start-line crossing while
--     the VM shows 1, so the offset is taken only once P1's own lap is >= 1 (1 s after each change of it); until then
--     guests use offset 0; the display is clamped to 1..NumLaps (V-HUD-04).
--   * Guest BotEngineInfo "Vehicle State" is checked against the guest's car (index-remap evidence, else written,
--     V-UX-01); the radio-chatter portrait (one dialogue line for everybody) is hidden in guest HUDs
--     (cfg.UxSplitGuestHolo, V-UX-12); the arcade ramjet-distance / bonus-time counters joined cfg.GuestHudCollapse.
-- Revision 0.11.0 (2026-10-10, user: "HUD is bad on screen where width is 1/2, fix that."; notes/research/
-- hud-narrow-views.md): the 0.8.2 fit scaled the WHOLE HUD interior (top bar, centre, engine row: all of it sits in
-- SzB_InteriorScale > SzB_InteriorSize 3620 > HudWings_Bind) to 0.53 in a half-width view: tiny timer / LAP / POS on a
-- TV. A view narrower than cfg.HudNarrowBelow now gets a narrower interior (SzB_InteriorSize ~2000, the scale box fits
-- it by WIDTH, ScaleToFitX), so the top bar, centre messages and countdown run at ~0.96 at layout scale (crisp text);
-- the Race top bar is compacted to fit (timer / LAP / POS 197 units in, P1's 1D map at 0.6) and the engine row, wider
-- than half a screen, is render-scaled down (~0.79) with the radio portrait collapsed. The view size is computed from
-- the split layout (it is not readable from Lua); a wrong estimate changes the scale, never cuts: every row fits the
-- interior. Applied when a HUD is created and whenever its plan changes (F8 flip, a guest leaving, one view / split,
-- window resize); full-width views keep the designer layout. cfg.HudNarrowViews = "fit" is the 0.8.2 behaviour.
-- VERIFY(V-HUD-17/18/19).

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "hud"

-- names looked up in a HUD's widget tree (lower-cased when compared) -------------------------------
local LAP_NAMES = { "WBP_Hud_EventLapCounter", "WBP_Hud_EventLapCounter_memory" }
local POS_NAMES = { "WBP_Hud_EventCurrentPosition", "WBP_Hud_EventCurrentPosition_Memory" }
local BOT_NAMES = { "WBP_HUD_BotEngineInfo", "WBP_HUD_BotEngineInfo_Memory" }
local MARKER_NAMES = { "WBP_VehicleMarkerContainer" }
local NOTIF_NAMES = { "Hud_Notification_CrashFeed", "Hud_Notification_GameFeed", "WBP_Hud_Notification_Container",
                      "WBP_Hud_Notification_Container_1", "WBP_Hud_Takedown_Notification_Container" }
-- 0.7.0: members of the game's hidden HUD ("clone" mode) that write global state or play 2D sounds (cfg.UxSplitGameHud):
-- the 1D map writes MPC_HUD_Parameters every Tick, the countdown plays its 3/2/1/GO beeps (ux-split-inventory §1)
local GAME_HUD_NAMES = { "WBP_Hud_PositionMap", "Img_1DMap_MidSection", "WBP_Hud_Countdown" }
-- nested user widgets whose own tree is searched too (everything else is a leaf for the walk)
local DESCEND = { ["wbp_hud_raceinfo"] = true }
local WALK_MAX_NODES = 1500
local FALLBACK_SEARCH_MS = 2000
local HUD_SWAP_WARN = 6   -- P1 HUD instance changes per 10 s above which hud.lua reports a thrash

local VIS_SHOW = C.E.Vis.SelfHitTestInvisible
local VIS_HIDE = C.E.Vis.Collapsed
-- Layers searched for WBP_PostRace_Info_C (its CsmActionShowWidgetData.Layer is unversioned data [HUD§3.1]).
local RESULTS_LAYERS = { C.E.UILayer.Menu, C.E.UILayer.HUD, C.E.UILayer.MenuOverlay }

local panelCls, userWidgetCls -- cached UClasses (re-validated)

local function H() return St.hud end

-- phase.photoMode() (shared detection); false when phase.lua is older than this file.
local function photoActive()
    local ok, ph = pcall(U.mod, "phase")
    if ok and type(ph) == "table" and type(ph.photoMode) == "function" then
        local ok2, v, why = pcall(ph.photoMode)
        if ok2 then return v == true, why end
    end
    return false, nil
end

-- Identity by ADDRESS (run E 2026-10-07: "P1 HUD instance changed (<same path>); re-placing" 3-4x per second for the
-- whole race: the `==` of two wrappers of the same widget did not hold, so every MAIN tick released and re-placed the
-- game's HUD (opacity 1 -> 0 flicker, member cache dropped). U.key = UObject address; 0 = invalid.
local function sameObj(a, b)
    local ka = U.key(a)
    return ka ~= 0 and ka == U.key(b)
end
M._sameObj = sameObj

local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

-- 0.8.2 (live run L, 3 players, 2026-10-07): WBP_Hud_Race's top bar (timer, lap, position: HudWings_Bind) sits in
-- SzB_InteriorSize (FuseSizeBox WidthOverride 3620, RemoveApplicationScaling) inside SzB_InteriorScale (FuseScaleBox
-- Stretch None, StretchDirection DownOnly). A 3840-wide player view (1P, 2P halves, P1's 3P top half) holds it; a
-- quarter view (3P bottom, 4P) is 1920 wide, so the bar was centred and lost both ends (timer and POS cut). Stretch
-- ScaleToFit (DownOnly kept) shrinks it only where it does not fit. The scale box is no BP variable and
-- GetWidgetFromName is not a UFunction here: it is HudWings_Bind's grandparent (path checked).
-- Run M (live): ScaleToFit alone changed nothing: the scale box's own CanvasPanelSlot is a centre point anchor 3640
-- wide (Offsets L -1820 R 3640, T/B 48, anchors (0.5,0)-(0.5,1)), so it was never narrower than its content. The slot
-- is stretched to the player's view (anchors (0,0)-(1,1), offsets 0/48/0/48): the bar then scales down in a quarter
-- view and stays as it was (centred, unscaled) in a 3840-wide view. Live-verified 2026-10-07 23:16 (3P bottom views).
-- 0.11.0: ScaleToFitX under the narrow-view layout (only the view WIDTH sets the scale: the narrower interior of a
-- narrow view is then run at view width / interior width, and a 3840-wide view still gives exactly 1.0); ScaleToFit as in
-- 0.8.2 with cfg.HudNarrowViews = "fit".
-- VERIFY(V-HUD-15): 3 players: P2's and P3's timer and POS fully visible; P1's bar unchanged.
local function fitInterior(w, who)
    if cfg.HudFitInterior == false or not U.ok(w) then return false end
    local stretch = (cfg.HudNarrowViews == "fit") and C.E.Stretch.ScaleToFit or C.E.Stretch.ScaleToFitX
    local ok, err = pcall(function()
        local wing = w.HudWings_Bind
        if not U.ok(wing) then error("no HudWings_Bind") end
        local size = wing:GetParent()
        local sc = U.ok(size) and size:GetParent() or nil
        if not U.ok(sc) then error("no scale box above the top bar") end
        local p = U.pathOf(sc)
        if not p:find("SzB_InteriorScale", 1, true) then error("unexpected box " .. p) end
        local slot = sc.Slot                               -- CanvasPanelSlot in HUD_Container
        if not U.ok(slot) then error("no slot on the scale box") end
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })   -- stretch over the view
        slot:SetOffsets({ Left = 0, Top = 48, Right = 0, Bottom = 48 })              -- margins (designer T/B 48)
        sc:SetStretch(stretch)                             -- ScaleBox:SetStretch(Enum EStretch); StretchDirection stays DownOnly
    end)
    if ok then
        U.logOnce("hud.fit." .. tostring(who), TAG, "%s HUD top bar fits its view (%s, DownOnly) (V-HUD-15)",
            tostring(who), stretch == C.E.Stretch.ScaleToFitX and "ScaleToFitX" or "ScaleToFit")
    else
        U.logOnce("hud.fitfail", TAG, "HUD top bar fit unavailable (%s): quarter views may cut the timer / POS",
            tostring(err))
    end
    return ok
end
M._fitInterior = fitInterior

local function fnameLower(w)
    local ok, s = pcall(function() return w:GetFName():ToString() end)
    if ok and s then return string.lower(s) end
    return ""
end

local function classOk(cached, path)
    if cached and U.ok(cached) then return cached end
    local c = U.class(path)
    if U.ok(c) then return c end
    return nil
end

-- A Blueprint class only if it is ALREADY in memory (StaticFindObject, never LoadAsset): a HUD class that is not
-- loaded cannot have a live instance, and U.class would synchronously load the whole HUD dependency tree
-- mid-race from the MAIN poll.
local function loadedClass(path)
    if type(path) ~= "string" then return nil end
    local ok, c = pcall(StaticFindObject, path)
    if ok and U.ok(c) then return c end
    return nil
end

-- Breadth-first walk of a user widget's tree. Collects every widget whose (lower-case) name is wanted, as
-- found[name] = {w1, w2, ...} in BFS order (shallowest first). The Memory HUD has e.g. a lap counter at its top
-- level AND (inside its WBP_HUD_RaceInfo) another one: both are patched/collapsed.
-- Descends into PanelWidgets (ContentWidget/NamedSlot/RetainerBox/... are PanelWidgets too) and into the
-- WidgetTree of nested user widgets listed in DESCEND.                                          [UI 1.3]
local function collect(rootUserWidget, wanted)
    local found = {}
    panelCls = classOk(panelCls, "/Script/UMG.PanelWidget")
    userWidgetCls = classOk(userWidgetCls, "/Script/UMG.UserWidget")
    if not panelCls then
        U.logOnce("hud.nopanel", TAG, "UMG PanelWidget class not resolvable; widget-tree walk disabled")
        return found
    end
    local queue, head, visited = {}, 1, 0
    local function pushTree(uw)
        local tree = uw.WidgetTree
        if U.ok(tree) then
            local r = tree.RootWidget
            if U.ok(r) then queue[#queue + 1] = r end
        end
    end
    pushTree(rootUserWidget)
    while head <= #queue and visited < WALK_MAX_NODES do
        local w = queue[head]; head = head + 1; visited = visited + 1
        local n = fnameLower(w)
        if wanted[n] then
            local l = found[n]
            if not l then l = {}; found[n] = l end
            l[#l + 1] = w
        end
        if w:IsA(panelCls) then
            local cnt = w:GetChildrenCount()
            for i = 0, (cnt or 0) - 1 do
                local ch = w:GetChildAt(i)
                if U.ok(ch) then queue[#queue + 1] = ch end
            end
        elseif DESCEND[n] and userWidgetCls and w:IsA(userWidgetCls) then
            pushTree(w)
        end
    end
    if visited >= WALK_MAX_NODES then
        U.logOnce("hud.walkcap", TAG, "widget-tree walk hit the %d-node cap", WALK_MAX_NODES)
    end
    return found
end

-- true when x's outer chain reaches w (member -> WidgetTree -> UserWidget, or deeper through a nested
-- WBP_HUD_RaceInfo: member -> its tree -> RaceInfo -> HUD tree -> HUD). UObject:GetOuter() is a UE4SS built-in.
local function ownedBy(x, w)
    local o = x
    for _ = 1, 6 do
        local ok, nxt = pcall(function() return o:GetOuter() end)
        if not ok or not U.ok(nxt) then return false end
        if sameObj(nxt, w) then return true end
        o = nxt
    end
    return false
end

-- A cache hit must prove it describes THIS instance: `U.same(e.widget, w)` alone is always true for an entry
-- looked up by address (UE4SS `==` compares pointers), so a new widget at a freed HUD's address would inherit
-- the dead HUD's members. Checked: same class, same WidgetTree address, every cached member alive, and the
-- first member's outer chain leads to w.
local function cacheValid(e, w)
    if not (e and sameObj(e.widget, w)) then return false end
    local okC, cls = pcall(function() return w:GetClass() end)
    if not okC or U.key(cls) ~= e.clsKey then return false end
    local okT, tree = pcall(function() return w.WidgetTree end)
    if not okT or U.key(tree) ~= e.treeKey then return false end
    local m = e.m
    local probe
    for _, list in ipairs({ m.laps, m.poss }) do
        for _, x in ipairs(list) do
            if not U.ok(x) then return false end
            probe = probe or x
        end
    end
    for _, x in ipairs({ m.bot or false, m.markers or false }) do
        if x then
            if not U.ok(x) then return false end
            probe = probe or x
        end
    end
    -- VERIFY(V-HUD-12): a tree widget's outer chain is member -> WidgetTree -> UserWidget (nested user widgets
    -- likewise). If not, every hit fails here and the tree is re-walked each poll (correct, just slower: look for
    -- repeated "member cache ... stale" debug lines and drop this probe).
    if probe and not ownedBy(probe, w) then return false end
    return true
end

local function forget(w)
    local h = H()
    if h and h.found and w ~= nil then
        local k = U.key(w)
        if k ~= 0 then h.found[k] = nil end
    end
end

-- Resolve every member we need for one HUD instance, once (cached in St.hud.found by widget address and
-- validated on every hit, see cacheValid).
local function membersOf(w)
    local h = H()
    h.found = h.found or {}
    local k = U.key(w)
    local e = h.found[k]
    if e then
        if cacheValid(e, w) then return e.m end
        h.found[k] = nil
        U.dbg(TAG, "member cache for %s was stale (address reused); re-walking", U.pathOf(w))
    end
    local wanted = {}
    local function want(list) for _, n in ipairs(list) do wanted[string.lower(n)] = true end end
    want(LAP_NAMES); want(POS_NAMES); want(BOT_NAMES); want(MARKER_NAMES); want(NOTIF_NAMES); want(GAME_HUD_NAMES)
    want(cfg.GuestHudCollapse or {})
    local ok, f = U.try(TAG, collect, w, wanted)
    local m = (ok and f) or {}
    local function all(list)
        local out = {}
        for _, n in ipairs(list) do
            for _, x in ipairs(m[string.lower(n)] or {}) do if U.ok(x) then out[#out + 1] = x end end
        end
        return out
    end
    local function first(list) return all(list)[1] end
    local res = {
        raw = m,            -- lower-case name -> {widgets}
        laps = all(LAP_NAMES),
        poss = all(POS_NAMES),
        bot = first(BOT_NAMES),
        markers = first(MARKER_NAMES),
    }
    res.lap = res.laps[1]
    -- variables are cheaper and exact when they exist (Race HUD: WBP_HUD_BotEngineInfo)
    if not res.bot then
        for _, n in ipairs(BOT_NAMES) do local x = w[n]; if U.ok(x) then res.bot = x; break end end
    end
    local okC, cls = pcall(function() return w:GetClass() end)
    local okT, tree = pcall(function() return w.WidgetTree end)
    h.found[k] = { widget = w, m = res, clsKey = okC and U.key(cls) or 0, treeKey = okT and U.key(tree) or 0 }
    U.dbg(TAG, "members of %s: laps=%d pos=%d bot=%s markers=%s", U.pathOf(w), #res.laps, #res.poss,
        tostring(res.bot ~= nil), tostring(res.markers ~= nil))
    return res
end
M._membersOf = membersOf -- for diag only

---------------------------------------------------------------------------------------------------- narrow views
-- 0.11.0 (header; notes/research/hud-narrow-views.md §2, §5-§8). SzB_InteriorScale > SzB_InteriorSize > HudWings_Bind
-- holds the WHOLE HUD, so a narrow view gets a narrower interior (Wn) that the scale box (ScaleToFitX) runs at
-- view width / Wn. Text keeps the layout scale (Slate rasterises glyphs at the accumulated layout scale; a render
-- transform only stretches the quads), so only the engine row and P1's 1D map (graphics) are render-scaled, and only
-- DOWN. Every row is sized to fit Wn, never the view: a wrong view estimate changes the achieved scale, never cuts.
-- Designer values in UI units [V: decoded WBP_Hud_Race, WBP_HUD_RaceInfo, WBP_HUD_BotEngineInfo, WBP_Hud_Memory trees]:
local INTERIOR_W = 3620                           -- SzB_InteriorSize.WidthOverride (Memory: FuseSizeBox_0 / _1 too)
local FULL_VIEW = { w = 3840, h = 2160 }          -- the full viewport in units when it cannot be read (16:9)
local BOT_MARGIN = 44                             -- WBP_HUD_BotEngineInfo slot Left / Right
local BOT_ROW_W = { hide = 2417, keep = 2767 }    -- its HB_Container width without / with the radio portrait (350 + 32)
local ROW_BOTTOM = 12                             -- C_BotLayout, and so the engine row, ends 12 units below the interior
local TOP_HALF = { native = 1170, compact = 1000 } -- top bar half width + the 75-unit HUD sway (UFuseHudWidget::NativeTick)
local TOP_SHIFT = 197                             -- compact bar: blocks this much further in, flat middle 2 x 197 shorter
-- WBP_HUD_RaceInfo > C_TopLayout children (CanvasPanelSlot, anchors (0.5,0)): designer position / size + compact delta.
-- The brackets' and the shadow's box margins (L 0.9 / R 0.1) keep their outer steps: only the flat middle shortens.
local TOP_SLOTS = {
    WBP_Hud_EventTotalTime       = { pos = { X = -905, Y = 50 }, d = TOP_SHIFT },         -- timer
    WBP_Hud_EventLapCounter      = { pos = { X = 612, Y = 40 }, d = -TOP_SHIFT },         -- LAP
    WBP_Hud_EventCurrentPosition = { pos = { X = 847.9174, Y = 40 }, d = -TOP_SHIFT },    -- POS
    HB_Layout_BackerLine         = { size = { X = 2180, Y = 128 }, d = -2 * TOP_SHIFT },  -- bracket lines
    HB_TopBar_Layout_Shadow      = { size = { X = 2340, Y = 260 }, d = -2 * TOP_SHIFT },  -- shadow glow
}
local MAP_COMPACT = 0.6                           -- P1's 1D map (980 wide): the designer gaps to timer and LAP are kept
-- render pivot at Img_1DMap_MidSection's height (T 101.17 in the 170-tall map box at T 36): the map image sits 14 units
-- up in its box, so scaling about the box centre would move the map's line off the centre mark
local MAP_PIVOT = { X = 0.5, Y = (101.17123 - 36) / 170 }
local RAMJET_MSG = { X = 994.622, Y = -340, halfW = 153 }  -- WBP_Hud_RamjetMessage: anchor (0.5,1), 306 x 157, centred
local RAMJET_FROM_RIGHT = { hide = 537, keep = 887 }       -- the ramjet bar's centre from the engine row's right end
local CRASHES_BOT = { X = 714.63654, Y = -119.747795 }     -- WBP_HUD_Crashes_Bot: anchor (0,1) of C_BotLayout
-- a measured Race engine row replaces the estimate when it is more than tol and at most dev units WIDER (Q2: the energy
-- pips vary by about 20; a reading 350 wider would be the portrait, which no BP ever shows again once collapsed)
local ROW_MEASURE = { tol = 4, dev = 150 }
local PROBE_TICKS = 40                            -- V-HUD-19: MAIN ticks a probe waits for its HUD to be drawn
local narrowOff = nil                             -- why the narrow layout is off for this session (V-HUD-19), or nil

-- WBP_HUD_RaceInfo's C_TopLayout children by name (RaceInfo has no BP variables: its tree root's direct children).
local function topBarParts(ri)
    local out = {}
    if not U.ok(ri) then return out end
    local tree = ri.WidgetTree
    local root = U.ok(tree) and tree.RootWidget or nil
    if not U.ok(root) then return out end
    for i = 0, (root:GetChildrenCount() or 0) - 1 do   -- PanelWidget:GetChildrenCount() -> Int, GetChildAt(Int)
        local ch = root:GetChildAt(i)
        if U.ok(ch) then out[ch:GetFName():ToString()] = ch end
    end
    return out
end

-- UWidget.Slot (a CanvasPanelSlot for every widget moved here); nil when the widget or its slot is invalid.
local function slotOf(x)
    if not U.ok(x) then return nil end
    local s = x.Slot
    if U.ok(s) then return s end
    return nil
end

-- Two number fields of a struct return value (UE4SS gives a table [API§9]; read through pcall + tonumber like
-- subsplit's viewport read, so a struct wrapper would do as well). nil, nil when unreadable.
local function fields2(v, a, b)
    local ok, x, y = pcall(function() return tonumber(v[a]), tonumber(v[b]) end)
    if ok then return x, y end
    return nil, nil
end

-- BotEngineInfo's radio-chatter portrait (a BP variable in both HUD variants), nil when absent.
local function holoOf(bot)
    if not U.ok(bot) then return nil end
    for _, n in ipairs({ "WBP_Hud_CharacterHolo", "WBP_Hud_CharacterHolo_Memory" }) do
        local ok, x = pcall(function() return bot[n] end)
        if ok and U.ok(x) then return x end
    end
    return nil
end

-- Every local player's view in UI units by lp.index, the full screen, and whether the race runs on one view. The view
-- itself is not readable (ULocalPlayer Origin/Size and FGeometry are not reflected, hud-narrow-views §6): the engine's
-- default SplitscreenInfo for the layout split.lua writes, times the viewport size / DPI scale.
local function viewSizes(lps)
    local single = St.race.singleView == true          -- join's race_enter guard: one view by design
    local present = lazy("present")
    if not single and present and present.isSingleView then
        local ok, s = pcall(present.isSingleView)
        single = ok and s == true
    end
    local full = { w = FULL_VIEW.w, h = FULL_VIEW.h }
    pcall(function()
        local wll, world = U.cdo("WidgetLayoutLibrary"), U.world()
        if not (U.ok(wll) and U.ok(world)) then return end
        local px, py = fields2(wll:GetViewportSize(world), "X", "Y")   -- GetViewportSize(Object) -> Vector2D (px)
        local dpi = wll:GetViewportScale(world)        -- WidgetLayoutLibrary:GetViewportScale(Object) -> Float (DPI)
        if px and py and px > 0 and py > 0 and type(dpi) == "number" and dpi > 0 then
            full.w, full.h = px / dpi, py / dpi        -- 3840 x 2160 at 16:9 whatever the resolution (live: subsplit)
        end
    end)
    local twoP = C.E.TwoP.Horizontal
    pcall(function()
        local g = U.GMS()
        if U.ok(g) then twoP = g.TwoPlayerSplitscreenLayout end   -- Byte, written by split.applyLayoutSettings
    end)
    local n, views = #lps, {}
    for _, lp in ipairs(lps) do
        local fw, fh = 1, 1
        if n == 2 then
            if twoP == C.E.TwoP.Vertical then fw = 0.5 else fh = 0.5 end   -- side by side | top / bottom
        elseif n == 3 then
            fh = 0.5
            if lp.index > 1 then fw = 0.5 end          -- FavorTop: P1 across the top, P2 / P3 below
        elseif n >= 4 then
            fw, fh = 0.5, 0.5                          -- Grid
        end
        views[lp.index] = { w = fw * full.w, h = fh * full.h }
    end
    return views, full, single
end
M._viewSizes = viewSizes -- for diag / tests

-- The layout of one HUD in a view v = {w, h} (units): { key = "W" } = the designer layout, else the narrow plan (§5.1):
--   e   top bar / centre scale = HudNarrowScale (<= 1), capped so the top bar plus sway keeps inside the view
--   wn  interior width: ScaleToFitX runs it at v.w / wn = e
--   r   engine-row render scale (<= 1): the row's visual width is wn - 2 x 44
-- kind "race" | "memory"; holoShown: the radio portrait stays in the engine row; rowW: the row's measured width or nil.
local function narrowPlan(v, kind, holoShown, rowW)
    if narrowOff or not (v.w > 0) or v.w >= (tonumber(cfg.HudNarrowBelow) or 3000) then return { key = "W" } end
    local tgt = math.min(tonumber(cfg.HudNarrowScale) or 1, 1)
    if not (tgt > 0) then tgt = 1 end
    local top, e = "row", tgt                          -- Memory HUD: its top row is a size box that follows the interior
    if kind == "race" then
        top = (cfg.HudNarrowTopBar ~= "native" and v.w / (2 * TOP_HALF.native) < tgt) and "compact" or "native"
        e = math.min(tgt, v.w / (2 * TOP_HALF[top]))
    end
    local wn = math.ceil(v.w / e - 1e-6)
    local holo = holoShown and "keep" or "hide"
    local row = rowW or BOT_ROW_W[holo]
    local r = math.min(1, (wn - 2 * BOT_MARGIN) / row)
    return { key = string.format("N%d:%s:%s:%d:%.3f", wn, top, holo, row, r), wn = wn, e = e, top = top, holo = holo,
             row = row, r = r }
end
M._narrowPlan = narrowPlan -- for diag / tests

-- Apply a plan to one HUD. EVERY value is set in both directions ("W" = designer), so an apply is idempotent and
-- repairs a half-applied state. Everything is resolved before the first write (a missing part changes nothing), and
-- the interior narrows last and widens first: a failure in between never leaves a row wider than the interior.
local function applyLayout(w, plan, st, kind, holoHidden)
    local narrow = plan.key ~= "W"
    local wn, r = narrow and plan.wn or INTERIOR_W, narrow and plan.r or 1
    local wing = w.HudWings_Bind                       -- UFuseHudWidget.HudWings_Bind (native property, both variants)
    if not U.ok(wing) then error("no HudWings_Bind") end
    local size = wing:GetParent()
    if not (U.ok(size) and U.pathOf(size):find("SzB_InteriorSize", 1, true)) then
        error("no SzB_InteriorSize above HudWings_Bind")
    end
    local parts, rows = {}, {}
    if kind == "race" then
        parts = topBarParts(w.WBP_HUD_RaceInfo)        -- BP variable
        if narrow and plan.top == "compact" then
            for name in pairs(TOP_SLOTS) do
                if not slotOf(parts[name]) then error("top bar part " .. name .. " not found") end
            end
        end
    else
        for i = 0, (wing:GetChildrenCount() or 0) - 1 do   -- Memory: top row and decor line, direct children
            local ch = wing:GetChildAt(i)
            local n = U.ok(ch) and fnameLower(ch) or ""
            if n == "fusesizebox_0" or n == "fusesizebox_1" then rows[n] = ch end
        end
        if narrow and not rows.fusesizebox_1 then error("Memory top row FuseSizeBox_1 not found") end
    end
    local bot = membersOf(w).bot
    local bslot = slotOf(bot)
    if narrow and not bslot then error("no WBP_HUD_BotEngineInfo slot") end
    local offTop, offBottom                            -- CanvasPanelSlot:GetOffsets() -> Margin (Race T 0, Memory T -88)
    if bslot then
        offTop, offBottom = fields2(bslot:GetOffsets(), "Top", "Bottom")
        if not (offTop and offBottom) then error("BotEngineInfo slot offsets unreadable") end
    end
    if not narrow then size:SetWidthOverride(wn) end   -- SizeBox:SetWidthOverride(Float)
    if kind == "race" then
        local compact = narrow and plan.top == "compact"
        for name, d in pairs(TOP_SLOTS) do
            local slot = slotOf(parts[name])
            if slot and d.pos then                     -- CanvasPanelSlot:SetPosition(Vector2D) = Offsets Left / Top
                slot:SetPosition({ X = d.pos.X + (compact and d.d or 0), Y = d.pos.Y })
            elseif slot then                           -- CanvasPanelSlot:SetSize(Vector2D) = Offsets Right / Bottom
                slot:SetSize({ X = d.size.X + (compact and d.d or 0), Y = d.size.Y })
            end
        end
        local map = parts.WBP_Hud_PositionMap          -- P1 only (collapsed in guests); drawn in UV space: render scale
        if U.ok(map) then
            local m = compact and MAP_COMPACT or 1
            map:SetRenderTransformPivot(MAP_PIVOT)     -- Widget:SetRenderTransformPivot(Vector2D)
            map:SetRenderScale({ X = m, Y = m })       -- Widget:SetRenderScale(Vector2D)
        end
        local msg = slotOf(w.WBP_Hud_RamjetMessage)    -- BP variable (Race only)
        if msg then
            local x, y = RAMJET_MSG.X, RAMJET_MSG.Y
            if narrow and RAMJET_MSG.X + RAMJET_MSG.halfW > wn / 2 - BOT_MARGIN then
                x = (plan.row / 2 - RAMJET_FROM_RIGHT[plan.holo]) * r   -- over the shrunk ramjet bar's centre
            end
            if narrow then y = ROW_BOTTOM - (ROW_BOTTOM - RAMJET_MSG.Y) * r end   -- same height over the shrunk row
            msg:SetPosition({ X = x, Y = y })
        end
    else
        for _, ch in pairs(rows) do ch:SetWidthOverride(wn) end
    end
    local cb = slotOf(w.WBP_HUD_Crashes_Bot)           -- BP variable, the same slot in both variants: kept over the row
    if cb then cb:SetPosition({ X = BOT_MARGIN + (CRASHES_BOT.X - BOT_MARGIN) * r, Y = CRASHES_BOT.Y * r }) end
    if bslot then
        -- a shrunk row's layout box is its own width (its Fill spacer then cannot push the ramjet end past the edge),
        -- render-scaled about its bottom centre to wn - 88 wide
        local side = (r < 1) and (wn - plan.row) / 2 or BOT_MARGIN
        bslot:SetOffsets({ Left = side, Top = offTop, Right = side, Bottom = offBottom })   -- CanvasPanelSlot:SetOffsets
        bot:SetRenderTransformPivot({ X = 0.5, Y = 1 })
        bot:SetRenderScale({ X = r, Y = r })
    end
    -- the radio portrait: collapsed while narrow, its visibility given back when wide. Re-collapsed every tick by
    -- layoutHud like collapseGlobalParts' parts, although no BP writes its own visibility (decoded: the holo BP only
    -- toggles its Img_Empty / Img_Character children). A guest's is already hidden by collapseGlobalParts (holoHidden).
    local holo = holoOf(bot)
    if holo and narrow and plan.holo == "hide" and not holoHidden then
        if st.holoVis == nil then st.holoVis = holo:GetVisibility() end   -- Widget:GetVisibility() -> Enum
        holo:SetVisibility(VIS_HIDE)
        st.holo = holo
    elseif st.holoVis ~= nil then
        if holo then holo:SetVisibility(st.holoVis) end
        st.holo, st.holoVis = nil, nil
    end
    if narrow then size:SetWidthOverride(wn) end
end

-- V-HUD-19, from the MAIN tick after a narrow apply, once the HUD is drawn (a collapsed HUD keeps stale desired sizes):
-- SzB_InteriorSize must report our width override (Q1: the Fuse size box removes the application scale). Narrower than
-- planned would cut the rows: the narrow layout then goes off for the session (every HUD back to the 0.8.2 fit). Wider
-- only makes the HUD smaller (logged). The Race engine row's real width replaces the estimate when it is wider (Q2: the
-- energy pips depend on the car): re-planned on the next tick.
-- VERIFY(V-HUD-19): "interior 2000 wide, 2000 planned; engine row 2417 wide" one tick after the narrow apply. Fallback:
-- cfg.HudNarrowViews = "fit" (taken automatically for the session when the interior reads narrower).
local function probeLayout(w, who, st)
    local p = st.probe
    p.n = p.n + 1
    if p.n > PROBE_TICKS then
        st.probe = nil
        U.dbg(TAG, "%s HUD: V-HUD-19 probe dropped (not drawn for %d ticks)", who, PROBE_TICKS)
        return
    end
    if w:GetVisibility() == VIS_HIDE then return end
    local wing = w.HudWings_Bind
    local size = U.ok(wing) and wing:GetParent() or nil
    if not U.ok(size) then return end
    local x = fields2(size:GetDesiredSize(), "X", "Y") -- Widget:GetDesiredSize() -> Vector2D (last layout pass)
    if not (x and x > 0) then return end               -- not laid out yet
    local bx
    local bot = st.kind == "race" and membersOf(w).bot or nil
    if U.ok(bot) then bx = fields2(bot:GetDesiredSize(), "X", "Y") end
    if x < p.wn - 2 then
        p.bad = p.bad + 1
        if p.bad < 3 then return end                   -- three draws in a row: not a stale value
        st.probe = nil
        narrowOff = string.format("%s HUD interior %.0f wide, %d planned", who, x, p.wn)
        U.warn(TAG, "%s HUD: SzB_InteriorSize reports %.0f, %d planned: the Fuse size box changes the width override "
            .. "(V-HUD-19 FAILED); narrow-view layout off for this session, every HUD fitted to its view as in 0.8.2 "
            .. "(cfg.HudNarrowViews = \"fit\" keeps it off)", who, x, p.wn)
        return
    end
    st.probe = nil
    U.log(TAG, "%s HUD: interior %.0f wide, %d planned%s; engine row %s wide, %d planned (V-HUD-19)", who, x, p.wn,
        x > p.wn + 2 and " (wider: the HUD is smaller than planned, nothing cut)" or "",
        bx and string.format("%.0f", bx) or "?", p.row)
    -- review 0.11.0: only a WIDER row is re-planned. A box narrowed to a reading taken while the row was short (energy
    -- pips not built yet, a part hidden for a moment) would let the row overflow it later and push the ramjet end past
    -- the interior; a narrower row in the estimate's box only leaves it a little smaller (never cut).
    local dev = bx and (bx - p.row) or 0
    if dev > ROW_MEASURE.tol and dev <= ROW_MEASURE.dev then
        st.rowW = st.rowW or {}
        st.rowW[p.holo] = math.ceil(bx)
        U.log(TAG, "%s HUD: engine row measured %d wide (estimate %d): re-planned", who, st.rowW[p.holo], p.row)
    end
end

-- One HUD we host: compare its plan with the applied one and apply on a change (V-HUD-17 narrow, V-HUD-18 designer),
-- run the V-HUD-19 probe after a narrow apply, keep the portrait collapsed. st = the HUD's layout record (a guest
-- entry's .layout, h.gameLayout). Callers wrap it in U.try / U.tryEvery.
-- VERIFY(V-HUD-17): 2P side by side logs "P2 HUD: narrow view 1920x2160: interior 2000 (scale 0.96), top bar compact,
-- engine row x0.79"; on screen timer / LAP / POS ~1.8x their 0.10.0 size, no view edge touched, the whole engine row
-- visible. Fallback: cfg.HudNarrowViews = "fit".
local function layoutHud(w, who, v, st, holoHidden)
    if cfg.HudFitInterior == false or cfg.HudNarrowViews ~= "readable" or not (U.ok(w) and v and st) then return end
    local wk = U.key(w)
    if st.widgetKey ~= wk then                         -- another instance under this record: start over
        for k in pairs(st) do st[k] = nil end
        st.widgetKey = wk
    end
    if st.kind == nil then
        local p = U.pathOf(w:GetClass())
        st.kind = (p == C.BP.HudRace and "race") or (p == C.BP.HudMemory and "memory") or "other"
        if st.kind == "other" then
            U.logOnce("hud.layoutkind." .. p, TAG, "%s HUD: no narrow-view layout for %s (fit only)", who, p)
        end
    end
    if st.kind == "other" then return end
    local holoShown = cfg.HudNarrowHolo == "keep" and not holoHidden
    local plan = narrowPlan(v, st.kind, holoShown, st.rowW and st.rowW[holoShown and "keep" or "hide"])
    local applied = false
    if st.key ~= plan.key and st.failKey ~= plan.key then
        if st.tryKey ~= plan.key then st.tryKey, st.fails = plan.key, 0 end
        local ok, err = pcall(applyLayout, w, plan, st, st.kind, holoHidden)
        if ok then
            applied, st.key, st.probe = true, plan.key, nil
            if plan.key == "W" then
                U.log(TAG, "%s HUD: view %.0fx%.0f, designer layout (V-HUD-18)", who, v.w, v.h)
            else
                st.probe = { wn = plan.wn, row = plan.row, holo = plan.holo, n = 0, bad = 0 }
                U.log(TAG, "%s HUD: narrow view %.0fx%.0f: interior %d (scale %.2f), top bar %s, engine row x%.2f%s "
                    .. "(V-HUD-17)", who, v.w, v.h, plan.wn, plan.e,
                    plan.top == "row" and "row at the interior width (Memory)" or plan.top, plan.r,
                    st.holo ~= nil and ", portrait hidden" or "")
            end
        else
            st.fails = st.fails + 1
            U.logEvery("hud.layoutfail", 5000, TAG, "%s HUD layout %s failed (%d/3): %s", who, plan.key, st.fails,
                tostring(err))
            if st.fails >= 3 then
                st.failKey = plan.key
                -- the fallback is the 0.8.2 fit: the designer interior, scaled to the view by fitInterior's box
                if plan.key ~= "W" and pcall(applyLayout, w, { key = "W" }, st, st.kind, holoHidden) then st.key = "W" end
                U.logOnce("hud.layoutoff." .. tostring(who), TAG, "%s HUD: narrow-view layout unavailable (%s); the "
                    .. "whole HUD is fitted to its view as in 0.8.2", who, tostring(err))
            end
        end
    end
    if not applied and st.probe then probeLayout(w, who, st) end
    if st.holo ~= nil then
        if U.ok(st.holo) then
            if st.holo:GetVisibility() ~= VIS_HIDE then st.holo:SetVisibility(VIS_HIDE) end
        else
            st.holo, st.holoVis = nil, nil
        end
    end
end
M._layoutHud = layoutHud -- for diag / tests

-- One HUD entry we host (a guest's or P1's clone) in its player's view; P1's covers the screen in one-view phases.
local function layoutEntry(e, idx, views, full, single)
    local v = (single and idx == 1) and full or views[idx]
    if not (v and U.ok(e.widget)) then return end
    e.layout = e.layout or {}
    U.tryEvery("hud.layout", nil, TAG, layoutHud, e.widget, "P" .. tostring(e.pnum), v, e.layout,
        e.pnum ~= 1 and cfg.UxSplitGuestHolo ~= "keep")
end

-- The game's own HUD (re-hosted into P1's view) gets its designer layout back before we let go of it (our guest HUDs
-- and P1's clone are removed instead). Clears h.gameLayout.
local function releaseGameLayout(h, w)
    local st = h.gameLayout
    h.gameLayout = nil
    if st and st.key ~= nil and st.key ~= "W" and st.kind ~= nil and U.ok(w) and st.widgetKey == U.key(w) then
        U.try(TAG, applyLayout, w, { key = "W" }, st, st.kind, false)
    end
end


local eqWarned = false
-- VERIFY(V-HUD-14): logged at most once per session when UE4SS `==` and the address disagree.
local function noteEqMismatch(a, b, what)
    if eqWarned or not (U.ok(a) and U.ok(b)) then return end
    if sameObj(a, b) and not (a == b) then
        eqWarned = true
        U.warn(TAG, "V-HUD-14: two wrappers of %s compare unequal with == (same address 0x%x); identity is compared "
            .. "by address in hud.lua", tostring(what), U.key(a))
    end
end

local function isOurs(w)
    local k = U.key(w)
    if k == 0 then return false end
    for _, e in pairs(H().guests) do
        if U.key(e.widget) == k then return true end
    end
    return false
end

-- Who owns a widget, for the log: "P1", "P<n> (guest)", "none", or "other <path>" (a PC that is no local player,
-- e.g. a stale PC of the previous world).
local function ownerDesc(w)
    local okO, owner = pcall(function() return w:GetOwningPlayer() end) -- UWidget:GetOwningPlayer() -> Object
    if not okO or not U.ok(owner) then return "none", nil end
    for _, lp in ipairs(U.localPlayers()) do
        if sameObj(lp.pc, owner) then
            if lp.index == 1 then return "P1", owner end
            return string.format("P%d (guest, ctrlId %s)", lp.index, tostring(lp.ctrlId)), owner
        end
    end
    return "other " .. U.pathOf(owner), owner
end

-- 2026-10-07 session B: "P1 HUD not found yet" for the whole race although the game's WBP_Hud_Race_C was on screen
-- (race-04.png). Both lookups (UIManager:GetWidgetInLayer and the FindAllOf("FuseHudWidget") fallback) ran without
-- an error, so the only filter that can have rejected it is the old owner test "owner invalid or == P1": the game's
-- HUD is owned by some other valid object (a guest PC, or a stale PC). The owner no longer filters the game's HUD;
-- it is logged once per instance (V-HUD-02c answer) and fixed to P1 where the HUD is moved into P1's view.
local loggedHud = {}
local function noteGameHud(w, how)
    local k = U.key(w)
    if loggedHud[k] then return end
    loggedHud[k] = true
    fitInterior(w, "game")                                -- P1's view in 4P is a quarter too (rehost / leave modes)
    local desc = ownerDesc(w)
    local okV, inVp = pcall(function() return w:IsInViewport() end)
    local okP, par = pcall(function() return w:GetParent() end)
    -- VERIFY(V-HUD-02c): which object owns the UIManager-created race HUD (expected P1; session B suggests not).
    U.log(TAG, "game HUD %s via %s: owner=%s inViewport=%s parent=%s", U.pathOf(w), how, desc,
        tostring(okV and inVp), (okP and U.ok(par)) and U.pathOf(par) or "none")
end

-- The race-HUD classes that are in memory (never LoadAsset), with their short class names for FindAllOf.
local HUD_CLASS_KEYS = { { key = "HudRace", short = "WBP_Hud_Race_C" }, { key = "HudMemory", short = "WBP_Hud_Memory_C" } }

-- Forget a P1 HUD instance we had placed (the CSM replaced it, or the race is over).
local function releaseP1(old)
    local h = H()
    releaseGameLayout(h, old) -- 0.11.0: designer layout back (before forget: it reads the member cache)
    forget(old) -- its cache entry must not outlive it (address reuse, see cacheValid)
    if U.ok(old) then
        U.try(TAG, function()
            if cfg.P1HudMode == "rehost" and h.p1Placed then
                old:RemoveFromParent() -- it sits on P1's player screen; the CSM no longer tracks it
            elseif cfg.P1HudMode == "clone" then
                old:SetRenderOpacity(1.0)
            end
        end)
    end
    h.p1hud, h.p1Placed, h.p1PlacedKey, h.p1hudKey = nil, false, 0, nil
end

-- P1 HUD mode in effect: cfg.P1HudMode, except that a failed rehost turns into "leave" for the rest of the race.
local function p1Mode()
    local h = H()
    if cfg.P1HudMode == "rehost" and h and h.rehostFailed then return "leave" end
    return cfg.P1HudMode
end

-- true while the game's HUD sits re-hosted in P1's view. Removing a UserWidget runs NativeDestruct ->
-- StopListeningForAllInputActions, which drops its InputComponent; the HUD's Enhanced-Input delegate bindings
-- (IA_Veh_Pause / IA_Veh_Player [HUD§3.2]) are made once at initialisation, so after the re-host P1's pause may only
-- work through pause.lua's P1 poll (cfg.P1PausePoll). VERIFY(V-PAU-03).
function M.p1Rehosted()
    local h = H()
    return h ~= nil and p1Mode() == "rehost" and h.p1Placed == true and U.ok(h.p1hud)
end

-- Find P1's HUD. Queried every call (2 UFunction calls) so that a NEW instance made by the CSM (e.g. the
-- Countdown_InHud -> InProgress_InHud hand-over) replaces a cached one we already moved.          [HUD 8]
function M.findP1Hud()
    local h = H()
    local p1 = U.p1()
    if not U.ok(p1) then return nil end
    local found
    local mgr = U.giSubsystem("UIManager")
    if U.ok(mgr) then
        for _, hc in ipairs(HUD_CLASS_KEYS) do
            local cls = loadedClass(C.BP[hc.key]) -- never LoadAsset here (unused HUD BP + dependency tree)
            if cls then
                -- VERIFY(V-HUD-01): UIManager:GetWidgetInLayer(Class, EUILayer.HUD) returns the game's race HUD
                -- (CSM_RF_*_InHud_Default/_Memory: CsmActionShowWidgetData Layer = EUILayer::HUD, decoded 2026-10-07).
                local ok, w = U.try(TAG, function() return mgr:GetWidgetInLayer(cls, C.E.UILayer.HUD) end)
                if ok and U.ok(w) and not isOurs(w) then
                    found = w
                    noteGameHud(w, "UIManager")
                    break
                end
            end
        end
    end
    if not found and U.ok(h.p1hud) then found = h.p1hud end
    if not found and cfg.HudSearchFallback ~= false then
        local now = St.nowMs()
        if now - (h.lastSearchMs or -1e9) >= FALLBACK_SEARCH_MS then
            h.lastSearchMs = now
            -- exact HUD classes (only those in memory), then the native parent as the last resort
            local shorts = {}
            for _, hc in ipairs(HUD_CLASS_KEYS) do
                if loadedClass(C.BP[hc.key]) then shorts[#shorts + 1] = hc.short end
            end
            if #shorts == 0 then shorts[1] = "FuseHudWidget" end
            local best, bestHow
            for _, short in ipairs(shorts) do
                local all = FindAllOf(short) -- nil or a Lua table [API 6]; throttled to 1 per 2 s
                for _, w in ipairs(all or {}) do
                    if U.ok(w) and not isOurs(w) then
                        local onScreen = (w:IsInViewport() == true) or U.ok(w:GetParent())
                        if onScreen then best, bestHow = w, "FindAllOf(" .. short .. ")"; break end
                        if not best then best, bestHow = w, "FindAllOf(" .. short .. ", off screen)" end
                    end
                end
                if best and bestHow:find("off screen", 1, true) == nil then break end
            end
            if best then
                found = best
                noteGameHud(best, bestHow)
            end
        end
    end
    if found and h.p1hud ~= nil then noteEqMismatch(found, h.p1hud, "the game's HUD") end
    -- same address as the instance we placed, but our stored wrapper no longer validates: keep the placement and
    -- just take the fresh wrapper (no release / re-place) (V-HUD-14)
    if found and h.p1hudKey ~= nil and h.p1hudKey ~= 0 and U.key(found) == h.p1hudKey and not U.ok(h.p1hud) then
        U.logOnce("hud.stalewrap", TAG, "V-HUD-14: stored P1 HUD wrapper invalid while the same address is live "
            .. "(0x%x); wrapper refreshed", h.p1hudKey)
        h.p1hud = found
    end
    if found and not sameObj(found, h.p1hud) then
        forget(found) -- a new instance may sit at a freed widget's address: never trust an old entry
        if h.p1hud ~= nil then
            -- a real hand-over happens a few times per race (countdown -> race, pause -> race); more than
            -- HUD_SWAP_WARN in 10 s is a thrash: logged once with both addresses (V-HUD-14)
            local now = St.nowMs()
            h.swaps = h.swaps or {}
            h.swaps[#h.swaps + 1] = now
            while #h.swaps > 0 and now - h.swaps[1] > 10000 do table.remove(h.swaps, 1) end
            if #h.swaps > HUD_SWAP_WARN and not h.swapWarned then
                h.swapWarned = true
                U.warn(TAG, "P1 HUD changed %d times in 10 s (old 0x%x valid=%s, new 0x%x): thrash (V-HUD-14)",
                    #h.swaps, U.key(h.p1hud), tostring(U.ok(h.p1hud)), U.key(found))
            end
            U.logEvery("hud.p1changed", 5000, TAG, "P1 HUD instance changed (%s, was 0x%x); re-placing",
                U.pathOf(found), U.key(h.p1hud))
            releaseP1(h.p1hud)
        else
            U.log(TAG, "P1 HUD: %s", U.pathOf(found))
        end
        h.p1hud, h.p1Placed, h.p1PlacedKey = found, false, 0
        h.p1hudKey = U.key(found)
    end
    return h.p1hud
end

-- CSM query for the polls: find-only (never LoadAsset from MAIN/FAST, ARCHITECTURE round 3). A state asset that is
-- not in memory means its state machine is not running: "unknown" (nil), not "inactive" (CSM_PauseIdle == false
-- would read as paused and hide every HUD).
local function csmPoll(key)
    return U.csmPoll(key)
end

-- Are the race CSM's "in HUD" states active? true / false / nil (unknown). Also read by pause.lua (P1 poll).
local function inHudState()
    local a = csmPoll("CSM_InProgressInHud")
    local b = csmPoll("CSM_CountdownInHud")
    if a == nil and b == nil then return nil end
    return (a == true) or (b == true)
end
M.inHudState = inHudState

-- Rehost failed after the HUD was taken off its layer: put it back where the game had it, so P1 is never
-- left without a HUD. Returns a short description of what worked.
local function putBackP1(p1hud)
    local mgr = U.giSubsystem("UIManager")
    if U.ok(mgr) then
        -- VERIFY(V-HUD-02b): AddExistingWidgetToLayer re-adopts a widget the UIManager created and we removed.
        local ok = U.try(TAG, function() mgr:AddExistingWidgetToLayer(p1hud, C.E.UILayer.HUD) end)
        if ok and (U.ok(p1hud:GetParent()) or p1hud:IsInViewport() == true) then return "UIManager HUD layer" end
    end
    -- last resort: whole viewport, like "leave" (UserWidget:AddToViewport(Int ZOrder))
    local ok = U.try(TAG, function() p1hud:AddToViewport(0) end)
    if ok and p1hud:IsInViewport() == true then return "viewport" end
    return nil
end

-- 0.7.0 (V-UX-10): in "clone" mode the game's own race HUD stays alive at opacity 0 and keeps ticking: its 1D map writes
-- the GLOBAL MPC_HUD_Parameters every frame (fighting P1's map) and its countdown beeps a third time. Those members are
-- collapsed (a collapsed widget does not tick), re-applied every MAIN tick; the root keeps opacity 0 (the CSM may wait
-- for its transition animations). Done again for every new instance (the CSM re-creates it after each pause).
-- VERIFY(V-UX-10): "game HUD ... 3 member(s) collapsed"; one 3-2-1 beep per player; P1's map steady. Fallback:
-- cfg.UxSplitGameHud = false.
local function tameGameHud(h, w)
    local k = U.key(w)
    if h.tamedKey ~= k then
        local mem = membersOf(w)
        local names = {}
        h.tamedKey, h.tamed = k, {}
        for _, n in ipairs(GAME_HUD_NAMES) do
            for _, x in ipairs(mem.raw[string.lower(n)] or {}) do
                if U.ok(x) then
                    h.tamed[#h.tamed + 1] = x
                    names[#names + 1] = n
                end
            end
        end
        U.log(TAG, "game HUD %s (hidden, owner %s): %d member(s) collapsed [%s] (V-UX-10)", U.pathOf(w),
            (ownerDesc(w)), #h.tamed, table.concat(names, ","))
    end
    for _, x in ipairs(h.tamed or {}) do
        if U.ok(x) and x:GetVisibility() ~= VIS_HIDE then x:SetVisibility(VIS_HIDE) end
    end
end

function M.placeP1()
    local h = H()
    local p1hud = h.p1hud
    if not U.ok(p1hud) then return end
    local mode = p1Mode()
    if mode == "rehost" then
        -- VERIFY(V-HUD-02): RemoveFromParent + AddToPlayerScreen(0) keeps the UIManager-owned HUD in P1's view
        -- and survives pause/unpause; GetParent() is valid only while the HUD sits in a UIManager layer panel.
        -- Fallback: cfg.P1HudMode = "clone", then "leave". A failed AddToPlayerScreen switches this race to
        -- "leave" automatically (below).
        local parentOk = U.ok(p1hud:GetParent())
        local firstTime = (h.p1PlacedKey ~= U.key(p1hud))
        local inViewport = p1hud:IsInViewport() -- true for viewport AND player-screen widgets
        local offScreen = (not parentOk) and (not inViewport)
        local wantShown = inHudState() ~= false
        if parentOk or firstTime or (offScreen and wantShown) then
            -- AddToPlayerScreen needs an owning LOCAL player (UE: returns false "No Owning Player" otherwise).
            -- The UIManager API has no owner parameter [HUD 3.1], so a HUD without owner gets P1 first.
            -- VERIFY(V-HUD-02c): the UIManager HUD is owned by P1's PC (or by nobody).
            -- Session B: the game's HUD is apparently NOT owned by P1 (see noteGameHud). AddToPlayerScreen puts a
            -- widget into its OWNER's view, so the owner is set to P1 first, whatever it was.
            local desc, owner = ownerDesc(p1hud)
            local p1 = U.p1()
            if U.ok(p1) and not sameObj(owner, p1) then
                U.try(TAG, function() p1hud:SetOwningPlayer(p1) end) -- SetOwningPlayer(Object LocalPlayerController)
                U.log(TAG, "P1 HUD owner was %s; set to P1 (parts bound at Construct may still follow the old owner:"
                    .. " use cfg.P1HudMode = \"clone\" if P1's view shows another player's data)", desc)
            end
            -- AddToPlayerScreen refuses a widget that is already on screen: take it off first
            if parentOk or inViewport then p1hud:RemoveFromParent() end
            local okA, added = U.try(TAG, function() return p1hud:AddToPlayerScreen(0) end)
            if okA and added == true then
                h.p1Placed, h.p1PlacedKey = true, U.key(p1hud)
                U.log(TAG, "P1 HUD moved to P1's view (parent was %s)", parentOk and "a layer" or "none")
            else
                h.rehostFailed = true
                h.p1Placed, h.p1PlacedKey = false, 0
                local where = putBackP1(p1hud)
                U.warn(TAG, "P1 HUD: AddToPlayerScreen returned %s; HUD put back to %s; P1HudMode 'leave' for the "
                    .. "rest of this race (try cfg.P1HudMode = \"clone\")", tostring(added), tostring(where or "NOWHERE"))
            end
        end
    elseif mode == "clone" then
        p1hud:SetRenderOpacity(0.0) -- re-applied every poll; the CSM's transitions may animate it
        h.p1Placed, h.p1PlacedKey = true, U.key(p1hud)
        if cfg.UxSplitGameHud ~= false and #U.localPlayers() >= 2 then U.try(TAG, tameGameHud, h, p1hud) end
        M.ensureGuest(U.p1(), 1)
    end
    -- "leave": the game's HUD stays where the UIManager put it (whole viewport)
end

-- Copy P1's EventInfo named-slot content (filled by the CSM's SetGamemodeWidgetInSlot action) into a HUD
-- we own, as a widget of the same class owned by that HUD's player. Re-done when P1's content class changes.
local function syncEventInfo(e)
    local p1hud = H().p1hud
    if not (U.ok(p1hud) and U.ok(e.widget)) then return end
    local src = p1hud.EventInfo -- FuseNamedSlot variable (Race and Memory HUD)
    local dst = e.widget.EventInfo
    if not (U.ok(src) and U.ok(dst)) then
        U.logOnce("hud.noeventinfo", TAG, "EventInfo slot missing on P1 or guest HUD; not copied")
        return
    end
    local c = src:GetContent() -- ContentWidget:GetContent() -> Object
    if not U.ok(c) then return end -- the CSM fills it later; retried every poll
    local cls = c:GetClass()
    local ck = U.key(cls)
    if e.eventInfoClassKey == ck and U.ok(dst:GetContent()) then return end
    -- VERIFY(V-HUD-07): a guest-owned copy of P1's EventInfo content works in the guest HUD.
    -- Fallback: none needed (the slot just stays empty if this fails; logged).
    local copy = U.WBL():Create(e.pc, cls, e.pc) -- Create(WorldContextObject, WidgetType, OwningPlayer)
    if U.ok(copy) then
        dst:SetContent(copy) -- ContentWidget:SetContent(Object Content) -> slot (ignored)
        e.eventInfoClassKey = ck
        U.dbg(TAG, "P%d EventInfo <- %s", e.pnum, U.pathOf(cls))
    end
end

local function collapseGlobalParts(e, mem)
    if e.pnum == 1 then return end -- P1's clone shows P1's own global data: nothing to hide
    for _, n in ipairs(cfg.GuestHudCollapse or {}) do
        local l = mem.raw[string.lower(n)]
        if l and #l > 0 then
            for _, x in ipairs(l) do
                if U.ok(x) then
                    x:SetVisibility(VIS_HIDE)
                    e.hidden[#e.hidden + 1] = x -- re-collapsed every poll (a BP may show it again)
                end
            end
        else
            U.logOnce("hud.nocollapse." .. n, TAG, "GuestHudCollapse member %s not found in %s", n,
                U.pathOf(e.widget:GetClass()))
        end
    end
    if cfg.GuestHudNotifications == "remove" then
        -- VERIFY(V-HUD-08): duplicate notification containers in a guest HUD; removal may also unregister them.
        for _, n in ipairs(NOTIF_NAMES) do
            for _, x in ipairs(mem.raw[string.lower(n)] or {}) do
                if U.ok(x) then x:RemoveFromParent() end
            end
        end
    end
    if cfg.GuestMarkers == "collapse" and mem.markers then
        -- VERIFY(V-HUD-09): markers of a guest-owned container project with the guest's camera.
        mem.markers:SetVisibility(VIS_HIDE)
    end
    -- 0.7.0 (V-UX-12): the radio-chatter portrait follows the world's ONE dialogue line (FuseDialogueManagerSubsystem
    -- OnHoloLineStarted/Ended): every HUD showed every line. Kept in P1's HUD only. It is a BotEngineInfo variable (the
    -- tree walk does not descend into BotEngineInfo); re-collapsed every poll with the other hidden parts.
    -- VERIFY(V-UX-12): the portrait shows in P1's half only. Fallback: cfg.UxSplitGuestHolo = "keep".
    if cfg.UxSplitGuestHolo ~= "keep" and mem.bot and U.ok(mem.bot) then
        local holo = holoOf(mem.bot)
        if holo then
            holo:SetVisibility(VIS_HIDE)
            e.hidden[#e.hidden + 1] = holo
            U.logOnce("hud.holo", TAG, "guest HUDs: radio-chatter portrait hidden (one dialogue line for everybody; "
                .. "UxSplitGuestHolo) (V-UX-12)")
        else
            U.logOnce("hud.noholo", TAG, "guest HUD: no WBP_Hud_CharacterHolo variable on %s; portrait left as is",
                U.pathOf(mem.bot:GetClass()))
        end
    end
end

-- Create (once per PC per race) the HUD of a local player other than the HUD owner of the game.
function M.ensureGuest(pc, pnum)
    local h = H()
    if not U.ok(pc) then return nil end
    local key = U.key(pc)
    local e = h.guests[key]
    if e and U.ok(e.widget) then
        e.pnum = pnum or e.pnum
        return e
    end
    if e then M.removeGuest(key) end
    local p1hud = h.p1hud
    local cls
    if U.ok(p1hud) then
        cls = p1hud:GetClass() -- same class as P1 (WBP_Hud_Race_C or WBP_Hud_Memory_C) [HUD 6 #1]
    elseif h.fallbackCls and U.ok(h.fallbackCls) then
        cls = h.fallbackCls    -- M.tick's fallback: the game's HUD was never found
    else
        return nil
    end
    -- VERIFY(V-HUD-03): a HUD created for the guest PC reads the guest's pawn/PlayerState (owner-based parts).
    local w = U.WBL():Create(pc, cls, pc) -- Create(WorldContextObject, WidgetType, OwningPlayer) -> Object
    if not U.ok(w) then
        U.logEvery("hud.createfail", 5000, TAG, "could not create %s for P%s", U.pathOf(cls), tostring(pnum))
        return nil
    end
    -- 0.7.0: Construct (and BotEngineInfo's GetPlayerPawn(self, 0) calls) runs INSIDE AddToPlayerScreen: uxsplit arms
    -- its hooks now if a split race runs and knows this widget as "being created" for this player until hudCreated.
    local ux = lazy("uxsplit")
    if ux and type(ux.hudCreating) == "function" then U.try(TAG, ux.hudCreating, w, pc, pnum) end
    local okAdd, added = U.try(TAG, function() return w:AddToPlayerScreen(cfg.GuestHudZOrder) end) -- (Int ZOrder) -> Bool
    if not okAdd then added = false end
    fitInterior(w, "P" .. tostring(pnum))
    U.try(TAG, function() w:TransitionIn() end)            -- FuseScreenWidget BlueprintEvent, no params
    if ux and type(ux.hudCreated) == "function" then U.try(TAG, ux.hudCreated, w, pc, pnum) end
    -- (only when the game's HUD really is P1's: a guest-owned or ownerless game HUD binds nothing on P1's PC, and
    -- then the clone's bindings are P1's only pause path)
    local gameHudIsP1s = false
    if pnum == 1 and U.ok(p1hud) then
        local okO, o = pcall(function() return p1hud:GetOwningPlayer() end)
        gameHudIsP1s = okO and sameObj(o, pc)
    end
    if pnum == 1 and cfg.P1CloneInput ~= true and gameHudIsP1s then
        -- P1's clone ("clone" mode): the game's own HUD stays alive (opacity 0) with its IA_Veh_Pause/IA_Veh_Player
        -- bindings on P1's PC; the clone's identical bindings would open the pause menu a second time in the same
        -- frame. VERIFY(V-HUD-02d): P1's pause works once (cfg.P1CloneInput = true keeps the clone's bindings).
        U.try(TAG, function() w:UnregisterInputComponent() end)
    elseif cfg.GuestHudRegisterInput then
        -- VERIFY(V-PAU-01): the guest HUD's IA_Veh_Pause binding only reaches the guest PC after this call.
        U.try(TAG, function() w:RegisterInputComponent() end)
    end
    e = { pc = pc, widget = w, pnum = pnum, lapCounter = nil, lastLapText = nil, lapFText = nil, shown = nil,
          eventInfoClassKey = nil, hidden = {},
          layout = { widgetKey = U.key(w), key = "W" } }   -- 0.11.0: a fresh HUD has the designer layout
    h.guests[key] = e
    forget(w) -- a freshly created widget can never own an existing cache entry (freed address reused)
    local mem = membersOf(w)
    -- 0.11.0: the narrow-view layout before the HUD is first drawn (no 0.53 -> 0.96 jump on screen) (V-HUD-17)
    U.try(TAG, function()
        local lps = U.localPlayers()
        local views, full, single = viewSizes(lps)
        for _, lp in ipairs(lps) do
            if sameObj(lp.pc, pc) then layoutEntry(e, lp.index, views, full, single) end
        end
    end)
    e.lapCounter, e.lapCounterList, e.posWidgets, e.bot, e.markers = mem.lap, mem.laps, mem.poss, mem.bot, mem.markers
    for _, lc in ipairs(e.lapCounterList) do h.lapCounters[U.key(lc)] = key end
    -- Memory-variant lap counters (rewritten every Tick by their BP): need the UpdateCurrentLap post-hook
    e.memoryLaps = {}
    for _, lc in ipairs(e.lapCounterList) do
        local okP, cp = pcall(function() return U.pathOf(lc:GetClass()) end)
        if okP and cp == C.BP.LapCounterMemory then e.memoryLaps[#e.memoryLaps + 1] = lc end
    end
    e.memoryLapSet = {}
    for _, lc in ipairs(e.memoryLaps) do e.memoryLapSet[U.key(lc)] = true end
    if not e.lapCounter then
        U.logOnce("hud.nolap." .. U.pathOf(cls), TAG, "no lap counter found in %s; lap patch off", U.pathOf(cls))
    end
    U.try(TAG, collapseGlobalParts, e, mem)
    U.try(TAG, syncEventInfo, e)
    U.log(TAG, "P%s HUD created (%s, AddToPlayerScreen=%s)", tostring(pnum), U.pathOf(cls), tostring(added))
    return e
end

function M.removeGuest(pcKey)
    local h = H()
    local e = h.guests[pcKey]
    if not e then return end
    h.guests[pcKey] = nil
    for lk, pk in pairs(h.lapCounters) do
        if pk == pcKey then h.lapCounters[lk] = nil end
    end
    -- 0.7.0 review: uxsplit drops this HUD's entry at once (its hooks never walk a HUD we no longer host)
    local ux = lazy("uxsplit")
    if ux and type(ux.hudRemoved) == "function" then U.try(TAG, ux.hudRemoved, e.widget) end
    if e.widget and U.ok(e.widget) then
        if h.found then h.found[U.key(e.widget)] = nil end
        U.try(TAG, function() e.widget:UnregisterInputComponent() end)
        U.try(TAG, function() e.widget:RemoveFromParent() end)
    end
    U.dbg(TAG, "P%s HUD removed", tostring(e.pnum))
end

-- The PlayerState that holds this player's racer entry (adopted/AI PS after a takeover).
local function racerPS(pc)
    local tko = lazy("takeover")
    if tko and tko.racerPSFor then
        local ok, ps = U.try(TAG, tko.racerPSFor, pc)
        if ok and U.ok(ps) then return ps end
    end
    return pc.PlayerState
end

local function raceVM()
    local vms = U.giSubsystem("ViewModelSubsystem")
    if not U.ok(vms) then return nil end
    local vm = vms:GetRaceEventVM() -- ViewModelSubsystem:GetRaceEventVM() -> Object (URaceEventVM)
    if U.ok(vm) then return vm end
    return nil
end

-- Offset between the global VM lap (P1's) and P1's own component lap.                        [HUD 2]
-- Run H (0.6.0 bug, P2 showed LAP 2 on lap 1): the component lap is 0 before a car's first start-line crossing while
-- the VM already shows 1; the old calibration ran 1 s after the start (VM 1 - component 0 = 1). Now the offset is taken
-- only once P1's component lap is >= 1, and again 1 s after each change of P1's lap (the VM follows a moment later;
-- the latest value wins). Until then patchGuest uses offset 0 (display = max(1, own lap): the mapping seen in run H).
function M.calibrateLap()
    if not cfg.LapPatch then return end
    if St.phase ~= "RACING" or not St.race.started then return end
    local p1 = U.p1()
    if not U.ok(p1) then return end
    -- P1's racer PlayerState (adopted/AI PS after a takeover of P1's car; pawn-first on clients, see racerPS)
    local comp = racerPS(p1).RaceEventComponent
    if not U.ok(comp) or comp:IsStillRacing() ~= true then return end
    local psLap = comp.CurrentLapNumber
    if type(psLap) ~= "number" or psLap < 1 then return end      -- P1 has not crossed the start line yet
    local h, now = H(), St.nowMs()
    if h.lapCalibLap ~= psLap then
        h.lapCalibLap, h.lapCalibSince = psLap, now
        return
    end
    if h.lapCalibDone == psLap or now - (h.lapCalibSince or now) < 1000 then return end
    local vm = raceVM()
    if not vm then return end
    local vmLap = vm.CurrentLapNumber
    if type(vmLap) ~= "number" then return end
    h.lapCalibDone = psLap
    -- VERIFY(V-HUD-04): URaceEventVM.CurrentLapNumber == P1's component lap once P1 crossed the line (offset 0).
    -- Fallback: cfg.LapPatch = false (guests then show P1's lap, the game's behaviour).
    local off = math.floor(vmLap - psLap)
    if St.race.lapOffset ~= off then
        U.log(TAG, "lap offset calibrated at P1's lap %d: VM %d - P1 component %d = %d (V-HUD-04)", math.floor(psLap),
            math.floor(vmLap), math.floor(psLap), off)
        if math.abs(off) > 1 then U.warn(TAG, "unexpected lap offset %d (expected 0)", off) end
    end
    St.race.lapOffset = off
end

local function setText(textWidget, s)
    if textWidget and U.ok(textWidget) then
        textWidget:SetText(U.ftext(s)) -- TextBlock:SetText(Text InText), plain input
        return true
    end
    return false
end

-- Current text of a TextBlock as a Lua string (TextBlock:GetText() -> Text), nil when unreadable.
local function textOf(textWidget)
    local ok, s = pcall(function() return textWidget:GetText():ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end

-- Memory lap counters: "collapse" (default) = guests' Memory lap counters stay collapsed (no per-frame write),
-- "hook" = per-frame write from the UpdateCurrentLap post-hook. cfg.MemoryLapMode is read with a default here.
-- Default "collapse" (2026-10-07): the UpdateCurrentLap BP hook never fires in this build, so "hook" only ever
-- collapsed them too; the setting now says what happens. "hook" stays an explicit opt-in.
local function memoryLapMode()
    local m = cfg.MemoryLapMode
    if m == "hook" then return "hook" end
    return "collapse"
end

-- Cost model of UFunction calls from Lua (UE4SS LuaUObject.cpp call_ufunction_from_lua): the parameter buffer
-- (DynamicUnrealFunctionData, uint8_t[0x200]) is never destructed after ProcessEvent. So every TextBlock:SetText
-- retains the FText it builds there (push_textproperty Set = SetString(...), a NEW text on every call, even when
-- the same Lua FText userdata is passed again), and every GetText retains one reference to the returned text.
-- No GetText in the per-frame path, and SetText only when the BP may have rewritten the text: in the hook (the BP
-- just ran UpdateCurrentLap) and, from the poll, when our Lua-side record says this counter shows something else.
-- Memory variant, mode "hook": one SetText per guest Memory lap counter per frame is unavoidable (the BP writes a
-- fresh Conv_IntToText every Tick) -> one leaked FText per guest per frame (estimate: ~100 B, i.e. ~10 MB for
-- 3 guests over a 10-minute race at 60 fps).
-- VERIFY(V-HUD-04c): process memory growth over a Memory-HUD race with cfg.MemoryLapMode = "hook"; fallback:
-- cfg.MemoryLapMode = "collapse" (guests' Memory lap counters collapsed, no per-frame write).
-- UpdateCurrentLap post-hook liveness, per UFunction path: set the first time the hook fires for ANY lap counter of
-- that class (P1's included: the BP Tick calls UpdateCurrentLap on every visible counter every frame [HUD§4]).
-- A hook that registered but never fires (e.g. the call never reaches ProcessEvent) must not be trusted: until it
-- has fired, the MAIN poll compares with the widget text and guest Memory counters stay collapsed.
-- "Ever fired" rather than "fired recently": a counter that stops ticking (HUD hidden while paused) is not
-- rewritten by its BP either, so the Lua-side record stays right.
local lapHookFired = {}

local function lapHookAlive(path)
    return St.hooks[path] ~= nil and lapHookFired[path] == true
end

local function lapHookFor(e, lc)
    local isMem = e.memoryLapSet and e.memoryLapSet[U.key(lc)] or false
    local path = isMem and C.FN.LapUpdateMemory or C.FN.LapUpdate
    return isMem, lapHookAlive(path)
end

-- BP-side lap of a Race-variant counter after its UpdateCurrentLap ran: the BP rewrote Txt_CurrentLap in this call
-- iff this value changed [HUD§4: `if (Current Lap Number != VM.CurrentLapNumber) { SetText; Current Lap Number = ..}`].
-- Property reads only (no UFunction call, no FText). nil when unreadable.
-- VERIFY(V-HUD-04d): lc["Current Lap Number"] (BP variable whose name contains spaces) reads as an integer through
-- UE4SS; else the VM fallback (lc.RaceEventVM.CurrentLapNumber) is used, and if both fail every hook call writes.
-- Second result: "var" (the BP's own variable, updated in the same BP call as its SetText: consistent with the text
-- at any time) or "vm" (the VM fallback: may run ahead of the BP's next rewrite, so only the hook path trusts it).
local function bpLapOf(lc)
    local ok, v = pcall(function() return lc["Current Lap Number"] end)
    if ok and type(v) == "number" then return v, "var" end
    ok, v = pcall(function()
        local vm = lc.RaceEventVM
        if U.ok(vm) then return vm.CurrentLapNumber end
        return nil
    end)
    if ok and type(v) == "number" then return v, "vm" end
    return nil, nil
end

local function writeLapTo(e, lc, fromHook)
    if not U.ok(lc) then return end
    local k = U.key(lc)
    local isMem, hooked = lapHookFor(e, lc)
    if isMem and (e.memoryLapsCollapsed or memoryLapMode() == "collapse") then return end -- not visible
    local t = lc.Txt_CurrentLap -- var Txt_CurrentLap (both variants)
    if not U.ok(t) then return end
    e.lapWritten = e.lapWritten or {}
    if fromHook and not isMem then
        -- Race variant: the BP writes only when the VM lap changes, so write only when it just did (its
        -- "Current Lap Number" moved) or when our own text changed. The Memory variant rewrites every Tick: written
        -- unconditionally (see the cost model above).
        e.bpLap = e.bpLap or {}
        local bp = bpLapOf(lc)
        local bpChanged = (bp == nil) or (e.bpLap[k] ~= bp)
        e.bpLap[k] = bp
        if not bpChanged and e.lapWritten[k] == e.lastLapText then return end
    end
    if not fromHook then
        if hooked then
            -- the hook rewrites after every BP write, so the Lua-side record is authoritative
            if e.lapWritten[k] == e.lastLapText then return end
        else
            -- MAIN poll, the DEFAULT path (BP hooks never fired in the 2026-10-06 runs). Race variant: the BP
            -- rewrites Txt_CurrentLap only together with its "Current Lap Number" variable, so a property read
            -- tells whether it overwrote our text since our last write: write only when it did or when the guest's
            -- own lap text changed (no GetText, no FText per poll). Without that variable: compare with the widget
            -- (each GetText retains one text reference, see above; poll rate only).
            local bp, src = nil, nil
            if not isMem then bp, src = bpLapOf(lc) end
            if src == "var" then
                e.bpLap = e.bpLap or {}
                local bpChanged = (e.bpLap[k] ~= bp)
                e.bpLap[k] = bp
                if not bpChanged and e.lapWritten[k] == e.lastLapText then return end
            elseif textOf(t) == e.lastLapText then
                e.lapWritten[k] = e.lastLapText
                return
            end
        end
    end
    if not e.lapFText or e.lapFTextFor ~= e.lastLapText then
        -- Lua-side cache only: the param path still builds a new FText from its string on every SetText
        e.lapFText, e.lapFTextFor = U.ftext(e.lastLapText), e.lastLapText
    end
    t:SetText(e.lapFText) -- TextBlock:SetText(Text InText)
    e.lapWritten[k] = e.lastLapText
end

local function writeLap(e, onlyLc)
    if not e.lastLapText then return end
    if onlyLc then
        writeLapTo(e, onlyLc, true)
        return
    end
    for _, lc in ipairs(e.lapCounterList or {}) do writeLapTo(e, lc, false) end
end

-- RE-POINT GUEST HUD PARTS FROM P1'S CAR TO THE GUEST'S CAR (feedback 2: P2's HUD must be P2's).
-- WBP_HUD_BotEngineInfo (ramjet / boost-toggle / throttle-toggle / critical-malfunction) binds GetPlayerPawn(0)'s
-- (P1's) VehicleDelegates at Construct [hud.md §2]. Every multicast delegate of P1's car's UVehicleDelegates (59, all
-- MulticastInline, runtime JMAP) is scanned with UE4SS's GetBindings; a binding whose object is a widget owned by
-- this guest's PC is removed there and added (same UFunction name) to the guest car's delegate. The guest car's own
-- events then drive the guest's parts. The two ignition delegates are left to present.lua (its own re-point).
-- Scanned every MAIN tick for the first ~10 s of a HUD (BP bindings may come late), then every ~2 s; a guest car
-- change (takeover) re-adds the learned bindings to the new car. A failing API sets e.rebindFailed (logged once).
-- VERIFY(V-HUD-10): "P2 HUD: n binding(s) moved from P1's car" and P2's boost/throttle icons follow P2's car.
local VD_NAMES = {
    "OnVehicleResetOnTrackDelegate", "OnBoostStateChangedDelegate", "OnAfterburnerStartFailedDelegate",
    "OnRamjetExplodeResetDelegate", "OnRamjetChangeFailedDelegate", "OnRamjetAvailabilityChangedDelegate",
    "OnRamjetStateChangedDelegate", "OnAfterburnerStateChangedDelegate", "OnDriftStartDelegate", "OnDriftEndDelegate",
    "OnKnifingStartDelegate", "OnKnifingEndDelegate", "OnEnergyBrakeStateChangeDelegate",
    "OnAirBrakeActivityChangeDelegate", "OnDraftingStartDelegate", "OnDraftingEndDelegate",
    "OnDraftingBuffAppliedDelegate", "OnDraftingBuffRemovedDelegate", "OnAirborneChanged", "OnGroundInViewChanged",
    "OnGroundMaterialChanged", "OnPerfectLandingStartDelegate", "OnLandingCompletedDelegate", "OnVehicleTrailStarted",
    "OnVehicleTrailEnded", "OnEpicJumpZoneChanged", "OnLookBackChangedDelegate", "OnChangeCameraDelegate",
    "OnBoostToggledDelegate", "OnThrottleToggledDelegate", "OnThrottlePunchDelegate", "OnThrottleOffDelegate",
    "OnBrakePunchDelegate", "OnWorldCollisionDelegate", "OnVehicleCollisionDelegate",
    "OnVehicleExplosionAOEFirstFrameTriggered", "OnVehicleExplosionAOEStartOverlappingAny",
    "OnVehicleExplosionAOUpdateIsOverlappingFlameyCentre", "OnVehicleExplosionAOEEndOverlappingAny",
    "OnCrashTagsChanged", "OnVehicleCrashTagChangedDelegate", "OnCrashTagChanged", "OnVehicleTakendownByDelegate",
    "OnVehicleTakendownFinishedDelegate", "OnExplosionDelegate", "OnConditionStarted", "OnConditionChanged",
    "OnConditionCancelled", "OnConditionCancelledBy", "OnConditionTriggered", "OnConditionEnded",
    "OnShieldCorrosionStarted", "OnShieldCorrosionFinished", "OnSlowMotionTriggered", "OnSlowMotionEnded",
    "OnCinematicCameraSwitch", "OnVehicleDamagedDelegate",
}

local function ownedByPC(obj, pc)
    local ok, r = pcall(function() return sameObj(obj:GetOwningPlayer(), pc) end)
    return ok and r == true
end

local function rebindToGuestCar(e)
    if e.pnum == 1 or e.rebindFailed then return end
    local gcar = e.pc.Pawn
    if not U.isVehicle(gcar) then return end
    local p1car
    pcall(function() p1car = U.p1().Pawn end)
    if not U.isVehicle(p1car) or sameObj(p1car, gcar) then return end
    e.rebind = e.rebind or { learned = {}, ticks = 0, carKey = 0 }
    local r = e.rebind
    r.ticks = r.ticks + 1
    local ok, err = pcall(function()
        local gvd = gcar.VehicleDelegates
        if not U.ok(gvd) then return end
        if r.carKey ~= U.key(gcar) then
            -- new guest car (first time or after a takeover): the bindings learned so far leave the old car and go
            -- to the new one
            local oldVd = nil
            pcall(function() if U.ok(r.car) then oldVd = r.car.VehicleDelegates end end)
            r.carKey, r.car = U.key(gcar), gcar
            for _, b in ipairs(r.learned) do
                if U.ok(b.obj) then
                    if U.ok(oldVd) then pcall(function() oldVd[b.name]:Remove(b.obj, b.fn) end) end
                    gvd[b.name]:Add(b.obj, b.fn)
                end
            end
        end
        if r.ticks > 40 and r.ticks % 8 ~= 0 then return end   -- ~10 s every tick, then every ~2 s
        local vd = p1car.VehicleDelegates
        if not U.ok(vd) then return end
        -- 0.7.0 (V-UX-10): the game's own hidden HUD ("clone" mode) is owned by a guest PC too (the UIManager's owner in
        -- a split race), and its BotEngineInfo bound P1's car: those bindings are REMOVED (its ramjet animations wrote
        -- the global MPC, its critical-malfunction dimming is invisible anyway), never moved to the guest's car.
        local gameHud = (cfg.UxSplitGameHud ~= false and p1Mode() == "clone" and U.ok(H().p1hud)) and H().p1hud or nil
        local moved, stripped = 0, 0
        for _, name in ipairs(VD_NAMES) do
            local md = vd[name]
            for _, b in ipairs(md:GetBindings() or {}) do
                local obj = b.Object
                if U.ok(obj) and (sameObj(obj, e.bot) or ownedByPC(obj, e.pc)) then
                    md:Remove(obj, b.FunctionName)
                    if gameHud and not sameObj(obj, e.bot) and ownedBy(obj, gameHud) then
                        stripped = stripped + 1
                    else
                        gvd[name]:Add(obj, b.FunctionName)
                        r.learned[#r.learned + 1] = { name = name, obj = obj, fn = b.FunctionName }
                        moved = moved + 1
                    end
                end
            end
        end
        if moved > 0 then
            U.log(TAG, "P%s HUD: %d binding(s) moved from P1's car to P%s's car", tostring(e.pnum), moved,
                tostring(e.pnum))
        end
        if stripped > 0 then
            U.log(TAG, "game HUD (hidden): %d binding(s) on P1's car removed (V-UX-10)", stripped)
        end
    end)
    if not ok then
        e.rebindFailed = true
        U.warn(TAG, "P%s HUD: cannot re-point car delegates (%s); GuestBotEngineFix polling only", tostring(e.pnum),
            tostring(err))
    end
end

-- 0.7.0 (V-UX-01): BotEngineInfo caches "Vehicle State" at Construct (its boost / throttle / ramjet handlers read it,
-- ux-split-inventory §2). With the index remap (uxsplit.lua) a guest HUD's is already the guest car's; otherwise
-- (remap off, the car not there yet, a takeover car) it is written (plain ObjectProperty BP variable). Checked once per
-- guest car.
local function checkVehicleState(e)
    local pawn = e.pc.Pawn
    if not U.isVehicle(pawn) then return end
    local ck = U.key(pawn)
    if e.vsCarKey == ck then return end
    local vs = pawn.VehicleState
    if not U.ok(vs) then return end
    e.vsCarKey = ck
    local okR, cur = pcall(function() return e.bot["Vehicle State"] end)
    if okR and sameObj(cur, vs) then
        U.log(TAG, "P%s BotEngineInfo: Vehicle State = P%s's car (index remap) (V-UX-01)", tostring(e.pnum),
            tostring(e.pnum))
        return
    end
    if cfg.GuestBotEngineFix == false then return end
    local okW, err = pcall(function() e.bot["Vehicle State"] = vs end)
    U.log(TAG, "P%s BotEngineInfo: Vehicle State was %s: %s (V-UX-01)", tostring(e.pnum),
        okR and (U.ok(cur) and U.pathOf(cur) or "none") or "unreadable",
        okW and "set to the guest car's (index remap off or too late)" or ("write failed: " .. tostring(err)))
end

function M.patchGuest(e)
    if not (e and U.ok(e.pc) and U.ok(e.widget)) then return end
    U.try(TAG, syncEventInfo, e)
    for _, x in ipairs(e.hidden or {}) do
        if U.ok(x) and x:GetVisibility() ~= VIS_HIDE then x:SetVisibility(VIS_HIDE) end
    end
    local ps = racerPS(e.pc)
    local comp = U.ok(ps) and ps.RaceEventComponent or nil
    -- Memory lap counter without its post-hook: the BP shows P1's lap again on the next frame, so it is collapsed
    -- while the hook is missing, and given back as soon as it registers. Its class loads with the Memory HUD, i.e.
    -- just before this first patch, while the SLOW loop retries pending hooks only once per second: retry here.
    -- VERIFY(V-HUD-04b): in a Memory-HUD race the hook registers (diag hook list) and the guest sees its own lap.
    if cfg.LapPatch and e.pnum ~= 1 and e.memoryLaps and #e.memoryLaps > 0 then
        local path = C.FN.LapUpdateMemory
        if St.hooks[path] == nil and St.pendingHooks[path] ~= nil then U.try(TAG, U.retryPendingHooks) end
        local collapseMode = (memoryLapMode() == "collapse")
        local hooked = lapHookAlive(path) and not collapseMode
        if not hooked and not e.memoryLapsCollapsed then
            e.memoryLapsVis = {}
            for _, lc in ipairs(e.memoryLaps) do
                if U.ok(lc) then
                    e.memoryLapsVis[U.key(lc)] = lc:GetVisibility()   -- GetVisibility() -> Enum (integer)
                    lc:SetVisibility(VIS_HIDE)
                    e.hidden[#e.hidden + 1] = lc     -- re-collapsed every poll with the other hidden parts
                end
            end
            e.memoryLapsCollapsed = true
            if collapseMode then
                U.logOnce("hud.memlapcfg", TAG, "cfg.MemoryLapMode = collapse: guest Memory lap counters collapsed "
                    .. "(no per-frame lap write)")
            else
                U.logOnce("hud.memlap", TAG, "Memory-HUD race: guest Memory lap counters collapsed (their BP rewrites "
                    .. "P1's lap every frame; the optional UpdateCurrentLap hook, registered=%s, has not fired)",
                    tostring(St.hooks[path] ~= nil))
            end
        elseif hooked and e.memoryLapsCollapsed then
            local isMem = {}
            for _, lc in ipairs(e.memoryLaps) do isMem[U.key(lc)] = true end
            local keep = {}
            for _, x in ipairs(e.hidden) do
                if not isMem[U.key(x)] then keep[#keep + 1] = x end
            end
            e.hidden = keep
            for _, lc in ipairs(e.memoryLaps) do
                if U.ok(lc) then
                    local v = e.memoryLapsVis and e.memoryLapsVis[U.key(lc)]
                    lc:SetVisibility((type(v) == "number" and v ~= VIS_HIDE) and v or VIS_SHOW)
                end
            end
            e.memoryLapsCollapsed, e.memoryLapsVis = false, nil
            if e.lapWritten then for _, lc in ipairs(e.memoryLaps) do e.lapWritten[U.key(lc)] = nil end end
            U.log(TAG, "P%s Memory lap counters shown again: UpdateCurrentLap hook fires", tostring(e.pnum))
        end
    end
    -- lap: from the race start on (0.7.0: offset 0 until calibrated after P1's first crossing; display >= 1)
    if cfg.LapPatch and e.pnum ~= 1 and e.lapCounter and comp and U.ok(comp) and St.race.started then
        local lap = comp.CurrentLapNumber
        if type(lap) == "number" then
            lap = math.max(1, lap + (St.race.lapOffset or 0))
            local vm = raceVM()
            local n = vm and vm.NumLaps
            if type(n) == "number" and n > 0 then lap = math.min(lap, n) end
            e.lastLapText = tostring(math.floor(lap))
            writeLap(e)
        end
    end
    -- position: only when the HUD's owner PS is not the racer [HUD 6 #6]: a takeover without PlayerState adoption,
    -- or (client) an adoption whose raw pc.PlayerState write did not replicate (V-TKO-05) while the pawn's
    -- PlayerState (set natively in PossessedBy, replicated) is the racer. Independent of cfg.TakeoverAdoptPS.
    if e.posWidgets and #e.posWidgets > 0 and comp and U.ok(comp) and U.ok(ps)
        and not sameObj(ps, e.pc.PlayerState) then
        local pos = comp.EventPosition
        if type(pos) == "number" and pos > 0 then
            local ps_ = tostring(pos)
            for _, pw in ipairs(e.posWidgets) do
                if U.ok(pw) then
                    local t = pw.Txt_CurrentPosition
                    if U.ok(t) and textOf(t) ~= ps_ then setText(t, ps_) end
                end
            end
        end
    end
    -- boost/ramjet/throttle icons are bound to player index 0's pawn by the BP [HUD 2]: re-pointed to the guest's car
    -- (rebindToGuestCar), plus the polled push below (only on a value change, so no animation restarts every poll)
    if e.pnum ~= 1 and e.bot and U.ok(e.bot) then U.try(TAG, checkVehicleState, e) end
    if e.pnum ~= 1 then U.try(TAG, rebindToGuestCar, e) end
    if cfg.GuestBotEngineFix and e.pnum ~= 1 and e.bot and U.ok(e.bot) and not e.botFixFailed then
        local pawn = e.pc.Pawn
        if U.isVehicle(pawn) then
            local vs = pawn.VehicleState -- AVehiclePawn.VehicleState (UVehicleState)
            if U.ok(vs) then
                -- VERIFY(V-HUD-10): calling the BP handlers with the guest car's state fixes the icons.
                -- Params (bpprops): OnRamjetAvailabilityChanged(Enum availability), OnBoostToggleChanged(Bool on),
                -- OnThrottleToggleChanged(Bool on). Fallback: cfg.GuestBotEngineFix = false.
                -- pcall, not U.try: a class without these BP functions (e.g. WBP_HUD_BotEngineInfo_Memory_C, no
                -- listing) would log a traceback per guest per poll. First failure disables the fix for this HUD.
                local ok, err = pcall(function()
                    local ra, bo, th = vs.RamjetAvailability, vs.BoostToggledOn == true, vs.ThrottleToggledOn == true
                    local last = e.botLast or {}
                    if last.ra ~= ra then e.bot:OnRamjetAvailabilityChanged(ra) end
                    if last.bo ~= bo then e.bot:OnBoostToggleChanged(bo) end
                    if last.th ~= th then e.bot:OnThrottleToggleChanged(th) end
                    e.botLast = { ra = ra, bo = bo, th = th }
                end)
                if not ok then
                    e.botFixFailed = true
                    local okC, cp = pcall(function() return U.pathOf(e.bot:GetClass()) end)
                    U.warn(TAG, "GuestBotEngineFix disabled for P%s's HUD (%s): %s", tostring(e.pnum),
                        okC and tostring(cp) or "?", tostring(err))
                end
            end
        end
    end
end

-- Post-hook of WBP_Hud_EventLapCounter[_Memory]_C:UpdateCurrentLap (BP: runs after the body, every Tick for
-- the Memory variant). Re-applies the cached guest text so the BP's global (P1) lap never shows.
function M.onLapCounterUpdated(ctx)
    local h = H()
    local lc = ctx:get()
    local pk = h.lapCounters[U.key(lc)]
    if not pk then return end
    local e = h.guests[pk]
    if e then writeLap(e, lc) end
end

local function applyVis(w, show, cacheTable)
    local want = show and VIS_SHOW or VIS_HIDE
    if cacheTable then
        if cacheTable.shown == show then return end
        cacheTable.shown = show
    elseif w:GetVisibility() == want then -- GetVisibility() -> Enum
        return
    end
    w:SetVisibility(want) -- SetVisibility(Enum InVisibility)
end

-- A local player who is out of the race (wrecked, spectating) gets no HUD: its car is gone, the HUD would show frozen
-- data of the wreck over the spectate view (run E: P2 wrecked, its HUD stayed). cfg.HudOutPlayers = "hide" (default)
-- | "keep". Sources: wreck.lua's per-world record (St.wreck.seen[pcKey] = wrecked), else the PC's view target being a
-- spectator camera (BP_SpectatorCameraActor_C). A player who FINISHED keeps its HUD (final lap/position).
-- VERIFY(V-HUD-15): "P2 HUD hidden: out of the race (wrecked)" once when P2 wrecks; no HUD line spam afterwards.
local function playerOut(e)
    if cfg.HudOutPlayers == "keep" then return false end
    local w = St.wreck
    if type(w) == "table" and w.gen == St.worldGen and type(w.seen) == "table" and w.seen[U.key(e.pc)] == true then
        return true, "wrecked"
    end
    local ok, n = pcall(function()
        local vt = e.pc:GetViewTarget()                 -- AController:GetViewTarget() -> Actor
        if not U.ok(vt) then return "" end
        return vt:GetClass():GetFName():ToString()
    end)
    if ok and type(n) == "string" and n:find("Spectator", 1, true) then return true, "spectating (" .. n .. ")" end
    return false
end

local function noteOut(h, e, out, why)
    h.outLogged = h.outLogged or {}
    local k = U.key(e.pc)
    if (h.outLogged[k] or false) == out then return end
    h.outLogged[k] = out
    if out then
        U.log(TAG, "P%s HUD hidden: out of the race (%s)", tostring(e.pnum), tostring(why))
    else
        U.log(TAG, "P%s HUD follows the race again", tostring(e.pnum))
    end
end

-- Guest HUDs (and a re-hosted P1 HUD) follow the game's own HUD rules: hidden while paused
-- (CSM_PauseMenus_Active active, U.csmPaused; BP_CsmHideHudWhenPaused tests Idle, valid only while the pause
-- machine runs), hidden in CSM_RF_PostRacePhase, shown in the
-- *_InHud states or while that guest is still racing after P1 finished.                    [HUD 3.2, 7.4]
function M.updateVisibility()
    local h = H()
    local postPhase = (St.phase == "POSTRACE")
    local paused, post, inHud, unknown
    if cfg.HudVisibilityMode == "csm" then
        -- VERIFY(V-HUD-05): IsStateActiveByRef sees these nested CSM states (booleans, not nil).
        -- VERIFY(V-HUD-06): player-screen widgets draw over the viewport-wide pause menu (so hiding is needed).
        -- Fallback: cfg.HudVisibilityMode = "always".
        -- find-only (no LoadAsset from the MAIN poll, ARCHITECTURE round 3); an asset not in memory = unknown (nil).
        -- pause detected positively (CSM_PauseMenus_Active active, U.csmPaused): "Idle inactive" also holds after
        -- P1 finished (race CSM in LocalResults, pause machine stopped) and would hide the guests still racing.
        local pz = U.csmPaused()
        local pst = csmPoll("CSM_PostRace")
        inHud = inHudState()
        unknown = (pz == nil and pst == nil and inHud == nil)
        if unknown then
            U.logOnce("hud.csmnil", TAG, "no CSM state resolvable; HUD visibility falls back to 'until POSTRACE'")
        end
        paused = (pz == true)
        -- The phase only when the CSM cannot answer: phase POSTRACE may come from bIsRaceFinished, whose meaning is
        -- not established (V-DIAG-01); a resolvable "post-race not active" keeps guests that still race on their HUD.
        post = (pst == true) or (pst == nil and postPhase)
    else
        unknown = true
    end
    if unknown then
        paused, post, inHud = false, postPhase, true
    elseif inHud == nil then
        inHud = true -- pause/post known, in-HUD states not resolvable: do not hide on that basis
    end
    -- present.lua runs cinematic/intro/results phases as ONE full-screen view (P1's): a guest has no view then, so
    -- its HUD is hidden whatever the CSM says (a widget on a zero-size player slot must not draw over P1's view).
    local single = false
    local present = lazy("present")
    if present and present.isSingleView then
        local okS, s = pcall(present.isSingleView)
        single = okS and s == true
    end
    for _, e in pairs(h.guests) do
        local out, outWhy = false, nil
        if U.ok(e.widget) and St.race.started then out, outWhy = playerOut(e) end
        noteOut(h, e, out, outWhy)
        if U.ok(e.widget) and single and e.pnum ~= 1 then
            U.try(TAG, applyVis, e.widget, false, e)
        elseif U.ok(e.widget) and out then
            U.try(TAG, applyVis, e.widget, false, e)
        elseif U.ok(e.widget) then
            local racing = false
            if St.race.started and not unknown then
                local ps = racerPS(e.pc)
                local comp = U.ok(ps) and ps.RaceEventComponent or nil
                if comp and U.ok(comp) then
                    local ok, r = U.try(TAG, function() return comp:IsStillRacing() end)
                    racing = ok and r == true
                end
            end
            local show = (not paused) and (not post) and (inHud or racing)
            U.try(TAG, applyVis, e.widget, show, e)
        end
    end
    if p1Mode() == "rehost" and h.p1Placed and U.ok(h.p1hud) then
        -- the UIManager may no longer remove a widget we moved out of its layer [UI 5 #2]
        U.try(TAG, applyVis, h.p1hud, (not paused) and (not post) and inHud, nil)
    end
end

-- Any local guest (not P1) still racing, by its racer PlayerState (adopted/AI PS after a takeover).
local function guestStillRacing(h)
    for _, e in pairs(h.guests) do
        if e.pnum ~= 1 and U.ok(e.pc) then
            local ps = racerPS(e.pc)
            local comp = U.ok(ps) and ps.RaceEventComponent or nil
            if comp and U.ok(comp) then
                local ok, r = U.try(TAG, function() return comp:IsStillRacing() end)
                if ok and r == true then return true end
            end
        end
    end
    return false
end

local function findLocalResults(h)
    if U.ok(h.results) then return h.results end
    local cls = loadedClass(C.BP.PostRaceInfo)        -- loaded once the CSM shows it; never LoadAsset here
    if not cls then return nil end
    local mgr = U.giSubsystem("UIManager")
    if U.ok(mgr) then
        for _, layer in ipairs(RESULTS_LAYERS) do
            local ok, w = U.try(TAG, function() return mgr:GetWidgetInLayer(cls, layer) end)
            if ok and U.ok(w) then
                U.logOnce("hud.resultslayer", TAG, "WBP_PostRace_Info_C found in UIManager layer %d", layer)
                return w
            end
        end
    end
    local now = St.nowMs()
    if now - (h.lastResultsSearchMs or -1e9) < FALLBACK_SEARCH_MS then return nil end
    h.lastResultsSearchMs = now
    local all = FindAllOf("WBP_PostRace_Info_C")      -- nil or a Lua table [API 6]; <= 1 per 2 s
    if all then
        for _, w in ipairs(all) do
            if U.ok(w) and (w:IsInViewport() == true or U.ok(w:GetParent())) then
                U.logOnce("hud.resultsfallback", TAG, "WBP_PostRace_Info_C found by FindAllOf")
                return w
            end
        end
    end
    return nil
end

-- P1 finished, a local guest still races: CSM_RF_LocalResults shows WBP_PostRace_Info_C over the whole viewport
-- [HUD§3.3], covering the guests' views. cfg.LocalResultsMode: "hide" collapses it until no local guest races any
-- more (then its visibility is given back), "rehost" moves it into P1's view once (RemoveFromParent +
-- AddToPlayerScreen, like the P1 HUD), "leave" does nothing. "hide_inactive" = "hide" plus DeactivateWidget() while
-- hidden (ActivateWidget() when given back): a collapsed panel is still an ACTIVATED CommonUI widget, whose action
-- bindings (continue/spectate/skip) keep reacting to P1's pad and whose desired input config is applied through
-- P1's controller and the viewport, which may change the game input of the guests that still race.
-- VERIFY(V-HUD-13): 3P race, P1 finishes first: P2/P3 views stay unobstructed; P1 sees the panel again (hide) or in
-- its own view (rehost) once everyone finished; while hidden, P1 pressing A / Start must not stop P2/P3 steering
-- (else cfg.LocalResultsMode = "hide_inactive"). The first sighting logs IsActivated / bIsModal / the desired input
-- config for that check.
local function logResultsInput(w)
    U.try(TAG, function()
        local act = w:IsActivated()                    -- UCommonActivatableWidget:IsActivated() -> Bool
        local modal = w.bIsModal                       -- UCommonActivatableWidget.bIsModal (Bool property)
        local cfgDesc = "?"
        -- BP_GetDesiredInputConfig() -> Struct FUIInputConfig (BlueprintNativeEvent, 0 params); may not be callable
        local okC, ic = pcall(function() return w:BP_GetDesiredInputConfig() end)
        if okC and type(ic) == "table" then
            local parts = {}
            for k, v in pairs(ic) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
            table.sort(parts)
            cfgDesc = "{" .. table.concat(parts, ", ") .. "}"
        elseif okC and ic ~= nil then
            cfgDesc = tostring(ic)
        end
        U.log(TAG, "local results panel input: IsActivated=%s bIsModal=%s DesiredInputConfig=%s", tostring(act),
            tostring(modal), cfgDesc)
    end)
end

function M.manageLocalResults()
    local h = H()
    local mode = cfg.LocalResultsMode
    if mode ~= "hide" and mode ~= "hide_inactive" and mode ~= "rehost" then return end
    local hideMode = (mode == "hide" or mode == "hide_inactive")
    local active = U.csmActive("CSM_LocalResults", true)  -- find-only (MAIN poll): not in memory = not shown
    if active == true and guestStillRacing(h) then
        local w = findLocalResults(h)
        if not w then return end
        if not sameObj(w, h.results) then
            h.results, h.resultsVis, h.resultsRehosted, h.resultsDeactivated = w, nil, false, false
            U.log(TAG, "local results panel shown while guests race: %s (%s)", mode, U.pathOf(w))
            logResultsInput(w)
        end
        if hideMode then
            local cur = w:GetVisibility()
            if h.resultsVis == nil then h.resultsVis = cur end
            if cur ~= VIS_HIDE then w:SetVisibility(VIS_HIDE) end   -- re-applied: the CSM/BP may show it again
            if mode == "hide_inactive" and w:IsActivated() == true then
                w:DeactivateWidget()                   -- UCommonActivatableWidget:DeactivateWidget()
                h.resultsDeactivated = true
                U.dbg(TAG, "local results panel deactivated while hidden")
            end
        elseif not h.resultsRehosted then
            h.resultsRehosted = true
            if not U.ok(w:GetOwningPlayer()) then
                local p1 = U.p1()
                if U.ok(p1) then w:SetOwningPlayer(p1) end
            end
            if U.ok(w:GetParent()) or w:IsInViewport() == true then w:RemoveFromParent() end
            local okA, added = U.try(TAG, function() return w:AddToPlayerScreen(0) end)
            if not (okA and added == true) then
                U.warn(TAG, "local results: AddToPlayerScreen returned %s; panel put back on the viewport", tostring(added))
                U.try(TAG, function() w:AddToViewport(0) end)
            end
        end
        return
    end
    if h.results ~= nil then
        local w = h.results
        if U.ok(w) then
            if h.resultsDeactivated then
                -- given back only while its CSM state still shows it (an ended state deactivates it itself)
                if active == true then U.try(TAG, function() w:ActivateWidget() end) end
                h.resultsDeactivated = false
            end
            if hideMode and h.resultsVis ~= nil then
                U.try(TAG, function() w:SetVisibility(h.resultsVis) end)
            elseif h.resultsRehosted and active ~= true then
                -- the state ended: the UIManager no longer owns the widget we moved
                U.try(TAG, function() w:RemoveFromParent() end)
            end
        end
        if active ~= true or not U.ok(w) then
            h.results, h.resultsVis, h.resultsRehosted, h.resultsDeactivated = nil, nil, false, false
        elseif hideMode then
            h.resultsVis = nil                         -- shown again; a later re-hide saves the current value
        end
    end
end

-- wreck.lua (2026-10-07): P1 wrecked while a guest still races. P1's race CSM (the only one: it is bound to P1) goes
-- CSM_RF_Spectating -> CSM_RF_SpectatingInProgress, which shows WBP_PVP_Spectate_C through the UIManager over the WHOLE
-- viewport (the guests' views too) until the DNF moves it to LocalResults (offline: about one tick; manageLocalResults
-- then takes over). cfg.SpectateWidgetMode: "hide" collapses it while a guest races (visibility given back after),
-- "hide_inactive" also DeactivateWidget()s it while hidden (pcall: it may not be a CommonActivatableWidget), "leave".
-- VERIFY(V-WD-11): P1 wrecked, P2 racing: P2's view stays clear; the log line "spectate panel shown while guests race".
local function findSpectateWidget(h)
    if U.ok(h.spectate) then return h.spectate end
    local cls = loadedClass(C.BP.PvpSpectate)          -- loaded once the CSM shows it; never LoadAsset here
    if not cls then return nil end
    local mgr = U.giSubsystem("UIManager")
    if U.ok(mgr) then
        for _, layer in ipairs(RESULTS_LAYERS) do
            local ok, w = U.try(TAG, function() return mgr:GetWidgetInLayer(cls, layer) end)
            if ok and U.ok(w) then return w end
        end
    end
    local now = St.nowMs()
    if now - (h.lastSpectateSearchMs or -1e9) < FALLBACK_SEARCH_MS then return nil end
    h.lastSpectateSearchMs = now
    for _, w in ipairs(FindAllOf("WBP_PVP_Spectate_C") or {}) do   -- nil or a Lua table [API 6]; <= 1 per 2 s
        if U.ok(w) and (w:IsInViewport() == true or U.ok(w:GetParent())) then return w end
    end
    return nil
end

function M.manageSpectateWidget()
    local h = H()
    local mode = cfg.SpectateWidgetMode
    if mode ~= "hide" and mode ~= "hide_inactive" then return end
    local a = U.csmActive("CSM_SpectatingInProgress", true)   -- find-only (MAIN poll)
    local b = U.csmActive("CSM_Spectating", true)
    local active = (a == true) or (b == true)
    if active and guestStillRacing(h) then
        local w = findSpectateWidget(h)
        if not w then return end
        if not sameObj(w, h.spectate) then
            h.spectate, h.spectateVis, h.spectateDeactivated = w, nil, false
            U.log(TAG, "spectate panel shown while guests race: %s (%s)", mode, U.pathOf(w))
        end
        local cur = w:GetVisibility()
        if h.spectateVis == nil then h.spectateVis = cur end
        if cur ~= VIS_HIDE then w:SetVisibility(VIS_HIDE) end     -- re-applied: the CSM/BP may show it again
        if mode == "hide_inactive" and not h.spectateDeactivated then
            local okA, act = pcall(function() return w:IsActivated() end)
            if okA and act == true and pcall(function() w:DeactivateWidget() end) then h.spectateDeactivated = true end
        end
        return
    end
    if h.spectate ~= nil then
        local w = h.spectate
        if U.ok(w) then
            if h.spectateDeactivated and active then pcall(function() w:ActivateWidget() end) end
            if h.spectateVis ~= nil then U.try(TAG, function() w:SetVisibility(h.spectateVis) end) end
        end
        h.spectate, h.spectateVis, h.spectateDeactivated = nil, nil, false
    end
end

-- wreck.lua fallback only (the GameMode's timeout byte could not be used): RaceTimeoutTime is parked at 1e9, so
-- WBP_Hud_EventTimes_List:UpdateTimeRemaining shows a huge "Remaining" line (it shows while T > now). Its Remaining
-- member is collapsed on every HUD we host and on the game's HUD, re-applied every MAIN tick (the BP re-shows it).
-- VERIFY(V-WD-02 fallback): no "Remaining" line on any HUD after "race timeout parked at 1e9".
local function collapseRemaining(h)
    local targets = {}
    for _, e in ipairs(M.allHuds()) do targets[#targets + 1] = e.widget end
    if U.ok(h.p1hud) then targets[#targets + 1] = h.p1hud end
    h.remainingLists = h.remainingLists or {}
    h.remainingRetryMs = h.remainingRetryMs or {}
    local now = St.nowMs()
    for _, w in ipairs(targets) do
        local k = U.key(w)
        local lists = h.remainingLists[k]
        -- an empty result is not cached (the list may not be built yet): searched again every 3 s
        if not lists and now - (h.remainingRetryMs[k] or -1e9) >= 3000 then
            h.remainingRetryMs[k] = now
            lists = collect(w, { ["wbp_hud_eventtimes_list"] = true })["wbp_hud_eventtimes_list"]
            if lists and #lists > 0 then h.remainingLists[k] = lists else lists = nil end
        end
        lists = lists or {}
        for _, lst in ipairs(lists) do
            U.try(TAG, function()
                local r = U.ok(lst) and lst.Remaining or nil     -- WBP_Hud_EventTimes_List.Remaining (BP variable)
                if U.ok(r) and r:GetVisibility() ~= VIS_HIDE then r:SetVisibility(VIS_HIDE) end
            end)
        end
    end
end

local function wreckHidesRemaining()
    return type(St.wreck) == "table" and St.wreck.hideRemaining == true
end

-- Hot reload: HUDs a previous Lua state created for the guests are unknown to h.guests; remove every FuseHudWidget
-- owned by a local guest PC that is not ours, once per race, before our guest HUDs are created.
local function sweepOrphanHuds(h, lps)
    h.orphansSwept = true
    local guestPC = {}
    for _, lp in ipairs(lps) do
        if lp.index >= 2 and U.ok(lp.pc) then guestPC[U.key(lp.pc)] = true end
    end
    if next(guestPC) == nil then return end
    -- 0.7.0: the game's own race HUD is owned by a guest PC in a split race and sits on the VIEWPORT with no parent
    -- (UIManager HUD layer = AddToViewport, ux-split-inventory §1): it must never be taken for an orphan.
    local gameHuds = {}
    local mgr = U.giSubsystem("UIManager")
    for _, hc in ipairs(HUD_CLASS_KEYS) do
        local cls = loadedClass(C.BP[hc.key])
        if cls and U.ok(mgr) then
            local ok, g = pcall(function() return mgr:GetWidgetInLayer(cls, C.E.UILayer.HUD) end)
            if ok and U.ok(g) then gameHuds[U.key(g)] = true end
        end
    end
    if U.ok(h.p1hud) then gameHuds[U.key(h.p1hud)] = true end
    local all = FindAllOf("FuseHudWidget")             -- nil or a Lua table [API 6]; once per race
    if not all then return end
    local n = 0
    for _, w in ipairs(all) do
        U.try(TAG, function()
            -- Only widgets sitting directly on a player screen (no parent panel) are orphans of a previous Lua state:
            -- sub-widgets of any HUD have a parent; the game's own HUD is excluded above.
            if U.ok(w) and not isOurs(w) and not gameHuds[U.key(w)] and guestPC[U.key(w:GetOwningPlayer())]
                and not U.ok(w:GetParent()) and w:IsInViewport() == true then
                U.try(TAG, function() w:UnregisterInputComponent() end)
                w:RemoveFromParent()
                n = n + 1
            end
        end)
    end
    if n > 0 then U.warn(TAG, "removed %d guest HUD(s) of a previous mod instance (hot reload)", n) end
end

-- Hot reload with cfg.P1HudMode = "clone": the P1-owned clone made by the previous Lua state is unknown to h.guests
-- and would stay on P1's screen under the new clone. Removes every P1-owned WBP_Hud_Race_C / WBP_Hud_Memory_C that is
-- neither ours nor the game's own HUD (UIManager:GetWidgetInLayer(cls, HUD)). Restricted to those two classes: other
-- FuseHudWidgets owned by P1 are sub-widgets of the game's HUD. Runs only once the game's HUD is resolved through the
-- UIManager (else nothing tells the game's HUD from an orphan clone); retried each tick until then, once per race.
-- VERIFY(V-CORE-11): Ctrl+F11 in a clone-mode race leaves exactly one HUD on P1's view.
local function sweepOrphanP1Clones(h)
    if p1Mode() ~= "clone" then h.p1OrphansSwept = true; return end
    local p1 = U.p1()
    local mgr = U.giSubsystem("UIManager")
    if not (U.ok(p1) and U.ok(mgr)) then return end
    local classes, gameHuds = {}, {}
    for _, k in ipairs({ "HudRace", "HudMemory" }) do
        local cls = loadedClass(C.BP[k])
        if cls then
            classes[#classes + 1] = cls
            local ok, w = U.try(TAG, function() return mgr:GetWidgetInLayer(cls, C.E.UILayer.HUD) end)
            if ok and U.ok(w) and not isOurs(w) then gameHuds[#gameHuds + 1] = w end
        end
    end
    if #gameHuds == 0 then return end                  -- the game's HUD is not resolvable yet: try again later
    h.p1OrphansSwept = true
    local all = FindAllOf("FuseHudWidget")             -- nil or a Lua table [API 6]; once per race
    if not all then return end
    local n = 0
    for _, w in ipairs(all) do
        U.try(TAG, function()
            if not U.ok(w) or isOurs(w) or sameObj(w, h.p1hud) then return end
            local isGame = false
            for _, g in ipairs(gameHuds) do if sameObj(g, w) then isGame = true end end
            if isGame or not sameObj(w:GetOwningPlayer(), p1) then return end
            local hudClass = false
            for _, cls in ipairs(classes) do
                local okA, isA = pcall(function() return w:IsA(cls) end)  -- UObject:IsA(UClass) [UE4SS]
                if okA and isA == true then hudClass = true end
            end
            if not hudClass then return end
            U.try(TAG, function() w:UnregisterInputComponent() end)
            w:RemoveFromParent()
            n = n + 1
        end)
    end
    if n > 0 then U.warn(TAG, "removed %d P1 HUD clone(s) of a previous mod instance (hot reload)", n) end
end

-- 0.11.0: the MAIN tick's layout pass (after the guest loop): every HUD we host follows its player's view, applied only
-- when its plan changes (a new HUD, the F8 2P flip, a guest leaving, one view / split, a window resize). One view: P1's
-- HUD covers the screen (designer layout), the guests' are hidden and keep their split layout. The game's own HUD in
-- "leave" (whole viewport) or "clone" (hidden) mode keeps the fit only.
-- VERIFY(V-HUD-18): F8 / a guest leaving / the results switch a HUD between "narrow view" and "designer layout".
function M.updateLayouts(lps)
    if cfg.HudFitInterior == false or cfg.HudNarrowViews ~= "readable" then return end
    local h = H()
    local views, full, single = viewSizes(lps)
    local idxOf = {}
    for _, lp in ipairs(lps) do if U.ok(lp.pc) then idxOf[U.key(lp.pc)] = lp.index end end
    for k, e in pairs(h.guests) do
        if idxOf[k] then layoutEntry(e, idxOf[k], views, full, single) end
    end
    if p1Mode() == "rehost" and h.p1Placed and U.ok(h.p1hud) then
        h.gameLayout = h.gameLayout or {}              -- dropped in releaseP1 / clearAll (releaseGameLayout)
        U.tryEvery("hud.layout", nil, TAG, layoutHud, h.p1hud, "game", (single or not views[1]) and full or views[1],
            h.gameLayout, false)
    end
end

-- 0.11.0 (diag / test probes): every hosted HUD's layout record as plain values.
function M.layoutStatus()
    local h = H()
    local out = { off = narrowOff }
    for _, e in pairs(h.guests or {}) do
        local st = e.layout or {}
        out[#out + 1] = { who = "P" .. tostring(e.pnum), key = st.key, failKey = st.failKey, holo = st.holo ~= nil }
    end
    if h.gameLayout then out[#out + 1] = { who = "game", key = h.gameLayout.key, failKey = h.gameLayout.failKey } end
    return out
end

function M.tick()
    local h = H()
    -- present.lua (view layout per race-flow state, per-player ignition screens) runs first, so that this tick's
    -- visibility already knows whether the race is on one view. Driven from here until main.lua calls it itself
    -- (cfg.PresentFromMain = true once main.lua has the present.tick() call).
    if cfg.PresentFromMain ~= true then
        local present = lazy("present")
        if present and present.tick then U.try(TAG, present.tick) end
    end
    local ph = St.phase
    if ph ~= "PRERACE" and ph ~= "RACING" and ph ~= "POSTRACE" then return end
    -- photo mode (run E: both PCs possess BP_PhotoModePawn_C): every HUD we host is hidden and nothing is created,
    -- re-placed or re-bound until it closes (the photo pawns are no cars; the game's photo HUD needs the screen).
    -- VERIFY(V-HUD-16): "photo mode open ... HUD work paused" once, "photo mode closed" once, nothing in between.
    local photoOn, photoWhy = photoActive()
    if photoOn then
        if not h.photoHidden then
            h.photoHidden = true
            U.log(TAG, "photo mode open (%s): every HUD we host hidden, HUD work paused", tostring(photoWhy))
        end
        for _, e in pairs(h.guests) do
            if U.ok(e.widget) then U.try(TAG, applyVis, e.widget, false, e) end
        end
        if p1Mode() == "rehost" and h.p1Placed and U.ok(h.p1hud) then U.try(TAG, applyVis, h.p1hud, false, nil) end
        return
    elseif h.photoHidden then
        h.photoHidden = false
        for _, e in pairs(h.guests) do e.shown = nil end  -- applyVis' cache: re-applied by updateVisibility below
        U.log(TAG, "photo mode closed: HUDs follow the race again")
    end
    local lps = U.localPlayers()
    -- prune HUDs of players that are gone (F7 leave, travel re-created the PC, widget collected)
    local present = {}
    for _, lp in ipairs(lps) do if U.ok(lp.pc) then present[U.key(lp.pc)] = true end end
    for k, e in pairs(h.guests) do
        if not present[k] or not U.ok(e.pc) or not U.ok(e.widget) then M.removeGuest(k) end
    end
    -- St.race.singleView: guests of a race the mod did not launch (join's "race_enter" guard), no guest views
    if #lps < 2 or St.race.singleView == true then
        -- The last guest just left (F7) or the views were dropped: give back what is still applied. The guests are
        -- pruned, so guestStillRacing() is false and manageLocalResults() restores a hidden/deactivated results
        -- panel; updateVisibility() keeps a re-hosted P1 HUD (or the P1 clone) following the pause/post-race rules
        -- (it would otherwise stay as last set, e.g. Collapsed if a guest left while paused).
        if h.results ~= nil or h.spectate ~= nil or (p1Mode() == "rehost" and h.p1Placed) or next(h.guests) ~= nil then
            U.try(TAG, M.updateVisibility)
            U.try(TAG, M.manageLocalResults)
            U.try(TAG, M.manageSpectateWidget)
        end
        -- 0.11.0: P1's clone / re-hosted HUD goes back to the designer layout once its view covers the screen (V-HUD-18)
        if next(h.guests) ~= nil or h.gameLayout ~= nil then U.tryEvery("hud.layouts", nil, TAG, M.updateLayouts, lps) end
        return
    end
    if not h.orphansSwept then U.try(TAG, sweepOrphanHuds, h, lps) end
    if not h.p1OrphansSwept then U.try(TAG, sweepOrphanP1Clones, h) end
    local p1hud = M.findP1Hud()
    if p1hud then
        h.noHudSinceMs, h.fallbackCls = nil, nil
    else
        -- FALLBACK (session B: the game's HUD was never found, so P2 got no HUD at all). Once the race is in a HUD
        -- state and a race-HUD class is in memory for cfg.HudFallbackAfterMs without a game HUD found, the guest
        -- HUDs (and, with cfg.HudFallbackP1Clone, P1's clone) are created from that class without p1hud. The game's
        -- viewport-wide HUD (if it is on screen unseen) cannot be hidden then: P1's clone is off by default so P1's
        -- data is not drawn twice. EventInfo is not copied until a source HUD is found.
        -- VERIFY(V-HUD-02c): "HUD fallback" in the log means the lookup still fails in this build.
        local cls = loadedClass(C.BP.HudRace) or loadedClass(C.BP.HudMemory)
        local now = St.nowMs()
        if cls and inHudState() == true then
            h.noHudSinceMs = h.noHudSinceMs or now
        else
            h.noHudSinceMs = nil
        end
        if not h.fallbackCls and h.noHudSinceMs
            and now - h.noHudSinceMs >= (tonumber(cfg.HudFallbackAfterMs) or 4000) then
            h.fallbackCls = cls
            U.warn(TAG, "HUD fallback: the game's race HUD was not found for %.0f ms; guest HUDs created from %s "
                .. "(the game's viewport-wide HUD cannot be hidden; EventInfo not copied) (V-HUD-02c)",
                now - h.noHudSinceMs, U.pathOf(cls))
        end
        if not h.fallbackCls then
            U.logEvery("hud.nop1", 5000, TAG, "P1 HUD not found yet (classes in memory: Race=%s Memory=%s; in-HUD "
                .. "state %s)", tostring(loadedClass(C.BP.HudRace) ~= nil), tostring(loadedClass(C.BP.HudMemory) ~= nil),
                tostring(inHudState()))
            return
        end
    end
    if p1hud then
        U.try(TAG, M.placeP1)
    elseif cfg.HudFallbackP1Clone == true and cfg.P1HudMode == "clone" then
        U.try(TAG, M.ensureGuest, U.p1(), 1)
    end
    local join = lazy("join")
    for _, lp in ipairs(lps) do
        if lp.index >= 2 and U.ok(lp.pc) then
            U.try(TAG, function()
                local pnum
                if join and join.displayNumForPC then pnum = join.displayNumForPC(lp.pc) end   -- unique per player
                local e = M.ensureGuest(lp.pc, pnum or lp.index)
                if e then M.patchGuest(e) end
            end)
        end
    end
    if cfg.P1HudMode == "clone" then
        local e = h.guests[U.key(U.p1())]
        if e then U.try(TAG, M.patchGuest, e) end
    end
    U.tryEvery("hud.layouts", nil, TAG, M.updateLayouts, lps)   -- 0.11.0 narrow views (V-HUD-17/18/19)
    U.try(TAG, M.calibrateLap)
    U.try(TAG, M.updateVisibility)
    U.try(TAG, M.manageLocalResults)
    U.try(TAG, M.manageSpectateWidget)
    if wreckHidesRemaining() then U.try(TAG, collapseRemaining, h) end
end

function M.clearAll()
    local h = H()
    if not h then return end
    local keys = {}
    for k in pairs(h.guests or {}) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do M.removeGuest(k) end
    releaseGameLayout(h, h.p1hud)                      -- 0.11.0: re-hosted game HUD back to its designer layout
    if U.ok(h.p1hud) then
        U.try(TAG, function()
            if cfg.P1HudMode == "rehost" and h.p1Placed then
                h.p1hud:RemoveFromParent()
            elseif cfg.P1HudMode == "clone" then
                h.p1hud:SetRenderOpacity(1.0)
            end
        end)
    end
    if h.results ~= nil and U.ok(h.results) then
        U.try(TAG, function()
            if h.resultsDeactivated and U.csmActive("CSM_LocalResults") == true then h.results:ActivateWidget() end
            if h.resultsVis ~= nil then h.results:SetVisibility(h.resultsVis)
            elseif h.resultsRehosted then h.results:RemoveFromParent() end
        end)
    end
    h.results, h.resultsVis, h.resultsRehosted, h.lastResultsSearchMs = nil, nil, false, nil
    h.resultsDeactivated = false
    if h.spectate ~= nil and U.ok(h.spectate) then
        U.try(TAG, function()
            if h.spectateVis ~= nil then h.spectate:SetVisibility(h.spectateVis) end
        end)
    end
    h.spectate, h.spectateVis, h.spectateDeactivated, h.lastSpectateSearchMs = nil, nil, false, nil
    h.remainingLists, h.remainingRetryMs = nil, nil
    h.p1hud, h.p1Placed, h.p1PlacedKey, h.rehostFailed, h.p1hudKey = nil, false, 0, false, nil
    h.swaps, h.swapWarned, h.photoHidden, h.outLogged = nil, false, false, nil
    h.tamedKey, h.tamed = nil, nil
    h.guests, h.lapCounters, h.found = {}, {}, {}
    h.lastSearchMs = nil
    if #keys > 0 then U.log(TAG, "cleared %d HUD(s)", #keys) end
end

-- Every HUD we host, P1's first: {pc, widget, pnum, markers} (markers = the HUD's vehicle-marker container
-- or nil; used by nametags). In "clone" mode P1's entry is our P1-owned copy.
function M.allHuds()
    local h = H()
    local out = {}
    local p1 = U.p1()
    if cfg.P1HudMode == "clone" then
        local e = U.ok(p1) and h.guests[U.key(p1)] or nil
        if e and U.ok(e.widget) then out[1] = { pc = e.pc, widget = e.widget, pnum = 1, markers = e.markers } end
    else
        local w = h.p1hud
        if not U.ok(w) then
            local ph = St.phase
            if ph == "PRERACE" or ph == "RACING" then
                local ok, r = U.try(TAG, M.findP1Hud)
                w = ok and r or nil
            end
        end
        if w and U.ok(w) then
            local mem = membersOf(w)
            out[1] = { pc = p1, widget = w, pnum = 1, markers = mem.markers }
        end
    end
    local rest = {}
    for _, e in pairs(h.guests) do
        if e.pnum ~= 1 and U.ok(e.widget) then
            rest[#rest + 1] = { pc = e.pc, widget = e.widget, pnum = e.pnum or 9, markers = e.markers }
        end
    end
    table.sort(rest, function(a, b) return a.pnum < b.pnum end)
    for _, r in ipairs(rest) do out[#out + 1] = r end
    return out
end

-- 0.7.0 (uxsplit.lua): every HUD we host (M.allHuds order, P1 first) with its notification containers:
-- { {pc, pnum, widget, bot, conts = { {w, name = TargetName, panel = NotificationSubPanel, tree = member name} }} }.
-- UNotificationContainerWidget.TargetName (FName @0x528) / NotificationSubPanel (@0x540) are read once per HUD
-- instance and kept in its member cache (a new instance is walked again).
function M.notifEntries()
    local out = {}
    for _, a in ipairs(M.allHuds()) do
        local mem = membersOf(a.widget)
        if mem.conts == nil then
            local conts = {}
            for _, n in ipairs(NOTIF_NAMES) do
                for _, x in ipairs((mem.raw or {})[string.lower(n)] or {}) do
                    if U.ok(x) then
                        local okT, tn = pcall(function() return x.TargetName:ToString() end)
                        local okP, panel = pcall(function() return x.NotificationSubPanel end)
                        if okT and type(tn) == "string" and okP and U.ok(panel) then
                            conts[#conts + 1] = { w = x, name = tn, panel = panel, tree = n }
                        end
                    end
                end
            end
            mem.conts = conts
            if #conts == 0 then
                U.logOnce("hud.noconts." .. U.pathOf(a.widget:GetClass()), TAG, "no notification container found in %s "
                    .. "(message routing has nothing to route there)", U.pathOf(a.widget:GetClass()))
            end
        end
        out[#out + 1] = { pc = a.pc, pnum = a.pnum, widget = a.widget, bot = mem.bot, conts = mem.conts }
    end
    return out
end

-- 0.7.0: the game's own race HUD while "clone" mode keeps it hidden (nil otherwise). uxsplit shows its own posts
-- (its elimination messages) nowhere and never remaps it.
function M.gameHudWidget()
    local h = H()
    if p1Mode() == "clone" and U.ok(h.p1hud) then return h.p1hud end
    return nil
end

function M.init()
    local h = H()
    h.guests = h.guests or {}
    h.lapCounters = h.lapCounters or {}
    h.found = h.found or {}
    -- OPTIONAL BP hooks (never fired in the 2026-10-06 runs): queued by U.hook until the lap-counter classes are
    -- loaded (race map). The MAIN poll (patchGuest -> writeLap) is the default lap path: Race-variant counters are
    -- rewritten only when the text differs, Memory-variant counters (rewritten by their BP every frame) stay
    -- collapsed for guests. Only once a hook is seen firing (lapHookAlive) does it take over: the Lua-side record
    -- then stops the poll from writing the same text again, and Memory counters are shown again.
    -- The wrappers record that each hook really fires, for P1's counters too.
    U.hook(C.FN.LapUpdate, { post = function(ctx)
        lapHookFired[C.FN.LapUpdate] = true
        return M.onLapCounterUpdated(ctx)
    end }, TAG)
    U.hook(C.FN.LapUpdateMemory, { post = function(ctx)
        lapHookFired[C.FN.LapUpdateMemory] = true
        return M.onLapCounterUpdated(ctx)
    end }, TAG)
    -- present.lua is not in main.lua's module list yet: initialised from here (its init is idempotent-safe:
    -- listeners only, registered once per Lua state).
    if cfg.PresentFromMain ~= true then
        local present = lazy("present")
        if present and present.init and not present._inited then
            present._inited = true
            U.try(TAG, present.init)
        end
    end
    St.on("leaving", TAG, function() M.clearAll() end)
    St.on("phase", TAG, function(new)
        if new == "FRONTEND" or new == "OTHER" or new == "LOADING" then M.clearAll() end
    end)
    U.log(TAG, "init: P1HudMode=%s, visibility=%s, lap patch=%s", tostring(cfg.P1HudMode),
        tostring(cfg.HudVisibilityMode), tostring(cfg.LapPatch))
end

return M
