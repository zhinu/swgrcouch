-- SWGRCouch · pilots.lua (0.10.0, G4 Players & launch): the pilot catalog of the RACE SETUP step "RACERS" - who may
-- race which class, in which order, with which art, racer style and signature vehicle - plus the default and
-- uniqueness rules and the RacerDef resolvers. Static data and pure functions; the only game reads are P.def (the
-- RacerDef by path) and P.favourite (P1's multiplayer favourite), both game thread only. No module state.
-- Design: notes/design/vehicle-step-v2.md §2.4 (defaults), §2.8 (uniqueness, class gating), §4.1 (table), §5.2 (API);
-- research notes/research/pilot-select.md.
--
-- Static sources (cue4cli decode of the hotfixed Steam paks, 2026-10-09; pilot-select.md §1-§5):
--   /Game/Griffin/Narrative/CharacterDefs/Racers/DA_Racer_* and DA_PlaneRacer_* (URacerDef). DA_CharacterList holds all
--   of them through hard references, so they stay resident while the GameInstance lives. CharacterDef.MainIcon (the
--   256x256 head shot) and RacerDef.LargePreviewImage (the 1480x1800 full body) are SOFT pointers and are never read:
--   thumb / full below are their decoded values (/Game/Griffin/UI/Library/Textures/Content/Characters/, every name
--   checked against notes/asset-list.txt and the PNG export work/png/pilots).
--   Class gating by seated pose (PAD_<Class>, PMM_PilotMeshes, §4.5): the pod aliens only have pod poses, SEBULBA
--   (Mentor, mesh PM_Swede) skimmer and pod poses; the humanoid speeder pilots fit every class.
--   crop = the figure box of a pod-figure render (alpha > 8 plus 6 % / 3 % padding, §5.3): those figures are short or
--   wide and would sit small at the bottom of the common-scale frame. The Aged boxes were computed the same way.
--   style = the perkdata STYLES / KITS key of the pilot's multiplayer racer style (Pvp_Style_<Key>; pods
--   Pvp_IA_Plane_<Veg> = "Pod_<Veg>"); a speeder pilot's style applies in every class it is offered for.
--   sig = RacerDef.PreferredCustomisationForVehicleArchetype (a hard TMap, decoded) as vehicles.lua preset ids.
--   tile (0.12.0 UI v2, notes/design/ui-v2/ui-redesign-final.md §9.3, WI-10) = the pilot's SCENARIOS poster
--   (Content/Scenarios/T_UI_FE_Scenario_0xx_<Tag>_Tile, 960x1580 duotone portrait; mapping decoded from the SCEN_0xx_*
--   assets, notes/research/ui-parts-catalogue.md §3.4, every name in notes/asset-list.txt). SEBULBA and the pod pilots
--   have none (nil): their card shows M.EMPTY_TILE with the full body (full / crop) on it.
-- Never offered: DA_Racer_TestPilot (dev "AUTOPILOT", no art), DA_Racer_MentorBossRace (campaign copy of SEBULBA).
local cfg = require("config")
local U   = require("util")
local V   = require("vehicles")

local M = {}
local TAG = "pilots"

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local CHAR = "/Game/Griffin/UI/Library/Textures/Content/Characters/"
local SCEN = "/Game/Griffin/UI/Library/Textures/Content/Scenarios/"
local DEF_DIR = "/Game/Griffin/Narrative/CharacterDefs/Racers/"
local SHADE = "DA_Racer_DarkEnigma"

-- The SCENARIOS poster with the stripes only (catalogue §3.4 "no pilot / empty slot"): the art window of SEBULBA and
-- the pod pilots (entry.tile nil) under their full body (UI v2 §9.3).
M.EMPTY_TILE = SCEN .. "T_UI_FE_Scenario_000_Empty_Tile.T_UI_FE_Scenario_000_Empty_Tile"

