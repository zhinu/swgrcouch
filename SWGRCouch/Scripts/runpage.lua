-- runpage.lua: the GALAXY RUN page (0.14 v3). Jules 2026-10-13: "galaxy run should open to a new page. New run,
-- continue run, shop etc..." + "I want it to look glorious".
--
-- A panel on the FREE MODE page, shown like RACE SETUP's (lobby.setSetupMode hides the posters while it is open):
-- the GALAXY RUN poster's A opens it. Two layers:
--   * THE SCENE (cfg.RunPageDeco): the campaign run-map look, built from the standalone-safe campaign widgets the
--     cmap research proved (notes/research/campaign-map/02, 03): T_UI_MapEvent_Bg on a 3840-su virtual canvas in a
--     ScaleToFit box, WBP_RunMap_Planet (the current planet, turning ring + sonar), the planet's NODE GRAPH drawn
--     with WBP_RunMap_Activity_Presentation_Btn nodes (no MapNode; icon + NodeState drive the look) joined by the
--     campaign's 5-su elbow lines (olive #BFC2A1, the picked path amber #E0AC50), League-Token pips
--     (WBP_Cam_Strike_Entry: SetHasStrike(false) = a token, true = a lost one), the Aurebesh deco line and
--     Font_Display titles, standings at the top right, the campaign's own RunMap sounds.
--   * THE ROWS (always): WBP_Common_Btn list rows carry ALL input - CONTINUE / NEXT NODE / LEAGUE / START NEW RUN /
--     END THE RUN (A twice) / BACK. The scene is display-only (HitTestInvisible): zero new input risk. Any scene
--     failure tears it down once and the page keeps working as plain rows (status/target/standings label rows show
--     again).
-- Rewards and the shop stay on each racer card (per-pad input lives there); CONTINUE leads to them.
-- The page never touches the game's campaign. Every game call is pcall-guarded; no UObject is kept across pages
-- (forget drops everything). B04: P1's pad B closes the page (lobby's B poll; backprompt answers the game's QuitGame
-- prompt this B posts over the page), as do the BACK row and keyboard Backspace.
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")
local C = require("consts")

local TAG = "runpage"
local M = {}

local W = nil                -- widgets of the current page instance (nil until built; dropped by forget)
local S = { active = false, abandonUntil = 0, abandonArmedMs = -1e12, backMs = -1e12 }

local function run() return U.mod("run") end
local function ui() return U.mod("ui") end
local function V() return U.mod("vehicles") end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

---------------------------------------------------------------------------------------------------- assets
local RM = "/Game/Griffin/UI/Widgets/RunMap/"
local CLS_PLANET = RM .. "WBP_RunMap_Planet.WBP_RunMap_Planet_C"
local CLS_NODE   = RM .. "WBP_RunMap_Activity_Presentation_Btn.WBP_RunMap_Activity_Presentation_Btn_C"
local CLS_PIP    = "/Game/Griffin/UI/Widgets/Campaign/WBP_Cam_Strike_Entry.WBP_Cam_Strike_Entry_C"
local TX = "/Game/Griffin/UI/Library/Textures/"
local function tx(sub, n) return TX .. sub .. n .. "." .. n end
local TEX_BG = tx("Backgrounds/", "T_UI_MapEvent_Bg")
local TEXK = {                                           -- node icons: BPFL_UIUtils.GetIconTextureForActivity [V]
    standard    = tx("Icons/Map/", "T_UI_Map_StandardEvent_Icn"),
    highrisk    = tx("Icons/Map/", "T_UI_Map_HighRisk_Icn"),
    fieldtest   = tx("Icons/Map/", "T_UI_Map_ShakedownRun_Icn"),
    planesprint = tx("Icons/Arcade/", "T_UI_Arcade_Plane_Icn"),
    knockout    = tx("Icons/Map/", "T_UI_Map_HighRisk_Icn"),
    champion    = tx("Icons/Map/", "T_UI_Map_ChampionEvent_Icn"),
}
local FONT_DISPLAY = "/Game/Griffin/UI/Library/Fonts/Font_Display.Font_Display"
local FONT_BODY    = "/Game/Griffin/UI/Library/Fonts/Font_Body.Font_Body"
local FONT_DECO    = "/Game/Griffin/UI/Library/Fonts/Font_Decorative.Font_Decorative"
local AUDIO_DT     = "/Game/Griffin/Audio/UI/DT_UI_Audio_ForceFeedback.DT_UI_Audio_ForceFeedback"
local AUDIO_LIB    = "/Script/Griffin.Default__UIAudioLibrary"

local VBOX   = { "/Script/Griffin.FuseVerticalBox", "/Script/UMG.VerticalBox" }
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local SCALE  = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" }
local TEXT   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }
local SIZEB  = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" }

local VIS = C.E.Vis
local STRETCH_FIT, STRETCH_FILL = 2, 5                   -- EStretch ScaleToFit / ScaleToFill
local CLIP_BOUNDS = 1

-- the campaign widgets' own colours (campaign-map/02 §1.4)
local INK_LIGHT  = { R = 0.775822, G = 0.730461, B = 0.665387, A = 1 } -- #E4DED5 run-map text
local INK_FOCUS  = { R = 1.0, G = 0.8632, B = 0.6724, A = 1 }          -- #FFEFD7
local LINE_OLIVE = { R = 0.520996, G = 0.53948, B = 0.3564, A = 1 }    -- #BFC2A1 MapLineTint
local LINE_AMBER = { R = 0.745404, G = 0.412543, B = 0.08022, A = 1 }  -- #E0AC50 VisitedPathMapLineTint
local LINE_DIM   = { R = 0.241, G = 0.25, B = 0.165, A = 1 }           -- #878971 DeadPathMapLineTint
local BACKER     = { R = 0.006944, G = 0.006944, B = 0.006944, A = 1 } -- #131313
local SHADOW     = { R = 0, G = 0, B = 0, A = 0.85 }

