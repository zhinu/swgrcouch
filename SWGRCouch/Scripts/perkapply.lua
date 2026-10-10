-- SWGRCouch · perkapply.lua (0.10.0, G4 Players & launch): the game writes of the RACE SETUP step "RACERS" - the
-- launch base build and its in-memory affix-slot patch, the humans' pilots (AI de-duplicated), each human's loadout
-- written field by field into his PlayerState's build entry and read back, and in the race world the verification,
-- the traits as passives, the late fallback and the seated-pilot check. Also the class's system flags for the board
-- (RC-2), the abilities' energy costs (RC-4) and the hot-reload record of the patch. Game thread only.
-- Design: notes/design/vehicle-step-v2.md §5.5 (API), §6 (exact order) and the review corrections RC-2, RC-4, RC-13,
-- RC-14; research notes/research/perks-loadout.md §1.2-§1.3 (structures, native behaviour), §5 (pipeline, pitfalls),
-- pilot-select.md §6.5-§6.6 (pilots).
--
-- Callers (no init, no loop of its own):
--   launch.lua, cards flow: start step 7 `build = prepareLaunch(plan)` (nil -> choice.build) and restoreLaunch("after
--     call") right after LaunchCustomRace (undoPrelaunch and the FRONTEND listener call it too: idempotent);
--     applyRecipe: humans' presets -> assignPilots -> the AI class loop -> applyAll; raceTick() first in its MAIN race
--     tick. humans = {[psKey] = {pnum, ctrlId, ps}}; plan = {arch, flow, players = {[pnum] = {ctrlId, pilotId,
--     presetId, buildPath, loadout = lo, code}}}; a pick is matched by ControllerId first (pickFor).
--   setup.lua: c.build = launchBase(arch). racers.lua: systems(arch) at step entry (hands the flags to perks.lua),
--     abilityCost(id) for the detail tag's COST.
-- Writes follow perks-loadout.md §5.4: fields of existing elements only (never a Lua table into a struct or an array,
-- never a resize, never an index past GetArrayNum()); a nil class write is a no-op in UE4SS, so empty ability slots
-- come from the zero base. No hook, no FindAllOf, no soft pointer (every object comes from a static path of
-- perkdata.lua / pilots.lua), no UIManager query. Every game call runs in U.try / pcall; one player's failure never
-- stops the others.
-- VERIFY ids: V-RC-19 (patch 4 -> 6 -> 4), V-RC-20 (pilots), V-RC-21 (read-back, PRERACE verify), V-RC-22 (traits),
-- V-RC-23 (seated pilot), V-RC-24 (pod entry), V-RC-26 (re-map by ControllerId), V-RC-27 (AI parity, PerkLaunchBase),
-- V-RC-32 (systems), V-RC-33 (energy costs without loading an ability class), V-PRK-06 (state lost in travel).
local C     = require("consts")
local cfg   = require("config")
local sched = require("sched")
local St    = require("state")
local U     = require("util")
local D     = require("perkdata")

local M = {}
local TAG = "perkapply"

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local function K() return U.mod("perks") end
local function P() return U.mod("pilots") end

local BUILD_DIR   = "/Game/Griffin/Vehicles/Common/Upgrades/BuildDefinitions/"
local BASE_SPEEDER = BUILD_DIR .. "VBD_000_1Mastiff.VBD_000_1Mastiff"              -- 4 / 10 affix slots, flags unset
local BASE_POD    = BUILD_DIR .. "VBD_000_1Mastiff_Plane.VBD_000_1Mastiff_Plane"  -- "Memory Pod [No Ramjet]"
local UP_DIR      = "/Game/Griffin/Vehicles/Common/Upgrades/UpgradeDefinitions/"
local CDO_PREFIX  = "/Script/Griffin.Default__"
local ANIM_CLS    = "/Script/Griffin.VehicleAnimationComponent"
local SHARED      = "perkapply.patch"     -- shared variable C.MOD .. "." .. SHARED (main.lua's naming)
local STATUS_INVALID, STATUS_ACTIVE, STATUS_FAULTY = 0, 1, 2                       -- EAffixStatus

-- Module state in St.perks (diag): patch = the in-memory base-build patch {path, name, u0, m0, want, obj} | nil;
-- systems[arch] = flags read from the base; costs[cfg] = EnergyCost | false; lastApply = "P1 ok P2 ok"; race = the
-- launch's per-player record for the race tick; raceText = "traits 3/3 3/3".
local function S()
    local s = St.perks
    if type(s) ~= "table" then
        s = { patch = nil, systems = {}, costs = {}, lastApply = "none", race = nil, raceText = "-" }
        St.perks = s
    end
    return s
end

local function archName(arch) return C.enumName(C.E.Archetype, arch) end
local function shortName(path) return string.match(tostring(path or ""), "%.([^%./]+)$") or tostring(path) end
local function b01(v) if v == true then return "1" elseif v == false then return "0" end return "?" end

local function nameOf(o)
    if not U.ok(o) then return nil end
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    if ok and type(n) == "string" and n ~= "" and n ~= "None" then return n end
    return nil
end

-- An AI racer's PlayerState carries its own copy of the pilot and of the display name into the race (the travel
-- copies both): a recipe write alone raced the re-assigned AI with its new pilot's car but still showed it as the
-- human's pilot ("Katja Mox" twice in the results, live run 2026-10-10). The name is URacerDef.CharacterName (FText),
-- written like nametags' "direct" rename. Both callers run where the race is launched (AI PlayerStates exist only on
-- the authority), so there is no extra authority test. -> short text for the log
local function adoptPilot(ps, def)
    if not U.ok(ps) then return "no PlayerState" end
    if not U.ok(def) then return "no RacerDef" end
    local okP = pcall(function() ps.Pilot = def end)
    local name = nil
    pcall(function() name = U.str(def.CharacterName) end)
    local okN = false
    if type(name) == "string" and name ~= "" then
        okN = pcall(function()
            ps.PlayerNamePrivate = name                     -- APlayerState.PlayerNamePrivate (Str)
            ps:OnRep_PlayerName()
        end)
    end
    return string.format("PlayerState.Pilot %s, name %s", okP and "set" or "refused",
        okN and ("'" .. name .. "'") or "kept")
end

-- BP_Ability_Surge_Overtake_C -> "Surge_Overtake"; false for an empty slot.
local function abilityIdOf(cls)
    local n = nameOf(cls)
    if not n then return false end
    return string.match(n, "^BP_Ability_(.+)_C$") or n
end

-- Level of an upgrade slot from its AuthoredUpgrade (VU_<part>_001 = 1, _NN = NN), else UserFacingStatIncrease.
local function levelOf(u)
    local n = nameOf(u.AuthoredUpgrade)
    local d = n and string.match(n, "_(%d+)$")
    if d then return tonumber(d) end
    local v = u.UserFacingStatIncrease
    if type(v) == "number" then return v end
    return nil
end

