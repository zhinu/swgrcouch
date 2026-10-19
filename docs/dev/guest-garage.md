# Guest garage: P2-P4 customise their own car (couch campaign, 0.15)

Jules 2026-10-15: "one thing missing is the customization of P2's car". Before this work a guest raced his class
with a preset body (`couch.guestVehicle`: the seat's default `PRE_*` preset on his grid entry). This file records what
the game does with a vehicle recipe, why the guests do not get a second copy of the game's Customize screens, and the
design that shipped on branch `couch-p2cust` (`garage.lua`, `custdata.lua`, the couchpanel kind `garage`).

All of it was found offline (static): runtime JMAP, the early `SWGR-Win64-Shipping.exe` (capstone, same layout as the
Steam build), the decoded Blueprints (`retoc to-legacy` + `scripts/kismet-disasm.py`) and the decoded data
(`cue4cli json`). Nothing below has been seen live yet: section 6 is the live checklist.

## 1. How the game stores and applies a vehicle recipe

### 1.1 The data
- `FCstSavedVehicleRecipeData` (0x60 bytes) {RecipeName FString @0, VehicleArchetype @0x10, UnitLayoutName @0x14,
  UnitRecipes TArray<FCstPresetRecipeUnit> @0x20, RootPhysicsConfiguration @0x30, LiveryPaletteTag @0x38,
  LiveryMaskTag @0x40, IconPaletteTag @0x48, IconMaskTag @0x50, PatinaTag @0x58}. A unit = {UnitName,
  VehicleArchetype, Parts[{ParentPartType, PartType, vehicleKit}], JellyConfiguration}: the kit parts (the model).
  The livery is five **gameplay tags**, never assets.
- `UCstVehiclePresetRecipe` (the `PRE_*` Blueprint classes) has exactly the same fields: a preset is a recipe.
  `FRecipeRacerSetup.VehicleCustomisation` (+0x80) holds such a CLASS; the 0x68 unreflected bytes before it
  (+0x18..+0x80) are the size of one saved recipe (race-setup.md section 11 asked about them; not needed here).
- `UCstSubsystem` is a **LocalPlayerSubsystem**: `VehicleRecipeDatas` (TArray of the struct, two slots per class:
  index = arch * 2 + (component +0x3E8 > 0)), the player's garage. `UCstSavedVehicleData` is its save object.
- The option catalogs: `DA_CstGlobalData` -> `LCD_LiveryCommon` (LiveryPaletteMap 61, PatinaMap 7, IconMaskMap 4,
  IconPaletteMap 5, each TMap<tag, option asset>) and `LAD_<Class>` (LiveryMaskMap: 23 car, 21 bike, 23 skimmer,
  14 pod templates). Option assets (`CstCustomisationOptionDataAsset`): ItemName, Cost, IsAvailableToPlayerByDefault,
  UnlockedBy, TagToUnlockWhenPurchased. Models: 37 `TH_<Model>` (`CstThemeData.presetRecipe` = `PRE_<Class>_<Model>`).
  Decals (IconMask) exist only for pods (Nesodon cockpit, Cretornis / Sordes engines).

### 1.2 How a human's car gets its recipe (native, exe addresses of the early copy)
- `PlayerVehicleCustomisationComponent::OnPawnSetCallback` impl `0x142FC7E64` (bound to the PlayerState's pawn-set
  delegate): owner must be a `GfnPlayerState`.
  - AI (`PlayerState +0x2BA & 8`, inferred to be the bot flag): the override class (+0xD8) if its archetype matches the pawn, else a random theme of
    the item registry; the recipe actor is spawned from the preset.
  - Human (pawn vfunc +0x818 true, inferred: locally controlled): with an override class (+0xD8, set by
    `Client_SetOverrideVehicleRecipe` impl `0x142FC704E`, which only stores it) -> `0x140B1CFA0` builds the saved
    struct from the class CDO -> `0x144637A90` = **`Server_UpdateVehicleRecipe(struct)`**. Without one ->
    `0x142F6E14A(customisationComponent, arch)` = `FirstLocalPlayer(world)->CstSubsystem->VehicleRecipeDatas[arch*2 +
    flag]` -> the same upload. So **a guest with no preset races P1's garage car**.
- `Server_UpdateVehicleRecipe` (exec `0x14465007A`, impl `0x140CA57F4`): owner IsA GfnPlayerState -> spawn a
  `CstVehicleRecipe` actor, `0x144D18D84(actor, &struct)` (init from the struct), store it in `VehicleRecipe` (+0xC0),
  mark it replicated (`0x1409E5BD0`), then if `PlayerState.PawnPrivate` (+0x328, inferred) is a vehicle: pawn vfunc +0x738 and
  `0x142FC7B5C` (apply the recipe to the pawn) when the recipe has units with parts. The car is **rebuilt**.
- `OnRep_VehicleRecipe` (exec `0x1470CA3A0` -> `0x142FC7184`): re-applies the current recipe actor to the pawn
  (the same `0x142FC7B5C` path).
- `CstCustomisationComponent::RefreshRecipe` (`0x142F67016`): resets dirty flags of the ActiveRecipe and rebuilds.

### 1.3 How the Customize screens edit it (why a guest copy is unsafe)
- `WBP_Paddock_VehicleCust` (Choose Model / Edit Vehicle / Edit Livery), `..ThemeOptions`, `..LiveryOptions`,
  `WBP_CustomisationOptionView` all reach the vehicle through `BPFL_CustomisationFunctionLibrary`:
  `FindCustomisationPawn` = `GetAllActorsOfClass(BP_CstPawn_C)[0]` and `FindCustomisationComponent` = its
  `CustomisationComponent` (decoded bytecode). **One** customisation pawn in the front end, the first one found.
- A selection goes through `CstCustomisationComponent:UpdateUISelection(type, item, index)` on that component; the
  livery screen calls `VehicleCustomisationPawn:ReloadRecipe()`.
- `CstCustomisationComponent::SaveCustomisationRecipes` (exec `0x14704CA1A` -> `0x142F6DEE0`): `0x1409AA663(world)` =
  the **first local player's** `CstSubsystem` (LocalPlayer +0x138 subsystem collection), writes
  `VehicleRecipeDatas[idx]` from the ActiveRecipe and saves. Never the owning player's.
- couchprerun.lua already found the same for `WBP_PreRun_VehicleSelect_C`: its Construct / OnVehicleFocused call
  `SetSelectedVehicleArchetype` on P1's customisation pawn.
=> A second instance of those screens for a guest edits P1's front-end vehicle and saves into P1's garage. The project
rule (reuse the game's own screens per player, never write P1's data from a guest copy) rules it out: the guests get
a compact game-style picker instead, and their recipe goes to their car through the game's own upload RPC.

### 1.4 UE4SS marshalling of the upload (source at the shipped commit 3f4037d2)
`comp:Server_UpdateVehicleRecipe(t)` with a Lua table: `push_structproperty` -> `convert_lua_table_to_struct`;
the `UnitRecipes` field given as the preset CDO's **TArray userdata** takes `push_arrayproperty`'s userdata branch:
`AddZeroed` + `CopySingleValueToScriptVM` per element = a deep copy of the units and their parts through the property
(the Lua-table branch for arrays of structs reads `lua_rawlen(L, 1)` and is avoided). Tags go as `{TagName = FName}`
(the FKey pattern the mod already uses), FName / string / enum / object fields as usual. The param buffer is zeroed,
not constructed: an empty TArray is valid there; at worst the copied arrays leak once per upload.

## 2. Design

- **Data**: `custdata.lua` (generated by `tools/gen-custdata.py` from a cue4cli dump): templates per class, palettes
  with their three colours, patinas, pod decals, each preset's own tags, the themes, unlock data and asset paths.
- **Storage**: `garage.lua`, `Mods/SWGRCouch/guest-garage.txt`, per **seat** (P2-P4) and class: `model` (base model),
  `mask`, `palette`, `patina`, `decal` (pods). nil = the model preset's own value. Kept across runs and sessions; P1's
  CstSubsystem and save are never read for writing nor written.
- **Options**: `CouchGarageUnlocks = "p1"` offers what P1 owns: `CstOptionFunctionLibrary:IsOptionUnlockedAndPurchased(
  asset, P1's PC)` (the test the game's option view uses for "owned"), assets loaded once by path; unreadable =
  offered (one log line). `"all"` = everything. A stored value stays listed even if no longer owned.
- **Grid** (model): `couch.guestVehicle` writes the standard preset of his model (`garage.presetFor`) as
  `VehicleCustomisation`; the game's own possession upload then builds that model.
- **Race** (livery): `garage.raceTick` (MAIN loop, PRERACE / RACING of a couch race, not time trials): once the guest's
  pawn and recipe actor exist, compare the actor's tags with the fields HE set; on a difference upload
  `{RecipeName, VehicleArchetype, UnitLayoutName, UnitRecipes, RootPhysicsConfiguration from the model preset's CDO;
  the five tags}` with `Server_UpdateVehicleRecipe`, at most `CouchGarageTries` (3) per guest and world (a respawned
  car is rebuilt by the game from the preset: it gets the livery again). `CouchGarageApply = "tags"`: write the tags on
  his recipe actor and call `OnRep_VehicleRecipe()` instead; `"off"`: the model only.
- **UX**: on the run map each guest's hint row reads `GARAGE  (A) SHOP` under his credits chip; his D-pad moves
  between the two (the focused one amber), A opens it. GARAGE opens a split like his own shop (every joined guest gets
  his area): rows MODEL, LIVERY, COLOURS, FINISH (+ DECAL for pods), RESET, DONE. UP / DOWN pick a row, LEFT / RIGHT
  change it, A = next option / reset / done, B = done. The model row shows the manufacturer badge, the colours row the
  three livery colours. Every change is saved at once; P1 leaving the map closes the split (saved).
- **Not done** (follow-ups): a 3D preview of the guest's car in his area (vpreview's photo bays are front-end only:
  untested in the paddock world); a FREE MODE "MY GARAGE" livery entry on the racer card (FREE MODE keeps its own
  preset picks; `garage.raceTick` only runs in couch campaign races); kit-part editing (Edit Vehicle).

## 3. Files
- `SWGRCouch/Scripts/garage.lua`, `custdata.lua` (generated), `couchpanel.lua` (launcher + kind `garage`),
  `couch.lua` (guestVehicle), `main.lua` (module + race tick), `config.lua` (`CouchGarage`, `CouchGarageApply`,
  `CouchGarageUnlocks`, `CouchGarageTries`).
- `tools/gen-custdata.py`, `tools/test_garage.lua`, couchsim scenario `garage [n]` (+ the sim's model of the
  possession upload in `tools/sim/game.lua`).

## 4. Risks
1. **The upload rebuilds the guest's car in PRERACE** (the game does the same at possession). Anything a mod module
   attached to that car before (perkapply's race pass, hud / nametags / inputfix) must survive it. If his car or HUD
   misbehaves after `P2 livery applied`, set `CouchGarageApply = "tags"` (no new recipe actor) or `"off"`.
2. Table -> struct marshalling of a nested struct array was read in the UE4SS source, never run: the first live upload
   is the test (a Lua error is caught and logged as `livery NOT applied`).
3. The game may normalise tags in the recipe actor (None -> the root tag): only the fields the guest set are compared.
4. Unlock checks load each option asset once (about 100 small data assets the first time a garage opens): a short
   hitch when the split opens.
5. Livery templates are per class (the game's LAD maps); whether every template suits every model is the game's
   choice (its own garage offers the same list).
6. A seat is a seat: whoever plays P2 gets P2's garage.

## 5. Evidence locations
- JMAP: `python3 scripts/decode/jmapq.py class CstSubsystem | PlayerVehicleCustomisationComponent |
  CstSavedVehicleRecipeData | CstCustomisationComponent | CstVehicleRecipeUIData | CstLiveryCommonData`.
- Thunks: `work/runtime/UE4SS_ObjectDump.txt` (`[f: ...]` of the functions above).
- Blueprints: `retoc to-legacy -f <name>` of WBP_Paddock_VehicleCust*, WBP_CustomisationOptionView,
  BPFL_CustomisationFunctionLibrary from the full Paks, then `kismet-disasm.py`.
- Data: `cue4cli json` with the regex in `tools/gen-custdata.py`'s header.

## 6. Live checklist
1. Boot: no `garage` error, `modules=61/61`.
2. Couch run, run map with P2 joined: `GARAGE hint beside it`; P2's D-pad LEFT moves the amber highlight to GARAGE,
   RIGHT back to SHOP; P1's map unaffected; P2's A on SHOP still opens his shop.
3. P2's A on GARAGE: `P2 opens his garage from the run map`, `garage panels open for 2 player(s)`; his area lists
   MODEL / LIVERY / COLOURS / FINISH / RESET / DONE; UP / DOWN move the amber row; LEFT / RIGHT change the value
   (`garage` log `P2 SPEEDER BIKE palette -> ...`) and the focus stays on the row; the colours row shows swatches.
   Count the options: with `CouchGarageUnlocks = "p1"` only what P1 owns (or `unlock state unreadable` once: all).
4. DONE (or B): `panels closed (garage done)`; `guest-garage.txt` holds his choice; P1's own garage (game's Customize
   screen) unchanged.
5. Pick a node: the grid line names his model's preset (`Bike/PRE_Bike_<Model>`).
6. Race: `P2 livery applied (try 1): ... Server_UpdateVehicleRecipe <Model>` then `P2's car carries his livery`;
   look at his car (template / colours / finish), his HUD, abilities, ramjet, name tag, input: all as before.
   If the car looks unchanged with the read-back OK, try `CouchGarageApply = "tags"`; if the upload failed or broke
   something, report the log and set `"off"`.
7. Wreck / respawn: the respawned car shows his livery (a second `try 2` line at most).
8. 3 players: both guests' areas, each pad changes only its own car.

## 7. Native garage turn (branch couch-garagenative, 644b699) and roadmap

Jules 2026-10-15: "the garage needs to be the same as P1 with 3D models and all" -> `garagenative.lua`
(`cfg.CouchGarageNative`, default false until a live turn passes): a guest gets a TURN in the game's own full-screen
garage (backup of P1's two class slots to `garage-p1-backup.txt` first, his car loaded into them, his pad on P1's PC,
`CSM_VehicleCustomisation_Root`; at the end his model + livery to his store, P1's slots restored and saved, an
interrupted turn repaired at the next boot). Live checklist: back up SaveGames; turn opens with his 3D car full screen;
his changes land in `guest-garage.txt`; P1's own garage unchanged afterwards; next race shows his car.

### Roadmap: VEHICLE SELECT 1:1 with the 3D model (Jules 2026-10-15)
Today P2 picks his class in the mod's "YOUR VEHICLE" strip under P1's native `WBP_PreRun_VehicleSelect_C`. A second
native screen is not display-safe (its Construct / OnVehicleFocused call `SetSelectedVehicleArchetype` on P1's 3D
customisation pawn; decoded @410-841 / @46-252), and its confirm (`OnVehicleChosen`) commits P1's run class.
Design (same pattern as the garage turn):
1. P1 picks and confirms his class natively first (his run class is set).
2. P2's TURN: the same native screen is shown again full screen (or kept up before P1's confirm is processed - to be
   decoded: which call in OnVehicleChosen commits the run, and whether the screen can be re-entered after it), P2's
   pad on P1's PC (`couch.garageHold`), his focus moves the 3D car natively (`SetSelectedVehicleArchetype` is
   display-only on the pawn).
