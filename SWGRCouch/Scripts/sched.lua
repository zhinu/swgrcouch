-- SWGRCouch / sched.lua  (G1 Core)
-- The only way to start game work. Every callback is wrapped (U.try, or a throttled xpcall for loops).
-- UE4SS facts (LuaMod.cpp at 3f4037d2, [API§2]):
--   ExecuteInGameThread(fn, method)        does NOT fall back: an unavailable method throws -> sched.GT
--   ExecuteInGameThreadWithDelay(ms, fn)   -> handle; falls back between EngineTick/ProcessEvent itself
--   LoopInGameThreadWithDelay(ms, fn)      -> handle; the callback's return value is ignored
--   ExecuteInGameThreadAfterFrames(n, fn)  needs the EngineTick hook (throws otherwise)
--   ms / frames / handles must be Lua INTEGERS (lua_isinteger checks): every ms goes through toMs()
--   CancelDelayedAction(h) / IsValidDelayedActionHandle(h); a mod can only cancel its own handles

local cfg = require("config")
local U   = require("util")
local St  = require("state")

local sched = {}

---------------------------------------------------------------------------------------------------- method
-- VERIFY(V-CORE-01): boot banner shows EngineTickAvailable=true; else ProcessEvent is used (coarser timing),
-- or set DefaultExecuteInGameThreadMethod=ProcessEvent in UE4SS-settings.ini.
local function pickMethod()
    if type(EGameThreadMethod) ~= "table" then return nil end
    if EngineTickAvailable == true and EGameThreadMethod.EngineTick ~= nil then return EGameThreadMethod.EngineTick end
    if ProcessEventAvailable == true and EGameThreadMethod.ProcessEvent ~= nil then return EGameThreadMethod.ProcessEvent end
    -- neither scan reported success: ProcessEvent is the safer guess (EngineTick needs an AOB match)
    return EGameThreadMethod.ProcessEvent
end
sched.GT = pickMethod()

function sched.methodName()
    if sched.GT == nil then return "default(ini)" end
    if type(EGameThreadMethod) == "table" then
        for k, v in pairs(EGameThreadMethod) do if v == sched.GT then return tostring(k) end end
    end
    return tostring(sched.GT)
end

---------------------------------------------------------------------------------------------------- helpers
local handles = {}       -- handle -> tag (every live handle this module created)
local loopSeqN = 0       -- St.loopSeq source (sched.every runs)
local loopStats = {}     -- tag -> {runs, errors, suppressed, lastRunMs, lastDeltaMs, maxDeltaMs, lastErrLogMs}

local function toMs(ms)
    local n = tonumber(ms) or 0
    if n < 0 then n = 0 end
    return math.tointeger(math.floor(n + 0.5)) or 0
end

local function pack(...) return table.pack(...) end

local function onGameThread()
    local ok, v = pcall(function() return IsInGameThread() end)
    return ok and v == true
end

---------------------------------------------------------------------------------------------------- one-shot
--- Run fn(...) on the game thread (next tick of the chosen method). Callable from any thread.
--- Returns true when queued.
function sched.run(tag, fn, ...)
    local args = pack(...)
    local wrapped = function() U.anchorThread(); U.try(tag, fn, table.unpack(args, 1, args.n)) end
    local ok, e
    if sched.GT ~= nil then
        ok, e = pcall(ExecuteInGameThread, wrapped, sched.GT)
    else
        ok, e = pcall(ExecuteInGameThread, wrapped)
    end
    if not ok then
        -- e.g. the chosen hook disappeared: the delayed-action path falls back by itself
        U.logEvery("sched.run!" .. tostring(tag), 5000, "sched", "ExecuteInGameThread failed for %s: %s; using delay 0",
            tostring(tag), tostring(e))
        return sched.after(tag, 0, function() fn(table.unpack(args, 1, args.n)) end) ~= nil
    end
    return true
end

