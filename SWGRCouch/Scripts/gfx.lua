-- gfx.lua (G5): split-screen graphics preset and the takedown-camera setting, both saved before the first change
-- of a race and restored in the front end.                                              [ARCH 1.6, ANALYSIS 6]
--
-- cfg.GfxApplyMode (config.lua, default "console"):
--   "console"     : every cvar through ExecuteConsoleCommand (ARCHITECTURE contract). A console write has
--                   SetByConsole priority, so until the game restarts the in-game graphics menu can no longer
--                   change any cvar the mod touched, even after restore() (UE cvar priority rule).
--   "usersettings": the sg.* scalability groups go through the GameUserSettings setters + ApplyNonResolutionSettings()
--                   (scalability priority, like the in-game graphics menu), restored the same way; only cvars
--                   without a setter (r.*) use the console. RISK: the levels live in the GameUserSettings object, so
--                   a game-side ApplySettings/SaveSettings during a split race (pause-menu graphics settings, game
--                   exit) would write the split preset into the user's GameUserSettings.ini.
-- The mod itself never calls ApplySettings / SaveSettings.
-- The saved values survive a hot reload (Ctrl+F11) in UE4SS shared variables (persistShared / restoreShared).
--
-- Static facts (2026-10-06):
--   KSL:GetConsoleVariableFloatValue(Str VariableName) -> Float   (reflect-func-all; works for int cvars too)
--   KSL:ExecuteConsoleCommand(Object WorldContextObject, Str Command, Object SpecificPlayer)   via U.console
--   Every cvar of cfg.GfxPresets exists in the exe (work/strings/swgr.utf16.txt).
--   UEngine.GameUserSettings (reflect.tsv); UGfnUserSettings.TakedownCameras is a Bool [ARCH 0 HERE].
--   UGameUserSettings (reflect-func-all): Set<G>Quality(Int Value), Get<G>Quality() -> Int for G in
--   GlobalIllumination, Reflection, Shadow, VisualEffect, ViewDistance, PostProcessing, Texture, Foliage, Shading,
--   AntiAliasing; ApplyNonResolutionSettings() (no params).
-- The user's GameUserSettings.ini is never written: no ApplySettings/SaveSettings call anywhere. TakedownCameras (a live
-- GameUserSettings property in every mode) is given back on "leaving", and a pre/post hook around the game's own
-- SaveSettings / ApplySettings writes the user's value back for the duration of a game-side save (V-GFX-06).

local C = require("consts")
local cfg = require("config")
local settings = require("settings")
local St = require("state")
local U = require("util")
local UEHelpers = require("UEHelpers")

local M = {}
local TAG = "gfx"

local function G()
    St.gfx = St.gfx or { saved = nil, savedTakedown = nil, appliedViews = 0 }
    return St.gfx
end

-- "%g", always with a decimal point (a process locale with a decimal comma would break the cvar parse)
local function num(v)
    return (string.gsub(string.format("%g", v), ",", "."))
end

local function setCvar(name, value)
    -- VERIFY(V-GFX-01): cvars set from ExecuteConsoleCommand take effect and are restored the same way.
    -- VERIFY(V-GFX-04): a console write has SetByConsole priority: until the game restarts, the in-game graphics
    -- menu can no longer lower-priority-override a cvar written here, even after restore(). In "usersettings"
    -- mode this only concerns the r.* cvars of cfg.GfxPresets (no GameUserSettings setter); drop them from the
    -- preset if the graphics menu must stay fully usable after a split race.
    return U.console(name .. " " .. num(value))
end

-- sg.* cvar -> GameUserSettings group (Set<G>Quality / Get<G>Quality)
local SG_GROUP = {
    ["sg.GlobalIlluminationQuality"] = "GlobalIlluminationQuality",
    ["sg.ReflectionQuality"]         = "ReflectionQuality",
    ["sg.ShadowQuality"]             = "ShadowQuality",
    ["sg.EffectsQuality"]            = "VisualEffectQuality",
    ["sg.ViewDistanceQuality"]       = "ViewDistanceQuality",
    ["sg.PostProcessQuality"]        = "PostProcessingQuality",
    ["sg.TextureQuality"]            = "TextureQuality",
    ["sg.FoliageQuality"]            = "FoliageQuality",
    ["sg.ShadingQuality"]            = "ShadingQuality",
    ["sg.AntiAliasingQuality"]       = "AntiAliasingQuality",
}

local function applyMode()
    local m = cfg.GfxApplyMode
    if m == "console" or m == "usersettings" then return m end
    return "console"
end

local userSettings -- forward

-- Get<G>Quality() -> Int on the settings object; nil when unavailable.
local function usGet(s, group)
    local ok, v = pcall(function() return s["Get" .. group](s) end)
    if ok and type(v) == "number" then return math.floor(v) end
    return nil
