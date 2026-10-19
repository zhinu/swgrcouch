# RESTART RACE in the in-race pause menu (research, 2026-10-10)

User: "Also add restart race in the menu" (the in-race pause menu).

Static only: the game was not launched, and no install or mod file was modified. Inputs:
- the decoded pause screens: `work/decoded-bp/.../Pause/WBP_Pause*.json` (CL381121) and
  `work/design/ui-v2/parts/decoded/.../Pause/WBP_Pause.json` (Steam paks = hotfix CL382493, with bytecode). They are
  identical for everything used here: tree, filter lists, bindings, and the statement offsets of
  `work/decoded-pause2/WBP_Pause.disasm.txt`;
- `DT_DialogData` and the `MenuText` string table, decoded with cue4cli from the Steam paks;
- the hotfix exe (`<hotfix game copy>/...`), read-only with capstone;
- the live restart test of 2026-10-10 (`state/runs/20261010-0512-hud-before/UE4SS-051730.log:1275-1425`,
  `restart-0-before.png`, `restart-1-after.png`, `restart-2-prerace.png`);
- the mod source (0.11.0-dev).

Tags: **[V]** read in data, bytecode, machine code or logs (evidence given). **[L]** stock UE5 / CommonUI behaviour or a
strong inference. **[I]** inference. **[S]** must be checked live (VERIFY ids V-RST-xx, §5).

Scratch files (not part of the project) are not included:
- `v.py`, `natpairs.py`: copies of the menu-owner-verify capstone helpers. Run them with `--new` on the hotfix exe;
- `json/`: `DT_DialogData.json` and `MenuText.json`;
- `restart.lua`: the module sketch of §3. It passes `luac5.4 -p`, and its only globals are std / UE4SS
  (`RegisterHook`, `UnregisterHook`, `StaticFindObject`);
- `patched/`: `pause.lua`, `main.lua`, `config.lua`, `consts.lua` with the §3.9 edits applied. All pass `luac5.4 -p`.

## 0. Short answer

1. **Where the buttons are [V].**
   - `WBP_PauseRacing_C` is a `WBP_Pause_C` with `State Name = 'CampaignRace'`. Its own WidgetTree is empty.
   - Its rows are `WBP_Vertical_Btn_C` widgets inside `FuseFilteredVerticalBox` (a BP variable,
     `UFuseFilteredVerticalBox : UFuseVerticalBox : UVerticalBox`).
   - `PreConstruct` calls `FuseFilteredVerticalBox:UpdateSlots('CampaignRace')`. That native call **detaches**
     (`UPanelWidget::RemoveChild`) every row that is not in the filter list: `Btn_RetryRace` and `Btn_ReportPlayer`.
   - `Construct` collapses the three dev rows.
   - What remains on screen is RESUME, LOGBOOK, SETTINGS, PHOTO MODE, EXIT TO MAIN MENU, ABANDON TOUR.
2. **The game already has the row [V].**
   - `Btn_RetryRace` is in the Arcade list only. Its click opens the game's own `RetryRace` confirm dialog:
     "Are You Sure? / Are you sure you want to retry the current race? / ACCEPT / CANCEL".
   - ACCEPT calls `ArcadeSubsystem:RequestRestartEvent()`, which is the Arcade restart.
   - For a custom race the restart is `RacingGameMode:RequestResetRace()` (race state machine event 8 +
     `ServerTravel("?Restart")`). It was verified live.
3. **Design.**
   - Put the game's own `Btn_RetryRace` back into the list right below RESUME. The five rows after it move down one.
   - Label it with the game's own unused string `MenuText.Pause_Button_Restart` ("Restart Race", localised).
   - Its native click and the game's dialog do the confirmation.
   - ACCEPT runs the Blueprint's `OnConfirmPrompt('Yes')`, which calls `RequestRestartEvent`. There **one native
     pre-hook** records the request. The hook is registered only while an eligible race is RACING, and it checks its
     armed flag first.
   - The FAST tick then:
     1. resumes the pause through RESUME's own click;
     2. waits until the game has been unpaused for 250 ms;
     3. calls `RequestResetRace()` and `phase.markLeaving("restart")` in the same tick;
     4. starts a watchdog.
4. **Safety: the Arcade path [V].** `RequestRestartEvent` travels to `ArcadeSubsystem.LastPlayedArcadeEvent` when that
   field is set, for example after an Arcade event played earlier in the session.
   - While the entry is offered, the field is cleared with the game's own `ResetLastPlayedArcadeEvent()`. It is
     written back at FRONTEND.
   - The hook clears it again right before the native body runs. The game's body is therefore always a no-op.
5. **When it is offered:** on `WBP_PauseRacing_C` screens only, while all of these hold:
   - phase RACING;
   - `St.race.launchedByUs`;
   - `PrimaryFlow == QuickRace`;
   - this machine is the authority (not a client, and `AuthorityGameMode` is a `RacingGameMode`);
   - no remote humans are connected or expected;
   - the hook is armed.

   It is never offered online (`WBP_PauseMultiplayer`), in the campaign, Arcade or paddock, or on a network client.
   pause.lua hands each screen over. A split race's screen arrives right after its pre-create, before the CSM shows
   it. A one-player race, or `PauseMenuOwner = "game"`, arrives at first sight in `menuTick`, the screen pause.lua
   already finds. No new UIManager query is added.
6. **Mod state: nothing needs resetting by hand.**
   - `markLeaving("restart")` runs every module's "leaving" listener while PCs and PlayerStates are still alive.
     `takeover.releaseAll` runs before HandleSeamlessTravelPlayer.
   - The new world's `St.resetRace()` keeps `launchedByUs` and `choice`.
   - `St.launch.vehPlan` must stay. `perkapply` re-verifies every world, and the live test showed it.
   - In the classic flow only, a cosmetic WARN is expected (§3.6).
