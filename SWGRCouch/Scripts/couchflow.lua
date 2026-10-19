-- couchflow.lua (couch-rewards2 STEP 3, 2026-10-17): A GUEST'S OWN REWARD FLOW IN HIS AREA, WITH THE GAME'S WIDGETS.
-- His stage list is couchrun's p.flow (couchrewards.lua: faults, credits, rounds from HIS result). couchpanel opens the
-- "reward" split as before; a guest with a flow gets this module's views instead of the mirror offer, one at a time in
-- his area (the box is rebuilt per view: no WidgetSwitcher state to keep in sync), driven by his pad on ghost buttons:
--   hub     WBP_PostRace_RewardsHub_Presentation_C - a CONSTRUCTED RewardsCollectionVM (his stages: CollectionType,
--           RewardReason, IsCollected, IsCurrentStage), SetVM + CreateRewardImages + InitIcons + InitButtonText +
--           InitRewardContextText + Anim_In by hand. A on its Hero button = the current stage.
--   credits WBP_PostRace_Rewards_CreditsBreakdown_Presentation_C - its inner layout's AddCreditsReason per row (or the
--           WBP_CreditRewardReason_Presentation_C rows by hand), SetCreditTotal, Anim_In / Anim_ContinueBtn. A = COLLECT
--           (display only: his credits were booked at the race end).
--   faults  WBP_PostRace_Rewards_Faults_Presentation_C - a constructed RewardsCollectionFaultsStageVM (his faulted parts
--           as CampaignItemVMs over a constructed CampaignItem with Data.Affix = the part's config). A = CONTINUE: his
--           queued faults land on his parts (couchrun.flowCollect). The faults list's callouts end in RefreshBuild (P1's
--           build into his panel): his build is put back on the next ticks.
--   round   couchpanel's CHOOSE AN UPGRADE copy (buildNative) on HIS round's rows (couchrun.flowRows), P.flowRound: the
--           copy shows his round's kind only (stat cards stocked when P1's round is of another kind, part cards from a
--           shop VM copy). A pick / SKIP claims (couchrun.claim moves his flow on), then the hub again.
-- Never for a guest: OnActiveInSwitcher (RefreshBuild + ConsumeNextUnseenCreditChange on P1's run + ActivateWidget),
-- the holder, the Cam_Rewards wrapper, ActFinish. Every widget is HitTestInvisible, never activated, owned by the mod.
-- A view that cannot be built natively falls back to a plain text view of the same stage (logged "text view"); a round
-- that cannot be built natively falls back to couchpanel's list. Every stage collected = his area waits for P1.
local U = require("util")
local St = require("state")
local cfg = require("config")

local M = {}
local TAG = "couchflow"

local HUB = "/Game/Griffin/UI/Screens/PostRace/WBP_PostRace_RewardsHub_Presentation.WBP_PostRace_RewardsHub_Presentation_C"
local CREDITS = "/Game/Griffin/UI/Screens/PostRace/WBP_PostRace_Rewards_CreditsBreakdown_Presentation.WBP_PostRace_Rewards_CreditsBreakdown_Presentation_C"
local FAULTS = "/Game/Griffin/UI/Screens/PostRace/WBP_PostRace_Rewards_Faults_Presentation.WBP_PostRace_Rewards_Faults_Presentation_C"
local REASON = "/Game/Griffin/UI/Widgets/PostRace/WBP_CreditRewardReason_Presentation.WBP_CreditRewardReason_Presentation_C"
local VM_HUB = "/Script/Griffin.RewardsCollectionVM"
local VM_STAGE = "/Script/Griffin.RewardsCollectionStageVM"
local VM_FAULTS = "/Script/Griffin.RewardsCollectionFaultsStageVM"
local VM_ITEM = "/Script/Griffin.CampaignItemVM"
local ITEM = "/Script/Griffin.CampaignItem"

local function CR() return U.mod("couchrun") end
local function CP() return package.loaded["couchpanel"] end
local function kit() local cp = CP(); return cp and cp.flowKit or nil end
local function RW() local ok, m = pcall(require, "couchrewards"); return ok and m or nil end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local PD = nil
pcall(function() PD = require("perkdata") end)

M.stats = { native = {}, text = {} }

local function stageName(t)
    return ({ [1] = "CREDITS", [2] = "UPGRADES", [3] = "ABILITIES", [4] = "MODIFIERS", [5] = "PARTS", [6] = "FAULTS" })[t]
        or ("STAGE " .. tostring(t))
end
M.stageName = stageName

---------------------------------------------------------------------------------------------------- the area
-- drop the current view's widgets (removed from the host canvas; never touched again)
local function clear(P)
    for _, w in ipairs({ P.box, P.stripPaper }) do
        if U.alive(w) then pcall(function() w:RemoveFromParent() end) end
    end
    P.box, P.stripPaper, P.nv, P.btns, P.focusInit = nil, nil, nil, nil, nil
end

-- the area frame of couchpanel's native views: strip paper, ScaleToFit 3840x2160 -> Overlay[paper, SizeBox 3840x1920,
-- canvas]. -> ov, inner, cv
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
    local inner = K.mk(K.SIZEB, H.tree)
    inner:SetWidthOverride(3840); inner:SetHeightOverride(1920)
    K.overlayAdd(ov, inner, 2, 2)
    local cv = K.mk(K.CANVAS, H.tree)
    return ov, inner, cv