---------------------------------------------------------------------------------------------------- picks
-- The pick of a local human (§5.10): by ControllerId first (a guest who left between SAVE and START moves the later
-- pads up a pnum: logged, V-RC-26), else the pick of its pnum when that pick names no other pad. h = {pnum, ctrlId}.
function M.pickFor(plan, h)
    local players = type(plan) == "table" and type(plan.players) == "table" and plan.players or nil
    if not players or type(h) ~= "table" then return nil end
    local cid, pnum = tonumber(h.ctrlId), tonumber(h.pnum)
    if cid ~= nil then
        for k, p in pairs(players) do
            if type(p) == "table" and tonumber(p.ctrlId) == cid then
                if tonumber(k) ~= pnum then
                    U.logOnce("perkapply.remap." .. tostring(St.launch.atMs) .. "." .. tostring(k) .. "." .. cid, TAG,
                        "pick of P%s re-mapped by ControllerId %d: now P%s (V-RC-26)", tostring(k), cid, tostring(pnum))
                end
                return p
            end
        end
    end
    local p = pnum and players[pnum] or nil
    if type(p) == "table" and (p.ctrlId == nil or cid == nil) then return p end
    return nil
end

-- humans ({[psKey] = {pnum, ctrlId, ps}}; the classic {[psKey] = pnum} is accepted) -> {{key, pnum, ctrlId, ps, r}}
-- in pnum order; r = the human's recipe racer, ps from it when the table has none.
local function humanList(racers, n, humans)
    local list, byKey = {}, {}
    for key, h in pairs(type(humans) == "table" and humans or {}) do
        local e
        if type(h) == "table" then
            e = { key = key, pnum = tonumber(h.pnum), ctrlId = tonumber(h.ctrlId), ps = h.ps }
        else
            e = { key = key, pnum = tonumber(h) }
        end
        if e.pnum then list[#list + 1] = e; byKey[key] = e end
    end
    for i = 1, (tonumber(n) or 0) do
        local okR, r = pcall(function() return racers[i] end)
        if okR and r ~= nil then
            local okP, ps = pcall(function() return r.Player end)
            local e = okP and U.ok(ps) and byKey[U.key(ps)] or nil
            if e then
                e.r = r
                if not U.ok(e.ps) then e.ps = ps end
            end
        end
    end
    table.sort(list, function(a, b) return a.pnum < b.pnum end)
    return list
end

local function p1Pick(plan)
    local players = type(plan) == "table" and type(plan.players) == "table" and plan.players or {}
    for _, p in pairs(players) do
        if type(p) == "table" and tonumber(p.ctrlId) == 0 then return p end
    end
    return type(players[1]) == "table" and players[1] or nil
end

---------------------------------------------------------------------------------------------------- base build
function M.basePath(arch)
    return tonumber(arch) == 1 and BASE_POD or BASE_SPEEDER
end

-- The launch build of a cards race (§6 step 3): VBD_000_1Mastiff (speeders) / VBD_000_1Mastiff_Plane (pods): no
-- abilities, no crash ability, no parts, so every empty slot of a loadout stays empty (PL §2.5). RC-14, the V-RC-27
-- fallback when the AI turn out to scale with the launch build: cfg.PerkLaunchBase = "pilot" launches speeders on the
-- Instant Action build of P1's pilot's style (VBD_PvP_IA_*: no abilities, no parts, 4 / 10 slots, PL 26-31; the
-- humans' levels are rewritten anyway). pilotId = P1's pick (nil = the zero base); pods always take the zero base
-- (the VBD_MP_* pod builds bring pod traits and a pawn override). nil when unresolvable.
-- 0.12.0: tierPath = RACE SETUP > MODE "Opponents" (a speeder tier build of the game's preset list, VBD_011_2Dal ..
-- VBD_058_6Whippet): the race launches on it, so the AI race at that strength as in the 0.9 classic flow (task #31,
-- RC-14 / V-RC-27); every human's loadout still replaces its build entry (writeEntry clears the slots the loadout
-- leaves empty when the base is not the zero base). Pods: always the zero base.
function M.launchBase(arch, pilotId, tierPath)
    arch = tonumber(arch)
    if arch == nil then return nil end
    local zero = M.basePath(arch)
    local path = zero
    if arch ~= 1 and type(tierPath) == "string" and tierPath ~= "" then
        path = tierPath
    elseif arch ~= 1 and type(pilotId) == "string" and opt("PerkLaunchBase", "zero") == "pilot" then
        local key = nil
        pcall(function() key = P().styleKey(pilotId, arch) end)
        local st = key and D.STYLES[key] or nil
        if st and type(st.build) == "string" then path = st.build end
    end
    local o = U.obj(path)
    if U.ok(o) then return o end
    U.logOnce("perkapply.base?" .. path, TAG, "launch base %s not resolvable", path)
    if path ~= zero then
        o = U.obj(zero)
        if U.ok(o) then return o end
    end
    return nil
end

local listening = false
-- FRONTEND: the patch is undone (launch.lua's listener does it too) and the race record ends with its race.
local function ensureListener()
    if listening then return end
    listening = true
    St.on("phase", TAG, function(new)
        if new ~= "FRONTEND" then return end
        M.restoreLaunch("frontend")
        S().race = nil
    end)
end

-- §6 step 3 (cards flow, cfg.PerkApply ~= "off"): the class's launch base with UnlockedAffixSlots raised in memory to
-- cfg.PerkPartSlots for the LaunchCustomRace call (the conversion runs synchronously inside it, PL §1.3 #1-2), so every
-- human gets that many empty part slots; MaximumAffixSlots = max(its value, that). Recorded in St.perks.patch
-- (persisted for a hot reload); restoreLaunch undoes it. PerkApply "passives" writes no part into the build: the base
-- is returned unpatched. -> build | nil, why (nil: launch.lua uses choice.build; loadouts are still written into the
-- slots that build has).  VERIFY(V-RC-19): "UnlockedAffixSlots 4 -> 6 -> 4" in both launch branches.
function M.prepareLaunch(plan)
    local mode = opt("PerkApply", "full")
    if mode == "off" then return nil, "PerkApply off" end
    local arch = type(plan) == "table" and tonumber(plan.arch) or nil
    if arch == nil then return nil, "no class in the plan" end
    ensureListener()
    M.restoreLaunch("new launch")                      -- never stack two patches on one asset
    local p1 = p1Pick(plan)
    local base = M.launchBase(arch, p1 and p1.pilotId or nil, plan.aiTierPath)
    if not U.ok(base) then return nil, "launch base not found" end
    S().baseZero = U.pathOf(base) == M.basePath(arch)  -- writeEntry clears empty ability slots on any other base
    S().baseName = shortName(U.pathOf(base))            -- the AI-builds log (the slot patch record is gone by then)
    if not S().baseZero then
        U.log(TAG, "launch base %s (opponents' tier; humans' empty ability slots are cleared) (V-RC-27)",
            shortName(U.pathOf(base)))
    end
    if mode ~= "full" then
        U.log(TAG, "launch base %s (PerkApply %s: affix slots not raised)", U.pathOf(base), tostring(mode))
        return base
    end
    local want = K().partSlots()
    local ok, err = pcall(function()
        local u0, m0 = base.UnlockedAffixSlots, base.MaximumAffixSlots
        if type(u0) ~= "number" or type(m0) ~= "number" then error("affix slot counts unreadable") end
        local path = U.pathOf(base)
        S().patch = { path = path, name = shortName(path), u0 = u0, m0 = m0, want = want, obj = base }
        base.UnlockedAffixSlots = want
        if m0 < want then base.MaximumAffixSlots = want end
        local u1, m1 = base.UnlockedAffixSlots, base.MaximumAffixSlots
        if u1 ~= want then error(string.format("UnlockedAffixSlots reads %s after writing %d", tostring(u1), want)) end
        U.log(TAG, "%s UnlockedAffixSlots %d -> %d, MaximumAffixSlots %d -> %s (in memory for the LaunchCustomRace "
            .. "call; V-RC-19)", shortName(path), u0, want, m0, tostring(m1))
    end)
    if not ok then
        U.warn(TAG, "affix slot patch of %s failed (%s): the launch build keeps its own slot count", U.pathOf(base),
            tostring(err))
        M.restoreLaunch("patch failed")
        return nil, tostring(err)
    end
    return base
end

-- Undo the base-build patch (idempotent): right after the LaunchCustomRace call, on a refused launch, on FRONTEND and
-- after a hot reload (the record then holds only the path: find-only, a patched asset no longer in memory took the
-- patch with it). -> true when there was a patch.
function M.restoreLaunch(why)
    local st = S()
    local p = st.patch
    if type(p) ~= "table" then return false end
    st.patch = nil
    local ok, err = pcall(function()
        local o = p.obj
        if not U.ok(o) and type(p.path) == "string" and p.path ~= "" then
            local okF, f = pcall(StaticFindObject, p.path)
            o = okF and f or nil
        end
        if not U.ok(o) then
            U.log(TAG, "%s: %s no longer loaded, nothing to restore (%s)", tostring(why), tostring(p.path), "V-RC-19")
            return
        end
        local u1 = o.UnlockedAffixSlots
        o.UnlockedAffixSlots = p.u0
        o.MaximumAffixSlots = p.m0
        U.log(TAG, "%s UnlockedAffixSlots %s -> %s -> %s (%s; V-RC-19)", p.name or shortName(p.path), tostring(p.u0),
            tostring(u1), tostring(o.UnlockedAffixSlots), tostring(why))
    end)
    if not ok then U.warn(TAG, "restore of %s (%s) failed: %s", tostring(p.path), tostring(why), tostring(err)) end
    return true
end

---------------------------------------------------------------------------------------------------- systems (RC-2)
-- What applyAll writes into the build entry: the flags configured "on" / "off" (PerkRamjet speeders only, pods
-- PerkPodRamjet = true; PerkCritMalfunctions every class). "keep" writes nothing (the base's value stays).
local function flagWrites(arch)
    local w = {}
    if arch == 1 then
        if opt("PerkPodRamjet", false) == true then w.RamjetInstalled = true end
    else
        local r = opt("PerkRamjet", "keep")
        if r == "on" then w.RamjetInstalled = true elseif r == "off" then w.RamjetInstalled = false end
    end
    local c = opt("PerkCritMalfunctions", "keep")
    if c == "on" then w.CriticalMalfunctions = true elseif c == "off" then w.CriticalMalfunctions = false end
    return w
end

-- The class's ramjet / critical-malfunction flags as the cars will have them: RamjetInstalled / CriticalMalfunctions of
-- the zero launch base (plain bools on the loaded asset, unset = the class default, V-PRK-09), then flagWrites. Read
-- once per class (an unreadable base is retried: the decoded values meanwhile, pods false / false, speeders assumed
-- on), logged once, and handed to perks.lua, whose pickers, L/R and validate then hide what the car cannot use. The
-- style bases of PerkLaunchBase "pilot" leave both flags at the class default like the zero base (decoded).
-- -> {ramjet = bool, critmalf = bool}.  VERIFY(V-RC-32): pods log "ramjet false, critmalf false".
function M.systems(arch)
    arch = tonumber(arch)
    if arch == nil then return { ramjet = true, critmalf = true } end
    local st = S()
    local s = st.systems[arch]
    if not s then
        local rj, cm = nil, nil
        U.try(TAG, function()
            local def = U.obj(M.basePath(arch))
            if not U.ok(def) then return end
            local a, b = def.RamjetInstalled, def.CriticalMalfunctions
            if type(a) == "boolean" then rj = a end
            if type(b) == "boolean" then cm = b end
        end)
        local read = rj ~= nil and cm ~= nil
        if rj == nil then rj = arch ~= 1 end
        if cm == nil then cm = arch ~= 1 end
        local ramjet, critmalf = rj, cm
        local w = flagWrites(arch)
        if w.RamjetInstalled ~= nil then ramjet = w.RamjetInstalled end
        if w.CriticalMalfunctions ~= nil then critmalf = w.CriticalMalfunctions end
        s = { ramjet = ramjet, critmalf = critmalf }
        if read then st.systems[arch] = s end
        U.logOnce("perkapply.systems." .. arch .. "." .. tostring(read), TAG,
            "systems %s: ramjet %s, critmalf %s (%s %s %s / %s; PerkRamjet %s, PerkCritMalfunctions %s, PerkPodRamjet "
            .. "%s) (V-RC-32)", archName(arch), tostring(ramjet), tostring(critmalf), shortName(M.basePath(arch)),
            read and "reads" or "unreadable, assumed", tostring(rj), tostring(cm), tostring(opt("PerkRamjet", "keep")),
            tostring(opt("PerkCritMalfunctions", "keep")), tostring(opt("PerkPodRamjet", false)))
    end
    pcall(function() K().setSystems(arch, s) end)
    return { ramjet = s.ramjet, critmalf = s.critmalf }
end

---------------------------------------------------------------------------------------------------- energy cost (RC-4)
-- An ability's Energy cost for the detail tag, without loading its BP_Ability_* actor class: EnergyCost
-- (GfnAbilityConfig +0x38) of its native config class's default object (resident; the cooked DA_AbilityConfig_*
-- store no EnergyCost except the crash configs = 0, which perkdata carries as `energy`). Cached per config class.
-- -> int | nil.  VERIFY(V-RC-33): no LoadAsset(.../BP_Ability_...) line before the launch.
function M.abilityCost(id)
    local a = type(id) == "string" and D.ABILITIES[id] or nil
    if not a then return nil end
    if type(a.energy) == "number" then return a.energy end
    if type(a.cfg) ~= "string" then return nil end
    local st = S()
    local c = st.costs[a.cfg]
    if c == nil then
        local v = nil
        U.try(TAG, function()
            local cdo = U.cdo(CDO_PREFIX .. a.cfg)
            if not U.ok(cdo) then return end
            local e = cdo.EnergyCost
            if type(e) == "number" then v = math.floor(e + 0.5) end
        end)
        c = v or false
        st.costs[a.cfg] = c
        U.logOnce("perkapply.cost." .. a.cfg, TAG, "energy cost %s: Default__%s.EnergyCost = %s (RC-4, V-RC-33)", id, a.cfg,
            v and tostring(v) or "unreadable")
    end
    return c or nil
end

---------------------------------------------------------------------------------------------------- pilots
-- §6 step 6.2 (PS §6.5), before the AI class loop: every local human with a pick gets it (FRecipeRacerSetup.Pilot +8
-- and the front-end GfnPlayerState.Pilot +0x3D0; P1 included); then every AI racer holding a human's pilot (or another
-- RacerDef of the same character) gets the first free id of pilots.replacementOrder (CharacterList.Opponents order,
-- KESTAR, SEBULBA in skimmers / pods, the pod pilots in pods); none free -> kept (a duplicate AI beats none). A remote
-- human's racer is never re-assigned. -> the log text.  VERIFY(V-RC-20): "pilots: P1=... P2=...; AI re-assigned n".
function M.assignPilots(racers, n, humans, plan)
    local arch = type(plan) == "table" and tonumber(plan.arch) or nil
    local pil = P()
    local function tagOf(id)
        local e = type(id) == "string" and pil.byId(id) or nil
        return e and ("tag:" .. e.tag) or ("id:" .. tostring(id))
    end
    local out, humanTag = {}, {}
    local list = humanList(racers, n, humans)
    for _, h in ipairs(list) do
        U.try(TAG, function()
            local pick = M.pickFor(plan, h)
            local id = type(pick) == "table" and pick.pilotId or nil
            if type(id) ~= "string" or id == "" then
                out[#out + 1] = string.format("P%d=(game)", h.pnum)
                local cur = h.r and nameOf(h.r.Pilot)
                if cur then humanTag[tagOf(cur)] = true end
                return
            end
            if not h.r then
                out[#out + 1] = string.format("P%d=(no recipe racer)", h.pnum)
                return
            end
            local def = pil.def(id)
            if not U.ok(def) then
                out[#out + 1] = string.format("P%d=(%s not found)", h.pnum, id)
                return
            end
            h.r.Pilot = def
            local okPS = pcall(function() h.ps.Pilot = def end)
            local back = nameOf(h.r.Pilot) or "?"
            humanTag[tagOf(back)] = true
            out[#out + 1] = string.format("P%d=%s%s", h.pnum, back, okPS and "" or " (PlayerState.Pilot refused)")
        end)
    end
    -- AI = not a local human, and a bot or no remote human connected (launch.applyRecipe's rule)
    local isLocal = {}
    for _, h in ipairs(list) do isLocal[h.key] = true end
    local remote = 0
    pcall(function() remote = #U.mod("roster").remoteHumans() end)
    local ai, aiTag = {}, {}
    for i = 1, (tonumber(n) or 0) do
        pcall(function()
            local r = racers[i]
            local ps = r.Player
            if U.ok(ps) and isLocal[U.key(ps)] then return end
            local bot = (not U.ok(ps)) or remote == 0
            if not bot then
                local okB, v = pcall(function() return ps.bIsABot end)
                bot = okB and v == true
            end
            local name = nameOf(r.Pilot)
            if name then aiTag[tagOf(name)] = true end
            if bot then ai[#ai + 1] = { r = r, name = name } end
        end)
    end
    local moved, kept = 0, 0
    local order = pil.replacementOrder(arch)
    for _, a in ipairs(ai) do
        if a.name and humanTag[tagOf(a.name)] then
            U.try(TAG, function()
                local free = nil
                for _, id in ipairs(order) do
                    local t = tagOf(id)
                    if not humanTag[t] and not aiTag[t] then free = id; break end
                end
                local def = free and pil.def(free) or nil
                if U.ok(def) then
                    a.r.Pilot = def
                    local ps = nil
                    pcall(function() ps = a.r.Player end)
                    local how = adoptPilot(ps, def)
                    aiTag[tagOf(free)] = true
                    moved = moved + 1
                    U.log(TAG, "AI %s -> %s (a human's pilot; %s) (V-RC-20)", a.name, free, how)
                else
                    kept = kept + 1
                end
            end)
        end
    end
    local text = string.format("%s; AI re-assigned %d%s", (#out > 0) and table.concat(out, " ") or "no human", moved,
        kept > 0 and string.format(" (%d kept: no free pilot)", kept) or "")
    U.log(TAG, "pilots: %s (V-RC-20)", text)
    return text
end

---------------------------------------------------------------------------------------------------- build entry
-- Entry indexes to write for a class: the entry the race reads (pods: RacerBuildState.ArchetypeToUseForPlane, PL §1.3
-- #3), plus entry 1 for a pod pointed elsewhere. Errors when the array is too short (never index past Num).
local function entryIndexes(rbs, arch, num)
    local idx = arch
    if arch == 1 then
        local okA, a = pcall(function() return tonumber(rbs.ArchetypeToUseForPlane) end)
        if okA and a ~= nil then idx = a end
    end
    if idx < 0 or idx + 1 > num then
        error(string.format("VehicleBuilds has %d entries, entry %d needed", num, idx))
    end
    local out = { idx }
    if arch == 1 and idx ~= arch and arch + 1 <= num then out[2] = arch end
    return out
end

local function vuDef(s, lv)
    local nn = (lv == 1) and "001" or string.format("%02d", lv)
    local name = "VU_" .. D.STATS[s].vu .. "_" .. nn
    local o = U.obj(UP_DIR .. name .. "." .. name)
    if not U.ok(o) then error(name .. " not found") end
    return o
end

local function numOf(v, what)
    if type(v) ~= "number" then error(what .. " unreadable (" .. type(v) .. ")") end
    return v
end

-- EAffixStatus of a part: Faulty when its config has FaultyRules (the native setter 0x1471bfb5c), else Active.
local function statusOf(cfgObj, p)
    local okN, n = pcall(function() return cfgObj.FaultyRules:GetArrayNum() end)
    if okN and type(n) == "number" then return n > 0 and STATUS_FAULTY or STATUS_ACTIVE end
    return p.faulty and STATUS_FAULTY or STATUS_ACTIVE
end

-- One build entry from a loadout (§6 step 6.4), each field group in its own pcall. mode "full" also writes the parts.
-- -> errors (list), part slots of the entry, planned parts beyond them.
local function writeEntry(e, lo, arch, mode, clearEmpty)
    local errs = {}
    local function step(what, fn)
        local ok, err = pcall(fn)
        if not ok then errs[#errs + 1] = what .. ": " .. tostring(err) end
    end
    local nUp, nAb = U.arrayCount(e.UpgradeSlots), U.arrayCount(e.AbilitySlots)
    if nUp < 6 or nAb < 4 then
        error(string.format("build entry not converted (%d upgrade / %d ability slots)", nUp, nAb))
    end
    -- levels: the native fill of an FVehicleUpgrade from its VU_* def (0x140027778), field by field
    local pl = 0
    for s = 0, 5 do
        step("level " .. s, function()
            local lv = math.max(0, math.min(D.LEVEL_MAX, math.floor(tonumber(lo.tune[s]) or 0)))
            local d = vuDef(s, lv)
            local q, inc = numOf(d.BaseQuality, "BaseQuality"), numOf(d.UserFacingStatIncrease, "UserFacingStatIncrease")
            local stacks, power = numOf(d.StacksToApply, "StacksToApply"), numOf(d.PowerLevel, "PowerLevel")
            local credits = numOf(d.CreditsValue, "CreditsValue")
            local stacking = d.IsStackingTuneset
            if type(stacking) ~= "boolean" then error("IsStackingTuneset unreadable") end
            local tuneset = d.TunesetToApply
            local u = e.UpgradeSlots[s + 1]
            u.UpgradeQuality = q
            u.UserFacingStatIncrease = inc
            u.TunesetToApply = U.ok(tuneset) and tuneset or nil      -- level 0 has none
            u.IsStackingTuneset = stacking
            u.StacksToApply = stacks
            u.PowerLevel = power
            u.CreditsValue = credits
            u.AuthoredUpgrade = d
            pl = pl + power
        end)
    end
    -- PowerLevel is recomputed at spawn (0x1409ff1e8); written too, as the native conversion does (0x1409ff224)
    step("power level", function()
        e.OverridenPowerLevel = 0
        e.PowerLevel = math.min(pl, D.POWER_MAX)
    end)
    -- abilities: picked slots only (an empty slot stays empty from the zero base: a nil class write is a no-op).
    -- 0.12.0: on an opponents' tier base the entry starts with that tier's abilities: an empty slot gets an invalid
    -- (null) class written (CreateInvalidObject); compare() reads every slot back and reports what stayed.
    for i = 1, 4 do
        local id = lo.ab[i]
        if id then
            step("ability " .. i, function()
                local a = D.ABILITIES[id]
                local cls = U.class(a.cls)
                if not U.ok(cls) then error(a.cls .. " not loadable") end
                e.AbilitySlots[i] = cls
            end)
        elseif clearEmpty then
            step("clear ability " .. i, function() e.AbilitySlots[i] = CreateInvalidObject() end)
        end
    end
    if lo.crash then
        step("crash", function()
            local a = D.ABILITIES[lo.crash]
            local cls = U.class(a.cls)
            if not U.ok(cls) then error(a.cls .. " not loadable") end
            e.CrashAbility = cls
        end)
    elseif clearEmpty then
        step("clear crash", function() e.CrashAbility = CreateInvalidObject() end)
    end
    -- parts: the fields of the slots the launch build gave (pod traits too: they work in normal slots on pods)
    local nSlots, dropped = 0, 0
    if mode == "full" then
        nSlots = U.arrayCount(e.AffixSlots)
        for i = 1, nSlots do
            step("part " .. i, function()
                local id = lo.parts[i]
                local p = id and D.PARTS[id] or nil
                local cfgObj = nil
                if p then
                    cfgObj = U.obj(p.path)
                    if not U.ok(cfgObj) then error(p.path .. " not found") end
                end
                local a = e.AffixSlots[i]
                a.PrimaryAffix = cfgObj
                a.SecondaryAffix = nil
                a.PlaneSpecific = false
                a.Status = cfgObj and statusOf(cfgObj, p) or STATUS_INVALID
            end)
        end
        for i = nSlots + 1, #lo.parts do if lo.parts[i] then dropped = dropped + 1 end end
    end
    -- system flags only when configured; UseHealth is wreck.lua's, PawnOverride is never touched
    for k, v in pairs(flagWrites(arch)) do step(k, function() e[k] = v end) end
    return errs, nSlots, dropped
end

-- Everything of a build entry the plan names, read back: {lv = {[0..5]}, pl, ab = {4}, crash, nSlots, parts = {},
-- status = {}, ramjet, malf}; an unreadable value stays nil.
local function readEntry(e)
    local rb = { lv = {}, ab = {}, parts = {}, status = {}, crash = false, nSlots = 0 }
    local nUp = U.arrayCount(e.UpgradeSlots)
    for s = 0, math.min(5, nUp - 1) do
        local ok, lv = pcall(function() return levelOf(e.UpgradeSlots[s + 1]) end)
        if ok then rb.lv[s] = lv end
    end
    pcall(function() rb.pl = tonumber(e.PowerLevel) end)
    local nAb = U.arrayCount(e.AbilitySlots)
    for i = 1, math.min(4, nAb) do
        local ok, id = pcall(function() return abilityIdOf(e.AbilitySlots[i]) end)
        if ok then rb.ab[i] = id end
    end
    pcall(function() rb.crash = abilityIdOf(e.CrashAbility) end)
    rb.nSlots = U.arrayCount(e.AffixSlots)
    for i = 1, rb.nSlots do
        pcall(function()
            local a = e.AffixSlots[i]
            rb.parts[i] = nameOf(a.PrimaryAffix) or false
            rb.status[i] = tonumber(a.Status)
        end)
    end
    pcall(function() rb.ramjet = e.RamjetInstalled end)
    pcall(function() rb.malf = e.CriticalMalfunctions end)
    return rb
end

-- Differences between a read-back and the plan (levels, abilities, crash; parts in mode "full"; written flags).
local function compare(rb, lo, mode, arch)
    local diffs = {}
    for s = 0, 5 do
        if rb.lv[s] ~= lo.tune[s] then
            diffs[#diffs + 1] = string.format("level %d = %s (plan %d)", s, tostring(rb.lv[s]), lo.tune[s])
        end
    end
    for i = 1, 4 do
        local want = lo.ab[i] or false
        if rb.ab[i] ~= want then
            diffs[#diffs + 1] = string.format("ability %d = %s (plan %s)", i, tostring(rb.ab[i] or "-"), want or "-")
        end
    end
    if rb.crash ~= (lo.crash or false) then
        diffs[#diffs + 1] = string.format("crash = %s (plan %s)", tostring(rb.crash or "-"), lo.crash or "-")
    end
    if mode == "full" then
        for i = 1, rb.nSlots do
            local want = lo.parts[i] or false
            if rb.parts[i] ~= want then
                diffs[#diffs + 1] = string.format("part %d = %s (plan %s)", i, tostring(rb.parts[i] or "-"), want or "-")
            end
        end
    end
    for k, v in pairs(flagWrites(arch)) do
        local have = (k == "RamjetInstalled") and rb.ramjet or rb.malf
        if have ~= v then diffs[#diffs + 1] = string.format("%s = %s (plan %s)", k, tostring(have), tostring(v)) end
    end
    return diffs
end

local function rbText(rb, arch, idx)
    local lv, ab, nP = {}, {}, 0
    for s = 0, 5 do lv[#lv + 1] = rb.lv[s] ~= nil and tostring(rb.lv[s]) or "?" end
    for i = 1, 4 do ab[#ab + 1] = rb.ab[i] and tostring(rb.ab[i]) or "-" end
    for i = 1, rb.nSlots do if rb.parts[i] then nP = nP + 1 end end
    return string.format("build[%s e%d]: lv %s PL%s abil %s crash %s parts %d/%d ramjet %s malf %s", archName(arch), idx,
        table.concat(lv, "/"), rb.pl ~= nil and tostring(rb.pl) or "?", table.concat(ab, ","), rb.crash or "-", nP,
        rb.nSlots, b01(rb.ramjet), b01(rb.malf))
end

-- The build entry a class reads on this PlayerState, as one log line (front end or race world). -> text, rb, idx.
function M.readBack(ps, arch)
    arch = tonumber(arch)
    if not U.ok(ps) or arch == nil then return "no PlayerState / class", nil, nil end
    local ok, text, rb, idx = pcall(function()
        local rbs = ps.RacerBuildState
        local vbs = rbs.VehicleBuilds
        local i = entryIndexes(rbs, arch, vbs:GetArrayNum())[1]
        local r = readEntry(vbs[i + 1])
        return rbText(r, arch, i), r, i
    end)
    if ok then return text, rb, idx end
    return "unreadable: " .. tostring(text), nil, nil
end

---------------------------------------------------------------------------------------------------- applyAll
-- The pick's loadout validated for the class: pick.loadout (racers.lua's table), else pick.code, else the pilot's
-- style kit. -> lo, how | nil.
local function loadoutOf(pick, arch, pilotStyle, pnum)
    if type(pick) ~= "table" then return nil end
    local Kp = K()
    local lo, notes, how = nil, nil, nil
    if type(pick.loadout) == "table" then
        lo, notes = Kp.validate(pick.loadout, arch, pilotStyle)
        how = "plan"
    elseif type(pick.code) == "string" and pick.code ~= "" then
        local why
        lo, why = Kp.decode(pick.code, arch, pilotStyle)
        if lo then
            notes, how = why, "code"
        else
            U.warn(TAG, "loadout: P%d code not decodable (%s)", pnum, tostring(why))
        end
    end
    if not lo and type(pick.pilotId) == "string" then
        lo, how = Kp.default(pilotStyle, arch), "pilot kit: the plan has no loadout"
    end
    if lo and type(notes) == "table" and #notes > 0 then
        U.log(TAG, "loadout: P%d fixed for %s: %s", pnum, archName(arch), table.concat(notes, ", "))
    end
    return lo, how
end

local function applyOne(h, arch, plan, mode, race)
    local pnum = h.pnum
    local ps = h.ps
    if not U.ok(ps) then error("no PlayerState") end
    local pick = M.pickFor(plan, h)
    local pilotId = type(pick) == "table" and pick.pilotId or nil
    local pilotStyle = nil
    if type(pilotId) == "string" then pcall(function() pilotStyle = P().styleKey(pilotId, arch) end) end
    local lo, how = loadoutOf(pick, arch, pilotStyle, pnum)
    if not lo then
        U.log(TAG, "loadout: P%d has no pick: it races the launch build", pnum)
        return { ok = true, skipped = true, text = "no pick" }
    end
    -- recorded before any write: the race tick checks and completes what got through
    local rec = { pnum = pnum, ctrlId = h.ctrlId, pilotId = pilotId, lo = lo, how = how, traitText = "-" }
    race.players[h.ctrlId ~= nil and h.ctrlId or ("p" .. pnum)] = rec
    local rbs = ps.RacerBuildState
    local vbs = rbs.VehicleBuilds
    local idxs = entryIndexes(rbs, arch, vbs:GetArrayNum())
    rec.idx = idxs[1]
    if arch == 1 then
        U.log(TAG, "loadout: P%d pod entry: ArchetypeToUseForPlane = %d%s (V-RC-24)", pnum, idxs[1],
            idxs[2] and string.format(", entry %d written too", idxs[2]) or "")
    end
    local res = { ok = true, partial = false, text = "" }
    for k, idx in ipairs(idxs) do
        local e = vbs[idx + 1]
        local errs, nSlots, dropped = writeEntry(e, lo, arch, mode, S().baseZero == false)
        local rb = readEntry(e)
        local diffs = compare(rb, lo, mode, arch)
        local line = rbText(rb, arch, idx)
        U.log(TAG, "loadout: P%d %s (%s) (V-RC-21)", pnum, line, tostring(how))
        if dropped > 0 then
            U.warn(TAG, "loadout: P%d %d part(s) beyond the build's %d slot(s) not applied (V-RC-19)", pnum, dropped, nSlots)
            res.partial = true
        end
        if #errs > 0 then
            U.warn(TAG, "loadout: P%d write errors: %s", pnum, table.concat(errs, "; "))
            res.partial = true
        end
        if #diffs > 0 then
            U.warn(TAG, "loadout: P%d %s differs from the plan: %s (V-RC-21)", pnum, line, table.concat(diffs, "; "))
            res.partial = true
        end
        if k == 1 then res.text = line end
    end
    res.ok = not res.partial
    rec.applied = res.ok
    return res
end

-- §6 step 6.4, after the AI class loop: each local human's loadout (P1 included, one code path) written into the
-- build entry of his PlayerState that the race reads, field by field, and read back. PerkApply "passives": levels,
-- abilities, crash and flags only; the parts go on as passives at PRERACE (raceTick); "off": nothing is written, only
-- the pilots are recorded for the race tick's seat check. Also records the plan for the race tick.
-- -> report {mode, players = {[pnum] = {ok, partial, skipped, text}}, text = "P1 ok P2 partial"}; a player
-- not applied puts "P2 LOADOUT NOT APPLIED" / "P2 LOADOUT PARTIAL" on the status line.
-- VERIFY(V-RC-21): the read-back equals the plan for every human (V-PRK-01).
function M.applyAll(racers, n, humans, plan)
    local mode = opt("PerkApply", "full")
    local st = S()
    local report = { mode = mode, players = {}, text = "" }
    local arch = type(plan) == "table" and tonumber(plan.arch) or nil
    if arch == nil then
        st.lastApply, report.text = "no class", "no class"
        return report
    end
    ensureListener()
    local race = { arch = arch, mode = mode, launchMs = St.launch.atMs, players = {}, done = {}, allDone = nil }
    st.race, st.raceText = race, "-"
    if mode == "off" then
        -- no loadout is written (the classic build); the race tick still checks the seated pilots (PilotSeatCheck)
        for _, h in ipairs(humanList(racers, n, humans)) do
            local pick = M.pickFor(plan, h)
            if type(pick) == "table" and type(pick.pilotId) == "string" then
                race.players[h.ctrlId ~= nil and h.ctrlId or ("p" .. h.pnum)] =
                    { pnum = h.pnum, ctrlId = h.ctrlId, pilotId = pick.pilotId, traitText = "-" }
            end
        end
        st.lastApply, report.text = "off", "off"
        return report
    end
    M.systems(arch)                                    -- RC-2 flags into perks.lua before validating
    local parts = {}
    for _, h in ipairs(humanList(racers, n, humans)) do
        local okR, res = U.try(TAG, applyOne, h, arch, plan, mode, race)
        if not okR or type(res) ~= "table" then res = { ok = false, partial = false, text = "error" } end
        report.players[h.pnum] = res
        if res.skipped then
            parts[#parts + 1] = string.format("P%d -", h.pnum)
        elseif res.ok then
            parts[#parts + 1] = string.format("P%d ok", h.pnum)
        else
            local what = res.partial and "PARTIAL" or "NOT APPLIED"
            parts[#parts + 1] = string.format("P%d %s", h.pnum, string.lower(what))
            local msg = string.format("P%d LOADOUT %s", h.pnum, what)
            U.warn(TAG, "%s", msg)
            St.emit("status", msg)
        end
    end
    report.text = (#parts > 0) and table.concat(parts, " ") or "no human"
    st.lastApply = report.text
    U.log(TAG, "apply (%s, %s): %s", tostring(mode), archName(arch), report.text)
    return report
end

---------------------------------------------------------------------------------------------------- race world (§6 step 8)
-- Config names of the live passives of a PlayerState ({[name] = count}), nil when unreadable.
local function liveConfigs(ps)
    local ok, set = pcall(function()
        local list = ps.PassiveManagerComponent.PassiveList
        local out = {}
        for i = 1, list:GetArrayNum() do
            local p = list[i]
            local nm = U.ok(p) and nameOf(p.Config) or nil
            if nm then out[nm] = (out[nm] or 0) + 1 end
        end
        return out
    end)
    if ok and type(set) == "table" then return set end
    return nil
end

local function passiveCount(ps)
    local n = nil
    pcall(function() n = ps.PassiveManagerComponent.PassiveList:GetArrayNum() end)
    return n
end

local function updateRaceText(race)
    local list = {}
    for _, rec in pairs(race.players) do list[#list + 1] = rec end
    table.sort(list, function(a, b) return (a.pnum or 9) < (b.pnum or 9) end)
    local t = {}
    for _, rec in ipairs(list) do t[#t + 1] = rec.traitText or "-" end
    S().raceText = "traits " .. table.concat(t, " ")
end

-- One local human in the race world, once per world when his PlayerState and car exist. -> true = done.
local function raceOne(lp, rec, race)
    local pc = lp.pc
    if not U.ok(pc) then return false end
    local ps, pawn = pc.PlayerState, pc.Pawn
    if not (U.ok(ps) and U.ok(pawn)) then return false end
    local arch, mode, lo, pnum = race.arch, race.mode, rec.lo, rec.pnum
    local live = nil                                   -- config names of the live passives (nil: unreadable)
    local partsMissing, lost = false, false
    -- (lo = nil: PerkApply "off", only the pilot check below runs)
    -- verify: the build entry the car was made from, the spawned ability slots, the live part passives
    if lo and opt("PerkVerify", true) ~= false then
        U.try(TAG, function()
            local text, rb = M.readBack(ps, arch)
            local diffs = rb and compare(rb, lo, mode, arch) or { "build unreadable" }
            local nOk, nWant, crashOk = 0, 0, nil
            local comp = ps.AbilityComponent
            if U.ok(comp) then
                local slots = comp.AbilitySlots
                local nS = U.arrayCount(slots)
                for i = 1, 4 do
                    local want = lo.ab[i] or false
                    if want then
                        nWant = nWant + 1
                        if i <= nS and abilityIdOf(slots[i]) == want then nOk = nOk + 1 end
                    end
                end
                crashOk = abilityIdOf(comp.CrashAbilitySlot) == (lo.crash or false)
            end
            live = liveConfigs(ps)
            local wantP, liveP = 0, 0
            for _, id in ipairs(lo.parts) do
                if id then
                    wantP = wantP + 1
                    if live and live[id] then liveP = liveP + 1 end
                end
            end
            if live then
                partsMissing = liveP < wantP
            elseif rb and mode == "full" then
                for i = 1, #lo.parts do
                    if lo.parts[i] and rb.parts[i] ~= lo.parts[i] then partsMissing = true end
                end
            end
            local levelsOk = true
            if rb then for s = 0, 5 do if rb.lv[s] ~= lo.tune[s] then levelsOk = false end end end
            lost = nOk < nWant or crashOk == false or not levelsOk
            U.log(TAG, "loadout: P%d in race: build %s, abilities %d/%d, crash %s, parts %s/%d live (V-RC-21)", pnum,
                #diffs == 0 and "ok" or "differs", nOk, nWant, crashOk == nil and "?" or (crashOk and "ok" or "missing"),
                live and tostring(liveP) or "?", wantP)
            if #diffs > 0 then U.warn(TAG, "loadout: P%d race %s: %s", pnum, text, table.concat(diffs, "; ")) end
        end)
    end
    -- the style object itself only when asked (its traits might then apply a second time)
    if lo and opt("PerkSetRacerStyle", false) == true then
        U.try(TAG, function()
            local st = D.STYLES[lo.style]
            local obj = st and U.obj(st.path) or nil
            if U.ok(obj) then
                ps.RacerStyle = obj
                U.log(TAG, "loadout: P%d RacerStyle = %s (PerkSetRacerStyle)", pnum, lo.style)
            end
        end)
    end
    -- traits: the game's own way to apply a style's traits is AddPassive per trait (PL §1.3 #6); Server_ApplyPassive
    -- reaches it, a Server RPC that runs locally on the standalone / listen host (PL §5.2 #5)
    if lo and opt("PerkTraits", true) ~= false then
        U.try(TAG, function()
            local n0 = passiveCount(ps)
            local want, applied = 0, 0
            for _, id in ipairs(lo.traits) do
                if id then
                    want = want + 1
                    local t = D.TRAITS[id]
                    local obj = t and U.obj(t.path) or nil
                    if U.ok(obj) and pcall(function() ps:Server_ApplyPassive(obj) end) then
                        applied = applied + 1
                    else
                        U.warn(TAG, "loadout: P%d trait %s not applied", pnum, id)
                    end
                end
            end
            local n1 = passiveCount(ps)
            rec.traitText = string.format("%d/%d", (n0 and n1) and math.max(0, n1 - n0) or applied, want)
            U.log(TAG, "loadout: P%d traits: %d of %d applied, PassiveList %s -> %s (V-RC-22)", pnum, applied, want,
                tostring(n0), tostring(n1))
        end)
    end
    -- parts as passives: always with PerkApply "passives"; in "full" mode only when the verify found them missing
    -- (PerkLateFallback). A flaw is never re-applied: a passive has no FVehicleAffix.Status, so its FaultyRules would
    -- not run (RC-13). Abilities and levels cannot be re-applied after the spawn (PL §1.3 #7).
    local fallback = mode == "full" and partsMissing and opt("PerkLateFallback", true) ~= false
    if lo and (mode == "passives" or fallback) then
        U.try(TAG, function()
            local applied, flaws = 0, 0
            for _, id in ipairs(lo.parts) do
                if id and not (live and live[id]) then
                    local p = D.PARTS[id]
                    if p.faulty or p.rarity == 4 then
                        flaws = flaws + 1
                        U.log(TAG, "loadout: P%d flaw %s not re-applied (a passive has no Faulty status, RC-13)", pnum, id)
                    else
                        local obj = U.obj(p.path)
                        if U.ok(obj) and pcall(function() ps:Server_ApplyPassive(obj) end) then
                            applied = applied + 1
                        else
                            U.warn(TAG, "loadout: P%d part %s not applied as a passive", pnum, id)
                        end
                    end
                end
            end
            U.log(TAG, "loadout: P%d %s: %d part(s) applied as passives, %d flaw(s) skipped (V-PRK-06)", pnum,
                fallback and "late fallback" or "PerkApply passives", applied, flaws)
        end)
    end
    if mode == "full" and lost then
        U.warn(TAG, "loadout: P%d abilities/levels lost in travel: the car races without them (V-PRK-06)", pnum)
    end
    -- seated pilot (PS §6.6): "log" compares; "refresh" writes the pick back and rebuilds the seated pilot
    local seat = opt("PilotSeatCheck", "log")
    if seat ~= "off" and type(rec.pilotId) == "string" then
        U.try(TAG, function()
            local have = nameOf(ps.Pilot)
            if seat == "refresh" then
                if have ~= rec.pilotId then
                    local def = P().def(rec.pilotId)
                    if U.ok(def) then ps.Pilot = def end
                end
                local cls = U.class(ANIM_CLS)
                local anim = nil
                if U.ok(cls) then pcall(function() anim = pawn:GetComponentByClass(cls) end) end
                local how = "not refreshed (no VehicleAnimationComponent)"
                if U.ok(anim) then
                    local okR, errR = pcall(function() anim:SynchronousRefreshPilot() end)
                    how = okR and "refreshed" or ("refresh failed: " .. tostring(errR))
                end
                U.log(TAG, "pilot: P%d %s -> %s, seat %s (V-RC-23)", pnum, tostring(have), tostring(nameOf(ps.Pilot)), how)
            elseif have == rec.pilotId then
                U.log(TAG, "pilot: P%d PlayerState.Pilot = %s, the pick (V-RC-23)", pnum, have)
            else
                U.warn(TAG, "pilot: P%d PlayerState.Pilot = %s, the pick is %s (PilotSeatCheck \"refresh\" writes it) "
                    .. "(V-RC-23)", pnum, tostring(have), rec.pilotId)
            end
        end)
    end
    updateRaceText(race)
    return true
end

-- Race-side net for the AI pilots, once per world: an AI PlayerState whose pilot differs from its race recipe entry
-- (assignPilots re-assigned it, the travel copied the old one) adopts the entry's pilot and name, and its seated
-- pilot is rebuilt. Retried while AI cars are still spawning (at most 40 MAIN ticks = 10 s).
local function fixAiPilots(race, wk)
    if race.aiFixed == wk then return end
    if race.aiWk ~= wk then race.aiWk, race.aiTries = wk, 0 end
    race.aiTries = race.aiTries + 1
    local gs = nil
    pcall(function() gs = U.world().GameState end)
    if not U.ok(gs) then return end
    local rs = nil
    pcall(function() rs = gs.EventRecipeState_Replication.Racers end)
    local n = rs and U.arrayCount(rs) or 0
    if n == 0 then return end
    local waiting, fixed = 0, 0
    for i = 1, n do
        U.try(TAG, function()
            local r = rs[i]
            local ps = r.Player
            if not U.ok(ps) or ps.bIsABot ~= true then return end
            local want, have = nameOf(r.Pilot), nameOf(ps.Pilot)
            if not want or want == have then return end
            local pawn = nil
            pcall(function() pawn = ps.PawnPrivate end)          -- APlayerState.PawnPrivate
            if not U.ok(pawn) then waiting = waiting + 1; return end
            local how = adoptPilot(ps, r.Pilot)
            local seat = "not refreshed (no VehicleAnimationComponent)"
            local cls = U.class(ANIM_CLS)
            local anim = nil
            if U.ok(cls) then pcall(function() anim = pawn:GetComponentByClass(cls) end) end
            if U.ok(anim) then
                local okR, errR = pcall(function() anim:SynchronousRefreshPilot() end)
                seat = okR and "refreshed" or ("refresh failed: " .. tostring(errR))
            end
            fixed = fixed + 1
            U.log(TAG, "AI pilot in race: %s -> %s (%s, seat %s) (V-RC-20)", tostring(have), want, how, seat)
        end)
    end
    if waiting == 0 or race.aiTries >= 40 then
        race.aiFixed = wk
        if waiting > 0 then U.warn(TAG, "AI pilot in race: %d AI car(s) never spawned in 10 s; not checked", waiting) end
    end
end

-- 0.12.0 V-RC-27: once per race world, the AI racers' build entries for the race's class: PowerLevel min / avg / max,
-- abilities and valid parts on average, next to the launch base (an opponents' tier must raise them). Read-only; waits
-- for the recipe's bots (40 tries, as fixAiPilots).
local function logAiPower(race, wk, arch)
    if race.aiPowerLogged == wk then return end
    if race.aiPwWk ~= wk then race.aiPwWk, race.aiPwTries = wk, 0 end
    race.aiPwTries = race.aiPwTries + 1
    local gs = nil
    pcall(function() gs = U.world().GameState end)
    if not U.ok(gs) then return end
    local rs = nil
    pcall(function() rs = gs.EventRecipeState_Replication.Racers end)
    local n = rs and U.arrayCount(rs) or 0
    if n == 0 then
        if race.aiPwTries >= 40 then race.aiPowerLogged = wk end
        return
    end
    local pls, abs, parts, bots = {}, 0, 0, 0
    for i = 1, n do
        pcall(function()
            local ps = rs[i].Player
            if not U.ok(ps) or ps.bIsABot ~= true then return end
            local rbs = ps.RacerBuildState
            local vbs = rbs.VehicleBuilds
            local e = vbs[entryIndexes(rbs, arch, vbs:GetArrayNum())[1] + 1]
            local pl = tonumber(e.PowerLevel)
            if pl then pls[#pls + 1] = pl end
            for k = 1, U.arrayCount(e.AbilitySlots) do
                local c = nil
                pcall(function() c = e.AbilitySlots[k] end)
                if U.ok(c) then abs = abs + 1 end
            end
            for k = 1, U.arrayCount(e.AffixSlots) do
                local a = nil
                pcall(function() a = e.AffixSlots[k].PrimaryAffix end)
                if U.ok(a) then parts = parts + 1 end
            end
            bots = bots + 1
        end)
    end
    if bots == 0 and race.aiPwTries < 40 then return end
    race.aiPowerLogged = wk
    if bots == 0 then U.log(TAG, "AI builds: no AI racer in the recipe (V-RC-27)"); return end
    table.sort(pls)
    local sum = 0
    for _, v in ipairs(pls) do sum = sum + v end
    local base = S().baseName or "?"
    U.log(TAG, "AI builds (%d AI, launch base %s): PowerLevel min %s / avg %.1f / max %s, abilities %.1f, parts %.1f "
        .. "per AI (V-RC-27)", bots, tostring(base), tostring(pls[1] or "?"), #pls > 0 and sum / #pls or 0,
        tostring(pls[#pls] or "?"), abs / bots, parts / bots)
end

-- launch.raceTick (MAIN, every race phase): in PRERACE / RACING of a cards race we launched, once per world and local
-- human (ControllerId from the LocalPlayer) as soon as his PlayerState and car exist: verify, traits, parts as passives
-- when needed, pilot check. An error marks that player done (no traceback every 250 ms).
function M.raceTick()
    if not St.race.launchedByUs then return end
    if St.phase ~= "PRERACE" and St.phase ~= "RACING" then return end
    local race = S().race
    if type(race) ~= "table" then return end
    if race.launchMs ~= St.launch.atMs then return end           -- the record of an earlier launch
    local vp = St.launch.vehPlan
    if type(vp) == "table" and vp.flow ~= nil and vp.flow ~= "cards" then return end
    local wk = St.worldGen
    U.try(TAG, fixAiPilots, race, wk)
    U.try(TAG, logAiPower, race, wk, tonumber(vp and vp.arch))
    if race.allDone == wk then return end
    local waiting = 0
    for _, lp in ipairs(U.localPlayers()) do
        -- P1 is filed under ControllerId 0 (racers / launch.localHumans), even when HotplugPadToP1 gave its
        -- LocalPlayer another ControllerId
        local key = (lp.index == 1) and 0 or lp.ctrlId
        local rec = race.players[key]
        if rec then
            local dk = tostring(wk) .. ":" .. tostring(key)
            if not race.done[dk] then
                local okR, done = U.try(TAG, raceOne, lp, rec, race)
                if not okR or done then race.done[dk] = true else waiting = waiting + 1 end
            end
        end
    end
    if waiting == 0 then race.allDone = wk end
end

---------------------------------------------------------------------------------------------------- hot reload
-- main.lua PERSIST_MODULES contract (OnUnload, not the game thread: Lua values only). The patch record as
-- "<path>|<u0>|<m0>|<want>"; the next Lua state restores the asset by path on its first game-thread tick.
function M.persistShared(put)
    local p = St.perks and St.perks.patch or nil
    if type(p) == "table" and type(p.path) == "string" and p.path ~= "" and type(p.u0) == "number"
        and type(p.m0) == "number" then
        put(SHARED, string.format("%s|%d|%d|%d", p.path, p.u0, p.m0, tonumber(p.want) or -1))
    else
        put(SHARED, "")
    end
end

function M.restoreShared(get)
    local v = get(SHARED)
    if type(v) ~= "string" or v == "" then return end
    local path, u0, m0, want = string.match(v, "^([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if not path then return end
    S().patch = { path = path, name = shortName(path), u0 = tonumber(u0), m0 = tonumber(m0), want = tonumber(want) }
    ensureListener()
    U.log(TAG, "hot reload: affix slot patch of %s (%s -> %s) left by the previous Lua state: restored now", path, u0,
        want)
    sched.run("perkapply.restore", function() M.restoreLaunch("hot reload") end)
end

---------------------------------------------------------------------------------------------------- status
-- "patch none | last apply: P1 ok P2 ok | race: traits 3/3 3/3" (diag F9, test.cmd).
function M.status()
    local st = S()
    local p = st.patch
    local patch = (type(p) == "table") and string.format("%s %s->%s", tostring(p.name), tostring(p.u0), tostring(p.want))
        or "none"
    return string.format("patch %s | last apply: %s | race: %s", patch, tostring(st.lastApply or "none"),
        tostring(st.raceText or "-"))
end

return M
