-- gauntlet.lua (couch-gauntlet, TEST TOOL, cfg.TestCommands only): one couch campaign run in which every race type of
-- the campaign comes up one after the other, each through the game's OWN node flow (map / paddock node pick -> the
-- game's own event build -> paddock / race -> results -> reward rounds -> map), so each type can be checked with its
-- rewards. How to drive it: docs/dev/gauntlet.md. Never active for players: it is initialised by testcmd.lua only
-- when cfg.TestCommands is true, and it does nothing until "gauntlet start" (or cfg.Gauntlet = true).
--
-- HOW (static evidence, CL381121 launch exe; the two debug-field clears
-- below are byte-identical in the CL382801 hf2 exe, one site each):
--   * A map node carries NO event: CampaignEventMapNode has Activity (+0x40), Reward (+0x41), PlanetIndex (+0x28),
--     PlanetDayIndex (+0x2c), Planet (+0x58) - the event is made at the PICK. CampaignSubsystem:ChooseNextMapNode
--     (impl 0x1430d4990) stores the node in run.mChosenNextNode (+0x400) and switches on ITS Activity (0x1430d4e01,
--     jump table 0x149a09a18, cases 2..10):
--       2 / 3  -> the planet's EventPicker (GenerateEventChoices(node.Planet, day, isHighRisk = Activity == 3) +
--                 PickEvent): a standard race / a high-risk (eliminator) race of THIS planet
--       4      -> run.mDebugConfig.NextPreviewEvent (+0x448) when set: used AND CLEARED (0x1430d5382..0x1430d5398),
--                 else a random event of node.Planet.PreviewEvents (+0x108): a FIELD TEST
--       10     -> run.mDebugConfig.NextPlaneSprintEvent (+0x450) when set: used and cleared (0x1430d52ec..0x1430d530a),
--                 else node.Planet.PlaneSprintEvents; needs Campaign.MapGenRules.PlaneSprintEventGameMode (CAM_MapGenRules
--                 has GMV_PlaneSprint): a PODRACER / PLANE SPRINT
--       5 / 6  -> 0x1471ec2ca / 0x1471ec19a: Tour.Planets[node.PlanetIndex].DaySetups[node.PlanetDayIndex].OverrideEvent
--                 (a soft pointer, resolved with TSoftObjectPtr::Get 0x1470895ae = only when LOADED), with
--                 MapGenRules.KnockOutEventGameMode / ChampionEventGameMode: the KNOCKOUT / the CHAMPIONSHIP. Only the
--                 last planet (Derven Acos) has such day setups (CAM_Tour1_Whippet_Mid day 0 = EVT_WHP_MID_BOSS;
--                 CAM_Tour2/3_WhippetEnd day 0 knockout, day 1 championship); every other planet has no DaySetups.
--       7 / 8 / 9 (and 11 / 12) -> no event at the pick: the black market, the repair stop, the mystery encounter
--     So a node becomes any type by its Activity, written in the native PRE-hook of ChooseNextMapNode (the pick itself),
--     and everything after it is the game's own code: the event build, couch.patchGrid (post-hook: guests' cars), the
--     travel (0x1430d6534 switches on the same Activity), the race, the result ingestion, the reward rounds (generated
--     at the race end for the node, N5 in couchrules.lua) and the map. Rewards are therefore those of a normal node of
--     that type on the CURRENT planet and day.
--   * Field tests per MODE: the gauntlet hands the pick a field-test event of that mode through the game's own debug
--     field (mDebugConfig.NextPreviewEvent / NextPlaneSprintEvent: a reflected struct of the run, honoured and cleared
--     by the shipping pick), loaded first (LoadAsset) together with its intro encounter (the event's
--     PreEventInteraction, MYST_SHK_* / MYST_TT_*: the pick preselects it as the run's mystery interaction).
--   * Knockout / championship: during the pick only, node.PlanetIndex / PlanetDayIndex point at the run tour's day
--     whose OverrideActivity is that type (its OverrideEvent loaded first); both are put back in the post-hook, so the
--     rest of the run (day rules, must-win, rewards) reads the real planet and day. Act I has no knockout day.
--   * Not reachable, logged and skipped: HOT LAP (no RaceEventDef of the game uses HotLapConfig: decoded events + asset
--     registry), MYSTERY RACES (no MysteryInteractionOutcome.ResultEvent outside the field-test / plane-sprint intros:
--     a mystery node is an encounter, the "mystery" step tests that stop), RIVAL CHALLENGES (only with an active
--     rivalry: the paddock's WBP_FE_Paddock_RivalChallenge calls CampaignRun:KickOffRivalChallengeEvent; "gauntlet
--     rival" makes that same call from the paddock).
-- Every step logs [gauntlet] lines: the step, the node, the activity written, the event asset, the planet (real name);
-- the race line (what the race really runs, from the recipe stage); the result line (the node's rewards).
-- State: <ModDir>/gauntlet.txt (the list and the next step; overwritten, never deleted) so a game restart resumes.
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "gauntlet"
local M = {}

local EVT = "/Game/Griffin/Gameplay/Events/"
local CHOOSE = "/Script/Griffin.CampaignSubsystem:ChooseNextMapNode"

---------------------------------------------------------------------------------------------------- data
-- planet asset names (PlanetDef PLA_<x>, CampaignPlanetSetup CAM_TourN_<x>) and track codes -> the names players see
M.PLANET = { Beagle = "Tatooine", Corgi = "Ando Prime", Dalmatian = "Lantaana", Husky = "Sentinel I", Mastiff = "Jakku",
             Spaniel = "Crait", Whippet = "Derven Acos" }
M.CODE = { BGL = "Beagle", COR = "Corgi", DAL = "Dalmatian", HSK = "Husky", HUS = "Husky", MAS = "Mastiff",
           SPA = "Spaniel", WHP = "Whippet" }
local CODE_OF = { Beagle = "BGL", Corgi = "COR", Dalmatian = "DAL", Husky = "HSK", Mastiff = "MAS", Spaniel = "SPA",
                  Whippet = "WHP" }

-- the steps. act = ECampaignMapNodeActivity written on the picked node; kind = couchrules' kind of that race;
-- mode = the field-test / plane-sprint event mode taken from M.EVENTS; race = false: a stop without a race
M.STEPS = {
    standard          = { act = 2, kind = "standard", label = "STANDARD RACE" },
    highrisk          = { act = 3, kind = "highrisk", label = "HIGH RISK (eliminator)" },
    ["ft-timetrial"]  = { act = 4, kind = "fieldtest", mode = "timetrial", label = "FIELD TEST: TIME TRIAL" },
    ["ft-hotlap"]     = { act = 4, kind = "fieldtest", mode = "hotlap", label = "FIELD TEST: HOT LAP",
                          absent = "no event of the game uses HotLapConfig (decoded events + asset registry): the "
                              .. "campaign has no hot-lap field test" },
    ["ft-takedowns"]  = { act = 4, kind = "fieldtest", mode = "takedowns", label = "FIELD TEST: TAKEDOWNS" },
    ["ft-ramjet"]     = { act = 4, kind = "fieldtest", mode = "ramjet", label = "FIELD TEST: RAMJET DISTANCE" },
    ["ft-precision"]  = { act = 4, kind = "fieldtest", mode = "precision", label = "FIELD TEST: PRECISION DRIVING" },
    planesprint       = { act = 10, kind = "planesprint", mode = "planesprint", label = "PODRACER TEST (plane sprint)" },
    mystery           = { act = 9, kind = "mystery", race = false, label = "MYSTERY ENCOUNTER (no race: no mystery "
                              .. "outcome of the game starts one)" },
    blackmarket       = { act = 7, race = false, label = "BLACK MARKET (shop stop)" },
    -- #65 (tester #3, Sentinel I node #24 StandardEvent->Repair): tooltip "<description missing>", no vendor in the
    -- paddock, the node never completed (unstuck by MarkCurrentMapNodeComplete). The map generator never makes a
    -- REPAIR node (decoded CAM_*MapGenRules: Repair is only listed in NoRepeatActivities, with no weight in any
    -- activity list): not a stop of this game. Skipped (logged) until a real repair stop is decoded.
    repair            = { act = 8, race = false, label = "REPAIR (scrap dealer stop)",
                          absent = "the map generator never makes a REPAIR node (CAM_*MapGenRules: no weight, only "
                              .. "NoRepeatActivities): a rewritten node has no description, no vendor and is never "
                              .. "completed (#65)" },
    rival             = { kind = "rival", watch = true, label = "RIVAL CHALLENGE" },
    knockout          = { act = 5, kind = "knockout", override = true, label = "KNOCKOUT" },
    champion          = { act = 6, kind = "champion", override = true, label = "CHAMPIONSHIP (boss)" },
}
-- the default order: the run-ending ones last (a championship WON on its node may end the act)
M.DEFAULT = { "standard", "highrisk", "ft-timetrial", "ft-hotlap", "ft-takedowns", "ft-ramjet", "ft-precision",
              "planesprint", "mystery", "blackmarket", "repair", "rival", "knockout", "champion" }

-- field-test and plane-sprint events {mode, planet code, event, intro} (paths under /Game/Griffin/Gameplay/Events/):
-- the first event of each mode and planet in the campaign's own pools (CAM_TourN_<PLANET>_PreviewEvents /
-- _PlaneSprintEvents), mode = the event's EventMode class (TimeTrialConfig / TakedownEventConfig /
-- RamjetDistanceConfig / PrecisionDrivingConfig), intro = its PreEventInteraction. Decoded 2026-10-18.
M.EVENTS = {
    { "timetrial", "COR", "Planets/Corgi/Loop_A/Shakedown/EVT_SHK_PRT_Skimmer_COR_A_FWD.EVT_SHK_PRT_Skimmer_COR_A_FWD", "Planets/Corgi/Loop_A/Shakedown/Narrative/MYST_SHK_PRT_Skimmer_COR_A_FWD.MYST_SHK_PRT_Skimmer_COR_A_FWD" },
    { "timetrial", "HSK", "Planets/Husky/P2P/Shakedown/EVT_SHK_PRT_Bike_HSK_P2P_FWD.EVT_SHK_PRT_Bike_HSK_P2P_FWD", "Planets/Husky/P2P/Shakedown/Narrative/MYST_SHK_PRT_Bike_HSK_P2P_FWD.MYST_SHK_PRT_Bike_HSK_P2P_FWD" },
    { "timetrial", "MAS", "Planets/Mastiff/LOOP_B/Shakedown/EVT_SHK_PRT_Skimmer_MAS_B_FWD.EVT_SHK_PRT_Skimmer_MAS_B_FWD", "Planets/Mastiff/Loop_B/Shakedown/Narrative/MYST_SHK_PRT_Skimmer_MAS_B_FWD.MYST_SHK_PRT_Skimmer_MAS_B_FWD" },
    { "timetrial", "SPA", "Planets/Spaniel/LOOP_B/Shakedown/EVT_SHK_PRT_Bike_SPA_B_SHORT_02.EVT_SHK_PRT_Bike_SPA_B_SHORT_02", "Planets/Spaniel/Loop_B/Shakedown/Narrative/MYST_SHK_PRT_Bike_SPA_B_SHORT_02.MYST_SHK_PRT_Bike_SPA_B_SHORT_02" },
    { "timetrial", "DAL", "Planets/Dalmatian/P2P/Shakedown/EVT_SHK_PRT_Skimmer_DAL_P2P_FWD.EVT_SHK_PRT_Skimmer_DAL_P2P_FWD", "Planets/Dalmatian/P2P/Shakedown/Narrative/MYST_SHK_PRT_Skimmer_DAL_P2P_FWD.MYST_SHK_PRT_Skimmer_DAL_P2P_FWD" },
    { "takedowns", "COR", "Planets/Corgi/P2P/Shakedown/EVT_SHK_BAT_Skimmer_COR_P2P_REV.EVT_SHK_BAT_Skimmer_COR_P2P_REV", "Planets/Corgi/P2P/Shakedown/Narrative/MYST_SHK_BAT_Skimmer_COR_P2P_REV.MYST_SHK_BAT_Skimmer_COR_P2P_REV" },
    { "takedowns", "HSK", "Planets/Husky/LOOP_B/Shakedown/EVT_SHK_BAT_Bike_HSK_B_REV.EVT_SHK_BAT_Bike_HSK_B_REV", "Planets/Husky/LOOP_B/Shakedown/Narrative/MYST_SHK_BAT_Bike_HSK_B_REV.MYST_SHK_BAT_Bike_HSK_B_REV" },
    { "takedowns", "MAS", "Planets/Mastiff/LOOP_B/Shakedown/EVT_SHK_BAT_Car_MAS_B_FWD.EVT_SHK_BAT_Car_MAS_B_FWD", "Planets/Mastiff/Loop_B/Shakedown/Narrative/MYST_SHK_BAT_Car_MAS_B_FWD.MYST_SHK_BAT_Car_MAS_B_FWD" },
    { "takedowns", "SPA", "Planets/Spaniel/LOOP_B/Shakedown/EVT_SHK_BAT_Car_SPA_B_FWD.EVT_SHK_BAT_Car_SPA_B_FWD", "Planets/Spaniel/Loop_B/Shakedown/Narrative/MYST_SHK_BAT_Car_SPA_B_FWD.MYST_SHK_BAT_Car_SPA_B_FWD" },
    { "takedowns", "DAL", "Planets/Dalmatian/Loop_A/Shakedown/EVT_SHK_BAT_Skimmer_DAL_A_SHORT_01.EVT_SHK_BAT_Skimmer_DAL_A_SHORT_01", "Planets/Dalmatian/Loop_A/Shakedown/Narrative/MYST_SHK_BAT_Skimmer_DAL_A_SHORT_01.MYST_SHK_BAT_Skimmer_DAL_A_SHORT_01" },
    { "ramjet", "COR", "Planets/Corgi/P2P/Shakedown/EVT_SHK_RAM_Bike_COR_P2P_FWD.EVT_SHK_RAM_Bike_COR_P2P_FWD", "Planets/Corgi/P2P/Shakedown/Narrative/MYST_SHK_RAM_Bike_COR_P2P_FWD.MYST_SHK_RAM_Bike_COR_P2P_FWD" },
    { "ramjet", "HSK", "Planets/Husky/P2P/Shakedown/EVT_SHK_RAM_Skimmer_HSK_P2P_FWD.EVT_SHK_RAM_Skimmer_HSK_P2P_FWD", "Planets/Husky/P2P/Shakedown/Narrative/MYST_SHK_RAM_Skimmer_HSK_P2P_FWD.MYST_SHK_RAM_Skimmer_HSK_P2P_FWD" },
    { "ramjet", "MAS", "Planets/Mastiff/Loop_A/Shakedown/EVT_SHK_RAM_Car_MAS_A_REV.EVT_SHK_RAM_Car_MAS_A_REV", "Planets/Mastiff/Loop_A/Shakedown/Narrative/MYST_SHK_RAM_Car_MAS_A_REV.MYST_SHK_RAM_Car_MAS_A_REV" },
    { "ramjet", "SPA", "Planets/Spaniel/Loop_A/Shakedown/EVT_SHK_RAM_Skimmer_SPA_A_REV.EVT_SHK_RAM_Skimmer_SPA_A_REV", "Planets/Spaniel/Loop_A/Shakedown/Narrative/MYST_SHK_RAM_Skimmer_SPA_A_REV.MYST_SHK_RAM_Skimmer_SPA_A_REV" },
    { "ramjet", "DAL", "Planets/Dalmatian/P2P/Shakedown/EVT_SHK_RAM_Car_DAL_P2P_FWD.EVT_SHK_RAM_Car_DAL_P2P_FWD", "Planets/Dalmatian/P2P/Shakedown/Narrative/MYST_SHK_RAM_Car_DAL_P2P_FWD.MYST_SHK_RAM_Car_DAL_P2P_FWD" },
    { "precision", "COR", "Planets/Corgi/LOOP_B/Shakedown/EVT_SHK_PRE_Skimmer_COR_B_FWD.EVT_SHK_PRE_Skimmer_COR_B_FWD", "Planets/Corgi/Loop_B/Shakedown/Narrative/MYST_SHK_PRE_Skimmer_COR_B_FWD.MYST_SHK_PRE_Skimmer_COR_B_FWD" },
    { "precision", "HSK", "Planets/Husky/LOOP_B/Shakedown/EVT_SHK_PRE_Car_HSK_B_FWD.EVT_SHK_PRE_Car_HSK_B_FWD", "Planets/Husky/LOOP_B/Shakedown/Narrative/MYST_SHK_PRE_Car_HSK_B_FWD.MYST_SHK_PRE_Car_HSK_B_FWD" },
    { "precision", "MAS", "Planets/Mastiff/LOOP_B/Shakedown/EVT_SHK_PRE_Skimmer_MAS_B_FWD.EVT_SHK_PRE_Skimmer_MAS_B_FWD", "Planets/Mastiff/Loop_B/Shakedown/Narrative/MYST_SHK_PRE_Skimmer_MAS_B_FWD.MYST_SHK_PRE_Skimmer_MAS_B_FWD" },
    { "precision", "DAL", "Planets/Dalmatian/Loop_A/Shakedown/EVT_SHK_PRE_Car_DAL_A_FWD.EVT_SHK_PRE_Car_DAL_A_FWD", "Planets/Dalmatian/Loop_A/Shakedown/Narrative/MYST_SHK_PRE_Car_DAL_A_FWD.MYST_SHK_PRE_Car_DAL_A_FWD" },
    { "precision", "SPA", "Planets/Spaniel/LOOP_B/Shakedown/EVT_SHK_PRE_Car_SPA_B_SHORT_02.EVT_SHK_PRE_Car_SPA_B_SHORT_02", "Planets/Spaniel/Loop_B/Shakedown/Narrative/MYST_SHK_PRE_Car_SPA_B_SHORT_02.MYST_SHK_PRE_Car_SPA_B_SHORT_02" },
    { "planesprint", "COR", "Plane_RaceTests/EVT_TT_COR_P2P_FWD_PLANE.EVT_TT_COR_P2P_FWD_PLANE", "Plane_RaceTests/MYST_TT_COR_P2P_FWD_PLANE.MYST_TT_COR_P2P_FWD_PLANE" },
    { "planesprint", "DAL", "Plane_RaceTests/EVT_TT_DAL_B_FWD_PLANE.EVT_TT_DAL_B_FWD_PLANE", "Plane_RaceTests/MYST_TT_DAL_B_FWD_PLANE.MYST_TT_DAL_B_FWD_PLANE" },
    { "planesprint", "HSK", "Plane_RaceTests/EVT_TT_HSK_B_FWD_PLANE.EVT_TT_HSK_B_FWD_PLANE", "Plane_RaceTests/MYST_TT_HSK_B_FWD_PLANE.MYST_TT_HSK_B_FWD_PLANE" },
    { "planesprint", "MAS", "Plane_RaceTests/EVT_TT_MAS_P2P_PLANE.EVT_TT_MAS_P2P_PLANE", "Plane_RaceTests/MYST_TT_MAS_PLANE.MYST_TT_MAS_PLANE" },
    { "planesprint", "SPA", "Plane_RaceTests/EVT_TT_SPA_A_PLANE.EVT_TT_SPA_A_PLANE", "Plane_RaceTests/MYST_TT_SPA_A_PLANE.MYST_TT_SPA_A_PLANE" },
}
-- the day-override events of each act (CampaignPlanetSetup.DaySetups[].OverrideEvent of the tour's last planet)
M.OVERRIDE = {
    CAM_Tour1 = { [6] = "Planets/Whippet/MIDBOSS/EVT_WHP_MID_BOSS.EVT_WHP_MID_BOSS" },
    CAM_Tour2 = { [5] = "Planets/Whippet/KNOCKOUT/EVT_WHP_LOOP_A_FWD_KNOCKOUT_TOUR2.EVT_WHP_LOOP_A_FWD_KNOCKOUT_TOUR2",
                  [6] = "Planets/Whippet/FINALBOSS/EVT_WHP_SHORTBOSS_FAIR.EVT_WHP_SHORTBOSS_FAIR" },
    CAM_Tour3 = { [5] = "Planets/Whippet/KNOCKOUT/EVT_WHP_LOOP_A_FWD_KNOCKOUT_TOUR3.EVT_WHP_LOOP_A_FWD_KNOCKOUT_TOUR3",
                  [6] = "Plane_PresentDay/EVT_WHP_PLANE_PDay.EVT_WHP_PLANE_PDay" },
}
local ACT_NAME = { [2] = "StandardEvent", [3] = "HighRiskEvent", [4] = "PreviewEvent", [5] = "KnockoutEvent",
                   [6] = "ChampionEvent", [7] = "BlackMarket", [8] = "Repair", [9] = "Mystery", [10] = "PlaneSprint",
                   [11] = "RivalRace", [12] = "RivalMystery" }
local MODE_NAME = { [1] = "TeamRace", [2] = "TimeTrial", [3] = "HotLap", [4] = "TimeEliminator", [5] = "KnockoutRace",
                    [6] = "Takedowns", [7] = "RamjetDistance", [8] = "PrecisionDriving" }
-- the race mode each step's race should run (ERaceEventModeType)
local WANT_MODE = { standard = 1, highrisk = 4, ["ft-timetrial"] = 2, ["ft-takedowns"] = 6, ["ft-ramjet"] = 7,
                    ["ft-precision"] = 8, planesprint = 2, knockout = 5, champion = 1 }
M.WANT_MODE = WANT_MODE

---------------------------------------------------------------------------------------------------- pure rules
local function short(path) return tostring(path or ""):match("%.([^%./]+)$") or tostring(path or "") end
M.short = short

-- "Mastiff" from "PLA_Mastiff" / "CAM_Tour2_Mastiff" / "CAM_Tour2_WhippetEnd" / "CAM_Tour1_Whippet_Mid", else nil
local function planetKey(s)
    local k = tostring(s or ""):match("^PLA_(%a+)") or tostring(s or ""):match("^CAM_Tour%d+_(%a+)")
    if not k then return nil end
    if M.PLANET[k] then return k end
    for p in pairs(M.PLANET) do if k:sub(1, #p) == p then return p end end
    return nil
end

-- "Jakku (Mastiff)" from a planet asset name, a track code or an event name ("EVT_SHK_BAT_Car_MAS_B_FWD")
function M.planetLabel(s)
    s = tostring(s or "")
    local key = planetKey(s)
    if not key then
        for code in s:gmatch("%u%u%u") do if M.CODE[code] then key = M.CODE[code]; break end end
    end
    if not key then for k in pairs(M.PLANET) do if s:find(k, 1, true) then key = k; break end end end
    if not key or not M.PLANET[key] then return s ~= "" and s or "?" end
    return string.format("%s (%s)", M.PLANET[key], key)
end

-- the event of a mode for this planet (its track code), else the first one of the mode; nil for a mode without one
function M.pickEvent(mode, code)
    local first = nil
    for _, e in ipairs(M.EVENTS) do
        if e[1] == mode then
            if e[2] == code then return { mode = e[1], code = e[2], event = EVT .. e[3], intro = EVT .. e[4] } end
            first = first or e
        end
    end
    if first then return { mode = first[1], code = first[2], event = EVT .. first[3], intro = EVT .. first[4] } end
    return nil
end

-- days = { {planet = 0-based index, day = 0-based index, act = OverrideActivity} } -> the first day of that activity
function M.overrideDay(days, act)
    for _, d in ipairs(days or {}) do
        if tonumber(d.act) == act then return d end
    end
    return nil
end

-- what one step does at a pick. ctx = {code = the planet's track code, tour = "CAM_TourN", days = M.overrideDay's
-- list, rivalry = bool, planetIndex = the node's PlanetIndex}. -> plan {act, field, event, intro, redirect = {planet,
-- day}, why}, plan.skip = reason (the step is passed) or plan.wait = reason (the step stays next, no node spent)
function M.plan(id, ctx)
    ctx = ctx or {}
    local s = M.STEPS[id]
    if not s then return { skip = "unknown step " .. tostring(id) } end
    if s.absent then return { skip = s.absent } end
    if s.watch then
        if ctx.rivalry then
            return { skip = "an active rivalry: accept the RIVAL CHALLENGE in the paddock (or \"gauntlet rival offer\" there); "
                .. "the gauntlet does not spend a node on it", watch = true }
        end
        return { skip = "no active rivalry in this run (the game starts one from an opponent's RivalScore): nothing to "
            .. "run", watch = true }
    end
    local p = { act = s.act }
    if s.mode then
        local e = M.pickEvent(s.mode, ctx.code)
        if not e then return { skip = "no " .. s.mode .. " event in the catalog" } end
        p.field = (s.act == 10) and "NextPlaneSprintEvent" or "NextPreviewEvent"
        p.event, p.intro = e.event, e.intro
        p.why = (e.code == ctx.code) and "this planet's" or ("from " .. M.planetLabel(e.code))
    elseif s.override then
        local d = M.overrideDay(ctx.days, s.act)
        local path = M.OVERRIDE[ctx.tour or ""] and M.OVERRIDE[ctx.tour][s.act]
        if not d then
            return { skip = string.format("%s has no day with OverrideActivity %s (Act I has no knockout)",
                tostring(ctx.tour or "this act"), ACT_NAME[s.act] or tostring(s.act)) }
        end
        -- AUTO-118: the redirect only moves the node to another DAY of its own planet; a node of another planet is
        -- never pointed at the override planet (the pick would build that planet's event from here): the step waits
        -- (no node spent, the pick is the game's) until the run is on the override day's planet
        if ctx.planetIndex ~= nil and tonumber(ctx.planetIndex) ~= d.planet then
            return { wait = string.format("its day override is on planet %d, the run's node is on planet %s: the step "
                .. "waits for that planet (never redirected across planets, AUTO-118)", d.planet,
                tostring(ctx.planetIndex)) }
        end
        p.redirect = { planet = d.planet, day = d.day }
        p.event = path and (EVT .. path) or nil
        p.why = string.format("the day override of planet %d day %d", d.planet, d.day)
    end
    return p
end

-- the list given to "gauntlet start": ids, "default" / nothing = M.DEFAULT; unknown ids -> nil, the bad id
function M.parseList(words)
    if not words or #words == 0 or (words[1] == "default" and #words == 1) then
        local t = {}
        for i, id in ipairs(M.DEFAULT) do t[i] = id end
        return t
    end
    local t = {}
    for _, w in ipairs(words) do
        for id in tostring(w):gmatch("[^,%s]+") do
            if not M.STEPS[id] then return nil, id end
            t[#t + 1] = id
        end
    end
    return t
end

---------------------------------------------------------------------------------------------------- state
local S = { on = false, list = {}, i = 1, n = 0, pending = nil, last = nil, raceLogged = nil }
local AR = { at = -1e12, sig = nil, toasted = nil, host = nil,   -- #82: the map arm (armTick)
             orig = {}, run = nil }                               -- AUTO-118: the written nodes' own values, per run
-- a new run: the old run's nodes are not put back (gone with it)
local function runSeen(run)
    local k = U.key(run)
    if AR.run ~= k then AR.run, AR.orig = k, {} end
end
M._S = S

local function statePath()
    local ok, d = pcall(function() return require("settings").modDir() end)
    if not ok or type(d) ~= "string" or d == "" then return nil end
    return d:gsub("\\", "/") .. "/gauntlet.txt"
end

local function save()
    local p = statePath()
    if not p then return end
    local f = io.open(p, "w")
    if not f then return end
    f:write(string.format("on=%s\nlist=%s\nnext=%d\n", tostring(S.on), table.concat(S.list, ","), S.i))
    f:close()
end

local function load()
    local p = statePath()
    local f = p and io.open(p, "r")
    if not f then return false end
    local s = f:read("a") or ""
    f:close()
    local list = M.parseList({ s:match("list=([^\n]*)") or "" })
    if not list or #list == 0 then return false end
    S.list, S.i, S.on = list, tonumber(s:match("next=(%d+)")) or 1, s:match("on=(%a+)") == "true"
    return true
end

---------------------------------------------------------------------------------------------------- game reads
local function unwrap(p)
    if p == nil then return nil end
    if type(p) == "userdata" and U.ok(p) then return p end
    local ok, v = pcall(function() return p:get() end)
    if ok and U.ok(v) then return v end
    return nil
end

local function campaignSub(ctxP)
    local c = unwrap(ctxP)
    if c then return c end
    local ok, f = pcall(FindFirstOf, "CampaignSubsystem")
    return (ok and U.ok(f)) and f or nil
end

local function activeRun(cs)
    local r = nil
    pcall(function() r = cs.ActiveRun end)
    return U.ok(r) and r or nil
end

local function num(o, k)
    local v = nil
    pcall(function() v = tonumber(o[k]) end)
    return v
end

local function bool(o, k)
    local v = nil
    pcall(function() v = o[k] == true end)
    return v
end

-- the node's planet asset name ("PLA_Mastiff"), else its setup's name
local function planetAsset(nd)
    local setup, def = nil, nil
    pcall(function() setup = nd.Planet end)
    if not U.ok(setup) then return "" end
    pcall(function() def = setup.Planet end)
    local n = U.objName(def)
    if n ~= "" then return n end
    return U.objName(setup)
end

local function codeOf(asset)
    local key = planetKey(asset)
    return key and CODE_OF[key] or nil
end

local function tourName(run)
    local t = nil
    pcall(function() t = run.Tour end)
    return U.objName(t)
end

-- every day setup of the run's tour with an OverrideActivity: { {planet, day, act} } (0-based indexes)
local function overrideDays(run)
    local out = {}
    pcall(function()
        local planets = run.Tour.Planets
        for i = 1, U.arrayCount(planets) do
            local pl = planets[i]
            if U.ok(pl) then
                local days = pl.DaySetups
                for d = 1, U.arrayCount(days) do
                    local a = tonumber(days[d].OverrideActivity)
                    if a and a > 0 then out[#out + 1] = { planet = i - 1, day = d - 1, act = a } end
                end
            end
        end
    end)
    return out
end

local function hasRivalry(run)
    local r = nil
    pcall(function() r = run.ActiveRivalry end)
    return U.ok(r)
end

-- the nodes the player can pick now (choosable, not chosen, not completed)
local function choosable(run)
    local out = {}
    pcall(function()
        local nodes = run.Map.mNodes
        for i = 1, U.arrayCount(nodes) do
            local nd = nodes[i]
            if U.ok(nd) and nd.bIsChoosable == true and nd.bHasBeenChosen ~= true and nd.bHasBeenCompleted ~= true then
                out[#out + 1] = { nd = nd, idx = i }
            end
        end
    end)
    return out
end

local function nodeIndex(run, node)
    local k, idx = U.key(node), nil
    pcall(function()
        local nodes = run.Map.mNodes
        for i = 1, U.arrayCount(nodes) do if U.key(nodes[i]) == k then idx = i; break end end
    end)
    return idx
end

---------------------------------------------------------------------------------------------------- AUTO-118
-- AUTO-118 (live round 1, 2026-10-18 12:53:51, Jakku -> Crait, Act II): after the mystery the only choosable node
-- was #24, the entry node of the NEXT planet (Crait). The #82 arm wrote BlackMarket on it and the pick kept it; the
-- couch planet check said "the picked node is on Crait (Spaniel) but the run is still on Jakku". The travel switches
-- on the node's Activity (0x1430d6534): a race node of the next planet travels there (the planet change appends
-- VisitedPlanets), a STOP opens in the current paddock - the Scrap Dealer opened in L_Mastiff_Paddock, the run never
-- changed planet, the map's next layer (Crait's) had no choosable node, NEXT PLANET / TravelToNextPlanet / CONTINUE
-- all landed in the same dead state (only REPLAY ACT II got out). Same family as #50 / #66: a node rewrite that
-- skips the planet change. RULES now: the gauntlet writes only a CHOOSABLE node of the run's CURRENT planet
-- (CampaignRun:GetCurrentPlanet() = VisitedPlanets.Last().Planet, the planet the paddock world comes from); a node of
-- another planet (or an unreadable planet) is left exactly as the game made it - an armed one is put back - and the
-- step waits for a pick on the run's planet. Every write remembers the node's own values; the pick is verified in
-- the post-hook (the chosen node is one the gauntlet wrote, on the run's planet): otherwise every write of that pick
-- is undone (before the travel, which runs after the hook) and the step is not spent. The knockout / championship
-- day redirect stays on the node's own planet (M.plan: wait).

-- the run's current planet (a PlanetDef), nil when unreadable
local function runPlanet(run)
    local p = nil
    pcall(function() p = run:GetCurrentPlanet() end)
    if U.ok(p) then return p end
    p = nil
    pcall(function()
        local vp = run.VisitedPlanets
        local n = U.arrayCount(vp)
        if n > 0 then p = vp[n].Planet end
    end)
    return U.ok(p) and p or nil
end

-- the node's planet (CampaignEventMapNode.Planet = its CampaignPlanetSetup; .Planet = the PlanetDef), nil when unreadable
local function nodePlanet(nd)
    local d = nil
    pcall(function() d = nd.Planet.Planet end)
    return U.ok(d) and d or nil
end

-- pure: may the gauntlet write this node? curKey / nodeKey = the planets' keys (nil = unreadable) -> ok, why
function M.writable(curKey, nodeKey)
    if curKey == nil then return false, "the run's current planet is unreadable" end
    if nodeKey == nil then return false, "the node's planet is unreadable" end
    if curKey ~= nodeKey then return false, "the node is on another planet than the run" end
    return true
end

-- -> fn(nd) = ok, why for the run's planet now
local function planetGate(run)
    local cur = runPlanet(run)
    local ck = cur and U.key(cur) or nil
    return function(nd)
        local d = nodePlanet(nd)
        return M.writable(ck, d and U.key(d) or nil)
    end, cur
end

local function planetName(def) return def and M.planetLabel(U.objName(def)) or "?" end

-- every node the gauntlet wrote, with its own values: AR.orig[key] = {nd, act, reward, pi, pd} (first write wins)
local function remember(nd)
    local k = U.key(nd)
    if k == nil or AR.orig[k] then return end
    AR.orig[k] = { nd = nd, act = num(nd, "Activity"), reward = num(nd, "Reward"), pi = num(nd, "PlanetIndex"),
                   pd = num(nd, "PlanetDayIndex") }
end
-- put a written node back as the game made it -> true when something was restored
local function restore(nd, why)
    local k = U.key(nd)
    local o = k and AR.orig[k]
    if not o then return false end
    AR.orig[k] = nil
    if not U.ok(o.nd) then return false end
    local was = num(o.nd, "Activity")
    pcall(function()
        if o.act ~= nil then o.nd.Activity = o.act end
        if o.reward ~= nil then o.nd.Reward = o.reward end
        if o.pi ~= nil then o.nd.PlanetIndex = o.pi end
        if o.pd ~= nil then o.nd.PlanetDayIndex = o.pd end
    end)
    U.log(TAG, "node %s put back: %s -> %s (%s)", U.objName(o.nd), ACT_NAME[was or -1] or tostring(was),
        ACT_NAME[o.act or -1] or tostring(o.act), tostring(why))
    return true
end
local function forget(nd) local k = U.key(nd); if k then AR.orig[k] = nil end end
local function restoreAll(why)
    local n = 0
    local list = {}
    for _, o in pairs(AR.orig) do list[#list + 1] = o.nd end
    for _, nd in ipairs(list) do if restore(nd, why) then n = n + 1 end end
    return n
end
M._orig = function() return AR.orig end

-- AUTO-128 (live round 2, 13:46:14-21): a node ARMED ChampionEvent by the champion step stayed act 6 after "gauntlet
-- start mystery champion"; the new list's arm and pick then took it for the planet's real CHAMPIONSHIP ("2
-- championship node(s) left alone", "node #12 is the planet's CHAMPIONSHIP: not rewritten") and the pick went to the
-- game as a ChampionEvent with no day override loaded: no event, a dead state. The championship rule now reads the
-- node's OWN activity (the value the gauntlet remembered before its first write), never one the gauntlet wrote; and a
-- new list puts every armed node back first (M.start).
local function ownAct(nd)
    local k = U.key(nd)
    local o = k and AR.orig[k]
    if o and o.act ~= nil then return o.act end
    return num(nd, "Activity")
end
M._ownAct = ownAct

-- the active recipe's current stage: {key, event, mode, gmv, track} (nil fields when absent)
local function recipeStage()
    local out = {}
    pcall(function()
        local rs = U.giSubsystem("EventRecipeSubsystem")
        if not U.ok(rs) then return end
        local inst = rs.ActiveRecipe
        if not U.ok(inst) then return end
        out.key = U.key(inst)
        local stages = inst.Recipe.EventStages
        local n = U.arrayCount(stages)
        local idx = (tonumber(inst.RecipeState.ActiveStage) or 0) + 1
        if idx < 1 or idx > n then return end
        local st = stages[idx]
        out.event = U.objName(st.AuthoredEvent)
        if out.event == "" then out.event = U.str(st.InternalName) end
        out.mode = tonumber(st.RaceEventModeType)
        out.gmv = U.objName(st.GameModeVariant)
        out.track = U.objName(st.TrackDef)
        out.stamp = string.format("%s|%s|%s", tostring(out.event), tostring(out.mode), tostring(out.track))
    end)
    return out
end

local function nodeReport(nd)
    if not U.ok(nd) then return "node gone" end
    local rounds = 0
    pcall(function() rounds = U.arrayCount(nd.RewardRounds) end)
    return string.format("completed %s, earned rewards %s, reward rounds %d (at %s), finish credits %s, tuning %s, kit %s",
        tostring(bool(nd, "bHasBeenCompleted")), tostring(bool(nd, "bEarnedRewards")), rounds,
        tostring(num(nd, "RewardRoundIx")), tostring(num(nd, "FinishCreditsAwarded")),
        tostring(num(nd, "FinishTuningPointsAwarded")), tostring(num(nd, "FinishKitPointsAwarded")))
end

---------------------------------------------------------------------------------------------------- the pick
local function stepLabel(i)
    local id = S.list[i]
    return string.format("step %d/%d %s", i, #S.list, tostring(id))
end

-- the previous step's node, read at the next pick (its race and reward rounds are over by then)
local function reportLast(run, why)
    local l = S.last
    if not l or l.reported then return end
    local credits = num(run, "Credits")
    U.log(TAG, "%s RESULT (%s): %s; run credits %s -> %s, strikes %s", l.label, why, nodeReport(l.nd),
        tostring(l.credits), tostring(credits), tostring(num(run, "Strikes")))
    if why == "next pick" then l.reported = true end
end

local function writeNode(nd, plan, race)
    remember(nd)
    local o = { nd = nd, act = num(nd, "Activity"), reward = num(nd, "Reward"), pi = num(nd, "PlanetIndex"),
                pd = num(nd, "PlanetDayIndex") }
    pcall(function() nd.Activity = plan.act end)
    o.okAct = num(nd, "Activity") == plan.act
    -- a race node shows (and rewards) a reward kind: a former stop node without one gets UpgradePart (1)
    if race and (o.reward or 0) == 0 then pcall(function() nd.Reward = 1 end) end
    if plan.redirect then
        pcall(function()
            nd.PlanetIndex = plan.redirect.planet
            nd.PlanetDayIndex = plan.redirect.day
        end)
        o.okRedirect = num(nd, "PlanetIndex") == plan.redirect.planet and num(nd, "PlanetDayIndex") == plan.redirect.day
    end
    return o
end

local function pre(ctxP, nodeP)
    if not S.on then return end
    local cs = campaignSub(ctxP)
    local run = cs and activeRun(cs)
    if not run then return end
    reportLast(run, "next pick")
    S.pending = nil
    runSeen(run)
    local picked = unwrap(nodeP)
    local nodes = choosable(run)
    local gate, cur = planetGate(run)
    -- AUTO-118: the picked node must be one the player can pick now AND on the run's own planet; else it goes to the
    -- native pick exactly as the game made it (an armed one put back first) and the step waits
    if picked then
        local pk, inSet = U.key(picked), false
        for _, t in ipairs(nodes) do if U.key(t.nd) == pk then inSet = true; break end end
        local okP, why = gate(picked)
        if not inSet then okP, why = false, "the node is not in the run's choosable set" end
        if not okP then
            local back = restore(picked, "AUTO-118: not a node the gauntlet may write")
            U.warn(TAG, "%s: node #%s on %s, the run on %s: NOT rewritten (%s)%s; this pick is left to the game, the "
                .. "step waits for a node of the run's planet (AUTO-118)", stepLabel(S.i), tostring(nodeIndex(run, picked)),
                planetName(nodePlanet(picked)), planetName(cur), tostring(why),
                back and ", its armed type put back" or "")
            save()
            return
        end
    end
    local code = codeOf(picked and planetAsset(picked) or "")
    if not code then
        local c = nodes[1]
        code = c and codeOf(planetAsset(c.nd)) or nil
    end
    local first = picked or (nodes[1] and nodes[1].nd)
    local ctx = { code = code, tour = tourName(run), days = overrideDays(run), rivalry = hasRivalry(run),
                  planetIndex = first and num(first, "PlanetIndex") or nil }
    -- the next step that spends a node; the ones that cannot are logged and passed, a waiting one leaves the pick
    local id, plan, idx = nil, nil, nil
    while S.i <= #S.list do
        local p = M.plan(S.list[S.i], ctx)
        if p.wait then
            U.log(TAG, "%s %s WAITS: %s; this pick is left to the game", stepLabel(S.i),
                (M.STEPS[S.list[S.i]] or {}).label or "?", p.wait)
            -- nothing the gauntlet wrote stays on the map while it waits
            local n = restoreAll("the step waits")
            if n > 0 then U.log(TAG, "%d written node(s) put back (the step waits)", n) end
            save()
            return
        end
        if not p.skip then id, plan, idx = S.list[S.i], p, S.i; break end
        U.log(TAG, "%s %s SKIPPED: %s", stepLabel(S.i), (M.STEPS[S.list[S.i]] or {}).label or "?", p.skip)
        S.i = S.i + 1
    end
    if not plan then
        if not S.doneLogged then
            U.log(TAG, "list done (%d step(s)): this pick is left to the game; \"gauntlet start\" runs it again", #S.list)
            S.doneLogged = true
        end
        save()
        return
    end
    local step = M.STEPS[id]
    local race = step.race ~= false
    -- the nodes to write: the picked one (the hook's parameter), else every node the player can pick now
    -- #50 (overnight 2026-10-18, tester #2): node #47 ChampionEvent->BlackMarket on Derven Acos. The CHAMPIONSHIP node
    -- is the planet's last: only its race result runs the end-of-planet flow (post-race CSM_RF_Results_Campaign_
    -- EndOfPlanet -> NEXT PLANET -> TravelToNextPlanet). Rewritten into a stop, the planet ended with no championship
    -- result: the paddock map showed Sentinel I with no screen activated, A / OnAccept / TravelToNextPlanet() did
    -- nothing, and the run could only be left through the pause menu. A championship node is never rewritten into
    -- another type: that pick is left to the game, the step waits for the next pick.
    local targets = {}
    local function isChampion(nd) return ownAct(nd) == 6 end    -- AUTO-128: the game's own type, not an armed one
    if picked then
        if isChampion(picked) and step.act ~= 6 then
            U.log(TAG, "%s: node #%s is the planet's CHAMPIONSHIP (its result ends the planet): not rewritten, this pick "
                .. "is left to the game; the step waits for the next pick", stepLabel(idx), tostring(nodeIndex(run, picked)))
            return
        end
        targets[1] = { nd = picked, idx = nodeIndex(run, picked) }
    else
        -- AUTO-118: only the choosable nodes of the run's planet (an armed node of another planet is put back)
        local off = 0
        for _, t in ipairs(nodes) do
            if not gate(t.nd) then
                off = off + 1
                restore(t.nd, "AUTO-118: another planet's node")
            elseif not (isChampion(t.nd) and step.act ~= 6) then
                targets[#targets + 1] = t
            end
        end
        if off > 0 then
            U.log(TAG, "%s: %d choosable node(s) not on the run's planet (%s) left to the game (AUTO-118)", stepLabel(idx),
                off, planetName(cur))
        end
    end
    if #targets == 0 then
        U.warn(TAG, "%s: no node to write (no parameter, no choosable node of the run's planet): this pick is left to "
            .. "the game", stepLabel(idx))
        return
    end
    -- the events this pick needs, loaded now (soft pointers resolve only when loaded; the pick runs right after)
    local def, intro, ovr = nil, nil, nil
    if plan.field then
        def = U.obj(plan.event)
        intro = U.obj(plan.intro)
        if not U.ok(def) then
            U.warn(TAG, "%s: %s not loadable: the planet's own random %s is picked", stepLabel(idx), short(plan.event),
                step.act == 10 and "plane sprint" or "field test")
        else
            local okW = pcall(function() run.mDebugConfig[plan.field] = def end)
            local back = nil
            pcall(function() back = run.mDebugConfig[plan.field] end)
            if not (okW and U.ok(back) and U.key(back) == U.key(def)) then
                U.warn(TAG, "%s: run.mDebugConfig.%s not written (read back %s): the planet's own random event is picked",
                    stepLabel(idx), plan.field, U.objName(back))
                def = nil
            end
        end
    elseif plan.redirect and plan.event then
        ovr = U.obj(plan.event)
        if not U.ok(ovr) then
            U.warn(TAG, "%s: %s not loadable: the pick finds no event (no race on this node)", stepLabel(idx),
                short(plan.event))
        end
    end
    local written = {}
    for _, t in ipairs(targets) do
        local o = writeNode(t.nd, plan, race)
        o.idx = t.idx
        written[#written + 1] = o
    end
    local w1 = written[1]
    local planet = M.planetLabel(planetAsset(w1.nd))
    local evText
    if plan.field then
        evText = def and string.format("%s (%s, through run.mDebugConfig.%s; intro %s%s)", short(plan.event),
            plan.why, plan.field, short(plan.intro), U.ok(intro) and "" or " NOT LOADED") or "the planet's random pool event"
    elseif plan.redirect then
        evText = string.format("%s (%s%s)", short(plan.event or "?"), plan.why, U.ok(ovr) and "" or ", NOT LOADED")
    elseif race then
        evText = "rolled by the planet's EventPicker (the race line names it)"
    else
        evText = "no event (a stop)"
    end
    -- "#3 (picked) Mystery->StandardEvent" / "#3,#4,#5 +2 (5 choosable) StandardEvent,Mystery->HighRiskEvent"
    local idxs, froms, seenFrom, failed = {}, {}, {}, 0
    for k, o in ipairs(written) do
        if k <= 6 then idxs[#idxs + 1] = "#" .. tostring(o.idx) end
        local f = ACT_NAME[o.act or -1] or tostring(o.act)
        if not seenFrom[f] then seenFrom[f] = true; froms[#froms + 1] = f end
        if not o.okAct then failed = failed + 1 end
    end
    local nodesText = string.format("%s%s (%s) %s->%s%s", table.concat(idxs, ","),
        #written > 6 and (" +" .. (#written - 6)) or "", picked and "picked" or (#written .. " choosable"),
        table.concat(froms, ","), ACT_NAME[plan.act], failed > 0 and string.format(" (%d WRITE(S) FAILED)", failed) or "")
    U.log(TAG, "%s %s: node %s; event %s; planet %s; act %s", stepLabel(idx), step.label, nodesText, evText, planet,
        tostring(ctx.tour))
    if step.act == 6 then
        U.log(TAG, "%s: a championship WON may end the act (the act-finish branch, couchrules N4: not verified for a "
            .. "championship on another day)", stepLabel(idx))
    end
    S.pending = { id = id, idx = idx, plan = plan, written = written, def = def, recipe0 = recipeStage().stamp,
                  credits = num(run, "Credits"), planet = planet }
    S.i = idx + 1
    save()
end

local function post(ctxP)
    local P = S.pending
    if not P then return end
    S.pending = nil
    local cs = campaignSub(ctxP)
    local run = cs and activeRun(cs)
    -- the planet / day redirect lasts the pick only
    for _, o in ipairs(P.written) do
        if P.plan.redirect and U.ok(o.nd) then
            pcall(function()
                o.nd.PlanetIndex = o.pi
                o.nd.PlanetDayIndex = o.pd
            end)
        end
    end
    local notes = {}
    if P.plan.redirect then notes[#notes + 1] = "planet/day indexes put back" end
    if run and P.plan.field and P.def then
        local left = nil
        pcall(function() left = run.mDebugConfig[P.plan.field] end)
        if U.ok(left) then
            notes[#notes + 1] = "the debug event was NOT consumed by the pick (cleared now)"
            pcall(function() run.mDebugConfig[P.plan.field] = nil end)
        else
            notes[#notes + 1] = "debug event consumed by the pick"
        end
    end
    local chosen = nil
    if run then pcall(function() chosen = run:GetChosenNextNode() end) end
    -- AUTO-118: verify the pick before the travel (it switches on the chosen node's Activity after this hook): the
    -- chosen node is one this pick wrote, on the run's planet. Else every write of this pick is undone and the step
    -- is not spent (the game's own node, the game's own travel).
    local bad = nil
    if not U.ok(chosen) then
        U.warn(TAG, "%s: GetChosenNextNode unreadable after the pick: not verified", stepLabel(P.idx))
    else
        local hit = false
        for _, o in ipairs(P.written) do if U.key(o.nd) == U.key(chosen) then hit = true; break end end
        local okP, why = true, nil
        if run then okP, why = (planetGate(run))(chosen) end
        if not hit then bad = "the game chose a node this pick did not write"
        elseif not okP then bad = "the chosen node failed the planet check after the pick: " .. tostring(why) end
    end
    if bad then
        local n = 0
        for _, o in ipairs(P.written) do if restore(o.nd, "pick verify failed") then n = n + 1 end end
        S.i = P.idx
        save()
        U.warn(TAG, "%s pick NOT verified (%s): %d write(s) undone, the step stays next (AUTO-118)", stepLabel(P.idx),
            bad, n)
        AR.sig, AR.at = nil, -1e12
        return
    end
    if U.ok(chosen) then forget(chosen) end              -- spent on it: its type is the game's from now on
    -- the other nodes this pick wrote (no hook parameter: every choosable one) get their own type back; the map arm
    -- (armTick) writes the next step on the choosable ones again
    if U.ok(chosen) then
        for _, o in ipairs(P.written) do
            if U.key(o.nd) ~= U.key(chosen) then restore(o.nd, "not the chosen node") end
        end
    end
    local act = U.ok(chosen) and num(chosen, "Activity") or nil
    local st = recipeStage()
    local built = (st.stamp and st.stamp ~= P.recipe0) and string.format("recipe %s, mode %s, %s, track %s",
        tostring(st.event), MODE_NAME[st.mode or -1] or tostring(st.mode), tostring(st.gmv), tostring(st.track))
        or "no new recipe at the pick (a stop, or a test started from its intro encounter in the paddock)"
    U.log(TAG, "%s picked: chosen node activity %s; %s; %s", stepLabel(P.idx), ACT_NAME[act or -1] or tostring(act),
        built, table.concat(notes, "; "))
    S.last = { id = P.id, idx = P.idx, nd = chosen or (P.written[1] and P.written[1].nd), credits = P.credits,
               label = stepLabel(P.idx), planet = P.planet, stop = (M.STEPS[P.id] or {}).race == false }
    AR.sig, AR.at = nil, -1e12                          -- #82: the next map arms the next step at once
    S.raceLogged = nil
end

---------------------------------------------------------------------------------------------------- race / result lines
local function onPhase(new, old)
    if not S.on or not S.last then return end
    if new == "RACING" and S.raceLogged ~= St.worldGen then
        S.raceLogged = St.worldGen
        local st = recipeStage()
        local kind, modeType = nil, nil
        pcall(function()
            local i = U.mod("couchsolo").info()
            kind, modeType = i.kind, i.modeType
        end)
        local mode = modeType or st.mode
        local want = WANT_MODE[S.last.id]
        local rival = false
        pcall(function()
            local cs = campaignSub(nil)
            local run = cs and activeRun(cs)
            rival = run ~= nil and run.bIsPlayingRivalChallengeEvent == true
        end)
        U.log(TAG, "%s RACE: %s, mode %s%s, %s, track %s, planet %s%s", S.last.label, tostring(st.event),
            MODE_NAME[mode or -1] or tostring(mode), kind and (" (" .. tostring(kind) .. ")") or "", tostring(st.gmv),
            tostring(st.track), tostring(S.last.planet),
            rival and "; a RIVAL CHALLENGE race" or (want and (want == mode and "; the type asked: OK"
                or string.format("; MISMATCH: %s asked", MODE_NAME[want] or tostring(want))) or ""))
    elseif old == "POSTRACE" and S.raceLogged then
        -- only once this step raced (overnight 2026-10-18: a pick made on the POST-RACE map left POSTRACE right
        -- after the pick and logged "RESULT (after the race)" for the step that had not raced yet)
        local cs = campaignSub(nil)
        local run = cs and activeRun(cs)
        if run then reportLast(run, "after the race") end
    end
end

---------------------------------------------------------------------------------------------------- commands
function M.status()
    if #S.list == 0 then return "gauntlet: not started (\"gauntlet start\")" end
    local parts = {}
    for i, id in ipairs(S.list) do parts[#parts + 1] = (i == S.i and ">" or "") .. id end
    return string.format("gauntlet %s: next %d/%d (%s); list %s; last %s", S.on and "ON" or "off", S.i, #S.list,
        tostring(S.list[S.i] or "done"), table.concat(parts, " "), S.last and S.last.label or "-")
end

function M.start(list, why)
    -- AUTO-128: the old list's armed nodes get their own type back before the new list arms anything
    local n = restoreAll("a new list (gauntlet start)")
    if n > 0 then U.log(TAG, "%d armed node(s) of the previous list put back (AUTO-128)", n) end
    AR.sig, AR.at = nil, -1e12
    S.list, S.i, S.on, S.last, S.doneLogged = list, 1, true, nil, nil
    save()
    U.log(TAG, "started (%s): %d step(s): %s. Every node pick on the run map / paddock takes the next one", tostring(why),
        #list, table.concat(list, " "))
end

-- #82 (playtest 2026-10-18, Jules): the run map's node icons / tooltips showed a NORMAL race until the pick rewrote the
-- node, so the gauntlet looked broken. The next step's activity is ARMED on the choosable nodes as soon as they exist
-- (armTick, MAIN tick in POSTRACE / the paddock: before / while the run map shows, and again after each step), with
-- the pick's own rules (the next step that spends a node; a planet's CHAMPIONSHIP node is never rewritten; a race node
-- without a reward kind gets UpgradePart). The pick (pre) still writes the picked node. P1 gets a toast
-- "GAUNTLET: next = <label>" once per map / step while a run map screen is up.
local MAP_SCREENS = { "RunMapOverview", "RunMap_Presentation", "Paddock_NextEvent" }
local ARM_PHASES = { POSTRACE = true, OTHER = true }
local ARM_MS = 500

-- the next step that spends a node, without advancing (pre's own skip rule) -> id, plan, index
local function nextStep(run, nodes)
    local code = nil
    local c = nodes and nodes[1]
    if c then code = codeOf(planetAsset(c.nd)) end
    local ctx = { code = code, tour = tourName(run), days = overrideDays(run), rivalry = hasRivalry(run),
                  planetIndex = c and num(c.nd, "PlanetIndex") or nil }
    for i = S.i, #S.list do
        local p = M.plan(S.list[i], ctx)
        if p.wait then return nil, p.wait end
        if not p.skip then return S.list[i], p, i end
    end
    return nil
end

-- pure: the nodes to arm for activity act -> list of {nd, write = bool, reward = bool}; champ(nd) = the node is the
-- planet's championship (never rewritten into another type), actOf(nd) / rewardOf(nd) = its current values;
-- onPlanet(nd) (optional, AUTO-118) = the node is on the run's current planet (else never armed); champOf(nd)
-- (optional, AUTO-128) = the node is the planet's own championship (default: its current activity is 6)
function M.armPlan(nodes, act, race, actOf, rewardOf, onPlanet, champOf)
    local out = {}
    for _, t in ipairs(nodes or {}) do
        local a = actOf(t.nd)
        local champ = (champOf ~= nil) and champOf(t.nd) or (champOf == nil and a == 6)
        if not (champ and act ~= 6) and (onPlanet == nil or onPlanet(t.nd)) then
            out[#out + 1] = { nd = t.nd, idx = t.idx, write = a ~= act, reward = race and (rewardOf(t.nd) or 0) == 0 }
        end
    end
    return out
end

local function closeToast()
    local h = AR.host
    AR.host = nil
    if h and U.alive(h) then pcall(function() h:RemoveFromParent() end) end
end
local function toast(text)
    closeToast()
    U.log(TAG, "toast to P1: %s (#82)", text)
    pcall(function()
        local CP = U.mod("couchpanel")
        local kit = CP.kit
        local H = CP.newHost()
        pcall(function() H.host:SetVisibility(kit.VIS.HitTestInvisible) end)
        local bandW, bandH, y = 1500, 130, 220
        local x = math.floor((kit.VW - bandW) / 2)
        kit.place(H.cv, kit.solid(H.tree, kit.colours.DEEP), x, y, bandW, bandH, 1)
        kit.place(H.cv, kit.solid(H.tree, kit.colours.AMBER), x, y + bandH - 8, bandW, 8, 2)
        local t = kit.text(H.tree, 52, kit.colours.AMBER)
        kit.setText(t, text)
        local sl = kit.place(H.cv, t, math.floor(kit.VW / 2), y + 32, nil, nil, 3)
        pcall(function() sl:SetAlignment({ X = 0.5, Y = 0 }) end)
        H.host:AddToViewport((tonumber(cfg.CouchPanelZ) or 1000) + 25)
        AR.host = H.host
        local host = H.host
        U.mod("sched").after("gauntlet.toast", 3500, function() if AR.host == host then closeToast() end end)
    end)
end

local function mapShown()
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return false end
    for _, e in ipairs(list) do
        for _, pat in ipairs(MAP_SCREENS) do
            if tostring(e.cls):find(pat, 1, true) then return true end
        end
    end
    return false
end

-- -> text (the command's answer), armed node count
-- AUTO-118: the armed nodes that left the choosable set: put back unless the game chose / completed them (a node the
-- gauntlet's pick spent was forgotten in the post-hook; a sibling of the chosen node gets its own type back)
local function pruneArms(nodes)
    local live = {}
    for _, t in ipairs(nodes) do live[U.key(t.nd)] = true end
    local stale = {}
    for k, o in pairs(AR.orig) do
        if not live[k] then stale[#stale + 1] = o end
    end
    for _, o in ipairs(stale) do
        if U.ok(o.nd) and bool(o.nd, "bHasBeenChosen") ~= true and bool(o.nd, "bHasBeenCompleted") ~= true then
            restore(o.nd, "no longer choosable")
        else
            forget(o.nd)
        end
    end
end

local function armNow(run, why)
    runSeen(run)
    local nodes = choosable(run)
    pruneArms(nodes)
    if #nodes == 0 then return "no choosable node", 0 end
    local id, plan, idx = nextStep(run, nodes)
    if not id then
        -- list done or the next step waits: every armed node gets the game's own type back
        local n = restoreAll(plan or "list done")
        if n > 0 then U.log(TAG, "%d armed node(s) put back (%s)", n, tostring(plan or "list done")) end
        return plan and ("next step waits: " .. plan) or "list done: nothing to arm", 0
    end
    local s = M.STEPS[id]
    local race = s.race ~= false
    -- AUTO-118: only the run's planet; an armed node of another planet is put back
    local gate, cur = planetGate(run)
    local off = 0
    local list = M.armPlan(nodes, plan.act, race, function(nd) return num(nd, "Activity") end,
        function(nd) return num(nd, "Reward") end, function(nd)
            if gate(nd) then return true end
            off = off + 1
            restore(nd, "AUTO-118: another planet's node")
            return false
        end, function(nd) return ownAct(nd) == 6 end)
    local wrote, idxs = 0, {}
    for _, a in ipairs(list) do
        if a.write or a.reward then remember(a.nd) end
        if a.write then
            pcall(function() a.nd.Activity = plan.act end)
            wrote = wrote + 1
        end
        if a.reward then pcall(function() a.nd.Reward = 1 end) end
        idxs[#idxs + 1] = "#" .. tostring(a.idx)
    end
    local sig = string.format("%d:%s:%d", idx, table.concat(idxs, ","), off)
    if #list == 0 then
        if sig ~= AR.sig then
            U.log(TAG, "%s %s: nothing armed (%s): %d choosable node(s), %d not on the run's planet %s (AUTO-118)",
                stepLabel(idx), s.label, tostring(why), #nodes, off, planetName(cur))
        end
        AR.sig = sig
        return string.format("no choosable node of the run's planet (%d elsewhere)", off), 0
    end
    if wrote > 0 or sig ~= AR.sig then
        U.log(TAG, "%s %s ARMED on the map (%s): %d choosable node(s) %s -> %s, %d rewritten%s%s (#82)", stepLabel(idx),
            s.label, tostring(why), #list, table.concat(idxs, ","), ACT_NAME[plan.act] or tostring(plan.act), wrote,
            (#list + off < #nodes) and string.format(", %d championship node(s) left alone", #nodes - #list - off) or "",
            off > 0 and string.format(", %d node(s) not on the run's planet %s left alone (AUTO-118)", off,
                planetName(cur)) or "")
    end
    AR.sig = sig
    return string.format("%d choosable node(s) now %s (the pick writes them again)", #list, ACT_NAME[plan.act]), #list, s
end

-- AUTO-128 backstop: a STOP the gauntlet wrote (black market / mystery on a former race node) whose node the game never
-- completed leaves the run with nothing to pick (the Scrap Dealer case is fixed at its leave: couchpanel.
-- stopNodeComplete). Once that stop's screen was seen and is gone, the map is up, the stop's node is the run's current
-- node, still not completed, and no node is choosable for STUCK_MS: the game's own MarkCurrentMapNodeComplete (the
-- step the stop's screen should have made), logged as a WARN. Never before the stop was visited.
local STOP_SCREENS = { "ExoticVendor", "Mystery" }
local STUCK_MS = 3000
-- pure: l = S.last, f = {completed, current, choosable, map, stopUp} -> "done" | "visit" | "wait" | "complete" | nil
function M.stopStep(l, f, now)
    if not (l and l.stop) or l.unstuck then return nil end
    if f.completed then return "done" end
    if f.stopUp then l.visited = true; l.stuckAt = nil; return "visit" end
    if not l.visited or not f.current or f.choosable > 0 or not f.map then l.stuckAt = nil; return "wait" end
    l.stuckAt = l.stuckAt or now
    if now - l.stuckAt < STUCK_MS then return "wait" end
    return "complete"
end
local function stopScreenUp()
    local okA, list = pcall(function() return U.mod("couch").activeScreens() end)
    if not okA or type(list) ~= "table" then return false end
    for _, e in ipairs(list) do
        for _, pat in ipairs(STOP_SCREENS) do
            if tostring(e.cls):find(pat, 1, true) then return true end
        end
    end
    return false
end
local function stopWatch(cs, run, now)
    local l = S.last
    if not (l and l.stop) or l.unstuck or not U.ok(l.nd) then return end
    local cur = nil
    pcall(function() cur = run:GetCurrentNode() end)
    local f = { completed = bool(l.nd, "bHasBeenCompleted") == true, current = U.ok(cur) and U.key(cur) == U.key(l.nd),
                choosable = #choosable(run), map = mapShown(), stopUp = stopScreenUp() }
    local step = M.stopStep(l, f, now)
    if step == "done" then l.unstuck = true; return end
    if step ~= "complete" then return end
    l.unstuck = true
    local ok = pcall(function() cs:MarkCurrentMapNodeComplete() end)
    U.warn(TAG, "%s: the stop's node was never completed (0 choosable nodes %d s after its screen closed): "
        .. "MarkCurrentMapNodeComplete %s, completed %s, %d choosable now (AUTO-128)", tostring(l.label),
        math.floor(STUCK_MS / 1000), ok and "called" or "FAILED", tostring(bool(l.nd, "bHasBeenCompleted")),
        #choosable(run))
    AR.sig, AR.at = nil, -1e12
end

function M.armTick(now)
    if not S.on or not ARM_PHASES[St.phase] then return end
    now = now or St.nowMs()
    if now - AR.at < ARM_MS then return end
    AR.at = now
    local cs = campaignSub(nil)
    local run = cs and activeRun(cs)
    if not run then return end
    U.try(TAG, stopWatch, cs, run, now)
    local _, n, s = armNow(run, "tick")
    if n == 0 or not s then return end
    if AR.toasted ~= AR.sig and mapShown() then
        AR.toasted = AR.sig
        if cfg.GauntletToast ~= false then toast("GAUNTLET: next = " .. s.label) end
    end
end

-- "gauntlet arm": the same, now
local function arm()
    local cs = campaignSub(nil)
    local run = cs and activeRun(cs)
    if not run then return "no active run" end
    return (armNow(run, "command"))
end

-- couch-fix60 (AUTO-147, live round 5: with every RivalScore at 6.0 the game started rivalries but never offered the
-- challenge). HOW THE GAME OFFERS IT (static, hf2 exe; offsets from the JMAP):
--   * the paddock's ARivalConversationSpawner (on the paddock map) spawns the rival NPC at its InteractionPoint while
--     WantsToBeActive() (exec 0x14710633c -> 0x147106362): its own unreflected "used" byte (+0x300) clear, the run's
--     bNeedsToPlayRivalIntro (+0x340) FALSE, and the run's offer check 0x1430dce44:
--       ActiveRivalry (+0x2f0) set; not vetoed by 0x1471e9bd2 (BuildAPlane feature on and the current planet's
--       podracer test not played yet = no offer before it); the current CampaignDayId inside the rivalry's
--       [CanInviteFrom (+0x88), MustInviteBy (+0x90)] (all 11 rivalries: planet 1 day 1 .. planet 5 day 4); the rival's
--       CampaignRunRacer found (0x1471edf7c: ActiveRivalry.racer RESOLVED - the RacerDef in memory - then the
--       OpponentRacers / NarrativeOpponentRacers entry with that Pilot); its RivalScore (+0xd8) >=
--       CampaignDef.RivalryConfig.RivalScoreThresholdToInitiateRivalChallenge (+0x48, 5.0).
--   * talking to that NPC on foot = CSM_Paddock_RivalConversation_Challenge -> WBP_FE_Paddock_RivalChallenge (it
--     LoadAsset_Blocking()s ActiveRivalry.racer, GO RACING = CampaignRun:KickOffRivalChallengeEvent, NOT NOW =
--     DeclineRivalChallengeEvent). bNeedsToPlayRivalIntro is the rivalry's INTRO first (NPCActor
--     bIsRivalryInterruption from the ARivalryInterruptionSpawner, CSM_Paddock_RivalryInterruptBeforeEventChoice:
--     the Rivalry_Intro sequence, then EventSelect). Both live only in the on-foot paddock: the fast map-pick flow
--     (race -> race travel, paddock visits straight to the event map) never walks there, so the intro flag stayed
--     true and the conversation never spawned. Map nodes 11 / 12 come from the rivalry system, not the map's weights.
-- "gauntlet rival [status]"  that gate, read out (no write)
-- "gauntlet rival offer"     the REAL offer, in the paddock: the rival's RacerDef loaded, his RivalScore raised to the
--                            threshold if below, bNeedsToPlayRivalIntro cleared (the intro skipped: logged), then the
--                            paddock machine -> CSM_Paddock_RivalConversation_Challenge = the game's own offer screen;
--                            P1's GO RACING kicks it off natively ([P1, rival] -> couchrules.rivalPlace)
-- "gauntlet rival accept"    the old harness: KickOffRivalChallengeEvent() at once (couchrules' pre-hook loads the
--                            RacerDef first, so the game finds the rival)
local CSM_PADDOCK_ROOT = "/Game/Griffin/Gameplay/Paddock/StateMachine/CSM_Paddock_Root.CSM_Paddock_Root"
local CSM_RIVAL_OFFER = "/Game/Griffin/Gameplay/Paddock/StateMachine/CSM_Paddock_RivalConversation_Challenge."
    .. "CSM_Paddock_RivalConversation_Challenge"
M.CSM_RIVAL_OFFER = CSM_RIVAL_OFFER

-- the rival's CampaignRunRacer: the opponent entry whose Pilot is DA_Racer_<X> -> entry, list field, index
local function rivalRacer(run, id)
    local want = "DA_Racer_" .. tostring(id)
    for _, field in ipairs({ "OpponentRacers", "NarrativeOpponentRacers" }) do
        local arr = nil
        pcall(function() arr = run[field] end)
        for i = 1, U.arrayCount(arr) do
            local nm = nil
            pcall(function() nm = U.objName(arr[i].Pilot) end)
            if nm == want then return arr[i], field, i end
        end
    end
    return nil
end

local function rivalThreshold(run)
    local t = nil
    pcall(function() t = tonumber(run.Campaign.RivalryConfig.RivalScoreThresholdToInitiateRivalChallenge) end)
    return t
end

local function dayStr(d)
    local p, n = nil, nil
    pcall(function() p, n = tonumber(d.PlanetNum), tonumber(d.PlanetDayNum) end)
    return string.format("%s/%s", tostring(p), tostring(n))
end

-- -> report string, facts
function M.rivalGate(run)
    local f = {}
    local rv = nil
    pcall(function() rv = run.ActiveRivalry end)
    if not U.ok(rv) then return "no active rivalry (the game starts one at RivalScore >= 2)", f end
    f.rivalry = U.objName(rv)
    pcall(function() f.intro = run.bNeedsToPlayRivalIntro == true end)
    pcall(function() f.playing = run.bIsPlayingRivalChallengeEvent == true end)
    pcall(function() f.done = run.bHasCompletedRivalChallenge == true end)
    pcall(function() f.window = dayStr(rv.CanInviteFrom) .. ".." .. dayStr(rv.MustInviteBy) end)
    local CR = U.mod("couchrules")
    local path, id = CR.rivalRacerPath(run)
    f.id = id
    f.defLoaded = false
    if path then
        local okS, o = pcall(StaticFindObject, path)
        f.defLoaded = okS and U.ok(o) or false
    end
    local e, field, idx = rivalRacer(run, id)
    f.found = e ~= nil and (field .. "[" .. idx .. "]") or nil
    if e then pcall(function() f.score = tonumber(e.RivalScore) end) end
    f.threshold = rivalThreshold(run)
    pcall(function() f.planets = U.arrayCount(run.VisitedPlanets) end)
    -- the 0x1471e9bd2 veto (this planet's podracer test not played yet), through the run's own native question
    pcall(function() f.planeTestPending = run:IsPlaneTestEventAvailable() == true end)
    local miss = {}
    if f.intro then miss[#miss + 1] = "the rivalry's intro not played yet (bNeedsToPlayRivalIntro)" end
    if f.playing or f.done then miss[#miss + 1] = "a challenge already played / under way" end
    if not f.found then miss[#miss + 1] = "the rival is on neither opponent list" end
    if f.score and f.threshold and f.score < f.threshold then
        miss[#miss + 1] = string.format("RivalScore %.2f < %.2f", f.score, f.threshold)
    end
    if f.planeTestPending then miss[#miss + 1] = "this planet's podracer test is still pending (no offer before it)" end
    local rep = string.format("rivalry %s (DA_Racer_%s, RacerDef %s, %s, RivalScore %s / %s, invite window %s, planets "
        .. "visited %s); offer: %s", tostring(f.rivalry), tostring(id), f.defLoaded and "in memory" or "not loaded",
        f.found and ("on " .. f.found) or "NOT on the opponent lists", tostring(f.score), tostring(f.threshold),
        tostring(f.window), tostring(f.planets), #miss == 0 and "open (talk to the rival on foot in the paddock)"
        or ("blocked - " .. table.concat(miss, "; ")))
    return rep, f
end

local function paddockMachine()
    local root = U.obj(CSM_PADDOCK_ROOT)
    if not U.ok(root) then return nil, "paddock state assets not loadable" end
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    local m = nil
    if U.ok(mgr) then pcall(function() m = mgr:GetStateMachineForRoot(root) end) end
    if not U.ok(m) then return nil, "no paddock machine (paddock map up?)" end
    return m
end

local function rival(sub)
    sub = sub or "status"
    local cs = campaignSub(nil)
    local run = cs and activeRun(cs)
    if not run then return "no active run" end
    if sub == "status" then
        local rep = M.rivalGate(run)
        U.log(TAG, "rival gate: %s (AUTO-147)", rep)
        return rep
    end
    if St.phase ~= "OTHER" then return "only in the paddock" end
    if not hasRivalry(run) then return "no active rivalry in this run" end
    if sub == "accept" then
        local ok, err = pcall(function() run:KickOffRivalChallengeEvent() end)
        U.log(TAG, "rival: KickOffRivalChallengeEvent %s", ok and "called" or ("failed: " .. tostring(err)))
        return ok and "KickOffRivalChallengeEvent called" or ("error: " .. tostring(err))
    elseif sub ~= "offer" then
        return "usage: gauntlet rival [status|offer|accept]"
    end
    local CR = U.mod("couchrules")
    local loaded = CR.rivalPreload("gauntlet rival offer")
    local _, f = M.rivalGate(run)
    local did = {}
    if not f.found then return "the rival is on neither opponent list: no offer possible (" .. M.rivalGate(run) .. ")" end
    if f.threshold and (f.score or 0) < f.threshold then
        local e = rivalRacer(run, f.id)
        if e and pcall(function() e.RivalScore = f.threshold end) then
            did[#did + 1] = string.format("RivalScore %.2f -> %.2f", f.score or 0, f.threshold)
        end
    end
    if f.intro and pcall(function() run.bNeedsToPlayRivalIntro = false end) then
        did[#did + 1] = "bNeedsToPlayRivalIntro cleared (the intro skipped)"
    end
    local m, why = paddockMachine()
    local st = U.obj(CSM_RIVAL_OFFER)
    if not (m and U.ok(st)) then return "no offer screen: " .. tostring(why or "state asset not loadable") end
    local okC, err = pcall(function() m:ChangeStateTo(st, "SWGRCouch: gauntlet rival offer", nil) end)
    local msg = string.format("rival offer: RacerDef %s; %s; paddock -> RivalConversation_Challenge %s (GO RACING = the "
        .. "game's own kickoff)", loaded and "loaded" or "NOT loaded", #did > 0 and table.concat(did, ", ") or "nothing to "
        .. "prepare", okC and "ok" or ("FAILED: " .. tostring(err)))
    U.log(TAG, "%s (AUTO-147)", msg)
    return msg
end

-- testcmd: "gauntlet start [ids...]|stop|status|skip|goto <id>|arm|list|rival"
function M.command(a)
    local sub = a[2] or "status"
    if sub == "start" then
        local words = {}
        for i = 3, #a do words[#words + 1] = a[i] end
        local list, bad = M.parseList(words)
        if not list then return "unknown step " .. tostring(bad) .. " (gauntlet list)" end
        M.start(list, "test command")
        return M.status()
    elseif sub == "stop" then
        S.on = false
        save()
        local n = restoreAll("gauntlet stop")
        U.log(TAG, "stopped at %s (%d armed node(s) put back)", tostring(S.list[S.i] or "the end"), n)
        return M.status()
    elseif sub == "skip" then
        U.log(TAG, "%s skipped by command", stepLabel(S.i))
        S.i = S.i + 1
        save()
        return M.status()
    elseif sub == "goto" then
        for i, id in ipairs(S.list) do
            if id == a[3] then S.i = i; S.on = true; save(); U.log(TAG, "next step set to %s", stepLabel(i)); return M.status() end
        end
        return "not in the list: " .. tostring(a[3])
    elseif sub == "arm" then
        return arm()
    elseif sub == "rival" then
        return rival(a[3])
    elseif sub == "list" then
        local parts = {}
        for _, id in ipairs(M.DEFAULT) do parts[#parts + 1] = id .. "=" .. M.STEPS[id].label end
        return table.concat(parts, "; ")
    elseif sub == "status" then
        return M.status()
    end
    return "usage: gauntlet start [steps]|stop|status|skip|goto <step>|arm|rival [status|offer|accept]|list"
end

local inited = false
function M.init()
    if inited then return end
    inited = true
    U.hook(CHOOSE, { pre = function(c, n) U.try(TAG, pre, c, n) end, post = function(c) U.try(TAG, post, c) end }, TAG)
    St.on("phase", TAG, function(new, old) U.try(TAG, onPhase, new, old) end)
    if load() then
        U.log(TAG, "state from gauntlet.txt: %s", M.status())
    end
    if cfg.Gauntlet == true and not S.on then
        if #S.list == 0 then M.start(M.parseList({}), "cfg.Gauntlet") else S.on = true; save() end
    end
end

return M
