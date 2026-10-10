-- SWGRCouch · perks.lua (0.10.0, G4 Players & launch): the loadout logic of the RACE SETUP step "RACERS", stage PERKS
-- - kits, quick-change (L/R), pickers (A), detail data, validation, the LastRaceRacers code and the totals. Pure: no
-- UObject, no util, no UE4SS global; requires only config and perkdata, so work/tests/perks_test.lua runs it in plain
-- Lua 5.4. racers.lua owns the per-player state and calls these functions with its own loadout tables; perkapply.lua
-- writes a loadout into the game at the launch.
-- Design: notes/design/vehicle-step-v2.md §2.5 (L/R and pickers), §4.3-§4.5 (catalog, kits, loadout model), §5.4
-- (API) and the review corrections RC-2 (system-dependent items) and RC-4 (the energy cost comes from perkapply).
--
-- Loadout lo = {v = 1, kit = "pilot" | "max" | "tier1".."tier6" | "s_<StyleKey>" | "custom", from = kit | nil,
--   style = perkdata STYLES key, tune = {[0..5] = 0..10} (EVehiclePartSlot), ab = {4 ids | false} (slots 1..4 = d-pad
--   Up, Left, Down, Right), crash = id | false, parts = {PerkPartSlots ids | false}, traits = {PerkTraitSlots ids |
--   false}}. Ids: abilities = BP_Ability_<id>_C suffixes, parts = affix asset names, traits = TRT_ names.
-- Ownership: fromKit / default / validate / decode / copy return NEW tables (never perkdata's own lists); cycle and
-- equip change the given lo in place and return it. Every texture path returned here is a full object path (M.tex).
-- Board slots (M.slots, the cursor's reading order): kit, ab1 (Up), ab2 (Left), crash (centre), ab4 (Right), ab3
-- (Down), part1..partN, tun0..tun5, style, trait1..traitN.
-- Systems (RC-2): an item with needs = "ramjet" | "critmalf" does nothing on a car without that system. M.systems(arch)
-- gives the class's flags: perkapply.systems() reads them from the class's launch base at step entry and hands them
-- over (M.setSystems); until then the config and the decoded bases apply (speeders: both on, pods: both off, then
-- PerkRamjet / PerkCritMalfunctions / PerkPodRamjet). With cfg.PerkHideInert (default) such items are hidden in the
-- pickers and in L/R, dropped by validate (note "NO RAMJET ON PODS") and refilled in a kit from the AFTERBURNER kit;
-- false keeps them, flagged inert (dimmed) with a NO RAMJET / NO CRITICAL MALFUNCTIONS tag.
-- Uniqueness: an ability family in one d-pad slot (cfg.PerkUniqueFamily), a part family in one part slot, a trait in
-- one trait slot. A picker equip of something another slot holds swaps the two slots (toast "SWAPPED WITH ...").
local cfg = require("config")
local D   = require("perkdata")

local M = {}

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local floor = math.floor

local LEVEL_MAX = D.LEVEL_MAX or 10
local SPEEDER_FALLBACK = "Cooling"      -- SHADE's style: last resort for an unknown style key
local REFILL_KIT = "Afterburner"        -- RC-2: its parts / traits refill the slots a missing system emptied
local SLOT_NAME = { kit = "LOADOUT", ab1 = "D-PAD UP", ab2 = "D-PAD LEFT", ab3 = "D-PAD DOWN", ab4 = "D-PAD RIGHT",
                    crash = "CRASH", style = "RACER STYLE" }
local ROMAN = { "I", "II", "III", "IV", "V", "VI" }
local SYS_NAME = { ramjet = "RAMJET", critmalf = "CRITICAL MALFUNCTION" }
local NO_SYS = { ramjet = "NO RAMJET", critmalf = "NO CRITICAL MALFUNCTIONS" }
-- Parts that change the Energy total (perks-loadout.md §2.3): Plug-F Power Cell "+13 Energy", Dud Battery "-2 total
-- Energy"; Volatile Battery's "+4 Energy, lost on Crash" is a note only.
local ENERGY_PARTS = {
    AFXCustom_LotsOfBattery = { 13, "PLUG-F +13" },
    AFX_Faulty_Ability_OneLessTotalEnergy = { -2, "DUD BATTERY -2" },
    AFX_Ability_MoreTotalEnergyUntilCrash = { 0, "+4 UNTIL A CRASH" },
}

---------------------------------------------------------------------------------------------------- indexes
local FAM, FAM_INDEX = {}, {}           -- ability family key -> D.FAMILIES entry / picker index
for i, f in ipairs(D.FAMILIES) do FAM[f.key], FAM_INDEX[f.key] = f, i end
local CAT, CAT_INDEX = {}, {}           -- part category key -> D.PART_CATS entry / index
for i, c in ipairs(D.PART_CATS) do CAT[c.key], CAT_INDEX[c.key] = c, i end
local GROUP_TRAITS = {}                 -- trait group key -> ids in D.TRAIT_ORDER order
for _, id in ipairs(D.TRAIT_ORDER) do
    local t = D.TRAITS[id]
    if t then
        GROUP_TRAITS[t.group] = GROUP_TRAITS[t.group] or {}
        GROUP_TRAITS[t.group][#GROUP_TRAITS[t.group] + 1] = id
    end
end
local GROUP_INDEX = {}
for i, g in ipairs(D.TRAIT_GROUPS) do GROUP_INDEX[g.key] = i end
local IS_SPEEDER, IS_POD = {}, {}       -- STYLES keys by kind
for _, k in ipairs(D.STYLE_ORDER.speeder) do IS_SPEEDER[k] = true end
for _, k in ipairs(D.STYLE_ORDER.pod) do IS_POD[k] = true end
local IS_TIER = {}
for _, k in ipairs(D.TIERS) do IS_TIER[k] = true end

---------------------------------------------------------------------------------------------------- config
local function clampCount(name, default, lo, hi)
    local n = floor(tonumber(opt(name, default)) or default)
    if n < lo then return lo elseif n > hi then return hi end
    return n
end
function M.partSlots() return clampCount("PerkPartSlots", 6, 1, 10) end
function M.traitSlots() return clampCount("PerkTraitSlots", 3, 1, 4) end
local function flawsOn() return opt("PerkFlaws", true) ~= false end
local function uniqueFamily() return opt("PerkUniqueFamily", true) ~= false end
local function hideInert() return opt("PerkHideInert", true) ~= false end

---------------------------------------------------------------------------------------------------- textures
-- perkdata's relative texture path -> full object path ("Icons/X/T_UI_Y" -> D.TEX .. "Icons/X/T_UI_Y.T_UI_Y"); a full
-- path passes, anything else is nil.
local texCache = {}
function M.tex(rel)
    if type(rel) ~= "string" or rel == "" then return nil end
    local p = texCache[rel]
    if p then return p end
    if string.sub(rel, 1, 1) == "/" then
        p = rel
    else
        p = D.TEX .. rel .. "." .. (string.match(rel, "([^/]+)$") or rel)
    end
    texCache[rel] = p
    return p
end

---------------------------------------------------------------------------------------------------- systems (RC-2)
local sysKnown = {}                     -- [arch] = {ramjet, critmalf}: the launch base's flags (perkapply.systems)

local function defaultSystems(arch)
    local crit = opt("PerkCritMalfunctions", "keep")
    if arch == 1 then                   -- VBD_000_1Mastiff_Plane decodes ramjet = false, critMalf = false
        return { ramjet = opt("PerkPodRamjet", false) == true, critmalf = crit == "on" }
    end
    return { ramjet = opt("PerkRamjet", "keep") ~= "off", critmalf = crit ~= "off" }
end

-- {ramjet = bool, critmalf = bool} of a class (read only).
function M.systems(arch)
    arch = tonumber(arch)
    return sysKnown[arch] or defaultSystems(arch)
end

-- perkapply.systems() hands the flags of the class's launch base over (nil sys = back to the defaults).
function M.setSystems(arch, sys)
    arch = tonumber(arch)
    if arch == nil then return end
    if type(sys) ~= "table" then sysKnown[arch] = nil; return end
    sysKnown[arch] = { ramjet = sys.ramjet ~= false, critmalf = sys.critmalf ~= false }
end

local function inertIn(item, sys) return item ~= nil and item.needs ~= nil and sys[item.needs] == false end
local function hiddenIn(item, sys) return inertIn(item, sys) and hideInert() end
local function partlyOff(item, sys) return item ~= nil and item.partly ~= nil and sys[item.partly] == false end

local function noSystemNote(need, arch)
    if need == "ramjet" then return arch == 1 and "NO RAMJET ON PODS" or "NO RAMJET ON THIS CAR" end
    return NO_SYS[need] or "NOT ON THIS CAR"
end

---------------------------------------------------------------------------------------------------- item checks
local function abilityOk(id, sys, crash)
    local a = type(id) == "string" and D.ABILITIES[id] or nil
    if not a then return false, "unknown" end
    if (a.crash == true) ~= (crash == true) then return false, "slot" end
    if hiddenIn(a, sys) then return false, a.needs end
    return true
end

local function partOk(id, arch, sys)
    local p = type(id) == "string" and D.PARTS[id] or nil
    if not p then return false, "unknown" end
    local c = CAT[p.cat]
    if (p.planeOnly or (c and c.podOnly)) and arch ~= 1 then return false, "pods" end
    if c and c.flaws and not flawsOn() then return false, "flaws" end
    if hiddenIn(p, sys) then return false, p.needs end
    return true
end

local function traitOk(id, sys)
    local t = type(id) == "string" and D.TRAITS[id] or nil
    if not t then return false, "unknown" end
    if hiddenIn(t, sys) then return false, t.needs end
    return true
end

local function styleOk(key, arch)
    return IS_SPEEDER[key] == true or (IS_POD[key] == true and arch == 1)
end

-- Same part, or another tier of the same ladder.
local function samePart(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local pa, pb = D.PARTS[a], D.PARTS[b]
    return pa ~= nil and pb ~= nil and pa.fam ~= nil and pa.fam == pb.fam
end

local function why2note(why, arch)
    if why == "ramjet" or why == "critmalf" then return noSystemNote(why, arch) end
    if why == "pods" then return "POD PART ON A SPEEDER" end
    if why == "flaws" then return "FLAWS ARE OFF" end
    if why == "slot" then return "CRASH ABILITY IN THE WRONG SLOT" end
    return "UNKNOWN ITEM DROPPED"
end

---------------------------------------------------------------------------------------------------- styles and kits
-- A speeder style key for any style key (a pod style's base kit; SHADE's style as the last resort).
local function speederStyleOf(key)
    if IS_SPEEDER[key] then return key end
    local s = D.STYLES[key]
    if s and IS_SPEEDER[s.base] then return s.base end
    return SPEEDER_FALLBACK
end

-- The pilot's own style / kit key for a class: pod styles only on pods (arch nil = no class gating).
local function ownStyle(pilotStyle, arch)
    local k = type(pilotStyle) == "string" and D.KITS[pilotStyle] or nil
    if k and k.kind ~= "tier" and (arch == nil or arch == 1 or not IS_POD[pilotStyle]) then return pilotStyle end
    return speederStyleOf(pilotStyle)
end

-- STYLES / KITS key behind a kit key (nil for tier kits, "custom" and unknown keys).
local function kitStyle(key, pilotStyle, arch)
    if key == "pilot" or key == "max" then return ownStyle(pilotStyle, arch) end
    local s = type(key) == "string" and string.match(key, "^s_(.+)$") or nil
    if s and D.KITS[s] and D.KITS[s].kind ~= "tier" then return s end
    return nil
end

local function kitValid(key, arch)
    if key == "pilot" or key == "max" or key == "custom" or IS_TIER[key] then return true end
    local s = type(key) == "string" and string.match(key, "^s_(.+)$") or nil
    return s ~= nil and D.KITS[s] ~= nil and D.KITS[s].kind ~= "tier" and styleOk(s, arch)
end

-- Kit row order (§4.4): pilot, max, tier1..tier6, then the other style kits (s_<Key>): speeders the speeder styles in
-- table order without the pilot's own; pods the other pod kits, then the speeder style kits.
function M.kits(arch, pilotStyle)
    arch = tonumber(arch)
    local own = ownStyle(pilotStyle, arch)
    local out = { "pilot", "max" }
    for _, t in ipairs(D.TIERS) do out[#out + 1] = t end
    if arch == 1 then
        for _, k in ipairs(D.STYLE_ORDER.pod) do if k ~= own then out[#out + 1] = "s_" .. k end end
    end
    for _, k in ipairs(D.STYLE_ORDER.speeder) do if k ~= own then out[#out + 1] = "s_" .. k end end
    return out
end

-- Kit name without " KIT": REDLINER, MAX POWER · REDLINER, TIER 3 · HUSKY, TECH EXPERT; "CUSTOM" for anything else.
local function kitName(key, pilotStyle, arch)
    local s = kitStyle(key, pilotStyle, arch)
    if key == "max" and s then return "MAX POWER · " .. D.KITS[s].label end
    if s then return D.KITS[s].label end
    if IS_TIER[key] then return D.KITS[key].label end
    return "CUSTOM"
end

-- "REDLINER KIT" | "MAX POWER · REDLINER" | "TIER 3 · HUSKY" | "TECH EXPERT KIT" | "CUSTOM". arch: optional (pod
-- styles are not gated without it).
function M.kitLabel(key, pilotStyle, arch)
    arch = tonumber(arch)
    local name = kitName(key, pilotStyle, arch)
    if key == "max" or IS_TIER[key] or name == "CUSTOM" then return name end
    return name .. " KIT"
end

-- [extension] The KIT row: "LOADOUT: REDLINER KIT" | "LOADOUT: CUSTOM · FROM REDLINER" (§2.5).
function M.kitRow(lo, pilotStyle, arch)
    if type(lo) ~= "table" then return "LOADOUT" end
    if lo.kit == "custom" then
        if lo.from ~= nil and lo.from ~= "custom" and kitName(lo.from, pilotStyle, arch) ~= "CUSTOM" then
            return "LOADOUT: CUSTOM · FROM " .. kitName(lo.from, pilotStyle, arch)
        end
        return "LOADOUT: CUSTOM"
    end
    return "LOADOUT: " .. M.kitLabel(lo.kit, pilotStyle, arch)
end

---------------------------------------------------------------------------------------------------- tables
local function listOf(src, n)           -- n entries: src's string ids, false elsewhere
    local t = {}
    for i = 1, n do
        local v = type(src) == "table" and src[i] or nil
        t[i] = (type(v) == "string" and v ~= "") and v or false
    end
    return t
end

local function tuneOf(src)
    local t = {}
    for s = 0, 5 do t[s] = floor(tonumber(type(src) == "table" and src[s] or nil) or 0) end
    return t
end

-- Deep copy of a loadout (the documented fields only).
function M.copy(lo)
    if type(lo) ~= "table" then return nil end
    local function arr(src)
        local t = {}
        if type(src) == "table" then for i = 1, #src do t[i] = src[i] end end
        return t
    end
    local tune = {}
    for s = 0, 5 do tune[s] = type(lo.tune) == "table" and lo.tune[s] or 0 end
    return { v = lo.v or 1, kit = lo.kit, from = lo.from, style = lo.style, tune = tune, ab = arr(lo.ab),
             crash = lo.crash, parts = arr(lo.parts), traits = arr(lo.traits) }
end

-- [extension] Two loadouts are the same (every documented field).
function M.equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if a.kit ~= b.kit or a.from ~= b.from or a.style ~= b.style or (a.crash or false) ~= (b.crash or false) then
        return false
    end
    for s = 0, 5 do
        if (type(a.tune) == "table" and a.tune[s]) ~= (type(b.tune) == "table" and b.tune[s]) then return false end
    end
    for _, f in ipairs({ "ab", "parts", "traits" }) do
        local x, y = a[f], b[f]
        if type(x) ~= "table" or type(y) ~= "table" or #x ~= #y then return false end
        for i = 1, #x do if (x[i] or false) ~= (y[i] or false) then return false end end
    end
    return true
end

-- Replace every field of dst by src's (cycle / equip of a kit keep the caller's table).
local function assign(dst, src)
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src) do dst[k] = v end
    return dst
end

local function blankLo(arch, pilotStyle)
    return { v = 1, kit = "custom", from = nil, style = ownStyle(pilotStyle, arch), tune = tuneOf(nil),
             ab = listOf(nil, 4), crash = false, parts = listOf(nil, M.partSlots()),
             traits = listOf(nil, M.traitSlots()) }
end

---------------------------------------------------------------------------------------------------- validate
-- -> a new valid loadout, notes (list of toast-ready strings, possibly empty). Never throws: an unusable input
-- becomes the pilot's style kit, an internal error an empty custom loadout.
local function validateNow(lo, arch, pilotStyle)
    local notes, seenNote = {}, {}
    local function note(s) if s and not seenNote[s] then seenNote[s] = true; notes[#notes + 1] = s end end
    if type(lo) ~= "table" then
        local d = M.fromKit("pilot", arch, pilotStyle)
        return d, { "LOADOUT RESET" }
    end
    local sys = M.systems(arch)
    -- levels: 0..10 per part (a 1-based list of 6 is accepted as well)
    local src = type(lo.tune) == "table" and lo.tune or {}
    if src[0] == nil and src[6] ~= nil then
        local shifted = {}
        for s = 0, 5 do shifted[s] = src[s + 1] end
        src = shifted
    end
    local tune = {}
    for s = 0, 5 do
        local n = tonumber(src[s]) or 0
        if n ~= n then n = 0 end
        n = floor(n)
        if n < 0 then n = 0; note("LEVELS CLAMPED") elseif n > LEVEL_MAX then n = LEVEL_MAX; note("LEVELS CLAMPED") end
        tune[s] = n
    end
    -- style: a pod style on a speeder class becomes the pilot's speeder style (the pod style's base without a pilot)
    local style = lo.style
    if not D.STYLES[style] then
        if style ~= nil then note("UNKNOWN STYLE") end
        style = ownStyle(pilotStyle, arch)
    elseif not styleOk(style, arch) then
        note("POD STYLE ON A SPEEDER")
        style = (type(pilotStyle) == "string" and D.KITS[pilotStyle]) and ownStyle(pilotStyle, arch)
            or speederStyleOf(style)
    end
    -- abilities: d-pad slots hold no crash ability; one slot per family (PerkUniqueFamily, later slots dropped)
    local ab, fams = {}, {}
    local abSrc = type(lo.ab) == "table" and lo.ab or {}
    for i = 1, 4 do
        local id = abSrc[i]
        if id == nil or id == false then
            id = false
        else
            local okA, why = abilityOk(id, sys, false)
            if not okA then
                note(why2note(why, arch)); id = false
            elseif uniqueFamily() and fams[D.ABILITIES[id].fam] then
                note("ABILITY FAMILY TWICE"); id = false
            else
                fams[D.ABILITIES[id].fam] = true
            end
        end
        ab[i] = id
    end
    -- crash slot: crash abilities only
    local crash = lo.crash
    if crash == nil or crash == false then
        crash = false
    else
        local okC, why = abilityOk(crash, sys, true)
        if not okC then note(why2note(why, arch)); crash = false end
    end
    -- parts: class, flaws, systems; one per ladder / id (later slots dropped); padded / truncated to PerkPartSlots
    local nP = M.partSlots()
    local pSrc = type(lo.parts) == "table" and lo.parts or {}
    local parts = {}
    for i = 1, nP do
        local id = pSrc[i]
        if id == nil or id == false then
            id = false
        else
            local okP, why = partOk(id, arch, sys)
            if not okP then
                note(why2note(why, arch)); id = false
            else
                for j = 1, i - 1 do
                    if samePart(parts[j], id) then note("PART TWICE"); id = false; break end
                end
            end
        end
        parts[i] = id
    end
    for k, v in pairs(pSrc) do
        if math.type(k) == "integer" and k > nP and type(v) == "string" then note("TOO MANY PARTS") end
    end
    -- traits: rule traits only, no duplicates; padded / truncated to PerkTraitSlots
    local nT = M.traitSlots()
    local tSrc = type(lo.traits) == "table" and lo.traits or {}
    local traits = {}
    for i = 1, nT do
        local id = tSrc[i]
        if id == nil or id == false then
            id = false
        else
            local okT, why = traitOk(id, sys)
            if not okT then
                note(why2note(why, arch)); id = false
            else
                for j = 1, i - 1 do
                    if traits[j] == id then note("TRAIT TWICE"); id = false; break end
                end
            end
        end
        traits[i] = id
    end
    for k, v in pairs(tSrc) do
        if math.type(k) == "integer" and k > nT and type(v) == "string" then note("TOO MANY TRAITS") end
    end
    -- kit: unknown -> custom; anything fixed above -> custom (from = the kit it was)
    local kit, from = lo.kit, lo.from
    if not kitValid(kit, arch) then
        if kit ~= nil then note("UNKNOWN KIT") end
        kit = "custom"
    end
    if kit == "custom" then
        if from == "custom" or not kitValid(from, arch) then from = nil end
    else
        from = nil
        if #notes > 0 then from, kit = kit, "custom" end
    end
    return { v = 1, kit = kit, from = from, style = style, tune = tune, ab = ab, crash = crash, parts = parts,
             traits = traits }, notes
end

function M.validate(lo, arch, pilotStyle)
    arch = tonumber(arch)
    local ok, out, notes = pcall(validateNow, lo, arch, pilotStyle)
    if ok and type(out) == "table" then return out, notes or {} end
    return blankLo(arch, pilotStyle), { "LOADOUT RESET" }
end

---------------------------------------------------------------------------------------------------- kits
-- RC-2: the items of `list` whose system the car lacks are removed; their slots get, in order, the source kit's items
-- that fit and are not in the list yet (parts: not the same ladder either). -> number removed.
local function refillInert(list, source, getItem, fits, same, notes, arch, sys)
    local emptied = {}
    for i = 1, #list do
        local item = list[i] and getItem(list[i]) or nil
        if inertIn(item, sys) then
            list[i] = false
            emptied[#emptied + 1] = i
            local n = noSystemNote(item.needs, arch)
            local dup = false
            for _, x in ipairs(notes) do if x == n then dup = true end end
            if not dup then notes[#notes + 1] = n end
        end
    end
    local k = 1
    for _, i in ipairs(emptied) do
        while k <= #source do
            local cand = source[k]
            k = k + 1
            local taken = false
            for j = 1, #list do if same(list[j], cand) then taken = true; break end end
            if not taken and fits(cand) then list[i] = cand; break end
        end
    end
    return #emptied
end

-- A fresh loadout from a kit (§4.4): "pilot" (the pilot's style kit), "max" (it at level 10), "tier1".."tier6" (the
-- quick-race builds: levels, abilities and crash; no parts; style and traits of prev), "s_<Key>" (another style or pod
-- kit). "custom" / unknown keys keep prev (validated) or give the pilot kit. -> lo, notes (RC-2 refills).
function M.fromKit(key, arch, pilotStyle, prev)
    arch = tonumber(arch)
    local sys = M.systems(arch)
    local own = ownStyle(pilotStyle, arch)
    local skey = kitStyle(key, pilotStyle, arch)
    local kit = skey and D.KITS[skey] or (IS_TIER[key] and D.KITS[key]) or nil
    if not kit then
        if type(prev) == "table" then return M.validate(prev, arch, pilotStyle) end
        key, skey, kit = "pilot", own, D.KITS[own]
    end
    local lo = { v = 1, kit = key, from = nil, tune = tuneOf(kit.tune), ab = listOf(kit.ab, 4),
                 crash = (type(kit.crash) == "string") and kit.crash or false, parts = listOf(kit.parts, M.partSlots()) }
    if key == "max" then for s = 0, 5 do lo.tune[s] = LEVEL_MAX end end
    local p = type(prev) == "table" and prev or nil
    if kit.kind == "tier" then
        lo.style = (p and D.STYLES[p.style]) and p.style or own
        lo.traits = listOf(p and p.traits or D.STYLES[lo.style].traits, M.traitSlots())
    else
        lo.style = kit.style or skey
        lo.traits = listOf(kit.traits, M.traitSlots())
    end
    local notes = {}
    if hideInert() then
        for i = 1, 4 do
            if lo.ab[i] and inertIn(D.ABILITIES[lo.ab[i]], sys) then lo.ab[i] = false end
        end
        local rk = D.KITS[REFILL_KIT]
        refillInert(lo.parts, rk.parts, function(id) return D.PARTS[id] end,
            function(id) return (partOk(id, arch, sys)) end, samePart, notes, arch, sys)
        refillInert(lo.traits, rk.traits, function(id) return D.TRAITS[id] end,
            function(id) return (traitOk(id, sys)) end, function(a, b) return a ~= false and a == b end, notes, arch,
            sys)
    end
    local out, vnotes = M.validate(lo, arch, pilotStyle)
    for _, n in ipairs(vnotes) do notes[#notes + 1] = n end
    return out, notes
end

-- The pilot's style kit (§2.4 default loadout).
function M.default(pilotStyle, arch)
    return (M.fromKit("pilot", arch, pilotStyle))
end

---------------------------------------------------------------------------------------------------- slots
-- Board slots in the cursor's reading order (§2.1).
function M.slots(arch)
    local out = { "kit", "ab1", "ab2", "crash", "ab4", "ab3" }
    for i = 1, M.partSlots() do out[#out + 1] = "part" .. i end
    for s = 0, 5 do out[#out + 1] = "tun" .. s end
    out[#out + 1] = "style"
    for i = 1, M.traitSlots() do out[#out + 1] = "trait" .. i end
    return out
end

-- [extension] "kit" | "ab" | "crash" | "part" | "tune" | "style" | "trait", index (ab 1..4, part / trait 1..n, tune
-- 0..5); nil for an unknown slot.
function M.slotKind(slot)
    if slot == "kit" or slot == "crash" or slot == "style" then return slot, nil end
    local k, n = string.match(tostring(slot), "^(%a+)(%d+)$")
    n = tonumber(n)
    if n == nil then return nil, nil end
    if k == "ab" and n >= 1 and n <= 4 then return "ab", n end
    if k == "part" and n >= 1 then return "part", n end
    if k == "tun" and n >= 0 and n <= 5 then return "tune", n end
    if k == "trait" and n >= 1 then return "trait", n end
    return nil, nil
end

-- [extension] Short name of a slot: D-PAD UP, CRASH, PART 3, CORNERING / DRIFT, RACER STYLE, TRAIT 2, LOADOUT.
function M.slotLabel(slot, arch)
    local kind, n = M.slotKind(slot)
    if kind == "part" then return "PART " .. n end
    if kind == "trait" then return "TRAIT " .. n end
    if kind == "tune" then
        if n == 5 and D.ADVANCED[tonumber(arch)] then return D.ADVANCED[tonumber(arch)] end
        return D.STATS[n].name
    end
    return SLOT_NAME[slot] or tostring(slot)
end

-- [extension] What L/R does on a slot (the hint line, §2.9): "kit" | "level" | "tier" (a laddered part) | "change";
-- nil = nothing (a single part or an empty part slot: the hint hides L/R).
function M.lrMode(lo, slot)
    local kind, n = M.slotKind(slot)
    if kind == "kit" then return "kit" end
    if kind == "tune" then return "level" end
    if kind == "part" then
        local p = type(lo) == "table" and type(lo.parts) == "table" and D.PARTS[lo.parts[n]] or nil
        if p and p.fam and #D.PART_FAMILIES[p.fam].tiers > 1 then return "tier" end
        return nil
    end
    if kind then return "change" end
    return nil
end

local function markCustom(lo)
    if lo.kit ~= "custom" then lo.from, lo.kit = lo.kit, "custom" end
end

local function usedElsewhereAb(lo, i, fam)        -- the other d-pad slot holding this ability family, or nil
    for j = 1, 4 do
        if j ~= i then
            local a = D.ABILITIES[lo.ab[j]]
            if a and a.fam == fam then return j end
        end
    end
    return nil
end

local function styleList(arch)
    local out = {}
    if arch == 1 then for _, k in ipairs(D.STYLE_ORDER.pod) do out[#out + 1] = k end end
    for _, k in ipairs(D.STYLE_ORDER.speeder) do out[#out + 1] = k end
    return out
end

-- STYLE row / picker: the style and its three traits (slots after the third keep theirs unless now a duplicate).
-- -> toast "TRAITS FROM <STYLE>" or the RC-2 note when a trait was left out.
local function setStyle(lo, key, arch, sys)
    lo.style = key
    local st = D.STYLES[key]
    local nT = #lo.traits
    local missing = nil
    for i = 1, math.min(3, nT) do
        local id = st.traits[i]
        local okT, why = traitOk(id, sys)
        if okT then lo.traits[i] = id else lo.traits[i] = false; missing = missing or why end
    end
    for i = 4, nT do
        for j = 1, 3 do
            if lo.traits[i] and lo.traits[i] == lo.traits[j] then lo.traits[i] = false end
        end
    end
    if missing == "ramjet" or missing == "critmalf" then return noSystemNote(missing, arch) end
    return "TRAITS FROM " .. st.name
end

-- Position of v in list (nil when absent).
local function indexOf(list, v)
    for i = 1, #list do if list[i] == v then return i end end
    return nil
end

-- Next / previous entry of a wrapping list from cur; a cur not in the list starts before the first / after the last.
local function stepList(list, cur, d)
    local n = #list
    if n == 0 then return nil end
    local i = indexOf(list, cur)
    if not i then i = d > 0 and 0 or (n + 1) end
    return list[((i - 1 + d) % n) + 1]
end

-- An ability slot emptied by L/R remembers its family, so the next L/R steps back into it (weak keys: per loadout).
local lastFam = setmetatable({}, { __mode = "k" })
local function rememberFam(lo, i, fam)
    if not fam then return end
    lastFam[lo] = lastFam[lo] or {}
    lastFam[lo][i] = fam
end

local function slotFamily(lo, i)                  -- the family an ability slot cycles / opens its picker on
    local a = D.ABILITIES[lo.ab[i]]
    if a then return a.fam end
    local mem = lastFam[lo] and lastFam[lo][i]
    if mem and FAM[mem] and not (uniqueFamily() and usedElsewhereAb(lo, i, mem)) then return mem end
    for _, f in ipairs(D.FAMILIES) do
        if not (uniqueFamily() and usedElsewhereAb(lo, i, f.key)) then return f.key end
    end
    return D.FAMILIES[1].key
end

---------------------------------------------------------------------------------------------------- L/R (§2.5)
-- Quick change of the slot under the cursor; dir < 0 = left / previous. Changes lo in place. -> lo, changed, toast.
-- Every change except a KIT change makes the loadout "custom" (from = the kit it came from).
function M.cycle(lo, slot, dir, arch, pilotStyle)
    arch = tonumber(arch)
    if type(lo) ~= "table" then return lo, false, nil end
    local d = (tonumber(dir) or 1) < 0 and -1 or 1
    local sys = M.systems(arch)
    local kind, n = M.slotKind(slot)
    if kind == "kit" then
        -- CUSTOM is skipped: it sits right after the kit it came from (left = that kit again, right = the next one)
        local list = M.kits(arch, pilotStyle)
        local key
        if lo.kit == "custom" then
            local fi = indexOf(list, lo.from)
            if fi then key = list[((fi - 1 + (d < 0 and 0 or 1)) % #list) + 1] else key = stepList(list, nil, d) end
        else
            key = stepList(list, lo.kit, d)
        end
        if not key then return lo, false, nil end
        local new, notes = M.fromKit(key, arch, pilotStyle, lo)
        assign(lo, new)
        return lo, true, notes[1]
    elseif kind == "ab" then
        -- [EMPTY, the family's variants in tree order], wrapping; an empty slot uses its last family or the first free
        local fam = slotFamily(lo, n)
        local list = { false }
        for _, id in ipairs(FAM[fam].order) do
            if abilityOk(id, sys, false) then list[#list + 1] = id end
        end
        local cur = lo.ab[n] or false
        local nxt = stepList(list, cur, d)
        if nxt == nil or nxt == cur then return lo, false, nil end
        lo.ab[n] = nxt
        if nxt == false then rememberFam(lo, n, fam) end
        markCustom(lo)
        return lo, true, nil
    elseif kind == "crash" then
        local list = { false }
        for _, id in ipairs(D.CRASH) do if abilityOk(id, sys, true) then list[#list + 1] = id end end
        local cur = lo.crash or false
        local nxt = stepList(list, cur, d)
        if nxt == nil or nxt == cur then return lo, false, nil end
        lo.crash = nxt
        markCustom(lo)
        return lo, true, nil
    elseif kind == "part" then
        -- a laddered part: tier -1 / +1 (I..IV, clamped); a single part or an empty slot: nothing
        local p = D.PARTS[lo.parts[n]]
        if not (p and p.fam) then return lo, false, nil end
        local tiers = D.PART_FAMILIES[p.fam].tiers
        local t = (indexOf(tiers, p.id) or p.tier or 1) + d
        if t < 1 or t > #tiers or not partOk(tiers[t], arch, sys) then return lo, false, nil end
        lo.parts[n] = tiers[t]
        markCustom(lo)
        return lo, true, nil
    elseif kind == "tune" then
        local cur = floor(tonumber(lo.tune[n]) or 0)
        local lv = cur + d
        if lv < 0 or lv > LEVEL_MAX then return lo, false, nil end
        lo.tune[n] = lv
        markCustom(lo)
        return lo, true, nil
    elseif kind == "style" then
        local key = stepList(styleList(arch), lo.style, d)
        if not key or key == lo.style then return lo, false, nil end
        local toast = setStyle(lo, key, arch, sys)
        markCustom(lo)
        return lo, true, toast
    elseif kind == "trait" then
        -- [EMPTY, every rule trait not in another trait slot], wrapping
        local list = { false }
        for _, id in ipairs(D.TRAIT_ORDER) do
            if traitOk(id, sys) then
                local other = false
                for j = 1, #lo.traits do if j ~= n and lo.traits[j] == id then other = true; break end end
                if not other then list[#list + 1] = id end
            end
        end
        local cur = lo.traits[n] or false
        local nxt = stepList(list, cur, d)
        if nxt == nil or nxt == cur then return lo, false, nil end
        lo.traits[n] = nxt
        markCustom(lo)
        return lo, true, nil
    end
    return lo, false, nil
end

---------------------------------------------------------------------------------------------------- pickers (§2.5)
local function pips(p)                  -- rarity pips of a part tile: COMMON 1 .. LEGENDARY 4 (EXPERIMENTAL 4), flaw 0
    if p.faulty or p.rarity == 4 then return 0 end
    if p.rarity == 5 then return 4 end
    return math.max(1, math.min(4, (tonumber(p.rarity) or 0) + 1))
end

local function pickerCats(kind, arch, sys, lo)
    local cats = {}
    if kind == "ab" then
        for _, f in ipairs(D.FAMILIES) do cats[#cats + 1] = { key = f.key, name = f.name, icon = M.tex(f.icon) } end
    elseif kind == "crash" then
        cats[1] = { key = D.CRASH_FAM.key, name = D.CRASH_FAM.name, icon = M.tex(D.CRASH_FAM.icon) }
    elseif kind == "part" then
        for _, c in ipairs(D.PART_CATS) do
            local okC = not (c.podOnly and arch ~= 1) and not (c.flaws and not flawsOn()) and not hiddenIn(c, sys)
            if okC then cats[#cats + 1] = { key = c.key, name = c.name, icon = M.tex(c.icon) } end
        end
    elseif kind == "style" then
        local st = D.STYLES[lo.style]
        cats[1] = { key = "styles", name = "RACER STYLES", icon = st and M.tex(st.icon) or nil }
    elseif kind == "trait" then
        for _, g in ipairs(D.TRAIT_GROUPS) do cats[#cats + 1] = { key = g.key, name = g.name, icon = M.tex(g.icon) } end
    else
        return nil
    end
    return cats
end

local function catOfCurrent(kind, n, lo, cats)
    local key = nil
    if kind == "ab" then
        key = slotFamily(lo, n)
    elseif kind == "part" then
        local p = D.PARTS[lo.parts[n]]
        key = p and p.cat
    elseif kind == "trait" then
        local t = D.TRAITS[lo.traits[n]]
        key = t and t.group
    end
    for i, c in ipairs(cats) do if c.key == key then return i end end
    return 1
end

-- Rows of one picker category: {id | false, name, icon, iconKind, rarity, pips, lvl, sub, faulty, tiers, equipped,
-- empty, inert, usedBy}. Ability, part and trait lists start with EMPTY (id false), the crash list with NONE.
local function catItems(kind, n, lo, arch, sys, cat)
    local items = {}
    if kind == "ab" or kind == "crash" then
        local cur = (kind == "ab") and (lo.ab[n] or false) or (lo.crash or false)
        items[1] = { id = false, name = (kind == "ab") and "EMPTY" or "NONE", iconKind = "disc", empty = true,
                     equipped = cur == false }
        local ids = (kind == "ab") and FAM[cat.key].order or D.CRASH
        for _, id in ipairs(ids) do
            local a = D.ABILITIES[id]
            if a and abilityOk(id, sys, kind == "crash") then
                local it = { id = id, name = a.name, icon = M.tex(a.icon), sub = M.tex(a.sub), iconKind = "disc",
                             lvl = a.lvl, equipped = cur == id, inert = inertIn(a, sys) or nil }
                if kind == "ab" and uniqueFamily() then it.usedBy = usedElsewhereAb(lo, n, a.fam) end
                items[#items + 1] = it
            end
        end
    elseif kind == "part" then
        local cur = lo.parts[n] or false
        items[1] = { id = false, name = "EMPTY", iconKind = "tile", empty = true, equipped = cur == false }
        for _, id in ipairs(D.PART_LIST[cat.key] or {}) do
            local p = D.PARTS[id]
            if p and partOk(id, arch, sys) then
                local it = { id = id, name = p.name, icon = M.tex(p.icon), iconKind = "tile", rarity = p.rarity,
                             pips = pips(p), faulty = p.faulty == true or nil,
                             tiers = p.fam and #D.PART_FAMILIES[p.fam].tiers or nil, equipped = samePart(cur, id),
                             inert = inertIn(p, sys) or nil }
                for j = 1, #lo.parts do
                    if j ~= n and samePart(lo.parts[j], id) then it.usedBy = j; break end
                end
                items[#items + 1] = it
            end
        end
    elseif kind == "style" then
        for _, key in ipairs(styleList(arch)) do
            local st = D.STYLES[key]
            items[#items + 1] = { id = key, name = st.name, icon = M.tex(st.icon), iconKind = st.pod and "tile" or "glyph",
                                  equipped = lo.style == key }
        end
    elseif kind == "trait" then
        local cur = lo.traits[n] or false
        items[1] = { id = false, name = "EMPTY", iconKind = "glyph", empty = true, equipped = cur == false }
        for _, id in ipairs(GROUP_TRAITS[cat.key] or {}) do
            local t = D.TRAITS[id]
            if traitOk(id, sys) then
                local it = { id = id, name = t.name, icon = M.tex(t.icon), iconKind = "glyph", equipped = cur == id,
                             inert = inertIn(t, sys) or nil }
                for j = 1, #lo.traits do
                    if j ~= n and lo.traits[j] == id then it.usedBy = j; break end
                end
                items[#items + 1] = it
            end
        end
    end
    local sel = 1
    for i, it in ipairs(items) do if it.equipped then sel = i; break end end
    return items, sel
end

-- The picker of a slot, opened on the equipped item's category and row: {slot, kind, cats = {{key, name, icon}},
-- cat = i, items = rows, sel = j}; nil for the KIT and UPGRADE rows (no picker).
function M.picker(lo, slot, arch)
    arch = tonumber(arch)
    if type(lo) ~= "table" then return nil end
    local kind, n = M.slotKind(slot)
    local sys = M.systems(arch)
    local cats = kind and pickerCats(kind, arch, sys, lo) or nil
    if not cats or #cats == 0 then return nil end
    local ci = catOfCurrent(kind, n, lo, cats)
    local items, sel = catItems(kind, n, lo, arch, sys, cats[ci])
    return { slot = slot, kind = kind, cats = cats, cat = ci, items = items, sel = sel }
end

-- Rows of another category (index wraps): items, sel (the equipped row, else 1).
function M.pickerCat(lo, slot, arch, catIndex)
    arch = tonumber(arch)
    if type(lo) ~= "table" then return {}, 1 end
    local kind, n = M.slotKind(slot)
    local sys = M.systems(arch)
    local cats = kind and pickerCats(kind, arch, sys, lo) or nil
    if not cats or #cats == 0 then return {}, 1 end
    local ci = ((floor(tonumber(catIndex) or 1) - 1) % #cats) + 1
    return catItems(kind, n, lo, arch, sys, cats[ci])
end

-- Picker equip (A on an item): changes lo in place. Something another slot holds is swapped with this slot's old
-- content (ability family, part ladder, trait); a ladder already in this slot keeps its tier. id false = empty.
-- -> lo, toast, changed.
function M.equip(lo, slot, id, arch, pilotStyle)
    arch = tonumber(arch)
    if type(lo) ~= "table" then return lo, nil, false end
    local sys = M.systems(arch)
    local kind, n = M.slotKind(slot)
    if id == nil then id = false end
    if kind == "kit" then
        if id == "custom" or not kitValid(id, arch) or id == lo.kit then return lo, nil, false end
        local new, notes = M.fromKit(id, arch, pilotStyle, lo)
        assign(lo, new)
        return lo, notes[1], true
    elseif kind == "ab" then
        if id ~= false and not abilityOk(id, sys, false) then return lo, nil, false end
        local old = lo.ab[n] or false
        if id == old then return lo, nil, false end
        local toast = nil
        if id then
            local j = uniqueFamily() and usedElsewhereAb(lo, n, D.ABILITIES[id].fam) or nil
            if j then lo.ab[j] = old; toast = "SWAPPED WITH SLOT " .. j end
        else
            rememberFam(lo, n, D.ABILITIES[old] and D.ABILITIES[old].fam)
        end
        lo.ab[n] = id
        markCustom(lo)
        return lo, toast, true
    elseif kind == "crash" then
        if id ~= false and not abilityOk(id, sys, true) then return lo, nil, false end
        if id == (lo.crash or false) then return lo, nil, false end
        lo.crash = id
        markCustom(lo)
        return lo, nil, true
    elseif kind == "part" then
        if n > #lo.parts then return lo, nil, false end
        if id ~= false and not partOk(id, arch, sys) then return lo, nil, false end
        local old = lo.parts[n] or false
        if id == old or (id and old and samePart(id, old)) then return lo, nil, false end
        local toast = nil
        if id then
            for j = 1, #lo.parts do
                if j ~= n and samePart(lo.parts[j], id) then lo.parts[j] = old; toast = "SWAPPED WITH PART " .. j end
            end
        end
        lo.parts[n] = id
        markCustom(lo)
        return lo, toast, true
    elseif kind == "trait" then
        if n > #lo.traits then return lo, nil, false end
        if id ~= false and not traitOk(id, sys) then return lo, nil, false end
        local old = lo.traits[n] or false
        if id == old then return lo, nil, false end
        local toast = nil
        if id then
            for j = 1, #lo.traits do
                if j ~= n and lo.traits[j] == id then lo.traits[j] = old; toast = "SWAPPED WITH TRAIT " .. j end
            end
        end
        lo.traits[n] = id
        markCustom(lo)
        return lo, toast, true
    elseif kind == "style" then
        if not (id and D.STYLES[id] and styleOk(id, arch)) or id == lo.style then return lo, nil, false end
        local toast = setStyle(lo, id, arch, sys)
        markCustom(lo)
        return lo, toast, true
    elseif kind == "tune" then
        local lv = tonumber(id)
        if lv == nil then return lo, nil, false end
        lv = math.max(0, math.min(LEVEL_MAX, floor(lv)))
        if lv == lo.tune[n] then return lo, nil, false end
        lo.tune[n] = lv
        markCustom(lo)
        return lo, nil, true
    end
    return lo, nil, false
end

---------------------------------------------------------------------------------------------------- totals
-- PowerLevel = the sum of the six levels (0..60, the power-rating TuneSet).
function M.power(lo)
    local sum = 0
    if type(lo) == "table" and type(lo.tune) == "table" then
        for s = 0, 5 do sum = sum + math.max(0, math.min(LEVEL_MAX, floor(tonumber(lo.tune[s]) or 0))) end
    end
    return math.min(sum, D.POWER_MAX or 60)
end

-- Energy: base 3 + the Power Cell bonus (+ Plug-F +13, Dud Battery -2). -> base, bonus, total, note | nil
-- ("PLUG-F +13 · +4 UNTIL A CRASH"); "ENERGY <base> + <bonus> = <total>" adds up.
function M.energy(lo)
    local base = D.ENERGY_BASE or 3
    local lv = 0
    if type(lo) == "table" and type(lo.tune) == "table" then
        lv = math.max(0, math.min(LEVEL_MAX, floor(tonumber(lo.tune[4]) or 0)))
    end
    local bonus = D.BATTERY[lv] or 0
    local notes = {}
    if type(lo) == "table" and type(lo.parts) == "table" then
        for i = 1, #lo.parts do
            local e = ENERGY_PARTS[lo.parts[i]]
            if e then bonus = bonus + e[1]; notes[#notes + 1] = e[2] end
        end
    end
    local total = math.max(0, base + bonus)
    return base, bonus, total, (#notes > 0) and table.concat(notes, " · ") or nil
end

local function countSet(list)
    local n = 0
    if type(list) == "table" then for i = 1, #list do if list[i] then n = n + 1 end end end
    return n
end

-- {power, energy, nAb, nParts, nTraits, styleName, text} + powerText "POWER 31 / 60", energyText "ENERGY 3 + 9 = 12",
-- totals "POWER 31 / 60 · ENERGY 12" (READY), partsLabel "PARTS 4/6", slots, crash, energyNote.
function M.summary(lo, arch)
    if type(lo) ~= "table" then lo = blankLo(tonumber(arch), nil) end
    local power = M.power(lo)
    local base, bonus, total, note = M.energy(lo)
    local st = D.STYLES[lo.style]
    local nAb, nParts, nTraits = countSet(lo.ab), countSet(lo.parts), countSet(lo.traits)
    local slots = type(lo.parts) == "table" and #lo.parts or 0
    local s = {
        power = power, energy = total, energyBase = base, energyBonus = bonus, energyNote = note,
        nAb = nAb, crash = lo.crash and true or false, nParts = nParts, slots = slots, nTraits = nTraits,
        styleName = st and st.name or "",
        powerText = string.format("POWER %d / %d", power, D.POWER_MAX or 60),
        energyText = string.format("ENERGY %d + %d = %d", base, bonus, total),
        totals = string.format("POWER %d / %d · ENERGY %d", power, D.POWER_MAX or 60, total),
        partsLabel = string.format("PARTS %d/%d", nParts, slots),
    }
    s.text = string.format("%s · %d ABILITIES · %d/%d PARTS · %d TRAITS · %s", s.totals, nAb, nParts, slots, nTraits,
        s.styleName)
    return s
end

---------------------------------------------------------------------------------------------------- detail panel
local function abilityDetail(kind, n, id, sys)
    local where = (kind == "crash") and "CRASH ABILITY" or SLOT_NAME["ab" .. n]
    local a = id and D.ABILITIES[id] or nil
    if not a then
        local title = (kind == "crash") and "NO CRASH ABILITY" or "EMPTY SLOT"
        local text = (kind == "crash") and "No ability fires when the car crashes. Press A to pick an Ion Blast."
            or "Nothing on this d-pad direction. Press A to pick an ability."
        return { kind = kind, id = false, title = title, plain = text, rich = text, icon = M.tex(D.EMPTY_ICON),
                 iconKind = "disc", tag = where .. " · EMPTY" }
    end
    local tag = where .. " · LEVEL " .. tostring(a.lvl)
    if inertIn(a, sys) then tag = tag .. " · " .. NO_SYS[a.needs] end
    if partlyOff(a, sys) then tag = tag .. " · PARTLY " .. SYS_NAME[a.partly] end
    -- costId: racers.lua appends " · COST n" from perkapply.abilityCost(costId) (a game read, RC-4)
    return { kind = kind, id = id, title = a.name, rich = a.rich, plain = a.desc, icon = M.tex(a.icon),
             sub = M.tex(a.sub), iconKind = "disc", large = M.tex(a.large), tag = tag, costId = id }
end

local function partDetail(id, sys)
    local p = id and D.PARTS[id] or nil
    if not p then
        local text = "A free part slot. Press A to fit a part."
        return { kind = "part", id = false, title = "EMPTY PART SLOT", plain = text, rich = text, iconKind = "tile",
                 tag = "PART · EMPTY" }
    end
    local c = CAT[p.cat]
    local bits = { D.RARITY[p.rarity] or "PART" }
    local note = nil
    if p.fam then
        local f = D.PART_FAMILIES[p.fam]
        bits[#bits + 1] = string.format("TIER %s OF %s", ROMAN[p.tier] or tostring(p.tier), ROMAN[#f.tiers] or #f.tiers)
        note = f.ladder
    end
    if p.cat == "pod" then bits[#bits + 1] = "POD TRAIT"
    elseif p.cat == "flaws" then bits[#bits + 1] = "STARTS FAULTY"
    elseif c then bits[#bits + 1] = c.name end
    if inertIn(p, sys) then bits[#bits + 1] = NO_SYS[p.needs] end
    return { kind = "part", id = id, title = p.name, rich = p.rich, plain = p.desc, icon = M.tex(p.icon),
             iconKind = "tile", large = M.tex(p.large), tag = table.concat(bits, " · "), note = note }
end

local function tuneDetail(s, lo, arch, sys)
    local st = D.STATS[s]
    local lv = floor(tonumber(lo.tune[s]) or 0)
    local name, plain, rich = st.name, st.desc, st.rich
    if s == 5 and D.ADVANCED[arch] then
        name, plain, rich = D.ADVANCED[arch], D.ADVANCED_DESC[arch], D.ADVANCED_DESC[arch]
    end
    local tag
    if s == 3 and sys.ramjet == false then
        tag = "NO RAMJET: COUNTS FOR POWER ONLY"
    elseif s == 4 then
        tag = string.format("LEVEL %d OF %d · ENERGY +%d · POWER %d", lv, LEVEL_MAX, D.BATTERY[lv] or 0, M.power(lo))
    else
        tag = string.format("LEVEL %d OF %d · %d OF %d STACKS · POWER %d", lv, LEVEL_MAX, D.STACKS[lv] or 0,
            D.STACKS[LEVEL_MAX] or 13, M.power(lo))
    end
    return { kind = "tune", id = s, title = name, plain = plain, rich = rich, icon = M.tex(st.icon), iconKind = "glyph",
             large = M.tex(st.large), tag = tag, note = st.lv10, level = lv }
end

local function styleDetail(key)
    local st = D.STYLES[key]
    if not st then return { kind = "style", id = false, title = "RACER STYLE", plain = "", rich = "", tag = "" } end
    local names = {}
    for _, t in ipairs(st.traits) do names[#names + 1] = D.TRAITS[t] and D.TRAITS[t].name or t end
    return { kind = "style", id = key, title = st.name, rich = st.rich, plain = st.desc, icon = M.tex(st.icon),
             iconKind = st.pod and "tile" or "glyph", tag = (st.pod and "POD STYLE" or "RACER STYLE") .. " · 3 TRAITS",
             note = table.concat(names, " · ") }
end

local function traitDetail(id, sys)
    local t = id and D.TRAITS[id] or nil
    if not t then
        local text = "A free trait slot. Press A to pick a trait."
        return { kind = "trait", id = false, title = "EMPTY TRAIT SLOT", plain = text, rich = text, iconKind = "glyph",
                 tag = "TRAIT · EMPTY" }
    end
    local bits = { D.TRAIT_GROUPS[GROUP_INDEX[t.group]] and D.TRAIT_GROUPS[GROUP_INDEX[t.group]].name or "TRAIT" }
    if t.requires and D.TRAITS[t.requires] then bits[#bits + 1] = "NEEDS " .. D.TRAITS[t.requires].name end
    if inertIn(t, sys) then bits[#bits + 1] = NO_SYS[t.needs] end
    if partlyOff(t, sys) then bits[#bits + 1] = "PARTLY " .. SYS_NAME[t.partly] end
    return { kind = "trait", id = id, title = t.name, rich = t.rich, plain = t.desc, icon = M.tex(t.icon),
             iconKind = "glyph", tag = table.concat(bits, " · ") }
end

-- Detail panel data of a board slot (itemId nil = what the slot holds) or of a picker row (itemId = the row's id,
-- false = its EMPTY row): {kind, id, title, rich (the game's markup), plain, icon, iconKind ("disc" | "tile" |
-- "glyph"), large, tag, note, costId}. pilotStyle (optional) names the KIT row's "pilot" kit.
function M.detail(slot, lo, arch, itemId, pilotStyle)
    arch = tonumber(arch)
    if type(lo) ~= "table" then lo = blankLo(arch, pilotStyle) end
    local sys = M.systems(arch)
    local kind, n = M.slotKind(slot)
    local id = itemId
    if kind == "ab" then
        if id == nil then id = lo.ab[n] end
        return abilityDetail(kind, n, id or false, sys)
    elseif kind == "crash" then
        if id == nil then id = lo.crash end
        return abilityDetail(kind, nil, id or false, sys)
    elseif kind == "part" then
        if id == nil then id = lo.parts[n] end
        return partDetail(id or false, sys)
    elseif kind == "tune" then
        return tuneDetail(n, lo, arch, sys)
    elseif kind == "style" then
        return styleDetail(id or lo.style)
    elseif kind == "trait" then
        if id == nil then id = lo.traits[n] end
        return traitDetail(id or false, sys)
    elseif kind == "kit" then
        local ps = pilotStyle or lo.style
        local s = M.summary(lo, arch)
        local st = D.STYLES[lo.style]
        local title = (id ~= nil and id ~= lo.kit) and M.kitLabel(id, ps, arch) or M.kitRow(lo, ps, arch)
        local text = string.format("%d abilities, %d of %d parts, %d traits. A: ready. Left / right: another kit.",
            s.nAb, s.nParts, s.slots, s.nTraits)
        return { kind = "kit", id = id or lo.kit, title = title, plain = text, rich = text,
                 icon = st and M.tex(st.icon) or nil, iconKind = (st and st.pod) and "tile" or "glyph", tag = s.totals }
    end
    return { kind = "none", title = "", plain = "", rich = "", tag = "" }
end

---------------------------------------------------------------------------------------------------- board view data
-- [extension] The PERKS board part of the card view model (vehicle-step-v2.md §5.6 vm.perks without cursor / detail /
-- picker): {kitRow, power, energy, partsLabel, ab = {[1..4] = cell, crash = cell}, parts = {[k] = {tile, pips, faulty,
-- empty, inert, id}}, tune = {[0..5] = {icon, name, level, inert}}, style = {icon, name}, traits = {[k] = {icon, name,
-- empty, inert, id}}}; cell = {glyph, sub, lvl, empty, inert, id}. The READY strip can reuse ab / parts / traits.
function M.board(lo, arch, pilotStyle)
    arch = tonumber(arch)
    if type(lo) ~= "table" then lo = blankLo(arch, pilotStyle) end
    local sys = M.systems(arch)
    local s = M.summary(lo, arch)
    local function cell(id)
        local a = id and D.ABILITIES[id] or nil
        if not a then return { empty = true } end
        return { glyph = M.tex(a.icon), sub = M.tex(a.sub), lvl = a.lvl, empty = false, inert = inertIn(a, sys) or nil,
                 id = id }
    end
    local out = { kitRow = M.kitRow(lo, pilotStyle, arch), power = s.powerText, energy = s.energyText,
                  partsLabel = s.partsLabel, ab = {}, parts = {}, tune = {}, traits = {} }
    for i = 1, 4 do out.ab[i] = cell(lo.ab[i]) end
    out.ab.crash = cell(lo.crash)
    for i = 1, #lo.parts do
        local p = lo.parts[i] and D.PARTS[lo.parts[i]] or nil
        if p then
            out.parts[i] = { tile = M.tex(p.icon), pips = pips(p), faulty = p.faulty == true, empty = false,
                             inert = inertIn(p, sys) or nil, id = p.id }
        else
            out.parts[i] = { empty = true }
        end
    end
    for k = 0, 5 do
        local st = D.STATS[k]
        out.tune[k] = { icon = M.tex(st.icon), name = M.slotLabel("tun" .. k, arch),
                        level = floor(tonumber(lo.tune[k]) or 0), inert = (inertIn(st, sys) or nil) }
    end
    local st = D.STYLES[lo.style]
    out.style = { icon = st and M.tex(st.icon) or nil, name = st and st.name or "" }
    for i = 1, #lo.traits do
        local t = lo.traits[i] and D.TRAITS[lo.traits[i]] or nil
        if t then
            out.traits[i] = { icon = M.tex(t.icon), name = t.name, empty = false, inert = inertIn(t, sys) or nil,
                              id = t.id }
        else
            out.traits[i] = { empty = true }
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------- code (§4.5)
-- "v1,k:<kit>,f:<from|->,s:<style>,t:<6 levels>,a:<4 ids>,x:<crash>,p:<parts>,r:<traits>": lists joined by ".",
-- "-" = empty. No ";", "=" or "@" (LastRaceRacers uses them); ids are [%w_] only.
local function idOrDash(v)
    if type(v) == "string" and string.match(v, "^[%w_]+$") then return v end
    return "-"
end

function M.encode(lo)
    if type(lo) ~= "table" then return "" end
    local lv = {}
    for s = 0, 5 do lv[#lv + 1] = tostring(floor(tonumber(type(lo.tune) == "table" and lo.tune[s] or 0) or 0)) end
    local function list(src, n)
        local t = {}
        for i = 1, n do t[i] = idOrDash(type(src) == "table" and src[i] or nil) end
        if #t == 0 then t[1] = "-" end
        return table.concat(t, ".")
    end
    local nP = type(lo.parts) == "table" and #lo.parts or 0
    local nT = type(lo.traits) == "table" and #lo.traits or 0
    return table.concat({ "v1", "k:" .. idOrDash(lo.kit), "f:" .. idOrDash(lo.from), "s:" .. idOrDash(lo.style),
        "t:" .. table.concat(lv, "."), "a:" .. list(lo.ab, 4), "x:" .. idOrDash(lo.crash), "p:" .. list(lo.parts, nP),
        "r:" .. list(lo.traits, nT) }, ",")
end

-- -> lo (validated for the class), notes | nil, why.
function M.decode(s, arch, pilotStyle)
    if type(s) ~= "string" or s == "" then return nil, "empty code" end
    local fields, first = {}, true
    for part in string.gmatch(s, "[^,]+") do
        if first then
            if part ~= "v1" then return nil, "not a v1 loadout code" end
            first = false
        else
            local k, v = string.match(part, "^(%a):(.*)$")
            if not k then return nil, "bad field " .. part end
            fields[k] = v
        end
    end
    if first then return nil, "empty code" end
    for _, k in ipairs({ "k", "s", "t", "a", "x", "p", "r" }) do
        if fields[k] == nil then return nil, "field " .. k .. " missing" end
    end
    local function ids(v)
        local out = {}
        for item in string.gmatch(v .. ".", "([^.]*)%.") do out[#out + 1] = (item ~= "" and item ~= "-") and item or false end
        return out
    end
    local lv = ids(fields.t)
    if #lv ~= 6 then return nil, "6 levels expected" end
    local tune = {}
    for i = 1, 6 do
        local n = tonumber(lv[i])
        if n == nil then return nil, "bad level " .. tostring(lv[i]) end
        tune[i - 1] = n
    end
    local function one(v) return (v ~= nil and v ~= "" and v ~= "-") and v or false end
    local lo = { v = 1, kit = one(fields.k) or "custom", from = one(fields.f) or nil, style = one(fields.s) or nil,
                 tune = tune, ab = ids(fields.a), crash = one(fields.x), parts = ids(fields.p), traits = ids(fields.r) }
    return M.validate(lo, arch, pilotStyle)
end

return M