-- {u0, v0, u1, v1}, the same numbers also as named fields (crop[1] == crop.u0).
local function box(u0, v0, u1, v1) return { u0, v0, u1, v1, u0 = u0, v0 = v0, u1 = u1, v1 = v1 } end

---------------------------------------------------------------------------------------------------- catalog
-- Source form: classes = list of EVehicleArchetype (Car 0, Plane 1, Bike 2, Skimmer 3), thumb / full = texture names,
-- crop = {u0, v0, u1, v1}; the loop below turns them into the entry shape of §5.2. specialist = {[arch] = rank}: the
-- class specialists a guest gets first (§2.4, PS §6.2). Flags: podRival = offered in pods with cfg.PilotPodRivals
-- (the 11 CharacterList.Opponents), extra = offered only when cfg.PilotExtras lists it, pod = pod-figure art, aged =
-- the Pod Tour roster (cfg.PilotPodAged).
M.ALL = {
    -- the 13 PvpPlayable speeder pilots (DA_CharacterList order = multiplayer rank unlock order)
    { id = "DA_Racer_DarkEnigma", name = "SHADE", tag = "DarkEnigma", classes = { 0, 1, 2, 3 },
      thumb = "T_UI_PlayerChar_4", full = "T_UI_PlayerChar_4_Fallback", tile = "T_UI_FE_Scenario_003_Tomato_Tile",
      style = "Cooling",
      sig = { [0] = "PRE_Car_Beluga_Protagonist", [1] = "PRE_Plane_MythP3", [2] = "PRE_Bike_Taipan_Protagonist",
              [3] = "PRE_Skimmer_Merlin_Protagonist" } },
    { id = "DA_Racer_ElegantProfessional", name = "KATJA MOX", tag = "ElegantProfessional", classes = { 0, 2, 3 },
      podRival = true, thumb = "T_UI_PlayerChar_6", full = "T_UI_PlayerChar_6_Fallback",
      tile = "T_UI_FE_Scenario_010_ElegantProfessional_Tile", style = "Abilities",
      sig = { [2] = "PRE_Bike_Rattlesnake_ElegantProfessional" }, specialist = { [2] = 1 } },
    { id = "DA_Racer_Veteran", name = "GRIFF HALLORAN", tag = "Veteran", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_PlayerChar_2", full = "T_UI_PlayerChar_2_Fallback", tile = "T_UI_FE_Scenario_008_Veteran_Tile",
      style = "Afterburner", sig = { [3] = "PRE_Skimmer_Saker_VeteranUpdated" }, specialist = { [3] = 1 } },
    { id = "DA_Racer_Protege", name = "ARY QUILL", tag = "Protege", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_RivalChar_Yara", full = "T_UI_RivalChar_Yara_Fallback", tile = "T_UI_FE_Scenario_006_Protege_Tile",
      style = "Ramjet", sig = { [0] = "PRE_Car_Orca_Protege" }, specialist = { [0] = 1 } },
    { id = "DA_Racer_InnerHonour", name = "SOREN ZAKS", tag = "InnerHonour", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_PlayerChar_5", full = "T_UI_PlayerChar_5_Fallback", tile = "T_UI_FE_Scenario_004_InnerHonour_Tile",
      style = "Malfunction", sig = { [0] = "PRE_Car_Snook_InnerHonour" }, specialist = { [0] = 2 } },
    { id = "DA_Racer_QuietStrength", name = "NIK SKANDARO", tag = "QuietStrength", classes = { 0, 2, 3 },
      podRival = true, thumb = "T_UI_PlayerChar_1", full = "T_UI_PlayerChar_1_Fallback",
      tile = "T_UI_FE_Scenario_001_QuietStrength_Tile", style = "Defence",
      sig = { [0] = "PRE_Car_Hammerhead_QuietStrength" }, specialist = { [0] = 3 } },
    -- Ghost and Nomad also prefer the Hexing pod (decoded): their signature when cfg.PilotPodRivals offers them in pods
    { id = "DA_Racer_Ghost", name = "GOLI & 02-R0", tag = "Ghost", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_RivalChar_Ghost", full = "T_UI_RivalChar_Ghost_Fallback", tile = "T_UI_FE_Scenario_009_Ghost_Tile",
      style = "Surging", sig = { [1] = "PRE_Plane_Hexing", [3] = "PRE_Skimmer_Pelican_Ghost" },
      specialist = { [3] = 2 } },
    { id = "DA_Racer_Nomad", name = "FOLA KANJEN", tag = "Nomad", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_PlayerChar_3", full = "T_UI_PlayerChar_3_Fallback", tile = "T_UI_FE_Scenario_002_Nomad_Tile",
      style = "Struggling", sig = { [1] = "PRE_Plane_Hexing", [3] = "PRE_Skimmer_Condor_Nomad" },
      specialist = { [3] = 3 } },
    { id = "DA_Racer_Thrall", name = "SEN FIRA", tag = "Thrall", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_RivalChar_Sen", full = "T_UI_RivalChar_Sen_Fallback", tile = "T_UI_FE_Scenario_012_Broccoli_Tile",
      style = "Drafting", sig = { [2] = "PRE_Bike_Boomslang_Thrall" }, specialist = { [2] = 2 } },
    { id = "DA_Racer_Rager", name = "BIDDY BLAS", tag = "Rager", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_RivalChar_Ziff", full = "T_UI_RivalChar_Ziff_Fallback", tile = "T_UI_FE_Scenario_011_Carrot_Tile",
      style = "Burning", sig = { [2] = "PRE_Bike_Sidewinder_Rager" }, specialist = { [2] = 3 } },
    { id = "DA_Racer_Mercenary", name = "MALIS VAZOSK", tag = "Mercenary", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_RivalChar_Mercenary", full = "T_UI_RivalChar_Mercenary_Fallback",
      tile = "T_UI_FE_Scenario_005_Mercenary_Tile", style = "Battling",
      sig = { [2] = "PRE_Bike_Boa_Mercenary" }, specialist = { [2] = 4 } },
    { id = "DA_Racer_Star", name = "LYREN SHOK", tag = "Star", classes = { 0, 2, 3 }, podRival = true,
      thumb = "T_UI_RivalChar_Lyren", full = "T_UI_RivalChar_Lyren_Fallback", tile = "T_UI_FE_Scenario_007_Star_Tile",
      style = "Airborne", sig = { [3] = "PRE_Skimmer_Crow_StarUpdated" }, specialist = { [3] = 4 } },
    { id = "DA_Racer_Antagonist", name = "KESTAR BOOL", tag = "Antagonist", classes = { 0, 1, 2, 3 },
      thumb = "T_UI_Antagonist", full = "T_UI_PlayerChar_Antagonist_Fallback",
      tile = "T_UI_FE_Scenario_013_Antagonist_Tile", style = "Antagonist",
      sig = { [0] = "PRE_Car_Antagonist", [1] = "PRE_Plane_Northropi" }, specialist = { [0] = 4 } },
    -- extra (cfg.PilotExtras): SEBULBA in a skim speeder. His MainIcon is a favour card, so he uses the pod pilot's art.
    { id = "DA_Racer_Mentor", name = "SEBULBA", tag = "Mentor", classes = { 3 }, extra = true,
      thumb = "T_UI_PlaneChar_Nesodon_Thumb", full = "T_UI_PlaneChar_Nesodon_Fallback",
      crop = { 0.228, 0.393, 0.806, 0.998 }, style = "BattlingFlameVent", sig = { [3] = "PRE_Skimmer_Rook_Mentor" } },
    -- the 6 pod pilots (PvpPlaneInstantActionPlayable order); style = their pod's IA style
    { id = "DA_PlaneRacer_Cabbage", name = "DUD BOLT", tag = "Cabbage", classes = { 1 }, pod = true,
      thumb = "T_UI_PlaneChar_Cabbage_Thumb", full = "T_UI_PlaneChar_Cabbage_Fallback",
      crop = { 0.221, 0.458, 0.778, 0.993 }, style = "Pod_Cabbage", sig = { [1] = "PRE_Plane_Cretornis" },
      specialist = { [1] = 1 } },
    { id = "DA_PlaneRacer_Celery", name = "GASGANO", tag = "Celery", classes = { 1 }, pod = true,
      thumb = "T_UI_PlaneChar_Celery_Thumb", full = "T_UI_PlaneChar_Celery_Fallback",
      crop = { 0.241, 0.292, 0.815, 0.994 }, style = "Pod_Celery", sig = { [1] = "PRE_Plane_Hexing" },
      specialist = { [1] = 2 } },
    { id = "DA_PlaneRacer_Garlic", name = "TEEMTO PAGALIES", tag = "Garlic", classes = { 1 }, pod = true,
      thumb = "T_UI_PlaneChar_Garlic_Thumb", full = "T_UI_PlaneChar_Garlic_Fallback",
      crop = { 0.229, 0.229, 0.658, 0.995 }, style = "Pod_Garlic", sig = { [1] = "PRE_Plane_Sordes" },
      specialist = { [1] = 3 } },
    { id = "DA_PlaneRacer_Nesodon", name = "SEBULBA", tag = "Mentor", classes = { 1 }, pod = true,
      thumb = "T_UI_PlaneChar_Nesodon_Thumb", full = "T_UI_PlaneChar_Nesodon_Fallback",
      crop = { 0.228, 0.393, 0.806, 0.998 }, style = "Pod_Swede", sig = { [1] = "PRE_Plane_Nesodon" },
      specialist = { [1] = 4 } },
    { id = "DA_PlaneRacer_Onion", name = "BEN QUADINAROS", tag = "Onion", classes = { 1 }, pod = true,
      thumb = "T_UI_PlaneChar_Onion_Thumb", full = "T_UI_PlaneChar_Onion_Fallback",
      crop = { 0.112, 0.041, 0.972, 1.000 }, style = "Pod_Onion", sig = { [1] = "PRE_Plane_Dearc" },
      specialist = { [1] = 5 } },
    { id = "DA_PlaneRacer_Pepper", name = "ODY MANDRELL", tag = "Pepper", classes = { 1 }, pod = true,
      thumb = "T_UI_PlaneChar_Pepper_Thumb", full = "T_UI_PlaneChar_Pepper_Fallback",
      crop = { 0.203, 0.028, 0.688, 1.000 }, style = "Pod_Pepper", sig = { [1] = "PRE_Plane_Tarchia" },
      specialist = { [1] = 6 } },
    -- the Aged five (cfg.PilotPodAged; PvpPlanePlayable, the Pod Tour roster): the same characters with their own art
    -- and their *Aged pods. Their IA style is the trait-less Pvp_Style_PlaneMemory, so they take their younger self's
    -- pod style (the pod kits of §4.4 are built on these pilots' Pod Tour styles anyway).
    { id = "DA_PlaneRacer_CabbageAged", name = "DUD BOLT · AGED", tag = "Cabbage", classes = { 1 }, pod = true,
      aged = true, thumb = "T_UI_PlaneChar_CabbageAged_Thumb", full = "T_UI_PlaneChar_CabbageAged_Fallback",
      crop = { 0.220, 0.458, 0.777, 0.993 }, style = "Pod_Cabbage", sig = { [1] = "PRE_Plane_CretornisAged" } },
    { id = "DA_PlaneRacer_CeleryAged", name = "GASGANO · AGED", tag = "Celery", classes = { 1 }, pod = true,
      aged = true, thumb = "T_UI_PlaneChar_CeleryAged_Thumb", full = "T_UI_PlaneChar_CeleryAged_Fallback",
      crop = { 0.242, 0.223, 0.816, 0.998 }, style = "Pod_Celery", sig = { [1] = "PRE_Plane_HexingAged" } },
    { id = "DA_PlaneRacer_NesodonAged", name = "SEBULBA · AGED", tag = "Mentor", classes = { 1 }, pod = true,
      aged = true, thumb = "T_UI_PlaneChar_SwedeAged_Thumb", full = "T_UI_PlaneChar_SwedeAged_Fallback",
      crop = { 0.228, 0.389, 0.813, 0.999 }, style = "Pod_Swede", sig = { [1] = "PRE_Plane_Nesodon" } },
    { id = "DA_PlaneRacer_OnionAged", name = "BEN QUADINAROS · AGED", tag = "Onion", classes = { 1 }, pod = true,
      aged = true, thumb = "T_UI_PlaneChar_OnionAged_Thumb", full = "T_UI_PlaneChar_OnionAged_Fallback",
      crop = { 0.060, 0.044, 0.957, 1.000 }, style = "Pod_Onion", sig = { [1] = "PRE_Plane_DearcAged" } },
    { id = "DA_PlaneRacer_PepperAged", name = "ODY MANDRELL · AGED", tag = "Pepper", classes = { 1 }, pod = true,
      aged = true, thumb = "T_UI_PlaneChar_PepperAged_Thumb", full = "T_UI_PlaneChar_PepperAged_Fallback",
      crop = { 0.207, 0.026, 0.683, 1.000 }, style = "Pod_Pepper", sig = { [1] = "PRE_Plane_Tarchia" } },
}

-- Entry shape (§5.2): {id, name, tag, classes = {[arch] = true}, thumb, full (Texture2D paths), crop = box | nil,
-- style, sig = {[arch] = presetId}, specialist = {[arch] = rank}, path (RacerDef object path), index, flags}.
-- UI v2 (§12.2): tile = the SCENARIOS poster path | nil (SEBULBA, pods); baseName = the name without the Pod Tour
-- suffix ("BEN QUADINAROS"), rankTag = "AGED" for the Aged five, else nil: the suffix moves to the card's rank line
-- ("TOP · AGED · 3 / 8", §9.7) and never joins the poster name. name keeps "BEN QUADINAROS · AGED" (classic cards).
local BY_ID = {}
local TWINS = {}   -- CharacterTag -> ids of that character (SEBULBA x3, the Aged pod pilots and their younger selves)
for i, e in ipairs(M.ALL) do
    local set = {}
    for _, a in ipairs(e.classes) do set[a] = true end
    e.classes = set
    e.thumb = CHAR .. e.thumb .. "." .. e.thumb
    e.full = CHAR .. e.full .. "." .. e.full
    if e.tile then e.tile = SCEN .. e.tile .. "." .. e.tile end
    if e.aged then
        e.baseName = e.name:match("^(.-)%s*\194\183%s*AGED$") or e.name     -- "·" = UTF-8 C2 B7
        e.rankTag = "AGED"
    else
        e.baseName = e.name
    end
    if e.crop then e.crop = box(e.crop[1], e.crop[2], e.crop[3], e.crop[4]) end
    e.sig = e.sig or {}
    e.specialist = e.specialist or {}
    e.path = DEF_DIR .. e.id .. "." .. e.id
    e.index = i
    BY_ID[e.id] = e
    TWINS[e.tag] = TWINS[e.tag] or {}
    TWINS[e.tag][#TWINS[e.tag] + 1] = e.id
end

-- Display order per class (§4.1). Speeder classes: the 13 PvpPlayable pilots, then SEBULBA (Skimmer only). Pods: the
-- 6 pod pilots, SHADE and KESTAR (both have a pod preset, KESTAR a pod pose), then the speeder rivals
-- (cfg.PilotPodRivals) and the Aged five (cfg.PilotPodAged). M.list filters these with M.allowed.
local ORDER_SPEEDER, ORDER_POD = {}, {}
for _, e in ipairs(M.ALL) do if not e.pod then ORDER_SPEEDER[#ORDER_SPEEDER + 1] = e end end
for _, e in ipairs(M.ALL) do if e.pod and not e.aged then ORDER_POD[#ORDER_POD + 1] = e end end
ORDER_POD[#ORDER_POD + 1] = BY_ID[SHADE]
ORDER_POD[#ORDER_POD + 1] = BY_ID["DA_Racer_Antagonist"]
for _, e in ipairs(M.ALL) do if e.podRival then ORDER_POD[#ORDER_POD + 1] = e end end
for _, e in ipairs(M.ALL) do if e.aged then ORDER_POD[#ORDER_POD + 1] = e end end

local function entry(e)
    if type(e) == "string" then return BY_ID[e] end
    if type(e) == "table" then return e end
    return nil
end

---------------------------------------------------------------------------------------------------- lists
-- cfg.PilotExtras lists the id (ids or RacerDef object paths; false = no extras).
local function inExtras(id)
    local list = opt("PilotExtras", { "DA_Racer_Mentor" })
    if type(list) ~= "table" then return false end
    for _, nm in ipairs(list) do
        if type(nm) == "string" and (nm == id or nm:match("([%w_]+)$") == id) then return true end
    end
    return false
end

-- May this pilot (entry or id) race class `arch`? Seated-pose gating plus the cfg gates (§2.8).
function M.allowed(e, arch)
    e, arch = entry(e), tonumber(arch)
    if not e or arch == nil then return false end
    if e.podRival and arch == 1 then return opt("PilotPodRivals", false) == true end
    if not e.classes[arch] then return false end
    if e.extra and not inExtras(e.id) then return false end
    if e.aged and opt("PilotPodAged", false) ~= true then return false end
    return true
end

-- The roster of a class in display order (Car / Bike 13, Skimmer 14, Plane 8 with the default config). A new list
-- per call; the entries are shared (do not modify them).
function M.list(arch)
    arch = tonumber(arch)
    local out = {}
    for _, e in ipairs(arch == 1 and ORDER_POD or ORDER_SPEEDER) do
        if M.allowed(e, arch) then out[#out + 1] = e end
    end
    return out
end

function M.byId(id)
    return type(id) == "string" and BY_ID[id] or nil
end

-- Position of a pilot in the class roster: i (nil when not offered), n = roster size (the PILOT stage's "4 / 13").
function M.indexOf(arch, id)
    local list = M.list(arch)
    for i, e in ipairs(list) do
        if e.id == id then return i, #list end
    end
    return nil, #list
end

---------------------------------------------------------------------------------------------------- per pilot
-- The pilot's signature preset id for the class, only when vehicles.lua knows that preset; nil = "ANY <CLASS>".
function M.signature(e, arch)
    e, arch = entry(e), tonumber(arch)
    local id = e and arch and type(e.sig) == "table" and e.sig[arch]
    if id and V.presetById(arch, id) then return id end
    return nil
end

-- perkdata STYLES / KITS key of the pilot's racer style (§4.1): one key for every class it races; SHADE's when unknown.
function M.styleKey(e, arch)
    e = entry(e)
    local s = e and e.style
    if type(s) == "table" then s = s[tonumber(arch)] end
    if type(s) == "string" and s ~= "" then return s end
    return "Cooling"
end

-- UV crop of the full-body render for the figure windows (§3.3): pod figures use their box in every width class;
-- the humanoid pilots the whole frame (common scale), or u 0.20-0.80 in the narrow 4-player class "N".
-- Shared tables: do not modify.
local FULL, NARROW = box(0, 0, 1, 1), box(0.20, 0, 0.80, 1)
function M.crop(e, widthClass)
    e = entry(e)
    if e and e.crop then return e.crop end
    if widthClass == "N" then return NARROW end
    return FULL
end

---------------------------------------------------------------------------------------------------- uniqueness
-- ControllerId of the other human who holds this pilot (or a twin of it: another RacerDef of the same character,
-- e.g. an Aged pod pilot and its younger self), nil when it is free. taken = {[pilotId] = ctrlId} of the humans'
-- current picks at any stage; ctrlId = the asking player (its own pick never blocks it; optional). cfg.PilotUnique
-- false: nothing is ever held; cfg.PilotShareShade: SHADE is never held (§2.8). The roster's "P3" tags use this too.
function M.holder(e, taken, ctrlId)
    e = entry(e)
    if not e or type(taken) ~= "table" then return nil end
    if opt("PilotUnique", true) == false then return nil end
    if e.id == SHADE and opt("PilotShareShade", false) == true then return nil end
    for _, id in ipairs(TWINS[e.tag] or { e.id }) do
        local c = taken[id]
        if c ~= nil and c ~= ctrlId then return c end
    end
    return nil
end

-- Next (dir >= 0) / previous (dir < 0) offered pilot nobody else holds, wrapping around the roster; nil when no other
-- one is free (the caller keeps curId). A curId not in the roster (class change) starts at the first / last pilot.
function M.step(arch, curId, dir, taken, ctrlId)
    local list = M.list(arch)
    local n = #list
    if n == 0 then return nil end
    local d = (tonumber(dir) or 1) < 0 and -1 or 1
    local cur = nil
    for i, e in ipairs(list) do
        if e.id == curId then cur = i; break end
    end
    if not cur then cur = d > 0 and 0 or (n + 1) end
    for k = 1, n do
        local e = list[((cur - 1 + d * k) % n) + 1]
        if e.id ~= curId and M.holder(e, taken, ctrlId) == nil then return e end
    end
    return nil
end

-- remembered = pilotId | {pilotId, ...} (nil holes allowed) -> ids in index order.
local function rememberedIds(remembered)
    if type(remembered) == "string" then return { remembered } end
    if type(remembered) ~= "table" then return {} end
    local keys, out = {}, {}
    for k in pairs(remembered) do if math.type(k) == "integer" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = remembered[k] end
    return out
end

-- Default pilot of a player for class `arch` (§2.4, first rule that applies): the remembered picks in order (session
-- memory, then LastRaceRacers[ctrlId]) when offered and free -> P1: SHADE (cfg.PilotP1Default = "favourite": P1's
-- multiplayer favourite first, V-PIL-08) -> guests: the first free class specialist (Car ARY, SOREN, NIK, KESTAR;
-- Bike KATJA, SEN, BIDDY, MALIS; Skimmer GRIFF, GOLI, FOLA, LYREN; pods the 6 pod pilots) -> the first free pilot of
-- the roster. Never nil: with every pilot held, the roster's first one (shared).
function M.defaultFor(arch, isP1, taken, remembered, ctrlId)
    arch = tonumber(arch)
    taken = type(taken) == "table" and taken or {}
    local function usable(id)
        local e = type(id) == "string" and BY_ID[id] or nil
        if e and M.allowed(e, arch) and M.holder(e, taken, ctrlId) == nil then return e end
        return nil
    end
    for _, id in ipairs(rememberedIds(remembered)) do
        local e = usable(id)
        if e then return e end
    end
    local list = M.list(arch)
    if isP1 then
        local e = nil
        if opt("PilotP1Default", "shade") == "favourite" then e = usable(M.favourite()) end
        e = e or usable(SHADE)
        if e then return e end
    else
        local best, bestRank = nil, math.huge
        for _, e in ipairs(list) do
            local r = e.specialist[arch]
            if r and r < bestRank and M.holder(e, taken, ctrlId) == nil then best, bestRank = e, r end
        end
        if best then return best end
    end
    for _, e in ipairs(list) do
        if M.holder(e, taken, ctrlId) == nil then return e end
    end
    return list[1] or BY_ID[SHADE]
end

---------------------------------------------------------------------------------------------------- game objects
-- RacerDef UObject of a pilot (entry or id), game thread only: StaticFindObject finds the resident asset, U.obj falls
-- back to LoadAsset. nil when unresolved (logged once). Used by perkapply.assignPilots (recipe Pilot +8,
-- GfnPlayerState.Pilot +0x3D0).
function M.def(e)
    e = entry(e)
    if not e then return nil end
    local o = U.obj(e.path)
    if U.ok(o) then return o end
    U.logOnce("pilots.def." .. e.id, TAG, "RacerDef %s not resolvable", e.path)
    return nil
end

-- P1's multiplayer favourite pilot id (GfnPlayerController.PvpFlowComponent +0x8a8 -> PvpFlowComponent.DefaultPilot
-- +0x188, both hard ObjectProperty in the JMAP), nil when unset, unreadable or not in the catalog. Game thread; read
-- only: SetDefaultPilot_OnClient / Server_SelectPilot would change P1's online state (pilot-select.md §6.8 #5).
-- VERIFY(V-PIL-08): valid in the main menu (log line "P1 favourite pilot"); cfg.PilotP1Default = "shade" otherwise.
function M.favourite()
    local name = nil
    U.try(TAG, function()
        local pc = U.p1()
        if not U.ok(pc) then return end
        local flow = pc.PvpFlowComponent
        if not U.ok(flow) then return end
        local d = flow.DefaultPilot
        if U.ok(d) then name = d:GetFName():ToString() end
    end)
    U.logOnce("pilots.favourite." .. tostring(name), TAG, "P1 favourite pilot: %s (V-PIL-08)", tostring(name))
    if name and BY_ID[name] then return name end
    return nil
end

-- AI de-duplication order for perkapply.assignPilots (§6 step 6.2): an AI racer that drew a human's pilot gets the
-- first free id of CharacterList.Opponents (the AI pool, decoded order PS §1.2), then KESTAR, then SEBULBA (Skimmer /
-- Plane), then the pod pilots (Plane). Car and Bike stop at KESTAR: SEBULBA and the pod aliens have no seated pose
-- there. In pods SEBULBA is DA_PlaneRacer_Nesodon, the only SEBULBA a human can hold in a pod race, so an id check
-- never hands an AI a second SEBULBA.
local OPPONENTS = { "DA_Racer_Mercenary", "DA_Racer_ElegantProfessional", "DA_Racer_Star", "DA_Racer_InnerHonour",
                    "DA_Racer_Thrall", "DA_Racer_Ghost", "DA_Racer_Rager", "DA_Racer_Nomad", "DA_Racer_Veteran",
                    "DA_Racer_QuietStrength", "DA_Racer_Protege" }
local POD_REPLACEMENTS = { "DA_PlaneRacer_Nesodon", "DA_PlaneRacer_Cabbage", "DA_PlaneRacer_Celery",
                           "DA_PlaneRacer_Garlic", "DA_PlaneRacer_Onion", "DA_PlaneRacer_Pepper" }
function M.replacementOrder(arch)
    arch = tonumber(arch)
    local out = {}
    for _, id in ipairs(OPPONENTS) do out[#out + 1] = id end
    out[#out + 1] = "DA_Racer_Antagonist"
    if arch == 3 then out[#out + 1] = "DA_Racer_Mentor" end
    if arch == 1 then
        for _, id in ipairs(POD_REPLACEMENTS) do out[#out + 1] = id end
    end
    return out
end

-- "pilots Car 13 · Bike 13 · Skimmer 14 · Plane 8" (test.cmd / diag; V-RC-09 class gating).
function M.status()
    local parts = {}
    for _, c in ipairs(V.CLASSES) do parts[#parts + 1] = c.key .. " " .. #M.list(c.arch) end
    return "pilots " .. table.concat(parts, " · ")
end

return M
