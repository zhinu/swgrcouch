-- couchpage.lua (0.15 F01): the COUCH CAMPAIGN entry. Jules 2026-10-15: "replace the upgrade button with couch
-- campaign - those who have the deluxe edition should have a new button since they don't see this button to start
-- with - and then it should go to choose amount of players (gamepad menu full screen) and continue campaign or start
-- new campaign. The continue campaign or start campaign should remain untouched." The workflow through FREE MODE was
-- "not understandable".
--
-- Two parts:
--   * THE TILE: on the game's CAMPAIGN tab (WBP_FE_Recommended_C) a "COUCH CAMPAIGN" tile, a WBP_FE_TileCommon_Btn_C
--     we create (the game's own tile class, its PreConstruct paints it), put in VB_ButtonLayout right after
--     Btn_Tile_A2. Without the Deluxe Edition A2 is the "Upgrade to Deluxe Edition" upsell: it is collapsed and ours
--     takes its place (same size). With the Deluxe Edition A2 is the owner's "Deluxe Art Book": it stays, ours is
--     added under it (the tab's DownOnly ScaleBox fits the taller column). Our tile has no native click binding: its
--     A is read with the selected-toggle poll (ui.lua's poll mode). The game's CONTINUE CAMPAIGN tile is untouched.
--   * THE PAGE: a full-screen page on our tab (built in the lobby page like runpage.lua): COUCH CAMPAIGN, the four
--     player slots (join.lua's pads: A on a pad joins, B leaves), CONTINUE CAMPAIGN (when a run exists) / START NEW
--     CAMPAIGN / BACK. Both campaign rows run the game's own campaign entry (the CONTINUE tile's code:
--     CampaignSubsystem:SetActiveCampaign(None, true) + FrontEndGameMode:CampaignSelected(); a NEW campaign over an
--     existing run goes through the tile's own restart confirm, OnRestartCampaignPressed). P1's B closes the page
--     (lobby's B poll; backprompt.lua answers the game's QuitGame prompt that B posts in the front end).
-- 0.15 F02 (Jules 2026-10-15: "have the unlocked previous campaigns ... even if you have already done the qualification
-- you can restart it" / "in options the option to delete all progress"): the NEW CAMPAIGN poster becomes the campaign's
-- three ACT posters (the act's embroidered patch; locked acts dimmed with the reason, done acts COMPLETED + check).
-- A on an unlocked act = a NEW run of that act with everyone joined (couchacts.replay; a run in progress is abandoned
-- only after the page's confirm: START ACT n AGAIN? YES / NO, B = NO, NO focused first, a YES within 400 ms of the
-- opening press ignored). CONTINUE CAMPAIGN is locked when no run is in progress. The why and the evidence of every
-- native call are in couchacts.lua's header.
-- #98 (2026-10-18): DELETE ALL COUCH PROGRESS left this page for the mod's settings: FREE MODE > OPTIONS > ADVANCED
-- (lobby.onCouchDelete, the same couchacts.deleteAll).
-- Config: cfg.CouchCampaignTile (true), cfg.CouchActPosters (true).
local U = require("util")
local St = require("state")
local cfg = require("config")
local C = require("consts")

local TAG = "couchpage"
local M = {}

local function ui() return U.mod("ui") end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local VIS = C.E.Vis
local TX_TILE = "/Game/Griffin/UI/Library/Textures/Content/MainMenu/"
local TILE_ART = TX_TILE .. (cfg.CouchTileArt or "T_UI_Difficulty_Tile_04.T_UI_Difficulty_Tile_04")
local TILE_CLS = "/Game/Griffin/UI/Widgets/Buttons/WBP_FE_TileCommon_Btn.WBP_FE_TileCommon_Btn_C"
local OVER   = { "/Script/Griffin.FuseOverlay", "/Script/UMG.Overlay" }
local IMAGE  = { "/Script/Griffin.FuseImage", "/Script/UMG.Image" }
local CANVAS = { "/Script/Griffin.FuseCanvasPanel", "/Script/UMG.CanvasPanel" }
local VBOX   = { "/Script/Griffin.FuseVerticalBox", "/Script/UMG.VerticalBox" }
local TX = "/Game/Griffin/UI/Library/Textures/"
local TEX_BG = TX .. "Backgrounds/T_UI_MainMenu_Bg.T_UI_MainMenu_Bg"

local W = nil                    -- the page's widgets (nil until built; dropped by forget)
local S = { active = false, backMs = -1e12, openWanted = 0, slotsSig = nil, lastSlotsMs = -1e12, modal = nil,
            msg = "", progress = nil, states = nil, verifyMs = -1e12 }
local T = { rec = nil, tile = nil, scanMs = -1e12, warned = false }   -- the Campaign tab tile

local function mk(paths, outer)
    for _, p in ipairs(paths) do
        local ok, cls = pcall(U.class, p)
        if ok and U.ok(cls) then
            local okW, w = pcall(StaticConstructObject, cls, outer)
            if okW and U.ok(w) then return w end
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------- the campaign
-- the game's own campaign tab widget (the visible one: garbage instances of closed menus stay in FindAllOf)
local function recommended()
    for _, r in ipairs(FindAllOf("WBP_FE_Recommended_C") or {}) do
        if U.ok(r) then
            local vis = false
            pcall(function() vis = r:IsVisible() == true end)
            if vis then return r end
        end
    end
    return nil
end

-- a campaign run exists = the CONTINUE tile shows its restart action (UpdateCampaignSaveStatus)
-- a campaign run exists = the game's own test for its CONTINUE / START label (UpdateCampaignSaveStatus)
local function runExists()
    local yes = nil
    pcall(function()
        local cs = FindFirstOf("CampaignSubsystem")
        if U.ok(cs) then yes = cs:HasNeverStartedCampaign() ~= true end
    end)
    return yes
end

local function ownsDeluxe()
    local owns = false
    pcall(function()
        local es = FindFirstOf("EntitlementSubsystem")
        if U.ok(es) then owns = es:OwnsEntitlement({ TagName = U.fname("Entitlements.DeluxeEdition") }) == true end
    end)
    return owns
end

-- the game's CONTINUE CAMPAIGN code (WBP_FE_Recommended Btn_Tile_Main click)
local function campaignSelected(why)
    local ok = pcall(function()
        local cs = FindFirstOf("CampaignSubsystem")
        if U.ok(cs) then cs:SetActiveCampaign(CreateInvalidObject(), true) end
    end)
    if not ok then U.warn(TAG, "SetActiveCampaign(None, true) failed: the game's own CampaignSelected still runs") end
    local gm = U.gm()
    if not U.ok(gm) then U.warn(TAG, "%s: no game mode", why); return false end
    -- couch-fix49 (AUTO-127): a pending championship's head-to-head grid grown before the continue's builder runs
    -- (also the CampaignSelected pre-hook's job: idempotent)
    pcall(function() U.mod("couchrules").continueArm(why) end)
    local okC, err = pcall(function() gm:CampaignSelected() end)
    if not okC then U.warn(TAG, "%s: CampaignSelected failed: %s", why, tostring(err)); return false end
    U.log(TAG, "%s: the game's CampaignSelected ran with %d local player(s)", why, #U.localPlayers())
    -- fix16: a run saved at a couch race end holds the result gate's flag (couchrules.repairResume); the phase hooks
    -- repeat this once the run world is up
    pcall(function() U.mod("couchrules").repairResume(why) end)
    -- runsync: the guests back at the checkpoint the loaded run resumes from (again at the next phases if the run is
    -- built later)
    pcall(function() U.mod("couchrun").resumeCheck(why) end)
    return true
end

---------------------------------------------------------------------------------------------------- the page
local lastBuild = nil            -- the lobby's build arguments: a page lost by a hot reload is rebuilt on open
local TXM = "/Game/Griffin/UI/Library/Textures/Content/MainMenu/"
-- the page in the FREE MODE page's own language (lobby.lua v2, screen su 3840 x 2160): the menu background, the game's
-- screen title, posters over ghosts (focus look painted from the ghost's CommonUI focus), the players strip
local POSTERS = { cont = { 128, 470, 1018, 1045 }, new = { 1190, 470, 1018, 1045 } }   -- under the screen title
-- F02: CONTINUE + the three acts in one row (to the page's right edge, 3712)
local ACTS = { { 1190, 470, 810, 1045 }, { 2046, 470, 810, 1045 }, { 2902, 470, 810, 1045 } }
local STRIP = { x = 128, y = 1560, w = 2080, h = 270 }
local MSG = { x = 128, y = 1872 }                        -- F02: one message line under the strip
-- F02 confirm (a modal over the page, the game's dark panel look)
local MODAL = { x = 1020, y = 560, w = 1800, h = 960 }
local BTN = { yes = { 1100, 1340, 780, 110 }, no = { 1960, 1340, 780, 110 }, ok = { 1530, 1340, 780, 110 } }
local YES_GUARD_MS = 400         -- an A within this time after the confirm opened is the press that opened it

local function acts() return U.mod("couchacts") end
local function actMode() return opt("CouchActPosters", true) ~= false end

function M.build(root, pc, page)
    W = nil
    S.modal = nil
    lastBuild = { root = root, pc = pc, page = page }
    if opt("CouchCampaignTile", true) == false then return false end
    if not (U.ok(root) and U.ok(pc) and U.ok(page)) then return false end
    local okT, tree = pcall(U.getField, page, "WidgetTree")
    if not okT or not U.ok(tree) then return false end
    local T = U.mod("theme")
    local cv = mk(CANVAS, tree)
    if not cv then U.warn(TAG, "page canvas not created"); return false end
    pcall(function() cv:SetVisibility(VIS.SelfHitTestInvisible) end)
    local slot = root:AddChildToVerticalBox(cv)
    pcall(function()
        slot:SetSize({ Value = 1, SizeRule = 1 })
        slot:SetHorizontalAlignment(C.E.HAlign.Fill)
        slot:SetVerticalAlignment(0)
        slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    end)
    local g = T.pageGeometry(root)
    local geo = { x = g.x, y = g.y, w = g.w, h = g.h, cmdY = g.cmdY, cardH = g.cardH, screen = g.screen, src = g.src }
    local ctx = { tree = tree, pc = pc }
    local function LR(x, y, w, h) return { x - geo.x, y - geo.y, w, h } end
    local w = { pc = pc, panel = cv, root = root, ctx = ctx, geo = geo, posters = {}, ghosts = {}, cells = {},
                acts = actMode(), order = {} }
    pcall(function() w.bg = T.pageBackground(ctx, cv, geo, "hub", { z = -10 }) end)
    pcall(function() w.title = T.screenTitle(ctx, cv, geo, "COUCH CAMPAIGN") end)
    local function poster(id, rect, art, title, ax, ay, zoom, extra)
        local o = { geo = geo, z = 1, art = art, ax = ax, ay = ay, zoom = zoom, title = title, titleSize = 96 }
        for k, v in pairs(extra or {}) do o[k] = v end
        local okP, p = pcall(T.poster, ctx, cv, rect, o)
        if okP and p then w.posters[id] = p end
        local okG, gh = pcall(T.ghost, ctx, cv, rect, "couchpage:" .. id, function() M.onPoster(id) end, { geo = geo })
        if okG and U.ok(gh) then w.ghosts[id] = gh; w.order[#w.order + 1] = id end
        return w.posters[id]
    end
    poster("cont", POSTERS.cont, TXM .. "T_UI_FE_Tile_01.T_UI_FE_Tile_01", "CONTINUE\nCAMPAIGN", 0.5, 0.3, 1.0)
    if w.acts then
        -- the act's embroidered patch (CAM_TourN.PrizeImage, 800 x 1200, transparent) centred on a backer in its hue,
        -- inside the poster's own canvas under its art window (z 0 after the shadow: drawn over it, under the art)
        for n, a in ipairs(acts().ACTS) do
            local id = "act" .. n
            local p = poster(id, ACTS[n], a.art, "ACT " .. a.roman .. "\n" .. a.name, 0.5, 0.28, 0.6,
                             { titleSize = 60, kickerAlways = true })
            if p and p.cv then
                pcall(function()
                    p.backer = T.image(ctx, p.cv, { tex = T.TEX.SolidFill, tint = T.hex(a.hue), z = 0,
                                                    rect = { 2, 2, ACTS[n][3] - 4, ACTS[n][4] - 4 } })
                end)
            end
        end
    else
        poster("new", POSTERS.new, TXM .. "T_UI_FE_Tile_Campaign_Hero.T_UI_FE_Tile_Campaign_Hero", "NEW\nCAMPAIGN",
               0.5, 0.3, 1.0)
    end
    for i = 1, #w.order - 1 do
        local a, b = w.ghosts[w.order[i]], w.ghosts[w.order[i + 1]]
        pcall(function() T.nav(a, "right", b); T.nav(b, "left", a) end)
    end
    -- the players strip: the lobby's backer (white @0.42, rounded) + one line per player (join.slotViews)
    pcall(function()
        w.strip = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 21, size = { STRIP.w, STRIP.h },
                                     tint = T.alpha(T.COL.WHITE, 0.42), z = 0, rect = LR(STRIP.x, STRIP.y, STRIP.w, STRIP.h) })
        w.hint = T.text(ctx, cv, "statusText", { colour = T.COL.INK, z = 2, text = "PRESS (A) ON A CONTROLLER TO JOIN · (B) TO LEAVE",
                                                 rect = LR(STRIP.x + 36, STRIP.y + 26) })
        for i = 1, 4 do
            w.cells[i] = T.text(ctx, cv, "posterDesc", { colour = T.COL.INK, z = 2, size = 36, text = "",
                                                         rect = LR(STRIP.x + 36 + (i - 1) * 512, STRIP.y + 130) })
        end
    end)
    pcall(function()
        w.msg = T.text(ctx, cv, "hint", { colour = T.COL.RUST, z = 2, text = "", rect = LR(MSG.x, MSG.y), visible = false })
    end)
    -- F02 the confirm modal (hidden): dim, dark panel, title, body, YES / NO pills over their ghosts
    pcall(function()
        local m = { btn = {}, lbl = {}, gh = {} }
        local sc = geo.screen or { x = 0, w = 3840 }
        m.dim = T.image(ctx, cv, { tex = T.TEX.SolidFill, tint = T.alpha(T.COL.BLACK, 0.62), z = 30, visible = false,
                                   rect = LR(sc.x or 0, 0, sc.w or 3840, 2160) })
        m.panel = T.image(ctx, cv, { tex = T.TEX.SolidFill, drawAs = 4, radius = 24, size = { MODAL.w, MODAL.h },
                                     tint = T.COL.PANEL_DEEP, z = 31, visible = false,
                                     rect = LR(MODAL.x, MODAL.y, MODAL.w, MODAL.h) })
        m.title = T.text(ctx, cv, "cardName", { colour = T.COL.WHITE, z = 32, text = "", wrapW = MODAL.w - 160,
                                                visible = false, rect = LR(MODAL.x + 80, MODAL.y + 70) })
        m.body = T.text(ctx, cv, "body", { colour = T.COL.BEIGE, z = 32, size = 36, text = "", wrapW = MODAL.w - 160,
                                           visible = false, rect = LR(MODAL.x + 80, MODAL.y + 230) })
        m.foot = T.text(ctx, cv, "hint", { colour = T.COL.BONE, z = 32, text = "(A) SELECT   (B) NO", visible = false,
                                           rect = LR(MODAL.x + 80, MODAL.y + MODAL.h - 70) })
        for _, k in ipairs({ "yes", "no" }) do
            local r = BTN[k]
            m.btn[k] = T.image(ctx, cv, { mat = T.MAT.Pill, drawAs = 1, margin = 0.5, size = r[4], tint = T.COL.TILE,
                                          z = 32, visible = false, rect = LR(r[1], r[2], r[3], r[4]) })
            m.lbl[k] = T.text(ctx, cv, "heroLabel", { text = string.upper(k), z = 33, align = { 0.5, 0.5 }, visible = false,
                                                      rect = LR(r[1] + r[3] / 2, r[2] + r[4] / 2) })
            local gh = T.ghost(ctx, cv, r, "couchpage:" .. k, function() M.onModal(k) end, { geo = geo, z = 34 })
            if U.ok(gh) then m.gh[k] = gh; pcall(function() T.set(gh, { visible = false }) end) end
        end
        pcall(function() T.nav(m.gh.yes, "right", m.gh.no); T.nav(m.gh.no, "left", m.gh.yes) end)
        w.modal = m
    end)
    pcall(function() cv:SetVisibility(VIS.Collapsed) end)
    W = w
    local n = 0
    for _ in pairs(w.posters) do n = n + 1 end
    U.log(TAG, "COUCH CAMPAIGN page built (%d poster(s)%s, strip %s)", n, w.acts and ", acts" or "",
        w.strip and "on" or "off")
    return true
end

function M.forget() W = nil; S.active = false; S.modal = nil end
function M.active() return S.active and W ~= nil end

-- the four player lines (join.slotViews: P1, the joined guests, then the open pads)
local function refreshSlots(force)
    if not W then return end
    local views = {}
    pcall(function() views = U.mod("join").slotViews() end)
    local sig = table.concat(views, "|")
    if not force and sig == S.slotsSig then return end
    S.slotsSig = sig
    local T = U.mod("theme")
    for i = 1, 4 do
        local line = tostring(views[i] or "--"):gsub("%s+%b()", ""):gsub("%s%s+", "  ")
        pcall(function() T.set(W.cells[i], { text = line }) end)
    end
end

local function showPoster(id, on)
    local T = U.mod("theme")
    pcall(function() T.set(W.posters[id], { visible = on }) end)
    pcall(function() W.posters[id].e.w:SetVisibility(on and VIS.HitTestInvisible or VIS.Collapsed) end)
    pcall(function() W.ghosts[id]:SetVisibility(on and VIS.Visible or VIS.Collapsed) end)
end

-- one line under the strip (a refusal, a reason); "" hides it
local function say(text, warn)
    S.msg = text or ""
    if text and text ~= "" then U.log(TAG, "page message: %s", text) end
    if not W then return end
    local T = U.mod("theme")
    pcall(function() T.set(W.msg, { text = S.msg, visible = S.msg ~= "", colour = warn == false and T.COL.INK or T.COL.RUST }) end)
end
M._say = say

local function actTitle(n)
    local a = acts().ACTS[n]
    return a and ("ACT " .. a.roman .. ": " .. a.name) or "?"
end

-- F02: the act posters from the game's progress (couchacts.readProgress: act pointer, ActN done tags, run in progress)
local function refreshActs()
    local A = acts()
    local p = A.readProgress()
    local st = A.states(p)
    S.progress, S.states = p, st
    if not W then return end
    for n = 1, #A.ACTS do
        local s, pst = st[n], W.posters["act" .. n]
        if pst then
            local kicker = A.kicker(s)
            local desc = A.ACTS[n].goal .. (s.unlocked and "\n(A) NEW RUN OF THIS ACT" or "")
            pcall(function()
                pst.set({ kicker = kicker, desc = desc, check = s.completed == true, lock = (not s.unlocked) and s.reason or false })
            end)
        end
    end
    local cont = W.posters.cont
    if cont then
        local desc = p.runAct and actTitle(p.runAct) or "Your run in progress"
        pcall(function()
            cont.set({ desc = desc, lock = (p.inProgress ~= true) and "No run in progress: pick an act." or false })
        end)
    end
end

function M.refresh()
    if not W then return end
    if W.acts then
        U.try(TAG, refreshActs)
    else
        local exists = runExists()
        showPoster("cont", exists ~= false)
        pcall(function() W.posters.new.set({ title = exists == false and "START\nCAMPAIGN" or "NEW\nCAMPAIGN" }) end)
    end
    refreshSlots(true)
end

local function ghostShown(g)
    local shown = false
    pcall(function() shown = g:GetVisibility() ~= VIS.Collapsed end)
    return shown
end

local function focusFirst()
    local first = { "cont", "new" }
    if W.acts then
        local p, st = S.progress or {}, S.states or {}
        first = {}
        if p.inProgress then first[1] = "cont" end
        for n = 1, 3 do if st[n] and st[n].next and st[n].unlocked then first[#first + 1] = "act" .. n end end
        first[#first + 1] = "act1"
    end
    for _, id in ipairs(first) do
        local g = W.ghosts[id]
        if U.ok(g) and ghostShown(g) then pcall(function() g:SetFocus() end); return end
    end
end

-- the focus look follows P1's CommonUI focus on the ghosts
local function paintFocus()
    if not W then return end
    local p1 = U.p1()
    W.focus = W.focus or {}
    for id, p in pairs(W.posters) do
        local f = false
        pcall(function() f = ui().hasFocus(W.ghosts[id], p1) == true end)
        if W.focus[id] ~= f then
            W.focus[id] = f
            pcall(function() p.focus(f) end)
        end
    end
    local m = W.modal
    if S.modal and m then
        local T = U.mod("theme")
        for k, gh in pairs(m.gh) do
            local f = false
            pcall(function() f = ui().hasFocus(gh, p1) == true end)
            if W.focus["m:" .. k] ~= f then
                W.focus["m:" .. k] = f
                pcall(function() T.set(m.btn[k], { colour = f and T.COL.RUST or T.COL.TILE }) end)
                pcall(function() T.set(m.lbl[k], { colour = f and T.COL.WHITE or T.COL.MIST }) end)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- F02 confirm
local function pageGhosts(on)
    if not W then return end
    local T = U.mod("theme")
    for _, gh in pairs(W.ghosts) do pcall(function() T.set(gh, { visible = on }) end) end
end

local function paintModal(on)
    local m = W and W.modal
    if not m then return end
    local T = U.mod("theme")
    local d = S.modal or {}
    local info = d.kind == "info"
    for _, e in ipairs({ m.dim, m.panel, m.title, m.body, m.foot }) do pcall(function() T.set(e, { visible = on }) end) end
    pcall(function() T.set(m.title, { text = d.title or "" }) end)
    pcall(function() T.set(m.body, { text = d.body or "" }) end)
    pcall(function() T.set(m.foot, { text = info and "(A) OK   (B) BACK" or "(A) SELECT   (B) NO" }) end)
    local yesOn, noOn = on and not info, on
    pcall(function() T.set(m.btn.yes, { visible = yesOn }) end)
    pcall(function() T.set(m.lbl.yes, { visible = yesOn, text = d.yes or "YES" }) end)
    pcall(function() T.set(m.gh.yes, { visible = yesOn }) end)
    local nr = info and BTN.ok or BTN.no
    local geo = W.geo
    local function LR(x, y, w, h) return { x - geo.x, y - geo.y, w, h } end
    pcall(function() T.set(m.btn.no, { visible = noOn, rect = LR(nr[1], nr[2], nr[3], nr[4]) }) end)
    pcall(function() T.set(m.lbl.no, { visible = noOn, text = info and "OK" or (d.no or "NO"),
                                       rect = LR(nr[1] + nr[3] / 2, nr[2] + nr[4] / 2) }) end)
    pcall(function() T.set(m.gh.no, { visible = noOn, rect = LR(nr[1], nr[2], nr[3], nr[4]) }) end)
    W.focus = nil
end

-- d = {kind = "replay" | "info", n, title, body, yes, no}
local function openModal(d)
    d.openedMs = St.nowMs()
    S.modal = d
    U.log(TAG, "confirm shown: %s (%s)", tostring(d.kind), tostring(d.title))
    if not W then return end
    pageGhosts(false)
    paintModal(true)
    -- the safe answer has the focus (NO / OK)
    pcall(function() local g = W.modal.gh.no; if U.ok(g) then g:SetFocus() end end)
end
M._openModal = openModal

local function closeModal(why, refocus)
    local d = S.modal
    if not d then return false end
    S.modal = nil
    U.log(TAG, "confirm closed: %s (%s)", tostring(d.kind), tostring(why))
    if W then
        paintModal(false)
        pageGhosts(true)
        if not W.acts then U.try(TAG, M.refresh) end          -- F01 page: CONTINUE stays hidden without a run
        if refocus ~= false then
            local back = d.from and W.ghosts[d.from]
            if U.ok(back) then pcall(function() back:SetFocus() end) else U.try(TAG, focusFirst) end
        end
    end
    return true
end

function M.modal() return S.modal end

---------------------------------------------------------------------------------------------------- open / close
function M.open()
    if not W and lastBuild and U.ok(lastBuild.root) and U.ok(lastBuild.page) then
        U.try(TAG, M.build, lastBuild.root, lastBuild.pc, lastBuild.page)
    end
    if not W then U.warn(TAG, "COUCH CAMPAIGN page not built: it cannot open"); return false end
    if St.phase ~= "FRONTEND" or St.launch.pending then return false end
    if S.active then M.refresh(); return true end
    pcall(function() U.mod("runpage").close("couch page") end)
    local okM, lobby = pcall(U.mod, "lobby")
    if okM and type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, true) end
    S.active = true
    S.modal = nil
    -- the pads join from here: no ADD PLAYERS confirm (this page IS the couch entry)
    pcall(function()
        local join = U.mod("join")
        if not join.padsEnabled() then join.enablePads("COUCH CAMPAIGN page") end
        if not St.join.active then join.open() end
    end)
    say("")
    M.refresh()
    paintModal(false)
    pcall(function() W.panel:SetVisibility(VIS.SelfHitTestInvisible) end)
    W.focus = nil
    U.try(TAG, focusFirst)
    U.log(TAG, "COUCH CAMPAIGN page opened (campaign run %s)", tostring(runExists()))
    return true
end

function M.close(why)
    if not S.active then return end
    S.active = false
    S.modal = nil
    if W then pcall(function() W.panel:SetVisibility(VIS.Collapsed) end) end
    local okM, lobby = pcall(U.mod, "lobby")
    if okM and type(lobby.setSetupMode) == "function" then U.try(TAG, lobby.setSetupMode, false) end
    U.log(TAG, "COUCH CAMPAIGN page closed (%s)", tostring(why))
end

-- the page closes and the pads' join window with it, right before the game's campaign entry
local function leaveFor(why)
    M.close(why)
    pcall(function() U.mod("join").close("couch campaign") end)
end

function M.onContinue()
    if not S.active then return end
    if W and W.acts then
        local p = acts().readProgress()
        if p.inProgress ~= true then say("No run in progress: pick an act to start a new run."); return end
    end
    leaveFor("CONTINUE CAMPAIGN")
    campaignSelected("CONTINUE CAMPAIGN")
end

-- F01 page (CouchActPosters = false): the NEW CAMPAIGN poster
function M.onNew()
    if not S.active then return end
    local exists = runExists()
    leaveFor("START NEW CAMPAIGN")
    if exists then
        -- a run exists: the CONTINUE tile's own restart (its confirm dialog, then the game starts the new run)
        local r = U.ok(T.rec) and T.rec or recommended()
        local ok = r and pcall(function() r:OnRestartCampaignPressed() end)
        U.log(TAG, "START NEW CAMPAIGN: the game's restart confirm %s", ok and "shown" or "NOT reached")
        if not ok then St.emit("status", "START A NEW CAMPAIGN FROM THE CAMPAIGN TAB") end
        return
    end
    campaignSelected("START CAMPAIGN")
end

-- F02: a new run of act n (abandon = the run in progress may be ended: the player said YES)
local function doReplay(n, abandon)
    local ok, msg = acts().replay(n, abandon, function(why)
        leaveFor(why)
        return campaignSelected(why)
    end)
    if not ok then
        U.warn(TAG, "REPLAY ACT %d: %s", n, tostring(msg))
        if S.active then say(msg) else St.emit("status", string.upper(tostring(msg))) end
    end
    return ok
end

function M.onAct(n)
    if not S.active or S.modal then return end
    local A = acts()
    local p = A.readProgress()
    local st = A.states(p)[n]
    if not st then return end
    if not st.unlocked then say(st.reason); return end
    if p.inProgress then
        local a = A.ACTS[n]
        openModal({ kind = "replay", n = n, from = "act" .. n, title = "START ACT " .. a.roman .. " AGAIN?",
                    body = "A new run of " .. actTitle(n) .. " starts with everyone who joined.\n\nYour run in progress ("
                        .. (p.runAct and actTitle(p.runAct) or "the current act") .. ") ends and cannot be continued. "
                        .. "Every unlocked act stays unlocked.",
                    yes = "YES, START", no = "NO" })
        return
    end
    doReplay(n, false)
end

-- the confirm's answer: k = "yes" | "no"
function M.onModal(k)
    local d = S.modal
    if not S.active or not d then return end
    if k ~= "yes" or d.kind == "info" then closeModal(k == "yes" and "OK" or "NO"); return end
    if St.nowMs() - (d.openedMs or 0) < YES_GUARD_MS then
        U.log(TAG, "confirm: YES %d ms after it opened ignored (the opening press)", math.floor(St.nowMs() - (d.openedMs or 0)))
        return
    end
    closeModal("YES", false)
    if d.kind == "replay" then
        if not doReplay(d.n, true) then U.try(TAG, focusFirst) end
    end
end

function M.onPoster(id)
    if S.modal then return end
    if id == "cont" then M.onContinue()
    elseif id == "new" then M.onNew()
    else
        local n = tonumber(string.match(tostring(id), "^act(%d)$"))
        if n then M.onAct(n) end
    end
end

-- P1's B (lobby's B poll after a race; backprompt.lua's QuitGame answer before that) = the confirm's NO, else close
function M.onP1Back(why)
    S.backMs = St.nowMs()
    if not S.active then return false end
    if S.modal then closeModal(why or "pad B"); return true end
    M.close(why or "pad B")
    return true
end
function M.lastP1BackMs() return S.backMs end
function M.onKey(name)
    if not S.active then return end
    if name == "back2" or name == "back" then M.onP1Back("keyboard back") end
end

-- offline tests
function M._setActive(on) S.active = on == true; if not on then S.modal = nil end end

---------------------------------------------------------------------------------------------------- the tile
-- Jules: campaign vehicles only (no podracer). No single game picture shows several, so the card stacks three of the
-- difficulty strips (each one campaign vehicle, the menu's own poster style, 1140 x 320): speeder bike, landspeeder,
-- skimmer. They go UNDER the tile's content in its O_ContentLayout overlay (B_ContentTint's parent): the overlay's own
-- children are taken out and added back after the strips, with their designer slot settings.
local STRIPS = { "T_UI_Difficulty_Tile_01", "T_UI_Difficulty_Tile_02", "T_UI_Difficulty_Tile_04" }
local function stripArt(tile)
    local tint = tile.B_ContentTint
    if not U.ok(tint) then error("B_ContentTint missing") end
    local ov = tint:GetParent()
    if not U.ok(ov) then error("O_ContentLayout missing") end
    local kids = {}
    local n = ov:GetChildrenCount()
    for i = 0, n - 1 do
        local c = ov:GetChildAt(i)
        if U.ok(c) then
            local info = { w = c }
            pcall(function()
                local sl = c.Slot
                info.pad = { Left = sl.Padding.Left, Top = sl.Padding.Top, Right = sl.Padding.Right, Bottom = sl.Padding.Bottom }
                info.h, info.v = sl.HorizontalAlignment, sl.VerticalAlignment
            end)
            kids[#kids + 1] = info
        end
    end
    local vb = mk(VBOX, tile)
    if not vb then error("no VerticalBox") end
    for _, name in ipairs(STRIPS) do
        local path = TX_TILE .. name .. "." .. name
        local tex = nil
        pcall(function() tex = U.obj(path) end)
        if not U.ok(tex) then pcall(function() tex = LoadAsset(path) end) end
        local img = mk(IMAGE, tile)
        if img and U.ok(tex) then
            pcall(function() img:SetBrushFromTexture(tex, false) end)
            pcall(function() img:SetVisibility(VIS.HitTestInvisible) end)
            local sl = vb:AddChildToVerticalBox(img)
            pcall(function() sl:SetSize({ Value = 1.0, SizeRule = 1 }) end)            -- Fill: three equal bands
            pcall(function() sl:SetHorizontalAlignment(0); sl:SetVerticalAlignment(0) end)
        end
    end
    for _, k in ipairs(kids) do pcall(function() k.w:RemoveFromParent() end) end
    local bs = ov:AddChildToOverlay(vb)
    pcall(function() bs:SetHorizontalAlignment(0); bs:SetVerticalAlignment(0) end)
    -- edge to edge: the same outset the art layer (B_ContentTint) has in the designer
    pcall(function() bs:SetPadding({ Left = -60, Top = -60, Right = -60, Bottom = -50 }) end)
    for _, k in ipairs(kids) do
        local sl = ov:AddChildToOverlay(k.w)
        pcall(function()
            if k.pad then sl:SetPadding(k.pad) end
            if k.h then sl:SetHorizontalAlignment(k.h) end
            if k.v then sl:SetVerticalAlignment(k.v) end
        end)
    end
    return #STRIPS
end

local function tileAlive() return T.tile and U.ok(T.tile) and T.rec and U.ok(T.rec) end

local function buildTile(rec)
    local cls = U.class(TILE_CLS)
    if not U.ok(cls) then pcall(function() local a = rec.Btn_Tile_A2; if U.ok(a) then cls = a:GetClass() end end) end
    if not U.ok(cls) then error("tile class not loaded") end
    -- VB_ButtonLayout is not a BP variable (only the Btn_Tile_* are): reach it as A2's parent
    local a2 = rec.Btn_Tile_A2
    if not U.ok(a2) then error("Btn_Tile_A2 missing") end
    local vb = nil
    pcall(function() vb = a2:GetParent() end)
    if not U.ok(vb) then pcall(function() vb = rec:GetWidgetFromName(U.fname("VB_ButtonLayout")) end) end
    if not U.ok(vb) then error("VB_ButtonLayout (A2's parent) missing") end
    local p1 = U.p1()
    local tile = U.WBL():Create(p1, cls, p1)
    if not U.ok(tile) then error("tile not created") end
    pcall(function() tile.TxtLabel = U.ftext("Couch Campaign") end)
    pcall(function() tile.ShowDescriptionText = false end)
    pcall(function() tile.ShowSupplementalText = false end)
    -- the slot's own look: A2's art, scale and offsets (made for this 900 x 718 card), A2's title ink
    pcall(function() tile.Icon = rec.Btn_Tile_A2.Icon end)
    pcall(function() tile.TileArt = rec.Btn_Tile_A2.TileArt end)        -- fallback art: the slot's own (A2)
    pcall(function() tile.TitleColor = rec.Btn_Tile_A2.TitleColor end)       -- the slot's light ink: the art is dark
    -- Jules: "zoom so that the height of the image is the height of the button". The tile material fits the art's
    -- WIDTH to the card (900 x 718) and wraps vertically: MP_02 is 1020 x 400, so its height covers 718 / (900 * 400 /
    -- 1020) = 2.03 cards' worth -> zoom 2.03, centred on the racers
    -- the art: T_UI_FE_Tile_MP_06 (two podracers racing, 1020 x 570, close to the card's shape) fills the card at 1.0
    pcall(function() tile.ImageScale = opt("CouchTileArtScale", 1.0) end)
    pcall(function() tile.ImageXOffset = opt("CouchTileArtX", 0.0); tile.ImageYOffset = opt("CouchTileArtY", 0.0) end)
    pcall(function() tile["In Wrap Text At"] = 880 end)
    pcall(function() tile["In Height Override"] = 718 end)
    pcall(function() tile["In Width Override"] = 900 end)
    pcall(function() tile.RequiresFullInstall = false end)
    local deluxe = ownsDeluxe()
    local idx = vb:GetChildIndex(a2)
    if type(idx) ~= "number" or idx < 0 then error("A2 not in VB_ButtonLayout") end
    -- InsertChildAt is editor-only: append, then move it right after A2 when ShiftChild exists. Appended after the
    -- column's two empty Fill rows it still lands where A2 was (they take the gap A2 leaves)
    local slot = vb:AddChild(tile)
    if not U.ok(slot) then error("AddChild refused the tile") end
    local shifted = pcall(function() vb:ShiftChild(idx + 1, tile) end)
    U.dbg(TAG, "tile %s", shifted and "moved after A2 (ShiftChild)" or "appended (no ShiftChild)")
    if not deluxe then
        pcall(function() a2:SetVisibility(VIS.Collapsed) end)
    else
        pcall(function() a2.Slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 44 }) end)
    end
    pcall(function() if U.ok(slot) then slot:SetVerticalAlignment(0) end end)            -- VAlign_Top, as A2
    -- Jules: "reuse another image with multiple vehicles": the multiplayer key art with a row of racers
    pcall(function()
        local tex = nil
        pcall(function() tex = U.obj(TILE_ART) end)
        if not U.ok(tex) then pcall(function() tex = LoadAsset(TILE_ART) end) end
        -- TileArt is a HARD Texture2D (TileBase.SetTileArt ends in self.TileArt = HardImage); PreConstruct builds the
        -- tile material from it. Never call SetTileArt from Lua: its first parameter is a SOFT reference and a UObject
        -- there crashed the game (VCRUNTIME140 write in UE4SS's parameter copy, live 2026-10-15 14:30)
        if U.ok(tex) then tile.TileArt = tex end
    end)
    pcall(function() tile:PreConstruct(false) end)
    pcall(function() tile.Txt_Label_Title:SetText(U.ftext("Couch Campaign")) end)
    if opt("CouchTileStrips", true) ~= false then
        local okS, nS = pcall(stripArt, tile)
        if not okS then U.warn(TAG, "vehicle strips not added (%s): the tile keeps its picture", tostring(nS)) end
    end
    pcall(function() tile:SetIsLocked(false) end)
    pcall(function() tile:SetIsSelectable(true); tile:SetIsToggleable(true) end)        -- the A poll (ui.lua poll mode)
    pcall(function() tile:BP_SetIsFocusable(true) end)
    pcall(function() tile:SetVisibility(VIS.Visible) end)
    T.rec, T.tile = rec, tile
    U.log(TAG, "COUCH CAMPAIGN tile added on the Campaign tab (%s)",
        deluxe and "Deluxe Edition: under the Art Book" or "in place of the Deluxe upsell")
end

local function tileTick(now)
    if opt("CouchCampaignTile", true) == false then return end
    local tile = T.tile
    if tileAlive() and U.ok(tile) then
        local sel = false
        pcall(function() sel = tile:GetSelected() == true end)
        if sel then
            pcall(function() tile:SetIsSelected(false, false) end)
            U.log(TAG, "COUCH CAMPAIGN tile pressed")
            S.openWanted = now + 4000
            pcall(function() U.mod("menu_tab").selectOurTab() end)
        end
        return
    end
    if now - T.scanMs < 500 then return end
    T.scanMs = now
    T.tile = nil
    local rec = recommended()
    if not rec then return end
    local ok, err = pcall(buildTile, rec)
    if not ok then U.logEvery("couchpage.tile", 10000, TAG, "COUCH CAMPAIGN tile not built: %s", tostring(err)) end
end

-- FAST loop (main.lua): the tile on the Campaign tab, the deferred page open after the tab switch, the slot lines
function M.fastTick()
    -- F02: which act the replayed run really plays (read once the run exists; FindFirstOf at most once a second)
    if acts().pendingVerify then
        local nowV = St.nowMs()
        if nowV - S.verifyMs >= 1000 then S.verifyMs = nowV; U.try(TAG, acts().verifyTick) end
    end
    if St.phase ~= "FRONTEND" or St.launch.pending then
        T.rec, T.tile = nil, nil
        if S.active then M.close("phase " .. tostring(St.phase)) end
        return
    end
    local now = St.nowMs()
    U.try(TAG, tileTick, now)
    if S.openWanted > 0 then
        if now > S.openWanted then S.openWanted = 0
        elseif St.menu.visible == "lobby" and W then
            S.openWanted = 0
            U.try(TAG, M.open)
        end
    end
    if S.active then U.try(TAG, paintFocus) end
    if S.active and now - S.lastSlotsMs > 300 then
        S.lastSlotsMs = now
        U.try(TAG, refreshSlots, false)
    end
end

-- dev: build the page again in place (live layout work)
function M.rebuildPage()
    if not lastBuild then return "no build arguments" end
    M.close("rebuild")
    if W and U.ok(W.panel) then pcall(function() W.panel:RemoveFromParent() end) end
    M.build(lastBuild.root, lastBuild.pc, lastBuild.page)
    return "page rebuilt: " .. tostring(W ~= nil)
end

-- dev: drop the tile (the next scan builds it again)
function M.resetTile()
    local tile, rec = T.tile, T.rec
    if U.ok(tile) then pcall(function() tile:RemoveFromParent() end) end
    if U.ok(rec) then pcall(function() local a2 = rec.Btn_Tile_A2; if U.ok(a2) then a2:SetVisibility(VIS.Visible) end end) end
    T.tile, T.rec, T.scanMs = nil, nil, -1e12
    return "tile reset"
end

function M.status()
    return string.format("couchpage: tile %s, page %s (%s)%s", tileAlive() and "up" or "down",
        S.active and "open" or "closed", W and "built" or "not built", S.modal and (", confirm " .. tostring(S.modal.kind)) or "")
end

return M
