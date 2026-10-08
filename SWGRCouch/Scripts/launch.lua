-- launch.lua (G4 Players & launch) - start the chosen race with every local and remote human already present
-- as a PlayerController (the recipe builder walks UWorld.PlayerControllerList inside LaunchCustomRace [RB§4]).
-- ARCHITECTURE.md §1.5, §4.2 `launch`.
--
-- Verified (reflect-func-all.py / reflect-types.py on the shipping exe):
--   AFrontEndGameMode:LaunchCustomRace(Object vehicleType, Object gameMode, Object track, Struct trackConditions,
--     Object vehicleBuild, Object debugVehicleBuild)  flags 0x4020401 - 6 params, FGameplayTag = {Name TagName}.
--     Native body [RB§3.1]: early return if vehicleType/gameMode/track is null or both builds are null; else
--     GfnGameInstance.PrimaryFlow = QuickRace(2) first, recipe, builds, ChangeState(LaunchingQuickRace=4).
--   UGfnGameInstance: Enum<EGfnPrimaryFlow> PrimaryFlow @+0x398 (Unknown=0, QuickRace=2).
--   UGameModeVariantDef: Struct<RaceGridMakeup> GridMakeup @+0x48 = {Text PlayerFacingName, Array Entries};
--     FRaceGridMakeupEntry (2 bytes) = {Enum<ERaceGridEntryType> EntryType, Byte NumEntrants}; PlayerChoice = 4.
--   UVehicleArchetype: Enum<EVehicleArchetype> Archetype @+0x30.
--   UTrackDef: Array<Struct<TrackConditionConfig>> TrackConditionDataLayers @+0x188; FTrackConditionConfig.Tag.
--   UPlayerRaceEventComponent:Server_SelectVehicle(Enum archetype)  (NetServer Reliable BlueprintCallable, 1 param).
--
-- Deviations from §4.2 `launch`: extra public M.prepareExternal(choice) (devscreen bookkeeping, called by builder);
-- the refusal branch also calls join.open/join.isFrozen and undoes the grid patch and St.ui.returnToTab.
--
-- Race setup (2026-10-07 user feedback 8/9, notes/research/race-setup.md): M.plan(choice) reads choice.setup
-- (setup.lua) or derives one (dev panel); prepareGrid rewrites the GameModeVariantDef's GridMakeup.Entries in memory
-- to the class limit (12 speeders / 8 pods, humans included) before LaunchCustomRace; applyRecipe then edits
-- UEventRecipeSubsystem.ActiveRecipe.RecipeState.Racers (FRecipeRacerSetup {Player @0, Pilot @8, VehicleType @0x10,
-- VehicleCustomisation @0x80}): humans get their chosen preset, AI of a single-class mode their class, guests their
-- build (VehicleBuildStateFunctions:SetVehicleBuildStateFromBuildDef(out Struct VehicleBuildState, VehicleBuildDef,
-- GfnGameInstance, Enum archetype), static); in the race world PlayerVehicleCustomisationComponent:
-- Client_SetOverrideVehicleRecipe(Class) repeats the human presets (LOADING / PRERACE). All signatures: runtime JMAP.

local C        = require("consts")
local cfg      = require("config")
local settings = require("settings")
local St       = require("state")
local U        = require("util")

local M = {}
local TAG = "launch"

local listenerRegistered = false
local undoPrelaunch                                    -- forward declaration (defined before start)
local assignGuestPilots                                -- defined before applyRecipe
local dormantOk = { untilMs = 0, text = nil }          -- second START within 5 s accepts the un-joined guests

local function status(text)
    U.log(TAG, "%s", text)
    St.emit("status", text)
end

local function builderMod() return U.mod("builder") end

---------------------------------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------------------------------

