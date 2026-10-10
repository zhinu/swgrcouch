-- vehicles.lua (G4 Players & launch) - static catalog of vehicle classes, vehicle presets (the visible model /
-- livery), builds and UI art, plus resolvers that turn catalog entries into game objects. No UI, no state.
-- Design: notes/research/race-setup.md §3 (catalog) and §5 (per-player vehicles).
--
-- Static sources (2026-10-07, cue4cli decode of the Steam paks + runtime JMAP, notes/research/runtime-decoding.md):
--   EVehicleArchetype Car 0, Plane 1, Bike 2, Skimmer 3; ERaceGridEntryType same + PlayerChoice 4.
--   VA_* (UVehicleArchetype): PlayerFacingName @+0x40, Description @+0x50, Traits[] {Icon, PlayerFacingName,
--     Description} @+0xd8, VehicleSelectImage (soft) - VA_Skimmer points to the *Plane* fallback image, VA_Plane to none.
--   UCstVehiclePresetRecipe (PRE_* Blueprint classes in the GriffinSharedVehicles plugin, mount /GriffinSharedVehicles/):
--     RecipeName (FString, e.g. "Hammerhead"), VehicleArchetype. FRecipeRacerSetup.VehicleCustomisation (+0x80) and
--     RacerDef.PreferredCustomisationForVehicleArchetype (TMap<EVehicleArchetype, class>) hold such classes.
--   UGfnGameInstance.PresetVehicleBuildList (+0x300) -> UPresetBuildList.QuickRaceBuildItems[] -> UPresetBuildItem
--     {PlayerFacingName FText @+0x28, VehicleBuildDef @+0x38}; 27 items (6 planet tiers, 4 DEBUG, 2 pods, 10 ability
--     tests, 5 trailer builds).
--   UGfnVehicleList:FindArchetype(Enum archetype) -> UVehicleArchetype (BlueprintPure).
--   2026-10-07: T_UI_Vehicle_<Class> are white line icons (512x512 DXT5), the renders are
--   T_UI_VehicleSelect_<Car|Bike|Plane>_Fallback (1950x1450 BGRA; "Plane_Fallback" depicts a SKIM SPEEDER, decoded and
--   viewed) and, for pods, the Arcade pod backgrounds (M.classImage).
--   No per-model UI image exists in the paks (searched UI/Library/Textures): the vehicle cards show the livery
--   owner's portrait for a pilot-livery preset (PORTRAIT_BY_SUFFIX below), else the class render tinted in the
--   player's colour, plus the model name and "n / N". 0.7.2 (notes/research/vehicle-preview.md): the per-model visual
--   is a live 3D render of the pick (vpreview.lua: our own BP_StaticVehicleBase_C + SceneCapture2D per column, the
--   2D card stays the fallback) plus the model's manufacturer badge (M.badge, TH_<Model>.Thumbnail decoded).
--   SpawnFrontEndVehicle itself stays unused (one vehicle per tag, sets owned by the game's own screens); the
--   IconPaletteTag/IconMaskTag path is the livery decal, not a UI icon (dead end, vehicle-preview.md §2).
--   0.10.0 RACERS step (notes/design/vehicle-step-v2.md §3.4, §4.2): the VEHICLE stage picks a base MODEL, then a
--   LIVERY of it: M.models groups the presets by base model, M.podName gives a pod its own name (Pvp_IA_Plane_*).

local C   = require("consts")
local cfg = require("config")
local U   = require("util")

local M = {}
local TAG = "vehicles"

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local TEX = "/Game/Griffin/UI/Library/Textures/Content/"
local function tex(sub, name) return TEX .. sub .. "/" .. name .. "." .. name end

---------------------------------------------------------------------------------------------------- classes
-- Order = the order of the CLASS step. maxRacers: grid limit of the class (PvpLiveDataConfig MaxRacersInAnEvent = 12,
-- MaxRacersInAPvpPlaneEvent = 8; the largest shipped grids are 12 speeders / 8 pods). art = Arcade texture class key.
M.CLASSES = {
    { key = "Car", arch = 0, label = "LANDSPEEDER", art = "Car", maxRacers = 12, folder = "Cars",
      va = "/Game/Griffin/Vehicles/Cars/VA_Car.VA_Car",
      image = tex("Vehicles", "T_UI_VehicleSelect_Car_Fallback"), icon = tex("Vehicles", "T_UI_Vehicle_Car") },
    { key = "Bike", arch = 2, label = "SPEEDER BIKE", art = "Bike", maxRacers = 12, folder = "Bikes",
      va = "/Game/Griffin/Vehicles/Bikes/VA_Bike.VA_Bike",
      image = tex("Vehicles", "T_UI_VehicleSelect_Bike_Fallback"), icon = tex("Vehicles", "T_UI_Vehicle_Bike") },
    { key = "Skimmer", arch = 3, label = "SKIM SPEEDER", art = "Skimmer", maxRacers = 12, folder = "Skimmers",
      va = "/Game/Griffin/Vehicles/Skimmers/VA_Skimmer.VA_Skimmer",
      -- the game's own VA_Skimmer.VehicleSelectImage is the "Plane" fallback (sic, decoded)
      image = tex("Vehicles", "T_UI_VehicleSelect_Plane_Fallback"), icon = tex("Vehicles", "T_UI_Vehicle_Skimmer") },
    -- VA_Plane has no VehicleSelectImage; T_UI_Vehicle_Plane is a WHITE line icon (invisible on the light setup page:
    -- run E "the vehicle preview image is empty"). The pod render is the Arcade pod background (decoded + viewed
    -- 2026-10-07: T_UI_Arcade_Mas_Plane_Bg 2172x2160 DXT5 shows a podracer); per planet through M.classImage.
    { key = "Plane", arch = 1, label = "PODRACER", art = "Plane", maxRacers = 8, folder = "Planes",
      va = "/Game/Griffin/Vehicles/Planes/VA_Plane.VA_Plane",
      image = tex("Arcade", "T_UI_Arcade_Mas_Plane_Bg"), icon = tex("Vehicles", "T_UI_Vehicle_Plane"), aspect = 1.0,
      byPlanet = { Bgl = true, Cor = true, Dal = true, Mas = true, Spa = true, Whp = true } },
}
-- Image aspect (width / height) of the class renders: T_UI_VehicleSelect_*_Fallback are 1950x1450 (decoded); the card
-- size box takes the card height and this ratio, so the render is not stretched to the 360x200 default.
for _, c in ipairs(M.CLASSES) do c.aspect = c.aspect or (1950 / 1450) end

-- The class render for the vehicle cards / CLASS media: pods get the Arcade pod art of the chosen planet
-- (T_UI_Arcade_<Pl>_Plane_Bg; planet art codes as in setup.lua PLANETS[].art), else cls.image.
-- VERIFY(V-SET-13): the VEHICLES step shows a podracer render in every pod column (Tatooine: the Bgl art).
function M.classImage(cls, planetArt)
    if not cls then return nil end
    if cls.byPlanet and type(planetArt) == "string" and cls.byPlanet[planetArt] then
        return tex("Arcade", "T_UI_Arcade_" .. planetArt .. "_Plane_Bg")
    end
    return cls.image
end

function M.classByArch(arch)
    arch = tonumber(arch)
    for _, c in ipairs(M.CLASSES) do if c.arch == arch then return c end end
    return nil
end

function M.classByKey(key)
    for _, c in ipairs(M.CLASSES) do if c.key == key then return c end end
    return nil
end

-- Grid limit of a class, config first (cfg.SetupMaxRacers / cfg.SetupMaxRacersPlane), clamped to 1..255 (uint8).
function M.maxRacers(cls)
    local n
    if cls and cls.arch == 1 then n = opt("SetupMaxRacersPlane", cls.maxRacers) else n = opt("SetupMaxRacers", 12) end
    n = math.floor(tonumber(n) or 12)
    if n < 1 then n = 1 elseif n > 255 then n = 255 end
    return n
end

---------------------------------------------------------------------------------------------------- presets
-- id = PRE_* asset name; sub = folder under Presets/ (pods only); owner = whose livery it is (RacerDef names,
-- summarize.py racers). Diorama presets (front-end set dressing) and pod part presets (Engine*/Root*) are left out.
local P = {
    [0] = {   -- Car
        { "PRE_Car_Beluga" }, { "PRE_Car_Bluefin" }, { "PRE_Car_Bowhead" }, { "PRE_Car_Goblin" },
        { "PRE_Car_Hammerhead" }, { "PRE_Car_Mako" }, { "PRE_Car_Marlin" }, { "PRE_Car_Minke" }, { "PRE_Car_Orca" },
        { "PRE_Car_Snook" }, { "PRE_Car_Tarpon" }, { "PRE_Car_Wahoo" },
        { "PRE_Car_Beluga_Protagonist", "SHADE" }, { "PRE_Car_Hammerhead_QuietStrength", "NIK SKANDARO" },
        { "PRE_Car_Orca_Protege", "ARY QUILL" }, { "PRE_Car_Snook_InnerHonour", "SOREN ZAKS" },
        { "PRE_Car_Antagonist", "KESTAR BOOL" },
    },
    [2] = {   -- Bike
        { "PRE_Bike_Boa" }, { "PRE_Bike_Boomslang" }, { "PRE_Bike_Bushmaster" }, { "PRE_Bike_Cobra" },
        { "PRE_Bike_Cottonmouth" }, { "PRE_Bike_Hognose_A" }, { "PRE_Bike_Kingsnake" }, { "PRE_Bike_Lancehead" },
        { "PRE_Bike_Mamba" }, { "PRE_Bike_Rattlesnake" }, { "PRE_Bike_Sidewinder" }, { "PRE_Bike_Taipan" },
        { "PRE_Bike_Taipan_Protagonist", "SHADE" }, { "PRE_Bike_Boa_Mercenary", "MALIS VAZOSK" },
        { "PRE_Bike_Boomslang_Thrall", "SEN FIRA" }, { "PRE_Bike_Rattlesnake_ElegantProfessional", "KATJA MOX" },
        { "PRE_Bike_Sidewinder_Rager", "BIDDY BLAS" },
    },
    [3] = {   -- Skimmer
        { "PRE_Skimmer_Albatross" }, { "PRE_Skimmer_Condor" }, { "PRE_Skimmer_Crow" }, { "PRE_Skimmer_Jackdaw" },
        { "PRE_Skimmer_Merlin" }, { "PRE_Skimmer_Needletail" }, { "PRE_Skimmer_Pelican" }, { "PRE_Skimmer_Peregrine" },
        { "PRE_Skimmer_Raven" }, { "PRE_Skimmer_Rook" }, { "PRE_Skimmer_Saker" }, { "PRE_Skimmer_Stork" },
        { "PRE_Skimmer_Merlin_Protagonist", "SHADE" }, { "PRE_Skimmer_Condor_Nomad", "FOLA KANJEN" },
        { "PRE_Skimmer_Crow_StarUpdated", "LYREN SHOK" }, { "PRE_Skimmer_Pelican_Ghost", "GOLI & 02-R0" },
        { "PRE_Skimmer_Rook_Mentor", "SEBULBA" }, { "PRE_Skimmer_Saker_VeteranUpdated", "GRIFF HALLORAN" },
    },
    [1] = {   -- Plane (pods live in one sub-folder per model)
        { "PRE_Plane_Cretornis", nil, "Cretornis" }, { "PRE_Plane_Dearc", nil, "Dearc" },
        { "PRE_Plane_Hexing", nil, "Hexing" }, { "PRE_Plane_MythP1", nil, "Myth" }, { "PRE_Plane_MythP2", nil, "Myth" },
        { "PRE_Plane_MythP3", nil, "Myth" }, { "PRE_Plane_Nesodon", "SEBULBA", "Nesodon" },
        { "PRE_Plane_Northropi", nil, "Northropi" }, { "PRE_Plane_Sordes", nil, "Sordes" },
        { "PRE_Plane_Tarchia", nil, "Tarchia" }, { "PRE_Plane_CretornisAged", "AGED", "Cretornis" },
        { "PRE_Plane_DearcAged", "AGED", "Dearc" }, { "PRE_Plane_HexingAged", "AGED", "Hexing" },
    },
}

-- "PRE_Car_Hammerhead_QuietStrength" -> "HAMMERHEAD"; "PRE_Plane_MythP2" -> "MYTH P2"; "PRE_Bike_Hognose_A" -> "HOGNOSE A"
local function modelName(id)
    local s = id:gsub("^PRE_%a+_", "")
    s = s:gsub("_(Protagonist)$", ""):gsub("_(QuietStrength)$", ""):gsub("_(Protege)$", ""):gsub("_(InnerHonour)$", "")
    s = s:gsub("_(Mercenary)$", ""):gsub("_(Thrall)$", ""):gsub("_(ElegantProfessional)$", ""):gsub("_(Rager)$", "")
    s = s:gsub("_(Nomad)$", ""):gsub("_(StarUpdated)$", ""):gsub("_(Ghost)$", ""):gsub("_(Mentor)$", "")
    s = s:gsub("_(VeteranUpdated)$", ""):gsub("Aged$", ""):gsub("(%l)(P%d)$", "%1 %2"):gsub("_", " ")
    return string.upper(s)
end

-- Livery owner portrait per preset suffix: RacerDef.LargePreviewImage (soft Texture2D, CharacterDef +0x218), read
-- statically from the decoded DA_Racer_*.json (work/decoded/.../CharacterDefs/Racers). The vehicle cards show it for
-- a pilot-livery preset, so a player sees WHICH vehicle (whose livery) each player picked, not only one class render.
-- SHADE (_Protagonist) has no RacerDef of its own: class render.
local CHAR = "/Game/Griffin/UI/Library/Textures/Content/Characters/"
local function chr(name) return CHAR .. name .. "." .. name end
local PORTRAIT_BY_SUFFIX = {
    QuietStrength = chr("T_UI_PlayerChar_1_Fallback"), VeteranUpdated = chr("T_UI_PlayerChar_2_Fallback"),
    Nomad = chr("T_UI_PlayerChar_3_Fallback"), InnerHonour = chr("T_UI_PlayerChar_5_Fallback"),
    ElegantProfessional = chr("T_UI_PlayerChar_6_Fallback"), Antagonist = chr("T_UI_PlayerChar_Antagonist_Fallback"),
    Ghost = chr("T_UI_RivalChar_Ghost_Fallback"), Mercenary = chr("T_UI_RivalChar_Mercenary_Fallback"),
    Protege = chr("T_UI_RivalChar_Yara_Fallback"), Rager = chr("T_UI_RivalChar_Ziff_Fallback"),
    StarUpdated = chr("T_UI_RivalChar_Lyren_Fallback"), Thrall = chr("T_UI_RivalChar_Sen_Fallback"),
    Mentor = chr("T_UI_PlaneChar_Nesodon_Fallback"), Nesodon = chr("T_UI_PlaneChar_Nesodon_Fallback"),
}
local function portraitOf(id)
    local suffix = id:match("_([%a]+)$")
    return suffix and PORTRAIT_BY_SUFFIX[suffix] or nil
end

-- Base model of a preset: "PRE_Car_Hammerhead_QuietStrength" -> "Hammerhead", "PRE_Bike_Hognose_A" -> "Hognose",
-- "PRE_Plane_MythP2" -> "Myth", "PRE_Plane_CretornisAged" -> "Cretornis", "PRE_Car_Antagonist" -> "Antagonist".
local function baseModel(id)
    local s = id:gsub("^PRE_%a+_", ""):gsub("_.*$", "")
    s = s:gsub("P%d+$", ""):gsub("Aged$", "")
    return s
end

-- Manufacturer badge per base model (TH_<Model>.Thumbnail, a hard Texture2D, 256x256 rounded-square logo with an
-- A/B glyph; decoded 2026-10-07, vehicle-preview.md §8). Unique within a class; pilot-livery presets use their base
-- model's badge; pods have none except Myth (TH_Myth -> PRE_Plane_MythP3); PRE_Car_Antagonist has no theme.
local BADGE = {
    Beluga = "Ace_A", Bluefin = "Raider_A", Bowhead = "Enforcer_B", Goblin = "Assassin_B", Hammerhead = "Raider_B",
    Mako = "Enforcer_A", Marlin = "Robotic_A", Minke = "Vintage_B", Orca = "Robotic_B", Snook = "Ace_B",
    Tarpon = "Vintage_A", Wahoo = "Assassin_A",                                                      -- cars
    Boa = "Raider_A", Boomslang = "Assassin_B", Bushmaster = "Raider_B", Cobra = "Vintage_A", Cottonmouth = "Ace_B",
    Hognose = "Enforcer_A", Kingsnake = "Robotic_A", Lancehead = "Robotic_B", Mamba = "Assassin_A",
    Rattlesnake = "Vintage_B", Sidewinder = "Enforcer_B", Taipan = "Ace_A",                          -- bikes
    Albatross = "Raider_B", Condor = "Raider_A", Crow = "Assassin_B", Jackdaw = "Robotic_A", Merlin = "Ace_A",
    Needletail = "Vintage_B", Pelican = "Robotic_B", Peregrine = "Ace_B", Raven = "Assassin_A", Rook = "Vintage_A",
    Saker = "Enforcer_A", Stork = "Enforcer_B",                                                      -- skimmers
    Myth = "Ace_A",                                                                                  -- pods
}
local MANUFACTURER = TEX .. "Customization/Vehicles/Manufacturer/"

-- Texture path of a preset entry's manufacturer badge (vehicle cards, top left), nil when its model has none.
-- VERIFY(V-VP-08): each speeder card shows a logo; pods other than MYTH show none.
function M.badge(p)
    local code = type(p) == "table" and BADGE[p.base or ""] or nil
    if not code then return nil end
    local n = "T_UI_Manufacturer_" .. code .. "_Thumb"
    return MANUFACTURER .. n .. "." .. n
end

local presetCache = {}   -- arch -> list
function M.presets(arch)
    arch = tonumber(arch)
    if presetCache[arch] then return presetCache[arch] end
    local cls = M.classByArch(arch)
    local out = {}
    for i, e in ipairs(P[arch] or {}) do
        local id, owner, sub = e[1], e[2], e[3]
        local dir = "/GriffinSharedVehicles/Griffin/Vehicles/" .. (cls and cls.folder or "?") .. "/Presets/"
            .. (sub and (sub .. "/") or "")
        local name = modelName(id)
        out[#out + 1] = {
            index = i, id = id, owner = owner, name = name, base = baseModel(id),
            label = owner and (name .. " (" .. owner .. ")") or name,
            portrait = owner and portraitOf(id) or nil,  -- livery owner's portrait (vehicle card), nil = class art
            asset = dir .. id .. "." .. id,              -- LoadAsset path
            classPath = dir .. id .. "." .. id .. "_C",  -- the generated class (FRecipeRacerSetup.VehicleCustomisation)
        }
    end
    -- LIVERY row label (RACERS step): the owner ("ARY QUILL", pods "AGED"), the preset's own name when its model has
    -- several owner-less presets ("MYTH P2"), else "STANDARD".
    local plain = {}   -- base -> owner-less presets
    for _, p in ipairs(out) do if not p.owner then plain[p.base] = (plain[p.base] or 0) + 1 end end
    for _, p in ipairs(out) do p.livery = p.owner or ((plain[p.base] or 0) > 1 and p.name) or "STANDARD" end
    presetCache[arch] = out
    return out
end

-- Distinct default per player: P1 the first base model, P2 the 2nd, ... (wraps).
function M.defaultPresetIndex(arch, pnum)
    local n = #M.presets(arch)
    if n == 0 then return 1 end
    return ((math.max(1, tonumber(pnum) or 1) - 1) % n) + 1
end

function M.presetById(arch, id)
    for _, p in ipairs(M.presets(arch)) do if p.id == id then return p end end
    return nil
end

---------------------------------------------------------------------------------------------------- models
-- RACERS step (vehicle-step-v2.md §3.4, §4.2): MODEL row = the base models of the class, LIVERY row = the presets of
-- the current model. Pod names = the titles of the pods' PlaneInstantAction racer styles (Pvp_IA_Plane_<Veg>
-- descriptions, decoded 2026-10-09, pilot-select.md §2.2); Myth and Northropi have none.
local POD_NAME = {
    Cretornis = "VULPTEREEN 327", Hexing = "CUSTOM ORD PEDROVIA", Sordes = "IPG-X1131 LONGTAIL",
    Nesodon = "PLUG-F MAMMOTH", Dearc = "BT310 QUADRA", Tarchia = "EXELBROK XL 5115",
}

