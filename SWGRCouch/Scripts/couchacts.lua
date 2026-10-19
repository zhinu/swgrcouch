-- couchacts.lua (0.15 F02): the campaign's ACTS for the COUCH CAMPAIGN page (couchpage.lua), and two actions on them:
-- REPLAY an unlocked act (the page: a new run of that act, everyone joined) and DELETE ALL COUCH PROGRESS (#98: offered
-- in the mod's settings, FREE MODE > OPTIONS > ADVANCED, lobby.onCouchDelete).
-- Jules 2026-10-15: "In the couch campaign screen, have the unlocked previous campaigns. For instance even if you have
-- already done the qualification you can restart it if you want." / "Have in options the option to delete all progress".
--
-- How the game tracks the acts (static evidence, CL381121 hf2 exe + data; notes in the commit message of F02):
--   * CAM_GfnCampaign.Tours = CAM_Tour1 / CAM_Tour2 / CAM_Tour3 ("ACT I: The Qualifier", "ACT II: The Galactic League",
--     "ACT III: Kestar's Galactic League"). One run = one act.
--   * CampaignMetaProgression.MainCampaignCurrentTourIx (+0x28, meta save) = the act the NEXT new run plays: with no
--     run, CampaignSubsystem's active-tour getter returns Campaign.Tours[MainCampaignCurrentTourIx] (exe 0x140b1da36;
--     with a run it returns ActiveRun.Tour, with a scenario Scenario.Tour). A WON run sets it to (index of the run's
--     tour) + 1, capped at the last act (exe 0x142f8ddf7): it follows the act played, not the furthest one.
--   * Completion = the unlock tags Unlock.Cam.Tour1Done / Tour2Done / Tour3Done (CAM_Tour2 / CAM_Tour3 list the
--     previous one in TagsToUnlockBeforeStarting; CAM_GfnCampaign's completion unlocks Tour3Done + NewGamePlus).
--   * The game has NO shipping way to pick an earlier act: no act select widget exists; the dev cvar
--     Campaign.SkipToTourIx (WBP_Dev_CampaignQuickSetup) does it inside the new-run start (exe 0x142f8c89e: it writes
--     MainCampaignCurrentTourIx = min(current, skip) .. skip, re-grants those acts' TagsToUnlockBeforeStarting and
--     marks the prologue skipped), but it stays set for every later run. REPLAY writes the same field directly, once,
--     with a read-back, right before the game's own campaign entry (CampaignSelected, the CONTINUE tile's code).
--   * A run in progress is abandoned the pause menu's way (WBP_Pause ABANDON TOUR: CampaignSubsystem:LockRun(); the
--     next CampaignSelected starts a new run, live 2026-10-14 notes 09 / 10). The page asks first (couchpage confirm).
--   * The game's own campaign reset is FrontEndGameMode:RestartCampaignSelected (the NG+ "Restart Campaign" action of
--     the CONTINUE tile, WBP_FE_Recommended.OnConfirmRestartCampaign): it locks the run, resets the meta campaign
--     progress (MainCampaignCurrentTourIx = 0, played prologues, rivalries, mysteries, last outcome: exe 0x1430075ec),
--     relocks CAM_CampaignResetData.UnlocksToRelock (Unlock.Cam.Tour0..3Done, FirstRunDone, Map, Evt, Spon, Sys,
--     Rival, VO...) and starts a fresh ACT I. It keeps the vehicle Tuning Points / Kit Points, vehicle upgrades,
--     customisation and logbook unlocks (the game's own NG+ text says so). DELETE uses it for the campaign part and
--     resets couch-run.txt (guests) with a dated copy kept (ARCHITECTURE hard rule 10: no file is deleted).
--   * HARD RULE: DELETE runs only while the COUCH save profile is live: the marker file .swgr-profile that
--     galactic-racer/tools/swgr-save-profile.sh writes in the live SaveGames/<account> folder must read "couch", and
--     the launcher's SWGR_SAVE_PROFILE (inherited by the game process) must not name another profile. Anything else
--     (no marker = the solo save, a "-loading" state, an unreadable folder) refuses with the reason.
-- Config: cfg.CouchActPosters (true), cfg.CouchDeleteProgress (true), cfg.CouchSaveAccountId ("" = from Steam's
-- loginusers.vdf).
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "couchacts"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local TXR = "/Game/Griffin/UI/Library/Textures/Content/Rewards/"
local function tex(n) return TXR .. n .. "." .. n end
-- the acts (CAM_TourN PlayerFacingName / PlayerFacingDescription, PrizeImage = the act's embroidered patch)
M.ACTS = {
    { n = 1, roman = "I", name = "THE QUALIFIER", tour = "CAM_Tour1", done = "Unlock.Cam.Tour1Done",
      goal = "Reach Derven Acos to challenge the Qualifier Champion.", art = tex("T_UI_Act_1_Prize"), hue = "#3B4443" },
    { n = 2, roman = "II", name = "THE GALACTIC LEAGUE", tour = "CAM_Tour2", done = "Unlock.Cam.Tour2Done",
      goal = "Reach the Championship to challenge Kestar Bool.", art = tex("T_UI_Act_2_Prize"), hue = "#33495C" },
    { n = 3, roman = "III", name = "KESTAR'S GALACTIC LEAGUE", tour = "CAM_Tour3", done = "Unlock.Cam.Tour3Done",
      goal = "Reach the Championship to challenge Kestar Bool once and for all.", art = tex("T_UI_Act_3_Prize"),
      hue = "#3A3160" },
}
M.MARKER = ".swgr-profile"

---------------------------------------------------------------------------------------------------- pure rules
-- p = {cur = MainCampaignCurrentTourIx | nil, done = {bool x3}, runAct = 1..3 | nil, runActGuess = bool, inProgress = bool}
-- -> {[n] = {unlocked, completed, current (the run in progress plays it), next (a new run would play it), reason}}
function M.states(p)
    p = type(p) == "table" and p or {}
    local done = type(p.done) == "table" and p.done or {}
    local cur = tonumber(p.cur)
    local out = {}
    for i = 1, #M.ACTS do
        local s = { completed = done[i] == true }
        if i == 1 then s.unlocked = true
        else s.unlocked = done[i - 1] == true or (cur ~= nil and cur >= i - 1) end
        s.current = p.inProgress == true and p.runAct == i
        s.continueHere = s.current and p.runActGuess == true
        s.next = cur ~= nil and cur == i - 1
        if not s.unlocked then s.reason = "Complete ACT " .. M.ACTS[i - 1].roman .. " to unlock." end
        out[i] = s
    end
    return out
end

-- the poster's kicker line. The run in progress wins over COMPLETED (a REPLAY of a done act is still the one CONTINUE
-- resumes); an act read from the act pointer, not from the loaded run, is "CONTINUE HERE"
function M.kicker(s)
    if type(s) ~= "table" then return "" end
    if s.current then return s.continueHere and "CONTINUE HERE" or "RUN IN PROGRESS" end
    return s.completed and "COMPLETED" or ""
end

-- "…/CAM_Tour2.CAM_Tour2" (any full name) -> 2
function M.actOfTourName(s)
    local n = tonumber(string.match(tostring(s or ""), "CAM_Tour(%d)"))
    if n and M.ACTS[n] then return n end
    return nil
end

---------------------------------------------------------------------------------------------------- game reads
local function cs()
    local ok, c = pcall(FindFirstOf, "CampaignSubsystem")
    return (ok and U.ok(c)) and c or nil
end
M._cs = cs

local function tagUnlocked(sub, tag)
    local lib = U.cdo("/Script/Griffin.Default__BlueprintSPUnlockSystemLibrary")
    if U.ok(lib) then
        local ok, v = pcall(function() return lib:IsTagUnlocked(sub, { TagName = U.fname(tag) }) end)
        if ok and type(v) == "boolean" then return v end
    end
    -- fallback: the campaign container's own tag list
    local found = nil
    pcall(function()
        local arr = sub.UnlockedTagsCampaign.GameplayTags
        found = false
        for i = 1, U.arrayCount(arr) do
            local t = arr[i]
            local n = t and t.TagName
            if n ~= nil and tostring(n:ToString()) == tag then found = true; break end
        end
    end)
    return found
end

-- the progress the page shows; every field nil when unreadable (the page then shows ACT I only)
function M.readProgress()
    local p = { done = {} }
    local c = cs()
    if not c then p.err = "no CampaignSubsystem"; return p end
    pcall(function()
        local meta = c.MetaProgression
        if U.ok(meta) then p.cur = tonumber(meta.MainCampaignCurrentTourIx) end
    end)
    local okS, sub = pcall(FindFirstOf, "SPUnlockSubsystem")
    if okS and U.ok(sub) then
        for i, a in ipairs(M.ACTS) do p.done[i] = tagUnlocked(sub, a.done) end
    end
    -- the run: ActiveRun (not locked) or the save manager's own CONTINUE test
    local run = nil
    pcall(function() run = c.ActiveRun end)
    if U.ok(run) then
        local locked = nil
        pcall(function() locked = run.bRunLocked == true end)
        p.inProgress = locked == false
        pcall(function()
            local t = run.Tour
            if U.ok(t) then p.runAct = M.actOfTourName(t:GetFullName()) end
        end)
    end
    pcall(function()
        local sm = FindFirstOf("CampaignSaveManager")
        if U.ok(sm) and sm:CanContinueCurrentCampaignSave() == true then p.inProgress = true end
    end)
    pcall(function() p.never = c:HasNeverStartedCampaign() == true end)
    if p.never then p.inProgress = false end
    -- Live 2026-10-15 (final F3/F4): at the front end the saved run is NOT loaded (ActiveRun null until CONTINUE's
    -- SetCampaignAsCurrent), so runAct stayed nil and no poster ever read RUN IN PROGRESS. A run in progress was
    -- started from the act pointer and the pointer only moves when a run is WON: the saved run plays
    -- Tours[MainCampaignCurrentTourIx] = act cur + 1, the act CONTINUE resumes (runActGuess: "CONTINUE HERE").
    if p.inProgress == true and p.runAct == nil and p.cur ~= nil then
        local n = math.floor(p.cur) + 1
        if n < 1 then n = 1 elseif n > #M.ACTS then n = #M.ACTS end
        p.runAct, p.runActGuess = n, true
    end
    return p
end

---------------------------------------------------------------------------------------------------- couch profile
M._getenv = function(k) return os.getenv(k) end
local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end
M._readFile = readFile

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- the account folders to look in: cfg.CouchSaveAccountId, else every SteamID64 in Steam's loginusers.vdf (Proton gives
-- the game STEAM_COMPAT_CLIENT_INSTALL_PATH; Wine maps Z: to /)
local function accountIds()
    local id = trim(opt("CouchSaveAccountId", ""))
    if id ~= "" then return { id } end
    local ids, seen = {}, {}
    local steam = M._getenv("STEAM_COMPAT_CLIENT_INSTALL_PATH")
    if steam and steam ~= "" then
        local src = M._readFile("Z:" .. steam:gsub("\\", "/") .. "/config/loginusers.vdf")
        for s in string.gmatch(src or "", '"(7656119%d%d%d%d%d%d%d%d%d%d)"') do
            if not seen[s] then seen[s] = true; ids[#ids + 1] = s end
        end
    end
    return ids
end

local function saveRoots()
    local roots, seen = {}, {}
    local function add(r)
        if r and r ~= "" then
            r = r:gsub("\\", "/"):gsub("/+$", "")
            if not seen[r] then seen[r] = true; roots[#roots + 1] = r end
        end
    end
    local lad = M._getenv("LOCALAPPDATA")
    if lad and lad ~= "" then add(lad .. "/StarWarsGalacticRacer/Saved/SaveGames") end
    local cd = M._getenv("STEAM_COMPAT_DATA_PATH")
    if cd and cd ~= "" then
        add("Z:" .. cd .. "/pfx/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/SaveGames")
    end
    add("C:/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/SaveGames")
    return roots
end

-- -> ok, reason (a sentence for the page), where (the marker file read)
function M.couchProfileLive()
    local env = trim(M._getenv("SWGR_SAVE_PROFILE"))
    if env ~= "" and env ~= "couch" then
        return false, "The " .. string.upper(env) .. " save profile is live (SWGR_SAVE_PROFILE): nothing was changed."
    end
    local ids = accountIds()
    if #ids == 0 then
        return false, "The couch save profile could not be checked (no Steam account found; set CouchSaveAccountId): "
            .. "nothing was changed."
    end
    local marks = {}
    for _, root in ipairs(saveRoots()) do
        for _, id in ipairs(ids) do
            local path = root .. "/" .. id .. "/" .. M.MARKER
            local s = M._readFile(path)
            if s ~= nil then marks[#marks + 1] = { path = path, v = trim(s) } end
        end
    end
    if #marks == 0 then
        return false, "Only for the COUCH save profile (the couch launcher): the live save is your SOLO save. Nothing was "
            .. "changed."
    end
    for _, m in ipairs(marks) do
        if m.v ~= "couch" then
            return false, "The live save profile is \"" .. m.v .. "\", not the couch one: nothing was changed.", m.path
        end
    end
    return true, "The COUCH save profile is live.", marks[1].path
end

---------------------------------------------------------------------------------------------------- actions
local function phaseOk()
    if St.phase ~= "FRONTEND" then return false, "only from the main menu" end
    if St.launch and St.launch.pending then return false, "a launch is pending" end
    return true
end

-- REPLAY act n as a NEW run. abandon = the player confirmed losing the run in progress. enter = fn(why) -> bool (the
-- page's campaign entry: SetActiveCampaign(None, true) + FrontEndGameMode:CampaignSelected()).
-- -> ok, message. Order: write the act (read back) -> abandon the run in progress -> the game's entry. A failure before
-- the abandon changes nothing; a failed entry puts the act pointer back.
function M.replay(n, abandon, enter)
    local okP, why = phaseOk()
    if not okP then return false, "Not now: " .. why .. "." end
    local act = M.ACTS[n]
    if not act then return false, "No such act." end
    local p = M.readProgress()
    local st = M.states(p)[n]
    if not st.unlocked then return false, st.reason end
    if p.inProgress and not abandon then return false, "A run is in progress: confirm first." end
    local c = cs()
    if not c then return false, "The campaign is not ready." end
    local meta = nil
    pcall(function() meta = c.MetaProgression end)
    if not U.ok(meta) then return false, "The campaign progress is not loaded." end
    local old = nil
    pcall(function() old = tonumber(meta.MainCampaignCurrentTourIx) end)
    if old == nil then return false, "The campaign progress is unreadable." end
    local want = n - 1
    if old ~= want then
        local okW = pcall(function() meta.MainCampaignCurrentTourIx = want end)
        local back = nil
        pcall(function() back = tonumber(meta.MainCampaignCurrentTourIx) end)
        if not okW or back ~= want then
            pcall(function() meta.MainCampaignCurrentTourIx = old end)
            U.warn(TAG, "REPLAY ACT %s: MainCampaignCurrentTourIx write %s -> %s read back %s: nothing changed",
                act.roman, tostring(old), tostring(want), tostring(back))
            return false, "The act could not be selected: nothing was changed."
        end
    end
    if p.inProgress then
        -- LockRun acts on ActiveRun only (exe 0x147088fec: no run = no-op): without a loaded run the game's entry would
        -- CONTINUE the saved run instead of starting the act, so the run must be there and must read locked after
        local run = nil
        pcall(function() run = c.ActiveRun end)
        if not U.ok(run) then
            -- live 2026-10-15 final: at the FRONT END the saved run is never loaded (ActiveRun nil), so every replay with
            -- a run in progress was refused. The saved run is ended the save manager's way instead:
            -- CampaignSaveManager:DeleteCurrentCampaignSaveAsync drops the RUN save only (GriffinRun; the meta save with
            -- the acts, unlocks and the act pointer stays), CanContinueCurrentCampaignSave reads false after it, and the
            -- game's entry then starts a new run of the act (live: CAM_Tour1 from the front end). (DEBUG_LockCampaignSave
            -- is a no-op in the shipping game.) Not gone at once (async): refused, nothing else changed.
            local sm, okD, still = nil, false, true
            pcall(function() sm = FindFirstOf("CampaignSaveManager") end)
            if U.ok(sm) then
                okD = pcall(function() sm:DeleteCurrentCampaignSaveAsync() end)
                pcall(function() still = sm:CanContinueCurrentCampaignSave() == true end)
            end
            if not okD or still then
                if old ~= want then pcall(function() meta.MainCampaignCurrentTourIx = old end) end
                U.warn(TAG, "REPLAY ACT %s: the saved run (not loaded) %s", act.roman,
                    okD and "is still there right after its delete" or "could not be deleted")
                return false, okD and "The saved run is being ended: press A on the act again."
                    or "The run in progress could not be ended: nothing was changed."
            end
            U.log(TAG, "REPLAY ACT %s: the saved run in progress (not loaded at the front end) ended: run save deleted "
                .. "(CampaignSaveManager:DeleteCurrentCampaignSaveAsync; acts and unlocks kept)", act.roman)
        else
            local okL, err = pcall(function() c:LockRun() end)
            local locked = nil
            pcall(function() locked = run.bRunLocked == true end)
            if not okL or locked ~= true then
                pcall(function() meta.MainCampaignCurrentTourIx = old end)
                U.warn(TAG, "REPLAY ACT %s: LockRun %s (run locked: %s): act pointer restored", act.roman,
                    okL and "ran" or ("failed: " .. tostring(err)), tostring(locked))
                return false, "The run in progress could not be ended: nothing was changed."
            end
            U.log(TAG, "REPLAY ACT %s: the run in progress (act %s) abandoned (LockRun, the pause menu's ABANDON TOUR)",
                act.roman, tostring(p.runAct))
        end
    end
    local okE, res = false, nil
    if type(enter) == "function" then okE, res = pcall(enter, "REPLAY ACT " .. act.roman) end
    if not (okE and res == true) then
        if not okE then U.warn(TAG, "REPLAY ACT %s: the campaign entry raised %s", act.roman, tostring(res)) end
        if old ~= want then pcall(function() meta.MainCampaignCurrentTourIx = old end) end
        if p.inProgress then return false, "The old run was ended, but the campaign did not start (see the log)." end
        return false, "The campaign did not start (see the log)."
    end
    M.pendingVerify = { n = n, atMs = St.nowMs() }
    U.log(TAG, "REPLAY ACT %s (%s): act pointer %s -> %d, new run started through the game's campaign entry", act.roman,
        act.name, tostring(old), want)
    return true, "ACT " .. act.roman .. " starts."
end

-- once the new run exists (any phase after the launch): log which act the game really started (V-CPAGE-01)
function M.verifyTick()
    local v = M.pendingVerify
    if not v then return end
    -- the new run exists only after the logbook, vehicle, style and loadout screens (live: > 2 min with two players)
    if St.nowMs() - v.atMs > 900000 then M.pendingVerify = nil; return end
    local c = cs()
    if not c then return end
    local run, tour = nil, nil
    pcall(function() run = c.ActiveRun end)
    if not U.ok(run) then return end
    pcall(function() local t = run.Tour; if U.ok(t) then tour = t:GetFullName() end end)
    if not tour then return end
    M.pendingVerify = nil
    local got = M.actOfTourName(tour)
    if got == v.n then
        U.log(TAG, "REPLAY ACT %s verified: the new run plays %s (V-CPAGE-01)", M.ACTS[v.n].roman, tostring(tour))
    else
        U.warn(TAG, "REPLAY ACT %s: the new run plays %s (act %s), not the act asked (V-CPAGE-01)", M.ACTS[v.n].roman,
            tostring(tour), tostring(got))
    end
end

-- DELETE ALL COUCH PROGRESS. -> ok, message. Refused unless the couch profile is live (checked again here). prepare()
-- runs right before the game's reset (OPTIONS and the join window close there, lobby.onCouchDelete).
function M.deleteAll(prepare)
    if opt("CouchDeleteProgress", true) == false then return false, "Turned off (CouchDeleteProgress)." end
    local okP, why = phaseOk()
    if not okP then return false, "Not now: " .. why .. "." end
    local live, reason, where = M.couchProfileLive()
    if not live then
        U.warn(TAG, "DELETE ALL COUCH PROGRESS refused: %s", reason)
        return false, reason
    end
    local gm = U.gm()
    if not U.ok(gm) then return false, "The main menu is not ready: nothing was changed." end
    -- the guests first (a mod file; its old content is kept in a dated copy)
    local okR, kept = pcall(function() return U.mod("couchrun").wipe("DELETE ALL COUCH PROGRESS") end)
    if not okR then
        U.warn(TAG, "couch-run.txt reset failed (%s): the campaign save is not touched", tostring(kept))
        return false, "The guests' progress could not be reset: nothing was changed."
    end
    if type(prepare) == "function" then pcall(prepare) end
    local okG, err = pcall(function() gm:RestartCampaignSelected() end)
    if not okG then
        U.warn(TAG, "RestartCampaignSelected failed (%s): guests reset, the campaign save is unchanged", tostring(err))
        return false, "The guests were reset, but the campaign reset failed (see the log)."
    end
    U.log(TAG, "DELETE ALL COUCH PROGRESS: couch profile live (%s); guests reset (old file kept: %s); the game's campaign "
        .. "reset ran (RestartCampaignSelected: acts relocked, a fresh ACT I starts)", tostring(where), tostring(kept))
    return true, "Couch progress deleted: a fresh ACT I starts."
end

return M
