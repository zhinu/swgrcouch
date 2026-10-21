-- couchbets.lua: COUCH CAMPAIGN - every guest's own PRE-RACE CHALLENGES (the game's side bets), 0.15.
-- Jules 2026-10-14 (live): "at a race's pre-race /CHALLENGES screen there is NO P2 content". Rule of the project: every
-- per-player moment shows the game's OWN screen for each player.
--
-- NATIVE FLOW (static, 2026-10-14: cue4cli --script decodes of WBP_PreRace_SideBets, WBP_Sidebet_Choice_Btn,
-- WBP_PlayerCreditsAmount, CSM_RF_SideBet*, JMAP CL381121):
--   * race flow CSM_RF_InRacePhase > CSM_RF_SideBet (ESimpleRaceGameModeState::SideBets, track RaceStartGrid, the
--     sidebet camera) auto-enters CSM_RF_SideBet_UI ("SidebetUI": WidgetClassToShow WBP_PreRace_SideBets_C on
--     EUILayer::Menu, ForceNewInstance false), whose ContinueCosmeticStateName is SidebetGraceTime. Mod phase PRERACE.
--     LIVE (19:51 probe, 2P qualifier): the screen is OWNED BY THE GUEST'S PlayerController (the UIManager's last local
--     PC, as every native screen) - P1's pad does not reach it natively (the qualifier harness had to click it).
--   * data: ViewModelSubsystem.SidebetChoicesVM (GetSidebetChoicesVM is a GETTER: the screen's Construct takes the ONE
--     shared VM, there is no Build* copy) .Challenges = Array<SidebetChallengeVM> {ChallengerName, bIsRival,
--     bIsHighRisk, bIsFavourAvailable, CreditAmount (the stake), PredictedFinishPosition, ChallengerAvatarIconTexture,
--     mSidebet: CampaignSidebetOption {racer: RacerDef}}; the run side is CampaignRun.mAvailableSidebets.
--   * the screen: Construct -> SidebetVM = GetSidebetChoicesVM(); InitChallengeButton(Btn_ChallengerA/B/C, i) copies
--     the VM row into the WBP_Sidebet_Choice_Btn (name, Credits, CharacterIcon, PredictedFinishPosition, rival icon,
--     favour) and RefreshView (affordability vs GetCreditsForCurrentPrimaryFlow = P1's credits: unaffordable = grey
--     ButtonContent + red B_CreditTint + interaction off). PreConstruct: Btn_ChallengerA:SetFocus().
--     OnButtonBaseFocused (A/B/C) -> "Set new racer hovered" -> SidebetsCameraComponent:OnNewRacerHovered on
--     GetPlayerController(0)'s view target (THE shared camera). OnButtonBaseClicked (A/B/C) -> ChooseChallengeAndMoveOn(i):
--     credits >= stake -> SidebetVM:ChooseChallenge (native: P1's bet) -> nemesis VO -> RacingGameMode:NotifySidebetComplete
--     -> OwningStateMachine:ContinueToNextState. WBP_Hero_Btn (DECLINE, bRequiresHold) clicked -> NotifySidebetComplete +
--     ContinueToNextState. The credits chip WBP_PlayerCreditsAmount reads P1's credits and its Tick writes
--     CampaignSubsystem:SetLastVisualCreditsValue (the same value as P1's own chip).
--   * settlement: native (PlayerSidebetOutcomeGameplayAction {Player, Target, HasWonSidebet, NumCreditsStaked,
--     NumCreditsWon}, CampaignStringsDef.PlayerFacingCreditsReasonSidebetWon / Lost) - a head-to-head with the TARGET
--     racer, booked on P1's run only.
--
-- WHAT THIS MODULE DOES (only while couch.active() in PRERACE, cfg.CouchBets):
--   1. P1's native screen goes into P1's area (couchroot user "bets": strips / quadrants, as the reward split);
--   2. every joined guest gets a SECOND INSTANCE of WBP_PreRace_SideBets_C in his area, owned by his PC, on the game's
--      paper - DISPLAY ONLY. Its Construct takes P1's (shared) VM: the same rivals and predictions (race facts); the mod
--      then re-tints every stake for the GUEST's couch credits and writes his credits into its chip. A second instance
--      is safe to show but NOT to use: any click on it runs ChooseChallengeAndMoveOn on P1's VM (a bet on P1's run +
--      NotifySidebetComplete). So, before it is constructed, its four buttons are made non-focusable (BP_SetIsFocusable
--      false: its PreConstruct SetFocus and Slate's accept never reach them, no OnButtonBaseFocused = P1's camera never
--      moves), the instance is HitTestInvisible and never activated (no CommonUI action binding is live).
--   3. the guest's pad drives invisible plain UMG buttons (couchpanel's technique, HasUserFocus / IsPressed); his focused
--      row shows through the instance's own BP_OnFocusReceived / Lost look. A = challenge that racer (stake vs his couch
--      credits: couchrun.placeBet deducts it), HOLD A on DECLINE = no bet (every row is a native hold: see holdMs). A guest's Slate focus is
--      moved OFF P1's native screen at once (live it starts there: the screen is his) and kept on his own buttons.
--   4. settlement at POSTRACE: guest finished AHEAD of the challenged racer = won (cfg.CouchBetRule "beat"; "predicted" =
--      the racer finished worse than his predicted place); won pays stake x cfg.CouchBetPayout into his couch credits
--      (couchrun.settleBet). A race left before its result (restart / quit) refunds the stake.
--   5. P1's pad on his own (guest-owned) screen - the P1 bridge (cfg.CouchBetP1Bridge): P1's Slate user gets the focus
--      on the screen's first affordable button (his D-pad then moves it natively, with the native camera hover); his A
--      is read from his own PlayerInput (P1's PC keeps id 0 in a race: no pad-id swap here, see below) and, when the
--      game did not act within cfg.MenuBridgeWaitMs, the button HE focuses is clicked through its own path
--      (HandleButtonClicked -> ChooseChallengeAndMoveOn); HOLD A on DECLINE runs the screen's own decline event. "Acted"
--      = the ChooseChallenge / NotifySidebetComplete hooks fired since the press (never a second bet).
-- No pad-id swap / park in a race (couch.lua swaps only in the paddock and post-race): in PRERACE inputfix, ignition, hud
-- and pause key per-player state on ControllerId; a swap there is unverified. The park's purpose (a guest's pad never
-- reaches P1's screen) is met by (3): his focus is never on it, and his own LocalPlayer has no IMC_UI (no CommonUI
-- accept); the screen is never his to click.
-- Scan rules (couch.lua): couch.activeScreens() only, nothing during couch.isQuiet(), U.alive before a UFunction on a
-- kept widget. Every UObject call is pcall-guarded; any build error = that guest gets the plain list look (or nothing),
-- P1's native flow is untouched.
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "couchbets"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function CP() return U.mod("couchpanel") end
local function CR() return U.mod("couchrun") end
local function couch() return U.mod("couch") end
local function rootMod() local ok, r = pcall(U.mod, "couchroot"); return (ok and type(r) == "table") and r or nil end

local SCREEN_CLS = "WBP_PreRace_SideBets_C"
local SCREEN = "/Game/Griffin/UI/Screens/PreRace/WBP_PreRace_SideBets.WBP_PreRace_SideBets_C"
local BTNS = { "Btn_ChallengerA", "Btn_ChallengerB", "Btn_ChallengerC" }
local HERO = "WBP_Hero_Btn"
local BND_HERO = "BndEvt__WBP_PreRace_SideBets_WBP_Hero_Btn_K2Node_ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature"
local HOOK_CHOOSE = "/Script/Griffin.SidebetChoicesVM:ChooseChallenge"
local HOOK_DONE = "/Script/Griffin.RacingGameMode:NotifySidebetComplete"
local KEY_A = { "Gamepad_FaceButton_Bottom", "Enter" }
local CSM_SIDEBET = "/Game/Griffin/Config/StateMachines/RaceFlow/CSM_RF_SideBet.CSM_RF_SideBet"
local MAX_ROWS = 3
local NAV = { Up = 2, Down = 3 }                    -- EUINavigation
local NAV_STOP = 3                                  -- EUINavigationRule::Stop
-- the screen's own colours (decoded): the dimmed rows after a pick, RefreshView's unaffordable grey / red tint
local DIM   = { R = 0.0252, G = 0.0704, B = 0.0908, A = 1 }
local GREY  = { R = 0.057, G = 0.057, B = 0.057, A = 1 }
local RED   = { R = 0.6172, G = 0.1095, B = 0.0423, A = 1 }
local WHITE = { R = 1, G = 1, B = 1, A = 1 }

-- S.panels[i] = P { ctrlId, pnum, pc, slot, region, rows, sel, done, note, scr (his instance), btns (ghosts), shown,
-- prevA, holdAt, focusAt, toast, toastUntil }
local S = { open = false, native = nil, nativeKey = 0, host = nil, panels = {}, n = 1, offers = nil, lastScan = 0,
            failKey = 0, acted = 0, br = { focusAt = -1e12, down = false, logged = false }, hooks = false, own = {},
            targets = {} }

