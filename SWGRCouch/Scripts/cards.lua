-- cards.lua (G3 Front-end UI, 0.10.0): the player cards of the race setup's step 5 RACERS (PILOT -> VEHICLE -> PERKS ->
-- READY per player). User request 2026-10-09: "improve the ui (kart are horrible p1 and p2 are not similar)", "A
-- chracter should be chosen, a kart then ... map out all the benefits and perks added to the kart ... It should look
-- nice the UI". Binding spec: notes/design/vehicle-step-v2.md §3 (visual spec) and §5.6 (this module's contract) with
-- the review corrections RC-3 (WrapTextAt), RC-5 (own detail icon), RC-7 (texture name check), RC-9 (size-aware texture
-- queue) and RC-15 (layout fits).
--
-- UI only: no input, no game-state reads. racers.lua owns the state machines and builds one view model (vm, pure data,
-- §5.6) per card right before CD.render; one widget tree and one renderer serve P1 and every guest, so two cards on the
-- same stage differ only by the texts and the colour their vm carries (V-RC-05).
--
-- Card = FuseSizeBox (CardW[n] x CardH, in setup's card row) > FuseOverlay [ frame = WBP_DarkPanel_C (vars written
-- before the add; CardFrame "solid": a FuseImage in CardPanelColour) ; FuseScaleBox (ScaleToFit, DownOnly, padding
-- CardPad) > FuseSizeBox (the class's design size: inner width x 1256) > FuseCanvasPanel ]. Every element sits on that
-- canvas or on a stage canvas (one per stage, built the first time the card shows it, only the current one visible) at
-- the place the per-width-class tables below give it (W = 1-2 players, inner 1656 su; M = 3, 1076; N = 4, 781). The
-- design box keeps the tables exact at the default sizes, and a lower CardH / CardW shrinks the whole card instead of
-- clipping it (RC-15: CardH is the remedy against a page shorter than measured).
-- Texts: FuseTextBlock in a FuseScaleBox (ScaleToFit, DownOnly) so a long name shrinks instead of overflowing; a box is
-- at least LINE x the font size high, centred on the spec's line, so the font metrics never shrink a single line.
-- Multi-line texts get WrapTextAt = their box width (RC-3; written before the add, later through the CommonTextBlock
-- setter SetWrapTextWidth).
--
-- Rendering is diffed: every element keeps what it last applied (rect, visibility, text, font, colours, texture,
-- scale, opacity) and CD.render calls the engine only for what changed (a cursor move = a few calls). A width-class
-- change and CD.clearCaches (page re-shown: a Slate rebuild may reset what a BP applied, V-RC-06) clear every cache and
-- re-render the cards from their last view model at once.
-- Textures: an image setter uses a loaded texture at once, loads a missing one within this tick's budget (one big
-- texture >= CardLoadBigBytes, up to CardLoadsPerTick small ones; full bodies, style backdrops and class art are
-- NeverStream without mips, RC-9) and queues the rest; CD.tick loads the queue under the same budget and puts each
-- texture on the images waiting for it. A cached texture is used only while its FName is still the asset's (RC-7: UE4SS
-- validity is address based, a collected texture's address can be reused).
-- Builds: at most CardBuildsPerTick card shells / stage panels / pickers per FAST tick (CD.tick resets the budget); a
-- render that could not build its panel returns false and CD.tick finishes it from the card's last view model.
-- GC rule: the 3D render brush (vpreview MID / render target) only comes from a view model built in the same tick;
-- re-renders from a stored view model never touch it. CD.releaseRenders empties the render images before vpreview
-- frees its targets. Head-shot MIDs go onto their image in the tick they are made (their only referencer).
-- Never used: WBP_Common_Btn / WBP_Vertical_Btn (focus side effects), SetBrushFromSoftTexture or any soft property,
-- WBP_Character_Ability:SetAbility / SetTrait (blocking soft loads, spec §0.3 #12) and its Icon (never shown, RC-5).
-- Every game call is guarded; a failed card or stage panel shows RACER CARD ERROR with the classic text rows (§8.2).
-- VERIFY ids: V-RC-01 (layouts 1-4 players, no tofu), V-RC-05 (P1 = guests), V-RC-06 (game widgets, colours after a
-- re-show), V-RC-15 (3P / 4P fit), V-RC-16 (build ms per shell / panel), V-RC-34 (multi-line texts wrap).

local C   = require("consts")
local cfg = require("config")
local St  = require("state")
local U   = require("util")

local M = {}
local TAG = "cards"

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

local floor, max, min = math.floor, math.max, math.min
local function rnd(v) return floor(v + 0.5) end
local function clamp(v, a, b) if v < a then return a end if v > b then return b end return v end

---------------------------------------------------------------------------------------------------- assets
local TX = "/Game/Griffin/UI/Library/Textures/"
local function tx(sub, n) return TX .. sub .. n .. "." .. n end
local TEX = {
    disc     = tx("Common/", "T_UI_CircleBig_Fill_Cmn"),            -- ability disc, level dots
    ring     = tx("Common/", "T_UI_CircleIconFrame_Cmn"),           -- ability ring
    noAffix  = tx("Common/", "T_UI_AffixFrame_NoRarity"),           -- empty part slot
    bar      = tx("Common/", "T_UI_StatProgressBar_Presentation_Cmn"), -- upgrade bar (428x48)
    squircle = tx("Common/", "T_UI_Squircle_A_Fill_Cmn"),           -- plain head-shot backer, pod model code
    divider  = tx("Common/", "T_UI_Line_Divider_Hor_Cmn"),
    tileFill = tx("Common/", "T_UI_FE_TileButton_300_Fill_Cmn"),    -- WBP_Character_Entry tile art
    tileSel  = tx("Common/", "T_UI_FE_TileButton_300_Select_Cmn"),
    tileUns  = tx("Common/", "T_UI_FE_TileButton_300_Unselect_Cmn"),
    pip      = tx("Icons/", "T_UI_MetallicRarityPip_Icn"),
    tick     = tx("Icons/", "T_UI_Tick_Icn"),
    arrow    = tx("Icons/", "T_UI_Arrow_Icn"),                      -- points left; the right one is mirrored
    star     = tx("Icons/", "T_UI_Star_Icn"),
    noAbil   = tx("Icons/Abilities/", "T_UI_Ability_Empty_Icn"),
}
-- pad glyphs of the hint line (vm.hint glyph keys); "text" = the ASCII words of CardGlyphs = "text" (§3.9 glyph rule)
local GLYPH, GLYPH_TEXT = {}, { Dpad_Left = "L", Dpad_Right = "R", Dpad_Top = "UP", Dpad_Bottom = "DN",
                                FaceButton_Bottom = "A", FaceButton_Right = "B" }
for k in pairs(GLYPH_TEXT) do GLYPH[k] = tx("Platform/Xbox/", "T_UI_Cntrl_XB_" .. k .. "_Icn") end
local WBP = "/Game/Griffin/UI/Widgets/"
local CLS_FRAME   = WBP .. "Decorative/WBP_DarkPanel.WBP_DarkPanel_C"
local CLS_BACKER  = WBP .. "Global/WBP_ButtonBacker.WBP_ButtonBacker_C"
local CLS_ABILITY = WBP .. "Character/WBP_Character_Ability.WBP_Character_Ability_C"
local MAT_HEAD    = "/Game/Griffin/UI/Library/Materials/Common/M_UI_CharacterProfilePicture.M_UI_CharacterProfilePicture"
local MAT_DIAMOND = "/Game/Griffin/UI/Library/Materials/HUD/MI_HUD_Abilities_BG.MI_HUD_Abilities_BG"
local KML         = "/Script/Engine.Default__KismetMaterialLibrary"
local MID_TRANSIENT = 1                    -- EMIDCreationFlags::Transient (as vpreview)
local FONT = {                             -- typefaces of the game's own widgets (WBP_Character_Ability: Body Semibold)
    display = { path = "/Game/Griffin/UI/Library/Fonts/Font_Display.Font_Display", face = "Bold" },
    body    = { path = "/Game/Griffin/UI/Library/Fonts/Font_Body.Font_Body", face = "Semibold" },
    italic  = { path = "/Game/Griffin/UI/Library/Fonts/Font_Body.Font_Body", face = "Medium Italic" },
}

-- RC-9: bytes of the big textures (asset list; UI textures are NeverStream with one mip, so a LoadAsset reads all of
-- it). Anything else counts as small (256x256 DXT5 icons and thumbs, ~66 KB; large art 472x244, ~116 KB).
local BIG = {
    { "/Content/Characters/", "_Fallback.", 2664556 },   -- full bodies 1480x1800 DXT5
    { "/Content/RacerStyles/", "_Bg.", 4147764 },        -- style backdrops 3840x2160 DXT1
    { "/Content/Arcade/", "_Bg.", 4692068 },             -- Arcade art (pod class art, pod backdrops)
    { "/Content/Vehicles/", "_Fallback.", 11310576 },    -- class renders 1950x1450
}
local function estBytes(path)
    for _, b in ipairs(BIG) do
        if string.find(path, b[1], 1, true) and string.find(path, b[2], 1, true) then return b[3] end
    end
    return 66000
end

local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local SIZE   = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" }
local SCALE  = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" }
local HBOX   = { "/Script/Griffin.FuseHorizontalBox", "/Script/UMG.HorizontalBox" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local TEXT   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }

local VIS = C.E.Vis
local FIT, FILL = 2, 5                     -- EStretch ScaleToFit / ScaleToFill
local DOWN_ONLY = 1                        -- EStretchDirection DownOnly
local CLIP = 1                             -- EWidgetClipping ClipToBounds
local AL = { l = 1, t = 1, c = 2, r = 3, b = 3 }   -- EHorizontal/EVerticalAlignment Left/Top 1, Center 2, Right/Bottom 3
local JUST = { l = 0, c = 1, r = 2 }               -- ETextJustify
local LINE = 1.7                           -- single-line box height per font point (pt x 96/72 x ~1.28 line height)

---------------------------------------------------------------------------------------------------- colours (§3.7)
-- Render caches compare colours by identity: every colour is interned (one table per value) and derived colours
-- (alpha, tint mix) are memoised on it, so a vm may hand over a new table each render.
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
local function memo(c, key, make)
    c = canon(c)
    local d = derived[c]
    if not d then d = {}; derived[c] = d end
    local v = d[key]
    if not v then v = canon(make(c)); d[key] = v end
    return v
end
local function alpha(c, a) return memo(c, a, function(b) return { R = b.R, G = b.G, B = b.B, A = a } end) end
-- white tinted toward c by m (the 2D class art "tinted 35 % player colour", setup.renderCard)
local function mix(c, m)
    return memo(c, "m" .. m, function(b) return { R = 1 - m + m * b.R, G = 1 - m + m * b.G, B = 1 - m + m * b.B, A = 1 } end)
end
local function lin(c) return { R = c.R, G = c.G, B = c.B, A = c.A } end    -- new table per call (UE4SS may keep it)
local function slate(c) return { SpecifiedColor = lin(c), ColorUseRule = 0 } end

local COL = {
    PANEL   = canon({ R = 0.012983, G = 0.036889, B = 0.048172, A = 0.90 }),  -- #1E363E @0.9 WBP_DarkPanel backer
    TILE    = canon({ R = 0.013702, G = 0.038204, B = 0.048172, A = 0.90 }),  -- #1F373E WBP_Tile_Btn fill
    BEIGE   = canon({ R = 0.775822, G = 0.730461, B = 0.665387, A = 1 }),     -- #E4DED5 text, icons
    CREAM   = canon({ R = 1.0, G = 0.863157, B = 0.679543, A = 1 }),          -- #FFEFD7 names, focused text
    SAGE    = canon({ R = 0.361307, G = 0.456411, B = 0.376262, A = 1 }),     -- #A2B4A5 small titles
    AMBER   = canon({ R = 0.745404, G = 0.412543, B = 0.08022, A = 1 }),      -- #E0AC50 section labels, signature
    GOLD    = canon({ R = 0.623961, G = 0.351533, B = 0.076185, A = 1 }),     -- #CFA04E style names, crash ring
    RUST    = canon({ R = 0.4396, G = 0.0823, B = 0.0452, A = 1 }),           -- #B1513C flaws, warnings
    BAR_OFF = canon({ R = 0.119538, G = 0.313989, B = 0.226966, A = 0.40 }),  -- #619883 @40 % stat bar background
    INK     = canon({ R = 0.006995, G = 0.006995, B = 0.006995, A = 1 }),     -- #141414 text on a fill
    DARK    = canon({ R = 0.006944, G = 0.006944, B = 0.006944, A = 0.85 }),  -- #131313 @0.85 taken pilot
    DIM     = canon({ R = 0.30, G = 0.30, B = 0.30, A = 1 }),                 -- style backdrop
    WHITE   = canon({ R = 1, G = 1, B = 1, A = 1 }),
}
local OUTLINE       = alpha(COL.BEIGE, 0.4)   -- idle pill outline (WBP_ButtonBacker ContentColor)
local OUTLINE_SOLID = alpha(COL.BEIGE, 0.12)  -- CardHighlight "solid": a faint quad stands for the outline

---------------------------------------------------------------------------------------------------- geometry (§3)
-- Slate units of the 3840x2160 design, relative to the card's inner canvas (shell) or to the stage canvas (stages).
-- Rects are {x, y, w, h}. Font sizes are points (Font_Display "Bold", Font_Body "Semibold" / "Medium Italic").
local IW = { W = 1656, M = 1076, N = 781 }            -- inner width per width class (card width - 2 x CardPad)
local IH = 1256                                       -- inner height (CardH 1320 - 2 x 32)
local SA_Y, SA_H = 206, 990                           -- stage area under the header (0-84), divider (92) and strip (110-190)
local HINT_Y, HINT_H = 1208, 48
local ROSTER = { W = 7, M = 6, N = 5 }                -- roster tiles (RC-15: M 6 tiles, 40-su arrows in M / N)
local PICK_ROWS = { W = 6, M = 8, N = 7 }             -- picker rows on one page
M.ROSTER_TILES, M.PICKER_ROWS = ROSTER, PICK_ROWS

local SHELL = {
    W = { nameW = 520, tabF = 28, arrow = 36 },
    M = { nameW = 400, tabF = 24, arrow = 36 },
    N = { nameW = nil, tabF = 22, arrow = 30 },       -- N: no pilot name in the header (the squircle stays)
}

-- PILOT (§3.3). tr = trait rows; W: icon + name + one-line description, M / N: icon + name (2 lines).
local PIL = {
    W = { bg = { 0, 0, 1656, 650 }, win = { 10, 0, 534, 650 }, sub = { 574, 34, 1062, 36 }, subF = 28,
          icon = { 574, 96, 150 }, name = { 750, 116, 886, 64 }, nameF = 52, line = { 750, 206, 886, 34 }, lineF = 26,
          desc = { 574, 266, 1062, 100 }, descF = 30,
          tr = { x = 574, w = 1062, y = 376, pitch = 76, icon = 58, nameF = 28, nameH = 38, descF = 22, descH = 32 },
          sig = { 574, 606, 1062, 40 }, sigF = 30,
          plate = { y = 662, h = 90, nameF = 70, cntF = 36, cntW = 300 },
          roster = { y = 772, h = 180, cur = 180, oth = 150, gap = 16, arrow = 52 } },
    M = { bg = { 0, 0, 1076, 620 }, win = { 0, 0, 510, 620 }, sub = { 528, 24, 548, 32 }, subF = 24,
          icon = { 528, 70, 120 }, name = { 664, 70, 412, 130 }, nameF = 42, nameWrap = 412,
          tr = { x = 528, w = 548, y = 246, pitch = 64, icon = 46, nameF = 24, nameH = 60, wrap = true },
          sig = { 528, 560, 548, 36 }, sigF = 26,
          plate = { y = 632, h = 88, nameF = 56, cntF = 30, cntW = 240 },
          roster = { y = 732, h = 160, cur = 160, oth = 132, gap = 12, arrow = 40 } },
    N = { bg = { 0, 0, 781, 600 }, win = { 0, 0, 296, 600 }, sub = { 314, 24, 467, 30 }, subF = 22,
          icon = { 314, 70, 104 }, name = { 434, 70, 347, 120 }, nameF = 36, nameWrap = 347,
          tr = { x = 314, w = 467, y = 230, pitch = 74, icon = 46, nameF = 22, nameH = 64, wrap = true },
          sig = { 314, 556, 467, 34 }, sigF = 24,
          plate = { y = 612, h = 84, nameF = 50, cntF = 26, cntW = 211 },
          roster = { y = 704, h = 150, cur = 150, oth = 124, gap = 10, arrow = 40 } },
}
local function trWrap(g) return g.tr.wrap and (g.tr.w - g.tr.icon - 12) or 0 end

-- VEHICLE (§3.4). M: badge, driver tile and SIGNATURE chip overlay the render; N: driver block under the render.
local VEH = {
    W = { r = { 0, 0, 1156, 650 }, badge = { 1184, 10, 180 }, codeF = 60, dl = { 1184, 230, 472, 36 }, dlF = 28,
          tile = { 1184, 280, 170 }, dn = { 1184, 460, 472, 50 }, dnF = 34, chip = { 1184, 540, 300, 60 }, chipI = 40,
          chipF = 28, plate = { y = 662, h = 90, nameF = 70, cntF = 36, cntW = 300 },
          rows = { { 772, 80 }, { 866, 80 } }, rowF = 30, arrow = 52, ax = 10, info = { 0, 950, 1656, 40 }, infoF = 24 },
    M = { r = { 0, 0, 1076, 605 }, badge = { 14, 14, 140 }, codeF = 48, tile = { 14, 455, 136 },
          chip = { 802, 14, 260, 56 }, chipI = 36, chipF = 26, plate = { y = 632, h = 88, nameF = 56, cntF = 30, cntW = 240 },
          rows = { { 732, 80 }, { 826, 80 } }, rowF = 26, arrow = 40, ax = 10, info = { 0, 920, 1076, 40 }, infoF = 22 },
    N = { r = { 0, 0, 781, 439 }, badge = { 14, 14, 124 }, codeF = 42, dl = { 148, 462, 633, 30 }, dlF = 22,
          tile = { 0, 459, 132 }, dn = { 148, 496, 633, 44 }, dnF = 34, chip = { 148, 549, 230, 44 }, chipI = 32,
          chipF = 22, plate = { y = 612, h = 84, nameF = 50, cntF = 26, cntW = 211 },
          rows = { { 704, 74 }, { 792, 74 } }, rowF = 24, arrow = 40, ax = 6, info = { 0, 880, 781, 50 }, infoF = 22,
          infoWrap = 781 },
}

-- PERKS board (§3.5). dia = ability diamond (cells, gap 8); parts = 3 x 2 grid (span = column width for more slots);
-- up = upgrade rows (M / N: 2 columns x 3 rows, column-major so Up / Down keep the W order); chips = trait chips
-- between x0 and x1; pick = the picker that replaces the board between the KIT row and the detail panel.
local PRK = {
    W = { kit = { 0, 0, 1000, 80 }, kitF = 30, pow = { 1040, 0, 604, 48 }, powF = 44, en = { 1040, 52, 604, 26 }, enF = 24,
          subF = 28, subAb = { 0, 100, 420, 36 }, subParts = { 450, 100, 450, 36 }, subUp = { 930, 100, 726, 36 },
          dia = { x = 10, y = 146, cell = 128 },
          parts = { x = 450, y = 146, tile = 128, px = 146, py = 170, span = 438, pip = 18, pipGap = 6 },
          up = { x = { 930 }, y = 146, pitch = 66, w = 726, h = 60, glyph = 48, nameX = 66, nameW = 294, nameF = 26,
                 barX = 370, barW = 280, barH = 28, digX = 670, digW = 56, digF = 40 },
          style = { 0, 572, 520, 76 }, styleF = 30, styleI = 52, chips = { x0 = 540, x1 = 1646, y = 572, h = 76, gap = 10,
          icon = 52, nameF = 24 }, dIcon = { 0, 668, 128 }, dCard = { 148, 668, 752, 262 }, tag = { 0, 936, 900, 44 },
          tagF = 22, large = { 1150, 668, 506, 262 },
          pick = { cat = { 60, 100, 1536, 70 }, catF = 30, arrow = 40, y = 186, pitch = 76, h = 70, icon = 60, nameF = 28,
                   tick = 40, pip = 18 } },
    M = { kit = { 0, 0, 1076, 72 }, kitF = 26, pow = { 748, 126, 316, 60 }, powF = 36, en = { 748, 190, 316, 40 }, enF = 22,
          short = "energy", subF = 24, subAb = { 0, 86, 360, 32 }, subParts = { 380, 86, 356, 32 },
          subUp = { 0, 494, 1076, 32 }, dia = { x = 4, y = 126, cell = 112 },
          parts = { x = 380, y = 126, tile = 108, px = 124, py = 152, span = 356, pip = 15, pipGap = 5 },
          up = { x = { 0, 548 }, y = 534, pitch = 60, w = 528, h = 56, glyph = 44, nameX = 58, nameW = 188, nameF = 22,
                 barX = 250, barW = 200, barH = 26, digX = 470, digW = 58, digF = 34 },
          style = { 0, 722, 360, 70 }, styleF = 26, styleI = 46, chips = { x0 = 372, x1 = 1072, y = 722, h = 70, gap = 5,
          icon = 46, nameF = 20, wrap = true }, dIcon = { 0, 806, 96 }, dCard = { 108, 806, 512, 184 },
          tag = { 640, 806, 436, 184 }, tagF = 22, tagWrap = 436,
          pick = { cat = { 54, 86, 968, 64 }, catF = 26, arrow = 40, y = 164, pitch = 78, h = 70, icon = 56, nameF = 26,
                   tick = 36, pip = 16 } },
    N = { kit = { 0, 0, 781, 72 }, kitF = 22, pow = { 340, 380, 441, 50 }, powF = 26, short = "both", subF = 22,
          subAb = { 0, 86, 324, 30 }, subParts = { 340, 86, 441, 30 }, subUp = { 0, 452, 781, 30 },
          dia = { x = 0, y = 122, cell = 100 },
          parts = { x = 340, y = 122, tile = 96, px = 108, py = 130, span = 312, pip = 13, pipGap = 4 },
          up = { x = { 0, 396 }, y = 488, pitch = 56, w = 385, h = 52, glyph = 40, nameX = 54, nameW = 138, nameF = 20,
                 barX = 195, barW = 150, barH = 24, digX = 350, digW = 35, digF = 30 },
          style = { 0, 664, 260, 70 }, styleF = 22, styleI = 44, chips = { x0 = 268, x1 = 776, y = 664, h = 70, gap = 5,
          icon = 44, nameF = 18, wrap = true }, dIcon = { 0, 748, 88 }, dCard = { 100, 748, 681, 200 },
          tag = { 0, 950, 781, 40 }, tagF = 20,
          pick = { cat = { 52, 86, 677, 64 }, catF = 22, arrow = 40, y = 162, pitch = 76, h = 70, icon = 52, nameF = 24,
                   tick = 34, pip = 15 } },
}
-- board cursor keys of the diamond -> cell position in pitch units (d-pad: slot 1 Up, 2 Left, 3 Down, 4 Right)
local DIAMOND = { ab1 = { 1, 0 }, ab2 = { 0, 1 }, crash = { 1, 1 }, ab4 = { 2, 1 }, ab3 = { 1, 2 } }

-- READY (§3.6). strip rows list their groups in order; sizes per item kind. name / style keep a 32-su gap and the style
-- a 12-su right inset (a long pilot · vehicle line ran into the style name in N, live run 2026-10-10).
local RDY = {
    W = { fig = { 155, 0, 330, 560 }, r = { 505, 0, 996, 560 }, stamp = { 1031, 24, 450, 160 }, stampF = 130,
          name = { 0, 572, 1084, 60 }, nameF = 50, style = { 1116, 582, 528, 44 }, styleF = 30,
          strip = { { y = 644, h = 84, groups = { "ab", "crash", "parts", "style", "traits" } } },
          sizes = { ab = 84, crash = 67, part = 70, style = 70, trait = 54 }, itemGap = 10, groupGap = 28,
          tot = { 0, 740, 1656, 50 }, totF = 32, rows = { { 120, 826, 1416, 76 }, { 120, 914, 1416, 76 } }, rowF = 30 },
    M = { r = { 0, 0, 1076, 605 }, tile = { 14, 441, 150 }, stamp = { 652, 20, 400, 136 }, stampF = 110,
          name = { 0, 617, 744, 50 }, nameF = 44, style = { 776, 621, 288, 42 }, styleF = 26,
          strip = { { y = 673, h = 64, groups = { "ab", "crash", "parts", "style", "traits" } } },
          sizes = { ab = 64, crash = 52, part = 56, style = 56, trait = 44 }, itemGap = 8, groupGap = 20,
          tot = { 0, 760, 1076, 40 }, totF = 28, rows = { { 60, 840, 956, 70 }, { 60, 920, 956, 70 } }, rowF = 26 },
    N = { r = { 0, 0, 781, 439 }, tile = { 14, 291, 134 }, stamp = { 445, 14, 320, 112 }, stampF = 92,
          name = { 0, 451, 520, 44 }, nameF = 32, style = { 552, 455, 217, 36 }, styleF = 22,
          strip = { { y = 507, h = 64, groups = { "ab", "crash", "style" } },
                    { y = 583, h = 58, groups = { "parts", "traits" } } },
          sizes = { ab = 60, crash = 50, part = 56, style = 56, trait = 40 }, itemGap = 6, groupGap = 16,
          tot = { 0, 760, 781, 36 }, totF = 26, rows = { { 40, 840, 701, 70 }, { 40, 920, 701, 70 } }, rowF = 24 },
}

local STAGE_LABEL = { pilot = "PILOT", vehicle = "VEHICLE", perks = "PERKS", ready = "READY" }

---------------------------------------------------------------------------------------------------- state
-- X = the cards of the current lobby page:
--   ctx (setup's helpers: tree, pc, newW, row, realMs), cls (width class), n (players), boxes[1..4] / slots[1..4] (the
--   card SizeBoxes in the row, made in order by M.init, and their HorizontalBoxSlots), boxC (their applied sizes),
--   cards[i], look (CardFrame / CardHighlight / CardDetail / CardThumbMask in use: a game widget that fails switches
--   its key to the fallback for everything built after), build / load budgets of this tick, the texture queue
--   (qHi / qLo, queued[path] = its queue, wait[path] = {element = card index}, missing, req) and counters.
-- card = { i, box, design, cv, els (every element: the cache reset), cls (class of its caches), vm (last view model),
--          pending, stages[stage] = panel, bad[stage] = why, broken / dead, H, tabs, hint, hints, toast, err }
-- element e = { w (widget in its parent), s (CanvasPanelSlot), t (text block), i (image), c (render cache), ci (card) }
local X = nil

local function now()
    local f = X and X.ctx and X.ctx.realMs
    if type(f) == "function" then
        local ok, v = pcall(f)
        if ok and type(v) == "number" then return v end
    end
    return St.nowMs()
end

---------------------------------------------------------------------------------------------------- construction
-- Native UMG widget with the page's WidgetTree as outer (setup's newW: what UWidgetTree::ConstructWidget does).
local function construct(paths)
    local w
    local f = X.ctx.newW
    if type(f) == "function" then
        w = f(paths)
    else
        for _, p in ipairs(paths) do
            local cls = U.class(p)
            if U.ok(cls) then
                w = StaticConstructObject(cls, X.ctx.tree)
                if U.ok(w) then break end
                w = nil
            end
        end
    end
    if not U.ok(w) then error("cannot construct " .. tostring(paths[1])) end
    X.nWidgets = X.nWidgets + 1
    return w
