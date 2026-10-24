-- SWGRCouch / trail.lua  (couch-fix75, player report #8, 2026-10-24)
-- A SHORT SESSION TRAIL that survives a crash and the next game start: Mods/SWGRCouch/session-trail.txt.
-- WHY: UE4SS truncates UE4SS.log at every game start. Players who see "Fatal Error" and restart the game (#8: "after
-- several races, a Fatal Error ... campaign progress was still there after restarting") have lost the only log of the
-- crashed session by the time they report it. This file keeps what triage needs from it: the start banner (mod version,
-- the native input filter's game build), every phase change with its map, each world's class pin count (AUTO-152), and
-- the session's first WARN / ERROR lines. At the next start the old trail moves to session-trail-prev.txt (rewritten in
-- place, no delete: settings.lua's rule), so the CRASHED session's trail is the -prev file after one restart and both
-- files are worth sending. Every line is appended and the file closed at once (a crash loses nothing written before).
-- Bounded: cfg.TrailMaxLines (default 3000) lines per session, of which at most cfg.TrailMaxWarnLines (300) WARN /
-- ERROR lines, each cut at 300 characters. cfg.SessionTrail = false turns it off. Writes only on events (phase changes,
-- worlds, warnings): nothing per tick.

local C   = require("consts")
local cfg = require("config")
local St  = require("state")
local U   = require("util")

local M = {}
local TAG = "trail"
M.FILE, M.PREV = "session-trail.txt", "session-trail-prev.txt"

local S = { path = nil, lines = 0, warns = 0, full = false, broken = nil, started = false }
M._S = S

local function maxLines() return tonumber(cfg.TrailMaxLines) or 3000 end
local function maxWarns() return tonumber(cfg.TrailMaxWarnLines) or 300 end

local function dir()
    local ok, d = pcall(function() return U.mod("settings").modDir() end)
    if ok and type(d) == "string" and d ~= "" then return d end
    return nil
end

local function stamp()
    local ok, s = pcall(os.date, "%H:%M:%S")
    return ok and s or "?"
end

local function append(line)
    if not S.path or S.broken then return false end
    if S.lines >= maxLines() then
        if not S.full then
            S.full = true
            local f = io.open(S.path, "a")
            if f then f:write(stamp(), " [trail] FULL: ", tostring(maxLines()), " lines, nothing more this session\n"); f:close() end
        end
        return false
    end
    local f, err = io.open(S.path, "a")
    if not f then S.broken = tostring(err); return false end
    f:write(stamp(), " ", line, "\n")
    f:close()
    S.lines = S.lines + 1
    return true
end

--- one line of the trail (no-op when off / not started)
function M.note(fmt, ...)
    if not S.started then return end
    local s = fmt
    if select("#", ...) > 0 then
        local ok, r = pcall(string.format, fmt, ...)
        s = ok and r or tostring(fmt)
    end
    append(tostring(s))
end

-- util.lua's logger hands every WARN / ERROR line here (U.trailHook)
local function onWarn(tag, level, msg)
    if not S.started or S.warns >= maxWarns() then return end
    S.warns = S.warns + 1
    local s = tostring(msg)
    if #s > 300 then s = s:sub(1, 300) .. "..." end
    append("[" .. tostring(tag) .. "] " .. tostring(level) .. s)
    if S.warns == maxWarns() then append("[trail] WARN/ERROR cap reached (" .. maxWarns() .. "): later ones are in UE4SS.log only") end
end

--- the previous session's trail -> session-trail-prev.txt; a fresh trail with the banner
function M.init()
    if cfg.SessionTrail == false or S.started then return end
    local d = dir()
    if not d then return end
    S.path = d .. "/" .. M.FILE
    local old = nil
    local f = io.open(S.path, "r")
    if f then old = f:read("a"); f:close() end
    if old and old ~= "" then
        local p = io.open(d .. "/" .. M.PREV, "w")
        if p then p:write(old); p:close() end
    end
    local w, err = io.open(S.path, "w")
    if not w then S.broken = tostring(err); return end
    local okD, day = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    w:write(string.format("%s SWGRCouch %s session trail (the previous session: %s)\n", okD and day or "?",
        tostring(C.VERSION), M.PREV))
    w:close()
    S.started = true
    S.lines = 1
    U.trailHook = onWarn
    St.on("phase", TAG, function(new, old)
        local map = ""
        pcall(function() map = tostring(U.levelName() or "") end)
        M.note("phase %s -> %s%s", tostring(old), tostring(new), map ~= "" and ("  map=" .. map) or "")
    end)
    St.on("world", TAG, function()
        local ok, ps = pcall(U.pinStats)
        if ok and type(ps) == "table" then
            M.note("world #%s: class pins %s/%s%s", tostring(St.worldGen), tostring(ps.pinned), tostring(ps.cap),
                ps.capped and " CAP REACHED" or (ps.broken and (" pins broken: " .. tostring(ps.broken)) or ""))
        end
    end)
    St.on("leaving", TAG, function(why) M.note("leaving the race (%s)", tostring(why)) end)
    U.log(TAG, "session trail: %s (previous session: %s) (V-TRAIL-01)", S.path, M.PREV)
end

function M.stats() return { lines = S.lines, warns = S.warns, full = S.full, broken = S.broken, path = S.path } end

return M
