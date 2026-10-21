-- gppage.lua (0.16): the GALACTIC GRAND PRIX page (design galactic-racer/notes/design/galactic-grand-prix.md). The
-- FREE MODE poster formerly GALAXY RUN opens it. Built like couchpage.lua, in the FREE MODE page's own language (theme
-- kit: the menu paper, the game's screen title, posters over ghosts, the SETTINGS rows, the command row's pills), one
-- page with four views on their own canvases:
--   hub       5 tour posters (PODRACER TOUR · PLANET TOUR · PLANET CHAMPIONSHIP · GALACTIC CHAMPIONSHIP · CUSTOM)
--   setup     the race list (one row per slot: track thumbnail, name, planet + layout; LEFT / RIGHT steps the track,
--             the last step is RANDOM), the tour's rows (PLANET / RACES / UPGRADES / ORDER / AI / each player's
--             VEHICLE; CUSTOM's own rows), command row BACK / START GRAND PRIX
--   standings the last race's finish + the championship table, command row BACK / NEXT RACE / END GRAND PRIX (A twice)
--   podium    three posters stepped 2-1-3 with the medals, command row BACK / DONE / TABLE
-- Input: CommonUI focus on ghosts (A = the ghost's action), LEFT / RIGHT on a row through two focus traps (lobby's
-- OPTIONS pattern, V-FIN-04) or keyboard left / right (onKey); P1's pad B / Backspace close (lobby's B poll and
-- backprompt.lua, as for couchpage). The texts come from pure view models (M.slotView / M.optionRows /
-- M.standingsRows / M.podiumView), tested offline in tools/test_gp.lua. Every game call is pcall-guarded.
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")

local TAG = "gppage"
local M = {}

local function ui() return U.mod("ui") end
local function gp() return U.mod("gp") end
local function TH() return U.mod("theme") end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local VIS = C.E.Vis
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local TXM = "/Game/Griffin/UI/Library/Textures/Content/MainMenu/"
local TXI = "/Game/Griffin/UI/Library/Textures/"
local function tex(dir, n) return dir .. n .. "." .. n end
local DOT = "\u{00B7}"

-- the tour posters' art (MainMenu multiplayer key art, wide: the poster crops it) and focus point
local ART = {
    pod      = { tex(TXM, "T_UI_FE_Tile_MP_06"), 0.62, 0.5 },
    planet   = { tex(TXM, "T_UI_FE_Tile_MP_04"), 0.72, 0.5 },
    champ    = { tex(TXM, "T_UI_FE_Tile_MP_03"), 0.55, 0.5 },
    galactic = { tex(TXM, "T_UI_FE_Tile_MP_01"), 0.16, 0.5 },
    custom   = { tex(TXM, "T_UI_FE_Tile_MP_05"), 0.45, 0.5 },
}
local MEDAL = { tex(TXI .. "Icons/Leaderboard/", "T_UI_LeaderboardMedal_Gold"),
                tex(TXI .. "Icons/Leaderboard/", "T_UI_LeaderboardMedal_Silver"),
                tex(TXI .. "Icons/Leaderboard/", "T_UI_LeaderboardMedal_Bronze") }
local RANDOM_ART = tex(TXI .. "Backgrounds/", "T_UI_MapEvent_Bg")

---------------------------------------------------------------------------------------------------- geometry (screen su)
-- 0.16.1 (live 2026-10-15, Jules "looks weird"): hub posters the FREE MODE tile size (663 x 700) with a two-line
-- caption under each and a BACK pill; the setup's race list as tall game-style rows (backer, number, 16:9 thumbnail,
-- name over planet / layout, arrows on focus) packed to the list's height; the right column a group header, the hint,
-- backed option rows and a preview poster of the focused race; the command pills sized to their labels.
local HUB = { x = 128, y = 500, w = 663, h = 700, gap = 67, capY = 1250, titleSize = 48 }
-- #24: the hub's players row (group header, one row of seats, one line); ends at y1 (BACK pill at y 1880)
local PLAYERS_ROW = { x = 128, x1 = 3712, head = 1540, y = 1630, pitch = 880, line = 1730, y1 = 1780 }
local LIST = { x = 128, w = 1904, y0 = 450, y1 = 1850, maxPitch = 166, gap = 14 }
local OPTC = { x = 2200, w = 1512, head = 470, hint = 530, y = 660, pitch = 104, h = 92, bottom = 1850 }
local PREVIEW = { big = { 2200, 1180, 1512, 660 }, small = { 2200, 1450, 1512, 390 } }
local TABLE_L = { x = 128, w = 1640, y = 540, pitch = 86, h = 80 }
local TABLE_R = { x = 1960, w = 1752, y = 540, pitch = 86, h = 80 }
local POD = { y = 520, w = 760, gap = 60, h = { 1100, 940, 800 } }
local MAX_SLOTS, MAX_OPTS, MAX_ROWS = 12, 17, 12

---------------------------------------------------------------------------------------------------- view models (pure)
local function planetName(k) return (gp().PLANET_NAME or {})[k] or string.upper(tostring(k or "")) end

local function artFor(e, dr)
    local okS, setup = pcall(U.mod, "setup")
    if not okS or type(setup) ~= "table" or type(setup.trackArt) ~= "function" then return nil end
    local cls = (e and e.group == "pod") and "Plane" or (dr and dr.classes and dr.classes[1]) or "Car"
    local ok, p = pcall(setup.trackArt, e and e.key, e and e.planet, cls)
    return ok and p or nil
end

-- slot i of a draft: {num = "01", title, sub, art, random}
function M.slotView(dr, i)
    local k = dr and dr.slots and dr.slots[i]
    if not k then return nil end
    local num = string.format("%02d", i)
    if k == "random" then
        local where = dr.planet and planetName(dr.planet) or "ANY PLANET"
        return { num = num, title = "RANDOM TRACK", sub = "DRAWN AT THE START " .. DOT .. " " .. where, art = RANDOM_ART,
                 random = true }
    end
    local e = gp().findTrack(k)
    if not e then return { num = num, title = tostring(k), sub = "", art = RANDOM_ART } end
    local sub = planetName(e.planet)
    if e.layout and e.layout ~= "" then sub = sub .. " " .. DOT .. " " .. e.layout end
    if k == gp().FINALE and i == #dr.slots then sub = sub .. " " .. DOT .. " FINALE" end
    return { num = num, title = e.name, sub = sub, art = artFor(e, dr) }
end

