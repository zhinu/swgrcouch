-- SWGRCouch · keyq.lua (0.10.0): cross-thread key mailbox for every UE4SS keybind of the mod.
--
-- RegisterKeyBind callbacks run on UE4SS's event-loop thread, while the game thread may be inside a UE4SS binding
-- (an obj:Method() __index lambda, a property read, a UFunction call) on the shared hook lua_State. Any UE4SS call made
-- from the keybind thread interleaves with it: 0.9.x's keybind bodies did sched.run -> ExecuteInGameThread =
-- lua_xmove + luaL_ref onto that state, which made the game thread's lua_rawget read the interned string
-- "GetSelected" as a Table (crash_2026_10_08_13_27_33, AV in ltable.c getgeneric; notes/research/
-- ue4ss-hook-thread-gc.md §3.1, upstream RE-UE4SS issue #1445). Native hook, loop and one-shot callbacks run without
-- UE4SS's m_thread_actions_mutex, and LuaRaw's process-wide lua_lock is released around every C call and allocation.
--
-- Rule (binding): on the event-loop thread run pure Lua only, allocation-free: the callback below increments an
-- existing integer field (GETUPVAL/GETTABLE/ADDI/SETTABLE, no allocation, no C call, so the lock is never released
-- inside it). The FAST loop drains the counters on the game thread (main.lua fastTick, every phase) and runs the bound
-- functions there. Bind only from main.lua's load (lobby.init / keys.init): RegisterKeyBind binds the callback to the
-- calling lua_State, which is the hook thread when called from a game-thread callback.
local U = require("util")

local M = {}
local seq, done, run, order = {}, {}, {}, {}
local MAX_PER_TICK = 3

--- key: Key.* value; mods: nil or {ModifierKey.*}; label: unique name (two keys may share one label, e.g. Enter and
--- Space both "lobby.accept": both bump the same counter); fn: runs on the game thread once per press.
function M.bind(key, mods, label, fn)
    if key == nil or type(RegisterKeyBind) ~= "function" then return false end
    if seq[label] == nil then
        seq[label], done[label] = 0, 0
        order[#order + 1] = label
    end
    run[label] = fn
    local cb = function() seq[label] = seq[label] + 1 end      -- event-loop thread: this line only
    local ok, err
    if mods then ok, err = pcall(RegisterKeyBind, key, mods, cb) else ok, err = pcall(RegisterKeyBind, key, cb) end
    if not ok then U.err("keyq", "RegisterKeyBind %s failed: %s", label, tostring(err)) end
    return ok
end

--- Game thread (FAST loop, every phase): each bound function once per press, at most MAX_PER_TICK per tick.
function M.drain()
    for i = 1, #order do
        local label = order[i]
        local n = seq[label]
        local d = n - done[label]
        if d > 0 then
            done[label] = n                      -- single writer per field: no lost press, no read-modify-write race
            if d > MAX_PER_TICK then d = MAX_PER_TICK end
            local fn = run[label]
            for _ = 1, d do U.try("key:" .. label, fn) end
        end
    end
end

function M.count() return #order end

return M