3. P2's A must NOT reach `OnVehicleChosen`: the mod reads his focused archetype (the screen's focused tile /
   `GetChosenVehicleTypeToCustomize`) and ends the turn itself (`couchprerun` stores it as his class, as the strip
   does now), then puts P1's archetype back on the pawn (`SetSelectedVehicleArchetype(P1's)`).
Open questions to decode before coding: the commit call inside `OnVehicleChosen`; how to swallow P2's A (park his
pad id while his turn shows the screen, the mod clicks nothing) without killing his D-pad focus; the unlock cinematic
(locked classes) must not play for P2's focus.

**Shipped instead (branch couch-prerun, 2026-10-17)**: not a sequential turn - the trailer clip
`03-vehicle-select-loadout.mp4` shows every player picking AT ONCE, so the simultaneous split stays. Each guest's half
is drawn in the 4-way garage's proven area look (`garage4ui.buildArea`: paper, his colour badge, the three class rows
with the amber focus row, the model name band) with a REAL 3D car of his highlighted class on his vpreview bay (his
garage model + livery; `garage4.prerunTick`, stills, a want only when his highlighted class changes). The compact
tiles stay as the input layer only (their invisible buttons keep his Slate focus and D-pad graph); his pick still goes
through `couchrun.choose` unchanged. Gated by `cfg.CouchPreRunNative` (default true; false = the old compact panel,
also the automatic fallback when the area cannot be built). Offline gates: couchsim `prerun3d 2|3`,
`tools/test_prerun.lua` (vehicleVm).

**#100 (branch couch-fix20, 2026-10-18): the native VEHICLE SELECT per guest.** Decoding (cue4cli --script) showed
`WBP_PreRun_VehicleSelect_C` has an EMPTY WidgetTree: its whole layout is its parent `WBP_FE_BaseVehicleSelect_C`'s,
and every call that reaches P1 (OnVehicleFocused -> `SetSelectedVehicleArchetype` on `BP_CstPawn_C[0]`, OnVehicleChosen
-> `ChooseVehicleType`, the locked-click purchase + cinematic, OnCustomise / OnUpgradeVehicle CSM changes) lives in the
pre-run OVERRIDES, which are empty on the parent. Each guest therefore gets a guest-owned, never-activated copy of the
PARENT class (`couchprerun.nativeVehicleCopy`): the game's class cards, stats panel, description and locked look, his
cursor through the card's own hover (`WBP_Vehicle_Entry` BP_OnFocusReceived -> the screen's VehicleArchetypeFocused),
his own 3D car on his vpreview bay behind it (2D `VehicleSelectImage` without a bay). Only P1 unlocks: P1's live
`IsArchetypeUnlocked` decides at every press (#102). The garage4ui area above is its fallback
(`cfg.CouchPreRunNativeCopy`). Offline gates: couchsim `prerun100 2|3|4`, `prerun100 2 nocopy`.

## 8. The native turn made default (branch couch-garage2, 2026-10-16, offline)

`cfg.CouchGarageNative = true` now; the compact panel stays the fallback (config `false`, a turn that cannot start, and
for the rest of the session after a turn whose garage never came up).

### 8.1 Decoded screens (cue4cli `--script` + `scripts/decode/kismet2txt.py`, no game run)
- `WBP_Paddock_VehicleCust_C` (root, FuseScreenWidget): hero buttons Choose Model (`WBP_Customise_Btn` ->
  "Selected Themes"), Edit Vehicle (`WBP_Customise_Parts` -> "Selected parts"), Edit Livery (`WBP_Customise_Livery`
  -> "Selected Livery"), desired focus `WBP_Customise_Theme.WBP_Theme_Btn`. Back = `RegisterActionBinding(IA_UI_Cancel)`
  -> `OnCancelAction` -> `ChangeToState("Exiting specific vehicle customisation")`. Widget Enhanced Input bindings:
  `IA_Cst_Movement` (pawn `MoveInputUpdated`), `IA_Veh_Camera` (`FuseCameraComponent:SetCameraInput`), `IA_Veh_Throttle`
  (`RevEngine`).
- `..ThemeOptions_C`, `..LiveryOptions_C`, `..PartsOptions_C` derive from `..LiveryOptionsBase_Concise_C`: a
  `WBP_Tab_List` (CommonTabListWidgetBase, LB / RB = its Next / Previous tab actions; `IA_UI_Tab_Left/Right` in
  IMC_UI) linked to a `FuseWidgetSwitcher` of `WBP_CustomisationOptionView` pages (`bAutoActivateOnSwitch`, each a
  ListView `LV_Items` of `WBP_CustomisationOptionButton_Vehicle`). Livery tabs = `LiveryCategories`; Edit Vehicle tabs =
  the parts (car `FrontL Front FrrontR EngineR Rear EngineL`, bike `Front Controls EngineC EngineB Rear Wings`, skimmer
  `FrontL Front FrontR EngineL Rear EngineR`); Choose Model has one collapsed tab. Back = CommonUI default back
  (`BP_OnHandleBackAction`: ends a playing unlock cinematic).
- An option entry: focus = preview (`EquipItem(true)` -> `UpdateUISelection`), A = equip (`UpdateUISelection` +
  `SaveCustomisationRecipes` into the FIRST local player's CstSubsystem slot), an unpurchased option is a requires-hold
  button (`TryToPurchaseOption`: P1's profile pays).
- The class shown: `BPFL_CustomisationFunctionLibrary.SetSelectedVehicleArchetype` = `UpdateUISelection(0, <enum
  friendly name>, arch)` on the pawn's component; the class read back from `ActiveRecipe.VehicleArchetype`.

### 8.2 Design
- Backup of all 8 slots + P1's shown class; his class switched on the pawn first (read back: refused = compact garage),
  his car (model preset + his stored kit parts + tags) into his class' 2 slots.
- EXCLUSIVE pads (`couch.garageHold`, `cfg.CouchGarageExclusive`): P1's PC on his pad id, the guest's PC on PARK_ID (P1's
  pad reaches no player), Slate user 0 on an invisible non-navigable sink; `couch.garageSinkCheck` (every FAST tick)
  puts user 0 back after each screen / page activation (CommonUI focuses the owner's LocalPlayer user = user 0). At the
  end the recorded ids come back and user 0 goes to the game viewport.
- His input: D-pad / A / sticks / RT native (user 1 focused by the mod on the root's selected button or the active
  page's equipped entry; again after every page change). B / LB / RB read from P1's PC raw input (= his pad with the
  DLL filter; without it also confirmed on P1's PlayerInput) and bridged only when the game did not act within 150 ms
  (baseline = the previous tick's screen / tab).
- P1's pad through a CommonUI router that follows the platform user (not seen live, `cfg.CouchGarageUndoForeign`): a tab
  change without his press is put back, a sub-screen left without his B is entered again (root BndEvt), a garage closed
  without his B is opened again (twice at most). His pad disconnected for 3 s: garage machine -> Idle, turn ends.
- End: model, tags AND kit parts (when they differ from the model preset's) into `guest-garage.txt` (`units`); P1's
  class back first, then every slot that differs from the backup written back, reload, save, read back ("restored
  exactly" or the field list). A crash repair without the garage pawn stays pending until a save went through.
- No purchase on P1's profile (`cfg.CouchGarageNoPurchase`): every option entry of the shown page that P1's profile
  does not own (`CstOptionFunctionLibrary:IsOptionUnlockedAndPurchased(entry.Data)`) is put in the CommonButton locked
  state (`SetIsLocked(true)`): its click / hold runs `BP_OnLockClicked` (lock sound), never `BP_OnClicked`, the only
  caller of `TryToPurchaseOption`. His A on one: toast "LOCKED - P1'S PROFILE". Locks lifted at the turn end; a
  `TryToPurchaseOption` seen during a turn anyway is a WARN (cannot be undone).
- Race: his kit parts patched into the preset CDO's `UnitRecipes` for the one `Server_UpdateVehicleRecipe` call, put back
  right after.

### 8.3 Offline gates
couchsim `garagenative [dead|native|user|nofilter|switch|refuse|gone|never|3|repair]` (`tools/sim/garagesim.lua` models
the garage), `tools/test_garagenative.lua` (slotDiff, nextTab, kit parts).

### 8.4 Live checklist
In the report of the couch-garage2 branch (run notes), repeated here in short: back up SaveGames; P2's GARAGE on the run
map; P1's pad does nothing (D-pad, A, B, LB, RB, START); P2 drives root / Choose Model / Edit Vehicle (LB / RB parts,
A equips) / Edit Livery (LB / RB template / colours / finish); B back; B on the root ends the turn; log "restored
exactly"; P1's own garage unchanged; P2's car (model, livery, kit parts) in the next race.

### 8.5 The turn's exit (couch-livefix r4, 2026-10-16, offline)
Live round 4 (clip `v2/05-p2-garage-turn.mp4`): after P2's turn the menu was gone but the garage camera stayed on P1's
landspeeder, P1 could not walk, B / START did nothing until the event map opened. Decoded (cue4cli `--script`):
- B on the root = `OnCancelAction` -> MainBack sound, `OwningStateMachine:ChangeToState(CSM_VehicleCustomisation_Idle,
  "Exiting specific vehicle customisation ")`, every `CstStaticVehicle:UpdateCustomisationMesh()`, the pawn's
  `StopEngine()`.
- `CSM_VehicleCustomisation_Active` (StandaloneCsmAsset) holds the data layers (customisation lighting),
  `CsmActionSwitchToCamera` (tag `VehicleCustomisationCamera`, `RestoreViewTargetOnEnd`), the hologram audio,
  `CsmActionEnableInteractionPoints(Enable=False)`; its child states (`CSM_VehicleCustomisation_Vehicle` = the root
  screen, back state `Customise_VehicleSelect`) run `BP_Csm_EnabledVehicleCustomisationInput` (IMC_Customisation at 2000
  on the machine's local PC + an audio listener override). All of it ends when the machine leaves Active: Idle IS the
  exit, there is no separate SetViewTarget / input-mode call.
- The mod's bridge called the root's FuseScreenWidget `BackToPreviousState`: its back state does not exist in the
  standalone machine, so the root deactivated and the machine stayed Active (round 3: root drawn; round 4 with the
  collapse: camera + IMC_Customisation left).
Fix: his B on the root ends the turn; `M.finish` restores P1's slots, gives the pad ids back, saves, then runs the game's
exit (`root:OnCancelAction`, else the machine -> Idle with the game's reason + StopEngine; parked vehicles re-meshed when
the root's exit did not run after the restore) and verifies for 3 s (`IsStateActiveByRef(Active)` false, P1's
`GetViewTarget()` = his pawn, `HasMappingContext(IMC_Customisation)` false, root not activated): log `garage exit
verified`. Still wrong at the deadline: machine -> Idle, `SetViewTargetWithBlend(his pawn)`, `RemoveMappingContext`, and
the section-8 collapse of a root left drawn (`garage exit NOT clean ... -> fallbacks: ...`). couchsim `garagenative *`
checks it (and P1 opening / leaving his own garage after a turn); `garagenative exitstuck` the fallbacks.
Live: after P2's B on the root: `P2's B on the garage root: his turn ends`, `garage exit = the root's own
OnCancelAction (ok; machine was Active)`, `garage exit verified (...)`; P1 walks, his camera is the paddock's, B / START
work, his own garage opens and closes normally.

## 8. The 4-way garage (branch couch-garage4, "option 2")

Jules 2026-10-16: every player builds his car AT THE SAME TIME in split screen, each in his own area with his own 3D
car and his own pad, in the game's look. Offline only so far (couchsim + unit tests); section 8.6 is the live list.
Both switches stay `false` until it passes: `cfg.Garage4Way` (FREE MODE / GRAND PRIX cards), `cfg.CouchGarage4Way`
(couch campaign run map).

### 8.1 Why a mod-built screen
The native garage is single-player (section 1.3): `FindCustomisationPawn` = the first `BP_CstPawn_C`,
`SaveCustomisationRecipes` writes the first local player's `CstSubsystem`, `CSM_VehicleCustomisation_Root` runs once
per machine, and the front end forces split screen off (so `AddToPlayerScreen` has no player regions to draw into and
guests have no view). No native garage widget is cloned: `garage4ui.lua` lays out its own areas in ONE full-screen
widget (`WBP_Background_Blur` host, the couch panels' technique), HitTestInvisible, z `cfg.Garage4Z` (900):
1 player full screen, 2 top / bottom strips (3840 x 1080 su), 3-4 quadrants (1920 x 1080 su; a 3P filler quadrant).
Each area: paper backdrop, the player's colour badge, GARAGE title, class chip, the 3D car (16:9, the bay's opaque MID
as on the RACERS cards) with the manufacturer badge and the model's game name on its bottom band, rows MODEL / LIVERY
/ COLOURS / FINISH (/ DECAL for pods) / RESET / DONE in the campaign panels' teal with the amber focus row (palette
swatches on COLOURS), hint and toast lines, a READY cover with "WAITING FOR P3, P4".

### 8.2 Input: one area per player, no CommonUI router
- FREE MODE: the area events come from `racers.dispatch`, which already carries the player: guests' pads polled on
  their OWN PlayerController (`racers.pollGuest`: d-pad / stick with repeat, A press edge, B release edge), P1 through
  the RACERS sink (directions + accept), the keyboard, P1's B after a race. While the garage is open every event goes
  to `garage4.event(ctrlId, ...)`: only that player's area changes. No widget of the garage is focusable, so the
  CommonUI split-screen pad mix-ups (one action router per LocalPlayer, the last local PC owning native screens) never
  reach it. P1's B before a race is the page's own Back (it leaves the step: the garage closes, picks kept): his area
  hint names the DONE row.
- COUCH CAMPAIGN: couchpanel's garage split is kept as the input layer (each guest's Slate-focused ghost buttons, the
  LEFT / RIGHT sentinels, the pad park of couch.lua); only the drawing of each guest area is garage4ui's.

### 8.3 Content, stores, the race
- FREE MODE catalog (`garage4.freeOptions`): MODEL = every PRE_* preset of the player's class (base models and the
  pilot / aged liveries, `vehicles.models` order); LIVERY / COLOURS / FINISH / DECAL = every option of custdata.lua
  (hidden pre-order entitlements only with `cfg.Garage4ShowHidden`), first entry MODEL'S OWN (= no override; the
  catalog entry equal to the preset's own tag is left out). Unlocked: nothing is filtered by P1's account.
- The model is the racer card's pick (`pl.presetId`: grid entry `VehicleCustomisation`, launch.lua). The livery tags
  are kept per pad and class in `Mods/SWGRCouch/garage4.txt` (never `guest-garage.txt`, never P1's CstSubsystem) and
  go with the pick (`racers.choicePlayers` -> `pick.livery = {arch, preset, mask, palette, patina, decal}`).
- Race (`garage4.raceTick`, MAIN, PRERACE / RACING of a cards launch, not a couch race): for each local human with a
  pick livery, once his car and recipe actor exist: `garage.apply` on HIS PlayerState's
  `PlayerVehicleCustomisationComponent` (`Server_UpdateVehicleRecipe` = model preset CDO + his tags; or the "tags"
  mode of `cfg.CouchGarageApply`), read back, re-applied after a rebuild, `CouchGarageTries` per world, skipped when
  the car's class / preset is not the livery's. P1 included: the upload makes a race-world recipe actor; his garage
  slots and save are never read for writing nor written (no `SaveCustomisationRecipes`; his grid entry carries a preset,
  so the game's own possession upload never touches his CstSubsystem either).
- COUCH CAMPAIGN: unchanged data path (`garage.lua`: `CouchGarageUnlocks` = what P1's save owns, guest-garage.txt,
  couch.guestVehicle for the model, garage.raceTick for the livery). P1 has no area there: his area keeps the run map
  and his own garage is the game's.
- The bays: `vpreview.want(i, p, cls, livery)` (keys = ControllerId + 1, the cards' keys). A ready model whose livery
  differs gets the tags on `CustomisationComponent.ActiveRecipe` + `RefreshRecipe()` (`cfg.Garage4BayLivery`
  "refresh"; "ui" = `UpdateUISelection(VRUST_LiveryMask 8 / LiveryPalette 7 / Patina 11 / IconMask 10 /
  IconPalette 9, tag, -1)` per tag; "off"), then the bay waits for the model again and captures: no respawn for a
  livery change. In the paddock the bays exist on garage4's grant (`vpreview.allowOutside`), for the current phase.

### 8.4 Cost and teardown
- No FindAllOf / StaticFindObject in a tick: the catalog is Lua data, preset classes are cached by vehicles.lua, the
  class's manufacturer badges are resolved once at open (`garage4ui.prefetch`), fonts once per session. couchsim
  `g4lag 4`: 0 / 0 in 600 FAST ticks, 0 renders and 0 bay wants idle, <= 2 area renders per tick, one want per change.
- Bays: stills by default (a burst at ready + one after the late-parts window, `SetupPreviewStillBurst`), at most
  `SetupPreviewCaptureBudget` (1) CaptureScene per FAST tick over all bays; `cfg.Garage4Spin` turns them with a capture
  every `Garage4SpinCaptureMs` (250) per bay.
- Teardown: every DONE closes the screen; START / any step change / a menu replacement (`racers.leave` / `forget`)
  closes it before the bays are released; a join or leave closes it (cards reconcile first); any phase change closes
  it, a world change drops it (no call on a dying widget). Campaign: the split's close releases the bays, a phase change
  only drops them (no call on a world in change).

### 8.5 Files and tests
`garage4.lua`, `garage4ui.lua`, `vpreview.lua` (livery, allowOutside, setCaptureMs), `racers.lua` (VEHICLE A,
dispatch routing, previews, choicePlayers, close paths), `couchpanel.lua` (garage areas), `config.lua`, `main.lua`.
Tests: `tools/test_garage4.lua` (layout, catalog, store, isolation, close paths, race uploads, campaign scope),
`tools/test_g4bay.lua` (the real vpreview on a stubbed engine: livery on a bay, re-livery without respawn, ui mode,
refusal, capture budget, paddock grant), couchsim `g4free 2|3|4`, `g4race 2|4`, `g4camp 2|3|4`, `g4lag 4`
(tools/sim/garage4.lua).

Unknowns (live only): G4-02 does `RefreshRecipe` (or `UpdateUISelection`) re-skin a static vehicle from tags; G4-03
does the WBP_Background_Blur host draw over the RACERS page without taking P1's sink focus; G4-07 bays in the paddock
world (lighting / visibility from P1's camera at z 60000); G4-09 the GPU cost of 4 captures on change.

### 8.6 Live checklist
The live checks G4-01..G4-10 (front end with 4 areas, livery recipe per bay, per-pad isolation, unlock-all, the race, P1's
saves untouched, the couch campaign, teardown, GPU cost, join / leave while open) were run with the project's own test
harness; the step-by-step script stays with the project notes.

## 9. P1's own garage with guests joined + the paddock garage offer (couch-rewards, 2026-10-17 playtest)
- Finding #6: P1's own paddock garage showed a speeder bike on a landspeeder run (screen owned by the last local PC).
  `garagenative` now watches P1's own visits (root activated, no guest turn, guests joined; `cfg.CouchP1GarageGuard`):
  the pawn's class must be P1's run class (`CampaignRun.MainVehicleType`) and its model P1's slot - else switched back
  (`UpdateUISelection(0)`) + `ReloadRecipe`, at the open and +0.5 / +1.5 s. Every guest CstSubsystem and P1's slots of
  other classes are snapshot at the open and put back (+ save) at the close if they changed. Log: `P1's own garage open
  (owner local player N, K customisation pawn(s))`, `shows class X ... switched`, `P1's own garage closed: ...`.
