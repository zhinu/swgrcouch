-- cards2.lua (G3 Front-end UI, 0.12.0 UI v2): the player cards of the race setup's step RACERS (PILOT -> VEHICLE ->
-- PERKS -> READY per player) drawn as the game's SCENARIOS posters. User request (workflow ui-v2, 2026-10-10): the
-- mod's screens should "look like they belong to the game". Binding spec: notes/design/ui-v2/ui-redesign-final.md §9
-- (card shell, stages, text fitting §9.7, budgets §9.8, view model §9.9) with §2 / §3 (the tokens of theme.lua) and §14
-- (V-FIN checks); work item WI-07 (§12.1). racers.lua renders through this module when cfg.UiStyle = "v2" and through
-- cards.lua (the 0.11.0 look) for "classic"; both keep the API of vehicle-step-v2.md §5.6 (CD.init / layout / ensure /
-- render / tick / tex / releaseRenders / clearCaches / forget / cls / status, ROSTER_TILES, PICKER_ROWS).  UI only: no
-- input, no game-state reads. racers.lua builds one view model per card (pure data, §5.6 + §9.9) right before
-- CD.render; one widget tree and one renderer serve P1 and every guest. Every §9.9 field is optional: the 0.11.0 fields
-- (pilot.full / crop, vehicle.modelRow / liveryRow, perks.kitRow and its POWER / ENERGY strings, readyPanel.rows / line
-- / figure) are read when the new ones are missing, and the pilot's poster comes from pilots.lua's static catalog (by
-- head shot, then name) when a stage's view model carries no tile. Card = FuseSizeBox (CardW[n] x CardH, in setup's
-- card row) > FuseScaleBox (ScaleToFit, DownOnly: a shorter CardH or a narrower CardW shrinks the whole card, RC-15) >
-- FuseSizeBox (the class's design size CARD[cls].w x 1300) > FuseCanvasPanel. No padding layer: the art windows start
-- at the card's outer edge. The shell (frame, stage rail, P-tag, READY badge, rank line, hint line, toast, error block)
-- sits on that canvas; every stage is a canvas of its own (built the first time the card shows it, only the current one
-- visible) holding its art window (a clipping SizeBox > canvas > the poster or the kart photo) and its parts at the
-- card-relative places of the §9 tables (W = 1-2 players, 1762 su; M = 3, 1162; N = 4, 860). Texts are never
-- auto-shrunk (rule 7): each text sits in an auto-sized canvas slot placed from the game fonts' vertical metrics (FM:
-- the §9 tables give cap tops, cap middles and baselines); multi-line texts wrap at their WrapTextAt (plain text
-- blocks: written before the add, later SetWrapTextWidth, RC-3; rich text: AutoWrapText inside a SizeBox of the wrap
-- width). Only the style names scale (FuseScaleBox DownOnly, never under 33 su / N 30). The line counts a layout
-- depends on (W trait panels, the detail card, the W name) are estimated with theme.textWidth; after layout CD.tick
-- compares each changed text's desired size with its box and logs "text overflow" once per string (§9.7,
-- VERIFY(V-FIN-09)). Rendering is diffed (cards.lua's machinery): every element keeps what it last applied and
-- CD.render calls the engine only for what changed. A width-class change and CD.clearCaches clear every cache and
-- re-render the cards from their last view model. Textures: hard paths only, loaded within the per-tick budget (one big
-- texture >= CardLoadBigBytes; the scenario posters always take the big slot, §9.8; up to CardLoadsPerTick small ones;
-- the chrome's tiny icons outside the budget, as theme.lua) and queued otherwise; a cached texture counts only while
-- its FName is still the asset's (RC-7). Builds: at most CardBuildsPerTick card shells / stage panels / pickers per
-- FAST tick; a render that could not build returns false and CD.tick finishes it from the card's last view model. GC
-- rule: the 3D render brush (vpreview MID / render target) only comes from a view model built in the same tick;
-- re-renders from a stored view model never touch it; CD.releaseRenders empties the render images before vpreview frees
-- its targets. Head-shot and figure MIDs go onto their image in the tick they are made (their only referencer). Never
-- used: a game widget Blueprint inside a card (no WBP_Common_Btn / WBP_Character_Ability / WBP_DarkPanel: everything is
-- painted from Fuse primitives, rule 6), SetBrushFromSoftTexture or any soft property. Every game call is guarded; a
-- failed card or stage panel shows RACER CARD ERROR with the text rows of vehicle-step-v2 §8.2. VERIFY ids: V-FIN-06
-- (player stripe), V-FIN-07 (pod figure tint), V-FIN-09 (text overflow), V-FIN-14 (widget counts in CD.status), V-RC-01
-- / V-RC-15 / V-RC-16 (as cards.lua).

local C   = require("consts")
local cfg = require("config")
local St  = require("state")
local U   = require("util")

local M = {}
local TAG = "cards2"

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

---------------------------------------------------------------------------------------------------- theme tokens
-- theme.lua owns the §2 tokens (colours, type roles, asset paths, pad glyphs, text widths); cards2 imports the tokens
-- only and keeps its own element machinery (§3.1). Reached lazily (ARCH §4.0: only group-1 modules at file top);
-- M.init raises when it cannot load (racers.build fails: that page keeps the classic columns, V-RC-01).
local TH = nil
local function theme()
    if TH == nil then
        local ok, m = pcall(U.mod, "theme")
        TH = (ok and type(m) == "table" and type(m.COL) == "table" and type(m.ROLE) == "table") and m or false
        if not TH then U.err(TAG, "theme.lua failed to load (%s): no v2 cards", tostring(m)) end
    end
    return TH or nil
end

---------------------------------------------------------------------------------------------------- classes, enums
local WC = {                              -- widget classes (Fuse first, the plain UMG class as the fallback)
    canvas = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" },
    over   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" },
    size   = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" },
    scale  = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" },
    hbox   = { "/Script/Griffin.FuseHorizontalBox", "/Script/UMG.HorizontalBox" },
    image  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" },
    text   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" },
    rich   = { "/Script/Griffin.FuseRichTextBlock", "/Script/UMG.RichTextBlock" },
}

local VIS = C.E.Vis
local FIT = 2                              -- EStretch ScaleToFit
local DOWN_ONLY = 1                        -- EStretchDirection DownOnly
local CLIP = 1                             -- EWidgetClipping ClipToBounds
local AL = { l = 1, t = 1, c = 2, r = 3, b = 3, fill = 0 }   -- EHorizontal/EVerticalAlignment
local JUST = { l = 0, c = 1, r = 2 }                         -- ETextJustify
local DRAW = { box = 1, image = 3, rounded = 4 }             -- ESlateBrushDrawType
local KML = "/Script/Engine.Default__KismetMaterialLibrary"
local MID_TRANSIENT = 1                    -- EMIDCreationFlags::Transient (as vpreview / cards.lua)

---------------------------------------------------------------------------------------------------- colours
-- The diffed setters compare colours by identity: every colour is interned (one table per value, cards.lua) and derived
-- colours are memoised on it, so a view model may hand over a new table on every render.
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
local function lin(c) return { R = c.R, G = c.G, B = c.B, A = c.A } end    -- a new table per call (UE4SS may keep it)
local function slate(c) return { SpecifiedColor = lin(c), ColorUseRule = 0 } end

-- Filled by tokens() at the first M.init: COL = theme.COL (+ the derived colours below), RL = type roles, TX / MT =
-- texture / material object paths, TINY = the chrome's small icons (loaded outside the budget).
local COL, RL, TX, MT = nil, nil, nil, nil
local TINY, STENCIL = {}, {}
local K = {}                               -- derived colours (K.TILE09 ...), see tokens()

local function role(T, name, over)
    local src = T.ROLE[name] or T.ROLE.body
    local r = {}
    for k, v in pairs(src) do r[k] = v end
    for k, v in pairs(over or {}) do r[k] = v end
    r.fk = (r.font == T.FONT.display) and "display" or ((r.font == T.FONT.deco) and "deco" or "body")
    if r.colour then r.colour = canon(r.colour) end
    return r
end

local function tokens()
    if COL then return true end
    local T = theme()
    if not T then return false end
    local col = {}
    for k, v in pairs(T.COL) do col[k] = canon(v) end
    local function hex(h, a) return canon(T.hex(h, a or 1)) end
    K = {
        TILE09 = alpha(col.TILE, 0.9), TILE92 = alpha(col.TILE, 0.92), TILE50 = alpha(col.TILE, 0.5),
        SELECT_LINE = alpha(col.BONE, 0.45), HERO_LINE = alpha(col.UNSELECT, 0.55), RING_IDLE = alpha(col.BONE, 0.5),
        RAIL_RING = alpha(col.BONE, 0.35), RAIL_CUR_RING = alpha(col.TILE, 0.9), BONE45 = alpha(col.BONE, 0.45),
        FRAME_EMPTY = alpha(col.BEIGE, 0.38), PART_EMPTY = alpha(col.BEIGE, 0.35), LABEL_IDLE = alpha(col.BEIGE, 0.75),
        SAVE_IDLE = alpha(col.BEIGE, 0.8), SIG_ANY = alpha(col.BEIGE, 0.6), RANK = alpha(col.BEIGE, 0.78),
        SAGE20 = alpha(col.SAGE, 0.2), SAGE90 = alpha(col.SAGE, 0.9), PANEL05 = alpha(col.WHITE, 0.05),
        NEAR55 = alpha(col.NEAR, 0.55), CHIP = alpha(col.AMBER, 0.16), FADE = alpha(col.BAND_STRIPE, 0.8),
        SHADOW34 = alpha(col.SHADOW, 0.34), SHADOW45 = alpha(col.SHADOW, 0.45), TAG_SHADOW = alpha(col.SHADOW, 0.35),
        DARK75 = alpha(col.BLACK, 0.75), WASH_PAGE = alpha(col.PAGE, 0.43), WASH_BAND = alpha(col.BAND, 0.43),
        NAME_PILL = hex("#F4EFE7", 0.62), NAME_PILL_CUR = hex("#F4EFE7", 0.95), NAME_INK = alpha(col.NEAR, 0.92),
        BADGE_IDLE = hex("#9E9E9E"),                       -- other model tiles' badges (the no-MID look, §9.4)
        FIG_TINT = hex("#E8C15A"), FIG_PLAIN = hex("#C9B98A"),   -- pod figure: MID TileColor / plain image tint
    }
    RL = {
        name = role(T, "cardName"), model = role(T, "modelTitle"), tile = role(T, "modelTileName"),
        style = role(T, "styleName"), sub = role(T, "subLabel"), aure = role(T, "aure", { colour = col.SAGE }),
        rank = role(T, "rank"), trait = role(T, "traitTitle"), pick = role(T, "traitTitle", { ls = 0 }),
        body = role(T, "body"), tag = role(T, "tag"), sig = role(T, "tag", { ls = 300 }),
        info = role(T, "tag", { ls = 200, colour = col.SAGE }), value = role(T, "value"), hint = role(T, "hint"),
        hero = role(T, "heroLabel"), status = role(T, "statusText"), err = role(T, "helpText", { colour = col.BEIGE }),
    }
    local TXR = "/Game/Griffin/UI/Library/Textures/"
    local function obj(dir, n) return dir .. n .. "." .. n end
    local tt = T.TEX
    TX = {
        solid = tt.SolidFill, disc = tt.CircleFill, ring = tt.CircleFrame, fade = tt.GradientV, stroke = tt.TileStroke,
        tileFill = tt.TileFill300, tileSel = tt.TileSelect300, tick = tt.Tick, arrow = tt.ArrowB, star = tt.Star,
        player = tt.Player, empty = tt.ScenarioEmpty,
        kit = obj(TXR .. "Icons/", "T_UI_KitPoint_Icn"), event = obj(TXR .. "Icons/Map/", "T_UI_Map_StandardEvent_Icn"),
        affix = obj(TXR .. "Common/", "T_UI_AffixFrame"), noAffix = obj(TXR .. "Common/", "T_UI_AffixFrame_NoRarity"),
        pip = obj(TXR .. "Icons/", "T_UI_MetallicRarityPip_Icn"),
        noAbil = obj(TXR .. "Icons/Abilities/", "T_UI_Ability_Empty_Icn"),
        plane = obj(TXR .. "Icons/VehicleArchetypes/", "T_UI_Vehicle_Plane_Icn"),
        car = obj(TXR .. "Content/Vehicles/", "T_UI_Vehicle_Car"),
        squircle = obj(TXR .. "Common/", "T_UI_Squircle_A_Fill_Cmn"),   -- plain head-shot backer (CardThumbMask "plain")
    }
    local tm = T.MAT
    MT = { pill = tm.Pill, tab = tm.Tab, hero = tm.PillHero, thick = tm.PillHeroThick, shadow = tm.BlurShadow,
           equip = tm.EquipBacker, currency = tm.CurrencyBacker, stroke = tm.CardStroke, head = tm.ProfilePicture,
           mask = tm.TextureMask, richBody = T.FONT.richBody }
    STENCIL = { [tm.FontTitle] = true, [tm.FontButtons] = true }   -- SDF title materials go with bMaterialIsStencil
    TINY = {}
    for _, k in ipairs({ "solid", "ring", "fade", "stroke", "tick", "arrow", "star", "player", "kit", "event", "affix",
                         "pip", "noAffix" }) do TINY[TX[k]] = true end
    COL = col
    return true
end

---------------------------------------------------------------------------------------------------- geometry (§9)
-- Card-relative su of the class's design box (CARD[cls].w x 1300); rects are {x, y, w, h}. Text y values are the
-- anchors of tput: cap top ("t"), cap middle ("m"), baseline ("s"), last baseline ("b").
local CH = 1300
local CARD = { W = { w = 1762, pad = 64 }, M = { w = 1162, pad = 56 }, N = { w = 860, pad = 48 } }
local ART = {                              -- art window per stage
    W = { pilot = { 0, 0, 820, 1300 }, vehicle = { 0, 0, 1762, 700 }, perks = { 0, 0, 600, 1300 },
          ready = { 0, 0, 820, 1300 } },
    M = { pilot = { 0, 0, 1162, 660 }, vehicle = { 0, 0, 1162, 600 }, perks = { 0, 0, 1162, 180 },
          ready = { 0, 0, 1162, 660 } },
    N = { pilot = { 0, 0, 860, 660 }, vehicle = { 0, 0, 860, 520 }, perks = { 0, 0, 860, 180 },
          ready = { 0, 0, 860, 660 } },
}
-- poster crop ay (ax 0.5): W centred, M / N top; PERKS on the eyes band (W column 0.1, strips 0.12 / 0.11)
local ART_AY = { W = { pilot = 0.5, perks = 0.1, ready = 0.5 }, M = { pilot = 0, perks = 0.12, ready = 0 },
                 N = { pilot = 0, perks = 0.11, ready = 0 } }
local RAIL = { W = { disc = 96, cur = 118, gap = 18 }, M = { disc = 90, cur = 110, gap = 16 },
               N = { disc = 84, cur = 104, gap = 14 } }                  -- at (pad, 40), on the art
local PTAG = { W = { w = 150, h = 96, f = 52 }, M = { w = 150, h = 96, f = 52 }, N = { w = 132, h = 84, f = 46 } }
local STRIPE = { angle = 56, w = 46, gap = 10, gapOff = 22, fromRight = { W = 250, M = 250, N = 210, Wperks = 190 },
                 rule = 6 }                -- scenario art only; the kart photo gets the rule alone
local HINT = { y = 1266, glyph = 40, font = 30, gap = 28, max = { W = 3, M = 3, N = 2 } }
local DETAIL_BOTTOM = 1232
local SZ = { posterW = 960, posterH = 1580,     -- T_UI_FE_Scenario_0xx_*_Tile (catalogue §3.4)
             bodyW = 1480, bodyH = 1800 }      -- T_UI_*Char_*_Fallback full bodies
local ROSTER = { W = 7, M = 6, N = 5 }
local PICK_ROWS = { W = 7, M = 7, N = 5 }
M.ROSTER_TILES, M.PICKER_ROWS = ROSTER, PICK_ROWS

-- PILOT (§9.3). W: the poster on the left with the name on it, the style column x 876-1698 on the band; M / N: the
-- poster on top; name, style line, trait lines, signature and roster on the band.
local PIL = {
    W = { name = { base = 1236, size = 69, wrap = 692, lines = 2 }, rankGap = 64, col = { x = 876, w = 822 },
          sub = 52, subEnd = 1508, sq = { 876, 140, 120 },
          -- min 30 (spec 33; integration 0.12.0, V-FIN-09 "fix the table entry"): the pod styles CUSTOM ORD PEDROVIA
          -- (710 su at 33) and BRAWLER · FLAME VENT (713) pass the column's 678 su at 33; at 30 they fit (645 / 648)
          style = { x = 1020, base = 192, w = 488, wMax = 678, size = 45, min = 30 }, own = 244,
          desc = { y = 290, lines = 2, stop = 1000 },
          tr = { label = 92, title = 18, body = 58, pitch = 44, base = 74, gap = 12, lines = 3 },
          sig = { y = 1010, wrap = 822, lines = 2 }, roster = { y = 1090, cur = 120, oth = 96, gap = 10 } },
    M = { rank = 684, name = { base = 790, size = 55.5 }, style = { y = 818, icon = 60, size = 39, min = 33 },
          traits = { y = 900, pitch = 44, ls = 240 }, sig = { y = 1050 },
          roster = { y = 1086, cur = 136, oth = 112, gap = 12 } },
    N = { rank = 684, name = { base = 782, size = 45 }, style = { y = 806, icon = 52, size = 36, min = 30 },
          traits = { y = 880, pitch = 44, ls = 200 }, sig = { y = 1030, star = 30 },
          roster = { y = 1070, cur = 130, oth = 104, gap = 12 } },
}

-- VEHICLE (§9.4). models = the CHOOSE MODEL row (W / M); title = the N title row (also the W / M fallback when the view
-- model carries no models window); chip = the SIGNATURE chip's anchor ("r": right edge at x).
local VEH = {
    W = { photo = ART.W.vehicle, badge = { 1578, 552, 120 }, codeF = 30, rank = { 64, 724 },
          models = { y = 772, tile = 120, pitch = 240 }, title = { 34, 772, 1694, 104 },
          livery = { 34, 980, 960, 84 }, liveryF = 33, driver = { 1100, 970, 96 }, chip = { 1100, 1106, "l" },
          info = { 64, 1110, 960, 2 } },
    M = { photo = ART.M.vehicle, badge = { 986, 452, 120 }, codeF = 30, rank = { 56, 620 },
          models = { y = 664, tile = 120, pitch = 228 }, title = { 32, 664, 1098, 104 },
          livery = { 32, 872, 1098, 84 }, liveryF = 30, driver = { 56, 980, 96 }, chip = { 1106, 998, "r" },
          info = { 56, 1110, 1050, 2 } },
    N = { photo = ART.N.vehicle, badge = { 708, 392, 104 }, codeF = 27, rank = { 48, 540 }, dropModel = 764,
          title = { 24, 580, 812, 104 }, titleFit = 596, livery = { 24, 700, 812, 84 }, liveryF = 30,
          driver = { 48, 812, 96 }, chip = { 48, 930, "l" }, info = { 48, 1024, 764, 3 } },
}

-- PERKS (§9.5, the spec's PRK table): dia = {x, y, cell, pitch}; parts = {x, y, tile, pitch x, pitch y}; power =
-- {x, y, w} (N: the totals line instead); detail.y = the card's normal top (it rises above it when the text needs more
-- room than y .. 1232); pick = the picker that replaces the board from pick.y down to the detail. V-FIN-09 table fix:
-- the POWER value "31 / 60" is 332 su at Moki 54 and the MAX POWER kit's "60 / 60" 368 su (the game font), so the
-- blocks are W {1330, w 368} (spec 1336 / 362) and M {770, w 336} (spec 800 / 306), right edges unchanged at the
-- inner margin; a value that still does not fit takes Moki 48.
local PRK = {
    W = { x0 = 656, iw = 1042, kit = { 632, 44, 880, 76 }, sub = 140, dia = { 656, 186, 92, 100 },
          parts = { 1000, 186, 88, 104, 128 }, power = { 1330, 186, 368 }, upsub = 506,
          up = { y = 550, pitch = 50, cols = 1, names = true }, style = 868, styleW = 330,
          detail = { y = 952, icon = 96 }, pick = { y = 140, rows = 7, pitch = 72, lines = 1 } },
    M = { x0 = 56, iw = 1050, kit = { 32, 194, 1098, 76 }, sub = 290, dia = { 56, 336, 92, 100 },
          parts = { 446, 336, 88, 104, 128 }, power = { 770, 336, 336 }, upsub = 656,
          up = { y = 700, pitch = 52, cols = 2, names = false }, style = 876, styleW = 330,
          detail = { y = 960, icon = 96 }, pick = { y = 290, rows = 7, pitch = 72, lines = 1 } },
    N = { x0 = 48, iw = 764, kit = { 24, 194, 812, 76 }, totals = 278, sub = 334, dia = { 48, 378, 80, 88 },
          parts = { 388, 378, 80, 104, 124 }, power = nil, upsub = 662,
          up = { y = 706, pitch = 52, cols = 2, names = false }, style = 880, styleW = 300,
          detail = { y = 962, icon = 80 }, pick = { y = 286, rows = 5, pitch = 84, lines = 2 } },
}
-- board cursor keys of the diamond -> cell position in pitch units (d-pad: slot 1 Up, 2 Left, 3 Down, 4 Right)
local DIAMOND = { ab1 = { 1, 0 }, ab2 = { 0, 1 }, crash = { 1, 1 }, ab4 = { 2, 1 }, ab3 = { 1, 2 } }

-- READY (§9.6). model / style / totals = {x, baseline, size} (style: x = its right edge); loadout sizes = ability,
-- crash, part, style glyph, trait glyph; start / save = P1's pad rows; pill = the READY / WAITING pill.
local RDY = {
    W = { plate = { 876, 168, 822, 462 }, model = { 876, 704, 45 }, style = { 1698, 704, 33 },
          loadout = { x = 876, y = 740, w = 822, sizes = { 80, 66, 64, 64, 52 }, rows = 2 }, totals = { 876, 952, 30 },
          start = { 876, 980, 822, 96 }, save = { 876, 1094, 822, 84 }, pill = { 876, 986, 822, 84 } },
    M = { plate = { 606, 349, 500, 281 }, rank = 684, name = { base = 790, size = 55.5 }, model = { 56, 842, 33 },
          style = { 1106, 842, 30 }, loadout = { x = 56, y = 870, w = 1050, sizes = { 70, 58, 56, 56, 46 }, rows = 1 },
          totals = { 56, 994, 27 }, start = { 56, 1022, 1050, 90 }, save = { 56, 1130, 1050, 76 },
          pill = { 56, 1028, 1050, 84 } },
    N = { plate = { 412, 405, 400, 225 }, rank = 684, name = { base = 782, size = 45 }, model = { 48, 830, 33 },
          style = { 812, 830, 30 }, loadout = { x = 48, y = 858, w = 764, sizes = { 66, 56, 54, 54, 44 }, rows = 2 },
          totals = { 48, 1040, 27 }, start = { 48, 1066, 764, 88 }, save = { 48, 1172, 764, 72 },
          pill = { 48, 1072, 764, 84 } },
}

local STAGES = { "pilot", "vehicle", "perks", "ready" }
local STAGE_LABEL = { pilot = "PILOT", vehicle = "VEHICLE", perks = "PERKS", ready = "READY" }
-- hint glyph keys written as ASCII words with CardGlyphs = "text" (the 0.11.0 glyph rule)
local GLYPH_TEXT = { Dpad_Left = "L", Dpad_Right = "R", Dpad_Top = "UP", Dpad_Bottom = "DN", FaceButton_Bottom = "A",
                     FaceButton_Right = "B", FaceButton_Left = "X", FaceButton_Top = "Y", Special_Right = "START" }

---------------------------------------------------------------------------------------------------- text metrics
-- Vertical metrics (em) of the game's faces from the extracted Moki-Base / Overpass hhea tables (Moki 1690 / -358 /
-- gap 614 of 2048, cap 0.75; Overpass 1766 / -766 / gap 0 of 2000, cap 0.70). UE's line box is ascender + |descender|
-- + line gap tall with the gap above the glyphs (baseline = box top + box height + descender, FreeType face height).
-- em su = font size x 4/3 (UE sizes are points at the 3840 design). Aurebesh was not extracted: an estimate.
local FM = {
    display = { base = 1.125, cap = 0.75, desc = 0.175, line = 1.30 },
    body    = { base = 0.883, cap = 0.70, desc = 0.383, line = 1.266 },
    deco    = { base = 0.85, cap = 0.70, desc = 0.25, line = 1.20 },
}
local function em(size) return size * 4 / 3 end
-- line-height percentages for the spec's pitches (pitch su / the face's line box at that size)
local LH = {
    body46 = 46 / (FM.body.line * em(30)),        -- detail / description bodies, pitch 46
    body44 = 44 / (FM.body.line * em(30)),        -- W trait bodies, pitch 44
    title44 = 44 / (FM.body.line * em(28.5)),     -- detail titles, pitch 44
    caps = 0.8,                                   -- tracked 27-su lines (signature, info line)
    pick = 38 / (FM.body.line * em(28.5)),        -- N picker names, pitch 38
    name = 0.75,                                  -- W poster name (the game's poster titles use 0.75)
    model = 43 / (FM.display.line * em(36)),      -- N model title on 2 lines, pitch 43
}

-- Slot y for a text whose reference y is: "t" the first line's cap top, "m" its cap middle, "s" its baseline, "b" the
-- last line's baseline (the slot is bottom-aligned there: the block grows upward), "c" the block's middle.
local function slotY(fm, size, y, v)
    local e = em(size)
    if v == "t" then return y - (fm.base - fm.cap) * e end
    if v == "m" then return y - (fm.base - fm.cap / 2) * e end
    if v == "s" then return y - fm.base * e end
    if v == "b" then return y + fm.desc * e end
    return y
end
local VAL = { t = 0, m = 0, s = 0, b = 1, c = 0.5 }
local HAL = { l = 0, c = 0.5, r = 1 }

-- markup helpers: plain = every tag out ("<H1>Ramjet</>" -> "Ramjet"); richSafe keeps the style tags and drops the
-- self-closing widget / action tags (no decorator classes on our rich text: they would draw nothing anyway)
local function plain(s) return (tostring(s or ""):gsub("<[^>]*>", "")) end
local function richSafe(s) return (tostring(s or ""):gsub("<widget[^>]*/>", ""):gsub("<action[^>]*/>", "")) end

-- Estimated line count of s wrapped at width (theme.textWidth on the game fonts' advance widths; word breaks only).
local lineMemo, lineMemoN = {}, 0
local function lines(s, r, size, width)
    s = tostring(s or "")
    if s == "" then return 0 end
    local key = s .. "\1" .. tostring(r) .. "\1" .. tostring(size) .. "\1" .. tostring(width)
    local v = lineMemo[key]
    if v then return v end
    local n, cur = 1, nil
    for word in s:gmatch("%S+") do
        local cand = cur and (cur .. " " .. word) or word
        if cur and TH.textWidth(cand, r, size) > width then
            n, cur = n + 1, word
        else
            cur = cand
        end
    end
    if lineMemoN > 4000 then lineMemo, lineMemoN = {}, 0 end
    lineMemo[key], lineMemoN = n, lineMemoN + 1
    return n
end

local function textW(s, r, size) return TH.textWidth(tostring(s or ""), r, size) end

-- 0.12.0: boxes sized from theme.textWidth keep this margin: small Moki text at 720p laid out up to ~8 % wider than
-- the estimate (glyph rounding at a low DPI scale; live 2026-10-10 "TECH EXPERT" 358 su for 331 estimated).
local TEXT_MARGIN = 1.08

-- Greedy word breaks of s at width (theme.textWidth): -> text with "\n" between the lines, line count. More than
-- maxLines: the rest joins the last line (it may run wide; the caller leaves room).
local function breakLines(s, r, size, width, maxLines)
    local out, cur = {}, nil
    for word in tostring(s or ""):gmatch("%S+") do
        local cand = cur and (cur .. " " .. word) or word
        if cur and TH.textWidth(cand, r, size) > width and #out < (maxLines or 99) - 1 then
            out[#out + 1], cur = cur, word
        else
            cur = cand
        end
    end
    if cur then out[#out + 1] = cur end
    return table.concat(out, "\n"), math.max(1, #out)
end

-- The §6.3 cut rule: whole trailing words dropped with an ellipsis until s fits room ("CUSTOM ORD…"); never under one
-- word.
local function cutWords(s, r, size, room)
    s = tostring(s or "")
    if textW(s, r, size) <= room then return s end
    local words = {}
    for w in s:gmatch("%S+") do words[#words + 1] = w end
    for k = #words - 1, 1, -1 do
        local c = table.concat(words, " ", 1, k):gsub("%s*\194\183$", "") .. "\226\128\166"
        if textW(c, r, size) <= room then return c end
    end
    local first = words[1] or s
    if textW(first, r, size) <= room or #words <= 1 then return first end
    return first .. "\226\128\166"
end

-- "HOLD: LEAVE" -> "Hold: leave" (the hints are sentence case, §9.9); a string with lower case passes.
local function sentence(s)
    s = tostring(s or "")
    if s:find("%l") then return s end
    return s:sub(1, 1) .. s:sub(2):lower()
end

-- items of a list until the first nil (entries may be false), at most n
local function count(list, n)
    if type(list) ~= "table" then return 0 end
    local k = 0
    while k < (n or 10) and list[k + 1] ~= nil do k = k + 1 end
    return k
end

---------------------------------------------------------------------------------------------------- state
-- X = the cards of the current lobby page:
--   ctx (setup's helpers: tree, pc, newW, row, realMs), cls (width class), n (players), boxes[1..4] / slots[1..4] (the
--   card SizeBoxes in the row and their HorizontalBoxSlots), boxC (their applied sizes), cards[i], early[i] (a vm whose
--   shell waits for the budget), look (fallbacks in use: a part that fails switches its key for what follows), build /
--   load budgets of this tick, the texture queue (qHi / qLo, queued[path], wait[path] = {element = card index},
--   missing, req), matMiss (materials not found), fit (texts waiting for the overflow check), cc (the card being built
--   or rendered: its widget count) and counters.
-- card = { i, box, design, cv, els, cls, vm, pending, stages[stage] = panel, bad[stage] = why, broken / dead, nw, F
--          (frame), rail, railPill, railRing, tag, badge, rank, hint, hints, toast, err, rankWant, pulse, poster }
-- element e = { w (widget in its parent), s (CanvasPanelSlot | nil), t (text / rich text), i (image), c (render cache),
--               ci (card index), role, ls, brush (Box / RoundedBox draw), label (overflow log name), rich, sb (the rich
--               text's SizeBox), box / fitMax / lines / pitch / lastH (the overflow check), lineH, head / fig (MID) }
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
    if X.cc then X.cc.nw = (X.cc.nw or 0) + 1 end
    return w
end

local function reg(card, e)
    e.c = e.c or {}
    e.ci = card.i
    card.els[#card.els + 1] = e
    return e
end

-- Child of a canvas (anchors 0 / 0), collapsed until a render places it.
local function onCanvas(cv, w, z)
    local s = cv:AddChildToCanvas(w)                      -- -> CanvasPanelSlot
    if not U.ok(s) then error("AddChildToCanvas returned no slot") end
    if z then pcall(function() s:SetZOrder(z) end) end
    pcall(function() w:SetVisibility(VIS.Collapsed) end)
    return s
end

local function boxAdd(hb, w, padL, padR, v)               -- HorizontalBox child, vertically centred
    local s = hb:AddChildToHorizontalBox(w)               -- -> HorizontalBoxSlot
    if U.ok(s) then
        pcall(function()
            s:SetVerticalAlignment(v or AL.c)
            if (padL or 0) ~= 0 or (padR or 0) ~= 0 then
                s:SetPadding({ Left = padL or 0, Top = 0, Right = padR or 0, Bottom = 0 })
            end
        end)
    end
    return s
end

local function overAdd(over, w, h, v, pad)                -- Overlay child (default Fill / Fill)
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

-- Image on a canvas. o = {box = margin (Box draw), rounded = radius (RoundedBox), size = brush ImageSize, flip}
local function newImage(card, cv, z, o)
    local im = construct(WC.image)
    local e = reg(card, { w = im, i = im, s = onCanvas(cv, im, z) })
    if o then
        if o.box or o.rounded then
            e.brush = { drawAs = o.rounded and DRAW.rounded or DRAW.box, margin = o.box or 0, w = o.size or 32,
                        h = o.size or 32, radius = o.rounded }
        end
        if o.flip then e.flip = true; pcall(function() im:SetRenderScale({ X = -1, Y = 1 }) end) end
    end
    return e
end

-- Image child of a HorizontalBox (its size from SetDesiredSizeOverride: dsize).
local function boxImage(card, hb, padL, padR, flip)
    local im = construct(WC.image)
    boxAdd(hb, im, padL, padR)
    if flip then pcall(function() im:SetRenderScale({ X = -1, Y = 1 }) end) end
    pcall(function() im:SetVisibility(VIS.Collapsed) end)
    return reg(card, { w = im, i = im, flip = flip })
end

local function prepText(t, r, o)                          -- text block properties written before the add (RC-3)
    local wrapW = tonumber(o.wrap) or 0
    if wrapW > 0 then pcall(function() t.WrapTextAt = wrapW end) end
    if o.lineH then
        pcall(function() t.LineHeightPercentage = o.lineH end)
        pcall(function() t.ApplyLineHeightToBottomLine = false end)
    end
    pcall(function() t:SetJustification(JUST[o.justify or "l"] or 0) end)
    if r.upper then pcall(function() t:SetTextTransformPolicy(2) end) end   -- ETextTransformPolicy ToUpper
    return wrapW
end

-- Text on a canvas (auto-sized slot). o = {wrap, lineH, justify, label (the overflow log's element name)}
local function newText(card, cv, r, z, o)
    o = o or {}
    local t = construct(WC.text)
    local wrapW = prepText(t, r, o)
    return reg(card, { w = t, t = t, role = r, s = onCanvas(cv, t, z), label = o.label, lineH = o.lineH,
                       pitchSu = o.pitch, c = { wrap = wrapW } })
end

local function boxText(card, hb, r, padL, padR, o)        -- text child of a HorizontalBox
    local t = construct(WC.text)
    prepText(t, r, o or {})
    boxAdd(hb, t, padL, padR)
    pcall(function() t:SetVisibility(VIS.Collapsed) end)
    return reg(card, { w = t, t = t, role = r, label = o and o.label })
end

-- Clipping window: FuseSizeBox (ClipToBounds) on cv > FuseCanvasPanel (e.cv) for the art / photo layers.
local function newClip(card, cv, z)
    local sb = construct(WC.size)
    pcall(function() sb:SetClipping(CLIP) end)
    local e = reg(card, { w = sb, s = onCanvas(cv, sb, z) })
    local inner = construct(WC.canvas)
    sb:AddChild(inner)
    e.cv = inner
    return e
end

-- Image at its texture's size in a ScaleBox (ScaleToFit: the art keeps its aspect; the class cut-out).
local function newFit(card, cv, z)
    local im = construct(WC.image)
    local sb = construct(WC.scale)
    pcall(function() sb:SetStretch(FIT) end)
    local ss = sb:AddChild(im)                            -- -> ScaleBoxSlot
    if U.ok(ss) then pcall(function() ss:SetHorizontalAlignment(AL.c); ss:SetVerticalAlignment(AL.c) end) end
    return reg(card, { w = sb, i = im, match = true, s = onCanvas(cv, sb, z) })
end

-- The style name's DownOnly guard (§2.3: the one card text that scales): FuseScaleBox (ScaleToFit, DownOnly) > text.
local function newGuarded(card, cv, r, z, h, label)
    local sb = construct(WC.scale)
    pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
    local t = construct(WC.text)
    if r.upper then pcall(function() t:SetTextTransformPolicy(2) end) end
    local ss = sb:AddChild(t)
    if U.ok(ss) then pcall(function() ss:SetHorizontalAlignment(AL[h or "l"]); ss:SetVerticalAlignment(AL.c) end) end
    return reg(card, { w = sb, t = t, role = r, s = onCanvas(cv, sb, z), label = label, guard = true })
end

---------------------------------------------------------------------------------------------------- diffed setters
local function show(e, on)                                -- raw visibility (HitTestInvisible: the cards take no input)
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

-- Fixed slot rect (alignment 0 / 0).
local function rect(e, x, y, w, h)
    local c = e.c
    x, y, w, h = rnd(x), rnd(y), max(0, rnd(w)), max(0, rnd(h))
    if c.auto ~= false and pcall(function() e.s:SetAutoSize(false) end) then c.auto = false end
    if (c.ax ~= 0 or c.ay ~= 0) and pcall(function() e.s:SetAlignment({ X = 0, Y = 0 }) end) then c.ax, c.ay = 0, 0 end
    if (c.x ~= x or c.y ~= y) and pcall(function() e.s:SetPosition({ X = x, Y = y }) end) then c.x, c.y = x, y end
    if (c.w ~= w or c.h ~= h) and pcall(function() e.s:SetSize({ X = w, Y = h }) end) then c.w, c.h = w, h end
end

-- Auto-sized slot (the widget's desired size) with its alignment point (ax, ay) at (x, y).
local function place(e, x, y, ax, ay)
    local c = e.c
    x, y, ax, ay = rnd(x), rnd(y), ax or 0, ay or 0
    if c.auto ~= true and pcall(function() e.s:SetAutoSize(true) end) then c.auto, c.w, c.h = true, nil, nil end
    if (c.ax ~= ax or c.ay ~= ay) and pcall(function() e.s:SetAlignment({ X = ax, Y = ay }) end) then
        c.ax, c.ay = ax, ay
    end
    if (c.x ~= x or c.y ~= y) and pcall(function() e.s:SetPosition({ X = x, Y = y }) end) then c.x, c.y = x, y end
end

local fontObjs, matObjs = {}, {}
local function fontObj(path)
    local o = fontObjs[path]
    if o and U.ok(o) then return o end
    o = U.obj(path)
    if U.ok(o) then fontObjs[path] = o; return o end
    return nil
end

local fontMatBroken = false
-- FSlateFontInfo from the element's role (missing fields are zero-filled: no outline); the SDF title materials with
-- bMaterialIsStencil (cfg.UiFontMaterials, theme.lua's rule; a refused material switches them off, V-PARTS-02).
local function font(e, size)
    local r = e.role
    if not (e.t and r) then return end
    size = tonumber(size) or r.size
    local ls = e.ls or r.ls or 0
    local mpath = (opt("UiFontMaterials", true) ~= false and not fontMatBroken) and r.material or nil
    local c = e.c
    if c.fs == size and c.fm == mpath and c.fl == ls then return end
    local f = fontObj(r.font)
    if not f then return end
    local m = nil
    if mpath then
        m = matObjs[mpath]
        if not (m and U.ok(m)) then m = U.obj(mpath); if U.ok(m) then matObjs[mpath] = m else m = nil end end
    end
    local info = { FontObject = f, TypefaceFontName = U.fname(r.face or "Bold"), Size = size, LetterSpacing = ls }
    if m then info.FontMaterial = m; info.bMaterialIsStencil = STENCIL[mpath] == true end
    local ok, err = pcall(function() e.t:SetFont(info) end)
    if not ok and m then
        fontMatBroken = true
        U.warn(TAG, "SetFont with a font material failed (%s): plain fonts on the cards from now on (V-PARTS-02)",
            tostring(err))
        info.FontMaterial, info.bMaterialIsStencil = nil, nil
        ok = pcall(function() e.t:SetFont(info) end)
        mpath = nil
    end
    if ok then c.fs, c.fm, c.fl, e.fitDirty = size, mpath, ls, true end
end

local function text(e, s)
    if e.c.s == s then return end
    if pcall(function() e.t:SetText(U.ftext(s)) end) then e.c.s, e.fitDirty = s, true end
end

local function ink(e, col)
    col = canon(col)
    if e.c.ink ~= col and pcall(function() e.t:SetColorAndOpacity(slate(col)) end) then e.c.ink = col end
end

local function tint(e, col)
    col = canon(col)
    if e.c.tint ~= col and pcall(function() e.i:SetColorAndOpacity(lin(col)) end) then e.c.tint = col end
end

local function wrap(e, w)                                 -- 0 = no wrapping (plain text blocks)
    w = rnd(w or 0)
    if e.c.wrap == w then return end
    -- UCommonTextBlock::SetWrapTextWidth(Int): WrapTextAt + SynchronizeProperties (FuseTextBlock is a CommonTextBlock)
    local ok = pcall(function() e.t:SetWrapTextWidth(w) end)
    if not ok then
        U.logOnce("cards2.wrap", TAG, "SetWrapTextWidth unavailable: WrapTextAt written as a property (V-RC-34)")
        ok = pcall(function() e.t.WrapTextAt = w end)
    end
    if ok then e.c.wrap, e.fitDirty = w, true end
end

local function dsize(e, w, h)                             -- an image's size in a box
    h = h or w
    if (e.c.dw ~= w or e.c.dh ~= h) and pcall(function() e.i:SetDesiredSizeOverride({ X = w, Y = h }) end) then
        e.c.dw, e.c.dh = w, h
    end
end

local function opacity(e, a)
    if e.c.op ~= a and pcall(function() e.w:SetRenderOpacity(a) end) then e.c.op = a end
end

local function rscale(e, k)                               -- about the widget's centre (a mirrored image stays mirrored)
    if e.c.rs == k then return end
    local sx = e.flip and -k or k
    if pcall(function() e.w:SetRenderScale({ X = sx, Y = k }) end) then e.c.rs = k end
end

local function angle(e, a)
    if e.c.ang ~= a and pcall(function() e.w:SetRenderTransformAngle(a) end) then e.c.ang = a end
end

---------------------------------------------------------------------------------------------------- overflow check
-- §9.7: every text whose desired size exceeds its box after layout is logged once per string ("text overflow",
-- VERIFY(V-FIN-09)). A changed text is queued with the time; CD.tick reads GetDesiredSize a few FAST ticks later (Slate
-- has laid it out by then), at most 8 per tick. Wrapped texts are checked by their line count instead.
local FIT_SEEN, fitSeenN = {}, 0
local GUARD_TOL = 1.12                                    -- a guarded text shrunk by up to 12 % is not reported

local function queueFit(e)
    if not (X and e.fitDirty and e.label and e.box) then return end
    e.fitDirty = false
    local q = X.fit
    -- 0.12.0: auto-wrapped rich text wraps at the width of the previous frame's arrange, so its first measures after a
    -- change can be the unwrapped line (live 2026-10-10 "trait body 1087/774" at 30 fps): checked ~250 ms after
    if #q < 256 then q[#q + 1] = { e = e, s = e.c.s, at = now() + (e.rich and 190 or 0) } end
end

local function fitCheck()
    local q = X.fit
    if #q == 0 then return end
    local t = now()
    local done = 0
    while #q > 0 and done < 8 do
        local f = q[1]
        if t - f.at < 60 then break end                   -- time ordered: the rest is newer
        table.remove(q, 1)
        local e = f.e
        if e.c.s == f.s and e.c.v and (e.box or 0) > 0 then
            done = done + 1
            local w, h
            pcall(function()
                local d = (e.t or e.w):GetDesiredSize()   -- UWidget::GetDesiredSize() -> FVector2D (unscaled)
                w, h = tonumber(d.X), tonumber(d.Y)
            end)
            if not (w and w > 0) and not f.retry and #q < 256 then
                q[#q + 1] = { e = e, s = f.s, at = t, retry = true }
            end
            if w and w > 0 then
                local limit = e.fitMax or e.box
                -- 0.12.0 (live 2026-10-10): a Slate-wrapped line keeps its trailing space in the measure (+ ~0.6 em),
                -- and a guarded text is shrunk to its box by its ScaleBox: only a shrink past GUARD_TOL is visible
                local wrapped = (e.c.wrap or 0) > 0 or (e.rich and (e.c.sw or 0) > 0)   -- rich: the SizeBox wraps
                local tol = wrapped and em(e.c.fs or 30) * 0.6 or 2
                -- one line: half a physical pixel per glyph (Slate's pixel rounding, theme.pxSu; 720p "31 / 60" 340/336)
                if not wrapped then tol = max(tol, (utf8.len(tostring(f.s)) or #tostring(f.s)) * TH.pxSu() * 0.5) end
                if e.guard then limit = limit * GUARD_TOL end
                local over = nil
                if w > limit + tol then over = string.format("%d/%d", rnd(w), rnd(limit)) end
                if not over and e.lines and e.pitch and e.lastH and h then
                    local n = 1 + max(0, floor((h - e.lastH) / e.pitch + 0.5))
                    if n > e.lines then over = string.format("%d lines/%d", n, e.lines) end
                end
                if over then
                    local key = tostring(e.label) .. "\n" .. tostring(f.s)
                    if not FIT_SEEN[key] then
                        if fitSeenN > 2000 then FIT_SEEN, fitSeenN = {}, 0 end
                        FIT_SEEN[key], fitSeenN = true, fitSeenN + 1
                        X.overflows = X.overflows + 1
                        U.warn(TAG, "text overflow card %d %s %s (V-FIN-09): \"%s\"", e.ci or 0, tostring(e.label), over,
                            tostring(f.s))
                    end
                end
            end
        end
    end
end

-- Text s on an auto-sized slot. a = h .. v: h "l" | "c" | "r" = x is the text's left edge / centre / right edge; v as
-- slotY. box = the width it must fit (the overflow check; nil = not checked); nLines = the lines a wrapped text may
-- take.
local function tput(e, x, y, s, size, col, a, box, nLines)
    s = (s ~= nil) and tostring(s) or ""
    if s == "" then return vis(e, false) end
    a = a or "lt"
    local h, v = string.sub(a, 1, 1), string.sub(a, 2, 2)
    local fm = FM[e.role and e.role.fk or "body"] or FM.body
    place(e, x, slotY(fm, size, y, v), HAL[h] or 0, VAL[v] or 0)
    font(e, size)
    ink(e, col)
    text(e, s)
    e.box, e.lines, e.fitMax = box, nLines, nil
    if nLines then
        e.lastH = fm.line * em(size)
        e.pitch = e.pitchSu or (e.lastH * (e.lineH or 1))
    end
    queueFit(e)
    return show(e, true)
end

---------------------------------------------------------------------------------------------------- textures (RC-7, RC-9)
local TXC = {}            -- path -> Texture2D; module level (assets outlive the page), re-checked on every use

local function assetName(path) return string.match(path, "%.([^%./]+)$") or path end

-- A vm path may be perkdata's relative form ("Icons/X/T_UI_Y", expanded as perkdata.lua's header says) or a full
-- object path; a package path without ".Name" gets its object name. nil for anything else.
local pathCache = {}
local function texPath(p)
    if type(p) ~= "string" or p == "" then return nil end
    local n = pathCache[p]
    if n then return n end
    n = (string.sub(p, 1, 1) == "/") and p or ("/Game/Griffin/UI/Library/Textures/" .. p)
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
        if X then X.stale = X.stale + 1 end
    end
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.ok(o) then TXC[path] = o; return o end
    return nil
end

-- RC-9 / §9.8: bytes of the big textures (asset list; UI textures are NeverStream with one mip, so a LoadAsset reads
-- all of it). The SCENARIOS posters (960 x 1580: DXT1 0.76 MB, DXT5 1.5 MB for KATJA MOX, GOLI & 02-R0, KESTAR BOOL)
-- always take the big slot: one poster per tick.
local BIG = {
    { "/Content/Characters/", "_Fallback.", 2664556 },   -- full bodies 1480 x 1800 DXT5 (pod figures)
    { "/Content/Vehicles/", "_Fallback.", 11310576 },    -- class cut-outs 1950 x 1450
    { "/Content/Arcade/", "_Bg.", 4692068 },
    { "/Content/RacerStyles/", "_Bg.", 4147764 },
}
local POSTER_DXT5 = { "_Scenario_009_", "_Scenario_010_", "_Scenario_013_" }
local function isPoster(path) return string.find(path, "/Content/Scenarios/", 1, true) ~= nil end
local function estBytes(path)
    if isPoster(path) then
        for _, k in ipairs(POSTER_DXT5) do if string.find(path, k, 1, true) then return 1517369 end end
        return 758969
    end
    for _, b in ipairs(BIG) do
        if string.find(path, b[1], 1, true) and string.find(path, b[2], 1, true) then return b[3] end
    end
    return 66000
end
local function isBig(path) return isPoster(path) or estBytes(path) >= num("CardLoadBigBytes", 1048576) end
-- The chrome's icons and fills (asset list: 0.8 - 22 KB each, the Xbox glyphs ~7 KB) load outside the budget, so the
-- rail, arrows, ticks and hint glyphs show in a card's first frame (theme.lua's rule).
local function tiny(path)
    return TINY[path] == true or string.find(path, "/Textures/Platform/Xbox/", 1, true) ~= nil
        or string.find(path, "/Icons/BuildStats/T_UI_BuildStats_", 1, true) ~= nil
end

-- The per-tick budgets (builds, loads) are reset by CD.tick; a render 100 ms after the last reset (3 FAST ticks: no
-- poll running) opens a new window itself, so nothing waits forever. Never sooner: a slow build must not let a second
-- one into the same tick.
local function budgetWindow()
    local t = now()
    if t - X.budgetAt > 100 then X.built, X.bigUsed, X.smallUsed, X.budgetAt = 0, 0, 0, t end
end

local function smallMax() return max(1, floor(num("CardLoadsPerTick", 3))) end

-- One LoadAsset inside this tick's budget. nil: over budget or missing.
local function loadNow(path)
    budgetWindow()
    local big = false
    if not tiny(path) then
        big = isBig(path)
        if big then
            if X.bigUsed >= 1 then return nil end
            X.bigUsed = X.bigUsed + 1
        else
            if X.smallUsed >= smallMax() then return nil end
            X.smallUsed = X.smallUsed + 1
        end
    end
    local t0 = now()
    local ok, err = pcall(LoadAsset, path)                -- game thread (FAST loop); 3 returns, re-found below
    local t = texNow(path)
    X.loads = X.loads + 1
    if not t then
        X.missing[path] = true
        U.logOnce("cards2.missing:" .. path, TAG, "texture missing: %s%s (its element stays hidden or shows its fallback)",
            path, ok and "" or (" (" .. tostring(err) .. ")"))
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

-- Material (or data table) by hard path; a path not found is remembered for the page (no retry every render).
local function matObj(path)
    if type(path) ~= "string" then return nil end
    local o = matObjs[path]
    if o and U.ok(o) then return o end
    if X and X.matMiss[path] then return nil end
    o = U.obj(path)                                       -- StaticFindObject, else LoadAsset (game thread)
    if U.ok(o) then matObjs[path] = o; return o end
    matObjs[path] = nil
    if X then
        X.matMiss[path] = true
        U.logOnce("cards2.mat?" .. path, TAG, "material not usable: %s (its element stays hidden or falls back)", path)
    end
    return nil
end

---------------------------------------------------------------------------------------------------- brushes, MIDs
-- A struct PARAM table is zero-filled (ue4ss-api §8): Box / RoundedBox brushes go through UImage:SetBrush with a full
-- table (theme.lua's brushTable); plain images use SetBrushFromTexture / SetBrushFromMaterial.
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
                              Width = 0, RoundingType = 0 }                -- FixedRadius
    end
    return t
end

local function applyRes(e, res, isTex, match)
    local b = e.brush
    local ok = false
    if b and b.drawAs ~= DRAW.image and not setBrushBroken then
        local okB, err = pcall(function() e.i:SetBrush(brushTable(res, b)) end)
        if okB then
            ok = true
        else
            setBrushBroken = true
            U.warn(TAG, "UImage:SetBrush with a table failed (%s): plain Image draws on the cards from now on (V-PARTS-08)",
                tostring(err))
        end
    end
    if not ok then
        if isTex then
            ok = pcall(function() e.i:SetBrushFromTexture(res, match == true) end)   -- (Texture2D, bMatchSize)
        else
            ok = pcall(function() e.i:SetBrushFromMaterial(res) end)
        end
    end
    if ok then e.c.res, e.c.resTex = res, isTex end
    return ok
end

-- A new brush ImageSize (a pill that changes height keeps its half-height ends).
local function bsize(e, w, h)
    local b = e.brush
    if not b then return end
    w, h = rnd(w), rnd(h or w)
    if b.w == w and b.h == h then return end
    b.w, b.h = w, h
    if e.c.res and U.ok(e.c.res) then applyRes(e, e.c.res, e.c.resTex, false) end
end

local function newMid(path)
    local parent, kml = matObj(path), U.cdo(KML)
    if not (parent and U.ok(kml)) then return nil, "material or KismetMaterialLibrary not found" end
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

-- Head shots: M_UI_CharacterProfilePicture MID (parameter Texture, squircle mask built in; cards.lua).
local function headFailed(why)
    if X.look.thumb ~= "mid" then return end
    X.look.thumb = "plain"
    U.warn(TAG, "head-shot MID unavailable (%s): plain head shots from now on (CardThumbMask = \"plain\")", tostring(why))
end

local function applyHead(e, t)
    local mid = U.ok(e.mid) and e.mid or nil
    local fresh = mid == nil
    if fresh then
        local why
        mid, why = newMid(MT.head)
        if not mid then headFailed(why); return applyTex(e, t) end
    end
    local ok, err = pcall(function() mid:SetTextureParameterValue(U.fname("Texture"), t) end)   -- (Name, Texture)
    if not ok then headFailed(err); return applyTex(e, t) end
    if fresh then
        -- the new MID's only referencer will be this brush: set in the same tick (GC rule)
        if not pcall(function() e.i:SetBrushFromMaterial(mid) end) then return false end
        e.mid = mid
    end
    e.c.res = nil
    return true
end

-- Pod figure (§9.3, VERIFY(V-FIN-07)): a MID of MI_UI_Squircle_TextureMask on a plain image, TileArt = the body,
-- Texture = the plain white fill (no squircle cut: the body has its own alpha), Desaturation 1 + Color Overlay Amount 1
-- + TileColor #E8C15A (a warm print), ImageScale 1, offsets 0.5, In Width / Height Override = the image size. A failure
-- switches to the plain image tinted #C9B98A (CardFigureTint = "plain": an image tint always works).
local function figFailed(why)
    if X.look.fig ~= "mid" then return end
    X.look.fig = "plain"
    U.warn(TAG, "pod figure MID unavailable (%s): plain #C9B98A tint from now on (CardFigureTint = \"plain\", V-FIN-07)",
        tostring(why))
end

local function figParams(e)
    local mid = U.ok(e.mid) and e.mid or nil
    if not mid then return end
    local w, h = e.c.w or SZ.bodyW, e.c.h or SZ.bodyH
    if e.c.mw == w and e.c.mh == h then return end
    pcall(function()
        mid:SetScalarParameterValue(U.fname("In Width Override"), w)
        mid:SetScalarParameterValue(U.fname("In Height Override"), h)
    end)
    e.c.mw, e.c.mh = w, h
end

local function applyFig(e, t)
    local mid = U.ok(e.mid) and e.mid or nil
    local fresh = mid == nil
    if fresh then
        local why
        mid, why = newMid(MT.mask)
        if not mid then figFailed(why); return applyTex(e, t) end
    end
    local mask = texNow(TX.solid) or loadNow(TX.solid)
    local ok, err = pcall(function()
        local FN = U.fname
        mid:SetTextureParameterValue(FN("TileArt"), t)
        if mask then mid:SetTextureParameterValue(FN("Texture"), mask) end
        mid:SetScalarParameterValue(FN("Desaturation"), 1)
        mid:SetScalarParameterValue(FN("Color Overlay Amount"), 1)
        mid:SetVectorParameterValue(FN("TileColor"), lin(K.FIG_TINT))
        mid:SetScalarParameterValue(FN("ImageScale"), 1)
        mid:SetScalarParameterValue(FN("ImageXOffset"), 0.5)
        mid:SetScalarParameterValue(FN("ImageYOffset"), 0.5)
    end)
    if not ok then figFailed(err); return applyTex(e, t) end
    if fresh then
        if not pcall(function() e.i:SetBrushFromMaterial(mid) end) then
            figFailed("SetBrushFromMaterial failed")
            return applyTex(e, t)
        end
        e.mid = mid
        U.logOnce("cards2.fig", TAG, "pod figure on the empty poster: MI_UI_Squircle_TextureMask MID, TileColor #E8C15A; "
            .. "a black box or an untinted body = CardFigureTint \"plain\" (V-FIN-07)")
    end
    e.c.res, e.c.mw, e.c.mh = nil, nil, nil
    figParams(e)
    return true
end

applyTex = function(e, t)
    if e.head and X.look.thumb == "mid" then return applyHead(e, t) end
    if e.fig and X.look.fig == "mid" then return applyFig(e, t) end
    local ok = applyRes(e, t, true, e.match)
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
        if applyTex(e, t) then c.tex, c.mat = path, nil; return show(e, true) end
        show(e, false)
        return false
    end
    if not X.missing[path] then waitFor(e, path) end
    if fb and fb ~= path then
        c.fbw = fb
        if c.tex == fb then show(e, true); return false end
        local ft = getTex(fb, true)
        if ft and applyTex(e, ft) then c.tex, c.mat = fb, nil; show(e, true); return false end
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
                c.tex, c.mat = path, nil
                show(e, true)
                if e.fig then figParams(e) end
                touched[ci] = true
            end
        end
    end
end

local function material(e, path)
    if e.c.mat == path then return show(e, true) end
    local m = matObj(path)
    if m and applyRes(e, m, false) then
        e.c.mat, e.c.tex, e.mid = path, nil, nil
        return show(e, true)
    end
    vis(e, false)
    return false
end

-- 3D render brush (vpreview MID or render target) from a view model built in this tick. e.held is the object the image
-- holds: not a render cache (a Slate rebuild keeps the brush), so a cache reset never drops it. kind "building" (UI v2
-- vpreview: show the wash) keeps the preview's brush type (SetupPreviewBrush).
local function setRender(e, brush, kind)
    if brush == nil then
        if e.held ~= nil then
            pcall(function() e.i:SetBrushResourceObject(nil) end)   -- the MID loses its last UPROPERTY reference
            e.held = nil
        end
        return false
    end
    if kind == "building" then kind = (opt("SetupPreviewBrush", "material") == "texture") and "texture" or "material" end
    if e.held == nil or e.held ~= brush then              -- UE4SS == compares the object addresses
        local ok = pcall(function()
            if kind == "texture" then e.i:SetBrushResourceObject(brush) else e.i:SetBrushFromMaterial(brush) end
        end)
        if not ok then return e.held ~= nil end
        e.held = brush
    end
    return true
end

---------------------------------------------------------------------------------------------------- rich text
-- Body text with GOLD keywords (§9.5 "rich DT_RichText_Body look"): FuseRichTextBlock with the DT_RichText_Body style
-- set (Medium Italic 30 #E4DED5, <H1> #CFA04E) and AutoWrapText inside a SizeBox whose WidthOverride is the wrap width
-- (a rich text block has no SetWrapTextWidth; the SizeBox follows a class change). No decorator classes: the
-- <widget id/> keyword icons are dropped (richSafe). A failure to build one switches to plain text blocks with the
-- markup stripped (no GOLD keywords) for what follows. o = {wrap, lineH, pitch, label}
local function newRich(card, cv, z, o)
    o = o or {}
    local wrapW = tonumber(o.wrap) or 0
    if X.look.rich then
        local ok, res = pcall(function()
            local sb = construct(WC.size)
            local t = construct(WC.rich)
            local dt = matObj(MT.richBody)
            if dt then pcall(function() t:SetTextStyleSet(dt) end) end
            pcall(function() t.AutoWrapText = true end)           -- before the add: wraps at the SizeBox's width
            if o.lineH then
                pcall(function() t.LineHeightPercentage = o.lineH end)
                pcall(function() t.ApplyLineHeightToBottomLine = false end)
            end
            if wrapW > 0 then pcall(function() sb:SetWidthOverride(wrapW) end) end
            sb:AddChild(t)
            return { sb = sb, t = t }
        end)
        if ok then
            local e = reg(card, { w = res.sb, t = res.t, sb = res.sb, rich = true, role = RL.body,
                                  s = onCanvas(cv, res.sb, z), label = o.label, lineH = o.lineH, pitchSu = o.pitch })
            e.c.sw = wrapW
            return e
        end
        X.look.rich = false
        U.warn(TAG, "FuseRichTextBlock unavailable (%s): plain card bodies without GOLD keywords from now on",
            tostring(res))
    end
    return newText(card, cv, RL.body, z, o)
end

-- Body s at (x, y = the first line's cap top), wrapped at wrapW, nLines = the lines it may take (overflow check).
local function rput(e, x, y, s, wrapW, nLines)
    s = (s ~= nil) and tostring(s) or ""
    if s == "" then return vis(e, false) end
    if not e.rich then
        wrap(e, wrapW)
        return tput(e, x, y, plain(s), 30, COL.BEIGE, "lt", wrapW, nLines)
    end
    if e.c.sw ~= wrapW and pcall(function() e.sb:SetWidthOverride(wrapW) end) then e.c.sw, e.fitDirty = wrapW, true end
    place(e, x, slotY(FM.body, 30, y, "t"), 0, 0)
    local m = richSafe(s)
    if e.c.s ~= m and pcall(function() e.t:SetText(U.ftext(m)) end) then e.c.s, e.fitDirty = m, true end
    e.box, e.lines, e.fitMax = wrapW, nLines, nil
    e.lastH = FM.body.line * em(30)
    e.pitch = e.pitchSu or e.lastH * (e.lineH or 1)
    queueFit(e)
    return show(e, true)
end

---------------------------------------------------------------------------------------------------- shared parts
-- One closure (Lua allows 200 locals in the main chunk): the parts below are its locals, PARTS exports them.
local PARTS = (function()
    -- Painted pill (the WBP_CommonButtonBacker_Pill / Hero_Btn look without the widget): MI_UI_Pill_Generic fill + one
    -- line image (MI_UI_Pill_Btn_Hero idle inner line / MI_UI_Pill_Btn_Hero_Thick focus rim), both Box 0.5 with
    -- ImageSize = the pill height (half-height ends). Looks: "select" (selector idle: TILE @0.9 + BONE @0.45 line),
    -- "focus" (the cursor: TILE + 6-su WHITE rim), "hero" (hero idle: TILE @0.92 + #D3D2C6 @0.55 line), "flat" (the
    -- fill alone in col).
    local function newPill(card, cv, z)
        return { fill = newImage(card, cv, z, { box = 0.5, size = 76 }),
                 line = newImage(card, cv, z, { box = 0.48, size = 76 }) }
    end

    local function hidePill(P) vis(P.fill, false); vis(P.line, false) end

    local function pill(P, x, y, w, h, look, col, k)
        k = k or 1
        bsize(P.fill, h, h)
        rect(P.fill, x, y, w, h)
        material(P.fill, MT.pill)
        local fill = col or COL.TILE
        if look == "focus" then fill = COL.TILE elseif look == "hero" then fill = K.TILE92 elseif look == "select" then
            fill = K.TILE09 end
        tint(P.fill, fill)
        rscale(P.fill, k)
        if look == "flat" then return vis(P.line, false) end
        bsize(P.line, h, h)
        rect(P.line, x, y, w, h)
        material(P.line, (look == "focus") and MT.thick or MT.hero)
        tint(P.line, (look == "focus") and COL.WHITE or ((look == "hero") and K.HERO_LINE or K.SELECT_LINE))
        rscale(P.line, k)
    end

    -- Section sub-label (the WBP_SectionSubLabel look, painted): [an Aurebesh 18 LS 200 line, PILOT only] + the Moki
    -- label + a 6-su rule from the label's end + 12 to x1 on the label's baseline. An HBox: the rule fills what the
    -- label leaves (the rule's own SizeBox: a texture-less image ignores SetDesiredSizeOverride, live run 2026-10-10).
    local function newSub(card, cv, z, aure)
        local S = {}
        if aure then S.aure = newText(card, cv, RL.aure, z) end
        local hb = construct(WC.hbox)
        S.box = reg(card, { w = hb, s = onCanvas(cv, hb, z) })
        local t = construct(WC.text)
        pcall(function() t:SetTextTransformPolicy(2) end)
        boxAdd(hb, t, 0, 0, AL.c)
        S.t = reg(card, { w = t, t = t, role = RL.sub })
        local sb = construct(WC.size)
        pcall(function() sb:SetHeightOverride(STRIPE.rule) end)
        local s2 = hb:AddChildToHorizontalBox(sb)
        if U.ok(s2) then
            pcall(function() s2:SetSize({ Value = 1, SizeRule = 1 }) end)       -- FSlateChildSize Fill
            pcall(function() s2:SetVerticalAlignment(AL.b) end)
        end
        S.slot = s2
        local im = construct(WC.image)
        pcall(function() sb:AddChild(im) end)
        S.rule = reg(card, { w = im, i = im })
        return S
    end

    local function hideSub(S)
        if S.aure then vis(S.aure, false) end
        vis(S.box, false)
    end

    -- y = the label's cap top; aureY = the Aurebesh line's cap top (nil: none)
    local function sub(S, x, x1, y, label, size, col, aureY)
        if S.aure then
            if aureY then tput(S.aure, x, aureY, label, 18, col, "lt") else vis(S.aure, false) end
        end
        local fm = FM.display
        local e = em(size)
        rect(S.box, x, slotY(fm, size, y, "t"), max(0, x1 - x), fm.line * e)
        show(S.box, true)
        font(S.t, size); ink(S.t, col); text(S.t, label); show(S.t, true)
        local pb = rnd((fm.line - fm.base) * e)                -- the rule's bottom on the baseline
        if S.pb ~= pb and U.ok(S.slot) and pcall(function()
            S.slot:SetPadding({ Left = 12, Top = 0, Right = 0, Bottom = pb })
        end) then S.pb = pb end
        img(S.rule, TX.solid); tint(S.rule, col)
    end

    -- Ability / trait disc (§9.2): TILE disc (T_UI_CircleBig_Fill_Cmn) + ring (T_UI_CircleIconFrame_Cmn: BONE @0.5
    -- idle, GOLD crash, WHITE cursor) + glyph BEIGE 58 % [+ keyword sub-icon GOLD 34 % at the lower right, level dots
    -- BEIGE]; empty: the T_UI_AffixFrame outline BEIGE @0.38; the cursor: + 8 %.
    local function newDisc(card, cv, z, o)
        o = o or {}
        local D = { disc = newImage(card, cv, z), ring = newImage(card, cv, z + 1), glyph = newImage(card, cv, z + 1),
                    frame = newImage(card, cv, z + 1) }
        if o.sub then D.sub = newImage(card, cv, z + 2) end
        if o.dots then D.dots = { newImage(card, cv, z + 2), newImage(card, cv, z + 2), newImage(card, cv, z + 2) } end
        return D
    end

    local function hideDisc(D)
        vis(D.disc, false); vis(D.ring, false); vis(D.glyph, false); vis(D.frame, false)
        if D.sub then vis(D.sub, false) end
        if D.dots then for k = 1, 3 do vis(D.dots[k], false) end end
    end

    -- d = {glyph, sub, lvl, empty} or a glyph path; ringCol = the idle ring (nil: BONE @0.5); noDots = the crash slot
    local function disc(D, x, y, s, d, ringCol, cursor, noDots)
        d = type(d) == "table" and d or { glyph = d }
        local empty = d.empty == true or type(d.glyph) ~= "string"
        local ss = s * (cursor and 1.08 or 1)
        local x0, y0 = x + (s - ss) / 2, y + (s - ss) / 2
        rect(D.disc, x0, y0, ss, ss); img(D.disc, TX.disc); tint(D.disc, empty and K.TILE50 or COL.TILE)
        rect(D.ring, x0, y0, ss, ss)
        img(D.ring, TX.ring)
        tint(D.ring, cursor and COL.WHITE or (ringCol or K.RING_IDLE))
        local lv = (D.dots and not noDots and not empty) and clamp(floor(tonumber(d.lvl) or 0), 0, 3) or 0
        if empty then
            vis(D.glyph, false)
            local f = ss * 0.55
            rect(D.frame, x0 + (ss - f) / 2, y0 + (ss - f) / 2, f, f)
            img(D.frame, TX.affix)
            tint(D.frame, K.FRAME_EMPTY)
        else
            vis(D.frame, false)
            local gs = ss * 0.58
            local gy = y0 + (ss - gs) / 2 - ((lv > 0) and ss * 0.05 or 0)
            rect(D.glyph, x0 + (ss - gs) / 2, gy, gs, gs); img(D.glyph, d.glyph, TX.noAbil); tint(D.glyph, COL.BEIGE)
        end
        if D.sub then
            if not empty and type(d.sub) == "string" then
                local sz, r = ss * 0.34, ss / 2
                rect(D.sub, x0 + r + r * 0.62 - sz / 2, y0 + r + r * 0.55 - sz / 2, sz, sz)
                img(D.sub, d.sub); tint(D.sub, COL.GOLD)
            else
                vis(D.sub, false)
            end
        end
        if D.dots then
            local dot, step = max(6, rnd(ss * 0.1)), ss * 0.152
            for k = 1, 3 do
                if k <= lv then
                    local cx, cy = x0 + ss / 2 + (k - (lv + 1) / 2) * step, y0 + ss / 2 + ss * 0.34
                    rect(D.dots[k], cx - dot / 2, cy - dot / 2, dot, dot)
                    img(D.dots[k], TX.disc)
                    tint(D.dots[k], COL.BEIGE)
                else
                    vis(D.dots[k], false)
                end
            end
        end
    end

    -- Part tile (§9.2): the affix icon (T_UI_AFX_*_Icn, finished art, as is), rarity pips (T_UI_MetallicRarityPip_Icn
    -- AMBER 18 su, 22 su apart) 12 su under it; a flaw: a RUST bar 90 x 5 instead of the pips; an empty slot: the
    -- T_UI_AffixFrame outline BEIGE @0.38 (never a grey "+" square); the cursor: + 8 % (the WHITE ring is the board's
    -- shared one).
    local function newPart(card, cv, z)
        local p = { tile = newImage(card, cv, z), frame = newImage(card, cv, z), rust = newImage(card, cv, z), pips = {} }
        for k = 1, 4 do p.pips[k] = newImage(card, cv, z) end
        return p
    end

    local function hidePart(p)
        vis(p.tile, false); vis(p.frame, false); vis(p.rust, false)
        for k = 1, 4 do vis(p.pips[k], false) end
    end

    local function part(p, x, y, s, d, cursor)
        d = type(d) == "table" and d or { tile = d }
        local empty = d.empty == true or type(d.tile) ~= "string"
        local ss = s * (cursor and 1.08 or 1)
        local cx, cy = x + s / 2, y + s / 2
        if empty then
            vis(p.tile, false)
            local f = ss * 0.86
            rect(p.frame, cx - f / 2, cy - f / 2, f, f); img(p.frame, TX.affix); tint(p.frame, K.FRAME_EMPTY)
        else
            vis(p.frame, false)
            rect(p.tile, cx - ss / 2, cy - ss / 2, ss, ss); img(p.tile, d.tile, TX.noAffix); tint(p.tile, COL.WHITE)
        end
        local py = y + s + 12
        local n = (empty or d.faulty) and 0 or clamp(floor(tonumber(d.pips) or 0), 0, 4)
        for k = 1, 4 do
            if k <= n then
                local px = cx + (k - (n + 1) / 2) * 22
                rect(p.pips[k], px - 9, py - 9, 18, 18); img(p.pips[k], TX.pip); tint(p.pips[k], COL.AMBER)
            else
                vis(p.pips[k], false)
            end
        end
        if not empty and d.faulty then
            rect(p.rust, cx - 45, py - 2, 90, 5); img(p.rust, TX.solid); tint(p.rust, COL.RUST)
        else
            vis(p.rust, false)
        end
    end

    -- Tag ink of a hue: consts' C.COLOUR_INK for the player's own hue (INK; P4 WHITE), else by relative luminance
    -- (§2.2).
    local function tagInk(pnum, hue)
        hue = canon(hue)
        local k = tonumber(pnum)
        local own = k and C.COLOURS[k]
        local inkC = k and type(C.COLOUR_INK) == "table" and C.COLOUR_INK[k]
        if own and inkC and canon(own) == hue then return canon(inkC) end
        local lum = 0.2126 * hue.R + 0.7152 * hue.G + 0.0722 * hue.B
        return (lum < 0.22) and COL.WHITE or COL.INK
    end

    -- Squircle head shot: TILE squircle (T_UI_FE_TileButton_300_Fill_Cmn) + the M_UI_CharacterProfilePicture MID
    -- (plain: the head shot inset 7 % on T_UI_Squircle_A_Fill_Cmn) [roster: WHITE select ring, taken = black @0.75 +
    -- the holder's hue tag (Moki 27)].
    local function newThumb(card, cv, z, roster)
        local T = { fill = newImage(card, cv, z), head = newImage(card, cv, z) }
        T.head.head = true
        if roster then
            T.ring = newImage(card, cv, z + 1)
            T.dark = newImage(card, cv, z + 1)
            T.tag = newImage(card, cv, z + 2, { box = 0.5, size = 40 })
            T.tagT = newText(card, cv, RL.value, z + 3)
        end
        return T
    end

    local function hideThumb(T)
        for _, k in ipairs({ "fill", "head", "ring", "dark", "tag", "tagT" }) do if T[k] then vis(T[k], false) end end
    end

    -- o = {ring = the WHITE select ring, takenBy = pnum}
    local function thumb(T, x, y, s, path, o)
        o = o or {}
        local plainLook = X.look.thumb ~= "mid"
        rect(T.fill, x, y, s, s); img(T.fill, plainLook and TX.squircle or TX.tileFill); tint(T.fill, COL.TILE)
        local inset = plainLook and rnd(s * 0.07) or 0
        rect(T.head, x + inset, y + inset, s - 2 * inset, s - 2 * inset)
        img(T.head, path)
        if not T.ring then return end
        if o.ring then
            local m = rnd(s * 0.05)
            rect(T.ring, x - m, y - m, s + 2 * m, s + 2 * m); img(T.ring, TX.tileSel); tint(T.ring, COL.WHITE)
        else
            vis(T.ring, false)
        end
        local tk = tonumber(o.takenBy)
        local tc = tk and C.COLOURS[tk]
        if tc then
            rect(T.dark, x, y, s, s); img(T.dark, TX.tileFill); tint(T.dark, K.DARK75)
            local tw, th = rnd(s * 0.56), rnd(s * 0.32)
            local tx0, ty0 = x + (s - tw) / 2, y + s - th - rnd(s * 0.04)
            rect(T.tag, tx0, ty0, tw, th); material(T.tag, MT.currency); tint(T.tag, canon(tc))
            tput(T.tagT, tx0 + tw / 2, ty0 + th / 2, "P" .. tk, 27, tagInk(tk, tc), "cm")
        else
            vis(T.dark, false); vis(T.tag, false); vis(T.tagT, false)
        end
    end

    -- Check badge (C10, the WBP_Tile_Btn B_SelectedMark): MI_UI_Squircle_FE_EquipBacker CREAM (fallback
    -- T_UI_FE_TileButton_300_Fill_Cmn CREAM) + T_UI_Tick_Icn INK at 62 %.
    local function newCheck(card, cv, z)
        return { back = newImage(card, cv, z), tick = newImage(card, cv, z + 1) }
    end

    local function hideCheck(B) vis(B.back, false); vis(B.tick, false) end

    local function check(B, cx, cy, s)
        rect(B.back, cx - s / 2, cy - s / 2, s, s)
        if not material(B.back, MT.equip) then img(B.back, TX.tileFill) end
        tint(B.back, COL.CREAM)
        local k = s * 0.62
        rect(B.tick, cx - k / 2, cy - k / 2, k, k); img(B.tick, TX.tick); tint(B.tick, COL.INK)
    end

    -- Guarded text (the style name, §2.3): the size shrinks from size toward minSize to fit box (a layout decision on
    -- the estimated width, in half-su steps), the box widens up to boxMax before going under minSize, and the DownOnly
    -- ScaleBox takes up what the estimate missed. x = the left edge (h "l") or the right edge (h "r"); y by anchor v
    -- ("s" | "m").
    local function gput(e, x, y, s, size, minSize, col, box, boxMax, h, v)
        s = (s ~= nil) and tostring(s) or ""
        if s == "" then return vis(e, false) end
        minSize = min(minSize, size)
        local sz = size
        local est = textW(s, e.role, size)
        if est > box then sz = max(minSize, floor(size * box / est * 2) / 2) end
        local w = box
        local estSz = textW(s, e.role, sz)
        if estSz > box then w = min(max(box, boxMax or box), estSz) end
        local fm = FM[e.role.fk] or FM.display
        local lh = fm.line * em(sz)
        rect(e, (h == "r") and (x - w) or x, slotY(fm, sz, y, v or "s"), w, lh)
        font(e, sz); ink(e, col); text(e, s)
        e.box, e.lines, e.fitMax = w, nil, w * sz / minSize   -- under minSize only when even that does not fit
        queueFit(e)
        return show(e, true)
    end

    -- Value row (§9.2): no box idle; the label (rank BEIGE @0.75) at x + 30, the value (Moki) right-aligned at x + w -
    -- 30; the cursor: the shared focus pill (the caller), WHITE texts and T_UI_Arrow_B_Icn 28 su 16 su either side of
    -- the value (an HBox, so the arrows follow the value's real width).
    local function newValueRow(card, cv, z, label)
        local Rw = { label = newText(card, cv, RL.rank, z) }
        local hb = construct(WC.hbox)
        Rw.box = reg(card, { w = hb, s = onCanvas(cv, hb, z) })
        Rw.al = boxImage(card, hb, 0, 16)
        Rw.v = boxText(card, hb, RL.value, 0, 0, { label = label })
        Rw.ar = boxImage(card, hb, 16, 0, true)
        return Rw
    end

    local function hideValueRow(Rw) vis(Rw.label, false); vis(Rw.box, false) end

    local function valueRow(Rw, x, y, w, h, label, value, size, focused)
        local cy = y + h / 2
        tput(Rw.label, x + 30, cy, label, 27, focused and COL.WHITE or K.LABEL_IDLE, "lm")
        place(Rw.box, x + w - 30, cy, 1, 0.5); show(Rw.box, true)
        for _, a in ipairs({ Rw.al, Rw.ar }) do
            if focused then dsize(a, 28); img(a, TX.arrow); tint(a, COL.WHITE) else vis(a, false) end
        end
        value = tostring(value or "")
        font(Rw.v, size); ink(Rw.v, focused and COL.WHITE or COL.BEIGE); text(Rw.v, value); show(Rw.v, value ~= "")
        Rw.v.box = w - 60 - textW(label, RL.rank, 27) - 40 - 88    -- the arrows' room kept in both looks
        queueFit(Rw.v)
    end

    -- SIGNATURE chip (§9.4): AMBER @0.16 pill 60 tall + T_UI_Star_Icn 34 su + "SIGNATURE" 27 LS 300 AMBER (SizeBox 60 >
    -- Overlay [pill, HBox]: the chip is as wide as its text).
    local function newChip(card, cv, z)
        local sbx = construct(WC.size)
        pcall(function() sbx:SetHeightOverride(60) end)
        local ch = { box = reg(card, { w = sbx, s = onCanvas(cv, sbx, z) }) }
        local over = construct(WC.over)
        pcall(function() sbx:AddChild(over) end)
        local fill = construct(WC.image)
        overAdd(over, fill)
        ch.fill = reg(card, { w = fill, i = fill, brush = { drawAs = DRAW.box, margin = 0.5, w = 60, h = 60 } })
        local hb = construct(WC.hbox)
        overAdd(over, hb, AL.l, AL.c)
        ch.star = boxImage(card, hb, 19, 0)
        ch.t = boxText(card, hb, RL.sig, 11, 32)
        return ch
    end

    local function chip(ch, x, y, anchor)
        place(ch.box, x, y, (anchor == "r") and 1 or 0, 0); show(ch.box, true)
        material(ch.fill, MT.pill); tint(ch.fill, K.CHIP)
        dsize(ch.star, 34); img(ch.star, TX.star); tint(ch.star, COL.AMBER)
        font(ch.t, 27); ink(ch.t, COL.AMBER); text(ch.t, "SIGNATURE"); show(ch.t, true)
    end

    -- CHOOSE MODEL name pill: modelTileName on a #F4EFE7 pill @0.62 (current @0.95), 44 tall (SizeBox > Overlay).
    local function newNamePill(card, cv, z)
        local sbx = construct(WC.size)
        pcall(function() sbx:SetHeightOverride(44) end)
        local N = { box = reg(card, { w = sbx, s = onCanvas(cv, sbx, z) }) }
        local over = construct(WC.over)
        pcall(function() sbx:AddChild(over) end)
        local fill = construct(WC.image)
        overAdd(over, fill)
        N.fill = reg(card, { w = fill, i = fill, brush = { drawAs = DRAW.box, margin = 0.5, w = 44, h = 44 } })
        local t = construct(WC.text)
        pcall(function() t:SetTextTransformPolicy(2) end)
        overAdd(over, t, AL.c, AL.c, { Left = 18, Top = 0, Right = 18, Bottom = 0 })
        N.t = reg(card, { w = t, t = t, role = RL.tile, label = "model tile name" })
        return N
    end

    -- The poster of a card. PILOT carries vm.pilot.tile (§9.9); the other stages may carry vm.header.tile / vm.tile /
    -- their own; pods carry vm.pilot.figure = {full, crop}. Without a tile the static pilots.lua catalog decides (by
    -- the head shot, then the name): its tile, else (pods, SEBULBA) its full body + crop on the empty poster; without a
    -- catalog entry the 0.11.0 fields (pilot.full / crop, readyPanel.figure). -> {tile | nil, full | nil, crop}
    local catalog = nil
    local function catalogEntry(thumbPath, name)
        if catalog == nil then
            catalog = { byThumb = {}, byName = {} }
            local ok, P = pcall(U.mod, "pilots")
            if ok and type(P) == "table" and type(P.ALL) == "table" then
                for _, e in ipairs(P.ALL) do
                    if type(e) == "table" then
                        if e.thumb and not catalog.byThumb[e.thumb] then catalog.byThumb[e.thumb] = e end
                        if e.name and not catalog.byName[e.name] then catalog.byName[e.name] = e end
                        if e.baseName and not catalog.byName[e.baseName] then catalog.byName[e.baseName] = e end
                    end
                end
            end
        end
        return (thumbPath and catalog.byThumb[thumbPath]) or (name and catalog.byName[name]) or nil
    end

    local function posterOf(card, vm)
        local p, hd, rp = vm.pilot or {}, vm.header or {}, vm.readyPanel or {}
        local key = tostring(hd.thumb or hd.pilotName or p.name or "")
        local tile = p.tile or hd.tile or vm.tile or (vm.perks and vm.perks.tile) or rp.tile
        local full, crop = nil, nil
        local fig = p.figure or hd.figure or vm.figure
        if type(fig) == "table" then full, crop = fig.full, fig.crop end
        if type(tile) ~= "string" then
            local e = catalogEntry(hd.thumb, hd.pilotName or p.name)
            if e then
                tile = e.tile
                if not tile and type(full) ~= "string" then full, crop = e.full, e.crop end
            elseif type(full) ~= "string" then
                local old = (type(rp.figure) == "table") and rp.figure or p
                full, crop = old.full, old.crop
            end
        end
        if type(tile) ~= "string" and type(full) ~= "string" and card.poster and card.poster.key == key then
            return card.poster
        end
        local src = { tile = (type(tile) == "string") and tile or nil, full = (type(full) == "string") and full or nil,
                      crop = crop, key = key }
        card.poster = src
        return src
    end

    -- The name on the card: the Pod Tour suffix " · AGED" moves to the rank line (§9.7). -> name, rankTag
    local function pilotName(vm, name)
        name = tostring(name or (vm.header and vm.header.pilotName) or "")
        local tag = vm.rankTag
        local base, suffix = name:match("^(.-)%s*\194\183%s*(%u+)$")
        if base and suffix and (tag == nil or tag == suffix) and suffix == "AGED" then return base, suffix end
        return name, tag
    end

    -- The rank line's words: vm.rank when racers composed them (§9.9 extra), else view [· rankTag] · tail.
    local function rankText(vm, rankTag, tail)
        if type(vm.rank) == "string" and vm.rank ~= "" then return vm.rank end
        local parts = {}
        for _, s in ipairs({ vm.view, rankTag, tail }) do
            if type(s) == "string" and s ~= "" then parts[#parts + 1] = s end
        end
        return table.concat(parts, " \194\183 ")
    end

    -- A style icon: pod styles' icons are head shots (perkdata, RP6): the podracer class glyph instead (§9.3).
    local function styleIcon(path)
        if type(path) == "string" and path:find("Content/Characters/", 1, true) then return TX.plane end
        return path
    end

    -- The class glyph of the rail's VEHICLE disc: vm.classIcon (optional), else the RACERS step's class (St.racers.cls,
    -- a pure table), else the landspeeder.
    local function classIcon(vm)
        if type(vm.classIcon) == "string" then return vm.classIcon end
        local r = St.racers
        local c = type(r) == "table" and r.cls or nil
        if type(c) == "table" and type(c.icon) == "string" then return c.icon end
        return TX.car
    end

    -- Trait text with its GOLD keywords: the vm's rich, else perkdata's markup for that trait name (static data), else
    -- the plain description.
    local traitRich = nil
    local function traitText(d)
        if type(d.rich) == "string" and d.rich ~= "" then return d.rich end
        if traitRich == nil then
            traitRich = {}
            local ok, D = pcall(U.mod, "perkdata")
            if ok and type(D) == "table" and type(D.TRAITS) == "table" then
                for _, t in pairs(D.TRAITS) do
                    if type(t) == "table" and t.name and t.rich then traitRich[t.name] = t.rich end
                end
            end
        end
        return traitRich[d.name] or d.desc or ""
    end

    ---------------------------------------------------------------------------------------------------- art windows
    -- Art window (§9.1): clipping SizeBox > canvas > the poster (cover, ax 0.5 / ay per stage) [+ the pod figure on the
    -- empty poster] + the player stripe and its BAND_STRIPE gap band (scenario art only, VERIFY(V-FIN-06)).
    local function newArt(card, cv, z)
        local A = newClip(card, cv, z)
        A.art = newImage(card, A.cv, 0)
        A.fig = newImage(card, A.cv, 1)
        A.fig.fig = true
        A.gap = newImage(card, A.cv, 2)
        A.stripe = newImage(card, A.cv, 2)
        return A
    end

    -- A band of horizontal width bw whose bottom edge starts x0 su from the window's left, parallel to the art's own
    -- 56-deg stripes: a long FuseImage rotated about its centre (CardStripeAngle, default 34 = 90 - 56: UMG's angle
    -- turns clockwise on screen, so a vertical bar leans right like the poster's stripes; spec text: "-34", see the
    -- WI-07 report).
    local function band(e, x0, bw, ww, wh, col)
        local a = math.rad(STRIPE.angle)
        local thick = bw * math.sin(a)
        local len = wh / math.sin(a) + 2 * thick + 40
        local cx = x0 + bw / 2 + (wh / 2) / math.tan(a)
        rect(e, cx - thick / 2, wh / 2 - len / 2, thick, len)
        angle(e, num("CardStripeAngle", 90 - STRIPE.angle))
        img(e, TX.solid); tint(e, col)
    end

    local function stripes(A, ww, wh, cls, stage, hue)
        if opt("CardStripe", true) == false then vis(A.stripe, false); vis(A.gap, false); return end   -- the rule alone
        local from = (cls == "W" and stage == "perks") and STRIPE.fromRight.Wperks or STRIPE.fromRight[cls]
        local xb = ww - from
        band(A.stripe, xb, STRIPE.w, ww, wh, hue)
        band(A.gap, xb - STRIPE.gapOff, STRIPE.gap, ww, wh, COL.BAND_STRIPE)
    end

    -- Pod figure: the 1480 x 1800 body scaled so its crop box {u0, v0, u1, v1} (pilots.lua) takes 92 % of the window
    -- width / 94 % of its height, centred, feet on the floor (§9.3); in a PERKS strip (M / N) head and shoulders from
    -- the box top.
    local function figure(e, ww, wh, crop, path)
        local u0, v0, u1, v1 = 0, 0, 1, 1
        if type(crop) == "table" then
            u0 = tonumber(crop[1] or crop.u0) or 0
            v0 = tonumber(crop[2] or crop.v0) or 0
            u1 = tonumber(crop[3] or crop.u1) or 1
            v1 = tonumber(crop[4] or crop.v1) or 1
        end
        local cw, ch = max(0.01, u1 - u0) * SZ.bodyW, max(0.01, v1 - v0) * SZ.bodyH
        local s, x, y
        if wh < ww * 0.5 then
            s = min(0.92 * ww / cw, 2.4 * wh / ch)
            x, y = ww / 2 - (u0 + u1) / 2 * SZ.bodyW * s, 8 - v0 * SZ.bodyH * s
        else
            s = min(0.92 * ww / cw, 0.94 * wh / ch)
            x, y = ww / 2 - (u0 + u1) / 2 * SZ.bodyW * s, wh - v1 * SZ.bodyH * s
        end
        rect(e, x, y, SZ.bodyW * s, SZ.bodyH * s)
        img(e, path)
        tint(e, (X.look.fig == "mid") and COL.WHITE or K.FIG_PLAIN)
        figParams(e)
    end

    local function posterArt(A, r, src, cls, stage, hue)
        rect(A, r[1], r[2], r[3], r[4]); show(A, true)
        local ww, wh = r[3], r[4]
        local ay = ART_AY[cls] and ART_AY[cls][stage] or 0
        local k = max(ww / SZ.posterW, wh / SZ.posterH)
        local iw, ih = SZ.posterW * k, SZ.posterH * k
        rect(A.art, (ww - iw) * 0.5, (wh - ih) * ay, iw, ih)
        img(A.art, src.tile or TX.empty, src.tile and TX.empty or nil)   -- a missing poster keeps the empty one's stripes
        tint(A.art, COL.WHITE)
        if not src.tile and src.full then figure(A.fig, ww, wh, src.crop, src.full) else vis(A.fig, false) end
        stripes(A, ww, wh, cls, stage, hue)
    end

    -- The 6-su hue rule along the art / band edge: vertical (W PILOT / PERKS / READY) or horizontal (elsewhere).
    local function hueRule(e, r, vertical, hue)
        if vertical then rect(e, r[1] + r[3] - 3, r[2], 6, r[4]) else rect(e, r[1], r[2] + r[4] - 3, r[3], 6) end
        img(e, TX.solid); tint(e, hue)
    end

    -- Photo window (§9.4, §10): clipping SizeBox > canvas: a STUDIO fill, the class cut-out (the first build and the
    -- "cutout" rung), the vpreview render (cover of its 16:9 target, centred), the building wash (PAGE / BAND @0.43 by
    -- the backdrop rung, instead of the 0.11.0 brightness dim).
    local function newPhoto(card, cv, z)
        local A = newClip(card, cv, z)
        A.fill = newImage(card, A.cv, 0)
        A.cut = newFit(card, A.cv, 1)
        A.render = newImage(card, A.cv, 2)
        A.wash = newImage(card, A.cv, 3)
        return A
    end

    -- b = {brush, brushKind, dim, fallback, aspect, backdrop}; keep = re-render from a stored view model: the brush
    -- stays as the image holds it (GC rule). backdrop = the bay's rung (racers: vpreview.backdrop, the rung in use after a
    -- fall), else the configured PreviewBackdrop; the fill behind the cut-out is the rung's (STUDIO; scenario: PANEL, the
    -- teal of T_UI_Scenario_Bg).
    local function photo(A, r, b, keep)
        rect(A, r[1], r[2], r[3], r[4]); show(A, true)
        local ww, wh = r[3], r[4]
        local rung = b.backdrop or opt("PreviewBackdrop", "studio")
        rect(A.fill, 0, 0, ww, wh); img(A.fill, TX.solid)
        tint(A.fill, (rung == "scenario") and alpha(COL.PANEL, 1) or COL.STUDIO)
        local live
        if rung == "cutout" then
            if not keep then setRender(A.render, nil) end
            live = false
        elseif keep then
            live = A.render.held ~= nil
        else
            live = setRender(A.render, b.brush, b.brushKind)
        end
        if live then
            local asp = tonumber(b.aspect) or (num("SetupPreviewW", 960) / max(1, num("SetupPreviewH", 540)))
            local iw = max(ww, wh * asp)
            local ih = iw / asp
            rect(A.render, (ww - iw) / 2, (wh - ih) / 2, iw, ih)
            tint(A.render, COL.WHITE)
            show(A.render, true)
            vis(A.cut, false)
            local building = b.brushKind == "building" or (tonumber(b.dim) or 1) < 0.999
            if building then
                rect(A.wash, 0, 0, ww, wh); img(A.wash, TX.solid)
                tint(A.wash, (rung == "scenario") and K.WASH_BAND or K.WASH_PAGE)
            else
                vis(A.wash, false)
            end
        else
            vis(A.render, false)
            vis(A.wash, false)
            if type(b.fallback) == "string" then
                rect(A.cut, ww * 0.09, wh * 0.11, ww * 0.82, wh * 0.78); img(A.cut, b.fallback); tint(A.cut, COL.WHITE)
            else
                vis(A.cut, false)
            end
        end
    end

    return { newPill = newPill, hidePill = hidePill, pill = pill, newSub = newSub, hideSub = hideSub, sub = sub,
             newDisc = newDisc, hideDisc = hideDisc, disc = disc, newPart = newPart, hidePart = hidePart,
             part = part, tagInk = tagInk, newThumb = newThumb, hideThumb = hideThumb, thumb = thumb,
             newCheck = newCheck, hideCheck = hideCheck, check = check, gput = gput, newValueRow = newValueRow,
             hideValueRow = hideValueRow, valueRow = valueRow, newChip = newChip, chip = chip,
             newNamePill = newNamePill, posterOf = posterOf, pilotName = pilotName, rankText = rankText,
             styleIcon = styleIcon, classIcon = classIcon, traitText = traitText, newArt = newArt,
             posterArt = posterArt, hueRule = hueRule, newPhoto = newPhoto, photo = photo }
end)()
local newPill, pill, hidePill, newCheck, check, hideCheck, tagInk, classIcon = PARTS.newPill, PARTS.pill,
    PARTS.hidePill, PARTS.newCheck, PARTS.check, PARTS.hideCheck, PARTS.tagInk, PARTS.classIcon

---------------------------------------------------------------------------------------------------- card shell
local function buildShell(card)
    local sb = construct(WC.scale)
    pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
    card.box:AddChild(sb)                                 -- -> SizeBoxSlot
    local design = construct(WC.size)
    local ds = sb:AddChild(design)
    if U.ok(ds) then pcall(function() ds:SetHorizontalAlignment(AL.c); ds:SetVerticalAlignment(AL.t) end) end
    card.design = design
    local cv = construct(WC.canvas)
    design:AddChild(cv)
    card.cv = cv
    -- frame (§9.1): shadow, BAND (9-su RoundedBox), border on top of everything
    card.F = { shadow = newImage(card, cv, -5, { box = 0.5, size = 128 }), band = newImage(card, cv, -4, { rounded = 9 }),
               border = newImage(card, cv, 40, { box = 0.5, size = 128 }) }
    -- stage rail: 4 discs [fill, ring, glyph, visited dot + tick], the rail cursor's pill and WHITE ring
    card.railPill = newPill(card, cv, 9)
    card.rail = {}
    for k = 1, 4 do
        card.rail[k] = { fill = newImage(card, cv, 10), ring = newImage(card, cv, 11), glyph = newImage(card, cv, 12),
                         dot = newImage(card, cv, 13), tick = newImage(card, cv, 14) }
    end
    card.railRing = newImage(card, cv, 12)
    -- P-tag (tight shadow, CurrencyBacker in the hue, "P1"), READY badge, rank line
    card.tag = { shadow = newImage(card, cv, 9, { box = 0.5, size = 48 }),
                 back = newImage(card, cv, 10, { box = 0.5, size = 40 }), text = newText(card, cv, RL.value, 11) }
    card.badge = newCheck(card, cv, 10)
    card.rank = newText(card, cv, RL.rank, 10, { label = "rank line" })
    -- hint line: [glyph][glyph][verb] x 3, right-aligned at (w - pad, 1266); the toast replaces it
    local hb = construct(WC.hbox)
    card.hint = reg(card, { w = hb, s = onCanvas(cv, hb, 10), label = "hint line" })
    card.hints = {}
    for k = 1, 3 do
        local eb = construct(WC.hbox)
        boxAdd(hb, eb, (k > 1) and HINT.gap or 0, 0)
        pcall(function() eb:SetVisibility(VIS.Collapsed) end)
        local ent = { box = reg(card, { w = eb }), g = {} }
        ent.g[1] = boxImage(card, eb, 0, 0)
        ent.g[2] = boxImage(card, eb, 2, 0)
        ent.t = boxText(card, eb, RL.hint, 5, 0)
        card.hints[k] = ent
    end
    local over = construct(WC.over)
    card.toast = reg(card, { w = over, s = onCanvas(cv, over, 12) })
    local fill = construct(WC.image)
    overAdd(over, fill)
    card.toastFill = reg(card, { w = fill, i = fill, brush = { drawAs = DRAW.box, margin = 0.5, w = 66, h = 66 } })
    local t = construct(WC.text)
    pcall(function() t:SetTextTransformPolicy(2) end)
    pcall(function() t:SetJustification(JUST.c) end)      -- a wrapped toast keeps both lines centred
    overAdd(over, t, AL.c, AL.c, { Left = 36, Top = 6, Right = 36, Bottom = 6 })
    card.toastT = reg(card, { w = t, t = t, role = RL.status, label = "toast" })
end

-- The design box follows the width class (the ScaleBox maps it onto the card box).
local function shellLayout(card)
    local w = (CARD[X.cls] or CARD.W).w
    if card.dw == w or not card.design then return end
    if pcall(function() card.design:SetWidthOverride(w); card.design:SetHeightOverride(CH) end) then card.dw = w end
end

local function renderFrame(card, vm, cls)
    local F, cw = card.F, CARD[cls].w
    rect(F.shadow, -30, -30 + 12, cw + 60, CH + 60); material(F.shadow, MT.shadow); tint(F.shadow, K.SHADOW34)
    rect(F.band, 0, 0, cw, CH); img(F.band, TX.solid); tint(F.band, COL.BAND)
    rect(F.border, 0, 0, cw, CH); img(F.border, TX.stroke); tint(F.border, COL.BORDER)
end

local function stageGlyph(key, vm)
    if key == "pilot" then return TX.player end
    if key == "vehicle" then return classIcon(vm) end
    if key == "perks" then return TX.kit end
    return TX.event
end

-- Stage rail (§9.1): 4 discs at (pad, 40) on the art: current BEIGE + TILE @0.9 ring + INK glyph (118 / 110 / 104 su),
-- others TILE @0.92 + BONE @0.35 ring + BONE glyph (upcoming @0.45); visited: a GOLD dot 30 su + BAND_STRIPE tick at
-- the disc's lower right. The rail cursor (the strip row): a NEAR @0.55 pill behind the rail + a WHITE ring on the
-- current disc. Replaces the 4 text tabs.
local function renderRail(card, vm, cls)
    local R, pad = RAIL[cls], CARD[cls].pad
    local st = vm.strip or {}
    local stages = type(st.stages) == "table" and st.stages or STAGES
    local n = min(4, count(stages, 4))
    local cur = clamp(floor(tonumber(st.current) or 1), 1, max(1, n))
    local cy = 40 + R.cur / 2
    local x, curX = pad, nil
    for k = 1, 4 do
        local D = card.rail[k]
        if k > n then
            vis(D.fill, false); vis(D.ring, false); vis(D.glyph, false); vis(D.dot, false); vis(D.tick, false)
        else
            local isCur = k == cur
            local d = isCur and R.cur or R.disc
            local cx = x + d / 2
            if isCur then curX = cx end
            rect(D.fill, cx - d / 2, cy - d / 2, d, d); img(D.fill, TX.disc)
            tint(D.fill, isCur and COL.BEIGE or K.TILE92)
            rect(D.ring, cx - d / 2, cy - d / 2, d, d); img(D.ring, TX.ring)
            tint(D.ring, isCur and K.RAIL_CUR_RING or K.RAIL_RING)
            local g = d * 0.56
            rect(D.glyph, cx - g / 2, cy - g / 2, g, g); img(D.glyph, stageGlyph(stages[k], vm))
            tint(D.glyph, isCur and COL.INK or ((k < cur) and COL.BONE or K.BONE45))
            if k < cur then
                local dx, dy = cx + d / 2 * 0.72, cy + d / 2 * 0.72
                rect(D.dot, dx - 15, dy - 15, 30, 30); img(D.dot, TX.disc); tint(D.dot, COL.GOLD)
                rect(D.tick, dx - 10, dy - 10, 20, 20); img(D.tick, TX.tick); tint(D.tick, COL.BAND_STRIPE)
            else
                vis(D.dot, false); vis(D.tick, false)
            end
            x = x + d + R.gap
        end
    end
    if st.cursor == true and n > 0 and curX then
        local tot = (n - 1) * R.disc + R.cur + (n - 1) * R.gap
        pill(card.railPill, pad - 14, cy - R.cur / 2 - 12, tot + 28, R.cur + 24, "flat", K.NEAR55)
        local s = R.cur * 1.06 + 9
        rect(card.railRing, curX - s / 2, cy - s / 2, s, s); img(card.railRing, TX.ring); tint(card.railRing, COL.WHITE)
    else
        hidePill(card.railPill); vis(card.railRing, false)
    end
end

-- P-tag (§9.1): always the card's top-right (x = w - pad - w_tag, y = 40 + (current disc - h) / 2); READY badge 16 su
-- left of it on the READY stage (replaces the rotated neon stamp).
local function renderTag(card, vm, cls)
    local g, cw, pad = PTAG[cls], CARD[cls].w, CARD[cls].pad
    local hue = canon(vm.colour or C.COLOURS.Remote)
    local x, y = cw - pad - g.w, 40 + (RAIL[cls].cur - g.h) / 2
    local T = card.tag
    rect(T.shadow, x - 6, y - 2, g.w + 12, g.h + 12); material(T.shadow, MT.shadow); tint(T.shadow, K.TAG_SHADOW)
    rect(T.back, x, y, g.w, g.h)
    if not material(T.back, MT.currency) then img(T.back, TX.solid) end   -- the 9-su box without its material
    tint(T.back, hue)
    tput(T.text, x + g.w / 2, y + g.h / 2, "P" .. tostring(vm.pnum or "?"), g.f, tagInk(vm.pnum, hue), "cm")
    if vm.stage == "ready" or vm.ready == true then
        check(card.badge, x - 16 - g.h / 2, y + g.h / 2, g.h)
    else
        hideCheck(card.badge)
    end
end

-- Hint line (§9.1): per entry 1-2 pad glyphs (T_UI_Cntrl_XB_*_Icn 40 su BEIGE, d-pad pairs 2 su apart) + the verb
-- (hint role, sentence case), right-aligned at (w - pad, 1266), at most HINT.max[cls] entries; no pill. CardGlyphs =
-- "text" writes the keys as ASCII words. The toast (CHAR pill + Moki 30 STATUS, centred on the line) replaces it; a
-- toast wider than the card's text box wraps to a 2nd line (integration 0.12.0, rule 7: "TRAITS FROM BRAWLER · FLAME
-- VENT" is 1027 su in N's 692) and the pill grows upward from the line (its bottom stays inside the card).
local function renderHint(card, vm, cls)
    local cw, pad = CARD[cls].w, CARD[cls].pad
    local toast = vm.toast
    if type(toast) == "string" and toast ~= "" then
        local box = cw - 2 * pad - 72
        local lineH = FM.display.line * em(30)
        place(card.toast, cw / 2, HINT.y + (lineH + 12) / 2, 0.5, 1); show(card.toast, true)
        material(card.toastFill, MT.pill); tint(card.toastFill, COL.CHAR)
        font(card.toastT, 30); ink(card.toastT, COL.STATUS); wrap(card.toastT, box); text(card.toastT, toast)
        show(card.toastT, true)
        local T = card.toastT
        T.box, T.lines, T.lastH, T.pitch, T.fitMax = box, 2, lineH, lineH, nil
        queueFit(T)
        return vis(card.hint, false)
    end
    vis(card.toast, false)
    local hint = type(vm.hint) == "table" and vm.hint or {}
    local n = min(HINT.max[cls] or 3, count(hint, 6))
    if n == 0 then return vis(card.hint, false) end
    place(card.hint, cw - pad, HINT.y, 1, 0.5); show(card.hint, true)
    local textMode = X.look.glyphs == "text"
    local all = {}
    for k = 1, 3 do
        local ent, h = card.hints[k], (k <= n) and hint[k] or nil
        if type(h) ~= "table" then
            vis(ent.box, false)
        else
            show(ent.box, true)
            local glyphs = type(h.glyphs) == "table" and h.glyphs or {}
            local words = {}
            for gi = 1, 2 do
                local key, ge = glyphs[gi], ent.g[gi]
                local path = (key ~= nil and not textMode) and TH.glyph(key) or nil
                if path then dsize(ge, HINT.glyph); img(ge, path); tint(ge, COL.BEIGE) else vis(ge, false) end
                if key ~= nil and textMode then words[#words + 1] = GLYPH_TEXT[key] or tostring(key) end
            end
            local label = sentence(h.text)
            if #words > 0 then label = table.concat(words, "/") .. " " .. label end
            font(ent.t, HINT.font); ink(ent.t, COL.BEIGE); text(ent.t, label); show(ent.t, label ~= "")
            all[#all + 1] = label
        end
    end
    -- the line's room: the band column on W PILOT / PERKS / READY, else the card less its pads
    local st = vm.stage
    local art = (cls == "W" and st ~= "vehicle") and ART.W[st] or nil
    card.hint.box = art and (cw - pad - art[3] - 24) or (cw - 2 * pad)
    card.hint.c.s = table.concat(all, " | ")
    card.hint.fitDirty = card.hint.fitDirty or card.hint.c.hs ~= card.hint.c.s
    card.hint.c.hs = card.hint.c.s
    queueFit(card.hint)
end

local function applyRank(card)
    local r = card.rankWant
    if r and type(r.s) == "string" and r.s ~= "" then
        tput(card.rank, r.x, r.y, r.s, 27, K.RANK, "lt", r.box)
    else
        vis(card.rank, false)
    end
end

---------------------------------------------------------------------------------------------------- error block (§8.2)
local ERR_LINES = 7

local function liveryOf(v)
    if type(v.livery) == "string" and v.livery ~= "" then return v.livery end
    local s = type(v.liveryRow) == "string" and v.liveryRow:match("^LIVERY:%s*(.-)%s*$") or nil
    return (s and s ~= "") and s or "STANDARD"
end

local function errLines(vm)
    local out = {}
    local function add(s) if type(s) == "string" and s ~= "" then out[#out + 1] = s end end
    vm = type(vm) == "table" and vm or {}
    local hd, v, p, r = vm.header or {}, vm.vehicle or {}, vm.perks or {}, vm.readyPanel or {}
    add(string.format("P%s \194\183 %s", tostring(vm.pnum or "?"), tostring(hd.pilotName or "")))
    add("STAGE: " .. (STAGE_LABEL[vm.stage] or "?") .. (vm.ready and " \194\183 READY" or ""))
    if next(v) then add("MODEL: " .. tostring(v.model or "?")); add("LIVERY: " .. liveryOf(v)) end
    add(p.kitLabel or p.kitRow)
    add(r.totals or (type(p.power) == "string" and p.power or nil))
    return out
end

local function ensureErr(card)
    if card.err then return card.err end
    local cv = card.cv
    local E = { bg = newImage(card, cv, 30), title = newText(card, cv, RL.value, 31), lines = {} }
    for k = 1, ERR_LINES do E.lines[k] = newText(card, cv, RL.err, 31) end
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
    local cw = (CARD[X.cls] or CARD.W).w
    local y0, h = full and 0 or 200, full and CH or 1000
    rect(E.bg, 0, y0, cw, h); img(E.bg, TX.solid); tint(E.bg, COL.BAND)
    tput(E.title, 48, y0 + 48, "RACER CARD ERROR", 40, COL.RUST, "lt")
    local ls = errLines(vm)
    for k = 1, ERR_LINES do tput(E.lines[k], 48, y0 + 140 + (k - 1) * 64, ls[k], 28, COL.BEIGE, "lt") end
end

---------------------------------------------------------------------------------------------------- stages
-- The four stage panels, one closure (the main chunk's 200-locals limit): BUILD[stage](card, cv) -> panel,
-- RENDER[stage](card, panel, vm, cls, keep), buildPicker(card, perksPanel).
local BUILD, RENDER, buildPicker = (function()
    local newSub, hideSub, sub, newDisc, hideDisc, disc, newPart, hidePart, part,
        newThumb, hideThumb, thumb, gput, newValueRow, hideValueRow, valueRow, newChip, chip,
        newNamePill, posterOf, pilotName, rankText, styleIcon, traitText, newArt, posterArt, hueRule,
        newPhoto, photo =
        PARTS.newSub, PARTS.hideSub, PARTS.sub, PARTS.newDisc, PARTS.hideDisc, PARTS.disc,
        PARTS.newPart, PARTS.hidePart, PARTS.part, PARTS.newThumb, PARTS.hideThumb, PARTS.thumb,
        PARTS.gput, PARTS.newValueRow, PARTS.hideValueRow, PARTS.valueRow, PARTS.newChip, PARTS.chip,
        PARTS.newNamePill, PARTS.posterOf, PARTS.pilotName, PARTS.rankText, PARTS.styleIcon, PARTS.traitText,
        PARTS.newArt, PARTS.posterArt, PARTS.hueRule, PARTS.newPhoto, PARTS.photo

    ---------------------------------------------------------------------------------------------------- PILOT (§9.3)
    local function buildPilot(card, cv)
        local P = { cv = cv }
        P.art = newArt(card, cv, 0)
        P.fade = newImage(card, cv, 2)
        P.rule = newImage(card, cv, 3)
        P.name = newText(card, cv, RL.name, 4, { wrap = PIL.W.name.wrap, lineH = LH.name, label = "pilot name" })
        P.sub = newSub(card, cv, 4, true)
        P.sq = newImage(card, cv, 4)
        P.icon = newImage(card, cv, 5)
        P.style = newGuarded(card, cv, RL.style, 5, "l", "style name")
        P.own = newText(card, cv, RL.rank, 4, { label = "own style" })
        P.desc = newRich(card, cv, 4, { wrap = PIL.W.col.w, lineH = LH.body46, pitch = 46, label = "style description" })
        P.tr = {}
        for k = 1, 3 do
            P.tr[k] = { panel = newImage(card, cv, 4, { box = 0.5, size = 64 }), glyph = newImage(card, cv, 5),
                        title = newText(card, cv, RL.trait, 5, { label = "trait title" }),
                        body = newRich(card, cv, 5, { wrap = PIL.W.col.w - 48, lineH = LH.body44, pitch = 44,
                                                      label = "trait body" }) }
        end
        P.sub2 = newSub(card, cv, 4, true)
        P.star = newImage(card, cv, 5)
        P.sig = newText(card, cv, RL.sig, 5, { wrap = PIL.W.sig.wrap, lineH = LH.caps, label = "signature" })
        P.tiles = {}
        for k = 1, ROSTER.W do P.tiles[k] = newThumb(card, cv, 6, true) end
        P.al, P.ar = newImage(card, cv, 6), newImage(card, cv, 6, { flip = true })
        return P
    end

    -- "SIGNATURE · ARZ 41" (or the 0.11.0 "SIGNATURE LANDSPEEDER · ORCA", re-worded) / "ANY LANDSPEEDER". -> text,
    -- isSig, model
    local function sigInfo(p)
        if type(p.signatureModel) == "string" and p.signatureModel ~= "" then
            return "SIGNATURE \194\183 " .. p.signatureModel, true, p.signatureModel
        end
        local s = tostring(p.signature or "")
        if s:find("^SIGNATURE") then
            local model = s:match(".*\194\183%s*(.-)%s*$")
            if model and model ~= "" then return "SIGNATURE \194\183 " .. model, true, model end
            return s, true, nil
        end
        return s, false, nil
    end

    -- W PILOT / READY: the name on the poster (cardName 69, WrapTextAt 692, 2 lines, last baseline 1236, grows upward)
    -- over the BAND_STRIPE fade (0, 840, 820, 460), the rank line 64 su above the name block. A single word wider than
    -- 692 at 69 (QUADINAROS 815 su: a line cannot break inside it) takes the role's next size, 55.5 (656 su), V-FIN-09.
    local function nameOnPoster(card, S, name, rank, ar)
        local g, pad = PIL.W.name, CARD.W.pad
        rect(S.fade, ar[1], 840, ar[3], 460); img(S.fade, TX.fade); tint(S.fade, K.FADE)
        local size = g.size
        for word in tostring(name or ""):gmatch("%S+") do
            if textW(word, RL.name, size) > g.wrap then size = 55.5; break end
        end
        -- 0.12.0 (live 2026-10-10): the breaks are ours. Slate wrapped "KATJA MOX" at WrapTextAt 692 where the estimate
        -- said one line, and the second line grew over the rank line. Now the estimate breaks the name, the text takes
        -- explicit "\n" breaks with Slate's own wrap off, and the rank is placed for exactly those lines; a line a little
        -- wider than estimated still ends inside the art window (pad + 692 = 756 of 820, box = the window).
        local broken, n = breakLines(name, RL.name, size, g.wrap, g.lines)   -- box 748 = 692 x TEXT_MARGIN
        wrap(S.name, 0)
        tput(S.name, pad, g.base, broken, size, COL.WHITE, "lb", ar[3] - pad - 8, g.lines)
        local e = em(size)
        local top = g.base - (n - 1) * FM.display.line * e * LH.name - FM.display.cap * e
        card.rankWant = { x = pad, y = top - PIL.W.rankGap, s = rank, box = ar[3] - 2 * pad }
    end

    -- Roster strip (§9.3): a window of the class's tile count around the current pilot (the vm's list is in display
    -- order, centred on the current one and wrapping); the current tile larger with the WHITE ring while the cursor is
    -- on the roster, arrows 30 su BEIGE at both ends; taken pilots dimmed with the holder's tag.
    local function renderRoster(P, p, r, nMax, x0, width)
        local list = type(p.roster) == "table" and p.roster or {}
        local nList = count(list, 32)
        local m = min(nMax, nList)
        local cur = nil
        for k = 1, nList do if type(list[k]) == "table" and list[k].current then cur = k; break end end
        cur = cur or floor((nList + 1) / 2)
        local start = clamp(cur - floor((m - 1) / 2), 1, max(1, nList - m + 1))
        local total = 0
        for k = 1, m do total = total + ((start + k - 1 == cur) and r.cur or r.oth) end
        total = total + max(0, m - 1) * r.gap
        local x = x0 + (width - total) / 2
        local xs = x
        local cursor = p.cursor == true
        for k = 1, #P.tiles do
            local T = P.tiles[k]
            local e = (k <= m) and list[start + k - 1] or nil
            if type(e) ~= "table" then
                hideThumb(T)
            else
                local isCur = start + k - 1 == cur
                local s = isCur and r.cur or r.oth
                thumb(T, x, r.y + (r.cur - s) / 2, s, e.thumb, { ring = isCur and cursor, takenBy = e.takenBy })
                x = x + s + r.gap
            end
        end
        if cursor and m > 0 then
            local ay = r.y + r.cur / 2 - 15
            rect(P.al, xs - 34, ay, 30, 30); img(P.al, TX.arrow); tint(P.al, COL.BEIGE)
            rect(P.ar, xs + total + 4, ay, 30, 30); img(P.ar, TX.arrow); tint(P.ar, COL.BEIGE)
        else
            vis(P.al, false); vis(P.ar, false)
        end
    end

    -- W style column (x 876-1698): RACER STYLE sub-label (y 52, the rule ends at 1508 before the tag); squircle 120
    -- (SAGE @0.2) + the style icon BEIGE; the style name (Moki 45 GOLD, DownOnly min 33, max width 488); PILOT'S OWN
    -- STYLE; the description (only when it takes <= 2 lines and the stack still ends above y 1000); TRAITS + 3 panels
    -- (height 74 + 44 x body lines, gap 12); the signature (y 1010, 2 lines); the roster (7 tiles at y 1090).
    local function pilotColumn(card, P, p)
        local g = PIL.W
        local x, cw = g.col.x, g.col.w
        sub(P.sub, x, g.subEnd, g.sub + 30, "RACER STYLE", 30, COL.SAGE, g.sub)
        rect(P.sq, g.sq[1], g.sq[2], g.sq[3], g.sq[3]); img(P.sq, TX.tileFill); tint(P.sq, K.SAGE20)
        local is = g.sq[3] * 0.7
        rect(P.icon, g.sq[1] + (g.sq[3] - is) / 2, g.sq[2] + (g.sq[3] - is) / 2, is, is)
        img(P.icon, styleIcon(p.styleIcon)); tint(P.icon, COL.BEIGE)
        local S = g.style
        gput(P.style, S.x, S.base, p.styleName, S.size, S.min, COL.GOLD, S.w, S.wMax, "l", "s")
        tput(P.own, S.x, g.own, "PILOT'S OWN STYLE", 27, COL.SAGE, "ls", S.wMax)
        local T = g.tr
        local traits = type(p.traits) == "table" and p.traits or {}
        local bw = cw - 48
        local hs, total, nT = {}, 0, 0
        for k = 1, 3 do
            local d = traits[k]
            if type(d) == "table" then
                hs[k] = T.base + T.pitch * max(1, lines(plain(traitText(d)), RL.body, 30, bw))
                total, nT = total + hs[k], nT + 1
            end
        end
        local stack = T.label + total + T.gap * max(0, nT - 1)
        local y = g.desc.y
        local desc = (type(p.styleDesc) == "string") and p.styleDesc or ""
        local dl = (desc ~= "") and lines(plain(desc), RL.body, 30, cw) or 0
        if dl > 0 and dl <= g.desc.lines and y + dl * 46 + 20 + stack <= g.desc.stop then
            rput(P.desc, x, y, desc, cw, g.desc.lines)
            y = y + dl * 46 + 20
        else
            vis(P.desc, false)
        end
        if nT > 0 then sub(P.sub2, x, x + cw, y + 30, "TRAITS", 30, COL.SAGE, y) else hideSub(P.sub2) end
        local ty = y + T.label
        for k = 1, 3 do
            local R, d = P.tr[k], traits[k]
            vis(R.glyph, false)
            if type(d) ~= "table" then
                vis(R.panel, false); vis(R.title, false); vis(R.body, false)
            else
                rect(R.panel, x, ty, cw, hs[k]); material(R.panel, MT.stroke); tint(R.panel, K.PANEL05)
                R.title.ls = 240
                tput(R.title, x + 24, ty + T.title, d.name, 28.5, COL.SAGE, "lt", bw)
                rput(R.body, x + 24, ty + T.body, traitText(d), bw, T.lines)
                ty = ty + hs[k] + T.gap
            end
        end
        local s, isSig = sigInfo(p)
        vis(P.star, false)
        wrap(P.sig, g.sig.wrap)
        tput(P.sig, x, g.sig.y, s, 27, isSig and COL.AMBER or K.SIG_ANY, "lt", g.sig.wrap, g.sig.lines)
        renderRoster(P, p, g.roster, ROSTER.W, x, cw)
    end

    -- M / N band under the poster: style line (icon 60 / 52 GOLD + name Moki 39 / 36, min 33 / 30), 3 trait lines
    -- (keyword glyph 34 SAGE + traitTitle LS 240 / 200), the signature (N: the star glyph + the model name), the
    -- roster.
    local function pilotBand(card, P, p, cls)
        local g, cw, pad = PIL[cls], CARD[cls].w, CARD[cls].pad
        hideSub(P.sub); hideSub(P.sub2); vis(P.sq, false); vis(P.own, false); vis(P.desc, false)
        local S = g.style
        rect(P.icon, pad, S.y, S.icon, S.icon); img(P.icon, styleIcon(p.styleIcon)); tint(P.icon, COL.GOLD)
        local sx = pad + S.icon + 16
        gput(P.style, sx, S.y + S.icon / 2, p.styleName, S.size, S.min, COL.GOLD, cw - pad - sx, nil, "l", "m")
        local traits = type(p.traits) == "table" and p.traits or {}
        for k = 1, 3 do
            local R, d = P.tr[k], traits[k]
            vis(R.panel, false); vis(R.body, false)
            if type(d) ~= "table" then
                vis(R.glyph, false); vis(R.title, false)
            else
                local y = g.traits.y + (k - 1) * g.traits.pitch
                rect(R.glyph, pad + 1, y + 1, 34, 34); img(R.glyph, d.icon); tint(R.glyph, K.SAGE90)
                R.title.ls = g.traits.ls
                tput(R.title, pad + 52, y + 18, d.name, 28.5, COL.SAGE, "lm", cw - pad - (pad + 52))
            end
        end
        local s, isSig, model = sigInfo(p)
        wrap(P.sig, 0)
        if g.sig.star and isSig and model then
            local st = g.sig.star
            local cy = g.sig.y + FM.body.cap * em(27) / 2
            rect(P.star, pad, cy - st / 2, st, st); img(P.star, TX.star); tint(P.star, COL.AMBER)
            tput(P.sig, pad + st + 10, g.sig.y, model, 27, COL.AMBER, "lt", cw - 2 * pad - st - 10)
        else
            vis(P.star, false)
            tput(P.sig, pad, g.sig.y, s, 27, isSig and COL.AMBER or K.SIG_ANY, "lt", cw - 2 * pad)
        end
        renderRoster(P, p, g.roster, ROSTER[cls], 0, cw)
    end

    local function renderPilot(card, P, vm, cls)
        local p = vm.pilot or {}
        local cw, pad = CARD[cls].w, CARD[cls].pad
        local hue = canon(vm.colour or C.COLOURS.Remote)
        local ar = ART[cls].pilot
        posterArt(P.art, ar, posterOf(card, vm), cls, "pilot", hue)
        hueRule(P.rule, ar, cls == "W", hue)
        local name, rankTag = pilotName(vm, p.name)
        local rank = rankText(vm, rankTag, (type(p.counter) == "string" and p.counter ~= "") and p.counter or nil)
        if cls == "W" then
            nameOnPoster(card, P, name, rank, ar)
            pilotColumn(card, P, p)
        else
            local g = PIL[cls]
            vis(P.fade, false)
            wrap(P.name, 0)
            tput(P.name, pad, g.name.base, name, g.name.size, COL.WHITE, "ls", cw - 2 * pad)
            card.rankWant = { x = pad, y = g.rank, s = rank, box = cw - 2 * pad }
            pilotBand(card, P, p, cls)
        end
    end

    ---------------------------------------------------------------------------------------------------- VEHICLE (§9.4)
    local function buildVehicle(card, cv)
        local V = { cv = cv }
        V.photo = newPhoto(card, cv, 0)
        V.rule = newImage(card, cv, 3)
        V.badge = newImage(card, cv, 4)
        V.codeBg = newImage(card, cv, 4)
        V.code = newText(card, cv, RL.value, 5, { label = "badge code" })
        V.focus = newPill(card, cv, 3)                        -- the cursor pill (title row / livery row)
        V.tiles = {}
        for k = 1, 6 do
            V.tiles[k] = { fill = newImage(card, cv, 4), badge = newImage(card, cv, 5),
                           code = newText(card, cv, RL.value, 5, { label = "model tile code" }),
                           name = newNamePill(card, cv, 5) }
        end
        V.ring = newImage(card, cv, 6)
        V.check = newCheck(card, cv, 7)
        V.al, V.ar = newImage(card, cv, 6), newImage(card, cv, 6, { flip = true })
        V.caption = newText(card, cv, RL.value, 5, { label = "model caption" })
        V.title = newText(card, cv, RL.model, 5, { wrap = VEH.N.titleFit, lineH = LH.model, justify = "c",
                                                    label = "model title" })
        V.tal, V.tar = newImage(card, cv, 6), newImage(card, cv, 6, { flip = true })
        V.livery = newValueRow(card, cv, 5, "livery")
        V.head = newThumb(card, cv, 5, false)
        V.dlab = newText(card, cv, RL.rank, 5)
        V.dname = newText(card, cv, RL.value, 5, { label = "driven by" })
        V.chip = newChip(card, cv, 5)
        V.info = newText(card, cv, RL.info, 5, { wrap = VEH.W.info[3], lineH = LH.caps, label = "info line" })
        return V
    end

    local function hideModels(V)
        for _, T in ipairs(V.tiles) do
            vis(T.fill, false); vis(T.badge, false); vis(T.code, false); vis(T.name.box, false)
        end
        vis(V.ring, false); hideCheck(V.check); vis(V.al, false); vis(V.ar, false); vis(V.caption, false)
    end

    -- CHOOSE MODEL row (graft 4, the garage's own row): n tiles of 120 at the class pitch, centred on the card.
    -- Current: CREAM squircle + the badge inset 10 + the check badge 44 su at its lower right, the WHITE ring and
    -- arrows 30 su at both ends while the cursor is on MODEL; others: TILE @0.92 + the badge tinted #9E9E9E; no badge:
    -- the 3-letter code (Moki 42, smaller until it fits); names on #F4EFE7 pills 14 su under the tiles. A name wider
    -- than the pitch (pod names): no names under the tiles (codes only where a model has no emblem) and one caption
    -- line with the current model's full name (Moki 33 BEIGE). The spec's
    -- "pitch - 12" is read as pitch - 10: JAKOBEAST measures 217.2 su against M's 228 and §9.7 says the speeder names
    -- fit.
    local function modelRow(V, g, list, cursor, cw, pad, current)
        local n = min(#V.tiles, count(list, 12))
        local pitch, tile, y = g.pitch, g.tile, g.y
        local total = n * pitch
        local xs = (cw - total) / 2
        local codes = false
        for k = 1, n do
            local m = list[k]
            if type(m) == "table" and textW(m.name, RL.tile, 30) > pitch - 10 then codes = true end
        end
        local curName, curSeen = nil, false
        for k = 1, #V.tiles do
            local Tl = V.tiles[k]
            local m = (k <= n) and list[k] or nil
            if type(m) ~= "table" then
                vis(Tl.fill, false); vis(Tl.badge, false); vis(Tl.code, false); vis(Tl.name.box, false)
            else
                local cur = m.current == true
                local cx = xs + (k - 1) * pitch + pitch / 2
                local tx = cx - tile / 2
                rect(Tl.fill, tx, y, tile, tile)
                img(Tl.fill, TX.tileFill)
                tint(Tl.fill, cur and COL.CREAM or K.TILE92)
                -- 0.12.0: the emblem stays in codes mode (live 2026-10-10: one long name in the window dropped every
                -- emblem of the row, so the row's look flipped while scrolling); the code is for a model without one
                local badge = type(m.badge) == "string" and m.badge or nil
                if badge then
                    rect(Tl.badge, tx + 10, y + 10, tile - 20, tile - 20); img(Tl.badge, badge)
                    tint(Tl.badge, cur and COL.WHITE or K.BADGE_IDLE)
                    vis(Tl.code, false)
                else
                    vis(Tl.badge, false)
                    local code = (type(m.code) == "string" and m.code ~= "") and m.code
                        or string.sub(tostring(m.name or "?"), 1, 3)
                    -- 0.12.0: Moki 42 drew the codes ~150 su wide on 120-su tiles (live 2026-10-10): the size steps
                    -- down until the code fits the tile with a 12-su margin each side
                    local cs = 42
                    while cs > 24 and textW(code, Tl.code.role, cs) * TEXT_MARGIN > tile - 24 do cs = cs - 3 end
                    tput(Tl.code, cx, y + tile / 2, code, cs, cur and COL.INK or COL.CREAM, "cm", tile - 12)
                end
                if codes then
                    vis(Tl.name.box, false)
                else
                    local N = Tl.name
                    place(N.box, cx, y + tile + 14, 0.5, 0); show(N.box, true)
                    material(N.fill, MT.pill); tint(N.fill, cur and K.NAME_PILL_CUR or K.NAME_PILL)
                    font(N.t, 30); ink(N.t, K.NAME_INK); text(N.t, tostring(m.name or "")); show(N.t, true)
                    N.t.box = pitch - 12
                    queueFit(N.t)
                end
                if cur then
                    curSeen, curName = true, m.name
                    check(V.check, tx + tile - 16, y + tile - 16, 44)
                    if cursor then
                        rect(V.ring, tx - 6, y - 6, tile + 12, tile + 12)
                        img(V.ring, TX.tileSel)
                        tint(V.ring, COL.WHITE)
                    end
                end
            end
        end
        if not curSeen then hideCheck(V.check) end
        if not (curSeen and cursor) then vis(V.ring, false) end
        if cursor and n > 0 then
            local ay = y + tile / 2 - 15
            rect(V.al, xs - 20, ay, 30, 30); img(V.al, TX.arrow); tint(V.al, COL.WHITE)
            rect(V.ar, xs + total - 10, ay, 30, 30); img(V.ar, TX.arrow); tint(V.ar, COL.WHITE)
        else
            vis(V.al, false); vis(V.ar, false)
        end
        if codes then
            tput(V.caption, cw / 2, y + tile + 14 + 22, current or curName, 33, COL.BEIGE, "cm", cw - 2 * pad)
        else
            vis(V.caption, false)
        end
    end

    -- Title row (N (24, 580, 812, 104); the W / M fallback without a models window): Moki 45 on one line, or 2 lines at
    -- 36 when the name does not fit (N 596 su: the pod names); the cursor: the focus pill (the caller) + arrows (inset
    -- 22).
    local function titleRow(V, r, name, cursor, fit)
        local x, y, w, h = r[1], r[2], r[3], r[4]
        if cursor then
            local cy = y + h / 2
            rect(V.tal, x + 22, cy - 14, 28, 28); img(V.tal, TX.arrow); tint(V.tal, COL.WHITE)
            rect(V.tar, x + w - 50, cy - 14, 28, 28); img(V.tar, TX.arrow); tint(V.tar, COL.WHITE)
        else
            vis(V.tal, false); vis(V.tar, false)
        end
        name = tostring(name or "")
        fit = fit or (w - 2 * 22 - 2 * 28 - 2 * 18)
        if textW(name, RL.model, 45) <= fit then
            wrap(V.title, 0)
            tput(V.title, x + w / 2, y + h / 2, name, 45, COL.WHITE, "cm", fit)
        else
            wrap(V.title, fit)
            tput(V.title, x + w / 2, y + h / 2, name, 36, COL.WHITE, "cc", fit, 2)
        end
    end

    local function renderVehicle(card, V, vm, cls, keep)
        local v = vm.vehicle or {}
        local g, cw, pad = VEH[cls], CARD[cls].w, CARD[cls].pad
        local hue = canon(vm.colour or C.COLOURS.Remote)
        photo(V.photo, g.photo, { brush = v.brush, brushKind = v.brushKind, dim = v.dim, fallback = v.fallback,
                                  aspect = v.aspect, backdrop = v.backdrop }, keep)
        hueRule(V.rule, g.photo, false, hue)
        -- manufacturer badge on the photo; no badge (ANTAGONIST, pods but MYTH): the code on a TILE squircle
        local bx, by, bs = g.badge[1], g.badge[2], g.badge[3]
        if type(v.badge) == "string" then
            rect(V.badge, bx, by, bs, bs); img(V.badge, v.badge); tint(V.badge, COL.WHITE)
            vis(V.codeBg, false); vis(V.code, false)
        elseif type(v.code) == "string" and v.code ~= "" then
            vis(V.badge, false)
            rect(V.codeBg, bx, by, bs, bs); img(V.codeBg, TX.tileFill); tint(V.codeBg, K.TILE92)
            tput(V.code, bx + bs / 2, by + bs / 2, v.code, g.codeF, COL.CREAM, "cm", bs)
        else
            vis(V.badge, false); vis(V.codeBg, false); vis(V.code, false)
        end
        -- rank line "TOP · MODEL 1 / 13" (N drops MODEL when the line passes 764 su)
        local counter = (type(v.counter) == "string" and v.counter ~= "") and v.counter or nil
        local rank = rankText(vm, nil, counter and ("MODEL " .. counter) or nil)
        if g.dropModel and textW(rank, RL.rank, 27) > g.dropModel then rank = (rank:gsub("MODEL ", "", 1)) end
        card.rankWant = { x = g.rank[1], y = g.rank[2], s = rank, box = cw - 2 * pad }
        -- MODEL: the CHOOSE MODEL row (W / M) or the title row (N; W / M without vm.vehicle.models)
        local cursor = tonumber(v.cursor) or 0
        local focus = nil
        local list = (type(v.models) == "table" and count(v.models, 12) > 0) and v.models or nil
        if g.models and list then
            vis(V.title, false); vis(V.tal, false); vis(V.tar, false)
            modelRow(V, g.models, list, cursor == 1, cw, pad, v.model)
        else
            hideModels(V)
            titleRow(V, g.title, v.model, cursor == 1, g.titleFit)
            if cursor == 1 then focus = g.title end
        end
        local L = g.livery
        valueRow(V.livery, L[1], L[2], L[3], L[4], "LIVERY", liveryOf(v), g.liveryF, cursor == 2)
        if cursor == 2 then focus = L end
        if focus then pill(V.focus, focus[1], focus[2], focus[3], focus[4], "focus") else hidePill(V.focus) end
        -- DRIVEN BY: head squircle 96 + "DRIVEN BY" (rank SAGE) + the pilot (Moki 33 BEIGE)
        local dr = type(v.driver) == "table" and v.driver or {}
        local dx, dy, ds = g.driver[1], g.driver[2], g.driver[3]
        local dname = pilotName(vm, dr.name)
        if cls == "W" then                                -- TEEMTO PAGALIES 544 su at Moki 33 > the 480 of x 1218-1698
            dx = max(L[1] + L[3] + 16, min(dx, cw - pad - ds - 22 - textW(dname, RL.value, 33)))
        end
        if dr.thumb or dr.name then
            if dr.thumb then thumb(V.head, dx, dy, ds, dr.thumb) else hideThumb(V.head) end
            tput(V.dlab, dx + ds + 22, dy + 16, "DRIVEN BY", 27, COL.SAGE, "lt")
            tput(V.dname, dx + ds + 22, dy + ds - 12, dname, 33, COL.BEIGE, "ls", cw - pad - (dx + ds + 22))
        else
            hideThumb(V.head); vis(V.dlab, false); vis(V.dname, false)
        end
        if v.signature then chip(V.chip, g.chip[1], g.chip[2], g.chip[3]) else vis(V.chip.box, false) end
        local I = g.info
        wrap(V.info, I[3])
        tput(V.info, I[1], I[2], v.info, 27, COL.SAGE, "lt", I[3], I[4])
    end

    ---------------------------------------------------------------------------------------------------- PERKS (§9.5)
    local function buildPerks(card, cv)
        local B = { cv = cv, card = card }
        B.art = newArt(card, cv, 0)
        B.rule = newImage(card, cv, 3)
        B.focus = newPill(card, cv, 3)                        -- the cursor pill (KIT, upgrade rows, STYLE, picker rows)
        B.kit = { pill = newPill(card, cv, 3), label = newText(card, cv, RL.value, 5, { label = "kit label" }),
                  al = newImage(card, cv, 5), ar = newImage(card, cv, 5, { flip = true }) }
        B.totP = newText(card, cv, RL.value, 5, { label = "power total" })
        B.totE = newText(card, cv, RL.rank, 5, { label = "energy total" })
        B.subs = { ab = newSub(card, cv, 4), parts = newSub(card, cv, 4), power = newSub(card, cv, 4),
                   up = newSub(card, cv, 4) }
        B.pow = { value = newText(card, cv, RL.value, 5, { label = "power" }),
                  track = newImage(card, cv, 4, { box = 0.5, size = 18 }),
                  fill = newImage(card, cv, 5, { box = 0.5, size = 18 }),
                  energy = newText(card, cv, RL.rank, 5, { label = "energy" }) }
        B.cells = {}
        for key in pairs(DIAMOND) do B.cells[key] = newDisc(card, cv, 5, { sub = true, dots = true }) end
        B.parts = {}
        for k = 1, 6 do B.parts[k] = newPart(card, cv, 5) end
        B.pring = newImage(card, cv, 7)                       -- the part cursor's WHITE squircle ring
        B.ups = {}
        for k = 0, 5 do
            B.ups[k] = { glyph = newImage(card, cv, 5), name = newText(card, cv, RL.pick, 5, { label = "upgrade name" }),
                         track = newImage(card, cv, 4, { box = 0.5, size = 18 }),
                         fill = newImage(card, cv, 5, { box = 0.5, size = 18 }), digit = newText(card, cv, RL.value, 5) }
        end
        B.style = { pill = newPill(card, cv, 3), icon = newImage(card, cv, 5),
                    name = newGuarded(card, cv, RL.style, 5, "l", "style chip"),
                    al = newImage(card, cv, 6), ar = newImage(card, cv, 6, { flip = true }) }
        B.traits = {}
        for k = 1, 3 do B.traits[k] = newDisc(card, cv, 5) end
        B.det = { shadow = newImage(card, cv, 8, { box = 0.5, size = 128 }),
                  frame = newImage(card, cv, 8, { rounded = 15 }),
                  panel = newImage(card, cv, 9, { box = 0.5, size = 64 }), icon = newImage(card, cv, 10),
                  tag = newText(card, cv, RL.tag, 10, { lineH = LH.caps, pitch = 44, label = "detail tag" }),
                  title = newText(card, cv, RL.trait, 10, { wrap = 878, lineH = LH.title44, pitch = 44,
                                                            label = "detail title" }),
                  body = newRich(card, cv, 10, { wrap = 878, lineH = LH.body46, pitch = 46, label = "detail body" }) }
        return B
    end

    -- The picker (§9.5): category pill + up to PICKER_ROWS.M rows (one page: W / M 7, N 5).
    local function buildPicker(card, B)
        local cv = B.cv
        local P = { cat = newPill(card, cv, 4), al = newImage(card, cv, 6), ar = newImage(card, cv, 6, { flip = true }),
                    glyph = newImage(card, cv, 6), name = newText(card, cv, RL.value, 6, { label = "picker group" }),
                    cnt = newText(card, cv, RL.rank, 6), rows = {}, top = 0 }
        for k = 1, PICK_ROWS.M do
            local R = { icon = newImage(card, cv, 6), frame = newImage(card, cv, 6), tick = newImage(card, cv, 6),
                        rust = newImage(card, cv, 6), pips = {},
                        name = newText(card, cv, RL.pick, 6, { wrap = 0, lineH = LH.pick, pitch = 38,
                                                               label = "picker row" }) }
            for j = 1, 4 do R.pips[j] = newImage(card, cv, 6) end
            P.rows[k] = R
        end
        B.pick = P
    end

    local function perkNumbers(p)
        local pv = tonumber(p.powerValue) or ((type(p.power) == "number") and p.power or nil)
        local pm = tonumber(p.powerMax) or 60
        if not pv and type(p.power) == "string" then
            local a, b = p.power:match("(%d+)%s*/%s*(%d+)")
            pv, pm = tonumber(a), tonumber(b) or pm
        end
        local ev = tonumber(p.energyValue) or ((type(p.energy) == "number") and p.energy or nil)
        if not ev and type(p.energy) == "string" then ev = tonumber(p.energy:match("(%d+)%s*$")) end
        return pv or 0, max(1, pm), ev or 0
    end

    -- KIT row label: the kit label ("SURVIVOR KIT" / "CUSTOM KIT"; 0.11.0: kitRow without "LOADOUT: "); when it does
    -- not fit the focused row (row - 132) " KIT" goes (N's BRAWLER · FLAME VENT, §9.7), then the part after the first "
    -- · " ("MAX POWER · CUSTOM ORD PEDROVIA" -> "MAX POWER": the detail card's title keeps the whole name), then whole
    -- trailing words with an ellipsis (the §6.3 cut rule).
    local function kitLabelOf(p, avail)
        local label = p.kitLabel
        if type(label) ~= "string" or label == "" then label = (tostring(p.kitRow or ""):gsub("^LOADOUT:%s*", "")) end
        if textW(label, RL.value, 30) <= avail then return label end
        local s = (type(p.kitLabelShort) == "string" and p.kitLabelShort ~= "") and p.kitLabelShort
            or (label:gsub(" KIT$", ""))
        if textW(s, RL.value, 30) <= avail then return s end
        s = s:match("^(.-) \194\183 ") or s
        if textW(s, RL.value, 30) <= avail then return s end
        return cutWords(s, RL.value, 30, avail)
    end

    -- Bar (§2.4): two MI_UI_Tab images, PETROL track and AMBER fill (width = the fraction), full round.
    local function bar(track, fill, x, y, w, h, frac)
        bsize(track, h, h); rect(track, x, y, w, h); material(track, MT.tab); tint(track, COL.PETROL)
        frac = clamp(tonumber(frac) or 0, 0, 1)
        if frac > 0 then
            bsize(fill, h, h); rect(fill, x, y, max(h, w * frac), h); material(fill, MT.tab); tint(fill, COL.AMBER)
        else
            vis(fill, false)
        end
    end

    local function hideUp(u)
        for _, k in ipairs({ "glyph", "name", "track", "fill", "digit" }) do vis(u[k], false) end
    end

    -- Upgrade row (§9.2): stat glyph 34 su, the name (W only, 300-su column), the bar from x + 350 (W) / x + 62, the
    -- digit Moki 30 CREAM at the right; the cursor's pill (x - 14, y, w + 28, pitch - 6) is the board's shared one.
    local function upgradeRow(u, x, y, w, pitch, d, isCur, names)
        local cy = y + (pitch - 6) / 2
        rect(u.glyph, x + 1, cy - 17, 34, 34); img(u.glyph, d.icon); tint(u.glyph, isCur and COL.WHITE or COL.BEIGE)
        local barX
        if names then
            tput(u.name, x + 50, cy, d.name, 28.5, isCur and COL.WHITE or COL.BEIGE, "lm", 300)
            barX = x + 350
        else
            vis(u.name, false)
            barX = x + 62
        end
        local lv = clamp(floor(tonumber(d.level) or 0), 0, 10)
        bar(u.track, u.fill, barX, cy - 9, max(60, w - (barX - x) - 74), 18, lv / 10)
        tput(u.digit, x + w - 8, cy, tostring(lv), 30, COL.CREAM, "rm")
    end

    local function hideBoard(B)
        for _, S in pairs(B.subs) do hideSub(S) end
        vis(B.pow.value, false); vis(B.pow.track, false); vis(B.pow.fill, false); vis(B.pow.energy, false)
        for _, c in pairs(B.cells) do hideDisc(c) end
        for k = 1, #B.parts do hidePart(B.parts[k]) end
        vis(B.pring, false)
        for k = 0, 5 do hideUp(B.ups[k]) end
        hidePill(B.style.pill); vis(B.style.icon, false); vis(B.style.name, false)
        vis(B.style.al, false); vis(B.style.ar, false)
        for k = 1, #B.traits do hideDisc(B.traits[k]) end
    end

    -- The HUD-shaped board: sub-labels (subLabel 27 SAGE + rule), the ability diamond in d-pad order (crash in the
    -- centre, GOLD ring), the parts grid (3 x 2; more slots: more columns in the same span), the POWER block (W / M),
    -- the upgrades (W one named column; M / N 2 columns, column-major), STYLE pill + 3 trait discs. Returns the cursor
    -- rect of the shared focus pill (upgrade row / STYLE) or nil.
    local function renderBoard(card, B, p, g, cls, cur, pv, pm, ev)
        local x0, iw = g.x0, g.iw
        local D, Pg = g.dia, g.parts
        local focus = nil
        local partsEnd = g.power and (Pg[1] + 2 * Pg[4] + Pg[3]) or (x0 + iw)
        sub(B.subs.ab, x0, Pg[1] - 36, g.sub, "ABILITIES", 27, COL.SAGE)
        sub(B.subs.parts, Pg[1], partsEnd, g.sub, tostring(p.partsLabel or "PARTS"), 27, COL.SAGE)
        if g.power then
            sub(B.subs.power, g.power[1], g.power[1] + g.power[3], g.sub, "POWER", 27, COL.SAGE)
        else
            hideSub(B.subs.power)
        end
        sub(B.subs.up, x0, x0 + iw, g.upsub, "UPGRADES", 27, COL.SAGE)
        local ab = type(p.ab) == "table" and p.ab or {}
        for key, pos in pairs(DIAMOND) do
            local d = (key == "crash") and ab.crash or ab[tonumber(string.sub(key, 3))]
            disc(B.cells[key], D[1] + pos[1] * D[4], D[2] + pos[2] * D[4], D[3], d, (key == "crash") and COL.GOLD or nil,
                cur == key, key == "crash")
        end
        local parts = type(p.parts) == "table" and p.parts or {}
        local n = count(parts, 10)
        local cols = max(3, math.ceil(n / 2))
        local tile, px = Pg[3], Pg[4]
        if cols > 3 then
            px = (2 * Pg[4] + Pg[3]) / cols
            tile = min(Pg[3], floor(px - 16))
        end
        for k = #B.parts + 1, n do B.parts[k] = newPart(card, B.cv, 5) end
        local ringOn = false
        for k = 1, #B.parts do
            if k <= n then
                local c, r = (k - 1) % cols, floor((k - 1) / cols)
                local x, y = Pg[1] + c * px, Pg[2] + r * Pg[5]
                local isCur = cur == ("part" .. k)
                part(B.parts[k], x, y, tile, parts[k], isCur)
                if isCur then
                    local rs = tile * 1.08 + 12
                    rect(B.pring, x + tile / 2 - rs / 2, y + tile / 2 - rs / 2, rs, rs); img(B.pring, TX.tileSel)
                    tint(B.pring, COL.WHITE)
                    ringOn = true
                end
            else
                hidePart(B.parts[k])
            end
        end
        if not ringOn then vis(B.pring, false) end
        if g.power then
            local bx, by, bw = g.power[1], g.power[2], g.power[3]
            local pvs = string.format("%d / %d", pv, pm)
            tput(B.pow.value, bx, by + 66, pvs, (textW(pvs, RL.value, 54) <= bw + 2) and 54 or 48, COL.CREAM, "ls", bw)
            bar(B.pow.track, B.pow.fill, bx, by + 92, bw, 18, pv / pm)
            tput(B.pow.energy, bx, by + 160, "ENERGY " .. ev, 27, COL.SAGE, "ls", bw)
        else
            vis(B.pow.value, false); vis(B.pow.track, false); vis(B.pow.fill, false); vis(B.pow.energy, false)
        end
        local Ug = g.up
        local tune = type(p.tune) == "table" and p.tune or {}
        local colw = (Ug.cols > 1) and (iw - 48) / 2 or iw
        for j = 0, 5 do
            local c, r = 0, j
            if Ug.cols > 1 then c, r = floor(j / 3), j % 3 end
            local x, y = x0 + c * (colw + 48), Ug.y + r * Ug.pitch
            local d = tune[j]
            if type(d) == "table" then
                local isCur = cur == ("tun" .. j)
                upgradeRow(B.ups[j], x, y, colw, Ug.pitch, d, isCur, Ug.names)
                if isCur then focus = { x - 14, y, colw + 28, Ug.pitch - 6 } end
            else
                hideUp(B.ups[j])
            end
        end
        -- STYLE pill (330 / N 300 x 66; wider for a long style name, as long as the 3 trait discs still fit the board)
        -- + 3 trait discs 70 su, gap 16. Focused (§9.2 selector): WHITE arrows at both ends, inset 22; the left one in
        -- the icon's place, the right one in a padding the pill keeps in both looks (nothing moves with the cursor).
        local st = type(p.style) == "table" and p.style or {}
        local traits = type(p.traits) == "table" and p.traits or {}
        local nt = count(traits, 4)
        local sx, sy = x0 - 12, g.style
        local cap = max(g.styleW, (x0 + iw) - sx - 18 - (max(3, nt) - 1) * 86 - 70)   -- the discs' real span
        local sname = cutWords(st.name, RL.style, 27, (cap - 138) / TEXT_MARGIN)  -- N pods: VULPTEREEN 327 (§6.3 cut)
        local sw = clamp(rnd(80 + textW(sname, RL.style, 27) * TEXT_MARGIN + 58), g.styleW, cap)
        local onStyle = cur == "style"
        if onStyle then
            focus = { sx, sy, sw, 66 }
            hidePill(B.style.pill)
        else
            pill(B.style.pill, sx, sy, sw, 66, "select")
        end
        if onStyle then
            vis(B.style.icon, false)
            rect(B.style.al, sx + 22, sy + 19, 28, 28); img(B.style.al, TX.arrow); tint(B.style.al, COL.WHITE)
            rect(B.style.ar, sx + sw - 50, sy + 19, 28, 28); img(B.style.ar, TX.arrow); tint(B.style.ar, COL.WHITE)
        else
            vis(B.style.al, false); vis(B.style.ar, false)
            if type(st.icon) == "string" then
                rect(B.style.icon, sx + 22, sy + 11, 44, 44)
                img(B.style.icon, styleIcon(st.icon))
                tint(B.style.icon, COL.GOLD)
            else
                vis(B.style.icon, false)
            end
        end
        gput(B.style.name, sx + 80, sy + 33, sname, 27, 27, onStyle and COL.WHITE or COL.BEIGE, sw - 138, nil, "l", "m")
        for k = #B.traits + 1, nt do B.traits[k] = newDisc(card, B.cv, 5) end
        local tx = sx + sw + 18
        for k = 1, #B.traits do
            if k <= nt then
                local d = traits[k]
                d = type(d) == "table" and d or {}
                disc(B.traits[k], tx + (k - 1) * 86, sy - 2, 70, { glyph = d.icon, empty = d.empty }, nil,
                    cur == ("trait" .. k))
            else
                hideDisc(B.traits[k])
            end
        end
        return focus
    end

    -- Detail card (§9.5): icon (96 / 96 / 80) + a sub-panel (x0 + icon + 20, width iw - icon - 20): the short tag line
    -- (AMBER 27 LS 200, one line), the title (traitTitle LS 240, up to 2 lines), the body (the DT_RichText_Body look,
    -- GOLD keywords, pitch 46). Height from the text: 22 + 44 + 44 x title lines + 46 x body lines + 14. Normal top =
    -- y0; when the text needs more room than y0 .. 1232 the card rises (top = 1232 - height), drawn above the board on
    -- an opaque DETAIL_RISE sub-panel inside a BAND frame that also covers the icon column, with a soft shadow. Nothing
    -- is cut.
    local function renderDetail(B, g, d, y0)
        local Dt = B.det
        d = type(d) == "table" and d or {}
        local title = tostring(d.title or "")
        local body = tostring(d.rich or d.plain or "")
        local tag = tostring(d.tag or "")
        if title == "" and plain(body) == "" and tag == "" then
            for _, e in ipairs({ Dt.shadow, Dt.frame, Dt.panel, Dt.icon, Dt.tag, Dt.title, Dt.body }) do vis(e, false) end
            return
        end
        local isz = g.detail.icon
        local x, w = g.x0 + isz + 20, g.iw - isz - 20
        local tw = w - 48
        -- 0.12.0: the tag's breaks are ours (nameOnPoster's reason): the panel is sized for exactly these lines
        local tagB, ng = "", 0
        if tag ~= "" then tagB, ng = breakLines(tag, RL.tag, 27, tw / TEXT_MARGIN, 3) end
        local nt = (title ~= "") and lines(title, RL.trait, 28.5, tw) or 0
        local nb = (plain(body) ~= "") and lines(plain(body), RL.body, 30, tw) or 0
        local h = 22 + 44 * ng + 44 * nt + 46 * nb + 14
        local top = (y0 + h <= DETAIL_BOTTOM) and y0 or (DETAIL_BOTTOM - h)
        if top < y0 then
            local ox, oy, ow, oh = g.x0 - 12, top - 12, g.iw + 24, h + 24
            rect(Dt.shadow, ox - 30, oy - 20, ow + 60, oh + 60)
            material(Dt.shadow, MT.shadow)
            tint(Dt.shadow, K.SHADOW45)
            rect(Dt.frame, ox, oy, ow, oh); img(Dt.frame, TX.solid); tint(Dt.frame, COL.BAND)
            rect(Dt.panel, x, top, w, h); material(Dt.panel, MT.stroke); tint(Dt.panel, COL.DETAIL_RISE)
        else
            vis(Dt.shadow, false); vis(Dt.frame, false)
            rect(Dt.panel, x, top, w, h); material(Dt.panel, MT.stroke); tint(Dt.panel, K.PANEL05)
        end
        -- icon: a part's affix tile as is; ability / trait / stat / style glyphs BEIGE (pod head shots: the plane
        -- glyph)
        if type(d.icon) == "string" then
            local path = styleIcon(d.icon)
            local glyph = (d.iconKind or "tile") ~= "tile" or path ~= d.icon
            rect(Dt.icon, g.x0, top, isz, isz); img(Dt.icon, path); tint(Dt.icon, glyph and COL.BEIGE or COL.WHITE)
        else
            vis(Dt.icon, false)
        end
        local cy = top + 22
        if tag ~= "" then
            wrap(Dt.tag, 0)
            tput(Dt.tag, x + 24, cy, tagB, 27, COL.AMBER, "lt", tw, ng)
            cy = cy + 44 * ng
        else
            vis(Dt.tag, false)
        end
        if title ~= "" then
            wrap(Dt.title, tw)
            Dt.title.ls = 240
            tput(Dt.title, x + 24, cy, title, 28.5, COL.SAGE, "lt", tw, 2)
            cy = cy + 44 * nt
        else
            vis(Dt.title, false)
        end
        rput(Dt.body, x + 24, cy, body, tw, max(1, nb))
    end

    local function hidePicker(P)
        if not P then return end
        hidePill(P.cat); vis(P.al, false); vis(P.ar, false); vis(P.glyph, false); vis(P.name, false); vis(P.cnt, false)
        for _, R in ipairs(P.rows) do
            vis(R.icon, false); vis(R.frame, false); vis(R.tick, false); vis(R.rust, false); vis(R.name, false)
            for j = 1, 4 do vis(R.pips[j], false) end
        end
    end

    -- Picker row (§9.2): icon 56 (a part tile as is; ability / trait / style glyphs BEIGE; EMPTY / NONE: the AffixFrame
    -- outline), the name (traitTitle face without tracking, 28.5; N on 2 lines), rarity pips (AMBER 18) / level dots
    -- (BEIGE) / a flaw's RUST bar, the CREAM tick on the equipped item.
    local function pickRow(R, x0, iw, cy, d, isCur, namew, two)
        local empty = d.empty == true or d.id == false
        if empty or type(d.icon) ~= "string" then
            vis(R.icon, false)
            local f = 46
            rect(R.frame, x0 + 28 - f / 2, cy - f / 2, f, f); img(R.frame, TX.affix); tint(R.frame, K.FRAME_EMPTY)
        else
            vis(R.frame, false)
            local path = styleIcon(d.icon)
            local tileArt = (d.iconKind or "tile") == "tile" and path == d.icon
            local s = tileArt and 56 or 46
            rect(R.icon, x0 + 28 - s / 2, cy - s / 2, s, s)
            img(R.icon, path)
            tint(R.icon, tileArt and COL.WHITE or COL.BEIGE)
        end
        wrap(R.name, two and namew or 0)
        tput(R.name, x0 + 76, cy, d.name or (empty and "EMPTY" or ""), 28.5, isCur and COL.WHITE or COL.BEIGE,
            two and "lc" or "lm", namew, two and 2 or nil)
        local n, tex, col, size, step = 0, TX.pip, COL.AMBER, 18, 22
        if not empty and not d.faulty then
            if d.pips then
                n = clamp(floor(tonumber(d.pips) or 0), 0, 4)
            elseif d.lvl then
                n, tex, col, size, step = clamp(floor(tonumber(d.lvl) or 0), 0, 3), TX.disc, COL.BEIGE, 12, 20
            end
        end
        for j = 1, 4 do
            local e = R.pips[j]
            if j <= n then
                local cx = x0 + iw - 150 + (j - 1) * step
                rect(e, cx - size / 2, cy - size / 2, size, size); img(e, tex); tint(e, col)
            else
                vis(e, false)
            end
        end
        if not empty and d.faulty then
            rect(R.rust, x0 + iw - 159, cy - 2, 90, 5); img(R.rust, TX.solid); tint(R.rust, COL.RUST)
        else
            vis(R.rust, false)
        end
        if d.equipped then
            rect(R.tick, x0 + iw - 37, cy - 17, 34, 34); img(R.tick, TX.tick); tint(R.tick, COL.CREAM)
        else
            vis(R.tick, false)
        end
    end

    -- Picker (§9.5, replaces the board from pick.y down to the detail): the category pill (x0 - 24, pick.y, iw + 48,
    -- 76: idle selector + BEIGE arrows; on the category row the focus look), category glyph GOLD 38, the group name
    -- Moki 27, the counter (rank SAGE, right); rows from pick.y + 96, paged around the cursor (or from picker.top).
    -- Returns the focus rect and the rows' end (the detail card goes 24 su under it).
    local function renderPicker(B, g, pk, cls)
        local G, P = g.pick, B.pick
        local x0, iw = g.x0, g.iw
        local cursor = tonumber(pk.cursor) or 0
        local bx, by, bw, bh = x0 - 24, G.y, iw + 48, 76
        local focus = nil
        local onCat = cursor == 0
        if onCat then focus = { bx, by, bw, bh }; hidePill(P.cat) else pill(P.cat, bx, by, bw, bh, "select") end
        local cy = by + bh / 2
        local acol = onCat and COL.WHITE or COL.BEIGE
        rect(P.al, bx + 26, cy - 14, 28, 28); img(P.al, TX.arrow); tint(P.al, acol)
        rect(P.ar, bx + bw - 54, cy - 14, 28, 28); img(P.ar, TX.arrow); tint(P.ar, acol)
        if type(pk.catIcon) == "string" then
            rect(P.glyph, bx + 71, cy - 19, 38, 38); img(P.glyph, styleIcon(pk.catIcon)); tint(P.glyph, COL.GOLD)
        else
            vis(P.glyph, false)
        end
        local room = bw - 70 - textW(pk.counter, RL.rank, 27) - 24 - 122
        local cname = tostring(pk.catName or "")
        if textW(cname, RL.value, 27) > room then             -- N (§9.7 rule 7): a fact dropped, never a shrink
            local head = cname:match("^(.-) & ")
            cname = (head and textW(head, RL.value, 27) <= room) and head or cutWords(cname, RL.value, 27, room)
        end
        tput(P.name, bx + 122, cy, cname, 27, onCat and COL.WHITE or COL.BEIGE, "lm", room)
        tput(P.cnt, bx + bw - 70, cy, pk.counter, 27, COL.SAGE, "rm")
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
        local namew = iw - 76 - 120 - 56
        local two = G.lines == 2
        for k = 1, #P.rows do
            local R = P.rows[k]
            local idx = top + k
            local d = (k <= cap) and rows[idx] or nil
            if type(d) ~= "table" then
                vis(R.icon, false); vis(R.frame, false); vis(R.tick, false); vis(R.rust, false); vis(R.name, false)
                for j = 1, 4 do vis(R.pips[j], false) end
            else
                local y = G.y + 96 + (k - 1) * G.pitch
                local h = G.pitch - 8
                if cursor == idx then focus = { bx, y, bw, h } end
                pickRow(R, x0, iw, y + h / 2, d, cursor == idx, namew, two)
            end
        end
        return focus, G.y + 96 + cap * G.pitch
    end

    local function renderPerks(card, B, vm, cls)
        local g = PRK[cls]
        local p = vm.perks or {}
        local hue = canon(vm.colour or C.COLOURS.Remote)
        local cur = p.cursor
        local picking = type(p.picker) == "table" and B.pick ~= nil
        local ar = ART[cls].perks
        posterArt(B.art, ar, posterOf(card, vm), cls, "perks", hue)
        hueRule(B.rule, ar, cls == "W", hue)
        local focus = nil
        -- KIT row (A on it = READY; L / R = another kit: arrows inside the focused pill)
        local kr = g.kit
        local avail = kr[3] - 132
        local label = kitLabelOf(p, avail)
        local ky = kr[2] + kr[4] / 2
        if cur == "kit" and not picking then
            focus = kr
            hidePill(B.kit.pill)
            rect(B.kit.al, kr[1] + 22, ky - 14, 28, 28); img(B.kit.al, TX.arrow); tint(B.kit.al, COL.WHITE)
            rect(B.kit.ar, kr[1] + kr[3] - 50, ky - 14, 28, 28); img(B.kit.ar, TX.arrow); tint(B.kit.ar, COL.WHITE)
            tput(B.kit.label, kr[1] + 66, ky, label, 30, COL.WHITE, "lm", avail)
        else
            pill(B.kit.pill, kr[1], kr[2], kr[3], kr[4], "select")
            vis(B.kit.al, false); vis(B.kit.ar, false)
            tput(B.kit.label, kr[1] + 30, ky, label, 30, COL.BEIGE, "lm", avail)
        end
        -- totals once (RK8): W / M in the POWER block; N on the totals line (hidden while the picker is open)
        local pv, pm, ev = perkNumbers(p)
        if g.totals and not picking then
            tput(B.totP, g.x0, g.totals + 30, string.format("POWER %d / %d", pv, pm), 30, COL.CREAM, "ls", g.iw - 290)
            tput(B.totE, g.x0 + g.iw, g.totals + 30, "ENERGY " .. ev, 27, COL.SAGE, "rs", 290)
        else
            vis(B.totP, false); vis(B.totE, false)
        end
        local detailY = g.detail.y
        if picking then
            hideBoard(B)
            local f, rowsEnd = renderPicker(B, g, p.picker, cls)
            focus = f or focus
            detailY = rowsEnd + 24
        else
            hidePicker(B.pick)
            focus = renderBoard(card, B, p, g, cls, cur, pv, pm, ev) or focus
        end
        renderDetail(B, g, p.detail, detailY)
        if focus then pill(B.focus, focus[1], focus[2], focus[3], focus[4], "focus") else hidePill(B.focus) end
    end

    ---------------------------------------------------------------------------------------------------- READY (§9.6)
    local function buildReady(card, cv)
        local R = { cv = cv, card = card }
        R.art = newArt(card, cv, 0)
        R.fade = newImage(card, cv, 2)
        R.rule = newImage(card, cv, 3)
        R.name = newText(card, cv, RL.name, 4, { wrap = PIL.W.name.wrap, lineH = LH.name, label = "pilot name" })
        R.shadow = newImage(card, cv, 4, { box = 0.5, size = 128 })
        R.photo = newPhoto(card, cv, 5)
        R.border = newImage(card, cv, 6, { box = 0.5, size = 128 })
        R.model = newText(card, cv, RL.value, 5, { label = "ready model" })
        R.style = newGuarded(card, cv, RL.style, 5, "r", "ready style")
        R.cells = {}
        for k = 1, 4 do R.cells[k] = newDisc(card, cv, 5, { sub = true }) end
        R.crash = newDisc(card, cv, 5, { sub = true })
        R.styleIc = newImage(card, cv, 5)
        R.traits, R.parts = {}, {}
        for k = 1, 3 do R.traits[k] = newImage(card, cv, 5) end
        for k = 1, 6 do R.parts[k] = { tile = newImage(card, cv, 5), frame = newImage(card, cv, 5) } end
        R.tot = newText(card, cv, RL.value, 5, { label = "ready totals" })
        local hb = construct(WC.hbox)
        R.start = { pill = newPill(card, cv, 5), box = reg(card, { w = hb, s = onCanvas(cv, hb, 6) }) }
        R.start.tick = boxImage(card, hb, 0, 14)
        R.start.label = boxText(card, hb, RL.hero, 0, 0, { label = "start label" })
        R.save = { pill = newPill(card, cv, 5), label = newText(card, cv, RL.hero, 6, { label = "save label" }) }
        R.status = { pill = newPill(card, cv, 5), label = newText(card, cv, RL.status, 6, { label = "ready pill" }),
                     pips = {} }
        for k = 1, 4 do R.status.pips[k] = newImage(card, cv, 6) end
        return R
    end

    -- The loadout (§9.6): row A = 4 ability discs (slot order, gap 8) + crash (GOLD ring) [+ the 6 part icons in M's
    -- one row] + the style glyph GOLD + 3 trait glyphs SAGE; row B (W / N) = the part icons (empty: the AffixFrame
    -- outline BEIGE @0.35). Items shrink together when a row would pass the column.
    local function renderLoadout(R, s, L)
        s = type(s) == "table" and s or {}
        local sa, sc, sp, ss, st = L.sizes[1], L.sizes[2], L.sizes[3], L.sizes[4], L.sizes[5]
        local ab = type(s.ab) == "table" and s.ab or {}
        local parts = type(s.parts) == "table" and s.parts or {}
        local traits = type(s.traits) == "table" and s.traits or {}
        local nP, nT = count(parts, 10), count(traits, 4)
        for k = #R.parts + 1, nP do R.parts[k] = { tile = newImage(R.card, R.cv, 5), frame = newImage(R.card, R.cv, 5) } end
        for k = #R.traits + 1, nT do R.traits[k] = newImage(R.card, R.cv, 5) end
        local wA = 4 * (sa + 8) + sc + 22 + ss + 12 + nT * (st + 8)
        if L.rows == 1 then wA = wA + nP * (sp + 6) + 16 end
        local wB = (L.rows == 2) and nP * (sp + 6) or 0
        local k = min(1, L.w / max(1, wA, wB))
        local x, y = L.x, L.y
        for i = 1, 4 do
            disc(R.cells[i], x, y, sa * k, ab[i], nil, false)
            x = x + (sa + 8) * k
        end
        disc(R.crash, x, y + (sa - sc) * k / 2, sc * k, s.crash or ab.crash, COL.GOLD, false, true)
        x = x + (sc + 22) * k
        local function partsAt(px, py)
            local w = sp * k
            for i = 1, #R.parts do
                local E = R.parts[i]
                if i <= nP then
                    local d = parts[i]
                    local path = (type(d) == "table") and d.tile or d
                    if type(path) ~= "string" or (type(d) == "table" and d.empty == true) then
                        vis(E.tile, false)
                        local f = w * 0.86
                        rect(E.frame, px + (w - f) / 2, py + (w - f) / 2, f, f); img(E.frame, TX.affix)
                        tint(E.frame, K.PART_EMPTY)
                    else
                        vis(E.frame, false)
                        rect(E.tile, px, py, w, w); img(E.tile, path, TX.noAffix); tint(E.tile, COL.WHITE)
                    end
                    px = px + (sp + 6) * k
                else
                    vis(E.tile, false); vis(E.frame, false)
                end
            end
            return px
        end
        if L.rows == 1 then x = partsAt(x, y + (sa - sp) * k / 2) + 16 * k end
        local sIcon = (type(s.style) == "table") and s.style.icon or s.style
        if type(sIcon) == "string" then
            rect(R.styleIc, x, y + (sa - ss) * k / 2, ss * k, ss * k); img(R.styleIc, styleIcon(sIcon))
            tint(R.styleIc, COL.GOLD)
        else
            vis(R.styleIc, false)
        end
        x = x + (ss + 12) * k
        for i = 1, #R.traits do
            local e = R.traits[i]
            local d = (i <= nT) and traits[i] or nil
            local path = (type(d) == "table") and d.icon or d
            if type(path) == "string" and not (type(d) == "table" and d.empty) then
                rect(e, x, y + (sa - st) * k / 2, st * k, st * k); img(e, path); tint(e, COL.SAGE)
            else
                vis(e, false)
            end
            if i <= nT then x = x + (st + 8) * k end
        end
        if L.rows == 2 then partsAt(L.x, y + (sa + 14) * k) end
    end

    -- 0.11.0 readyPanel.line "ARY QUILL · NL-4": the name before the last "·", the model after it
    local function lineName(line) return type(line) == "string" and line:match("^(.-)%s*\194\183[^\194]*$") or nil end
    local function lineModel(line) return type(line) == "string" and line:match(".*\194\183%s*(.-)%s*$") or nil end

    -- P1's rows by input mode (§6.4, §9.6, VERIFY(V-FIN-11): START RACE once on screen): "pad" = START RACE / SAVE AND
    -- RETURN on the card; "p1pill" = P1 with mouse + keyboard (START / SAVE in the command row): the READY pill;
    -- "waiting" = a guest's WAITING FOR P1 pill. readyPanel.rows / p1Pill / waiting (§9.9), else the 0.11.0 rows.
    local function readyMode(vm, rp)
        if rp.waiting == true then return "waiting" end
        if rp.p1Pill == true then return "p1pill" end
        if vm.isP1 and vm.inputMode == "mouse" then return "p1pill" end
        local nr = count(rp.rows, 4)
        if nr >= 2 then return "pad" end
        if vm.isP1 then return (nr >= 1) and "pad" or "p1pill" end
        return "waiting"
    end

    local function readyRows(card, R, vm, rp, g)
        local mode = readyMode(vm, rp)
        card.pulse = false
        if mode == "pad" then
            hidePill(R.status.pill); vis(R.status.label, false)
            for k = 1, 4 do vis(R.status.pips[k], false) end
            local rows = type(rp.rows) == "table" and rp.rows or {}
            local cursor = tonumber(rp.cursor) or 0
            local first = tostring(rows[1] or "START RACE")
            local all = rp.allReady == true or rp.pulse == true or first:find("ALL READY", 1, true) ~= nil
            local startLabel = (first:gsub("%s*\194\183%s*ALL READY.*$", ""))
            local s1, on1 = g.start, cursor == 1
            -- START RACE hero pill, heroLabel 39 (+ a 40-su tick before the label when everyone is ready)
            pill(R.start.pill, s1[1], s1[2], s1[3], s1[4], on1 and "focus" or "hero", nil, on1 and 1.05 or 1)
            place(R.start.box, s1[1] + s1[3] / 2, s1[2] + s1[4] / 2, 0.5, 0.5); show(R.start.box, true)
            rscale(R.start.box, on1 and 1.05 or 1)
            local lc = on1 and COL.WHITE or COL.MIST
            if all then
                dsize(R.start.tick, 40); img(R.start.tick, TX.tick); tint(R.start.tick, lc)
            else
                vis(R.start.tick, false)
            end
            font(R.start.label, 39); ink(R.start.label, lc); text(R.start.label, startLabel); show(R.start.label, true)
            R.start.label.box = s1[3] - 48 - (all and 54 or 0)
            queueFit(R.start.label)
            -- the START pulse animates the WHITE rim's opacity only (0.55 <-> 1, 1 s; RR4), CD.tick
            card.pulse = all and on1 and opt("CardStartPulse", true) ~= false
            if not card.pulse then opacity(R.start.pill.line, 1) end
            -- SAVE AND RETURN: idle = text only Moki 33 BEIGE @0.8, cursor = the hero pill
            local s2 = g.save
            local saveLabel = tostring(rows[2] or "SAVE AND RETURN")
            if cursor == 2 then
                pill(R.save.pill, s2[1], s2[2], s2[3], s2[4], "focus", nil, 1.05)
                tput(R.save.label, s2[1] + s2[3] / 2, s2[2] + s2[4] / 2, saveLabel, 33, COL.WHITE, "cm", s2[3] - 48)
            else
                hidePill(R.save.pill)
                tput(R.save.label, s2[1] + s2[3] / 2, s2[2] + s2[4] / 2, saveLabel, 33, K.SAVE_IDLE, "cm", s2[3] - 48)
            end
            rscale(R.save.label, (cursor == 2) and 1.05 or 1)
            return
        end
        hidePill(R.start.pill); vis(R.start.box, false); hidePill(R.save.pill); vis(R.save.label, false)
        -- the READY / WAITING FOR P1 pill: NEAR @0.55, Moki 30 STATUS, AMBER pips (one per player, filled = on READY)
        local P = g.pill
        pill(R.status.pill, P[1], P[2], P[3], P[4], "flat", K.NEAR55)
        local cy = P[2] + P[4] / 2
        tput(R.status.label, P[1] + 36, cy, (mode == "p1pill") and "READY" or "WAITING FOR P1", 30, COL.STATUS, "lm",
            P[3] - 72 - 130)
        local pips = type(rp.pips) == "table" and rp.pips or {}
        local n = min(4, count(pips, 4))
        local px = P[1] + P[3] - 36
        for k = 1, 4 do
            local e = R.status.pips[k]
            if k <= n then
                local cx = px - (n - k) * 30
                rect(e, cx - 9, cy - 9, 18, 18); img(e, pips[k] and TX.disc or TX.ring); tint(e, COL.AMBER)
            else
                vis(e, false)
            end
        end
    end

    local function renderReady(card, R, vm, cls, keep)
        local rp = vm.readyPanel or {}
        local g, cw, pad = RDY[cls], CARD[cls].w, CARD[cls].pad
        local hue = canon(vm.colour or C.COLOURS.Remote)
        local ar = ART[cls].ready
        posterArt(R.art, ar, posterOf(card, vm), cls, "ready", hue)
        hueRule(R.rule, ar, cls == "W", hue)
        local name, rankTag = pilotName(vm, rp.name or rp.pilotName or (vm.header and vm.header.pilotName)
            or lineName(rp.line))
        local rank = rankText(vm, rankTag, "READY")
        if cls == "W" then
            nameOnPoster(card, R, name, rank, ar)
        else
            vis(R.fade, false)
            wrap(R.name, 0)
            tput(R.name, pad, g.name.base, name, g.name.size, COL.WHITE, "ls", cw - 2 * pad)
            card.rankWant = { x = pad, y = g.rank, s = rank, box = cw - 2 * pad }
        end
        -- the photo plate: the still render on its backdrop, BORDER + shadow (W beside the poster; M / N pinned on it)
        local pr = g.plate
        rect(R.shadow, pr[1] - 30, pr[2] - 20, pr[3] + 60, pr[4] + 60); material(R.shadow, MT.shadow)
        tint(R.shadow, K.SHADOW45)
        local fb = rp.fallback or (type(vm.vehicle) == "table" and vm.vehicle.fallback) or nil
        photo(R.photo, pr, { brush = rp.brush, brushKind = rp.brushKind, dim = rp.dim, fallback = fb, aspect = rp.aspect,
                             backdrop = rp.backdrop }, keep)
        rect(R.border, pr[1], pr[2], pr[3], pr[4]); img(R.border, TX.stroke); tint(R.border, COL.BORDER)
        -- model (W Moki 45 WHITE; M / N 33 BEIGE) and the style right-aligned (GOLD 33 / 30) on one baseline
        -- each fact once (rule 8): a pod's style is named after its pod, so a style name equal to the model goes; a W
        -- model wider than the column (CUSTOM ORD PEDROVIA 967 su at 45) takes the modelTitle role's 36; a style that
        -- does not fit beside the model even at its minimum is dropped (rule 7; the loadout keeps its glyph)
        local model = tostring(rp.model or lineModel(rp.line) or "")
        local style = tostring(rp.styleName or "")
        if string.upper(style) == string.upper(model) then style = "" end
        local mx, mb, msz = g.model[1], g.model[2], g.model[3]
        local sx, sb, ssz = g.style[1], g.style[2], g.style[3]
        if cls == "W" and textW(model, RL.value, msz) > sx - mx then msz = 36 end
        tput(R.model, mx, mb, model, msz, (cls == "W") and COL.WHITE or COL.BEIGE, "ls", sx - mx)
        local smin = min(ssz, (cls == "N") and 30 or 33)
        local room = sx - (mx + textW(model, RL.value, msz) + 32)
        if style ~= "" and textW(style, RL.style, smin) <= room then
            gput(R.style, sx, sb, style, ssz, smin, COL.GOLD, room, room, "r", "s")
        else
            vis(R.style, false)
        end
        renderLoadout(R, rp.strip, g.loadout)
        -- totals "POWER 31 / 60 · ENERGY 8" (Moki 30 / 27); W's MAX POWER line (60 / 60 · 16: 847 su) takes 27
        local tot = g.totals
        local tsz = tot[3]
        if textW(rp.totals, RL.value, tsz) > g.loadout.w + 2 then tsz = 27 end
        tput(R.tot, tot[1], tot[2], rp.totals, tsz, COL.CREAM, "ls", g.loadout.w)
        readyRows(card, R, vm, rp, g)
    end

    return { pilot = buildPilot, vehicle = buildVehicle, perks = buildPerks, ready = buildReady },
        { pilot = renderPilot, vehicle = renderVehicle, perks = renderPerks, ready = renderReady }, buildPicker
end)()

---------------------------------------------------------------------------------------------------- building

-- One unit of the per-tick build budget (a card shell, a stage panel or a picker; vehicle-step-v2 §5.12).
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
    local card = { i = i, box = X.boxes[i], els = {}, stages = {}, bad = {}, cls = X.cls, nw = 0 }
    X.cards[i] = card
    local t0, n0 = now(), X.nWidgets
    X.cc = card
    local ok, err = pcall(buildShell, card)
    if not ok then
        -- §8.2: the shell is replaced by a BAND panel with RACER CARD ERROR and the text rows
        card.broken = tostring(err)
        U.warn(TAG, "card %d: shell failed (%s): RACER CARD ERROR panel (V-RC-01)", i, tostring(err))
        local ok2, err2 = pcall(function()
            pcall(function() card.box:ClearChildren() end)
            card.els, card.err = {}, nil
            local sb = construct(WC.scale)
            pcall(function() sb:SetStretch(FIT); sb:SetStretchDirection(DOWN_ONLY) end)
            card.box:AddChild(sb)
            local design = construct(WC.size)
            sb:AddChild(design)
            card.design = design
            card.cv = construct(WC.canvas)
            design:AddChild(card.cv)
            ensureErr(card)
        end)
        if not ok2 then
            card.dead = true
            U.err(TAG, "card %d: the error panel failed too (%s)", i, tostring(err2))
        end
    end
    X.cc = nil
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
        local cv = construct(WC.canvas)                   -- collapsed until a render shows it: a half-built one stays off
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
    X.cc = card
    if card.broken then
        U.tryEvery("cards2.error", nil, TAG, renderErr, card, vm, true, true)
        X.cc = nil
        card.pending = false
        return true
    end
    U.tryEvery("cards2.frame", nil, TAG, renderFrame, card, vm, cls)
    U.tryEvery("cards2.rail", nil, TAG, renderRail, card, vm, cls)
    U.tryEvery("cards2.tag", nil, TAG, renderTag, card, vm, cls)
    U.tryEvery("cards2.hint", nil, TAG, renderHint, card, vm, cls)
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
    local cw = CARD[cls].w
    for st, p in pairs(card.stages) do
        if st == stage then
            rect(p.cvE, 0, 0, cw, CH)
            show(p.cvE, true)
        else
            vis(p.cvE, false)
        end
    end
    U.tryEvery("cards2.error", nil, TAG, renderErr, card, vm, card.bad[stage] ~= nil, false)
    card.rankWant = nil
    if panel then U.tryEvery("cards2." .. stage, nil, TAG, RENDER[stage], card, panel, vm, cls, keep) end
    U.tryEvery("cards2.rank", nil, TAG, applyRank, card)
    if not (panel and stage == "ready") then card.pulse = false end
    X.cc = nil
    card.pending = not done
    return done
end

local function relayout(card)
    clearCardCaches(card)
    card.cls = X.cls
    shellLayout(card)
    if card.vm then renderCard(card, card.vm, true) end
end

---------------------------------------------------------------------------------------------------- API (§5.6, §12.2)
-- The cards.lua API unchanged (vehicle-step-v2 §5.6); the view model is §5.6 + the §9.9 fields, every one optional:
-- vm.inputMode ("pad" | "mouse", P1: READY rows vs the READY pill), vm.rankTag ("AGED"), vm.classIcon (the rail's
-- VEHICLE glyph; else St.racers.cls.icon), pilot.tile / pilot.figure {full, crop} / pilot.signatureModel, header.tile,
-- vehicle.models {{name, badge, code, current}} (W 6 / M 4; nil = the title row), vehicle.livery, vehicle.aspect,
-- perks.kitLabel / kitLabelShort, perks.power / energy (numbers) or powerValue / powerMax / energyValue,
-- perks.detail.tag (perks.detail's short tag), readyPanel.rows + allReady | p1Pill | waiting, readyPanel.pips,
-- readyPanel.model / pilotName, hint verbs (sentence case; upper case is converted), toast.
-- setup.buildWidgets (through racers.build): ctx = {tree, pc, newW, row (FuseHorizontalBox), realMs}. Puts four empty
-- card boxes into the row (in order, collapsed; shells are built lazily). Errors when the row or theme.lua is unusable
-- (setup then keeps the classic columns for this page).
function M.init(ctx)
    if type(ctx) ~= "table" or not U.ok(ctx.row) then error("cards2.init: no card row") end
    if not tokens() then error("cards2.init: theme.lua unavailable (the v2 tokens)") end
    -- the same page (the same context): keep its cards. Not U.same on the stored row: UE4SS validity is address based,
    -- and a new page's row can reuse a dead page's address (RC-7)
    if X and X.ctx == ctx then return true end
    X = { ctx = ctx, cls = nil, n = 0, boxes = {}, slots = {}, boxC = {}, cards = {}, early = {}, built = 0, bigUsed = 0,
          smallUsed = 0, qHi = {}, qLo = {}, queued = {}, wait = {}, missing = {}, req = {}, matMiss = {}, fit = {},
          nWidgets = 0, nPanels = 0, mids = 0, loads = 0, stale = 0, overflows = 0, budgetAt = -1e9, cc = nil,
          look = { thumb = opt("CardThumbMask", "mid"), glyphs = opt("CardGlyphs", "xbox"),
                   fig = (opt("CardFigureTint", "mid") == "plain") and "plain" or "mid", rich = true } }
    for i = 1, 4 do
        local b = construct(WC.size)
        pcall(function() b:SetVisibility(VIS.Collapsed) end)
        local s = ctx.row:AddChildToHorizontalBox(b)      -- -> HorizontalBoxSlot
        if U.ok(s) then pcall(function() s:SetVerticalAlignment(AL.t) end) end
        X.boxes[i], X.slots[i], X.boxC[i] = b, s, {}
    end
    U.log(TAG, "init: 4 card slots (v2 posters; head shots %s, glyphs %s, pod figure %s, player stripe %s at %s deg, "
        .. "backdrop %s) (V-RC-01, V-FIN-06, V-FIN-07)", X.look.thumb, X.look.glyphs, X.look.fig,
        (opt("CardStripe", true) == false) and "off" or "on", tostring(num("CardStripeAngle", 90 - STRIPE.angle)),
        tostring(opt("PreviewBackdrop", "studio")))
    return true
end

-- n players: card widths / gaps (CardW / CardGap per player count: v2 {1762, 1762, 1162, 860} / {0, 60, 49, 48}, CardH
-- 1300; config.lua resolves them per UiStyle), cards > n hidden. Returns "W" | "M" | "N". A class change clears every
-- card's render caches and re-renders it from its last view model at once (RC-15, V-RC-15).
function M.layout(n)
    if not X then return nil end
    n = clamp(floor(tonumber(n) or 0), 0, 4)
    local cls = (n <= 2) and "W" or ((n == 3) and "M" or "N")
    local DW, DG = { 1762, 1762, 1162, 860 }, { 0, 60, 49, 48 }
    local cw, gap = DW[max(1, n)], DG[max(1, n)]
    if type(cfg.CardW) == "table" then cw = tonumber(cfg.CardW[max(1, n)]) or cw end
    if type(cfg.CardGap) == "table" then gap = tonumber(cfg.CardGap[max(1, n)]) or gap end
    local h = num("CardH", CH)
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
            if card then U.tryEvery("cards2.relayout", nil, TAG, relayout, card) end
        end
        U.log(TAG, "layout: %d player(s), class %s (was %s), cards %d su (design %d x %d), gap %d (V-RC-15)", n, cls,
            tostring(old), cw, CARD[cls].w, CH, gap)
    end
    return cls
end

-- Card shell i built (frame, rail, tag, hint line); at most CardBuildsPerTick builds per FAST tick. false = not yet
-- (budget) or unusable.
function M.ensure(i)
    if not X or not X.boxes[i] then return false end
    local card = X.cards[i]
    if card then return not card.dead end
    if not X.cls then M.layout(max(i, X.n)) end
    if not takeBudget() then return false end
    return buildCard(i)
end

-- Renders view model vm on card i: builds the shell / the vm.stage panel / the picker on first use (budget), then diffs
-- everything. Returns true when complete; false = something waits for the build budget (CD.tick finishes it from this
-- vm, without touching the render brush) or the card is unusable.
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
-- CardLoadsPerTick small, the tiny chrome icons freely) and puts them on the images waiting for them, finishes deferred
-- panels, animates the START rim, checks the texts laid out since (§9.7). Returns the indices of the cards it changed
-- (informational: they need no re-render).
function M.tick()
    if not X then return {} end
    X.built, X.bigUsed, X.smallUsed, X.budgetAt = 0, 0, 0, now()
    local touched = {}
    U.tryEvery("cards2.load", nil, TAG, function()
        local sm = smallMax()
        for _, q in ipairs({ X.qHi, X.qLo }) do
            local i, scanned = 1, 0
            while i <= #q and scanned < 64 do
                scanned = scanned + 1
                local p = q[i]
                if X.queued[p] ~= q then
                    table.remove(q, i)                    -- promoted to the other queue, or done
                else
                    local free = tiny(p)
                    local big = not free and isBig(p)
                    if (big and X.bigUsed >= 1) or (not free and not big and X.smallUsed >= sm) then
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
        if card and card.pending and card.vm then        -- the shell at once; the panel when the budget allows
            U.tryEvery("cards2.deferred", nil, TAG, renderCard, card, card.vm, true)
            touched[i] = true
        end
        local R = card and card.stages.ready
        if R and card.pulse and card.vm and card.vm.stage == "ready" then
            local ph = (now() % 1000) / 1000
            opacity(R.start.pill.line, floor((0.775 + 0.225 * math.cos(2 * math.pi * ph)) * 100 + 0.5) / 100)
        end
    end
    U.tryEvery("cards2.fit", nil, TAG, fitCheck)
    local out = {}
    for i in pairs(touched) do out[#out + 1] = i end
    table.sort(out)
    return out
end

-- Texture2D for path: cached / already loaded at once, else queued (nil until CD.tick loaded it). Used to prefetch
-- (PILOT entry: the class roster's head shots and posters, one big texture per tick).
function M.tex(path)
    path = texPath(path)
    if not X or not path then return nil end
    return getTex(path, false)
end

-- Every render image (VEHICLE photo, READY plate) of card i (nil = all cards) lets go of its brush: call before
-- vpreview frees the bays' render targets (VP.release / VP.releaseAll with freeTargets). Returns the number reset.
function M.releaseRenders(i)
    if not X then return 0 end
    local n = 0
    for k, card in pairs(X.cards) do
        if i == nil or k == i then
            for _, st in ipairs({ "vehicle", "ready" }) do
                local P = card.stages[st]
                local e = P and P.photo and P.photo.render
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
        if card then U.tryEvery("cards2.reshow", nil, TAG, relayout, card) end
    end
end

-- The page died (menu replaced): every reference dropped (no game call).
function M.forget()
    X = nil
end

function M.cls() return X and X.cls or nil end

-- test.cmd / diag: cards, widgets (total and per card: §9.8 / V-FIN-14 expects about 1.6k for 4 players), panels,
-- textures, MIDs, overflow lines (V-FIN-09 wants 0) and the fallbacks in use.
function M.status()
    if not X then return "no page" end
    local built, panels, nReq, nGot, queued, missing = 0, 0, 0, 0, 0, 0
    local per = {}
    for i = 1, 4 do
        local card = X.cards[i]
        if card then
            built = built + 1
            for _, p in pairs(card.stages) do panels = panels + (p.pick and 2 or 1) end
            per[#per + 1] = string.format("P%d %d", i, card.nw or 0)
        end
    end
    for p in pairs(X.req) do
        nReq = nReq + 1
        if TXC[p] ~= nil then nGot = nGot + 1 end
    end
    for _ in pairs(X.queued) do queued = queued + 1 end
    for _ in pairs(X.missing) do missing = missing + 1 end
    local fb = {}
    if X.look.thumb ~= opt("CardThumbMask", "mid") then fb[#fb + 1] = "head shots plain" end
    if X.look.fig == "plain" and opt("CardFigureTint", "mid") ~= "plain" then fb[#fb + 1] = "figure tint plain" end
    if not X.look.rich then fb[#fb + 1] = "plain bodies" end
    if setBrushBroken then fb[#fb + 1] = "SetBrush off" end
    if fontMatBroken then fb[#fb + 1] = "font materials off" end
    return string.format("cards2 %d (%s), widgets %d [%s], panels %d, tex %d/%d (queued %d, loads %d, missing %d, "
        .. "stale %d), mids %d, text overflow %d%s (V-FIN-09, V-FIN-14)", built, tostring(X.cls), X.nWidgets,
        table.concat(per, ", "), panels, nGot, nReq, queued, X.loads, missing, X.stale, X.mids, X.overflows,
        (#fb > 0) and (", fallbacks: " .. table.concat(fb, ", ")) or "")
end

return M
