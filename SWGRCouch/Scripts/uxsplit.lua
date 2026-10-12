-- SWGRCouch · uxsplit.lua (G5, 0.7.0): each player's half of the screen shows only its own player's messages and
-- effects. Run H (2026-10-07): "System malfunction / perfect landing and other screen. Are shared between players. Each
-- ux should be fully autonomous" and "Even before wrecked the ux were sharing perfect landing and danger (changing colors
-- and trembling)". Research: notes/research/ux-split-messages.md (messages), ux-split-visuals.md (danger visuals, index
-- remap), ux-split-inventory.md (the rest), live-run-H-ux-facts.md (verified hook facts, probe log).
--
-- ARMED while a split race runs: phase PRERACE or RACING, >= 2 local players, not a single-view race
-- (St.race.singleView). hud.lua also arms it right before it creates a HUD (M.hudCreating), so the Construct-time calls of
-- that HUD already see the hooks. DISARMED on POSTRACE, "leaving" (fired from the LoadMap pre-hook, i.e. BEFORE the map
-- changes), FRONTEND / LOADING / OTHER / TRANSIT, or fewer than 2 local players. Nothing runs while disarmed.
--
-- 1. MESSAGES (cfg.UxSplitMessages = "route"). The game has ONE GfnMessagingSubsystem; a post names only a message id,
--    whose DataTable row names a TargetContainer, and every registered container with that TargetName gets a copy (each
--    WBP_Hud_Race has 4: two central HUD_Notification_Container, Hud_Notification_GameFeed, Hud_Notification_CrashFeed).
--    a) Attribution: every Blueprint poster calls GetGameInstanceSubsystem(self, GfnMessagingSubsystem) right before the
--       post (ux-split-messages §2): a pre-hook records the ContextObject = the poster: the car's BP_VehicleUIComponent
--       (-> its car's controller), an ability feedback actor (-> its ability's vehicle; the Disruptor -> the TARGETED
--       player), a HUD widget (-> that HUD's player, by outer walk to one of hud.lua's HUDs).
--    b) The AddMessage / AddMessageParams pre-hook snapshots the children of every container with the row's TargetName;
--       the post-hook diffs them (dispatch is synchronous when a container has room, run H) and collapses the copies in
--       the other players' HUDs, re-asserted from the FAST tick while the copy sits in its panel.
--    c) A container that got no copy (full) gets a pending entry: a copy that appears there later (after a removal, on a
--       timer) is matched by its text on removals and FAST ticks. A copy of the same id already on screen is shared with
--       the second poster meanwhile (dedup or queue: for the same id both read the same).
--    d) RemoveMessage(id) / FlushMessageContainer remove EVERY player's copy: the players that still hold a plain message
--       (C.MSG[id].repost: WrongWay, OutOfBounds, Vulnerable, the crash-feed explosions) get it re-posted at once
--       (cfg.UxSplitRepost). Parameterised rows are never re-posted (their FText parameters cannot be rebuilt safely).
--    e) No Blueprint poster (native: the race-timeout messages) = global, kept in every HUD; an AI car or the game's own
--       hidden HUD = nobody. Elimination rows (C.MSG[id].perHud) are posted by EVERY HUD instance: the first post of a
--       burst goes to every half, the duplicates within 1.5 s are hidden. "all" = attribution + log only (every HUD keeps
--       every copy); "off" = no messaging hook.
--    Limit (Plan A, ux-split-messages §5.7): one queue per container, so a hidden copy still holds its slot.
-- 2. INDEX REMAP (cfg.UxSplitIndexRemap). WBP_HUD_BotEngineInfo(_Memory) binds GetPlayerPawn(self, 0) = P1's car at
--    Construct (ramjet / boost / throttle icons, critical-malfunction dimming, its "Vehicle State"). The GetPlayerPawn
--    POST-hook returns the guest's own pawn (a return override: no parameter rewrite needed) when the caller is one of
--    those widgets AND sits in one of OUR guest HUDs (hud.lua's registry, or the HUD being created). Never for P1's HUD,
--    the game's own HUD (UIManager-owned by P2 in a split race), or any other caller.
-- 3. DANGER (cfg.UxSplitDanger = "own"; "neutral" = only the global parts; "off" = game behaviour).
--    a) HUD colours (cfg.UxSplitHudColours): WBP_Hud_Race.UpdateLastCrashHud writes AfterburnerColor / HighThreatColor /
--       MalfunctionColor of the ONE world MPC_HUD_Parameters (read by almost every HUD material). The pre-hook on
--       KismetMaterialLibrary:SetVectorParameterValue drops those writes (Collection := nil = a no-op; checked once per
--       race by reading the value back, else the default is written back after each write). "own": that player's HUD
--       root is tinted (AfterburnerColor_LastCrash / _Default) while its health is 1.
--    b) Ramjet sweep (cfg.UxSplitRamjetColour): BotEngineInfo's EngageRamjet / DisengageRamjet animations move the global
--       FadeDirection / FadeProgress (MovieScene MPC track: no KML call). The PlayAnimation post-hook stops them and sets
--       the two icons as the animation would; the MPC is pinned to 1 / -1 every second. "own": the HUD root of a player
--       in ramjet (VehicleState.BoostState >= 3) is tinted blue (RamjetColor / AfterburnerColor).
--    c) Full-screen effects (cfg.UxSplitFullScreenFx): BP_VehicleState (one level actor that follows the FIRST local pawn
--       it finds) drives 8 post-process materials through an unbound PostProcessComponent, i.e. over EVERY view (last-
--       life desaturation + vignette, malfunction flash, concussion / wreck blur + RGB offset = the "trembling", frost,
--       heat, blind). The GfnUserSettings:GetFullScreenEffectsEnabled post-hook returns false while armed and neither
--       paused nor in photo mode. "own": a player on its last life gets a dark-red fade (cfg.UxSplitFadeMax, < 0.5 so
--       crashcam's held-fade guard leaves it alone) and a short warm flash on System Malfunction, through ITS OWN
--       PlayerCameraManager (per view), never while it crashes, is wrecked or another fade runs.
--    Camera shakes, the HUD sway and the per-HUD scanline / SYSTEMS CRITICAL / malfunction icons are per player already
--    (ux-split-visuals §2.3-2.6): nothing to do there.
-- HOOK RULES (run H: probe hooks left registered across a level transition crashed in UE4SS's dispatch):
--   raw RegisterHook (not U.hook: no xpcall per call; the GIS hook sees ~500-750 calls/s), registered when arming,
--   UnregisterHook-ed when disarming. Ids live in _G.SWGRCouch_uxsplit_hooks, so a re-require in the same Lua state never
--   double-registers (stale entries are unregistered first; the previous load's flags are switched off through
--   _G.SWGRCouch_uxsplit_flags); RestartCurrentMod unhooks everything by itself. Every callback checks its family flag
--   first (flags are cleared before unhooking), runs its body in pcall, counts instead of logging (U.logEvery at most)
--   and returns nil, except the two return overrides (GetPlayerPawn: the guest pawn; GetFullScreenEffectsEnabled:
--   false). No FindAllOf / FindFirstOf / LoadAsset anywhere in this file.
-- UE4SS 3f4037d2 facts (LuaMod.cpp 132-430): pre-callback args (ctx, params...); POST-callback args (ctx, ReturnValue,
-- params...) when the UFunction returns a value; a non-nil return of either callback overrides the return value;
-- UnregisterHook only flags the hook (its pre-callback returns at once, the next call's post-step removes it).
-- testcmd: `lua return require("uxsplit").status()`, `lua return require("uxsplit").testPost(2, "PerfectLanding")`,
-- `lua return require("uxsplit").testRemove(1, "WrongWay")`, `lua return St.uxsplit.n.copies`.
-- VERIFY ids: V-UX-00..13 (ARCHITECTURE.md §6 Session I, README §9 "Run-H UX checks").
-- Review 0.7.0 (integration): every wrapper kept between ticks (E.list widgets / PCs / panels, tagged copies) gets
-- U.ok() before any member access (UE4SS reads a collected object's class from freed memory: an AV pcall cannot catch);
-- GetGameInstanceSubsystem is hooked PRE-only (no Lua post call); the class-kind cache is per race (addresses repeat);
-- elimination bursts are per HUD root (two racers out within 1.5 s give two messages); a copy of a parameterised row is
-- never shared with another player; a "{Status}"-only body matches nothing and a race-ending-countdown copy is never
-- claimed by a waiting post; the remap returns vehicles only; the full-screen override follows this tick's pause state;
-- the MPC last-crash colours are reset when arming; a HUD with no tint record gets TintNone once; what a quiet disarm
-- left (hidden copies, tints, camera fades) is given back when the module arms again in the same world.

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "uxsplit"

local fmt, floor, lower = string.format, math.floor, string.lower
local VIS_COLLAPSED = C.E.Vis.Collapsed
local VIS_SHOW = C.E.Vis.SelfHitTestInvisible
local FX = C.UX or {}
local MSGTAB = C.MSG or {}
local PENDING_MS = 30000         -- a copy waiting in a full container is forgotten after this
local CRASH_GRACE_MS = 2000      -- no camera-fade write this long after a tumble (the game's own reset fade)
local CREATING_MAX_MS = 3000     -- a "HUD being created" slot older than this is ignored

---------------------------------------------------------------------------------------------------- state (St.uxsplit)
local function counters()
    return { gis = 0, gisMsg = 0, posts = 0, copies = 0, hidden = 0, unhidden = 0, queued = 0, promoted = 0,
             shared = 0, unknown = 0, nobody = 0, reposts = 0, repostFail = 0, removes = 0, flushes = 0, remaps = 0,
             remapMiss = 0, colourBlocks = 0, colourRestores = 0, rjStops = 0, fsfx = 0, fades = 0, flashes = 0,
             tints = 0, reasserts = 0, cbErrors = 0 }
end

-- Plain data only (testcmd `lua` and diag read it): St.uxsplit.armed, .why, .huds, .n.<counter>, .lastRoute, .tint,
-- .fade, .verdicts, .hooks.
local S = { armed = false, why = "never armed", since = 0, arms = 0, hooks = {}, n = counters(), lastRoute = "",
            huds = "", tint = {}, fade = {}, verdicts = {} }
St.uxsplit = S

-- Family flags, read first by every callback. own = UxSplitDanger "own" (per-player tints and fades).
local A = { on = false, msg = false, route = false, remap = false, colours = false, ramjet = false, fsfx = false,
            fsfxOverride = false, own = false }
do
    -- a previous load of this file in the same Lua state: its callbacks see their flags go off at once
    local old = _G.SWGRCouch_uxsplit_flags
    if type(old) == "table" and old ~= A then
        for k in pairs(old) do old[k] = false end
    end
    _G.SWGRCouch_uxsplit_flags = A
end

local function cbFail(where, err)
    S.n.cbErrors = S.n.cbErrors + 1
    U.logEvery("ux.cb." .. where, 10000, TAG, "WARN callback %s failed (%d callback error(s) so far): %s", where,
        S.n.cbErrors, tostring(err))
end

local function noop() return nil end

local function pdesc(p)
    if p == nil then return "global" end
    if p == -1 then return "nobody" end
    return "P" .. tostring(p)
end

---------------------------------------------------------------------------------------------------- hook registry
-- path -> {pre = id, post = id, owner = INSTANCE}. Kept in _G so a re-require of this file (same Lua state) finds the
-- registrations of the previous load and replaces them instead of adding a second set.
local HOOKS = _G.SWGRCouch_uxsplit_hooks
if type(HOOKS) ~= "table" then
    HOOKS = {}
    _G.SWGRCouch_uxsplit_hooks = HOOKS
end
local INSTANCE = {}

local function onGameThread()
    local ok, v = pcall(function() return IsInGameThread() end)
    return ok and v == true
end

local function unhook(path, why)
    local h = HOOKS[path]
    if h == nil then return false end
    HOOKS[path] = nil
    S.hooks[path] = "off (" .. tostring(why) .. ")"
    local ok, e = pcall(UnregisterHook, path, h.pre, h.post or h.pre)
    if not ok then
        U.warn(TAG, "UnregisterHook(%s, %s, %s) failed: %s", path, tostring(h.pre), tostring(h.post), tostring(e))
        return false
    end
    return true
end

-- Registers pre/post on a native UFunction once (a registration of this load is reused; one of an earlier load is
-- replaced). Returns true when the hook is in place. post = nil: PRE-only (review 0.7.0, for the ~750 calls/s
-- GetGameInstanceSubsystem hook): UE4SS then makes no Lua post call at all (LuaMod.cpp: lua_post_callback_ref == -1),
-- while RegisterHook still returns both ids (UnregisterHook needs them).
local function hook(path, pre, post)
    local h = HOOKS[path]
    if h ~= nil and h.owner == INSTANCE then return true end
    if h ~= nil then unhook(path, "stale registration of an earlier load") end
    local okF, fn = pcall(StaticFindObject, path)
    if not okF or not U.ok(fn) then
        S.hooks[path] = "missing"
        U.warn(TAG, "hook %s: UFunction not found; that part stays off", path)
        return false
    end
    local ok, preId, postId
    if post == nil then
        ok, preId, postId = pcall(RegisterHook, path, pre)
    else
        ok, preId, postId = pcall(RegisterHook, path, pre, post)
    end
    if not ok or type(preId) ~= "number" then
        S.hooks[path] = "failed: " .. tostring(preId)
        U.err(TAG, "RegisterHook(%s) failed: %s; that part stays off", path, tostring(preId))
        return false
    end
    HOOKS[path] = { pre = preId, post = postId, owner = INSTANCE }
    local only = (post == nil) and ", pre only" or ""
    S.hooks[path] = fmt("on (ids %s/%s%s)", tostring(preId), tostring(postId), only)
    U.log(TAG, "hook on: %s (ids %s/%s%s)", path, tostring(preId), tostring(postId), only)
    return true
end

-- Every registration in the table (this load's and stale ones). Game thread only (UnregisterHook finds the UFunction).
local function unhookAll(why)
    if not onGameThread() then return 0 end
    local paths = {}
    for p in pairs(HOOKS) do paths[#paths + 1] = p end
    local n = 0
    for _, p in ipairs(paths) do
        if unhook(p, why) then n = n + 1 end
    end
    return n
end

local function hookCount()
    local n = 0
    for _, h in pairs(HOOKS) do if h.owner == INSTANCE then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------------------------------- HUD entries (hud.lua)
-- E.list = hud.notifEntries(): { {pc, pnum, widget, bot, conts = { {w, name, panel, tree} }} } (P1 first), refreshed
-- from the ticks (never inside a callback). byRoot / byPc index them by address; foreign = the game's own hidden HUD
-- ("clone" mode); rj = WidgetAnimation address -> "engage" | "disengage" (class-level objects shared by every instance).
local E = { list = {}, byRoot = {}, byPc = {}, foreign = {}, dirty = true, sig = "", rj = {}, rjCount = 0, at = -1e12 }
local creating = nil             -- {rootKey, pc, pcKey, pnum, at}: the HUD between hudCreating and hudCreated
local onEntriesChanged           -- forward (messages section)

local function hudMod()
    local ok, m = pcall(U.mod, "hud")
    if ok and type(m) == "table" then return m end
    return nil
end

local function refreshEntries()
    E.dirty, E.at = false, St.nowMs()
    local hud = hudMod()
    if not (hud and type(hud.notifEntries) == "function") then return end
    local ok, list = pcall(hud.notifEntries)
    if not ok or type(list) ~= "table" then
        U.logEvery("ux.entries", 10000, TAG, "WARN hud.notifEntries failed: %s", tostring(list))
        return
    end
    local byRoot, byPc, parts, keys = {}, {}, {}, {}
    for _, e in ipairs(list) do
        e.wKey, e.pcKey = U.key(e.widget), U.key(e.pc)
        byRoot[e.wKey], byPc[e.pcKey] = e, e
        keys[#keys + 1] = tostring(e.wKey)
        for _, c in ipairs(e.conts or {}) do
            c.key = c.key or U.key(c.w)
            c.panelKey = c.panelKey or U.key(c.panel)
            c.lname = c.lname or lower(tostring(c.name))
        end
        if U.ok(e.bot) then
            for name, kind in pairs({ EngageRamjet = "engage", DisengageRamjet = "disengage" }) do
                local okA, a = pcall(function() return e.bot[name] end)        -- BP variables (WidgetAnimation)
                local ak = okA and U.key(a) or 0
                if ak ~= 0 and E.rj[ak] == nil then E.rj[ak], E.rjCount = kind, E.rjCount + 1 end
            end
        end
        parts[#parts + 1] = fmt("P%s:%d", tostring(e.pnum), #(e.conts or {}))
    end
    local foreign = {}
    if type(hud.gameHudWidget) == "function" then
        local okG, g = pcall(hud.gameHudWidget)
        if okG and U.ok(g) and not byRoot[U.key(g)] then foreign[U.key(g)] = true end
    end
    E.list, E.byRoot, E.byPc, E.foreign = list, byRoot, byPc, foreign
    local sig = table.concat(parts, " ") .. (next(foreign) ~= nil and " +game HUD" or "")
    if sig ~= E.sig then
        E.sig, S.huds = sig, sig
        U.log(TAG, "HUDs: %s (P<n>:<notification containers>)%s; ramjet animations known: %d", sig,
            next(foreign) ~= nil and "; the game's hidden HUD: its own posts are shown nowhere" or "", E.rjCount)
    end
    local keysig = table.concat(keys, ",")          -- a HUD replaced by a new instance changes only this
    if keysig ~= E.keysig then
        E.keysig = keysig
        if onEntriesChanged then onEntriesChanged() end
    end
end

-- The HUD entry (or "foreign" for the game's hidden HUD, or the creating slot) a widget sits in, and that HUD root's
-- address: walk the outers (member -> WidgetTree -> UserWidget, nested user widgets likewise; hud.lua V-HUD-12), at
-- most 8 hops.
local function rootOf(o)
    local now = St.nowMs()
    local slot = (creating and now - creating.at < CREATING_MAX_MS) and creating or nil
    local x = o
    for _ = 0, 8 do
        local k = U.key(x)
        if k == 0 then return nil end
        local e = E.byRoot[k]
        if e then return e, k end
        if E.foreign[k] then return "foreign", k end
        if slot and slot.rootKey == k then return slot, k end
        local ok, nx = pcall(function() return x:GetOuter() end)
        if not ok or nx == nil then return nil end
        x = nx
    end
    return nil
end

-- Class kind cache (class address -> {kind, name}): "remap" (BotEngineInfo widgets), "vuic" (a car's UI component),
-- "fbDisruptor" / "fb" (ability feedback actors), "widget", "other". Review 0.7.0: emptied by clearRace (every arm /
-- disarm): the race's Blueprint classes unload with the map and another class can land at a cached address.
local REMAP_CLASSES = { WBP_HUD_BotEngineInfo_C = true, WBP_HUD_BotEngineInfo_Memory_C = true }
local KIND = {}
local function kindOf(o)
    local okC, cls = pcall(function() return o:GetClass() end)
    if not okC then return "other", "?" end
    local ck = U.key(cls)
    local k = KIND[ck]
    if k then return k[1], k[2] end
    local name = "?"
    pcall(function() name = cls:GetFName():ToString() end)
    local kind = "other"
    if REMAP_CLASSES[name] then kind = "remap"
    elseif name == "BP_VehicleUIComponent_C" or U.isA(o, "/Script/Griffin.VehicleUIComponent") then kind = "vuic"
    elseif name == "BP_AbilityFeedback_Disruptor_C" then kind = "fbDisruptor"
    elseif U.isA(o, "/Script/Griffin.AbilityFeedback") then kind = "fb"
    elseif U.isA(o, "/Script/UMG.Widget") then kind = "widget" end
    if ck ~= 0 then KIND[ck] = { kind, name } end
    return kind, name
end

-- Player number of a controller: its HUD entry's pnum (hud.lua's numbering); anything else = -1 (nobody): a local
-- player without a HUD (its messages show in no other HUD), an AI controller, none.
local function pnumOfPc(pc)
    local k = U.key(pc)
    if k == 0 then return -1, "no controller" end
    local e = E.byPc[k]
    if e then return e.pnum, nil end
    for _, lp in ipairs(U.localPlayers()) do
        if U.key(lp.pc) == k then return -1, fmt("local player %d without a HUD", lp.index) end
    end
    return -1, "not a local player (AI)"
end

local function pnumOfCar(car)
    if not U.ok(car) then return -1, "no car" end
    local ctrl
    pcall(function() ctrl = car.Controller end)
    if not U.ok(ctrl) then return -1, "car without controller" end
    return pnumOfPc(ctrl)
end

-- Poster object -> pnum (nil = global, -1 = nobody), how, kind, and for a HUD widget its HUD root's address (the
-- per-HUD elimination bursts). ux-split-messages §5.1.
local function resolvePoster(o)
    if not U.ok(o) then return nil, "no poster" end
    local kind, name = kindOf(o)
    local p, why
    if kind == "vuic" then
        local car
        pcall(function() car = o.Pawn end)                       -- UVehiclePresentationComponent.Pawn @0xF0
        if not U.ok(car) then pcall(function() car = o:GetOwner() end) end
        p, why = pnumOfCar(car)
        return p, name .. " (car" .. (why and (": " .. why) or "") .. ")", kind
    elseif kind == "fbDisruptor" then
        local pc
        pcall(function() pc = o["Local Player Being Targeting"]:GetPlayerController() end)
        p, why = pnumOfPc(pc)
        return p, name .. " (targeted player" .. (why and (": " .. why) or "") .. ")", kind
    elseif kind == "fb" then
        local car
        pcall(function() car = o.ParentAbility:GetOwnerVehicle() end)
        p, why = pnumOfCar(car)
        return p, name .. " (ability vehicle" .. (why and (": " .. why) or "") .. ")", kind
    elseif kind == "widget" or kind == "remap" then
        local r, rk = rootOf(o)
        if r == "foreign" then return -1, name .. " (the game's hidden HUD)", "hud", rk end
        if type(r) == "table" then return r.pnum, name .. " (HUD widget)", "hud", rk end
        return nil, name .. " (widget outside the race HUDs)", kind
    end
    return nil, name .. " (unknown poster)", kind
end

---------------------------------------------------------------------------------------------------- 2. index remap
-- GetPlayerPawn post-hook (ctx, ReturnValue, WorldContextObject, PlayerIndex): for a BotEngineInfo in one of our guest
-- HUDs asking for index 0, the guest's own pawn is returned instead of P1's (V-UX-01).
-- VERIFY(V-UX-01): the post-hook's return override reaches the Blueprint caller (Construct's GetPlayerPawn node): the
-- guest's BotEngineInfo then stores the guest car's VehicleState (hud.lua logs it). Fallback: UxSplitIndexRemap=false.
local function remapInner(wco, idx)
    if idx:get() ~= 0 then return nil end
    local o = wco:get()
    if o == nil then return nil end
    local kind, cname = kindOf(o)
    if kind ~= "remap" then return nil end
    local r = rootOf(o)
    if type(r) ~= "table" or (tonumber(r.pnum) or 1) < 2 then return nil end   -- P1's HUD, the game's HUD, unknown
    if not U.ok(r.pc) then return nil end                    -- review 0.7.0: a stored PC wrapper is validated first
    local pawn
    pcall(function() pawn = r.pc.Pawn end)
    -- review 0.7.0: vehicles only. BotEngineInfo casts the result to VehiclePawn: a car-less guest (spectator pawn,
    -- the takeover fallback before its car) would bind nothing at all, and hud.lua's rebind would find no binding on
    -- P1's car to move later. Index 0 (P1's car) then stays, and the 0.6.0 rebind moves it once the guest has a car.
    if not U.isVehicle(pawn) then
        S.n.remapMiss = S.n.remapMiss + 1
        U.logEvery("ux.remapmiss" .. tostring(r.pnum), 5000, TAG, "WARN remap: P%s has no car while its %s binds one: "
            .. "left on index 0 (hud.lua's rebind moves those bindings later) (V-UX-01)", tostring(r.pnum), cname)
        return nil
    end
    S.n.remaps = S.n.remaps + 1
    S.verdicts.remap = fmt("P%s x%d", tostring(r.pnum), S.n.remaps)
    U.logEvery("ux.remap" .. tostring(r.pnum), 2000, TAG, "remap GetPlayerPawn(self, 0) -> P%s's car for %s (%s) (V-UX-01)",
        tostring(r.pnum), cname, (r == creating) and "HUD being created" or "registered HUD")
    return pawn
end

local function onRemapPost(ctx, ret, wco, idx)
    if not A.remap then return nil end
    local ok, pawn = pcall(remapInner, wco, idx)
    if not ok then
        cbFail("GetPlayerPawn", pawn)
        return nil
    end
    return pawn
end

---------------------------------------------------------------------------------------------------- 1. messages: copies
local HUDCONT = {}                    -- lower-case TargetNames of the race HUD containers
for _, n in ipairs(C.MSG_CONTAINERS or {}) do HUDCONT[lower(n)] = true end

local last = nil                      -- poster recorded by the GetGameInstanceSubsystem pre-hook (cleared every FAST tick)
local forced = nil                    -- {pnum, why} while we post ourselves (re-post, test)
local frames = {}                     -- in-flight hooked calls (a stack: our re-posts nest inside a removal's post-hook)
local tags = {}                       -- copy address -> {grp, w, c, pnum (of the HUD it sits in), text, at}
local hidden = {}                     -- copy address -> {w, panelKey, orig, mode, at, young}
local seen = {}                       -- container key -> {copy address -> text} after the last diff of that container
local pending = {}                    -- container key -> FIFO of {id, grp, at}: a post that found that container full
local active = {}                     -- id -> {[pnum] = {h, v, at}}: plain re-postable messages a player still holds
local unknownLogged = {}

local function msgCont(id)
    local m = MSGTAB[id]
    if m and m.c then return lower(m.c) end
    return nil
end

local function msgText(w)
    local ok, s = pcall(function() return w.Txt_MainMessage:GetText():ToString() end)   -- WBP_Hud_(GameFeed_)Message
    if ok and type(s) == "string" then return s end
    return ""
end

local function childrenOf(panel)
    local out = {}
    if not U.ok(panel) then return out end                   -- review 0.7.0: a panel of a HUD that went away
    local okN, n = pcall(function() return panel:GetChildrenCount() end)
    if not okN or type(n) ~= "number" then return out end
    for i = 0, floor(n) - 1 do
        local okC, w = pcall(function() return panel:GetChildAt(i) end)
        if okC and U.ok(w) then out[#out + 1] = w end
    end
    return out
end

local function inPanel(w, panelKey)
    if panelKey == nil or panelKey == 0 then return false end
    local ok, par = pcall(function() return w:GetParent() end)
    return ok and U.key(par) == panelKey
end

-- Does a copy's text fit the row's English body? true / false / nil (no body known, or no text read).
-- Review 0.7.0: a body that is only a placeholder ("{Status}": VulnerableDueToStatus / _Choked) says nothing about the
-- text: nil (unknown), never true (it matched ANY text, e.g. the race-ending countdown).
local function textMatches(id, text)
    local m = MSGTAB[id]
    if not (m and type(m.text) == "string" and m.text ~= "") then return nil end
    local t, want = lower(text or ""), lower(m.text)
    if t == "" then return nil end
    local a, b = want:match("^(.-){[^}]*}(.*)$")
    if a then
        if a == "" and b == "" then return nil end
        return (a == "" or t:find(a, 1, true) ~= nil) and (b == "" or t:find(b, 1, true) ~= nil)
    end
    return t:find(want, 1, true) ~= nil
end

-- A row other than `except` whose body (with literal text) the text fits, or nil.
local function otherRowFor(text, except)
    for id in pairs(MSGTAB) do
        if id ~= except and textMatches(id, text) == true then return id end
    end
    return nil
end

-- Does the text read like a `global = true` row (the race-ending countdown)? Such a copy is never claimed by a waiting
-- post: it stays global, in every HUD (V-UX-06).
local GLOBAL_IDS = {}
for id, m in pairs(MSGTAB) do if m.global then GLOBAL_IDS[#GLOBAL_IDS + 1] = id end end
local function isGlobalText(text)
    for _, id in ipairs(GLOBAL_IDS) do
        if textMatches(id, text) == true then return true end
    end
    return false
end

-- One group per posted message: every copy of it (one per container per HUD) shares it, so sharing it with a second
-- player later updates every copy.
local function newGroup(id, pnum, via)
    local g = { id = id, players = {}, global = (pnum == nil), via = via, at = St.nowMs() }
    if type(pnum) == "number" and pnum >= 1 then g.players[pnum] = true end
    return g
end

local function shows(g, pnum)
    return g.global or g.players[pnum] == true
end

local function hideCopy(k, t)
    local now = St.nowMs()
    if hidden[k] then hidden[k].young = now; return end
    local w = t.w
    if not U.ok(w) then return end                           -- review 0.7.0: a tagged copy that died meanwhile
    local mode = (cfg.UxSplitMsgHide == "opacity") and "opacity" or "collapse"
    local orig
    if mode == "collapse" then
        local ok, v = pcall(function() return w:GetVisibility() end)
        orig = ok and v or nil
        pcall(function() w:SetVisibility(VIS_COLLAPSED) end)
    else
        local ok, v = pcall(function() return w:GetRenderOpacity() end)
        orig = ok and v or 1.0
        pcall(function() w:SetRenderOpacity(0.0) end)
    end
    hidden[k] = { w = w, panelKey = t.c.panelKey, orig = orig, mode = mode, at = now, young = now }
    S.n.hidden = S.n.hidden + 1
end

-- A hidden copy's look given back (also when it left its panel: a pooled widget must not come back collapsed).
local function showAgain(h)
    if not U.ok(h.w) then return false end
    if h.mode == "collapse" then
        local v = h.orig
        if type(v) ~= "number" or v == VIS_COLLAPSED then v = VIS_SHOW end
        pcall(function() h.w:SetVisibility(v) end)
    else
        local o = (type(h.orig) == "number" and h.orig > 0.01) and h.orig or 1.0
        pcall(function() h.w:SetRenderOpacity(o) end)
    end
    return true
end

local function unhideCopy(k)
    local h = hidden[k]
    if not h then return end
    hidden[k] = nil
    S.n.unhidden = S.n.unhidden + 1
    showAgain(h)
end

-- Shows or hides one tagged copy for the HUD it sits in ("all" mode never hides). Returns true when shown.
local function applyTag(k)
    local t = tags[k]
    if not t then return nil end
    if not A.route or shows(t.grp, t.pnum) then
        if hidden[k] then unhideCopy(k) end
        return true
    end
    hideCopy(k, t)
    return false
end

local function dropTag(k)
    if hidden[k] then unhideCopy(k) end
    tags[k] = nil
end

local function tagCopy(w, k, text, e, c, grp, res)
    if tags[k] then dropTag(k) end
    tags[k] = { grp = grp, w = w, c = c, pnum = e.pnum, text = text, at = St.nowMs() }
    S.n.copies = S.n.copies + 1
    local shown = applyTag(k)
    if res then
        res.n = res.n + 1
        local bucket = shown and res.shown or res.hid
        bucket[e.pnum] = (bucket[e.pnum] or 0) + 1
    end
end

local function resText(res)
    local parts = {}
    for _, kv in ipairs({ { "shown", res.shown }, { "hidden", res.hid } }) do
        local ps = {}
        for p, n in pairs(kv[2]) do ps[#ps + 1] = fmt("P%s x%d", tostring(p), n) end
        table.sort(ps)
        if #ps > 0 then parts[#parts + 1] = kv[1] .. " " .. table.concat(ps, ", ") end
    end
    return #parts > 0 and table.concat(parts, "; ") or "nothing shown"
end

-- fn(entry, container) for every race HUD container of our HUDs whose TargetName is lname (nil = all of them).
local function eachCont(lname, fn)
    for _, e in ipairs(E.list) do
        for _, c in ipairs(e.conts or {}) do
            if HUDCONT[c.lname] and (lname == nil or c.lname == lname) then fn(e, c) end
        end
    end
end

local function kidsOf(c)
    local kids = {}
    for _, w in ipairs(childrenOf(c.panel)) do kids[U.key(w)] = msgText(w) end
    return kids
end

local function snapshot(lname)
    local snap = {}
    eachCont(lname, function(_, c) snap[c.key] = kidsOf(c) end)
    return snap
end

-- A new HUD (or the first arm): its containers' current children are the baseline (never treated as new copies).
onEntriesChanged = function()
    if not A.msg then return end
    eachCont(nil, function(_, c)
        if seen[c.key] == nil then seen[c.key] = kidsOf(c) end
    end)
end

---------------------------------------------------------------------------------------------------- messages: waiting copies
local function pushPending(c, grp)
    local q = pending[c.key]
    if not q then q = {}; pending[c.key] = q end
    q[#q + 1] = { id = grp.id, grp = grp, at = St.nowMs() }
    S.n.queued = S.n.queued + 1
end

-- The oldest waiting post of that container whose body fits the text (else the oldest one without a known body, but
-- review 0.7.0: only for a text no other row's body fits, so a PerfectLanding or countdown copy never goes to a
-- "{Status}" post).
local function pickPending(q, text)
    if not q then return nil end
    local fallback
    for i, p in ipairs(q) do
        local m = textMatches(p.id, text)
        if m == true then return table.remove(q, i) end
        if m == nil and fallback == nil then fallback = i end
    end
    if fallback and otherRowFor(text, q[fallback].id) == nil then return table.remove(q, fallback) end
    return nil
end

local function dropPendingId(id)
    for ck, q in pairs(pending) do
        for i = #q, 1, -1 do if q[i].id == id then table.remove(q, i) end end
        if #q == 0 then pending[ck] = nil end
    end
end

local function expirePending(now)
    for ck, q in pairs(pending) do
        for i = #q, 1, -1 do if now - q[i].at > PENDING_MS then table.remove(q, i) end end
        if #q == 0 then pending[ck] = nil end
    end
end

local function firstPlayer(g)
    if g.global then return nil end
    local best
    for p in pairs(g.players) do if best == nil or p < best then best = p end end
    return best or -1
end

-- Only a waiting post whose row body fits the text (a widget re-used in place, or re-initialised by the container).
local function pickPendingStrict(q, text)
    if not q then return nil end
    for i, p in ipairs(q) do
        if textMatches(p.id, text) == true then return table.remove(q, i) end
    end
    return nil
end

-- Diffs containers against `seen`. A new child is a copy that waited (matched to a pending post of THAT container) or
-- an unattributed message (native: race timeout): global, kept in every HUD. A known child whose text changed keeps its
-- tag (a late Initialise, a self-updating text) unless a waiting post with exactly that body claims it (re-used in
-- place). onlyPending: only the containers with waiting posts (removal post-hooks, ~100 ms timer); else every race
-- container (1 s scan).
-- VERIFY(V-UX-06): the race-ending countdown (native post, no hook call) is found here and kept in every HUD.
local function scan(why, onlyPending)
    expirePending(St.nowMs())
    for _, e in ipairs(E.list) do
        for _, c in ipairs(e.conts or {}) do
            if HUDCONT[c.lname] and (not onlyPending or pending[c.key] ~= nil) then
                local was = seen[c.key] or {}
                local cur = {}
                for _, w in ipairs(childrenOf(c.panel)) do
                    local k = U.key(w)
                    local t = msgText(w)
                    cur[k] = t
                    if was[k] ~= t then
                        local old = tags[k]
                        local p
                        -- review 0.7.0: a copy reading like a global row (the race-ending countdown, which rewrites its
                        -- text every second) is never claimed by a waiting post, and a player's tag never sticks to it
                        local glob = isGlobalText(t)
                        if not glob then
                            if was[k] == nil then p = pickPending(pending[c.key], t)
                            else p = pickPendingStrict(pending[c.key], t) end
                        end
                        if not p and was[k] ~= nil and old and not (glob and not old.grp.global) then
                            old.text = t                     -- same copy, new text: keeps its player
                        elseif p then
                            tagCopy(w, k, t, e, c, p.grp, nil)
                            S.n.promoted = S.n.promoted + 1
                            U.logEvery("ux.promo." .. p.id, 2000, TAG, "msg %s (%s) shown after it waited (%s): %s in P%s's %s "
                                .. "(V-UX-03)", p.id, pdesc(firstPlayer(p.grp)), why, hidden[k] and "hidden" or "shown",
                                tostring(e.pnum), tostring(c.name))
                        elseif old and old.grp.global then
                            old.text = t                     -- a global copy, still global
                        else
                            tagCopy(w, k, t, e, c, newGroup("?", nil, "unattributed"), nil)
                            S.n.unknown = S.n.unknown + 1
                            local cls = "?"
                            pcall(function() cls = w:GetClass():GetFName():ToString() end)
                            local key = cls .. "|" .. c.lname
                            if not unknownLogged[key] then
                                unknownLogged[key] = true
                                U.log(TAG, "unattributed %s '%s' in %s of P%s's HUD (%s): global, kept in every HUD (V-UX-06)",
                                    cls, t, tostring(c.name), tostring(e.pnum), why)
                            end
                        end
                    end
                end
                seen[c.key] = cur
                if pending[c.key] ~= nil and #pending[c.key] == 0 then pending[c.key] = nil end
            end
        end
    end
end

-- Forgets copies that left their panel (message over, or the widget died); a hidden one gets its look back.
local function sweepGone()
    local now = St.nowMs()
    for k, t in pairs(tags) do
        if not U.ok(t.w) or not inPanel(t.w, t.c.panelKey) then
            local h, m = hidden[k], MSGTAB[t.grp.id]
            if h and m and (m.min or 0) > 0 then
                U.logEvery("ux.life." .. t.grp.id, 5000, TAG, "hidden copy of %s (%s) left P%s's HUD after %.1f s (row "
                    .. "minimum %.1f s) (V-UX-05)", t.grp.id, pdesc(firstPlayer(t.grp)), tostring(t.pnum),
                    (now - h.at) / 1000, m.min)
            end
            dropTag(k)
        end
    end
end

-- FAST: a hidden copy stays hidden while it sits in its panel (copies younger than 1.5 s every tick, older ones every
-- 8th tick: ~264 ms); a timed copy still there 10 s past its row minimum is reported once (stall).
local maintN = 0
-- VERIFY(V-UX-05): a collapsed copy still expires on time (lifetime is native, not driven by the widget). Fallback:
-- UxSplitMsgHide="opacity".
local function maintainHidden(now)
    maintN = maintN + 1
    local full = (maintN % 8 == 0)
    for k, h in pairs(hidden) do
        if full or now - (h.young or 0) < 1500 then
            local w = h.w
            if not U.ok(w) or not inPanel(w, h.panelKey) then
                dropTag(k)
            else
                if h.mode == "collapse" then
                    local okV, v = pcall(function() return w:GetVisibility() end)
                    if okV and v ~= VIS_COLLAPSED then
                        pcall(function() w:SetVisibility(VIS_COLLAPSED) end)
                        S.n.reasserts = S.n.reasserts + 1
                    end
                else
                    local okO, o = pcall(function() return w:GetRenderOpacity() end)
                    if okO and type(o) == "number" and o > 0.01 then
                        pcall(function() w:SetRenderOpacity(0.0) end)
                        S.n.reasserts = S.n.reasserts + 1
                    end
                end
                local t = tags[k]
                local m = t and MSGTAB[t.grp.id]
                if full and m and not t.stallWarned and (m.min or 0) > 0 and now - h.at > (m.min + 10) * 1000 then
                    t.stallWarned = true
                    U.warn(TAG, "hidden copy of %s still in P%s's HUD %.0f s after its post (row minimum %.1f s): a stall? "
                        .. "try UxSplitMsgHide = \"opacity\" (V-UX-05)", t.grp.id, tostring(t.pnum), (now - h.at) / 1000, m.min)
                end
            end
        end
    end
end

-- AddMessage* post: every container with the row's TargetName is diffed against its pre-snapshot. Each new child is a
-- copy of this post; with no new child, a child whose text changed to this row's body was swapped in place (a full
-- container giving the slot to a higher priority); any other text change keeps that copy's tag.
local function routeAdd(fr)
    local res = { n = 0, shown = {}, hid = {} }
    local grp = newGroup(fr.id, fr.pnum, fr.via)
    local full = {}
    eachCont(fr.lname, function(e, c)
        local before = fr.snap[c.key] or seen[c.key] or {}
        local cur, got, changed = {}, false, {}
        for _, w in ipairs(childrenOf(c.panel)) do
            local k = U.key(w)
            local t = msgText(w)
            cur[k] = t
            if before[k] == nil then
                tagCopy(w, k, t, e, c, grp, res)
                got = true
            elseif before[k] ~= t then
                changed[#changed + 1] = { w = w, k = k, t = t }
            end
        end
        for _, x in ipairs(changed) do
            if not got and textMatches(fr.id, x.t) == true then
                tagCopy(x.w, x.k, x.t, e, c, grp, res)
                got = true
            elseif tags[x.k] then
                tags[x.k].text = x.t
            end
        end
        seen[c.key] = cur
        if not got then full[#full + 1] = c end
    end)
    return res, grp, full
end

-- VERIFY(V-UX-02): with room, the copies exist when AddMessage returns (run H probe: 0->1 in the post-hook), 2 per post
-- for the feeds and 4 for the central container with 2 HUDs. VERIFY(V-UX-03): a full container queues (pending) or
-- dedups (shared); either way both posters read the message. Fallback: UxSplitMessages="all".
local function afterAdd(fr)
    S.n.posts = S.n.posts + 1
    if fr.pnum == -1 then S.n.nobody = S.n.nobody + 1 end
    local res, grp, full = routeAdd(fr)
    -- 0.13.0 v2: per-player HUD message stream for the GALAXY RUN challenges (run.lua counts "Takedown")
    if type(fr.pnum) == "number" and not tostring(fr.via):find("re-post", 1, true) then
        pcall(St.emit, "hudmsg", fr.pnum, fr.id)
    end
    local m = MSGTAB[fr.id]
    if m and m.repost and type(fr.pnum) == "number" and fr.pnum >= 1 then
        local a = active[fr.id]
        if not a then a = {}; active[fr.id] = a end
        a[fr.pnum] = { h = fr.h, v = fr.v, at = St.nowMs() }
    end
    local extra = ""
    if #full > 0 and fr.lname ~= nil then
        for _, c in ipairs(full) do pushPending(c, grp) end
        extra = fmt("; %d full container(s): it waits there", #full)
        -- the same id already on screen (dedup or full container): shared with this poster meanwhile. Review 0.7.0:
        -- only a row without parameters ("{Player} Taken down", "{Status}", "{Affix} damaged" ... would show the OTHER
        -- player's text); those wait in the pending queue only.
        local plain = m ~= nil and type(m.text) == "string" and m.text ~= "" and not m.text:find("{", 1, true)
        if A.route and plain and type(fr.pnum) == "number" and fr.pnum >= 1 then
            local n = 0
            for _, t in pairs(tags) do
                if t.grp ~= grp and t.grp.id == fr.id and not t.grp.global and not t.grp.players[fr.pnum] then
                    t.grp.players[fr.pnum] = true
                    n = n + 1
                end
            end
            if n > 0 then
                for k, t in pairs(tags) do if t.grp.id == fr.id then applyTag(k) end end
                S.n.shared = S.n.shared + 1
                extra = extra .. fmt("; the %s copy already on screen is shared with %s", fr.id, pdesc(fr.pnum))
            end
        end
    end
    local line = fmt("%s by %s = %s -> %s: %d new copy(ies) (%s)%s", fr.id, tostring(fr.via), pdesc(fr.pnum),
        (MSGTAB[fr.id] and MSGTAB[fr.id].c) or "every HUD container", res.n, resText(res), extra)
    S.lastRoute = line
    U.logEvery("ux.msg." .. fr.id .. "." .. pdesc(fr.pnum), 2000, TAG, "msg %s (V-UX-02)", line)
end

---------------------------------------------------------------------------------------------------- messages: removals
-- The remover drops its own hold of the ids; the other holders are re-posted after the call (the game removes every
-- instance of an id / every copy of a flushed container). Unknown remover (native, Lua): nobody is re-posted.
local function survivorsOf(ids, remover)
    local surv = {}
    for _, id in ipairs(ids) do
        local a = active[id]
        if a then
            if type(remover) == "number" and remover >= 1 then
                a[remover] = nil
                for p, rec in pairs(a) do surv[#surv + 1] = { id = id, pnum = p, rec = rec } end
                if next(a) == nil then active[id] = nil end
            else
                active[id] = nil
            end
        end
    end
    return surv
end

local MSUB = nil                  -- the messaging subsystem (resolved when arming, never inside a callback)

local function repost(id, p, rec)
    if not U.ok(MSUB) then
        S.n.repostFail = S.n.repostFail + 1
        return false, "no messaging subsystem"
    end
    local prev = forced
    forced = { pnum = p, why = "mod re-post" }
    local h = floor(tonumber(rec and rec.h) or 0)
    local v = floor(tonumber(rec and rec.v) or 0)
    -- AddMessage(Name, Struct& handle = {}, Delegate = nil (cleared), Object = nil, Byte, Byte) [fastboot's RemoveMessage
    -- call passes its const-ref handle the same way]; it runs through our own AddMessage hooks (routed for p).
    local ok, err = pcall(function() MSUB:AddMessage(U.fname(id), {}, nil, nil, h, v) end)
    forced = prev
    if ok then S.n.reposts = S.n.reposts + 1 else S.n.repostFail = S.n.repostFail + 1 end
    return ok, err
end

-- VERIFY(V-UX-04): RemoveMessage(id, true, {}) / FlushMessageContainer drop every player's copy and our AddMessage from
-- Lua (empty handle table, nil delegate) re-creates the survivor's copy through our own hooks. Fallback: UxSplitRepost=false.
local function afterRemove(fr, what)
    if what == "FlushMessageContainer" then S.n.flushes = S.n.flushes + 1 else S.n.removes = S.n.removes + 1 end
    sweepGone()
    if next(pending) ~= nil then scan(what, true) end
    if #fr.survivors == 0 then return end
    if not A.route or cfg.UxSplitRepost == false then
        U.logEvery("ux.norepost", 5000, TAG, "%s %s by %s: %d other holder(s) lose their copy (re-post off)", what,
            tostring(fr.id or fr.cont), pdesc(fr.pnum), #fr.survivors)
        return
    end
    for _, s in ipairs(fr.survivors) do
        local ok, err = repost(s.id, s.pnum, s.rec)
        U.logEvery("ux.repost." .. s.id .. "." .. tostring(s.pnum), 2000, TAG, "%s %s by %s: %s still holds %s -> re-posted "
            .. "for %s (%s) (V-UX-04)", what, tostring(fr.id or fr.cont), pdesc(fr.pnum), pdesc(s.pnum), s.id,
            pdesc(s.pnum), ok and "ok" or ("FAILED: " .. tostring(err)))
    end
end

---------------------------------------------------------------------------------------------------- messages: hook callbacks
local MS_CLASS_KEY = 0            -- address of the GfnMessagingSubsystem UClass (resolved when arming)

-- The poster of the post being hooked: our own forced post, else the context of the last GetGameInstanceSubsystem
-- (GfnMessagingSubsystem) call (consumed: it never serves two posts), else nil = native = global.
local function takePoster()
    local o = last
    last = nil
    if forced then return forced.pnum, forced.why, "forced" end
    if o == nil then return nil, "no Blueprint poster (native)", "native" end
    return resolvePoster(o)
end

-- GetGameInstanceSubsystem pre (ctx, ContextObject, Class): ~500-750 calls/s, so only the class address is compared.
local function gisInner(ctxObj, cls)
    local c = cls:get()
    if c == nil or c:GetAddress() ~= MS_CLASS_KEY then return end
    last = ctxObj:get()
    S.n.gisMsg = S.n.gisMsg + 1
end

local function onGisPre(ctx, ctxObj, cls)
    if not A.msg then return nil end
    S.n.gis = S.n.gis + 1
    local ok, err = pcall(gisInner, ctxObj, cls)
    if not ok then cbFail("GetGameInstanceSubsystem", err) end
    return nil
end

local perHud = {}                 -- id -> {at = burst start, roots = {[HUD root address] = true}}
local function beforeAdd(fr, id, h, v)
    local p, via, kind, rootKey = takePoster()
    local lname = msgCont(id)
    if lname ~= nil and not HUDCONT[lname] then return end          -- a dialog / front-end message: untouched
    local m = MSGTAB[id]
    if m and m.global then p, via = nil, tostring(via) .. "; global row" end
    if m and m.perHud and kind == "hud" then
        -- every HUD instance posts it once per eliminated racer (P1's, each guest's, the game's hidden one; never the
        -- eliminated player's own HUD): the first post of a burst is shown in every half at once, the other HUDs'
        -- duplicates are hidden (else each half waits for the others' copies). Review 0.7.0: a burst = one racer. It
        -- ends after 1.5 s OR when a HUD that already posted in it posts again (the next racer's broadcast): two racers
        -- out within 1.5 s give two messages, as with one HUD.
        local now = St.nowMs()
        local rk = rootKey or 0
        local b = perHud[id]
        if b == nil or now - b.at > 1500 or b.roots[rk] then
            perHud[id] = { at = now, roots = { [rk] = true } }
            p, via = nil, tostring(via) .. "; first copy of a per-HUD message: every half"
        else
            b.roots[rk] = true
            p, via = -1, tostring(via) .. "; duplicate of a per-HUD message"
        end
    end
    fr.kind, fr.id, fr.pnum, fr.via, fr.lname, fr.h, fr.v = "add", id, p, via, lname, h, v
    fr.snap = snapshot(lname)
end

-- AddMessage pre (ctx, MessageID, MessageHandle, Delegate, Payload, HAlign, VAlign)
local function onAddPre(ctx, idP, handleP, delP, payloadP, hP, vP)
    if not A.msg then return nil end
    local fr = { kind = "skip" }
    frames[#frames + 1] = fr                       -- pushed first: the post pops exactly one frame per call
    local ok, err = pcall(function()
        local h, v = 0, 0
        pcall(function() h = hP:get() end)
        pcall(function() v = vP:get() end)
        beforeAdd(fr, idP:get():ToString(), h, v)
    end)
    if not ok then cbFail("AddMessage pre", err) end
    return nil
end

-- AddMessageParams pre (ctx, Struct<GfnMessagingParams>{ID, Parameters, ...}, Delegate)
local function onAddParamsPre(ctx, paramsP)
    if not A.msg then return nil end
    local fr = { kind = "skip" }
    frames[#frames + 1] = fr
    local ok, err = pcall(function() beforeAdd(fr, paramsP:get().ID:ToString(), 0, 0) end)
    if not ok then cbFail("AddMessageParams pre", err) end
    return nil
end

-- AddMessage post (ctx, params...) / AddMessageParams post (ctx, ReturnValue, params...): arguments not used.
local function onAddPost()
    if not A.msg then return nil end
    local fr = table.remove(frames)
    if not fr or fr.kind ~= "add" then return nil end
    local ok, err = pcall(afterAdd, fr)
    if not ok then cbFail("AddMessage post", err) end
    return nil
end

-- RemoveMessage pre (ctx, MessageID, IncludePendingMessages, OptionalMessageHandle). Every Blueprint call site passes an
-- empty handle = every instance of the id (ux-split-messages §2).
local function onRemovePre(ctx, idP, incP)
    if not A.msg then return nil end
    local fr = { kind = "skip" }
    frames[#frames + 1] = fr
    local ok, err = pcall(function()
        local id = idP:get():ToString()
        local p, via = takePoster()
        fr.kind, fr.id, fr.pnum, fr.via = "remove", id, p, via
        fr.survivors = survivorsOf({ id }, p)
        local inc = false
        pcall(function() inc = incP:get() == true end)
        if inc then dropPendingId(id) end
    end)
    if not ok then cbFail("RemoveMessage pre", err) end
    return nil
end

local function onRemovePost()
    if not A.msg then return nil end
    local fr = table.remove(frames)
    if not fr or fr.kind ~= "remove" then return nil end
    local ok, err = pcall(afterRemove, fr, "RemoveMessage")
    if not ok then cbFail("RemoveMessage post", err) end
    return nil
end

-- FlushMessageContainer pre (ctx, Container): BP_VehicleUIComponent flushes the crash feed when ITS tumble ends.
local function onFlushPre(ctx, contP)
    if not A.msg then return nil end
    local fr = { kind = "skip" }
    frames[#frames + 1] = fr
    local ok, err = pcall(function()
        local cn = contP:get():ToString()
        local lname = lower(cn)
        local p, via = takePoster()
        local ids = {}
        for id in pairs(active) do if msgCont(id) == lname then ids[#ids + 1] = id end end
        fr.kind, fr.cont, fr.pnum, fr.via = "flush", cn, p, via
        fr.survivors = survivorsOf(ids, p)
    end)
    if not ok then cbFail("FlushMessageContainer pre", err) end
    return nil
end

local function onFlushPost()
    if not A.msg then return nil end
    local fr = table.remove(frames)
    if not fr or fr.kind ~= "flush" then return nil end
    local ok, err = pcall(afterRemove, fr, "FlushMessageContainer")
    if not ok then cbFail("FlushMessageContainer post", err) end
    return nil
end

-- RemoveMessageByHandle (ctx, MessageHandle): one instance only (TakendownBy, autopilot, disruptor): nothing to re-post;
-- a copy that waited may show now.
local function onHandlePre()
    if not A.msg then return nil end
    last = nil
    frames[#frames + 1] = { kind = "handle" }
    return nil
end

local function onHandlePost()
    if not A.msg then return nil end
    local fr = table.remove(frames)
    if not fr or fr.kind ~= "handle" then return nil end
    local ok, err = pcall(function()
        S.n.removes = S.n.removes + 1
        sweepGone()
        if next(pending) ~= nil then scan("RemoveMessageByHandle", true) end
    end)
    if not ok then cbFail("RemoveMessageByHandle post", err) end
    return nil
end

-- Wrecked / spectating players hold nothing any more (no re-post for them; their HUD is hidden by hud.lua).
local function isOut(e)
    local w = St.wreck
    return type(w) == "table" and w.gen == St.worldGen and type(w.seen) == "table" and w.seen[e.pcKey] == true
end

local function dropOutPlayers()
    for _, e in ipairs(E.list) do
        if isOut(e) then
            for id, a in pairs(active) do
                a[e.pnum] = nil
                if next(a) == nil then active[id] = nil end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- testcmd helpers
-- `lua return require("uxsplit").testPost(2, "PerfectLanding")`: posts a message as player p (no driving needed) and
-- returns the routing line. `testRemove(p, id)`: RemoveMessage(id) as player p (re-posts for the other holders).
function M.testPost(p, id)
    if not A.msg then return "messages not armed (" .. tostring(S.why) .. ")" end
    if not U.ok(MSUB) then return "no messaging subsystem" end
    id = tostring(id or "PerfectLanding")
    local prev = forced
    forced = { pnum = tonumber(p), why = "testcmd" }
    S.lastRoute = "(the AddMessage hooks did not run)"
    local ok, err = pcall(function() MSUB:AddMessage(U.fname(id), {}, nil, nil, 0, 0) end)
    forced = prev
    return ok and S.lastRoute or ("error: " .. tostring(err))
end

function M.testRemove(p, id)
    if not A.msg then return "messages not armed (" .. tostring(S.why) .. ")" end
    if not U.ok(MSUB) then return "no messaging subsystem" end
    id = tostring(id or "WrongWay")
    local before = S.n.reposts
    local prev = forced
    forced = { pnum = tonumber(p), why = "testcmd" }
    local ok, err = pcall(function() MSUB:RemoveMessage(U.fname(id), true, {}) end)
    forced = prev
    if not ok then return "error: " .. tostring(err) end
    local holders = {}
    for q in pairs(active[id] or {}) do holders[#holders + 1] = "P" .. tostring(q) end
    table.sort(holders)
    return fmt("RemoveMessage %s as P%s: %d re-post(s); still held by [%s]", id, tostring(p), S.n.reposts - before,
        table.concat(holders, ","))
end

---------------------------------------------------------------------------------------------------- 3a. HUD colours (MPC)
-- mode "drop": the pre-hook sets Collection := nil (KismetMaterialLibrary::SetVectorParameterValue does nothing without
-- a collection); the first blocked write of a race is read back once. "restore": the value moved anyway, so the default
-- is written back right after each write (a nested KML call, guarded by inWrite).
local COL = { kml = nil, mpc = nil, mpcKey = 0, defaults = {}, mode = "drop", verified = false, inWrite = false,
              name = nil }
local BLOCK = { AfterburnerColor = "AfterburnerColor_Default", HighThreatColor = "HighThreatColor_Default",
                MalfunctionColor = "MalfunctionColor_Default" }

local function readVec(name)
    local kml, mpc, w = COL.kml, COL.mpc, U.world()
    if not (U.ok(kml) and U.ok(mpc) and U.ok(w)) then return nil end
    local ok, v = pcall(function() return kml:GetVectorParameterValue(w, mpc, U.fname(name)) end)
    if not ok or v == nil then return nil end
    local r, g, b, a
    pcall(function() r, g, b, a = tonumber(v.R), tonumber(v.G), tonumber(v.B), tonumber(v.A) end)
    if r and g and b then return { R = r, G = g, B = b, A = a or 1.0 } end
    return nil
end

local function readScalar(mpc, name)
    local kml, w = COL.kml, U.world()
    if not (U.ok(kml) and U.ok(mpc) and U.ok(w)) then return nil end
    local ok, v = pcall(function() return kml:GetScalarParameterValue(w, mpc, U.fname(name)) end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function writeVec(name, col)
    local kml, mpc, w = COL.kml, COL.mpc, U.world()
    if not (U.ok(kml) and U.ok(mpc) and U.ok(w) and col) then return false end
    COL.inWrite = true
    local ok = pcall(function() kml:SetVectorParameterValue(w, mpc, U.fname(name), col) end)
    COL.inWrite = false
    return ok
end

local function near(a, b)
    return a ~= nil and b ~= nil and math.abs(a.R - b.R) < 0.002 and math.abs(a.G - b.G) < 0.002
        and math.abs(a.B - b.B) < 0.002
end

-- SetVectorParameterValue pre (ctx, WorldContextObject, Collection, ParameterName, ParameterValue)
local function colPreInner(wco, coll, name)
    local c = coll:get()
    if c == nil or c:GetAddress() ~= COL.mpcKey then return end
    local n = name:get():ToString()
    if not BLOCK[n] then return end
    S.n.colourBlocks = S.n.colourBlocks + 1
    COL.name = n
    if COL.mode == "drop" then coll:set(nil) end
    local who = "?"                                   -- rare (a HUD's construct / its player's health change): logged
    pcall(function()
        local r = rootOf(wco:get())
        who = (r == "foreign") and "the game's hidden HUD" or (type(r) == "table" and pdesc(r.pnum) .. "'s HUD" or "?")
    end)
    U.logEvery("ux.col." .. n, 5000, TAG, "MPC %s <- last-crash colour by %s: blocked, the global HUD colour stays neutral "
        .. "(%s) (V-UX-07)", n, who, COL.mode)
end

local function onColPre(ctx, wco, coll, name)
    if not A.colours or COL.inWrite then return nil end
    local ok, err = pcall(colPreInner, wco, coll, name)
    if not ok then cbFail("SetVectorParameterValue pre", err) end
    return nil
end

-- VERIFY(V-UX-07): Collection := nil in the pre-hook reaches the native call (the read-back says "still the default");
-- else restore mode. Fallback: UxSplitHudColours=false.
local function colPostInner()
    local n = COL.name
    COL.name = nil
    if n == nil or (COL.mode == "drop" and COL.verified) then return end
    local def = COL.defaults[n]
    if COL.mode == "drop" then
        local cur = readVec(n)
        if cur == nil or def == nil or near(cur, def) then
            COL.verified = true
            U.log(TAG, "MPC %s write dropped: value %s (V-UX-07)", n, cur and "still the default" or "not readable")
            return
        end
        COL.mode = "restore"
        U.warn(TAG, "MPC %s changed although its Collection was set to nil (the rewrite did not reach the call): the default "
            .. "is written back after each write from now on (V-UX-07)", n)
    end
    if writeVec(n, def) then S.n.colourRestores = S.n.colourRestores + 1 end
end

local function onColPost()
    if not A.colours or COL.inWrite then return nil end
    local ok, err = pcall(colPostInner)
    if not ok then cbFail("SetVectorParameterValue post", err) end
    return nil
end

-- Review 0.7.0: arming after a HUD already wrote its red *_LastCrash values (a re-arm mid-race, a hot reload with a
-- player on its last life) would keep them world-wide, since the HUD's later write back to *_Default is dropped from
-- now on: each colour still away from its default is written back once (COL.inWrite keeps our own hook out).
local function resetColours()
    local done = {}
    for n in pairs(BLOCK) do
        local def, cur = COL.defaults[n], readVec(n)
        if def and cur and not near(cur, def) and writeVec(n, def) then done[#done + 1] = n end
    end
    table.sort(done)
    if #done > 0 then
        U.log(TAG, "MPC %s reset to the default when arming (a last-crash colour was left) (V-UX-07)",
            table.concat(done, ", "))
    end
end

---------------------------------------------------------------------------------------------------- 3b. ramjet sweep
local RJ = { lastPin = -1e12 }

-- PlayAnimation post (ctx, ReturnValue, InAnimation, ...): EngageRamjet / DisengageRamjet of a BotEngineInfo.
-- VERIFY(V-UX-08): StopAnimation right after PlayAnimation leaves FadeDirection/FadeProgress untouched (probe 1.00/-1.00).
-- Fallback: UxSplitRamjetColour=false.
local function rjPostInner(ctx, anim)
    local a = anim:get()
    if a == nil then return end
    local kind = E.rj[U.key(a)]
    if not kind then return end
    local w = ctx:get()
    if not U.ok(w) then return end
    pcall(function() w:StopAnimation(a) end)
    S.n.rjStops = S.n.rjStops + 1
    local ab, rj = FX.IconFull, FX.IconDim                      -- the animation's end state: Engage dims the
    if kind == "engage" then ab, rj = FX.IconDim, FX.IconFull end -- afterburner icon and lights the ramjet one
    pcall(function() w.Img_AfterburnerIcon:SetColorAndOpacity(ab) end)
    pcall(function() w.Img_RamjetIcon:SetColorAndOpacity(rj) end)
    local who = "?"
    pcall(function()
        local r = rootOf(w)
        who = (r == "foreign") and "the game's hidden HUD" or (type(r) == "table" and pdesc(r.pnum) or "?")
    end)
    U.logEvery("ux.rj." .. kind .. who, 3000, TAG, "%s stopped on %s's BotEngineInfo: icons set, the global ramjet colour "
        .. "kept (V-UX-08)", kind == "engage" and "EngageRamjet" or "DisengageRamjet", who)
end

local function onAnimPost(ctx, ret, anim)
    if not A.ramjet or E.rjCount == 0 then return nil end
    local ok, err = pcall(rjPostInner, ctx, anim)
    if not ok then cbFail("PlayAnimation", err) end
    return nil
end

-- FadeDirection 1 / FadeProgress -1 (orange, no sweep) every second: a construct / destruct of a BotEngineInfo also
-- writes FadeDirection from its own car's boost state.
-- 0.13.0: the ramjet bar's fill only shows in the ramjet colour state (pinned orange, the split bar never filled: live
-- 2026-10-12 19:0x). The MPC is ONE value for every HUD, so it goes to the ramjet state (FadeDirection 0 /
-- FadeProgress -1, read live 20:00 while a car sat in ramjet mode) only while some local car is FIRING its ramjet
-- (RamjetState 3-7: on, overheating, exploding); R3 alone (ramjet mode, charging) keeps every HUD orange.
local function anyRamjetFiring()
    for _, e in ipairs(U.localPlayers()) do
        local ok, st = pcall(function()
            local car = e.pc.Pawn
            if not (U.ok(car) and U.isVehicle(car)) then return 0 end
            return tonumber(car.VehicleState.RamjetState) or 0
        end)
        if ok and st and st >= 3 and st <= 7 then return true end
    end
    return false
end

local function pinRamjet(now, force)
    local blue = cfg.UxSplitRamjetFiringBlue ~= false and anyRamjetFiring()
    if not force and blue == RJ.blue and now - RJ.lastPin < 1000 then return end
    if blue ~= RJ.blue then
        U.log(TAG, "ramjet colour (every HUD): %s (V-UX-08)", blue and "ramjet state, a local car fires its ramjet"
            or "orange")
    end
    RJ.lastPin, RJ.blue = now, blue
    local kml, mpc, w = COL.kml, COL.mpc, U.world()
    if not (U.ok(kml) and U.ok(mpc) and U.ok(w)) then return end
    pcall(function() kml:SetScalarParameterValue(w, mpc, U.fname("FadeDirection"), blue and 0.0 or 1.0) end)
    -- FadeProgress +1 (sweep done), NOT -1: at -1 the ramjet bar's two boxes render their fill nearly invisible
    -- (matrix test 2026-10-12 21:5x, b2-a..e: fill faint at FP=-1, clear at FP=0..1 under FD=1 orange)
    pcall(function() kml:SetScalarParameterValue(w, mpc, U.fname("FadeProgress"), 1.0) end)
end

---------------------------------------------------------------------------------------------------- 3c. full-screen effects
local fsLogged = false
-- GetFullScreenEffectsEnabled post (ctx, ReturnValue): false while split, not paused, no photo mode.
-- VERIFY(V-UX-09): BP_VehicleState reads the override every Tick (ConditionEffects_Off: probe VS_vfx FinalLife=0.00).
-- Fallback: UxSplitFullScreenFx=false.
local function onFsfxPost()
    if A.fsfxOverride then
        S.n.fsfx = S.n.fsfx + 1
        return false
    end
    return nil
end

---------------------------------------------------------------------------------------------------- 3d. per-player tints / fades
local T = {}                      -- HUD widget address -> tint name applied ("none" | "danger" | "ramjet")
local F = {}                      -- PC address -> {a, applied, malf, crashAt, flashUntil, foreignUntil}
local MALF = nil                  -- {TagName = FName("Vehicle.Condition.Malfunction")}
local FADE_AMT, FADE_FLAGS = "SWGRCouchFadeAmount", "SWGRCouchFadeFlags"   -- wreck.lua / crashcam.lua custom properties
local fadeReg = { tried = false, bad = false }

local function racerComp(pc)
    local ps
    local okT, tko = pcall(U.mod, "takeover")
    if okT and type(tko) == "table" and type(tko.racerPSFor) == "function" then
        local okP, p = pcall(tko.racerPSFor, pc)
        if okP and U.ok(p) then ps = p end
    end
    if not ps then pcall(function() ps = pc.PlayerState end) end
    local comp
    if U.ok(ps) then pcall(function() comp = ps.RaceEventComponent end) end
    return U.ok(comp) and comp or nil
end

local function carOf(e)
    local car, vs
    pcall(function() car = e.pc.Pawn end)
    if not U.isVehicle(car) then return nil, nil end
    pcall(function() vs = car.VehicleState end)
    return car, U.ok(vs) and vs or nil
end

-- Camera fade fields of a PlayerCameraManager (not reflected): the custom properties wreck.lua / crashcam.lua register
-- (FadeAmount = DefaultAspectRatio + 0x14, bEnableFading = bit 3 of bDefaultConstrainAspectRatio's byte); registered
-- here with the same names and offsets when neither module did yet. {enabled, amount} or nil.
local function fadeState(pcm)
    if fadeReg.bad or not U.ok(pcm) then return nil end
    local okA, a = pcall(function() return pcm[FADE_AMT] end)
    local okF, f = pcall(function() return pcm[FADE_FLAGS] end)
    if (not okA or type(a) ~= "number") and not fadeReg.tried and cfg.WreckFadeRead ~= false
        and type(RegisterCustomProperty) == "function" and type(PropertyTypes) == "table" then
        fadeReg.tried = true
        local cls = "/Script/Engine.PlayerCameraManager"
        pcall(RegisterCustomProperty, { Name = FADE_AMT, Type = PropertyTypes.FloatProperty, BelongsToClass = cls,
            OffsetInternal = { Property = "DefaultAspectRatio", RelativeOffset = 0x14 } })
        pcall(RegisterCustomProperty, { Name = FADE_FLAGS, Type = PropertyTypes.ByteProperty, BelongsToClass = cls,
            OffsetInternal = { Property = "bDefaultConstrainAspectRatio", RelativeOffset = 0 } })
        okA, a = pcall(function() return pcm[FADE_AMT] end)
        okF, f = pcall(function() return pcm[FADE_FLAGS] end)
    end
    if not okA or not okF or type(a) ~= "number" or type(f) ~= "number" then return nil end
    if a ~= a or a < -0.01 or a > 1.01 then
        fadeReg.bad = true
        U.warn(TAG, "camera fade fields not trusted (FadeAmount reads %s): fades only on changes", tostring(a))
        return nil
    end
    return { enabled = (floor(f) // 8) % 2 == 1, amount = a }
end

-- "own": each HUD root is tinted from ITS player's state, written only on a change (UserWidget:SetColorAndOpacity
-- multiplies every child; WBP_Hud_Race's animations target children only). Last crash (health 1) wins over ramjet.
local TINTS = { none = FX.TintNone, danger = FX.TintLastCrash, ramjet = FX.TintRamjet }
local function tintTick(ps)
    for _, e in ipairs(E.list) do
        local want = "none"
        if A.own then
            local st = ps[e.pcKey] or {}
            local comp = st.comp
            local hp
            if comp then pcall(function() hp = comp.VehicleHealth end) end      -- the BP's own test: Health == 1
            if A.colours and hp == 1 then
                want = "danger"
            elseif A.ramjet then
                local vs = st.vs
                local bs
                if vs then pcall(function() bs = vs.BoostState end) end        -- EBoostState: 3 MovingToRamjet, 4 Ramjet
                if type(bs) == "number" and bs >= 3 then want = "ramjet" end
            end
        end
        -- review 0.7.0: validated first; and a HUD with no record gets TintNone once too (a tint left by a quiet disarm
        -- or a hot reload is cleared; white = the UserWidget default, its animations target children only)
        local prev = T[e.wKey]
        if prev ~= want and U.ok(e.widget) then
            local col = TINTS[want]
            if col and pcall(function() e.widget:SetColorAndOpacity(col) end) then
                T[e.wKey] = want
                S.tint[e.pnum] = want
                if prev ~= nil or want ~= "none" then
                    S.n.tints = S.n.tints + 1
                    U.log(TAG, "P%s HUD tint: %s (V-UX-%s)", tostring(e.pnum), want == "danger" and "danger (last crash)"
                        or want, want == "ramjet" and "08" or (want == "danger" and "07" or "07/08"))
                end
            end
        end
    end
end

-- "own" + full-screen effects off: each player's last life / system malfunction through its OWN camera fade. Skipped
-- while the view is not the player's own car (crash camera, spectate, cinematic), while it crashes (+2 s: the game's
-- reset fade), when it is wrecked (wreck.lua owns that view; its guard clears what is left), in a single-view phase,
-- paused, in photo mode, and while another fade runs (read through the fade fields when readable).
local function fadeTick(now, blocked, ps)
    local maxA = math.min(math.max(tonumber(cfg.UxSplitFadeMax) or 0.2, 0.0), 0.45)
    for _, e in ipairs(E.list) do
        local f = F[e.pcKey]
        if not f then f = { a = 0 }; F[e.pcKey] = f end
        local st = ps[e.pcKey] or {}
        local car, vs, comp = st.car, st.vs, st.comp
        local pcOk = U.ok(e.pc)                                -- review 0.7.0: stored PC wrapper validated first
        local pcm
        if pcOk then pcall(function() pcm = e.pc.PlayerCameraManager end) end
        local out = isOut(e)
        local usable = pcOk and (not blocked) and (not out) and car ~= nil and vs ~= nil and comp ~= nil and U.ok(pcm)
        if usable then
            local okV, vt = pcall(function() return e.pc:GetViewTarget() end)
            usable = okV and U.key(vt) == U.key(car)
        end
        if out then f.applied, f.a = nil, 0 end
        if not usable then
            f.malf = nil
        else
            local tumbling, final, malf = false, false, false
            pcall(function() tumbling = vs:IsTumbling() == true end)
            pcall(function() final = comp:ShouldNextCrashWreckVehicle() == true end)
            pcall(function() malf = vs:IsConditionTagActive(MALF) == true end)
            if tumbling then f.crashAt = now end
            local quiet = tumbling or now - (f.crashAt or -1e12) < CRASH_GRACE_MS or now < (f.foreignUntil or 0)
            local fs = fadeState(pcm)
            if not quiet and now >= (f.flashUntil or 0) and fs and fs.enabled and fs.amount > 0.02
                and (f.applied == nil or math.abs(fs.amount - f.applied) > 0.02) then
                f.foreignUntil, quiet = now + 1000, true             -- someone else's fade (reset, cinematic): left alone
            end
            if malf and f.malf == false and not quiet then
                if pcall(function() pcm:StartCameraFade(0.35, 0.0, 0.6, FX.FlashColour, false, false) end) then
                    f.flashUntil, f.applied = now + 700, nil
                    S.n.flashes = S.n.flashes + 1
                    U.logEvery("ux.flash" .. tostring(e.pnum), 3000, TAG, "P%s system malfunction: camera flash in its own "
                        .. "view (V-UX-09)", tostring(e.pnum))
                end
            end
            f.malf = malf
            local target = (final and not tumbling) and maxA or 0
            if target > f.a then f.a = math.min(target, f.a + maxA * 0.05) else f.a = target end   -- up over 2 s
            if not quiet and now >= (f.flashUntil or 0) then
                if f.a > 0.005 then
                    if f.applied == nil or math.abs(f.applied - f.a) > 0.004 or (fs ~= nil and not fs.enabled) then
                        if pcall(function() pcm:SetManualCameraFade(f.a, FX.FadeColour, false) end) then
                            if f.applied == nil then
                                S.n.fades = S.n.fades + 1
                                U.logEvery("ux.fade" .. tostring(e.pnum), 3000, TAG, "P%s last life: camera tint in its own "
                                    .. "view (up to %.2f) (V-UX-09)", tostring(e.pnum), maxA)
                            end
                            f.applied = f.a
                        end
                    end
                elseif f.applied ~= nil then
                    pcall(function() pcm:StopCameraFade() end)
                    f.applied = nil
                end
            end
        end
        S.fade[e.pnum] = f.applied or 0
    end
end

-- Gives back tints and fades (disarm while the world is alive): our manual fade, or a flash still running.
local function stopFadeOf(pc)
    if not U.ok(pc) then return false end                     -- review 0.7.0: validated before any member access
    local pcm
    pcall(function() pcm = pc.PlayerCameraManager end)
    return U.ok(pcm) and pcall(function() pcm:StopCameraFade() end) or false
end

local function restoreLooks()
    local now = St.nowMs()
    for _, e in ipairs(E.list) do
        if T[e.wKey] ~= nil and T[e.wKey] ~= "none" and U.ok(e.widget) then
            pcall(function() e.widget:SetColorAndOpacity(FX.TintNone) end)
        end
        local f = F[e.pcKey]
        if f and (f.applied ~= nil or now < (f.flashUntil or 0)) and not isOut(e) then stopFadeOf(e.pc) end
    end
    T, F = {}, {}
end

-- Review 0.7.0: a QUIET disarm (the world may be going away: nothing is touched) leaves hidden copies, tints and our
-- camera fades in place, and the next arm starts from empty records. They are kept here with the world generation and
-- given back when the module arms again in the SAME world (a phase blip, a cancelled "leaving"); another world's
-- objects are dropped untouched. Not covered: RestartCurrentMod (a new Lua state: the guest HUDs and the P1 clone are
-- re-created; a last-life fade is re-applied while it lasts, wreck.lua clears what a wreck leaves).
local LEFT = nil
local function keepLeftovers()
    local L = { gen = St.worldGen, copies = {}, tints = {}, fades = {} }
    for _, h in pairs(hidden) do L.copies[#L.copies + 1] = h end
    for _, e in ipairs(E.list) do
        if T[e.wKey] ~= nil and T[e.wKey] ~= "none" then L.tints[#L.tints + 1] = e.widget end
        local f = F[e.pcKey]
        if f and f.applied ~= nil then L.fades[#L.fades + 1] = { pc = e.pc, pcKey = e.pcKey } end
    end
    LEFT = (#L.copies + #L.tints + #L.fades > 0) and L or nil
end

local function giveBackLeftovers()
    local L = LEFT
    LEFT = nil
    if not L or L.gen ~= St.worldGen then return end
    local nc, nt, nf = 0, 0, 0
    for _, h in ipairs(L.copies) do if showAgain(h) then nc = nc + 1 end end
    for _, w in ipairs(L.tints) do
        if U.ok(w) and pcall(function() w:SetColorAndOpacity(FX.TintNone) end) then nt = nt + 1 end
    end
    for _, x in ipairs(L.fades) do
        if not isOut(x) and stopFadeOf(x.pc) then nf = nf + 1 end
    end
    if nc + nt + nf > 0 then
        U.log(TAG, "armed again in the same world: given back what the quiet disarm left: %d hidden cop(ies), %d HUD "
            .. "tint(s), %d camera fade(s)", nc, nt, nf)
    end
end

---------------------------------------------------------------------------------------------------- arming
local function msgMode()
    local m = cfg.UxSplitMessages
    if m == "route" or m == "all" or m == "off" then return m end
    return "route"
end

local function dangerMode()
    local d = cfg.UxSplitDanger
    if d == "own" or d == "neutral" or d == "off" then return d end
    return "own"
end

local function wantArmed()
    local ph = St.phase
    if ph ~= "PRERACE" and ph ~= "RACING" then return false, "phase " .. tostring(ph) end
    if St.race.singleView == true then return false, "single-view race" end
    local n = #U.localPlayers()
    if n < 2 then return false, fmt("%d local player", n) end
    return true, fmt("%d local players", n)
end

-- Per-race tables (the counters stay readable after the race; they are reset when arming again).
local function clearRace()
    frames, tags, hidden, seen, pending, active, unknownLogged = {}, {}, {}, {}, {}, {}, {}
    last, forced, creating, perHud = nil, nil, nil, {}
    KIND = {}                         -- review 0.7.0: class addresses repeat once a race's Blueprint classes unload
    E.list, E.byRoot, E.byPc, E.foreign, E.sig, E.dirty, E.rj, E.rjCount = {}, {}, {}, {}, "", true, {}, 0
    E.keysig = nil
    T, F = {}, {}
    COL.mode, COL.verified, COL.name, COL.inWrite, COL.defaults = "drop", false, nil, false, {}
    fsLogged = false
end

local function onOff(v) return v and "on" or "off" end

-- Arms the module if a split race runs (game thread: ticks, hud.lua's HUD creation). Returns true when armed.
function M.ensureArmed(why)
    if A.on then return true end
    local want, reason = wantArmed()
    if not want then return false end
    local mm, dm = msgMode(), dangerMode()
    if mm == "off" and dm == "off" and cfg.UxSplitIndexRemap == false then
        U.logOnce("ux.alloff", TAG, "UxSplitMessages, UxSplitIndexRemap and UxSplitDanger are all off: nothing armed")
        return false
    end
    U.try(TAG, giveBackLeftovers)     -- review 0.7.0: what a quiet disarm in this same world left
    clearRace()
    S.n, S.tint, S.fade, S.verdicts, S.lastRoute = counters(), {}, {}, {}, ""
    A.on = true
    S.armed, S.why, S.since, S.arms = true, fmt("%s, %s", tostring(why), reason), St.nowMs(), S.arms + 1
    -- objects resolved here, never inside a callback (StaticFindObject only: the race map loaded them)
    local okC, cls = pcall(StaticFindObject, C.CLASS.GfnMessagingSubsystem)
    MS_CLASS_KEY = okC and U.key(cls) or 0
    MSUB = U.giSubsystem("GfnMessagingSubsystem")
    COL.kml = U.cdo("KismetMaterialLibrary")
    local okM, mpc = pcall(StaticFindObject, C.ASSET.MPC_HUD)
    COL.mpc = (okM and U.ok(mpc)) and mpc or nil
    COL.mpcKey = U.key(COL.mpc)
    MALF = { TagName = U.fname("Vehicle.Condition.Malfunction") }
    refreshEntries()
    if mm ~= "off" then
        if MS_CLASS_KEY ~= 0 and U.ok(MSUB) then
            local ok = hook(C.FN.GIS, onGisPre, nil)          -- review 0.7.0: pre only (no Lua post call per call)
            ok = hook(C.FN.MsgAdd, onAddPre, onAddPost) and ok
            ok = hook(C.FN.MsgAddParams, onAddParamsPre, onAddPost) and ok
            ok = hook(C.FN.MsgRemove, onRemovePre, onRemovePost) and ok
            ok = hook(C.FN.MsgRemoveByHandle, onHandlePre, onHandlePost) and ok
            ok = hook(C.FN.MsgFlush, onFlushPre, onFlushPost) and ok
            A.msg, A.route = ok, ok and mm == "route"
            if A.msg then onEntriesChanged() end
        else
            U.warn(TAG, "messages: GfnMessagingSubsystem %s: no routing this race",
                MS_CLASS_KEY == 0 and "class not found" or "subsystem not found")
        end
    end
    if cfg.UxSplitIndexRemap ~= false then A.remap = hook(C.FN.GetPlayerPawn, noop, onRemapPost) end
    if dm ~= "off" then
        A.own = (dm == "own")
        if cfg.UxSplitHudColours ~= false then
            if COL.mpc and U.ok(COL.kml) then
                for n, dn in pairs(BLOCK) do COL.defaults[n] = readVec(dn) or (FX.Defaults or {})[n] end
                A.colours = hook(C.FN.KmlSetVector, onColPre, onColPost)
                if A.colours then U.try(TAG, resetColours) end   -- review 0.7.0: a red left by an earlier write
            else
                U.warn(TAG, "HUD colours: %s: the last-crash colours stay global",
                    COL.mpc and "no KismetMaterialLibrary" or "MPC_HUD_Parameters not loaded")
            end
        end
        if cfg.UxSplitRamjetColour ~= false then
            A.ramjet = hook(C.FN.PlayAnimation, noop, onAnimPost)
            if A.ramjet then pinRamjet(St.nowMs(), true) end
        end
        if cfg.UxSplitFullScreenFx ~= false then A.fsfx = hook(C.FN.FullScreenFx, noop, onFsfxPost) end
    end
    U.log(TAG, "armed (%s): HUDs %s; messages %s, index remap %s, danger %s (HUD colours %s, ramjet %s, full-screen "
        .. "effects %s); %d hook(s) (V-UX-01..09)", S.why, E.sig ~= "" and E.sig or "none yet",
        A.msg and (A.route and "routed" or "logged only (all)") or "off", onOff(A.remap), dm, onOff(A.colours),
        onOff(A.ramjet), onOff(A.fsfx), hookCount())
    return true
end

-- quiet: the world is going away ("leaving" fires inside the LoadMap pre-hook): only the hooks are removed.
-- VERIFY(V-UX-13): "disarmed (phase POSTRACE): 10 hook(s) off" before the results screen is left; no crash on the way
-- back to the menu (run H: the probe's hooks, still registered across that travel, crashed in UE4SS's dispatch).
function M.disarm(why, quiet)
    if not A.on then return end
    local hadRamjet = A.ramjet
    A.on, A.msg, A.route, A.remap, A.colours, A.ramjet, A.fsfx, A.fsfxOverride, A.own =
        false, false, false, false, false, false, false, false, false
    local n = unhookAll(why)
    if not quiet then
        for k in pairs(hidden) do unhideCopy(k) end
        restoreLooks()
        if hadRamjet then pinRamjet(St.nowMs(), true) end
    else
        keepLeftovers()               -- review 0.7.0: given back if the module arms again in this same world
    end
    S.armed, S.why = false, "disarmed: " .. tostring(why)
    local c = S.n
    U.log(TAG, "disarmed (%s): %d hook(s) off; %d post(s), %d copies (%d hidden, %d waited, %d shown after waiting, "
        .. "%d shared), %d re-post(s) (%d failed), %d unattributed, %d remap(s) (%d without a car), %d colour block(s) "
        .. "(%d restore(s)), %d ramjet stop(s), %d full-screen override(s), %d fade(s), %d flash(es), %d tint "
        .. "change(s), %d callback error(s) (V-UX-13)", tostring(why), n, c.posts, c.copies, c.hidden, c.queued, c.promoted,
        c.shared, c.reposts, c.repostFail, c.unknown, c.remaps, c.remapMiss, c.colourBlocks, c.colourRestores, c.rjStops,
        c.fsfx, c.fades, c.flashes, c.tints, c.cbErrors)
    clearRace()
end

-- hud.lua (ensureGuest): Construct runs INSIDE AddToPlayerScreen, so the HUD is announced before it is added (the
-- index remap knows it by address) and released after its TransitionIn.
function M.hudCreating(w, pc, pnum)
    if not A.on then M.ensureArmed("HUD creation") end
    creating = { rootKey = U.key(w), pc = pc, pcKey = U.key(pc), pnum = tonumber(pnum) or 1, at = St.nowMs() }
end

function M.hudCreated()
    creating = nil
    E.dirty = true
end

-- hud.lua (removeGuest), review 0.7.0: a HUD left the registry. Its entry is dropped at once (no callback walks its
-- containers until the next refresh) and the list is refreshed on the next tick.
function M.hudRemoved(w)
    E.dirty = true
    local k = U.key(w)
    local gone = (k ~= 0) and E.byRoot[k] or nil
    if not gone then return end
    local keep = {}
    for _, e in ipairs(E.list) do if e ~= gone then keep[#keep + 1] = e end end
    E.list, E.byRoot[k] = keep, nil
    if E.byPc[gone.pcKey] == gone then E.byPc[gone.pcKey] = nil end
end

---------------------------------------------------------------------------------------------------- ticks
local fastN, pausedV, lastScan, lastProbe = 0, false, -1e12, -1e12

-- This tick's pause state: pause.lua's (pause.poll runs earlier in the same FAST tick, main.lua), else U.csmPaused().
local function pausedThisTick()
    local P = St.pause
    if type(P) == "table" and P.menuWasPaused ~= nil then return P.menuWasPaused == true end
    return U.csmPaused() == true
end

local function photoOn()
    local ok, ph = pcall(U.mod, "phase")
    if ok and type(ph) == "table" and type(ph.photoMode) == "function" then
        local ok2, v = pcall(ph.photoMode)
        return ok2 and v == true
    end
    return false
end

local function singleView()
    local ok, pr = pcall(U.mod, "present")
    if ok and type(pr) == "table" and type(pr.isSingleView) == "function" then
        local ok2, v = pcall(pr.isSingleView)
        return ok2 and v == true
    end
    return false
end

local function f2(x) return type(x) == "number" and fmt("%.2f", x) or "?" end

-- VERIFY(V-UX-11): one probe line per cfg.UxSplitProbeMs while armed (MPC values, tints, fades, counters).
local function probe(now)
    local every = tonumber(cfg.UxSplitProbeMs) or 0
    if every <= 0 or now - lastProbe < every then return end
    lastProbe = now
    local af = COL.mpc and readVec("AfterburnerColor") or nil
    local vfx
    pcall(function() local o = StaticFindObject(C.ASSET.MPC_VehicleVfx); if U.ok(o) then vfx = o end end)
    local tints, fades = {}, {}
    for _, e in ipairs(E.list) do
        tints[#tints + 1] = fmt("P%s=%s", tostring(e.pnum), tostring(S.tint[e.pnum] or "none"))
        fades[#fades + 1] = fmt("P%s=%s", tostring(e.pnum), f2(tonumber(S.fade[e.pnum]) or 0))
    end
    local c = S.n
    U.log(TAG, "probe MPC Afterburner=%s FadeDir=%s FadeProg=%s | VS_vfx FinalLife=%s Malf=%s Wreck=%s | tint %s | fade %s "
        .. "| msgs posts=%d copies=%d hidden=%d waited=%d unattributed=%d reposts=%d | remaps=%d rjStops=%d fsfx=%d "
        .. "(V-UX-11)", af and fmt("(%.2f,%.2f,%.2f)", af.R, af.G, af.B) or "?", f2(readScalar(COL.mpc, "FadeDirection")),
        f2(readScalar(COL.mpc, "FadeProgress")), f2(readScalar(vfx, "VehicleFinalLife")),
        f2(readScalar(vfx, "MalfunctionTrigger")), f2(readScalar(vfx, "Wreck")), table.concat(tints, " "),
        table.concat(fades, " "), c.posts, c.copies, c.hidden, c.queued, c.unknown, c.reposts, c.remaps, c.rjStops, c.fsfx)
end

-- FAST (main.lua, race phases): hidden copies, waiting copies, and every ~100 ms the overrides, tints and fades.
function M.fastTick()
    if not A.on then return end
    last = nil                        -- a GetGameInstanceSubsystem context never serves a later tick's post
    if #frames > 0 then
        U.logEvery("ux.frames", 10000, TAG, "WARN %d hooked call(s) without their post-step dropped", #frames)
        frames = {}
    end
    if E.dirty then refreshEntries() end
    local now = St.nowMs()
    -- review 0.7.0: EVERY tick, from this tick's pause state: the 0.7.0 draft re-read it at most every 200 ms on every
    -- 3rd tick, so for up to ~300 ms after each resume the world ran with the game's shared full-screen effects
    pausedV = pausedThisTick()
    local photo = photoOn()
    A.fsfxOverride = A.fsfx and not pausedV and not photo
    if A.msg then maintainHidden(now) end
    fastN = fastN + 1
    if fastN % 3 ~= 0 then return end
    -- ~100 ms: copies that waited in a full container (a scan reads every child's text: not every 33 ms)
    if A.msg and next(pending) ~= nil then scan("timer", true) end
    if S.n.fsfx > 0 and not fsLogged then
        fsLogged = true
        U.log(TAG, "GetFullScreenEffectsEnabled -> false while split (BP_VehicleState's effects follow one player and "
            .. "cover every view): %s (V-UX-09)", A.own and "each player's last life / malfunction is shown in its own view"
            or "no per-player replacement (UxSplitDanger neutral)")
    end
    if A.own then
        local ps = {}                 -- each player's car / VehicleState / race component, read once for both
        for _, e in ipairs(E.list) do
            if U.ok(e.pc) then        -- review 0.7.0: a stored PC wrapper is validated before any member access
                local car, vs = carOf(e)
                ps[e.pcKey] = { car = car, vs = vs, comp = racerComp(e.pc) }
            end
        end
        tintTick(ps)
        if A.fsfx then fadeTick(now, pausedV or photo or singleView(), ps) end
    end
end

-- MAIN (main.lua, race phases, after hud.tick): arm / disarm backup, HUD list, 1 s scan, MPC pin, probe.
function M.tick()
    local want, reason = wantArmed()
    if want and not A.on then
        M.ensureArmed("race tick")
    elseif not want and A.on then
        M.disarm(reason, false)
    end
    if not A.on then return end
    local now = St.nowMs()
    if E.dirty or now - E.at >= 1000 then refreshEntries() end
    if A.msg and now - lastScan >= 1000 then
        lastScan = now
        sweepGone()
        scan("1 s scan", false)
        dropOutPlayers()
    end
    if A.ramjet then pinRamjet(now, false) end
    probe(now)
end

---------------------------------------------------------------------------------------------------- diag / testcmd
function M.status()
    local c = S.n
    return fmt("armed=%s (%s) huds=[%s] hooks=%d posts=%d copies=%d hidden=%d waited=%d promoted=%d shared=%d "
        .. "unattributed=%d nobody=%d reposts=%d/%d remaps=%d colourBlocks=%d rjStops=%d fsfx=%d tints=%d fades=%d "
        .. "flashes=%d cbErrors=%d | last: %s", tostring(S.armed), tostring(S.why), tostring(S.huds), hookCount(), c.posts,
        c.copies, c.hidden, c.queued, c.promoted, c.shared, c.unknown, c.nobody, c.reposts, c.reposts + c.repostFail,
        c.remaps, c.colourBlocks, c.rjStops, c.fsfx, c.tints, c.fades, c.flashes, c.cbErrors, tostring(S.lastRoute))
end

function M.dump(out)
    out = out or function(f, ...) U.log(TAG, f, ...) end
    out("uxsplit: %s", M.status())
    out("  cfg: messages=%s hide=%s repost=%s remap=%s danger=%s colours=%s ramjet=%s fullscreen=%s fadeMax=%s "
        .. "gameHud=%s holo=%s probeMs=%s", msgMode(), tostring(cfg.UxSplitMsgHide), tostring(cfg.UxSplitRepost),
        tostring(cfg.UxSplitIndexRemap), dangerMode(), tostring(cfg.UxSplitHudColours), tostring(cfg.UxSplitRamjetColour),
        tostring(cfg.UxSplitFullScreenFx), tostring(cfg.UxSplitFadeMax), tostring(cfg.UxSplitGameHud),
        tostring(cfg.UxSplitGuestHolo), tostring(cfg.UxSplitProbeMs))
    out("  flags: msg=%s route=%s remap=%s colours=%s (%s%s) ramjet=%s (%d animations) fsfx=%s (override %s) own=%s",
        onOff(A.msg), onOff(A.route), onOff(A.remap), onOff(A.colours), COL.mode, COL.verified and ", verified" or "",
        onOff(A.ramjet), E.rjCount, onOff(A.fsfx), onOff(A.fsfxOverride), onOff(A.own))
    local paths = {}
    for p in pairs(S.hooks) do paths[#paths + 1] = p end
    table.sort(paths)
    for _, p in ipairs(paths) do out("  hook %s: %s", p, tostring(S.hooks[p])) end
    for _, e in ipairs(E.list) do
        local names = {}
        for _, c in ipairs(e.conts or {}) do names[#names + 1] = fmt("%s=%s", tostring(c.tree), tostring(c.name)) end
        out("  P%s HUD %s: %s | tint %s fade %s", tostring(e.pnum), U.pathOf(e.widget), table.concat(names, " "),
            tostring(S.tint[e.pnum] or "none"), f2(tonumber(S.fade[e.pnum]) or 0))
    end
    local holds = {}
    for id, a in pairs(active) do
        local ps = {}
        for p in pairs(a) do ps[#ps + 1] = "P" .. tostring(p) end
        table.sort(ps)
        holds[#holds + 1] = id .. "=" .. table.concat(ps, ",")
    end
    local nt, nh, np = 0, 0, 0
    for _ in pairs(tags) do nt = nt + 1 end
    for _ in pairs(hidden) do nh = nh + 1 end
    for _, q in pairs(pending) do np = np + #q end
    out("  copies tracked=%d hidden=%d waiting=%d; held: %s", nt, nh, np, #holds > 0 and table.concat(holds, " ") or "none")
end

function M.init()
    local stale = 0
    for _, h in pairs(HOOKS) do if h.owner ~= INSTANCE then stale = stale + 1 end end
    if stale > 0 and onGameThread() then
        unhookAll("stale registration of an earlier load")
        stale = 0
    end
    -- "leaving" fires synchronously inside the LoadMap / seamless-travel / RequestReturnToMenus pre-hooks: the hooks go
    -- before the map changes (run H crash rule). POSTRACE: the world is alive, tints / fades / copies are given back.
    St.on("leaving", TAG, function(reason) M.disarm("leaving: " .. tostring(reason), true) end)
    St.on("phase", TAG, function(new)
        if new ~= "PRERACE" and new ~= "RACING" then M.disarm("phase " .. tostring(new), new ~= "POSTRACE") end
    end)
    St.on("world", TAG, function() if not A.on then clearRace() end end)
    U.log(TAG, "init: messages=%s (hide %s, re-post %s), index remap %s, danger=%s (HUD colours %s, ramjet %s, "
        .. "full-screen effects %s, fade max %s), game HUD %s, guest radio portrait %s; hooks only while a split race "
        .. "runs%s (V-UX-00)", msgMode(), tostring(cfg.UxSplitMsgHide), onOff(cfg.UxSplitRepost ~= false),
        onOff(cfg.UxSplitIndexRemap ~= false), dangerMode(), onOff(cfg.UxSplitHudColours ~= false),
        onOff(cfg.UxSplitRamjetColour ~= false), onOff(cfg.UxSplitFullScreenFx ~= false), tostring(cfg.UxSplitFadeMax),
        onOff(cfg.UxSplitGameHud ~= false), tostring(cfg.UxSplitGuestHolo),
        stale > 0 and fmt("; %d stale hook registration(s) of an earlier load, replaced when arming", stale) or "")
end

return M
