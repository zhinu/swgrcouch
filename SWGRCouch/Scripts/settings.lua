-- SWGRCouch / settings.lua  (G1 Core)
-- The user's choices, persisted as "Key = value" lines in <ModDir>/settings.txt with plain io
-- (io/os exist in mod Lua states [ARCH §0]). Defaults and types come from config.Defaults.
-- Unknown keys are kept verbatim on save; a missing file is created from the defaults.
-- The file is rewritten in place with io.open(path, "w"): no temp file, no delete (§0 rule 10).
-- No game calls: safe on any thread.

local cfg = require("config")
local St  = require("state")
local U   = require("util")

local settings = {}

local DEFAULTS = cfg.Defaults
-- Fixed key order for writing the file
local ORDER = { "Layout2P", "SplitGraphics", "TakedownCams", "NameTags", "KeyboardIsP1", "NetMode",
                "JoinAddress", "Port", "LastRaceArchetype", "LastRaceGameMode", "LastRacePlanet", "LastRaceTrack",
                "LastRaceBuild", "LastRaceDebugBuild", "LastRaceCondition", "LastRaceMaxRacers", "LastRaceVehicles",
                "LastRaceRacers", "OpponentTier", "PlayMode", "OpponentMatch", "RunPick",
                "Name1", "Name2", "Name3", "Name4", "CouchMysteryTeam",
                "CouchEconomy" }                                     -- couch-fix35: COUCH CAMPAIGN rules
