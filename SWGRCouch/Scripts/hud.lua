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
local initWorldGen = nil      -- St.worldGen when this Lua state initialised hud.lua (hot-reload sweeps)

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
    if not U.ok(w) then return "" end         -- GetFName on a null wrapper is a native AV
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
local function loadedClass(path, missTtl)
    if type(path) ~= "string" then return nil end
    -- U.findLoaded: cached (raw StaticFindObject is ~2.5 ms in this build, 2026-10-13); missTtl for classes
    -- that appear mid-race (spectate, post-race) so their polls still see them within a second
    return U.findLoaded(path, missTtl)
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
        if not U.ok(o) then return false end  -- GetOuter on a null wrapper is a native AV
        local ok, nxt = pcall(U.callMethod, o, "GetOuter")
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
    if not (e and sameObj(e.widget, w)) or not U.ok(w) then return false end   -- U.ok: null w = native AV in GetClass
    local okC, cls = pcall(U.callMethod, w, "GetClass")
    if not okC or U.key(cls) ~= e.clsKey then return false end
    local okT, tree = pcall(U.getField, w, "WidgetTree")
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
    -- couch-fix63 (AUTO-152): the HUD's class and its BotEngineInfo's (read by name: WBP_Hud_CharacterHolo, the
    -- crash frame) stay loaded for the session; the HUD class's WidgetTree keeps the other nested classes
    U.pinClassOf(w, "race HUD")
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
    if res.bot then U.pinClassOf(res.bot, "HUD engine row") end
    local okC, cls = false, nil
    if U.ok(w) then okC, cls = pcall(U.callMethod, w, "GetClass") end   -- U.ok: null GetClass = native AV
    local okT, tree = pcall(U.getField, w, "WidgetTree")
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
        local ok, x = pcall(U.getField, bot, n)
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
    -- couch-livefix r2: dormant local players hold no view (split.lua): the joined players' own rects
    local vf = nil
    pcall(function() vf = lazy("split").viewFractions() end)
    if type(vf) == "table" then
        for _, lp in ipairs(lps) do
            local f = vf[lp.index]
            if f then views[lp.index] = { w = f.fw * full.w, h = f.fh * full.h } end
        end
        return views, full, single
    end
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
    local okO, owner = pcall(U.callMethod, w, "GetOwningPlayer") -- UWidget:GetOwningPlayer() -> Object
    if not okO or not U.ok(owner) then return "none", nil end
    for _, lp in ipairs(U.localPlayersRO()) do
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
    local okV, inVp = pcall(U.callMethod, w, "IsInViewport")
    local okP, par = pcall(U.callMethod, w, "GetParent")
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
                -- couch-fix63 (AUTO-152): kept loaded before any member of its instances is read by name (U.pinClass)
                U.pinClass(cls, "race HUD")
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

-- #37: a race-alone test's counter that soloscore.lua feeds from the guest's OWN score (his private RaceEventVM)
local function ownCounter(n)
    local ok, own = pcall(function() return U.mod("soloscore").ownsGuestCounter(n) end)
    if ok and own == true then return true end
    -- #86: the precision test's CHECKPOINT BONUS popup, fed from the guest's own gates (precision.lua)
    local okP, ownP = pcall(function() return U.mod("precision").ownsGuestCounter(n) end)
    return okP and ownP == true
end

