-- garagenative.lua: COUCH CAMPAIGN - a guest's GARAGE TURN in the game's OWN full-screen garage (3D car, every
-- screen of P1's garage). Jules 2026-10-15: "the garage needs to be the same as P1 with 3D models and all".
-- cfg.CouchGarageNative (default true since couch-garage2, 2026-10-16); false = garage.lua's compact panel. A turn that
-- cannot start (no CstSubsystem, slots unreadable, class switch refused...) opens the compact panel instead, and a turn
-- whose garage never came up turns the native garage off for the session (the next GARAGE press is compact).
--
-- Why a turn and not a second screen (docs/dev/guest-garage.md section 1.3): the game's garage screens drive the ONE
-- customisation pawn (BP_CstPawn_C) and both load (VehicleCustomisationPawn:ReloadRecipe) and save
-- (CstCustomisationComponent:SaveCustomisationRecipes) through the FIRST local player's CstSubsystem
-- (VehicleRecipeDatas, two slots per class). So during a guest's turn:
--   1. BACKUP: EVERY slot of P1's CstSubsystem (scalar fields, tags, unit / part names) and P1's displayed class
--      (the component's ActiveRecipe.VehicleArchetype) go to <ModDir>/garage-p1-backup.txt with pending = true BEFORE
--      anything is changed (a crash mid-turn is repaired at the next boot: restore() runs as soon as P1's CstSubsystem
--      exists).
--   2. CLASS: when P1's garage shows another class than the guest's, the pawn is switched to his class the way the
--      game's BPFL_CustomisationFunctionLibrary.SetSelectedVehicleArchetype does it (UpdateUISelection(0, name, arch));
--      read back after the reload, a refused switch = no turn (else his edits would land in P1's class).
--   3. LOAD: both slots of his class get his car (garage.effective -> garage.recipeTable: his model preset's units, his
--      kit parts, his livery tags), the pawn reloads it: the 3D car on screen is HIS.
--   4. PADS (couch.garageHold, EXCLUSIVE): P1's PC listens to the guest's pad id (the screens belong to P1's PC); the
--      guest's PC is parked (P1's pad reaches no player) and P1's Slate focus sits on an invisible sink, put back after
--      every screen activation (couch.garageSinkCheck, every FAST tick).
--   5. OPEN: the garage machine (CSM_VehicleCustomisation_Root) goes to its Active state; a toast names the turn.
--   6. DRIVE (every FAST tick, decoded 2026-10-16 below): his D-pad / A / sticks / RT work natively (Slate focus user 1,
--      Enhanced Input on P1's PC); B and LB / RB are bridged from his raw input when the game did not act on them.
--   7. END (the garage screens are gone): his result is read from the slots (RecipeName = the model's base id, the five
--      tags, his kit parts when they differ from the model preset's) into garage.lua's store (his seat, his class);
--      P1's class comes back on the pawn, every slot that differs from the backup is written back, the pawn reloads,
--      the component saves, every slot is compared with the backup again ("restored exactly" or the differences), the
--      pad ids go back and the backup is marked done.
--   8. ROOT LEFT ON SCREEN (live 2026-10-16 round 3): after the turn the game's root WBP_Paddock_VehicleCust_C (P1's car
--      in the garage) stayed VISIBLE but deactivated over the paddock until another screen opened. Root cause (round 4,
--      section 9): the bridged B on the root never left the garage machine. Since couch-livefix r4 the collapse is a
--      LAST RESORT only: a root still drawn (deactivated) after the verified exit or the exit's fallbacks is collapsed
--      and gets its visibility back the moment the game activates that instance again (P1's own garage later).
--      cfg.CouchGarageHideRoot = false: off.
--   9. EXIT (couch-livefix r4, live round 4: the garage camera stayed on P1's landspeeder, P1 could not walk, B / START
--      dead): his B on the root ENDS the turn; after the restore and the pad ids, the turn leaves the garage the game's
--      own way (the root's OnCancelAction: the machine -> Idle, which restores the camera, the paddock lighting, the
--      interactions and drops IMC_Customisation) and verifies it (section "9. the game's exit" below).
--
-- THE GARAGE SCREENS (decoded 2026-10-16 with cue4cli --script + kismet2txt, docs/dev/guest-garage.md section 8):
--   WBP_Paddock_VehicleCust_C (root, FuseScreenWidget): three hero buttons (Choose Model / Edit Vehicle / Edit Livery,
--     desired focus WBP_Customise_Theme.WBP_Theme_Btn); back = RegisterActionBinding(IA_UI_Cancel) -> OnCancelAction ->
--     ChangeToState("Exiting specific vehicle customisation"). Widget Enhanced Input: IA_Cst_Movement (left stick:
--     MoveInputUpdated), IA_Veh_Camera (right stick: FuseCameraComponent:SetCameraInput), IA_Veh_Throttle (RevEngine).
--   WBP_Paddock_VehicleCustThemeOptions_C / ..LiveryOptions_C / ..PartsOptions_C (children of
--     ..LiveryOptionsBase_Concise_C): a WBP_Tab_List (CommonTabListWidgetBase, LB / RB = its Next / Previous tab
--     input actions) linked to a FuseWidgetSwitcher of WBP_CustomisationOptionView pages (bAutoActivateOnSwitch; a
--     ListView LV_Items of WBP_CustomisationOptionButton_Vehicle entries). Focusing an entry previews it
--     (EquipItem(true) -> UpdateUISelection), A equips it (UpdateUISelection + SaveCustomisationRecipes) or, for an
--     unpurchased option, holds to buy (TryToPurchaseOption, the requires-hold CommonButton). Livery tabs = the
--     LiveryCategories map (template / colours / finish...); Edit Vehicle tabs = the parts (Front, EngineL...).
--     Back = the CommonUI default back (BP_OnHandleBackAction: ends a playing unlock cinematic, else the screen leaves).
--   ..LiveryOptionsBase_C / ..LiveryColour_C / ..LiveryTemplate_C / ..Patina_C: RegisterActionBinding(IA_UI_Cancel) ->
--     OwningStateMachine:BackToPreviousState.
-- Live 2026-10-15: his D-pad / A drove the screens through Slate (user 1 holds the focus the mod gave it); his B did
-- NOT reach the screens' CommonUI back (the bridge did it). LB / RB are the same kind of CommonUI action: bridged too.
-- A bridge acts only when the game did not (BRIDGE_MS after the press: no state-machine change / the screen still
-- activated for B, the same selected tab for LB / RB): a session where CommonUI does take his press never acts twice.
-- P1's pad: parked, it reaches no player. Should CommonUI's router still take P1's B / LB / RB (a router that follows
-- the LocalPlayer's platform user, not its ControllerId), the change comes without a press of his: a tab change is
-- put back, a sub-screen left is re-entered, a garage closed is opened again (cfg.CouchGarageUndoForeign).
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")

local TAG = "garagenative"
local M = {}

local CS_CLASS = "/Script/Griffin.CstSubsystem"
local CSM_DIR = "/Game/Griffin/Config/StateMachines/Customisation/"
local CSM_GARAGE = CSM_DIR .. "CSM_VehicleCustomisation_Root.CSM_VehicleCustomisation_Root"
local CSM_GARAGE_ACTIVE = CSM_DIR .. "CSM_VehicleCustomisation_Active.CSM_VehicleCustomisation_Active"
local CSM_GARAGE_IDLE = CSM_DIR .. "CSM_VehicleCustomisation_Idle.CSM_VehicleCustomisation_Idle"
local TAGS = { "LiveryPaletteTag", "LiveryMaskTag", "IconPaletteTag", "IconMaskTag", "PatinaTag" }
local KEY_OF = { LiveryMaskTag = "mask", LiveryPaletteTag = "palette", PatinaTag = "patina", IconMaskTag = "decal" }
local FILE = "garage-p1-backup.txt"
local ROOT_CLS = "WBP_Paddock_VehicleCust_C"
local OPT_BTN = "WBP_CustomisationOptionButton_Vehicle_C"
local ARCH_NAMES = { [0] = "Car", [1] = "Plane", [2] = "Bike", [3] = "Skimmer" }
-- the root's hero-button events (decoded): a sub-screen left by a foreign back is entered again through them
-- the root's hero buttons (UMG fields) -> the sub-screen class their BndEvt opens (ENTER)
local HERO = {
    WBP_Customise_Theme = "WBP_Paddock_VehicleCustThemeOptions_C",
    WBP_Customise_Parts = "WBP_Paddock_VehicleCustPartsOptions_C",
    WBP_Customise_Livery = "WBP_Paddock_VehicleCustLiveryOptions_C",
}
local ENTER = {
    WBP_Paddock_VehicleCustThemeOptions_C = "BndEvt__WBP_Paddock_VehicleCust_WBP_Customise_Btn_K2Node_ComponentBoundEvent_4_CallButtonClicked__DelegateSignature",
    WBP_Paddock_VehicleCustLiveryOptions_C = "BndEvt__WBP_Paddock_VehicleCust_WBP_Customise_Livery_K2Node_ComponentBoundEvent_6_CallButtonClicked__DelegateSignature",
    WBP_Paddock_VehicleCustPartsOptions_C = "BndEvt__WBP_Paddock_VehicleCust_WBP_Customise_Parts_K2Node_ComponentBoundEvent_5_CallButtonClicked__DelegateSignature",
}
M.ENTER = ENTER
local IA_BACK, IA_PREV, IA_NEXT = "IA_UI_Cancel", "IA_UI_Tab_Left", "IA_UI_Tab_Right"
local IA_ACCEPT = "IA_UI_Accept"
-- 9. the game's own garage exit (decoded, see M.exitGarage)
local EXIT_REASON = "Exiting specific vehicle customisation "        -- the root's own ChangeToState reason (sic)
local IMC_CUST = "/Game/Griffin/Config/Input/Customisation/IMC_Customisation.IMC_Customisation"
local EI_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local CAM_TAG = "VehicleCustomisationCamera"
local EXIT_MS = 3000            -- the exit must be complete (machine Idle, P1's view back...) within this time ...
local EXIT_POLL_MS = 200        -- ... checked this often; then the fallbacks
local BRIDGE_MS = 150           -- a press the game did not act on within this time is bridged
local HELD_A_SETTLE_MS = 150    -- couch-fix76 AUTO-174: the standing offer's held A counts as released after this
local FOREIGN_MS = 400          -- a tab change without his press within this time = P1's pad (or the game)
local FOREIGN_SCREEN_MS = 1500  -- the same for a screen change (seen through couch's screen cache: up to ~0.7 s late)
local ENTRY_RETRY_MS = 120      -- a new option page: his focus re-checked / re-given on an entry this often ...
local ENTRY_TRIES = 15          -- ... at most this many times (~1.8 s: a page builds its entry widgets a frame late)
local CANCEL_TRIGGER ={ [1] = true, [2] = true, [4] = true }      -- ETriggerEvent Triggered / Started / Ongoing

local T = nil                   -- the turn
local VIS = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }   -- ESlateVisibility
-- 8. the root left on screen: pending = { untilMs, world, w, k } after a turn; hidden = { [k] = { vis, world } }
local leftRoot = { pending = nil, hidden = {} }
-- 9. the exit after a turn being verified: { untilMs, nextAt, world, w, k, why, how, stage, sawIdle }
local exitWatch = nil
local unlockAll                 -- (defined with the purchase locks)
local disabledWhy = nil         -- a turn whose garage never came up: the compact garage for the rest of the session
local repairClean = false       -- the backup file was read and holds nothing pending (re-armed by a turn)
local repairMem = false         -- this session restored a pending backup in memory (its save waits for the pawn)

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function G() return U.mod("garage") end
local function couch() return U.mod("couch") end

---------------------------------------------------------------------------------------------------- file
local function filePath()
    local ok, d = pcall(function() return settings.modDir() end)
    if not ok or type(d) ~= "string" then return nil end
    return (d:gsub("\\", "/")) .. "/" .. FILE
end

local function ser(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = { "{" }
        for _, k in ipairs(keys) do
            local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
            out[#out + 1] = ind .. "  " .. key .. " = " .. ser(v[k], ind .. "  ") .. ","
        end
        out[#out + 1] = ind .. "}"
        return table.concat(out, "\n")
    elseif t == "string" then return string.format("%q", v)
    elseif t == "number" or t == "boolean" then return tostring(v) end
    return "nil"
end
M._ser = ser

local function writeBackup(b)
    local p = filePath()
    if not p then return false end
    local f = io.open(p, "w")
    if not f then return false end
    f:write("return " .. ser(b) .. "\n")
    f:close()
    return true
end

local function readBackup()
    local p = filePath()
    if not p then return nil end
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("a"); f:close()
    local fn = load(s, "garage-p1-backup", "t", {})
    if not fn then return nil end
    local ok, b = pcall(fn)
    return (ok and type(b) == "table") and b or nil
end
M._readBackup = readBackup
M._writeBackup = writeBackup

---------------------------------------------------------------------------------------------------- game reads / writes
local function cstOf(pc)
    if not U.ok(pc) then return nil end
    local sub = nil
    pcall(function() sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, U.class(CS_CLASS)) end)
    return U.ok(sub) and sub or nil
end

local function str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(U.callMethod, v, "ToString")
    if ok and type(s) == "string" then return s end
    return tostring(v)
end

local function tagStr(t)
    local s = nil
    pcall(function() s = t.TagName:ToString() end)
    if s == "None" then s = nil end
    return s
end

-- one saved recipe (FCstSavedVehicleRecipeData) -> a plain Lua table (strings / numbers only)
local function readSlot(el)
    local r = { units = {} }
    pcall(function() r.RecipeName = str(el.RecipeName) end)
    pcall(function() r.VehicleArchetype = tonumber(el.VehicleArchetype) end)
    pcall(function() r.UnitLayoutName = str(el.UnitLayoutName) end)
    for _, k in ipairs(TAGS) do pcall(function() r[k] = tagStr(el[k]) end) end
    local arr = nil
    pcall(function() arr = el.UnitRecipes end)
    r.units = G().readUnits(arr) or {}
    return r
end
M._readSlot = readSlot

-- writes a recipe table (garage.recipeTable shape: RecipeName, VehicleArchetype, UnitLayoutName, UnitRecipes (the
-- preset CDO's TArray), RootPhysicsConfiguration, tag structs) onto a slot -> ok, err
local function writeSlot(el, t)
    local ok, err = pcall(function()
        el.RecipeName = t.RecipeName
        el.VehicleArchetype = t.VehicleArchetype
        el.UnitLayoutName = t.UnitLayoutName
        if t.UnitRecipes ~= nil then el.UnitRecipes = t.UnitRecipes end
        if t.RootPhysicsConfiguration ~= nil then el.RootPhysicsConfiguration = t.RootPhysicsConfiguration end
        for _, k in ipairs(TAGS) do if t[k] ~= nil then el[k] = t[k] end end
    end)
    return ok, err
end

-- kit parts written field by field where the unit / part counts match (the model preset written first)
local function writeParts(el, units)
    if type(units) ~= "table" then return 0 end
    local arr = nil
    pcall(function() arr = el.UnitRecipes end)
    if arr == nil then return 0 end
    local n = G().patchUnits(arr, units)
    return n
end

-- pure: two read slots differ (model, any tag, any kit part)
function M.differs(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a ~= b end
    if a.RecipeName ~= b.RecipeName then return true end
    for _, k in ipairs(TAGS) do if a[k] ~= b[k] then return true end end
    if type(a.units) == "table" and type(b.units) == "table" and not G().sameUnits(a.units, b.units) then return true end
    return false
end

-- pure: the differences between a backed-up slot and a read one -> list of "field: want -> have" strings (empty = same)
function M.slotDiff(want, have)
    local out = {}
    if type(want) ~= "table" or type(have) ~= "table" then return { "slot unreadable" } end
    local function cmp(name, a, b) if a ~= b then out[#out + 1] = string.format("%s: %s -> %s", name, tostring(a), tostring(b)) end end
    cmp("RecipeName", want.RecipeName, have.RecipeName)
    cmp("VehicleArchetype", want.VehicleArchetype, have.VehicleArchetype)
    cmp("UnitLayoutName", want.UnitLayoutName, have.UnitLayoutName)
    for _, k in ipairs(TAGS) do cmp(k, want[k], have[k]) end
    local wu, hu = want.units or {}, have.units or {}
    if #wu ~= #hu then
        cmp("units", #wu, #hu)
    else
        for i = 1, #wu do
            cmp("unit " .. i .. " UnitName", wu[i].UnitName, hu[i].UnitName)
            local wp, hp = wu[i].parts or {}, hu[i].parts or {}
            if #wp ~= #hp then
                cmp("unit " .. i .. " parts", #wp, #hp)
            else
                for j = 1, #wp do
                    for _, f in ipairs({ "ParentPartType", "PartType", "vehicleKit" }) do
                        cmp(string.format("unit %d part %d %s", i, j, f), wp[j][f], hp[j][f])
                    end
                end
            end
        end
    end
    return out
end

local function tagOf(s) return { TagName = U.fname((type(s) == "string" and s ~= "") and s or "None") } end

-- a backup slot -> the recipe table to write back (its model's preset CDO for the units, its own names and tags)
local function backupTable(arch, saved)
    local th = nil
    pcall(function() th = require("custdata").THEMES[saved.RecipeName] end)
    local t = nil
    if th and th.preset then t = G().recipeTable({ arch = arch, model = saved.RecipeName, preset = th.preset, stored = {} }) end
    t = t or {}
    t.units = nil
    t.RecipeName = saved.RecipeName
    t.VehicleArchetype = saved.VehicleArchetype or arch
    t.UnitLayoutName = saved.UnitLayoutName and U.fname(saved.UnitLayoutName) or t.UnitLayoutName
    for _, k in ipairs(TAGS) do t[k] = tagOf(saved[k]) end
    return t
end

local function pawn()
    local p = nil
    pcall(function() p = FindFirstOf("VehicleCustomisationPawn") end)
    return U.ok(p) and p or nil
end

local function component()
    local p = pawn()
    if not p then return nil end
    local comp = nil
    pcall(function() comp = p.CustomisationComponent end)
    return U.ok(comp) and comp or nil
end

local function reload()
    local p = pawn()
    if not p then return false end
    return pcall(function() p:ReloadRecipe() end)
end

local function saveRecipes()
    local comp = component()
    if not comp then return false end
    return pcall(function() comp:SaveCustomisationRecipes() end)
end

-- the class P1's garage shows (the component's active recipe), nil when unreadable
local function activeArch()
    local comp = component()
    if not comp then return nil end
    local a = nil
    pcall(function() a = tonumber(comp.ActiveRecipe.VehicleArchetype) end)
    return a
end
M._activeArch = activeArch

-- EVehicleArchetype's user-facing enumerator name (the game's SetSelectedVehicleArchetype passes it)
local function archName(arch)
    local s = nil
    pcall(function()
        local lib = U.cdo("/Script/Engine.Default__KismetNodeHelperLibrary")
        local en = U.obj("/Script/Griffin.EVehicleArchetype")
        if U.ok(lib) and U.ok(en) then s = lib:GetEnumeratorUserFriendlyName(en, arch) end
    end)
    s = str(s)
    if type(s) ~= "string" or s == "" then s = ARCH_NAMES[arch] or tostring(arch) end
    return s
end

-- BPFL_CustomisationFunctionLibrary.SetSelectedVehicleArchetype (decoded): UpdateUISelection(0, name, arch)
local function selectArch(arch)
    local comp = component()
    if not comp then return false end
    return pcall(function() comp:UpdateUISelection(0, archName(arch), arch) end)
end

---------------------------------------------------------------------------------------------------- restore
-- P1's garage back from a backup (this turn's or a crashed one's): his class on the pawn, every slot that differs
-- written back, reload + save, then compared again. -> written, remaining differences (slots), ok
-- deferSave (couch-livefix ii): no save here, the caller saves once the pad ids are back (P1's account user on id 0)
local function restore(b, why, deferSave)
    local sub = cstOf(U.p1())
    if not sub then return 0, 0, false end
    if b.p1Arch ~= nil and activeArch() ~= b.p1Arch then
        local okA = selectArch(b.p1Arch)
        U.log(TAG, "P1's garage class back to %s: %s", tostring(b.p1Arch), okA and "ok" or "failed")
    end
    -- the slots must be there (a CstSubsystem not filled yet: try again later, the backup stays pending)
    local num = 0
    pcall(function() num = sub.VehicleRecipeDatas:GetArrayNum() end)
    if type(num) ~= "number" or num < 1 then return 0, 0, false end
    local n = 0
    pcall(function()
        local datas = sub.VehicleRecipeDatas
        for idx, saved in pairs(b.slots or {}) do
            local el = (idx <= num) and datas[idx] or nil
            if el == nil then
                U.warn(TAG, "P1's garage slot %d missing (%d slot(s) now): not restored", idx, num)
            elseif #M.slotDiff(saved, readSlot(el)) > 0 then
                local ok, err = writeSlot(el, backupTable(saved.VehicleArchetype or (idx - 1) // 2, saved))
                if ok then
                    n = n + 1
                    local parts = writeParts(el, saved.units)
                    U.log(TAG, "P1's garage slot %d restored (%s, %d kit part(s)) (%s)", idx, tostring(saved.RecipeName), parts, why)
                else
                    U.warn(TAG, "P1's garage slot %d NOT restored: %s (backup kept in %s)", idx, tostring(err), FILE)
                end
            end
        end
    end)
    reload()
    local saved = (not deferSave) and saveRecipes() or false
    -- read back: every slot the same as the backup
    local bad, lines = 0, {}
    pcall(function()
        local datas = sub.VehicleRecipeDatas
        for idx, saved in pairs(b.slots or {}) do
            local d = (idx <= num) and M.slotDiff(saved, readSlot(datas[idx])) or { "slot missing" }
            if #d > 0 then
                bad = bad + 1
                lines[#lines + 1] = string.format("slot %d: %s", idx, table.concat(d, "; ", 1, math.min(#d, 4)))
            end
        end
    end)
    if bad == 0 then
        U.log(TAG, "P1's garage restored exactly: %d slot(s) written, every slot equals the backup (%s)", n, why)
    else
        U.warn(TAG, "P1's garage NOT exactly restored (%s): %s (backup kept in %s)", why, table.concat(lines, " | "), FILE)
    end
    -- no garage pawn (a crash repair in the front end): the slots are back in memory but the game's save file still
    -- holds the guest's car - the backup stays pending until a save went through (slowTick retries with the pawn)
    b.pending = not saved
    b.diffs = bad > 0 and lines or nil
    writeBackup(b)
    if not saved and not deferSave then U.log(TAG, "P1's garage restored in memory; saved once the garage pawn exists (%s)", why) end
    return n, bad, true
end

---------------------------------------------------------------------------------------------------- turn
local function toast(text)
    U.log(TAG, "%s", text)
    pcall(function() St.emit("status", text) end)
end

-- the garage screens up: { root = entry, sub = newest other entry, any = bool }
local function garageScreens()
    local root, sub = nil, nil
    pcall(function()
        for _, e in ipairs(couch().activeScreens()) do
            if e.cls:find("VehicleCust", 1, true) and U.alive(e.w) then
                if e.cls == ROOT_CLS then root = e
                elseif not sub or (e.seen or 0) >= (sub.seen or 0) then sub = e end
            end
        end
    end)
    return root, sub
end

-- couchpanel: a guest chose GARAGE on the run map -> true when the native turn started (else the compact panel)
-- opts.heldA (rel103, the standing offer): his A is still held when the turn starts - its release is not a press
-- in the garage (live 2026-10-24: the hold's own A entered CHOOSE MODEL through the accept bridge)
function M.start(g, arch, opts)
    if opt("CouchGarageNative", true) ~= true then return false end
    if disabledWhy then
        U.logOnce("garagenative.disabled", TAG, "native garage off for this session (%s): the compact garage", disabledWhy)
        return false
    end
    if T then return true end
    -- live 2026-10-16: couchpanel offers GARAGE on the post-race run map too (phase POSTRACE). The game's garage machine
    -- lives in the paddock only, and fastTick runs in phase OTHER only: a turn started there held the pads, never opened
    -- the garage and never timed out (P1's pad dead until a world change). Outside the paddock: the compact garage.
    if St.phase ~= "OTHER" then
        U.log(TAG, "P%s's garage on the %s map: the compact garage (the game's garage exists in the paddock only)",
            tostring(g and g.pnum), tostring(St.phase))
        return false
    end
    arch = tonumber(arch)
    if arch == nil then return false end
    local p1 = U.p1()
    local sub = cstOf(p1)
    if not sub then U.warn(TAG, "no CstSubsystem on P1's local player: the compact garage instead"); return false end
    local eff = G().effective(g.pnum, arch)
    local t, why = G().recipeTable(eff)
    if not t then U.warn(TAG, "P%s's car not buildable (%s): the compact garage instead", tostring(g.pnum), tostring(why)); return false end
    local units = t.units
    t.units = nil
    -- 1. backup of every slot + P1's displayed class (file first)
    local b = { pending = true, arch = arch, pnum = g.pnum, at = os.time(), slots = {}, p1Arch = activeArch() }
    local okR = pcall(function()
        local datas = sub.VehicleRecipeDatas
        for idx = 1, datas:GetArrayNum() do b.slots[idx] = readSlot(datas[idx]) end
    end)
    local mine = { arch * 2 + 1, arch * 2 + 2 }               -- Lua 1-based: his class' slots arch*2 and arch*2+1
    if not okR or b.slots[mine[1]] == nil then U.warn(TAG, "P1's garage slots unreadable: no turn"); return false end
    if not writeBackup(b) then U.warn(TAG, "backup file not writable: no turn"); return false end
    repairClean = false
    -- 2. his class on the pawn (before his car is written: a switch may save the class it leaves)
    if b.p1Arch ~= nil and b.p1Arch ~= arch then
        local okA = selectArch(arch)
        U.log(TAG, "P1's garage shows class %s, P%s's is %s: pawn switched (%s)", tostring(b.p1Arch), tostring(g.pnum),
            tostring(arch), okA and "ok" or "failed")
    end
    -- 3. his car into his class' slots
    local wrote = 0
    pcall(function()
        local datas = sub.VehicleRecipeDatas
        for _, idx in ipairs(mine) do
            if b.slots[idx] then
                local ok, err = writeSlot(datas[idx], t)
                if ok then
                    wrote = wrote + 1
                    if units then writeParts(datas[idx], units) end
                else
                    U.warn(TAG, "slot %d: %s", idx, tostring(err))
                end
            end
        end
    end)
    if wrote == 0 then restore(b, "load failed"); return false end
    local written = {}
    pcall(function()
        local datas = sub.VehicleRecipeDatas
        for _, idx in ipairs(mine) do if b.slots[idx] then written[idx] = readSlot(datas[idx]) end end
    end)
    reload()
    local shown = activeArch()
    if shown ~= nil and shown ~= arch then
        U.warn(TAG, "P1's garage still shows class %s after the switch to %s: no turn (the compact garage instead)",
            tostring(shown), tostring(arch))
        restore(b, "class switch refused")
        return false
    end
    -- 4. pads: the guest's pad drives P1's PC (the screens' owner), P1's pad nobody
    local okH = pcall(function() couch().garageHold(g.ctrlId, true) end)
    local held = false
    pcall(function() held = couch().garageHeld() == true end)
    if not (okH and held) then
        U.warn(TAG, "P%s's pad could not be given P1's screens: no turn (the compact garage instead)", tostring(g.pnum))
        restore(b, "pads not held")
        return false
    end
    -- 5. the game's garage
    -- the garage is a STANDALONE machine (see M.openGarage); on the run map (no paddock HUD) the map closes first
    -- (its BackToPreviousState) and fastTick opens the garage once that machine accepts it
    local okS, how = M.openGarage()
    if not okS then
        pcall(function()
            for _, e in ipairs(couch().activeScreens()) do
                if e.cls:find("Paddock_NextEvent", 1, true) and U.alive(e.w) then e.w:BackToPreviousState(); how = "map closed, opening"; break end
            end
        end)
    end
    T = { pnum = g.pnum, ctrlId = g.ctrlId, arch = arch, backup = b, written = written, mine = mine, at = St.nowMs(),
          seen = false, world = St.worldGen, opened = okS, prev = (type(opts) == "table" and opts.heldA) and { [IA_ACCEPT] = true } or {},
          pend = {}, lastPress = -1e12, reopens = 0,
          reenters = 0, tabsBack = 0, bridged = { back = 0, tab = 0, accept = 0 }, native = { back = 0, tab = 0, accept = 0 },
          locked = {}, lockedN = 0, lockPresses = 0, ownCache = {}, buys = 0,
          heldA = (type(opts) == "table" and opts.heldA) and { since = St.nowMs() } or nil }
    toast(string.format("P%s'S GARAGE - P%s DRIVES", tostring(g.pnum), tostring(g.pnum)))
    U.log(TAG, "P%s garage turn: P1's %d slot(s) backed up, his %s loaded in %d, pads %s, garage %s (%s)", tostring(g.pnum),
        (function() local n = 0; for _ in pairs(b.slots) do n = n + 1 end; return n end)(), tostring(t.RecipeName), wrote,
        okH and "held" or "NOT held", okS and "opened" or "NOT opened", tostring(how))
    return true
end

-- his result -> garage.lua's store; P1's garage back; pads back
function M.finish(why)
    if not T then return end
    lastTurnEnd = St.nowMs()
    U.try(TAG, unlockAll, why)
    local t = T
    T = nil
    local sub = cstOf(U.p1())
    -- his result: the slot of his class the game's screens saved into differs from what we wrote; with no change, any
    local res = nil
    if sub then
        pcall(function()
            local datas = sub.VehicleRecipeDatas
            for _, idx in ipairs(t.mine) do
                if t.backup.slots[idx] then
                    local r = readSlot(datas[idx])
                    if M.differs(r, (t.written or {})[idx]) then res = r end
                    res = res or r
                end
            end
        end)
    end
    if res and res.RecipeName then
        local st = { model = res.RecipeName }
        for prop, key in pairs(KEY_OF) do st[key] = res[prop] end
        -- his kit parts ("Edit Vehicle"): kept when they differ from his model preset's own
        if type(res.units) == "table" and #res.units > 0 then
            local pu = nil
            pcall(function() pu = G().presetUnits(t.arch, res.RecipeName) end)
            if not (pu and G().sameUnits(res.units, pu)) then st.units = res.units end
        end
        pcall(function() G().setFromNative(t.pnum, t.arch, st) end)
        U.log(TAG, "P%s garage turn done (%s): model %s, mask %s, colours %s, finish %s, kit parts %s", tostring(t.pnum),
            tostring(why), tostring(st.model), tostring(st.mask), tostring(st.palette), tostring(st.patina),
            st.units and tostring(G().partCount(st.units)) .. " of his own" or "the model's")
    else
        U.warn(TAG, "P%s garage turn: his result unreadable (%s); his store unchanged", tostring(t.pnum), tostring(why))
    end
    local n, bad, okR = restore(t.backup, "end of P" .. tostring(t.pnum) .. "'s turn", true)
    pcall(function() couch().garageHold(t.ctrlId, false) end)
    -- (couch-livefix ii) P1's restored garage is saved only now: the pad ids are back, P1's account user holds pad
    -- id 0 (saved inside the hold it went to the account-less root slot, live savepath-watch 11:46:05)
    if okR then
        local saved = saveRecipes()
        t.backup.pending = not saved
        writeBackup(t.backup)
        U.log(TAG, "P1's restored garage saved after the pad ids came back: %s", saved and "ok"
            or "no garage pawn (saved once it exists)")
    end
    -- 9. the game's own garage exit, P1 the owner again (pad ids back, his car restored): not after a world change
    -- (the garage died with its world)
    if t.world == St.worldGen and why ~= "world changed" then U.try(TAG, M.exitAfterTurn, t, why) end
    if t.buys > 0 then
        U.warn(TAG, "P%s's turn: %d purchase(s) on P1's profile went through despite the locks (cannot be undone)",
            tostring(t.pnum), t.buys)
    end
    U.log(TAG, "P%s's turn: bridged A %d / B %d / tabs %d, native B %d / tabs %d, P1-pad undos: %d tab(s), %d re-entry(ies), "
        .. "%d reopen(s); %d press(es) seen only by their trigger time", tostring(t.pnum), t.bridged.accept or 0,
        t.bridged.back, t.bridged.tab, t.native.back, t.native.tab, t.tabsBack, t.reenters, t.reopens, t.missed or 0)
    if why == "the garage never came up" then
        disabledWhy = why
        toast("GARAGE: THE COMPACT GARAGE NEXT TIME")
    end
    toast((okR and bad == 0) and string.format("P%s'S GARAGE SAVED - P1'S CAR RESTORED", tostring(t.pnum))
        or "GARAGE: P1'S CAR NOT RESTORED - SEE LOG")
    return n
end

local function garageMachine()
    local root = U.obj(CSM_GARAGE)
    if not U.ok(root) then return nil, "garage state assets not loadable" end
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    local m = nil
    if U.ok(mgr) then pcall(function() m = mgr:GetStateMachineForRoot(root) end) end
    if not U.ok(m) then return nil, "no garage machine (map up?)" end
    return m
end

-- -> ok, how. The garage is a STANDALONE machine (CSM_VehicleCustomisation_Root: Idle / Active) hosted by the on-foot
-- paddock state like the pause menus (decoded CSM_Paddock_OnFoot RootAsset actions): CosmeticStateMachineManager:
-- GetStateMachineForRoot(root):ChangeStateTo(CSM_VehicleCustomisation_Active) - live 2026-10-15: the game's
-- WBP_Paddock_VehicleCust_C full screen with the 3D car. (ChangeStateTo(root) on the paddock HUD's machine did nothing.)
function M.openGarage()
    local m, how = garageMachine()
    if not m then return false, how end
    local act = U.obj(CSM_GARAGE_ACTIVE)
    if not U.ok(act) then return false, "garage state assets not loadable" end
    local okC, err = pcall(function() m:ChangeStateTo(act, "SWGRCouch: guest garage turn", nil) end)
    return okC, okC and "garage machine -> Active" or tostring(err)
end

-- the garage machine back to Idle (an aborted turn: his pad gone)
function M.closeGarage(why)
    local m, how = garageMachine()
    if not m then return false, how end
    local idle = U.obj(CSM_GARAGE_IDLE)
    if not U.ok(idle) then return false, "Idle state not loadable" end
    local ok = pcall(function() m:ChangeStateTo(idle, "SWGRCouch: " .. tostring(why), nil) end)
    return ok
end

function M.active() return T ~= nil end

---------------------------------------------------------------------------------------------------- his input
-- the IA_UI_* actions triggered on P1's PC's raw input subsystem (the native filter gives it the pad id P1's PC holds:
-- the guest's, live 2026-10-15) -> { [name] = true }. Without the DLL filter every raw subsystem records every pad (P1's
-- B too): then an action also needs its key down on P1's PlayerInput (routed by ControllerId = the guest's pad only).
local KEY_OF_IA = { [IA_BACK] = "Gamepad_FaceButton_Right", [IA_PREV] = "Gamepad_LeftShoulder", [IA_NEXT] = "Gamepad_RightShoulder",
                    [IA_ACCEPT] = "Gamepad_FaceButton_Bottom" }
local function filterOn()
    local on = nil
    pcall(function() on = U.mod("inputfix").nativeOn() end)
    return on == true
end
-- (couch-livefix r2, live 2026-10-16 round 2: "the garage closed without his B ... opened again" x2 while P2 had
-- pressed B) TriggerEvent is a ONE-FRAME state for a pressed trigger: a B shorter than the FAST poll's 33 ms (two game
-- frames at 60 fps) is Triggered only between two polls and the poll never saw it - the press that closed the garage
-- natively went unseen. FInputActionInstance.LastTriggeredWorldTime (reflected, +0x14) keeps the moment of the last
-- trigger: a change since the previous poll = a trigger the poll missed. -> acts, ltw ({ [name] = time })
local function rawActs(pc)
    local acts, ltw = {}, {}
    pcall(function()
        local epi = pc.RawInputSubsystem.EnhancedPlayerInput
        if not U.ok(epi) then return end
        epi.ActionInstanceData:ForEach(function(k, v)
            local ia = k:get()
            if not U.ok(ia) then return end
            local n = U.objName(ia)
            if n == IA_BACK or n == IA_PREV or n == IA_NEXT or n == IA_ACCEPT then
                local inst = v:get()
                if CANCEL_TRIGGER[tonumber(inst.TriggerEvent) or 0] then acts[n] = true end
                local t = nil
                pcall(function() t = tonumber(inst.LastTriggeredWorldTime) end)
                if t then ltw[n] = t end
            end
        end)
    end)
    if next(acts) ~= nil and not filterOn() then
        U.logOnce("garagenative.nofilter", TAG, "swgr_inputfilter not active: his B / LB / RB are confirmed on P1's "
            .. "PlayerInput (P1's pad would also show on the raw input)")
        for n in pairs(acts) do
            local down = false
            pcall(function() down = pc:IsInputKeyDown({ KeyName = U.fname(KEY_OF_IA[n]) }) == true end)
            if not down then acts[n] = nil end
        end
    end
    if not filterOn() then ltw = {} end           -- every pad on every raw subsystem: a trigger time is nobody's
    return acts, ltw
end

-- live 2026-10-16: UE4SS returns GetDisplayedEntryWidgets' TArray as a Lua table of param wrappers (userdata whose
-- :get() is the widget; U.ok(wrapper) is false): every entry was skipped, no option was ever locked and a hold bought
-- one on P1's profile. Elements are unwrapped here.
local function unwrap(v)
    if type(v) == "userdata" and not U.ok(v) then
        local ok, g = pcall(function() return v:get() end)
        if ok and g ~= nil then return g end
    end
    return v
end
local function arrList(a)
    local out = {}
    if type(a) == "table" then
        for i, v in ipairs(a) do out[i] = unwrap(v) end
        return out
    end
    pcall(function() for i = 1, a:GetArrayNum() do out[i] = unwrap(a[i]) end end)
    return out
end

-- the screen's tab list (two tabs or more, shown) or nil
local function tabList(w)
    local tl = nil
    if not U.alive(w) then return nil end
    pcall(function() tl = w.WBP_Tab_List end)
    if not U.alive(tl) then return nil end
    local n = nil
    pcall(function() n = tonumber(tl:GetTabCount()) end)
    if not n or n < 2 then return nil end
    local vis = true
    pcall(function() vis = tl:IsVisible() ~= false end)
    return vis and tl or nil, n
end

local function selectedTab(tl)
    if not U.alive(tl) then return nil end
    local s = nil
    pcall(function() s = str(tl:GetSelectedTabId()) end)
    return s
end

-- pure: the next usable tab id from cur in direction dir (+1 / -1); wrap (bShouldWrapNavigation) or stop at the ends;
-- usable(id) false skips a tab (disabled / hidden, as CommonTabListWidgetBase's own HandleNextTabInputAction)
function M.nextTab(ids, cur, dir, wrap, usable)
    local n = #ids
    if n < 2 then return nil end
    local i = nil
    for k, id in ipairs(ids) do if id == cur then i = k end end
    if not i then return nil end
    for _ = 1, n - 1 do
        i = i + dir
        if i < 1 or i > n then
            if not wrap then return nil end
            i = (i < 1) and n or 1
        end
        if usable == nil or usable(ids[i]) ~= false then return ids[i] end
    end
    return nil
end

local function stepTab(tl, dir)
    local n = 0
    pcall(function() n = tonumber(tl:GetTabCount()) or 0 end)
    local ids = {}
    for i = 0, n - 1 do
        local id = nil
        pcall(function() id = str(tl:GetTabIdAtIndex(i)) end)
        if id then ids[#ids + 1] = id end
    end
    local wrap = true
    pcall(function() local v = tl.bShouldWrapNavigation; if type(v) == "boolean" then wrap = v end end)
    local nextId = M.nextTab(ids, selectedTab(tl), dir, wrap, function(id)
        local ok = true
        pcall(function()
            local b = tl:GetTabButtonBaseByID(U.fname(id))
            if U.ok(b) then ok = b:GetIsEnabled() ~= false and b:IsVisible() ~= false end
        end)
        return ok
    end)
    if not nextId then return false end
    return pcall(function() tl:SelectTabByID(U.fname(nextId), false) end), nextId
end

local function selectTab(tl, id)
    return pcall(function() tl:SelectTabByID(U.fname(id), false) end)
end

local function cinematicPlaying()
    local p = pawn()
    local cin = false
    if p then pcall(function() cin = p:IsUnlockCinematicPlaying() == true end) end
    return cin, p
end

-- the screen's back as its own CommonUI back would do it (decoded): a playing unlock cinematic ends first
local function doBack(w)
    local cin, p = cinematicPlaying()
    if cin then return pcall(function() p:EndUnlockCinematic() end), "unlock cinematic ended" end
    local ok = pcall(function() w:BackToPreviousState() end)
    if not ok then ok = pcall(function() w.OwningStateMachine:BackToPreviousState(nil) end) end
    return ok, "back"
end

M.backOf = doBack                -- couch-scaccept: menubridge's B on P1's OWN garage pages (ids swapped, not a turn)

local function activated(w)
    local a = false
    pcall(function() a = w:IsActivated() == true end)
    return a
end

-- the option page of a tabbed screen (its switcher's active page, else its single page) -> its list's target entry
-- (entriesOnly: nil while the page shows no entry widget yet, instead of the list itself)
local function listTarget(w, entriesOnly)
    local ov = nil
    pcall(function() local sw = w.FuseWidgetSwitcher; if U.ok(sw) then ov = sw:GetActiveWidget() end end)
    if not U.ok(ov) then pcall(function() ov = w.WBP_CustomisationOptionView end) end
    if not U.ok(ov) then return nil end
    local lv = nil
    pcall(function() lv = ov.LV_Items end)
    if not U.ok(lv) then return nil end
    local sel = nil
    pcall(function() sel = lv:BP_GetSelectedItem() end)
    local ents = {}
    pcall(function() ents = arrList(lv:GetDisplayedEntryWidgets()) end)
    local first = nil
    for _, en in ipairs(ents) do
        if U.ok(en) then
            first = first or en
            if U.ok(sel) then
                local it = nil
                pcall(function() it = en["As BP Customisation Option Entry Object"] end)
                if U.ok(it) and U.key(it) == U.key(sel) then return en end
            end
        end
    end
    if entriesOnly then return first end
    return first or lv
end

-- a CommonButton of the screen in its selected state (the root's hero buttons, live 2026-10-15)
local function selectedButton(w)
    local wk = U.key(w)
    for _, btn in ipairs(FindAllOf("CommonButtonBase") or {}) do
        if U.ok(btn) then
            local s = false
            pcall(function() s = btn:GetSelected() == true and btn:IsVisible() == true end)
            if s then
                local x = btn
                for _ = 1, 14 do
                    x = U.outerOf(x)
                    if not U.ok(x) then break end
                    if U.key(x) == wk then return btn end
                end
            end
        end
    end
    return nil
end

local function focusTarget(e)
    local tgt = nil
    if e.cls ~= ROOT_CLS then tgt = listTarget(e.w) end
    if not U.ok(tgt) then tgt = selectedButton(e.w) end
    if not U.ok(tgt) then pcall(function() tgt = e.w:GetDesiredFocusTarget() end) end
    if not U.ok(tgt) then tgt = e.w end
    return tgt
end

-- P1's pad (or the game) acted without his press: put it back (cfg.CouchGarageUndoForeign)
local function undoOn() return opt("CouchGarageUndoForeign", true) ~= false end

local function watchTabs(e, p1, now)
    local tl = tabList(e.w)
    local w = T.tabWatch
    if not tl then T.tabWatch = nil; return end
    local cur = selectedTab(tl)
    if not (w and w.k == e.k) then T.tabWatch = { k = e.k, id = cur }; return end
    if cur == w.id or cur == nil then return end
    -- our own step / put-back, his own A on the tab bar (his Slate focus there) or his LB / RB just now: not foreign
    local x = T.expectTab
    local his = (x and x.k == e.k and x.id == cur and now - x.at < FOREIGN_MS) or now - T.lastPress < FOREIGN_MS
    if not his then pcall(function() his = tl:HasUserFocusedDescendants(p1) == true end) end
    if his or not undoOn() then w.id = cur; return end
    if selectTab(tl, w.id) then
        T.tabsBack = T.tabsBack + 1
        T.expectTab = { k = e.k, id = w.id, at = now }
        U.warn(TAG, "P%s's turn: the tab of %s changed to %s without his press (P1's pad?): back to %s", tostring(T.pnum),
            e.cls, tostring(cur), tostring(w.id))
    else
        w.id = cur
    end
end

-- the top garage screen changed: a sub-screen left without his B (P1's pad?) is entered again
local function watchBack(root, top, now)
    local prev = T.top
    T.top = top and { k = top.k, cls = top.cls } or nil
    if not (prev and top) or prev.k == top.k then return end
    if prev.cls == ROOT_CLS or top.cls ~= ROOT_CLS then return end      -- not a sub -> root step
    if now - T.lastBack < FOREIGN_SCREEN_MS or not undoOn() or T.reenters >= 3 then return end
    local ev = ENTER[prev.cls]
    if not (ev and root) then return end
    local ok = pcall(function() root.w[ev](root.w) end)
    T.reenters = T.reenters + 1
    U.warn(TAG, "P%s's turn: %s left without his B (P1's pad?): entered again (%s)", tostring(T.pnum), prev.cls,
        ok and "ok" or "failed")
end

---------------------------------------------------------------------------------------------------- no purchases
-- NO PURCHASE ON P1's PROFILE (couch-garage2 follow-up, cfg.CouchGarageNoPurchase): an option entry that P1's profile
-- does not own (CstOptionFunctionLibrary:IsOptionUnlockedAndPurchased(entry.Data), the test of the entry's own
-- GetHasBeenPurchased) is put in the CommonButton LOCKED state (SetIsLocked(true)) while the guest's turn shows it: a
-- locked button's click / hold runs BP_OnLockClicked (the lock sound) instead of BP_OnClicked, whose path is the only
-- caller of CstVehicleRecipeUIData:TryToPurchaseOption (decoded WBP_CustomisationOptionButton_Vehicle). Owned options
-- still equip. His A on a locked entry shows "LOCKED - P1'S PROFILE". Every lock is lifted at the end of the turn.
-- Safety net: a TryToPurchaseOption seen during a turn anyway is logged as a WARN (a purchase cannot be undone).
local OPT_LIB = "/Script/Griffin.Default__CstOptionFunctionLibrary"
local function noBuy() return opt("CouchGarageNoPurchase", true) ~= false end

-- the entries of the active page of a screen (none on the root)
local function pageEntries(w)
    local ov = nil
    pcall(function() local sw = w.FuseWidgetSwitcher; if U.ok(sw) then ov = sw:GetActiveWidget() end end)
    if not U.ok(ov) then pcall(function() ov = w.WBP_CustomisationOptionView end) end
    if not U.alive(ov) then return {} end
    local lv = nil
    pcall(function() lv = ov.LV_Items end)
    if not U.alive(lv) then return {} end
    local ents = {}
    pcall(function() ents = arrList(lv:GetDisplayedEntryWidgets()) end)
    return ents
end

-- P1's profile owns the entry's option? true / false / nil (unreadable: treated as not owned = locked)
local function owned(en)
    local data = nil
    pcall(function() data = en.Data end)
    if not U.ok(data) then return nil end
    local k = U.key(data)
    local c = T.ownCache[k]
    if c ~= nil then return c end
    local r = nil
    pcall(function()
        local lib = U.cdo(OPT_LIB)
        if U.ok(lib) then r = U.callMethod(lib, "IsOptionUnlockedAndPurchased", data, en) end
    end)
    if type(r) == "boolean" then T.ownCache[k] = r end
    return type(r) == "boolean" and r or nil
end

local function lockTick(e, now, force)
    if not noBuy() or e.cls == ROOT_CLS then return end
    if not force and now < (T.lockAt or 0) then return end
    T.lockAt = now + 500
    for _, en in ipairs(pageEntries(e.w)) do
        if U.alive(en) and U.className(en) == OPT_BTN then
            local k = U.key(en)
            if not T.locked[k] and owned(en) ~= true then
                local ok = pcall(function() en:SetIsLocked(true) end)
                if ok then
                    T.locked[k] = en
                    T.lockedN = T.lockedN + 1
                end
            end
        end
    end
end

-- en holds his focus (user 1 = P1's PC): a CommonButton forwards a focus it is given to its internal root button
-- (the same test as backprompt / menubridge: the button itself OR a descendant)
local function hisFocus(en, p1)
    local f = false
    if U.alive(en) then
        pcall(function() f = en:HasUserFocus(p1) == true or en:HasUserFocusedDescendants(p1) == true end)
    end
    return f
end

-- an option entry of the screen's active page holds his focus
local function entryFocused(e, p1)
    for _, en in ipairs(pageEntries(e.w)) do
        if hisFocus(en, p1) then return true end
    end
    return false
end

-- FINDING #27 (couch-p1garage, live 2026-10-17 round 2): P1's OWN garage while the pad ids are swapped for it (no guest
-- turn; the screens belong to the last local PC, P1 = Steam Controller through Steam Input): his D-pad moves the hero
-- highlight, his A on CHOOSE MODEL / EDIT VEHICLE / EDIT LIVERY never reaches the owner's CommonUI router. menubridge
-- (cnat "garage") reads his A from the DLL's pad watch and, when the game did not act within its wait, enters the hero
-- page that holds HIS focus (the pad-0 PC's Slate user) through the root's own BndEvt - the guest turn's bridge above.
-- pc = the PC on pad id 0. -> ok, the sub-screen class (or why nothing was entered)
function M.ownEnter(w, pc)
    if not (U.alive(w) and U.ok(pc)) then return false, "no root / no pad-0 PC" end
    for field, sub in pairs(HERO) do
        local b = nil
        pcall(function() b = w[field] end)
        if U.ok(b) and hisFocus(b, pc) then
            local ev = ENTER[sub]
            local ok = ev ~= nil and pcall(function() w[ev](w) end)
            return ok, sub
        end
    end
    return false, "no hero button holds his focus"
end
-- the page's tab list and its selected tab id (nil, nil without tabs)
function M.ownTab(w)
    local tl = tabList(w)
    if not tl then return nil, nil end
    return tl, selectedTab(tl)
end
-- LB / RB on his own garage page (dir -1 / +1): the tab list's next usable tab -> ok, id
function M.ownTabStep(w, dir)
    local tl = tabList(w)
    if not tl then return false, nil end
    return stepTab(tl, dir)
end
-- his cursor on a page: an option ENTRY must hold it (a focus on the list itself = dead D-pad, live 2026-10-16) ->
-- holds (true / false; nil = the page lists no option entries: the caller's own test), the entry to focus (or nil)
function M.ownEntryFocus(w, pc)
    local ents = pageEntries(w)
    if #ents == 0 then return nil, nil end
    for _, en in ipairs(ents) do
        if hisFocus(en, pc) then return true, en end
    end
    return false, listTarget(w, true)
end
-- the page's state for a native-first check: selected tab + the list's selected item (an equip moves it)
function M.ownPageSig(w)
    local parts = {}
    local tl = tabList(w)
    parts[1] = tostring(tl and selectedTab(tl) or "-")
    pcall(function()
        local ov = nil
        local sw = w.FuseWidgetSwitcher
        if U.ok(sw) then ov = sw:GetActiveWidget() end
        if not U.ok(ov) then ov = w.WBP_CustomisationOptionView end
        local it = U.ok(ov) and ov.LV_Items:BP_GetSelectedItem() or nil
        parts[2] = U.ok(it) and tostring(U.key(it)) or "-"
    end)
    return table.concat(parts, "/")
end

-- his A on a locked entry (his focus = user 1, P1's PC) -> the toast
local function lockedPress(e, p1)
    for k, en in pairs(T.locked) do
        local f = hisFocus(en, p1)
        if f then
            T.lockPresses = T.lockPresses + 1
            toast("LOCKED - P1'S PROFILE")
            return true
        end
    end
    return false
end

unlockAll = function(why)
    if not T then return end
    local n = 0
    for k, en in pairs(T.locked) do
        if U.alive(en) and pcall(function() en:SetIsLocked(false) end) then n = n + 1 end
        T.locked[k] = nil
    end
    if T.lockedN > 0 then
        U.log(TAG, "P%s's turn: %d option(s) P1's profile does not own shown locked, %d unlocked again (%s); %d A on them",
            tostring(T.pnum), T.lockedN, n, tostring(why), T.lockPresses)
    end
end

local function driveTick(now, root, sub)
    local e = sub or root
    local p1 = U.p1()
    if not (e and U.ok(p1)) then return end
    -- P1's pad keeps no Slate focus in the garage (a screen activation hands it user 0's focus)
    pcall(function() couch().garageSinkCheck("garage screen " .. e.cls) end)
    -- options P1's profile does not own: locked (no purchase on P1's profile); his A on one: the toast
    lockTick(e, now, T.lockKey ~= e.k)
    T.lockKey = e.k
    if (T.edge or {})[IA_ACCEPT] and next(T.locked) ~= nil then lockedPress(e, p1) end
    local edge = T.edge or {}
    -- the baselines are the PREVIOUS tick's (a CommonUI action that works acts at the key-down, before this poll sees
    -- the press: the screen / tab of this tick may already be the result)
    local before = T.last or { k = e.k, w = e.w, cls = e.cls, seq = couch().csmSeq() }
    if edge[IA_BACK] then
        T.pend.back = { at = now, k = before.k, w = before.w, cls = before.cls, seq = before.seq }
    end
    if edge[IA_ACCEPT] and e.cls == ROOT_CLS then
        T.pend.accept = { at = now, k = before.k, w = before.w, cls = before.cls, seq = before.seq }
    end
    if edge[IA_PREV] or edge[IA_NEXT] then
        local tl = tabList(e.w)
        local tw = T.tabWatch
        local base = (tw and tw.k == e.k) and tw.id or selectedTab(tl)
        if tl then T.pend.tab = { at = now, tl = tl, k = e.k, id = base, dir = edge[IA_NEXT] and 1 or -1 } end
    end
    -- bridges: only when the game did not act on his press
    local pb = T.pend.back
    if pb and now - pb.at >= BRIDGE_MS then
        T.pend.back = nil
        if couch().csmSeq() ~= pb.seq or not U.alive(pb.w) or not activated(pb.w) then
            T.native.back = T.native.back + 1
        elseif pb.cls == ROOT_CLS and not cinematicPlaying() then
            -- (couch-livefix r4) his B on the ROOT = the end of his turn: NOT the root's FuseScreenWidget
            -- BackToPreviousState (its back state does not exist in the standalone garage machine: the root
            -- deactivated, the machine stayed Active - the garage camera on P1's car, P1's input dead, live round 4).
            -- The turn ends here and M.finish leaves the garage the game's own way once P1's car and pad ids are back.
            T.bridged.back = T.bridged.back + 1
            T.lastBack = now
            U.log(TAG, "P%s's B on the garage root: his turn ends (the game's own garage exit after P1's restore)",
                tostring(T.pnum))
            M.finish("his B on the garage root")
            return
        else
            local ok, how = doBack(pb.w)
            T.bridged.back = T.bridged.back + 1
            T.lastBack = now
            T.focusAt = now + 300                      -- let the next screen activate before re-focusing
            U.log(TAG, "P%s's B in the garage -> %s %s: %s", tostring(T.pnum), pb.cls, how, ok and "ok" or "failed")
            T.pend.tab = nil
            return                                      -- that screen may be gone: nothing more on it this tick
        end
    end
    -- live 2026-10-16 (round 2, pads 3 / 4 plugged, not joined): the garage root belongs to the LAST local PC, parked
    -- on an id no pad holds: his D-pad moves the Slate focus (user 1) but his A never reaches the owner's CommonUI
    -- router. A root A the game did not act on enters the hero button that holds his focus (the root's own BndEvt).
    local pa = T.pend.accept
    if pa and now - pa.at >= BRIDGE_MS then
        T.pend.accept = nil
        if couch().csmSeq() ~= pa.seq or e.k ~= pa.k or not U.alive(pa.w) or not activated(pa.w) then
            T.native.accept = T.native.accept + 1
        else
            for field, sub in pairs(HERO) do
                local b = nil
                pcall(function() b = pa.w[field] end)
                if U.ok(b) and hisFocus(b, p1) then
                    local ev = ENTER[sub]
                    local ok = ev and pcall(function() pa.w[ev](pa.w) end)
                    T.bridged.accept = T.bridged.accept + 1
                    T.focusAt = now + 300
                    U.log(TAG, "P%s's A in the garage -> %s: %s", tostring(T.pnum), sub, ok and "ok" or "failed")
                    return
                end
            end
        end
    end
    local pt = T.pend.tab
    if pt and now - pt.at >= BRIDGE_MS then
        T.pend.tab = nil
        if not U.alive(pt.tl) then
            -- its screen closed meanwhile: nothing to step
        elseif selectedTab(pt.tl) ~= pt.id then
            T.native.tab = T.native.tab + 1
        else
            local ok, id = stepTab(pt.tl, pt.dir)
            T.bridged.tab = T.bridged.tab + 1
            T.expectTab = { k = pt.k, id = id, at = now }
            if T.tabWatch and T.tabWatch.k == pt.k and ok then T.tabWatch.id = id end
            U.log(TAG, "P%s's %s in the garage -> tab %s: %s", tostring(T.pnum), pt.dir > 0 and "RB" or "LB", tostring(id),
                ok and "ok" or "failed")
        end
    end
    watchTabs(e, p1, now)
    T.last = { k = e.k, w = e.w, cls = e.cls, seq = couch().csmSeq() }
    -- (one sink check per tick: at the top; a screen a bridge opened is checked at the next tick, 33 ms later)
    -- his focus: user 1 (P1's PC holds his pad id) gets one inside the top screen whenever it holds none, and on the
    -- new page after a tab change (the page's activation focuses user 0 = P1's sunk pad; his stays on the hidden page)
    local tl = tabList(e.w)
    local pageKey = tostring(e.k) .. "/" .. tostring(tl and selectedTab(tl) or "")
    local newPage = T.focusPage ~= pageKey
    -- LIVE 2026-10-16 (livetest-combo, g2-*): after a bridged RB / LB no option entry of the new page held his focus
    -- (every entry's HasAnyUserFocus false; the first sight of a page logged "focus on FuseListView": the page had not
    -- generated its entry widgets yet, the LIST got the focus and the screen "held" it) -> his D-pad / A dead on the
    -- new tab, the LOCKED toast never showed. Every new option page (a tab change, bridged or native, a sub-screen
    -- entered) now wants an ENTRY: the equipped one (else the first) gets his focus, re-checked every ENTRY_RETRY_MS
    -- until an entry holds it (at most ENTRY_TRIES tries).
    if newPage then
        T.focusPage = pageKey
        lockTick(e, now, true)
        T.entryWant = (e.cls ~= ROOT_CLS) and { key = pageKey, tries = 0, at = now } or nil
    end
    local ew = T.entryWant
    if ew and ew.key == pageKey then
        if now < ew.at then return end
        ew.at = now + ENTRY_RETRY_MS
        if ew.tries > 0 and entryFocused(e, p1) then
            T.entryWant = nil
            if ew.tries > 1 then
                U.log(TAG, "P%s's focus on an option of %s after %d tries", tostring(T.pnum), pageKey, ew.tries)
            end
            return
        end
        if ew.tries >= ENTRY_TRIES then
            T.entryWant = nil
            U.warn(TAG, "P%s: no option entry of %s took his focus in %d tries (his D-pad may be dead on this page)",
                tostring(T.pnum), pageKey, ew.tries)
            return
        end
        ew.tries = ew.tries + 1
        local tgt = listTarget(e.w, true)
        if not U.ok(tgt) then return end                     -- the page's entries are not generated yet
        local ok = pcall(function() tgt:SetUserFocus(p1) end)
        if T.focusLogged ~= pageKey then
            T.focusLogged = pageKey
            U.log(TAG, "P%s drives %s: focus on %s (%s)", tostring(T.pnum), pageKey, U.className(tgt), ok and "ok" or "failed")
        end
        T.focusAt = now + 400
        return
    end
    if not newPage and now < (T.focusAt or 0) then return end
    T.focusAt = now + 400
    local holds = false
    if not newPage then pcall(function() holds = e.w:HasUserFocusedDescendants(p1) == true end) end
    if holds then return end
    local tgt = focusTarget(e)
    local ok = pcall(function() tgt:SetUserFocus(p1) end)
    if T.focusLogged ~= e.k then
        T.focusLogged = e.k
        U.log(TAG, "P%s drives %s: focus on %s (%s)", tostring(T.pnum), e.cls, U.className(tgt), ok and "ok" or "failed")
    end
end

-- his pad gone for good (join's device state): the garage closes, the turn ends with what he saved
local function padGone(now)
    local present = nil
    pcall(function() present = U.mod("join").padPresent(T.ctrlId) end)
    if present ~= false then T.goneSince = nil; return false end
    T.goneSince = T.goneSince or now
    return now - T.goneSince >= 3000
end

-- 8. (FAST, paddock) a deactivated root still visible after a turn -> collapsed; a collapsed one the game activates
-- again -> its visibility back. "Activated" = listed by couch's shared screen scan (activated screens only), so the root
-- gets no UFunction while it is not on screen except the one GetVisibility / SetVisibility of the hide (it was drawn a
-- moment ago); nothing in couch's quiet window (world changes: the 2026-10-14 crashes).
local function activeKeys()
    local t = {}
    pcall(function() for _, e in ipairs(couch().activeScreens()) do if e.cls == ROOT_CLS then t[e.k] = e.w end end end)
    return t
end
function M.leftRootTick(now)
    local quiet = false
    pcall(function() quiet = couch().isQuiet() == true end)
    if quiet then return end
    local act = activeKeys()
    for k, h in pairs(leftRoot.hidden) do
        if h.world ~= St.worldGen then
            leftRoot.hidden[k] = nil
        elseif act[k] then
            leftRoot.hidden[k] = nil
            local ok = pcall(function() act[k]:SetVisibility(h.vis) end)
            U.log(TAG, "the garage root is activated again (the game reuses it): visibility %s back (%s)", tostring(h.vis),
                ok and "ok" or "failed")
        end
    end
    local p = leftRoot.pending
    if not p then return end
    if p.world ~= St.worldGen or now > p.untilMs or not U.alive(p.w) then leftRoot.pending = nil; return end
    if act[p.k] then return end                         -- still (or again) the game's: wait (until the deadline)
    leftRoot.pending = nil
    local v = nil
    pcall(function() v = p.w:GetVisibility() end)
    if v == VIS.Visible or v == VIS.HitTestInvisible or v == VIS.SelfHitTestInvisible then
        local ok = pcall(function() p.w:SetVisibility(VIS.Collapsed) end)
        if ok then leftRoot.hidden[p.k] = { vis = v, world = p.world } end
        U.log(TAG, "the garage root %s stayed visible after the turn (deactivated): collapsed (%s)", ROOT_CLS,
            ok and "ok" or "failed")
    end
end
M._leftRoot = leftRoot                                   -- tests

---------------------------------------------------------------------------------------------------- 9. the game's exit
-- (couch-livefix r4) HOW THE GAME LEAVES ITS GARAGE (decoded 2026-10-16, cue4cli --script + kismet2txt, static):
--   WBP_Paddock_VehicleCust_C OnCancelAction (its B: RegisterActionBinding(IA_UI_Cancel)) = Play2DAudioFromTable
--   (MainBack), OwningStateMachine:ChangeToState(CSM_VehicleCustomisation_Idle, "Exiting specific vehicle
--   customisation "), every CstStaticVehicle:UpdateCustomisationMesh() (the paddock's parked vehicle re-reads P1's
--   garage), the customisation pawn's StopEngine(). Leaving CSM_VehicleCustomisation_Active ends ITS state actions:
--   CsmActionSwitchToCamera (tag VehicleCustomisationCamera, RestoreViewTargetOnEnd: P1's view back on his paddock
--   pawn), the data layers (customisation lighting off, paddock lighting back), CsmActionEnableInteractionPoints(false)
--   (the paddock's interactions back) and, from its child states, BP_Csm_EnabledVehicleCustomisationInput's stop
--   (IMC_Customisation, priority 2000, off the machine's local PC; its audio listener override cleared). Nothing else
--   (no input-mode or SetViewTarget call of its own): the machine's Idle IS the exit.
--   9a44ffd's bridge called the root's FuseScreenWidget BackToPreviousState instead: its back state
--   (Customise_VehicleSelect, the front end's) does not exist in the standalone garage machine - the root deactivated,
--   the machine STAYED Active: live round 3 the root drawn over the paddock, round 4 (root collapsed) the garage camera
--   on P1's landspeeder and IMC_Customisation over P1's sticks / B / START until the event map changed state.
-- At a turn end (M.finish, P1's car restored, pad ids back): the machine still Active (or unreadable with a garage
-- screen up) -> the root's own OnCancelAction (else the machine -> Idle with the game's reason + StopEngine); the parked
-- vehicles re-meshed when the root's exit did not do it after the restore. Then verified for EXIT_MS (machine not
-- Active, P1's view = his pawn, IMC_Customisation off P1's PC, the root not activated); still wrong at the deadline:
-- one fallback per wrong item (machine -> Idle, SetViewTargetWithBlend(his pawn), RemoveMappingContext, and the
-- section 8 collapse of a root left drawn), then one last check.

-- CSM_VehicleCustomisation_Active running? true / false / nil (unreadable)
local function garageActive()
    local act = U.obj(CSM_GARAGE_ACTIVE)
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    if not (U.ok(act) and U.ok(mgr)) then return nil end
    local r = nil
    pcall(function() r = mgr:IsStateActiveByRef(act) end)
    if type(r) ~= "boolean" then return nil end
    return r
end
M._garageActive = garageActive

local function stateStr(a) if a == nil then return "unreadable" end; return a and "Active" or "Idle" end

-- P1's view target: true (his pawn), false (not his pawn / the garage camera), nil (unknown), its class
local function p1View(p1)
    local vt, pw = nil, nil
    pcall(function() vt = p1:GetViewTarget() end)
    pcall(function() pw = p1.Pawn end)
    if not U.ok(vt) then return nil, "unreadable" end
    local d = U.className(vt)
    if U.ok(pw) then return U.key(vt) == U.key(pw), d end
    local cam = false
    pcall(function() cam = vt:ActorHasTag(U.fname(CAM_TAG)) == true end)
    if cam then return false, d end
    return nil, d
end

local function findL(p)
    if type(U.findLoaded) == "function" then return U.findLoaded(p, 1000) end
    local o = U.obj(p)
    return U.ok(o) and o or nil
end
local IMC_OUT = (St.outParams or function(t) return t end)({})            -- HasMappingContext's out table, reused

-- IMC_Customisation on P1's PC: true / false / nil (unreadable or not loaded), the subsystem, the IMC
local function custImc(p1)
    local imc, cls = findL(IMC_CUST), findL(EI_CLASS)
    if not (imc and cls) then return nil end
    local sub = nil
    pcall(function() sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(p1, cls) end)
    if not U.ok(sub) then return nil end
    local out = IMC_OUT
    out.OutFoundPriority = nil
    local has = nil
    pcall(function() has = sub:HasMappingContext(imc, out) == true end)
    if St.dropOutRefs then St.dropOutRefs(out) end
    return has, sub, imc
end

-- every parked CstStaticVehicle re-reads P1's garage (the root's exit does it; a turn end without it does it here)
local function remeshStatic()
    local n = 0
    for _, v in ipairs(FindAllOf("CstStaticVehicle") or {}) do
        if U.alive(v) and pcall(function() v:UpdateCustomisationMesh() end) then n = n + 1 end
    end
    return n
end

-- the game's own exit -> ok, how, viaRoot
function M.exitGarage(rootW)
    if U.alive(rootW) then
        local ok = pcall(function() rootW:OnCancelAction(U.fname(IA_BACK)) end)
        if ok then return true, "the root's own OnCancelAction", true end
    end
    local m, err = garageMachine()
    local idle = U.obj(CSM_GARAGE_IDLE)
    if not (m and U.ok(idle)) then return false, tostring(err or "Idle state not loadable"), false end
    local ok = pcall(function() m:ChangeStateTo(idle, EXIT_REASON, nil) end)
    local p = pawn()
    if p then pcall(function() p:StopEngine() end) end
    return ok, "garage machine -> Idle (the root's reason)", false
end

-- the root still drawn after the exit: section 8's collapse (last resort; leftRootTick only hides a visible,
-- deactivated root)
local function armCollapse(x)
    if not (x.w and x.k) or opt("CouchGarageHideRoot", true) == false or not U.alive(x.w) then return end
    leftRoot.pending = { untilMs = St.nowMs() + 1500, world = x.world, w = x.w, k = x.k }
end

function M.exitAfterTurn(t, why)
    local now = St.nowMs()
    local active = garageActive()
    local root, sub = garageScreens()
    local rootW = (root and root.w) or t.rootW
    local ok, how, viaRoot = true, "the game had left its garage already", false
    if active == true or (active == nil and (root or sub)) then ok, how, viaRoot = M.exitGarage(rootW) end
    -- the parked vehicle shows P1's restored car (a game-closed garage re-meshed it BEFORE the restore: his car)
    local n = viaRoot and 0 or remeshStatic()
    exitWatch = { untilMs = now + EXIT_MS, nextAt = now, world = St.worldGen, w = rootW, k = rootW and U.key(rootW) or t.rootK,
                  why = why, how = how, stage = 1, sawIdle = active == false }
    U.log(TAG, "P%s's turn over (%s): garage exit = %s (%s; machine was %s)%s", tostring(t.pnum), tostring(why), how,
        ok and "ok" or "FAILED", stateStr(active), viaRoot and "" or string.format("; %d parked vehicle(s) re-meshed", n))
end

function M.exitWatchTick(now)
    local x = exitWatch
    if not x then return end
    if x.world ~= St.worldGen or T then exitWatch = nil; return end      -- the world went / a new turn: not ours
    local quiet = false
    pcall(function() quiet = couch().isQuiet() == true end)
    if quiet or now < x.nextAt then return end
    x.nextAt = now + EXIT_POLL_MS
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local active = garageActive()
    if active == false then x.sawIdle = true end
    if active == true and x.sawIdle then
        exitWatch = nil
        U.log(TAG, "garage exit verified up to Idle; the garage is Active again (P1's own garage): watch ended")
        return
    end
    local view, vdesc = p1View(p1)
    local imc = custImc(p1)
    local rootAct = false
    if x.k then pcall(function() rootAct = activeKeys()[x.k] ~= nil end) end
    local function state()
        return string.format("machine %s, P1's view %s (%s), IMC_Customisation %s, root %s", stateStr(active),
            view == true and "his pawn" or (view == false and "NOT his pawn" or "unknown"), tostring(vdesc),
            imc == nil and "unreadable" or (imc and "ON" or "off"), rootAct and "ACTIVE" or "not active")
    end
    if active ~= true and view ~= false and imc ~= true and not rootAct then
        exitWatch = nil
        U.log(TAG, "garage exit verified (%s, exit %s): %s", tostring(x.why), tostring(x.how), state())
        armCollapse(x)
        return
    end
    if now < x.untilMs then return end
    if x.stage == 2 then
        exitWatch = nil
        U.warn(TAG, "garage exit NOT clean after the fallbacks (%s): %s", tostring(x.why), state())
        return
    end
    local did = {}
    if active == true then
        local m = garageMachine()
        local idle = U.obj(CSM_GARAGE_IDLE)
        if m and U.ok(idle) and pcall(function() m:ChangeStateTo(idle, EXIT_REASON, nil) end) then did[#did + 1] = "machine -> Idle" end
    end
    if view == false then
        local pw = nil
        pcall(function() pw = p1.Pawn end)
        if U.ok(pw) and pcall(function() p1:SetViewTargetWithBlend(pw, 0.0, 0, 0.0, false) end) then
            did[#did + 1] = "view -> his pawn"
        end
    end
    if imc == true then
        local _, s, i = custImc(p1)
        if s and pcall(function() s:RemoveMappingContext(i, {}) end) then did[#did + 1] = "IMC_Customisation removed" end
    end
    armCollapse(x)
    U.warn(TAG, "garage exit NOT clean %.1f s after the turn (%s, exit %s): %s -> fallbacks: %s", EXIT_MS / 1000,
        tostring(x.why), tostring(x.how), state(), #did > 0 and table.concat(did, ", ") or "none possible")
    x.stage, x.untilMs = 2, now + 1000
end

---------------------------------------------------------------------------------------------------- P1's own garage
-- FINDING #6 (live 2026-10-17, garage-p1-customize.png): P1's OWN paddock garage ("Customize ...") showed a speeder bike
-- while P1's run class is the landspeeder (Car, CampaignRun.MainVehicleType 0). With a guest joined every native screen
-- belongs to the LAST local PC (the garage root WBP_Paddock_VehicleCust_C was "guest-owned", log 17:40:58). The game's
-- load / save stay the FIRST local player's (P1's CstSubsystem, decoded SaveCustomisationRecipes).
-- FINDING #26 (round 2, 18:48): the first guard (switch the pawn to the RUN class, reload until the model is the run
-- class' first slot) FOUGHT THE SCREEN: "shows class 2 (Bike), his run class is 0 (Car): switched" + three reloads
-- (Tarpon vs Beluga). Live reads (test.cmd, 2026-10-17 20:51): CampaignRun.MainVehicleType 0, PaddockGameState
-- .PreRunChosenVehicleType 0, PlayerRacer.Build.VehicleBuilds = one build per class (0 1 2 3) - the run class read was
-- right; the PADDOCK offers a garage per parked class (PaddockVehicleSpawner vehicleType 2 = the speeder bike, its
-- "Customize speeder bike" interaction): the class the garage opens on is the GAME's choice (the vehicle P1 walked to),
-- never a fault. Two slots per class: the model shown may be either of them (Tarpon = P1's 2nd Car slot).
-- GUARD (cfg.CouchP1GarageGuard, default OFF since #26), while no guest turn runs:
--   * the class is never touched: the reference is the class the game's garage SHOWS (ActiveRecipe.VehicleArchetype);
--     the run class is logged for information only;
--   * the shown model must be one of P1's two slots of THAT class (by the slots' own VehicleArchetype). A model that is
--     not, read the SAME at two checks (open / +0.5 s / +1.5 s: the screen's Construct may change it after the first
--     sight), is reloaded from P1's slots ONCE per visit; the next check only reports. Never a class switch, never a
--     second reload (no loop).
--   * snapshots at the open: P1's 8 slots and every joined guest's CstSubsystem slots. At the close: a guest's slot
--     or P1's slot of ANOTHER class than the one shown that changed is put back (+ P1's garage saved).
-- FINDING #4 (C): when P1 leaves his own garage, each joined guest in turn is offered his native garage turn right there
-- (cfg.CouchGarageOffer): a hint under his chip "P2: PRESS A FOR YOUR GARAGE" / "B: NO THANKS"; A = M.start (the
-- native turn, the compact garage only if it cannot start), B / CouchGarageOfferMs = the next guest.
local P1V = nil                 -- P1's visit { k, at, arch, snapP1, snapG = { [pnum] = {pc, slots} }, checks }
local OFFER = nil               -- { queue, i, cur, at, prevA, prevB, turn, turnEndAt }
local lastTurnEnd = -1e12
local function guestsList()
    local ok, gl = pcall(function() return U.mod("join").joinedList() end)
    return (ok and type(gl) == "table") and gl or {}
end
local function readAll(sub)
    local out = {}
    if not sub then return out end
    pcall(function()
        local datas = sub.VehicleRecipeDatas
        for idx = 1, datas:GetArrayNum() do out[idx] = readSlot(datas[idx]) end
    end)
    return out
end
local function p1RunArch()
    local a = nil
    pcall(function() a = tonumber(U.mod("couchrun").campaignArch()) end)
    return a
end
local function shownModel()
    local comp = component()
    local n = nil
    if comp then pcall(function() n = str(comp.ActiveRecipe.RecipeName) end) end
    if n == "None" or n == "" then n = nil end
    return n
end

-- pure: P1's slot models of class arch (by each slot's own VehicleArchetype; slot index (i - 1) // 2 when unreadable)
function M.classModels(slots, arch)
    local out = {}
    for idx, sl in pairs(slots or {}) do
        local cls = (type(sl) == "table" and sl.VehicleArchetype) or (idx - 1) // 2
        if cls == arch and type(sl) == "table" and sl.RecipeName then out[#out + 1] = sl.RecipeName end
    end
    table.sort(out)
    return out
end

-- pure: one guard check of a visit v ({ snapP1, prev = {arch, model}, reloaded, done }) against the class / model the
-- garage shows -> "ok" | "wait" (first sight of a mismatch, or unreadable) | "reload" (the mismatch read twice, no
-- reload yet) | "gaveup" (still wrong after the one reload: reported, never acted on again)
function M.guardDecide(v, arch, model)
    if arch == nil or model == nil then return "wait" end
    local mine = M.classModels(v.snapP1, arch)
    if #mine == 0 then return "ok" end                                  -- no slot of that class read: nothing to compare
    for _, m in ipairs(mine) do if m == model then return "ok" end end
    if v.reloaded then return "gaveup" end
    local p = v.prev
    if p and p.arch == arch and p.model == model then return "reload" end
    return "wait"
end

-- the pawn shows one of P1's own models of the class the game opened -> fixes made (at most one per visit)
local function guardCheck(v, why)
    if opt("CouchP1GarageGuard", false) ~= true or v.done then return 0 end
    local arch, model = activeArch(), shownModel()
    local d = M.guardDecide(v, arch, model)
    v.prev = { arch = arch, model = model }
    if d == "reload" then
        v.reloaded = true
        local ok = reload()
        v.fixes = (v.fixes or 0) + 1
        U.warn(TAG, "P1's own garage (class %s %s, the game's choice) shows the model %s, P1's %s slots hold %s [%s]: "
            .. "reloaded ONCE from his slots (%s, now %s)", tostring(arch), archName(arch), tostring(model), archName(arch),
            table.concat(M.classModels(v.snapP1, arch), " / "), tostring(why), ok and "ok" or "FAILED", tostring(shownModel()))
        return 1
    elseif d == "gaveup" then
        v.done = true
        U.warn(TAG, "P1's own garage still shows the model %s after the one reload (P1's %s slots: %s) [%s]: left as "
            .. "the game shows it (no second reload)", tostring(model), archName(arch),
            table.concat(M.classModels(v.snapP1, arch), " / "), tostring(why))
    elseif d == "ok" and v.reloaded and not v.done then
        v.done = true
        U.log(TAG, "P1's own garage shows his own %s model %s after the reload [%s]", archName(arch), tostring(model),
            tostring(why))
    end
    return 0
end

local function guardOpen(root, now)
    local v = { k = root.k, at = now, runArch = p1RunArch(), arch = activeArch(), checks = 0, snapG = {} }
    v.snapP1 = readAll(cstOf(U.p1()))
    for _, g in ipairs(guestsList()) do
        local sub = cstOf(g.pc)
        if sub then v.snapG[g.pnum] = { pc = g.pc, slots = readAll(sub) } end
    end
    local pawns = 0
    pcall(function() for _, a in ipairs(FindAllOf("BP_CstPawn_C") or {}) do if U.ok(a) then pawns = pawns + 1 end end end)
    local owner = "?"
    pcall(function()
        local o = root.w:GetOwningPlayer()
        for i, e in ipairs(U.localPlayers()) do if U.ok(o) and U.key(e.pc) == U.key(o) then owner = "local player " .. i end end
    end)
    local n = 0
    for _ in pairs(v.snapP1) do n = n + 1 end
    U.log(TAG, "P1's own garage open (owner %s, %d customisation pawn(s)): class shown %s (the game's choice; run class "
        .. "%s, info only), model %s; %d slot(s) of P1 + %d guest garage(s) snapshot; guard %s", owner, pawns,
        tostring(v.arch), tostring(v.runArch), tostring(shownModel()), n,
        (function() local c = 0; for _ in pairs(v.snapG) do c = c + 1 end; return c end)(),
        opt("CouchP1GarageGuard", false) == true and "on" or "off")
    guardCheck(v, "open")
    return v
end

-- the visit's end: only P1's slots of his class may have changed
local function guardClose(v)
    if opt("CouchP1GarageGuard", false) ~= true then
        U.log(TAG, "P1's own garage closed (guard off: nothing compared, nothing put back)")
        return
    end
    if v.prev and v.prev.arch ~= nil then v.arch = v.prev.arch end      -- the class the game showed last
    local back, lines = 0, {}
    local function putBack(sub, snap, idx, who)
        pcall(function()
            local el = sub.VehicleRecipeDatas[idx]
            local ok = writeSlot(el, backupTable(snap.VehicleArchetype or (idx - 1) // 2, snap))
            if ok then writeParts(el, snap.units) end
            back = back + 1
            lines[#lines + 1] = string.format("%s slot %d (%s)", who, idx, ok and "put back" or "NOT put back")
        end)
    end
    local sub = cstOf(U.p1())
    if sub and v.arch ~= nil then
        local now = readAll(sub)
        for idx, snap in pairs(v.snapP1 or {}) do
            local cls = (idx - 1) // 2
            if cls ~= v.arch and now[idx] and #M.slotDiff(snap, now[idx]) > 0 then putBack(sub, snap, idx, "P1's other-class") end
        end
    end
    for pnum, g in pairs(v.snapG or {}) do
        local gs = cstOf(g.pc)
        if gs then
            local now = readAll(gs)
            for idx, snap in pairs(g.slots) do
                if now[idx] and #M.slotDiff(snap, now[idx]) > 0 then putBack(gs, snap, idx, "P" .. tostring(pnum) .. "'s") end
            end
        end
    end
    if back > 0 then
        reload()
        local saved = saveRecipes()
        U.warn(TAG, "P1's own garage closed: %d slot(s) outside P1's class changed and were put back (%s); P1's garage "
            .. "saved %s", back, table.concat(lines, ", "), saved and "ok" or "FAILED")
    else
        U.log(TAG, "P1's own garage closed: only P1's %s slots may have changed; every guest garage and P1's other "
            .. "classes untouched (%d fix(es) during the visit)", archName(v.arch or 0), v.fixes or 0)
    end
end

local function offerHint(g)
    local ok, cp = pcall(U.mod, "couchpanel")
    if not (ok and type(cp) == "table" and cp.garageOfferShow) then return false end
    local okS, r = pcall(cp.garageOfferShow, g, string.format("P%d: PRESS A FOR YOUR GARAGE", g.pnum), "B: NO THANKS")
    return okS and r == true
end
local function offerHintClose()
    local cp = package.loaded["couchpanel"]
    if type(cp) == "table" and cp.garageOfferClose then pcall(cp.garageOfferClose) end
end

local function offerEnd(why)
    if not OFFER then return end
    offerHintClose()
    U.log(TAG, "guest garage offers over (%s)", tostring(why))
    OFFER = nil
end
M.offerEnd = offerEnd

local function offerNext(now)
    offerHintClose()
    OFFER.i = OFFER.i + 1
    local g = OFFER.queue[OFFER.i]
    if not g then offerEnd("every guest asked"); return end
    OFFER.cur, OFFER.at, OFFER.prevA, OFFER.prevB, OFFER.turn = g, now, true, true, nil
    local shown = offerHint(g)
    U.log(TAG, "P%d: PRESS A FOR YOUR GARAGE (offered after P1's own garage; B = no thanks; hint %s)", g.pnum,
        shown and "up" or "NOT drawn")
end

local function offerStart(now)
    if opt("CouchGarageOffer", true) == false or opt("CouchGarageNative", true) ~= true then return end
    local gl = guestsList()
    if #gl == 0 then return end
    OFFER = { queue = gl, i = 0 }
    offerNext(now)
end

local function padOf(g)
    local pc = nil
    pcall(function() pc = U.mod("couchpanel").kit.padPC(g.ctrlId) end)
    return U.ok(pc) and pc or g.pc
end

local function offerTick(now)
    if not OFFER then return end
    if T then return end                                         -- his turn runs
    if OFFER.turn then                                           -- his turn ended: the next guest
        if now - lastTurnEnd >= 1500 then offerNext(now) end
        return
    end
    local g = OFFER.cur
    if not g then return end
    local menu = false
    pcall(function() menu = couch().menuOver() == true end)
    if menu then offerEnd("a menu opened"); return end
    if P1V then offerEnd("P1 opened his garage again"); return end
    local still = false
    for _, e in ipairs(guestsList()) do if e.ctrlId == g.ctrlId then still = true end end
    if not still then U.log(TAG, "P%d left: no garage offer", g.pnum); offerNext(now); return end
    if now - OFFER.at >= (tonumber(opt("CouchGarageOfferMs", 15000)) or 15000) then
        U.log(TAG, "P%d's garage offer withdrawn (no answer in %d s)", g.pnum, math.floor((now - OFFER.at) / 1000))
        offerNext(now)
        return
    end
    local pc = padOf(g)
    local ui = U.mod("ui")
    local a = ui.keyDown(pc, "Gamepad_FaceButton_Bottom")
    local b = ui.keyDown(pc, "Gamepad_FaceButton_Right")
    local aEdge, bEdge = a and not OFFER.prevA, b and not OFFER.prevB
    OFFER.prevA, OFFER.prevB = a, b
    if bEdge then
        U.log(TAG, "P%d declines his garage (B)", g.pnum)
        offerNext(now)
    elseif aEdge then
        offerHintClose()
        local arch = nil
        pcall(function() arch = U.mod("couchrun").archOf(g.ctrlId, g.pnum) end)
        local ok = M.start(g, arch)
        if ok then
            OFFER.turn = true
            U.log(TAG, "P%d's A: his native garage turn starts (offered after P1's own garage)", g.pnum)
        else
            local okC = false
            pcall(function() okC = U.mod("couchpanel").garageCompact({ g }, "his native garage turn could not start") == true end)
            U.warn(TAG, "P%d's native garage turn could not start: %s", g.pnum,
                okC and "the compact garage instead" or "no garage (compact not opened either)")
            offerEnd("P" .. g.pnum .. "'s native turn refused")
        end
    end
end

-- couch-fix74 (player report v1.0.2 #1: "P2 cannot customize their vehicle in the Couch Campaign. The guest garage
-- doesn't seem to work for us"). The guests' garage turn was ONLY offered right after P1 had been in his OWN paddock
-- garage (FINDING #4 C), for 15 s, once: a couple who never opens P1's garage never sees a way to P2's car (the
-- run-map GARAGE hint is off since FINDING #10). The game's garage BPs are unchanged in CL386500 (WBP_Paddock_
-- VehicleCust / SelectVehicleCust decoded from the 2026-10-22 paks: the same 28 / 15 functions, the same members).
-- STANDING OFFER (cfg.CouchGarageStanding): while the team walks the paddock (a PaddockGameState, nothing but HUDs
-- activated, pad ids normal, no pause menu, no turn / offer / P1 garage visit), the first guest's hint spot shows
-- "P2: HOLD A FOR YOUR GARAGE" (3-4 players: "P2-P4: ..."); a guest HOLDING his A for cfg.CouchGarageStandingHoldMs
-- starts his own native garage turn (M.start, as the offer's A). A hold, never a tap: a short A is the game's own.
local STAND = { since = nil, shown = false, down = {}, up = {}, warned = false }
local FREE_CLS = { "^WBP_Hud", "^WBP_HUD", "Paddock_HUD" }
-- pure: only HUD classes activated (the team walks the paddock)
function M.paddockFree(classes)
    for _, cn in ipairs(classes or {}) do
        local hud = false
        for _, pat in ipairs(FREE_CLS) do if tostring(cn):find(pat) then hud = true; break end end
        if not hud then return false end
    end
    return true
end
-- pure: the hint's text for the joined guests' numbers
function M.standingText(pnums)
    table.sort(pnums)
    if #pnums == 0 then return nil end
    local who = (#pnums == 1) and ("P" .. pnums[1]) or ("P" .. pnums[1] .. "-P" .. pnums[#pnums])
    return who .. ": HOLD A FOR YOUR GARAGE"
end
local function standHide(why)
    if STAND.shown then
        if not OFFER then offerHintClose() end              -- the offer after P1's garage owns the hint now
        U.dbg(TAG, "standing garage hint hidden (%s)", tostring(why))
    end
    STAND.shown, STAND.since, STAND.down, STAND.up = false, nil, {}, {}
end
M._stand = function() return STAND end

-- couch-fix76 (AUTO-175, live 2026-10-24 13:05:52 / 13:06:35, after a REASSIGN CONTROLLERS): two garage turns of P2
-- started with nobody holding A (pad watch: both pads up). The guest PC's IsInputKeyDown(A) read true: a key state left
-- on a PlayerController whose ControllerId moved (the shared-screen swap / the garage hold / a reassignment move ids
-- while keys change) - the PlayerInput never saw that release. Now (1) the A must have been seen UP since the hint came
-- up (an A already down - stale, or the A that closed the last screen - is no hold), and (2) with the input DLL's pad
-- watch the PHYSICAL pad the guest holds (padmap: ident -> pad) must hold A too (cfg.CouchGarageStandingPadWatch).
local function standPhysDown(g)
    if opt("CouchGarageStandingPadWatch", true) == false then return nil end
    local IF = package.loaded["inputfix"]
    if not (type(IF) == "table" and type(IF.padWatch) == "function" and type(IF.padPresses) == "function") then return nil end
    local okW, on = pcall(IF.padWatch)
    if not (okW and on == true) then return nil end
    local pad = g.ctrlId
    local PM = package.loaded["padmap"]
    if type(PM) == "table" and type(PM.padOfIdent) == "function" then
        local okP, p = pcall(PM.padOfIdent, g.ctrlId)
        if okP and type(p) == "number" then pad = p end
    end
    local off = 0
    pcall(function() if U.GMS().bOffsetPlayerGamepadIds == true then off = 1 end end)
    local okR, pads = pcall(IF.padPresses)
    if not (okR and type(pads) == "table") then return nil end
    local e = pads[pad - off]
    if type(e) ~= "table" then return false end
    return ((tonumber(e.down) or 0) & 1) ~= 0
end

local function standFree(now)
    if opt("CouchGarageStanding", true) == false or opt("CouchGarageNative", true) ~= true then return false, "off" end
    if St.phase ~= "OTHER" then return false, "phase" end
    if T or OFFER or P1V or exitWatch then return false, "busy" end
    if now - lastTurnEnd < 2500 then return false, "turn just ended" end
    local okA, act = pcall(function() return couch().active() end)
    if not (okA and act == true) then return false, "couch rules off" end
    if not U.isA(U.gs(), "/Script/Griffin.PaddockGameState") then return false, "not the paddock" end
    local sw = false
    pcall(function() sw = couch().swapped() == true end)
    if sw then return false, "a guest-owned screen" end
    local menu = false
    pcall(function() menu = couch().menuOver() == true end)
    if menu then return false, "menu" end
    local cls = {}
    pcall(function() for _, e in ipairs(couch().activeScreens()) do cls[#cls + 1] = e.cls end end)
    if not M.paddockFree(cls) then return false, "a screen is up" end
    local cp = package.loaded["couchpanel"]
    if type(cp) == "table" and type(cp.isOpen) == "function" then
        local okO, o = pcall(cp.isOpen)
        if okO and o == true then return false, "a guest panel is open" end
    end
    return true
end

local function standTick(now)
    local free, why = standFree(now)
    if not free then if STAND.shown or STAND.since then standHide(why) end; return end
    local gl = guestsList()
    if #gl == 0 then standHide("no guest"); return end
    STAND.since = STAND.since or now
    if now - STAND.since < 1500 then return end              -- a screen that just closed: no flicker
    if not STAND.shown then
        local nums = {}
        for _, g in ipairs(gl) do nums[#nums + 1] = g.pnum end
        local first = gl[1]
        for _, g in ipairs(gl) do if g.pnum < first.pnum then first = g end end
        local ok, cp = pcall(U.mod, "couchpanel")
        local okS, r = false, false
        if ok and type(cp) == "table" and cp.garageOfferShow then
            okS, r = pcall(cp.garageOfferShow, first, M.standingText(nums), nil)
        end
        STAND.shown = okS and r == true
        if STAND.shown then
            U.log(TAG, "standing garage hint up in the paddock: %s", tostring(M.standingText(nums)))
        elseif not STAND.warned then
            STAND.warned = true
            U.warn(TAG, "standing garage hint NOT drawn (the guests' HOLD A still works)")
        end
    end
    local hold = tonumber(opt("CouchGarageStandingHoldMs", 800)) or 800
    local ui = U.mod("ui")
    for _, g in ipairs(gl) do
        local a = false
        pcall(function() a = ui.keyDown(padOf(g), "Gamepad_FaceButton_Bottom") == true end)
        local k = tostring(g.ctrlId)
        local phys = standPhysDown(g)
        if a and phys == false then
            if not STAND.ghost then
                STAND.ghost = true
                U.log(TAG, "P%d's PlayerController reads A down but his pad (pad watch) does not: a stale key state, no "
                    .. "garage hold (AUTO-175)", g.pnum)
            end
            a = false
        end
        if not a then STAND.down[k] = nil; STAND.up[k] = true
        elseif not STAND.up[k] then
            STAND.down[k] = nil                                     -- down since before the hint: release it first
        else
            STAND.down[k] = STAND.down[k] or now
            if now - STAND.down[k] >= hold then
                standHide("P" .. g.pnum .. " holds A")
                local arch = nil
                pcall(function() arch = U.mod("couchrun").archOf(g.ctrlId, g.pnum) end)
                local okT = M.start(g, arch, { heldA = true })
                if okT then
                    U.log(TAG, "P%d held A in the paddock: his native garage turn starts (standing offer)", g.pnum)
                else
                    local okC = false
                    pcall(function() okC = U.mod("couchpanel").garageCompact({ g }, "his native garage turn could not start") == true end)
                    U.warn(TAG, "P%d's native garage turn could not start (standing offer): %s", g.pnum,
                        okC and "the compact garage instead" or "no garage")
                end
                lastTurnEnd = now                                 -- no second start before the turn shows up
                return
            end
        end
    end
end

-- P1's own garage: seen activated (no guest turn), its end, then the offers
local function p1VisitTick(now)
    if St.phase ~= "OTHER" then P1V = nil; return end
    if exitWatch or now - lastTurnEnd < 2500 then return end    -- a guest turn's own exit is not P1's visit
    local root = garageScreens()
    if root then
        if not P1V or P1V.k ~= root.k then
            if #guestsList() == 0 then return end
            if OFFER then offerEnd("P1 opened his garage again") end
            P1V = guardOpen(root, now)
        end
        P1V.goneAt = nil
        if P1V.checks < 2 and now - P1V.at >= (P1V.checks == 0 and 500 or 1500) then
            P1V.checks = P1V.checks + 1
            guardCheck(P1V, string.format("+%d ms", math.floor(now - P1V.at)))
        end
        return
    end
    if not P1V then return end
    P1V.goneAt = P1V.goneAt or now
    if now - P1V.goneAt < 700 then return end
    local v = P1V
    P1V = nil
    U.try(TAG, guardClose, v)
    offerStart(now)
end
M._p1Visit = function() return P1V end
M._offer = function() return OFFER end

function M.fastTick()
    if exitWatch then U.try(TAG, M.exitWatchTick, St.nowMs()) end
    if leftRoot.pending or next(leftRoot.hidden) then U.try(TAG, M.leftRootTick, St.nowMs()) end
    if not T then
        U.try(TAG, p1VisitTick, St.nowMs())
        U.try(TAG, offerTick, St.nowMs())
        U.try(TAG, standTick, St.nowMs())                  -- couch-fix74 (#1): the paddock's standing offer
        return
    end
    if T.world ~= St.worldGen then M.finish("world changed"); return end
    if T.opened and T.seen and not couch().garageHeld() then M.finish("pad ids released (a player left)"); return end
    local now = St.nowMs()
    T.lastBack = T.lastBack or -1e12
    if not T.aborting and padGone(now) then
        T.aborting = true
        local ok = M.closeGarage("P" .. tostring(T.pnum) .. "'s pad disconnected")
        U.warn(TAG, "P%s's pad disconnected during his garage turn: garage closed (%s)", tostring(T.pnum), tostring(ok))
    end
    -- his B / LB / RB: edges of P1's PC's raw input (= his pad), read before anything compares screens (a CommonUI
    -- action that works acted at the key-down: this tick may already show its result)
    local p1 = U.p1()
    local acts, ltw = {}, {}
    if U.ok(p1) then acts, ltw = rawActs(p1) end
    -- his B as a key on P1's PlayerInput too (P1's PC holds his pad id during the turn: routed by ControllerId, his
    -- pad only): one more witness of his own back
    local bKey = false
    if U.ok(p1) then pcall(function() bKey = p1:IsInputKeyDown({ KeyName = U.fname(KEY_OF_IA[IA_BACK]) }) == true end) end
    -- couch-fix76 (AUTO-174, live 2026-10-24 11:22:57): the standing offer's held A. The engine hands his still-held A
    -- to P1's PC (now on his pad id) a few frames AFTER the id change: Triggered again while held -> an accept edge ->
    -- CHOOSE MODEL / THEME entered through the accept bridge. rel103's "A marked down" covered the first tick only. Now
    -- every A of the turn is ignored until his physical A has been up for HELD_A_SETTLE_MS (P1's PC IsInputKeyDown on his
    -- pad id, and the DLL's pad watch for his pad), at most cfg.CouchGarageHeldAMaxMs.
    if T.heldA then
        local h = T.heldA
        local down = false
        if U.ok(p1) then pcall(function() down = p1:IsInputKeyDown({ KeyName = U.fname(KEY_OF_IA[IA_ACCEPT]) }) == true end) end
        if not down then
            pcall(function()
                local IF = U.mod("inputfix")
                if IF.padWatch() then
                    local e = IF.padPresses()[(T.ctrlId or -1) - (U.GMS().bOffsetPlayerGamepadIds and 1 or 0)]
                    down = type(e) == "table" and ((tonumber(e.down) or 0) & 1) ~= 0
                end
            end)
        end
        if down then h.upAt = nil; h.seenDown = true else h.upAt = h.upAt or now end
        acts[IA_ACCEPT], ltw[IA_ACCEPT] = nil, nil
        local maxMs = tonumber(opt("CouchGarageHeldAMaxMs", 4000)) or 4000
        if (h.upAt and now - h.upAt >= HELD_A_SETTLE_MS) or now - h.since >= maxMs then
            U.log(TAG, "P%s's held A (the standing offer) %s after %d ms: his A works in the garage now (AUTO-174)",
                tostring(T.pnum), h.upAt and "released" or "still down: given up", math.floor(now - h.since))
            T.heldA = nil
        end
    end
    local edge = {}
    for _, n in ipairs({ IA_BACK, IA_PREV, IA_NEXT, IA_ACCEPT }) do
        local missed = T.ltw ~= nil and ltw[n] ~= nil and T.ltw[n] ~= nil and ltw[n] > T.ltw[n] + 1e-4
        local keyed = n == IA_BACK and bKey and not T.prevKeyB
        if ((acts[n] or missed) and not T.prev[n]) or keyed then
            edge[n] = true
            if n ~= IA_ACCEPT then T.lastPress = now end
            if n == IA_BACK then T.lastBack = now end
            if missed and not acts[n] then T.missed = (T.missed or 0) + 1 end
        end
    end
    T.prev, T.edge, T.ltw, T.prevKeyB = acts, edge, ltw, bKey
    local root, sub = garageScreens()
    if root then T.rootW, T.rootK = root.w, root.k end
    if root or sub then
        T.seen = true; T.goneAt = nil
        U.try(TAG, watchBack, root, sub or root, now)
        U.try(TAG, driveTick, now, root, sub)
        return
    end
    if not T.seen then
        if not T.opened and now - (T.tryAt or 0) >= 500 then
            T.tryAt = now
            local ok, how = M.openGarage()
            if ok then T.opened = true; U.log(TAG, "garage opened after the map closed (%s)", how) end
        end
        if now - T.at > 10000 then M.finish("the garage never came up") end
        return
    end
    T.goneAt = T.goneAt or now
    if now - T.goneAt < 700 then return end
    -- (couch-livefix r2) the garage closed because a pause menu / dialog opened (the paddock pause takes the garage
    -- machine down): never reopened under it - the turn ends (his saved choices kept), GARAGE again after the pause
    local menu = false
    pcall(function() menu = couch().menuOver() == true end)
    if menu then
        M.finish("garage closed: a pause menu opened")
        return
    end
    -- the garage closed without his B (P1's pad through CommonUI?): opened again, at most 2 times
    if not T.aborting and undoOn() and T.goneAt - T.lastBack > FOREIGN_SCREEN_MS and T.reopens < 2 then
        T.reopens = T.reopens + 1
        local ok = M.openGarage()
        T.goneAt = nil
        U.warn(TAG, "P%s's turn: the garage closed without his B (P1's pad?): opened again (%s)", tostring(T.pnum), tostring(ok))
        return
    end
    M.finish(T.aborting and "his pad disconnected" or "garage closed")
end

function M.status()
    if not T then return "garagenative: idle" .. (disabledWhy and (" (off this session: " .. disabledWhy .. ")") or "") end
    return string.format("garagenative: P%s's turn (%s), screen seen %s, bridged B %d tabs %d, undos %d/%d/%d",
        tostring(T.pnum), tostring(T.arch), tostring(T.seen), T.bridged.back, T.bridged.tab, T.tabsBack, T.reenters, T.reopens)
end

function M._reset()                                                                                   -- tests
    T = nil; disabledWhy = nil; repairClean = false; repairMem = false; leftRoot.pending = nil; leftRoot.hidden = {}
    exitWatch = nil; P1V = nil; OFFER = nil; lastTurnEnd = -1e12
end          -- tests

-- crash repair: a pending backup from an earlier session goes back as soon as P1's CstSubsystem exists
local repairAt = -1e12
function M.slowTick()
    if T or repairClean then return end
    if St.phase == "RACING" or St.phase == "PRERACE" or St.phase == "LOADING" then return end
    local now = St.nowMs()
    if now - repairAt < 5000 then return end
    repairAt = now
    local b = readBackup()
    if not (b and b.pending == true) then repairClean = true; return end
    if not cstOf(U.p1()) then return end
    if repairMem and not pawn() then return end          -- in memory already: waits for the garage pawn to save it
    repairMem = true
    local n = restore(b, "pending backup from an interrupted turn")
    U.warn(TAG, "interrupted garage turn repaired: %d slot(s) of P1's garage restored", n)
end

function M.init()
    St.on("phase", TAG .. ".offer", function(new)
        if new ~= "OTHER" then P1V = nil; if OFFER then offerEnd("phase " .. tostring(new)) end end
    end)
    -- safety net: a purchase during a guest's turn (the locks should make it impossible)
    pcall(function()
        U.hook("/Script/Griffin.CstVehicleRecipeUIData:TryToPurchaseOption", { post = function()
            if T then
                T.buys = T.buys + 1
                U.warn(TAG, "P%s's turn: TryToPurchaseOption ran on P1's profile (a lock missed)", tostring(T.pnum))
            end
        end }, TAG)
    end)
    U.log(TAG, "init: native guest garage turns %s (cfg.CouchGarageNative), exclusive %s, undo P1-pad actions %s",
        opt("CouchGarageNative", true) and "ON" or "off", tostring(opt("CouchGarageExclusive", true) ~= false),
        tostring(undoOn()))
end

return M
