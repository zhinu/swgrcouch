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
           -- launch.lua may add gridPatch = {entry, old, ...}; acceptCb = St.cb of the callback that made the accepted
           -- LaunchCustomRace call (St.launchHold)
St.cb = 0  -- callback serial: +1 at the start of every sched callback and native hook dispatch (U.anchorThread)

-- 0.12.0 launch hold (crashes 2026-10-10 13:10, 13:21, 13:30, 13:33, 4 of 5 launches from RACE SETUP): an accepted
-- LaunchCustomRace tears the front end down, and the garbage collector frees its widgets before the mod's next
-- callback, while St.phase still says FRONTEND / LAUNCHING and every page still holds its widgets (theme forgets them
-- only on a race phase). A call on a freed widget is an access violation inside UE4SS (UE4SS.dll+0x3e7ee5). True
-- from the first callback after the one that made the accepted call until the launch is over (St.launch.pending is
-- cleared on a race phase, a launch timeout or a refusal): no front-end page, theme widget or menu object is touched.
function St.launchHold()
    local l = St.launch
    return l.pending == true and l.accepted == true and l.acceptCb ~= St.cb
end
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

---------------------------------------------------------------------------------------------------- out-param leak
-- UE4SS LEAK (couch-racefast, live 2026-10-15 after one couch race: 635,469 Lua registry entries, 632,054 of them
-- {Seconds, PartialSeconds} tables and 6,885 {OutFoundPriority}; Lua heap 64 MB LIVE after a full collect, a full
-- collect 55-79 ms). A UFunction call with out-params luaL_ref's the Lua table passed for them in the registry and
-- never unrefs it: every GetAccurateRealTime (the clock sample of EVERY sched loop run, ~45 a second; the profiler
-- twice per profiled call) left a table in the registry for the rest of the session. The live heap only grows, so
-- every incremental GC cycle marks more and its atomic phase gets longer: the 10-20 ms spikes that land in whatever
-- module tick allocates at that moment, worse the longer the session runs.
-- Fix: out-param tables are reused (St.outParams) and the refs a call left on them are dropped from the registry
-- right after it (St.dropOutRefs: the refs sit at the registry's tail); St.sweepOutRefs (every 3 s from the clock
-- sample) removes any other entry holding a registered out table or a leaked out-param table of a known shape
-- (callers not migrated, a hot reload's predecessor). UE4SS never reads these refs again after the call returns.
local REG = nil
pcall(function() REG = debug.getregistry() end)
local outSet = setmetatable({}, { __mode = "k" })
-- the key sets of the leaked out-param tables (exactly these keys, nothing else)
local OUT_SHAPES = { { "PartialSeconds", "Seconds" }, { "OutFoundPriority" } }

--- Register a reusable out-param table (its registry refs are dropped by St.dropOutRefs / St.sweepOutRefs).
function St.outParams(t) outSet[t] = true; return t end

--- Right after a UFunction call with out table t: drop the refs it left at the registry's tail. -> refs dropped
function St.dropOutRefs(t)
    if REG == nil then return 0 end
    local n, k = #REG, 0
    while n > 3 and k < 16 and rawequal(rawget(REG, n), t) do
        rawset(REG, n, nil)
        n, k = n - 1, k + 1
    end
    return k
end

local function leakedShape(v)
    if outSet[v] then return true end
    if getmetatable(v) ~= nil then return false end
    for _, shape in ipairs(OUT_SHAPES) do
        local n, ok = 0, true
        for key in pairs(v) do
            n = n + 1
            local hit = false
            for _, want in ipairs(shape) do if key == want then hit = true end end
            if not hit then ok = false; break end
        end
        if ok and n > 0 then return true end
    end
    return false
end

local sweep = { at = nil, total = 0, last = 0 }
--- Remove every registry entry that holds an out-param table (registered or of a known leaked shape). -> removed
function St.sweepOutRefs()
    if REG == nil then return 0 end
    local n = 0
    for k, v in pairs(REG) do
        if type(k) == "number" and k > 3 and type(v) == "table" and leakedShape(v) then
            REG[k] = nil                        -- assigning nil to an existing field during next() is allowed
            n = n + 1
        end
    end
    sweep.total, sweep.last = sweep.total + n, n
    return n
end
function St.outRefStats() return { total = sweep.total, last = sweep.last } end

local CLK_OUT = St.outParams({})
local function clockCall(gs, a) return gs:GetAccurateRealTime(a, a) end
local function clockFn(gs) return gs.GetAccurateRealTime end
local function realSecondsNow()
    local gs = clk.gs
    if gs == nil or not gs:IsValid() then
        gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if gs == nil or not gs:IsValid() then return nil end
        clk.gs = gs
    end
    -- Two SCALAR out-params: UE4SS 3f4037d2 (LuaUObject.cpp ~203-223) refs stack index 1 for EVERY out-param and a
    -- non-struct/non-array out-param does not consume its table, so both values land in the FIRST table. Pass the
    -- same table twice and read both fields from it. ONE table for every call (see the out-param leak above).
    -- couch-racegc: the UFunction wrapper of `gs.GetAccurateRealTime` is kept with the CDO wrapper and called again
    -- (its calling context is the CDO; `gs:GetAccurateRealTime` built a new wrapper - a finalizable userdata - at every
    -- call: ~45 loop runs a second plus two per profiled module call). The built-in CallFunction with a UFunction found
    -- by StaticFindObject is refused by this UE4SS (live 2026-10-16, util.lua U.pcallFn).
    local a = CLK_OUT
    a.Seconds, a.PartialSeconds = nil, nil
    local fw = clk.fnW
    if fw == nil or clk.fnWOf ~= gs then
        local okF, f = pcall(clockFn, gs)
        fw = (okF and type(f) == "userdata") and f or nil
        clk.fnW, clk.fnWOf = fw, gs
    end
    local okC, err
    if fw ~= nil then
        okC, err = pcall(fw, gs, a, a)
        if not okC then clk.fnW = nil end                -- looked up again next time; this sample the plain call
    end
    if fw == nil or not okC then
        St.dropOutRefs(a)
        a.Seconds, a.PartialSeconds = nil, nil
        okC, err = pcall(clockCall, gs, a)
    end
    St.dropOutRefs(a)
    if not okC then error(err, 0) end
    local s = tonumber(a.Seconds)
    local p = tonumber(a.PartialSeconds)
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
    -- the out-param leak sweep (cheap: the registry stays small once swept), every 3 s of real time
    if sweep.at == nil or realMs - sweep.at >= 3000 then
        sweep.at = realMs
        pcall(St.sweepOutRefs)
    end
    if not clk.logged and clk.rateSamples >= 10 then
        clk.logged = true
        print(string.format("[SWGRCouch][state] clock: real time source GetAccurateRealTime (os.clock runs at x%.2f "
            .. "of real time)\n", 1 / clk.rate))
    end
    return true
end

--- Profiling only (main.lua's tick profiler): the engine's real time in ms NOW (one static UFunction call, not the
--- extrapolated St.nowMs), or nil. os.clock() is process CPU time under Wine, useless for spans.
function St.preciseMs()
    local ok, sec = pcall(realSecondsNow)
    if ok and type(sec) == "number" then return sec * 1000 end
    return nil
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
