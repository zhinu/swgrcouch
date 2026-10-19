-- garage4ui.lua: the 4-WAY GARAGE's screen (garage4.lua; docs/dev/guest-garage.md section 8). One full-screen widget
-- of our own (the front end has no split screen: the game forces it off there, so AddToPlayerScreen would have no
-- player regions to draw into) with one AREA per player, laid out like the race's split views:
--   1 player: the whole screen; 2: top / bottom strips (3840 x 1080 su each); 3-4: quadrants (1920 x 1080 su),
--   a 3-player bottom-right quadrant gets the paper only.
-- Each area is drawn in the game's look, the same parts the couch panels and the RACERS cards use: the paper
-- backdrop (T_UI_Generic_A_Bg, couchpanel.paperCover), the campaign's dark teal panels with the amber focus row, cream
-- Font_Display labels and Font_Body text, the player's colour badge (C.COLOURS), the manufacturer badge of the model,
-- the palette's three livery colours, and the player's 3D car (his vpreview photo bay through the same opaque MID the
-- cards use). buildArea / renderArea are also used inside couchpanel's guest areas (couch campaign) so both hosts look
-- the same.
-- Every widget is HitTestInvisible: the host never takes a mouse click nor the focus (P1's RACERS sink keeps it).
-- Renders are diffed (a text / colour / brush is only set when it changed) and textures are resolved once per path.
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")

local TAG = "garage4ui"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local VIS = C.E.Vis
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local SCALE  = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" }
local TEXT   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }
local SIZEB  = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" }
local HOST = "/Game/Griffin/UI/Widgets/Decorative/WBP_Background_Blur.WBP_Background_Blur_C"
local FONT_DISPLAY = "/Game/Griffin/UI/Library/Fonts/Font_Display.Font_Display"
local FONT_BODY    = "/Game/Griffin/UI/Library/Fonts/Font_Body.Font_Body"

-- the campaign panel palette (couchpanel.lua): linear colours
local CREAM  = { R = 1.0, G = 0.8632, B = 0.6724, A = 1 }
local PAPER  = { R = 0.776, G = 0.73, B = 0.665, A = 1 }
local AMBER  = { R = 0.745, G = 0.413, B = 0.080, A = 1 }
local DEEP   = { R = 0.008, G = 0.032, B = 0.040, A = 1 }
local ROW    = { R = 0.018, G = 0.062, B = 0.074, A = 1 }
local INKD   = { R = 0.006, G = 0.006, B = 0.006, A = 1 }
local SHADE  = { R = 0.004, G = 0.012, B = 0.016, A = 0.82 }

local VW, VH = 3840, 2160
local ROW_MAX = 7

---------------------------------------------------------------------------------------------------- primitives
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

local function place(cv, w, x, y, sw, sh, z)
    local s = cv:AddChildToCanvas(w)
    s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    s:SetAlignment({ X = 0, Y = 0 })
    if sw then s:SetAutoSize(false); s:SetSize({ X = sw, Y = sh }) else s:SetAutoSize(true) end
    s:SetPosition({ X = x, Y = y })
    if z then s:SetZOrder(z) end
    return s
end

local objs = {}             -- path -> object (fonts, textures): resolved once (StaticFindObject is ~2.5 ms a call)
local function objOf(path)
    if type(path) ~= "string" or path == "" then return nil end
    local o = objs[path]
    -- live 2026-10-16 (v2 4-way): a prefetched badge no widget references is garbage-collected within seconds (only
    -- the badges a RACERS card shows stay loaded): a stale entry is resolved again (setTex calls this only when the
    -- path changes, and a brush then holds the texture)
    if o == false then return nil end
    if o ~= nil and U.ok(o) then return o end
    o = nil
    pcall(function() o = U.obj(path) end)
    if not U.ok(o) then
        -- live 2026-10-16: the badges of models no card had shown never appeared: LoadAsset loads the package but its
        -- return is not the texture (cards2.loadNow finds it again afterwards, as here)
        pcall(LoadAsset, path)
        o = nil
        pcall(function() o = StaticFindObject(path) end)
    end
    objs[path] = U.ok(o) and o or false
    if not objs[path] then U.logOnce("garage4ui.tex?" .. path, TAG, "texture not found: %s (hidden)", path) end
    return objs[path] or nil
