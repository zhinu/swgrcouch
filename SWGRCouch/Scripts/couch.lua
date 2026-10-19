-- couch.lua: COUCH CAMPAIGN - the game's real single-player rogue campaign played by 2-4 local players (0.15; 3-4: couch-4p).
-- Jules 2026-10-14: "make 2 players 1 to 1 of the rogue campaign with perks unlock etc." (feasibility:
-- notes/research/rogue-mode/06-COUCH-CAMPAIGN-FEASIBILITY.md).
--
-- The campaign itself runs natively (P1's CampaignRun: paddock, cinematics, map, events, rewards, saves - kept in a
-- separate COUCH save profile by tools/swgr-save-profile.sh). This module decides WHEN the couch rules apply and
-- answers the other modules' guards:
--   * active: the world is the campaign's (a PaddockGameState, or a race while CampaignSubsystem has an active run)
--     and at least one joined guest exists, cfg.CouchCampaign on, not a network session, not a race the mod launched.
--   * while active: guests are NOT closed when the paddock opens (menu_tab), and their cars are NOT handed to the AI
--     in campaign races (join's race_enter guard): the race keeps split screen, every per-player system (HUDs, pause,
--     input isolation) runs as in a FREE MODE race.
--   * Campaign.SkipPrologueEvents 1 (cfg.CouchSkipPrologue): a new run skips the vehicle-tryout prologue race.
-- Every game read is pcall-guarded; the module holds no UObject across ticks.
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")

local TAG = "couch"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local state = { on = false, why = "", worldKey = nil, prologueSet = false }

-- STUTTER FIX (live 2026-10-14 23:25, tick profiler, 2P race): this was a FindFirstOf("CampaignSubsystem") per call =
-- a walk of the whole object array (~5 ms in a race world), and M.active() (-> isCampaignWorld -> hasActiveRun) is
-- called every FAST tick by menubridge, inputfix.p1UiGuard, couchrules, couchbets, couchpanel, couchprerun and every
-- MAIN tick by nametags: menubridge.fastTick 5.4 ms, p1UiGuard 5.3 ms, nametags.tick 5.3 ms average, the FAST loop
-- 14.4 ms per run = Jules's micro-stutters. The subsystem is a GameInstance subsystem: U.giSubsystem caches it (one
-- GetGameInstanceSubsystem, re-validated with U.ok); the FindFirstOf fallback runs at most every 2 s on a miss.
local CS_PATH = "/Script/Griffin.CampaignSubsystem"
local csMissAt = -1e12
local function campaignSubsystem()
    local cs = nil
    pcall(function() cs = U.giSubsystem(CS_PATH) end)
    if U.ok(cs) then return cs end
    local now = St.nowMs()
    if now - csMissAt < 2000 then return nil end
    csMissAt = now
    local ok, f = pcall(FindFirstOf, "CampaignSubsystem")
    if ok and U.ok(f) then return f end
    return nil
end
M.campaignSubsystem = campaignSubsystem

-- true when the campaign has a live run (a race straight from CONTINUE has one before any paddock)
local function hasActiveRun()
    local cs = campaignSubsystem()
    if not cs then return false end
    local ok, v = pcall(U.callMethod, cs, "HasActiveRun")
    if ok and v == true then return true end
    -- the prologue race runs before the run exists (live 2026-10-14: HasActiveRun false in L_Mastiff_P2P_A)
    local okP, p = pcall(U.getField, cs, "bIsPlayingPrologue")
    return okP and p == true
end

local function joinedGuests()
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    return (ok and type(list) == "table") and #list or 0
end

-- The world belongs to the campaign: the paddock, or a race of an active run that the mod did not launch.
-- (couch-livefix f) LIVE 2026-10-16: a guest who LEFT still controlled the run-END screen. The run's last screens
-- (WBP_PostRace_RunComplete / WBP_PostRace_RunEndRecap: LockRun() at its anim-in, CleanupAfterRunAndPrepareForNext at
-- its continue) are shown in the race world while the run is being closed - once HasActiveRun() reads false the world
-- stopped counting as a campaign world: no couch rules, no dormant-screen swap, and menubridge fell back to "anyone's A
-- on a shared post-race screen" - the left guest's pad (the screens' owner, the LAST local PC) drove them. A race world
-- that was a campaign world stays one until the world changes.
local campWorld = { gen = nil }
function M.isCampaignWorld()
    local gs = U.gs()
    if not U.ok(gs) then return false end
    if U.isA(gs, "/Script/Griffin.PaddockGameState") then return true end
    if U.isA(gs, "/Script/Griffin.RacingGameState") and St.race.launchedByUs ~= true then
        if hasActiveRun() then
            campWorld.gen = St.worldGen
            return true
        end
        return campWorld.gen ~= nil and campWorld.gen == St.worldGen
    end
    return false
end

-- The couch rules apply now. Called every FAST tick by several modules (see campaignSubsystem): the answer is
-- memoised for 200 ms per world and local-player count (a join / world change / launch flag is seen next tick).
-- RACE FAST PATH (couch-racefast 2026-10-15, live profile couch-integ 4d6c050): in a race world (PRERACE / RACING) the
-- answer cannot change without a world change, a launch flag or a local player joining / leaving (the "players" event
-- drops the memo): it is kept 2 s there and the U.localPlayers() walk (1 + 3 reads per player) is skipped on a hit -
-- menubridge / couchrun / garage / couchrules ask every FAST / MAIN tick.
local ACTIVE_RACE_TTL = { PRERACE = 2000, RACING = 2000 }
local activeMemo = { at = -1e12, world = nil, n = -1, launched = nil, v = false }
local activeUncached
function M.active()
    local now = St.nowMs()
    local m = activeMemo
    local raceTtl = ACTIVE_RACE_TTL[St.phase]
    if raceTtl and now - m.at < raceTtl and m.world == St.worldGen and m.launched == St.race.launchedByUs then return m.v end
    local n = #U.localPlayers()
    if now - m.at < 200 and m.world == St.worldGen and m.n == n and m.launched == St.race.launchedByUs then return m.v end
    local v = activeUncached()
    m.at, m.world, m.n, m.launched, m.v = now, St.worldGen, n, St.race.launchedByUs, v
    return v
end
function M.activeForget() activeMemo.at = -1e12 end
activeUncached = function()
    if opt("CouchCampaign", true) ~= true then return false end
    if U.netMode() == "client" or St.net.wantConnected == true then return false end
    if St.race.launchedByUs == true then return false end
    if #U.localPlayers() < 2 then return false end
    local okW, inCampaign = pcall(M.isCampaignWorld)
    if not (okW and inCampaign) then return false end
    return joinedGuests() > 0
end