7. **Fallback:** `PauseRestartConfirm = "twice"` uses our own `WBP_Vertical_Btn_C` in the same place, confirmed by a
   second press within 3 s. A hint appears in the screen's own description box. No hook and no dialog are used.

## 1. The pause screen, decoded [V]

### 1.1 Classes and tree
| Class | Parent | Own data |
|---|---|---|
| `WBP_PauseRacing_C` | `WBP_Pause_C` | `State Name = 'CampaignRace'`. `SafeExitToMenuStates` is a **soft** array: never read it. PreConstruct: `Btn_Exit:SetIsLocked(...)` |
| `WBP_PauseArcadeRacing_C` / `WBP_PausePaddock_C` / `WBP_PauseMultiplayer_C` | `WBP_Pause_C` | `ArcadeRace` / `Paddock` / `Multiplayer` |
| `WBP_Pause_C` | `FuseScreenWidget` | the whole tree. `ValidPhotomodeCSMStates` is a **soft** array: never read it |

```
SzB_ScreenSizeOverride > FuseOverlay_0 > VB_ContentLayout(0 FuseSpacer fill, 1 WBP_Screen_Title, 2 SzB_ButtonLayout 1880x700)
SzB_ButtonLayout (SizeBoxSlot VAlign Bottom, pad 32/16/32) > VB_ButtonList:
  0 FuseSpacer_147 (Fill)   1 FuseFilteredVerticalBox (the rows)   2 PauseButtonList (empty FuseVerticalBox)
  3 VS_Info (pad top 150: SzB_Description_Size > Txt_Description | SzB_Info_Size > WBP_Pause_Info)
FuseFilteredVerticalBox, designer order (every slot HAlign Left, no padding):
  0 Btn_ResumeRace  1 Btn_AbandonRace  2 Btn_WreckVehicle  3 Btn_ResetVehicle  4 Btn_RetryRace  5 Btn_ReportPlayer
  6 Btn_Stickerbook  7 Btn_Settings  8 Btn_Photomode  9 Btn_Exit  10 Btn_AbandonRun
```
Every row and container used here is a BP variable (`bpprops/WBP_Pause.txt`): `FuseFilteredVerticalBox`,
`Btn_*`, `Txt_Description`, `VS_Info`. Lua reads them as `w.Btn_RetryRace`.

### 1.2 What a custom race shows, and why
- **`FilterListMap`** (instance TMap, copied from the archetype):

  | Key | Rows |
  |---|---|
  | `CampaignRace` (WBP_PauseRacing) | ResumeRace, AbandonRace, WreckVehicle, ResetVehicle, Settings, Photomode, Exit, AbandonRun, Stickerbook |
  | `ArcadeRace` | ResumeRace, AbandonRace, ResetVehicle, Settings, Photomode, Exit, WreckVehicle, **RetryRace**, Stickerbook |
  | `Multiplayer` | ResumeRace, AbandonRace, WreckVehicle, ResetVehicle, ReportPlayer, Settings, Exit |
  | `Paddock` | ResumeRace, Photomode, Settings, Exit, AbandonRun, Stickerbook |

- **`UpdateSlots(Name)`** runs from PreConstruct (ubergraph 2059). Native path: exec `0x146ffebae` → `0x14705e378`:
  `if FilterListMap.Contains(Name)`, copy the list and call `0x14712e4b0(this, list)`. That function:
  1. walks `Slots` (`+0x178/+0x180`);
  2. collects every slot whose `Content` (`+0x30`) is not in the list;
  3. calls `0x1405c3978(this, Content)` for each of them.

  `0x1405c3978` is `UPanelWidget::RemoveChild`: a GetChildIndex loop followed by RemoveChildAt.

  So a filtered-out row is **detached, not collapsed**. It stays alive (BP variable, WidgetTree) and keeps its component
  bindings. The visible order is the designer order, not the list order: LOGBOOK comes second in the screenshot.
- `Construct` → ubergraph 2721/1073 → `ShouldShowDevOptions` → `SetShowDevOptions(false)` in shipping. This collapses
  `Btn_AbandonRace` / `Btn_ResetVehicle` / `Btn_WreckVehicle` with `SetVisibility(1)`.
- **The custom-race panel after construction:**
  - 0 RESUME
  - 1-3 dev rows (collapsed)
  - 4 LOGBOOK, 5 SETTINGS, 6 PHOTO MODE, 7 EXIT TO MAIN MENU (lock icon), 8 ABANDON TOUR

  This matches `state/runs/20261010-0213-racers-v2/rc-10-race-hud-022703.png`.

### 1.3 How the rows are wired (component bindings + ubergraph, hotfix decode)
| Row (label key → text) | OnButtonBaseClicked | OnButtonBaseFocused |
|---|---|---|
| `Btn_ResumeRace` (Pause_Button_Resume "Resume") | 826 `OwningStateMachine->BackToPreviousState(None)` (Paused_Racing Back = Idle) | 1276: description "Get back to the action!", `ShowInfo()` |
| `Btn_RetryRace` (Pause_Button_Retry "Retry") | 3485 `GfnMessagingSubsystem:AddMessage('RetryRace', handle, OnConfirmPrompt, None, 0, 0)` | 3991 `Txt_Description = Pause_Description_Retry` ("Give it another go!"), `ShowDescription()` |
| `Btn_Exit` (Pause_Button_Exit) | 3764 `AddMessageParams(QuitToMenu + {LastSave}, QuitDialogDone)`; 3934: Yes → `ReturnToMainMenu(self)` | 4360: exit description + last save |
| `Btn_AbandonRun` | 89 `AddMessage('AbandonRun', OnConfirmAbandonRun)`; 4228: Yes → `CampaignSubsystem:LockRun`, `ReturnToMainMenu` | 4519 |
| `Btn_Settings` / `Btn_Photomode` / `Btn_Stickerbook` | `ChangeStateTo(CSM_PauseMenus_Settings)` / `ChangeToState(soft Photomode, '')` / `ChangeToState(soft Stickerbook, 'Open Stickerbook from Pause menu')` | descriptions |