-- -> ok, reasonText
function M.canStart()
    if St.phase ~= "FRONTEND" then
        return false, "START RACE ONLY WORKS IN THE MAIN MENU"
    end
    if St.launch.pending then
        return false, "LAUNCHING…"
    end
    local b = builderMod()
    if not b.isValid(St.race.choice) then
        b.restoreFromSettings()
        if not b.isValid(St.race.choice) then
            return false, "CHOOSE A RACE FIRST"
        end
    end
    local gm = U.gm()
    if not (U.ok(gm) and U.isA(gm, "FrontEndGameMode")) then
        -- clients have no AuthorityGameMode; BP_FrontEndGameMode_C is a subclass [MT§8 #4]
        if U.netMode() == "client" then return false, "THE HOST STARTS THE RACE" end
        return false, "FRONT-END GAME MODE NOT FOUND"
    end
    local mode = settings.get("NetMode")
    if U.netMode() == "client" or mode == "join" then
        return false, "THE HOST STARTS THE RACE"
    end
    if mode == "host" and not U.mod("net").isListening() then
        return false, "START HOSTING FIRST"
    end
    return true, nil
end

-- -> slots (sum of NumEntrants, nil for an empty makeup = native default), humans (local + remote)
function M.gridInfo(choice)
    local slots = nil
    U.try(TAG, function()
        local entries = choice.gameMode.GridMakeup.Entries
        local n = entries:GetArrayNum()
        if n > 0 then
            slots = 0
            for i = 1, n do
                slots = slots + (tonumber(entries[i].NumEntrants) or 0)
            end
        end
    end)
    local remote = 0
    U.try(TAG, function() remote = #U.mod("roster").remoteHumans() end)
    -- Every LocalPlayer travels (a dormant guest accepted with a second START cannot be removed and gets a
    -- PlayerController + PlayerState in the race too): count them all, not only the joined ones.
    local locals = U.mod("join").localHumanCount()
    U.try(TAG, function() locals = math.max(locals, #U.localPlayers()) end)
    local humans = locals + remote
    return slots, humans
end

-- FGameplayTag argument for LaunchCustomRace (§4.2 conditionArg).
function M.conditionArg(choice)
    if cfg.ConditionPassMode == "trackdefault" then
        local tag = NAME_None
        U.try(TAG, function()
            local arr = choice.track.TrackConditionDataLayers
            if arr:GetArrayNum() > 0 then tag = arr[1].Tag.TagName end
        end)
        return { TagName = tag }
    end
    if type(choice.condition) == "string" and choice.condition ~= "" then
        return { TagName = U.fname(choice.condition) }
    end
    return { TagName = NAME_None }
end

---------------------------------------------------------------------------------------------------
-- In-memory grid growth (cfg.GrowGridInMemory, V-LCH-04) and its undo
---------------------------------------------------------------------------------------------------

-- {{t = EntryType, n = NumEntrants}, ...} of a FRaceGridMakeup.Entries TArray.
local function readEntries(entries)
    local out = {}
    for i = 1, entries:GetArrayNum() do
        local e = entries[i]
        out[i] = { t = tonumber(e.EntryType) or 0, n = tonumber(e.NumEntrants) or 0 }
    end
    return out
end

local function entriesText(list)
    local parts = {}
    for _, e in ipairs(list) do
        parts[#parts + 1] = string.format("%s x%d", C.enumName(C.E.GridEntry, e.t), e.n)
    end
    return #parts > 0 and table.concat(parts, " + ") or "(empty)"
end

-- Replace the whole Entries array by list. UE4SS grows a TArray when an index past the end is read (AddZeroed,
-- notes/research/ue4ss-api.md §8, used deliberately here) and Empty() clears it.
-- VERIFY(V-SET-06): the array reads back as written (logged); a mismatch raises and the caller falls back.
local function writeEntries(entries, list)
    if entries:GetArrayNum() ~= #list then entries:Empty() end
    for i, e in ipairs(list) do
        local el = entries[i]
        el.EntryType = e.t
        el.NumEntrants = e.n
    end
    local back = readEntries(entries)
    if #back ~= #list then error(string.format("Entries has %d element(s) after writing %d", #back, #list)) end
    for i, e in ipairs(list) do
        if back[i].t ~= e.t or back[i].n ~= e.n then error("Entries element " .. i .. " did not take") end
    end
end

function M.restoreGridPatch()
    local p = St.launch.gridPatch
    if not p then return end
    St.launch.gridPatch = nil
    U.try(TAG, function()
        local gmv = p.gmv
        -- after a hot reload the record holds only the asset path (launch.restoreShared): find-only, the patched
        -- asset is in memory or the patch is gone with it
        if not U.ok(gmv) and type(p.path) == "string" and p.path ~= "" then
            local okF, o = pcall(StaticFindObject, p.path)
            gmv = okF and o or nil
        end
        if not U.ok(gmv) then return end
        p.gmv = gmv
        local entries = p.gmv.GridMakeup.Entries
        if p.orig then
            writeEntries(entries, p.orig)
            U.log(TAG, "grid patch undone: %s = %s", U.pathOf(p.gmv), entriesText(p.orig))
        elseif p.entry >= 1 and p.entry <= entries:GetArrayNum() then
            entries[p.entry].NumEntrants = p.old
            U.log(TAG, "grid patch undone: entry %d NumEntrants=%d", p.entry, p.old)
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- Race setup plan (setup.lua): full grid of the chosen class, per-player vehicles and builds.
-- notes/research/race-setup.md §4-§6. Every step is optional and logged; a failure leaves the game's own result.
---------------------------------------------------------------------------------------------------

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local function V() return U.mod("vehicles") end

-- plan = {arch, cls, single, grid ("max"|"native"), maxRacers, players = {[pnum] = {presetId, buildPath}}}.
-- A choice from the dev panel / settings.txt has no c.setup: setup.deriveSetup makes one (grid = class limit for
-- GMV_Race, so the dev panel gets the full grid too).
function M.plan(choice)
    local s = type(choice) == "table" and choice.setup or nil
    if type(s) ~= "table" then
        local ok, d = pcall(function() return U.mod("setup").deriveSetup(choice) end)
        s = ok and d or {}
    end
    local arch = tonumber(s.arch)
    if arch == nil then pcall(function() arch = tonumber(choice.archetype.Archetype) end) end
    return { arch = arch, cls = V().classByArch(arch), single = s.single == true, grid = s.grid or "native",
             maxRacers = tonumber(s.maxRacers), players = s.players or {} }
end

-- Full grid (user feedback item 9). Humans are inside NumEntrants (2026-10-07 race: GMV_Race "PlayerChoice x5" =
-- 2 humans + 3 AI). cfg.SetupGridMode:
--   "typed" (default): PlayerChoice x<humans> + <class> x<max - humans>: the AI slots are typed, so the recipe
--      builder itself gives every AI the chosen class (as GMV_MultiVehicleRace's Car/Bike/Skimmer entries do);
--   "playerchoice": PlayerChoice x<max> (the AI then keep their pilot's preferred class: fixed in the recipe below);
--   "off": the asset's own grid.
-- VERIFY(V-SET-06): the recipe after the launch lists <max> racers, every AI of the class (log "recipe:").
local function prepareGrid(choice, plan, humans)
    local mode = opt("SetupGridMode", "typed")
    if mode == "off" or plan.grid ~= "max" or not plan.maxRacers or plan.arch == nil then return false end
    local gmv = choice.gameMode
    local entries = gmv.GridMakeup.Entries
    local orig = readEntries(entries)
    local total = math.min(255, math.max(plan.maxRacers, humans))
    local want
    if mode == "typed" and total > humans then
        want = { { t = C.E.GridEntry.PlayerChoice, n = humans }, { t = plan.arch, n = total - humans } }
    else
        want = { { t = C.E.GridEntry.PlayerChoice, n = total } }
    end
    M.init()                                           -- the FRONTEND listener that undoes the patch (idempotent)
    M.restoreGridPatch()                               -- never stack two patches on one asset
    St.launch.gridPatch = { gmv = gmv, orig = orig, path = U.pathOf(gmv) }   -- path: persisted for a hot reload
    local ok, err = pcall(writeEntries, entries, want)
    if not ok and #want > 1 then
        U.warn(TAG, "typed grid not writable (%s): PlayerChoice x%d instead", tostring(err), total)
        want = { { t = C.E.GridEntry.PlayerChoice, n = total } }
        ok, err = pcall(writeEntries, entries, want)
    end
    if not ok then
        U.warn(TAG, "grid patch failed (%s): the asset's grid is used", tostring(err))
        M.restoreGridPatch()
        return false
    end
    U.log(TAG, "grid: %s -> %s (%d human(s), in memory, undone in the front end)", entriesText(orig),
        entriesText(want), humans)
    return true
end

-- Local humans' PlayerStates: key -> pnum (P1 = 1, joined guests = their pnum).
local function localHumanPS()
    local out = {}
    pcall(function()
        local ps = U.p1().PlayerState
        if U.ok(ps) then out[U.key(ps)] = 1 end
    end)
    for _, e in ipairs(U.mod("join").joinedList()) do
        pcall(function()
            local ps = e.pc.PlayerState
            if U.ok(ps) then out[U.key(ps)] = e.pnum end
        end)
    end
    return out
end

-- Preset class for an AI racer forced into another class: the pilot's own preference for that class
-- (RacerDef.PreferredCustomisationForVehicleArchetype, a TMap read with UE4SS's TMap:ForEach), else the next base
-- model of the class not used yet. VERIFY(V-SET-09): TMap ForEach works on this map (else round robin only).
local function aiPreset(pilot, arch, used)
    local found = nil
    pcall(function()
        pilot.PreferredCustomisationForVehicleArchetype:ForEach(function(k, v)
            local key = U.unwrap(k)
            if tonumber(key) == arch then found = U.unwrap(v) end
        end)
    end)
    if U.ok(found) and not used[U.key(found)] then return found end
    for _, p in ipairs(V().presets(arch)) do
        if not p.owner then
            local cls = V().presetClass(p)
            if cls and not used[U.key(cls)] then return cls end
        end
    end
    if U.ok(found) then return found end
    local first = V().presets(arch)[1]
    return first and V().presetClass(first) or nil
end

-- Copy of a VehicleBuildState computed by the game (VehicleBuildStateFunctions:SetVehicleBuildStateFromBuildDef, static,
-- struct out-param = a Lua table filled in place) into the PlayerState's entry.
-- SCALARS ONLY by default. The table's ARRAY fields are NOT values: UE4SS (3f4037d2, LuaUObject.cpp push_arrayproperty)
-- fills each element with Operation::GetParam, i.e. RemoteUnrealParam / LocalUnrealParam wrappers pointing into the
-- out buffer. Assigning such a table back to a UPROPERTY array goes through unchecked casts (LuaMadeSimple
-- get_userdata = plain static_cast): AbilitySlots (TArray<TSubclassOf>) would store the element-slot ADDRESS as a
-- UClass* in a live build state (crash at the next GC / ability spawn). cfg.SetupPerPlayerBuildArrays = true copies
-- the arrays too, but only from a clean Lua list built element by element (:get() unwrap, every element checked)
-- and only once EVERY array validated. Even then a throw while UE4SS writes element n of an array would leave a
-- zero-filled element (the table-to-array path AddZeroed's before each Set), hence the default off.
-- VERIFY(V-SET-10): the log shows "build P2: ... applied" and P2's car has the chosen tier in the race (scalars:
-- VehicleBuildDef / PowerLevel; with ...Arrays = true also the slots).
local BUILD_ARRAYS = { "UpgradeSlots", "AbilitySlots", "AffixSlots", "PlaneOnlyAffixSlots", "AffixSlotOwners" }
local BUILD_CLASS_ARRAYS = { AbilitySlots = true }
local BUILD_SCALARS = { "PawnOverride", "CrashAbility", "PowerLevelMaxRemainder", "OverridenPowerLevel", "PowerLevel",
                        "BaseResilienceOverride", "UnlockedAffixSlots", "MaximumAffixSlots", "RamjetInstalled",
                        "CriticalMalfunctions", "BasicBoostType", "UseHealth", "VehicleBuildDef" }

local function userdataType(v)
    if type(v) ~= "userdata" then return type(v) end
    local ok, t = pcall(function() return v:type() end)
    return ok and tostring(t) or "?"
end

-- out-param array field -> plain Lua list of real values, or error (nothing is written by this function).
local function cleanArray(f, src)
    if type(src) ~= "table" then error(f .. " is not a table (" .. userdataType(src) .. ")") end
    local list, classCls = {}, nil
    for i, v in ipairs(src) do
        local x = U.unwrap(v)
        local t = userdataType(x)
        if t == "RemoteUnrealParam" or t == "LocalUnrealParam" or type(x) ~= "userdata" then
            error(string.format("%s element %d not unwrapped (%s)", f, i, t))
        end
        if BUILD_CLASS_ARRAYS[f] then
            classCls = classCls or StaticFindObject("/Script/CoreUObject.Class")
            local okC, isCls = pcall(function() return U.ok(x) and x:IsA(classCls) end)
            if not (okC and isCls) then error(string.format("%s element %d is not a UClass", f, i)) end
        elseif t ~= "UScriptStruct" then
            error(string.format("%s element %d is a %s, not a UScriptStruct", f, i, t))
        end
        list[i] = x
    end
    return list
end

local function applyBuild(ps, buildObj, arch, pnum)
    local lib = StaticFindObject("/Script/Griffin.Default__VehicleBuildStateFunctions")
    if not U.ok(lib) then error("VehicleBuildStateFunctions CDO not found") end
    local st = {}
    lib:SetVehicleBuildStateFromBuildDef(st, buildObj, U.gi(), arch)   -- (out Struct, Object, Object, Enum)
    if st.VehicleBuildDef == nil and st.PowerLevel == nil then error("SetVehicleBuildStateFromBuildDef filled nothing") end
    -- every array validated BEFORE anything is written (an error here leaves the shared build untouched)
    local arrays = nil
    if opt("SetupPerPlayerBuildArrays", false) == true then
        arrays = {}
        for _, f in ipairs(BUILD_ARRAYS) do
            if st[f] ~= nil then arrays[f] = cleanArray(f, st[f]) end
        end
    end
    local scalars = {}
    for _, f in ipairs(BUILD_SCALARS) do
        local v = st[f]
        if v ~= nil then
            local t = userdataType(v)
            if t == "RemoteUnrealParam" or t == "LocalUnrealParam" then v = U.unwrap(v) end
            scalars[f] = v
        end
    end
    local vbs = ps.RacerBuildState.VehicleBuilds
    local n, done = vbs:GetArrayNum(), 0
    for k = 1, n do
        local el = vbs[k]
        if n == 1 or tonumber(el.BuildArchetype) == arch then
            if arrays then
                for _, f in ipairs(BUILD_ARRAYS) do
                    if arrays[f] ~= nil then el[f] = arrays[f] end
                end
            end
            for _, f in ipairs(BUILD_SCALARS) do
                if scalars[f] ~= nil then el[f] = scalars[f] end
            end
            done = done + 1
        end
    end
    if done == 0 then error(string.format("no VehicleBuilds entry for archetype %d (%d entries)", arch, n)) end
    U.log(TAG, "build P%d: %s applied to %d VehicleBuilds entr%s (%s)", pnum, U.pathOf(buildObj), done,
        done == 1 and "y" or "ies", arrays and "scalars + arrays" or "scalars only")
end

-- Feedback 5: every local human had P1's pilot (diag-race.txt: recipe [1] and [2] pilot=DA_Racer_DarkEnigma), so a
-- screen showing the pilot (grid intro, podium, portraits) showed one racer twice. Each guest (P2+) gets the first
-- RacerDef of cfg.GuestPilots that no racer of the recipe uses yet (AI included); P1 keeps its own. Written to
-- FRecipeRacerSetup.Pilot (+8) and GfnPlayerState.Pilot (+0x3D0, runtime JMAP). cfg.GuestPilots = false: off.
-- VERIFY(V-NAM-03): the "pilots:" log line, and P2's racer model/portrait differs from P1's in the race.
local PILOT_DIR = "/Game/Griffin/Narrative/CharacterDefs/Racers/"
assignGuestPilots = function(racers, n, humans)
    local list = opt("GuestPilots", false)
    if type(list) ~= "table" or #list == 0 then return end
    local used = {}
    for i = 1, n do
        pcall(function()
            local pl = racers[i].Pilot
            if U.ok(pl) then used[pl:GetFName():ToString()] = true end
        end)
    end
    local guests = {}
    for i = 1, n do
        local r = racers[i]
        local ps = r.Player
        local pnum = U.ok(ps) and humans[U.key(ps)] or nil
        if pnum and pnum > 1 then guests[#guests + 1] = { r = r, ps = ps, pnum = pnum } end
    end
    table.sort(guests, function(a, b) return a.pnum < b.pnum end)
    local out = {}
    for _, g in ipairs(guests) do
        local def, name = nil, nil
        for _, nm in ipairs(list) do
            if type(nm) == "string" and not used[nm] then
                local path = nm:find("/", 1, true) and nm or (PILOT_DIR .. nm .. "." .. nm)
                local o = U.obj(path)
                if U.ok(o) then def, name = o, nm; break end
            end
        end
        if def then
            used[name] = true
            g.r.Pilot = def
            local okPS = pcall(function() g.ps.Pilot = def end)
            local back = "?"
            pcall(function() back = g.r.Pilot:GetFName():ToString() end)
            out[#out + 1] = string.format("P%d=%s%s", g.pnum, back, okPS and "" or " (PlayerState.Pilot refused)")
        else
            out[#out + 1] = string.format("P%d=(no free pilot)", g.pnum)
        end
    end
    if #out > 0 then U.log(TAG, "pilots: %s", table.concat(out, " ")) end
end

-- After an accepted LaunchCustomRace (the recipe is built synchronously; travel happens on a later tick):
--   humans: VehicleType = the class, VehicleCustomisation = their chosen preset (FRecipeRacerSetup +0x80);
--   AI in a single-class mode: class forced (the 2026-10-07 race had DA_Racer_Ghost's preferred Skimmer in a
--   Landspeeder race: AI in PlayerChoice slots use their pilot's PreferredVehicleType) with a matching preset;
--   per-player builds (cfg.SetupPerPlayerBuild).
-- VERIFY(V-SET-08): FRecipeRacerSetup fields written through UE4SS struct-element access stick (the log reads them back)
-- and the race spawns those vehicles.
local function applyRecipe(choice, plan)
    local arch = plan.arch
    if arch == nil then return end
    local rs = U.giSubsystem("EventRecipeSubsystem")
    if not U.ok(rs) or not U.ok(rs.ActiveRecipe) then U.warn(TAG, "recipe: no ActiveRecipe after the launch"); return end
    local racers = rs.ActiveRecipe.RecipeState.Racers
    local n = racers:GetArrayNum()
    local humans = localHumanPS()
    local used, nh, nai, fixed, styled = {}, 0, 0, 0, {}
    -- humans first, so the AI fallback avoids the models the players took
    for i = 1, n do
        local r = racers[i]
        local ps = r.Player
        local pnum = U.ok(ps) and humans[U.key(ps)] or nil
        if pnum then
            nh = nh + 1
            U.try(TAG, function()
                if tonumber(r.VehicleType) ~= arch then r.VehicleType = arch end
                local pick = plan.players[pnum]
                local pr = pick and pick.presetId and V().presetById(arch, pick.presetId) or nil
                local cls = pr and V().presetClass(pr) or nil
                if cls then
                    r.VehicleCustomisation = cls
                    used[U.key(cls)] = true
                    styled[#styled + 1] = string.format("P%d=%s", pnum, pr.name)
                end
            end)
        end
    end
    -- AI = not a local human and either flagged a bot or no remote human is connected (a remote human's racer is
    -- never re-classed: it keeps the launch archetype like ours)
    local remote = 0
    pcall(function() remote = #U.mod("roster").remoteHumans() end)
    for i = 1, n do
        local r = racers[i]
        local ps = r.Player
        local isAI = U.ok(ps) and humans[U.key(ps)] == nil and (ps.bIsABot == true or remote == 0)
        if isAI then
            nai = nai + 1
            if plan.single and tonumber(r.VehicleType) ~= arch then
                U.try(TAG, function()
                    local cls = aiPreset(r.Pilot, arch, used)
                    r.VehicleType = arch
                    if cls then r.VehicleCustomisation = cls; used[U.key(cls)] = true end
                    fixed = fixed + 1
                end)
            end
        end
    end
    U.log(TAG, "recipe: %d racer(s): %d local human(s) [%s], %d AI, %d AI moved to %s", n, nh, table.concat(styled, " "),
        nai, fixed, C.enumName(C.E.Archetype, arch))
    U.try(TAG, assignGuestPilots, racers, n, humans)
    -- per-player builds (P1's is the launch build already)
    if opt("SetupPerPlayerBuild", true) == false then return end
    local shared = U.ok(choice.build) and U.pathOf(choice.build) or ""
    for key, pnum in pairs(humans) do
        local pick = plan.players[pnum]
        if pick and pick.buildPath and pick.buildPath ~= "" and pick.buildPath ~= shared then
            local ok, err = pcall(function()
                local b = U.obj(pick.buildPath)
                if not U.ok(b) then error("build not found: " .. pick.buildPath) end
                local ps = nil
                for i = 1, n do
                    local p2 = racers[i].Player
                    if U.ok(p2) and U.key(p2) == key then ps = p2 end
                end
                if not ps then error("no recipe racer") end
                applyBuild(ps, b, arch, pnum)
            end)
            if not ok then U.warn(TAG, "build P%d not applied (%s): P%d races the shared build", pnum, tostring(err), pnum) end
        end
    end
end

-- In the race world: the same preset as a PlayerState override (PlayerVehicleCustomisationComponent:
-- Client_SetOverrideVehicleRecipe(Class), NetClient RPC: runs locally for local players on the server/standalone).
-- Applied during LOADING only (before the grid spawns): on the LOADING edge and retried from the MAIN race tick
-- (M.raceTick) while the phase is LOADING, until every local human with a pick has been overridden (the new world's
-- PlayerState / component may not exist yet on the edge). On PRERACE the cars exist and are possessed: an override
-- there could rebuild/respawn the pawn under inputfix/hud/takeover/nametags (V-SET-11 unknown), so PRERACE only LOGS
-- who never got it, unless cfg.SetupInRaceOverridePrerace = true. cfg.SetupInRaceOverride = false skips it all.
-- VERIFY(V-SET-11): with the recipe write alone the humans already get their models (then this is redundant); a
-- "first success on PRERACE" line means the LOADING retries never found the component.
local function overrideList()
    local list = { { pnum = 1, pc = U.p1() } }
    for _, e in ipairs(U.mod("join").joinedList()) do list[#list + 1] = { pnum = e.pnum, pc = e.pc } end
    return list
end

-- -> number of local humans with a pick still waiting for their override in this world
local function inRaceOverride(why)
    local vp = St.launch.vehPlan
    if type(vp) ~= "table" or opt("SetupInRaceOverride", true) == false then return 0 end
    vp.done = vp.done or {}
    local wk = tostring(St.worldGen)
    local waiting = 0
    for _, e in ipairs(overrideList()) do
        local pick = vp.players[e.pnum]
        local pr = pick and pick.presetId and V().presetById(vp.arch, pick.presetId) or nil
        local dk = wk .. ":P" .. e.pnum
        if pr and not vp.done[dk] then
            local okCall = false
            U.try(TAG, function()
                local ps = U.ok(e.pc) and e.pc.PlayerState or nil
                local comp = U.ok(ps) and ps.VehicleCustomisationComponent or nil
                local cls = V().presetClass(pr)
                if not (U.ok(comp) and cls) then return end
                if why == "prerace" and opt("SetupInRaceOverridePrerace", false) ~= true then
                    U.warn(TAG, "in-race override: P%d never overridden during LOADING (V-SET-11); not applied on "
                        .. "PRERACE (cars already spawned; cfg.SetupInRaceOverridePrerace = true forces it)", e.pnum)
                    vp.done[dk] = "skipped"
                    return
                end
                comp:Client_SetOverrideVehicleRecipe(cls)
                vp.done[dk] = why
                okCall = true
                U.log(TAG, "in-race override (%s): P%d -> %s%s", why, e.pnum, pr.id,
                    why == "prerace" and " [first success on PRERACE: may be too late, V-SET-11]" or "")
            end)
            if not okCall and not vp.done[dk] then waiting = waiting + 1 end
        end
    end
    return waiting
end

-- MAIN race tick (main.lua): LOADING retries of the in-race override (edge-only was too early for the new world).
function M.raceTick()
    if not St.race.launchedByUs or St.phase ~= "LOADING" then return end
    local vp = St.launch.vehPlan
    if type(vp) ~= "table" then return end
    local wk = tostring(St.worldGen)
    if vp.allDoneWorld == wk then return end
    if inRaceOverride("loading") == 0 then vp.allDoneWorld = wk end
end

-- PRERACE evidence for V-SET-06/08: the replicated recipe (RacingGameState) as the race sees it.
local function logRaceRecipe()
    U.try(TAG, function()
        local gs = U.gs()
        local racers = gs.EventRecipeState_Replication.Racers
        local parts = {}
        for i = 1, racers:GetArrayNum() do
            local r = racers[i]
            local cust = "-"
            pcall(function() cust = r.VehicleCustomisation:GetFName():ToString() end)
            parts[#parts + 1] = string.format("%s/%s", C.enumName(C.E.Archetype, tonumber(r.VehicleType)), cust)
        end
        U.log(TAG, "race recipe: %d racer(s): %s", #parts, table.concat(parts, " "))
    end)
end

local function ensureListener()
    if listenerRegistered then return end
    listenerRegistered = true
    St.on("phase", TAG, function(new, old)
        if new == "FRONTEND" then
            M.restoreGridPatch()
            -- the launch is over (race left, or launch timed out): the next race is "ours" only if launched again
            St.race.launchedByUs = false
            St.launch.vehPlan = nil
        elseif St.race.launchedByUs and (new == "LOADING" or new == "PRERACE") then
            inRaceOverride(string.lower(new))   -- PRERACE: log-only unless cfg.SetupInRaceOverridePrerace
            if new == "PRERACE" then logRaceRecipe() end
        end
    end)
end

-- Called by main (optional init). Registers the FRONTEND listener above at boot, not only on the first grid patch,
-- because St.race.launchedByUs must be cleared after every launch (join's "race_enter" guard reads it).
function M.init()
    ensureListener()
end

-- Hot reload (Ctrl+F11) while our own launch is LAUNCHING: the launch bookkeeping survives, so the reloaded state
-- stays in LAUNCHING (phase.compute; the launch's age is persisted, so the timeout still counts from the launch)
-- instead of going BOOT -> FRONTEND, which would clear launchedByUs, let join.open re-create dormant guests during
-- the travel and make join's race_enter guard remove the joined guests of our own race. Scalars only (OnUnload).
-- The grid patch (an edit of a SHARED GameModeVariantDef asset, undone at FRONTEND) is persisted as scalars: the
-- asset path (taken when the patch was made: OnUnload is not on the game thread, no UObject call here) and the
-- original entries "t:n,t:n" (or "@entry:old" for growGrid's single-entry patch). restoreShared rebuilds the record
-- without the UObject; restoreGridPatch finds the asset again by path when the FRONTEND listener undoes it.
function M.persistShared(put)
    put("launch.pending", St.launch.pending == true)
    put("launch.accepted", St.launch.accepted == true)
    -- an AGE, not a stamp: the reloaded Lua state's St.nowMs() has its own base (state.lua REAL CLOCK)
    put("launch.ageMs", math.max(0, St.nowMs() - (tonumber(St.launch.atMs) or St.nowMs())))
    local p, path, enc = St.launch.gridPatch, "", ""
    if type(p) == "table" and type(p.path) == "string" and p.path ~= "" then
        if type(p.orig) == "table" then
            local parts = {}
            for _, e in ipairs(p.orig) do parts[#parts + 1] = string.format("%d:%d", e.t, e.n) end
            path, enc = p.path, table.concat(parts, ",")
        elseif tonumber(p.entry) and tonumber(p.old) then
            path, enc = p.path, string.format("@%d:%d", p.entry, p.old)
        end
    end
    put("launch.grid.path", path)
    put("launch.grid.orig", enc)
end

local function restoreGridRecord(get)
    local path, enc = get("launch.grid.path"), get("launch.grid.orig")
    if type(path) ~= "string" or path == "" or type(enc) ~= "string" then return end
    local entry, old = enc:match("^@(%d+):(%d+)$")
    if entry then
        St.launch.gridPatch = { entry = tonumber(entry), old = tonumber(old), path = path }
    else
        local orig = {}
        for t, n in enc:gmatch("(%d+):(%d+)") do orig[#orig + 1] = { t = tonumber(t), n = tonumber(n) } end
        if #orig == 0 then return end
        St.launch.gridPatch = { orig = orig, path = path }
    end
    U.log(TAG, "hot reload: grid patch of %s restored (%s): undone at the next FRONTEND", path, enc)
end

function M.restoreShared(get)
    restoreGridRecord(get)
    if get("launch.pending") ~= true then return end
    local age = get("launch.ageMs")
    St.launch.pending = true
    St.launch.accepted = (get("launch.accepted") == true)
    St.launch.atMs = St.nowMs() - (type(age) == "number" and age or 0)
    U.log(TAG, "hot reload: pending launch restored (accepted=%s, %.0f ms old)", tostring(St.launch.accepted),
        St.nowMs() - St.launch.atMs)
end

local function growGrid(choice, deficit)
    ensureListener()
    M.restoreGridPatch()                               -- never stack two patches on one asset
    local entries = choice.gameMode.GridMakeup.Entries
    local n = entries:GetArrayNum()
    if n == 0 then return end
    local idx = n
    for i = 1, n do
        if entries[i].EntryType == C.E.GridEntry.PlayerChoice then idx = i; break end
    end
    local old = tonumber(entries[idx].NumEntrants) or 0
    local new = math.min(255, old + deficit)           -- uint8
    -- VERIFY(V-LCH-04): whether humans replace grid entries or come on top (decides if this is needed).
    entries[idx].NumEntrants = new
    St.launch.gridPatch = { entry = idx, old = old, gmv = choice.gameMode, path = U.pathOf(choice.gameMode) }
    U.log(TAG, "grid patch: entry %d NumEntrants %d -> %d (in memory, undone in the front end)", idx, old, new)
end

---------------------------------------------------------------------------------------------------
-- start(): exact order of §4.2 launch
---------------------------------------------------------------------------------------------------

-- A refused or throwing launch never leaves FRONTEND, so join.resync (phase listener) does not run: undo the
-- steps 2/4/6 here. join.open() re-creates the dormant guests, keeps the joined flags and clears St.join.keep.
-- Deviation: join.open is not in the §4.2 "May call" line of launch (same group G4).
undoPrelaunch = function()
    St.launch.pending = false
    St.launch.accepted = false
    St.race.launchedByUs = false
    St.ui.returnToTab = false                          -- else an unrelated later race would reopen our tab
    M.restoreGridPatch()
    local tabOpen = (St.menu.visible == "lobby" or St.menu.visible == "builder")
    local join = U.mod("join")
    if tabOpen and not join.isFrozen() then
        U.try(TAG, join.open)
    else
        St.emit("players")                             -- the lobby re-reads the (committed) guest set
    end
end

local function selectVehicleForGuests(choice)
    local arch = choice.archetype.Archetype
    local list = U.mod("join").joinedList()
    for i = 1, #list do
        local e = list[i]
        U.try(TAG, function()
            local rec = e.pc.PlayerState.RaceEventComponent
            if not U.ok(rec) then
                U.warn(TAG, "P%d has no RaceEventComponent; Server_SelectVehicle skipped", e.pnum)
                return
            end
            -- VERIFY(V-LCH-05): a Server RPC called on the server runs locally; ChosenVehicleType is read by the race.
            rec:Server_SelectVehicle(arch)
            U.log(TAG, "P%d Server_SelectVehicle(%d)", e.pnum, arch)
        end)
    end
end

function M.start()
    -- 1. checks
    local ok, why = M.canStart()
    if not ok then
        status(why)
        return false
    end
    -- 1b. un-joined guests: they cannot be removed (RemovePlayer crash, join.lua GUEST LIFECYCLE) and would race in
    -- their own view with an AI-driven car. First START: refused with the reason; a second START within 5 s (same
    -- set) goes ahead (join.commit parks them: car to the AI).
    local dormant = U.mod("join").dormantText()
    if dormant then
        -- real clock: St.nowMs (os.clock) ran ~1.5x fast under Wine (2026-10-07: a 5 s window expired in 3.5 s)
        local now = U.mod("setup").realMs()
        if not (now <= dormantOk.untilMs and dormantOk.text == dormant) then
            dormantOk.untilMs, dormantOk.text = now + 5000, dormant
            status(dormant .. ": PRESS A ON IT, OR START AGAIN FOR AN AI CAR IN ITS VIEW")
            return false
        end
        U.warn(TAG, "launch with un-joined guest(s) accepted by a second START: %s", dormant)
    end
    dormantOk.untilMs, dormantOk.text = 0, nil
    local choice = St.race.choice
    local gm = U.gm()

    -- 2. grid: the full grid of the class (race setup plan, user feedback item 9), else the old room check
    local slots, humans = M.gridInfo(choice)
    local plan = M.plan(choice)
    local patched = false
    U.try(TAG, function() patched = prepareGrid(choice, plan, humans) end)
    if patched then slots = math.max(plan.maxRacers or 0, humans) end
    U.log(TAG, "grid: %s place(s) for %d human(s)", slots and tostring(slots) or "native default", humans)
    if slots and humans > slots then
        status(string.format("GRID HAS %d PLACES FOR %d PLAYERS", slots, humans))
        if cfg.GrowGridInMemory then
            U.try(TAG, growGrid, choice, humans - slots)
        end
    end

    -- 3. remember how many remote players must follow the travel. Every launch, not only on a listening host: it is
    -- the only reset of St.net.expectedRemote (0 when not listening), so a race that starts standalone while
    -- NetMode=host never runs the travel fallback with the previous race's count.
    if U.netMode() ~= "client" then
        U.try(TAG, function() U.mod("net").beforeLaunch() end)
    end

    -- 4. dormant guests must not become racers
    U.mod("join").commit()
    -- A joined guest whose pad is gone races as AI from its first frame (join.raceTick, cfg.AIOnPadDisconnect).
    for _, e in ipairs(U.mod("join").joinedList()) do
        local sl = St.join.slots[e.ctrlId]
        if sl and sl.disconnected then
            status(string.format("P%d HAS NO CONTROLLER: %s", e.pnum,
                cfg.AIOnPadDisconnect and "AI DRIVES ITS CAR" or "ITS CAR WILL STAND STILL"))
        end
    end

    -- 5. optional per-guest vehicle class
    if cfg.SelectVehicleForGuests then selectVehicleForGuests(choice) end

    -- 6. bookkeeping before the call (the native code may already start the state change)
    St.launch.pending = true
    St.launch.accepted = false                         -- set below once PrimaryFlow confirms (phase's timeout)
    St.launch.atMs = St.nowMs()
    St.race.launchedByUs = true
    St.ui.returnToTab = true

    -- PrimaryFlow is the acceptance signal. A previous quick race may have left it at QuickRace, so it is
    -- cleared first and restored if the game refuses the launch.
    local gi = U.gi()
    local flowBefore = nil
    U.try(TAG, function()
        flowBefore = gi.PrimaryFlow
        if flowBefore == C.E.PrimaryFlow.QuickRace then gi.PrimaryFlow = C.E.PrimaryFlow.Unknown end
    end)

    -- 7. the launch: 6 arguments, null builds as nil
    local build = U.ok(choice.build) and choice.build or nil
    local debugBuild = U.ok(choice.debugBuild) and choice.debugBuild or nil
    local cond = M.conditionArg(choice)
    U.log(TAG, "LaunchCustomRace(%s, %s, %s, {TagName=%s}, %s, %s)", U.pathOf(choice.archetype),
        U.pathOf(choice.gameMode), U.pathOf(choice.track), U.str(cond.TagName),
        build and U.pathOf(build) or "nil", debugBuild and U.pathOf(debugBuild) or "nil")
    -- VERIFY(V-LCH-01): the call works from Lua with a Lua-table FGameplayTag (fallback cfg.ConditionPassMode="trackdefault").
    local called = U.try(TAG, function()
        gm:LaunchCustomRace(choice.archetype, choice.gameMode, choice.track, cond, build, debugBuild)
    end)

    -- 8. accepted iff the native body set PrimaryFlow = QuickRace
    local flowAfter = nil
    U.try(TAG, function() flowAfter = gi.PrimaryFlow end)
    -- VERIFY(V-LCH-02): PrimaryFlow reads 2 right after an accepted call.
    if not called or flowAfter ~= C.E.PrimaryFlow.QuickRace then
        St.launch.pending = false
        St.race.launchedByUs = false
        if flowBefore ~= nil and flowAfter ~= C.E.PrimaryFlow.QuickRace then
            U.try(TAG, function() gi.PrimaryFlow = flowBefore end)
        end
        U.warn(TAG, "launch refused: call %s, PrimaryFlow before=%s after=%s", called and "returned" or "threw",
            tostring(flowBefore), tostring(flowAfter))
        undoPrelaunch()
        status("LAUNCH REFUSED BY THE GAME")
        return false
    end

    -- 9. per-player vehicles / AI class / builds in the recipe, evidence for V-LCH-03, then the events
    St.launch.accepted = true                          -- phase: long LAUNCHING timeout (cfg.LaunchAcceptedTimeoutMs)
    U.try(TAG, applyRecipe, choice, plan)
    St.launch.vehPlan = { arch = plan.arch, players = plan.players }
    U.try(TAG, function() U.mod("diag").recipe() end)
    U.log(TAG, "launch accepted: %s, %d local human(s)", choice.label or "?", U.mod("join").localHumanCount())
    St.emit("launched")
    status("LOADING…")
    return true
end

---------------------------------------------------------------------------------------------------
-- prepareExternal(): cfg.BuilderMode = "devscreen" (§7). The game's dev screen calls LaunchCustomRace from its
-- own OnEventChosen listener inside the Go broadcast, so start() never runs. builder.onGo (Go post-hook, after
-- that listener) calls this to do the bookkeeping of steps 3 and 6. Deviation: not in the §4.2 public API.
-- Travel is processed on a later engine tick (OpenLevel/ServerTravel only record the pending URL), so the
-- remote players are still connected when net.beforeLaunch counts them here.
-- VERIFY(V-BLD-05): in devscreen mode the log shows "external launch" with PrimaryFlow=2 and, on a listen host,
-- net "beforeLaunch: ... expectedRemote=<n>" before the travel.
---------------------------------------------------------------------------------------------------

function M.prepareExternal(choice)
    local gi = U.gi()
    local flow = nil
    U.try(TAG, function() flow = gi.PrimaryFlow end)
    -- builder.onGo calls this only when the BP's Go test passed (= the listener's LaunchCustomRace has no reason
    -- to early-return [RB§3.1]); PrimaryFlow = QuickRace confirms the listener actually ran. builder.open (devscreen)
    -- resets PrimaryFlow (AFrontEndGameMode:ResetPrimaryFlow, field-write fallback) before it shows the dev screen,
    -- so a QuickRace left by an earlier quick race cannot pass this check.
    if flow ~= C.E.PrimaryFlow.QuickRace then
        -- The listener may be missing (V-BLD-01) or have refused; nothing was launched.
        U.warn(TAG, "external launch not confirmed: PrimaryFlow=%s; no bookkeeping done", tostring(flow))
        return false
    end
    -- every launch (see start(), step 3); the dev screen bypasses canStart's "START HOSTING FIRST" gate
    local mode = U.netMode()
    if mode ~= "client" then
        U.try(TAG, function() U.mod("net").beforeLaunch() end)
    end
    if mode ~= "listen" and settings.get("NetMode") == "host" then
        U.warn(TAG, "external launch while NetMode=host but not listening: the race is local")
        status("HOST NOT LISTENING: RACE IS LOCAL")
    end
    St.launch.pending = true
    St.launch.accepted = true                          -- PrimaryFlow == QuickRace checked above
    St.launch.atMs = St.nowMs()
    St.race.launchedByUs = true
    St.ui.returnToTab = true
    U.log(TAG, "external launch (dev screen): %s, PrimaryFlow=%s, %d local human(s)",
        type(choice) == "table" and choice.label or "?", tostring(flow), U.mod("join").localHumanCount())
    -- the grid could not be patched before the dev screen's own launch; the AI class / per-player vehicles still can
    if type(choice) == "table" then
        local plan = M.plan(choice)
        U.try(TAG, applyRecipe, choice, plan)
        St.launch.vehPlan = { arch = plan.arch, players = plan.players }
    end
    U.try(TAG, function() U.mod("diag").recipe() end)
    St.emit("launched")
    status("LOADING…")
    return true
end

return M
