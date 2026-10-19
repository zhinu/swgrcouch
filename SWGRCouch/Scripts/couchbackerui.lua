-- couchbackerui.lua (couch-fix21, #90 / #2 / #78): EVERY GUEST'S OWN BACKER MOMENTS, WITH THE GAME'S OWN WIDGETS, IN HIS
-- AREA OF THE COUCH SPLIT (couchpanel.lua opens the split; P1's native screen goes into P1's area, couchroot.lua).
--   choose   (couchpanel kind "backer": P1's WBP_SponsorSelect_C up = CHOOSE A BACKER CONTRACT, the run's first pick or a
--            mid-run offer) a standalone WBP_SponsorSelect_Content_C (the screen's own content: header, the three
--            WBP_SponsorChoice_Btn_C cards) owned by his PC, NEVER activated: its BP_OnActivated -> InitContent(false)
--            would build P1's SponsorChoiceVM (ViewModelSubsystem:InitSponsorChoiceVM) and a click runs OnSponsorChosen
--            = PaddockGameState:ChooseSponsor + the CSM's ContinueToNextState on P1's run (decoded,
--            work/decoded-backer21). Its PreConstruct only runs InitContent(true) (the design-time path: the Show*
--            flags, no VM). Each card gets SetSponsor(a FRESH RolledSponsorOptionVM, outer = his copy) with the fields of
--            P1's offer (the same three backers and contracts: the run rolled them) and bIsCurrentContract = HIS current
--            contract. His pad drives invisible buttons (Left / Right); the focused card shows its own focus look
--            (BP_OnFocusReceived: Anim_Hover + its frame), A = HIS contract (couchbacker.choose; the starting credits of
--            the offer when the screen shows them = a run's first pick), his card selected the way the native click
--            does it (UpdateSelectedState + the others dimmed). A locked backer = "LOCKED".
--   checkin  (kind "checkin": P1's WBP_SponsorCheckIn_C up = the planet's check-in, the contract completion screen) a
--            standalone WBP_SponsorCheckIn_C whose SponsorCheckinVM is a FRESH SponsorCheckinVM with HIS values
--            (couchbacker.checkinData: his backer, his contract, his progress / target, his finish places, his moods),
--            set before its Construct's 1.4 s delay reads it for the progress bar; the texts its Construct wrote from
--            P1's VM are rewritten (planet, backer, contract, value, form, ratings). A = his bonus page:
--   bonus    a standalone WBP_SponsorCheckinBonus_C: SetSponsorCheckinVM(his VM) (his check-in credits, his backer's name)
--            + WBP_Rating_Overall:SetRating(his overall mood). A = COLLECT (couchbacker.collect: his credits; the run's
--            last check-in rates his run and shares his backer's favour). His Hero buttons are never clicked (their
--            ContinueToNextState / CompleteSponsorCheckin are P1's flow).
-- A view that cannot be built natively falls back to a text view (his choice / his numbers, logged).
local U = require("util")
local St = require("state")
local cfg = require("config")

local M = {}
local TAG = "couchbackerui"

M.CONTENT = "/Game/Griffin/UI/Screens/Paddock/WBP_SponsorSelect_Content.WBP_SponsorSelect_Content_C"
M.CHECKIN = "/Game/Griffin/UI/Screens/Paddock/WBP_SponsorCheckIn.WBP_SponsorCheckIn_C"
M.BONUS = "/Game/Griffin/UI/Screens/Paddock/WBP_SponsorCheckinBonus.WBP_SponsorCheckinBonus_C"
M.OPTION_VM = "/Script/Griffin.RolledSponsorOptionVM"
M.CHECKIN_VM = "/Script/Griffin.SponsorCheckinVM"
M.SELECT_MATCH = { "WBP_SponsorSelect_C", "WBP_Paddock_SponsorConfirmation_C" }
M.CHECKIN_MATCH = { "WBP_SponsorCheckIn_C", "WBP_SponsorCheckinBonus_C" }
local BUTTONS = { "SponsorButtonA", "SponsorButtonB", "SponsorButtonC" }
local DIM = { R = 0.025187, G = 0.07036, B = 0.090842, A = 1 }        -- the content's own dim of an unpicked card
local LIT = { R = 1, G = 1, B = 1, A = 1 }
local OPTION_FIELDS = { "Sponsor", "contract", "StartingCredits", "CreditsPerAction", "bIsSponsorLocked",
                        "bCanFavourBeUnlocked", "bIsNewTarget", "TargetQuantity", "TargetUnits", "RunsRemainingToUnlock" }

local function BK() return U.mod("couchbacker") end
local function CP() return package.loaded["couchpanel"] end
local function kit() local cp = CP(); return cp and cp.flowKit or nil end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

M.stats = { native = {}, text = {} }
local function stat(view, native) local t = native and M.stats.native or M.stats.text; t[view] = (t[view] or 0) + 1 end

---------------------------------------------------------------------------------------------------- P1's screens
-- the content of P1's backer screen (WBP_SponsorSelect_C -> WBP_SponsorSelect_Content), or the content itself.
-- couch-fix42 (live 2026-10-18 12:13, A4 FAIL): couch.activeScreens lists ONLY WBP_SponsorSelect_Content_C (the
-- activated FuseActivatableWidget; its WBP_SponsorSelectBase_C screen is not activated) and couchpanel's findNative
-- pattern "WBP_SponsorSelect_C" is a plain find - a prefix of "WBP_SponsorSelect_Content_C" - so the native handed here
-- was the content, which has no WBP_SponsorSelect_Content member (jmap): offers() = nil, no guest split ever opened.
M.CONTENT_CLS = "WBP_SponsorSelect_Content_C"
local function contentOf(native)
    if not U.alive(native) then return nil end
    if U.className(native) == M.CONTENT_CLS then return native end
    local c = nil
    pcall(function() c = native.WBP_SponsorSelect_Content end)
    return U.alive(c) and c or nil
end
M._contentOf = contentOf

-- the offers of P1's backer screen -> { {sponsor, contract, sponsorObj, contractObj, cpa, start, locked, vm} }, showStart
-- | nil (not filled yet: the screen's VM comes with its activation)
function M.offers(native)
    local content = contentOf(native)
    if not content then return nil end
    local list = {}
    local vms = {}
    pcall(function() vms = U.arrayToTable(content.SponsorChoiceVM.Sponsors) end)
    for i, vm in ipairs(vms) do
        if U.ok(vm) then
            local o = { i = i, vm = vm }
            pcall(function() o.sponsorObj = vm.Sponsor end)
            pcall(function() o.contractObj = vm.contract end)
            pcall(function() o.cpa = tonumber(vm.CreditsPerAction) end)
            pcall(function() o.start = tonumber(vm.StartingCredits) end)
            pcall(function() o.locked = vm.bIsSponsorLocked == true end)
            o.sponsor, o.contract = U.objName(o.sponsorObj), U.objName(o.contractObj)
            if o.sponsor ~= "" and o.contract ~= "" then list[#list + 1] = o end
        end
    end
    if #list == 0 then
        -- the cards themselves (SetSponsor wrote Sponsor / Contract on them)
        for i, name in ipairs(BUTTONS) do
            local b = nil
            pcall(function() b = content[name] end)
            if U.alive(b) then
                local o = { i = i, btn = b }
                pcall(function() o.sponsorObj = b.Sponsor end)
                pcall(function() o.contractObj = b.Contract end)
                pcall(function() o.locked = b:GetLocked() == true end)
                o.sponsor, o.contract = U.objName(o.sponsorObj), U.objName(o.contractObj)
                if o.sponsor ~= "" and o.contract ~= "" then list[#list + 1] = o end
            end
        end
    end
    if #list == 0 then return nil end
    local showStart = false
    pcall(function() showStart = content.ShowSponsorCredits == true end)
    return list, showStart
end

-- P1's check-in VM (the run recap flag: the run's last check-in) and its planet name
local function p1Checkin(native)
    local vm = nil
    pcall(function() vm = native.SponsorCheckinVM end)
    if not U.ok(vm) then
        pcall(function() vm = U.giSubsystem("ViewModelSubsystem"):GetSponsorCheckinVM() end)
    end
    return U.ok(vm) and vm or nil
end

---------------------------------------------------------------------------------------------------- the area
local function clear(P)
    for _, w in ipairs({ P.box, P.stripPaper }) do
        if U.alive(w) then pcall(function() w:RemoveFromParent() end) end
    end
    P.box, P.stripPaper, P.nv, P.btns, P.focusInit = nil, nil, nil, nil, nil
end

local function frame(H, P)
    local K = kit()
    if P.region.strip then
        local fullOv = K.mk(K.OVER, H.tree)
        if fullOv then
            K.place(H.cv, fullOv, P.region.x, P.region.y, P.region.w, P.region.h, 0)
            K.paperBackdrop(H, H.tree, fullOv, P.gpc)
            P.stripPaper = fullOv
        end
    end
    local box, sb = K.regionBox(H, P.region, K.VW, K.VH)
    P.box = box
    local ov = K.mk(K.OVER, H.tree)
    if not ov then error("no Overlay") end
    sb:AddChild(ov)
    K.paperBackdrop(H, H.tree, ov, P.gpc)
    local cv = K.mk(K.CANVAS, H.tree)
    return ov, cv
end

-- his marks: the P-badge + credits (top left), the wait line, the chip top right
local function marks(H, P, ov, cv, root)
    local K = kit()
    K.overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.lay = root
    W.badge = K.solid(H.tree, K.colours.AMBER); K.place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = K.text(H.tree, 64, K.colours.INKD); K.place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = K.text(H.tree, 48, K.colours.INKD); K.place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = K.text(H.tree, 84, K.colours.INKD); K.place(cv, W.wait, 900, 1960, nil, nil, 22)
    W.nCards, W.hasSkip, W.cards, W.animated, W.items = W.nCards or 0, false, W.cards or {}, {}, {}
end

local function newWidget(P, path)
    local K = kit()
    local cls = U.class(path)
    if not U.ok(cls) then error(path:match("([%w_]+)$") .. " class not loaded") end
    local w = U.WBL():Create(P.gpc, cls, P.gpc)
    if not U.ok(w) then error("not created") end
    K.own(w)
    pcall(function() w.bAutoActivate = false end)
    return w
end

local function construct(path, outer)
    local cls = U.class(path)
    if not U.ok(cls) then error(path .. " not found") end
    local ok, o = pcall(StaticConstructObject, cls, outer)
    if not (ok and U.ok(o)) then error(path:match("([%w_]+)$") .. " not constructed") end
    return o
end

local function setText(w, s)
    if U.alive(w) then pcall(function() w:SetText(U.ftext(s)) end) end
end

---------------------------------------------------------------------------------------------------- choose
-- a fresh offer VM for his card: P1's offer's fields, HIS current contract
local function optionVM(outer, o, mine)
    local vm = construct(M.OPTION_VM, outer)
    for _, f in ipairs(OPTION_FIELDS) do
        pcall(function() vm[f] = o.vm[f] end)
    end
    pcall(function() vm.bIsCurrentContract = mine ~= nil and mine == o.contract end)
    return vm
end

local function nativeChoose(H, P)
    local K = kit()
    local native = K.native()
    local offers, showStart = M.offers(native)
    if not offers then error("P1's backer screen has no offers") end
    P.offers, P.showStart = offers, showStart
    local ov, cv = frame(H, P)
    local copy = newWidget(P, M.CONTENT)
    K.overlayAdd(ov, copy, 0, 0)
    pcall(function() copy:SetVisibility(K.VIS.HitTestInvisible) end)
    -- the card flags of P1's content (credits shown on a run's first pick), the design-time init only (no VM)
    local p1c = contentOf(native)
    for _, f in ipairs({ "ShowSponsorCredits", "ShowSelectedState", "ShowSponsorCreditsPerAction", "ShowTokensGained" }) do
        pcall(function() copy[f] = p1c[f] end)
    end
    pcall(function() copy.UseCampaignLogic = true end)
    pcall(function() copy:InitContent(true) end)
    local mine = nil
    pcall(function() local p = U.mod("couchrun").player(P.ctrlId); mine = p and p.backer and p.backer.contract end)
    P.nv = { backerView = "choose", cards = {}, nCards = #offers, items = {} }
    local fresh = 0
    for i, o in ipairs(offers) do
        local b = nil
        pcall(function() b = copy[BUTTONS[i]] end)
        if U.alive(b) then
            local vm = nil
            if o.vm then
                local okV, v = pcall(optionVM, copy, o, mine)
                if okV then vm, fresh = v, fresh + 1 else vm = o.vm end
            end
            if vm then pcall(function() b:SetSponsor(vm) end) end
            pcall(function() b:BP_SetIsFocusable(false) end)
            P.nv.cards[i] = b
        end
    end
    marks(H, P, ov, cv, copy)
    P.rows, P.sel = {}, 1
    for i, o in ipairs(offers) do
        P.rows[i] = { rkind = "backer", id = o.contract, name = BK().nameOf(o.sponsor), o = o }
        if mine and o.contract == mine then P.sel = i end
    end
    P.btns = {}
    for i = 1, #offers do P.btns[i] = K.ghostButton(H.tree, cv, 40 + (i - 1) * 130, 2040, 120, 100) end
    K.navCards(P.btns, #offers, false)
    local now = St.nowMs()
    P.paintAt = { now + 40, now + 300, now + 900 }
    local names = {}
    for _, o in ipairs(offers) do names[#names + 1] = BK().nameOf(o.sponsor) .. (o.locked and " (locked)" or "") end
    U.log(TAG, "P%s's CHOOSE A BACKER CONTRACT: the game's content in his area, %d offer(s) (%s), %d fresh offer VM(s)%s",
        tostring(P.pnum), #offers, table.concat(names, ", "), fresh, showStart and ", starting credits shown" or "")
end

-- the card he picked: selected the way the content's own click does it, the others dimmed
local function markPick(P, i)
    local nv = P.nv
    if not (nv and nv.cards) then return end
    for j, b in pairs(nv.cards) do
        if U.alive(b) then
            pcall(function() b:UpdateSelectedState(j == i) end)
            pcall(function() b:SetColorAndOpacity(j == i and LIT or DIM) end)
        end
    end
end

---------------------------------------------------------------------------------------------------- check-in
local function planetNow()
    local planet = 1
    pcall(function() local p = U.mod("couchrun").nodeInfo(); planet = p or 1 end)
    return planet
end

-- his SponsorCheckinVM (fresh, outer = his copy)
local function checkinVM(outer, d, p1vm)
    local vm = construct(M.CHECKIN_VM, outer)
    local sp = U.obj(BK().sponsorPath(d.sponsor))
    local ct = U.obj(BK().contractPath(d.contract))
    if U.ok(sp) then pcall(function() vm.Sponsor = sp end) end
    if U.ok(ct) then pcall(function() vm.contract = ct end) end
    pcall(function() vm.ReviewPlanetName = p1vm.ReviewPlanetName end)
    local units = (d.def and d.def.units) or ""
    vm.ContractScore = d.progress
    vm.ContractTarget = d.target
    pcall(function() vm.FormattedContractScore = U.ftext(tostring(math.floor(d.progress))) end)
    pcall(function() vm.FormattedContractTarget = U.ftext(tostring(math.floor(d.target))) end)
    pcall(function() vm.ContractUnits = U.ftext(units) end)
    vm.FormMood, vm.ContractMood, vm.OverallMood = d.form, d.cmood, d.omood
    vm.CreditsAwarded, vm.KitPointsAwarded = d.cr, d.kp or 0
    -- HIS penalty (his backer's PenaltyFavour after his displeased rating), never P1's
    pcall(function() vm.bWasPlayerPenalised = d.penalty ~= nil end)
    if d.penalty then
        local pf = U.obj(BK().penaltyPath(d.penalty.favour))
        if U.ok(pf) then pcall(function() vm.PenaltyFavour = pf end) end
    end
    -- his finish places (the form row): an int array grown one past its end (couchflow's TArray write)
    local n = 0
    for _, pos in ipairs(d.pos or {}) do
        local ok = pcall(function() vm.FinishPositions[n + 1] = math.floor(pos) end)
        if not ok then break end
        n = n + 1
    end
    return vm, sp, ct
end

local function valueText(d)
    local units = (d.def and d.def.units) or ""
    return string.format("%d/%d%s", math.floor(d.progress), math.floor(d.target), units ~= "" and (" " .. units) or "")
end

local function nativeCheckin(H, P, d)
    local K = kit()
    local ov, cv = frame(H, P)
    local w = newWidget(P, M.CHECKIN)
    K.overlayAdd(ov, w, 0, 0)
    pcall(function() w:SetVisibility(K.VIS.HitTestInvisible) end)
    local vm, sp, ct = checkinVM(w, d, P.p1vm)
    -- before the Construct's 1.4 s delay reads it (the progress bar = his score / target)
    w.SponsorCheckinVM = vm
    pcall(function() w.Txt_SubHead_Planet:SetText(vm.ReviewPlanetName) end)
    if U.ok(sp) then pcall(function() w.Txt_SubHead_Sponsor:SetText(sp.PlayerFacingName) end) end
    if U.ok(ct) then pcall(function() w.Txt_ContractDesc:SetText(ct.SummaryHeading) end)
    else setText(w.Txt_ContractDesc, d.def and d.def.text or d.contract) end
    setText(w.Txt_ContractValue_1, valueText(d))
    pcall(function() w:RefreshRaceForm() end)
    pcall(function() w.WBP_Rating_Form:SetRating(d.form) end)
    pcall(function() w.WBP_Rating_Contract:SetRating(d.cmood) end)
    P.nv = { backerView = "checkin", nCards = 0, cards = {}, vm = vm }
    marks(H, P, ov, cv, w)
    P.btns = { K.ghostButton(H.tree, cv, 40, 2040, 120, 100) }
end

local function nativeBonus(H, P, d)
    local K = kit()
    local ov, cv = frame(H, P)
    local w = newWidget(P, M.BONUS)
    K.overlayAdd(ov, w, 0, 0)
    pcall(function() w:SetVisibility(K.VIS.HitTestInvisible) end)
    local vm = checkinVM(w, d, P.p1vm)
    w:SetSponsorCheckinVM(vm)                       -- his credits, his kit points, his backer, RefreshPenalty (his)
    pcall(function() w.WBP_Rating_Overall:SetRating(d.omood) end)
    if d.penalty then
        -- the penalty text when the favour asset could not be read (RefreshPenalty shows the box from the flag)
        pcall(function() w.Txt_PenaltyName:SetText(U.ftext(d.penalty.text)) end)
    else
        pcall(function() w.B_Penalty:SetVisibility(kit().VIS.Collapsed) end)
        pcall(function() w.VB_Penalty:SetVisibility(kit().VIS.Collapsed) end)
    end
    P.nv = { backerView = "bonus", nCards = 0, cards = {}, vm = vm }
    marks(H, P, ov, cv, w)
    P.btns = { K.ghostButton(H.tree, cv, 40, 2040, 120, 100) }
end

-- the text view of a moment (a native view failed)
local function textView(H, P, view, d)
    local K = kit()
    local ov, cv = frame(H, P)
    P.nv = { backerView = view, nCards = 0, cards = {}, text = true }
    marks(H, P, ov, cv, nil)
    local t1 = K.text(H.tree, 120, K.colours.INKD); K.place(cv, t1, 300, 420, nil, nil, 23)
    local t2 = K.text(H.tree, 72, K.colours.INKD); K.place(cv, t2, 300, 640, nil, nil, 23)
    local t3 = K.text(H.tree, 64, K.colours.INKD); K.place(cv, t3, 300, 820, nil, nil, 23)
    P.nv.t = { t1, t2, t3 }
    local B = BK()
    if view == "choose" then
        setText(t1, "CHOOSE A BACKER CONTRACT")
        local o = P.rows and P.rows[P.sel] and P.rows[P.sel].o
        local def = o and B.contract(o.contract)
        setText(t2, o and string.upper(B.nameOf(o.sponsor)) or "")
        setText(t3, def and def.text or "")
    elseif d then
        setText(t1, view == "bonus" and "BACKER BONUS" or "BACKER CHECK-IN")
        setText(t2, string.upper(B.nameOf(d.sponsor)) .. "  -  " .. tostring(d.def and d.def.text or d.contract))
        setText(t3, view == "bonus" and string.format("%s  +%s CR  +%d KIT%s", B.MOOD_NAME[d.omood] or "?", K.groupDigits(d.cr),
            d.kp or 0, d.penalty and ("  PENALTY: " .. d.penalty.text) or "")
            or string.format("%s   FORM %s  CONTRACT %s", valueText(d), B.MOOD_NAME[d.form] or "?", B.MOOD_NAME[d.cmood] or "?"))
    end
    P.btns = P.btns or {}
    if #P.btns == 0 then
        for i = 1, math.max(1, #(P.rows or {})) do P.btns[i] = K.ghostButton(H.tree, cv, 40 + (i - 1) * 130, 2040, 120, 100) end
        K.navCards(P.btns, #P.btns, false)
    end
end

---------------------------------------------------------------------------------------------------- views
function M.show(P, view)
    local H = P.H
    clear(P)
    P.backerView = view
    local d = nil
    if view ~= "choose" then
        d = BK().checkinData(P.ctrlId, P.pnum, P.planet)
        if not d then error("no backer of his") end
        P.rows, P.sel = { { rkind = "backer", id = view, name = view } }, 1
    end
    P.prev = { a = true, b = true }               -- the A that opened this view is not a press on it
    local fn = (view == "choose" and function() nativeChoose(H, P) end)
        or (view == "checkin" and function() nativeCheckin(H, P, d) end)
        or (view == "bonus" and function() nativeBonus(H, P, d) end)
    local okN, err = pcall(fn)
    if okN then
        P.view = "native"
        stat(view, true)
        U.log(TAG, "P%s's backer %s (native)", tostring(P.pnum), view)
    else
        U.warn(TAG, "P%s native backer %s view failed (%s): text view instead", tostring(P.pnum), view, tostring(err))
        clear(P)
        if view == "choose" and not P.rows then
            local offers = M.offers(kit().native()) or {}
            P.offers, P.rows, P.sel = offers, {}, 1
            for i, o in ipairs(offers) do P.rows[i] = { rkind = "backer", id = o.contract, name = BK().nameOf(o.sponsor), o = o } end
        end
        local okT, errT = pcall(textView, H, P, view, d)
        if not okT then U.warn(TAG, "P%s backer text view failed: %s", tostring(P.pnum), tostring(errT)); P.broken = true end
        P.view = "native"
        stat(view, false)
    end
    if view == "bonus" and d and d.checked then P.done = true end
end

-- couchpanel.open: his area of a backer moment (kind "backer" | "checkin")
function M.build(H, P)
    if opt("CouchBackers", true) == false then error("CouchBackers off") end
    P.H = H
    P.gpc = U.ok(P.pc) and P.pc or U.p1()
    P.backerMode = true
    local kind = CP() and CP().kind and CP().kind() or P.kind
    if P.kind then kind = P.kind end
    if kind == "checkin" then
        P.planet = planetNow()
        P.p1vm = p1Checkin(kit().native())
        local runEnd = false
        pcall(function() runEnd = P.p1vm.bHasRunRecap == true end)
        if not runEnd then pcall(function() runEnd = U.mod("couchrun").activeRun():IsOnFinalPlanet() == true end) end
        P.runEnd = runEnd
        local d = BK().checkinData(P.ctrlId, P.pnum, P.planet)
        if not d then error("no backer of his") end
        U.log(TAG, "P%s's own backer check-in (planet %d%s): %s, %s %s, form %s, contract %s, overall %s: +%d CR +%d kit%s%s",
            tostring(P.pnum), P.planet, runEnd and ", the run's last" or "", BK().nameOf(d.sponsor),
            tostring(d.def and d.def.text or d.contract), valueText(d), BK().MOOD_NAME[d.form], BK().MOOD_NAME[d.cmood],
            BK().MOOD_NAME[d.omood], d.cr, d.kp or 0, d.penalty and (", penalty: " .. d.penalty.text) or "",
            d.checked and " (already collected)" or "")
        M.show(P, d.checked and "bonus" or "checkin")
    else
        M.show(P, "choose")
    end
end

-- his A (couchpanel.act)
function M.act(P)
    if P.done then return end
    local v = P.backerView
    if v == "choose" then
        local it = P.rows and P.rows[P.sel]
        local o = it and it.o
        if not o then return end
        local ok, toast = BK().choose(P.ctrlId, P.pnum, o, P.showStart)
        P.toast, P.toastUntil = toast, St.nowMs() + (ok and 4000 or 2500)
        if ok then
            P.done, P.picked = true, P.sel
            markPick(P, P.sel)
        end
        return
    end
    if v == "checkin" then
        U.try(TAG, M.show, P, "bonus")
        return
    end
    if v == "bonus" then
        local cr, note = BK().collect(P.ctrlId, P.pnum, P.planet, P.runEnd, "his check-in screen")
        P.done = true
        P.toast = (tonumber(cr) or 0) > 0 and string.format("+%s CR", kit().groupDigits(cr)) or "COLLECTED"
        if note then P.toast = P.toast .. "  -  " .. note end
        P.toastUntil = St.nowMs() + 6000
    end
end

-- couchpanel.paint: his cards' focus look (the native one, couchpanel's cardFocus on setSel), his pick kept
function M.paint(P)
    local nv = P.nv
    if not nv or nv.text then return end
    if nv.backerView == "choose" then
        if P.picked then markPick(P, P.picked) end
        if not nv.focusShown and not P.done and nv.cards[P.sel] then
            nv.focusShown = P.sel
            local K = kit()
            if K and K.cardFocus then K.cardFocus(nv.cards[P.sel], true) end
        end
    end
end

-- the split closed before he collected his check-in (P1 travelled on): his reward is booked anyway
function M.autoCollect(P, why)
    if P.done or P.backerView == nil or P.backerView == "choose" then return end
    local cr = BK().collect(P.ctrlId, P.pnum, P.planet, P.runEnd, "area closed (" .. tostring(why) .. ")")
    P.done = true
    U.log(TAG, "P%s's check-in collected as his area closed (%s): +%s CR", tostring(P.pnum), tostring(why), tostring(cr))
end

-- couchpanel's done line
function M.idle(P)
    if P.backerView == "choose" then return "CONTRACT SIGNED - WAITING FOR P1" end
    return "CHECK-IN DONE - WAITING FOR P1"
end

---------------------------------------------------------------------------------------------------- BACKER INFO (#78)
-- couchpanel.fillBacker: the fresh SponsorRunInfoVM of a guest's BACKER INFO page rewritten with HIS backer, contract
-- and progress on this planet (before SetSponsor). -> his backer's name | nil (no backer of his: the team's page)
function M.infoVM(vm, ctrlId, pnum)
    if opt("CouchBackers", true) == false or not U.ok(vm) then return nil end
    local B = BK()
    local b = B.ensure(ctrlId, pnum, "backer info")
    if not b then return nil end
    local sp = U.obj(B.sponsorPath(b.sponsor))
    local ct = U.obj(B.contractPath(b.contract))
    if not (U.ok(sp) and U.ok(ct)) then return nil end
    local planet = planetNow()
    local target = B.liveTarget(b.contract, planet)
    local r = B.planetRec(b, planet, target)
    local def = B.contract(b.contract) or {}
    pcall(function() vm.Sponsor = sp end)
    pcall(function() vm.contract = ct end)
    pcall(function() vm.ContractScore = tonumber(r.progress) or 0 end)
    pcall(function() vm.ContractTarget = tonumber(target) or 0 end)
    pcall(function() vm.FormattedContractScore = U.ftext(tostring(math.floor(tonumber(r.progress) or 0))) end)
    pcall(function() vm.FormattedContractTarget = U.ftext(tostring(math.floor(tonumber(target) or 0))) end)
    pcall(function() vm.ContractUnits = U.ftext(def.units or "") end)
    return B.nameOf(b.sponsor), string.format("%d/%d%s", math.floor(tonumber(r.progress) or 0), math.floor(tonumber(target) or 0),
        (def.units or "") ~= "" and (" " .. def.units) or "")
end

function M.status()
    local function c(t) local s = {}; for k, v in pairs(t) do s[#s + 1] = k .. "=" .. v end; return table.concat(s, " ") end
    return "couchbackerui: native " .. c(M.stats.native) .. " / text " .. c(M.stats.text)
end

return M
