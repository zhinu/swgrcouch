-- garage.lua: COUCH CAMPAIGN - each guest's own car customisation (his GARAGE). Jules 2026-10-15: "one thing missing
-- is the customization of P2's car". Research, evidence and design: docs/dev/guest-garage.md.
--
-- What a car is (decoded 2026-10-15, docs/dev/guest-garage.md section 1): the race builds a human's car from ONE
-- struct, FCstSavedVehicleRecipeData {RecipeName, VehicleArchetype, UnitLayoutName, UnitRecipes (the model's kit
-- parts), RootPhysicsConfiguration, LiveryPaletteTag, LiveryMaskTag, IconPaletteTag, IconMaskTag, PatinaTag},
-- uploaded through his PlayerState's PlayerVehicleCustomisationComponent:Server_UpdateVehicleRecipe (the game's own
-- per-player path: its OnPawnSetCallback uploads the grid entry's preset class as that struct, or, with no preset, the
-- FIRST local player's saved garage recipe - P1's). The server spawns a CstVehicleRecipe actor from it
-- (VehicleRecipe) and rebuilds the pawn's customisation when the pawn exists.
-- P1's own garage lives in HIS LocalPlayer's CstSubsystem (VehicleRecipeDatas, two slots per class); the game's
-- Customize screens edit the ONE BP_CstPawn_C of the front end (BPFL_CustomisationFunctionLibrary.FindCustomisationPawn
-- = GetAllActorsOfClass()[0]) and CstCustomisationComponent:SaveCustomisationRecipes writes the FIRST local player's
-- CstSubsystem: a second instance of those screens for a guest would edit and save P1's car. So a guest's garage is
-- mod-side (this module, Mods/SWGRCouch/guest-garage.txt), edited in a compact game-style panel (couchpanel kind
-- "garage", opened from the run map like his own shop), and reaches his car through the same struct upload.
--
-- A guest's recipe per class: model (a base model = the game's "Choose Model" theme, raced as its standard PRE_*
-- preset), mask (livery template tag), palette (colours tag), patina tag, decal tag (pods only); nil = the model
-- preset's own value. Stored per SEAT (P2 / P3 / P4) and class, kept across runs and sessions; never P1's data.
--   * the model goes on his grid entry (couch.guestVehicle -> M.presetFor): FRecipeRacerSetup.VehicleCustomisation;
--   * a livery (any of mask / palette / patina / decal set) is uploaded in the race (M.raceTick) once his car exists:
--     Server_UpdateVehicleRecipe(<the model preset's CDO fields + his tags>) (cfg.CouchGarageApply "upload"), or the
--     tags written on his VehicleRecipe actor + OnRep_VehicleRecipe() ("tags"). Read back: re-applied when the
--     game rebuilt his car (a respawn), at most cfg.CouchGarageTries times per world.
-- KIT PARTS (couch-garage2, 2026-10-16): the game's own garage turn (garagenative.lua) also edits his kit parts ("Edit
-- Vehicle": one CustomisationOptionView per part tab, UpdateUISelection + SaveCustomisationRecipes on the slot). They are
-- kept per seat and class as `units` = { {UnitName, parts = {{ParentPartType, PartType, vehicleKit}}} } (FNames as
-- strings, only when they differ from the model preset's) and reach his car with the same upload: the preset CDO's
-- UnitRecipes are patched for the one Server_UpdateVehicleRecipe call (UE4SS deep-copies the TArray into the param) and
-- put back at once (no other game code runs during a Lua call on the game thread). A new model (compact garage) drops
-- them: another model has other parts.
-- Options: the game's catalog (custdata.lua, generated from the paks). cfg.CouchGarageUnlocks = "p1" offers what P1
-- owns (CstOptionFunctionLibrary:IsOptionUnlockedAndPurchased on P1's account, as the game's own option view tests it;
-- unreadable = offered), "all" everything.
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")

local TAG = "garage"
local M = {}
local FILE = "guest-garage.txt"

local okD, D = pcall(require, "custdata")
if not okD or type(D) ~= "table" then D = nil end

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function V() return U.mod("vehicles") end

-- the rows of a class' garage panel (couchpanel kind "garage"), in order; decals exist for pods only (the game's
-- IconMaskMap holds pod engine / cockpit icons: Nesodon, Cretornis, Sordes)
local CYCLE = {
    { key = "model", label = "MODEL" },
    { key = "mask", label = "LIVERY" },
    { key = "palette", label = "COLOURS" },
    { key = "patina", label = "FINISH" },
    { key = "decal", label = "DECAL", pods = true },
}
M.CYCLE = CYCLE
local TAGKEY = { mask = "LiveryMaskTag", palette = "LiveryPaletteTag", patina = "PatinaTag", decal = "IconMaskTag",
                 decalColour = "IconPaletteTag" }
M.TAGKEY = TAGKEY
local LIVERY = { "mask", "palette", "patina", "decal" }

local function className(arch)
    local c = V().classByArch(arch)
    return c and c.label or "VEHICLE"
end
M.className = className

-- the classes a garage serves: the run classes (landspeeder 0, bike 2, skimmer 3) and pods (1, FREE MODE later)
function M.supported(arch)
    arch = tonumber(arch)
    return D ~= nil and arch ~= nil and D.MASKS and D.MASKS[arch] ~= nil
end

---------------------------------------------------------------------------------------------------- persistence
-- F = { version = 1, seats = { [seat] = { [arch] = {model, mask, palette, patina, decal} } } }
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
        if ok and type(t) == "table" and type(t.seats) == "table" then F = t end
    end
    F = F or { version = 1, seats = {} }
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

-- COUCH SEATS (couchseat.lua, FINDING #43): the records are per SEAT (2 = the first guest to join the run, 3, 4); the
-- callers hold the guest's display number (pnum = his rank in view order). The two are the same until a middle seat
-- leaves while a higher one stays: the seat of the guest shown as P<pnum> is looked up here (couchseat.ofPnum; no seat
-- module / no such guest: pnum itself). Files keyed by pnum before seats need no migration (pnum was the seat number).
local function seatOf(pnum)
    local ok, s = pcall(function() return U.mod("couchseat").ofPnum(pnum) end)
    if ok and tonumber(s) then return tonumber(s) end
    return tonumber(pnum)
end
M.seatOf = seatOf

local function entrySeat(seat, arch, create)
    loadState()
    seat, arch = tonumber(seat), tonumber(arch)
    if not (seat and arch) then return nil end
    local s = F.seats[seat]
    if not s then
        if not create then return nil end
        s = {}
        F.seats[seat] = s
    end
    local e = s[arch]
    if not e and create then e = {}; s[arch] = e end
    return e
end
local function entry(pnum, arch, create) return entrySeat(seatOf(pnum), arch, create) end

---------------------------------------------------------------------------------------------------- catalog
-- unlock test (cfg.CouchGarageUnlocks "p1"): path -> true | false | nil (unreadable). Cached per session; tests replace
-- it with M._setUnlockFn.
local unlockCache = {}
local unlockFn = nil
function M._setUnlockFn(fn) unlockFn = fn; unlockCache = {} end

local function runtimeUnlocked(path)
    local lib = U.cdo("/Script/Griffin.Default__CstOptionFunctionLibrary")
    if not U.ok(lib) then return nil end
    local o = U.obj(path)                            -- StaticFindObject, else LoadAsset once (util tryLoad)
    if not U.ok(o) then return nil end
    local ctx = U.p1()
    if not U.ok(ctx) then return nil end
    local ok, r = pcall(U.callMethod, lib, "IsOptionUnlockedAndPurchased", o, ctx)
    if ok and type(r) == "boolean" then return r end
    return nil
end

local function allowed(e)
    if opt("CouchGarageUnlocks", "p1") == "all" then return true end
    local path = e and e.path
    if type(path) ~= "string" then return true end
    local v = unlockCache[path]
    if v == nil then
        local fn = unlockFn or runtimeUnlocked
        local ok, r = pcall(fn, path)
        if ok and type(r) == "boolean" then v = r else v = "?" end
        unlockCache[path] = v
        if v == "?" then
            U.logOnce("garage.unlock?", TAG, "unlock state unreadable (first: %s): such options are offered", path)
        end
    end
    return v ~= false
end

-- the base model entries of a class (vehicles.models: the game's model names, badges); id = base
local function modelOptions(arch)
    local out = {}
    for _, m in ipairs(V().models(arch)) do
        local th = D and D.THEMES and D.THEMES[m.base] or nil
        local pr = m.presets[1]
        if pr and not pr.owner then
            out[#out + 1] = { id = m.base, name = m.name or m.codename or m.base, preset = pr.id, badge = m.badge,
                              maker = m.maker, path = th and th.path or nil, def = th and th.def or nil }
        end
    end
    return out
end

-- every option of a row for a class, the game's order -> { {id, name, ...} }; id = the tag (model: the base)
local function catalog(arch, key)
    arch = tonumber(arch)
    if not D or arch == nil then return {} end
    if key == "model" then return modelOptions(arch) end
    local src = (key == "mask" and D.MASKS[arch]) or (key == "palette" and D.PALETTES) or (key == "patina" and D.PATINAS)
        or (key == "decal" and D.DECALS) or nil
    local out = {}
    for _, e in ipairs(src or {}) do
        out[#out + 1] = { id = e.tag, name = e.name, path = e.path, def = e.def, colours = e.colours, hidden = e.hidden }
    end
    return out
end
M.catalog = catalog

-- the options a guest may pick (unlock filter); the current value always stays in the list (a stored pick P1 no
-- longer owns is kept, never silently changed)
function M.options(arch, key, keep)
    local out = {}
    for _, e in ipairs(catalog(arch, key)) do
        if e.id == keep or allowed(e) then out[#out + 1] = e end
    end
    return out
end

---------------------------------------------------------------------------------------------------- recipes
-- the default model of a seat: the preset FREE MODE / the grid patch gives him today (vehicles.defaultPresetIndex)
local function defaultModel(arch, pnum)
    local list = V().presets(arch)
    local pr = list[V().defaultPresetIndex(arch, pnum)]
    return pr and pr.base or nil
end

local function modelEntry(arch, base)
    for _, m in ipairs(modelOptions(arch)) do if m.id == base then return m end end
    return nil
end

-- his effective recipe for a class -> { arch, model, preset, mask, palette, patina, decal, decalColour, custom,
-- stored = {...} }: custom = a livery field of his differs from the model preset's own (an upload is needed)
local function effectiveOf(e, arch, pnum)
    e = e or {}
    local base = e.model
    if not (base and modelEntry(arch, base)) then base = defaultModel(arch, pnum) end
    local m = base and modelEntry(arch, base) or nil
    local preset = m and m.preset or nil
    local own = (D and D.PRESETS and preset and D.PRESETS[preset]) or {}
    local r = { arch = arch, model = base, preset = preset, stored = e, custom = false }
    for _, k in ipairs(LIVERY) do
        r[k] = e[k] or own[k]
        if e[k] ~= nil and e[k] ~= own[k] then r.custom = true end
    end
    -- his kit parts (garagenative), only for the model they were made on
    if type(e.units) == "table" and #e.units > 0 and e.model == base then r.units = e.units; r.custom = true end
    r.decalColour = own.decalColour
    return r
end
function M.effective(pnum, arch)
    arch = tonumber(arch)
    return effectiveOf(entry(pnum, arch, false), arch, pnum)
end
-- the same for a known seat (a joinedList entry's e.seat: no display-number lookup)
function M.effectiveSeat(seat, arch, pnum)
    arch = tonumber(arch)
    return effectiveOf(entrySeat(seat, arch, false), arch, pnum or seat)
end

-- the preset his grid entry gets (nil = no garage model stored: the caller keeps its own default)
function M.presetFor(pnum, arch)
    local e = entry(pnum, arch, false)
    if not (e and e.model) then return nil end
    local m = modelEntry(tonumber(arch), e.model)
    return m and m.preset or nil
end

local function indexOf(list, id)
    for i, o in ipairs(list) do if o.id == id then return i end end
    return nil
end

-- one step of a row (dir +1 / -1, wraps) -> the new option entry, its index and the count
function M.cycle(pnum, arch, key, dir)
    arch = tonumber(arch)
    local eff = M.effective(pnum, arch)
    local cur = eff[key]
    local list = M.options(arch, key, cur)
    if #list == 0 then return nil, 0, 0 end
    local i = indexOf(list, cur) or 0
    i = ((i - 1 + (dir or 1)) % #list) + 1
    local e = entry(pnum, arch, true)
    e[key] = list[i].id
    if key == "model" then e.units = nil end           -- another model: other kit parts
    save()
    U.log(TAG, "P%s %s %s -> %s (%d / %d)", tostring(pnum), className(arch), key, tostring(list[i].name), i, #list)
    return list[i], i, #list
end

function M.reset(pnum, arch)
    loadState()
    local s = F.seats[seatOf(pnum) or -1]
    if s then s[tonumber(arch)] = nil end
    save()
    U.log(TAG, "P%s %s garage reset: the default car", tostring(pnum), className(arch))
end

-- garagenative.lua: a guest's result from the game's own garage (his turn) -> his store. st = { model = base id,
-- mask / palette / patina / decal = tags or nil }; a field equal to the model preset's own is stored as nil (default).
function M.setFromNative(pnum, arch, st)
    arch = tonumber(arch)
    local e = entry(pnum, arch, true)
    if not e then return false end
    for k in pairs(e) do e[k] = nil end
    local m = st.model and modelEntry(arch, st.model) or nil
    if m then e.model = st.model end
    local own = (D and D.PRESETS and m and m.preset and D.PRESETS[m.preset]) or {}
    for _, k in ipairs(LIVERY) do
        -- decals exist for pods only (arch 1); a root tag ("Customisation.Livery", "Customisation.Patina") = the default
        local root = st[k] == "Customisation.Livery" or st[k] == "Customisation.Patina"
        if st[k] ~= nil and st[k] ~= own[k] and not root and (k ~= "decal" or arch == 1) then e[k] = st[k] end
    end
    -- his kit parts ("Edit Vehicle"): garagenative passes them only when they differ from the model preset's
    if m and type(st.units) == "table" and #st.units > 0 then e.units = st.units end
    save()
    U.log(TAG, "P%s %s garage from the game's own screens: model %s%s%s", tostring(pnum), className(arch),
        tostring(st.model), e.units and string.format(", %d kit part(s) of his own", M.partCount(e.units)) or "",
        m and "" or " (not in the catalog: model kept as before)")
    return true
end

function M.stored(pnum, arch) local e = entry(pnum, arch, false); return e ~= nil and next(e) ~= nil end

---------------------------------------------------------------------------------------------------- kit parts
local function nameStr(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return tostring(v)
end

-- a TArray<FCstPresetRecipeUnit> (a slot's, a preset CDO's, a recipe actor's) -> the plain units table, or nil
function M.readUnits(arr)
    if arr == nil then return nil end
    local out = {}
    local ok = pcall(function()
        for i = 1, arr:GetArrayNum() do
            local u = arr[i]
            local ur = { UnitName = nameStr(u.UnitName), parts = {} }
            pcall(function()
                local parts = u.Parts
                for j = 1, parts:GetArrayNum() do
                    local p = parts[j]
                    ur.parts[#ur.parts + 1] = { ParentPartType = nameStr(p.ParentPartType), PartType = nameStr(p.PartType),
                                                vehicleKit = nameStr(p.vehicleKit) }
                end
            end)
            out[#out + 1] = ur
        end
    end)
    return ok and out or nil
end

function M.partCount(units)
    local n = 0
    for _, u in ipairs(units or {}) do n = n + #(u.parts or {}) end
    return n
end

-- pure: same kit parts (unit / part counts, every part's PartType / vehicleKit / ParentPartType)
function M.sameUnits(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        local pa, pb = a[i].parts or {}, b[i].parts or {}
        if #pa ~= #pb then return false end
        for j = 1, #pa do
            if pa[j].PartType ~= pb[j].PartType or pa[j].vehicleKit ~= pb[j].vehicleKit
                or pa[j].ParentPartType ~= pb[j].ParentPartType then return false end
        end
    end
    return true
end

-- writes the units' part names into a TArray<FCstPresetRecipeUnit> in place, where the unit / part counts match ->
-- parts written, undo list ({part, field, old string})
function M.patchUnits(arr, units)
    local n, undo = 0, {}
    if type(units) ~= "table" then return 0, undo end
    pcall(function()
        if arr:GetArrayNum() ~= #units then return end
        for i = 1, #units do
            local parts = arr[i].Parts
            local sp = units[i].parts or {}
            if parts:GetArrayNum() == #sp then
                for j = 1, #sp do
                    local p = parts[j]
                    for _, f in ipairs({ "ParentPartType", "PartType", "vehicleKit" }) do
                        local v = sp[j][f]
                        if type(v) == "string" then
                            local old = nil
                            pcall(function() old = nameStr(p[f]) end)
                            if old ~= v and pcall(function() p[f] = U.fname(v) end) then
                                undo[#undo + 1] = { p = p, f = f, old = old }
                            end
                        end
                    end
                    n = n + 1
                end
            end
        end
    end)
    return n, undo
end

function M.unpatchUnits(undo)
    for i = #(undo or {}), 1, -1 do
        local u = undo[i]
        if type(u.old) == "string" then pcall(function() u.p[u.f] = U.fname(u.old) end) end
    end
end

-- the kit parts of a model's preset (its CDO) -> units table or nil
function M.presetUnits(arch, model)
    local th = D and D.THEMES and D.THEMES[model] or nil
    local preset = th and th.preset or nil
    if not preset then
        local m = modelEntry(tonumber(arch), model)
        preset = m and m.preset or nil
    end
    if not preset then return nil end
    local t = M.recipeTable({ arch = tonumber(arch), preset = preset, model = model, stored = {} })
    return t and M.readUnits(t.UnitRecipes) or nil
end

-- pure: does his car carry his kit parts? true / false, nil = unknown (the car's units unreadable)
function M.partsMatch(eff, have)
    if type(eff) ~= "table" or type(eff.units) ~= "table" then return true end
    if type(have) ~= "table" then return nil end
    return M.sameUnits(eff.units, have)
end

---------------------------------------------------------------------------------------------------- panel rows
-- the panel rows of a guest's garage (couchpanel kind "garage", list view, at most 6 rows):
--   { rkind = "cycle", key, name = label, value, idx, n, sub = "< VALUE >  3 / 12", desc, icon, colours }
--   { rkind = "reset" }, { rkind = "done" }
function M.rows(pnum, arch)
    arch = tonumber(arch)
    local eff = M.effective(pnum, arch)
    local rows = {}
    for _, c in ipairs(CYCLE) do
        if (not c.pods) or arch == 1 then
            local list = M.options(arch, c.key, eff[c.key])
            local i = indexOf(list, eff[c.key])
            local o = i and list[i] or nil
            local own = (eff.stored[c.key] == nil)
            local value = o and o.name or ((c.key == "model") and "?" or "NONE")
            local desc
            if c.key == "model" then
                desc = (o and o.maker) and (o.maker .. " - the model you race in every event") or "the model you race in every event"
            elseif own then
                desc = "the model's own " .. string.lower(c.label)
            else
                desc = "your " .. string.lower(c.label)
            end
            rows[#rows + 1] = { rkind = "cycle", key = c.key, id = c.key, name = c.label, value = value, idx = i or 0,
                                n = #list, sub = string.format("<  %s  >   %d / %d", value, i or 0, #list), desc = desc,
                                icon = (c.key == "model" and o) and o.badge or nil,
                                colours = (c.key == "palette" and o) and o.colours or nil }
        end
    end
    if arch ~= 1 then
        rows[#rows + 1] = { rkind = "reset", id = "reset", name = "RESET", sub = "BACK TO THE DEFAULT CAR",
                            desc = "your seat's standard " .. string.lower(className(arch)) }
    end
    rows[#rows + 1] = { rkind = "done", id = "done", name = "DONE", sub = "SAVED - YOUR CAR IN THE NEXT RACE",
                        desc = "every change is saved at once" }
    return rows
end

---------------------------------------------------------------------------------------------------- the car
-- FGameplayTag as a struct param / property value
local function tagOf(s) return { TagName = U.fname((type(s) == "string" and s ~= "") and s or "None") } end
M._tagOf = tagOf

local function tagName(t)
    local s = nil
    pcall(function() s = t.TagName:ToString() end)
    if s == nil or s == "None" then return nil end
    return s
end

-- the FCstSavedVehicleRecipeData of his recipe: the model preset's CDO (RecipeName, layout, kit parts, root physics:
-- the same fields the game's own preset upload copies) with his tags. The kit parts go as the CDO's TArray userdata
-- (UE4SS copies a TArray param element by element through the property: a deep copy). -> table or nil, why
function M.recipeTable(eff)
    local pr = eff and eff.preset and V().presetById(eff.arch, eff.preset) or nil
    if not pr then return nil, "no preset for " .. tostring(eff and eff.model) end
    local cls = V().presetClass(pr)
    if not U.ok(cls) then return nil, "preset class " .. tostring(pr.id) .. " not loaded" end
    local cdo = nil
    pcall(function() cdo = cls:GetCDO() end)
    if not U.ok(cdo) then return nil, "no CDO of " .. tostring(pr.id) end
    local t = { VehicleArchetype = eff.arch }
    local ok, err = pcall(function()
        t.RecipeName = cdo.RecipeName:ToString()
        t.UnitLayoutName = cdo.UnitLayoutName
        t.UnitRecipes = cdo.UnitRecipes
    end)
    if not ok then return nil, "CDO read: " .. tostring(err) end
    pcall(function()
        local rp = cdo.RootPhysicsConfiguration
        if U.ok(rp) then t.RootPhysicsConfiguration = rp end
    end)
    -- his tags; a field he did not set keeps the preset CDO's own tag (custdata's copy when unreadable)
    local st = type(eff.stored) == "table" and eff.stored or {}
    t.units = eff.units                                -- his kit parts (applied by the caller: M.apply / garagenative)
    for k, prop in pairs(TAGKEY) do
        local v = st[k]
        if v == nil then
            v = eff[k]
            pcall(function()
                local s = cdo[prop].TagName:ToString()
                if type(s) == "string" then v = (s ~= "None") and s or nil end
            end)
        end
        t[prop] = tagOf(v)
    end
    return t
end

-- the tags his car's recipe actor carries now -> { mask = tag|nil, ... }, its RecipeName, or nil
local function carTags(comp)
    local rec = nil
    pcall(function() rec = comp.VehicleRecipe end)
    if not U.ok(rec) then return nil end
    local out = {}
    for k, prop in pairs(TAGKEY) do
        local t = nil
        pcall(function() t = rec[prop] end)
        out[k] = t and tagName(t) or nil
    end
    pcall(function() out.recipeName = rec.RecipeName:ToString() end)
    pcall(function() out.arch = tonumber(rec.VehicleArchetype) end)
    out.units = M.readUnits((function() local a = nil; pcall(function() a = rec.UnitRecipes end); return a end)())
    return out, rec
end
M._carTags = carTags

-- pure: does the car carry his livery? Only the fields HE set are compared (the others are the preset's, whatever
-- form the game keeps them in).
function M.matches(eff, have)
    if type(have) ~= "table" then return false end
    local st = type(eff.stored) == "table" and eff.stored or {}
    for _, k in ipairs(LIVERY) do
        if st[k] ~= nil and st[k] ~= have[k] then return false end
    end
    return true
end

-- one apply on his PlayerState's customisation component -> ok, how
function M.apply(comp, eff)
    local mode = opt("CouchGarageApply", "upload")
    if mode == "tags" then
        local have, rec = carTags(comp)
        if not have then return false, "no VehicleRecipe actor" end
        for k, prop in pairs(TAGKEY) do
            if eff[k] ~= nil then pcall(function() rec[prop] = tagOf(eff[k]) end) end
        end
        local okR, errR = pcall(function() comp:OnRep_VehicleRecipe() end)
        return okR, okR and "tags + OnRep_VehicleRecipe" or ("OnRep_VehicleRecipe: " .. tostring(errR))
    end
    local t, why = M.recipeTable(eff)
    if not t then return false, why end
    -- his kit parts: patched into the preset CDO's array for this one call, put back right after
    local nParts, undo = 0, {}
    if t.units then nParts, undo = M.patchUnits(t.UnitRecipes, t.units) end
    t.units = nil
    local ok, err = pcall(function() comp:Server_UpdateVehicleRecipe(t) end)
    M.unpatchUnits(undo)
    return ok, ok and ("Server_UpdateVehicleRecipe " .. tostring(t.RecipeName) .. (nParts > 0 and
        string.format(" + %d kit part(s)", nParts) or "")) or ("upload: " .. tostring(err))
end

local function tagShort(s) return s and (s:gsub("^Customisation%.", "")) or "-" end
local function liveryText(eff)
    return string.format("%s mask %s, colours %s, finish %s%s%s", tostring(eff.model), tagShort(eff.mask),
        tagShort(eff.palette), tagShort(eff.patina), eff.decal and (", decal " .. tagShort(eff.decal)) or "",
        eff.units and string.format(", %d kit part(s)", M.partCount(eff.units)) or "")
end
M.liveryText = liveryText

-- RACE: every joined guest with a livery of his own gets it on his car once the car exists (PRERACE / RACING of a
-- couch campaign race; not a time trial: everybody races P1's test vehicle there). Read back each pass: a car the
-- game rebuilt (respawn) gets it again, at most CouchGarageTries uploads per guest and world.
local R = { wk = nil, g = {}, at = 0, tt = nil }
local SETTLED = { ok = true, plain = true, gaveup = true }
function M.raceTick()
    if opt("CouchGarage", true) == false or opt("CouchGarageApply", "upload") == "off" then return end
    if St.phase ~= "PRERACE" and St.phase ~= "RACING" then return end
    local now = St.nowMs()
    if now - R.at < 400 then return end
    R.at = now
    local okC, on = pcall(function() return U.mod("couch").active() end)
    if not (okC and on == true) then return end
    if R.wk ~= St.worldGen then R.wk, R.g, R.tt = St.worldGen, {}, nil end
    -- race fast path (couch-racefast): the node's activity does not change inside a race world; isTimeTrial walks the
    -- whole run map (every node's flags) - asked once per world
    if R.tt == nil then
        local okT, tt = pcall(function() return U.mod("couch").isTimeTrial() end)
        R.tt = okT and tt == true
    end
    if R.tt then return end
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    local maxTries = math.max(1, math.floor(tonumber(opt("CouchGarageTries", 3)) or 3))
    for _, e in ipairs(list) do
        local g = R.g[e.ctrlId]
        if not g then g = { tries = 0, last = -1e12, state = nil }; R.g[e.ctrlId] = g end
        U.try(TAG, function()
            local ps, pawn, comp = nil, nil, nil
            pcall(function() ps = e.pc.PlayerState end)
            if not U.ok(ps) then return end
            pcall(function() pawn = ps.PawnPrivate end)
            if not U.ok(pawn) then return end                 -- not spawned yet: next pass
            pcall(function() comp = ps.VehicleCustomisationComponent end)
            if not U.ok(comp) then return end
            -- settled (his livery on, no livery of his own, gave up) on THIS car: only a rebuilt car (a new pawn or a
            -- new recipe actor: respawn, the game's own upload) is read back again (couch-racefast: the full read-back
            -- was ~20 reads + a map walk per guest every 400 ms for the whole race)
            local rk = nil
            pcall(function() rk = U.key(comp.VehicleRecipe) end)
            local sig = tostring(U.key(pawn)) .. "/" .. tostring(rk)
            if SETTLED[g.state] and g.sig == sig then return end
            g.sig = sig
            local have = carTags(comp)
            if not have then return end                       -- the game's own upload has not run yet
            local arch = have.arch
            if not M.supported(arch) then return end
            local eff = e.seat and M.effectiveSeat(e.seat, arch, e.pnum) or M.effective(e.pnum, arch)
            if not eff.custom then
                if g.state ~= "plain" then
                    g.state = "plain"
                    U.dbg(TAG, "P%d: no livery of his own for %s (the grid preset)", e.pnum, className(arch))
                end
                return
            end
            -- his kit parts: compared when the car's recipe actor shows its units, else trusted after one upload
            local pm = M.partsMatch(eff, have.units)
            if M.matches(eff, have) and (pm == true or (pm == nil and g.tries > 0)) then
                if g.state ~= "ok" then
                    g.state = "ok"
                    U.log(TAG, "P%d's car carries his livery (%s) [%s]", e.pnum, liveryText(eff), St.phase)
                end
                return
            end
            if g.tries >= maxTries then
                if g.state ~= "gaveup" then
                    g.state = "gaveup"
                    U.warn(TAG, "P%d's livery not on his car after %d upload(s): car has mask %s colours %s finish %s",
                        e.pnum, g.tries, tagShort(have.mask), tagShort(have.palette), tagShort(have.patina))
                end
                return
            end
            if now - g.last < 1500 then return end
            g.last, g.tries = now, g.tries + 1
            local ok, how = M.apply(comp, eff)
            g.state = ok and "sent" or "failed"
            local fn = ok and U.log or U.warn
            fn(TAG, "P%d livery %s (try %d): %s - %s", e.pnum, ok and "applied" or "NOT applied", g.tries, liveryText(eff),
                tostring(how))
        end)
    end
end

function M.status()
    loadState()
    local t = {}
    for seat, s in pairs(F.seats) do
        for arch, e in pairs(s) do
            t[#t + 1] = string.format("seat %s/%s: %s", tostring(seat), tostring(arch), liveryText(effectiveOf(e, tonumber(arch), seat)))
        end
    end
    table.sort(t)
    return "garage: " .. (#t > 0 and table.concat(t, "; ") or "no guest recipe stored")
end

function M.init()
    St.on("world", TAG, function() R.wk, R.g = nil, {} end)
end

return M