-- the setup's option rows for a draft and the current humans {pnum}: list of {key, label, value, kind}
function M.optionRows(dr, humans)
    local GPM = gp()
    local t = GPM.tour(dr.tour) or {}
    local rows = {}
    local function add(key, label, value, kind) rows[#rows + 1] = { key = key, label = label, value = value, kind = kind or "cycle" } end
    if t.planet then add("planet", "Planet", planetName(dr.planet)) end
    if not t.fixed then add("count", "Races", tostring(dr.count or #dr.slots))
    else add("count", "Races", string.format("%d %s EVERY CIRCUIT", #dr.slots, DOT), "value") end
    add("upgrades", "Upgrades", GPM.upgradesText(dr.upgrades))
    add("order", "Order", GPM.orderText(dr.order))
    add("ai", "AI", GPM.aiText(dr.ai))
    local rule = GPM.vehicleRule(dr)
    if dr.custom then
        local vword = ({ each = "EACH PLAYER PICKS", same = "SAME FOR ALL", pods = "PODRACERS" })[dr.custom.vehicles]
        add("vehicles", "Vehicles", vword or "?")
        local g = dr.custom.grid
        add("grid", "AI racers", g == "full" and "FULL GRID" or tostring(g))
        add("weather", "Weather", dr.custom.weather == "random" and "RANDOM" or "TRACK DEFAULT")
        add("catchup", "Catch-up", dr.custom.catchup and "ON" or "OFF", "toggle")
        add("noAbilities", "Abilities", dr.custom.noAbilities and "OFF" or "ON", "toggle")
    end
    for _, h in ipairs(humans or {}) do
        if rule == "each" or (rule == "same" and h.pnum == 1) then
            add("class" .. h.pnum, string.format("P%d vehicle", h.pnum), GPM.CLASS_LABEL[dr.classes[h.pnum] or "Car"])
        end
    end
    if dr.custom then
        for _, h in ipairs(humans or {}) do
            local v = tonumber(dr.custom.handicap[h.pnum]) or 0
            add("hcap" .. h.pnum, string.format("P%d handicap", h.pnum),
                v == 0 and "NONE" or string.format("%+d LEVELS", v))
        end
    end
    return rows
end

-- #24 the hub's players row (pure): the humans {pnum, name} as seats {pnum, tag, text}, then (canJoin) the open seats up
-- to 4 {open = true, tag = "P<n>", text = "PRESS (A) TO JOIN"}; no points anywhere (Jules: "useless to know")
M.HUB_LINE = "Up to 4 players " .. DOT .. " podium after the final race"
function M.hubSeats(hs, canJoin)
    local out, used = {}, {}
    for _, h in ipairs(hs or {}) do
        if #out < 4 and h.pnum then
            out[#out + 1] = { pnum = h.pnum, tag = "P" .. h.pnum, text = tostring(h.name or ("Player " .. h.pnum)) }
            used[h.pnum] = true
        end
    end
    if canJoin then
        for p = 1, 4 do
            if #out >= 4 then break end
            if not used[p] then out[#out + 1] = { pnum = p, open = true, tag = "P" .. p, text = "PRESS (A) TO JOIN" } end
        end
    end
    return out
end
-- pads can join right now (our tab's join session open, not a frozen client set)
function M.canJoin()
    return St.join and St.join.active == true and St.join.frozen ~= true
end

-- couch-fix63 (AUTO-154e, live round 8: 12 racers, the 11th-placed AI left out while P2 at 12th was listed - the lists
-- kept "the top 10 + every human"): the rows a list of max lines shows (pure). Every row when they fit; else the top of
-- the table, as many as leave room for every human below it.
function M.fitRows(rows, max)
    rows, max = rows or {}, tonumber(max) or 0
    if #rows <= max then
        local all = {}
        for i, r in ipairs(rows) do all[i] = r end
        return all
    end
    local k = max
    while k > 0 do
        local below = 0
        for i = k + 1, #rows do if rows[i].human then below = below + 1 end end
        if k + below <= max then break end
        k = k - 1
    end
    local out = {}
    for i = 1, k do out[#out + 1] = rows[i] end
    for i = k + 1, #rows do if rows[i].human and #out < max then out[#out + 1] = rows[i] end end
    return out
end

-- championship rows (best first) {rank, name, value, human, pnum}; the last race's rows {rank, name, value}
function M.standingsRows(gs)
    local out = {}
    for i, r in ipairs(gp().standings(gs)) do
        local pnum = nil
        if r.human then
            local p = gs.players[tonumber(tostring(r.id):sub(2))]
            pnum = p and p.pnum
        end
        out[i] = { rank = i, name = r.name, value = string.format("%d PTS %s %d WIN%s", r.points, DOT, r.wins,
                   r.wins == 1 and "" or "S"), human = r.human, pnum = pnum, points = r.points }
    end
    return out
end

function M.lastRaceRows(gs)
    local h = gs and gs.history and gs.history[#gs.history]
    if not h then return {}, nil end
    local out = {}
    for _, r in ipairs(h.res or {}) do
        out[#out + 1] = { rank = r.place, name = r.name, value = r.dnf and "DNF" or string.format("+%d PTS", r.pts),
                          human = r.human }
    end
    return out, h
end

-- the podium {first, second, third}: {name, points, human, title, art}
function M.podiumView(gs)
    local Pm = nil
    pcall(function() Pm = U.mod("pilots") end)
    local out = {}
    for i, r in ipairs(gp().podium(gs)) do
        if r then
            local art, pnum = nil, nil
            if r.human then
                local p = (gs.players or {})[tonumber(tostring(r.id):sub(2))]
                pnum = p and p.pnum
                if Pm then pcall(function() art = p and p.pilotId and Pm.byId(p.pilotId).full end) end
            end
            out[i] = { name = r.name, points = r.points, human = r.human, pnum = pnum,
                       place = ({ "1ST", "2ND", "3RD" })[i],
                       title = ({ "1ST", "2ND", "3RD" })[i] .. "\n" .. tostring(r.name), art = art }
        end
    end
    return out
end

-- Live 2026-10-15 (ggp-live2 71-72): the podium cards were washed out - BEIGE titles straight on the light pilot art
-- (grey studio background) and the idle art tint. Each card now has a SOLID nameplate: a human's in his player colour
-- with that colour's tag ink (consts COLOURS / COLOUR_INK), an AI racer's on the campaign's dark pill with BEIGE ink.
-- pure: e (a podiumView entry) -> {plate = colour, ink = colour}
local PLATE_AI = { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.94 }      -- #131313 (B_CurrencyHolder) @0.94
local INK_AI = { R = 0.7758, G = 0.7305, B = 0.6654, A = 1 }           -- BEIGE #E4DED5
function M.podiumStyle(e)
    if type(e) == "table" and e.human and e.pnum then
        local c, k = (C.COLOURS or {})[e.pnum], (C.COLOUR_INK or {})[e.pnum]
        if type(c) == "table" and type(k) == "table" then
            return { plate = { R = c.R, G = c.G, B = c.B, A = 1 }, ink = k }
        end
    end
    return { plate = PLATE_AI, ink = INK_AI }
end
M.PLATE_H = 300

---------------------------------------------------------------------------------------------------- page state
local W = nil
local S = { active = false, view = "hub", tour = nil, draft = nil, backMs = -1e12, openWanted = 0, wantView = nil,
            lastRow = nil, lrAtMs = -1e12, endArmMs = -1e12, endUntil = 0, sig = {} }
local lastBuild = nil

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

-- a full-page sub-canvas on the page canvas (one per view; collapsed hides its ghosts from CommonUI too)
local function subCanvas(tree, parent)
    local cv = mk(CANVAS, tree)
    if not cv then error("view canvas not created") end
    local s = parent:AddChildToCanvas(cv)
    if U.ok(s) then
        pcall(function() s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } }) end)
        pcall(function() s:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
    end
    pcall(function() cv:SetVisibility(VIS.Collapsed) end)
    return cv
end

local function humans()
    local ok, h = pcall(function() return gp().humans() end)
    return (ok and type(h) == "table") and h or { { pnum = 1, ctrlId = 0, name = "P1" } }
end
local function pnums()
    local out = {}
    for _, h in ipairs(humans()) do out[#out + 1] = h.pnum end
    return out
end

---------------------------------------------------------------------------------------------------- build
-- the hub posters' titles: one size for all five (the FREE MODE tile's 663 su leave ~560 for a word: CHAMPIONSHIP at 48
-- is ~640, so it is split), and the caption line under each poster
local HUB_TITLE = { pod = "PODRACER\nTOUR", planet = "PLANET\nTOUR", champ = "PLANET\nCHAMPIONSHIP",
                    galactic = "GALACTIC\nCHAMPIONSHIP", custom = "CUSTOM" }
-- live2 (Jules: "CHAMPION-/SHIP looks broken"): a title whose longest line overflows the poster gets a smaller size
-- (only the CHAMPIONSHIP posters); the poster's title runs from x 72 with a 40 su margin on the right
local function hubTitleSize(T, title)
    local widest = 0
    for line in (tostring(title) .. "\n"):gmatch("(.-)\n") do
        local okW, tw = pcall(T.textWidth, line, "posterTitle", HUB.titleSize)
        if okW and tonumber(tw) and tw > widest then widest = tw end
    end
    local room = HUB.w - 72 - 48
    if widest <= room then return HUB.titleSize end
    return math.max(28, math.floor(HUB.titleSize * room / widest))
end
M._hubTitleSize = hubTitleSize
local HUB_DESC = {
    pod      = "Podracers only: the Quick Podrace tracks and the Podracing Tour. Pick your pod on the racer cards.",
    planet   = "A few circuits of one planet. Each player races their own vehicle class.",
    champ    = "Every circuit of one planet, in order. Each player races their own vehicle class.",
    galactic = "One race per planet, the Galactic Gauntlet as the finale.",
    custom   = "Any track, any vehicle rule, AI grid, weather, catch-up and handicaps.",
}
function M.hubTitle(key) return HUB_TITLE[key] end

-- command pills sized to their labels, packed right to left from BACK (the game's slot)
local function cmdDefs(T, defs)
    local F = T.FRAME.cmd
    local x = F.slots.back[1]
    for _, d in ipairs(defs) do
        if d.id == "back" then
            d.rect = { F.slots.back[1], F.y, F.slots.back[3], F.h }
        else
            local okW, tw = pcall(T.textWidth, d.label, "heroLabel")
            local w = math.max(F.slots.start[3], math.floor(((okW and tonumber(tw)) or 600) + 170))
            x = x - F.gap - w
            d.rect = { x, F.y, w, F.h }
        end
    end
    return defs
end

local function buildHub(w, T, ctx, geo)
    local cv = w.views.hub
    local function LR(x, y, ww, hh) return { x - geo.x, y - geo.y, ww, hh } end
    w.hub = { posters = {}, ghosts = {}, caps = {}, descs = {} }
    for i, t in ipairs(gp().TOURS) do
        local x = HUB.x + (i - 1) * (HUB.w + HUB.gap)
        local rect = { x, HUB.y, HUB.w, HUB.h }
        local a = ART[t.key] or ART.custom
        local okP, p = pcall(T.poster, ctx, cv, rect, { geo = geo, z = 1, art = a[1], ax = a[2], ay = a[3],
            title = HUB_TITLE[t.key] or t.title, titleSize = hubTitleSize(T, HUB_TITLE[t.key] or t.title) })
        if okP and p then w.hub.posters[t.key] = p end
        local okG, gh = pcall(T.ghost, ctx, cv, rect, "gppage:tour:" .. t.key, function() M.onTour(t.key) end,
            { geo = geo })
        if okG and U.ok(gh) then w.hub.ghosts[#w.hub.ghosts + 1] = gh; w.hub.ghosts[t.key] = gh end
        -- the caption under the poster: the draft's summary (bold) over the tour's one-line description
        -- live2 (Jules: the CUSTOM description is hard to read over the red / teal stripes): a soft cream plate under
        -- both lines, the poster's width
        pcall(function()
            w.hub.plates = w.hub.plates or {}
            w.hub.plates[t.key] = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 18, size = { HUB.w, 210 },
                tint = T.alpha(T.COL.PAGE, 0.85), z = 1, rect = LR(x, HUB.capY - 16, HUB.w, 210) })
        end)
        pcall(function()
            w.hub.caps[t.key] = T.text(ctx, cv, "rowValue", { z = 2, colour = T.COL.INK, text = "", wrapW = HUB.w,
                rect = LR(x + 4, HUB.capY) })
            w.hub.descs[t.key] = T.text(ctx, cv, "helpFoot", { z = 2, colour = T.COL.NEAR, wrapW = HUB.w - 8,
                text = HUB_DESC[t.key] or t.kicker or "", rect = LR(x + 4, HUB.capY + 54) })
        end)
    end
    for i = 1, #w.hub.ghosts - 1 do
        pcall(function() T.nav(w.hub.ghosts[i], "right", w.hub.ghosts[i + 1]); T.nav(w.hub.ghosts[i + 1], "left", w.hub.ghosts[i]) end)
    end
    -- #24 (playtest 2026-10-17, Jules: the white points banner was ugly and the points table useless): no backer box and
    -- no points. The game's own group header ("PLAYERS" + its ink rule, as the setup's option column) over one row of
    -- seats: a P-tag pill in the player's colour + the name, open seats as a pale tag + "PRESS (A) TO JOIN" while pads
    -- can join; one short line under it. It ends at PLAYERS_ROW.y1, well above the command row (BACK at y 1880).
    pcall(function()
        w.hub.head = T.groupHeader(ctx, cv, PLAYERS_ROW.x, PLAYERS_ROW.x1, PLAYERS_ROW.head, "PLAYERS", { geo = geo })
        w.hub.cells, w.hub.tags, w.hub.tagTexts = {}, {}, {}
        for i = 1, 4 do
            local x = PLAYERS_ROW.x + (i - 1) * PLAYERS_ROW.pitch
            w.hub.tags[i] = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 12, size = { 76, 50 },
                tint = T.PLAYER[i] or T.COL.WHITE, z = 1, visible = false, rect = LR(x, PLAYERS_ROW.y, 76, 50) })
            w.hub.tagTexts[i] = T.text(ctx, cv, "rowValue", { colour = T.COL.INK, z = 2, size = 34, text = "",
                align = { 0.5, 0.5 }, rect = LR(x + 38, PLAYERS_ROW.y + 25) })
            w.hub.cells[i] = T.text(ctx, cv, "rowLabel", { colour = T.COL.INK, z = 2, text = "", align = { 0, 0.5 },
                rect = LR(x + 100, PLAYERS_ROW.y + 25) })
        end
        w.hub.sub = T.text(ctx, cv, "hint", { colour = T.COL.NEAR, z = 2, rect = LR(PLAYERS_ROW.x, PLAYERS_ROW.line),
            text = M.HUB_LINE })
    end)
    local okC, cmd = pcall(T.commandRow, ctx, cv, geo, cmdDefs(T, {
        { id = "back", label = "BACK", ghostId = "gppage:hub:back", fn = function() M.close("BACK") end } }))
    if okC and cmd then
        w.hub.cmd = cmd
        local back = cmd.widget("back")
        for _, gh in ipairs(w.hub.ghosts) do pcall(T.nav, gh, "down", back) end
        pcall(T.nav, back, "up", w.hub.ghosts[1])
    end
end

-- one race-list row: backer, number, 16:9 thumbnail, name over planet / layout, the cycle arrows (focused), a ghost
local function slotRow(T, ctx, cv, geo, i)
    local e = { i = i }
    local function el(fn) local ok, v = pcall(fn); if ok then return v end; return nil end
    e.bg = el(function() return T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 21, size = { LIST.w, 150 },
        tint = T.alpha(T.COL.WHITE, 0.42), z = 1, rect = { 0, 0, LIST.w, 100 } }) end)
    e.num = el(function() return T.text(ctx, cv, "groupHeader", { z = 3, colour = T.COL.INK, text = string.format("%02d", i),
        align = { 0.5, 0.5 }, rect = { 0, 0 } }) end)
    e.thumb = el(function() return T.image(ctx, cv, { z = 2, rect = { 0, 0, 160, 90 }, visible = false }) end)
    e.title = el(function() return T.text(ctx, cv, "rowLabel", { z = 3, text = "", align = { 0, 0.5 }, rect = { 0, 0 } }) end)
    e.sub = el(function() return T.text(ctx, cv, "rowValue", { z = 3, text = "", align = { 0, 0.5 }, rect = { 0, 0 } }) end)
    e.al = el(function() return T.image(ctx, cv, { tex = T.TEX.ArrowB, z = 3, align = { 0.5, 0.5 }, rect = { 0, 0, 30, 30 },
        visible = false }) end)
    e.ar = el(function() return T.image(ctx, cv, { tex = T.TEX.ArrowB, z = 3, flipX = true, align = { 0.5, 0.5 },
        rect = { 0, 0, 30, 30 }, visible = false }) end)
    e.ghost = el(function() return T.ghost(ctx, cv, { LIST.x, LIST.y0, LIST.w, 100 }, "gppage:slot" .. i,
        function() M.step("slot" .. i, 1) end, { geo = geo }) end)
    -- the settingsRow-like surface the rest of the page uses (row.ghost / row.poll / row.show)
    local row = { ghost = e.ghost, st = {} }
    e.row = row
    local function paint()
        local foc, on = row.st.focused == true, row.st.shown ~= false
        local ink = foc and T.COL.WHITE or T.COL.INK
        pcall(T.set, e.bg, { visible = on, colour = foc and T.COL.RUST or T.alpha(T.COL.WHITE, 0.42) })
        pcall(T.set, e.num, { visible = on, colour = ink })
        pcall(T.set, e.title, { visible = on, colour = foc and T.COL.WHITE or T.COL.NEAR })
        pcall(T.set, e.sub, { visible = on, colour = foc and T.COL.WHITE or T.COL.INK })
        local arrows = on and foc and row.st.cycle == true
        pcall(T.set, e.al, { visible = arrows, colour = T.COL.WHITE })
        pcall(T.set, e.ar, { visible = arrows, colour = T.COL.WHITE })
    end
    -- place the row at y with height h (screen su)
    function row.place(y, h)
        if row.st.y == y and row.st.h == h then return end
        row.st.y, row.st.h = y, h
        local lx, ly = LIST.x - geo.x, y - geo.y
        local th = h - 16
        local tw = math.floor(th * 16 / 9)
        local big = h >= 130
        pcall(T.set, e.bg, { rect = { lx, ly, LIST.w, h } })
        pcall(T.set, e.num, { rect = { lx + 66, ly + h / 2 }, size = big and 54 or 42 })
        pcall(T.set, e.thumb, { rect = { lx + 132, ly + 8, tw, th } })
        local tx = lx + 132 + tw + 40
        pcall(T.set, e.title, { rect = { tx, ly + h * 0.36 }, size = big and 44 or 36 })
        pcall(T.set, e.sub, { rect = { tx, ly + h * 0.72 }, size = big and 32 or 27 })
        pcall(T.set, e.al, { rect = { lx + LIST.w - 120, ly + h / 2, 34, 34 } })
        pcall(T.set, e.ar, { rect = { lx + LIST.w - 56, ly + h / 2, 34, 34 } })
        pcall(T.set, e.ghost, { rect = { lx, ly, LIST.w, h } })
    end
    function row.set(f)
        if f.label ~= nil then pcall(T.set, e.title, { text = f.label }) end
        if f.value ~= nil then pcall(T.set, e.sub, { text = f.value }) end
        if f.art ~= nil then
            row.st.art = f.art
            pcall(T.set, e.thumb, { tex = f.art, visible = row.st.shown ~= false })
        end
        if f.cycle ~= nil then row.st.cycle = f.cycle end
        -- #22: a fixed list (PLANET CHAMPIONSHIP) is display-only: its ghost leaves CommonUI's navigation
        if f.nav ~= nil and row.st.nav ~= f.nav then
            row.st.nav = f.nav
            pcall(T.set, e.ghost, { visible = row.st.shown ~= false and f.nav ~= false })
        end
        paint()
    end
    function row.show(on)
        row.st.shown = on ~= false
        -- couch-fix63 (AUTO-154e, live round 8: Races 3 -> 4 showed the 4th race without its thumbnail): set() ran
        -- while the row was still hidden, so the thumbnail is given back here when the row shows again
        pcall(T.set, e.thumb, { visible = row.st.shown and row.st.art ~= nil })
        pcall(T.set, e.ghost, { visible = row.st.shown and row.st.nav ~= false })
        paint()
    end
    function row.poll(p1)
        local f, hv = false, false
        pcall(function() f, hv = T.isFocused(e.ghost, p1) end)
        local on = (f or hv) and row.st.shown ~= false
        if row.st.focused ~= on then row.st.focused = on; paint() end
        return on, f, hv
    end
    return e
end

local function buildSetup(w, T, ctx, geo)
    local cv = w.views.setup
    local function LR(x, y, ww, hh) return { x - geo.x, y - geo.y, ww, hh } end
    local s = { slots = {}, opts = {}, previews = {} }
    w.setup = s
    for i = 1, MAX_SLOTS do
        local okR, e = pcall(slotRow, T, ctx, cv, geo, i)
        if okR and e then s.slots[i] = e else U.warn(TAG, "race row %d not built: %s", i, tostring(e)) end
    end
    for i = 1, MAX_OPTS do
        local y = OPTC.y + (i - 1) * OPTC.pitch
        local o = {}
        pcall(function()
            o.bg = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 21, size = { OPTC.w, OPTC.h },
                tint = T.alpha(T.COL.WHITE, 0.42), z = 2, rect = LR(OPTC.x, y, OPTC.w, OPTC.h), visible = false })
        end)
        local okR, row = pcall(T.settingsRow, ctx, cv, { OPTC.x, y, OPTC.w, OPTC.h },
            { geo = geo, id = "gppage:opt" .. i, fn = function() M.step("opt" .. i, 1) end, z = 3 })
        if okR and row then o.row = row; s.opts[i] = o end
    end
    pcall(function()
        s.head = T.groupHeader(ctx, cv, OPTC.x, OPTC.x + OPTC.w, OPTC.head, "", { geo = geo })
        s.kicker = T.text(ctx, cv, "helpFoot", { z = 2, text = "", rect = LR(OPTC.x, OPTC.hint), wrapW = OPTC.w })
    end)
    for k, r in pairs(PREVIEW) do
        local okP, p = pcall(T.poster, ctx, cv, r, { geo = geo, z = 1, art = RANDOM_ART, title = "", titleSize = 54,
            kickerAlways = true })
        if okP and p then s.previews[k] = p; pcall(p.show, false) end
    end
    local okC, cmd = pcall(T.commandRow, ctx, cv, geo, cmdDefs(T, {
        { id = "back", label = "BACK", ghostId = "gppage:setup:back", fn = function() M.showView("hub") end },
        { id = "start", label = "START GRAND PRIX", ghostId = "gppage:setup:start", fn = function() M.onStart() end } }))
    if okC then s.cmd = cmd end
end

local function buildTables(w, T, ctx, geo)
    local cv = w.views.standings
    local function LR(x, y, ww, hh) return { x - geo.x, y - geo.y, ww, hh } end
    local t = { left = {}, right = {} }
    w.standings = t
    pcall(function()
        t.headL = T.text(ctx, cv, "groupHeader", { z = 2, text = "LAST RACE", rect = LR(TABLE_L.x, TABLE_L.y - 96) })
        t.headR = T.text(ctx, cv, "groupHeader", { z = 2, text = "CHAMPIONSHIP", rect = LR(TABLE_R.x, TABLE_R.y - 96) })
    end)
    for i = 1, MAX_ROWS do
        local okA, a = pcall(T.settingsRow, ctx, cv, { TABLE_L.x, TABLE_L.y + (i - 1) * TABLE_L.pitch, TABLE_L.w, TABLE_L.h },
            { geo = geo, z = 3 })
        if okA then t.left[i] = { row = a } end
        local okB, b = pcall(T.settingsRow, ctx, cv, { TABLE_R.x, TABLE_R.y + (i - 1) * TABLE_R.pitch, TABLE_R.w, TABLE_R.h },
            { geo = geo, z = 3 })
        if okB then t.right[i] = { row = b } end
        -- the player's colour chip at the row's left (humans only)
        pcall(function()
            t.right[i].chip = T.image(ctx, cv, { tex = T.TEX.SolidFill, z = 4, visible = false,
                rect = LR(TABLE_R.x - 28, TABLE_R.y + (i - 1) * TABLE_R.pitch + 14, 14, TABLE_R.h - 28) })
        end)
    end
    local okC, cmd = pcall(T.commandRow, ctx, cv, geo, cmdDefs(T, {
        { id = "back", label = "BACK", ghostId = "gppage:tab:back", fn = function() M.close("BACK") end },
        { id = "start", label = "NEXT RACE", ghostId = "gppage:tab:next", fn = function() M.onNext() end },
        { id = "save", label = "END GRAND PRIX", ghostId = "gppage:tab:end", fn = function() M.onEnd() end } }))
    if okC then t.cmd = cmd end
end

local function buildPodium(w, T, ctx, geo)
    local cv = w.views.podium
    local function LR(x, y, ww, hh) return { x - geo.x, y - geo.y, ww, hh } end
    local p = { posters = {}, medals = {}, pts = {}, plates = {}, places = {}, names = {} }
    w.podium = p
    local total = 3 * POD.w + 2 * POD.gap
    local x0 = (3840 - total) / 2
    local order = { 2, 1, 3 }                     -- left to right: 2nd, 1st, 3rd
    for col, place in ipairs(order) do
        local h = POD.h[place]
        local x = x0 + (col - 1) * (POD.w + POD.gap)
        local y = POD.y + (POD.h[1] - h)
        local rect = { x, y, POD.w, h }
        local okP, ps = pcall(T.poster, ctx, cv, rect, { geo = geo, z = 1, art = ART.galactic[1], ax = 0.5, ay = 0.4,
            title = "", titleSize = 60 })
        if okP and ps then p.posters[place] = ps end
        -- the solid nameplate over the card's lower part (z 3, above the poster's own canvas at z 1) + its texts
        local py = y + h - M.PLATE_H - 2
        pcall(function()
            p.plates[place] = T.image(ctx, cv, { tex = T.TEX.SolidFill, z = 3, tint = PLATE_AI,
                rect = LR(x + 2, py, POD.w - 4, M.PLATE_H) })
        end)
        pcall(function()
            p.places[place] = T.text(ctx, cv, "posterTitle", { z = 4, size = 72, colour = INK_AI, text = "",
                rect = LR(x + 52, py + 36) })
            p.names[place] = T.text(ctx, cv, "posterTitle", { z = 4, size = 60, colour = INK_AI, text = "",
                wrapW = POD.w - 104, rect = LR(x + 52, py + 128) })
        end)
        pcall(function()
            p.medals[place] = T.image(ctx, cv, { tex = MEDAL[place], z = 9, align = { 0.5, 0.5 },
                rect = LR(x + POD.w / 2, y, 160, 160) })
            p.pts[place] = T.text(ctx, cv, "value", { z = 9, size = 48, colour = T.COL.INK, align = { 0.5, 0 }, text = "",
                rect = LR(x + POD.w / 2, POD.y + POD.h[1] + 24) })
        end)
    end
    local okC, cmd = pcall(T.commandRow, ctx, cv, geo, cmdDefs(T, {
        { id = "back", label = "BACK", ghostId = "gppage:pod:back", fn = function() M.close("BACK") end },
        { id = "start", label = "DONE", ghostId = "gppage:pod:done", fn = function() M.onDone() end },
        { id = "save", label = "CHAMPIONSHIP TABLE", ghostId = "gppage:pod:table", fn = function() M.showView("standings") end } }))
    if okC then p.cmd = cmd end