end

-- textures / fonts resolved now (garage4.open: the class's manufacturer badges), so no find happens in a later tick
function M.prefetch(paths)
    local n = 0
    for _, p in ipairs(paths or {}) do
        if objs[p] == nil or objs[p] == false then objs[p] = nil; objOf(p); n = n + 1 end
    end
    return n
end

local function text(outer, size, colour, fontPath)
    local t = mk(TEXT, outer)
    if not t then error("no TextBlock") end
    local f = objOf(fontPath or FONT_DISPLAY)
    if f then pcall(function() t:SetFont({ FontObject = f, TypefaceFontName = U.fname("None"), Size = math.floor(size) }) end) end
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = lin(colour), ColorUseRule = 0 }) end)
    pcall(function() t:SetVisibility(VIS.HitTestInvisible) end)
    return t
end

local function solid(outer, colour)
    local i = mk(IMAGE, outer)
    if not i then error("no Image") end
    pcall(function() i:SetColorAndOpacity(lin(colour)) end)
    pcall(function() i:SetVisibility(VIS.HitTestInvisible) end)
    return i
end

-- diffed setters: e = {w = widget, t = last text, c = last colour table, v = last visibility}
local function setText(e, s)
    s = s or ""
    if e.t == s or not U.ok(e.w) then return end
    e.t = s
    pcall(function() e.w:SetText(U.ftext(s)) end)
end
local function setInk(e, c)
    if e.c == c or not U.ok(e.w) then return end
    e.c = c
    pcall(function() e.w:SetColorAndOpacity({ SpecifiedColor = lin(c), ColorUseRule = 0 }) end)
end
local function setTint(e, c)
    if e.c == c or not U.ok(e.w) then return end
    e.c = c
    pcall(function() e.w:SetColorAndOpacity(lin(c)) end)
end
local function show(e, on)
    if e.v == on or not U.ok(e.w) then return end
    e.v = on
    pcall(function() e.w:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end)
end
local function W(w) return { w = w } end

-- "#RRGGBB" / "RRGGBB" sRGB -> linear (the palette swatches); memoised so the diffed setters compare identities
local hexMemo = {}
local function hexColour(h)
    if type(h) ~= "string" then return nil end
    h = h:gsub("^#", "")
    if #h < 6 then return nil end
    if hexMemo[h] then return hexMemo[h] end
    local function ch(i) return (tonumber(h:sub(i, i + 1), 16) or 0) / 255 end
    local function l1(c) return (c <= 0.04045) and (c / 12.92) or (((c + 0.055) / 1.055) ^ 2.4) end
    local c = { R = l1(ch(1)), G = l1(ch(3)), B = l1(ch(5)), A = 1 }
    hexMemo[h] = c
    return c
end
M.hexColour = hexColour

local function paper(tree, cv, x, y, w, h, z)
    local ok, cp = pcall(U.mod, "couchpanel")
    if ok and type(cp) == "table" and type(cp.paperCover) == "function" then
        local okP, sc = pcall(cp.paperCover, tree, cv, { x, y, w, h }, nil, z)
        if okP and sc then return sc end
    end
    local s = solid(tree, PAPER)
    place(cv, s, x, y, w, h, z)
    return s
end