end

-- his marks (P-badge, credits, the wait line) + one ghost button; nv.lay = the view's root widget
local function marks(H, P, ov, cv, root)
    local K = kit()
    K.overlayAdd(ov, cv, 0, 0)
    local W = P.nv
    W.lay = root
    W.badge = K.solid(H.tree, K.colours.AMBER); K.place(cv, W.badge, 120, 40, 150, 104, 20)
    W.badgeT = K.text(H.tree, 64, K.colours.INKD); K.place(cv, W.badgeT, 142, 44, nil, nil, 21)
    W.credits = K.text(H.tree, 48, K.colours.INKD); K.place(cv, W.credits, 300, 64, nil, nil, 21)
    W.wait = K.text(H.tree, 96, K.colours.INKD); K.place(cv, W.wait, 900, 1960, nil, nil, 22)
    P.btns = { K.ghostButton(H.tree, cv, 40, 2040, 120, 100) }
    W.nCards, W.hasSkip, W.cards, W.animated, W.items = 0, false, {}, {}, {}
    if U.ok(root) then W.chip = K.headerChip(root, P) end
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

-- an object array grown one past its end (the proven UE4SS TArray write); raises when it did not grow
local function append(arr, v, what)
    local n = U.arrayCount(arr)
    local ok = pcall(function() arr[n + 1] = v end)
    if not ok or U.arrayCount(arr) ~= n + 1 then error(what .. " did not grow") end
end

-- the build panel inside the view = his build (initBuild), re-applied after the view's own refreshes
local function build(P, root)
    local K = kit()
    local okB, errB = pcall(K.initBuild, P, root)
    if not okB then
        U.warn(TAG, "P%s: build panel of his %s view failed (%s); panel hidden", tostring(P.pnum), tostring(P.flowView),
            tostring(errB))
        pcall(function() root.WBP_CondensedBuildInfo_Presentation:SetVisibility(K.VIS.Hidden) end)
        P.nv.bvm, P.nv.panel = nil, nil
    end
    local now = St.nowMs()
    P.paintAt = { now + 60, now + 400, now + 1200, now + 2500 }
    if P.nv then P.nv.root = root end
end