-- #69 (tester #3, Sentinel I precision test): P2's HUD had no target-time line, P1's showed 01:45.00. WBP_Hud_BestLapTime
-- (decoded) shows the race VM's BestTime (bWantsBestTime: P1's own best = collapsed in a guest HUD) OR its
-- CurrentTargetTime (bWantsTargetTime: the event's target, picked by the shared clock) - the same for every player of a
-- race-alone test (couchsolo: field tests, podracer tests), so a guest keeps it there.
local function sharedTargetTime(n)
    if string.lower(n) ~= "wbp_hud_bestlaptime" then return false end
    local ok, yes = pcall(function()
        local cs = U.mod("couchsolo")
        if not cs.raceAlone() then return false end
        local vm = cs._raceVM()
        return U.ok(vm) and vm.bWantsTargetTime == true and vm.bWantsBestTime ~= true
    end)
    return ok and yes == true
end

-- soloscore.lua: the members named `name` of a guest HUD entry (its widget tree walk, cached)
function M.guestMembers(e, name)
    if not (e and U.ok(e.widget)) then return {} end
    local mem = membersOf(e.widget)
    local out = {}
    for _, x in ipairs((mem and mem.raw and mem.raw[string.lower(name)]) or {}) do if U.ok(x) then out[#out + 1] = x end end
    return out
end

local function collapseGlobalParts(e, mem)
    if e.pnum == 1 then return end -- P1's clone shows P1's own global data: nothing to hide
    -- #38 (progress.lua): the guest's own race-progress strip keeps the map's centre triangle (his own mark)
    local keep = nil
    local prog = lazy("progress")
    if prog and type(prog.guestKeeps) == "function" then
        local okK, k = pcall(prog.guestKeeps, e.widget)
        if okK and type(k) == "table" then keep = k end
    end
    for _, n in ipairs(cfg.GuestHudCollapse or {}) do
        local l = mem.raw[string.lower(n)]
        if ownCounter(n) then
            U.logOnce("hud.owncounter." .. n, TAG, "guest HUDs: %s kept (fed from each guest's own score: soloscore)", n)
        elseif sharedTargetTime(n) then
            U.logOnce("hud.target." .. n, TAG, "guest HUDs: %s kept (the test's target time: the same for every player)", n)
        elseif keep and keep[string.lower(n)] then
            U.logOnce("hud.keep." .. n, TAG, "guest HUDs: %s kept (the race-progress strip's own mark)", n)
        elseif l and #l > 0 then
            for _, x in ipairs(l) do
                if U.ok(x) then
                    x:SetVisibility(VIS_HIDE)
                    e.hidden[#e.hidden + 1] = x -- re-collapsed every poll (a BP may show it again)
                end
            end
        else
            U.logOnce("hud.nocollapse." .. n, TAG, "GuestHudCollapse member %s not found in %s", n,
                U.pathOf(U.ok(e.widget) and e.widget:GetClass() or nil))
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

M._collapseGlobalParts = collapseGlobalParts   -- for tools/test_progress.lua

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
    U.pinClass(cls, "race HUD")   -- couch-fix63 (AUTO-152): see util.lua U.pinClass
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
        local okO, o = pcall(U.callMethod, p1hud, "GetOwningPlayer")
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
        local okP, cp = pcall(function() return U.pathOf(U.ok(lc) and lc:GetClass() or nil) end)
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
-- Scanned in slices (VD_SLICE_EARLY / VD_SLICE delegates per MAIN tick): a full sweep every ~1.5 s for the first
-- ~10 s of a HUD (BP bindings may come late), then every ~2 s; a guest car
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
local VD_SLICE_EARLY, VD_SLICE = 10, 8   -- GetBindings per MAIN tick (first ~10 s of a HUD / afterwards)

local function ownedByPC(obj, pc)
    local ok, r = pcall(function() return sameObj(obj:GetOwningPlayer(), pc) end)
    return ok and r == true
end

-- 0.13.0 (Jules, live 2026-10-12: "the ramjet not working is gamebreaking": P2's ramjet bar never filled, overheat
-- not shown). WBP_HUD_RamjetBar / WBP_Hud_RamjetOverheatWarning / WBP_Hud_RamjetMessage bind their OWN player's car at
-- Construct (GetOwningPlayerPawn -> cast VehiclePawn -> VehicleDelegates += ..., the bar's InitState(VehicleState);
-- work/ramjet/*.disasm.txt). A guest HUD is created before the guest's car exists, so the cast fails and they stay
-- unbound for the whole race (the bar's Tick reads a null "Vehicle State": always empty). Once the guest drives a car:
-- if its bar's "Vehicle State" is not that car's, Construct is run again on the three widgets (they bind the car the
-- game's way). Once per car per HUD (a re-run on a bound widget would double its bindings).
local RAMJET_WIDGETS = { "WBP_HUD_RamjetBar_C", "WBP_Hud_RamjetOverheatWarning_C", "WBP_Hud_RamjetMessage_C" }
-- Race smoothness (Jules 2026-10-15: hud.tick spikes up to ~97 ms at the race start): the three FindAllOf walks above
-- (~30 ms each in a race world) ran in ONE MAIN tick per guest car. The widgets now report themselves through
-- NotifyOnNewObject (hud.init, one notify per class, the wrapper only stored: no UObject work in the callback) and
-- are read from that list. Without the notify (or no bar of this player reported after RJ_SEEN_WAIT_TICKS) the walk
-- runs one class per MAIN tick, and the two other classes are walked only when the bar is not bound yet.
local RAMJET_PATHS = {
    WBP_HUD_RamjetBar_C = "/Game/Griffin/UI/Widgets/HUD/WBP_HUD_RamjetBar.WBP_HUD_RamjetBar_C",
    WBP_Hud_RamjetOverheatWarning_C =
        "/Game/Griffin/UI/Widgets/HUD/WBP_Hud_RamjetOverheatWarning.WBP_Hud_RamjetOverheatWarning_C",
    WBP_Hud_RamjetMessage_C = "/Game/Griffin/UI/Widgets/HUD/WBP_Hud_RamjetMessage.WBP_Hud_RamjetMessage_C",
}
local RJ_SEEN_MAX = 64            -- wrappers kept per class (oldest dropped; dead ones pruned on read)
-- couch-racegc (live 2026-10-16: hud.fastAfterburner 16 spikes of 20-25 ms per race = its FindAllOf every 15 s; the
-- ramjet re-find walk ~19 more): the afterburner bars report themselves too; both re-finds read these lists.
local AB_PATH = "/Game/Griffin/UI/Widgets/HUD/WBP_HUD_Afterburner.WBP_HUD_Afterburner_C"   -- live class path
local abSeen = {}                 -- afterburner bar wrappers reported by NotifyOnNewObject (cleared on "leaving")
function M._abSeen(obj)
    if obj == nil then return end
    abSeen[#abSeen + 1] = obj
    if #abSeen > RJ_SEEN_MAX then table.remove(abSeen, 1) end
end
-- the live wrappers of a seen list (dead ones dropped from it)
local function seenAlive(list)
    local keep = {}
    for _, w in ipairs(list) do if U.ok(w) then keep[#keep + 1] = w end end
    return keep
end
local RJ_SEEN_WAIT_TICKS = 8      -- MAIN ticks (~2 s) a guest car waits for a reported bar before the walk fallback
local rjSeen = {}                 -- short class -> wrappers reported by NotifyOnNewObject (cleared on "leaving")

-- NotifyOnNewObject callback (hud.init): store only (the object is still being constructed).
function M._rjSeen(cn, obj)
    if obj == nil or RAMJET_PATHS[cn] == nil then return end
    local l = rjSeen[cn]
    if not l then l = {}; rjSeen[cn] = l end
    l[#l + 1] = obj
    if #l > RJ_SEEN_MAX then table.remove(l, 1) end
end
function M._rjSeenClear() rjSeen = {}; abSeen = {} end

-- the live wrappers of one class owned by pc: from the notify list (pruned), or one FindAllOf walk
local function ramjetOwned(cn, pc, fromWalk)
    local out, keep = {}, {}
    local src = fromWalk and (FindAllOf(cn) or {}) or (rjSeen[cn] or {})
    for _, w in ipairs(src) do
        if U.ok(w) then
            if not fromWalk then keep[#keep + 1] = w end
            pcall(function()
                if U.key(w:GetOwningPlayer()) == U.key(pc) then out[#out + 1] = w end
            end)
        end
    end
    if not fromWalk then rjSeen[cn] = keep end
    return out
end

local function rebindRamjet(e)
    if cfg.HudGuestRamjetFix == false then return end
    local pawn = e.pc.Pawn
    if not (U.ok(pawn) and U.isVehicle(pawn)) then return end
    local ck = U.key(pawn)
    if e.ramjetCar == ck then return end
    local vs = pawn.VehicleState
    if not U.ok(vs) then return end
    local function isBound(bars)
        local bound = false
        pcall(function() local cur = bars[1]["Vehicle State"]; bound = U.ok(cur) and U.key(cur) == U.key(vs) end)
        return bound
    end
    local bars, others
    local rw = e.rjWalk
    if rw and rw.ck ~= ck then rw = nil; e.rjWalk = nil end
    if not rw and _G.SWGRCouch_rjSeenNotify == true then
        bars = ramjetOwned(RAMJET_WIDGETS[1], e.pc, false)
        if #bars == 0 then
            e.rjSeenWait = (e.rjSeenWait or 0) + 1
            if e.rjSeenWait < RJ_SEEN_WAIT_TICKS then return end   -- the HUD's parts are not built yet: the next tick
            U.logOnce("hud.rjseenmiss", TAG, "ramjet bar of P%s not reported by NotifyOnNewObject: one FindAllOf per "
                .. "MAIN tick instead", tostring(e.pnum))
        else
            others = {}
            if not isBound(bars) then
                for i = 2, #RAMJET_WIDGETS do
                    for _, w in ipairs(ramjetOwned(RAMJET_WIDGETS[i], e.pc, false)) do others[#others + 1] = w end
                end
            end
        end
    end
    if not others then
        -- walk fallback: ONE class per MAIN tick (a FindAllOf is ~30 ms in a race world)
        rw = rw or { ck = ck, i = 1, bars = {}, others = {} }
        e.rjWalk = rw
        local cn = RAMJET_WIDGETS[rw.i]
        for _, w in ipairs(ramjetOwned(cn, e.pc, true)) do
            if rw.i == 1 then rw.bars[#rw.bars + 1] = w else rw.others[#rw.others + 1] = w end
        end
        if rw.i == 1 then
            if #rw.bars == 0 then e.rjWalk = nil; return end   -- the HUD's parts are not built yet: the next tick
            if isBound(rw.bars) then rw.i = #RAMJET_WIDGETS end -- bound: the other classes are not needed
        end
        if rw.i < #RAMJET_WIDGETS then rw.i = rw.i + 1; return end
        bars, others, e.rjWalk = rw.bars, rw.others, nil
    end
    if #bars == 0 then return end
    e.ramjetCar, e.rjSeenWait = ck, nil
    if isBound(bars) then
        U.log(TAG, "P%s ramjet bar already bound to its car (V-HUD-RJ)", tostring(e.pnum))
        return
    end
    local n = 0
    for _, w in ipairs(bars) do if pcall(function() w:Construct() end) then n = n + 1 end end
    for _, w in ipairs(others) do if pcall(function() w:Construct() end) then n = n + 1 end end
    local okB = isBound(bars)
    U.log(TAG, "P%s ramjet bar / overheat widgets bound to P%s's car: Construct re-run on %d widget(s), bar %s (V-HUD-RJ)",
        tostring(e.pnum), tostring(e.pnum), n, okB and "ok" or "STILL UNBOUND")
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
        -- a SLICE of the delegates per MAIN tick (race smoothness 2026-10-15: all 57 GetBindings in one tick, every
        -- tick for ~10 s and then every ~2 s, made the patchGuest spikes): a full sweep every ~1.5 s for the first
        -- ~10 s, then every ~2 s, as before
        local per = (r.ticks <= 40) and VD_SLICE_EARLY or VD_SLICE
        local names = {}
        for _ = 1, math.min(per, #VD_NAMES) do
            r.cursor = (r.cursor or 0) % #VD_NAMES + 1
            names[#names + 1] = VD_NAMES[r.cursor]
        end
        local vd = p1car.VehicleDelegates
        if not U.ok(vd) then return end
        -- 0.7.0 (V-UX-10): the game's own hidden HUD ("clone" mode) is owned by a guest PC too (the UIManager's owner in
        -- a split race), and its BotEngineInfo bound P1's car: those bindings are REMOVED (its ramjet animations wrote
        -- the global MPC, its critical-malfunction dimming is invisible anyway), never moved to the guest's car.
        local gameHud = (cfg.UxSplitGameHud ~= false and p1Mode() == "clone" and U.ok(H().p1hud)) and H().p1hud or nil
        local moved, stripped = 0, 0
        for _, name in ipairs(names) do
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
    -- couch-trial2: a mission with instances shows the place inside the player's OWN race (instances.lua)
    local instPos = nil
    if e.posWidgets and #e.posWidgets > 0 and U.ok(ps) then
        local inst = lazy("instances")
        if inst and type(inst.localPosition) == "function" then
            local okI, lp = pcall(inst.localPosition, ps)
            if okI and type(lp) == "number" then
                instPos = lp
                U.logOnce("hud.instpos" .. tostring(e.pnum) .. ":" .. tostring(St.worldGen), "instances", "HUD: P%s's position shows his own race's place "
                    .. "(%d now; global %s)", tostring(e.pnum), lp, tostring(comp and U.ok(comp) and comp.EventPosition))
            end
        end
    end
    if e.posWidgets and #e.posWidgets > 0 and comp and U.ok(comp) and U.ok(ps)
        and (instPos ~= nil or not sameObj(ps, e.pc.PlayerState)) then
        local pos = instPos or comp.EventPosition
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
    if e.pnum ~= 1 then U.try(TAG, rebindRamjet, e) end
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
    local cls = loadedClass(C.BP.PostRaceInfo, 1000)  -- loads at race end; 1 s miss TTL keeps the fallback fresh
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

-- couch-fix64 (AUTO-158e): the outro's WBP_PostRace_Info_C through the UIManager's layers only (no FindAllOf walk:
-- present.lua reads it in the full-screen outro, whose walk budget is spent) -> widget | nil
function M.postRaceInfo()
    local cls = loadedClass(C.BP.PostRaceInfo, 1000)
    if not cls then return nil end
    local mgr = U.giSubsystem("UIManager")
    if not U.ok(mgr) then return nil end
    for _, layer in ipairs(RESULTS_LAYERS) do
        local ok, w = pcall(function() return mgr:GetWidgetInLayer(cls, layer) end)
        if ok and U.ok(w) then return w end
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
        local okC, ic = pcall(U.callMethod, w, "BP_GetDesiredInputConfig")
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
    local cls = loadedClass(C.BP.PvpSpectate, 1000)    -- loads on the first wreck; 1 s miss TTL for the spectate poll
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
            local okA, act = pcall(U.callMethod, w, "IsActivated")
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
                local okA, isA = pcall(U.callMethod, w, "IsA", cls)  -- UObject:IsA(UClass) [UE4SS]
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

-- 0.13.0 (task #35, live 2026-10-11): once P1 is out of the race (wrecked or finished first) the game's global
-- RaceEventVM stops the event timer (CurrentEventTime is put back to -1 every frame), so every guest HUD still racing
-- reads "--:--.--" while P1's hidden copy freezes at P1's time. The HUD rewrites Txt_Time every frame (live 23:45: a
-- SetText from the FAST loop lost every frame), so a twin FuseTextBlock is added next to it in HB_TimerContent (same
-- font, colour, shadow and slot) and Txt_Time is collapsed; the twin shows the race clock
-- (RacingGameState:GetServerWorldTimeSeconds() - RaceStartTime, matches the game's timer). Proven live 2026-10-11
-- (P2's HUD showed 00:52.79 in the timer's place). A guest that finished or wrecked keeps its last value. FAST loop,
-- every 50 ms; nothing is touched while P1 still races (a new race builds new HUDs, so the twin goes with them).
local function fmtRaceTime(t)
    if t < 0 then t = 0 end
    local m = math.floor(t / 60)
    return string.format("%02d:%05.2f", m, t - m * 60)
end

local function guestTimerText(e)
    if U.ok(e.timerTxt) then return e.timerTxt end
    if (e.timerMiss or 0) >= 3 then return nil end
    local tx
    pcall(function()
        -- live 2026-10-11: WBP_Hud_EventTotalTime is not a property of WBP_HUD_RaceInfo (the tree walk descends into
        -- RaceInfo, DESCEND); WBP_Hud_EventTime_Item is a property of WBP_Hud_EventTotalTime_C (bpprops)
        local tl = collect(e.widget, { ["wbp_hud_eventtotaltime"] = true })["wbp_hud_eventtotaltime"]
        local tt = tl and tl[1]
        if not U.ok(tt) then return end
        local it = tt.WBP_Hud_EventTime_Item
        if not U.ok(it) then return end
        local l = collect(it, { ["txt_time"] = true })["txt_time"]
        tx = l and l[1]
    end)
    if U.ok(tx) then
        local tw
        local okT, err = pcall(function()
            tw = StaticConstructObject(tx:GetClass(), tx:GetOuter())
            tx:GetParent():AddChildToHorizontalBox(tw)
        end)
        if okT and U.ok(tw) then
            pcall(function() tw:SetFont(tx.Font) end)
            pcall(function() tw:SetColorAndOpacity(tx.ColorAndOpacity) end)
            pcall(function() tw:SetShadowOffset(tx.ShadowOffset) end)
            pcall(function() tw:SetShadowColorAndOpacity(tx.ShadowColorAndOpacity) end)
            pcall(function() tw.Slot:SetVerticalAlignment(tx.Slot.VerticalAlignment) end)
            pcall(function() tw.Slot:SetPadding(tx.Slot.Padding) end)
            e.timerTxt, e.timerOrig = tw, tx
            U.log(TAG, "P%s race timer: twin text in place of the game's (written while P1 is out of the race)",
                tostring(e.pnum))
            return tw
        end
        U.logOnce("hud.timertwin" .. tostring(e.pnum), TAG, "P%s race timer twin not made (%s)", tostring(e.pnum),
            tostring(err))
    end
    e.timerMiss = (e.timerMiss or 0) + 1
    if e.timerMiss >= 3 then
        U.logOnce("hud.timermiss" .. tostring(e.pnum), TAG, "P%s race timer text not found: its timer stays the game's",
            tostring(e.pnum))
    end
    return nil
end

local function stillRacingPC(pc)
    local ps = racerPS(pc)
    local comp = U.ok(ps) and ps.RaceEventComponent or nil
    if not (comp and U.ok(comp)) then return nil end
    local ok, r = pcall(U.callMethod, comp, "IsStillRacing")
    if not ok or type(r) ~= "boolean" then return nil end
    return r
end

-- 0.13.0 v2 GALAXY RUN: a live challenge line in each player's HUD, a second FuseTextBlock after the timer in
-- HB_TimerContent (same font / colour), written every 250 ms from run.liveText ("BOOST 23 S", "TAKEDOWNS 2", "BEST LAP
-- 34.21", "RIVAL <NAME>"). Only while a run race is in flight; split races (the guest / clone HUDs).
local function timerBox(e)
    if U.ok(e.timerOrigTx) then return e.timerOrigTx end
    local tx
    pcall(function()
        local tl = collect(e.widget, { ["wbp_hud_eventtotaltime"] = true })["wbp_hud_eventtotaltime"]
        local tt = tl and tl[1]
        local it = U.ok(tt) and tt.WBP_Hud_EventTime_Item or nil
        if not U.ok(it) then return end
        local l = collect(it, { ["txt_time"] = true })["txt_time"]
        tx = l and l[1]
    end)
    if U.ok(tx) then e.timerOrigTx = tx end
    return e.timerOrigTx
end

function M.fastChallenge()
    local h = H()
    if St.phase ~= "RACING" then return end
    local now = St.nowMs()
    if now < (h.chalNextMs or 0) then return end
    h.chalNextMs = now + 250
    local run = lazy("run")
    if not (run and run.inFlight and run.inFlight()) then return end
    local ctrlOf = {}
    local lps = U.localPlayers()
    for _, lp in ipairs(lps) do if U.ok(lp.pc) then ctrlOf[U.key(lp.pc)] = lp.ctrlId end end
    local entries = h.guests
    if next(h.guests) == nil and #lps == 1 then
        -- solo: no per-player HUD copies; the game's own race HUD carries the line (found once per race)
        -- the game's race HUD hud.lua tracks (h.p1hud), else the first one found; one line per HUD widget (kept
        -- while the same widget lives, so a phase flicker never adds a second line)
        -- 0.13.0 live (Jules, solo hot lap: "didn't read best lap"): h.p1hud is not always the race HUD and the first
        -- WBP_Hud_Race_C found can be a hidden one: the race HUD that is in the viewport, kept while it stays there
        local function onScreen(x)
            local ok, v = pcall(function() return x:IsInViewport() == true end)
            return ok and v
        end
        local w = h.soloChal and U.ok(h.soloChal.widget) and onScreen(h.soloChal.widget) and h.soloChal.widget or nil
        if not w then
            for _, x in ipairs(FindAllOf("WBP_Hud_Race_C") or {}) do
                if U.ok(x) and onScreen(x) then w = x; break end
            end
        end
        -- one entry per HUD widget (review 2026-10-12): a HUD briefly off screen that comes back keeps its own line
        -- instead of getting a second one
        if h.soloWorld ~= St.worldGen then h.soloWorld, h.soloByKey, h.soloChal = St.worldGen, {}, nil end
        if U.ok(w) then
            local k = U.key(w)
            local e = h.soloByKey[k]
            if not (e and U.ok(e.widget)) then
                e = { widget = w, pc = lps[1].pc, pnum = 1 }
                h.soloByKey[k] = e
            end
            h.soloChal = e
        end
        entries = (U.ok(w) and h.soloChal) and { solo = h.soloChal } or {}
    end
    for _, e in pairs(entries) do
        if U.ok(e.widget) and U.ok(e.pc) then
            local c = ctrlOf[U.key(e.pc)]
            local lap = -1
            pcall(function() lap = racerPS(e.pc).RaceEventComponent.BestLapTime end)
            local okT, text = pcall(run.liveText, c, lap)
            text = okT and text or nil
            -- a failed try (HUD not built yet) is retried every 2 s
            if text and not U.ok(e.chalTx) and St.nowMs() >= (e.chalRetryMs or 0) then
                local tx = timerBox(e)
                local okC = pcall(function()
                    if not U.ok(tx) then error("no timer text yet") end   -- GetClass on a null wrapper = native AV
                    local tw = StaticConstructObject(tx:GetClass(), tx:GetOuter())
                    tx:GetParent():AddChildToHorizontalBox(tw)
                    -- the timer's Font_Numbers has digits only (live: "BOOST 38 S" showed "38"): the HUD labels'
                    -- Font_Diegetic Bold (the POS label's face), colour and shadow from the timer
                    pcall(function()
                        local f = tx.Font
                        local fo = StaticFindObject("/Game/Griffin/UI/Library/Fonts/Font_Diegetic.Font_Diegetic")
                        if U.ok(fo) then f.FontObject = fo; f.TypefaceFontName = FName("Bold"); f.Size = 36 end
                        tw:SetFont(f)
                    end)
                    pcall(function() tw:SetColorAndOpacity(tx.ColorAndOpacity) end)
                    pcall(function() tw:SetShadowOffset(tx.ShadowOffset) end)
                    pcall(function() tw:SetShadowColorAndOpacity(tx.ShadowColorAndOpacity) end)
                    pcall(function() tw.Slot:SetVerticalAlignment(tx.Slot.VerticalAlignment) end)
                    e.chalTx = tw
                end)
                if not okC or not U.ok(e.chalTx) then
                    e.chalRetryMs = St.nowMs() + 2000
                    U.logOnce("hud.chal" .. tostring(e.pnum), TAG, "P%s challenge line not made", tostring(e.pnum))
                else
                    U.log(TAG, "P%s challenge line in its HUD (GALAXY RUN)", tostring(e.pnum))
                end
            end
            if U.ok(e.chalTx) and e.chalShown ~= text then
                e.chalShown = text
                pcall(function() e.chalTx:SetText(FText(text and ("   " .. text) or "")) end)
            end
        end
    end
end

-- 0.13.0: WBP_HUD_Afterburner caches its bar's MID in the variable M_AfterburnerBar (= the MID drawn on screen,
-- checked live 19:50) and every Tick writes "Slider" = UIBlueprintFunctionLibrary.GetAfterBurnerGuagePercentage(self)
-- through it: PLAYER 0's AfterburnerEnergy on every guest bar. The fix points M_AfterburnerBar at a throwaway MID (the
-- Tick writes P1's value there) and drives the drawn MID from the bar owner's car. Re-pointed whenever the widget
-- re-caches it (a Construct after a pause). P1's bar stays the game's. Tried and rejected: a post-hook on the getter
-- (a BP call to a static native passes no readable WorldContextObject; reading it is a crash risk) and swapping
-- Img_AfterburnerBar (the Tick never reads it, it uses the cached MID).
local AB = { e = {}, findMs = -1e12, world = -1, lastN = -1 }
local KMLIB = "/Script/Engine.Default__KismetMaterialLibrary"

function M.fastAfterburner()
    if St.phase ~= "RACING" or cfg.HudAfterburnerDrive == false then return end
    local lps = U.localPlayers(); if #lps < 2 then return end
    local now = St.nowMs()
    if AB.world ~= St.worldGen then AB.e = {}; AB.world = St.worldGen; AB.findMs = -1e12 end
    -- STUTTER FIX (2026-10-14 tick profiler: 18-20 ms spikes every 2 s here): the FindAllOf (a walk of the whole object
    -- array) runs every 2 s only while a guest has no driven bar yet, else every 15 s; the library CDO is cached.
    local guests = #lps - 1
    local have = 0; for _, x in pairs(AB.e) do if U.ok(x.w) then have = have + 1 end end
    if now - AB.findMs > ((have >= guests) and 15000 or 2000) then
        AB.findMs = now
        local p1 = U.key(lps[1].pc)
        local lib = U.findLoaded(KMLIB)
        local src
        if _G.SWGRCouch_abNotify == true then
            abSeen = seenAlive(abSeen); src = abSeen          -- reported by NotifyOnNewObject: no object-array walk
        else
            src = FindAllOf("WBP_HUD_Afterburner_C") or {}
        end
        for _, w in ipairs(src) do pcall(function()
            local wk = U.key(w)
            if AB.e[wk] or not (U.ok(w) and w:IsVisible()) then return end
            local pc = w:GetOwningPlayer()
            if not U.ok(pc) or U.key(pc) == p1 then return end
            local mid = w.M_AfterburnerBar
            if not (U.ok(mid) and U.ok(lib)) then return end
            local dummy = lib:CreateDynamicMaterialInstance(w, mid.Parent, FName("None"), 0)
            if not U.ok(dummy) then return end
            w.M_AfterburnerBar = dummy
            AB.e[wk] = { w = w, pc = pc, mid = mid, dummy = dummy }
        end) end
        local n = 0; for _ in pairs(AB.e) do n = n + 1 end
        if n ~= AB.lastN then AB.lastN = n
            U.log(TAG, "afterburner bar per player: %d guest bar(s) driven from their own car (V-HUD-AB1)", n) end
    end
    -- every object re-checked every frame: pcall does not catch a call on a freed UObject (19:32 crash)
    local slider = FName("Slider")
    for wk, x in pairs(AB.e) do
        if not (U.ok(x.w) and U.ok(x.pc) and U.ok(x.mid) and U.ok(x.dummy)) then AB.e[wk] = nil
        else pcall(function()
            if U.key(x.w.M_AfterburnerBar) ~= U.key(x.dummy) then        -- re-cached by a Construct
                local m = x.w.M_AfterburnerBar
                if U.ok(m) then x.mid = m end
                x.w.M_AfterburnerBar = x.dummy
            end
            local car = x.pc.Pawn
            if not (U.ok(car) and U.isVehicle(car)) then return end
            local v = math.max(0, math.min(1, tonumber(car.VehicleState.AfterburnerEnergy) or 0))
            x.mid:SetScalarParameterValue(slider, v)
        end) end
    end
end

-- 0.13.0 (Jules, live 2026-10-12, URGENT: "the bar fills in solo, it's only broken in split"): WBP_HUD_RamjetBar's
-- Tick fills its material from UIBlueprintFunctionLibrary.GetEngineOverheatingPercentage(self) /
-- GetRamJetReadyGaugePercentage(self), which read PLAYER 0's car: in a split race every bar showed P1's ramjet (live:
-- P2's bars carried P1's values). Every bar image gets a material instance of its own (the BP keeps writing its own
-- one, no longer drawn) driven here from the player's own car (P1 too: one verified path), with the game's mapping
-- recorded live in solo (2026-10-12 18:47): RamjetPercentage = RamjetHeat x EngineHeatWeight while the ramjet runs
-- (RamjetState 3 / 6), else 0; ChargingPercentage = 1 from Ready (state >= 1), else the recharge gauge;
-- [B]IsReady? = 1 from Ready; [B]Overheated = clamp(remap(fill, 0.8 w, 1.1 w)).
-- 0.15 REGRESSION FIX (Jules 2026-10-15, own pad, split: "no fill in the bottom-right bar, no redline alert", P1 and
-- P2; worked in 0.13.1):
--   * dac2e9b re-found the bars every 15 s once each player had a LIVE one. A bar the game rebuilds (pause -> HUD
--     re-placed, CSM hand-over) leaves the old widget alive (not collected yet), so the new, DRAWN bar stayed on the
--     game's own material for up to 15 s per rebuild - and the game's material fills from player 0 / its own unbound
--     "Vehicle State". Back to the 0.13.1 rule: re-found every 2 s (RJ_FIND_MS), plus at once when a driven bar is
--     no longer visible.
--   * the bar's Construct (work/ramjet/WBP_HUD_RamjetBar.disasm.txt @1426) runs IMG_Ramjet:SetBrushFromMaterial(
--     this.Material) again whenever the widget is re-constructed (re-added after a pause, hud.rebindRamjet's Construct
--     re-run): our material was then no longer the one drawn, forever (the instance was only made once per widget).
--     Now the drawn brush is checked every tick and our material put back (V-HUD-RJ3).
--   * the game's CheckShouldSetMinimumHeat: while ramjetting a fill under MinRamjetPercentage eases to it (lerp 0.5
--     per Tick), so the game's bar shows from the first frame of a burn even before the heat climbs; ours sat at 0.
local KML = "/Script/Engine.Default__KismetMaterialLibrary"
local RJ_FIND_MS = 2000
-- live2 stutter hunt (Jules 2026-10-15: "races must be flawless"): the FindAllOf walk costs up to ~30 ms in a 2P race
-- (a visible hitch) and ran every 1-2 s all race long. Re-finds are now event-driven: a NEW bar widget (the game's
-- HUD rebuild: race start, CSM hand-over, pause / resume) is reported by NotifyOnNewObject (hud.init) and re-found
-- RJ_NEW_DELAYS after it; a resume re-finds too; a driven bar collected or hidden re-finds at once (max 1/s). No
-- periodic walk once the notify is installed (cfg.HudRamjetPeriodicFind = true brings the 2 s walk back).
local RJ_HIDDEN_MIN_MS = 1000
local RJ_NEW_DELAYS = { 150, 1500 }
local RJ_BAR_CLASS = "/Game/Griffin/UI/Widgets/HUD/WBP_HUD_RamjetBar.WBP_HUD_RamjetBar_C"
function M._rjNewBar() local h = H(); h.rjNewMs = St.nowMs(); h.rjNewDone = 0 end   -- notify callback: no UObject work

-- pure: the material values of one bar from the car's ramjet values. prevFill = the bar's last fill (the game eases
-- toward its minimum from the value already on the material), minFill = the bar's MinRamjetPercentage (nil/0 = none).
-- -> { EngineHeatWeight, RamjetPercentage, ChargingPercentage, IsReady, Overheated }
function M.ramjetParams(st, heat, bypassOverheat, bypassHeat, wt, prevFill, minFill)
    st = tonumber(st) or 0
    heat = math.max(0, tonumber(heat) or 0)
    wt = tonumber(wt) or 0.74
    -- live 18:55 (explosion recorded): 3 on, 4 overheating (heat 1.0), 7 exploded; the fill must stay through 4-7
    -- box 1 = heat x w while on (3); box 2 = the overheat (4-6): w + BypassOverheatingPercentage x (1 - w)
    -- (live 19:06: 0.23 -> 0.83 -> 1.0 at the explosion, state 7 = full)
    local fill = 0
    if st == 3 then
        fill = math.min(1, heat) * wt
        local mn = tonumber(minFill) or 0
        if mn > 0 and fill < mn then                       -- the game's CheckShouldSetMinimumHeat
            local prev = math.max(0, math.min(1, tonumber(prevFill) or 0))
            fill = prev + (mn - prev) * 0.5
        end
    elseif st >= 4 and st <= 6 then
        -- live 2026-10-15 final (autopilot burn, RJDIAG vs GetEngineOverheatingPercentage): heat x w + bypass x (1 - w);
        -- state 6 cools down with the heat (0.94 -> 0.10), the old "w + bypass" froze our bar at 0.74 until state 0
        local by = math.max(0, math.min(1, tonumber(bypassOverheat) or 0))
        fill = math.min(1, heat) * wt + by * (1 - wt)
    elseif st == 7 then
        fill = 1
    end
    -- charging gauge refit live 2026-10-15 00:10 against the game's own GetRamJetReadyGaugePercentage (player 0, 26
    -- samples): ready = (1 - RamjetBypassHeat) x (1 - heat / 0.5) while recharging, 1 from Ready (state >= 1)
    local byp = math.max(0, math.min(1, tonumber(bypassHeat) or 0))
    local charge = (st >= 1) and 1 or math.max(0, math.min(1, (1 - byp) * (1 - heat / 0.5)))
    return { EngineHeatWeight = wt, RamjetPercentage = fill, ChargingPercentage = charge,
             IsReady = (st >= 1) and 1 or 0, Overheated = math.max(0, math.min(1, (fill - 0.8 * wt) / (0.3 * wt))) }
end

local function brushIs(w, mid)
    local ok, same = pcall(function() return U.key(w.IMG_Ramjet.Brush.ResourceObject) == U.key(mid) end)
    if ok then return same end
    return nil                                             -- unreadable: the caller re-brushes on a timer
end

function M.fastRamjet()
    if St.phase ~= "RACING" or cfg.HudRamjetDrive == false then return end
    local h = H()
    local lps = U.localPlayers()
    if #lps < 2 then return end                          -- solo: the game's own HUD is right
    local now = St.nowMs()
    local paused = false
    pcall(function() paused = U.csmPaused() == true end)
    if h.rjPaused and not paused then M._rjNewBar() end           -- a resume: the HUD may be re-placed
    h.rjPaused = paused
    local refind = h.rjWorld ~= St.worldGen or h.rjBars == nil
    if not _G.SWGRCouch_rjNotify or cfg.HudRamjetPeriodicFind == true then
        refind = refind or now - (h.rjFindMs or -1e12) > RJ_FIND_MS   -- no notify: the 0.13.1 periodic walk
    end
    if h.rjNewMs then                                             -- a new bar: re-find after each delay, once
        local d = RJ_NEW_DELAYS[(h.rjNewDone or 0) + 1]
        if d == nil then h.rjNewMs = nil
        elseif now - h.rjNewMs >= d then refind = true; h.rjNewDone = (h.rjNewDone or 0) + 1 end
    end
    if not refind then
        for _, bars in pairs(h.rjBars) do                -- a driven bar hidden / collected: its successor at once
            for _, w in ipairs(bars) do
                if not U.ok(w) then refind = true; break end
                local okV, vis = pcall(U.callMethod, w, "IsVisible")
                if okV and vis == false then refind = true; break end
            end
            if refind then break end
        end
        if refind and now - (h.rjFindMs or -1e12) < RJ_HIDDEN_MIN_MS then refind = false end   -- at most 1 walk per second
    end
    if refind then
        h.rjFinds = (h.rjFinds or 0) + 1                  -- live2: re-find count (read after a race; no log per walk)
        if h.rjWorld ~= St.worldGen then h.rjMid, h.rjFill, h.rjBrushMs = {}, {}, {} end
        h.rjFindMs, h.rjWorld, h.rjBars = now, St.worldGen, {}
        local src
        if _G.SWGRCouch_rjBarSeen == true then
            rjSeen["WBP_HUD_RamjetBar_C"] = seenAlive(rjSeen["WBP_HUD_RamjetBar_C"] or {})
            src = rjSeen["WBP_HUD_RamjetBar_C"]               -- reported by NotifyOnNewObject: no object-array walk
        else
            src = FindAllOf("WBP_HUD_RamjetBar_C") or {}
        end
        for _, w in ipairs(src) do
            pcall(function()
                if U.ok(w) and w:IsVisible() then
                    local k = U.key(w:GetOwningPlayer())
                    h.rjBars[k] = h.rjBars[k] or {}
                    table.insert(h.rjBars[k], w)
                end
            end)
        end
    end
    h.rjMid, h.rjFill, h.rjBrushMs = h.rjMid or {}, h.rjFill or {}, h.rjBrushMs or {}
    for _, e in ipairs(lps) do
        local pk = U.key(e.pc)
        local bars = h.rjBars[pk]                          -- every player in a split race, P1 too (same mapping)
        if bars then
            pcall(function()
                local car = e.pc.Pawn
                if not (U.ok(car) and U.isVehicle(car)) then return end
                local vs = car.VehicleState
                local heat = tonumber(vs.RamjetHeat) or 0
                local st = tonumber(vs.RamjetState) or 0
                -- couch-fix27 #108: each player's ramjet at the start (native: NotReady, heat 0.50, bypass 0.25 for every
                -- racer in 5473 RJDIAG samples of 8 speeder sessions = an EMPTY charging gauge at GO), once at GO and
                -- once 3 s in, so a full gauge at the start can be told from the data
                local t0 = St.race and tonumber(St.race.startedAtMs)
                if t0 then
                    h.rjStart = (h.rjStartGen == St.worldGen) and h.rjStart or {}
                    h.rjStartGen = St.worldGen
                    local done = h.rjStart[pk] or 0
                    local due = (done == 0) or (done == 1 and now - t0 >= 3000)
                    if due and done < 2 then
                        h.rjStart[pk] = done + 1
                        local av, byp = -1, -1
                        pcall(function() av = tonumber(vs.RamjetAvailability) or -1 end)
                        pcall(function() byp = tonumber(vs.RamjetBypassHeat) or -1 end)
                        U.log(TAG, "P%d ramjet at %s: state %d heat %.2f bypass %.2f availability %d (#108)", e.index,
                            done == 0 and "GO" or "GO+3s", st, heat, byp, av)
                    end
                end
                for _, w in ipairs(bars) do
                    if U.ok(w) then
                        local wk = U.key(w)
                        local mid = h.rjMid[wk]
                        if not U.ok(mid) then
                            local lib, parent = U.findLoaded(KML), nil
                            -- "afterburner" style: the ramjet material only SHOWS its fill while the global MPC is in
                            -- the ramjet colour state (one value for every HUD: blue on all, Jules 21:0x). The
                            -- afterburner bar shader ignores the MPC: a plain per-player fill under any colours.
                            if cfg.HudRamjetBarStyle == "afterburner" then
                                pcall(function() parent = U.findLoaded(
                                    "/Game/Griffin/UI/Library/Materials/HUD/M_UI_HUD_AfterburnerBar.M_UI_HUD_AfterburnerBar") end)
                            end
                            if not U.ok(parent) then pcall(function() parent = w.Material.Parent end) end
                            if U.ok(lib) and U.ok(parent) then
                                mid = lib:CreateDynamicMaterialInstance(w, parent, FName("None"), 0)
                                if U.ok(mid) then
                                    w.IMG_Ramjet:SetBrushFromMaterial(mid)
                                    h.rjMid[wk], h.rjBrushMs[wk] = mid, now
                                    U.log(TAG, "P%s ramjet bar: own material, driven from P%s's car (V-HUD-RJ2)",
                                        tostring(e.index), tostring(e.index))
                                end
                            end
                        else
                            local drawn = brushIs(w, mid)
                            if drawn == false or (drawn == nil and now - (h.rjBrushMs[wk] or -1e12) >= 500) then
                                -- re-constructed: the BP put its own material back on the image
                                pcall(function() w.IMG_Ramjet:SetBrushFromMaterial(mid) end)
                                h.rjBrushMs[wk] = now
                                U.logEvery("hud.rjrebrush" .. tostring(e.index), 5000, TAG,
                                    "P%s ramjet bar re-constructed by the game: own material put back (V-HUD-RJ3)",
                                    tostring(e.index))
                            end
                        end
                        -- DIAG (cfg.HudRamjetDiag, 2026-10-15, Jules: "ramjet still not working, no redline, no fill"):
                        -- once a second per player while anything ramjet-ish moves, the raw car state, what we draw and
                        -- the game's OWN gauge functions with THIS bar as context (do they follow the bar's owner or
                        -- player 0?) and the game's own material on the bar, into the UE4SS log (V-HUD-RJD)
                        -- ANSWERED (#55, overnight 2026-10-18 tester #2, 4P Jakku): the "P1ctx" columns (the library
                        -- gauges and the game's material) read the SAME value for all four players in every sample (AI
                        -- cars in an active burn included) and reset for everyone when P1's bot was switched: they follow
                        -- P1's car, never this bar's owner. The ready gauge also tops out at 1 - P1's bypass / 2 (0.90
                        -- at bypass 0.20; 0.80 / 0.85 / 0.87 / 0.89 at 0.39 / 0.29 / 0.24 / 0.21): a "stall" at 0.90 is
                        -- a FULL gauge, not a blocked charge. Per player = st / heat / byHeat / byOver / t / drawn.
                        if cfg.HudRamjetDiag ~= false then
                            h.rjDiagMs = h.rjDiagMs or {}
                            local moving = st ~= 1 and st ~= 2 or heat > 0
                            if moving and now - (h.rjDiagMs[wk] or -1e12) >= 1000 then
                                h.rjDiagMs[wk] = now
                                local lib = U.findLoaded("/Script/Griffin.Default__UIBlueprintFunctionLibrary")
                                local nOv, nRd, nBy, gRj, gCh, gOv, rt, bh, bo = -1, -1, -1, -1, -1, -1, -1, -1, -1
                                local wt0 = tonumber(w.EngineHeatWeight) or 0.74
                                pcall(function() nOv = lib:GetEngineOverheatingPercentage(w, wt0, 0.0) end)
                                pcall(function() nRd = lib:GetRamJetReadyGaugePercentage(w, wt0, 0.0) end)
                                pcall(function() nBy = lib:GetBypassOverheatingPercentage(w) end)
                                pcall(function() gRj = w.Material:K2_GetScalarParameterValue(FName("RamjetPercentage")) end)
                                pcall(function() gCh = w.Material:K2_GetScalarParameterValue(FName("ChargingPercentage")) end)
                                pcall(function() gOv = w.Material:K2_GetScalarParameterValue(FName("[B]Overheated")) end)
                                pcall(function() rt = vs.RamjettingTime end)
                                pcall(function() bh = vs.RamjetBypassHeat end)
                                pcall(function() bo = vs.BypassOverheatingPercentage end)
                                U.log(TAG, "RJDIAG P%d st=%d heat=%.2f byHeat=%.2f byOver=%.2f t=%.1f | drawn=%.2f | P1ctx native ovh=%.2f rdy=%.2f by=%.2f | P1ctx gameMID rj=%.2f chg=%.2f ovh=%.2f (V-HUD-RJD)",
                                    e.index, st, heat, tonumber(bh) or -1, tonumber(bo) or -1, tonumber(rt) or -1,
                                    tonumber(h.rjFill[wk]) or -1, tonumber(nOv) or -1, tonumber(nRd) or -1,
                                    tonumber(nBy) or -1, tonumber(gRj) or -1, tonumber(gCh) or -1, tonumber(gOv) or -1)
                            end
                        end
                        if U.ok(mid) then
                            local minFill = nil
                            pcall(function() minFill = tonumber(w.MinRamjetPercentage) end)
                            local p = M.ramjetParams(st, heat, vs.BypassOverheatingPercentage, vs.RamjetBypassHeat,
                                tonumber(w.EngineHeatWeight) or 0.74, h.rjFill[wk], minFill)
                            h.rjFill[wk] = p.RamjetPercentage
                            mid:SetScalarParameterValue(FName("EngineHeatWeight"), p.EngineHeatWeight)
                            mid:SetScalarParameterValue(FName("RamjetPercentage"), p.RamjetPercentage)
                            mid:SetScalarParameterValue(FName("ChargingPercentage"), p.ChargingPercentage)
                            mid:SetScalarParameterValue(FName("[B]IsReady?"), p.IsReady)
                            mid:SetScalarParameterValue(FName("[B]Overheated"), p.Overheated)
                            mid:SetScalarParameterValue(FName("Slider"), p.RamjetPercentage)   -- afterburner-style parent
                        end
                    end
                end
            end)
        end
    end
end

function M.fastTimer()
    if St.phase ~= "RACING" or cfg.HudGuestTimer == false then return end
    local h = H()
    if next(h.guests) == nil then return end
    local now = St.nowMs()
    if now < (h.timerNextMs or 0) then return end
    h.timerNextMs = now + 50
    local p1 = U.p1()
    -- #86: in a couch precision test every guest's clock carries his OWN gate bonus (precision.guestClock), written
    -- from the start, P1 still racing or not
    local okC, clockOf = pcall(function()
        local pr = U.mod("precision")
        local st = pr._state()
        if st and st.gen == St.worldGen and st.native == false then return pr.guestClock end
        return nil
    end)
    if not okC then clockOf = nil end
    if not clockOf and (not U.ok(p1) or stillRacingPC(p1) ~= false) then
        h.timerP1Out = nil
        return
    end
    local gs = U.gs()
    if not U.ok(gs) then return end
    local okT, el = pcall(function() return gs:GetServerWorldTimeSeconds() - gs.RaceStartTime end)
    if not okT or type(el) ~= "number" then return end
    if clockOf then
        for _, e in pairs(h.guests) do
            if e.pnum ~= 1 and U.ok(e.widget) and U.ok(e.pc) and stillRacingPC(e.pc) == true then
                local t = clockOf(e, el)
                if type(t) == "number" then
                    local tx = guestTimerText(e)
                    if tx and U.ok(e.timerOrig) and e.timerOrig:GetVisibility() ~= 1 then
                        pcall(function() e.timerOrig:SetVisibility(1) end)
                    end
                    local text = fmtRaceTime(t)
                    if tx and e.timerShown ~= text then
                        e.timerShown = text
                        pcall(function() tx:SetText(FText(text)) end)
                    end
                end
            end
        end
        return
    end
    if not h.timerP1Out then
        h.timerP1Out = true
        U.log(TAG, "P1 is out of the race at %s: the guests' race timers are written by the mod (task #35)",
            fmtRaceTime(el))
    end
    local text = fmtRaceTime(el)
    for _, e in pairs(h.guests) do
        if e.pnum ~= 1 and U.ok(e.widget) and U.ok(e.pc) and stillRacingPC(e.pc) == true then
            local tx = guestTimerText(e)
            if tx and U.ok(e.timerOrig) and e.timerOrig:GetVisibility() ~= 1 then
                pcall(function() e.timerOrig:SetVisibility(1) end)          -- Collapsed: the twin takes its place
            end
            if tx and e.timerShown ~= text then
                e.timerShown = text
                pcall(function() tx:SetText(FText(text)) end)
            end
        end
    end
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
    -- couch-livefix r2: a dormant local player (plugged, never joined) holds no view in this race (split.lua): no HUD
    local split = lazy("split")
    -- #29: a couch guest SITTING OUT this race (no grid entry, couchrules) holds no view either: P1 keeps his clone
    local sitOut = St.race.singleView == true and St.race.sitOut == true
    local rules = sitOut and lazy("couchrules") or nil
    local ctrlOf = {}
    if sitOut then for _, lp in ipairs(lps) do if U.ok(lp.pc) then ctrlOf[U.key(lp.pc)] = lp.ctrlId end end end
    local function noView(pc)
        if sitOut and M.sitsOut(rules, ctrlOf[U.key(pc)]) then return true end
        if not (split and split.noView) then return false end
        local ok, v = pcall(split.noView, pc)
        return ok and v == true
    end
    for _, lp in ipairs(lps) do if U.ok(lp.pc) and not noView(lp.pc) then present[U.key(lp.pc)] = true end end
    for k, e in pairs(h.guests) do
        if not present[k] or not U.ok(e.pc) or not U.ok(e.widget) then M.removeGuest(k) end
    end
    -- St.race.singleView: guests of a race the mod did not launch (join's "race_enter" guard), no guest views
    if M.guestPassOff(#lps, St.race.singleView, St.race.sitOut) then
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
    -- Race smoothness (2026-10-15): the two hot-reload sweeps walked FuseHudWidget twice (~30 ms each) in the first
    -- MAIN tick of EVERY race. A previous Lua state's HUDs can only exist in the world this Lua state was loaded into
    -- (a travel destroys the old world's PCs and their widgets): any later world skips them.
    if St.worldGen ~= initWorldGen then h.orphansSwept, h.p1OrphansSwept = true, true end
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
        if lp.index >= 2 and U.ok(lp.pc) and not noView(lp.pc) then
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

-- #29: the per-player HUD pass stops on one local player and on a single-view race the mod did not launch; a couch
-- sit-out (couchrules: singleView + sitOut) keeps it, the guest being view-less like a dormant player (P1's clone,
-- no guest HUD). Pure (tools/test_sitouthud.lua).
function M.guestPassOff(nLps, singleView, sitOut)
    if (tonumber(nLps) or 0) < 2 then return true end
    return singleView == true and sitOut ~= true
end
-- a guest's ctrlId sits this race out (couchrules.isSittingOut)
function M.sitsOut(rules, ctrlId)
    if type(rules) ~= "table" or type(rules.isSittingOut) ~= "function" or ctrlId == nil then return false end
    local ok, v = pcall(rules.isSittingOut, ctrlId)
    return ok and v == true
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
                        local okP, panel = pcall(U.getField, x, "NotificationSubPanel")
                        if okT and type(tn) == "string" and okP and U.ok(panel) then
                            conts[#conts + 1] = { w = x, name = tn, panel = panel, tree = n }
                        end
                    end
                end
            end
            mem.conts = conts
            if #conts == 0 then
                U.logOnce("hud.noconts." .. U.pathOf(U.ok(a.widget) and a.widget:GetClass() or nil), TAG, "no notification container found in %s "
                    .. "(message routing has nothing to route there)", U.pathOf(U.ok(a.widget) and a.widget:GetClass() or nil))
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
    initWorldGen = St.worldGen                         -- the hot-reload sweeps run in this world only (M.tick)
    -- live2: the ramjet bars' re-find trigger (see RJ_NEW_DELAYS); once per game session (hot reloads re-run init),
    -- through U.mod so a reloaded hud.lua gets the calls
    if not _G.SWGRCouch_rjNotify and type(NotifyOnNewObject) == "function" then
        -- the bar's notify also records the new widget (rebindRamjet reads that list instead of FindAllOf)
        local okN = pcall(NotifyOnNewObject, RJ_BAR_CLASS, function(obj)
            pcall(function() U.mod("hud")._rjNewBar() end)
            pcall(function() U.mod("hud")._rjSeen("WBP_HUD_RamjetBar_C", obj) end)
        end)
        _G.SWGRCouch_rjBarSeen = okN
        _G.SWGRCouch_rjNotify = okN
        U.log(TAG, "ramjet bars: re-find on NotifyOnNewObject %s (no periodic FindAllOf)", okN and "installed" or "FAILED")
    end
    -- race smoothness 2026-10-15: the overheat warning / ramjet message report themselves too (rebindRamjet). Only
    -- when this session's bar notify records its widget (a bar notify from an older hud.lua does not)
    if _G.SWGRCouch_rjBarSeen and not _G.SWGRCouch_rjSeenNotify and type(NotifyOnNewObject) == "function" then
        local okAll = true
        for cn, path in pairs(RAMJET_PATHS) do
            if cn ~= "WBP_HUD_RamjetBar_C" then
                okAll = pcall(NotifyOnNewObject, path, function(obj)
                    pcall(function() U.mod("hud")._rjSeen(cn, obj) end)
                end) and okAll
            end
        end
        _G.SWGRCouch_rjSeenNotify = okAll
        U.log(TAG, "ramjet widgets: guest re-bind from NotifyOnNewObject %s (no FindAllOf at the race start)",
            okAll and "installed" or "FAILED")
    end
    if not _G.SWGRCouch_abNotify and type(NotifyOnNewObject) == "function" then
        local okA = pcall(NotifyOnNewObject, AB_PATH, function(obj)
            pcall(function() U.mod("hud")._abSeen(obj) end)
        end)
        _G.SWGRCouch_abNotify = okA
        U.log(TAG, "afterburner bars: re-find from NotifyOnNewObject %s (no FindAllOf every 15 s)",
            okA and "installed" or "FAILED")
    end
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
    St.on("leaving", TAG, function() M.clearAll(); M._rjSeenClear() end)
    St.on("phase", TAG, function(new)
        if new == "FRONTEND" or new == "OTHER" or new == "LOADING" then M.clearAll() end
    end)
    U.log(TAG, "init: P1HudMode=%s, visibility=%s, lap patch=%s", tostring(cfg.P1HudMode),
        tostring(cfg.HudVisibilityMode), tostring(cfg.LapPatch))
end

return M