---------------------------------------------------------------------------------------------------- geometry
-- The campaign MAP formula (05-campaign-ux-live.md): the planet disc is the stage, the graph sits ON it, the header
-- is a dark tag top-left, the tokens a chip top-right, and the picked node gets a dark RISK CARD at the right.
local VW, VH = 3840, 1040                                -- the scene's virtual canvas (campaign units)
local BOX_W, BOX_H = 3500, 950                           -- on the page (ScaleToFit)
local PANEL_W, PANEL_H = 2140, 2400                      -- WBP_RunMap_Planet natural size
local PLANET_X, PLANET_SCALE = 660, 0.52
local TAG_X, TAG_Y, TAG_W = 44, 32, 1280                 -- the header tag (dark, over the disc's top left)
local GRAPH_X0, GRAPH_DX, GRAPH_CY, GRAPH_DY = 620, 430, 650, 212   -- the graph rides the disc
local NODE_SCALE, NODE_SCALE_SEL = 1.45, 1.95
local CARD_X, CARD_Y, CARD_W, CARD_H = -44, 168, 1100, 836          -- the node risk card (right-anchored)
local PIP_DX, PIP_Y = 84, CARD_Y + 12                    -- token pips: the risk card's top-right corner
local NODE_MAX, STRIP_MAX = 16, 96

---------------------------------------------------------------------------------------------------- widget helpers
local function mk(paths, outer)
    for _, p in ipairs(paths) do
        local ok, cls = pcall(U.class, p)
        if ok and U.ok(cls) then
            local okW, w = pcall(StaticConstructObject, cls, outer)
            if okW and U.ok(w) then return w end
        end
    end
    return nil
end

local function lin(c) return { R = c.R, G = c.G, B = c.B, A = c.A or 1 } end
local function slate(c) return { SpecifiedColor = lin(c), ColorUseRule = 0 } end

local function show(w, on)
    if U.ok(w) then pcall(function() w:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end) end
end

local function place(cv, w, o)
    local s = cv:AddChildToCanvas(w)
    if not U.ok(s) then error("AddChildToCanvas returned no slot") end
    local an = o.anchor or { 0, 0 }
    s:SetAnchors({ Minimum = { X = an[1], Y = an[2] }, Maximum = { X = an[1], Y = an[2] } })
    s:SetAlignment({ X = o.ax or 0, Y = o.ay or 0 })
    if o.size then
        s:SetAutoSize(false)
        s:SetSize({ X = o.size[1], Y = o.size[2] })
    else
        s:SetAutoSize(true)
    end
    s:SetPosition({ X = o.x or 0, Y = o.y or 0 })
    if o.z then s:SetZOrder(o.z) end
    return s
end

local fontCache = {}
local function fontObj(path)
    local f = fontCache[path]
    if f and U.ok(f) then return f end
    f = U.obj(path)
    if U.ok(f) then fontCache[path] = f; return f end
    return nil
end

local function newText(outer, s)
    local t = mk(TEXT, outer)
    if not t then error("no TextBlock class") end
    if s.wrapAt then pcall(function() t.WrapTextAt = s.wrapAt end) end
    local f = fontObj(s.font or FONT_DISPLAY)
    if f then
        pcall(function() t:SetFont({ FontObject = f, TypefaceFontName = U.fname(s.typeface or "None"),
                                     Size = s.size or 32 }) end)
    end
    pcall(function() t:SetColorAndOpacity(slate(s.colour or INK_LIGHT)) end)
    if s.justify then pcall(function() t:SetJustification(s.justify) end) end
    pcall(function() t:SetTextTransformPolicy(2) end)                       -- ToUpper, the campaign look
    if s.shadow then
        pcall(function()
            t:SetShadowOffset({ X = 3, Y = 3 })
            t:SetShadowColorAndOpacity(lin(SHADOW))
        end)
    end
    pcall(function() t:SetVisibility(VIS.HitTestInvisible) end)
    return t
end

local function setPlain(t, text)
    if U.ok(t) then pcall(function() t:SetText(U.ftext(text or "")) end) end
end

local function solid(outer, colour)
    local img = mk(IMAGE, outer)
    if not img then error("no Image class") end
    pcall(function() img:SetColorAndOpacity(lin(colour)) end)
    pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
    return img
end

local function sizeBox(outer, w, h)
    local sb = mk(SIZEB, outer)
    if not sb then error("no SizeBox class") end
    if w then pcall(function() sb:SetWidthOverride(w) end) end
    if h then pcall(function() sb:SetHeightOverride(h) end) end
    return sb
end

local soundObjs = {}
local function sound(row)
    if opt("RunPageSounds", true) == false or not W then return end
    pcall(function()
        if not U.ok(soundObjs.al) then soundObjs.al = U.cdo(AUDIO_LIB) end
        if not U.ok(soundObjs.dt) then soundObjs.dt = U.obj(AUDIO_DT) end
        if U.ok(soundObjs.al) and U.ok(soundObjs.dt) then
            soundObjs.al:Play2DAudioFromTable(W.pc, soundObjs.dt, U.fname(row))
        end
    end)
end

---------------------------------------------------------------------------------------------------- the scene
-- Built once per page in its own pcall; nil = rows mode. All display-only.
local function buildDeco(panel, tree, pc)
    if opt("RunPageDeco", true) == false then return nil end
    local D = { nodes = {}, strips = {}, pips = {}, stand = {} }
    local outer = tree
    D.box = sizeBox(outer, BOX_W, BOX_H)
    local slot = panel:AddChildToVerticalBox(D.box)
    if U.ok(slot) then
        pcall(function() slot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 10 }) end)
        pcall(function() slot:SetHorizontalAlignment(C.E.HAlign.Center) end)   -- a Fill slot would stretch the box
    end
    D.virt = sizeBox(outer, VW, VH)
    pcall(function() D.virt:SetClipping(CLIP_BOUNDS) end)  -- the planet rings reach far outside the panel
    local sc = mk(SCALE, outer)
    if not sc then error("no ScaleBox class") end
    pcall(function() sc:SetStretch(STRETCH_FIT) end)
    sc:AddChild(D.virt)
    D.box:AddChild(sc)
    D.over = mk(OVER, outer)
    if not D.over then error("no Overlay class") end
    D.virt:AddChild(D.over)
    local function fill(w)
        local s = D.over:AddChildToOverlay(w)
        if U.ok(s) then pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end) end
    end
    -- no backer of its own: the scene floats on the page's starfield
    D.canvas = mk(CANVAS, outer)
    if not D.canvas then error("no CanvasPanel class") end
    fill(D.canvas)
    -- the big planet is created lazily in setPlanet (PlanetDef + Planet must be set BEFORE the add: PreConstruct
    -- draws the texture; a later property write alone never reaches the brush - seen live 2026-10-13)
    D.pl, D.plKey = nil, nil
    -- the header TAG (the campaign map's act header): a dark panel, Aurebesh echo, title, status, goal sentence
    D.tagBack = solid(outer, { R = 0.004, G = 0.018, B = 0.024, A = 1.0 })   -- opaque: translucent canvas solids do not draw (live)
    D.tagSlot = place(D.canvas, D.tagBack, { x = TAG_X, y = TAG_Y, size = { TAG_W, 330 }, z = 2 })
    D.deco  = newText(outer, { font = FONT_DECO, typeface = "Aurebesh", size = 26, colour = LINE_AMBER })
    place(D.canvas, D.deco, { x = TAG_X + 36, y = TAG_Y + 22, z = 3 })
    setPlain(D.deco, "GALAXY RUN")
    D.title = newText(outer, { font = FONT_DISPLAY, size = 92, colour = INK_FOCUS, shadow = true })
    place(D.canvas, D.title, { x = TAG_X + 36, y = TAG_Y + 52, z = 3 })
    setPlain(D.title, "GALAXY RUN")
    D.line1 = newText(outer, { font = FONT_BODY, typeface = "Bold", size = 40, colour = INK_LIGHT, shadow = true,
                               wrapAt = TAG_W - 72 })
    place(D.canvas, D.line1, { x = TAG_X + 36, y = TAG_Y + 182, z = 3 })
    D.line2 = newText(outer, { font = FONT_BODY, typeface = "Bold", size = 30, colour = LINE_AMBER, shadow = true,
                               wrapAt = TAG_W - 72 })
    place(D.canvas, D.line2, { x = TAG_X + 36, y = TAG_Y + 246, z = 3 })
    -- the current planet's name under the disc (the panel's own label sits behind our art)
    D.plName = newText(outer, { font = FONT_DISPLAY, size = 52, colour = INK_LIGHT, shadow = true, justify = 1 })
    local pn = sizeBox(outer, 900, nil)
    pn:AddChild(D.plName)
    place(D.canvas, pn, { ax = 0.5, x = PLANET_X, y = VH - 84, z = 2 })
    -- the node RISK CARD (right): event name, rule, reward rows, the red stake line, the team standings
    D.cardBack = solid(outer, { R = 0.004, G = 0.018, B = 0.024, A = 1.0 })
    D.cardSlot = place(D.canvas, D.cardBack, { anchor = { 1, 0 }, ax = 1, x = CARD_X, y = CARD_Y,
                                               size = { CARD_W, CARD_H }, z = 2 })
    local cx = CARD_X - CARD_W + 44                       -- text x, from the right anchor
    local function cardText(s, dy, extra)
        local t = newText(outer, extra or s)
        place(D.canvas, t, { anchor = { 1, 0 }, ax = 0, x = cx, y = CARD_Y + dy, z = 3 })
        return t
    end
    D.cKind = cardText({ font = FONT_DISPLAY, size = 56, colour = LINE_AMBER, shadow = true }, 28)
    D.cRule = cardText({ font = FONT_BODY, size = 30, colour = INK_LIGHT, wrapAt = CARD_W - 88 }, 122)
    D.cRewHdr = cardText({ font = FONT_BODY, typeface = "Bold", size = 28, colour = { R = 0.3613, G = 0.4564, B = 0.3763, A = 1 } }, 238)
    setPlain(D.cRewHdr, "REWARDS")
    D.cRew = {}
    for i = 1, 3 do
        D.cRew[i] = cardText({ font = FONT_BODY, typeface = "Bold", size = 34, colour = INK_LIGHT }, 238 + i * 56)
    end
    D.cLoss = cardText({ font = FONT_BODY, typeface = "Bold", size = 30,
                         colour = { R = 0.886, G = 0.412, B = 0.310, A = 1 }, wrapAt = CARD_W - 88 }, 476)
    D.cStandHdr = cardText({ font = FONT_BODY, typeface = "Bold", size = 28, colour = { R = 0.3613, G = 0.4564, B = 0.3763, A = 1 } }, 568)
    setPlain(D.cStandHdr, "THE TEAM")
    D.cStand = {}
    for i = 1, 4 do
        D.cStand[i] = cardText({ font = FONT_BODY, typeface = "Bold", size = 30, colour = INK_LIGHT }, 568 + i * 48)
    end
    -- the League's itinerary (idle state): one disc per planet + the finale, names underneath
    D.itin = {}
    D.itinName = newText(outer, { font = FONT_BODY, typeface = "Bold", size = 34, colour = INK_LIGHT, shadow = true,
                                  wrapAt = 2100 })
    place(D.canvas, D.itinName, { x = 1500, y = 760, z = 2 })
    show(D.itinName, false)
    -- the TOKENS chip (top right): a dark chip, the campaign's token icons as plain images (the WBP pip drew
    -- nothing live), amber when held, dim when lost
    -- the textures WBP_Cam_Strike_Entry itself uses (the Lg variants drew as solid squares, live)
    D.pipTex = { on = V().texture(tx("Icons/", "T_UI_Strike_Token_Icn")),
                 off = V().texture(tx("Icons/", "T_UI_Strike_Icn")) or V().texture(tx("Icons/", "T_UI_Strike_Token_Icn")) }
    D.pipChip = solid(outer, { R = 0.004, G = 0.018, B = 0.024, A = 1.0 })
    D.pipChipSlot = place(D.canvas, D.pipChip, { anchor = { 1, 0 }, ax = 1, x = CARD_X, y = CARD_Y,
                                                 size = { 300, 112 }, z = 2 })
    D.pipLbl = newText(outer, { font = FONT_BODY, typeface = "Bold", size = 26,
                                colour = { R = 0.3613, G = 0.4564, B = 0.3763, A = 1 } })
    place(D.canvas, D.pipLbl, { anchor = { 1, 0 }, ax = 1, x = CARD_X - 300 + 170, y = CARD_Y + 20, z = 3 })
    setPlain(D.pipLbl, "TOKENS")
    show(D.pipChip, false)
    show(D.pipLbl, false)
    if D.pipTex.on then
        for i = 1, 8 do
            local pip = mk(IMAGE, outer)
            if pip then
                pcall(function() pip:SetVisibility(VIS.HitTestInvisible) end)
                local ps = place(D.canvas, pip, { anchor = { 1, 0 }, ax = 1, x = CARD_X - 28 - (i - 1) * PIP_DX,
                                                  y = PIP_Y + 18, z = 4, size = { 64, 64 } })
                D.pips[i] = { w = pip, slot = ps }
                show(pip, false)
            end
        end
    end
    -- node pool + line pool (nodes created lazily on the first run refresh: icons need resident textures)
    local function newStrip()
        local im = solid(outer, LINE_OLIVE)
        local s = place(D.canvas, im, { x = -200, y = -200, size = { 5, 5 }, z = 1 })
        return { w = im, slot = s }
    end
    D.newStrip = newStrip
    U.log(TAG, "run page scene built (planet, %d pips, titles)", #D.pips)
    return D
end

local function decoDisc(D, i)
    local d = D.itin[i]
    if d then return d end
    local img = mk(IMAGE, W.tree)
    if not img then return nil end
    pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
    local slot = place(D.canvas, img, { x = -300, y = -300, size = { 170, 170 }, z = 2 })
    d = { w = img, slot = slot }
    D.itin[i] = d
    return d
end

local function decoNode(D, i)
    local nd = D.nodes[i]
    if nd then return nd end
    local cls = U.class(CLS_NODE)
    if not U.ok(cls) then error("node button class not found") end
    local b = U.WBL():Create(W.pc, cls, W.pc)
    if not U.ok(b) then error("Create(activity button) failed") end
    pcall(function() b.IsTooltipEnabled = false end)
    pcall(function() b:BP_SetIsFocusable(false) end)       -- the scene takes no focus, no clicks
    pcall(function() b:SetVisibility(VIS.HitTestInvisible) end)
    pcall(function() b:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    local slot = place(D.canvas, b, { ax = 0.5, ay = 0.5, x = -300, y = -300, z = 3 })
    nd = { w = b, slot = slot }
    D.nodes[i] = nd
    return nd
end

local function decoStrip(D, i)
    local st = D.strips[i]
    if not st then
        if i > STRIP_MAX then return nil end
        st = D.newStrip()
        D.strips[i] = st
    end
    return st
end

-- one elbow (the campaign's [From, Corner1, Corner2, To] polyline) out of up to 3 axis-aligned 5-su strips
local function elbow(D, used, x1, y1, x2, y2, colour, thick)
    local t = thick or 5
    local midX = math.floor(x1 + (x2 - x1) * 0.55)
    local parts = (y1 == y2) and { { x1, y1, x2, y2 } }
        or { { x1, y1, midX, y1 }, { midX, y1, midX, y2 }, { midX, y2, x2, y2 } }
    for _, p in ipairs(parts) do
        used.n = used.n + 1
        local st = decoStrip(D, used.n)
        if not st then return end
        pcall(function() st.w:SetColorAndOpacity(lin(colour)) end)
        if p[2] == p[4] then
            st.slot:SetPosition({ X = math.min(p[1], p[3]), Y = p[2] - t / 2 })
            st.slot:SetSize({ X = math.max(t, math.abs(p[3] - p[1]) + t / 2), Y = t })
        else
            st.slot:SetPosition({ X = p[1] - t / 2, Y = math.min(p[2], p[4]) - t / 2 })
            st.slot:SetSize({ X = t, Y = math.max(t, math.abs(p[4] - p[2]) + t) })
        end
        show(st.w, true)
    end
end

local function nodeXY(cols, c, i)
    local w = #cols[c]
    return GRAPH_X0 + (c - 1) * GRAPH_DX, GRAPH_CY + (i - (w + 1) / 2) * GRAPH_DY
end

-- the same reachability run.lua uses (a narrower next column rescales the path index)
local function reachSet(cols, c, i)
    local w1, w2 = #cols[c], #cols[c + 1]
    local base = i
    if w1 > 1 and w2 ~= w1 then base = math.floor((i - 1) * (w2 - 1) / (w1 - 1) + 0.5) + 1 end
    local out, seen = {}, {}
    for _, j in ipairs({ base - 1, base, base + 1 }) do
        local jj = math.max(1, math.min(w2, j))
        if not seen[jj] then seen[jj] = true; out[#out + 1] = jj end
    end
    return out
end

local function setPlanet(D, key)
    if D.plKey == key then return end
    local planets = nil
    pcall(function() planets = U.mod("setup").PLANETS end)
    local p = nil
    for _, e in ipairs(planets or {}) do if e.key == key then p = e end end
    if not p then show(D.pl, false); D.plKey = nil; return end
    local def = U.obj(p.path)
    local hi = V().texture(p.hires)
    if not (U.ok(def) and hi) then show(D.pl, false); D.plKey = nil; return end
    if not U.ok(D.pl) then
        local cls = U.class(CLS_PLANET)
        if not U.ok(cls) then error("WBP_RunMap_Planet_C not found") end
        local pl = U.WBL():Create(W.pc, cls, W.pc)
        if not U.ok(pl) then error("Create(WBP_RunMap_Planet_C) failed") end
        pl.PlanetDef = def
        pl.Planet = hi                                     -- before the add: PreConstruct draws this texture
        D.plSlot = place(D.canvas, pl, { x = PLANET_X - PANEL_W / 2, y = VH / 2 - PANEL_H / 2,
                                         size = { PANEL_W, PANEL_H }, z = 0 })
        pcall(function() pl:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
        pcall(function() pl:SetRenderScale({ X = PLANET_SCALE, Y = PLANET_SCALE }) end)
        pcall(function() pl:SetVisibility(VIS.HitTestInvisible) end)
        D.pl = pl
    else
        D.pl.PlanetDef = def
        pcall(function() D.pl.Planet = hi end)
    end
    local ok = pcall(function() D.pl:SetPlanetInfo(true) end)   -- active: turning ring, dashes, sonar pulse
    pcall(function() D.pl.B_TextColor:SetVisibility(VIS.Collapsed) end)   -- our own name label under the disc
    show(D.pl, ok)
    -- the panel's own Img_Planet renders flat on this page (live 2026-10-13: the brush holds the texture, nothing
    -- draws), so the planet ART is our own image over the disc: the colourful select art, like the campaign's
    -- overview carousel
    local okArt = pcall(function()
        if not D.plArt then
            local img = mk(IMAGE, W.tree)
            pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
            D.plArtSlot = place(D.canvas, img, { ax = 0.5, ay = 0.5, x = PLANET_X, y = VH / 2,
                                                 size = { 860, 860 }, z = 1 })
            pcall(function() D.plArtSlot:SetAutoSize(false) end)
            D.plArt = img
        end
        local sel = nil
        for _, e in ipairs((function() local okP, pl2 = pcall(function() return U.mod("setup").PLANETS end)
            return okP and pl2 or {} end)()) do
            if e.key == key then sel = V().texture(e.select) end
        end
        if sel then
            D.plArt:SetBrushFromTexture(sel, false)
            show(D.plArt, true)
        else
            show(D.plArt, false)
        end
    end)
    if not okArt and D.plArt then show(D.plArt, false) end
    if D.plName then setPlain(D.plName, p.name or key) end
    D.plKey = ok and key or nil
end

local function fmtCr(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    if #s > 3 then s = s:sub(1, #s - 3) .. " " .. s:sub(-3) end
    return s
end

local ORD = { "1ST", "2ND", "3RD" }

-- everything the scene shows, from the run state; errors tear the scene down (rows mode stays)
local function decoRefresh()
    local D = W.deco
    if not D then return end
    local R = run()
    local st, active, between, flight = nil, false, false, false
    pcall(function()
        st = R.state(); active = R.active(); between = R.betweenRaces(); flight = R.inFlight()
    end)
    local usedN, used = 0, { n = 0 }
    local pre = nil
    if st then pcall(function() pre = R._data() and R._data().presets[st.preset] or nil end) end
    -- planet + headline
    if active and st then
        local bossPhase = st.bossIdx ~= nil or (st.next and st.next.boss)
        local planetKey = bossPhase and (pre and pre.boss[1].planet) or
            (pre and st.cursor and pre.planets[math.min(st.cursor.p or 1, #pre.planets)])
        if st.next and not st.next.boss and pre and st.next.p then planetKey = pre.planets[st.next.p] end
        setPlanet(D, planetKey)
        setPlain(D.line1, string.format("%s · RACE %d / %d", R.presetName(st.preset), st.race or 1, st.length or 0))
        local kind = (st.next and st.next.kind) or (st.flight and st.flight.kind) or "standard"
        -- the goal sentence (the campaign map's "Reach Derven Acos to challenge the Qualifier Champion.")
        local goalName, antName = "THE FINALE", "THE CHAMPION"
        pcall(function()
            local bossKey = pre.boss[1].planet
            for _, e in ipairs(U.mod("setup").PLANETS) do if e.key == bossKey then goalName = e.name end end
            antName = pre.antagonist.name or antName
        end)
        if flight then
            setPlain(D.line2, "RACE IN FLIGHT — FINISH IT, LEAVING EARLY RACES IT AGAIN")
        elseif st.status == "won" then
            setPlain(D.line2, "RUN WON — " .. (R.leaderText() or ""))
        elseif st.status == "lost" then
            setPlain(D.line2, "OUT OF LEAGUE TOKENS — " .. (R.leaderText() or ""))
        else
            setPlain(D.line2, string.format("REACH %s — BEAT %s WITH THE TEAM", goalName, antName))
        end
        -- the tokens chip: sized to the pip count
        local maxT = math.min(8, st.tokensMax or st.hull or 0)
        local chipW = 48 + maxT * PIP_DX + 170
        pcall(function() D.pipChipSlot:SetSize({ X = chipW, Y = 112 }) end)
        pcall(function() D.pipLbl.Slot:SetPosition({ X = CARD_X - 28 - maxT * PIP_DX - 20, Y = CARD_Y + 34 }) end)
        show(D.pipChip, false)                            -- the card's own fill is the chip now
        show(D.pipLbl, maxT > 0)
        for i = 1, 8 do
            local pip = D.pips[i]
            if pip then
                if i <= maxT then
                    local held = i <= (st.hull or 0)
                    local tex = held and D.pipTex.on or (D.pipTex.off or D.pipTex.on)
                    pcall(function()
                        pip.w:SetBrushFromTexture(tex, false)
                        pip.w:SetColorAndOpacity(held and { R = 0.745, G = 0.413, B = 0.080, A = 1 }
                            or { R = 0.30, G = 0.30, B = 0.28, A = 0.9 })
                    end)
                    show(pip.w, true)
                else
                    show(pip.w, false)
                end
            end
        end
        -- the RISK CARD of the picked node (the campaign map's risk/reward panel)
        local showCard = (between or flight) and st.status == "on"
        show(D.cardBack, showCard)
        show(D.cKind, showCard)
        show(D.cRule, showCard)
        if showCard then
            local ev = R.eventOf(kind)
            local where = (st.next and (st.next.planetName or st.next.planet)) or
                (st.flight and st.flight.planet) or ""
            setPlain(D.cKind, tostring(ev.name))
            setPlain(D.cRule, flight and ("ON THE TRACK NOW · " .. tostring(where)) or tostring(ev.rule))
            local showRew = not flight
            show(D.cRewHdr, showRew)
            for i = 1, 3 do
                if showRew then
                    local okP, cr = pcall(R.payoutPreview, i, kind)
                    setPlain(D.cRew[i], string.format("%s   %s CR", ORD[i], fmtCr(okP and cr or 0)))
                end
                show(D.cRew[i], showRew)
            end
            local okT, t = pcall(R.targetText, kind)
            if showRew and okT and t then
                setPlain(D.cLoss, (kind == "highrisk" and "MISS THE TOP 3 — THE TEAM LOSES A LEAGUE TOKEN")
                    or (kind == "planesprint" and "A PLAYER NOT FINISHING COSTS A LEAGUE TOKEN")
                    or "MUST-WIN — LOSING IT COSTS A LEAGUE TOKEN")
                show(D.cLoss, true)
            else
                show(D.cLoss, false)
            end
        else
            show(D.cRewHdr, false)
            for i = 1, 3 do show(D.cRew[i], false) end
            show(D.cLoss, false)
        end
        -- the team, in the card's footer
        local okS, list = pcall(R.standingsRows)
        show(D.cStandHdr, showCard)
        for i = 1, 4 do
            local e = showCard and okS and type(list) == "table" and list[i] or nil
            if e then
                setPlain(D.cStand[i], string.format("%s · %d PTS · %s CR%s", tostring(e.name), e.points or 0,
                    fmtCr(e.credits or 0), e.pending and " · PICK WAITING" or ""))
                show(D.cStand[i], true)
            else
                show(D.cStand[i], false)
            end
        end
        -- the node graph of the current planet (or the boss event)
        if bossPhase or not (pre and st.maps and st.cursor) then
            if bossPhase and st.next and st.next.boss then
                local nd = decoNode(D, 1)
                usedN = 1
                local tex = V().texture(TEXK[st.next.kind or "champion"] or TEXK.champion)
                if tex then pcall(function() nd.w.Img_Activity:SetBrushFromTexture(tex, false) end) end
                pcall(function() nd.w.NodeState = 1; nd.w:RefreshNodeFromState() end)
                pcall(function() nd.w:SetRenderScale({ X = 2.6, Y = 2.6 }) end)
                nd.slot:SetPosition({ X = GRAPH_X0 + GRAPH_DX, Y = GRAPH_CY })
                show(nd.w, true)
            end
        else
            local p = st.cursor.p or 1
            if st.next and not st.next.boss and st.next.p then p = st.next.p end
            local map = st.maps[p]
            if map then
                local cols = map.cols
                local curC = (st.cursor.p == p) and st.cursor.c or 0
                -- lines first (under the nodes)
                for c = 1, map.days - 1 do
                    for i = 1, #cols[c] do
                        local x1, y1 = nodeXY(cols, c, i)
                        for _, j in ipairs(reachSet(cols, c, i)) do
                            local x2, y2 = nodeXY(cols, c + 1, j)
                            local colr, th = LINE_OLIVE, 5
                            if c == curC and i == st.cursor.i then
                                if st.next and st.next.c == c + 1 and st.next.i == j then
                                    colr, th = LINE_AMBER, 11            -- the picked path, unmistakable
                                else
                                    colr, th = INK_FOCUS, 7
                                end
                            elseif c < curC then
                                colr = LINE_DIM
                            end
                            elbow(D, used, x1 + 90, y1, x2 - 90, y2, colr, th)
                        end
                    end
                end
                -- nodes
                for c = 1, map.days do
                    for i = 1, #cols[c] do
                        usedN = usedN + 1
                        local nd = decoNode(D, usedN)
                        local tex = V().texture(TEXK[cols[c][i]] or TEXK.standard)
                        if tex then pcall(function() nd.w.Img_Activity:SetBrushFromTexture(tex, false) end) end
                        local state = 2                                      -- grey: not on the path yet
                        if c < curC or (c == curC and i == st.cursor.i) then state = 0 end   -- amber: behind us
                        if c == curC + 1 then
                            for _, j in ipairs(reachSet(cols, curC, st.cursor.i or 1)) do
                                if j == i then state = 1 end                  -- cream: reachable now
                            end
                        end
                        pcall(function() nd.w.NodeState = state; nd.w:RefreshNodeFromState() end)
                        local sel = st.next and st.next.c == c and st.next.i == i and not st.next.boss
                        local k = sel and NODE_SCALE_SEL or NODE_SCALE
                        pcall(function() nd.w:SetRenderScale({ X = k, Y = k }) end)
                        local x, y = nodeXY(cols, c, i)
                        nd.slot:SetPosition({ X = x, Y = y })
                        show(nd.w, true)
                    end
                end
            end
        end
    else
        -- no run: the picked League's first planet, the itinerary discs and the pitch
        local key = tostring(settings.get("RunPick") or "qualifier")
        local okD, data = pcall(function() return R._data() end)
        local preIdle = okD and data and data.presets and data.presets[key] or nil
        setPlanet(D, preIdle and preIdle.planets[1] or "Mastiff")
        local lbl = key
        pcall(function() lbl = R.presetLabel(key) end)
        if st and (st.status == "won" or st.status == "lost") then
            local okT2, t2 = pcall(R.statusText)
            setPlain(D.line1, (okT2 and t2) or "")
            setPlain(D.line2, "NEXT: " .. tostring(lbl))
        else
            setPlain(D.line1, "NO RUN — PICK A LEAGUE AND START")
            setPlain(D.line2, tostring(lbl))
        end
        -- itinerary: one disc per planet, then the finale's
        local planets = nil
        pcall(function() planets = U.mod("setup").PLANETS end)
        local function discTex(k)
            for _, e in ipairs(planets or {}) do if e.key == k then return e.select, e.name end end
            return nil, tostring(k)
        end
        local usedD, names = 0, {}
        if preIdle then
            local chain = {}
            for _, k in ipairs(preIdle.planets) do chain[#chain + 1] = k end
            local bossKey = preIdle.boss[1] and preIdle.boss[1].planet or nil
            for ci, k in ipairs(chain) do
                local d = decoDisc(D, ci)
                local texPath, nm = discTex(k)
                local tex = texPath and V().texture(texPath) or nil
                if d and tex then
                    pcall(function() d.w:SetBrushFromTexture(tex, false) end)
                    d.slot:SetPosition({ X = 1500 + (ci - 1) * 210, Y = 500 })
                    show(d.w, true)
                    usedD = ci
                end
                names[#names + 1] = nm
            end
            if bossKey then
                local d = decoDisc(D, usedD + 1)
                local texPath, nm = discTex(bossKey)
                local tex = texPath and V().texture(texPath) or nil
                if d and tex then
                    pcall(function() d.w:SetBrushFromTexture(tex, false) end)
                    d.slot:SetPosition({ X = 1500 + usedD * 210 + 80, Y = 500 })
                    show(d.w, true)
                    usedD = usedD + 1
                end
                names[#names + 1] = "FINALE: " .. nm
            end
        end
        for i = usedD + 1, #D.itin do if D.itin[i] then show(D.itin[i].w, false) end end
        setPlain(D.itinName, table.concat(names, " · "))
        show(D.itinName, #names > 0)
        -- no run: no chip, no card
        for i = 1, 8 do if D.pips[i] then show(D.pips[i].w, false) end end
        show(D.pipChip, false)
        show(D.pipLbl, false)
        show(D.cardBack, false)
        show(D.cKind, false)
        show(D.cRule, false)
        show(D.cRewHdr, false)
        for i = 1, 3 do show(D.cRew[i], false) end
        show(D.cLoss, false)
        show(D.cStandHdr, false)
        for i = 1, 4 do show(D.cStand[i], false) end
    end
    if active and st then
        show(D.itinName, false)
        for i = 1, #D.itin do if D.itin[i] then show(D.itin[i].w, false) end end
    end
    for i = usedN + 1, #D.nodes do show(D.nodes[i].w, false) end
    for i = used.n + 1, #D.strips do show(D.strips[i].w, false) end
end

local function decoDown(why)
    if W and W.deco then
        show(W.deco.box, false)
        W.deco = nil
        U.warn(TAG, "run page scene off (%s): plain rows stay", tostring(why))
    end
end

---------------------------------------------------------------------------------------------------- build
-- lobby.build calls this right after setup.build, on the same page root. Failure = no page (the poster falls back
-- to the pre-page behaviour); never an error out of here.
function M.build(root, pc, page)
    W = nil
    if not (U.ok(root) and U.ok(pc) and U.ok(page)) then return false end
    local okT, tree = pcall(U.getField, page, "WidgetTree")
    if not okT or not U.ok(tree) then U.warn(TAG, "no WidgetTree: the run page is off"); return false end
    -- the page root: an overlay whose first child is a canvas holding the GALAXY backdrop (Jules: "dark bg... a view
    -- of the galaxy and stars"): a near-black fill + T_UI_Starfield_BG, placed at negative page coordinates on open so
    -- they cover the whole screen, tab bar included (theme.pageBackground's trick); the content VBox on top
    local outerOv = mk(OVER, tree)
    if not outerOv then U.warn(TAG, "run page overlay not created"); return false end
    ui().addRow(root, outerOv)
    local bg = {}
    local okBG = pcall(function()
        local cv = mk(CANVAS, tree)
        local cs = outerOv:AddChildToOverlay(cv)
        if U.ok(cs) then cs:SetHorizontalAlignment(0); cs:SetVerticalAlignment(0) end
        bg.dark = solid(tree, { R = 0.002, G = 0.006, B = 0.012, A = 1 })
        bg.darkSlot = place(cv, bg.dark, { x = 0, y = 0, size = { 10, 10 }, z = 0 })
        local star = V().texture(tx("Backgrounds/", "T_UI_Starfield_BG"))
        if star then
            bg.star = mk(IMAGE, tree)
            bg.star:SetBrushFromTexture(star, false)
            bg.star:SetVisibility(VIS.HitTestInvisible)
            bg.starSlot = place(cv, bg.star, { x = 0, y = 0, size = { 10, 10 }, z = 1 })
        end
        bg.canvas = cv
    end)
    if not okBG then U.warn(TAG, "galaxy backdrop failed: the page stays on the menu background"); bg = {} end
    local panel = mk(VBOX, tree)
    if not panel then U.warn(TAG, "run page panel not created"); return false end
    local pSlot = outerOv:AddChildToOverlay(panel)
    if U.ok(pSlot) then pcall(function() pSlot:SetHorizontalAlignment(0); pSlot:SetVerticalAlignment(0) end) end
    local w = { pc = pc, panel = outerOv, content = panel, tree = tree, root = root, bg = bg }
    local UI = ui()
    local okD, deco = pcall(buildDeco, w.content, tree, pc)
    w.deco = okD and deco or nil
    if not okD then U.warn(TAG, "run page scene not built (%s): plain rows", tostring(deco)) end
    -- with the scene on, the action rows sit on their own dark strip (they wash out on the page paper)
    local host = w.content
    if w.deco then
        local okH, innerVB = pcall(function()
            local box = sizeBox(tree, 2000, nil)
            local slot = w.content:AddChildToVerticalBox(box)
            if U.ok(slot) then
                pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 6 }) end)
                pcall(function() slot:SetHorizontalAlignment(C.E.HAlign.Center) end)
            end
            local over = mk(OVER, tree)
            box:AddChild(over)
            local back = solid(tree, { R = 0.004, G = 0.018, B = 0.024, A = 0.93 })
            local bs = over:AddChildToOverlay(back)
            if U.ok(bs) then pcall(function() bs:SetHorizontalAlignment(0); bs:SetVerticalAlignment(0) end) end
            local vb = mk(VBOX, tree)
            local vs = over:AddChildToOverlay(vb)
            if U.ok(vs) then pcall(function() vs:SetHorizontalAlignment(0); vs:SetVerticalAlignment(0) end) end
            return vb
        end)
        if okH and U.ok(innerVB) then host = innerVB end
    end
    local function add(widget, top, bottom)
        if widget then UI.addRow(host, widget, top, bottom) end
        return widget
    end
    local function btn(id, text, fn) return add(UI.button(pc, "runpage:" .. id, text, fn)) end
    local function lbl(text) return add(UI.label(pc, text)) end
    w.header   = add(UI.header(pc, "GALAXY RUN"), 8, 8)
    w.status   = lbl("")
    w.target   = lbl("")
    w.continue = btn("continue", "CONTINUE", function() M.onContinue() end)
    w.node     = btn("node", "NEXT NODE", function() M.onNode() end)
    w.stand    = {}
    for i = 1, 4 do w.stand[i] = lbl("") end
    w.pending  = lbl("")
    w.league   = btn("league", "LEAGUE", function() M.onLeague() end)
    w.newrun   = btn("newrun", "START NEW RUN", function() M.onNewRun() end)
    w.hint     = lbl("")
    w.abandon  = btn("abandon", "END THE RUN", function() M.onAbandon() end)
    w.back     = add(UI.button(pc, "runpage:back", "BACK", function() M.close("BACK row") end), 10, 4)
    UI.setShown(outerOv, false)                    -- the whole page (backdrop included) hides until open
    W = w
    U.log(TAG, "run page built (12 rows, scene %s)", w.deco and "on" or "off")
    return true
end

function M.forget()
    tabSaved = nil                                        -- the tab buttons die with the menu
    W = nil
    S.active = false
end

function M.active() return S.active and W ~= nil end

---------------------------------------------------------------------------------------------------- texts
local function pickKey()
    local v = tostring(settings.get("RunPick") or "qualifier")
    local okP, list = pcall(function() return run().presets() end)
    if okP and type(list) == "table" then
        for _, p in ipairs(list) do if p.key == v then return v end end
        if list[1] then return list[1].key end
    end
    return "qualifier"
end

local function setShown(widget, on) pcall(function() ui().setShown(widget, on) end) end
local function setBtn(widget, text) pcall(function() ui().setButtonText(widget, text) end) end
local function setLbl(widget, text) pcall(function() ui().setLabelText(widget, text) end) end

-- All texts and row visibility from the run's state. Safe on any state (no run / armed / between / flight / over).
function M.refresh()
    if not W then return end
    local R = run()
    local st, active, between, flight = nil, false, false, false
    pcall(function()
        st = R.state()
        active = R.active()
        between = R.betweenRaces()
        flight = R.inFlight()
    end)
    local deco = W.deco ~= nil
    local rows = {}                                   -- id -> shown
    local statusText = ""
    if active and st then
        statusText = string.format("RACE %d / %d · TOKENS %d OF %d", st.race or 1, st.length or 0, st.hull or 0,
            st.tokensMax or st.hull or 0)
        local kind = (st.next and st.next.kind) or "standard"
        local okT, t = pcall(R.targetText, kind)
        setLbl(W.target, (okT and t) and ("TARGET " .. t .. " — OR THE TEAM LOSES A LEAGUE TOKEN") or "")
        rows.target = between and okT and t ~= nil and not deco
        if between and st.next then
            local okE, ev = pcall(R.eventOf, kind)
            local name = okE and ev.name or "RACE"
            setBtn(W.continue, string.format("CONTINUE · %s · %s", name,
                tostring(st.next.planetName or st.next.planet or "?")))
            rows.continue = true
            local n = (type(st.options) == "table") and #st.options or 0
            if n > 1 then
                setBtn(W.node, string.format("NEXT NODE %d / %d: %s · %s", st.choice or 1, n, name,
                    tostring(st.next.planetName or st.next.planet or "?")))
                rows.node = true
            end
        elseif flight then
            statusText = statusText .. " · RACE IN FLIGHT"
            setLbl(W.target, "FINISH THE RACE — LEAVING IT EARLY RACES IT AGAIN")
            rows.target = not deco
        end
        local okS, list = pcall(R.standingsRows)
        if okS and type(list) == "table" and not deco then
            for i = 1, 4 do
                local e = list[i]
                if e then
                    setLbl(W.stand[i], string.format("%s · %d PTS · %d CR · CAP %d%s", tostring(e.name),
                        e.points or 0, e.credits or 0, e.cap or 1, e.pending and " · PICK WAITING" or ""))
                    rows["stand" .. i] = true
                end
            end
        end
        setLbl(W.pending, "REWARDS AND THE SHOP OPEN ON EACH RACER CARD — PRESS CONTINUE")
        rows.pending = between and not deco
        rows.abandon = true
    else
        if st and (st.status == "won" or st.status == "lost") then
            local okT, t = pcall(R.statusText)
            statusText = (okT and t) or string.upper(tostring(st.status))
        else
            statusText = "NO RUN — PICK A LEAGUE AND START"
        end
        local key = pickKey()
        local okL, lbl = pcall(R.presetLabel, key)
        setBtn(W.league, "LEAGUE: " .. ((okL and lbl) or string.upper(key)))
        setBtn(W.newrun, "START NEW RUN")
        setLbl(W.hint, "EVERYONE STARTS ON A STARTER BUILD · REWARDS AND THE SHOP ARE ON YOUR RACER CARD")
        rows.league, rows.newrun = true, true
        rows.hint = not deco
    end
    setLbl(W.status, statusText)
    setShown(W.header, not deco)
    setShown(W.status, not deco)
    for id, widget in pairs({ continue = W.continue, node = W.node, pending = W.pending, league = W.league,
                              newrun = W.newrun, hint = W.hint, abandon = W.abandon, target = W.target,
                              stand1 = W.stand[1], stand2 = W.stand[2], stand3 = W.stand[3], stand4 = W.stand[4] }) do
        setShown(widget, rows[id] == true)
    end
    if deco then
        local okD, errD = pcall(decoRefresh)
        if not okD then
            decoDown(errD)
            M.refresh()                                   -- once more in rows mode (deco is nil now)
        end
    end
end

---------------------------------------------------------------------------------------------------- galaxy backdrop
-- The backdrop canvas sits in the page's content area; its two images go to negative page coordinates so they
-- cover the whole 3840 x 2160 screen (theme.pageBackground's trick, V-FIN-02).
local function placeBackdrop()
    local bg = W and W.bg
    if not (bg and bg.darkSlot) then return end
    local gx, gy, sw, sh = 128, 240, 3840, 2160
    pcall(function()
        local geo = U.mod("theme").pageGeometry(W.root)
        if type(geo) == "table" and tonumber(geo.x) then
            gx, gy = geo.x, geo.y
            if type(geo.screen) == "table" and tonumber(geo.screen.w) then sw, sh = geo.screen.w, geo.screen.h end
        end
    end)
    pcall(function() bg.darkSlot:SetPosition({ X = -gx, Y = -gy }); bg.darkSlot:SetSize({ X = sw, Y = sh }) end)
    if bg.starSlot then
        -- cover the screen keeping the starfield's aspect (scale to the larger side)
        pcall(function() bg.starSlot:SetPosition({ X = -gx, Y = -gy }); bg.starSlot:SetSize({ X = sw, Y = sh }) end)
    end
end

-- The top menu inverted while the page shows (Jules: "invert the colors of the top menu"): the tab labels go cream
-- on the starfield; the originals come back on close.
local CREAM = { R = 1.0, G = 0.8632, B = 0.6724, A = 1 }
local tabSaved = nil
local function tabButtons()
    local out = {}
    pcall(function()
        for _, b in ipairs(FindAllOf("WBP_Tab_Btn_C") or {}) do
            if U.ok(b) and U.ok(b.Txt_Label) then out[#out + 1] = b end
        end
    end)
    return out
end

local function invertTabs(on)
    if opt("RunPageInvertTabs", true) == false then return end
    if on then
        if tabSaved then return end
        tabSaved = {}
        for _, b in ipairs(tabButtons()) do
            local sel = false
            pcall(function() sel = b:GetSelected() == true end)
            local okC, col = pcall(function()
                local c = b.UnselectColor.SpecifiedColor
                return { R = c.R, G = c.G, B = c.B, A = c.A }
            end)
            tabSaved[#tabSaved + 1] = { b = b, col = okC and col or nil, sel = sel }
            pcall(function() b.UnselectColor = { SpecifiedColor = CREAM, ColorUseRule = 0 } end)
            if not sel then
                pcall(function() b.Txt_Label:SetColorAndOpacity({ SpecifiedColor = CREAM, ColorUseRule = 0 }) end)
            end
        end
        U.log(TAG, "top menu inverted (%d tab label(s) cream)", #tabSaved)
    else
        if not tabSaved then return end
        for _, e in ipairs(tabSaved) do
            if U.ok(e.b) and e.col then
                pcall(function() e.b.UnselectColor = { SpecifiedColor = e.col, ColorUseRule = 0 } end)
                local sel = false
                pcall(function() sel = e.b:GetSelected() == true end)
                if not sel then
                    pcall(function() e.b.Txt_Label:SetColorAndOpacity({ SpecifiedColor = e.col, ColorUseRule = 0 }) end)
                end
            end
        end
        tabSaved = nil
        U.log(TAG, "top menu colours restored")
    end
end

---------------------------------------------------------------------------------------------------- open / close
local function focusFirst()
    for _, widget in ipairs({ W.continue, W.league, W.back }) do
        local shown = false
        pcall(function() shown = widget:GetVisibility() ~= VIS.Collapsed end)
        if shown then
            pcall(function() widget:SetFocus() end)
            return
        end
    end
end

function M.open()
    if not W then return false end
    if St.phase ~= "FRONTEND" or St.launch.pending then return false end
    if S.active then M.refresh(); return true end
    local okM, lobby = pcall(U.mod, "lobby")
    if okM and type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, true) end
    S.active = true
    S.abandonUntil, S.abandonArmedMs = 0, -1e12
    M.refresh()
    pcall(function() ui().setShown(W.panel, true) end)
    U.try(TAG, placeBackdrop)
    U.try(TAG, invertTabs, true)
    U.try(TAG, focusFirst)
    sound("RunMap_Open")
    U.log(TAG, "run page opened (scene %s)", W.deco and "on" or "off")
    return true
end

function M.close(why)
    if not S.active then return end
    S.active = false
    if W then pcall(function() ui().setShown(W.panel, false) end) end
    U.try(TAG, invertTabs, false)
    local okM, lobby = pcall(U.mod, "lobby")
    if okM and type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, false) end
    sound("RunMap_Paddock_Close")
    U.log(TAG, "run page closed (%s)", tostring(why))
end

---------------------------------------------------------------------------------------------------- actions
function M.onContinue()
    if not S.active then return end
    sound("RunMap_EventClick_Accept")
    M.close("CONTINUE")
    local ok, handled = pcall(function() return run().openNext() end)
    if not (ok and handled == true) then
        St.emit("status", "GALAXY RUN: THE NEXT RACE DID NOT OPEN — TRY START")
    end
end

function M.onNode()
    if not S.active then return end
    pcall(function() run().switchRoute() end)          -- emits the route status line itself
    sound("RunMap_PlanetSelect")
    M.refresh()
end

function M.onLeague()
    if not S.active then return end
    local cur = pickKey()
    local keys = {}
    pcall(function() for _, p in ipairs(run().presets()) do keys[#keys + 1] = p.key end end)
    if #keys == 0 then return end
    local nxt = keys[1]
    for i, k in ipairs(keys) do if k == cur then nxt = keys[i % #keys + 1] end end
    settings.set("RunPick", nxt)
    if tostring(settings.get("RunLength") or "off") ~= "off" then settings.set("RunLength", nxt) end
    sound("RunMap_PlanetSelect")
    M.refresh()
end

function M.onNewRun()
    if not S.active then return end
    local pick = pickKey()
    settings.set("RunLength", pick)
    local label = pick
    pcall(function() label = run().presetLabel(pick) end)
    sound("RunMap_EventClick_Accept")
    M.close("START NEW RUN")
    St.emit("status", "GALAXY RUN: THE NEXT RACE STARTS " .. tostring(label))
    local opened = false
    pcall(function() opened = U.mod("setup").open() == true end)
    if not opened then U.try(TAG, function() U.mod("builder").open() end) end
end

-- B04 (live 2026-10-15, P1): Jules's B on this page "dropped" the run and the next B quit the game. END THE RUN is an
-- explicit two-press confirm on its own row: the second A counts only ABANDON_GAP_MS after the first (one press can
-- not be read twice) and only when no B / Quit prompt came in between (a B always means "keep it"). Both presses log.
local ABANDON_GAP_MS = 400
local function ABANDON_WINDOW() return U.confirmMs() end      -- couch-fix59 AUTO-145e: one window (5 s) for every confirm
local function recentBack(sinceMs)
    if S.backMs >= sinceMs then return true end
    local ok, t = pcall(function() return U.mod("backprompt").lastQuitPostMs() end)
    return ok and type(t) == "number" and t >= sinceMs
end

function M.onAbandon()
    if not S.active then return end
    local now = St.nowMs()
    local R = run()
    local isOn = false
    pcall(function() isOn = R.active() end)
    if not isOn then M.refresh(); return end
    if now <= S.abandonUntil and now - S.abandonArmedMs < ABANDON_GAP_MS then
        U.log(TAG, "END THE RUN: second press %d ms after the first ignored (one press)", math.floor(now - S.abandonArmedMs))
        return
    end
    if now <= S.abandonUntil and recentBack(S.abandonArmedMs) then
        S.abandonUntil = 0
        U.log(TAG, "END THE RUN: a B came between the presses: the run is kept")
        St.emit("status", "GALAXY RUN KEPT")
        return
    end
    if now <= S.abandonUntil then
        S.abandonUntil = 0
        U.log(TAG, "END THE RUN confirmed (second A %d ms after the first)", math.floor(now - S.abandonArmedMs))
        pcall(function() R.abandon("run page") end)
        settings.set("RunLength", "off")
        St.emit("status", "GALAXY RUN ABANDONED")
        M.refresh()
    else
        S.abandonUntil, S.abandonArmedMs = now + ABANDON_WINDOW(), now
        U.log(TAG, "END THE RUN armed: A again within %d ms ends the run, B keeps it", ABANDON_WINDOW())
        St.emit("status", "END THE GALAXY RUN? PRESS A AGAIN · B KEEPS IT")
    end
end

-- B04: P1's B on the run page = back to the lobby (never the game's Exit prompt, never END THE RUN). Called by the
-- lobby's B edge poll (P1's PlayerController sees pad B after a race) and by backprompt.lua (the game's QuitGame
-- prompt posted over this page: answered No out of sight).
function M.onP1Back(why)
    S.backMs = St.nowMs()
    S.abandonUntil = 0
    if not S.active then return false end
    M.close(why or "pad B")
    return true
end
function M.lastP1BackMs() return S.backMs end

-- lobby.onKey forwards while the page is open: Backspace closes, everything else is CommonUI's.
function M.onKey(name)
    if not S.active then return end
    if name == "back2" or name == "back" then M.close("keyboard back") end
end

---------------------------------------------------------------------------------------------------- events
function M.init()
    St.on("phase", TAG, function(new)
        if S.active and new ~= "FRONTEND" then M.close("phase " .. tostring(new)) end
    end)
    St.on("tab", TAG, function(shown)
        if S.active and shown == false then M.close("tab left") end
    end)
end

-- tests: the page's open flag without a built page (tools/test_runpage_back.lua)
function M._setActive(on) S.active = on == true end

function M.status()
    return string.format("runpage: %s, built %s, scene %s", S.active and "open" or "closed",
        W ~= nil and "yes" or "no", (W and W.deco) and "on" or "off")
end

return M