-- BUG 2 (live 2026-10-16, l3-solo shots 78-84): all guests left (hold B) -> no joined guest -> M.active() false -> the
-- couch rules (and with them the pad-id swap and menubridge's couch mode) are off. But the guests' LocalPlayers stay
-- (dormant, GuestRemoval=never) and the game still gives every paddock / post-race screen to the LAST local PC: the run
-- map / PlanetSelector belonged to pad 4's dormant PC, P1's pad drove nothing, and the dormant pads' input is ignored
-- by join.lua: a soft lock. M.sharedScreens(): the shared-screen machinery (swap / park, refocus, owner IMC_UI,
-- menubridge's P1-only bridge) runs whenever the campaign world has 2+ local players, joined or dormant - only the
-- couch RULES (grid, payouts, guests' areas) still need a joined guest (M.active). cfg.CouchDormantScreens = false: off.
local sharedMemo = { at = -1e12, world = nil, n = -1, launched = nil, v = false }
function M.sharedScreens()
    if M.active() then return true end
    if opt("CouchDormantScreens", true) == false or opt("CouchCampaign", true) ~= true then return false end
    local now = St.nowMs()
    local m = sharedMemo
    local n = #U.localPlayers()
    if now - m.at < 500 and m.world == St.worldGen and m.n == n and m.launched == St.race.launchedByUs then return m.v end
    local v = false
    if n >= 2 and St.race.launchedByUs ~= true and U.netMode() ~= "client" and St.net.wantConnected ~= true then
        local okW, inCampaign = pcall(M.isCampaignWorld)
        v = okW and inCampaign == true
    end
    m.at, m.world, m.n, m.launched, m.v = now, St.worldGen, n, St.race.launchedByUs, v
    return v
end
function M.sharedForget() sharedMemo.at = -1e12 end

-- takeover.lua's guard: why no human may take over an AI car in this world, or nil. A campaign race (any, with or
-- without cfg.CouchCampaign or a joined guest) never gets the AI takeover: possessing a campaign AI car crashes the game
-- natively one frame later (exe+0x641579 null+0xdf0, live 2026-10-14 14:57 / 15:14 UTC: UFuseHudWingWidget's NativeTick,
-- vtable slot 0x3e0, resolves its weak UFuseCameraComponent with no null check and reads mCameraModeStacks (+0xde8, Num at
-- +0xdf0) - the HUD top bar now follows a car whose camera component it never had). A carless guest spectates instead.
-- Checked only when someone is eligible (one FindFirstOf, not per tick).
function M.takeoverBlocked()
    local okA, on = pcall(M.active)
    if okA and on == true then return "couch campaign race" end
    local okW, camp = pcall(M.isCampaignWorld)
    if okW and camp == true then return "campaign race" end
    return nil
end

local function setPrologueSkip()
    if state.prologueSet or opt("CouchSkipPrologue", true) ~= true then return end
    local ok = pcall(U.console, "Campaign.SkipPrologueEvents 1")
    if ok then
        state.prologueSet = true
        U.log(TAG, "Campaign.SkipPrologueEvents 1: a new run skips the vehicle-tryout prologue race")
    end
end

---------------------------------------------------------------------------------------------------- grid patch
-- Field Test / Podracer Test activities (ECampaignMapNodeActivity). Declared before patchGrid: it reads them (the
-- 0.15 draft declared them below it, so patchGrid called a nil global and stopped after the first guest's entry).
local TT_ACTIVITY = { [4] = true, [10] = true }

-- the chosen node's activity (ECampaignMapNodeActivity), or nil
local function chosenActivity()
    local act = nil
    pcall(function()
        local r = campaignSubsystem().ActiveRun
        local nodes = r.Map.mNodes
        for i = 1, U.arrayCount(nodes) do
            local nd = nodes[i]
            if U.ok(nd) and nd.bHasBeenChosen == true and nd.bHasBeenCompleted ~= true then act = tonumber(nd.Activity) end
        end
    end)
    return act
end
M.chosenActivity = chosenActivity

-- #30 (playtest 2026-10-17 18:54, Tatooine's PODRACER TEST L_Beagle_PLANE): the planet's plane test is not a map node.
-- The paddock starts it with CampaignRun:KickOffPlaneTestEvent, whose native body (CL381121 0x1430cdeb8 ->
-- 0x1430daf50) loads Tour.Planets[#VisitedPlanets].PlaneTestEvent into run.ActivePlaneTestEvent, runs the racer
-- builder 0x1430d7dcc (P1 + the event's CustomOpponents + AI fill from GridMakeup), stores the recipe (only into an
-- EMPTY RecipeState.Racers) and server-travels - no ChooseNextMapNode, so no grid patch ever ran: the guest had no
-- entry, sat out ("one view, everyone watches P1") and the race showed ONE view. planeT.kicked = our own kickoff
-- seen (the run's ActivePlaneTestEvent alone may outlive the test); cleared in the paddock / front end / next pick.
local planeT = { kicked = false, patch = nil }

local function planeTestActive()
    local on = false
    pcall(function() on = U.ok(campaignSubsystem().ActiveRun.ActivePlaneTestEvent) end)
    return on
end

-- a plane test started by the run's KickOffPlaneTestEvent is running (the guests race P1's mission pod)
function M.isPlaneTest() return planeT.kicked == true and planeTestActive() end

-- the chosen node is a time trial (every human races P1's test vehicle), or the planet's plane test runs
function M.isTimeTrial() return TT_ACTIVITY[chosenActivity() or -1] == true or M.isPlaneTest() end

-- The guest's own class + a preset of it on his grid entry (FREE MODE's launch.applyRecipe writes), and the class on
-- his RaceEventComponent (Server_SelectVehicle, as launch.selectVehicleForGuests). A time trial copies P1's test
-- vehicle (entry 1 is P1's: playerRacer goes first). The preset = his GARAGE model (garage.presetFor) when he picked
-- one, else the seat's default; his livery is uploaded in the race (garage.raceTick). -> note
local function guestVehicle(racers, idx, g, tt)
    if tt then
        pcall(function()
            racers[idx].VehicleType = racers[1].VehicleType
            racers[idx].VehicleCustomisation = racers[1].VehicleCustomisation
        end)
        if not M.isPlaneTest() then return "P1's test vehicle" end
        -- #30: a plane test is the mission's character in the mission's pod ("both race as Sebulba"): P1's entry pilot
        -- on the guest's entry and PlayerState (couchrun.applyBuilds keeps it: no couch build on a mission pod)
        local pil = "?"
        pcall(function()
            local def = racers[1].Pilot
            if U.ok(def) then
                racers[idx].Pilot = def
                pcall(function() g.ps.Pilot = def end)
                pil = def:GetFName():ToString()
            end
        end)
        return "P1's mission pod, pilot " .. tostring(pil)
    end
    local arch = nil
    pcall(function() arch = U.mod("couchrun").archOf(g.ctrlId, g.pnum) end)
    if arch == nil or arch == 1 then return "class unknown" end
    local note = C.enumName(C.E.Archetype, arch)
    U.try(TAG, function()
        if tonumber(racers[idx].VehicleType) ~= arch then racers[idx].VehicleType = arch end
        local V = U.mod("vehicles")
        local list = V.presets(arch)
        local pr = list[V.defaultPresetIndex(arch, g.pnum)]
        -- his GARAGE model (garage.lua: the standard preset of the model he picked), else the seat's default
        local okG, gid = pcall(function() return U.mod("garage").presetFor(g.pnum, arch) end)
        local gpr = (okG and gid) and V.presetById(arch, gid) or nil
        if gpr then pr = gpr end
        local cls = pr and V.presetClass(pr) or nil
        if cls then
            racers[idx].VehicleCustomisation = cls
            note = note .. "/" .. tostring(pr.id)
        else
            note = note .. "/no preset"
        end
    end)
    pcall(function()
        local rec = g.ps.RaceEventComponent
        if U.ok(rec) then rec:Server_SelectVehicle(arch) end
    end)
    return note
end
M.guestVehicle = guestVehicle               -- couch-fix38: couchrules.bossPlace gives each guest his own car the same way

-- The campaign builds a race's grid at the node PICK (ChooseNextMapNode -> RecipeState.Racers) with ONE human
-- (06b §1): P1 + opponents. Each joined guest takes over the LAST bot entries (its Player -> the guest's
-- GfnPlayerState); the race spawn then gives that controller its own car (live 2026-10-14: P2 drove his own bike in a
-- Jakku map race, split screen, own HUD). Runs as a native post-hook, for the paddock map and the post-race map.
local function guestPlayerStates()
    local out = {}
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    if not (ok and type(list) == "table") then return out end
    for _, e in ipairs(list) do
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        if U.ok(ps) then out[#out + 1] = { ps = ps, pnum = e.pnum, ctrlId = e.ctrlId } end
    end
    return out
end

-- An AI filler entry a guest may take: a bot PlayerState that is not P1's rival / nemesis / antagonist.
function M.takeableEntry(entry)
    local ok, res = pcall(function()
        local ps = entry.Player
        if not (U.ok(ps) and ps.bIsABot == true) then return false end
        return not (ps.bIsRival == true or ps.bIsRaceNemesis == true or ps.bIsAntagonist == true)
    end)
    return ok and res == true
end

-- #67 (tester #3 04:42, and tester #2's 02:52 vanish at the deferred placement): the game vanished (exit 9, no dump)
-- inside the native ChooseNextMapNode of a MYSTERY pick on the POST-RACE map right after an eliminator, just after this
-- clear. UE4SS's TArray:Empty() is FScriptArray::Empty(0): it FREES the racers' buffer without running a destructor,
-- while that race world still lives (its AI cars, controllers and the mode rules hold the recipe's entries: the
-- unreflected AI build state at 0x18..0x80). A race pick refills the array at once; a STOP (black market 7, repair 8,
-- mystery 9, rival 11 / 12: the pick builds no grid) leaves the freed block to the next allocation = garbage under the
-- live race. Both vanishes are the same path: the recipe's racer array rewritten / freed while its race world (or its
-- travel) still uses it. So: the grid is emptied only when the pick builds one, never on a race world for a stop, never
-- in TRANSIT / LOADING; a kept grid is emptied by the next pick (off the race world: the paddock / map).
M.GRID_AT_PICK = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [10] = true }
local function nodeActivity(nodeP)
    local a = nil
    pcall(function()
        local nd = nodeP
        if nd ~= nil and type(nd) ~= "number" and not U.ok(nd) then nd = nodeP:get() end   -- a RemoteUnrealParam
        if U.ok(nd) then a = tonumber(nd.Activity) end
    end)
    return a
end
M._nodeActivity = nodeActivity

-- #66 (tester #3): every paddock visit loaded Lantaana's paddock while the map, the races and the gauntlet moved on
-- to Ando Prime, Sentinel I and Jakku. Static (CL381121): the paddock world is PlanetDef.PaddockMap of
-- CampaignRun:GetCurrentPlanet() = VisitedPlanets.Last().Planet (0x1471e89c8), and only TravelToNextPlanet appends a
-- VisitedPlanets entry (0x1430d7a1e -> 0x1430d1982). ACT III's planets (CAM_Tour3_*) set bAutoTravelToNextPlanet
-- false and carry a PlaneTestEvent: the planet's last race does not travel, the planet is left FROM THE PADDOCK after
-- its PODRACER TEST (bShowLeaveSequenceAfterPlaneTest). The test harness forced CSM_Paddock_SelectEvent there (its
-- testcmd lines right before each NEXT PLANET), so the next planet's nodes were picked from the old paddock and the
-- run never left Lantaana. Neither the mod nor the gauntlet writes VisitedPlanets. This only says so, once per
-- planet pair: the picked node's planet against the run's current one.
local planetLag = {}
local function planetOf(def)
    local n = U.objName(def)
    local g = package.loaded["gauntlet"]
    local key = n:match("PLA_(%a+)")
    local real = key and type(g) == "table" and g.PLANET and g.PLANET[key]
    return real and string.format("%s (%s)", real, key) or (n ~= "" and n or "?")
end
function M.planetCheck(nodeP)
    local nd = nodeP
    pcall(function() if nd ~= nil and type(nd) ~= "number" and not U.ok(nd) then nd = nodeP:get() end end)
    if not U.ok(nd) then return nil end
    local nodeDef, curDef = nil, nil
    pcall(function() nodeDef = nd.Planet.Planet end)
    pcall(function() curDef = campaignSubsystem().ActiveRun:GetCurrentPlanet() end)
    if not (U.ok(nodeDef) and U.ok(curDef)) or U.key(nodeDef) == U.key(curDef) then return true end
    local k = tostring(U.key(curDef)) .. ">" .. tostring(U.key(nodeDef))
    if not planetLag[k] then
        planetLag[k] = true
        -- couch-fix56: only a NOTE at the pick - a race node of the next planet may still get its planet visit from
        -- the race's own travel (AUTO-118); the race start says whether the run really stayed behind (raceStartPlanet)
        U.log(TAG, "planet check: the picked node is on %s but the run is still on %s at the pick (its last visited "
            .. "planet: the paddock world comes from it) - checked again at the race start", planetOf(nodeDef),
            planetOf(curDef))
    end
    return false
end

-- couch-fix56 (live round 3 runs 42/43, AUTO-137 note): every planet change logged "the run is still on Sentinel I
-- ... The run never left". The source (GetCurrentPlanet = VisitedPlanets.Last()) was the game's own state and right:
-- the paddock world stayed L_Husky_PADDOCK on Jakku, Crait and Ando Prime. The harness (helpers/pick.sh: ChooseNext-
-- MapNode + TravelToNextActivity) picked the next planet's node in the OLD paddock ~6 s after NEXT PLANET landed there,
-- before the native planet travel (TravelToNextPlanet ~8 s after: run 41 15:29:14 L_Husky_PADDOCK -> 15:29:22
-- L_Mastiff_Paddock) - VisitedPlanets never got its entry. Said ONCE per planet pair, at the race start, from the one
-- reader of both sources (couchrun.runPlanet): the game keeps the run on the old planet and so does every mod
-- consumer that follows the game (P2's shop, the strike / results bookkeeping, the gauntlet's write gate); the
-- backer contracts follow the race's own planet.
local planetSkip = {}
function M.raceStartPlanet()
    if not (M.active() or state.on) then return nil end
    local okR, rp = pcall(function() return U.mod("couchrun").runPlanet() end)
    if not (okR and type(rp) == "table" and rp.lag) then return false end
    local k = tostring(rp.visit) .. ">" .. tostring(rp.node)
    if planetSkip[k] then return true end
    planetSkip[k] = true
    local v = rp.visitDef and planetOf(rp.visitDef) or ("planet " .. tostring(rp.visit))
    local nn = rp.nodeDef and planetOf(rp.nodeDef) or ("planet " .. tostring(rp.node))
    U.warn(TAG, "planet check (race start): this race is on %s (planet %d) but the run's last planet visit is %s "
        .. "(planet %d): the planet travel was SKIPPED (TravelToNextPlanet never ran - a node of the next planet picked in "
        .. "the old paddock before the native planet travel, e.g. a test harness's direct pick). The game keeps the run "
        .. "on %s: its paddock world, Hibi's, check-ins and planet-exit flow, P2's shop (planet %d), the strike / results "
        .. "bookkeeping and the gauntlet follow it; the backer contracts count this race's planet %d", nn, rp.node, v,
        rp.visit, v, rp.visit, rp.node)
    return true
end
M._planetSkipForget = function() planetSkip, planetLag = {}, {} end

-- -> what happened: "emptied", "kept" (a stop on the race world / a travel), or why nothing was there to clear
-- ("no guests", "no ActiveRecipe", "already empty"); #67b: the paddock-arrival clear logs the no-op ones
function M.clearGrid(why, nodeP)
    if opt("CouchCampaign", true) ~= true or #guestPlayerStates() == 0 then return "no guests" end
    local rs = U.giSubsystem("EventRecipeSubsystem")
    if not U.ok(rs) then return "no EventRecipeSubsystem" end
    if not U.ok(rs.ActiveRecipe) then return "no ActiveRecipe" end
    local racers = rs.ActiveRecipe.RecipeState.Racers
    local n = racers:GetArrayNum()
    if n == 0 then return "already empty" end
    if St.phase == "TRANSIT" or St.phase == "LOADING" then
        U.log(TAG, "grid of %d racer(s) kept (%s, phase %s: never rewritten during a travel)", n, tostring(why), St.phase)
        return "kept"
    end
    local act = nodeActivity(nodeP)
    local raceWorld = U.isA(U.gs(), "/Script/Griffin.RacingGameState")
    if raceWorld and act ~= nil and not M.GRID_AT_PICK[act] then
        U.log(TAG, "grid of %d racer(s) kept (%s: node activity %d builds no grid and this race world still uses it; "
            .. "the next pick off the race world empties it)", n, tostring(why), act)
        M._gridKept = true
        return "kept"
    end
    -- couch-fix57 (round 4 VANISH 18:05:59, Crait post-race map, node #30 standard: the #67 signature on a RACE pick,
    -- exit 9 inside the native ChooseNextMapNode right after "grid of 12 racer(s) emptied"): never Empty on the race
    -- world, for any activity. Static (CL381121 0x142fe8da2 / hf2 0x142fe99f2, the store of every node pick): the
    -- store NewObject()s a fresh UEventRecipeInstance (0x144d2e80a -> StaticConstructObject), fills ITS empty
    -- RecipeState.Racers (0x142fe92c8) and makes it ActiveRecipe (0x142fe983c). So the old recipe's racers never had to
    -- be emptied for a new grid: the clear only freed the buffer of the recipe the live race world (and the native pick
    -- right after it) still reads = the vanish, on ~1 race pick in 30. The old recipe stays whole; the game's GC
    -- destroys it with its world, as in solo. The post-hook checks that the pick really made a new recipe.
    if raceWorld then
        local okK, key = pcall(function() return U.key(rs.ActiveRecipe) end)
        M._pickKept = { key = okK and key or nil, n = n }
        U.log(TAG, "grid of %d racer(s) kept (%s, race world: the pick stores a fresh recipe; this one stays whole for "
            .. "the race world that still reads it)", n, tostring(why))
        return "kept"
    end
    racers:Empty()
    M._gridKept = nil
    U.log(TAG, "grid of %d racer(s) emptied (%s): the campaign builds a fresh one", n, tostring(why))
    return "emptied"
end

function M.patchGrid(why, force, plane)
    if not M.active() and not (opt("CouchCampaign", true) == true and #guestPlayerStates() > 0
        and (force == true or U.isA(U.gs(), "/Script/Griffin.PaddockGameState"))) then
        return 0
    end
    local guests = guestPlayerStates()
    if #guests == 0 then return 0 end
    -- couchrules (D5/D6): never on a rival race / non-race node, never a protected entry (rival, boss, antagonist).
    -- A plane test (#30) is not the chosen node: the node-activity check does not apply to it.
    local okR, rules = pcall(U.mod, "couchrules")
    rules = (okR and type(rules) == "table") and rules or nil
    -- couch-fix38 (D8): a championship picked as BOSS INSTANCES is placed by couchrules.bossPlace (its post-hook, next)
    if rules and plane ~= true and type(rules.bossPending) == "function" and rules.bossPending() == true then
        U.log(TAG, "grid patch (%s) skipped: boss instances - couchrules places each guest + his own boss", tostring(why))
        return 0
    end
    if rules and plane ~= true then
        local okA, allow, why = pcall(rules.allowGridPatch)
        if okA and allow == false then
            U.log(TAG, "grid patch skipped: %s", tostring(why))
            return 0
        end
    end
    local rs = U.giSubsystem("EventRecipeSubsystem")
    if not (U.ok(rs) and U.ok(rs.ActiveRecipe)) then U.warn(TAG, "grid patch: no ActiveRecipe (%s)", tostring(why)); return 0 end
    -- couch-fix57: a grid kept whole at a race-world pick (clearGrid): the pick must have stored a NEW recipe; the same
    -- one = the old race's grid (its AI PlayerStates die with that world) - never re-pointed / written
    local kept = M._pickKept
    if kept and kept.key ~= nil and tostring(why):find("^node picked") then
        local okK, key = pcall(function() return U.key(rs.ActiveRecipe) end)
        if okK and key == kept.key then
            U.warn(TAG, "grid patch (%s) skipped: the pick stored no new recipe (the old race's grid of %d is still the "
                .. "active one)", tostring(why), kept.n or 0)
            return 0
        end
    end
    local racers = rs.ActiveRecipe.RecipeState.Racers
    local n = racers:GetArrayNum()
    if n == 0 then
        -- a node without a race (mystery / vendor): the builder made no grid, no guest build to write
        U.log(TAG, "grid patch (%s): no grid (a node without a race)", tostring(why))
        return 0
    end
    local have = {}
    for i = 1, n do
        local ps = racers[i].Player
        if U.ok(ps) then have[U.key(ps)] = i end
    end
    local placed, notes = 0, {}
    local nextBot = n
    local tt = M.isTimeTrial()
    -- 3-4 players: entries the guests must never take (the run's rival / nemesis / antagonist: custom opponents of
    -- P1's event), and a non-time-trial grid with a SINGLE AI keeps it (a rival challenge or a championship
    -- head-to-head: that AI is the opponent of P1's event; the guests sit it out). Time trials are grown to
    -- 1 + guests by patchTimeTrials: every AI entry there is a filler. More guests than AI entries: the last ones sit
    -- the race out (logged, no car).
    local free = 0
    for i = 1, n do if M.takeableEntry(racers[i]) then free = free + 1 end end
    -- a single takeable AI is kept for P1's event (an unflagged championship boss in a head-to-head) unless the
    -- event's opponent is already a protected entry (rival / nemesis / antagonist / couchrules.isProtected)
    local protectedIn = false
    for i = 1, n do
        local ps = nil
        pcall(function() ps = racers[i].Player end)
        if U.ok(ps) and ps.bIsABot == true and not M.takeableEntry(racers[i]) then protectedIn = true end
        if U.ok(ps) and rules and rules.isProtected(ps) then protectedIn = true end
    end
    local reserve = (not tt and free == 1 and not protectedIn) and 1 or 0
    local skipped = 0
    for _, g in ipairs(guests) do
        local idx = have[U.key(g.ps)]
        if idx then
            notes[#notes + 1] = string.format("P%d already in (entry %d, %s)", g.pnum, idx,
                guestVehicle(racers, idx, g, tt))
        elseif free - reserve <= 0 then
            skipped = skipped + 1
            notes[#notes + 1] = string.format("P%d: no AI entry to take (grid of %d, %d AI left%s): sits this one out",
                g.pnum, n, free, reserve > 0 and ", the single AI opponent kept" or "")
        else
            for i = nextBot, 1, -1 do
                local ps = racers[i].Player
                if M.takeableEntry(racers[i]) and not (rules and rules.isProtected(ps)) then idx = i; break end
            end
            if not idx then
                skipped = skipped + 1
                notes[#notes + 1] = string.format("P%d: no AI entry to take (grid of %d)", g.pnum, n)
            else
                local was = "?"
                pcall(function() was = racers[idx].Player:GetPlayerName():ToString() end)
                racers[idx].Player = g.ps
                nextBot = idx - 1
                free = free - 1
                placed = placed + 1
                notes[#notes + 1] = string.format("P%d takes entry %d (was %s, %s)", g.pnum, idx, was,
                    guestVehicle(racers, idx, g, tt))
            end
        end
    end
    if skipped > 0 then
        U.warn(TAG, "grid patch (%s): %d guest(s) without an entry (no car this race)", tostring(why), skipped)
    end
    U.log(TAG, "grid patch (%s): %d racer(s), %s", tostring(why), n, table.concat(notes, ", "))
    U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, n) end)   -- every guest's own run build
    return placed
end

---------------------------------------------------------------------------------------------------- time trials
-- Field Test (GMV_Shakedown) and Podracer Test (GMV_PlaneSprint) build a ONE-car grid (06b Q4). While the couch rules
-- apply, their GridMakeup holds 1 + guests entrants (in memory, restored in the front end), so the campaign adds AI
-- entries that patchGrid hands to the guests; the guest copies P1's test vehicle. In the race every human car is
-- seen only from its own view and ignores the other cars' movement: each player races alone (Jules's spec).
local TT_GMV = {
    "/Game/Griffin/Gameplay/Campaign/GameModes/GMV_Shakedown.GMV_Shakedown",
    "/Game/Griffin/Gameplay/Campaign/GameModes/GMV_PlaneSprint.GMV_PlaneSprint",
}
local ttPatch = nil                         -- { {gmv, orig = {{t, n}}} }

local function readGrid(entries)
    local out = {}
    for i = 1, entries:GetArrayNum() do
        out[i] = { t = tonumber(entries[i].EntryType) or 0, n = tonumber(entries[i].NumEntrants) or 0 }
    end
    return out
end

function M.patchTimeTrials(nGuests)
    if opt("CouchTimeTrials", true) == false or (nGuests or 0) < 1 then return end
    if ttPatch and (ttPatch.n or 0) >= nGuests then return end
    if ttPatch then M.restoreTimeTrials() end       -- a guest joined since: grown again from the original grids
    ttPatch = { n = nGuests }
    for _, path in ipairs(TT_GMV) do
        local g = U.obj(path)
        if U.ok(g) then
            local okP, err = pcall(function()
                local entries = g.GridMakeup.Entries
                local orig = readGrid(entries)
                local total = 0
                for _, e in ipairs(orig) do total = total + e.n end
                if #orig >= 1 and total < 1 + nGuests then
                    entries[1].NumEntrants = orig[1].n + (1 + nGuests - total)
                    ttPatch[#ttPatch + 1] = { gmv = g, orig = orig }
                    U.log(TAG, "time trial %s: grid %d -> %d entrant(s) (each guest races it too)",
                        path:match("([%w_]+)$"), total, 1 + nGuests)
                end
            end)
            if not okP then U.warn(TAG, "time trial grid %s not patched: %s", path, tostring(err)) end
        end
    end
end

function M.restoreTimeTrials()
    if not ttPatch then return end
    for _, p in ipairs(ttPatch) do
        -- U.ok: the GMV asset was found in an earlier world; an unloaded one would be a dead object here
        if U.ok(p.gmv) then pcall(function()
            local entries = p.gmv.GridMakeup.Entries
            for i, e in ipairs(p.orig) do entries[i].NumEntrants = e.n end
        end) end
    end
    U.log(TAG, "time trial grids restored (%d)", #ttPatch)
    ttPatch = nil
end

-- #30: the plane test's grid. Its event (a VehicleTestEventDef, EVT_*_PLANE_*) carries its own GridMakeup and its
-- CustomOpponents (Tatooine: 5 named podracers = the 6-car grid of 18:54); the builder adds GridMakeup - 1 - opponents
-- AI fill entries. Pre-hook: every LOADED plane event's first grid entry grows to 1 + opponents + guests, so the builder
-- adds one fill entry per guest (a guest never takes a story podracer); GMV_PlaneSprint too (patchTimeTrials). The
-- grid is emptied first: the store fills RecipeState.Racers only while it is empty (the previous event's grid is still
-- there in a couch run, as before a node pick). An event not loaded yet keeps its grid: the guest then takes the last
-- opponent's entry (logged). Restored in the post-hook, right after the builder.
local function planeDefs()
    local ok, list = pcall(FindAllOf, "VehicleTestEventDef")
    local out = {}
    if ok and type(list) == "table" then
        for _, d in ipairs(list) do
            if U.ok(d) then
                local okN, n = pcall(function() return d:GetFName():ToString() end)
                if not (okN and type(n) == "string" and n:find("^Default__")) then out[#out + 1] = d end
            end
        end
    end
    return out
end

-- couch-trial2: the planets' plane tests (CampaignPlanetSetup.PlaneTestEvent is a SOFT reference: the event may not be
-- in memory at the kickoff, and an unloaded event cannot be grown for instances). Asset registry (work/asset-registry
-- .txt): the 7 present-day plane test events. Loaded (U.obj: StaticFindObject, else LoadAsset) right before the scan.
local PLANE_EVENTS = { "BGL", "BGL_PLANE_PDay_ACT2", "COR", "DAL", "MAS", "SPA", "WHP" }
local function preloadPlaneEvents()
    if opt("CouchInstancesPreload", true) ~= true then return end
    local got = 0
    for _, k in ipairs(PLANE_EVENTS) do
        local name = k:find("_", 1, true) and ("EVT_" .. k) or ("EVT_" .. k .. "_PLANE_PDay")
        local path = "/Game/Griffin/Gameplay/Events/Plane_PresentDay/" .. name .. "." .. name
        local o = nil
        pcall(function() o = U.obj(path) end)
        if U.ok(o) then got = got + 1 end
    end
    U.log("instances", "kickoff: %d/%d present-day plane test event(s) in memory", got, #PLANE_EVENTS)
end

-- couch-fix29: a new grid drops the previous race's couch build record (perkapply couchRaceTick: never re-used)
local function forgetCouchBuilds(why) pcall(function() U.mod("perkapply").couchForget(why) end) end

function M.planeTestPre()
    planeT.kicked = false
    forgetCouchBuilds("plane test kickoff")
    pcall(function() U.mod("instances").reset("plane test kickoff") end)
    if opt("CouchTimeTrials", true) == false then return end
    local nG = #guestPlayerStates()
    if nG < 1 or not (M.active() or opt("CouchCampaign", true) == true) then return end
    pcall(function() if U.mod("instances").enabled() then preloadPlaneEvents() end end)
    U.try(TAG, M.clearGrid, "before the plane test")
    M.patchTimeTrials(nG)
    planeT.patch = {}
    planeT.instS = {}
    local notes = {}
    local inst = nil
    pcall(function() inst = U.mod("instances") end)
    for _, d in ipairs(planeDefs()) do
        local okP, err = U.ok(d) and pcall(function()
            local entries = d.GridMakeup.Entries
            local orig = readGrid(entries)
            local total, opp = 0, 0
            for _, e in ipairs(orig) do total = total + e.n end
            pcall(function() opp = U.arrayCount(d.CustomOpponents) end)
            local name = d:GetFName():ToString()
            local want = 1 + opp + nG
            -- couch-trial2: MISSION INSTANCES - each human his own copy of the event's field (instances.lua)
            local iw, iS, iwhy = nil, nil, nil
            if inst then iw, iS, iwhy = inst.gridFor(total, opp, nG, name) end
            if iw then
                want = iw
                planeT.instS[name] = iS
            elseif inst and iwhy then
                U.log("instances", "kickoff: no instances for %s (%s): shared field, the humans ghosted", name, iwhy)
            end
            if #orig >= 1 and total < want then
                entries[1].NumEntrants = orig[1].n + (want - total)
                planeT.patch[#planeT.patch + 1] = { def = d, orig = orig }
                notes[#notes + 1] = string.format("%s %d -> %d", name, total, want)
            end
        end)
        if not okP then U.warn(TAG, "plane test grid not patched: %s", tostring(err)) end
    end
    U.log(TAG, "plane test kickoff: %d guest(s); %s", nG,
        #notes > 0 and ("event grid(s) " .. table.concat(notes, ", ")) or "no loaded plane event grid to grow")
    if inst and inst.enabled() and next(planeT.instS) == nil then
        U.warn("instances", "kickoff: no loaded plane event can hold the instances: shared field (couch-trial)")
    end
end

local function planeRestore()
    for _, p in ipairs(planeT.patch or {}) do
        if U.ok(p.def) then pcall(function()
            local entries = p.def.GridMakeup.Entries
            for i, e in ipairs(p.orig) do entries[i].NumEntrants = e.n end
        end) end
    end
    planeT.patch = nil
end

function M.planeTestPost()
    planeRestore()
    if #guestPlayerStates() < 1 then return end
    if not planeTestActive() then
        U.warn(TAG, "plane test kickoff: no ActivePlaneTestEvent after the native call (no grid patch)")
        return
    end
    planeT.kicked = true
    -- couch-trial2: the event's instances (instances.lua), else the couch-trial grid patch (shared field)
    local ev, S = nil, nil
    pcall(function()
        local d = campaignSubsystem().ActiveRun.ActivePlaneTestEvent
        if U.ok(d) then ev = d:GetFName():ToString() end
    end)
    S = ev and planeT.instS and planeT.instS[ev] or nil
    planeT.instS = nil
    if S then
        local inst = U.mod("instances")
        local okI, placed, why = pcall(function()
            local rs = U.giSubsystem("EventRecipeSubsystem")
            local racers = rs.ActiveRecipe.RecipeState.Racers
            local p1ps = nil
            pcall(function() p1ps = U.localPlayers()[1].pc.PlayerState end)
            local placed, why = inst.assignGrid(racers, guestPlayerStates(), S, p1ps)
            if placed then
                U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, U.arrayCount(racers)) end)
            end
            return placed, why
        end)
        if okI and placed then
            U.log(TAG, "plane test: %d guest(s) on the grid, each in his own instance of %s", placed, tostring(ev))
            return
        end
        U.warn("instances", "kickoff: FALLBACK to the shared field (%s)", okI and tostring(why) or tostring(placed))
    elseif ev then
        U.log("instances", "kickoff: %s not grown for instances: shared field (couch-trial)", tostring(ev))
    end
    local placed = M.patchGrid("plane test kicked off", true, true)
    U.log(TAG, "plane test: %d guest(s) on the grid (each races the mission alone, in his own view)", placed or 0)
end

---------------------------------------------------------------------------------------------------- field tests
-- #37 / #39 (Jules's round 4, Crait TAKEDOWNS field test, 2026-10-17 21:58): "P1 and P2 should have independent
-- sessions and scores" - every field test, 1-car or with its own opponents, is one instance per player. The 1-car ones
-- are planned in the race (instances.planSolo). A field test with opponents (the SHK_BAT TAKEDOWNS events:
-- ShakedownEventDef, GridMakeup Car x8, 7 CustomOpponents) needs its grid grown BEFORE the native builder reads it.
-- #51 (overnight 2026-10-18, tester #2, Lantaana EVT_SHK_BAT_Skimmer_DAL_A_SHORT_01, twice): the NODE PICK builds no
-- recipe (the test starts from its paddock intro), so the pick-time growth (d2eb0ec) was restored before any build =
-- "NO INSTANCES - shared field"; a placement from a 250 ms poll (5784810) ran in the TRANSIT tick of the seamless travel
-- and the game process vanished (reverted 02ac3b6). WHERE THE GRID IS REALLY BUILT, proven on the live exe (Steam
-- build md5 ad8cf3f6..., hf2), static disassembly (capstone) + the native table:
--   FNameNativePtrPair "FinishLeaving" -> exec 0x1470b0500 (Stack.Code++, jmp) -> impl 0x142fb094a: CampaignRun
--   (subsystem+0xc8); a running narrative event -> 0x1430ddff6; else the PaddockGameState's ActiveMysteryInteraction
--   (+0x370) with MysteryInteractionOutcome (+0x388) - or the interaction's MandatoryChoice.MandatoryOutcome, or that
--   choice's only Outcome - whose ResultEvent (+0x188) is set -> call 0x1430ce7f4 = CampaignRun::
--   KickOffMysteryInteractionEvent (its ONLY native caller: the other reference is its own UFunction thunk 0x1471ea132,
--   which no BP calls - the hook on it never fires). Inside: not a PlaneSprint node -> 0x142fea6e8 = the all-PC
--   builder (every PlayerController + the event's CustomOpponents + fill from the EVENT's GridMakeup), the activity-9
--   tag 0x1430d9420, then tail-jump 0x142febfd8 = the travel REQUEST (ProcessServerTravel -> SeamlessTravel only starts
--   loading the transition map; the world switch is a later tick). FinishLeaving is a BP-called UFunction
--   (BP_Csm_Paddock_WipeAndLeave_Finish): UE4SS hooks fire. So: PRE = grow the ResultEvent's grid (nothing built yet),
--   POST = grids restored + the new grid re-dressed per player (instances.assignGrid: set g = guest g + copies of P1's
--   opponents; adapt = a grid the builder clamped gives smaller sets) while the paddock world still stands - never from
--   a poll, never in the TRANSIT tick (refused + WARN if the phase is not the paddock's). Not grown / not placed = the
--   builder's own all-PC field (every human on it natively; soloscore counts per player) with a WARN.
local ft = nil                                   -- { patch = { {def, orig} }, instS = {[event] = S}, nG }
-- couch-fix29: this FinishLeaving kicks off a race event (a field test / a podracer node): {ev, pod}. Its post-hook gives
-- the guests on the new grid their builds (couchrun.applyBuilds) when the placement did not
local ftKick = nil

-- the event FinishLeaving's native body will kick off (impl 0x142fb094a, see above): the paddock's mystery outcome's
-- ResultEvent. -> event object (nil when only its name is known), where it came from (or nil, why), the event's name
-- couch-fix52 (AUTO-135 / AUTO-137, Act II couch at ch=16 dn=15, 4 dumps crash_2026_10_18_16_14_13 / 16_18_16 / 16_22_05
-- / 17_09_36, same unwind with the hf2 UE4SS.dll md5 38d8d2e0): VCRUNTIME140 memcpy(dst, src NULL, r8 0xb3a448) <-
-- UE4SS+0x234545 FString copy <- +0x4704a0 FSoftObjectPath copy <- +0x2cb760 push_softobjectproperty <- +0x2aad40 UObject
-- member __index <- +0xb99090 lua_gettable, under the FinishLeaving pre-hook. MysteryInteractionOutcome.ResultEvent is a
-- SoftObjectProperty (+0x180, UE4SS_ObjectDump), NOT an object: the FINDING #111 layout bug on a plain member (the path
-- read 8 bytes past it: Data = SubPathString's Num/Max = NULL, Num = the low dword of DialogueEvent at +0x1a8 = 0x59d224).
-- An outcome with a DialogueEvent crashes EVERY time (the paddock's planet-exit field test after Ando Prime), one without
-- reads "fine" (the earlier live kickoffs). pcall does not catch it. So the soft member is never read: the event's NAME
-- comes from mystdata.EVENTS (static, per interaction: each of the 94 pre-event interactions kicks off one event from
-- every outcome), the OBJECT from the interaction's RaceWithCustomVehicle (a hard ObjectProperty, +0x120, loaded with
-- the interaction) when it is that event - the 84 MYST_SHK_* (a field test needs the object: its grid is grown). The 10
-- MYST_TT_*_PLANE carry another RaceWithCustomVehicle than their outcome's event: name only (the podracer branch needs
-- no more). An interaction mystdata does not know (a newer game build): its RaceWithCustomVehicle if it is a field test.
local okMD, MD = pcall(require, "mystdata")
local function leavingEvent()
    local gs = U.gs()
    if not U.isA(gs, "/Script/Griffin.PaddockGameState") then return nil, "not a paddock" end
    local inter = nil
    pcall(function() inter = gs.ActiveMysteryInteraction end)
    if not U.ok(inter) then return nil, "no ActiveMysteryInteraction" end
    local iname = U.objName(inter)
    local rv, rvName = nil, ""
    pcall(function() rv = inter.RaceWithCustomVehicle end)
    if U.ok(rv) then rvName = U.objName(rv) else rv = nil end
    local evName = okMD and type(MD) == "table" and type(MD.EVENTS) == "table" and MD.EVENTS[iname] or nil
    if evName then
        if rv and rvName == evName then return rv, "the outcome's event (mystdata) = RaceWithCustomVehicle", evName end
        return nil, "the outcome's event (mystdata), name only", evName
    end
    if rv and U.isA(rv, "/Script/Griffin.ShakedownEventDef") then
        return rv, "the interaction's RaceWithCustomVehicle (" .. iname .. " not in mystdata)", rvName
    end
    return nil, "no event in mystdata for " .. (iname ~= "" and iname or "?") .. " (the soft ResultEvent is never read)"
end
M.leavingEvent = leavingEvent

-- PaddockGameMode:FinishLeaving PRE
function M.fieldTestPre()
    if ft then M.fieldTestRestore("a new FinishLeaving") end
    ft = nil
    ftKick = nil
    if #guestPlayerStates() > 0 and (M.active() or opt("CouchCampaign", true) == true) then
        local _, _, kn = leavingEvent()
        if kn then
            ftKick = { ev = kn, pod = chosenActivity() == 10 }
            forgetCouchBuilds("kickoff of " .. kn)
        end
    end
    if opt("CouchFieldTestInstances", true) ~= true or opt("CouchTimeTrials", true) == false then return end
    local nG = #guestPlayerStates()
    if nG < 1 or not (M.active() or opt("CouchCampaign", true) == true) then return end
    local ev, src, evName = leavingEvent()
    if not evName then                                                 -- an ordinary leave (no kickoff)
        if src ~= "no ActiveMysteryInteraction" and src ~= "not a paddock" then
            U.log("instances", "leaving the paddock: a mystery interaction without a race event (%s)", tostring(src))
        end
        return
    end
    -- #67: a grid kept at a stop pick on the post-race map: the paddock's builder fills only an empty one
    if M._gridKept then U.try(TAG, M.clearGrid, "before the paddock's builder: kept since a stop pick") end
    if chosenActivity() == 10 then                                     -- KickOff's PlaneSprint branch
        -- #88 (live 2026-10-18 09:03, Crait EVT_TT_SPA_A_PLANE via a podracer node): this branch is the ONE-human
        -- campaign builder (P1 + AI fill from GMV_PlaneSprint, grown 1 -> 1 + guests by patchTimeTrials): the guests'
        -- fill entries were never re-pointed ("1 guest(s) sit this race out", "NO INSTANCES - shared field"). The
        -- post-hook gives every guest his own entry (P1's mission pod + pilot, as a plane test) and his own instance
        -- (S = 1). The fill is made sure here, before the builder reads GMV_PlaneSprint.
        local inst = nil
        pcall(function() inst = U.mod("instances") end)
        if not (inst and inst.enabled()) then
            U.log("instances", "leaving the paddock for %s (podracer node): CouchMissionInstances off, guests not placed",
                evName)
            return
        end
        U.try(TAG, M.patchTimeTrials, nG)
        ft = { patch = {}, instS = { [evName] = 1 }, nG = nG, ev = evName, pod = true }
        U.log("instances", "podracer node kickoff (FinishLeaving pre, %s): %s, %d guest(s): the one-human builder fills "
            .. "GMV_PlaneSprint; each guest gets his own entry + instance after it", tostring(src), evName, nG)
        return
    end
    if not (ev and U.isA(ev, "/Script/Griffin.ShakedownEventDef")) then
        U.log("instances", "leaving the paddock for %s (%s): not a field test", evName, tostring(src))
        return
    end
    local opp = 0
    pcall(function() opp = U.arrayCount(ev.CustomOpponents) end)
    if opp < 1 then                                                    -- a 1-car test: instances.planSolo in the race
        U.log("instances", "leaving the paddock for %s (%s): a 1-car field test (instances planned in the race)",
            evName, tostring(src))
        return
    end
    local inst = nil
    pcall(function() inst = U.mod("instances") end)
    if not (inst and inst.enabled()) then
        U.warn("instances", "field test %s: CouchMissionInstances off: its opponents share one field", evName)
        return
    end
    ft = { patch = {}, instS = {}, nG = nG, ev = evName }
    local cap = tonumber(opt("CouchFieldTestMaxGrid", 32)) or 32
    local note, okP, err = nil, nil, nil
    okP, err = pcall(function()
        local entries = ev.GridMakeup.Entries
        local orig = readGrid(entries)
        local total = 0
        for _, e in ipairs(orig) do total = total + e.n end
        -- Q8 B (Jules 2026-10-18): every player's copy is solo's whole field (3P = 24, 4P = 32 racers); only past the
        -- cap the sets shrink, and then soloscore scales the takedown target to the set (and says so on the HUD)
        local want, S, why, fullS = inst.gridFor(total, opp, nG, evName, { cap = cap, capKey = "CouchFieldTestMaxGrid",
                                                                           shrink = true })
        if not want then note = tostring(why); return end
        if #orig >= 1 and want > total then
            entries[1].NumEntrants = orig[1].n + (want - total)
            ft.patch[#ft.patch + 1] = { def = ev, orig = orig }
            ft.instS[evName] = S
            ft.fullS = fullS
            note = string.format("grid %d -> %d%s", total, want, why and ("; " .. why) or "")
        end
    end)
    if not okP then U.warn(TAG, "field test grid not grown: %s", tostring(err)) end
    U.log("instances", "field test kickoff (FinishLeaving pre, %s): %s, %d guest(s); %s", tostring(src), evName, nG,
        note or "not grown")
end

function M.fieldTestRestore(why)
    for _, p in ipairs((ft and ft.patch) or {}) do
        if U.ok(p.def) then pcall(function()
            local entries = p.def.GridMakeup.Entries
            for i, e in ipairs(p.orig) do entries[i].NumEntrants = e.n end
        end) end
    end
    if ft and why then U.log("instances", "field test grids restored (%s)", tostring(why)) end
end

-- PaddockGameMode:FinishLeaving POST. -> true when the field test's grid was placed per player (instances), and whether
-- the guests' builds were applied (couch-fix29)
local function fieldTestPlace()
    if not ft then return false end
    local f = ft
    M.fieldTestRestore()
    ft = nil
    if next(f.instS) == nil then return false end
    -- the travel was only REQUESTED inside FinishLeaving: the paddock world still stands. Anything else (the TRANSIT
    -- tick: 5784810 vanished there) = no placement
    if St.phase ~= "OTHER" then
        U.warn("instances", "field test %s: FinishLeaving returned in phase %s: no placement (SHARED FIELD)", f.ev,
            tostring(St.phase))
        return false
    end
    local racers, n = nil, 0
    pcall(function()
        racers = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe.RecipeState.Racers
        n = U.arrayCount(racers)
    end)
    if n < 2 then
        U.warn("instances", "field test %s: no recipe after FinishLeaving (%d racer(s)): SHARED FIELD", f.ev, n)
        return false
    end
    local guests = guestPlayerStates()
    local ev, S = f.ev, f.instS[f.ev]
    if not S then
        U.warn("instances", "field test %s (grid of %d) was not grown: SHARED FIELD (the players ghosted, one count)",
            tostring(f.ev), n)
        return false
    end
    local inst = U.mod("instances")
    local p1ps = nil
    pcall(function() p1ps = U.localPlayers()[1].pc.PlayerState end)
    if f.pod then
        -- #88: the podracer node's grid = P1 + one AI fill entry per guest: each fill entry becomes a guest in P1's
        -- mission pod with the mission pilot (assignGrid's plane-test dressing), one instance each. No couch build: the
        -- mission pod is the test (couchrun.applyBuilds is not run, as research 08 V3)
        local okP, placedP, whyP = pcall(inst.assignGrid, racers, guests, 1, p1ps, { kind = "planesprint", ev = ev })
        if not (okP and placedP) then
            U.warn("instances", "podracer node %s: guests NOT placed (%s): they sit the race out", tostring(ev),
                okP and tostring(whyP) or tostring(placedP))
            return false
        end
        U.log(TAG, "podracer node %s: %d guest(s) on the grid in P1's mission pod, each in his own instance",
            tostring(ev), placedP)
        -- couch-fix29: a podracer test races the racer's own build (P1's pod reads his): the guests' builds too
        U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, U.arrayCount(racers), { pod = true }) end)
        return true, true
    end
    local okI, placed, why = pcall(inst.assignGrid, racers, guests, S, p1ps,
        { adapt = true, kind = "fieldtest", ev = ev, guestPilot = "own", fullS = f.fullS })
    if not (okI and placed) then
        U.warn("instances", "field test %s: FALLBACK to the shared field (%s)", tostring(ev),
            okI and tostring(why) or tostring(placed))
        return false
    end
    -- couch-fix29: the guests' builds for a field test = the test's own build (as P1's) + their traits (applyBuilds)
    U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, U.arrayCount(racers), { field = true }) end)
    U.log(TAG, "field test %s: %d guest(s) on the grid, each in his own instance", tostring(ev), placed)
    return true, true
end

-- couch-fix29: a kickoff whose guests were not placed by fieldTestPlace (a 1-car field test, a shared-field fallback,
-- the all-PC builder's own grid) still gets their builds, from the paddock world only (never in TRANSIT)
local function kickBuilds(kick)
    if St.phase ~= "OTHER" then
        U.warn(TAG, "kickoff of %s: FinishLeaving returned in phase %s: the guests' builds not applied", tostring(kick.ev),
            tostring(St.phase))
        return
    end
    local racers, n = nil, 0
    pcall(function()
        racers = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe.RecipeState.Racers
        n = U.arrayCount(racers)
    end)
    if n < 1 then return end
    U.mod("couchrun").applyBuilds(racers, n, { pod = kick.pod, field = not kick.pod })
end

function M.fieldTestPost()
    local kick = ftKick
    ftKick = nil
    local okP, placed, built = U.try(TAG, fieldTestPlace)
    if not okP then placed, built = false, false end
    if kick and not built then U.try(TAG, kickBuilds, kick) end
    return placed == true
end

-- In a time trial: every human car visible only from its own view, and no human car blocks another.
local ghosted = {}
local ghostedGen = nil
function M.ghostCars(why)
    local cars = {}
    for _, e in ipairs(U.localPlayersRO()) do
        local car = nil
        pcall(function() car = e.pc.Pawn end)
        if U.isVehicle(car) then cars[#cars + 1] = car end
    end
    if #cars < 2 then return 0 end
    -- per world (race): keys are addresses, the next race's pawns reuse them
    if ghostedGen ~= St.worldGen then ghosted, ghostedGen = {}, St.worldGen end
    local prim = U.class("/Script/Engine.PrimitiveComponent")
    local n = 0
    for _, car in ipairs(cars) do
        if not ghosted[U.key(car)] then
            local raw = -1
            local okG, errG = pcall(function()
                -- UE4SS returns this TArray as a plain Lua TABLE: comps:GetArrayNum() threw inside the pcall and
                -- nothing was ever ghosted ("0 component(s)", P2's car visible in P1's view, live 2026-10-14)
                local list = U.arrayToTable(car:K2_GetComponentsByClass(prim))
                raw = #list
                for _, c0 in ipairs(list) do
                    -- ...and each element is a RemoteUnrealParam (U.ok false on the wrapper): :get() the component
                    -- (still "0 component(s)" after 2ebcdb1, live 2026-10-14 field test)
                    local c = c0
                    if type(c0) == "userdata" and not U.ok(c0) then pcall(function() c = c0:get() end) end
                    if U.ok(c) then
                        pcall(function() c:SetOnlyOwnerSee(true) end)
                        for _, other in ipairs(cars) do
                            if other ~= car then pcall(function() c:IgnoreActorWhenMoving(other, true) end) end
                        end
                        n = n + 1
                    end
                end
            end)
            if not okG or raw <= 0 then
                U.warn(TAG, "time trial ghosting of a car: %s (%d component param(s) returned)", okG and "no component" or tostring(errG), raw)
            end
            ghosted[U.key(car)] = true
        end
    end
    U.log(TAG, "time trial (%s): %d car(s) ghosted, %d component(s): each player races alone", tostring(why), #cars, n)
    return #cars
end

---------------------------------------------------------------------------------------------------- race letterbox
-- Jules: "remove cinematic bar at the beginning of races". The game letterboxes every camera actor through a
-- post-process (r.CinematicCamera.ConstrainAspectRatioUsingPostProcess, chasecam.lua) whose 16:9 rect is in absolute
-- pixels: in split screen both views get black bars during the intro. Off in couch races (LOADING -> leaving), and the
-- intro's cine cameras lose their aspect constraint; paddock cinematics keep their letterbox.
local lbOff = false
local function letterbox(on, why)
    if on == not lbOff then return end
    pcall(U.console, "r.CinematicCamera.ConstrainAspectRatioUsingPostProcess " .. (on and "1" or "0"))
    lbOff = not on
    U.log(TAG, "race intro letterbox %s (%s)", on and "restored" or "OFF", tostring(why))
end

function M.unconstrainCameras()
    local n = 0
    for _, cls in ipairs({ "CineCameraComponent", "CameraComponent" }) do
        pcall(function()
            for _, c in ipairs(FindAllOf(cls) or {}) do
                if U.ok(c) and U.alive(c) then
                    local on = false
                    pcall(function() on = c.bConstrainAspectRatio == true end)
                    if on then
                        pcall(function() c:SetConstraintAspectRatio(false) end)
                        n = n + 1
                    end
                end
            end
        end)
    end
    if n > 0 then U.log(TAG, "race intro: %d camera(s) unconstrained (no letterbox in split views)", n) end
    return n
end

-- The intro / ignition shots are FuseCinematicCameraActors whose FuseCinematicCameraComponent has its OWN
-- bConstrainAspectRatioUsingPostProcess = true (live 2026-10-14: ar 2.39, bConstrainAspectRatio false, so the cvar and
-- unconstrainCameras miss it): the post-process letterbox pillarboxed P1's strip. Every 150 ms of PRERACE (and the
-- first seconds of RACING) each local view target's camera components lose the post-process constraint.
local lbPoll = { gen = 0, seen = {} }
function M.unletterboxViews()
    local n = 0
    local camCls = U.class("/Script/Engine.CameraComponent")
    if not U.ok(camCls) then return 0 end
    for _, e in ipairs(U.localPlayersRO()) do
        pcall(function()
            local vt = e.pc.PlayerCameraManager.ViewTarget.Target
            if not U.ok(vt) or U.isVehicle(vt) then return end
            for _, c in ipairs(U.arrayToTable(vt:K2_GetComponentsByClass(camCls))) do
                if U.ok(c) and c:GetConstraintAspectRatioUsingPostProcess() == true then
                    c:SetConstrainAspectRatioUsingPostProcess(false)
                    pcall(function() c:SetConstraintAspectRatio(false) end)
                    n = n + 1
                end
            end
        end)
    end
    if n > 0 then U.dbg(TAG, "race intro: %d cinematic camera(s) lost their post-process letterbox", n) end
    lbPoll.total = (lbPoll.total or 0) + n
    return n
end

local function lbPollStart()
    lbPoll.gen = lbPoll.gen + 1
    lbPoll.total, lbPoll.racingAt = 0, nil
    local gen, untilMs = lbPoll.gen, St.nowMs() + 30000
    local sched = U.mod("sched")
    local function step()
        if gen ~= lbPoll.gen or not lbOff then return end
        if St.phase ~= "PRERACE" and St.phase ~= "RACING" then return end
        -- race fast path: the race cameras are the cars' own 2 s after the start; nothing left to unletterbox
        if St.phase == "RACING" then
            lbPoll.racingAt = lbPoll.racingAt or St.nowMs()
            if St.nowMs() - lbPoll.racingAt > 2000 then
                U.log(TAG, "race intro: %d cinematic camera(s) unletterboxed (poll ends 2 s into the race)", lbPoll.total or 0)
                return
            end
        end
        if St.nowMs() > untilMs or M.isQuiet() then
            if St.nowMs() > untilMs then
                U.log(TAG, "race intro: %d cinematic camera(s) unletterboxed", lbPoll.total or 0)
                return
            end
        else
            U.try(TAG, M.unletterboxViews)
        end
        sched.after("couch.lbpoll", 150, step)
    end
    sched.after("couch.lbpoll", 50, step)
end

---------------------------------------------------------------------------------------------------- shared menus
-- The game gives every screen to the LAST local PlayerController (feowner research): with a guest joined, the
-- paddock / post-race / map screens belong to the guest and only the guest's pad drives them (live 2026-10-14).
-- While such a screen is up the pad ids are SWAPPED (GameplayStatics:SetPlayerControllerID): the screen owner carries
-- P1's id (new screens then take P1's pad by themselves), the screen open at the swap is re-focused for its owner, and
-- P1's own PlayerController (now on the guest's pad id) gets its focus parked on an invisible sink - so P1 alone
-- directs the shared moments. Walking and racing use the normal ids.
local swap = { on = false, sink = nil, lastScanMs = 0, owner = nil, orig = nil, parked = false, parkFor = nil }
local quietUntil = 0

-- 3-4 players (couch-4p): the screen owner is any local PC but P1's (the game picks the LAST one; a guest-owned
-- screen of another guest is handled the same way). While swapped: the owner carries P1's ORIGINAL id (his physical
-- pad, 0), P1's PC carries the owner's original id, every other local PC keeps its own; "normal" restores exactly the
-- ids recorded at the first swap (swap.orig, pc key -> id). Each id change goes through a distinct temporary id first
-- (TEMP_ID + i): with the engine's SetControllerId the holder of a target id would otherwise swap with the mover.
local TEMP_ID = 7

-- pure: the wanted ids while swapped. orig = {[pcKey] = id}; -> {[pcKey] = id} or nil (unknown key / owner = P1)
function M.swapPlan(orig, p1Key, ownerKey)
    if type(orig) ~= "table" or orig[p1Key] == nil or orig[ownerKey] == nil or p1Key == ownerKey then return nil end
    local want = {}
    for k, id in pairs(orig) do want[k] = id end
    want[ownerKey], want[p1Key] = orig[p1Key], orig[ownerKey]
    return want
end

-- Moves every local PC whose id differs from want[key] (temp ids first). -> number of PCs moved (errors raised)
local function applyIds(GS, lp, want)
    local changed = {}
    for _, e in ipairs(lp) do
        if U.ok(e.pc) then
            local k = U.key(e.pc)
            local cur = GS:GetPlayerControllerID(e.pc)
            if want[k] ~= nil and cur ~= want[k] then changed[#changed + 1] = e end
        end
    end
    for i, e in ipairs(changed) do GS:SetPlayerControllerID(e.pc, TEMP_ID + i - 1) end
    for _, e in ipairs(changed) do GS:SetPlayerControllerID(e.pc, want[U.key(e.pc)]) end
    -- the campaign saves follow the holder of pad id 0 (M.saveOwnerSync: P1's account folder, never the root slot)
    if #changed > 0 then U.try(TAG, M.saveOwnerSync, "pad ids moved") end
    return #changed
end

local function liveIds(GS, lp)
    local ids = {}
    for _, e in ipairs(lp) do
        if U.ok(e.pc) then
            local okI, id = pcall(function() return GS:GetPlayerControllerID(e.pc) end)
            if okI and type(id) == "number" then ids[U.key(e.pc)] = id end
        end
    end
    return ids
end

-- PARK (cfg.CouchSwapPark, live 2026-10-14, true 2-player game): while swapped, P1's PC carries the owner's id = the
-- guest's PHYSICAL pad, and P1's LocalPlayer is the one the game's InputModeManager gives IMC_UI (re-applied on every
-- OnControlMappingsRebuilt: removing it or a blocker context failed live). CommonUI's input preprocessor routes the
-- FIRST KeyDown of that pad to P1's action router: the guest's A on his own strip confirmed P1's native VEHICLE SELECT
-- / opened P1's favour picker, and a short A never reached the guest's invisible button (only the key repeats did:
-- >= 250 ms presses worked). With a 3rd local player owning the screens the guest's pad stayed on his own PC and all
-- worked. So while a guest split is open (couchprerun / couchpanel / couchroot), P1's PC waits on PARK_ID instead:
-- the guest's pad reaches NO LocalPlayer, CommonUI lets the key through to Slate, and the Slate user of that pad (from
-- the device, not from a LocalPlayer) keeps the focus on the guest's own tiles. Consequences handled here:
-- SetUserFocus needs a PC on the guest's id (M.withPadId moves P1's PC there for the call and back), HasUserFocus(pc)
-- cannot name the guest's user (M.parkedFocus: any user's focus but no local player's), join.padPcFor /
-- couchpanel.padPC get P1's PC from M.padHolder. The split's end puts P1's PC back on the swap id; the unswap,
-- players changed, phase changes and the hot-reload repair (M.normalIds) bring every id back as before.
local PARK_ID = 6
M.PARK_ID = PARK_ID
local UNPARK_MIN_MS = 500                    -- withPadId: at most one focus round trip per 500 ms

-- pure: ids without the leftovers of a park / a swap whose record is lost (hot reload). ids = {[pcKey] = id};
-- -> a copy where P1 is back on 0 when a park / temp id or another PC holds 0, and every other PC on an id < PARK_ID
-- (its own when free, else the lowest free one from 1)
function M.normalIds(ids, p1Key)
    local out, used = {}, {}
    for k, id in pairs(ids) do out[k] = id end
    local p1 = out[p1Key]
    local holder0 = nil
    for k, id in pairs(out) do if id == 0 and k ~= p1Key then holder0 = k end end
    if p1 ~= nil and p1 ~= 0 and (p1 >= PARK_ID or holder0 ~= nil) then
        out[p1Key] = 0
        if holder0 then out[holder0] = (p1 < PARK_ID) and p1 or -1 end
    end
    for _, id in pairs(out) do if id >= 0 and id < PARK_ID then used[id] = (used[id] or 0) + 1 end end
    local keys = {}
    for k in pairs(out) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local id = out[k]
        if id < 0 or id >= PARK_ID or (used[id] or 0) > 1 then
            if id >= 0 and id < PARK_ID then used[id] = used[id] - 1 end
            local f = 1
            while used[f] do f = f + 1 end
            out[k], used[f] = f, 1
        end
    end
    return out
end

-- a guest split is open (each module asked without loading it: the simulator and tests load only some)
local function splitOpen()
    local r = package.loaded["couchroot"]
    if type(r) == "table" and type(r.active) == "function" then
        local ok, on = pcall(r.active)
        if ok and on == true then return true end
    end
    local pr = package.loaded["couchprerun"]
    if type(pr) == "table" and type(pr.state) == "function" then
        local ok, s = pcall(pr.state)
        if ok and type(s) == "table" and s.open == true then return true end
    end
    local cp = package.loaded["couchpanel"]
    if type(cp) == "table" and type(cp.isOpen) == "function" then
        local ok, on = pcall(cp.isOpen)
        if ok and on == true then return true end
    end
    -- NOTE 11: the guests' own-shop launcher on the run map: their A must reach only their invisible buttons (unparked,
    -- the screen owner's short A goes to P1's CommonUI router: the live guest-pad leak)
    if type(cp) == "table" and type(cp.launcherUp) == "function" then
        local ok, on = pcall(cp.launcherUp)
        if ok and on == true then return true end
    end
    return false
end
-- Input matrix (couchsim results / credits / recap / strikes / pause, 2026-10-15): on a shared screen WITHOUT a guest
-- split the plain swap still put the screen owner's pad on P1's LocalPlayer, so the guest's short A / B reached P1's
-- CommonUI router - the live leak (his A confirming P1's VEHICLE SELECT) on every no-split moment: results, credits,
-- run recap, strike popups, the paddock pause. cfg.CouchSwapParkAlways (default true): P1's PC waits on PARK_ID for as
-- long as the ids are swapped; that guest's pad reaches no player at all on a shared screen (P1 alone drives it).
-- false = parked only while a split is open (the first park version).
local function parkWanted()
    if opt("CouchSwapPark", true) == false then return false end
    return opt("CouchSwapParkAlways", true) ~= false or splitOpen()
end
M.parkWanted = parkWanted

-- couch-fix53 (AUTO-131, live round 3 15:18:27 / 15:25:15 / 15:29:13): the MAP INPUT HOLD. While a guest still chooses
-- his rewards and P1 is on the held run map (couchpanel.mapHeld), the screen owner (P1's pad id 0 while swapped) waits
-- on HOLD_ID and P1's PC takes his own id 0 back: P1's pad reaches HIS LocalPlayer, whose CommonUI router owns none of
-- the map screens (the game gives them to the LAST local PC), so no IA_UI_Accept of the map can trigger - the node
-- buttons' TriggeringInputAction and the overview's RegisterActionBinding(IA_UI_Accept -> OnAccept) fire on the
-- OWNER's router whatever the widgets' enabled state (fix32 / fix51 disabled them: P1's A still picked / travelled).
-- Pad id 0 stays a local player's (P1's own LocalPlayer = his account folder: BUG 1, the saves never go to the root
-- slot); the guest's pad stays parked (P1's PC is on id 0, not on his). Undone by M.mapInputHold(false), the unswap
-- (setIds(nil) restores swap.orig), a players change. HOLD_ID: clear of the pads (0-3), PARK_ID 6, TEMP_ID 7-10 and
-- PARK_EXTRA 11-14.
local HOLD_ID = 16
M.HOLD_ID = HOLD_ID

-- the swap plan + the park: P1's PC on PARK_ID instead of the owner's original id; hold (couch-fix53): the owner on
-- HOLD_ID, P1's PC on his own original id
local function wantedIds(orig, p1Key, ownerKey, park, hold)
    local want = M.swapPlan(orig, p1Key, ownerKey)
    if want and park then want[p1Key] = PARK_ID end
    if want and hold then want[ownerKey], want[p1Key] = HOLD_ID, orig[p1Key] end
    return want
end
M._wantedIds = wantedIds

-- ownerPc = the shared screen's owner (swap to it), nil = normal ids. -> ok
local function setIds(ownerPc)
    local lp = U.localPlayers()
    if #lp < 2 then return false end
    local GS = U.cdo("GameplayStatics")
    local p1 = lp[1].pc
    if not U.ok(p1) then return false end
    local p1Key = U.key(p1)
    local ok = pcall(function()
        if ownerPc then
            -- no record yet: the live ids, cleaned of a park / swap left by a previous mod instance (hot reload)
            local orig = swap.orig or M.normalIds(liveIds(GS, lp), p1Key)
            local park = parkWanted()
            local want = wantedIds(orig, p1Key, U.key(ownerPc), park, swap.hold == true)
            if not want then error("no swap plan for the owner") end
            applyIds(GS, lp, want)
            swap.orig = orig
            swap.parked, swap.parkFor = park, park and orig[U.key(ownerPc)] or nil
        else
            -- no record (hot reload while swapped): P1 back on 0, the holder of 0 takes P1's id (M.normalIds)
            local want = swap.orig or M.normalIds(liveIds(GS, lp), p1Key)
            applyIds(GS, lp, want)
            swap.orig = nil
            swap.parked, swap.parkFor = false, nil
            swap.hold, swap.holdWhy = false, nil                -- couch-fix53: the unswap ends the map input hold
        end
    end)
    return ok
end

-- While parked: the original id whose pad reaches no LocalPlayer (the screen owner's), else nil.
function M.parkedFor()
    if swap.on and swap.parked and swap.orig then return swap.parkFor end
    return nil
end
-- While parked: P1's PC for the parked id (the PC that holds that pad whenever it is not parked), else nil.
function M.padHolder(id)
    if id == nil or M.parkedFor() ~= id then return nil end
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    return U.ok(p1) and p1 or nil
end
-- While parked: fn(pc) with P1's PC on pad id `id` for the duration of the call (SetUserFocus maps a PC to its
-- ControllerId's Slate user; no input is processed during a Lua call on the game thread, so the guest's pad never
-- reaches P1 in between). Rate-limited (UNPARK_MIN_MS). -> true when fn ran without error
function M.withPadId(id, fn, force)
    local p1 = M.padHolder(id)
    if not p1 then return false end
    local now = St.nowMs()
    if not force and now - (swap.unparkAt or -1e12) < UNPARK_MIN_MS then return false end
    swap.unparkAt = now
    local GS = U.cdo("GameplayStatics")
    -- couch-fix53: back on the id it had (PARK_ID, or his own id 0 during the map input hold)
    local prev = PARK_ID
    pcall(function() local c = GS:GetPlayerControllerID(p1); if type(c) == "number" then prev = c end end)
    local moved = pcall(function() GS:SetPlayerControllerID(p1, id) end)
    local ok = moved and pcall(fn, p1)
    local back = pcall(function() GS:SetPlayerControllerID(p1, prev) end)
    swap.focusTrips = (swap.focusTrips or 0) + 1
    if not back then
        -- P1's PC stays on the guest's id: the plain swap (the 0.15 first version); parkSync parks again later
        swap.parked, swap.parkFor = false, nil
        U.warn(TAG, "park: P1's PC could not go back to id %d after a focus call (plain swap now)", prev)
    end
    return ok == true
end
-- While parked: w holds the parked pad's focus = some Slate user focuses it, and no local player's user does
-- (HasUserFocus(pc) cannot name a user without a PC). One UFunction when unfocused.
function M.parkedFocus(w)
    if not U.ok(w) then return false end
    local any = false
    pcall(function() any = w:HasAnyUserFocus() == true end)
    if not any then return false end
    for _, e in ipairs(U.localPlayersRO()) do
        local mine = false
        if U.ok(e.pc) then pcall(function() mine = w:HasUserFocus(e.pc) == true end) end
        if mine then return false end
    end
    return true
end
function M.parkState() return { parked = swap.parked == true, parkFor = swap.parkFor, trips = swap.focusTrips or 0 } end

-- While swapped: a local PC's ORIGINAL id (the pad that is physically his); nil when not swapped / unknown.
function M.swapped() return swap.on == true end
function M.originalIdOf(pc)
    if not (swap.on and swap.orig and U.ok(pc)) then return nil end
    return swap.orig[U.key(pc)]
end
-- While swapped: the local PC whose original id is id (the guest's own PC), else nil.
function M.pcOfOriginalId(id)
    if not (swap.on and swap.orig) then return nil end
    for _, e in ipairs(U.localPlayersRO()) do
        if U.ok(e.pc) and swap.orig[U.key(e.pc)] == id then return e.pc end
    end
    return nil
end

-- The activated screens: the first one owned by a guest PlayerController, and whether P1 owns an activated screen of
-- his own (dialogs are created for P1, e.g. WBP_LoadoutConfirmation_C over the guest-owned loadout screen, live
-- 2026-10-14: then the ids must be NORMAL, or P1's pad cannot answer his own dialog). Generic layer containers
-- (WBP_*_Container_C) do not count.
-- ONE scan of the activatable widgets, shared by couch / couchpanel / couchprerun / menubridge / couchroot. Each
-- FindAllOf entry is filtered by its class name first (no UFunction), then by U.alive (garbage-marked widgets of closed
-- menus are still listed, and a UFunction call on one crashed the game, live 2026-10-14).
-- 0.15 LAG (blocker 5, Jules felt video lag): every caller re-scanned on its own clock - 11-14 FindAllOf per second in
-- the paddock (each one walks the engine's whole object array) and ~3000 GetClass per second (couchsim lag). Now:
--   * a FULL scan only when the screens may have changed: a CosmeticStateMachine state change (native hooks; every
--     paddock / post-race screen is shown by a CSM state action), a phase / world / players change, P1's press on a
--     shared screen (menubridge), M.markDirty - re-marked 200 and 700 ms later (screens appear after the state
--     actions) - and at most every SAFETY_MS otherwise;
--   * between full scans, every VERIFY_MS the cached activated entries are re-checked (IsActivated) without FindAllOf,
--     so a closed screen still drops out within 200 ms;
--   * class names are cached by object key (cleared on world change and quiet), so GetClass runs once per widget.
-- VERIFY(V-CC-LAG): "[couch] screen scans: N full / M verify in 10 s" debug line, no "pad ids" lag after a CSM change.
local SAFETY_MS, VERIFY_MS = 1500, 200
local scanCache = { atMs = -1e12, verifyAt = -1e12, list = {}, raw = {}, dirty = true, full = 0, verify = 0, seen = {} }
local clsCache = {}
local clsCacheN = 0

-- The +200 / +700 ms re-marks are timestamps checked by the next activeScreens call (couch-racefast: they were two
-- ExecuteInGameThreadWithDelay timers per CSM state change, and a race changes CSM states all the time).
-- CosmeticStateMachine state changes seen by the hooks of M.init (garagenative: did a native back already act?)
local csmSeq = 0
function M.csmSeq() return csmSeq end

function M.markDirty(why)
    local now = St.nowMs()
    scanCache.dirty = true
    scanCache.remark1, scanCache.remark2 = now + 200, now + 700
end

-- a re-mark time passed since the last full scan
local function remarkDue(now)
    local c = scanCache
    if c.remark1 and now >= c.remark1 then
        c.remark1 = nil
        if c.atMs < now then c.dirty = true end
    end
    if c.remark2 and now >= c.remark2 then
        c.remark2 = nil
        if c.atMs < now then c.dirty = true end
    end
end

-- RACE FAST PATH (couch-racefast 2026-10-15; live profile of couch-integ 4d6c050: couch.tick 69 RACING spikes > 2 ms,
-- max 38 ms = the SAFETY_MS FindAllOf("CommonActivatableWidget") walk of a race world every 1.5 s, from skipTick).
-- No couch moment lives in RACING (every shared screen is paddock / post-race; a race pause is pause.lua's and
-- menubridge's own scan): activeScreens() returns nothing there unless forced. PRERACE / LOADING: full scans only
-- when marked dirty (a CSM state change, a phase / players change), never on the SAFETY_MS clock.
local NO_SCREENS_PHASES = { RACING = true }
-- live 2026-10-16 (round 3 footage, SkipRaceIntro = false): the /CHALLENGES screen activates at the END of the race
-- intro with no CSM state change -> no dirty mark -> PRERACE never rescanned, couchbets never opened, the guest-owned
-- screen got no pad (soft lock: both pads dead, the intro cameras looping). PRERACE keeps the SAFETY_MS clock (a
-- grid of AI cars waiting, no race tick to protect); only LOADING stays dirty-only.
local DIRTY_ONLY_PHASES = { LOADING = true }
M.NO_SCREENS_PHASES = NO_SCREENS_PHASES

-- couch-fix43 (live round 1 2026-10-18 12:16, A6): the cache is keyed by ADDRESS, and the GC hands a freed widget's
-- address to the next widget of the same size inside one world: Hibi's shop layout (WBP_Paddock_Shop_Layout_Presentation_C)
-- was listed as "WBP_PostRace_Results_Arcade_C" (the freed post-race screen at that address), so P1's shop VM was never
-- found ("no view model 2000 ms after the shop opened" -> P2 got the list shop), and on the next visit the outer shop
-- screen vanished from the list the same way. A cached name is re-checked against the object's CLASS (one GetClass,
-- no name read) whenever it would be handed out as an ACTIVATED screen or would hide one (a non-WBP / container name),
-- and every entry whose address was not seen in a full scan is dropped (freed). verify = true: check this entry.
local function className(w, k, verify)
    local e = clsCache[k]
    if e and not verify then return e.cn, true end
    local ck = U.key(U.classOf(w))            -- U.ok inside both: a null / dead wrapper or class gives 0
    if e and e.ck == ck and ck ~= 0 then return e.cn, true end
    local cn = U.className(w)                 -- U.ok inside: GetClass on a null / dead wrapper is a native AV
    if e and e.cn ~= cn and cn ~= "" then
        U.logEvery("couch.clsreuse", 5000, TAG, "screen scan: the widget at a reused address is %s now (the cache said %s)",
            cn, tostring(e.cn))
    end
    if not e then
        if clsCacheN > 4000 then clsCache, clsCacheN = {}, 0 end
        clsCacheN = clsCacheN + 1
    end
    clsCache[k] = { cn = cn, ck = ck }
    return cn, false
end
M._className = className

local function fullScan(now)
    scanCache.atMs, scanCache.verifyAt, scanCache.dirty = now, now, false
    scanCache.full = scanCache.full + 1
    local list, raw = {}, {}
    local seenNow = {}
    local lp = U.localPlayers()
    local p1Key = (lp[1] and U.key(lp[1].pc)) or 0
    local cp = package.loaded["couchpanel"]
    local ownW = (type(cp) == "table" and type(cp.isOwn) == "function") and cp.isOwn or nil
    -- couch-fix47 (AUTO-122): the activatables inside a guest's pre-run copy (its class list, its party prompt)
    local pr = package.loaded["couchprerun"]
    local copyW = (type(pr) == "table" and type(pr.isCopyWidget) == "function") and pr.isCopyWidget or nil
    local alive = {}
    local walked = pcall(function()
        for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
            -- U.ok FIRST: GetClass reads the object's class pointer (+0x10) and a pcall does not catch an access
            -- violation on a dead entry (the null+0x10 crash in UE4SS.dll+0x2ace67, live 2026-10-14)
            if U.ok(w) then
                local k = U.key(w)
                alive[k] = true
                local cn, cached = className(w, k)
                -- couch-fix43: a cached name that would HIDE the widget (not a WBP_ screen / a container) is re-checked
                if cached and (not cn:find("^WBP_") or cn:find("_Container_C$")) then cn, cached = className(w, k, true) end
                -- couchpanel's guest reward views (standalone native layouts owned by a guest PC) are never shared screens
                if cn ~= "" and ownW and ownW(k) then cn = "" end
                if cn ~= "" and copyW and copyW(k) then cn = "" end
                if cn:find("^WBP_") then
                    local re = { w = w, k = k, cls = cn }
                    raw[#raw + 1] = re
                    if not cn:find("_Container_C$") and U.alive(w) then
                        local act = false
                        pcall(function() act = w:IsActivated() == true end)
                        -- couch-fix43: an ACTIVATED screen's cached name is re-checked against its class (a few per scan)
                        if act and cached then
                            local fresh = className(w, k, true)
                            if fresh ~= cn then
                                cn, re.cls = fresh, fresh
                                if not cn:find("^WBP_") or cn:find("_Container_C$") then act = false end
                            end
                        end
                        if act then
                            local own = nil
                            pcall(function() own = w:GetOwningPlayer() end)
                            local ok = U.ok(own) and U.key(own) or 0
                            -- no GetDesiredFocusTarget here: it is a BP event, and calling it every scan froze the loadout
                            -- screen's D-pad navigation (live 2026-10-14). Wrappers (*_Holder_*) never hold the focus.
                            scanCache.seen[k] = scanCache.seen[k] or now
                            seenNow[k] = true
                            list[#list + 1] = { w = w, k = k, cls = cn, owner = ok, p1 = (ok ~= 0 and ok == p1Key),
                                                target = not cn:find("Holder", 1, true), seen = scanCache.seen[k] }
                        end
                    end
                end
            end
        end
    end)
    scanCache.list, scanCache.raw = list, raw
    for k in pairs(scanCache.seen) do if not seenNow[k] then scanCache.seen[k] = nil end end
    -- couch-fix43: an address FindAllOf no longer lists was freed: its cached name goes (the next owner is read fresh)
    if walked then
        for k in pairs(clsCache) do
            if not alive[k] then clsCache[k] = nil; clsCacheN = clsCacheN - 1 end
        end
    end
end

local function verify(now)
    scanCache.verifyAt = now
    scanCache.verify = scanCache.verify + 1
    local keep, gone = {}, false
    for _, e in ipairs(scanCache.list) do
        local act = false
        if U.alive(e.w) then pcall(function() act = e.w:IsActivated() == true end) end
        if act then keep[#keep + 1] = e else gone = true end
    end
    if gone then
        scanCache.list = keep
        scanCache.dirty = true          -- a screen closed: the next one may be up already (full scan next call)
    end
end

function M.activeScreens(force)
    local now = St.nowMs()
    if now < quietUntil then return {} end
    if NO_SCREENS_PHASES[St.phase] and not force then
        if #scanCache.list > 0 or #scanCache.raw > 0 then scanCache.list, scanCache.raw, scanCache.dirty = {}, {}, true end
        return {}
    end
    remarkDue(now)
    local safety = (not DIRTY_ONLY_PHASES[St.phase]) and now - scanCache.atMs >= SAFETY_MS
    if force or scanCache.dirty or safety then
        fullScan(now)
    elseif now - scanCache.verifyAt >= VERIFY_MS then
        verify(now)
    else
        -- a cached entry may have been collected since (GC between ticks): never hand out a dead widget
        local dead = false
        for _, e in ipairs(scanCache.list) do if not U.alive(e.w) then dead = true; break end end
        if dead then
            local keep = {}
            for _, e in ipairs(scanCache.list) do if U.alive(e.w) then keep[#keep + 1] = e end end
            scanCache.list, scanCache.dirty = keep, true
        end
    end
    return scanCache.list
end

-- every WBP_ activatable of the last full scan (activated or not, containers included): couchroot's candidates
function M.allActivatables()
    M.activeScreens()
    local out = {}
    for _, e in ipairs(scanCache.raw) do if U.ok(e.w) then out[#out + 1] = e end end
    return out
end

function M.scanStats() return { full = scanCache.full, verify = scanCache.verify, cached = clsCacheN } end

-- couch-fix54 (AUTO-133, live round 3 15:43:51, eliminator with both humans out): the post-race holder's pages
-- (WBP_PostRace_Cam_Holder_Presentation.WS_ScreenSwitcher: Results_Race / Shakedown / ActFinish / RewardsHub / ...)
-- can be ACTIVATED while another page is the switcher's active one: WBP_PostRace_Results_ActFinish_Presentation_C is
-- activated in EVERY campaign post-race (listed up to the run map) but shown only at the end of an act. When it was
-- activated a scan AFTER the results (the strike popup delayed the results), it won screens() as "the newest guest
-- screen with a target": the swap refocused its hidden CONTINUE and the bridge clicked it ~100 times, the visible
-- RESULTS never moved on (softlock). A page that is not its switcher's active widget is not on screen: it never wins.
-- -> true when w (or a wrapper up to 4 parents above it) sits in a WidgetSwitcher whose active widget is another one.
-- Cached 400 ms per widget (the switcher flips at the next state; a stale "inactive" lasts one scan at most).
local SWITCHER_CLS = "/Script/UMG.WidgetSwitcher"
local pageCache, pageCacheN = {}, 0
function M.inactivePage(w, now, cls)
    if not U.alive(w) then return false end
    now = now or St.nowMs()
    local k = U.key(w)
    local c = pageCache[k]
    if c and now - c.at < 400 then return c.v end
    local v = false
    pcall(function()
        local child, x = w, w:GetParent()
        for _ = 1, 4 do
            -- U.alive: a parent being torn down (garbage) takes no UFunction call (the native AV class)
            if not U.alive(x) then break end
            if U.isA(x, SWITCHER_CLS) then
                local a = x:GetActiveWidget()
                v = U.alive(a) and U.key(a) ~= U.key(child)
                break
            end
            child, x = x, x:GetParent()
        end
    end)
    if not c then
        pageCacheN = pageCacheN + 1
        if pageCacheN > 128 then pageCache, pageCacheN = {}, 1 end
    end
    pageCache[k] = { at = now, v = v }
    if v and not (c and c.v) then
        local cn = cls or U.className(w)
        U.logEvery("couch.inactivePage" .. tostring(cn), 10000, TAG,
            "%s is activated but not its switcher's active page (hidden): never the shared screen (AUTO-133)", tostring(cn))
    end
    return v
end

-- The first guest-owned activated screen (one with a real focus target wins: nested post-race screens), whether P1
-- owns an activated screen of his own (dialogs on top need the NORMAL ids), and the local PC that owns that screen
-- (3-4 players: any local PC but P1's; a screen owned by a non-local controller is not shared).
local function screens()
    local lp = U.localPlayers()
    if #lp < 2 then return nil, false, nil end
    local locals = {}
    for i = 2, #lp do if U.ok(lp[i].pc) then locals[U.key(lp[i].pc)] = lp[i].pc end end
    local guest, p1Own, guestHasTarget, ownerPc, gSeen = nil, false, false, nil, nil
    local orphan = nil
    swap.p1W, swap.p1HasTarget = nil, false
    local now = St.nowMs()
    for _, e in ipairs(M.activeScreens()) do
        -- couch-fix54 (AUTO-133): a guest-owned page hidden in its switcher is not a screen anyone sees
        if e.p1 or e.cls:find("^WBP_Hud") or not M.inactivePage(e.w, now, e.cls) then
            -- couch-scaccept: an activated screen with no readable local owner (GetOwningPlayer nil / not a local PC) is
            -- remembered: while swapped it is the shared screen of the current owner (the game makes every native screen
            -- for the LAST local PC; a sub-screen whose owner reads empty must not end the swap under P1's pad)
            if not e.p1 and not (e.owner ~= 0 and locals[e.owner]) and not e.cls:find("^WBP_Hud") then
                if not orphan or (e.seen or 0) >= (orphan.seen or 0) then orphan = e end
            end
            -- HUD feed widgets (WBP_Hud_GameFeed_Message_C) are activatable P1 widgets, never dialogs: counting them
            -- gave the ids back for 2-3 s on the post-race screens (live 2026-10-14) and P2's pad drove the run map
            if e.p1 and e.cls:find("^WBP_Hud") then -- not a P1 screen
            elseif e.p1 then
                if not p1Own or (e.target and not swap.p1HasTarget) then swap.p1W, swap.p1HasTarget = e.w, e.target and true or false end
                p1Own = true; swap.p1Cls = e.cls
            elseif e.owner ~= 0 and locals[e.owner] then
                -- input matrix (couchsim pausepost): a pause over the post-race results is the NEWER screen; the first one
                -- with a target won, so P1's cursor stayed on the results under the pause. Now: a screen with a target
                -- first, then the most recently seen (first full scan that listed it), then the later list entry.
                local tgt = e.target == true
                if not guest or (tgt and not guestHasTarget) or (tgt == guestHasTarget and (e.seen or 0) >= (gSeen or 0)) then
                    guest, guestHasTarget, ownerPc, gSeen = e.w, tgt, locals[e.owner], e.seen
                end
            end
        end
    end
    -- only a screen that came up WHILE swapped (a sub-screen pushed over the shared one): a long-lived ownerless widget
    -- seen before the swap never holds it
    if not guest and not p1Own and orphan and swap.on and swap.owner and (orphan.seen or 0) >= (swap.onAt or 1e18)
        and opt("CouchOrphanScreens", true) ~= false then
        for k, pc in pairs(locals) do
            if k == swap.owner then
                guest, ownerPc = orphan.w, pc
                if swap.orphanK ~= orphan.k then
                    swap.orphanK = orphan.k
                    U.log(TAG, "shared screen %s has no local owner (owner key %s): kept as the swapped owner's screen",
                        tostring(orphan.cls), tostring(orphan.owner))
                end
            end
        end
    end
    return guest, p1Own, ownerPc
end

local function guestScreen()
    local g = screens()
    return g
end
M.screens = screens

local function parkP1Focus()
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if not U.ok(p1) then return end
    if not U.ok(swap.sink) then
        pcall(function()
            local cls = U.class("/Game/Griffin/UI/Widgets/Buttons/WBP_Common_Btn.WBP_Common_Btn_C")
            local w = U.WBL():Create(p1, cls, p1)
            w:SetRenderOpacity(0)
            w:AddToViewport(-100)
            w:BP_SetIsFocusable(true)
            swap.sink = w
        end)
    end
    if U.ok(swap.sink) then pcall(function() swap.sink:SetUserFocus(p1) end) end
end

-- Input matrix (couchsim results / credits / strikes / pause / viewbuild, 2026-10-15): CommonUI's activation of a new
-- guest-owned screen focuses it for the owner's own pad (his PHYSICAL pad: the live "a new guest screen while swapped
-- needed its own refocus" for P1's pad), so the guest's D-pad moved the cursor of P1's shared screen and the bridge's
-- "focused button" fallback could click the row the GUEST picked. At the swap and at every new shared screen (no
-- guest split open: his own area then holds his pad's focus) that pad's Slate user gets the invisible sink instead;
-- parked (no PC on that id): through M.withPadId (forced: one-shot, outside its rate limit).
-- a guest area that keeps the owner's pad focused on its own buttons (the display-only VIEW BUILD area does not)
local function areaHoldsPad()
    local pr = package.loaded["couchprerun"]
    if type(pr) == "table" and type(pr.state) == "function" then
        local ok, st = pcall(pr.state)
        if ok and type(st) == "table" and st.open == true then return true end
    end
    local cp = package.loaded["couchpanel"]
    if type(cp) == "table" then
        local okO, on = pcall(function() return cp.isOpen() end)
        local okK, kind = pcall(function() return cp.kind and cp.kind() end)
        if okO and on == true and not (okK and kind == "build") then return true end
        local okL, up = pcall(function() return cp.launcherUp and cp.launcherUp() end)
        if okL and up == true then return true end
    end
    return false
end

local function sinkOwnerPad(why, force)
    if not (swap.on and swap.orig and swap.owner) then return end
    if not force and areaHoldsPad() then
        -- (couch-livefix iii) the guests' SHOP hint holds the pad: its next tick takes the focus back from the new screen
        local cp = package.loaded["couchpanel"]
        if type(cp) == "table" and type(cp.launcherRefocusSoon) == "function" then pcall(cp.launcherRefocusSoon) end
        return
    end
    local id = swap.orig[swap.owner]
    if id == nil then return end
    parkP1Focus()                                 -- unparked: P1's PC carries that pad (its sink focus is the pad's)
    if not swap.parked then return end
    -- FINDING #42: parked onto that pad's OWN guest sink (couchfence's home for it: readable, the fence leaves it there);
    -- swap.sink (P1's parked PC focuses it too: "the parked pad is on it" cannot be read) only when that one is missing
    local g = M.guestSink(id)
    if not U.ok(g) then g = swap.sink end
    if not U.ok(g) then return end
    local ok = M.withPadId(id, function(holder) g:SetUserFocus(holder) end, true)
    U.dbg(TAG, "pad %s (the screen owner's own) focus on its sink (%s): %s", tostring(id), tostring(why), ok and "ok" or "failed")
end

-- couch-rewards2 (couchfence.lua): a SECOND invisible sink for the guests' pads only (swap.sink also holds P1's parked
-- PC's focus, so "the parked pad is on it" could not be read). M.guestSinkHeld(): the parked pad focuses it (some user,
-- no local player's) - one cheap read per FAST tick. M.sinkGuestPad(id | pc): that pad onto it (parked: withPadId,
-- forced; else SetUserFocus for the PC carrying it).
-- FINDING #42 (live 22:07:17-44, 433 fence moves; couchsim rewardfence p3): ONE sink for every guest pad made the
-- parked pad's home unreadable whenever another guest's pad (a local player's user) sat on it too: parkedFocus then
-- reads "a local player's" and the fence moved the parked pad again every FAST tick. One sink PER PAD ID now (the
-- parked pad's own sink is focused by that pad only).
function M.guestSink(id)
    swap.gsinks = swap.gsinks or {}
    local k = tostring(id)
    local g = swap.gsinks[k]
    if U.alive(g) then return g end
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if not U.ok(p1) then return nil end
    pcall(function()
        local cls = U.class("/Game/Griffin/UI/Widgets/Buttons/WBP_Common_Btn.WBP_Common_Btn_C")
        local w = U.WBL():Create(p1, cls, p1)
        w:SetRenderOpacity(0)
        w:AddToViewport(-101)
        w:BP_SetIsFocusable(true)
        swap.gsinks[k] = w
    end)
    g = swap.gsinks[k]
    return U.alive(g) and g or nil
end
function M.guestSinkHeld(id)
    local g = swap.gsinks and swap.gsinks[tostring(id)]
    return U.alive(g) and M.parkedFocus(g)
end
function M.sinkGuestPad(id, pc, why)
    local g = M.guestSink(id)
    if not g then return false end
    local ok
    if U.ok(pc) then ok = pcall(function() g:SetUserFocus(pc) end)
    else ok = M.withPadId(id, function(holder) g:SetUserFocus(holder) end, true) end
    U.dbg(TAG, "pad %s onto its guest sink (%s): %s", tostring(id), tostring(why), ok and "ok" or "failed")
    return ok == true
end

local function targetOf(w)
    local t = nil
    pcall(function() t = w:GetDesiredFocusTarget() end)
    return U.ok(t) and t or nil
end

-- The screen whose focus target P1's pad gets: w itself when it has one, else the newest other activated screen of the
-- same owner that has one (nested moments: post-race holder > hub, paddock host > event map; input matrix nodemap:
-- the host has no target of its own and SetUserFocus on it took P1's cursor off the event map's nodes). One
-- GetDesiredFocusTarget per candidate, only at a refocus moment (never in the periodic scan).
-- FINDING #71 (live 2026-10-18 03:54:55, tester #4): the swap's screen WBP_PostRace_Cam_Rewards_Presentation_C holds the
-- CHOOSE A PART layout nested in it, and its desired focus target is that layout WIDGET (an activatable of its own):
-- Slate focus on a UserWidget is no cursor (D-pad / A dead); the layout's own target (TV_List_Items) was the cure. A
-- target that is itself an activatable screen of the scan hands on to ITS target (at most 3 levels; a refocus moment
-- only, like every GetDesiredFocusTarget here).
local function deeper(t)
    for _ = 1, 3 do
        local k, isScreen = U.key(t), false
        for _, e in ipairs(scanCache.raw) do if e.k == k then isScreen = true; break end end
        if not isScreen then return t end
        local t2 = targetOf(t)
        if not t2 or U.key(t2) == k then return t end
        t = t2
    end
    return t
end

local function focusScreen(w)
    local t = targetOf(w)
    if t then return w, deeper(t) end
    local own = nil
    pcall(function() own = w:GetOwningPlayer() end)
    if not U.ok(own) then return w, nil end
    local ok, wk = U.key(own), U.key(w)
    local list = M.activeScreens()
    for i = #list, 1, -1 do
        local e = list[i]
        if e.owner == ok and e.k ~= wk and e.target and U.alive(e.w) then
            t = targetOf(e.w)
            if t then return e.w, deeper(t) end
        end
    end
    return w, nil
end

-- onlyIfLost: skip while the owner's focus is inside the screen on another widget than its target (P1 moved his
-- cursor: input matrix vehicle / dpad, the +1.5 s refocus put it back on the default target). -> true = focus given
local function refocus(w, onlyIfLost)
    local done = false
    pcall(function()
        local own = w:GetOwningPlayer()
        local tw, tgt = focusScreen(w)
        if onlyIfLost and U.ok(own) and tw:HasUserFocusedDescendants(own) == true
            and not (U.ok(tgt) and tgt:HasUserFocus(own) == true) then
            return
        end
        -- couch-fix59 (AUTO-145a, live 18:29:36 NEW UNLOCK WBP_EndRunNewUnlocks_C): a screen with no focus target
        -- (no BP_GetDesiredFocusTarget override) but a UserWidget DesiredFocusWidget (there: its CONTINUE WBP_Hero_Btn)
        -- gets the focus on that widget: on the root, Slate has no cursor and A did nothing until a D-pad press
        if not U.ok(tgt) then
            local d = nil
            pcall(function() d = w:GetDesiredFocusWidget() end)
            if U.ok(d) and U.key(d) ~= U.key(w) then tgt = d end
        end
        if U.ok(tgt) then tgt:SetUserFocus(own) else w:SetUserFocus(own) end
        done = true
    end)
    return done
end

-- FINDING #71 (live 2026-10-18 03:54:44-55): a game dialog over a shared screen (P1's PART SLOTS FULL
-- WBP_ItemChangeModifier_C over CHOOSE A PART: the swap ends for it and comes back when it closes; a guest-owned modal:
-- "another shared screen" and back) takes the owner's Slate focus, and nothing in the game gives it back to the screen
-- under it for P1's pad. While swapped, the innermost activated screen holding the owner's focus is remembered per
-- swapped screen (HasUserFocusedDescendants, once per HOLD_MS); when that same shared screen is the swap's screen
-- again, the refocus goes to the remembered one (its own desired target) instead of the outer screen's guess.
local HOLD_MS = 1000
local function nestedIn(x, hk)
    local inside = false
    pcall(function()
        local o = U.outerOf(x)
        for _ = 1, 8 do
            if not U.ok(o) then break end
            if U.key(o) == hk then inside = true; break end
            o = U.outerOf(o)
        end
    end)
    return inside
end
local function trackHolder(ownerPc, now)
    if not swap.screenKey or now < (swap.holdAt or 0) then return end
    swap.holdAt = now + HOLD_MS
    local ok, hs = U.key(ownerPc), {}
    for _, e in ipairs(M.activeScreens()) do
        if e.owner == ok and e.target and U.alive(e.w) then
            local f = false
            pcall(function() f = e.w:HasUserFocusedDescendants(ownerPc) == true end)
            if f then hs[#hs + 1] = e end
        end
    end
    local best = nil
    for _, h in ipairs(hs) do
        local outer = false
        for _, x in ipairs(hs) do if x ~= h and nestedIn(x.w, h.k) then outer = true; break end end
        if not outer then best = h; break end
    end
    if not best then return end
    swap.held = swap.held or {}
    swap.held[swap.screenKey] = { k = best.k, cls = best.cls, owner = ok, gen = St.worldGen }
end
-- the screen to refocus for the shared screen w: the one remembered under w (still activated, same owner and world)
local function resumeScreen(w, why)
    local wk = U.key(w)
    local h = swap.held and swap.held[wk]
    if not h or h.k == wk or h.gen ~= St.worldGen or h.owner ~= swap.owner then return w end
    for _, e in ipairs(M.activeScreens()) do
        if e.k == h.k and U.alive(e.w) then
            if why then
                U.log(TAG, "owner's focus back on the screen it held before (%s): %s in %s", why, tostring(h.cls), U.className(w))
            end
            return e.w
        end
    end
    swap.held[wk] = nil
    return w
end

---------------------------------------------------------------------------------------------------- owner's IMC_UI
-- ROOT CAUSE of "the map screens ignore P1's pad" (live 2026-10-14, NEXT PLANET / paddock event map): those screens
-- take their input through CommonUI action bindings on Enhanced Input actions (WBP_RunMapOverview_Presentation:
-- RegisterActionBinding(IA_UI_Accept -> OnAccept, IA_UI_Nav_Left / IA_UI_Nav_Right -> NavLeft / NavRight); the node
-- map's CommonButtons click on the router's IA_UI_Accept too). CommonUI matches a key against the mapping contexts of
-- the screen OWNER's EnhancedInputLocalPlayerSubsystem, and the game's InputModeManager raises IMC_UI (500) for the
-- FIRST local player only (pause.lua layer D, 0x140ded924 GetFirstLocalPlayerFromController). After the swap P1's pad
-- reaches the owner (a guest) - IsInputKeyDown(A) true on it - but the guest has no IMC_UI: no IA_UI_* ever
-- triggers, so A / D-pad on these screens do nothing, while plain Slate buttons (shop rows) still work. Fix: while
-- swapped, the screen owner's subsystem gets IMC_UI at the active priority; it gets back what it had at the unswap.
local IMC_UI_PATH = "/Game/Griffin/Config/Input/UI/IMC_UI.IMC_UI"
local EI_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local UIM_SETTINGS = "/Script/Griffin.Default__UIManagerSettings"
local imcRec = nil                          -- { key, pc, had, prio } of the boosted owner
local IMC_OUT = (St.outParams or function(t) return t end)({})            -- HasMappingContext's out table, reused (state.lua: the out-param leak)

local function findL(p)
    if type(U.findLoaded) == "function" then return U.findLoaded(p, 1000) end
    local ok, o = pcall(StaticFindObject, p)
    return (ok and U.ok(o)) and o or nil
end

local function imcActive()
    local act = 500
    local s = findL(UIM_SETTINGS)
    if s then pcall(function() local v = tonumber(s.UI_IMC_ActivePriority); if v then act = math.floor(v) end end) end
    return act
end

local function eiOf(pc)
    local cls = findL(EI_CLASS)
    if not (cls and U.ok(pc)) then return nil end
    local sub = nil
    pcall(function() sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, cls) end)
    return U.ok(sub) and sub or nil
end

local function imcOpts() return { bIgnoreAllPressedKeysUntilRelease = true } end

-- boost the owner's IMC_UI (re-asserted every swap tick: pause.lua normalises guests on its own edges)
function M.ownerUiInput(ownerPc, why)
    if opt("CouchOwnerUiImc", true) == false or not U.ok(ownerPc) then return false end
    local imc = findL(IMC_UI_PATH)
    local sub = eiOf(ownerPc)
    if not (imc and sub) then
        U.logEvery("couch.imc.missing", 10000, TAG, "owner IMC_UI not boosted: %s", imc and "no input subsystem" or "IMC_UI not loaded")
        return false
    end
    local k = U.key(ownerPc)
    if imcRec and imcRec.key ~= k then M.restoreOwnerUiInput("owner changed") end
    local act = imcActive()
    local has, p = nil, nil
    local out = IMC_OUT
    out.OutFoundPriority = nil
    pcall(function()
        local r = sub:HasMappingContext(imc, out)
        has, p = r == true, tonumber(out.OutFoundPriority)
    end)
    if St.dropOutRefs then St.dropOutRefs(out) end
    if not imcRec then imcRec = { key = k, pc = ownerPc, had = has, prio = p } end
    if has == true and p and math.floor(p) == act then return true end
    local ok = pcall(function() sub:AddMappingContext(imc, act, imcOpts()) end)
    U.log(TAG, "screen owner's IMC_UI -> %d (%s; had %s): P1's A / D-pad reach its CommonUI actions", act,
        tostring(why), has == true and tostring(p) or "none")
    return ok
end

function M.restoreOwnerUiInput(why)
    local r = imcRec
    imcRec = nil
    if not r then return end
    local imc = findL(IMC_UI_PATH)
    local sub = U.ok(r.pc) and eiOf(r.pc) or nil
    if not (imc and sub) then return end
    if r.had == true and r.prio then
        pcall(function() sub:AddMappingContext(imc, math.floor(r.prio), imcOpts()) end)
    else
        pcall(function() sub:RemoveMappingContext(imc, imcOpts()) end)
    end
    U.log(TAG, "screen owner's IMC_UI restored (%s)", tostring(why))
end
function M.ownerImcState() return imcRec end

-- Live 2026-10-14 23:16 (pre-run LOADOUT, the style split open BEFORE the swap: swap + park in one setSwap): the
-- refocus right after the swap did run with the final ids, yet P1's strip had no cursor (the screen's own activation /
-- the guest split's setup takes the focus in the same frame); the same refocus by hand 5 min later worked at once.
-- So the owner's focus is given again 0.5 s and 1.5 s later, only while the same screen is still the swapped one.
local function laterRefocus(tag)
    local sched = package.loaded["sched"]
    if not (sched and type(sched.after) == "function") then return end
    local key, gen = swap.screenKey, St.worldGen
    -- +3 s / +5 s (live 2026-10-15 00:27: LOADOUT still without a cursor after +1.5 s; the screen's own transition-in
    -- ends later and hands the focus to the FIRST local player, i.e. P1's parked PC)
    for _, ms in ipairs({ 500, 1500, 3000, 5000 }) do
        sched.after("couch.refocus" .. ms, ms, function()
            if not swap.on or swap.screenKey ~= key or St.worldGen ~= gen or M.isQuiet() then return end
            local w = guestScreen()
            if w then w = resumeScreen(w) end
            -- input matrix (couchsim vehicle / dpad): P1 had already moved his cursor inside the screen when the +1.5 s
            -- refocus put it back on the default target. Skipped while the owner's focus is inside the screen on
            -- another widget (= P1 moved it); re-given when it is outside (the live no-cursor case) or on the target.
            if w and refocus(w, true) then
                if ms == 1500 then U.dbg(TAG, "owner focus re-given (%s, +%d ms) on %s", tag, ms, U.className(w)) end
            end
        end)
    end
end

-- on = true: swap to ownerPc (the shared screen's owner; a different owner while swapped re-targets the swap).
function M.setSwap(on, why, ownerPc)
    if on and not U.ok(ownerPc) then
        local _, _, o = screens()
        ownerPc = o
        if not U.ok(ownerPc) then return end
    end
    local ownerKey = on and U.key(ownerPc) or nil
    if on == swap.on and ownerKey == swap.owner then return end
    if setIds(on and ownerPc or nil) then
        local was = swap.on
        swap.on, swap.owner = on, ownerKey
        if on and not was then swap.onAt = St.nowMs() elseif not on then swap.onAt, swap.orphanK, swap.keptWhy = nil, nil, nil end
        local pn = nil
        if on then pcall(function() pn = U.mod("join").displayNumForPC(ownerPc) end) end
        U.log(TAG, "pad ids %s (%s)", on and string.format("SWAPPED%s: P1's pad drives the shared screen of P%s%s",
            was and " (new owner)" or "", tostring(pn or "?"), swap.parked and string.format(", P1's PC parked on id "
            .. "%d: the guest split is open", PARK_ID) or "") or "normal", tostring(why))
        if on then
            U.try(TAG, M.ownerUiInput, ownerPc, "swap")
            parkP1Focus()
            local w = guestScreen()
            if w then
                swap.screenKey = swap.screenKey or U.key(w)
                refocus(resumeScreen(w, "swap"))
                laterRefocus("swap")
            end
            U.try(TAG, sinkOwnerPad, "swap")
        else
            U.try(TAG, M.restoreOwnerUiInput, why)
        end
    end
end

---------------------------------------------------------------------------------------------------- swap holds
-- couch-scaccept (live 2026-10-17, P1's OWN garage, Steam Controller): the swap ran for the guest-owned root
-- WBP_Paddock_VehicleCust_C; entering CHOOSE MODEL logged "pad ids normal (no shared screen)" and P1's pad could not
-- move in the option page (still the LAST local PC's screen). The page did not show up as an activated guest-owned
-- screen in the shared scan at that moment, so the swap was dropped under P1's pad. While the game's garage machine
-- is in CSM_VehicleCustomisation_Active (P1's own garage: a guest's garage turn holds the ids itself, garageHeld) the
-- swap is kept whatever the scan says; it ends when the machine leaves Active. cfg.CouchGarageKeepSwap = false: off.
local CSM_GARAGE_ACTIVE = "/Game/Griffin/Config/StateMachines/Customisation/CSM_VehicleCustomisation_Active.CSM_VehicleCustomisation_Active"
local garageMemo = { at = -1e12, v = false }
function M.garageOpen()
    local now = St.nowMs()
    if now - garageMemo.at < 250 then return garageMemo.v end
    garageMemo.at = now
    local v = false
    pcall(function()
        local act = U.obj(CSM_GARAGE_ACTIVE)
        local mgr = U.giSubsystem("CosmeticStateMachineManager")
        if U.ok(act) and U.ok(mgr) then v = mgr:IsStateActiveByRef(act) == true end
    end)
    garageMemo.v = v
    return v
end
function M._garageForget() garageMemo.at = -1e12 end          -- tests

-- why the swap stays on although no guest-owned screen was found (nil = let it end)
local function keepSwap()
    if not swap.on then return nil end
    if opt("CouchGarageKeepSwap", true) ~= false and M.garageOpen() then return "P1's garage open (CSM_VehicleCustomisation_Active)" end
    return nil
end

-- one line naming every activated screen and its owner when a swap ends for "no shared screen" (the live evidence the
-- next session needs when a sub-screen is not recognised)
local function swapEndDiag()
    local lp = U.localPlayers()
    local pn = {}
    for i, e in ipairs(lp) do if U.ok(e.pc) then pn[U.key(e.pc)] = i end end
    local t = {}
    for _, e in ipairs(scanCache.list) do t[#t + 1] = string.format("%s(P%s)", e.cls, tostring(pn[e.owner] or ("?" .. tostring(e.owner)))) end
    local raw = 0
    for _, e in ipairs(scanCache.raw) do if e.cls:find("VehicleCust", 1, true) then raw = raw + 1 end end
    U.log(TAG, "swap end diag: activated [%s]; VehicleCust widgets listed %d; garage machine %s", table.concat(t, ", "),
        raw, M.garageOpen() and "Active" or "not Active")
end

local SHARED_PHASES = { OTHER = true, POSTRACE = true }
-- the screens of a NEW run only (the logbook WBP_PreRun_Stickerbook_C is not counted: it is not proven pre-run only)
local PRE_RUN = { WBP_PreRun_VehicleSelect_C = true, WBP_PreRun_LoadoutSelect_C = true }
M.PRE_RUN = PRE_RUN

-- P1 BLOCKER (live 2026-10-15 final-live, a NEW run with P2 joined): on the swapped + parked pre-run LOADOUT P1's pad
-- had NO cursor - the owner (the PC on pad id 0) focused nothing inside the screen 33 s after the swap, long after the
-- one-shot refocuses (+0.5 .. +5 s, laterRefocus); the same SetUserFocus on its target by hand worked, and a few
-- seconds later the focus was gone again (P2 READY in between). Whatever takes it (the guest split's own focus round
-- trips, the screen's transitions), the one-shots cannot cover a screen P1 stays on for minutes. So while a pre-run
-- screen is the swapped one: every CURSOR_WATCH_MS, when no activated screen holds a focus of the owner (= P1's pad
-- focuses nothing he can see: a favour picker / difficulty screen of his keeps it), the screen's focus is given back.
-- HasUserFocusedDescendants per screen only; GetDesiredFocusTarget (a BP event: the periodic-call D-pad freeze trap)
-- only at an actual refocus, at most once per CURSOR_WATCH_MS. cfg.CouchCursorWatch = false: the one-shots only.
local CURSOR_WATCH_MS = 1000
local CURSOR_WATCH = PRE_RUN
-- couch-fix46 (live round 1 AUTO-117, shot 141011-31-crop-p1grid, 12:10:11: P1's LOADOUT grid without a visible
-- cursor between the watch's re-gives at 12:09:43 and 12:10:36): the owner's focus on the swapped screen's ROOT
-- counted as "holds a focus" (HasUserFocus(screen)); Slate's HasUserFocusedDescendants does not count the widget
-- itself, and a focused UserWidget root draws no cursor anywhere. On the swapped pre-run screen only a focused
-- descendant counts now (its root alone = no cursor: re-given when the screen has a focus target to give it to).
local function ownerHoldsFocus(ownerPc, swappedKey)
    for _, e in ipairs(M.activeScreens()) do
        if U.alive(e.w) then
            local f = false
            pcall(function()
                f = e.w:HasUserFocusedDescendants(ownerPc) == true
                    or (e.k ~= swappedKey and e.w:HasUserFocus(ownerPc) == true)
            end)
            if f then return true end
        end
    end
    return false
end
local function cursorWatch(w, ownerPc, now)
    if opt("CouchCursorWatch", true) == false or not (swap.on and U.ok(ownerPc)) then return end
    if now < (swap.cursorAt or 0) then return end
    swap.cursorAt = now + CURSOR_WATCH_MS
    local wk, cls = U.key(w), nil
    for _, e in ipairs(M.activeScreens()) do if e.k == wk then cls = e.cls end end
    if not (cls and CURSOR_WATCH[cls]) then return end
    if ownerHoldsFocus(ownerPc, wk) then return end
    local rootOnly = false
    pcall(function() rootOnly = w:HasUserFocus(ownerPc) == true end)
    if rootOnly then
        local _, tgt = focusScreen(w)
        if not U.ok(tgt) then return end                    -- nothing better than the root to give the focus to
    end
    local ok = refocus(w)
    swap.cursorFixes = (swap.cursorFixes or 0) + 1
    U.logEvery("couch.cursor", 5000, TAG, "P1's pad had no cursor on %s (swapped): the owner's focus re-given: %s (%d so far)",
        cls, ok and "ok" or "failed", swap.cursorFixes)
end
M.cursorFixes = function() return swap.cursorFixes or 0 end

-- Once per pre-run sequence (cleared on LOADING / FRONTEND): every guest back to a starter build. Called by the tick
-- and by couchprerun when its panel opens (before any guest pick, whichever sees the screen first).
function M.markPreRun(why)
    if swap.preRunSeen then return false end
    swap.preRunSeen = true
    U.try(TAG, function() U.mod("couchrun").resetRun(why) end)
    return true
end
-- World changes: FindAllOf returns the dying world's widgets too, and a UFunction call on one crashed the game twice
-- live (2026-10-14, both dumps inside UE4SS's Lua VM: at "LEAVING -> TRANSIT" and at the next race's ignition).
-- "leaving" is emitted BEFORE the old world goes; every cached widget is dropped and no scan runs for 2 s.
local function quiet(why)
    quietUntil = St.nowMs() + 2000
    swap.sink, swap.gsinks, swap.screenKey, swap.held = nil, nil, nil, nil
    scanCache.atMs, scanCache.list, scanCache.raw, scanCache.dirty, scanCache.seen = -1e12, {}, {}, true, {}
    clsCache, clsCacheN = {}, 0                -- object keys (addresses) are reused by the next world
end
M.quiet = quiet
function M.isQuiet() return St.nowMs() < quietUntil end

-- A local player plugged / unplugged while swapped (the owner = the LAST local PC changed): the ids are given back at
-- once - no widget is touched, so also during the quiet window (couchsim soak: P3 unplugged while swapped left P1 on
-- id 2 of 2 players, his pad driving nobody until the next world's quiet window ended).
local function playersChanged(why)
    if not (swap.on and swap.orig) then return end
    local lp = U.localPlayers()
    local now, n = {}, 0
    for _, e in ipairs(lp) do if U.ok(e.pc) then now[U.key(e.pc)] = true; n = n + 1 end end
    local same = true
    for k in pairs(swap.orig) do if not now[k] then same = false end end
    for k in pairs(now) do if swap.orig[k] == nil then same = false end end
    if same then return end
    if n >= 2 then
        M.setSwap(false, why)
    else
        -- one local player left: nobody to swap with; P1 takes id 0 back
        pcall(function() U.cdo("GameplayStatics"):SetPlayerControllerID(lp[1].pc, 0) end)
        U.log(TAG, "pad ids normal (%s: P1 alone)", tostring(why))
        U.try(TAG, M.saveOwnerSync, "P1 alone")
    end
    U.try(TAG, M.restoreOwnerUiInput, why)
    swap.on, swap.orig, swap.parked, swap.parkFor = false, nil, false, nil
    swap.hold, swap.holdWhy = false, nil
end

-- The park follows the guest split (called by couchprerun / couchpanel when a split opens or closes, and every tick):
-- parked while swapped and a split is open, the plain swap ids otherwise. Ids only, except that an unpark outside the
-- quiet window gives P1's PC its sink focus again (it carries the guest's pad once more). -> true when the ids changed
function M.parkSync(why)
    if not (swap.on and swap.orig and swap.owner) then
        swap.parked, swap.parkFor = false, nil
        return false
    end
    local want = parkWanted()
    if want == (swap.parked == true) then return false end
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if #lp < 2 or not U.ok(p1) then return false end
    local p1Key = U.key(p1)
    local GS = U.cdo("GameplayStatics")
    local ids = wantedIds(swap.orig, p1Key, swap.owner, want, swap.hold == true)
    if not ids then return false end
    local ok = pcall(function() applyIds(GS, lp, ids) end)
    if not ok then
        U.warn(TAG, "pad ids: %s failed (%s)", want and "park" or "unpark", tostring(why))
        return false
    end
    swap.parked, swap.parkFor = want, want and swap.orig[swap.owner] or nil
    if want then
        U.log(TAG, "pad ids PARKED: P1's PC on id %d, the pad of id %s reaches no player, only its guest's area (%s)",
            PARK_ID, tostring(swap.parkFor), tostring(why))
        -- Live 2026-10-14 22:43 (pre-run LOADOUT split) and 22:20 (vendor shop split): the swap's refocus ran BEFORE
        -- the park moved the ids, and Slate keeps a focus under the user index it was given for: after the park the
        -- PC on pad id 0 (the owner, driven by P1's pad) had no cursor on P1's native screen, D-pad and A dead
        -- (harness stuck 5 min). Focus re-given for the owner on the screen's own target (live: D-pad moved at once).
        if not M.isQuiet() then
            local w = guestScreen()
            if w then
                refocus(w)
                laterRefocus("park")
                U.log(TAG, "pad ids PARKED: the screen owner's focus re-given on %s (pad id 0 = P1's pad)", U.className(w))
            end
        end
    else
        U.log(TAG, "pad ids unparked: P1's PC back on id %s (%s)", tostring(swap.orig[swap.owner]), tostring(why))
        if not M.isQuiet() then parkP1Focus() end
    end
    return true
end

-- couch-fix53: the map input hold (see HOLD_ID). on = true while couchpanel holds P1's run map for a guest's rewards;
-- called every couchpanel tick of the hold (idempotent: the live ids are re-checked every HOLD_CHECK_MS and put back
-- when something moved them). -> true while the hold is in place
local HOLD_CHECK_MS = 500
function M.mapInputHold(on, why)
    on = on == true
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if on and not (swap.on and swap.orig and swap.owner and #lp >= 2 and U.ok(p1)) then
        -- not swapped: the PC on id 0 is P1's own and owns no guest screen; nothing to move (the button hold remains)
        if swap.hold then swap.hold, swap.holdWhy = false, nil end
        U.logEvery("couch.maphold53", 10000, TAG, "fix53: map input hold not needed / not possible (ids not swapped)")
        return false
    end
    if not on then
        if not swap.hold then return false end
        swap.hold, swap.holdWhy, swap.holdCheckAt = false, nil, nil
        if not (swap.on and swap.orig and swap.owner and U.ok(p1)) then return false end
        local GS = U.cdo("GameplayStatics")
        local ids = wantedIds(swap.orig, U.key(p1), swap.owner, swap.parked == true, false)
        local ok = ids and pcall(function() applyIds(GS, lp, ids) end)
        U.log(TAG, "fix53: map input hold ended (%s): P1's pad drives the shared map again (pad ids %s)", tostring(why),
            ok and "swapped as before" or "NOT restored")
        if not M.isQuiet() then
            -- Slate keeps a focus under the user it was given for: the map's focus back for its owner (pad id 0 again)
            local w = guestScreen()
            if w then refocus(resumeScreen(w)); laterRefocus("map input hold end") end
        end
        return ok == true
    end
    local now = St.nowMs()
    if swap.hold and now < (swap.holdCheckAt or 0) then return true end
    swap.holdCheckAt = now + HOLD_CHECK_MS
    local GS = U.cdo("GameplayStatics")
    local p1Key = U.key(p1)
    local ids = wantedIds(swap.orig, p1Key, swap.owner, swap.parked == true, true)
    if not ids then return false end
    local live = liveIds(GS, lp)
    local diff = false
    for k, id in pairs(ids) do if live[k] ~= nil and live[k] ~= id then diff = true end end
    if not diff then
        if not swap.hold then swap.hold, swap.holdWhy = true, why end
        return true
    end
    local was = swap.hold
    swap.hold, swap.holdWhy = true, why
    local ok = pcall(function() applyIds(GS, lp, ids) end)
    if not ok then
        swap.hold, swap.holdWhy = false, nil
        U.warn(TAG, "fix53: map input hold FAILED (%s): the ids could not move", tostring(why))
        return false
    end
    if was then
        U.warn(TAG, "fix53: map input hold: the ids had moved (%s) - put back (the owner on id %d, P1's PC on id %s)",
            tostring(why), HOLD_ID, tostring(ids[p1Key]))
    else
        U.log(TAG, "fix53: map input hold (%s): the screen owner waits on id %d, P1's PC on his own id %s - P1's pad "
            .. "reaches no router that owns the map (no IA_UI_Accept pick / travel); P1's B hold still read by the pad "
            .. "watch", tostring(why), HOLD_ID, tostring(ids[p1Key]))
        -- P1's pad (Slate user 0) off the map's node / planet buttons: onto the invisible sink (no Slate accept either)
        if not M.isQuiet() then parkP1Focus() end
    end
    return true
end
function M.mapInputHeld() return swap.hold == true end

-- Ids left on a park / temp id with no swap on (a hot reload while parked, a failed move): back to normal ids.
-- Polled every second outside the race phases; in LOADING / PRERACE / RACING only once after a phase / world / players
-- change or a (re)load (swap.repairWanted): nothing in a race moves the ids (couch-racefast).
local REPAIR_EVENT_ONLY = { LOADING = true, PRERACE = true, RACING = true }
local function repairIds()
    if swap.on then return end
    local now = St.nowMs()
    if REPAIR_EVENT_ONLY[St.phase] then
        if not swap.repairWanted then return end
    elseif now - (swap.repairAt or -1e12) < 1000 then
        return
    end
    swap.repairWanted = nil
    swap.repairAt = now
    local lp = U.localPlayers()
    if #lp < 1 or not U.ok(lp[1].pc) then return end
    local GS = U.cdo("GameplayStatics")
    local ids = liveIds(GS, lp)
    local bad = false
    for _, id in pairs(ids) do if id >= PARK_ID then bad = true end end
    if not bad then return end
    local want = M.normalIds(ids, U.key(lp[1].pc))
    local ok = pcall(function() applyIds(GS, lp, want) end)
    U.warn(TAG, "pad ids repaired: a local player was left on a park / temporary id (hot reload?): %s",
        ok and "normal ids again" or "FAILED")
end

---------------------------------------------------------------------------------------------------- save owner
-- BUG 1 (live 2026-10-16, state/runs/20261016-livetest savewatch.log + UE4SS-launch2/3.log): with a guest joined, the
-- reward / node-pick saves went to the account-less ROOT slot SaveGames/GriffinRun.0.6.sav + GriffinSave.6.sav, the
-- CONTINUE save (ids normal) to SaveGames/<steamid>/. Every root write fell inside a "pad ids SWAPPED ... P1's PC
-- parked on id 6" window (08:56:57 node pick: swapped 08:54:56..08:56:59; 09:10:12 after rewards: swapped
-- 09:08:41..09:10:41), every account write outside one. How the game picks the folder: the campaign saves are
-- /Script/Griffin.SaveDataBase objects (CampaignSaveData = GriffinRun.<slot>.<ver>, CampaignMetaSaveData =
-- GriffinSave.<ver>), children of /Script/Engine.LocalPlayerSaveGame: the engine saves them with
-- GetPlatformUserIndex() = the user of OwningPlayer (CampaignSaveManager.LocalPlayer = P1's LocalPlayer), and the
-- game's GfnSaveGameSystemWindows (exe string) turns that user index into the <steamid> folder. GameplayStatics:
-- SetPlayerControllerID moves the LocalPlayer's user with the id: parked on 6 (or on a guest's id), P1's LocalPlayer
-- is user 6 - no account - and the save lands in the root slot. After a crash the game resumes from the stale
-- account copy (P1 loses that progress too), and swgr-save-profile.sh never moved the root files.
-- FIX: whoever holds pad id 0 IS P1's account user (P1 himself, or the screen owner while swapped / the guest during
-- a garage turn). The save objects' OwningPlayer and the manager's LocalPlayer (new save objects copy it) follow that
-- LocalPlayer: retargeted after every id move (applyIds), every MAIN tick outside the race phases (new save objects),
-- and at the game's own save event (couchrun's save listener, before the save is written). Normal ids = P1's
-- LocalPlayer again. Only an owner that is one of OUR local players is replaced (a null owner = the engine's own
-- path, left alone). cfg.CouchSaveOwner = false: off (the root-slot bug comes back).
local CSM_PATH = "/Script/Griffin.CampaignSaveManager"
local SAVE_SLOTS = { "CurrentRunSaveData", "CampaignSaveData", "CampaignMetaSaveData", "ScenarioSaveData" }
local saveOwn = { at = -1e12, holderKey = nil, n = 0, mine = {} }
local SAVE_SYNC_SKIP = { LOADING = true, PRERACE = true, RACING = true }   -- the periodic sync: no id moves in a race
M.SAVE_SLOTS = SAVE_SLOTS

function M.saveManager()
    local s = nil
    pcall(function() s = U.giSubsystem(CSM_PATH) end)
    return U.ok(s) and s or nil
end

local function liveCtrlId(lp)
    local id = nil
    if U.ok(lp) then pcall(function() id = lp.ControllerId end) end
    return type(id) == "number" and id or nil
end

-- pure (tests): entries {key, id} -> the key of the ONE entry on id 0, else nil (nobody / mid-move)
function M.saveHolderKey(entries)
    local k = nil
    for _, e in ipairs(entries or {}) do
        if e.id == 0 then
            if k ~= nil then return nil end
            k = e.key
        end
    end
    return k
end

-- -> number of save references moved. periodic = the MAIN tick's call (rate-limited, never in the race phases)
function M.saveOwnerSync(why, periodic)
    if opt("CouchSaveOwner", true) == false then return 0 end
    local now = St.nowMs()
    if periodic then
        if SAVE_SYNC_SKIP[St.phase] or now - saveOwn.at < 1000 then return 0 end
    end
    saveOwn.at = now
    local lps = U.localPlayers()
    if #lps < 1 then return 0 end
    local entries, byKey = {}, {}
    for _, e in ipairs(lps) do
        if U.ok(e.lp) then
            local k = U.key(e.lp)
            entries[#entries + 1] = { key = k, id = liveCtrlId(e.lp) }
            byKey[k] = e
        end
    end
    local hk = M.saveHolderKey(entries)
    -- (couch-livefix ii) nobody on pad id 0 (a garage turn: P1's PC on the guest's id, the guest's PC parked):
    -- P1's own LocalPlayer, never the parked guest's (the account folder itself comes from M.garageSaveIn's bracket)
    if hk == nil and U.ok(lps[1].lp) then
        local any0 = false
        for _, e in ipairs(entries) do if e.id == 0 then any0 = true end end
        if not any0 then hk = U.key(lps[1].lp) end
    end
    local holder = hk and byKey[hk] or nil
    if not holder then return 0 end
    local csm = M.saveManager()
    if not csm then return 0 end
    local moved = {}
    local p1Key = U.ok(lps[1].lp) and U.key(lps[1].lp) or 0
    local function follow(obj, field, label)
        local cur = nil
        pcall(function() cur = obj[field] end)
        local ck = U.ok(cur) and U.key(cur) or 0
        if ck ~= 0 and ck == hk then return end
        -- a null / foreign owner the mod never set = the engine's own state: left alone. One the mod set that is no
        -- local player any more (the screen owner unplugged while swapped: RemovePlayer) comes back to the holder.
        if not byKey[ck] and not saveOwn.mine[label] then return end
        if pcall(function() obj[field] = holder.lp end) then
            moved[#moved + 1] = label
            saveOwn.mine[label] = hk ~= p1Key
        end
    end
    for _, f in ipairs(SAVE_SLOTS) do
        local o = nil
        pcall(function() o = csm[f] end)
        if U.ok(o) then follow(o, "OwningPlayer", f) end
    end
    if opt("CouchSaveOwnerManager", true) ~= false then follow(csm, "LocalPlayer", "CampaignSaveManager.LocalPlayer") end
    if #moved > 0 then
        saveOwn.n = saveOwn.n + #moved
        U.log(TAG, "campaign saves -> %s's LocalPlayer (pad id 0 = P1's account folder): %s (%s)",
            holder.index == 1 and "P1" or ("local player " .. tostring(holder.index)), table.concat(moved, ", "), tostring(why))
    end
    saveOwn.holderKey = hk
    return #moved
end

-- (couch-livefix ii) ROOT-slot GriffinSave.6.sav writes during / at the end of a garage turn (savepath-watch
-- 11:45:13 .. 11:46:05): garageHold puts P1's PC on the guest's id and parks the guest's PC, so NO local player holds
-- pad id 0 while the turn's equips save (SaveCustomisationRecipes -> the meta save, synchronous) - the folder is the
-- OwningPlayer's user index = no account. The save owner is P1's account user at all times: during a hold every
-- SaveCustomisationRecipes call is BRACKETED - P1's PC on id 0 for the call (no input is processed during it, as
-- M.withPadId), the save objects on P1's LocalPlayer, the ids back after. Any other save object written while nobody
-- holds id 0 is reported (WARN) and the meta save is written again at the hold's end (SaveMetaSaveAsync).
local garageSaveRec = nil                -- forward: the garage hold record (set below)
function M.garageSaveIn()
    local r = garageSaveRec and garageSaveRec()
    if not r or r.bracket then return false end
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if not U.ok(p1) then return false end
    local GS = U.cdo("GameplayStatics")
    for _, id in pairs(liveIds(GS, lp)) do if id == 0 then return false end end
    local cur = nil
    pcall(function() cur = GS:GetPlayerControllerID(p1) end)
    if type(cur) ~= "number" then return false end
    local ok = pcall(function() GS:SetPlayerControllerID(p1, 0) end)
    if not ok then return false end
    r.bracket = { id = cur }
    r.bracketN = (r.bracketN or 0) + 1
    U.try(TAG, M.saveOwnerSync, "garage turn save")
    return true
end
function M.garageSaveOut()
    local r = garageSaveRec and garageSaveRec()
    if not (r and r.bracket) then return false end
    local b = r.bracket
    r.bracket = nil
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if not U.ok(p1) then return false end
    local ok = pcall(function() U.cdo("GameplayStatics"):SetPlayerControllerID(p1, b.id) end)
    if not ok then U.warn(TAG, "garage turn: P1's PC could not go back to id %s after a save", tostring(b.id)) end
    return ok
end
-- couchrun's OnPreSave hook: every save object the game writes (kind "run" / "meta")
function M.onSaveObject(obj, kind)
    M.saveOwnerSync("the game saves")
    local id = nil
    pcall(function() id = tonumber(obj.OwningPlayer.ControllerId) end)
    local r = garageSaveRec and garageSaveRec()
    if r and id ~= 0 then
        r.accountless = (r.accountless or 0) + 1
        U.warn(TAG, "garage turn: a %s save while no player holds pad id 0 (pad id %s): written again at the turn's end",
            tostring(kind), tostring(id))
    end
    return id
end

-- the run save the game is writing now: whose user (pad id) its OwningPlayer has. -> id or nil, the slot field
function M.saveUserNow()
    local csm = M.saveManager()
    if not csm then return nil end
    for _, f in ipairs({ "CurrentRunSaveData", "CampaignMetaSaveData" }) do
        local o = nil
        pcall(function() o = csm[f] end)
        if U.ok(o) then
            local own = nil
            pcall(function() own = o.OwningPlayer end)
            local id = liveCtrlId(own)
            if id ~= nil then return id, f end
        end
    end
    return nil
end
function M.saveOwnerStats() return { moved = saveOwn.n } end

---------------------------------------------------------------------------------------------------- action bar tags
-- BUG-4 / coordinator (9) (live s24 + Jules's jules-ratio-004442, pre-run LOADOUT confirmation split): P1's footer read
-- "[P2] Select / [P2] Customize / [P2] Change Difficulty / [P2] Help / [P2] Back" and P2's strip "[P1] Back". Every
-- screen's footer is WBP_ActionBar -> FuseBoundActionBar (bDisplayOwningPlayerActionsOnly = false, decoded) with
-- WBP_Input_Dark_Btn_C entries; with 2+ local players the engine prefixes an entry with "[P{PlayerNum}] {ActionName}"
-- (exe string). PlayerNum follows the binding owner's ControllerId, and the entries are built when the bindings change
-- - i.e. while the pad ids are SWAPPED / PARKED for a guest-owned screen (P1's LocalPlayer on id 1 -> "[P2]"); the
-- unswap that follows changes no binding, so the wrong tag stays. In a couch campaign every player looks at his own
-- area, so the prompts carry NO tag: the "[Pn] " prefix is stripped from each entry's Text_ActionName (the button list
-- re-found when the set of activated screens changes - couch.activeScreens' cache, no scan of its own - or every
-- TAGS_SCAN_MS; the texts re-checked every TAGS_CHECK_MS: a bar rebuilt by the engine is clean again within 250 ms).
-- cfg.CouchActionTags = false keeps the engine's tags.
-- couch-fix46 (live round 1 AUTO-120, shot 145326-g8-mystery: P2's footer "[P1] Select / [P1] View Build" on the
-- mystery screen, clean 10 s later): a guest's NATIVE COPY (couchpanel: built ~600 ms after the screen came up, once it
-- settled) brings its own footer buttons, but the button list was re-found only when the activated screens changed (the
-- copy is no activated screen) or every TAGS_SCAN_MS: the copy's footer kept its tags up to 5 s. Now a screen change
-- also re-finds the list TAGS_FOLLOW_MS later (the copies built after it), and couchpanel asks for a re-find when a
-- guest copy opens (M.tagsSoon).
local TAGS_SCAN_MS, TAGS_CHECK_MS = 5000, 250
local TAGS_FOLLOW_MS = { 700, 1500, 3000 }
local TAGS_PHASES = { OTHER = true, POSTRACE = true, PRERACE = true }
local tagsS = { list = {}, scanAt = -1e12, checkAt = -1e12, fixed = 0, scans = 0, sig = nil, follow = nil, sigAt = 0,
                soon = nil }

-- the activated screens' keys as one string (a screen opened / closed = another signature)
local function screensSig()
    local ks = {}
    for _, e in ipairs(scanCache.list or {}) do ks[#ks + 1] = tostring(e.k) end
    table.sort(ks)
    return table.concat(ks, ",")
end

-- pure: an action label without the engine's player prefix ("[P2] Select" -> "Select"); nil when it has none
function M.untagAction(s)
    if type(s) ~= "string" then return nil end
    return s:match("^%[P%d%]%s*(.-)$")
end

local function tagsScan(now)
    tagsS.scanAt, tagsS.scans = now, tagsS.scans + 1
    local list = {}
    pcall(function()
        for _, b in ipairs(FindAllOf("WBP_Input_Dark_Btn_C") or {}) do
            if U.ok(b) then list[#list + 1] = b end
        end
    end)
    tagsS.list = list
end

-- -> entries fixed this pass
function M.tagsTick(force)
    if opt("CouchActionTags", true) == false then return 0 end
    if #U.localPlayers() < 2 then return 0 end
    local now = St.nowMs()
    if now < quietUntil then return 0 end
    local sig = screensSig()
    local soon = tagsS.soon
    tagsS.soon = nil
    local fw = TAGS_FOLLOW_MS[tagsS.follow or 99]
    local follow = fw ~= nil and now >= tagsS.sigAt + fw
    if follow then tagsS.follow = tagsS.follow + 1 end
    if force or soon or sig ~= tagsS.sig or follow or now - tagsS.scanAt >= TAGS_SCAN_MS then
        if soon or sig ~= tagsS.sig then tagsS.sigAt, tagsS.follow = now, 1 end
        tagsS.sig = sig
        tagsScan(now)
    elseif now - tagsS.checkAt < TAGS_CHECK_MS then return 0 end
    tagsS.checkAt = now
    local n = 0
    for _, b in ipairs(tagsS.list) do
        if U.alive(b) then
            local t = nil
            pcall(function() t = b.Text_ActionName end)
            if U.ok(t) then
                local cur = nil
                pcall(function() cur = t:GetText():ToString() end)
                local plain = M.untagAction(cur)
                if plain and pcall(function() t:SetText(U.ftext(plain)) end) then n = n + 1 end
            end
        end
    end
    if n > 0 then
        tagsS.fixed = tagsS.fixed + n
        U.dbg(TAG, "action bar: %d player tag(s) removed (%d so far)", n, tagsS.fixed)
    end
    return n
end
function M.tagsStats() return { scans = tagsS.scans, fixed = tagsS.fixed, buttons = #tagsS.list } end
-- couch-fix46: a guest copy with its own footer just opened: re-find the buttons now and again shortly after
function M.tagsSoon() tagsS.soon = true end

---------------------------------------------------------------------------------------------------- skip cinematic
-- Live 2026-10-15 (final, 16:29 / 16:41): with P2 joined, holding A never skipped the arrival cinematic. Its
-- WBP_Skip_Cinematic_C belongs to the LAST local PC (the guest) like every native screen: the swap gives it P1's pad,
-- but the hold button (WBP_SkipScene_Btn, bRequiresHold, BP_HoldData_Default) never completed. Decoded BP: the
-- button's Clicked event (BndEvt__..._CommonButtonBaseClicked) runs owner.PauseForCutscene(false) and broadcasts
-- owner.OnSkipCutscene - the whole skip. Bridge: ANY local player's A (P1 also Enter / Space) held for
-- cfg.CouchSkipHoldMs (1200 then; 800 since couch-scaccept, the native hold is 750 ms and goes first) on an activated skip
-- screen calls that event once per screen; fallback the button's HandleButtonClicked.
-- Live 2026-10-16 round 3 (16:10:00): the bridge "fired" on a screen owned by pad 4's DORMANT PC and the cinematic
-- played on. Decoded WBP_Skip_Cinematic (cue4cli --script): EVERY step goes through GetOwningPlayer(): Construct shows
-- HB_SkipWrapper only when the OWNER IsInSkippableCutscene(), the Clicked event skips only when the OWNER is in one
-- (PauseForCutscene(false) + owner.OnSkipCutscene) - a guest's / dormant PC never is, the cinematic is P1's. And the
-- prompt itself: WBP_SkipScene_Btn reveals (Anim_Reveal) and fills PB_Hold only from OnActionProgress(HeldPercent),
-- i.e. the OWNER's hold input - so with a guest owner it never showed. Now (cfg.CouchSkipReown, default true):
--   * the bridge also runs when only DORMANT local players share the screens (M.sharedScreens), not only with the
--     couch rules on (dormant-only: no bridge at all before);
--   * a guest-owned skip screen gets its prompt from the mod's hold: HB_SkipWrapper visible while a local PC (P1
--     first) is in a skippable cutscene, the button's own OnActionProgress(held / CouchSkipHoldMs) every tick of the
--     hold (the game's reveal animation, ring and hide timer), 0 on a release;
--   * at the end of the hold the screen is re-owned to the PC that IS in the skippable cutscene (P1 first:
--     UUserWidget:SetOwningPlayer) right before its Clicked event: the game's own skip code then runs for P1.
-- A P1-owned screen (no other local player, or no guest owns it) is left to the game: its own hold works there.
local SKIP_CLS = "WBP_Skip_Cinematic_C"
local SKIP_EVT = "BndEvt__WBP_Skip_Cinematic_WBP_SkipScene_Btn_K2Node_ComponentBoundEvent_1_CommonButtonBaseClicked__DelegateSignature"
local skipS = { since = nil, done = {}, keys = nil, shown = {}, prog = nil, cur = nil }
local VIS = C.E.Vis

-- pure: the hold state machine. st {since}; down = any A held now -> true when the hold reached holdMs
function M.skipHold(st, now, down, holdMs)
    if not down then st.since = nil; return false end
    st.since = st.since or now
    return now - st.since >= (holdMs or 1200)
end

-- pure: the prompt's fill for a hold (0..1); 0 when not held. A held key shows at least a sliver (the BP reveals the
-- prompt on the first progress > 0).
function M.skipProgress(st, now, holdMs)
    if not st.since then return 0 end
    local p = (now - st.since) / (holdMs or 1200)
    if p < 0.01 then p = 0.01 elseif p > 1 then p = 1 end
    return p
end

-- couch-scaccept (live 2026-10-17, P1 = Steam Input pad): P1's A never shows in a PlayerInput on a guest-owned screen
-- (the sponsor-screen finding): a local player's A held per swgr_inputfilter.dll's PAD WATCH (down mask bit 0 of his
-- PHYSICAL pad's Slate UserIndex = his original id), whatever the pad type
local function padWatchA()
    if opt("CouchPadWatchBridge", true) == false then return false end
    local IF = package.loaded["inputfix"]
    if type(IF) ~= "table" or type(IF.padPresses) ~= "function" then return false end
    local okW, on = pcall(function() return IF.padWatch() end)
    if not (okW and on == true) then return false end
    local okP, pads = pcall(IF.padPresses)
    if not okP or type(pads) ~= "table" then return false end
    for _, lp in ipairs(U.localPlayersRO()) do
        local id = M.originalIdOf(lp.pc)
        if id == nil then id = lp.ctrlId end
        local e = type(id) == "number" and pads[id] or nil
        if type(e) == "table" and ((tonumber(e.down) or 0) & 1) == 1 then return true end
    end
    return false
end
M._padWatchA = padWatchA

local function skipDown(btn)
    if padWatchA() then return true end
    if not skipS.keys then
        skipS.keys = { { KeyName = U.fname(C.KEY.A) }, { KeyName = U.fname("Enter") }, { KeyName = U.fname("SpaceBar") } }
    end
    local down = false
    for i, lp in ipairs(U.localPlayersRO()) do
        if U.ok(lp.pc) then
            pcall(function()
                if lp.pc:IsInputKeyDown(skipS.keys[1]) == true then down = true end
                if i == 1 and (lp.pc:IsInputKeyDown(skipS.keys[2]) == true or lp.pc:IsInputKeyDown(skipS.keys[3]) == true) then
                    down = true
                end
            end)
        end
        if down then return true end
    end
    -- the guest-owned button itself (Slate delivers P1's pad to the widget focused for its user while swapped)
    if U.ok(btn) then pcall(function() down = btn:IsPressed() == true end) end
    return down
end

-- the local PC whose cinematic this is: P1 first, then any local PC in a skippable cutscene; nil = none says so
local function skipTarget()
    local lps = U.localPlayers()
    for _, lp in ipairs(lps) do
        if U.ok(lp.pc) then
            local inCut = false
            pcall(function() inCut = lp.pc:IsInSkippableCutscene() == true end)
            if inCut then return lp.pc, lp.index end
        end
    end
    return nil
end
M._skipTarget = skipTarget

-- couch-skip (live round 3 #33, 19:42 L_Mastiff_LOOP_A): the bridged Clicked fired once, re-owned to P1, and the race
-- intro played on 14 s (round 2, 19:01 LOOP_B: two skips, ignition 22 s later). Decoded (exe CL381121, static):
--   * WBP_Skip_Cinematic's Clicked = owner.PauseForCutscene(false) + broadcast owner.OnSkipCutscene (PC +0x760).
--   * the chain player (PlayerCinematicFlowComponent, PC +0x8C0) binds OnSkipCutscene -> SkipCinematicChain when it
--     starts a chain whose CutsceneSkippable / CutsceneCanBePaused is set (AddUnique of FName "SkipCinematicChain");
--     SkipCinematicChain stops the LevelSequenceActor's player, sets its skipped flag (+0x181) and calls
--     OnCinematicFinished(continueCinematicChain = false): the WHOLE chain ends (all its shots), not one shot.
--     CsmActionPlaySequence binds the same delegate -> SkipSequence (the paddock / map presentation sequences).
--   * IsInSkippableCutscene = PC.PlayerCinematicFlowComponent.CurrentCinematicChain.CutsceneSkippable (or the CSM
--     sequence flag at PC +0x860/+0x861): it is per PC.
--   * the race intro is chained per PLAYER: every local PC plays the track intro (CINC_TrackIntro_*, skippable) and
--     then the grid intro (CINC_RaceGridIntro*, skippable, 2+ shots); CINC_Ignition_Chain / the rolling starts are
--     NOT skippable. A sequence's camera cuts land on the FIRST local PC (viewguard V-VG-FIN), and the race flow waits
--     for every player's chain: P1's skip ended P1's chain, the guest's chain kept the intro (and P1's view) going.
-- So P1's skip = the game's skip for EVERY local PC in a skippable cutscene: the screen re-owned to each in turn and
-- its own Clicked event (each PC's OnSkipCutscene), P1 last (the screen ends P1's as before). Each (PC, chain) once.
local function chainOf(pc)
    local ch = nil
    pcall(function()
        local f = pc.PlayerCinematicFlowComponent
        if U.ok(f) then
            local c = f.CurrentCinematicChain
            if U.ok(c) then ch = c end
        end
    end)
    return ch
end

local function chainName(ch)
    if not ch then return "a sequence" end
    local n = nil
    pcall(function() n = U.objName(ch) end)
    return n or "a chain"
end

-- every local PC in a skippable cutscene, P1 first: { pc, index, chain }
local function skipTargets()
    local out = {}
    for _, lp in ipairs(U.localPlayersRO()) do
        if U.ok(lp.pc) then
            local inCut = false
            pcall(function() inCut = lp.pc:IsInSkippableCutscene() == true end)
            if inCut then out[#out + 1] = { pc = lp.pc, index = lp.index, chain = chainOf(lp.pc) } end
        end
    end
    return out
end
M._skipTargets = skipTargets

-- (PC, chain) pairs skipped in this world: the sweep never skips a chain twice (one the game keeps current after its
-- skip, one a skip screen already ended)
local function skipId(t, scrKey)
    return tostring(U.key(t.pc)) .. ":" .. (t.chain and tostring(U.key(t.chain)) or ("seq" .. tostring(scrKey)))
end
local function skippedYet(id)
    if skipS.skippedGen ~= St.worldGen then skipS.skipped, skipS.skippedGen = {}, St.worldGen end
    return skipS.skipped[id] == true
end
local function markSkipped(id)
    if skipS.skippedGen ~= St.worldGen then skipS.skipped, skipS.skippedGen = {}, St.worldGen end
    skipS.skipped[id] = true
end

-- the local players' cinematic state, for the log: "P1 CINC_TrackIntro_MAS_LOOP_A skippable, P2 none"
local function skipStateText()
    local parts = {}
    for _, lp in ipairs(U.localPlayersRO()) do
        if U.ok(lp.pc) then
            local inCut = false
            pcall(function() inCut = lp.pc:IsInSkippableCutscene() == true end)
            local ch = chainOf(lp.pc)
            parts[#parts + 1] = string.format("P%d %s%s", lp.index, ch and chainName(ch) or "no chain",
                inCut and " skippable" or "")
        end
    end
    return table.concat(parts, ", ")
end
M._skipStateText = skipStateText

local function reownOn() return opt("CouchSkipReown", true) ~= false end

-- a guest-owned skip screen: its wrapper visible once (a local PC is in a skippable cutscene), the button's progress
-- from the mod's hold (only when it changed)
local function skipPrompt(scr, btn, pct)
    if not skipS.shown[scr.k] then
        local tgt = skipTarget()
        if tgt then
            skipS.shown[scr.k] = true
            local vis, wrap = nil, nil
            pcall(function() wrap = scr.w.HB_SkipWrapper end)
            if U.ok(wrap) then pcall(function() vis = wrap:GetVisibility() end) end
            if U.ok(wrap) and vis ~= nil and vis ~= VIS.Visible and vis ~= VIS.SelfHitTestInvisible then
                local ok = pcall(function() wrap:SetVisibility(VIS.Visible) end)
                U.log(TAG, "skip cinematic: guest-owned %s, the cinematic is a local player's: its skip prompt shown (%s)",
                    SKIP_CLS, ok and "ok" or "failed")
            end
        end
    end
    if not U.ok(btn) then return end
    if pct == skipS.prog then return end
    if pct == 0 and (skipS.prog == nil or skipS.prog == 0) then skipS.prog = 0; return end
    skipS.prog = pct
    pcall(function() btn:OnActionProgress(pct) end)
end

-- one step of the hold on a found skip screen (MAIN's skipTick and the FAST skipFast): the prompt, then the skip
-- couch-scaccept (live 2026-10-17, finding #17): one bridged skip ended ONE shot of the race intro / map presentation
-- and the next shot's skip screen came up 5 s later ("pressing skip doesn't skip"). P1's skip is for the whole
-- presentation: a new skip screen within cfg.CouchSkipChainMs (8000) of the last bridged skip, in the same world, while
-- a local PC is still in a skippable cutscene, is skipped at once (no second hold); each chained skip extends it.
local function chainOn(now)
    return skipS.chainUntil ~= nil and now < skipS.chainUntil and skipS.chainGen == St.worldGen
end

local function skipStep(scr)
    if skipS.done[scr.k] then return end
    local btn = nil
    pcall(function() btn = scr.w.WBP_SkipScene_Btn end)
    local now = St.nowMs()
    -- the game's own hold is 0.75 s (BP_HoldData_Default, decoded): the bridge's default 800 ms matches it (a working
    -- native skip still goes first; the IsActivated check below never skips a screen the game already closed)
    local holdMs = tonumber(opt("CouchSkipHoldMs", 800)) or 800
    local chained = chainOn(now) and skipTarget() ~= nil
    local done = chained or M.skipHold(skipS, now, skipDown(btn), holdMs)
    local guestOwned = not scr.p1
    if guestOwned and reownOn() then U.try(TAG, skipPrompt, scr, btn, done and 1 or M.skipProgress(skipS, now, holdMs)) end
    if not done then return end
    skipS.since = nil
    local act = false
    if U.alive(scr.w) then pcall(function() act = scr.w:IsActivated() == true end) end
    if not act then return end                         -- the native hold acted first: the screen is gone
    skipS.done[scr.k] = true
    -- the game's skip runs for the screen's OWNER: the screen goes to each local PC in a skippable cutscene in turn
    -- (the guests first, P1 last: it ends P1's like before) and its Clicked event runs for each (#33)
    local reowned, also = nil, nil
    local targets = {}
    if reownOn() then
        -- (a new skip screen = a new step of the presentation: every PC in a skippable cutscene, once per screen)
        for _, t in ipairs(skipTargets()) do t.id = skipId(t, scr.k); targets[#targets + 1] = t end
        if #targets == 0 and guestOwned then reowned = "no local PC in a skippable cutscene: owner kept" end
    end
    local function fire()
        local okE, errE = pcall(function() scr.w[SKIP_EVT](scr.w, btn) end)
        if okE then return true, "its Clicked event" end
        local okH, errH = pcall(function() btn:HandleButtonClicked() end)
        return okH, "HandleButtonClicked (" .. tostring(errE) .. ")", errH
    end
    local ok, how, err = false, "its Clicked event", nil
    if #targets == 0 then
        ok, how, err = fire()
    else
        local owner = nil
        pcall(function() owner = scr.w:GetOwningPlayer() end)
        local others = {}
        for i = #targets, 1, -1 do
            local t = targets[i]
            local okO = true
            if not (U.ok(owner) and U.same(owner, t.pc)) then
                okO = pcall(function() scr.w:SetOwningPlayer(t.pc) end)
                if okO then owner = t.pc end
            end
            local okT, howT, errT = fire()
            if okT then markSkipped(t.id) end
            if i == 1 then
                ok, how, err = okT, howT, errT
                if guestOwned or t.index ~= 1 then
                    reowned = okO and ("re-owned to local player " .. tostring(t.index)) or "re-own FAILED"
                end
            else
                ok = ok or okT
                others[#others + 1] = string.format("P%d's %s%s", t.index, chainName(t.chain), okT and "" or " (FAILED)")
            end
        end
        if #others > 0 then also = "also skipped: " .. table.concat(others, ", ") end
    end
    if ok then
        U.log(TAG, "skip cinematic: %s -> %s on the %s screen (owned by %s%s%s)",
            chained and "next shot of the same presentation (chain)" or string.format("A held %d ms", holdMs), how,
            SKIP_CLS, scr.p1 and "P1" or "a guest", reowned and (", " .. reowned) or "", also and ("; " .. also) or "")
        skipS.chainUntil, skipS.chainGen = now + (tonumber(opt("CouchSkipChainMs", 8000)) or 8000), St.worldGen
        skipS.diagAt = now + 1500
    else
        U.warn(TAG, "skip cinematic: bridge failed: %s", tostring(err))
    end
    skipS.cur = nil
    M.markDirty("skip cinematic")
end

-- couch-skip (#33): the rest of the presentation P1 skipped, without a skip screen. Inside the chain window (same
-- world, paddock / PRERACE only), a local PC that is (still or again) in a skippable cutscene on a chain not skipped
-- yet gets the game's own skip handler for chains: PauseForCutscene(false) + its PlayerCinematicFlowComponent's
-- SkipCinematicChain (what its OnSkipCutscene runs). Covers a guest's chain that started after P1's skip and the
-- next chain of the intro (the grid intro after the track intro) when its screen is not up. Never the ignition: its
-- chain is not skippable (decoded) and the ignition / countdown / racing states stop the sweep.
local SWEEP_PHASES = { OTHER = true, PRERACE = true }
local SWEEP_STOP = { "CSM_RF_IgnitionSequence", "CSM_RF_RollingStart", "CSM_RF_Countdown", "CSM_RF_Racing" }
local function sweepStopped()
    local P = package.loaded["present"]
    if type(P) ~= "table" or type(P.stateActive) ~= "function" then return false end
    for _, n in ipairs(SWEEP_STOP) do
        local okS, v = pcall(P.stateActive, n)
        if okS and v == true then return n end
    end
    return false
end

local function skipSweep(now)
    if opt("CouchSkipSweep", true) == false or not reownOn() then return end
    if not chainOn(now) or not SWEEP_PHASES[St.phase] then return end
    local todo = {}
    for _, t in ipairs(skipTargets()) do
        if t.chain then
            t.id = skipId(t)
            if not skippedYet(t.id) then todo[#todo + 1] = t end
        end
    end
    if #todo == 0 then return end
    local stop = sweepStopped()
    if stop then
        U.logOnce("couch.skip.sweepstop." .. tostring(St.worldGen) .. stop, TAG,
            "skip cinematic: %s is up: the presentation skip stops here (%d skippable chain(s) left alone)", stop, #todo)
        return
    end
    for _, t in ipairs(todo) do
        markSkipped(t.id)
        pcall(function() t.pc:PauseForCutscene(false) end)
        local okS, errS = pcall(function() t.pc.PlayerCinematicFlowComponent:SkipCinematicChain() end)
        if okS then
            U.log(TAG, "skip cinematic: local player %d's %s is part of the presentation P1 skipped -> its "
                .. "SkipCinematicChain (the game's OnSkipCutscene handler, no skip screen) (chain)", t.index, chainName(t.chain))
            skipS.chainUntil = now + (tonumber(opt("CouchSkipChainMs", 8000)) or 8000)
            skipS.diagAt = now + 1500
        else
            U.warn(TAG, "skip cinematic: local player %d's SkipCinematicChain failed: %s", t.index, tostring(errS))
        end
    end
    M.markDirty("skip cinematic")
end

-- 1.5 s after a skip: what every local PC still plays (the live check of #33)
local function skipDiag(now)
    if not skipS.diagAt or now < skipS.diagAt then return end
    skipS.diagAt = nil
    U.log(TAG, "skip cinematic: 1.5 s after the skip: %s", skipStateText())
end

-- MAIN (couch.tick, 250 ms): finds the skip screen (the shared screen scan) and steps the hold once
function M.skipTick()
    if opt("CouchSkipBridge", true) == false then skipS.since, skipS.cur = nil, nil; return end
    -- round 3: dormant local players own the screens too (no joined guest: the rules are off, the screens shared)
    if not (state.on or M.sharedScreens()) then skipS.since, skipS.cur = nil, nil; return end
    local now = St.nowMs()
    local scr = nil
    for _, e in ipairs(M.activeScreens()) do
        if e.cls == SKIP_CLS then scr = e; break end
    end
    if not scr then
        -- #33: the game's own hold (a P1-owned screen) skipped P1's chain: the screen closed under a hold of 0.6 s+.
        -- The rest of the presentation (the guests' chains, the next chain) follows it like a bridged skip.
        if skipS.since and now - skipS.since >= 600 and skipS.curK and not skipS.done[skipS.curK] then
            skipS.chainUntil, skipS.chainGen = now + (tonumber(opt("CouchSkipChainMs", 8000)) or 8000), St.worldGen
            skipS.diagAt = now + 1500
            U.log(TAG, "skip cinematic: the %s screen closed under a %d ms hold (the game's own skip): the rest of the "
                .. "presentation follows it (%s)", SKIP_CLS, now - skipS.since, skipStateText())
        end
        skipS.since = nil; skipS.done = {}; skipS.shown = {}; skipS.prog = nil; skipS.cur = nil; skipS.curK = nil
        U.try(TAG, skipSweep, now)
        skipDiag(now)
        return
    end
    skipS.curK = scr.k
    skipS.cur = (not skipS.done[scr.k]) and scr or nil
    skipStep(scr)
    if skipS.done[scr.k] then U.try(TAG, skipSweep, now) end
    skipDiag(now)
end

-- FAST (main.lua, 33 ms, paddock + PRERACE): the hold and its ring on the screen MAIN found - a 1.2 s hold read every
-- 250 ms was up to 250 ms late and its ring moved in 4 steps. No scan here: the cached entry only.
local SKIP_FAST_PHASES = { OTHER = true, PRERACE = true }
function M.skipFast()
    local scr = skipS.cur
    if not scr then return end
    if not SKIP_FAST_PHASES[St.phase] or St.nowMs() < quietUntil or not U.alive(scr.w) then skipS.cur = nil; return end
    skipStep(scr)
end

-- garagenative.lua: during a guest's garage turn his pad drives P1's PC (the game's garage screens belong to P1):
-- P1's PC on the guest's pad id. The swap / park logic stays out while held.
-- EXCLUSIVE TURN (cfg.CouchGarageExclusive, default true; couch-garage2 2026-10-16): the first version put the guest's
-- PC on id 0, so P1's physical pad drove the GUEST's PC - and through it the run map overview, which stays activated
-- (guest-owned) under the garage (live 2026-10-15) - and P1's pad kept the Slate focus the garage screens' CommonUI
-- activation hands to P1's LocalPlayer user (user 0 = pad 0 whatever its ControllerId: live, P2's D-pad did nothing
-- until the mod gave user 1 a focus). Now:
--   * the guest's PC waits on PARK_ID: P1's pad reaches NO LocalPlayer (no PlayerInput, no CommonUI action router),
--     CommonUI lets its keys through to Slate (couch.lua's PARK, live-verified for the guest splits);
--   * Slate user 0 (P1's pad) is focused on an invisible, non-navigable sink (WBP_Common_Btn, all navigation rules
--     Stop); every activation that takes it into the garage is undone by M.garageSinkCheck (garagenative's FAST tick):
--     the guest's PC goes to id 0 for one SetUserFocus call and back to PARK_ID (no input is processed during a Lua
--     call on the game thread, as couch.withPadId).
--   * at the end every PC gets back the id it had at the start (recorded), user 0's focus leaves the sink.
local garageRec = nil         -- { ctrlId, orig = {[pcKey] = id}, guestKey, parked, sink, resinks, at }
local garageHeld = nil
garageSaveRec = function() return garageRec end
local NAV_STOP = 3            -- EUINavigationRule::Stop (Escape 0, Explicit 1, Wrap 2, Stop 3)
local PARK_EXTRA = 11         -- the other local PCs' park ids during a garage turn (11, 12, ...: clear of PARK_ID and
                              -- of applyIds' temporary ids TEMP_ID .. TEMP_ID + 3)
M.PARK_EXTRA = PARK_EXTRA

local function newSink(p1)
    local w = nil
    pcall(function()
        local cls = U.class("/Game/Griffin/UI/Widgets/Buttons/WBP_Common_Btn.WBP_Common_Btn_C")
        w = U.WBL():Create(p1, cls, p1)
        w:SetRenderOpacity(0)
        w:AddToViewport(-100)
        w:BP_SetIsFocusable(true)
    end)
    if not U.ok(w) then return nil end
    pcall(function() w:SetAllNavigationRules(NAV_STOP, U.fname("None")) end)
    return w
end

local function garageSink(p1)
    local r = garageRec
    if r and U.ok(r.sink) then return r.sink end
    local w = newSink(p1)
    if r and w then r.sink = w end
    return w
end

-- the sink holds a focus: a WBP_Common_Btn (CommonButtonBase) forwards a focus it is given to its internal root button,
-- so HasAnyUserFocus on the widget itself stays false (live 2026-10-16: "P1's pad re-sunk 3508 time(s)" in ~90 s =
-- a re-sink every FAST tick); the descendants count too (backprompt / menubridge test buttons the same way)
local function sinkHeld(sink)
    if not U.ok(sink) then return false end
    local held = false
    pcall(function() held = sink:HasAnyUserFocus() == true or sink:HasFocusedDescendants() == true end)
    return held
end
M._sinkHeld = sinkHeld

local function guestPcOf(rec)
    for _, e in ipairs(U.localPlayersRO()) do
        if U.ok(e.pc) and U.key(e.pc) == rec.guestKey then return e.pc end
    end
    return nil
end

-- user 0 (P1's physical pad) -> the sink: the guest's PC carries id 0 for the one call (it is parked otherwise)
local function sinkUser0(rec, why)
    local guest = guestPcOf(rec)
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if not (U.ok(guest) and U.ok(p1)) then return false end
    local sink = garageSink(p1)
    if not sink then return false end
    local GS = U.cdo("GameplayStatics")
    local ok = false
    local moved = pcall(function() GS:SetPlayerControllerID(guest, 0) end)
    if moved then ok = pcall(function() sink:SetUserFocus(guest) end) end
    if rec.parked then
        local back = pcall(function() GS:SetPlayerControllerID(guest, PARK_ID) end)
        if not back then
            rec.parked = false
            U.warn(TAG, "garage turn: the guest's PC could not go back to id %d (P1's pad drives the guest's PC now)", PARK_ID)
        end
    end
    rec.resinks = (rec.resinks or 0) + 1
    U.dbg(TAG, "garage turn: P1's pad focus on the sink (%s): %s", tostring(why), ok and "ok" or "failed")
    return ok
end

-- (c) a parked OTHER local PC's own pad (Slate user = its original id) -> its own sink: CommonUI's activation of a
-- garage screen focuses the screen OWNER's physical pad - with dormant pads that is pad 4's user, which would then
-- drive the garage through Slate although its PC is parked. The PC carries its own id for the one call.
local function sinkUserX(rec, x, why)
    if not U.ok(x.pc) then return false end
    local lp = U.localPlayers()
    local p1 = lp[1] and lp[1].pc
    if not U.ok(x.sink) then x.sink = U.ok(p1) and newSink(p1) or nil end
    if not U.ok(x.sink) then return false end
    local GS = U.cdo("GameplayStatics")
    local ok = false
    local moved = pcall(function() GS:SetPlayerControllerID(x.pc, x.id) end)
    if moved then ok = pcall(function() x.sink:SetUserFocus(x.pc) end) end
    local back = pcall(function() GS:SetPlayerControllerID(x.pc, x.park) end)
    if not back then U.warn(TAG, "garage turn: a parked local PC could not go back to id %d", x.park) end
    rec.xresinks = (rec.xresinks or 0) + 1
    U.dbg(TAG, "garage turn: pad id %s focus on its sink (%s): %s", tostring(x.id), tostring(why), ok and "ok" or "failed")
    return ok
end

function M.garageHold(ctrlId, on)
    local lp = U.localPlayers()
    if #lp < 2 or not U.ok(lp[1].pc) then return false end
    local GS = U.cdo("GameplayStatics")
    if on then
        if swap.on then M.setSwap(false, "guest garage turn") end
        local orig = liveIds(GS, lp)
        local p1Key = U.key(lp[1].pc)
        if garageRec and garageRec.orig then orig = garageRec.orig end      -- held twice: keep the first record
        local want, guestKey = {}, nil
        for _, e in ipairs(lp) do
            if U.ok(e.pc) then
                local k = U.key(e.pc)
                local id = orig[k]
                if e.index == 1 then want[k] = ctrlId
                elseif id == ctrlId then want[k] = 0; guestKey = k
                else want[k] = id end
            end
        end
        applyIds(GS, lp, want)
        garageHeld = ctrlId
        garageRec = { ctrlId = ctrlId, orig = orig, p1Key = p1Key, guestKey = guestKey, parked = false, resinks = 0,
                      at = St.nowMs() }
        local excl = opt("CouchGarageExclusive", true) ~= false and guestKey ~= nil
        if excl then
            sinkUser0(garageRec, "turn start")                  -- the guest's PC is on id 0 right now
            local okP = pcall(function()
                local g = guestPcOf(garageRec)
                GS:SetPlayerControllerID(g, PARK_ID)
            end)
            garageRec.parked = okP
        end
        -- LIVE 2026-10-16 (couch-livefix, launch4): pads 3 / 4 plugged but not joined (DORMANT guest PCs). The game
        -- gives the garage screens to the LAST local PC (probe: "owner id 3 | lp1=1 lp2=6 lp3=2 lp4=3(OWNER)"): pad 4
        -- drove them through that PC's CommonUI router (only pad 4's A acted, its B closed the garage) and the turn-
        -- taker's A was dead. With 2 players the owner IS the parked turn-taker, which is why the turn worked there.
        -- Now every other local PC (dormant or joined, it is not his turn) is parked too, each on its own id from
        -- PARK_EXTRA: whoever owns the screens, no pad reaches them but the turn-taker's, through P1's PC.
        garageRec.extra = {}
        local extraN = 0
        if garageRec.parked and opt("CouchGarageParkOthers", true) ~= false then
            for _, e in ipairs(lp) do
                if U.ok(e.pc) and e.index ~= 1 then
                    local k = U.key(e.pc)
                    if k ~= guestKey then
                        local pid = PARK_EXTRA + extraN
                        local okX = pcall(function() GS:SetPlayerControllerID(e.pc, pid) end)
                        if okX then
                            garageRec.extra[k] = pid
                            extraN = extraN + 1
                            local x = { pc = e.pc, id = garageRec.orig[k], park = pid }
                            garageRec.xs = garageRec.xs or {}
                            garageRec.xs[k] = x
                            if x.id ~= nil then sinkUserX(garageRec, x, "turn start") end
                        end
                    end
                end
            end
        end
        -- the save objects back on P1's LocalPlayer (the move of the guest through id 0 above handed them to him)
        U.try(TAG, M.saveOwnerSync, "garage turn")
        U.log(TAG, "pad ids HELD for a garage turn: P1's PC on id %s, the guest's pad drives the game's garage; %s%s",
            tostring(ctrlId), garageRec.parked and string.format("P1's pad reaches no player (the guest's PC parked on "
            .. "id %d, P1's Slate focus on a sink)", PARK_ID) or "NOT exclusive (P1's pad drives the guest's PC)",
            extraN > 0 and string.format("; %d other local PC(s) parked (ids %d+): no other pad reaches the garage",
            extraN, PARK_EXTRA) or "")
    else
        local rec = garageRec
        garageHeld, garageRec = nil, nil
        local want = (rec and rec.orig) or M.normalIds(liveIds(GS, lp), U.key(lp[1].pc))
        -- a PC that joined during the turn keeps its id; one that left is skipped by applyIds
        applyIds(GS, lp, want)
        local ids = liveIds(GS, lp)
        if ids[U.key(lp[1].pc)] ~= 0 then
            applyIds(GS, lp, M.normalIds(ids, U.key(lp[1].pc)))     -- the record was stale: P1 back on 0 at least
        end
        for _, x in pairs((rec and rec.xs) or {}) do
            if U.ok(x.sink) then pcall(function() x.sink:RemoveFromParent() end) end
        end
        if rec and U.ok(rec.sink) then
            local sink = rec.sink
            -- user 0 (P1's pad, P1's PC again) leaves the invisible sink: the game viewport (the paddock walker / the
            -- next shared screen's refocus by M.tick take it from there)
            if sinkHeld(sink) then pcall(function() U.WBL():SetFocusToGameViewport() end) end
            pcall(function() sink:RemoveFromParent() end)
        end
        U.log(TAG, "pad ids back after the garage turn%s", rec and string.format(" (P1's pad re-sunk %d time(s); %d save(s) "
            .. "on pad id 0 by the bracket)", math.max(0, (rec.resinks or 0) - 1), rec.bracketN or 0) or "")
        U.try(TAG, M.saveOwnerSync, "garage turn end")
        if rec and (rec.accountless or 0) > 0 then
            local csm = M.saveManager()
            local ok = csm and pcall(function() csm:SaveMetaSaveAsync() end)
            U.warn(TAG, "garage turn: %d save(s) went to no account: the meta save written again for P1's account (%s)",
                rec.accountless, ok and "ok" or "FAILED")
        end
        M.markDirty("garage turn end")
    end
    return true
end
function M.garageHeld() return garageHeld ~= nil end
-- { ctrlId, parked, guestKey } of the turn, or nil (couchsim's pad-id invariant)
function M.garageHoldState()
    local r = garageRec
    if not r then return nil end
    local extra = {}
    for k, id in pairs(r.extra or {}) do extra[k] = id end
    return { ctrlId = r.ctrlId, parked = r.parked == true, guestKey = r.guestKey, resinks = r.resinks or 0,
             extra = extra, orig = r.orig }
end

-- garagenative's FAST tick during a turn: user 0 (P1's pad) still on the sink? A garage screen's activation (CommonUI
-- focuses its owner's LocalPlayer user = user 0) takes it into the garage: it goes back at once. -> true when re-sunk
-- CHEAP (couch-livefix): one focus read per call; a re-sink only when user 0's focus really left the sink. A re-sink
-- that does not stick (the next check finds the sink unfocused again at once: an unreadable focus) backs off
-- 100 ms -> 2 s instead of moving the guest's PC through id 0 every FAST tick.
local SINK_BACKOFF_MIN, SINK_BACKOFF_MAX = 100, 2000
-- st = one sink's check state {nextAt, lastAt, backoff, warned} -> true when that sink must be re-sunk now
local function sinkDue(st, sink, now, label)
    if now < (st.nextAt or -1e12) then return false end
    if sinkHeld(sink) then
        st.backoff, st.lastAt = nil, nil
        return false
    end
    -- the previous check re-sank and the sink is still not held: that re-sink did not stick
    if st.lastAt then
        st.backoff = math.min(SINK_BACKOFF_MAX, math.max(SINK_BACKOFF_MIN, (st.backoff or 0) * 2))
        if st.backoff >= SINK_BACKOFF_MAX and not st.warned then
            st.warned = true
            U.warn(TAG, "garage turn: %s focus never reads as held on its sink (re-sinks every %d ms now)", label,
                SINK_BACKOFF_MAX)
        end
    end
    st.nextAt = now + (st.backoff or 0)
    st.lastAt = now
    return true
end

function M.garageSinkCheck(why)
    local r = garageRec
    if not (r and r.parked) then return false end
    local now = St.nowMs()
    local did = false
    for _, x in pairs(r.xs or {}) do
        if x.id ~= nil and sinkDue(x, x.sink, now, "pad id " .. tostring(x.id) .. "'s") then
            sinkUserX(r, x, why or "focus left its sink")
            did = true
        end
    end
    r.s0 = r.s0 or {}
    if sinkDue(r.s0, r.sink, now, "P1's pad") then
        return sinkUser0(r, why or "focus left the sink") or did
    end
    return did
end

-- RACE FAST PATH (couch-racefast): what M.tick does in LOADING / PRERACE / RACING. No shared screen, credits chip, action
-- bar or swap exists in a race; the only race-phase work is the ids (swap given back / repair after an event) and, in
-- PRERACE, the cinematic skip bridge on the dirty-driven screen cache. RACING: no widget scan, no UFunction unless an
-- event asked for an ids repair.
-- (couch-livefix e) LIVE 2026-10-16: holding B made a guest leave in FREE MODE but not in the couch campaign -
-- join.lua's leave poll runs in the front end only. In the campaign (paddock / post-race, no garage turn, no guest area
-- open: there a quick B is his "back") a joined guest who HOLDS B for cfg.LeaveHoldMs leaves (join.campaignLeave). His
-- B is read on the PC that carries his pad id now (his own, or P1's in a plain swap); a PARKED pad (the shared screen's
-- owner) has no PlayerInput - he leaves from the paddock / a screen that is not his to own.
-- BUG #28 (round 2 2026-10-17 18:50, couch-playtest2 2d84485: Hibi's shop opened no area for P2): P1's B left HIS OWN
-- garage (menubridge OnCancelAction) under the pad-id swap - P1's pad id 0 sat on P2's PC, so the press landed in P2's
-- PlayerInput. The swap ended while B was still down: the release went to P1's PC (id 0 again) and P2's PlayerInput
-- kept B DOWN for good. 1.3 s later this poll read "P2 held B 1012 ms" and P2 left the run (dormant): no joined guest,
-- no shop split at Hibi's. A hold counts only from a FRESH press now: B must first read UP on the PC that carries his
-- id (since the ids last moved, since a guest area / the garage offer closed); a key held across an id move never
-- leaves. The garage offer ("B: NO THANKS") counts as a guest area: its B is the answer, not a leave.
local LEAVE_PHASES = { OTHER = true, POSTRACE = true }
local leave = { down = {}, told = {}, up = {}, pcOf = {}, stuck = {} }
local function leaveReset()
    leave.down, leave.told, leave.up, leave.pcOf, leave.stuck = {}, {}, {}, {}, {}
end
function M.leaveTick()
    -- a guest area (split) open: B is his "back" there (the run map's SHOP hint does not count: its B does nothing)
    local cp = package.loaded["couchpanel"]
    local area = false
    if type(cp) == "table" and type(cp.isOpen) == "function" then pcall(function() area = cp.isOpen() == true end) end
    local pr = package.loaded["couchprerun"]
    if not area and type(pr) == "table" and type(pr.state) == "function" then
        pcall(function() local st = pr.state(); area = type(st) == "table" and st.open == true end)
    end
    local rt = package.loaded["couchroot"]
    if not area and type(rt) == "table" and type(rt.active) == "function" then pcall(function() area = rt.active() == true end) end
    if not area and type(cp) == "table" and type(cp.garageOfferText) == "function" then
        pcall(function() area = cp.garageOfferText() ~= nil end)
    end
    if opt("CouchHoldBLeave", true) == false or not LEAVE_PHASES[St.phase] or garageHeld ~= nil or area then
        leaveReset()
        return nil
    end
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not (okJ and type(list) == "table") or #list == 0 then return nil end
    local lp = U.localPlayers()
    local GS = U.cdo("GameplayStatics")
    local ids = liveIds(GS, lp)
    local byId = {}
    for _, e in ipairs(lp) do if U.ok(e.pc) and ids[U.key(e.pc)] ~= nil then byId[ids[U.key(e.pc)]] = e.pc end end
    local now = St.nowMs()
    local hold = tonumber(cfg.LeaveHoldMs) or 1000
    for _, g in ipairs(list) do
        local pc = byId[g.ctrlId]
        local b = false
        if U.ok(pc) then pcall(function() b = U.mod("ui").keyDown(pc, "Gamepad_FaceButton_Right") == true end) end
        -- his id moved to another PC (a swap began / ended): that PC's key state is not his press
        local pk = U.ok(pc) and U.key(pc) or nil
        if leave.pcOf[g.ctrlId] ~= pk then
            leave.pcOf[g.ctrlId], leave.up[g.ctrlId], leave.down[g.ctrlId], leave.told[g.ctrlId] = pk, nil, nil, nil
            leave.stuck[g.ctrlId] = nil
        end
        if not b then
            leave.down[g.ctrlId], leave.told[g.ctrlId] = nil, nil
            if pk ~= nil then leave.up[g.ctrlId] = true end
            if leave.stuck[g.ctrlId] then
                leave.stuck[g.ctrlId] = nil
                U.log(TAG, "P%d's B reads up again: his hold-B leave is armed", g.pnum)
            end
        elseif not leave.up[g.ctrlId] then
            if not leave.stuck[g.ctrlId] then
                leave.stuck[g.ctrlId] = true
                U.log(TAG, "P%d's B reads DOWN before any fresh press (held across a pad-id move / a guest area): "
                    .. "not a leave until it is released (#28)", g.pnum)
            end
        else
            leave.down[g.ctrlId] = leave.down[g.ctrlId] or now
            local held = now - leave.down[g.ctrlId]
            if held >= 300 and not leave.told[g.ctrlId] then
                leave.told[g.ctrlId] = true
                pcall(function() St.emit("status", string.format("P%d: KEEP HOLDING B TO LEAVE", g.pnum)) end)
            end
            if held >= hold then
                leave.down[g.ctrlId] = nil
                local ok, left = pcall(function() return U.mod("join").campaignLeave(g.ctrlId, "held B in the campaign") end)
                if ok and left then
                    U.log(TAG, "P%d held B %d ms in the couch campaign (%s): he leaves", g.pnum, math.floor(held), St.phase)
                    M.activeForget(); M.sharedForget()
                    return g.ctrlId
                end
            end
        end
    end
    return nil
end

local RACE_TICK_PHASES = { LOADING = true, PRERACE = true, RACING = true }
local function raceTick()
    if swap.on then M.setSwap(false, "phase " .. tostring(St.phase)) end
    if swap.parked and not swap.on then swap.parked, swap.parkFor = false, nil end
    if swap.repairWanted then U.try(TAG, repairIds) end
    if St.phase ~= "PRERACE" or St.nowMs() < quietUntil then return end
    U.try(TAG, M.skipTick)
end

function M.tick()
    if swap.on then playersChanged("local players changed") end
    if garageHeld ~= nil then return end           -- garagenative turn: ids held, no swap / park / repair
    if RACE_TICK_PHASES[St.phase] then return raceTick() end
    -- ids only (also inside the quiet window: a world change ends a split without its close)
    U.try(TAG, M.parkSync, "tick")
    -- couch-fix53: a map input hold whose couchpanel hold is gone (reset / reload) ends here
    if swap.hold then
        local cp = package.loaded["couchpanel"]
        local held = false
        if type(cp) == "table" and type(cp.mapHeld) == "function" then
            local okH, h = pcall(cp.mapHeld)
            held = okH and h == true
        end
        if not held then U.try(TAG, M.mapInputHold, false, "no run map hold any more") end
    end
    U.try(TAG, repairIds)
    if St.nowMs() < quietUntil then return end
    -- #67 follow-up (tester #4 05:57): a grid KEPT at a stop pick on the post-race map (eliminator -> mystery) crossed
    -- into the paddock with the dead race world's entries; ~30 s later, as the paddock's mystery screen came up, the
    -- game crashed (AV in a memcpy under UE4SS's Lua VM, crash_2026_10_18_03_57_20). The same screen on a fresh load
    -- (no kept grid) ran fine. Empty it as soon as the paddock world is up (after the 2 s quiet): the stop then runs on
    -- an empty grid, the state every earlier paddock stop had (fix8: emptied at the pick).
    -- #67b observability (tester #5: the clear above never logged; the game had already dropped the race recipe):
    -- the no-op is logged too, so a live log tells which state the paddock stop really ran on
    if M._gridKept and U.isA(U.gs(), "/Script/Griffin.PaddockGameState") then
        M._gridKept = nil
        local okC, what = U.try(TAG, M.clearGrid, "paddock arrival: kept since a stop pick on the race world")
        if okC and what ~= "emptied" then
            U.log(TAG, "kept grid: nothing to clear at paddock arrival (%s) - the game dropped the race's recipe at the "
                .. "travel; the stop runs without it", tostring(what))
        end
    end
    U.try(TAG, function() M.chipTick() end)
    U.try(TAG, M.skipTick)
    U.try(TAG, M.saveOwnerSync, "tick", true)
    U.try(TAG, M.leaveTick)
    -- BUG 2: the screens are shared with a dormant guest's PC too (M.sharedScreens), not only while the rules are on
    local shared = state.on or (SHARED_PHASES[St.phase] and M.sharedScreens())
    if shared and not state.on and not swap.dormantLogged then
        swap.dormantLogged = true
        U.log(TAG, "no joined guest, %d local players: the screens of a dormant guest's PC are P1's (pad-id swap on)",
            #U.localPlayers())
    elseif state.on then
        swap.dormantLogged = nil
    end
    if shared and TAGS_PHASES[St.phase] then U.try(TAG, M.tagsTick) end
    if not (shared and SHARED_PHASES[St.phase]) then
        if swap.on then M.setSwap(false, "phase " .. tostring(St.phase)) end
        return
    end
    local now = St.nowMs()
    if now - swap.lastScanMs < 400 then return end
    swap.lastScanMs = now
    local w, p1Own, ownerPc = screens()
    if p1Own then w = nil end                 -- P1's own dialog on top: P1's pad must reach it with the normal ids
    -- P1 on a pre-run screen = a NEW campaign run: the guests restart on starter builds too
    if not swap.preRunSeen then
        for _, e in ipairs(M.activeScreens()) do
            if PRE_RUN[e.cls] then M.markPreRun("pre-run screen " .. e.cls); break end
        end
    end
    if w and swap.on and U.ok(ownerPc) and U.key(ownerPc) ~= swap.owner then
        -- a shared screen of ANOTHER local PC (3-4 players): the swap moves to that owner
        swap.screenKey = U.key(w)
        M.setSwap(true, "shared screen owner changed", ownerPc)
    elseif w and swap.on and U.key(w) ~= swap.screenKey then
        -- another guest-owned screen while swapped (the next cinematic's skip prompt, the next post-race screen):
        -- it gets its focus for its owner too
        swap.screenKey = U.key(w)
        parkP1Focus()
        refocus(resumeScreen(w, "new shared screen"))
        U.try(TAG, sinkOwnerPad, "new shared screen")
        U.dbg(TAG, "refocused new shared screen %s", U.className(w))
    end
    if w and swap.on and U.ok(ownerPc) and U.key(ownerPc) == swap.owner then
        U.try(TAG, cursorWatch, w, ownerPc, now)
        if U.key(w) == swap.screenKey then U.try(TAG, trackHolder, ownerPc, now) end
    end
    if swap.on and U.ok(ownerPc) and U.key(ownerPc) == swap.owner and now - (swap.imcAt or 0) >= 2000 then
        swap.imcAt = now                      -- re-asserted (pause.lua's restore edges normalise guests' IMC_UI)
        U.try(TAG, M.ownerUiInput, ownerPc, "re-check")
    end
    if w and not swap.on then
        swap.screenKey = U.key(w)
        M.setSwap(true, "guest-owned screen " .. U.className(w), ownerPc)
    elseif not w and swap.on and not p1Own and keepSwap() then
        local why = keepSwap()
        if swap.keptWhy ~= why then
            swap.keptWhy = why
            U.log(TAG, "no guest-owned screen in the scan, swap KEPT: %s", why)
            U.try(TAG, swapEndDiag)
        end
    elseif not w and swap.on then
        if p1Own then U.log(TAG, "P1-owned screen up: %s", tostring(swap.p1Cls)) end
        if not p1Own then U.try(TAG, swapEndDiag) end
        M.setSwap(false, p1Own and "P1's own screen on top" or "no shared screen")
        -- BUG-5 (live 2026-10-14, true 2P): the swap parked P1's Slate focus on the sink; his own dialog that ends the
        -- swap (WBP_LoadoutConfirmation_C after START RUN) never got it back and P1's A did nothing on it
        if p1Own and not swap.on and U.alive(swap.p1W) then
            refocus(swap.p1W)
            U.log(TAG, "P1's focus back on his own screen %s", tostring(swap.p1Cls))
        end
    end
end

---------------------------------------------------------------------------------------------------- start toast
-- A short banner when the couch rules first turn on in a session ("COUCH CAMPAIGN: P2 JOINS THE RUN"). The FREE MODE
-- status pill is front-end only, so the banner is its own display-only host (couchpanel's kit, HitTestInvisible,
-- created for P1, never focused). Shown once per guest set until the front end; 2.5 s after the rules turn on (past
-- the 2 s world-change quiet window); removed after cfg.CouchToastMs or at once on "leaving". Any failure = log only.
local toast = { host = nil, shownFor = nil, gen = 0 }
local TOAST_PHASES = { OTHER = true, PRERACE = true, RACING = true, POSTRACE = true }

local function toastClose()
    toast.gen = toast.gen + 1
    if toast.host then
        local h = toast.host
        toast.host = nil
        pcall(function() if U.ok(h) then h:RemoveFromParent() end end)
    end
end

local function toastText()
    local nums = {}
    pcall(function()
        for _, g in ipairs(U.mod("join").joinedList()) do nums[#nums + 1] = "P" .. tostring(g.pnum) end
    end)
    if #nums == 0 then return nil, nil end
    local who = table.concat(nums, " + ")
    return string.format("COUCH CAMPAIGN: %s JOIN%s THE RUN", who, #nums == 1 and "S" or ""), who
end

local function toastShow()
    local ms = tonumber(opt("CouchToastMs", 4000)) or 0
    if ms <= 0 or not state.on or M.isQuiet() or not TOAST_PHASES[St.phase] then return end
    local msg, who = toastText()
    if not msg or toast.shownFor == who then return end
    toast.shownFor = who
    St.emit("status", msg)                      -- the FREE MODE pill, if it is up; always the log
    U.log(TAG, "toast: %s", msg)
    M.banner(msg, ms)
end

-- the toast's band with any text (display only, P1-owned, HitTestInvisible), closed after ms or on "leaving"; one band
-- at a time (a new one replaces the old). Q8: soloscore's "takedown target scaled" notice in the race
function M.banner(msg, ms)
    ms = tonumber(ms) or 4000
    toastClose()
    local CP = U.mod("couchpanel")
    local kit = CP.kit
    local H = CP.newHost()
    pcall(function() H.host:SetVisibility(kit.VIS.HitTestInvisible) end)
    local bandW, bandH, y = 2000, 170, 120
    local band = kit.solid(H.tree, kit.colours.DEEP)                    -- opaque: translucent solids never draw
    kit.place(H.cv, band, math.floor((kit.VW - bandW) / 2), y, bandW, bandH, 1)
    local edge = kit.solid(H.tree, kit.colours.AMBER)
    kit.place(H.cv, edge, math.floor((kit.VW - bandW) / 2), y + bandH - 8, bandW, 8, 2)
    local t = kit.text(H.tree, 64, kit.colours.AMBER)
    kit.setText(t, msg)
    local s = kit.place(H.cv, t, math.floor(kit.VW / 2), y + 40, nil, nil, 3)
    pcall(function() s:SetAlignment({ X = 0.5, Y = 0 }) end)
    H.host:AddToViewport((tonumber(opt("CouchPanelZ", 1000)) or 1000) + 10)
    toast.host = H.host
    local gen = toast.gen
    U.mod("sched").after("couch.toast.close", ms, function() if toast.gen == gen then toastClose() end end)
end

---------------------------------------------------------------------------------------------------- guests' credits chip
-- Blocker 3 (live 2026-10-14, map / shop / rewards): the native top-right chip shows P1's credits only; a guest has no
-- way to see his own (couchrun) credits outside his split area. While the couch rules apply and a map, shop or
-- rewards screen is up and NO split is open (a split area shows the guest's credits itself), a display-only chip per
-- guest sits left of the native chip: "P2  6200 CR" in the guest's colour badge on the campaign's dark pill. P1-owned,
-- HitTestInvisible, above the Menu layer; rebuilt only when the guest set changes, its text only when a value changes.
local CHIP_MATCH = { "RunMapOverview", "RunMap_Presentation", "Paddock_NextEvent", "PostRace_Cam_Holder", "Shop",
                     "ExoticVendor", "ScrapDealer", "Reward" }
local chip = { host = nil, set = nil, texts = {}, natives = {}, last = {}, rects = nil, tags = {} }

-- pure: do these activated screen classes show the native credits chip?
function M.chipScreen(classes)
    for _, cn in ipairs(classes or {}) do
        for _, pat in ipairs(CHIP_MATCH) do if cn:find(pat, 1, true) then return true end end
    end
    return false
end

-- Live 2026-10-15 (final F1/F2): the guests' chip row and couchpanel's (A) SHOP / GARAGE hint sit at z ~995, above
-- the game's Menu / Dialog layers: they drew ON TOP of the paddock pause menu and its EXIT TO MAIN MENU dialog.
-- While a pause screen, a modal or a confirm dialog is up, every guest overlay is collapsed (not closed: no rebuild,
-- no park / focus change) and shown again when it closes.
local MENU_MATCH = { "WBP_Pause", "WBP_Modal", "Stickerbook", "Logbook", "Settings", "PhotoMode", "WBP_PlayerMenu" }

-- pure: is one of these activated screen classes a pause screen / modal that guest overlays must not cover?
function M.menuOverScreen(classes)
    for _, cn in ipairs(classes or {}) do
        for _, pat in ipairs(MENU_MATCH) do if cn:find(pat, 1, true) then return true end end
    end
    return false
end

local menuC = { at = -1e12, v = false }
-- -> true while a pause menu / modal / confirm dialog is up (cached 100 ms: polled from the FAST loop)
function M.menuOver()
    local now = St.nowMs()
    if now - menuC.at < 100 then return menuC.v end
    menuC.at = now
    local cls = {}
    for _, e in ipairs(M.activeScreens()) do cls[#cls + 1] = e.cls end
    local v = M.menuOverScreen(cls)
    if not v then pcall(function() v = U.csmPoll("CSM_PauseActive") == true end) end
    if not v then
        local pz = package.loaded["pause"]
        if type(pz) == "table" and type(pz.dialogWidget) == "function" then
            local ok, w = pcall(pz.dialogWidget)
            v = ok and w ~= nil and U.ok(w) or false
        end
    end
    menuC.v = v == true
    return menuC.v
end
function M._menuReset() menuC.at = -1e12 end      -- tests

-- pure: the chip text of a guest - the native chip's number format ("1,800"); the P2 tag is drawn separately
function M.chipText(pnum, credits)
    local n = tostring(math.floor(tonumber(credits) or 0))
    local out = n:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return out
end

local function chipClose()
    local h = chip.host
    chip.host, chip.set, chip.texts, chip.natives, chip.last, chip.rects, chip.tags = nil, nil, {}, {}, {}, nil, {}
    chip.hidden = nil
    if h and U.alive(h) then pcall(function() h:RemoveFromParent() end) end
end

local function chipGuests()
    local out = {}
    pcall(function()
        for _, g in ipairs(U.mod("join").joinedList()) do
            local p = U.mod("couchrun").player(g.ctrlId)
            out[#out + 1] = { pnum = g.pnum, credits = p and p.credits or 0 }
        end
    end)
    return out
end

-- NOTE 4 (Jules 2026-10-14: "squared, not centered, no logo, no P1, not beautiful - and how would it look with P1 P2 P3
-- P4"): ONE ROW of identical chips at the native chip's place, P1 rightmost (the game's own chip, untouched) then P2,
-- P3, P4 to its left, equal gaps. Every guest chip is built like the native one: the header's rounded backer
-- (MI_UI_Pill_FE_Section_CurrencyBacker, Box 0.5, #131313 @0.90, 105 tall), the game's WBP_PlayerCreditsAmount_C
-- (credits logo + Font_Display number, "1,800") rewired to his couch credits (couchpanel chipRewire), vertically
-- centred like the native one; each chip - P1's native one too - carries a small rounded player tag (MI_UI_Pill_Generic
-- in the player's colour, "Pn") inside the pill at its right end (P1: in the end cap, right of his token icon).
-- Geometry measured on live 4K frames (2026-10-14 crashfix-verify s27 shop / s41 map, 3840 canvas): native pill right
-- edge 3706, y 78-182; icon x +16 (77 su); number from +113; token icon R-106..R-63; width "300" 455, "1,800" 488.
local CHIP_PILL = "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_FE_Section_CurrencyBacker.MI_UI_Pill_FE_Section_CurrencyBacker"
local CHIP_TAG = "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_Generic.MI_UI_Pill_Generic"
local CHIP_ICON = "Icons/T_UI_CreditCurrency_Icn"
-- LIVE 2026-10-14 (s56 chip row, P1 at 0 CR): P1's pill was 451 wide (the header's minimum, not the 384 guessed),
-- so P2's pill overlapped it and P2's tag sat on P1's credits icon; P1's overlay tag in the end cap was cut off. Now:
-- P1_MIN 451 (measured), P1's text width read from his own chip at runtime (Txt_PlayerCredits:GetDesiredSize, widget
-- units x the header's 0.96; FGeometry is not readable in this UE4SS build, theme.lua), P1's tag INSIDE his native pill
-- (the last child of its own HB_Currency, couchpanel.tagInto: the pill lays it out and grows by P1_TAG) - the end-cap
-- overlay only when his chip is not found -, a SAFE margin on the gap, every guest tag inside its own pill with padding.
-- LIVE 2026-10-16 round 2 (20-eventmap.png, 3,600 CR, TWO token pips): P2's pill ran 37 su into P1's. P1's pill holds
-- the run's strike pips (WBP_Cam_StrikesWidget: one WBP_Cam_Strike_Entry per CampaignRun:GetMaxStrikes(), decoded
-- ConstructStrikes); every measurement above had ONE pip. Each further pip widens it by STRIKE (measured: the two
-- pips 95 su apart, P1's pill 600 su wide at 3,600 CR): opts.p1Strikes.
local ROW = { R = 3706, Y = 78, H = 105, GAP = 28, SAFE = 16, ICON_X = 16, SCALE = 0.96, TAG_W = 52, TAG_H = 40,
              TAG_R = 18, NUM_MIN = 173, NUM_GAP = 18, P1_MIN = 451, P1_BASE = 296, P1_TAG = 68, P1_CAP = 36,
              STRIKE = 95 }
M.CHIP_ROW = ROW
-- the native number's glyph advances at the header's scale (measured: "300" = 159 su, "1,800" = 193 su)
local GLYPH = { ["1"] = 22, [","] = 12 }
function M.chipTextW(credits)
    local w = 0
    for ch in M.chipText(0, credits):gmatch(".") do w = w + (GLYPH[ch] or 53) end
    return w
end
-- pure: the row. entries = { {pnum, credits}, ... } with P1 first; opts.p1tw = P1's measured text width (su),
-- opts.p1Inside = P1's tag is inside his native pill (it grows by P1_TAG). -> rects { [pnum] = {x, y, w, h, order,
-- tag = {x, y, w, h, native}} } in the 3840 x 2160 canvas; the guests strictly left of P1, GAP + SAFE apart.
function M.chipLayout(entries, opts)
    opts = opts or {}
    local out, right = {}, ROW.R
    for i, e in ipairs(entries) do
        local tw = M.chipTextW(e.credits)
        local w, tag
        if i == 1 then
            tw = math.max(tw, tonumber(opts.p1tw) or 0)
            local pips = math.max(0, math.floor(tonumber(opts.p1Strikes) or 1) - 1) * ROW.STRIKE
            w = math.max(ROW.P1_MIN, ROW.P1_BASE + tw + pips) + (opts.p1Inside and ROW.P1_TAG or 0)
            if opts.p1Inside then
                tag = { x = right - 40 - ROW.TAG_W, y = ROW.Y + (ROW.H - ROW.TAG_H) / 2, w = ROW.TAG_W, h = ROW.TAG_H,
                        native = true }
            else                                       -- the end cap, right of his token icon (R-63)
                tag = { x = right - 16 - ROW.P1_CAP, y = ROW.Y + (ROW.H - ROW.P1_CAP) / 2, w = ROW.P1_CAP,
                        h = ROW.P1_CAP }
            end
        else
            w = ROW.ICON_X + math.floor(77 + 10 * ROW.SCALE + 0.5) + math.max(ROW.NUM_MIN, tw) + ROW.NUM_GAP
                + ROW.TAG_W + ROW.TAG_R
        end
        local x = right - w
        tag = tag or { x = x + w - ROW.TAG_R - ROW.TAG_W, y = ROW.Y + (ROW.H - ROW.TAG_H) / 2, w = ROW.TAG_W,
                       h = ROW.TAG_H }
        out[e.pnum] = { x = x, y = ROW.Y, w = w, h = ROW.H, order = i, tag = tag }
        right = x - ROW.GAP - ((i == 1) and ROW.SAFE or 0)
    end
    return out
end

-- P1's own credits chip on the screen up (the header of a map / shop / rewards screen) -> chip widget or nil
local function p1NativeChip()
    for _, e in ipairs(M.activeScreens()) do
        if M.chipScreen({ e.cls }) and U.alive(e.w) then
            local hdr = nil
            pcall(function() hdr = e.w.WBP_Header_Presentation end)
            if not U.ok(hdr) then
                pcall(function() hdr = e.w:GetWidgetFromName(U.fname("WBP_Header_Presentation")) end)
            end
            local c = nil
            if U.ok(hdr) then pcall(function() c = hdr.WBP_PlayerCreditsAmount end) end
            local vis = false
            if U.ok(c) then pcall(function() vis = hdr:IsVisible() == true end) end
            if U.ok(c) and vis then return c end
        end
    end
    return nil
end

local function boxImage(kit, H, matPath, colour) return kit.pillImage(H.tree, matPath, colour) end

-- the player tag: a rounded pill in his colour with "Pn" centred
local function chipTag(kit, H, pnum, r)
    local col = C.COLOURS[pnum] or kit.colours.AMBER
    local pill = boxImage(kit, H, CHIP_TAG, col)
    kit.place(H.cv, pill, r.x, r.y, r.w, r.h, 4)
    local t = kit.text(H.tree, (r.h < ROW.TAG_H) and 18 or 22, (C.COLOUR_INK and C.COLOUR_INK[pnum]) or kit.colours.INKD)
    kit.setText(t, "P" .. tostring(pnum))
    local s = kit.place(H.cv, t, r.x + r.w / 2, r.y + r.h / 2, nil, nil, 5)
    pcall(function() s:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    return pill
end

local function chipBuild(gs, p1cr)
    local CP = U.mod("couchpanel")
    local kit = CP.kit
    local H = CP.newHost()
    pcall(function() H.host:SetVisibility(kit.VIS.HitTestInvisible) end)
    local entries = { { pnum = 1, credits = p1cr or 0 } }
    for _, g in ipairs(gs) do entries[#entries + 1] = { pnum = g.pnum, credits = g.credits } end
    -- P1's own chip: his tag inside its pill (once per chip), his text width measured
    local nc, inside, tw = p1NativeChip(), false, nil
    chip.tagged = chip.tagged or {}
    if nc then
        local k = U.key(nc)
        if chip.tagged[k] then inside = true
        else
            local okT, box = pcall(kit.tagInto, nc, 1)
            if okT and box then chip.tagged[k] = true; inside = true end
        end
        pcall(function()
            local d = nc.Txt_PlayerCredits:GetDesiredSize()
            local x = tonumber(d and d.X)
            if x and x > 0 then tw = x * ROW.SCALE end
        end)
    end
    local rects = M.chipLayout(entries, { p1tw = tw, p1Inside = inside, p1Strikes = chip.strikes })
    chip.texts, chip.natives, chip.rects, chip.tags = {}, {}, rects, {}
    chip.p1Inside = inside
    local PILL = { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.9 }       -- #131313 @0.90 (B_CurrencyHolder BrushColor)
    local p1 = U.p1()
    local ccls = nil
    pcall(function() ccls = U.class(kit.CHIP_CLS) end)
    if not inside then chip.tags[1] = chipTag(kit, H, 1, rects[1].tag) end   -- fallback: the end cap overlay
    if inside then chip.tags[1] = nc end
    for _, g in ipairs(gs) do
        local r = rects[g.pnum]
        kit.place(H.cv, boxImage(kit, H, CHIP_PILL, PILL), r.x, r.y, r.w, r.h, 1)
        chip.tags[g.pnum] = chipTag(kit, H, g.pnum, r.tag)
        local nat = nil
        if U.ok(ccls) and U.ok(p1) then
            local okC, cw = pcall(function() return U.WBL():Create(p1, ccls, p1) end)
            if okC and U.ok(cw) then
                local okP, slot = pcall(kit.place, H.cv, cw, r.x + ROW.ICON_X, r.y + r.h / 2, nil, nil, 3)
                if okP and slot then
                    pcall(function() slot:SetAlignment({ X = 0, Y = 0.5 }) end)
                    pcall(function() cw:SetRenderTransformPivot({ X = 0, Y = 0.5 }) end)
                    pcall(function() cw:SetRenderScale({ X = ROW.SCALE, Y = ROW.SCALE }) end)
                    pcall(function() cw:SetVisibility(kit.VIS.HitTestInvisible) end)
                    nat = kit.chipRewire(cw)
                end
            end
        end
        if nat then
            chip.natives[g.pnum] = nat
        else                                               -- the painted twin: the game's logo + the native font
            local icon = kit.mk(kit.IMAGE, H.tree)
            if icon then
                local tex = kit.texOf(CHIP_ICON)
                if tex then pcall(function() icon:SetBrushFromTexture(tex, false) end) end
                pcall(function() icon:SetColorAndOpacity(kit.lin(kit.colours.PAPER)) end)
                pcall(function() icon:SetVisibility(kit.VIS.HitTestInvisible) end)
                kit.place(H.cv, icon, r.x + ROW.ICON_X, r.y + (r.h - 77) / 2, 77, 77, 2)
            end
            local t = kit.text(H.tree, 44, kit.colours.PAPER)
            local s = kit.place(H.cv, t, r.x + 113, r.y + r.h / 2, nil, nil, 3)
            pcall(function() s:SetAlignment({ X = 0, Y = 0.5 }) end)
            chip.texts[g.pnum] = t
        end
    end
    H.host:AddToViewport((tonumber(opt("CouchPanelZ", 1000)) or 1000) - 5)
    chip.host = H.host
    pcall(function() U.mod("couchroot").exclude(H.host) end)
    local n = 0
    for _ in pairs(chip.natives) do n = n + 1 end
    U.log(TAG, "guests' credits chip: %d native chip(s), %d painted; row P1..P%d from x %d", n, #gs - n, #gs + 1,
        math.floor(rects[entries[#entries].pnum].x))
end

function M.chipTick()
    local want = opt("CouchCreditsChip", true) ~= false and state.on and (St.phase == "OTHER" or St.phase == "POSTRACE")
        and not M.isQuiet()
    if want then
        local okR, split = pcall(function() return U.mod("couchroot").active() end)
        if okR and split == true then want = false end
    end
    if want then
        local cls = {}
        for _, e in ipairs(M.activeScreens()) do cls[#cls + 1] = e.cls end
        want = M.chipScreen(cls)
    end
    if not want then if chip.host then chipClose() end; return end
    local gs = chipGuests()
    if #gs == 0 then if chip.host then chipClose() end; return end
    local p1cr = 0
    pcall(function() p1cr = U.mod("couchrun").campaignCredits() or 0 end)
    -- P1's strike pips (his pill's width): CampaignRun:GetMaxStrikes(), read with the credits
    local strikes = nil
    pcall(function() strikes = tonumber(M.campaignSubsystem().ActiveRun:GetMaxStrikes()) end)
    chip.strikes = strikes
    local set = { "1:" .. math.floor(M.chipTextW(p1cr)) .. "/" .. tostring(strikes) }
    for _, g in ipairs(gs) do set[#set + 1] = tostring(g.pnum) .. ":" .. math.floor(M.chipTextW(g.credits)) end
    local setKey = table.concat(set, ",")       -- guests + every chip's text width: a wider number re-lays the row
    if chip.host and (chip.set ~= setKey or not U.alive(chip.host)) then chipClose() end
    if not chip.host then
        local ok, err = pcall(chipBuild, gs, p1cr)
        if not ok then
            U.logEvery("couch.chip", 10000, TAG, "credits chip not built: %s", tostring(err))
            chipClose()
            return
        end
        chip.set = setKey
        chip.last = {}
        chip.hidden = nil
        local pn = {}
        for _, g in ipairs(gs) do pn[#pn + 1] = tostring(g.pnum) end
        U.log(TAG, "guests' credits chip up (%s)", table.concat(pn, ","))
    end
    local hide = M.menuOver()
    if hide ~= (chip.hidden == true) then
        chip.hidden = hide
        local kit = U.mod("couchpanel").kit
        pcall(function() chip.host:SetVisibility(hide and kit.VIS.Collapsed or kit.VIS.HitTestInvisible) end)
        U.log(TAG, "guests' credits chip %s", hide and "hidden under a pause menu / dialog" or "shown again")
    end
    if hide then return end
    for _, g in ipairs(gs) do
        local txt = M.chipText(g.pnum, g.credits)
        local nat = chip.natives and chip.natives[g.pnum]
        if nat and not nat.swapped then chip.last[g.pnum] = nil end   -- settled chips: re-applied every tick
        if chip.last[g.pnum] ~= txt then
            chip.last[g.pnum] = txt
            if nat then
                U.mod("couchpanel").kit.chipFeed(nat, g.credits)
            else
                pcall(function() U.mod("couchpanel").kit.setText(chip.texts[g.pnum], txt) end)
            end
        end
    end
end
M.chipClose = chipClose
function M.chipUp() return chip.host ~= nil end
function M._chip() return chip end                -- tests: the chip state (natives / texts)

local function toastArm()
    if (tonumber(opt("CouchToastMs", 4000)) or 0) <= 0 then return end
    U.mod("sched").after("couch.toast", 2500, function() U.try(TAG, toastShow) end)
end

local function onPhase(new, old)
    activeMemo.at = -1e12                       -- the race fast path keeps M.active() 2 s: a phase re-decides at once
    swap.repairWanted = true                    -- repairIds runs on events only in the race phases
    if new == "FRONTEND" or new == "LOADING" then toastClose() end
    if new == "FRONTEND" then toast.shownFor = nil end
    if new == "FRONTEND" or new == "LOADING" then if swap.on then M.setSwap(false, "phase " .. new) end end
    -- any phase without shared screens: normal ids at once (a race seen first as PRERACE skipped LOADING)
    if not SHARED_PHASES[new] and swap.on then M.setSwap(false, "phase " .. new) end
    if new == "LOADING" or new == "FRONTEND" then swap.preRunSeen = nil end
    if new == "FRONTEND" then M.restoreTimeTrials() end
    if new == "LOADING" or new == "PRERACE" then ghosted = {} end
    -- PRERACE too: a race picked in the PADDOCK goes OTHER -> TRANSIT -> PRERACE (no LOADING phase), and its
    -- ignition cameras kept side bars in P1's strip (live 2026-10-14, L_Dalmatian_P2P after a mystery node)
    if (new == "LOADING" or new == "PRERACE") and (state.on or M.active()) then letterbox(false, "couch race " .. new) end
    if new == "PRERACE" and lbOff then
        lbPollStart()
        local sched = U.mod("sched")
        for _, ms in ipairs({ 200, 1500, 4000 }) do
            -- two FindAllOf walks each: never once the race runs (the 4 s one can land in RACING after a short intro)
            sched.after("couch.unconstrain." .. ms, ms, function()
                if St.phase == "PRERACE" then U.try(TAG, M.unconstrainCameras) end
            end)
        end
    end
    if new == "OTHER" or new == "FRONTEND" then letterbox(true, "phase " .. new) end
    -- #30: the plane test's flag lives from its kickoff to the paddock / front end after it
    if new == "OTHER" or new == "FRONTEND" then planeT.kicked = false end
    -- couch-trial2: a mission with instances: instances.lua hides / un-collides the other sets instead (its own
    -- PRERACE / RACING listener; it calls ghostCars itself when it falls back)
    -- couch-fieldtest: a 1-car field test (the grid holds only the players) gives each player his own instance too
    if new == "PRERACE" and state.on ~= false and M.isTimeTrial() and not M.isPlaneTest() then
        pcall(function() U.mod("instances").planSolo("field test") end)
    end
    local instOn = false
    pcall(function() instOn = U.mod("instances").planned() == true end)
    if (new == "PRERACE" or new == "RACING") and state.on ~= false and M.isTimeTrial() and not instOn then
        U.mod("sched").after("couch.ghost", 800, function() U.try(TAG, M.ghostCars, new) end)
    end
    if new == "FRONTEND" then
        setPrologueSkip()
        if state.on then
            state.on = false
            U.log(TAG, "couch campaign rules OFF (back in the front end)")
        end
        return
    end
    -- CONTINUE of a run saved at StartEvent goes FRONTEND -> race directly (ContinueCurrentMapNodeEvent): no node pick,
    -- so no grid patch, P2 got no car and takeover hijacked an AI car -> native crash (exe+0x641579, live 2026-10-14).
    -- The saved recipe is back before the travel: patch it now (the guest takes an AI entry like after a pick).
    -- couch-fix49 (AUTO-127): a pending CHAMPIONSHIP is placed by couchrules (boss instances / the shared boss race,
    -- its head-to-head grid grown before the continue's builder ran); every other continue as before
    if new == "TRANSIT" and old == "FRONTEND" and hasActiveRun() then
        local handled = false
        pcall(function() handled = U.mod("couchrules").continuePlace("campaign CONTINUE (front end -> run)") == true end)
        if not handled then U.try(TAG, function() M.patchGrid("campaign CONTINUE (front end -> run)", true) end) end
    end
    if new == "TRANSIT" or new == "BOOT" then return end
    local now = M.active()
    if now ~= state.on then
        state.on = now
        U.log(TAG, "couch campaign rules %s (phase %s, %d local player(s), active run %s)", now and "ON" or "OFF",
            tostring(new), #U.localPlayers(), tostring(hasActiveRun()))
        if now then toastArm() end
    end
end

function M.init()
    -- (couch-livefix ii) a garage turn's own saves on P1's account (M.garageSaveIn / garageSaveOut)
    pcall(function()
        U.hook("/Script/Griffin.CstCustomisationComponent:SaveCustomisationRecipes", {
            pre = function() U.try(TAG, M.garageSaveIn) end,
            post = function() U.try(TAG, M.garageSaveOut) end,
        }, TAG)
    end)
    St.on("phase", TAG, function(new, old) U.try(TAG, onPhase, new, old) end)
    -- couch-trial2: the mission instances (loaded with couch; its own phase / leaving / world listeners)
    U.try(TAG, function() U.mod("instances").init() end)
    St.on("leaving", TAG, function() quiet("leaving"); toastClose(); chipClose(); chip.tagged = {} end)
    swap.repairWanted = true                    -- a (re)load: one ids check whatever the phase
    St.on("world", TAG, function() swap.repairWanted = true; quiet("world"); chip.host, chip.set, chip.texts, chip.last = nil, nil, {}, {} end)
    St.on("players", TAG, function()
        activeMemo.at, swap.repairWanted = -1e12, true
        U.try(TAG, playersChanged, "players changed"); M.markDirty("players")
        -- a garage turn whose guest left: the held ids are given back (garagenative ends the turn when it sees it)
        if garageRec then
            local r = garageRec
            local found = false
            for _, e in ipairs(U.localPlayersRO()) do if U.ok(e.pc) and U.key(e.pc) == r.guestKey then found = true end end
            if not found then U.try(TAG, M.garageHold, r.ctrlId, false) end
        end
    end)
    St.on("phase", TAG .. ".dirty", function() M.markDirty("phase") end)
    St.on("phase", TAG .. ".planet", function(new) if new == "RACING" then U.try(TAG, M.raceStartPlanet) end end)
    -- every paddock / post-race screen is shown by a CosmeticStateMachine state action: a state change = a full scan
    for _, fn in ipairs({ "ChangeToState", "BackToPreviousState", "ContinueToNextState", "FinishState" }) do
        U.hook("/Script/Griffin.CosmeticStateMachine:" .. fn, { post = function()
            csmSeq = csmSeq + 1
            M.markDirty("csm " .. fn)
        end }, TAG .. ".dirty")
    end
    U.hook("/Script/Griffin.CampaignSubsystem:ChooseNextMapNode", {
        -- the native builder fills RecipeState.Racers only while it is EMPTY (06b §1). After a race the old grid is
        -- still there in a couch run (live 2026-10-14: "P2 already in", then a crash in the race -> race travel: the
        -- previous race's AI PlayerStates are gone). Emptied before the pick, so the campaign builds a fresh grid.
        -- couch-fix57: OFF the race world only (paddock map). The store makes a fresh recipe instance at every pick;
        -- on the post-race map the old one is kept whole (clearGrid: freeing it there vanished the game, round 4).
        pre = function(_, node)
            -- couch-fix51: the reward map hold disables the node buttons; a pick that still gets through is a native
            -- path not blocked yet (UE4SS cannot veto the call): said loudly for the next test
            pcall(function()
                local CP = U.mod("couchpanel")
                if CP.mapHeld and CP.mapHeld() == true then
                    U.warn(TAG, "fix51: a node pick went through while P1's run map was held for a guest's rewards "
                        .. "(an unblocked native path): the guest's open rounds become skip credits")
                end
            end)
            planeT.kicked = false
            M._pickKept = nil
            forgetCouchBuilds("node pick")
            pcall(function() U.mod("instances").reset("node pick") end)
            U.try(TAG, M.planetCheck, node)
            U.try(TAG, M.clearGrid, "before the node pick", node)
            U.try(TAG, function() if M.active() or U.isA(U.gs(), "/Script/Griffin.PaddockGameState") then
                M.patchTimeTrials(#guestPlayerStates())
            end end)
        end,
        post = function() U.try(TAG, M.patchGrid, "node picked") end,
    }, TAG)
    -- couch-fix53 (AUTO-131(c), 15:29:13: NEXT PLANET went through the held overview without any line): the planet
    -- travel says so too (diagnostic: UE4SS cannot veto it; the map input hold keeps P1's pad off the owner's router)
    U.hook("/Script/Griffin.CampaignSubsystem:TravelToNextPlanet", {
        pre = function()
            pcall(function()
                local CP = U.mod("couchpanel")
                if CP.mapHeld and CP.mapHeld() == true then
                    U.warn(TAG, "fix53: a planet travel went through while P1's run map was held for a guest's rewards "
                        .. "(map input hold %s): the guest's open rounds become skip credits",
                        M.mapInputHeld() and "ON - an unblocked path" or "off")
                end
            end)
        end,
    }, TAG .. ".fix53")
    -- #51: a field test (and every mystery kickoff) builds its grid and requests the travel INSIDE FinishLeaving
    -- (decoded above, "field tests"): pre = the field test's grid grown, post = restored + placed per player
    U.hook("/Script/Griffin.PaddockGameMode:FinishLeaving", {
        pre = function() U.try(TAG, M.fieldTestPre) end,
        post = function() U.try(TAG, M.fieldTestPost) end,
    }, TAG)
    -- #30: the planet's plane test (paddock): its own grid build + travel, no node pick
    U.hook("/Script/Griffin.CampaignRun:KickOffPlaneTestEvent", {
        pre = function() U.try(TAG, M.planeTestPre) end,
        post = function() U.try(TAG, M.planeTestPost) end,
    }, TAG)
    U.hook("/Script/Griffin.CampaignSubsystem:ContinueCurrentMapNodeEvent", {
        post = function() U.try(TAG, M.patchGrid, "ContinueCurrentMapNodeEvent", true) end,
    }, TAG)
    U.log(TAG, "init: CouchCampaign=%s CouchSkipPrologue=%s", tostring(opt("CouchCampaign", true)),
        tostring(opt("CouchSkipPrologue", true)))
end

function M.status()
    return string.format("couch: rules %s (%s), pad ids %s", state.on and "ON" or "off", tostring(state.why),
        swap.on and (swap.parked and string.format("swapped + P1 parked on %d (pad %s free)", PARK_ID,
            tostring(swap.parkFor)) or "swapped") or "normal")
end

return M