---------------------------------------------------------------------------------------------------- pure rules
-- outcome of a guest's challenge: rule "beat" (default) = he finished ahead of the target; "predicted" = the target
-- finished worse than predicted. guestOut = the guest wrecked / did not finish. -> "won" | "lost" | "void"
function M.outcome(rule, guestPos, guestOut, targetPos, predicted)
    guestPos, targetPos, predicted = tonumber(guestPos), tonumber(targetPos), tonumber(predicted)
    if targetPos == nil or targetPos <= 0 or targetPos >= 99 then return "void" end
    if rule == "predicted" then
        if predicted == nil or predicted <= 0 then return "void" end
        return (targetPos > predicted) and "won" or "lost"
    end
    if guestOut or guestPos == nil or guestPos <= 0 or guestPos >= 99 then return "lost" end
    return (guestPos < targetPos) and "won" or "lost"
end

-- credits as the native chip prints them (Conv_IntToText with grouping)
function M.groupDigits(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local neg = s:sub(1, 1) == "-"
    if neg then s = s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (neg and "-" or "") .. out
end

---------------------------------------------------------------------------------------------------- native reads
-- the challenges of P1's native screen: { {i, name, stake, predicted, rival, risk, vm}, ... } (VM order = the buttons)
local function readOffers(nat)
    local out = {}
    if not U.alive(nat) then return out end
    local svm = nil
    pcall(function() svm = nat.SidebetVM end)
    if not U.ok(svm) then return out end
    local list = {}
    pcall(function() list = U.arrayToTable(svm.Challenges) end)
    for i = 1, math.min(MAX_ROWS, #list) do
        local c = list[i]
        if U.ok(c) then
            local o = { i = i, name = "?", stake = 0, predicted = 0, vm = c }
            pcall(function() o.name = c.ChallengerName:ToString() end)
            pcall(function() o.stake = math.floor(tonumber(c.CreditAmount) or 0) end)
            pcall(function() o.predicted = math.floor(tonumber(c.PredictedFinishPosition) or 0) end)
            pcall(function() o.rival = c.bIsRival == true end)
            pcall(function() o.risk = c.bIsHighRisk == true end)
            -- #110 the challenged racer's RacerDef (Racer Roulette counts the won bets against Biddy Blas)
            pcall(function() local d = c.mSidebet.racer; if U.ok(d) then o.racer = U.objName(d) end end)
            if type(o.name) ~= "string" or o.name == "" then o.name = "RACER " .. i end
            out[#out + 1] = o
        end
    end
    return out, svm
end

-- the challenged racer's PlayerState (SidebetChoicesVM:GetPawnForChallenge, native pure) -> ps or nil
local function targetOf(svm, chal)
    if not (U.ok(svm) and U.ok(chal)) then return nil end
    local pawn = nil
    pcall(function() pawn = svm:GetPawnForChallenge(chal) end)
    if not U.ok(pawn) then return nil end
    local ps = nil
    pcall(function() ps = pawn.PlayerState end)
    return U.ok(ps) and ps or nil
end

local function guestCredits(ctrlId)
    local p = nil
    pcall(function() p = CR().player(ctrlId) end)
    return (type(p) == "table" and math.floor(tonumber(p.credits) or 0)) or 0
end

---------------------------------------------------------------------------------------------------- hooks
-- P1's native acts (the bridge's "acted" signature) and P1's bet for the log. Registered once (U.hook: native paths).
local function armHooks()
    if S.hooks then return end
    S.hooks = true
    local okC = U.hook(HOOK_CHOOSE, { post = function(ctx, chosen)
        S.acted = S.acted + 1
        local name = "?"
        local bet = { gen = St.worldGen }
        pcall(function()
            local c = chosen and chosen:get()
            if U.ok(c) then
                name = c.ChallengerName:ToString()
                bet.name = name
                -- #110 P1's bet for the team's Racer Roulette (its racer, its car for the result)
                pcall(function() local d = c.mSidebet.racer; if U.ok(d) then bet.racer = U.objName(d) end end)
                local svm = ctx and ctx:get() or nil
                bet.tps = targetOf(svm, c)
            end
        end)
        S.p1Bet = bet
        U.log(TAG, "P1 challenges %s (the game's own bet on P1's run)", tostring(name))
    end }, TAG)
    local okD = U.hook(HOOK_DONE, { post = function() S.acted = S.acted + 1 end }, TAG)
    -- without them a press the game took natively cannot be told from one it ignored: the bridge then relies on the
    -- screen's activation only (a native A + a bridged click inside its Anim_Out = a second bet)
    if okC ~= true or okD ~= true then
        U.warn(TAG, "P1 bridge: hook ChooseChallenge %s, NotifySidebetComplete %s - a native A may be bridged twice",
            okC == true and "on" or "MISSING", okD == true and "on" or "MISSING")
    else
        U.log(TAG, "P1 bridge: ChooseChallenge / NotifySidebetComplete hooks on")
    end
end

---------------------------------------------------------------------------------------------------- widgets
local function kit() return CP().kit end

local function setTint(w, field, c)
    if U.ok(w) then pcall(function() w[field]:SetContentColorAndOpacity(c) end) end
end

-- the guest's instance after its Construct: his stakes' affordability, his credits in the chip, no favour marks
local function fillNative(P)
    local scr = P.scr
    if not U.alive(scr) then return end
    local cr = guestCredits(P.ctrlId)
    for _, r in ipairs(P.rows) do
        if r.kind == "bet" then
            local b = nil
            pcall(function() b = scr[BTNS[r.i]] end)
            if U.ok(b) then
                local can = cr >= r.stake
                setTint(b, "ButtonContent", can and WHITE or GREY)
                setTint(b, "B_CreditTint", can and WHITE or RED)
                pcall(function() b.Img_Favour:SetVisibility(kit().VIS.Collapsed) end)   -- P1's favour, not his
            end
        end
    end
    pcall(function() scr.SzB_Favor:SetVisibility(kit().VIS.Hidden) end)
    -- NOTE 7: the instance's own chip = HIS credits for good (couchpanel.chipRewire: its Tick writes P1's credits to
    -- a detached text) + his P-tag inside it; settled (the old way) only if the rewire fails
    if not P.instChip then
        local chip = nil
        pcall(function() chip = scr.WBP_PlayerCreditsAmount end)
        if U.ok(chip) then
            P.instChip = kit().chipRewire(chip)
            pcall(kit().tagInto, chip, P.pnum)
        end
    end
    if P.instChip then kit().chipFeed(P.instChip, cr) end
    if P.topChip and P.topChip.nat then kit().chipFeed(P.topChip.nat, cr) end
end

-- the native button of row index i on the guest's instance (a challenger, or the DECLINE hero button)
local function nativeBtn(P, i)
    local r = P.rows[i]
    if not r or not U.alive(P.scr) then return nil end
    local b = nil
    pcall(function() b = (r.kind == "bet") and P.scr[BTNS[r.i]] or P.scr[HERO] end)
    return U.ok(b) and b or nil
end

-- the guest's focused row drawn by the instance's own focus events (cosmetic BP events: no OnButtonBaseFocused)
local function showFocus(P)
    if P.done or P.shown == P.sel then return end
    local old = P.shown and nativeBtn(P, P.shown)
    if old then pcall(function() old:BP_OnFocusLost() end) end
    local b = nativeBtn(P, P.sel)
    if b then pcall(function() b:BP_OnFocusReceived() end) end
    P.shown = P.sel
end

-- the 16:9 frame of a region (strips: the centred 1920 x 1080; quadrants: the quadrant)
local function frameOf(r)
    local fw = math.min(r.w, r.h * 16 / 9)
    local fh = fw * 9 / 16
    return r.x + (r.w - fw) / 2, r.y + (r.h - fh) / 2, fw, fh
end

local function paperIn(tree, cv, x, y, w, h, z)
    local k = kit()
    local img = k.mk(k.IMAGE, tree)
    if not img then return nil end
    k.place(cv, img, x, y, w, h, z or 0)
    local tex = k.texOf(k.PAPER_TEX)
    pcall(function()
        if tex then img:SetBrushFromTexture(tex, false) else img:SetColorAndOpacity(k.lin(k.colours.PAPER)) end
        img:SetVisibility(k.VIS.HitTestInvisible)
    end)
    return img
end

-- the guest's own WBP_PreRace_SideBets_C in his area (raises on failure: the caller keeps the list look)
local function buildNative(H, P)
    local k = kit()
    local cls = U.class(SCREEN)
    if not U.ok(cls) then error("challenges screen class not loaded") end
    if not U.ok(P.pc) then error("no guest PlayerController") end
    local r = P.region
    local sc = k.mk(k.SCALE, H.tree)
    if not sc then error("no ScaleBox") end
    pcall(function() sc:SetStretch(2) end)                                      -- ScaleToFit
    k.place(H.cv, sc, r.x, r.y, r.w, r.h, 1)
    local sb = k.mk(k.SIZEB, H.tree)
    if not sb then error("no SizeBox") end
    sb:SetWidthOverride(k.VW); sb:SetHeightOverride(k.VH)
    sc:AddChild(sb)
    local scr = U.WBL():Create(P.pc, cls, P.pc)
    if not U.ok(scr) then error("challenges screen not created") end
    k.own(scr)
    S.own[U.key(scr)] = true
    pcall(function() rootMod().exclude(scr) end)
    pcall(function() scr.bAutoActivate = false end)
    -- BEFORE its construction (the host's AddToViewport): no button of this instance may ever take a focus or a click
    local nf = 0
    for _, nm in ipairs({ BTNS[1], BTNS[2], BTNS[3], HERO }) do
        if pcall(function() scr[nm]:BP_SetIsFocusable(false) end) then nf = nf + 1 end
    end
    if nf < 4 then error(string.format("only %d of 4 buttons made non-focusable", nf)) end
    sb:AddChild(scr)
    pcall(function() scr:SetVisibility(k.VIS.HitTestInvisible) end)
    P.scr, P.sc = scr, sc
end

-- the plain look (the native instance failed): one line per row on the paper
local function buildList(H, P)
    local k = kit()
    local r = P.region
    local f = math.max(0.5, r.h / 2160)
    P.lines = {}
    for i, row in ipairs(P.rows) do
        local t = k.text(H.tree, math.floor(56 * f), k.colours.INKD)
        k.place(H.cv, t, r.x + math.floor(r.w * 0.55), r.y + math.floor((420 + (i - 1) * 190) * f), nil, nil, 3)
        local s = (row.kind == "bet") and string.format("%s  -  Predicted %d  -  %s CR", row.name, row.predicted,
            M.groupDigits(row.stake)) or "DECLINE (hold A)"
        k.setText(t, s)
        P.lines[i] = t
    end
    local hd = k.text(H.tree, math.floor(80 * f), k.colours.INKD)
    k.place(H.cv, hd, r.x + math.floor(r.w * 0.55), r.y + math.floor(250 * f), nil, nil, 3)
    k.setText(hd, "/CHALLENGES")
end

-- invisible plain buttons (one per row, stacked over the panel's place), D-pad Up / Down only, Stop at the ends
local function buildGhosts(H, P)
    local k = kit()
    local r = P.region
    P.btns = {}
    for i = 1, #P.rows do
        local b = k.mk(k.BUTTON, H.tree)
        if b then
            k.place(H.cv, b, r.x + 20 + (i - 1) * 60, r.y + r.h - 80, 50, 50, 50)
            pcall(function() b:SetRenderOpacity(0.01) end)
        end
        P.btns[i] = b
    end
end

local function navGhosts(P)
    local n = #P.btns
    for i, b in ipairs(P.btns) do
        if U.ok(b) then
            local up, down = P.btns[i - 1], P.btns[i + 1]
            for dir, t in pairs({ [NAV.Up] = up, [NAV.Down] = down }) do
                if U.ok(t) then pcall(function() b:SetNavigationRuleExplicit(dir, t) end)
                else pcall(function() b:SetNavigationRuleBase(dir, NAV_STOP) end) end
            end
            for _, dir in ipairs({ 0, 1, 4, 5 }) do pcall(function() b:SetNavigationRuleBase(dir, NAV_STOP) end) end
        end
    end
    return n
end

-- NOTE 7 (Jules: the P2 tag clipped at the strip's far left, "0 CR - A challenge HOLD A on DECLINE" plain white text
-- = ugly, tiny chips, P2's showing 0): inside his 16:9 frame - the P-tag top left; the game's action-bar look bottom right
-- (the header pill backer, the pad's own A glyph T_UI_Cntrl_XB_A_Icn, "Challenge" / "Hold  Decline"); his credits as
-- the game's chip + P-tag top right (couchpanel.chipAt, rewired to his couch credits). P1's area gets his own chip there.
local BAR_INK = { R = 0.7758, G = 0.7305, B = 0.6654, A = 1 }      -- #E4DED5 (the game's light ink on dark pills)
local function chipScale(fh) return math.max(0.75, fh / 2160) end

local function buildBar(H, P, fx, fy, fw, fh)
    local k = kit()
    local s = chipScale(fh)
    local bh = math.floor(72 * s + 0.5)
    local B = { s = s, h = bh, right = math.floor(fx + fw - 32 * s), y = math.floor(fy + fh - 32 * s - bh),
                left = math.floor(fx + 32 * s) }                -- couch-fix63 (AUTO-154b): the bar stays inside his frame
    B.back = k.pillImage(H.tree, "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_FE_Section_CurrencyBacker.MI_UI_Pill_FE_Section_CurrencyBacker",
        { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.9 })
    B.backSlot = k.place(H.cv, B.back, B.right - 400, B.y, 400, bh, 40)
    -- couch-fix46 (live round 1 AUTO-120: "every choice is a HOLD, nothing on P2's half tells him to hold"): the hold's
    -- progress fills the bar's pill from the left (the game's hold buttons fill as they are held), so a short press
    -- shows a fill that drops back and a held one fills to the end
    B.fill = k.pillImage(H.tree, "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_FE_Section_CurrencyBacker.MI_UI_Pill_FE_Section_CurrencyBacker",
        { R = 0.9, G = 0.55, B = 0.08, A = 0.85 })
    B.fillSlot = k.place(H.cv, B.fill, B.right - 400, B.y, 0, bh, 40)
    k.show(B.fill, false)
    -- LIVE 2026-10-14: the glyphs were WHITE SQUARES - theme.glyph returns the texture's PATH, and a path given to
    -- SetBrushFromTexture fails (the image keeps its blank brush). The texture is loaded by its path (couchpanel
    -- texOf: StaticFindObject, else LoadAsset); not found = no image at all, the bar writes "A" instead.
    local gtex = nil
    pcall(function() gtex = k.texOf(U.mod("theme").glyph("A")) end)
    B.noGlyph = not U.ok(gtex)
    if B.noGlyph then U.warn(TAG, "P%s: the pad's A glyph texture is not loaded: the bar writes 'A'", tostring(P.pnum)) end
    local function glyph()
        if B.noGlyph then return nil end
        local g = k.mk(k.IMAGE, H.tree)
        if not g then return nil end
        local ok = pcall(function() g:SetBrushFromTexture(gtex, false) end)
        if not ok then pcall(function() g:SetVisibility(k.VIS.Collapsed) end); return nil end
        pcall(function() g:SetVisibility(k.VIS.HitTestInvisible) end)
        return g, k.place(H.cv, g, 0, B.y + math.floor((bh - 48 * s) / 2), math.floor(48 * s), math.floor(48 * s), 41)
    end
    local function label()
        local t = k.text(H.tree, math.floor(30 * s + 0.5), BAR_INK, k.FONT_BODY)
        local sl = k.place(H.cv, t, 0, B.y + bh / 2, nil, nil, 41)
        pcall(function() sl:SetAlignment({ X = 0, Y = 0.5 }) end)
        return t, sl
    end
    B.g1, B.g1s = glyph(); B.t1, B.t1s = label(); B.g2, B.g2s = glyph(); B.t2, B.t2s = label()
    B.t3, B.t3s = label(); B.t4, B.t4s = label()
    B.note, B.notes = label()
    B.gy, B.ty = B.y + math.floor((bh - 48 * s) / 2), B.y + bh / 2
    P.bar = B
end

-- the bar's items right-aligned (text widths from theme.textWidth: Overpass ~ Font_Body)
-- couch-fix63 (AUTO-154b): x 1.1 - the estimate is the Medium Italic table, the bar's labels are Font_Body's default face
-- (live shot 130548: the text ran ~10 % past the backer the estimate sized)
local function textW(t, size)
    local w = #t * size * 0.5
    pcall(function() w = U.mod("theme").textWidth(t, "posterDesc", size) end)
    return w * 1.1
end
local function layoutBar(P, items)
    local k, B = kit(), P.bar
    if not B then return end
    local s = B.s
    local size = math.floor(30 * s + 0.5)
    local gw, gap, padX = math.floor(48 * s), math.floor(12 * s), math.floor(28 * s)
    local seq = {}
    for _, it in ipairs(items) do
        if it.glyph and (B.noGlyph or not U.ok(B.g1)) then seq[#seq + 1] = { text = "A" }   -- no texture: the letter
        else seq[#seq + 1] = it end
    end
    local function measure()
        local t = padX * 2
        for i, it in ipairs(seq) do
            it.w = it.glyph and gw or textW(it.text, size)
            t = t + it.w + ((i > 1) and (it.glyph and gap * 3 or gap) or 0)
        end
        return t
    end
    local total = measure()
    -- couch-fix63 (AUTO-154b, live round 8 shot 130548: "CHALLENGE Soren Zaks -600 CR - CHALLENGED Soren Zaks - WAITING
    -- FOR P1" ran past his frame's left and the screen's right edge): a bar wider than his frame gets a smaller text
    local avail = (B.left and (B.right - B.left)) or nil
    if avail and total > avail then
        local fixed = total
        for _, it in ipairs(seq) do if not it.glyph then fixed = fixed - it.w end end
        local textTotal = total - fixed
        if textTotal > 0 then
            size = math.max(math.floor(16 * s), math.floor(size * (avail - fixed) / textTotal))
            total = measure()
        end
    end
    if B.textSize ~= size then
        for _, key in ipairs({ "t1", "t2", "t3", "t4", "note" }) do
            local t = B[key]
            if t then pcall(function() k.setTextFit(t, "", nil, size, k.FONT_BODY, "posterDesc") end) end
        end
        B.textSize = size
    end
    local x = B.right - total + padX
    pcall(function() B.backSlot:SetPosition({ X = B.right - total, Y = B.y }); B.backSlot:SetSize({ X = total, Y = B.h }) end)
    B.x0, B.total = B.right - total, total
    local used = { g1 = false, t1 = false, g2 = false, t2 = false, t3 = false, t4 = false, note = false }
    local gi, ti = 0, 0
    for i, it in ipairs(seq) do
        if i > 1 then x = x + (it.glyph and gap * 3 or gap) end
        local key
        if it.glyph then gi = gi + 1; key = "g" .. gi
        elseif it.note then key = "note"
        else ti = ti + 1; key = "t" .. ti end
        used[key] = true
        local sl = B[key .. "s"]
        local yy = it.glyph and B.gy or B.ty
        if sl then pcall(function() sl:SetPosition({ X = x, Y = yy }) end) end
        B[key .. "x"] = x
        if not it.glyph then k.setText(B[key], it.text) end
        x = x + it.w
    end
    for key, on in pairs(used) do k.show(B[key], on) end
    P.barText = {}
    for _, it in ipairs(seq) do if not it.glyph then P.barText[#P.barText + 1] = it.text end end
end

-- couch-fix46: the hold's progress on his bar (0 = none)
local function barHold(P, pct)
    local k, B = kit(), P.bar
    if not (B and B.fill and B.total) then return end
    pct = math.max(0, math.min(1, tonumber(pct) or 0))
    if pct <= 0 then
        if B.fillOn then k.show(B.fill, false); B.fillOn = false end
        return
    end
    local w = math.max(B.h, math.floor(B.total * pct + 0.5))
    pcall(function() B.fillSlot:SetPosition({ X = B.x0, Y = B.y }); B.fillSlot:SetSize({ X = w, Y = B.h }) end)
    if not B.fillOn then k.show(B.fill, true); B.fillOn = true end
    B.fillMax = math.max(B.fillMax or 0, pct)
end

local function buildMarks(H, P)
    local k = kit()
    local fx, fy, fw, fh = frameOf(P.region)
    local s = chipScale(fh)
    local bh = math.floor(64 * s + 0.5)
    local bw = math.floor(bh * 1.45 + 0.5)
    local bx, by = math.floor(fx + 32 * s), math.floor(fy + 32 * s)
    P.badgeRect = { bx, by, bw, bh }
    P.badge = k.solid(H.tree, k.colours.AMBER)
    k.place(H.cv, P.badge, bx, by, bw, bh, 20)
    P.badgeT = k.text(H.tree, math.floor(bh * 0.62), k.colours.INKD)
    local sb = k.place(H.cv, P.badgeT, bx + bw / 2, by + bh / 2, nil, nil, 21)
    pcall(function() sb:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    buildBar(H, P, fx, fy, fw, fh)
    local okC, c = pcall(k.chipAt, H, math.floor(fx + fw - 32 * s), math.floor(fy + 32 * s), s, P.pnum,
        guestCredits(P.ctrlId), true)
    P.topChip = okC and c or nil
end

---------------------------------------------------------------------------------------------------- render
local function render(P)
    local k = kit()
    k.setText(P.badgeT, "P" .. tostring(P.pnum))
    local now = St.nowMs()
    local toast = (P.toast and now < (P.toastUntil or 0)) and P.toast or nil
    if P.done then
        -- couch-fix63 (AUTO-154b): the pick's own toast ("CHALLENGE Soren Zaks -600 CR") said the same as his note
        -- ("CHALLENGED Soren Zaks - WAITING FOR P1") on one line: the note alone
        layoutBar(P, { { note = true, text = P.note or "WAITING FOR P1" } })
    elseif toast then
        layoutBar(P, { { note = true, text = toast } })
    else
        layoutBar(P, { { glyph = true }, { text = "Hold  Select" } })
    end
    local cr = guestCredits(P.ctrlId)
    if P.topChip and P.topChip.nat then k.chipFeed(P.topChip.nat, cr) end
    if P.instChip then k.chipFeed(P.instChip, cr) end
    if P.scr then
        pcall(showFocus, P)
        if U.alive(P.scr) then pcall(function() P.scr:SetRenderOpacity(P.done and 0.6 or 1) end) end
    elseif P.lines then
        for i, t in ipairs(P.lines) do k.setInk(t, (i == P.sel and not P.done) and k.colours.AMBER or k.colours.INKD) end
    end
end

---------------------------------------------------------------------------------------------------- guest picks
local function pick(P)
    local row = P.rows[P.sel]
    if not row or P.done then return end
    if row.kind ~= "bet" then return end                     -- DECLINE is a hold (poll)
    local cr = guestCredits(P.ctrlId)
    if cr < row.stake then
        P.toast, P.toastUntil = "NOT ENOUGH CREDITS", St.nowMs() + 2000
        render(P)
        return
    end
    local tps = targetOf(S.svm, row.vm)
    local ok, toast = CR().placeBet(P.ctrlId, { name = row.name, stake = row.stake, predicted = row.predicted,
        rival = row.rival, gen = St.worldGen, rule = opt("CouchBetRule", "beat"), target = tps and true or false,
        racer = row.racer })
    P.toast, P.toastUntil = toast, St.nowMs() + 3000
    if ok then
        S.targets[P.ctrlId] = tps
        P.done, P.note = true, "CHALLENGED " .. row.name .. " - WAITING FOR P1"
        -- the native pick look on his instance: the chosen row's own click animation, the others dimmed
        local b = nativeBtn(P, P.sel)
        if b then pcall(function() b:BP_OnClicked() end) end
        for i = 1, #P.rows do
            local o = (i ~= P.sel) and nativeBtn(P, i) or nil
            if o then pcall(function() o:SetColorAndOpacity(DIM) end) end
        end
        if not tps then U.warn(TAG, "P%s: %s's car not found (GetPawnForChallenge): the bet is void at the result",
            tostring(P.pnum), row.name) end
    end
    render(P)
end

local function decline(P, why)
    if P.done then return end
    P.done, P.note = true, "DECLINED - WAITING FOR P1"
    for i, r in ipairs(P.rows) do
        if r.kind == "bet" then
            local o = nativeBtn(P, i)
            if o then pcall(function() o:SetColorAndOpacity(DIM) end) end
        end
    end
    U.log(TAG, "P%s declines the challenges (%s)", tostring(P.pnum), tostring(why))
    render(P)
end

-- HOLD (couch-livefix d, live 2026-10-16: "a hold placed P2's challenge instead of declining"). Decoded: EVERY choice
-- of the game's screen is a hold button - WBP_Sidebet_Choice_Btn (the 3 challengers) AND the DECLINE WBP_Hero_Btn
-- both have bRequiresHold = true with BP_HoldData_Default (HoldTime = CommonUI's default 0.75 s, only the rollback
-- overridden); WBP_PreRace_SideBets binds no input action of its own. So A HELD on the focused row chooses it (a
-- challenger = challenge, DECLINE = decline) and a short A does nothing. The mod's guests picked a challenger at the
-- key-down of ANY press and labelled DECLINE alone "Hold": a hold meant as a decline challenged his focused racer.
-- Now the guests and P1's bridge both need the row's own hold time (the native button's GetRequiredHoldTime, else
-- cfg.CouchBetHoldMs), with the native hold progress on the row; the bar reads "Hold A  Select".
local function holdMs()
    return math.max(100, tonumber(opt("CouchBetHoldMs", 750)) or 750)
end
local function holdFor(btn)
    local need = holdMs()
    if U.ok(btn) then
        pcall(function() local t = tonumber(btn:GetRequiredHoldTime()); if t and t > 0 then need = t * 1000 end end)
    end
    return need
end

-- the guest's pad: his invisible buttons (couchpanel's kit: Slate user focus + IsPressed)
local function poll(P, now)
    if P.toast and now >= (P.toastUntil or 0) then P.toast = nil; render(P) end
    local k = kit()
    -- #47 (tester #1 shot 18: both of P2's chips showed P1's 3,685 on the CHALLENGES screen): the chips were fed at the
    -- build and on events only. A chip whose Txt_PlayerCredits swap did not stick is the native one: its Tick writes
    -- P1's credits again whenever P1's value moves (here: the skip-cinematic payout right after the build). Re-fed
    -- every tick when settled (as couchpanel's settled chips), and whenever his credits move when swapped.
    local cr = nil
    for _, c in ipairs({ P.topChip and P.topChip.nat or false, P.instChip or false }) do
        if c and (not c.swapped or c.shown ~= (cr or guestCredits(P.ctrlId))) then
            cr = cr or guestCredits(P.ctrlId)
            k.chipFeed(c, cr)
        end
    end
    local pc = k.padPC(P.ctrlId)
    if not U.ok(pc) then return end
    local focused = nil
    for i, b in ipairs(P.btns) do
        if U.ok(b) and k.padHasFocus(b, P.ctrlId, pc) then focused = i; break end
    end
    if not focused then
        -- his focus anywhere else (at first P1's native screen, which the game focused for its owner = him; CommonUI
        -- may focus it for him again when another of his screens comes and goes): back on his own row at once, then
        -- every 2 FAST ticks (no park in a race: SetUserFocus is one plain call; parked, couch.withPadId's 250 ms)
        local gap = (k.padParked and k.padParked(P.ctrlId)) and 250 or 60
        if now - (P.focusAt or -1e12) > gap then
            P.focusAt = now
            local b = P.btns[P.sel]
            if U.ok(b) then k.padSetFocus(b, P.ctrlId, pc) end
        end
        P.prevA, P.holdAt = true, nil
        barHold(P, 0)
        return
    end
    if P.done then P.prevA = true; return end
    if focused ~= P.sel then
        P.sel, P.holdAt = focused, nil
        barHold(P, 0)
        render(P)
    end
    local b = P.btns[focused]
    local pressed = false
    if U.ok(b) then pcall(function() pressed = b:IsPressed() == true end) end
    local row = P.rows[focused]
    -- a hold starts only at a press made on this row (a key still held from elsewhere never chooses)
    if pressed and not P.prevA then P.holdAt = now end
    if row and pressed and P.holdAt then
        local hb = nativeBtn(P, focused)
        local pct = math.min(1, (now - P.holdAt) / holdFor(hb))
        if hb then pcall(function() hb:OnActionProgress(pct) end) end
        barHold(P, pct)
        if pct >= 1 then
            P.holdAt = nil
            if hb then pcall(function() hb:OnActionProgress(0) end) end
            barHold(P, 0)
            if row.kind == "decline" then decline(P, "held A on DECLINE") else pick(P) end
        end
    elseif not pressed and P.holdAt then
        local held = now - P.holdAt
        P.holdAt = nil
        local hb = nativeBtn(P, focused)
        if hb then pcall(function() hb:OnActionProgress(0) end) end
        barHold(P, 0)
        if not P.done then
            P.toast, P.toastUntil = "HOLD A TO SELECT", now + 1500
            render(P)
            U.log(TAG, "P%s's A on row %d released after %d ms: every choice is a HOLD (as the game's own)",
                tostring(P.pnum), focused, math.floor(held))
        end
    end
    P.prevA = pressed
end

---------------------------------------------------------------------------------------------------- open / close
local function guests()
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    local out = {}
    if okJ and type(list) == "table" then
        for _, e in ipairs(list) do if #out < 3 then out[#out + 1] = e end end
    end
    return out
end

local function sittingOut(ctrlId)
    local r = package.loaded["couchrules"]
    if type(r) ~= "table" or type(r.isSittingOut) ~= "function" then return false end
    local ok, v = pcall(r.isSittingOut, ctrlId)
    return ok and v == true
end

local function close(why, calls)
    if not S.open then return end
    for _, P in ipairs(S.panels) do
        if not P.done then
            P.done = true
            U.log(TAG, "P%s made no challenge (%s)", tostring(P.pnum), tostring(why))
        end
    end
    if calls ~= false then
        local h = S.host
        if U.alive(h) then pcall(function() h:RemoveFromParent() end) end
    end
    local r = rootMod()
    if r and not S.p1only then U.try(TAG, r.finish, "bets", calls) end
    U.log(TAG, "challenges %s closed (%s)", S.p1only and "P1-only bridge" or "split", tostring(why))
    if S.p1wait then U.warn(TAG, "P1's held-back answer dropped: the split closed (%s)", tostring(why)) end
    S.p1wait, S.p1NoteT, S.p1NoteB = nil, nil, nil
    S.open, S.native, S.nativeKey, S.host, S.panels, S.offers, S.svm = false, nil, 0, nil, {}, nil, nil
    S.p1btns, S.p1Chip, S.paperRects, S.dsink, S.p1only = nil, nil, nil, nil, nil
end

-- (couch-livefix f) LIVE 2026-10-16: a guest who LEFT (hold B: his PC stays, dormant) still drove P1's challenges -
-- the screen belongs to the LAST local PC (his), and with no joined guest the couch rules (and this module) were off.
-- No joined guest but the screen not P1's: a P1-ONLY split - no guest area, only P1's bridge buttons (his pad drives
-- his screen as in a couch race) and the dormant pads' focus kept off the screen (M.dormantOff).
local function openP1Only(nat)
    local k = kit()
    local okB, err = pcall(function()
        local H = CP().newHost()
        S.host, S.panels, S.n, S.offers, S.svm, S.own = H.host, {}, 1, readOffers(nat), nil, {}
        S.own[U.key(H.host)] = true
        S.p1btns = {}
        for i = 1, 5 do                                -- 4 rows + the dormant pads' sink (5)
            local b = k.mk(k.BUTTON, H.tree)
            if b then
                k.place(H.cv, b, 20 + (i - 1) * 60, k.VH - 80, 50, 50, 50)
                pcall(function() b:SetRenderOpacity(0.01) end)
            end
            if i <= 4 then S.p1btns[i] = b else S.dsink = b end
        end
        H.host:AddToViewport(tonumber(opt("CouchPanelZ", 1000)) or 1000)
        navGhosts({ btns = S.p1btns })
        if U.ok(S.dsink) then
            for _, dir in ipairs({ 0, 1, 2, 3, 4, 5 }) do pcall(function() S.dsink:SetNavigationRuleBase(dir, NAV_STOP) end) end
        end
    end)
    if not okB then
        U.warn(TAG, "P1-only challenges bridge not built: %s", tostring(err))
        local h = S.host
        if U.alive(h) then pcall(function() h:RemoveFromParent() end) end
        S.host, S.p1btns, S.dsink = nil, nil, nil
        S.failKey = U.key(nat)
        return
    end
    S.open, S.native, S.nativeKey, S.p1only = true, nat, U.key(nat), true
    U.log(TAG, "challenges: no joined guest, P1's screen owned by another local PC: P1-only bridge (a dormant pad "
        .. "never answers it)")
end

-- every local PC that is neither P1 nor a joined guest: its user's focus off P1's native screen (onto the sink)
local function dormantOff(nat)
    if not (U.alive(nat) and U.ok(S.dsink)) then return end
    local joined = {}
    for _, g in ipairs(guests()) do if U.ok(g.pc) then joined[U.key(g.pc)] = true end end
    local lps = U.localPlayers()
    for i = 2, #lps do
        local pc = lps[i].pc
        if U.ok(pc) and not joined[U.key(pc)] then
            local f = false
            pcall(function() f = nat:HasUserFocusedDescendants(pc) == true or nat:HasUserFocus(pc) == true end)
            if f then
                local ok = pcall(function() S.dsink:SetUserFocus(pc) end)
                S.dormantMoves = (S.dormantMoves or 0) + 1
                U.logEvery("cb.dormant", 3000, TAG, "a dormant pad's focus was on P1's challenges: moved off (%s)",
                    ok and "ok" or "failed")
            end
        end
    end
end
M._dormantOff = dormantOff

local function open(nat)
    local gl = guests()
    if #gl == 0 then
        local own = nil
        pcall(function() own = nat:GetOwningPlayer() end)
        local p1 = U.p1()
        if U.ok(own) and U.ok(p1) and U.key(own) ~= U.key(p1) then openP1Only(nat) end
        return
    end
    local offers, svm = readOffers(nat)
    local nk = U.key(nat)
    if #offers == 0 then
        if S.emptyKey ~= nk then S.emptyKey = nk; U.log(TAG, "challenges screen: no challenge readable yet (retrying)") end
        return
    end
    local n = math.min(4, 1 + #gl)
    local R = CP().regionsFor(n)
    local k = kit()
    local okB, err = pcall(function()
        local H = CP().newHost()
        S.host, S.panels, S.n, S.offers, S.svm, S.own = H.host, {}, n, offers, svm, {}
        S.own[U.key(H.host)] = true
        -- NOTE 7 (Jules: "P2's strip is empty paper"): a guest's 16:9 frame stays OPEN - his own view of the grid (his
        -- split viewport) shows behind his /CHALLENGES like P1's scene behind his; the paper only on the strip's sides
        -- outside the frame (as P1's strip), and over the free 4th quadrant of 3 players
        S.paperRects = {}
        -- (7) each side piece is a crop of one cover of the guest's whole region (texture aspect kept, never squeezed)
        local function paper(x, y, w, h, full)
            if w > 0 and h > 0 then
                if type(k.paperCover) == "function" then k.paperCover(H.tree, H.cv, { x, y, w, h }, full, 0)
                else paperIn(H.tree, H.cv, x, y, w, h, 0) end
                S.paperRects[#S.paperRects + 1] = { x, y, w, h }
            end
        end
        for slot = 1, 3 do
            local rg = R[slot]
            if rg and slot <= #gl then
                local fx, _, fw = frameOf(rg)
                local full = { rg.x, rg.y, rg.w, rg.h }
                paper(rg.x, rg.y, fx - rg.x, rg.h, full)
                paper(fx + fw, rg.y, rg.x + rg.w - fx - fw, rg.h, full)
            elseif rg and n >= 3 then
                paper(rg.x, rg.y, rg.w, rg.h)
            end
        end
        pcall(function()
            if n >= 3 then local v = k.solid(H.tree, k.colours.AMBER); k.place(H.cv, v, 1916, 0, 8, k.VH, 30) end
            local h = k.solid(H.tree, k.colours.AMBER); k.place(H.cv, h, 0, 1076, k.VW, 8, 30)
        end)
        for i, g in ipairs(gl) do
            CR().ensure(g.ctrlId, g.pnum)
            local prev = CR().player(g.ctrlId)
            if prev and prev.bet then CR().voidBet(g.ctrlId, "a bet of an earlier race was still open") end
            local rows = {}
            for _, o in ipairs(offers) do
                rows[#rows + 1] = { kind = "bet", i = o.i, name = o.name, stake = o.stake, predicted = o.predicted,
                                    rival = o.rival, vm = o.vm, racer = o.racer }
            end
            rows[#rows + 1] = { kind = "decline" }
            local P = { ctrlId = g.ctrlId, pnum = g.pnum, pc = g.padPc or g.pc, slot = i, region = R[i], rows = rows,
                        sel = #rows, done = false, prevA = true }
            local cr = guestCredits(g.ctrlId)
            for j, r in ipairs(rows) do if r.kind == "bet" and cr >= r.stake then P.sel = j; break end end
            if sittingOut(g.ctrlId) then P.done, P.note = true, "SITTING OUT THIS RACE - NO CHALLENGE" end
            if opt("CouchBetsNative", true) ~= false then
                local okN, errN = pcall(buildNative, H, P)
                if not okN then
                    U.warn(TAG, "P%s native challenges screen failed (%s): the plain list instead", tostring(g.pnum), tostring(errN))
                    P.scr = nil
                end
            end
            if not P.scr then pcall(buildList, H, P) end
            buildGhosts(H, P)
            buildMarks(H, P)
            S.panels[#S.panels + 1] = P
        end
        -- NOTE 7: P1's own credits chip top right of his frame (the game's chip, his run's credits, his P-tag)
        pcall(function()
            local fx, fy, fw, fh = frameOf(R[0])
            local s = chipScale(fh)
            local p1cr = 0
            pcall(function() p1cr = CR().campaignCredits() or 0 end)
            S.p1Chip = k.chipAt(H, math.floor(fx + fw - 32 * s), math.floor(fy + 32 * s), s, 1, p1cr, false)
        end)
        -- the P1 bridge's own input (live 2026-10-14: P1's A did NOTHING): 4 invisible plain buttons in P1's area, the
        -- rows of his native screen (3 challengers + DECLINE), D-pad Up / Down between them
        S.p1btns = {}
        local r1 = R[0]
        local ds = k.mk(k.BUTTON, H.tree)               -- (f) the dormant pads' focus sink
        if U.ok(ds) then
            k.place(H.cv, ds, r1.x + 4, r1.y + r1.h - 30, 8, 8, 50)
            pcall(function() ds:SetRenderOpacity(0.01) end)
            for _, dir in ipairs({ 0, 1, 2, 3, 4, 5 }) do pcall(function() ds:SetNavigationRuleBase(dir, NAV_STOP) end) end
        end
        S.dsink = ds
        for i = 1, 4 do
            local b = k.mk(k.BUTTON, H.tree)
            if b then
                k.place(H.cv, b, r1.x + 20 + (i - 1) * 60, r1.y + r1.h - 80, 50, 50, 50)
                pcall(function() b:SetRenderOpacity(0.01) end)
            end
            S.p1btns[i] = b
        end
        -- FINDING #8: P1's "WAITING FOR P2" plate (his answer held back until the guests chose), bottom left of his frame
        pcall(function()
            local fx, fy, fw, fh = frameOf(r1)
            local s = chipScale(fh)
            local bh = math.floor(72 * s + 0.5)
            local y = math.floor(fy + fh - 32 * s - bh)
            S.p1NoteB = k.pillImage(H.tree, "/Game/Griffin/UI/Library/Materials/Common/MI_UI_Pill_FE_Section_CurrencyBacker.MI_UI_Pill_FE_Section_CurrencyBacker",
                { R = 0.0065, G = 0.0065, B = 0.0065, A = 0.9 })
            k.place(H.cv, S.p1NoteB, math.floor(fx + 32 * s), y, math.floor(560 * s), bh, 40)
            S.p1NoteT = k.text(H.tree, math.floor(30 * s + 0.5), BAR_INK, k.FONT_BODY)
            local sl = k.place(H.cv, S.p1NoteT, math.floor(fx + 60 * s), y + bh / 2, nil, nil, 41)
            pcall(function() sl:SetAlignment({ X = 0, Y = 0.5 }) end)
            k.show(S.p1NoteB, false); k.show(S.p1NoteT, false)
        end)
        H.host:AddToViewport(tonumber(opt("CouchPanelZ", 1000)) or 1000)
        navGhosts({ btns = S.p1btns })
        for _, P in ipairs(S.panels) do
            navGhosts(P)
            if P.scr then
                pcall(fillNative, P)
                U.playAnim(P.scr, "Anim_In")   -- no OnAnimInComplete bound
            end
        end
    end)
    if not okB then
        U.warn(TAG, "challenges split not built: %s", tostring(err))
        local h = S.host
        if U.alive(h) then pcall(function() h:RemoveFromParent() end) end
        S.host, S.panels, S.offers, S.svm = nil, {}, nil, nil
        S.failKey = nk
        return
    end
    S.open, S.native, S.nativeKey = true, nat, nk
    local rt = rootMod()
    if rt then pcall(function() rt.exclude(S.host); rt.begin("bets", n) end) end
    local names = {}
    for _, o in ipairs(offers) do names[#names + 1] = string.format("%s (pred %d, %d CR)", o.name, o.predicted, o.stake) end
    local views = {}
    for _, P in ipairs(S.panels) do
        views[#views + 1] = string.format("P%d %s%s", P.pnum, P.scr and "native" or "list", P.done and " (sitting out)" or "")
    end
    U.log(TAG, "challenges split open for %d player(s): %s; challenges %s", n, table.concat(views, ", "),
        table.concat(names, ", "))
    for _, P in ipairs(S.panels) do render(P) end
end

---------------------------------------------------------------------------------------------------- P1 bridge
-- LIVE 2026-10-14 (merged build): P1's A did NOTHING. The old bridge put P1's Slate focus on the guest-owned screen's
-- own CommonButtons and polled P1's PlayerInput: a CommonButton swallows the key for a user that is not its screen's
-- owner (no click) and nothing reaches P1's PlayerInput either (menubridge V-MB-08/09: same on the post-race screens).
-- Now P1's Slate focus sits on 4 invisible PLAIN UMG buttons of the mod (S.p1btns, the rows of his screen): a plain
-- Button handles the accept key itself, IsPressed() is true while P1 holds A (the V-MB-09 catcher, the guests'
-- technique); his D-pad moves between them (explicit Up / Down). His focused row is mirrored onto his native screen: the
-- row's own focus look (BP_OnFocusReceived / Lost) and the shared sidebet camera through the screen's own
-- "Set new racer hovered"(index). A on a challenger = that button's own click (HandleButtonClicked ->
-- ChooseChallengeAndMoveOn); HOLD A on DECLINE = the screen's own decline event. PlayerInput's A still counts (a
-- session where it does reach P1's PC).
local waitGuests          -- (FINDING #8, below)
local function keyDownP1(pc)
    local ui = U.mod("ui")
    for _, n in ipairs(KEY_A) do if ui.keyDown(pc, n) then return true end end
    return false
end

-- P1's focused ghost row: 1..3 challengers, 4 = DECLINE, nil = none
local function p1Ghost(pc)
    for i, b in ipairs(S.p1btns or {}) do
        local has = false
        if U.ok(b) then pcall(function() has = b:HasUserFocus(pc) == true end) end
        if has then return i end
    end
    return nil
end

local function p1Mirror(nat, f)
    local br = S.br
    if br.shownRow == f then return end
    local function btn(i) return (i == 4) and HERO or BTNS[i] end
    if br.shownRow then pcall(function() nat[btn(br.shownRow)]:BP_OnFocusLost() end) end
    if f then
        pcall(function() nat[btn(f)]:BP_OnFocusReceived() end)
        if f <= 3 then pcall(function() nat["Set new racer hovered"](nat, f - 1) end) end
    end
    br.shownRow = f
end

-- FINDING #8 (live 2026-10-17): P1 confirmed first, the screen's ChooseChallengeAndMoveOn closed it and P2's pick
-- was lost ("P2 made no challenge (native screen closed)"). P1's answer (bridged) now WAITS while a joined guest has
-- not chosen: his row keeps the pick look, his area reads "WAITING FOR P2", and the game's own move-on (the same
-- ChooseChallengeAndMoveOn / decline event as before) runs once every guest has challenged or declined - or after
-- cfg.CouchBetWaitMs (an undecided guest = declined), or when P1 holds A cfg.CouchBetForceMs once more.
-- (A P1 hold the game takes NATIVELY - his own screen - cannot be held back: it moves on as before.)
local function guestsWaiting()
    local out = {}
    for _, P in ipairs(S.panels) do if not P.done then out[#out + 1] = "P" .. tostring(P.pnum) end end
    return out
end

local function p1Note(text)
    local k = kit()
    if S.p1NoteT then k.setText(S.p1NoteT, text or "") end
    if S.p1NoteT then k.show(S.p1NoteT, text ~= nil) end
    if S.p1NoteB then k.show(S.p1NoteB, text ~= nil) end
end

-- -> true when P1's answer is held back (the guests still choosing)
waitGuests = function(nat, kind, btn, now)
    if opt("CouchBetWaitGuests", true) == false or S.p1only or not S.open then return false end
    local w = guestsWaiting()
    if #w == 0 then return false end
    S.p1wait = { kind = kind, btn = btn, at = now, nat = nat, natKey = U.key(nat), down = true }
    for j, nm in ipairs({ BTNS[1], BTNS[2], BTNS[3], HERO }) do
        if j ~= btn then pcall(function() nat[nm]:SetColorAndOpacity(DIM) end) end
    end
    p1Note("WAITING FOR " .. table.concat(w, ", "))
    U.log(TAG, "P1 %s: held back until %s chose (the game moves on after every guest's answer, at most %d s; "
        .. "P1 holds A %d s to move on now)", kind == "bet" and ("challenges row " .. tostring(btn)) or "declines",
        table.concat(w, ", "), math.floor((tonumber(opt("CouchBetWaitMs", 20000)) or 20000) / 1000),
        math.floor((tonumber(opt("CouchBetForceMs", 2000)) or 2000) / 1000))
    return true
end

-- the held-back answer: the game's own move-on now
local function runP1Answer(why)
    local wt = S.p1wait
    S.p1wait = nil
    if not wt then return end
    local nat = wt.nat
    for _, P in ipairs(S.panels) do
        if not P.done then
            P.done, P.note = true, "NO CHALLENGE - P1 MOVED ON"
            U.log(TAG, "P%s declines the challenges (%s)", tostring(P.pnum), tostring(why))
            U.try(TAG, render, P)
        end
    end
    p1Note(nil)
    if not U.alive(nat) then U.warn(TAG, "P1's held-back answer: the screen is gone (%s)", tostring(why)); return end
    if wt.kind == "decline" then
        local rb = nil
        pcall(function() rb = nat[HERO] end)
        local ok = pcall(function() nat[BND_HERO](nat, rb) end)
        U.log(TAG, "P1 held A on DECLINE: the screen's own decline event %s (%s)", ok and "ran" or "FAILED", tostring(why))
    else
        local ok = pcall(function() nat:ChooseChallengeAndMoveOn(wt.btn - 1) end)
        if not ok then ok = pcall(function() nat[BTNS[wt.btn]]:HandleButtonClicked() end) end
        U.log(TAG, "P1's A -> challenge %d: the screen's ChooseChallengeAndMoveOn %s (%s)", wt.btn, ok and "ran" or "FAILED",
            tostring(why))
    end
end

local function waitTick(now)
    local wt = S.p1wait
    if not wt then return end
    local w = guestsWaiting()
    if #w == 0 then runP1Answer("every guest chose"); return end
    p1Note("WAITING FOR " .. table.concat(w, ", "))
    if now - wt.at >= (tonumber(opt("CouchBetWaitMs", 20000)) or 20000) then
        runP1Answer(string.format("%s still choosing after %d s: P1 moves on", table.concat(w, ", "),
            math.floor((now - wt.at) / 1000)))
        return
    end
    -- P1's force: A held CouchBetForceMs (a fresh press after his pick)
    local p1 = U.p1()
    local down = false
    if U.ok(p1) then
        down = keyDownP1(p1)
        for _, b in ipairs(S.p1btns or {}) do
            if not down and U.ok(b) then pcall(function() down = b:IsPressed() == true end) end
        end
    end
    if not down then wt.down, wt.downAt = false, nil
    elseif not wt.down then wt.down, wt.downAt = true, now end
    if wt.downAt and now - wt.downAt >= (tonumber(opt("CouchBetForceMs", 2000)) or 2000) then
        runP1Answer("P1 held A: moves on now")
    end
end
M._waitTick = waitTick

local function bridge(nat, now)
    if opt("CouchBetP1Bridge", true) == false then return end
    if not U.alive(nat) then return end
    if St.pause and St.pause.menuWasPaused == true then return end
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local own = nil
    pcall(function() own = nat:GetOwningPlayer() end)
    if U.ok(own) and U.key(own) == U.key(p1) then return end          -- P1's own screen: native input
    local br = S.br
    local nk = U.key(nat)
    if br.key ~= nk then
        br.key, br.down, br.fired, br.pending, br.focusAt, br.acted00, br.done = nk, true, false, nil, -1e12, S.acted, false
        br.shownRow, br.lastRow = nil, nil
    end
    -- the screen already took its answer (P1's bet or decline, native or bridged): it is on its way out (Anim_Out),
    -- nothing more is bridged on it
    -- (br.done: the bridge answered it itself - also when the hooks never fire)
    if br.done or (S.acted ~= br.acted00 and not br.pending) then return end
    local f = p1Ghost(p1)
    if not f and now - br.focusAt > 300 then
        br.focusAt = now
        local ix = 0
        pcall(function() ix = math.floor(tonumber(nat.SidebetVM:GetIndexForFirstAffordableChallenge()) or 0) end)
        local row = (ix >= 0 and ix <= 2) and (ix + 1) or 4
        local b = S.p1btns and S.p1btns[br.lastRow or row]
        local ok = U.ok(b) and pcall(function() b:SetUserFocus(p1) end)
        if not br.logged then
            br.logged = true
            U.log(TAG, "P1's challenges screen is owned by a guest: P1's pad on the bridge's own buttons (row %d), "
                .. "his A bridged (%s)", br.lastRow or row, ok and "ok" or "SetUserFocus failed")
        end
        f = p1Ghost(p1)
    end
    if f then br.lastRow = f end
    p1Mirror(nat, f)
    local pressed = false
    if f and U.ok(S.p1btns[f]) then pcall(function() pressed = S.p1btns[f]:IsPressed() == true end) end
    local down = pressed or keyDownP1(p1)
    if down and not br.down then
        -- the game's own press acts at the key-down event, before this poll: "acted" is judged against the count of
        -- the tick before the press
        br.downAt, br.btn, br.acted0, br.fired = now, f, br.lastActed or S.acted, false
        U.log(TAG, "P1's A on row %s (%s)", tostring(f), pressed and "bridge button" or "PlayerInput")
    end
    if not down then br.lastActed = S.acted end
    -- every row is a HOLD button (see holdMs): the row's own hold time, its native progress, then its own path
    local function rowBtn(i) local b = nil; pcall(function() b = nat[(i == 4) and HERO or BTNS[i]] end); return U.ok(b) and b or nil end
    if down and br.btn and not br.fired and br.downAt then
        local rb = rowBtn(br.btn)
        local pct = math.min(1, (now - br.downAt) / holdFor(rb))
        if rb then pcall(function() rb:OnActionProgress(pct) end) end
        if pct >= 1 and S.acted == br.acted0 then
            br.fired = true
            if br.btn == 4 then
                br.done = true
                if not waitGuests(nat, "decline", 4, now) then
                    local ok = pcall(function() nat[BND_HERO](nat, rb) end)
                    U.log(TAG, "P1 held A on DECLINE: the screen's own decline event %s", ok and "ran" or "FAILED")
                end
            else
                -- (a native hold completing at the same moment: the pending check below sees its hooks and stays out)
                br.pending = { at = now, btn = br.btn, acted0 = br.acted0 }
            end
        end
    end
    if not down and br.down and br.btn then
        local rb = rowBtn(br.btn)
        if rb then pcall(function() rb:OnActionProgress(0) end) end
        if not br.fired and br.downAt then
            U.log(TAG, "P1's A on %s released after %d ms: every choice is the screen's HOLD button (hold A ~%d ms)",
                br.btn == 4 and "DECLINE" or ("challenge " .. br.btn), math.floor(now - br.downAt), math.floor(holdFor(rb)))
        end
    end
    br.down = down
    local pd = br.pending
    if pd and now - pd.at >= (tonumber(opt("MenuBridgeWaitMs", 150)) or 150) then
        br.pending = nil
        if S.acted ~= pd.acted0 then
            U.log(TAG, "P1's A on challenge %d acted natively: not bridged", pd.btn)
        else
            local act = false
            pcall(function() act = nat:IsActivated() == true end)
            local cr0, stake0 = nil, nil
            pcall(function() cr0 = tonumber(U.mod("couchrun").campaignCredits()) end)
            pcall(function() stake0 = tonumber(nat.SidebetVM.Challenges[pd.btn].CreditAmount) end)
            local affordable = not (cr0 and stake0 and cr0 < stake0)
            if act and affordable and waitGuests(nat, "bet", pd.btn, now) then
                br.fired, br.done = true, true
            elseif act then
                br.fired = true
                -- LIVE 2026-10-14: the screen must CLOSE. The screen's own ChooseChallengeAndMoveOn(index) is the full
                -- native path (decoded @0-845: P1's credits vs the stake -> SidebetChoicesVM:ChooseChallenge ->
                -- nemesis VO -> RacingGameMode:NotifySidebetComplete -> OwningStateMachine:ContinueToNextState;
                -- unaffordable = its "invalid" sound), then the click's own dimming of the other rows (@376-593);
                -- the button's HandleButtonClicked only if that call is refused
                local ok = pcall(function() nat:ChooseChallengeAndMoveOn(pd.btn - 1) end)
                if ok then
                    for j, nm in ipairs({ BTNS[1], BTNS[2], BTNS[3], HERO }) do
                        if j ~= pd.btn then pcall(function() nat[nm]:SetColorAndOpacity(DIM) end) end
                    end
                else
                    ok = pcall(function() nat[BTNS[pd.btn]]:HandleButtonClicked() end)
                end
                -- an unaffordable challenge is refused by the screen itself (its "invalid" sound): P1 may pick again
                local cr, stake = nil, nil
                pcall(function() cr = tonumber(U.mod("couchrun").campaignCredits()) end)
                pcall(function() stake = tonumber(nat.SidebetVM.Challenges[pd.btn].CreditAmount) end)
                if not (cr and stake and cr < stake) then br.done = true end
                U.log(TAG, "P1's A -> challenge %d: the screen's ChooseChallengeAndMoveOn %s", pd.btn, ok and "ran" or "FAILED")
            else
                U.log(TAG, "P1's A -> challenge %d: the screen is not activated (no click)", pd.btn)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- settlement
local function readRec(ps)
    local pos, out = nil, false
    if not U.ok(ps) then return nil, true end
    -- couch-fix30 (audit 12 #5): a final event won by a guest swapped his REC with P1's: settle on his REAL place
    local okR, rp, rw = pcall(function() return U.mod("couchrules").realResult(ps) end)
    if okR and rp then return math.floor(tonumber(rp) or 99), rw == true end
    pcall(function()
        local rec = ps.RaceEventComponent
        pos = math.floor(tonumber(rec.EventPosition) or 99)
        out = rec.bHasVehicleWrecked == true
    end)
    return pos, out
end

function M.settle(why)
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    for _, e in ipairs(list) do
        local p = CR().player(e.ctrlId)
        local bet = p and p.bet or nil
        if bet then
            if bet.gen ~= nil and bet.gen ~= St.worldGen then
                CR().voidBet(e.ctrlId, "placed in another race")
            else
                local gps = nil
                pcall(function() gps = e.pc.PlayerState end)
                local gpos, gout = readRec(gps)
                local tps = S.targets[e.ctrlId]
                local tpos = nil
                if U.ok(tps) then tpos = select(1, readRec(tps)) end
                local res = M.outcome(bet.rule or opt("CouchBetRule", "beat"), gpos, gout, tpos, bet.predicted)
                if res == "void" then
                    CR().voidBet(e.ctrlId, string.format("%s's result unreadable", tostring(bet.name)))
                else
                    CR().settleBet(e.ctrlId, res == "won", { pos = gpos, out = gout, targetPos = tpos, why = why })
                end
            end
            S.targets[e.ctrlId] = nil
        end
    end
    -- #110 Racer Roulette counts P1's won bets too (the native head-to-head: P1 ahead of the target)
    local pb = S.p1Bet
    S.p1Bet = nil
    if type(pb) == "table" and pb.gen == St.worldGen and U.ok(pb.tps) then
        local lp = U.localPlayers()
        local p1ps = nil
        if lp[1] and U.ok(lp[1].pc) then pcall(function() p1ps = lp[1].pc.PlayerState end) end
        local ppos, pout = readRec(p1ps)
        local tpos = select(1, readRec(pb.tps))
        local res = M.outcome("beat", ppos, pout, tpos, nil)
        if res ~= "void" then
            local okF, Fv = pcall(U.mod, "couchfavours")
            if okF and type(Fv) == "table" then U.try(TAG, Fv.onBet, 1, res == "won", pb.racer, pb.name) end
        end
    end
end

-- a race left before its result: every open bet back to its guest
local function voidAll(why)
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    for _, e in ipairs(list) do
        local p = CR().player(e.ctrlId)
        if p and p.bet then CR().voidBet(e.ctrlId, why) end
    end
    S.targets = {}
end

---------------------------------------------------------------------------------------------------- tick
-- P1's activated native challenges screen (never one of ours), else nil
local function findNative()
    local okA, list = pcall(function() return couch().activeScreens() end)
    if not okA or type(list) ~= "table" then return nil end
    local cp = package.loaded["couchpanel"]
    for _, e in ipairs(list) do
        if e.cls == SCREEN_CLS and not S.own[e.k] and not (cp and cp.isOwn and cp.isOwn(e.k)) and U.alive(e.w) then
            return e.w
        end
    end
    return nil
end

function M.fastTick()
    if opt("CouchBets", true) == false then
        if S.open then close("CouchBets off") end
        return
    end
    local okQ, q = pcall(function() return couch().isQuiet() end)
    if okQ and q == true then return end
    if St.phase ~= "PRERACE" then
        if S.open then close("phase " .. tostring(St.phase)) end
        return
    end
    local now = St.nowMs()
    if now - S.lastScan >= 250 then
        S.lastScan = now
        -- (f) also with no joined guest left (dormant PCs only): P1's screen may still be a dormant PC's
        local okC, on = pcall(function() return couch().active() == true or couch().sharedScreens() == true end)
        if not (okC and on == true) then
            if S.open then close("couch rules off") end
            S.scanNative = nil
            return
        end
        armHooks()
        -- no object-array scan in a race whose side-bet state is not up (CosmeticStateMachineManager, find only;
        -- nil = unknown -> scan)
        if not S.open and U.csmActive(CSM_SIDEBET, true) == false then S.scanNative = nil; return end
        local nat = findNative()
        S.scanNative = nat
        if S.open and (not nat or U.key(nat) ~= S.nativeKey) then close("native screen closed") end
        if nat and not S.open and U.key(nat) ~= S.failKey then open(nat) end
    end
    local nat = S.scanNative
    if nat and U.alive(nat) then U.try(TAG, bridge, nat, now) end
    if S.open and nat and U.alive(nat) then U.try(TAG, dormantOff, nat) end
    if S.open then
        if not U.alive(S.host) then close("split host gone", false); return end
        for _, P in ipairs(S.panels) do U.try(TAG, poll, P, now) end
        U.try(TAG, waitTick, now)
        local rt = rootMod()
        if rt then rt.tick() end
    end
end

function M.isOwn(key) return S.own[key] == true end
function M.isOpen() return S.open == true end
function M.state() return S end

function M.status()
    if not S.open then return "couchbets: closed" end
    local t = {}
    for _, P in ipairs(S.panels) do
        local r = P.rows[P.sel]
        t[#t + 1] = string.format("P%d %s sel %s%s", P.pnum, P.scr and "native" or "list",
            r and (r.name or r.kind) or "?", P.done and " done" or "")
    end
    return string.format("couchbets: open, %d player(s): %s", S.n, table.concat(t, ", "))
end

function M.init()
    St.on("phase", TAG, function(new, old)
        if S.open and new ~= "PRERACE" then close("phase " .. tostring(new)) end
        if new == "POSTRACE" then U.try(TAG, M.settle, "race result") end
    end)
    -- "leaving" before the old world goes: the split is released while alive; a race left without a result refunds
    St.on("leaving", TAG, function()
        close("leaving")
        U.try(TAG, voidAll, "race left before its result")      -- settled bets are already closed at POSTRACE
    end)
    St.on("world", TAG, function()
        close("world", false)
        S.scanNative, S.failKey, S.br = nil, 0, { focusAt = -1e12, down = false, logged = false }
        S.p1Bet = nil                                           -- #110: P1's bet PlayerState is the old world's
    end)
end

return M
