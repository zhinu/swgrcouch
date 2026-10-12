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
-- 0.12.0 UI v2 (WI-05; binding spec notes/design/ui-v2/ui-redesign-final.md §6, §7.1, §7.4, §7.5, §8; user 2026-10-10:
-- screens that "look like they belong to the game"): with cfg.UiStyle ~= "classic" (read at page build) W.panel is ONE
-- FuseCanvasPanel (VerticalBoxSlot Size Fill in the lobby root) and every part sits on it in screen su through
-- theme.pageGeometry: the hub / map page backgrounds, "/RACE SETUP" (WBP_Screen_Title), the step row in the game's tab
-- style, the command row BACK / START RACE / SAVE AND RETURN (START and SAVE only on RACERS with P1 in mouse + keyboard
-- mode, theme.inputMode), the status pill (§6.5 priorities), poster views for CLASS (Arcade posters + the VEHICLE
-- SELECT info panel), CONDITIONS (tinted posters, facts only) and MODE (4 strips, detail column, GRID row, grid strip),
-- the settings-look list fallback, the card row at (128, 548) and P1's sink host at (1800, cmdY). PLANET / TRACK stay
-- cmap.lua's (its ctx gains place(widget, rect), ghost(...) and geo). Every focus target is a ghost (ui.ghost) under a
-- painted look. S.items / M.onOption / M.onItem / the START gate / the input routes are unchanged; "classic" builds and
-- runs the 0.11.0 page exactly as before (buildWidgets, showStep, the lists). New API: setup.raceArt(choice),
-- setup.arcadeTile(planet, cls), setup.commandFocus(id), setup.debugInputMode(mode), setup.setStatus(text[, opts]),
-- setup.clearStatus(key), setup.onPoster(i). VERIFY ids V-FIN-01..16 (§14) on the log lines a live tester needs.
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

-- 0.12.0: the UI v2 page (theme.lua) unless cfg.UiStyle = "classic"; read when a page is built (M.build, M.open).
local function wantV2() return opt("UiStyle", "v2") ~= "classic" end

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

-- 0.12.0 (§7.2): the Arcade event tiles T_UI_Arcade_<Pl>_<Class>_Tile the game ships (notes/asset-list.txt). A pair it
-- does not ship takes the planet's own class (Hus -> Car, Spa -> Bike, Bgl -> Plane), so the planet hue stays.
local ARCADE_TILES = {
    Mas = { Car = true, Bike = true, Skimmer = true, Plane = true },
    Dal = { Car = true, Bike = true, Skimmer = true, Plane = true },
    Cor = { Car = true, Bike = true, Skimmer = true, Plane = true },
    Whp = { Car = true, Bike = true, Skimmer = true, Plane = true },
    Hus = { Car = true }, Spa = { Bike = true, Plane = true }, Bgl = { Plane = true },
}
local ARCADE_TILE_OWN = { Hus = "Car", Spa = "Bike", Bgl = "Plane" }

-- PLANETS entry for an entry, a key ("Mastiff"), a PlanetDef name ("PLA_Mastiff") or a display name ("JAKKU").
local function planetEntry(p)
    if type(p) == "table" then
        if p.art and p.key then return p end
        p = p.key
    end
    if type(p) ~= "string" then return nil end
    local k, up = p:gsub("^PLA_", ""), string.upper(p)
    for _, e in ipairs(PLANETS) do
        if e.key == k or e.name == up then return e end
    end
    return nil
end

-- vehicles.CLASSES entry for an entry or a key ("Car").
local function classEntry(c)
    if type(c) == "table" then
        if c.art then return c end
        c = c.key
    end
    if type(c) ~= "string" then return nil end
    return V.classByKey(c)
end

-- setup.arcadeTile(planet, cls) -> the planet x class Arcade tile (the class's own art when the pair exists, else the
-- planet's own class); planet / cls as entries or keys; cls nil = the landspeeder. nil for an unknown planet.
function M.arcadeTile(planet, cls)
    local p, c = planetEntry(planet), classEntry(cls)
    if not p then return nil end
    local pl, k = p.art, c and c.art or "Car"
    if not (ARCADE_TILES[pl] or {})[k] then k = ARCADE_TILE_OWN[pl] or "Car" end
    return tp("Arcade", "T_UI_Arcade_" .. pl .. "_" .. k .. "_Tile")
end

-- true when the pair has its own tile (the CLASS posters keep their class art otherwise).
local function ownArcadeTile(p, c)
    return p ~= nil and c ~= nil and (ARCADE_TILES[p.art] or {})[c.art] == true
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

-- 0.12.0 UI v2 (§7.5): the MODE strips' art (none of it is on a main-menu tab; RACE = the chosen class's strip) and
-- title ink, and the sentence-case mode texts of the detail column (the caps desc above stays for "classic").
local MODE_V2 = {
    race       = { art = { Car = "T_UI_FE_Tile_05", Bike = "T_UI_FE_Tile_05_Bike", Skimmer = "T_UI_FE_Tile_05_Skim",
                           Plane = "T_UI_FE_Tile_05_Plane" }, ink = "BEIGE",
                   text = function(cls) return "A single-class race: the whole grid drives the <H1>"
                       .. string.lower(cls and cls.label or "chosen class") .. "</>." end },
    fullgrid   = { art = "T_UI_Difficulty_Tile_01", ink = "DEEP", scrim = "#93A495",   -- scrim: the art's base, idle
                   text = "The game's own full-grid race. The game sets the grid." },
    mixed      = { art = "T_UI_Difficulty_Tile_02", ink = "DEEP", scrim = "#B9924B",
                   text = "4 landspeeders, 4 speeder bikes and 4 skim speeders." },
    eliminator = { art = "T_UI_FE_Tile_MP_06", ink = "BEIGE",
                   text = "Timed elimination with mixed classes, 12 racers." },
}

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

-- 0.12.0: v2 = the UI v2 page's functions (filled in the "UI v2" section below; the classic code calls them only on a
-- v2 page). pillFeed = the v2 status pill (a no-op on a classic page or while the setup is closed).
local v2 = {}
local pillFeed = function() end
local TH = nil
local function T()                                         -- theme.lua (G3, lazy: only a v2 page needs it)
    if TH == nil then TH = U.mod("theme") end
    return TH
end

-- o (0.12.0, v2 page only): the status pill variant {warn, sticky, prio, key, ms, pips}; nil = classified by its text.
local function status(text, o)
    U.log(TAG, "%s", text)
    pillFeed(text, o)
    St.emit("status", text)
end

local function ui() return U.mod("ui") end
local function racers() return U.mod("racers") end         -- 0.10.0 RACERS step (lazy: G3 like this file)
local function quickM() return U.mod("quick") end           -- 0.13.0 QUICK RACE (PlayMode, the difficulty names)

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

-- 0.12.0 sentence case for the v2 texts: "DEBRIS DUNES" -> "Debris Dunes", "LOOP B · SHORT 2" -> "loop B · short 2"
-- (single letters and roman numerals keep their case).
local ROMAN = { I = true, II = true, III = true, IV = true, V = true, VI = true, VII = true, VIII = true }
local function keepCase(w) return #w <= 1 or ROMAN[w] == true or w:find("%d") ~= nil end
local function titleCase(s)
    return (tostring(s or ""):gsub("%S+", function(w)
        if keepCase(w) then return w end
        return w:sub(1, 1):upper() .. w:sub(2):lower()
    end))
end
local function lowerWords(s)
    return (tostring(s or ""):gsub("%S+", function(w)
        if keepCase(w) then return w end
        return w:lower()
    end))
end

---------------------------------------------------------------------------------------------------- state
-- W: widgets of the current lobby page instance (rebuilt with the page; forget() drops it). 0.10.0: cardBox / cardRow /
--    sinkHost (RACERS cards), cardsOk (racers.build succeeded), cardsBroken (this page keeps the classic columns).
-- S: the flow. players[pnum] = {pnum, ctrlId, pc, preset (index), build (index), ready, row (1 vehicle, 2 build),
--    nav = {edges/repeat state}} - P1 is pnum 1 (CommonUI focus), guests come from join.joinedList(). These are the
--    classic columns; in the cards flow racers.lua keeps the players (St.racers). cards: the shown step 5 is RACERS;
--    startDormant: the un-joined pads the START window was armed for (RC-1).
-- 0.12.0 v2 page (W.v2): W.panel = the page canvas; root, geo (theme.pageGeometry at build), tctx (theme ctx), bg
--    {hub, map}, title, steps, cmd (command row; back / start / save = its ghosts), pill, views[class|cond|mode|list]
--    (built the first time a step needs them), viewBroken, posters (4 shared poster ghosts) + posterMap, rows (the
--    list's settings rows; opts = their ghosts), shift (render translation when the page moved after the build).
--    S.view: "posters" (CLASS / CONDITIONS / MODE), "cmap" (PLANET / TRACK), "list" (fallback), "cards" (RACERS).
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
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }   -- 0.12.0 v2 page
local TEXT  = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }
local RICH  = { "/Script/Griffin.FuseRichTextBlock", "/Script/UMG.RichTextBlock" }

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
    -- 0.12.0 v2: pill = the page's theme status pill (racers posts its keyed join / ALL READY entries there, §6.5)
    local r = racers().build({ tree = W.tree, pc = W.pc, newW = newW, row = W.cardRow, sinkHost = W.sinkHost,
                               realMs = M.realMs, footer = { W.back, W.save, W.start }, pill = W.pill })
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

-- One page build (M.build; 0.12.0 also M.open after a live UiStyle switch). v2 = cfg.UiStyle ~= "classic" now.
local function buildPage(root, pc, page)
    W = { pageKey = U.key(page), page = page, pc = pc, tree = page.WidgetTree, cyclers = {}, opts = {}, cols = {},
          focusables = {}, cardsOk = false, cardsBroken = false,
          v2 = wantV2(), root = root, views = {}, viewBroken = {}, rows = {} }
    textCache, imgCache = {}, {}
    M._resetVideoFlags()                                   -- address-keyed like the caches above (new page)
    local ok, err = pcall(W.v2 and v2.buildWidgets or buildWidgets, root)
    if not ok then
        W.broken = true
        U.err(TAG, "race setup page could not be built (%s): the lobby uses the dev race builder%s", tostring(err),
            W.v2 and " (UiStyle = \"classic\" builds the 0.11.0 page)" or "")
        if U.ok(W.panel) then show(W.panel, false) end
        return false
    end
    show(W.panel, false)
    U.log(TAG, "race setup page built (%s, %d option rows, %d focusable widgets, campaign views: %s, step 5: %s)",
        W.v2 and "UI v2" or "classic", #W.opts, #W.focusables, CM and CM.status() or "not loaded",
        W.cardsOk and "RACERS cards" or (cardsWanted() and "classic columns (cards unavailable)" or "classic columns"))
    return true
end