- `OnConfirmPrompt(Result)` → 3644: when `Result == 'Yes'`, run 3701/3731
  `GetGameInstanceSubsystem(ArcadeSubsystem)->RequestRestartEvent()`. This is an `EX_FinalFunction` in the hotfix
  bytecode, so it calls through the UFunction's `Func`.
- On activation (`BP_OnActivated` 860): `RequestRefreshFocus()`, then `RegisterActionBinding` for `IA_UI_Cancel` →
  `OnCancelAction` (1663 BackToPreviousState) and `IA_UI_Pause` → `OnPauseAction` (→ 1663), plus the EOS overlay prompt.

### 1.4 Focus and navigation
- The screen's focus target is RESUME: `DesiredFocusWidget = Btn_ResumeRace` and `BP_GetDesiredFocusTarget` returns it.
- No row has explicit Navigation rules (decoded properties), so Slate's geometric navigation inside the vertical box
  decides up/down. A row placed at index 4 is reached with D-pad down from RESUME [L].
- `Btn_ResumeRace` has `bSelectable` and `bShouldSelectUponReceivingFocus`. Every row has `IsInvert = true` and
  `LinearSelectBackgroundColor` E0AC50 (the focus pill).
- `UIManagerSettings.AllowedFocusableWidgets` includes `FuseButton`, the base of every `WBP_*_Btn` (ui-toolkit §1.1).

### 1.5 Strings (cue4cli, hotfix paks)
- `MenuText`:

  | Key | Text |
  |---|---|
  | `Pause_Button_Restart` | "Restart Race" (no Blueprint uses it today; localised like every MenuText row) |
  | `Pause_Button_Retry` | "Retry" |
  | `Pause_Description_Retry` | "Give it another go!" |
  | `Pause_Retry_Desc` | "Do you want to begin this event again?" (not used by RetryRace) |

- `DT_DialogData.RetryRace`:
  - Header: `CommonText.Dialog_AreYouSure_Title` "Are You Sure?"
  - Body: `DialogText.RetryRace_Desc` "Are you sure you want to retry the current race?"
  - Actions: Accept → `Yes`, Cancel → `No`; `ShouldGenerateInputActions` false
  - `TargetContainer Dialog`: the persistent P1-owned container, like QuitToMenu
    (`state/runs/20261010-0437-ui-before/ref-20-exit-confirm.png`)

## 2. The native restart paths (hotfix exe CL382493) [V]

### 2.1 `ARacingGameMode::RequestResetRace()`
Exec `0x1470de988` → `0x142fe0bb2`:
1. `if (0x143b74c46(this) == 3) return`. [I] This is `AActor::GetNetMode`, and 3 = NM_Client.
2. `this->StateMachine` (+0x4f8, `USimpleRaceStateMachine`) gets event 8 (`0x140d65bb0(sm, 8)`).
3. `0x14645a2f2(world, L"?Restart", 0)`: a relative ServerTravel, so the same map. The string is at `0x14a2e06ba`.

**Live, 2026-10-10 03:16:31** (`UE4SS-051730.log`):
- 1275: `RequestResetRace: true nil` (test.cmd).
- 1278 (+260 ms): `pause CSM gone (the race CSM left CSM_RF_InProgress ...)`. This is event 8.
- 1284: `leaving the race (poll)`. The OnSeamlessTravelStarted pre-hook did not fire (V-CORE-10).
- 1292-1303: RACING → LEAVING → TRANSIT → PRERACE, map `L_Mastiff_LOOP_B`, in 0.25 s.
- 1354-1365: perkapply `build ok, abilities 4/4, crash ok, parts 4/4 live`, `traits: 3 of 3 applied, PassiveList 4 -> 7`
  and `pilot: ... the pick`, for P1 and P2.
- 1425: PRERACE → RACING after the intro.

### 2.2 `UArcadeSubsystem::RequestRestartEvent()` and `LastPlayedArcadeEvent`
- Exec `0x14707c2f2`, body inline from `0x14707c308`:
  1. `if (!this->[0x40]) return;`
  2. `gm = GetWorld()->[0x1a8]; if (!gm || !gm->IsA(...)) return;`. [I] `vtbl[0x180]` is GetWorld (menu-owner §1.1),
     and `+0x1a8` is the world's AuthorityGameMode.
  3. `0x142fe5f86(gm)`: the same net-mode check, then race state machine event 8.
  4. tail jump `0x14707c426`: `TravelToEvent(this, this->[0x40])`.
- `ResetLastPlayedArcadeEvent` (exec `0x14707c36e`) writes `this->[0x40] = 0`.
- `reflect-types --class UArcadeSubsystem`: `Object<UArcadeEventDef> LastPlayedArcadeEvent @+0x40`. This is a **hard**
  pointer: it can be read, written, and nulled.
