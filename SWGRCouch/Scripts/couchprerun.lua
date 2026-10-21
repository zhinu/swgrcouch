-- couchprerun.lua: COUCH CAMPAIGN - the guests' own vehicle class and racer style at the start of a run (0.15).
-- Jules 2026-10-14: "Vehicle select - 2p shouldn't the screen split there as well?" / "loadout should be also split?".
-- A new run takes P1 through the native pre-run screens WBP_PreRun_VehicleSelect_C (Landspeeder / Speeder Bike / Skim
-- Speeder) and WBP_PreRun_LoadoutSelect_C (RACER STYLE grid, favors, START RUN, then P1's WBP_LoadoutConfirmation_C).
-- While one of them is up and the couch rules apply, the native screen is shrunk into P1's area (couchlayout: halves
-- for 2 players, quadrants for 3-4; P1's confirmation dialog too) and every joined guest gets a panel in his own area:
--   * vehicle: the 3 run classes (the native screen's own lock state:
--     WBP_PreRun_VehicleSelect_C:IsArchetypeUnlocked(VehicleArchetype, out IsUnlocked), re-read every 2 s), drawn in
--     the 4-way garage's area look with a REAL 3D car of the highlighted class ((9), cfg.CouchPreRunNative; the
--     compact tile strip is the fallback and keeps supplying the invisible input buttons either way);
--   * loadout: the racer styles of the native grid (its LoadoutVM.RacerStyles: RacerStyleVM.RacerStyle +
--     bIsLocked, the data the WBP_RacerStyleChoice_Btn_C tiles show; fallback the displayed tiles' RacerStyle +
--     GetIsEntryLocked), so a guest sees exactly P1's unlocked styles.
-- A guest moves with his D-pad and confirms with A (the panel shows READY); a pick goes to couchrun.choose (his class /
-- style -> a starter build for it; couch.patchGrid gives him that class, applyBuilds that build). P1 is never blocked:
-- when P1 leaves the screen first, a guest who is not READY keeps his current choice (the vehicle cursor only if he
-- moved it: untouched, he follows P1's class).
-- Input = couchpanel's proven technique: an invisible plain /Script/UMG.Button per tile, focused for the guest's Slate
-- user, polled with HasUserFocus / IsPressed (his PlayerInput key state does not update while couch.lua swaps the
-- pad ids). Scan rules: couch.activeScreens() only, U.alive before a UFunction on a native widget, nothing while
-- couch.isQuiet(). Any build error = no panel (the native flow is untouched).
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")
local L = require("couchlayout")

local TAG = "couchprerun"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function CP() return U.mod("couchpanel") end
local function CR() return U.mod("couchrun") end
local function couch() return U.mod("couch") end
local function G4() local ok, g = pcall(U.mod, "garage4"); return (ok and type(g) == "table") and g or nil end
local function G4UI() local ok, g = pcall(U.mod, "garage4ui"); return (ok and type(g) == "table") and g or nil end
local function rootMod() local ok, r = pcall(U.mod, "couchroot"); return (ok and type(r) == "table") and r or nil end
-- couch.lua's park (cfg.CouchSwapPark) follows the split at once (its own tick re-checks every 250 ms)
local function parkSync(why)
    local c = package.loaded["couch"]
    if type(c) == "table" and type(c.parkSync) == "function" then U.try(TAG, c.parkSync, why) end
end

local okPD, PD = pcall(require, "perkdata")
if not okPD or type(PD) ~= "table" then PD = nil end

local SCREENS = { WBP_PreRun_VehicleSelect_C = "vehicle", WBP_PreRun_LoadoutSelect_C = "style" }
local NAV = { left = 0, right = 1, up = 2, down = 3 }        -- EUINavigation
local RULE_STOP = 3                                          -- EUINavigationRule::Stop
local MAX_GUESTS = 3
-- #100: the guests' VEHICLE SELECT = the game's own screen, as its PARENT class (see nativeVehicleCopy)
local VSBASE = "/Game/Griffin/UI/Screens/Multiplayer/WBP_FE_BaseVehicleSelect.WBP_FE_BaseVehicleSelect_C"
local FAV_COLS = 5                                           -- #101: TV_Favours' columns (P1's grid, photo 2026-10-18)
local MAX_PICK = 40                                          -- #101: the favour grid's input buttons (AllFavours: ~20)

-- S.panels[i] = one guest's panel P {ctrlId, pnum, slot, tiles, sel, sel0, choice, ready, touched, prevA, focusAt,
-- toast, toastUntil, ...widgets}
local S = { open = false, kind = nil, native = nil, nativeKey = 0, n = 1, host = nil, items = nil, panels = {},
            shrunk = {}, lastScan = 0, lastLock = 0, failKey = nil }

