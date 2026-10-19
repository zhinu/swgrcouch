-- theme.lua (G3 Front-end UI, 0.12.0 UI v2): the tokens and the shared chrome of the v2 pages (FREE MODE lobby, OPTIONS,
-- RACE SETUP, cmap, the RACERS card row). User request (workflow ui-v2, 2026-10-10): screens that "look like they belong
-- to the game". Binding spec: notes/design/ui-v2/ui-redesign-final.md §2 (tokens), §3 (this API, components C1-C12),
-- §12.3 (config), §14 (V-FIN checks). lobby.lua, setup.lua, cmap.lua and cards2.lua build on this module; it depends on
-- no other UI module except ui.lua (ui.ghost, ui.hasFocus, ui.hovered: the one focus mechanism, §3.3).
--
-- API (§3.2). Builder positions are SCREEN su (3840 x 2160) and are converted with the page geometry (§2.5); the
-- primitives T.text / T.image / T.set work in the LOCAL su of the canvas they were put on. Builders without a geo
-- parameter (poster, ghost, settingsRow, groupHeader, checkBadge, lockOverlay, detailColumn) convert with opts.geo,
-- else with the geometry of the last T.pageGeometry call (pass opts.geo = {x = 0, y = 0} for canvas-local positions).
-- ctx = {tree = page.WidgetTree, pc = owning PlayerController, newW = setup.lua's constructor (optional)}.
--   tokens    T.COL[name]                -- §2.1 linear colours {R, G, B, A}; canonical tables, never modified
--             T.alpha(col, a) -> col     -- memoised copy with alpha a (identity-stable: the diffed setters compare it)
--             T.hex("#RRGGBB", a) -> col -- sRGB hex -> linear colour (memoised)
--             T.PLAYER[pnum]             -- = C.COLOURS[pnum] (planet hues, §2.2; Remote = WHITE)
--             T.PLANET[key]              -- planet tone by setup.PLANETS key ("Mastiff" -> apricot ...); T.planet(keyOrName)
--             T.ROLE[name]               -- §2.3 {font, face, size, ls, material, colour, upper, wrapW, lineH, justify}
--             T.FRAME                    -- §2.5 numbers (titleCap, steps, content, cmd, pill, cardRow, page fallback)
--             T.TEX[name], T.MAT[name], T.WBP[name], T.FONT[name]   -- every object path of §3.4
--             T.glyph(key) -> path       -- Xbox pad glyph ("A", "B", "FaceButton_Bottom", "Gamepad_DPad_Up", ...)
--             T.textWidth(s, role, size) -> su   -- estimate from the game fonts' advance widths (no FGeometry in Lua)
--   geometry  T.pageGeometry(root) -> geo {x, y, w, h, src, screen = {x, y, w, h}, cmdY, cardH}; every page show
--             T.toLocal(geo, x, y) -> lx, ly
--   prims     T.text(ctx, cv, role, opts) -> e   opts {text, size, colour, ls, wrapW, justify "l"|"c"|"r", upper,
--                                                       align = {ax, ay}, rect = {x, y[, w, h]}, z, visible}
--             T.image(ctx, cv, opts) -> e        opts {tex | mat, drawAs (1 Box, 3 Image, 4 RoundedBox), margin,
--                                                       size = n | {w, h} (brush ImageSize), radius, tint, align, rect,
--                                                       z, visible, opacity, flipX}
--             T.set(e, f) -> e                   diffed: f = {text, colour, tex, mat, rect = {x, y[, w, h]}, visible,
--                                                       opacity, scale, size (font), wrapW, align}
--   builders  T.pageBackground(ctx, cv, geo, kind) -> e              C1 kind "hub" | "map" (a group: T.set visible)
--             T.screenTitle(ctx, cv, geo, text) -> t                 C2 t.set(text), t.show(on)
--             T.stepRow(ctx, cv, geo) -> r                           C3 r.render{{label, state = "done"|"current"|"next"}}
--             T.commandRow(ctx, cv, geo, defs) -> c                  C4 c.show{back, start, save}; c.look(id, look);
--                                                                       defs {id, label, ghostId, fn, opts, rect (optional)}
--                                                                       c.poll(p1) -> paintedId; c.widget(id)
--             T.statusPill(ctx, cv, geo) -> p                        C5 p.post(text, {warn, pips, ms, sticky, prio, key});
--                                                                       p.clear([key]); p.tick(nowMs) -> text | nil
--             T.poster(ctx, cv, rect, opts) -> p                     C6 p.set(f); p.focus(on); p.cv (poster canvas)
--             T.ghost(ctx, cv, rect, id, fn, opts) -> w              C7 ui.ghost placed on cv (opts.nav explicit rules)
--             T.settingsRow(ctx, cv, rect, opts) -> r                C8 r.set{label, value, kind, on, focused, enabled}
--             T.groupHeader(ctx, cv, x0, x1, y, label) -> h          C9 h.set(label), h.show(on)
--             T.checkBadge(ctx, cv, opts) -> b                       C10 b.place(cx, cy, s) / b.hide()
--             T.lockOverlay(ctx, cv, opts) -> l                      C11 l.set(rect, reason | nil) / l.hide()
--             T.detailColumn(ctx, cv, x, y, w, opts) -> d            C12 d.set{aure, title, body, rich, foot}; d.bottom()
--   input     T.inputMode(now) -> "pad" | "mouse"   (P1's CommonInput type, stable for InputModeDebounceMs; KeyboardIsP1
--             = "mouse"); T.forceInputMode(mode | nil) (tests: setup.debugInputMode routes here so racers sees it too)
--   life      T.forget() (page died: every cached widget dropped; also on the "menu" event and when a race phase
--             starts); T.tick(now) (optional: drains the texture queue; the pills / command rows / T.set also drain it);
--             T.nav(w, dir, target); T.isFocused(w, p1) -> focused, hovered; T.status() -> text
-- Every builder returns nil and logs once when it cannot be built; every method is guarded (throttled error log).
--
-- Engine facts used here (and why):
--   * FGeometry has no reflected fields (notes/research/hud-narrow-views.md §6): GetCachedGeometry comes back as an empty
--     table, so pageGeometry's LocalToViewport route (V-FIN-01) is tried but cannot work in this UE4SS build; the page
--     rect is then read from the main menu's own layout (WS_ScreenContent's siblings: GetDesiredSize + slot paddings,
--     all reflected), else the constants 128 / 240 / 3584 / 1756 (UiPageOrigin overrides all of it).
--   * A struct PARAM table is zero-filled (ue4ss-api §8): Box / RoundedBox brushes go through UImage:SetBrush with a full
--     table (resource, ImageSize, DrawAs, Margin, white TintColor, ImageType FullColor); plain images use
--     SetBrushFromTexture / SetBrushFromMaterial, which keep the other brush fields.
--   * WrapTextAt has no UTextLayoutWidget setter: a property write before the add, later CommonTextBlock:SetWrapTextWidth
--     (cards.lua RC-3). LineHeightPercentage / ApplyLineHeightToBottomLine: property writes before the add (the game's
--     own FuseTextBlocks carry them), later SetLineHeightPercentage.
--   * Textures by hard path only (StaticFindObject, LoadAsset within a per-tick budget: one big >= CardLoadBigBytes, up
--     to CardLoadsPerTick small; cards.lua's queue pattern, RC-7 FName check); never a soft-pointer read.
-- VERIFY ids (§14): V-FIN-01 page geometry, V-FIN-02 page background, V-FIN-03 screen title, V-FIN-04 ghosts, V-FIN-11
-- input mode, V-FIN-12 status pill, V-FIN-16 command-row backer pill; V-PARTS-02 font materials, V-PARTS-08 SetBrush.

local C        = require("consts")
local cfg      = require("config")
local settings = require("settings")
local St       = require("state")
local U        = require("util")

local T = {}
local TAG = "theme"

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

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local function rnd(v) return floor(v + 0.5) end
local function nowMs() return St.nowMs() end

---------------------------------------------------------------------------------------------------- classes, enums
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local SIZE   = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" }
local HBOX   = { "/Script/Griffin.FuseHorizontalBox", "/Script/UMG.HorizontalBox" }
local VBOX   = { "/Script/Griffin.FuseVerticalBox", "/Script/UMG.VerticalBox" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local TEXT   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }
local RICH   = { "/Script/Griffin.FuseRichTextBlock", "/Script/UMG.RichTextBlock" }

local VIS = C.E.Vis
local DRAW = { box = 1, image = 3, rounded = 4 }       -- ESlateBrushDrawType Box 1, Image 3, RoundedBox 4
local CLIP = 1                                         -- EWidgetClipping ClipToBounds
local AL = { l = 1, t = 1, c = 2, r = 3, b = 3, fill = 0 }   -- EHorizontal/EVerticalAlignment
local JUST = { l = 0, c = 1, r = 2 }                   -- ETextJustify
local NAV = { left = 0, right = 1, up = 2, down = 3 }  -- EUINavigation

---------------------------------------------------------------------------------------------------- colours (§2.1)
-- Every colour is interned (one table per value) and derived colours (alpha) are memoised on it, so the diffed setters
-- compare colours by identity (cards.lua pattern) and a caller may hand over a new table each render.
local interned = setmetatable({}, { __mode = "k" })
local byValue, derived = {}, {}
local function canon(c)
    if type(c) ~= "table" then c = { R = 1, G = 1, B = 1, A = 1 } end
    local k = interned[c]
    if k then return k end
    local r, g, b, a = tonumber(c.R) or 1, tonumber(c.G) or 1, tonumber(c.B) or 1, tonumber(c.A) or 1
    local key = string.format("%.4f,%.4f,%.4f,%.4f", r, g, b, a)
    k = byValue[key]
    if not k then
        k = { R = r, G = g, B = b, A = a }
        byValue[key], interned[k] = k, k
    end
    interned[c] = k
    return k
end
local function alpha(c, a)
    c = canon(c)
    local d = derived[c]
    if not d then d = {}; derived[c] = d end
    local v = d[a]
    if not v then v = canon({ R = c.R, G = c.G, B = c.B, A = a }); d[a] = v end
    return v
end
local function lin(c) return { R = c.R, G = c.G, B = c.B, A = c.A } end      -- new table per call (UE4SS may keep it)
local function slate(c) return { SpecifiedColor = lin(c), ColorUseRule = 0 } end

local function s2l(v)                                                         -- sRGB channel (0..1) -> linear
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end
local hexCache = {}
function T.hex(h, a)
    local key = tostring(h) .. "@" .. tostring(a or 1)
    local c = hexCache[key]
    if c then return c end
    local s = tostring(h):gsub("^#", "")
    local r, g, b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
    if not (r and g and b) then return canon(nil) end
    c = canon({ R = s2l(r / 255), G = s2l(g / 255), B = s2l(b / 255), A = a or 1 })
    hexCache[key] = c
    return c
end
T.alpha = alpha

local function col(r, g, b, a) return canon({ R = r, G = g, B = b, A = a or 1 }) end
-- §2.1 (linear values from the spec table). Two-alpha tokens keep their first alpha here (TILE 1, SAGE 1, SHADOW
-- 0.30); the other one is T.alpha(T.COL.X, a) at the use site.
T.COL = {
    MENU        = col(0.7682, 0.7454, 0.6867),          -- #E3E0D8 main-menu field (game-owned)
    PAGE        = col(0.8148, 0.8070, 0.7529),          -- #E9E8E1 sub-page field; building wash @0.43
    WASH        = col(0.7157, 0.7084, 0.6514, 0.7),     -- #DCDBD3 the action bar's pill (game-owned)
    INK         = col(0.0160, 0.0160, 0.0152),          -- #222221 text on cream, titles, rules
    NEAR        = col(0.0070, 0.0070, 0.0070),          -- #141414 settings row labels
    GREY        = col(0.1301, 0.1301, 0.1221),          -- #656562 upcoming steps, idle state words
    BEIGE       = col(0.7758, 0.7305, 0.6654),          -- #E4DED5 text on the band, light poster titles
    CREAM       = col(1.0000, 0.8632, 0.6795),          -- #FFEFD7 numbers, check-badge fill
    WHITE       = col(1, 1, 1),                         -- focus rims, focused labels
    BORDER      = col(0.9131, 0.9216, 0.9047, 0.92),    -- #F5F6F4 poster / card border
    BONE        = col(0.6172, 0.5711, 0.5149),          -- #CEC7BE rail glyphs, lock icon
    MIST        = col(0.6038, 0.6240, 0.6445),          -- #CCCFD2 idle hero-pill labels
    BAND        = col(0.0273, 0.0595, 0.0666),          -- #2E4549 card band
    BAND_STRIPE = col(0.0091, 0.0194, 0.0242),          -- #18262B the scenario art's dark stripe
    TILE        = col(0.0137, 0.0382, 0.0482),          -- #1F373E focused pill (idle pills @0.9)
    PANEL       = col(0.0130, 0.0369, 0.0482, 0.9),     -- #1E363E WBP_DarkPanel MainPanelColor
    PANEL_DEEP  = col(0.0030, 0.0080, 0.0097, 0.95),    -- #0A1619 run-map detail card
    PETROL      = col(0.0015, 0.0395, 0.0685),          -- #05384A bar track
    RUST        = col(0.4397, 0.0823, 0.0452),          -- #B1513C the one accent (rule 3)
    AMBER       = col(0.7454, 0.4125, 0.0802),          -- #E0AC50 bar fill, pips, tag lines
    GOLD        = col(0.6240, 0.3515, 0.0762),          -- #CFA04E style names, keywords on the band
    SAGE        = col(0.3613, 0.4564, 0.3763),          -- #A2B4A5 section labels (style backer @0.2)
    CHAR        = col(0.0123, 0.0123, 0.0116),          -- #1D1D1C status pill, card toast
    STATUS      = col(0.6939, 0.6514, 0.5972),          -- #D9D3CB text on the pill, current step label
    CHEVRON     = col(0.6038, 0.3813, 0.3185),          -- #CCA699 chevron beside a RUST row pill
    TOGGLE      = col(0.4910, 0.0545, 0.0545),          -- #BA4242 settings toggle knob
    DEEP        = col(0.0052, 0.0232, 0.0307),          -- #102A31 titles on light poster art
    STUDIO      = col(0.7682, 0.7379, 0.6724),          -- #E3DFD6 photo-bay backdrop target
    ART_TEXT    = col(0.9301, 0.8796, 0.8632),          -- #F7F1EF tracked captions on Arcade art
    DETAIL_RISE = col(0.0395, 0.0762, 0.0844),          -- #384E52 risen detail card fill
    SHADOW      = col(0.0015, 0.0044, 0.0056, 0.30),    -- #050E11 poster / card shadow (focused @0.45)
    -- derived from §3.4 / §2.6 (not rows of §2.1)
    UNSELECT    = col(0.6514, 0.6445, 0.5647),          -- #D3D2C6 WBP_CommonButtonBacker_Pill ColorUnselect
    ART_IDLE    = col(0.7913, 0.7913, 0.7913),          -- #E6E6E6 idle poster art tint
    BLACK       = col(0, 0, 0),
}
local COL = T.COL
local TILE09 = alpha(COL.TILE, 0.9)

-- §2.2 player hues (consts.lua, read by nametags / roster / cards as well)
T.PLAYER = C.COLOURS

-- planet tones (PlanetsToColors, catalogue §5) by setup.PLANETS key
T.PLANET = {
    Mastiff   = col(0.7913, 0.3968, 0.1046),            -- JAKKU #E6A95B
    Beagle    = col(0.7913, 0.3968, 0.1046),            -- TATOOINE #E6A95B
    Dalmatian = col(0.4564, 0.5647, 0.1878),            -- LANTAANA #B4C678
    Husky     = col(0.6376, 0.5457, 0.1651),            -- SENTINEL I #D1C371
    Corgi     = col(0.2874, 0.5271, 0.4678),            -- ANDO PRIME #92C0B6
    Spaniel   = col(0.5906, 0.0931, 0.0931),            -- CRAIT #CA5656
    Whippet   = col(0.3813, 0.2961, 0.2961),            -- DERVEN ACOS #A69494
}
local PLANET_NAMES = { JAKKU = "Mastiff", TATOOINE = "Beagle", LANTAANA = "Dalmatian", ["SENTINEL I"] = "Husky",
                       ["ANDO PRIME"] = "Corgi", CRAIT = "Spaniel", ["DERVEN ACOS"] = "Whippet" }
-- Planet tone by key ("Mastiff"), PlanetDef name ("PLA_Mastiff") or display name ("Jakku"); nil when unknown.
function T.planet(k)
    if type(k) ~= "string" then return nil end
    local key = k:gsub("^PLA_", "")
    if T.PLANET[key] then return T.PLANET[key] end
    local n = PLANET_NAMES[string.upper(k)]
    return n and T.PLANET[n] or nil
end

---------------------------------------------------------------------------------------------------- asset paths (§3.4)
local TXR = "/Game/Griffin/UI/Library/Textures/"
local MTR = "/Game/Griffin/UI/Library/Materials/"
local WBR = "/Game/Griffin/UI/Widgets/"
local FNR = "/Game/Griffin/UI/Library/Fonts/"
local function obj(dir, n) return dir .. n .. "." .. n end

T.TEX = {
    MainMenuBg    = obj(TXR .. "Backgrounds/", "T_UI_MainMenu_Bg"),        -- C1 hub
    MapBg         = obj(TXR .. "Backgrounds/", "T_UI_Map_Bg"),             -- C1 map
    ScenarioBg    = obj(TXR .. "Backgrounds/", "T_UI_Scenario_Bg"),
    MapEventBg    = obj(TXR .. "Backgrounds/", "T_UI_MapEvent_Bg"),
    SolidFill     = obj(TXR .. "Common/", "T_UI_SolidFill_Cmn"),           -- C1 map strip, C11 dim
    CircleFill    = obj(TXR .. "Common/", "T_UI_CircleBig_Fill_Cmn"),      -- C5 done pip
    CircleFrame   = obj(TXR .. "Common/", "T_UI_CircleIconFrame_Cmn"),     -- C5 pending pip
    GradientV     = obj(TXR .. "Common/", "T_UI_Gradient_Vertical_A_Cmn"), -- C6 fade
    TileStroke    = obj(TXR .. "Common/", "T_UI_FE_TileStroke_UnSelect_Cmn"), -- C6 border
    SettingFill   = obj(TXR .. "Common/", "T_UI_Squircle_Setting_Fill_Cmn"),  -- C8 toggle body
    SettingHandle = obj(TXR .. "Common/", "T_UI_Squircle_Setting_Handle_Cmn"), -- C8 toggle knob
    Divider       = obj(TXR .. "Common/", "T_UI_Line_Divider_Hor_Cmn"),    -- C9, C12 rules
    TileFill300   = obj(TXR .. "Common/", "T_UI_FE_TileButton_300_Fill_Cmn"),   -- C10 fallback backer
    TileSelect300 = obj(TXR .. "Common/", "T_UI_FE_TileButton_300_Select_Cmn"),
    TileFill200   = obj(TXR .. "Common/", "T_UI_FE_TileButton_200_Fill_Cmn"),
    ModalInner    = obj(TXR .. "Common/", "T_UI_Modal_Panel_Inner_Cmn"),
    Tick          = obj(TXR .. "Icons/", "T_UI_Tick_Icn"),                 -- C3 done, C10
    ArrowB        = obj(TXR .. "Icons/", "T_UI_Arrow_B_Icn"),              -- C8 chevron + cycle arrows (points left)
    Lock          = obj(TXR .. "Icons/", "T_UI_Lock_Icn"),                 -- C11
    Player        = obj(TXR .. "Icons/", "T_UI_Player_Icn"),
    Star          = obj(TXR .. "Icons/", "T_UI_Star_Icn"),
    ScenarioEmpty = obj(TXR .. "Content/Scenarios/", "T_UI_FE_Scenario_000_Empty_Tile"),
    LobbyStart    = obj(TXR .. "Content/MainMenu/", "T_UI_FE_Tile_03"),           -- §4.2 START
    LobbyPlayers  = obj(TXR .. "Content/MainMenu/", "T_UI_FE_Tiles_MP_Custom_01"), -- §4.2 PLAYERS
    LobbyOptions  = obj(TXR .. "Content/MainMenu/", "T_UI_Difficulty_Tile_04"),    -- §4.2 OPTIONS
    TitleBarcode  = obj(TXR .. "Decorative/", "T_UI_ScreenTitles_Barcode_01"),     -- C2 text fallback tag
    TitleLayer    = obj(TXR .. "Decorative/", "T_UI_ScreenTitles_02_Layer01"),
}
local TEX = T.TEX

T.MAT = {
    DialRight      = obj(MTR .. "Common/", "MI_UI_Background_Dial_Right"),        -- C1 hub dial art
    Tab            = obj(MTR .. "Common/", "MI_UI_Tab"),                          -- C3 step pill, C5 capsules
    Pill           = obj(MTR .. "Common/", "MI_UI_Pill_Generic"),                 -- C5, C8 focus pill, C4 fallback
    PillHero       = obj(MTR .. "Common/", "MI_UI_Pill_Btn_Hero"),                -- C4 fallback idle inner line
    PillHeroFill   = obj(MTR .. "Common/", "MI_UI_Pill_Btn_Hero_Fill"),
    PillHeroThick  = obj(MTR .. "Common/", "MI_UI_Pill_Btn_Hero_Thick"),          -- C4 fallback focus rim
    BlurShadow     = obj(MTR .. "Common/", "M_UI_Blur_Shadow_A"),                 -- C6 shadow
    EquipBacker    = obj(MTR .. "Common/", "MI_UI_Squircle_FE_EquipBacker"),      -- C10
    CurrencyBacker = obj(MTR .. "Common/", "MI_UI_Squircle_FE_Section_CurrencyBacker"), -- P-tag, C2 fallback tag
    CardStroke     = obj(MTR .. "Common/", "MI_UI_Squircle_Card_Stroke_Ability"),
    ProfilePicture = obj(MTR .. "Common/", "M_UI_CharacterProfilePicture"),
    TextureMask    = obj(MTR .. "RetainerBox/", "MI_UI_Squircle_TextureMask"),
    FontTitle      = obj(MTR .. "Common/", "MI_UI_SDF_Font_Title"),
    FontButtons    = obj(MTR .. "Common/", "MI_UI_SDF_Font_FE_Buttons"),
    FontClean      = obj(MTR .. "Common/", "MI_UI_SDF_Font_TitleClean"),
}
local MAT = T.MAT

local function bp(key, dir, n) return (C.BP and C.BP[key]) or (WBR .. dir .. n .. "." .. n .. "_C") end
T.WBP = {
    ScreenTitle      = bp("ScreenTitle", "Decorative/", "WBP_Screen_Title"),
    ButtonBackerPill = bp("ButtonBackerPill", "Buttons/", "WBP_CommonButtonBacker_Pill"),
    VehicleTrait     = bp("VehicleTrait", "Vehicle/", "WBP_VehicleTrait"),
    SectionSubLabel  = bp("SectionSubLabel", "Global/", "WBP_SectionSubLabel"),
    DarkPanel        = bp("DarkPanel", "Decorative/", "WBP_DarkPanel"),
    TooltipHolder    = bp("TooltipHolder", "Decorative/", "WBP_Tooltip_Holder"),
    CommonBtn        = bp("CommonBtn", "Buttons/", "WBP_Common_Btn"),
}

T.FONT = {
    display        = obj(FNR, "Font_Display"),         -- Moki ("Bold")
    body           = obj(FNR, "Font_Body"),            -- Overpass ("Semibold", "Semibold Italic", "Medium", ...)
    deco           = obj(FNR, "Font_Decorative"),      -- "Aurebesh"
    richBody       = obj(FNR, "DT_RichText_Body"),
    richDarkItalic = obj(FNR, "DT_RichText_Body_Dark_Italic"),
}

---------------------------------------------------------------------------------------------------- type roles (§2.3)
-- The SDF title / button materials go with bMaterialIsStencil = true (the game's own text blocks); TitleClean without.
local STENCIL = { [MAT.FontTitle] = true, [MAT.FontButtons] = true }
local function role(font, face, size, colour, x)
    local r = { font = font, face = face, size = size, ls = 0, colour = colour, upper = false }
    for k, v in pairs(x or {}) do r[k] = v end
    return r
end
local D, B, A = T.FONT.display, T.FONT.body, T.FONT.deco
T.ROLE = {
    pageTitle     = role(D, "Bold", 103.5, COL.INK, { material = MAT.FontTitle, upper = true }),
    detailTitle   = role(D, "Bold", 90, COL.INK, { material = MAT.FontTitle, upper = true, lineH = 0.85 }),
    posterTitle   = role(D, "Bold", 60, COL.BEIGE, { material = MAT.FontButtons, upper = true, lineH = 0.78,
                                                     sizes = { 69, 60, 54, 48, 42 } }),   -- DEEP on light art
    posterKicker  = role(B, "Medium Italic", 33, COL.ART_TEXT),
    posterDesc    = role(B, "Medium Italic", 30, COL.BEIGE),
    artCaption    = role(B, "Medium", 27, COL.ART_TEXT, { upper = true, ls = 300 }),       -- CLASS: LS 200
    planetLine    = role(D, "Bold", 37.5, COL.BEIGE, { upper = true, sizes = { 37.5, 30 } }), -- colour: planet tone
    stepLabel     = role(D, "Bold", 34.5, COL.INK, { upper = true }),     -- INK done, STATUS current, GREY next
    heroLabel     = role(D, "Bold", 39, COL.MIST, { material = MAT.FontTitle, upper = true, justify = "c",
                                                    focus = COL.WHITE, sizes = { 39, 33 } }),
    statusText    = role(D, "Bold", 39, COL.STATUS, { upper = true, sizes = { 39, 30 } }), -- WHITE on the warn pill
    groupHeader   = role(D, "Bold", 42, COL.INK, { upper = true }),
    rowLabel      = role(B, "Semibold", 35, COL.NEAR, { focus = COL.WHITE }),
    rowValue      = role(B, "Bold", 33, COL.INK, { upper = true, focus = COL.WHITE }),
    rowState      = role(B, "Bold", 29, COL.GREY, { upper = true, focus = COL.WHITE }), -- toggle state words
    helpText      = role(B, "Semibold", 30, COL.INK),                     -- keywords RUST (rich text)
    helpFoot      = role(B, "Semibold Italic", 30, COL.INK),
    cardName      = role(D, "Bold", 69, COL.WHITE, { material = MAT.FontClean, upper = true, sizes = { 69, 55.5, 45 } }),
    modelTitle    = role(D, "Bold", 45, COL.WHITE, { upper = true, sizes = { 45, 36 } }),
    modelTileName = role(B, "Semibold Italic", 30, alpha(COL.NEAR, 0.92), { upper = true, justify = "c" }),
    styleName     = role(D, "Bold", 45, COL.GOLD, { upper = true, sizes = { 45, 39, 36 }, min = 33 }),
    subLabel      = role(D, "Bold", 30, COL.SAGE, { upper = true }),      -- 27 in the PERKS board
    rank          = role(B, "Medium", 27, alpha(COL.BEIGE, 0.78), { upper = true, ls = 300 }),
    traitTitle    = role(B, "Semibold", 28.5, COL.SAGE, { upper = true, ls = 240 }),   -- N: LS 200
    body          = role(B, "Medium Italic", 30, COL.BEIGE),              -- keywords GOLD, line pitch 46
    tag           = role(B, "Medium", 27, COL.AMBER, { upper = true, ls = 200 }),
    value         = role(D, "Bold", 30, COL.CREAM, { upper = true }),
    hint          = role(B, "Semibold Italic", 30, COL.BEIGE),            -- NEAR on the page
    aure          = role(A, "Aurebesh", 18, COL.INK, { upper = true, ls = 200 }),
    lockReason    = role(B, "Semibold Italic", 30, COL.BEIGE),            -- C11
}
local ROLE = T.ROLE

local function roleOf(r)
    if type(r) == "table" then return r end
    local x = ROLE[r]
    if x then return x end
    U.logOnce("theme.role?" .. tostring(r), TAG, "unknown type role '%s': helpText used", tostring(r))
    return ROLE.helpText
end

---------------------------------------------------------------------------------------------------- frame (§2.5)
T.FRAME = {
    screen   = { w = 3840, h = 2160 },
    page     = { x = 128, y = 240, w = 3584, h = 1756 },     -- fallback page geometry (before captures, V-FIN-01)
    margin   = { l = 128, r = 3712 },
    titleCap = 285, titleX = 128, titleBox = { w = 2700, h = 150, capOffset = 36 },   -- C2 (V-FIN-03)
    steps    = { x = 128, y = 420, h = 72, gap = 56, pad = 36, cap = 720, minCap = 300, tick = 30, tickGap = 10, n = 6 },
    content  = { y0 = 540, y1 = 1856 },
    cmd      = { y = 1880, h = 96, right = 3712, gap = 32, slots = {
                   back = { 3292, 1880, 420, 96 }, start = { 2660, 1880, 600, 96 }, save = { 1928, 1880, 700, 96 } } },
    pill     = { x = -90, cy = 2079, h = 120, h2 = 168, wrap = 1700, capsules = 5, page = { x = 128 } },
    cardRow  = { x = 128, y = 548, w = 3584, h = 1300, one = 1039, W = 1762, M = 1162, N = 860,
                 gap = { W = 60, M = 49, N = 48 } },
    sink     = { x = 1800, y = 1880, w = 96, h = 96 },
}
local FRAME = T.FRAME

---------------------------------------------------------------------------------------------------- glyphs
local GLYPH_KEYS = {}
for _, k in ipairs({ "Dpad_Bottom", "Dpad_Left", "Dpad_Right", "Dpad_Top", "FaceButton_Bottom", "FaceButton_Left",
                     "FaceButton_Right", "FaceButton_Top", "ShoulderLeft", "ShoulderRight", "Special_Left",
                     "Special_Right", "Stick_LeftButton", "Stick_Left", "Stick_RightButton", "Stick_Right",
                     "TriggerLeft", "TriggerRight" }) do GLYPH_KEYS[k] = true end     -- asset-list.txt (Platform/Xbox)
local GLYPH_ALIAS = { A = "FaceButton_Bottom", B = "FaceButton_Right", X = "FaceButton_Left", Y = "FaceButton_Top",
                      START = "Special_Right", MENU = "Special_Right", VIEW = "Special_Left", BACK = "Special_Left",
                      SELECT = "Special_Left", LB = "ShoulderLeft", RB = "ShoulderRight", LT = "TriggerLeft",
                      RT = "TriggerRight", UP = "Dpad_Top", DOWN = "Dpad_Bottom", LEFT = "Dpad_Left",
                      RIGHT = "Dpad_Right", LS = "Stick_Left", RS = "Stick_Right", L3 = "Stick_LeftButton",
                      R3 = "Stick_RightButton", DPAD_UP = "Dpad_Top", DPAD_DOWN = "Dpad_Bottom",
                      DPAD_LEFT = "Dpad_Left", DPAD_RIGHT = "Dpad_Right", LEFTSHOULDER = "ShoulderLeft",
                      RIGHTSHOULDER = "ShoulderRight", LEFTTRIGGER = "TriggerLeft", RIGHTTRIGGER = "TriggerRight",
                      LEFTTHUMBSTICK = "Stick_LeftButton", RIGHTTHUMBSTICK = "Stick_RightButton" }
-- Texture path of an Xbox pad glyph: "A", "B", "START", "FaceButton_Bottom", "Gamepad_FaceButton_Bottom",
-- "Gamepad_DPad_Up" ... nil (logged once) for a key without a shipped glyph.
function T.glyph(key)
    if type(key) ~= "string" or key == "" then return nil end
    local k = key:gsub("^Gamepad_", "")
    if not GLYPH_KEYS[k] then k = GLYPH_ALIAS[string.upper(k)] or k end
    if not GLYPH_KEYS[k] then
        U.logOnce("theme.glyph?" .. key, TAG, "no pad glyph for key '%s'", key)
        return nil
    end
    return obj(TXR .. "Platform/Xbox/", "T_UI_Cntrl_XB_" .. k .. "_Icn")
end

---------------------------------------------------------------------------------------------------- text widths
-- Advance widths in 1/1000 em of the game's own faces (extracted Moki-Base and Overpass, PIL getlength at 1000 px):
-- ASCII 32..126, then U+00B7, U+2026, U+2019. Moki is measured upper-cased (it is always drawn ToUpper). em su =
-- font Size x 4/3 (UE sizes are points at the 3840 design). Proof: GRIFF HALLORAN at 55.5 su = 864 su (288 px at 720p,
-- language guide §1). Only for layout decisions Lua must take without FGeometry (step-row budget, rules after a label).
local ADV_SRC = {
    moki  = "400,396,418,822,869,1422,839,215,466,466,494,594,372,550,376,595,986,482,879,879,891,870,872,811,873,872,"
         .. "396,406,519,604,519,636,1224,935,910,848,971,862,885,945,932,346,514,892,809,1072,936,986,927,986,933,869,"
         .. "824,960,935,1255,917,886,896,466,595,466,630,816,217,935,910,848,971,862,885,945,932,346,514,892,809,1072,"
         .. "936,986,927,986,933,869,824,960,935,1255,917,886,896,553,346,553,851,316,1128,267",
    semi  = "245,291,430,696,598,858,700,235,362,362,546,639,241,410,237,512,652,391,612,600,636,614,608,532,623,608,"
         .. "237,237,639,639,639,512,826,704,679,642,701,616,570,684,714,292,554,692,564,808,715,725,636,725,682,608,"
         .. "596,704,672,845,653,670,643,387,512,387,639,494,0,547,572,528,572,551,352,572,582,273,273,550,281,866,582,"
         .. "564,574,572,408,484,388,582,542,737,557,555,530,380,291,380,639,0,1018,241",
    bold  = "250,300,442,702,604,852,710,245,372,372,552,636,249,414,243,522,658,400,612,600,642,611,614,536,629,614,"
         .. "243,243,636,636,636,510,834,717,690,638,710,624,574,682,721,296,558,708,566,810,718,722,638,723,690,614,"
         .. "602,712,682,848,678,684,639,393,522,393,636,496,0,557,577,542,577,557,362,578,592,283,283,559,291,876,592,"
         .. "566,578,578,416,492,392,592,558,748,577,568,544,384,301,384,636,0,1056,249",
    med   = "240,282,416,690,593,864,688,224,353,353,540,642,233,404,231,501,647,382,612,601,628,618,603,527,617,603,"
         .. "231,231,642,642,642,513,818,692,668,644,692,608,566,686,707,287,550,676,562,806,712,728,633,728,673,604,"
         .. "590,696,662,842,628,655,646,382,501,382,642,492,0,536,567,514,567,544,342,568,572,264,264,540,272,856,572,"
         .. "561,570,568,398,477,383,572,527,726,537,542,518,376,282,376,642,0,980,233",
    medi  = "232,276,401,668,576,838,660,220,345,345,524,625,230,396,228,486,604,346,574,563,584,585,567,490,580,567,"
         .. "228,228,625,625,625,501,788,658,634,615,664,576,540,654,674,269,522,644,534,770,678,691,605,691,642,576,"
         .. "562,664,632,802,593,622,612,373,486,373,625,492,0,519,542,488,540,520,324,542,547,250,254,511,258,822,548,"
         .. "532,546,543,388,454,358,548,504,693,517,520,491,368,276,368,625,0,890,230",
    semii = "237,283,414,672,579,830,673,228,352,352,528,620,235,398,231,494,608,356,571,560,592,576,568,493,581,568,"
         .. "231,231,620,620,620,499,796,669,643,614,669,578,540,654,678,270,526,656,531,770,678,692,609,692,648,580,"
         .. "567,670,639,805,617,635,612,376,494,376,620,494,0,522,542,498,538,526,328,542,551,254,257,519,262,828,551,"
         .. "534,546,542,394,458,362,551,512,700,532,529,496,370,283,370,620,0,934,235",
}
local ADV = {}
for k, s in pairs(ADV_SRC) do
    local t, sum, n = {}, 0, 0
    for v in s:gmatch("[^,]+") do t[#t + 1] = tonumber(v); end
    for i = 34, 59 do sum, n = sum + (t[i] or 0), n + 1 end      -- A-Z average for unknown characters
    t.avg = (n > 0) and (sum / n) or 600
    ADV[k] = t
end
local EXTRA_CP = { [0xB7] = 96, [0x2026] = 97, [0x2019] = 98 }
local FACE_KEY = { Bold = "bold", Semibold = "semi", Medium = "med", ["Medium Italic"] = "medi",
                   ["Semibold Italic"] = "semii" }
local function advTable(r)
    if r.font == T.FONT.display then return ADV.moki end
    return ADV[FACE_KEY[r.face] or "semi"] or ADV.semi
end

-- Estimated width (su) of s drawn in role r at size (default the role's size), tracking included.
function T.textWidth(s, r, size)
    s = tostring(s or "")
    if s == "" then return 0 end
    r = roleOf(r or "stepLabel")
    size = tonumber(size) or r.size
    local adv = advTable(r)
    if r.upper and adv ~= ADV.moki then s = string.upper(s) end
    local sum, n = 0, 0
    local function add(cp)
        local idx = (cp >= 32 and cp <= 126) and (cp - 31) or EXTRA_CP[cp]
        sum = sum + ((idx and adv[idx]) or adv.avg)
        n = n + 1
    end
    if not pcall(function() for _, cp in utf8.codes(s) do add(cp) end end) then
        sum, n = 0, 0
        for i = 1, #s do add(s:byte(i)) end                      -- invalid UTF-8: bytes
    end
    local em = size * 4 / 3
    local w = sum / 1000 * em + (r.ls or 0) / 1000 * em * max(0, n - 1)
    -- 0.12.0: cfg.UiMokiWidthScale (1.0) scales the Moki estimate. Live 2026-10-10 the table matched Slate at size 100
    -- (glyph x 10, within 4 %), but small text at 720p came out up to ~8 % wider ("TECH EXPERT" 27 su: 358 vs 331;
    -- glyph rounding at a low DPI scale): boxes sized from an estimate keep their own margin (cards2 TEXT_MARGIN).
    if adv == ADV.moki then w = w * (tonumber(cfg.UiMokiWidthScale) or 1.0) end
    return w
end

-- Debug only (lobby.debugCalibrate, test.cmd): the real advance of every printable ASCII glyph per role, measured by
-- Slate. Step 1 builds one off-screen text per glyph (the glyph x 10 at size 100) on cv; step 2, a few ticks later,
-- reads GetDesiredSize and returns the per-mille advances as an ADV_SRC line plus the worst ratios against the table.
function T.calibrate(ctx, cv, roles)
    local st = { roles = {}, at = nil }
    for _, rn in ipairs(roles or { "stepLabel" }) do
        local r = roleOf(rn)
        local list = {}
        for cp = 32, 126 do
            local ch = string.char(cp)
            local e = T.text(ctx, cv, rn, { text = string.rep(ch, 10), size = 100, ls = 0, rect = { 6000, 6000 } })
            list[#list + 1] = { cp = cp, e = e }
        end
        st.roles[#st.roles + 1] = { name = rn, role = r, list = list }
    end
    return st
end

function T.calibrateRead(st)
    local out = {}
    for _, R0 in ipairs(st.roles or {}) do
        local adv = advTable(R0.role)
        local em = 100 * 4 / 3
        local vals, worst = {}, {}
        for _, g in ipairs(R0.list) do
            local w = nil
            pcall(function() local d = g.e.t:GetDesiredSize(); w = tonumber(d.X) end)
            local pm = w and math.floor(w / 10 / em * 1000 + 0.5) or -1
            vals[#vals + 1] = tostring(pm)
            local tab = adv[g.cp - 31]
            if w and tab and tab > 0 then worst[#worst + 1] = { r = pm / tab, ch = string.char(g.cp) } end
        end
        table.sort(worst, function(a, b) return math.abs(a.r - 1) > math.abs(b.r - 1) end)
        local ws = {}
        for i = 1, math.min(8, #worst) do ws[i] = string.format("%s %.3f", worst[i].ch, worst[i].r) end
        out[#out + 1] = string.format("%s: %s | worst: %s", R0.name, table.concat(vals, ","), table.concat(ws, "  "))
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------------------------------- registry
-- R.gen: bumped by T.forget(); every element / builder remembers the generation it was made in and is dead after.
-- R.showGen: bumped by T.pageGeometry (a page show): builders re-apply what a Slate rebuild may have reset (V-FIN-16).
local R = { gen = 1, showGen = 0, nEls = 0, builders = {}, ghosts = {}, widgets = 0, geo = nil,
            geoLog = nil, fails = {}, forgets = 0 }
-- texture loader state (module level: assets outlive the page; the waiting lists hold elements and die with forget)
local Q = { txc = {}, hi = {}, lo = {}, queued = {}, wait = {}, missing = {}, loads = 0, stale = 0,
            win = -1e9, big = 0, small = 0 }

local function fail(kind, err)
    local first = tostring(err or "?"):match("^[^\n]*") or "?"
    R.fails[kind] = (R.fails[kind] or 0) + 1
    U.logOnce("theme.fail:" .. kind .. ":" .. first:sub(1, 120), TAG, "%s not built: %s", kind, tostring(err))
end

-- Builder objects listed by T.status (plain elements are counted in R.nEls instead).
local BUILDER_KINDS = { group = true, title = true, steprow = true, cmdrow = true, pill = true, poster = true,
                        row = true, ["group-header"] = true, check = true, lock = true, detail = true }

-- Runs a builder; nil (logged once per kind and reason) instead of an error.
local function build(kind, fn, ...)
    local ok, r = xpcall(fn, debug.traceback, ...)
    if ok and r ~= nil then
        if type(r) == "table" and BUILDER_KINDS[r.kind] then R.builders[#R.builders + 1] = r end
        return r
    end
    fail(kind, ok and "no result" or r)
    return nil
end

-- Method wrapper: one bad widget never throws into the caller's FAST tick (throttled error log, U.tryEvery).
local function guard(key, fn)
    return function(...)
        if St.launchHold() then return nil end           -- 0.12.0: no widget work while the front end is torn down
        local r = table.pack(U.tryEvery("theme." .. key, nil, TAG, fn, ...))
        if r[1] then return table.unpack(r, 2, r.n) end
        return nil
    end
end

local function dead(o) return type(o) ~= "table" or o.gen ~= R.gen end

---------------------------------------------------------------------------------------------------- construction
-- Native UMG / Fuse widget with the page's WidgetTree as outer (setup.lua's newW when the ctx has it).
local function construct(ctx, paths)
    local w
    if type(ctx.newW) == "function" then
        local ok, r = pcall(ctx.newW, paths)
        if ok and U.ok(r) then w = r end
    end
    if not w then
        for _, p in ipairs(paths) do
            local cls = U.class(p)
            if U.ok(cls) then
                local ok, r = pcall(StaticConstructObject, cls, ctx.tree)
                if ok and U.ok(r) then w = r; break end
            end
        end
    end
    if not w then error("cannot construct " .. tostring(paths[1])) end
    R.widgets = R.widgets + 1
    return w
end

-- One of the game's widget Blueprints owned by the page's player. Callers write its variables before the add.
local function create(ctx, clsPath)
    local cls = U.class(clsPath)
    if not U.ok(cls) then error(clsPath .. " not found") end
    local pc = U.ok(ctx.pc) and ctx.pc or nil
    local w = U.WBL():Create(pc or U.world(), cls, pc)    -- Create(WorldContextObject, WidgetType, OwningPlayer)
    if not U.ok(w) then error("Create(" .. clsPath .. ") failed") end
    R.widgets = R.widgets + 1
    return w
end

local function checkCtx(ctx, cv)
    if type(ctx) ~= "table" then error("ctx missing") end
    if not U.ok(cv) then error("canvas invalid") end
end

-- Child of a canvas: point anchor (0, 0), alignment (ax, ay), z order.
local function onCanvas(cv, w, z, align)
    local s = cv:AddChildToCanvas(w)                      -- -> CanvasPanelSlot
    if not U.ok(s) then error("AddChildToCanvas returned no slot") end
    pcall(function()
        s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        s:SetAlignment({ X = align and align[1] or 0, Y = align and align[2] or 0 })
    end)
    if z then pcall(function() s:SetZOrder(z) end) end
    return s
end

local function overlayAdd(over, w, h, v, pad)
    local s = over:AddChildToOverlay(w)                   -- -> OverlaySlot
    if U.ok(s) then
        pcall(function()
            s:SetHorizontalAlignment(h or AL.fill)
            s:SetVerticalAlignment(v or AL.fill)
            if pad then s:SetPadding(pad) end
        end)
    end
    return s
end

local function hboxAdd(hb, w, pad, v)
    local s = hb:AddChildToHorizontalBox(w)               -- -> HorizontalBoxSlot
    if U.ok(s) then
        pcall(function()
            s:SetVerticalAlignment(v or AL.c)
            if pad then s:SetPadding(pad) end
        end)
    end
    return s
end

local function vboxAdd(vb, w, pad, h)
    local s = vb:AddChildToVerticalBox(w)                 -- -> VerticalBoxSlot
    if U.ok(s) then
        pcall(function()
            s:SetHorizontalAlignment(h or AL.l)
            if pad then s:SetPadding(pad) end
        end)
    end
    return s
end

local function pad(l, t, r, b) return { Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 } end

-- Element: {kind, w (widget in its parent), s (slot, canvas children only), t (text block), i (image), c (render
-- cache), vis (the visibility it shows with), want (caller wants it shown), ready (its resource is on), gen}.
local function newEl(kind, w, s, x)
    local e = { kind = kind, w = w, s = s, c = {}, vis = VIS.HitTestInvisible, want = true, ready = true, gen = R.gen }
    for k, v in pairs(x or {}) do e[k] = v end
    R.nEls = R.nEls + 1
    return e
end

local function live(e)
    if St.launchHold() then return false end            -- 0.12.0: the front end is being torn down (state.lua)
    if type(e) ~= "table" or e.gen ~= R.gen then return false end
    if e.kind == "group" then return true end
    return U.ok(e.w)
end

---------------------------------------------------------------------------------------------------- diffed setters
local function applyVis(e)
    local v = (e.want and e.ready) and e.vis or VIS.Collapsed
    if e.c.vis ~= v and pcall(function() e.w:SetVisibility(v) end) then e.c.vis = v end
end

local function rectOf(r)
    if type(r) ~= "table" then return nil end
    return { tonumber(r[1] or r.x) or 0, tonumber(r[2] or r.y) or 0, tonumber(r[3] or r.w), tonumber(r[4] or r.h) }
end

-- r = {x, y[, w, h]} canvas-local; without w / h the slot sizes itself to the content.
local function rectSet(e, r)
    if not (e.s and live(e)) then return end            -- 0.12.0 (review ui-1): a dead widget is never called
    r = rectOf(r)
    if not r then return end
    local c = e.c
    local x, y = rnd(r[1]), rnd(r[2])
    if (c.x ~= x or c.y ~= y) and pcall(function() e.s:SetPosition({ X = x, Y = y }) end) then c.x, c.y = x, y end
    if r[3] and r[4] then
        local w, h = max(0, rnd(r[3])), max(0, rnd(r[4]))
        if c.auto ~= false and pcall(function() e.s:SetAutoSize(false) end) then c.auto = false end
        if (c.w ~= w or c.h ~= h) and pcall(function() e.s:SetSize({ X = w, Y = h }) end) then c.w, c.h = w, h end
    elseif c.auto ~= true and pcall(function() e.s:SetAutoSize(true) end) then
        c.auto, c.w, c.h = true, nil, nil
    end
end

local function alignSet(e, a)
    if not (e.s and type(a) == "table" and live(e)) then return end
    local ax, ay = tonumber(a[1] or a.x) or 0, tonumber(a[2] or a.y) or 0
    if (e.c.ax ~= ax or e.c.ay ~= ay) and pcall(function() e.s:SetAlignment({ X = ax, Y = ay }) end) then
        e.c.ax, e.c.ay = ax, ay
    end
end

local fontObjs, matObjs = {}, {}
local function assetObj(cache, path)
    if type(path) ~= "string" or path == "" then return nil end
    local o = cache[path]
    if o and U.ok(o) then return o end
    o = U.obj(path)                                       -- StaticFindObject, else LoadAsset (game thread)
    if U.ok(o) then cache[path] = o; return o end
    cache[path] = nil
    return nil
end

local fontMatBroken = false
local function fontSet(e, size)
    local r = e.role
    if not (e.t and r) then return end
    size = tonumber(size) or e.size or r.size
    local mpath = (opt("UiFontMaterials", true) ~= false and not fontMatBroken) and r.material or nil
    if e.c.fs == size and e.c.fm == mpath then return end
    local f = assetObj(fontObjs, r.font)
    if not f then return end
    local m = mpath and assetObj(matObjs, mpath) or nil
    local info = { FontObject = f, TypefaceFontName = U.fname(r.face or "Bold"), Size = size,
                   LetterSpacing = e.ls or r.ls or 0 }
    if m then info.FontMaterial = m; info.bMaterialIsStencil = STENCIL[mpath] == true end
    -- FSlateFontInfo from a table: missing fields are zero-filled (no outline) [cards.lua, cmap.lua]
    local ok, err = pcall(function() e.t:SetFont(info) end)
    if not ok and m then
        fontMatBroken = true
        U.warn(TAG, "SetFont with a font material failed (%s): plain fonts from now on (V-PARTS-02)", tostring(err))
        info.FontMaterial, info.bMaterialIsStencil = nil, nil
        ok = pcall(function() e.t:SetFont(info) end)
        mpath = nil
    end
    if ok then e.c.fs, e.c.fm, e.size = size, mpath, size end
end

local function textSet(e, s)
    s = tostring(s or "")
    if e.c.s == s then return end
    if pcall(function() e.t:SetText(U.ftext(s)) end) then e.c.s = s end
end

local function inkSet(e, c)
    c = canon(c)
    if e.c.ink ~= c and pcall(function() e.t:SetColorAndOpacity(slate(c)) end) then e.c.ink = c end
end

local function tintSet(e, c)
    c = canon(c)
    if e.c.tint ~= c and pcall(function() e.i:SetColorAndOpacity(lin(c)) end) then e.c.tint = c end
end

local function wrapSet(e, w)
    w = rnd(tonumber(w) or 0)
    if e.c.wrap == w then return end
    -- UCommonTextBlock::SetWrapTextWidth(Int): WrapTextAt + SynchronizeProperties (FuseTextBlock is a CommonTextBlock)
    local ok = pcall(function() e.t:SetWrapTextWidth(w) end)
    if not ok then ok = pcall(function() e.t.WrapTextAt = w end) end
    if ok then e.c.wrap = w end
end

local function opacitySet(e, a)
    a = tonumber(a) or 1
    if e.c.op ~= a and live(e) and pcall(function() e.w:SetRenderOpacity(a) end) then e.c.op = a end
end

-- Uniform render scale about the widget's centre (flipX keeps a mirrored image mirrored).
local function scaleSet(e, k)
    k = tonumber(k) or 1
    if e.c.rs == k or not live(e) then return end       -- 0.12.0 (review ui-1): crash on a freed poster
    local sx = e.flipX and -k or k
    if pcall(function() e.w:SetRenderScale({ X = sx, Y = k }) end) then e.c.rs = k end
end

---------------------------------------------------------------------------------------------------- brushes
local setBrushBroken = false
local function brushTable(res, b)
    local m = tonumber(b.margin) or 0
    local t = {
        ResourceObject = res,
        ImageSize = { X = b.w or 32, Y = b.h or 32 },
        DrawAs = b.drawAs or DRAW.image,
        Margin = { Left = m, Top = m, Right = m, Bottom = m },
        TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 },
        ImageType = 1,                                     -- ESlateBrushImageType::FullColor
    }
    if b.drawAs == DRAW.rounded then
        local r = tonumber(b.radius) or 0
        t.OutlineSettings = { CornerRadii = { X = r, Y = r, Z = r, W = r },
                              Color = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 0 }, ColorUseRule = 0 },
                              Width = 0, RoundingType = b.rounding or 0 }   -- 0 FixedRadius, 1 HalfHeightRadius
    end
    return t
end

-- Puts a texture / material on e.i: a full SetBrush table for Box / RoundedBox draws, else SetBrushFrom*.
local function applyRes(e, res, isTex)
    local b = e.brush
    if b and b.drawAs ~= DRAW.image and not setBrushBroken then
        local ok, err = pcall(function() e.i:SetBrush(brushTable(res, b)) end)
        if ok then return true end
        setBrushBroken = true
        U.warn(TAG, "UImage:SetBrush with a table failed (%s): Image draws from now on (V-PARTS-08)", tostring(err))
    end
    if isTex then
        return pcall(function() e.i:SetBrushFromTexture(res, false) end)   -- (Texture2D, bMatchSize)
    end
    return pcall(function() e.i:SetBrushFromMaterial(res) end)
end

-- A new brush ImageSize (a pill that changes height keeps half-height corners).
local function brushSize(e, w, h)
    local b = e.brush
    if not b or (b.w == w and b.h == h) then return end
    b.w, b.h = w, h
    if e.c.res and U.ok(e.c.res) then applyRes(e, e.c.res, e.c.resTex) end
end

---------------------------------------------------------------------------------------------------- textures (RC-7, RC-9)
local function assetName(path) return string.match(path, "%.([^%./]+)$") or path end

local BIG = {                                              -- uasset sizes (notes/asset-list.txt), one mip, NeverStream
    { "/Textures/Backgrounds/", 4147732 }, { "/Content/MainMenu/T_UI_FE_Tile_MP_01", 2326149 },
    { "/Content/MainMenu/T_UI_FE_Tile_MP_06", 2326149 }, { "/Content/MainMenu/T_UI_FE_Tile_Campaign_Hero", 1764076 },
    { "/Content/MainMenu/T_UI_FE_Tile_Temp", 2626531 }, { "_Scenario_009_", 1517369 }, { "_Scenario_010_", 1517393 },
    { "_Scenario_013_", 1517377 }, { "_Scenario_Tile_Dal_Backer_Bg", 4692100 }, { "_Fallback.", 2664556 },
}
local function estBytes(path)
    for _, b in ipairs(BIG) do
        if string.find(path, b[1], 1, true) then
            if b[1] == "_Fallback." and string.find(path, "/Content/Vehicles/", 1, true) then return 11310576 end
            return b[2]
        end
    end
    if string.find(path, "/Content/Arcade/", 1, true) and string.find(path, "_Bg.", 1, true) then return 4692068 end
    return 400000
end

-- The loaded texture, or nil (never loads). A cached object counts only while its FName is still the asset's.
local function texNow(path)
    local t = Q.txc[path]
    if t ~= nil then
        if U.ok(t) then
            local ok, n = pcall(function() return t:GetFName():ToString() end)
            if ok and n == assetName(path) then return t end
        end
        Q.txc[path] = nil
        Q.stale = Q.stale + 1
    end
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.ok(o) then Q.txc[path] = o; return o end
    return nil
end

-- Per-tick budget window (one big texture, CardLoadsPerTick small), cards.lua's rule (review fix 0.12.0): a page's
-- per-tick entry (the status pill's tick, the command row's poll, T.tick: entry = true) opens a new window, at most
-- once per FAST period (the lobby and the setup page both tick while the setup is open); a load 100 ms after the last
-- opening (no page ticking, e.g. a page built while hidden) opens one itself, so nothing waits forever. Never sooner:
-- the former 30-ms wall-clock window let a slow page build open several windows inside ONE game tick (lobby.build
-- with the setup page loaded both 4-MB page backgrounds, T_UI_MainMenu_Bg and T_UI_Map_Bg, in the same tick).
local function budgetWindow(now, entry)
    if (entry and now - Q.win >= 25) or now - Q.win > 100 then Q.win, Q.big, Q.small = now, 0, 0 end
end

-- The chrome's own icons and fills are a few KB each (asset-list.txt: 0.8 - 22 KB; the Xbox glyphs ~7 KB): they load
-- outside the budget, so a page shows its arrows, ticks and pips in its first frame. Everything else is budgeted.
local TINY = {}
for _, k in ipairs({ "SolidFill", "CircleFrame", "GradientV", "TileStroke", "SettingFill", "SettingHandle", "Divider",
                     "Tick", "ArrowB", "Lock", "Player", "TitleBarcode", "TitleLayer" }) do TINY[TEX[k]] = true end
local function tiny(path) return TINY[path] == true or string.find(path, "/Textures/Platform/Xbox/", 1, true) ~= nil end

local function loadNow(path)
    budgetWindow(nowMs())
    if tiny(path) then
        -- no budget
    elseif estBytes(path) >= num("CardLoadBigBytes", 1048576) then
        if Q.big >= 1 then return nil end
        Q.big = Q.big + 1
    else
        if Q.small >= max(1, floor(num("CardLoadsPerTick", 3))) then return nil end
        Q.small = Q.small + 1
    end
    local ok, err = pcall(LoadAsset, path)                 -- game thread; 3 returns, re-found below
    local t = texNow(path)
    Q.loads = Q.loads + 1
    if not t then
        Q.missing[path] = true
        U.logOnce("theme.missing:" .. path, TAG, "texture missing: %s%s", path, ok and "" or (" (" .. tostring(err) .. ")"))
    end
    return t
end

local function enqueue(path, hi)
    if Q.missing[path] then return end
    local q = Q.queued[path]
    if q == Q.hi or (q ~= nil and not hi) then return end
    q = hi and Q.hi or Q.lo
    Q.queued[path] = q
    q[#q + 1] = path
end

local function getTex(path, wanted)
    local t = texNow(path)
    if t then return t end
    if Q.missing[path] then return nil end
    if wanted then
        t = loadNow(path)
        if t then return t end
    end
    enqueue(path, wanted)
    return nil
end

-- Texture size in texels: UTexture2D:Blueprint_GetSizeX/Y(), else the brush ImageSize that SetBrushFromTexture(t, true)
-- writes (an art image is a plain Image draw on an explicitly sized slot: ImageSize changes nothing visible).
local function texSize(e, t)
    local w, h
    pcall(function() w, h = tonumber(t:Blueprint_GetSizeX()), tonumber(t:Blueprint_GetSizeY()) end)
    if not (w and h and w > 0 and h > 0) and not e.brush then
        pcall(function()
            e.i:SetBrushFromTexture(t, true)               -- (Texture2D, bMatchSize = true)
            local s = e.i.Brush.ImageSize                  -- FSlateBrush property read (struct userdata)
            w, h = tonumber(s.X), tonumber(s.Y)
        end)
    end
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

-- Cover placement of an art image inside its clipping window (§3.4 C6: "sized to cover the box, placed by (ax, ay)").
local function placeCover(e)
    local cv = e.cover
    if not (cv and cv.tw and cv.th) then return end
    local k = max(cv.bw / cv.tw, cv.bh / cv.th) * (cv.zoom or 1)
    local iw, ih = cv.tw * k, cv.th * k
    rectSet(e, { (cv.bw - iw) * (cv.ax or 0.5), (cv.bh - ih) * (cv.ay or 0.5), iw, ih })
end

local function putTex(e, path, t)
    if not applyRes(e, t, true) then return false end
    e.c.tex, e.c.res, e.c.resTex = path, t, true
    if e.cover then
        local w, h = texSize(e, t)
        e.cover.tw, e.cover.th = w or e.cover.tw or e.cover.bw, h or e.cover.th or e.cover.bh
        placeCover(e)
    end
    e.ready = true
    applyVis(e)
    return true
end

local function arrived(path, t)
    local w = Q.wait[path]
    Q.wait[path] = nil
    if not (w and t) then return end
    for e in pairs(w) do
        if live(e) and e.c.want == path and e.c.tex ~= path then pcall(putTex, e, path, t) end
    end
end

-- Drains the texture queue within this window's budget. entry = true from the per-tick entry points (the pills' tick,
-- the command rows' poll, T.tick: they open the next window); every T.set drains too (inside the current window).
-- A path over this window's budget costs no engine call (cards.lua's CD.tick): it waits for the next window.
local function pump(now, entry)
    if #Q.hi == 0 and #Q.lo == 0 then return end
    if St.launchHold() then return end                   -- 0.12.0: queued textures wait (the page is dying)
    budgetWindow(now or nowMs(), entry)
    local smallMax = max(1, floor(num("CardLoadsPerTick", 3)))
    for _, q in ipairs({ Q.hi, Q.lo }) do
        local i = 1
        while i <= #q do
            local path = q[i]
            if Q.queued[path] ~= q then
                table.remove(q, i)
            else
                local free = tiny(path)
                local big = not free and estBytes(path) >= num("CardLoadBigBytes", 1048576)
                if (big and Q.big >= 1) or (not free and not big and Q.small >= smallMax) then
                    i = i + 1                              -- over budget: a later (small) one may still fit
                else
                    local t = texNow(path) or loadNow(path)
                    if t or Q.missing[path] then
                        table.remove(q, i)
                        Q.queued[path] = nil
                        arrived(path, t)
                    else
                        i = i + 1
                    end
                end
            end
        end
    end
end

-- The texture at path on image e; e stays hidden until it is on (cards.lua `img`).
local function texSet(e, path)
    if type(path) ~= "string" or path == "" then
        e.c.want = nil
        e.ready = false
        applyVis(e)
        return false
    end
    e.c.want = path
    if e.c.tex == path then e.ready = true; applyVis(e); return true end
    local t = getTex(path, true)
    if t then return putTex(e, path, t) end
    if not Q.missing[path] then
        local w = Q.wait[path]
        if not w then w = setmetatable({}, { __mode = "k" }); Q.wait[path] = w end
        w[e] = true
    end
    e.ready = false
    applyVis(e)
    return false
end

local function matSet(e, path)
    if e.c.mat == path and e.c.res and U.ok(e.c.res) then return true end
    local m = assetObj(matObjs, path)
    if m and applyRes(e, m, false) then
        e.c.mat, e.c.res, e.c.resTex, e.c.tex = path, m, false, nil
        e.ready = true
        applyVis(e)
        return true
    end
    U.logOnce("theme.mat?" .. tostring(path), TAG, "material not usable: %s", tostring(path))
    e.ready = false
    applyVis(e)
    return false
end

---------------------------------------------------------------------------------------------------- geometry (§2.5)
local function viewportSu()
    local w, h = FRAME.screen.w, FRAME.screen.h
    pcall(function()
        local wll, world = U.cdo("WidgetLayoutLibrary"), U.world()
        if not (U.ok(wll) and U.ok(world)) then return end
        local s = wll:GetViewportSize(world)              -- WidgetLayoutLibrary:GetViewportSize(Object) -> Vector2D px
        local dpi = wll:GetViewportScale(world)           -- GetViewportScale(Object) -> Float (UMG DPI scale)
        local px, py = tonumber(s and s.X), tonumber(s and s.Y)
        if px and py and px > 0 and py > 0 and type(dpi) == "number" and dpi > 0 then w, h = px / dpi, py / dpi end
    end)
    return w, h
end

-- su per physical pixel (1 / the UMG DPI scale; 3 at 720p, 1 at 2160p), re-read every 2 s. Slate lays text out on
-- whole pixels, so at a low resolution a text measures up to about a pixel per glyph wider than T.textWidth: the
-- overflow checks (cards2 V-FIN-09) allow for it.
local PX = { at = -1e12, v = 1 }
function T.pxSu()
    local t = nowMs()
    if t - PX.at < 2000 then return PX.v end
    PX.at = t
    pcall(function()
        local wll, world = U.cdo("WidgetLayoutLibrary"), U.world()
        if not (U.ok(wll) and U.ok(world)) then return end
        local dpi = wll:GetViewportScale(world)
        if type(dpi) == "number" and dpi > 0 then PX.v = 1 / dpi end
    end)
    return PX.v
end

local function plausible(g)
    return g and g.x >= 0 and g.x <= 1200 and g.y >= 40 and g.y <= 900 and g.w >= 1500 and g.w <= 6000
        and g.h >= 800 and g.h <= 2400
end

-- V-FIN-01 as specified: SlateBlueprintLibrary.LocalToViewport(root geometry, (0, 0)) + GetLocalSize. In this UE4SS
-- build FGeometry comes back as an empty table (no reflected fields), so this returns nil with the reason.
local function slateGeometry(root)
    if not U.ok(root) then return nil, "no root" end
    local okG, g = pcall(U.callMethod, root, "GetCachedGeometry")  -- UWidget::GetCachedGeometry() -> FGeometry
    if not okG or g == nil then return nil, "GetCachedGeometry failed" end
    if type(g) == "table" and next(g) == nil then return nil, "GetCachedGeometry returned no fields" end
    local sbl = U.cdo("/Script/UMG.Default__SlateBlueprintLibrary")
    if not U.ok(sbl) then return nil, "SlateBlueprintLibrary CDO not found" end
    local px, vp = {}, {}
    -- LocalToViewport(Object WorldContextObject, Geometry, Vector2D LocalCoordinate, out PixelPosition,
    --   out ViewportPosition); struct out-params are filled in place
    local okL = pcall(function() sbl:LocalToViewport(U.world(), g, { X = 0, Y = 0 }, px, vp) end)
    local okS, size = pcall(U.callMethod, sbl, "GetLocalSize", g)  -- GetLocalSize(Geometry) -> Vector2D
    local x, y = tonumber(vp.X), tonumber(vp.Y)
    local w, h = okS and size and tonumber(size.X), okS and size and tonumber(size.Y)
    if not (okL and x and y and w and h) then return nil, "LocalToViewport / GetLocalSize unusable" end
    return { x = x, y = y, w = w, h = h }
end

local function padOf(w)
    local p = { l = 0, t = 0, r = 0, b = 0 }
    pcall(function()
        local m = w.Slot.Padding                           -- UWidget.Slot (UPanelSlot) -> FMargin property
        p.l, p.t = tonumber(m.Left) or 0, tonumber(m.Top) or 0
        p.r, p.b = tonumber(m.Right) or 0, tonumber(m.Bottom) or 0
    end)
    return p
end

-- The page rect from the main menu's own layout (WBP_FE_MainMenu: SzB_ScreenSizeOverride 3840 > VB_Content (padding
-- 128 / 128) > [SzB_MP_Searching, O_Header, DevButtonHolder] WS_ScreenContent (Fill) [SzB_Build]): the visible
-- siblings' desired heights + slot paddings above and below the switcher, every value a reflected property.
local function layoutGeometry(root)
    local menu = St.menu and St.menu.widget
    if not U.ok(menu) then return nil, "no main menu" end
    local sw
    pcall(function() sw = menu.WS_ScreenContent end)
    if not U.ok(sw) then return nil, "WS_ScreenContent not found" end
    local vb = sw:GetParent()                             -- UWidget::GetParent() -> PanelWidget (VB_Content)
    if not U.ok(vb) then return nil, "WS_ScreenContent has no parent panel" end
    local n, idx = vb:GetChildrenCount(), vb:GetChildIndex(sw)
    if type(n) ~= "number" or type(idx) ~= "number" or idx < 0 then return nil, "VB_Content children unreadable" end
    local above, below = 0, 0
    for i = 0, n - 1 do
        if i ~= idx then
            local c = vb:GetChildAt(i)
            local okV, v = pcall(U.callMethod, c, "GetVisibility")
            if U.ok(c) and not (okV and v == VIS.Collapsed) then
                local hh = 0
                pcall(function() hh = tonumber(c:GetDesiredSize().Y) or 0 end)   -- Widget:GetDesiredSize() -> Vector2D
                local p = padOf(c)
                if i < idx then above = above + hh + p.t + p.b else below = below + hh + p.t + p.b end
            end
        end
    end
    local sp, vp = padOf(sw), padOf(vb)
    local boxW = FRAME.screen.w
    pcall(function()
        local wo = tonumber(vb:GetParent().WidthOverride) -- SzB_ScreenSizeOverride.WidthOverride (3840)
        if wo and wo > 0 then boxW = wo end
    end)
    local pp = { l = 0, t = 0, r = 0, b = 0 }
    pcall(function()
        local tree = U.ok(root) and root:GetOuter() or nil                -- null GetOuter = native AV
        local page = U.ok(tree) and tree:GetOuter() or nil              -- WidgetTree -> its UserWidget (our page)
        if U.ok(page) then pp = padOf(page) end
    end)
    local _, vh = viewportSu()
    local g = { x = vp.l + sp.l + pp.l, y = vp.t + above + sp.t + pp.t,
                w = boxW - vp.l - vp.r - sp.l - sp.r - pp.l - pp.r,
                h = vh - vp.t - vp.b - above - below - sp.t - sp.b - pp.t - pp.b }
    if not plausible(g) then
        return nil, string.format("implausible layout rect %d,%d %dx%d (above %d below %d)", rnd(g.x), rnd(g.y),
            rnd(g.w), rnd(g.h), rnd(above), rnd(below))
    end
    return g
end

local function screenExtent()
    local vw, vh = viewportSu()
    return { x = (FRAME.screen.w - vw) / 2, y = 0, w = vw, h = vh }   -- the 3840 design box is centred
end

local function withDerived(g)
    g.cmdY = min(FRAME.cmd.y, g.y + g.h - 104)                       -- §2.5 derived
    g.cardH = min(FRAME.cardRow.h, g.cmdY - 32 - FRAME.cardRow.y)
    return g
end

local function fallbackGeo()
    local p = FRAME.page
    return withDerived({ x = p.x, y = p.y, w = p.w, h = p.h, src = "fallback",
                         screen = { x = 0, y = 0, w = FRAME.screen.w, h = FRAME.screen.h } })
end

local function geoOr(geo)
    if type(geo) == "table" and tonumber(geo.x) and tonumber(geo.y) then return geo end
    return R.geo or fallbackGeo()
end

local function screenOf(geo)
    local s = type(geo) == "table" and geo.screen
    if type(s) == "table" and tonumber(s.w) then return s end
    return { x = 0, y = 0, w = FRAME.screen.w, h = FRAME.screen.h }
end

-- Page origin / size in screen su, measured on every page show (V-FIN-01). Order: config UiPageOrigin, the spec's
-- Slate geometry route, the main menu's live layout, the constants 128 / 240 / 3584 / 1756.
function T.pageGeometry(root)
    local g, src, why = nil, nil, {}
    local ok = pcall(function()
        local o = opt("UiPageOrigin", nil)                -- §12.3: nil = measured
        if type(o) == "table" then
            local x, y = tonumber(o.x or o[1]), tonumber(o.y or o[2])
            local w, h = tonumber(o.w or o[3]), tonumber(o.h or o[4])
            if x and y and w and h and w > 0 and h > 0 then g, src = { x = x, y = y, w = w, h = h }, "config"
            else why[#why + 1] = "UiPageOrigin malformed" end
        end
        if not g then
            local r, e = slateGeometry(root)
            if r and plausible(r) then g, src = r, "geometry"
            else why[#why + 1] = e or "implausible geometry" end
        end
        if not g then
            local r, e = layoutGeometry(root)
            if r then g, src = r, "layout" else why[#why + 1] = e end
        end
    end)
    if not ok or not g then g, src = fallbackGeo(), "fallback" end
    g.src = src
    g.screen = screenExtent()
    withDerived(g)
    R.geo = g
    R.showGen = R.showGen + 1
    pump(nowMs())
    local key = string.format("%s %d,%d %dx%d", src, rnd(g.x), rnd(g.y), rnd(g.w), rnd(g.h))
    if key ~= R.geoLog then
        R.geoLog = key
        U.log(TAG, "page geometry: x %d y %d w %d h %d (source %s%s), screen %d..%d x %d, cmdY %d, CardH %d (V-FIN-01)",
            rnd(g.x), rnd(g.y), rnd(g.w), rnd(g.h), src, (#why > 0) and ("; " .. table.concat(why, "; ")) or "",
            rnd(g.screen.x), rnd(g.screen.x + g.screen.w), rnd(g.screen.h), rnd(g.cmdY), rnd(g.cardH))
    else
        U.dbg(TAG, "page geometry unchanged (%s)", key)
    end
    return g
end

function T.toLocal(geo, x, y)
    geo = geoOr(geo)
    return (tonumber(x) or 0) - geo.x, (tonumber(y) or 0) - geo.y
end

local function L(geo, x, y) return x - geo.x, y - geo.y end
local function LR(geo, r)
    r = rectOf(r)
    return { r[1] - geo.x, r[2] - geo.y, r[3], r[4] }
end

---------------------------------------------------------------------------------------------------- primitives
-- Text block on a canvas (HitTestInvisible). opts: see the API list at the top.
function T.text(ctx, cv, r, opts)
    opts = opts or {}
    return build("text", function()
        checkCtx(ctx, cv)
        local ro = roleOf(r)
        local t = construct(ctx, TEXT)
        local wrapW = tonumber(opts.wrapW or ro.wrapW) or 0
        -- before the add (PreConstruct / SynchronizeProperties read them when Slate builds the widget, RC-3)
        if wrapW > 0 then pcall(function() t.WrapTextAt = wrapW end) end
        if ro.lineH then
            pcall(function() t.LineHeightPercentage = ro.lineH end)
            pcall(function() t.ApplyLineHeightToBottomLine = false end)
        end
        pcall(function() t:SetJustification(JUST[opts.justify or ro.justify or "l"] or 0) end)
        local upper = opts.upper
        if upper == nil then upper = ro.upper end
        if upper then pcall(function() t:SetTextTransformPolicy(2) end) end   -- ETextTransformPolicy ToUpper
        local s = onCanvas(cv, t, opts.z, opts.align)
        local e = newEl("text", t, s, { t = t, role = ro, ls = opts.ls, size = tonumber(opts.size) or ro.size })
        e.c.wrap = wrapW
        if opts.align then e.c.ax, e.c.ay = tonumber(opts.align[1]) or 0, tonumber(opts.align[2]) or 0 end
        fontSet(e, e.size)
        inkSet(e, opts.colour or ro.colour)
        if opts.text ~= nil then textSet(e, opts.text) end
        rectSet(e, opts.rect or { 0, 0 })
        e.want = opts.visible ~= false
        applyVis(e)
        return e
    end)
end

-- Box / RoundedBox brush description (nil for a plain Image draw: SetBrushFrom* keeps the default brush).
local function brushOf(opts)
    local da = opts.drawAs or (opts.margin and DRAW.box) or nil
    if da == nil or da == DRAW.image then return nil end
    local sz = opts.size
    local w, h
    if type(sz) == "table" then w, h = tonumber(sz[1] or sz.w), tonumber(sz[2] or sz.h)
    else w = tonumber(sz); h = w end
    return { drawAs = da, margin = opts.margin or 0, w = w or 32, h = h or 32, radius = opts.radius,
             rounding = opts.rounding }
end

-- Image on a canvas (HitTestInvisible). A texture still loading keeps it hidden (shown when it arrives).
function T.image(ctx, cv, opts)
    opts = opts or {}
    return build("image", function()
        checkCtx(ctx, cv)
        local img = construct(ctx, IMAGE)
        pcall(function() img:SetVisibility(VIS.Collapsed) end)
        local s = onCanvas(cv, img, opts.z, opts.align)
        local e = newEl("image", img, s, { i = img, brush = brushOf(opts), flipX = opts.flipX == true })
        e.c.vis = VIS.Collapsed
        if opts.align then e.c.ax, e.c.ay = tonumber(opts.align[1]) or 0, tonumber(opts.align[2]) or 0 end
        if opts.tint then tintSet(e, opts.tint) end
        if opts.opacity then opacitySet(e, opts.opacity) end
        if e.flipX then scaleSet(e, 1) end
        rectSet(e, opts.rect or { 0, 0, 32, 32 })
        e.want = opts.visible ~= false
        if opts.mat then matSet(e, opts.mat)
        elseif opts.tex then texSet(e, opts.tex)
        else e.ready = true; applyVis(e) end
        return e
    end)
end

-- An element (a table with .gen) or a ghost widget made by T.ghost (its element). Offline harnesses fake UObjects as
-- tables: anything that is not an element is looked up like a widget.
local function resolve(e)
    if type(e) == "userdata" then return R.ghosts[U.key(e)] end
    if type(e) == "table" and rawget(e, "gen") == nil then return R.ghosts[U.key(e)] end
    return e
end

-- Diffed writes on an element (or a ghost widget made by T.ghost). Returns e, nil when it is dead.
function T.set(e, f)
    e = resolve(e)
    if type(f) ~= "table" or not live(e) then return nil end
    if #Q.hi + #Q.lo > 0 then pump(nowMs()) end           -- queued textures within this window's budget
    local ok = pcall(function()
        if e.kind == "group" then
            for _, p in ipairs(e.parts) do
                if live(p) then
                    if f.visible ~= nil then p.want = f.visible and true or false; applyVis(p) end
                    if f.opacity then opacitySet(p, f.opacity) end
                end
            end
            return
        end
        if f.align then alignSet(e, f.align) end
        if f.rect then rectSet(e, f.rect) end
        if e.t then
            if f.size then fontSet(e, f.size) end
            if f.wrapW then wrapSet(e, f.wrapW) end
            if f.colour then inkSet(e, f.colour) end
            if f.text ~= nil then textSet(e, f.text) end
        elseif e.i then
            if f.colour then tintSet(e, f.colour) end
            if f.tex ~= nil then texSet(e, f.tex) end
            if f.mat ~= nil then matSet(e, f.mat) end
        end
        if f.opacity then opacitySet(e, f.opacity) end
        if f.scale then scaleSet(e, f.scale) end
        if f.visible ~= nil then e.want = f.visible and true or false; applyVis(e) end
    end)
    if not ok then return nil end
    return e
end

-- Plain container (canvas / overlay / boxes) placed on a canvas; e.w is the container.
local function container(ctx, cv, paths, z, vis, align)
    local w = construct(ctx, paths)
    pcall(function() w:SetVisibility(vis or VIS.SelfHitTestInvisible) end)
    local s = cv and onCanvas(cv, w, z, align) or nil
    local e = newEl("box", w, s, { vis = vis or VIS.SelfHitTestInvisible })
    e.c.vis = e.vis
    return e
end

-- Image child of a panel (not a canvas): desired size override, brush as T.image.
local function childImage(ctx, opts)
    local img = construct(ctx, IMAGE)
    local e = newEl("image", img, nil, { i = img, brush = brushOf(opts), flipX = opts.flipX == true })
    pcall(function() img:SetVisibility(VIS.Collapsed) end)
    e.c.vis = VIS.Collapsed
    if opts.dsize then
        pcall(function() img:SetDesiredSizeOverride({ X = opts.dsize[1], Y = opts.dsize[2] }) end)
    end
    if opts.tint then tintSet(e, opts.tint) end
    if e.flipX then scaleSet(e, 1) end
    e.want = opts.visible ~= false
    if opts.mat then matSet(e, opts.mat) elseif opts.tex then texSet(e, opts.tex) else e.ready = true; applyVis(e) end
    return e
end

-- Text child of a panel (not a canvas).
local function childText(ctx, r, opts)
    opts = opts or {}
    local ro = roleOf(r)
    local t = construct(ctx, TEXT)
    local wrapW = tonumber(opts.wrapW or ro.wrapW) or 0
    if wrapW > 0 then pcall(function() t.WrapTextAt = wrapW end) end
    if ro.lineH then
        pcall(function() t.LineHeightPercentage = ro.lineH end)
        pcall(function() t.ApplyLineHeightToBottomLine = false end)
    end
    pcall(function() t:SetJustification(JUST[opts.justify or ro.justify or "l"] or 0) end)
    local upper = opts.upper
    if upper == nil then upper = ro.upper end
    if upper then pcall(function() t:SetTextTransformPolicy(2) end) end
    local e = newEl("text", t, nil, { t = t, role = ro, ls = opts.ls, size = tonumber(opts.size) or ro.size })
    e.c.wrap = wrapW
    fontSet(e, e.size)
    inkSet(e, opts.colour or ro.colour)
    if opts.text ~= nil then textSet(e, opts.text) end
    e.want = opts.visible ~= false
    applyVis(e)
    return e
end

---------------------------------------------------------------------------------------------------- ghosts (C7, §3.3)
function T.nav(w, dir, target)
    local d = (type(dir) == "number") and dir or NAV[string.lower(tostring(dir))]
    if d == nil or not U.ok(w) or not U.ok(target) then return false end
    -- UWidget::SetNavigationRuleExplicit(EUINavigation Direction, UWidget* InWidget) (the RACERS sink's method)
    return pcall(function() w:SetNavigationRuleExplicit(d, target) end) == true
end

local hoverSeen = false
-- focused, hovered of a ghost (or any widget) for P1.
function T.isFocused(w, p1)
    if not U.ok(w) then return false, false end
    local ui = U.mod("ui")
    local f = ui.hasFocus(w, p1) == true
    local h = false
    if type(ui.hovered) == "function" then h = ui.hovered(w) == true
    else
        local ok, v = pcall(U.callMethod, w, "IsHovered")
        h = ok and v == true
    end
    if h and not hoverSeen then
        hoverSeen = true
        U.log(TAG, "mouse hover seen on a ghost (IsHovered works, V-FIN-04)")
    end
    return f, h
end

-- An invisible focus target (ui.ghost) on cv at rect (screen su). opts: geo, z (default 10), nav = {dir = widget},
-- plus ui.registerButton's opts (noClaim). Returns the WBP_Common_Btn widget.
function T.ghost(ctx, cv, rect, id, fn, opts)
    opts = opts or {}
    return build("ghost", function()
        checkCtx(ctx, cv)
        local ui = U.mod("ui")
        local g
        if type(ui.ghost) == "function" then
            g = ui.ghost(ctx.pc, id, fn, opts)
        else
            g = ui.button(ctx.pc, id, "", fn, opts)
            if U.ok(g) then
                pcall(function() g:SetRenderOpacity(0) end)
                pcall(function() g:SetVisibility(VIS.Visible) end)
            end
        end
        if not U.ok(g) then error("ghost '" .. tostring(id) .. "' not created") end
        local geo = geoOr(opts.geo)
        local s = onCanvas(cv, g, opts.z or 10)
        local e = newEl("ghost", g, s, { vis = VIS.Visible, id = id })
        e.c.vis = VIS.Visible
        rectSet(e, LR(geo, rect))
        R.ghosts[U.key(g)] = e
        if type(opts.nav) == "table" then
            for dir, target in pairs(opts.nav) do T.nav(g, dir, target) end
        end
        return g
    end)
end

---------------------------------------------------------------------------------------------------- C1 page background
-- kind "hub": T_UI_MainMenu_Bg at render size 1.4 (5376 x 3024), top-right anchored, + the main menu's dial line art
-- (MI_UI_Background_Dial_Right DEEP @0.4, mirrored as the menu's own Img_Background); kind "map": a PAGE strip over the
-- tab bar + the campaign's T_UI_Map_Bg from y 180. Lives on the page canvas at negative page-local positions and dies
-- with the page; the menu's WBP_Media_Background is never touched. opts.z: the lowest z (default -10).
function T.pageBackground(ctx, cv, geo, kind, opts)
    opts = opts or {}
    return build("pageBackground", function()
        checkCtx(ctx, cv)
        geo = geoOr(geo)
        local sc = screenOf(geo)
        local z = tonumber(opts.z) or -10
        local parts = {}
        if kind == "map" then
            local x, y = L(geo, sc.x, 0)
            parts[1] = T.image(ctx, cv, { tex = TEX.SolidFill, tint = COL.PAGE, z = z, rect = { x, y, sc.w, 180 } })
            local mh = FRAME.screen.h * sc.w / FRAME.screen.w
            local mx, my = L(geo, sc.x, 180)
            parts[2] = T.image(ctx, cv, { tex = TEX.MapBg, z = z, rect = { mx, my, sc.w, mh } })
        else
            kind = "hub"
            local bw, bh = FRAME.screen.w * 1.4, FRAME.screen.h * 1.4
            local x, y = L(geo, sc.x + sc.w - bw, 0)
            parts[1] = T.image(ctx, cv, { tex = TEX.MainMenuBg, z = z, rect = { x, y, bw, bh } })
            local dx, dy = L(geo, sc.x, 0)
            parts[2] = T.image(ctx, cv, { mat = MAT.DialRight, tint = alpha(COL.DEEP, 0.4), z = z + 1, flipX = true,
                                          rect = { dx, dy, sc.w, FRAME.screen.h } })
        end
        if not parts[1] then error("background image not built") end
        local e = { kind = "group", parts = {}, gen = R.gen, c = {}, bg = kind }
        for _, p in ipairs(parts) do if p then e.parts[#e.parts + 1] = p end end
        U.log(TAG, "page background '%s' on the page canvas at local %d,%d (screen %d..%d), z %d (V-FIN-02: it must draw "
            .. "under the tab bar and the profile card and past WS_ScreenContent)", kind, rnd(sc.x - geo.x), rnd(-geo.y),
            rnd(sc.x), rnd(sc.x + sc.w), z)
        return e
    end)
end

---------------------------------------------------------------------------------------------------- C2 screen title
-- WBP_Screen_Title (HeaderText / LightVersion before the add) in a FuseSizeBox (150 x 2700): the slash at x 128, the cap
-- top at 285 (the box top 36 su above the cap: the game's VEHICLE SELECT puts the box at 84 for a cap at 120, V-FIN-03).
-- UiTitleWidget = "text" (or a failed Create): our own RUST slash + Moki 103.5 + RUST tag box with a barcode.
function T.screenTitle(ctx, cv, geo, text)
    return build("screenTitle", function()
        checkCtx(ctx, cv)
        geo = geoOr(geo)
        local FT = FRAME.titleBox
        local boxH = num("UiTitleBoxH", FT.h)
        local t = { kind = "title", gen = R.gen, text = tostring(text or "") }
        local box = container(ctx, cv, SIZE, 3, VIS.HitTestInvisible)
        pcall(function() box.w:SetHeightOverride(boxH); box.w:SetWidthOverride(FT.w) end)
        local x, y = L(geo, FRAME.titleX, FRAME.titleCap - FT.capOffset)
        rectSet(box, { x, y })
        t.e = box
        if opt("UiTitleWidget", "game") ~= "text" then
            local ok, w = pcall(create, ctx, T.WBP.ScreenTitle)
            if ok then
                pcall(function() w.HeaderText = U.ftext(t.text) end)   -- PreConstruct: Txt_ScreenTitle:SetText(HeaderText)
                pcall(function() w.LightVersion = false end)           -- the dark headline style on the cream page
                pcall(function() w:SetVisibility(VIS.HitTestInvisible) end)
                local okA = pcall(function() box.w:AddChild(w) end)    -- -> SizeBoxSlot
                if okA then
                    t.w = w
                    U.log(TAG, "screen title '%s': WBP_Screen_Title in a %d x %d box at screen (%d, %d), cap top %d "
                        .. "expected (V-FIN-03)", t.text, FT.w, boxH, FRAME.titleX, FRAME.titleCap - FT.capOffset,
                        FRAME.titleCap)
                end
            else
                U.warn(TAG, "WBP_Screen_Title unavailable (%s): text title (V-FIN-03)", tostring(w))
            end
        end
        if not t.w then
            -- fallback: [/][TITLE][tag box] in a horizontal box, the game's -32 top padding on both texts
            local hb = construct(ctx, HBOX)
            pcall(function() hb:SetVisibility(VIS.HitTestInvisible) end)
            pcall(function() box.w:AddChild(hb) end)
            local slash = childText(ctx, "pageTitle", { text = "/", colour = COL.RUST })
            hboxAdd(hb, slash.w, pad(0, -32, 0, 0), AL.t)
            t.txt = childText(ctx, "pageTitle", { text = t.text })
            hboxAdd(hb, t.txt.w, pad(0, -32, 0, 0), AL.t)
            local tagSb = construct(ctx, SIZE)
            pcall(function() tagSb:SetHeightOverride(106) end)
            local tag = construct(ctx, OVER)
            pcall(function() tagSb:AddChild(tag) end)
            local fill = childImage(ctx, { mat = MAT.CurrencyBacker, drawAs = DRAW.box, margin = 0.5, size = 106,
                                           tint = COL.RUST })
            overlayAdd(tag, fill.w)
            local inner = construct(ctx, HBOX)
            overlayAdd(tag, inner, AL.l, AL.c, pad(16, 16, 16, 16))
            local bc = childImage(ctx, { tex = TEX.TitleBarcode, dsize = { 56, 74 }, tint = COL.BONE })
            hboxAdd(inner, bc.w)
            local ly = childImage(ctx, { tex = TEX.TitleLayer, dsize = { 157, 74 }, tint = COL.BONE })
            hboxAdd(inner, ly.w, pad(2, 0, 0, 0))
            hboxAdd(hb, tagSb, pad(32, 0, 0, 0), AL.c)
            U.log(TAG, "screen title '%s': text fallback at screen (%d, %d) (UiTitleWidget = %s, V-FIN-03)", t.text,
                FRAME.titleX, FRAME.titleCap - FT.capOffset, tostring(opt("UiTitleWidget", "game")))
        end
        t.set = guard("title.set", function(s)
            if dead(t) then return end
            s = tostring(s or "")
            if s == t.text then return end
            t.text = s
            if t.w and U.ok(t.w) then
                pcall(function() t.w.HeaderText = U.ftext(s) end)       -- a Slate rebuild re-applies it (PreConstruct)
                pcall(function() t.w:SetScreenTitleText(U.ftext(s)) end) -- SetScreenTitleText(Text)
            elseif t.txt then
                T.set(t.txt, { text = s })
            end
        end)
        t.show = guard("title.show", function(on) if not dead(t) then T.set(t.e, { visible = on ~= false }) end end)
        return t
    end)
end

---------------------------------------------------------------------------------------------------- C3 step row
-- One line in the game's tab style at (128, 420): done = tick + value INK, current = RUST pill (72 tall, 36 padding)
-- with the step name in STATUS, upcoming = GREY; gap 56. A done value wider than 720 su drops a leading "THE ", then
-- trailing words with an ellipsis; a row past x 3712 cuts its longest done value further (never under 300 su).
local function fitValue(s, cap)
    local function w(x) return T.textWidth(x, ROLE.stepLabel) end
    if w(s) <= cap then return s end
    if s:sub(1, 4) == "THE " then
        s = s:sub(5)
        if w(s) <= cap then return s end
    end
    local words = {}
    for x in s:gmatch("%S+") do words[#words + 1] = x end
    local out = s
    while #words > 1 do
        table.remove(words)
        while #words > 1 and (words[#words] == "·" or words[#words] == "-" or words[#words] == "\u{00B7}") do
            table.remove(words)
        end
        out = table.concat(words, " ") .. "\u{2026}"
        if w(out) <= cap then return out end
    end
    return out
end

function T.stepRow(ctx, cv, geo)
    return build("stepRow", function()
        checkCtx(ctx, cv)
        geo = geoOr(geo)
        local F = FRAME.steps
        local r = { kind = "steprow", gen = R.gen, items = {}, sig = nil }
        local hb = container(ctx, cv, HBOX, 2, VIS.HitTestInvisible)
        local x, y = L(geo, F.x, F.y)
        rectSet(hb, { x, y })
        r.e = hb
        for i = 1, F.n do
            local it = {}
            it.sb = construct(ctx, SIZE)
            pcall(function() it.sb:SetHeightOverride(F.h) end)
            it.slot = hboxAdd(hb.w, it.sb, nil, AL.c)
            local ov = construct(ctx, OVER)
            pcall(function() it.sb:AddChild(ov) end)
            it.pill = childImage(ctx, { mat = MAT.Tab, drawAs = DRAW.box, margin = 0.5, size = F.h, tint = COL.RUST,
                                        visible = false })
            overlayAdd(ov, it.pill.w)
            it.inner = construct(ctx, HBOX)
            it.innerSlot = overlayAdd(ov, it.inner, AL.l, AL.c)
            it.tick = childImage(ctx, { tex = TEX.Tick, dsize = { F.tick, F.tick }, tint = COL.INK, visible = false })
            hboxAdd(it.inner, it.tick.w, pad(0, 0, F.tickGap, 0))
            it.txt = childText(ctx, "stepLabel", { text = "" })
            hboxAdd(it.inner, it.txt.w)
            it.c = {}
            pcall(function() it.sb:SetVisibility(VIS.Collapsed) end)
            r.items[i] = it
        end
        r.render = guard("steprow.render", function(list)
            if dead(r) then return end
            list = type(list) == "table" and list or {}
            -- labels with the width budget
            local labels, widths, total = {}, {}, 0
            for i = 1, min(#list, F.n) do
                local s = tostring(list[i].label or list[i][1] or "")
                local st = list[i].state or "next"
                if st == "done" then s = fitValue(s, F.cap) end
                labels[i] = s
            end
            local function rowWidth()
                total = 0
                for i = 1, #labels do
                    local st = list[i].state or "next"
                    widths[i] = T.textWidth(labels[i], ROLE.stepLabel)
                    total = total + widths[i] + ((i > 1) and F.gap or 0)
                        + ((st == "done") and (F.tick + F.tickGap) or 0)
                        + ((st == "current") and 2 * F.pad or 0)
                end
                return total
            end
            local limit = FRAME.margin.r - F.x
            local guardN = 0
            while rowWidth() > limit and guardN < 12 do
                guardN = guardN + 1
                local wi, ww = nil, 0
                for i = 1, #labels do
                    if (list[i].state or "next") == "done" and widths[i] > ww and widths[i] > F.minCap then
                        wi, ww = i, widths[i]
                    end
                end
                if not wi then break end
                local cut = fitValue(tostring(list[wi].label or list[wi][1] or ""), max(F.minCap, ww - (total - limit)))
                if cut == labels[wi] then break end
                labels[wi] = cut
            end
            local sig = {}
            for i = 1, #labels do sig[#sig + 1] = (list[i].state or "next") .. ":" .. labels[i] end
            sig = table.concat(sig, "|")
            if sig == r.sig then return end
            r.sig = sig
            for i = 1, F.n do
                local it = r.items[i]
                local s = labels[i]
                if not s then
                    if it.c.on ~= false and pcall(function() it.sb:SetVisibility(VIS.Collapsed) end) then it.c.on = false end
                else
                    local st = list[i].state or "next"
                    local cur = st == "current"
                    local left = ((i == 1) and 0 or F.gap) - (cur and F.pad or 0)
                    if it.c.left ~= left and pcall(function() it.slot:SetPadding(pad(left, 0, 0, 0)) end) then
                        it.c.left = left
                    end
                    local ip = cur and F.pad or 0
                    if it.c.ip ~= ip and pcall(function() it.innerSlot:SetPadding(pad(ip, 0, ip, 0)) end) then
                        it.c.ip = ip
                    end
                    T.set(it.pill, { visible = cur })
                    T.set(it.tick, { visible = st == "done" })
                    T.set(it.txt, { text = s, colour = (st == "done" and COL.INK) or (cur and COL.STATUS) or COL.GREY })
                    if it.c.on ~= true and pcall(function() it.sb:SetVisibility(VIS.HitTestInvisible) end) then
                        it.c.on = true
                    end
                end
            end
            U.dbg(TAG, "step row: %s (about %d su wide)", sig, rnd(total))
        end)
        r.show = guard("steprow.show", function(on) if not dead(r) then T.set(r.e, { visible = on ~= false }) end end)
        return r
    end)
end

---------------------------------------------------------------------------------------------------- C4 command row
-- Fixed slots bottom right (§6.4): back (3292, cmdY, 420, 96), start (2660, ...), save (1928, ...). Each button =
-- WBP_CommonButtonBacker_Pill (ColorBase TILE @0.9, ColorSelect WHITE, ColorUnselect #D3D2C6 before the add; focus =
-- Img_Tile_Select_Thick visible, fill TILE, inner line off) or, with UiHeroPill = "painted" / a failed Create, painted
-- MI_UI_Pill_Generic + MI_UI_Pill_Btn_Hero(_Thick) images (V-FIN-16); a heroLabel centred on it; a ghost over it.
-- A hidden slot is collapsed: the rects never move. c.poll paints hover, else the c.look override, else ghost focus.
function T.commandRow(ctx, cv, geo, defs)
    return build("commandRow", function()
        checkCtx(ctx, cv)
        geo = geoOr(geo)
        local F = FRAME.cmd
        local cy = tonumber(geo.cmdY) or F.y
        local c = { kind = "cmdrow", gen = R.gen, btn = {}, order = {}, forced = nil, showGen = R.showGen }
        local painted = opt("UiHeroPill", "backer") == "painted"
        for _, d in ipairs(type(defs) == "table" and defs or {}) do
            -- d.rect {x, y, w, h} (screen su; y is replaced by the row's y): a pill wider than its slot (GP page:
            -- "START GRAND PRIX" overflowed the 600-su start slot into BACK, live 2026-10-15)
            local slot = (type(d.rect) == "table" and d.rect[3] and d.rect) or (d.id and F.slots[d.id])
            if not slot then
                U.logOnce("theme.cmd?" .. tostring(d.id), TAG, "command row: no slot for id '%s' (back | start | save)",
                    tostring(d.id))
            else
                local rx, ry, rw, rh = slot[1], cy, slot[3], slot[4]
                local lx, ly = L(geo, rx, ry)
                local b = { id = d.id, rect = { rx, ry, rw, rh }, shown = true, look = nil }
                if not painted then
                    local ok, w = pcall(create, ctx, T.WBP.ButtonBackerPill)
                    if ok then
                        pcall(function() w.ColorBase = lin(TILE09) end)
                        pcall(function() w.ColorSelect = lin(COL.WHITE) end)
                        pcall(function() w.ColorUnselect = lin(COL.UNSELECT) end)
                        pcall(function() w:SetVisibility(VIS.HitTestInvisible) end)
                        local s = onCanvas(cv, w, 5)
                        b.backer = newEl("widget", w, s, {})
                        b.backer.c.vis = VIS.HitTestInvisible
                        pcall(function() w:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
                        rectSet(b.backer, { lx, ly, rw, rh })
                    else
                        U.warn(TAG, "WBP_CommonButtonBacker_Pill unavailable (%s): painted pills (V-FIN-16)", tostring(w))
                    end
                end
                if not b.backer then
                    b.fill = T.image(ctx, cv, { mat = MAT.Pill, drawAs = DRAW.box, margin = 0.5, size = rh, tint = TILE09,
                                               z = 5, rect = { lx, ly, rw, rh } })
                    b.inner = T.image(ctx, cv, { mat = MAT.PillHero, drawAs = DRAW.box, margin = 0.48, size = rh,
                                                tint = alpha(COL.UNSELECT, 0.55), z = 5, rect = { lx, ly, rw, rh } })
                    b.thick = T.image(ctx, cv, { mat = MAT.PillHeroThick, drawAs = DRAW.box, margin = 0.48, size = rh,
                                                tint = COL.WHITE, z = 5, rect = { lx, ly, rw, rh }, visible = false })
                    for _, p in ipairs({ b.fill, b.inner, b.thick }) do
                        pcall(function() p.w:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
                    end
                end
                b.label = T.text(ctx, cv, "heroLabel", { text = d.label or string.upper(d.id), z = 6, align = { 0.5, 0.5 },
                                                         rect = { lx + rw / 2, ly + rh / 2 } })
                local gopts = { geo = geo, z = 7 }
                for k, v in pairs(type(d.opts) == "table" and d.opts or {}) do gopts[k] = v end
                b.ghost = T.ghost(ctx, cv, b.rect, d.ghostId or ("cmd:" .. d.id), d.fn, gopts)
                if b.label then pcall(function() b.label.w:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end) end
                c.btn[d.id] = b
                c.order[#c.order + 1] = d.id
            end
        end
        if #c.order == 0 then error("no command buttons") end

        local function paint(b, look)
            if b.look == look then return end
            b.look = look
            local on = look == "focus"
            if b.backer and live(b.backer) then
                local w = b.backer.w
                pcall(function() w.Img_Tile_Select_Thick:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end)
                pcall(function() w.Img_Tile_UnSelect_Inner:SetVisibility(on and VIS.Collapsed or VIS.HitTestInvisible) end)
                pcall(function() w.Img_Tile_Fill:SetColorAndOpacity(lin(on and COL.TILE or TILE09)) end)
                scaleSet(b.backer, on and 1.05 or 1)
            else
                T.set(b.fill, { colour = on and COL.TILE or TILE09, scale = on and 1.05 or 1 })
                T.set(b.inner, { visible = not on, scale = on and 1.05 or 1 })
                T.set(b.thick, { visible = on, scale = on and 1.05 or 1 })
            end
            T.set(b.label, { colour = on and COL.WHITE or COL.MIST, scale = on and 1.05 or 1 })
        end

        local function setShown(b, on)
            b.shown = on
            if b.backer and live(b.backer) then b.backer.want = on; applyVis(b.backer) end
            T.set(b.fill, { visible = on })
            T.set(b.inner, { visible = on and b.look ~= "focus" })
            T.set(b.thick, { visible = on and b.look == "focus" })
            T.set(b.label, { visible = on })
            if b.ghost then T.set(b.ghost, { visible = on }) end
            if not on then paint(b, "idle") end
        end

        c.show = guard("cmd.show", function(m)
            if dead(c) or type(m) ~= "table" then return end
            for _, id in ipairs(c.order) do
                local b = c.btn[id]
                local on = m[id]
                if on == nil then on = (id == "back") and b.shown or false end
                on = on and true or false
                if b.shown ~= on or b.c0 == nil then b.c0 = true; setShown(b, on) end
            end
        end)
        -- look = "focus" | "idle" paints at once and holds a keyboard focus (setup.commandFocus); nil / "auto" releases.
        c.look = guard("cmd.look", function(id, look)
            if dead(c) then return end
            local b = c.btn[id]
            if not b then return end
            if look == "focus" then c.forced = id
            elseif c.forced == id then c.forced = nil end
            if look == "focus" or look == "idle" then paint(b, look) end
        end)
        c.poll = guard("cmd.poll", function(p1)
            if dead(c) then return nil end
            pump(nowMs(), true)                           -- a per-tick entry: opens this tick's texture window
            if c.showGen ~= R.showGen then                -- page re-shown: a Slate rebuild reset the backers' looks
                c.showGen = R.showGen
                for _, b in pairs(c.btn) do b.look = nil end
            end
            local hov, foc
            for _, id in ipairs(c.order) do
                local b = c.btn[id]
                if b.shown and U.ok(b.ghost) then
                    local f, h = T.isFocused(b.ghost, p1)
                    if h and not hov then hov = id end
                    if f and not foc then foc = id end
                end
            end
            local want = hov or c.forced or foc
            for _, id in ipairs(c.order) do
                local b = c.btn[id]
                paint(b, (b.shown and id == want) and "focus" or "idle")
            end
            return want, foc, hov
        end)
        c.widget = function(id) local b = c.btn[id]; return b and b.ghost or nil end
        -- couch-fix59 (AUTO-145e): a button's label (an armed press-twice confirmation shows it on the row)
        c.label = guard("cmd.label", function(id, text)
            local b = c.btn[id]
            if b and b.label and b.text ~= text then b.text = text; T.set(b.label, { text = text }) end
        end)
        c.rect = function(id) local b = c.btn[id]; return b and b.rect or nil end
        for _, id in ipairs(c.order) do paint(c.btn[id], "idle") end
        U.log(TAG, "command row: %s at y %d (%s pills, V-FIN-16)", table.concat(c.order, ", "), rnd(cy),
            c.btn[c.order[1]].backer and "WBP_CommonButtonBacker_Pill" or "painted")
        return c
    end)
end

---------------------------------------------------------------------------------------------------- C5 status pill
-- The game's bottom-left toast (ref-15): a CHAR pill (warn RUST) from the screen's left edge, centre y 2079, 120 tall
-- (168 on 2 lines; 0.12.0: its bottom stays at 2139 and a second line grows it upward: centred, the 2-line pill ran
-- off the screen's bottom edge, live 2026-10-10 "CHANGING THE CLASS RESETS PLANET AND TRACK"), 5 capsules, Moki 39 STATUS text (WHITE on warn) with "(A)" / "(B)" tokens as 48-su pad glyphs, AMBER
-- pips. StatusPillPlace = "page": inside the page at (128, cmdY), left of the command row (V-FIN-12 fallback).
-- Entries: transient (ms, default StatusPillMs) or sticky (until cleared); the shown one is the highest prio, the latest
-- among equals. Defaults: transient prio 0 (one transient slot: a new one replaces it), sticky prio 2, sticky + warn 3
-- (spec §6.5: gate 3 > all ready 2 > launching 1 > transient 0); key identifies an entry for p.clear(key).
local CAPS = { { 90, 126, 162, 198, 234 }, { 200, 214, 228, 241, 255 } }   -- sRGB greys of the capsule glyph
local GLYPH_TOKEN = { A = "FaceButton_Bottom", B = "FaceButton_Right", X = "FaceButton_Left", Y = "FaceButton_Top" }

local function splitRuns(s)
    local runs, pos = {}, 1
    while true do
        local a, b, k = s:find("%(([ABXY])%)", pos)
        if not a then break end
        if a > pos then runs[#runs + 1] = { t = s:sub(pos, a - 1) } end
        runs[#runs + 1] = { g = GLYPH_TOKEN[k], raw = s:sub(a, b) }
        pos = b + 1
    end
    if pos <= #s then runs[#runs + 1] = { t = s:sub(pos) } end
    return runs
end

-- couch-fix46 (live round 1 AUTO-121, shot 145922-a16-armed: "DELETES THE COUCH CAMPAIGN SAVE AND EVERY GUEST'S
-- PROGRESS: PRESS (A) AGAIN TO DELETE" ran under the Select / Settings / Back bar, its end unreadable): a text with a
-- pad glyph had NO wrap (only a glyph-less text wrapped at F.wrap), so one long line from the screen's left edge. Now
-- the first text run wraps at what the line has left after the glyph(s) and the text after them; two lines when it
-- does. Pure: slots = the render's text / glyph slots, wrap = F.wrap, width(text) -> su. -> first run's wrap width
-- (0 = none), two lines?
T.PILL_GLYPH_W = 64                                         -- a 48-su glyph + its 8-su paddings
function T.pillLayout(slots, wrap, width)
    local multi = slots[2] ~= nil or slots[4] ~= nil
    local w1 = (slots[1] and slots[1] ~= "") and width(slots[1]) or 0
    if not multi then return wrap, w1 > wrap end
    local rest = 0
    for i = 2, 5 do
        local x = slots[i]
        if x ~= nil and x ~= "" then rest = rest + ((i % 2 == 0) and T.PILL_GLYPH_W or width(x)) end
    end
    if w1 + rest <= wrap then return 0, false end
    return math.max(600, wrap - rest), true
end

-- couch-fix59 (AUTO-145c, live round 4 shots r4-113 / r4-114: "PADS STAY ON UNTIL THE GAME / RESTARTS. NOT FOR ONLINE
-- PLAY: (A) AGAIN / PRESS"): the pill is ONE HBox (text / glyph / text ...), vertically centred. When the first text run
-- wraps, the glyph and the text after it sit beside the wrapped BLOCK, mid-height: the words before the glyph that wrap
-- to the last line are read after it ("(A) AGAIN PRESS"), in every locale and for every armed prompt. Pure: the pill's
-- slots for a text -> slots, first run's wrap width (0 = none), two lines?. A glyph text that fits on one line keeps its
-- glyph slots; one that needs two lines is ONE text run in reading order with its "(A)" tokens as written.
function T.pillSlots(text, wrap, width)
    local slots, si = {}, 1
    for _, r in ipairs(splitRuns(text)) do
        if r.t then slots[si] = (slots[si] or "") .. r.t
        elseif si < 5 then slots[si + 1] = r.g; si = si + 2
        else slots[5] = (slots[5] or "") .. r.raw end
    end
    local wrap1, two = T.pillLayout(slots, wrap, width)
    if two and (slots[2] ~= nil or slots[4] ~= nil) then
        local plain = { text }
        return plain, wrap, width(text) > wrap
    end
    return slots, wrap1, two
end

function T.statusPill(ctx, cv, geo)
    return build("statusPill", function()
        checkCtx(ctx, cv)
        geo = geoOr(geo)
        local F = FRAME.pill
        local inPage = opt("StatusPillPlace", "screen") == "page"
        local sc = screenOf(geo)
        local p = { kind = "pill", gen = R.gen, entries = {}, seq = 0, shown = nil, sig = nil }
        local ov = container(ctx, cv, OVER, 20, VIS.HitTestInvisible, { 0, 1 })   -- bottom-anchored (grows upward)
        local x, y
        if inPage then x, y = L(geo, F.page.x, (tonumber(geo.cmdY) or FRAME.cmd.y) + FRAME.cmd.h / 2 + F.h / 2)
        else x, y = L(geo, sc.x + F.x, F.cy + F.h / 2) end
        rectSet(ov, { x, y })
        p.e = ov
        p.bg = childImage(ctx, { mat = MAT.Pill, drawAs = DRAW.box, margin = 0.5, size = F.h, tint = COL.CHAR })
        overlayAdd(ov.w, p.bg.w)
        local sb = construct(ctx, SIZE)
        pcall(function() sb:SetMinDesiredHeight(F.h) end)
        overlayAdd(ov.w, sb, AL.fill, AL.fill)
        local hb = construct(ctx, HBOX)
        local ss
        pcall(function() ss = sb:AddChild(hb) end)        -- -> SizeBoxSlot
        local padL = inPage and 54 or (-F.x + 30)         -- capsules at screen x 30 (the pill starts at -90)
        if U.ok(ss) then
            pcall(function()
                ss:SetPadding(pad(padL, 22, 54, 22))
                ss:SetVerticalAlignment(AL.c)
                ss:SetHorizontalAlignment(AL.l)
            end)
        end
        p.caps = {}
        for i = 1, F.capsules do
            local cimg = childImage(ctx, { mat = MAT.Tab, drawAs = DRAW.box, margin = 0.5, size = 12, dsize = { 12, 42 },
                                           tint = T.hex(string.format("#%02X%02X%02X", CAPS[1][i], CAPS[1][i], CAPS[1][i])) })
            hboxAdd(hb, cimg.w, pad((i == 1) and 0 or 9, 0, 0, 0))
            p.caps[i] = cimg
        end
        p.runs, p.runSlots = {}, {}
        for i = 1, 5 do                                   -- text, glyph, text, glyph, text
            if i % 2 == 1 then
                local t = childText(ctx, "statusText", { text = "", wrapW = (i == 1) and F.wrap or 0 })
                p.runSlots[i] = hboxAdd(hb, t.w, pad((i == 1) and 42 or 0, 0, 0, 0))
                p.runs[i] = t
            else
                local g = childImage(ctx, { tex = T.glyph("A"), dsize = { 48, 48 }, tint = COL.STATUS, visible = false })
                p.runSlots[i] = hboxAdd(hb, g.w, pad(8, 0, 8, 0))
                p.runs[i] = g
            end
        end
        p.pips = {}
        for i = 1, 4 do
            local pi = childImage(ctx, { tex = TEX.CircleFill, dsize = { 36, 36 }, tint = COL.AMBER, visible = false })
            hboxAdd(hb, pi.w, pad((i == 1) and 54 or 18, 0, 0, 0))
            p.pips[i] = pi
        end
        T.set(ov, { visible = false })

        local function top(now)
            local best
            for k, e in pairs(p.entries) do
                if not e.sticky and e.untilMs and now >= e.untilMs then p.entries[k] = nil
                elseif not best or e.prio > best.prio or (e.prio == best.prio and e.seq > best.seq) then best = e end
            end
            return best
        end

        local function render(e)
            local sig = e and (e.text .. "|" .. tostring(e.warn) .. "|" .. tostring(e.pipsSig)) or ""
            if sig == p.sig then return end
            p.sig = sig
            if not e then
                T.set(ov, { visible = false })
                p.shown = nil
                return
            end
            local ink = e.warn and COL.WHITE or COL.STATUS
            local caps = e.warn and CAPS[2] or CAPS[1]
            T.set(p.bg, { colour = e.warn and COL.RUST or COL.CHAR })
            for i = 1, F.capsules do
                T.set(p.caps[i], { colour = T.hex(string.format("#%02X%02X%02X", caps[i], caps[i], caps[i])) })
            end
            -- slots text / glyph / text / glyph / text; a third token stays text "(A)" in the last slot; a glyph text
            -- that needs two lines is one text run (AUTO-145c: the reading order)
            local slots, wrap1, twoLines = T.pillSlots(e.text, F.wrap,
                function(t) return T.textWidth(t, ROLE.statusText) end)
            -- a message that starts with a glyph: the glyph keeps the capsules' 42-su gap (the empty text run collapses)
            local gl = (slots[1] == nil or slots[1] == "") and 42 or 8
            if p.c_gl ~= gl and U.ok(p.runSlots[2]) and pcall(function() p.runSlots[2]:SetPadding(pad(gl, 0, 8, 0)) end) then
                p.c_gl = gl
            end
            for i = 1, 5 do
                local el = p.runs[i]
                if i % 2 == 1 then
                    local s = slots[i]
                    T.set(el, { text = s or "", colour = ink, visible = s ~= nil and s ~= "" })
                    if i == 1 then T.set(el, { wrapW = wrap1 }) end
                else
                    local g = slots[i] and T.glyph(slots[i]) or nil
                    if g then T.set(el, { tex = g, colour = ink, visible = true }) else T.set(el, { visible = false }) end
                end
            end
            local pips = type(e.pips) == "table" and e.pips or {}
            for i = 1, 4 do
                local v = pips[i]
                if v == nil then T.set(p.pips[i], { visible = false })
                else T.set(p.pips[i], { tex = v and TEX.CircleFill or TEX.CircleFrame, visible = true }) end
            end
            -- 2 lines past 1700 su: a 168-tall pill keeps half-height corners
            local h = twoLines and F.h2 or F.h
            brushSize(p.bg, h, h)
            T.set(ov, { visible = true })
            if not p.logged then
                p.logged = true
                U.log(TAG, "status pill first shown %s (StatusPillPlace %s, V-FIN-12): %s",
                    inPage and "inside the page" or "from the screen's left edge, bottom y 2139 (1 line: centre 2079)",
                    inPage and "page" or "screen", e.text)
            else
                U.dbg(TAG, "pill: %s%s", e.text, e.warn and " [warn]" or "")
            end
            p.shown = e
        end

        p.post = guard("pill.post", function(text, o)
            if dead(p) then return end
            o = type(o) == "table" and o or {}
            local sticky = o.sticky == true
            local prio = tonumber(o.prio) or (sticky and (o.warn and 3 or 2) or 0)
            local key = o.key or (sticky and ("sticky:" .. prio) or "transient")
            text = tostring(text or "")
            if text == "" then p.entries[key] = nil
            else
                p.seq = p.seq + 1
                local now = nowMs()
                local pipsSig
                if type(o.pips) == "table" then
                    local t = {}
                    for i = 1, #o.pips do t[i] = o.pips[i] and "1" or "0" end
                    pipsSig = table.concat(t)
                end
                p.entries[key] = { text = text, warn = o.warn == true, pips = o.pips, pipsSig = pipsSig, sticky = sticky,
                                   prio = prio, seq = p.seq, untilMs = (not sticky) and
                                       (now + (tonumber(o.ms) or num("StatusPillMs", 5000))) or nil }
            end
            render(top(nowMs()))
        end)
        p.clear = guard("pill.clear", function(key)
            if dead(p) then return end
            if key == nil then p.entries = {} else p.entries[key] = nil end
            render(top(nowMs()))
        end)
        p.tick = guard("pill.tick", function(now)
            if dead(p) then return nil end
            now = tonumber(now) or nowMs()
            pump(now, true)                               -- a per-tick entry: opens this tick's texture window
            local e = top(now)
            render(e)
            return e and e.text or nil
        end)
        p.show = guard("pill.show", function(on) if not dead(p) then T.set(p.e, { visible = on ~= false and p.shown ~= nil }) end end)
        return p
    end)
end

---------------------------------------------------------------------------------------------------- C10 check badge
-- The CHOOSE MODEL selected mark (WBP_Tile_Btn B_SelectedMark): MI_UI_Squircle_FE_EquipBacker CREAM (fallback
-- T_UI_FE_TileButton_300_Fill_Cmn) + T_UI_Tick_Icn INK at 62 %.
function T.checkBadge(ctx, cv, opts)
    opts = opts or {}
    return build("checkBadge", function()
        checkCtx(ctx, cv)
        local b = { kind = "check", gen = R.gen, geo = opts.geo, c = {} }
        local z = tonumber(opts.z) or 8
        b.back = T.image(ctx, cv, { mat = MAT.EquipBacker, tint = COL.CREAM, z = z, visible = false })
        if not (b.back and b.back.ready) then
            b.back = b.back or T.image(ctx, cv, { tex = TEX.TileFill300, tint = COL.CREAM, z = z, visible = false })
            if b.back and not b.back.ready then T.set(b.back, { tex = TEX.TileFill300 }) end
        end
        b.tick = T.image(ctx, cv, { tex = TEX.Tick, tint = COL.INK, z = z + 1, visible = false })
        b.place = guard("check.place", function(cx, cy, s)
            if dead(b) then return end
            local geo = geoOr(b.geo)
            s = tonumber(s) or 64
            local x, y = L(geo, tonumber(cx) or 0, tonumber(cy) or 0)
            T.set(b.back, { rect = { x - s / 2, y - s / 2, s, s }, visible = true })
            local k = s * 0.62
            T.set(b.tick, { rect = { x - k / 2, y - k / 2, k, k }, visible = true })
        end)
        b.hide = guard("check.hide", function()
            if dead(b) then return end
            T.set(b.back, { visible = false })
            T.set(b.tick, { visible = false })
        end)
        return b
    end)
end

---------------------------------------------------------------------------------------------------- C11 lock overlay
-- Black @0.75 on the rect + T_UI_Lock_Icn BONE 66 su at (x + 40, y + 40) + the reason (Overpass Semibold Italic 30,
-- BEIGE, wraps at w - 160) at (x + 124, y + 46). The target stays focusable; A posts the reason as a warn pill.
function T.lockOverlay(ctx, cv, opts)
    opts = opts or {}
    return build("lockOverlay", function()
        checkCtx(ctx, cv)
        local l = { kind = "lock", gen = R.gen, geo = opts.geo }
        local z = tonumber(opts.z) or 9
        l.dim = T.image(ctx, cv, { tex = TEX.SolidFill, tint = alpha(COL.BLACK, 0.75), z = z, visible = false })
        l.icon = T.image(ctx, cv, { tex = TEX.Lock, tint = COL.BONE, z = z + 1, visible = false })
        l.reason = T.text(ctx, cv, "lockReason", { text = "", z = z + 1, visible = false })
        l.hide = guard("lock.hide", function()
            if dead(l) then return end
            T.set(l.dim, { visible = false })
            T.set(l.icon, { visible = false })
            T.set(l.reason, { visible = false })
        end)
        -- rect (screen su) and a reason; l.set(nil) hides it; reason nil / "" = dim + padlock without a text.
        l.set = guard("lock.set", function(rect, reason)
            if dead(l) then return end
            local r = rectOf(rect)
            if not r or not r[3] then return l.hide() end
            local geo = geoOr(l.geo)
            local x, y = L(geo, r[1], r[2])
            T.set(l.dim, { rect = { x, y, r[3], r[4] }, visible = true })
            T.set(l.icon, { rect = { x + 40, y + 40, 66, 66 }, visible = true })
            local s = tostring(reason or "")
            T.set(l.reason, { rect = { x + 124, y + 46 }, wrapW = max(0, r[3] - 160), text = s, visible = s ~= "" })
        end)
        return l
    end)
end

---------------------------------------------------------------------------------------------------- C6 poster
-- A poster tile on cv at rect: shadow (M_UI_Blur_Shadow_A Box 0.5 SHADOW @0.30, rect + 30, y + 10), art in a clipping
-- window (inset 2, cover placement by ax / ay, idle tint #E6E6E6), the focus fade (T_UI_Gradient_Vertical_A_Cmn SHADOW
-- @0.6 over the lower 60 %), border (T_UI_FE_TileStroke_UnSelect_Cmn Box 0.5, BORDER @0.92 / WHITE), the text stack
-- bottom-left at (74, h - 64) [kicker / title / desc], C10, C11. Focus: render scale 1.04, shadow @0.45, art WHITE,
-- border WHITE, kicker / desc (+ fade) shown. opts {art, ax, ay, zoom, title, titleRole, titleSize, titleCol, kicker,
-- kickerAlways (START "Launching..."), desc, check (true = top-right inset 56, or {cx, cy, s} poster-local), lock (a
-- reason; false = unlocked), dim (title opacity), scrim (a colour: the band behind the title, see below; false = none),
-- z, geo}. p.set takes the same fields (+ art, ax, ay, zoom). p.cv is the
-- poster's own canvas (poster-local su) for extra texts (event cards).
-- couch-fix59 (AUTO-145c, live round 4 shot r4-113: ADD PLAYERS' kicker ran off the 425-tall tile's top and its
-- "Press again to confirm" badge (top-right, y 24-90) sat on the 2-line title): the estimated top (poster-local su) of
-- the bottom-left text stack [kicker / title / desc] a focused poster of size w x h shows for o = {kicker, title,
-- titleSize, desc}. Line heights from the roles' em (size x 4/3): Moki titles x lineH x 1.1, Overpass x 1.25 (the shot:
-- the 2-line title 134 su).
function T.posterStackTop(w, h, o)
    local wrapW = math.max(1, w - 148)
    local function lines(text, r, size)
        local n = 0
        for part in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
            n = n + math.max(1, math.ceil(T.textWidth(part, r, size) / wrapW))
        end
        return n
    end
    local function em(r, size) r = roleOf(r); return (tonumber(size) or r.size) * 4 / 3 end
    local hgt = 64
    if o.kicker ~= nil and tostring(o.kicker) ~= "" then hgt = hgt + lines(o.kicker, "posterKicker") * em("posterKicker") * 1.25 + 18 end
    if o.title ~= nil and tostring(o.title) ~= "" then
        local tr = roleOf("posterTitle")
        hgt = hgt + lines(o.title, tr, o.titleSize) * em(tr, o.titleSize) * (tr.lineH or 1) * 1.1
    end
    if o.desc ~= nil and tostring(o.desc) ~= "" then hgt = hgt + 16 + lines(o.desc, "posterDesc") * em("posterDesc") * 1.25 end
    return h - hgt
end

function T.poster(ctx, cv, rect, opts)
    opts = opts or {}
    return build("poster", function()
        checkCtx(ctx, cv)
        local geo = geoOr(opts.geo)
        local r = rectOf(rect)
        if not (r and r[3] and r[4]) then error("poster rect needs x, y, w, h") end
        local w, h = r[3], r[4]
        local P = { kind = "poster", gen = R.gen, w = w, h = h, focused = false, rect = r, opts = {} }
        local root = container(ctx, cv, CANVAS, tonumber(opts.z) or 1, VIS.HitTestInvisible)
        local x, y = L(geo, r[1], r[2])
        rectSet(root, { x, y, w, h })
        pcall(function() root.w:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
        P.e, P.cv = root, root.w
        local pc = root.w
        P.shadow = T.image(ctx, pc, { mat = MAT.BlurShadow, drawAs = DRAW.box, margin = 0.5, size = 128,
                                      tint = COL.SHADOW, z = 0, rect = { -30, -20, w + 60, h + 60 } })
        -- art window: clipping SizeBox > canvas > art image
        local win = construct(ctx, SIZE)
        pcall(function() win:SetClipping(CLIP) end)
        pcall(function() win:SetVisibility(VIS.HitTestInvisible) end)
        local ws = onCanvas(pc, win, 1)
        local winEl = newEl("box", win, ws, {})
        rectSet(winEl, { 2, 2, w - 4, h - 4 })
        local acv = construct(ctx, CANVAS)
        pcall(function() win:AddChild(acv) end)
        P.art = T.image(ctx, acv, { tint = COL.ART_IDLE, z = 0, visible = false })
        if P.art then P.art.cover = { bw = w - 4, bh = h - 4, ax = opts.ax or 0.5, ay = opts.ay or 0.5, zoom = opts.zoom } end
        -- opts.scrim (0.12.0): a band of the art's own base colour behind the title, for light art with DEEP ink whose
        -- dark shapes run under it (the MODE strips FULL GRID / MIXED, live 2026-10-10): @0.85, solid to the title's end
        -- + 40, then T_UI_Gradient_Vertical_A_Cmn turned 90 degrees COUNTER-clockwise over SCRIM_FADE su (the texture is
        -- opaque at its TOP: alpha 255 to 3/8 of the height, 0 at the bottom; -90 puts that edge on the left, against the
        -- solid band; +90 put it on the right and left a hard edge at both ends of the fade, live 2026-10-10). In the art window (clipped like the art); the colour given is the idle look (art x ART_IDLE),
        -- divided by ART_IDLE while focused (the art is WHITE then).
        P.scrimS = T.image(ctx, acv, { tex = TEX.SolidFill, z = 1, visible = false })
        P.scrimG = T.image(ctx, acv, { tex = TEX.GradientV, z = 1, visible = false })
        if P.scrimG then pcall(function() P.scrimG.w:SetRenderTransformAngle(-90) end) end
        P.fade = T.image(ctx, pc, { tex = TEX.GradientV, tint = alpha(COL.SHADOW, 0.6), z = 2,
                                    rect = { 2, h * 0.4, w - 4, h * 0.6 - 2 }, visible = false })
        P.border = T.image(ctx, pc, { tex = TEX.TileStroke, drawAs = DRAW.box, margin = 0.5, size = 128,
                                      tint = COL.BORDER, z = 8, rect = { 0, 0, w, h } })
        -- z: shadow 0, art 1, fade 2, lock 3-4 (the title stays readable over the dim), texts 5, badge 6-7, border 8
        -- bottom-left text stack, growing upward
        local stack = container(ctx, pc, VBOX, 5, VIS.HitTestInvisible, { 0, 1 })
        rectSet(stack, { 74, h - 64 })
        P.stack = stack
        local wrapW = max(0, w - 148)
        P.kicker = childText(ctx, "posterKicker", { text = "", wrapW = wrapW, visible = false })
        vboxAdd(stack.w, P.kicker.w, pad(0, 0, 0, 18))
        local tr = roleOf(opts.titleRole or "posterTitle")
        P.title = childText(ctx, tr, { text = "", wrapW = wrapW, size = opts.titleSize, visible = false })
        vboxAdd(stack.w, P.title.w)
        P.desc = childText(ctx, "posterDesc", { text = "", wrapW = wrapW, visible = false })
        vboxAdd(stack.w, P.desc.w, pad(0, 16, 0, 0))
        P.badge = T.checkBadge(ctx, pc, { geo = { x = 0, y = 0 }, z = 6 })
        P.lock = T.lockOverlay(ctx, pc, { geo = { x = 0, y = 0 }, z = 3 })

        local SCRIM_FADE, SCRIM_A = 360, 0.85
        local function layoutScrim()
            local o = P.opts
            local c = o.scrim
            local hasTitle = o.title ~= nil and tostring(o.title) ~= ""
            if type(c) ~= "table" or not hasTitle then
                T.set(P.scrimS, { visible = false }); T.set(P.scrimG, { visible = false })
                return
            end
            if P.focused then
                local k = COL.ART_IDLE
                c = { R = min(1, c.R / max(k.R, 0.01)), G = min(1, c.G / max(k.G, 0.01)), B = min(1, c.B / max(k.B, 0.01)),
                      A = 1 }
            end
            c = alpha(c, SCRIM_A)
            local ww, wh = w - 4, h - 4
            local x1 = min(ww, 72 + T.textWidth(tostring(o.title), tr, o.titleSize or tr.size) + 40)
            T.set(P.scrimS, { rect = { 0, 0, x1, wh }, colour = c, visible = true })
            local gw = min(SCRIM_FADE, ww - x1)
            if gw > 4 then   -- the box before the turn: wh wide, gw tall, centred on the visible band (x1 .. x1 + gw)
                -- the gradient texture's opaque end is not white: the tint is divided by its value so the fade starts
                -- at the solid band's exact colour. Measured live 2026-10-10 on both MODE posters (fade start / band, flat
                -- rows, 720p): 0.933 with 0.835 (the texel guess), 0.973 with 0.75, 0.999 with 0.70, 1.028 with 0.65
                local k = 0.70
                local cg = { R = min(1, c.R / k), G = min(1, c.G / k), B = min(1, c.B / k), A = c.A }
                T.set(P.scrimG, { rect = { x1 + gw / 2 - wh / 2, wh / 2 - gw / 2, wh, gw }, colour = cg, visible = true })
            else
                T.set(P.scrimG, { visible = false })
            end
        end

        local function refreshTexts()
            local o = P.opts
            local hasTitle = o.title ~= nil and tostring(o.title) ~= ""
            T.set(P.title, { text = o.title or "", visible = hasTitle, colour = o.titleCol or tr.colour,
                             size = o.titleSize or tr.size, opacity = tonumber(o.dim) or 1 })
            local k = (P.focused or o.kickerAlways == true) and o.kicker ~= nil and tostring(o.kicker) ~= ""
            local d = P.focused and o.desc ~= nil and tostring(o.desc) ~= ""
            local light = o.titleCol ~= nil and canon(o.titleCol) == COL.DEEP     -- light art: DEEP texts
            T.set(P.kicker, { text = o.kicker or "", visible = k,
                              colour = light and COL.DEEP or ROLE.posterKicker.colour })
            T.set(P.desc, { text = o.desc or "", visible = d, colour = light and COL.DEEP or ROLE.posterDesc.colour })
            T.set(P.fade, { visible = P.focused and (k or d) })
        end

        P.set = guard("poster.set", function(f)
            if dead(P) or type(f) ~= "table" then return end
            local o = P.opts
            for _, k in ipairs({ "title", "titleCol", "titleSize", "kicker", "kickerAlways", "desc", "dim", "scrim" }) do
                if f[k] ~= nil then o[k] = f[k] end
            end
            if (f.ax ~= nil or f.ay ~= nil or f.zoom ~= nil) and P.art and P.art.cover then
                local cvr = P.art.cover
                cvr.ax, cvr.ay, cvr.zoom = f.ax or cvr.ax, f.ay or cvr.ay, f.zoom or cvr.zoom
                placeCover(P.art)
            end
            if f.art ~= nil then
                if f.art == false or f.art == "" then T.set(P.art, { visible = false })
                else T.set(P.art, { tex = f.art, visible = true }) end
            end
            refreshTexts()
            layoutScrim()
            if f.check ~= nil then
                if f.check == false then P.badge.hide()
                elseif type(f.check) == "table" then P.badge.place(f.check[1], f.check[2], f.check[3])
                else P.badge.place(w - 56, 56, 64) end
            end
            if f.lock ~= nil then
                if f.lock == false then P.lock.hide() else P.lock.set({ 0, 0, w, h }, f.lock) end
            end
        end)
        P.focus = guard("poster.focus", function(on)
            if dead(P) then return end
            on = on and true or false
            if P.focused == on and P.c0 then return end
            P.focused, P.c0 = on, true
            scaleSet(P.e, on and 1.04 or 1)
            T.set(P.shadow, { colour = alpha(COL.SHADOW, on and 0.45 or 0.30) })
            T.set(P.border, { colour = on and COL.WHITE or COL.BORDER })
            T.set(P.art, { colour = on and COL.WHITE or COL.ART_IDLE })
            refreshTexts()
            layoutScrim()
        end)
        P.show = guard("poster.show", function(on) if not dead(P) then T.set(P.e, { visible = on ~= false }) end end)
        local init = {}
        for _, k in ipairs({ "art", "title", "titleCol", "titleSize", "kicker", "kickerAlways", "desc", "check", "lock",
                             "dim", "scrim" }) do
            init[k] = opts[k]
        end
        P.set(init)
        P.focus(false)
        return P
    end)
end

---------------------------------------------------------------------------------------------------- C8 settings row
-- The game's SETTINGS row (rc-14) on cv at rect (h 96): RUST pill (focused / hovered) + CHEVRON 30 su at x - 40, mirrored
-- to point at the row; label rowLabel at x + 39; the value right-aligned at w - 39: [arrow][value][arrow] (cycle,
-- arrows when focused or arrows = "always"), [state word][toggle] (toggle: T_UI_Squircle_Setting_Fill_Cmn 99 x 48
-- black / WHITE + handle 30 TOGGLE left OFF, right ON). Disabled: GREY, no arrows, the own ghost collapsed.
-- opts {geo, id, fn, ghost (ui opts), z}: with id + fn the row places its own ghost (r.ghost; r.poll(p1) paints it).
function T.settingsRow(ctx, cv, rect, opts)
    opts = opts or {}
    return build("settingsRow", function()
        checkCtx(ctx, cv)
        local geo = geoOr(opts.geo)
        local r0 = rectOf(rect)
        if not (r0 and r0[3]) then error("settings row rect needs x, y, w[, h]") end
        local w, h = r0[3], r0[4] or 96
        local row = { kind = "row", gen = R.gen, st = {}, rect = { r0[1], r0[2], w, h } }
        local root = container(ctx, cv, CANVAS, tonumber(opts.z) or 3, VIS.HitTestInvisible)
        local x, y = L(geo, r0[1], r0[2])
        rectSet(root, { x, y, w, h })
        row.e = root
        local pc = root.w
        row.pill = T.image(ctx, pc, { mat = MAT.Pill, drawAs = DRAW.box, margin = 0.5, size = h, tint = COL.RUST, z = 0,
                                      rect = { 0, 0, w, h }, visible = false })
        row.chev = T.image(ctx, pc, { tex = TEX.ArrowB, tint = COL.CHEVRON, z = 1, flipX = true, align = { 0.5, 0.5 },
                                      rect = { -40, h / 2, 30, 30 }, visible = false })
        row.label = T.text(ctx, pc, "rowLabel", { text = "", z = 2, align = { 0, 0.5 }, rect = { 39, h / 2 } })
        local vb = container(ctx, pc, HBOX, 2, VIS.HitTestInvisible, { 1, 0.5 })
        rectSet(vb, { w - 39, h / 2 })
        row.al = childImage(ctx, { tex = TEX.ArrowB, dsize = { 27, 27 }, tint = COL.WHITE, visible = false })
        hboxAdd(vb.w, row.al.w, pad(0, 0, 18, 0))
        row.value = childText(ctx, "rowValue", { text = "" })
        hboxAdd(vb.w, row.value.w)
        row.ar = childImage(ctx, { tex = TEX.ArrowB, dsize = { 27, 27 }, tint = COL.WHITE, flipX = true, visible = false })
        hboxAdd(vb.w, row.ar.w, pad(18, 0, 0, 0))
        row.state = childText(ctx, "rowState", { text = "", visible = false })
        hboxAdd(vb.w, row.state.w, pad(0, 0, 24, 0))
        local tsb = construct(ctx, SIZE)
        pcall(function() tsb:SetWidthOverride(99); tsb:SetHeightOverride(48) end)
        pcall(function() tsb:SetVisibility(VIS.Collapsed) end)
        row.toggleBox = newEl("box", tsb, nil, { vis = VIS.HitTestInvisible })
        row.toggleBox.c.vis = VIS.Collapsed
        row.toggleBox.want = false
        hboxAdd(vb.w, tsb)
        local tov = construct(ctx, OVER)
        pcall(function() tsb:AddChild(tov) end)
        row.tfill = childImage(ctx, { tex = TEX.SettingFill, tint = COL.BLACK })
        overlayAdd(tov, row.tfill.w)
        row.knob = childImage(ctx, { tex = TEX.SettingHandle, dsize = { 30, 30 }, tint = COL.TOGGLE })
        row.knobSlot = overlayAdd(tov, row.knob.w, AL.l, AL.c, pad(12, 0, 12, 0))
        if opts.id and opts.fn then
            local gopts = { geo = geo }
            for k, v in pairs(type(opts.ghost) == "table" and opts.ghost or {}) do gopts[k] = v end
            row.ghost = T.ghost(ctx, cv, row.rect, opts.id, opts.fn, gopts)
        end

        row.set = guard("row.set", function(f)
            if dead(row) or type(f) ~= "table" then return end
            local s = row.st
            for _, k in ipairs({ "label", "value", "kind", "on", "focused", "enabled", "arrows" }) do
                if f[k] ~= nil then s[k] = f[k] end
            end
            local kind = s.kind or "value"
            local enabled = s.enabled ~= false
            local foc = enabled and s.focused == true
            T.set(row.pill, { visible = foc })
            T.set(row.chev, { visible = foc })
            local ink = (not enabled and COL.GREY) or (foc and COL.WHITE) or COL.NEAR
            T.set(row.label, { text = s.label or "", colour = ink })
            local isToggle = kind == "toggle"
            local arrows = enabled and kind == "cycle" and (foc or s.arrows == "always")
            local arrowCol = foc and COL.WHITE or COL.GREY
            T.set(row.al, { visible = arrows, colour = arrowCol })
            T.set(row.ar, { visible = arrows, colour = arrowCol })
            local vink = (not enabled and COL.GREY) or (foc and COL.WHITE) or COL.INK
            T.set(row.value, { text = isToggle and "" or tostring(s.value or ""), colour = vink, visible = not isToggle })
            local on = s.on == true
            local word = s.value
            if isToggle and (word == nil or word == "") then word = on and "ON" or "OFF" end
            T.set(row.state, { text = isToggle and tostring(word) or "", visible = isToggle,
                               colour = (not enabled and COL.GREY) or (foc and COL.WHITE) or COL.GREY })
            row.toggleBox.want = isToggle
            applyVis(row.toggleBox)
            if isToggle then
                T.set(row.tfill, { colour = foc and COL.WHITE or COL.BLACK })
                local ha = on and AL.r or AL.l
                if row.c_ha ~= ha and pcall(function() row.knobSlot:SetHorizontalAlignment(ha) end) then row.c_ha = ha end
            end
            if row.ghost then
                local gv = enabled and not row.hidden
                if row.c_gv ~= gv then
                    row.c_gv = gv
                    T.set(row.ghost, { visible = gv })
                end
            end
        end)
        -- the own ghost's focus / hover -> the painted look; returns focused (or hovered)
        row.poll = guard("row.poll", function(p1)
            if dead(row) or not row.ghost then return false end
            local f, hv = T.isFocused(row.ghost, p1)
            local on = (f or hv) and row.st.enabled ~= false
            if row.st.focused ~= on then row.set({ focused = on }) end
            return on, f, hv
        end)
        row.show = guard("row.show", function(on)
            if dead(row) then return end
            row.hidden = on == false
            T.set(row.e, { visible = not row.hidden })
            if row.ghost then
                row.c_gv = not row.hidden and row.st.enabled ~= false
                T.set(row.ghost, { visible = row.c_gv })
            end
        end)
        row.set({ label = "", value = "", kind = "value", focused = false, enabled = true })
        return row
    end)
end

---------------------------------------------------------------------------------------------------- C9 group header
-- Moki 42 INK at (x0, y) + a 6-su INK rule (T_UI_Line_Divider_Hor_Cmn) from the text end + 24 to x1.
function T.groupHeader(ctx, cv, x0, x1, y, label, opts)
    opts = opts or {}
    return build("groupHeader", function()
        checkCtx(ctx, cv)
        local geo = geoOr(opts.geo)
        local g = { kind = "group-header", gen = R.gen, label = nil }
        local lx, ly = L(geo, tonumber(x0) or 0, tonumber(y) or 0)
        local lx1 = (tonumber(x1) or 0) - geo.x
        g.txt = T.text(ctx, cv, "groupHeader", { text = "", z = 2, rect = { lx, ly } })
        g.rule = T.image(ctx, cv, { tex = TEX.Divider, tint = COL.INK, z = 2, rect = { lx, ly + 23, 0, 6 } })
        g.set = guard("group.set", function(s)
            if dead(g) then return end
            s = tostring(s or "")
            if s == g.label then return end
            g.label = s
            T.set(g.txt, { text = s })
            local rx = lx + T.textWidth(s, ROLE.groupHeader) + 24
            T.set(g.rule, { rect = { rx, ly + 23, max(0, lx1 - rx), 6 }, visible = lx1 - rx > 0 })
        end)
        g.show = guard("group.show", function(on)
            if dead(g) then return end
            T.set(g.txt, { visible = on ~= false })
            T.set(g.rule, { visible = on ~= false })
        end)
        g.set(label)
        return g
    end)
end

---------------------------------------------------------------------------------------------------- C12 detail column
-- The SETTINGS screen's help column at (x, y), width w: Aurebesh line (18 LS 200 INK), detailTitle (Moki 90, wraps at
-- w), 6-su INK rule, body = helpText (FuseTextBlock) or DT_RichText_Body_Dark_Italic (FuseRichTextBlock) when it carries
-- <H1> keywords or rich = true, foot = helpFoot lines. d.bottom() -> screen y under the last line (live layout when
-- available, else an estimate from the font widths).
function T.detailColumn(ctx, cv, x, y, w, opts)
    opts = opts or {}
    return build("detailColumn", function()
        checkCtx(ctx, cv)
        local geo = geoOr(opts.geo)
        w = tonumber(w) or 1430
        local d = { kind = "detail", gen = R.gen, st = {}, x = tonumber(x) or 0, y = tonumber(y) or 0, w = w }
        local column = container(ctx, cv, VBOX, tonumber(opts.z) or 2, VIS.HitTestInvisible)
        local lx, ly = L(geo, d.x, d.y)
        rectSet(column, { lx, ly })
        d.e = column
        d.aure = childText(ctx, "aure", { text = "", wrapW = w })
        vboxAdd(column.w, d.aure.w, pad(0, 0, 0, 4))
        d.title = childText(ctx, "detailTitle", { text = "", wrapW = w })
        vboxAdd(column.w, d.title.w)
        local rsb = construct(ctx, SIZE)
        pcall(function() rsb:SetWidthOverride(w); rsb:SetHeightOverride(6) end)
        vboxAdd(column.w, rsb, pad(0, 30, 0, 30))
        d.rule = childImage(ctx, { tex = TEX.Divider, tint = COL.INK })
        pcall(function() rsb:AddChild(d.rule.w) end)
        d.body = childText(ctx, "helpText", { text = "", wrapW = w })
        vboxAdd(column.w, d.body.w)
        -- rich body: DT_RichText_Body_Dark_Italic (Semibold Italic 31.5 #222221, <H1> Black Italic RUST)
        local rich = construct(ctx, RICH)
        local dt = assetObj(matObjs, T.FONT.richDarkItalic)
        if dt then pcall(function() rich:SetTextStyleSet(dt) end) end
        pcall(function() rich.WrapTextAt = w end)         -- before the add (RC-3)
        pcall(function() rich:SetVisibility(VIS.Collapsed) end)
        d.rich = newEl("rich", rich, nil, { t = rich })
        d.rich.c.vis, d.rich.want = VIS.Collapsed, false
        vboxAdd(column.w, rich)
        d.foot = {}
        for i = 1, 3 do
            local f = childText(ctx, "helpFoot", { text = "", wrapW = w, visible = false })
            vboxAdd(column.w, f.w, pad(0, (i == 1) and 24 or 6, 0, 0))
            d.foot[i] = f
        end
        d.set = guard("detail.set", function(f)
            if dead(d) or type(f) ~= "table" then return end
            local s = d.st
            for _, k in ipairs({ "aure", "title", "body", "rich", "foot" }) do if f[k] ~= nil then s[k] = f[k] end end
            local title = tostring(s.title or "")
            T.set(d.aure, { text = tostring(s.aure or title) })
            T.set(d.title, { text = title })
            local body = tostring(s.body or "")
            local isRich = s.rich == true or (s.rich ~= false and body:find("<H%d>") ~= nil)
            if isRich then
                if d.rich.c.s ~= body and pcall(function() rich:SetText(U.ftext(body)) end) then d.rich.c.s = body end
                d.rich.want = body ~= ""
                applyVis(d.rich)
                T.set(d.body, { visible = false })
            else
                d.rich.want = false
                applyVis(d.rich)
                T.set(d.body, { text = body:gsub("<[^>]*>", ""), visible = body ~= "" })
            end
            local foot = s.foot
            if type(foot) == "string" then foot = { foot } end
            foot = type(foot) == "table" and foot or {}
            for i = 1, 3 do
                local line = foot[i] and tostring(foot[i]) or ""
                T.set(d.foot[i], { text = line, visible = line ~= "" })
            end
        end)
        d.bottom = guard("detail.bottom", function()
            if dead(d) then return nil end
            local hh
            pcall(function()
                column.w:ForceLayoutPrepass()                -- UWidget::ForceLayoutPrepass(): desired sizes now
                hh = tonumber(column.w:GetDesiredSize().Y)
            end)
            if not (hh and hh > 0) then
                local s = d.st
                local function lines(text, r)
                    local tw = T.textWidth(text, r)
                    return max(1, math.ceil(tw / max(1, d.w)))
                end
                local title = tostring(s.title or "")
                hh = 18 * 4 / 3 * 1.3 + 4 + lines(title, ROLE.detailTitle) * 90 * 4 / 3 * 0.85 * 1.2 + 66
                local body = tostring(s.body or ""):gsub("<[^>]*>", "")
                if body ~= "" then hh = hh + lines(body, ROLE.helpText) * 30 * 4 / 3 * 1.3 end
                local foot = type(s.foot) == "table" and s.foot or (s.foot and { s.foot } or {})
                for i = 1, min(3, #foot) do hh = hh + 6 + 30 * 4 / 3 * 1.3 + ((i == 1) and 18 or 0) end
            end
            return d.y + hh
        end)
        d.show = guard("detail.show", function(on) if not dead(d) then T.set(d.e, { visible = on ~= false }) end end)
        return d
    end)
end

---------------------------------------------------------------------------------------------------- input mode (§6.4)
-- P1's CommonInputSubsystem:GetCurrentInputType() (0 MouseAndKeyboard, 1 Gamepad, 2 Touch), switched only after the
-- raw type was stable for InputModeDebounceMs (V-FIN-11: a mouse nudge during pad play must not flip the command row).
-- KeyboardIsP1 = always "mouse"; T.forceInputMode(mode) pins it for tests (setup.debugInputMode).
local IM = { mode = nil, raw = nil, rawSince = 0, cis = nil, force = nil, switches = 0, lastSwitchMs = nil }

local function rawInputMode()
    local kb = false
    pcall(function() kb = settings.get("KeyboardIsP1") == true end)
    if kb then return "mouse" end
    if not U.ok(IM.cis) then
        IM.cis = nil
        pcall(function()
            local cls = U.class("/Script/CommonInput.CommonInputSubsystem")
            -- SubsystemBlueprintLibrary:GetLocalPlayerSubSystemFromPlayerController(PlayerController, Class) -> Object
            local o = U.SBL():GetLocalPlayerSubSystemFromPlayerController(U.p1(), cls)
            if U.ok(o) then IM.cis = o end
        end)
        if not IM.cis then return IM.raw or "pad" end
    end
    local ok, t = pcall(function() return IM.cis:GetCurrentInputType() end)
    if not ok then return IM.raw or "pad" end
    return (tonumber(t) == 0) and "mouse" or "pad"
end

function T.inputMode(now)
    now = tonumber(now) or nowMs()
    pump(now)
    if IM.force then return IM.force end
    local raw = rawInputMode()
    if IM.mode == nil then
        IM.mode, IM.raw, IM.rawSince = raw, raw, now
        U.log(TAG, "input mode: %s (P1's CommonInput type, debounce %d ms, V-FIN-11)", raw,
            rnd(num("InputModeDebounceMs", 500)))
        return IM.mode
    end
    if raw ~= IM.raw then IM.raw, IM.rawSince = raw, now end
    if raw ~= IM.mode and now - IM.rawSince >= num("InputModeDebounceMs", 500) then
        IM.mode = raw
        IM.switches = IM.switches + 1
        IM.lastSwitchMs = now
        U.log(TAG, "input mode -> %s (stable %d ms) (V-FIN-11)", raw, rnd(now - IM.rawSince))
    end
    return IM.mode
end

function T.forceInputMode(mode)
    if mode ~= "pad" and mode ~= "mouse" then mode = nil end
    if IM.force ~= mode then U.log(TAG, "input mode forced: %s (test helper)", tostring(mode or "live")) end
    IM.force = mode
    return mode or T.inputMode()
end

---------------------------------------------------------------------------------------------------- life cycle
---------------------------------------------------------------------------------------------------- texture pins (#23)
-- Live playtest 2026-10-17 #23 (stutter on the FREE MODE / GRAND PRIX pages): every view switch loaded its art
-- synchronously (5 "Asset loaded" right before "[gppage] view setup": the race thumbnails and the preview poster), and an
-- art that left its last image (a thumbnail stepped away, the preview's previous race) could be collected and loaded
-- again on the next visit. A page now hands its art list to T.preload once: one texture per cfg.UiPreloadEveryMs is
-- loaded in the background (only while no visible texture waits in the queue) onto a HIDDEN image of the page's pin
-- canvas (T.pinHost), which keeps a hard reference for the page's life (UImage brush resource). Navigation then finds
-- every texture in memory (texNow: StaticFindObject, no LoadAsset). The pins die with the page (T.forget).
local PIN = { ctx = nil, cv = nil, els = {}, n = 0, want = {}, wanted = {}, nextMs = 0, made = 0 }

-- the canvas the hidden pin images go to (a page canvas that lives as long as the page; collapsed is fine)
function T.pinHost(ctx, cv)
    if PIN.cv ~= cv then PIN.els, PIN.n, PIN.want, PIN.wanted = {}, 0, {}, {} end
    PIN.ctx, PIN.cv = ctx, cv
end

-- queue paths for the background preload (each pinned once; order kept: the likely first views first)
function T.preload(paths)
    if opt("UiPreload", true) == false then return 0 end
    local n = 0
    for _, p in ipairs(paths or {}) do
        if type(p) == "string" and p ~= "" and not PIN.els[p] and not PIN.wanted[p] and not Q.missing[p] then
            PIN.wanted[p] = true
            PIN.want[#PIN.want + 1] = p
            n = n + 1
        end
    end
    return n
end

-- the path is held by a pin image (its texture cannot be collected while the page lives)
function T.pinned(path)
    local e = PIN.els[path]
    return e ~= nil and e ~= false and e.c ~= nil and e.c.tex == path
end

function T.pinStatus()
    return { pinned = PIN.n, queued = #PIN.want, made = PIN.made }
end

-- one background preload step (FAST, the GP page's tick): -> true when it pinned / started one texture
function T.preloadTick(now)
    if not (PIN.cv and #PIN.want > 0) then return false end
    if St.launchHold() or St.phase ~= "FRONTEND" then return false end
    -- the pin canvas went with its page (live 2026-10-17 18:44:33: the COUCH CAMPAIGN page closed, the next preload
    -- step logged "image not built: canvas invalid" with a stack): the queue belongs to that page, dropped quietly
    if not U.ok(PIN.cv) then
        U.dbg(TAG, "preload: the pin canvas is gone (%d texture(s) still queued): queue dropped", #PIN.want)
        PIN.ctx, PIN.cv, PIN.els, PIN.n, PIN.want, PIN.wanted = nil, nil, {}, 0, {}, {}
        return false
    end
    now = tonumber(now) or nowMs()
    if now < PIN.nextMs then return false end
    if #Q.hi + #Q.lo > 0 then return false end            -- the visible page's own textures first
    PIN.nextMs = now + max(16, num("UiPreloadEveryMs", 150))
    while #PIN.want > 0 do
        local path = table.remove(PIN.want, 1)
        PIN.wanted[path] = nil
        if not PIN.els[path] and not Q.missing[path] then
            local ok, e = pcall(T.image, PIN.ctx, PIN.cv, { tex = path, visible = false, rect = { 0, 0, 8, 8 } })
            PIN.els[path] = (ok and e) or false
            if ok and e then PIN.n, PIN.made = PIN.n + 1, PIN.made + 1 end
            return true
        end
    end
    return false
end

function T.forget()
    PIN.ctx, PIN.cv, PIN.els, PIN.n, PIN.want, PIN.wanted = nil, nil, {}, 0, {}, {}
    R.gen = R.gen + 1
    R.nEls, R.builders, R.ghosts = 0, {}, {}
    R.widgets = 0
    R.forgets = R.forgets + 1
    Q.wait = {}                                           -- waiting elements belong to the dead page
    U.dbg(TAG, "forget: every cached widget dropped (generation %d)", R.gen)
end

-- Optional per-tick entry: opens this tick's texture window and drains the queue (the pills' tick and the command
-- rows' poll do the same; T.inputMode and T.set drain inside the current window).
function T.tick(now)
    pump(tonumber(now) or nowMs(), true)
end

-- The page dies with its main-menu instance (menu_tab installs a new one: "menu") and when a race world runs (the front
-- end and its pages are gone then). Not on LEAVING / OTHER (integration 0.12.0): phase.lua's backup leaving detector
-- sets LEAVING on its first tick in the NEXT front end, after menu_tab installed that front end's menu and the lobby /
-- setup built their v2 pages; a forget there would drop those live pages' elements (the "menu" event of every new
-- front end forgets the previous page anyway).
local RACE_PHASES = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }
St.on("menu", TAG, function() T.forget() end)
St.on("phase", TAG, function(new)
    if RACE_PHASES[new] then T.forget() end
end)

function T.status()
    local g = R.geo
    local parts = {}
    if g then
        parts[#parts + 1] = string.format("geo %d,%d %dx%d (%s) screen %d..%d cmdY %d CardH %d", rnd(g.x), rnd(g.y),
            rnd(g.w), rnd(g.h), tostring(g.src), rnd(g.screen.x), rnd(g.screen.x + g.screen.w), rnd(g.cmdY), rnd(g.cardH))
    else
        parts[#parts + 1] = "geo not measured yet"
    end
    parts[#parts + 1] = string.format("input %s (raw %s, forced %s, switches %d, debounce %d ms)",
        tostring(IM.force or IM.mode or "?"), tostring(IM.raw or "?"), tostring(IM.force or "-"), IM.switches,
        rnd(num("InputModeDebounceMs", 500)))
    local kinds, pills = {}, {}
    for _, b in ipairs(R.builders) do
        if not dead(b) then
            kinds[b.kind] = (kinds[b.kind] or 0) + 1
            if b.kind == "pill" then
                local e = b.shown
                pills[#pills + 1] = e and string.format("'%s'%s%s", e.text, e.warn and " warn" or "",
                    e.sticky and " sticky" or "") or "hidden"
            end
        end
    end
    local kl = {}
    for k, n in pairs(kinds) do kl[#kl + 1] = k .. " " .. n end
    table.sort(kl)
    parts[#parts + 1] = "pills: " .. ((#pills > 0) and table.concat(pills, ", ") or "none")
    parts[#parts + 1] = string.format("widgets %d, elements %d, builders: %s", R.widgets, R.nEls,
        (#kl > 0) and table.concat(kl, ", ") or "none")
    local nm = 0
    for _ in pairs(Q.missing) do nm = nm + 1 end
    parts[#parts + 1] = string.format("textures: queue %d, loads %d, missing %d, stale %d", #Q.hi + #Q.lo, Q.loads, nm,
        Q.stale)
    local fl = {}
    for k, n in pairs(R.fails) do fl[#fl + 1] = k .. " x" .. n end
    table.sort(fl)
    parts[#parts + 1] = "failures: " .. ((#fl > 0) and table.concat(fl, ", ") or "none")
    parts[#parts + 1] = string.format("generation %d, forgets %d%s%s", R.gen, R.forgets,
        setBrushBroken and ", SetBrush OFF" or "", fontMatBroken and ", font materials OFF" or "")
    return "theme: " .. table.concat(parts, " | ")
end

return T