---------------------------------------------------------------------------------------------------- native views
local function hubVM(outer, flow, cur)
    local vm = construct(VM_HUB, outer)
    for i, st in ipairs(flow.stages) do
        local s = construct(st.type == 6 and VM_FAULTS or VM_STAGE, vm)
        s.CollectionType = st.type
        pcall(function() s.RewardReason = U.ftext(st.reason or stageName(st.type)) end)
        s.IsCollected = st.collected == true
        s.IsCurrentStage = (i == cur)
        append(vm.CollectionStages, s, "hub stages")
    end
    vm.CurrentRewardStage = math.max(0, (cur or (#flow.stages + 1)) - 1)
    vm.TotalRewardStages = #flow.stages
    return vm
end

-- #47 (tester #1 shot 43: P2's done panel showed P1's speed 322, his 312-316): the build panel's own RefreshBuild
-- (decoded: VehicleBuildVM = GetVehicleBuildVM() = P1's build, then its Init* + speed) runs again from the views'
-- graphs (hub Continue anim, faults callouts) after the paintAt re-applies are over. Seen = the panel holds another VM
-- than his copy: his copy is put back and his build written again (initBuild: his class, speed, parts, bars).
function M.keepBuild(P, now)
    local nv = P and P.nv
    if not (nv and U.ok(nv.bvm) and U.alive(nv.panel) and U.alive(nv.root)) then return end
    if now < (nv.buildAt or 0) then return end
    nv.buildAt = now + 250
    local cur = nil
    pcall(function() cur = nv.panel.VehicleBuildVM end)
    if U.ok(cur) and U.key(cur) == U.key(nv.bvm) then return end
    nv.rebuilt = (nv.rebuilt or 0) + 1
    if nv.rebuilt <= 3 then
        U.log(TAG, "P%s's %s view: the build panel was refreshed with P1's build (RefreshBuild): his build again (%d)",
            tostring(P.pnum), tostring(P.flowView), nv.rebuilt)
    end
    -- his own copy back first: the VM RefreshBuild put there may be P1's shared one (never rewritten for a guest)
    local mine = nv.bvm
    pcall(function() nv.panel.VehicleBuildVM = mine end)
    pcall(function() nv.panel.LV_Stats:BP_SetListItems(mine.StatBars) end)   -- RefreshBuild listed P1's bars
    build(P, nv.root)
end

-- #47 / #53: his hub without the native "NO REWARDS" text while he has stages (see nativeHub); couchpanel's tick calls
-- it every 250 ms while the hub view is up (the hub's own graph may show the text again after an anim / a refresh)
function M.keepHub(P, now, force)
    local nv = P and P.nv
    if not (nv and nv.view == "hub" and (nv.stages or 0) > 0 and U.alive(nv.hub)) then return end
    if not force and now < (nv.keepAt or 0) then return end
    nv.keepAt = now + 250
    local hub = nv.hub
    local vis = nil
    pcall(function() vis = hub.Txt_NoRewards:GetVisibility() end)
    if vis ~= kit().VIS.Collapsed then
        pcall(function() hub.Txt_NoRewards:SetVisibility(kit().VIS.Collapsed) end)
        pcall(function() hub.HB_RewardRoundIcons:SetVisibility(kit().VIS.SelfHitTestInvisible) end)
        if not nv.noRewLogged then
            nv.noRewLogged = true
            U.log(TAG, "P%s's hub: the native NO REWARDS text collapsed (%d stage(s) of his)", tostring(P.pnum), nv.stages)
        end
    end
end

local function nativeHub(H, P, flow, cur)
    local ov, inner, cv = frame(H, P)
    local hub = newWidget(P, HUB)
    inner:AddChild(hub)
    pcall(function() hub:SetVisibility(kit().VIS.HitTestInvisible) end)
    P.nv = { view = "hub", hub = hub }
    local vm = hubVM(hub, flow, cur)
    P.nv.vm = vm
    hub:SetVM(vm)
    for _, f in ipairs({ "CreateRewardImages", "InitIcons", "InitButtonText", "InitRewardContextText" }) do
        local ok, err = pcall(function() hub[f](hub) end)
        if not ok then U.dbg(TAG, "P%s hub %s: %s", tostring(P.pnum), f, tostring(err)) end
    end
    U.playAnim(hub, "Anim_In")
    marks(H, P, ov, cv, hub)
    build(P, hub)
    kit().ownInside(hub)
    -- #47 / #53 (overnight 2026-10-18, t3-fieldtests/28 + tester #1 shots 22/24): the hub's own init (ubergraph @519,
    -- decoded) shows Txt_NoRewards and collapses HB_RewardRoundIcons when its VM's HasCollectionStages() is false - it
    -- ran at Construct, before SetVM, so "NO REWARDS" sat over his reward cards (also after he collected them). His
    -- stages are the flow's: when he has any, the native empty-state text is collapsed and the icons row shown, now
    -- and while the view is up (M.keepHub from couchpanel's tick: the anim / a late init may run the graph again).
    P.nv.stages = #flow.stages
    M.keepHub(P, St.nowMs(), true)
end

-- one CreditChangeDisplayDetails row in the layout (AddCreditsReason with a Lua struct, else the row widget by hand)
local function creditRow(P, lay, r)
    local ok = pcall(function()
        lay:AddCreditsReason({ Delta = r.delta, Reason = U.ftext(r.reason), Contributions = {}, Count = 1, bSeen = true })
    end)
    if ok then return "struct" end
    local w = newWidget(P, REASON)
    pcall(function() w.Reason = U.ftext(r.reason) end)
    pcall(function() w.Value = U.ftext(kit().groupDigits(r.delta)) end)
    lay.VB_CreditReasons:AddChild(w)
    return "by hand"
end

local function nativeCredits(H, P, st)
    local ov, inner, cv = frame(H, P)
    local cb = newWidget(P, CREDITS)
    inner:AddChild(cb)
    pcall(function() cb:SetVisibility(kit().VIS.HitTestInvisible) end)
    P.nv = { view = "credits" }
    local lay = cb.WBP_CreditsBreakdown_Layout_Presentation
    if not U.ok(lay) then error("no credits layout") end
    local how = {}
    for _, r in ipairs(st.rows or {}) do how[#how + 1] = creditRow(P, lay, r) end
    pcall(function() lay:SetCreditTotal(math.floor(tonumber(st.total) or 0)) end)
    U.playAnim(cb, "Anim_In")
    pcall(function() cb:PlayContinueBtnAnim() end)
    marks(H, P, ov, cv, cb)
    build(P, cb)
    kit().ownInside(cb)
    P.nv.rowsHow = table.concat(how, ",")
end

-- a faulted part as the faults list's CampaignItemVM (ItemType 4 over a constructed CampaignItem with its config)
-- AUTO-142 (live 2026-10-18 18:53:59, both of P2's faulted parts): the field writes item.Data.ItemType / .Affix did
-- not stick on the constructed CampaignItem ("CampaignItem.Data.Affix not writable" -> the text view). The native list
-- reads the card from its CampaignItemVM only (WBP_Item_Btn: ItemVM fields + GetItemType); the Item's config
-- (Data.Affix, Item+0x68) is read by ONE native: VehicleBuildVM:FindAffixVmFromItem (exec 0x1471647d6 -> 0x1471648ca,
-- static CL381121) from the list's callouts, a pointer compare against the build's affix configs (null Item = null
-- result, no dereference of the config). So: the in-place writes, else ONE whole-struct write of a Lua table (UE4SS
-- convert_lua_table_to_struct, missing fields keep their value), each read back; when neither sticks the card is
-- shown without its config (no callout on his panel: nothing to match) instead of dropping the native view.
local function writeAffixData(item, cfgObj)
    local function stuck()
        local back = nil
        pcall(function() back = item.Data.Affix end)
        return U.same(back, cfgObj)
    end
    local errs = {}
    local okT, eT = pcall(function() item.Data.ItemType = 4 end)
    local okA, eA = pcall(function() item.Data.Affix = cfgObj end)
    if okT and okA and stuck() then return "in place" end
    errs[#errs + 1] = okA and (okT and "in place: read back differs" or ("ItemType: " .. tostring(eT)))
        or ("in place: " .. tostring(eA))
    local okW, eW = pcall(function() item.Data = { ItemType = 4, Affix = cfgObj } end)
    if okW and stuck() then return "struct table" end
    errs[#errs + 1] = okW and "struct table: read back differs" or ("struct table: " .. tostring(eW))
    return nil, table.concat(errs, "; ")
end
M._writeAffixData = writeAffixData

local function faultItem(vm, part, fault)
    local d = PD and PD.PARTS and PD.PARTS[part]
    local fd = PD and PD.PARTS and PD.PARTS[fault]
    if not d then error("unknown part " .. tostring(part)) end
    local cfgObj = U.obj(d.path)
    if not U.ok(cfgObj) then error(tostring(part) .. " config not loaded") end
    local item = construct(ITEM, vm)
    local how, why = writeAffixData(item, cfgObj)
    local ivm = construct(VM_ITEM, vm)
    ivm.Item = item
    pcall(function() ivm.ItemType = 4 end)
    pcall(function() ivm.PlayerFacingName = U.ftext(d.name or part) end)
    pcall(function() ivm.Description = U.ftext(d.desc or "") end)
    pcall(function() ivm.Quality = math.max(0, math.min(3, tonumber(d.rarity) or 0)) end)
    pcall(function() ivm.AffixStatus = 2 end)
    kit().setEffect(ivm, "FaultyEffect", fd and fd.name or tostring(fault), fd and (fd.desc or "") or "", 4)
    return ivm, cfgObj, how, why
end

local function nativeFaults(H, P, st)
    local ov, inner, cv = frame(H, P)
    local fs = newWidget(P, FAULTS)
    inner:AddChild(fs)
    pcall(function() fs:SetVisibility(kit().VIS.HitTestInvisible) end)
    P.nv = { view = "faults" }
    local vm = construct(VM_FAULTS, fs)
    P.nv.fvm = vm
    vm.CollectionType = 6
    pcall(function() vm.RewardReason = U.ftext(st.reason or "Critical Malfunction Error") end)
    local n = 0
    P.nv.art, P.nv.fs = {}, fs
    for _, f in ipairs(st.faults or {}) do
        local okI, ivm, cfgObj, how, why = pcall(faultItem, vm, f.part, f.fault)
        if okI then
            append(vm.FaultyAffixes, ivm, "faulty affixes")
            local d = PD and PD.PARTS and PD.PARTS[f.part]
            if d and (d.large or d.icon) then P.nv.art[U.key(ivm)] = { part = f.part, rel = d.large or d.icon } end
            pcall(function() append(vm.FaultyAffixConfigs, cfgObj, "fault configs") end)
            n = n + 1
            if how then
                U.dbg(TAG, "P%s faults view: %s card, part config written (%s)", tostring(P.pnum), tostring(f.part), how)
            else
                U.logOnce("couchflow.faultcfg." .. tostring(f.part), TAG, "P%s faults view: %s card shown without its part config (%s): "
                    .. "no callout on his panel", tostring(P.pnum), tostring(f.part), tostring(why))
            end
        else
            U.warn(TAG, "P%s faults view: %s not shown (%s)", tostring(P.pnum), tostring(f.part), tostring(ivm))
        end
    end
    if n == 0 then error("no faulted part could be shown") end
    fs:SetVM(vm)
    U.playAnim(fs, "Anim_In")
    pcall(function() fs:PlayContinueBtnAnim() end)
    marks(H, P, ov, cv, fs)
    build(P, fs)                     -- the callouts end in RefreshBuild (P1's build): his build again on paintAt
    kit().ownInside(fs)
    U.try(TAG, M.keepFaults, P, St.nowMs(), true)
end

-- couch-fix61 (AUTO-150a, live round 6 08:54:10, shot 105413-r6-post1-p2-2): the card's art box of P2's native FAULTS
-- stage was empty grey. Decoded WBP_Item_Btn RefreshIcon: Img_Thumbnail_Item:SetBrushFromSoftTexture(ItemVM.LargeIcon)
-- when that SOFT reference is valid, else nothing (shipping build). The mod's CampaignItemVM is built by hand and a soft
-- property is never written from Lua (the FSoftObjectPath crash family, couch.lua AUTO-135), so the card's image is set
-- on the entry widget itself: the part's large affix icon (perkdata, the same texture the game's own card shows),
-- loaded by path, SetBrushFromTexture on its Img_Thumbnail_Item. The list makes its entries after SetVM (and may make
-- them again): couchpanel's tick re-checks every 250 ms while the view is up; RefreshIcon never clears it (no LargeIcon).
function M.keepFaults(P, now, force)
    local nv = P and P.nv
    if not (nv and nv.view == "faults" and nv.art and next(nv.art) and U.alive(nv.fs)) then return end
    if not force and now < (nv.artAt or 0) then return end
    nv.artAt = now + 250
    nv.artDone = nv.artDone or {}
    local ents = {}
    pcall(function() ents = U.arrayToTable(nv.fs.TV_List_Items:GetDisplayedEntryWidgets()) end)
    for _, w in ipairs(ents) do
        if U.ok(w) and not nv.artDone[U.key(w)] then
            local a = nil
            pcall(function() a = nv.art[U.key(w.ItemVM)] end)
            local img = nil
            if a then pcall(function() img = w.Img_Thumbnail_Item end) end
            if a and U.ok(img) then
                local t = kit().texOf(a.rel)
                local ok = t ~= nil and pcall(function() img:SetBrushFromTexture(t, true) end)
                nv.artDone[U.key(w)] = true
                U.log(TAG, "P%s faults view: %s card art %s (V-CF-142)", tostring(P.pnum), tostring(a.part),
                    ok and ("set from " .. tostring(a.rel)) or ("not loaded: " .. tostring(a.rel)))
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- text views
-- the fallback: the stage as plain text on the paper (title, rows, CONTINUE)
local function textView(H, P, view, flow, cur, st)
    local K = kit()
    local ov, inner, cv = frame(H, P)
    P.nv = { view = view, text = true }
    local lines = {}
    if view == "hub" then
        lines[1] = "REWARDS"
        for i, s in ipairs(flow.stages) do
            lines[#lines + 1] = string.format("%s %s  -  %s", s.collected and "[x]" or (i == cur and ">" or "[ ]"),
                stageName(s.type), tostring(s.reason or ""))
        end
        lines[#lines + 1] = cur and ("A: " .. stageName(flow.stages[cur].type)) or "ALL COLLECTED"
    elseif view == "credits" then
        lines[1] = "CREDITS BREAKDOWN"
        for _, r in ipairs(st.rows or {}) do
            lines[#lines + 1] = string.format("%s   %s%s CR", tostring(r.reason), r.delta >= 0 and "+" or "", K.groupDigits(r.delta))
        end
        lines[#lines + 1] = string.format("TOTAL  %s CR", K.groupDigits(st.total or 0))
        lines[#lines + 1] = "A: COLLECT CREDITS"
    elseif view == "faults" then
        lines[1] = "CRITICAL MALFUNCTION ERROR"
        for _, f in ipairs(st.faults or {}) do
            local d = PD and PD.PARTS
            lines[#lines + 1] = string.format("%s  <-  %s", tostring(d and d[f.part] and d[f.part].name or f.part),
                tostring(d and d[f.fault] and d[f.fault].name or f.fault))
        end
        lines[#lines + 1] = "A: CONTINUE"
    end
    for i, l in ipairs(lines) do
        local t = K.text(H.tree, i == 1 and 120 or 72, K.colours.INKD)
        K.place(cv, t, 300, 220 + (i - 1) * (i == 1 and 160 or 110), nil, nil, 21)
        K.setText(t, l)
    end
    marks(H, P, ov, cv, nil)
end

---------------------------------------------------------------------------------------------------- views
local function stats(view, native) local t = native and M.stats.native or M.stats.text; t[view] = (t[view] or 0) + 1 end

-- show his flow's view: the hub (view nil), or a stage
function M.show(P, view)
    local H = P.H
    local flow, cur = CR().flow(P.ctrlId)
    if not flow then error("no flow") end
    view = view or "hub"
    local st = cur and flow.stages[cur] or nil
    if view ~= "hub" and not st then view = "hub" end
    clear(P)
    P.flowView, P.flowIdx = view, cur
    if view == "round" then
        local rows = CR().flowRows(P.ctrlId, cur)
        if not rows or #rows == 0 then error("his round has no rows") end
        P.rows, P.sel, P.flowRound = rows, 1, st.round
        P.prev = { a = true, b = true }               -- the A that opened the round is not a pick
        local okN, err = pcall(kit().buildNative, H, P)
        if okN then
            P.view = "native"
            stats("round", true)
        else
            U.warn(TAG, "P%s native %s round failed (%s): his list instead", tostring(P.pnum), tostring(st.round.kind),
                tostring(err))
            clear(P)
            P.rows = rows
            P.view = "list"
            local okL, errL = pcall(kit().buildList, H, P)
            if not okL then U.warn(TAG, "P%s list panel failed: %s", tostring(P.pnum), tostring(errL)); P.broken = true end
            stats("round", false)
        end
        P.flowRound = nil
        return
    end
    P.rows, P.sel = { { rkind = "flow", id = view, name = view } }, 1
    P.prev = { a = true, b = true }
    local fn = (view == "hub" and function() nativeHub(H, P, flow, cur) end)
        or (view == "credits" and function() nativeCredits(H, P, st) end)
        or (view == "faults" and function() nativeFaults(H, P, st) end)
    local okN, err = pcall(fn)
    if okN then
        P.view = "native"
        stats(view, true)
        U.log(TAG, "P%s's %s (native)%s", tostring(P.pnum), view == "hub" and "reward hub" or (stageName(st.type) .. " stage"),
            view == "credits" and (" rows " .. tostring(P.nv and P.nv.rowsHow)) or "")
    else
        U.warn(TAG, "P%s native %s view failed (%s): text view instead", tostring(P.pnum), view, tostring(err))
        clear(P)
        local okT, errT = pcall(textView, H, P, view, flow, cur, st)
        if not okT then U.warn(TAG, "P%s text view failed: %s", tostring(P.pnum), tostring(errT)); P.broken = true end
        P.view = "native"
        stats(view, false)
    end
    if view == "hub" and not cur then P.done = true end      -- every stage collected: waiting for P1
end

-- couchpanel.open: his area for a guest with a flow
function M.build(H, P)
    if opt("CouchRewardFlow", true) == false then error("CouchRewardFlow off") end
    P.H = H
    P.gpc = U.ok(P.pc) and P.pc or U.p1()
    P.flowMode = true
    pcall(function() CR().flowRefresh(P.ctrlId) end)      -- his challenge (settled after the race end) in his credits
    local flow, cur = CR().flow(P.ctrlId)
    if not flow then error("no flow") end
    local t = {}
    for i, s in ipairs(flow.stages) do t[i] = stageName(s.type) .. (s.collected and "(done)" or "") end
    U.log(TAG, "P%s's own reward flow: %s (stage %s)", tostring(P.pnum), table.concat(t, " -> "), tostring(cur or "-"))
    M.show(P, "hub")
end

-- his A on a hub / credits / faults view (couchpanel.act)
function M.act(P)
    local flow, cur = CR().flow(P.ctrlId)
    -- #83 (live 2026-10-18 08:48): his CONTINUE on his finished hub did nothing ("REWARDS COLLECTED - WAITING FOR P1"
    -- stayed up while P1 was already on the run map): it closes his own area now (couchpanel.closeOwn)
    if P.done then
        if flow and not cur and P.flowView == "hub" then P.closeOwn = true end
        return
    end
    if not flow then return end
    local st = cur and flow.stages[cur] or nil
    if P.flowView == "hub" then
        if not st then P.done = true; return end
        local Rm = RW()
        local view = (st.type == 1 and "credits") or (st.type == 6 and "faults") or "round"
        if view ~= "round" and Rm then
            -- the hub's own advance look on his card (VM-local, the native CollectCurrentStage is after the stage)
            if P.nv and U.alive(P.nv.lay) then U.playAnim(P.nv.lay, "Anim_In_Continue") end
        end
        U.try(TAG, M.show, P, view)
        return
    end
    if P.flowView == "credits" or P.flowView == "faults" then
        -- FINDING #42 (live crash 2026-10-17 22:07:44, SWGR-Win64-Shipping.exe+0x9338e7): this used to play w.Anim_Out on
        -- the view here. CREDITS BREAKDOWN and FAULTS have no Anim_Out (decoded: Anim_In, Anim_ContinueBtn): UE4SS handed
        -- out its missing-member placeholder, PlayAnimation read it as a UWidgetAnimation* and the game crashed. The view
        -- is removed on this same call (M.show -> clear): no out animation, every other one through U.playAnim.
        CR().flowCollect(P.ctrlId, P.flowIdx)
        if P.flowView == "faults" then
            local pp = CR().player(P.ctrlId)
            if pp and pp.lo then P.lo = pp.lo end
        end
        U.try(TAG, M.show, P, "hub")
    end
end

-- after his pick / SKIP of a round (couchpanel.act claimed it): the hub again (or done)
function M.afterClaim(P)
    local pp = CR().player(P.ctrlId)
    if pp and pp.lo then P.lo = pp.lo end
    P.done = false
    local now = St.nowMs()
    P.flowBackAt = now + 900                                   -- his card's ActionSucceeded plays first
end

-- couchpanel.panelTick: a pending switch back to the hub
function M.tick(P, now)
    if P.flowBackAt and now >= P.flowBackAt then
        P.flowBackAt = nil
        U.try(TAG, M.show, P, "hub")
        return true
    end
    return false
end

function M.status()
    local function c(t) local s = {}; for k, v in pairs(t) do s[#s + 1] = k .. "=" .. v end; return table.concat(s, " ") end
    return "couchflow: native " .. c(M.stats.native) .. " / text " .. c(M.stats.text)
end
return M
