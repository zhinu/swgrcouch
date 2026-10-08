-- SWGRCouch / state.lua  (G1 Core)
-- The one shared state table `St` plus the synchronous event bus. No game calls.
-- Fields are fixed by ARCHITECTURE.md §4.2 `state`; modules keep their private state under St.<module>
-- so diag can dump everything. `util` is required lazily (util requires this file at its top).
-- Event names: "phase"(new, old), "race_enter"(new, from) (just before "phase" when a race phase is entered from a
-- non-race phase; from = previous phase other than TRANSIT), "leaving"(reason), "leaving_cancelled"(phase), "world"(world), "menu"(menuWidget),
-- "tab"(shown), "players"(), "race_chosen"(choice), "launched"(), "net"(), "status"(text), "settings"(key, value).

local St = {}

local function newMenu()
    return { widget = nil, key = 0, tabAdded = false, lobby = nil, builder = nil,
             visible = nil,            -- "lobby" | "builder" | nil
             hooksMenu = false, hooksBuilder = false, prevTabId = nil,
             pendingNew = nil,         -- last main-menu instance seen by NotifyOnNewObject (menu_tab)
             devscreen = nil }         -- true: builder.open showed the game's dev screen (BuilderMode "devscreen")
end

local function newRace(choice)
    -- launchedByUs: set by launch.start / launch.prepareExternal, kept across the travel worlds, cleared on FRONTEND
    -- (launch.lua); read by join's "race_enter" guard.
    -- singleView: set by join's "race_enter" guard when the guests of a race the mod did not launch are handed to
    -- the AI (split.enterRace shows one view, hud creates no guest HUD).
    return { choice = choice, startedAtMs = 0, started = false, lapOffset = nil, localViews = 1,
             launchedByUs = false, mapPath = "", singleView = false }
end

St.phase = "BOOT"             -- BOOT|FRONTEND|LAUNCHING|LOADING|PRERACE|RACING|POSTRACE|LEAVING|OTHER|TRANSIT
St.phaseSinceMs = 0
St.worldKey, St.gsKey = 0, 0  -- addresses of the current UWorld / GameState
-- Incremented by phase on every new world, also when the new UWorld reuses the old one's address (LoadMap post-hook).
-- Per-world "already done" checks and world-bound timers compare St.worldGen, never St.worldKey: an address repeats.
-- It restarts at 0 in a new Lua state (hot reload): never persist it; a persisted world identity uses St.worldKey.
St.worldGen = 0

St.menu = newMenu()
St.ui = { buttons = {}, rows = {}, statusText = "", dirty = true, returnToTab = false }
           -- buttons[addr] = {id=string, fn=function, widget=UObject}; rows[id] = UObject
St.join = { active = false, frozen = false, keep = false,   -- keep: commit() -> the joined set survives the next travel
            enabled = false,  -- ADD PLAYERS / F6 opt-in given (cfg.GuestOptIn): guests may be created
            slots = {} }  -- slots[ctrlId 1..3] = {ctrlId, joined=false, prevA=false, prevB=false,
                          --   prevStart=false, createdMs=0, disconnected=false, leaving=false}