---------------------------------------------------------------------------------------------------- geometry
-- the areas of n players on the 3840 x 2160 host (the race's split layout): {x, y, w, h, shape}; fillers = the unused
-- quadrant of 3 players. Pure: tests read it.
function M.regionsFor(n)
    n = math.max(1, math.min(4, math.floor(tonumber(n) or 1)))
    if n == 1 then return { { x = 0, y = 0, w = VW, h = VH, shape = "full" } }, {} end
    if n == 2 then
        return { { x = 0, y = 0, w = VW, h = VH / 2, shape = "strip" },
                 { x = 0, y = VH / 2, w = VW, h = VH / 2, shape = "strip" } }, {}
    end
    local q = { { x = 0, y = 0, w = VW / 2, h = VH / 2, shape = "quad" },
                { x = VW / 2, y = 0, w = VW / 2, h = VH / 2, shape = "quad" },
                { x = 0, y = VH / 2, w = VW / 2, h = VH / 2, shape = "quad" },
                { x = VW / 2, y = VH / 2, w = VW / 2, h = VH / 2, shape = "quad" } }
    if n == 3 then return { q[1], q[2], q[3] }, { q[4] } end
    return q, {}
end

-- inside an area of w x h: header, 3D image (16:9), rows, footer. Pure.
function M.areaGeo(w, h)
    local pad = math.floor(h * 0.04 + 0.5)
    local hh = math.floor(h * 0.10 + 0.5)
    local foot = math.floor(h * 0.07 + 0.5)
    local y0 = pad + hh + math.floor(pad / 2)
    local bodyH = h - y0 - foot - pad
    local imgW = math.floor(math.min(w * 0.55, bodyH * 16 / 9))
    local imgH = math.floor(imgW * 9 / 16)
    local rx = pad * 2 + imgW
    local rw = w - rx - pad
    local gap = math.max(4, math.floor(h * 0.008))
    local rh = math.floor(math.min((bodyH - gap * (ROW_MAX - 1)) / ROW_MAX, h * 0.12))
    return { pad = pad, hh = hh, foot = foot, y0 = y0, bodyH = bodyH, imgX = pad, imgY = y0, imgW = imgW, imgH = imgH,
             rx = rx, rw = rw, rh = rh, gap = gap, w = w, h = h }
end

-- header badge width and the gap before the title, in header heights
local BADGE_W, TITLE_GAP = 2.0, 0.35
M.BADGE_W, M.TITLE_GAP = BADGE_W, TITLE_GAP
-- a row's two text lines: label size / top, value size / top (su). UMG font sizes draw ~1.33 su per unit: the label's
-- line box ends at nameY + 1.33 nameS, the value line starts below it. Pure.
function M.rowText(rh)
    local nameS, subS = math.floor(rh * 0.27), math.floor(rh * 0.22)
    local nameY = math.floor(rh * 0.05)
    local subY = math.floor(rh * 0.56)
    return { nameS = nameS, subS = subS, nameY = nameY, subY = subY, nameBottom = nameY + math.ceil(nameS * 1.33),
             subBottom = subY + math.ceil(subS * 1.33) }
end

---------------------------------------------------------------------------------------------------- one area
-- builds an area's widgets on canvas cv at (x, y) w x h (canvas units). -> A (widget handles)
function M.buildArea(tree, cv, x, y, w, h, opts)
    opts = opts or {}
    local g = M.areaGeo(w, h)
    local A = { g = g, rows = {}, last = {} }
    local function at(wd, px, py, pw, ph, z) place(cv, wd, x + px, y + py, pw, ph, z) end
    if opts.paper ~= false then paper(tree, cv, x, y, w, h, 0) end
    -- header: the player's badge, the title, the class chip
    -- live 2026-10-16: "P2GARAGE" - the badge text (Font_Display "P2" ~1.55 x hh wide) ran past a 1.3 hh badge into
    -- the title: the badge is 2 hh wide and the title starts a gap after it
    local bw = math.floor(g.hh * BADGE_W)
    A.badge = W(solid(tree, C.COLOURS.Remote)); at(A.badge.w, g.pad, g.pad, bw, g.hh, 2)
    A.badgeT = W(text(tree, g.hh * 0.62, INKD)); at(A.badgeT.w, g.pad + math.floor(g.hh * 0.18), g.pad + math.floor(g.hh * 0.1), nil, nil, 3)
    A.title = W(text(tree, g.hh * 0.62, DEEP)); at(A.title.w, g.pad + bw + math.floor(g.hh * TITLE_GAP), g.pad + math.floor(g.hh * 0.1), nil, nil, 3)
    A.chip = W(solid(tree, DEEP)); at(A.chip.w, g.rx, g.pad, g.rw, g.hh, 2)
    A.chipT = W(text(tree, g.hh * 0.42, CREAM)); at(A.chipT.w, g.rx + g.pad, g.pad + math.floor(g.hh * 0.22), nil, nil, 3)
    -- the 3D car: a dark frame, the render, the model's name and badge over its bottom band
    A.frame = W(solid(tree, DEEP)); at(A.frame.w, g.imgX - 6, g.imgY - 6, g.imgW + 12, g.imgH + 12, 2)
    A.img = W(mk(IMAGE, tree)); at(A.img.w, g.imgX, g.imgY, g.imgW, g.imgH, 3)
    pcall(function() A.img.w:SetVisibility(VIS.HitTestInvisible) end)
    A.empty = W(text(tree, g.hh * 0.36, PAPER, FONT_BODY)); at(A.empty.w, g.imgX + g.pad, g.imgY + math.floor(g.imgH / 2) - g.pad, nil, nil, 4)
    local bandH = math.floor(g.hh * 0.9)
    A.band = W(solid(tree, SHADE)); at(A.band.w, g.imgX, g.imgY + g.imgH - bandH, g.imgW, bandH, 4)
    A.logo = W(mk(IMAGE, tree)); at(A.logo.w, g.imgX + 12, g.imgY + g.imgH - bandH + 8, bandH - 16, bandH - 16, 5)
    pcall(function() A.logo.w:SetVisibility(VIS.HitTestInvisible) end)
    A.model = W(text(tree, bandH * 0.5, CREAM)); at(A.model.w, g.imgX + bandH + 8, g.imgY + g.imgH - bandH + math.floor(bandH * 0.18), nil, nil, 5)
    -- the rows
    for i = 1, ROW_MAX do
        local ry = g.y0 + (i - 1) * (g.rh + g.gap)
        local R = {}
        R.bg = W(solid(tree, ROW)); at(R.bg.w, g.rx, ry, g.rw, g.rh, 2)
        -- live 2026-10-16: the label's glyphs (a UMG font size draws ~1.33 x as many su) ran into the value line:
        -- smaller label at the row's top, the value line lower (ROW_* below, areaGeo.rowText)
        local rt = M.rowText(g.rh)
        R.name = W(text(tree, rt.nameS, CREAM)); at(R.name.w, g.rx + 24, ry + rt.nameY, nil, nil, 3)
        R.sub = W(text(tree, rt.subS, AMBER, FONT_BODY)); at(R.sub.w, g.rx + 24, ry + rt.subY, nil, nil, 3)
        R.sw = {}
        local s = math.floor(g.rh * 0.5)
        for k = 1, 3 do
            R.sw[k] = W(solid(tree, ROW)); at(R.sw[k].w, g.rx + g.rw - (4 - k) * (s + 10) - 14, ry + math.floor((g.rh - s) / 2), s, s, 4)
            show(R.sw[k], false)
        end
        R.icon = W(mk(IMAGE, tree)); at(R.icon.w, g.rx + g.rw - g.rh - 6, ry + 6, g.rh - 12, g.rh - 12, 4)
        pcall(function() R.icon.w:SetVisibility(VIS.HitTestInvisible) end)
        show(R.icon, false)
        A.rows[i] = R
    end
    -- footer: the hint and a toast; the READY cover over the rows
    A.foot = W(text(tree, g.foot * 0.42, DEEP, FONT_BODY)); at(A.foot.w, g.pad, h - g.foot - math.floor(g.pad / 2), nil, nil, 3)
    A.toast = W(text(tree, g.foot * 0.5, AMBER)); at(A.toast.w, g.rx, h - g.foot - math.floor(g.pad / 2), nil, nil, 4)
    A.cover = W(solid(tree, SHADE)); at(A.cover.w, g.rx, g.y0, g.rw, g.bodyH, 6)
    A.ready = W(text(tree, g.hh * 0.9, CREAM)); at(A.ready.w, g.rx + g.pad, g.y0 + math.floor(g.bodyH * 0.35), nil, nil, 7)
    A.wait = W(text(tree, g.hh * 0.38, PAPER, FONT_BODY)); at(A.wait.w, g.rx + g.pad, g.y0 + math.floor(g.bodyH * 0.35) + g.hh, nil, nil, 7)
    show(A.cover, false); show(A.ready, false); show(A.wait, false)
    return A
end

local function setImage(e, br, kind)
    if not U.ok(e.w) then return end
    if e.br == br and e.kind == kind then return end
    e.br, e.kind = br, kind
    if br == nil then
        pcall(function() e.w:SetBrushResourceObject(nil) end)
        return
    end
    if kind == "texture" then pcall(function() e.w:SetBrushResourceObject(br) end)
    else pcall(function() e.w:SetBrushFromMaterial(br) end) end
end

local function setTex(e, path)
    if e.path == path then return end
    e.path = path
    local t = objOf(path)
    if t then
        pcall(function() e.w:SetBrushFromTexture(t, false) end)
        show(e, true)
    else
        show(e, false)
    end
end

-- vm (garage4's view model): {pnum, colour, who, title, className, model, rows = {{kind, label, sub, desc, icon,
-- colours, focus}}, sel, done, toast, hint, waiting, brush, brushKind, dim}
function M.renderArea(A, vm)
    if type(A) ~= "table" or type(vm) ~= "table" then return end
    setTint(A.badge, vm.colour or C.COLOURS.Remote)
    setText(A.badgeT, vm.who or "")
    setText(A.title, vm.title or "GARAGE")
    setText(A.chipT, vm.className or "")
    setText(A.model, vm.model or "")
    -- the car: the render (material / texture), dimmed while a new pick or livery builds
    local building = vm.brush ~= nil and (vm.brushKind == "building" or (tonumber(vm.dim) or 1) < 0.999)
    setImage(A.img, vm.brush, (vm.brushKind == "texture") and "texture" or "material")
    show(A.img, vm.brush ~= nil)
    local op = building and 0.55 or 1
    if A.img.op ~= op and U.ok(A.img.w) then A.img.op = op; pcall(function() A.img.w:SetRenderOpacity(op) end) end
    setText(A.empty, vm.brush and "" or "3D PREVIEW...")
    show(A.empty, vm.brush == nil)
    local logo = nil
    for _, r in ipairs(vm.rows or {}) do if r.label == "MODEL" then logo = r.icon end end
    setTex(A.logo, logo)
    for i = 1, ROW_MAX do
        local R, r = A.rows[i], vm.rows and vm.rows[i] or nil
        local on = r ~= nil
        show(R.bg, on); show(R.name, on); show(R.sub, on)
        if r then
            local focus = r.focus == true
            setTint(R.bg, focus and AMBER or ROW)
            setInk(R.name, focus and INKD or CREAM)
            setInk(R.sub, focus and INKD or AMBER)
            setText(R.name, r.label or "")
            setText(R.sub, (r.kind == "cycle") and (r.sub or "") or (r.sub or r.desc or ""))
        end
        for k = 1, 3 do
            local c = r and r.colours and hexColour(r.colours[k]) or nil
            show(R.sw[k], c ~= nil)
            if c then setTint(R.sw[k], c) end
        end
        if r and r.label == "MODEL" and r.icon then setTex(R.icon, r.icon) else show(R.icon, false) end
    end
    setText(A.foot, vm.hint or "")
    setText(A.toast, vm.toast or "")
    show(A.cover, vm.done == true); show(A.ready, vm.done == true); show(A.wait, vm.done == true)
    if vm.done then
        setText(A.ready, "READY")
        setText(A.wait, vm.waiting or "")
    end
