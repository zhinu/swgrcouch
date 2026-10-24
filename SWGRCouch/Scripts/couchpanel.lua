-- couchpanel.lua: COUCH CAMPAIGN - every guest's own area of a build moment (0.15, 2-4 players).
-- Jules 2026-10-14: "when [P1] interacts with something, shop or vehicle edit, then the screen doubles ... and each
-- player gets their options that will only impact their build"; then "Rewards: the screen doubles - can the screen be
-- the same for both left and right? and eventually for 4 players."
-- When P1's native REWARDS screen or a SHOP is up and a joined guest has something to pick, the native screen is
-- shrunk into P1's area (render transform, the subsplit.lua technique) and every joined guest gets his own area:
--   N = 2: halves (P1 left, P2 right; P1's screen at 0.5 with pivot (0, 0.5));
--   N = 3-4: quadrants (P1 top-left at 0.5 with pivot (0, 0); P2 top-right, P3 bottom-left, P4 bottom-right; a 3P
--   bottom-right quadrant gets the paper backdrop only).
-- A guest area shows the guest's own choices (couchrun: mirrored reward round / shop stock), driven by the guest's OWN
-- pad. P1 keeps the native screen with his pad (couch.lua's pad-id swap); a guest's claim changes only his couch-run
-- build.
-- REWARD areas look like the game's own CHOOSE AN UPGRADE screen (notes/research/rogue-mode/07-native-reward-widgets.md
-- §3): per guest a WBP_Media_Background (T_UI_Generic_A_Bg paper) + a standalone WBP_PostRace_Rewards_Layout_Presentation
-- (header, WBP_Item_Btn cards, skip button, WBP_CondensedBuildInfo build panel) owned by the guest's PC, fed with a COPY
-- of the rewards view model (ViewModelSubsystem:BuildRewardsVMForCurrentCampaignEvent returns a fresh object) rewritten
-- with the guest's offer rows; the build panel's own (fresh) VehicleBuildVM is rewritten with the guest's build.
-- NEVER called on a guest instance (07 §1.3/§1.5/§5): RewardRoundComplete, ActivateWidget, AnimateIn,
-- RefreshForNewRewardRound, RefreshBuild; never created for a guest: the Cam_Rewards wrapper, the post-race holder, the
-- outer credits-breakdown screen. The guest widgets are HitTestInvisible and never activated (bAutoActivate off).
-- Fallback: the 0.15 dark list panel (cfg.CouchPanelNative = false, any native build / view-model failure for that guest,
-- and every SHOP: the list is the shop's look).
-- Input: invisible plain /Script/UMG.Button rows focused for the guest's Slate user, polled with HasUserFocus/IsPressed
-- (PlayerInput key state does NOT update for guests while the pad ids are swapped). The focused index is drawn on the
-- native card (its BP_OnFocusReceived/Lost events, or by hand with cfg.CouchPanelNativeHover = false); the native focus
-- event re-runs SetDeltaPart on the guest's build VM, so the guest's build bars are re-applied after every focus event.
-- Scan rules (couch.lua): only couch.activeScreens(), nothing during couch.isQuiet(), U.alive before UFunction calls on
-- found widgets. Every UObject call is pcall-guarded; any build error = the list panel or no panel (native flow untouched).
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")

local TAG = "couchpanel"
local M = {}
-- couch-fix72: the guests' panels are keyed by ident (join.lua); the PAD a guest holds can differ after a
-- REASSIGN CONTROLLERS (padmap.lua). ident -> pad (the same id without a reassignment)
local function padOf(ctrlId)
    if ctrlId == nil then return nil end
    local okM, PM = pcall(require, "padmap")
    if okM and type(PM) == "table" and type(PM.padOfIdent) == "function" then
        local okP, pad = pcall(PM.padOfIdent, ctrlId)
        if okP and type(pad) == "number" then return pad end
    end
    return ctrlId
end
M.padOf = padOf


local function CR() return U.mod("couchrun") end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
-- 4-way garage (cfg.CouchGarage4Way, garage4.lua / garage4ui.lua): the garage areas are drawn by garage4ui (the same
-- look as the front end's 4-way garage) with each guest's 3D car; this module keeps the input (ghost buttons) and rows
local function G4()
    if opt("CouchGarage4Way", false) ~= true then return nil end
    local ok, g = pcall(U.mod, "garage4")
    return (ok and type(g) == "table") and g or nil
end
local function G4UI()
    local ok, g = pcall(U.mod, "garage4ui")
    return (ok and type(g) == "table") and g or nil
end

local okPD, PD = pcall(require, "perkdata")
if not okPD or type(PD) ~= "table" then PD = nil end
local LEVEL_MAX = (PD and tonumber(PD.LEVEL_MAX)) or 10
local ENERGY_BASE = (PD and tonumber(PD.ENERGY_BASE)) or 3

local VIS = C.E.Vis
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local SCALE  = { "/Script/Griffin.FuseScaleBox", "/Script/UMG.ScaleBox" }
local TEXT   = { "/Script/Griffin.FuseTextBlock", "/Script/UMG.TextBlock" }
local SIZEB  = { "/Script/Griffin.FuseSizeBox", "/Script/UMG.SizeBox" }
local HOST = "/Game/Griffin/UI/Widgets/Decorative/WBP_Background_Blur.WBP_Background_Blur_C"
local LAYOUT = "/Game/Griffin/UI/Screens/PostRace/WBP_PostRace_Rewards_Layout_Presentation.WBP_PostRace_Rewards_Layout_Presentation_C"
local MEDIA = "/Game/Griffin/UI/Widgets/Decorative/WBP_Media_Background.WBP_Media_Background_C"
local PAPER_TEX = "/Game/Griffin/UI/Library/Textures/Backgrounds/T_UI_Generic_A_Bg.T_UI_Generic_A_Bg"
local TX = "/Game/Griffin/UI/Library/Textures/"
local FONT_DISPLAY = "/Game/Griffin/UI/Library/Fonts/Font_Display.Font_Display"
local FONT_BODY    = "/Game/Griffin/UI/Library/Fonts/Font_Body.Font_Body"
local LAYOUT_CLS = "WBP_PostRace_Rewards_Layout_Presentation_C"

local PAPER  = { R = 0.776, G = 0.73, B = 0.665, A = 1 }      -- #E4DED5
local CREAM  = { R = 1.0, G = 0.8632, B = 0.6724, A = 1 }     -- #FFEFD7
local AMBER  = { R = 0.745, G = 0.413, B = 0.080, A = 1 }     -- #E0AC50
local DEEP   = { R = 0.008, G = 0.032, B = 0.040, A = 1 }     -- the campaign's dark teal panel
local ROW    = { R = 0.018, G = 0.062, B = 0.074, A = 1 }
local ROWF   = { R = 0.745, G = 0.413, B = 0.080, A = 1 }
local INKD   = { R = 0.006, G = 0.006, B = 0.006, A = 1 }
local SAGE   = { R = 0.3613, G = 0.4564, B = 0.3763, A = 1 }  -- #A2B4A5 (theme.lua SAGE): couchprerun's LOCKED entries
                                                               -- (kit.colours.SAGE was a nil global before 0.15.0 release)
local GRADE  = { [1] = "COMMON", [2] = "RARE", [3] = "EPIC", [4] = "LEGENDARY" }

local VW, VH = 3840, 2160                         -- the host canvas (campaign units)
local ROW_MAX = 6
-- list-panel geometry per region shape: a half (1920 x 2160 design) or a quadrant (2880 x 1620 design, 2/3 scale)
local LIST_GEO = {
    -- nameY / tagY / descY: a row's text lines (live 2026-10-15 final: the quad rows of the 2P strip had the value line
    -- over the label and a narrow 2-line description spilling out of the row); badge = the P2 badge's text size
    half = { dw = 1920, dh = 2160, title = 120, sub = 216, chip = 300, y0 = 430, rh = 250, gap = 24, foot = 140, toast = 260,
             nameS = 44, nameY = 22, tagY = 80, descY = 118, badge = 54 },
    quad = { dw = 2880, dh = 1620, title = 50, sub = 150, chip = 210, y0 = 300, rh = 196, gap = 14, foot = 90, toast = 170,
             nameS = 38, nameY = 8, tagY = 66, descY = 100, badge = 44 },
}
local NAV = { Left = 0, Right = 1, Up = 2, Down = 3, Next = 4, Previous = 5 }    -- EUINavigation
local NAV_STOP, NAV_EXPLICIT = 3, 1                                           -- EUINavigationRule

-- S.panels: one per guest area { ctrlId, pnum, pc, lo, rows, sel, done, view = "native" | "list", slot, region, box,
-- nv (native widgets), lv (list widgets), btns, prev, toast, toastUntil, focusAt, paintAt, mirror, broken }
local S = { open = false, kind = nil, H = nil, panels = {}, n = 2, native = nil, nativeKey = 0, nativeAt = 0,
            lastScan = 0, own = {}, barsLogged = false }
local V = {}             -- the scrap dealer's guest views (FINDING #20, "scrap dealer" below)
-- a guest area that is a SHOP now: the paddock shop, his own shop, or the scrap dealer's SHOP page (FINDING #20)
function V.shopLike(P)
    return S.kind == "shop" or S.kind == "pshop" or (S.kind == "vendor" and P ~= nil and P.vmode == "shop")
end

---------------------------------------------------------------------------------------------------- widgets
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
local function show(w, on) if U.ok(w) then pcall(function() w:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end) end end

local function place(cv, w, x, y, sw, sh, z)
    local s = cv:AddChildToCanvas(w)
    s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    s:SetAlignment({ X = 0, Y = 0 })
    if sw then s:SetAutoSize(false); s:SetSize({ X = sw, Y = sh }) else s:SetAutoSize(true) end
    s:SetPosition({ X = x, Y = y })
    if z then s:SetZOrder(z) end
    return s
end

-- an Overlay child with its alignment (EHorizontalAlignment / EVerticalAlignment: 0 Fill, 2 Center)
local function overlayAdd(ov, w, h, v)
    local s = ov:AddChildToOverlay(w)
    pcall(function() s:SetHorizontalAlignment(h or 0); s:SetVerticalAlignment(v or 0) end)
    return s
end

local fonts = {}
local function font(path)
    if not U.ok(fonts[path]) then fonts[path] = U.obj(path) end
    return fonts[path]
end

local function text(outer, size, colour, fontPath, wrap)
    local t = mk(TEXT, outer)
    if not t then error("no TextBlock") end
    local f = font(fontPath or FONT_DISPLAY)
    if f then pcall(function() t:SetFont({ FontObject = f, TypefaceFontName = U.fname("None"), Size = size }) end) end
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = lin(colour), ColorUseRule = 0 }) end)
    if wrap then pcall(function() t.WrapTextAt = wrap end); pcall(function() t:SetAutoWrapText(true) end) end
    pcall(function() t:SetVisibility(VIS.HitTestInvisible) end)
    return t
end
local function setText(t, s) if U.ok(t) then pcall(function() t:SetText(U.ftext(s or "")) end) end end
-- couch-fix63 (AUTO-154b, live round 8: "READY - WAITING FOR P1" and "... - WAITING FOR P1" cut at the panel / screen
-- edge): the size (<= size) at which s fits maxW su, by theme.textWidth in role (a display role for FONT_DISPLAY, a
-- body role for FONT_BODY), never below minSize. Pure.
function M.fitSize(s, maxW, size, role, minSize)
    size = tonumber(size) or 30
    local w = nil
    pcall(function() w = U.mod("theme").textWidth(s, role, size) end)
    if not (w and maxW and maxW > 0 and w > maxW) then return size end
    return math.max(tonumber(minSize) or 10, math.floor(size * maxW / w))
end
-- setText + the font size that fits maxW (SetFont only when the size changes: t's last size kept on the kit's table)
M._fitSizes = setmetatable({}, { __mode = "k" })
function M.setTextFit(t, s, maxW, size, fontPath, role, minSize)
    if not U.ok(t) then return size end
    local want = M.fitSize(s, maxW, size, role, minSize)
    local fitSizes = M._fitSizes
    if fitSizes[t] ~= want then
        local f = font(fontPath or FONT_DISPLAY)
        if f then pcall(function() t:SetFont({ FontObject = f, TypefaceFontName = U.fname("None"), Size = want }) end) end
        fitSizes[t] = want
    end
    setText(t, s)
    return want
end
local function setInk(t, c) if U.ok(t) then pcall(function() t:SetColorAndOpacity({ SpecifiedColor = lin(c), ColorUseRule = 0 }) end) end end

local function solid(outer, colour)
    local i = mk(IMAGE, outer)
    if not i then error("no Image") end
    pcall(function() i:SetColorAndOpacity(lin(colour)) end)
    pcall(function() i:SetVisibility(VIS.HitTestInvisible) end)
    return i
end

local function texOf(rel)
    if type(rel) ~= "string" or rel == "" then return nil end
    local path = rel
    if not rel:find("^/Game/") then
        local n = rel:match("([^/]+)$")
        path = TX .. rel .. "." .. n
    elseif not rel:find("%.") then
        path = rel .. "." .. rel:match("([^/]+)$")
    end
    local t = nil
    pcall(function() t = U.obj(path) end)
    if not U.ok(t) then pcall(function() t = LoadAsset(path) end) end
    return U.ok(t) and t or nil
end

local function brush(img, rel)
    local t = texOf(rel)
    if t and U.ok(img) then pcall(function() img:SetBrushFromTexture(t, false) end) end
    return t ~= nil
end

local function own(w) if U.ok(w) then S.own[U.key(w)] = true end end

-- every CommonActivatableWidget INSIDE one of our copies (the shop copy's WBP_Shop_MainSelectionPanel_Presentation is
-- an activatable of its own): live 2026-10-14 22:20 it was listed by couch.activeScreens as a guest-owned screen, so
-- (1) findNative kept it as "P1's native shop" after P1 left: the split never closed ("LEFT THE SHOP - WAITING FOR
-- P1" forever), and (2) couch's swap refocused into it, so P1's pad had no cursor in the real shop (D-pad and A dead).
local function ownInside(root)
    if not U.ok(root) then return 0 end
    local rk, n = U.key(root), 0
    for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
        if U.ok(w) and not S.own[U.key(w)] then
            local x = w
            for _ = 1, 12 do
                x = U.outerOf(x)
                if not U.ok(x) then break end
                if U.key(x) == rk then own(w); n = n + 1; break end
            end
        end
    end
    return n
end

---------------------------------------------------------------------------------------------------- the credits chip
-- Jules 2026-10-14 (paddock shop): "hibi's shop for P2 shows 1800 whereas on top right side 2300" + "the coins don't
-- decrease after purchase, and the design is horrible for coins". The guest copies (shop layout, rewards layout, build
-- page) each carry the game's header (WBP_Header_Presentation, ShowCurrency on) whose credits chip is
-- WBP_PlayerCreditsAmount_C. Decoded (cue4cli --script, 2026-10-14): NOT bound to any view model - its Tick reads
-- UIBlueprintFunctionLibrary:GetCreditsForCurrentPrimaryFlow (= P1's run credits) into TargetCreditsAmount,
-- interpolates CampaignSubsystem's LastVisualCredits towards it and writes self.Txt_PlayerCredits:SetText(Conv_IntToText
-- grouped: "1,800") whenever Target ~= CurrentSetValue / LastVisual. So every copy showed P1's credits, and moved
-- only when P1's changed. Fix: the chip's Txt_PlayerCredits PROPERTY is pointed at a detached dummy TextBlock: its
-- Tick writes P1's number there, the real text (still in the chip's tree, the native font / icon / pill) gets ONLY
-- the guest's couch credits (chipFeed, on every render: after each buy at once). If the property write does not stick,
-- the couchbets technique: settle CurrentSetValue = TargetCreditsAmount, then his number (re-applied every render).
local CHIP_CLS = "/Game/Griffin/UI/Widgets/BlackMarket/WBP_PlayerCreditsAmount.WBP_PlayerCreditsAmount_C"

-- pure: the native chip's number format (Conv_IntToText grouped, en): 1800 -> "1,800"
local function groupDigits(n)
    n = math.floor(tonumber(n) or 0)
    local neg = n < 0
    local out = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (neg and "-" or "") .. out
end

-- chip: a WBP_PlayerCreditsAmount_C (never P1's own: a copy's / one we created). -> {chip, txt, swapped} or nil
local function chipRewire(chip)
    if not U.ok(chip) then return nil end
    local real = nil
    pcall(function() real = chip.Txt_PlayerCredits end)
    if not U.ok(real) then return nil end
    local swapped = false
    local dummy = mk(TEXT, chip)
    if dummy then
        pcall(function() chip.Txt_PlayerCredits = dummy end)
        pcall(function() swapped = U.key(chip.Txt_PlayerCredits) == U.key(dummy) end)
        if not swapped then pcall(function() chip.Txt_PlayerCredits = real end) end
    end
    return { chip = chip, txt = real, swapped = swapped }
end

-- the guest's credits into a rewired chip -> true when shown
local function chipFeed(c, credits)
    if not (c and U.ok(c.txt)) then return false end
    if not c.swapped then
        pcall(function() c.chip.CurrentSetValue = c.chip.TargetCreditsAmount end)
    end
    local ok = pcall(function() c.txt:SetText(U.ftext(groupDigits(credits))) end)
    if ok then c.shown = math.floor(tonumber(credits) or 0) end
    return ok
end

-- an Image drawing a material as a Box (margin 0.5: the game's pills), tinted; a plain solid when SetBrush with a
-- table is refused (then opaque: translucent solids never draw)
local PILL_TAG = "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_Generic.MI_UI_Pill_Generic"
local function pillImage(outer, matPath, colour)
    local img = mk(IMAGE, outer)
    if not img then error("no Image") end
    local mat = nil
    pcall(function() mat = U.obj(matPath) end)
    local c = { R = colour.R, G = colour.G, B = colour.B, A = colour.A or 1 }
    local ok = U.ok(mat) and pcall(function()
        img:SetBrush({ ResourceObject = mat, ImageSize = { X = 128, Y = 128 }, DrawAs = 1,
                       Margin = { Left = 0.5, Top = 0.5, Right = 0.5, Bottom = 0.5 },
                       TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }, ImageType = 1 })
    end)
    if not ok then c.A = 1 end
    pcall(function() img:SetColorAndOpacity(lin(c)) end)
    pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
    return img
end

-- NOTE 4 (split areas): the copy's header pill gets the guest's rounded P-tag at its right end, laid out by the pill
-- itself (a child of the chip's parent HorizontalBox HB_Currency, after the credits). The copy's token pips
-- (WBP_Cam_StrikesWidget: its Tick reads the active CampaignRun's GetMaxStrikes / GetSeenStrikes) STAY: League Tokens
-- are the TEAM's (one run, shared - couchrules books every human's result into it), so the guest's header shows them
-- like P1's (they used to be collapsed: "P2's header looks incomplete").
-- the rounded P-tag as the LAST child of a credits chip's own HorizontalBox (the header pill's HB_Currency), laid out
-- by the pill itself: inside it, after the credits / token pips, with the pill's own right padding. -> the tag's box
local function tagInto(chip, pnum)
    local hb = nil
    pcall(function() hb = chip:GetParent() end)
    if not U.ok(hb) then return nil end
    local sb = mk(SIZEB, chip)
    local ov = mk(OVER, chip)
    if not (sb and ov) then return nil end
    pcall(function() sb:SetWidthOverride(52); sb:SetHeightOverride(40) end)
    pcall(function() sb:AddChild(ov) end)
    local col = C.COLOURS and C.COLOURS[pnum] or AMBER
    overlayAdd(ov, pillImage(chip, PILL_TAG, col), 0, 0)
    local t = text(chip, 24, (C.COLOUR_INK and C.COLOUR_INK[pnum]) or INKD)
    setText(t, "P" .. tostring(pnum))
    overlayAdd(ov, t, 2, 2)
    local slot = nil
    pcall(function() slot = hb:AddChildToHorizontalBox(sb) end)
    pcall(function() slot:SetPadding({ Left = 16, Top = 0, Right = 0, Bottom = 0 }) end)
    pcall(function() slot:SetVerticalAlignment(2) end)
    pcall(function() slot:SetHorizontalAlignment(2) end)
    return sb
end

-- NOTE 7: one game credits chip on a host canvas, right-aligned at (right, top), k = scale of the 105-su native pill:
-- the header backer (MI_UI_Pill_FE_Section_CurrencyBacker, Box 0.5, #131313 @0.90), the game's WBP_PlayerCreditsAmount
-- (rewired to `credits` for a guest: rewire = true; P1's own chip reads his run itself), the rounded P-tag inside the
-- pill's right end. Width = the guest chip of couch.lua's row (glyph-measured number). -> {rect, nat, chipW, tagRect}
local CHIP_PILL_MAT = "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_FE_Section_CurrencyBacker.MI_UI_Pill_FE_Section_CurrencyBacker"
local function numW(credits)
    local w = 0
    for ch in groupDigits(credits):gmatch(".") do w = w + (({ ["1"] = 22, [","] = 12 })[ch] or 53) end
    return w
end
local function chipAt(H, right, top, k, pnum, credits, rewire)
    k = tonumber(k) or 1
    local w = math.floor((16 + 87 + math.max(173, numW(credits)) + 18 + 52 + 18) * k + 0.5)
    local h = math.floor(105 * k + 0.5)
    local x = math.floor(right - w + 0.5)
    local out = { rect = { x, top, w, h }, parts = {} }       -- parts: every widget it put on the host canvas
    local pill = pillImage(H.tree, CHIP_PILL_MAT, { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.9 })
    out.parts[#out.parts + 1] = pill
    place(H.cv, pill, x, top, w, h, 30)
    local p1 = U.p1()
    local okC, cw = pcall(function() return U.WBL():Create(p1, U.class(CHIP_CLS), p1) end)
    if okC and U.ok(cw) then
        local okP, slot = pcall(place, H.cv, cw, x + math.floor(16 * k), top + h / 2, nil, nil, 31)
        if okP and slot then
            pcall(function() slot:SetAlignment({ X = 0, Y = 0.5 }) end)
            pcall(function() cw:SetRenderTransformPivot({ X = 0, Y = 0.5 }) end)
            pcall(function() cw:SetRenderScale({ X = 0.96 * k, Y = 0.96 * k }) end)
            pcall(function() cw:SetVisibility(VIS.HitTestInvisible) end)
            out.chipW = cw
            out.parts[#out.parts + 1] = cw
            if rewire then out.nat = chipRewire(cw) end
        end
    end
    local tw, th = math.floor(52 * k + 0.5), math.floor(40 * k + 0.5)
    local tx, ty = x + w - math.floor(18 * k + 0.5) - tw, top + math.floor((h - th) / 2 + 0.5)
    out.tagRect = { tx, ty, tw, th }
    local col = C.COLOURS and C.COLOURS[pnum] or AMBER
    local tagPill = pillImage(H.tree, PILL_TAG, col)
    out.parts[#out.parts + 1] = tagPill
    place(H.cv, tagPill, tx, ty, tw, th, 32)
    local t = text(H.tree, math.max(14, math.floor(22 * k + 0.5)), (C.COLOUR_INK and C.COLOUR_INK[pnum]) or INKD)
    out.parts[#out.parts + 1] = t
    setText(t, "P" .. tostring(pnum))
    local s2 = place(H.cv, t, tx + tw / 2, ty + th / 2, nil, nil, 33)
    pcall(function() s2:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    if out.nat then chipFeed(out.nat, credits) end
    return out
end

local headerOf
local function headerTag(root, P, c)
    local hdr = headerOf(root) or (P and P.nv and P.nv.hdr)
    -- the team's tokens: visible (a copy inherits nothing collapsed from an older build of this panel either)
    if hdr then pcall(function() hdr.WBP_Cam_StrikesWidget:SetVisibility(VIS.SelfHitTestInvisible) end) end
    return tagInto(c.chip, P.pnum)
end

-- the header chip of a copied screen (shop layout / rewards layout / build page) -> rewired chip or nil
-- the header of a copied screen: a BP variable on the shop layout / build page, NOT on the rewards layout (decoded
-- WBP_PostRace_Rewards_Layout_Presentation: WBP_Header_Presentation bIsVariable false - live "the copy's credits chip
-- not found") -> the widget tree by name (UUserWidget:GetWidgetFromName)
headerOf = function(root)
    local hdr = nil
    pcall(function() hdr = root.WBP_Header_Presentation end)
    if U.ok(hdr) then
        local c = nil
        pcall(function() c = hdr.WBP_PlayerCreditsAmount end)
        if U.ok(c) then return hdr end
    end
    hdr = nil
    pcall(function() hdr = root:GetWidgetFromName(U.fname("WBP_Header_Presentation")) end)
    return U.ok(hdr) and hdr or nil
end

-- NOTE 9 (live s77: P2's rewards copy still showed P1's 6,300 and the token pips: neither the property nor the named
-- lookup reached its chip): the copy's own WBP_PlayerCreditsAmount found by OWNERSHIP - every live instance whose outer
-- chain (chip -> WidgetTree -> header -> WidgetTree -> the copy) ends at this copy; once, at build time
local function chipByOuter(root)
    local list = nil
    pcall(function() list = FindAllOf("WBP_PlayerCreditsAmount_C") end)
    if type(list) ~= "table" then return nil, nil end
    local rk = U.key(root)
    for _, c in ipairs(list) do
        if U.ok(c) then
            local o, hdr = c, nil
            for depth = 1, 8 do
                local nxt = nil
                if U.ok(o) then pcall(function() nxt = o:GetOuter() end) end
                if not U.ok(nxt) then break end
                if depth == 2 then hdr = nxt end                         -- chip -> WidgetTree -> its header widget
                if U.key(nxt) == rk then return c, hdr end
                o = nxt
            end
        end
    end
    return nil, nil
end

local function headerChip(root, P)
    local chip, how = nil, "header property"
    local hdr = headerOf(root)
    if hdr then pcall(function() chip = hdr.WBP_PlayerCreditsAmount end) end
    if not U.ok(chip) then
        local c2, h2 = chipByOuter(root)
        if U.ok(c2) then chip, how = c2, "found by ownership" end
        if U.ok(h2) and not hdr then hdr = h2 end
    end
    if P and P.nv then P.nv.hdr = hdr end
    local c = chipRewire(chip)
    if c then
        c.how = how
        local okT, tag = pcall(headerTag, root, P, c)
        c.tag = okT and tag or nil
        if not okT then U.warn(TAG, "P%s: header P-tag not added (%s)", tostring(P and P.pnum), tostring(tag)) end
    end
    U.log(TAG, "P%s: the copy's credits chip %s%s", tostring(P and P.pnum or "?"),
        c and (c.swapped and "rewired to his credits" or "settled to his credits (no property swap)") or "not found",
        c and (" (" .. tostring(c.how) .. ")") or "")
    return c
end

-- an invisible plain UMG Button: Slate delivers the guest's D-pad / A to the widget focused for his user
local function ghostButton(tree, cv, x, y, w, h)
    local b = mk({ "/Script/UMG.Button" }, tree)
    if not b then return nil end
    place(cv, b, x, y, w, h, 50)
    pcall(function() b:SetRenderOpacity(0.01) end)
    return b
end

-- explicit D-pad navigation between one guest's buttons, Stop at the edges: Slate's geometric navigation would walk
-- into another guest's buttons on the shared host canvas (3-4 players)
local function navTo(b, dir, target)
    if not U.ok(b) then return end
    if U.ok(target) then
        if pcall(function() b:SetNavigationRuleExplicit(dir, target) end) then return end
    end
    pcall(function() b:SetNavigationRuleBase(dir, NAV_STOP) end)
end

local function navList(btns, n)
    for i = 1, n do
        local b = btns[i]
        navTo(b, NAV.Up, i > 1 and btns[i - 1] or nil)
        navTo(b, NAV.Down, i < n and btns[i + 1] or nil)
        navTo(b, NAV.Left, nil); navTo(b, NAV.Right, nil); navTo(b, NAV.Next, nil); navTo(b, NAV.Previous, nil)
    end
end

-- native view: cards in a row (Left / Right), the skip button below them (Down from any card, Up = the middle card)
local function navCards(btns, nCards, hasSkip)
    local skip = hasSkip and btns[nCards + 1] or nil
    for i = 1, nCards do
        local b = btns[i]
        navTo(b, NAV.Left, i > 1 and btns[i - 1] or nil)
        navTo(b, NAV.Right, i < nCards and btns[i + 1] or nil)
        navTo(b, NAV.Up, nil)
        navTo(b, NAV.Down, skip)
        navTo(b, NAV.Next, nil); navTo(b, NAV.Previous, nil)
    end
    if skip then
        navTo(skip, NAV.Up, btns[math.max(1, math.ceil(nCards / 2))])
        navTo(skip, NAV.Left, nil); navTo(skip, NAV.Right, nil); navTo(skip, NAV.Down, nil)
        navTo(skip, NAV.Next, nil); navTo(skip, NAV.Previous, nil)
    end
end

---------------------------------------------------------------------------------------------------- geometry
-- areas in host units: [0] = P1, [1..3] = guest slots in join order
local function regionsFor(n)
    if n <= 2 then
        -- top / bottom strips (couchlayout): the 16:9 content is centred at half size, the paper fills the strip
        return { [0] = { x = 0, y = 0, w = 3840, h = 1080, shape = "quad", strip = true },
                 { x = 0, y = 1080, w = 3840, h = 1080, shape = "quad", strip = true } }
    end
    return { [0] = { x = 0, y = 0, w = 1920, h = 1080, shape = "quad" },
             { x = 1920, y = 0, w = 1920, h = 1080, shape = "quad" },
             { x = 0, y = 1080, w = 1920, h = 1080, shape = "quad" },
             { x = 1920, y = 1080, w = 1920, h = 1080, shape = "quad" } }
end
M.regionsFor = regionsFor

-- a region's ScaleBox(ScaleToFit) -> SizeBox(dw x dh) on the host canvas
local function regionBox(H, r, dw, dh)
    local sc = mk(SCALE, H.tree)
    if not sc then error("no ScaleBox") end
    pcall(function() sc:SetStretch(2) end)                                      -- ScaleToFit
    place(H.cv, sc, r.x, r.y, r.w, r.h, 1)
    local sb = mk(SIZEB, H.tree)
    if not sb then error("no SizeBox") end
    sb:SetWidthOverride(dw); sb:SetHeightOverride(dh)
    sc:AddChild(sb)
    return sc, sb
end

---------------------------------------------------------------------------------------------------- host
local function buildHost()
    local p1 = U.p1()
    if not U.ok(p1) then error("no P1") end
    local cls = U.class(HOST)
    if not U.ok(cls) then error("host class not loaded") end
    local host = U.WBL():Create(p1, cls, p1)
    if not U.ok(host) then error("host not created") end
    local tree = host.WidgetTree
    local root = tree.RootWidget
    -- hide the blur host's own children: only our canvas draws (the native screen keeps its look in P1's area)
    pcall(function()
        for i = root:GetChildrenCount() - 1, 0, -1 do
            local c = root:GetChildAt(i)
            if U.ok(c) then c:SetVisibility(VIS.Collapsed) end
        end
    end)
    local sc = mk(SCALE, tree); pcall(function() sc:SetStretch(2) end)
    local sb = mk(SIZEB, tree); sb:SetWidthOverride(VW); sb:SetHeightOverride(VH)
    sc:AddChild(sb)
    local cv = mk(CANVAS, tree)
    sb:AddChild(cv)
    overlayAdd(root, sc, 0, 0)
    -- in the viewport BEFORE the guest widgets are added: their Construct runs on AddChild (the build panel's
    -- VehicleBuildVM exists right after it)
    host:AddToViewport(tonumber(opt("CouchPanelZ", 1000)) or 1000)
    return { host = host, tree = tree, cv = cv }
end

-- (7) Jules (live, jules-ratio-004442): the paper on the strips' sides was the WHOLE paper texture squeezed into each
-- 960-wide side (couchroot) / stretched over the 3840 x 1080 strip (couchprerun, couchbets): circles became ovals.
-- The game's own WBP_Media_Background draws its paper through FuseScaleBox Stretch = ScaleToFill (decoded): the
-- texture keeps its aspect, scaled to COVER the area, the overflow cropped. paperCover does the same for any rect:
-- an Image at the texture's own size (SetBrushFromTexture matchSize) in a ScaleBox ScaleToFill that covers `full`
-- (default: the rect itself), clipped to `rect` - several side pieces of one strip (full = the strip) are crops of the
-- SAME continuous backdrop (Jules's 21:9 reference), never a texture per piece. rect / full = {x, y, w, h} in the
-- canvas' units. -> the outer widget (ScaleBox, or the clip canvas for a piece) or nil
local STRETCH_FILL, CLIP_BOUNDS = 5, 1              -- EStretch::ScaleToFill, EWidgetClipping::ClipToBounds
local function paperCover(tree, cv, rect, full, z)
    full = full or rect
    local x, y, w, h = rect[1], rect[2], rect[3], rect[4]
    if not (w and h and w > 0 and h > 0) then return nil end
    local sc = mk(SCALE, tree)
    if not sc then return nil end
    pcall(function() sc:SetStretch(STRETCH_FILL) end)
    pcall(function() sc:SetClipping(CLIP_BOUNDS) end)
    local img = mk(IMAGE, tree)
    if img then
        local tex = texOf(PAPER_TEX)
        if tex then pcall(function() img:SetBrushFromTexture(tex, true) end)                  -- its own size / aspect
        else pcall(function() img:SetColorAndOpacity(lin(PAPER)) end) end
        pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
        pcall(function() sc:AddChild(img) end)
    end
    pcall(function() sc:SetVisibility(VIS.HitTestInvisible) end)
    local same = full[1] == x and full[2] == y and full[3] == w and full[4] == h
    if same then
        place(cv, sc, x, y, w, h, z or 0)
        return sc
    end
    -- a piece: a clipping canvas on the rect, the strip-sized cover inside it at the strip's offset
    local clip = mk(CANVAS, tree)
    if not clip then return nil end
    pcall(function() clip:SetClipping(CLIP_BOUNDS) end)
    pcall(function() clip:SetVisibility(VIS.HitTestInvisible) end)
    place(cv, clip, x, y, w, h, z or 0)
    place(clip, sc, full[1] - x, full[2] - y, full[3], full[4])
    return clip
end
M.paperCover = paperCover

local function paperBackdrop(H, outer, ov, ownerPc)
    local cls = U.class(MEDIA)
    if not U.ok(cls) then return nil end
    local bg = U.WBL():Create(ownerPc, cls, ownerPc)
    if not U.ok(bg) then return nil end
    local paper = texOf(PAPER_TEX)
    if paper then pcall(function() bg.Texture = paper end) end              -- before the add: PreConstruct reads it
    pcall(function() bg.ShowVideo = false end)
    overlayAdd(ov, bg, 0, 0)
    if paper then pcall(function() bg.Img_Background:SetBrushFromTexture(paper, false) end) end
    pcall(function() bg:SetVisibility(VIS.HitTestInvisible) end)
    own(bg)
    return bg
end

---------------------------------------------------------------------------------------------------- offer rows -> card data
local function arch() local ok, a = pcall(function() return CR().campaignArch() end); return ok and a or nil end
-- couch-fix64 (AUTO-158b, live round 9 shot hibi-p2-packopen: P2 on a Skim Speeder, his UPGRADE PACK's first card drawn
-- DRIFT "Stronger Drift ..." = P1's Landspeeder move, while the log offered and gave KNIFE EDGE +2): a card's class
-- move follows HIS class (his couchrun record's arch, read only: never couchrun.ensure from a paint), P1's only when he
-- has none
function M.archOfP(P)
    if P and P.ctrlId ~= nil then
        local ok, a = pcall(function()
            local p = CR().player(P.ctrlId)
            return p and tonumber(p.arch) or nil
        end)
        if ok and a ~= nil and a ~= 1 then return a end
    end
    return arch()
end

-- -> { title, desc, large, icon, q (EGfnRarity), itype (1 upgrade, 2 ability, 3 modifier, 4 affix), level }
local function rowInfo(row, lo, guestArch)
    local k, id = row.rkind, row.id
    local out = { title = tostring(row.name or id or ""), desc = tostring(row.desc or ""), q = 0, itype = 2 }
    if not PD then return out end
    if k == "stat" then
        local st = PD.STATS and PD.STATS[id]
        local name = st and st.name or out.title
        local a = guestArch
        if a == nil then a = arch() end
        if id == 5 and a and PD.ADVANCED and PD.ADVANCED[a] then name = PD.ADVANCED[a] end
        out.title, out.desc = name, st and (st.rich or st.desc) or ""
        if id == 5 and a and PD.ADVANCED_DESC and PD.ADVANCED_DESC[a] then out.desc = PD.ADVANCED_DESC[a] end
        out.large, out.icon, out.itype = st and st.large, st and st.icon, 1
        out.level = math.floor(tonumber(lo and lo.tune and lo.tune[id]) or 0)
    elseif k == "upgrade" then
        local st = PD.STATS and PD.STATS[5]
        out.title, out.desc, out.q, out.itype = "LEVEL CAP", "Raises the level cap of every build stat by 1.", 3, 1
        out.large, out.icon, out.level = st and st.large, st and st.icon, 0
    elseif k == "ab" or k == "crash" then
        local a = PD.ABILITIES and PD.ABILITIES[id]
        if a then
            out.title, out.desc, out.large, out.icon = a.name, a.rich or a.desc or "", a.large or a.icon, a.icon
            out.q = math.max(0, math.min(3, (tonumber(a.lvl) or 1) - 1))
        end
    elseif k == "part" then
        local p = PD.PARTS and PD.PARTS[id]
        if p then
            out.title, out.desc, out.large, out.icon = p.name, p.rich or p.desc or "", p.large or p.icon, p.icon
            out.q, out.faulty = math.max(0, math.min(3, tonumber(p.rarity) or 0)), p.faulty == true
        end
        -- #73: a scrap dealer's EXPERIMENTAL part: the card's FAULT box = its drawback (the affix's FaultyEffect)
        local f = row.fault and PD.PARTS and PD.PARTS[row.fault]
        if f then out.faulty, out.faultTitle, out.faultDesc = true, f.name, f.rich or f.desc or "" end
        out.itype = 4
    elseif k == "trait" then
        local t = PD.TRAITS and PD.TRAITS[id]
        if t then out.title, out.desc, out.large, out.icon = t.name, t.rich or t.desc or "", t.large or t.icon, t.icon end
        out.q, out.itype = 1, 3
    end
    return out
end
M.rowInfo = rowInfo

local function setEffect(it, field, title, desc, rarity)
    local ok = pcall(function()
        local e = it[field]
        e.Title = U.ftext(title); e.Description = U.ftext(desc); e.Rarity = rarity
    end)
    if not ok then
        pcall(function() it[field] = { Title = U.ftext(title), Description = U.ftext(desc), Rarity = rarity } end)
    end
end

-- one CampaignItemVM of the COPY: the guest's offer (the copy keeps P1's Item: GetItemType may read through it).
-- keepType (the SHOP, BUG-12 root cause, static 2026-10-14): ItemType (+0x1A4) is NOT written. Natives switch on it and
-- read the VM's Item (+0x1A8) as that kind: ShopVMBase:RefreshDeltaForAllItems (exec thunk 0x147160238 -> vslot 0x2c8
-- = 0x14307c184) walks UpgradeParts / Affixes / Abilities and calls the item delta 0x14714acf6, whose VehicleUpgrade
-- case (ItemType 1) reads Item+0x30+0x20 -> +0x90 (0x14714adf8). The copy's Affixes hold affix Items: a guest stat row
-- written as ItemType 1 made that read null+0x90 = the live AV, inside lay:Init (MainSelection Init -> InitItems ->
-- RefreshAfterBuildChange). SetDeltaPart (a card's focus) reads the same way. The reward layout only switches its card
-- LOOK on GetItemType (BP, no native delta): there the type is still written.
local function writeItem(it, info, keepType)
    pcall(function() it.PlayerFacingName = U.ftext(info.title) end)
    pcall(function() it.Subtitle = U.ftext(info.title) end)
    pcall(function() it.Description = U.ftext(info.desc) end)
    pcall(function() it.Quality = info.q end)
    if not keepType then pcall(function() it.ItemType = info.itype end) end
    pcall(function() it.bIsAvailable = true end)
    pcall(function() it.bIsNew = false end)
    pcall(function() it.bWillReplaceItem = false end)
    pcall(function() it.CreditsValue = 0 end)
    -- the "+1" of a stat card: written when the card IS a stat card (rewards: keepType = the native type 1)
    if info.itype == 1 and (not keepType or keepType == 1) then
        pcall(function() it.Level = info.level or 0 end)
        pcall(function() it.DeltaLevel = -1 end)                               -- shows "+1"
    end
    if info.faulty then setEffect(it, "FaultyEffect", info.faultTitle or info.title, info.faultDesc or info.desc, 4)
    else setEffect(it, "FaultyEffect", "", "", 0) end
end

---------------------------------------------------------------------------------------------------- P1's view models
-- keys of P1's live reward VMs (his native layout's RewardsVM and its build panel's VehicleBuildVM); {} when unknown
local function p1VmKeys()
    local keys = { rewards = 0, build = 0, found = false }
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return keys end
    for _, e in ipairs(list) do
        if e.cls == LAYOUT_CLS and not S.own[U.key(e.w)] and U.alive(e.w) then
            pcall(function() keys.rewards = U.key(e.w.RewardsVM) end)
            pcall(function() keys.build = U.key(e.w.WBP_CondensedBuildInfo_Presentation.VehicleBuildVM) end)
            keys.found = true
            return keys
        end
    end
    return keys
end

-- P1's CHOOSE AN UPGRADE round: found (his native layout is up), n = its RewardsVM item count
local function p1RoundItems()
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return false, 0 end
    for _, e in ipairs(list) do
        if e.cls == LAYOUT_CLS and not S.own[U.key(e.w)] and U.alive(e.w) then
            local n = 0
            pcall(function() n = #U.arrayToTable(e.w.RewardsVM.Items) end)
            return true, n
        end
    end
    return false, 0
end
M._p1RoundItems = p1RoundItems

local function vms()
    local v = U.giSubsystem("ViewModelSubsystem")
    if not U.ok(v) then error("no ViewModelSubsystem") end
    return v
end

local function abilityCDO(id)
    local a = PD and PD.ABILITIES and PD.ABILITIES[id]
    if not a or type(a.cls) ~= "string" then return nil end
    local pkg, cn = a.cls:match("^(.-)%.([%w_]+)$")
    if not pkg then return nil end
    local ok, o = pcall(StaticFindObject, pkg .. ".Default__" .. cn)   -- find only: never a blocking load here
    return (ok and U.ok(o)) and o or nil
end

---------------------------------------------------------------------------------------------------- guest build panel
local function focusedStat(P)
    if P.done then return nil end
    local row = P.rows and P.rows[P.sel]
    if row and row.rkind == "stat" then return tonumber(row.id) end
    return nil
end

local function battery(l)
    local t = PD and PD.BATTERY
    l = math.max(0, math.min(LEVEL_MAX, math.floor(tonumber(l) or 0)))
    return t and (tonumber(t[l]) or 0) or l
end

-- the guest's levels on the panel's stat bars + energy; re-run after every native focus event (SetDeltaPart rewrites
-- the bars from P1's build state)
local function reapplyBuild(P)
    local nv = P.nv
    if not nv or not U.ok(nv.bvm) or not U.alive(nv.panel) then return end
    local lo, bvm, panel = P.lo or {}, nv.bvm, nv.panel
    local tune = lo.tune or {}
    local ds = focusedStat(P)
    local bars = {}
    pcall(function() bars = U.arrayToTable(bvm.StatBars) end)
    for _, bar in ipairs(bars) do
        if U.ok(bar) then
            pcall(function()
                local s = tonumber(bar.Slot) or -1
                local lv = math.floor(tonumber(tune[s]) or 0)
                local mx = tonumber(bar.MaxValue) or LEVEL_MAX
                if mx <= 0 then mx = LEVEL_MAX end
                -- level units when the bar's max is a level (<= LEVEL_MAX), else scaled to the bar's range
                local k = (mx > LEVEL_MAX + 0.5) and (mx / LEVEL_MAX) or 1
                if k == 1 and lv + (ds == s and 1 or 0) > mx then bar.MaxValue = lv + (ds == s and 1 or 0) end
                bar.Value = lv * k
                bar.BaseValue = lv * k
                bar.Delta = (ds == s) and k or 0
            end)
        end
    end
    pcall(function() panel.LV_Stats:RegenerateAllEntries() end)
    local l4 = math.floor(tonumber(tune[4]) or 0)
    local e = ENERGY_BASE + battery(l4)
    local de = (ds == 4 and l4 < LEVEL_MAX) and (battery(l4 + 1) - battery(l4)) or 0
    pcall(function() bvm.Energy = e; bvm.EnergyDelta = de; bvm.EnergyTemp = 0 end)
    pcall(function() panel.WBP_MiniBuildStat_MaxEnergy:SetEnergy(e, de, 0) end)
    if nv.statsPanel then pcall(function() panel:RefreshStats() end) end      -- the shop's WBP_BuildStatsPanel
end

-- the build panel's icons: abilities, crash ability, racer style, affix chips (after the lists generated their entries)
local function paintBuildIcons(P)
    local nv = P.nv
    if not nv or not U.alive(nv.panel) or not PD then return end
    local lo, panel = P.lo or {}, nv.panel
    local crashKey = 0
    pcall(function() crashKey = U.key(panel.WBP_CrashAbility) end)
    local kids = {}
    pcall(function() kids = U.arrayToTable(panel.GP_Abilities:GetAllChildren()) end)
    local n = 0
    for _, c in ipairs(kids) do
        if U.ok(c) and U.key(c) ~= crashKey then
            local img = nil
            pcall(function() img = c.Img_AbilityIcn end)
            if U.ok(img) then
                n = n + 1
                local id = lo.ab and lo.ab[n]
                local a = id and PD.ABILITIES and PD.ABILITIES[id]
                brush(img, a and a.icon or PD.EMPTY_ICON)
            end
        end
    end
    pcall(function()
        local a = lo.crash and PD.ABILITIES and PD.ABILITIES[lo.crash]
        brush(panel.WBP_CrashAbility.Img_AbilityIcn, a and a.icon or (PD.CRASH_FAM and PD.CRASH_FAM.icon))
    end)
    pcall(function()
        local st = lo.style and PD.STYLES and PD.STYLES[lo.style]
        if st and st.icon then brush(panel.Img_RacerStyleIcn, st.icon) end
    end)
    local ents = {}
    pcall(function() ents = U.arrayToTable(panel.TV_Affixes:GetDisplayedEntryWidgets()) end)
    for _, w in ipairs(ents) do
        if U.ok(w) then
            local id = nil
            pcall(function() id = nv.affixes[U.key(w["Applied Affix VM"])] end)
            local p = id and PD.PARTS and PD.PARTS[id]
            if p then pcall(function() brush(w.Img_AffixIcon, p.icon) end) end
        end
    end
    -- #79: the shop's WBP_BuildStatsPanel lists his parts in WBP_AppliedAffixPanel (LV / TV entries of
    -- WBP_AppliedAffixInfo, VM "AppliedAffixVM"): PopulateFromVM loads the VM's Icon = P1's part's (a new VM: none), so his
    -- own icon goes on; entries are enabled (a disabled CommonButton draws faded)
    local ap = nil
    pcall(function() ap = panel.WBP_AppliedAffixPanel_Presentation end)
    if not U.ok(ap) then return end
    for _, list in ipairs({ "LV_AppliedAffixes", "TV_AppliedAffixes" }) do
        local es = {}
        pcall(function() es = U.arrayToTable(ap[list]:GetDisplayedEntryWidgets()) end)
        for _, w in ipairs(es) do
            if U.ok(w) then
                local id = nil
                -- couch-fix46: the entry's VM member is AppliedAffixVM (decoded WBP_AppliedAffixInfo: "AffixVM" is only
                -- PopulateFromVM's parameter): w.AffixVM matched nothing - no icon of his (P1's on P1's rows, blank on
                -- the new ones: shots 145418 / 145428) and no liven (his rows at the disabled alpha)
                local vm = nil
                pcall(function() vm = w.AppliedAffixVM end)
                if not U.ok(vm) then pcall(function() vm = w.AffixVM end) end
                if U.ok(vm) then id = nv.affixes[U.key(vm)] end
                local p = id and PD.PARTS and PD.PARTS[id]
                if p then pcall(function() brush(w.WBP_Build_Affix_Presentation.Img_AffixIcon, p.icon) end) end
                M.liven(w)                                   -- couch-fix46: every row of his (an empty slot too)
            end
        end
    end
end

-- #79: a guest copy's CommonButton (never activated screen) can come up disabled; on the scrap dealer's screen its
-- cards have bApplyAlphaOnDisable (WBP_ExoticVendorShop instance override) -> washed out. Enabled, full opacity.
-- couch-fix46 (live round 1 AUTO-120, shot 145418: P2's INSTALLED PARTS rows drawn at ~45 % - title max (142,149,148)
-- over the panel's (54,76,82), P1's native rows white): UCommonButtonBase overrides SetIsEnabled with its own
-- bButtonEnabled (NativeOnDisabled = RootButton alpha 0.5 under bApplyAlphaOnDisable, on by default) and leaves the
-- UWidget flag GetIsEnabled reads alone: "if not GetIsEnabled() then SetIsEnabled(true)" never re-enabled such a
-- button. SetIsEnabled(true) always (a no-op on an enabled one).
function M.liven(w)
    if not U.ok(w) then return end
    pcall(function() w:SetIsEnabled(true) end)
    pcall(function() w:SetIsInteractionEnabled(true) end)
    pcall(function() w:SetRenderOpacity(1.0) end)
end

-- BUG-6 (live s28, VIEW BUILD): the guest's build page said LANDSPEEDER with P1's speed (P2 drives the Speeder Bike).
-- A build VM copy (BuildVehicleBuildVMForCampaign) is P1's vehicle: WBP_BuildStatsPanel's Init writes Txt_VehicleName
-- from VM.VehicleArchetype.PlayerFacingName and the speed chip from VM.RawSpeed / TempSpeed (decoded), the condensed
-- panel's InitVehicleIcon reads VehicleArchetype too. The copy gets HIS class: the VehicleArchetype object of the
-- game's own VEHICLE SELECT view model (ViewModelSubsystem:BuildVehicleSelectVM().Vehicles[i], VehicleSelectItemVM:
-- VehicleArchetype / RawSpeed = the class' base speed for this account), else GfnGameInstance.VehicleList:
-- FindArchetype.
-- couch-fix66 (AUTO-162, live round 11 Derven Acos: P2's Speeder Bike read SPEED 726 next to P1's 363, growing every
-- race 298 -> 328 -> 410 -> 524 -> 669 -> 726): his speed was his class base + P1's gain over P1's class base spread
-- over P1's summed levels - P1's levels read from his VM's StatBars came out 2.0 (or 0.0) all run long, so P2's 15
-- levels got P1's whole +57 x 7.5. His speed is HIS OWN now, the game's rule (research perks-loadout §1.4): the chip
-- is the class base + the power-rating step of his PowerLevel (= the sum of his six part levels, 0..60:
-- TNS_Upgrade_PowerRating_Max, top speed +150 at 60 for speeders, +250 for pods). One power level on the chip =
-- M.SPEED_PER_LEVEL (4.1, read off P1's own live chip: 306 -> 310 -> 314 ... 347 at 10, 363 at 14, 383 at 19; the
-- game truncates), pods x 250 / 150. P1's VM is never extrapolated (his parts / traits are his). Pure: M.guestSpeed.
M.SPEED_PER_LEVEL = 4.1
M.POD_SPEED_SCALE = 250 / 150
M.POWER_LEVEL_MAX = 60
-- pure: -> the chip speed of a class base + a power level (arch 1 = Plane: a pod), nil without a base
function M.guestSpeed(base2, level2, arch2, perLevel)
    base2 = tonumber(base2)
    if not base2 then return nil end
    local pl = math.max(0, math.min(M.POWER_LEVEL_MAX, tonumber(level2) or 0))
    local per = tonumber(perLevel) or M.SPEED_PER_LEVEL
    if tonumber(arch2) == 1 then per = per * M.POD_SPEED_SCALE end
    return math.floor(base2 + per * pl + 1e-6)
end

local selectCache = { atMs = -1e12, items = nil }
local function classItems()
    local now = St.nowMs()
    if selectCache.items and now - selectCache.atMs < 10000 then return selectCache.items end
    local out = {}
    pcall(function()
        local vm = vms():BuildVehicleSelectVM()
        if not U.ok(vm) then return end
        for _, it in ipairs(U.arrayToTable(vm.Vehicles)) do
            if U.ok(it) then
                local va, a, raw = nil, nil, nil
                pcall(function() va = it.VehicleArchetype end)
                if U.ok(va) then pcall(function() a = tonumber(va.Archetype) end) end
                pcall(function() raw = tonumber(it.RawSpeed) end)
                if a ~= nil then out[a] = { va = va, raw = raw } end
            end
        end
    end)
    selectCache.atMs, selectCache.items = now, out
    return out
end

-- his class + speed into a build VM copy (before reapplyBuild rewrites the bars)
local function rewriteVehicle(P, bvm)
    local a2 = nil
    pcall(function() a2 = U.mod("couchrun").archOf(P.ctrlId, P.pnum) end)
    a2 = tonumber(a2)
    if a2 == nil then return false end
    local va1, a1 = nil, nil
    pcall(function() va1 = bvm.VehicleArchetype end)
    if U.ok(va1) then pcall(function() a1 = tonumber(va1.Archetype) end) end
    local items = classItems()
    local it2, it1 = items[a2], (a1 ~= nil) and items[a1] or nil
    local va2 = it2 and it2.va or nil
    if not U.ok(va2) then pcall(function() va2 = U.mod("vehicles").archetypeObj({ arch = a2 }) end) end
    if U.ok(va2) and a1 ~= a2 then pcall(function() bvm.VehicleArchetype = va2 end) end
    local sum2 = 0
    for s = 0, 5 do sum2 = sum2 + (tonumber((P.lo and P.lo.tune or {})[s]) or 0) end
    local raw1, temp1 = nil, nil
    pcall(function() raw1 = tonumber(bvm.RawSpeed); temp1 = tonumber(bvm.TempSpeed) end)
    local raw2 = M.guestSpeed(it2 and it2.raw, sum2, a2)
    -- the rule checked on P1's own chip (his real PowerLevel: VehicleBuild.PowerLevel, never the StatBars): logged
    local pl1 = nil
    pcall(function() pl1 = tonumber(bvm.VehicleBuild.PowerLevel) end)
    local p1Rule = (pl1 and it1) and M.guestSpeed(it1.raw, pl1, a1) or nil
    if raw2 then
        pcall(function()
            bvm.RawSpeed = raw2
            -- TempSpeed follows the same rule as P1's VM (0 = no preview, else the preview = the speed itself)
            bvm.TempSpeed = (temp1 == nil or temp1 == 0) and (temp1 or 0) or raw2
        end)
    end
    U.log(TAG, "P%s build copy: class %s -> %s (%s), speed %s -> %s (his class base %s + power level %s; P1: base %s, "
        .. "power level %s -> rule %s vs his chip %s)", tostring(P.pnum), tostring(a1), tostring(a2),
        U.ok(va2) and "archetype set" or "archetype NOT found", tostring(raw1), tostring(raw2), tostring(it2 and it2.raw),
        tostring(sum2), tostring(it1 and it1.raw), tostring(pl1), tostring(p1Rule), tostring(raw1))
    return U.ok(va2)
end
M.rewriteVehicle = rewriteVehicle

local refreshShopBuild
-- the guest's abilities / crash ability / parts written into a build VM COPY (the bars: reapplyBuild). -> parts, afx
local function rewriteBuildVM(P, bvm)
    local nv = P.nv
    local lo = P.lo or {}
    pcall(rewriteVehicle, P, bvm)                       -- BUG-6: his class + speed (before the bars are rewritten)
    pcall(function()
        local abs = U.arrayCount(bvm.StandardAbilities)
        for n = 1, abs do
            local cdo = lo.ab and lo.ab[n] and abilityCDO(lo.ab[n])
            if cdo then pcall(function() bvm.StandardAbilities[n] = cdo end) end
        end
    end)
    if lo.crash then
        local cdo = abilityCDO(lo.crash)
        if cdo then pcall(function() bvm.CrashAbility = cdo end) end
    end
    -- affixes = the guest's parts: rewrite the copy's entries; extras are removed from the list after InitAffixes
    local parts = {}
    for i = 1, #(lo.parts or {}) do
        local id = lo.parts[i]
        if id and PD and PD.PARTS and PD.PARTS[id] then parts[#parts + 1] = id end
    end
    local afx = {}
    pcall(function() afx = U.arrayToTable(bvm.AppliedAffixes) end)
    -- fix16 (live: "NO PARTS INSTALLED 0/4", log "P2: 1 part(s), the build copy shows 0"): the copy is P1's build, so
    -- with P1 holding fewer parts than the guest there was no entry to rewrite. A new /Script/Griffin.AppliedAffixVM
    -- (the array's element class) per missing part, appended at Num + 1 (UE4SS grows a TArray written one past its end,
    -- live-checked 2026-10-15); WBP_BuildStatsPanel:Init / AppliedAffixPanel:InitFromVehicleBuild list them.
    if #parts > #afx then
        local okC, cls = pcall(U.class, "/Script/Griffin.AppliedAffixVM")
        for _ = #afx + 1, #parts do
            local okO, o = false, nil
            if okC and U.ok(cls) then okO, o = pcall(StaticConstructObject, cls, bvm) end
            if not (okO and U.ok(o)) then break end
            local okA = pcall(function() bvm.AppliedAffixes[#afx + 1] = o end)
            if not okA then break end
            afx[#afx + 1] = o
        end
    end
    nv.affixes = nv.affixes or {}
    local who = nil
    pcall(function() who = P.ctrlId and CR().player(P.ctrlId) end)
    local faults = who and type(who.faults) == "table" and who.faults or {}
    local fixed = who and type(who.fixed) == "table" and who.fixed or {}
    for i = 1, math.min(#parts, #afx) do
        local p = PD.PARTS[parts[i]]
        pcall(function()
            afx[i].Name = U.ftext(p.name or "")
            afx[i].Description = U.ftext(p.rich or p.desc or "")
            afx[i].Rarity = tonumber(p.rarity) or 0
        end)
        -- #73: HIS part's status (an experimental part bought at the scrap dealer is Faulty until repaired), never P1's
        local st = (faults[parts[i]] or (p.faulty and not fixed[parts[i]])) and 2 or (fixed[parts[i]] and 3 or 1)
        pcall(function() afx[i].AffixStatus = st end)
        -- #79: the row's FAULT box (WBP_AppliedAffixInfo:PopulateFromVM shows it when FaultyPassiveFlavourTexts is not
        -- empty) = HIS part's drawback only; the copy's entries carried P1's fault texts onto his parts
        local ft = faults[parts[i]] and PD.PARTS[faults[parts[i]]]
        pcall(function() afx[i].FaultyPassiveFlavourTexts:Empty() end)
        if ft then pcall(function() afx[i].FaultyPassiveFlavourTexts[1] = U.ftext(ft.rich or ft.desc or ft.name or "") end) end
        nv.affixes[U.key(afx[i])] = parts[i]
    end
    if #parts == 0 then pcall(function() bvm.AppliedAffixes:Empty() end) end
    if #(lo.parts or {}) > 0 then pcall(function() bvm.MaxAffixSlots = #lo.parts end) end
    -- #79: the panel's "n/m" (m = VehicleBuild.UnlockedAffixSlots, P1's 4): his slots hold all his parts ("6/4")
    -- #105 / #110: m = HIS part slots (the native base + his Gadgeteer), never P1's (P1's Gadgeteer showed 0/6 vs 0/4)
    pcall(function()
        local u = tonumber(bvm.VehicleBuild.UnlockedAffixSlots) or 0
        local mine = P.ctrlId ~= nil and CR().partSlotsOf(P.ctrlId) or nil
        local want = math.max(tonumber(mine) or u, #parts)
        if want ~= u then bvm.VehicleBuild.UnlockedAffixSlots = want end
    end)
    if #parts > #afx then
        U.log(TAG, "P%s: %d part(s), the build copy shows %d", tostring(P.pnum), #parts, #afx)
    end
    return parts, afx
end
M.rewriteBuildVM = rewriteBuildVM

-- fix16: a part bought in his own shop goes into his couch-run build at once; his INSTALLED PARTS panel (the shop's
-- WBP_BuildStatsPanel, Init(VM) -> AppliedAffixPanel:InitFromVehicleBuild + the "n/m" count) is re-initialised from the
-- rewritten copy. Other kinds only move bars / icons (reapplyBuild).
refreshShopBuild = function(P, row)
    local nv = P.nv
    if not nv or not nv.statsPanel or not U.ok(nv.bvm) or not U.alive(nv.panel) then return false end
    if row and row.rkind ~= "part" then return false end
    local okP, p = pcall(function() return CR().player(P.ctrlId) end)
    if okP and p and p.lo then P.lo = p.lo end
    local okR, parts, afx = pcall(rewriteBuildVM, P, nv.bvm)
    pcall(function() nv.panel:Init(nv.bvm) end)
    -- couch-fix64 (AUTO-158a, live round 9 shot hibi-p2-replaced: after PART SLOTS FULL put AFTERBURNER RECHARGER in
    -- VOLATILE BATTERY's slot, his INSTALLED PARTS still listed VOLATILE BATTERY until the shop was rebuilt): the
    -- panel's list keeps an entry widget per unchanged VM object (rewritten in place, same count), so Init redraws
    -- nothing for a swap. Every displayed entry re-reads its VM, then his part icons go back on.
    local nRe = M.repopulateAffixes(nv.panel)
    pcall(paintBuildIcons, P)
    local now = St.nowMs()
    P.paintAt = P.paintAt or {}
    P.paintAt[#P.paintAt + 1] = now + 200
    U.log(TAG, "P%s's installed parts refreshed after his buy: %s part(s), %s shown, %d entr%s re-read", tostring(P.pnum),
        tostring(okR and #parts or "?"), tostring(okR and math.min(#parts, #afx) or "?"), nRe, nRe == 1 and "y" or "ies")
    return okR
end

-- the INSTALLED PARTS entries (WBP_AppliedAffixPanel: LV / TV of WBP_AppliedAffixInfo) re-read their own VM -> count
function M.repopulateAffixes(panel)
    if not U.alive(panel) then return 0 end
    local ap = nil
    pcall(function() ap = panel.WBP_AppliedAffixPanel_Presentation end)
    if not U.ok(ap) then return 0 end
    local n = 0
    for _, list in ipairs({ "LV_AppliedAffixes", "TV_AppliedAffixes" }) do
        local es = {}
        pcall(function() es = U.arrayToTable(ap[list]:GetDisplayedEntryWidgets()) end)
        for _, w in ipairs(es) do
            if U.ok(w) then
                local vm = nil
                pcall(function() vm = w.AppliedAffixVM end)
                if U.ok(vm) and pcall(function() w:PopulateFromVM(vm) end) then n = n + 1 end
            end
        end
    end
    return n
end
M._refreshShopBuild = function(P, row) return refreshShopBuild(P, row) end

-- the panel's own VehicleBuildVM (a fresh build made by its Construct -> RefreshBuild) rewritten with the guest's build
local function initBuild(P, lay)
    local nv = P.nv
    local panel = lay.WBP_CondensedBuildInfo_Presentation
    if not U.ok(panel) then error("no build panel") end
    nv.panel = panel
    local p1 = p1VmKeys()
    local bvm = nil
    pcall(function() bvm = panel.VehicleBuildVM end)
    local fresh = false
    if not U.ok(bvm) or (p1.build ~= 0 and U.key(bvm) == p1.build) then
        bvm = vms():BuildVehicleBuildVMForCampaignPlayerVehicle()
        if not U.ok(bvm) then error("no build VM") end
        if p1.build ~= 0 and U.key(bvm) == p1.build then error("build VM is P1's own") end
        panel.VehicleBuildVM = bvm
        fresh = true
    end
    nv.bvm = bvm
    if not S.barsLogged then
        -- once per session, for the live check of the bar units (reapplyBuild's level vs scaled rule)
        S.barsLogged = true
        local t = {}
        pcall(function()
            for _, bar in ipairs(U.arrayToTable(bvm.StatBars)) do
                t[#t + 1] = string.format("%s:%s/%s/%s", tostring(bar.Slot), tostring(bar.Value), tostring(bar.BaseValue),
                    tostring(bar.MaxValue))
            end
        end)
        U.log(TAG, "build VM bars before the rewrite (slot:value/base/max): %s; energy %s", table.concat(t, " "),
            tostring(select(2, pcall(U.getField, bvm, "Energy"))))
    end
    local parts, afx = rewriteBuildVM(P, bvm)
    pcall(function() panel:InitVehicleIcon(bvm) end)
    pcall(function() panel:InitAffixes(bvm) end)
    if #parts > 0 then
        for i = #parts + 1, #afx do
            pcall(function() panel.TV_Affixes:RemoveItem(afx[i]); panel.TV_Affixes:AddEmptyItem() end)
        end
    end
    pcall(function() panel:InitAbilities(bvm) end)
    if fresh then pcall(function() panel.LV_Stats:BP_SetListItems(bvm.StatBars) end) end
    pcall(function() panel.WBP_MiniBuildStat_Speed:SetSpeed(bvm.RawSpeed, bvm.TempSpeed) end)
    reapplyBuild(P)
end

---------------------------------------------------------------------------------------------------- native view
local packBtnKeys = {}            -- the guest copies' PACKS buttons (U.key): focus look by hand, never their BP events
local function cardFocus(w, on)
    if not U.alive(w) then return end
    if opt("CouchPanelNativeHover", true) ~= false and not packBtnKeys[U.key(w)] then
        if on then pcall(function() w:BP_OnFocusReceived() end) else pcall(function() w:BP_OnFocusLost() end) end
        return
    end
    -- by hand: the hover look of BP_OnFocusReceived without its OnItemFocussed broadcast (no SetDeltaPart)
    U.playAnim(w, "Anim_Hover", on and 0 or 1)
    pcall(function() w.Img_Tile_Stroke_Selected:SetVisibility(on and VIS.SelfHitTestInvisible or VIS.Collapsed) end)
    pcall(function()
        local c = on and w.TitleHoverColour or w.TitleDefaultColour
        w.Txt_Title:SetDefaultColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 })
    end)
end

-- the native target of button index i: a card, or the skip button (index nCards + 1)
local function target(P, i)
    local nv = P.nv
    if not nv or not i then return nil end
    if i <= nv.nCards then return nv.cards and nv.cards[i] or nil end
    if nv.extra and nv.extra[i] then return nv.extra[i] end              -- the shop's RESTOCK / PACKS buttons
    if nv.restockBtn and i == nv.nCards + 2 then return nv.restockBtn end
    if nv.hasSkip and i == nv.nCards + 1 then
        if nv.leaveBtn then return nv.leaveBtn end
        local sk = nil
        pcall(function() sk = nv.lay.WBP_Skip_Btn end)
        return sk
    end
    return nil
end

-- NOTE 5 (Jules 2026-10-14, live: "P2's shop cards show no price"). Decoded WBP_Item_Btn: PopulateFromVM writes
-- Txt_CostText from ItemVM.CreditsValue ("{cost}"), but Txt_CostText / Img_CreditsIcn are Collapsed by default and only
-- ShouldShowPrices(true) shows them - called by the MainSelectionPanel's TV_Parts OnEntryWidgetGenerated, which the
-- guest copy did not get. So: ShouldShowPrices(true) on each of his cards, the price text written from his couchrun
-- row ("1,500", the native Format of an int), and the game's affordability colours against HIS credits (the card's
-- own cost ink #05384A when he can pay, the vendor screens' NoMoneyCreditsTint #B1513C when not; the shop card
-- itself has no affordability look). Re-run with every paint (after each buy: the figures move).
local COST_OK = { R = 0.001518, G = 0.039546, B = 0.068478, A = 1 }   -- WBP_Item_Btn Txt_CostText / Img_CreditsIcn
local COST_NO = { R = 0.439657, G = 0.082283, B = 0.045186, A = 1 }   -- WBP_ExoticVendorRepair NoMoneyCreditsTint
-- fix16 (live s01/s02): ShouldShowPrices + the text were set, the price still invisible: HB_CreditCost's RenderOpacity
-- was 0.0. WBP_Item_Btn's Anim_In holds HB_CreditCost.RenderOpacity at a constant 0 (a reward card hides its cost);
-- the native shop never plays Anim_In on its cards. So the shop copy plays no Anim_In (paintCard) and the cost box gets
-- its visibility (HitTestInvisible, PopulateFromVM's available look) + opacity 1 here.
local function priceCard(P, w, row)
    if row.bought then return end                                     -- PURCHASED: the card hides its cost itself
    if row.packPick then                                              -- a PACK's choice: paid with the pack
        pcall(function() w:ShouldShowPrices(false) end)
        pcall(function() w.HB_CreditCost:SetVisibility(VIS.Collapsed) end)
        return
    end
    local price = math.floor(tonumber(row.price) or 0)
    pcall(function() w:ShouldShowPrices(true) end)
    pcall(function() w.HB_CreditCost:SetVisibility(VIS.HitTestInvisible) end)
    pcall(function() w.HB_CreditCost:SetRenderOpacity(1.0) end)
    pcall(function() w.Txt_CostText:SetText(U.ftext(groupDigits(price))) end)
    local p = P.ctrlId and CR().player(P.ctrlId) or nil
    local col = ((p and p.credits or 0) >= price) and COST_OK or COST_NO
    pcall(function() w.Txt_CostText:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 }) end)
    pcall(function() w.Img_CreditsIcn:SetColorAndOpacity(col) end)
end

local function paintCard(P, w, row, first)
    local info = rowInfo(row, P.lo, M.archOfP(P))
    pcall(function() w.Txt_Title:SetText(U.ftext(info.title)) end)
    if info.itype ~= 1 then pcall(function() w.RTxt_ItemDesc:SetText(U.ftext(info.desc)) end) end
    pcall(function() w.WBP_ItemRarity:SetRarityLevel(info.q) end)
    if info.itype == 1 then
        -- his card's own level step (a reward round's +1, an eliminator's +2, an UPGRADE PACK's rolled levels)
        local plus = "+" .. tostring(math.max(1, math.floor(tonumber(row.lv) or 1)))
        for _, f in ipairs({ "Txt_StatChange", "Txt_StatChange_echo1", "Txt_StatChange_echo2" }) do
            pcall(function() w[f]:SetText(U.ftext(plus)) end)
        end
    end
    pcall(function() brush(w.Img_Thumbnail_Item, info.large or info.icon) end)
    local shop = P.nv and P.nv.shop
    if shop then priceCard(P, w, row) end
    -- Anim_In zeroes the cost box (priceCard): reward cards only
    if first and not shop then U.playAnim(w, "Anim_In") end
end

-- cards (by their ItemVM), focus look, build bars, build icons; re-run after every focus event and populate
local paintMystery
local function paint(P)
    local nv = P.nv
    if nv and nv.mystery then return paintMystery(P) end
    if nv and nv.vendor then return V.paintVendor(P) end
    if nv and nv.backerView then return require("couchbackerui").paint(P) end      -- couch-fix21: his backer moment
    if not nv or not U.alive(nv.lay) then return end
    local ents = {}
    pcall(function() ents = U.arrayToTable((nv.tv or nv.lay.TV_List_Items):GetDisplayedEntryWidgets()) end)
    local byKey = {}
    for i, it in ipairs(nv.items or {}) do byKey[U.key(it)] = i end
    local cards = {}
    for j, w in ipairs(ents) do
        if U.ok(w) then
            local i = nil
            pcall(function() i = byKey[U.key(w.ItemVM)] end)
            cards[i or j] = w
        end
    end
    nv.cards = cards
    for i = 1, nv.nCards do
        local w = cards[i]
        if U.ok(w) and P.rows[i] then
            local k = U.key(w)
            paintCard(P, w, P.rows[i], not nv.animated[k])
            nv.animated[k] = true
        end
    end
    if not nv.focusShown and not P.done and target(P, P.sel) then
        nv.focusShown = P.sel
        cardFocus(target(P, P.sel), true)
    end
    reapplyBuild(P)
    paintBuildIcons(P)
end

local function setSel(P, i)
    local old = P.sel
    P.sel = i
    if P.view ~= "native" then return end
    local nv = P.nv
    if nv.focusShown and target(P, nv.focusShown) then
        cardFocus(target(P, nv.focusShown), false)
        if nv.mystery then pcall(function() target(P, nv.focusShown):SetIsSelected(false, false) end) end
    end
    nv.focusShown = nil
    if target(P, i) then
        nv.focusShown = i
        cardFocus(target(P, i), true)
        if nv.mystery then pcall(function() target(P, i):SetIsSelected(true, false) end) end
    end
    if nv.vendor == "repair" then V.repairDetail(P) end          -- his focused part on the repair screen's detail
    -- the card's OnDeltasUpdated may re-run PopulateFromVM (P1's thumbnail): repaint now and twice more
    reapplyBuild(P)
    local now = St.nowMs()
    P.paintAt = { now + 40, now + 220 }
    U.dbg(TAG, "P%s focus %s -> %s", tostring(P.pnum), tostring(old), tostring(i))
end

-- FINDING #31 (live 2026-10-17 19:05:20: "P2 native reward view failed (rewards VM has no items): list panel
-- instead"). An act finish's reward flow is credits only (RewardsCollectionVM stage types {1}): the #7 fallback gives
-- the guest the closest kind (stat levels), but BuildRewardsVMForCurrentCampaignEvent() of that event has NO items, so
-- the guest got the plain list (Jules: ugly, not P1's CHOOSE AN UPGRADE). The copy is stocked with one VehicleUpgrade
-- card per stat row instead:
--   * a new /Script/Griffin.CampaignItemVM (outer = the copy) appended at Num + 1 (UE4SS grows a TArray written one
--     past its end, live-checked 2026-10-15 on AppliedAffixes), ItemType 1;
--   * its Item = a new /Script/Griffin.CampaignItem with Data.ItemType 1 and Data.Upgrade filled from the stat's
--     VU_<part>_<NN> def exactly as the native FVehicleUpgrade fill (perkapply.writeEntry, 0x140027778). A focused card
--     runs the layout's native delta (OnItemFocussed -> SetDeltaPart), whose VehicleUpgrade case reads
--     Item.Data.Upgrade.AuthoredUpgrade->PartSlot (Item+0x30+0x20 -> +0x90, the BUG-12 read): never a card without a
--     live Item and a live def - a card that cannot get both is not added;
--   * fallback when no item can be constructed: the VehicleUpgrade cards of a fresh build VM copy's
--     CurrentBuildUpgrades (P1's own live upgrade items: Item and def valid), rewritten with the guest's rows;
--   * TotalRewardRounds 0 hides the layout's CHOOSE AN UPGRADE title (UpdateRewardRoundsInfo: Greater_IntInt(.., 0)):
--     a stocked copy gets 1 round (CurrentRewardRound 0).
-- Only when neither works: the list panel (the caller's fallback). -> number of cards added, how
V.RW = {}          -- the reward-copy stock helpers (a field: couchpanel's main chunk is at Lua's 200-locals limit)
V.RW.UP_DIR = "/Game/Griffin/Vehicles/Common/Upgrades/UpgradeDefinitions/"
V.RW.ITEMVM_CLS = "/Script/Griffin.CampaignItemVM"
V.RW.ITEM_CLS = "/Script/Griffin.CampaignItem"

-- the VU def of a stat slot at a level (1 = _001, else %02d), or nil
function V.RW.vuDef(slot, lv)
    local st = PD and PD.STATS and PD.STATS[slot]
    if not st or type(st.vu) ~= "string" then return nil end
    lv = math.max(0, math.min(LEVEL_MAX, math.floor(tonumber(lv) or 0)))
    local nn = (lv == 1) and "001" or string.format("%02d", lv)
    local name = "VU_" .. st.vu .. "_" .. nn
    local o = nil
    pcall(function() o = U.obj(V.RW.UP_DIR .. name .. "." .. name) end)
    return U.ok(o) and o or nil
end

-- the guest's level after this row (a reward round's stat row is +1, an UPGRADE PACK row carries lv)
function V.RW.rowLevel(row, lo)
    local cur = math.floor(tonumber(lo and lo.tune and lo.tune[row.id]) or 0)
    return math.min(LEVEL_MAX, cur + math.max(1, math.floor(tonumber(row.lv) or 1)))
end

-- a CampaignItem of kind VehicleUpgrade for this stat row (outer = the copy), or nil, why
function V.RW.upgradeItem(outer, row, lo)
    local slot = tonumber(row.id)
    if row.rkind == "upgrade" then slot = 5 end
    if not slot then return nil, "no stat slot" end
    local def = V.RW.vuDef(slot, V.RW.rowLevel(row, lo))
    if not def then return nil, "VU def of slot " .. tostring(slot) .. " not loadable" end
    local cls = U.class(V.RW.ITEM_CLS)
    if not U.ok(cls) then return nil, "CampaignItem class not found" end
    local okO, item = pcall(StaticConstructObject, cls, outer)
    if not (okO and U.ok(item)) then return nil, "CampaignItem not constructed" end
    local okT = pcall(function() item.Data.ItemType = 1 end)
    local okD = pcall(function() item.Data.Upgrade.AuthoredUpgrade = def end)
    local back = nil
    pcall(function() back = item.Data.Upgrade.AuthoredUpgrade end)
    if not (okT and okD and U.same(back, def)) then return nil, "CampaignItem.Data.Upgrade not writable" end
    -- the rest of the native fill, field by field (an unreadable field keeps its zero)
    local function num(v) return type(v) == "number" and v or nil end
    pcall(function() local v = num(def.BaseQuality); if v then item.Data.Upgrade.UpgradeQuality = v end end)
    pcall(function() local v = num(def.UserFacingStatIncrease); if v then item.Data.Upgrade.UserFacingStatIncrease = v end end)
    pcall(function() local t = def.TunesetToApply; if U.ok(t) then item.Data.Upgrade.TunesetToApply = t end end)
    pcall(function() local v = def.IsStackingTuneset; if type(v) == "boolean" then item.Data.Upgrade.IsStackingTuneset = v end end)
    pcall(function() local v = num(def.StacksToApply); if v then item.Data.Upgrade.StacksToApply = v end end)
    pcall(function() local v = num(def.PowerLevel); if v then item.Data.Upgrade.PowerLevel = v end end)
    pcall(function() local v = num(def.CreditsValue); if v then item.Data.Upgrade.CreditsValue = v end end)
    return item, nil
end

-- a stocked CampaignItemVM appended to the copy's Items (ItemType 1 over a live upgrade Item), or nil, why
function V.RW.appendStatCard(vm, row, lo)
    local cls = U.class(V.RW.ITEMVM_CLS)
    if not U.ok(cls) then return nil, "CampaignItemVM class not found" end
    local item, why = V.RW.upgradeItem(vm, row, lo)
    if not item then return nil, why end
    local okO, ivm = pcall(StaticConstructObject, cls, vm)
    if not (okO and U.ok(ivm)) then return nil, "CampaignItemVM not constructed" end
    local okI = pcall(function() ivm.Item = item end)
    pcall(function() ivm.ItemType = 1 end)
    local back = nil
    pcall(function() back = ivm.Item end)
    if not (okI and U.same(back, item)) then return nil, "CampaignItemVM.Item not writable" end
    local n = U.arrayCount(vm.Items)
    local okA = pcall(function() vm.Items[n + 1] = ivm end)
    if not okA or U.arrayCount(vm.Items) ~= n + 1 then return nil, "rewards VM Items did not grow" end
    return ivm, nil
end

-- the fallback stock: P1's live VehicleUpgrade cards of a fresh build VM copy (never his own panel's VM)
function V.RW.templateCards(vm, want)
    local okB, bvm = pcall(function() return vms():BuildVehicleBuildVMForCampaignPlayerVehicle() end)
    if not (okB and U.ok(bvm)) then return 0 end
    local p1 = p1VmKeys()
    if p1.build ~= 0 and U.key(bvm) == p1.build then return 0 end
    local added = 0
    for _, it in ipairs(U.arrayToTable(bvm.CurrentBuildUpgrades)) do
        if added >= want then break end
        local t, item = nil, nil
        pcall(function() t = tonumber(it.ItemType) end)
        pcall(function() item = it.Item end)
        if U.ok(it) and t == 1 and U.ok(item) then
            local n = U.arrayCount(vm.Items)
            if pcall(function() vm.Items[n + 1] = it end) and U.arrayCount(vm.Items) == n + 1 then added = added + 1 end
        end
    end
    return added
end

-- -> cards added, "constructed" | "templates" | "mixed" | why nothing
function V.RW.stockStatCards(vm, P)
    local rows = {}
    for _, r in ipairs(P.rows or {}) do
        if r.rkind == "stat" or r.rkind == "upgrade" then rows[#rows + 1] = r end
    end
    if #rows == 0 then return 0, "no stat rows to stock" end
    local made, lastWhy = 0, nil
    for _, r in ipairs(rows) do
        local ivm, why = V.RW.appendStatCard(vm, r, P.lo)
        if ivm then made = made + 1 else lastWhy = why end
    end
    local tpl = 0
    if made < #rows then tpl = V.RW.templateCards(vm, #rows - made) end
    if made + tpl == 0 then return 0, tostring(lastWhy or "nothing constructible") end
    pcall(function()
        if (tonumber(vm.TotalRewardRounds) or 0) < 1 then vm.TotalRewardRounds = 1; vm.CurrentRewardRound = 0 end
    end)
    local how = (tpl == 0 and "constructed") or (made == 0 and "templates") or "mixed"
    U.log(TAG, "P%s rewards copy without items (credits-only event): %d VehicleUpgrade card(s) stocked (%s%s)",
        tostring(P.pnum), made + tpl, how, lastWhy and ("; " .. lastWhy) or "")
    return made + tpl, how
end
M._stockStatCards = V.RW.stockStatCards

-- couch-rewards2: the copy's items for HIS round (P.flowRound): items of the round's card type kept (at most his card
-- count), the others removed; missing ones stocked (stat: constructed VehicleUpgrade cards; part: the live Affix cards
-- of a fresh shop VM copy, rewritten by writeItem like the shop's). -> the items
function V.RW.flowItems(vm, P, items)
    local want = (P.flowRound.kind == "part") and 4 or 1
    local nCards = 0
    for _, r in ipairs(P.rows or {}) do if r.rkind ~= "skip" then nCards = nCards + 1 end end
    local kept, dropped = 0, 0
    for _, it in ipairs(items) do
        local t = nil
        pcall(function() t = tonumber(it.ItemType) end)
        if t == want and kept < nCards then kept = kept + 1
        else pcall(function() vm:RemoveItem(it) end); dropped = dropped + 1 end
    end
    if kept < nCards and want == 1 then
        local okS = pcall(function()
            local rows = {}
            for _, r in ipairs(P.rows) do if r.rkind == "stat" then rows[#rows + 1] = r end end
            for i = kept + 1, #rows do
                local ivm = V.RW.appendStatCard(vm, rows[i], P.lo)
                if ivm then kept = kept + 1 end
            end
        end)
        if not okS then U.warn(TAG, "P%s: his stat cards could not be stocked", tostring(P.pnum)) end
    elseif kept < nCards and want == 4 then
        local okA, shop = pcall(function() return vms():BuildCampaignShopVMForCurrentPlanet() end)
        if okA and U.ok(shop) then
            for _, it in ipairs(U.arrayToTable(shop.Affixes)) do
                if kept >= nCards then break end
                local t, item = nil, nil
                pcall(function() t = tonumber(it.ItemType) end)
                pcall(function() item = it.Item end)
                if t == 4 and U.ok(item) then
                    local n = U.arrayCount(vm.Items)
                    if pcall(function() vm.Items[n + 1] = it end) and U.arrayCount(vm.Items) == n + 1 then kept = kept + 1 end
                end
            end
        end
    end
    pcall(function()
        if (tonumber(vm.TotalRewardRounds) or 0) < 1 then vm.TotalRewardRounds = 1; vm.CurrentRewardRound = 0 end
    end)
    U.log(TAG, "P%s's own %s round: %d card(s) of his %d (%d of P1's card(s) of another kind removed)", tostring(P.pnum),
        tostring(P.flowRound.kind), kept, nCards, dropped)
    return U.arrayToTable(vm.Items)
end

-- the guest's CHOOSE AN UPGRADE in his area. Errors are raised (the caller falls back to the list panel).
local function buildNative(H, P)
    local cls = U.class(LAYOUT)
    if not U.ok(cls) then error("rewards layout class not loaded") end
    local gpc = U.ok(P.pc) and P.pc or U.p1()
    -- the view-model COPY: a fresh object from the builder, rewritten with the guest's offer, then SetVM, all in this
    -- game-thread callback (07 §6: the copy shows P1's offers until it is rewritten)
    local vm = vms():BuildRewardsVMForCurrentCampaignEvent()
    if not U.ok(vm) then error("no rewards VM") end
    local p1 = p1VmKeys()
    if p1.rewards ~= 0 and U.key(vm) == p1.rewards then error("rewards VM is P1's own") end
    local items = U.arrayToTable(vm.Items)
    -- couch-rewards2: his OWN round (couchflow): the copy shows that round's kind only - P1's cards of another kind
    -- go, his stat cards are stocked / his part cards come from a shop VM copy when P1's round has none of them
    if P.flowRound then items = V.RW.flowItems(vm, P, items) end
    if #items == 0 then
        -- FINDING #31: a credits-only event (act finish) - the copy gets the guest's stat cards (stockStatCards)
        local n, why = V.RW.stockStatCards(vm, P)
        if n == 0 then error("rewards VM has no items and none could be stocked (" .. tostring(why) .. ")") end
        items = U.arrayToTable(vm.Items)
    end
    if #items == 0 then error("rewards VM has no items") end
    local cardsRows, skip = {}, nil
    for _, r in ipairs(P.rows or {}) do
        if r.rkind == "skip" then skip = skip or r else cardsRows[#cardsRows + 1] = r end
    end
    if #cardsRows == 0 then error("no guest cards") end
    -- NOTE 8 (the shop lesson, BUG-12): every card KEEPS its native ItemType - the card look switches on it, and a
    -- focused card hands its VM to the build panel's native delta (SetBuildDeltaVM), which reads the VM's Item as that
    -- type. Each native card gets the first guest row of ITS type; a card without one is removed from the copy.
    local function ntype(it) local t = nil; pcall(function() t = tonumber(it.ItemType) end); return t end
    local keptItems, keptRows, usedRow, dropped = {}, {}, {}, 0
    for _, it in ipairs(items) do
        local t, pick = ntype(it), nil
        for j, r in ipairs(cardsRows) do
            if not usedRow[j] and (t == nil or t == 0 or rowInfo(r, P.lo, M.archOfP(P)).itype == t) then pick = j; break end
        end
        if not pick and t and t > 0 and not P.flowRound then
            -- no guest row of this card's type (his offer was made for another round shape): one of that type
            local okX, extra = pcall(function() return CR().offerOfType(P.ctrlId, t, 1) end)
            if okX and type(extra) == "table" and extra[1] then
                cardsRows[#cardsRows + 1] = extra[1]
                pick = #cardsRows
            end
        end
        if pick then
            usedRow[pick] = true
            keptItems[#keptItems + 1], keptRows[#keptRows + 1] = it, cardsRows[pick]
        else
            pcall(function() vm:RemoveItem(it) end)
            dropped = dropped + 1
        end
    end
    if #keptRows == 0 then error("no guest offer matches the native card types") end
    if dropped > 0 then
        U.log(TAG, "P%s rewards: %d native card(s) without a guest offer of their type removed", tostring(P.pnum), dropped)
    end
    items, cardsRows = keptItems, keptRows
    if U.arrayCount(vm.Items) ~= #cardsRows then error("item count mismatch after RemoveItem") end
    for i, r in ipairs(cardsRows) do
        local t = ntype(items[i])
        writeItem(items[i], rowInfo(r, P.lo, M.archOfP(P)), (t and t > 0) and t or nil)   -- unknown native type: written as before
    end
    pcall(function() vm.SkipCreditsAward = skip and math.floor(tonumber(skip.credits) or 0) or 0 end)
    pcall(function() vm.bIsAllowedToSkipRewardRound = skip ~= nil end)
    pcall(function() vm.NarrativeContextMoment = { TagName = U.fname("None") } end)   -- read on activation only
    -- the rows the buttons drive = the shown cards + the skip
    local rows = {}
    for _, r in ipairs(cardsRows) do rows[#rows + 1] = r end
    if skip then rows[#rows + 1] = skip end
    P.rows = rows
    P.nv = { vm = vm, items = items, nCards = #cardsRows, hasSkip = skip ~= nil, cards = {}, animated = {},
             affixes = {} }
    -- the area: ScaleToFit 3840 x 2160 -> Overlay[ paper, SizeBox 3840 x 1920 (the holder's SzB_InteriorScreen), canvas ]
    if P.region.strip then
        -- the strip's own paper edge to edge (the game's wide-screen look), under the centred 16:9 content
        local fullOv = mk(OVER, H.tree)
        if fullOv then
            place(H.cv, fullOv, P.region.x, P.region.y, P.region.w, P.region.h, 0)
            paperBackdrop(H, H.tree, fullOv, gpc)
            P.stripPaper = fullOv
        end
    end
    local box, sb = regionBox(H, P.region, VW, VH)
    P.box = box
    local ov = mk(OVER, H.tree)
    if not ov then error("no Overlay") end
    sb:AddChild(ov)
    paperBackdrop(H, H.tree, ov, gpc)
    local inner = mk(SIZEB, H.tree)
    inner:SetWidthOverride(3840); inner:SetHeightOverride(1920)
    overlayAdd(ov, inner, 2, 2)
    local lay = U.WBL():Create(gpc, cls, gpc)
    if not U.ok(lay) then error("rewards layout not created") end
    own(lay)
    pcall(function() lay.bAutoActivate = false end)                -- never activated (BP_OnActivated = narrative VO)
    inner:AddChild(lay)
    pcall(function() lay:SetVisibility(VIS.HitTestInvisible) end)
    local act = false
    pcall(function() act = lay:IsActivated() == true end)
    if act then
        U.warn(TAG, "P%s: the guest rewards layout came up activated; deactivating it", tostring(P.pnum))
        pcall(function() lay:DeactivateWidget() end)
    end
    P.nv.lay = lay
    lay:SetVM(vm)                                                   -- OnVMSet: titles, tiles, skip button; no natives
    P.nv.chip = headerChip(lay, P)                                  -- the header's credits chip: his credits
    U.playAnim(lay, "Anim_In")
    if skip then U.playAnim(lay, "Anim_SkipButton") end
    local okB, errB = pcall(initBuild, P, lay)
    if not okB then
        -- never P1's build in a guest area: the panel goes, the cards stay
        U.warn(TAG, "P%s: guest build panel failed (%s); panel hidden", tostring(P.pnum), tostring(errB))
        pcall(function() lay.WBP_CondensedBuildInfo_Presentation:SetVisibility(VIS.Hidden) end)
        P.nv.bvm, P.nv.panel = nil, nil
    end
    ownInside(lay)                       -- its inner activatables are ours too (see ownInside)
    -- the guest's own marks and input on top
    local cv = mk(CANVAS, H.tree)
    overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.badge = solid(H.tree, AMBER);          place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = text(H.tree, 64, INKD);       place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = text(H.tree, 48, INKD);      place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = text(H.tree, 96, INKD);         place(cv, W.wait, 900, 1960, nil, nil, 22)
    P.btns = {}
    for i = 1, #rows do P.btns[i] = ghostButton(H.tree, cv, 40 + (i - 1) * 130, 2040, 120, 100) end
    navCards(P.btns, W.nCards, W.hasSkip)
    local now = St.nowMs()
    P.paintAt = { now + 40, now + 200, now + 600, now + 1500 }     -- the tile entries come on the next Slate pass
    U.log(TAG, "P%s native reward view: %d card(s)%s, build panel %s", tostring(P.pnum), W.nCards,
        skip and " + skip" or "", W.bvm and "rewritten" or "hidden")
end

-- THE GUEST'S SHOP = the game's own shop screen (Jules 2026-10-14: "use exactly the same screen as the rogue campaign").
-- A standalone WBP_Paddock_Shop_Layout_Presentation_C (the INNER layout: its outer WBP_Paddock_Shop_Presentation calls
-- CampaignRun:OnEnterShop / OnLeaveShop on P1's run and is never created) owned by the guest's PC, in his area on the
-- shop's own paper (WBP_Media_Background, as the outer screen), filled with Init(shop VM copy, build VM copy):
--   * ViewModelSubsystem:BuildCampaignShopVMForCurrentPlanet() / BuildVehicleBuildVMForCampaign() return fresh objects
--     (asserted: never P1's own layout's VMs); the copy's Affixes (the TV_Parts cards, WBP_Item_Btn_C) are rewritten
--     with the guest's couchrun stock (title, description, rarity, price = CreditsValue); cards beyond his stock show
--     as unavailable; the pack buttons and RESTOCK (natives on P1's run) are hidden; CONTINUE = his LEAVE;
--   * the build panel (WBP_BuildStatsPanel_Presentation) gets the guest's build (rewriteBuildVM + Init + bars).
-- The layout is never activated, HitTestInvisible and never focused: a card's own click would call
-- ShopVM:PurchaseItem (P1's run). The guest's pad drives invisible buttons (the reward technique); a buy goes to
-- couchrun.buy only and the bought card turns unavailable (its PopulateFromVM). Any error = the list panel.
local SHOP_LAYOUT = "/Game/Griffin/UI/Widgets/CampaignShop/WBP_Paddock_Shop_Layout_Presentation.WBP_Paddock_Shop_Layout_Presentation_C"
local SHOP_LAYOUT_CLS = "WBP_Paddock_Shop_Layout_Presentation_C"
local ITEM_AFFIX = 4                                 -- ECampaignItemType::Affix (the shop shelf's part cards)
-- couch-fix43 (live round 1 A6): the guests' native copy waits for the REAL readiness signal - P1's layout holding its
-- ShopVM (the outer WBP_Paddock_Shop_Presentation's Construct -> Layout:Init(BuildCampaignShopVMForCurrentPlanet)) -
-- read through the outer screen's own WBP_Paddock_Shop_Layout_Presentation member, not only by the layout's class in
-- the screen scan (a reused widget address listed it under a freed screen's class: couch.lua className). This is only
-- the safety net: P1's layout without a VM this long = the list panel (2000 ms was the fixed wait of the A6 fallback).
local SHOP_WAIT_MS = 8000
M.SHOP_WAIT_MS = SHOP_WAIT_MS
V.SHOP_OUTER_CLS = "WBP_Paddock_Shop_Presentation_C"

function V.layKeys(lay, keys)
    pcall(function() keys.shop = U.key(lay.ShopVM) end)
    pcall(function() keys.build = U.key(lay.VehicleBuildVM) end)
    keys.lay = lay
end

-- P1's outer shop screen: shop itself, or the outer chain of its layout / main selection panel (widget -> WidgetTree
-- -> widget ...), or the scan's own entry; nil when none
function V.p1ShopOuter(shop)
    local o = shop
    for _ = 1, 6 do
        if not U.ok(o) then break end
        if U.className(o) == V.SHOP_OUTER_CLS then
            if not S.own[U.key(o)] then return o end
            return nil
        end
        o = U.outerOf(o)
    end
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if okA and type(list) == "table" then
        for _, e in ipairs(list) do
            if e.cls == V.SHOP_OUTER_CLS and not S.own[e.k] and U.alive(e.w) then return e.w end
        end
    end
    return nil
end
M._p1ShopOuter = V.p1ShopOuter

-- keys of P1's live shop VMs (his native shop layout), {} when unknown. shop: P1's native shop screen when known
local function p1ShopKeys(shop)
    local keys = { shop = 0, build = 0 }
    local outer = V.p1ShopOuter(shop or S.native)
    if outer then
        local lay = nil
        pcall(function() lay = outer.WBP_Paddock_Shop_Layout_Presentation end)
        if U.alive(lay) and not S.own[U.key(lay)] then V.layKeys(lay, keys) end
        if keys.shop ~= 0 then keys.via = "outer"; return keys end
    end
    local okA, list = pcall(function() return U.mod("couch").allActivatables() end)
    if not okA or type(list) ~= "table" then return keys end
    for _, e in ipairs(list) do
        if e.cls == SHOP_LAYOUT_CLS and not S.own[e.k] and U.alive(e.w) then
            V.layKeys(e.w, keys)
            keys.via = "scan"
        end
    end
    return keys
end
M._p1ShopKeys = p1ShopKeys

-- #105 (playtest 2026-10-18, photo hibi-shop-3wide-vs-4wide): P1's native parts grid is 3 wide (the 4th card wraps),
-- the guest's copy was 4 wide. Decoded WBP_Shop_MainSelectionPanel_Presentation: TV_Parts (FuseTileView, EntryWidth
-- 572) fills VB_MidPanel inside SzB_PartsSize (WidthOverride 1800), a FILL slot of HB_Layout inside a DownOnly ScaleBox
-- with HAlign Fill: the tile view's columns = its ARRANGED width / EntryWidth, and a SizeBox does not cap what a Fill
-- slot hands it. The copy's area (3840 x 1920 in a ScaleToFit region box) gave the parts box more than 4 x 572.
-- FGeometry is not readable in this UE4SS (theme.lua), so the native GRID SETTINGS are read from P1's own widget
-- (reflected floats: EntryWidth / EntryHeight, SzB_PartsSize.WidthOverride) and the copy is pinned to them: its parts
-- box slot Automatic (= its WidthOverride), WidthOverride / EntryWidth / EntryHeight = P1's. cols = floor(w / entry).
-- couch-fix43 (live round 1 2026-10-18 12:16:44, A6 visit 2: "P2 shop grid: no native grid settings readable", P2 4
-- wide vs P1 3 wide): SzB_PartsSize is NO BP variable (decoded class properties: TV_Parts yes, SzB_PartsSize no), so
-- msp.SzB_PartsSize never read - on P1's widget nor on the copy. It is TV_Parts' grandparent (TV_Parts in VB_MidPanel
-- in SzB_PartsSize): found through UWidget:GetParent (by its name, else the first SizeBox up the chain).
function V.partsBox(msp)
    if not U.ok(msp) then return nil end
    local b = nil
    pcall(function() b = msp.SzB_PartsSize end)
    if U.ok(b) then
        local w = nil
        pcall(function() w = tonumber(b.WidthOverride) end)
        if w then return b end
    end
    local tv = nil
    pcall(function() tv = msp.TV_Parts end)
    local o, first = tv, nil
    for _ = 1, 4 do
        local nxt = nil
        if U.ok(o) then pcall(function() nxt = o:GetParent() end) end
        if not U.ok(nxt) then break end
        if U.objName(nxt) == "SzB_PartsSize" then return nxt end
        if not first and U.className(nxt):find("SizeBox", 1, true) then first = nxt end
        o = nxt
    end
    return first
end

-- pure: -> settings {ew, eh, w, cols} of a MainSelectionPanel, or nil
function V.gridSettings(msp)
    if not U.ok(msp) then return nil end
    local g = {}
    pcall(function() g.ew = tonumber(msp.TV_Parts.EntryWidth) end)
    pcall(function() g.eh = tonumber(msp.TV_Parts.EntryHeight) end)
    local box = V.partsBox(msp)
    if U.ok(box) then pcall(function() g.w = tonumber(box.WidthOverride) end) end
    if not (g.ew and g.ew > 0 and g.w and g.w > 0) then return nil end
    g.cols = math.max(1, math.floor(g.w / g.ew + 1e-6))
    return g
end
M.gridSettings = V.gridSettings

function V.shopGridMatch(P, msp, p1lay)
    if cfg.CouchShopGridMatchP1 == false then return end
    local p1msp = nil
    if U.ok(p1lay) then pcall(function() p1msp = p1lay.WBP_Shop_MainSelectionPanel_Presentation end) end
    local nat = V.gridSettings(p1msp)
    local own = V.gridSettings(msp)
    local g = nat or own
    if not g then
        U.warn(TAG, "P%s shop grid: no native grid settings readable: the copy keeps its layout", tostring(P.pnum))
        return
    end
    local box = V.partsBox(msp)
    local okS = U.ok(box) and pcall(function() box.Slot:SetSize({ Value = 1, SizeRule = 0 }) end)  -- Automatic
    if U.ok(box) then pcall(function() box:SetWidthOverride(g.w) end) end
    pcall(function() msp.TV_Parts:SetEntryWidth(g.ew) end)
    if g.eh and g.eh > 0 then pcall(function() msp.TV_Parts:SetEntryHeight(g.eh) end) end
    P.nv.gridCols = g.cols
    U.log(TAG, "P%s shop grid: %d column(s) (%s: entry %d in %d)%s", tostring(P.pnum), g.cols,
        nat and "P1's native grid" or "the copy's own settings", math.floor(g.ew), math.floor(g.w),
        okS and "" or ", parts slot NOT pinned")
end

-- couch-shopstock: a shop's rows -> stock cards, LEAVE, RESTOCK, PACKS (couchrun.personalShop's order)
local function shopSplit(rows)
    local stock, leave, restock, packs = {}, nil, nil, {}
    for _, r in ipairs(rows or {}) do
        if r.rkind == "leave" then leave = leave or r
        elseif r.rkind == "restock" then restock = restock or r            -- NOTE 11: his own shop's RESTOCK
        elseif r.rkind == "pack" then packs[#packs + 1] = r
        elseif r.rkind ~= "empty" then stock[#stock + 1] = r end
    end
    return stock, leave, restock, packs
end
local function emptyPlace() return { rkind = "empty", id = "empty", name = "", bought = true } end

-- the copy's shelf cards from card rows (types kept: BUG-12); a bought / empty place = the game's PURCHASED card
local function shelfFill(items, cardRows, lo, guestArch)
    for i, it in ipairs(items or {}) do
        local r = cardRows[i]
        if r and not r.bought and r.rkind ~= "empty" then
            writeItem(it, rowInfo(r, lo, guestArch), true)                       -- keepType: the card stays an Affix (BUG-12)
            pcall(function() it.CreditsValue = math.floor(tonumber(r.price) or 0) end)
            -- #73: the scrap dealer's sale shows the struck-through full price (CreditsValueNoDiscount), as P1's
            pcall(function() it.CreditsValueNoDiscount = math.floor(tonumber(r.fullPrice or r.price) or 0) end)
            pcall(function() it.bIsAvailable = true end)
        else
            pcall(function() it.bIsAvailable = false end)
        end
    end
end

local function shelfRepaint(P)
    local nv = P.nv
    nv.animated = {}
    for _, w in pairs(nv.cards or {}) do pcall(function() w:PopulateFromVM() end) end
    P.paintAt = { St.nowMs() + 40, St.nowMs() + 300 }
end

-- his RESTOCK / PACKS rows from couchrun (the prices climb with each restock / pack on this planet), on the game's
-- own buttons
local function shopControls(P)
    if (S.kind ~= "shop" and S.kind ~= "pshop") or S.vendor then return end
    local okC, rows = pcall(function() return CR().personalShop(P.ctrlId) end)
    if not okC or type(rows) ~= "table" then return end
    local _, leave, restock, packs = shopSplit(rows)
    local byId = { restock = restock }
    for _, pk in ipairs(packs) do byId[pk.id] = pk end
    for i, r in ipairs(P.rows or {}) do
        local nr = (r.rkind == "restock" and byId.restock) or (r.rkind == "pack" and byId[r.id]) or nil
        if nr then P.rows[i] = nr end
        if r.rkind == "leave" and leave then P.rows[i] = leave end
    end
    local nv = P.nv
    if not (nv and nv.extra) then return end
    for i, b in pairs(nv.extra) do
        local r = P.rows[i]
        if r and r.rkind == "pack" then pcall(function() b:SetCost(math.floor(tonumber(r.price) or 0)) end) end
        if r and r.rkind == "restock" then
            pcall(function() b.Txt_NumCredits:SetText(U.ftext(groupDigits(r.price or 0))) end)
        end
    end
end

-- a PACK opened in his shop: its choices on the shelf's places (the game's pack picker shows them in the shop too),
-- A takes one (couchrun.packPick); LEAVE / B keep it paid and unopened for the next visit
local function packOpen(P, choices, why)
    P.pick = true
    if P.view ~= "native" or not (P.nv and P.nv.shop) then
        local rows = {}
        for _, r in ipairs(choices) do rows[#rows + 1] = r end
        rows[#rows + 1] = { rkind = "leave", id = "leave", name = "LEAVE THE SHOP", sub = "" }
        P.rows, P.sel = rows, 1
        U.log(TAG, "P%s's pack open (%s): %d choice(s)", tostring(P.pnum), tostring(why), #choices)
        return
    end
    local nv = P.nv
    local cardRows = {}
    for i = 1, nv.nCards do cardRows[i] = choices[i] or emptyPlace() end
    shelfFill(nv.items, cardRows, P.lo, M.archOfP(P))
    for i = 1, nv.nCards do P.rows[i] = cardRows[i] end
    shelfRepaint(P)
    setSel(P, 1)
    P.refocus = true                                  -- his pad's focus onto card 1 (panelTick: the ghost button)
    U.log(TAG, "P%s's pack open (%s): %d choice(s) on his shelf", tostring(P.pnum), tostring(why), #choices)
end

-- the pick taken: his stock back on the shelf (its bought marks kept), the new pack prices on the buttons
local function packClose(P)
    P.pick = nil
    if P.view ~= "native" or not (P.nv and P.nv.shop) then
        local okC, rows = pcall(function() return CR().personalShop(P.ctrlId) end)
        P.rows = (okC and type(rows) == "table") and rows or P.rows
        P.sel = math.max(1, math.min(P.sel or 1, #P.rows))
        return
    end
    local nv = P.nv
    local cardRows = P.stockRows or {}
    shelfFill(nv.items, cardRows, P.lo, M.archOfP(P))
    for i = 1, nv.nCards do P.rows[i] = cardRows[i] or emptyPlace() end
    shopControls(P)
    shelfRepaint(P)
end

local function buildNativeShop(H, P)
    local cls = U.class(SHOP_LAYOUT)
    if not U.ok(cls) then error("shop layout class not loaded") end
    local gpc = U.ok(P.pc) and P.pc or U.p1()
    local p1 = p1ShopKeys()
    local svm = vms():BuildCampaignShopVMForCurrentPlanet()
    if not U.ok(svm) then error("no shop VM") end
    if p1.shop ~= 0 and U.key(svm) == p1.shop then error("shop VM is P1's own") end
    local bvm = vms():BuildVehicleBuildVMForCampaign()
    if not U.ok(bvm) then error("no build VM") end
    if p1.build ~= 0 and U.key(bvm) == p1.build then error("build VM is P1's own") end
    local items = U.arrayToTable(svm.Affixes)
    if #items == 0 then error("shop VM has no part cards") end
    -- the shelf the natives read: every card an Affix (4) over a live Item, before and after the rewrite (a mismatch =
    -- the access violation of BUG-12 at Init, so the list panel instead)
    local function shelfSafe(when)
        for i, it in ipairs(items) do
            local t, item = nil, nil
            pcall(function() t = tonumber(it.ItemType) end)
            pcall(function() item = it.Item end)
            if t ~= ITEM_AFFIX then error(string.format("shop card %d: ItemType %s (%s), not Affix", i, tostring(t), when)) end
            if not U.ok(item) then error(string.format("shop card %d: no Item (%s)", i, when)) end
        end
    end
    shelfSafe("as built")
    local stock, leave, restock, packs = shopSplit(P.rows)
    while #stock > #items do table.remove(stock) end                 -- the native shelf's size wins
    local nStock = #stock
    -- couch-shopstock: every shelf place is a row (an empty place = a PURCHASED card): a pack's choices and a restocked
    -- stock fill the same places, the buttons after them keep their indices
    local cardRows = {}
    for i = 1, #items do cardRows[i] = stock[i] or emptyPlace() end
    shelfFill(items, cardRows, P.lo, M.archOfP(P))
    local rows = {}
    for _, r in ipairs(cardRows) do rows[#rows + 1] = r end
    leave = leave or { rkind = "leave", id = "leave", name = "LEAVE THE SHOP" }
    rows[#rows + 1] = leave
    local extraRows = {}
    if restock then rows[#rows + 1] = restock; extraRows[#rows] = "restock" end
    for _, pk in ipairs(packs) do rows[#rows + 1] = pk; extraRows[#rows] = pk.id end
    P.rows = rows
    P.stockRows = cardRows
    P.nv = { svm = svm, items = items, nCards = #items, hasSkip = true, cards = {}, animated = {}, affixes = {},
             shop = true, extra = {} }
    if P.region.strip then
        local fullOv = mk(OVER, H.tree)
        if fullOv then
            place(H.cv, fullOv, P.region.x, P.region.y, P.region.w, P.region.h, 0)
            paperBackdrop(H, H.tree, fullOv, gpc)
            P.stripPaper = fullOv
        end
    end
    local box, sb = regionBox(H, P.region, VW, VH)
    P.box = box
    local ov = mk(OVER, H.tree)
    if not ov then error("no Overlay") end
    sb:AddChild(ov)
    paperBackdrop(H, H.tree, ov, gpc)
    local inner = mk(SIZEB, H.tree)
    inner:SetWidthOverride(3840); inner:SetHeightOverride(1920)
    overlayAdd(ov, inner, 2, 2)
    local lay = U.WBL():Create(gpc, cls, gpc)
    if not U.ok(lay) then error("shop layout not created") end
    own(lay)
    pcall(function() lay.bAutoActivate = false end)
    inner:AddChild(lay)
    pcall(function() lay:SetVisibility(VIS.HitTestInvisible) end)
    local act = false
    pcall(function() act = lay:IsActivated() == true end)
    if act then pcall(function() lay:DeactivateWidget() end) end
    P.nv.lay = lay
    local okR = pcall(rewriteBuildVM, P, bvm)
    if not okR then U.warn(TAG, "P%s: shop build copy not rewritten", tostring(P.pnum)) end
    shelfSafe("rewritten")
    -- MainSelection:Init(shop) -> InitItems -> RefreshAfterBuildChange -> ShopVM:RefreshDeltaForAllItems (native, reads
    -- every card's Item by its ItemType) + BuildStatsPanel:Init(build)
    lay:Init(svm, bvm)
    P.nv.chip = headerChip(lay, P)                                  -- the header's credits chip: his credits
    local msp = nil
    pcall(function() msp = lay.WBP_Shop_MainSelectionPanel_Presentation end)
    if not U.ok(msp) then error("no main selection panel") end
    own(msp)
    ownInside(lay)
    P.nv.tv = msp.TV_Parts
    U.try(TAG, V.shopGridMatch, P, msp, p1.lay)                       -- #105: P1's column count
    for _, n in ipairs({ "WBP_Ability_Pack", "WBP_Part_Pack", "WBP_Restock_Btn", "WBP_PulseAnim" }) do
        pcall(function() msp[n]:SetVisibility(VIS.Hidden) end)
    end
    -- couch-shopstock: the PACKS column, display only (a click is P1's native PurchasePartPack / AbilityPack): his
    -- prices on the game's own buttons (SetCost = the button's own cost text), his A acts through the ghost row
    local PACK_W = { upgrade = "WBP_Part_Pack", ability = "WBP_Ability_Pack" }
    for i, what in pairs(extraRows) do
        if PACK_W[what] then
            local b = nil
            pcall(function() b = msp[PACK_W[what]] end)
            if U.ok(b) then
                pcall(function() b:SetVisibility(VIS.HitTestInvisible) end)
                pcall(function() b:SetCost(math.floor(tonumber(rows[i].price) or 0)) end)
                packBtnKeys[U.key(b)] = true
                P.nv.extra[i] = b
            end
        end
    end
    pcall(function() P.nv.leaveBtn = msp.WBP_MP_Continue_Btn end)
    -- fix16 bug 5 (live s04): his LEAVE was the panel's WBP_MP_Continue_Btn (a WBP_Hero_Btn) inside the COLLAPSED
    -- O_Continue overlay: invisible, so the focus on it showed nothing. Shown as the game's own "LEAVE THE SHOP" hero
    -- button (bottom right, right of RESTOCK; its input glyph hidden: his A acts through the ghost row), focus look by
    -- cardFocus (BP_OnFocusReceived / Lost) like the cards.
    local lb = P.nv.leaveBtn
    if U.ok(lb) then
        local label = U.ftext(leave.name or "LEAVE THE SHOP")
        pcall(function() lb:GetParent():SetVisibility(VIS.SelfHitTestInvisible) end)
        pcall(function() lb:SetVisibility(VIS.HitTestInvisible) end)
        pcall(function() lb.ButtonLabel = label end)
        pcall(function() lb:UpdateText() end)
        pcall(function() lb.Txt_Label:SetText(label) end)
        pcall(function() lb.WBP_Input_Action:SetVisibility(VIS.Collapsed) end)
    end
    if restock then
        -- the shop's own RESTOCK button, display only (its click is P1's native restock): his price on it
        pcall(function()
            local b = msp.WBP_Restock_Btn
            b:SetVisibility(VIS.HitTestInvisible)
            b.Txt_NumCredits:SetText(U.ftext(groupDigits(restock.price or 0)))
            P.nv.restockBtn = b
        end)
        for i, what in pairs(extraRows) do
            if what == "restock" and P.nv.restockBtn then P.nv.extra[i] = P.nv.restockBtn end
        end
    end
    pcall(function() P.nv.panel = lay.WBP_BuildStatsPanel_Presentation end)
    P.nv.bvm, P.nv.statsPanel = bvm, true
    U.playAnim(lay, "Anim_In")
    reapplyBuild(P)
    -- the guest's marks and input on top
    local cv = mk(CANVAS, H.tree)
    overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.badge = solid(H.tree, AMBER);          place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = text(H.tree, 64, INKD);       place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = text(H.tree, 48, INKD);      place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = text(H.tree, 96, INKD);         place(cv, W.wait, 900, 1960, nil, nil, 22)
    P.btns = {}
    for i = 1, #rows do P.btns[i] = ghostButton(H.tree, cv, 40 + (i - 1) * 130, 2040, 120, 100) end
    navCards(P.btns, W.nCards, true)
    if restock then                                   -- RESTOCK (bottom left) <-> LEAVE (bottom right): as drawn
        local lb, rb = P.btns[W.nCards + 1], P.btns[W.nCards + 2]
        navTo(lb, NAV.Left, rb)
        navTo(rb, NAV.Right, lb); navTo(rb, NAV.Up, P.btns[math.max(1, math.ceil(W.nCards / 2))])
        navTo(rb, NAV.Left, nil); navTo(rb, NAV.Down, nil); navTo(rb, NAV.Next, nil); navTo(rb, NAV.Previous, nil)
    end
    -- the PACKS column right of the shelf, as drawn: last card RIGHT -> UPGRADE PACK, DOWN -> ABILITY PACK, DOWN -> LEAVE
    local col = {}
    for i = W.nCards + 1, #rows do if rows[i].rkind == "pack" then col[#col + 1] = i end end
    if #col > 0 then
        local last = P.btns[W.nCards]
        navTo(last, NAV.Right, P.btns[col[1]])
        for k, i in ipairs(col) do
            local b = P.btns[i]
            navTo(b, NAV.Left, last)
            navTo(b, NAV.Right, nil)
            navTo(b, NAV.Up, k > 1 and P.btns[col[k - 1]] or nil)
            navTo(b, NAV.Down, k < #col and P.btns[col[k + 1]] or P.btns[W.nCards + 1])
            navTo(b, NAV.Next, nil); navTo(b, NAV.Previous, nil)
        end
        navTo(P.btns[W.nCards + 1], NAV.Up, P.btns[col[#col]])
    end
    local now = St.nowMs()
    P.paintAt = { now + 40, now + 200, now + 600, now + 1500 }
    U.log(TAG, "P%s native shop: %d card(s) of %d shelf place(s) + LEAVE%s%s, build panel %s", tostring(P.pnum), nStock,
        #items, restock and " + RESTOCK" or "", #packs > 0 and (" + " .. #packs .. " PACK(S)") or "",
        okR and "rewritten" or "P1's look")
    -- a pack he paid for and has not opened yet (a quit, a crash, B): its choice first
    local pk = nil
    pcall(function() pk = CR().pendingPack(P.ctrlId) end)
    if pk then U.try(TAG, packOpen, P, pk.rows, "his paid pack, still unopened") end
end

-- NOTE 11: his RESTOCK in his own shop - the copy's cards rewritten with the new stock (types kept), the bought marks
-- cleared, his new restock price on the shop's own button
local function restockNative(P, rows)
    local nv = P.nv
    local stock, leave, restock, packs = shopSplit(rows)
    if not (nv and nv.shop) then P.rows = rows; P.sel = 1; return end
    local cardRows = {}
    for i = 1, nv.nCards do cardRows[i] = stock[i] or emptyPlace() end
    shelfFill(nv.items, cardRows, P.lo, M.archOfP(P))
    P.stockRows = cardRows
    local newRows = {}
    for i, r in ipairs(cardRows) do newRows[i] = r end
    newRows[#newRows + 1] = leave
    if restock then newRows[#newRows + 1] = restock end
    for _, pk in ipairs(packs) do newRows[#newRows + 1] = pk end
    P.rows = newRows
    if restock and nv.restockBtn then
        pcall(function() nv.restockBtn.Txt_NumCredits:SetText(U.ftext(groupDigits(restock.price or 0))) end)
    end
    shelfRepaint(P)
    U.log(TAG, "P%s's shop restocked: %d new card(s)", tostring(P.pnum), #stock)
end

-- VIEW BUILD (blocker 4): the map footer's "View Build" opens the player menu (IA_UI_PlayerMenu -> CSM_PauseMenus
-- PlayerMenu, WBP_PlayerMenu_Presentation_C, its switcher on WBP_VehicleBuild_Presentation). While that page is up,
-- P1's menu goes into his area (couchroot) and every guest gets the SAME native page in his: a standalone
-- WBP_VehicleBuild_Presentation_C owned by his PC whose three WBP_BuildStatsPanel_Presentation panels (stats,
-- abilities, parts) are Init'ed with a build VM COPY (BuildVehicleBuildVMForCampaign, never P1's) rewritten with his
-- build. Display only (no input: P1 closes the menu); never activated. Any error = the list panel with his build.
local BUILD_VIEW = "/Game/Griffin/UI/Screens/WBP_VehicleBuild_Presentation.WBP_VehicleBuild_Presentation_C"
local PLAYER_MENU_MATCH = { "WBP_PlayerMenu_Presentation" }

local function buildNativeBuild(H, P)
    local cls = U.class(BUILD_VIEW)
    if not U.ok(cls) then error("build view class not loaded") end
    local gpc = U.ok(P.pc) and P.pc or U.p1()
    local bvm = vms():BuildVehicleBuildVMForCampaign()
    if not U.ok(bvm) then error("no build VM") end
    P.nv = { nCards = 0, hasSkip = false, cards = {}, animated = {}, affixes = {}, items = {}, build = true }
    if P.region.strip then
        local fullOv = mk(OVER, H.tree)
        if fullOv then
            place(H.cv, fullOv, P.region.x, P.region.y, P.region.w, P.region.h, 0)
            paperBackdrop(H, H.tree, fullOv, gpc)
        end
    end
    local box, sb = regionBox(H, P.region, VW, VH)
    P.box = box
    local ov = mk(OVER, H.tree)
    if not ov then error("no Overlay") end
    sb:AddChild(ov)
    paperBackdrop(H, H.tree, ov, gpc)
    local inner = mk(SIZEB, H.tree)
    inner:SetWidthOverride(3840); inner:SetHeightOverride(1920)
    overlayAdd(ov, inner, 2, 2)
    local view = U.WBL():Create(gpc, cls, gpc)
    if not U.ok(view) then error("build view not created") end
    own(view)
    pcall(function() view.bAutoActivate = false end)
    inner:AddChild(view)
    pcall(function() view:SetVisibility(VIS.HitTestInvisible) end)
    P.nv.lay = view
    P.nv.chip = headerChip(view, P)                                 -- the header's credits chip: his credits
    rewriteBuildVM(P, bvm)
    P.nv.bvm, P.nv.statsPanel = bvm, true
    P.nv.panel = view.WBP_BuildStatsPanel
    reapplyBuild(P)                                       -- the guest's bars + energy into the copy
    local n = 0
    for _, name in ipairs({ "WBP_BuildStatsPanel", "WBP_AppliedAbilities", "WBP_AppliedAffixes" }) do
        if pcall(function() view[name]:Init(bvm) end) then n = n + 1 end
    end
    if n == 0 then error("no build panel took the guest's build") end
    -- NOT Anim_In: its end runs RequestFocus -> ActivateWidget (decoded WBP_VehicleBuild_Presentation @10-88, @254)
    -- his vehicle class and racer style instead of P1's (the page's Construct -> PopulateVMs showed P1's)
    pcall(function()
        local a = U.mod("couchrun").archOf(P.ctrlId, P.pnum)
        if a ~= nil then view.WBP_VehicleTypeLarge:UpdateVehicleMaterial(a) end
    end)
    local styled = false
    pcall(function()
        local st = P.lo and P.lo.style and PD and PD.STYLES and PD.STYLES[P.lo.style]
        local asset = st and st.path and U.findLoaded(st.path, 5000)
        if asset then view.WBP_Player_Traits["Init Traits"](view.WBP_Player_Traits, asset); styled = true end
    end)
    if not styled then pcall(function() view.WBP_Player_Traits:SetVisibility(VIS.Hidden) end) end
    local cv = mk(CANVAS, H.tree)
    overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.badge = solid(H.tree, AMBER);          place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = text(H.tree, 64, INKD);       place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = text(H.tree, 48, INKD);      place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = text(H.tree, 96, INKD);         place(cv, W.wait, 900, 1960, nil, nil, 22)
    -- FINDING #12: the BACKER tab (L1) of P1's menu - a plate in his area instead of his build page (no guest contract:
    -- the run's backer is P1's, shown read-only), hidden until that tab is up
    W.backer = {}
    W.backer.title = text(H.tree, 120, INKD, FONT_DISPLAY); place(cv, W.backer.title, 300, 480, nil, nil, 23)
    W.backer.name = text(H.tree, 96, INKD, FONT_DISPLAY);   place(cv, W.backer.name, 300, 700, nil, nil, 23)
    W.backer.contract = text(H.tree, 64, INKD);             place(cv, W.backer.contract, 300, 900, nil, nil, 23)
    W.backer.note = text(H.tree, 56, INKD);                 place(cv, W.backer.note, 300, 1100, nil, nil, 23)
    for _, t in pairs(W.backer) do show(t, false) end
    W.ov, W.gpc = ov, gpc                       -- #78: the native BACKER INFO page goes into the same overlay (V.buildBacker)
    P.btns = {}
    P.paintAt = { St.nowMs() + 200, St.nowMs() + 800 }
    U.log(TAG, "P%s native build view: %d build panel(s) with his build", tostring(P.pnum), n)
end

-- NOTE 10: THE GUEST'S MYSTERY ENCOUNTER = the game's own WBP_FE_Paddock_MysteryInteraction in his area, owned by his
-- PC, display only. Decoded (kismet/WBP_FE_Paddock_MysteryInteraction): its list is filled in BP_OnActivated (from
-- NarrativeContextSubsystem:GetCurrentMysteryInteraction) and that activation also binds OnChoiceMade to P1's flow, so
-- the copy is NEVER activated: the mod fills it the same way (MysteryInteraction, List_Choices:BP_SetListItems(
-- Choices), Txt_ChoiceOverview, the NPC name from P1's header). Its entries (WBP_FE_Paddock_MysteryInteraction_Choice)
-- run CampaignRun:ChooseMysteryInteractionOutcome on P1's run when CLICKED (BP_OnClicked @718-903): they are made
-- non-focusable, the copy is HitTestInvisible, nothing of them is ever clicked or BP_OnClicked'ed. His pad drives
-- invisible buttons; a pick goes to couchrun.mysteryChoose (his run). Each entry is enabled per HIS validity (his
-- credits vs the cost; a run-wide-only choice greyed: P1's run). His credits: the game chip + P-tag top right.
local MYSTERY = "/Game/Griffin/UI/Screens/Paddock/WBP_FE_Paddock_MysteryInteraction.WBP_FE_Paddock_MysteryInteraction_C"

local function frameOfRegion(r)
    local fw = math.min(r.w, r.h * 16 / 9)
    local fh = fw * 9 / 16
    return r.x + (r.w - fw) / 2, r.y + (r.h - fh) / 2, fw, fh
end

local function buildNativeMystery(H, P)
    local inter, nat = S.mystInter, S.native
    if not U.ok(inter) then error("no mystery interaction") end
    local cls = U.class(MYSTERY)
    if not U.ok(cls) then error("mystery screen class not loaded") end
    local gpc = U.ok(P.pc) and P.pc or U.p1()
    P.nv = { mystery = true, items = {}, nCards = #P.rows, hasSkip = false, cards = {}, animated = {}, affixes = {} }
    for i, r in ipairs(P.rows) do P.nv.items[i] = r.choice end
    if P.region.strip then
        local fullOv = mk(OVER, H.tree)
        if fullOv then
            place(H.cv, fullOv, P.region.x, P.region.y, P.region.w, P.region.h, 0)
            paperBackdrop(H, H.tree, fullOv, gpc)
            P.stripPaper = fullOv
        end
    end
    local box, sb = regionBox(H, P.region, VW, VH)
    P.box = box
    local ov = mk(OVER, H.tree)
    if not ov then error("no Overlay") end
    sb:AddChild(ov)
    paperBackdrop(H, H.tree, ov, gpc)
    local scr = U.WBL():Create(gpc, cls, gpc)
    if not U.ok(scr) then error("mystery screen not created") end
    own(scr)
    pcall(function() scr.bAutoActivate = false end)
    overlayAdd(ov, scr, 0, 0)
    pcall(function() scr:SetVisibility(VIS.HitTestInvisible) end)
    P.nv.lay = scr
    -- what its BP_OnActivated does, minus the OnChoiceMade binding (P1's flow)
    pcall(function() scr.MysteryInteraction = inter end)
    local okL = pcall(function() scr.List_Choices:BP_SetListItems(inter.Choices) end)
    if not okL then error("choice list not filled") end
    pcall(function() scr.Txt_ChoiceOverview:SetText(inter.ChoiceOverview) end)
    pcall(function()
        local t = nat.WBP_SectionHeaderModal.Txt_Header:GetText()
        scr.WBP_SectionHeaderModal.Txt_Header:SetText(t)
    end)
    P.nv.tv = scr.List_Choices
    U.playAnim(scr, "Anim_In")
    -- his marks: the game chip with his P-tag top right of his frame (no mod badge), the status line, his buttons
    local cv = mk(CANVAS, H.tree)
    overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.badge = solid(H.tree, AMBER);          place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = text(H.tree, 64, INKD);       place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = text(H.tree, 48, INKD);      place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = text(H.tree, 72, INKD);         place(cv, W.wait, 900, 1960, nil, nil, 22)
    local cr = 0
    pcall(function() cr = CR().player(P.ctrlId).credits or 0 end)
    local fx, fy, fw, fh = frameOfRegion(P.region)
    local k = math.max(0.75, fh / VH)
    local okC, chip = pcall(chipAt, H, math.floor(fx + fw - 32 * k), math.floor(fy + 32 * k), k, P.pnum, cr, true)
    if okC and chip and chip.nat then W.chip, W.topChip = chip.nat, chip end
    -- the screen's OWN credits chip (bottom of its panel): its Tick reads P1's run like every header chip (live
    -- 2026-10-18, tester #3: P2's mystery copy showed P1's 10,750 there under his own 9,350) -> rewired to his credits
    local okI, inner = pcall(chipByOuter, scr)
    if okI and U.ok(inner) then
        local ic = chipRewire(inner)
        if ic then chipFeed(ic, cr); W.innerChip = ic end
    end
    U.log(TAG, "P%s mystery copy: its own credits chip %s", tostring(P.pnum),
        W.innerChip and (W.innerChip.swapped and "rewired to his credits" or "settled to his credits") or "not found")
    P.btns = {}
    for i = 1, #P.rows do P.btns[i] = ghostButton(H.tree, cv, 40 + (i - 1) * 130, 2040, 120, 100) end
    navList(P.btns, #P.rows)
    P.paintAt = { St.nowMs() + 40, St.nowMs() + 200, St.nowMs() + 600, St.nowMs() + 1500 }
    local modes = {}
    for _, r in ipairs(P.rows) do modes[#modes + 1] = r.mode end
    U.log(TAG, "P%s native mystery view: %d choice(s) (%s)", tostring(P.pnum), #P.rows, table.concat(modes, ","))
    local greyed = {}
    for i, r in ipairs(P.rows) do if r.delayed then greyed[#greyed + 1] = tostring(i) end end
    if #greyed > 0 then
        U.log(TAG, "P%s mystery: choice(s) %s paid by a later bookend: %s (#112)", tostring(P.pnum),
            table.concat(greyed, ","), CR().mysteryGreyDelayed() and "greyed for him" or "selectable (switch off)")
    end
end

-- #112: the reason line under his focused choice when it is greyed as a bookend deal (nil = none)
function V.mysteryReason(P)
    if S.kind ~= "mystery" or P.done or not P.rows then return nil end
    local row = P.rows[P.sel or 1]
    if not (row and (row.delayed or row.mode == "mixed" or row.mode == "follow")) then return nil end
    local ok, why = CR().mysteryValid(P.ctrlId, row)
    -- couch-fix32: also a choice he cannot mirror (mixed), a follow-up of P1's deal, a pool no part of his car fits
    local grey = CR().MYST_GREY_REASONS or { [CR().MYST_DELAYED_REASON] = true }
    if ok or not grey[why] then return nil end
    return why
end

-- his entries: non-focusable, enabled per HIS validity, the focused one with its own focus look
paintMystery = function(P)
    local nv = P.nv
    if not nv or not U.alive(nv.lay) then return end
    local ents = {}
    pcall(function() ents = U.arrayToTable(nv.tv:GetDisplayedEntryWidgets()) end)
    local byKey = {}
    for i, it in ipairs(nv.items) do if U.ok(it) then byKey[U.key(it)] = i end end
    local cards = {}
    for j, w in ipairs(ents) do
        if U.ok(w) then
            local i = nil
            pcall(function() i = byKey[U.key(w.Choice)] end)
            cards[i or j] = w
        end
    end
    nv.cards = cards
    for i, w in pairs(cards) do
        local k = U.key(w)
        if not nv.animated[k] then
            nv.animated[k] = true
            pcall(function() w:BP_SetIsFocusable(false) end)
        end
        local row = P.rows[i]
        local ok = row and CR().mysteryValid(P.ctrlId, row)
        pcall(function() w:SetIsEnabled(ok == true and not P.done) end)
    end
    if not nv.focusShown and not P.done and cards[P.sel] then
        nv.focusShown = P.sel
        cardFocus(cards[P.sel], true)
        pcall(function() cards[P.sel]:SetIsSelected(true, false) end)     -- the list's selected look (no click)
    end
end

---------------------------------------------------------------------------------------------------- scrap dealer
-- FINDING #20 (Jules 2026-10-17 playtest 18:12, "REPAIR PARTS vendor: only P1 can repair"): the paddock's Scrap Dealer
-- (Ori & Per, WBP_ExoticVendor_C) was matched as a SHOP: every guest got a shop in his area and nobody but P1 could
-- repair. Decoded (kismet WBP_ExoticVendor / WBP_ExoticVendorRepair_Presentation / WBP_ExoticVendorShop_Presentation,
-- JMAP CL381121): the LANDING has two WBP_Modal_Btn, SHOP (shown only when CampaignRun:ShouldBlackMarketHaveShopItems)
-- -> CSM ExoticVendor_Shop, REPAIR PARTS -> CSM ExoticVendor_Repair; B = back to the paddock. The REPAIR screen's
-- BP_OnActivated builds ViewModelSubsystem:BuildBlackMarketVMForCurrentPlanet and lists its FaultyItems
-- (WBP_AppliedAffixPanel_Presentation:InitFromCampaignItems through PopulateFaultyList); an empty list = the
-- "No Parts in need of repair" text; a selected part = WBP_FaultyAffixRepair:UpdateAffixRepair + RefreshRepairAffixText
-- (name, has faulty passives, IsRepairable) -> "Repair {0}?" + the disclosure + the cost (RefreshCredits: the
-- can-afford / NoMoneyCreditsTint and "Insufficient Credits"), "Repaired" once fixed, the unavailable text when not
-- repairable; a click = BlackMarketVM:RepairItem when AffixStatus == Faulty, affordable and IsRepairable, else
-- Anim_RepairFailed. The guest kind "vendor": each guest gets the SAME vendor in his area, on his own pad:
--   landing  the landing's look in his frame: the vendor's name over the game's WBP_Modal_Btn column (SHOP when it
--            sells, REPAIR PARTS) + LEAVE (a parked pad has no B). Not a WBP_ExoticVendor_C copy (see below);
--   repair   a standalone WBP_ExoticVendorRepair_Presentation_C, never activated (its BP_OnActivated would build P1's
--            VM and call OnEnterShop(2) on P1's run): its BlackMarketVM = a FRESH BuildBlackMarketVMForCurrentPlanet
--            whose FaultyItems are NEW AppliedAffixVMs of HIS faulty parts (couchrun.repairRows), CurrentPlayerCredits =
--            his credits, RepairCost = the game's figure; then the BP's own PopulateFaultyList / RefreshCredits /
--            RefreshRepairAffixText / UpdateAffixRepair (display only). His A = couchrun.repair (his credits, his
--            p.fixed); RepairItem / OnEnterShop / any list click never run on a guest copy. A BACK WBP_Modal_Btn;
--   shop     only when the vendor sells: his own vendor stock (couchrun.vendorStock: one per visit) on the game's shop
--            screen (buildNativeShop, as before), its LEAVE labelled BACK.
-- B (when his pad is readable) = back to the landing / leave on the landing, like the game.
V.VENDOR_REPAIR = "/Game/Griffin/UI/Screens/Paddock/WBP_ExoticVendorRepair_Presentation.WBP_ExoticVendorRepair_Presentation_C"
V.MODAL_BTN = "/Game/Griffin/UI/Widgets/Buttons/WBP_Modal_Btn.WBP_Modal_Btn_C"
V.AFFIX_VM = "/Script/Griffin.AppliedAffixVM"
V.REPAIR_EMPTY = "No Parts in need of repair"            -- CampaignText NoFaultyParts_Shop (the native empty state)
V.AFFIX_FAULTY, V.AFFIX_FIXED = 2, 3                         -- EAffixStatus

-- his area's frame (the mystery technique): the strip's paper, the region box, the paper backdrop -> gpc, overlay
function V.vendorFrame(H, P)
    local gpc = U.ok(P.pc) and P.pc or U.p1()
    if P.region.strip then
        local fullOv = mk(OVER, H.tree)
        if fullOv then
            place(H.cv, fullOv, P.region.x, P.region.y, P.region.w, P.region.h, 0)
            paperBackdrop(H, H.tree, fullOv, gpc)
            P.stripPaper = fullOv
        end
    end
    local box, sb = regionBox(H, P.region, VW, VH)
    P.box = box
    local ov = mk(OVER, H.tree)
    if not ov then error("no Overlay") end
    sb:AddChild(ov)
    paperBackdrop(H, H.tree, ov, gpc)
    return gpc, ov
end

-- a standalone native screen of his PC, display only (never activated)
function V.vendorScreen(gpc, ov, path, what)
    local cls = U.class(path)
    if not U.ok(cls) then error(what .. " class not loaded") end
    local scr = U.WBL():Create(gpc, cls, gpc)
    if not U.ok(scr) then error(what .. " not created") end
    own(scr)
    pcall(function() scr.bAutoActivate = false end)
    overlayAdd(ov, scr, 0, 0)
    pcall(function() scr:SetVisibility(VIS.HitTestInvisible) end)
    return scr
end

-- the game's modal button (WBP_Modal_Btn: the landing's own SHOP / REPAIR PARTS look) with a label, display only
function V.modalButton(gpc, label)
    local okC, cls = pcall(U.class, V.MODAL_BTN)
    if not (okC and U.ok(cls)) then return nil end
    local okB, b = pcall(function() return U.WBL():Create(gpc, cls, gpc) end)
    if not (okB and U.ok(b)) then return nil end
    own(b)
    local t = U.ftext(label)
    pcall(function() b.ButtonLabel = t end)                   -- WBP_Hero_Btn's label (+ its own UpdateText)
    pcall(function() b:SetText(t) end)                        -- WBP_Modal_Btn:SetText (BP event)
    pcall(function() b:SetVisibility(VIS.HitTestInvisible) end)
    return b
end

-- his marks over the view: the mod badge (hidden once the game chip is up), status line, the game chip with his P-tag
-- top right of his frame (made ONCE per area: it sits on the host canvas, a view switch keeps it), his ghost buttons
function V.vendorMarks(H, P, ov)
    local cv = mk(CANVAS, H.tree)
    overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.badge = solid(H.tree, AMBER);          place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = text(H.tree, 64, INKD);       place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = text(H.tree, 48, INKD);      place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = text(H.tree, 72, INKD);         place(cv, W.wait, 900, 1960, nil, nil, 22)
    if not P.vchip then
        local cr = 0
        pcall(function() cr = CR().player(P.ctrlId).credits or 0 end)
        local fx, fy, fw, fh = frameOfRegion(P.region)
        local k = math.max(0.75, fh / VH)
        local okC, chip = pcall(chipAt, H, math.floor(fx + fw - 32 * k), math.floor(fy + 32 * k), k, P.pnum, cr, true)
        P.vchip = (okC and type(chip) == "table") and chip or false
    end
    if P.vchip then
        for _, w in ipairs(P.vchip.parts or {}) do pcall(function() w:SetVisibility(VIS.HitTestInvisible) end) end
        if P.vchip.nat then W.chip, W.topChip = P.vchip.nat, P.vchip end
    end
    P.btns = {}
    for i = 1, #P.rows do P.btns[i] = ghostButton(H.tree, cv, 40 + (i - 1) * 130, 2040, 120, 100) end
    navList(P.btns, #P.rows)
    local now = St.nowMs()
    P.paintAt = { now + 40, now + 200, now + 600, now + 1500 }
    return cv
end

-- FINDING #73 / #32: the dealer's SHOP page for him = the game's own WBP_ExoticVendorShop_Presentation_C (the SCRAP
-- DEALER header, its 3 item places WBP_Item_1..3, its build panel), never activated (BP_OnActivated = OnEnterShop(1) on
-- P1's run), HitTestInvisible, its cards never focusable (a card click = TryPurchaseItem -> BlackMarketVM:PurchaseItem
-- on P1's run). Its Construct builds a fresh BlackMarketVM (P1's stock), PopulateItems and RefreshBuildVM (P1's build):
-- the copy gets HIS VM (a fresh BuildBlackMarketVMForCurrentPlanet whose Items are rewritten with his couchrun stock;
-- topped up from a fresh shop VM's affix cards when P1 already bought some) and HIS build VM, put back by every paint
-- when its Construct ran after the build (V.vendorShopKeep). His A = couchrun.buy (his credits, the part FAULTY).
V.VENDOR_SHOP = "/Game/Griffin/UI/Screens/Paddock/WBP_ExoticVendorShop_Presentation.WBP_ExoticVendorShop_Presentation_C"
V.VENDOR_SHOP_PLACES = 3
V.SHOP_BACK = { 920, 1705, 760, 130 }                   -- #79: x, y, w, h of his BACK (campaign units)
function V.buildVendorShop(H, P)
    local stock, leave = shopSplit(P.rows)
    local bm = vms():BuildBlackMarketVMForCurrentPlanet()
    if not U.ok(bm) then error("no black market VM") end
    local p1bm = 0
    pcall(function() local x = S.native.VendorVM; if U.ok(x) then p1bm = U.key(x) end end)
    if p1bm ~= 0 and U.key(bm) == p1bm then error("black market VM is P1's own") end
    local items = U.arrayToTable(bm.Items)
    local want = math.min(V.VENDOR_SHOP_PLACES, math.max(1, #stock))
    if #items < want then
        -- P1 bought from his stock already (a fresh VM lists what is left): affix cards of a fresh shop VM (live Items
        -- of ItemType Affix, the kind the card natives read)
        local svm = vms():BuildCampaignShopVMForCurrentPlanet()
        local extra = U.ok(svm) and U.arrayToTable(svm.Affixes) or {}
        for _, it in ipairs(extra) do
            if #items >= want then break end
            if not pcall(function() bm.Items[#items + 1] = it end) then error("vendor Items not grown") end
            items[#items + 1] = it
        end
    end
    while #items > V.VENDOR_SHOP_PLACES do table.remove(items) end
    if #items == 0 then error("vendor VM has no item") end
    for i, it in ipairs(items) do
        local t, item = nil, nil
        pcall(function() t = tonumber(it.ItemType) end)
        pcall(function() item = it.Item end)
        if t ~= ITEM_AFFIX then error(string.format("vendor card %d: ItemType %s, not Affix", i, tostring(t))) end
        if not U.ok(item) then error(string.format("vendor card %d: no Item", i)) end
    end
    local cardRows = {}
    for i = 1, #items do cardRows[i] = stock[i] or emptyPlace() end
    shelfFill(items, cardRows, P.lo, M.archOfP(P))
    local rows = {}
    for _, r in ipairs(cardRows) do rows[#rows + 1] = r end
    leave = leave or { rkind = "leave", id = "leave", name = "BACK", sub = "" }
    rows[#rows + 1] = leave
    P.rows, P.stockRows = rows, cardRows
    local bvm = vms():BuildVehicleBuildVMForCampaign()
    if not U.ok(bvm) then error("no build VM") end
    local gpc, ov = V.vendorFrame(H, P)
    local scr = V.vendorScreen(gpc, ov, V.VENDOR_SHOP, "scrap dealer shop")
    P.nv = { vendor = "shop", lay = scr, bm = bm, bvm = bvm, items = items, nCards = #items, hasSkip = true, cards = {},
             animated = {}, affixes = {}, shop = true, extra = {}, statsPanel = true }
    pcall(function() P.nv.panel = scr.WBP_BuildStatsPanel_Presentation end)
    local okR = pcall(rewriteBuildVM, P, bvm)
    if not okR then U.warn(TAG, "P%s: scrap dealer build copy not rewritten", tostring(P.pnum)) end
    V.vendorShopKeep(P, true)
    P.nv.chip = headerChip(scr, P)                                  -- the header's credits chip: his credits
    ownInside(scr)
    local back = V.modalButton(gpc, leave.name or "BACK")
    if back then pcall(function() back:BP_SetIsFocusable(false) end) end
    local hchip = P.nv.chip
    local cv = V.vendorMarks(H, P, ov)
    -- #79: vendorMarks set nv.chip to the landing's top chip (collapsed on this page): the fed chip = the header's
    -- (rewired: P1's Tick writes a dummy, so only renderNative's feed shows a figure; it kept P1's 7,520)
    if hchip then P.nv.chip, P.nv.topChip = hchip, nil end
    if back then
        -- #79: under the cards' box (its bottom ~1665), centred on it; VW - 1000 sat over the INSTALLED PARTS panel
        pcall(place, cv, back, V.SHOP_BACK[1], V.SHOP_BACK[2], V.SHOP_BACK[3], V.SHOP_BACK[4], 25)
        P.nv.leaveBtn = back
    end
    navCards(P.btns, P.nv.nCards, true)                -- the cards side by side, BACK under them (as drawn)
    reapplyBuild(P)
    local names = {}
    for i = 1, #items do names[#names + 1] = cardRows[i].bought and "-" or tostring(cardRows[i].name) end
    U.log(TAG, "P%s native scrap dealer shop: %d experimental part(s) of %d place(s) (%s) + %s, build panel %s",
        tostring(P.pnum), math.min(#stock, #items), #items, table.concat(names, ", "), tostring(leave.name),
        okR and "rewritten" or "P1's look")
end

-- his VM / build VM on the dealer's shop copy (again after its Construct: a fresh VM of P1's stock and P1's build),
-- then PopulateItems (the cards' Init from his items) and the build panel's Init. force = the first time.
function V.vendorShopKeep(P, force)
    local nv = P.nv
    if not (nv and nv.vendor == "shop" and U.alive(nv.lay)) then return false end
    local scr = nv.lay
    local cur, curB = 0, 0
    pcall(function() cur = U.key(scr.VendorVM) end)
    pcall(function() curB = U.key(scr.BuildVM) end)
    local redo = force or cur ~= U.key(nv.bm) or curB ~= U.key(nv.bvm)
    if not redo then return false end
    pcall(function() scr.VendorVM = nv.bm end)
    pcall(function() scr.BuildVM = nv.bvm end)
    pcall(function()                                               -- #79: ItemVM:CanPurchase reads HIS credits
        local p = P.ctrlId and CR().player(P.ctrlId) or nil
        nv.bm.CurrentPlayerCredits = p and p.credits or 0
    end)
    pcall(function() scr:PopulateItems(nv.bm) end)
    pcall(function() nv.panel:Init(nv.bvm) end)
    pcall(function() scr:SetVisibility(VIS.HitTestInvisible) end)
    for i = 1, V.VENDOR_SHOP_PLACES do
        local w = nil
        pcall(function() w = scr["WBP_Item_" .. i] end)
        if U.ok(w) then
            if i <= nv.nCards then
                nv.cards[i] = w
                pcall(function() w:BP_SetIsFocusable(false) end)
                pcall(function() w:SetVisibility(VIS.HitTestInvisible) end)
            else
                pcall(function() w:SetVisibility(VIS.Hidden) end)
            end
        end
    end
    nv.animated = {}
    if not force then
        U.log(TAG, "P%s's scrap dealer shop copy: his stock / build put back (its Construct ran after the build)",
            tostring(P.pnum))
    end
    return true
end

-- couch-fix46 (live round 1 AUTO-120, shots 145408 / 145440): the landing's "Ori & Per" ran over the SCRAP DEALER
-- title and PART SLOTS FULL's body over its title. A text line's glyphs take more than its font size in canvas units
-- (measured on the 2P shots, 0.5 canvas scale: the display font ~1.6 x the size from the slot's top to the glyphs'
-- end, the body font ~1.5 x); the lines were 1.4 / 1.38 x apart. And at 3 / 4 players (a quadrant: canvas scale 0.25)
-- the frame's top-right credits chip (chipAt: 105 x k px tall at 32 x k from the top, k >= 0.75 whatever the frame)
-- reaches 412 canvas units down, over a title at 300. Now the lines stack by their real heights from below his chip.
-- Pure: fh = his frame's height (px), specs = { {size, body}... } -> the lines' y (canvas units), the stack's end
V.LINE_K = { display = 1.6, body = 1.5 }
V.LINE_GAP = 24
function V.headerTop(fh)
    fh = tonumber(fh) or VH / 2
    local sc = math.max(0.05, fh / VH)
    local k = math.max(0.75, fh / VH)
    return math.floor((32 * k + 105 * k) / sc + 40 + 0.5)
end
function V.stackLines(fh, top, specs)
    local y = math.max(tonumber(top) or 0, V.headerTop(fh))
    local ys = {}
    for i, sp in ipairs(specs) do
        ys[i] = y
        y = y + math.floor(sp[1] * (sp[2] and V.LINE_K.body or V.LINE_K.display) + 0.5) + V.LINE_GAP
    end
    return ys, y
end

-- the vendor's landing for him: the landing's own look (the vendor's name over a column of the game's WBP_Modal_Btn:
-- SHOP when the vendor sells, REPAIR PARTS, + LEAVE) built in his frame. NOT a WBP_ExoticVendor_C copy: its Construct
-- binds AnimIn's end to FuseScreenWidget:OnTransitionInComplete (native, for its CosmeticStateMachine), and a guest
-- copy has no state machine.
function V.buildVendorLanding(H, P)
    local gpc, ov = V.vendorFrame(H, P)
    local cv = mk(CANVAS, H.tree)
    if not cv then error("no Canvas") end
    overlayAdd(ov, cv, 0, 0)
    P.nv = { vendor = "landing", lay = cv, items = {}, nCards = #P.rows, hasSkip = false, cards = {}, animated = {},
             affixes = {} }
    local _, _, _, fh = frameOfRegion(P.region)
    local ys, yEnd = V.stackLines(fh, 560, { { 150 }, { 64, true } })    -- couch-fix46: never over each other / his chip
    P.nv.lineYs = ys
    local title = text(H.tree, 150, INKD)
    setText(title, "SCRAP DEALER")
    local s1 = place(cv, title, VW / 2, ys[1], nil, nil, 5)
    pcall(function() s1:SetAlignment({ X = 0.5, Y = 0 }) end)
    local sub = text(H.tree, 64, INKD, FONT_BODY)
    setText(sub, "Ori & Per")
    local s2 = place(cv, sub, VW / 2, ys[2], nil, nil, 5)
    pcall(function() s2:SetAlignment({ X = 0.5, Y = 0 }) end)
    local rowY = math.max(960, yEnd + 60)
    P.nv.rowY = rowY
    local made = 0
    for i, r in ipairs(P.rows) do
        local b = V.modalButton(gpc, r.name)
        if b then
            made = made + 1
            pcall(function() b:BP_SetIsFocusable(false) end)        -- his pad drives the ghost rows, nobody this button
            local okP = pcall(place, cv, b, (VW - 1200) / 2, rowY + (i - 1) * 210, 1200, 170, 6)
            if not okP then error("landing button not placed") end
            P.nv.cards[i] = b
        end
    end
    if made == 0 then error("no WBP_Modal_Btn") end
    V.vendorMarks(H, P, ov)
    local names = {}
    for _, r in ipairs(P.rows) do names[#names + 1] = r.name end
    U.log(TAG, "P%s native scrap dealer: %s%s", tostring(P.pnum), table.concat(names, " + "),
        V.hasShopRow(P) and "" or " (the vendor sells nothing here)")
end
function V.hasShopRow(P)
    for _, r in ipairs(P.rows or {}) do if r.rkind == "vshop" then return true end end
    return false
end

-- one AppliedAffixVM of his: the part's own texts / rarity, its status (Faulty / Fixed), the fault text
function V.writeAffixVM(o, r)
    local d = PD and PD.PARTS and PD.PARTS[r.id] or {}
    local desc = d.rich or d.desc or ""
    pcall(function() o.Name = U.ftext(d.name or r.name or r.id) end)
    pcall(function() o.Description = U.ftext(desc) end)
    pcall(function() o.Rarity = tonumber(d.rarity) or 4 end)
    pcall(function() o.IsPlaneOnly = d.planeOnly == true end)
    pcall(function() o.IsRepairable = r.repairable ~= false end)
    pcall(function() o.AffixStatus = r.status end)
    if d.path then
        local cfgObj = nil
        pcall(function() cfgObj = U.obj(d.path) end)          -- the affix config (as perkapply finds / loads it)
        if U.ok(cfgObj) then pcall(function() o.PrimaryAffixConfig = cfgObj end) end
    end
    pcall(function() o.FaultyPassiveFlavourTexts:Empty() end)
    -- #91: a faulted part (dealer buy / malfunction: r.fault = its AFX_Faulty_* drawback) shows the drawback's text
    local fd = r.fault and PD and PD.PARTS and PD.PARTS[r.fault] or nil
    local ftext = fd and (fd.rich or fd.desc or fd.name) or desc
    if r.status == V.AFFIX_FAULTY then pcall(function() o.FaultyPassiveFlavourTexts[1] = U.ftext(ftext) end) end
end

-- the vendor's REPAIR PARTS for him (his faulty parts). Errors are raised (the caller falls back to the list panel).
function V.buildVendorRepair(H, P)
    local p = P.ctrlId and CR().player(P.ctrlId) or nil
    local bm = vms():BuildBlackMarketVMForCurrentPlanet()
    if not U.ok(bm) then error("no black market VM") end
    local p1bm = 0
    pcall(function() local x = S.native.BlackMarketVM; if U.ok(x) then p1bm = U.key(x) end end)
    if p1bm ~= 0 and U.key(bm) == p1bm then error("black market VM is P1's own") end
    local nativeCost = nil
    pcall(function() nativeCost = tonumber(bm.RepairCost) end)
    local cost = CR().repairPrice(p, nativeCost)
    -- his parts: NEW AppliedAffixVMs (the fresh VM's own entries are P1's faulty parts), appended one past the end
    if not pcall(function() bm.FaultyItems:Empty() end) then error("FaultyItems not cleared") end
    local acls = U.class(V.AFFIX_VM)
    local list = {}
    for _, r in ipairs(P.rows) do
        if r.rkind == "repair" then
            local okO, o = false, nil
            if U.ok(acls) then okO, o = pcall(StaticConstructObject, acls, bm) end
            if not (okO and U.ok(o)) then error("no AppliedAffixVM for " .. tostring(r.id)) end
            V.writeAffixVM(o, r)
            if not pcall(function() bm.FaultyItems[#list + 1] = o end) then error("FaultyItems not grown") end
            list[#list + 1] = o
            r.vm = o
        end
    end
    pcall(function() bm.CurrentPlayerCredits = p and p.credits or 0 end)
    pcall(function() bm.RepairCost = cost end)
    local gpc, ov = V.vendorFrame(H, P)
    local scr = V.vendorScreen(gpc, ov, V.VENDOR_REPAIR, "repair screen")
    pcall(function() scr.BlackMarketVM = bm end)
    P.nv = { vendor = "repair", lay = scr, bm = bm, cost = cost, items = list, nCards = #P.rows, hasSkip = false,
             cards = {}, animated = {}, affixes = {} }
    local fr = nil
    pcall(function() fr = scr.WBP_FaultyAffixRepair end)
    if #list == 0 then
        -- the game's empty state (BP_OnActivated, FaultyItems empty): the list empty, the text, nothing to pay
        pcall(function() scr.Txt_RepairAffix:SetText(U.ftext(V.REPAIR_EMPTY)) end)
        pcall(function() scr.Txt_RepairAffix:SetVisibility(VIS.SelfHitTestInvisible) end)
        for _, n in ipairs({ "Txt_RepairDisclosure", "Txt_PlayerIsSkint", "Txt_RepairUnavailable", "Txt_Repaired",
                             "HB_CreditCost" }) do
            pcall(function() scr[n]:SetVisibility(VIS.Collapsed) end)
        end
        if U.ok(fr) then pcall(function() fr:HideFaultyDescription() end) end
    else
        if not pcall(function() scr:PopulateFaultyList() end) then error("PopulateFaultyList failed") end
        if U.ok(fr) then pcall(function() fr:HideFaultyDescription() end) end
        pcall(function() scr:RefreshCredits() end)
    end
    -- couch-fix63 (AUTO-154d, live round 8 shot scrap-repair: two credit chips on top of each other): the repair page
    -- has the game's header (WBP_Header_Presentation) with its own credits chip at the landing chip's place. That
    -- chip is his (rewired, his P-tag inside), as on the shop page; vendorSwitch collapses the landing's top chip
    local hchip = headerChip(scr, P)
    ownInside(scr)
    local back = V.modalButton(gpc, "BACK")
    if back then pcall(function() back:BP_SetIsFocusable(false) end) end
    local cv = V.vendorMarks(H, P, ov)
    if hchip then P.nv.chip, P.nv.topChip, P.nv.headerChip = hchip, nil, true end
    if back then
        pcall(place, cv, back, VW - 1000, 1800, 760, 150, 25)
        P.nv.back = back
    end
    P.nv.cards[#P.rows] = back
    V.repairDetail(P)
    local faulty = 0
    for _, r in ipairs(P.rows) do if r.rkind == "repair" and r.status == V.AFFIX_FAULTY then faulty = faulty + 1 end end
    U.log(TAG, "P%s native repair view: %d part(s) listed (%d faulty), repair %d CR, his credits %d%s", tostring(P.pnum),
        #list, faulty, cost, p and p.credits or 0, #list == 0 and " (empty: \"" .. V.REPAIR_EMPTY .. "\")" or "")
end

-- the detail of his focused part (what the game's AffixItemSelected runs): fault text, "Repair X?" / "Repaired", cost
V.repairDetail = function(P)
    local nv = P.nv
    if not (nv and nv.vendor == "repair" and U.alive(nv.lay)) then return end
    local scr, r = nv.lay, P.rows and P.rows[P.sel]
    local p = P.ctrlId and CR().player(P.ctrlId) or nil
    pcall(function() nv.bm.CurrentPlayerCredits = p and p.credits or 0 end)
    if not (r and r.rkind == "repair" and U.ok(r.vm)) then return end           -- BACK: the last part stays shown
    pcall(function() scr.WBP_FaultyAffixRepair:UpdateAffixRepair(r.vm) end)
    pcall(function() scr:RefreshRepairAffixText(U.ftext(r.name), r.status == V.AFFIX_FAULTY, r.repairable ~= false) end)
    pcall(function() scr:RefreshCredits() end)
    local d = PD and PD.PARTS and PD.PARTS[r.id]
    if d then pcall(function() brush(scr.WBP_FaultyAffixRepair.WBP_Build_Affix_Presentation.Img_AffixIcon, d.large or d.icon) end) end
end

-- his entries (the list view generates them after PopulateFaultyList): icons, never focusable, the focus look
V.paintVendor = function(P)
    local nv = P.nv
    if not nv or not U.alive(nv.lay) then return end
    if nv.vendor == "shop" then
        -- #73: his stock / build back on the copy if its Construct replaced them, then his cards' texts and prices
        V.vendorShopKeep(P)
        for i = 1, nv.nCards do
            local w = nv.cards[i]
            if U.ok(w) and P.rows[i] then
                local k = U.key(w)
                if not nv.animated[k] then
                    nv.animated[k] = true
                    pcall(function() w:PopulateFromVM() end)
                end
                paintCard(P, w, P.rows[i], false)
                -- #79: enabled (a disabled card is drawn at the screen's alpha-on-disable), and no retained foil
                -- render left on a card his cursor is not on (a stale, blurred capture)
                M.liven(w)
                -- couch-fix46 (shots 145418 / 145428: the card under his cursor was the blank, blurred one - card 1,
                -- then card 2 after his buy): the focused card's retained foil render is as stale on a copy as the
                -- others'. No retained render on any card of his (the hover look stays: Anim_Hover, the stroke)
                pcall(function() w.RB_Hover:SetRetainRendering(false) end)
            end
        end
        reapplyBuild(P)
        paintBuildIcons(P)
    end
    if nv.vendor == "repair" then
        local ents = {}
        pcall(function() ents = U.arrayToTable(nv.lay.WBP_AppliedAffixPanel_Presentation.LV_AppliedAffixes:GetDisplayedEntryWidgets()) end)
        local byKey = {}
        for i, r in ipairs(P.rows) do if U.ok(r.vm) then byKey[U.key(r.vm)] = i end end
        for _, w in ipairs(ents) do
            if U.ok(w) then
                local i = nil
                pcall(function() i = byKey[U.key(w.AppliedAffixVM)] end)
                if i then
                    nv.cards[i] = w
                    local k = U.key(w)
                    if not nv.animated[k] then
                        nv.animated[k] = true
                        pcall(function() w:BP_SetIsFocusable(false) end)
                    end
                    local d = PD and PD.PARTS and PD.PARTS[P.rows[i].id]
                    if d then pcall(function() brush(w.WBP_Build_Affix_Presentation.Img_AffixIcon, d.icon) end) end
                end
            end
        end
    end
    if not nv.focusShown and not P.done and nv.cards[P.sel] then
        nv.focusShown = P.sel
        cardFocus(nv.cards[P.sel], true)
    end
end

local function renderNative(P)
    local W = P.nv
    if not W then return end
    local p = P.ctrlId and CR().player(P.ctrlId) or nil
    setText(W.badgeT, "P" .. tostring(P.pnum or "?"))
    -- NOTE 8: his P-tag is inside the copy's own header pill: no mod badge over the screen title
    -- NOTE 9: with his chip found (rewired or settled) the mod badge and its "6100 CR" never show
    local tagged = W.chip ~= nil
    show(W.badge, not tagged); show(W.badgeT, not tagged)
    -- his credits in the copy's own native chip; the mod text only when that chip is missing (no duplicate figure)
    local cr = p and p.credits or 0
    if chipFeed(W.chip, cr) then setText(W.credits, "") else setText(W.credits, string.format("%d CR", cr)) end
    local now = St.nowMs()
    if S.kind == "build" then
        setText(W.wait, "")
    elseif P.done and S.p1Left then
        setText(W.wait, "")                                   -- #83: P1 is gone: nobody is waited for (closing)
    elseif S.p1Left then
        setText(W.wait, (P.toast and now < (P.toastUntil or 0)) and P.toast or "P1 IS ON THE MAP - FINISH YOUR REWARDS")
        pcall(function() W.lay:SetRenderOpacity(1) end)
    elseif P.done then
        local idle = (S.kind == "vendor" and "LEFT THE SCRAP DEALER - WAITING FOR P1")
            or (P.backerMode and require("couchbackerui").idle(P))
            or (V.shopLike(P) and "LEFT THE SHOP - WAITING FOR P1")
            or ((S.kind == "mystery") and P.passed and (V.MYST_TEAM_NOTE .. " - WAITING FOR P1"))
            or ((S.kind == "mystery") and "CHOSEN - WAITING FOR P1")
            or (P.flowMode and "REWARDS COLLECTED - WAITING FOR P1" or "PICKED - WAITING FOR P1")
        setText(W.wait, (P.toast and now < (P.toastUntil or 0)) and (P.toast .. "  -  WAITING FOR P1") or idle)
        pcall(function() W.lay:SetRenderOpacity(0.55) end)
    else
        -- couch-fix54 (AUTO-132): no takeable row = the team note and his way out
        local note = V.mysteryNoChoice(P) and (V.MYST_TEAM_NOTE .. " - A: OK") or nil
        setText(W.wait, (P.toast and now < (P.toastUntil or 0)) and P.toast or note or V.mysteryReason(P) or "")
        pcall(function() W.lay:SetRenderOpacity(1) end)
    end
end

---------------------------------------------------------------------------------------------------- list view (fallback)
-- BUG-13 (live 2026-10-14, SURGING SHIELD): catalog rows from run.makeOffer carry `sub` = the keyword ICON PATH
-- ("Icons/Keywords/T_UI_Keyword_Surge_Icn") - the list printed it as the row's tag line. A label is shown only when it
-- is not an asset path. pure: -> the text or nil
local function plainLabel(s)
    if type(s) ~= "string" or s == "" then return nil end
    if s:find("^/Game/") or s:find("^/Script/") or s:find("^Icons/") or s:find("T_UI_[%w_]+$")
        or s:find("%.uasset$") or (s:find("/", 1, true) and not s:find("%s")) then
        return nil
    end
    return s
end
M.plainLabel = plainLabel

local function buildList(H, P)
    local geo = LIST_GEO[P.region.shape] or LIST_GEO.half
    -- the guest's WHOLE area opaque (the ScaleToFit box leaves the strip's sides open)
    local full = solid(H.tree, DEEP); place(H.cv, full, P.region.x, P.region.y, P.region.w, P.region.h, 0)
    local box, sb = regionBox(H, P.region, geo.dw, geo.dh)
    P.box = box
    local tree = H.tree
    local cv = mk(CANVAS, tree)
    if not cv then error("no Canvas") end
    sb:AddChild(cv)
    local DW, DH = geo.dw, geo.dh
    local PW = DW - 120
    local W = { rows = {}, geo = geo, full = full }
    W.back = solid(tree, DEEP);            place(cv, W.back, 0, 0, DW, DH, 0)
    W.badge = solid(tree, AMBER);          place(cv, W.badge, 60, geo.title + 4, 124, 88, 2)
    W.badgeT = text(tree, geo.badge or 54, INKD); place(cv, W.badgeT, 78, geo.title + 8, nil, nil, 3)
    W.title = text(tree, 64, CREAM);       place(cv, W.title, 214, geo.title, nil, nil, 2)
    W.sub = text(tree, 30, PAPER, FONT_BODY); place(cv, W.sub, 218, geo.sub, nil, nil, 2)
    W.chip = solid(tree, ROW);             place(cv, W.chip, DW - 580, geo.chip, 520, 80, 2)    -- "LANDSPEEDER" fits
    W.chipT = text(tree, 40, CREAM);       place(cv, W.chipT, DW - 550, geo.chip + 12, nil, nil, 3)
    P.btns = {}
    for i = 1, ROW_MAX do
        local y = geo.y0 + (i - 1) * (geo.rh + geo.gap)
        local R = {}
        local ih = math.min(180, geo.rh - 40)
        R.bg = solid(tree, ROW);           place(cv, R.bg, 60, y, PW, geo.rh, 2)
        R.icon = mk(IMAGE, tree);          place(cv, R.icon, 90, y + (geo.rh - ih) / 2, ih, ih, 3)
        pcall(function() R.icon:SetVisibility(VIS.HitTestInvisible) end)
        local tx = 124 + ih + 40
        R.name = text(tree, geo.nameS or 44, CREAM); place(cv, R.name, tx - 4, y + (geo.nameY or 22), nil, nil, 3)
        R.tag = text(tree, 26, AMBER, FONT_BODY); place(cv, R.tag, tx, y + (geo.tagY or 80), nil, nil, 3)
        -- a sized slot: the auto-wrap follows the slot's width (WrapTextAt alone wrapped at the text's own short size)
        local dw = DW - 480 - tx
        R.desc = text(tree, 28, PAPER, FONT_BODY, dw)
        place(cv, R.desc, tx, y + (geo.descY or 118), dw, geo.rh - (geo.descY or 118), 3)
        -- right-aligned on the row's inner edge: "2000 CR" overflowed the strip with a left anchor (BUG-13)
        R.price = text(tree, 40, CREAM)
        local ps = place(cv, R.price, DW - 96, y + 30, nil, nil, 3)
        pcall(function() ps:SetAlignment({ X = 1, Y = 0 }) end)
        P.btns[i] = ghostButton(tree, cv, 60, y, PW, geo.rh)
        W.rows[i] = R
    end
    W.foot = text(tree, 30, PAPER, FONT_BODY); place(cv, W.foot, 60, DH - geo.foot, nil, nil, 2)
    W.toast = text(tree, 48, AMBER);       place(cv, W.toast, 60, DH - geo.toast, nil, nil, 4)
    if S.kind == "garage" then
        -- garage.lua: LEFT / RIGHT change the focused row. Slate moves his focus onto one of these two sentinels (every
        -- row's Left / Right rule), panelTick reads it, steps the row and puts the focus back on the row
        P.side = { L = ghostButton(tree, cv, 0, 0, 20, 20), R = ghostButton(tree, cv, DW - 20, 0, 20, 20) }
        for _, b in pairs(P.side) do
            for _, d in pairs(NAV) do navTo(b, d, nil) end
        end
        -- a palette row's three colour swatches (the game's livery colours), right of its text
        for i = 1, ROW_MAX do
            local y = geo.y0 + (i - 1) * (geo.rh + geo.gap)
            local R = W.rows[i]
            R.sw = {}
            for k = 1, 3 do
                R.sw[k] = solid(tree, ROW)
                place(cv, R.sw[k], DW - 420 + (k - 1) * 110, y + (geo.rh - 90) / 2, 90, 90, 4)
                show(R.sw[k], false)
            end
        end
        -- 4-way garage: garage4ui's area (his 3D car) over the list; the list's own pieces stay collapsed, its ghost
        -- buttons and sentinels keep the input
        local g4, ui = G4(), G4UI()
        if g4 and ui then
            local okA, A = pcall(ui.buildArea, tree, cv, 0, 0, DW, DH)
            if okA and type(A) == "table" then
                P.g4 = A
                for _, k in ipairs({ "back", "badge", "badgeT", "title", "sub", "chip", "chipT", "foot", "toast" }) do show(W[k], false) end
                for i = 1, ROW_MAX do
                    local R = W.rows[i]
                    for _, k in ipairs({ "bg", "icon", "name", "tag", "desc", "price" }) do show(R[k], false) end
                    for k = 1, 3 do show(R.sw[k], false) end
                end
            else
                U.warn(TAG, "P%s 4-way garage area failed (%s): the list garage", tostring(P.pnum), tostring(A))
            end
        end
    end
    P.lv = W
end

-- garage.lua's rows in the list view: LABEL / "<  VALUE  >  i / n" / a line; the model's badge, a palette's swatches
local function garageClass(P)
    local ok, s = pcall(function() return U.mod("garage").className(P.arch) end)
    return string.lower((ok and type(s) == "string") and s or "car")
end

local function hexColour(h)
    if type(h) ~= "string" or #h < 6 then return nil end
    local function ch(i) return (tonumber(h:sub(i, i + 1), 16) or 0) / 255 end
    local function lin1(c) return (c <= 0.04045) and (c / 12.92) or (((c + 0.055) / 1.055) ^ 2.4) end
    return { R = lin1(ch(1)), G = lin1(ch(3)), B = lin1(ch(5)), A = 1 }
end
M.hexColour = hexColour

-- 4-way garage: the same rows / input as the list garage, drawn by garage4ui with his 3D car
local function renderGarage4(P, W)
    local n = 0
    for i = 1, ROW_MAX do
        if P.rows and P.rows[i] then n = i end
        local b = P.btns and P.btns[i]
        if U.ok(b) then pcall(function() b:SetVisibility((P.rows and P.rows[i]) and VIS.Visible or VIS.Collapsed) end) end
    end
    if W.navN ~= n then
        W.navN = n
        navList(P.btns, n)
        for i = 1, n do
            navTo(P.btns[i], NAV.Left, P.side and P.side.L or nil)
            navTo(P.btns[i], NAV.Right, P.side and P.side.R or nil)
        end
    end
    local now = St.nowMs()
    local vm = { pnum = P.pnum, colour = C.COLOURS[P.pnum] or C.COLOURS.Remote, who = "P" .. tostring(P.pnum),
                 title = "GARAGE", className = string.upper(garageClass(P)), rows = {}, sel = P.sel,
                 done = P.done == true, toast = (P.toast and now < (P.toastUntil or 0)) and P.toast or nil,
                 -- the front end's hint (garage4.HINT): A steps the row, the DONE row closes (a parked pad's B is unreadable)
                 hint = P.mirror and "TEST MIRROR - no pad" or "UP / DOWN choose   LEFT / RIGHT change   A next   DONE: ready",
                 waiting = "GARAGE CLOSED - waiting for P1" }
    for i, r in ipairs(P.rows or {}) do
        vm.rows[i] = { kind = r.rkind, label = r.name, value = r.value, sub = r.sub, desc = r.desc, icon = r.icon,
                       colours = r.colours, focus = (i == P.sel) and not P.done }
        if r.key == "model" then vm.model = r.value end
    end
    local g = G4()
    if g then
        local br, kind, dim = g.campaignBrush(P)
        vm.brush, vm.brushKind, vm.dim = br, kind, dim
    end
    local ui = G4UI()
    if ui then ui.renderArea(P.g4, vm) end
end

local function renderGarage(P, W)
    if P.g4 then return renderGarage4(P, W) end
    local n = 0
    for i = 1, ROW_MAX do
        local R, it = W.rows[i], P.rows and P.rows[i] or nil
        local on = it ~= nil
        if on then n = i end
        for _, k in ipairs({ "bg", "icon", "name", "tag", "desc", "price" }) do show(R[k], on) end
        local b = P.btns and P.btns[i]
        if U.ok(b) then pcall(function() b:SetVisibility(on and VIS.Visible or VIS.Collapsed) end) end
        local focus = on and (i == P.sel) and not P.done
        if it then
            pcall(function() R.bg:SetColorAndOpacity(lin(focus and ROWF or ROW)) end)
            setInk(R.name, focus and INKD or CREAM)
            setInk(R.desc, focus and INKD or PAPER)
            setInk(R.tag, focus and INKD or AMBER)
            setText(R.name, tostring(it.name or it.id))
            setText(R.tag, it.sub or "")
            setText(R.desc, it.desc or "")
            setText(R.price, "")
            local t = texOf(it.icon)
            if t then pcall(function() R.icon:SetBrushFromTexture(t, false) end) else show(R.icon, false) end
        end
        for k = 1, 3 do
            local c = it and it.colours and hexColour(it.colours[k]) or nil
            local sw = R.sw and R.sw[k]
            if sw then
                show(sw, c ~= nil)
                if c then pcall(function() sw:SetColorAndOpacity(lin(c)) end) end
            end
        end
    end
    if W.navN ~= n then
        W.navN = n
        navList(P.btns, n)
        for i = 1, n do
            navTo(P.btns[i], NAV.Left, P.side and P.side.L or nil)
            navTo(P.btns[i], NAV.Right, P.side and P.side.R or nil)
        end
    end
    setText(W.chipT, string.upper(garageClass(P)))
    if P.done then
        setText(W.foot, "GARAGE CLOSED - waiting for P1")
    elseif P.rp then
        setText(W.foot, "D-PAD choose   A replace   B / DON'T REPLACE: keep your parts")
    elseif P.mirror then
        setText(W.foot, "TEST MIRROR - no pad")
    else
        local parked = false
        pcall(function()
            local c = package.loaded["couch"]
            local id = (type(c) == "table" and type(c.parkedFor) == "function") and c.parkedFor() or nil
            parked = id ~= nil and id == padOf(P.ctrlId)
        end)
        setText(W.foot, parked and "UP / DOWN choose   LEFT / RIGHT change   DONE closes"
            or "UP / DOWN choose   LEFT / RIGHT change   B done")
    end
    local now = St.nowMs()
    setText(W.toast, (P.toast and now < (P.toastUntil or 0)) and P.toast or "")
end

local function renderList(P)
    local W = P.lv
    if not W then return end
    local p = P.ctrlId and CR().player(P.ctrlId) or nil
    setText(W.badgeT, "P" .. tostring(P.pnum or "?"))
    if P.rp then
        setText(W.title, V.REPLACE_TITLE)
        setText(W.sub, V.REPLACE_BODY .. "  New: " .. tostring(P.rp.item.name or P.rp.item.id))
    elseif S.kind == "build" then
        setText(W.title, "YOUR BUILD")
        setText(W.sub, "P1 is looking at their build")
    elseif S.kind == "mystery" then
        setText(W.title, "MYSTERY ENCOUNTER")
        setText(W.sub, "Your own deal - P1 chooses for his run")
    elseif V.shopLike(P) then
        setText(W.title, "YOUR SHOP")
        setText(W.sub, "Buy for your own build - P1 shops in his area")
    elseif S.kind == "vendor" then
        setText(W.title, P.vmode == "repair" and "REPAIR PARTS" or "SCRAP DEALER")
        setText(W.sub, P.vmode == "repair" and ((#(P.rows or {}) <= 1) and V.REPAIR_EMPTY or "Your faulty parts - your credits")
            or "Ori & Per - your own repairs")
    elseif S.kind == "garage" then
        setText(W.title, "YOUR GARAGE")
        setText(W.sub, "Your " .. garageClass(P) .. " - in every race of the run")
    else
        setText(W.title, "CHOOSE AN UPGRADE")
        local pos = p and p.lastPos and p.lastPos < 99 and string.format("You finished P%d: +%d CR", p.lastPos, p.lastPay or 0) or "Your reward for this event"
        setText(W.sub, pos)
    end
    setText(W.chipT, groupDigits(p and p.credits or 0) .. " CR")
    if S.kind == "garage" then return renderGarage(P, W) end
    local n = 0
    for i = 1, ROW_MAX do
        local R, it = W.rows[i], P.rows and P.rows[i] or nil
        local on = it ~= nil
        if on then n = i end
        for _, k in ipairs({ "bg", "icon", "name", "tag", "desc", "price" }) do show(R[k], on) end
        local b = P.btns and P.btns[i]
        if U.ok(b) then pcall(function() b:SetVisibility(on and VIS.Visible or VIS.Collapsed) end) end
        if it then
            local focus = (i == P.sel) and not P.done
            pcall(function() R.bg:SetColorAndOpacity(lin(focus and ROWF or ROW)) end)
            setInk(R.name, focus and INKD or CREAM)
            setInk(R.desc, focus and INKD or PAPER)
            setInk(R.tag, focus and INKD or AMBER)
            setInk(R.price, focus and INKD or CREAM)
            setText(R.name, tostring(it.name or it.id))
            local tag = plainLabel(it.sub)
            if not tag then
                local kindName = ({ ab = "ABILITY", part = "PART", trait = "TRAIT", crash = "CRASH ABILITY",
                                    stat = "UPGRADE", upgrade = "LEVEL CAP", pack = "PACK",
                                    restock = "NEW STOCK" })[it.rkind] or ""
                tag = (GRADE[tonumber(it.grade) or 0] and (GRADE[tonumber(it.grade)] .. " ") or "") .. kindName
            end
            setText(R.tag, tag)
            setText(R.desc, plainLabel(it.desc) or plainLabel(it.text) or plainLabel(it.blurb) or "")
            setText(R.price, it.price and string.format("%d CR", it.price) or "")
            local t = texOf(it.icon or it.iconPath)
            if t then pcall(function() R.icon:SetBrushFromTexture(t, false) end) else show(R.icon, false) end
        end
    end
    if W.navN ~= n then W.navN = n; navList(P.btns, n) end
    if P.done then
        setText(W.foot, (S.kind == "vendor" and "LEFT THE SCRAP DEALER - waiting for P1")
            or (V.shopLike(P) and "LEFT THE SHOP - waiting for P1") or "PICKED - waiting for P1")
    elseif P.mirror then
        setText(W.foot, "TEST MIRROR - no pad")
    else
        -- a PARKED pad has no PlayerInput: his B cannot be read (fix16), the LEAVE row is the way out
        local bOk = true
        pcall(function() bOk = package.loaded["couch"].parkedFor() ~= padOf(P.ctrlId) end)
        if S.kind == "vendor" then
            setText(W.foot, bOk and "D-PAD choose   A select   B back" or "D-PAD choose   A select   BACK / LEAVE row")
        else
            setText(W.foot, V.shopLike(P)
                and (bOk and "D-PAD choose   A buy   B leave" or "D-PAD choose   A buy   LEAVE row: leave") or "D-PAD choose   A claim")
        end
    end
    local now = St.nowMs()
    setText(W.toast, (P.toast and now < (P.toastUntil or 0)) and P.toast or "")
end

local function render(P)
    if P.view == "native" then renderNative(P) else renderList(P) end
end

---------------------------------------------------------------------------------------------------- native screen (P1)
local REWARD_MATCH = { "Reward" }
local SHOP_MATCH = { "Shop", "ExoticVendor", "ScrapDealer" }
-- the Scrap Dealer (ExoticVendor, the black market: its own stock at 75%, no packs, no restock) - not Hibi's shop
local function isVendor(w)
    local n = ""
    pcall(function() n = U.className(w) or "" end)
    return n:find("ExoticVendor", 1, true) ~= nil or n:find("ScrapDealer", 1, true) ~= nil
        or n:find("BlackMarket", 1, true) ~= nil
end
M._isVendor = isVendor
-- FINDING #20: the scrap dealer's screens (landing, its SHOP and REPAIR PARTS pages): one guest split for the visit
V.VENDOR_MATCH = { "ExoticVendor", "ScrapDealer", "BlackMarket" }
V.VENDOR_GONE_MS = 1500     -- P1 between two of its pages (a CSM state change): the guests' areas stay this long

-- does this scrap dealer sell? The run's own flag (the landing's Construct shows SHOP by it), else P1's landing's SHOP
-- button, else no (a guest is never given a shop the game does not have)
function M.vendorHasShop(nat)
    local v = nil
    pcall(function() v = CR().vendorHasShop() end)
    if v ~= nil then return v == true end
    if U.alive(nat) then
        local vis = nil
        pcall(function() vis = nat.WBP_Shop_Btn:GetVisibility() end)
        if type(vis) == "number" then return vis ~= VIS.Collapsed and vis ~= VIS.Hidden end
    end
    return false
end

-- his landing rows: SHOP (when the vendor sells), REPAIR PARTS, LEAVE
function M.landingRows()
    local rows = {}
    if S.vendorShop then rows[#rows + 1] = { rkind = "vshop", id = "vshop", name = "SHOP" } end
    rows[#rows + 1] = { rkind = "vrepair", id = "vrepair", name = "REPAIR PARTS" }
    rows[#rows + 1] = { rkind = "vleave", id = "vleave", name = "LEAVE" }
    return rows
end
local MYST_MATCH = { "Paddock_MysteryInteraction_C" }
M.MYST_SETTLE_MS = 600              -- #67b: the mystery screen shows the same interaction this long before it is read
-- NOTE 11: the run map screens a guest opens his own shop from (paddock / post-race map, NEXT PLANET overview)
local MAP_MATCH = { "RunMapOverview", "RunMap_Presentation", "Paddock_NextEvent" }       -- the choices screen (not its _Result / _Choice widgets)

-- the outer switcher screens rank before the inner layout (one shrink only: never the screen AND its child)
local function rank(cn) return cn:find("Rewards_Layout", 1, true) and 2 or 1 end

-- P1's activated native screen of this moment (sticky: the shrunk one wins while it is up), or nil
local function findNative(patterns)
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return nil end
    local best, bestRank = nil, 99
    for _, e in ipairs(list) do
        local k = U.key(e.w)
        if not S.own[k] then
            for _, pat in ipairs(patterns) do
                if e.cls:find(pat, 1, true) then
                    if S.nativeKey ~= 0 and k == S.nativeKey then return e.w end
                    local r = rank(e.cls)
                    if r < bestRank then best, bestRank = e.w, r end
                    break
                end
            end
        end
    end
    return best
end

-- P1's native screen of this moment: only TRACKED here (its end closes the panels). Live 2026-10-14 ("the split is
-- not a split"): shrinking this one inner activatable left the screen's frame, background, header and tooltips full
-- screen under P2's area. couchroot.lua now moves EVERY top-level game screen into P1's area while the panels are up.
local function setNative(w)
    local k = U.ok(w) and U.key(w) or 0
    if k == S.nativeKey then return end
    S.native, S.nativeKey = (k ~= 0) and w or nil, k
end

local function root() local ok, r = pcall(U.mod, "couchroot"); return (ok and type(r) == "table") and r or nil end
-- couch.lua's park follows the split at once (its own tick re-checks every 250 ms)
local function parkSync(why)
    local c = package.loaded["couch"]
    if type(c) == "table" and type(c.parkSync) == "function" then U.try(TAG, c.parkSync, why) end
end

-- gbtns / pills / on: the GARAGE hint beside the shop's (garage.lua): his D-pad moves between the two, A opens the one
-- focused (on[ctrlId] = "shop" | "garage", the highlighted pill)
local LAUNCH_REFOCUS_MS = 30   -- the guests' hint takes his pad's focus back at most this often (= every FAST tick)
local LAUNCH = { host = nil, H = nil, btns = {}, gbtns = {}, pills = {}, on = {}, prevA = {}, focusAt = {}, key = nil,
                 spots = {} }
local function launcherClose(why)
    local h = LAUNCH.host
    LAUNCH.host, LAUNCH.H, LAUNCH.btns, LAUNCH.prevA, LAUNCH.focusAt, LAUNCH.key = nil, nil, {}, {}, {}, nil
    LAUNCH.gbtns, LAUNCH.pills, LAUNCH.on, LAUNCH.spots = {}, {}, {}, {}
    LAUNCH.hidden, LAUNCH.miss, LAUNCH.only = nil, {}, nil
    if h and U.alive(h) then pcall(function() h:RemoveFromParent() end) end
    if h and why then U.dbg(TAG, "shop launcher closed (%s)", tostring(why)) end
    if h then parkSync("own-shop launcher closed") end
end
M.launcherClose = launcherClose

-- collapse / show the launcher (a pause menu or modal is over the run map); shown again = a NEW press is needed
local function launcherHide(on)
    if not (LAUNCH.host and U.alive(LAUNCH.host)) or on == (LAUNCH.hidden == true) then return end
    LAUNCH.hidden = on
    pcall(function() LAUNCH.host:SetVisibility(on and VIS.Collapsed or VIS.SelfHitTestInvisible) end)
    if not on then
        for k in pairs(LAUNCH.btns) do LAUNCH.prevA[k] = true end
    end
    U.log(TAG, "guests' SHOP / GARAGE hint %s", on and "hidden under a pause menu / dialog" or "shown again")
end
M._launcherHide = launcherHide
function M.launcherHidden() return LAUNCH.host ~= nil and LAUNCH.hidden == true end
function M.launcherUp() return LAUNCH.host ~= nil end
-- couch.lua: a new shared screen came up while the hint holds the guests' pads - their focus back at once
function M.launcherRefocusSoon() for k in pairs(LAUNCH.focusAt) do LAUNCH.focusAt[k] = -1e12 end end

---------------------------------------------------------------------------------------------------- open / close
-- a guest's reward that can no longer be shown (P1's post-race over with his offer pending, his area closed unpicked):
-- his SKIP REWARD credits are booked - a reward moment never ends with nothing for him
local function bookSkip(ctrlId, pnum, why)
    local okR, row = pcall(function() return CR().skipRow() end)
    local toast = nil
    if okR and type(row) == "table" then toast = CR().claim(ctrlId, row) end
    U.warn(TAG, "P%s's reward %s: SKIP REWARD booked (%s)", tostring(pnum), tostring(why), tostring(toast or "FAILED"))
end

local function close(why, relayout)
    -- FINDING #7: a reward area closed unpicked (phase / world / host gone) books his SKIP REWARD credits
    -- (#93: not for a re-layout - the guests still choosing get their areas back at once)
    if S.kind == "reward" and not S.debug and not relayout then
        for _, P in ipairs(S.panels) do
            if not P.done and not P.mirror and not P.gone and P.ctrlId ~= nil then
                P.done = true
                if P.flowMode then
                    U.try(TAG, function() CR().flowAbandon(P.ctrlId, "area closed (" .. tostring(why) .. ")") end)
                else
                    U.try(TAG, bookSkip, P.ctrlId, P.pnum, "area closed unpicked (" .. tostring(why) .. ")")
                end
            end
        end
    end
    if S.kind == "pshop" then
        for _, P in ipairs(S.panels) do
            if not P.done then U.log(TAG, "P%s's shop closed (%s): his purchases are kept", tostring(P.pnum), tostring(why)) end
        end
    end
    -- couch-fix21: a check-in closed before he collected it: his reward is booked anyway; a backer screen closed before
    -- he picked: his backer stays (P1's when he never had one: couchbacker.ensure)
    if (S.kind == "checkin" or S.kind == "backer") and not S.debug and not relayout then
        for _, P in ipairs(S.panels) do
            if P.backerMode and not P.done and not P.gone and P.ctrlId ~= nil then
                if S.kind == "checkin" then U.try(TAG, require("couchbackerui").autoCollect, P, why)
                else U.log(TAG, "P%s's backer screen closed unpicked (%s): his backer stays", tostring(P.pnum), tostring(why)) end
            end
        end
    end
    -- #77: a guest still shopping when the stop closed without the hold (the leave was not seen, the hold is off)
    if (S.kind == "shop" or S.kind == "vendor") and not S.debug then
        local wt = V.waiting()
        if #wt > 0 then
            U.warn(TAG, "#77 the %s closed with %s still shopping (%s; held %s): purchases kept (written at each buy)",
                S.kind == "vendor" and "scrap dealer" or "shop", table.concat(wt, ", "), tostring(why),
                S.hold and "yes" or "no")
        end
    end
    -- couch-fix39: the encounter is over: the guests' waiting team effects (couchrun.mystTeamEnd)
    if S.kind == "mystery" and not relayout then U.try(TAG, function() CR().mystTeamEnd(why) end) end
    U.try(TAG, V.disarmHold)
    if S.mapHold then U.try(TAG, V.mapRelease, "the split closed (" .. tostring(why) .. ")") end     -- fix32
    S.mapHold = nil
    S.hold, S.holdPass, V.noteT, V.noteB, V.noteShown = nil, nil, nil, nil, nil
    V.noteSl, V.noteGeo, V.noteW = nil, nil, nil
    S.guardNatKey, S.guardOuter, S.guardB, S.guardAt, S.guardScreens = nil, nil, nil, nil, nil  -- fix43: the back guard
    S.p1Left, S.mapSince, S.mapAt = nil, nil, nil                 -- #83
    local r = root()
    if r then U.try(TAG, r.finish, "panel") end
    -- 4-way garage: the guests' 3D cars go with the split
    if S.kind == "garage" then
        local ok, g = pcall(U.mod, "garage4")
        if ok and type(g) == "table" and g.campaignOn() then U.try(TAG, g.campaignClose, why) end
    end
    -- U.alive first: a world change seen by this tick before phase's "world" event left a freed host (couchsim soak,
    -- paddock -> front end with a shop open), and a pcall does not catch the access violation of a call on it
    if S.H and U.alive(S.H.host) then pcall(function() S.H.host:RemoveFromParent() end) end
    -- couch-fix63 (AUTO-153): Slate's default boundary back on P1's screen (a pooled CommonUI widget may live on)
    if S.navFence ~= nil then
        if U.alive(S.navFence) then pcall(function() S.navFence:SetAllNavigationRules(0, U.fname("None")) end) end
        S.navFence = nil
    end
    U.log(TAG, "panels closed (%s)", tostring(why))
    S.open, S.H, S.panels, S.native, S.nativeKey, S.own, S.buildTab, S.garageFree = false, nil, {}, nil, 0, {}, nil, nil
    S.vendorGoneAt = nil
    parkSync("panels closed")                 -- couch.lua: P1's PC off the park id (the split is over)
end

local function fillers(H, R, used)
    -- areas nobody uses (3 players: bottom-right) get the paper; dividers between the areas
    for i = 1, 3 do
        if R[i] and not used[i] then
            pcall(function()
                local box, sb = regionBox(H, R[i], VW, VH)
                local ov = mk(OVER, H.tree)
                sb:AddChild(ov)
                paperBackdrop(H, H.tree, ov, U.p1())
            end)
        end
    end
    -- dividers: quadrants only get the vertical one (live 2026-10-14: in 2-player strips the old 1916 rule ran through
    -- the middle of P2's area); every split gets the horizontal line between the top and bottom areas
    pcall(function()
        if S.n >= 3 then local v = solid(H.tree, AMBER); place(H.cv, v, 1916, 0, 8, VH, 30) end
        local h = solid(H.tree, AMBER); place(H.cv, h, 0, 1076, VW, 8, 30)
    end)
end

-- The guest shops come only once P1's own paddock shop is fully built: its layout (WBP_Paddock_Shop_Presentation ->
-- Construct -> Layout:Init) holds its ShopVM. Nothing of the guest's copy is made while the native shop is still being
-- constructed (the scan that sees it activated may run inside that frame). A vendor screen without that layout (the
-- mystery ExoticVendor / ScrapDealer) opens at once. P1's layout without a VM after SHOP_WAIT_MS: the list panel.
-- -> ready, listOnly
local function shopReady(shop, now)
    if not U.ok(shop) then return false, false end
    local n = ""
    n = U.className(shop)                        -- U.ok on the object AND its class (FINDING #31)
    if not n:find("Paddock_Shop", 1, true) and not n:find("Shop_MainSelectionPanel", 1, true) then return true, false end
    S.shopSeenAt = S.shopSeenAt or now
    local keys = p1ShopKeys(shop)
    if keys.shop ~= 0 then
        if S.shopWaitLogged then
            U.log(TAG, "P1's shop layout has its view model after %d ms (%s): the guests get the native shop",
                math.floor(now - S.shopSeenAt), tostring(keys.via))
        end
        return true, false
    end
    if now - S.shopSeenAt < SHOP_WAIT_MS then
        if not S.shopWaitLogged then
            S.shopWaitLogged = true
            U.log(TAG, "shop up: waiting for P1's shop layout to get its view model (at most %d ms)", SHOP_WAIT_MS)
        end
        return false, false
    end
    U.warn(TAG, "P1's shop layout has no view model %d ms after the shop opened (outer screen %s): the guests get the "
        .. "list shop", SHOP_WAIT_MS, V.p1ShopOuter(shop) and "found" or "NOT found")
    return true, true
end

-- FIX 5 (live 2026-10-14/15, ~2 reward moments in 3: "rewards VM has no items" -> the list look): the reward split
-- opened on the FIRST "Reward" screen (the hub / CREDITS BREAKDOWN), before the game had built the reward round, so
-- BuildRewardsVMForCurrentCampaignEvent returned a VM with no items. The round exists once P1's own CHOOSE AN UPGRADE
-- layout has items: wait for that (the guests' offers stay pending meanwhile). P1's layout up with an empty round for
-- REWARD_WAIT_MS, or no layout for REWARD_NOLAYOUT_MS (a reward moment without an upgrade round) = open anyway (the
-- native build still tries, the list panel is its fallback).
-- FINDING #7 (live 2026-10-17, 17:48:46: "reward screen up: the guests' areas wait for P1's reward round (no CHOOSE AN
-- UPGRADE layout yet)" x3, P2's area never opened): that reward flow had NO upgrade round (act finish: hub -> credits
-- -> ... -> map; P1's credits unchanged, no CHOOSE AN UPGRADE layout ever activated). Two faults made it silent:
--   * the wait clock was reset whenever the matched "Reward" screen blinked out between two stages (hub -> credits),
--     so the 45 s no-layout limit never ran out - and the whole flow lasted ~30 s anyway;
--   * when the flow ended (the run map) the guests' offers stayed pending: no area, and the next race overwrote them.
-- Now: the holder's own RewardsCollectionVM stages say whether an upgrade round will come (no stage of type 2..5 = none:
-- the guest areas open at once with the closest kind, couchrun.makeOffer); the wait clock runs for the whole flow; the
-- flow ending with offers still pending opens the areas on the run map; an area closed unpicked (phase / world) books
-- his SKIP REWARD credits.
local REWARD_WAIT_MS = 3000
local REWARD_NOLAYOUT_MS = 45000
local REWARD_FLOW_END_MS = 1500     -- every reward screen gone this long with the run map up = the flow ended
local REWARD_FLOW_LOST_MS = 6000    -- ... or this long without a map
local HOLDER_CLS = "WBP_PostRace_Cam_Holder_Presentation_C"

-- P1's reward flow stages, read from the post-race holder's RewardsCollectionVM (the hub's own data):
-- -> { types = {..}, upgrade = first upgrade stage's offer kind or nil } or nil when unreadable
local function p1FlowStages()
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return nil end
    for _, e in ipairs(list) do
        if e.cls == HOLDER_CLS and not S.own[U.key(e.w)] and U.alive(e.w) then
            local out = nil
            pcall(function()
                local rc = e.w.RewardsCollectionVM
                if not U.ok(rc) then return end
                local st = U.arrayToTable(rc.CollectionStages)
                if #st == 0 then return end
                out = { types = {} }
                local SK = CR().STAGE_KIND or {}
                for _, s in ipairs(st) do
                    local t = nil
                    pcall(function() t = tonumber(s.CollectionType) end)
                    out.types[#out.types + 1] = t or -1
                    if t and SK[t] and not out.upgrade then out.upgrade = SK[t] end
                end
            end)
            return out
        end
    end
    return nil
end
M._p1FlowStages = p1FlowStages

local function rewardReset()
    S.rewardSeenAt, S.rewardLayAt, S.rewardWaitLogged, S.rewardGoneAt, S.rewardStageKind = nil, nil, nil, nil, nil
    S.rewardNoRound = nil
end

-- P1's post-race left while a guest's offer was still pending after a reward screen was seen
local function rewardLeft(why)
    rewardReset()
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    for _, g in ipairs(list) do
        local p = CR().player(g.ctrlId)
        if p and p.offerPending then
            p.offerPending = nil
            local okF, f = pcall(function() return CR().flow(g.ctrlId) end)
            if okF and f then
                U.try(TAG, function() CR().flowAbandon(g.ctrlId, "never got an area (" .. tostring(why) .. ")") end)
            else
                bookSkip(g.ctrlId, g.pnum, "never got an area (" .. tostring(why) .. ")")
            end
        end
    end
end

local function rewardReady(now)
    if opt("CouchPanelNative", true) == false then return true end
    local found, n = p1RoundItems()
    if found and n > 0 then return true end
    S.rewardSeenAt = S.rewardSeenAt or now
    if found then S.rewardLayAt = S.rewardLayAt or now end
    -- the flow's own stages: no upgrade stage = no CHOOSE AN UPGRADE round will come - open now (closest kind)
    local stages = (not found) and p1FlowStages() or nil
    if stages and not stages.upgrade then
        S.rewardNoRound = true
        U.log(TAG, "reward screen up: P1's reward flow has no CHOOSE AN UPGRADE round (stage types %s): the guests' "
            .. "areas open now with the closest kind", table.concat(stages.types, ","))
        return true
    end
    if stages and stages.upgrade then S.rewardStageKind = stages.upgrade end
    local waited = found and (now - S.rewardLayAt) or (now - S.rewardSeenAt)
    local limit = found and REWARD_WAIT_MS or REWARD_NOLAYOUT_MS
    if waited < limit then
        if not S.rewardWaitLogged then
            S.rewardWaitLogged = true
            U.log(TAG, "reward screen up: the guests' areas wait for P1's reward round (%s)",
                found and "his layout has no items yet" or "no CHOOSE AN UPGRADE layout yet")
        end
        return false
    end
    U.warn(TAG, "P1's reward round still empty after %d ms (%s): the guest areas open now", waited,
        found and "layout up, no items" or "no layout")
    return true
end

-- list: { {ctrlId, pnum, pc, rows, lo, mirror} } in join order; listOnly = no native guest view (the list panels)
local function open(kind, native, list, listOnly)
    if #list == 0 then return end
    launcherClose(kind .. " split")
    local okH, H = pcall(buildHost)
    if not okH then U.warn(TAG, "host build failed: %s", tostring(H)); return end
    S.open, S.kind, S.H, S.panels, S.own = true, kind, H, {}, {}
    S.p1Left, S.mapSince, S.mapAt = nil, nil, nil                 -- #83
    S.buildTab = (kind == "build") and "build" or nil
    S.n = math.min(4, 1 + #list)
    -- read by their builders (couch-fix43: the shop copy reads P1's VMs through his outer shop screen)
    if kind == "mystery" or kind == "backer" or kind == "checkin" or kind == "shop" or kind == "pshop" then setNative(native) end
    own(H.host)
    local R = regionsFor(S.n)
    local used = {}
    for i, g in ipairs(list) do
        if i > 3 then break end
        local rows = g.rows or {}
        local P = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, lo = g.lo, rows = rows, sel = 1,
                    done = #rows == 0 and not g.flow, slot = i, region = R[i], mirror = g.mirror, prev = { a = true, b = true },
                    paintAt = {}, view = "list", arch = g.arch, vmode = (kind == "vendor") and "landing" or nil }
        used[i] = true
        local native = (kind == "reward" and opt("CouchPanelNative", true) ~= false)
            or ((kind == "shop" or kind == "pshop") and opt("CouchShopNative", true) ~= false and not listOnly)
            or kind == "build"
            or kind == "mystery"
            or kind == "vendor"
            or kind == "backer" or kind == "checkin"
        if native and (#rows > 0 or kind == "build" or g.flow) then
            local fn = ((kind == "shop" or kind == "pshop") and buildNativeShop) or (kind == "build" and buildNativeBuild)
                or (kind == "mystery" and buildNativeMystery) or (kind == "vendor" and V.buildVendorLanding)
                or ((kind == "backer" or kind == "checkin") and require("couchbackerui").build)
                or (g.flow and require("couchflow").build) or buildNative
            local okN, err = pcall(fn, H, P)
            if okN then
                P.view = "native"
            elseif kind == "backer" or kind == "checkin" then
                -- couch-fix21: no backer area for him (no offer / no backer readable): his area stays empty, never a
                -- reward list (its A would claim a reward)
                U.warn(TAG, "P%s's backer %s area failed (%s): none for him this time", tostring(P.pnum), kind, tostring(err))
                if U.ok(P.box) then pcall(function() P.box:RemoveFromParent() end) end
                P.box, P.nv, P.rows, P.done, P.broken, P.backerMode = nil, nil, {}, true, true, nil
            elseif g.flow then
                -- couch-rewards2: his flow could not start: the mirror offer in the list instead (logged)
                U.warn(TAG, "P%s's own reward flow failed (%s): the mirror offer in a list instead", tostring(P.pnum),
                    tostring(err))
                if U.ok(P.box) then pcall(function() P.box:RemoveFromParent() end) end
                P.flowMode = nil
                local okO, o = pcall(function() return CR().makeOffer(P.ctrlId, nil, true) end)
                P.box, P.nv, P.rows = nil, nil, (okO and type(o) == "table") and o or {}
                P.done = #P.rows == 0
            else
                U.warn(TAG, "P%s native %s view failed (%s): list panel instead", tostring(P.pnum), kind, tostring(err))
                if U.ok(P.box) then pcall(function() P.box:RemoveFromParent() end) end
                P.box, P.nv, P.rows = nil, nil, rows
            end
        end
        if P.view == "list" and (kind == "shop" or kind == "pshop") and not S.vendor and P.ctrlId ~= nil then
            local okK, pk = pcall(function() return CR().pendingPack(P.ctrlId) end)
            if okK and pk then U.try(TAG, packOpen, P, pk.rows, "his paid pack, still unopened") end
        end
        if P.view == "list" and not P.broken then
            local okL, errL = pcall(buildList, H, P)
            if not okL then U.warn(TAG, "P%s list panel failed: %s", tostring(P.pnum), tostring(errL)); P.broken = true end
        end
        S.panels[#S.panels + 1] = P
    end
    fillers(H, R, used)
    setNative(native)
    -- couch-fix63 (AUTO-153): P1's backer contracts sit side by side in his shrunk screen; a D-pad move with nothing of
    -- his that way (DOWN) let Slate's geometric search leave his screen and his A found no contract. While the split is
    -- open his screen is a Stop navigation boundary (as couch-fix47's CouchPreRunNavBoundary), Escape again at the close.
    if kind == "backer" and opt("CouchBackerNavBoundary", true) ~= false and U.alive(native) then
        S.navFence = pcall(function() native:SetAllNavigationRules(3, U.fname("None")) end) and native or nil
        if S.navFence then U.log(TAG, "backer split: P1's screen %s is a navigation boundary (AUTO-153)", U.className(native)) end
    end
    if kind == "shop" or kind == "vendor" then U.try(TAG, V.armHold) end         -- #77: P1's leave waits for the guests
    local rt = root()
    if rt then U.try(TAG, rt.begin, "panel", S.n) end
    parkSync(kind .. " panels open")          -- couch.lua: the screen owner's pad reaches only his own area now
    for _, P in ipairs(S.panels) do if not P.broken then render(P) end end
    local views = {}
    for _, P in ipairs(S.panels) do views[#views + 1] = string.format("P%s %s %d row(s)", tostring(P.pnum), P.view, #P.rows) end
    U.log(TAG, "%s panels open for %d player(s): %s; native %s shrunk into P1's area", kind, S.n,
        table.concat(views, ", "), U.ok(S.native) and U.className(S.native) or "-")
    -- couch-fix46 (AUTO-120): the copies' own footers lose the engine's "[P1]" tags now, not at the next 5 s scan
    pcall(function() U.mod("couch").tagsSoon() end)
    if kind == "backer" then V.backerFocusSoon(native) end
end

-- couch-fix69 (AUTO-164): P1's first backer card framed when the split opens (menubridge.sponsorFocusFirst: only while
-- no card of his holds his pad's focus), again at +0.3 / +1 / +2.5 s (couchroot's move of his screen into his area and
-- the swap's own refocuses come in those first seconds). cfg.CouchBackerFocusFirst = false: off.
function V.backerFocusSoon(native)
    if opt("CouchBackerFocusFirst", true) == false or not U.alive(native) then return end
    local MB = package.loaded["menubridge"]
    if not (type(MB) == "table" and type(MB.sponsorFocusFirst) == "function") then return end
    local nk, gen = U.key(native), St.worldGen
    local function step(why)
        if not S.open or S.kind ~= "backer" or St.worldGen ~= gen or not U.ok(S.native) or U.key(S.native) ~= nk then
            return
        end
        U.try(TAG, MB.sponsorFocusFirst, S.native, why)
    end
    step("split open")
    local sched = package.loaded["sched"]
    if not (type(sched) == "table" and type(sched.after) == "function") then return end
    for _, ms in ipairs({ 300, 1000, 2500 }) do
        sched.after("cp.backerfocus" .. ms, ms, function() step("+" .. ms .. " ms") end)
    end
end

-- garage.lua: one step of the focused row (LEFT / RIGHT, A = the next option), RESET, DONE
local function garageAct(P, dir)
    local it = P.rows and P.rows[P.sel]
    if not it then return end
    local G = U.mod("garage")
    if it.rkind == "done" then
        if dir == 0 then P.done = true; P.toast, P.toastUntil = "SAVED", St.nowMs() + 2500 end
    elseif it.rkind == "reset" then
        if dir == 0 then
            G.reset(P.pnum, P.arch)
            P.toast, P.toastUntil = "THE DEFAULT CAR", St.nowMs() + 2500
        end
    elseif it.rkind == "cycle" then
        local o, i, n = G.cycle(P.pnum, P.arch, it.key, (dir == 0) and 1 or dir)
        if o and n <= 1 then P.toast, P.toastUntil = "NOTHING ELSE UNLOCKED", St.nowMs() + 2000 end
    end
    P.rows = G.rows(P.pnum, P.arch)
    P.sel = math.max(1, math.min(P.sel, #P.rows))
    render(P)
end
M._garageAct = garageAct                       -- couchsim / tests: a guest's step on his focused row

-- FINDING #20: his area moves to another page of the scrap dealer (landing / repair / shop): the old page's widgets go
-- (his region box, the strip paper; the game chip stays), the new page is built in the same region, his pad's focus
-- follows. A native build error = the list panel with the same rows.
function V.vendorSwitch(P, mode)
    local H = S.H
    if not (H and U.alive(H.host)) then return end
    if U.ok(P.box) then pcall(function() P.box:RemoveFromParent() end) end
    if U.ok(P.stripPaper) then pcall(function() P.stripPaper:RemoveFromParent() end) end
    if P.lv and U.ok(P.lv.full) then pcall(function() P.lv.full:RemoveFromParent() end) end
    P.box, P.stripPaper, P.nv, P.lv, P.btns, P.pick = nil, nil, nil, nil, {}, nil
    P.vmode, P.sel, P.paintAt = mode, 1, {}
    local rows
    if mode == "repair" then
        rows = CR().repairRows(P.ctrlId) or {}
        rows[#rows + 1] = { rkind = "vback", id = "vback", name = "BACK" }
    elseif mode == "shop" then
        rows = {}
        for _, r in ipairs(CR().vendorStock(P.ctrlId) or {}) do
            -- the vendor's shop page has no leave of its own: B / this row goes back to the landing
            rows[#rows + 1] = (r.rkind == "leave") and { rkind = "leave", id = "leave", name = "BACK", sub = "" } or r
        end
    else
        rows = M.landingRows()
    end
    P.rows = rows
    P.view = "list"
    -- #73: the dealer's own shop screen (was buildNativeShop = HIBI'S SHOP's layout)
    local fn = (mode == "repair" and V.buildVendorRepair) or (mode == "shop" and V.buildVendorShop) or V.buildVendorLanding
    if not (mode == "shop" and opt("CouchShopNative", true) == false) then
        local okN, err = pcall(fn, H, P)
        if okN then
            P.view = "native"
        else
            U.warn(TAG, "P%s native scrap dealer %s view failed (%s): list panel instead", tostring(P.pnum), mode, tostring(err))
            if U.ok(P.box) then pcall(function() P.box:RemoveFromParent() end) end
            if U.ok(P.stripPaper) then pcall(function() P.stripPaper:RemoveFromParent() end) end
            P.box, P.stripPaper, P.nv = nil, nil, nil
            P.rows = rows
        end
    end
    -- the game chip of the landing / repair pages: the shop page has its own (its header's)
    if P.vchip then
        -- couch-fix63 (AUTO-154d): the repair page has its own header chip too (when it was found and rewired)
        local own = P.view == "native" and (mode == "shop" or (mode == "repair" and P.nv and P.nv.headerChip == true))
        for _, w in ipairs(P.vchip.parts or {}) do
            pcall(function() w:SetVisibility(own and VIS.Collapsed or VIS.HitTestInvisible) end)
        end
    end
    if P.view == "list" then
        local okL, errL = pcall(buildList, H, P)
        if not okL then U.warn(TAG, "P%s list panel failed: %s", tostring(P.pnum), tostring(errL)); P.broken = true; return end
    end
    P.refocus = true
    P.prev.a, P.prev.b = true, true                 -- the press that switched is not the new page's first A / B
    U.log(TAG, "P%s at the scrap dealer: %s page (%d row(s), %s view)", tostring(P.pnum), mode, #P.rows, P.view)
    render(P)
end
M._vendorSwitch = V.vendorSwitch
M._vendorLayout = { headerTop = function(fh) return V.headerTop(fh) end, stackLines = function(...) return V.stackLines(...) end,
    frameOf = function(r) return frameOfRegion(r) end }

-- his A on a landing / repair row (the shop page is the shop's act)
function V.vendorAct(P, it)
    local now = St.nowMs()
    if it.rkind == "vleave" then P.done = true; render(P); return end
    if it.rkind == "vback" then V.vendorSwitch(P, "landing"); return end
    if it.rkind == "vrepair" then V.vendorSwitch(P, "repair"); return end
    if it.rkind == "vshop" then V.vendorSwitch(P, "shop"); return end
    if it.rkind ~= "repair" then return end
    local nv = P.nv
    local scr = nv and nv.vendor == "repair" and nv.lay or nil
    local w = nv and nv.cards and nv.cards[P.sel] or nil
    local ok, toast = CR().repair(P.ctrlId, it.id, nv and nv.cost)
    P.toast, P.toastUntil = toast, now + 2500
    if ok then
        -- the game's own success path on HIS copy: the part Fixed (listed as Repaired), the fault text hidden, his
        -- credits / cost tint refreshed, the entry's success feedback
        it.status = V.AFFIX_FIXED
        if U.ok(it.vm) then
            pcall(function() it.vm.AffixStatus = V.AFFIX_FIXED end)
            pcall(function() it.vm.FaultyPassiveFlavourTexts:Empty() end)
        end
        local p = CR().player(P.ctrlId)
        if nv and U.ok(nv.bm) then pcall(function() nv.bm.CurrentPlayerCredits = p and p.credits or 0 end) end
        if U.alive(w) then
            pcall(function() w:OnActionSuccess() end)
            if U.ok(it.vm) then pcall(function() w:PopulateFromVM(it.vm) end) end
            -- couch-fix63 (AUTO-154d, shot scrap-repaired: the part's icon an empty grey square): PopulateFromVM reads
            -- the icon from the VM's affix config (not resolved on his fresh AppliedAffixVM): his part's own icon again
            local d = PD and PD.PARTS and PD.PARTS[it.id]
            if d then pcall(function() brush(w.WBP_Build_Affix_Presentation.Img_AffixIcon, d.icon) end) end
        end
        P.paintAt = { now + 40, now + 300 }                 -- and repainted once its animation settled
        if U.alive(scr) then pcall(function() scr.WBP_FaultyAffixRepair:HideFaultyDescription() end) end
        V.repairDetail(P)
        local pp = CR().player(P.ctrlId)
        if pp and pp.lo then P.lo = pp.lo end
    elseif U.alive(scr) then
        U.playAnim(scr, "Anim_RepairFailed")
        if U.alive(w) then pcall(function() w:OnActionFailed() end) end
    end
    render(P)
end

---------------------------------------------------------------------------------------------------- part slots full
-- FINDING #95 (Jules's 1:1 rule; couchrun "part slots full" has the decoded solo flow): a part he buys (Hibi's shop,
-- the scrap dealer), takes from a pack or picks as a reward with every part slot full opens the game's choice in HIS
-- area - "PART SLOTS FULL" / "Your Part slots are full. Would you like to replace one?", the new part named, one row
-- per installed part (a FAULTY one refused: it cannot be replaced until repaired), DON'T REPLACE (the game's Cancel:
-- nothing bought / picked). The page he was on is hidden (kept) and comes back as it was; his pick re-runs his A on
-- the same card with item.replace = the part it replaces (couchrun.applyClaim: the new part in that slot, the old
-- one owned). B = DON'T REPLACE. The look: the scrap dealer landing's pieces (WBP_Modal_Btn rows on his paper frame),
-- the list panel when they cannot be built.
V.REPLACE_TITLE = "PART SLOTS FULL"
V.REPLACE_BODY = "Your Part slots are full. Would you like to replace one?"
function V.buildReplace(H, P)
    local gpc, ov = V.vendorFrame(H, P)
    local cv = mk(CANVAS, H.tree)
    if not cv then error("no Canvas") end
    overlayAdd(ov, cv, 0, 0)
    P.nv = { vendor = "replace", lay = cv, items = {}, nCards = #P.rows, hasSkip = false, cards = {}, animated = {},
             affixes = {} }
    local function line(s, size, y, font_)
        local t = text(H.tree, size, INKD, font_)
        setText(t, s)
        local sl = place(cv, t, VW / 2, y, nil, nil, 5)
        pcall(function() sl:SetAlignment({ X = 0.5, Y = 0 }) end)
        return t
    end
    local it = P.rp and P.rp.item or {}
    local _, _, _, fh = frameOfRegion(P.region)
    local ys, yEnd = V.stackLines(fh, 250, { { 130 }, { 60, true }, { 64 } })   -- couch-fix46: no line over another
    P.nv.lineYs = ys
    line(V.REPLACE_TITLE, 130, ys[1])
    line(V.REPLACE_BODY, 60, ys[2], FONT_BODY)
    line("NEW PART: " .. tostring(it.name or it.id or "?"), 64, ys[3])
    local rowY = math.max(760, yEnd + 40)
    local step = 165
    if #P.rows > 0 and rowY + (#P.rows - 1) * step + 140 > VH - 260 then          -- many rows at 4P: tighter
        step = math.max(145, math.floor((VH - 260 - 140 - rowY) / math.max(1, #P.rows - 1)))
    end
    P.nv.rowY, P.nv.rowStep = rowY, step
    local made = 0
    for i, r in ipairs(P.rows) do
        local label = r.rkind == "vreplace" and (r.name .. (r.faulty and "  (FAULTY)" or "")) or r.name
        local b = V.modalButton(gpc, label)
        if b then
            made = made + 1
            pcall(function() b:BP_SetIsFocusable(false) end)
            local okP = pcall(place, cv, b, (VW - 1400) / 2, rowY + (i - 1) * step, 1400, 140, 6)
            if not okP then error("replace row not placed") end
            if r.faulty then pcall(function() b:SetRenderOpacity(0.45) end) end      -- the game's faulty disabled look
            P.nv.cards[i] = b
        end
    end
    if made == 0 then error("no WBP_Modal_Btn") end
    V.vendorMarks(H, P, ov)
end

-- does his A on this row need the choice first? (couchrun.mustReplace; a stub without it: never)
function V.mustReplace(P, it)
    local cr = CR()
    if type(cr) ~= "table" or type(cr.mustReplace) ~= "function" or P.ctrlId == nil then return false end
    local ok, v = pcall(cr.mustReplace, P.ctrlId, it)
    return ok and v == true
end

-- -> true when his choice is open
function V.replaceOpen(P, it, how)
    local H = S.H
    if P.rp or not (H and U.alive(H.host)) then return false end
    local rows = CR().replaceRows(P.ctrlId)
    local back = { rows = P.rows, sel = P.sel, btns = P.btns, nv = P.nv, lv = P.lv, box = P.box, strip = P.stripPaper,
                   view = P.view, side = P.side, vis = {} }
    for k, w in pairs({ box = P.box, strip = P.stripPaper, full = P.lv and P.lv.full }) do
        if U.ok(w) then
            local v = nil
            pcall(function() v = w:GetVisibility() end)
            back.vis[k] = v
            pcall(function() w:SetVisibility(VIS.Collapsed) end)
        end
    end
    P.rp = { item = it, how = how, back = back }
    P.box, P.stripPaper, P.nv, P.lv, P.btns, P.side = nil, nil, nil, nil, {}, nil
    P.rows, P.sel, P.paintAt = rows, 1, {}
    P.view = "list"
    if opt("CouchReplaceNative", true) ~= false then
        local okN, err = pcall(V.buildReplace, H, P)
        if okN then
            P.view = "native"
        else
            U.warn(TAG, "P%s PART SLOTS FULL native view failed (%s): list panel instead", tostring(P.pnum),
                tostring(err))
            for _, w in ipairs({ P.box, P.stripPaper }) do
                if U.ok(w) then pcall(function() w:RemoveFromParent() end) end
            end
            P.box, P.stripPaper, P.nv, P.btns = nil, nil, nil, {}
        end
    end
    if P.view == "list" then
        local okL, errL = pcall(buildList, H, P)
        if not okL then
            U.warn(TAG, "P%s PART SLOTS FULL list failed: %s", tostring(P.pnum), tostring(errL))
            V.replaceClose(P)
            return false
        end
    end
    local nf = 0
    for _, r in ipairs(rows) do if r.faulty then nf = nf + 1 end end
    P.refocus = true
    P.prev.a, P.prev.b = true, true
    U.log(TAG, "P%s: PART SLOTS FULL for %s (%s): %d installed part(s) to replace (%d faulty) + DON'T REPLACE, %s view",
        tostring(P.pnum), tostring(it.name or it.id), tostring(how), #rows - 1, nf, P.view)
    render(P)
    return true
end

function V.replaceClose(P)
    local rp = P.rp
    if not rp then return end
    for _, w in ipairs({ P.box, P.stripPaper, P.lv and P.lv.full }) do
        if U.ok(w) then pcall(function() w:RemoveFromParent() end) end
    end
    local b = rp.back
    P.rows, P.sel, P.btns, P.nv, P.lv, P.box, P.stripPaper, P.view, P.side =
        b.rows, b.sel, b.btns, b.nv, b.lv, b.box, b.strip, b.view, b.side
    for k, w in pairs({ box = P.box, strip = P.stripPaper, full = P.lv and P.lv.full }) do
        if U.ok(w) then
            local v = b.vis[k]
            pcall(function() w:SetVisibility(v ~= nil and v or VIS.SelfHitTestInvisible) end)
        end
    end
    P.rp = nil
    -- couch-fix64 (AUTO-158a, shots hibi-p2-replaced / hibi-p2-packopen: the choice's credits chip (6,000) stayed drawn
    -- over Hibi's shop's own chip for the rest of the visit): the chip lives on the host canvas, not in the choice's
    -- box. Only the scrap dealer's pages use it; anywhere else it goes with the choice (shown again by the next one)
    if P.vchip and S.kind ~= "vendor" then
        for _, w in ipairs(P.vchip.parts or {}) do pcall(function() w:SetVisibility(VIS.Collapsed) end) end
    end
    if P.nv then P.nv.focusShown = nil end
    local now = St.nowMs()
    P.paintAt = { now + 40, now + 300 }
    P.refocus = true
    P.prev.a, P.prev.b = true, true
end

-- his A (or B = "vkeep") on the choice
function V.replaceAct(P, it)
    local rp = P.rp
    if not (rp and it) then return end
    if it.rkind == "vkeep" then
        V.replaceClose(P)
        P.toast = (rp.how == "claim") and "NOT PICKED - YOUR PARTS KEPT" or "NOT BOUGHT - YOUR PARTS KEPT"
        P.toastUntil = St.nowMs() + 2500
        U.log(TAG, "P%s: PART SLOTS FULL declined: %s not %s", tostring(P.pnum), tostring(rp.item.name or rp.item.id),
            rp.how == "claim" and "picked" or "bought")
        render(P)
        return
    end
    if it.rkind ~= "vreplace" then return end
    if it.faulty then
        P.toast, P.toastUntil = "FAULTY PARTS CANNOT BE REPLACED UNTIL REPAIRED", St.nowMs() + 2500
        render(P)
        return
    end
    local item = rp.item
    V.replaceClose(P)
    item.replace = it.id
    U.try(TAG, M._act, P)                                -- his A on the same card again, with the part to replace
    item.replace = nil
end

-- couch-fix54 (AUTO-132, live round 3 15:18:57, MYST_101_Antagonist_HighRiskEvents_Act2): P2's three rows were all
-- greyed (choices 1-2 = a bookend deal #112: the League Token payout runs on P1's run only; choice 3 = 6,000 CR, he had
-- 3,650) and the encounter has no pass choice: no row of his could be taken, his A / B did nothing and his greyed area
-- stayed on his half through P1's result and onto the run map (closed only at the next node pick). The greying is
-- solo parity (a bookend deal is not tracked per guest; an unaffordable choice is not takeable). Now a guest with NO
-- takeable row always has a way out: the area says P1's choice applies to the team, his A or B = he passes (no deal,
-- nothing applied), and once P1 has made his pick (or P1's mystery screen is gone) he passes by himself - his area no
-- longer waits for a pick he cannot make (the split closes with P1's screen).
V.MYST_TEAM_NOTE = "P1'S CHOICE APPLIES TO THE TEAM"
function V.mysteryNoChoice(P)
    if S.kind ~= "mystery" or not P or P.done or P.mirror or P.ctrlId == nil then return false end
    if type(P.rows) ~= "table" or #P.rows == 0 then return false end
    for _, r in ipairs(P.rows) do
        local ok = CR().mysteryValid(P.ctrlId, r)
        if ok then return false end
    end
    return true
end
function V.mysteryPass(P, why)
    if P.done then return end
    P.done, P.passed = true, true
    P.toast, P.toastUntil = nil, nil
    P.paintAt = { St.nowMs() + 40 }                              -- the entries stay disabled (no choice made)
    U.log(TAG, "P%s mystery: no takeable choice (every row greyed for him): he passes (%s) - %s (AUTO-132)",
        tostring(P.pnum), tostring(why), V.MYST_TEAM_NOTE)
    render(P)
end
-- the tick: a no-choice guest passes once P1's pick is in (or P1's mystery screen has gone)
function V.mysteryNoChoiceTick(now)
    if S.kind ~= "mystery" or now - (S.noChoiceAt or 0) < 300 then return end
    S.noChoiceAt = now
    local any = false
    for _, P in ipairs(S.panels) do if V.mysteryNoChoice(P) then any = true; break end end
    if not any then return end
    local why = (not S.native) and "P1's mystery screen closed" or nil
    if not why then
        local ok, picked = pcall(CR().mystP1Picked, S.mystName)
        if ok and picked == true then why = "P1's choice made" end
    end
    if not why then return end
    for _, P in ipairs(S.panels) do if V.mysteryNoChoice(P) then V.mysteryPass(P, why) end end
end

local function act(P)
    if P.ownClosed then return end                          -- #83: his area is closed
    local it = P.rows and P.rows[P.sel]
    if not it then return end
    if P.rp then V.replaceAct(P, it); return end          -- #95: his PART SLOTS FULL choice
    -- couch-rewards2: his own reward flow's hub / credits / faults views (couchflow.lua)
    -- couch-fix21 (#90): his own backer contract / check-in (couchbackerui.lua)
    if P.backerMode then
        U.try(TAG, require("couchbackerui").act, P)
        render(P)
        return
    end
    if P.flowMode and P.flowBackAt then return end          -- his pick is in: the hub comes back (no 2nd pick)
    if P.flowMode and P.flowView ~= "round" then
        U.try(TAG, require("couchflow").act, P)
        if P.closeOwn then M.closeOwn(P, "his CONTINUE on his finished hub"); return end
        render(P)
        return
    end
    if S.kind == "garage" then garageAct(P, 0); return end
    if S.kind == "vendor" and P.vmode ~= "shop" then V.vendorAct(P, it); return end
    if S.kind == "vendor" and it.rkind == "leave" then V.vendorSwitch(P, "landing"); return end
    if S.kind == "mystery" then
        if V.mysteryNoChoice(P) then V.mysteryPass(P, "his A"); return end     -- couch-fix54 (AUTO-132)
        local okV, why = CR().mysteryValid(P.ctrlId, it)
        if not okV then
            P.toast, P.toastUntil = why, St.nowMs() + 2500
            render(P)
            return
        end
        local okM, toast = CR().mysteryChoose(P.ctrlId, it)
        P.toast, P.toastUntil = toast, St.nowMs() + 4000
        if okM then
            P.done = true
            P.paintAt = { St.nowMs() + 40 }                            -- the entries go disabled (his choice made)
        end
        render(P)
        return
    end
    if V.shopLike(P) and it.rkind == "leave" then P.done = true; render(P); return end
    -- couch-shopstock: his PACK's choice open on the shelf: A takes the focused one, the rest of the shop waits
    if V.shopLike(P) and P.pick then
        if it.packPick then
            if V.mustReplace(P, it) and V.replaceOpen(P, it, "pack") then return end      -- #95
            local ok, toast = CR().packPick(P.ctrlId, it)
            P.toast, P.toastUntil = toast, St.nowMs() + 3000
            if ok then
                local w = target(P, P.sel)
                if w and P.view == "native" then pcall(function() w:ActionSucceeded() end) end
                local pp = CR().player(P.ctrlId)
                if pp and pp.lo then P.lo = pp.lo end                -- his build after the pick (bars, icons)
                U.try(TAG, packClose, P)
                if P.view == "native" then refreshShopBuild(P, it); reapplyBuild(P) end
            end
        else
            P.toast, P.toastUntil = "CHOOSE FROM YOUR PACK FIRST", St.nowMs() + 2000
        end
        render(P)
        return
    end
    if V.shopLike(P) and it.rkind == "restock" then
        local ok, toast, rows = CR().restock(P.ctrlId)
        P.toast, P.toastUntil = toast, St.nowMs() + 2500
        if ok and type(rows) == "table" then U.try(TAG, restockNative, P, rows) end
        render(P)
        return
    end
    if V.shopLike(P) and it.rkind == "pack" then
        local ok, toast, choices = CR().buyPack(P.ctrlId, it.id)
        P.toast, P.toastUntil = toast, St.nowMs() + 3000
        if ok and type(choices) == "table" then
            local w = target(P, P.sel)
            if w and P.view == "native" then U.playAnim(w, "Anim_Select") end
            U.try(TAG, shopControls, P)                               -- the next pack's price on the button
            U.try(TAG, packOpen, P, choices, "bought")
        end
        render(P)
        return
    end
    if V.shopLike(P) then
        if it.rkind == "empty" then return end
        if it.bought then P.toast, P.toastUntil = "PURCHASED", St.nowMs() + 2000; render(P); return end
        if V.mustReplace(P, it) and not CR().pendingPack(P.ctrlId) then
            -- #95: the game asks only when the card can be bought (CanPurchase AND PlayerMustPickReplacement)
            local pp = CR().player(P.ctrlId)
            if pp and (pp.credits or 0) >= (tonumber(it.price) or 0) and V.replaceOpen(P, it, "buy") then return end
        end
        local ok, toast = CR().buy(P.ctrlId, it)
        P.toast, P.toastUntil = toast, St.nowMs() + 2500
        if ok then
            local pp = CR().player(P.ctrlId)
            if pp and pp.lo then P.lo = pp.lo end                    -- his build after the buy (bars, icons)
        end
        if ok and P.view == "native" then
            -- the native shelf keeps its places: the bought card turns unavailable (the game's PURCHASED look)
            it.bought = true
            local vm = P.nv.items[P.sel]
            pcall(function() vm.bIsAvailable = false end)
            local w = target(P, P.sel)
            if w then pcall(function() w:ActionSucceeded() end); pcall(function() w:PopulateFromVM() end) end
            P.paintAt = { St.nowMs() + 40, St.nowMs() + 300 }
            M.noteBuy(P, St.nowMs())                             -- AUTO-158c: his cursor stays, a quick 2nd A waits
            refreshShopBuild(P, it)
            reapplyBuild(P)
        elseif ok then
            -- the list: his stock as couchrun keeps it (the paddock shop / his own shop with RESTOCK and PACKS)
            local rows = nil
            if S.vendor then
                local p = CR().player(P.ctrlId)
                rows = p and p.vendorShop
            else
                pcall(function() rows = CR().personalShop(P.ctrlId) end)
            end
            P.rows = type(rows) == "table" and rows or P.rows
            P.sel = math.max(1, math.min(P.sel, #P.rows))
        end
    else
        if not P.mirror and V.mustReplace(P, it) and V.replaceOpen(P, it, "claim") then return end      -- #95
        local toast = P.mirror and tostring(it.name or it.id) or CR().claim(P.ctrlId, it)
        P.toast, P.toastUntil = toast, St.nowMs() + 3000
        P.done = true
        if P.flowMode then U.try(TAG, require("couchflow").afterClaim, P) end     -- couch-rewards2: his hub again
        if P.view == "native" then
            local w = target(P, P.sel)
            if w and P.sel <= P.nv.nCards then pcall(function() w:ActionSucceeded() end) end
            P.paintAt = { St.nowMs() + 40, St.nowMs() + 300 }        -- ActionSucceeded re-populates from the VM
        end
    end
    render(P)
end

---------------------------------------------------------------------------------------------------- input
local KEYS = { b = { C.KEY.B } }

-- the PlayerController reading this guest's pad now (the swap moves pad ids between PCs). ctrlId = the guest's
-- ORIGINAL id (join.joinedList keys guests by it even while swapped); 3-4 players: only the shared screen's owner and
-- P1 exchange ids, every other guest's pad stays on his own PC.
-- couch.lua's PARK (cfg.CouchSwapPark): while a split is open the screen owner's pad reaches no PlayerController; then
-- P1's PC is returned (the one that carries that pad whenever it is not parked) and padHasFocus / padSetFocus below
-- take the parked path.
local function couchMod() local c = package.loaded["couch"]; return type(c) == "table" and c or nil end
local function padParked(ctrlId)
    local c = couchMod()
    if ctrlId == nil or not (c and type(c.parkedFor) == "function") then return false end
    local ok, id = pcall(c.parkedFor)
    return ok and id ~= nil and id == padOf(ctrlId)
end

local function padPC(ctrlId)
    ctrlId = padOf(ctrlId)        -- couch-fix72: ident -> the pad he holds (padmap)
    local GS = U.cdo("GameplayStatics")
    for _, e in ipairs(U.localPlayers()) do
        local okI, id = pcall(function() return GS:GetPlayerControllerID(e.pc) end)
        if okI and id == ctrlId then return e.pc end
    end
    local c = couchMod()
    if c and type(c.padHolder) == "function" then
        local ok, pc = pcall(c.padHolder, ctrlId)
        if ok and U.ok(pc) then return pc end
    end
    return nil
end

-- w holds the focus of pad ctrlId's Slate user (pc = padPC(ctrlId)). Parked: no PC carries that id, so HasUserFocus
-- cannot name the user: couch.parkedFocus (some user, none of the local players' users).
local function padHasFocus(w, ctrlId, pc)
    if not U.ok(w) then return false end
    if padParked(ctrlId) then
        local ok, has = pcall(couchMod().parkedFocus, w)
        return ok and has == true
    end
    local has = false
    pcall(function() has = w:HasUserFocus(pc) == true end)
    return has
end

-- focus w for pad ctrlId's Slate user. Parked: through couch.withPadId (P1's PC on that id for the one call).
local function padSetFocus(w, ctrlId, pc, force)
    if not U.ok(w) then return false end
    if padParked(ctrlId) then
        local ok, done = pcall(couchMod().withPadId, padOf(ctrlId), function(holder) w:SetUserFocus(holder) end, force == true)
        return ok and done == true
    end
    return pcall(function() w:SetUserFocus(pc) end)
end

local function readPad(pc)
    local st = {}
    for k, names in pairs(KEYS) do
        st[k] = false
        for _, n in ipairs(names) do if U.mod("ui").keyDown(pc, n) then st[k] = true; break end end
    end
    return st
end

-- couch-fix64 (AUTO-158c, live round 9 Hibi's: after a part buy P2's focus jumped to the row-2 card, Right could not
-- leave it (only empty places to its right) and a quick second A bought that card too). The bought card turns
-- unavailable (PopulateFromVM) and the focus moved off it. A focus jump within BUY_HOLD_MS of the buy (the card's own
-- disable, not his move: none with a D-pad / stick key down) is undone ONCE: his cursor stays on the card he bought (the
-- PURCHASED card: an A there only says PURCHASED); an A within BUY_A_GUARD_MS of the buy is not a press (the same
-- thumb's double tap).
M.BUY_HOLD_MS, M.BUY_A_GUARD_MS = 350, 300
M.DIR_KEYS = { "Gamepad_DPad_Left", "Gamepad_DPad_Right", "Gamepad_DPad_Up", "Gamepad_DPad_Down",
               "Gamepad_LeftStick_Left", "Gamepad_LeftStick_Right", "Gamepad_LeftStick_Up", "Gamepad_LeftStick_Down" }
function M.noteBuy(P, now)
    P.selHold = { sel = P.sel, untilMs = now + M.BUY_HOLD_MS }
    P.aGuardUntil = now + M.BUY_A_GUARD_MS
    P.refocus = true
end
-- pure: the row his cursor shows after a buy -> sel to keep (nil = follow the focus read), moved = he moved it himself
function M.buyHoldSel(P, now, focused, moved)
    local h = P.selHold
    if not h then return nil end
    if now > h.untilMs or moved then P.selHold = nil; return nil end
    if focused ~= nil and focused ~= h.sel then P.selHold = nil; return h.sel end      -- once
    return nil
end
-- pure: an A edge now is swallowed (too soon after his buy)
function M.buyAGuarded(P, now) return P.aGuardUntil ~= nil and now < P.aGuardUntil end

local function panelTick(P, now)
    if P.broken or P.ownClosed then return end
    -- a SETTLED chip (the property swap did not stick): re-applied every tick, P1's Tick rewrites it when his credits move
    local cw = P.nv and P.nv.chip
    if cw and not cw.swapped and P.ctrlId ~= nil then
        local p = CR().player(P.ctrlId)
        chipFeed(cw, p and p.credits or 0)
    end
    local ic = P.nv and P.nv.innerChip                 -- the mystery copy's own chip: settled, or fed when his credits move
    if ic and P.ctrlId ~= nil then
        local p = CR().player(P.ctrlId)
        local c = math.floor(tonumber(p and p.credits) or 0)
        if not ic.swapped or ic.shown ~= c then chipFeed(ic, c) end
    end
    if P.view == "native" and P.paintAt[1] and now >= P.paintAt[1] then
        table.remove(P.paintAt, 1)
        paint(P)
        renderNative(P)
    end
    if P.toast and now >= (P.toastUntil or 0) then P.toast = nil; render(P) end
    if P.flowMode and P.flowBackAt then
        local okF, F = pcall(require, "couchflow")
        if okF and F.tick(P, now) then render(P); return end
    end
    if P.flowMode and P.nv and not P.rp then  -- #47: no native "NO REWARDS" over his hub, his build stays his
        local okF, F = pcall(require, "couchflow")
        if okF and type(F.keepHub) == "function" then
            if P.nv.view == "hub" then U.try(TAG, F.keepHub, P, now) end
            if P.nv.view == "faults" and type(F.keepFaults) == "function" then U.try(TAG, F.keepFaults, P, now) end
            U.try(TAG, F.keepBuild, P, now)
        end
    end
    -- #83: a done guest's finished hub still reads his A (CONTINUE closes his own area: couchflow.act -> closeOwn)
    local doneHub = P.done and P.flowMode and P.flowView == "hub"
    if (P.done and not doneHub) or P.mirror or P.ctrlId == nil then return end
    local pc = padPC(P.ctrlId)
    if not U.ok(pc) then return end
    local n = P.rows and #P.rows or 0
    if n == 0 then return end
    local focused, pressed, pressedAt = nil, false, nil
    for i = 1, math.min(n, #P.btns) do
        local b = P.btns[i]
        if U.ok(b) then
            if padHasFocus(b, P.ctrlId, pc) then focused = i end
            local pr = false
            pcall(function() pr = b:IsPressed() == true end)
            if pr then pressed = true; pressedAt = pressedAt or i end
        end
    end
    -- FINDING #31 (live: "the first option (CORNERING) could not be selected"): a press belongs to the button he
    -- PRESSED. The focus read can lag a tick behind Slate (parked: HasAnyUserFocus minus every local user), and A then
    -- acted on the stale selection or on nothing; the pressed button's row is the selection from now on.
    if pressedAt and not P.prev.a and pressedAt ~= P.sel then
        focused = pressedAt
    end
    if P.refocus then                                 -- the shelf changed under him (a pack opened): his focus follows
        P.refocus = nil
        local b = P.btns and P.btns[P.sel]
        if U.ok(b) then padSetFocus(b, P.ctrlId, pc) end
        P.focusAt = now
        focused = P.sel
    end
    if P.selHold then                                 -- AUTO-158c: the focus jump off his bought card is undone
        local moved = false
        if not padParked(P.ctrlId) then
            for _, n in ipairs(M.DIR_KEYS) do
                if U.mod("ui").keyDown(pc, n) then moved = true; break end
            end
        end
        local keep = M.buyHoldSel(P, now, focused, moved)
        if keep then
            local b = P.btns and P.btns[keep]
            if U.ok(b) then padSetFocus(b, P.ctrlId, pc) end
            P.focusAt = now
            U.dbg(TAG, "P%s: focus moved to row %s right after his buy: back on the card he bought (row %d)",
                tostring(P.pnum), tostring(focused), keep)
            focused = keep
        end
    end
    if focused and focused ~= P.sel then
        setSel(P, focused)
        if P.view ~= "native" or (P.nv and P.nv.mystery) then render(P) end     -- #112: the mystery reason line
    end
    -- garage: his LEFT / RIGHT landed on a sentinel: step the row, focus back on it
    if not focused and S.kind == "garage" and P.side then
        local dir = (padHasFocus(P.side.L, P.ctrlId, pc) and -1) or (padHasFocus(P.side.R, P.ctrlId, pc) and 1) or nil
        if dir then
            garageAct(P, dir)
            local b = P.btns[P.sel]
            if U.ok(b) then padSetFocus(b, P.ctrlId, pc) end
            P.focusAt = now
            P.prev.a = pressed
            return
        end
    end
    -- FINDING #31: the first tick of his area puts his pad's focus on his first row at once, past the park's rate
    -- limit (forced): his first A is never spent while his focus is still on P1's screen
    if not P.focusInit then
        P.focusInit = true
        if not focused and not pressed then
            local b = P.btns[P.sel]
            if U.ok(b) and padSetFocus(b, P.ctrlId, pc, true) then P.focusAt = now end
        end
    end
    -- (never while he holds a button: a focus round trip under a held A released the press - no click, no claim)
    if not focused and not pressed and now - (P.focusAt or 0) > 250 then
        P.focusAt = now
        local b = P.btns[P.sel]
        if U.ok(b) then padSetFocus(b, P.ctrlId, pc) end
    end
    if pressed and not P.prev.a then
        if M.buyAGuarded(P, now) then
            U.log(TAG, "P%s's A %d ms after his buy ignored (a double tap, AUTO-158c)", tostring(P.pnum),
                math.floor(now - (P.aGuardUntil - M.BUY_A_GUARD_MS)))
        else
            act(P)
        end
    end
    -- B leaves the shop. couch-fix48 (live round 2 AUTO-125, 13:45:3x: P2's B twice in his Hibi's copy, nothing; his
    -- LEAVE row worked): the pad ids were SWAPPED and PARKED (the shop screen is the last local PC's = P2's: P1's pad
    -- drives it, P1's PC waits on the spare id), so no PlayerInput reads P2's pad and the B read below was skipped. His
    -- B is read from the input filter's pad watch first (his physical pad's B counter, like fix43's P1 back guard:
    -- V.p1BSeq), parked or not; the PlayerInput stays the fallback when the pad watch is off.
    -- couch-fix54 (AUTO-132): a guest with no takeable mystery row passes with his B too
    if P.rp or V.shopLike(P) or S.kind == "garage" or S.kind == "vendor" or V.mysteryNoChoice(P) then
        local bEdge, bDown, via = false, false, nil
        local seq, watch = V.guestBSeq(P.ctrlId)
        if seq == nil and watch then seq = 0 end
        if seq ~= nil then
            if P.bSeq ~= nil and seq > P.bSeq then bEdge, via = true, "pad watch" end
            P.bSeq = seq
            P.prev.b = false
        elseif not padParked(P.ctrlId) then
            local st = readPad(pc)
            bDown = st.b == true
            bEdge, via = bDown and not P.prev.b, "PlayerInput"
            P.prev.b = bDown
        end
        if bEdge and P.rp then                               -- #95: B on PART SLOTS FULL = DON'T REPLACE
            V.replaceAct(P, { rkind = "vkeep" })
            P.prev.b, P.prev.a = bDown, pressed
            return
        end
        if bEdge then
            U.log(TAG, "P%s's B (%s) on his %s area", tostring(P.pnum), tostring(via), tostring(S.kind))
            -- the scrap dealer like the game: B on a page = back to the landing, B on the landing = leave
            if S.kind == "vendor" and P.vmode ~= "landing" then V.vendorSwitch(P, "landing"); return end
            if S.kind == "mystery" then V.mysteryPass(P, "his B"); P.prev.a = pressed; return end
            P.done = true; render(P)
        end
    end
    P.prev.a = pressed
end

---------------------------------------------------------------------------------------------------- tick
local function guests()
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    return (okJ and type(list) == "table") and list or {}
end

local function allDone()
    for _, P in ipairs(S.panels) do
        if not P.done and not P.mirror and not P.broken then return false end
    end
    return true
end

-- #83 (live 2026-10-18 08:48:19-08:49:06, after the gauntlet's time-trial field test): P2 had collected all 3 of his
-- stages and P1 had left his rewards for the RUN MAP, yet P2's area said "REWARDS COLLECTED - WAITING FOR P1" for 47 s,
-- until the race world went ("panels closed (panel host gone)"): P1's post-race reward screens stay ACTIVATED under the
-- map (the guest-owned WBP_PostRace_Cam_Rewards_Presentation_C: the UI manager's owner is the last local PC), so the
-- "native screen closed" test never fired. Now:
--   * the run map up for REWARD_FLOW_END_MS with the reward areas open = P1's reward flow has ENDED (S.p1Left);
--   * then every guest done -> the areas close with P1's flow; a guest NOT done keeps his area on the map, with
--     "P1 IS ON THE MAP - FINISH YOUR REWARDS" (never a stale WAITING FOR P1);
--   * a done guest's A on his finished hub (CONTINUE) closes his own area (closeOwn); every area closed = the split ends.
-- #83: a done guest's CONTINUE on his finished hub: his own area goes (the others go on; the last one ends the split)
function M.closeOwn(P, why)
    P.closeOwn = nil
    if P.ownClosed then return end
    P.ownClosed = true
    show(P.box, false)
    U.log(TAG, "P%s closed his own %s area (%s)", tostring(P.pnum), tostring(S.kind), tostring(why))
end
-- #93 (Jules, 2026-10-18): a guest who has collected every reward (his hub: "REWARDS COLLECTED - WAITING FOR P1") does
-- not wait for P1 any more: his area closes AT ONCE and the split is laid out again for the players still choosing
-- (3-4 players: a 3-area or 2-area split); only P1 left = P1's reward screen full screen again. The #83 rule for a
-- guest NOT done when P1 leaves is kept (his area stays on the map, FINISH YOUR REWARDS).
-- pure: the reward-area action this tick -> "closeOwn" (a done guest's area to close), "relayout", "close" or nil
function M.doneAction(kind, panels, n, p1Left)
    if kind ~= "reward" then return nil end
    local left = 0
    for _, P in ipairs(panels or {}) do
        if not P.mirror and not P.gone and not P.ownClosed then
            if P.done and not p1Left then return "closeOwn", P end
            left = left + 1
        end
    end
    if left == 0 then
        for _, P in ipairs(panels or {}) do if not P.mirror then return "close" end end
        return nil
    end
    if 1 + left < (n or 0) then return "relayout" end
    return nil
end
-- pure: the reward areas' state after P1's flow ended -> "close" | "finish" (a guest still choosing) | nil (not ended)
function M.p1LeftAction(kind, p1Left, panels)
    if kind ~= "reward" or not p1Left then return nil end
    for _, P in ipairs(panels or {}) do
        if not P.done and not P.mirror and not P.broken and not P.gone then return "finish" end
    end
    return "close"
end
-- pure: every guest area closed by its own guest (or gone) -> true
function M.allClosedOwn(panels)
    local any = false
    for _, P in ipairs(panels or {}) do
        if not P.mirror then
            any = true
            if not (P.ownClosed or P.gone) then return false end
        end
    end
    return any
end

---------------------------------------------------------------------------------------------------- #77 the stop waits
-- FINDING #77 (Jules 2026-10-18, P2 on a DS4 at the SCRAP DEALER): P1's B left the stop (Hibi's shop / the Scrap
-- Dealer) and the split closed with P2 still shopping. P1's leave now WAITS for every joined guest, like the challenges
-- screen (couchbets "WAITING FOR P2"):
--   * P1's B on the stop's leaving screen (WBP_Paddock_Shop_Presentation_C, the dealer's landing WBP_ExoticVendor_C -
--     never its SHOP / REPAIR PARTS pages, whose B goes back to the landing) is held while a guest area is open. Two
--     paths reach it: the menubridge's bridged B (P1's PC parked: shopBack / genericBack ask M.holdLeave first), and the
--     game's own CommonUI back (a session where P1's B reaches the screen): a Blueprint post-hook on the screen's
--     BP_OnHandleBackAction returns true ("handled": FuseScreenWidget leaves - BackToPreviousState - only on false;
--     UE4SS's script hook writes a non-nil callback return into the function's return value). Decoded: the shop's
--     returns false except on the pack picker (kept: nothing to hold there), the landing's always false.
--   * P1's area shows "WAITING FOR P2" (the couchbets plate), each guest still shopping sees "P1 IS LEAVING" with the
--     seconds left; P1's pad stays his (D-pad / A browse and buy natively); his A = back to shopping (hold cancelled).
--   * the stop closes (the screen's own BackToPreviousState) once every guest left with his own LEAVE / B / DONE, after
--     cfg.CouchStopWaitMs, or when P1 holds B cfg.CouchStopForceMs (pad watch down bit, else his PlayerInput). A guest
--     closed that way keeps every purchase (couchrun writes each buy at once; a paid pack stays pending for his next
--     shop) - logged per guest.
V.STOP_LEAVE = { WBP_Paddock_Shop_Presentation_C = true, WBP_ExoticVendor_C = true }
V.STOP_PAGES = { "ExoticVendorShop", "ExoticVendorRepair" }      -- the dealer's pages: B = back to its landing
V.STOP_HOOKS = {
    "/Game/Griffin/UI/Screens/Paddock/WBP_Paddock_Shop_Presentation.WBP_Paddock_Shop_Presentation_C:BP_OnHandleBackAction",
    "/Game/Griffin/UI/Screens/Paddock/WBP_ExoticVendor.WBP_ExoticVendor_C:BP_OnHandleBackAction",
}
V.PADW_B = 4                                                       -- swgr_inputfilter pad watch down mask: slot 2 (B)

-- the guests still shopping ("P2", ...)
function V.waiting()
    local out = {}
    for _, P in ipairs(S.panels) do
        if not P.done and not P.mirror and not P.gone and not P.broken and P.ctrlId ~= nil then
            out[#out + 1] = "P" .. tostring(P.pnum)
        end
    end
    return out
end

-- Hibi's shop with its pack picker up: its own back returns true (the picker's), not a leave
function V.shopOnPack(w)
    local on = false
    pcall(function()
        local lay = w.WBP_Paddock_Shop_Layout_Presentation
        on = U.key(lay.MainSwitcher:GetActiveWidget()) == U.key(lay.WBP_Shop_ItemPack_Panel_Presentation)
    end)
    return on
end

-- w = the stop's leaving screen (P1's), not one of the dealer's pages
function V.isStopLeave(w)
    if not (S.open and (S.kind == "shop" or S.kind == "vendor")) or not U.ok(w) then return false end
    local n = ""
    pcall(function() n = U.className(w) or "" end)
    for _, p in ipairs(V.STOP_PAGES) do if n:find(p, 1, true) then return false end end
    if not (V.STOP_LEAVE[n] or (S.nativeKey ~= 0 and U.key(w) == S.nativeKey)) then return false end
    if n:find("Paddock_Shop_Presentation", 1, true) and V.shopOnPack(w) then return false end
    return true
end

-- couch-fix50 (live round 2 AUTO-130e, shot r2-a7-01: "WAITING FOR P2 - HOLD B" cut at its right end): the plate was
-- a fixed 560 su wide, the text "WAITING FOR P2 - HOLD B TO LEAVE" (30 su body caps, ~0.78 of the size a character)
-- runs ~730 su. Pure: the plate width for text t at scale s: the text's width + 28 su each side, at least 560, at most
-- maxW (P1's frame minus its margins).
V.NOTE_CHAR = 0.78
function V.noteWidth(t, s, maxW)
    local font = math.floor(30 * s + 0.5)
    local w = math.floor(#tostring(t or "") * font * V.NOTE_CHAR + 56 * s + 0.5)
    w = math.max(math.floor(560 * s), w)
    if maxW then w = math.min(w, math.floor(maxW)) end
    return w
end

-- P1's plate bottom left of his frame (couchbets' look), made at the first hold. text nil = hidden
function V.p1Note(t)
    local H = S.H
    if t ~= nil and H and not V.noteT then
        pcall(function()
            local r = regionsFor(S.n)[0]
            local fw = math.min(r.w, r.h * 16 / 9)
            local fh = fw * 9 / 16
            local fx, fy = r.x + (r.w - fw) / 2, r.y + (r.h - fh) / 2
            local s = math.max(0.75, fh / 2160)
            local bh = math.floor(72 * s + 0.5)
            local y = math.floor(fy + fh - 32 * s - bh)
            V.noteB = pillImage(H.tree, "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_FE_Section_CurrencyBacker.MI_UI_Pill_FE_Section_CurrencyBacker",
                { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.9 })
            V.noteGeo = { s = s, h = bh, maxW = fw - 64 * s }
            V.noteW = V.noteWidth(t, s, V.noteGeo.maxW)
            V.noteSl = place(H.cv, V.noteB, math.floor(fx + 32 * s), y, V.noteW, bh, 40)
            V.noteT = text(H.tree, math.floor(30 * s + 0.5), PAPER, FONT_BODY)
            local sl = place(H.cv, V.noteT, math.floor(fx + 60 * s), math.floor(y + bh / 2), nil, nil, 41)
            pcall(function() sl:SetAlignment({ X = 0, Y = 0.5 }) end)
        end)
    end
    -- the plate follows its text (a longer guest list, the map hold's text)
    if t ~= nil and V.noteGeo and U.alive(V.noteSl) then
        local w = V.noteWidth(t, V.noteGeo.s, V.noteGeo.maxW)
        if w ~= V.noteW then
            V.noteW = w
            pcall(function() V.noteSl:SetSize({ X = w, Y = V.noteGeo.h }) end)
        end
    end
    if V.noteT then setText(V.noteT, t or "") end
    show(V.noteT, t ~= nil); show(V.noteB, t ~= nil)
    V.noteShown = t
end

-- the BP back hooks (hot-reload safe: the registered callbacks read the current handler from _G)
function V.hooksTable()
    local H = rawget(_G, "SWGRCouch_stophold_hooks")
    if type(H) ~= "table" then H = {}; _G.SWGRCouch_stophold_hooks = H end
    return H
end
function V.backHook(ctx)
    local H = rawget(_G, "SWGRCouch_stophold_hooks")
    if not (H and H.on) then return nil end
    local ok, held = pcall(H.on, ctx)
    -- couch-fix43: proof in the log that the hook runs at all (live round 1: never a line from it)
    U.logEvery("couchpanel.backhook", 3000, TAG, "#77 the stop screen's BP_OnHandleBackAction ran (hook): %s",
        ok and (held == true and "held (returns handled)" or "not held") or ("error " .. tostring(held)))
    if ok and held == true then return true end
    return nil
end
function V.armHold()
    if opt("CouchStopWaitGuests", true) == false then return end
    local H = V.hooksTable()
    H.on = function(ctx) return M.holdLeave(U.unwrap(ctx), "P1's B (the game's own back)") end
    if H.ids then return end
    local ids = {}
    for _, path in ipairs(V.STOP_HOOKS) do
        -- only a screen class in memory (RegisterHook throws otherwise; the other stop's class loads with its visit)
        local found = false
        pcall(function() found = U.ok(StaticFindObject(path)) end)
        if found then
            local ok, pre, post = pcall(RegisterHook, path, V.backHook)
            if ok and type(pre) == "number" then ids[#ids + 1] = { path = path, pre = pre, post = post } end
        end
    end
    H.ids = ids
    U.log(TAG, "stop hold armed: %d of %d back hook(s) on the stop screens in memory (P1's leave waits for the guests)",
        #ids, #V.STOP_HOOKS)
end
function V.disarmHold()
    U.try(TAG, V.backRestore, "the split closed")
    local H = V.hooksTable()
    H.on = nil
    for _, h in ipairs(H.ids or {}) do pcall(UnregisterHook, h.path, h.pre, h.post or h.pre) end
    H.ids = nil
end

-- M.holdLeave(w, src): P1 is leaving the stop through screen w -> true when the leave is held
function M.holdLeave(w, src)
    if opt("CouchStopWaitGuests", true) == false or S.debug or S.holdPass then return false end
    if not V.isStopLeave(w) then return false end
    local wt = V.waiting()
    if #wt == 0 then return false end
    local now = St.nowMs()
    if S.hold then
        U.logEvery("couchpanel.holdagain", 2000, TAG, "%s again: the stop still waits for %s", tostring(src), table.concat(wt, ", "))
        return true
    end
    S.hold = { at = now, src = src, natKey = U.key(w), nat = w, downAt = now, aSeq = nil, names = "" }
    local waitMs = V.waitMs()
    U.log(TAG, "#77 P1 leaves the %s (%s): held until %s left (his LEAVE / B), %s; P1 holds B %d s to leave "
        .. "now, his A = back to shopping", (S.kind == "vendor") and "scrap dealer" or "shop", tostring(src),
        table.concat(wt, ", "), waitMs > 0 and string.format("at most %d s", math.floor(waitMs / 1000)) or "no time limit",
        math.floor((tonumber(opt("CouchStopForceMs", 2000)) or 2000) / 1000))
    return true
end
M._noteWidth = function(t, s, maxW) return V.noteWidth(t, s, maxW) end
M._note = function() return { w = V.noteW, geo = V.noteGeo, shown = V.noteShown } end
function M.holdState() return S.hold and { at = S.hold.at, src = S.hold.src, note = V.noteShown } or nil end

-- P1's B held / A pressed now: pad watch (his physical pad) first, his PlayerInput as a fallback
function V.p1Keys()
    local bDown, aSeq, aDown = false, nil, false
    local IF = package.loaded["inputfix"]
    if opt("CouchPadWatchBridge", true) ~= false and type(IF) == "table" and type(IF.padPresses) == "function" then
        local okW, on = pcall(function() return IF.padWatch() end)
        if okW and on == true then
            local uid = 0
            pcall(function()
                local c = U.mod("couch")
                local o = c.originalIdOf(U.p1())
                if type(o) ~= "number" and type(c.p1Pad) == "function" then o = c.p1Pad() end   -- couch-fix72
                if type(o) == "number" then uid = o end
            end)
            local okP, pads = pcall(IF.padPresses)
            local e = okP and type(pads) == "table" and pads[uid] or nil
            if type(e) == "table" then
                bDown = ((tonumber(e.down) or 0) & V.PADW_B) ~= 0
                aSeq = tonumber(e.a)
            end
        end
    end
    local p1 = U.p1()
    if U.ok(p1) then
        local ui = U.mod("ui")
        if not bDown then pcall(function() bDown = ui.keyDown(p1, C.KEY.B) == true end) end
        pcall(function() aDown = ui.keyDown(p1, C.KEY.A) == true end)
    end
    return bDown, aSeq, aDown
end

-- Jules's Q9 (audit 12, 2026-10-18): "hard wait, hold to force" - cfg.CouchStopWaitMs 0 (the default) = no time
-- limit; > 0 = the old cap
function V.waitMs()
    local v = tonumber(opt("CouchStopWaitMs", 0)) or 0
    return (v > 0) and v or 0
end

-- couch-fix43 (live round 1 2026-10-18 12:16:29 and 12:16:55, A7: "#77 the shop closed with P2 still shopping (native
-- screen closed; held no)" twice, though "stop hold armed: 2 of 2 back hook(s)"; the same at 10:23 on the Scrap
-- Dealer): no hold line ever, live. P1's pad drove the stop screen's owner (the swap: the game makes it for the LAST
-- local PC) and his B went the game's own way: CommonUI's back action -> the stop screen (decoded: the ONLY back handler
-- of Hibi's shop - bIsBackHandler true on WBP_Paddock_Shop_Presentation, false on its layout and main selection panel)
-- -> NativeOnHandleBackAction -> BP_OnHandleBackAction -> FuseScreenWidget's leave (BackToPreviousState) -> OnLeaveShop
-- (the checkpoint save at 12:16:28.90, the paddock HUD at .97). The BP post-hook's "handled" return did not stop it
-- (UE4SS writes a script hook's return into RESULT_DECL of ProcessLocalScriptFunction; nothing in the log shows the hook
-- even ran). So the guard does not rely on it: while a guest shops, P1's stop leaving screen is no back handler
-- (CommonActivatableWidget.bIsBackHandler = false: NativeOnHandleBackAction does nothing), and P1's B is read from his
-- own pad (the input filter's pad watch B counter, his PlayerInput as a fallback) -> M.holdLeave (WAITING FOR P2 -
-- HOLD B TO LEAVE). The flag comes back the moment nobody shops, at the release (then the screen's own
-- BackToPreviousState) and when the split closes. The BP hook stays as a second line (logged when it runs).
V.backOff = {}                      -- key -> stop screen whose bIsBackHandler the guard turned off

-- P1's stop leaving screens up now (the scan's activated entries, and the outer chain of the tracked native screen)
function V.stopScreens()
    local out, seen = {}, {}
    local function add(w)
        local k = U.key(w)
        if k ~= 0 and not seen[k] and not S.own[k] then seen[k] = true; out[#out + 1] = w end
    end
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if okA and type(list) == "table" then
        for _, e in ipairs(list) do
            if V.STOP_LEAVE[e.cls] and U.alive(e.w) then add(e.w) end
        end
    end
    if S.nativeKey ~= 0 and S.guardNatKey ~= S.nativeKey then
        S.guardNatKey, S.guardOuter = S.nativeKey, nil
        local o = S.native
        for _ = 1, 6 do
            if not U.ok(o) then break end
            if V.STOP_LEAVE[U.className(o)] then S.guardOuter = o; break end
            o = U.outerOf(o)
        end
    end
    if U.alive(S.guardOuter) then add(S.guardOuter) end
    return out
end

function V.backRestore(why)
    local n = 0
    for k, w in pairs(V.backOff) do
        if U.alive(w) then
            if pcall(function() w.bIsBackHandler = true end) then n = n + 1 end
        end
        V.backOff[k] = nil
    end
    if n > 0 then U.log(TAG, "#77 back guard off (%s): %d stop screen(s) handle the back again", tostring(why), n) end
end

-- P1's B presses: -> seq (the pad watch's B counter for his physical pad) or nil, down now
function V.p1BSeq()
    local seq = nil
    local IF = package.loaded["inputfix"]
    if opt("CouchPadWatchBridge", true) ~= false and type(IF) == "table" and type(IF.padPresses) == "function" then
        local okW, on = pcall(function() return IF.padWatch() end)
        if okW and on == true then
            local uid = 0
            pcall(function()
                local c = U.mod("couch")
                local o = c.originalIdOf(U.p1())
                if type(o) ~= "number" and type(c.p1Pad) == "function" then o = c.p1Pad() end   -- couch-fix72
                if type(o) == "number" then uid = o end
            end)
            local okP, pads = pcall(IF.padPresses)
            local e = okP and type(pads) == "table" and pads[uid] or nil
            if type(e) == "table" then seq = tonumber(e.b) end
        end
    end
    if seq ~= nil then return seq, false end
    local down = false                                       -- no pad watch: his PlayerInput (a UFunction call)
    local p1 = U.p1()
    if U.ok(p1) then pcall(function() down = U.mod("ui").keyDown(p1, C.KEY.B) == true end) end
    return nil, down
end

-- couch-fix48: a guest's B presses -> the pad watch's B counter of his physical pad (his original pad id = ctrlId) or
-- nil, and whether the pad watch is on (on, no entry = his pad pressed nothing yet: counter 0)
function V.guestBSeq(ctrlId)
    if ctrlId == nil or opt("CouchPadWatchBridge", true) == false then return nil, false end
    local IF = package.loaded["inputfix"]
    if type(IF) ~= "table" or type(IF.padPresses) ~= "function" or type(IF.padWatch) ~= "function" then return nil, false end
    local okW, on = pcall(function() return IF.padWatch() end)
    if not (okW and on == true) then return nil, false end
    local okP, pads = pcall(IF.padPresses)
    ctrlId = padOf(ctrlId)        -- couch-fix72: his ident -> the pad he holds (padmap.lua)
    local e = okP and type(pads) == "table" and pads[ctrlId] or nil
    return type(e) == "table" and tonumber(e.b) or nil, true
end

-- every FAST tick while a shop / Scrap Dealer split is open
function V.backGuardTick(now)
    local want = S.open and not S.debug and opt("CouchStopWaitGuests", true) ~= false and opt("CouchStopBackGuard", true)
        ~= false and not S.holdPass and #V.waiting() > 0
    if not want then
        if next(V.backOff) ~= nil then V.backRestore(S.holdPass and "P1's leave released" or "nobody shopping") end
        S.guardB = nil
        return
    end
    -- the stop screens: looked up every 100 ms (a new dealer landing / shop screen is guarded within 3 FAST ticks)
    if not S.guardAt or now - S.guardAt >= 100 or now < S.guardAt then
        S.guardAt, S.guardScreens = now, V.stopScreens()
    end
    local screens = S.guardScreens or {}
    for _, w in ipairs(screens) do
        local k = U.key(w)
        if k ~= 0 and not V.backOff[k] then
            local was = nil
            pcall(function() was = w.bIsBackHandler end)
            if was == true then
                pcall(function() w.bIsBackHandler = false end)
                local is = nil
                pcall(function() is = w.bIsBackHandler end)
                if is == false then
                    V.backOff[k] = w
                    U.log(TAG, "#77 back guard on: %s is no back handler while %s shop(s) (P1's B -> WAITING, held B "
                        .. "%d s forces)", U.className(w), table.concat(V.waiting(), ", "),
                        math.floor((tonumber(opt("CouchStopForceMs", 2000)) or 2000) / 1000))
                else
                    U.logEvery("couchpanel.guardfail", 5000, TAG, "#77 back guard: %s.bIsBackHandler not writable (%s)",
                        U.className(w), tostring(is))
                end
            end
        end
    end
    -- P1's B (a new press): his leave, held while a guest shops
    local seq, down = V.p1BSeq()
    local g = S.guardB
    if not g then g = { seq = seq, down = down }; S.guardB = g; return end
    local edge = false
    if seq ~= nil then
        if g.seq ~= nil and seq > g.seq then edge = true end
    elseif down and not g.down then
        edge = true
    end
    g.seq, g.down = seq or g.seq, down
    if not edge or S.hold then return end
    for _, w in ipairs(screens) do
        if U.alive(w) and V.backOff[U.key(w)] and M.holdLeave(w, "P1's B (back guard)") then return end
    end
end

-- couch-fix50 (live round 2 AUTO-128, 13:34:31: after the Scrap Dealer 0 choosable nodes, the planet overview ignored
-- A; CampaignSubsystem:MarkCurrentMapNodeComplete() by hand unstuck it). The dealer's node completes in its LANDING's
-- back handler, not in BackToPreviousState (decoded WBP_ExoticVendor_C:BP_OnHandleBackAction: if
-- CampaignSubsystem:GetCurrentNodeActivity() == 7 BlackMarket and not ActiveRun:GetCurrentNode().bHasBeenCompleted ->
-- MarkCurrentMapNodeComplete(); return false = FuseScreenWidget's leave). The #77 release and the menubridge's bridged
-- B call BackToPreviousState directly (the guard turned bIsBackHandler off, P1's PC is parked): the node stayed open
-- and the run had nothing to pick. Every such leave of the landing runs that step first (the same checks: idempotent,
-- nothing on Hibi's shop or the dealer's pages, nothing for a node of another activity). -> true when it completed it
M.VENDOR_LANDING = "WBP_ExoticVendor_C"
function M.stopNodeComplete(w, why)
    if not U.ok(w) or U.className(w) ~= M.VENDOR_LANDING then return false end
    local cs = nil
    pcall(function() cs = FindFirstOf("CampaignSubsystem") end)
    if not U.ok(cs) then return false end
    local act = nil
    pcall(function() act = tonumber(cs:GetCurrentNodeActivity()) end)
    if act ~= 7 then return false end
    local done, node = nil, nil
    pcall(function()
        local r = cs.ActiveRun
        if U.ok(r) then node = r:GetCurrentNode() end
        if U.ok(node) then done = node.bHasBeenCompleted == true end
    end)
    if done ~= false then return false end                  -- completed already, or no node to read: as the BP
    local ok = pcall(function() cs:MarkCurrentMapNodeComplete() end)
    local now = nil
    pcall(function() now = node.bHasBeenCompleted == true end)
    U.log(TAG, "AUTO-128 the Scrap Dealer's node completed on its leave (%s): MarkCurrentMapNodeComplete %s, completed %s "
        .. "(the landing's own back step, skipped by a direct BackToPreviousState)", tostring(why),
        ok and "called" or "FAILED", tostring(now))
    return ok
end

-- the hold ends: the guests still shopping are closed (purchases kept), the game's own leave runs
function V.release(why)
    local h = S.hold
    S.hold, S.holdPass = nil, true
    V.p1Note(nil)
    for _, P in ipairs(S.panels) do
        if not P.done and not P.mirror and not P.gone and P.ctrlId ~= nil then
            P.done, P.toast, P.toastUntil = true, nil, nil
            local p = CR().player(P.ctrlId)
            U.log(TAG, "P%s's %s closed by P1's leave (%s): %s CR, every purchase kept (written at each buy)%s",
                tostring(P.pnum), (S.kind == "vendor") and "scrap dealer" or "shop", tostring(why),
                tostring(p and p.credits), (p and type(p.pack) == "table") and ", his paid pack stays pending" or "")
            U.try(TAG, render, P)
        elseif P.toast and P.toast:find("^P1 IS LEAVING") then
            P.toast, P.toastUntil = nil, nil
        end
    end
    U.try(TAG, V.backRestore, "P1's leave released")
    -- couch-fix43: the screen P1 left (the outer stop screen, a FuseScreenWidget) first: S.native can be Hibi's main
    -- selection panel, which has no BackToPreviousState
    local nat = (h and U.alive(h.nat)) and h.nat or S.native
    if U.alive(nat) then U.try(TAG, M.stopNodeComplete, nat, "#77 release: " .. tostring(why)) end   -- AUTO-128
    local ok = U.alive(nat) and pcall(function() nat:BackToPreviousState() end)
    if not ok and U.alive(S.native) and nat ~= S.native then
        nat = S.native
        U.try(TAG, M.stopNodeComplete, nat, "#77 release: " .. tostring(why))
        ok = pcall(function() nat:BackToPreviousState() end)
    end
    U.log(TAG, "#77 the stop closes (%s): the screen's own BackToPreviousState %s", tostring(why), ok and "ran"
        or "FAILED (P1's next B leaves)")
    if ok then V.afterRel = { atMs = St.nowMs(), cls = U.className(nat), n = 0, lastMs = -1e12, why = tostring(why) } end
end

-- couch-fix64 (AUTO-157, live round 9 12:11:27): P2's B released P1's held leave of Hibi's shop, "the stop closes ...
-- BackToPreviousState ran", "panels closed (native screen closed)" - and 1.9 s later a NEW shop screen was up (new
-- WBP_Item_Btn_C, "5 new top-level screen(s)" without the paddock HUD), P2's area reopened, and a second round of B
-- (P2, then P1's own game back) was needed. One BackToPreviousState stepped back to an earlier shop state of the
-- front-end CSM (P1 had bought there: the game's own leave does not stop on it, ours did). Now, for COMEBACK_MS after a
-- release, the same stop screen coming back before any paddock HUD is the same leave: it is left again (at most
-- COMEBACK_TRIES times, COMEBACK_GAP_MS apart), the guests' areas do not reopen. A paddock HUD in between = the stop was
-- really left (a later visit opens normally).
V.COMEBACK_MS, V.COMEBACK_TRIES, V.COMEBACK_GAP_MS = 3500, 3, 700
V.PADDOCK_HUD = "WBP_Paddock_HUD_C"
-- pure: what to do with a stop screen seen now after a release -> "leave" | "wait" | nil (open normally) ; rel cleared
-- by the caller on nil. screen = the leaving screen of rel.cls is up; hud = the paddock HUD is up
function M.comebackAction(rel, now, screen, hud)
    if not rel then return nil end
    if hud or now - rel.atMs > V.COMEBACK_MS or rel.n >= V.COMEBACK_TRIES then return nil end
    if not screen then return "wait" end
    if now - rel.lastMs < V.COMEBACK_GAP_MS then return "wait" end
    return "leave"
end

-- no stop on screen after a release: the paddock HUD up = the stop was really left (a later visit opens normally)
function V.comebackHud(now)
    local rel = V.afterRel
    if not rel then return end
    if now - rel.atMs > V.COMEBACK_MS then V.afterRel = nil; return end
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not (okA and type(list) == "table") then return end
    for _, e in ipairs(list) do
        if e.cls == V.PADDOCK_HUD then V.afterRel = nil; return end
    end
end

-- the scan saw a stop again: true = handled here (no split opens this tick)
function V.comebackTick(now)
    local rel = V.afterRel
    if not rel then return false end
    local screen, hud = nil, false
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if okA and type(list) == "table" then
        for _, e in ipairs(list) do
            if e.cls == V.PADDOCK_HUD then hud = true end
            if e.cls == rel.cls and U.alive(e.w) then screen = e.w end
        end
    end
    local a = M.comebackAction(rel, now, screen, hud)
    if a == nil then
        V.afterRel = nil
        if rel.n >= V.COMEBACK_TRIES and not hud then
            U.warn(TAG, "AUTO-157 %s still up after %d extra leave(s): the split opens again (P1's B leaves)", rel.cls, rel.n)
        end
        return false
    end
    if a == "wait" then return true end
    rel.n, rel.lastMs = rel.n + 1, now
    U.try(TAG, M.stopNodeComplete, screen, "AUTO-157 comeback")
    local ok = pcall(function() screen:BackToPreviousState() end)
    U.log(TAG, "AUTO-157 %s came back %d ms after the release (%s): left again (BackToPreviousState %s, try %d of %d); "
        .. "the guests' areas stay closed", rel.cls, math.floor(now - rel.atMs), rel.why, ok and "ran" or "FAILED", rel.n,
        V.COMEBACK_TRIES)
    return true
end

function V.cancel(why)
    S.hold = nil
    V.p1Note(nil)
    for _, P in ipairs(S.panels) do
        if P.toast and P.toast:find("^P1 IS LEAVING") then P.toast, P.toastUntil = nil, nil; U.try(TAG, render, P) end
    end
    U.log(TAG, "#77 P1's leave cancelled (%s): the stop stays open", tostring(why))
end

-- every FAST tick while the split is open
function V.holdTick(now)
    local h = S.hold
    if not h then return end
    -- the dealer: P1 went from the landing into one of its pages = back to shopping
    local pageNow = false
    if S.kind == "vendor" and U.ok(S.native) and S.nativeKey ~= h.natKey then
        local n = U.className(S.native) or ""
        for _, p in ipairs(V.STOP_PAGES) do if n:find(p, 1, true) then pageNow = true end end
    end
    if pageNow then V.cancel("P1 opened another page of the stop"); return end
    if not U.alive(h.nat) then
        S.hold = nil
        V.p1Note(nil)
        local wt = V.waiting()
        if #wt > 0 then
            U.warn(TAG, "#77 P1's held leave: the stop screen went anyway (%s still shopping)", table.concat(wt, ", "))
        else
            U.log(TAG, "#77 P1's held leave: the stop screen went (nobody shopping any more)")
        end
        return
    end
    local wt = V.waiting()
    if #wt == 0 then V.release("every guest left"); return end
    local waitMs = V.waitMs()
    local left = math.max(0, math.ceil((waitMs - (now - h.at)) / 1000))
    local names = table.concat(wt, ", ")
    local note = "WAITING FOR " .. names .. " - HOLD B TO LEAVE"
    if V.noteShown ~= note then V.p1Note(note) end
    for _, P in ipairs(S.panels) do
        if not P.done and not P.mirror and not P.gone and P.ctrlId ~= nil then
            local t = (waitMs > 0) and string.format("P1 IS LEAVING - LEAVE WHEN DONE (%d S)", left)
                or "P1 IS LEAVING - LEAVE WHEN DONE"
            local was = P.toast
            P.toast, P.toastUntil = t, now + 1000
            if was ~= t then U.try(TAG, render, P) end
        end
    end
    if waitMs > 0 and now - h.at >= waitMs then
        V.release(string.format("%s still shopping after %d s", names, math.floor((now - h.at) / 1000)))
        return
    end
    local bDown, aSeq, aDown = V.p1Keys()
    if not bDown then h.downAt = nil elseif not h.downAt then h.downAt = now end
    if h.downAt and now - h.downAt >= (tonumber(opt("CouchStopForceMs", 2000)) or 2000) then
        V.release("P1 held B: leaves now")
        return
    end
    -- his A (a new press after the hold began) = back to shopping
    local aEdge = false
    if aSeq ~= nil then
        if h.aSeq ~= nil and aSeq > h.aSeq then aEdge = true end
        h.aSeq = aSeq
    end
    if aDown and h.aUp then aEdge = true end
    h.aUp = not aDown
    if aEdge then V.cancel("P1's A: back to shopping") end
end

---------------------------------------------------------------------------------------------------- fix32 map hold
-- couch-fix32 (audit 12 issue 13, playtest #83 / #93): P1 left his reward screens for the RUN MAP while a guest was
-- still choosing (his area stays there: "P1 IS ON THE MAP - FINISH YOUR REWARDS"), then P1's node pick ended the
-- post-race and close() -> flowAbandon turned the guest's open rounds into SKIP credits (and the next race's build was
-- applied before his pick). Jules's rule: the guest finishes first. While a guest reward area is open and not done:
--   * every run map screen (the planet overview, the event map, the paddock's next-event map) is DISABLED
--     (UWidget:SetIsEnabled(false): Slate gives a disabled widget no input - P1's native A on a node does nothing) and
--     the menubridge asks M.mapHeld() before it clicks a node / accepts the overview for P1;
--   * P1's area shows "WAITING FOR P2 - HOLD B TO LEAVE"; the guests' areas their FINISH YOUR REWARDS;
--   * the map comes back the tick the last guest is done (#93 closes his area), or when P1 holds B
--     cfg.CouchStopForceMs (the two-step forced leave: the guest's open rounds are then booked as before).
-- cfg.CouchRewardWaitGuests = false: no hold (0.16).
function V.choosing()
    local out = {}
    for _, P in ipairs(S.panels) do
        if not P.done and not P.mirror and not P.gone and not P.broken and not P.ownClosed and P.ctrlId ~= nil then
            out[#out + 1] = "P" .. tostring(P.pnum)
        end
    end
    return out
end
function V.mapScreensUp()
    local out = {}
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        if U.ok(e.w) and not S.own[U.key(e.w)] then
            for _, pat in ipairs(MAP_MATCH) do
                if tostring(e.cls):find(pat, 1, true) then out[#out + 1] = e.w; break end
            end
        end
    end
    return out
end
-- couch-fix51 (AUTO-130(f), live 2026-10-18 13:38:21 / 14:19:13): the disabled map did NOT stop P1's native A - the
-- game's own node pick went through 0.7 s after "WBP_RunMap_Presentation_C disabled" (no menubridge line: the pad
-- swap's CommonUI input on the screen owner's PC, IMC_UI 500) and the post-race end turned the guest's open rounds
-- into SKIP credits. The press is routed to the focused node BUTTON (the node's CommonUI triggering action / its
-- internal button): CommonButtonBase:HandleButtonClicked only checks the button's OWN interactability
-- (IsInteractionEnabled = its bButtonEnabled, set by its SetIsEnabled), never an ancestor's Slate enabled state. The
-- node's BP_OnClicked broadcasts OnNodePicked -> RunMap.MapNodePicked -> the host's OnMapNodeClicked ->
-- ChooseNextMapNode (UE4SS 3.0 cannot veto a native call, BP hooks never fire in this build): the source to block is
-- the node button itself. Every node button of a held map (RunMap.P_MapLayout's children; the paddock's
-- NextEvent hosts its RunMap as WBP_RunMap_Presentation) is disabled too, re-scanned every 100 ms (OnActiveInSwitcher
-- -> RefreshMap rebuilds them), and given back on release (only the ones that were interactable).
-- couch-fix53 (AUTO-131): the scan stopped at 64 children (the live map had at least 64 node buttons: every hold
-- logged exactly "64 ... disabled"); the planet overview's own planet buttons (WBP_PlanetSelector.Buttons,
-- WBP_Diegetic_MapOverview_Btn_C: TriggeringInputAction + OnButtonClicked -> OnSelectionClicked -> "On Selected Planet
-- Clicked") were never covered. NOTE: the live presses went through the disabled buttons anyway (the screen owner's
-- CommonUI router: couch.mapInputHold is the hold that closes that path); the buttons stay disabled for the Slate path.
V.NODE_BTN = "RunMap_Activity_Presentation_Btn"
V.NODE_MAX = 512
function V.mapNodeButtons(w)
    local out = {}
    local cls = tostring(U.className(w))
    -- the overview (post-race holder / paddock): its planet buttons
    local sel = nil
    pcall(function()
        if cls:find("RunMapOverview", 1, true) then sel = w.WBP_PlanetSelector end
    end)
    if U.ok(sel) then
        local bs = nil
        pcall(function() bs = sel.Buttons end)
        local nb = 0
        pcall(function() nb = U.arrayCount(bs) end)
        for i = 1, math.min(nb, 32) do
            local b = nil
            pcall(function() b = bs[i] end)
            if U.ok(b) then out[#out + 1] = b end
        end
        return out
    end
    local map = w
    pcall(function()
        if not cls:find("RunMap_Presentation", 1, true) then map = w.WBP_RunMap_Presentation end
    end)
    if not U.ok(map) then return out end
    local lay = nil
    pcall(function() lay = map.P_MapLayout end)
    if not U.ok(lay) then return out end
    local n = 0
    pcall(function() n = math.tointeger(tonumber(lay:GetChildrenCount())) or 0 end)
    for i = 0, math.min(n, V.NODE_MAX) - 1 do
        local b = nil
        pcall(function() b = lay:GetChildAt(i) end)
        if U.ok(b) and tostring(U.className(b)):find(V.NODE_BTN, 1, true) then out[#out + 1] = b end
    end
    return out
end
function V.mapNodesHold(h, now)
    if h.nodeScanAt and now - h.nodeScanAt < 100 then return end
    h.nodeScanAt = now
    h.nodes = h.nodes or {}
    local added = 0
    for _, w in pairs(h.ws or {}) do
        if U.alive(w) then
            for _, b in ipairs(V.mapNodeButtons(w)) do
                local k = U.key(b)
                if not h.nodes[k] then
                    local was = true
                    pcall(function() was = b:IsInteractionEnabled() ~= false end)
                    local ok = pcall(function() b:SetIsEnabled(false) end)
                    h.nodes[k] = { b = b, was = was, ok = ok }
                    added = added + 1
                end
            end
        end
    end
    if added > 0 then
        U.log(TAG, "fix51: %d run map node button(s) disabled (P1's native A on a node acts on the button, not on the "
            .. "disabled map)", added)
    end
end
function V.mapNodesRelease(h)
    local n = 0
    for _, e in pairs(h.nodes or {}) do
        if e.was and U.alive(e.b) then pcall(function() e.b:SetIsEnabled(true) end); n = n + 1 end
    end
    h.nodes, h.nodeScanAt = {}, nil
    return n
end
function V.mapRelease(why, forced)
    local h = S.mapHold
    if not h then return end
    local n = 0
    for _, w in pairs(h.ws or {}) do
        if U.alive(w) then pcall(function() w:SetIsEnabled(true) end); n = n + 1 end
    end
    h.ws = {}
    -- couch-fix53: P1's pad back on the screen owner (the map's router) first, then the buttons
    pcall(function() U.mod("couch").mapInputHold(false, tostring(why)) end)
    local nb = V.mapNodesRelease(h)
    if nb > 0 then U.log(TAG, "fix51: %d run map node button(s) enabled again", nb) end
    -- couch-fix66 (AUTO-161): read by couch.lua's node pick breadcrumb (the last line before the native pick)
    V.lastHold = { at = St.nowMs(), gen = St.worldGen, maps = n, buttons = nb, inputHeld = h.inputHeld == true,
                   forced = forced == true }
    if V.noteShown and tostring(V.noteShown):find("HOLD B TO LEAVE", 1, true) then V.p1Note(nil) end
    if forced then h.forced = true else S.mapHold = nil end
    U.log(TAG, "fix32: the run map is P1's again (%s): %d map screen(s) enabled%s", tostring(why), n,
        forced and " - the guests' open rounds are booked when the post-race ends" or "")
    -- couch-fix69 (AUTO-165): P1's pad focus back on a node of the run map once the split has closed (menubridge)
    if opt("CouchMapHoldEndRefocus", true) ~= false then
        local MB = package.loaded["menubridge"]
        if type(MB) == "table" and type(MB.mapNodeFocusSoon) == "function" then U.try(TAG, MB.mapNodeFocusSoon, why) end
    end
end
V.HOLD_GRACE_MS = 1000
-- couch-fix68 (AUTO-163, live round 12 17:08:14.847): P1's A on his LAST reward screen brought the run map up and
-- picked a node 54 ms before the hold started; the travel closed P2's open UPGRADES round (skip credits). The map is a
-- PAGE of the post-race holder (CSM_RF_Results_Campaign_PickNextEvent shows WBP_RunMap_Presentation in the holder's
-- WS_ScreenSwitcher) and P1's Rewards_Layout stays activated under it, so nothing left couch.lua's screen list: the
-- cached list only saw the map once the pick's own state change marked it dirty (the hold then came at once). P1's
-- press (150 ms) brought the map, its release clicked the focused node. Now the hold does not wait for the screen
-- list: every FAST tick of an open reward split with a guest still choosing reads the holder's switcher page itself
-- (V.holderMapPage: the cached holder, one property, GetActiveWidget), and every CosmeticStateMachine state change of
-- the post-race arms it inside the hook (M.csmChanged, couch.lua), before the next input event can reach the map.
-- cfg.CouchMapHoldEarly = false: the hold starts when the screen list shows the map (couch-fix66).
-- inHook = true (M.csmChanged): no screen scan inside the native hook (the list is dirty there): the holder the last
-- FAST tick found, in this world, alive
V.holderPage = { key = 0, cls = "" }
function V.holderMapPage(inHook)
    local holder = nil
    local hk = V.holderW
    if hk and hk.gen == St.worldGen and U.alive(hk.w) then holder = hk.w end
    if not inHook then
        holder = nil
        local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
        if okA and type(list) == "table" then
            for _, e in ipairs(list) do
                if e.cls == HOLDER_CLS and not S.own[U.key(e.w)] and U.alive(e.w) then holder = e.w; break end
            end
        end
        V.holderW = holder and { w = holder, gen = St.worldGen } or nil
    end
    if not holder then return nil end
    local page = nil
    pcall(function()
        local sw = holder.WS_ScreenSwitcher
        if U.ok(sw) then page = sw:GetActiveWidget() end
    end)
    if not (U.ok(page) and U.alive(page)) then return nil end
    local k = U.key(page)
    if k ~= V.holderPage.key then V.holderPage = { key = k, cls = tostring(U.className(page)) } end
    for _, pat in ipairs(MAP_MATCH) do
        if V.holderPage.cls:find(pat, 1, true) then return page end
    end
    return nil
end
function V.mapHoldTick(now, via)
    if S.kind ~= "reward" or S.debug or opt("CouchRewardWaitGuests", true) == false then return end
    local h = S.mapHold
    if h and h.forced then return end
    local wt = V.choosing()
    if #wt == 0 then
        if h then V.mapRelease("every guest finished his rewards") end
        return
    end
    local inHook = via ~= nil
    local maps = inHook and {} or V.mapScreensUp()
    local early = nil
    if #maps == 0 and not h and opt("CouchMapHoldEarly", true) ~= false then
        -- couch-fix68: the holder's own page (the screen list may not show the map yet)
        early = V.holderMapPage(inHook)
        if early then
            maps = { early }
            pcall(function() U.mod("couch").markDirty("fix68 run map page") end)
        end
    end
    if #maps == 0 and not h then return end
    if not h then
        h = { at = now, ws = {}, downAt = nil, early = early ~= nil }
        S.mapHold = h
        U.log(TAG, "fix32: P1 is on the run map with %s still choosing rewards: the map waits (his node pick held; P1 "
            .. "holds B %d s to leave anyway)", table.concat(wt, ", "),
            math.floor((tonumber(opt("CouchStopForceMs", 2000)) or 2000) / 1000))
        if early then
            U.log(TAG, "fix68: the run map is the post-race holder's page (%s, %s) before the screen list shows it: "
                .. "the hold starts now, before P1's input reaches it (AUTO-163)", V.holderPage.cls,
                tostring(via or "tick"))
        end
    end
    -- couch-fix53: P1's pad off the screen owner's CommonUI router (the path that picked / travelled through fix51)
    local inputHeld = false
    if opt("CouchMapInputHold", true) ~= false then
        U.try(TAG, function()
            inputHeld = U.mod("couch").mapInputHold(true, "P1's run map held for " .. table.concat(wt, ", ")) == true
        end)
    end
    -- couch-fix66 (AUTO-161): with the input hold in place the live map and its node buttons are never written. Both
    -- post-race vanishes since fix53 (AUTO-141 round 4, AUTO-161 round 11) were picks on a run map that had been held
    -- (2 of 28 held-map picks, 0 of 123 others, every round-1..11 log): that map lived through fix32's SetIsEnabled
    -- false / true and fix51's 138+ node button toggles (re-scanned every 100 ms) while it was the active screen, and
    -- P1 picked on it 4-7 s after the release. Those writes block nothing the input hold leaves open (AUTO-131: the
    -- router path ignores them; the Slate path is P1's user 0 on the sink), so they are only the fallback now: no input
    -- hold (cfg.CouchMapInputHold = false, ids not swapped) = fix32 + fix51 as before. The paddock-map pick that ran
    -- fine after CONTINUE was on a map built after its hold (the hold was on the planet overview).
    -- the swap of a guest-owned screen can come a tick after the map: the input hold gets V.HOLD_GRACE_MS to start
    -- before the fallback writes the map (the live order: ids swapped at the reward screens, the hold at once)
    local grace = not inputHeld and opt("CouchMapInputHold", true) ~= false and now - (h.at or now) < V.HOLD_GRACE_MS
    if not inputHeld and not grace then
        for _, w in ipairs(maps) do
            local k = U.key(w)
            if not h.ws[k] then
                h.ws[k] = w
                local ok = pcall(function() w:SetIsEnabled(false) end)
                U.log(TAG, "fix32: %s disabled until the guests are done%s", tostring(U.className(w)), ok and "" or " (FAILED)")
            end
        end
        U.try(TAG, V.mapNodesHold, h, now)                     -- fix51: the node buttons themselves
    elseif inputHeld and not h.mixedSaid and (next(h.ws) ~= nil or (h.nodes and next(h.nodes) ~= nil)) then
        -- the fallback ran before the input hold could start (ids not swapped yet): those writes stay until the release
        h.mixedSaid = true
        U.log(TAG, "fix66: the input hold came after fix32 / fix51 had disabled the map: those stay until the release")
    end
    if inputHeld and not h.inputSaid then
        h.inputSaid = true
        U.log(TAG, "fix66: map held by the input hold alone (%d map screen(s)): the map and its node buttons are not "
            .. "written (no fix32 / fix51 toggles on the live map)", #maps)
    end
    h.inputHeld = inputHeld or h.inputHeld
    if inHook then return end                                   -- fix68: the note / B hold on the next FAST tick
    local note = "WAITING FOR " .. table.concat(wt, ", ") .. " - HOLD B TO LEAVE"
    if V.noteShown ~= note then V.p1Note(note) end
    local bDown = V.p1Keys()
    if not bDown then h.downAt = nil elseif not h.downAt then h.downAt = now end
    if h.downAt and now - h.downAt >= (tonumber(opt("CouchStopForceMs", 2000)) or 2000) then
        V.mapRelease("P1 held B: leaves the rewards now", true)
    end
end
-- couch-fix68 (AUTO-163): couch.lua's CosmeticStateMachine post-hooks (POSTRACE): the map's state was just entered -
-- the hold starts inside the hook, before the next input event (the release of the press that left the rewards)
function M.csmChanged(fn)
    if not (S.open and S.kind == "reward") or S.debug or S.mapHold then return end
    if opt("CouchMapHoldEarly", true) == false or opt("CouchRewardWaitGuests", true) == false then return end
    local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
    if okQ and q == true then return end
    if #V.choosing() == 0 then return end
    U.try(TAG, V.mapHoldTick, St.nowMs(), "state change " .. tostring(fn))
end
-- couch-fix68 (AUTO-163): couch.lua's ChooseNextMapNode pre-hook. A pick on the RACE world while a guest still has
-- open reward stages and no hold is in place cannot be vetoed (UE4SS 3.0): said loudly, with the timing, for the next
-- test. -> the warning text or nil
function M.pickWhileChoosing()
    if not (S.open and S.kind == "reward") or S.debug then return nil end
    local wt = V.choosing()
    if #wt == 0 or M.mapHeld() or (S.mapHold and S.mapHold.forced) then return nil end   -- held / P1's forced leave
    local page = nil
    pcall(function() page = V.holderMapPage(true) end)
    local lh = V.lastHold
    return string.format("AUTO-163: a node pick while %s still choose(s) rewards and the run map is NOT held (map "
        .. "page %s, last hold %s): the guest's open stages become skip credits",
        table.concat(wt, ", "), page and V.holderPage.cls or "not the holder's page",
        (lh and lh.gen == St.worldGen) and string.format("released %d ms ago", math.floor(St.nowMs() - (lh.at or 0)))
        or "none this post-race")
end
-- menubridge: P1's node pick / planet accept on the run map is held now
function M.mapHeld() local h = S.mapHold; return S.open == true and h ~= nil and not h.forced end
function M.mapHoldState() local h = S.mapHold; return h and { at = h.at, forced = h.forced, note = V.noteShown } or nil end
-- couch-fix66: the last released map hold -> { at (ms), maps / buttons re-enabled, inputHeld, forced } or nil
function M.lastMapHold() return V.lastHold end

-- the player menu showing its build page, else nil
local function buildPage()
    local pm = findNative(PLAYER_MENU_MATCH)
    if not pm or not U.alive(pm) then return nil end
    local on = false
    pcall(function() on = U.key(pm.WS_ScreenSwitcher:GetActiveWidget()) == U.key(pm.WBP_VehicleBuild_Presentation) end)
    return on and pm or nil
end
M.buildPage = buildPage

-- FINDING #12: P1's player menu and its page: "build" | "backer" (WBP_SponsorInfo_Presentation, the L1 tab) | nil
local function playerMenuPage()
    local pm = findNative(PLAYER_MENU_MATCH)
    if not pm or not U.alive(pm) then return nil, nil end
    local page = nil
    pcall(function()
        local aw = U.key(pm.WS_ScreenSwitcher:GetActiveWidget())
        if aw == U.key(pm.WBP_VehicleBuild_Presentation) then page = "build"
        elseif aw == U.key(pm.WBP_SponsorInfo_Presentation) then page = "backer" end
    end)
    return pm, page
end
M._playerMenuPage = playerMenuPage

-- P1's backer as his own BACKER page shows it (read-only): name, contract line
local function p1Backer(pm)
    local out = { name = "", contract = "" }
    pcall(function() out.name = pm.WBP_SponsorInfo_Presentation.Txt_SponsorName:GetText():ToString() end)
    pcall(function()
        local a = pm.WBP_SponsorInfo_Presentation.Txt_Contract:GetText():ToString()
        local b = ""
        pcall(function() b = pm.WBP_SponsorInfo_Presentation.Txt_ContractValue:GetText():ToString() end)
        out.contract = (b ~= "" and (a .. "  " .. b)) or a
    end)
    if type(out.name) ~= "string" or out.name == "" then out.name = "P1'S BACKER" end
    return out
end

-- FINDING #78 (Jules 2026-10-18, backer-split.png): on VIEW BUILD -> BACKER INFO (L1) P1's half was the game's real
-- page (title bar, backer card with its icon, contract progress bar, FAVORS list) and P2's half a plain text plate.
-- P2's half is now the game's own page: a standalone WBP_SponsorInfo_Presentation_C owned by his PC in his area (made
-- at the first BACKER tab), NEVER activated (its BP_OnActivated / Anim_In are not run: no CommonUI focus, no second
-- AnimIn sound; its RenderOpacity stays the design's 1), filled the way its BP_OnActivated fills P1's (decoded
-- kismet, cue4cli --script): SponsorInfoVM = ViewModelSubsystem:BuildSponsorRunInfoVM() (a fresh VM of the run's
-- backer and contract - the team's, there is no per-player backer), Txt_Message collapsed, SetSponsor(VM) (name, icon,
-- contract line, progress bar, credits), VB_Sponsor / Img_Sponsor shown, the Display* flags from the VM, RefreshData()
-- (visibilities, SetFavours = the run's loadout favours). Then the FAVORS list is HIS: the run-wide favours of the
-- team (every kind but the per-guest ones, couchrun.guestFavour - they act on the shared run) + his own guest favours
-- (couchrun p.favours, the RacerFavour assets), each in a WBP_Favour_Description_Entry via its own SetFavour. Its header
-- chip shows his credits (headerChip). Any build error = the plate as before (logged once).
V.SPONSOR_VIEW = "/Game/Griffin/UI/Screens/WBP_SponsorInfo_Presentation.WBP_SponsorInfo_Presentation_C"
V.FAVOUR_ENTRY = "/Game/Griffin/UI/Widgets/Loadout/WBP_Favour_Description_Entry.WBP_Favour_Description_Entry_C"
V.FAVOUR_DIR = "/Game/Griffin/Gameplay/Campaign/Loadouts/Favours/"

-- his FAVORS list on the page (after RefreshData's SetFavours) -> number shown, names
function V.backerFavours(P, view)
    local list, names = {}, {}
    local function add(f, who)
        local nm = "?"
        pcall(function() nm = f.PlayerFacingName:ToString() end)
        if nm == "?" and U.ok(f) then pcall(function() nm = f:GetFName():ToString() end) end
        list[#list + 1] = f
        names[#names + 1] = string.upper(tostring(nm)) .. " (" .. who .. ")"
    end
    pcall(function()
        local arr = view.Favours
        for i = 1, U.arrayCount(arr) do
            local f = arr[i]
            local id = nil
            if U.ok(f) then pcall(function() id = f:GetFName():ToString() end) end
            if id and CR().teamFavour(id) then add(f, "team") end              -- #110: P1's per-player ones are his
        end
    end)
    local p = P.ctrlId ~= nil and CR().player(P.ctrlId) or nil
    for i = 1, 3 do
        local id = p and type(p.favours) == "table" and p.favours[i] or nil
        if type(id) == "string" and id ~= "" then
            local f = U.obj(V.FAVOUR_DIR .. id .. "." .. id)
            if U.ok(f) then add(f, "his") end
        end
    end
    local box = view.VB_Favours
    local n = 0
    pcall(function() n = math.tointeger(tonumber(box:GetChildrenCount())) or 0 end)
    local shown = 0
    for i, f in ipairs(list) do
        local e = nil
        if i - 1 < n then pcall(function() e = box:GetChildAt(i - 1) end) end
        if not U.ok(e) then
            local cls = U.class(V.FAVOUR_ENTRY)
            if U.ok(cls) then
                pcall(function() e = U.WBL():Create(P.nv.gpc, cls, P.nv.gpc) end)
                if U.ok(e) then pcall(function() box:AddChild(e) end); own(e) end
            end
        end
        if U.ok(e) and pcall(function() e:SetFavour(f) end) then
            pcall(function() e:SetVisibility(VIS.SelfHitTestInvisible) end)
            shown = shown + 1
        end
    end
    for i = #list, n - 1 do
        pcall(function() box:GetChildAt(i):SetVisibility(VIS.Collapsed) end)
    end
    pcall(function() view.B_Favours:SetVisibility((shown > 0) and VIS.HitTestInvisible or VIS.Collapsed) end)
    return shown, names
end

-- fill his page from a fresh run-info VM (the page's own BP_OnActivated path)
function V.fillBacker(P)
    local view = P.nv and P.nv.sponsor
    if not U.alive(view) then error("no BACKER INFO page") end
    local vm = vms():BuildSponsorRunInfoVM()
    -- couch-fix21 (#78 + #90): HIS backer, contract and progress in the fresh VM (couchbackerui.infoVM), the team's when
    -- he has none
    local his, hisVal = nil, nil
    if U.ok(vm) and P.ctrlId ~= nil then
        local okH, a, b = pcall(function() return require("couchbackerui").infoVM(vm, P.ctrlId, P.pnum) end)
        if okH then his, hisVal = a, b end
    end
    local okS = false
    pcall(function() okS = U.ok(vm) and U.ok(vm.Sponsor) end)
    pcall(function() view.SponsorInfoVM = vm end)
    local name = "-"
    if okS then
        pcall(function() view.Txt_Message:SetVisibility(VIS.Collapsed) end)
        view:SetSponsor(vm)
        pcall(function() view.VB_Sponsor:SetVisibility(VIS.HitTestInvisible) end)
        pcall(function() view.Img_Sponsor:SetVisibility(VIS.HitTestInvisible) end)
        pcall(function() view.DisplayFavours = vm.bCanDisplayFavoursInfo end)
        pcall(function() view.DisplayContractInfo = vm.bCanDisplayContractInfo end)
        pcall(function() view.DisplayForm = vm.bCanDisplaySoloTourForm end)
        pcall(function() view.DisplayContractProgress = vm.bCanDisplayContractProgress end)
        pcall(function() view.DisplayContractEarnings = vm.bCanDisplayContractCreditsEarned end)
        view:RefreshData()
        pcall(function() name = vm.Sponsor.PlayerFacingName:ToString() end)
    else
        -- the page's no-backer state (its own message)
        pcall(function() view.Txt_Message:SetVisibility(VIS.HitTestInvisible) end)
        for _, k in ipairs({ "B_ContractDetails", "B_Form", "VB_Sponsor", "Img_Sponsor" }) do
            pcall(function() view[k]:SetVisibility(VIS.Collapsed) end)
        end
        pcall(function() view:SetFavours() end)
    end
    local nf, names = 0, {}
    local fav = true
    pcall(function() fav = view.DisplayFavours ~= false end)
    if fav then nf, names = V.backerFavours(P, view) end
    local c = P.ctrlId ~= nil and CR().player(P.ctrlId) or nil
    if P.nv.innerChip then chipFeed(P.nv.innerChip, math.floor(tonumber(c and c.credits) or 0)) end
    U.log(TAG, "#78 P%s's BACKER INFO: the game's page, backer %s%s, %d favour(s)%s%s", tostring(P.pnum), tostring(name),
        okS and "" or " (no backer: the page's message)", nf, (#names > 0) and (": " .. table.concat(names, ", ")) or "",
        his and string.format(" - HIS OWN backer (%s, %s)", his, tostring(hisVal)) or "")
end

-- his page, made once in his build area's overlay (hidden on the BUILD tab)
function V.buildBacker(P)
    local W = P.nv
    if not (W and W.ov and S.H) then error("no build area") end
    local cls = U.class(V.SPONSOR_VIEW)
    if not U.ok(cls) then error("WBP_SponsorInfo_Presentation_C not loaded") end
    local gpc = U.ok(W.gpc) and W.gpc or U.p1()
    local inner = mk(SIZEB, S.H.tree)
    if not inner then error("no SizeBox") end
    inner:SetWidthOverride(3840); inner:SetHeightOverride(1920)
    overlayAdd(W.ov, inner, 2, 2)
    local view = U.WBL():Create(gpc, cls, gpc)
    if not U.ok(view) then
        pcall(function() inner:RemoveFromParent() end)
        error("BACKER INFO page not created")
    end
    own(view)
    pcall(function() view.bAutoActivate = false end)
    inner:AddChild(view)
    pcall(function() view:SetVisibility(VIS.HitTestInvisible) end)
    W.sponsor, W.sponsorBox = view, inner
    W.innerChip = headerChip(view, P)          -- the page header's credits chip: his (panelTick keeps feeding it)
    V.fillBacker(P)
end

-- the build split follows P1's menu tab: his build page in each guest area on BUILD, the game's BACKER INFO page (the
-- plate when it cannot be built) on BACKER
local function buildTab(page, pm)
    if S.buildTab == page then return end
    S.buildTab = page
    local info = (page == "backer") and p1Backer(pm) or nil
    for _, P in ipairs(S.panels) do
        local W = P.nv
        if W and W.build then
            show(W.lay, page ~= "backer")
            if page == "backer" and opt("CouchBackerNative", true) ~= false then
                if not W.sponsorTried then
                    W.sponsorTried = true
                    local ok, err = pcall(V.buildBacker, P)
                    if not ok then
                        if U.ok(W.sponsorBox) then pcall(function() W.sponsorBox:RemoveFromParent() end) end
                        W.sponsor, W.sponsorBox, W.innerChip = nil, nil, nil
                        U.warn(TAG, "#78 P%s's BACKER INFO page not built (%s): the plate instead", tostring(P.pnum),
                            tostring(err))
                    end
                elseif U.alive(W.sponsor) then
                    local ok, err = pcall(V.fillBacker, P)
                    if not ok then U.warn(TAG, "#78 P%s's BACKER INFO refill failed: %s", tostring(P.pnum), tostring(err)) end
                end
            end
            local native = page == "backer" and U.alive(W.sponsor)
            show(W.sponsorBox, native)
            if U.ok(W.sponsor) then show(W.sponsor, native) end
            for _, t in pairs(W.backer or {}) do show(t, page == "backer" and not native) end
            if info and W.backer and not native then
                -- couch-fix21 (#90): his own backer on the plate too (the team's when he has none)
                local mine = nil
                pcall(function()
                    local BK = U.mod("couchbacker")
                    local bk = P.ctrlId ~= nil and BK.ensure(P.ctrlId, P.pnum, "backer plate") or nil
                    local def = bk and BK.contract(bk.contract)
                    if def then
                        local planet = CR().nodeInfo()
                        local r = BK.planetRec(bk, planet, BK.liveTarget(bk.contract, planet))
                        mine = { name = BK.nameOf(bk.sponsor), contract = string.format("%s  %d/%d %s", def.text,
                            math.floor(tonumber(r.progress) or 0), math.floor(tonumber(r.target) or 0), def.units) }
                    end
                end)
                setText(W.backer.title, "BACKER")
                setText(W.backer.name, string.upper((mine or info).name))
                setText(W.backer.contract, (mine or info).contract)
                setText(W.backer.note, mine and ("P" .. tostring(P.pnum) .. "'S OWN CONTRACT")
                    or "P1'S RUN CONTRACT - THE TEAM'S BACKER (READ-ONLY)")
            end
        end
    end
    if page == "backer" then
        U.log(TAG, "VIEW BUILD on the BACKER tab: every guest area shows his own backer (P1's run contract: %s)", info.name)
    else
        U.log(TAG, "VIEW BUILD back on the BUILD tab: every guest area shows his own build")
    end
end

-- NOTE 11 (Jules: "I feel P2 is never getting the option to spend their money"): while a run map is up and no split
-- is open, every guest can open HIS shop: his pad's A on an invisible button kept focused for his Slate user (the
-- proven guest technique: while couch.lua swaps the ids his PlayerInput reads nothing, so a Y on the map cannot be read;
-- his A reaches no native screen there - the map's actions are its owner's). A game-style hint under his credits chip:
-- "(A) SHOP". P1 is never blocked: his pad keeps driving the map; when he launches an event the map goes and the shop
-- closes (purchases are saved at once).
local PILL_OFF = { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.9 }
-- the GARAGE hint exists: cfg.CouchGarage and the guest-garage data (custdata.lua) loaded
local function garageWanted()
    if opt("CouchGarage", true) == false then return false end
    local ok, G = pcall(U.mod, "garage")
    return ok and type(G) == "table" and G.supported(0) == true
end
-- the focused hint of a guest drawn in AMBER (his A opens that one), the other dark
local function pillFocus(ctrlId)
    local p = LAUNCH.pills[ctrlId]
    if not p then return end
    local on = LAUNCH.on[ctrlId] or "shop"
    for k, img in pairs(p) do
        if U.ok(img) then
            local c = (k == on and p.garage) and AMBER or PILL_OFF
            pcall(function() img:SetColorAndOpacity(lin({ R = c.R, G = c.G, B = c.B, A = c.A or 0.9 })) end)
        end
    end
end

-- fix16 bug 7 (live: "(A) SHOP" under P1's chip): the hint went under his chip of couch's credits row, but the launcher
-- can come up before that row (log: hint at 14:13:42.68, "credits chip up" at 42.80): without his rect it fell back to
-- the right edge = under P1's native chip, and was never moved. Now the hint follows his rect every launcher tick
-- (M.followHints); the fallback spot is only used until the row exists. pure: -> x, y (host units)
function M.hintSpot(rects, pnum, i)
    local w = 210
    local r = rects and rects[pnum]
    if r and r.x and r.w then return r.x + r.w - w, (r.y or 78) + (r.h or 104) + 14 end
    return 3706 - w - ((i or 1) - 1) * (w + 20), 200
end

local function followHints()
    local rects = nil
    pcall(function() rects = U.mod("couch")._chip().rects end)
    if not rects then return 0 end
    local moved = 0
    for _, sp in pairs(LAUNCH.spots or {}) do
        local x, y = M.hintSpot(rects, sp.pnum, sp.i)
        if math.abs(x - sp.x) > 1 or math.abs(y - sp.y) > 1 then
            sp.x, sp.y = x, y
            for _, it in ipairs(sp.slots) do
                pcall(function() it.s:SetPosition({ X = x + it.dx, Y = y + it.dy }) end)
            end
            moved = moved + 1
            U.log(TAG, "P%s's SHOP hint moved under his chip (%d,%d)", tostring(sp.pnum), math.floor(x), math.floor(y))
        end
    end
    return moved
end
M._followHints = followHints
M._launchSpots = function() return LAUNCH.spots end

local function launcherBuild(gl)
    local H = M.newHost()
    pcall(function() H.host:SetVisibility(VIS.SelfHitTestInvisible) end)
    local rects = nil
    pcall(function() rects = U.mod("couch")._chip().rects end)
    local gtex = nil
    pcall(function() gtex = texOf(U.mod("theme").glyph("A")) end)
    local hints = {}
    -- FINDING #10: SHOP (cfg.CouchMapGuestShop) and GARAGE (cfg.CouchMapGuestGarage) hints each behind a switch; with
    -- the garage alone the one hint is GARAGE
    local shopOn = opt("CouchMapGuestShop", false) == true
    local garageOn = garageWanted() and opt("CouchMapGuestGarage", false) == true
    LAUNCH.only = (not shopOn and garageOn) and "garage" or nil
    if not shopOn then garageOn = false end
    for i, g in ipairs(gl) do
        local b = ghostButton(H.tree, H.cv, 4 + (i - 1) * 12, 4, 8, 8)
        LAUNCH.btns[g.ctrlId], LAUNCH.prevA[g.ctrlId], LAUNCH.focusAt[g.ctrlId] = b, true, 0
        LAUNCH.on[g.ctrlId] = LAUNCH.only or "shop"
        -- the hint: the header backer pill, the pad's A, "SHOP", under his chip of the credits row
        local x, y = M.hintSpot(rects, g.pnum, i)
        local w, h = 210, 64
        local slots = {}
        local function at(cv, wd, dx, dy, sw, sh, z)
            local sl = place(cv, wd, x + dx, y + dy, sw, sh, z)
            slots[#slots + 1] = { s = sl, dx = dx, dy = dy }
            return sl
        end
        local shopPill = pillImage(H.tree, CHIP_PILL_MAT, PILL_OFF)
        at(H.cv, shopPill, 0, 0, w, h, 2)
        LAUNCH.pills[g.ctrlId] = { shop = shopPill }
        -- garage.lua: "GARAGE" left of his SHOP hint, its own invisible button; his D-pad moves between the two
        if garageOn then
            local gb = ghostButton(H.tree, H.cv, 4 + (i - 1) * 12, 16, 8, 8)
            if gb then
                LAUNCH.gbtns[g.ctrlId] = gb
                navTo(b, NAV.Left, gb); navTo(gb, NAV.Right, b)
                for _, d in ipairs({ NAV.Up, NAV.Down, NAV.Next, NAV.Previous }) do navTo(b, d, nil); navTo(gb, d, nil) end
                navTo(b, NAV.Right, nil); navTo(gb, NAV.Left, nil)
                local gw = 250
                local gdx = -gw - 14
                local gp = pillImage(H.tree, CHIP_PILL_MAT, PILL_OFF)
                at(H.cv, gp, gdx, 0, gw, h, 2)
                LAUNCH.pills[g.ctrlId].garage = gp
                local gt = text(H.tree, 30, PAPER, FONT_BODY)
                setText(gt, "GARAGE")
                local gs = at(H.cv, gt, gdx + gw / 2, h / 2, nil, nil, 3)
                pcall(function() gs:SetAlignment({ X = 0.5, Y = 0.5 }) end)
            end
        end
        pillFocus(g.ctrlId)
        if gtex then
            local gi = mk(IMAGE, H.tree)
            if gi then
                pcall(function() gi:SetBrushFromTexture(gtex, false) end)
                pcall(function() gi:SetVisibility(VIS.HitTestInvisible) end)
                at(H.cv, gi, 18, 10, 44, 44, 3)
            end
        end
        local t = text(H.tree, 30, PAPER, FONT_BODY)
        setText(t, (gtex and "" or "(A) ") .. (LAUNCH.only == "garage" and "GARAGE" or "SHOP"))
        local sl = at(H.cv, t, (gtex and 76 or 22), h / 2, nil, nil, 3)
        pcall(function() sl:SetAlignment({ X = 0, Y = 0.5 }) end)
        LAUNCH.spots[g.ctrlId] = { x = x, y = y, slots = slots, pnum = g.pnum, i = i }
        hints[#hints + 1] = string.format("P%d at %d,%d", g.pnum, math.floor(x), math.floor(y))
    end
    H.host:AddToViewport((tonumber(opt("CouchPanelZ", 1000)) or 1000) - 6)
    pcall(function() U.mod("couchroot").exclude(H.host) end)
    LAUNCH.host, LAUNCH.H = H.host, H
    U.log(TAG, "guests' own shop: (A) SHOP hint up on the run map (%s)%s", table.concat(hints, ", "),
        garageOn and "; GARAGE hint beside it" or "")
    parkSync("own-shop launcher up")
end

-- -> the guest who pressed (his entry of gl) or nil
local function launcherTick(gl, now)
    local key = {}
    for _, g in ipairs(gl) do key[#key + 1] = tostring(g.ctrlId) end
    key = table.concat(key, ",")
    if LAUNCH.host and (LAUNCH.key ~= key or not U.alive(LAUNCH.host)) then launcherClose("guests changed") end
    if not LAUNCH.host then
        local ok, err = pcall(launcherBuild, gl)
        if not ok then U.logEvery("cp.launch", 10000, TAG, "shop launcher not built: %s", tostring(err)); launcherClose(); return nil end
        LAUNCH.key = key
    end
    followHints()
    for _, g in ipairs(gl) do
        local b = LAUNCH.btns[g.ctrlId]
        local gb = LAUNCH.gbtns[g.ctrlId]
        local pc = padPC(g.ctrlId)
        if U.ok(b) and U.ok(pc) then
            local onShop = padHasFocus(b, g.ctrlId, pc)
            local onGarage = (not onShop) and U.ok(gb) and padHasFocus(gb, g.ctrlId, pc)
            LAUNCH.miss = LAUNCH.miss or {}
            if onShop or onGarage then LAUNCH.miss[g.ctrlId] = 0 end
            -- a refocus that never reads back as held (unreadable focus): every 250 ms after 10 in a row, not every tick
            local gap = ((LAUNCH.miss[g.ctrlId] or 0) > 10) and 250 or LAUNCH_REFOCUS_MS
            if onShop or onGarage then
                local on = onGarage and "garage" or "shop"
                if LAUNCH.on[g.ctrlId] ~= on then LAUNCH.on[g.ctrlId] = on; pillFocus(g.ctrlId) end
            elseif now - (LAUNCH.focusAt[g.ctrlId] or 0) >= gap then
                LAUNCH.miss[g.ctrlId] = (LAUNCH.miss[g.ctrlId] or 0) + 1
                -- (couch-livefix iii) LIVE 2026-10-16 (sp-01..03, swap ON on the paddock event map): P2's A on his lit
                -- (A) SHOP hint PICKED P1's NODE - his Slate user's focus was on the shared map (CommonUI focuses a
                -- guest-owned screen for its owner's PHYSICAL pad = his), and a parked pad's Slate accept clicks the
                -- focused node. His hint must hold his pad's focus whenever it is up: taken back at the next FAST tick
                -- (was 250 ms + couch.withPadId's 500 ms rate limit: a window his A fell into), forced through the
                -- park's rate limit.
                LAUNCH.focusAt[g.ctrlId] = now
                local ok = padSetFocus((LAUNCH.on[g.ctrlId] == "garage" and U.ok(gb)) and gb or b, g.ctrlId, pc, true)
                LAUNCH.lost = (LAUNCH.lost or 0) + 1
                U.logEvery("cp.launch.lost" .. tostring(g.ctrlId), 5000, TAG,
                    "P%s's pad focus was off his SHOP / GARAGE hint (on a shared screen?): taken back (%s, %d so far)",
                    tostring(g.pnum), ok and "ok" or "failed", LAUNCH.lost)
            end
            local pr = false
            pcall(function() pr = b:IsPressed() == true end)
            if not pr and U.ok(gb) then pcall(function() pr = gb:IsPressed() == true end) end
            local was = LAUNCH.prevA[g.ctrlId]
            LAUNCH.prevA[g.ctrlId] = pr
            if pr and not was then return g, LAUNCH.only or LAUNCH.on[g.ctrlId] or "shop" end
        end
    end
    return nil
end

-- FINDING #4 (garagenative's offer after P1's own paddock garage): "P2: PRESS A FOR YOUR GARAGE" / "B: NO THANKS"
-- under the guest's credits chip (the launcher hint's place and look). Display only: garagenative reads his A / B.
local OFFERH = { host = nil }
function M.garageOfferClose()
    local h = OFFERH.host
    OFFERH.host = nil
    if h and U.alive(h) then pcall(function() h:RemoveFromParent() end) end
end
function M.garageOfferShow(g, line1, line2)
    M.garageOfferClose()
    local H = M.newHost()
    pcall(function() H.host:SetVisibility(VIS.HitTestInvisible) end)
    local rects = nil
    pcall(function() rects = U.mod("couch")._chip().rects end)
    local w, h = 900, 64
    local x, y = M.hintSpot(rects, g.pnum, 1)
    x = math.max(40, x + 210 - w)
    local pill = pillImage(H.tree, CHIP_PILL_MAT, AMBER)
    place(H.cv, pill, x, y, w, h, 2)
    local t1 = text(H.tree, 30, INKD, FONT_BODY)
    setText(t1, line1)
    local s1 = place(H.cv, t1, x + 24, y + h / 2, nil, nil, 3)
    pcall(function() s1:SetAlignment({ X = 0, Y = 0.5 }) end)
    if line2 then                                         -- couch-fix74: the standing offer has one line only
        local pill2 = pillImage(H.tree, CHIP_PILL_MAT, PILL_OFF)
        place(H.cv, pill2, x + w - 320, y + h + 10, 320, h, 2)
        local t2 = text(H.tree, 30, PAPER, FONT_BODY)
        setText(t2, line2)
        local s2 = place(H.cv, t2, x + w - 300, y + h + 10 + h / 2, nil, nil, 3)
        pcall(function() s2:SetAlignment({ X = 0, Y = 0.5 }) end)
    end
    H.host:AddToViewport((tonumber(opt("CouchPanelZ", 1000)) or 1000) - 6)
    pcall(function() U.mod("couchroot").exclude(H.host) end)
    OFFERH.host = H.host
    OFFERH.text = { line1, line2 }
    return true
end
function M.garageOfferText() return OFFERH.host and OFFERH.text or nil end

-- FINDING #11: the compact garage only as the FALLBACK of a native turn that cannot start (paddock: no run map under
-- it - the split is not tied to a map screen, it closes when every guest is DONE)
function M.garageCompact(gl, why)
    if S.open then return false end
    local list = {}
    for _, g in ipairs(gl or {}) do
        local arch = CR().archOf(g.ctrlId, g.pnum)
        list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, arch = arch,
                            rows = U.mod("garage").rows(g.pnum, arch) }
    end
    if #list == 0 then return false end
    U.log(TAG, "compact garage for %d guest(s) (%s)", #list, tostring(why))
    open("garage", nil, list)
    S.garageFree = S.open or nil
    return S.open == true
end

-- Live 2026-10-15 (final): after the post-race rewards the map is the ACTIVE slot of the holder's WS_ScreenSwitcher,
-- but the Rewards_Layout of an earlier slot stays activated and visible -> the guest launcher never came up on the
-- post-race map. A map that is its switcher's active widget is on top: rewards then do not block.
local function mapOnTop(map)
    local top = false
    pcall(function()
        local p = map:GetParent()
        if not U.ok(p) then return end
        local aw = p:GetActiveWidget()
        top = U.ok(aw) and U.key(aw) == U.key(map)
    end)
    return top
end

local SCAN_PHASES = { OTHER = true, POSTRACE = true }

function M.fastTick()
    if opt("CouchPanel", true) == false then return end
    -- world changes: no widget call at all (couch.lua's quiet window; dying widgets crash UFunction calls)
    local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
    if okQ and q == true then return end
    -- couch-rewards2 STEP 2: no guest pad's focus inside P1's reward screens (couchfence.lua)
    if St.phase == "POSTRACE" then
        local okF, F = pcall(require, "couchfence")
        if okF and type(F) == "table" then U.try(TAG, F.tick) end
    end
    -- FINDING #7: P1's post-race over with a guest's reward still pending (after a reward screen was up)
    if S.rewardSeenAt and St.phase ~= "POSTRACE" and not S.open then U.try(TAG, rewardLeft, "phase " .. tostring(St.phase)) end
    if not SCAN_PHASES[St.phase] then
        if S.open then close("phase " .. tostring(St.phase)) end
        return
    end
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if not (okC and couch == true) and not S.debug then
        if S.open then close("couch rules off") end
        return
    end
    local now = St.nowMs()
    if not S.open then
        if S.debug then return end
        -- NOTE 11: a guest opens HIS shop from the run map (polled every tick: a press is short)
        if LAUNCH.host or now - S.lastScan >= 300 then
            local gl0 = guests()
            -- FINDING #10 (Jules 2026-10-17: unequal, the solo campaign has no shop on the map): the run-map hints only
            -- with cfg.CouchMapGuestShop / CouchMapGuestGarage (both false by default)
            local hints = opt("CouchGuestShop", true) ~= false
                and (opt("CouchMapGuestShop", false) == true or opt("CouchMapGuestGarage", false) == true)
            local map = (#gl0 > 0 and hints) and findNative(MAP_MATCH) or nil
            local other = map and (((not mapOnTop(map)) and findNative(REWARD_MATCH)) or findNative(SHOP_MATCH)
                                   or findNative(MYST_MATCH)) or nil
            -- garagenative.lua: during a guest's turn in the game's garage the run map's overview stays activated under
            -- it; the launcher must not take his pad (live 2026-10-15: his D-pad moved the GARAGE / SHOP hint)
            local okG, turn = pcall(function() return U.mod("garagenative").active() end)
            if okG and turn == true then
                if LAUNCH.host then launcherClose("guest garage turn") end
                map = nil
            end
            -- a pause menu / modal over the map (couch.menuOver): the hint collapses, no focus / press handling
            local over = false
            if map and not other then
                local okM, m = pcall(function() return U.mod("couch").menuOver() end)
                over = okM and m == true
                launcherHide(over)
            end
            if map and not other and over then
                return
            elseif map and not other then
                local who, which = launcherTick(gl0, now)
                if who and which == "garage" then
                    launcherClose("P" .. tostring(who.pnum) .. " opens his garage")
                    -- garagenative.lua (cfg.CouchGarageNative): his turn in the game's own full-screen garage
                    local okN, native = pcall(function()
                        return U.mod("garagenative").start(who, CR().archOf(who.ctrlId, who.pnum))
                    end)
                    if okN and native == true then return end
                    local list = {}
                    for _, g in ipairs(gl0) do
                        local arch = CR().archOf(g.ctrlId, g.pnum)
                        list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, arch = arch,
                                            rows = U.mod("garage").rows(g.pnum, arch) }
                    end
                    U.log(TAG, "P%s opens his garage from the run map", tostring(who.pnum))
                    open("garage", map, list)
                    return
                end
                if who then
                    launcherClose("P" .. tostring(who.pnum) .. " opens his shop")
                    local list = {}
                    for _, g in ipairs(gl0) do
                        local p = CR().ensure(g.ctrlId, g.pnum)
                        list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc,
                                            rows = CR().personalShop(g.ctrlId), lo = p.lo }
                    end
                    U.log(TAG, "P%s opens his own shop from the run map", tostring(who.pnum))
                    S.vendor = false
                    open("pshop", map, list)
                    return
                end
            elseif LAUNCH.host then
                launcherClose("no run map")
            end
        end
        if now - S.lastScan < 300 then return end
        S.lastScan = now
        local gl = guests()
        if #gl == 0 then return end
        local ps = {}
        for _, g in ipairs(gl) do ps[#ps + 1] = CR().ensure(g.ctrlId, g.pnum) end
        local rewards = findNative(REWARD_MATCH)
        local pending = false
        for _, p in ipairs(ps) do if p.offerPending then pending = true end end
        -- FINDING #7: the wait clock lives for the whole reward flow (a stage switch blinks every "Reward" screen out)
        if not pending then rewardReset() end
        local flowEnd = nil
        if pending and not rewards and S.rewardSeenAt then
            S.rewardGoneAt = S.rewardGoneAt or now
            local gone = now - S.rewardGoneAt
            local mapUp = findNative(MAP_MATCH) ~= nil
            if (mapUp and gone >= REWARD_FLOW_END_MS) or gone >= REWARD_FLOW_LOST_MS then
                flowEnd = string.format("%s, %d ms after the last reward screen", mapUp and "run map up" or "no reward screen", math.floor(gone))
            end
        elseif rewards then
            S.rewardGoneAt = nil
        end
        -- couch-rewards2: guests with their own flow do not wait for P1's round (their stages are their own)
        local allFlow = pending
        for i, p in ipairs(ps) do
            if p.offerPending then
                local okF, f = pcall(function() return CR().flow(gl[i].ctrlId) end)
                if not (okF and f) then allFlow = false end
            end
        end
        -- (P1's flow without any reward screen - DidEventGenerateRewards false - with a guest flow pending: his own
        -- flow opens on the run map)
        if allFlow and not rewards and not flowEnd and findNative(MAP_MATCH) ~= nil then
            flowEnd = "no reward screen of P1's: his own flow on the run map"
        end
        if pending and ((rewards and (allFlow or rewardReady(now))) or flowEnd) then
            local kind, noRound = S.rewardStageKind, S.rewardNoRound
            if flowEnd then
                U.warn(TAG, "P1's reward flow ended without a round the guests could follow (%s): their reward areas open now",
                    flowEnd)
            end
            rewardReset()
            local list = {}
            for i, g in ipairs(gl) do
                local p, rows, flow = ps[i], nil, nil
                if p.offerPending then
                    p.offerPending = nil
                    local okF, f, cur = pcall(function() return CR().flow(g.ctrlId) end)
                    flow = (okF and f and cur and opt("CouchRewardFlow", true) ~= false and opt("CouchPanelNative", true) ~= false)
                        and true or nil
                    if not flow then rows = CR().makeOffer(g.ctrlId, kind, noRound) end
                end
                list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, rows = rows, lo = p.lo, flow = flow }
            end
            open("reward", rewards, list)
            return
        end
        -- couch-fix21 (#90, Jules 2026-10-18: per-player backers): P1's CHOOSE A BACKER CONTRACT / his planet check-in ->
        -- every guest's own (couchbackerui.lua), once the screen showed its offers for M.MYST_SETTLE_MS
        if opt("CouchBackers", true) ~= false then
            local BU = require("couchbackerui")
            -- couch-fix42: a plain find, so it matches the screen AND its content WBP_SponsorSelect_Content_C - live the
            -- content is the only one activated (couch.activeScreens): couchbackerui.offers reads either one
            local sel = findNative({ "WBP_SponsorSelect_C" })
            if sel and not S.backerVisited and BU.offers(sel) then
                local k = U.key(sel)
                if S.backerSeenKey ~= k then
                    S.backerSeenKey, S.backerSeenAt = k, now
                    U.log(TAG, "backer screen up (%s): the guests' own backer choice opens once it has settled (%d ms)",
                        U.className(sel), M.MYST_SETTLE_MS)
                elseif now - (S.backerSeenAt or now) >= M.MYST_SETTLE_MS then
                    S.backerVisited = true
                    local list = {}
                    for i, g in ipairs(gl) do
                        list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc,
                                            rows = { { rkind = "backer" } }, lo = ps[i].lo }
                    end
                    open("backer", sel, list)
                    return
                end
            end
            if not sel then S.backerVisited, S.backerSeenKey, S.backerSeenAt, S.backerNoOffers = nil, nil, nil, nil end
            -- couch-fix42: a backer screen whose offers never read was silent (live A4): said once per screen
            if sel and not S.backerVisited and S.backerSeenKey ~= U.key(sel) then
                local k = U.key(sel)
                if S.backerNoOffers == nil or S.backerNoOffers.k ~= k then S.backerNoOffers = { k = k, at = now }
                elseif not S.backerNoOffers.said and now - S.backerNoOffers.at >= 2000 then
                    S.backerNoOffers.said = true
                    U.warn(TAG, "backer screen %s up 2 s with no offers read: the guests' own backer choice cannot open",
                        U.className(sel))
                end
            end
            local ci = findNative({ "WBP_SponsorCheckIn_C" })
            if ci and not S.checkinVisited then
                S.checkinVisited = true
                local list = {}
                for i, g in ipairs(gl) do
                    list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc,
                                        rows = { { rkind = "backer" } }, lo = ps[i].lo }
                end
                open("checkin", ci, list)
                return
            end
            if not ci and not findNative({ "WBP_SponsorCheckinBonus_C" }) then S.checkinVisited = nil end
        end
        -- NOTE 10: a mystery encounter (its list filled = P1's screen activated)
        local myst = findNative(MYST_MATCH)
        if myst and not S.mystVisited then
            local inter = nil
            pcall(function() inter = myst.MysteryInteraction end)
            if not U.ok(inter) then
                pcall(function() inter = U.giSubsystem("NarrativeContextSubsystem"):GetCurrentMysteryInteraction() end)
            end
            -- #67b (crash_2026_10_18_03_57_20, tester #4): the game died in this scan's FIRST read of the outcomes, as
            -- the paddock's mystery screen came up after a seamless race -> paddock travel (the faulting frames: the
            -- ResultFavours soft-pointer element read of couchrun.outcomeData, its FString {null, garbage length}).
            -- The same screen read fine on a fresh load. The outcomes are read only once the screen has shown the
            -- SAME interaction for M.MYST_SETTLE_MS (two scans), never on the tick it first appears.
            -- FINDING #111 (crash_2026_10_18_10_24_48, MYST_108, build 04d50fd): the settle did NOT prevent it - the
            -- read crashed at +600 ms, same stack. The cause is UE4SS's TSoftObjectPtr layout (it reads the path 8
            -- bytes past each 0x28-byte element), not a half-built outcome: couchrun no longer reads any ResultFavours
            -- element (favours from mystdata). The settle stays (cheap; the screen's list is filled by then).
            local ready = false
            if U.ok(inter) then
                local k = U.key(inter)
                if S.mystSeenKey ~= k then
                    S.mystSeenKey, S.mystSeenAt = k, now
                    U.log(TAG, "mystery screen up (%s): the guests' choices are read once it has settled (%d ms)",
                        U.objName(inter), M.MYST_SETTLE_MS)
                elseif now - (S.mystSeenAt or now) >= M.MYST_SETTLE_MS then
                    ready = true
                end
            end
            if ready then
                S.mystVisited, S.mystInter, S.mystName = true, inter, U.objName(inter)
                local list = {}
                for i, g in ipairs(gl) do
                    list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc,
                                        rows = CR().mysteryRows(g.ctrlId, inter), lo = ps[i].lo }
                end
                open("mystery", myst, list)
                return
            end
        end
        if not myst then S.mystVisited, S.mystInter, S.mystSeenKey, S.mystSeenAt = nil, nil, nil, nil end
        local shop = findNative(SHOP_MATCH)
        if V.afterRel then                                                                      -- AUTO-157
            if shop and not S.shopVisited then
                if V.comebackTick(now) then return end
            else
                U.try(TAG, V.comebackHud, now)
            end
        end
        local ready, listOnly = true, false
        if shop and not S.shopVisited then ready, listOnly = shopReady(shop, now) end
        if shop and not S.shopVisited and ready then
            S.shopVisited, S.shopSeenAt = true, nil
            if isVendor(shop) then
                -- FINDING #20: the Scrap Dealer is its own kind (repair + maybe a shop), never a plain shop
                S.vendor, S.vendorShop = true, M.vendorHasShop(shop)
                local list = {}
                for i, g in ipairs(gl) do
                    list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, rows = M.landingRows(),
                                        lo = ps[i].lo }
                end
                open("vendor", shop, list)
            else
                -- couch-shopstock: at HIBI'S SHOP each guest gets the SAME kind of shop as P1's (his planet stock of
                -- parts, RESTOCK, the PACKS column: couchrun.personalShop)
                local list = {}
                for i, g in ipairs(gl) do
                    list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc,
                                        rows = CR().personalShop(g.ctrlId), lo = ps[i].lo }
                end
                S.vendor = false
                open("shop", shop, list, listOnly)
            end
        end
        if not shop then S.shopVisited, S.shopSeenAt, S.shopWaitLogged = nil, nil, nil end
        -- VIEW BUILD: P1's player menu on its build page -> every guest's build in his area
        if not shop and opt("CouchBuildView", true) ~= false then
            local bp = buildPage()
            if bp then
                local list = {}
                for i, g in ipairs(gl) do
                    list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, rows = {}, lo = ps[i].lo }
                end
                open("build", bp, list)
            end
        end
        return
    end
    -- open: follow P1's native screen (the switcher moves hub -> credits -> CHOOSE AN UPGRADE); when it is gone,
    -- close once every guest is done (an unpicked reward keeps the guest areas up, P1's screen restored)
    if now - S.nativeAt >= 300 then
        S.nativeAt = now
        if S.kind == "build" then
            local pm, page = playerMenuPage()
            setNative(page and pm or nil)
            if page then U.try(TAG, buildTab, page, pm) end
        else setNative(findNative((S.kind == "shop" and SHOP_MATCH) or (S.kind == "mystery" and MYST_MATCH)
            or (S.kind == "vendor" and V.VENDOR_MATCH)
            or (S.kind == "backer" and require("couchbackerui").SELECT_MATCH)
            or (S.kind == "checkin" and require("couchbackerui").CHECKIN_MATCH)
            or ((S.kind == "pshop" or S.kind == "garage") and MAP_MATCH) or REWARD_MATCH)) end
    end
    -- couch-fix39: the guests' team mystery effects waiting for P1's pick go out once his outcome shows (no stacking)
    if S.kind == "mystery" then U.try(TAG, function() CR().mystTeamTick() end) end
    if S.kind == "mystery" and not S.debug then U.try(TAG, V.mysteryNoChoiceTick, now) end    -- couch-fix54 (AUTO-132)
    -- hotplug (couchsim hotplug rewards / mystery 3): a guest unplugged mid-split (RemoveLocalPlayer) kept his area -
    -- never done, so the split stayed up after P1's screen had gone. His area is marked done and hidden; the others go on.
    if now - (S.guestAt or 0) >= 300 then
        S.guestAt = now
        local here = {}
        for _, g in ipairs(guests()) do here[g.ctrlId] = g.pnum end
        for _, P in ipairs(S.panels) do
            if not P.gone and not P.mirror and P.ctrlId ~= nil and here[P.ctrlId] ~= P.pnum then
                P.gone, P.done = true, true
                show(P.box, false)
                U.log(TAG, "P%s left the game: his %s area closed, the other areas go on", tostring(P.pnum), tostring(S.kind))
            end
        end
    end
    if S.kind == "reward" and not S.debug and opt("CouchRewardDoneClose", true) ~= false then
        local act, P = M.doneAction(S.kind, S.panels, S.n, S.p1Left)
        if act == "closeOwn" then
            M.closeOwn(P, "every reward collected: no waiting for P1 (#93)")
            act = M.doneAction(S.kind, S.panels, S.n, S.p1Left)
        end
        if act == "close" then close("every guest done: P1's reward screen full screen again (#93)"); return end
        if act == "relayout" then U.try(TAG, M.relayout, "a guest done (#93)"); return end
    end
    if S.kind == "reward" and not S.debug then
        if now - (S.mapAt or 0) >= 300 then
            S.mapAt = now
            local mapUp = findNative(MAP_MATCH) ~= nil
            if mapUp then S.mapSince = S.mapSince or now else S.mapSince = nil end
        end
        if not S.p1Left and S.mapSince and now - S.mapSince >= REWARD_FLOW_END_MS then
            S.p1Left = true
            U.log(TAG, "P1's reward flow ended (the run map is up, %d ms): no guest waits for P1 any more (#83)",
                math.floor(now - S.mapSince))
            for _, P in ipairs(S.panels) do if not P.ownClosed then U.try(TAG, render, P) end end
        end
        U.try(TAG, V.mapHoldTick, now)                          -- fix32: P1's node pick waits for the guests
        local a = M.p1LeftAction(S.kind, S.p1Left, S.panels)
        if a == "close" then close("P1 on the run map, every guest done: the areas close with P1's reward flow"); return end
        if M.allClosedOwn(S.panels) then close("every guest closed his own reward area"); return end
    end
    if S.kind == "shop" or S.kind == "vendor" then U.try(TAG, V.backGuardTick, now) end  -- fix43: the native back off
    if S.hold then U.try(TAG, V.holdTick, now) end             -- #77: P1's leave held for the guests still shopping
    if not S.native and S.kind == "pshop" and not S.debug then close("P1 left the run map: his shop closed"); return end
    if S.kind == "pshop" and allDone() and not S.debug then close("his shop left"); return end
    if not S.native and S.kind == "garage" and not S.debug and not S.garageFree then close("P1 left the run map: garage saved"); return end
    if S.kind == "garage" and allDone() and not S.debug then close("garage done"); return end
    -- the scrap dealer: P1 moves between its landing / SHOP / REPAIR PARTS pages (one CSM state each): a short gap
    -- without any of them keeps the guests' areas (and where each one is); gone for V.VENDOR_GONE_MS = closed
    if S.kind == "vendor" and not S.debug then
        if S.native then
            S.vendorGoneAt = nil
        else
            S.vendorGoneAt = S.vendorGoneAt or now
            if now - S.vendorGoneAt >= V.VENDOR_GONE_MS then close("native screen closed"); return end
        end
    elseif not S.native and (allDone() or S.kind == "shop") and not S.debug then close("native screen closed"); return end
    -- our host is kept across ticks: gone (collected with its owner, a world change seen before phase's event) = close
    -- without touching its children (a call on a dead widget is a native AV that pcall cannot catch)
    if S.H and not U.alive(S.H.host) then close("panel host gone"); return end
    for _, P in ipairs(S.panels) do U.try(TAG, panelTick, P, now) end
    -- 4-way garage: each guest's 3D car (bay wants + vpreview's tick); a changed bay re-renders its area
    if S.kind == "garage" and S.open then
        local g = G4()
        if g then
            local okT, ch, keys = pcall(g.campaignTick, S.panels)
            if okT and ch and type(keys) == "table" then
                for _, P in ipairs(S.panels) do
                    if P.g4 and P.ctrlId ~= nil and keys[P.ctrlId + 1] then render(P) end
                end
            end
        end
    end
    local rt = root()
    if rt then rt.tick() end
end

---------------------------------------------------------------------------------------------------- tests (testcmd)
-- M.debugOpen(n): the reward areas NOW for the joined guests plus display-only mirrors up to n players (a mirror is
-- owned by local player 2 + k when one exists - a dormant 3rd local player - else by the first guest / P1); works solo
-- (a mirror of a starter offer). The native flow is not touched. M.debugClose() ends it.
local function starterRows()
    local rows = {}
    for s = 0, 2 do
        local st = PD and PD.STATS and PD.STATS[s]
        rows[#rows + 1] = { rkind = "stat", id = s, name = (st and st.name or ("STAT " .. s)) .. " +1", icon = st and st.large }
    end
    rows[#rows + 1] = { rkind = "skip", id = "skip", name = "SKIP REWARD", credits = 1000 }
    return rows
end

function M.debugOpen(n, kind)
    if S.open then close("debugOpen") end
    n = math.max(2, math.min(4, math.floor(tonumber(n) or 2)))
    local gl = guests()
    local lp = U.localPlayers()
    local list = {}
    for _, g in ipairs(gl) do
        if #list >= n - 1 then break end
        local p = CR().ensure(g.ctrlId, g.pnum)
        local rows = (kind == "shop") and CR().makeShop(g.ctrlId) or CR().makeOffer(g.ctrlId)
        list[#list + 1] = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, rows = rows, lo = p.lo }
    end
    local base = list[1]
    local lo0 = base and base.lo or nil
    if not lo0 then pcall(function() lo0 = U.mod("run").starter(arch() or 0, nil) end) end
    while #list < n - 1 do
        local k = #list + 1
        local owner = (lp[k + 1] and U.ok(lp[k + 1].pc)) and lp[k + 1].pc or (base and base.pc) or U.p1()
        local rows = {}
        for _, r in ipairs(base and base.rows or starterRows()) do rows[#rows + 1] = r end
        list[#list + 1] = { ctrlId = nil, pnum = k + 1, pc = owner, rows = rows, lo = lo0, mirror = true }
    end
    S.debug = true
    open(kind or "reward", findNative(kind == "shop" and SHOP_MATCH or REWARD_MATCH), list)
    return M.status()
end

function M.debugClose()
    if S.open then close("debugClose") end
    S.debug = nil
    return M.status()
end

-- Isolation probe (07 §7 spike 1): a rewards VM copy is built and its first item renamed; P1's live VM, the reward
-- picks left and the round index must not change. -> one line for test.out
function M.vmProbe()
    local cs = nil
    pcall(function() cs = FindFirstOf("CampaignSubsystem") end)
    local function snap()
        local t = { left = "?", ix = "?" }
        pcall(function() t.left = tostring(cs:GetNumberOfRewardsLeftToPick()) end)
        pcall(function() t.ix = tostring(cs.ActiveRun:GetCurrentNode().RewardRoundIx) end)
        return t
    end
    local p1 = p1VmKeys()
    local p1name = function()
        local s = "?"
        if not p1.found then return s end
        pcall(function()
            for _, e in ipairs(U.mod("couch").activeScreens()) do
                if e.cls == LAYOUT_CLS and not S.own[U.key(e.w)] then s = e.w.RewardsVM.Items[1].PlayerFacingName:ToString() end
            end
        end)
        return s
    end
    local b, nameB = snap(), p1name()
    local vm = nil
    local okV, errV = pcall(function() vm = vms():BuildRewardsVMForCurrentCampaignEvent() end)
    if not okV or not U.ok(vm) then return "vmProbe: no VM (" .. tostring(errV) .. ")" end
    local n = U.arrayCount(vm.Items)
    pcall(function() vm.Items[1].PlayerFacingName = U.ftext("COUCH PROBE") end)
    local a, nameA = snap(), p1name()
    return string.format("vmProbe: copy %s P1's (p1 layout %s), items %d, left %s->%s, roundIx %s->%s, P1 item1 '%s'->'%s'",
        (p1.rewards ~= 0 and U.key(vm) == p1.rewards) and "IS" or "is not", p1.found and "found" or "NOT found", n,
        b.left, a.left, b.ix, a.ix, nameB, nameA)
end

function M.isOwn(key) return S.own[key] == true end
function M.isOpen() return S.open == true end
function M.kind() return S.open and S.kind or nil end
-- #93: the split again for the guests still choosing (a done guest's area gone): the host is rebuilt for the new count
-- (couchroot re-lays P1's screen out); a guest's own flow comes back on his hub at his current stage (his collected
-- stages and picks are kept by couchrun), a mirror offer with its rows. No SKIP is booked (close(_, true)).
function M.relayout(why)
    if not S.open then return false end
    local kind, native = S.kind, S.native
    local list = {}
    for _, P in ipairs(S.panels) do
        if not (P.ownClosed or P.gone or P.mirror) then
            list[#list + 1] = { ctrlId = P.ctrlId, pnum = P.pnum, pc = P.pc, lo = P.lo, arch = P.arch,
                                rows = P.flowMode and {} or P.rows, flow = P.flowMode or nil }
        end
    end
    local n0 = S.n
    close(why, true)
    if #list == 0 then return true end
    open(kind, native, list)
    U.log(TAG, "%s split laid out again: %d -> %d player(s) (%s)", tostring(kind), n0, S.n, tostring(why))
    return true
end

function M._panels() return S.panels end           -- tools/test_couchpanel.lua
function M._act(P) act(P) end                       -- couchsim: a guest's A on his selected row

function M.status()
    local t = {}
    for _, P in ipairs(S.panels) do
        t[#t + 1] = string.format("P%s:%s sel %s%s%s", tostring(P.pnum), P.view, tostring(P.sel), P.done and " done" or "",
            P.mirror and " mirror" or "")
    end
    return string.format("couchpanel: %s %s n=%d native %s [%s]", S.open and "open" or "closed", tostring(S.kind), S.n,
        S.native and "shrunk" or "-", table.concat(t, ", "))
end

function M.init()
    St.on("phase", TAG, function(new)
        if S.open and (new == "LOADING" or new == "FRONTEND" or new == "TRANSIT") then close("phase " .. new) end
        if new == "LOADING" or new == "FRONTEND" then S.debug = nil end
    end)
    -- "leaving" runs before the old world is torn down: the panels and the shrunk native screen are released while alive
    St.on("leaving", TAG, function() S.debug = nil; if S.open then close("leaving") end end)
    St.on("world", TAG, function()
        local rt = root()
        if rt and S.open then pcall(rt.finish, "panel", false) end
        -- couch-fix21: a check-in he never collected is booked (no widget touched: couchbacker's data only)
        if S.open and S.kind == "checkin" then
            for _, P in ipairs(S.panels) do
                if P.backerMode and not P.done and not P.gone and P.ctrlId ~= nil then
                    U.try(TAG, require("couchbackerui").autoCollect, P, "world change")
                end
            end
        end
        S.open, S.H, S.panels, S.native, S.nativeKey, S.own, S.debug = false, nil, {}, nil, 0, {}, nil
    end)
end

---------------------------------------------------------------------------------------------------- shared kit
-- (additive) The widget helpers and the input technique for the other couch panels (couchprerun.lua), so every couch
-- panel looks and reads the guest's pad the same way.
M.kit = {
    mk = mk, lin = lin, show = show, place = place, text = text, setText = setText, setInk = setInk, solid = solid,
    fitSize = M.fitSize, setTextFit = M.setTextFit,
    texOf = texOf, groupDigits = groupDigits, pillImage = pillImage, tagInto = tagInto, chipAt = chipAt, chipRewire = chipRewire, chipFeed = chipFeed, CHIP_CLS = CHIP_CLS,
    padPC = padPC, padHasFocus = padHasFocus, padSetFocus = padSetFocus, padParked = padParked, IMAGE = IMAGE, BUTTON = { "/Script/UMG.Button" }, VIS = VIS, VW = VW, VH = VH,
    SCALE = SCALE, SIZEB = SIZEB, OVER = OVER, PAPER_TEX = PAPER_TEX, own = own, paperCover = paperCover,
    FONT_DISPLAY = FONT_DISPLAY, FONT_BODY = FONT_BODY,
    colours = { PAPER = PAPER, CREAM = CREAM, AMBER = AMBER, DEEP = DEEP, ROW = ROW, ROWF = ROWF, INKD = INKD,
                SAGE = SAGE },
}

-- couch-rewards2 (couchflow.lua): the native-view helpers a guest's own reward flow builds its views with
M.flowKit = {
    mk = mk, place = place, text = text, setText = setText, solid = solid, own = own, ownInside = ownInside,
    paperBackdrop = paperBackdrop, regionBox = regionBox, overlayAdd = overlayAdd, ghostButton = ghostButton,
    headerChip = headerChip, initBuild = initBuild, reapplyBuild = reapplyBuild, groupDigits = groupDigits,
    setEffect = setEffect, buildNative = buildNative, buildList = buildList, texOf = texOf,
    -- couch-fix21 (couchbackerui.lua): the guests' own backer moments
    navCards = navCards, navList = navList, cardFocus = cardFocus, native = function() return S.native end,
    OVER = OVER, SIZEB = SIZEB, CANVAS = CANVAS, VIS = VIS, VW = VW, VH = VH,
    colours = { AMBER = AMBER, INKD = INKD, DEEP = DEEP, CREAM = CREAM },
}

-- A full-screen host created for P1 (the build() technique): WBP_Background_Blur_C with its own children hidden, a
-- ScaleBox -> SizeBox(3840 x 2160) -> CanvasPanel. NOT added to the viewport (the caller fills it first).
-- -> {host, tree, cv} (raises on failure)
function M.newHost()
    local p1 = U.p1()
    if not U.ok(p1) then error("no P1") end
    local cls = U.class(HOST)
    if not U.ok(cls) then error("host class not loaded") end
    local host = U.WBL():Create(p1, cls, p1)
    if not U.ok(host) then error("host not created") end
    local tree = host.WidgetTree
    local root = tree.RootWidget
    pcall(function()
        for i = root:GetChildrenCount() - 1, 0, -1 do
            local c = root:GetChildAt(i)
            if U.ok(c) then c:SetVisibility(VIS.Collapsed) end
        end
    end)
    local sc = mk(SCALE, tree); pcall(function() sc:SetStretch(2) end)
    local sb = mk(SIZEB, tree); sb:SetWidthOverride(VW); sb:SetHeightOverride(VH)
    sc:AddChild(sb)
    local cv = mk(CANVAS, tree)
    sb:AddChild(cv)
    local slot = root:AddChildToOverlay(sc)
    pcall(function() slot:SetHorizontalAlignment(0); slot:SetVerticalAlignment(0) end)
    return { host = host, tree = tree, cv = cv }
end

return M