end

-- One of the game's widget Blueprints owned by the page's player (cmap pattern). The caller writes the BP variables
-- before the widget is added: PreConstruct reads them when Slate builds it.
local function create(clsPath)
    local cls = U.class(clsPath)
    if not U.ok(cls) then error(clsPath .. " not found") end
    local pc = U.ok(X.ctx.pc) and X.ctx.pc or nil
    local w = U.WBL():Create(pc or U.world(), cls, pc)    -- Create(WorldContextObject, WidgetType, OwningPlayer)
    if not U.ok(w) then error("Create(" .. clsPath .. ") failed") end
    X.nWidgets = X.nWidgets + 1
    return w
end

local function reg(card, e)
    e.c = e.c or {}
    e.ci = card.i
    card.els[#card.els + 1] = e
    return e
end

-- Child of a canvas (slot defaults: anchors 0/0, alignment 0/0, no auto size), collapsed until a render places it.
local function onCanvas(cv, w, z)
    local s = cv:AddChildToCanvas(w)                      -- -> CanvasPanelSlot
    if not U.ok(s) then error("AddChildToCanvas returned no slot") end
    if z then pcall(function() s:SetZOrder(z) end) end
    pcall(function() w:SetVisibility(VIS.Collapsed) end)
    return s
end

local function overlayFill(over, w)
    local s = over:AddChildToOverlay(w)                   -- -> OverlaySlot
    if U.ok(s) then pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end) end   -- Fill / Fill
    return s
end

local function newImage(card, cv, z)
    local img = construct(IMAGE)
    return reg(card, { w = img, i = img, s = onCanvas(cv, img, z) })
end

-- Image at its texture's size in a ScaleBox (ScaleToFit: the art keeps its aspect; ScaleToFill + clip: cover).
local function newFit(card, cv, stretch, z, clip)
    local img = construct(IMAGE)
    local sb = construct(SCALE)
    pcall(function() sb:SetStretch(stretch) end)
    if clip then pcall(function() sb:SetClipping(CLIP) end) end
    local ss = sb:AddChild(img)                           -- -> ScaleBoxSlot
    if U.ok(ss) then pcall(function() ss:SetHorizontalAlignment(AL.c); ss:SetVerticalAlignment(AL.c) end) end
    return reg(card, { w = sb, i = img, match = true, s = onCanvas(cv, sb, z) })
end

-- Text in a ScaleBox (ScaleToFit, DownOnly). o = {face = "display"|"body"|"italic", ls (letter spacing, 1/1000 em),
-- h = "l"|"c"|"r", v = "t"|"c"|"b", wrap = width of a multi-line text}.
local function newText(card, cv, o, z)
    o = o or {}
    local t = construct(TEXT)
    local wrap = tonumber(o.wrap) or 0
    -- RC-3: a ScaleBox lays its child out unconstrained, so AutoWrapText would wrap at the one-line width. WrapTextAt
    -- has no UTextLayoutWidget setter: a property write before the add (later changes: SetWrapTextWidth)
    if wrap > 0 then pcall(function() t.WrapTextAt = wrap end) end
    pcall(function() t:SetJustification(JUST[o.h or "l"]) end)     -- ETextJustify (lines of a wrapped text)
    local sb = construct(SCALE)
    pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
    local ss = sb:AddChild(t)
    if U.ok(ss) then
        pcall(function() ss:SetHorizontalAlignment(AL[o.h or "l"]); ss:SetVerticalAlignment(AL[o.v or "c"]) end)
    end
    return reg(card, { w = sb, t = t, face = o.face or "display", ls = o.ls or 0, s = onCanvas(cv, sb, z),
                       c = { wrap = wrap } })
end

-- A row of small parts in a box: ScaleBox (ScaleToFit, DownOnly; h = alignment in the box) > HorizontalBox. spec =
-- list of {kind = "img"|"text", pad = {left, right}, face, ls, flip}. Images get their size from SetDesiredSizeOverride.
local function newRow(card, cv, h, spec, z)
    local sb = construct(SCALE)
    pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
    local hb = construct(HBOX)
    local ss = sb:AddChild(hb)
    if U.ok(ss) then pcall(function() ss:SetHorizontalAlignment(AL[h or "c"]); ss:SetVerticalAlignment(AL.c) end) end
    local row = reg(card, { w = sb, s = onCanvas(cv, sb, z) })
    local parts = {}
    for k, p in ipairs(spec) do
        local w = construct(p.kind == "text" and TEXT or IMAGE)
        local hs = hb:AddChildToHorizontalBox(w)          -- -> HorizontalBoxSlot
        if U.ok(hs) then
            pcall(function()
                hs:SetVerticalAlignment(AL.c)
                if p.pad then hs:SetPadding({ Left = p.pad[1] or 0, Top = 0, Right = p.pad[2] or 0, Bottom = 0 }) end
            end)
        end
        if p.flip then pcall(function() w:SetRenderScale({ X = -1, Y = 1 }) end) end
        local e = { w = w, face = p.face or "display", ls = p.ls or 0 }
        if p.kind == "text" then e.t = w else e.i = w end
        parts[k] = reg(card, e)
    end
    return row, parts
end

---------------------------------------------------------------------------------------------------- diffed setters
local function show(e, on)                                -- raw visibility (HitTestInvisible: the cards never take input)
    on = on and true or false
    if e.c.v ~= on and pcall(function() e.w:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end) then
        e.c.v = on
    end
    return on
end