end

-- the unused quadrant of 3 players (live 2026-10-16: a blank backdrop): paper + a centred teal plate saying what this
-- screen is and how a 4th player joins (a free pad's A joins on the RACERS page: the garage closes for the cards first)
function M.fillerPlate(tree, cv, r)
    paper(tree, cv, r.x, r.y, r.w, r.h, 1)
    local pw, ph = math.floor(r.w * 0.62), math.floor(r.h * 0.42)
    local px, py = r.x + math.floor((r.w - pw) / 2), r.y + math.floor((r.h - ph) / 2)
    local plate = solid(tree, DEEP); place(cv, plate, px, py, pw, ph, 2)
    local band = solid(tree, AMBER); place(cv, band, px, py, pw, math.floor(ph * 0.06), 3)
    local t1 = text(tree, ph * 0.16, CREAM); place(cv, t1, px + math.floor(pw * 0.07), py + math.floor(ph * 0.18), nil, nil, 3)
    local t2 = text(tree, ph * 0.09, PAPER, FONT_BODY); place(cv, t2, px + math.floor(pw * 0.07), py + math.floor(ph * 0.48), nil, nil, 3)
    local t3 = text(tree, ph * 0.09, AMBER, FONT_BODY); place(cv, t3, px + math.floor(pw * 0.07), py + math.floor(ph * 0.66), nil, nil, 3)
    pcall(function() t1:SetText(U.ftext("4-WAY GARAGE")) end)
    pcall(function() t2:SetText(U.ftext("Every player builds their own car at once")) end)
    pcall(function() t3:SetText(U.ftext("P4: press (A) on a free pad to join")) end)
    return { plate = plate, t1 = t1, t2 = t2, t3 = t3 }
end

---------------------------------------------------------------------------------------------------- the host
local H = nil                -- { host, tree, cv, areas = {[slot] = A}, n }

local function buildHost()
    local p1 = U.p1()
    if not U.ok(p1) then error("no P1") end
    local cls = U.class(HOST)
    if not U.ok(cls) then error("host class not loaded") end
    local host = U.WBL():Create(p1, cls, p1)
    if not U.ok(host) then error("host not created") end
    local tree = host.WidgetTree
    local root = tree.RootWidget
    pcall(function()                                   -- only our canvas draws (the blur host's own children hidden)
        for i = root:GetChildrenCount() - 1, 0, -1 do
            local c = root:GetChildAt(i)
            if U.ok(c) then c:SetVisibility(VIS.Collapsed) end
        end
    end)
    local sc = mk(SCALE, tree); pcall(function() sc:SetStretch(2) end)      -- ScaleToFit: 3840 x 2160 su on any screen
    local sb = mk(SIZEB, tree); sb:SetWidthOverride(VW); sb:SetHeightOverride(VH)
    sc:AddChild(sb)
    local cv = mk(CANVAS, tree)
    sb:AddChild(cv)
    local s = root:AddChildToOverlay(sc)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)
    pcall(function() host:SetVisibility(VIS.HitTestInvisible) end)
    host:AddToViewport(tonumber(opt("Garage4Z", 900)) or 900)
    return { host = host, tree = tree, cv = cv, areas = {} }
end

-- the screen for n areas (garage4.open). Raises when it cannot be built (garage4 then stays closed).
function M.open(n)
    if H then M.close("reopen") end
    local t0 = St.nowMs()
    local h = buildHost()
    H = h
    local ok, err = pcall(function()
        local R, fill = M.regionsFor(n)
        local back = solid(h.tree, DEEP); place(h.cv, back, 0, 0, VW, VH, 0)
        for i, r in ipairs(R) do h.areas[i] = M.buildArea(h.tree, h.cv, r.x, r.y, r.w, r.h) end
        h.fill = {}
        for _, r in ipairs(fill) do h.fill[#h.fill + 1] = M.fillerPlate(h.tree, h.cv, r) end
        -- the split's dividers (amber, as the couch panels)
        local hl = solid(h.tree, AMBER); place(h.cv, hl, 0, VH / 2 - 4, VW, 8, 30)
        if #R >= 3 then local vl = solid(h.tree, AMBER); place(h.cv, vl, VW / 2 - 4, 0, 8, VH, 30) end
        if #R == 1 then pcall(function() hl:SetVisibility(VIS.Collapsed) end) end
        h.n = #R
    end)
    if not ok then
        M.close("build failed")
        error(err, 0)
    end
    U.log(TAG, "4-way garage screen: %d area(s) %s, %.1f ms (G4-01)", h.n, (h.n == 2) and "top / bottom" or
        ((h.n == 1) and "full screen" or "quadrants"), St.nowMs() - t0)
    return true
end

function M.render(slot, vm)
    if not H then return false end
    local A = H.areas[slot]
    if not A then return false end
    M.renderArea(A, vm)
    return true
end

function M.close(why)
    local h = H
    H = nil
    if h and U.alive(h.host) then pcall(function() h.host:RemoveFromParent() end) end
    if h then U.dbg(TAG, "screen closed (%s)", tostring(why)) end
end

-- the world went with it: references only
function M.drop(why)
    H = nil
    U.dbg(TAG, "screen dropped (%s)", tostring(why))
end

function M.isUp() return H ~= nil end
function M.areaCount() return H and H.n or 0 end
function M._host() return H end

-- textures / fonts of a dead world are not kept
St.on("world", TAG, function() objs = {}; H = nil end)

return M