end

local function usSet(s, group, v)
    local ok, err = pcall(function() s["Set" .. group](s, math.floor(v)) end) -- Set<G>Quality(Int Value)
    if not ok then U.logOnce("gfx.usset." .. group, TAG, "Set%s failed: %s", group, tostring(err)) end
    return ok
end

-- VERIFY(V-GFX-05): ApplyNonResolutionSettings (GfnUserSettingsPC may override it) pushes the groups to the
-- sg.* cvars without saving the ini and without side effects on the game's own menus.
-- Fallback: cfg.GfxApplyMode = "console".
local function usApply(s)
    local ok, err = pcall(function() s:ApplyNonResolutionSettings() end)
    if not ok then U.warn(TAG, "ApplyNonResolutionSettings failed: %s", tostring(err)) end
    return ok
end

function M.presetFor(nViews)
    local s = settings.get("SplitGraphics")
    local presets = cfg.GfxPresets or {}
    if s == "off" then return nil end
    if s == "auto" then
        if (nViews or 1) <= (cfg.GfxAutoQualityMaxViews or 2) then return presets.quality end
        return presets.performance
    end
    return presets[s]
end

-- The preset plus cfg.GfxSplitFixes (split-screen correctness values, applied even with SplitGraphics "off"); nil when
-- both are empty. A fresh table: the config tables are never written.
local function wantedFor(nViews)
    local p = M.presetFor(nViews)
    local fixes = cfg.GfxSplitFixes
    if type(fixes) ~= "table" or next(fixes) == nil then return p end
    local t = {}
    for k, v in pairs(p or {}) do t[k] = v end
    for k, v in pairs(fixes) do t[k] = v end
    return t
end

-- Write back saved values that are not part of `keep` (nil = all) and forget them.
-- g.saved = console cvars (name -> float), g.savedUS = scalability groups (sg name -> {group, level}).
-- Returns the count restored and whether a GameUserSettings group changed (ApplyNonResolutionSettings pending).
local function restoreCvars(keep)
    local g = G()
    local n, usDirty = 0, false
    if g.saved then
        for name, v in pairs(g.saved) do
            if not (keep and keep[name] ~= nil) then
                if U.try(TAG, setCvar, name, v) then n = n + 1 end
                g.saved[name] = nil
            end
        end
        if next(g.saved) == nil then g.saved = nil end
    end
    if g.savedUS then
        local s = userSettings()
        for name, rec in pairs(g.savedUS) do
            if not (keep and keep[name] ~= nil) then
                if s and usSet(s, rec.group, rec.level) then n = n + 1; usDirty = true end
                g.savedUS[name] = nil
            end
        end
        if next(g.savedUS) == nil then g.savedUS = nil end
    end
    return n, usDirty
end

function M.applyForViews(nViews)
    local g = G()
    nViews = nViews or 1
    if nViews < 2 then return end
    local p = wantedFor(nViews)
    -- a preset change mid-race (console `couch gfx`): values of the old preset go back first
    local _, usDirty = restoreCvars(p)
    local mode = applyMode()
    local s = (mode == "usersettings") and userSettings() or nil
    if mode == "usersettings" and not s then
        U.logOnce("gfx.nousmode", TAG, "GameUserSettings not found; GfxApplyMode 'usersettings' uses the console")
    end
    if p then
        local applied, viaUS = 0, 0
        for name, value in pairs(p) do
            local group = s and SG_GROUP[name] or nil
            local cur = group and usGet(s, group) or nil
            -- a group already saved through the console path (mode switched mid-race) stays on that path
            if group and cur ~= nil and not (g.saved and g.saved[name] ~= nil) then
                g.savedUS = g.savedUS or {}
                if g.savedUS[name] == nil then g.savedUS[name] = { group = group, level = cur } end
                if usSet(s, group, value) then applied, viaUS, usDirty = applied + 1, viaUS + 1, true end
            else
                g.saved = g.saved or {}
                if g.saved[name] == nil then
                    local ok, v = U.try(TAG, U.cvarFloat, name)
                    if ok and type(v) == "number" then g.saved[name] = v end
                end
                if U.try(TAG, setCvar, name, value) then applied = applied + 1 end
            end
        end
        U.log(TAG, "split preset '%s' + split fixes for %d views: %d values applied (%d via GameUserSettings, mode %s)",
            tostring(settings.get("SplitGraphics")), nViews, applied, viaUS, mode)
    else
        U.log(TAG, "split graphics off: user settings kept")
    end
    if usDirty then
        local us = s or userSettings()
        if us then usApply(us) end
    end
    if settings.get("TakedownCams") == false then
        M.setTakedownCameras(false)
    elseif g.savedTakedown ~= nil then
        M.setTakedownCameras(g.savedTakedown) -- setting turned back on mid-race: give the user's value back
    end
    g.appliedViews = nViews