- Finding #4/#10/#11: the guests' run-map SHOP / GARAGE hints are off by default (`cfg.CouchMapGuestShop`,
  `cfg.CouchMapGuestGarage`); after P1 leaves his own garage each joined guest in turn sees "P2: PRESS A FOR YOUR
  GARAGE" / "B: NO THANKS" under his chip (`cfg.CouchGarageOffer`, withdrawn after `CouchGarageOfferMs`): A = his native
  turn (`M.start`), the compact garage only when that turn cannot start (`couchpanel.garageCompact`).
- couchsim: `p1garage`, `garageoffer a|b|timeout`, `maphints` (tools/sim/rewards17.lua).
- Finding #26 (round 2, couch-p1garage): the guard above FOUGHT THE SCREEN (bike garage forced to Car, three reloads
  Tarpon vs Beluga). The run class read was right (live test.cmd: `MainVehicleType` 0, `PreRunChosenVehicleType` 0, one
  `PlayerRacer.Build.VehicleBuilds` entry per class); the paddock has a garage per parked class (`PaddockVehicleSpawner`
  vehicleType 2 = "Customize speeder bike"), so the class the garage opens on is the GAME's choice. Now: never a class
  switch; the shown model must be one of P1's TWO slots of the shown class, else ONE `ReloadRecipe` per visit (the same
  mismatch read twice), then only reported. `cfg.CouchP1GarageGuard` defaults to false. couchsim `p1garage26
  off|bike|slot2|foreign` (tools/sim/p1garage.lua).
- Finding #27 (couch-p1garage): P1's A on his own garage root (ids swapped, Steam Input pad) never reached the owner's
  CommonUI router. menubridge (cnat `garage`): his A on the ROOT enters the hero page holding the pad-0 PC's focus
  (`garagenative.ownEnter`: the root's BndEvt, as the guest turn's bridge), his A on a PAGE clicks the option entry he
  focuses (never a hold / locked one), his LB / RB step the page's tabs (`ownTabStep`; read on the pad-0 PC: its
  PlayerInput and its raw subsystem's `IA_UI_Tab_*`, where the live loadout session saw P1's `IA_UI_Accept`; the DLL's
  pad watch has no shoulder keys), each after the wait only when the game did not act (state machine, new screen,
  tab / selection signature). His cursor on a page is put on an option ENTRY. `cfg.CouchP1GarageRootA` /
  `cfg.CouchP1GaragePageA` = false: off. couchsim `p1garage27 steam|xinput|native` (tools/sim/p1garage.lua).
  LIVE CHECK: a Steam Input LB / RB on a garage page should log `P1's RB -> ... tab ...` (or act natively); if neither,
  the shoulder keys reach no PC under the swap and need a pad-watch slot in swgr_inputfilter.