end

function M.build(root, pc, page)
    W = nil
    lastBuild = { root = root, pc = pc, page = page }
    if opt("GrandPrix", true) == false then return false end
    if not (U.ok(root) and U.ok(pc) and U.ok(page)) then return false end
    local okT, tree = pcall(U.getField, page, "WidgetTree")
    if not okT or not U.ok(tree) then return false end
    local T = TH()
    local cv = mk(CANVAS, tree)
    if not cv then U.warn(TAG, "page canvas not created"); return false end
    pcall(function() cv:SetVisibility(VIS.SelfHitTestInvisible) end)
    local slot = root:AddChildToVerticalBox(cv)
    pcall(function()
        slot:SetSize({ Value = 1, SizeRule = 1 })
        slot:SetHorizontalAlignment(C.E.HAlign.Fill)
        slot:SetVerticalAlignment(0)
        slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    end)
    local g = T.pageGeometry(root)
    local geo = { x = g.x, y = g.y, w = g.w, h = g.h, cmdY = g.cmdY, cardH = g.cardH, screen = g.screen, src = g.src }
    local ctx = { tree = tree, pc = pc }
    local w = { pc = pc, panel = cv, root = root, ctx = ctx, geo = geo, views = {} }
    pcall(function() w.bg = T.pageBackground(ctx, cv, geo, "hub", { z = -10 }) end)
    pcall(function() w.title = T.screenTitle(ctx, cv, geo, "GALACTIC GRAND PRIX") end)
    for _, v in ipairs({ "hub", "setup", "standings", "podium" }) do
        local okV, c = pcall(subCanvas, tree, cv)
        if okV then w.views[v] = c end
    end
    local function part(name, fn)
        local ok, err = pcall(fn, w, T, ctx, geo)
        if not ok then U.warn(TAG, "%s view not built: %s", name, tostring(err)) end
    end
    part("hub", buildHub)
    part("setup", buildSetup)
    part("standings", buildTables)
    part("podium", buildPodium)
    -- live fix: the page's own status pill. setup.lua's pill sits on the RACE SETUP panel, collapsed while this page
    -- shows, so "END THE GRAND PRIX? PRESS A AGAIN" (and KEPT / ENDED / the race-result lines) were never seen
    pcall(function() w.pill = T.statusPill(ctx, cv, geo) end)
    -- LEFT / RIGHT focus traps: invisible ghosts out of every geometric sweep, reached only through the rows' rules
    pcall(function()
        local noop = function() end
        w.trapL = T.ghost(ctx, cv, { 40, 100, 24, 24 }, "gppage:trapL", noop, { geo = geo })
        w.trapR = T.ghost(ctx, cv, { 72, 100, 24, 24 }, "gppage:trapR", noop, { geo = geo })
    end)
    for _, list in ipairs({ w.setup and w.setup.slots or {}, w.setup and w.setup.opts or {} }) do
        for _, e in ipairs(list) do
            pcall(function() T.nav(e.row.ghost, "left", w.trapL); T.nav(e.row.ghost, "right", w.trapR) end)
        end
    end
    -- #23: the pin canvas (collapsed, never shown) and the background preload of every art the page can show
    pcall(function()
        local pins = subCanvas(tree, cv)
        w.pins = pins
        T.pinHost(ctx, pins)
        local okA, paths = pcall(M.artPaths)
        local n = (okA and type(T.preload) == "function") and T.preload(paths) or 0
        U.log(TAG, "art preload queued: %d texture(s), one per %s ms in the background (#23)", n,
            tostring(opt("UiPreloadEveryMs", 150)))
    end)
    pcall(function() cv:SetVisibility(VIS.Collapsed) end)
    W = w
    U.log(TAG, "GALACTIC GRAND PRIX page built (views: hub %s, setup %s, standings %s, podium %s; traps %s)",
        tostring(w.hub ~= nil), tostring(w.setup ~= nil), tostring(w.standings ~= nil), tostring(w.podium ~= nil),
        (U.ok(w.trapL) and U.ok(w.trapR)) and "ok" or "MISSING")
    return true