end

userSettings = function()
    local eng = UEHelpers.GetEngine()
    if not U.ok(eng) then return nil end
    local s = eng.GameUserSettings -- the GfnUserSettingsPC instance [API 15 #8]
    if U.ok(s) then return s end
    return nil
end

function M.setTakedownCameras(on)
    local g = G()
    local s = userSettings()
    if not s then
        U.logOnce("gfx.nogus", TAG, "GameUserSettings not found; takedown cameras unchanged")
        return false
    end
    local cur = s.TakedownCameras
    if type(cur) ~= "boolean" then
        U.logOnce("gfx.notbool", TAG, "GameUserSettings.TakedownCameras is not a Bool (%s); unchanged", type(cur))
        return false
    end
    if g.savedTakedown == nil then g.savedTakedown = cur end
    -- VERIFY(V-GFX-02): the game reads TakedownCameras live (no takedown cut-away while false).
    s.TakedownCameras = (on == true)
    g.takedownApplied = (on == true)
    U.log(TAG, "TakedownCameras %s -> %s", tostring(cur), tostring(on == true))
    return true
end

-- Gives the user's TakedownCameras back now (the cvars stay): on "leaving", so a game-side save after the race (menu,
-- game exit from the results) never sees the split value. The next race's applyForViews sets it again.
function M.restoreTakedown(why)
    local g = G()
    if g.savedTakedown == nil then return end
    local s = userSettings()
    if s and type(s.TakedownCameras) == "boolean" then
        s.TakedownCameras = g.savedTakedown
        U.log(TAG, "TakedownCameras restored to %s (%s)", tostring(g.savedTakedown), tostring(why))
    end
    g.savedTakedown, g.takedownApplied = nil, nil
end

-- Guard around a game-side GameUserSettings:SaveSettings / ApplySettings (ApplySettings saves too) while the split
-- value is applied: the pre-hook writes the user's value back, the post-hook re-applies the split value, so the
-- user's GameUserSettings.ini (or the Gfn settings save) never stores the split value.
-- VERIFY(V-GFX-06): changing an option in the pause menu during a split race logs "takedown guard" (the game calls
-- these through ProcessEvent / the BP VM; a direct C++ call would bypass the hooks - then only the "leaving"
-- restore limits the window), and GameUserSettings.ini keeps the user's TakedownCameras.
local function guardPre()
    local g = G()
    g.guardDepth = (g.guardDepth or 0) + 1             -- nested calls (ApplySettings -> SaveSettings) act once
    if g.guardDepth ~= 1 or g.savedTakedown == nil or g.takedownApplied == nil then return end
    local s = userSettings()
    if not (s and type(s.TakedownCameras) == "boolean") then return end
    s.TakedownCameras = g.savedTakedown
    U.log(TAG, "takedown guard: user value %s written back for a game-side settings save", tostring(g.savedTakedown))
end

local function guardPost()
    local g = G()
    if (g.guardDepth or 0) <= 0 then g.guardDepth = 0; return end
    g.guardDepth = g.guardDepth - 1
    if g.guardDepth > 0 or g.savedTakedown == nil or g.takedownApplied == nil then return end
    local s = userSettings()
    if s and type(s.TakedownCameras) == "boolean" then s.TakedownCameras = g.takedownApplied end
end

-- present.lua (2026-10-07): intro / cinematic / results phases run as ONE full-screen view. The split preset's render
-- scale (r.ScreenPercentage 50) would make those full-screen cinematics blurry, so the cvars of cfg.GfxSingleViewCvars
-- (default { "r.ScreenPercentage" }; false = off) get the user's saved value back while the view is single and the
-- preset value again when the views split. The other preset values stay (sg.* / Lumen / VSM toggles can hitch).
-- VERIFY(V-GFX-07): no visible hitch when the views split at the countdown.
function M.onViewModeChanged(single)
    local g = G()
    if not g.saved or (g.appliedViews or 0) < 2 then return end
    local list = cfg.GfxSingleViewCvars
    if list == false then return end
    if type(list) ~= "table" then list = { "r.ScreenPercentage" } end
    local p = M.presetFor(g.appliedViews)
    if not p then return end
    local n = 0
    for _, name in ipairs(list) do
        local user, split = g.saved[name], p[name]
        if user ~= nil and split ~= nil then
            if U.try(TAG, setCvar, name, single and user or split) then n = n + 1 end
        end
    end
    g.singleView = (single == true)
    if n > 0 then U.log(TAG, "%s view: %d render value(s) set to the %s value", single and "single" or "split", n,
        single and "user's" or "split preset") end
