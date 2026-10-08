-- cmap.lua (G3 Front-end UI, 0.9.0): campaign-style PLANET and TRACK views of the RACE SETUP (setup.lua).
-- User request 2026-10-07: "In split screen, the planet selection should be similar to the one in campaign, with
-- planets moving and then the circuit for each one."
--
-- PLANET view = the campaign planet overview (WBP_RunMapOverview_Presentation) rebuilt around its reusable part:
--   * WBP_PlanetSelector_C, the campaign's own planet arc. SetPlanetVms(Array<PlanetDef>, idx) makes one
--     WBP_Diegetic_MapOverview_Btn per planet on a 7200-su circle; its Tick (UpdateButtonPos) slides the arc so the
--     selected planet rests at the top; SetSelectedIndex expands it (220 -> 660 su) and plays the game's scroll sound.
--     ArcAngleDeg 35 / SelectionPadAngle 2 as in the campaign's instance (max(35, 5.85 n) so 7 planets do not touch),
--     the 7200 box render-scaled by SetupCMapArcScale about the selected planet's point (pivot 0.5, 0.01).
--   * under the selected planet, the overview's info block (VB_PlanetInfo layout: Aurebesh line, Font_Display 75
--     name, GameDescriptionText in DT_RichText_Body_Dark_Italic) plus the track count; the arrival video beside it;
--   * a row of planet chips (WBP_Common_Btn) under the arc is the control: P1's CommonUI focus on chip i selects
--     planet i (the arc slides), A on it chooses (setup.lua's focus poll and click poll, as for its list rows).
--     The planet buttons themselves stay display only (not focusable; the toggle-click trick would fight their
--     Anim_Expand); the selector is HitTestInvisible and never activated.
-- TRACK view = a single-planet campaign run map (the WBP_RunMap_Presentation look; that screen needs a campaign view
--   model): a 3840 x 1500 virtual map (ScaleToFit) on T_UI_MapEvent_Bg, the big planet (WBP_RunMap_Planet, active:
--   turning ring, sonar pulse), one row per circuit (track display name), one node per variant
--   (WBP_RunMap_Activity_Presentation_Btn with no MapNode: RefreshFromMapNode returns at its IsValid guard and
--   IconActivity + NodeState drive the look; icon = race / point to point / reverse / mines / scorching / podracer),
--   olive path lines (amber on the focused row), short variant labels and a detail card (WBP_Tooltip_Holder: track
--   art, planet and class, laps, variant, conditions). P1 moves between nodes with the d-pad (CommonUI geometric
--   navigation over the canvas), A chooses (toggle-click trick: the nodes have no select handlers).
-- Static research: notes/research/campaign-map/01-overview-carousel.md, 02-runmap-circuits.md, 03-lua-integration.md.
-- Never used here: the campaign screens themselves, CampaignSubsystem, a node's SetNavigation (campaign view model),
-- SetBrushFromSoftTexture from Lua, ActivateWidget on the selector.
-- Every game call is guarded. A failure marks the view broken: setup.lua then shows the 0.8.0 lists for that step.
-- VERIFY ids V-CMAP-01..12 (README §9 "0.9.0 checks").

local C   = require("consts")
local cfg = require("config")
local U   = require("util")
local V   = require("vehicles")

local M = {}
local TAG = "cmap"

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

---------------------------------------------------------------------------------------------------- assets
local RM = "/Game/Griffin/UI/Widgets/RunMap/"
local CLS_SELECTOR = RM .. "WBP_PlanetSelector.WBP_PlanetSelector_C"
local CLS_PLANET   = RM .. "WBP_RunMap_Planet.WBP_RunMap_Planet_C"
local CLS_NODE     = RM .. "WBP_RunMap_Activity_Presentation_Btn.WBP_RunMap_Activity_Presentation_Btn_C"
local CLS_CARD     = "/Game/Griffin/UI/Widgets/Decorative/WBP_Tooltip_Holder.WBP_Tooltip_Holder_C"
local TX = "/Game/Griffin/UI/Library/Textures/"
local function tx(sub, n) return TX .. sub .. n .. "." .. n end
local TEX = {
    mapBg   = tx("Backgrounds/", "T_UI_Map_Bg"),           -- campaign overview background (beige paper map)
    eventBg = tx("Backgrounds/", "T_UI_MapEvent_Bg"),      -- campaign run map background (dark teal)
    race    = tx("Icons/Map/", "T_UI_Map_StandardEvent_Icn"),
    sprint  = tx("Icons/Map/", "T_UI_Map_ShakedownRun_Icn"),
    hard    = tx("Icons/Map/", "T_UI_Map_HighRisk_Icn"),
    rev     = tx("Icons/", "T_UI_Reverse_Icn"),
    mines   = tx("Icons/Abilities/", "T_UI_Ability_Mines_Icn"),
    pod     = tx("Icons/Arcade/", "T_UI_Arcade_Plane_Icn"),
}
local FONT_DISPLAY = "/Game/Griffin/UI/Library/Fonts/Font_Display.Font_Display"
local FONT_DECO    = "/Game/Griffin/UI/Library/Fonts/Font_Decorative.Font_Decorative"
local RICH_STYLE   = "/Game/Griffin/UI/Library/Fonts/DT_RichText_Body_Dark_Italic.DT_RichText_Body_Dark_Italic"
local AUDIO_DT     = "/Game/Griffin/Audio/UI/DT_UI_Audio_ForceFeedback.DT_UI_Audio_ForceFeedback"
local AUDIO_LIB    = "/Script/Griffin.Default__UIAudioLibrary"

local VBOX   = { "/Script/Griffin.FuseVerticalBox", "/Script/UMG.VerticalBox" }
local HBOX   = { "/Script/Griffin.FuseHorizontalBox", "/Script/UMG.HorizontalBox" }
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local SCALE  = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" }
local TEXT   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }
local RICH   = { "/Script/Griffin.FuseRichTextBlock", "/Script/UMG.RichTextBlock" }

local VIS = C.E.Vis
local STRETCH_FIT, STRETCH_FILL = 2, 5                    -- EStretch ScaleToFit / ScaleToFill
local CLIP_BOUNDS = 1                                     -- EWidgetClipping ClipToBounds