local function vis(e, on)                                 -- a render hides it: a texture still loading stays off
    if not on then e.c.want, e.c.fbw = nil, nil end
    return show(e, on)
end

local function rect(e, x, y, w, h)
    local c = e.c
    x, y, w, h = rnd(x), rnd(y), max(0, rnd(w)), max(0, rnd(h))
    if (c.x ~= x or c.y ~= y) and pcall(function() e.s:SetPosition({ X = x, Y = y }) end) then c.x, c.y = x, y end
    if (c.w ~= w or c.h ~= h) and pcall(function() e.s:SetSize({ X = w, Y = h }) end) then c.w, c.h = w, h end
end

local fontObjs = {}
local function fontObj(face)
    local f = FONT[face] or FONT.display
    local o = fontObjs[f.path]
    if o and U.ok(o) then return o end
    o = U.obj(f.path)
    if U.ok(o) then fontObjs[f.path] = o; return o end
    return nil
end

local function font(e, size)
    if e.c.fs == size then return end
    local f = fontObj(e.face)
    if not f then return end
    local face = (FONT[e.face] or FONT.display).face
    -- FSlateFontInfo from a table: missing fields are zero-filled (no outline, no material) [cmap newText]
    if pcall(function()
        e.t:SetFont({ FontObject = f, TypefaceFontName = U.fname(face), Size = size, LetterSpacing = e.ls or 0 })
    end) then e.c.fs = size end
end

local function text(e, s)
    if e.c.s == s then return end
    if pcall(function() e.t:SetText(U.ftext(s)) end) then e.c.s = s end
end

local function ink(e, col)
    col = canon(col)
    if e.c.ink ~= col and pcall(function() e.t:SetColorAndOpacity(slate(col)) end) then e.c.ink = col end
end

local function tint(e, col)
    col = canon(col)
    if e.c.tint ~= col and pcall(function() e.i:SetColorAndOpacity(lin(col)) end) then e.c.tint = col end
end

-- Style icons are white glyphs tinted per use, except the pod styles': their icon is the pilot's head shot
-- (perkdata STYLES.Pod_*.icon = Content/Characters/T_UI_PlaneChar_*_Thumb), which a tint turns into a silhouette.
local function glyphCol(path, col)
    if type(path) == "string" and path:find("Content/Characters/", 1, true) then return COL.WHITE end
    return col
end

local function wrap(e, w)                                 -- 0 = no wrapping
    w = rnd(w or 0)
    if e.c.wrap == w then return end
    -- UCommonTextBlock::SetWrapTextWidth(Int): WrapTextAt + SynchronizeProperties (FuseTextBlock is a CommonTextBlock)
    local ok = pcall(function() e.t:SetWrapTextWidth(w) end)
    if not ok then
        U.logOnce("cards.wrap", TAG, "SetWrapTextWidth unavailable: WrapTextAt written as a property (V-RC-34)")
        ok = pcall(function() e.t.WrapTextAt = w end)
    end
    if ok then e.c.wrap = w end
end

local function dsize(e, w, h)                             -- an image's size in a horizontal box
    h = h or w
    if (e.c.dw ~= w or e.c.dh ~= h) and pcall(function() e.i:SetDesiredSizeOverride({ X = w, Y = h }) end) then
        e.c.dw, e.c.dh = w, h
    end
end

local function opacity(e, a)
    if e.c.op ~= a and pcall(function() e.w:SetRenderOpacity(a) end) then e.c.op = a end
end

local function rscale(e, k)
    if e.c.rs ~= k and pcall(function() e.w:SetRenderScale({ X = k, Y = k }) end) then e.c.rs = k end
end

-- Text in its box (s nil / "" = hidden). A single line gets a box at least LINE x size high, centred on the given
-- one; wrapW > 0 = a multi-line text wrapped at that width in the given box (RC-3); wrapW 0 = wrapping off.
local function put(e, x, y, w, h, s, size, col, wrapW)
    s = (s ~= nil) and tostring(s) or ""
    if s == "" then return vis(e, false) end
    if wrapW ~= nil then wrap(e, wrapW) end
    if (wrapW or 0) <= 0 then
        local hh = max(h, rnd(size * LINE))
        y, h = y + (h - hh) / 2, hh
    end
    rect(e, x, y, w, h)
    font(e, size)
    ink(e, col)
    text(e, s)
    return show(e, true)
end

local function solid(e, x, y, w, h, col)
    rect(e, x, y, w, h)
    tint(e, col)
    return show(e, true)
end

---------------------------------------------------------------------------------------------------- textures (RC-7, RC-9)
local TXC = {}            -- path -> Texture2D; module level (assets outlive the page), re-checked on every use

local function assetName(path) return string.match(path, "%.([^%./]+)$") or path end

-- A vm path may be perkdata's relative form ("Icons/X/T_UI_Y", expanded as perkdata.lua's header says: D.TEX .. rel ..
-- "." .. name) or a full object path; a package path without ".Name" gets its object name. nil for anything else.
local pathCache = {}
local function texPath(p)
    if type(p) ~= "string" or p == "" then return nil end
    local n = pathCache[p]
    if n then return n end
    n = (string.sub(p, 1, 1) == "/") and p or (TX .. p)
    local last = string.match(n, "([^/]+)$") or n
    if not string.find(last, ".", 1, true) then n = n .. "." .. last end
    pathCache[p] = n
    return n
end

-- The loaded texture, or nil (never loads). A cached object counts only while it is valid AND its FName is still the
-- asset's: UE4SS validity is address based and a collected texture's address can be reused (RC-7).
local function texNow(path)
    local t = TXC[path]
    if t ~= nil then
        if U.ok(t) then
            local ok, n = pcall(function() return t:GetFName():ToString() end)
            if ok and n == assetName(path) then return t end
        end
        TXC[path] = nil
        if X then X.stale = X.stale + 1 end           -- collected, or its address reused (RC-7)
    end
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.ok(o) then TXC[path] = o; return o end
    return nil
end

local function isBig(path) return estBytes(path) >= num("CardLoadBigBytes", 1048576) end

-- The per-tick budgets (builds, loads) are reset by CD.tick; a render 100 ms after the last reset (3 FAST ticks: no
-- poll running) opens a new window itself, so nothing waits forever. Never sooner: a slow build must not let a second
-- one into the same tick.
local function budgetWindow()
    local t = now()
    if t - X.budgetAt > 100 then X.built, X.bigUsed, X.smallUsed, X.budgetAt = 0, 0, 0, t end
end

-- One LoadAsset inside this tick's budget (one big texture, CardLoadsPerTick small ones). nil: over budget or missing.
local function loadNow(path)
    budgetWindow()
    local big = isBig(path)
    if big then
        if X.bigUsed >= 1 then return nil end
        X.bigUsed = X.bigUsed + 1
    else
        if X.smallUsed >= max(1, floor(num("CardLoadsPerTick", 3))) then return nil end
        X.smallUsed = X.smallUsed + 1
    end
    local t0 = now()
    local ok, err = pcall(LoadAsset, path)                -- game thread (FAST loop); 3 returns, re-found below
    local t = texNow(path)
    X.loads = X.loads + 1
    if not t then
        X.missing[path] = true
        U.logOnce("cards.missing:" .. path, TAG, "texture missing: %s%s (its element keeps its backer / fallback)", path,
            ok and "" or (" (" .. tostring(err) .. ")"))
        return nil
    end
    local ms = now() - t0
    if big or ms > 20 then U.dbg(TAG, "loaded %s in %.1f ms%s (RC-9)", assetName(path), ms, big and " (big)" or "") end
    return t
end