St.race = newRace(nil)
St.launch = { pending = false, atMs = 0, accepted = false }
           -- accepted: the game took the launch (PrimaryFlow == QuickRace; phase's long LAUNCHING timeout);
           -- launch.lua may add gridPatch = {entry, old, ...}
St.hud = { p1hud = nil, p1Placed = false, guests = {}, lapCounters = {} }
           -- guests[pcKey] = {pc, widget, pnum, lapCounter, lastLapText}; lapCounters[addr] = pcKey
St.tags = { seen = {} }
St.gfx = { saved = nil, savedTakedown = nil, appliedViews = 0 }
St.takeovers, St.takeoversByCar = {}, {}            -- rec tables of ARCHITECTURE §3.3
St.roster = { firstSeen = {}, midGame = {}, remote = {}, humans = {} }  -- keyed by PC address
St.net = { hosting = false, wantConnected = false, connecting = false, listenSinceMs = 0, expectedRemote = 0,
           relistenDone = false, relistenPending = false, waitUntilMs = 0, serverTravelDone = false,
           lateJoinAllowed = false, rejoinTries = 0, nextRejoinMs = 0, lastFailure = nil, driverChecked = false,
           lastRemoteCount = 0, lastLoginLogMs = 0 }
St.hooks = {}                 -- path -> {pre=id, post=id}            (util.lua)
St.pendingHooks = {}          -- path -> {spec, tag, ...}             (util.lua)

---------------------------------------------------------------------------------------------------- time
-- REAL CLOCK (2026-10-07, session B): os.clock() is NOT wall time under Wine/Proton: a 5 s confirm window expired
-- within ~3.5 s (os.clock ran ~1.5x fast; Wine's clock() may count process CPU time, which varies with load). So
-- St.nowMs() is anchored on GameplayStatics:GetAccurateRealTime(out Int Seconds, out Double PartialSeconds) (static,
-- FPlatformTime::Seconds = QueryPerformanceCounter = CLOCK_MONOTONIC under Wine; runtime JMAP), which is process-wide
-- (it does not restart with each world, unlike GetRealTimeSeconds) and therefore also valid across a hot reload.
-- St.sampleClock() takes a sample; it runs on the game thread only (sched's loop wrapper calls it before every loop
-- callback, ~every 33 ms). Between two samples (and on other threads) the time is extrapolated with os.clock()
-- scaled by the measured os.clock rate. Before the first sample St.nowMs() is os.clock-based; the first sample
-- switches to the real clock WITHOUT a jump (offset = the os.clock value at that moment - real time), so stamps
-- taken during init (fastboot's arm time) stay comparable. Each Lua state has its own base: a value that must
-- survive a hot reload is persisted as an age (launch.persistShared), never as a stamp.
-- VERIFY(V-CORE-13): the log line "clock: real time source GetAccurateRealTime (os.clock runs at x1.xx...)" appears once,
-- and the 5 s START-again windows (launch / setup) last 5 real seconds. Fallback: none needed (os.clock as before).
local clk = { real = nil, atClock = nil, rate = 1.0, lastOut = 0, source = "os.clock", fails = 0, logged = false,
              rateSamples = 0, offset = nil }

local function realSecondsNow()
    local a, b = {}, {}
    local gs = clk.gs
    if gs == nil or not gs:IsValid() then
        gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if gs == nil or not gs:IsValid() then return nil end
        clk.gs = gs
    end
    -- Two SCALAR out-params: UE4SS 3f4037d2 (LuaUObject.cpp ~203-223) refs stack index 1 for EVERY out-param and a
    -- non-struct/non-array out-param does not consume its table, so both values land in the FIRST table. Pass the
    -- same table twice and read both fields from it (b is still read as a fallback, should a later UE4SS fix this).
    gs:GetAccurateRealTime(a, a)
    local s = tonumber(a.Seconds) or tonumber(b.Seconds)
    local p = tonumber(a.PartialSeconds) or tonumber(b.PartialSeconds)
    if s == nil or p == nil then return nil end
    return s + p
end

--- Game thread only: anchor the clock on the engine's real time. Cheap (one static UFunction call).
function St.sampleClock()
    if clk.fails > 20 then return false end            -- the call does not work here: stay on os.clock
    local ok, sec = pcall(realSecondsNow)
    if not ok or type(sec) ~= "number" then
        clk.fails = clk.fails + 1
        if clk.fails == 21 then
            print("[SWGRCouch][state] WARN clock: GetAccurateRealTime unavailable (" .. tostring(sec)
                .. "); timers use os.clock (may run fast under Wine)\n")
        end
        return false
    end
    local c = os.clock() * 1000
    if clk.offset == nil then clk.offset = St.nowMs() - sec * 1000 end   -- first sample: continue where we are
    local realMs = sec * 1000 + clk.offset
    if clk.winReal == nil then clk.winReal, clk.winClock = realMs, c end
    local dc, dr = c - clk.winClock, realMs - clk.winReal
    if dc >= 1000 then                                  -- os.clock rate vs real time over >= 1 s windows, smoothed
        if dr > 0 then
            local r = dr / dc
            if r > 0.05 and r < 20 then
                clk.rate = (clk.rateSamples == 0) and r or (clk.rate * 0.7 + r * 0.3)
                clk.rateSamples = clk.rateSamples + 1
            end
        end
        clk.winReal, clk.winClock = realMs, c
    end
    clk.real, clk.atClock, clk.source = realMs, c, "GetAccurateRealTime"
    if not clk.logged and clk.rateSamples >= 10 then
        clk.logged = true
        print(string.format("[SWGRCouch][state] clock: real time source GetAccurateRealTime (os.clock runs at x%.2f "
            .. "of real time)\n", 1 / clk.rate))
    end
    return true
end

--- Milliseconds for timers (monotonic, real time once sampled).  VERIFY(V-CORE-02): FAST deltas ~33 ms.
function St.nowMs()
    local c = os.clock() * 1000
    local out
    if clk.real ~= nil then
        local d = (c - clk.atClock) * clk.rate
        if d < 0 then d = 0 end
        out = clk.real + d
    else
        out = c
    end
    if out < clk.lastOut then out = clk.lastOut end
    clk.lastOut = out
    return out
end

--- Clock diagnostics: source, os.clock-to-real rate.
function St.clockInfo()
    return { source = clk.source, rate = clk.rate, samples = clk.rateSamples, fails = clk.fails }
end

---------------------------------------------------------------------------------------------------- resets
--- New world: per-race state goes. Keeps race.choice (the chosen race) and race.launchedByUs (set by
--- launch.start just before the travel that creates this new world).
function St.resetRace()
    local keepChoice, keepLaunched = St.race.choice, St.race.launchedByUs
    St.race = newRace(keepChoice)
    St.race.launchedByUs = keepLaunched
    St.hud = { p1hud = nil, p1Placed = false, guests = {}, lapCounters = {} }
    St.tags = { seen = {} }
    St.takeovers, St.takeoversByCar = {}, {}
    St.roster.midGame = {}
end

--- New main-menu instance: the menu table goes back to defaults. St.ui.returnToTab is untouched.
function St.resetMenu()
    St.menu = newMenu()
end

---------------------------------------------------------------------------------------------------- event bus
local listeners = {}   -- event -> array of {tag=, fn=}

--- Subscribe. A second registration with the same (event, tag, fn) is ignored.
function St.on(event, tag, fn)
    if type(event) ~= "string" or type(fn) ~= "function" then
        error("St.on(event, tag, fn): bad arguments for event " .. tostring(event), 2)
    end
    local list = listeners[event]
    if not list then list = {}; listeners[event] = list end
    for i = 1, #list do
        if list[i].fn == fn and list[i].tag == tag then return end
    end
    list[#list + 1] = { tag = tag or "event", fn = fn }
end

--- Emit synchronously; each listener runs in its own U.try (one failure does not stop the others).
function St.emit(event, ...)
    local list = listeners[event]
    if not list or #list == 0 then return end
    local U = require("util")
    -- copy: a listener may subscribe during dispatch
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    for i = 1, #snapshot do
        local l = snapshot[i]
        U.try(l.tag .. "<" .. event, l.fn, ...)
    end
end

--- Number of listeners per event (diag).
function St.listenerCounts()
    local out = {}
    for ev, list in pairs(listeners) do out[ev] = #list end
    return out
end

return St