end

-- #23: every art path the page can show (pure, deduplicated): the drafts' current race thumbnails first (the likely
-- first setup view), then the random / medal art, then every track of every pool in every class a player can pick
-- (a P<n> vehicle step changes the thumbnails of the tracks without their own Arcade tile)
function M.artPaths()
    local out, seen = {}, {}
    local function add(p) if type(p) == "string" and p ~= "" and not seen[p] then seen[p] = true; out[#out + 1] = p end end
    local GPM = gp()
    local okD, drafts = pcall(function()
        local list = {}
        for _, t in ipairs(GPM.TOURS) do list[#list + 1] = GPM.draft(t.key, pnums()) end
        return list
    end)
    if okD then
        for _, dr in ipairs(drafts) do
            for i = 1, #(dr.slots or {}) do
                local v = M.slotView(dr, i)
                if v then add(v.art) end
            end
        end
    end
    add(RANDOM_ART)
    for _, m in ipairs(MEDAL) do add(m) end
    for _, kind in ipairs({ "pod", "galactic" }) do
        local okP, pool = pcall(GPM.pool, { tour = kind, slots = {}, classes = {} })
        for _, e in ipairs(okP and pool or {}) do
            if e.group == "pod" then add(artFor(e, nil))
            else for _, c in ipairs(GPM.CLASSES or { "Car" }) do add(artFor(e, { classes = { c } })) end end
        end
    end
    return out
end

function M.forget() W = nil; S.active = false end
function M.active() return S.active and W ~= nil end

---------------------------------------------------------------------------------------------------- render
local function setRow(row, f) if row then pcall(function() row.set(f) end) end end
local function showRow(row, on) if row then pcall(function() row.show(on) end) end end

local function renderHub()
    local T = TH()
    local seats = M.hubSeats(humans(), M.canJoin())
    for i = 1, 4 do
        local s = seats[i]
        local open = s and s.open
        pcall(function() T.set(W.hub.cells[i], { text = s and s.text or "", colour = open and T.COL.NEAR or T.COL.INK }) end)
        pcall(function() T.set(W.hub.tagTexts[i], { text = s and s.tag or "",
            colour = (s and not open and (C.COLOUR_INK or {})[s.pnum]) or T.COL.NEAR }) end)
        pcall(function() T.set(W.hub.tags[i], { visible = s ~= nil,
            colour = open and T.alpha(T.COL.WHITE, 0.42) or (s and T.PLAYER[s.pnum]) or nil }) end)
    end
    for _, t in ipairs(gp().TOURS) do
        local okD, dr = pcall(gp().draft, t.key, pnums())
        local cap = ""
        if okD and dr then
            -- one line only (the description sits 54 su below): the longest variant that fits the poster width
            local races = string.format("%d RACE%s", #dr.slots, #dr.slots == 1 and "" or "S")
            local up = gp().upgradesText(dr.upgrades)
            local pl = dr.planet and planetName(dr.planet) or nil
            local tries = pl and { pl .. " " .. DOT .. " " .. races .. " " .. DOT .. " " .. up,
                                   pl .. " " .. DOT .. " " .. races .. " " .. DOT .. " " .. up:gsub(" " .. DOT .. " .*$", ""),
                                   pl .. " " .. DOT .. " " .. races }
                          or { races .. " " .. DOT .. " " .. up, races }
            cap = tries[#tries]
            for _, s in ipairs(tries) do
                local okW, tw = pcall(T.textWidth, s, "rowValue")
                if okW and tonumber(tw) and tw <= HUB.w - 8 then cap = s; break end
            end
        end
        pcall(function() T.set(W.hub.caps[t.key], { text = cap }) end)
    end
    pcall(function() W.hub.cmd.show({ back = true }) end)
end

-- #22 (playtest 2026-10-17): the setup is one D-pad column, like the game's own setup screens. The focus opens on the
-- first option row (PLANET / RACES ...); DOWN walks the option rows, then (a list the player can edit: PODRACER /
-- PLANET TOUR / GALACTIC / CUSTOM) the race rows top to bottom, then START GRAND PRIX, then BACK; UP walks it back.
-- LEFT / RIGHT on a row step it (the focus traps); START <-> BACK also by LEFT / RIGHT. The first option row's UP and
-- BACK's DOWN stay put (no geometric jump into the race list). A fixed list (PLANET CHAMPIONSHIP) is display-only:
-- its rows are out of the chain and out of CommonUI's navigation (slotRow nav = false). Pure order: M.navOrder.
function M.navOrder(nOpts, nSlots, editable)
    local out = {}
    for i = 1, nOpts do out[#out + 1] = "opt" .. i end
    if editable then for i = 1, nSlots do out[#out + 1] = "slot" .. i end end
    out[#out + 1] = "start"
    out[#out + 1] = "back"
    return out
end

local function linkSetup(nSlots, nOpts, editable)
    local T = TH()
    local s = W.setup
    local function ghostOf(id)
        if id == "start" or id == "back" then return s.cmd and s.cmd.widget(id) end
        local kind, n = id:match("^(%a+)(%d+)$")
        local list = kind == "opt" and s.opts or s.slots
        local e = list[tonumber(n)]
        return e and e.row and e.row.ghost
    end
    local order = M.navOrder(nOpts, nSlots, editable)
    local gs = {}
    for i, id in ipairs(order) do gs[i] = ghostOf(id) end
    for i = 1, #order do
        local g = gs[i]
        if U.ok(g) then
            pcall(T.nav, g, "down", U.ok(gs[i + 1]) and gs[i + 1] or g)
            pcall(T.nav, g, "up", U.ok(gs[i - 1]) and gs[i - 1] or g)
        end
    end
    local start, back = ghostOf("start"), ghostOf("back")
    if U.ok(start) and U.ok(back) then
        pcall(T.nav, start, "right", back)
        pcall(T.nav, back, "left", start)
        pcall(T.nav, start, "left", start)
        pcall(T.nav, back, "right", back)
    end
    S.navOrder = order
end

-- the race list's pitch for n rows (tall rows up to 8, packed to the list's height beyond)
function M.listPitch(n)
    n = math.max(1, tonumber(n) or 1)
    return math.min(LIST.maxPitch, math.floor((LIST.y1 - LIST.y0) / n))
end

-- the option rows' pitch: packed from OPTC.y, shrunk when a CUSTOM list is long
local function layoutOpts(n)
    local pitch = OPTC.pitch
    if n > 0 and OPTC.y + n * pitch > OPTC.bottom then pitch = math.floor((OPTC.bottom - OPTC.y) / n) end
    return pitch
end

-- the preview poster: the focused race (else race 1), big under a short option list, small under a long one, none
-- when the options reach the bottom
local function renderPreview()
    local s = W and W.setup
    if not (s and S.draft) then return end
    local n = tonumber((S.lastRow or ""):match("^slot(%d+)$") or "") or S.lastSlot or 1
    -- RACES lowered under the focused race: its slot is gone, show race 1 (and say so)
    if not M.slotView(S.draft, n) then n = 1 end
    S.lastSlot = n
    local v = M.slotView(S.draft, n)
    local want = nil
    local optsEnd = S.optsEnd or OPTC.y
    if optsEnd + 40 <= PREVIEW.big[2] then want = "big" elseif optsEnd + 40 <= PREVIEW.small[2] then want = "small" end
    for k, p in pairs(s.previews or {}) do
        local on = k == want and v ~= nil
        pcall(p.show, on)
        if on then
            local key = table.concat({ n, v.title or "", v.sub or "", tostring(v.art) }, "|")
            if S.sig.preview ~= key .. k then
                S.sig.preview = key .. k
                pcall(p.set, { art = v.art or RANDOM_ART, title = v.title or "",
                               kicker = string.format("Race %d %s %s", n, DOT, v.sub or ""), kickerAlways = true })
            end
        end
    end
end

local function renderSetup()
    local T = TH()
    local dr = S.draft
    if not dr then return end
    local t = gp().tour(dr.tour) or {}
    local geo = W.geo
    pcall(function() W.setup.head.set(t.name or "") end)
    local lines = {}
    lines[1] = t.fixed and "Every circuit of the planet, in its order: the list is fixed."
        or "LEFT / RIGHT on a race changes its track; the last step is a random track."
    if gp().vehicleRule(dr) == "pods" then
        lines[2] = "Each player picks their podracer on the racer cards after START."
    else
        -- couch-fix59 (AUTO-145b): <= 84 characters a line, two lines (a wrapped third ran over the Planet row)
        lines[2] = "Vehicle classes are set here; pilots are picked on the racer cards after START."
    end
    pcall(function() T.set(W.setup.kicker, { text = table.concat(lines, "\n") }) end)
    local nSlots = math.min(#dr.slots, MAX_SLOTS)
    local pitch = M.listPitch(nSlots)
    local h = pitch - LIST.gap
    for i = 1, MAX_SLOTS do
        local e = W.setup.slots[i]
        local v = M.slotView(dr, i)
        if e then
            local on = v ~= nil
            if on then
                pcall(e.row.place, LIST.y0 + (i - 1) * pitch, h)
                pcall(e.row.set, { label = v.title, value = v.sub, art = v.art or RANDOM_ART, cycle = not t.fixed,
                                   nav = not t.fixed })
            end
            pcall(e.row.show, on)
        end
    end
    local rows = M.optionRows(dr, humans())
    S.optKeys = {}
    local opitch = layoutOpts(#rows)
    S.optsEnd = OPTC.y + #rows * opitch
    for i = 1, MAX_OPTS do
        local o = W.setup.opts[i]
        local r = rows[i]
        if o then
            if r then
                S.optKeys[i] = r.key
                local y = OPTC.y + (i - 1) * opitch
                local rh = math.min(OPTC.h, opitch - 8)
                local rect = { OPTC.x - geo.x, y - geo.y, OPTC.w, rh }
                pcall(function() T.set(o.row.e, { rect = rect }) end)
                pcall(function() T.set(o.row.ghost, { rect = rect }) end)
                pcall(function() T.set(o.bg, { rect = rect, visible = true }) end)
                local kind = r.kind
                local val = r.value
                if kind == "toggle" then setRow(o.row, { label = r.label, value = val, kind = "toggle", on = val == "ON" })
                else setRow(o.row, { label = r.label, value = val, kind = kind, arrows = kind == "cycle" and "always" or nil }) end
                showRow(o.row, true)
            else
                showRow(o.row, false)
                pcall(function() T.set(o.bg, { visible = false }) end)
            end
        end
    end
    U.try(TAG, linkSetup, nSlots, math.min(#rows, MAX_OPTS), not t.fixed)
    U.try(TAG, renderPreview)
end

local function chipColour(pnum)
    local c = (C.COLOURS or {})[pnum]
    if type(c) == "table" then return c end
    return TH().COL.RUST
end

local function renderStandings()
    local T = TH()
    local gs = gp().state()
    if not gs then return end
    local last, h = M.lastRaceRows(gs)
    pcall(function()
        T.set(W.standings.headL, { text = h and string.format("RACE %d %s %s", h.race, DOT, tostring(h.name)) or "NO RACE YET" })
        T.set(W.standings.headR, { text = string.format("CHAMPIONSHIP %s %d / %d", DOT, math.min(gs.race - 1, #gs.races), #gs.races) })
    end)
    -- the last race: every racer that fits, else the top + every human below them (M.fitRows)
    local shown = M.fitRows(last, MAX_ROWS)
    for i = 1, MAX_ROWS do
        local e = W.standings.left[i]
        local r = shown[i]
        if e then
            showRow(e.row, r ~= nil)
            if r then setRow(e.row, { label = string.format("%d.  %s", r.rank, r.name), value = r.value, kind = "value" }) end
        end
    end
    local tab = M.standingsRows(gs)
    local list = M.fitRows(tab, MAX_ROWS)
    for i = 1, MAX_ROWS do
        local e = W.standings.right[i]
        local r = list[i]
        if e then
            showRow(e.row, r ~= nil)
            if r then setRow(e.row, { label = string.format("%d.  %s", r.rank, r.name), value = r.value, kind = "value" }) end
            pcall(function() T.set(e.chip, { visible = r ~= nil and r.human == true, colour = chipColour(r and r.pnum) }) end)
        end
    end
    local nxt = gp().nextRace()
    pcall(function()
        W.standings.cmd.show({ back = true, start = nxt ~= nil, save = gs.status == "on" })
    end)
end

local function renderPodium()
    local T = TH()
    local gs = gp().state()
    if not gs then return end
    local v = M.podiumView(gs)
    for place = 1, 3 do
        local p = W.podium.posters[place]
        local e = v[place]
        if p then
            pcall(function()
                p.set({ title = "", art = (e and e.art) or ART.galactic[1], kicker = "", kickerAlways = false })
                T.set(p.art, { colour = T.COL.WHITE })          -- full-strength art, not the idle grey tint
            end)
        end
        local st = M.podiumStyle(e)
        local P = W.podium
        pcall(function() T.set(P.plates[place], { colour = st.plate, visible = e ~= nil }) end)
        pcall(function() T.set(P.places[place], { text = e and e.place or "", colour = st.ink, visible = e ~= nil }) end)
        pcall(function() T.set(P.names[place], { text = e and tostring(e.name) or "", colour = st.ink, visible = e ~= nil }) end)
        pcall(function() T.set(W.podium.pts[place], { text = e and string.format("%d PTS", e.points) or "" }) end)
    end
end

function M.refresh()
    if not W then return end
    local v = S.view
    for name, c in pairs(W.views) do
        pcall(function() c:SetVisibility(name == v and VIS.SelfHitTestInvisible or VIS.Collapsed) end)
    end
    local r = ({ hub = renderHub, setup = renderSetup, standings = renderStandings, podium = renderPodium })[v]
    if r then U.try(TAG, r) end
end

---------------------------------------------------------------------------------------------------- focus
local function firstGhost()
    if S.view == "hub" then return W.hub and W.hub.ghosts[S.tour or "pod"] or (W.hub and W.hub.ghosts[1]) end
    if S.view == "setup" then
        -- #22: the first option row (PLANET / RACES), as the game's setup screens open on their first setting
        local o = W.setup and W.setup.opts[1]
        if o and o.row and U.ok(o.row.ghost) and (S.optKeys or {})[1] then return o.row.ghost end
        local c = W.setup and W.setup.cmd
        return c and c.widget("start")
    end
    if S.view == "standings" then
        local c = W.standings and W.standings.cmd
        return c and (c.widget("start") or c.widget("back"))
    end
    if S.view == "podium" then local c = W.podium and W.podium.cmd; return c and c.widget("start") end
    return nil
end

local function focus(g) if U.ok(g) then pcall(function() g:SetFocus() end) end end
local focusWatch

-- every focusable row of the setup view: id -> ghost
local function setupRows()
    local out = {}
    if not (W and W.setup) then return out end
    for i, e in ipairs(W.setup.slots) do if e.row and e.row.ghost then out["slot" .. i] = e.row.ghost end end
    for i, o in ipairs(W.setup.opts) do if o.row and o.row.ghost then out["opt" .. i] = o.row.ghost end end
    return out
end

local function focusedRow(p1)
    for id, g in pairs(setupRows()) do
        local ok, f = pcall(function() return ui().hasFocus(g, p1) end)
        if ok and f == true then return id end
    end
    return nil
end

---------------------------------------------------------------------------------------------------- actions
function M.showView(v)
    if not W then return end
    if v == "standings" or v == "podium" then
        if not gp().state() then v = "hub" end
    end
    S.view = v
    S.sig = {}
    S.seatsSig, S.seatsAtMs = nil, 0
    M.refresh()
    U.try(TAG, function() focus(firstGhost()) end)
    U.log(TAG, "view %s", v)
end

-- the view the page opens on: a running GP's standings, a finished one's podium, else the hub
local function homeView()
    if gp().done() then return "podium" end
    if gp().state() then return "standings" end
    return "hub"
end

function M.open(view)
    if not W and lastBuild and U.ok(lastBuild.root) and U.ok(lastBuild.page) then
        U.try(TAG, M.build, lastBuild.root, lastBuild.pc, lastBuild.page)
    end
    if not W then U.warn(TAG, "GALACTIC GRAND PRIX page not built: it cannot open"); return false end
    if St.phase ~= "FRONTEND" or St.launch.pending then return false end
    pcall(function() U.mod("runpage").close("grand prix page") end)
    pcall(function() U.mod("couchpage").close("grand prix page") end)
    local okM, lobby = pcall(U.mod, "lobby")
    if not S.active and okM and type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, true) end
    S.active = true
    S.openedAtMs, S.focusCheckAt = St.nowMs(), St.nowMs() + 300
    pcall(function() W.panel:SetVisibility(VIS.SelfHitTestInvisible) end)
    M.showView(view or homeView())
    U.log(TAG, "GALACTIC GRAND PRIX page opened (%s)", S.view)
    return true
end

local END_LABEL, END_ARMED = "END GRAND PRIX", "A AGAIN: END GP"
local function endLabel(armed)
    local c = W and W.standings and W.standings.cmd
    if c and c.label then pcall(c.label, "save", armed and END_ARMED or END_LABEL) end
end
M._endLabel = function() local c = W and W.standings and W.standings.cmd; local b = c and c.btn and c.btn.save; return b and b.text end

function M.close(why)
    if not S.active then return end
    S.active = false
    S.endUntil = 0                                       -- an armed END GRAND PRIX never survives the page
    endLabel(false)
    if W and W.pill then pcall(W.pill.clear) end
    if W then pcall(function() W.panel:SetVisibility(VIS.Collapsed) end) end
    pcall(function() gp().saveDrafts() end)
    local okM, lobby = pcall(U.mod, "lobby")
    -- fix16: focus back on the GRAND PRIX poster (the "galaxy" tile that opened the page), not the mode tile
    if okM and type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, false, "galaxy") end
    U.log(TAG, "GALACTIC GRAND PRIX page closed (%s)", tostring(why))
end

-- gp.settle: open the standings once the front end is back (fastTick, within 6 s)
function M.wantOpen(view)
    S.wantView = view
    S.openWanted = St.nowMs() + 6000
end

function M.onTour(key)
    if not S.active then return end
    if gp().active() then St.emit("status", "A GRAND PRIX IS ON: FINISH IT OR END IT"); M.showView("standings"); return end
    S.tour = key
    S.draft = gp().draft(key, pnums())
    M.showView("setup")
end

-- one LEFT / RIGHT / A step on a setup row ("slot3" | "opt5")
function M.step(id, dir)
    if not (S.active and S.view == "setup" and S.draft) then return end
    local dr = S.draft
    local n = tonumber(id:match("^slot(%d+)$") or "")
    if n then
        gp().stepSlot(dr, n, dir)
    else
        local i = tonumber(id:match("^opt(%d+)$") or "")
        local key = i and S.optKeys and S.optKeys[i]
        if not key then return end
        gp().stepOption(dr, key, dir)
    end
    S.lastRow = id
    M.refresh()
end

function M.onStart()
    if not (S.active and S.draft) then return end
    local h = humans()
    local gs = gp().begin(S.draft, h)
    if not (gs and #gs.races > 0) then St.emit("status", "GRAND PRIX: NO RACE IN THE LIST"); return end
    St.emit("status", string.format("GRAND PRIX: %d RACES %s RACE 1 %s", #gs.races, DOT, tostring(gs.races[1].name)))
    M.onNext()
end

function M.onNext()
    if not S.active then return end
    if not gp().betweenRaces() then M.refresh(); return end
    M.close("NEXT RACE")
    local ok, opened = pcall(function() return gp().openNext() end)
    if not (ok and opened == true) then
        St.emit("status", "GRAND PRIX: THE NEXT RACE DID NOT OPEN - TRY START")
    end
end

-- END GRAND PRIX: A twice (>= 400 ms apart, within U.confirmMs() = 5 s, no B in between), as END THE RUN (B04).
-- couch-fix59 (AUTO-145e): the window was 3 s (a second A 3 s later re-armed it: a dead button); while armed the
-- button reads END GRAND PRIX? A AGAIN and the pill stays up for the whole window
function M.onEnd()
    if not S.active then return end
    local now = St.nowMs()
    if now <= S.endUntil and now - S.endArmMs < 400 then return end
    local quitMs = -1e12
    pcall(function() quitMs = U.mod("backprompt").lastQuitPostMs() end)
    if now <= S.endUntil and (S.backMs >= S.endArmMs or quitMs >= S.endArmMs) then
        S.endUntil = 0
        endLabel(false)
        St.emit("status", "GRAND PRIX KEPT")
        return
    end
    if now <= S.endUntil then
        S.endUntil = 0
        endLabel(false)
        pcall(function() gp().abandon("page") end)
        St.emit("status", "GRAND PRIX ENDED")
        M.showView("hub")
        return
    end
    S.endUntil, S.endArmMs = now + U.confirmMs(), now
    endLabel(true)
    St.emit("status", "END THE GRAND PRIX? PRESS A AGAIN " .. DOT .. " B KEEPS IT")
end

function M.onDone()
    if not S.active then return end
    pcall(function() gp().finish() end)
    M.showView("hub")
end

function M.onP1Back(why)
    S.backMs = St.nowMs()
    if not S.active then return false end
    -- live2: "PRESS A AGAIN · B KEEPS IT": a B while END GRAND PRIX is armed only disarms it (the page stays; it used
    -- to close the page with the prompt still up on the FREE MODE pill)
    if (S.endUntil or 0) > 0 and S.backMs <= S.endUntil then
        S.endUntil = 0
        endLabel(false)
        St.emit("status", "GRAND PRIX KEPT")
        -- the game's Quit prompt (backprompt) took the focus: back on END GRAND PRIX, where the player was
        local c = W and W.standings and W.standings.cmd
        local g = c and c.widget("save") or firstGhost()
        focus(g)
        S.refocus, S.refocusUntil = g, St.nowMs() + 500
        return true
    end
    if S.view == "setup" then M.showView("hub"); return true end
    M.close(why or "pad B")
    return true
end
function M.lastP1BackMs() return S.backMs end

function M.onKey(name)
    if not S.active then return end
    if name == "back2" or name == "back" then
        if S.view == "setup" then M.showView("hub") else M.close("keyboard back") end
        return
    end
    if (name == "left" or name == "right") and S.view == "setup" then
        local id = focusedRow(U.p1()) or S.lastRow
        if id then M.step(id, name == "left" and -1 or 1) end
    end
end

---------------------------------------------------------------------------------------------------- tick
local function paintFocus(p1)
    if S.view == "hub" and W.hub then
        for key, p in pairs(W.hub.posters) do
            local f = false
            pcall(function() f = ui().hasFocus(W.hub.ghosts[key], p1) == true end)
            if S.sig[key] ~= f then
                S.sig[key] = f
                pcall(function() p.focus(f) end)
                pcall(function() TH().set(W.hub.caps[key], { colour = f and TH().COL.RUST or TH().COL.INK }) end)
            end
        end
        if W.hub.cmd then pcall(function() W.hub.cmd.poll(p1) end) end
    elseif S.view == "setup" and W.setup then
        for _, list in ipairs({ W.setup.slots, W.setup.opts }) do
            for _, e in ipairs(list) do if e.row then pcall(function() e.row.poll(p1) end) end end
        end
        if W.setup.cmd then pcall(function() W.setup.cmd.poll(p1) end) end
    elseif S.view == "standings" and W.standings and W.standings.cmd then
        pcall(function() W.standings.cmd.poll(p1) end)
    elseif S.view == "podium" and W.podium and W.podium.cmd then
        pcall(function() W.podium.cmd.poll(p1) end)
    end
end

-- pad LEFT / RIGHT: CommonUI moved P1's focus onto a trap -> step the row that had it, focus back on that row
local function trapTick(p1, now)
    if S.view ~= "setup" then return end
    local id = focusedRow(p1)
    if id and id ~= S.lastRow then S.lastRow = id; U.try(TAG, renderPreview) end
    local dir = nil
    pcall(function()
        if ui().hasFocus(W.trapL, p1) then dir = -1 elseif ui().hasFocus(W.trapR, p1) then dir = 1 end
    end)
    if not dir then return end
    local row = S.lastRow
    if row and now - S.lrAtMs > 120 then
        S.lrAtMs = now
        U.logOnce("gppage.trap", TAG, "pad %s through the focus trap (V-GP-01)", dir < 0 and "left" or "right")
        M.step(row, dir)
    end
    local g = row and setupRows()[row]
    focus(g or firstGhost())
end

-- live2: back from a race the standings / podium opened with NO focused pill (the front end's own activation took the
-- focus after ours): the pad did nothing until B. For 4 s after an open, every 300 ms: nothing of this view focused ->
-- focus its first pill again.
local function viewFocusables()
    local out = {}
    local c = (S.view == "standings" and W.standings and W.standings.cmd) or (S.view == "podium" and W.podium and W.podium.cmd)
        or (S.view == "hub" and W.hub and W.hub.cmd) or (S.view == "setup" and W.setup and W.setup.cmd)
    if c then for _, id in ipairs({ "start", "save", "back" }) do local g = c.widget(id); if U.ok(g) then out[#out + 1] = g end end end
    if S.view == "hub" and W.hub then for _, g in ipairs(W.hub.ghosts) do out[#out + 1] = g end end
    if S.view == "setup" then
        for _, g in pairs(setupRows()) do out[#out + 1] = g end
        -- #22: a LEFT / RIGHT in the 4 s after the open passes through a focus trap: that focus is the page's (the
        -- refocus used to put it back on the first row before trapTick stepped the row - the press was lost)
        out[#out + 1] = W.trapL
        out[#out + 1] = W.trapR
    end
    return out
end
focusWatch = function(now)
    if now - (S.openedAtMs or -1e12) > 4000 or now < (S.focusCheckAt or 0) then return end
    S.focusCheckAt = now + 300
    if St.menu.visible ~= "lobby" then return end
    local p1 = U.p1()
    for _, g in ipairs(viewFocusables()) do
        local f = false
        pcall(function() f = ui().hasFocus(g, p1) == true end)
        if f then return end
    end
    U.logOnce("gppage.refocus." .. tostring(S.view), TAG, "no focus on the %s view after its open: first pill focused again", tostring(S.view))
    focus(firstGhost())
end

function M.fastTick()
    if St.phase ~= "FRONTEND" or St.launch.pending then
        if S.active then M.close("phase " .. tostring(St.phase)) end
        return
    end
    local now = St.nowMs()
    if (S.endUntil or 0) > 0 and now > S.endUntil then   -- AUTO-145e: the window ran out: the row reads END again
        S.endUntil = 0
        endLabel(false)
    end
    if S.openWanted > 0 then
        if now > S.openWanted then S.openWanted = 0
        elseif St.menu.visible == "lobby" and W then
            S.openWanted = 0
            U.try(TAG, M.open, S.wantView)
        end
    end
    -- #23: the background art preload runs while the page is closed too (the FREE MODE posters show)
    if W and St.menu.visible == "lobby" then pcall(function() TH().preloadTick(now) end) end
    if not (S.active and W) then return end
    if W.pill then pcall(W.pill.tick, now) end
    U.try(TAG, focusWatch, now)
    if S.refocus then                                    -- a B that disarmed END: the focus once the prompt is gone
        if now > (S.refocusUntil or 0) then focus(S.refocus); S.refocus = nil end
    end
    -- #24: the hub's players row follows joins / leaves (a cheap signature every 500 ms; the row only on a change)
    if S.view == "hub" and now >= (S.seatsAtMs or 0) then
        S.seatsAtMs = now + 500
        local sig = {}
        for _, s in ipairs(M.hubSeats(humans(), M.canJoin())) do sig[#sig + 1] = s.tag .. s.text end
        sig = table.concat(sig, "|")
        if S.seatsSig ~= sig then
            if S.seatsSig ~= nil then U.try(TAG, renderHub) end
            S.seatsSig = sig
        end
    end
    local p1 = U.p1()
    U.try(TAG, paintFocus, p1)
    U.try(TAG, trapTick, p1, now)
end

function M.init()
    St.on("tab", TAG, function(shown)
        if S.active and shown == false then M.close("tab left") end
    end)
    St.on("status", TAG, function(text)
        if not (S.active and W and W.pill) then return end
        text = tostring(text or "")
        if text == "" then return end
        local armed = text:find("PRESS A AGAIN", 1, true) ~= nil
        pcall(W.pill.post, text, { ms = armed and U.confirmMs() or nil, warn = armed })
    end)
end

-- dev: build the page again in place (live layout work)
function M.rebuildPage()
    if not lastBuild then return "no build arguments" end
    M.close("rebuild")
    if W and U.ok(W.panel) then pcall(function() W.panel:RemoveFromParent() end) end
    M.build(lastBuild.root, lastBuild.pc, lastBuild.page)
    return "page rebuilt: " .. tostring(W ~= nil)
end

-- tests
function M._setActive(on) S.active = on == true end
function M._state() return S end
function M._w() return W end

function M.status()
    return string.format("gppage: %s (%s), %s", S.active and "open" or "closed", S.view, W and "built" or "not built")
end

return M
