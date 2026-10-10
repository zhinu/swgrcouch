-- setup.lua (G3 Front-end UI) - the RACE SETUP flow inside the SPLIT SCREEN lobby page:
--   1 CLASS -> 2 PLANET (planet art + the planet's arrival video) -> 3 TRACK (track art, laps, flags) [+ CONDITIONS]
--   -> 4 MODE (+ grid size) -> 5 VEHICLES (one column per local player, each picks model + build with their own pad)
--   -> START RACE (launch.start) or SAVE (back to the lobby with the race chosen).
-- Design: notes/research/race-setup.md. The old dev panel (builder.lua) stays reachable from the lobby (ADVANCED row).
--
-- Input model (2026-10-07 runs): P1's pad never reaches P1's PlayerController in the menu (CommonUI routes it), so P1
-- drives CommonUI focus on WBP_Common_Btn rows (pad A / mouse clicks are seen by ui.pollClicks, ClickMode "poll");
-- left/right on a value row is a "focus trap": the row is [<][value][>], CommonUI moves focus to an arrow, the FAST
-- poll steps the value and puts the focus back on the middle button. The keyboard comes through lobby.onKey (UE4SS
-- keybinds). Guests (ControllerId 1..3) DO reach their own PlayerController: their d-pad / stick / A are polled with
-- IsInputKeyDown (as join.lua does), never B (join.lua: B = leave).
-- Everything is poll-based: no Blueprint hook is needed.
-- 0.7.2 (notes/research/vehicle-preview.md): each VEHICLES card shows a live 3D render of the pick (vpreview.lua
-- "photo bays", built only while this step shows, released when it is left / the setup closes / the menu is
-- replaced) with the model's manufacturer badge; the 2D card (class render / livery owner's portrait) stays the
-- fallback whenever a render is not available. cfg.SetupPreview3D = false restores the 0.7.1 cards.
-- 0.9.0 (user 2026-10-07: "the planet selection should be similar to the one in campaign, with planets moving and then
-- the circuit for each one"): PLANET and TRACK show cmap.lua's campaign views - the campaign's own planet arc
-- (WBP_PlanetSelector) with a row of planet chips as the control, then a single-planet run map (circuit rows, variant
-- nodes, detail card). The lists below stay: S.items drives both presentations (S.view "cmap" | "list"), and any cmap
-- failure falls back to the list for that step (cfg.SetupCampaignMap = false: the 0.8.0 lists only).
-- 0.10.0 RACERS (notes/design/vehicle-step-v2.md §5.9; user 2026-10-09: "A chracter should be chosen, a kart then. and
-- then we should be able to map out all the benefits and perks added to the kart"): with cfg.SetupPlayerFlow "cards"
-- step 5 is RACERS, one card per local player, each on its own PILOT -> VEHICLE -> PERKS -> READY. racers.lua drives it
-- (state machines, every input source, view models) and cards.lua draws it; this file builds the card row and the
-- host of P1's input sink, hands the step to racers (enter / leave / poll / keys / players / page shown), gates START
-- (READY, and RC-1: un-joined pads before the page closes), makes the race choice from the picks (the class's launch
-- base build, c.setup.flow = "cards", pilots and loadouts per ControllerId) and persists them (LastRaceRacers).
-- "classic", or a page whose cards cannot be built, keeps the VEHICLES columns below unchanged.
--
-- Verified signatures (runtime JMAP 2026-10-07, work/runtime/idx via /tmp query; UMG/CommonUI as in ui.lua):
--   UImage:SetBrushFromTexture(Texture2D, Bool bMatchSize), SetBrushFromMaterial(MaterialInterface),
--     SetColorAndOpacity(Struct LinearColor); USizeBox:SetWidthOverride/SetHeightOverride/SetMaxDesiredHeight(Float);
--   UScrollBox:SetScrollWhenFocusChanges(Enum EScrollWhenFocusChanges: NoScroll 0, InstantScroll 1, AnimatedScroll 2),
--     ScrollToStart(); UHorizontalBox:AddChildToHorizontalBox(Widget) -> HorizontalBoxSlot (SetSize(FSlateChildSize
--     {Value, SizeRule}), SetPadding, SetHorizontalAlignment, SetVerticalAlignment); UOverlay:AddChildToOverlay;
--   UBinkMediaPlayer: OpenUrl(Str) -> Bool, Play() -> Bool, Stop(), CloseUrl(), SetLooping(Bool) -> Bool,
--     IsLooping() -> Bool, GetUrl() -> Str, SetVolume(Float); /Game/Movies/UI_BinkMediaPlayer (+ _Tex,
--     M_UI_MediaPlayer_Video_Mat) is the player the main menu itself uses (runtime-decoding.md §4.3);
--   UGfnEventList:GetQuickplayTracksForVehicleAndPlanet(Object vehicleType, Object planet) -> Array<UTrackDef>;
--   UTrackDef: PlayerFacingName, bIsPointToPoint, bIsReverse, bHasMines, DefaultLapCount @+0xec,
--     TrackConditionDataLayers[] {Tag {TagName}} @+0x188; UPlanetDef: PlayerFacingName, FlavourText;
--   GameplayStatics:GetRealTimeSeconds(WorldContext) -> Float (fallback real clock; St.nowMs is real since 0.4.0);
--   CommonInputSubsystem:GetCurrentInputType() -> Enum (MouseAndKeyboard 0, Gamepad 1, Touch 2) through
--     SubsystemBlueprintLibrary:GetLocalPlayerSubSystemFromPlayerController(PC, Class).

local C        = require("consts")
local cfg      = require("config")
local settings = require("settings")
local St       = require("state")
local U        = require("util")
local V        = require("vehicles")

local M = {}
local TAG = "setup"

-- 0.7.2: live 3D renders of the VEHICLES picks (vpreview.lua, notes/research/vehicle-preview.md). Optional: a load
-- error leaves the 2D cards (class render / livery owner's portrait) exactly as before.
local VP = nil
do
    local ok, m = pcall(require, "vpreview")
    if ok and type(m) == "table" then VP = m
    else U.err(TAG, "vpreview.lua failed to load (%s): the vehicle cards stay 2D", tostring(m)) end
end

-- 0.9.0: campaign-style PLANET / TRACK views (cmap.lua, notes/research/campaign-map/). Optional like vpreview.
local CM = nil
do
    local ok, m = pcall(require, "cmap")
    if ok and type(m) == "table" then CM = m
    else U.err(TAG, "cmap.lua failed to load (%s): PLANET / TRACK use the lists", tostring(m)) end
end

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

---------------------------------------------------------------------------------------------------- static data
local PLA = "/Game/Griffin/Gameplay/Config/Planets/"
local GMV = "/Game/Griffin/Gameplay/Campaign/GameModes/"
local TEXC = "/Game/Griffin/UI/Library/Textures/Content/"
local function tp(sub, n) return TEXC .. sub .. "/" .. n .. "." .. n end

-- Quick-race planets (DA_Events.QuickRacePlanets order) + Tatooine (pods; cfg.SetupTatooine). tex = planet texture
-- code, art = Arcade texture code, movie = MEDIA_PlanetEstablish_* (PLA_Beagle points to the MAS movie; BGL exists).
local PLANETS = {
    { key = "Mastiff",   name = "JAKKU",       tex = "Mas", art = "Mas", movie = "MAS" },
    { key = "Dalmatian", name = "LANTAANA",    tex = "Dal", art = "Dal", movie = "DAL" },
    { key = "Husky",     name = "SENTINEL I",  tex = "Hus", art = "Hus", movie = "HUS" },
    { key = "Corgi",     name = "ANDO PRIME",  tex = "Cor", art = "Cor", movie = "COR" },
    { key = "Spaniel",   name = "CRAIT",       tex = "Spa", art = "Spa", movie = "SPA" },
    { key = "Whippet",   name = "DERVEN ACOS", tex = "Whp", art = "Whp", movie = "WHI" },
    { key = "Beagle",    name = "TATOOINE",    tex = "Bea", art = "Bgl", movie = "BGL", optional = true },
}
for _, p in ipairs(PLANETS) do
    p.path = PLA .. "PLA_" .. p.key .. ".PLA_" .. p.key
    p.select = tp("Planets", "T_UI_Planet_" .. p.tex .. "_Select")
    p.hires = tp("Planets", "T_UI_Planet_" .. p.tex)
    p.url = "./Movies/MEDIA_PlanetEstablish_" .. p.movie .. ".bk2"
end

-- Arcade per planet x class backgrounds (T_UI_Arcade_<Pl>_<Class>_Bg); Husky has no Car image (the Arcade uses
-- Corgi's), Tatooine only Plane.
local function arcadeBg(planet, cls)
    local pl, k = planet.art, cls.art
    if pl == "Hus" and k == "Car" then pl = "Cor" end
    if pl == "Bgl" and k ~= "Plane" then return planet.select end
    return tp("Arcade", "T_UI_Arcade_" .. pl .. "_" .. k .. "_Bg")
end

-- Track art: the Arcade event tile of the same TrackDef when one exists (summarize.py arcade, 48 tracks).
local TRACK_TILE = {
    TRAK_BGL_PLANE_FWD = "Bgl_Plane", TRAK_COR_Loop_A_FWD = "Brain_Freeze", TRAK_COR_Loop_A_SHORT_02 = "Cor_Skimmer",
    TRAK_COR_Loop_B_FWD = "Night_Drive_I", TRAK_COR_P2P_SHORT_05 = "Skimmer_Test_Drive_I",
    TRAK_DAL_LOOP_A_SHORT_01 = "Bike_Test_Drive_I", TRAK_DAL_LOOP_A_SHORT_06 = "Cutting_It_Fine",
    TRAK_DAL_LOOP_B_FWD = "Lethal_Lava", TRAK_DAL_LOOP_B_REV = "Dlx_Car_Test_Drive", TRAK_DAL_P2P_FWD = "Dal_Skimmer",
    TRAK_DAL_P2P_SHORT_05 = "Dal_Quick", TRAK_DAL_PLANE_FWD_Pday = "Podracing_VI", TRAK_HSK_LOOP_A_FWD_MINES = "Hus_Car",
    TRAK_HSK_LOOP_A_REV = "Shield_Smart", TRAK_HSK_LOOP_B_REV = "Skimmer_Test_Drive_II",
    TRAK_HSK_LOOP_B_SHORT_02 = "Hus_I_Quick", TRAK_HSK_P2P_FWD = "Absolute_Hangtime",
    TRAK_HSK_P2P_SPEC_SHORT_01 = "Acid_Accumulation", TRAK_INSTA_COR_PLANE_FWD = "Cor_Plane",
    TRAK_INSTA_COR_PLANE_REV = "Podracing_V", TRAK_INSTA_DAL_PLANE_REV = "Dal_Plane", TRAK_MAS_LOOP_A_REV = "Mas_Car",
    TRAK_MAS_LOOP_A_SHORT_02 = "Car_Test_Drive", TRAK_MAS_LOOP_B_SHORT_01 = "Cooling_Surge",
    TRAK_MAS_PLANE_FWD_Pday = "Mas_Plane", TRAK_SHK_COR_P2P_REV = "Bike_Test_Drive_II",
    TRAK_SHK_DAL_LOOP_A_FWD = "Dal_Car", TRAK_SHK_MAS_P2P_RollingStart_FWD_01 = "Dlx_Skimmer_Test_Drive",
    TRAK_SHK_MAS_P2P_RollingStart_FWD_02 = "Mas_Bike", TRAK_SPA_Loop_A_FWD = "Spa_Bike",
    TRAK_SPA_Loop_A_SHORT_01 = "Spa_Quick", TRAK_SPA_Loop_B_FWD = "Night_Drive_II",
    TRAK_SPA_Loop_B_FWD_MINES = "Salt_Mines", TRAK_SPA_Loop_B_P2P = "Skimmer_Test_Drive_III",
    TRAK_SPA_PLANE_FWD_PDay = "Spa_Plane", TRAK_WHP_LOOP_A_FWD_ARC = "Whp_Car", TRAK_WHP_PLANE_FWD = "Whp_Plane",
}

-- TrackDef.ExcludedGameModeVariants (decoded-tracks.tsv): only these 7 tracks exclude a quick-race mode.
local EXCLUDED = {
    TRAK_SHK_DAL_LOOP_A_SHORT_01 = "GMV_Eliminator", TRAK_SHK_DAL_LOOP_A_SHORT_06 = "GMV_Eliminator",
    TRAK_SHK_HSK_LOOP_B_SHORT_02 = "GMV_Eliminator", TRAK_SHK_HSK_P2P_SHORT_01 = "GMV_Eliminator",
    TRAK_MAS_LOOP_B_SHORT_01_MINES = "GMV_Eliminator", TRAK_SHK_SPA_Loop_B_SHORT_02 = "GMV_Eliminator",
    TRAK_SPA_Loop_B_SHORT_02_MINES = "GMV_Eliminator",
}

-- Quick-race modes (DA_Events.QuickRaceGameModes). single: every racer drives the chosen class (launch forces the AI
-- to it); grid "max": launch rewrites the grid to the class limit (cfg.SetupGridMode); "native": the asset's grid.
M.MODES = {
    { key = "race", asset = "GMV_Race", label = "RACE", single = true, grid = "max",
      desc = "SINGLE CLASS RACE, FULL GRID OF THE CHOSEN CLASS" },
    { key = "fullgrid", asset = "GMV_FullGridRace", label = "FULL GRID RACE", single = true, grid = "native",
      desc = "THE GAME'S OWN FULL-GRID RACE (GRID SIZE SET BY THE GAME)" },
    { key = "mixed", asset = "GMV_MultiVehicleRace", label = "MIXED CLASS RACE", single = false, grid = "native",
      speedersOnly = true, desc = "4 LANDSPEEDERS + 4 SPEEDER BIKES + 4 SKIM SPEEDERS" },
    { key = "eliminator", asset = "GMV_Eliminator", label = "ELIMINATOR", single = false, grid = "native",
      speedersOnly = true, desc = "TIMED ELIMINATION, MIXED CLASSES (12 RACERS)" },
}
for _, m in ipairs(M.MODES) do m.path = GMV .. m.asset .. "." .. m.asset end

function M.modeByPath(path)
    for _, m in ipairs(M.MODES) do if m.path == path then return m end end
    return nil
end

function M.modeByKey(key)
    for _, m in ipairs(M.MODES) do if m.key == key then return m end end
    return nil
end

---------------------------------------------------------------------------------------------------- helpers
-- Real milliseconds. St.nowMs() is real time once state.lua's clock has a GetAccurateRealTime sample (integration
-- 2026-10-07); before that (or if that call fails) GameplayStatics:GetRealTimeSeconds of the current world, os.time()
-- as the last fallback.
function M.realMs()
    local okI, info = pcall(St.clockInfo)
    if okI and type(info) == "table" and info.source ~= "os.clock" then return St.nowMs() end
    local ok, v = pcall(function() return U.GS():GetRealTimeSeconds(U.world()) end)
    if ok and type(v) == "number" then return v * 1000 end
    return os.time() * 1000
end

local function status(text)
    U.log(TAG, "%s", text)
    St.emit("status", text)
end

local function ui() return U.mod("ui") end
local function racers() return U.mod("racers") end         -- 0.10.0 RACERS step (lazy: G3 like this file)

local function trackKey(track)
    local ok, n = pcall(function() return track:GetFName():ToString() end)
    return ok and n or ""
end

-- Short planet entry for a UPlanetDef object (by FName "PLA_<Key>").
function M.planetFor(obj)
    if not U.ok(obj) then return nil end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    if not ok then return nil end
    for _, p in ipairs(PLANETS) do if "PLA_" .. p.key == n then return p end end
    return nil
end

M.PLANETS = PLANETS
M.arcadeBg = arcadeBg
M.trackKey = trackKey

---------------------------------------------------------------------------------------------------- state
-- W: widgets of the current lobby page instance (rebuilt with the page; forget() drops it). 0.10.0: cardBox / cardRow /
--    sinkHost (RACERS cards), cardsOk (racers.build succeeded), cardsBroken (this page keeps the classic columns).
-- S: the flow. players[pnum] = {pnum, ctrlId, pc, preset (index), build (index), ready, row (1 vehicle, 2 build),
--    nav = {edges/repeat state}} - P1 is pnum 1 (CommonUI focus), guests come from join.joinedList(). These are the
--    classic columns; in the cards flow racers.lua keeps the players (St.racers). cards: the shown step 5 is RACERS;
--    startDormant: the un-joined pads the START window was armed for (RC-1).
local W = nil
local cmapCtx            -- helpers handed to cmap.build (assigned below the data section)
local S = { active = false, step = nil, cls = nil, planets = {}, planet = nil, tracks = {}, track = nil, conds = {},
            cond = "", mode = nil, grid = 12, players = {}, items = {}, page = 0, hl = nil, lastFocus = nil,
            keepUntil = 0, keepNext = 0, startConfirmUntil = 0, kbStepAt = 0, builds = {}, presets = {},
            pickMemory = {}, cards = false, startDormant = nil }

local VBOX  = { "/Script/Griffin.FuseVerticalBox", "/Script/UMG.VerticalBox" }
local HBOX  = { "/Script/Griffin.FuseHorizontalBox", "/Script/UMG.HorizontalBox" }
local SIZE  = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" }
local OVER  = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local IMAGE = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local SCROLL = { "/Script/UMG.ScrollBox" }
local SCALE = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" }

-- New native UMG widget with the page's WidgetTree as outer (what UWidgetTree::ConstructWidget does for non-user
-- widgets). VERIFY(V-SET-01): widgets made with StaticConstructObject and added to the live page render and lay out.
local function newW(paths)
    for _, p in ipairs(paths) do
        local cls = U.class(p)
        if U.ok(cls) then
            local w = StaticConstructObject(cls, W.tree)
            if U.ok(w) then return w end
        end
    end
    error("cannot construct " .. tostring(paths[1]))
end

local function pad(l, t, r, b) return { Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 } end

local function vAdd(box, w, p, hAlign)
    local s = box:AddChildToVerticalBox(w)                 -- -> UVerticalBoxSlot
    if U.ok(s) then
        if p then s:SetPadding(p) end
        s:SetHorizontalAlignment(hAlign or C.E.HAlign.Fill)
    end
    return s
end

-- fill: nil = automatic size, number = fill weight (FSlateChildSize {Value, SizeRule Fill=1}).
local function hAdd(box, w, fill, p)
    local s = box:AddChildToHorizontalBox(w)               -- -> UHorizontalBoxSlot
    if U.ok(s) then
        if fill then s:SetSize({ Value = fill, SizeRule = 1 }) end
        if p then s:SetPadding(p) end
        s:SetVerticalAlignment(1)                          -- EVerticalAlignment VAlign_Top
    end
    return s
end

-- Containers: SelfHitTestInvisible (children stay clickable); collapsed when off.
local function show(w, on)
    if not U.ok(w) then return end
    pcall(function() w:SetVisibility(on and C.E.Vis.SelfHitTestInvisible or C.E.Vis.Collapsed) end)
end

local function showRow(w, on)                               -- our buttons / labels (ui.setShown knows labels)
    if U.ok(w) then pcall(function() ui().setShown(w, on) end) end
end

local textCache = {}
local function setText(w, text, isButton)
    if not U.ok(w) then return end
    text = tostring(text or "")
    local k = U.key(w)
    if textCache[k] == text then return end
    local ok = pcall(function()
        if isButton then ui().setButtonText(w, text) else ui().setLabelText(w, text) end
    end)
    if ok then textCache[k] = text end
end

local function label(text)
    local w = ui().label(W.pc, text or "")
    if w then ui().styleRow(w) end
    return w
end

local function button(id, text, fn)
    local w = ui().button(W.pc, "setup:" .. id, text or "", fn)
    if w then ui().styleRow(w) end
    W.focusables[#W.focusables + 1] = w
    return w
end

local INK_DARK = { R = 0.006995, G = 0.006995, B = 0.006995, A = 1 }   -- the BPs' near-black (ui.lua)

local function slateColor(c) return { SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = c.A or 1 }, ColorUseRule = 0 } end

local function tint(lbl, colour)
    pcall(function()
        local t = lbl.Txt_Label
        if U.ok(t) and colour then t:SetColorAndOpacity(slateColor(colour)) end
    end)
end

local imgCache = {}
local function setImage(img, texPath)
    if not U.ok(img) then return false end
    local k = U.key(img)
    if imgCache[k] == texPath then return true end
    local t = V.texture(texPath)
    if not t then return false end
    local ok = pcall(function() img:SetBrushFromTexture(t, false) end)   -- (Texture2D, Bool bMatchSize)
    if ok then imgCache[k] = texPath end
    return ok
end

local function sizeBox(w, h)
    local sb = newW(SIZE)
    if w then sb:SetWidthOverride(w) end
    if h then sb:SetHeightOverride(h) end
    return sb
end

-- [<][value][>] row. onStep(dir) changes the value; the middle button's A steps forward too.
local function makeCycler(id, onStep)
    local box = newW(HBOX)
    local cy = { id = id, box = box, onStep = onStep }
    cy.l = button(id .. ":l", "<", function() M.cyclerStep(id, -1, "click") end)
    cy.m = button(id .. ":m", "", function() M.cyclerStep(id, 1, "click") end)
    cy.r = button(id .. ":r", ">", function() M.cyclerStep(id, 1, "click") end)
    hAdd(box, cy.l, nil, pad(0, 0, 4, 0))
    hAdd(box, cy.m, 1)
    hAdd(box, cy.r, nil, pad(4, 0, 0, 0))
    pcall(function()                                        -- EUINavigation Left 0, Right 1
        cy.m:SetNavigationRuleExplicit(0, cy.l); cy.m:SetNavigationRuleExplicit(1, cy.r)
        cy.l:SetNavigationRuleExplicit(1, cy.m); cy.r:SetNavigationRuleExplicit(0, cy.m)
    end)
    W.cyclers[id] = cy
    return cy
end

-- Vehicle card of a column (0.7.2): cardBox (SizeBox, 16:9 while 3D renders are on) > card (Overlay) >
--   render  (Image, fill)          the 3D render of the pick (vpreview), hidden until its bay has one;
--   imgBox > img (centred)         the 2D art at its own aspect (class render / livery owner's portrait), the fallback;
--   badgeBox > badge (top left)    the model's manufacturer badge (vehicles.badge, cfg.SetupCardBadges);
--   insetBox > inset (bottom right) the livery owner's portrait next to a render (pilot-livery presets).
-- Without an overlay the card is imgBox > img as before 0.7.2 (2D only, logged once). Returns the card's root.
local function makeCard(col)
    local h = opt("SetupCardH", 200)
    col.imgBox = sizeBox(opt("SetupCardW", 360), h)
    col.img = newW(IMAGE)
    col.imgBox:AddChild(col.img)
    local ok, err = pcall(function()
        local box, over = sizeBox(math.floor(h * 16 / 9 + 0.5), h), newW(OVER)
        box:AddChild(over)
        local function put(w, hAlign, vAlign, p)               -- EHorizontal/EVerticalAlignment: Fill 0, Left/Top 1,
            local s = over:AddChildToOverlay(w)                 -- Center 2, Right/Bottom 3
            if U.ok(s) then
                s:SetHorizontalAlignment(hAlign)
                s:SetVerticalAlignment(vAlign)
                if p then s:SetPadding(p) end
            end
        end
        local render = newW(IMAGE)
        put(render, 0, 0)
        put(col.imgBox, 2, 2)
        local bs = opt("SetupCardBadgeSize", 44)
        local badgeBox, badge = sizeBox(bs, bs), newW(IMAGE)
        badgeBox:AddChild(badge)
        put(badgeBox, 1, 1, pad(6, 6, 0, 0))
        local ih = opt("SetupCardInsetH", 72)
        local insetBox, inset = sizeBox(math.floor(ih * 1480 / 1800 + 0.5), ih), newW(IMAGE)   -- portraits 1480x1800
        insetBox:AddChild(inset)
        put(insetBox, 3, 3, pad(0, 0, 6, 6))
        col.cardBox, col.render, col.badgeBox, col.badge, col.insetBox, col.inset =
            box, render, badgeBox, badge, insetBox, inset
    end)
    if not ok then
        U.logOnce("setup.card!", TAG, "vehicle card overlay unavailable (%s): 2D art only, no badge (V-VP-08)", tostring(err))
        return col.imgBox                                       -- AddChild re-parents it out of a half-built overlay
    end
    show(col.render, false)
    show(col.badgeBox, false)
    show(col.insetBox, false)
    return col.cardBox
end

-- The column's 3D render off the image (the MID loses its last UPROPERTY reference).
local function resetRender(col)
    if col.vpBrush then
        pcall(function() col.render:SetBrushResourceObject(nil) end)
        col.vpBrush = nil
    end
    if U.ok(col.render) then show(col.render, false) end
end

-- 3D previews off: render images reset (when the page lives on), then the bay actors destroyed and, with the
-- images reset, their render targets released (vpreview). VERIFY(V-VP-07)
local function releasePreviews(why, pageAlive)
    local reset = W ~= nil and pageAlive ~= false
    if reset then
        for _, col in pairs(W.cols or {}) do resetRender(col) end
    end
    if VP then U.try(TAG, VP.releaseAll, why, reset) end
end

-- One player column of the VEHICLES step. Column 1 is P1's (cyclers); the others are labels driven by guest pads.
local function makeColumn(i)
    local col = { box = newW(VBOX) }
    col.title = label("P" .. i)
    vAdd(col.box, col.title, pad(0, 0, 0, 4))
    vAdd(col.box, makeCard(col), pad(0, 0, 0, 6), C.E.HAlign.Center)
    col.name = label("")
    vAdd(col.box, col.name, pad(0, 2, 0, 2))
    col.owner = label("")
    vAdd(col.box, col.owner, pad(0, 0, 0, 2))
    if i == 1 then
        col.vehCy = makeCycler("veh", function(dir) M.stepPlayer(1, "preset", dir) end)
        vAdd(col.box, col.vehCy.box, pad(0, 4, 0, 4))
        col.buildCy = makeCycler("build", function(dir) M.stepPlayer(1, "build", dir) end)
        vAdd(col.box, col.buildCy.box, pad(0, 4, 0, 4))
    end
    col.build = label("")
    vAdd(col.box, col.build, pad(0, 2, 0, 2))
    col.state = label("")
    vAdd(col.box, col.state, pad(0, 2, 0, 2))
    W.cols[i] = col
    return col
end

---------------------------------------------------------------------------------------------------- RACERS cards
-- 0.10.0 (cfg.SetupPlayerFlow "cards"). The page gets the card row right after the classic columns, P1's sink host at
-- the footer's right end and, once the page is complete, racers.build (cards.init + the sink). A failure at any of the
-- three keeps the classic columns for this page (W.cardsBroken, logged once per page). VERIFY(V-RC-01)
local function cardsWanted() return opt("SetupPlayerFlow", "cards") == "cards" end

-- The cards serve this page (racers.build succeeded) / the shown step 5 is RACERS.
local function cardsReady() return W ~= nil and W.cardsOk == true and not W.cardsBroken end
local function cardsStep() return S.active == true and W ~= nil and S.step == "vehicles" and S.cards == true end

local function cardsStage(what, fn)
    if W.cardsBroken or not cardsWanted() then return end
    local ok, err = pcall(fn)
    if ok then return end
    W.cardsBroken, W.cardsOk = true, false
    U.err(TAG, "RACERS cards unavailable (%s: %s): this page keeps the classic VEHICLES columns (V-RC-01)", what,
        tostring(err))
end

-- W.cardBox (CardRowW x CardH) > ScaleBox (ScaleToFit, DownOnly: an overflow guard only, the page cannot shrink the
-- row, RC-15) > W.cardRow (the cards, centred: cards.init puts four collapsed card boxes into it).
local function buildCardRow()
    local box = sizeBox(opt("CardRowW", 3500), opt("CardH", 1320))
    local sc = newW(SCALE)
    pcall(function() sc:SetStretch(2); sc:SetStretchDirection(1) end)   -- EStretch ScaleToFit, EStretchDir. DownOnly
    box:AddChild(sc)
    local row = newW(HBOX)
    local s = sc:AddChild(row)                              -- -> ScaleBoxSlot
    if U.ok(s) then pcall(function() s:SetHorizontalAlignment(C.E.HAlign.Center); s:SetVerticalAlignment(1) end) end
    vAdd(W.panel, box, pad(0, 0, 0, 8), C.E.HAlign.Center)
    show(box, false)
    W.cardBox, W.cardRow = box, row
end

-- P1's input sink (racers.lua, spec §5.7.3): five invisible focusable buttons on a canvas in this 96 x 96 su box,
-- collapsed outside step 5.
local function buildSinkHost()
    local host = sizeBox(96, 96)
    hAdd(W.footer, host, nil, pad(8, 0, 0, 0))
    show(host, false)
    W.sinkHost = host
end

local function buildRacers()
    local r = racers().build({ tree = W.tree, pc = W.pc, newW = newW, row = W.cardRow, sinkHost = W.sinkHost,
                               realMs = M.realMs, footer = { W.back, W.save, W.start } })
    if r ~= true then error("racers.build returned " .. tostring(r)) end
    W.cardsOk = true
end

-- racers.leave when the cards serve this page ("step <x>" keeps the visit: MODE and back; anything else ends it). Its
-- render images let go of the targets before the bays are released, so it runs before releasePreviews.
local function racersLeave(why)
    if cardsReady() then U.try(TAG, function() racers().leave(why) end) end
end

---------------------------------------------------------------------------------------------------- page skeleton
local function buildWidgets(root)
    W.panel = newW(VBOX)
    W.hdr = ui().header(W.pc, "RACE SETUP")
    vAdd(W.panel, W.hdr, pad(0, 0, 0, 6))
    W.crumb = label("")
    vAdd(W.panel, W.crumb, pad(0, 0, 0, 6))
    -- body: media + info (left), options list + value rows (right)
    W.body = newW(HBOX)
    local left = newW(VBOX)
    W.mediaBox = sizeBox(opt("SetupMediaW", 640), opt("SetupMediaH", 360))
    W.mediaOver = newW(OVER)
    W.mediaBox:AddChild(W.mediaOver)
    W.media = newW(IMAGE)                                   -- video (material brush) or a still
    local ms = W.mediaOver:AddChildToOverlay(W.media)
    if U.ok(ms) then ms:SetHorizontalAlignment(0); ms:SetVerticalAlignment(0) end   -- Fill / Fill
    W.insetBox = sizeBox(opt("SetupInsetW", 256), opt("SetupInsetH", 144))
    W.inset = newW(IMAGE)
    W.insetBox:AddChild(W.inset)
    local is = W.mediaOver:AddChildToOverlay(W.insetBox)
    if U.ok(is) then is:SetHorizontalAlignment(3); is:SetVerticalAlignment(3); is:SetPadding(pad(0, 0, 8, 8)) end
    vAdd(left, W.mediaBox, pad(0, 0, 0, 8), C.E.HAlign.Left)
    W.info = {}
    for i = 1, 6 do
        W.info[i] = label("")
        vAdd(left, W.info[i], pad(0, 1, 0, 1))
    end
    hAdd(W.body, left, opt("SetupLeftWeight", 0.45), pad(0, 0, 16, 0))
    local right = newW(VBOX)
    W.listBox = newW(SIZE)
    W.listBox:SetMaxDesiredHeight(opt("SetupListMaxH", 520))
    W.scroll = newW(SCROLL)
    pcall(function() W.scroll:SetScrollWhenFocusChanges(2) end)   -- AnimatedScroll
    W.listBox:AddChild(W.scroll)
    local n = math.max(4, math.floor(tonumber(opt("SetupListMax", 16)) or 16))
    for i = 1, n do
        local idx = i
        local b = button("opt" .. i, "", function() M.onOption(idx) end)
        W.opts[i] = b
        W.scroll:AddChild(b)                                 -- -> ScrollBoxSlot
    end
    vAdd(right, W.listBox, pad(0, 0, 0, 8))
    W.gridCy = makeCycler("grid", function(dir) M.stepGrid(dir) end)
    vAdd(right, W.gridCy.box, pad(0, 4, 0, 4))
    hAdd(W.body, right, 1 - opt("SetupLeftWeight", 0.45))
    vAdd(W.panel, W.body, pad(0, 0, 0, 8))
    -- 0.9.0 campaign views (collapsed until their step shows; a failure leaves the lists)
    if CM then
        local okC, why = pcall(CM.build, cmapCtx())
        if not okC then U.err(TAG, "campaign views not built (%s): PLANET / TRACK use the lists", tostring(why)) end
    end
    -- vehicles: one column per local player
    W.vehRow = newW(HBOX)
    for i = 1, 4 do
        local col = makeColumn(i)
        hAdd(W.vehRow, col.box, 1, pad(i > 1 and 12 or 0, 0, 0, 0))
    end
    vAdd(W.panel, W.vehRow, pad(0, 0, 0, 8))
    -- 0.10.0 RACERS: the card row (collapsed until step 5 shows in the cards flow)
    cardsStage("card row", buildCardRow)
    -- footer
    W.footer = newW(HBOX)
    W.back = button("back", "< BACK", function() M.back() end)
    hAdd(W.footer, W.back, 1, pad(0, 0, 8, 0))
    W.save = button("save", "SAVE AND RETURN", function() M.finish(false) end)
    hAdd(W.footer, W.save, 1, pad(0, 0, 8, 0))
    W.start = button("start", "START RACE", function() M.finish(true) end)
    hAdd(W.footer, W.start, 1)
    cardsStage("sink host", buildSinkHost)                 -- 0.10.0: P1's input sink, right end
    vAdd(W.panel, W.footer, pad(0, 4, 0, 4))
    W.status = label("")
    vAdd(W.panel, W.status, pad(0, 2, 0, 0))
    ui().addRow(root, W.panel, 0, 0)
    cardsStage("racers.build", buildRacers)                -- 0.10.0: cards.init + the sink, on the complete page
end

-- lobby.build: once per lobby page. false = the flow is unavailable (lobby falls back to the dev panel).
function M.build(root, pc, page)
    if W and W.pageKey == U.key(page) and U.ok(W.panel) then return not W.broken end
    W = { pageKey = U.key(page), page = page, pc = pc, tree = page.WidgetTree, cyclers = {}, opts = {}, cols = {},
          focusables = {}, cardsOk = false, cardsBroken = false }
    textCache, imgCache = {}, {}
    M._resetVideoFlags()                                   -- address-keyed like the caches above (new page)
    local ok, err = pcall(buildWidgets, root)
    if not ok then
        W.broken = true
        U.err(TAG, "race setup page could not be built (%s): the lobby uses the dev race builder", tostring(err))
        if U.ok(W.panel) then show(W.panel, false) end
        return false
    end
    show(W.panel, false)
    U.log(TAG, "race setup page built (%d option rows, %d focusable widgets, campaign views: %s, step 5: %s)", #W.opts,
        #W.focusables, CM and CM.status() or "not loaded", W.cardsOk and "RACERS cards"
        or (cardsWanted() and "classic columns (cards unavailable)" or "classic columns"))
    return true
end

function M.available() return W ~= nil and not W.broken and U.ok(W.panel) end

-- New menu instance (ui.forgetAll -> lobby.resetNav): our widgets died with the old page.
function M.forget()
    if S.active then M.stopVideo("menu replaced") end
    -- 0.10.0: the cards died with the page. Also when they failed on it (racers.build after cards.init, or the step
    -- entry): racers / cards must not keep that page's sink and card widgets for the next page
    if cardsWanted() then pcall(function() racers().forget() end) end
    releasePreviews("menu replaced", false)                  -- the old page's images die with it
    if CM then pcall(CM.forget) end
    M._resetVideoFlags()
    S.active = false
    W = nil
end

---------------------------------------------------------------------------------------------------- media
-- The planet video plays in the game's own UI Bink player (the one the main menu uses); the URL it had is restored
-- when the setup closes. VERIFY(V-SET-02): OpenUrl("./Movies/MEDIA_PlanetEstablish_*.bk2") + Play() shows the movie
-- through M_UI_MediaPlayer_Video_Mat on our image; fallback cfg.SetupVideo = false (planet still image).
local video = { player = nil, mat = nil, saved = false, prevUrl = "", prevLoop = false, url = nil, matOn = {} }
function M._resetVideoFlags() video.matOn = {}; video.pending = nil end  -- M.build / M.forget are above `video`

local function videoObjects()
    if not U.ok(video.player) then video.player = U.obj("/Game/Movies/UI_BinkMediaPlayer.UI_BinkMediaPlayer") end
    if not U.ok(video.mat) then video.mat = U.obj("/Game/Movies/M_UI_MediaPlayer_Video_Mat.M_UI_MediaPlayer_Video_Mat") end
    return U.ok(video.player) and U.ok(video.mat)
end

local function ensureMaterial(img)
    local k = U.key(img)
    if video.matOn[k] then return end
    if pcall(function() img:SetBrushFromMaterial(video.mat) end) then video.matOn[k] = true end   -- (MaterialInterface)
    imgCache[k] = "<video>"
end

local function openVideo(url, img)
    local ok = pcall(function()
        local p = video.player
        if not video.saved then
            video.prevUrl = U.str(p:GetUrl())                  -- GetUrl() -> Str
            video.prevLoop = p:IsLooping() == true
            video.saved = true
        end
        p:OpenUrl(url)                                         -- OpenUrl(Str) -> Bool
        p:SetLooping(true)
        local vol = tonumber(opt("SetupVideoVolume", -1)) or -1
        if vol >= 0 then p:SetVolume(vol) end
        p:Play()
    end)
    if not ok then
        U.logOnce("setup.video!", TAG, "planet video unavailable (Bink player call failed); stills only")
        return false
    end
    video.url = url
    ensureMaterial(img)
    U.dbg(TAG, "video: %s", url)
    return true
end

-- true when the movie was started or queued (img, default the media image, then shows the video material). 0.9.0:
-- the material flag is per image (cmap's planet view shows the movie on its own image). 0.10.0: while a movie is
-- already up, a new URL waits until the selection has been still for cfg.SetupVideoSettleMs (scrolling the planet
-- carousel opened 2-3 Bink files a second); M.videoTick (pollNav) opens it.
local function playVideo(url, img)
    if opt("SetupVideo", true) == false or not videoObjects() then return false end
    img = img or W.media
    if video.url == url then video.pending = nil; ensureMaterial(img); return true end
    local settle = tonumber(opt("SetupVideoSettleMs", 250)) or 0
    if settle > 0 and video.url ~= nil then
        video.pending = { url = url, img = img, at = M.realMs() + settle }
        ensureMaterial(img)
        return true
    end
    return openVideo(url, img)
end

function M.videoTick()
    local p = video.pending
    if p == nil or M.realMs() < p.at then return end
    video.pending = nil
    if video.url ~= p.url and U.ok(p.img) then openVideo(p.url, p.img) end
end

function M.stopVideo(why)
    video.pending = nil
    if not video.saved then return end
    video.saved = false
    video.url = nil
    pcall(function()
        local p = video.player
        if not U.ok(p) then return end
        if video.prevUrl ~= "" then
            p:OpenUrl(video.prevUrl)
            p:SetLooping(video.prevLoop)
            p:Play()
        else
            p:Stop()
            p:CloseUrl()
        end
    end)
    U.dbg(TAG, "video restored to '%s' (%s)", video.prevUrl, tostring(why))
end

-- Media area: still (texture path) or the planet's video; inset = small art in the corner (nil = hidden).
local function setMedia(still, videoUrl, insetPath)
    if not W then return end
    if not videoUrl and video.saved then M.stopVideo("still") end
    local playing = videoUrl and playVideo(videoUrl) or false
    if not playing then
        video.matOn[U.key(W.media)] = nil
        if not still or not setImage(W.media, still) then imgCache[U.key(W.media)] = nil end
    end
    if insetPath and setImage(W.inset, insetPath) then show(W.insetBox, true) else show(W.insetBox, false) end
end

---------------------------------------------------------------------------------------------------- data
local trackCache = {}   -- "<arch>|<planet key>" -> list (per session; TrackDefs are permanent data assets)

local function prettyCond(tag)
    local s = tostring(tag or ""):gsub("^TrackCondition%.", ""):gsub("%.", " ")
    if s == "" or s == "None" then return "DEFAULT" end
    return string.upper(s)
end
M.prettyCond = prettyCond

local function readTrack(t)
    local e = { obj = t, key = trackKey(t), name = "?", laps = 0, p2p = false, rev = false, mines = false, conds = {},
                internal = "" }
    pcall(function() e.name = string.upper(U.str(t.PlayerFacingName)) end)
    pcall(function() e.internal = U.str(t.InternalName) end)
    pcall(function() e.laps = tonumber(t.DefaultLapCount) or 0 end)
    pcall(function() e.p2p = t.bIsPointToPoint == true end)
    pcall(function() e.rev = t.bIsReverse == true end)
    pcall(function() e.mines = t.bHasMines == true end)
    pcall(function()
        local arr = t.TrackConditionDataLayers
        for i = 1, arr:GetArrayNum() do
            local tag = U.str(arr[i].Tag.TagName)
            if tag ~= "" and tag ~= "None" then e.conds[#e.conds + 1] = tag end
        end
    end)
    if e.name == "" or e.name == "?" then e.name = e.key end
    return e
end

-- Run E 2026-10-07: "MOS ESPA SPEEDWAY (BGL_PLANE_FWD)" listed several times. The quick-play list holds campaign /
-- event copies of one layout (decoded-tracks.tsv: TRAK_BGL_PLANE_FWD, _GC, _PDay, _PDay_ACT2 share InternalName
-- BGL_PLANE_FWD and the display name). Tracks are grouped by layout = display name + InternalName + reverse/p2p/
-- mines; each group keeps ONE entry: the plain TrackDef (no _GC/_ACT/_PDay suffix) first, then the one with the most
-- conditions, then the shortest asset name. The others stay as e.alts (art + preselect). Same display name with a
-- different layout: a readable variant hint from the InternalName ("LOOP B", "SHORT 2", ...).
-- VERIFY(V-SET-12): Tatooine lists "MOS ESPA SPEEDWAY" and "MOS ESPA SPEEDWAY · REVERSE" once each.
local SUFFIX_PENALTY = { "_GC", "_ACT", "_PDAY", "_PNIGHT", "_ARC", "_TEST", "_DEBUG", "_DEV" }

local function variantScore(e)
    local k, pen = string.upper(e.key or ""), 0
    for _, suf in ipairs(SUFFIX_PENALTY) do if k:find(suf, 1, true) then pen = pen + 1 end end
    return pen
end

-- "HSK_LOOP_B_SHORT_02" -> "LOOP B · SHORT 2"; planet code, FWD/REV and the track word dropped.
local function variantHint(internal)
    local t = {}
    for part in string.upper(internal or ""):gmatch("[^_]+") do t[#t + 1] = part end
    if #t > 1 then table.remove(t, 1) end            -- planet code (MAS, DAL, HSK, BGL, Beagle, SHK...)
    local out, i = {}, 1
    while i <= #t do
        local w = t[i]
        if w == "FWD" or w == "REV" or w == "PLANE" or w == "MINES" or w == "PDAY" then
            -- flags shown separately / class word
        elseif (w == "LOOP" or w == "SHORT" or w == "P2P") and t[i + 1] and t[i + 1]:match("^%w%w?$") then
            local n = t[i + 1]
            out[#out + 1] = w .. " " .. (tonumber(n) and tostring(tonumber(n)) or n)
            i = i + 1
        else
            out[#out + 1] = w
        end
        i = i + 1
    end
    return table.concat(out, " · ")
end

-- ranked (0.10.0, a track set is active): group by layout without the display name (it folded "Sebulba's
-- Challenge" into the tour's "Debris Dunes" pod layout) and let the pool rank win (Quick Race / Quick Podrace first).
local function dedupeTracks(list, cls, planet, ranked)
    if opt("SetupTrackDedupe", true) == false then         -- fallback: every TrackDef the game returns
        local byName = {}
        for _, e in ipairs(list) do byName[e.name] = (byName[e.name] or 0) + 1 end
        for _, e in ipairs(list) do
            e.dup = byName[e.name] > 1
            e.hint = e.dup and (e.key or e.internal) or nil
        end
        return list
    end
    local groups, order = {}, {}
    for _, e in ipairs(list) do
        local first = e.name
        if ranked then first = ((e.internal or "") == "") and (e.key or e.name) or "" end   -- no InternalName: own row
        local g = table.concat({ first, string.upper(e.internal or ""), tostring(e.rev), tostring(e.p2p),
            tostring(e.mines) }, "|")
        if not groups[g] then groups[g] = {}; order[#order + 1] = g end
        local l = groups[g]
        l[#l + 1] = e
    end
    local out, dropped = {}, 0
    for _, g in ipairs(order) do
        local l = groups[g]
        table.sort(l, function(a, b)
            if ranked and (a.rank or 9) ~= (b.rank or 9) then return (a.rank or 9) < (b.rank or 9) end
            local sa, sb = variantScore(a), variantScore(b)
            if sa ~= sb then return sa < sb end
            if #a.conds ~= #b.conds then return #a.conds > #b.conds end
            return #(a.key or "") < #(b.key or "")
        end)
        local keep = l[1]
        keep.alts = {}
        for i = 2, #l do keep.alts[#keep.alts + 1] = l[i]; dropped = dropped + 1 end
        out[#out + 1] = keep
    end
    -- same display name, different layouts: add a variant hint (flags are added by trackLabel)
    local byName = {}
    for _, e in ipairs(out) do byName[e.name] = (byName[e.name] or 0) + 1 end
    for _, e in ipairs(out) do
        e.dup = byName[e.name] > 1
        if e.dup then
            local h = variantHint(e.internal)
            e.hint = (h ~= "") and h or nil
        end
    end
    if dropped > 0 then
        U.log(TAG, "tracks for %s on %s: %d listed, %d duplicate TrackDef(s) folded (kept: %s)", tostring(cls.key),
            tostring(planet.key), #out, dropped, (function()
                local t = {}
                for _, e in ipairs(out) do t[#t + 1] = e.key end
                return table.concat(t, ",")
            end)())
    end
    return out
end

-- Tracks the game offers for (class, planet): GfnGameInstance.Events:GetQuickplayTracksForVehicleAndPlanet, the
-- native filter the dev panel uses. nil when the call failed (unknown), {} when the planet has none for the class.
---------------------------------------------------------------------------------------------------- track pools
-- 0.10.0 (notes/research/track-whitelist.md). GetQuickplayTracksForVehicleAndPlanet is the dev panel's helper with no
-- shipping filter: every loaded TrackDef of the planet whose VehicleTypeTag fits comes back (Prologue slices,
-- "COR [LOOP B - SHORT 01]", campaign _ACT2 copies, shakedown SHK_PRE_*, time-trial TT_*, boss arenas, untagged pod
-- tracks in the SPEEDER lists). The setup offers what the game itself offers, read from the game instance's own
-- data assets (native UPROPERTYs, hard references, no Blueprint call):
--   QR    GfnGameInstance.PvpInstantActionDef.Tracks[].track        "Quick Race" (speeders, 61 tracks)
--   QRP   GfnGameInstance.PvpPlaneInstantActionDef.Tracks[].track   "Quick Podrace" (6 tracks)
--   TOUR  GfnGameInstance.PvpRunDef.Tour.Planets[].Tracks[].track   Multiplayer Tour
--   PTOUR GfnGameInstance.PvpPlaneRunDef.Tour.Planets[].Tracks[]    Podracing Tour
--   ARC   GfnGameInstance.ArcadeDef.ArcadeEvents[].TrackDef          Arcade (precision courses excluded)
-- cfg.SetupTrackSet: "quickrace" (QR+QRP) | "arcade" (+ARC, default) | "game" (+both tours) | "all" (0.9.x lists).
-- The class comes from the pool (speeder pool -> Landspeeder/Bike/Skimmer, pod pool -> Podracer), the pool rank wins
-- the dedupe (the Quick Podrace TrackDef over its "memory" twin). TRACK_POOLS is the generated fallback (hotfix
-- CL382493 paks, identical before the hotfix) for when the pools cannot be read.
-- VERIFY(V-TRK-01): "track pools 'arcade': 77 TrackDef(s) (game data)" on the first setup open.
local POOL_SETS = {
    quickrace = { QR = 1, QRP = 1 },
    arcade    = { QR = 1, QRP = 1, ARC = 3 },
    game      = { QR = 1, QRP = 1, TOUR = 2, PTOUR = 2, ARC = 3 },
}
-- TRACK_POOLS letters: Q Quick Race, q Quick Podrace, T Multiplayer Tour, t Podracing Tour, A / a Arcade race
-- track (speeder / pod).
local POOL_LETTERS = { Q = { "QR", "speeder" }, q = { "QRP", "pod" }, T = { "TOUR", "speeder" },
                       t = { "PTOUR", "pod" }, A = { "ARC", "speeder" }, a = { "ARC", "pod" } }
local TRACK_POOLS = {
    TRAK_BGL_PLANE_FWD = "a", TRAK_BGL_PLANE_FWD_PDay = "qt", TRAK_COR_Loop_A_FWD = "QTA",
    TRAK_COR_Loop_A_FWD_MINES = "QT", TRAK_COR_Loop_A_REV = "QT", TRAK_COR_Loop_A_SHORT_02 = "QTA",
    TRAK_COR_Loop_A_SHORT_02_MINES = "QT", TRAK_COR_Loop_B_FWD = "QTA", TRAK_COR_Loop_B_FWD_MINES = "QT",
    TRAK_COR_Loop_B_REV = "QT", TRAK_COR_P2P_FWD = "QT", TRAK_COR_P2P_FWD_MINES = "QT", TRAK_COR_P2P_REV = "QT",
    TRAK_COR_P2P_SHORT_05 = "QTA", TRAK_COR_PLANE_FWD_Pday = "t", TRAK_DAL_LOOP_A_FWD = "QT",
    TRAK_DAL_LOOP_A_FWD_MINES = "QT", TRAK_DAL_LOOP_A_SHORT_01 = "QTA", TRAK_DAL_LOOP_A_SHORT_06 = "QTA",
    TRAK_DAL_LOOP_B_FWD = "QTA", TRAK_DAL_LOOP_B_FWD_MINES = "QT", TRAK_DAL_LOOP_B_REV = "QTA",
    TRAK_DAL_LOOP_B_SHORT_03 = "QT", TRAK_DAL_P2P_FWD = "QTA", TRAK_DAL_P2P_FWD_MINES = "QT",
    TRAK_DAL_P2P_SHORT_05 = "QTA", TRAK_DAL_PLANE_FWD_Pday = "qta", TRAK_HSK_LOOP_A_FWD = "QT",
    TRAK_HSK_LOOP_A_FWD_MINES = "QTA", TRAK_HSK_LOOP_A_FWD_MP_PLANE = "t", TRAK_HSK_LOOP_A_REV = "QTA",
    TRAK_HSK_LOOP_B_FWD = "QT", TRAK_HSK_LOOP_B_FWD_MINES = "QT", TRAK_HSK_LOOP_B_FWD_PDAY_PLANE = "t",
    TRAK_HSK_LOOP_B_REV = "QTA", TRAK_HSK_LOOP_B_SHORT_02 = "QTA", TRAK_HSK_LOOP_B_SHORT_02_MINES = "T",
    TRAK_HSK_P2P_FWD = "QTA", TRAK_HSK_P2P_FWD_MINES = "QT", TRAK_HSK_P2P_REV = "QT",
    TRAK_HSK_P2P_SPEC_SHORT_01 = "QTA", TRAK_HSK_P2P_SPEC_SHORT_02 = "QT", TRAK_INSTA_COR_PLANE_FWD = "qa",
    TRAK_INSTA_COR_PLANE_REV = "qa", TRAK_INSTA_DAL_PLANE_REV = "a", TRAK_MAS_LOOP_A_FWD = "QT",
    TRAK_MAS_LOOP_A_FWD_HARD = "QT", TRAK_MAS_LOOP_A_FWD_MINES = "QT", TRAK_MAS_LOOP_A_REV = "QTA",
    TRAK_MAS_LOOP_A_REV_HARD = "QT", TRAK_MAS_LOOP_A_SHORT_02 = "QTA", TRAK_MAS_LOOP_A_SHORT_02_HARD = "QT",
    TRAK_MAS_LOOP_B_FWD = "QT", TRAK_MAS_LOOP_B_FWD_HARD = "QT", TRAK_MAS_LOOP_B_FWD_MINES = "QT",
    TRAK_MAS_LOOP_B_FWD_MP_PLANE = "t", TRAK_MAS_LOOP_B_REV = "QT", TRAK_MAS_LOOP_B_REV_HARD = "QT",
    TRAK_MAS_LOOP_B_SHORT_01 = "QTA", TRAK_MAS_P2P_FWD = "QT", TRAK_MAS_P2P_FWD_MINES = "QT",
    TRAK_MAS_P2P_SHORT_03 = "QT", TRAK_MAS_P2P_SHORT_03_MINES = "QT", TRAK_MAS_PLANE_FWD_Pday = "a",
    TRAK_MP_COR_Loop_A_FWD_PLANE = "t", TRAK_MP_COR_Loop_B_FWD_PLANE = "t", TRAK_MP_COR_P2P_FWD_PLANE = "t",
    TRAK_MP_COR_P2P_REV_PLANE = "t", TRAK_MP_COR_PLANE_FWD_Pday = "t", TRAK_MP_DAL_LOOP_B_FWD_PLANE = "t",
    TRAK_MP_DAL_P2P_FWD_PLANE = "t", TRAK_MP_DAL_PLANE_REV = "qt", TRAK_MP_HSK_P2P_FWD_PLANE = "t",
    TRAK_MP_MAS_P2P_FWD_PLANE = "t", TRAK_MP_SPA_Loop_A_FWD_PLANE = "t", TRAK_SHK_COR_P2P_REV = "A",
    TRAK_SHK_DAL_LOOP_A_FWD = "A", TRAK_SHK_MAS_P2P_RollingStart_FWD_01 = "A",
    TRAK_SHK_MAS_P2P_RollingStart_FWD_02 = "A", TRAK_SPA_Loop_A_FWD = "QTA", TRAK_SPA_Loop_A_FWD_MINES = "QT",
    TRAK_SPA_Loop_A_REV = "QT", TRAK_SPA_Loop_A_SHORT_01 = "A", TRAK_SPA_Loop_A_SHORT_01_MINES = "QT",
    TRAK_SPA_Loop_B_FWD = "QTA", TRAK_SPA_Loop_B_FWD_MINES = "QTA", TRAK_SPA_Loop_B_P2P = "QTA",
    TRAK_SPA_Loop_B_P2P_MINES = "QT", TRAK_SPA_Loop_B_SHORT_02 = "QT", TRAK_SPA_PLANE_FWD_PDay = "qta",
    TRAK_WHP_LOOP_A_FWD_ARC = "A", TRAK_WHP_LOOP_A_FWD_MP = "T", TRAK_WHP_PLANE_FWD = "a",
}
local poolCache = {}   -- set name -> { [TrackDef key] = { speeder = {rank, conds}, pod = {rank, conds} } }

local function poolEntry(P, key, grp, rank)
    local e = P[key] or {}
    P[key] = e
    local g = e[grp]
    if not g then g = { rank = rank, conds = {} }; e[grp] = g elseif rank < g.rank then g.rank = rank end
    return g
end

-- Arcade pod events run 1-2 pods (time trials, team races of 2). Live 2026-10-09 (V-TRK-08): an 8-pod race on
-- TRAK_WHP_PLANE_FWD crashed at PRERACE (AV null+0x1e0 at SWGR+0x3ad7857, crash_2026_10_09_18_51_15). Arcade-only pod
-- tracks are therefore left out unless cfg.SetupTrackArcadePods (the Quick Podrace and Podracing Tour pods race 6-8).
local function arcadePodsWanted() return opt("SetupTrackArcadePods", false) == true end

local function staticPools(set)
    local P = {}
    for key, letters in pairs(TRACK_POOLS) do
        for ch in letters:gmatch(".") do
            local spec = POOL_LETTERS[ch]
            local rank = spec and set[spec[1]]
            if rank and not (ch == "a" and not arcadePodsWanted()) then poolEntry(P, key, spec[2], rank) end
        end
    end
    return P
end

local function poolAdd(P, t, grp, rank, tagContainer)
    if not U.ok(t) then return end
    local key = trackKey(t)
    if key == "" then return end
    local g = poolEntry(P, key, grp, rank)
    if tagContainer then
        pcall(function()
            local tags = tagContainer.GameplayTags                       -- FGameplayTagContainer +0x0
            for i = 1, tags:GetArrayNum() do
                local s = U.str(tags[i].TagName)
                if s ~= "" and s ~= "None" then g.conds[s] = true end
            end
        end)
    end
end

local function poolAddSetups(P, arr, grp, rank)       -- TArray<FPvpTrackSetup {track, Weight, TrackConditionsOverride}>
    for i = 1, arr:GetArrayNum() do
        local st = arr[i]
        poolAdd(P, st.track, grp, rank, st.TrackConditionsOverride)
    end
end

local function trackPools(setName)
    if poolCache[setName] ~= nil then return poolCache[setName] end
    local set, P, n = POOL_SETS[setName], {}, 0
    local gi = U.gi()
    if not U.ok(gi) then return nil end                 -- transient: no cache, the next call tries again
    local ok, err = pcall(function()
        if set.QR then poolAddSetups(P, gi.PvpInstantActionDef.Tracks, "speeder", set.QR) end
        if set.QRP then poolAddSetups(P, gi.PvpPlaneInstantActionDef.Tracks, "pod", set.QRP) end
        for _, r in ipairs({ { "TOUR", "PvpRunDef", "speeder" }, { "PTOUR", "PvpPlaneRunDef", "pod" } }) do
            if set[r[1]] then
                local planets = gi[r[2]].Tour.Planets
                for i = 1, planets:GetArrayNum() do poolAddSetups(P, planets[i].Tracks, r[3], set[r[1]]) end
            end
        end
        if set.ARC then
            local evs = gi.ArcadeDef.ArcadeEvents
            for i = 1, evs:GetArrayNum() do
                local ev = evs[i]
                if U.ok(ev) and tonumber(ev.Category) ~= 4 then        -- EArcadeEventCategories::Precision
                    local pod = U.str(ev.VehicleTypeTag.TagName):find("^Vehicle%.Special") ~= nil
                    if not pod or arcadePodsWanted() then
                        poolAdd(P, ev.TrackDef, pod and "pod" or "speeder", set.ARC, nil)
                    end
                end
            end
        end
    end)
    for _ in pairs(P) do n = n + 1 end
    local source = "game data"
    if not ok or n == 0 then
        P, n, source = staticPools(set), 0, "static table, game data unreadable: " .. tostring(err)
        for _ in pairs(P) do n = n + 1 end
        U.warn(TAG, "track pools '%s': game data unreadable (%s); using the static whitelist", setName, tostring(err))
    end
    U.log(TAG, "track pools '%s': %d TrackDef(s) (%s) (V-TRK-01)", setName, n, source)
    poolCache[setName] = P
    return P
end

-- The set in effect: nil = no filter ("all" or an unknown value).
local function trackSetName()
    local s = tostring(opt("SetupTrackSet", "arcade"))
    return POOL_SETS[s] and s or nil
end

local function queryTracks(cls, planet)
    local setName = trackSetName()
    local ck = tostring(setName or "all") .. "|" .. tostring(cls.arch) .. "|" .. planet.key
    if trackCache[ck] then return trackCache[ck] end
    local va, pla = V.archetypeObj(cls), U.obj(planet.path)
    if not (va and U.ok(pla)) then return nil end
    local P = setName and trackPools(setName) or nil
    if setName and not P then return nil end            -- game instance not ready: unknown for now (not cached)
    local list = nil
    local ok, err = pcall(function()
        local events = U.gi().Events
        local raw = U.arrayToTable(events:GetQuickplayTracksForVehicleAndPlanet(va, pla))
        list = {}
        if not P then
            for i = 1, #raw do if U.ok(raw[i]) then list[#list + 1] = readTrack(raw[i]) end end
            return
        end
        local grp = (cls.arch == 1) and "pod" or "speeder"
        if grp == "pod" then                            -- 9 pod tracks have no VehicleTypeTag: only in the speeder lists
            local car = V.archetypeObj(V.classByArch(0))
            if car then
                local more = U.arrayToTable(events:GetQuickplayTracksForVehicleAndPlanet(car, pla))
                for i = 1, #more do raw[#raw + 1] = more[i] end
            end
        end
        local seen = {}
        for i = 1, #raw do
            local t = raw[i]
            local k = U.ok(t) and trackKey(t) or nil
            local pe = k and P[k] and P[k][grp]
            if pe and not seen[k] then
                seen[k] = true
                local e = readTrack(t)
                e.rank = pe.rank
                if opt("SetupTrackPoolConds", true) ~= false and next(pe.conds) ~= nil then
                    local keep = {}
                    for _, c in ipairs(e.conds) do if pe.conds[c] then keep[#keep + 1] = c end end
                    if #keep > 0 then e.conds = keep end
                end
                list[#list + 1] = e
            end
        end
    end)
    if not ok then
        U.warn(TAG, "track list for %s on %s unavailable: %s", cls.key, planet.key, tostring(err))
        return nil
    end
    list = dedupeTracks(list, cls, planet, setName ~= nil)
    trackCache[ck] = list
    return list
end

local function trackLabel(e)
    local flags = {}
    if e.rev then flags[#flags + 1] = "REVERSE" end
    if e.p2p then flags[#flags + 1] = "POINT TO POINT" end
    if e.mines then flags[#flags + 1] = "MINES" end
    local s = e.name
    if e.dup and e.hint then s = s .. "  ·  " .. e.hint end
    if #flags > 0 then s = s .. "  ·  " .. table.concat(flags, " · ") end
    return s
end

-- Test helper (testcmd lua, 0.10.0): every class x planet track list of the current set, one log line each
-- (V-TRK-02..06). Returns the number of lists logged.
function M.dumpTrackLists()
    local n = 0
    for _, cls in ipairs(V.CLASSES) do
        for _, p in ipairs(PLANETS) do
            local l = queryTracks(cls, p)
            if l and #l > 0 then
                local t = {}
                for _, e in ipairs(l) do
                    t[#t + 1] = tostring(e.key) .. " = " .. trackLabel(e) .. " [" .. table.concat(e.conds or {}, ",") .. "]"
                end
                U.log(TAG, "track list %s / %s (set %s): %d: %s", cls.key, p.key, tostring(trackSetName() or "all"), #l,
                    table.concat(t, " | "))
                n = n + 1
            end
        end
    end
    return n
end

local function planetsFor(cls)
    local out = {}
    for _, p in ipairs(PLANETS) do
        local wanted = not p.optional or (cls.arch == 1 and opt("SetupTatooine", true) ~= false)
        if wanted then
            local tracks = queryTracks(cls, p)
            if tracks == nil then
                out[#out + 1] = { planet = p, tracks = nil }         -- unknown: offered, the track step says so
            elseif #tracks > 0 then
                out[#out + 1] = { planet = p, tracks = tracks }
            end
        end
    end
    return out
end

local function humansCount()
    local n = 1
    pcall(function() n = 1 + #U.mod("join").joinedList() end)
    pcall(function() n = n + #U.mod("roster").remoteHumans() end)
    return n
end

local function modesFor(cls, track)
    local out = {}
    local tk = track and track.key or ""
    for _, m in ipairs(M.MODES) do
        if not (m.speedersOnly and cls.arch == 1) and EXCLUDED[tk] ~= m.asset and U.ok(U.obj(m.path)) then
            out[#out + 1] = m
        end
    end
    return out
end

-- Helpers for cmap.build (0.9.0). setImage clears the image's video-material flag: a still replaces the movie.
cmapCtx = function()
    return {
        W = W, newW = newW, sizeBox = sizeBox, button = button, show = show, showRow = showRow, setText = setText,
        pad = pad, vAdd = vAdd, hAdd = hAdd, prettyCond = prettyCond,
        setImage = function(img, path)
            video.matOn[U.key(img)] = nil
            return setImage(img, path)
        end,
        playVideoOn = function(img, url) return playVideo(url, img) end,
        stopVideo = function(why) M.stopVideo(why) end,
        onItem = function(i) M.onItem(i) end,
        realMs = function() return M.realMs() end,
    }
end

-- A campaign view failed at run time: that step uses the list from now on; the step is shown again from the FAST
-- loop (never re-entered from inside a preview or a showStep).
local function cmapFailed(step, why)
    if CM then pcall(CM.markBroken, step, why) end
    S.cmapRetry = step
end

---------------------------------------------------------------------------------------------------- rendering
-- racers: step 5 in the cards flow (0.10.0)
local STEP_TITLE = { class = "STEP 1/5  CLASS", planet = "STEP 2/5  PLANET", track = "STEP 3/5  TRACK",
                     cond = "STEP 3/5  CONDITIONS", mode = "STEP 4/5  MODE", vehicles = "STEP 5/5  VEHICLES",
                     racers = "STEP 5/5  RACERS" }

local function crumb()
    local parts = {}
    if S.cls then parts[#parts + 1] = S.cls.label end
    if S.planet and S.step ~= "class" then parts[#parts + 1] = S.planet.name end
    if S.track and (S.step == "cond" or S.step == "mode" or S.step == "vehicles") then
        parts[#parts + 1] = S.track.name .. (S.track.rev and " (REVERSE)" or "")
        if S.cond ~= "" then parts[#parts + 1] = prettyCond(S.cond) end
    end
    if S.mode and S.step == "vehicles" then parts[#parts + 1] = S.mode.label end
    local title = (S.step == "vehicles" and S.cards) and STEP_TITLE.racers or STEP_TITLE[S.step]
    return (title or "") .. "      " .. table.concat(parts, "  >  ")
end

local function setInfo(lines)
    for i = 1, #W.info do
        local t = lines[i]
        setText(W.info[i], t or "")
        showRow(W.info[i], t ~= nil and t ~= "")
    end
end

-- Fill the option pool from S.items (paged: the last row becomes "MORE" when the list is longer than the pool).
local function fillOptions()
    local n, total = #W.opts, #S.items
    local per = total > n and (n - 1) or n
    local pages = math.max(1, math.ceil(total / per))
    if S.page >= pages or S.page < 0 then S.page = 0 end
    local first = S.page * per
    W.optMap = {}
    for i = 1, n do
        local w, idx = W.opts[i], first + i
        if i <= per and idx <= total then
            setText(w, S.items[idx].label, true)
            showRow(w, true)
            W.optMap[i] = idx
        elseif i == n and total > n then
            setText(w, string.format("MORE  (PAGE %d / %d)  >", S.page + 1, pages), true)
            showRow(w, true)
            W.optMap[i] = "more"
        else
            showRow(w, false)
        end
    end
    pcall(function() W.scroll:ScrollToStart() end)
end

-- Option row that shows item idx (switching to its page), or nil.
local function optionFor(idx)
    if not idx or #S.items == 0 then return nil end
    local n = #W.opts
    local per = #S.items > n and (n - 1) or n
    local page = math.floor((idx - 1) / per)
    if page ~= S.page then S.page = page; fillOptions() end
    return W.opts[idx - page * per]
end

---------------------------------------------------------------------------------------------------- steps
local function indexWhere(list, pred)
    for i, v in ipairs(list) do if pred(v) then return i end end
    return nil
end

local STEPS = {}

STEPS.class = function()
    S.items = {}
    for _, cls in ipairs(V.CLASSES) do
        S.items[#S.items + 1] = {
            label = cls.label,
            preview = function()
                local info = V.classInfo(cls)
                local lines = { info.name, info.desc }
                for _, t in ipairs(info.traits) do lines[#lines + 1] = t end
                lines[#lines + 1] = string.format("UP TO %d RACERS", V.maxRacers(cls))
                setInfo(lines)
                setMedia((V.classImage and V.classImage(cls, nil)) or cls.image, nil, cls.icon)
            end,
            choose = function()
                if S.cls ~= cls then S.planet, S.track, S.cond, S.gridTouched = nil, nil, "", false end
                S.cls = cls
                M.showStep("planet")
            end,
        }
    end
    return S.cls and indexWhere(V.CLASSES, function(c) return c == S.cls end) or 1
end

STEPS.planet = function()
    S.items = {}
    S.planets = planetsFor(S.cls)
    for idx, e in ipairs(S.planets) do
        local p = e.planet
        local n = e.tracks and #e.tracks or nil
        local circuits = 0
        do
            local seen = {}
            for _, t in ipairs(e.tracks or {}) do
                if not seen[t.name] then seen[t.name] = true; circuits = circuits + 1 end
            end
        end
        S.items[#S.items + 1] = {
            label = p.name .. (n and string.format("   (%d TRACK%s)", n, n == 1 and "" or "S") or ""),
            preview = function()
                if S.view == "cmap" and CM then
                    local count = n and string.format("%d CIRCUIT%s  ·  %d TRACK%s FOR THE %s", circuits,
                        circuits == 1 and "" or "S", n, n == 1 and "" or "S", S.cls.label) or "TRACK LIST UNKNOWN"
                    local okC, err = pcall(CM.previewPlanet, idx, { planet = p, count = count, url = p.url })
                    if not okC then cmapFailed("planet", err) end
                    return
                end
                local flavour = ""
                pcall(function() flavour = U.str(U.obj(p.path).FlavourText) end)
                setInfo({ p.name, flavour, n and string.format("%d TRACK%s FOR THE %s", n, n == 1 and "" or "S",
                    S.cls.label) or "TRACK LIST UNKNOWN" })
                setMedia(p.hires, p.url, p.select)
            end,
            choose = function()
                if S.planet ~= p then S.track, S.cond = nil, "" end
                S.planet = p
                S.tracks = e.tracks or {}
                if S.view == "cmap" and CM then pcall(CM.sound, "RunMap_PlanetClick_Accept") end
                M.showStep("track")
            end,
        }
    end
    if #S.items == 0 then status("NO PLANET HAS TRACKS FOR THE " .. S.cls.label) end
    return S.planet and indexWhere(S.planets, function(e) return e.planet == S.planet end) or 1
end

local function trackArt(e)
    local tile = TRACK_TILE[e.key]
    for _, a in ipairs(e.alts or {}) do tile = tile or TRACK_TILE[a.key] end
    if tile then return tp("Arcade", "T_UI_Arcade_" .. tile .. "_Tile") end
    return arcadeBg(S.planet, S.cls)
end

STEPS.track = function()
    S.items = {}
    for idx, e in ipairs(S.tracks or {}) do
        S.items[#S.items + 1] = {
            label = trackLabel(e),
            preview = function()
                if S.view == "cmap" and CM then
                    local okC, err = pcall(CM.previewTrack, idx, { e = e, planet = S.planet.name, cls = S.cls.label,
                        art = trackArt(e) })
                    if not okC then cmapFailed("track", err) end
                    return
                end
                local laps = e.p2p and "1 LAP (POINT TO POINT)" or string.format("%d LAPS", e.laps)
                local conds = {}
                for _, t in ipairs(e.conds) do conds[#conds + 1] = prettyCond(t) end
                setInfo({ e.name, S.planet.name .. "  ·  " .. laps,
                    #conds > 0 and ("CONDITIONS: " .. table.concat(conds, ", ")) or "",
                    e.mines and "MINES ON THE TRACK" or "", e.rev and "REVERSE DIRECTION" or (e.hint or "") })
                setMedia(S.planet.hires, S.planet.url, trackArt(e))
            end,
            choose = function()
                if S.track ~= e then S.cond = "" end
                S.track = e
                if #e.conds > 1 and opt("SetupAskCondition", true) ~= false then
                    M.showStep("cond")
                else
                    S.cond = e.conds[1] or ""
                    M.showStep("mode")
                end
            end,
        }
    end
    if #S.items == 0 then status("NO TRACK FOUND: TRY ANOTHER PLANET OR THE ADVANCED BUILDER") end
    return S.track and indexWhere(S.tracks, function(e) return e == S.track end) or 1
end

STEPS.cond = function()
    S.items = {}
    for _, tag in ipairs(S.track.conds) do
        S.items[#S.items + 1] = {
            label = prettyCond(tag),
            preview = function()
                setInfo({ trackLabel(S.track), "CONDITIONS: " .. prettyCond(tag), "" })
                setMedia(S.planet.hires, S.planet.url, trackArt(S.track))
            end,
            choose = function() S.cond = tag; M.showStep("mode") end,
        }
    end
    return indexWhere(S.track.conds, function(t) return t == S.cond end) or 1
end

local function gridText(m)
    m = m or S.focusMode or S.mode
    if not m or m.grid ~= "max" then return "GRID: SET BY THE GAME" end
    local h = humansCount()
    return string.format("GRID: %d RACERS  (%d AI)", S.grid, math.max(0, S.grid - h))
end

STEPS.mode = function()
    S.items = {}
    local mx = V.maxRacers(S.cls)
    if not S.gridTouched then S.grid = mx end
    S.grid = math.max(humansCount(), math.min(S.grid, mx))
    for _, m in ipairs(modesFor(S.cls, S.track)) do
        S.items[#S.items + 1] = {
            label = m.label,
            preview = function()
                S.focusMode = m
                setText(W.gridCy.m, gridText(m), true)
                setInfo({ m.label, m.desc, m.single and ("ALL RACERS DRIVE A " .. S.cls.label) or "",
                    m.grid == "max" and string.format("UP TO %d RACERS FOR THE %s", mx, S.cls.label) or "" })
                setMedia(S.planet.hires, S.planet.url, trackArt(S.track))
            end,
            choose = function() S.mode = m; M.showStep("vehicles") end,
        }
    end
    return S.mode and indexWhere(S.items, function(it) return it.label == S.mode.label end) or 1
end

---------------------------------------------------------------------------------------------------- vehicles step
local function localPlayers()
    local list = { { pnum = 1, ctrlId = 0, pc = U.p1() } }
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do
            list[#list + 1] = { pnum = e.pnum, ctrlId = e.ctrlId, pc = e.pc }
        end
    end)
    return list
end

-- Where each player's view will be (split.lua layout rules: 2P cfg Layout2P, 3P favour-top, 4P grid).
local function viewName(i, n)
    if n <= 1 then return "FULL SCREEN" end
    if n == 2 then
        if settings.get("Layout2P") == "side-by-side" then return i == 1 and "LEFT" or "RIGHT" end
        return i == 1 and "TOP" or "BOTTOM"
    end
    if n == 3 then return ({ "TOP", "BOTTOM LEFT", "BOTTOM RIGHT" })[i] or "?" end
    return ({ "TOP LEFT", "TOP RIGHT", "BOTTOM LEFT", "BOTTOM RIGHT" })[i] or "?"
end

-- The race has one view per LocalPlayer (dormant guests are never removed and travel too), in LocalPlayers order:
-- the column's view = its PC's position there, out of all local players (not only the joined ones).
local function viewSlot(e, i, n)
    local lps = {}
    for _, lp in ipairs(U.localPlayers()) do if U.ok(lp.pc) then lps[#lps + 1] = lp end end
    if #lps < n then return i, n end
    for k, lp in ipairs(lps) do
        if U.same(lp.pc, e.pc) then return k, #lps end
    end
    return i, #lps
end

local function remember(p)
    local arch = S.cls.arch
    S.pickMemory[arch] = S.pickMemory[arch] or {}
    local pr, b = V.presets(arch)[p.preset], S.builds[p.build]
    S.pickMemory[arch][p.pnum] = { presetId = pr and pr.id or nil, buildPath = b and b.path or nil }
end

local function ensurePlayer(e)
    local arch = S.cls.arch
    local p = S.players[e.pnum]
    if not p or p.arch ~= arch then
        local mem = (S.pickMemory[arch] or {})[e.pnum]
        local presets = V.presets(arch)
        local pi = mem and mem.presetId and indexWhere(presets, function(x) return x.id == mem.presetId end)
        local bi = mem and mem.buildPath and V.buildIndex(S.builds, mem.buildPath)
        p = { pnum = e.pnum, arch = arch, preset = pi or V.defaultPresetIndex(arch, e.pnum), build = bi or 1,
              ready = false, row = 1, nav = { primed = false } }
        S.players[e.pnum] = p
    end
    if p.build > #S.builds then p.build = 1 end
    p.ctrlId, p.pc = e.ctrlId, e.pc
    return p
end

-- The vehicle card of column i: the 3D render of the pick once its bay has one (vpreview; the previous model stays,
-- dimmed, while a new pick builds), else the 2D art (feedback 8): the livery owner's portrait for a pilot-livery
-- preset, else the class render tinted in the player's colour. The manufacturer badge sits top left on both; next to
-- a render the portrait becomes the bottom-right inset. VERIFY(V-SET-07, V-VP-03, V-VP-08)
-- Card height: cfg.SetupCardH, lowered when n 16:9 cards (3D on) would not fit cfg.SetupCardRowW (4 players).
local function cardHeight(n)
    local h = opt("SetupCardH", 200)
    if VP and n > 0 and VP.enabled() == true then
        local fit = math.floor(((opt("SetupCardRowW", 1400) / n) - 16) / VP.aspect())
        if fit < h then h = math.max(80, fit) end
    end
    return h
end

local function renderCard(i, col, e, p, pr, h)
    if col.cardH ~= h then                                  -- player count changed the card height
        col.cardH, col.aspect, col.cardW = h, nil, nil
        pcall(function() col.imgBox:SetHeightOverride(h) end)
        if U.ok(col.cardBox) then pcall(function() col.cardBox:SetHeightOverride(h) end) end
    end
    local alpha = (i == 1 or p.ready) and 1.0 or 0.55
    local portrait = (opt("SetupCardPortraits", true) ~= false) and pr.portrait or nil
    local live = VP ~= nil and U.ok(col.render) and VP.enabled() == true
    local brush, kind, dim, asp
    if live then
        U.try(TAG, VP.want, i, pr, S.cls)
        local ok, b1, k1, d1, a1 = U.try(TAG, VP.brush, i)
        if ok then brush, kind, dim, asp = b1, k1, d1, a1 end
    end
    if brush and col.vpBrush ~= brush then
        local okB = pcall(function()
            if kind == "texture" then col.render:SetBrushResourceObject(brush) else col.render:SetBrushFromMaterial(brush) end
        end)
        if okB then col.vpBrush = brush else brush = nil end
    end
    if brush then
        show(col.render, true)
        show(col.imgBox, false)
        pcall(function() col.render:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = alpha * (dim or 1) }) end)
        show(col.insetBox, portrait ~= nil and setImage(col.inset, portrait))
    else
        resetRender(col)
        show(col.imgBox, true)
        show(col.insetBox, false)
        local usedPortrait = portrait ~= nil and setImage(col.img, portrait)
        local clsImg = (V.classImage and V.classImage(S.cls, S.planet and S.planet.art)) or S.cls.image
        if not usedPortrait and not setImage(col.img, clsImg) and clsImg ~= S.cls.image then
            setImage(col.img, S.cls.image)
        end
        -- the 2D art at its own aspect (portraits and renders are not 1.8:1; stretched they looked empty)
        pcall(function()
            local a2 = usedPortrait and (1480 / 1800) or (S.cls.aspect or 1.8)   -- portraits: 1480x1800
            if col.aspect ~= a2 then
                col.aspect = a2
                col.imgBox:SetWidthOverride(math.floor(h * a2 + 0.5))
            end
        end)
        pcall(function()
            local pc = C.COLOURS[e.pnum] or C.COLOURS.Remote
            local m = usedPortrait and 0 or 0.35                 -- portraits keep their colours
            col.img:SetColorAndOpacity({ R = 1 - m + m * pc.R, G = 1 - m + m * pc.G, B = 1 - m + m * pc.B, A = alpha })
        end)
    end
    -- card width: 16:9 while 3D renders are on (no reflow when a render arrives), else the 2D art's own width
    if U.ok(col.cardBox) then
        pcall(function()
            local w = math.floor(h * ((live and (asp or VP.aspect())) or col.aspect or 1.8) + 0.5)
            if col.cardW ~= w then
                col.cardW = w
                col.cardBox:SetWidthOverride(w)
            end
        end)
    end
    local badge = (opt("SetupCardBadges", true) ~= false and V.badge) and V.badge(pr) or nil
    show(col.badgeBox, badge ~= nil and setImage(col.badge, badge))
end

local function renderColumns()
    local list = localPlayers()
    S.order = list
    local cardH = cardHeight(#list)
    for i = 1, 4 do
        local col, e = W.cols[i], list[i]
        if not e then
            show(col.box, false)
            resetRender(col)
            if VP then U.try(TAG, VP.release, i, "no player in column " .. i, true) end
        else
            show(col.box, true)
            local p = ensurePlayer(e)
            local pr = V.presets(S.cls.arch)[p.preset] or { name = "?", owner = nil }
            local b = S.builds[p.build] or { label = "?" }
            local vi, vn = viewSlot(e, i, #list)
            setText(col.title, string.format("P%d  ·  %s", e.pnum, viewName(vi, vn)))
            tint(col.title, C.COLOURS[e.pnum])
            renderCard(i, col, e, p, pr, cardH)
            local nPresets = #V.presets(S.cls.arch)
            setText(col.owner, (pr.owner and ("LIVERY: " .. pr.owner) or "STANDARD LIVERY")
                .. string.format("   ·   %d / %d", p.preset, nPresets))
            if i == 1 then
                setText(col.name, pr.name)
                setText(col.vehCy.m, "MODEL: " .. pr.name, true)
                setText(col.buildCy.m, "BUILD: " .. b.label, true)
                showRow(col.build, false)
                setText(col.state, "YOU START THE RACE")
            else
                local edit = not p.ready
                setText(col.name, (edit and p.row == 1) and ("<  " .. pr.name .. "  >") or pr.name)
                setText(col.build, (edit and p.row == 2) and ("<  BUILD: " .. b.label .. "  >") or ("BUILD: " .. b.label))
                showRow(col.build, true)
                -- the active row in the player's colour (ui.highlight would ink labels white on the light page)
                tint(col.name, (edit and p.row == 1) and C.COLOURS[e.pnum] or INK_DARK)
                tint(col.build, (edit and p.row == 2) and C.COLOURS[e.pnum] or INK_DARK)
                setText(col.state, p.ready and "READY  (A / B = CHANGE)" or "D-PAD: PICK  ·  A: READY  ·  HOLD B: LEAVE")
            end
        end
    end
    setText(W.crumb, crumb())
end
M.renderColumns = renderColumns

-- what: "preset" | "build"; dir: -1 | 1 (wraps).
function M.stepPlayer(pnum, what, dir)
    local p = S.players[pnum]
    if not p or not S.cls then return end
    if what == "preset" then
        local n = #V.presets(S.cls.arch)
        if n > 0 then p.preset = ((p.preset - 1 + dir) % n) + 1 end
    else
        local n = #S.builds
        if n > 0 then p.build = ((p.build - 1 + dir) % n) + 1 end
    end
    remember(p)
    renderColumns()
end

function M.stepGrid(dir)
    local m = S.focusMode or S.mode
    if S.step ~= "mode" or not m or m.grid ~= "max" then return end
    local lo, hi = humansCount(), V.maxRacers(S.cls)
    S.grid = math.max(lo, math.min(hi, S.grid + dir))
    S.gridTouched = true
    setText(W.gridCy.m, gridText(m), true)
end

function M.cyclerStep(id, dir, src)
    local cy = W and W.cyclers[id]
    if not cy then return end
    U.dbg(TAG, "cycler %s %+d (%s)", id, dir, tostring(src))
    U.try(TAG, cy.onStep, dir)
end

---------------------------------------------------------------------------------------------------- flow
local function armKeeper(target)
    S.focusTarget = target
    S.keepUntil = M.realMs() + (tonumber(opt("LobbyFocusKeepMs", 3000)) or 3000)
    S.keepNext = 0
end

function M.focus(target)
    if not U.ok(target) then return false end
    pcall(function() W.page:SetDesiredFocusWidget(target) end)
    local ok = ui().focus(target, U.p1())
    armKeeper(target)
    return ok
end

-- 0.10.0: step 5 as RACERS (racers.enter: the players, their cards and previews) -> P1's focus target (the sink), or
-- nil when the cards cannot start: racers left, and this page uses the classic columns from now on.
local function enterCards()
    local ok, t = U.try(TAG, function() return racers().enter(S.cls, S.planet) end)
    if ok and U.ok(t) then return t end
    racersLeave("cards failed")
    W.cardsBroken, S.cards = true, false
    U.err(TAG, "RACERS step could not start (%s): this page uses the classic VEHICLES columns (V-RC-01)",
        ok and "no focus target" or "error")
    return nil
end

function M.showStep(step)
    if not W or not STEPS[step] and step ~= "vehicles" then return end
    if step ~= "vehicles" then
        racersLeave("step " .. step)                       -- 0.10.0: the cards' images first, then their bays
        releasePreviews("step " .. step)                   -- the bays exist only in the VEHICLES step
    end
    S.step, S.page, S.lastFocus, S.previewed, S.focusMode = step, 0, nil, nil, nil
    local veh = (step == "vehicles")
    S.cards = veh and cardsWanted() and cardsReady()       -- 0.10.0: step 5 = RACERS (cards flow)
    -- 0.9.0: PLANET / TRACK in cmap's campaign views when usable, else the lists (S.items drives both)
    S.view = (CM and not veh and CM.usable(step)) and "cmap" or "list"
    if CM then pcall(CM.setView, S.view == "cmap" and step or nil) end
    if S.view == "cmap" and step == "track" then M.stopVideo("run map") end   -- the run map has no video area
    show(W.body, not veh and S.view == "list")
    show(W.vehRow, veh and not S.cards)
    show(W.cardBox, veh and S.cards)
    show(W.sinkHost, veh and S.cards)
    show(W.gridCy.box, step == "mode")
    showRow(W.save, veh)
    showRow(W.start, veh)
    setText(W.back, step == "class" and "< BACK TO LOBBY" or "< BACK", true)
    setText(W.crumb, crumb())
    local target
    if veh then
        M.stopVideo("vehicles step")
        S.builds = V.builds(S.cls.arch)
        S.startConfirmUntil, S.startDormant = 0, nil
        if S.cards then target = enterCards() end
        if not S.cards then                                -- classic, or the cards failed just now
            show(W.cardBox, false)
            show(W.sinkHost, false)
            show(W.vehRow, true)
            renderColumns()
            target = W.cols[1].vehCy.m
        end
        setText(W.crumb, crumb())
    else
        local sel = STEPS[step]() or 1
        if S.view == "cmap" and #S.items == 0 then           -- nothing to show: the list (with its message), map kept
            S.view = "list"
            pcall(CM.setView, nil)
            show(W.body, true)
        end
        if S.view == "cmap" then
            local okC, t = pcall(function()
                if step == "planet" then return CM.showPlanets(S.planets, sel) end
                return CM.showTracks({ planet = S.planet, tracks = S.tracks, sel = sel, isPod = S.cls.arch == 1 })
            end)
            if okC and U.ok(t) then
                target = t
            else
                pcall(CM.markBroken, step, okC and "no focus target" or t)
                S.view = "list"
                pcall(CM.setView, nil)
                show(W.body, true)
            end
        end
        if S.view == "list" then
            fillOptions()
            target = optionFor(sel) or W.back
        end
        if S.items[sel] then
            U.try(TAG, S.items[sel].preview)
            S.previewed = sel
        end
    end
    M.focus(target)
    U.dbg(TAG, "step %s (%d items, %s)", step, #S.items, tostring(S.view))
end

-- 0.9.0: a chip / map node chosen (cmap): the same as a list row's click.
function M.onItem(i)
    if not M.isActive() then return end
    local it = S.items[i]
    if it then
        S.previewed = i
        U.try(TAG, it.preview)
        U.try(TAG, it.choose)
    end
end

-- A click / pad A on option row i (ui.pollClicks dispatch).
function M.onOption(i)
    if not M.isActive() or not W.optMap then return end
    local idx = W.optMap[i]
    if idx == "more" then
        S.page = S.page + 1
        fillOptions()
        M.focus(W.opts[1])
        return
    end
    local it = type(idx) == "number" and S.items[idx] or nil
    if it then
        S.previewed = idx
        U.try(TAG, it.preview)
        U.try(TAG, it.choose)
    end
end

local PREV = { planet = "class", track = "planet", cond = "track", vehicles = "mode" }

function M.back()
    if not S.active then return end
    if S.step == "class" then M.close("back"); return end
    local prev = PREV[S.step]
    if S.step == "mode" then
        prev = (S.track and #S.track.conds > 1 and opt("SetupAskCondition", true) ~= false) and "cond" or "track"
    end
    M.showStep(prev or "class")
end

---------------------------------------------------------------------------------------------------- choice output
-- The race choice consumed by launch.start (same fields as builder.capture) + c.setup:
--   {classKey, arch, modeKey, single, grid ("max"|"native"), maxRacers, flow ("cards" | "classic"),
--    players = {[pnum] = {presetId, buildPath}}}
-- 0.10.0 cards flow: c.build = the class's launch base (perkapply.launchBase: VBD_000_1Mastiff / _Plane, with
-- PerkLaunchBase "pilot" P1's style build) and players = racers.choicePlayers(): {[pnum] = {ctrlId, pilotId, presetId,
-- buildPath (the base build, for LastRaceVehicles), loadout, code}}.
function M.makeChoice()
    if not (S.cls and S.planet and S.track and S.mode) then return nil, "CHOOSE CLASS, PLANET, TRACK AND MODE" end
    local b = S.builds[(S.players[1] or {}).build or 1]
    local build, players = nil, nil
    if S.cards then
        local okP, r = U.try(TAG, function() return racers().choicePlayers() end)
        players = (okP and type(r) == "table") and r or {}
        local p1 = players[1]
        local okB, base = U.try(TAG, function()
            return U.mod("perkapply").launchBase(S.cls.arch, p1 and p1.pilotId or nil)
        end)
        if okB and U.ok(base) then
            build = base
        else
            U.warn(TAG, "RACERS: no launch base build for %s: the class's first build is used", tostring(S.cls.key))
        end
    end
    local c = { archetype = V.archetypeObj(S.cls), gameMode = U.obj(S.mode.path), planet = U.obj(S.planet.path),
                track = S.track.obj, build = build or V.buildObj(b), debugBuild = nil, condition = S.cond or "" }
    if not U.ok(c.gameMode) then c.gameMode = nil end
    if not U.ok(c.planet) then c.planet = nil end
    local builder = U.mod("builder")
    if not builder.isValid(c) then return nil, "RACE INCOMPLETE (CLASS, MODE, TRACK OR BUILD NOT FOUND)" end
    c.setup = { classKey = S.cls.key, arch = S.cls.arch, modeKey = S.mode.key, single = S.mode.single,
                grid = S.mode.grid, maxRacers = S.grid, flow = S.cards and "cards" or "classic", players = {} }
    if S.cards then
        c.setup.players = players
    else
        for _, e in ipairs(S.order or localPlayers()) do
            local p = S.players[e.pnum]
            if p and p.arch == S.cls.arch then
                local pr, pb = V.presets(S.cls.arch)[p.preset], S.builds[p.build]
                c.setup.players[e.pnum] = { presetId = pr and pr.id or nil, buildPath = pb and pb.path or nil }
            end
        end
    end
    c.label = builder.describe(c)
    return c
end

-- Optional settings keys (config.lua cfg.Defaults must define them; without a default they are simply not saved).
local KEY_GRID, KEY_VEH, KEY_RACERS = "LastRaceMaxRacers", "LastRaceVehicles", "LastRaceRacers"

function M.persistExtras(c)
    if type(c) ~= "table" or type(c.setup) ~= "table" then return end
    if settings.get(KEY_GRID) ~= nil then settings.set(KEY_GRID, math.floor(tonumber(c.setup.maxRacers) or 0)) end
    if settings.get(KEY_VEH) ~= nil then
        local parts = {}
        for pnum = 1, 4 do
            local p = c.setup.players[pnum]
            if p and p.presetId then parts[#parts + 1] = string.format("%d=%s@%s", pnum, p.presetId, p.buildPath or "") end
        end
        settings.set(KEY_VEH, table.concat(parts, ";"))
    end
    -- 0.10.0 cards flow: every pad's pilot, vehicle and loadout by ControllerId (LastRaceRacers, racers.persist)
    if c.setup.flow == "cards" then U.try(TAG, function() racers().persist(c) end) end
end

-- 0.10.0: is build what a cards race persists as its build (LastRaceBuild) for class arch? The class's zero base, or
-- with cfg.PerkLaunchBase "pilot" one of the Instant Action style builds (perkdata STYLES[].build).
local function cardsBase(build, arch)
    local path = U.pathOf(build)
    if path == "" then return false end
    local okB, base = pcall(function() return U.mod("perkapply").basePath(arch) end)
    if okB and path == base then return true end
    if opt("PerkLaunchBase", "zero") == "pilot" then
        local okD, D = pcall(U.mod, "perkdata")
        if okD and type(D) == "table" and type(D.STYLES) == "table" then
            for _, st in pairs(D.STYLES) do
                if st.build == path then return true end
            end
        end
    end
    return false
end

-- 0.10.0: s.flow = "cards" and s.players from LastRaceRacers (§7.1: per ControllerId) for the pads present now (P1 =
-- ControllerId 0, the joined guests in view order) when the cards flow is on, the key is not empty and the choice
-- launches on a cards base build. Entries are class-checked (pilot, preset); the loadout code is decoded and validated
-- where it is used (racers.restore, perkapply). A pad without an entry gets no pick (launch: a fresh card's defaults).
-- V-RC-25: quit + relaunch, the lobby's START RACE replays every pad's picks.
local function racersFromSettings(s, c, cls)
    if opt("SetupPlayerFlow", "cards") ~= "cards" then return end
    local text = settings.get(KEY_RACERS)
    if type(text) ~= "string" or text == "" or not cardsBase(c.build, cls.arch) then return end
    local okP, entries = pcall(function() return racers().parseRacers(text) end)
    if not okP or type(entries) ~= "table" then return end
    local okL, Pm = pcall(U.mod, "pilots")
    local base, players = U.pathOf(c.build), {}
    for _, e in ipairs(localPlayers()) do
        local r = entries[e.ctrlId]
        if r then
            local pilot = r.pilot
            if pilot and not (okL and Pm.allowed(pilot, cls.arch)) then pilot = nil end
            local preset = (r.preset and V.presetById(cls.arch, r.preset)) and r.preset or nil
            players[e.pnum] = { ctrlId = e.ctrlId, pilotId = pilot, presetId = preset, buildPath = base, code = r.code }
        end
    end
    s.flow, s.players = "cards", players
end

-- c.setup for a choice made elsewhere (dev panel, settings.txt): mode/class from the objects, grid = class limit,
-- per-player vehicles from settings.txt when the class matches. Never fails (fields may stay nil).
function M.deriveSetup(c)
    local s = { players = {} }
    pcall(function() s.arch = tonumber(c.archetype.Archetype) end)
    local cls = V.classByArch(s.arch)
    s.classKey = cls and cls.key or nil
    local m = M.modeByPath(U.pathOf(c.gameMode))
    s.modeKey = m and m.key or nil
    s.single = m and m.single or false
    s.grid = m and m.grid or "native"
    s.maxRacers = cls and V.maxRacers(cls) or nil
    local g = settings.get(KEY_GRID)
    if type(g) == "number" and g > 0 and s.maxRacers then s.maxRacers = math.min(g, s.maxRacers) end
    local veh = settings.get(KEY_VEH)
    if type(veh) == "string" and cls then
        for pnum, id, path in veh:gmatch("(%d)=([%w_]+)@([^;]*)") do
            if V.presetById(cls.arch, id) then
                s.players[tonumber(pnum)] = { presetId = id, buildPath = path ~= "" and path or nil }
            end
        end
    end
    if cls then                                            -- 0.10.0: a cards race's picks replace the columns' ones
        local okR, err = pcall(racersFromSettings, s, c, cls)
        if not okR then
            U.warn(TAG, "LastRaceRacers not usable (%s): the race replays without the RACERS picks", tostring(err))
        end
    end
    return s
end

---------------------------------------------------------------------------------------------------- open / close
-- Pre-select the current race so A, A, A, A, A replays it.
local function preselect()
    local c = St.race.choice
    if type(c) ~= "table" then return end
    pcall(function()
        local cls = V.classByArch(tonumber(c.archetype.Archetype))
        if cls then S.cls = cls end
        S.planet = M.planetFor(c.planet) or S.planet
        S.cond = c.condition or ""
        S.mode = M.modeByPath(U.pathOf(c.gameMode)) or S.mode
        local s = c.setup or M.deriveSetup(c)
        if s.maxRacers then S.grid = s.maxRacers; S.gridTouched = true end
        if S.cls then
            local mem = S.pickMemory[S.cls.arch] or {}
            S.pickMemory[S.cls.arch] = mem
            for pnum, p in pairs(s.players or {}) do mem[pnum] = { presetId = p.presetId, buildPath = p.buildPath } end
            if U.ok(c.build) then                              -- P1's build is the launch build
                mem[1] = mem[1] or {}
                mem[1].buildPath = mem[1].buildPath or U.pathOf(c.build)
            end
        end
        -- 0.10.0: the RACERS cards' session memory (pilot, preset, loadout per ControllerId) from the same race
        if cardsReady() then U.try(TAG, function() racers().restore(s) end) end
        if S.cls and S.planet then
            for _, e in ipairs(queryTracks(S.cls, S.planet) or {}) do
                local hit = U.key(e.obj) ~= 0 and U.key(e.obj) == U.key(c.track)
                for _, a in ipairs(e.alts or {}) do
                    hit = hit or (U.key(a.obj) ~= 0 and U.key(a.obj) == U.key(c.track))
                end
                if hit then S.track = e; S.tracks = queryTracks(S.cls, S.planet) end
            end
        end
    end)
end

function M.isActive() return S.active == true and W ~= nil end

-- The setup widget P1's CommonUI focus is on (or should return to), for join.lua's GameAndUI focus target. RACERS:
-- P1's input sink.
function M.focusTarget()
    if not M.isActive() then return nil end
    if cardsStep() then
        local ok, t = pcall(function() return racers().sink() end)
        if ok and U.ok(t) then return t end
    end
    if U.ok(S.lastFocus) then return S.lastFocus end
    if U.ok(S.focusTarget) then return S.focusTarget end
    return nil
end

function M.open()
    if not M.available() then return false end
    if St.phase ~= "FRONTEND" then status("RACE SETUP ONLY WORKS IN THE MAIN MENU"); return false end
    if St.launch.pending then status("LAUNCHING…"); return false end
    if S.choiceSeen ~= St.race.choice then preselect(); S.choiceSeen = St.race.choice end
    S.active = true
    S.players = {}
    local lobby = U.mod("lobby")
    if type(lobby.setSetupMode) == "function" then lobby.setSetupMode(true) end
    show(W.panel, true)
    setText(W.status, "")
    M.showStep("class")
    U.log(TAG, "race setup opened")
    return true
end

function M.close(why)
    if not S.active then return end
    S.active = false
    M.stopVideo(why)
    racersLeave(why)                                         -- 0.10.0: the visit ends (cards' images, then their bays)
    releasePreviews(why)                                     -- SAVE / START RACE / BACK / tab left / phase change
    if CM then pcall(CM.setView, nil) end
    if W then show(W.panel, false) end
    local lobby = U.mod("lobby")
    if type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, false) end
    U.log(TAG, "race setup closed (%s)", tostring(why))
end

-- The START gate's warning: "P2, P3 NOT READY: START AGAIN TO RACE ANYWAY", "PAD 3 IS NOT JOINED: START AGAIN FOR AN
-- AI CAR", or both.
local function gateText(waiting, dormant)
    local what = {}
    if #waiting > 0 then what[#what + 1] = table.concat(waiting, ", ") .. " NOT READY" end
    if dormant then what[#what + 1] = dormant end
    local tail = "START AGAIN TO RACE ANYWAY"
    if #waiting == 0 then tail = dormant:find("^PADS ") and "START AGAIN FOR AI CARS" or "START AGAIN FOR AN AI CAR" end
    return table.concat(what, " · ") .. ": " .. tail
end

-- SAVE (start=false) or START RACE (start=true). START gates, one 5 s window of real time (kept from 0.9.x): every
-- joined guest READY (RACERS: on the READY stage, racers.readyState; classic: the READY toggle) and, 0.10.0 RC-1, no
-- connected pad left un-joined (join.dormantText), checked here before the page closes: launch.start would refuse the
-- first START after the setup closed and drop everybody into the lobby. A second START inside the window (the same
-- un-joined pads) races anyway: launch.start({acceptDormant = true}) skips its own refusal and parks those pads (an AI
-- car in their view). VERIFY(V-RC-18, V-RC-35)
function M.finish(start)
    if not S.active or S.step ~= "vehicles" then return end
    local acceptDormant = false
    if start then
        local now, waiting = M.realMs(), {}
        if cardsStep() then
            local ok, _, w = U.try(TAG, function() return racers().readyState() end)
            if ok and type(w) == "table" then waiting = w end
        else
            for i = 2, #(S.order or {}) do
                local p = S.players[S.order[i].pnum]
                if p and not p.ready then waiting[#waiting + 1] = "P" .. p.pnum end
            end
        end
        local dormant = nil
        pcall(function() dormant = U.mod("join").dormantText() end)
        local again = now <= S.startConfirmUntil and (dormant == nil or dormant == S.startDormant)
        if (#waiting > 0 or dormant) and not again then
            S.startConfirmUntil, S.startDormant = now + 5000, dormant
            status(gateText(waiting, dormant))
            return
        end
        acceptDormant = dormant ~= nil
    end
    local c, why = M.makeChoice()
    if not c then status(why); return end
    U.mod("builder").adoptExternal(c, "race setup")
    M.persistExtras(c)
    local parts = {}
    for pnum, p in pairs(c.setup.players) do
        local s = string.format("P%d=%s", pnum, tostring(p.presetId))
        if p.ctrlId ~= nil then                            -- RACERS: ControllerId, pilot and kit too
            s = s .. string.format("(c%s %s kit %s)", tostring(p.ctrlId), tostring(p.pilotId),
                tostring(type(p.loadout) == "table" and p.loadout.kit or "?"))
        end
        parts[#parts + 1] = s
    end
    table.sort(parts)
    U.log(TAG, "race set: %s | grid %s (%s) | %s | %s", c.label, tostring(c.setup.maxRacers), tostring(c.setup.grid),
        tostring(c.setup.flow), table.concat(parts, " "))
    M.close(start and "start" or "save")
    if start then U.mod("launch").start({ acceptDormant = acceptDormant }) end
end

function M.setStatus(text)
    if W and S.active then setText(W.status, text or "") end
end

---------------------------------------------------------------------------------------------------- input
-- P1's focus: HasUserFocusedDescendants(P1) is the check that matched in the 2026-10-07 run (ui.lua V-LOB-08);
-- ui.hasFocus (4 checks) is the fallback when that call errors.
local function holds(w, p1)
    if not U.ok(w) then return false end
    local ok, v = pcall(function() return w:HasUserFocusedDescendants(p1) end)
    if ok then return v == true end
    return ui().hasFocus(w, p1)
end

local function visibleFocusables()
    local out = {}
    if S.view == "cmap" and CM then                          -- 0.9.0: chips / map nodes of the shown view + BACK
        for _, w in ipairs(CM.focusables()) do out[#out + 1] = w end
        out[#out + 1] = W.back
        return out
    end
    for _, w in ipairs(W.focusables) do
        local ok, vis = pcall(function() return w:IsVisible() end)        -- UWidget::IsVisible() -> Bool
        if not ok or vis == true then out[#out + 1] = w end
    end
    return out
end

local scanAt = 0
local function focusedWidget(p1)
    if S.lastFocus and holds(S.lastFocus, p1) then return S.lastFocus end
    local now = M.realMs()
    if now < scanAt then return S.lastFocus end           -- throttled full scan (focus is moving or lost)
    scanAt = now + 90
    for _, w in ipairs(visibleFocusables()) do
        if holds(w, p1) then return w end
    end
    return nil
end

-- CommonInputSubsystem of P1 (gamepad vs mouse+keyboard). nil -> treated as gamepad.
local cis = nil
local function gamepadInput()
    if not U.ok(cis) then
        cis = nil
        pcall(function()
            local cls = U.class("/Script/CommonInput.CommonInputSubsystem")
            local o = U.SBL():GetLocalPlayerSubSystemFromPlayerController(U.p1(), cls)
            if U.ok(o) then cis = o end
        end)
        if not cis then return true end
    end
    local ok, t = pcall(function() return cis:GetCurrentInputType() end)  -- 0 MouseAndKeyboard, 1 Gamepad
    if not ok then return true end
    return tonumber(t) ~= 0
end

-- 0.10.0 (racers.lua): P1 uses a pad (true also when unknown); a move of P1's sink focus is a direction only then.
function M.p1Gamepad() return gamepadInput() end

local function cyclerOf(w)
    for id, cy in pairs(W.cyclers) do
        if U.same(w, cy.l) then return cy, -1 end
        if U.same(w, cy.r) then return cy, 1 end
        if U.same(w, cy.m) then return cy, 0 end
    end
    return nil, nil
end

local function onFocus(f)
    S.lastFocus = f
    if not f then return end
    if S.view == "cmap" and CM then                          -- 0.9.0: a planet chip / circuit node took the focus
        local idx = CM.itemFor(f)
        if idx then
            if idx ~= S.previewed and S.items[idx] then
                S.previewed = idx
                U.try(TAG, S.items[idx].preview)
            end
            return
        end
    end
    for i, w in ipairs(W.opts) do
        if U.same(w, f) then
            local idx = W.optMap and W.optMap[i]
            if type(idx) == "number" and idx ~= S.previewed and S.items[idx] then
                S.previewed = idx
                U.try(TAG, S.items[idx].preview)
            end
            return
        end
    end
    local cy, dir = cyclerOf(f)
    if cy and dir ~= 0 then
        -- focus trap: d-pad left/right moved the focus onto an arrow. Mouse hover and the keyboard (lobby.onKey
        -- steps itself) only get the focus put back.  VERIFY(V-SET-03)
        if gamepadInput() and M.realMs() - S.kbStepAt > 300 then M.cyclerStep(cy.id, dir, "pad") end
        ui().focus(cy.m, U.p1())
        S.lastFocus = cy.m
    end
end

local PADK = {
    up = { "Gamepad_DPad_Up", "Gamepad_LeftStick_Up" }, down = { "Gamepad_DPad_Down", "Gamepad_LeftStick_Down" },
    left = { "Gamepad_DPad_Left", "Gamepad_LeftStick_Left" }, right = { "Gamepad_DPad_Right", "Gamepad_LeftStick_Right" },
    a = { C.KEY.A }, b = { C.KEY.B },
}

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

-- Guests' own pads in the VEHICLES step: up/down = row (model / build), left/right = change (held: repeats),
-- A = ready toggle, B = un-ready / back to the model row. Leaving the session needs B HELD (join.lua, while this
-- step is open: M.guestBHoldsToLeave) so a quick B never drops the guest.  VERIFY(V-SET-04)
local function pollGuests()
    local now, changed = M.realMs(), false
    local delay = tonumber(opt("LobbyNavRepeatDelayMs", 400)) or 400
    local rep = tonumber(opt("LobbyNavRepeatMs", 140)) or 140
    for i = 2, #(S.order or {}) do
        local e = S.order[i]
        local p = S.players[e.pnum]
        if p and U.ok(e.pc) then
            local st = readPad(e.pc)
            local n = p.nav
            if not n.primed then
                n.primed, n.prev, n.hdir, n.nextMs = true, st, 0, now + delay  -- baseline: the join press is no edge
            else
                if st.a and not n.prev.a then p.ready = not p.ready; changed = true end
                if st.b and not n.prev.b then
                    if p.ready then p.ready = false elseif p.row == 2 then p.row = 1 end
                    changed = true
                end
                if not p.ready then
                    if (st.up and not n.prev.up) or (st.down and not n.prev.down) then
                        p.row = (p.row == 1) and 2 or 1; changed = true
                    end
                    local h = (st.left and not st.right) and -1 or ((st.right and not st.left) and 1 or 0)
                    local step = 0
                    if h == 0 then n.hdir = 0
                    elseif h ~= n.hdir then n.hdir, n.nextMs, step = h, now + delay, h
                    elseif now >= n.nextMs then n.nextMs, step = now + rep, h end
                    if step ~= 0 then
                        M.stepPlayer(e.pnum, p.row == 1 and "preset" or "build", step)
                        changed = false                    -- stepPlayer rendered already
                    end
                end
                n.prev = st
            end
        end
    end
    if changed then renderColumns() end
end

-- join.lua: while the VEHICLES step is open a guest leaves only by HOLDING B (a quick B = un-ready / row back).
function M.guestBHoldsToLeave()
    return M.isActive() and S.step == "vehicles"
end

-- P1's pad B = one step back (the setup's own PADK had no B: B only reached the game's main-menu Back). Not with
-- KeyboardIsP1: pad 0's B then belongs to a guest (it arrives on P1's PC); P1 uses Backspace (onKey "back2").
-- 0.10.0 RACERS: P1's back on the card (racers.onP1Back: the stage before; at the first stage the double-back rule).
local p1BPrev = false
local function pollP1Back(p1)
    local down = ui().keyDown(p1, C.KEY.B)
    local kbp1 = false
    pcall(function() kbp1 = require("settings").get("KeyboardIsP1") == true end)
    if down and not p1BPrev and not kbp1 then
        pcall(function() U.mod("lobby").armBackGuard() end)   -- the game may also open its Back prompt
        if cardsStep() then racers().onP1Back() else M.back() end
    end
    p1BPrev = down
end

-- FAST loop (lobby.pollNav while the setup is active and the lobby is not covered).
function M.pollNav()
    if not M.isActive() then p1BPrev = false; return end
    if S.cmapRetry then                                      -- 0.9.0: a campaign view failed: its step as a list
        local st = S.cmapRetry
        S.cmapRetry = nil
        if S.step == st then U.try(TAG, M.showStep, st) end
    end
    if S.view == "cmap" and CM then U.tryEvery("setup.cmap", nil, TAG, CM.tick) end
    if video.pending then U.try(TAG, M.videoTick) end
    local p1 = U.p1()
    if cardsStep() then
        -- 0.10.0 RACERS: racers.poll replaces the focus poll, the guests' columns and the preview tick (guests' pads,
        -- P1's sink and accept, timers, previews, renders, the status line); P1's B stays a source, read first so its
        -- edge state is current on every tick of the step
        if U.ok(p1) then U.try(TAG, pollP1Back, p1) end
        if cardsStep() then U.tryEvery("setup.racers", nil, TAG, function() racers().poll(p1) end) end
        return
    end
    if U.ok(p1) then
        local f = focusedWidget(p1)
        if f ~= S.lastFocus then onFocus(f) end
        U.try(TAG, pollP1Back, p1)
    end
    if M.isActive() and S.step == "vehicles" then
        U.try(TAG, pollGuests)
        -- 3D previews: debounced builds, readiness, turntable, captures; a column re-renders when its state changed
        if VP then
            local ok, changed = U.tryEvery("setup.preview", nil, TAG, VP.tick)
            if ok and changed and M.isActive() and S.step == "vehicles" then U.try(TAG, renderColumns) end
        end
    end
end

-- FAST loop (lobby.keepFocus): re-give P1's focus for a moment after each step change. RACERS: racers keeps P1's
-- focus on the sink for the whole step while P1 uses a pad.
function M.keepFocus()
    if not M.isActive() then return end
    if cardsStep() then U.tryEvery("setup.racers.keep", nil, TAG, function() racers().keepFocus() end); return end
    local now = M.realMs()
    if now > S.keepUntil or now < S.keepNext then return end
    S.keepNext = now + 200
    local p1 = U.p1()
    if focusedWidget(p1) then return end
    if U.ok(S.focusTarget) then ui().focus(S.focusTarget, p1) end
end

-- Keyboard (lobby.onKey through UE4SS keybinds): left/right step the focused value row, Backspace = BACK. RACERS:
-- every key is P1's on the card (racers.onKey: arrows, Enter / Space, Backspace).
function M.onKey(name)
    if not M.isActive() then return end
    if cardsStep() then U.try(TAG, function() racers().onKey(name) end); return end
    if name == "back2" then M.back(); return end
    local p1 = U.p1()
    local f = S.lastFocus or focusedWidget(p1)
    if name == "left" or name == "right" then
        local cy = cyclerOf(f)
        if cy then
            S.kbStepAt = M.realMs()
            M.cyclerStep(cy.id, name == "left" and -1 or 1, "keyboard")
            ui().focus(cy.m, p1)
        end
        return
    end
    if not focusedWidget(p1) and U.ok(S.focusTarget) then ui().focus(S.focusTarget, p1) end
end

-- lobby.onPageShown("lobby") (the page came back, e.g. from Settings): the step's focus again. RACERS: every card's
-- render caches cleared (a Slate rebuild may reset what a Blueprint applied, V-RC-06), a still burst for the still
-- previews, the focus on the sink.
function M.onPageShown()
    if not M.isActive() then return end
    if cardsStep() then
        local ok, t = U.try(TAG, function() return racers().onPageShown() end)
        if ok and U.ok(t) then M.focus(t) end
        return
    end
    if U.ok(S.focusTarget) then M.focus(S.focusTarget) end
end

-- Players joined / left while the VEHICLES step is open (RACERS: a joiner's card at the first stage, a leaver's card
-- and bay go, its picks stay in memory).
function M.onPlayers()
    if not (M.isActive() and S.step == "vehicles") then return end
    if cardsStep() then U.try(TAG, function() racers().onPlayers() end) else U.try(TAG, renderColumns) end
end

-- Test helper (test.cmd lua, only with cfg.TestCommands; vehicle-step-v2.md §10): a fresh setup visit straight to a
-- step with these picks. spec = {class = vehicles.CLASSES key ("Car" default, "Bike", "Skimmer", "Plane"), planet =
-- PLANETS key ("Mastiff" default = JAKKU, "Beagle" = TATOOINE, ...), track = TrackDef key (default: the planet's
-- first track for the class), mode = MODES key ("race" default, "fullgrid", "mixed", "eliminator"), step = the step
-- to show ("vehicles" default)}. The track's default condition and the class's full grid are taken. -> summary text.
-- Example: lua return require("setup").debugJump{class = "Car", planet = "Mastiff", step = "vehicles"}
function M.debugJump(spec)
    if cfg.TestCommands ~= true then return "debugJump: needs cfg.TestCommands = true" end
    spec = type(spec) == "table" and spec or {}
    local cls = V.classByKey(spec.class or "Car")
    if not cls then return "debugJump: unknown class " .. tostring(spec.class) end
    local planet = nil
    for _, p in ipairs(PLANETS) do
        if p.key == (spec.planet or "Mastiff") then planet = p end
    end
    if not planet then return "debugJump: unknown planet " .. tostring(spec.planet) end
    local step = spec.step or "vehicles"
    if not STEPS[step] and step ~= "vehicles" then return "debugJump: unknown step " .. tostring(step) end
    if M.isActive() then M.close("debug jump") end            -- a new visit: every card starts at its first stage
    if not M.open() then
        return string.format("debugJump: the setup did not open (page %s, phase %s, launch pending %s)",
            M.available() and "ok" or "unavailable", tostring(St.phase), tostring(St.launch.pending))
    end
    local tracks = queryTracks(cls, planet)
    if not tracks or #tracks == 0 then
        return string.format("debugJump: no track for %s on %s (setup open on CLASS)", cls.key, planet.key)
    end
    local track = tracks[1]
    if spec.track then
        track = nil
        for _, e in ipairs(tracks) do
            if e.key == spec.track then track = e end
            for _, a in ipairs(e.alts or {}) do
                if a.key == spec.track then track = e end
            end
        end
        if not track then return "debugJump: track " .. tostring(spec.track) .. " not offered (setup open on CLASS)" end
    end
    local mode = M.modeByKey(spec.mode or "race")
    local fits = false
    for _, m in ipairs(modesFor(cls, track)) do
        if m == mode then fits = true end
    end
    if not fits then
        return "debugJump: mode " .. tostring(spec.mode or "race") .. " not offered (setup open on CLASS)"
    end
    S.cls, S.planet, S.tracks, S.track, S.mode = cls, planet, tracks, track, mode
    S.cond = track.conds[1] or ""
    S.gridTouched = false
    S.grid = math.max(humansCount(), V.maxRacers(cls))
    M.showStep(step)
    return string.format("debugJump: %s / %s / %s%s / %s -> step %s%s (%s)", cls.key, planet.key, tostring(track.key),
        S.cond ~= "" and (" [" .. S.cond .. "]") or "", mode.key, tostring(S.step),
        S.step == "vehicles" and (S.cards and " RACERS" or " classic") or "", tostring(St.menu.visible))
end

return M