local function enqueue(path, hi)
    if X.missing[path] then return end
    local q = X.queued[path]
    if q == X.qHi or (q ~= nil and not hi) then return end
    q = hi and X.qHi or X.qLo
    X.queued[path] = q
    q[#q + 1] = path
end

-- Loaded texture, loaded now (wanted by an element, budget left), or queued (nil).
local function getTex(path, wanted)
    X.req[path] = true
    local t = texNow(path)
    if t then return t end
    if X.missing[path] then return nil end
    if wanted then
        t = loadNow(path)
        if t then return t end
    end
    enqueue(path, wanted)
    return nil
end

-- Head-shot MID of M_UI_CharacterProfilePicture (parameter Texture, squircle mask; the material WBP_Tile_Btn uses).
local function newMid()
    local parent, kml = U.obj(MAT_HEAD), U.cdo(KML)
    if not (U.ok(parent) and U.ok(kml)) then return nil, "material or KismetMaterialLibrary not found" end
    local ok, mid = pcall(function()
        -- CreateDynamicMaterialInstance(WorldContextObject, Parent, OptionalName, CreationFlags) (vpreview)
        return kml:CreateDynamicMaterialInstance(U.world(), parent, U.fname("None"), MID_TRANSIENT)
    end)
    if ok and U.ok(mid) then
        X.mids = X.mids + 1
        return mid
    end
    return nil, tostring(mid)
end

local applyTex
local function headFailed(why)
    X.look.thumb = "plain"
    U.warn(TAG, "head-shot MID unavailable (%s): plain head shots from now on (CardThumbMask = \"plain\")", tostring(why))
end

local function applyHead(e, t)
    local mid = U.ok(e.mid) and e.mid or nil
    local fresh = mid == nil
    if fresh then
        local why
        mid, why = newMid()
        if not mid then headFailed(why); return applyTex(e, t) end
    end
    local ok, err = pcall(function() mid:SetTextureParameterValue(U.fname("Texture"), t) end)   -- (Name, Texture)
    if not ok then headFailed(err); return applyTex(e, t) end
    if fresh then
        -- the new MID's only referencer will be this brush: set in the same tick (GC rule)
        if not pcall(function() e.i:SetBrushFromMaterial(mid) end) then return false end
        e.mid = mid
    end
    return true
end

applyTex = function(e, t)
    if e.head and X.look.thumb == "mid" then return applyHead(e, t) end
    local ok = pcall(function() e.i:SetBrushFromTexture(t, e.match == true) end)   -- (Texture2D, bMatchSize)
    if ok then e.mid = nil end
    return ok
end

local function waitFor(e, path)
    local w = X.wait[path]
    if not w then w = {}; X.wait[path] = w end
    w[e] = e.ci or 0
end

-- The texture at path on e.i; shown once it is on. While it loads the element shows fb (when given and loaded) or
-- nothing, and CD.tick puts the texture on when it arrives. Returns true when path itself is shown.
local function img(e, path, fb)
    path, fb = texPath(path), texPath(fb)
    if not path then return vis(e, false) end
    local c = e.c
    c.want, c.fbw = path, nil
    if c.tex == path then return show(e, true) end
    local t = getTex(path, true)
    if t then
        if applyTex(e, t) then c.tex = path; return show(e, true) end
        show(e, false)
        return false
    end
    if not X.missing[path] then waitFor(e, path) end
    if fb and fb ~= path then
        c.fbw = fb
        if c.tex == fb then show(e, true); return false end
        local ft = getTex(fb, true)
        if ft and applyTex(e, ft) then c.tex = fb; show(e, true); return false end
        if not X.missing[fb] then waitFor(e, fb) end
    end
    show(e, false)
    return false
end

-- A texture arrived (or is missing): put it on the elements still waiting for it. Returns the touched card indices.
local function arrived(path, t, touched)
    local w = X.wait[path]
    X.wait[path] = nil
    if not (w and t) then return end
    for e, ci in pairs(w) do
        local c = e.c
        local main = c.want == path
        if c.tex ~= path and (main or (c.fbw == path and c.want ~= nil and c.tex ~= c.want)) then
            if applyTex(e, t) then
                c.tex = path
                show(e, true)
                touched[ci] = true
            end
        end
    end
end

local function material(e, path)
    if e.c.mat == path then return show(e, true) end
    local m = U.obj(path)
    if U.ok(m) and pcall(function() e.i:SetBrushFromMaterial(m) end) then
        e.c.mat = path
        return show(e, true)
    end
    return vis(e, false)
end

-- 3D render brush (vpreview MID or render target) from a view model built in this tick. e.held is the object the
-- image holds: not a render cache (a Slate rebuild keeps the brush), so a cache reset never drops it.
local function setRender(e, brush, kind)
    if brush == nil then
        if e.held ~= nil then
            pcall(function() e.i:SetBrushResourceObject(nil) end)   -- the MID loses its last UPROPERTY reference
            e.held = nil
        end
        return false
    end
    if e.held == nil or e.held ~= brush then              -- UE4SS == compares the object addresses
        local ok = pcall(function()
            if kind == "texture" then e.i:SetBrushResourceObject(brush) else e.i:SetBrushFromMaterial(brush) end
        end)
        if not ok then return e.held ~= nil end
        e.held = brush
    end
    return true
end

---------------------------------------------------------------------------------------------------- composite widgets
-- Pill backer: WBP_ButtonBacker_C (IsOutline: MI_UI_Pill_GenericOutline, else the filled MI_UI_Tab; PreConstruct puts
-- ContentColor on B_Color) or, with CardHighlight "solid" / after a creation failure, a solid image.
local function newBacker(card, cv, outline, z)
    if X.look.hl == "pill" then
        local ok, w = pcall(function()
            local b = create(CLS_BACKER)
            pcall(function() b.IsOutline = outline end)
            pcall(function() b.ContentColor = lin(outline and OUTLINE or COL.TILE) end)
            pcall(function() b:SetVisibility(VIS.HitTestInvisible) end)
            return b
        end)
        if ok then return reg(card, { w = w, backer = true, outline = outline, s = onCanvas(cv, w, z) }) end
        X.look.hl = "solid"
        U.warn(TAG, "WBP_ButtonBacker unavailable (%s): solid pills from now on (CardHighlight = \"solid\", V-RC-06)",
            tostring(w))
    end
    local img0 = construct(IMAGE)
    return reg(card, { w = img0, i = img0, outline = outline, s = onCanvas(cv, img0, z) })
end

local function backerColour(e, col)
    col = canon(col)
    if not e.backer and e.outline then col = OUTLINE_SOLID end
    if e.c.bc == col then return end
    local ok
    if e.backer then
        ok = pcall(function() e.w.B_Color:SetContentColorAndOpacity(lin(col)) end)   -- UBorder (FuseBorder B_Color)
        pcall(function() e.w.ContentColor = lin(col) end)  -- PreConstruct re-applies it after a Slate rebuild (V-RC-06)
        if not ok then
            U.logOnce("cards.bcolor", TAG, "WBP_ButtonBacker.B_Color not writable: pill colour from ContentColor only (V-RC-06)")
        end
    else
        ok = pcall(function() e.i:SetColorAndOpacity(lin(col)) end)
    end
    if ok then e.c.bc = col end
end

local function backer(e, x, y, w, h, col)
    rect(e, x, y, w, h)
    backerColour(e, col)
    return show(e, true)
end

-- Pill = outline backer + fill backer (active, player colour) + centred label [icon][text] + arrows (inside or outside,
-- drawn only while active) + optional counter at the right end.
local function newPill(card, cv, z, o)
    o = o or {}
    local P = { out = newBacker(card, cv, true, z), fill = newBacker(card, cv, false, z) }
    local spec = { { kind = "text" } }
    if o.icon then spec = { { kind = "img", pad = { 0, 12 } }, { kind = "text" } } end
    local parts
    P.lbl, parts = newRow(card, cv, "c", spec, z)
    if o.icon then P.icon, P.txt = parts[1], parts[2] else P.txt = parts[1] end
    P.al, P.ar = newImage(card, cv, z), newImage(card, cv, z)
    pcall(function() P.ar.w:SetRenderScale({ X = -1, Y = 1 }) end)
    if o.counter then P.cnt = newText(card, cv, { h = "r" }, z) end
    return P
end

local function pillParts(P) return { P.out, P.fill, P.lbl, P.al, P.ar, P.cnt } end

local function hidePill(P)
    for _, e in ipairs(pillParts(P)) do vis(e, false) end
end

-- o = {active, colour, size (font), arrows = "in" | "out", arrow (size), icon (path), iconSize, counter, opacity}
local function pill(P, x, y, w, h, s, o)
    local act = o.active == true
    backer(P.out, x, y, w, h, OUTLINE)
    if act then backer(P.fill, x, y, w, h, o.colour) else vis(P.fill, false) end
    local a = o.arrow or 40
    local mode = act and o.arrows or nil
    local inset = 24
    if mode == "in" then
        inset = 20 + a
        rect(P.al, x + 12, y + (h - a) / 2, a, a)
        rect(P.ar, x + w - 12 - a, y + (h - a) / 2, a, a)
    elseif mode == "out" then
        rect(P.al, x - 8 - a, y + (h - a) / 2, a, a)
        rect(P.ar, x + w + 8, y + (h - a) / 2, a, a)
    end
    for _, e in ipairs({ P.al, P.ar }) do
        if mode then
            img(e, TEX.arrow)
            tint(e, mode == "in" and COL.INK or o.colour)
        else
            vis(e, false)
        end
    end
    local ink0 = act and COL.INK or COL.BEIGE
    local cw = 0
    if P.cnt then
        if o.counter and o.counter ~= "" then
            cw = rnd(min(w * 0.22, 220))
            put(P.cnt, x + w - inset - cw, y, cw, h, o.counter, max(16, (o.size or 30) - 4), ink0)
        else
            vis(P.cnt, false)
        end
    end
    local side = inset + (cw > 0 and (cw + 8) or 0)          -- symmetric: the label stays centred on the pill
    rect(P.lbl, x + side, y, max(10, w - 2 * side), h)
    show(P.lbl, true)
    if P.icon then
        if o.icon then
            dsize(P.icon, o.iconSize or 52)
            img(P.icon, o.icon)
            tint(P.icon, glyphCol(o.icon, act and COL.INK or COL.AMBER))
        else
            vis(P.icon, false)
        end
    end
    font(P.txt, o.size or 30)
    ink(P.txt, ink0)
    text(P.txt, s or "")
    show(P.txt, true)
    local op = o.opacity or 1
    for _, e in ipairs(pillParts(P)) do opacity(e, op) end
end

-- Section label: amber title + a 2-su amber @0.6 line to the column end (§3.5 sublabels).
local function newSublabel(card, cv, z)
    local hb = construct(HBOX)
    local t = construct(TEXT)
    local line = construct(IMAGE)
    local s1 = hb:AddChildToHorizontalBox(t)
    if U.ok(s1) then pcall(function() s1:SetVerticalAlignment(AL.c) end) end
    -- The rule sits in a 2-su SizeBox: a texture-less FuseImage ignores SetDesiredSizeOverride and drew its brush's
    -- default 32 su (a thick bar through the label, live run 2026-10-10).
    local okB, box = pcall(construct, SIZE)
    if not okB then box = nil end
    local s2 = hb:AddChildToHorizontalBox(box or line)
    if U.ok(s2) then
        pcall(function() s2:SetSize({ Value = 1, SizeRule = 1 }) end)       -- FSlateChildSize Fill
        pcall(function() s2:SetVerticalAlignment(AL.c) end)
        pcall(function() s2:SetPadding({ Left = 16, Top = 0, Right = 0, Bottom = 0 }) end)
    end
    if box then
        pcall(function() box:SetHeightOverride(2) end)
        pcall(function() box:AddChild(line) end)
    end
    pcall(function() line:SetDesiredSizeOverride({ X = 2, Y = 2 }) end)
    pcall(function() line:SetColorAndOpacity(lin(alpha(COL.AMBER, 0.6))) end)
    local e = reg(card, { w = hb, s = onCanvas(cv, hb, z) })
    e.txt = reg(card, { w = t, t = t, face = "display", ls = 80 })
    return e
end

local function sublabel(e, x, y, w, h, s, size)
    rect(e, x, y, w, h)
    font(e.txt, size)
    ink(e.txt, COL.AMBER)
    text(e.txt, s)
    show(e.txt, true)
    return show(e, true)
end

-- Squircle head-shot tile: backer + head shot (MID or plain) [+ roster frame, taken overlay and holder tag].
local function newThumb(card, cv, z, roster)
    local T = { fill = newImage(card, cv, z), head = newImage(card, cv, z) }
    T.head.head = true
    if roster then
        T.frame = newImage(card, cv, z)
        T.dark = newImage(card, cv, z)
        T.tag = newBacker(card, cv, false, z)
        T.tagT = newText(card, cv, { h = "c" }, z)
    end
    return T
end

local function hideThumb(T)
    for _, k in ipairs({ "fill", "head", "frame", "dark", "tag", "tagT" }) do
        if T[k] then vis(T[k], false) end
    end
end

-- o = {current, colour, takenBy = pnum}
local function thumb(T, x, y, s, path, o)
    o = o or {}
    local plain = X.look.thumb ~= "mid"
    rect(T.fill, x, y, s, s)
    img(T.fill, plain and TEX.squircle or TEX.tileFill)
    tint(T.fill, COL.TILE)
    local inset = rnd(s * 0.07)
    rect(T.head, x + inset, y + inset, s - 2 * inset, s - 2 * inset)
    img(T.head, path)
    if T.frame then
        rect(T.frame, x, y, s, s)
        img(T.frame, o.current and TEX.tileSel or TEX.tileUns)
        tint(T.frame, o.current and o.colour or alpha(COL.BEIGE, 0.6))
        local tk = tonumber(o.takenBy)
        local tc = tk and C.COLOURS[tk]
        if tc then
            solid(T.dark, x, y, s, s, COL.DARK)
            local tw, th = rnd(s * 0.46), rnd(s * 0.24)
            local tx0, ty0 = x + (s - tw) / 2, y + s - th - rnd(s * 0.05)
            backer(T.tag, tx0, ty0, tw, th, tc)
            put(T.tagT, tx0, ty0, tw, th, "P" .. tk, rnd(24 * s / 150), COL.INK)
        else
            vis(T.dark, false); vis(T.tag, false); vis(T.tagT, false)
        end
    end
end

-- Ability disc: disc + ring (+ glyph at 64 %, keyword sub-icon 35 % bottom right, 1-3 level dots, "+" when empty).
local function newCell(card, cv, z, o)
    o = o or {}
    local c = { disc = newImage(card, cv, z), ring = newImage(card, cv, z), glyph = newImage(card, cv, z) }
    if o.sub then c.sub = newImage(card, cv, z) end
    if o.pips then c.pips = { newImage(card, cv, z), newImage(card, cv, z), newImage(card, cv, z) } end
    if o.plus then c.plus = newText(card, cv, { h = "c" }, z) end
    return c
end

local function hideCell(c)
    vis(c.disc, false); vis(c.ring, false); vis(c.glyph, false)
    if c.sub then vis(c.sub, false) end
    if c.pips then for k = 1, 3 do vis(c.pips[k], false) end end
    if c.plus then vis(c.plus, false) end
end

-- d = {glyph, sub, lvl, empty}; ringCol = BEIGE (GOLD: crash); cursor = player colour ring at render scale 1.08.
local function cell(c, x, y, s, d, ringCol, cursor, pc)
    d = type(d) == "table" and d or { glyph = d }
    local empty = d.empty == true or type(d.glyph) ~= "string"
    rect(c.disc, x, y, s, s); img(c.disc, TEX.disc); tint(c.disc, COL.TILE)
    rect(c.ring, x, y, s, s); img(c.ring, TEX.ring)
    tint(c.ring, cursor and pc or ringCol)
    rscale(c.ring, cursor and 1.08 or 1)
    if empty then
        vis(c.glyph, false)
    else
        local gs = rnd(s * 0.64)
        rect(c.glyph, x + (s - gs) / 2, y + (s - gs) / 2, gs, gs)
        img(c.glyph, d.glyph, TEX.noAbil)
        tint(c.glyph, COL.BEIGE)
    end
    if c.sub then
        if not empty and type(d.sub) == "string" then
            local ss = rnd(s * 0.35)
            rect(c.sub, x + s - ss - rnd(s * 0.02), y + s - ss - rnd(s * 0.02), ss, ss)
            img(c.sub, d.sub)
        else
            vis(c.sub, false)
        end
    end
    if c.pips then
        local n = empty and 0 or clamp(floor(tonumber(d.lvl) or 0), 0, 3)
        local dot, gap = max(4, rnd(s * 0.08)), max(2, rnd(s * 0.05))
        local x0 = x + (s - (n * dot + (n - 1) * gap)) / 2
        for k = 1, 3 do
            if k <= n then
                rect(c.pips[k], x0 + (k - 1) * (dot + gap), y + s - rnd(s * 0.19), dot, dot)
                img(c.pips[k], TEX.disc)
                tint(c.pips[k], COL.BEIGE)
            else
                vis(c.pips[k], false)
            end
        end
    end
    if c.plus then
        if empty then put(c.plus, x, y, s, s, "+", rnd(40 * s / 128), alpha(COL.BEIGE, 0.4)) else vis(c.plus, false) end
    end
end

-- Detail / picker icon by kind: "disc" (ability disc), "tile" (finished affix tile, as is), "glyph" (white glyph tinted
-- BEIGE: traits, styles, keywords). empty: "+".
local function icon(c, x, y, s, path, kind, empty)
    if kind == "disc" then
        cell(c, x, y, s, { glyph = (not empty) and path or nil, empty = empty }, COL.BEIGE, false)
        return
    end
    vis(c.disc, false); vis(c.ring, false)
    if c.sub then vis(c.sub, false) end
    if c.pips then for k = 1, 3 do vis(c.pips[k], false) end end
    if empty or type(path) ~= "string" then
        vis(c.glyph, false)
    else
        rect(c.glyph, x, y, s, s)
        img(c.glyph, path)
        tint(c.glyph, kind == "glyph" and COL.BEIGE or COL.WHITE)
    end
    if c.plus then
        if empty then put(c.plus, x, y, s, s, "+", rnd(40 * s / 128), alpha(COL.BEIGE, 0.4)) else vis(c.plus, false) end
    end
end

-- Part tile: affix tile (finished art) + rarity pips / flaw bar; empty: the NoRarity frame + "+"; cursor: the tile
-- button's Select frame in the player colour around it.
local function newPart(card, cv, z)
    local p = { tile = newImage(card, cv, z), frame = newImage(card, cv, z), plus = newText(card, cv, { h = "c" }, z),
                rust = newImage(card, cv, z), sel = newImage(card, cv, z + 1), pips = {} }
    for k = 1, 4 do p.pips[k] = newImage(card, cv, z) end
    return p
end

local function hidePart(p)
    for _, k in ipairs({ "tile", "frame", "plus", "rust", "sel" }) do vis(p[k], false) end
    for k = 1, 4 do vis(p.pips[k], false) end
end

-- d = {tile, pips, faulty, empty}; g = {pip, pipGap} sizes (pips 8 su under the tile)
local function part(p, x, y, s, d, cursor, pc, g)
    d = type(d) == "table" and d or { tile = d }
    local empty = d.empty == true or type(d.tile) ~= "string"
    rect(p.tile, x, y, s, s)
    if empty then vis(p.tile, false) else img(p.tile, d.tile, TEX.noAffix) end
    if empty then
        rect(p.frame, x, y, s, s); img(p.frame, TEX.noAffix); tint(p.frame, alpha(COL.BEIGE, 0.5))
        put(p.plus, x, y, s, s, "+", rnd(40 * s / 128), alpha(COL.BEIGE, 0.4))
    else
        vis(p.frame, false); vis(p.plus, false)
    end
    local ps, pg = g.pip or rnd(18 * s / 128), g.pipGap or rnd(6 * s / 128)
    local py = y + s + rnd(8 * s / 128)
    local n = (empty or d.faulty) and 0 or clamp(floor(tonumber(d.pips) or 0), 0, 4)
    local x0 = x + (s - (n * ps + (n - 1) * pg)) / 2
    for k = 1, 4 do
        if k <= n then
            rect(p.pips[k], x0 + (k - 1) * (ps + pg), py, ps, ps)
            img(p.pips[k], TEX.pip)
            tint(p.pips[k], COL.AMBER)
        else
            vis(p.pips[k], false)
        end
    end
    if not empty and d.faulty then                        -- a flaw: one rust bar instead of pips
        local rw, rh = rnd(90 * s / 128), max(4, rnd(8 * s / 128))
        solid(p.rust, x + (s - rw) / 2, py + (ps - rh) / 2, rw, rh, COL.RUST)
    else
        vis(p.rust, false)
    end
    if cursor then
        local m = rnd(8 * s / 128)
        rect(p.sel, x - m, y - m, s + 2 * m, s + 2 * m)
        img(p.sel, TEX.tileSel)
        tint(p.sel, pc)
    else
        vis(p.sel, false)
    end
end

-- 3D render box: the render image, else the 2D class art at its own aspect tinted 35 % player colour (setup.renderCard).
local function newRenderBox(card, cv, z)
    return { render = newImage(card, cv, z), fb = newFit(card, cv, FIT, z) }
end

-- keep = re-render from a stored view model: the brush is left as the image holds it (GC rule).
local function renderBox(rb, x, y, w, h, brush, kind, dim, fallback, pc, keep)
    local live
    if keep then live = rb.render.held ~= nil else live = setRender(rb.render, brush, kind) end
    if live then
        rect(rb.render, x, y, w, h)
        tint(rb.render, alpha(COL.WHITE, clamp(tonumber(dim) or 1, 0, 1)))
        show(rb.render, true)
        vis(rb.fb, false)
    else
        vis(rb.render, false)
        rect(rb.fb, x, y, w, h)
        tint(rb.fb, mix(pc, 0.35)); img(rb.fb, fallback)
    end
end

-- Figure window (§3.3): the 1480x1800 full body scaled so the crop box {u0, v0, u1, v1} shows whole, centred on it and
-- bottom-aligned (feet on the window's floor): one code path for speeder pilots (whole frame) and pods (their box).
local function figure(e, ww, wh, crop, path)
    if type(path) ~= "string" or path == "" then return vis(e, false) end
    local u0, v0, u1, v1 = 0, 0, 1, 1
    if type(crop) == "table" then
        u0 = tonumber(crop[1] or crop.u0) or 0
        v0 = tonumber(crop[2] or crop.v0) or 0
        u1 = tonumber(crop[3] or crop.u1) or 1
        v1 = tonumber(crop[4] or crop.v1) or 1
    end
    local cw, ch = max(0.01, u1 - u0) * 1480, max(0.01, v1 - v0) * 1800
    local s = min(ww / cw, wh / ch)
    local fw, fh = 1480 * s, 1800 * s
    rect(e, ww / 2 - (u0 + u1) / 2 * fw, wh - v1 * fh, fw, fh)
    return img(e, path)
end

local function plate(eName, eCnt, g, iw, name, counter)
    put(eName, 0, g.y, iw - g.cntW - 16, g.h, name, g.nameF, COL.CREAM)
    put(eCnt, iw - g.cntW, g.y, g.cntW, g.h, counter, g.cntF, COL.BEIGE)
end

-- items of a list until the first nil (entries may be false), at most n
local function count(list, n)
    if type(list) ~= "table" then return 0 end
    local k = 0
    while k < (n or 10) and list[k + 1] ~= nil do k = k + 1 end
    return k
end

---------------------------------------------------------------------------------------------------- card shell
local function frameWidget()
    local panel = canon(opt("CardPanelColour", COL.PANEL))
    if X.look.frame == "darkpanel" then
        local ok, w = pcall(function()
            local f = create(CLS_FRAME)
            -- PreConstruct: shadow / tight / gradient visibility + Img_PanelBacker colour = MainPanelColor [V decoded]
            pcall(function() f.MainPanelColor = lin(panel) end)
            pcall(function() f.ShowShadow = true end)
            pcall(function() f.ShowTightPanel = false end)
            pcall(function() f.ShowGradientPanel = false end)
            pcall(function() f:SetVisibility(VIS.HitTestInvisible) end)
            return f
        end)
        if ok then return w end
        X.look.frame = "solid"
        U.warn(TAG, "WBP_DarkPanel unavailable (%s): solid card frames from now on (CardFrame = \"solid\", V-RC-06)",
            tostring(w))
    end
    local im = construct(IMAGE)
    pcall(function() im:SetColorAndOpacity(lin(panel)) end)
    pcall(function() im:SetVisibility(VIS.HitTestInvisible) end)
    return im
end

local function buildHint(card, cv)
    local sb = construct(SCALE)
    pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
    local hb = construct(HBOX)
    local ss = sb:AddChild(hb)
    if U.ok(ss) then pcall(function() ss:SetHorizontalAlignment(AL.c); ss:SetVerticalAlignment(AL.c) end) end
    card.hint = reg(card, { w = sb, s = onCanvas(cv, sb, 2) })
    card.hints = {}
    for k = 1, 4 do                                       -- [glyph][glyph][text] x 4, 28 su apart
        local eb = construct(HBOX)
        local es = hb:AddChildToHorizontalBox(eb)
        if U.ok(es) then
            pcall(function()
                es:SetVerticalAlignment(AL.c)
                if k > 1 then es:SetPadding({ Left = 28, Top = 0, Right = 0, Bottom = 0 }) end
            end)
        end
        local ent = { box = reg(card, { w = eb }), g = {} }
        for g = 1, 2 do
            local im = construct(IMAGE)
            local s = eb:AddChildToHorizontalBox(im)
            if U.ok(s) then
                pcall(function()
                    s:SetVerticalAlignment(AL.c)
                    s:SetPadding({ Left = 0, Top = 0, Right = 4, Bottom = 0 })
                end)
            end
            ent.g[g] = reg(card, { w = im, i = im })
        end
        local t = construct(TEXT)
        local s = eb:AddChildToHorizontalBox(t)
        if U.ok(s) then
            pcall(function() s:SetVerticalAlignment(AL.c); s:SetPadding({ Left = 6, Top = 0, Right = 0, Bottom = 0 }) end)
        end
        ent.t = reg(card, { w = t, t = t, face = "body", ls = 160 })
        card.hints[k] = ent
    end
    card.toast = newText(card, cv, { h = "c" }, 2)
end

local function buildShell(card)
    local over = construct(OVER)
    card.box:AddChild(over)                               -- -> SizeBoxSlot
    overlayFill(over, frameWidget())                      -- §3.2: the frame is the bottom layer
    local sb = construct(SCALE)
    pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
    local os = overlayFill(over, sb)
    local pad = num("CardPad", 32)
    if U.ok(os) then pcall(function() os:SetPadding({ Left = pad, Top = pad, Right = pad, Bottom = pad }) end) end
    local design = construct(SIZE)
    local ds = sb:AddChild(design)
    if U.ok(ds) then pcall(function() ds:SetHorizontalAlignment(AL.c); ds:SetVerticalAlignment(AL.t) end) end
    card.design = design
    local cv = construct(CANVAS)
    design:AddChild(cv)
    card.cv = cv
    -- header: tag pill, view label + READY tick, pilot name, squircle; divider
    local H = { tag = newBacker(card, cv, false, 1), tagT = newText(card, cv, { h = "c" }, 2) }
    local parts
    H.lbl, parts = newRow(card, cv, "l", { { kind = "text", face = "body", ls = 240 }, { kind = "img", pad = { 16, 0 } } },
        1)
    H.lblT, H.tick = parts[1], parts[2]
    H.name = newText(card, cv, { h = "r" }, 1)
    H.sq = newThumb(card, cv, 1, false)
    H.div = newImage(card, cv, 1)
    card.H = H
    -- stage strip: [arrow][tick][label][arrow] centred in each tab, current tab = fill backer
    card.tabs = {}
    for k = 1, 4 do
        local T = { fill = newBacker(card, cv, false, 1) }
        T.row, parts = newRow(card, cv, "c", { { kind = "img", pad = { 0, 8 } }, { kind = "img", pad = { 0, 8 } },
                                              { kind = "text" }, { kind = "img", pad = { 8, 0 }, flip = true } }, 2)
        T.al, T.tick, T.lbl, T.ar = parts[1], parts[2], parts[3], parts[4]
        card.tabs[k] = T
    end
    buildHint(card, cv)
end

-- The design box follows the width class (the ScaleBox maps it onto the card's inner area).
local function shellLayout(card)
    local w = IW[X.cls] or IW.W
    if card.dw == w or not card.design then return end
    if pcall(function() card.design:SetWidthOverride(w); card.design:SetHeightOverride(IH) end) then card.dw = w end
end

local function renderHeader(card, vm, cls)
    local H, iw, g = card.H, IW[cls], SHELL[cls]
    local pc = canon(vm.colour)
    backer(H.tag, 0, 6, 132, 72, pc)
    put(H.tagT, 0, 6, 132, 72, "P" .. tostring(vm.pnum or "?"), 44, COL.INK)
    local right = iw - 76 - 16 - (g.nameW and (g.nameW + 16) or 0)
    rect(H.lbl, 150, 6, max(80, right - 150), 72)
    show(H.lbl, true)
    font(H.lblT, 30); ink(H.lblT, COL.SAGE); text(H.lblT, tostring(vm.view or "")); show(H.lblT, true)
    if vm.ready then
        dsize(H.tick, 52); img(H.tick, TEX.tick); tint(H.tick, pc)
    else
        vis(H.tick, false)
    end
    local hd = vm.header or {}
    if g.nameW then put(H.name, iw - 92 - g.nameW, 6, g.nameW, 72, hd.pilotName, 34, COL.CREAM) else vis(H.name, false) end
    if hd.thumb then thumb(H.sq, iw - 76, 4, 76, hd.thumb) else hideThumb(H.sq) end
    rect(H.div, 0, 92, iw, 6)
    img(H.div, TEX.divider)
    tint(H.div, pc)
end

local function renderStrip(card, vm, cls)
    local st = vm.strip or {}
    local stages = type(st.stages) == "table" and st.stages or { "pilot", "vehicle", "perks", "ready" }
    local n = min(4, count(stages, 4))
    local cur = tonumber(st.current) or 1
    local iw, g = IW[cls], SHELL[cls]
    local tw = (iw - (n - 1) * 12) / max(1, n)
    local pc = canon(vm.colour)
    for k = 1, 4 do
        local T = card.tabs[k]
        if k > n then
            vis(T.fill, false); vis(T.row, false)
        else
            local x = (k - 1) * (tw + 12)
            if k == cur then backer(T.fill, x, 110, tw, 80, pc) else vis(T.fill, false) end
            rect(T.row, x + 8, 110, tw - 16, 80)
            show(T.row, true)
            local key = stages[k]
            font(T.lbl, g.tabF)
            ink(T.lbl, (k == cur) and COL.INK or ((k < cur) and COL.BEIGE or alpha(COL.BEIGE, 0.55)))
            text(T.lbl, STAGE_LABEL[key] or string.upper(tostring(key)))
            show(T.lbl, true)
            if k < cur then dsize(T.tick, 24); img(T.tick, TEX.tick); tint(T.tick, COL.BEIGE) else vis(T.tick, false) end
            -- RC-15: the 4 tabs fill the strip, so the strip cursor's arrows sit inside the current tab's pill
            local arrows = st.cursor == true and k == cur
            for _, a in ipairs({ T.al, T.ar }) do
                if arrows then dsize(a, g.arrow); img(a, TEX.arrow); tint(a, COL.INK) else vis(a, false) end
            end
        end
    end
end

local function renderHint(card, vm, cls)
    local iw = IW[cls]
    local toast = vm.toast
    if type(toast) == "string" and toast ~= "" then
        put(card.toast, 0, HINT_Y, iw, HINT_H, toast, 26, COL.AMBER)
        vis(card.hint, false)
        return
    end
    vis(card.toast, false)
    local hint = type(vm.hint) == "table" and vm.hint or {}
    local n = count(hint, 4)
    if n == 0 then return vis(card.hint, false) end
    rect(card.hint, 0, HINT_Y, iw, HINT_H)
    show(card.hint, true)
    local textMode = X.look.glyphs == "text"
    for k = 1, 4 do
        local ent, h = card.hints[k], hint[k]
        if type(h) ~= "table" then
            vis(ent.box, false)
        else
            show(ent.box, true)
            local glyphs = type(h.glyphs) == "table" and h.glyphs or {}
            local words = {}
            for gi = 1, 2 do
                local key = glyphs[gi]
                local ge = ent.g[gi]
                if key ~= nil and not textMode and GLYPH[key] then
                    dsize(ge, 40); img(ge, GLYPH[key])
                else
                    vis(ge, false)
                end
                if key ~= nil and textMode then words[#words + 1] = GLYPH_TEXT[key] or tostring(key) end
            end
            local label = tostring(h.text or "")
            if #words > 0 then label = table.concat(words, "/") .. " " .. label end
            font(ent.t, 24); ink(ent.t, COL.BEIGE); text(ent.t, label); show(ent.t, label ~= "")
        end
    end
end

---------------------------------------------------------------------------------------------------- error block (§8.2)
local ERR_LINES = 7

local function errLines(vm)
    local out = {}
    local function add(s) if type(s) == "string" and s ~= "" then out[#out + 1] = s end end
    vm = type(vm) == "table" and vm or {}
    local hd, v, p, r = vm.header or {}, vm.vehicle or {}, vm.perks or {}, vm.readyPanel or {}
    add(string.format("P%s · %s", tostring(vm.pnum or "?"), tostring(hd.pilotName or "")))
    add("STAGE: " .. (STAGE_LABEL[vm.stage] or "?") .. (vm.ready and " · READY" or ""))
    add(v.modelRow); add(v.liveryRow); add(p.kitRow); add(r.totals or p.power)
    return out
end

local function ensureErr(card)
    if card.err then return card.err end
    local cv = card.cv
    local E = { bg = newImage(card, cv, 30), title = newText(card, cv, {}, 31), lines = {} }
    for k = 1, ERR_LINES do E.lines[k] = newText(card, cv, { face = "body" }, 31) end
    card.err = E
    return E
end

local function renderErr(card, vm, on, full)
    local E = card.err
    if not on then
        if E then
            vis(E.bg, false); vis(E.title, false)
            for k = 1, ERR_LINES do vis(E.lines[k], false) end
        end
        return
    end
    E = E or ensureErr(card)
    local iw = IW[X.cls] or IW.W
    local y0, h = full and 0 or SA_Y, full and IH or SA_H
    solid(E.bg, 0, y0, iw, h, canon(opt("CardPanelColour", COL.PANEL)))
    put(E.title, 24, y0 + 24, iw - 48, 60, "RACER CARD ERROR", 40, COL.RUST)
    local lines = errLines(vm)
    for k = 1, ERR_LINES do
        put(E.lines[k], 24, y0 + 110 + (k - 1) * 64, iw - 48, 56, lines[k], 28, COL.BEIGE)
    end
end

---------------------------------------------------------------------------------------------------- PILOT (§3.3)
local function buildPilot(card, cv)
    local g = PIL[X.cls]
    local P = { bg = newFit(card, cv, FILL, 0, true) }
    local win = construct(CANVAS)
    pcall(function() win:SetClipping(CLIP) end)           -- the figure window clips the full body
    P.win = reg(card, { w = win, s = onCanvas(cv, win, 1) })
    local fig = construct(IMAGE)
    P.fig = reg(card, { w = fig, i = fig, s = onCanvas(win, fig) })
    P.sub = newSublabel(card, cv, 2)
    P.icon = newImage(card, cv, 2)
    P.name = newText(card, cv, { wrap = g.nameWrap }, 2)
    P.line = newText(card, cv, { face = "body", ls = 160 }, 2)
    P.desc = newText(card, cv, { face = "italic", wrap = g.desc and g.desc[3] }, 2)
    P.tr = {}
    for k = 1, 3 do
        P.tr[k] = { icon = newImage(card, cv, 2), name = newText(card, cv, { face = "body", ls = 120, wrap = trWrap(g) }, 2),
                    desc = newText(card, cv, { face = "italic" }, 2) }
    end
    P.sig = newText(card, cv, { ls = 60 }, 2)
    P.pname = newText(card, cv, {}, 2)
    P.cnt = newText(card, cv, { h = "r" }, 2)
    P.tiles = {}
    for k = 1, ROSTER.W do P.tiles[k] = newThumb(card, cv, 3, true) end
    P.al, P.ar = newImage(card, cv, 3), newImage(card, cv, 3)
    pcall(function() P.ar.w:SetRenderScale({ X = -1, Y = 1 }) end)
    return P
end

-- Roster strip (§3.3): a window of the class's tile count around the current pilot (the vm's list is in display order,
-- centred on the current one and wrapping); taken pilots dimmed with the holder's tag.
local function renderRoster(P, p, g, cls, pc)
    local list = type(p.roster) == "table" and p.roster or {}
    local nList = count(list, 32)
    local m = min(ROSTER[cls], nList)
    local cur = nil
    for k = 1, nList do if type(list[k]) == "table" and list[k].current then cur = k; break end end
    cur = cur or floor((nList + 1) / 2)
    local start = clamp(cur - floor((m - 1) / 2), 1, max(1, nList - m + 1))
    local r = g.roster
    local total = 0
    for k = 1, m do total = total + ((start + k - 1 == cur) and r.cur or r.oth) end
    total = total + max(0, m - 1) * r.gap
    local iw = IW[cls]
    local x = (iw - total) / 2
    local x0 = x
    for k = 1, #P.tiles do
        local T = P.tiles[k]
        local e = (k <= m) and list[start + k - 1] or nil
        if type(e) ~= "table" then
            hideThumb(T)
        else
            local s = (start + k - 1 == cur) and r.cur or r.oth
            thumb(T, x, r.y + (r.h - s) / 2, s, e.thumb,
                { current = (start + k - 1 == cur), colour = pc, takenBy = e.takenBy })
            x = x + s + r.gap
        end
    end
    if p.cursor and m > 0 then
        local a = r.arrow
        local ag = max(0, min(r.gap, floor((iw - total - 2 * a) / 2)))
        local ay = r.y + (r.h - a) / 2
        rect(P.al, x0 - ag - a, ay, a, a); img(P.al, TEX.arrow); tint(P.al, pc)
        rect(P.ar, x0 + total + ag, ay, a, a); img(P.ar, TEX.arrow); tint(P.ar, pc)
    else
        vis(P.al, false); vis(P.ar, false)
    end
end

local function renderPilot(card, P, vm, cls)
    local g = PIL[cls]
    local p = vm.pilot or {}
    local pc = canon(vm.colour)
    local iw = IW[cls]
    if opt("CardBackdrop", true) ~= false and type(p.backdrop) == "string" then
        rect(P.bg, g.bg[1], g.bg[2], g.bg[3], g.bg[4])
        tint(P.bg, COL.DIM); img(P.bg, p.backdrop)
    else
        vis(P.bg, false)
    end
    rect(P.win, g.win[1], g.win[2], g.win[3], g.win[4])
    show(P.win, true)
    figure(P.fig, g.win[3], g.win[4], p.crop, p.full)
    -- style block
    sublabel(P.sub, g.sub[1], g.sub[2], g.sub[3], g.sub[4], "RACER STYLE", g.subF)
    rect(P.icon, g.icon[1], g.icon[2], g.icon[3], g.icon[3])
    tint(P.icon, glyphCol(p.styleIcon, COL.AMBER)); img(P.icon, p.styleIcon)
    put(P.name, g.name[1], g.name[2], g.name[3], g.name[4], p.styleName, g.nameF, COL.GOLD, g.nameWrap or 0)
    if g.line then
        put(P.line, g.line[1], g.line[2], g.line[3], g.line[4], p.styleLine, g.lineF, COL.SAGE)
    else
        vis(P.line, false)
    end
    if g.desc then
        put(P.desc, g.desc[1], g.desc[2], g.desc[3], g.desc[4], p.styleDesc, g.descF, COL.BEIGE, g.desc[3])
    else
        vis(P.desc, false)
    end
    local tr = g.tr
    local traits = type(p.traits) == "table" and p.traits or {}
    for k = 1, 3 do
        local R, d = P.tr[k], traits[k]
        if type(d) ~= "table" then
            vis(R.icon, false); vis(R.name, false); vis(R.desc, false)
        else
            local y = tr.y + (k - 1) * tr.pitch
            local tx0 = tr.x + tr.icon + (tr.wrap and 12 or 16)
            local tw = tr.x + tr.w - tx0
            if tr.descF then                              -- W: name + one-line description
                rect(R.icon, tr.x, y + 6, tr.icon, tr.icon)
                put(R.name, tx0, y, tw, tr.nameH, d.name, tr.nameF, COL.CREAM, 0)
                put(R.desc, tx0, y + tr.nameH, tw, tr.descH, d.desc, tr.descF, COL.BEIGE)
            else                                          -- M / N: the name on up to 2 lines (RC-3)
                rect(R.icon, tr.x, y + (tr.nameH - tr.icon) / 2, tr.icon, tr.icon)
                put(R.name, tx0, y, tw, tr.nameH, d.name, tr.nameF, COL.CREAM, tw)
                vis(R.desc, false)
            end
            tint(R.icon, COL.BEIGE); img(R.icon, d.icon)
        end
    end
    put(P.sig, g.sig[1], g.sig[2], g.sig[3], g.sig[4], p.signature, g.sigF, COL.AMBER)
    plate(P.pname, P.cnt, g.plate, iw, p.name, p.counter)
    renderRoster(P, p, g, cls, pc)
end

---------------------------------------------------------------------------------------------------- VEHICLE (§3.4)
local function buildVehicle(card, cv)
    local V = { rb = newRenderBox(card, cv, 0) }
    V.badge = newImage(card, cv, 3)
    V.codeBg = newImage(card, cv, 3)
    V.code = newText(card, cv, { h = "c" }, 4)
    V.dl = newSublabel(card, cv, 2)
    V.tile = newThumb(card, cv, 3, false)
    V.dn = newText(card, cv, {}, 2)
    V.chip = { bg = newBacker(card, cv, false, 3), star = newImage(card, cv, 4), t = newText(card, cv, { ls = 60 }, 4) }
    V.name = newText(card, cv, {}, 2)
    V.cnt = newText(card, cv, { h = "r" }, 2)
    V.rows = { newPill(card, cv, 2), newPill(card, cv, 2) }
    V.info = newText(card, cv, { h = "c", face = "body", ls = 80, wrap = VEH[X.cls].infoWrap }, 2)   -- centred like the rows
    return V
end

local function renderVehicle(card, V, vm, cls, keep)
    local g = VEH[cls]
    local v = vm.vehicle or {}
    local pc = canon(vm.colour)
    local iw = IW[cls]
    renderBox(V.rb, g.r[1], g.r[2], g.r[3], g.r[4], v.brush, v.brushKind, v.dim, v.fallback, pc, keep)
    -- manufacturer badge; pods without one: the 3-letter model code on a squircle
    local bx, by, bs = g.badge[1], g.badge[2], g.badge[3]
    if type(v.badge) == "string" then
        rect(V.badge, bx, by, bs, bs)
        img(V.badge, v.badge)
        vis(V.codeBg, false); vis(V.code, false)
    elseif type(v.code) == "string" and v.code ~= "" then
        vis(V.badge, false)
        rect(V.codeBg, bx, by, bs, bs)
        tint(V.codeBg, COL.TILE); img(V.codeBg, TEX.squircle)
        put(V.code, bx, by, bs, bs, v.code, g.codeF, COL.CREAM)
    else
        vis(V.badge, false); vis(V.codeBg, false); vis(V.code, false)
    end
    -- DRIVEN BY
    local dr = type(v.driver) == "table" and v.driver or {}
    if g.dl then sublabel(V.dl, g.dl[1], g.dl[2], g.dl[3], g.dl[4], "DRIVEN BY", g.dlF) else vis(V.dl, false) end
    if dr.thumb then thumb(V.tile, g.tile[1], g.tile[2], g.tile[3], dr.thumb) else hideThumb(V.tile) end
    if g.dn then put(V.dn, g.dn[1], g.dn[2], g.dn[3], g.dn[4], dr.name, g.dnF, COL.CREAM) else vis(V.dn, false) end
    -- SIGNATURE chip (preset == the pilot's signature)
    local ch = V.chip
    if v.signature then
        local x, y, w, h = g.chip[1], g.chip[2], g.chip[3], g.chip[4]
        backer(ch.bg, x, y, w, h, COL.TILE)
        rect(ch.star, x + 14, y + (h - g.chipI) / 2, g.chipI, g.chipI)
        tint(ch.star, COL.AMBER); img(ch.star, TEX.star)
        put(ch.t, x + 24 + g.chipI, y, w - g.chipI - 38, h, "SIGNATURE", g.chipF, COL.AMBER)
    else
        vis(ch.bg, false); vis(ch.star, false); vis(ch.t, false)
    end
    plate(V.name, V.cnt, g.plate, iw, v.model, v.counter)
    -- MODEL / LIVERY rows; the cursor row gets the fill and the arrows outside the pill
    local px = g.ax + g.arrow + 8
    local labels = { v.modelRow, v.liveryRow }
    for k = 1, 2 do
        if labels[k] then
            pill(V.rows[k], px, g.rows[k][1], iw - 2 * px, g.rows[k][2], labels[k],
                { active = v.cursor == k, colour = pc, size = g.rowF, arrows = "out", arrow = g.arrow })
        else
            hidePill(V.rows[k])
        end
    end
    put(V.info, g.info[1], g.info[2], g.info[3], g.info[4], v.info, g.infoF, COL.SAGE, g.infoWrap or 0)
end

---------------------------------------------------------------------------------------------------- PERKS (§3.5)
local function newUpgrade(card, cv)
    local u = { cur = newImage(card, cv, 0), acc = newImage(card, cv, 1), glyph = newImage(card, cv, 1),
                name = newText(card, cv, { face = "body", ls = 160 }, 1), off = newImage(card, cv, 1),
                dig = newText(card, cv, { h = "r" }, 1) }
    local clip = construct(CANVAS)                        -- lit part of the bar: a left-aligned clipping box, level / 10
    pcall(function() clip:SetClipping(CLIP) end)
    u.clip = reg(card, { w = clip, s = onCanvas(cv, clip, 2) })
    local on = construct(IMAGE)
    u.on = reg(card, { w = on, i = on, s = onCanvas(clip, on) })
    return u
end

local function upgrade(u, x, y, g, d, cursor, pc)
    d = type(d) == "table" and d or {}
    if cursor then
        solid(u.cur, x, y, g.w, g.h, alpha(pc, 0.30))
        solid(u.acc, x, y, 8, g.h, pc)
    else
        vis(u.cur, false); vis(u.acc, false)
    end
    rect(u.glyph, x + 10, y + (g.h - g.glyph) / 2, g.glyph, g.glyph)
    tint(u.glyph, COL.BEIGE); img(u.glyph, d.icon)
    put(u.name, x + g.nameX, y, g.nameW, g.h, d.name, g.nameF, cursor and COL.CREAM or COL.BEIGE)
    local lv = clamp(floor(tonumber(d.level) or 0), 0, 10)
    local by = y + (g.h - g.barH) / 2
    rect(u.off, x + g.barX, by, g.barW, g.barH)
    tint(u.off, COL.BAR_OFF); img(u.off, TEX.bar)
    if lv > 0 then
        rect(u.clip, x + g.barX, by, g.barW * lv / 10, g.barH)
        show(u.clip, true)
        rect(u.on, 0, 0, g.barW, g.barH)
        tint(u.on, COL.BEIGE); img(u.on, TEX.bar)
    else
        vis(u.clip, false)
    end
    put(u.dig, x + g.digX, y, g.digW, g.h, tostring(lv), g.digF, COL.CREAM)
end

local function hideUpgrade(u)
    for _, k in ipairs({ "cur", "acc", "glyph", "name", "off", "clip", "dig" }) do vis(u[k], false) end
end

local function newChip(card, cv)
    return { bg = newImage(card, cv, 0), cur = newImage(card, cv, 1), acc = newImage(card, cv, 2),
             icon = newImage(card, cv, 2), name = newText(card, cv, { face = "body", ls = 80, wrap = 0 }, 2),
             plus = newText(card, cv, { face = "body", h = "c" }, 2) }
end

local function hideChip(ch)
    for _, k in ipairs({ "bg", "cur", "acc", "icon", "name", "plus" }) do vis(ch[k], false) end
end

local function chip(ch, x, y, w, h, g, d, cursor, pc)
    d = type(d) == "table" and d or {}
    solid(ch.bg, x, y, w, h, COL.TILE)
    if cursor then
        solid(ch.cur, x, y, w, h, alpha(pc, 0.30))
        solid(ch.acc, x, y, 8, h, pc)
    else
        vis(ch.cur, false); vis(ch.acc, false)
    end
    local empty = d.empty == true or (d.name == nil and d.icon == nil)
    if empty then
        vis(ch.icon, false); vis(ch.name, false)
        put(ch.plus, x, y, w, h, "+ TRAIT", g.nameF, alpha(COL.BEIGE, 0.5))
        return
    end
    vis(ch.plus, false)
    local m = clamp(rnd(w * 0.04), 6, 14)                 -- margins shrink with the chip (N: 166 su, M: 230, W: 362)
    rect(ch.icon, x + m, y + (h - g.icon) / 2, g.icon, g.icon)
    tint(ch.icon, COL.BEIGE); img(ch.icon, d.icon)
    local nx = x + m + g.icon + rnd(m * 0.7)
    local nw = x + w - rnd(m * 0.5) - nx
    put(ch.name, nx, y, nw, h, d.name, g.nameF, COL.CREAM, g.wrap and nw or 0)
end

local function newPickRow(card, cv)
    local R = { cur = newImage(card, cv, 0), acc = newImage(card, cv, 1), ic = newCell(card, cv, 2, { plus = true }),
                name = newText(card, cv, {}, 2), tick = newImage(card, cv, 2), rust = newImage(card, cv, 2), pips = {} }
    for k = 1, 4 do R.pips[k] = newImage(card, cv, 2) end
    return R
end

local function hidePickRow(R)
    vis(R.cur, false); vis(R.acc, false); hideCell(R.ic); vis(R.name, false); vis(R.tick, false); vis(R.rust, false)
    for k = 1, 4 do vis(R.pips[k], false) end
end

-- row d = {icon, iconKind, name, pips (parts: rarity), lvl (abilities: level dots), faulty, equipped, empty}
local function pickRow(R, y, w, G, d, cursor, pc)
    if cursor then
        solid(R.cur, 0, y, w, G.h, alpha(pc, 0.31))
        solid(R.acc, 0, y, 8, G.h, pc)
    else
        vis(R.cur, false); vis(R.acc, false)
    end
    local is = G.icon
    local empty = d.empty == true or d.id == false
    icon(R.ic, 20, y + (G.h - is) / 2, is, d.icon, d.iconKind or "tile", empty)
    -- right end: tick on the equipped item, then the pips / level dots / flaw bar
    local tx0 = w - 16 - G.tick
    if d.equipped then
        rect(R.tick, tx0, y + (G.h - G.tick) / 2, G.tick, G.tick)
        tint(R.tick, pc); img(R.tick, TEX.tick)
    else
        vis(R.tick, false)
    end
    local ps, pg = G.pip, rnd(G.pip / 3)
    local px1 = tx0 - 20                                  -- right edge of the pip group
    local n, tex0, col = 0, TEX.pip, COL.AMBER
    if not empty and not d.faulty then
        if d.pips then n = clamp(floor(tonumber(d.pips) or 0), 0, 4)
        elseif d.lvl then n, tex0, col = clamp(floor(tonumber(d.lvl) or 0), 0, 3), TEX.disc, COL.BEIGE end
    end
    local slotW = 4 * ps + 3 * pg
    for k = 1, 4 do
        if k <= n then
            rect(R.pips[k], px1 - slotW + (k - 1) * (ps + pg), y + (G.h - ps) / 2, ps, ps)
            img(R.pips[k], tex0)
            tint(R.pips[k], col)
        else
            vis(R.pips[k], false)
        end
    end
    if not empty and d.faulty then
        solid(R.rust, px1 - slotW, y + (G.h - 8) / 2, slotW, 8, COL.RUST)
    else
        vis(R.rust, false)
    end
    local nx = 20 + is + 18
    put(R.name, nx, y, px1 - slotW - 16 - nx, G.h, d.name or (empty and "EMPTY" or ""), G.nameF,
        cursor and COL.CREAM or COL.BEIGE)
end

local function buildPerks(card, cv)
    local g = PRK[X.cls]
    local K = { cv = cv, card = card }
    K.kit = newPill(card, cv, 2)
    K.pow = newText(card, cv, { h = "r" }, 2)
    K.en = newText(card, cv, { face = "body", ls = 120, h = "r" }, 2)
    K.subAb, K.subParts, K.subUp = newSublabel(card, cv, 2), newSublabel(card, cv, 2), newSublabel(card, cv, 2)
    K.diaBg = newImage(card, cv, 0)                       -- MI_HUD_Abilities_BG (CardDiamond "hud")
    K.cells = {}
    for key in pairs(DIAMOND) do K.cells[key] = newCell(card, cv, 2, { sub = true, pips = true, plus = true }) end
    K.parts = {}
    for k = 1, 6 do K.parts[k] = newPart(card, cv, 2) end
    K.ups = {}
    for k = 0, 5 do K.ups[k] = newUpgrade(card, cv) end
    K.style = newPill(card, cv, 2, { icon = true })
    K.chips = {}
    for k = 1, 3 do K.chips[k] = newChip(card, cv) end
    K.dIcon = newCell(card, cv, 2)
    if X.look.detail == "game" then
        local ok, w = pcall(function()
            local a = create(CLS_ABILITY)
            -- vars before the add: PreConstruct runs Refresh() (Txt_Title / RT_Desc from ItemName / ItemDescription)
            pcall(function() a.ItemName = U.ftext(" ") end)
            pcall(function() a.ItemDescription = U.ftext(" ") end)
            pcall(function() a:BP_SetIsFocusable(false) end)           -- a CommonButtonBase: never in P1's focus path
            pcall(function() a:SetVisibility(VIS.HitTestInvisible) end)
            return a
        end)
        if ok then
            local sb = construct(SCALE)
            pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
            local ss = sb:AddChild(w)
            if U.ok(ss) then pcall(function() ss:SetHorizontalAlignment(AL.l); ss:SetVerticalAlignment(AL.t) end) end
            K.dCard = reg(card, { w = sb, a = w, s = onCanvas(cv, sb, 2) })
        else
            X.look.detail = "plain"
            U.warn(TAG, "WBP_Character_Ability unavailable (%s): plain detail panels from now on (CardDetail = \"plain\", "
                .. "V-RC-06)", tostring(w))
        end
    end
    -- plain detail (CardDetail "plain", or the game card failing at run time): title + description, markup stripped
    K.dTitle = newText(card, cv, { face = "body", ls = 240 }, 2)
    K.dDesc = newText(card, cv, { face = "body", v = "t", wrap = g.dCard[3] }, 2)
    K.tag = newText(card, cv, { face = "body", ls = 80, wrap = g.tagWrap, v = g.tagWrap and "t" or "c" }, 2)
    K.large = newFit(card, cv, FIT, 2)
    return K
end

local function buildPicker(card, K)
    local cv = K.cv
    local pk = { cat = newPill(card, cv, 3, { icon = true, counter = true }), rows = {}, top = 0 }
    for k = 1, PICK_ROWS.M do pk.rows[k] = newPickRow(card, cv) end
    K.pick = pk
end

local function renderGameCard(e, d)
    local key = tostring(d.title or "") .. "\n" .. tostring(d.rich or d.plain or "")
    if e.c.k == key then return true end
    local ok, err = pcall(function()
        e.a.ItemName = U.ftext(d.title or "")
        e.a.ItemDescription = U.ftext(d.rich or d.plain or "")   -- the game's markup (keyword widgets, <H1>)
        e.a:Refresh()                                     -- BP: Txt_Title / RT_Desc from the vars; never SetAbility/SetTrait
    end)
    if ok then e.c.k = key; return true end
    X.look.detail = "plain"
    U.warn(TAG, "WBP_Character_Ability refresh failed (%s): plain detail panels from now on (V-RC-06)", tostring(err))
    return false
end

local function renderDetail(K, g, d, cls)
    d = type(d) == "table" and d or {}
    local x, y, s = g.dIcon[1], g.dIcon[2], g.dIcon[3]
    local kind = d.iconKind or "tile"
    if type(d.icon) == "string" then icon(K.dIcon, x, y, s, d.icon, kind, false) else hideCell(K.dIcon) end
    local r = g.dCard
    local game = X.look.detail == "game" and K.dCard ~= nil
    if game then
        rect(K.dCard, r[1], r[2], r[3], r[4])
        game = renderGameCard(K.dCard, d)
        show(K.dCard, game)
    end
    if game then
        vis(K.dTitle, false); vis(K.dDesc, false)
    else
        if K.dCard then vis(K.dCard, false) end
        local th = rnd(r[4] * 0.22)
        local plain = d.plain
        if type(plain) ~= "string" and type(d.rich) == "string" then
            plain = string.gsub(d.rich, "<[^>]*>", "")    -- markup stripped: <widget id="X"/>, <H1>..</>
        end
        put(K.dTitle, r[1] + 24, r[2], r[3] - 24, th, d.title, 28, COL.SAGE)
        put(K.dDesc, r[1] + 24, r[2] + th + 6, r[3] - 24, r[4] - th - 6, plain, 24, COL.BEIGE, r[3] - 24)
    end
    put(K.tag, g.tag[1], g.tag[2], g.tag[3], g.tag[4], d.tag, g.tagF, COL.AMBER, g.tagWrap or 0)
    if g.large and type(d.large) == "string" then
        rect(K.large, g.large[1], g.large[2], g.large[3], g.large[4])
        img(K.large, d.large)                             -- hidden until (unless) the art exists
    else
        vis(K.large, false)
    end
end

-- picker (§2.5, §3.5): category pill with arrows outside and "n / N" inside; rows paged around the cursor (or from
-- picker.top when the vm pages itself; rows may be the whole list or one page).
local function renderPicker(K, g, pk, pc, cls)
    local G = g.pick
    local P = K.pick
    local cursor = tonumber(pk.cursor) or 0
    pill(P.cat, G.cat[1], G.cat[2], G.cat[3], G.cat[4], pk.catName or "",
        { active = cursor == 0, colour = pc, size = G.catF, arrows = "out", arrow = G.arrow, icon = pk.catIcon,
          iconSize = rnd(G.cat[4] * 0.62), counter = pk.counter })
    local rows = type(pk.rows) == "table" and pk.rows or {}
    local nRows = count(rows, 999)
    local cap = PICK_ROWS[cls]
    local top = 0
    if nRows > cap then
        if tonumber(pk.top) then
            top = clamp(floor(tonumber(pk.top)), 0, nRows - cap)
        else
            top = P.top or 0
            if cursor >= 1 then
                if cursor - 1 < top then top = cursor - 1 elseif cursor > top + cap then top = cursor - cap end
            end
            top = clamp(top, 0, nRows - cap)
        end
    end
    P.top = top
    local iw = IW[cls]
    for k = 1, #P.rows do
        local idx = top + k
        local d = (k <= cap) and rows[idx] or nil
        if type(d) ~= "table" then
            hidePickRow(P.rows[k])
        else
            pickRow(P.rows[k], G.y + (k - 1) * G.pitch, iw, G, d, cursor == idx, pc)
        end
    end
end

local function hidePicker(P)
    if not P then return end
    hidePill(P.cat)
    for k = 1, #P.rows do hidePickRow(P.rows[k]) end
end

-- "ENERGY 3 + 9 = 12" -> "ENERGY 12" (M), "POWER 31 / 60 · EN 12" (N): the shorter totals of the narrow classes
local function energyTotal(s)
    return type(s) == "string" and string.match(s, "(%d+)%s*$") or nil
end

local function renderPerks(card, K, vm, cls)
    local g = PRK[cls]
    local p = vm.perks or {}
    local pc = canon(vm.colour)
    local cur = p.cursor
    local picking = type(p.picker) == "table" and K.pick ~= nil
    local iw = IW[cls]
    -- KIT row (A on it = READY; L/R = kit: arrows inside the pill)
    pill(K.kit, g.kit[1], g.kit[2], g.kit[3], g.kit[4], p.kitRow or "",
        { active = cur == "kit", colour = pc, size = g.kitF, arrows = "in", arrow = 36 })
    -- totals (inside the picker's area in M / N: hidden while it is open)
    local en = energyTotal(p.energy)
    if picking and g.short then
        vis(K.pow, false); vis(K.en, false)
    elseif g.short == "both" then
        local s = tostring(p.power or "") .. (en and (" · EN " .. en) or "")
        put(K.pow, g.pow[1], g.pow[2], g.pow[3], g.pow[4], s, g.powF, COL.CREAM)
        vis(K.en, false)
    else
        put(K.pow, g.pow[1], g.pow[2], g.pow[3], g.pow[4], p.power, g.powF, COL.CREAM)
        local es = (g.short == "energy" and en) and ("ENERGY " .. en) or p.energy
        put(K.en, g.en[1], g.en[2], g.en[3], g.en[4], es, g.enF, COL.SAGE)
    end
    -- board
    if picking then
        vis(K.subAb, false); vis(K.subParts, false); vis(K.subUp, false); vis(K.diaBg, false)
        for _, c in pairs(K.cells) do hideCell(c) end
        for k = 1, #K.parts do hidePart(K.parts[k]) end
        for k = 0, 5 do hideUpgrade(K.ups[k]) end
        hidePill(K.style)
        for k = 1, #K.chips do hideChip(K.chips[k]) end
    else
        hidePicker(K.pick)
        sublabel(K.subAb, g.subAb[1], g.subAb[2], g.subAb[3], g.subAb[4], "ABILITIES", g.subF)
        sublabel(K.subParts, g.subParts[1], g.subParts[2], g.subParts[3], g.subParts[4], p.partsLabel or "PARTS", g.subF)
        sublabel(K.subUp, g.subUp[1], g.subUp[2], g.subUp[3], g.subUp[4], "UPGRADES", g.subF)
        -- ability diamond: the race HUD's d-pad layout, crash in the centre
        local D = g.dia
        local pitch = D.cell + 8
        if X.look.diamond == "hud" then
            local ext = rnd(pitch * 0.25)
            rect(K.diaBg, D.x - ext, D.y - ext, 3 * D.cell + 16 + 2 * ext, 3 * D.cell + 16 + 2 * ext)
            material(K.diaBg, MAT_DIAMOND)
        else
            vis(K.diaBg, false)
        end
        local ab = type(p.ab) == "table" and p.ab or {}
        for key, pos in pairs(DIAMOND) do
            local d = (key == "crash") and ab.crash or ab[tonumber(string.sub(key, 3))]
            cell(K.cells[key], D.x + pos[1] * pitch, D.y + pos[2] * pitch, D.cell, d,
                key == "crash" and COL.GOLD or COL.BEIGE, cur == key, pc)
        end
        -- parts: 3 x 2 (more slots: more columns in the same span)
        local Pg = g.parts
        local parts = type(p.parts) == "table" and p.parts or {}
        local n = count(parts, 10)
        local cols = max(3, math.ceil(n / 2))
        local tile, px = Pg.tile, Pg.px
        if cols > 3 then
            px = Pg.span / cols
            tile = min(Pg.tile, floor(px - (Pg.px - Pg.tile)))
        end
        local k2 = tile / Pg.tile
        for k = #K.parts + 1, n do K.parts[k] = newPart(card, K.cv, 2) end
        for k = 1, #K.parts do
            if k <= n then
                local c, r = (k - 1) % cols, floor((k - 1) / cols)
                part(K.parts[k], Pg.x + c * px, Pg.y + r * Pg.py, tile, parts[k], cur == ("part" .. k), pc,
                    { pip = rnd(Pg.pip * k2), pipGap = rnd(Pg.pipGap * k2) })
            else
                hidePart(K.parts[k])
            end
        end
        -- upgrades: one column (W) or 2 x 3 column-major (M / N)
        local Ug = g.up
        local tune = type(p.tune) == "table" and p.tune or {}
        for k = 0, 5 do
            local col = (#Ug.x > 1) and floor(k / 3) or 0
            local row = (#Ug.x > 1) and (k % 3) or k
            if type(tune[k]) == "table" then
                upgrade(K.ups[k], Ug.x[col + 1], Ug.y + row * Ug.pitch, Ug, tune[k], cur == ("tun" .. k), pc)
            else
                hideUpgrade(K.ups[k])
            end
        end
        -- STYLE pill + trait chips
        local st = type(p.style) == "table" and p.style or {}
        pill(K.style, g.style[1], g.style[2], g.style[3], g.style[4], st.name or "",
            { active = cur == "style", colour = pc, size = g.styleF, arrows = "in", arrow = 36, icon = st.icon,
              iconSize = g.styleI })
        local C2 = g.chips
        local traits = type(p.traits) == "table" and p.traits or {}
        local nt = count(traits, 4)
        local cw = nt > 0 and (C2.x1 - C2.x0 - (nt - 1) * C2.gap) / nt or 0
        for k = #K.chips + 1, nt do K.chips[k] = newChip(card, K.cv) end
        for k = 1, #K.chips do
            if k <= nt then
                chip(K.chips[k], C2.x0 + (k - 1) * (cw + C2.gap), C2.y, cw, C2.h, C2, traits[k], cur == ("trait" .. k), pc)
            else
                hideChip(K.chips[k])
            end
        end
    end
    if picking then renderPicker(K, g, p.picker, pc, cls) end
    renderDetail(K, g, p.detail, cls)
end

---------------------------------------------------------------------------------------------------- READY (§3.6)
local function buildReady(card, cv)
    local R = { cv = cv, card = card, bg = newFit(card, cv, FILL, 0, true) }
    local win = construct(CANVAS)
    pcall(function() win:SetClipping(CLIP) end)
    R.win = reg(card, { w = win, s = onCanvas(cv, win, 1) })
    local fig = construct(IMAGE)
    R.fig = reg(card, { w = fig, i = fig, s = onCanvas(win, fig) })
    R.rb = newRenderBox(card, cv, 0)
    R.tile = newThumb(card, cv, 3, false)
    R.stamp = newText(card, cv, { h = "r" }, 4)
    pcall(function() R.stamp.w:SetRenderTransformAngle(-6) end)   -- the stamp leans like the game's results stamps
    R.name = newText(card, cv, {}, 2)
    R.style = newText(card, cv, { h = "r" }, 2)
    R.cells = {}
    for k = 1, 4 do R.cells[k] = newCell(card, cv, 2) end
    R.crash = newCell(card, cv, 2)
    R.parts, R.traits = {}, {}
    for k = 1, 6 do R.parts[k] = { tile = newImage(card, cv, 2) } end
    for k = 1, 3 do R.traits[k] = newImage(card, cv, 2) end
    R.styleIc = newImage(card, cv, 2)
    R.tot = newText(card, cv, { h = "c" }, 2)
    R.rows = { newPill(card, cv, 2), newPill(card, cv, 2) }
    return R
end

-- the loadout as one or two centred icon rows (§3.6): 4 abilities (Up, Left, Down, Right), crash (gold ring), parts,
-- style, traits; items shrink together when a row would not fit the card
local function renderLoadout(R, s, g, cls, pc)
    s = type(s) == "table" and s or {}
    local iw = IW[cls]
    local ab, parts, traits = s.ab or {}, s.parts or {}, s.traits or {}
    local nParts, nTraits = count(parts, 10), count(traits, 4)
    for k = #R.parts + 1, nParts do R.parts[k] = { tile = newImage(R.card, R.cv, 2) } end
    for k = #R.traits + 1, nTraits do R.traits[k] = newImage(R.card, R.cv, 2) end
    local used = { cells = {}, parts = {}, traits = {} }
    for _, row in ipairs(g.strip) do
        local items = {}
        for gi, grp in ipairs(row.groups) do
            if grp == "ab" then
                for k = 1, 4 do items[#items + 1] = { g = gi, kind = "ab", k = k, d = ab[k] } end
            elseif grp == "crash" then
                items[#items + 1] = { g = gi, kind = "crash", d = s.crash }
            elseif grp == "parts" then
                for k = 1, nParts do items[#items + 1] = { g = gi, kind = "part", k = k, d = parts[k] } end
            elseif grp == "style" then
                items[#items + 1] = { g = gi, kind = "style", d = s.style }
            elseif grp == "traits" then
                for k = 1, nTraits do items[#items + 1] = { g = gi, kind = "trait", k = k, d = traits[k] } end
            end
        end
        local total, prev = 0, nil
        for _, it in ipairs(items) do
            if prev then total = total + ((prev == it.g) and g.itemGap or g.groupGap) end
            total = total + g.sizes[it.kind]
            prev = it.g
        end
        local k2 = min(1, (iw - 16) / max(1, total))
        local x = (iw - total * k2) / 2
        prev = nil
        for _, it in ipairs(items) do
            if prev then x = x + ((prev == it.g) and g.itemGap or g.groupGap) * k2 end
            local sz = g.sizes[it.kind] * k2
            local y = row.y + (row.h - sz) / 2
            local d = it.d
            if it.kind == "ab" or it.kind == "crash" then
                local c = (it.kind == "ab") and R.cells[it.k] or R.crash
                cell(c, x, y, sz, type(d) == "string" and { glyph = d } or d,
                    it.kind == "crash" and COL.GOLD or COL.BEIGE, false)
                if it.kind == "ab" then used.cells[it.k] = true else used.crash = true end
            elseif it.kind == "part" then
                local e = R.parts[it.k].tile
                local path = type(d) == "table" and d.tile or d
                rect(e, x, y, sz, sz)
                if type(path) == "string" and not (type(d) == "table" and d.empty) then
                    img(e, path, TEX.noAffix); tint(e, COL.WHITE)
                else
                    img(e, TEX.noAffix); tint(e, alpha(COL.BEIGE, 0.5))
                end
                used.parts[it.k] = true
            elseif it.kind == "style" then
                local path = type(d) == "table" and d.icon or d
                rect(R.styleIc, x, y, sz, sz)
                tint(R.styleIc, glyphCol(path, COL.AMBER)); img(R.styleIc, path)
                used.style = true
            elseif it.kind == "trait" then
                local e = R.traits[it.k]
                local path = type(d) == "table" and d.icon or d
                rect(e, x, y, sz, sz)
                if type(path) == "string" and not (type(d) == "table" and d.empty) then
                    tint(e, COL.BEIGE); img(e, path)
                else
                    vis(e, false)
                end
                used.traits[it.k] = true
            end
            x = x + sz
            prev = it.g
        end
    end
    for k = 1, 4 do if not used.cells[k] then hideCell(R.cells[k]) end end
    if not used.crash then hideCell(R.crash) end
    for k = 1, #R.parts do if not used.parts[k] then vis(R.parts[k].tile, false) end end
    for k = 1, #R.traits do if not used.traits[k] then vis(R.traits[k], false) end end
    if not used.style then vis(R.styleIc, false) end
end

local function renderReady(card, R, vm, cls, keep)
    local g = RDY[cls]
    local rp = vm.readyPanel or {}
    local pc = canon(vm.colour)
    local iw = IW[cls]
    local fig = type(rp.figure) == "table" and rp.figure or {}
    if g.fig then                                         -- W: the pilot on the style art beside the still render
        local f = g.fig
        if opt("CardBackdrop", true) ~= false and type(fig.backdrop) == "string" then
            rect(R.bg, f[1], f[2], f[3], f[4])
            tint(R.bg, COL.DIM); img(R.bg, fig.backdrop)
        else
            vis(R.bg, false)
        end
        rect(R.win, f[1], f[2], f[3], f[4])
        show(R.win, true)
        figure(R.fig, f[3], f[4], fig.crop, fig.full)
    else
        vis(R.bg, false); vis(R.win, false)
    end
    local fb = rp.fallback or (type(vm.vehicle) == "table" and vm.vehicle.fallback) or nil
    renderBox(R.rb, g.r[1], g.r[2], g.r[3], g.r[4], rp.brush, rp.brushKind, rp.dim, fb, pc, keep)
    local th = vm.header and vm.header.thumb
    if g.tile and th then thumb(R.tile, g.tile[1], g.tile[2], g.tile[3], th) else hideThumb(R.tile) end
    put(R.stamp, g.stamp[1], g.stamp[2], g.stamp[3], g.stamp[4], "READY", g.stampF, pc)
    put(R.name, g.name[1], g.name[2], g.name[3], g.name[4], rp.line, g.nameF, COL.CREAM)
    put(R.style, g.style[1], g.style[2], g.style[3], g.style[4], rp.styleName, g.styleF, COL.AMBER)
    renderLoadout(R, rp.strip, g, cls, pc)
    put(R.tot, g.tot[1], g.tot[2], g.tot[3], g.tot[4], rp.totals, g.totF, COL.CREAM)
    local rows = type(rp.rows) == "table" and rp.rows or {}
    local cursor = tonumber(rp.cursor) or 0
    card.pulse = rp.pulse == true                         -- true: CD.tick animates row 1 (0.65 <-> 1.0, 1 s)
    for k = 1, 2 do
        local r = g.rows[k]
        if type(rows[k]) == "string" then
            local op = 1
            if k == 1 and type(rp.pulse) == "number" then op = clamp(rp.pulse, 0, 1) end
            if k == 1 and card.pulse then op = R.rows[1].out.c.op or 1 end
            pill(R.rows[k], r[1], r[2], r[3], r[4], rows[k],
                { active = cursor == k, colour = pc, size = g.rowF, opacity = op })
        else
            hidePill(R.rows[k])
        end
    end
end

---------------------------------------------------------------------------------------------------- building
local BUILD = { pilot = buildPilot, vehicle = buildVehicle, perks = buildPerks, ready = buildReady }
local RENDER = { pilot = renderPilot, vehicle = renderVehicle, perks = renderPerks, ready = renderReady }

-- One unit of the per-tick build budget (a card shell, a stage panel or a picker; spec §5.12).
local function takeBudget()
    budgetWindow()
    if X.built >= max(1, floor(num("CardBuildsPerTick", 1))) then return false end
    X.built = X.built + 1
    return true
end

local function clearCardCaches(card)
    for _, e in ipairs(card.els) do e.c = {} end
    card.dw = nil
end

local function buildCard(i)
    local card = { i = i, box = X.boxes[i], els = {}, stages = {}, bad = {}, cls = X.cls }
    X.cards[i] = card
    local t0, n0 = now(), X.nWidgets
    local ok, err = pcall(buildShell, card)
    if not ok then
        -- §8.2: the shell is replaced by a solid panel with RACER CARD ERROR and the classic text rows
        card.broken = tostring(err)
        U.warn(TAG, "card %d: shell failed (%s): RACER CARD ERROR panel (V-RC-01)", i, tostring(err))
        local ok2, err2 = pcall(function()
            pcall(function() card.box:ClearChildren() end)
            card.els, card.H, card.tabs, card.hint, card.hints, card.toast, card.err = {}, nil, nil, nil, nil, nil, nil
            local over = construct(OVER)
            card.box:AddChild(over)
            local bg = construct(IMAGE)
            pcall(function() bg:SetColorAndOpacity(lin(canon(opt("CardPanelColour", COL.PANEL)))) end)
            overlayFill(over, bg)
            local sb = construct(SCALE)
            pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
            overlayFill(over, sb)
            local design = construct(SIZE)
            sb:AddChild(design)
            card.design = design
            card.cv = construct(CANVAS)
            design:AddChild(card.cv)
            ensureErr(card)
        end)
        if not ok2 then
            card.dead = true
            U.err(TAG, "card %d: the error panel failed too (%s)", i, tostring(err2))
        end
    end
    pcall(function() card.box:SetVisibility(VIS.HitTestInvisible) end)
    shellLayout(card)
    U.log(TAG, "card %d: %s (%s): %d widgets, %.1f ms (V-RC-16)", i,
        card.dead and "unusable" or (card.broken and "error panel built" or "shell built"), tostring(X.cls),
        X.nWidgets - n0, now() - t0)
    return not card.dead
end

local function buildStage(card, stage)
    local fn = BUILD[stage]
    if not fn then
        card.bad[stage] = "unknown stage"
        return nil
    end
    local t0, n0 = now(), X.nWidgets
    local cvE
    local ok, res = pcall(function()
        local cv = construct(CANVAS)                      -- collapsed until a render shows it: a half-built one stays off
        cvE = reg(card, { w = cv, s = onCanvas(card.cv, cv, 1) })
        local panel = fn(card, cv)
        panel.cvE = cvE
        return panel
    end)
    if not ok then
        card.bad[stage] = tostring(res)
        U.warn(TAG, "card %d: %s panel failed (%s): RACER CARD ERROR in its stage area (V-RC-01)", card.i, stage,
            tostring(res))
        if cvE then pcall(function() cvE.w:SetVisibility(VIS.Collapsed) end) end
        return nil
    end
    card.stages[stage] = res
    X.nPanels = X.nPanels + 1
    U.log(TAG, "card %d: %s panel built (%s): %d widgets, %.1f ms (V-RC-16)", card.i, stage, tostring(X.cls),
        X.nWidgets - n0, now() - t0)
    return res
end

-- keep = a re-render from the card's stored view model (layout change, page re-shown, deferred panel): the 3D render
-- brushes stay as the images hold them.
local function renderCard(card, vm, keep)
    if card.dead or type(vm) ~= "table" then return false end
    X.cls = X.cls or "W"                                  -- the builders read the class too (layout not called yet)
    local cls = X.cls
    if card.cls ~= cls then
        clearCardCaches(card)
        card.cls = cls
    end
    card.vm = vm
    shellLayout(card)
    if card.broken then
        U.tryEvery("cards.error", nil, TAG, renderErr, card, vm, true, true)
        card.pending = false
        return true
    end
    U.tryEvery("cards.header", nil, TAG, renderHeader, card, vm, cls)
    U.tryEvery("cards.strip", nil, TAG, renderStrip, card, vm, cls)
    U.tryEvery("cards.hint", nil, TAG, renderHint, card, vm, cls)
    local stage = vm.stage
    local done = true
    local panel = card.stages[stage]
    if not panel and BUILD[stage] and not card.bad[stage] then
        if takeBudget() then panel = buildStage(card, stage) else done = false end
    end
    if panel and stage == "perks" and type(vm.perks) == "table" and type(vm.perks.picker) == "table"
        and not panel.pick and not panel.pickBad then
        if takeBudget() then
            local t0, n0 = now(), X.nWidgets
            local ok, err = pcall(buildPicker, card, panel)
            if ok then
                X.nPanels = X.nPanels + 1
                U.log(TAG, "card %d: picker built (%s): %d widgets, %.1f ms (V-RC-16)", card.i, tostring(cls),
                    X.nWidgets - n0, now() - t0)
            else
                panel.pick, panel.pickBad = nil, tostring(err)
                U.warn(TAG, "card %d: picker failed (%s): the board stays", card.i, tostring(err))
            end
        else
            done = false
        end
    end
    for st, p in pairs(card.stages) do
        if st == stage then
            rect(p.cvE, 0, SA_Y, IW[cls], SA_H)
            show(p.cvE, true)
        else
            vis(p.cvE, false)
        end
    end
    U.tryEvery("cards.error", nil, TAG, renderErr, card, vm, card.bad[stage] ~= nil, false)
    if panel then U.tryEvery("cards." .. stage, nil, TAG, RENDER[stage], card, panel, vm, cls, keep) end
    card.pending = not done
    return done
end

local function relayout(card)
    clearCardCaches(card)
    card.cls = X.cls
    shellLayout(card)
    if card.vm then renderCard(card, card.vm, true) end
end

---------------------------------------------------------------------------------------------------- API (§5.6)
-- View model (§5.6) as read here, with these conventions: texture paths are full object paths or perkdata's relative
-- form ("Icons/X/T_UI_Y"); pilot.roster is the display-order list around the current pilot (any length: the card shows
-- CD.ROSTER_TILES[cls] of it, W 7 / M 6 / N 5, centred on the entry with current = true); perks.picker.rows may be the
-- whole category (the card pages around picker.cursor, or from picker.top when given) or one page
-- (CD.PICKER_ROWS[cls]); optional fields: perks.detail.iconKind ("tile" | "disc" | "glyph", default "tile"),
-- readyPanel.fallback (default vehicle.fallback), readyPanel.dim, readyPanel.pulse = true (CD.tick animates the START
-- row; a number = that render opacity). M / N show the energy total only ("ENERGY 12", "POWER 31 / 60 · EN 12"), taken
-- from the last number of perks.energy. Ability entries: {glyph, sub, lvl, empty}; parts: {tile, pips, faulty, empty};
-- traits / chips: {icon, name, empty}; READY strip items: those tables or a plain path.
-- setup.buildWidgets (through racers.build): ctx = {tree, pc, newW, row (FuseHorizontalBox), realMs}. Puts four empty
-- card boxes into the row (in order, collapsed; shells are built lazily). Errors when the row is unusable (setup then
-- keeps the classic columns for this page).
function M.init(ctx)
    if type(ctx) ~= "table" or not U.ok(ctx.row) then error("cards.init: no card row") end
    -- the same page (the same context): keep its cards. Not U.same on the stored row: UE4SS validity is address based,
    -- and a new page's row can reuse a dead page's address (RC-7)
    if X and X.ctx == ctx then return true end
    X = { ctx = ctx, cls = nil, n = 0, boxes = {}, slots = {}, boxC = {}, cards = {}, early = {}, built = 0, bigUsed = 0,
          smallUsed = 0, qHi = {}, qLo = {}, queued = {}, wait = {}, missing = {}, req = {}, nWidgets = 0, nPanels = 0,
          mids = 0, loads = 0, stale = 0, budgetAt = -1e9,
          look = { frame = opt("CardFrame", "darkpanel"), hl = opt("CardHighlight", "pill"),
                   detail = opt("CardDetail", "game"), thumb = opt("CardThumbMask", "mid"),
                   glyphs = opt("CardGlyphs", "xbox"), diamond = opt("CardDiamond", "disc") } }
    for i = 1, 4 do
        local b = construct(SIZE)
        pcall(function() b:SetVisibility(VIS.Collapsed) end)
        local s = ctx.row:AddChildToHorizontalBox(b)      -- -> HorizontalBoxSlot
        if U.ok(s) then pcall(function() s:SetVerticalAlignment(AL.t) end) end
        X.boxes[i], X.slots[i], X.boxC[i] = b, s, {}
    end
    U.log(TAG, "init: 4 card slots (frame %s, pills %s, detail %s, head shots %s, glyphs %s, diamond %s) (V-RC-01)",
        X.look.frame, X.look.hl, X.look.detail, X.look.thumb, X.look.glyphs, X.look.diamond)
    return true
end

-- n players: card widths / gaps (CardW / CardGap per player count), cards > n hidden. Returns "W" | "M" | "N". A class
-- change clears every card's render caches and re-renders it from its last view model at once (RC-15, V-RC-15).
function M.layout(n)
    if not X then return nil end
    n = clamp(floor(tonumber(n) or 0), 0, 4)
    local cls = (n <= 2) and "W" or ((n == 3) and "M" or "N")
    local DW, DG = { 1720, 1720, 1140, 845 }, { 0, 60, 40, 40 }
    local cw, gap = DW[max(1, n)], DG[max(1, n)]
    if type(cfg.CardW) == "table" then cw = tonumber(cfg.CardW[max(1, n)]) or cw end
    if type(cfg.CardGap) == "table" then gap = tonumber(cfg.CardGap[max(1, n)]) or gap end
    local h = num("CardH", 1320)
    for i = 1, 4 do
        local b, bc = X.boxes[i], X.boxC[i]
        local on = i <= n
        if on then
            if (bc.w ~= cw or bc.h ~= h) and pcall(function() b:SetWidthOverride(cw); b:SetHeightOverride(h) end) then
                bc.w, bc.h = cw, h
            end
            local left = (i > 1) and gap or 0
            if bc.gap ~= left
                and pcall(function() X.slots[i]:SetPadding({ Left = left, Top = 0, Right = 0, Bottom = 0 }) end) then
                bc.gap = left
            end
        end
        if bc.on ~= on and pcall(function() b:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end) then
            bc.on = on
        end
    end
    X.n = n
    if cls ~= X.cls then
        local old = X.cls
        X.cls = cls
        for i = 1, n do                                   -- hidden cards follow on their next render (card.cls)
            local card = X.cards[i]
            if card then U.tryEvery("cards.relayout", nil, TAG, relayout, card) end
        end
        U.log(TAG, "layout: %d player(s), class %s (was %s), cards %d su, gap %d (V-RC-15)", n, cls, tostring(old), cw, gap)
    end
    return cls
end

-- Card shell i built (header, strip, hint, frame); at most CardBuildsPerTick builds per FAST tick. false = not yet
-- (budget) or unusable.
function M.ensure(i)
    if not X or not X.boxes[i] then return false end
    local card = X.cards[i]
    if card then return not card.dead end
    if not X.cls then M.layout(max(i, X.n)) end
    if not takeBudget() then return false end
    return buildCard(i)
end

-- Renders view model vm on card i: builds the shell / the vm.stage panel / the picker on first use (budget), then
-- diffs everything. Returns true when complete; false = something waits for the build budget (CD.tick finishes it
-- from this vm, without touching the render brush) or the card is unusable.
function M.render(i, vm)
    if not X or type(vm) ~= "table" or not X.boxes[i] then return false end
    if not X.cards[i] and not M.ensure(i) then
        X.early[i] = vm                                   -- the shell waits for the budget: CD.tick builds and shows it
        return false
    end
    X.early[i] = nil
    local card = X.cards[i]
    if not card then return false end
    return renderCard(card, vm, false) == true
end

-- FAST loop (racers.poll, before the renders): resets the build / load budgets, loads queued textures (one big, up to
-- CardLoadsPerTick small) and puts them on the images waiting for them, finishes deferred panels, animates a pulsing
-- START row. Returns the indices of the cards it changed (informational: they need no re-render).
function M.tick()
    if not X then return {} end
    X.built, X.bigUsed, X.smallUsed, X.budgetAt = 0, 0, 0, now()
    local touched = {}
    U.tryEvery("cards.load", nil, TAG, function()
        local smallMax = max(1, floor(num("CardLoadsPerTick", 3)))
        for _, q in ipairs({ X.qHi, X.qLo }) do
            local i, scanned = 1, 0
            while i <= #q and scanned < 64 and (X.bigUsed < 1 or X.smallUsed < smallMax) do
                scanned = scanned + 1
                local p = q[i]
                if X.queued[p] ~= q then
                    table.remove(q, i)                    -- promoted to the other queue, or done
                else
                    local big = isBig(p)
                    if (big and X.bigUsed >= 1) or (not big and X.smallUsed >= smallMax) then
                        i = i + 1
                    else
                        table.remove(q, i)
                        X.queued[p] = nil
                        local t = texNow(p) or loadNow(p)
                        arrived(p, t, touched)
                    end
                end
            end
        end
    end)
    local buildMax = max(1, floor(num("CardBuildsPerTick", 1)))
    for i = 1, 4 do
        local card = X.cards[i]
        if not card and X.early[i] and i <= X.n and X.built < buildMax then
            local vm = X.early[i]                         -- a render that found no budget for the shell
            X.early[i] = nil
            if M.ensure(i) then card = X.cards[i]; card.vm, card.pending = vm, true end
        end
        if card and card.pending and card.vm then        -- header / strip / hint at once; the panel when budget allows
            U.tryEvery("cards.deferred", nil, TAG, renderCard, card, card.vm, true)
            touched[i] = true
        end
        local R = card and card.stages.ready
        if R and card.pulse and card.vm and card.vm.stage == "ready" and opt("CardStartPulse", true) ~= false then
            local ph = (now() % 1000) / 1000
            local a = floor((0.825 + 0.175 * math.cos(2 * math.pi * ph)) * 100 + 0.5) / 100
            for _, e in ipairs(pillParts(R.rows[1])) do opacity(e, a) end
        end
    end
    local out = {}
    for i in pairs(touched) do out[#out + 1] = i end
    table.sort(out)
    return out
end

-- Texture2D for path: cached / already loaded at once, else queued (nil until CD.tick loaded it). Used to prefetch
-- (PILOT entry: the class roster's full bodies, one big texture per tick).
function M.tex(path)
    path = texPath(path)
    if not X or not path then return nil end
    return getTex(path, false)
end

-- Every render image (VEHICLE, READY) of card i (nil = all cards) lets go of its brush: call before vpreview frees the
-- bays' render targets (VP.release / VP.releaseAll with freeTargets). Returns the number of images reset.
function M.releaseRenders(i)
    if not X then return 0 end
    local n = 0
    for k, card in pairs(X.cards) do
        if i == nil or k == i then
            for _, st in ipairs({ "vehicle", "ready" }) do
                local P = card.stages[st]
                local e = P and P.rb and P.rb.render
                if e and e.held ~= nil then
                    setRender(e, nil)
                    vis(e, false)
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- Page re-shown (setup.onPageShown): every cache cleared, every card re-rendered from its last view model.
function M.clearCaches()
    if not X then return end
    for i = 1, 4 do X.boxC[i] = {} end
    if X.n > 0 then
        local n = X.n
        X.n = -1
        M.layout(n)
    end
    for i = 1, 4 do
        local card = X.cards[i]
        if card then U.tryEvery("cards.reshow", nil, TAG, relayout, card) end
    end
end

-- The page died (menu replaced): every reference dropped (no game call).
function M.forget()
    X = nil
end

function M.cls() return X and X.cls or nil end

function M.status()
    if not X then return "no page" end
    local built, panels, nReq, nGot, queued, missing = 0, 0, 0, 0, 0, 0
    for _, card in pairs(X.cards) do
        built = built + 1
        for _, p in pairs(card.stages) do panels = panels + (p.pick and 2 or 1) end
    end
    for p in pairs(X.req) do
        nReq = nReq + 1
        if TXC[p] ~= nil then nGot = nGot + 1 end
    end
    for _ in pairs(X.queued) do queued = queued + 1 end
    for _ in pairs(X.missing) do missing = missing + 1 end
    local fb = {}
    if X.look.frame ~= opt("CardFrame", "darkpanel") then fb[#fb + 1] = "frame solid" end
    if X.look.hl ~= opt("CardHighlight", "pill") then fb[#fb + 1] = "pills solid" end
    if X.look.detail ~= opt("CardDetail", "game") then fb[#fb + 1] = "detail plain" end
    if X.look.thumb ~= opt("CardThumbMask", "mid") then fb[#fb + 1] = "head shots plain" end
    return string.format("cards %d (%s), widgets %d, panels %d, tex %d/%d (queued %d, loads %d, missing %d, "
        .. "stale %d), mids %d%s", built, tostring(X.cls), X.nWidgets, panels, nGot, nReq, queued, X.loads, missing,
        X.stale, X.mids, (#fb > 0) and (", fallbacks: " .. table.concat(fb, ", ")) or "")
end

return M