end

function M.restore()
    local g = G()
    local n, usDirty = restoreCvars(nil)
    if usDirty then
        local s = userSettings()
        if s then usApply(s) end
    end
    if g.savedTakedown ~= nil then
        local s = userSettings()
        if s and type(s.TakedownCameras) == "boolean" then
            s.TakedownCameras = g.savedTakedown
            U.log(TAG, "TakedownCameras restored to %s", tostring(g.savedTakedown))
        end
    end
    if n > 0 then U.log(TAG, "restored %d cvars", n) end
    g.saved, g.savedUS, g.savedTakedown, g.appliedViews, g.takedownApplied = nil, nil, nil, 0, nil
end

-- Hot reload: the values to restore (and the takedown flag) survive as one string each. OnUnload is not on the
-- game thread: only Lua values are read here.
function M.persistShared(put)
    local g = G()
    local parts = {}
    for name, v in pairs(g.saved or {}) do parts[#parts + 1] = name .. "=" .. num(v) end
    put("gfx.saved", table.concat(parts, ";"))
    parts = {}
    for name, rec in pairs(g.savedUS or {}) do parts[#parts + 1] = name .. "=" .. rec.group .. ":" .. tostring(rec.level) end
    put("gfx.savedUS", table.concat(parts, ";"))
    if g.savedTakedown == nil then put("gfx.savedTakedown", "") else put("gfx.savedTakedown", tostring(g.savedTakedown)) end
end

function M.restoreShared(get)
    local g = G()
    local n = 0
    local v = get("gfx.saved")
    if type(v) == "string" then
        for name, val in v:gmatch("([^;=]+)=([^;]+)") do
            local f = tonumber(val)
            if f then g.saved = g.saved or {}; g.saved[name] = f; n = n + 1 end
        end
    end
    v = get("gfx.savedUS")
    if type(v) == "string" then
        for name, group, lvl in v:gmatch("([^;=]+)=([^;:]+):([^;]+)") do
            local l = tonumber(lvl)
            if l then g.savedUS = g.savedUS or {}; g.savedUS[name] = { group = group, level = l }; n = n + 1 end
        end
    end
    v = get("gfx.savedTakedown")
    if v == "true" then g.savedTakedown = true elseif v == "false" then g.savedTakedown = false end
    if g.savedTakedown ~= nil then g.takedownApplied = false end -- the mod only ever applies false in a split race
    if n > 0 or g.savedTakedown ~= nil then
        U.log(TAG, "hot reload: %d saved graphics value(s) restored (restored to the game in the front end)", n)
    end
end

local initDone = false
local RACE = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }

-- Idempotent. ARCHITECTURE 4.2 main's init list does not call gfx.init(), so the module also calls it once
-- at require time (it only registers an event listener; no game call).
function M.init()
    if initDone then return end
    initDone = true
    G()
    St.on("phase", TAG, function(new, old)
        -- Same edge as split.lua: any first race phase. The MAIN poll may skip LOADING (grid already there on its
        -- first look: seamless travel, a client receiving a replicated grid, a rejoin into a running race, a hot
        -- reload mid-race). Values already saved (restoreShared) are never overwritten by applyForViews.
        if RACE[new] and not RACE[old] then
            -- VERIFY(V-GFX-03): frame time per preset (MangoHud); tune cfg.GfxPresets.
            -- St.race.singleView: join's "race_enter" guard (emitted before "phase") handed the guests' cars to the AI
            -- and the race keeps one view: no split-screen preset, takedown cameras untouched.
            local n = (St.race.singleView == true) and 1 or #U.localPlayers()
            pcall(function() n = U.mod("split").viewCount() end)   -- couch-livefix r2: dormant players hold no view
            M.applyForViews(n)
        elseif new == "FRONTEND" then
            M.restore()
        end
    end)
    -- the race is left: the user's takedown flag goes back at once (see restoreTakedown); cvars stay until FRONTEND
    St.on("leaving", TAG, function() U.try(TAG, M.restoreTakedown, "leaving") end)
    -- net's servertravel watchdog restored the race: re-apply the split takedown value
    St.on("leaving_cancelled", TAG, function()
        if (G().appliedViews or 0) >= 2 and St.race.singleView ~= true and settings.get("TakedownCams") == false then
            U.try(TAG, M.setTakedownCameras, false)
        end
    end)
    -- native /Script/ UFunctions: exist at boot (U.hook queues them otherwise)
    U.hook(C.FN.GUSSaveSettings, { pre = guardPre, post = guardPost }, TAG)
    U.hook(C.FN.GUSApplySettings, { pre = guardPre, post = guardPost }, TAG)
end

M.init()

return M