-- linear colours (the campaign widgets' own values)
local INK_TITLE  = { R = 0.0137, G = 0.0382, B = 0.0482, A = 1 }       -- #1F373E overview title ink
local INK_ACCENT = { R = 0.4396, G = 0.0823, B = 0.0452, A = 1 }       -- #B1513C rich-text H1 accent
local INK_LIGHT  = { R = 0.775822, G = 0.730461, B = 0.665387, A = 1 } -- #E4DED5 run-map text
local INK_FOCUS  = { R = 1.0, G = 0.8632, B = 0.6724, A = 1 }          -- #FFEFD7 focused label
local LINE_OLIVE = { R = 0.520996, G = 0.53948, B = 0.3564, A = 1 }    -- #BFC2A1 MapLineTint
local LINE_AMBER = { R = 0.745404, G = 0.412543, B = 0.08022, A = 1 }  -- #E0AC50 VisitedPathMapLineTint
local BACKER     = { R = 0.006944, G = 0.006944, B = 0.006944, A = 1 } -- #131313 run-map backer
local SHADOW     = { R = 0, G = 0, B = 0, A = 0.85 }

---------------------------------------------------------------------------------------------------- geometry
local ARC = 7200          -- the campaign's selector canvas (R = 0.49 x 7200 = 3528 su), WBP_RunMapOverview slot
local CHIP_MAX = 8        -- quick-race planets: 6 + Tatooine
local VW, VH = 3840, 1500 -- virtual run map (campaign units), scaled to SetupCMapMapW x SetupCMapMapH
local NAME_X, NAME_W = 170, 640                          -- circuit names (left column)
local BUS_X = 880                                        -- vertical path line joining the rows
local NODE_X0, NODE_DX, LABEL_W = 1010, 240, 240         -- variant columns and their labels
local CARD_MARGIN = 128                                  -- card inset from the right edge (campaign RiskReward place)
local PANEL_W, PANEL_H = 2140, 2400                      -- WBP_RunMap_Planet natural size (disc centred)
local ROW_MAX = 10

---------------------------------------------------------------------------------------------------- state
-- X = per lobby page: { ctx = setup helpers, broken = {planet=why, track=why}, view = "planet"|"track"|nil,
--                       P = planet view, T = track view }
local X = nil

local function ctx() return X.ctx end

local function slate(c) return { SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = c.A or 1 }, ColorUseRule = 0 } end
local function lin(c) return { R = c.R, G = c.G, B = c.B, A = c.A or 1 } end

local function overlayFill(over, w)
    local s = over:AddChildToOverlay(w)                   -- -> OverlaySlot
    if U.ok(s) then
        pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)   -- Fill / Fill
    end
    return s
end

-- Canvas child: o = {anchor = {x, y} (point anchor), ax, ay (alignment), x, y, size = {w, h} (nil = auto), z}.
local function place(cv, w, o)
    local s = cv:AddChildToCanvas(w)                      -- -> CanvasPanelSlot
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

-- Native text block. s = {font, typeface, size, colour, wrap, justify (0 left, 1 centre, 2 right), upper, shadow}.
local function newText(s)
    local t = ctx().newW(TEXT)
    local f = fontObj(s.font or FONT_DISPLAY)
    if f then
        -- FSlateFontInfo from a table: missing fields are zero-filled (no outline, no material) [ue4ss-api §8]
        pcall(function() t:SetFont({ FontObject = f, TypefaceFontName = U.fname(s.typeface or "None"), Size = s.size or 32 }) end)
    end
    pcall(function() t:SetColorAndOpacity(slate(s.colour or INK_LIGHT)) end)
    if s.wrap then pcall(function() t:SetAutoWrapText(true) end) end
    if s.justify then pcall(function() t:SetJustification(s.justify) end) end   -- ETextJustify
    if s.upper then pcall(function() t:SetTextTransformPolicy(2) end) end      -- ETextTransformPolicy ToUpper
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

-- An FText property of a data asset straight into a text widget (keeps rich-text tags for RichTextBlocks).
local function setFText(t, obj, prop, fallback)
    local ok = U.ok(t) and U.ok(obj) and pcall(function()
        local v = obj[prop]
        if v == nil then error("nil") end
        t:SetText(v)
    end)
    if not ok then setPlain(t, fallback) end
end

local function newRich(stylePath)
    local r = ctx().newW(RICH)
    local dt = U.obj(stylePath)
    if U.ok(dt) then pcall(function() r:SetTextStyleSet(dt) end) end
    pcall(function() r:SetAutoWrapText(true) end)
    pcall(function() r:SetVisibility(VIS.HitTestInvisible) end)
    return r
end

-- Image with a texture at its own size (bMatchSize: a ScaleBox around it then fills or fits it).
local function texImage(path)
    local img = ctx().newW(IMAGE)
    local t = V.texture(path)
    if t then pcall(function() img:SetBrushFromTexture(t, true) end) end
    pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
    return img, t ~= nil
end