--- Inline when already on the game thread (returns U.try's results), else sched.run.
function sched.now(tag, fn, ...)
    if onGameThread() then return U.try(tag, fn, ...) end
    return sched.run(tag, fn, ...)
end

--- Run fn() once on the game thread after ms milliseconds. Returns a handle (or nil on failure).
function sched.after(tag, ms, fn)
    local h
    local wrapped = function()
        U.anchorThread()
        if h ~= nil then handles[h] = nil end
        U.try(tag, fn)
    end
    local ok, r = pcall(ExecuteInGameThreadWithDelay, toMs(ms), wrapped)
    if not ok or type(r) ~= "number" then
        U.err("sched", "ExecuteInGameThreadWithDelay(%s) failed: %s", tostring(tag), tostring(r))
        return nil
    end
    h = r
    handles[h] = tag
    return h
end

--- Next frame (EngineTick) or, without EngineTick, a delayed action of fallbackMs (default 0). With the ProcessEvent
--- method a 0 ms action runs on the next ProcessEvent call, normally inside the SAME frame: a caller that needs a
--- real frame boundary passes fallbackMs (e.g. 50 = a few frames).
function sched.nextFrame(tag, fn, fallbackMs)
    if EngineTickAvailable == true then
        local h
        local wrapped = function()
            U.anchorThread()
            if h ~= nil then handles[h] = nil end
            U.try(tag, fn)
        end
        local ok, r = pcall(ExecuteInGameThreadAfterFrames, 1, wrapped)
        if ok and type(r) == "number" then
            h = r
            handles[h] = tag
            return h
        end
        U.logOnce("sched.frames!", "sched", "ExecuteInGameThreadAfterFrames failed (%s); nextFrame uses after(%d)",
            tostring(r), tonumber(fallbackMs) or 0)
    end
    return sched.after(tag, tonumber(fallbackMs) or 0, fn)
end

---------------------------------------------------------------------------------------------------- loops
--- Run fn() every ms on the game thread until sched.cancel(handle). An error never cancels the loop; error
--- lines are throttled to one per cfg.LoopErrorLogEveryMs per loop (with the count of suppressed ones).
--- Timing stats per tag feed V-CORE-02 (sched.stats()).
function sched.every(tag, ms, fn)
    local st = { runs = 0, errors = 0, suppressed = 0, lastRunMs = nil, lastDeltaMs = 0, maxDeltaMs = 0,
                 lastErrLogMs = nil, periodMs = toMs(ms) }
    loopStats[tag] = st
    local wrapped = function()
        U.anchorThread()                     -- util.lua: keep UE4SS's shared hook thread alive (V-CORE-12)
        -- game thread: anchor St.nowMs on the engine's real time (state.lua REAL CLOCK; os.clock runs fast under Wine)
        pcall(St.sampleClock)
        local now = St.nowMs()
        if st.lastRunMs then
            local d = now - st.lastRunMs
            st.lastDeltaMs = d
            if d > st.maxDeltaMs then st.maxDeltaMs = d end
        end
        st.lastRunMs = now
        st.runs = st.runs + 1
        if U.trace then U.trace("loop", tag) end
        -- tick profiler (main.lua call(), stutter hunt 2026-10-14): whole-loop spans + the gap between two runs of
        -- the loop (a gap far over its period = a long game frame: a hitch), only while _G.SWGRCouch_prof is set
        local prof = _G.SWGRCouch_prof and St.preciseMs or nil
        local t0 = prof and prof() or nil
        -- couch-racegc: collector cycles (gctune's sentinel) during this loop run
        local gt = prof and package.loaded.gctune or nil
        local c0 = gt and gt.cycleCount and gt.cycleCount() or nil
        -- St.loopSeq: one id per loop run (util.lua's per-run U.localPlayers cache), nil outside loop runs
        loopSeqN = loopSeqN + 1
        St.loopSeq = loopSeqN
        local ok, e = xpcall(fn, debug.traceback)
        St.loopSeq = nil
        if t0 then
            local t1 = prof()
            if t1 then
                local D = _G.SWGRCouch_profData or {}
                _G.SWGRCouch_profData = D
                local k = "loop:" .. tostring(tag)
                local p = D[k] or { n = 0, sum = 0, max = 0, over2 = 0, phase = {}, gapN = 0, gap60 = 0, gap100 = 0, gapMax = 0 }
                D[k] = p
                local d = t1 - t0
                p.n, p.sum = p.n + 1, p.sum + d
                if d > p.max then p.max = d end
                if d > 2 then p.over2 = p.over2 + 1; p.phase[St.phase or "?"] = (p.phase[St.phase or "?"] or 0) + 1 end
                if c0 and gt.cycleCount() ~= c0 then
                    p.cyc = (p.cyc or 0) + 1
                    if St.phase == "RACING" and d > (p.rcycMax or 0) then p.rcycMax = d end
                end
                if St.phase == "RACING" then
                    p.rn, p.rsum = (p.rn or 0) + 1, (p.rsum or 0) + d
                    if d > (p.rmax or 0) then p.rmax = d end
                    if p.lastT0 and t0 - p.lastT0 > 60 then p.rgap60 = (p.rgap60 or 0) + 1 end
                end
                if p.lastT0 then
                    local g = t0 - p.lastT0
                    p.gapN = p.gapN + 1
                    if g > 60 then p.gap60 = p.gap60 + 1 end
                    if g > 100 then p.gap100 = p.gap100 + 1 end
                    if g > p.gapMax then p.gapMax = g end
                end
                p.lastT0 = t0
            end
        end
        if not ok then
            st.errors = st.errors + 1
            local every = cfg.LoopErrorLogEveryMs or 5000
            if st.lastErrLogMs == nil or now - st.lastErrLogMs >= every then
                U.err(tag, "loop error #%d (%d suppressed since last report): %s", st.errors, st.suppressed, tostring(e))
                st.lastErrLogMs = now
                st.suppressed = 0
            else
                st.suppressed = st.suppressed + 1
            end
        end
        -- return value is ignored by LoopInGameThreadWithDelay
    end
    local ok, r = pcall(LoopInGameThreadWithDelay, st.periodMs, wrapped)
    if not ok or type(r) ~= "number" then
        U.err("sched", "LoopInGameThreadWithDelay(%s, %d) failed: %s", tostring(tag), st.periodMs, tostring(r))
        return nil
    end
    st.handle = r
    handles[r] = tag
    return r
end

---------------------------------------------------------------------------------------------------- cancel
--- Cancel one handle created here (no-op for nil / already finished handles).
function sched.cancel(handle)
    if type(handle) ~= "number" then return false end
    local tag = handles[handle]
    handles[handle] = nil
    local okV, valid = pcall(IsValidDelayedActionHandle, handle)
    if okV and valid == true then
        local ok, r = pcall(CancelDelayedAction, handle)
        if not ok then
            U.warn("sched", "CancelDelayedAction(%d, %s): %s", handle, tostring(tag), tostring(r))
            return false
        end
        return r == true
    end
    return false
end

--- Cancel every handle this module created (ModRef.OnUnload).
function sched.cancelAll()
    local list = {}
    for h in pairs(handles) do list[#list + 1] = h end
    for i = 1, #list do sched.cancel(list[i]) end
    handles = {}
end

---------------------------------------------------------------------------------------------------- diag
--- Copy of loop timing/error stats: tag -> {runs, errors, periodMs, lastDeltaMs, maxDeltaMs}.
function sched.stats()
    local out = {}
    for tag, s in pairs(loopStats) do
        out[tag] = { runs = s.runs, errors = s.errors, periodMs = s.periodMs, lastDeltaMs = s.lastDeltaMs,
                     maxDeltaMs = s.maxDeltaMs }
    end
    return out
end

--- Number of live handles (diag).
function sched.handleCount()
    local n = 0
    for _ in pairs(handles) do n = n + 1 end
    return n
end

return sched