---------------------------------------------------------------------------------------------------- the copies' activatables
-- couch-fix47 (live round 2 AUTO-122, 2026-10-18 13:25:12 / 14:13:13): a guest's native VEHICLE SELECT copy (the never
-- activated WBP_FE_BaseVehicleSelect_C) holds activatables of its own - its class list WBP_Vehicle_List_C and its
-- WBP_Party_Prompt_C - which ACTIVATE by themselves ~1.5 s after the copy is up (round 1 12:08:10 too: two lists, two
-- prompts in couch.activeScreens). couch.lua then took the copy's list for a guest-owned shared screen: the newest one
-- with a target, so (2P) "new shared screen" refocused the owner's user - P1's pad - into P2's copy (P1's VEHICLE
-- SELECT had no cursor, menubridge "no button holds his focus", the cursor watch never ran: the swapped screen was the
-- copy's list) and (4P) the swap moved to P2 ("pad ids SWAPPED (new owner) ... shared screen owner changed" 14:13:13)
-- while P1's screen was P4's. Every activatable inside a copy: bAutoActivate off, deactivated when it activated anyway,
-- and never listed by couch.activeScreens (M.isCopyWidget, as couchpanel's ownInside for its shop copy).
local COPY = { keys = {}, ws = {} }      -- keys[k] = true (the copies and every activatable inside), ws = the inner ones
function M.isCopyWidget(k) return COPY.keys[k] == true end

-- -> number of new inner activatables
local function quietCopy(root)
    if not U.ok(root) then return 0 end
    local rk, n = U.key(root), 0
    COPY.keys[rk] = true
    for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
        if U.ok(w) then
            local k = U.key(w)
            local inside = k ~= rk and COPY.keys[k] == true
            if not inside and k ~= rk then
                local x = w
                for _ = 1, 12 do
                    x = U.outerOf(x)
                    if not U.ok(x) then break end
                    if U.key(x) == rk then inside = true; break end
                end
            end
            if inside and not COPY.keys[k] then
                COPY.keys[k] = true
                COPY.ws[#COPY.ws + 1] = w
                n = n + 1
                pcall(function() w.bAutoActivate = false end)
            end
        end
    end
    return n
end

-- every inner activatable that activated anyway goes back to inactive (a handful of widgets)
local function deactivateCopies()
    local off = 0
    for _, w in ipairs(COPY.ws) do
        if U.alive(w) then
            local act = false
            pcall(function() act = w:IsActivated() == true end)
            if act then
                pcall(function() w:DeactivateWidget() end)
                off = off + 1
            end
        end
    end
    return off
end

-- the copies of the open split (vehicle: P.nv.scr, loadout: P.native.scr)
local function copyRoots()
    local out = {}
    for _, P in ipairs(S.panels or {}) do
        local r = (P.nv and P.nv.scr) or (P.native and P.native.scr)
        if U.ok(r) then out[#out + 1] = r end
    end
    return out
end

-- full walk at the open and for COPY_SCAN_MS after it (once a second), then only the known inner widgets
local COPY_SCAN_MS = 8000
local function copyTick(now)
    if now < (COPY.at or 0) then return end
    COPY.at = now + 1000
    local found = 0
    if now - (S.openAt or now) <= COPY_SCAN_MS then
        for _, r in ipairs(copyRoots()) do found = found + (quietCopy(r)) end
    end
    local off = deactivateCopies()
    if found > 0 or off > 0 then
        U.log(TAG, "guest copies: %d inner activatable(s) kept out of the shared screens%s", #COPY.ws,
            off > 0 and string.format(", %d deactivated (they activated by themselves)", off) or "")
    end
end

-- couch-fix47 (AUTO-122 LOADOUT, 13:59:15-14:00:55: 7x "P1's pad had no cursor ... re-given" on every move towards
-- FAVORS / START RUN): P1's shrunk native screen kept Slate's default Escape boundary, so the D-pad's geometric search
-- ran on past his own widgets into the guests' areas below / beside it, where every guest has visible (opacity 0.01)
-- invisible input buttons - the owner's focus (P1's pad) landed on one, nothing of his screen held it any more, and the
-- cursor watch put it back on the screen's default target (STUNT RUNNER). While the split is open the native screen's
-- root is a Stop boundary: Slate's search stays inside P1's screen (its rect = his area); Escape again at the close.
local RULE_ESCAPE = 0
local function p1Boundary(native, on)
    if not U.alive(native) then return false end
    local ok = pcall(function() native:SetAllNavigationRules(on and RULE_STOP or RULE_ESCAPE, U.fname("None")) end)
    return ok
end

---------------------------------------------------------------------------------------------------- native reads
-- IsArchetypeUnlocked(EVehicleArchetype, out bool IsUnlocked) on the live native screen -> true | false | nil
local function archUnlocked(native, arch)
    if not U.alive(native) then return nil end
    local out = {}
    local ok, r = pcall(U.callMethod, native, "IsArchetypeUnlocked", arch, out)
    if not ok then return nil end
    local v = out.IsUnlocked
    if v == nil and type(r) == "boolean" then v = r end
    if type(v) ~= "boolean" then return nil end
    return v
end

-- #102 (live 2026-10-18 09:50): ONLY P1 unlocks a class; a guest can never pick one P1's game reports locked. The
-- live screen's own IsArchetypeUnlocked (the check P1's screen uses) decides; unreadable = locked for the guests (the
-- Landspeeder excepted: the switch's literal true), the last value read is kept while the screen closes.
local function refreshLocks(native, items)
    local changed, unknown = false, 0
    for _, it in ipairs(items) do
        local v = archUnlocked(native, it.id)
        local lk = it.locked
        if v == nil then
            unknown = unknown + 1
            if not it.known then lk = it.id ~= 0 end
        else
            lk, it.known = not v, true
        end
        if it.locked ~= lk then it.locked = lk; changed = true end
    end
    if unknown > 0 then
        U.logOnce("couchprerun.lockunknown", TAG, "IsArchetypeUnlocked unreadable for %d class(es): locked for the guests "
            .. "(the Landspeeder excepted)", unknown)
    end
    return changed
end
M._refreshLocks = refreshLocks

local function vehicleItems(native)
    local V = U.mod("vehicles")
    local out = {}
    for _, cls in ipairs(V.CLASSES) do
        if cls.arch ~= 1 then                                -- the podracer is never a run vehicle
            local info = nil
            pcall(function() info = V.classInfo(cls) end)
            out[#out + 1] = { id = cls.arch, name = (info and info.name ~= "" and info.name) or cls.label,
                              desc = info and info.intro or "", image = V.classImage(cls), aspect = cls.aspect or 1.34,
                              locked = false }
        end
    end
    refreshLocks(native, out)
    return out
end

-- RacerStyle data asset -> perkdata STYLES key (CAM_Style_Ramjet_Lv2 -> Ramjet, Pvp_Style_Battling_FlameVent ->
-- BattlingFlameVent), else its BaseRacerStyle's; nil for the campaign's Default / Mentor / Null styles and pods.
local function styleKeyOf(rs, depth)
    if not U.ok(rs) then return nil, "" end
    local nm = ""
    pcall(function() nm = rs:GetFName():ToString() end)
    local k = nm:match("^CAM_Style_(.-)_Lv%d+$") or nm:match("^Pvp_Style_(.+)$") or nm:match("^CAM_Style_(.+)$")
    if k then k = k:gsub("_", "") end
    if k and PD and PD.STYLES and PD.STYLES[k] and PD.STYLES[k].pod ~= true then return k, nm end
    if (depth or 0) < 2 then
        local base = nil
        pcall(function() base = rs.BaseRacerStyle end)
        if U.ok(base) then
            local bk = styleKeyOf(base, (depth or 0) + 1)
            if bk then return bk, nm end
        end
    end
    return nil, nm
end
M.styleKeyOf = styleKeyOf

local function styleItems(native)
    local out, seen, skipped = {}, {}, {}
    local function add(rs, locked)
        local key, nm = styleKeyOf(rs)
        if not key then
            if nm ~= "" then skipped[#skipped + 1] = nm end
            return
        end
        -- couch-fix29: the rank of a campaign style asset (CAM_Style_<Key>_Lv<N>): the guest races the highest one the
        -- shared unlocks give (it.rank, handed to couchrun.choose)
        local rk = nil
        local okR, CSm = pcall(require, "camstyles")
        if okR and type(CSm) == "table" then rk = CSm.rankOf(nm) end
        local it = seen[key]
        if it then
            if not locked then
                it.locked = false                           -- one unlocked rank unlocks the style
                if rk and (it.rank == nil or rk > it.rank) then it.rank, it.asset = rk, nm end
            end
            return
        end
        local st = PD.STYLES[key]
        it = { id = key, name = st.name or key, desc = st.desc or "", image = st.icon, aspect = 1, locked = locked == true,
               asset = nm, rank = (locked ~= true) and rk or nil }
        seen[key] = it
        out[#out + 1] = it
    end
    pcall(function()
        local vm = native.LoadoutVM
        if not U.ok(vm) then return end
        local arr = vm.RacerStyles
        for i = 1, U.arrayCount(arr) do
            local svm = arr[i]
            if U.ok(svm) then
                local rs, lk = nil, false
                pcall(function() rs = svm.RacerStyle end)
                pcall(function() lk = svm.bIsLocked == true end)
                add(rs, lk)
            end
        end
    end)
    local src = "LoadoutVM"
    if #out == 0 and U.alive(native) then
        -- fallback: the tiles the grid displays (WBP_RacerStyleChoice_Btn_C: RacerStyle + GetIsEntryLocked)
        src = "grid tiles"
        pcall(function()
            local tv = native.Tile_RacerStyles
            if not U.alive(tv) then return end
            local arr = tv:GetDisplayedEntryWidgets()
            for i = 1, U.arrayCount(arr) do
                local e = arr[i]
                if U.alive(e) then
                    local rs, lk = nil, false
                    pcall(function() rs = e.RacerStyle end)
                    pcall(function() lk = e:GetIsEntryLocked() == true end)
                    add(rs, lk)
                end
            end
        end)
    end
    if #out > 0 then
        local nLocked = 0
        for _, it in ipairs(out) do if it.locked then nLocked = nLocked + 1 end end
        U.log(TAG, "racer styles from the %s: %d (%d locked)%s", src, #out, nLocked,
            #skipped > 0 and (", not offered: " .. table.concat(skipped, " ")) or "")
    end
    return out
end

-- P1's current pick on the native screen (the guests' default cursor): class / style key or nil
local function nativeChoice(kind, native)
    local v = nil
    if kind == "vehicle" then
        pcall(function() v = tonumber(native.FocusedVehicleArchetype) end)
        if v == nil or v == 1 then pcall(function() v = tonumber(native.ChosenVehicleArchetype.Archetype) end) end
    else
        pcall(function() v = styleKeyOf(native.LoadoutVM.ChosenStyle.RacerStyle) end)
    end
    return v
end

---------------------------------------------------------------------------------------------------- widgets
local function indexOf(items, id)
    for i, it in ipairs(items) do if it.id == id then return i end end
    return nil
end

local function firstUnlocked(items)
    for i, it in ipairs(items) do if not it.locked then return i end end
    return 1
end

-- pure: the P-badge and the READY / CHOOSING chip on the screen's header line, right of the native title + its deco.
-- couch-fix44 (live 2026-10-18 12:09, A3: "VEHICLE SELE[P2 CHOOSING]"): one x for both screens put them over the
-- longer "/VEHICLE SELECT" title (its deco ends at 0.54 of the frame; "/LOADOUT"'s at 0.375, both measured on
-- shot 140903-23 / 140920-26). The frame is the 16:9 one the screen shows in, so the fractions hold at 2/3/4 players.
M.TITLE_END = { vehicle = 0.54, style = 0.375 }
M.P1_NOTE_Y = 0.925                 -- P1's WAITING FOR note: under his loadout panel (ends 0.92), above the frame's end
-- couch-fix47 (AUTO-123, shot 152448-r2-a3-01-vehsel crop): "CHOOSING" ran past both ends of its plate (4K 2P: the
-- word 278 px wide at font 0.5 x the plate height 65 = 32.5, i.e. ~1.07 x the font size per glyph of the display
-- font; the plate 3.9 x 65 = 253 px). Font 0.4 x the plate height (the word ~3.4 plates' heights) on a 4.3-wide plate:
-- ~0.45 of a height clear at each end, at every player count (all in the frame's own units)
M.CHIP = { w = 4.3, font = 0.4 }
function M.headerRects(kind, fx, fy, fw, fh)
    local x0 = (M.TITLE_END[kind] or M.TITLE_END.style) + 0.015
    local hx, hy = math.floor(fx + fw * x0 + 0.5), math.floor(fy + fh * 0.042 + 0.5)
    local bh = math.floor(fh * 0.06 + 0.5)
    local bw = math.floor(bh * 1.45 + 0.5)
    local cw = math.floor(bh * M.CHIP.w + 0.5)
    return { hx, hy, bw, bh }, { hx + bw + math.floor(bh * 0.3), hy, cw, bh }
end

local function buildPanel(kit, tree, cv, P, kind, items, n)
    local col = kit.colours
    local x, y, w, h = L.area(P.slot, n)
    local f = math.max(0.6, h / L.VH)                       -- 1 in a half, 0.6 in a quadrant
    local function s(v) return math.floor(v * f + 0.5) end
    local pad = s(60)
    P.back = kit.solid(tree, col.DEEP);               kit.place(cv, P.back, x, y, w, h, 0)
    if x > 0 then local r = kit.solid(tree, col.AMBER); kit.place(cv, r, x, y, 10, h, 1) end
    if y > 0 then local r = kit.solid(tree, col.AMBER); kit.place(cv, r, x, y, w, 10, 1) end
    -- NOTE 6 (Jules 2026-10-14): the P-badge and the READY / CHOOSING chip sat on the strip's outer edges (clipped):
    -- they go INSIDE the 16:9 frame the screen shows in, on the header line right of the screen title ("/LOADOUT" +
    -- its deco end at 0.375 of the frame, measured on jules-favors-224009), badge then chip
    local fx, fy, fw, fh = L.frame(P.slot, n)
    P.badgeRect, P.chipRect = M.headerRects(kind, fx, fy, fw, fh)
    local hx, hy, bw, bh = P.badgeRect[1], P.badgeRect[2], P.badgeRect[3], P.badgeRect[4]
    local cw = P.chipRect[3]
    P.badge = kit.solid(tree, col.AMBER);             kit.place(cv, P.badge, hx, hy, bw, bh, 2)
    P.badgeT = kit.text(tree, math.floor(bh * 0.62), col.INKD)
    local sB = kit.place(cv, P.badgeT, hx + bw / 2, hy + bh / 2, nil, nil, 3)
    pcall(function() sB:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    P.title = kit.text(tree, s(64), col.CREAM);       kit.place(cv, P.title, x + pad + s(154), y + pad - s(6), nil, nil, 2)
    P.sub = kit.text(tree, s(30), col.PAPER, kit.FONT_BODY); kit.place(cv, P.sub, x + pad + s(158), y + pad + s(90), nil, nil, 2)
    P.chip = kit.solid(tree, col.ROW);                kit.place(cv, P.chip, P.chipRect[1], hy, cw, bh, 2)
    P.chipT = kit.text(tree, math.floor(bh * M.CHIP.font), col.CREAM)
    local sC = kit.place(cv, P.chipT, P.chipRect[1] + cw / 2, hy + bh / 2, nil, nil, 3)
    pcall(function() sC:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    local top = y + pad + s(170)
    local footH = s(290)
    local gx, gy, gw, gh = x + pad, top, w - 2 * pad, (y + h) - footH - top
    local gap = s(24)
    local nameH = s(96)
    local aspect = (kind == "vehicle") and 1.25 or 0.95
    local cols, rows, tw, th = L.grid(#items, gw, gh, aspect, gap)
    local ox = gx + math.floor((gw - (cols * tw + (cols - 1) * gap)) / 2)
    local oy = gy + math.floor((gh - (rows * th + (rows - 1) * gap)) / 2)
    local nameSize = math.max(22, math.min(s(44), math.floor(tw / 9)))
    P.cols, P.tiles = cols, {}
    for i, it in ipairs(items) do
        local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
        local tx, ty = ox + c * (tw + gap), oy + r * (th + gap)
        local T = {}
        T.bg = kit.solid(tree, col.ROW);              kit.place(cv, T.bg, tx, ty, tw, th, 2)
        local m = s(16)
        local iw, ih = tw - 2 * m, th - nameH - 2 * m
        if (it.aspect or 1) > 1 then
            if iw / ih > it.aspect then iw = math.floor(ih * it.aspect) else ih = math.floor(iw / it.aspect) end
        else
            local side = math.min(iw, ih)
            iw, ih = side, side
        end
        T.img = kit.mk(kit.IMAGE, tree)
        if T.img then
            kit.place(cv, T.img, tx + math.floor((tw - iw) / 2), ty + m, iw, ih, 3)
            pcall(function() T.img:SetVisibility(kit.VIS.HitTestInvisible) end)
            local tex = kit.texOf(it.image)
            if tex then pcall(function() T.img:SetBrushFromTexture(tex, false) end) else kit.show(T.img, false) end
        end
        T.name = kit.text(tree, nameSize, col.CREAM, kit.FONT_DISPLAY, tw - 2 * m)
        kit.place(cv, T.name, tx + m, ty + th - nameH, nil, nil, 3)
        T.tag = kit.text(tree, math.max(18, s(28)), col.AMBER, kit.FONT_BODY)
        kit.place(cv, T.tag, tx + m, ty + m, nil, nil, 4)
        kit.setText(T.name, it.name)
        T.btn = kit.mk(kit.BUTTON, tree)
        if T.btn then
            kit.place(cv, T.btn, tx, ty, tw, th, 5)
            pcall(function() T.btn:SetRenderOpacity(0.01) end)
        end
        P.tiles[i] = T
    end
    P.detailN = kit.text(tree, s(40), col.CREAM);     kit.place(cv, P.detailN, x + pad, y + h - footH + s(16), nil, nil, 2)
    P.detail = kit.text(tree, s(28), col.PAPER, kit.FONT_BODY, w - 2 * pad)
    kit.place(cv, P.detail, x + pad, y + h - footH + s(76), nil, nil, 2)
    P.foot = kit.text(tree, s(30), col.PAPER, kit.FONT_BODY); kit.place(cv, P.foot, x + pad, y + h - pad - s(36), nil, nil, 2)
    P.toastT = kit.text(tree, s(40), col.AMBER);      kit.place(cv, P.toastT, x + math.floor(w / 2), y + h - pad - s(44), nil, nil, 4)
end

-- D-pad navigation kept inside the guest's own groups (explicit neighbours, Stop at the edges): Slate's geometric
-- search would otherwise wander into another guest's panel. Set after AddToViewport (the Slate widgets exist).
local function navSet(b, nb)
    if not U.ok(b) then return end
    for dir, code in pairs(NAV) do
        local tb = nb[dir]
        if U.ok(tb) then pcall(function() b:SetNavigationRuleExplicit(code, tb) end)
        else pcall(function() b:SetNavigationRuleBase(code, RULE_STOP) end) end
    end
end

local function setNav(P)
    -- the vehicle half draws the classes as one row of cards (native copy) or a vertical list (garage4ui rows):
    -- every direction steps it
    if P.navBoth then
        for i, T in ipairs(P.tiles) do
            local prev = P.tiles[i - 1] and P.tiles[i - 1].btn or nil
            local nxt = P.tiles[i + 1] and P.tiles[i + 1].btn or nil
            navSet(T.btn, { left = prev, up = prev, right = nxt, down = nxt })
        end
        return
    end
    local nT, cols = #P.tiles, P.cols
    local F = P.favBtns
    local lastRow0 = (math.ceil(nT / cols) - 1) * cols + 1      -- the first tile of the last row
    for i, T in ipairs(P.tiles) do
        local c = (i - 1) % cols
        local nb = {
            left = (c > 0) and (i - 1) or nil,
            right = (c < cols - 1 and i + 1 <= nT) and (i + 1) or nil,
            up = (i - cols >= 1) and (i - cols) or nil,
            down = (i + cols <= nT) and (i + cols) or ((math.ceil(i / cols) < math.ceil(nT / cols)) and nT or nil),
        }
        local t = {}
        for dir, j in pairs(nb) do t[dir] = P.tiles[j] and P.tiles[j].btn or nil end
        if not t.down and F and U.ok(F[1]) then t.down = F[1] end              -- the bottom row -> favours
        navSet(T.btn, t)
    end
    for k, b in ipairs(F or {}) do
        navSet(b, { left = F[k - 1], right = F[k + 1], up = P.tiles[lastRow0] and P.tiles[lastRow0].btn or nil,
                    down = P.startBtn })
    end
    if P.startBtn then navSet(P.startBtn, { up = F and F[1] or nil }) end
    -- #101 his favour grid (the copy's TV_Favours, FAV_COLS a row); the top row's UP is set when it opens (his slot)
    local np = P.native and P.native.pickVms and #P.native.pickVms or 0
    for i = 1, math.min(np, #(P.pickBtns or {})) do
        local c = (i - 1) % FAV_COLS
        navSet(P.pickBtns[i], {
            left = (c > 0) and P.pickBtns[i - 1] or nil,
            right = (c < FAV_COLS - 1 and i + 1 <= np) and P.pickBtns[i + 1] or nil,
            up = (i - FAV_COLS >= 1) and P.pickBtns[i - FAV_COLS] or (F and F[1] or nil),
            down = (i + FAV_COLS <= np) and P.pickBtns[i + FAV_COLS] or nil,
        })
    end
end

-- n invisible input buttons (the tiles' technique) inside his area: their position does not matter (explicit nav)
local function ghostButtons(kit, tree, cv, n, x, y)
    local out = {}
    for k = 1, n do
        local b = kit.mk(kit.BUTTON, tree)
        if b then
            kit.place(cv, b, x + ((k - 1) % 10) * 14, y + math.floor((k - 1) / 10) * 14, 12, 12, 5)
            pcall(function() b:SetRenderOpacity(0.01) end)
            out[#out + 1] = b
        end
    end
    return out
end

-- the displayed entry widget of a list / tile view that shows item vm (prop = the entry's own VM member, else its
-- list item object) or nil (the list generates its entries on its first layout pass)
local function entryOf(list, vm, prop)
    if not (U.alive(list) and U.ok(vm)) then return nil end
    local want = U.key(vm)
    local found = nil
    pcall(function()
        local ents = U.arrayToTable(list:GetDisplayedEntryWidgets())
        for _, e in ipairs(ents) do
            if U.alive(e) then
                local it = nil
                pcall(function() it = e[prop] end)
                if not U.ok(it) then pcall(function() it = e:GetListItemObject() end) end
                if U.ok(it) and U.key(it) == want then found = e; break end
            end
        end
    end)
    return found
end

-- #103 (Jules 2026-10-18: every tile of P2's grid flashed into the hover state at each move): ONE native hover at a
-- time, like P1's. BP_OnFocusLost goes to the widget that got BP_OnFocusReceived and to no other (its reverse
-- Anim_Hover starts from the hovered end: called on every tile it scaled them all up and back). F = {w}
local function hoverTo(F, target)
    local cur = F.w
    local same = target ~= nil and U.alive(cur) and U.alive(target) and U.key(cur) == U.key(target)
    if same then return end
    if U.alive(cur) then pcall(function() cur:BP_OnFocusLost() end) end
    F.w = nil
    if U.alive(target) then
        pcall(function() target:BP_OnFocusReceived() end)
        F.w = target
    end
end

---------------------------------------------------------------------------------------------------- native style screen
-- Jules 2026-10-14: "use exactly the same screen as the rogue campaign". RACER STYLE: each guest's area shows a second
-- WBP_PreRun_LoadoutSelect_C (the game's own loadout screen) owned by his PC, display only. Decoded (cue4cli
-- --script): its Construct builds its OWN LoadoutVM (ViewModelSubsystem:BuildCampaignLoadoutSelectVM), lists the
-- styles, RefreshFocusedStyle / RefreshFavours / RefreshSelectedVehicle (reads only); the run is only touched by
-- RacerStyleChosen (SetChosenStyle + UpdateLastPickedStyle on ITS VM copy), OnFavourChosen (SetFavourInSlot +
-- UpdateLastPickedFavours: P1's save) and START RUN (PaddockGameState:ChooseLoadout + ContinueToNextState) - none is
-- ever reached: the screen is never activated, never focused, HitTestInvisible, nothing of it is ever clicked. The
-- guest's D-pad / A drive invisible buttons; the copy shows his state through its own functions:
--   * styles: RefreshFocusedStyle (name, description, traits, video) + ONE tile's own hover look (#103); his EQUIPPED
--     style = the tile's own selected mark (RacerStyleVM.bIsActive + RefreshActiveState) - written only when the
--     copy's VMs are its own objects (never P1's);
--   * favours (#101, Jules: the SAME choices as P1): A on one of his slots opens the copy's own FAVORS grid
--     (VS_MidPanelSwitcher -> B_Favours, TV_Favours:BP_SetListItems(its AllFavours): P1's unlocked favours, locked
--     ones in the native lock look), his cursor on it (the entries' own hover + RefreshFocusedFavour), A equips it in
--     that slot (A on the one it holds removes it), his equipped ones carry the native active mark;
--   * START RUN (#104) = his READY: his summary (vehicle, racer style, favours, pilot) + "READY - WAITING FOR ..." in
--     his half; A on it again (or B when his pad is readable) un-readies. P1's own START RUN is held until every guest
--     is READY (cfg.CouchPreRunWaitGuests).
-- The game's SwitchToFavourSelectForSlot / CloseFavourPanel are NOT used: they NavigateToIndex / SetFocus for the
-- copy's owning player (while the ids are swapped that is P1's pad: his A would click the copy's favour entry ->
-- UpdateLastPickedFavours on P1's save).
local LOADOUT = "/Game/Griffin/UI/Screens/WBP_PreRun_LoadoutSelect.WBP_PreRun_LoadoutSelect_C"

-- his READY summary (#104), over the copy's middle panel (where the favour grid opens)
local function buildSummary(kit, tree, cv, P, n)
    local col = kit.colours
    local fx, fy, fw, fh = L.frame(P.slot, n)
    local f = fh / L.VH
    local function s(v) return math.max(10, math.floor(v * f + 0.5)) end
    local x, y = math.floor(fx + fw * 0.355 + 0.5), math.floor(fy + fh * 0.17 + 0.5)
    local w, h = math.floor(fw * 0.33 + 0.5), math.floor(fh * 0.62 + 0.5)
    local pad = s(48)
    local Sm = { lines = {} }
    Sm.box = kit.solid(tree, col.DEEP);                kit.place(cv, Sm.box, x, y, w, h, 6)
    Sm.bar = kit.solid(tree, col.AMBER);               kit.place(cv, Sm.bar, x, y, w, s(12), 7)
    Sm.head = kit.text(tree, s(58), col.AMBER);         kit.place(cv, Sm.head, x + pad, y + pad, nil, nil, 7)
    Sm.headSize, Sm.headMax = s(58), w - 2 * pad        -- couch-fix63 (AUTO-154b): the head is fitted to the box
    for i = 1, 4 do
        local t = kit.text(tree, s(40), col.CREAM, kit.FONT_BODY, w - 2 * pad)
        kit.place(cv, t, x + pad, y + pad + s(130) + (i - 1) * s(150), nil, nil, 7)
        Sm.lines[i] = t
    end
    Sm.hint = kit.text(tree, s(30), col.PAPER, kit.FONT_BODY); kit.place(cv, Sm.hint, x + pad, y + h - pad - s(40), nil, nil, 7)
    for _, k in ipairs({ "box", "bar", "head", "hint" }) do kit.show(Sm[k], false) end
    for _, t in ipairs(Sm.lines) do kit.show(t, false) end
    return Sm
end

local function nativeStyle(kit, tree, cv, P, items, n)
    local cls = U.class(LOADOUT)
    if not U.ok(cls) then error("loadout screen class not loaded") end
    if not U.ok(P.pc) then error("no guest PlayerController") end
    local x, y, w, h = L.area(P.slot, n)
    -- (7) the guest's strip paper keeps the texture's aspect (ScaleToFill cover, cropped): it was stretched to 32:9
    local paper = kit.paperCover(tree, cv, { x, y, w, h }, nil, 1)
    local sc = kit.mk(kit.SCALE, tree)
    if not sc then error("no ScaleBox") end
    pcall(function() sc:SetStretch(2) end)                                      -- ScaleToFit
    kit.place(cv, sc, x, y, w, h, 1)
    local sb = kit.mk(kit.SIZEB, tree)
    sb:SetWidthOverride(kit.VW); sb:SetHeightOverride(kit.VH)
    sc:AddChild(sb)
    local scr = U.WBL():Create(P.pc, cls, P.pc)
    if not U.ok(scr) then error("loadout screen not created") end
    kit.own(scr)
    pcall(function() rootMod().exclude(scr) end)
    pcall(function() scr.bAutoActivate = false end)
    quietCopy(scr)                                -- couch-fix47: its own activatables never activate (AUTO-122)
    sb:AddChild(scr)
    pcall(function() scr:SetVisibility(kit.VIS.HitTestInvisible) end)
    -- #104: START RUN (WBP_Hero_Btn) stays: for a guest it is his READY; the difficulty is P1's
    for _, nm in ipairs({ "HB_Difficulty", "Scb_Difficulty", "HB_NewBreadcrumb" }) do
        pcall(function() scr[nm]:SetVisibility(kit.VIS.Hidden) end)
    end
    -- his input: the favour row (3), the favour grid (#101) and START RUN (#104), in the tiles' D-pad graph
    P.favBtns = ghostButtons(kit, tree, cv, 3, x + 40, y + h - 140)
    P.pickBtns = ghostButtons(kit, tree, cv, MAX_PICK, x + 200, y + h - 140)
    P.startBtn = ghostButtons(kit, tree, cv, 1, x + 40, y + h - 60)[1]
    P.sum = buildSummary(kit, tree, cv, P, n)
    P.zone, P.fsel, P.psel = "style", 1, 1
    -- the VM copy exists only once the screen's Construct ran, i.e. after the host is in the viewport (BUG-3, live
    -- 2026-10-14: mapped here, before AddToViewport, LoadoutVM was nil -> "lists none of the guest's styles" every
    -- time): nativeMap runs right after the host's AddToViewport
    P.native = { scr = scr, sc = sc, paper = paper, shown = nil, pending = true, hov = {} }
end

local favourMap, favShow, favActive, styleActive          -- (defined below)

-- the copy's VMs are its OWN objects (BuildCampaignLoadoutSelectVM builds new ones): only then the mod writes their
-- display flags (bIsActive / ActiveInSlot) for the guest; P1's VM objects are never written
local function ownVms(scr, native)
    local own = false
    pcall(function()
        local mine = scr.LoadoutVM
        if not U.ok(mine) then return end
        own = true
        if not U.alive(native) then return end
        local his = native.LoadoutVM
        if not U.ok(his) then return end
        if U.key(mine) == U.key(his) then own = false; return end
        for _, k in ipairs({ "AllFavours", "RacerStyles" }) do
            local a, b = mine[k], his[k]
            if U.arrayCount(a) > 0 and U.arrayCount(b) > 0 and U.key(a[1]) == U.key(b[1]) then own = false end
        end
    end)
    return own
end

-- after the host's AddToViewport: the guest's items -> the RacerStyleVMs of the screen's own VM copy (first unlocked
-- rank of each style). Nothing mapped = the native screen goes and the mod panel's own look stays.
local function nativeMap(P, items, native)
    local N = P.native
    if not (N and N.pending) then return end
    N.pending = nil
    local svm = {}
    pcall(function()
        local arr = N.scr.LoadoutVM.RacerStyles
        for i = 1, U.arrayCount(arr) do
            local v = arr[i]
            local key = nil
            pcall(function() key = styleKeyOf(v.RacerStyle) end)
            local j = key and indexOf(items, key)
            if j and (not svm[j] or (v.bIsLocked ~= true)) then svm[j] = svm[j] and (v.bIsLocked ~= true and v or svm[j]) or v end
        end
    end)
    local mapped = 0
    for _ in pairs(svm) do mapped = mapped + 1 end
    if mapped == 0 then
        pcall(function() N.scr:RemoveFromParent() end)
        pcall(function() N.sc:RemoveFromParent() end)
        if N.paper then pcall(function() N.paper:RemoveFromParent() end) end
        P.native = nil
        error("its LoadoutVM lists none of the guest's styles")
    end
    N.svm = svm
    N.ownVm = ownVms(N.scr, native)
    if not N.ownVm then
        U.warn(TAG, "P%s's loadout copy shares P1's VM objects: his equipped marks are not drawn", tostring(P.pnum))
    end
    local okF, errF = pcall(favourMap, P)
    if okF then pcall(favShow, P) else U.warn(TAG, "P%s favours not mapped: %s", tostring(P.pnum), tostring(errF)) end
    -- his equipped style: his saved pick, else the cursor's
    local p = CR().ensure(P.ctrlId, P.pnum)
    P.equip = indexOf(items, p.style) or P.sel
    pcall(styleActive, P)
    -- his vehicle in the copy's info panel (its RefreshSelectedVehicle reads P1's PaddockGameState pick)
    pcall(function()
        local arch = CR().archOf(P.ctrlId, P.pnum)
        if arch ~= nil then N.scr.WBP_LoadoutInfoPanel:RefreshSelectedVehicle(arch) end
    end)
    -- the mod panel's own look goes: the screen is the look; P2's badge, READY chip, toast and footer stay on top
    local kit = CP().kit
    for _, k in ipairs({ "back", "title", "sub", "detailN", "detail" }) do kit.show(P[k], false) end
    for _, T in ipairs(P.tiles or {}) do
        for _, k in ipairs({ "bg", "img", "name", "tag" }) do kit.show(T[k], false) end
    end
    U.log(TAG, "P%s native RACER STYLE screen: %d of %d style(s) mapped", tostring(P.pnum), mapped, #items)
end

-- favours: RacerFavour Favour_<Base>_<rank> in the copy's LoadoutVM (BuildCampaignLoadoutSelectVM: P1's account
-- unlocks; P1's last picked favours in FavourSlots). Decoded WBP_PreRun_LoadoutSelect: RefreshFavourSlots ->
-- Btn_FavourSlotN:Init(LoadoutVM.FavourSlots[N]) (WBP_FavourSlot_Btn SetFavour: display only); the list =
-- LoadoutVM.AllFavours (RacerFavourVM: Favour, bIsLocked, bIsRestricted, bIsActive, ActiveInSlot).
local function favId(fvm)
    local id = nil
    local f = nil
    pcall(function() f = fvm.Favour end)
    if not U.ok(f) then return nil end                     -- an empty slot: GetFName on null = native AV
    pcall(function() id = f:GetFName():ToString() end)
    return id
end
local function favName(id)
    local base, r = CR().favourBase(id)
    return base and string.format("%s %s", base, string.rep("*", r or 1)) or tostring(id)
end
local function favTitle(N, id)
    local nm = nil
    pcall(function() nm = N.favById[id].Favour.PlayerFacingName:ToString() end)
    if type(nm) ~= "string" or nm == "" then nm = favName(id) end
    return string.upper(nm)
end
local function favLocked(v)
    local lk = false
    pcall(function() lk = v.bIsLocked == true or v.bIsRestricted == true end)
    return lk
end

-- #101 (live 2026-10-18 09:50 "P2 favours: 0 of his kind unlocked"; Jules: the guests get the SAME favour choices as
-- P1): every favour P1's account has unlocked is the guest's to pick, into his own slots (P1's slot count / locks).
favourMap = function(P)
    local N = P.native
    local vm = N.scr.LoadoutVM
    local all, byId, slots, list = {}, {}, {}, {}
    pcall(function()
        local arr = vm.AllFavours
        for i = 1, U.arrayCount(arr) do
            local v = arr[i]
            if U.ok(v) then
                list[#list + 1] = v
                local id = favId(v)
                if id then
                    byId[id] = byId[id] or v
                    if not favLocked(v) then all[#all + 1] = id end
                end
            end
        end
    end)
    pcall(function()
        local arr = vm.FavourSlots
        for i = 1, math.min(3, U.arrayCount(arr)) do
            local sv = arr[i]
            local lk, id = false, nil
            pcall(function() lk = sv.bIsLocked == true end)
            if U.ok(sv) then id = favId(sv) end
            slots[i] = { vm = sv, locked = lk, p1 = id }
        end
    end)
    while #list > MAX_PICK do table.remove(list) end
    N.favAll, N.favById, N.favSlots, N.pickVms = all, byId, slots, list
    -- his favours: saved, else P1's own picks (a start he changes), each in an unlocked slot
    local p = CR().ensure(P.ctrlId, P.pnum)
    local mine = {}
    if type(p.favours) == "table" then
        for i = 1, 3 do mine[i] = p.favours[i] or false end
    else
        local used = {}
        for i = 1, 3 do
            local sl = slots[i]
            local id = sl and not sl.locked and sl.p1 or nil
            local b = id and CR().favourBase(id)
            if id and b and byId[id] and not favLocked(byId[id]) and not used[b] then mine[i] = id; used[b] = true
            else mine[i] = false end
        end
        CR().setFavours(P.ctrlId, P.pnum, mine)
    end
    P.favours = mine
    U.log(TAG, "P%s favours: %d unlocked (P1's account, every kind) of %d; his slots %s", tostring(P.pnum), #all, #list,
        table.concat({ tostring(mine[1]), tostring(mine[2]), tostring(mine[3]) }, ", "))
end

-- pure: what each of a guest's 3 slots shows. locked[i] = the slot is locked for P1's account, own[i] = his favour id
-- or false, team = { {id, slot}... } shared favours with P1's slot index (#101: none any more - the guest's slots are
-- his own; kept for the offline tests). -> { {kind = "locked"|"own"|"team"|"empty", id} x3 }
function M.favLayout(locked, own, team)
    local out, rest = {}, {}
    for i = 1, 3 do
        if locked[i] then out[i] = { kind = "locked" }
        elseif own[i] then out[i] = { kind = "own", id = own[i] }
        else out[i] = { kind = "empty" } end
    end
    for _, e in ipairs(team or {}) do
        local i = tonumber(e.slot)
        if i and out[i] and out[i].kind == "empty" then out[i] = { kind = "team", id = e.id }
        else rest[#rest + 1] = e end
    end
    for _, e in ipairs(rest) do
        for i = 1, 3 do
            if out[i].kind == "empty" then out[i] = { kind = "team", id = e.id }; break end
        end
    end
    return out
end

-- the VM a slot shows (his own favour's) or nil
local function slotVm(P, i)
    local N = P.native
    local e = N and N.favLay and N.favLay[i]
    if not e then return nil end
    if e.kind == "own" then return N.favById[e.id] end
    return nil
end

-- his slots on the copy: a locked slot keeps the native lock look, his favour VM, or the native empty slot
favShow = function(P)
    local N = P.native
    if not (N and N.favSlots and U.alive(N.scr)) then return end
    local locked, own = {}, {}
    for i = 1, 3 do
        local sl = N.favSlots[i]
        locked[i] = sl == nil or sl.locked == true
        local id = P.favours and P.favours[i]
        own[i] = (id and N.favById[id]) and id or false
    end
    N.favLay = M.favLayout(locked, own, nil)
    for i = 1, 3 do
        local b = nil
        pcall(function() b = N.scr["Btn_FavourSlot" .. i] end)
        local sl = N.favSlots[i]
        local e = N.favLay[i]
        if U.ok(b) and sl then
            local v = slotVm(P, i)
            if e.kind == "locked" then pcall(function() b:Init(sl.vm) end)
            elseif v then pcall(function() b:Init(v) end)
            else pcall(function() b:Init(CreateInvalidObject()) end) end
        end
    end
    pcall(favActive, P)
end

-- his equipped favours = the native active mark on the copy's own VMs (bIsActive, ActiveInSlot) + its own refresh
favActive = function(P)
    local N = P.native
    if not (N and N.ownVm and N.pickVms and U.alive(N.scr)) then return end
    for _, v in ipairs(N.pickVms) do
        local id = U.ok(v) and favId(v) or nil
        local slot = nil
        for i = 1, 3 do if id and P.favours and P.favours[i] == id then slot = i end end
        pcall(function() v.bIsActive = slot ~= nil end)
        pcall(function() v.ActiveInSlot = slot and (slot - 1) or -1 end)
    end
    pcall(function() N.scr:RefreshAllFavourChoiceActiveStates() end)
end

-- his equipped racer style = the tile's own selected mark (bIsActive + RefreshActiveState)
styleActive = function(P)
    local N = P.native
    -- couch-fix44 (A3, shot 141026-33): the copy's RACER STYLE header (Txt_StyleName) is written by the game's
    -- RacerStyleChosen only (never called on a copy: it saves P1's last pick), so it kept P1's style after the guest
    -- equipped another: his equipped style's name, on the copy's own text block
    if N and U.alive(N.scr) then
        local it = S.items and S.items[P.equip or 0]
        if it and N.headName ~= it.name then
            local t = nil
            pcall(function() t = N.scr.Txt_StyleName end)
            if U.ok(t) then
                CP().kit.setText(t, tostring(it.name))
                N.headName = it.name
            end
        end
    end
    if not (N and N.ownVm and N.svm and U.alive(N.scr)) then return end
    local on = N.svm[P.equip or 0]
    local onKey = U.ok(on) and U.key(on) or nil
    pcall(function()
        local arr = N.scr.LoadoutVM.RacerStyles
        for i = 1, U.arrayCount(arr) do
            local v = arr[i]
            if U.ok(v) then
                local want = onKey ~= nil and U.key(v) == onKey
                pcall(function() v.bIsActive = want end)
            end
        end
    end)
    pcall(function()
        local ents = U.arrayToTable(N.scr.Tile_RacerStyles:GetDisplayedEntryWidgets())
        for _, e in ipairs(ents) do
            if U.alive(e) then pcall(function() e:RefreshActiveState() end) end
        end
    end)
end

-- couch-fix47 (live round 2 AUTO-123, 13:27:05, shot 152707-r2-a3-10-p2-ready): P2's RACER STYLE header went back
-- to STUNT RUNNER when his cursor reached START RUN (= his READY) while his equip stayed SURVIVOR. Decoded
-- WBP_PreRun_LoadoutSelect: the WBP_Hero_Btn focus event -> ubergraph 4128 RefreshFocusedStyle(LoadoutVM.ChosenStyle),
-- and a copy's ChosenStyle is P1's last pick (its VM is built from P1's account; RacerStyleChosen never runs on a
-- copy). On START RUN the copy shows HIS equipped style the same way (RefreshFocusedStyle on his style's VM of the
-- copy: header, info panel, background), and the header is re-asserted twice a second while his cursor stays there
-- (a hover look replayed later by the button's own animation must not win).
local function startHead(P, refresh)
    local N = P.native
    if not (N and U.alive(N.scr)) then return end
    local it = S.items and S.items[P.equip or 0]
    if not it then return end
    if refresh then
        local vm = N.svm and N.svm[P.equip] or nil
        if U.ok(vm) then pcall(function() N.scr:RefreshFocusedStyle(vm) end) end
    end
    local t = nil
    pcall(function() t = N.scr.Txt_StyleName end)
    if U.ok(t) then CP().kit.setText(t, tostring(it.name)); N.headName = it.name end
    N.headAt = St.nowMs() + 500
end

-- the copy's focus look and info panel for his cursor: ONE hovered widget (a style tile, a favour slot, a favour of
-- the grid, START RUN) and the matching info (RefreshFocusedStyle / RefreshFocusedFavour / RefreshNoSelection)
local function nativeFocus(P)
    local N = P.native
    if not N or N.pending or not U.alive(N.scr) then return end
    local z = P.zone or "style"
    local i = (z == "style" and P.sel) or (z == "fav" and P.fsel) or (z == "pick" and P.psel) or 1
    local scr = N.scr
    local target, vm = nil, nil
    if z == "style" then
        vm = N.svm and N.svm[i] or nil
        if vm then pcall(function() target = entryOf(scr.Tile_RacerStyles, vm, "RacerStyleVM") end) end
    elseif z == "fav" then
        pcall(function() target = scr["Btn_FavourSlot" .. i] end)
        vm = slotVm(P, i)
    elseif z == "pick" then
        vm = N.pickVms and N.pickVms[i] or nil
        if vm then pcall(function() target = entryOf(scr.TV_Favours, vm, "Favour VM") end) end
    else
        pcall(function() target = scr.WBP_Hero_Btn end)
    end
    local sig = z .. ":" .. tostring(i)
    if N.sig ~= sig then
        N.sig = sig
        if z == "style" then
            if vm then pcall(function() scr:RefreshFocusedStyle(vm) end) end
        elseif z == "fav" or z == "pick" then
            if vm and favId(vm) then pcall(function() scr:RefreshFocusedFavour(vm) end)
            else pcall(function() scr:RefreshNoSelection() end) end
        end
    end
    hoverTo(N.hov, U.ok(target) and target or nil)
    if z == "start" then startHead(P, sig ~= N.headSig) end
    N.headSig = sig
    N.hovMiss = (N.hov.w == nil) and z ~= "start"
    N.shown = (z == "style") and P.sel or nil
end

-- his READY summary (#104): his vehicle, racer style, favours, pilot + who is still choosing
local function waitingNames(except)
    local w = { "P1" }
    for _, Q in ipairs(S.panels) do
        if Q ~= except and Q.startBtn and not Q.ready then w[#w + 1] = "P" .. tostring(Q.pnum) end
    end
    return w
end

function M.summaryLines(P, items)
    local lines = {}
    local arch = nil
    pcall(function() arch = CR().archOf(P.ctrlId, P.pnum) end)
    local cls = nil
    pcall(function() cls = U.mod("vehicles").classByArch(arch) end)
    local model = nil
    local g4 = G4()
    if g4 and arch ~= nil then pcall(function() model = g4.prerunInfo(P.pnum, arch).model end) end
    -- couch-fix63 (AUTO-154a, live round 8: "VEHICLE LANDSPEEDER - VORNSKR" while P2 raced P1's Skimmer): a guest who
    -- never picked a class follows P1's (couchrun.ensure gives him P1's class once P1's run starts: "P2 follows P1's class
    -- 0 -> 3"). On the pre-run screens P1's run still holds the previous / default class, so archOf named the wrong one:
    -- his summary says he races P1's class
    local follows = false
    pcall(function()
        local p = CR().player(P.ctrlId)
        follows = p ~= nil and p.picked ~= true
    end)
    if follows then
        lines[1] = "VEHICLE   SAME AS P1"
    else
        lines[1] = "VEHICLE   " .. string.upper(tostring(cls and cls.label or "?")) .. ((model and model ~= "") and ("  -  " .. string.upper(model)) or "")
    end
    local it = items and items[P.choice or P.equip or P.sel]
    lines[2] = "RACER STYLE   " .. (it and string.upper(tostring(it.name)) or "?")
    local fav = {}
    local N = P.native
    for i = 1, 3 do
        local id = P.favours and P.favours[i]
        if id then fav[#fav + 1] = N and favTitle(N, id) or favName(id) end
    end
    lines[3] = "FAVORS   " .. (#fav > 0 and table.concat(fav, ", ") or "NONE")
    local pilot = nil
    pcall(function()
        local PIL = U.mod("pilots")
        local p = CR().player(P.ctrlId)
        local e = p and p.pilot and PIL.byId(p.pilot) or nil
        if not e and arch ~= nil then e = PIL.defaultFor(arch, false, {}, nil, P.ctrlId) end
        pilot = e and e.name
    end)
    lines[4] = "PILOT   " .. (pilot and string.upper(pilot) or "AT THE START")
    return lines
end

local function renderSummary(P)
    local Sm = P.sum
    if not Sm then return end
    local kit = CP().kit
    local on = P.ready == true and P.zone ~= "pick"
    for _, k in ipairs({ "box", "bar", "head", "hint" }) do kit.show(Sm[k], on) end
    for _, t in ipairs(Sm.lines) do kit.show(t, on) end
    if not on then return end
    local head = "READY - WAITING FOR " .. table.concat(waitingNames(P), ", ")
    if kit.setTextFit then kit.setTextFit(Sm.head, head, Sm.headMax, Sm.headSize, kit.FONT_DISPLAY, "stepLabel", 14)
    else kit.setText(Sm.head, head) end
    local lines = M.summaryLines(P, S.items)
    for i, t in ipairs(Sm.lines) do kit.setText(t, lines[i] or "") end
    kit.setText(Sm.hint, "A on START RUN or B: change")
end

---------------------------------------------------------------------------------------------------- native vehicle select
-- #100 (Jules 2026-10-18: "1:1 parity, 4P-ready"): each guest's half is the game's OWN VEHICLE SELECT - a guest-owned
-- copy of WBP_FE_BaseVehicleSelect_C, the PARENT class of P1's WBP_PreRun_VehicleSelect_C. Decoded (cue4cli --script,
-- 2026-10-18): the pre-run screen's WidgetTree is EMPTY (the layout - title, class cards WBP_Vehicle_List_C, stats
-- panel WBP_VehicleInfoPanel_C, description, upgrade / unlock hints - is the parent's), and every call that reaches
-- P1's run lives in the pre-run OVERRIDES, which are empty on the parent:
--   OnVehicleFocused -> SetSelectedVehicleArchetype / SetOverrideMaterial on THE customisation pawn (GetAllActorsOfClass
--   BP_CstPawn_C[0] = P1's 3D car) + holo audio; OnVehicleChosen -> PaddockGameState:ChooseVehicleType +
--   ContinueToNextState; OnLockedVehicleArchetypeClicked -> TryToPurchaseVehicle + the unlock cinematic; OnCustomise /
--   OnUpgradeVehicle -> CSM changes; its Construct -> the pawn's unlock delegate.
-- The parent's Construct binds the class list's focus / choose / locked-click to those (empty) events and builds its
-- own list VM (ViewModelSubsystem:BuildVehicleSelectVM: P1's account = the unlocks, levels, costs). Never activated
-- (bAutoActivate false; its action bindings are made in BindInputs = TransitionIn only), HitTestInvisible, nothing
-- clicked. The guest's D-pad / A drive invisible buttons (couchpanel's technique); his cursor shows through the class
-- card's own hover (WBP_Vehicle_Entry BP_OnFocusReceived: its look + OnUpdateArchetypeDescription -> the screen's own
-- VehicleArchetypeFocused: stats panel InitFromVM, description, upgrade text) - one card at a time (#103's rule).
-- Locked classes keep the native locked look (the VM's bIsLocked); only P1 unlocks (#102: IsArchetypeUnlocked on
-- P1's live screen decides every pick). 3D: his own car of the highlighted class (his garage model + livery) on his
-- vpreview bay behind the screen (garage4.prerunTick, the scene P1's half shows behind his); without a bay the copy
-- shows the game's 2D vehicle render (Show2DVehicleImage: GfnVehicleList:FindArchetype.VehicleSelectImage).
-- Fallback: the garage4ui area (the text-row list) when the copy cannot be built (logged warning).
local VS_COPY_FLAGS = { "ShowScreenTimer", "ShowOpaqueBackground", "ShowVehicleDescription", "ShowLeftGradient",
                        "ShowVehicleInfoPanel", "TitleOverride" }

local function bay3DWanted()
    if opt("Garage4Bays3D", true) == false then return false end
    local g4 = G4()
    if not (g4 and g4.prerunTick and g4.campaignBrush) then return false, "garage4 not available" end
    -- couch-fix44: vpreview is off outside the front end until garage4 grants the bays: grant first, then ask
    -- (asking first = always "phase OTHER" in the paddock = the 2D image for every guest, live 2026-10-18 12:09)
    if g4.prerunGrant then
        local ok, on, why = pcall(g4.prerunGrant)
        if not ok then return false, tostring(on) end
        return on == true, why
    end
    return false, "garage4.prerunGrant missing"
end

local function nativeVehicleCopy(kit, tree, cv, P, n, native)
    local cls = U.class(VSBASE)
    if not U.ok(cls) then error("vehicle select class not loaded") end
    if not U.ok(P.pc) then error("no guest PlayerController") end
    local x, y, w, h = L.area(P.slot, n)
    local fx, fy, fw, fh = L.frame(P.slot, n)
    local paper = kit.paperCover(tree, cv, { x, y, w, h }, nil, 1)
    local b3, why2D = bay3DWanted()
    local bay = nil
    if b3 then
        bay = kit.mk(kit.IMAGE, tree)
        if bay then
            kit.place(cv, bay, math.floor(fx + 0.5), math.floor(fy + 0.5), math.floor(fw + 0.5), math.floor(fh + 0.5), 1)
            pcall(function() bay:SetVisibility(kit.VIS.HitTestInvisible) end)
            kit.show(bay, false)
        else
            b3, why2D = false, "no bay image widget"
            local g4 = G4()
            if g4 and g4.campaignClose then pcall(g4.campaignClose, "pre-run: no bay image widget", false) end
        end
    end
    local sc = kit.mk(kit.SCALE, tree)
    if not sc then error("no ScaleBox") end
    pcall(function() sc:SetStretch(2) end)                                      -- ScaleToFit
    kit.place(cv, sc, x, y, w, h, 2)
    local sb = kit.mk(kit.SIZEB, tree)
    sb:SetWidthOverride(kit.VW); sb:SetHeightOverride(kit.VH)
    sc:AddChild(sb)
    local scr = U.WBL():Create(P.pc, cls, P.pc)
    if not U.ok(scr) then error("vehicle select not created") end
    kit.own(scr)
    pcall(function() rootMod().exclude(scr) end)
    pcall(function() scr.bAutoActivate = false end)
    quietCopy(scr)                                -- couch-fix47: its own activatables never activate (AUTO-122)
    -- P1's screen's look (read before Construct: PreConstruct / Construct apply them), then the guest's own
    if U.alive(native) then
        for _, k in ipairs(VS_COPY_FLAGS) do pcall(function() scr[k] = native[k] end) end
    end
    local GUEST = { ShowCustomisationPrompt = false, ShowDifficultyPrompt = false, ShowTuningPoints = false,
                    ShowKitPoints = false, ShowSelectedVehicleTxt = false, ShowProfileInsignia = false,
                    PlayTransitionOutAnim = false, Show2DVehicleImage = not b3 }
    for k, v in pairs(GUEST) do pcall(function() scr[k] = v end) end
    sb:AddChild(scr)
    pcall(function() scr:SetVisibility(kit.VIS.HitTestInvisible) end)
    -- P1's prompts / profile / telemetry (his account's currencies) are not the guest's
    for _, nm in ipairs({ "WBP_ActionBar", "WBP_Party_Prompt", "O_Profile", "WBP_RaceTelemetryCurrency" }) do
        pcall(function() scr[nm]:SetVisibility(kit.VIS.Collapsed) end)
    end
    P.nv = { scr = scr, sc = sc, paper = paper, bay = bay, bay3D = b3, why2D = why2D, pending = true,
             hov = {} }
    P.navBoth = true
end

-- after the host's AddToViewport (Construct built the list's VM): the run classes -> the copy's VehicleSelectItemVMs
local function nativeVehicleMap(P, items)
    local N = P.nv
    if not (N and N.pending) then return end
    N.pending = nil
    local vms, mapped = {}, 0
    pcall(function()
        local arr = N.scr.WBP_Vehicle_Select.VehiclesVM.Vehicles
        for i = 1, U.arrayCount(arr) do
            local v = arr[i]
            local a = nil
            if U.ok(v) then pcall(function() a = tonumber(v.VehicleArchetype.Archetype) end) end
            local j = a and indexOf(items, a)
            if j and not vms[j] then vms[j] = v; mapped = mapped + 1 end
        end
    end)
    if mapped == 0 then
        pcall(function() N.scr:RemoveFromParent() end)
        pcall(function() N.sc:RemoveFromParent() end)
        if N.paper then pcall(function() N.paper:RemoveFromParent() end) end
        if N.bay then pcall(function() N.bay:RemoveFromParent() end) end
        P.nv = nil
        error("its VehiclesVM lists none of the run classes")
    end
    N.vm = vms
    -- #102: the copy's VM (P1's account) agrees: a class it shows locked stays locked while P1's check is unread
    for j, v in pairs(vms) do
        local lk = false
        pcall(function() lk = v.bIsLocked == true end)
        if lk and items[j] and not items[j].known then items[j].locked = true end
    end
    local kit = CP().kit
    for _, k in ipairs({ "back", "title", "sub", "detailN", "detail" }) do kit.show(P[k], false) end
    for _, T in ipairs(P.tiles or {}) do
        for _, k in ipairs({ "bg", "img", "name", "tag" }) do kit.show(T[k], false) end
    end
    U.log(TAG, "P%s native VEHICLE SELECT: %d of %d class(es) mapped, %s", tostring(P.pnum), mapped, #items,
        N.bay3D and "his own 3D car behind it" or ("the game's 2D vehicle render (no 3D bay: " .. tostring(N.why2D) .. ")"))
end

local function renderNativeVehicle(P)
    local N = P.nv
    if not N or N.pending or not U.alive(N.scr) then return end
    local items = S.items or {}
    local it = items[P.sel]
    P.g4arch = (N.bay3D and it) and it.id or nil          -- garage4.prerunTick: his bay follows his cursor
    local vm = N.vm and N.vm[P.sel] or nil
    if N.shown ~= P.sel or (vm and N.hov.w == nil) then
        local list = nil
        pcall(function() list = N.scr.WBP_Vehicle_Select.VehicleSelect_List end)
        local e = vm and entryOf(list, vm, "VehicleSelectItemVM") or nil
        local btn = nil
        if e then pcall(function() btn = e.WBP_Vehicle_Entry end) end
        if U.ok(btn) then
            hoverTo(N.hov, btn)        -- the card's hover + its broadcast -> VehicleArchetypeFocused (stats, description)
            N.filled = P.sel
        else
            hoverTo(N.hov, nil)
            if vm and N.filled ~= P.sel then
                -- no card widgets yet (the list builds them on its first layout pass): the screen's own handler fills
                -- the stats panel now, the card's hover follows on a later render
                local arch, desc = nil, nil
                pcall(function() arch = vm.VehicleArchetype end)
                if U.ok(arch) then pcall(function() desc = arch.Description end) end
                pcall(function() N.scr:VehicleArchetypeFocused(desc, arch, vm) end)
                N.filled = P.sel
            end
        end
        N.shown = P.sel
    end
    if N.bay3D and U.ok(N.bay) then
        local g4 = G4()
        local br, kind = nil, nil
        if g4 then br, kind = g4.campaignBrush(P) end
        if br ~= N.br or kind ~= N.brKind then
            N.br, N.brKind = br, kind
            if br then
                if kind == "texture" then pcall(function() N.bay:SetBrushResourceObject(br) end)
                else pcall(function() N.bay:SetBrushFromMaterial(br) end) end
            end
            CP().kit.show(N.bay, br ~= nil)
        end
        local op = (it and it.locked) and 0.45 or 1          -- a locked class's car dimmed (P1's: the unlock material)
        if N.op ~= op then N.op = op; pcall(function() N.bay:SetRenderOpacity(op) end) end
    end
end

---------------------------------------------------------------------------------------------------- native-look vehicle half
-- (9) Jules 2026-10-17 (trailer clip 03): the guests' VEHICLE SELECT half was the compact "YOUR VEHICLE" strip.
-- Since #100 the FALLBACK of the native copy above: the 4-way garage's PROVEN area look (garage4ui.buildArea: paper
-- backdrop, his colour badge, the class rows with the amber focus row, the model name band) with a REAL 3D car of the
-- highlighted class on his vpreview photo bay. The compact tiles stay as the INPUT layer only. Fallback of this one =
-- the compact panel (cfg.CouchPreRunNative false, or the build failing).
local function nativeVehicle(kit, tree, cv, P, n)
    local ui = G4UI()
    if not ui then error("garage4ui not available") end
    local x, y, w, h = L.area(P.slot, n)
    local A = ui.buildArea(tree, cv, x, y, w, h)
    if type(A) ~= "table" then error("area not built") end
    P.g4, P.navBoth = A, true
    -- the compact panel's look goes (the ghost buttons stay: they are his input)
    for _, k in ipairs({ "back", "badge", "badgeT", "title", "sub", "chip", "chipT", "detailN", "detail", "foot",
                         "toastT" }) do
        kit.show(P[k], false)
    end
    for _, T in ipairs(P.tiles or {}) do
        for _, k in ipairs({ "bg", "img", "name", "tag" }) do kit.show(T[k], false) end
    end
end

-- pure: the guest's vehicle-half view model (garage4ui.renderArea's vm; offline tests). items = the class items,
-- n = player count, info = garage4.prerunInfo of the highlighted class (model name + his palette's colours).
function M.vehicleVm(P, items, n, info, nowMs)
    info = info or {}
    local it = items[P.sel]
    local vm = { pnum = P.pnum, colour = C.COLOURS[P.pnum] or C.COLOURS.Remote, who = "P" .. tostring(P.pnum),
                 title = "VEHICLE SELECT", className = it and string.upper(tostring(it.name or "")) or "",
                 model = info.model or (it and it.name) or "", rows = {}, sel = P.sel,
                 toast = (P.toast and (nowMs or 0) < (P.toastUntil or 0)) and P.toast or nil }
    for i, c in ipairs(items) do
        local mine = P.ready and P.choice == i
        local focus = i == P.sel
        vm.rows[i] = { label = c.name, sub = c.locked and "LOCKED" or (mine and "YOUR PICK - READY" or ""),
                       focus = focus, colours = focus and info.colours or nil }
    end
    local where = (n == 2) and "above" or "top left"
    if P.ready then
        local c = items[P.choice]
        vm.hint = string.format("READY: %s - waiting for P1   (A on another tile changes it)", c and c.name or "?")
    else
        vm.hint = "P1 picks " .. where .. " - you race your own class   D-PAD choose   A confirm"
    end
    return vm
end

local function renderVehicleArea(P)
    local ui, g4 = G4UI(), G4()
    local items = S.items or {}
    local it = items[P.sel]
    P.g4arch = it and it.id or nil                -- garage4.prerunTick: his bay follows the highlighted class
    local info = (g4 and P.g4arch ~= nil) and g4.prerunInfo(P.pnum, P.g4arch) or nil
    local vm = M.vehicleVm(P, items, S.n, info, St.nowMs())
    if g4 then
        local br, kind, dim = g4.campaignBrush(P)
        vm.brush, vm.brushKind, vm.dim = br, kind, dim
        if it and it.locked and br then vm.dim = math.min(tonumber(dim) or 1, 0.5) end   -- a locked class's car dimmed
    end
    S.renders = (S.renders or 0) + 1
    if ui then ui.renderArea(P.g4, vm) end
end

---------------------------------------------------------------------------------------------------- render
local function render(P)
    if P.g4 and S.kind == "vehicle" then return renderVehicleArea(P) end
    S.renders = (S.renders or 0) + 1
    if P.nv then pcall(renderNativeVehicle, P) end
    if P.native then pcall(nativeFocus, P); pcall(renderSummary, P) end
    local kit = CP().kit
    local col = kit.colours
    local items = S.items or {}
    kit.setText(P.badgeT, "P" .. tostring(P.pnum))
    local where = (S.n == 2) and "above" or "top left"
    if S.kind == "vehicle" then
        kit.setText(P.title, "YOUR VEHICLE")
        kit.setText(P.sub, "P1 chooses " .. where .. " - you race your own class")
    else
        kit.setText(P.title, "YOUR RACER STYLE")
        kit.setText(P.sub, "P1 chooses " .. where .. " - your style is your starter build")
    end
    kit.setText(P.chipT, P.ready and "READY" or "CHOOSING")
    if U.ok(P.chip) then pcall(function() P.chip:SetColorAndOpacity(kit.lin(P.ready and col.AMBER or col.ROW)) end) end
    kit.setInk(P.chipT, P.ready and col.INKD or col.CREAM)
    if not (P.nv or P.native) then
        for i, T in ipairs(P.tiles) do
            local it = items[i]
            local focus = (i == P.sel)
            local mine = P.ready and P.choice == i
            local bg = focus and col.ROWF or (it.locked and col.DEEP or col.ROW)
            pcall(function() T.bg:SetColorAndOpacity(kit.lin(bg)) end)
            kit.setInk(T.name, focus and col.INKD or (it.locked and col.SAGE or col.CREAM))
            kit.setInk(T.tag, focus and col.INKD or col.AMBER)
            kit.setText(T.tag, it.locked and "LOCKED" or (mine and "YOUR PICK" or ""))
            if T.img then pcall(function() T.img:SetRenderOpacity(it.locked and 0.3 or 1) end) end
        end
        local it = items[P.sel]
        kit.setText(P.detailN, it and (it.name .. (it.locked and "  -  LOCKED" or "")) or "")
        kit.setText(P.detail, it and it.desc or "")
    end
    local foot
    if P.native then
        local z = P.zone or "style"
        if P.ready then foot = "READY   A on START RUN or B: change"
        elseif z == "style" then foot = "D-PAD choose   A equip   DOWN: favors, START RUN"
        elseif z == "fav" then foot = "A: choose a favor   UP: racer styles   DOWN: START RUN"
        elseif z == "pick" then foot = "D-PAD choose   A equip (A on yours removes it)   UP: back"
        else foot = "A: READY   UP: favors" end
    elseif P.ready then
        local c = items[P.choice]
        foot = string.format("READY: %s - waiting for P1   (A on another tile changes it)", c and c.name or "?")
    else
        foot = "D-PAD choose   A confirm"
    end
    kit.setText(P.foot, foot)
    kit.setText(P.toastT, (P.toast and St.nowMs() < (P.toastUntil or 0)) and P.toast or "")
end

local function renderAll() for _, P in ipairs(S.panels) do U.try(TAG, render, P) end end

---------------------------------------------------------------------------------------------------- open / close
local function what() return S.kind == "vehicle" and "arch" or "style" end

-- #102: the lock of a class AT the pick: P1's live screen's own check (the last value read when it is gone)
local function lockedNow(it)
    if not it then return true end
    if S.kind == "vehicle" then
        local v = archUnlocked(S.native, it.id)
        if v ~= nil then it.locked, it.known = not v, true end
    end
    return it.locked == true
end
M._lockedNow = lockedNow

-- the guest's pick when the native screen goes: READY = his choice; else his equipped style (native loadout) / the
-- cursor (the vehicle cursor only when he moved it - untouched, he follows P1's class); a locked class never
local function commit(P, why)
    local items = S.items or {}
    local i, how = nil, nil
    if P.ready and P.choice then i, how = P.choice, "confirmed"
    elseif S.kind == "style" and P.native and P.equip then i, how = P.equip, "not confirmed: equipped"
    elseif S.kind == "style" or P.touched then i, how = P.sel, "not confirmed: current choice" end
    local it = i and items[i] or nil
    if not it or lockedNow(it) then
        U.log(TAG, "P%s keeps his %s (%s)", tostring(P.pnum), S.kind == "vehicle" and "class (follows P1)" or "style",
            tostring(why))
        return
    end
    U.try(TAG, function() CR().choose(P.ctrlId, P.pnum, what(), it.id, how, it.rank) end)
    U.log(TAG, "P%s %s: %s (%s, %s)", tostring(P.pnum), S.kind, tostring(it.name), how, tostring(why))
end

-- P1's screens back to full screen: couchroot (every top-level screen) or, with CouchRootSplit off, the old per-widget
-- shrink of the native screen and its dialogs
local function restoreShrunk(calls)
    local r = rootMod()
    if r then U.try(TAG, r.finish, "prerun", calls) end
    if calls == false then return end
    for _, w in pairs(S.shrunk) do
        if U.alive(w) and not (r and r.isShrunk(w)) then L.restoreNative(w) end
    end
end

-- P1's area: couchroot moves every top-level screen (the native screen's frame and dialogs included); without it the
-- native screen / dialog alone is shrunk (0.15 first version)
local function intoP1Area(w, n)
    local r = rootMod()
    if r and r.active() then r.tick(); return true end
    return L.applyNative(w, n)
end

-- #104: P1's START RUN (WBP_Hero_Btn of HIS loadout screen) interaction off while a guest is not READY
local function p1Button(on)
    local nat = S.native
    if not U.alive(nat) then return end
    local b = nil
    pcall(function() b = nat.WBP_Hero_Btn end)
    if U.alive(b) then pcall(function() b:BP_SetIsInteractionEnabled(on == true) end) end
end

-- calls = false on a world change: nothing is called on the dying widgets
local function close(why, calls)
    if not S.open then return end
    for _, P in ipairs(S.panels) do commit(P, why) end
    if S.held and calls ~= false then p1Button(true) end
    S.held = nil
    if calls ~= false then
        p1Boundary(S.native, false)               -- couch-fix47: Slate's default boundary back on P1's screen
        deactivateCopies()
    end
    COPY.keys, COPY.ws, COPY.at = {}, {}, nil
    -- the guests' 3D bays go before the host (teardown before any travel; a world change = references only)
    for _, P in ipairs(S.panels) do
        if P.g4 or (P.nv and P.nv.bay3D) then
            local g4 = G4()
            if g4 and g4.campaignClose then
                U.try(TAG, g4.campaignClose, "pre-run: " .. tostring(why), calls == false)
            end
            break
        end
    end
    if calls ~= false then
        if U.ok(S.host) then pcall(function() S.host:RemoveFromParent() end) end
    end
    restoreShrunk(calls)
    U.log(TAG, "%s split closed (%s)", tostring(S.kind), tostring(why))
    S.open, S.kind, S.native, S.nativeKey, S.host, S.items, S.panels, S.shrunk = false, nil, nil, 0, nil, nil, {}, {}
    S.p1Note, S.p1NoteRect = nil, nil
    parkSync("pre-run split closed")          -- couch.lua: P1's PC off the park id (the split is over)
end

local function guests()
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    local out = {}
    if okJ and type(list) == "table" then
        for _, e in ipairs(list) do
            if #out < MAX_GUESTS then out[#out + 1] = e end
        end
    end
    return out
end

local function open(kind, native)
    local gl = guests()
    if #gl == 0 then return end
    local nk = U.key(native)
    couch().markPreRun("pre-run " .. kind .. " screen")    -- the guests' run reset comes before any pick
    local items = (kind == "vehicle") and vehicleItems(native) or styleItems(native)
    if #items == 0 then
        if S.failKey ~= nk then
            S.failKey = nk
            U.log(TAG, "%s screen: nothing readable yet (retrying)", kind)
        end
        return
    end
    local n = 1 + #gl
    local kit = CP().kit
    COPY.keys, COPY.ws, COPY.at = {}, {}, nil
    local okB, err = pcall(function()
        local H = CP().newHost()
        S.host, S.items, S.kind, S.n, S.panels = H.host, items, kind, n, {}
        for slot = n + 1, L.slots(n) do                       -- 3 players: the free quadrant stays dark
            local x, y, w, h = L.area(slot, n)
            local b = kit.solid(H.tree, kit.colours.DEEP)
            kit.place(H.cv, b, x, y, w, h, 0)
        end
        local def = nativeChoice(kind, native)
        for i, g in ipairs(gl) do
            local p = CR().ensure(g.ctrlId, g.pnum)
            local own = (kind == "vehicle") and (p.picked and p.arch or nil) or p.style
            local sel = indexOf(items, own) or indexOf(items, def) or firstUnlocked(items)
            if items[sel] and items[sel].locked then sel = firstUnlocked(items) end
            local P = { ctrlId = g.ctrlId, pnum = g.pnum, slot = i + 1, sel = sel, sel0 = sel, ready = false,
                        touched = false, prevA = true, focusAt = 0, pc = g.pc }
            buildPanel(kit, H.tree, H.cv, P, kind, items, n)
            if kind == "vehicle" and opt("CouchPreRunNative", true) ~= false then
                local done = false
                if opt("CouchPreRunNativeCopy", true) ~= false then
                    local okC, errC = pcall(nativeVehicleCopy, kit, H.tree, H.cv, P, n, native)
                    if okC then done = true
                    else
                        P.nv, P.navBoth = nil, nil
                        U.warn(TAG, "P%s native VEHICLE SELECT copy failed (%s): the area list instead", tostring(P.pnum),
                            tostring(errC))
                    end
                end
                if not done then
                    local okN, errN = pcall(nativeVehicle, kit, H.tree, H.cv, P, n)
                    if not okN then
                        P.g4, P.navBoth = nil, nil
                        U.warn(TAG, "P%s native-look VEHICLE area failed (%s): the mod panel instead", tostring(P.pnum),
                            tostring(errN))
                    end
                end
            end
            if kind == "style" and opt("CouchPreRunNative", true) ~= false then
                local okN, errN = pcall(nativeStyle, kit, H.tree, H.cv, P, items, n)
                if not okN then
                    P.native, P.favBtns, P.pickBtns, P.startBtn, P.sum, P.zone = nil, nil, nil, nil, nil, "style"
                    U.warn(TAG, "P%s native RACER STYLE screen failed (%s): the mod panel instead", tostring(P.pnum), tostring(errN))
                end
            end
            S.panels[#S.panels + 1] = P
        end
        -- #104: P1's "WAITING FOR P2" note, bottom left of his frame (by his START RUN). couch-fix44 (A3, shot
        -- 140920-26): at 0.955 its glyphs ran past the frame's bottom (cut by the split line): M.P1_NOTE_Y
        if kind == "style" then
            local fx, fy, fw, fh = L.frame(1, n)
            S.p1Note = kit.text(H.tree, math.max(16, math.floor(fh * 0.03 + 0.5)), kit.colours.AMBER)
            S.p1NoteRect = { math.floor(fx + fw * 0.04 + 0.5), math.floor(fy + fh * M.P1_NOTE_Y + 0.5), fh * 0.03 }
            kit.place(H.cv, S.p1Note, S.p1NoteRect[1], S.p1NoteRect[2], nil, nil, 8)
        end
        H.host:AddToViewport(tonumber(opt("CouchPanelZ", 1000)) or 1000)
        for _, P in ipairs(S.panels) do
            if P.native then
                local okM, errM = pcall(nativeMap, P, items, native)
                if not okM then
                    P.native, P.zone = nil, "style"
                    for _, k in ipairs({ "favBtns", "pickBtns" }) do
                        for _, b in ipairs(P[k] or {}) do pcall(function() b:SetVisibility(kit.VIS.Collapsed) end) end
                    end
                    if P.startBtn then pcall(function() P.startBtn:SetVisibility(kit.VIS.Collapsed) end) end
                    P.favBtns, P.pickBtns, P.startBtn, P.sum = nil, nil, nil, nil
                    U.warn(TAG, "P%s native RACER STYLE screen failed (%s): the mod panel instead", tostring(P.pnum), tostring(errM))
                end
            end
            if P.nv then
                local okV, errV = pcall(nativeVehicleMap, P, items)
                if not okV then
                    P.nv = nil
                    local okN, errN = pcall(nativeVehicle, kit, H.tree, H.cv, P, n)
                    if not okN then P.g4, P.navBoth = nil, nil end
                    U.warn(TAG, "P%s native VEHICLE SELECT copy failed (%s): %s", tostring(P.pnum), tostring(errV),
                        okN and "the area list instead" or ("the mod panel instead: " .. tostring(errN)))
                end
            end
        end
        for _, P in ipairs(S.panels) do
            P.tileBtns = {}
            for i, T in ipairs(P.tiles or {}) do P.tileBtns[i] = T.btn end
            setNav(P)
        end
    end)
    if not okB then
        U.warn(TAG, "%s split not built: %s", kind, tostring(err))
        if U.ok(S.host) then pcall(function() S.host:RemoveFromParent() end) end
        S.host, S.items, S.kind, S.panels, S.p1Note = nil, nil, nil, {}, nil
        S.failKey = nk
        return
    end
    S.open, S.native, S.nativeKey, S.shrunk, S.lastLock, S.openAt, S.held = true, native, nk, {}, St.nowMs(), St.nowMs(), nil
    local rt = rootMod()
    if rt then pcall(function() rt.exclude(S.host); rt.begin("prerun", n) end) end
    parkSync(kind .. " split open")           -- couch.lua: the screen owner's pad reaches only his own area now
    if intoP1Area(native, n) then S.shrunk[nk] = native end
    if opt("CouchPreRunNavBoundary", true) ~= false and p1Boundary(native, true) then
        U.log(TAG, "P1's %s screen: navigation boundary Stop (his D-pad stays inside his own screen)", kind)
    end
    copyTick(St.nowMs())
    local names = {}
    for _, it in ipairs(items) do names[#names + 1] = it.name .. (it.locked and "(locked)" or "") end
    U.log(TAG, "%s split open: %d player(s), %d choice(s): %s", kind, n, #items, table.concat(names, ", "))
    renderAll()
end

---------------------------------------------------------------------------------------------------- tick
local function ready(P, on, why)
    if on then
        local it = S.items and S.items[P.equip or P.sel]
        if not it or it.locked then
            P.toast, P.toastUntil = "LOCKED", St.nowMs() + 2000
            render(P)
            return
        end
        P.ready, P.choice = true, P.equip or P.sel
        U.try(TAG, function() CR().choose(P.ctrlId, P.pnum, "style", it.id, "READY (START RUN)", it.rank) end)
        P.toast, P.toastUntil = "READY", St.nowMs() + 2000
        U.log(TAG, "P%s READY: style %s, favours %s (%s)", tostring(P.pnum), tostring(it.name),
            table.concat({ tostring(P.favours and P.favours[1]), tostring(P.favours and P.favours[2]),
                tostring(P.favours and P.favours[3]) }, ", "), tostring(why))
    else
        P.ready = false
        P.toast, P.toastUntil = "CHOOSING", St.nowMs() + 1500
        U.log(TAG, "P%s not READY any more (%s)", tostring(P.pnum), tostring(why))
    end
    renderAll()                               -- every summary's "WAITING FOR" list
end

-- #101 his favour grid: open on his slot k / close back onto it
local function setFocusFor(P, b, force)
    local kit = CP().kit
    local pc = kit.padPC(P.ctrlId)
    local setF = kit.padSetFocus or function(w, _, p) if U.ok(w) then pcall(function() w:SetUserFocus(p) end) end end
    if U.ok(b) and U.ok(pc) then setF(b, P.ctrlId, pc, force) end
end

local function closePick(P, k, why)
    local N = P.native
    if N and U.alive(N.scr) then
        pcall(function() N.scr.VS_MidPanelSwitcher:SetActiveWidget(N.scr.Spc_Empty) end)
    end
    P.pickOpen = false
    if k then
        P.zone, P.fsel = "fav", k
        setFocusFor(P, P.favBtns and P.favBtns[k], true)
    end
    U.log(TAG, "P%s favour grid closed (%s)", tostring(P.pnum), tostring(why))
end

local function openPick(P, k)
    local N = P.native
    if not (N and N.pickVms and #N.pickVms > 0 and U.alive(N.scr)) then
        P.toast, P.toastUntil = "NO FAVORS UNLOCKED", St.nowMs() + 2000
        render(P)
        return
    end
    if not N.listed then
        local okL = pcall(function() N.scr.TV_Favours:BP_SetListItems(N.scr.LoadoutVM.AllFavours) end)
        N.listed = okL
        if not okL then U.warn(TAG, "P%s favour grid: the copy's TV_Favours refused its AllFavours", tostring(P.pnum)) end
    end
    pcall(function() N.scr.VS_MidPanelSwitcher:SetActiveWidget(N.scr.B_Favours) end)
    pcall(favActive, P)
    -- the top row's UP: back to the slot he came from
    for c = 1, math.min(FAV_COLS, #N.pickVms) do
        local b = P.pickBtns and P.pickBtns[c]
        if U.ok(b) and P.favBtns and U.ok(P.favBtns[k]) then
            pcall(function() b:SetNavigationRuleExplicit(NAV.up, P.favBtns[k]) end)
        end
    end
    local cur = P.favours and P.favours[k]
    local start = 1
    for i, v in ipairs(N.pickVms) do if cur and favId(v) == cur then start = i end end
    P.pickOpen, P.pickSlot, P.zone, P.psel = true, k, "pick", start
    setFocusFor(P, P.pickBtns and P.pickBtns[start], true)
    U.log(TAG, "P%s favour grid open for his slot %d (%d favour(s), %d unlocked)", tostring(P.pnum), k, #N.pickVms,
        #(N.favAll or {}))
    render(P)
end

-- A on his favour slot k: the grid (a locked slot: the native lock, nothing)
local function favAct(P, k)
    local N = P.native
    if not (N and N.favSlots) then return end
    local sl = N.favSlots[k]
    if not sl or sl.locked then
        P.toast, P.toastUntil = "LOCKED", St.nowMs() + 2000
        render(P)
        return
    end
    openPick(P, k)
end

-- A on favour i of the grid: equip it in his slot (A on the one the slot holds removes it; the same favour in another
-- of his slots moves); locked / restricted = the native lock, nothing
local function pickAct(P, i)
    local N = P.native
    local k = P.pickSlot or P.fsel or 1
    local v = N and N.pickVms and N.pickVms[i]
    if not v then return end
    local id = favId(v)
    if id and favLocked(v) then
        P.toast, P.toastUntil = "LOCKED - ONLY P1 UNLOCKS FAVORS", St.nowMs() + 2000
        render(P)
        return
    end
    P.favours = P.favours or { false, false, false }
    local was = P.favours[k]
    local msg
    if not id or id == was then
        P.favours[k] = false
        msg = "REMOVED"
    else
        local b = CR().favourBase(id)
        for j = 1, 3 do
            if j ~= k and P.favours[j] and CR().favourBase(P.favours[j]) == b then P.favours[j] = false end
        end
        P.favours[k] = id
        msg = favTitle(N, id)
    end
    U.try(TAG, function() CR().setFavours(P.ctrlId, P.pnum, P.favours) end)
    favShow(P)
    U.log(TAG, "P%s favour slot %d: %s", tostring(P.pnum), k, tostring(P.favours[k]))
    closePick(P, k, "picked")
    if P.ready then ready(P, false, "changed his favours") end
    P.toast, P.toastUntil = msg, St.nowMs() + 2000
    render(P)
end

local function act(P)
    local it = S.items and S.items[P.sel]
    if not it then return end
    if lockedNow(it) then
        P.toast, P.toastUntil = (S.kind == "vehicle") and "LOCKED - ONLY P1 CAN UNLOCK IT" or "LOCKED", St.nowMs() + 2000
        U.log(TAG, "P%s A on the locked %s %s: refused", tostring(P.pnum), S.kind, tostring(it.name))
        render(P)
        return
    end
    if S.kind == "style" and P.native then
        -- #104: A on a style EQUIPS it (the native tile mark); READY is START RUN
        P.equip = P.sel
        U.try(TAG, function() CR().choose(P.ctrlId, P.pnum, "style", it.id, "equipped with A", it.rank) end)
        pcall(styleActive, P)
        if P.ready then ready(P, false, "changed his style") end
        P.toast, P.toastUntil = string.upper(tostring(it.name)), St.nowMs() + 2000
        U.log(TAG, "P%s equips style %s", tostring(P.pnum), tostring(it.name))
    else
        P.choice, P.ready = P.sel, true
        U.try(TAG, function() CR().choose(P.ctrlId, P.pnum, what(), it.id, "confirmed with A", it.rank) end)
        P.toast, P.toastUntil = "READY", St.nowMs() + 2000
        U.log(TAG, "P%s READY: %s %s", tostring(P.pnum), S.kind, tostring(it.name))
    end
    render(P)
end

local function startAct(P)
    if P.ready then ready(P, false, "A on START RUN again") else ready(P, true, "A on START RUN") end
end

-- couch.lua's PARK (cfg.CouchSwapPark): while this split is open the screen owner's pad reaches no PlayerController
-- (his first A KeyDown went to P1's CommonUI router before: the leak to P1's VEHICLE SELECT, short presses lost);
-- kit.padHasFocus / padSetFocus read and set his Slate user's focus without a PC on his id.
local function plainHas(w, _, pc)
    local has = false
    if U.ok(w) then pcall(function() has = w:HasUserFocus(pc) == true end) end
    return has
end
local function plainSet(w, _, pc) if U.ok(w) then pcall(function() w:SetUserFocus(pc) end) end end
local function never() return false end

local ZONES = { "style", "fav", "pick", "start" }
local function groupOf(P, z)
    if z == "style" then return P.tileBtns end
    if z == "fav" then return P.favBtns end
    if z == "pick" then return P.pickOpen and P.pickBtns or nil end
    if z == "start" then return P.startBtn and { P.startBtn } or nil end
    return nil
end
local function curOf(P, z)
    return (z == "style" and P.sel) or (z == "fav" and P.fsel) or (z == "pick" and P.psel) or 1
end

local function moveTo(P, z, i)
    if P.pickOpen and z ~= "pick" then closePick(P, nil, "his cursor left it") end
    if z == "style" then
        if P.sel ~= i then P.touched = true end
        P.sel = i
    elseif z == "fav" then P.fsel = i
    elseif z == "pick" then P.psel = i end
    P.zone = z
    P.hovTries = 0
    render(P)
end

-- the copy's entry widgets appear on its first layout pass: the hover is retried (4 a second, 10 s at most per
-- cursor position) until it lands
local function hoverRetry(P, now)
    local miss = (P.native and P.native.hovMiss) or (P.nv and P.nv.vm and P.nv.hov.w == nil)
    if not miss or (P.hovTries or 0) >= 40 or now - (P.hovAt or 0) < 250 then return end
    P.hovAt, P.hovTries = now, (P.hovTries or 0) + 1
    U.try(TAG, render, P)
end

local function poll(P, now)
    local kit = CP().kit
    local hasF, setF, parked = kit.padHasFocus or plainHas, kit.padSetFocus or plainSet, kit.padParked or never
    local pc = kit.padPC(P.ctrlId)
    if not U.ok(pc) then return end
    local z0 = P.zone or "style"
    local function look(z)
        local g = groupOf(P, z)
        if not g then return nil end
        local c = curOf(P, z)
        if g[c] and hasF(g[c], P.ctrlId, pc) then return c end
        local np = (z == "pick" and P.native and P.native.pickVms) and #P.native.pickVms or #g
        for i = 1, math.min(np, #g) do
            if i ~= c and hasF(g[i], P.ctrlId, pc) then return i end
        end
        return nil
    end
    local zone, idx = nil, look(z0)
    if idx then zone = z0 end
    if not zone then
        for _, z in ipairs(ZONES) do
            if z ~= z0 then
                idx = look(z)
                if idx then zone = z; break end
            end
        end
    end
    if not zone and parked(P.ctrlId) then
        -- parked: an A on the button focused for him counts even if the any-user focus query misses it
        local g = groupOf(P, z0)
        local b = g and g[curOf(P, z0)]
        local pr = false
        if U.ok(b) then pcall(function() pr = b:IsPressed() == true end) end
        if pr then zone, idx = z0, curOf(P, z0) end
    end
    if zone and (zone ~= z0 or idx ~= curOf(P, zone)) then moveTo(P, zone, idx) end
    -- B un-readies (#104) when his pad's key state is readable (not while parked: no PC carries his id)
    if P.ready and P.native and not parked(P.ctrlId) then
        local bd = false
        pcall(function() bd = U.mod("ui").keyDown(pc, C.KEY.B) == true end)
        if bd and not P.prevB then ready(P, false, "B") end
        P.prevB = bd
    end
    if not zone then
        if now - (P.focusAt or 0) > 250 then
            P.focusAt = now
            local g = groupOf(P, z0)
            local b = g and g[curOf(P, z0)]
            if U.ok(b) then setF(b, P.ctrlId, pc) end
        end
        P.prevA = false
        hoverRetry(P, now)
        return
    end
    local g = groupOf(P, zone)
    local b = g and g[idx]
    local pressed = false
    if U.ok(b) then pcall(function() pressed = b:IsPressed() == true end) end
    if pressed and not P.prevA then
        if zone == "style" then act(P)
        elseif zone == "fav" then favAct(P, idx)
        elseif zone == "pick" then pickAct(P, idx)
        else startAct(P) end
    end
    P.prevA = pressed
    if P.toast and now >= (P.toastUntil or 0) then P.toast = nil; render(P) end
    if P.native and P.zone == "start" and now >= (P.native.headAt or 0) then startHead(P, false) end
    hoverRetry(P, now)
end

-- #104: P1's START RUN is held until every guest is READY (cfg.CouchPreRunWaitGuests; a safety release after
-- cfg.CouchPreRunWaitMs). Held = his START RUN's interaction off + "WAITING FOR P2" by it; menubridge never clicks it.
local function holdTick(now)
    local wait = {}
    for _, P in ipairs(S.panels) do
        if P.startBtn and not P.ready then wait[#wait + 1] = "P" .. tostring(P.pnum) end
    end
    local held = #wait > 0 and opt("CouchPreRunWaitGuests", true) ~= false
    local limit = tonumber(opt("CouchPreRunWaitMs", 180000)) or 0
    if held and limit > 0 and now - (S.openAt or now) >= limit then
        if not S.released then
            S.released = true
            U.warn(TAG, "P1's START RUN released after %d s: %s not READY", math.floor(limit / 1000), table.concat(wait, ", "))
        end
        held = false
    end
    if held ~= (S.held == true) then
        S.held = held
        p1Button(not held)
        U.log(TAG, held and "P1's START RUN held: WAITING FOR %s" or "P1's START RUN free%s", held and table.concat(wait, ", ")
            or (#wait == 0 and " (every guest READY)" or ""))
    end
    local kit = CP().kit
    local note = held and ("WAITING FOR " .. table.concat(wait, ", ")) or ((#wait == 0 and S.p1Note) and "ALL READY" or "")
    if S.noteText ~= note then S.noteText = note; kit.setText(S.p1Note, note) end
end

function M.p1Held() return S.open == true and S.kind == "style" and S.held == true end

local function scan(now)
    local okC, on = pcall(function() return couch().active() end)
    if not (okC and on == true) then
        if S.open then close("couch rules off") end
        return
    end
    local found, kind, dialogs = nil, nil, {}
    for _, e in ipairs(couch().activeScreens()) do
        local k = SCREENS[e.cls]
        if k and (not found or k == "style") then found, kind = e.w, k end   -- a transition: the loadout wins
        if e.cls:find("Confirmation", 1, true) then dialogs[#dialogs + 1] = e.w end
    end
    if S.open and (not found or U.key(found) ~= S.nativeKey) then close("native screen closed") end
    if S.open and 1 + #guests() ~= S.n then close("players changed") end
    if found and not S.open then open(kind, found) end
    if not S.open then return end
    -- P1's own dialog on top (WBP_LoadoutConfirmation_C) goes into his area too
    for _, d in ipairs(dialogs) do
        local k = U.key(d)
        if k ~= 0 and not S.shrunk[k] and U.alive(d) then
            if intoP1Area(d, S.n) then
                S.shrunk[k] = d
                U.log(TAG, "P1's dialog shrunk into his area")
            end
        end
    end
    if S.kind == "style" then holdTick(now) end
    copyTick(now)
    if S.kind == "vehicle" and now - S.lastLock > 2000 then
        S.lastLock = now
        if refreshLocks(S.native, S.items) then
            -- P1 unlocked a class: the copies' own lists again (their VMs read P1's account)
            for _, P in ipairs(S.panels) do
                local N = P.nv
                if N and U.alive(N.scr) then
                    pcall(function() N.scr.WBP_Vehicle_Select:RefreshVehicleArchetypes() end)
                    N.pending, N.shown, N.filled, N.hov = true, nil, nil, {}
                    local okV = pcall(nativeVehicleMap, P, S.items)
                    if not okV then U.warn(TAG, "P%s vehicle copy not re-mapped after an unlock", tostring(P.pnum)) end
                end
            end
            local names = {}
            for _, it in ipairs(S.items) do names[#names + 1] = it.name .. (it.locked and "(locked)" or "") end
            U.log(TAG, "class locks changed: %s", table.concat(names, ", "))
            renderAll()
        end
    end
end

function M.fastTick()
    if opt("CouchPreRunSplit", true) == false then
        if S.open then close("CouchPreRunSplit off") end
        return
    end
    local okQ, q = pcall(function() return couch().isQuiet() end)
    if okQ and q == true then return end
    if St.phase ~= "OTHER" then
        if S.open then close("phase " .. tostring(St.phase)) end
        return
    end
    local now = St.nowMs()
    if now - S.lastScan >= 250 then
        S.lastScan = now
        U.try(TAG, scan, now)
    end
    if S.open and not U.alive(S.host) then close("split host gone"); return end   -- kept across ticks
    if S.open then
        for _, P in ipairs(S.panels) do U.try(TAG, poll, P, now) end
        -- the guests' 3D bays (the native copy's scene / the area look's car): a want only when a guest's highlighted
        -- class changed, captures on vpreview's own budget; an area is redrawn only when its bay changed
        if S.kind == "vehicle" then
            local any = false
            for _, P in ipairs(S.panels) do if P.g4 or (P.nv and P.nv.bay3D) then any = true; break end end
            if any then
                local g4 = G4()
                if g4 and g4.prerunTick then
                    local okT, ch, keys = pcall(g4.prerunTick, S.panels)
                    if okT and ch == true and type(keys) == "table" then
                        for _, P in ipairs(S.panels) do
                            if (P.g4 or P.nv) and keys[P.ctrlId + 1] then U.try(TAG, render, P) end
                        end
                    end
                end
            end
        end
        local rt = rootMod()
        if rt then rt.tick() end
    end
end

function M.status()
    if not S.open then return "couchprerun: closed" end
    local t = {}
    for _, P in ipairs(S.panels) do
        local it = S.items and S.items[P.ready and P.choice or P.sel]
        t[#t + 1] = string.format("P%d %s%s", P.pnum, it and it.name or "?", P.ready and " READY" or "")
    end
    return string.format("couchprerun: %s split, %d player(s): %s%s", tostring(S.kind), S.n, table.concat(t, ", "),
        S.held and " (P1's START RUN held)" or "")
end

-- test hooks: the open panels' state (live test plan), the native readers (offline test)
function M.state() return S end
M._test = { vehicleItems = vehicleItems, styleItems = styleItems, nativeChoice = nativeChoice }

function M.init()
    St.on("phase", TAG, function(new)
        if S.open and (new == "LOADING" or new == "FRONTEND" or new == "TRANSIT") then close("phase " .. new) end
    end)
    -- "leaving" runs before the old world is torn down: the panel and the shrunk screens are released while alive
    St.on("leaving", TAG, function() close("leaving") end)
    St.on("world", TAG, function() close("world", false) end)
end

return M