-- "Cretornis" -> "VULPTEREEN 327"; nil for every other base model.
function M.podName(base)
    return type(base) == "string" and POD_NAME[base] or nil
end

-- {{base = "Orca", name = "ORCA", presets = {<M.presets entries>}, badge = path | nil, code = "CRE" | nil,
-- maker = "ROBOTIC" | nil, podName = "VULPTEREEN 327" | nil}, ...}: M.presets(arch) grouped by base model in
-- first-appearance order (Car 13 = 12 + ANTAGONIST, Bike 12, Skimmer 12, Plane 8). Inside a model the owner-less
-- presets come first (MYTH P1/P2/P3), then the owner liveries (pods: AGED). code = 3-letter model code, set only when
-- the model has no badge (pods but MYTH, PRE_Car_Antagonist); maker = the badge's maker (Robotic_B -> "ROBOTIC") for
-- the info line. Cached and shared like M.presets: callers must not modify the tables.
local modelCache = {}   -- arch -> list
function M.models(arch)
    arch = tonumber(arch)
    if arch == nil then return {} end
    if modelCache[arch] then return modelCache[arch] end
    local out, byBase, owned = {}, {}, {}
    for _, p in ipairs(M.presets(arch)) do
        local m = byBase[p.base]
        if not m then
            local badge, badgeCode = M.badge(p), BADGE[p.base]
            m = { base = p.base, name = string.upper(p.base), presets = {}, badge = badge,
                  code = (not badge) and string.upper(p.base:sub(1, 3)) or nil,
                  maker = badgeCode and string.upper((badgeCode:gsub("_%a+$", ""))) or nil,
                  podName = M.podName(p.base) }
            byBase[p.base], owned[p.base] = m, {}
            out[#out + 1] = m
        end
        if p.owner then local o = owned[p.base]; o[#o + 1] = p else m.presets[#m.presets + 1] = p end
    end
    for _, m in ipairs(out) do
        for _, p in ipairs(owned[m.base]) do m.presets[#m.presets + 1] = p end
    end
    modelCache[arch] = out
    return out
end

-- Model index, livery index and model entry of a preset id; nil when the class has no such preset.
function M.modelOf(arch, id)
    for mi, m in ipairs(M.models(arch)) do
        for li, p in ipairs(m.presets) do
            if p.id == id then return mi, li, m end
        end
    end
    return nil
end

-- The preset a MODEL change lands on (§4.2): preferId (the pilot's signature preset) when model mi has it, else the
-- model's standard livery. nil for a model index out of range.
function M.modelPreset(arch, mi, preferId)
    local m = M.models(arch)[tonumber(mi) or 0]
    if not m then return nil end
    if preferId then
        for _, p in ipairs(m.presets) do if p.id == preferId then return p end end
    end
    return m.presets[1]
end

---------------------------------------------------------------------------------------------------- resolvers
local classObjCache = {}   -- classPath -> UClass
local loadTriedAt = {}     -- asset -> os.time() of the last LoadAsset

local function findObj(path)
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.ok(o) then return o end
    return nil
end

-- Generated class of a preset: StaticFindObject, else LoadAsset(<pkg>.<name>) (game thread; it loads the package
-- even when it reports the cooked-out Blueprint as not found, see util U.class) and find again. nil when unresolved.
-- VERIFY(V-SET-05): "/GriffinSharedVehicles/..." plugin paths load through LoadAsset like /Game/ paths.
function M.presetClass(p)
    if type(p) ~= "table" then return nil end
    local c = classObjCache[p.classPath]
    if c and U.ok(c) then return c end
    c = findObj(p.classPath)
    if not c then
        local now = os.time()
        if (loadTriedAt[p.asset] or -100) + 5 <= now then
            loadTriedAt[p.asset] = now
            local ok, _, found, loaded = pcall(LoadAsset, p.asset)
            U.logOnce("vehicles.load." .. p.id, TAG, "LoadAsset(%s): ok=%s found=%s loaded=%s", p.asset, tostring(ok),
                tostring(found), tostring(loaded))
            c = findObj(p.classPath)
        end
    end
    if c then classObjCache[p.classPath] = c else
        U.logOnce("vehicles.miss." .. p.id, TAG, "preset class %s not resolvable", p.classPath)
    end
    return c
end

-- UVehicleArchetype for a class entry: GfnGameInstance.VehicleList:FindArchetype(arch) first (the object the game's
-- own pickers use), else the VA asset path.
function M.archetypeObj(cls)
    if not cls then return nil end
    local found = nil
    pcall(function()
        local vl = U.gi().VehicleList
        if U.ok(vl) then
            local o = vl:FindArchetype(cls.arch)          -- FindArchetype(Enum archetype) -> Object
            if U.ok(o) then found = o end
        end
    end)
    if found then return found end
    local o = U.obj(cls.va)
    if U.ok(o) then return o end
    return nil
end

local function ftextStr(o, field)
    local ok, s = pcall(function() return U.str(o[field]) end)
    if ok and type(s) == "string" then return s end
    return ""
end

-- {name, desc, traits = {"NAME: description", ...}} from the VA asset (FText fields), "" when unreadable.
-- The archetype texts are rich text for the game's own widgets: <action id="ImprovedSteering"/> is an input glyph
-- (the game's VEHICLE SELECT draws the X button there), <H1>..</> styles. Plain text blocks showed the markup raw
-- ("USE <ACTION ID=..."), so: known actions become their pad button, every other tag is dropped.
local ACTION_LABEL = { improvedsteering = "X" }
local function plainText(s)
    if type(s) ~= "string" or s == "" then return "" end
    s = s:gsub('<action%s+id="([^"]*)"%s*/>', function(id) return ACTION_LABEL[id:lower()] or "the button" end)
    s = s:gsub("<[^>]*>", "")
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end
M.plainText = plainText

function M.classInfo(cls)
    local out = { name = cls and cls.label or "?", desc = "", traits = {} }
    local va = M.archetypeObj(cls)
    if not va then return out end
    local n = ftextStr(va, "PlayerFacingName")
    if n ~= "" then out.name = string.upper(n) end
    out.desc = plainText(ftextStr(va, "Description"))
    pcall(function()
        local arr = va.Traits
        local cnt = arr:GetArrayNum()
        for i = 1, math.min(cnt, 3) do
            local t = arr[i]
            local tn, td = U.str(t.PlayerFacingName), plainText(U.str(t.Description))
            out.traits[#out.traits + 1] = string.upper(tn) .. (td ~= "" and (": " .. td) or "")
        end
    end)
    return out
end

-- Texture2D object by path ("" / unresolvable -> nil).
function M.texture(path)
    if type(path) ~= "string" or path == "" then return nil end
    local o = U.obj(path)
    if U.ok(o) then return o end
    return nil
end

---------------------------------------------------------------------------------------------------- builds
local BUILD_DIR = "/Game/Griffin/Vehicles/Common/Upgrades/BuildDefinitions/"
-- Fallback when GfnGameInstance.PresetVehicleBuildList is unreadable (labels = the game's own, DA_PresetBuilds).
local STATIC_BUILDS = {
    { "01 - Mastiff [0%]", BUILD_DIR .. "VBD_000_1Mastiff.VBD_000_1Mastiff" },
    { "02 - Dalmatian [11%]", BUILD_DIR .. "VBD_011_2Dal.VBD_011_2Dal" },
    { "03 - Husky [23%]", BUILD_DIR .. "VBD_023_3Husky.VBD_023_3Husky" },
    { "04 - Corgi [35%]", BUILD_DIR .. "VBD_035_4Corgi.VBD_035_4Corgi" },
    { "05 - Spaniel [46%]", BUILD_DIR .. "VBD_046_5Spaniel.VBD_046_5Spaniel" },
    { "06 - Whippet [58%]", BUILD_DIR .. "VBD_058_6Whippet.VBD_058_6Whippet" },
    { "Memory Pod [No Ramjet]", BUILD_DIR .. "VBD_000_1Mastiff_Plane.VBD_000_1Mastiff_Plane" },
    { "PDay Pod [Unstable]", "/Game/Griffin/Gameplay/Campaign/Builds/VBD_Plane_PDay_Unstable.VBD_Plane_PDay_Unstable" },
}

-- Which builds a class offers. Pods: the pod builds; speeders: the planet tiers (+ DEBUG with cfg.SetupDebugBuilds;
-- every build with cfg.SetupAllBuilds, as the dev panel does).
local function buildFits(arch, label, path)
    if opt("SetupAllBuilds", false) == true then return true end
    local isPod = label:find("Pod", 1, true) ~= nil or path:find("_Plane", 1, true) ~= nil
    if arch == 1 then return isPod end
    if isPod then return false end
    if label:match("^%s*0%d%s*%-") then return true end
    return opt("SetupDebugBuilds", false) == true and label:find("DEBUG", 1, true) ~= nil
end

-- "01 - Mastiff [0%]" -> "TIER 1 [0%]"; other labels upper-cased and trimmed.
local function buildLabel(label)
    local n, pct = label:match("^%s*0(%d)%s*%-%s*%a+%s*(%[[^%]]*%])")
    if n then return "TIER " .. n .. " " .. pct end
    return string.upper((label:gsub("^%s+", ""):gsub("%s+$", "")))
end

-- {{label, path, obj}, ...} for a class (obj resolved lazily by M.buildObj).
function M.builds(arch)
    arch = tonumber(arch)
    local out = {}
    local okR = pcall(function()
        local items = U.gi().PresetVehicleBuildList.QuickRaceBuildItems
        local n = items:GetArrayNum()
        for i = 1, n do
            local it = items[i]
            if U.ok(it) then
                local def = it.VehicleBuildDef
                local label = U.str(it.PlayerFacingName)
                local path = U.ok(def) and U.pathOf(def) or ""
                if path ~= "" and buildFits(arch, label, path) then
                    out[#out + 1] = { label = buildLabel(label), raw = label, path = path, obj = def }
                end
            end
        end
    end)
    if not okR or #out == 0 then
        out = {}
        for _, b in ipairs(STATIC_BUILDS) do
            if buildFits(arch, b[1], b[2]) then out[#out + 1] = { label = buildLabel(b[1]), raw = b[1], path = b[2] } end
        end
        U.logOnce("vehicles.staticbuilds." .. tostring(arch), TAG,
            "build list for archetype %s from the static table (PresetVehicleBuildList %s)", tostring(arch),
            okR and "had no match" or "unreadable")
    end
    return out
end

function M.buildObj(b)
    if type(b) ~= "table" then return nil end
    if U.ok(b.obj) then return b.obj end
    local o = U.obj(b.path)
    if U.ok(o) then b.obj = o; return o end
    return nil
end

-- Index of the build that matches a path (1 when none).
function M.buildIndex(list, path)
    for i, b in ipairs(list) do if b.path == path then return i end end
    return 1
end

return M