-- lobby.build: once per lobby page. false = the flow is unavailable (lobby falls back to the dev panel).
function M.build(root, pc, page)
    if W and W.pageKey == U.key(page) and U.ok(W.panel) then return not W.broken end
    return buildPage(root, pc, page)
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
        -- 0.12.0 v2 page (W.v2): the views go on the page canvas. place(widget, rect = {x, y[, w, h]} screen su, z,
        -- align) -> CanvasPanelSlot; ghost(id, fn, rect, cv) -> a theme ghost ("setup:" .. id) on cv (default the
        -- page canvas); back() -> the command row's BACK ghost (the lowest targets' Down rule); tctx = theme's ctx.
        v2 = W.v2 == true, geo = W.geo, tctx = W.tctx,
        place = function(w, rect, z, align) return v2.placeOn(W.panel, w, rect, z, align) end,
        ghost = function(id, fn, rect, cv)
            return T().ghost(W.tctx, cv or W.panel, rect, "setup:" .. id, fn, { geo = W.geo, z = 10 })
        end,
        back = function() return W.back end,
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
    if W.v2 then return v2.fillRows() end                  -- 0.12.0: the list as settings rows (same paging)
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
            cls = cls,                                     -- 0.12.0 v2: poster / list row data
            row = { titleCase(cls.label), string.format("UP TO %d RACERS", V.maxRacers(cls)) },
            preview = function()
                if W.v2 then v2.previewClass(cls); return end
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
            planet = p,                                    -- 0.12.0 v2: list row "Jakku" + "17 TRACKS"
            row = { titleCase(p.name), n and string.format("%d TRACK%s", n, n == 1 and "" or "S") or "" },
            preview = function()
                if S.view == "cmap" and CM then
                    local sep = W.v2 and " · " or "  ·  "   -- v2 (§7.2): "6 CIRCUITS · 17 TRACKS FOR THE LANDSPEEDER"
                    local count = n and string.format("%d CIRCUIT%s%s%d TRACK%s FOR THE %s", circuits,
                        circuits == 1 and "" or "S", sep, n, n == 1 and "" or "S", S.cls.label) or "TRACK LIST UNKNOWN"
                    local okC, err = pcall(CM.previewPlanet, idx, { planet = p, count = count, url = p.url,
                        art = W.v2 and M.arcadeTile(p, S.cls) or nil })
                    if not okC then cmapFailed("planet", err) end
                    return
                end
                if W.v2 then return end                    -- v2 list: the row is the preview
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
            track = e,                                     -- 0.12.0 v2: list row "Debris Dunes · reverse"
            row = { v2.trackRow and v2.trackRow(e) or trackLabel(e), "" },
            preview = function()
                if S.view == "cmap" and CM then
                    local okC, err = pcall(CM.previewTrack, idx, { e = e, planet = S.planet.name, cls = S.cls.label,
                        art = trackArt(e),
                        condNext = #(e.conds or {}) > 1 and opt("SetupAskCondition", true) ~= false })
                    if not okC then cmapFailed("track", err) end
                    return
                end
                if W.v2 then return end                    -- v2 list: the row is the preview
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
            tag = tag,                                     -- 0.12.0 v2: poster / list row data
            row = { titleCase(prettyCond(tag)), "" },
            preview = function()
                if W.v2 then v2.previewCond(tag); return end
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
            mode = m,                                      -- 0.12.0 v2: poster / list row data
            row = { titleCase(m.label), "" },
            preview = function()
                S.focusMode = m
                if W.v2 then v2.previewMode(m); return end
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
        local ok, b1, k1, d1, a1, base1 = U.try(TAG, VP.brush, i)
        if ok then brush, kind, dim, asp = b1, k1, d1, a1 end
        -- 0.12.0: a v2 bay (PreviewBackdrop studio / scenario) reports a building frame as kind "building" (the v2
        -- card washes it); these columns draw no wash: its real brush type at the 0.11.0 0.5 dim
        if kind == "building" then kind, dim = (base1 == "texture") and "texture" or "material", 0.5 end
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

-- 0.12.0 (task #31): RACE SETUP > MODE "Opponents" = the speeder build tier the race launches on, i.e. the AI's
-- strength, as the 0.9 classic VEHICLES build column set it (0.10's cards flow always launched on TIER 1, the zero
-- base). Persisted in settings OpponentTier (1 = TIER 1 [0%] .. 6 = TIER 6 [58%]); pods have no tier (the zero base).
-- M.aiTierIndex() -> index, list (nil, {} for pods); M.aiTierPath() -> the tier build's path, nil for TIER 1 / pods.
-- 0.13.0 QUICK RACE (quick.lua): the same setting is the friends' difficulty, ROOKIE .. LEGEND; pods step it too (a
-- list of 6 tiers without a build: the players' tier kits, the AI pods keep the zero base).
local POD_TIERS = {}
for i = 1, 6 do POD_TIERS[i] = { label = "TIER " .. i } end

local function quickOn()
    local ok, q = pcall(function() return quickM().isQuick() end)
    return ok and q == true
end

function M.isQuick() return quickOn() end

-- 0.13.0 CUSTOM: Opponents "MATCH THE PLAYERS" (settings OpponentMatch): the AI get the players' average build
-- (launch.aiLoadoutFor -> perkapply.matchLoadout), every class; the last value of the row, after TIER 6 (pods: after
-- Standard).
local function matchOn() return not quickOn() and settings.get("OpponentMatch") == true end
function M.isMatch() return matchOn() end
function M.quickTier()
    local ok, t = pcall(function() return quickM().quickTier() end)
    return (ok and tonumber(t)) or 1
end

local function tierIndexFor(arch)
    if arch ~= nil and tonumber(arch) == 1 and quickOn() then return M.quickTier(), POD_TIERS end
    if arch == nil or tonumber(arch) == 1 then return nil, {} end
    local ok, list = pcall(V.builds, arch)
    if not ok or type(list) ~= "table" or #list == 0 then return nil, {} end
    local i = math.floor(tonumber(settings.get("OpponentTier")) or 1)
    return math.max(1, math.min(#list, i)), list
end

function M.aiTierIndex() return tierIndexFor(S.cls and S.cls.arch) end

-- the tier build's path for class arch from the setting (nil: TIER 1 = the zero base, pods); the single source for a
-- choice made here (makeChoice) and for one derived from settings.txt (the lobby's START RACE, deriveSetup)
function M.aiTierPathFor(arch)
    local i, list = tierIndexFor(arch)
    if not i or i <= 1 or not list[i] then return nil end
    return list[i].path
end

function M.aiTierPath() return M.aiTierPathFor(S.cls and S.cls.arch) end

-- "TIER 3 · HUSKY (23%)" from the game's "03 - Husky [23%]"; pods: "Standard". QUICK RACE: the difficulty first,
-- "PRO · TIER 3 · HUSKY (23%)" (pods "PRO · TIER 3")
function M.aiTierText()
    if matchOn() then return "MATCH THE PLAYERS" end
    local i, list = M.aiTierIndex()
    if not i then return "Standard" end
    local b = list[i] or {}
    local n, name, pct = tostring(b.raw or ""):match("^%s*0?(%d+)%s*%-%s*(%a+)%s*%[([^%]]*)%]")
    local text = n and string.format("TIER %s · %s (%s)", n, string.upper(name), pct) or tostring(b.label or "TIER 1")
    if quickOn() then
        local okN, word = pcall(function() return quickM().name(i) end)
        if okN and word then text = word .. " · " .. text end
    end
    return text
end

function M.stepAiTier(dir)
    if S.step ~= "mode" then return end
    local i, list = M.aiTierIndex()
    if not quickOn() then
        -- CUSTOM: 1..#tiers (pods: Standard only) then MATCH
        local top = math.max(1, #list) + 1
        local cur = matchOn() and top or (i or 1)
        local j = math.max(1, math.min(top, cur + dir))
        if j ~= cur then
            settings.set("OpponentMatch", j == top)
            -- pods have no tier list (#list 0): "Standard" must not reset QUICK RACE's difficulty (review 2026-10-12)
            if j < top and #list > 0 then settings.set("OpponentTier", j) end
            U.log(TAG, "opponents: %s (V-RC-27)", M.aiTierText())
        end
        if W.v2 then v2.renderGrid(S.focusMode or S.mode) end
        return
    end
    if not i then return end
    local j = math.max(1, math.min(#list, i + dir))
    if j ~= i then
        settings.set("OpponentTier", j)
        U.log(TAG, "opponents: %s (V-RC-27)", M.aiTierText())
    end
    if W.v2 then v2.renderGrid(S.focusMode or S.mode) end
end

function M.stepGrid(dir)
    local m = S.focusMode or S.mode
    if S.step ~= "mode" or not m or m.grid ~= "max" then return end
    local lo, hi = humansCount(), V.maxRacers(S.cls)
    S.grid = math.max(lo, math.min(hi, S.grid + dir))
    S.gridTouched = true
    if W.v2 then v2.renderGrid(m) else setText(W.gridCy.m, gridText(m), true) end
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

---------------------------------------------------------------------------------------------------- UI v2 (0.12.0)
-- The v2 page (spec §6 frame, §7.1 / 7.4 / 7.5 steps, §8 RACERS page level). theme.lua builds every part (tokens,
-- builders, ghosts, texture budget); this section places them, fills them from S and paints the focus looks every FAST
-- tick from the ghosts' focus / hover (§3.3: one painted look per target, the ghost is invisible). Positions are the
-- spec's screen su (3840 x 2160), converted with the page geometry measured at the build (W.geo); a page that moved
-- since is shifted as a whole (v2.measure: render translation, V-FIN-01). The poster views and the list are built the
-- first time a step needs them (about 60-110 widgets each), so no tick builds the whole page.
do   -- 0.12.0: the v2 page's helpers stay local to this block (the main chunk's 200-local limit)
local L2 = {
    class = { x = 128, dx = 708, y = 600, w = 668, h = 1120, title = 42, panel = { 2968, 600, 744 } },   -- §7.1
    cond  = { x = 128, dx = 744, y = 600, w = 700, h = 1120, title = 48, detail = { 1700, 610, 1880 } },  -- §7.4
    mode  = { x = 128, y = 600, dy = 324, w = 1720, h = 290, title = 60, detail = { 2000, 600, 1712 } },  -- §7.5
    list  = { x = 128, y = 560, w = 1872, h = 96, pitch = 102, n = 12 },                                  -- §7
    cards = { x = 128, y = 548 },                                                                         -- §8
    sinkX = 1800,                                                                                         -- §6.4
}
local POSTER_KIND = { class = "class", cond = "cond", mode = "mode" }
local CLASS_HOME = { Car = "Mastiff", Bike = "Dalmatian", Skimmer = "Corgi", Plane = "Spaniel" }   -- §7.1 poster art
local PLURAL = { Car = "landspeeders", Bike = "speeder bikes", Skimmer = "skim speeders", Plane = "podracers" }
local COND_TINT = { BLUEHOUR = "#9CC3D0", NIGHT = "#316375", DAY = "#D1C371", AFTERNOON = "#D1C371" }   -- §7.4
local COND_AT = { SUNSET = "at sunset", BLUEHOUR = "at bluehour", NIGHT = "at night", AFTERNOON = "in the afternoon",
                  DAY = "by day", OVERCAST = "under an overcast sky", SCORCHING = "in scorching heat" }
local DT_RICH_BODY = "/Game/Griffin/UI/Library/Fonts/DT_RichText_Body.DT_RichText_Body"
local KML = "/Script/Engine.Default__KismetMaterialLibrary"
local MID_TRANSIENT = 1                                    -- EMIDCreationFlags::Transient (cards.lua, vpreview)

local function posterRect(kind, i)
    local g = L2[kind]
    if kind == "mode" then return { g.x, g.y + g.dy * (i - 1), g.w, g.h } end
    return { g.x + g.dx * (i - 1), g.y, g.w, g.h }
end

-- A child of a canvas at a SCREEN rect {x, y[, w, h]} (no w / h: the slot sizes to its content), point anchor (0, 0).
function v2.placeOn(cv, w, rect, z, align)
    local s = cv:AddChildToCanvas(w)                       -- -> CanvasPanelSlot
    if not U.ok(s) then error("AddChildToCanvas returned no slot") end
    local g = W.geo
    s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    s:SetAlignment({ X = align and align[1] or 0, Y = align and align[2] or 0 })
    if rect[3] and rect[4] then
        s:SetAutoSize(false)
        s:SetSize({ X = rect[3], Y = rect[4] })
    else
        s:SetAutoSize(true)
    end
    s:SetPosition({ X = rect[1] - g.x, Y = rect[2] - g.y })
    if z then s:SetZOrder(z) end
    return s
end

local function localRect(r)                                -- screen rect -> the page canvas's (T.set wants local su)
    local g = W.geo
    return { r[1] - g.x, r[2] - g.y, r[3], r[4] }
end

-- One of the game's widget Blueprints owned by P1 (the caller writes its variables before the add).
local function createBP(path)
    local cls = U.class(path)
    if not U.ok(cls) then error(tostring(path) .. " not found") end
    local w = U.WBL():Create(W.pc, cls, W.pc)              -- Create(WorldContextObject, Class, OwningPlayer)
    if not U.ok(w) then error("Create(" .. tostring(path) .. ") failed") end
    return w
end

local fontObjs = {}
local function fontObj(path)
    local f = fontObjs[path]
    if f and U.ok(f) then return f end
    f = U.obj(path)
    if U.ok(f) then fontObjs[path] = f; return f end
    return nil
end

-- A text block in a theme type role, for boxes (not a canvas). o = {colour, size, wrap (WrapTextAt, before the add),
-- justify (ETextJustify 0 / 1 / 2)}.
local function roleText(role, o)
    o = o or {}
    local r = type(role) == "table" and role or T().ROLE[role] or T().ROLE.helpText
    local t = newW(TEXT)
    if o.wrap then pcall(function() t.WrapTextAt = o.wrap end) end
    local f = fontObj(r.font)
    if f then
        -- FSlateFontInfo from a table: missing fields are zero-filled (no outline, no material) [cmap.lua]
        pcall(function() t:SetFont({ FontObject = f, TypefaceFontName = U.fname(r.face or "Bold"),
                                     Size = o.size or r.size, LetterSpacing = r.ls or 0 }) end)
    end
    pcall(function() t:SetColorAndOpacity(slateColor(o.colour or r.colour)) end)
    if r.upper then pcall(function() t:SetTextTransformPolicy(2) end) end   -- ETextTransformPolicy ToUpper
    if o.justify then pcall(function() t:SetJustification(o.justify) end) end
    pcall(function() t:SetVisibility(C.E.Vis.HitTestInvisible) end)
    return t
end

local function navReset(w, dirs)                           -- EUINavigationRule::Escape = Slate's geometric move
    if not U.ok(w) then return end
    for _, d in ipairs(dirs or { 0, 1, 2, 3 }) do pcall(function() w:SetNavigationRuleBase(d, 0) end) end
end

local function isCommand(w)
    return W ~= nil and (U.same(w, W.back) or U.same(w, W.start) or U.same(w, W.save))
end

-- BACK's Up rule follows P1's content focus (BACK sits alone at the bottom right: geometric Up finds nothing there).
function v2.noteFocus(f)
    if not (U.ok(f) and U.ok(W.back)) or isCommand(f) or U.same(W.backUp, f) then return end
    if T().nav(W.back, "up", f) then W.backUp = f end
end

---------------------------------------------------------------------------------------------------- v2 texts
local function condWords(tag)
    local t = {}
    for w in prettyCond(tag):gmatch("%S+") do if w ~= "MEM" then t[#t + 1] = w end end
    return t
end

local function condTint(tag)                               -- §7.4: Bluehour / Night / Day tints (others: as is)
    local w = condWords(tag)[1]
    local h = w and COND_TINT[w]
    return h and T().hex(h) or nil
end

local function condPhrase(tag)                             -- "NIGHT DRY" -> "at night, dry"
    local w = condWords(tag)
    if #w == 0 then return "" end
    local s = COND_AT[w[1]] or ("in " .. string.lower(w[1]))
    if #w > 1 then s = s .. ", " .. lowerWords(table.concat(w, " ", 2)) end
    return s
end

local function condName(tag) return titleCase(table.concat(condWords(tag), " ")) end

-- "DEBRIS DUNES · REVERSE": the CONDITIONS posters' caption (the condition is the poster's title).
local function trackCaption(e)
    local t = { e.name }
    if e.rev then t[#t + 1] = "REVERSE" end
    if e.p2p then t[#t + 1] = "POINT TO POINT" end
    if e.mines then t[#t + 1] = "MINES" end
    return table.concat(t, " · ")
end

-- §7.4 facts only: "Debris Dunes, reverse, loop B: 2 laps at sunset." + "This track also runs at Bluehour."
local function condFacts(e, tag)
    local t = { titleCase(e.name) }
    if e.rev then t[#t + 1] = "reverse" end
    if e.p2p then t[#t + 1] = "point to point" end
    if e.mines then t[#t + 1] = "mines" end
    if e.hint and e.hint ~= "" then t[#t + 1] = lowerWords((e.hint:gsub(" · ", ", "))) end
    local laps = ""
    if e.p2p then laps = "1 lap"
    elseif (tonumber(e.laps) or 0) > 0 then laps = string.format("%d lap%s", e.laps, e.laps == 1 and "" or "s") end
    local tail = table.concat({ laps, condPhrase(tag) }, " "):gsub("^%s+", ""):gsub("%s+$", "")
    return table.concat(t, ", ") .. (tail ~= "" and (": " .. tail) or "") .. "."
end

local function condFoot(e, tag)
    local others = {}
    for _, c in ipairs(e.conds or {}) do if c ~= tag then others[#others + 1] = condName(c) end end
    if #others == 0 then return "" end
    local s = (#others == 1) and others[1] or (table.concat(others, ", ", 1, #others - 1) .. " and " .. others[#others])
    return "This track also runs at " .. s .. "."
end

-- §7.3 list fallback row: "Debris Dunes · reverse".
function v2.trackRow(e)
    local t = { titleCase(e.name) }
    if e.dup and e.hint then t[#t + 1] = lowerWords(e.hint) end
    if e.rev then t[#t + 1] = "reverse" end
    if e.p2p then t[#t + 1] = "point to point" end
    if e.mines then t[#t + 1] = "mines" end
    return table.concat(t, " · ")
end

-- CLASS poster art (§7.1): the class's own Arcade tile; with a planet chosen (the class re-picked) that planet's
-- tile of the class when the game ships the pair. -> path, planet key (its tone colours the "UP TO n RACERS" line).
function v2.classArt(cls)
    local p = S.planet
    if p and ownArcadeTile(p, cls) then return M.arcadeTile(p, cls), p.key end
    local home = planetEntry(CLASS_HOME[cls.key] or "Mastiff") or PLANETS[1]
    return M.arcadeTile(home, cls), home.key
end

-- The CLASS poster caption "SWEEPING FORMS · DRIFT": the class's first VA trait + its class move. 0.12.0: the move is
-- the VA trait whose description names an input action ("Use <action id=.../> to drift"), so it comes in the game's
-- language like the first trait (live 2026-10-10 de: "RASENDE AGILITÄT · KINETIC BURST"); perkdata.ADVANCED (English:
-- Drift, Air Brake, Kinetic Burst, Knife Edge) only for a class without one (VA_Plane has no traits: "AIR BRAKE").
function v2.classCaption(cls)
    local names = {}
    local okI, info = pcall(V.classInfo, cls)
    local list = okI and type(info) == "table" and type(info.traitList) == "table" and info.traitList or {}
    if list[1] then names[1] = list[1].name end
    local move = nil
    for _, t in ipairs(list) do
        if type(t) == "table" and t.action and (t.name or "") ~= "" then move = t.name end
    end
    if not move then
        local okD, D = pcall(U.mod, "perkdata")
        move = okD and type(D) == "table" and type(D.ADVANCED) == "table" and D.ADVANCED[cls.arch] or nil
    end
    if move and move ~= names[1] then names[#names + 1] = move end
    return table.concat(names, " · ")
end

---------------------------------------------------------------------------------------------------- v2 page build
local function setBackground(kind)                         -- §6.1: hub on every step but PLANET (map)
    if W.bgKind == kind then return end
    W.bgKind = kind
    if W.bg.hub then T().set(W.bg.hub, { visible = kind == "hub" }) end
    if W.bg.map then T().set(W.bg.map, { visible = kind == "map" }) end
end

-- §8 card row: W.cardBox (CardRowW x CardH, CardH = min(cfg, the page's derived CardH)) > DownOnly ScaleBox (RC-15)
-- > W.cardRow, on the canvas at (128, 548).
function v2.buildCardRow()
    local h = math.min(tonumber(opt("CardH", 1300)) or 1300, tonumber(W.geo.cardH) or 1300)
    local box = sizeBox(opt("CardRowW", 3584), h)
    local sc = newW(SCALE)
    pcall(function() sc:SetStretch(2); sc:SetStretchDirection(1) end)   -- EStretch ScaleToFit, EStretchDir. DownOnly
    box:AddChild(sc)
    local row = newW(HBOX)
    local s = sc:AddChild(row)                             -- -> ScaleBoxSlot
    if U.ok(s) then pcall(function() s:SetHorizontalAlignment(C.E.HAlign.Center); s:SetVerticalAlignment(1) end) end
    v2.placeOn(W.panel, box, { L2.cards.x, L2.cards.y }, 2)
    show(box, false)
    W.cardBox, W.cardRow = box, row
end

-- §6.4 P1's input sink host (racers.lua's five invisible buttons) left of the command row's reserved slots.
function v2.buildSinkHost()
    local host = sizeBox(96, 96)
    v2.placeOn(W.panel, host, { L2.sinkX, tonumber(W.geo.cmdY) or 1880 }, 4)
    show(host, false)
    W.sinkHost = host
end

function v2.buildWidgets(root)
    local th = T()
    W.panel = newW(CANVAS)
    local s = root:AddChildToVerticalBox(W.panel)          -- -> VerticalBoxSlot: Size Fill, HAlign / VAlign Fill (§6)
    if U.ok(s) then
        pcall(function()
            s:SetSize({ Value = 1, SizeRule = 1 })         -- FSlateChildSize {Value, SizeRule Fill = 1}
            s:SetHorizontalAlignment(0)
            s:SetVerticalAlignment(0)
            s:SetPadding(pad(0, 0, 0, 0))
        end)
    end
    W.geo = th.pageGeometry(root)                           -- V-FIN-01 (logged by theme)
    W.shift = { x = 0, y = 0 }
    W.tctx = { tree = W.tree, pc = W.pc, newW = newW }
    local ctx, geo = W.tctx, W.geo
    W.bg = { hub = th.pageBackground(ctx, W.panel, geo, "hub"), map = th.pageBackground(ctx, W.panel, geo, "map") }
    if W.bg.map then th.set(W.bg.map, { visible = false }) end
    W.bgKind = "hub"
    W.title = th.screenTitle(ctx, W.panel, geo, "RACE SETUP")
    W.steps = th.stepRow(ctx, W.panel, geo)
    W.cmd = th.commandRow(ctx, W.panel, geo, {
        { id = "back", label = "BACK", fn = function() M.back() end, ghostId = "setup:back" },
        { id = "start", label = "START RACE", fn = function() M.finish(true) end, ghostId = "setup:start" },
        { id = "save", label = "SAVE AND RETURN", fn = function() M.finish(false) end, ghostId = "setup:save" },
    })
    if not W.cmd then error("command row not built (theme log: commandRow)") end
    W.back, W.start, W.save = W.cmd.widget("back"), W.cmd.widget("start"), W.cmd.widget("save")
    for _, g in ipairs({ W.back, W.start, W.save }) do
        if U.ok(g) then W.focusables[#W.focusables + 1] = g end
    end
    W.cmd.show({ back = true, start = false, save = false })
    W.pill = th.statusPill(ctx, W.panel, geo)
    cardsStage("card row", v2.buildCardRow)                -- 0.10.0 RACERS (collapsed until step 5 in the cards flow)
    cardsStage("sink host", v2.buildSinkHost)
    if CM then                                             -- 0.9.0 campaign views, placed on the canvas (ctx.place)
        local okC, why = pcall(CM.build, cmapCtx())
        if not okC then U.err(TAG, "campaign views not built (%s): PLANET / TRACK use the lists", tostring(why)) end
    end
    cardsStage("racers.build", buildRacers)                -- cards.init / cards2.init + the sink, on the complete page
    U.log(TAG, "UI v2 frame: page %d,%d %dx%d (%s), title %s, step row %s, command row, status pill %s, card row %s "
        .. "(V-FIN-01/02/03/12/16 in the theme log)", math.floor(geo.x), math.floor(geo.y), math.floor(geo.w),
        math.floor(geo.h), tostring(geo.src), W.title and "on" or "MISSING", W.steps and "on" or "MISSING",
        W.pill and "on" or "MISSING", U.ok(W.cardBox) and "on" or "off")
end

-- A built page whose canvas origin moved since the build (another page geometry now: DPI, a sibling of the switcher):
-- every part keeps its screen place through the canvas's render translation (V-FIN-01).
function v2.measure(why)
    if not (W and W.v2 and U.ok(W.panel) and W.geo) then return end
    local ok, g = pcall(function() return T().pageGeometry(W.root) end)
    if not ok or type(g) ~= "table" or not (tonumber(g.x) and tonumber(g.y)) then return end
    local dx, dy = W.geo.x - g.x, W.geo.y - g.y
    if math.abs(dx) < 1 and math.abs(dy) < 1 then dx, dy = 0, 0 end
    if W.shift.x == dx and W.shift.y == dy then return end
    if pcall(function() W.panel:SetRenderTranslation({ X = dx, Y = dy }) end) then   -- UWidget::SetRenderTranslation
        W.shift = { x = dx, y = dy }
        U.log(TAG, "page origin moved since the build (%s): built at %d,%d (%s), now %d,%d (%s): canvas shifted by "
            .. "%d,%d (V-FIN-01)", tostring(why), math.floor(W.geo.x), math.floor(W.geo.y), tostring(W.geo.src),
            math.floor(g.x), math.floor(g.y), tostring(g.src), math.floor(dx), math.floor(dy))
    end
end

-- A live UiStyle switch (spec §13 session I): the page of the other style is built in place of this one at the next
-- open (racers' cards, the bays and cmap's views go with the old panel).
function v2.rebuild(why)
    local root, pc, page = W.root, W.pc, W.page
    if not (U.ok(root) and U.ok(page)) then return false end
    if cardsWanted() then pcall(function() racers().forget() end) end
    releasePreviews("page rebuilt: " .. tostring(why), false)
    if CM then pcall(CM.forget) end
    if U.ok(W.panel) then pcall(function() W.panel:RemoveFromParent() end) end
    W = nil
    return buildPage(root, pc, page)
end

---------------------------------------------------------------------------------------------------- v2 views
-- The 4 poster ghosts shared by CLASS / CONDITIONS / MODE: re-placed per step, A / a click = M.onPoster(i).
local function ensurePosterGhosts()
    if W.posters then return end
    local list = {}
    for i = 1, 4 do
        local idx = i
        local g = T().ghost(W.tctx, W.panel, posterRect("class", i), "setup:poster" .. i,
            function() M.onPoster(idx) end, { geo = W.geo, z = 10 })
        if not U.ok(g) then error("poster ghost " .. i .. " not created") end
        T().set(g, { visible = false })
        list[i] = g
        W.focusables[#W.focusables + 1] = g
    end
    W.posters, W.posterMap = list, {}
end

-- Class / condition posters: the title stack at (44, h - 52) and the "UP TO n RACERS" / planet line + caption at 71.5 %
-- of the height (setup-class.png / setup-cond.png), wrapping at w - 88.
local function posterSet(V2, kind, extra)
    local th, L = T(), L2[kind]
    for i = 1, 4 do
        local p = th.poster(W.tctx, W.panel, posterRect(kind, i), { geo = W.geo, titleSize = L.title, z = 1,
                                                                     ay = (kind == "mode") and 1.0 or 0.5 })
        if not p then error(kind .. " poster " .. i .. " not built") end
        p.show(false)
        V2.posters[i] = p
        if kind ~= "mode" then
            th.set(p.stack, { rect = { 44, L.h - 52 } })
            th.set(p.title, { wrapW = L.w - 88 })
            V2.line[i] = th.text(W.tctx, p.cv, "planetLine", { size = 30, z = 5, rect = { 44, L.h * 0.715 } })
            V2.cap[i] = th.text(W.tctx, p.cv, "artCaption", { ls = 200, wrapW = L.w - 88, z = 5,
                                                              rect = { 44, L.h * 0.715 + 56 } })
        end
        if extra then extra(p, i) end
    end
end

-- §7.1 info panel (C13): WBP_DarkPanel under a FuseOverlay, content padding 56: WBP_SectionSubLabel (the class name,
-- SAGE), the first paragraph of VA_<Class>.Description (DT_RichText_Body, WrapTextAt 632), 3 x WBP_VehicleTrait (texts
-- written, never InitFromTrait). Height from the content.
local function buildInfoPanel(V2)
    local x, y, w = L2.class.panel[1], L2.class.panel[2], L2.class.panel[3]
    local inner = w - 112
    local sb = sizeBox(w, nil)
    pcall(function() sb:SetVisibility(C.E.Vis.HitTestInvisible) end)
    v2.placeOn(W.panel, sb, { x, y }, 3)
    V2.panel = sb
    local ov = newW(OVER)
    sb:AddChild(ov)
    local function fill(wd, p)
        local s = ov:AddChildToOverlay(wd)                 -- -> OverlaySlot
        if U.ok(s) then
            pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)
            if p then pcall(function() s:SetPadding(p) end) end
        end
    end
    local okP, dp = pcall(createBP, C.BP.DarkPanel)
    if okP then
        -- PreConstruct: tight / gradient / shadow visibility + Img_PanelBacker = MainPanelColor (decoded WBP_DarkPanel)
        pcall(function() dp.MainPanelColor = { R = 0.0130, G = 0.0369, B = 0.0482, A = 0.9 } end)   -- PANEL @0.9
        pcall(function() dp.ShowTightPanel = false end)
        pcall(function() dp.ShowShadow = true end)
        pcall(function() dp.ShowGradientPanel = false end)
        pcall(function() dp:SetVisibility(C.E.Vis.HitTestInvisible) end)
        fill(dp)
    else
        local im = newW(IMAGE)
        pcall(function() im:SetColorAndOpacity({ R = 0.0130, G = 0.0369, B = 0.0482, A = 0.9 }) end)
        pcall(function() im:SetVisibility(C.E.Vis.HitTestInvisible) end)
        fill(im)
        U.warn(TAG, "WBP_DarkPanel unavailable (%s): a plain CLASS info panel", tostring(dp))
    end
    local vb = newW(VBOX)
    fill(vb, pad(56, 56, 56, 56))
    local okS, sl = pcall(createBP, C.BP.SectionSubLabel)
    if okS then
        pcall(function() sl.Label = U.ftext("") end)       -- PreConstruct copies Label + Color into texts and rule
        pcall(function() sl.Color = { R = 0.3613, G = 0.4564, B = 0.3763, A = 1 } end)   -- SAGE (LinearColor)
        pcall(function() sl:SetVisibility(C.E.Vis.HitTestInvisible) end)
        vAdd(vb, sl, pad(0, 0, 0, 20))
        V2.sub = sl
    else
        V2.subText = roleText("subLabel")
        vAdd(vb, V2.subText, pad(0, 0, 0, 20))
        U.warn(TAG, "WBP_SectionSubLabel unavailable (%s): a plain sub-label", tostring(sl))
    end
    local rt = newW(RICH)
    local dt = U.obj(DT_RICH_BODY)
    if U.ok(dt) then pcall(function() rt:SetTextStyleSet(dt) end) end
    pcall(function() rt.WrapTextAt = inner end)            -- before the add (RC-3)
    pcall(function() rt:SetVisibility(C.E.Vis.HitTestInvisible) end)
    vAdd(vb, rt, pad(0, 0, 0, 26))
    V2.intro = rt
    -- a trait's text box: the panel content minus the trait's own paddings (border 16 + 16, row 16 + 16, right 16);
    -- its 620 default would exceed it and the trait's DownOnly scale box would shrink the text (rule 7)
    V2.traitW = inner - 92
    V2.traits = {}
    for i = 1, 3 do
        local okT, vt = pcall(createBP, C.BP.VehicleTrait)
        if okT then
            pcall(function() vt.Txt_Title.WrapTextAt = V2.traitW end)
            pcall(function() vt.RT_Desc.WrapTextAt = V2.traitW end)
            pcall(function() vt:SetVisibility(C.E.Vis.HitTestInvisible) end)
            vAdd(vb, vt, pad(0, (i > 1) and 16 or 0, 0, 0))
            V2.traits[i] = { w = vt }
        else
            U.warn(TAG, "WBP_VehicleTrait %d unavailable (%s): the CLASS panel shows fewer traits", i, tostring(vt))
        end
    end
    U.log(TAG, "CLASS info panel: %s, %s, %d WBP_VehicleTrait, trait glyphs %s (V-FIN-08: the DRIFT text must show "
        .. "the X button on an AMBER disc; fallback UiTraitGlyph = \"runs\")", okP and "WBP_DarkPanel" or "plain panel",
        okS and "WBP_SectionSubLabel" or "plain sub-label", #V2.traits, tostring(opt("UiTraitGlyph", "decorator")))
end

local function buildClassView()
    local V2 = { kind = "class", posters = {}, line = {}, cap = {}, sil = {} }
    W.views.class = V2
    posterSet(V2, "class", function(p, i)
        local L = L2.class                                 -- class silhouette WHITE @0.9, 90 su, top-right (inset 70)
        V2.sil[i] = T().image(W.tctx, p.cv, { tint = T().alpha(T().COL.WHITE, 0.9), z = 5,
                                              rect = { L.w - 115, 25, 90, 90 }, visible = false })
    end)
    buildInfoPanel(V2)
end

-- Two detail columns: §7.4's (x 1700, width 1880) beside two posters, and one right of a third poster (x 2444, the same
-- right edge 3580): tracks often have three conditions (decoded-tracks.tsv), the spec's layout shows two. Four or more
-- use the list.
local function buildCondView()
    local V2 = { kind = "cond", posters = {}, line = {}, cap = {}, tint = {}, midSig = {}, details = {} }
    W.views.cond = V2
    posterSet(V2, "cond")
    local d = L2.cond.detail
    local x3 = L2.cond.x + 3 * L2.cond.dx + (d[1] - (L2.cond.x + 2 * L2.cond.dx))
    for n, col in pairs({ [2] = { d[1], d[3] }, [3] = { x3, d[1] + d[3] - x3 } }) do
        V2.details[n] = T().detailColumn(W.tctx, W.panel, col[1], d[2], col[2], { geo = W.geo })
        if not V2.details[n] then error("CONDITIONS detail column not built") end
        V2.details[n].show(false)
    end
    V2.detail = V2.details[2]
end

local function buildModeView()
    local th, L = T(), L2.mode
    local V2 = { kind = "mode", posters = {}, line = {}, cap = {}, icons = {} }
    W.views.mode = V2
    posterSet(V2, "mode")
    local dx, dy, dw = L.detail[1], L.detail[2], L.detail[3]
    V2.detail = th.detailColumn(W.tctx, W.panel, dx, dy, dw, { geo = W.geo })
    if not V2.detail then error("MODE detail column not built") end
    -- the GRID group sits under the foot: the column's height with a one-line description + the foot (§7.5; every mode
    -- text is one line in 1712 su, so the place is fixed)
    V2.detail.set({ title = "RACE", body = MODE_V2.race.text(V.CLASSES[1]),
                    foot = "Up to 12 racers for the landspeeder." })
    local bottom = tonumber(V2.detail.bottom()) or (dy + 352)
    local gy = math.floor(bottom + 40)
    V2.header = th.groupHeader(W.tctx, W.panel, dx, dx + dw, gy, "GRID", { geo = W.geo })
    local ry = gy + 90
    V2.rowRect = { dx - 39, ry, dw + 39, 96 }              -- the label at x 2000, the value right-aligned at 3673
    V2.row = th.settingsRow(W.tctx, W.panel, V2.rowRect, { geo = W.geo, z = 3 })
    if not V2.row then error("GRID row not built") end
    -- the old cycler's three buttons are the row's ghosts (middle = the row, left / right = its arrows): the focus trap
    -- of onFocus works unchanged (EUINavigation Left 0, Right 1, as makeCycler)
    local cy = { id = "grid", onStep = function(dir) M.stepGrid(dir) end }
    cy.m = th.ghost(W.tctx, W.panel, V2.rowRect, "setup:grid:m", function() M.cyclerStep("grid", 1, "click") end,
        { geo = W.geo, z = 10 })
    cy.l = th.ghost(W.tctx, W.panel, { dx, ry, 64, 96 }, "setup:grid:l",
        function() M.cyclerStep("grid", -1, "click") end, { geo = W.geo, z = 11 })
    cy.r = th.ghost(W.tctx, W.panel, { dx, ry, 64, 96 }, "setup:grid:r",
        function() M.cyclerStep("grid", 1, "click") end, { geo = W.geo, z = 11 })
    if not (U.ok(cy.m) and U.ok(cy.l) and U.ok(cy.r)) then error("GRID ghosts not created") end
    pcall(function()
        cy.m:SetNavigationRuleExplicit(0, cy.l); cy.m:SetNavigationRuleExplicit(1, cy.r)
        cy.l:SetNavigationRuleExplicit(1, cy.m); cy.r:SetNavigationRuleExplicit(0, cy.m)
    end)
    for _, g in ipairs({ cy.m, cy.l, cy.r }) do
        th.set(g, { visible = false })
        W.focusables[#W.focusables + 1] = g
    end
    W.cyclers.grid = cy
    -- 0.12.0 (task #31): "Opponents" under "Racers" (same row look and ghost trio): the speeder tier the race launches
    -- on, i.e. the AI's strength (M.stepAiTier / settings OpponentTier)
    local ry2 = ry + 102
    V2.row2Rect = { dx - 39, ry2, dw + 39, 96 }
    V2.row2 = th.settingsRow(W.tctx, W.panel, V2.row2Rect, { geo = W.geo, z = 3 })
    if not V2.row2 then error("Opponents row not built") end
    local cy2 = { id = "aitier", onStep = function(dir) M.stepAiTier(dir) end }
    cy2.m = th.ghost(W.tctx, W.panel, V2.row2Rect, "setup:aitier:m", function() M.cyclerStep("aitier", 1, "click") end,
        { geo = W.geo, z = 10 })
    cy2.l = th.ghost(W.tctx, W.panel, { dx, ry2, 64, 96 }, "setup:aitier:l",
        function() M.cyclerStep("aitier", -1, "click") end, { geo = W.geo, z = 11 })
    cy2.r = th.ghost(W.tctx, W.panel, { dx, ry2, 64, 96 }, "setup:aitier:r",
        function() M.cyclerStep("aitier", 1, "click") end, { geo = W.geo, z = 11 })
    if not (U.ok(cy2.m) and U.ok(cy2.l) and U.ok(cy2.r)) then error("Opponents ghosts not created") end
    pcall(function()
        cy2.m:SetNavigationRuleExplicit(0, cy2.l); cy2.m:SetNavigationRuleExplicit(1, cy2.r)
        cy2.l:SetNavigationRuleExplicit(1, cy2.m); cy2.r:SetNavigationRuleExplicit(0, cy2.m)
    end)
    for _, g in ipairs({ cy2.m, cy2.l, cy2.r }) do
        th.set(g, { visible = false })
        W.focusables[#W.focusables + 1] = g
    end
    W.cyclers.aitier = cy2
    -- grid strip, 130 su under the last row: 12 class silhouettes (96 su, pitch 128) + one sentence (helpFoot)
    V2.stripY = ry2 + 130
    for i = 1, 12 do
        V2.icons[i] = th.image(W.tctx, W.panel, { z = 3, visible = false,
                                                  rect = localRect({ dx + 128 * (i - 1), V2.stripY, 96, 96 }) })
    end
    V2.stripText = th.text(W.tctx, W.panel, "helpFoot",
        { z = 3, wrapW = dw, rect = localRect({ dx, V2.stripY + 120 }) })
    U.log(TAG, "MODE view: detail column bottom %d, GRID header at y %d, row at %d, strip at %d", math.floor(bottom),
        gy, ry, V2.stripY)
end

-- §7 list fallback: 12 C8 settings rows (x 128-2000 from y 560, pitch 102); their ghosts are W.opts (onOption, onFocus
-- and the click poll keep working); the last row says "More (page n / m)" when the list is paged.
local function buildListView()
    local th, L = T(), L2.list
    local V2 = { kind = "list" }
    W.views.list = V2
    W.opts, W.rows = {}, {}
    for i = 1, L.n do
        local idx = i
        local r = th.settingsRow(W.tctx, W.panel, { L.x, L.y + L.pitch * (i - 1), L.w, L.h },
            { geo = W.geo, id = "setup:opt" .. i, fn = function() M.onOption(idx) end, z = 3 })
        if not (r and U.ok(r.ghost)) then error("list row " .. i .. " not built") end
        r.show(false)
        W.rows[i], W.opts[i] = r, r.ghost
        W.focusables[#W.focusables + 1] = r.ghost
    end
end

local VIEW_BUILD = { class = buildClassView, cond = buildCondView, mode = buildModeView, list = buildListView }

local function hideView(kind)
    local V2, th = W.views[kind], T()
    if not V2 then return end
    if kind == "list" then
        for _, r in ipairs(W.rows) do r.show(false) end
        return
    end
    for _, p in ipairs(V2.posters or {}) do p.show(false) end
    if V2.panel then show(V2.panel, false) end
    if V2.detail then V2.detail.show(false) end
    for _, d in pairs(V2.details or {}) do d.show(false) end
    if V2.header then V2.header.show(false) end
    if V2.row then V2.row.show(false) end
    if V2.row2 then V2.row2.show(false) end
    for _, e in ipairs(V2.icons or {}) do th.set(e, { visible = false }) end
    if V2.stripText then th.set(V2.stripText, { visible = false }) end
end

-- The view of kind ready (built now if needed). false = it failed (logged once): that step uses the list.
function v2.ensureView(kind)
    if W.views[kind] and not W.viewBroken[kind] then return true end
    if W.viewBroken[kind] then return false end
    local t0 = St.nowMs()
    local ok, err = pcall(function()
        if kind ~= "list" then ensurePosterGhosts() end
        VIEW_BUILD[kind]()
    end)
    if not ok then
        W.viewBroken[kind] = tostring(err)
        pcall(hideView, kind)
        W.views[kind] = nil
        U.err(TAG, "UI v2 %s view not built (%s): that step uses the list", kind, tostring(err))
        return false
    end
    hideView(kind)
    W.views[kind].shown = false
    U.log(TAG, "UI v2 %s view built (%.1f ms)", kind, St.nowMs() - t0)
    return true
end

-- Only the view of this step shows (posters of one kind, or the list); the RACERS parts follow the step.
local function showViews(step, view)
    local kind = POSTER_KIND[step]
    for k, V2 in pairs(W.views) do
        local on = (view == "posters" and k == kind) or (view == "list" and k == "list")
        if not on and V2.shown ~= false then hideView(k) end
        V2.shown = on
        if on and k ~= "list" then                         -- the posters show as renderPosters fills them
            if V2.panel then show(V2.panel, true) end
            if V2.detail then V2.detail.show(true) end
            if V2.header then V2.header.show(true) end
            if V2.row then V2.row.show(true) end
            if V2.row2 then V2.row2.show(true) end
            if V2.stripText then T().set(V2.stripText, { visible = true }) end
        end
    end
    if W.posters and view ~= "posters" then
        for _, g in ipairs(W.posters) do T().set(g, { visible = false }) end
    end
    for _, id in ipairs({ "grid", "aitier" }) do
        local cy = W.cyclers[id]
        if cy and not (view == "posters" and step == "mode") then
            for _, g in ipairs({ cy.l, cy.m, cy.r }) do T().set(g, { visible = false }) end
        end
    end
    local veh = step == "vehicles"
    show(W.cardBox, veh and S.cards)
    show(W.sinkHost, veh and S.cards)
    show(W.vehRow, veh and not S.cards)
end

-- The classic VEHICLES columns on the v2 canvas: only when the RACERS cards cannot serve this page (V-RC-01).
function v2.ensureVehRow()
    if U.ok(W.vehRow) then return true end
    local ok, err = pcall(function()
        local row = newW(HBOX)
        for i = 1, 4 do
            local col = makeColumn(i)
            hAdd(row, col.box, 1, pad(i > 1 and 12 or 0, 0, 0, 0))
        end
        v2.placeOn(W.panel, row, { L2.cards.x, L2.cards.y, 3584, 1300 }, 2)
        W.vehRow = row
    end)
    if not ok then
        U.err(TAG, "classic VEHICLES columns not built on the v2 page (%s)", tostring(err))
        return false
    end
    U.log(TAG, "classic VEHICLES columns built on the v2 page (the RACERS cards are unavailable here)")
    return true
end

---------------------------------------------------------------------------------------------------- v2 posters
-- §7.4 V-FIN-07: a CONDITIONS poster after the first through a MID of MI_UI_Squircle_TextureMask on the art image
-- (TileArt = the tile, Desaturation 1, Color Overlay Amount 1, TileColor; Texture = a plain fill: the window clips).
-- Applied once the tile is on the image (theme sized it to cover the window). UiCondTint = false: untinted art.
local tintFailed = nil
local function applyTint(e, path, colour)
    if tintFailed then return false end
    local ok, err = pcall(function()
        local tex, parent, kml = U.obj(path), U.obj(T().MAT.TextureMask), U.cdo(KML)
        if not (U.ok(tex) and U.ok(parent) and U.ok(kml)) then
            error("texture, MI_UI_Squircle_TextureMask or KismetMaterialLibrary not found")
        end
        -- CreateDynamicMaterialInstance(WorldContextObject, Parent, OptionalName, CreationFlags) (cards.lua, vpreview)
        local mid = kml:CreateDynamicMaterialInstance(U.world(), parent, U.fname("None"), MID_TRANSIENT)
        if not U.ok(mid) then error("CreateDynamicMaterialInstance failed") end
        local fillTex = U.obj(T().TEX.SolidFill)
        mid:SetTextureParameterValue(U.fname("TileArt"), tex)                    -- (Name, Texture)
        if U.ok(fillTex) then mid:SetTextureParameterValue(U.fname("Texture"), fillTex) end
        mid:SetScalarParameterValue(U.fname("Desaturation"), 1.0)                 -- (Name, Float)
        mid:SetScalarParameterValue(U.fname("Color Overlay Amount"), 1.0)
        mid:SetScalarParameterValue(U.fname("ImageScale"), 1.0)
        mid:SetScalarParameterValue(U.fname("ImageXOffset"), 0.5)
        mid:SetScalarParameterValue(U.fname("ImageYOffset"), 0.5)
        local cw, ch = type(e.c) == "table" and e.c.w, type(e.c) == "table" and e.c.h   -- the image's cover size
        if cw and ch then
            mid:SetScalarParameterValue(U.fname("In Width Override"), cw)
            mid:SetScalarParameterValue(U.fname("In Height Override"), ch)
        end
        mid:SetVectorParameterValue(U.fname("TileColor"), { R = colour.R, G = colour.G, B = colour.B, A = 1 })
        e.i:SetBrushFromMaterial(mid)                      -- the MID's only referencer: set in the same tick (GC rule)
        e.mid = mid
    end)
    if ok then
        U.logOnce("setup.tint", TAG, "condition tint: MI_UI_Squircle_TextureMask MID on the CONDITIONS poster art "
            .. "(V-FIN-07: the second poster must read as a duotone of the condition's colour; fallback UiCondTint = "
            .. "false)")
        return true
    end
    tintFailed = tostring(err)
    U.warn(TAG, "condition tint unavailable (%s): untinted condition art (V-FIN-07 fallback)", tintFailed)
    return false
end

-- FAST: the tints wait for their poster's art (theme loads textures within the per-tick budget).
local function tintTick()
    local V2 = W.views.cond
    if not (V2 and V2.shown) then return end
    for i = 1, 4 do
        local want, p = V2.tint[i], V2.posters[i]
        local e = p and p.art
        if want and e and U.ok(e.i) and type(e.c) == "table" and e.c.tex == want.art then
            local sig = want.art .. "|" .. tostring(want.colour)
            if V2.midSig[i] ~= sig then
                if applyTint(e, want.art, want.colour) then V2.midSig[i] = sig else V2.tint[i] = nil end
            end
        end
    end
end

function v2.fillPoster(kind, i, it)
    local th, V2, L = T(), W.views[kind], L2[kind]
    local p = V2.posters[i]
    if kind == "class" then
        local cls = it.cls
        local art, pl = v2.classArt(cls)
        p.set({ art = art, title = (cls.label:gsub(" ", "\n")),
                -- 0.12.0: top-left; bottom-right it covered the end of a one-word name (LANDSPEEDER, live 2026-10-10)
                check = (S.cls == cls) and { 60, 60, 64 } or false })
        th.set(V2.sil[i], { tex = cls.icon, visible = true })
        th.set(V2.line[i], { text = string.format("UP TO %d RACERS", V.maxRacers(cls)),
                             colour = th.PLANET[pl] or th.COL.BEIGE })
        th.set(V2.cap[i], { text = v2.classCaption(cls) })
    elseif kind == "cond" then
        local tag, e = it.tag, S.track
        local art = trackArt(e)
        local tint = (i > 1 and opt("UiCondTint", true) ~= false) and condTint(tag) or nil
        if not tint and p.art and p.art.mid then              -- a MID from an earlier track: the plain tile again
            local tex = U.obj(art)
            if U.ok(tex) and pcall(function() p.art.i:SetBrushFromTexture(tex, false) end) then
                p.art.mid, V2.midSig[i] = nil, nil
            end
        end
        p.set({ art = art, title = prettyCond(tag), check = (S.cond == tag) and { L.w - 60, 60, 64 } or false })
        th.set(V2.line[i], { text = S.planet and S.planet.name or "",
                             colour = tint or (S.planet and th.PLANET[S.planet.key]) or th.COL.BEIGE })
        th.set(V2.cap[i], { text = trackCaption(e) })
        V2.tint[i] = tint and { art = art, colour = tint } or nil
    elseif kind == "mode" then
        local m = it.mode
        local mv = MODE_V2[m.key] or {}
        local art = type(mv.art) == "table" and mv.art[S.cls and S.cls.key or "Car"] or mv.art
        -- 0.12.0: the light strips get a band of their own colour behind the title (theme.poster scrim): the art's
        -- dark shapes ran under the DEEP title (FULL GRID RACE / MIXED-CLASS RACE, live 2026-10-10)
        p.set({ art = art and tp("MainMenu", art) or false, title = m.label, titleCol = th.COL[mv.ink or "BEIGE"],
                scrim = mv.scrim and th.hex(mv.scrim) or false, check = S.mode == m })
    end
end

-- Posters for this step's items (up to 4) + their ghosts; -> the ghost to focus.
local function renderPosters(step, sel)
    local kind = POSTER_KIND[step]
    local V2, th = W.views[kind], T()
    local n = math.min(#S.items, 4)
    W.posterMap = {}
    if V2.details then                                     -- CONDITIONS: the detail column beside the last poster
        local want = V2.details[(n >= 3) and 3 or 2]
        if want ~= V2.detail then V2.detail.show(false); V2.detail = want end
        V2.detail.show(true)
    end
    for i = 1, 4 do
        local p, g = V2.posters[i], W.posters[i]
        if i <= n then
            U.try(TAG, v2.fillPoster, kind, i, S.items[i])
            p.show(true)
            th.set(g, { rect = localRect(posterRect(kind, i)), visible = true })
            W.posterMap[i] = i
        else
            p.show(false)
            th.set(g, { visible = false })
        end
        p.focus(false)
    end
    V2.painted = nil
    return W.posters[math.max(1, math.min(n, tonumber(sel) or 1))]
end

-- FAST: the painted poster = the hovered ghost, else the focused one (one focus look, §2.6).
local function paintPosters()
    local V2 = W.views[POSTER_KIND[S.step] or ""]
    if not (V2 and W.posters) then return end
    local hov = ui().hovered
    local painted
    if type(hov) == "function" then
        for i, g in ipairs(W.posters) do
            if W.posterMap[i] and hov(g) then painted = i; break end
        end
    end
    if not painted then
        for i, g in ipairs(W.posters) do
            if W.posterMap[i] and U.same(S.lastFocus, g) then painted = i; break end
        end
    end
    if V2.painted == painted then return end
    V2.painted = painted
    for i, p in ipairs(V2.posters) do p.focus(i == painted) end
    if painted and not W.ghostLogged then
        W.ghostLogged = true
        U.log(TAG, "poster ghost %d holds P1's focus / hover: painted look on its poster (V-FIN-04)", painted)
    end
end

---------------------------------------------------------------------------------------------------- v2 previews
-- §7.1: the info panel follows the focused class.
function v2.previewClass(cls)
    local V2 = W.views.class
    if not V2 or V2.shownClass == cls.key then return end
    V2.shownClass = cls.key
    local info = V.classInfo(cls)
    if V2.sub then pcall(function() V2.sub:SetLabel(U.ftext(info.name)) end)   -- SetLabel(Text): Label + both texts
    elseif V2.subText then pcall(function() V2.subText:SetText(U.ftext(info.name)) end) end
    local intro = (info.introRich ~= nil and info.introRich ~= "") and info.introRich or (info.intro or info.desc or "")
    pcall(function() V2.intro:SetText(U.ftext(intro)) end)
    local runs = opt("UiTraitGlyph", "decorator") == "runs"
    for i = 1, 3 do
        local t, tr = V2.traits[i], (info.traitList or {})[i]
        if t then
            if tr then
                pcall(function() t.w.Txt_Title:SetText(U.ftext(tr.name)) end)
                if runs and tr.action then
                    pcall(function() t.w.RT_Desc:SetVisibility(C.E.Vis.Collapsed) end)
                    U.try(TAG, v2.fillRuns, t, tr, V2.traitW)
                else
                    if t.box then pcall(function() t.box:SetVisibility(C.E.Vis.Collapsed) end) end
                    pcall(function() t.w.RT_Desc:SetVisibility(C.E.Vis.HitTestInvisible) end)
                    pcall(function() t.w.RT_Desc:SetText(U.ftext(tr.rich ~= "" and tr.rich or tr.plain)) end)
                end
                pcall(function() t.w:SetVisibility(C.E.Vis.HitTestInvisible) end)
            else
                pcall(function() t.w:SetVisibility(C.E.Vis.Collapsed) end)
            end
        end
    end
end

-- V-FIN-08 fallback (UiTraitGlyph = "runs"): the trait text as the mod's own run in the trait's VB_DescLayout, "Use"
-- + the X glyph on an AMBER disc + "to drift sharply", the rest of the sentence on the lines below (one line of runs,
-- cut at a word that would pass the box).
function v2.fillRuns(t, tr, width)
    if not t.box then
        local box = newW(VBOX)
        local okB = pcall(function() t.w.VB_DescLayout:AddChildToVerticalBox(box) end)
        if not okB then error("VB_DescLayout not reachable") end
        t.box = box
    end
    pcall(function() t.box:ClearChildren() end)
    pcall(function() t.box:SetVisibility(C.E.Vis.HitTestInvisible) end)
    local th = T()
    local line = newW(HBOX)
    vAdd(t.box, line, pad(0, 4, 0, 0), C.E.HAlign.Left)
    local used, rest = 0, nil
    for _, r in ipairs(tr.runs or {}) do
        if rest then
            rest = rest .. (r.text or (r.key and r.key) or "")
        elseif r.text then
            local cur = ""
            for sp, word in r.text:gmatch("(%s*)(%S+)") do
                if rest then rest = rest .. sp .. word
                elseif used + th.textWidth(cur .. sp .. word, th.ROLE.body) > width then rest = word
                else cur = cur .. sp .. word end
            end
            if not rest and r.text:match("%s$") then cur = cur .. " " end
            if cur ~= "" then
                local tb = roleText("body")
                pcall(function() tb:SetText(U.ftext(cur)) end)
                hAdd(line, tb)
                used = used + th.textWidth(cur, th.ROLE.body)
            end
        elseif r.glyph then
            local sb, ov = sizeBox(40, 40), newW(OVER)
            sb:AddChild(ov)
            local disc, gl = newW(IMAGE), newW(IMAGE)
            local dt, gt = V.texture(th.TEX.CircleFill), V.texture(th.glyph(r.glyph))
            if dt then pcall(function() disc:SetBrushFromTexture(dt, false) end) end
            pcall(function() disc:SetColorAndOpacity({ R = 0.7454, G = 0.4125, B = 0.0802, A = 1 }) end)   -- AMBER
            if gt then pcall(function() gl:SetBrushFromTexture(gt, false) end) end
            pcall(function() gl:SetColorAndOpacity({ R = 0.0160, G = 0.0160, B = 0.0152, A = 1 }) end)     -- INK
            for _, im in ipairs({ disc, gl }) do
                local s = ov:AddChildToOverlay(im)
                if U.ok(s) then pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end) end
                if im == gl and U.ok(s) then pcall(function() s:SetPadding(pad(6, 6, 6, 6)) end) end
            end
            hAdd(line, sb, nil, pad(6, 4, 6, 0))
            used = used + 52
        end
    end
    if rest and rest ~= "" then
        local tb = roleText("body", { wrap = width })
        pcall(function() tb:SetText(U.ftext(rest)) end)
        vAdd(t.box, tb)
    end
end

function v2.previewCond(tag)
    local V2 = W.views.cond
    if not (V2 and V2.detail and S.track) then return end
    V2.detail.set({ title = prettyCond(tag), body = condFacts(S.track, tag), foot = condFoot(S.track, tag),
                    rich = false })
end

function v2.previewMode(m)
    local V2 = W.views.mode
    if not V2 then return end
    local mv = MODE_V2[m.key] or {}
    local text = mv.text
    if type(text) == "function" then text = text(S.cls) end
    local foot = (m.grid == "max" and S.cls) and string.format("Up to %d racers for the %s.", V.maxRacers(S.cls),
        string.lower(S.cls.label)) or ""
    V2.detail.set({ title = m.label, body = text or m.desc, foot = foot })
    v2.renderGrid(m)
end

-- The strips' Right rule reaches the first GRID row that takes focus (Racers: "max" grids only; Opponents: speeders).
-- Racers Down -> Opponents -> BACK; Up the other way, the top row up to the first strip.
local function gridNav(on, on2)
    local cy, cy2 = W.cyclers.grid, W.cyclers.aitier
    if not (cy and W.posters) then return end
    local th = T()
    local first = (on and cy.m) or (on2 and cy2 and cy2.m) or nil
    for i = 1, 4 do
        navReset(W.posters[i], { 1 })
        if first and W.posterMap[i] then th.nav(W.posters[i], "right", first) end
    end
    navReset(cy.m, { 2, 3 })
    if cy2 then navReset(cy2.m, { 2, 3 }) end
    if on then
        th.nav(cy.m, "down", (on2 and cy2) and cy2.m or W.back)
        th.nav(cy.m, "up", W.posters[1])
    end
    if on2 and cy2 then
        th.nav(cy2.m, "down", W.back)
        th.nav(cy2.m, "up", on and cy.m or W.posters[1])
    end
end

-- §7.5 GRID row + grid strip for the focused mode (range humans .. class limit, unchanged stepGrid).
function v2.renderGrid(m)
    local V2 = W.views.mode
    if not V2 then return end
    m = m or S.focusMode or S.mode
    local th = T()
    local maxGrid = m ~= nil and m.grid == "max"
    local h = humansCount()
    local cls = S.cls or V.CLASSES[1]
    local value = maxGrid and string.format("%d  (%d AI)", S.grid, math.max(0, S.grid - h)) or "Set by the game"
    V2.row.set({ label = "Racers", value = value, kind = maxGrid and "cycle" or "value", enabled = maxGrid,
                 arrows = "always" })
    local on = maxGrid and S.step == "mode" and S.view == "posters"
    local cy = W.cyclers.grid
    if cy then
        th.set(cy.m, { visible = on })
        th.set(cy.l, { visible = on })
        th.set(cy.r, { visible = on })
        if on then                                         -- the arrow ghosts over the painted arrows (mouse clicks)
            local r = V2.rowRect
            local right = r[1] + r[3] - 39
            local vw = th.textWidth(value, th.ROLE.rowValue)
            th.set(cy.r, { rect = localRect({ right - 27 - 18, r[2], 64, r[4] }) })
            th.set(cy.l, { rect = localRect({ right - 27 - 18 - vw - 18 - 27 - 18, r[2], 64, r[4] }) })
        end
    end
    -- 0.12.0 (task #31): the Opponents row (speeders: the tier list; pods: "Standard", not focusable; 0.13.0 QUICK
    -- RACE: pods step the 6 difficulties too)
    local tierI, tiers = M.aiTierIndex()
    local speeder = (tierI ~= nil and #tiers > 1) or not quickOn()   -- CUSTOM: every class can step to MATCH
    local tierText = M.aiTierText()
    if V2.row2 then
        V2.row2.set({ label = quickOn() and "Difficulty" or "Opponents", value = tierText, kind = speeder and "cycle" or "value", enabled = speeder,
                      arrows = "always" })
    end
    local on2 = speeder and S.step == "mode" and S.view == "posters"
    local cy2 = W.cyclers.aitier
    if cy2 then
        th.set(cy2.m, { visible = on2 })
        th.set(cy2.l, { visible = on2 })
        th.set(cy2.r, { visible = on2 })
        if on2 then
            local r = V2.row2Rect
            local right = r[1] + r[3] - 39
            local vw = th.textWidth(tierText, th.ROLE.rowValue)
            th.set(cy2.r, { rect = localRect({ right - 27 - 18, r[2], 64, r[4] }) })
            th.set(cy2.l, { rect = localRect({ right - 27 - 18 - vw - 18 - 27 - 18, r[2], 64, r[4] }) })
        end
    end
    if V2.gridOn ~= on or V2.tierOn ~= on2 then
        V2.gridOn, V2.tierOn = on, on2
        gridNav(on, on2)
        if not on then V2.rowFocus = nil; V2.row.set({ focused = false }) end
        if not on2 and V2.row2 then V2.row2Focus = nil; V2.row2.set({ focused = false }) end
    end
    -- the strip: humans INK, AI INK @0.32 (MIXED 4 + 4 + 4, ELIMINATOR 12 mixed); then one sentence
    local list, key = {}, m and m.key or "race"
    local trio = { V.classByKey("Car"), V.classByKey("Bike"), V.classByKey("Skimmer") }
    if key == "mixed" then
        for _, c in ipairs(trio) do for _ = 1, 4 do list[#list + 1] = c end end
    elseif key == "eliminator" then
        for _ = 1, 4 do for _, c in ipairs(trio) do list[#list + 1] = c end end
    else
        local n = maxGrid and S.grid or V.maxRacers(cls)
        for _ = 1, math.min(12, n) do list[#list + 1] = cls end
    end
    local humansLeft = h
    local ink, ai = th.COL.INK, th.alpha(th.COL.INK, 0.32)
    for i = 1, 12 do
        local c = list[i]
        if c then
            local human = humansLeft > 0 and c == cls
            if human then humansLeft = humansLeft - 1 end
            th.set(V2.icons[i], { tex = c.icon, colour = human and ink or ai, visible = true })
        else
            th.set(V2.icons[i], { visible = false })
        end
    end
    local players = string.format("%d player%s", h, h == 1 and "" or "s")
    local text
    if key == "fullgrid" then
        text = players .. "; the game fills the rest of the grid."
    elseif key == "mixed" or key == "eliminator" then
        text = string.format("%s and %d AI in mixed classes.", players, math.max(0, #list - h))
    else
        local nAi = math.max(0, #list - h)
        text = (nAi > 0) and string.format("%s and %d AI, all in %s.", players, nAi, PLURAL[cls.key] or "the class")
            or string.format("%s, all in %s.", players, PLURAL[cls.key] or "the class")
    end
    th.set(V2.stripText, { text = text, visible = S.step == "mode" })
end

-- FAST: the GRID row's RUST pill follows its three ghosts (focus or hover).
local function paintGrid()
    local V2 = W.views.mode
    if not (V2 and V2.row and W.cyclers.grid) then return end
    local hov = ui().hovered
    local function lit(cy, active)
        if not (cy and active) then return false end
        for _, g in ipairs({ cy.m, cy.l, cy.r }) do
            if U.same(S.lastFocus, g) or (type(hov) == "function" and hov(g)) then return true end
        end
        return false
    end
    local on = lit(W.cyclers.grid, V2.gridOn)
    if V2.rowFocus ~= on then
        V2.rowFocus = on
        V2.row.set({ focused = on })
    end
    if V2.row2 then                                        -- 0.12.0: the Opponents row
        local on2 = lit(W.cyclers.aitier, V2.tierOn)
        if V2.row2Focus ~= on2 then
            V2.row2Focus = on2
            V2.row2.set({ focused = on2 })
        end
    end
end

---------------------------------------------------------------------------------------------------- v2 list
function v2.fillRows()
    local n, total = #W.opts, #S.items
    if n == 0 then return end
    local per = total > n and (n - 1) or n
    local pages = math.max(1, math.ceil(total / per))
    if S.page >= pages or S.page < 0 then S.page = 0 end
    local first = S.page * per
    W.optMap = {}
    for i = 1, n do
        local r, idx = W.rows[i], first + i
        if i <= per and idx <= total then
            local it = S.items[idx]
            local row = it.row or { titleCase(it.label), "" }
            r.set({ label = row[1], value = row[2] or "", kind = "value", enabled = true, focused = false })
            r.show(true)
            W.optMap[i] = idx
        elseif i == n and total > n then
            r.set({ label = string.format("More (page %d / %d)", S.page + 1, pages), value = "", kind = "action",
                    enabled = true, focused = false })
            r.show(true)
            W.optMap[i] = "more"
        else
            r.show(false)
        end
    end
end

-- FAST: a row's RUST pill follows its ghost (P1's focus, from the focus scan, or the mouse).
local function paintRows()
    local hov = ui().hovered
    for i, r in ipairs(W.rows) do
        if W.optMap and W.optMap[i] ~= nil then
            local on = U.same(S.lastFocus, r.ghost) or (type(hov) == "function" and hov(r.ghost))
            if r.st.focused ~= on then r.set({ focused = on }) end
        end
    end
end

---------------------------------------------------------------------------------------------------- v2 frame state
-- §6.3: done = tick + value, current = RUST pill, upcoming = GREY; CONDITIONS only when the chosen track asks for it.
function v2.renderSteps()
    if not W.steps then return end
    local cur = (S.step == "vehicles") and "racers" or S.step
    local list = {}
    local function add(id, name, done) list[#list + 1] = { id = id, name = name, done = done } end
    add("class", "CLASS", S.cls and S.cls.label)
    add("planet", "PLANET", S.planet and S.planet.name)
    add("track", "TRACK", S.track and (S.track.name .. (S.track.rev and " · REV" or "")))
    if S.track and #(S.track.conds or {}) > 1 and opt("SetupAskCondition", true) ~= false then
        add("cond", "CONDITIONS", (S.cond ~= nil and S.cond ~= "") and prettyCond(S.cond) or nil)
    end
    add("mode", "MODE", S.mode and S.mode.label)
    add("racers", "RACERS", nil)
    local ci = 1
    for i, it in ipairs(list) do if it.id == cur then ci = i end end
    local items = {}
    for i, it in ipairs(list) do
        local st = (i < ci) and "done" or ((i == ci) and "current" or "next")
        items[#items + 1] = { label = (st == "done" and it.done) or it.name, state = st }
    end
    W.steps.render(items)
end

-- §6.4: BACK always; SAVE AND RETURN / START RACE on RACERS only with P1 in mouse + keyboard mode (pad: P1's READY rows
-- on the card) or when the classic columns serve the step (no READY rows there).
function v2.renderCommands()
    local c = W.cmd
    if not c then return end
    local mode = T().inputMode()                           -- debounced by theme with its own clock (V-FIN-11)
    local veh = S.active and S.step == "vehicles"
    local ss = veh and (mode == "mouse" or not S.cards)
    if W.cmdSS ~= ss and not ss and W.cmdForced then c.look(W.cmdForced, nil); W.cmdForced = nil end
    W.cmdSS = ss
    local sig = veh and (tostring(ss) .. tostring(mode) .. tostring(S.cards)) or nil
    if W.cmdSig ~= sig then
        W.cmdSig = sig
        if veh then
            U.log(TAG, "command row: %s (P1 input %s%s) (V-FIN-11: START RACE is never shown twice)",
                ss and "SAVE AND RETURN, START RACE, BACK" or "BACK only", tostring(mode),
                S.cards and "" or ", classic columns")
        end
    end
    c.show({ back = true, start = ss, save = ss })
    if W.pillReady and W.pillReadyMode ~= mode then v2.postAllReady(mode) end
end

-- §6.5 "ALL READY · P1: (A) TO START" (pad) / "ALL READY · P1: START RACE" (mouse), sticky, one AMBER pip per player.
function v2.postAllReady(mode)
    if not W.pill then return end
    mode = mode or T().inputMode()
    local text = (mode == "mouse") and "ALL READY · P1: START RACE" or "ALL READY · P1: (A) TO START"
    local pips = {}
    for i = 1, math.min(4, #localPlayers()) do pips[i] = true end
    W.pillReady, W.pillReadyMode = text, mode
    W.pill.post(text, { sticky = true, prio = 2, key = "allready", pips = pips })
end

-- The status pill's variant by the text (§6.5: refusals and errors warn), for messages without opts.
local WARN_WORDS = { "FAILED", "ERROR", "REFUSED", "TIMED OUT", "UNAVAILABLE", "NOT AVAILABLE", "NOT FOUND", "CANNOT",
                     "ONLY WORKS", "ONLY IN THE", "ONLY FROM", " FIRST", "DISCONNECT TO", "NO FREE", "NO TRACK",
                     "NO PLANET", "NOT JOINED", "NOT READY", "GAVE UP", "DROPPED", "NO MENU", "NOT ACTIVE", "MUST BE",
                     "HAS NO CONTROLLER", "CONTROLLER DISCONNECTED", "NO GUEST", "INCOMPLETE", "CHOOSE CLASS",
                     "NOT LISTENING", "GRID HAS" }
local function warnText(u)
    for _, w in ipairs(WARN_WORDS) do if u:find(w, 1, true) then return true end end
    return false
end

-- "P1 PILOT · P2 PERKS": the 0.11.0 RACERS progress line, dropped on the v2 page (§6.5: every card's rail shows it).
local function progressText(u)
    local any = false
    for part in (u .. " · "):gmatch("(.-) · ") do
        if not part:match("^P%d [A-Z]+$") then return false end
        any = true
    end
    return any
end

-- The page's status pill (§6.5). opts given (this file's gate / class-reset texts, racers' keyed entries): posted as
-- given (text "" + key = that entry cleared). Without opts (St.emit("status") through lobby.setStatus, racers' 0.11.0
-- line): one entry per "   ·   " part, the RACERS progress summary dropped, "ALL READY" sticky with pips, the join hint
-- posted once per change, LAUNCHING sticky, refusals and errors warn, the rest 5 s. The echo of a text this page just
-- posted (St.emit -> lobby.setStatus -> setup.setStatus) is dropped.
pillFeed = function(text, o)
    if not (W and W.v2 and W.pill and S.active) then return end
    text = tostring(text or "")
    local now, p = M.realMs(), W.pill
    local echo = text == W.pillLast and now - (W.pillLastAt or -1e9) < 300
    W.pillLast, W.pillLastAt = text, now
    if type(o) == "table" then
        if text == "" then p.clear(o.key) else p.post(text, o) end
        return
    end
    if echo or text == "" then return end
    local parts, racersLine, ready, join = {}, false, false, false
    for part in (text .. "   ·   "):gmatch("(.-)   ·   ") do parts[#parts + 1] = part end
    for _, part in ipairs(parts) do
        local u = string.upper(part)
        if u:find("^ALL READY") then
            racersLine, ready = true, true
            if not W.pillReady then v2.postAllReady() end
        elseif progressText(u) then
            racersLine = true
        elseif u:find("PRESS", 1, true) and u:find("TO JOIN", 1, true) then
            join = true
            local t = part:gsub("PRESS A TO JOIN", "PRESS (A) TO JOIN")
            if t ~= W.pillJoin then W.pillJoin = t; p.post(t, { key = "join" }) end
        elseif u:find("^LAUNCHING") then
            p.post(part, { sticky = true, prio = 1, key = "launch" })
        else
            p.post(part, { warn = warnText(u) })
        end
    end
    if racersLine and not ready and W.pillReady then W.pillReady = nil; p.clear("allready") end
    if racersLine and not join then W.pillJoin = nil end
end

-- The RACERS-only entries go when the step is left.
local function clearRacersPill()
    if not W.pill then return end
    W.pillReady, W.pillJoin = nil, nil
    W.pill.clear("allready")
    W.pill.clear("join")
    W.pill.clear("gate")
end

---------------------------------------------------------------------------------------------------- v2 navigation
-- P1 reaches BACK with Down from the lowest focus targets (§6.4: an explicit rule from those ghosts to BACK's).
local function navRules(step, view)
    local back, th = W.back, T()
    if not U.ok(back) then return end
    if view == "posters" and W.posters then
        local n = math.min(#S.items, 4)
        for i = 1, 4 do navReset(W.posters[i]) end
        if step == "mode" then
            if n > 0 then th.nav(W.posters[n], "down", back) end
            local V2 = W.views.mode
            gridNav(V2 ~= nil and V2.gridOn == true)
        else
            for i = 1, n do th.nav(W.posters[i], "down", back) end
        end
    elseif view == "list" then
        local last
        for i, g in ipairs(W.opts) do
            navReset(g, { 3 })
            if W.optMap and W.optMap[i] ~= nil then last = g end
        end
        if last then th.nav(last, "down", back) end
    elseif view == "cmap" and CM and type(CM.navDown) == "function" then
        pcall(CM.navDown, back)
    end
end

---------------------------------------------------------------------------------------------------- v2 step
function v2.showStep(step)
    if step ~= "vehicles" then
        racersLeave("step " .. step)                       -- 0.10.0: the cards' images first, then their bays
        releasePreviews("step " .. step)
    end
    S.step, S.page, S.lastFocus, S.previewed, S.focusMode = step, 0, nil, nil, nil
    local veh = step == "vehicles"
    S.cards = veh and cardsWanted() and cardsReady()
    local sel, view = 1, nil
    if veh then
        view = S.cards and "cards" or "columns"
    else
        sel = STEPS[step]() or 1
        if step == "planet" or step == "track" then
            view = (CM and CM.usable(step) and #S.items > 0) and "cmap" or "list"
        else
            local most = (step == "cond") and 3 or 4         -- CONDITIONS: up to 3 posters beside the detail column
            view = (#S.items <= most and v2.ensureView(POSTER_KIND[step])) and "posters" or "list"
        end
        if view == "list" and not v2.ensureView("list") then
            U.err(TAG, "%s step: no view could be built (see the log above)", tostring(step))
        end
    end
    S.view = view
    if CM then pcall(CM.setView, view == "cmap" and step or nil) end
    if view == "cmap" and step == "track" then M.stopVideo("run map") end   -- the run map has no video area
    setBackground((step == "planet" and view == "cmap") and "map" or "hub")
    showViews(step, view)
    local target
    if veh then
        M.stopVideo("vehicles step")
        S.builds = V.builds(S.cls.arch)
        S.startConfirmUntil, S.startDormant = 0, nil
        W.pillJoin = nil
        if S.cards then target = enterCards() end
        if not S.cards then                                -- classic columns (the cards failed just now or before)
            S.view = "columns"
            show(W.cardBox, false)
            show(W.sinkHost, false)
            if v2.ensureVehRow() then
                show(W.vehRow, true)
                renderColumns()
                target = W.cols[1] and W.cols[1].vehCy and W.cols[1].vehCy.m or nil
            end
        end
    else
        clearRacersPill()
        if view == "cmap" then
            local okC, t = pcall(function()
                if step == "planet" then return CM.showPlanets(S.planets, sel) end
                return CM.showTracks({ planet = S.planet, tracks = S.tracks, sel = sel, isPod = S.cls.arch == 1 })
            end)
            if okC and U.ok(t) then
                target = t
            else
                pcall(CM.markBroken, step, okC and "no focus target" or t)
                view = "list"
                S.view = "list"
                pcall(CM.setView, nil)
                setBackground("hub")
                if v2.ensureView("list") then showViews(step, view) end
            end
        end
        if view == "posters" then target = renderPosters(step, sel) end
        if view == "list" then
            fillOptions()
            target = optionFor(sel) or W.back
        end
        if S.items[sel] then
            U.try(TAG, S.items[sel].preview)
            S.previewed = sel
        end
        navRules(step, view)
        if step == "class" and (S.planet or S.track) then  -- §6.5 (normal, 5 s)
            pillFeed("CHANGING THE CLASS RESETS PLANET AND TRACK", { key = "classreset" })
        end
    end
    v2.renderSteps()
    v2.renderCommands()
    M.focus(target)
    if U.ok(target) then v2.noteFocus(target) end
    U.dbg(TAG, "step %s (%d items, %s, UI v2)", step, #S.items, tostring(S.view))
end

-- FAST (pollNav, every step): the command row's slots by P1's input mode and its painted focus, the status pill's
-- timers, the painted focus of the posters / rows / GRID row, the condition tints.
function v2.poll(p1)
    if not (W and W.v2 and S.active) then return end
    v2.renderCommands()
    if W.cmd then W.cmd.poll(p1) end
    if W.pill then W.pill.tick() end
    if S.view == "posters" then
        paintPosters()
        if S.step == "mode" then paintGrid() end
        if S.step == "cond" then tintTick() end
    elseif S.view == "list" then
        paintRows()
    end
end

-- theme.forget (a phase other than FRONTEND / LAUNCHING / TRANSIT) kills every element of the page even when menu_tab
-- keeps that page: T.set on a dead element returns nil. M.open rebuilds such a page.
function v2.alive()
    if not (W and W.v2) then return true end
    local probe = (W.bg and (W.bg.hub or W.bg.map)) or (W.title and W.title.e)
    if not probe then return true end
    return T().set(probe, {}) ~= nil
end

function v2.onOpen()
    v2.measure("open")
    W.cmdForced, W.cmdSS, W.cmdSig, W.pillReady, W.pillJoin, W.bgKind = nil, nil, nil, nil, nil, nil
    if W.pill then W.pill.clear() end
end

function v2.onClose()
    if W.cmdForced and W.cmd then W.cmd.look(W.cmdForced, nil) end
    W.cmdForced, W.cmdSS, W.cmdSig, W.pillReady, W.pillJoin = nil, nil, nil, nil, nil
    if W.pill then W.pill.clear() end
end
end   -- of the UI v2 block (v2.* and pillFeed are what the rest of the file uses)

function M.showStep(step)
    if not W or not STEPS[step] and step ~= "vehicles" then return end
    if W.v2 then return v2.showStep(step) end              -- 0.12.0 UI v2 page
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
            return U.mod("perkapply").launchBase(S.cls.arch, p1 and p1.pilotId or nil, M.aiTierPath())
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
                grid = S.mode.grid, maxRacers = S.grid, flow = S.cards and "cards" or "classic", players = {},
                aiTierPath = S.cards and M.aiTierPath() or nil }   -- 0.12.0 "Opponents" (cards flow; classic: own builds)
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
    -- 0.12.0: an opponents' tier build (RACE SETUP > MODE "Opponents") is a cards base too
    if tonumber(arch) ~= 1 then
        local okL, list = pcall(V.builds, arch)
        if okL and type(list) == "table" then
            for _, b in ipairs(list) do if b.path == path then return true end end
        end
    end
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
    -- 0.13.0 QUICK RACE: the saved codes are the players' own builds; the launch forces copies (quick.forcePlan)
    s.flow, s.players = "cards", players
    s.aiTierPath = M.aiTierPathFor(cls.arch)               -- 0.12.0: the Opponents setting (nil = TIER 1 / pods)
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
    -- 0.12.0: cfg.UiStyle switched live since this page was built (spec §13 session I): the other page is built first
    if W and not W.broken and not S.active and W.v2 ~= wantV2() and W.root ~= nil then
        U.log(TAG, "UiStyle is \"%s\" now: the race setup page is rebuilt in that style",
            tostring(opt("UiStyle", "v2")))
        U.try(TAG, v2.rebuild, "UiStyle")
    elseif W and W.v2 and not W.broken and not S.active and not v2.alive() then
        U.warn(TAG, "the v2 page's theme elements were dropped (theme.forget on a phase change): the page is rebuilt")
        U.try(TAG, v2.rebuild, "theme elements dropped")
    end
    if not M.available() then return false end
    if St.phase ~= "FRONTEND" then status("RACE SETUP ONLY WORKS IN THE MAIN MENU"); return false end
    if St.launch.pending then status("LAUNCHING…"); return false end
    if S.choiceSeen ~= St.race.choice then preselect(); S.choiceSeen = St.race.choice end
    S.active = true
    S.players = {}
    local lobby = U.mod("lobby")
    if type(lobby.setSetupMode) == "function" then lobby.setSetupMode(true) end
    if W.v2 then U.try(TAG, v2.onOpen) end                 -- 0.12.0: page moved? pill and command focus reset
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
    if W and W.v2 then U.try(TAG, v2.onClose) end            -- 0.12.0: the pill's entries and the command focus go
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
            -- 0.12.0 v2: the warn pill, over every other entry for the gate's 5-s window (§6.5, §6.6)
            status(gateText(waiting, dormant), { warn = true, prio = 3, key = "gate", ms = 5000 })
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

-- lobby.setStatus (every St.emit("status")) and racers. 0.12.0 v2 page: the status pill (§6.5); opts = {warn, sticky,
-- prio, key, ms, pips} as theme's statusPill post (text "" + key: that entry cleared), nil = classified by the text.
function M.setStatus(text, opts)
    if not (W and S.active) then return end
    if W.v2 then pillFeed(text, opts) else setText(W.status, text or "") end
end

-- 0.12.0 v2: one keyed status-pill entry removed (nil = every entry).
function M.clearStatus(key)
    if W and W.v2 and W.pill and S.active then W.pill.clear(key) end
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
-- 0.12.0: undebounced as before; setup.debugInputMode pins it (tests) like theme.inputMode.
local forcedMode = nil
function M.p1Gamepad()
    if forcedMode then return forcedMode == "pad" end
    return gamepadInput()
end

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
    if W.v2 then
        v2.noteFocus(f)                                      -- 0.12.0: BACK's Up rule follows the content focus
        if S.view == "posters" and W.posters then            -- a poster ghost: preview its item (painted by v2.poll)
            for i, g in ipairs(W.posters) do
                if U.same(g, f) then
                    local idx = W.posterMap and W.posterMap[i]
                    if idx and idx ~= S.previewed and S.items[idx] then
                        S.previewed = idx
                        U.try(TAG, S.items[idx].preview)
                    end
                    return
                end
            end
        end
    end
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
local p1BackMs = -1e12
-- P1's back step itself: the card's stage before (RACERS), else one setup step back. Also called by backprompt.lua
-- when P1's B only reached the game (its QuitGame prompt), so it is exported as M.p1Back.
local function p1Back(why)
    p1BackMs = St.nowMs()
    if cardsStep() then racers().onP1Back() else M.back() end
    U.dbg(TAG, "P1 back (%s)", tostring(why or "pad B"))
end
function M.p1Back(why) if M.isActive() then p1Back(why) end end
-- backprompt.lua: when the last P1 back step ran (St.nowMs), so a B both polls saw is never stepped back twice
function M.lastP1BackMs() return p1BackMs end

local function pollP1Back(p1)
    local down = ui().keyDown(p1, C.KEY.B)
    local kbp1 = false
    pcall(function() kbp1 = require("settings").get("KeyboardIsP1") == true end)
    if down and not p1BPrev and not kbp1 then
        pcall(function() U.mod("lobby").armBackGuard() end)   -- the game may also open its Back prompt
        p1Back("pad B")
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
        if M.isActive() and W.v2 then U.tryEvery("setup.v2", nil, TAG, v2.poll, p1) end   -- 0.12.0: command row, pill
        return
    end
    if U.ok(p1) then
        local f = focusedWidget(p1)
        if f ~= S.lastFocus then onFocus(f) end
        U.try(TAG, pollP1Back, p1)
    end
    if M.isActive() and W.v2 then U.tryEvery("setup.v2", nil, TAG, v2.poll, p1) end   -- 0.12.0: painted focus looks
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
    if W.v2 then U.try(TAG, v2.measure, "page shown") end   -- 0.12.0: the page may sit elsewhere now (V-FIN-01)
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

---------------------------------------------------------------------------------------------------- 0.12.0 API
-- A / a click on poster ghost i (CLASS / CONDITIONS / MODE on the v2 page): the same as a list row's click.
function M.onPoster(i)
    if not M.isActive() or not W.posterMap then return end
    local idx = W.posterMap[i]
    local it = idx and S.items[idx]
    if it then
        S.previewed = idx
        U.try(TAG, it.preview)
        U.try(TAG, it.choose)
    end
end

-- racers.lua (§6.4): P1's READY cursor with mouse + keyboard ("start" | "save") paints that command-row pill as
-- focused (keyboard Up / Down; Enter runs it through racers -> setup.finish); nil releases it. -> true on a v2 page.
function M.commandFocus(id)
    if not (W and W.v2 and W.cmd) then return false end
    if id ~= "start" and id ~= "save" then id = nil end
    if W.cmdForced == id then return true end
    if W.cmdForced then W.cmd.look(W.cmdForced, nil) end
    W.cmdForced = id
    if id then W.cmd.look(id, "focus") end
    return true
end

-- Test helper (§13): P1's input mode pinned to "pad" or "mouse" (nil = live) for the command row, P1's READY card
-- (theme.forceInputMode, which racers reads) and setup.p1Gamepad. -> summary text.
-- Example: lua return require("setup").debugInputMode("mouse")
function M.debugInputMode(mode)
    if mode ~= "pad" and mode ~= "mouse" then mode = nil end
    forcedMode = mode
    local ok, r = pcall(function() return T().forceInputMode(mode) end)
    if W and W.v2 and S.active then U.try(TAG, v2.renderCommands) end
    U.log(TAG, "input mode %s (test helper, V-FIN-11)", mode and ("forced: " .. mode) or "live")
    return string.format("debugInputMode: %s (theme: %s)", tostring(mode or "live"), ok and tostring(r)
        or ("error: " .. tostring(r)))
end

-- lobby.lua (§4.2 RACE card): the art of a race choice (St.race.choice): the chosen track's Arcade tile (TRACK_TILE,
-- also through a folded twin), else the planet x class tile (setup.arcadeTile); nil without a choice / planet.
-- Memoised per choice table (the lobby asks on every refresh); game thread (reads the choice's assets).
local raceArtMemo = { choice = nil, path = nil }
function M.raceArt(choice)
    if type(choice) ~= "table" then return nil end
    if raceArtMemo.choice == choice and raceArtMemo.path then return raceArtMemo.path end
    local path
    local ok, err = pcall(function()
        local cls
        if type(choice.setup) == "table" and choice.setup.arch ~= nil then cls = V.classByArch(choice.setup.arch) end
        if not cls and U.ok(choice.archetype) then cls = V.classByArch(tonumber(choice.archetype.Archetype)) end
        local planet = M.planetFor(choice.planet)
        local key = U.ok(choice.track) and trackKey(choice.track) or ""
        local tile = TRACK_TILE[key]
        if not tile and key ~= "" and cls and planet then
            for _, e in ipairs(queryTracks(cls, planet) or {}) do
                local hit = e.key == key
                for _, a in ipairs(e.alts or {}) do hit = hit or a.key == key end
                if hit then
                    tile = TRACK_TILE[e.key]
                    for _, a in ipairs(e.alts or {}) do tile = tile or TRACK_TILE[a.key] end
                end
            end
        end
        if tile then path = tp("Arcade", "T_UI_Arcade_" .. tile .. "_Tile")
        elseif planet then path = M.arcadeTile(planet, cls) end
    end)
    if not ok then U.logOnce("setup.raceArt!", TAG, "raceArt failed (%s)", tostring(err)) end
    if path then raceArtMemo = { choice = choice, path = path } end
    return path
end

-- Test helper (test.cmd lua, only with cfg.TestCommands; vehicle-step-v2.md §10): a fresh setup visit straight to a
-- step with these picks. spec = {class = vehicles.CLASSES key ("Car" default, "Bike", "Skimmer", "Plane"), planet =
-- PLANETS key ("Mastiff" default = JAKKU, "Beagle" = TATOOINE, ...), track = TrackDef key (default: the planet's
-- first track for the class), mode = MODES key ("race" default, "fullgrid", "mixed", "eliminator"), step = the step
-- to show ("vehicles" default)}. The track's default condition and the class's full grid are taken. -> summary text.
-- Example: lua return require("setup").debugJump{class = "Car", planet = "Mastiff", step = "vehicles"}
-- 0.13.0 GALAXY RUN (run.lua): every valid race of a class for the run's picks: {planet = key, track = key, path,
-- conds, modes = {mode keys}} (the same pools / exclusions as the PLANET and TRACK steps).
function M.runCandidates(classKey)
    local cls = V.classByKey(classKey or "Car")
    if not cls then return {} end
    local out = {}
    for _, pe in ipairs(planetsFor(cls)) do
        local p = pe.planet
        for _, e in ipairs(pe.tracks or {}) do
            local modes = {}
            for _, m in ipairs(modesFor(cls, e)) do modes[#modes + 1] = m.key end
            local path = nil
            pcall(function() path = e.obj:GetFullName() end)
            out[#out + 1] = { planet = p.key, track = e.key, path = path or e.key, conds = e.conds or {}, modes = modes,
                              name = e.name, planetName = p.name }
        end
    end
    return out
end

-- The body of debugJump (also run.lua's next race): opens the setup on {class, planet, track, mode, cond} at step.
local jumpTo

function M.debugJump(spec)
    if cfg.TestCommands ~= true then return "debugJump: needs cfg.TestCommands = true" end
    return jumpTo(spec)
end

-- 0.13.0: the GALAXY RUN's next race on the racer cards (FREE MODE START between run races). true when open there.
function M.openRun(spec)
    if type(spec) ~= "table" then return false end
    local r = jumpTo({ class = spec.class, planet = spec.planet, track = spec.track, mode = spec.mode or "race",
                       cond = spec.cond, step = "vehicles" })
    U.log(TAG, "GALAXY RUN next race: %s", tostring(r))
    return S.active == true and S.step == "vehicles"
end

jumpTo = function(spec)
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
    for _, cnd in ipairs(track.conds or {}) do if spec.cond and cnd == spec.cond then S.cond = cnd end end
    S.gridTouched = false
    S.grid = math.max(humansCount(), V.maxRacers(cls))
    M.showStep(step)
    return string.format("debugJump: %s / %s / %s%s / %s -> step %s%s (%s)", cls.key, planet.key, tostring(track.key),
        S.cond ~= "" and (" [" .. S.cond .. "]") or "", mode.key, tostring(S.step),
        S.step == "vehicles" and (S.cards and " RACERS" or " classic") or "", tostring(St.menu.visible))
end

-- 0.12.0 v2: every St.emit("status") reaches the open page's status pill even when lobby.setStatus does not forward
-- it (when it does, the pill's echo filter drops the second copy). A classic page or a closed setup: nothing.
St.on("status", TAG, function(text) pillFeed(text, nil) end)

return M
