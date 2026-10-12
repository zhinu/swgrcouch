-- SWGRCouch backprompt.lua (0.12.0): P1's pad B on the mod's sub-pages (v2 OPTIONS, RACE SETUP) goes back.
--
-- Why: in the front end the game keeps P1 in UI-only input, so before the first race P1's PlayerController never sees
-- pad B (lobby's OPTIONS poll and setup.pollP1Back read it there and stay blind; notes/research/vehicle-step-code-map.md
-- "B"). The press reaches CommonUI instead, and the main menu's back action posts the game's own "QUIT GAME?" prompt
-- (DT_DialogData row QuitGame) with ACCEPT focused: one more A quits the game. Live 2026-10-10 on the v2 OPTIONS page;
-- RACE SETUP had it since 0.9.
-- How: native pre-hooks on GfnMessagingSubsystem:AddMessage / AddMessageParams see the QuitGame post. While OPTIONS or
-- RACE SETUP shows on our tab, the hook notes it (and which prompts were already up); the next FAST ticks answer the
-- new prompt "No" through its own last button (its native click = ReportResultAndRemove) and run the page's back step
-- instead: OPTIONS closes, RACE SETUP steps back (RACERS: the card's stage before). On the plain lobby (a main-menu tab)
-- the prompt stays: B there is the game's own "exit game", as on every tab. Exit Game in the action bar (mouse) reaches
-- the same prompt; on a sub-page it means back too. When P1's PC does see B (after a race), lobby's / setup's own polls
-- already went back in the same press: this module then only answers the prompt (no second back step).
-- Config: cfg.BackPromptAsBack (true) | false = the 0.11 behaviour (the game's prompt stays up).
-- HOOK RULES (subsplit's): the two hooks are registered ONLY while OPTIONS or RACE SETUP shows and no launch is
-- pending, and UnregisterHook-ed otherwise (launch.lua also calls M.disarm() right before LaunchCustomRace): no Lua
-- runs inside the game's messaging in races or on the other tabs. (The launch crashes of 2026-10-10 were NOT these
-- hooks: they also happened with BackPromptAsBack = false; their cause was the v2 pages' widget calls after the
-- front end was freed, fixed by the launch hold, state.lua St.launchHold.)
-- KeyboardIsP1 (review flow-1): pad 0 then belongs to a guest whose B still reaches P1's CommonUI back. The prompt is
-- answered No but no back step runs (the keyboard P1's back is Backspace, as in setup.pollP1Back).
-- VERIFY(V-BP-01): OPTIONS open, P1's B: "QuitGame prompt over OPTIONS: answered No (1 click(s), N ms after the post), OPTIONS closed
--   (V-BP-01)"; no prompt left on screen; the tiles show with OPTIONS focused. RACE SETUP on PLANET: "... over RACE
--   SETUP: answered No (1 click(s), ...), one step back (V-BP-01)" and CLASS shows. On the plain lobby: no [backprompt]
--   line, the game's prompt stays.

local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "backprompt"
local HOOKS = { "/Script/Griffin.GfnMessagingSubsystem:AddMessage",
                "/Script/Griffin.GfnMessagingSubsystem:AddMessageParams" }
local MODAL = "WBP_Modal_C"
local WAIT_MS = 2000                       -- the prompt shows within a few ticks of the post; give up after this

local Q = { pending = nil, tryMs = -1e12, failed = nil, answered = 0 }
local SCAN_MS = 250                        -- review flow-5: FindAllOf at most every 250 ms while waiting

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

-- hot-reload safe registry (restart.lua's pattern): the registered callbacks read the current handler from _G
local function HK()
    local H = _G.SWGRCouch_backprompt_hooks
    if type(H) ~= "table" then
        H = {}
        _G.SWGRCouch_backprompt_hooks = H
    end
    return H
end

local function visibleModals()
    local list = {}
    for _, m in ipairs(FindAllOf(MODAL) or {}) do
        if U.ok(m) then
            local v = false
            pcall(function() v = m:IsVisible() == true end)
            if v then list[#list + 1] = m end
        end
    end
    return list
end

-- what a B means right now: "options" | "setup" | nil (plain lobby, another tab, a race: the game's prompt stays)
local function context()
    if opt("BackPromptAsBack", true) == false then return nil end
    if St.phase ~= "FRONTEND" then return nil end
    local lobby, setup = U.mod("lobby"), U.mod("setup")
    local okO, optOpen = pcall(function() return lobby and lobby.optionsOpen and lobby.optionsOpen() end)
    if okO and optOpen then return "options" end
    local okS, act = pcall(function() return setup and setup.isActive and setup.isActive() end)
    if okS and act and St.menu.visible == "lobby" then return "setup" end
    return nil
end

-- the hook's handler (game thread, inside the game's AddMessage call): note a QuitGame post on a sub-page
local function onPost(id)
    if id ~= "QuitGame" then return end
    local what = context()
    if not what then return end
    local before = {}
    for _, m in ipairs(visibleModals()) do before[U.key(m)] = true end
    if Q.pending and Q.pending.hidden and Q.pending.prompt then       -- an older hidden prompt: shown again first
        local old = Q.pending
        old.hidden = false
        pcall(function() old.prompt:SetRenderOpacity(1.0) end)
    end
    Q.pending = { atMs = St.nowMs(), what = what, before = before, clicks = 0, lastClickMs = -1e12 }
end

local function hookAdd(ctx, idP)
    local H = _G.SWGRCouch_backprompt_hooks
    if not (H and H.on) then return nil end
    pcall(function() H.on(idP:get():ToString()) end)
    return nil
end

local function hookAddParams(ctx, paramsP)
    local H = _G.SWGRCouch_backprompt_hooks
    if not (H and H.on) then return nil end
    pcall(function() H.on(paramsP:get().ID:ToString()) end)
    return nil
end

-- Unregister both hooks (idempotent); why for the log.
local function disarm(why)
    local H = HK()
    if not H.ids then return false end
    for _, h in ipairs(H.ids) do
        local ok, e = pcall(UnregisterHook, h.path, h.pre, h.post or h.pre)
        if not ok then U.warn(TAG, "UnregisterHook(%s, %s, %s) failed: %s", h.path, tostring(h.pre), tostring(h.post),
            tostring(e)) end
    end
    H.ids = nil
    U.dbg(TAG, "QuitGame watch disarmed (%s)", tostring(why))
    return true
end

function M.disarm(why) return disarm(why or "launch") end

local function ensureHooks(now)
    local H = HK()
    H.on = onPost
    if H.ids then return true end
    if Q.failed or now - Q.tryMs < 100 then return false end       -- re-armed on each sub-page visit
    Q.tryMs = now
    local ids = {}
    for i, path in ipairs(HOOKS) do
        local found = false
        pcall(function() found = U.ok(StaticFindObject(path)) end)
        if found then
            local ok, pre, post = pcall(RegisterHook, path, i == 1 and hookAdd or hookAddParams)
            if ok and type(pre) == "number" then
                ids[#ids + 1] = { path = path, pre = pre, post = post }
            else
                U.warn(TAG, "RegisterHook(%s) failed: %s (V-BP-01)", path, tostring(pre))
            end
        end
    end
    if #ids == 0 then
        Q.failed = "no hook"
        U.err(TAG, "GfnMessagingSubsystem:AddMessage(Params) could not be hooked: P1's B on OPTIONS / RACE SETUP keeps "
            .. "opening the game's Quit prompt (V-BP-01)")
        return false
    end
    H.ids = ids
    U.log(TAG, "QuitGame watch armed: %d native pre-hook(s) on GfnMessagingSubsystem while OPTIONS / RACE SETUP "
        .. "shows (kept in _G.SWGRCouch_backprompt_hooks) (V-BP-01)", #ids)
    return true
end

-- the new prompt's buttons (BoundActionNotificationWidget.ButtonPanel_Dynamic, menubridge's reading), visible only
local function buttonsOf(m)
    local list = {}
    local panel
    pcall(function() panel = m.ButtonPanel_Dynamic end)
    if not U.ok(panel) then return list end
    local n = 0
    pcall(function() n = math.tointeger(tonumber(panel:GetChildrenCount())) or 0 end)
    for i = 0, n - 1 do
        local b
        pcall(function() b = panel:GetChildAt(i) end)
        if U.ok(b) then
            local vis = true
            pcall(function() local v = b:GetVisibility(); vis = (v ~= 1 and v ~= 2) end)
            if vis then list[#list + 1] = b end
        end
    end
    return list
end

local function anyFocus(btns)
    for _, b in ipairs(btns) do
        local f = false
        pcall(function() f = b:HasAnyUserFocus() == true or b:HasFocusedDescendants() == true end)
        if f then return true end
    end
    return false
end

local function backStep(pd)
    local kbp1 = false
    pcall(function() kbp1 = require("settings").get("KeyboardIsP1") == true end)
    if kbp1 then return "no back step (KeyboardIsP1: pad 0 is a guest; P1's back is Backspace)" end
    if pd.what == "options" then
        local ok, closed = pcall(function() return U.mod("lobby").closeOptions("pad B (the game's Quit prompt)") end)
        return (ok and closed) and "OPTIONS closed" or "OPTIONS was already closed"
    end
    local setup = U.mod("setup")
    local last = -1e12
    pcall(function() last = setup.lastP1BackMs() end)
    if last >= pd.atMs - 150 then return "setup's own B poll already stepped back" end
    pcall(function() setup.p1Back("pad B (the game's Quit prompt)") end)
    return "one step back"
end

-- One prompt, answered once it is ready: a click during its intro is dropped (live 2026-10-10: the reused prompt
-- stayed up with no focused button), so "ready" = one of its buttons holds focus (the game focuses ACCEPT when the
-- prompt activates) or READY_MS on screen; then No, and No again every RETRY_MS (MAX_CLICKS) until it is gone.
local READY_MS, RETRY_MS, MAX_CLICKS = 600, 400, 5
-- 0.13.0 review: a hidden prompt is shown again whenever it is left (answered, given up, page / phase change): the
-- game reuses the widget, and a prompt left invisible with ACCEPT focused would quit the game on the next A
local function reveal(pd)
    if pd and pd.hidden and pd.prompt then
        pd.hidden = false
        pcall(function() pd.prompt:SetRenderOpacity(1.0) end)
    end
end
M._reveal = reveal

local function drop(pd)
    reveal(pd)
    if Q.pending == pd then Q.pending = nil end
end

local function answer(pd, now)
    if not pd.prompt then
        -- 0.13.0 (Jules: "pressing B goes to cancel game very quickly, bad UI"): every FAST tick while a post waits
        -- (it lasts < WAIT_MS), so the prompt is caught on its first frame
        if now - (pd.scanMs or -1e12) >= (opt("BackPromptHide", true) and 0 or SCAN_MS) then
            pd.scanMs = now
            for _, m in ipairs(visibleModals()) do
                if not pd.before[U.key(m)] then pd.prompt, pd.seenMs = m, now end
            end
            -- 0.13.0: the prompt is made invisible at once and the page steps back at once; No is still clicked
            -- once the prompt is ready (below), out of sight
            if pd.prompt and opt("BackPromptHide", true) then
                pcall(function() pd.prompt:SetRenderOpacity(0.0) end)
                pd.hidden = true
                if not pd.did then pd.did = backStep(pd) end
            end
        end
        if not pd.prompt then
            if now - pd.atMs > WAIT_MS then
                drop(pd)
                U.warn(TAG, "QuitGame posted over %s but no new prompt showed within %d ms: left alone (V-BP-01)",
                    pd.what, WAIT_MS)
            end
            return
        end
    end
    local m = pd.prompt
    local vis = false
    if U.ok(m) then pcall(function() vis = m:IsVisible() == true end) end
    if not vis then
        drop(pd)
        if pd.clicks > 0 then
            Q.answered = Q.answered + 1
            U.log(TAG, "QuitGame prompt over %s: answered No (%d click(s), %d ms after the post), %s (V-BP-01)",
                pd.what == "options" and "OPTIONS" or "RACE SETUP", pd.clicks, math.floor(now - pd.atMs),
                tostring(pd.did))
        else
            U.log(TAG, "QuitGame prompt over %s closed before it was answered (the player did) (V-BP-01)", pd.what)
        end
        return
    end
    local btns = buttonsOf(m)
    if #btns < 2 then                              -- still being built: the next tick (shown again after WAIT_MS)
        if now - (pd.seenMs or now) > WAIT_MS then
            drop(pd)
            U.warn(TAG, "QuitGame prompt over %s never got its buttons: shown, left to the player (V-BP-01)", pd.what)
        end
        return
    end
    -- 0.13.0 review: while hidden, No holds the focus (an A pressed meanwhile answers No, never the invisible ACCEPT)
    if pd.hidden and not pd.noFocused then
        local no = btns[#btns]
        pcall(function() no:SetFocus() end)
        pcall(function() no:SetUserFocus(U.p1()) end)
        pd.noFocused = true
    end
    if pd.clicks >= MAX_CLICKS then
        if now - pd.lastClickMs >= RETRY_MS then
            drop(pd)
            U.warn(TAG, "QuitGame prompt over %s still up after %d No clicks: left to the player (V-BP-01)", pd.what,
                pd.clicks)
        end
        return
    end
    if pd.clicks == 0 then
        if not (anyFocus(btns) or now - pd.seenMs >= READY_MS) then return end
    elseif now - pd.lastClickMs < RETRY_MS then
        return
    end
    local no = btns[#btns]                         -- DT_DialogData QuitGame: Yes, No (menubridge: the last = cancel)
    pcall(function() no:HandleButtonClicked() end)
    pd.clicks, pd.lastClickMs = pd.clicks + 1, now
    if pd.clicks > 1 then U.dbg(TAG, "QuitGame prompt still up: No again (%d)", pd.clicks) end
    if not pd.did then pd.did = backStep(pd) end   -- the page's back once, at the first click
end

-- FAST loop (main.lua, every phase; cheap outside the front end)
function M.fastTick()
    if opt("BackPromptAsBack", true) == false then disarm("off"); return end
    if St.phase ~= "FRONTEND" then
        if Q.pending then drop(Q.pending) end
        disarm("phase " .. tostring(St.phase))
        return
    end
    if St.launch.pending == true then
        if Q.pending then drop(Q.pending) end
        disarm("launch pending")
        return
    end
    local now = St.nowMs()
    if St.menu.visible == "lobby" and context() then ensureHooks(now) else disarm("no sub-page") end
    local pd = Q.pending
    if pd then U.try(TAG, answer, pd, now) end
end

function M.status()
    local H = HK()
    return string.format("backprompt: hooks %s, answered %d%s", H.ids and tostring(#H.ids) or "none", Q.answered,
        Q.failed and (", failed: " .. Q.failed) or "")
end

return M