- Readers: `BP_Csm_Pick_HUD(_Countdown)` reads it in the Arcade PrimaryFlow branch only (hud.md §3.1);
  `WBP_PostRace_Arcade_Holder_Presentation` (the Arcade results screen's retry); `WBP_Pause`'s RETRY.
- So in a custom race the game's own RETRY → ACCEPT does one of two things:
  - nothing at all, when no Arcade event was played in this session;
  - **a travel to that Arcade event**, when one was.

  It never restarts our race. That is why §3 hooks it and keeps the field null.

## 3. Design

### 3.1 Flow (default `PauseRestartConfirm = "dialog"`)
1. **FAST (restart.fastTick, RACING, eligible race).** Register the native pre-hook on
   `/Script/Griffin.ArcadeSubsystem:RequestRestartEvent` and arm it.
   - It is unregistered at "leaving", at every phase other than RACING, and at FRONTEND.
   - Registry `_G.SWGRCouch_restart_hooks = {ids, on, armed}`. The registered callback checks `armed` first and calls
     the current handler inside `pcall`. This is pause.lua's B pattern.
2. **A pause screen appears.** pause.lua calls `restart.decorate(w, how)`:
   - from `precreate` when the leaf is `Paused_Racing`. This is a split race, inside the ChangeStateTo hook, right
     after `AddToViewport`; PreConstruct/Construct have run synchronously, so UpdateSlots has already detached RETRY;
   - from `menuTick` when it first sees a new screen instance. That is a one-player race, `PauseMenuOwner "game"`, or
     a screen the pre-create missed.
3. `decorate`:
   1. checks the class (`IsA WBP_PauseRacing_C`, class found with StaticFindObject only) and eligibility (§3.2);
   2. runs the arcade guard (§3.4);
   3. sets the label;
   4. places `Btn_RetryRace` (§3.3) and logs it (V-RST-02).

   It is idempotent per screen.
4. **The player picks RESTART RACE.** These are native paths, unchanged: the pauser's own pad
   (IMC_UI boosted, V-MB-04), menubridge's A for a guest without native input, or any player's A on a pause screen
   it does not own. The game's RetryRace dialog opens.
   - ACCEPT runs `OnConfirmPrompt('Yes')` → `RequestRestartEvent`. Our pre-callback:
     1. nulls `LastPlayedArcadeEvent` again if needed;
     2. records `St.restart.req = {by = pause.controller(), ...}`.

     Then the native body returns at once.
   - CANCEL changes nothing.
5. **FAST, next tick: resume.** Call `w.Btn_ResumeRace:HandleButtonClicked()` (the game's own resume; menubridge has
   proved it live, V-MB-01). The fallback is a new `pause.resume()` export: pause CSM → `CSM_PauseMenus_Idle`, the
   F2/F3 path.
6. **FAST: wait.** Wait until `pause.isPaused() == false` for `PauseRestartAfterResumeMs` (250), then in one tick:
   1. `U.gm():RequestResetRace()`, with `U.ok` and the `RacingGameMode` IsA check;
   2. `phase.markLeaving("restart")`;
   3. `sched.after(PauseRestartWatchdogMs)`: the watchdog.
7. **Travel.** LEAVING → TRANSIT → PRERACE (same map) → RACING. The entry is offered again in the new race.

### 3.2 Eligibility (first failing check = the reason, logged once per race and on every change; V-RST-01)
1. `cfg.PauseRestart`.
2. `St.phase == "RACING"`. PRERACE (intro, grid, ignition) is excluded on purpose. After all humans finish there is no
   pause menu.
3. `St.race.launchedByUs`. It is kept across the restart (`St.resetRace`) and cleared at FRONTEND (launch.lua).
4. No restart is already requested.
5. `U.netMode() ~= "client"`, and `U.gm()` is valid and `IsA RacingGameMode`.
6. `GfnGameInstance.PrimaryFlow == QuickRace` (2). `LaunchCustomRace` sets it, and `BP_CsmPickPauseMenu` maps it to
   `Paused_Racing`. Campaign is 1, Arcade 3, Multiplayer 4: never.
7. Unless `PauseRestartRemote`: `#roster.remoteHumans() == 0` and `St.net.expectedRemote == 0`. net.lua's
   `onRaceMap` runs its stage checks again on the new PRERACE: relisten or servertravel when a client is missing.
8. `"dialog"`: the hook is registered and armed.

### 3.3 Placement (`place(w, btn, resume)`)
- `UVerticalBox` has no reflected insert. `UPanelWidget` reflects AddChild, ClearChildren, GetAllChildren, GetChildAt,
  GetChildIndex, GetChildrenCount, HasChild, RemoveChild and RemoveChildAt; `UVerticalBox` adds
  `AddChildToVerticalBox`. So the row goes to the end and every later row is moved behind it:
  1. `if box:HasChild(btn)` → done (idempotent).
  2. `ri = box:GetChildIndex(resume)`. If it is < 0, or `PauseRestartPosition == "end"`, append and stop.
  3. `tail` = every child at an index > `ri`, except the dev rows (`w.Btn_AbandonRace / Btn_WreckVehicle /
     Btn_ResetVehicle`, compared by `U.key`). In shipping that is LOGBOOK, SETTINGS, PHOTO MODE, EXIT, ABANDON TOUR.
  4. `box:RemoveChild(c)` for each of them, then `box:AddChildToVerticalBox(btn)` and
     `slot:SetHorizontalAlignment(C.E.HAlign.Left)`. A new `UVerticalBoxSlot` is HAlign Fill, so without this the focus
     pill would stretch across the 1880-unit box.
  5. `AddChildToVerticalBox(c)` + HAlign Left for every removed row, in order. This runs even when step 4's add failed.
  6. `btn:SetVisibility(Visible)`. Log the new index, e.g. `at 4 of 10 under RESUME (5 row(s) moved below it)`.
- Every call runs in its own pcall, so a failed RemoveChild never loses a row. Signatures (reflect-types):
  - `RemoveChild(Object) -> Bool`
  - `HasChild(Object) -> Bool`
  - `GetChildIndex(Object) -> Int`
  - `AddChildToVerticalBox(Object) -> UVerticalBoxSlot`
  - `UVerticalBoxSlot:SetHorizontalAlignment(Byte)`
- **Why this is safe:**
  - It is the path UpdateSlots itself takes. The game calls RemoveChild on this live panel inside PreConstruct.
  - A re-added row rebuilds its Slate widget (NativeDestruct, then PreConstruct/Construct of `WBP_Vertical_Btn`).
    Label, IsInvert, LinearSelectBackgroundColor and the locked state are the button's own properties, so they come
    back: EXIT's lock icon, and LOGBOOK / PHOTO MODE `SetIsLocked` [L].
  - The component bindings live on the button objects and survive [L].
  - RESUME is never moved, so its focus and the desired focus target stay.
- **Visibility of the re-layout:**
  - A split race pre-creates the screen, so it is laid out before the CSM shows it: no visible change.
  - A one-player race places the row at first sight. In practice that is the first paused FAST tick, because
    findPauseMenu runs at once after the pause edge. That falls inside `Anim_In`, which fades `SzB_ButtonLayout` in
    over 0-0.25 s [S].
- **Re-check:** every 500 ms while paused, `box:HasChild(btn)` on the kept screen (`U.ok` first). A rebuilt screen
  (`PauseMenuRehost "always"` runs PreConstruct → UpdateSlots again) gets the row placed again (WARN).
- **Label:** `UKismetTextLibrary::TextFromStringTable(FName("/Game/Griffin/Localization/MenuText.MenuText"),
  "Pause_Button_Restart")` → `btn:SetText(ft)`. `WBP_Vertical_Btn_C:SetText` sets `ButtonLabel` and `Txt_Label`, so the
  label survives the re-add's PreConstruct. An empty or "MISSING" text falls back to `FText("Restart Race")`.
  `PauseRestartLabel = "retry"` keeps the game's "Retry".

### 3.4 Click and confirmation
- **Click detection: none of our own.**
  - The row's native click raises the game's dialog.
  - The only hookable native call on the ACCEPT path is `RequestRestartEvent`. Native UFunction hooks fire for
    Blueprint calls: run H counted 2970 BP calls of a hooked `GetGameInstanceSubsystem`, and pause.lua's ChangeStateTo
    hook fires for the HUD Blueprint's request (V-PAU-11).
  - A 0-param native function with no soft param is the safest kind to hook. It complies with ARCHITECTURE Revision
    0.5.1 §1.
- **Why not raise the dialog from Lua:**
  - `AddMessage` returns the result only through a dynamic delegate, which Lua cannot bind (ui-toolkit §2.6).
  - The dialog buttons call `ReportResultAndRemove` natively (pause.lua 0.7.2 header), so no hook sees them.
  - The Blueprint's own `OnConfirmPrompt` is the only result path we can observe.
- **Why not `ui.registerButton` / `ui.pollClicks`:**
  - The registry belongs to the front end (`ui.forgetAll`).
  - `pollClicks` is ticked only while `St.menu.visible`.
  - `ui.onClicked` returns outside the front end.
  - The selected-toggle trick is used only by the `"twice"` fallback (§3.7), in restart.lua's own poll.
- **Menus another player owns (split race):**
  - The screen belongs to the pauser (pause.lua C). With its IMC_UI boosted (D), the pauser's A, B and D-pad act
    natively.
  - menubridge bridges a guest whose UI input is not native. Its last rule also lets any player's A click the focused
    row of a pause screen that player does not own.
  - The dialog sits in the P1-owned Dialog container. pause.lua D2 lowers the guests' IMC_UI while it is up, and
    menubridge lets the pause controller answer it: A = the focused button, else Accept; B = Cancel (V-MB-05). P1
    answers natively.
  - The P1 catcher (V-MB-09) is for the shared results screens only. It is not needed here.
- **Arcade guard (V-RST-05):**
  - `arcadeGuard()` runs when the row is offered (each decorated screen) and again inside the hook.
  - When `LastPlayedArcadeEvent` is valid, it keeps the asset path (a scalar), calls `ResetLastPlayedArcadeEvent()`
    and reads the field back.
  - At FRONTEND the path is re-found with StaticFindObject and written back, but only while the field is still null.
    The write is `sub.LastPlayedArcadeEvent = obj`, the same object-property write as perkapply's `ps.Pilot = def`.
  - The path is persisted across a hot reload (PERSIST_MODULES).
  - With `PauseRestartArcadeGuard = false`, the row is not offered while the field is set.

### 3.5 The restart sequence
- **Resume first.** That way `RequestResetRace` runs exactly as in the live test: in a running, unpaused race. Every
  per-pause layer of pause.lua also unwinds through its normal resume path: HUD inputs (A2), guests' IMC_UI (D), the
  pre-created screen's reference, and the restarted own pause CSM (G).
  - The pause exit runs a GC (`CSM_PauseMenus_Active` has `BP_CsmTriggerGCOnEntryExit`). restart.lua therefore drops its
    screen and button references as soon as it has asked for the resume.
  - If the game is still paused 2 s later, `pause.resume()` is tried once more. 2 s after that, the request is dropped
    (WARN).
- **The call:**
  1. `U.gm()` is `U.ok` and `IsA RacingGameMode`.
  2. `pcall(gm.RequestResetRace)`.
  3. `phase.markLeaving("restart")` in the same tick. This is `net.serverTravelNow`'s order: ServerTravel only arms the
     travel, so every "leaving" listener still sees the PCs and PlayerStates.
     - It also replaces the late "poll" leaving of the live test.
     - The misleading `pause CSM gone (... P1 wrecked or finished)` line disappears too: pause.poll no longer runs once
       LEAVING is set.
- **Watchdog (V-RST-08).** `sched.after(PauseRestartWatchdogMs)`, because LEAVING is not a race phase and the FAST race
  block stops there. If `St.worldGen` has not changed, call `phase.cancelLeaving("restart not executed", gen)` and WARN.
- **Not chosen: "direct" (call while still paused).** The game's own Arcade RETRY travels from the paused state, so this
  probably works, but it was never tested here. Keep it as a later option if the 250 ms of racing after the resume
  bothers anyone.

### 3.6 The mod's per-race state across the restart (`markLeaving("restart")`, then the new world)
| Owner | What happens | Action needed |
|---|---|---|
| `St.race` | `St.resetRace()` on the new world: `launchedByUs` and `choice` kept; `started`, `singleView` and the rest reset | none |
| `St.launch.vehPlan` | kept (cleared only at FRONTEND). The cards flow's perkapply raceTick reads it | **keep it** |
| perkapply | per world and human. The base-build patch was undone after the launch, and loadouts and recipe live in GameInstance-level state (live: build/traits/pilot re-verified, traits not stacked) | none |
| launch classic flow | `inRaceOverride` runs on LOADING, and a restart has no LOADING phase. PRERACE logs `never overridden during LOADING (V-SET-11)` per human. The recipe keeps the presets, so this is harmless | optional: mark `vehPlan.restarted` and log one INFO line instead |
| wreck / crashcam / viewguard | "leaving" → `clear("leaving")`: cvars, emulated slow-mo, camera overrides | none |
| hud / nametags / uxsplit / subsplit | "leaving" → `clearAll` / `clear` / disarm (hooks off); re-armed on PRERACE | none |
| takeover | "leaving" → `releaseAll(true)` (adopted PlayerStates given back before the travel); "world" → resetPriv | none |
| pause / menubridge | "leaving" → own CSM ended, IMC_UI restored, ChangeStateTo hook unregistered; per-race fields dropped on the phase change | none |
| inputfix | phase listener; the next world's cars are re-bound by bindPoll (live) | none |
| join | slots kept (a guest that left keeps an AI car). The race_enter guard returns for `from == "LEAVING"` | none |
| net | only matters with remote players (not offered then) | none |
| restart.lua | "leaving": hook dropped, screen and button refs dropped. New race world: `req` and eligibility cleared. FRONTEND: arcade restore | — |

### 3.7 Fallback `PauseRestartConfirm = "twice"` (V-RST-12)
- **The row:** `ui.make("VerticalBtn", w:GetOwningPlayer())`.
  - `IsInvert = true`, set before the add (PreConstruct reads it).
  - `LinearSelectBackgroundColor` copied from RESUME.
  - `SetIsSelectable(true)` + `SetIsToggleable(true)`.
  - Placed exactly like RETRY.
- **The clicks:** restart.lua polls `GetSelected()` every FAST tick while paused, then calls `SetIsSelected(false,
  false)`.
  - First press: `armedUntil = now + PauseRestartConfirmMs`, and a hint in the screen's own description box:
    `w.Txt_Description:SetText(FText("Press again to restart the race"))` + `w:ShowDescription()` (a BP function).
  - Second press inside the window: the same request and sequence.
- No hook, no dialog, no arcade guard. Use it if V-RST-03/04 fail live.

### 3.8 Config (config.lua "Pause" section, after `PauseDialogGuestUi`)
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `PauseRestart` | `true` | RESTART RACE in the pause menu (RACING, authority, launched by SWGRCouch) | V-RST-01 |
| `PauseRestartConfirm` | `"dialog"` | `"dialog"` (game row + RetryRace dialog + RequestRestartEvent pre-hook) \| `"twice"` (ENUMS) | V-RST-03/12 |
| `PauseRestartConfirmMs` | `3000` | "twice" window (POSITIVE) | V-RST-12 |
| `PauseRestartLabel` | `"game"` | `"game"` (MenuText.Pause_Button_Restart) \| `"retry"` (keep "Retry") \| any text | V-RST-02 |
| `PauseRestartPosition` | `"below_resume"` | \| `"end"` (appended, nothing moved) (ENUMS) | V-RST-02 |
| `PauseRestartRemote` | `false` | offer it while remote humans are connected or expected (untested) | V-RST-09 |
| `PauseRestartArcadeGuard` | `true` | clear LastPlayedArcadeEvent while offered, restore at FRONTEND; false = not offered while it is set | V-RST-05 |
| `PauseRestartAfterResumeMs` | `250` | RequestResetRace this long after the pause ended (NONNEG) | V-RST-06 |
| `PauseRestartWatchdogMs` | `5000` | no new world this long after the call → LEAVING undone (POSITIVE) | V-RST-08 |

### 3.9 Files and exact edits (applied and syntax-checked in `scratch/patched/`)
- **New `Scripts/restart.lua` (G5)**, from `scratch/restart.lua`:
  - `decorate(w, how)`, `fastTick()`, `status()`, `persistShared(put)`, `restoreShared(get)`, `init()`;
  - TAG `restart`, `opt()`, `St.restart`.
- **`pause.lua`, three edits:**
  - `precreate`, right after `st.pre = {...}`: `if leaf == "Paused_Racing" then` call
    `U.mod("restart").decorate(w, "pre-create")` through `pcall(U.mod, ...)` + `U.try`.
  - `menuTick`, in the new-instance block after `imcBoost(... "menu owner")`: the same call with `how`.
  - The export `function M.resume(why) return pauseCsmChange("CSM_PauseIdle", why or "SWGRCouch") end`.
- **`main.lua`:**
  - MODULES += `"restart"` before `"feowner"`;
  - INIT_ORDER += `"restart"` after `"menubridge"`;
  - FAST, inside `if isRace()`, right after `call("menubridge", "fastTick")`: `call("restart", "fastTick")`;
  - PERSIST_MODULES += `"restart"`.
- **`consts.lua`:** C.CLASS list += `"ArcadeSubsystem"`; C.CDO += `KismetTextLibrary =
  "/Script/Engine.Default__KismetTextLibrary"`. The sketch uses the literal paths, so both are optional.
- **`config.lua`:** the 9 keys above. `ENUMS.PauseRestartConfirm = {"dialog","twice"}` and
  `ENUMS.PauseRestartPosition = {"below_resume","end"}`. POSITIVE += ConfirmMs and WatchdogMs; NONNEG += AfterResumeMs.
- **`diag.lua`:** a `restart` section from `restart.status()`:
  `restart: hook=%s armed=%s offered=%s (%s) offers=%s placed=%s pending=%s restarts=%s arcadeSaved=%s`.
- **README / ARCHITECTURE:** config table rows, §9 VERIFY rows and a 0.11.0 revision entry. This is the lead's job.

## 4. Edge cases
| Case | Behaviour |
|---|---|
| Paused by a guest (split) | The row is in that guest's pre-created screen. The guest's A works natively (IMC_UI boosted) or through menubridge. The dialog is P1-owned: menubridge lets the pause controller answer it, and P1 can answer natively. `restart confirmed by P2` |
| Another player's A on the guest's menu | menubridge's last rule clicks the focused row, so RESTART RACE can be clicked by someone else. The dialog is the safety step |
| One local player / `PauseMenuOwner "game"` | Placed at first sight from `menuTick` (`how = UIManager`). No pre-create |
| Settings / Logbook / Photo mode and back | The pause screen that comes back is a new instance, pre-created again or seen again, so it is decorated again. Photo mode deactivates the screen: nothing to do. A pending request cannot coexist with photo mode, because the dialog closes first |
| Inactivity auto-pause (V-PAU-22) | P1's screen; offered like any pause |
| After P1 finished / wrecked (pause.lua G restarts the pause CSM) | Still RACING, so it is offered. The restart puts every human back on the grid. Wreck, crash cam and spectate state is cleared on "leaving" [S] |
| Results screen / POSTRACE | No pause menu, so no row. A request whose 250 ms wait ends after the race finished still sends (POSTRACE is accepted) |
| PRERACE pause (intro, grid, ignition) | Not offered (RACING only) |
| Dormant guests | Unaffected: they keep their AI cars and views after the restart |
| Network host with remote clients (connected or expected) | Not offered (`PauseRestartRemote`). With it true, RequestResetRace's seamless `?Restart` should carry the clients like net.lua's servertravel (V-NET-13). net.onRaceMap's checks then run on the new PRERACE [S] |
| Network client | Never offered. `RequestResetRace` is a no-op on a client anyway |
| Online / campaign / Arcade / paddock | `launchedByUs` false, the PrimaryFlow check, and a class other than WBP_PauseRacing_C: never |
| Arcade event played earlier this session | Field cleared while offered (V-RST-05). The restart reloads the custom race, never the Arcade event. Restored at FRONTEND |
| Hot reload while paused with the row | The row stays in the screen. The new state registers the hook on its first RACING tick. ACCEPT then works, with the resume falling back to `pause.resume()` |
| Travel refused | Watchdog: `cancelLeaving` brings the race phase back and the race goes on (V-RST-08) |
| Dev build with dev options shown | The dev rows stay above RESTART RACE (designer order) |

## 5. VERIFY (live checks, in test order; logs `[SWGRCouch][restart]` unless noted)
- **V-RST-01** (eligibility). The first RACING tick of a FREE MODE race logs
  `RESTART RACE offered in this race (standalone, confirm dialog)` and
  `native pre-hook registered: /Script/Griffin.ArcadeSubsystem:RequestRestartEvent (ids ...)`. A campaign or
  online race logs `RESTART RACE not offered: race not launched by SWGRCouch`, or no line at all.
- **V-RST-02** (row). 2P, P1 pauses:
  - log: `RESTART RACE added to WBP_PauseRacing_C (owner P1, pre-create): Btn_RetryRace at 4 of 10 under RESUME (5 row(s)
    moved below it), label MenuText.Pause_Button_Restart 'Restart Race'`;
  - screenshot: RESUME / RESTART RACE / LOGBOOK / SETTINGS / PHOTO MODE / EXIT TO MAIN MENU (lock) / ABANDON TOUR, left
    aligned like the others;
  - D-pad down moves the orange pill to RESTART RACE, and the description reads "Give it another go!". 1P race: the same
    with `(owner P1, UIManager)`.
- **V-RST-03** (dialog). A on RESTART RACE shows "ARE YOU SURE? / Are you sure you want to retry the current race? /
  ACCEPT / CANCEL".
  - CANCEL: back to the pause menu, no `[restart]` line.
  - ACCEPT: `restart confirmed by P1 (RetryRace dialog Accept -> ArcadeSubsystem:RequestRestartEvent pre-hook)`.
- **V-RST-04** (guest). P2 pauses, D-pad to RESTART RACE, A. `[menubridge] P2 A -> dialog WBP_Modal_C (Dialog:1) button
  1/2 'Accept' ...: clicked`, or a native accept, then `restart confirmed by P2`. Before that, P2 B on the dialog gives
  `... button 2/2 'Cancel'` and the race stays paused.
- **V-RST-05** (arcade guard). Play one Arcade event, go back, start a FREE MODE race, pause:
  - `ArcadeSubsystem.LastPlayedArcadeEvent /Game/... cleared (entry offered)`;
  - ACCEPT reloads the **same custom map** (phase line `TRANSIT -> PRERACE map=<same map>`), not the Arcade track;
  - at FRONTEND: `LastPlayedArcadeEvent restored (front end): ... ok`.
- **V-RST-06** (sequence), in this order:
  1. `restart: resuming the pause (Btn_ResumeRace:HandleButtonClicked)`;
  2. `[pause] pause over (states [...])`;
  3. `restart #1: RequestResetRace sent 2xx ms after the pause ended (requested by P1)`;
  4. `[phase] leaving the race (restart)`;
  5. `[phase] RACING -> LEAVING  (restart)`, `LEAVING -> TRANSIT`, `TRANSIT -> PRERACE  map=<same>`;
  6. `[perkapply] loadout: Pn in race: build ok ...` and `traits: 3 of 3 applied, PassiveList 4 -> 7` for every human;
  7. `[phase] PRERACE -> RACING`;
  8. `RESTART RACE offered in this race` again.

  No ERROR, no `lost menu`, no `request ... without a pause`.
- **V-RST-07** (hook lifecycle).
  - `native pre-hook unregistered (leaving (restart))` comes before `RACING -> LEAVING`.
  - `registered` appears again on the new RACING tick.
  - `unregistered (phase POSTRACE)` appears at the race end.
  - A second restart in the same session works.
- **V-RST-08** (watchdog). Never seen in a normal run. If seen: `restart: no travel 5000 ms after RequestResetRace ...;
  LEAVING undone`, and the race goes on.
- **V-RST-09** (not offered). Host with a connected client: `RESTART RACE not offered: remote humans (1 connected, ...)`.
- **V-RST-10** (state edges). Restart while P2 is wrecked and spectating, and once after P1 finished (P2 paused through
  G):
  - every human is back on the grid in the new race (screenshot at PRERACE: each view on its own car);
  - no crash-cam or spectate view is left over, and no `[wreck]` / `[crashcam]` ERROR;
  - when wreck had changed a cvar, `[wreck] <cvar> back to the user value <n> (leaving)` appears before
    `RACING -> LEAVING`. wreck.clear and crashcam.clear have no line of their own.
- **V-RST-11** (pods). An 8-pod race restarts the same way: same map, 8 pods.
- **V-RST-12** (fallback, `PauseRestartConfirm = "twice"`). First A: `RESTART RACE pressed once by P1: press again within
  3000 ms`, and the description box reads "Press again to restart the race". Second A within 3 s: `restart confirmed by
  P1 (second press within 3000 ms)`, then the V-RST-06 sequence.

## 6. Open points and risks
1. **[S] The hook firing on `RequestRestartEvent`.** It is a BP `EX_FinalFunction` call into a native UFunction, the
   same mechanism as the proven hooks. If it does not fire: ACCEPT does nothing (the field is null), and
   `PauseRestartConfirm = "twice"` is the switch.
2. **[S] Re-layout side effects.** RemoveChild + AddChildToVerticalBox on five live rows: locks, focus, the hover
   animation and the description bindings. `PauseRestartPosition = "end"` avoids any move.
3. **[S] `TextFromStringTable`.** It has not been called from Lua yet. The fallback is the literal "Restart Race".
4. **[S] The dialog bridge.** V-MB-05 / V-PAU-21 have never run live. A guest-opened restart depends on them, but P1 can
   always answer the dialog natively.
5. **Restart from the paused state ("direct").** Not chosen (§3.5). It is a later option.
6. **Remote players.** `PauseRestartRemote = true` needs a network session test. The interplay with
   `net.onRaceMap/checkTravel` and the clients' own mod state is unknown.
7. **Classic flow.** One cosmetic WARN per human after a restart (§3.6). Suppressing it is optional polish in launch.lua.
8. **The LastPlayedArcadeEvent clear/restore.** Its only side effect is the Arcade "last played" memory during our race.
   It is restored at FRONTEND, and also across a hot reload.

## 8. Live result (2026-10-10, run `20261010-0710-restart-test`, 2P, hotfix build, 1280x720)

PASS: V-RST-01, 02, 03 (Accept and Cancel), 04 (a guest restarts), 06, 07; five restarts in one session, the loadouts and
pilots applied again each time (V-RC-21/23). Not run live: V-RST-05 (arcade guard), 08 (watchdog), 09 (remote), 12
(`"twice"`). The log lines are in `ARCHITECTURE.md` Session T. What the design did not foresee:

1. **The moved rows came back disabled.** Every row removed and added again (and the detached RETRY) reported
   `GetIsFocusable()` / `IsInteractionEnabled()` false: grey, and the D-pad stopped at the first of them. The game
   switches them off once more right after the pre-create placement. Fix: `enableRows` copies RESUME's state (only ever
   ON) at placement, every FAST tick for 1.5 s after the pause starts, and with the 500 ms re-check. This build's setters
   are `BP_SetIsFocusable` / `BP_SetIsInteractionEnabled`.
2. **A guest's native menu input is dead after the restart's seamless travel** (A and B; its D-pad still moves the
   focus). Before any restart it works. The pause menu also keeps RESUME `GetSelected()` while the owner's focus
   moves. Fix in `menubridge.lua` (V-MB-10): the owner-focused row first; a guest's own pause menu, and its B anywhere,
   bridged whatever `MenuBridgeGuestNative` says; a guest whose pause-menu press needed the bridge gets its A bridged on
   Settings too until the next world.
3. **P1 answers the dialog natively, but B does not close it** (the RetryRace row has no generated input actions):
   CANCEL is one D-pad press away. Not changed.
4. **Test trap**: a Steam "Steam Controller Welcome" window took focus from the game window and all pad input was
   dropped silently; it looked exactly like a mod bug until the window focus was checked.