-- Solid tinted quad (a brush without a resource draws a white quad: the campaign's Img_Backer does the same).
local function solid(colour)
    local img = ctx().newW(IMAGE)
    pcall(function() img:SetColorAndOpacity(lin(colour)) end)
    pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
    return img
end

local function sizedScale(stretch, child)
    local sb = ctx().newW(SCALE)
    pcall(function() sb:SetStretch(stretch) end)
    local s = sb:AddChild(child)                          -- -> ScaleBoxSlot
    return sb, s
end

local soundObjs = { al = nil, dt = nil }
local function sound(row)
    if opt("SetupCMapSounds", true) == false or not X then return end
    pcall(function()
        if not U.ok(soundObjs.al) then soundObjs.al = U.cdo(AUDIO_LIB) end
        if not U.ok(soundObjs.dt) then soundObjs.dt = U.obj(AUDIO_DT) end
        if U.ok(soundObjs.al) and U.ok(soundObjs.dt) then
            -- UIAudioLibrary::Play2DAudioFromTable(Object WorldContextObject, DataTable Table, Name RowName) [V JMAP]
            soundObjs.al:Play2DAudioFromTable(ctx().W.pc, soundObjs.dt, U.fname(row))
        end
    end)
end
M.sound = sound

local function nowMs() return ctx().realMs() end

---------------------------------------------------------------------------------------------------- planet view
local function readSel()
    local ok, v = pcall(function() return X.P.sel.SelectedIndex end)   -- IntProperty +0x580, 0-based
    if ok and type(v) == "number" then return v end
    return nil
end

local function readTarget()
    local ok, v = pcall(function() return X.P.sel.TargetSelectionOffset end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Rest angle of planet i0 (0-based): GetAngleForStep(i0, i0, Arc / n, Pad) with the selection at the top.
local function restOffset(i0)
    local P = X.P
    local arc, padA = tonumber(P.arc) or 35, num("SetupCMapArcPad", 2)
    return -(i0 * arc / math.max(1, P.n or 1) + (i0 > 0 and padA or 0))
end

-- Tick probe (V-CMAP-04): TargetSelectionOffset is written only by the selector's per-frame UpdateButtonPos.
local function armProbe(i0, before)
    local P = X.P
    local expect = restOffset(i0)
    if before ~= nil and math.abs(expect - before) > 0.01 then
        P.probe = { at = nowMs(), before = before, expect = expect }
    end
end

local function unlockButtons()
    local P = X.P
    local arr = P.sel.Buttons                             -- TArray<WBP_Diegetic_MapOverview_Btn_C>
    local n = U.arrayCount(arr)
    for i = 1, n do                                       -- never past #arr (reading past the end grows it)
        local okB, b = pcall(function() return arr[i] end)
        if okB and U.ok(b) then
            pcall(function() b:SetAvailable(true) end)    -- every planet bright, no scanlines
            pcall(function() b:SetCurrentPlanet(false) end) -- no ship icon
            pcall(function() b:SetGoalPlanet(false) end)  -- no championship trophy
        end
    end
    P.firstBtn = 0
    if n > 0 then
        local okB, b = pcall(function() return arr[1] end)
        if okB then P.firstBtn = U.key(b) end
    end
    return n
end

local function firstButtonKey()
    local P = X.P
    local ok, k = pcall(function()
        local arr = P.sel.Buttons
        if U.arrayCount(arr) < 1 then return 0 end
        return U.key(arr[1])
    end)
    return ok and k or 0
end

local function selectIndex(i0)
    local P = X.P
    local cur = readSel()
    if cur == i0 then return end
    local before = readTarget()
    -- SetSelectedIndex(Int): a public BP function ("Set Selection" only forwards to it); clamps, expands the new
    -- planet, shrinks the old one, broadcasts OnSelectionChanged and plays RunMap_PlanetSelect [V kismet]
    local ok, err = pcall(function() P.sel:SetSelectedIndex(i0) end)
    if not ok then error("SetSelectedIndex: " .. tostring(err)) end
    local now = readSel()
    if now ~= i0 then
        P.mismatch = (P.mismatch or 0) + 1
        U.warn(TAG, "selector index %s != %d after SetSelectedIndex (%d) (V-CMAP-03)", tostring(now), i0, P.mismatch)
        if P.mismatch >= 2 then error("the planet arc does not follow the selection") end
    else
        P.mismatch = 0
        U.dbg(TAG, "select %d -> selector index %d (V-CMAP-03)", i0 + 1, now)
    end
    armProbe(i0, before)
end

-- The selector, created empty (the CDO's 5 null PlanetVMs would build Sentinel I placeholders at construction).
local function makeSelector()
    local P, c = X.P, ctx()
    local cls = U.class(CLS_SELECTOR)
    if not U.ok(cls) then error("WBP_PlanetSelector_C not found") end
    local sel = U.WBL():Create(c.W.pc, cls, c.W.pc)       -- Create(WorldContext, Class, OwningPlayer)
    if not U.ok(sel) then error("Create(WBP_PlanetSelector_C) failed") end
    pcall(function() sel.PlanetVMs:Empty() end)
    sel.ArcAngleDeg = num("SetupCMapArcAngle", 35)
    sel.SelectionPadAngle = num("SetupCMapArcPad", 2)
    pcall(function() sel:SetVisibility(VIS.HitTestInvisible) end)  -- whole subtree: no hover blink, no "locked" beeps
    P.sel = sel
    P.selSlot = place(P.canvas, sel, { anchor = { 0.5, 0 }, ax = 0.5, ay = 0, size = { ARC, ARC }, x = 0, y = 0, z = 1 })
    sel:SetRenderTransformPivot({ X = 0.5, Y = 0.01 })    -- the selected planet's point (3600, 72) of the 7200 box
end

-- Positions: selected planet centre at (centre, PlanetY); info block right edge 360k left of it and the video frame
-- 360k right of it, both 28 su under the expanded planet (the overview's VB_PlanetInfo place).
local function layoutPlanet()
    local P = X.P
    local k = num("SetupCMapArcScale", 0.85)
    local py = num("SetupCMapPlanetY", 330)
    P.k = k
    P.selSlot:SetPosition({ X = 0, Y = py - 0.01 * ARC })
    pcall(function() P.sel:SetRenderScale({ X = k, Y = k }) end)
    local top = py + 330 * k + 28
    if not P.infoSlot then
        P.infoSlot = place(P.canvas, P.infoBox, { anchor = { 0.5, 0 }, ax = 1, ay = 0, x = -360 * k, y = top, z = 2 })
    else
        P.infoSlot:SetPosition({ X = -360 * k, Y = top })
    end
    if P.vidBox then
        if not P.vidSlot then
            P.vidSlot = place(P.canvas, P.vidBox, { anchor = { 0.5, 0 }, ax = 0, ay = 0, x = 360 * k, y = top, z = 2 })
        else
            P.vidSlot:SetPosition({ X = 360 * k, Y = top })
        end
    end
end

local function buildPlanetView()
    local c = ctx()
    local P = { chips = {}, n = 0 }
    X.P = P
    P.root = c.newW(VBOX)
    P.area = c.sizeBox(num("SetupCMapAreaW", 3500), num("SetupCMapAreaH", 1080))
    pcall(function() P.area:SetClipping(CLIP_BOUNDS) end)  -- the arc is 7200 su: cut to the area
    P.over = c.newW(OVER)
    P.area:AddChild(P.over)
    if opt("SetupCMapBackground", true) ~= false then
        local img, have = texImage(TEX.mapBg)
        if have then
            local sb = sizedScale(STRETCH_FILL, img)
            overlayFill(P.over, sb)
        end
    end
    P.canvas = c.newW(CANVAS)
    overlayFill(P.over, P.canvas)
    c.vAdd(P.root, P.area, c.pad(0, 0, 0, 6), C.E.HAlign.Center)
    -- info block (WBP_RunMapOverview_Presentation VB_PlanetInfo: Aurebesh line, name, description pill)
    P.infoBox = c.sizeBox(num("SetupCMapInfoW", 820), nil)
    P.info = c.newW(VBOX)
    P.infoBox:AddChild(P.info)
    P.deco = newText({ font = FONT_DECO, typeface = "Aurebesh", size = 24, colour = INK_TITLE, upper = true })
    P.name = newText({ size = 75, colour = INK_TITLE, upper = true, wrap = true })
    P.desc = newRich(RICH_STYLE)
    P.count = newText({ size = 34, typeface = "Bold", colour = INK_ACCENT, upper = true, wrap = true })
    c.vAdd(P.info, P.deco, c.pad(20, 0, 0, 0))
    c.vAdd(P.info, P.name, c.pad(20, 0, 0, 6))
    c.vAdd(P.info, P.desc, c.pad(20, 6, 0, 6))
    c.vAdd(P.info, P.count, c.pad(20, 6, 0, 0))
    -- the planet's arrival video (setup.lua's Bink player), 16:9
    local vw = num("SetupCMapVideoW", 768)
    if vw > 0 then
        P.vidBox = c.sizeBox(vw, math.floor(vw * 9 / 16 + 0.5))
        P.vid = c.newW(IMAGE)
        pcall(function() P.vid:SetVisibility(VIS.HitTestInvisible) end)
        P.vidBox:AddChild(P.vid)
    end
    -- planet chips: the control (focus = select, A = choose)
    P.chipRow = c.newW(HBOX)
    for i = 1, CHIP_MAX do
        local idx = i
        local b = c.button("cmchip" .. i, "", function() M.onChip(idx) end)
        if not b then error("chip button " .. i .. " not created") end
        P.chips[i] = b
        c.hAdd(P.chipRow, b, 1, c.pad(i > 1 and 8 or 0, 0, 0, 0))
    end
    c.vAdd(P.root, P.chipRow, c.pad(0, 2, 0, 2))
    c.vAdd(c.W.panel, P.root, c.pad(0, 0, 0, 8))
    c.show(P.root, false)
    makeSelector()
    layoutPlanet()
end

-- entries = setup's S.planets ({planet = PLANETS entry, tracks = list|nil}); selIdx 1-based. Returns the chip to
-- focus. Feeds the arc only when the planet list changed (a class change), else just selects.
function M.showPlanets(entries, selIdx)
    local P = X.P
    local defs, keys = {}, {}
    for i, e in ipairs(entries) do
        local d = U.obj(e.planet.path)
        if not U.ok(d) then error("PlanetDef " .. tostring(e.planet.key) .. " not found") end
        V.texture(e.planet.select)                        -- pre-load the carousel art (no wrong-planet frame)
        defs[i], keys[i] = d, e.planet.key
    end
    local n = #defs
    if n == 0 then error("no planet to show") end
    if n > CHIP_MAX then error(n .. " planets > " .. CHIP_MAX .. " chips") end
    local i0 = math.max(0, math.min(n - 1, (tonumber(selIdx) or 1) - 1))
    local key = table.concat(keys, ",")
    if P.listKey ~= key or U.arrayCount(P.sel.Buttons) ~= n then
        P.n = n
        P.arc = math.max(num("SetupCMapArcAngle", 35), 5.85 * n)   -- 7 planets need ~41 deg not to touch
        P.sel.ArcAngleDeg = P.arc
        P.sel.SelectionPadAngle = num("SetupCMapArcPad", 2)
        local before = readTarget()
        local ok, err = pcall(function() P.sel:SetPlanetVms(defs, i0) end)   -- Array<PlanetDef> from a Lua table
        local nb = U.arrayCount(P.sel.Buttons)
        local how = "SetPlanetVms ok"
        if not ok or nb ~= n then
            -- fallback (critic C2.1): fill the instance's own array in place and pass it back (UE4SS copies a TArray
            -- userdata parameter); keeps the real SetPlanetVms path (Current Planet Idx, SelectedIndex, rebuild)
            local ok2, err2 = pcall(function()
                local arr = P.sel.PlanetVMs
                arr:Empty()
                for j = 1, n do arr[j] = defs[j] end      -- index #arr+1 appends (AddZeroed) [ue4ss-api §8]
                P.sel:SetPlanetVms(arr, i0)
            end)
            nb = U.arrayCount(P.sel.Buttons)
            how = string.format("SetPlanetVms(table) %s, PlanetVMs written in place (%s)",
                ok and ("made " .. tostring(nb)) or ("refused: " .. tostring(err)), ok2 and "ok" or tostring(err2))
            if nb ~= n then error(string.format("the arc has %d planet button(s) for %d planets (%s)", nb, n, how)) end
        end
        unlockButtons()
        P.listKey = key
        pcall(function() P.sel.SelectionOffset = restOffset(i0) end)   -- start at rest: no 0.4 s slide from planet 1
        armProbe(i0, before)
        U.log(TAG, "planets: %d (%s), %s, %d button(s), selected %d, arc %.1f deg (V-CMAP-02)", n, key, how, nb,
            i0 + 1, P.arc)
    else
        if firstButtonKey() ~= P.firstBtn then         -- a Slate rebuild recreated the buttons (01 R3)
            unlockButtons()
            U.log(TAG, "planet buttons were rebuilt: unlocked again (R3)")
        end
        selectIndex(i0)
    end
    for i = 1, CHIP_MAX do
        local ch = P.chips[i]
        if i <= n then
            ctx().setText(ch, entries[i].planet.name, true)
            ctx().showRow(ch, true)
        else
            ctx().showRow(ch, false)
        end
    end
    P.entries = entries
    return P.chips[i0 + 1]
end

-- Planet i (1-based) under focus: the arc slides to it, the info block and the video follow.
-- d = {planet = PLANETS entry, count = "8 CIRCUITS · 23 TRACKS FOR THE LANDSPEEDER", url = movie url | nil}
function M.previewPlanet(i, d)
    local P = X.P
    selectIndex(i - 1)
    local def = U.obj(d.planet.path)
    setFText(P.deco, def, "PlayerFacingName", d.planet.name)
    setFText(P.name, def, "PlayerFacingName", d.planet.name)
    setFText(P.desc, def, "GameDescriptionText", "")      -- <H1>...</> tags: the rich text style draws them
    setPlain(P.count, d.count)
    if not P.vid then ctx().stopVideo("planet view without video") end
    if P.vid then
        local playing = d.url and ctx().playVideoOn(P.vid, d.url) or false
        if not playing then ctx().setImage(P.vid, d.planet.select) end
    end
end

function M.onChip(i)
    if X and X.view == "planet" and X.P and i <= (X.P.n or 0) then ctx().onItem(i) end
end

local function planetTick()
    local P = X.P
    if not (P and U.ok(P.sel)) then return end
    local mode = opt("SetupCMapManualTick", "auto")
    if mode == "off" then return end
    if mode == "always" or P.manual then
        pcall(function() P.sel:UpdateButtonPos() end)    -- BP function, no Lua args [V JMAP]
        return
    end
    local pr = P.probe
    if not pr or nowMs() - pr.at < 300 then return end
    P.probe = nil
    local t = readTarget()
    if t == nil then return end
    if math.abs(t - pr.expect) < 0.01 then
        if not P.tickLogged then
            P.tickLogged = true
            U.log(TAG, "selector ticks (target offset %.2f -> %.2f) (V-CMAP-04)", pr.before, t)
        end
    elseif math.abs(t - pr.before) < 0.001 then
        P.manual = true
        pcall(function() P.sel.LerpSpeed = 20 end)        -- 30 Hz manual steps: keep the campaign's ~0.4 s slide
        U.warn(TAG, "selector does not tick (target offset still %.2f, expected %.2f): UpdateButtonPos from the FAST loop (V-CMAP-04)",
            t, pr.expect)
    end
end

---------------------------------------------------------------------------------------------------- track view
local function buildTrackShell()
    local c = ctx()
    local T = { nodes = {}, rows = {}, nodeItem = {}, itemNode = {}, itemRow = {}, used = 0, ready = false }
    X.T = T
    T.root = c.newW(VBOX)
    T.box = c.sizeBox(num("SetupCMapMapW", 3500), num("SetupCMapMapH", 1200))
    T.virt = c.sizeBox(VW, VH)
    pcall(function() T.virt:SetClipping(CLIP_BOUNDS) end) -- the planet rings reach 2912 su (5824 at the pulse peak)
    local sc = sizedScale(STRETCH_FIT, T.virt)
    T.box:AddChild(sc)
    T.over = c.newW(OVER)
    T.virt:AddChild(T.over)
    overlayFill(T.over, solid(BACKER))
    local img, have = texImage(TEX.eventBg)
    if have then overlayFill(T.over, (sizedScale(STRETCH_FILL, img))) end
    T.canvas = c.newW(CANVAS)
    overlayFill(T.over, T.canvas)
    c.vAdd(T.root, T.box, c.pad(0, 0, 0, 6), C.E.HAlign.Center)
    c.vAdd(c.W.panel, T.root, c.pad(0, 0, 0, 8))
    c.show(T.root, false)
end

local function strip(colour, z)
    local im = solid(colour)
    local s = place(X.T.canvas, im, { x = -100, y = -100, size = { 5, 5 }, z = z or 1 })
    return { w = im, slot = s }
end

local function setStrip(st, x1, y1, x2, y2)
    if y1 == y2 then
        st.slot:SetPosition({ X = math.min(x1, x2), Y = y1 - 2.5 })
        st.slot:SetSize({ X = math.max(5, math.abs(x2 - x1)), Y = 5 })
    else
        st.slot:SetPosition({ X = x1 - 2.5, Y = math.min(y1, y2) })
        st.slot:SetSize({ X = 5, Y = math.max(5, math.abs(y2 - y1)) })
    end
    ctx().show(st.w, true)
end

local function hideW(w) if U.ok(w) then pcall(function() w:SetVisibility(VIS.Collapsed) end) end end
local function showHT(w) if U.ok(w) then pcall(function() w:SetVisibility(VIS.HitTestInvisible) end) end end

local function newNode(i, tex)
    local T, c = X.T, ctx()
    local cls = U.class(CLS_NODE)
    if not U.ok(cls) then error("WBP_RunMap_Activity_Presentation_Btn_C not found") end
    local b = U.WBL():Create(c.W.pc, cls, c.W.pc)
    if not U.ok(b) then error("Create(activity button) failed") end
    -- MapNode stays nil: RefreshFromMapNode returns at IsValid; PreConstruct applies IconActivity and NodeState.
    -- IconActivity is an ObjectProperty: a resolved Texture2D, never the path (review 0.9.0).
    local t = V.texture(tex) or V.texture(TEX.race)
    if not t then error("node icon texture missing: " .. tostring(tex)) end
    b.IconActivity = t
    b.NodeState = 1                                        -- Choosable: cream disc, accept sound on click
    pcall(function() b.IsTooltipEnabled = false end)
    local slot = place(T.canvas, b, { ax = 0.5, ay = 0.5, x = -500, y = -500, z = 3 })
    local idx = i
    U.mod("ui").registerButton(b, "setup:cmnode" .. i, function() M.onNode(idx) end)
    c.W.focusables[#c.W.focusables + 1] = b
    local lblBox = c.sizeBox(LABEL_W, nil)
    local lbl = newText({ size = 26, typeface = "Bold", colour = INK_LIGHT, upper = true, wrap = true, justify = 1,
                          shadow = true })
    lblBox:AddChild(lbl)
    local lblSlot = place(T.canvas, lblBox, { ax = 0.5, ay = 0, x = -500, y = -500, z = 2 })
    hideW(b)
    hideW(lblBox)
    return { w = b, slot = slot, lbl = lbl, lblBox = lblBox, lblSlot = lblSlot, tex = tex }
end

-- Lazy: the map's game widgets are made the first time the TRACK step shows (planet panel needs a PlanetDef).
local function ensureTrackWidgets(planet)
    local T, c = X.T, ctx()
    if T.ready then return end
    -- big planet (WBP_RunMap_Planet): PlanetDef + Planet before it is added (PreConstruct draws Planet)
    local cls = U.class(CLS_PLANET)
    if not U.ok(cls) then error("WBP_RunMap_Planet_C not found") end
    local pl = U.WBL():Create(c.W.pc, cls, c.W.pc)
    if not U.ok(pl) then error("Create(WBP_RunMap_Planet_C) failed") end
    local def = U.obj(planet.path)
    local hi = V.texture(planet.hires)
    if not (U.ok(def) and hi) then error("planet " .. tostring(planet.key) .. ": PlanetDef or hi-res texture missing") end
    pl.PlanetDef = def
    pl.Planet = hi
    local px, ps = num("SetupCMapPlanetX", 1180), num("SetupCMapPlanetScale", 0.62)
    T.plSlot = place(T.canvas, pl, { x = px - PANEL_W / 2, y = VH / 2 - PANEL_H / 2, size = { PANEL_W, PANEL_H }, z = 0 })
    pcall(function() pl:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)   -- the disc centre
    pcall(function() pl:SetRenderScale({ X = ps, Y = ps }) end)
    pcall(function() pl:SetVisibility(VIS.HitTestInvisible) end)
    T.pl = pl
    T.plKey = nil
    -- path lines: one bus, one line per row
    T.bus = strip(LINE_OLIVE, 1)
    hideW(T.bus.w)
    for r = 1, ROW_MAX do
        local row = { line = strip(LINE_OLIVE, 1) }
        hideW(row.line.w)
        row.box = c.sizeBox(NAME_W, nil)
        row.name = newText({ size = 44, typeface = "Bold", colour = INK_LIGHT, upper = true, wrap = true, shadow = true })
        row.box:AddChild(row.name)
        row.slot = place(T.canvas, row.box, { ax = 0, ay = 0.5, x = NAME_X, y = -500, z = 2 })
        hideW(row.box)
        T.rows[r] = row
    end
    -- detail card (WBP_Tooltip_Holder: dark frame, Font_Display 33 amber header, named content slot)
    local ccls = U.class(CLS_CARD)
    if not U.ok(ccls) then error("WBP_Tooltip_Holder_C not found") end
    local card = U.WBL():Create(c.W.pc, ccls, c.W.pc)
    if not U.ok(card) then error("Create(WBP_Tooltip_Holder_C) failed") end
    pcall(function() card.ShowHeader = true end)
    pcall(function() card.Label = U.ftext(" ") end)
    local cw = num("SetupCMapCardW", 980) - 64            -- content width inside the holder's 32 su padding
    local body = c.newW(VBOX)
    T.artBox = c.sizeBox(cw, math.floor(cw * 9 / 16 + 0.5))
    pcall(function() T.artBox:SetClipping(CLIP_BOUNDS) end)
    T.art = c.newW(IMAGE)
    pcall(function() T.art:SetVisibility(VIS.HitTestInvisible) end)
    local artScale, artSlot = sizedScale(STRETCH_FILL, T.art)
    pcall(function() artSlot:SetVerticalAlignment(1) end) -- VAlign Top: the Arcade tiles keep their art up top
    T.artBox:AddChild(artScale)
    c.vAdd(body, T.artBox, c.pad(0, 0, 0, 14))
    T.lines = {}
    for i = 1, 4 do
        local t = newText({ size = i == 1 and 40 or 36, typeface = "Bold", colour = i == 1 and INK_FOCUS or INK_LIGHT,
                            upper = true, wrap = true })
        T.lines[i] = t
        c.vAdd(body, t, c.pad(0, 4, 0, 4))
    end
    local okS, errS = pcall(function() card.NS_TooltipContent:SetContent(body) end)
    if not okS then error("card content slot: " .. tostring(errS)) end
    T.card = card
    T.cardSlot = place(T.canvas, card, { anchor = { 1, 0.5 }, ax = 1, ay = 0.5, x = -CARD_MARGIN, y = 0, z = 4 })
    pcall(function() card:SetVisibility(VIS.HitTestInvisible) end)
    T.ready = true
    U.log(TAG, "run map built: planet panel, %d row(s), card %d su (V-CMAP-08)", ROW_MAX, cw + 64)
end

local function setMapPlanet(planet)
    local T = X.T
    if T.plKey == planet.key then return end
    local def = U.obj(planet.path)
    local hi = V.texture(planet.hires)                    -- resident: SetPlanetInfo's soft load resolves at once
    if not U.ok(def) then error("PlanetDef " .. tostring(planet.key) .. " not found") end
    T.pl.PlanetDef = def
    if hi then pcall(function() T.pl.Planet = hi end) end
    local ok, err = pcall(function() T.pl:SetPlanetInfo(true) end)   -- active: turning ring, dashes, sonar pulse
    if not ok then error("SetPlanetInfo: " .. tostring(err)) end
    if opt("SetupCMapPlanetName", false) ~= true then hideW(T.pl.B_TextColor) end   -- our card names the circuit
    T.plKey = planet.key
end

local function isHard(e)
    local k = string.upper((e.key or "") .. " " .. (e.internal or ""))
    return k:find("_HARD", 1, true) ~= nil or k:find("SCORCH", 1, true) ~= nil
end

-- Variant words: short for the node label, long for the card.
local function variantWords(e, long)
    local t = {}
    if isHard(e) then
        local word = "HARD"
        if #(e.conds or {}) == 1 then word = ctx().prettyCond(e.conds[1]) end
        t[#t + 1] = word
    end
    if e.rev then t[#t + 1] = long and "REVERSE" or "REV" end
    if e.mines then t[#t + 1] = "MINES" end
    if #t == 0 then t[1] = "STANDARD" end
    return table.concat(t, " · ")
end

local function iconFor(e, isPod)
    if e.mines then return TEX.mines end
    if isHard(e) then return TEX.hard end
    if e.rev then return TEX.rev end
    if isPod then return TEX.pod end
    if e.p2p then return TEX.sprint end
    return TEX.race
end

local function rank(e)
    return (e.rev and 1 or 0) + (e.mines and 2 or 0) + (isHard(e) and 4 or 0)
end

-- Rows = circuits (display name, game order), variants sorted standard, reverse, mines, reverse+mines, hard...
local function groupRows(tracks)
    local rows, byName = {}, {}
    for i, e in ipairs(tracks) do
        local r = byName[e.name]
        if not r then
            r = { name = e.name, items = {} }
            byName[e.name] = r
            rows[#rows + 1] = r
        end
        r.items[#r.items + 1] = { i = i, e = e }
    end
    for _, r in ipairs(rows) do
        table.sort(r.items, function(a, b)
            local ra, rb = rank(a.e), rank(b.e)
            if ra ~= rb then return ra < rb end
            return a.i < b.i
        end)
        -- same short label twice in a row (two layouts under one name): add the layout hint
        local seen = {}
        for _, it in ipairs(r.items) do
            it.label = variantWords(it.e, false)
            seen[it.label] = (seen[it.label] or 0) + 1
        end
        for _, it in ipairs(r.items) do
            if seen[it.label] > 1 and it.e.hint and it.e.hint ~= "" then it.label = it.label .. " · " .. it.e.hint end
        end
    end
    return rows
end

local function setNodeIcon(nd, tex)
    if nd.tex == tex then return end
    local t = V.texture(tex) or V.texture(TEX.race)
    if not t then return end
    pcall(function() nd.w.IconActivity = t end)
    pcall(function() nd.w.Img_Activity:SetBrushFromTexture(t, false) end)
    nd.tex = tex
end

-- d = {planet = PLANETS entry, tracks = setup's S.tracks, sel = 1-based selected track, isPod = bool}.
-- Returns the node to focus.
function M.showTracks(d)
    local T = X.T
    local tracks = d.tracks or {}
    if #tracks == 0 then error("no track for this planet") end
    local maxNodes = math.floor(num("SetupCMapNodeMax", 40))
    if #tracks > maxNodes then error(string.format("%d tracks > SetupCMapNodeMax %d", #tracks, maxNodes)) end
    ensureTrackWidgets(d.planet)
    setMapPlanet(d.planet)
    local rows = groupRows(tracks)
    if #rows > ROW_MAX then error(string.format("%d circuits > %d rows", #rows, ROW_MAX)) end
    -- grid: rows centred, columns from NODE_X0, squeezed if a circuit has more variants than the space before the card
    local R, maxCols = #rows, 1
    for _, r in ipairs(rows) do maxCols = math.max(maxCols, #r.items) end
    local cardLeft = VW - CARD_MARGIN - num("SetupCMapCardW", 980) - 40
    local dx = NODE_DX
    if maxCols > 1 then dx = math.min(NODE_DX, (cardLeft - NODE_X0 - LABEL_W / 2) / (maxCols - 1)) end
    local pitch = math.min(190, (VH - 200) / R)
    local function rowY(r) return VH / 2 + pitch * (r - (R + 1) / 2) end
    T.nodeItem, T.itemNode, T.itemRow, T.rowLast = {}, {}, {}, {}
    local n = 0
    for r, row in ipairs(rows) do
        local y = rowY(r)
        local rw = T.rows[r]
        setPlain(rw.name, row.name)
        pcall(function() rw.name:SetColorAndOpacity(slate(INK_LIGHT)) end)   -- a previous map's focus highlight off
        rw.slot:SetPosition({ X = NAME_X, Y = y })
        showHT(rw.box)
        local lastX = NODE_X0
        for c, it in ipairs(row.items) do
            n = n + 1
            local nd = T.nodes[n]
            if not nd then
                nd = newNode(n, TEX.race)
                T.nodes[n] = nd
            end
            local x = NODE_X0 + dx * (c - 1)
            lastX = x
            setNodeIcon(nd, iconFor(it.e, d.isPod))
            nd.slot:SetPosition({ X = x, Y = y })
            pcall(function() nd.w:SetVisibility(VIS.Visible) end)   -- focusable + hit-testable
            setPlain(nd.lbl, it.label)
            pcall(function() nd.lbl:SetColorAndOpacity(slate(INK_LIGHT)) end)
            nd.lblSlot:SetPosition({ X = x, Y = y + 62 })
            showHT(nd.lblBox)
            T.nodeItem[n], T.itemNode[it.i], T.itemRow[it.i] = it.i, n, r
        end
        setStrip(rw.line, BUS_X, y, lastX, y)
        pcall(function() rw.line.w:SetColorAndOpacity(lin(LINE_OLIVE)) end)
        T.rowLast[r] = lastX
    end
    for r = R + 1, ROW_MAX do
        hideW(T.rows[r].box)
        hideW(T.rows[r].line.w)
    end
    for j = n + 1, #T.nodes do
        hideW(T.nodes[j].w)
        hideW(T.nodes[j].lblBox)
    end
    if R >= 2 then setStrip(T.bus, BUS_X, rowY(1), BUS_X, rowY(R)) else hideW(T.bus.w) end
    T.used, T.R, T.focusRow, T.focusNode = n, R, nil, nil
    U.log(TAG, "map %s: %d circuit(s), %d node(s), %d column(s) max, pitch %.0f su (V-CMAP-08)", tostring(d.planet.key),
        R, n, maxCols, pitch)
    local sel = T.itemNode[tonumber(d.sel) or 1] or 1
    return T.nodes[sel] and T.nodes[sel].w or nil
end

-- Track item i focused: highlight its row (amber line, bright labels) and fill the card.
-- d = {e = track entry, planet = "JAKKU", cls = "LANDSPEEDER", art = texture path}
function M.previewTrack(i, d)
    local T = X.T
    if not T.ready then return end
    local r, nIdx = T.itemRow[i], T.itemNode[i]
    if T.focusRow and T.focusRow ~= r and T.rows[T.focusRow] then
        pcall(function() T.rows[T.focusRow].line.w:SetColorAndOpacity(lin(LINE_OLIVE)) end)
        pcall(function() T.rows[T.focusRow].name:SetColorAndOpacity(slate(INK_LIGHT)) end)
    end
    if r and T.rows[r] then
        pcall(function() T.rows[r].line.w:SetColorAndOpacity(lin(LINE_AMBER)) end)
        pcall(function() T.rows[r].name:SetColorAndOpacity(slate(INK_FOCUS)) end)
    end
    if T.focusNode and T.focusNode ~= nIdx and T.nodes[T.focusNode] then
        pcall(function() T.nodes[T.focusNode].lbl:SetColorAndOpacity(slate(INK_LIGHT)) end)
    end
    if nIdx and T.nodes[nIdx] then pcall(function() T.nodes[nIdx].lbl:SetColorAndOpacity(slate(INK_FOCUS)) end) end
    T.focusRow, T.focusNode = r, nIdx
    local e = d.e
    local okL = pcall(function() T.card:SetTooltipLabel(U.ftext(e.name)) end)   -- BP custom event (Text)
    if not okL then pcall(function() T.card.Txt_Label:SetText(U.ftext(e.name)) end) end
    local laps = e.p2p and "POINT TO POINT" or string.format("%d LAP%s", e.laps or 0, (e.laps == 1) and "" or "S")
    local conds = {}
    for _, t in ipairs(e.conds or {}) do conds[#conds + 1] = ctx().prettyCond(t) end
    setPlain(T.lines[1], d.planet .. "  ·  " .. d.cls)
    setPlain(T.lines[2], laps)
    setPlain(T.lines[3], variantWords(e, true) .. ((e.hint and e.hint ~= "") and ("  ·  " .. e.hint) or ""))
    setPlain(T.lines[4], #conds > 0 and ("CONDITIONS: " .. table.concat(conds, ", ")) or "")
    local t = V.texture(d.art)
    if t then pcall(function() T.art:SetBrushFromTexture(t, true) end) end
end

function M.onNode(n)
    if not (X and X.view == "track" and X.T) then return end
    local i = X.T.nodeItem[n]
    if i then ctx().onItem(i) end
end

---------------------------------------------------------------------------------------------------- setup API
-- ctx = setup.lua helpers: {W, newW, sizeBox, button, show, showRow, setText, setImage, pad, vAdd, hAdd, prettyCond,
--        playVideoOn(img, url) -> bool, onItem(i), realMs()}. Builds both views collapsed after W.body.
function M.build(c)
    X = { ctx = c, pageKey = c.W.pageKey, broken = {}, view = nil }
    if opt("SetupCampaignMap", true) == false then
        X.broken.planet, X.broken.track = "SetupCampaignMap=false", "SetupCampaignMap=false"
        U.log(TAG, "campaign views off (SetupCampaignMap=false): PLANET / TRACK use the lists (V-CMAP-12)")
        return false
    end
    if opt("SetupCMapPlanetNav", "chips") == "list" then
        X.broken.planet = "SetupCMapPlanetNav=list"
    else
        local ok, err = pcall(buildPlanetView)
        if not ok then
            X.broken.planet = tostring(err)
            U.warn(TAG, "planet view unavailable (%s): the PLANET step uses the list (V-CMAP-01)", tostring(err))
        end
    end
    if opt("SetupCMapTrackView", "map") == "list" then
        X.broken.track = "SetupCMapTrackView=list"
    else
        local ok, err = pcall(buildTrackShell)
        if not ok then
            X.broken.track = tostring(err)
            U.warn(TAG, "track map unavailable (%s): the TRACK step uses the list (V-CMAP-01)", tostring(err))
        end
    end
    U.log(TAG, "built: planet view %s (arc %d su x%.2f, area %dx%d, %d chips), track map %s (%dx%d) (V-CMAP-01)",
        X.broken.planet and ("OFF: " .. X.broken.planet) or "on", ARC, num("SetupCMapArcScale", 0.85),
        num("SetupCMapAreaW", 3500), num("SetupCMapAreaH", 1080), CHIP_MAX,
        X.broken.track and ("OFF: " .. X.broken.track) or "on", num("SetupCMapMapW", 3500), num("SetupCMapMapH", 1200))
    return true
end

-- "planet" / "track" view usable for this page.
function M.usable(step)
    if not X then return false end
    if step == "planet" then return X.P ~= nil and X.broken.planet == nil and U.ok(X.P.root) end
    if step == "track" then return X.T ~= nil and X.broken.track == nil and U.ok(X.T.root) end
    return false
end

-- A runtime failure: the step falls back to the list for the rest of this page (logged once per view).
function M.markBroken(step, why)
    if not X then return end
    if X.broken[step] == nil then
        X.broken[step] = tostring(why)
        U.warn(TAG, "%s view failed (%s): the %s step uses the list from now on", tostring(step), tostring(why),
            string.upper(tostring(step)))
    end
    if X.view == step then M.setView(nil) end
end

-- Show one view ("planet" | "track") or none.
function M.setView(view)
    if not X then return end
    local c = ctx()
    if X.P and U.ok(X.P.root) then c.show(X.P.root, view == "planet") end
    if X.T and U.ok(X.T.root) then c.show(X.T.root, view == "track") end
    local was = X.view
    X.view = view
    if view == "planet" and was ~= "planet" then sound("RunMap_Open") end
end

function M.view() return X and X.view or nil end

-- Item index (1-based) of a chip / node widget of the current view, or nil.
function M.itemFor(w)
    if not (X and w) then return nil end
    if X.view == "planet" and X.P then
        for i = 1, (X.P.n or 0) do
            if U.same(w, X.P.chips[i]) then return i end
        end
    elseif X.view == "track" and X.T then
        for n = 1, (X.T.used or 0) do
            local nd = X.T.nodes[n]
            if nd and U.same(w, nd.w) then return X.T.nodeItem[n] end
        end
    end
    return nil
end

-- Widget of item i in the current view (focus target), or nil.
function M.widgetFor(i)
    if not (X and i) then return nil end
    if X.view == "planet" and X.P then return X.P.chips[i] end
    if X.view == "track" and X.T then
        local n = X.T.itemNode[i]
        return n and X.T.nodes[n] and X.T.nodes[n].w or nil
    end
    return nil
end

-- Focusable widgets of the current view (setup.lua's focus scan).
function M.focusables()
    local out = {}
    if not X then return out end
    if X.view == "planet" and X.P then
        for i = 1, (X.P.n or 0) do out[#out + 1] = X.P.chips[i] end
    elseif X.view == "track" and X.T then
        for n = 1, (X.T.used or 0) do out[#out + 1] = X.T.nodes[n].w end
    end
    return out
end

-- FAST loop (setup.pollNav) while a view shows.
function M.tick()
    if not X then return end
    if X.view == "planet" then planetTick() end
end

-- Menu replaced / page rebuilt: the widgets die with the old page (no game call here).
function M.forget()
    X = nil
end

function M.status()
    if not X then return "no page" end
    return string.format("view %s, planet %s, track %s", tostring(X.view), X.broken.planet or "on", X.broken.track or "on")
end

return M