-- Enumerated string keys: allowed values (a value outside the list is refused / replaced by the default)
settings.ALLOWED = {
    Layout2P      = { "top-bottom", "side-by-side" },
    SplitGraphics = { "auto", "performance", "quality", "off" },
    NetMode       = { "offline", "host", "join" },
    PlayMode      = { "quick", "custom" },
    RunPick       = { "qualifier", "league", "kestar", "sprint" },
    CouchMysteryTeam = { "greyed", "allowed" },            -- couch-fix39 (OPTIONS > COUCH CAMPAIGN)
    CouchEconomy  = { "own", "best" },                               -- couch-fix35 (Q1)
}
-- couch-fix36: OPTIONS > COUCH CAMPAIGN (couchpenalty.lua)
settings.ALLOWED.CouchBrokerPenalty = { "both", "owner" }
ORDER[#ORDER + 1] = "CouchBrokerPenalty"
-- couch-fix75 (player request #12): OPTIONS > COUCH CAMPAIGN > Friendly fire (friendly.lua)
settings.ALLOWED.CouchFriendlyFire = { "on", "off" }
ORDER[#ORDER + 1] = "CouchFriendlyFire"
-- couch-fix41: retired keys - an old settings.txt line is dropped quietly (never kept, never written back).
-- CouchBackerTokens (couch-fix36's backer token rule): solo parity, an unhappy backer never costs a League Token.
settings.RETIRED = { CouchBackerTokens = true }
-- A config_user.lua `Defaults` override has the right type but may be outside ALLOWED (`NetMode = "Host"`): it would
-- become a default that coerce() falls back to and every save writes back. Replaced by the built-in default here.
for key, list in pairs(settings.ALLOWED) do
    local v, ok = DEFAULTS[key], false
    for i = 1, #list do if list[i] == v then ok = true; break end end
    if not ok then
        local builtin = type(cfg.DefaultsBuiltin) == "table" and cfg.DefaultsBuiltin[key] or nil
        local okB = false
        for i = 1, #list do if list[i] == builtin then okB = true; break end end
        local repl = okB and builtin or list[1]
        U.warn("settings", "config Defaults.%s = %q is not one of: %s; using %q", key, tostring(v),
            table.concat(list, ", "), repl)
        DEFAULTS[key] = repl
    end
end

local COMMENTS = {
    Layout2P      = "top-bottom | side-by-side",
    SplitGraphics = "auto | performance | quality | off",
    NetMode       = "offline | host | join",
    JoinAddress   = "host address used by CONNECT (WireGuard address between homes)",
    Port          = "host port; a host on another port than 7777 must be started with -port=<n>",
    LastRaceMaxRacers = "RACE SETUP grid size, humans included (0 = the class limit: 12 speeders / 8 podracers)",
    LastRaceVehicles  = "RACE SETUP picks per player: <pnum>=<PRE_* preset>@<build path>;...",
    LastRaceRacers    = "RACERS step per pad: <ControllerId>=<pilot>@<preset>@<loadout>;...",
    OpponentTier      = "RACE SETUP opponents (speeders): 1 = TIER 1 [0%] (weakest) .. 6 = TIER 6 [58%]",
    OpponentMatch     = "CUSTOM opponents: true = the AI get the players' average build (MATCH THE PLAYERS)",
    PlayMode          = "quick (QUICK RACE: everybody on the Opponents tier, no perks) | custom (perks per kart)",
    RunPick           = "FREE MODE GALAXY RUN preset: qualifier | league | kestar | sprint (RunLength arms the next launch)",
    CouchBrokerPenalty = "couch campaign, a guest's Broker penalty: both | owner (OPTIONS > COUCH CAMPAIGN)",
    CouchFriendlyFire = "couch campaign: on (abilities hit teammates, as in solo) | off (no Ion Bolt / Blast / Shockwave on a teammate) (OPTIONS > COUCH CAMPAIGN)",
    CouchMysteryTeam  = "greyed | allowed: a guest may take a mystery choice with a TEAM effect (OPTIONS > COUCH CAMPAIGN)",
    CouchEconomy      = "COUCH CAMPAIGN: own (P1's wallet / rounds follow his own place) | best (the best result carries everyone)",
    Name1             = "custom player names (OPTIONS > PLAYER NAMES; empty = default: P1's own name, 'Player <n>')",
}

-- Custom player names (Name1..Name4): one line of printable text, runs of blanks collapsed, at most
-- cfg.PlayerNameMaxChars characters (UTF-8 aware). `""`, `''` and `default` mean "no custom name" (the console
-- cannot pass an empty value: 'couch set Name2 default').
settings.NAME_KEYS = { Name1 = 1, Name2 = 2, Name3 = 3, Name4 = 4 }
function settings.cleanName(v, maxChars)
    local s = tostring(v or "")
    s = s:gsub("%c", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == '""' or s == "''" or s:lower() == "default" then return "" end
    local max = math.tointeger(tonumber(maxChars) or tonumber(cfg.PlayerNameMaxChars) or 16) or 16
    if max < 1 then max = 1 end
    if utf8.len(s) == nil then s = s:gsub("[\128-\255]", "?") end    -- not UTF-8: keep it printable ASCII
    if utf8.len(s) > max then s = s:sub(1, utf8.offset(s, max + 1) - 1):gsub(" $", "") end
    return s
end

local values = {}        -- key -> typed value (only keys of DEFAULTS)
local extraLines = {}    -- unknown "Key = value" lines, verbatim, in file order
local loaded = false
local dirCache, pathCache = nil, nil

---------------------------------------------------------------------------------------------------- paths
local function fileExists(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

--- <ModDir> with forward slashes, no trailing slash.  VERIFY(V-CORE-03): settings.txt is created there.
function settings.modDir()
    if dirCache then return dirCache end
    -- 1) this chunk's name: "@<abs path>/Scripts/settings.lua" (UE4SS custom searcher, LuaMod.cpp:1043)
    local ok, info = pcall(debug.getinfo, 1, "S")
    local src = ok and info and info.source or ""
    if src:sub(1, 1) == "@" then
        local p = src:sub(2):gsub("\\", "/")
        local dir = p:match("^(.*)/[Ss][Cc][Rr][Ii][Pp][Tt][Ss]/settings%.lua$")
        if dir and dir ~= "" then dirCache = dir; return dir end
    end
    -- 2) package.path entry "<...>/Mods/SWGRCouch/Scripts/?.lua"
    local pp = (package and package.path or ""):gsub("\\", "/")
    for entry in pp:gmatch("[^;]+") do
        local scripts = entry:match("^(.-/Mods/SWGRCouch/[Ss]cripts)/%?%.lua$")
        if scripts then
            dirCache = scripts:gsub("/[Ss]cripts$", "")
            return dirCache
        end
    end
    -- 3) relative to the working directory (Binaries/Win64): try both UE4SS layouts
    for _, cand in ipairs({ "ue4ss/Mods/SWGRCouch", "Mods/SWGRCouch" }) do
        if fileExists(cand .. "/Scripts/main.lua") or fileExists(cand .. "/scripts/main.lua") then
            U.warn("settings", "mod directory from relative fallback: %s", cand)
            dirCache = cand
            return cand
        end
    end
    U.warn("settings", "mod directory not found; using relative 'Mods/SWGRCouch'")
    dirCache = "Mods/SWGRCouch"
    return dirCache
end

function settings.path()
    if not pathCache then pathCache = settings.modDir() .. "/settings.txt" end
    return pathCache
end

---------------------------------------------------------------------------------------------------- typing
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function allowed(key, v)
    local list = settings.ALLOWED[key]
    if not list then return true end
    for i = 1, #list do if list[i] == v then return true end end
    return false
end

--- Convert v (any type, strings from the file or the console) to the type of key's default.
--- Returns value or nil, errorText.
local function coerce(key, v)
    local def = DEFAULTS[key]
    local t = type(def)
    if t == "boolean" then
        if type(v) == "boolean" then return v end
        local s = trim(tostring(v)):lower()
        if s == "true" or s == "1" or s == "on" or s == "yes" then return true end
        if s == "false" or s == "0" or s == "off" or s == "no" then return false end
        return nil, "expected true/false"
    elseif t == "number" then
        local n = tonumber(type(v) == "string" and trim(v) or v)
        if not n then return nil, "expected a number" end
        if math.type(def) == "integer" then
            local i = math.tointeger(n)
            if not i then return nil, "expected an integer" end
            return i
        end
        return n
    elseif t == "string" then
        if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
            return nil, "expected a string"
        end
        local s = trim(tostring(v)):gsub("[\r\n]", " ")
        if settings.NAME_KEYS[key] then s = settings.cleanName(s) end
        if not allowed(key, s) then
            return nil, "allowed: " .. table.concat(settings.ALLOWED[key], ", ")
        end
        return s
    end
    return nil, "unknown key"
end

local function resetToDefaults()
    values = {}
    for k, v in pairs(DEFAULTS) do values[k] = v end
end
resetToDefaults()

---------------------------------------------------------------------------------------------------- save / load
local function serialise(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    return tostring(v)
end

--- Rewrite settings.txt in place. Returns true on success.
function settings.save()
    local path = settings.path()
    local lines = {
        "# SWGRCouch user settings. Edit while the game is closed, or use the Lobby / console 'couch set <Key> <value>'.",
        "# Format: Key = value   (bools true/false; '#' starts a comment line). Unknown keys are kept.",
    }
    for _, k in ipairs(ORDER) do
        -- a key without a default has no type and no value: never written as "<Key> = nil"
        if DEFAULTS[k] ~= nil then
            if COMMENTS[k] then lines[#lines + 1] = "# " .. k .. ": " .. COMMENTS[k] end
            lines[#lines + 1] = k .. " = " .. serialise(values[k])
        end
    end
    -- keys present in DEFAULTS but missing from ORDER (future additions)
    local inOrder = {}
    for _, k in ipairs(ORDER) do inOrder[k] = true end
    local rest = {}
    for k in pairs(DEFAULTS) do if not inOrder[k] then rest[#rest + 1] = k end end
    table.sort(rest)
    for _, k in ipairs(rest) do lines[#lines + 1] = k .. " = " .. serialise(values[k]) end
    for i = 1, #extraLines do lines[#lines + 1] = extraLines[i] end

    local f, e = io.open(path, "w")
    if not f then
        U.err("settings", "cannot write %s: %s", path, tostring(e))
        return false
    end
    local ok, we = pcall(function() f:write(table.concat(lines, "\n"), "\n") end)
    f:close()
    if not ok then
        U.err("settings", "write %s failed: %s", path, tostring(we))
        return false
    end
    return true
end

--- Read settings.txt (creates it from the defaults when missing). Returns true when the file was read or
--- created. Bad values are logged and replaced by the default.
function settings.load()
    resetToDefaults()
    extraLines = {}
    loaded = true
    local path = settings.path()
    local f = io.open(path, "r")
    if not f then
        U.log("settings", "%s not found: creating it from the defaults", path)
        return settings.save()
    end
    local n, bad = 0, 0
    local first = true
    for raw in f:lines() do
        local line = raw:gsub("\r$", "")
        if first then line = line:gsub("^\239\187\191", ""); first = false end   -- UTF-8 BOM
        local s = trim(line)
        if s ~= "" and s:sub(1, 1) ~= "#" and s:sub(1, 1) ~= ";" then
            local k, v = s:match("^([%w_]+)%s*=%s*(.-)$")
            if not k then
                U.warn("settings", "ignored line: %s", s)
            elseif DEFAULTS[k] ~= nil then
                local cv, why = coerce(k, v)
                if cv == nil then
                    bad = bad + 1
                    U.warn("settings", "%s = '%s' rejected (%s); using default %s", k, v, why, serialise(DEFAULTS[k]))
                else
                    values[k] = cv
                    n = n + 1
                end
            else
                -- unknown key: kept verbatim, once (an ORDER key without a default is dropped, never duplicated)
                local isOrderKey = false
                for i = 1, #ORDER do if ORDER[i] == k then isOrderKey = true; break end end
                local dup = false
                for i = 1, #extraLines do if extraLines[i] == s then dup = true; break end end
                if settings.RETIRED[k] then
                    U.log("settings", "%s is retired: line dropped", k)
                elseif isOrderKey then
                    U.warn("settings", "%s has no default in config.Defaults: line dropped", k)
                elseif not dup then
                    extraLines[#extraLines + 1] = s
                end
            end
        end
    end
    f:close()
    U.log("settings", "loaded %d keys from %s%s", n, path, bad > 0 and (" (" .. bad .. " rejected)") or "")
    return true
end

---------------------------------------------------------------------------------------------------- access
local function ensureLoaded()
    if not loaded then settings.load() end
end

--- Current value (typed). Unknown keys return nil.
function settings.get(key)
    ensureLoaded()
    return values[key]
end

--- Set a known key (value coerced to the default's type, enumerated keys checked), save at once and emit
--- "settings"(key, value) when it changed. Returns true on success, false + reason on refusal.
function settings.set(key, value)
    ensureLoaded()
    if DEFAULTS[key] == nil then
        U.warn("settings", "set: unknown key '%s'", tostring(key))
        return false, "unknown key"
    end
    local v, why = coerce(key, value)
    if v == nil then
        U.warn("settings", "set %s = '%s' refused (%s)", key, tostring(value), why)
        return false, why
    end
    if values[key] == v then return true end
    values[key] = v
    settings.save()
    U.log("settings", "%s = %s", key, serialise(v))
    St.emit("settings", key, v)
    return true
end

--- Advance an enumerated value to the next entry of valuesArray (wraps; unknown current -> first).
function settings.cycle(key, valuesArray)
    ensureLoaded()
    local list = valuesArray or settings.ALLOWED[key]
    if type(list) ~= "table" or #list == 0 then return values[key] end
    local cur, nextIdx = values[key], 1
    for i = 1, #list do
        if list[i] == cur then nextIdx = (i % #list) + 1; break end
    end
    settings.set(key, list[nextIdx])
    return values[key]
end

--- Flip a boolean key; returns the new value.
function settings.toggle(key)
    ensureLoaded()
    if type(DEFAULTS[key]) ~= "boolean" then
        U.warn("settings", "toggle: '%s' is not a boolean key", tostring(key))
        return values[key]
    end
    settings.set(key, not values[key])
    return values[key]
end

--- Copy of all known values (diag).
function settings.all()
    ensureLoaded()
    local out = {}
    for k, v in pairs(values) do out[k] = v end
    return out
end

return settings
