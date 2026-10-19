-- garage4.lua: THE 4-WAY GARAGE - every player builds his car AT THE SAME TIME, each in his own area of the screen
-- (2 players: top / bottom strips, 3-4: quadrants), his own 3D car (a vpreview photo bay per player), his own pad.
-- Design, evidence and the live checklist: docs/dev/guest-garage.md section 8.
--
-- Why a mod-built screen (guest-garage.md 1.3): the game's garage is single-player. Its screens edit the ONE
-- BP_CstPawn_C of the front end (BPFL_CustomisationFunctionLibrary.FindCustomisationPawn = the first one found), save
-- into the FIRST local player's CstSubsystem (SaveCustomisationRecipes), run one CSM_VehicleCustomisation_Root, and the
-- front end forces split screen off. Two players can never be in it at once, so no native garage widget is cloned:
-- each area is our own panel in the game's look (garage4ui.lua), fed from the game's own catalog (custdata.lua).
--
-- Two hosts, one look:
--   * FREE MODE / GALACTIC GRAND PRIX (cfg.Garage4Way): A on a racer card's VEHICLE stage (racers.lua) opens it for
--     every card at once. Every model of the player's class (every PRE_* preset: the base models and the pilot / aged
--     liveries) and every livery option (templates, colours, finishes, pod decals) is offered: unlocked for this mode.
--     The model is the card's pick (racers pl.presetId: the grid entry's VehicleCustomisation, launch.lua); the livery
--     (tags) is kept per pad and class in Mods/SWGRCouch/garage4.txt and handed on with the pick (racers.choicePlayers
--     pick.livery). In the race, M.raceTick uploads it onto that player's car through his own PlayerState's
--     PlayerVehicleCustomisationComponent:Server_UpdateVehicleRecipe (garage.apply, the same path as the couch guests).
--     P1 included: the upload is a race-world recipe actor only, his CstSubsystem garage and his save are never read
--     for writing nor written (his grid entry carries a preset, so the game's own possession upload is the preset's).
--   * COUCH CAMPAIGN (cfg.CouchGarage4Way): the guests' GARAGE on the run map stays couchpanel's split (its input: the
--     guests' Slate-focused ghost buttons, the pad park); each guest area is drawn by garage4ui with his 3D car, his
--     options are garage.lua's (CouchGarageUnlocks: what P1's save owns), his store guest-garage.txt, his livery goes
--     on his car through garage.raceTick (unchanged). P1 keeps the game's own garage (his area = the run map).
-- Input: every event already carries its player (racers.dispatch: guests' pads polled on their own PlayerController,
-- P1 through the sink / keyboard; couchpanel: each guest's focused ghost button). An area only ever changes from its
-- own player's events (M.event(ctrlId, ...)): no CommonUI router is involved, so the split-screen pad mix-ups of
-- CommonUI cannot reach it.
-- Cost: no FindAllOf / StaticFindObject in a tick (vehicles.presetClass caches its classes; the catalog is Lua data);
-- the bays capture stills on a change (vpreview's budget: SetupPreviewCaptureBudget per FAST tick over all bays) or turn
-- slowly (cfg.Garage4Spin, Garage4SpinCaptureMs); everything goes before a race travel (close on leave / phase / world).
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")
local V = require("vehicles")
local settings = require("settings")

local TAG = "garage4"
local M = {}
local FILE = "garage4.txt"

local okD, D = pcall(require, "custdata")
if not okD or type(D) ~= "table" then D = nil end

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function G() return U.mod("garage") end

local vpMod = nil
local function VP()
    if vpMod == nil then
        local ok, m = pcall(require, "vpreview")
        vpMod = (ok and type(m) == "table") and m or false
    end
    return vpMod or nil
end
local function UI()
    local ok, m = pcall(U.mod, "garage4ui")
    return (ok and type(m) == "table") and m or nil
end

-- the rows of an area; decals exist for pods only (the game's IconMaskMap: pod engine / cockpit icons)
local ROWS = {
    { key = "model", label = "MODEL" },
    { key = "mask", label = "LIVERY" },
    { key = "palette", label = "COLOURS" },
    { key = "patina", label = "FINISH" },
    { key = "decal", label = "DECAL", pods = true },
}
M.ROWS = ROWS
local LIVERY = { "mask", "palette", "patina", "decal" }
M.LIVERY = LIVERY
local TOAST_MS = 2200
M.HINT = "UP / DOWN choose   LEFT / RIGHT change   A next   DONE: ready"

---------------------------------------------------------------------------------------------------- free store
-- F = { version = 1, pads = { [ctrlId] = { [arch] = { mask, palette, patina, decal } } } }: FREE MODE liveries per
-- pad (racers keys its picks by ControllerId too) and class; nil field = the preset's own. Never the couch store.
local F = nil

local function ser(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "number" then return (math.type(v) == "integer") and tostring(v) or string.format("%.17g", v) end
    if t == "string" then return string.format("%q", v) end
    if t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = { "{\n" }
    for _, k in ipairs(keys) do
        local ks = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
        out[#out + 1] = ind .. "  " .. ks .. " = " .. ser(v[k], ind .. "  ") .. ",\n"
    end
    out[#out + 1] = ind .. "}"
    return table.concat(out)
end

local function filePath()
    local ok, d = pcall(function() return settings.modDir() end)
    return (ok and type(d) == "string") and (d .. "/" .. FILE) or nil
end

local function loadState()
    if F then return F end
    local p = filePath()
    local f = p and io.open(p, "r")
    if f then
        local src = f:read("a")
        f:close()
        local chunk = load(src, "@" .. FILE, "t", {})
        local ok, t = pcall(chunk or function() return nil end)
        if ok and type(t) == "table" and type(t.pads) == "table" then F = t end
    end
    F = F or { version = 1, pads = {} }
    return F
end

local function save()
    local p = filePath()
    if not p or not F then return false end
    local f = io.open(p, "w")
    if not f then return false end
    f:write("return " .. ser(F) .. "\n")
    f:close()
    return true
end

function M._reset() F = nil end                  -- tests: forget the in-memory copy (the file is read again)

local function freeEntry(ctrlId, arch, create)
    loadState()
    ctrlId, arch = tonumber(ctrlId), tonumber(arch)
    if not (ctrlId and arch) then return nil end
    local s = F.pads[ctrlId]
    if not s then
        if not create then return nil end
        s = {}
        F.pads[ctrlId] = s
    end
    local e = s[arch]
    if not e and create then e = {}; s[arch] = e end
    return e
end

---------------------------------------------------------------------------------------------------- catalog
-- The model row of FREE MODE: every preset of the class, model by model (vehicles.models order: the owner-less presets
-- first, then the pilot / aged liveries) -> { {id = preset id, name, badge, maker, base} }
local function modelOptions(arch)
    local out = {}
    for _, m in ipairs(V.models(arch)) do
        local mname = m.name or m.codename or m.base
        pcall(function() mname = V.modelName(m) end)
        for _, p in ipairs(m.presets) do
            local extra = p.owner or ((p.livery and p.livery ~= "STANDARD") and p.livery) or nil
            out[#out + 1] = { id = p.id, name = extra and (tostring(mname) .. " · " .. tostring(extra)) or tostring(mname),
                              badge = m.badge, maker = m.maker, base = m.base }
        end
    end
    return out
end

-- every option of a row for a class (FREE MODE: everything; hidden entitlement options only with Garage4ShowHidden)
function M.freeOptions(arch, key)
    arch = tonumber(arch)
    if arch == nil then return {} end
    if key == "model" then return modelOptions(arch) end
    if not D then return {} end
    local src = (key == "mask" and D.MASKS[arch]) or (key == "palette" and D.PALETTES) or (key == "patina" and D.PATINAS)
        or (key == "decal" and arch == 1 and D.DECALS) or nil
    local out = {}
    local hidden = opt("Garage4ShowHidden", false) == true
    for _, e in ipairs(src or {}) do
        if hidden or not e.hidden then
            out[#out + 1] = { id = e.tag, name = e.name, colours = e.colours, path = e.path }
        end
    end
    return out
end

-- the choices of an area's row: the catalog, and for a livery row first "MODEL'S OWN" (id false = no override: the
-- preset's own tag, whatever it is - many presets name no palette / finish at all, so the catalog has no entry for
-- it); the catalog entry equal to the preset's own tag is left out (it would look exactly like MODEL'S OWN: a dead step)
local OWN_NAME = "MODEL'S OWN"
local function choices(arch, key, ownTag)
    local list = M.freeOptions(arch, key)
    if key == "model" then return list end
    local out = { { id = false, name = OWN_NAME } }
    for _, e in ipairs(list) do
        if e.id ~= ownTag then out[#out + 1] = e end
    end
    return out
end
M._choices = choices

local function presetOwn(presetId)
    return (D and D.PRESETS and presetId and D.PRESETS[presetId]) or {}
end

-- FREE MODE effective recipe of a pad's car: the card's preset + his stored tags -> eff (garage.lua's shape: arch,
-- preset, model, stored = his overrides, mask / palette / patina / decal / decalColour, custom = a livery of his own)
function M.freeEffective(ctrlId, arch, presetId)
    arch = tonumber(arch)
    local e = freeEntry(ctrlId, arch, false) or {}
    local own = presetOwn(presetId)
    local p = presetId and V.presetById(arch, presetId) or nil
    local r = { arch = arch, preset = presetId, model = p and p.base or nil, stored = {}, custom = false }
    for _, k in ipairs(LIVERY) do
        local v = e[k]
        if k == "decal" and arch ~= 1 then v = nil end
        r.stored[k] = v
        r[k] = v or own[k]
        if v ~= nil and v ~= own[k] then r.custom = true end
    end
    r.decalColour = own.decalColour
    return r
end

-- the livery a pick carries to the race (racers.choicePlayers): nil when the pad has nothing of his own for that class
-- (the preset races as it is); else a COPY {arch, preset, mask, palette, patina, decal} of the fields he set
function M.pickLivery(ctrlId, arch, presetId)
    if opt("Garage4Way", false) ~= true then return nil end
    local eff = M.freeEffective(ctrlId, arch, presetId)
    if not eff.custom then return nil end
    local t = { arch = tonumber(arch), preset = presetId }
    for _, k in ipairs(LIVERY) do t[k] = eff.stored[k] end
    return t
end

-- the full tag set a bay should show for (eff): every key the effective recipe names (nil = keep the model's own)
local function bayLivery(eff)
    if type(eff) ~= "table" then return nil end
    local t = {}
    for _, k in ipairs(LIVERY) do t[k] = eff[k] end
    t.decalColour = eff.decalColour
    return t
end
M.bayLivery = bayLivery

-- racers previews with the 4-way garage on: the card's bay wears the pad's livery too (nil = no livery control)
function M.cardLivery(ctrlId, arch, presetId)
    if opt("Garage4Way", false) ~= true or opt("Garage4BayLivery", "refresh") == "off" then return nil end
    local eff = M.freeEffective(ctrlId, arch, presetId)
    if not eff.custom then return nil end
    return bayLivery(eff)
end

---------------------------------------------------------------------------------------------------- rows
local function indexOf(list, id)
    for i, o in ipairs(list) do if o.id == id then return i end end
    return nil
end

local function className(arch)
    local c = V.classByArch(arch)
    return c and c.label or "VEHICLE"
end
M.className = className

-- the swatches of the model's own palette (MODEL'S OWN on the colours row)
local function ownColours(tag)
    if not (D and tag) then return nil end
    for _, e in ipairs(D.PALETTES) do if e.tag == tag then return e.colours end end
    return nil
end

-- an area's rows (couchpanel's garage row shape, so both hosts draw the same):
--   { rkind = "cycle", key, name, value, idx, n, sub, desc, icon, colours }, { rkind = "reset" }, { rkind = "done" }
local function freeRows(A)
    local eff = M.freeEffective(A.ctrlId, A.arch, A.preset)
    local rows = {}
    for _, c in ipairs(ROWS) do
        if (not c.pods) or A.arch == 1 then
            local list = choices(A.arch, c.key, presetOwn(A.preset)[c.key])
            local cur = A.preset
            if c.key ~= "model" then cur = eff.stored[c.key] or false end
            local i = indexOf(list, cur)
            local o = i and list[i] or nil
            local value = o and o.name or ((c.key == "model") and tostring(A.preset or "?") or tostring(cur))
            local desc
            if c.key == "model" then
                desc = (o and o.maker) and (o.maker .. " - every model unlocked") or "every model unlocked"
            elseif eff.stored[c.key] == nil then
                desc = "the model's own " .. string.lower(c.label)
            else
                desc = "your " .. string.lower(c.label)
            end
            rows[#rows + 1] = { rkind = "cycle", key = c.key, id = c.key, name = c.label, value = value, idx = i or 0,
                                n = #list, sub = string.format("<  %s  >   %d / %d", value, i or 0, #list), desc = desc,
                                icon = (c.key == "model" and o) and o.badge or nil,
                                colours = (c.key == "palette" and o) and (o.colours or ownColours(eff.palette)) or nil }
        end
    end
    rows[#rows + 1] = { rkind = "reset", id = "reset", name = "RESET", sub = "THE MODEL'S OWN LIVERY",
                        desc = "colours, template and finish back to the preset" }
    rows[#rows + 1] = { rkind = "done", id = "done", name = "DONE", sub = "READY - YOUR CAR IN THE RACE",
                        desc = "every change is kept at once" }
    return rows
end
M._freeRows = freeRows

---------------------------------------------------------------------------------------------------- session (front end)
-- S.areas[ctrlId] = { ctrlId, pnum, isP1, arch, cls, preset, sel, done, rows, toast, toastUntil, dirty, slot }
-- S.order = { ctrlId, ... } (view order: slot i = area i)
local S = { open = false, areas = {}, order = {}, lastSel = {}, scope = nil, by = nil, cb = nil, at = 0, ui = false, sig = nil,
            stats = { events = 0, changes = 0, renders = 0, wants = 0 } }

function M.isOpen() return S.open == true end
function M._forgetCursors() S.lastSel = {} end   -- tests: every area opens on MODEL again
function M.wanted() return opt("Garage4Way", false) == true and D ~= nil end
function M.state() return S end

local function toast(A, text, now)
    A.toast, A.toastUntil, A.dirty = text, (now or St.nowMs()) + TOAST_MS, true
end

local function bayKey(A) return A.ctrlId + 1 end              -- racers' bay key (vpreview: ControllerId + 1)

-- the area's car changed: rows, dirty, the host told (racers: the card's preset follows the area's model)
local function changed(A, what)
    A.rev = (A.rev or 0) + 1                     -- previews: the bay's want is sent again only after a change
    A.rows = freeRows(A)
    A.sel = math.max(1, math.min(A.sel, #A.rows))
    A.dirty = true
    S.stats.changes = S.stats.changes + 1
    if S.cb and S.cb.onChange then U.try(TAG, S.cb.onChange, A, what) end
end

local function stepRow(A, key, dir, now)
    local list = choices(A.arch, key, (key ~= "model") and presetOwn(A.preset)[key] or nil)
    if #list == 0 then return nil end
    if key == "model" then
        local i = indexOf(list, A.preset) or 0
        i = ((i - 1 + dir) % #list) + 1
        A.preset = list[i].id
        U.log(TAG, "P%d %s model -> %s (%d / %d)", A.pnum, className(A.arch), list[i].id, i, #list)
        changed(A, "model")
        return "nav"
    end
    local eff = M.freeEffective(A.ctrlId, A.arch, A.preset)
    local i = indexOf(list, eff.stored[key] or false) or 1
    i = ((i - 1 + dir) % #list) + 1
    local e = freeEntry(A.ctrlId, A.arch, true)
    local own = presetOwn(A.preset)
    -- MODEL'S OWN, or the model's own tag picked from the catalog, is stored as "no override" (RESET = the same look)
    local id = list[i].id
    e[key] = (id and id ~= own[key]) and id or nil
    save()
    U.log(TAG, "P%d %s %s -> %s (%d / %d)", A.pnum, className(A.arch), key, tostring(list[i].name), i, #list)
    if #list <= 1 then toast(A, "NOTHING ELSE FOR THIS CLASS", now) end
    changed(A, key)
    return "nav"
end

local function resetArea(A, now)
    loadState()
    local s = F.pads[A.ctrlId]
    if s then s[A.arch] = nil end
    save()
    U.log(TAG, "P%d %s livery reset: the preset's own", A.pnum, className(A.arch))
    toast(A, "THE MODEL'S OWN LIVERY", now)
    changed(A, "reset")
end

local function allDone()
    for _, c in ipairs(S.order) do
        local A = S.areas[c]
        if A and not A.done then return false end
    end
    return #S.order > 0
end

-- one player's event (racers.dispatch routes every event of every player here while the garage is open) -> what
-- happened ("nav" | "accept" | "quiet") or nil. Only this player's area can change.
function M.event(ctrlId, ev, rep, now)
    if not S.open then return nil end
    local A = S.areas[tonumber(ctrlId) or -1]
    if not A then return nil end
    now = now or St.nowMs()
    S.stats.events = S.stats.events + 1
    if A.done then
        if ev == "accept" or ev == "back" then
            if ev == "accept" then
                A.done, A.dirty = false, true
                toast(A, "CHANGE YOUR CAR", now)
                U.log(TAG, "P%d back in his garage", A.pnum)
                return "accept"
            end
        end
        return nil
    end
    local n = #A.rows
    local r = A.rows[A.sel]
    if ev == "up" then
        if A.sel > 1 then A.sel, A.dirty = A.sel - 1, true; return "nav" end
        return nil
    elseif ev == "down" then
        if A.sel < n then A.sel, A.dirty = A.sel + 1, true; return "nav" end
        return nil
    elseif ev == "left" or ev == "right" then
        if r and r.rkind == "cycle" then return stepRow(A, r.key, (ev == "right") and 1 or -1, now) end
        return nil
    elseif ev == "accept" then
        if not r then return nil end
        if r.rkind == "cycle" then return stepRow(A, r.key, 1, now) end
        if r.rkind == "reset" then resetArea(A, now); return "accept" end
        if r.rkind == "done" then
            A.done, A.dirty = true, true
            U.log(TAG, "P%d DONE (%s, %s)", A.pnum, tostring(A.preset), M.liveryText(M.freeEffective(A.ctrlId, A.arch, A.preset)))
            if allDone() then M.close("every player DONE") end
            return "accept"
        end
    elseif ev == "back" then
        -- B = DONE (the changes are kept: there is nothing to cancel)
        A.done, A.dirty = true, true
        U.log(TAG, "P%d leaves his garage (B)", A.pnum)
        if allDone() then M.close("every player DONE") end
        return "accept"
    end
    return nil
end

local function tagShort(s) return s and (s:gsub("^Customisation%.", "")) or "-" end
function M.liveryText(eff)
    if type(eff) ~= "table" then return "?" end
    return string.format("mask %s, colours %s, finish %s%s", tagShort(eff.mask), tagShort(eff.palette),
        tagShort(eff.patina), eff.decal and (", decal " .. tagShort(eff.decal)) or "")
end

-- players = { {ctrlId, pnum, isP1, arch, cls, presetId} } in view order; opts = { by = ctrlId, onChange = fn(A, what),
-- onClose = fn(why, areas) }. -> true when the garage is open (the host widget built), false, why otherwise.
function M.open(players, opts)
    if S.open then return true end
    if not M.wanted() then return false, "Garage4Way off or no catalog" end
    if type(players) ~= "table" or #players == 0 then return false, "no players" end
    opts = opts or {}
    S.areas, S.order, S.by, S.cb, S.at = {}, {}, opts.by, opts, St.nowMs()
    S.scope = "free"
    local list = {}
    for i, p in ipairs(players) do
        if i > 4 then break end
        local A = { ctrlId = p.ctrlId, pnum = p.pnum or i, isP1 = p.isP1 == true, arch = tonumber(p.arch), cls = p.cls,
                    preset = p.presetId, sel = 1, done = false, dirty = true, slot = i, toast = nil, toastUntil = 0 }
        A.rows = freeRows(A)
        -- live 2026-10-16: a reopened garage keeps each pad's cursor on its last row (not MODEL)
        local last = S.lastSel[A.ctrlId]
        if last then A.sel = math.max(1, math.min(last, #A.rows)) end
        S.areas[A.ctrlId] = A
        S.order[#S.order + 1] = A.ctrlId
        list[#list + 1] = string.format("P%d %s %s", A.pnum, className(A.arch), tostring(A.preset))
    end
    S.open = true
    local ui = UI()
    local okU, err = false, "garage4ui.lua not loaded"
    if ui then okU, err = pcall(ui.open, #S.order) end
    if not okU then
        S.open, S.areas, S.order, S.cb = false, {}, {}, nil
        U.warn(TAG, "4-way garage not opened: its screen failed (%s)", tostring(err))
        return false, tostring(err)
    end
    S.ui = true
    -- the badges of every model the areas can reach, resolved now (a model change must not find a texture in a tick)
    if ui.prefetch then
        local paths, seen = {}, {}
        for _, c in ipairs(S.order) do
            local a = S.areas[c].arch
            if not seen[a] then
                seen[a] = true
                for _, m in ipairs(V.models(a)) do if m.badge then paths[#paths + 1] = m.badge end end
            end
        end
        pcall(ui.prefetch, paths)
    end
    -- a still per bay (capture on change) unless the cars turn
    local vp = VP()
    if vp then
        for _, c in ipairs(S.order) do
            pcall(vp.setMode, c + 1, opt("Garage4Spin", false) == true and "spin" or "still")
            if opt("Garage4Spin", false) == true then pcall(vp.setCaptureMs, c + 1, tonumber(opt("Garage4SpinCaptureMs", 250))) end
        end
    end
    U.log(TAG, "4-way garage open for %d player(s) (opened by %s): %s (G4-01)", #S.order,
        opts.by and ("c" .. tostring(opts.by)) or "?", table.concat(list, ", "))
    return true
end

-- close (every DONE, the step left, a player joined / left, a phase / world change). The host widget goes; the bays
-- stay with racers' cards in the front end (same keys); vpreview releases them on START / leave / phase.
local function keepCursors()
    for c, A in pairs(S.areas) do S.lastSel[c] = A.sel end
end

function M.close(why)
    if not S.open then return end
    S.open = false
    keepCursors()
    local areas = S.areas
    local ui = UI()
    if ui and S.ui then U.try(TAG, ui.close, why) end
    S.ui = false
    local vp = VP()
    if vp then for _, c in ipairs(S.order) do pcall(vp.setCaptureMs, c + 1, nil) end end
    local cb = S.cb
    S.cb = nil
    U.log(TAG, "4-way garage closed (%s)", tostring(why))
    if cb and cb.onClose then U.try(TAG, cb.onClose, why, areas) end
end

-- the world went (travel): no call on any widget of it (they died with it)
function M.drop(why)
    if not S.open then return end
    keepCursors()
    S.open, S.cb = false, nil
    local ui = UI()
    if ui and ui.drop then pcall(ui.drop, why) end
    S.ui = false
    U.log(TAG, "4-way garage dropped (%s)", tostring(why))
end

-- an area's view model for garage4ui (pure Lua + the bay's brush, made in the tick that puts it on the image)
local function vmOf(A, now, live)
    local eff = M.freeEffective(A.ctrlId, A.arch, A.preset)
    local mname = "?"
    pcall(function()
        local p = V.presetById(A.arch, A.preset)
        if p then mname = V.modelName(p) end
    end)
    local vm = { pnum = A.pnum, colour = C.COLOURS[A.pnum] or C.COLOURS.Remote, who = "P" .. tostring(A.pnum),
                 title = "GARAGE", className = string.upper(className(A.arch)),
                 model = mname, rows = {}, sel = A.sel, done = A.done, livery = eff,
                 toast = (A.toast and now < (A.toastUntil or 0)) and A.toast or nil,
                 -- one hint for every player (live 2026-10-16: P1's differed). P1's B is the page's own Back before a
                 -- race (his PlayerController reads no pad key there): the DONE row is everybody's way out
                 hint = A.done and "READY - A: CHANGE AGAIN" or M.HINT,
                 waiting = nil }
    if A.done then
        local w = {}
        for _, c in ipairs(S.order) do
            local o = S.areas[c]
            if o and not o.done then w[#w + 1] = "P" .. tostring(o.pnum) end
        end
        vm.waiting = (#w > 0) and ("WAITING FOR " .. table.concat(w, ", ")) or nil
    end
    for i, r in ipairs(A.rows) do
        vm.rows[i] = { kind = r.rkind, label = r.name, value = r.value, sub = r.sub, desc = r.desc, icon = r.icon,
                       colours = r.colours, idx = r.idx, n = r.n, focus = (i == A.sel) and not A.done }
    end
    if live then
        local vp = VP()
        if vp and opt("Garage4Bays3D", true) ~= false then
            local ok, br, kind, dim = pcall(vp.brush, bayKey(A))
            if ok and br then vm.brush, vm.brushKind, vm.dim = br, kind, dim end
        end
    end
    return vm
end
M._vmOf = vmOf

-- racers.previews while the garage is open: each area's bay wants its car (preset + livery), sent on open and after
-- each change of that area only (no per-tick garbage)
function M.previews(now)
    if not S.open then return end
    local vp = VP()
    if not vp or opt("Garage4Bays3D", true) == false then return end
    for _, c in ipairs(S.order) do
        local A = S.areas[c]
        if A and A.wantRev ~= (A.rev or 0) then
            A.wantRev = A.rev or 0
            local p = V.presetById(A.arch, A.preset)
            local cls = A.cls or V.classByArch(A.arch)
            if p and cls then
                local eff = M.freeEffective(A.ctrlId, A.arch, A.preset)
                local liv = (opt("Garage4BayLivery", "refresh") ~= "off") and bayLivery(eff) or nil
                pcall(vp.want, bayKey(A), p, cls, liv)
                S.stats.wants = S.stats.wants + 1
            end
        end
    end
end

-- a bay changed (vpreview.tick keys): that area's image re-renders
function M.bayChanged(key)
    local A = S.areas[(tonumber(key) or 0) - 1]
    if A then A.dirty = true end
end

-- racers.poll while open: toasts, then up to 2 dirty areas rendered (oldest slot first)
function M.poll(now)
    if not S.open then return end
    now = now or St.nowMs()
    local ui = UI()
    local budget = 2
    for _, c in ipairs(S.order) do
        local A = S.areas[c]
        if A then
            if A.toast and now >= (A.toastUntil or 0) then A.toast, A.dirty = nil, true end
            if A.dirty and budget > 0 and ui then
                A.dirty = false
                budget = budget - 1
                local ok, err = pcall(ui.render, A.slot, vmOf(A, now, true))
                S.stats.renders = S.stats.renders + 1
                if not ok then U.logEvery("garage4.render", 5000, TAG, "area P%d render failed: %s", A.pnum, tostring(err)) end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- couch campaign
-- couchpanel's garage split with cfg.CouchGarage4Way: each guest panel P {ctrlId, pnum, arch, rows, sel, done} gets
-- his 3D car; called from couchpanel's FAST tick while the split is open. The bays live in the paddock world
-- (vpreview.allowOutside) and go when the split closes (M.campaignClose) or with any phase change.
local CAMP = { on = false, keys = {} }
function M.campaignWanted() return opt("CouchGarage4Way", false) == true end

function M.campaignTick(panels)
    if not M.campaignWanted() or type(panels) ~= "table" then return false end
    local vp = VP()
    if not vp or opt("Garage4Bays3D", true) == false then return false end
    if not CAMP.on then
        CAMP.on = true
        pcall(vp.allowOutside, TAG, true)
        U.log(TAG, "couch garage: 3D cars for %d guest area(s) (phase %s) (G4-07)", #panels, tostring(St.phase))
    end
    for _, P in ipairs(panels) do
        -- couchpanel replaces P.rows on every change of his: the want is sent on the first tick and after a change only
        if P.ctrlId ~= nil and P.arch ~= nil and P.g4want ~= P.rows then
            P.g4want = P.rows
            local okE, eff = pcall(function() return G().effective(P.pnum, P.arch) end)
            if okE and type(eff) == "table" and eff.preset then
                local p = V.presetById(P.arch, eff.preset)
                local cls = V.classByArch(P.arch)
                if p and cls then
                    local key = P.ctrlId + 1
                    CAMP.keys[key] = true
                    pcall(vp.setMode, key, opt("Garage4Spin", false) == true and "spin" or "still")
                    pcall(vp.want, key, p, cls, (opt("Garage4BayLivery", "refresh") ~= "off") and bayLivery(eff) or nil)
                end
            end
        end
    end
    local ok, ch, keys = pcall(vp.tick)
    return ok and ch == true, (ok and type(keys) == "table") and keys or {}
end

-- a couch guest panel's brush (couchpanel's renderGarage): mid, kind, dim | nil
function M.campaignBrush(P)
    if not CAMP.on or type(P) ~= "table" or P.ctrlId == nil then return nil end
    local vp = VP()
    if not vp then return nil end
    local ok, br, kind, dim = pcall(vp.brush, P.ctrlId + 1)
    if ok and br then return br, kind, dim end
    return nil
end

-- drop = true (a phase / world change): the references only, nothing is called on the actors of a world in change
function M.campaignClose(why, drop)
    if not CAMP.on then return end
    CAMP.on = false
    local vp = VP()
    if vp then
        if drop and vp.dropAll then pcall(vp.dropAll, "couch garage: " .. tostring(why))
        else pcall(vp.releaseAll, "couch garage closed: " .. tostring(why), true) end
        pcall(vp.allowOutside, TAG, false)
    end
    CAMP.keys = {}
    U.log(TAG, "couch garage: 3D cars released (%s) (G4-07)", tostring(why))
end
function M.campaignOn() return CAMP.on end

---------------------------------------------------------------------------------------------------- couch pre-run
-- couch pre-run VEHICLE SELECT (couchprerun, cfg.CouchPreRunNative; guest-garage.md section 7): the guest's half is
-- drawn in the 4-way garage's area look and his bay shows the car he would race in the HIGHLIGHTED class (his garage
-- model + livery, garage.effective). Same bay plumbing as the campaign garage split: keys = ControllerId + 1, stills
-- (a capture on change only), vpreview's outside-the-front-end grant, released through M.campaignClose (the two splits
-- are never open at once).

-- what the guest's area shows for a class: the model's game name and his palette's three colours. Pure data (one
-- garage.effective + Lua tables); called from couchprerun's render, never in an idle tick.
function M.prerunInfo(pnum, arch)
    local out = {}
    pcall(function()
        local eff = G().effective(pnum, arch)
        local p = eff.preset and V.presetById(arch, eff.preset) or nil
        if p then out.model = V.modelName(p) end
        if D and eff.palette then
            for _, e in ipairs(D.PALETTES) do
                if e.tag == eff.palette then out.colours = e.colours; break end
            end
        end
    end)
    return out
end

-- couch-fix44 (live 2026-10-18 12:09, A3): the pre-run lives in the paddock (phase OTHER), where vpreview.enabled() is
-- false until a host grants the bays (allowOutside). couchprerun asked enabled() at the copy's build, BEFORE the first
-- prerunTick made that grant: every guest got the game's 2D image. The grant is made here, first, then enabled() is
-- asked. -> true | false, reason (no grant left behind on false).
function M.prerunGrant()
    local vp = VP()
    if not vp then return false, "no vpreview" end
    if opt("Garage4Bays3D", true) == false then return false, "Garage4Bays3D = false" end
    if not CAMP.on then
        CAMP.on = true
        pcall(vp.allowOutside, TAG, true)
        U.log(TAG, "couch pre-run: 3D bays granted (phase %s) (G4-07)", tostring(St.phase))
    end
    if type(vp.enabled) ~= "function" then return true end
    local ok, on, why = pcall(vp.enabled)
    if ok and on == true then return true end
    M.campaignClose("no 3D bays: " .. tostring(ok and why or on), false)
    return false, ok and why or tostring(on)
end

-- panels = couchprerun's S.panels (P {ctrlId, pnum, g4arch = the highlighted class, g4want = the last wanted one}).
-- A want goes out only when a guest's highlighted class changed. -> changed, { [bayKey] = true } (the areas to redraw)
function M.prerunTick(panels)
    if type(panels) ~= "table" or #panels == 0 then return false end
    local vp = VP()
    if not vp or opt("Garage4Bays3D", true) == false then return false end
    if not CAMP.on then
        CAMP.on = true
        pcall(vp.allowOutside, TAG, true)
        U.log(TAG, "couch pre-run: 3D cars for %d guest area(s) (phase %s) (G4-07)", #panels, tostring(St.phase))
    end
    for _, P in ipairs(panels) do
        local arch = P.g4arch
        if P.ctrlId ~= nil and arch ~= nil and P.g4want ~= arch then
            P.g4want = arch
            local okE, eff = pcall(function() return G().effective(P.pnum, arch) end)
            if okE and type(eff) == "table" and eff.preset then
                local p = V.presetById(arch, eff.preset)
                local cls = V.classByArch(arch)
                if p and cls then
                    local key = P.ctrlId + 1
                    CAMP.keys[key] = true
                    pcall(vp.setMode, key, "still")
                    pcall(vp.want, key, p, cls, (opt("Garage4BayLivery", "refresh") ~= "off") and bayLivery(eff) or nil)
                end
            end
        end
    end
    local ok, ch, keys = pcall(vp.tick)
    return ok and ch == true, (ok and type(keys) == "table") and keys or {}
end

---------------------------------------------------------------------------------------------------- the race
-- FREE MODE / GALACTIC GRAND PRIX race (launch's cards plan, St.launch.vehPlan): every local human whose pick carries a
-- livery gets it on his car once the car exists, through HIS PlayerState's component (garage.apply: the upload or the
-- tags mode of cfg.CouchGarageApply), read back, re-applied after a rebuild (respawn), at most CouchGarageTries per
-- player and world. A couch campaign race is garage.raceTick's (this returns). A pick whose class is not the car's
-- (gp.prelaunch moved him) is skipped: templates are per class.
local R = { wk = nil, g = {}, at = 0 }
local SETTLED = { ok = true, gaveup = true, skip = true }

local function humans()
    local list = { { pnum = 1, ctrlId = 0, pc = U.p1() } }
    local okJ, js = pcall(function() return U.mod("join").joinedList() end)
    if okJ and type(js) == "table" then
        for _, e in ipairs(js) do list[#list + 1] = { pnum = e.pnum, ctrlId = e.ctrlId, pc = e.pc } end
    end
    return list
end

local function pickOf(vp, ctrlId, pnum)
    for _, p in pairs(vp.players or {}) do
        if type(p) == "table" and tonumber(p.ctrlId) == ctrlId then return p end
    end
    local p = vp.players and vp.players[pnum]
    if type(p) == "table" and p.ctrlId == nil then return p end
    return nil
end

function M.raceTick()
    if opt("CouchGarageApply", "upload") == "off" then return end
    if St.phase ~= "PRERACE" and St.phase ~= "RACING" then return end
    local vp = St.launch and St.launch.vehPlan
    if type(vp) ~= "table" or vp.flow ~= "cards" then return end
    local now = St.nowMs()
    if now - R.at < 400 then return end
    R.at = now
    if R.wk ~= St.worldGen then R.wk, R.g = St.worldGen, {} end
    local okC, couchOn = pcall(function() return U.mod("couch").active() end)
    if okC and couchOn == true then return end
    local maxTries = math.max(1, math.floor(tonumber(opt("CouchGarageTries", 3)) or 3))
    for _, h in ipairs(humans()) do
        local g = R.g[h.ctrlId]
        if not g then g = { tries = 0, last = -1e12 }; R.g[h.ctrlId] = g end
        U.try(TAG, function()
            local pick = pickOf(vp, h.ctrlId, h.pnum)
            local liv = type(pick) == "table" and pick.livery or nil
            if type(liv) ~= "table" then
                if g.state ~= "skip" then g.state = "skip" end
                return
            end
            if not U.ok(h.pc) then return end
            local ps, pawn, comp = nil, nil, nil
            pcall(function() ps = h.pc.PlayerState end)
            if not U.ok(ps) then return end
            pcall(function() pawn = ps.PawnPrivate end)
            if not U.ok(pawn) then return end
            pcall(function() comp = ps.VehicleCustomisationComponent end)
            if not U.ok(comp) then return end
            local rk = nil
            pcall(function() rk = U.key(comp.VehicleRecipe) end)
            local sig = tostring(U.key(pawn)) .. "/" .. tostring(rk)
            if SETTLED[g.state] and g.sig == sig then return end
            g.sig = sig
            local have = G()._carTags(comp)
            if not have then return end
            local arch = tonumber(have.arch)
            local preset = pick.presetId
            if arch ~= tonumber(liv.arch) or (liv.preset and liv.preset ~= preset) then
                if g.state ~= "skip" then
                    g.state = "skip"
                    U.log(TAG, "P%d's livery is for %s / %s, his car is %s / %s: not applied", h.pnum, tostring(liv.arch),
                        tostring(liv.preset), tostring(arch), tostring(preset))
                end
                return
            end
            local own = presetOwn(preset)
            local p = V.presetById(arch, preset)
            local eff = { arch = arch, preset = preset, model = p and p.base or nil, stored = {}, custom = true,
                          decalColour = own.decalColour }
            for _, k in ipairs(LIVERY) do
                eff.stored[k] = liv[k]
                eff[k] = liv[k] or own[k]
            end
            if G().matches(eff, have) then
                if g.state ~= "ok" then
                    g.state = "ok"
                    U.log(TAG, "P%d's car carries his livery (%s, %s) [%s] (G4-05)", h.pnum, tostring(preset),
                        M.liveryText(eff), St.phase)
                end
                return
            end
            if g.tries >= maxTries then
                if g.state ~= "gaveup" then
                    g.state = "gaveup"
                    U.warn(TAG, "P%d's livery not on his car after %d upload(s)", h.pnum, g.tries)
                end
                return
            end
            if now - g.last < 1500 then return end
            g.last, g.tries = now, g.tries + 1
            local ok, how = G().apply(comp, eff)
            g.state = ok and "sent" or "failed"
            local fn = ok and U.log or U.warn
            fn(TAG, "P%d livery %s (try %d): %s %s - %s (G4-05)", h.pnum, ok and "applied" or "NOT applied", g.tries,
                tostring(preset), M.liveryText(eff), tostring(how))
        end)
    end
end

---------------------------------------------------------------------------------------------------- diag / life
function M.status()
    local parts = {}
    for _, c in ipairs(S.order) do
        local A = S.areas[c]
        if A then
            parts[#parts + 1] = string.format("P%d c%d %s row %d%s %s", A.pnum, A.ctrlId, className(A.arch), A.sel,
                A.done and " DONE" or "", tostring(A.preset))
        end
    end
    return string.format("garage4 %s%s: %s | events %d, changes %d, renders %d | couch 3D %s",
        S.open and "open" or "closed", S.open and (" (" .. #S.order .. " areas)") or "",
        (#parts > 0) and table.concat(parts, "; ") or "-", S.stats.events, S.stats.changes, S.stats.renders,
        CAMP.on and "on" or "off")
end

function M.init()
    St.on("world", TAG, function()
        R.wk, R.g = nil, {}
        if S.open then M.drop("world") end
        CAMP.on, CAMP.keys = false, {}
    end)
    St.on("phase", TAG, function(new)
        if new ~= "FRONTEND" and S.open then M.close("phase " .. tostring(new)) end
        if CAMP.on then M.campaignClose("phase " .. tostring(new), true) end
    end)
end

return M
