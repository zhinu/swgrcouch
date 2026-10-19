-- progress.lua: the RACE-PROGRESS STRIP in every player's HUD (playtest 2026-10-17 finding #38, branch couch-progress).
--
-- P1's race HUD shows, at the top centre, the game's 1D map (WBP_HUD_RaceInfo > C_TopLayout > WBP_Hud_PositionMap):
-- a track line, P1's own mark in the middle (Img_1DMap_MidSection, the small triangle), a pill for every other car
-- ahead / behind on the track and the lap / finish line flag. The guests' HUDs had none of it: hud.lua collapses
-- their copy (cfg.GuestHudCollapse) because the map CANNOT be per player:
--   [V decoded WBP_Hud_PositionMap, kismet2txt] its BP Tick (UpdateParams / UpdateParamsForMarker) writes the native
--   CurrentMapParams (PositionMapParameters: MarkerParams[] = {NormalisedPos, bIsClamped, bIsWrecked, bIsEliminated},
--   NemesisIndex, RivalIndex, SideBetIndex, NormalisedLapMarkerPosition) into the WORLD's MPC_HUD_Parameters
--   ("P01..P11 Position.x / State / Visible?", "FinishPosition.x", "TargetIndex", "LinesNumber"), and the image's
--   material M_UI_HUD_1DMap draws from that MPC. One MPC per world: every map on screen shows the last writer.
--   [V jmap Griffin-5.7.4-381121] PositionMapWidget's own marker widget classes (PlayerMarkerClass, VehicleMarkerClass,
--   LapMarkerClass) exist natively but no game asset implements PositionMapMarkerInterface: the MPC path is the only
--   one the game ships.
-- So each strip here is the mod's own: a canvas in the HUD's C_TopLayout at the map's slot (anchor (0.5, 0), T 36,
-- 980 x 170, the map's own render scale copied: hud.lua's compact top bar runs it at 0.6), a pill per car on the
-- line (y 65.17 in the box = Img_1DMap_MidSection's centre), the lap / finish tick with its flag. The player's own
-- mark is the HUD's own Img_1DMap_MidSection (hud.lua keeps it in guest HUDs while the strip runs: guestKeeps).
--
-- DATA (per FAST tick, plain float reads, no wrapper): [V jmap] VehiclePawn.RouteMarker (+0xB00, VehicleRouteMarker)
-- .EventProgressNormalised (+0x38; also EventProgress, DistanceToFinish, DistanceAroundMainRoute) for every car in
-- RacingGameState.Vehicles (list refreshed 1 Hz), PlayerRaceEventComponent bHasVehicleWrecked / bHasBeenEliminated /
-- bHasBeenDisappeared (4 Hz: the native map hides wrecked / eliminated markers), RaceEventVM.NumLaps (lap lines at
-- k / NumLaps of the event). [S] EventProgressNormalised = the event fraction 0..1 (laps included): a car whose value
-- drops by more than half while racing switches the strip to the per-lap reading ((lap - 1 + v) / NumLaps), logged
-- once (V-HUD-PR4).
-- SCALE: the same as P1's strip (cfg.HudProgressScale "p1"): every second P1's native CurrentMapParams are read and
-- the unclamped pills are paired with the cars nearest to P1 on each side (both reading directions tried, the more
-- consistent one kept): half window = progress gap / (2 x |NormalisedPos - 0.5|), median, smoothed. Until that works
-- (or "fixed"): cfg.HudProgressHalfLap of a lap each side. Logged as V-HUD-PR2.
-- WHO: every guest HUD of a split race. In a MISSION-INSTANCES race (instances.lua: each human his own copy of the
-- field) P1 gets the strip too and his native map goes to render opacity 0 (it still ticks: its params keep the
-- scale), and every strip shows only the cars of its player's own set (instances.setOf).
-- COST: no FindAllOf / StaticFindObject in a tick; per FAST tick one float read per car and one SetPosition per pill
-- that moved >= 1.5 units (cached UFunction handle via U.pcallFn, one reused argument table). Build: once per HUD
-- instance (a pause / CSM rebuild makes a new HUD: a new strip). Hot reload: strips of the previous Lua state are
-- found by their name prefix and removed.
-- VERIFY(V-HUD-PR1): "P2 race-progress strip in its HUD" once per guest HUD; a pill per car on P2's top line, his own
-- triangle in the middle, the flag at the lap line. VERIFY(V-HUD-PR2): the scale line; P2's gaps look like P1's.
-- VERIFY(V-HUD-PR3): instance race: "P1's native map hidden" and each strip only shows its own set's cars.
local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "progress"

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

local VIS = C.E.Vis
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local IMAGE = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local SET_POS = "/Script/UMG.CanvasPanelSlot:SetPosition"
-- [V hud-narrow-views §2.2] WBP_Hud_PositionMap's slot in C_TopLayout: anchor (0.5, 0), L 0 T 36, Align (0.5, 0),
-- SzB_1DMapSize 980 x 170; Img_1DMap_MidSection centred at T 101.17 (the line's height)
local BOX = { w = 980, h = 170, top = 36 }
local LINE_Y = 101.17123 - 36
local MAP_NAME, MID_NAME = "wbp_hud_positionmap", "img_1dmap_midsection"
local NAME_PREFIX = "SWGRCouchProgress"
local MAX_MARKERS = 15                 -- the native map draws 11 (P01..P11); instance fields may hold more
local MOVE_EPS = 1.5                   -- UI units a pill must move before it is written again
local PILL = { w = 64, h = 34 }        -- the native pills: ~9 x 5 px at 0.125 px / unit (2P screenshot r4)
local TICK = { w = 7, h = 76 }         -- lap line tick through the track line
local FLAG = { w = 30, h = 22, dx = 12, dy = 30 }   -- the flag hangs below the line, right of its tick
local CARS_MS, FLAGS_MS, HUDS_MS, CAL_MS, LAPS_MS, SCALE_MS = 1000, 250, 500, 1000, 2000, 1000

local R = nil                          -- this race world's state (reset on a world change)
local nameSeq = 0
local nameToken = tostring(os.time() % 100000) .. tostring(math.random(100, 999))
local brushBroken = false
local V = { X = 0, Y = 0 }             -- the one SetPosition argument table (UE4SS copies it at the call)

local function reset()
    R = { gen = St.worldGen, cars = {}, byKey = {}, mine = {}, carsAt = -1e12, flagsAt = -1e12, hudsAt = -1e12,
          calAt = -1e12, lapsAt = -1e12, nextMs = -1e12, strips = {}, failed = {}, maps = {}, laps = nil,
          cal = { half = nil, dir = 1, n = 0, spread = nil, ok = 0, loggedAt = -1e12 }, mode = "event",
          inst = false, stats = { builds = 0, writes = 0, ticks = 0, calOk = 0, calMiss = 0 } }
end

---------------------------------------------------------------------------------------------------- pure (tests)
-- A car `rel` event fractions ahead of the strip's owner (behind < 0): its place 0..1 on the strip and whether it is
-- pinned to an end. half = the event fraction from the middle to an end; dir = +1 ahead to the right.
function M.place(rel, half, dir)
    if not (type(rel) == "number" and type(half) == "number" and half > 0) then return 0.5, false end
    local x = 0.5 + (dir or 1) * rel / (2 * half)
    if x < 0 then return 0, true end
    if x > 1 then return 1, true end
    return x, false
end

-- The lap line nearest to pMe (event fraction) inside the window: rel (event fraction, ahead > 0) and true when it is
-- the finish line; nil when no line is in sight. Lines at k / nLaps, k = 0 (start) .. nLaps (finish).
function M.lapLine(pMe, nLaps, half)
    if type(pMe) ~= "number" or not (type(half) == "number" and half > 0) then return nil end
    local N = math.max(1, math.floor(tonumber(nLaps) or 1))
    local best, bk = nil, nil
    for k = 0, N do
        local rel = k / N - pMe
        if math.abs(rel) <= half and (best == nil or math.abs(rel) < math.abs(best)) then best, bk = rel, k end
    end
    if best == nil then return nil end
    return best, bk == N
end

local function median(t)
    table.sort(t)
    local n = #t
    if n == 0 then return nil end
    if n % 2 == 1 then return t[(n + 1) // 2] end
    return (t[n // 2] + t[n // 2 + 1]) / 2
end

-- P1's scale from his native map. markers = { {pos, clamped, out} } (CurrentMapParams.MarkerParams), rels = every
-- other running car's progress minus P1's. -> { half, dir, n, spread } or nil. The unclamped pills right / left of the
-- middle are the cars nearest to P1 on that side (ahead or behind: both readings are tried, the one with the smaller
-- relative spread wins; one pair keeps prevDir).
function M.fitScale(markers, rels, prevDir)
    local Ar, Al, Ba, Bb = {}, {}, {}, {}
    local centre = 0                                  -- pills ON the middle: as many cars nearest to P1 are dropped
    for _, m in ipairs(markers or {}) do
        if type(m.pos) == "number" and not m.clamped and not m.out then
            local d = m.pos - 0.5
            if d > 1e-3 then Ar[#Ar + 1] = d elseif d < -1e-3 then Al[#Al + 1] = -d else centre = centre + 1 end
        end
    end
    local rs = {}
    for _, r in ipairs(rels or {}) do if type(r) == "number" then rs[#rs + 1] = r end end
    table.sort(rs, function(a, b) return math.abs(a) < math.abs(b) end)
    for i = centre + 1, #rs do
        local r = rs[i]
        if r > 0 then Ba[#Ba + 1] = r elseif r < 0 then Bb[#Bb + 1] = -r end
    end
    table.sort(Ar); table.sort(Al); table.sort(Ba); table.sort(Bb)
    local function fit(dir)
        local right, left = (dir == 1) and Ba or Bb, (dir == 1) and Bb or Ba
        local hs = {}
        for i = 1, math.min(#Ar, #right) do hs[#hs + 1] = right[i] / (2 * Ar[i]) end
        for i = 1, math.min(#Al, #left) do hs[#hs + 1] = left[i] / (2 * Al[i]) end
        if #hs == 0 then return nil end
        local med = median(hs)
        local dev = {}
        for i, h in ipairs(hs) do dev[i] = math.abs(h - med) end
        local mad = median(dev) or 0
        return { half = med, dir = dir, n = #hs, spread = (med > 0) and (mad / med) or math.huge }
    end
    local a, b = fit(1), fit(-1)
    if not a then return b end
    if not b then return a end
    if a.n >= 2 and b.n >= 2 and math.abs(a.spread - b.spread) > 1e-9 then
        return (a.spread < b.spread) and a or b
    end
    if a.n ~= b.n then return (a.n > b.n) and a or b end
    return ((prevDir or 1) == -1) and b or a
end

-- The event fraction of a raw EventProgressNormalised: "event" = as is; "lap" = (lap - 1 + v) / laps.
function M.eventFrac(raw, mode, lap, laps)
    if type(raw) ~= "number" then return nil end
    if mode == "lap" then
        local N = math.max(1, math.floor(tonumber(laps) or 1))
        local l = math.max(1, math.floor(tonumber(lap) or 1))
        return (l - 1 + raw) / N
    end
    return raw
end

-- Strip x (0..1) -> the pill's centre in the 980-wide box.
function M.boxX(x)
    local span = tonumber(opt("HudProgressSpan", 0.9)) or 0.9
    return BOX.w / 2 + (x - 0.5) * BOX.w * span
end

---------------------------------------------------------------------------------------------------- helpers
local function on() return opt("HudProgress", true) ~= false end

local function field(o, k)
    local ok, v = pcall(U.getField, o, k)
    if ok then return v end
    return nil
end

local function lin(t, a)
    t = type(t) == "table" and t or {}
    return { R = tonumber(t.R or t[1]) or 1, G = tonumber(t.G or t[2]) or 1, B = tonumber(t.B or t[3]) or 1,
             A = (a or 1) * (tonumber(t.A or t[4]) or 1) }
end

local function classOf(paths)
    for _, p in ipairs(paths) do
        local c = U.findLoaded(p)                         -- /Script classes: always in memory (cached find)
        if U.ok(c) then return c end
    end
    return nil
end

local function newName(kind)
    nameSeq = nameSeq + 1
    return string.format("%s_%s_%s_%d", NAME_PREFIX, kind, nameToken, nameSeq)
end

-- StaticConstructObject(UClass, Outer, FName) (named: a later Lua state finds and removes it), unnamed as a fallback
local function construct(paths, outer, kind)
    local cls = classOf(paths)
    if not (U.ok(cls) and U.ok(outer)) then return nil end
    local FN = rawget(_G, "FName")
    local ok, w = false, nil
    if type(FN) == "function" then
        local okN, nm = pcall(FN, newName(kind))
        if okN then ok, w = pcall(StaticConstructObject, cls, outer, nm) end
        if ok and U.ok(w) then return w end
    end
    ok, w = pcall(StaticConstructObject, cls, outer)
    if ok and U.ok(w) then return w end
    return nil
end

local function fnameLower(w)
    if not U.ok(w) then return "" end
    local ok, s = pcall(function() return w:GetFName():ToString() end)
    return (ok and type(s) == "string") and string.lower(s) or ""
end

-- WBP_HUD_RaceInfo > WidgetTree > RootWidget (C_TopLayout) of a race HUD: root, tree, { lower name -> child }
local function topLayout(w)
    if not U.ok(w) then return nil end
    local ri = field(w, "WBP_HUD_RaceInfo")               -- BP variable (WBP_Hud_Race_C only)
    if not U.ok(ri) then return nil end
    local tree = field(ri, "WidgetTree")
    if not U.ok(tree) then return nil end
    local root = field(tree, "RootWidget")
    if not U.ok(root) then return nil end
    local kids = {}
    local okC, n = pcall(U.callMethod, root, "GetChildrenCount")
    for i = 0, ((okC and tonumber(n)) or 0) - 1 do
        local okK, ch = pcall(U.callMethod, root, "GetChildAt", i)
        if okK and U.ok(ch) then
            local nm = fnameLower(ch)
            if nm ~= "" then kids[nm] = ch end
        end
    end
    return root, tree, kids
end

-- the native map of a HUD (cached per HUD instance)
local function mapOf(w)
    local k = U.key(w)
    local c = R.maps[k]
    if c and c.w == w and (c.map == false or U.ok(c.map)) then return c.map or nil end
    local _, _, kids = topLayout(w)
    local map = kids and kids[MAP_NAME] or nil
    R.maps[k] = { w = w, map = U.ok(map) and map or false }
    return U.ok(map) and map or nil
end

local function instActive()
    local inst = lazy("instances")
    if not (inst and inst.active) then return false, nil end
    local ok, a = pcall(inst.active)
    return ok and a == true, inst
end

local function raceLaps()
    local vms = U.giSubsystem("ViewModelSubsystem")
    if not U.ok(vms) then return nil end
    local ok, vm = pcall(U.callMethod, vms, "GetRaceEventVM")
    if not (ok and U.ok(vm)) then return nil end
    local n = tonumber(field(vm, "NumLaps"))
    if n and n >= 1 then return math.floor(n) end
    return nil
end

---------------------------------------------------------------------------------------------------- cars
local function refreshCars(now)
    R.carsAt = now
    local gs = U.gs()
    if not U.ok(gs) then return end
    local vs = field(gs, "Vehicles")                     -- RacingGameState.Vehicles TArray<VehiclePawn*>
    local n = U.arrayCount(vs)
    local list, by = {}, {}
    for i = 1, n do
        local okV, v = pcall(U.getField, vs, i)
        if okV and U.ok(v) then
            local k = U.key(v)
            local e = R.byKey[k]
            if not (e and U.ok(e.pawn)) then e = { pawn = v, k = k } end
            if not U.ok(e.rm) then e.rm = field(v, "RouteMarker") end       -- VehiclePawn.RouteMarker
            if not U.ok(e.ps) then e.ps = field(v, "PlayerState") end
            if U.ok(e.ps) and not U.ok(e.comp) then e.comp = field(e.ps, "RaceEventComponent") end
            if U.ok(e.rm) then list[#list + 1] = e; by[k] = e end
        end
    end
    R.cars, R.byKey = list, by
    -- the local players' own cars (takeover: the car the PC drives now)
    local mine = {}
    for _, e in ipairs(list) do e.human = false end
    for _, lp in ipairs(U.localPlayersRO()) do
        local car = U.carOf(lp.pc)
        local e = car and by[U.key(car)] or nil
        if e then e.human = true; mine[U.key(lp.pc)] = e end
    end
    R.mine = mine
    R.stats.cars = #list
end

local function refreshFlags(now)
    R.flagsAt = now
    local act, inst = instActive()
    R.inst = act
    for _, e in ipairs(R.cars) do
        local c = e.comp
        if U.ok(c) then
            e.out = field(c, "bHasVehicleWrecked") == true or field(c, "bHasBeenEliminated") == true
                or field(c, "bHasBeenDisappeared") == true
            e.lap = tonumber(field(c, "CurrentLapNumber")) or e.lap
        end
        e.set = nil
        if act and U.ok(e.ps) then
            local ok, s = pcall(inst.setOf, e.ps)
            if ok then e.set = s end
        end
    end
end

local function sampleProgress()
    local laps = R.laps or 1
    for _, e in ipairs(R.cars) do
        local raw = nil
        if U.ok(e.rm) then raw = tonumber(field(e.rm, "EventProgressNormalised")) end
        if raw then
            if R.mode == "event" and e.raw and laps > 1 and not e.out and e.raw - raw > 0.5 then
                R.mode = "lap"
                R.cal.ring, R.cal.half = {}, nil                  -- the fits so far were made on the wrong reading
                U.log(TAG, "EventProgressNormalised wrapped (%.3f -> %.3f): read per lap from now on (V-HUD-PR4)",
                    e.raw, raw)
            end
            e.raw = raw
            e.p = M.eventFrac(raw, R.mode, e.lap, laps)
        else
            e.p = nil
        end
    end
end

---------------------------------------------------------------------------------------------------- scale
local function scale()
    local c = R.cal
    if opt("HudProgressScale", "p1") == "p1" and c.half then return c.half, c.dir end
    local laps = R.laps or 1
    return (tonumber(opt("HudProgressHalfLap", 0.12)) or 0.12) / laps, 1
end

local function calibrate(now, p1w)
    R.calAt = now
    if opt("HudProgressScale", "p1") ~= "p1" or not U.ok(p1w) then return end
    local map = mapOf(p1w)
    if not U.ok(map) then return end
    local p1e = R.mine[U.key(U.p1())]
    if not (p1e and p1e.p) then return end
    local mp = field(map, "CurrentMapParams")
    local arr = mp and field(mp, "MarkerParams") or nil
    local n = U.arrayCount(arr)
    local markers = {}
    for i = 1, math.min(n, 32) do
        local okM, m = pcall(U.getField, arr, i)
        if okM and m ~= nil then
            markers[#markers + 1] = { pos = tonumber(field(m, "NormalisedPos")), clamped = field(m, "bIsClamped") == true,
                                      out = field(m, "bIsWrecked") == true or field(m, "bIsEliminated") == true }
        end
    end
    local rels = {}
    for _, e in ipairs(R.cars) do
        if e ~= p1e and e.p and not e.out then rels[#rels + 1] = e.p - p1e.p end
    end
    local fit = M.fitScale(markers, rels, R.cal.dir)
    local c = R.cal
    if not (fit and fit.half and fit.half > 1e-5 and fit.half < 2) then
        R.stats.calMiss = R.stats.calMiss + 1
        if R.stats.calMiss == 20 and c.ok == 0 then
            U.log(TAG, "no scale from P1's map yet (%d marker(s), %d other car(s)): the strips use %.2f lap each side "
                .. "(V-HUD-PR2)", n, #rels, tonumber(opt("HudProgressHalfLap", 0.12)) or 0.12)
        end
        return
    end
    R.stats.calOk = R.stats.calOk + 1
    -- the median of the last 5 fits (5 s): one odd pairing (a pill on the middle, a car just wrecked) never shows
    c.ring = c.ring or {}
    c.ring[#c.ring + 1] = fit.half
    if #c.ring > 5 then table.remove(c.ring, 1) end
    local t = {}
    for i, h in ipairs(c.ring) do t[i] = h end
    c.half = median(t)
    c.dir, c.n, c.spread, c.ok = fit.dir, fit.n, fit.spread, c.ok + 1
    if c.ok == 1 or now - c.loggedAt >= 30000 then
        c.loggedAt = now
        local laps = R.laps or 1
        U.log(TAG, "scale from P1's map: %.3f lap(s) each side (%d pair(s), spread %.2f, ahead = %s, %d marker(s), "
            .. "%d car(s)) (V-HUD-PR2)", c.half * laps, fit.n, fit.spread, c.dir == 1 and "right" or "left", n, #R.cars)
    end
end

---------------------------------------------------------------------------------------------------- strips
local function setPos(e, x, y)
    V.X, V.Y = x, y
    local ok = U.pcallFn(e.s, SET_POS, "SetPosition", V)
    if ok then R.stats.writes = R.stats.writes + 1 end
    return ok
end

local function setVis(e, show)
    if e.shown == show then return end
    if pcall(U.callMethod, e.w, "SetVisibility", show and VIS.HitTestInvisible or VIS.Collapsed) then e.shown = show end
end

local function setTint(e, col)
    if e.col == col then return end
    if pcall(U.callMethod, e.w, "SetColorAndOpacity", col) then e.col = col end
end

-- an image on the strip's canvas (slot: anchor 0/0, centred on its position, fixed size), collapsed until placed
local function newImage(st, size, rounded)
    local img = construct(IMAGE, st.tree, "img")
    if not img then return nil end
    local okS, s = pcall(U.callMethod, st.cv, "AddChildToCanvas", img)  -- -> CanvasPanelSlot
    if not (okS and U.ok(s)) then return nil end
    pcall(U.callMethod, s, "SetAlignment", { X = 0.5, Y = 0.5 })
    pcall(U.callMethod, s, "SetSize", { X = size.w, Y = size.h })
    pcall(U.callMethod, s, "SetAutoSize", false)
    if rounded and not brushBroken and opt("HudProgressRound", true) ~= false then
        -- a RoundedBox brush without a resource (HalfHeightRadius: a pill); a struct param table is zero-filled
        local okB = pcall(U.callMethod, img, "SetBrush", {
            ImageSize = { X = size.w, Y = size.h }, DrawAs = 4, ImageType = 1,
            TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 },
            OutlineSettings = { CornerRadii = { X = 0, Y = 0, Z = 0, W = 0 }, Width = 0, RoundingType = 1,
                                Color = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 0 }, ColorUseRule = 0 } } })
        if not okB then
            brushBroken = true
            U.logOnce("progress.brush", TAG, "rounded pill brush refused: square pills")
        end
    end
    local e = { w = img, s = s, x = nil, shown = true, col = nil }
    setVis(e, false)
    return e
end

local function dropStrip(st, why)
    if not st then return end
    if U.ok(st.cv) then pcall(U.callMethod, st.cv, "RemoveFromParent") end
    if st.mapHidden and U.ok(st.map) then pcall(U.callMethod, st.map, "SetRenderOpacity", 1.0) end
    U.dbg(TAG, "P%s strip removed (%s)", tostring(st.pnum), tostring(why))
end

local function buildStrip(a, wantNativeHidden)
    local okC, cp = pcall(function() return U.pathOf(a.widget:GetClass()) end)   -- uobj: ensureStrips U.ok-checks it
    if not (okC and cp == C.BP.HudRace) then return nil, "not a WBP_Hud_Race_C HUD (" .. tostring(cp) .. ")" end
    local root, tree, kids = topLayout(a.widget)
    if not root then return nil, "no WBP_HUD_RaceInfo top bar (Memory HUD?)" end
    -- a previous Lua state's strip (hot reload): removed by its name
    for nm, ch in pairs(kids) do
        if nm:sub(1, #NAME_PREFIX) == string.lower(NAME_PREFIX) then pcall(U.callMethod, ch, "RemoveFromParent") end
    end
    local cv = construct(CANVAS, tree, "strip")
    if not cv then return nil, "canvas not constructed" end
    local okS, s = pcall(U.callMethod, root, "AddChildToCanvas", cv)
    if not (okS and U.ok(s)) then return nil, "AddChildToCanvas refused" end
    local map = kids[MAP_NAME]
    local pos = { X = 0, Y = BOX.top }
    if U.ok(map) then
        local ms = field(map, "Slot")
        if U.ok(ms) then
            local okP, p = pcall(U.callMethod, ms, "GetPosition")
            if okP and type(p) == "table" and tonumber(p.X) and tonumber(p.Y) then pos = { X = p.X, Y = p.Y } end
        end
    end
    pcall(U.callMethod, s, "SetAnchors", { Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } })
    pcall(U.callMethod, s, "SetAlignment", { X = 0.5, Y = 0 })
    pcall(U.callMethod, s, "SetPosition", pos)
    pcall(U.callMethod, s, "SetSize", { X = BOX.w, Y = BOX.h })
    pcall(U.callMethod, s, "SetAutoSize", false)
    pcall(U.callMethod, s, "SetZOrder", 4)
    pcall(U.callMethod, cv, "SetVisibility", VIS.HitTestInvisible)
    local st = { key = U.key(a.widget), w = a.widget, pc = a.pc, pnum = a.pnum, cv = cv, tree = tree, map = map,
                 mid = kids[MID_NAME], marks = {}, scaleK = nil, mapHidden = false }
    st.tick = newImage(st, TICK, false)
    st.flag = newImage(st, FLAG, false)
    if wantNativeHidden and U.ok(map) then
        st.mapHidden = pcall(U.callMethod, map, "SetRenderOpacity", 0.0)
        U.log(TAG, "P%s's native map hidden (opacity 0, still ticking for the scale): his strip shows his own "
            .. "instance only (V-HUD-PR3)", tostring(a.pnum))
    end
    R.stats.builds = R.stats.builds + 1
    U.log(TAG, "P%s race-progress strip in its HUD (top centre%s) (V-HUD-PR1)", tostring(a.pnum),
        U.ok(st.mid) and ", own mark = the HUD's centre triangle" or ", no centre triangle found")
    return st
end

-- the map's render scale / pivot (hud.lua's compact top bar runs the map at 0.6) on the strip, 1 Hz
local function syncScale(st)
    if not U.ok(st.map) then return end
    local rt = field(st.map, "RenderTransform")
    local sc = rt and field(rt, "Scale") or nil
    local sx = sc and tonumber(field(sc, "X")) or 1
    local sy = sc and tonumber(field(sc, "Y")) or sx
    local pv = field(st.map, "RenderTransformPivot")
    local px, py = pv and tonumber(field(pv, "X")) or 0.5, pv and tonumber(field(pv, "Y")) or 0.5
    local k = string.format("%.3f:%.3f:%.3f:%.3f", sx, sy, px, py)
    if st.scaleK == k then return end
    if pcall(U.callMethod, st.cv, "SetRenderTransformPivot", { X = px, Y = py })
        and pcall(U.callMethod, st.cv, "SetRenderScale", { X = sx, Y = sy }) then
        st.scaleK = k
    end
end

local function ensureStrips(now)
    R.hudsAt = now
    local hud = lazy("hud")
    if not (hud and hud.allHuds) then return end
    local ok, huds = pcall(hud.allHuds)
    if not ok or type(huds) ~= "table" then return end
    local inst = R.inst
    local want = {}
    R.p1w = nil
    for _, a in ipairs(huds) do
        if a.pnum == 1 then R.p1w = a.widget end
        if U.ok(a.widget) and U.ok(a.pc) and (a.pnum ~= 1 or inst) then
            local k = U.key(a.widget)
            want[k] = true
            local st = R.strips[k]
            if st and not (st.w == a.widget and U.ok(st.cv)) then dropStrip(st, "stale"); R.strips[k] = nil; st = nil end
            if not st and not R.failed[k] then
                local s, why = buildStrip(a, a.pnum == 1)
                if s then
                    R.strips[k] = s
                else
                    R.failed[k] = true
                    U.logOnce("progress.fail." .. tostring(why), TAG, "P%s: no race-progress strip (%s)", tostring(a.pnum),
                        tostring(why))
                end
            end
            st = R.strips[k]
            if st then st.pc, st.pnum = a.pc, a.pnum end
        end
    end
    for k, st in pairs(R.strips) do
        if not want[k] then dropStrip(st, "not wanted"); R.strips[k] = nil end
    end
end

local function render(st)
    local me = R.mine[U.key(st.pc)]
    local half, dir = scale()
    local n = 0
    if me and me.p then
        local set = R.inst and me.set or nil
        local colAi = st.colAi or lin(opt("HudProgressColour", nil))
        local colHu = st.colHu or lin(opt("HudProgressHumanColour", nil))
        local colAiPin = st.colAiPin or lin(opt("HudProgressColour", nil), 0.45)
        local colHuPin = st.colHuPin or lin(opt("HudProgressHumanColour", nil), 0.45)
        st.colAi, st.colHu, st.colAiPin, st.colHuPin = colAi, colHu, colAiPin, colHuPin
        for _, e in ipairs(R.cars) do
            if e ~= me and e.p and not e.out and (not R.inst or (set ~= nil and e.set == set)) then
                if n >= MAX_MARKERS then break end
                n = n + 1
                local mk = st.marks[n]
                if not mk then
                    mk = newImage(st, PILL, true)
                    if not mk then n = n - 1; break end
                    st.marks[n] = mk
                end
                local x, pinned = M.place(e.p - me.p, half, dir)
                local bx = M.boxX(x)
                if mk.x == nil or math.abs(mk.x - bx) >= MOVE_EPS then
                    if setPos(mk, bx, LINE_Y) then mk.x = bx end
                end
                if e.human then setTint(mk, pinned and colHuPin or colHu) else setTint(mk, pinned and colAiPin or colAi) end
                setVis(mk, true)
            end
        end
    end
    for i = n + 1, #st.marks do setVis(st.marks[i], false) end
    st.n = n
    -- the lap / finish line
    local rel, fin = nil, false
    if me and me.p then rel, fin = M.lapLine(me.p, R.laps or 1, half) end
    if rel and st.tick and st.flag then
        local x = M.place(rel, half, dir)
        local bx = M.boxX(x)
        if st.tick.x == nil or math.abs(st.tick.x - bx) >= MOVE_EPS then
            if setPos(st.tick, bx, LINE_Y) then st.tick.x = bx end
            if setPos(st.flag, bx + FLAG.dx, LINE_Y + FLAG.dy) then st.flag.x = bx end
        end
        setTint(st.tick, st.colAi or lin(opt("HudProgressColour", nil)))
        if fin then
            st.colFin = st.colFin or lin(opt("HudProgressFinishColour", nil))
            setTint(st.flag, st.colFin)
        else
            setTint(st.flag, st.colAi or lin(opt("HudProgressColour", nil)))
        end
        setVis(st.tick, true); setVis(st.flag, true)
    else
        if st.tick then setVis(st.tick, false) end
        if st.flag then setVis(st.flag, false) end
    end
end

---------------------------------------------------------------------------------------------------- loop
-- FAST loop (main.lua, race phases): everything inside its own timers.
function M.fastTick()
    if not on() then return end
    local ph = St.phase
    if ph ~= "PRERACE" and ph ~= "RACING" then return end
    if not R or R.gen ~= St.worldGen then
        if R then for _, st in pairs(R.strips) do dropStrip(st, "world") end end
        reset()
    end
    local now = St.nowMs()
    if now < R.nextMs then return end
    R.nextMs = now + (tonumber(opt("HudProgressMs", 33)) or 33) - 1
    R.stats.ticks = R.stats.ticks + 1
    -- the HUD list first (2 Hz): no strip (one player, no HUD yet) = no car work at all
    if now - R.hudsAt >= HUDS_MS then
        if now - R.flagsAt >= FLAGS_MS then refreshFlags(now) end   -- R.inst: who gets a strip
        ensureStrips(now)
    end
    if next(R.strips) == nil then return end
    if now - R.carsAt >= CARS_MS then refreshCars(now); refreshFlags(now) end
    if now - R.flagsAt >= FLAGS_MS then refreshFlags(now) end
    if (R.laps == nil or now - R.lapsAt >= 30000) and now - R.lapsAt >= LAPS_MS then
        R.lapsAt = now
        R.laps = raceLaps() or R.laps
    end
    sampleProgress()
    if not R.dataLogged and R.laps then
        -- V-HUD-PR5 (live check of the data reading): the local players' cars as the strip reads them
        R.dataLogged = true
        local parts = {}
        for _, lp in ipairs(U.localPlayersRO()) do
            local e = R.mine[U.key(lp.pc)]
            if e then
                parts[#parts + 1] = string.format("P%d %.4f (EventProgress %s, DistanceToFinish %s)", lp.index, e.raw or -1,
                    tostring(field(e.rm, "EventProgress")), tostring(field(e.rm, "DistanceToFinish")))
            end
        end
        U.log(TAG, "data: %d car(s), %d lap(s), EventProgressNormalised %s (V-HUD-PR5)", #R.cars, R.laps,
            #parts > 0 and table.concat(parts, "; ") or "no local car")
    end
    if now - R.calAt >= CAL_MS then calibrate(now, R.p1w) end
    local doScale = now - (R.scaleAt or -1e12) >= SCALE_MS
    if doScale then R.scaleAt = now end
    for k, st in pairs(R.strips) do
        if U.ok(st.cv) and U.ok(st.w) then
            if doScale then syncScale(st) end
            render(st)
        else
            R.strips[k] = nil
        end
    end
end

-- hud.lua (collapseGlobalParts): the guest-HUD members it must leave visible while the strip runs (lower-case names).
-- Race HUD only: the Memory HUD's map is vertical (O_1D_Map at the right edge), no strip there.
function M.guestKeeps(w)
    if not on() or not U.ok(w) then return nil end
    local ok, p = pcall(function() return U.pathOf(w:GetClass()) end)
    if ok and p == C.BP.HudRace then return { [MID_NAME] = true } end
    return nil
end

function M.status()
    if not R then return "progress: idle" end
    local n = 0
    for _ in pairs(R.strips) do n = n + 1 end
    local c = R.cal
    return string.format("progress: %d strip(s), %d car(s), laps %s, mode %s, scale %s (%s), builds %d, writes %d, "
        .. "ticks %d, cal %d/%d", n, #R.cars, tostring(R.laps), R.mode,
        c.half and string.format("%.3f lap", c.half * (R.laps or 1)) or "default", c.half and "P1" or "fixed",
        R.stats.builds, R.stats.writes, R.stats.ticks, R.stats.calOk, R.stats.calOk + R.stats.calMiss)
end

function M._state() return R end

function M.init()
    St.on("leaving", TAG, function()
        if R then for _, st in pairs(R.strips) do dropStrip(st, "leaving") end end
        R = nil
    end)
    St.on("world", TAG, function() R = nil end)
end

return M
