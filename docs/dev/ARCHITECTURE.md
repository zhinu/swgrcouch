# SWGRCouch: architecture (binding design for all implementers)

*2026-10-06. Lead-architect pass. Static only: nothing from the game was run. This document supersedes the
design parts of `SPLITSCREEN-UX.md`, `BUILD-PLAN.md` and the old draft in `mod/SWGRCouch/Scripts/`. Every
implementer follows it **exactly**: names, call order, parameters and VERIFY ids are fixed here.*

> **Revision 2026-10-07 (after the first live runs, `state/runs/20261006-2329-session-A/`). Binding; it overrides the
> sections below where they differ.**
> 1. **Blueprint-function hooks register but never fire** in this build (V-CORE-07 answered NO): `WBP_FE_MainMenu_C`
>    `CustomEvent`/`RegisterTabs`, `WBP_Common_Btn_C:BP_OnClicked`, the builder's Go `BndEvt`, the HUD lap counters'
>    `UpdateCurrentLap`. Native `/Script/` hooks are unaffected. Rule: every behaviour has a **poll path that is the
>    default**; a BP hook may stay registered only as an optional extra that the poll de-duplicates against.
>    Poll paths: `menu_tab.pollTab` (MAIN, always on; `GetActiveTab` edges, main-menu `IsActivated` edges =
>    "RegisterTabs again", `cfg.TabReactivateMinMs`) also drives `builder.poll` (Go = `Btn_Go` selectable+toggleable,
>    `GetSelected` edge; live pick `cfg.BuilderAdopt = "live"`; devscreen = `PrimaryFlow` edge); `ui.pollClicks`
>    (FAST whenever a page shows; `cfg.ClickMode = "poll"` default) also runs `lobby.pollNav` (P1 pad/keyboard
>    navigation with its own highlight, `cfg.LobbyPadNav`); `pause.poll` (FAST in every race; guests' Start deferred by
>    `cfg.PauseDeferMs`, `cfg.GuestPauseFallback`); HUD laps = MAIN text poll, Memory-variant guest counters collapsed.
> 2. **Guest lifecycle (supersedes §1.1 "guests never leak" and §1.3 Close):** every guest `RemovePlayer` leaves a
>    dangling raw listener (the guest's CommonUI analog cursor) on the UIManager's `InputModeManager` delegate; the next
>    control-mapping rebuild calls into freed memory (the run-2 crash at `exe+0x3800ac`; analysis in the `join.lua`
>    header). Guests are created **once** (`cfg.GuestCreate = "connected"`: plugged-in pads only), **kept** across tab
>    switches, races and non-couch flows, and never removed (`cfg.GuestRemoval = "never"`). `join.close` only stops the
>    join session (input ignored, `split.frontEndSingleView` keeps one view on every tab); removal goes through
>    `join.dropGuest` (`join.removeAll`, `join.closeStray`, `join.removeGuest` for `takeover.leaveMidRace`) and only
>    where `cfg.GuestRemoval` allows it; a ControllerId removed in a world is never re-created in that world. A dormant
>    guest that travels into a couch race gets an AI-driven car and a view; in a non-couch race one view + AI cars.
> 3. **NO-INTRO boot** (`fastboot.lua`, G2-level module, init right after `phase`): poll loop, no hooks; skips title
>    idents + PRESS A, the photosensitivity warning (experienced saves only) and the Epic login / SOCIAL OVERLAY modal
>    (profile `bUseEosLinking` forced false). `cfg.FastBoot*`, VERIFY V-FB-01..05.
> 4. **User config folder in the prefix:** `AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/` (not
>    `.../Griffin/...`). `install.sh --prefix` writes there; `--fastboot-ini` sets `bEnableEOSAccountLinking=False`.

> **Revision 0.4.0 (2026-10-07, after the first 2-player race, `state/runs/20261007-0846-session-B/`). Binding; it
> overrides the sections below where they differ.** Research: `notes/research/input-isolation.md`, `presentation.md`,
> `race-setup.md`.
> 5. **Input isolation (`inputfix.lua`, new, G4-level; init after `takeover`, MAIN race tick + its own loop).** Every
>    human car read P1's raw input: `UPlayerInputComponent.RawInputSubsystem` (+0xc0) is filled with
>    `LocalPlayers[0]`'s `UGfnRawInputSubsystem`, and each subsystem's Slate pre-processor ("GfnRawInput") records every
>    device (it ignores `FInputEvent::UserIndex`). Fix: BIND each car's component to its owner's
>    `PC.RawInputSubsystem` (poll, re-bound if the game resets it) + NATIVE `native/swgr_inputfilter.dll` (loaded with
>    `package.loadlib(path, "*")`, DllMain only; wraps 5 vtable slots after checking their values, drops events whose
>    user is not the processor's owner; owner table in `swgr_inputfilter.cfg`, counters in `.status`) + KBSPLIT Lua
>    fallback (mapping contexts filtered by device class). `cfg.InputFix*`, V-INP-01..06.
> 6. **Per-view presentation (`present.lua`, new, G5; init after `hud`, ticked by main right before `hud.tick`,
>    `cfg.PresentFromMain = true`).** The race-flow CSM state (`IsStateActiveByRef` on `CSM_RF_*`) decides the layout:
>    ONE full-screen view (`split.setSingleView`) during LoadingPhase, PreRacePhase (track intro), PrepareForEventStart
>    (grid intro), SideBet, IntermissionPhase, PostRacePhase; split from IgnitionSequence (`cfg.IgnitionView`) /
>    Countdown / Racing / RollingStart. `split.enterRace` starts a race on one view when present wants it;
>    `split.relayout` and `leaving_cancelled` keep present's single view. Ignition: every local player gets its own
>    `WBP_IgnitionScreen_C` in its own view (`cfg.IgnitionMode = "perplayer"`; `"auto"` completes the checks for all;
>    `cfg.IgnitionSimple`), the game's viewport-wide screen goes to opacity 0. `gfx.onViewModeChanged` gives
>    `r.ScreenPercentage` the user's value while single. V-PRE-01..05, V-GFX-07.
> 7. **HUD:** `cfg.P1HudMode = "clone"` is the default (P1 gets a P1-owned HUD in its view; the game's HUD, whose owner
>    is NOT P1's PC, stays alive at opacity 0). The owner filter that made "P1 HUD not found yet" is gone. V-HUD-02/02c/02d.
> 8. **Names:** guests' PlayerStates are renamed `cfg.GuestNames[pnum-1]` ("Player 2"...) in the front end and in the
>    race (`nametags.namesTick`, 1 s throttle; `ServerChangeName` -> `GameMode:ChangeName` -> direct). V-NAM-01/02.
> 9. **RACE SETUP flow (`setup.lua` + `vehicles.lua`, new, G3/G4).** CHOOSE RACE opens CLASS -> PLANET (planet arrival
>    video `MEDIA_PlanetEstablish_*.bk2` in the UI Bink player) -> TRACK (+CONDITIONS) -> MODE (+grid size) ->
>    VEHICLES (one column per local player, model preset + build each, guests with their own pads, READY) inside the
>    lobby page; the dev panel stays as the ADVANCED row (`cfg.SetupMode = "builder"` restores the old CHOOSE RACE).
>    `launch.start` rewrites the GMV grid in memory to the class limit (12 speeders / 8 pods, humans included;
>    `cfg.SetupGridMode = "typed"`: `PlayerChoice x<humans> + <class> x<rest>`), undone on FRONTEND; after the accepted
>    `LaunchCustomRace` it writes each human's preset into `ActiveRecipe.RecipeState.Racers[].VehicleCustomisation`,
>    moves stray-class AI to the class, applies guests' builds, and repeats the presets in the race
>    (`Client_SetOverrideVehicleRecipe`). V-SET-01..11.
> 10. **Clock:** `St.nowMs()` is real time (`GameplayStatics:GetAccurateRealTime`, sampled by sched's loop wrapper,
>    os.clock-extrapolated between samples); `os.clock` ran ~1.5x fast under Wine. Values that cross a hot reload are
>    persisted as ages. V-CORE-13.
> 11. **Disabling the mod:** rename `ue4ss/Mods/SWGRCouch/enabled.txt` (e.g. `enabled.txt.off`); `SWGRCouch : 0` in
>    `mods.txt` does NOT disable a mod folder that has an `enabled.txt`.

> **Revision 0.8.0 (2026-10-07, integration of the 0.7.2 work after runs I and J). Binding; it overrides 0.7.1 and older
> where they differ.** Not run in the game yet: README §9 "0.8.0 checks" (V-SUB-00..08, V-VP-01..10, V-PAU-19..22,
> V-MB-03..06, in test order). Module comments and a few log lines (`[pause] init 0.7.2`, `[menubridge] init 0.7.2`) say
> 0.7.2: same work. The run-J camera fixes (chase-rig letterbox off, `WreckView` "native", `CrashCamLetterboxFix`; README
> §9 "Run-I results") ship in 0.8.0. Facts: `notes/research/live-run-I-facts.md`, `subtitles-split.md`,
> `vehicle-preview.md`, pause.lua's 0.7.2 header.
> 1. **New G5 module `subsplit.lua` (subtitles per player).** Run I: radio chatter for one player was drawn in P2's half
>    (ONE `FuseDialogueManagerSubsystem.SubtitlesWidget`, P1-owned, whole window, box 450 su above the bottom). Armed like
>    uxsplit (PRERACE/RACING, 2+ local players, not single view) once that widget exists (looked up every MAIN tick, never
>    FindAllOf). 7 native hooks, registered when arming, UnregisterHook-ed at POSTRACE (transform reset, clones removed),
>    "leaving" (quiet: hooks only) and every other phase; ids in `_G.SWGRCouch_subsplit_hooks`, flags in
>    `_G.SWGRCouch_subsplit_flags`; every callback checks its flag, runs in pcall, counts, returns nil: GetWorldSubsystem
>    PRE only (the poster; class address compare only; `UxSplitSubPosterHook`), RequestTrigger[Delayed] /
>    RequestEvent[Delayed] PRE (waiting requests; RequestEvent reads only its first param), UIManager
>    `GetCurrentSubtitleConfig` POST (the frame a line appears; `UxSplitSubDetect`), VehicleNarrativeComponent
>    `OnPlayerHitTargetWithAbility` PRE+POST (hitter / hit player; `UxSplitSubAbilityHook`). Who a line is for: the same
>    event < 1.5 s later -> the previous player(s); else the latest-due matching request (two players' requests within
>    150 ms = both; `C.SUB_RULES` both-rules; a non-delayed RequestEvent = both; ability hits); else a both-rule from the
>    event tag; else the speaker's car (AI -> nearest human within `UxSplitSubAiRadiusUU`); else `UxSplitSubUnmatched`.
>    Placement: the game widget's render transform only (never its visibility, never AddToPlayerScreen); a line for
>    everybody: the game box in P1's half + one guest-owned WBP_Subtitles clone per guest (viewport, same z; text,
>    speaker, language, text size, backing opacity copied; `UxSplitSubBoth`). FAST text poll = fallback. Persisted for hot
>    reload. Against the research note: config fields are HorizontalAlignment / VerticalAlignment; WBP_Subtitles'
>    Construct calls UpdateFromConfig (clone creation guarded); the latest-due request wins (an older one the cooldown
>    swallowed would steal the line); the text placed last is never re-attributed; the probe follows `UxSplitProbeMs`.
>    NOT built: V-SUB-09 (per-player radio portrait, `UxSplitGuestHolo` "route"): hud.lua still hides the guest portrait
>    (V-UX-12) and P1's animates for every line. Limits: audio and trigger cooldowns shared; native-only lines
>    (TriggerOvertake, TryTriggerNarrativeMoment, cinematic sections) have no request; a new instance of the same event
>    within 1.5 s inherits the previous line's player(s).
> 2. **New G3 module `vpreview.lua` (3D vehicle cards, front end only).** One "photo bay" per VEHICLES column in the sky
>    (`SetupPreviewX/Y/Z`, `Spacing`): `GfnGameInstance.StaticVehicleClass` (BP_StaticVehicleBase_C) spawned deferred with
>    `preset` (a hard ClassProperty) set before FinishSpawningActor (the game's own spawner path), a SceneCapture2D with a
>    show-only list (captures only from Lua, never every frame) into a 640x360 RGBA16f target, an optional fill light.
>    Ready = unit containers > 0 and bounds equal on two samples 100 ms apart; then framing from the bounds, turntable,
>    a capture every `SetupPreviewCaptureMs`. No hooks, no FindAllOf, no soft pointers. Driven by setup.lua (want / brush
>    from renderColumns, tick from the FAST pollNav, released in showStep / close / forget and when a player leaves);
>    `SetupPreview3D = false` = the 0.7.1 cards. Listed in main's MODULES after setup (a load error shows at boot) and in
>    PERSIST_MODULES (own shared variable `SWGRCouch.vpreview.actors`: the next Lua state destroys the bay actors on its
>    first game-thread tick). Corrections to `vehicle-preview.md`: (a) `M_UI_RetainerBox_ScreenSpace` is NOT a
>    pass-through (decoded: MF_UI_WarpUVs, Radial, CustomRotator, SmoothStep, Blend_LinearDodge, T_UI_WarpLines,
>    T_SC_StarMap_TwinkleNoise_M); it stays the default (the game's only opaque UI material with a texture parameter);
>    A/B: Epic's VirtualCamera `M_ThumbnailMask` (param Target, AlphaComposite, rounded corners) or
>    `SetupPreviewBrush = "texture"`; (b) the render target's outer is the GameInstance and the MID is transient: neither
>    pins the front-end world; (c) the default rebuild is "respawn" (unit count 0 -> > 0 is unambiguous; "update" =
>    V-VP-02); (d) the fill light is given in lux at the model (`SetupPreviewFillLux` replaces SetupPreviewFillCd);
>    (e) cards are 16:9 with the 2D art centred, the manufacturer badge top left (`vehicles.badge`, TH_<Model>.Thumbnail),
>    the livery owner's portrait as an inset, and an automatic 4-player shrink (`SetupCardRowW`: 187 px).
> 3. **Pause phase 2 (`pause.lua` B2/C2/D2/E2 + `menubridge.lua`).** Every screen opened FROM a split-race pause belongs
>    to the pause controller (`ownerFor(pauser)`). C2: Settings and its pages (requested through ChangeStateTo, B reads
>    newState) are pre-created for the controller and acquired by the CSM (`PauseSubScreenPrecreate`). Confirm dialogs
>    (WBP_Modal_C in the P1-owned Dialog container; DT_DialogData Accept -> Yes, Cancel -> No) are answered by the
>    controller through menubridge (A / B = last button / D-pad; `MenuBridgeDialogs`) while the guests' IMC_UI is
>    lowered (D2, `PauseDialogGuestUi`). menubridge: a guest's own screen is native while its IMC_UI is boosted
>    (`MenuBridgeGuestNative`, run I); B on a screen without RESUME runs its own back path (`MenuBridgeBack`); the
>    controller drives a pause screen another player owns (`MenuBridgeControllerFallback`); the front-end profile card
>    owned by a guest after a split race is re-owned by P1 (`MenuBridgeProfileOwner`; the activatable main menu is never
>    re-owned). E2: sub-screen probes + one focus fix. New exports `pause.controller()`, `guestUiNative(pc)`,
>    `dialogWidget()`; `status()` gains ctsHook, ctsCalls, subRequests, subScreen, imcDialog.
> 4. **HARD RULE of Revision 0.5.1 §1 stays as written; B2 is OPT-IN.** B2 is a native pre-hook on
>    `CosmeticStateMachine:ChangeToState(SoftObject<UCsmAsset> NewState, Str reason, Object payload)` (the Logbook
>    request). UE4SS 3f4037d2's pre-dispatch (LuaMod.cpp `lua_unreal_script_function_hook_pre`) runs the
>    SoftObjectProperty pusher with `Operation::GetParam` on that param for EVERY ChangeToState call of EVERY CSM while
>    registered; that only wraps the address (`push_softobjectproperty` -> RemoteUnrealParam) and the callback never
>    reads it, but run F crashed right after a hook on TestPreflightCheckInput (also a soft param), and the rule forbids
>    hooking one. Decision: `cfg.PauseSubScreenHook = false` (default). Off: the Logbook is created for the last local
>    PC and menubridge's controller fallback drives it (sub-screen probe WARN + `... is P2's but the pause controller is
>    P1`). It is turned on only for the dedicated V-PAU-20 run (README §9). After a clean run (LOGBOOK from P1 and P2,
>    PHOTO MODE, race end, no crash) the lead amends §1 explicitly ("a native pre-hook on a function with a by-value soft
>    param is allowed when the callback never touches that param") before the default changes.
> 5. **Integration review fixes.** subsplit: the ability-hit choice is explicit (`hitter and h.inst or h.tgt` handed a
>    PlayerHits line to the HIT player when the hitter's racer state was not cached; nil now keeps the poster); the
>    engine-wide GetWorldSubsystem poster hook has its own switch `UxSplitSubPosterHook` (run-H rule: one switch per
>    hook family; off = 6 hooks, requests without a poster, placement and clones unchanged).
> 6. **Config and wiring.** 51 new config.lua keys (UX split: subtitles; Race setup: 3D vehicle preview; Pause phase 2;
>    MenuBridge*) with ENUMS / POSITIVE / MIXED checks; MIXED takes an optional max (`UxSplitSubHalfFrac`: "auto" |
>    0..1). `C.SUB_RULES` and `C.VERSION = "0.8.0"` in consts.lua. diag F9 gains `menubridge`, `subsplit` and
>    `vpreview` sections and a pause `phase 2:` line. main.lua: MODULES += vpreview (after setup), PERSIST_MODULES +=
>    vpreview; subsplit init after uxsplit, FAST / MAIN after uxsplit's ticks (as delivered).

> **Revision 0.7.1 (2026-10-07, run I, `state/runs/20261007-16*-session-I/`). Binding; it overrides 0.7.0 where they
> differ.** 0.7.0 ran live: messages, danger, BotEngineInfo remap and both players' pause verified (README "Run-I
> results"). Changes: (1) new G5 module `menubridge.lua` (FAST, after `pause.poll`): a guest-owned screen or a shared
> post-race screen takes the player's A/B by clicking the selected `CommonButtonBase` (`HandleButtonClicked`) when the
> game did not react within `cfg.MenuBridgeWaitMs`; another player's A on a pause screen too; non-owners get Game+UI
> input on shared post-race screens (P1's PC saw no keys there). (2) `wreck.lua`/`chasecam.lua`: camera ACTORS render
> black in a guest's view and `TargetActorOverride` made the game pause itself, so `WreckCarCam` "auto" keeps a guest
> whose pick is a camera-less (AI) car on its own wreck (V-WD-22); `WreckSpectateTarget` default "ai"; the camera
> guard measures an override against the watched car. (3) `install.sh --quiet-console` also sets ConsoleEnabled=0.
>
> **Revision 0.7.0 (2026-10-07, after run H, `state/runs/20261007-1313-session-H/`). Binding; it overrides Revision
> 0.6.0 and older where they differ.** User: "System malfunction / perfect landing and other screen. Are shared between
> players. Each ux should be fully autonomous", "Even before wrecked the ux were sharing perfect landing and danger
> (changing colors and trembling)". Research: `notes/research/ux-split-messages.md`, `ux-split-visuals.md`,
> `ux-split-inventory.md`, `live-run-H-ux-facts.md`. Not run in the game yet (§6 Session I).
> 1. **New G5 module `uxsplit.lua`** (contract in §4.2): armed only in a split race (PRERACE/RACING, 2+ local players,
>    not single view), by its own ticks or by `hud.ensureGuest` right before a HUD is added. Its native hooks are
>    registered on arming and UnregisterHook-ed on disarm (POSTRACE, `"leaving"` from the LoadMap pre-hook, any phase
>    away from PRERACE/RACING): the run-H rule after the probe crash (hooks left across a level transition). Ids in
>    `_G.SWGRCouch_uxsplit_hooks`; every callback checks a flag, runs in pcall, counts, returns nil (two return
>    overrides). Facts used, verified in run H: native UFunction hooks fire for Blueprint calls; a post-callback's
>    non-nil return overrides the return value (UE4SS source); message dispatch is synchronous with room.
> 2. **Messages** (`UxSplitMessages = "route"`): poster attribution through the `GetGameInstanceSubsystem(self,
>    GfnMessagingSubsystem)` call every Blueprint poster makes right before a post (car UI component -> its controller;
>    ability feedback -> its vehicle, the Disruptor -> the targeted player; HUD widget -> that HUD); container diff in
>    the AddMessage* post-hook; copies in other players' HUDs collapsed (`UxSplitMsgHide`), re-asserted; full
>    containers -> pending copies matched by text later, the same id already on screen shared meanwhile; `RemoveMessage`
>    by id / `FlushMessageContainer` -> plain messages re-posted for the remaining holders (`UxSplitRepost`; rows
>    `C.MSG[id].repost`; parameterised rows never re-posted); native (race-timeout) messages global; AI / the game's
>    hidden HUD -> nobody; elimination rows posted by every HUD instance (`C.MSG[id].perHud`): first post of a burst to
>    every half, duplicates within 1.5 s hidden. Plan A limit: one queue per container (a hidden copy keeps its slot);
>    Plan B' (per-player DataTable rows + containers) is not done.
> 3. **Index remap** (`UxSplitIndexRemap`): `GameplayStatics:GetPlayerPawn` post-hook returns the guest's pawn for
>    `WBP_HUD_BotEngineInfo(_Memory)_C` in OUR guest HUDs (registry or the HUD being created). `hud.lua` checks the
>    guest BotEngineInfo's `"Vehicle State"` (writes it when the remap did not happen) and, in `"clone"` mode, REMOVES
>    the game's hidden HUD's bindings on P1's car instead of moving them (`UxSplitGameHud`).
> 4. **Danger** (`UxSplitDanger = "own"`): last-crash colours of `MPC_HUD_Parameters` never written (pre-hook
>    `Collection := nil`, verified by read-back, restore fallback) + per-HUD red tint while health is 1
>    (`UxSplitHudColours`); ramjet MPC animation stopped + icons + MPC pinned + per-HUD blue tint (`UxSplitRamjetColour`);
>    `GetFullScreenEffectsEnabled` -> false while armed and not paused (BP_VehicleState's global post-process follows one
>    pawn over every view) + per-player camera fades: last life (`UxSplitFadeMax` < 0.5) and a System Malfunction
>    flash, never on a crashing / wrecked / foreign-faded view (`UxSplitFullScreenFx`). Camera shakes, HUD sway and the
>    per-HUD scanline / SYSTEMS CRITICAL are per player already (visuals research §2.3-2.6).
> 5. **hud.lua:** the game's hidden HUD gets its 1D map / Img_1DMap_MidSection / countdown collapsed (`UxSplitGameHud`);
>    `sweepOrphanHuds` never removes the UIManager's HUD; guest lap offset taken only after P1's first start-line
>    crossing (offset 0 before, display 1..NumLaps; run H: LAP 2 on lap 1); guest radio portrait hidden
>    (`UxSplitGuestHolo`); `GuestHudCollapse` += `WBP_Hud_EventRamjetCounter`, `WBP_Hud_EventBonusTime`. New accessors
>    `hud.notifEntries()`, `hud.gameHudWidget()`.
> 6. **Still shared / phase 2 (not done in 0.7.0):** subtitles drawn across the whole window (P2's half too); the local
>    results, spectate and final results screens and the Settings / Logbook / confirm dialogs opened from a pause are
>    UIManager screens owned by P2 (the results screen may take no input at all: leave with
>    `UIBlueprintFunctionLibrary:ReturnToMainMenu`, README §9 V-UX-13); Eliminator danger zone per player; weather
>    particles on P1's camera; Concussed / Frozen / Heated / Blinded / Corroded full-screen effects off while split (no
>    per-player replacement); Plan B' messages.
> 7. **Pause (`pause.lua` rewritten; contract in §4.2, research `pause-split.md` §6).** Run H: a guest's Start soft-locked
>    the game in [PauseMenu] with no screen; no pause screen of a split race took input, rehosted or not; after P1's
>    wreck nobody could pause. Causes: two IA_Veh_Pause bindings on P2 (its own HUD + the P2-owned game HUD; a second
>    `ChangeStateTo(PauseMenu)` leaves `Paused_*`); the UIManager makes every screen for the LAST local PC; the
>    InputModeManager raises IMC_UI for the FIRST local player only; the pause CSM is a sub-CSM of `CSM_RF_InProgress`.
>    Layers, split race only, each switchable: A HUD input guard (game HUD of a guest that has its own HUD; every hosted
>    HUD from the request until resume + keys up), B one native pre-hook on `CosmeticStateMachine:ChangeStateTo`
>    (registered per split race, armed flag first, removed at POSTRACE / leaving), C the screen created for the
>    controlling player inside the hook and ACQUIRED by the CSM (our extra reference released), D guests' IMC_UI at 500
>    while paused, E owner focus, F safety net (F1 sub-state repair, F2 resume when the screen is missing, F3 another
>    player's Start resumes; "dialog up" = a persistent container holding a message), G restart of the pause CSM after
>    P1's wreck. The 0.5/0.6 rehost is off (`PauseMenuRehost` default `"never"`, `"auto"` = `"never"`). Config: §4.2
>    G1 config.lua "0.7.0". VERIFY V-PAU-09..18 (§6 Session I); V-PAU-04/05/07/08 superseded.
> 8. **Integration review (0.7.0).** Stored UObject wrappers (hud.lua's game HUD, uxsplit's HUD entries, panels, PCs,
>    tagged copies) get `U.ok()` before ANY member access: UE4SS resolves a member of a collected object from freed memory
>    (a native access violation pcall cannot catch). pause.lua undoes a request no pause followed (600 ms). uxsplit:
>    GetGameInstanceSubsystem hooked pre-only; class-kind cache per race; elimination bursts per HUD root; parameterised
>    rows never shared; a "{Status}"-only body matches nothing and a countdown copy is never claimed; remap returns
>    vehicles only; the full-screen override follows each FAST tick's pause state; MPC last-crash colours reset when
>    arming; a quiet disarm's leftovers given back on a re-arm in the same world. `hud.removeGuest` tells uxsplit
>    (`hudRemoved`); diag F9 gains a `pause` section.

> **Revision 0.6.0 (2026-10-07, after run G, `state/runs/20261007-1217-session-G/`). Binding; it overrides Revision
> 0.5.1 and older where they differ.** Every item below was found or proven in the live game in run G; the code is
> not run in the game yet (§6 Session H).
> 1. **Guest Enhanced Input (F1, root cause of dead guest actions; `inputfix.lua` V-INP-08).** A guest's
>    `EnhancedInputLocalPlayerSubsystem` had NO vehicle mapping context (0 `IA_Veh_*` of 98 mappings; P1 28 of 126).
>    Every guest that possesses a vehicle now gets P1's vehicle PAD IMC (`IMC_Vehicle_Default`/`_Alternative`, never
>    `_Keyboard`) via `SubsystemBlueprintLibrary:GetLocalPlayerSubSystemFromPlayerController` + a DIRECT
>    `sub:AddMappingContext(imc, prio, {})` (CallFunction with the interface UFunction fails), re-added when
>    `HasMappingContext` says it is gone, verified by counting `IA_Veh_*` in `PlayerInput.EnhancedActionMappings`,
>    removed in the front end. `cfg.InputFixGuestEnhanced` "add"|"off", `InputFixGuestEnhancedPriority`,
>    `InputFixGuestEnhancedRemove`.
> 2. **ignpad prefers the guest's own path (V-PRE-06).** A guest whose mappings include check actions (or whose
>    context is ok/game/pending) is WATCHED like P1: injection only after `IgnitionSilentPressesP1` silent starts on 2+
>    actions (integration review: one missed screen read must not switch a working guest to replays), and each replay
>    waits `IgnitionInjectDelayMs` (120) so a late native reaction flips the verdict to "game" first (no double input).
>    Mappings re-probed every `IgnitionMapReprobeMs`. F4c: the garbled `inject #` line was a `%d` of the float
>    `St.nowMs()` difference (string.format threw, U.log fell back to the raw format string), now floored.
> 3. **Pause (F2, `pause.lua` V-PAU-07/08).** `WBP_PlayerMenu_Presentation_C` counted as a pause screen; owner focus on
>    rehost; a pause with no shown pause screen (no Settings/Photomode/Stickerbook state, nothing on the UIManager
>    Dialog layer) for `PauseLostMenuMs` is repaired: re-add -> reopen via CSM Idle + PauseMenu -> resume.
> 4. **Wrecked guest view (F3, `chasecam.lua` + `wreck.lua` V-WD-19/20)** and **guest crash view (F4a,
>    `CrashCamGuest = "car"` default, V-CC-07)**: see G-wreck "0.6.0 (run G, track B)" in §4.2.
> 5. **View guard (F4b, `viewguard.lua` V-VG-01):** a still-racing player whose view became another player's DNF
>    cinematic (`BP_PlayerFailedCam_C`) is put back on its own car; `cfg.ViewGuard`; F9 line `viewguard: on fixes=`.
> 6. **DLL reload thread (F4d, `swgr_inputfilter.dll`):** the cfg is re-read every 250 ms by a thread started in
>    DllMain (`CreateThread`/`Sleep` imports), so a `wo`/`w` bind applies without an input event; the owner table is
>    under a spin lock; integration: a `wo` weak-pointer store is ONE aligned 8-byte write (it now runs off the input
>    thread). Status file `reload_thread=1`.
> 7. **Pad order (F4e):** joined players follow `/dev/input/eventN` order under Wine (README §3.2).
> 8. **Test commands (`testcmd.lua`, `cfg.TestCommands`, off by default):** file-driven live test commands
>    (`<ModDir>/test.cmd` -> `test.out`), used by `tools/gr-session.sh cmd` and `tools/ignite.sh`.
> 9. **Steam-free launch (F5, prepared, NOT applied):** `notes/steam-free.md` (gbe_fork in the update-proof copy only;
>    Steam path stays the fallback).

> **Revision 0.5.1 (2026-10-07, after run F, `state/runs/20261007-1139-session-F/`). Binding; it overrides Revision
> 0.5.0 and the sections below where they differ.** User after run F: "the wrecked is still black screen and on top of
> that ignition game still doesn't work".
> 1. **HARD RULE (two UE4SS crashes, AV in memcpy 0xba04 bytes from null):** no module hooks, reads, writes or passes
>    a `TSoftObjectPtr` / soft-keyed map / soft param from Lua. The only remaining soft code (ignition.lua
>    `autoComplete`: `PreFlightChecksByAction` + `Server_OnSuccessfulPreFlightCheck`) runs only with the explicit
>    opt-in `cfg.IgnitionSoftComplete = true` (default false; it also failed in F3). Weak pointers: the DLL `wo` only.
> 2. **`crashcam.lua` (new, G5, FAST right after `wreck.fastTick`, persisted for hot reload):** a local human's CRASH
>    (tumble/reset, no wreck). Static findings (exe .text only): `UVehicleCrashCamComponent::OnCrashTagChanged`
>    0x140f4b256 spawns the `BP_CrashCameraActor_C` ONCE per car at the world origin (0x140f4b530, no transform) and
>    reuses it; 0x144a79aba starts it with `InitialCameraMode` = the first validated shot (null = no shot: the camera
>    stays at the origin, under the terrain = black); then `SetViewTargetWithBlend(CrashCam)` on the car's OWN PC;
>    nothing selects player 0 there. Slow-mo comes only from an evaluated crash camera (pods
>    `CVF_Slowmo_Crash_Plane` 1.0 -> 0.2 -> 0.7). A guest's crash view that is unusable (no shot / origin / far / NaN /
>    faded) for `CrashCamBadMs` goes to the guest's own car; learned per player (`CrashCamLearn`); held fades cleared;
>    slow-mo emulated per `WreckSlowMo` (`CrashSlowMoEmulate`, `CrashSlowMoCurve`). Exports `crashCamBad(pc)` (used by
>    `wreck.wreckEdgeView`) and `viewInfo(pc)`. VERIFY V-CC-01..06.
> 3. **Wreck view (wreck.lua wiring):** the wreck-camera hold (`WreckCrashCamHoldMs`) is skipped for a guest whose crash
>    camera is unusable, learned bad, or NOT PROVEN usable in an earlier crash (`CrashCamWreckHold = "proven"`,
>    default; "never" | "always"); the guest then goes straight to the moving-car view. P1 unchanged.
> 4. **Ignition:** `IgnitionMode = "auto"` is the default again: it touches no soft pointer in Lua. A guest's presses
>    are replayed by calling that guest's OWN `BP_GfnPlayerController_C` action event `InpActEvt_IA_Veh_*` with the IA
>    object (the BP builds the soft reference natively and calls `TestPreflightCheckInput` on its cached
>    `Pre Flight Check Component`, made the player's own first: `IgnitionFixPcComp`). Guests switch to replay after
>    `IgnitionSilentPresses` (1) silent check start, or at once when their PlayerInput maps none of the check actions
>    while P1's does; P1 is never replayed from the start (watching, `IgnitionSilentPressesP1` = 3), so P1's working
>    game path is never doubled. `p1game_guestauto` / `complete` no longer complete anything without the opt-in.
> 5. **Pause menu (run F f-11.png "faint"):** the screenshot was the menu's intro animation, restarted by our re-add 19 ms
>    earlier; the bone-white backdrop is the game's design. Rehost after `PauseMenuRehostDelayMs` checked every FAST
>    tick, HUDs hidden on the pause edge (`PauseHideHudsAtOnce`), parts probed and settled to their end values
>    (`PauseMenuSettle`, `PauseMenuSettleMs`). VERIFY V-PAU-06.

> **Revision 0.5.0 (2026-10-07, after run E, `state/runs/20261007-1033-session-E/`). Binding; it overrides the sections
> below (and Revision 0.4.0) where they differ.** Research: `notes/research/wreck-design.md` §9/§9.1,
> `presentation.md` §3b, `input-isolation.md` (photo mode), `race-setup.md`.
> 12. **Wrecked guest view (`wreck.lua`).** The game's own spectate replaced P2's crash cam (blend 0) and parked on P1's
>    still car: black/static half. Now: wreck camera (`VehicleCrashCamComponent.CrashCam`) held `WreckCrashCamHoldMs`,
>    then `cfg.WreckView = "car"`: `Client_OnSpectatorModeEnded` on the guest (impl `0x1470c9072`) and
>    `SetViewTargetWithBlend` to a MOVING racing car (re-picked when still/out/unusable). Camera fades read through
>    custom properties (`FadeAmount` @0x2EC, `bEnableFading` bit 0x08 @0x33E8, from `SetManualCameraFade` `0x1449f8286`)
>    and cleared. `cfg.WreckSlowMo = "game"` (default) with an emulated `CinematicTimeDilation` curve when the game's
>    slow-mo does not run. New exports: `wreck.photoMode()` -> active, why (150 ms cache); `wreck.viewInfo(pc)` -> nil |
>    `{pnum, phase='crash'|'car'|'native', targetPS, targetPawn, photo}`. V-WD-15..18.
> 13. **Pre-flight checks (`ignition.lua` + `ignpad.lua`, new, ticked by `present.tick`/`present.fastTick`, no init).**
>    Only the PC's Enhanced Input action events call `PreFlightCheckComponent:TestPreflightCheckInput(SoftObject<IA>)`
>    and a guest's are dead. ignpad polls each player's keys (`IsInputKeyDown`), a native PRE hook on
>    `TestPreflightCheckInput` records what the game delivered, undelivered presses are replayed
>    (`cfg.IgnitionPadAssist`); pad prompts via `CommonInputSubsystem:SetCurrentInputType(Gamepad)` and fixed display
>    keys. `cfg.IgnitionMode = "auto"` (default; completion rescue) | `"perplayer"` | `"simple"` | `"p1game_guestauto"` |
>    `"complete"` | `"off"`. V-PRE-06..09.
> 14. **Photo mode.** `UPhotoModeManager::EnterPhotoMode()` puts every local player in photo mode (each PC possesses a
>    `BP_PhotoModePawn_C`; Enhanced Input routed per ControllerId, the raw-input filter is not involved). Shared detector
>    `phase.photoMode()` (+ `"photomode"` event): hud hides every hosted HUD, pause shows no menu fix, inputfix turns the
>    native filter off and leaves the contexts, ignition pauses, wreck pauses its view guard / slow-mo. V-PH-01,
>    V-HUD-16, V-INP-07, V-WD-17.
> 15. **HUD stability (`hud.lua`).** Every widget identity test compares addresses (two UE4SS wrappers of one widget did
>    not compare equal: the game HUD was re-placed 3-4x/s, the run-E "lag after the wreck"); change logs rate-limited;
>    a wrecked/spectating local player's HUD hidden (`cfg.HudOutPlayers`). V-HUD-14..16.
> 16. **Other run-E fixes.** `pause.lua`: the pause screen forced visible and re-added full screen owned by the pauser
>    (`cfg.PauseMenuFix/Rehost/Owner/ZOrder`, V-PAU-04/05). `inputfix.lua`: the bind check compares addresses
>    (weak pointer -> object), accepts the PC's or LocalPlayer's subsystem, waits for the DLL `wo` copy (V-INP-01).
>    `phase.lua`: `redetect` on the first frame after a (hot) load (`cfg.PhaseBootWarnMs`, V-CORE-14). `setup.lua`:
>    one row per track layout (`cfg.SetupTrackDedupe`, V-SET-12). `vehicles.lua`: class renders, pods use the planet's
>    Arcade pod art (V-SET-13).

## 0. Ground rules, evidence keys, facts verified in this pass

**Evidence keys.** `[MT§n]` = `notes/research/mainmenu-tabs.md`, `[RB§n]` = `race-builder.md`, `[PS§n]` =
`player-spawn.md`, `[UI§n]` = `ui-toolkit.md`, `[HUD§n]` = `hud.md`, `[NET§n]` = `netcode.md`, `[API§n]` =
`ue4ss-api.md`. `[HERE]` = checked during this architecture pass (list below).

**VERIFY ids.** Every runtime assumption carries an id `V-<AREA>-<nn>` (areas: CORE, TAB, LOB, JOIN, BLD, LCH,
SPL, HUD, GFX, PAU, TKO, NET, DIAG). In code it is written as `-- VERIFY(V-HUD-03): <what>` on the line that
depends on it. Section 6 lists every id with its test. Where a fallback exists it is a `config.lua` switch; the
switch name is given with the VERIFY.

**Facts verified in this pass [HERE]** (commands: `grep`/`sed` over the UE4SS source tree `ue4ss-src-3f4037d2`;
`python3 -I scripts/reflect-func-all.py`, `reflect-types.py --class`, `reflect-enum.py enum` on the exe;
`work/script-objects.tsv`, `work/bpprops/*.txt`, `notes/asset-list.txt`):

| Fact | Evidence |
|---|---|
| `io` and `os` exist in mod Lua states (`luaL_openlibs`) | `LuaMadeSimple.cpp:682` `open_all_libs`, called for mods at `LuaMod.cpp:5863`; `linit.c:47-48` |
| `main.lua` is loaded with chunk name `"@" .. <absolute path>`; `package.path` gets `<Scripts>/?.lua` | `LuaMod.cpp:5964`, `LuaMod.cpp:1100-1111` |
| The `URL` argument of LoadMap hooks is an **opaque** `FURL` userdata (no fields, no methods) | `LuaFURL.cpp:42-55` (metamethod/member stubs are `todo`) |
| A LoadMap callback returning a bool calls `TrySetReturnValue` (changes LoadMap's result, not a skip). **We always return nil** | `LuaMod.cpp:6450-6480` |
| UFunction params flagged `Const` (e.g. `const FText&`) are plain inputs, not out-tables | `LuaUObject.cpp:203-204`; `WBP_Tab_Btn_C.SetText` / `WBP_Vertical_Btn_C.SetText` `InText` = `Parm|Out|Const|RefParm` (`work/bpprops`) |
| Every game class we name lives in `/Script/Griffin` (FrontEndGameMode, RacingGameState/Mode, VehiclePawn, GfnPlayerController/State, GfnGameInstance, UIManager, CosmeticStateMachineManager, ViewModelSubsystem, EventRecipeSubsystem, PlayfabOnlineMatchmaking, PvpFlowComponent, PlayerSpectatorComponent, FrontEndGameState, GfnUserSettings, FuseScreenWidget, FuseHudWidget, CsmAsset) | `work/script-objects.tsv` (from `global.utoc`) |
| `UGfnUserSettings.TakedownCameras` and `.bEnableHwrt` are **Bool** (resolves [API§15 #8]) | `reflect-types.py --class UGfnUserSettings` |
| `ETwoPlayerSplitScreenType` Horizontal=0 Vertical=1 (Byte prop); `EThreePlayer…` FavorTop=0; `EFourPlayer…` Grid=0 (Enum prop); `EGfnOverallScalabilityOption` Low=0..Custom=4 | `reflect-enum.py`, `reflect-types.py --class UGameMapsSettings` |
| Signatures: `IsInputKeyDown(FKey)->bool`, `WasInputKeyJustPressed(FKey)->bool`, `OpenLevel(WorldContext, Name LevelName, bool bAbsolute, Str Options)`, `GetClientTravelOptions()->Str`, `ClientTravel(Str URL, Byte TravelType, bool bSeamless, Struct MapPackageGuid)`, `GetGameInstanceSubsystem(ContextObject, Class)->Object`, `IsStateActiveByRef(Object)->bool`, `IsStateActive(Name)->bool`, `GetStateMachineForRoot(Object)->Object`, `ChangeStateTo(Object, Str, Object)`, `GetRaceEventVM()->Object`, `GetWidgetInLayer(Class, EUILayer)->Object`, `HandleNetworkFailure(World, NetDriver, Byte FailureType, Str ErrorString)`, `OnUserInputDeviceChanged(Enum NewConnectionState, Struct PlatformUserId, Struct InputDeviceId)` (flags 0x80401, native), `Server_Cheat_FinishRace(bool)`, `Client_RequestAckObjects()`, `Server_NotifyCoreObjectsArrived()`, `AddChildToGrid(Content, InRow, InColumn)->GridSlot`, `GetInputSourceOverrides()->TArray<enum>` (array **return**), `GetSelectedIndex()->int`, `SetUserFocus(PlayerController)`, `RequestRefreshFocus()`, `BP_SetIsInteractionEnabled(bool)`, `TransitionIn()` (BlueprintEvent), `UnregisterInputComponent()`/`RegisterInputComponent()` | `reflect-func-all.py` |
| Engine property names: `UWorld.NetDriver/AuthorityGameMode/GameState`, `AActor.Owner`, `APlayerController.Player`, `UGameInstance.LocalPlayers`, `ULocalPlayer.ControllerId/bSentSplitJoin`, `AGameStateBase.PlayerArray` + `GetServerWorldTimeSeconds`, `UEngine.GameUserSettings/GameViewport/NetDriverDefinitions` | `work/reflect.tsv` |
| `WBP_FE_MainMenu_C` has a BP `Tick`; `WBP_Hud_EventLapCounter_C` has BP `UpdateCurrentLap` (called from its Tick); `WBP_Common_Btn_C` has a BP `BP_OnClicked` body; `WBP_FE_QuickRace_Custom_Widget_C` root = `FuseGridPanel_0` (3 slots: `FuseGridPanel_1`, `List_Choices`, `Btn_Go`); its `ChosenCondition` is a 12-byte struct (FGameplayTag) | `work/bpprops/*.txt`, `work/exports/WBP_FE_QuickRace_Custom_Widget.txt` |
| Asset paths used in §4 (`CSM_PauseMenus_PauseMenu/Idle/Root`, `CSM_RF_*`, `WBP_*`, `GMV_Race`, `VA_Car`, `VBD_000_1Mastiff`, `L_SeamlessTravel.umap`) exist | `notes/asset-list.txt` |

> **Revision 0.10.0 (2026-10-09, crash_2026_10_08_13_27_33; notes/research/ue4ss-hook-thread-gc.md). Binding; it
> overrides every older sentence below that wraps keybind bodies in `sched.run`.** RegisterKeyBind callbacks run on
> UE4SS's event-loop thread, while the game thread may be inside a UE4SS binding on the shared hook `lua_State`;
> native-hook, loop and one-shot callbacks take no mutex, and the process-wide `lua_lock` is dropped around C calls and
> allocations. A keybind body that calls ANY UE4SS function (ExecuteInGameThread = `lua_xmove` + `luaL_ref` onto that
> state) corrupts it. Rule: every keybind goes through `keyq.bind` (load time only, main.lua top level); the event-loop
> callback is the allocation-free `seq[label] = seq[label] + 1`, and `keyq.drain()` (first line of the FAST tick, every
> phase) runs the bodies on the game thread. Hot reload (Ctrl+F11 / `couch reload`) only with `cfg.AllowHotReload`.
>
> **Revision 0.10.0, continued (2026-10-10: RACERS step, front-end menu owner, game track pools; run live in three
> sessions on CL382493, `notes/research/live-run-racers-facts.md`). Binding; it overrides 0.9.x and older where they
> differ.** The RACERS contract is `notes/design/vehicle-step-v2.md` with its "Review corrections" RC-1..RC-15. It was
> written for "0.11.0" and shipped as 0.10.0: read its "0.11.0" as 0.10.0 and its "0.10.0 columns" as the 0.9.x columns.
> 1. **Step 5 RACERS (new modules).** One card per local human (P1 + joined guests), each on its own PILOT -> VEHICLE ->
>    PERKS -> READY. Cards, session memory, preview bays and persisted picks are keyed by ControllerId; pnum only numbers
>    and colours the cards. `cfg.SetupPlayerFlow = "classic"` keeps the 0.9.x VEHICLES columns (also used for one page
>    when the cards cannot be built). Require rule (§4.0): G1 + `vehicles` + `perkdata` at the top, the rest lazily.
>    - `pilots.lua` (G4): the static pilot table (v2 §4.1: art paths, class gating, racer style, signature preset),
>      defaults, uniqueness, RacerDef resolvers. Game reads: `P.def` (RacerDef by static path), `P.favourite`.
>    - `perkdata.lua` (G4 data): generated by `tools/gen-perkdata.py` from `work/decoded/perks/*.json` (CL382493 paks;
>      self-check `work/decoded/perks/perkdata.summary.txt`): 45 abilities (8 slot families + the crash slot), 316 parts
>      in 12 picker categories, 41 traits, 15 speeder + 6 pod styles, 27 kits. No function, no game call; every texture
>      a static path (never derived from an asset name, never from a soft pointer).
>    - `perks.lua` (G4): pure loadout logic (kits, L/R cycling, pickers, detail data, `validate`, `encode` / `decode` of
>      the `LastRaceRacers` code, POWER / ENERGY totals). Requires only `config` + `perkdata`, touches no UObject
>      (offline tests `work/tests/perks_test.lua`, plain Lua 5.4). Items with `needs` ramjet / critmalf follow the class's
>      system flags handed over from `perkapply.systems` (RC-2).
>    - `perkapply.lua` (G4; game writes, game thread; no hook, no FindAllOf, no soft pointer, no UIManager query):
>      (a) launch base `VBD_000_1Mastiff` / `_Plane` (no abilities, no parts, PL 0) with `UnlockedAffixSlots` raised in
>      memory to `cfg.PerkPartSlots` around `LaunchCustomRace` (live: `4 -> 6 -> 4`); restored right after the call, on a
>      refusal, at FRONTEND and, from the persisted record, after a hot reload (PERSIST_MODULES); (b) pilots before the
>      AI class loop: `FRecipeRacerSetup.Pilot` + `GfnPlayerState.Pilot` per human; an AI holding a human's pick gets the
>      next free pilot AND adopts it on its front-end PlayerState (`adoptPilot`: `Pilot`, `PlayerNamePrivate` =
>      `URacerDef.CharacterName`, `OnRep_PlayerName()`; the travel copies both: run 1 listed an AI as "Katja Mox", P1's
>      pilot), plus a race-side net `fixAiPilots` (once per world: an AI PlayerState whose pilot differs from its recipe
>      entry adopts the entry's pilot and name, seated pilot rebuilt by `SynchronousRefreshPilot`); (c) each human's
>      loadout written field by field into `ps.RacerBuildState.VehicleBuilds[idx + 1]` (upgrade slots from the `VU_*`
>      defs, ability classes, crash ability, affix slots with `Status`), every field read back; (d) race world
>      (`raceTick` from `launch.raceTick`, PRERACE / RACING, once per world and human): verify, traits by
>      `Server_ApplyPassive` (live: `PassiveList 4 -> 7` per human), late fallback for lost parts (flaws skipped,
>      RC-13), seat check (`PilotSeatCheck`). P1's race record is keyed by `LocalPlayers[1]` = ControllerId 0, also when
>      `HotplugPadToP1` gave P1's LocalPlayer another ControllerId. Energy costs come from the native config CDOs
>      (`Default__Ability<x>Config.EnergyCost`, RC-4): no `BP_Ability_*` class loads before the launch.
>    - `cards.lua` (G3; UI only: no input, no game-state reads): one widget tree and one renderer for P1 and every guest;
>      per-width-class layout tables W (1-2 players, inner 1656 su) / M (3, 1076) / N (4, 781) on canvas panels (no
>      rebuild on a class change); diffed rendering (only changed rects / texts / fonts / colours / textures reach the
>      engine; every cache cleared on a page re-show and a class change, V-RC-06); lazy card shells, stage panels and
>      pickers (`CardBuildsPerTick`), `CardRendersPerTick` renders per FAST tick; texture budget per FAST tick:
>      `CardLoadsPerTick` small loads plus at most one texture >= `CardLoadBigBytes` (RC-9); a cached texture is used
>      only while its FName is the asset's (RC-7). Never `WBP_Character_Ability:SetAbility/SetTrait` (blocking soft
>      loads) and never a soft property.
>    - `racers.lua` (G3): one state machine per player, `St.racers.players[ControllerId]`; every input ends in one
>      dispatch (`racers.event(who, ev)`, also the test.cmd entry). Guests are polled on their OWN PlayerController
>      (`IsInputKeyDown`: d-pad / left stick with repeat, A on the press edge, B on the release when held shorter than
>      `CardBackTapMaxMs`; a hold of `LeaveHoldMs` leaves through join.lua). P1's pad moves CommonUI focus on an
>      invisible 5-button sink in the footer (`CardP1Input` "sink": explicit navigation rules, a move onto a neighbour =
>      one direction, focus back on the centre; the buttons are registered with `opts.noClaim`); a sink click is P1's
>      accept, held one FAST tick and dropped when a guest's A coincides (`CardGuestClickGuardMs`); a P1 direction
>      coinciding with a guest's same direction is dropped (`CardP1DirGuardMs`, RC-10). P1's keyboard: keyq ->
>      `lobby.onKey` -> `setup.onKey` -> `racers.onKey`; P1's B: `setup.pollP1Back`. Each card's view model is built right
>      before `cards.render` in the tick that takes its vpreview brush (GC rule). Persists `LastRaceRacers`
>      (settings.txt, per ControllerId: `<ctrlId>=<pilot>@<preset>@<loadout code>;...`).
> 2. **New module `feowner.lua` (front end; `notes/research/menu-owner.md`).** The UIManager makes every screen for the
>    LAST local PlayerController, and the seamless return to `L_FrontEnd` after a split race carries the guests' PCs, so
>    the main menu was built for the last guest (P1's pad dead: its CommonUI router had no screen). feowner pre-creates
>    `WBP_FE_MainMenu_C` for P1 right before the front-end CSM shows it (pre-hook on
>    `CampaignSubsystem:GetMainMenuShouldOpenScenarios`, which `BP_Csm_FrontEnd_PickPrimaryMode` calls on every entry,
>    the arrival after a race included) and the front-end sub-screens (Settings and its pages, Credits, Stickerbook,
>    inspect screens) and their returns (`CosmeticStateMachine:ChangeStateTo` / `BackToPreviousState` pre-hooks in
>    FRONTEND). The CSM acquires the pre-created widget (pause.lua's C pattern); the extra reference is released, a
>    widget not acquired within 1500 ms is removed. The Multiplayer tab is hidden and disabled while guests exist (its
>    state waits for an empty layer, which no pre-create can feed). Never `GetWidgetInLayer`. Results screens are not
>    covered (menubridge). Keys `FrontEndMenuOwner` ("game" = kill switch), `FrontEndMenuPrecreate`,
>    `FrontEndSubScreens`, `FrontEndHideMultiplayer`, `FrontEndMenuZ`. VERIFY V-FEO-01..13.
> 3. **`setup.lua` track pools (`notes/research/track-whitelist.md`).** `GetQuickplayTracksForVehicleAndPlanet` (the dev
>    panel's helper) returns every loaded TrackDef of the planet (Prologue slices, campaign copies, shakedown, time-trial
>    and boss tracks). The setup now offers what the game itself offers, read from the GameInstance's own data assets:
>    Quick Race + Quick Podrace (`PvpInstantActionDef` / `PvpPlaneInstantActionDef`), the Arcade's race tracks
>    (`ArcadeDef`, precision courses excluded), Multiplayer Tour + Podracing Tour (`PvpRunDef` / `PvpPlaneRunDef`), by
>    `cfg.SetupTrackSet` ("quickrace" | "arcade" default | "game" | "all" = the 0.9.x lists). Arcade-only pod tracks
>    only with `SetupTrackArcadePods` (8 pods on TRAK_WHP_PLANE_FWD crashed at PRERACE, V-TRK-08); `SetupTrackPoolConds`
>    keeps only the conditions the pool gives a track. A static whitelist (CL382493) is the fallback when the pools
>    cannot be read. Live: `track pools 'arcade': 73 TrackDef(s) (game data) (V-TRK-01)`.
> 4. **menubridge raw A (`cfg.MenuBridgeRawA`, V-MB-08): tried, FAILED live.** On a shared results screen another player
>    owns, P1's PC sees no key and V-MB-07's Slate focus did not click (runs L, N1). 0.10.0 reads a non-owner's A from
>    its raw vehicle input (`RawInputSubsystem.EnhancedPlayerInput.ActionInstanceData`: `IA_Veh_Boost`, or
>    `IA_Veh_Throttle` in the alternative layout, Triggered / Started / Ongoing). Live 2026-10-10, while P1 held A: no
>    `IA_Veh_Boost` entry in P1's ActionInstanceData, `IA_UI_Accept` TriggerEvent 0,
>    `IsInputKeyDown(Gamepad_FaceButton_Bottom)` false. Likely cause: the screen is owned by the last local PC and P1's
>    CommonUI router has no active screen. Task #10 stays open; another player's A continues (V-MB-01/02 pass).
>    `MenuBridgeRawA` stays `true` in config.lua (it only reads; no raw A was ever detected).
> 5. **`swgr_inputfilter.dll` on both builds (`notes/research/inputfilter-hotfix-port.md`).** The hotfix CL382493 moved
>    only the 6 code pointers the DLL compares. The DLL carries both constant sets, and `install()` picks the set whose
>    `vt[11]` and 5 handler slots match (auto-detect by vtable). `.status` reports `build=382493` | `381121` | `unknown`;
>    on a mismatch `reason=` lists what each set expected. inputfix logs `native filter loaded: installed=1 reason=ok
>    build=382493` (V-INP-10). The new UE4SS refuses the Lua weak write of `RawInputSubsystem`; the DLL's native copy
>    binds every guest car (as designed since 0.4.0).
> 6. **New and changed APIs.** `launch.start(opts)`: `opts.acceptDormant = true` accepts un-joined pads at once (the race
>    setup's own second START; RC-1: the setup asks before its page closes). `launch.prepareExternal` keeps the classic
>    flow (`plan.flow` set to "classic": the dev screen's own `LaunchCustomRace` ran without the affix-slot patch). The
>    in-race override (`Client_SetOverrideVehicleRecipe`) is skipped in the cards flow: the recipe write gives every
>    human his car, and an override would rebuild the customisation over the loadout. `launch.plan` /
>    `St.launch.vehPlan` carry `flow`; picks are matched by ControllerId first (`perkapply.pickFor`, V-RC-26).
>    `c.setup.flow = "cards" | "classic"` (`setup.makeChoice`). `setup.debugJump(spec)` (test.cmd helper; returns an
>    error text unless `cfg.TestCommands`), `setup.p1Gamepad()`. vpreview: `setMode(key, "spin" | "still")`,
>    `stageMode(stage)` (`SetupPreviewSpinStage`), `recapture(why)` (still bursts after a page re-show, RC-12),
>    `stats()`; `tick()` returns `changed, keys` (`keys` = the bays that changed or went; the classic setup reads only
>    the first value); RACERS bays are keyed ControllerId + 1, with one global capture budget and spawn gap.
>    `ui.registerButton(w, id, fn, opts)` / `ui.button(pc, id, text, fn, opts)`: `opts.noClaim` skips the
>    one-action-per-press dedup (`ui.claimAction`, `lobby.consumedClick`).
> 7. **Config and wiring.** 64 new config.lua keys (`FrontEnd*`, `MenuBridgeRawA`, `AllowHotReload`,
>    `SetupVideoSettleMs`, `SetupTrackSet` / `SetupTrackArcadePods` / `SetupTrackPoolConds`, `SetupPreviewCaptureBudget` /
>    `SpawnGapMs` / `StillBurst` / `SpinStage` / `PrebuildMs`, `SetupPlayerFlow`, `PilotStage`, `PerkStage`, `Card*`,
>    `Pilot*`, `Perk*`) with ENUMS / POSITIVE / FALSEABLE (`PilotExtras`) entries and three new check tables: NONNEG
>    (>= 0), CLAMP (`PerkPartSlots` 1..10, `PerkTraitSlots` 1..4) and SHAPES (`CardW` / `CardGap`: 4 numbers,
>    `CardPanelColour`: a colour). New defaults: `SetupPreviewSpacing` 20000, `SetupPreviewW/H` 960 x 540,
>    `SetupPreviewCaptureMs` 66; `SetupCampaignMap` true again (the public 0.9.3 had it false). `Defaults.LastRaceRacers`
>    (settings.lua ORDER / COMMENTS). `C.VERSION = "0.10.0"`. main.lua MODULES += `pilots`, `perkdata`, `perks`,
>    `perkapply`, `cards`, `racers` (after `cmap`), `keyq`, `feowner` (boot line `modules=42/42`); PERSIST_MODULES +=
>    `perkapply`. diag F9 gains a `racers` section (racers / perkapply / vpreview status + preview stats). install.sh keeps
>    an existing UE4SS-settings.ini's console choice (only a first install turns the windows on; `--quiet-console` turns
>    them off).
> 8. **HARD RULE (live, 2026-10-09/10): test probes guard cached UObjects with `U.ok`.** The "Settings crash" of
>    2026-10-09 21:20:41 was a `test.cmd` probe that called `St.menu.widget:GetOwningPlayer()` after Settings had replaced
>    the main menu. UE4SS's UObject `__index` only checks the object pointer for null, so a member lookup on a dead
>    object walks freed reflection data (AV in `FField::GetClass`). Confirmed: `FName("GetOwningPlayer")` has comparison
>    index 465218 = 0x71942, the name the crashing `__index` looked up (`notes/research/settings-crash-2026-10-09.md`).
>    Every Lua run inside the game, test probes included, follows §0 hard rule 5 and Revision 0.7.0 §8: `U.ok(x)` before
>    `x.Member` or `x:Fn()` on any object kept from an earlier tick or an earlier command.
> 9. **Live status (2026-10-10; what each id covered: the facts file).** Seen working: V-RC-01/02/14/15/16/18/19/20/21/
>    22/23/25/31/32/33/35, V-RC-04 (join at PILOT, hold-B leave), V-RC-17 (spawn gap, still bursts, release),
>    V-FEO-01/02/07/11/12/13, V-MB-01/02, V-TRK-01, V-INP-10 (0.10.0 meaning: DLL build match; README §9 "Run-G checks"
>    uses the same id for the pad order); 0 ERROR lines and no crash in the three sessions. Failed: V-MB-08. No live
>    evidence yet: V-RC-03/07/08/10/24 (pod race)/26/27/28/29/30/34, the 960x540 preview default (the tests ran
>    640 x 360) and the cards-flow skip of the in-race override (saved after the last race of the session).

> **Revision 0.12.0 (2026-10-10: UI v2, the launch hold, the back prompt, the opponents' tier; binding spec
> `notes/design/ui-v2/ui-redesign-final.md`, the UI v2 design spec, kept with the project notes and not in this repo;
> run live on CL382493 in runs `20261010-1209-ui-v2-A` to `20261010-1556-rc-0.12`). Binding; it overrides §1.1-§1.4,
> Revision 0.10.0 continued (the RACERS cards, the launch base, the install line) and every older sentence where they
> differ.** User request (workflow ui-v2): the mod's screens should "look like they belong to the game". The spec is
> the intent; where it and the code differ, the code and this revision win (spec work item WI-15 asked for this
> revision). Checks: V-FIN-01..16 (spec §14) and §6 Session U.
> 1. **Kill switch `cfg.UiStyle` ("v2" default | "classic").** Read when a page is built. After a live switch the
>    lobby rebuilds its content, and the RACE SETUP panel with it, at its next show (`styleCheck`); `setup.open`
>    rebuilds a page of the other style too (`v2.rebuild`); `racers.build` picks the card renderer per page.
>    "classic" runs the 0.11.0 code paths unchanged: the lobby rows of §1.2, setup's header / crumb / footer and lists,
>    cmap's classic views, `cards.lua` fed the classic view model (`perks.detail` style "classic"), the photo bays'
>    "cutout" rung. config.lua resolves the eight keys whose default UI v2 changed through a metatable: while
>    `UiStyle` is "classic", `CardW`, `CardGap`, `CardH`, `CardRowW`, `SetupCMapVideoW`, `SetupCMapBackground`,
>    `SetupCMapMapW` and `SetupCMapMapH` read their 0.11.0 values (`cfg.UiClassic`: {1720, 1720, 1140, 845},
>    {0, 60, 40, 40}, 1320, 3500, 768, true, 3500, 1200); a value config_user.lua sets is a plain value and applies in
>    both styles. Without the switch: a v2 lobby page that cannot be built keeps the 0.11.0 rows (no rebuild loop); a
>    `cards2.lua` that cannot load or init gives that page `cards.lua` and the classic view model (logged); a RACE
>    SETUP page that cannot be built leaves the lobby on the dev race builder, in both styles.
> 2. **HARD RULE (live, 2026-10-10): the launch hold.** An accepted `LaunchCustomRace` tears the front end down, and the
>    garbage collector frees its widgets before the mod's next callback, while `St.phase` still says FRONTEND /
>    LAUNCHING and every page still holds its widgets (theme forgets them on a new menu or a race phase). A call on a
>    freed widget is an access violation inside UE4SS that no `pcall` catches: 4 of 5 launches from RACE SETUP crashed
>    with the 0.12.0-dev build ("Fatal Error!" about 20 ms after the LOADING… pill, `UE4SS.dll+0x3e7ee5`: the v2
>    lobby's `v2Tick` repainted its poster tiles through theme's `scaleSet` -> `SetRenderScale` on a freed
>    FuseCanvasPanel; review ui-1). The 0.11.0 lobby had no per-tick painting. **Rule: from the first callback after
>    the one that made the accepted call until the launch is over, no front-end page, theme widget or main-menu object
>    is touched (no call, no member read).** Every front-end poll, tick, listener, timer and keybind body checks
>    `St.launchHold()` before it reaches such an object, and before any `U.ok` on it (UE4SS validity is address-based,
>    §4.2 `ui.onClicked`: the address of a freed widget can already hold another object). Race code is not affected:
>    the hold ends before the listeners of the first race phase run.
>    - Mechanism: `St.cb` (state.lua) is a callback serial, +1 at the start of every sched callback (the `run` /
>      `after` / `nextFrame` / `every` wrappers) and every `U.hook` dispatch (`U.anchorThread()`). `launch.start`
>      stores `St.launch.acceptCb = St.cb` once the PrimaryFlow check accepted the call. `St.launchHold()` =
>      `pending and accepted and acceptCb ~= St.cb`: the hold starts with the next callback, so the rest of the
>      accepting callback (the "launched" event, the "LOADING…" status) runs as before; `launch.prepareExternal` (dev
>      screen) sets no `acceptCb`, so its hold starts at once. The launch is over when `St.launch.pending` goes false:
>      the first race phase (phase.lua clears `pending` and `accepted` before it emits "race_enter" / "phase"),
>      FRONTEND, a launch timeout, a refusal.
>    - Gates: main.lua's `frontHeld()` (one log line per launch: `[main] launch hold: the front-end pages stop until
>      the race world (V-LCH-07)`) skips `ui.pollClicks` (FAST), `lobby.tick`, `menu_tab.pollTab`,
>      `nametags.namesTick`, `feowner.mainTick` (MAIN), `menu_tab.ensure` and `join.hotplugTick` (SLOW); `phase.tick`
>      keeps running (it ends the hold), so does `net.tick`. Early returns in `lobby.keepFocus` / `v2Tick` / `pollNav`
>      / `tick` / `onKey`, `join.poll`, menubridge's front-end tick and menu_tab's delayed un-highlight of our tab;
>      `keyq.drain` drops the presses (counted as done). theme: `guard()` (every builder method) returns nil, `live(e)`
>      is false (so `rectSet`, `alignSet`, `opacitySet`, `scaleSet` and `T.set` do nothing), the texture pump waits.
>      The "phase" listeners at LAUNCHING only drop references: lobby's calls `setup.forget()` instead of
>      `setup.close()`, vpreview's calls `vpreview.dropAll()` instead of `releaseAll()` (the bays' actors go with the
>      front-end world).
>    - Debug aid that found the path: while `_G.SWGRCouch_traceLeft > 0` (set from test.cmd only) `U.try` /
>      `U.tryEvery` log their tag before they run (a native crash's minidump holds no Lua stack). The last breadcrumbs
>      before a crash, 20 ms after "launch accepted": `ui.pollClicks`, `ui.keepFocus`, `lobby.v2Tick`,
>      `theme.pill.tick`, `theme.poster.focus` (twice).
> 3. **New G3 module `theme.lua`: the tokens and the shared chrome of the v2 pages (spec §2, §3, components C1-C12).**
>    No init and no loop. lobby.lua, setup.lua and cmap.lua (v2 views) build on it, cards2.lua takes its tokens only,
>    racers.lua its `inputMode`; all reach it lazily (`U.mod("theme")`). Beyond the G1 modules it depends on `ui.lua`
>    alone (`ui.ghost`, `ui.hasFocus`, `ui.hovered`).
>    - Tokens: `T.COL` (canonical colours; `T.alpha` and `T.hex` are memoised, so the diffed setters compare colours
>      by identity), `T.PLAYER` (= `C.COLOURS`), `T.PLANET` / `T.planet(k)`, `T.ROLE` (type roles), `T.FRAME`, the
>      object paths `T.TEX` / `T.MAT` / `T.WBP` / `T.FONT`, `T.glyph(key)` (the game's Xbox pad glyphs),
>      `T.textWidth(s, role, size)` (advance tables of the game fonts: Lua has no FGeometry; `UiMokiWidthScale`).
>    - Geometry: `T.pageGeometry(root)` on every page show (V-FIN-01): `UiPageOrigin`, else the Slate route (in this
>      UE4SS build `GetCachedGeometry` returns no fields), else the main menu's own layout (live: x 128 y 232 w 3584
>      h 1764), else 128 / 240 / 3584 / 1756; `T.toLocal`, `T.pxSu`. Builder positions are screen su (3840 x 2160).
>    - Primitives `T.text`, `T.image`, `T.set` (diffed: only changed values reach the engine) and the builders C1-C12:
>      `pageBackground`, `screenTitle` (`WBP_Screen_Title`), `stepRow`, `commandRow` (`WBP_CommonButtonBacker_Pill`
>      pills over ghosts), `statusPill`, `poster`, `ghost`, `settingsRow`, `groupHeader`, `checkBadge`, `lockOverlay`,
>      `detailColumn`; `T.nav(w, dir, target)` (an explicit navigation rule), `T.isFocused(w, p1)`. A builder that
>      cannot be built returns nil (logged once per kind and reason).
>    - `T.inputMode(now)`: P1's CommonInput type, "pad" | "mouse", stable for `InputModeDebounceMs` (KeyboardIsP1 =
>      "mouse"); `T.forceInputMode(mode)` for tests (through `setup.debugInputMode`).
>    - Life: every element and builder carries the generation it was made in. `T.forget()` (on the "menu" event and on
>      the race phases LOADING / PRERACE / RACING / POSTRACE; not on LEAVING / OTHER, which phase.lua can set late, in
>      the next front end) bumps the generation and calls nothing. Every builder method runs in `guard()` (throttled
>      error log; nil during the launch hold); `T.set` and the rect / align / opacity / scale setters check `live(e)`
>      (hold, generation, `U.ok`). Textures by hard path only, within a per-tick budget by cards.lua's rule (one
>      texture >= `CardLoadBigBytes`, up to `CardLoadsPerTick` small ones); no soft pointer. `T.tick(now)`, `T.status()`
>      (diag F9).
> 4. **New G3 module `cards2.lua`: the v2 RACERS cards (spec §9).** The `cards.lua` API unchanged (`init`, `layout`,
>    `ensure`, `render`, `tick`, `tex`, `releaseRenders`, `clearCaches`, `forget`, `cls`, `status`, `ROSTER_TILES`,
>    `PICKER_ROWS`; vehicle-step-v2 §5.6), so racers.lua's state machines and input model did not change. Its only
>    caller is racers.lua: `racers.build` picks the renderer per page (`St.racers.renderer` "cards2" unless `UiStyle`
>    is "classic"); the rest of racers reaches the cards through `CD()`. UI only: no input, no game-state read. It takes
>    theme's tokens and keeps cards.lua's machinery (diffed elements, the texture queue, where the scenario posters
>    always take the big slot, the build budget `CardBuildsPerTick`, the error panel). Each card is drawn like the
>    game's SCENARIOS posters from Fuse primitives only: no game widget Blueprint inside a card (no WBP_Common_Btn,
>    WBP_Character_Ability or WBP_DarkPanel), hard texture paths only, no soft property. Width classes W (1-2 players,
>    1762 su) / M (3, 1162) / N (4, 860); card height `CardH` (1300), shrunk to fit a shorter measured page. Texts are
>    never auto-shrunk: after layout `CD.tick` compares each changed text's desired size with its box and logs
>    `text overflow` once per string (V-FIN-09). Config: `CardThumbMask`, `CardGlyphs`, `CardFigureTint` (V-FIN-07),
>    `CardStripe` / `CardStripeAngle` (V-FIN-06), `CardStartPulse`, the layout and budget keys. `CardPad`, `CardFrame`,
>    `CardPanelColour`, `CardHighlight`, `CardDetail`, `CardDiamond` and `CardBackdrop` are read by cards.lua only
>    ("classic" only; config.lua marks them). racers.lua's v2 view model (spec §9.9) adds P1's input mode, the pilot's
>    poster tile, the game's model names, POWER / ENERGY as numbers, the short detail tags (`perks.detail` style "v2")
>    and the READY rows by P1's input mode.
> 5. **New G3 module `backprompt.lua`: P1's pad B on OPTIONS / RACE SETUP goes back (`cfg.BackPromptAsBack`,
>    V-BP-01).** In the front end the game keeps P1 in UI-only input, so before the first race P1's PlayerController
>    never sees pad B (lobby's OPTIONS poll and `setup.pollP1Back` stay blind). The press reaches CommonUI, and the
>    main menu's back action posts the game's own "QUIT GAME?" prompt (`DT_DialogData` row QuitGame) with ACCEPT
>    focused: one more A quits the game. backprompt answers that prompt No and runs the page's back step instead:
>    OPTIONS closes (`lobby.closeOptions`), RACE SETUP steps back (`setup.p1Back`; on RACERS the card's stage before).
>    On the plain lobby tiles (a main-menu tab) the prompt stays: B there is the game's own exit, as on every tab. When
>    P1's PlayerController does see B (after a race), lobby's / setup's own polls already went back in that press
>    (`setup.lastP1BackMs()` at most 150 ms before the post): backprompt only answers the prompt. With `KeyboardIsP1`,
>    pad 0 is a guest whose B still reaches P1's CommonUI back: the prompt is answered No and no back step runs (review
>    flow-1; the keyboard P1's back is Backspace).
>    - How: native pre-hooks on `GfnMessagingSubsystem:AddMessage` and `AddMessageParams` (raw `RegisterHook`; the
>      callbacks read their handler from `_G.SWGRCouch_backprompt_hooks.on`, so a hot reload swaps it) note a QuitGame
>      post and the prompts already visible. The FAST tick finds the new `WBP_Modal_C`, waits until it is ready (one of
>      its buttons holds focus, or 600 ms on screen), clicks its last button (`HandleButtonClicked`; QuitGame lists Yes,
>      No), again every 400 ms up to 5 clicks, and gives up when no new prompt shows within 2 s. The prompt search
>      (`FindAllOf("WBP_Modal_C")`) runs once in the hook, then at most every 250 ms while it waits, for at most 2 s
>      after a post (review flow-5 / ui-2): a bounded exception to hard rule 6.
>    - **Hook rule (binding):** the two hooks are registered only while OPTIONS or RACE SETUP shows on our tab (phase
>      FRONTEND, `St.menu.visible == "lobby"`, `lobby.optionsOpen()` or `setup.isActive()`), `BackPromptAsBack` is not
>      false and no launch is pending, and UnregisterHook-ed otherwise: no Lua runs inside the game's messaging in a
>      race or on another tab. `launch.start` calls `backprompt.disarm("launch")` right before `LaunchCustomRace`.
>      This is the run-H rule that uxsplit, subsplit, pause and restart follow in races (Revision 0.7.0 item 1),
>      applied to a front-end page (hard rule 13). The launch crashes were not these hooks: they also happened with
>      `BackPromptAsBack = false`.
>    - API: `fastTick()` (main.lua FAST, every phase, right after `ui.pollClicks`), `disarm(why)` (launch.lua),
>      `status()`. Reads `lobby.optionsOpen` / `closeOptions` and `setup.isActive` / `p1Back` / `lastP1BackMs`.
> 6. **lobby.lua v2 page (FREE MODE tab; spec §4, §5).** The emptied `WBP_Setting_List` root holds ONE
>    FuseCanvasPanel (`St.ui.canvas`) and everything sits on it in screen su (`theme.pageGeometry`; a page origin that
>    moved since the build shifts the canvas, V-FIN-01). A page whose theme elements were dropped while it lived is
>    rebuilt at its next show (`styleCheck`).
>    - Four painted posters over ghosts that keep their ROW_ORDER ids, so `St.ui.rows`, `refresh`, `focusedId`,
>      `activate` and `ui.pollClicks` work as before: the RACE event card (`race`: the chosen track's Arcade tile from
>      `setup.raceArt`, CHOOSE RACE without a choice), START RACE (`start`: locked with its reason and still focusable,
>      A posts the reason as a warn pill; "Launching…"), ADD PLAYERS / PADS ON (`pads`: the 2-press opt-in), OPTIONS
>      (`options`, new). The painted focus look follows the ghosts' CommonUI focus and mouse hover every FAST tick
>      (`v2Tick`, run from `lobby.keepFocus`); the tile graph is wired with explicit navigation rules (live: 8 of 8,
>      V-FIN-04). The START tile drops a click that coincides with a guest pad's A
>      (`join.guestPressWithin(CardGuestClickGuardMs)`, task #14), as racers does on P1's sink.
>    - The players strip replaces the slot rows: `join.slotStates()` (host / ready / disconnected / leaving / join /
>      connect / padsoff / later / frozen / empty), heads from `racers.lastPilotThumb(ctrlId)`; the network line while
>      NETWORK is not offline (`net.statusText`). Lobby messages (the "status" event) go to theme's status pill
>      (`StatusPillMs`; refusals and errors in the warn variant) instead of the status row.
>    - OPTIONS: a sub-page of the same page, built at its first open (`lobby.openOptions()` / `closeOptions(why)` /
>      `optionsOpen()`, test helper `lobby.debugOptions(on)`): "/OPTIONS" title, the rows that left the lobby, in
>      groups SPLIT SCREEN (2-player layout, Split graphics, Takedown cameras, Name tags), PLAYERS (Keyboard is player
>      1), NETWORK (Network; Host on port N / Connect to ADDR, hidden while offline), ADVANCED (Race builder: the
>      game's own race builder), each keeping the ROW_ORDER id of its classic row; the help / "Default value" detail
>      column; BACK in the command row. Back route: BACK, P1's pad B edge (when P1's PlayerController sees B),
>      Backspace, a tab change, backprompt (item 5). Left / right on a value row go through two invisible focus traps.
> 7. **setup.lua v2 page (RACE SETUP; spec §6, §7.1, §7.4, §7.5, §8).** `W.panel` is ONE FuseCanvasPanel in the lobby
>    root and every part sits on it in screen su: the hub / map page backgrounds (C1), "/RACE SETUP"
>    (`WBP_Screen_Title`), the step row in the game's tab style, the command row BACK / START RACE / SAVE AND RETURN,
>    the status pill, poster views for CLASS (Arcade posters and the VEHICLE SELECT info panel: `WBP_DarkPanel`,
>    `WBP_SectionSubLabel`, three `WBP_VehicleTrait`), CONDITIONS (tinted posters) and MODE (four mode strips, the
>    detail column, the Racers and Opponents rows, the grid strip), the settings-look list fallback, the RACERS card
>    row at (128, 548) and P1's input sink at (1800, cmdY). PLANET / TRACK are cmap's v2 views on the same canvas
>    (item 8). Every focus target is a ghost under a painted look; `S.items`, `M.onOption` / `M.onItem`, the START
>    gate and the input routes are unchanged.
>    - START RACE and SAVE AND RETURN show once (V-FIN-11): with P1 on a pad they are P1's READY card rows; with P1 on
>      mouse + keyboard (`theme.inputMode`) they are the command row on RACERS, and P1's READY cursor paints there
>      through `setup.commandFocus(id)` (racers.lua).
>    - Opponents (task #31, V-RC-27): the second settings row on MODE, under Racers. Setting `OpponentTier` (1..6,
>      default 1) = the speeder build tier the race launches on, i.e. the AI's strength; the value text comes from the
>      game's tier name ("TIER 3 · HUSKY (23%)"); pods have no tier (the row shows "Standard" and takes no focus). API
>      `setup.aiTierIndex()`, `aiTierPath()`, `aiTierPathFor(arch)`, `aiTierText()`, `stepAiTier(dir)`. `makeChoice`
>      (cards flow) and `deriveSetup` (a choice not made in RACE SETUP, e.g. one restored from settings.txt) put the
>      tier build's path into `c.setup.aiTierPath`, `launch.plan` carries it and `perkapply.prepareLaunch` launches on
>      it (`perkapply.launchBase(arch, pilotId, tierPath)`): the AI race with that tier's power and perks, every
>      human's loadout still replaces its build entry, and on a tier base the ability / crash slots a loadout leaves
>      empty are cleared (`CreateInvalidObject`). TIER 1 and pods launch as before (the zero base of Revision 0.10.0
>      item 1 (a), or `PerkLaunchBase` "pilot"). This overrides that item: 0.10's cards flow launched on TIER 1 unless
>      `PerkLaunchBase` was "pilot".
>      The row is on the v2 page only; a classic page launches on the stored tier.
>    - New API: `setup.raceArt(choice)` (lobby's RACE poster), `setup.arcadeTile(planet, cls)` (cmap's planet poster,
>      the CLASS posters), `setup.commandFocus(id)` (racers), `opts` of `setup.setStatus(text[, opts])` (0.11 had
>      `setStatus(text)`) / `clearStatus(key)` (racers' join hint and ALL READY), `setup.onPoster(i)` (the poster
>      ghosts), `setup.p1Back(why)` / `lastP1BackMs()` (backprompt), `setup.debugInputMode(mode)` (tests). A v2 page
>      whose theme elements were dropped (`theme.forget` on a phase change) is rebuilt at the next `setup.open`.
> 8. **cmap.lua v2 views (spec §7.2, §7.3).** On setup's v2 page (`ctx.v2`; the ctx adds `geo`, `tctx`,
>    `place(widget, rect, z, align)`, `ghost(id, fn, rect, cv)`, `back()`) both views are page-sized canvases on
>    setup's page canvas, in screen su. PLANET: `T_UI_Map_Bg` is setup's page background (`SetupCMapBackground` false);
>    the arc and the info block keep their anchors; the planet x class Arcade tile (`setup.arcadeTile`) is a framed
>    poster where the video box was (the movie plays there only with `SetupCMapVideoW` > 0); a disc pager under the arc
>    (`T_UI_Planet_<Pl>_Select` on 96-su discs, the selected one 128 su with a WHITE ring) whose ghosts are the old
>    chips (focus = select, A = choose); no name chips. TRACK: the run map as one framed print at (128, 540),
>    3584 x 1316 = the virtual map at scale 1.0 (`SetupCMapMapW` / `SetupCMapMapH`), with the `WBP_Tooltip_Holder`
>    detail card at (2560, 600). `cmap.navDown(back)` links the lowest focus targets (every disc; the last circuit
>    row's nodes) to setup's BACK with Down. `SetupCMapPlanetNav` / `SetupCMapTrackView` "list" also apply live on a
>    v2 page. The classic views are unchanged.
> 9. **Player colours (spec §2.2; `consts.lua`).** `C.COLOURS` holds the game's planet tones (the Arcade event card's
>    PlanetsToColors) instead of the 0.11 blue / red / green / yellow: P1 apricot #E6A95B
>    `{R=0.7913,G=0.3968,B=0.1046}`, P2 teal #92C0B6 `{R=0.2874,G=0.5271,B=0.4678}`, P3 lime #B4C678
>    `{R=0.4564,G=0.5647,B=0.1878}`, P4 Crait red #CA5656 `{R=0.5906,G=0.0931,B=0.0931}`, `Remote` white (A = 1
>    everywhere). `C.COLOUR_INK` is the tag ink on each hue (INK #222221 on apricot, teal, lime and for Remote; WHITE
>    on Crait red); `C.COLOUR_P4_SAND` (#D1C371, the Sentinel I tone) is the V-FIN-13 fallback for P4. Used on small
>    marks only: P-tags, the 6-su art rule and the stripe on the scenario art (cards2), the players strip and the taken
>    tags (lobby, cards), the in-race name tags (nametags through roster). One table for both styles: nametags, roster,
>    cards.lua, racers and setup's classic columns read it too. §1.2 and the G1 `consts.lua` contract are updated.
> 10. **Other changed modules.**
>    - `ui.lua`: `ui.ghost(pc, id, fn, opts)` = `ui.button` with an empty label at render opacity 0, Visible and
>      focusable: the one focus mechanism of the v2 pages (CommonUI navigation and its sounds, the selected-toggle
>      click poll; the look is painted under it, V-FIN-04); `ui.hovered(w)` (`IsHovered`).
>    - `join.lua`: `join.slotStates()` (the players strip as data; `slotViews` stays for the classic lobby),
>      `join.guestPressWithin(ms)` (the guest pads' raw A edges, read in `join.poll`), `join.padPresent(ctrlId)`.
>      Hot-plug (review hyg-3; overrides the 0.8.1 rule): `HotplugPadToP1` keeps its values ("front" default |
>      "always" | "off"), but a new pad takes P1 only while P1's own pad is known to be gone (its disconnect was seen:
>      the Moonlight / Sunshine reconnect case), never with `KeyboardIsP1`; a second pad switched on next to a working
>      P1 pad stays free for ADD PLAYERS. The device hook reports a disconnect with user -1: pad presence maps it to the
>      user that device last connected for ("(the pad of user N)" in the log line).
>    - `racers.lua`: the renderer per page (item 4), the v2 view model, P1's input mode from `theme.inputMode`,
>      `racers.lastPilotThumb(ctrlId)` (the lobby strip), the join hint and ALL READY in setup's status pill (the
>      "P1 PILOT · P2 PERKS" summary line is gone). The input model (P1's sink, guests polled, keyboard, mouse filter)
>      is the same in both styles.
>    - `vehicles.lua`: `vehicles.modelName` = the game's model name (`TH_<Model>.ItemName`, read once per class;
>      `VehicleNameSource` "load" | "find" | "table", V-FIN-10). `pilots.lua`: `tile` (the SCENARIOS poster),
>      `baseName` / `rankTag`. `perks.lua`: the short v2 detail tags (`perks.detail` style "v2" unless `UiStyle` is
>      "classic").
>    - `vpreview.lua`: the backdrop inside the capture (`PreviewBackdrop` "studio" | "scenario" | "cutout"; a failed
>      rung falls to the next; "classic" always "cutout"; "studio" forces the "fixed" exposure), `PreviewStudioGain`,
>      `PreviewStudioFloor`, `PreviewCalibrate` (default false: the corner read, up to two GPU readbacks per bay, only
>      on request; `vpreview.calibrate()` re-arms it, but the read runs only while `PreviewCalibrate` is true),
>      `vpreview.dropAll(why)` (the launch hold).
>    - `perkapply.lua`: `launchBase(arch, pilotId, tierPath)` (item 7) and one AI-builds line per race world (V-RC-27).
>    - `util.lua`: `U.anchorThread()` also bumps `St.cb`, and the debug breadcrumbs (item 2).
> 11. **Config and wiring.** 21 new config.lua keys: `UiStyle`, `InputModeDebounceMs`, `StatusPillMs`,
>    `PreviewBackdrop`, `UiPageOrigin` (nil = measured), `UiTitleWidget`, `UiTitleBoxH`, `UiHeroPill`,
>    `StatusPillPlace`, `UiFontMaterials`, `UiTraitGlyph`, `UiCondTint`, `CardFigureTint`, `CardStripe`,
>    `CardStripeAngle`, `PreviewStudioGain`, `PreviewCalibrate`, `PreviewStudioFloor`, `VehicleNameSource`,
>    `UiMokiWidthScale`, `BackPromptAsBack` (fallback selectors and knobs of the V-FIN / V-BP checks), plus the
>    read-only `cfg.UiClassic`. Check tables: ENUMS for the string selectors; POSITIVE += `InputModeDebounceMs`,
>    `StatusPillMs`, `UiTitleBoxH`, `UiMokiWidthScale`; NONNEG += `SetupCMapVideoW`; SHAPES += `UiPageOrigin` (a rect
>    {x, y, w, h}); new NILABLE (`UiPageOrigin`: no default, config_user.lua may still set it) and NUM_OR_RGB
>    (`PreviewStudioGain`: a number or {r, g, b}, each > 0). v2 defaults: `CardRowW` 3584, `CardH` 1300, `CardW`
>    {1762, 1762, 1162, 860}, `CardGap` {0, 60, 49, 48}, `SetupCMapVideoW` 0, `SetupCMapBackground` false,
>    `SetupCMapMapW` / `SetupCMapMapH` 3584 / 1316 (item 1 for "classic"). Release defaults (review hyg-6 / hyg-8):
>    `Debug` false (no U.dbg lines, no debug hooks in diag; `Debug = true` in config_user.lua for a bug report),
>    `UxSplitProbeMs` 0, `WreckProbe` false, `CrashCamProbe` false, `PreviewCalibrate` false. Settings: `OpponentTier`
>    (settings.lua ORDER and COMMENTS, `cfg.Defaults.OpponentTier = 1`). consts: `C.VERSION = "0.12.0"`; `C.BP` +=
>    `ScreenTitle`, `ButtonBackerPill`, `VehicleTrait`, `SectionSubLabel`, `DarkPanel`, `TooltipHolder`; new
>    `C.COLOUR_INK` and `C.COLOUR_P4_SAND` (item 9). main.lua: MODULES += `theme` (after `ui`), `cards2` (after
>    `cards`), `backprompt` (last; boot line `modules=46/46`); INIT_ORDER and PERSIST_MODULES unchanged (none of the
>    three is initialised at boot or persisted); FAST += `backprompt.fastTick` (every phase). diag F9 gains a `ui v2`
>    section (style, fallback selectors, `theme.status`, `lobby.status`, model names, the bays' backdrop). install.sh
>    (overrides the install line of Revision 0.10.0 item 7): a first install keeps UE4SS's bundled console settings
>    (both off), `--console` turns the log console and the GUI console on, `--quiet-console` off again; an installed
>    UE4SS 3.0.1-1160 gets a WARNING (it does not boot on the hotfixed game). `tools/package.sh VERSION` builds the
>    release zips from git-tracked files plus the images README.md references (it refuses untracked files in the
>    shipped folders and checks `C.VERSION`, `luac5.4 -p` and a leak pattern); docs/REFERENCE.md also goes in as
>    `SWGRCouch/README.md`.
> 12. **Live status (2026-10-10, CL382493).** Checked: the UI v2 pages at 1280x720, 1920x1080 and 3840x2160, in
>    English, German and French (other game languages not checked yet). Seen working: V-LCH-07 and the crash fix
>    (five consecutive launches from RACE SETUP with returns to the menu, no crash; before the fix 4 of 5 crashed);
>    V-RC-27 (a TIER 1 race gave the AI PowerLevel 0, no abilities and no parts, a TIER 4 race PowerLevel 18 and 2
>    abilities each, and the humans' own loadouts stayed intact: "in race: build ok, abilities 4/4, crash ok, parts
>    4/4 live", V-RC-21); V-JOIN-20 with the 0.12.0 rule ("hot-plugged pad ctrlId 3: P1 keeps ctrlId 0, whose pad is
>    still connected (ADD PLAYERS makes the new pad a guest)"); V-BP-01 on OPTIONS (answered No with 1 click, 72-104
>    ms after the post, OPTIONS closed) and on RACE SETUP (1 click, 102 ms, one step back). No live evidence in the
>    2026-10-10 logs: backprompt's KeyboardIsP1 branch (review flow-1), its 2 s give-up and 5-click limit, and a
>    hot-plugged pad taking P1 after P1's own pad disconnected (the user -1 mapping).

**Hard rules for all code.**
1. Nothing touches a UObject off the game thread. Keybinds, `LoopAsync`, `ExecuteAsync` are banned for game work;
   everything goes through `sched.lua` [API§2]. 0.10.0: a keybind callback may not even call `sched.*`; it only bumps
   its `keyq` counter (see the 0.10.0 revision above).
2. Every block of game calls runs inside `U.try(tag, fn, ...)` (xpcall + traceback log). One failure never kills a
   loop, a hook or the mod [API§2 LoopAsync gotcha].
3. Every UFunction call passes **exactly** the declared argument count; trailing `nil` for null objects; out-params
   as Lua tables [API§9]. Enums are integers. FName params are `FName("x")`, FText params `FText("x")` [API§8].
4. TArray: only `for i = 1, arr:GetArrayNum()` or `arr:ForEach`; never `ipairs`/`pairs`/open loops [API§8].
5. A missing property is an invalid object, not nil: test with `U.ok(x)`; never `if obj.Prop then` [API§7].
6. No `FindAllOf` in loops faster than 2 s; no `FindFirstOf` faster than 1 s. Enumerate owners instead
   (`GameInstance.LocalPlayers`, `GameState.PlayerArray`, `RacingGameState.Vehicles`) [API§6, §15 #4]. 0.12.0 adds
   one bounded exception, backprompt's prompt search (at most every 250 ms, for at most 2 s after a QuitGame post;
   Revision 0.12.0 item 5).
7. No `HasAnyInternalFlags(EInternalObjectFlags.PendingKill)` anywhere (unreliable on 5.7) [API§13].
8. No key in use by bundled mods: F10, Tilde (ConsoleEnablerMod), INS, Ctrl+J/H/Num5-9, Ctrl+O, Ctrl+R, F3,
   Ctrl+Y/U/I [API§12]. `SplitScreenMod` must stay `: 0` in `mods.txt`.
9. LoadMap hook callbacks always `return nil`. Console handlers always return a boolean [API§11].
10. Never `rm`/delete files; settings are rewritten in place (`io.open(path, "w")`).
11. (0.10.0) Test probes (`test.cmd` `lua` lines, console snippets) obey rules 1-5 like module code: every UObject kept
    from an earlier tick or command gets `U.ok(x)` before `x.Member` / `x:Fn()` (Revision 0.10.0 continued, item 8).
12. (0.12.0) The launch hold: from the first callback after an accepted `LaunchCustomRace` until the launch is over,
    no front-end page, theme widget or main-menu object is touched. Every front-end poll, tick, listener, timer and
    keybind body checks `St.launchHold()` before it reaches one, and before any `U.ok` on it (Revision 0.12.0, item 2).
13. (0.12.0) A raw `RegisterHook` (outside `U.hook`) lives only while the page or race state it serves shows:
    registered when arming, UnregisterHook-ed when disarming, ids in `_G.SWGRCouch_<module>_hooks` (uxsplit, subsplit,
    pause and restart in races; backprompt while OPTIONS or RACE SETUP shows, disarmed by `launch.start` right before
    `LaunchCustomRace`; Revision 0.7.0 item 1, Revision 0.12.0 item 5).

---

## 1. User-facing behaviour

### 1.1 Entry point: the SPLIT SCREEN tab
- The main-menu tab strip becomes **Campaign · Scenarios · Arcade · Multiplayer · SPLIT SCREEN**. The new tab is
  appended right of Multiplayer (CommonUI appends to `WBP_Tab_List.DynamicContainer`) and the bumpers reach it
  [MT§6 B, UI§2.3].
- Tab id: `FName("SWGR_SplitScreen")` (not in `DT_TabDescriptors`, not in `TabIDToState`). Button class:
  `menu["Button Widget Type"]`, fallback `WBP_Tab_Btn_C`. Label: `btn:SetText(FText("SPLIT SCREEN"))` [MT§6 B].
- Selecting it shows our **Lobby page** in `menu.WS_ScreenContent`. The game's handler only prints "Unhandled
  state for tab" for our id [MT§3.2]; our post-hook on `CustomEvent(TabId)` does the switch.
- Selecting any other tab: the game's CSM puts its own pane back; our hook deactivates the Lobby and the Builder,
  removes **all** guests (`join.close`) and restores the single view. Guests never leak into Campaign/Arcade.
  The invariant is enforced independently of our tab bookkeeping (integration round 1): every game-tab selection
  (`CustomEvent`, the switcher→tab sync unless a post-race return is pending, the `TabDetectMode` poll) closes any
  local guest unless a launch is pending or the set is frozen (connected client); a failed post-race return closes
  them; and a race entered from the menu (or from OTHER: campaign paddock / PvP flow) that the mod did not launch
  removes them first (`"race_enter"` guard in `join`); OTHER entered from the menu closes them as well.
- After a race (offline, host or client) the menu reopens **on the SPLIT SCREEN tab** with the joined guests
  kept and the last race preselected (`cfg.ReturnToSplitTab = true`).

### 1.2 Lobby page layout
Host widget: one `WBP_Setting_List_C` instance (a `FuseActivatableWidget` with no logic) whose root
(`page.WidgetTree.RootWidget`, the FuseVerticalBox `SettingsVerticalLayut`) is emptied with `ClearChildren()`
[UI§2.5, §3.2]. Each row is created with
`WidgetBlueprintLibrary:Create(menu, <class>, menu:GetOwningPlayer())` and added with
`root:AddChildToVerticalBox(w)`; the returned slot gets `SetPadding({Left=0,Top=4,Right=0,Bottom=4})` and
`SetHorizontalAlignment(0)` (HAlign_Fill) [UI§1.3].

| Row id | Widget class | Focus | Label examples | On click |
|---|---|---|---|---|
| `hdr` | `WBP_SectionHeaderModal_C` (`SetHeaderText(FText)`) | no | `SPLIT SCREEN` | — |
| `slot1..slot4` | `WBP_Vertical_Btn_C`, `BP_SetIsFocusable(false)` | no | `P1  READY  (pad 1)` · `P2  READY  B = leave` · `--  press A to join (pad 3)` · `P3  CONTROLLER DISCONNECTED` | — |
| `remote` | `WBP_Vertical_Btn_C`, not focusable; collapsed when offline | no | `ONLINE: 3 remote players (2 machines)` · `CONNECTED TO 10.8.0.1:7777` | — |
| `race` | `WBP_Common_Btn_C` (`UpdateText(FText)`) | yes (first focus) | `CHOOSE RACE >` · `RACE: Jakku / The War Fields / Race / Landspeeder >` | open the race builder (§1.4) |
| `layout` | `WBP_Common_Btn_C` | yes | `2P LAYOUT: TOP / BOTTOM` · `SIDE BY SIDE` | cycle |
| `gfx` | `WBP_Common_Btn_C` | yes | `SPLIT GRAPHICS: PERFORMANCE` (AUTO / PERFORMANCE / QUALITY / MY SETTINGS) | cycle |
| `takedown` | `WBP_Common_Btn_C` | yes | `TAKEDOWN CAMERAS: OFF` | toggle |
| `tags` | `WBP_Common_Btn_C` | yes | `NAME TAGS: ON` | toggle |
| `kbp1` | `WBP_Common_Btn_C` | yes | `KEYBOARD IS P1: OFF` | toggle; refused (status message) while a guest is joined |
| `net` | `WBP_Common_Btn_C` | yes | `NETWORK: OFFLINE` · `HOST` · `JOIN` | cycle; refused while hosting/connected |
| `netact` | `WBP_Common_Btn_C`; `SetVisibility(1)` when OFFLINE | yes | `START HOSTING (PORT 7777)` · `STOP HOSTING` · `CONNECT TO 10.8.0.1:7777` · `DISCONNECT` | net action (§2) |
| `start` | `WBP_Common_Btn_C` | yes | `START RACE` · client: `WAITING FOR HOST` (`BP_SetIsInteractionEnabled(false)`) | launch (§1.5) |
| `status` | `WBP_Vertical_Btn_C`, not focusable | no | last status/error line | — |

- Every cycle/toggle writes the persisted setting immediately (`settings.set`) and re-labels the row. Live
  effects: `layout` → `split.applyLayoutSettings()`; `kbp1` → `split.applyGamepadOffset()` then `join.rebuild()`.
  The join-address and port are **not editable in the UI**: they come from `settings.txt` (`JoinAddress`, `Port`).
- Focus: `page:SetDesiredFocusWidget(race)` before activation; after `ActivateWidget()` call `race:SetFocus()`
  [UI§3.3]. Up/down navigation is CommonUI's own; non-focusable rows are skipped.
- Click detection (`ui.lua`): primary = post-hook on `WBP_Common_Btn_C:BP_OnClicked` filtered by instance
  address [UI§3.4]; fallback (`cfg.ClickMode = "poll"`) = `SetIsSelectable(true)` + `SetIsToggleable(true)` and a
  50 ms poll of `GetSelected()` that resets with `SetIsSelected(false, false)`.
- Colours (`consts.COLOURS`; 0.12.0: the game's planet tones, which replaced the 0.11 blue / red / green / yellow,
  Revision 0.12.0 item 9): P1 apricot #E6A95B `{R=0.7913,G=0.3968,B=0.1046,A=1}`, P2 teal #92C0B6
  `{R=0.2874,G=0.5271,B=0.4678,A=1}`, P3 lime #B4C678 `{R=0.4564,G=0.5647,B=0.1878,A=1}`, P4 Crait red #CA5656
  `{R=0.5906,G=0.0931,B=0.0931,A=1}`, remote humans white. Used for name tags (§1.6), the RACERS cards (0.10.0) and
  the players strip (0.12.0). The classic slot rows carry the colour only as text (`P2`), because
  `WBP_Vertical_Btn_C` colour variables are cosmetic and unverified.

### 1.3 Pad join flow
- **When it runs:** the Lobby is visible, the world is the front end, and the machine is not a connected client
  (a connected client's guest set is frozen; see §2.4).
- **Open** (`join.open`): `GameplayStatics:SetForceDisableSplitscreen(world, true)` (one view while dormant guests
  exist), then for `id = 1 .. cfg.MaxLocalPlayers - 1`: if `GameplayStatics:GetPlayerControllerFromID(world, id)` is
  invalid, `GameplayStatics:CreatePlayer(world, id, true)` [UI§4.3]. These are **dormant** guests.
- **Pad mapping.** `KeyboardIsP1 = false`: XInput pad *k* (0-based) drives ControllerId *k*; P1 = pad 0 plus
  keyboard/mouse. `KeyboardIsP1 = true`: `GameMapsSettings.bOffsetPlayerGamepadIds = true`, pad *k* drives
  ControllerId *k+1*, P1 is keyboard only. In both cases the join poll scans ControllerIds 1..3 [UI§5 #5].
- **Edge poll** (`join.poll`, every `cfg.JoinPollMs` = 33 ms, game thread): for each dormant/joined guest PC,
  `down = pc:IsInputKeyDown(KEY_A) or pc:IsInputKeyDown(KEY_START)`; a rising edge (previous false) more than
  `cfg.JoinArmMs` = 300 ms after creation marks the slot **joined**. For a joined slot a rising edge of
  `KEY_B` un-joins it. `WasInputKeyJustPressed` is not used (a slower poll misses it) [API§3, UI§4.3].
  `KEY_A = {KeyName = FName("Gamepad_FaceButton_Bottom")}`, `KEY_B = …"Gamepad_FaceButton_Right"`,
  `KEY_START = …"Gamepad_Special_Right"` (names in the exe [API§3]).
- **Player numbers:** P1 is ControllerId 0. Joined guests are numbered by ascending ControllerId (P2 = lowest joined
  id). That is exactly the order the engine lays out views after the dormant ones are removed, so the card colour,
  the view and the name tag always agree.
- **Keyboard test path:** F6 joins the lowest dormant guest; F7 un-joins the highest joined guest (§1.8).
- **Device events:** post-hook `/Script/Griffin.GfnGameInstance:OnUserInputDeviceChanged`; `NewConnectionState:get()`
  2 = Disconnected, 3 = Connected [UI§4.1]. The slot whose ControllerId equals `PlatformUserId:get().InternalId`
  shows `CONTROLLER DISCONNECTED` (lobby) or, in a race, its car gets the `Disconnect` override (§1.6).
- **Close** (`join.close`): remove every guest (joined or not), highest ControllerId first, with
  `RemovePlayer(pc, true)`; `SetForceDisableSplitscreen(world, false)` only if the world is not the front end.
- **Commit** (`join.commit`, right before launch or connect): remove only the **dormant** guests. Force-disable
  stays on until the race map (§1.6), so the loading flow is not split four ways.

### 1.4 Race builder (the game's own panel)
- A second page, `WBP_FE_QuickRace_Custom_Widget_C`, created once per main-menu instance (`Create(menu, cls,
  owningPC)`) and added to `menu.WS_ScreenContent` with `AddChild` [MT§5, RB§1.3]. Pages are always shown with
  `SetActiveWidget(widget)`, never by index.
- `race` row click → `builder.open()`: `WS_ScreenContent:SetActiveWidget(bw)`, `bw:ActivateWidget()` (its
  `BP_OnActivated` runs `InitVehicleArchetypes/InitGameModes/InitPlanets/InitBuilds/ClearChoices` [MT§5]), then
  `bw:RequestRefreshFocus()` (its `BP_GetDesiredFocusTarget` is `Btn_SetVehicle`).
- The user picks Vehicle, Game mode, Planet, Track, Conditions, Build with the game's pickers and presses **Go**.
- Post-hook on `…WBP_FE_QuickRace_Custom_Widget_C:BndEvt__WBP_FE_QuickRace_Custom_Widget_Btn_Go_K2Node_ComponentBoundEvent_6_CommonButtonBaseClicked__DelegateSignature`:
  if `ctx:get() == bw` and the BP's own test passes (`ChosenArchetype`, `ChosenGameMode`, `ChosenTrack` valid and
  `ChosenBuild` or `ChosenDebugBuild` valid [RB§1.3]), the choice is **captured by value** (objects + the condition
  `TagName` FName + display strings), persisted (object paths) and the Lobby is shown again with the `race` row
  relabelled. With `cfg.LaunchOnGo = true` the launch starts at once.
- Capturing by value is mandatory: the next `ActivateWidget()` runs `ClearChoices`, which wipes `Chosen*`.
- Leaving the builder without Go: (1) a `BACK` `WBP_Common_Btn_C` that `builder.ensure` appends to the builder's
  root grid with `root:AddChildToGrid(back, cfg.BuilderBackRow, cfg.BuilderBackCol)` (`cfg.BuilderBackButton`);
  (2) switching tab away and back always shows the Lobby; (3) F5.
- The last race is restored on the next session from `settings.LastRace*` paths (StaticFindObject, then LoadAsset
  of the asset path on the game thread). A path that no longer resolves clears the choice.

### 1.5 Launch
- `START RACE` (offline or host): `launch.start()` checks the choice and the front-end game mode, checks grid room
  (humans vs `ChosenGameMode.GridMakeup.Entries[i].NumEntrants`; warning only, see §4 `launch`), calls
  `join.commit()`, optionally `Server_SelectVehicle` for each guest, then
  `FrontEndGameMode:LaunchCustomRace(archetype, gmv, track, {TagName = condName}, build, debugBuild)` [RB§6b]. The
  native code writes `PrimaryFlow = QuickRace (2)` first [RB§3.1]: `launch` reads `GfnGameInstance.PrimaryFlow` right
  after the call to know the launch was accepted.
- Guests must exist as PlayerControllers **before** this call: the recipe builder walks
  `UWorld.PlayerControllerList` inside `LaunchCustomRace` [RB§4, PS§5].
- Host: only allowed while `net.isListening()`; the remote players already in the front end are part of the recipe
  the same way (§2.2).
- Client: `START RACE` is disabled; the client follows the host's travel.

### 1.6 In-race behaviour
- **Layout.** On the first poll that sees a `RacingGameState` (`phase` LOADING): `split.enterRace()` calls
  `SetForceDisableSplitscreen(world, false)`; the engine lays out the views from the `GameMapsSettings` CDO that
  `split.applyLayoutSettings()` wrote at boot and on every change: `bUseSplitscreen = true`,
  `TwoPlayerSplitscreenLayout` = 0 (TOP / BOTTOM) or 1 (SIDE BY SIDE), `ThreePlayerSplitscreenLayout = 0` (FavorTop),
  `FourPlayerSplitscreenLayout = 0` (Grid), `bOffsetPlayerGamepadIds = settings.KeyboardIsP1` [HERE enums, ANALYSIS§6].
  F8 (and the lobby row) flips the 2P layout live with `split.relayout()` (force-disable true then false).
- **Per-player HUD** (every machine, local guests only, `hud.lua`, 250 ms):
  - P1's HUD is the game's (`WBP_Hud_Race_C` or `WBP_Hud_Memory_C`, found with `UIManager:GetWidgetInLayer(cls, 1)`).
    By default (`cfg.P1HudMode = "rehost"`) it is moved into P1's view (`RemoveFromParent` + `AddToPlayerScreen(0)`)
    and re-moved whenever the CSM puts it back in its layer (`GetParent()` valid) [HUD§7.2].
  - Each guest gets `Create(world, p1hud:GetClass(), guestPC)` → `AddToPlayerScreen(10)` → `TransitionIn()`; its
    `EventInfo` named slot gets a guest-owned copy of P1's slot content [HUD§7.3].
  - Patched in guest HUDs: lap counter text from the guest's own `RaceEventComponent.CurrentLapNumber` plus a
    calibrated offset, re-applied each poll and in a post-hook of `WBP_Hud_EventLapCounter_C:UpdateCurrentLap`
    [HUD§4]. Collapsed in guest HUDs: 1D position map, its mid-section image, best lap, takedown counter (they show
    P1's global data) [HUD§7.5]. Boost/ramjet icons (bound to P1's pawn) stay as they are unless
    `cfg.GuestBotEngineFix = true` (speculative) [HUD§2].
  - Visibility follows the game's state: hidden while paused (`CSM_PauseMenus_Active` active, `U.csmPaused`; "Idle not active" is NOT used
    alone: after P1 finished the race CSM is in `CSM_RF_LocalResults`, the pause machine stops and Idle is inactive),
    hidden once the
    race CSM is in `CSM_RF_PostRacePhase`, shown in `..._InHud` states or while the guest is still racing after P1
    finished [HUD§7.4].
- **Graphics.** When local views ≥ 2 at LOADING: the preset from `settings.SplitGraphics` is applied with console
  cvars; previous values are saved and restored in the front end (`gfx.lua`) [ANALYSIS§6].
- **Takedown cameras.** If `settings.TakedownCams = false` and local views ≥ 2: `GameUserSettings.TakedownCameras`
  (Bool [HERE]) is saved and set to `false`; restored in the front end.
- **Name tags.** With `settings.NameTags = true`, in every HUD we host, each vehicle marker whose
  `MarkerVM.PlayerState` belongs to a human gets `DesiredTagColour` = that player's colour and the label `P<n>` (local)
  or keeps its name (remote humans get the neutral white `consts.COLOURS.Remote`) [HUD§5, §7.6].
- **Guest pause.** Primary: the guest HUD's own `IA_Veh_Pause` binding opens the global pause menu
  (`cfg.GuestPauseMode = "hud"`) [HUD§3.2, §6 #9]. Fallback `"poll"`: a rising edge of `KEY_START` on a guest PC calls
  `CosmeticStateMachineManager:GetStateMachineForRoot(CSM_PauseMenus_Root):ChangeStateTo(CSM_PauseMenus_PauseMenu,
  "SWGRCouch", nil)`. The pause menu itself stays P1-navigated (global UI owner).
- **Racer slots.** Native slots are expected (guests created before `LaunchCustomRace`). A local or remote human
  still without a vehicle after the race starts gets an AI car through takeover with PlayerState adoption (§3).
- **Pad lost mid-race** (`cfg.AIOnPadDisconnect = true`, server side): the guest's car gets
  `StartInputSourceOverride_OnServer(4)` (Disconnect, the game's own human→AI path); on reconnect
  `StopInputSourceOverride_OnServer(4)`. Joining mid-race is **not** offered (UX rule); F6 in a race does nothing
  unless `cfg.AllowMidRaceJoin = true` (then: CreatePlayer + immediate takeover, debugging only).
- **Wrecks and race end** (`wreck.lua`, added 2026-10-07; research `notes/research/wreck-design.md`). Offline
  (`NM_Standalone`) the first human who finishes or is wrecked arms `RacingGameState.RaceTimeoutTime = now + 2 s` plus
  the unreflected `RacingGameMode+0x4D0` byte, and `ShouldEndRace` ends the race for everyone. The mod keeps an offline
  race running until no human races (`cfg.FinishGraceSec`: `"all"` default, or N s after the first real finish), lets a
  wrecked player spectate in their own view (native spectate, retargeted to the other local human, failed-event
  cinematic ended, camera guard with a `SetViewTargetWithBlend` fallback), turns the world-wide crash slow-mo off while
  split (`cfg.WreckSlowMo`), and offers `cfg.WreckMode = "noWreck"` / `"game"`. P1 out while a guest races: P1's CSM
  `CSM_RF_Spectating`/`SpectatingInProgress` (`WBP_PVP_Spectate_C`) and `CSM_RF_LocalResults` (`WBP_PostRace_Info_C`)
  are kept off the guests' views by `hud.lua`; `present.lua` keeps them split.

### 1.7 Post-race and back to the menu
- Results: guest HUDs are collapsed when `CSM_RF_PostRacePhase` becomes active; the game's results screen is a
  viewport-wide widget, so everyone shares it.
- Leaving the race (detected by `phase`, §5): `takeover.releaseAll()` (server), `hud.clearAll()`, `nametags.clear()`,
  `gfx.restore()`. In the next front end: `split.enterFrontEnd()` (force-disable on), the guests that were joined stay
  joined (their LocalPlayers survive travel; their new PCs are picked up by `join.resync()`), the menu is reopened
  on the SPLIT SCREEN tab, and `START RACE` relaunches the same race ("rematch").
- Selecting another tab removes all guests (§1.1). Quitting the game needs no cleanup.

### 1.8 Debug keybinds and console command
All keybinds go through `keyq.bind` (0.10.0; the bodies run on the game thread from `keyq.drain`, never `sched.run`
from the event-loop thread). None collides with §0 rule 8.

| Key | Action | Module call |
|---|---|---|
| F5 | select the SPLIT SCREEN tab (or show the Lobby if already on it) | `menu_tab.selectOurTab()` |
| F6 | front end: join the lowest dormant guest; race: nothing (or mid-race join if `cfg.AllowMidRaceJoin`) | `join.keyboardJoin()` |
| F7 | front end: un-join the highest joined guest; race (server): release + remove that guest | `join.keyboardLeave()` |
| F8 | flip the 2P layout (persisted) | `split.toggle2PLayout()` |
| F9 | diagnostics dump to UE4SS.log | `diag.dump()` |
| Ctrl+F5 | launch the last race now (skips the builder; front end only) | `launch.start()` |
| Ctrl+F6 | force takeover now for every PC without a car (server, race only; ignores the grace period) | `takeover.forceAll()` |
| Ctrl+F7 | host: start/stop hosting | `net.toggleHosting()` |
| Ctrl+F8 | client: connect to `settings.JoinAddress:Port` / disconnect | `net.toggleConnect()` |
| Ctrl+F9 | network status dump | `diag.net()` |
| Ctrl+F11 | `RestartCurrentMod()` (development), deferred to the game thread via `sched.run` (on the event-loop thread it would uninstall inline and free the running Lua state) | `keys` |

Console (needs ConsoleEnablerMod, Tilde/F10 open it): `couch <sub> [args]` through
`RegisterConsoleCommandGlobalHandler("couch", fn)`; subcommands `diag`, `net`, `tab`, `join`, `leave`, `layout`,
`launch`, `takeover`, `host`, `connect [addr[:port]]`, `disconnect`, `gfx <auto|performance|quality|off>`,
`set <Key> <value>` (writes `settings.txt`), `reload`. The handler always returns `true`.

---

## 2. Network design (self-hosted listen server, direct IP, split-screen on every machine)

### 2.1 Transport and config (both machines)
- The game's GameNetDriver is PlayFabNetDriver, defined in **`[/Script/Engine.GameEngine]`** with `ClearArray`; an
  override in `[/Script/Engine.Engine]` (old draft) loses. PlayFab Party allows one user per device, so split-screen
  guests need plain `IpNetDriver` [NET§0, §1.2, §9].
- `mod/config/Engine.ini` (owned by the network group) is appended by the user to
  `<prefix>/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/Engine.ini`
  (corrected 2026-10-07; the `Griffin` folder named here before is not read by the game) (VERIFY V-NET-01: that folder is the active user layer under the SteamPlayFab custom config):
  ```ini
  [/Script/Engine.GameEngine]
  !NetDriverDefinitions=ClearArray
  +NetDriverDefinitions=(DefName="GameNetDriver",DriverClassName="/Script/OnlineSubsystemUtils.IpNetDriver",DriverClassNameFallback="/Script/OnlineSubsystemUtils.IpNetDriver")

  [/Script/OnlineSubsystemUtils.IpNetDriver]
  NetServerMaxTickRate=30
  ConnectionTimeout=30.0
  InitialConnectTimeout=120.0

  ; Iris fallback, BOTH machines (or Lutris argument -UseIrisReplication=0):
  ;[ConsoleVariables]
  ;net.Iris.UseIrisReplication=0

  ; Only if the host log shows "incompatible_unique_net_id":
  ;[/Script/OnlineSubsystemUtils.OnlineEngineInterfaceImpl]
  ;+CompatibleUniqueNetIdTypes=<type name from the host log>

  [/Script/Sentry.SentrySettings]
  InitAutomatically=False
  ```
  The file states in its header that official online play does not work while it is installed [NET§6.1].
- Runtime check (`net.checkDriverConfig()`, once in the first front end): read
  `UEHelpers.GetEngine().NetDriverDefinitions` (TArray of struct, numeric loop), log each `DefName`/`DriverClassName`;
  if the GameNetDriver entry is not `/Script/OnlineSubsystemUtils.IpNetDriver`, the Lobby status shows
  `ENGINE.INI NET OVERRIDE NOT ACTIVE` and HOST/JOIN still work but are expected to fail (V-NET-02).
- **Iris.** `cfg.IrisOff` (default `false`). When `true`, `main` runs `U.console("net.Iris.UseIrisReplication 0")`
  at boot, before any net driver exists (the standalone front end has none). Both machines must use the same value.
  The command-line key `-UseIrisReplication=0` (string verified [NET§1.2]) is the documented alternative (V-NET-03).
- **Port.** The listen port is the engine's `[URL] Port` (7777) or `-port=N` on the host's command line. The mod
  never appends `?port=` (FURL ignores it [NET§9]). `settings.Port` is used to build the client's address and is
  displayed; if it is not 7777 the host's Lobby status reminds `HOST MUST BE STARTED WITH -port=<n>`.
- Between homes: WireGuard; `settings.JoinAddress` is the host's WG address. No PlayFab, EOS or Steam networking.

### 2.2 Host flow
1. Lobby `NETWORK: HOST`. Guests can join before or after hosting starts.
2. `START HOSTING` → `net.startHosting()`: sets `state.net.hosting = true`, `state.ui.returnToTab = true`, runs
   `cfg.NetSafetyCvars` (empty by default), then console
   `open /Game/Griffin/Maps/L_FrontEnd/L_FrontEnd?listen` through
   `KismetSystemLibrary:ExecuteConsoleCommand(world, cmd, nil)` [RB§8, NET§6.2 H-alt]. This hard-reloads the front end
   as a listen server; LocalPlayers (guests) survive, their PCs are re-created (V-NET-04: boot flow skipped, menu and
   our tab come back).
3. In the reloaded front end `net.isListening()` must become true within `cfg.ListenCheckMs` (10000):
   `KSL:IsServer(world) and not KSL:IsStandalone(world) and U.ok(world.NetDriver)`. Else: status
   `LISTEN FAILED`, `state.net.hosting = false`.
4. Clients connect into the host's front end (§2.4). Remote PCs, guests included (child connections), are listed by
   `roster.remoteHumans()` (owners of `GameState.PlayerArray` entries that are PlayerControllers and not local) and
   shown in the `remote` row. A post-hook on `/Script/Engine.GameModeBase:HandleStartingNewPlayer(NewPlayer)`
   (BlueprintNativeEvent, hookable [PS§3]) logs every arrival and feeds `roster.noteArrival(pc)`.
5. `START RACE` → `launch.start()` (§1.5). First `net.beforeLaunch()` stores `state.net.expectedRemote =
   #roster.remoteHumans()`. `LaunchCustomRace` then builds the recipe from every PC in `PlayerControllerList`, local
   and remote [RB§4], writes builds into every `GfnPlayerState` and calls `ChangeState(LaunchingQuickRace = 4)`, which
   travels natively [RB§3.1].
6. **The travel question.** How `ULaunchingQuickRaceFrontEndState` travels is not readable [RB§10 #2]. The project is
   built for seamless travel (`TransitionMap=L_SeamlessTravel`, `OnPlayerStateMigrated` handlers) [RB§8, PS§4], so a
   `ServerTravel` that carries clients is expected. `net.checkTravel()` runs once, `cfg.TravelCheckDelayMs` (2000)
   after the host's phase becomes LOADING, and again at `cfg.RemoteArriveTimeoutMs` (20000):
   | Observation | Meaning | Action |
   |---|---|---|
   | listening and `#remote >= expectedRemote` | native networked travel worked | nothing |
   | not listening (`IsStandalone` true) | native travel was a local `OpenLevel` | `cfg.HostTravelFallback` (below) |
   | listening, `#remote < expectedRemote` at 20 s | some clients did not follow | missing clients auto-rejoin (§2.4 step 5); late arrivals are handled by `cfg.HostTravelFallback` |

   Round-2 rules: the per-world "once" checks (`onFrontEnd`, `onRaceMap`) and every world-bound timer compare
   `St.worldGen`, never the UWorld address (consecutive worlds often share one). The relisten wait ends in a
   `servertravel` only when `#remote` grew since it was armed (`St.net.remoteAtCheck`); a client that left on purpose
   does not restart the race. A race-map relisten that is not listening after `cfg.ListenCheckMs` reports
   `RELISTEN FAILED` and drops the wait. `cfg.ServerTravelOnMissingCars` only counts a human without a car once the race
   started plus `cfg.TakeoverGraceMs` (re-armed `checkTravel(3)` before that). `serverTravelNow` arms a watchdog
   (`cfg.ServerTravelWatchdogMs`): still in the same world after it = the servertravel was refused →
   `phase.cancelLeaving()` restores the race phase (V-NET-16); the servertravel is retried once 2 s later
   (`St.net.serverTravelRetries`, reset per race world), and a second refusal sets `St.net.lateJoinAllowed = true` so
   the remote players waiting without a car take AI cars (takeover) instead of spectating.
   Integration round 3: a relisten wait armed by `checkTravel(2)` (listening host, networked travel, clients late:
   `St.net.waitFromStage2`) ends in a `servertravel` only when, once the race started plus `cfg.TakeoverGraceMs` and no
   arrival for that long, a human still has no car; late clients that got their cars natively clear the wait. The
   `hostTravelFallback` wait keeps the plain rule. `net.beforeLaunch()` runs on every launch that is not a client's
   (also standalone and in the dev-screen path), so `expectedRemote` is 0 for a race that starts standalone.
   `cfg.HostTravelFallback` values:
   - `"relisten"` (default): host console `open <map>?listen` where `<map> = U.currentMapPath(world)` (package path
     parsed from `world:GetFullName()`); the recipe survives in `UEventRecipeSubsystem` [RB§3.3] (V-NET-07). Clients
     auto-rejoin. The host then waits until `#remote >= expectedRemote` or `cfg.RejoinWaitMs` (60000) and issues
     console `servertravel <map>` once, so the race restarts with every PlayerState present before the grid is built
     [NET§6.2 H2-H5]. `state.net.relistenDone` prevents loops.
   - `"relisten_takeover"`: same relisten, no `servertravel`; the late remote PCs get AI cars by takeover (§3) and
     `takeover` treats them as eligible although they joined after the start (`state.net.lateJoinAllowed = true`).
   - `"none"`: log only.
   Independent switch `cfg.ServerTravelOnMissingCars` (default `false`): host listening, every expected client present,
   but at least one remote human without a vehicle at `cfg.RemoteArriveTimeoutMs` → one `servertravel <map>`.
7. **Back to the menu.** If the host ends in a standalone front end while `settings.NetMode == "host"` and
   `state.net.hosting` is still true, `net.ensureListening()` repeats step 2 automatically
   (`cfg.AutoRelistenInFrontEnd = true`); clients auto-rejoin.
8. `STOP HOSTING` → `state.net.hosting = false`, console `open /Game/Griffin/Maps/L_FrontEnd/L_FrontEnd` (no listen);
   clients receive a network failure and return to their own front end.

### 2.3 Split-screen guests over the network (engine split-join)
- A client's extra LocalPlayers that exist when it connects send one split-join each after the join; the server
  creates a `UChildConnection`, a `BP_GfnPlayerController_C` and a `GfnPlayerState` per guest
  (`MaxSplitscreensPerConnection = 4`, `MaxPlayers = 16`); nothing game-side disables it [NET§2]. The host therefore
  sees "2 here + 3 there" as five PCs and `LaunchCustomRace` gives each a recipe entry (V-NET-08).
- Client rule: **only joined guests may exist when connecting** (`join.commit()` first), otherwise dormant guests
  would split-join as racers. After connecting, the client's guest set is frozen (`join.open` refuses on a client;
  the Lobby says `DISCONNECT TO CHANGE PLAYERS`). A guest created later would split-join immediately [NET§6.3].

### 2.4 Client flow
1. Lobby `NETWORK: JOIN`, `netact` = `CONNECT TO <JoinAddress>:<Port>`. Guests join with their pads as offline.
2. `CONNECT` → `net.connect()`: `join.commit()`, `state.net.wantConnected = true`, `state.ui.returnToTab = true`,
   then by `cfg.JoinMethod`:
   - `"openlevel_opts"` (default): `GameplayStatics:OpenLevel(world, FName(addr .. ":" .. port), true, opts)` with
     `opts = mm:GetClientTravelOptions():ToString()`, `mm = SubsystemBlueprintLibrary:GetGameInstanceSubsystem(gi,
     U.class(C.CLASS.PlayfabOnlineMatchmaking))`; if `mm` is invalid or the call throws, `opts = ""` and the log says
     so [NET§5.4] (V-NET-05).
   - `"openlevel"`: same call with `opts = ""`.
   - `"console"`: `open <addr>:<port>` through `ExecuteConsoleCommand` (V-NET-06).
3. Connected (`KSL:IsServer(world) == false` and the GameState is the host's `FrontEndGameState`): Lobby shows
   `CONNECTED TO …`, `start` disabled (`WAITING FOR HOST`), join frozen.
4. The host's launch carries the client to the race map (expected, §2.2 step 6). On the client, `hud`, `nametags`,
   `gfx`, `pause` work for its local guests exactly as offline; `takeover` never runs on a client.
5. **Failures.** Post-hook `/Script/Griffin.GfnGameInstance:HandleNetworkFailure(World, NetDriver, FailureType,
   ErrorString)` (native, flags 0x40401 [HERE]): log `ENetworkFailure` name (`consts.E.NetworkFailure`) and
   `ErrorString:get():ToString()`, show it on the status row. If `cfg.AutoRejoin` and `state.net.wantConnected`:
   once the client is back in a standalone front end, `net.connect()` again after `cfg.RejoinDelayMs` (3000), at most
   `cfg.RejoinMaxTries` (20) times; a successful connection resets the counter.
6. `DISCONNECT` → `state.net.wantConnected = false`, console `disconnect`.

### 2.5 Race-flow handshakes for remote guests
- **Core-object ack (R6).** Post-hook `/Script/Griffin.PvpFlowComponent:Client_RequestAckObjects()` (NetClient RPC;
  fires on the receiving client) [NET§5.2]. `cfg.GuestAckMode`: `"guests"` (default) = if the component's owner PC is
  a local PC other than P1, schedule `comp:Server_NotifyCoreObjectsArrived()` 500 ms later (callable from UE4SS
  although not BlueprintCallable [NET§6.2 H6]); `"all"` = every local PC; `"off"`. A duplicate ack is assumed
  harmless (V-NET-09).
- **Results blocking (R5).** Handled on the host by `takeover.finishIdlePlayerStates()` (§3.5).
- Clients never call `*_OnServer`, `Possess`, `UnPossess` or `SetOwner` (not RPCs) [NET§9].

### 2.6 Identity, login and PvP-system risks
| Risk | Mitigation in the mod | VERIFY |
|---|---|---|
| Token/entitlement check kicks IpNetDriver clients (R4) | join with `GetClientTravelOptions()` (`openlevel_opts`); `HandleNetworkFailure` log; host logs `HandleStartingNewPlayer` (only reached after login passed) and `RacingGameMode:OnPlayerControllerDestroyed(playerController)` | V-NET-10 |
| `incompatible_unique_net_id` (R8) | commented `CompatibleUniqueNetIdTypes` line in `Engine.ini` | V-NET-10 |
| Front-end login gate holds remote players (`AFrontEndGameMode::IsAnyLoginPending() -> bool` [HERE]) | host logs `fe:IsAnyLoginPending()` every 5 s while hosting in the front end | V-NET-11 |
| PvP systems (AFK kick, PlayFab player data, shop) disconnect players (R10) | only `LaunchCustomRace` events (BP_RacingGameMode); never `PvpFlowMap`; `cfg.NetSafetyCvars` list (empty by default; candidate `Pvp.FakeProgressionAuthKillswitch 1`) run on hosting start | V-NET-12 |
| Iris and child connections (R7) | `cfg.IrisOff` / `-UseIrisReplication=0` on both machines | V-NET-03 |
| Map-load time over the connect timeout (R9) | `InitialConnectTimeout=120`, `ConnectionTimeout=30` | V-NET-01 |

---

## 3. Fallback racer assignment: takeover with PlayerState adoption

Native slots are the primary path: every human PC exists before `LaunchCustomRace` (§1.5, §2.2). Takeover covers
whoever the race left without a vehicle. It is the reverse of the game's own human→AI disconnect switch and keeps
results, position, lap, abilities and `Racers`/`Vehicles` bookkeeping on a real racer entry [PS§6]. **Server only.**

### 3.1 Gate (`takeover.tick`, every main poll, at most one takeover per poll)
All of the following must hold (`cfg.SlotMode = "auto"`; `"off"` disables takeover; Ctrl+F6 bypasses only the grace
period):
1. `U.isServer()`; `gs = world.GameState` IsA `/Script/Griffin.RacingGameState`; `gs.Vehicles:GetArrayNum() > 0`.
2. `gs.bIsRaceStarted == true` and `os.clock()*1000 - state.race.startedAtMs >= cfg.TakeoverGraceMs` (3000).
   `state.race.startedAtMs` is set by `phase` on the false→true edge of `bIsRaceStarted` [NET§6.4, PS§8 #7].
3. Candidate PC: a human PC from `roster.humanPCs()` (local joined players + remote PCs incl. child connections),
   `U.ok(pc)`, no vehicle pawn (`not U.isVehicle(pc.Pawn)`), no record in `state.takeovers`.
4. Not a mid-game joiner: `roster.firstSeenMs(pc) < state.race.startedAtMs` **and**
   `pc.SpectatorComponent.bIsMidGameJoiner ~= true` (property on `AGfnPlayerController` [PS§1.6]); both are bypassed
   only when `state.net.lateJoinAllowed` (`relisten_takeover`, §2.2) or `cfg.TakeoverMidGameJoiners = true`.
5. `cfg.TakeoverWhen = "started"` (default) uses gate 2; `"countdown"` replaces gate 2 by "vehicles present and the
   count of `gs.Vehicles` unchanged for 2 polls" (earlier, riskier: may steal a car the race was about to assign).

### 3.2 Car pick (`takeover.pickCar(gs)`)
Iterate `gs.Vehicles` (`for i = 1, gs.Vehicles:GetArrayNum()`), never `FindAllOf` (front-end or cinematic cars
exist) [PS§6]. Keep `car` when:
`U.ok(car)` · `not car:WasSpawnedForCinematic()` · `not car:IsUnderCinematicControl()` ·
`car:GetOriginalInputSource() == E.InputSource.AI (2)` (a human car under an AI override is never taken) ·
`not U.isPlayerController(car.Controller)` · `U.ok(car.PlayerState)` IsA `GfnPlayerState` ·
`car.PlayerState.RaceEventComponent.bHasFinishedEvent == false` · not already in `state.takeovers`.
Among the kept cars choose the one whose `PlayerState.RaceEventComponent.EventPosition` is highest (last place:
least disruptive; `cfg.TakeoverPick = "last"`), or the first kept car (`"first"`).

### 3.3 Takeover sequence (`takeover.takeOver(pc, car)`), exact order
```
rec = {pc=pc, car=car, aiPS=car.PlayerState, aiCtrl=car.Controller, ownPS=pc.PlayerState, adopted=false}
rec.aiCtrlHadPS = U.ok(rec.aiCtrl) and rec.aiCtrl.PlayerState == rec.aiPS
0. if U.ok(pc.Pawn) and not U.isVehicle(pc.Pawn) then old = pc.Pawn; pc:UnPossess(); old:K2_DestroyActor() end
1. if U.ok(rec.aiCtrl) then rec.aiCtrl:UnPossess() end
   if rec.aiCtrlHadPS then rec.aiCtrl.PlayerState = nil end           -- the idle AI controller can never destroy aiPS
2. if cfg.TakeoverAdoptPS then pc.PlayerState = rec.aiPS; rec.aiPS:SetOwner(pc); rec.adopted = true end
3. pc:Possess(car)                                                    -- PossessedBy -> car.PlayerState = pc.PlayerState -> OnPawnSet
4. ov = car:GetInputSourceOverrides()                                 -- TArray return: U.arrayToTable(ov)  VERIFY(V-TKO-02)
   for each r in ov: if r is 2 (SpawnAI) or 4 (Disconnect) or 8 (Debug) or 9 (Autopilot) then car:StopInputSourceOverride_OnServer(r) end
5. car:SetInputSource_OnServer(1)                                     -- Player
6. pc:SetViewTargetWithBlend(car, 0.0, 0, 0.0, false)
7. if not pc:IsLocalController() then pc:ForceNetUpdate(); car:ForceNetUpdate() end
8. if U.ok(pc.SpectatorComponent) and pc.SpectatorComponent.bIsSpectatorRunning == true
   then pc.SpectatorComponent:Client_OnSpectatorModeEnded() end      -- [S] PS§6 notes
9. state.takeovers[U.key(pc)] = rec ; state.takeoversByCar[U.key(car)] = rec
```
Verification (logged once, 1 s later, `takeover.verify(rec)`): `car:GetCurrentInputSource() == 1` (or only RollingStart
/TakedownCam/FinishedRace/Reset overrides left), `gs:FindRacerIndexByPlayer(pc.PlayerState) >= 0`, and for local PCs
`car.PlayerInputComponent.RawInputSubsystem` equals `pc.RawInputSubsystem`. Escalations, each behind a switch and
logged: AI still steering → `car.RaceAIComponent:SetBehaviour(0)` (Idle; undone with 2 on release)
(`cfg.TakeoverIdleAI`); pad not driving → `car.ResetComponent:Client_BindInputActions()` (`cfg.TakeoverBindInput`;
round 4: for a REMOTE PC the server cannot read the binding, so the NetClient RPC is sent once in verify#1 with
`cfg.TakeoverBindInputRemote`, routed to the client that owns the car after Possess, V-TKO-12),
then, last resort, raw write `car.PlayerInputComponent.RawInputSubsystem = pc.RawInputSubsystem`
(`cfg.TakeoverForceRawInput`, default false) [PS§6].
`aiPS.bIsABot` stays true (`cfg.TakeoverClearBotFlag = false`).
`cfg.TakeoverAdoptPS = false` gives the smoke-test variant (possess only); then `hud` patches position and lap
from `rec.aiPS` because the HUD's owning PlayerState is not a racer [HUD§6 #6].

### 3.4 Release (`takeover.release(rec)`), exact order, server
```
1. rec.pc:UnPossess()                                  (skip if rec.pc is no longer valid)
2. if rec.adopted then
     if rec.pc.PlayerState == rec.aiPS and U.alive(rec.ownPS) then rec.pc.PlayerState = rec.ownPS end
       -- only while the PC still holds the racer PS, never nil: a late release must not clobber a live PC's new PS
     rec.aiPS:SetOwner(U.ok(rec.aiCtrl) and rec.aiCtrl or nil)
   end
   -- MUST precede any RemovePlayer/destroy of rec.pc: AController::Destroyed destroys pc.PlayerState [PS§7]
3. if U.ok(rec.aiCtrl) then
     if rec.aiCtrlHadPS then rec.aiCtrl.PlayerState = rec.aiPS end
     rec.aiCtrl:Possess(rec.car)
   end
   if rec.car.PlayerState ~= rec.aiPS then rec.car.PlayerState = rec.aiPS end      -- raw fallback [S]
4. if U.ok(rec.aiCtrl) then rec.car:SetInputSource_OnServer(2) else rec.car:StartInputSourceOverride_OnServer(4) end
   if cfg.TakeoverIdleAI then rec.car.RaceAIComponent:SetBehaviour(2) end
5. state.takeovers[...] = nil ; state.takeoversByCar[...] = nil
```
Triggers: F7 on a taken-over local guest (then `RemovePlayer(pc, false)` **after** release); `phase` leaving the
race (§5: `takeover.releaseAll()` runs on LEAVING detection, before the world goes); a hooked
`RacingGameMode:OnPlayerControllerDestroyed(playerController)` pre-callback for a recorded PC (release before the
engine destroys the controller and its PlayerState) (V-TKO-06).

### 3.5 Results must not block (R5)
`BP_Csm_Race_WaitForAllPlayersToFinish` waits on `ARacingGameState.Racers` only (OnTick: `Array_Get(RacingState.Racers, i)`
-> cast `GfnPlayerState` -> `RaceEventComponent->IsStillRacing()`, then `ContinueToNextState`; bytecode via
`scripts/kismet-disasm.py`, no `PlayerArray` in its name table) [corrects NET§5.1]. A PlayerState without a racer entry
(`FindRacerIndexByPlayer < 0`: rejoined client, refused late joiner, spectator, the idle `ownPS` of an adopted takeover)
never blocks. With adoption the car carries `aiPS`, which finishes natively: nothing to do.
`takeover.finishIdlePlayerStates()` (SLOW poll and phase → POSTRACE, server, `cfg.FinishIdlePlayerStates = true`) only
acts on a **non-adopted** record (`cfg.TakeoverAdoptPS = false` or step 2 failed): its `aiPS` is a Racers entry no car of
`gs.Vehicles` carries; once the human's car `bHasFinishedEvent`, every carried racer is done, or POSTRACE, it calls
`rec.aiPS.RaceEventComponent:Server_Cheat_FinishRace(false)` once (a Server RPC called on the server runs locally)
(V-TKO-07). Optional safety net `cfg.FinishUncarriedRacers` (default false): once every carried racer is done, finish any
Racers entry still racing that no car carries, once per PlayerState and race. The cheat RPC is never sent to a human or
non-racer PlayerState (`ARacingGameState.bHaveCheatsBeenUsed` is replicated; its effect is unknown).

### 3.6 Native-slot human leaving mid-race
F7 on a guest that holds a native slot: `pc.Pawn:StartInputSourceOverride_OnServer(4)` (Disconnect; the AI drives) and
keep the LocalPlayer and PC until the front end; `join.resync()` removes it there with `RemovePlayer(pc, true)`
[PS§7]. On a connected client F7 in a race is refused with `DISCONNECT TO CHANGE PLAYERS` (integration round 3): a
client's `RemovePlayer` is not seen by the host (`UGameInstance::RemoveLocalPlayer` only destroys an authoritative PC,
no split-leave message), which would leave a ghost remote player with a grid car; `join.resync` never removes a
`leaving` slot while the set is frozen.
Hooks `RacingGameMode:OnPlayerControllerDestroyed` and `/Script/Griffin.MatchManagerSubsystem:OnHumanSwitchedWithAI`
are logged by `diag` to learn the game's own path (V-TKO-08).

---

## 4. Modules

### 4.0 Shared conventions (binding for every file)
- **Files.** All code in `mod/SWGRCouch/Scripts/*.lua`, flat (the UE4SS searcher does not map dotted names to folders
  [API§12]). `enabled.txt` stays. Lua 5.4; every file passes `luac5.4 -p`. Every module returns one table named after
  the file (`local M = {}` … `return M`); no globals except what UE4SS defines.
- **Requires.** At file top a module may `require` only group-1 modules (`consts`, `config`, `settings`, `state`,
  `util`, `sched`) and `UEHelpers`. Any other module is reached **lazily** with `U.mod("name")` inside a function
  (avoids circular-require half tables). `main.lua` is the only file that requires everything at top level.
- **Logging.** `U.log(tag, fmt, ...)` → `print("[SWGRCouch][" .. tag .. "] " .. msg .. "\n")`. Variants `U.dbg`
  (only `cfg.Debug`), `U.warn`, `U.err`, `U.logOnce(key, tag, fmt, ...)`, `U.logEvery(key, ms, tag, fmt, ...)`. Tags are
  the module names (`hud`, `net`, …). User-visible messages go through `St.emit("status", text)` (Lobby status row)
  **and** the log.
- **Errors.** `U.try(tag, fn, ...)` = `xpcall(fn, debug.traceback, ...)`; on error logs `ERROR` with the traceback and
  returns `false`; otherwise returns `true, results...`. Every hook callback, scheduled callback, event listener and
  keybind body is wrapped (by `U.hook`, `sched.*`, `St.on`, `keys` respectively). Inside a tick, independent blocks
  (one per guest, one per car) get their own `U.try` so one bad object does not stop the others.
- **Game thread.** Only `sched.run/after/every/nextFrame` start game work. `sched.GT` = `EGameThreadMethod.EngineTick`
  if `EngineTickAvailable` else `EGameThreadMethod.ProcessEvent` [API§2] (V-CORE-01).
- **Loops (owned by `main`).** FAST every `cfg.FastPollMs` (33), MAIN every `cfg.MainPollMs` (250), SLOW every
  `cfg.SlowPollMs` (1000), all `sched.every`. `main` calls module tick functions explicitly in a fixed order (§4.2
  `main`). No other module starts a permanent loop.
- **Validity.** `U.ok(o)`: `o ~= nil and type(o) == "userdata" and o:IsValid()` inside `pcall`. `U.alive(o)`: `U.ok(o)` and,
  when `cfg.UseKslIsValid`, `KismetSystemLibrary:IsValid(o)` (catches Garbage-marked actors) (V-CORE-05).
  `U.key(o)` = `o:GetAddress()` (table keys); `U.same(a, b)` = both ok and `a == b`.
- **Classes and objects.** `U.class(key)` resolves a `consts.CLASS`/`consts.BP` key or a full path: cache →
  `StaticFindObject(path)` → for `/Game/…_C` paths `LoadAsset(<path without _C>)` (3 returns ignored; game thread
  only) then `StaticFindObject(path)` again [API§10]. Cached entries are re-checked with `U.ok`. `U.isA(o, key)` uses
  the cached UClass. `U.obj(path)` does the same for non-class assets (CSM assets, data assets).
- **Shared state.** Only `state.lua` holds cross-module state (one table `St`, fields fixed in §4.2 `state`). A module
  may keep private caches of UObjects only if it re-validates them before use. Module-private state lives in
  `St.<module>` so `diag` can dump everything.
- **Events.** `St.on(event, tag, fn)` / `St.emit(event, ...)`. Fixed event names: `"phase"(new, old)`, `"leaving"(reason)`, `"leaving_cancelled"(phase)`,
  `"world"(world)`, `"menu"(menuWidget)`, `"tab"(shown:boolean)`, `"players"()`, `"race_chosen"(choice)`,
  `"launched"()`, `"net"()`, `"status"(text)`, `"settings"(key, value)`. Listeners run synchronously, each in `U.try`.
- **Config vs settings.** `config.lua` = developer constants, timings and fallback selectors (edit + restart).
  `settings.lua` = user choices persisted to `<ModDir>/settings.txt` (Lobby rows, address, port, last race).
  In this document `cfg.X` means `require("config").X` and `settings.X` in prose means `settings.get("X")`.
- **Naming.** Files and module tables lower-case (`menu_tab`); public functions lowerCamelCase; constants in
  `consts` UPPER or CamelCase keys exactly as listed; config/settings keys PascalCase. Lobby row ids are the strings
  of §1.2. UE parameter values are always built at the call site from `consts.E` (never bare magic numbers).
- **Hooks.** Only through `U.hook(path, {pre = fn, post = fn}, tag)`: for `/Script/` paths it calls
  `RegisterHook(path, pre or noop, post)`; for `/Game/` (Blueprint) paths `RegisterHook(path, post or pre)` (one
  callback, after the BP body [API§4]). Registration runs in `pcall`; when the UFunction is not loaded yet the request
  is queued and `U.retryPendingHooks()` (SLOW loop and every `NotifyOnNewObject` callback) retries it. A path is
  registered once; ids are kept in `St.hooks` (diag, `U.unhookAll()` for an explicit reset on the game thread; on unload
  UE4SS unhooks the mod's hooks itself). Callback params are `RemoteUnrealParam`s: always `:get()`.

### 4.1 Implementation groups (disjoint file sets)
| Group | Files | Responsibility |
|---|---|---|
| **G1 Core** | `consts.lua`, `config.lua`, `settings.lua`, `state.lua`, `util.lua`, `sched.lua` | constants (paths, enums, keys, colours), dev config, persisted settings (io), the shared state table + event bus, object/class/world helpers, logging and error handling, game-thread scheduler |
| **G2 Wiring & lifecycle** | `main.lua`, `phase.lua`, `keys.lua`, `diag.lua` | boot order, the three loops and tick order, phase detection and transition events (LoadMap/InitGameState/seamless/return-to-menu hooks), debug keybinds + `couch` console command, diagnostics dumps and debug-only hooks |
| **G3 Front-end UI** | `ui.lua`, `menu_tab.lua`, `lobby.lua` | widget factory + click detection, the SPLIT SCREEN tab on `WBP_FE_MainMenu_C` and page switching, the Lobby page rows/labels/actions |
| **G4 Players & launch** | `join.lua`, `split.lua`, `builder.lua`, `launch.lua` | dormant guests + pad edge polling + device events, engine split-screen settings and single-view control, race-builder embedding and choice capture/persistence, `LaunchCustomRace` |
| **G5 In-race presentation** | `hud.lua`, `nametags.lua`, `gfx.lua`, `pause.lua`, `present.lua`, `wreck.lua` | per-player HUDs and patches, coloured name tags, split graphics preset + takedown cameras, guest pause, per-phase view layout + per-player ignition, wreck/finish race rules (timeout guard, spectate, no-wreck, slow-mo) |
| **G6 Racer assignment** | `roster.lua`, `takeover.lua` | who is human/local/remote/late, takeover with PlayerState adoption, release, idle-PlayerState finishing |
| **G7 Network** | `net.lua`, `netfix.lua`, `mod/config/Engine.ini` | host/join/listen/rejoin/travel fallbacks, network-failure handling, ack fix, Iris/safety cvars, the user Engine.ini override |

Dependency rule: G1 depends on nothing (except `UEHelpers`). G2–G7 may call G1 freely and other groups only through
the public APIs listed below, lazily. A call not listed in a module's "May call" line is not allowed.

### 4.2 Module contracts

Format per module: **File · Responsibility · Public API · May call · Game/engine calls (with evidence) · State ·
VERIFY**. "Game calls" lists every UFunction/property the module touches; parameter order is the reflected order.

#### G1 · `consts.lua`
- **Responsibility:** the single source of every path, name, enum value, key name and colour. No functions except
  `C.enumName(enumTable, value) -> string`.
- **Public API (exact keys):**
  - `C.MOD = "SWGRCouch"`, `C.VERSION = "0.2.0"`, `C.TAB_ID = "SWGR_SplitScreen"`, `C.TAB_LABEL = "SPLIT SCREEN"`.
  - `C.GAME_TABS = {MainMenu_Recommended = 0, MainMenu_Scenarios = 1, MainMenu_Arcade = 2, MainMenu_Multiplayer = 3}`
    (tab id → switcher index of the game's pane [MT§2]).
  - `C.CLASS`: `PlayerController="/Script/Engine.PlayerController"`, `GameModeBase="/Script/Engine.GameModeBase"`,
    `GridPanel="/Script/UMG.GridPanel"`, and `/Script/Griffin.<X>` for `FrontEndGameMode, FrontEndGameState,
    RacingGameMode, RacingGameState, VehiclePawn, GfnPlayerController, GfnPlayerState, GfnGameInstance, FuseHudWidget,
    UIManager, CosmeticStateMachineManager, ViewModelSubsystem, EventRecipeSubsystem, PlayfabOnlineMatchmaking,
    PvpFlowComponent, PlayerSpectatorComponent, DrivingAIController, PassbyWorldSubsystem, OvertakeWorldSubsystem,
    AudioNonPlayerProximityWorldSubsystem` [HERE script-objects].
  - `C.CDO`: `GameplayStatics="/Script/Engine.Default__GameplayStatics"`,
    `KismetSystemLibrary="/Script/Engine.Default__KismetSystemLibrary"`,
    `WidgetBlueprintLibrary="/Script/UMG.Default__WidgetBlueprintLibrary"`,
    `SubsystemBlueprintLibrary="/Script/Engine.Default__SubsystemBlueprintLibrary"`,
    `GameMapsSettings="/Script/EngineSettings.Default__GameMapsSettings"` [API§6, HERE].
  - `C.BP` (class paths, `_C`): `MainMenu=/Game/Griffin/UI/Screens/MainMenu/WBP_FE_MainMenu.WBP_FE_MainMenu_C`,
    `TabBtn=/Game/Griffin/UI/Widgets/Buttons/WBP_Tab_Btn.WBP_Tab_Btn_C`,
    `CommonBtn=/Game/Griffin/UI/Widgets/Buttons/WBP_Common_Btn.WBP_Common_Btn_C`,
    `VerticalBtn=/Game/Griffin/UI/Widgets/Buttons/WBP_Vertical_Btn.WBP_Vertical_Btn_C`,
    `SettingList=/Game/Griffin/UI/Widgets/Settings/WBP_Setting_List.WBP_Setting_List_C`,
    `SectionHeader=/Game/Griffin/UI/Widgets/Global/WBP_SectionHeaderModal.WBP_SectionHeaderModal_C`,
    `Builder=/Game/Griffin/UI/Widgets/FrontEnd/QuickRace/WBP_FE_QuickRace_Custom_Widget.WBP_FE_QuickRace_Custom_Widget_C`,
    `HudRace=/Game/Griffin/UI/Screens/WBP_Hud_Race.WBP_Hud_Race_C`, `HudMemory=/Game/Griffin/UI/Screens/WBP_Hud_Memory.WBP_Hud_Memory_C`,
    `LapCounter=/Game/Griffin/UI/Widgets/HUD/WBP_Hud_EventLapCounter.WBP_Hud_EventLapCounter_C`,
    `LapCounterMemory=/Game/Griffin/UI/Widgets/HUD/WBP_Hud_EventLapCounter_Memory.WBP_Hud_EventLapCounter_Memory_C`.
  - `C.ASSET` (object paths `Pkg.Obj`): `CSM_PauseRoot`, `CSM_PauseMenu`, `CSM_PauseIdle`, `CSM_PauseActive` under
    `/Game/Griffin/Config/StateMachines/PauseMenus/CSM_PauseMenus_{Root,PauseMenu,Idle,Active}`; `CSM_InProgressInHud`,
    `CSM_CountdownInHud`, `CSM_PostRace` (`CSM_RF_PostRacePhase`), `CSM_LocalResults`, `CSM_RFInProgress`
    (`CSM_RF_InProgress`), `CSM_RFCountdown` (`CSM_RF_Countdown`) under
    `/Game/Griffin/Config/StateMachines/RaceFlow/` [HUD§7, HERE asset-list].
  - `C.STATE_NAME` (fallback FNames for `IsStateActive` [HUD§3.3]): `InProgressInHud="InProgress_InHud"`,
    `CountdownInHud="Countdown_InHud"`, `LocalResults="LocalResults"`.
  - `C.MAP.FrontEnd = "/Game/Griffin/Maps/L_FrontEnd/L_FrontEnd"` [NET§1.1].
  - `C.FN` (hook paths): `MenuRegisterTabs = BP.MainMenu..":RegisterTabs"`, `MenuCustomEvent = BP.MainMenu..":CustomEvent"`,
    `CommonBtnClicked = BP.CommonBtn..":BP_OnClicked"`,
    `BuilderGo = BP.Builder..":BndEvt__WBP_FE_QuickRace_Custom_Widget_Btn_Go_K2Node_ComponentBoundEvent_6_CommonButtonBaseClicked__DelegateSignature"`,
    `LapUpdate = BP.LapCounter..":UpdateCurrentLap"`, `LapUpdateMemory = BP.LapCounterMemory..":UpdateCurrentLap"`,
    `DeviceChanged="/Script/Griffin.GfnGameInstance:OnUserInputDeviceChanged"`,
    `NetFailure="/Script/Griffin.GfnGameInstance:HandleNetworkFailure"`,
    `StartingNewPlayer="/Script/Engine.GameModeBase:HandleStartingNewPlayer"`,
    `MidGameJoiner="/Script/Griffin.PlayerSpectatorComponent:Client_SetIsMidGameJoiner"`,
    `RaceCtrlDestroyed="/Script/Griffin.RacingGameMode:OnPlayerControllerDestroyed"`,
    `RequestReturnToMenus="/Script/Griffin.RacingGameMode:RequestReturnToMenus"`,
    `SeamlessTravelStarted="/Script/Griffin.RacingGameState:OnSeamlessTravelStarted"`,
    `AckRequest="/Script/Griffin.PvpFlowComponent:Client_RequestAckObjects"`,
    `HumanSwitchedWithAI="/Script/Griffin.MatchManagerSubsystem:OnHumanSwitchedWithAI"`,
    `ControllerAssigned="/Script/Griffin.VehiclePawn:Multi_ReceiveControllerAssigned"`,
    `PossessedPawnChanged="/Script/Griffin.GfnPlayerController:PossessedPawnChanged"` [PS§3, NET§3.3, §5.2, HERE].
  - `C.KEY = {A="Gamepad_FaceButton_Bottom", B="Gamepad_FaceButton_Right", Y="Gamepad_FaceButton_Top",
    Start="Gamepad_Special_Right"}` [API§3].
  - `C.E` (integers): `InputSource {None=0,Player=1,AI=2}`; `Override {None=0,SpawnPlayer=1,SpawnAI=2,FinishedRace=3,
    Disconnect=4,RollingStart=5,TakedownCam=6,VehicleCineProxy=7,Debug=8,Autopilot=9,Reset=10}`; `AIBehaviour {Idle=0,
    Countdown=1,Racing=2,Aggression=3,PostRace=4,FollowSplineDirect=5}`; `Archetype {Car=0,Plane=1,Bike=2,Skimmer=3}`;
    `GridEntry {Car=0,Plane=1,Bike=2,Skimmer=3,PlayerChoice=4}`; `PrimaryFlow {Unknown=0,Campaign=1,QuickRace=2,Arcade=3,
    Multiplayer=4}`; `Vis {Visible=0,Collapsed=1,Hidden=2,HitTestInvisible=3,SelfHitTestInvisible=4}`; `UILayer {InWorld=0,
    HUD=1,Menu=2,Dialog=3,MenuOverlay=10}`; `TwoP {Horizontal=0,Vertical=1}`; `ThreeP {FavorTop=0}`; `FourP {Grid=0}`;
    `HAlign {Fill=0,Left=1,Center=2,Right=3}`; `DeviceConn {Invalid=0,Unknown=1,Disconnected=2,Connected=3}`;
    `NetworkFailure` = array `[0..10]` of the `ENetworkFailure` names [HERE]; `ViewBlend {Linear=0}` [PS§1-2, RB§5.1, UI§1.3].
  - `C.COLOURS = {[1]={R=0.7913,G=0.3968,B=0.1046,A=1}, [2]={R=0.2874,G=0.5271,B=0.4678,A=1},
    [3]={R=0.4564,G=0.5647,B=0.1878,A=1}, [4]={R=0.5906,G=0.0931,B=0.0931,A=1}, Remote={R=1,G=1,B=1,A=1}}` (0.12.0
    planet hues: apricot, teal, lime, Crait red); `C.COLOUR_INK` (the tag ink on each hue) and `C.COLOUR_P4_SAND` (the
    V-FIN-13 fallback for P4): Revision 0.12.0 item 9.
- **May call:** nothing. **State:** none. **VERIFY:** none (all values are file-verified).

#### G1 · `config.lua`
- **Responsibility:** developer constants and fallback selectors; returns one table `cfg`. Header comment: "edit, then
  restart the game or Ctrl+F11".
- **Keys and defaults (exact):**
  - Core: `Debug=true`, `FastPollMs=33`, `MainPollMs=250`, `SlowPollMs=1000`, `UseKslIsValid=true` (V-CORE-05),
    `SubsystemLookup="sbl"` | `"findfirst"` (V-CORE-06), `LoopErrorLogEveryMs=5000`, `DiagPeriodicMs=0`.
  - Tab/UI: `ClickMode="hook"` | `"poll"` (V-LOB-03), `ReturnToSplitTab=true` (V-TAB-06),
    `RestoreGamePaneOnTabLeave=false` (V-TAB-05), `DeactivateGamePaneOnShow=false` (V-TAB-12), `LaunchOnGo=false`, `BuilderBackButton=true`, `BuilderBackRow=3`,
    `BuilderBackCol=0` (V-BLD-03), `LobbyRootMode="setting_list"` | `"own"` (V-LOB-01, §7),
    `BuilderMode="embedded"` | `"devscreen"` (V-BLD-01, §7).
  - Join: `MaxLocalPlayers=4`, `JoinArmMs=300`, `JoinWithStart=true`, `JoinFocusTrick="none"` | `"userfocus"` |
    `"viewport"` (V-JOIN-03).
  - Launch: `ConditionPassMode="table"` | `"trackdefault"` (V-LCH-01), `SelectVehicleForGuests=false` (V-LCH-05),
    `GrowGridInMemory=false` (V-LCH-04).
  - HUD: `P1HudMode="rehost"` | `"clone"` | `"leave"` (V-HUD-02), `GuestHudZOrder=10`, `LapPatch=true` (V-HUD-04),
    `GuestHudCollapse={"WBP_Hud_PositionMap","Img_1DMap_MidSection","WBP_Hud_BestLapTime","WBP_Hud_EventTakedownCounter"}`
    (members of `WBP_HUD_RaceInfo` [HUD§1.2]), `GuestHudNotifications="keep"` | `"remove"` (V-HUD-08),
    `GuestMarkers="keep"` | `"collapse"` (V-HUD-09), `GuestBotEngineFix=false` (V-HUD-10), `HudSearchFallback=true`
    (V-HUD-01), `HudVisibilityMode="csm"` | `"always"` (V-HUD-05).
  - Pause: `GuestPauseMode="hud"` | `"poll"` | `"off"`, `GuestHudRegisterInput=false` (V-PAU-01).
  - Race: `AIOnPadDisconnect=true`, `AllowMidRaceJoin=false`, `ReRegisterP1Pawn=false` (V-TKO-10).
  - Graphics: `GfxPresets = { performance = {["sg.GlobalIlluminationQuality"]=0, ["sg.ReflectionQuality"]=0,
    ["sg.ShadowQuality"]=1, ["sg.EffectsQuality"]=1, ["sg.ViewDistanceQuality"]=1, ["r.Shadow.Virtual.Enable"]=0,
    ["r.Lumen.DiffuseIndirect.Allow"]=0, ["r.ScreenPercentage"]=50}, quality = {["sg.GlobalIlluminationQuality"]=1,
    ["sg.ReflectionQuality"]=1, ["sg.ShadowQuality"]=1, ["r.ScreenPercentage"]=62, ["r.Streaming.PoolSize"]=3000} }`
    [ANALYSIS§6]; `GfxAutoQualityMaxViews=2` (auto = quality for ≤ 2 views, performance above).
  - Takeover: `SlotMode="auto"` | `"off"`, `TakeoverGraceMs=3000`, `TakeoverWhen="started"` | `"countdown"`,
    `TakeoverMidGameJoiners=false`, `TakeoverPick="last"` | `"first"`, `TakeoverAdoptPS=true`, `TakeoverIdleAI=false`,
    `TakeoverBindInput=true`, `TakeoverForceRawInput=false`, `TakeoverClearBotFlag=false`, `FinishIdlePlayerStates=true`.
  - Network: `JoinMethod="openlevel_opts"` | `"openlevel"` | `"console"` (V-NET-05/06),
    `HostTravelFallback="relisten"` | `"relisten_takeover"` | `"none"` (V-NET-13), `ServerTravelOnMissingCars=false`,
    `AutoRelistenInFrontEnd=true`, `AutoRejoin=true`, `IrisOff=false` (V-NET-03), `NetSafetyCvars={}`,
    `ListenCheckMs=10000`, `TravelCheckDelayMs=2000`, `RemoteArriveTimeoutMs=20000`, `RejoinWaitMs=60000`,
    `RejoinDelayMs=3000`, `RejoinMaxTries=20`, `GuestAckMode="guests"` | `"all"` | `"off"` (V-NET-09),
    `LoginLogEveryMs=5000`.
  - Added in integration round 1 (fallback selectors; every key a module reads is defined here):
    `GoMode="hook"` | `"click"` (V-BLD-06), `TabDetectMode="hook"` | `"both"` | `"poll"` (V-TAB-10),
    `JoinButtons="a_or_start"` | `"start"` (V-JOIN-06), `DeviceDetectMode="hook"` | `"both"` | `"poll"` (V-JOIN-10),
    `LocalResultsMode="hide"` | `"rehost"` | `"leave"` (V-HUD-13), `ForceCarTags=false` (V-HUD-11b),
    `P1PausePoll=true` (V-PAU-03), `GfxApplyMode="console"` | `"usersettings"` (V-GFX-05),
    `TakeoverAICarTest="original"` | `"override"` (V-TKO-02), `TakeoverEndSpectateRemote="joiner"` | `"always"` | `"off"`
    (V-TKO-11).
  - Added in integration round 2: `LaunchTimeoutMs=30000`, `LaunchAcceptedTimeoutMs=180000` (V-LCH-06),
    `LocalResultsMode` gains `"hide_inactive"` (V-HUD-13), `FinishNonRacerPlayerStates` (round 2; superseded: replaced by `FinishUncarriedRacers=false`, V-TKO-07),
    `RacerPSSource="pawn"` | `"controller"` (V-TKO-05), `ServerTravelWatchdogMs=10000` (V-NET-16).
  - Integration round 3: `FinishNonRacerPlayerStates` removed; `FinishUncarriedRacers=false` (V-TKO-07),
    `MemoryLapMode="hook"` | `"collapse"` (V-HUD-04c), `DeactivateGamePaneOnShow=false` (V-TAB-12, now defined),
    `ClientMenuFallback="csm"` | `"off"` (V-NET-17); `TabDetectMode` default becomes `"both"` (`"hook"` still polls
    while the CustomEvent hook is unregistered or found silent); `DeviceDetectMode="hook"` runs the SLOW device poll as
    an edge-only watchdog (no baseline report; an edge is applied only when no device hook call came in the last 3 s).
    `config_user.lua` top-level overrides are type-checked against the default, string selectors against their allowed
    values (`ENUMS` in `config.lua`), and `FastPollMs/MainPollMs/SlowPollMs` must be > 0; a bad override is ignored
    with a warning.
  - Integration round 4: `StopHostingMethod="openlevel_abs"` | `"disconnect"` (V-NET-18), `RejoinSettleMs=10000`
    (the relisten wait, counted from the confirmed race-map listen, ends only after no arrival for this long, at most
    2 × `RejoinWaitMs`), `RejoinAfterQuitToMenu=false` (V-NET-19), `TakeoverBindInputRemote=true` (V-TKO-12),
    `LeaveHoldMs=1000` (V-JOIN-09), `OurTabSyncFix="clear"` | `"off"` (V-TAB-13).
  - 0.7.0: the `UxSplit*` keys (G5 uxsplit contract); pause layers A-G (G5 pause contract): `PauseHudInputGuard=true`,
    `PauseInputsBackMs=150` (> 0), `PauseCsmHook=true`, `PauseHookReadState=true`, `PauseHookTrace=false`,
    `PauseMenuPrecreate=true`, `PauseMenuOwner="pauser"` | `"p1"` | `"game"` | `"keep"`, `PauseOwnerPadShift="auto"` |
    `"off"`, `PauseMenuZ="auto"` | a number ≥ 0 (`MIXED`), `PauseUiImcBoost="all"` | `"owner"` | `"off"`,
    `PauseNoSubStateMs=150` (> 0), `PauseAnyStartResumes="fallback"` | `"always"` | `"off"`, `PauseRestartCsm="onpress"`
    | `"eager"` | `"off"`; `PauseMenuRehost` default `"never"` (`"auto"` = `"never"`, `"always"` = A/B rehost tests);
    `PauseLostMenu`, `PauseLostMenuMs`, `PauseMenuFocusOwner`, `PauseMenuZOrder`, `P1PausePoll` keep their defaults with
    the 0.7.0 meaning (V-PAU-09..18).
  - `Defaults` = the settings defaults table (below). `DefaultsBuiltin` = a copy of it taken before the user merge
    (round 2): `settings.lua` replaces a merged `Defaults` value outside `settings.ALLOWED` with the built-in one
    (warning logged), since `config.lua` cannot require `settings`.
  - **User overrides:** `config.lua` is not edited by the user. At its end it loads the optional
    `Scripts/config_user.lua` (`return { Key = value }`, top-level keys replace the defaults, except `Defaults`, which
    is merged key by key with a type check; unknown keys and mistyped / out-of-list values are ignored with a warning) through `loadfile` + `pcall`: a broken override file is logged and ignored, so a typo
    never stops the mod.
- **May call:** nothing. **State:** none.

#### G1 · `settings.lua`
- **Responsibility:** load/save the user's choices as `key = value` lines in `<ModDir>/settings.txt` with plain `io`
  (`io`/`os` are available [HERE]). Unknown keys are kept verbatim on save; a missing file is created from defaults.
- **Keys (type, default):** `Layout2P` (string `"top-bottom"` | `"side-by-side"`), `SplitGraphics` (`"performance"` |
  `"auto"` | `"quality"` | `"off"`), `TakedownCams` (bool `false`), `NameTags` (bool `true`), `KeyboardIsP1` (bool `false`),
  `NetMode` (`"offline"` | `"host"` | `"join"`), `JoinAddress` (string `"10.8.0.1"`), `Port` (int `7777`),
  `LastRaceArchetype`, `LastRaceGameMode`, `LastRacePlanet`, `LastRaceTrack`, `LastRaceBuild`, `LastRaceDebugBuild`
  (object paths `"/Game/…/X.X"`, default `""`), `LastRaceCondition` (tag string, default `""`).
- **Public API:** `settings.load() -> boolean`, `settings.save() -> boolean`, `settings.get(key) -> value`,
  `settings.set(key, value)` (type-checked against the default's type; saves immediately; emits `"settings"`),
  `settings.cycle(key, valuesArray) -> newValue`, `settings.toggle(key) -> newValue`, `settings.path() -> string`,
  `settings.modDir() -> string`.
- **Mod directory:** `debug.getinfo(1, "S").source` (chunk names are `"@<path>"` [HERE]); normalise `\` to `/`; strip
  `/Scripts/settings.lua` (case-insensitive `scripts`). Fallback: find in `package.path` the entry matching
  `"(.-/Mods/SWGRCouch/[Ss]cripts)/%?%.lua"` and take its parent. Last fallback: `"Mods/SWGRCouch"` relative (log a
  warning) (V-CORE-03).
- **File format:** UTF-8, `# comment` lines, `Key = value`; bools `true`/`false`; numbers via `tonumber`; strings raw
  (trimmed). Saving rewrites the file in place with `io.open(path, "w")` (no temp file, no delete).
- **May call:** `util` (log only), `state` (emit). **Game calls:** none. **State:** private `values` table.
- **VERIFY:** V-CORE-03.

#### G1 · `state.lua`
- **Responsibility:** the one shared table `St` plus the event bus. No game calls.
- **Fields (exact; created at load; types in comments):**
  ```lua
  St.phase = "BOOT"            -- BOOT|FRONTEND|LAUNCHING|LOADING|PRERACE|RACING|POSTRACE|LEAVING|OTHER|TRANSIT
  St.phaseSinceMs = 0
  St.worldKey, St.gsKey = 0, 0  -- addresses of the current UWorld / GameState
  St.worldGen = 0               -- +1 on every new world (phase), also at a reused address; never persisted
  St.menu = { widget=nil, key=0, tabAdded=false, lobby=nil, builder=nil, visible=nil,  -- visible: "lobby"|"builder"|nil
              hooksMenu=false, hooksBuilder=false, prevTabId=nil }   -- menu_tab adds worldKey (menu's UWorld address)
  St.ui = { buttons = {}, rows = {}, statusText = "", dirty = true, returnToTab = false }
             -- buttons[addr] = {id=string, fn=function, widget=UObject}; rows[id] = UObject
  St.join = { active=false, frozen=false, keep=false,   -- keep: commit()/net failure -> joined set survives travel
              slots = {} }  -- slots[ctrlId 1..3] = {ctrlId, joined=false, prevA=false, prevB=false,
                            --   prevStart=false, createdMs=0, disconnected=false, leaving=false}
  St.race = { choice=nil, startedAtMs=0, started=false, lapOffset=nil, localViews=1, launchedByUs=false,
              mapPath="", singleView=false }   -- singleView: join's race_enter guard handed the guests to the AI
  St.launch = { pending=false, atMs=0, accepted=false }   -- accepted: PrimaryFlow == QuickRace after the call
  St.hud = { p1hud=nil, p1Placed=false, guests={}, lapCounters={} }
             -- guests[pcKey] = {pc, widget, pnum, lapCounter, lastLapText}; lapCounters[addr] = pcKey
  St.tags = { seen = {} }
  St.gfx = { saved=nil, savedTakedown=nil, appliedViews=0 }
  St.takeovers, St.takeoversByCar = {}, {}           -- rec tables of §3.3
  St.roster = { firstSeen = {}, midGame = {}, remote = {}, humans = {} }  -- keyed by PC address
  St.net = { hosting=false, wantConnected=false, connecting=false, listenSinceMs=0, expectedRemote=0,
             relistenDone=false, relistenPending=false, waitUntilMs=0, serverTravelDone=false,
             lateJoinAllowed=false, rejoinTries=0, nextRejoinMs=0, lastFailure=nil, driverChecked=false,
             lastRemoteCount=0, lastLoginLogMs=0 }
  St.hooks = {}                                      -- path -> {pre=id, post=id}
  St.pendingHooks = {}                               -- path -> {spec, tag}
  ```
- **Events:** `"phase"(new, old)`, `"race_enter"(new, from)` (emitted by `phase` just before `"phase"` when a race
  phase is entered from a non-race phase; `from` = the previous phase other than TRANSIT), `"leaving"(reason)`,
  `"world"(world)`, `"menu"(menu)`, `"tab"(shown)`, `"players"()`, `"race_chosen"(choice)`, `"launched"()`, `"net"()`,
  `"status"(text)`, `"settings"(key, value)`. `St.race.launchedByUs` is set by `launch.start/prepareExternal`, kept
  across the travel worlds by `St.resetRace()` and cleared on phase → FRONTEND by `launch`.
- **Public API:** `St.on(event, tag, fn)`, `St.emit(event, ...)` (each listener in `U.try(tag, ...)`; `util` is
  required lazily inside `emit`), `St.resetRace()` (race, hud, tags, takeovers, takeoversByCar, roster.midGame reset;
  keeps `race.choice`), `St.resetMenu()` (menu table back to defaults; keeps `ui.returnToTab`), `St.nowMs()`
  (`os.clock() * 1000`; monotonic enough for timers).
- **May call:** `util` (lazily, for `try`/log). **VERIFY:** none.

#### G1 · `util.lua`
- **Responsibility:** logging, error handling, object/class/world/subsystem helpers, console, hook registry.
- **Public API (exact):**
  - Logging: `U.log(tag, fmt, ...)`, `U.dbg(tag, fmt, ...)`, `U.warn(tag, fmt, ...)`, `U.err(tag, fmt, ...)`,
    `U.logOnce(key, tag, fmt, ...)`, `U.logEvery(key, ms, tag, fmt, ...)`.
  - Errors: `U.try(tag, fn, ...) -> ok, ...`; `U.mod(name) -> table` (`require(name)`; lazy access).
  - Validity: `U.ok(o) -> bool`, `U.alive(o) -> bool`, `U.key(o) -> integer|0`, `U.same(a, b) -> bool`,
    `U.isA(o, keyOrPath) -> bool`, `U.isVehicle(pawn) -> bool` (IsA `C.CLASS.VehiclePawn`),
    `U.isPlayerController(o) -> bool`.
  - Values: `U.str(v) -> string` (FString/FText/FName `:ToString()`, Lua string passthrough, else `tostring`),
    `U.fname(s) -> FName` (cached per string), `U.ftext(s) -> FText` (new each call), `U.arrayToTable(arr) -> table`
    (TArray userdata via numeric loop + `:get()` when elements are params, or a Lua table passthrough) (V-CORE-08),
    `U.arrayCount(arr) -> int` (`arr:GetArrayNum()` or `#tbl`), `U.pathOf(obj) -> string` (`GetFullName()` without the
    leading `"<Class> "`), `U.assetPathFromClassPath(p)` (strip trailing `_C`).
  - Classes/objects: `U.class(keyOrPath) -> UClass|invalid`, `U.obj(path) -> UObject|invalid` (StaticFindObject, then
    `LoadAsset(path)` on the game thread), `U.cdo(key) -> UObject` (from `C.CDO`), shorthands `U.GS()`, `U.KSL()`,
    `U.WBL()`, `U.SBL()`, `U.GMS()`.
  - World: `U.gi() -> GameInstance` (`FindFirstOf("GameInstance")` once, re-validated) (V-CORE-04),
    `U.localPlayers() -> array of {lp, pc, ctrlId, index}` (from `gi.LocalPlayers`, numeric loop, sorted by index;
    `pc = lp.PlayerController`, `ctrlId = lp.ControllerId`), `U.p1() -> pc|invalid`, `U.world() -> UWorld` (`U.p1():GetWorld()`,
    else `UEHelpers.GetWorld()`), `U.gs()` (`world.GameState`), `U.gm()` (`world.AuthorityGameMode`; invalid on clients),
    `U.isServer()` (`KSL:IsServer(world)`), `U.isStandalone()` (`KSL:IsStandalone(world)`), `U.netMode() ->
    "standalone"|"listen"|"client"`, `U.levelName() -> string` (`GameplayStatics:GetCurrentLevelName(world, true)`),
    `U.currentMapPath() -> "/Game/…/L_X"` (package part of `U.pathOf(world)`).
  - Subsystems: `U.giSubsystem(classKey) -> UObject` (`SBL:GetGameInstanceSubsystem(gi, U.class(key))`, cached per GI;
    fallback `FindFirstOf(<short name>)` once per world when `cfg.SubsystemLookup = "findfirst"` or the first call
    fails) (V-CORE-06); `U.worldSubsystem(classKey)` (`SBL:GetWorldSubsystem(world, cls)`, cached per world).
  - CSM: `U.csmActive(assetKey) -> bool|nil` (`mgr:IsStateActiveByRef(U.obj(C.ASSET[k]))` with
    `mgr = U.giSubsystem("CosmeticStateMachineManager")`; when the asset is not resolvable falls back to
    `mgr:IsStateActive(U.fname(C.STATE_NAME[k]))`; `nil` if neither works) (V-HUD-05). `U.csmLoaded(assetKey) -> bool`
    (StaticFindObject only): the polls (hud.updateVisibility/inHudState, pause.isPaused) call `U.csmActive(k, true)` and
    map `false` to `nil` (unknown) when the asset is not in memory (its state machine is not running); `U.csmPoll(k)`
    wraps exactly that. `U.csmPaused() -> bool|nil`: `CSM_PauseActive` active; when that is unresolvable, Idle
    inactive counts only while `CSM_RFInProgress` or `CSM_RFCountdown` is active (or both unknown) (V-HUD-05).
  - Console: `U.console(cmd)` (`KSL:ExecuteConsoleCommand(world, cmd, nil)` [API§9]), `U.cvarInt(name)`,
    `U.cvarFloat(name)` (`KSL:GetConsoleVariableIntValue/FloatValue(name)`).
  - Hooks: `U.hook(path, spec, tag) -> bool` (spec = `{pre=fn, post=fn}`; rules §4.0), `U.retryPendingHooks()`,
    `U.unhookAll()`.
- **Game calls:** `StaticFindObject`, `LoadAsset`, `FindFirstOf("GameInstance")` (once), `GameInstance.LocalPlayers`,
  `LocalPlayer.PlayerController/ControllerId`, `UObject:GetWorld()`, `World.GameState/AuthorityGameMode`,
  `KSL:IsServer(World)`, `KSL:IsStandalone(World)`, `KSL:IsValid(Object)` [Inf stock signature],
  `KSL:ExecuteConsoleCommand(World, Str, nil)`, `KSL:GetConsoleVariableIntValue(Str)`,
  `GameplayStatics:GetCurrentLevelName(World, true)`, `SBL:GetGameInstanceSubsystem(Object, Class)`,
  `SBL:GetWorldSubsystem(Object, Class)` [Inf stock], `CosmeticStateMachineManager:IsStateActiveByRef(Object)` /
  `IsStateActive(Name)` [HERE], `RegisterHook`, `UnregisterHook` [API§4, §6, §9].
- **State:** private caches (classes, fnames, gi, subsystems keyed by owner address); `St.hooks`, `St.pendingHooks`.
- **VERIFY:** V-CORE-04, V-CORE-05, V-CORE-06, V-CORE-07, V-CORE-08, V-HUD-05.

#### G1 · `sched.lua`
- **Responsibility:** the only way to run game work; wraps every callback in `U.try`.
- **Public API:** `sched.GT` (method constant); `sched.run(tag, fn, ...)` (`ExecuteInGameThread(wrapped, sched.GT)`;
  callable from any thread); `sched.now(tag, fn, ...)` (if `IsInGameThread()` run inline else `run`);
  `sched.after(tag, ms, fn) -> handle` (`ExecuteInGameThreadWithDelay(ms, wrapped)`); `sched.every(tag, ms, fn) -> handle`
  (`LoopInGameThreadWithDelay(ms, wrapped)`; return value ignored; consecutive errors only throttle logging to one line per
  `cfg.LoopErrorLogEveryMs`, the loop is never cancelled by an error); `sched.nextFrame(tag, fn)`
  (`ExecuteInGameThreadAfterFrames(1, …)` if `EngineTickAvailable`, else `after(tag, fallbackMs or 0, fn)`; round 4:
  optional 3rd arg `fallbackMs` for callers that need a real frame boundary, e.g. `split.relayout` passes 50: a 0 ms
  action under the ProcessEvent method runs inside the same frame); `sched.cancel(handle)`
  (`CancelDelayedAction`, guarded by `IsValidDelayedActionHandle`); `sched.cancelAll()` (all handles it created).
- **Game calls:** the UE4SS globals above [API§2]. **State:** private handle list.
- **VERIFY:** V-CORE-01, V-CORE-02.

#### G2 · `main.lua`
- **Responsibility:** boot order, the three loops, tick order, unload. No game logic of its own.
- **Boot sequence (top level, mod thread; exact order):**
  1. `require` G1 (`consts, config, settings, state, util, sched`), then every other module.
  2. `settings.load()`; log banner: version, `EngineTickAvailable`, `ProcessEventAvailable`, `sched.GT`,
     `settings.path()`, `UnrealVersion` if available.
  3. Module `init()` calls in this order (each in `U.try`): `phase.init()`, `menu_tab.init()`, `ui.init()`,
     `join.init()`, `builder.init()`, `roster.init()`, `takeover.init()`, `hud.init()`, `pause.init()`, `net.init()`,
     `netfix.init()`, `diag.init()`, `keys.init()`. `init()` functions only register hooks/NotifyOnNewObject/event
     listeners; they never call UFunctions (native `/Script/` UFunctions exist at boot, so `U.hook` succeeds; BP hooks
     are queued).
  4. `sched.run("boot", split.init)` (CDO writes). The Iris cvar is applied by `netfix` on the first `"world"`
     event, when a world exists for `ExecuteConsoleCommand` and no net driver exists yet.
  5. Start loops: `FAST = sched.every("fast", cfg.FastPollMs, fastTick)`,
     `MAIN = sched.every("main", cfg.MainPollMs, mainTick)`, `SLOW = sched.every("slow", cfg.SlowPollMs, slowTick)`.
  6. `ModRef.OnUnload = function() sched.cancelAll(); <persist> end` [API§12] (wrapped in `pcall`, since
     the field may not exist). No `U.unhookAll()` there: `UnregisterHook` calls `StaticFindObject` and OnUnload is not
     on the game thread; `LuaMod::uninstall` unhooks every hook of the mod itself right after OnUnload. **Hot reload** (V-CORE-11): `<persist>` calls `persistShared(put)` of `join`, `net`, `gfx`,
     `takeover`, `launch` (round 2: `St.launch.pending/accepted/atMs`, so a reload during LAUNCHING stays LAUNCHING) and writes `ui.tabOpen`, `ui.returnToTab`, `race.launchedByUs`, then `persisted = true`, all through
     `ModRef:SetSharedVariable("SWGRCouch.<name>", v)` (survives `RestartCurrentMod`; scalars only — OnUnload is not on
     the game thread, so no UObject is touched; takeover records are stored as object addresses taken at takeover
     time). At boot, after step 3, when `persisted == true`: each module's `restoreShared(get)` (Lua state only), a
     tab that was open → `St.ui.returnToTab = true`; then `persisted = false`. Game-side leftovers are handled on the
     game thread by `menu_tab` (stale pages), `hud` (orphan guest HUDs), `takeover` (records re-found by address in the
     same world), `gfx` (saved values restored in the next front end), `join.open` (unknown guest PCs adopted).
- **Tick order (each line its own `U.try`):**
  - `fastTick`: `join.poll()` if `St.join.active`; `ui.pollClicks()` if `cfg.ClickMode == "poll"` and
    `St.menu.visible`; `pause.poll()` if `phase.isRace()` and (`cfg.GuestPauseMode == "poll"` or `cfg.P1PausePoll`).
  - `mainTick`: `phase.tick()`; then if `phase.isFrontEnd()`: `lobby.tick()`, `net.tick()`, `menu_tab.pollTab()` (when
    `menu_tab.pollWanted()`: `cfg.TabDetectMode` `"both"`/`"poll"`, or `"hook"` while the CustomEvent hook is not
    registered or `menu_tab.hookSilent`); if `phase.isRace()`: `roster.tick()`, `takeover.tick()`, `hud.tick()`,
    `nametags.tick()`, `net.tick()`, `join.raceTick()` (server only).
  - `slowTick`: `U.retryPendingHooks()`; `menu_tab.ensure()` if `phase.isFrontEnd()`; `net.slowTick()`;
    `takeover.finishIdlePlayerStates()` if `phase.isRace()`; `join.pollDevices()` (every mode; with `"hook"` it is
    the edge-only watchdog); `diag.periodic()`.
- **May call:** every module's `init`/tick functions listed above, `sched`, `U`. **Game calls:** none directly.
- **Keybind Ctrl+F11** (`RestartCurrentMod()`) is registered by `keys`, not here.
- **VERIFY:** V-CORE-01 (banner shows which game-thread method is used).

#### G2 · `phase.lua`
- **Responsibility:** decide the current phase, emit `"phase"`, `"world"`, `"leaving"`; record race start time.
- **Public API:** `phase.init()`, `phase.tick()`, `phase.get() -> string`, `phase.isFrontEnd() -> bool`
  (FRONTEND or LAUNCHING), `phase.isRace() -> bool` (LOADING, PRERACE, RACING, POSTRACE), `phase.markLeaving(reason)`
  (sets LEAVING once per race and emits `"leaving"(reason)` synchronously), `phase.cancelLeaving(reason, worldGen)
  -> bool` (round 2: a LEAVING whose servertravel never happened; same world generation and GameState only; the race
  phase is restored without `"phase"`/`"race_enter"` events; it emits `"leaving_cancelled"(phase)` for split), `phase.refreshSoon()` (`sched.nextFrame` → `phase.tick()`).
- **Detection (`phase.tick`, MAIN):**
  ```
  w = U.world(); if not U.ok(w) then return end
  if U.key(w) ~= St.worldKey or <LoadMap post-hook seen> then
     St.worldKey = U.key(w); St.worldGen = St.worldGen + 1; St.resetRace(); emit("world", w) end
  gs = w.GameState
  if not U.ok(gs)                                   -> TRANSIT (client before replication)
  elseif gs:IsA(FrontEndGameState)                  -> LAUNCHING if St.launch.pending and now-St.launch.atMs < limit, else FRONTEND
                                                       (limit = cfg.LaunchTimeoutMs, or cfg.LaunchAcceptedTimeoutMs while
                                                        St.launch.accepted and PrimaryFlow is still QuickRace; a timeout
                                                        also clears St.ui.returnToTab)
  elseif gs:IsA(RacingGameState):
     if gs.bIsRaceFinished == true                                        -> POSTRACE
     elseif gs.bIsRaceStarted == true -> U.csmActive("CSM_PostRace", true) == true and POSTRACE or RACING
                                         (find-only: never LoadAsset from the MAIN poll)
     elseif gs.Vehicles:GetArrayNum() > 0                                 -> PRERACE
     else                                                                 -> LOADING
  else                                              -> OTHER (campaign paddock, PvP flow, …)
  ```
  On change: `St.phase`, `St.phaseSinceMs`, then — when a race phase is entered from a non-race phase —
  `St.emit("race_enter", new, from)` (`from` = last phase other than TRANSIT), then `St.emit("phase", new, old)`. On the RACING edge:
  `St.race.started = true`, `St.race.startedAtMs = St.nowMs()`. Entering FRONTEND clears `St.launch.pending`; entering a
  race phase from a non-race phase clears `St.launch.pending` and `St.launch.accepted` (the launch produced its race;
  `St.race.launchedByUs` carries the rest).
  A phase never goes backwards inside one GameState except POSTRACE→LEAVING.
  Round 3: same UWorld address but a different non-zero GameState than the recorded one (not the transition map) =
  a new world (`onNewWorld(w, true)`), the backup for a missed or unavailable LoadMap post-hook.
- **Hooks (`init`):**
  - `RegisterLoadMapPreHook(function(Engine, World) … return nil end)`: if `phase.isRace()` →
    `phase.markLeaving("loadmap")`; always `St.launch.atMs` untouched. The FURL argument is not read (opaque [HERE]).
  - `RegisterLoadMapPostHook(function() phase.refreshSoon(); return nil end)`.
  - `RegisterInitGameStatePostHook(function(GM) phase.refreshSoon() end)` (param is the GameMode [API§4]).
  - `U.hook(C.FN.SeamlessTravelStarted, {pre = function() phase.markLeaving("seamless") end})` (native, flags 0x40401;
    fires only if dispatched through ProcessEvent: V-CORE-10).
  - `U.hook(C.FN.RequestReturnToMenus, {pre = function() phase.markLeaving("return") end})` (BlueprintCallable native).
- **Who reacts (listeners registered by those modules, not by `phase`):** see §5.
- **May call:** `U`, `St`, `sched`. **Game calls:** `World.GameState`, `IsA` with `FrontEndGameState`/`RacingGameState`,
  `RacingGameState.bIsRaceFinished/bIsRaceStarted/Vehicles` [PS§1.1], `U.csmActive`. **State:** `St.phase*`, `St.worldKey`,
  `St.gsKey`, `St.race.started*`.
- **VERIFY:** V-CORE-10 (seamless/return hooks fire), V-DIAG-01 (phase sequence matches §5 on a real race; LoadMap
  hooks fire or not for front end → race, which tells whether that travel is seamless).

#### G2 · `keys.lua`
- **Responsibility:** debug keybinds (§1.8) and the `couch` console command. Each bind is `keyq.bind(key, mods,
  label, fn)` (0.10.0); `fn` runs on the game thread from `keyq.drain`.
- **Public API:** `keys.init()`.
- **Calls (exact):** `RegisterKeyBind(Key.F5, cb)` → `menu_tab.selectOurTab()`; `Key.F6` → `join.keyboardJoin()`;
  `Key.F7` → `join.keyboardLeave()`; `Key.F8` → `split.toggle2PLayout()`; `Key.F9` → `diag.dump()`;
  `RegisterKeyBind(Key.F5, {ModifierKey.CONTROL}, cb)` → `launch.start()`; Ctrl+F6 → `takeover.forceAll()`;
  Ctrl+F7 → `net.toggleHosting()`; Ctrl+F8 → `net.toggleConnect()`; Ctrl+F9 → `diag.net()`;
  Ctrl+F11 → `RestartCurrentMod()` from the keyq body (game thread, so it goes through `queue_event`), registered only
  with `cfg.AllowHotReload` (0.10.0, default off: upstream #1445) [API§3, §12; UE4SSProgram.cpp:1885].
  `RegisterConsoleCommandGlobalHandler("couch", function(full, params, ar) … return true end)`: dispatch on
  `params[1]` to the same functions (`connect` sets `settings.JoinAddress`/`Port` first when an argument is given;
  `set` → `settings.set` (for `KeyboardIsP1`: `split.applyGamepadOffset()`, and `join.rebuild()` only while the join
  screen is open, `St.join.active` or `St.menu.visible == "lobby"`; otherwise the next `join.open` uses the new
  mapping); `gfx` → `settings.set("SplitGraphics", v)` then `gfx.applyForViews(St.race.localViews)` in a
  race); replies with `ar:Log(text)`.
- **May call:** `menu_tab`, `join`, `split`, `diag`, `launch`, `takeover`, `net`, `settings`, `gfx`, `lobby` (refresh).
- **VERIFY:** none beyond the called modules (keys are keyboard-only by design [API§3]).

#### G2 · `diag.lua`
- **Responsibility:** human-readable dumps that answer the runtime questions; debug-only hooks.
- **Public API:** `diag.init()`, `diag.dump()`, `diag.net()`, `diag.recipe()`, `diag.periodic()`.
- **`diag.dump()` prints:** phase, map (`U.levelName()`), net mode, `St.join.slots`, every local player
  (`index, ctrlId, pc, pc.Pawn, pc.PlayerState`), GameMapsSettings (`bUseSplitscreen`, layouts, offset), and in a race,
  for `i = 1..gs.Racers:GetArrayNum()`: `gs.Racers[i]` (`GetPlayerName()`), `bIsABot`, `RaceEventComponent.EventPosition /
  CurrentLapNumber / bHasFinishedEvent`, the pawn (`gs.Vehicles[i]`), `car.Controller`, `car:GetCurrentInputSource()`,
  `car:GetOriginalInputSource()`, `U.arrayToTable(car:GetInputSourceOverrides())`, `gs:FindRacerIndexByPlayer(ps)` per local
  PC, plus `St.takeovers` and `St.hud` [PS§8 #9]. The V-CORE-08 marker check reaches P1's `WBP_VehicleMarkerContainer`
  through `hud._membersOf(p1hud).markers` (a widget-tree member, not a Blueprint variable).
- **`diag.recipe()`:** `rs = U.giSubsystem("EventRecipeSubsystem")`; `rs.ActiveRecipe.RecipeState.Racers` (numeric loop):
  each `.Player` and `.VehicleType`; `rs:GetActiveRecipeEventStage()` → `InternalName`, `TrackDef`, `LapCount`,
  `RaceEventModeType` [RB§6c, PS§1.4]. Called by `launch` right after `LaunchCustomRace`.
- **`diag.net()`:** `U.netMode()`, `world.NetDriver` validity, `St.net`, remote humans from `roster`, `gi.PrimaryFlow`.
- **Debug hooks (`init`, only when `cfg.Debug`):** post-hooks logging `C.FN.ControllerAssigned` (car gets a controller),
  `C.FN.PossessedPawnChanged`, `C.FN.HumanSwitchedWithAI` [PS§3].
- **`diag.periodic()`:** nothing unless `cfg.DiagPeriodicMs > 0` (then `diag.dump()` at that interval).
- **0.7.0 sections:** `uxsplit` (`uxsplit.dump`: armed state, hooks with ids, counters, each HUD's containers, held
  messages; plus the guest lap offset) and `pause` (`pause.status()`: armed, hook, hookCalls, requests, noPause, pre /
  acquired, imcBoosted, hudInputsOff, ownCsm, pauser, Menu-layer Z seen / auto, dialog containers; and the pause cfg).
- **May call:** `roster`, `takeover` (read `St` only), `U`. **VERIFY:** V-DIAG-01, V-LCH-03 (the dump is the evidence),
  V-TKO-08.

#### G3 · `ui.lua`
- **Responsibility:** create the game's widgets for our pages, set their texts, detect clicks.
- **Public API:**
  - `ui.init()` (nothing to hook yet; the click hook needs the class loaded).
  - `ui.make(bpKey, pc) -> widget` = `U.WBL():Create(pc, U.class(C.BP[bpKey]), pc)` (WorldContextObject = owning PC)
    [UI§3, HERE `Create(Object, Class, Object)`].
  - `ui.header(pc, text)` → `SectionHeader` + `w:SetHeaderText(U.ftext(text))` (param `Text`, plain input [HERE bpprops]).
  - `ui.label(pc, text)` → `VerticalBtn` + `w:SetText(U.ftext(text))` (const ref → plain input [HERE]) +
    `w:BP_SetIsFocusable(false)`.
  - `ui.button(pc, id, text, fn) -> widget` → `CommonBtn`; `ui.setButtonText(w, text)`; `ui.registerButton(w, id, fn)`.
  - `ui.registerButton(w, id, fn) -> bool`: registers `St.ui.buttons[U.key(w)] = {id=id, fn=fn, widget=w}` for any
    `WBP_Common_Btn_C` (ours, or the builder's `Btn_Go` with `cfg.GoMode = "click"`); in `"poll"` mode also
    `w:SetIsSelectable(true)`, `w:SetIsToggleable(true)`; calls `ui.installClickHook()`.
  - `ui.setButtonText(w, text)`: `w.ButtonLabel = U.ftext(text)` then `w:UpdateText(U.ftext(text))` (BP fn, param
    `InText` plain [HERE]).
  - `ui.setLabelText(w, text)`: `w:SetText(U.ftext(text))`.
  - `ui.addRow(vbox, w, top, bottom) -> slot`: `slot = vbox:AddChildToVerticalBox(w)`; `slot:SetPadding({Left=0,
    Top=top or 4, Right=0, Bottom=bottom or 4})`; `slot:SetHorizontalAlignment(C.E.HAlign.Fill)` [UI§1.3].
  - `ui.setShown(w, on)`: `w:SetVisibility(on and C.E.Vis.Visible or C.E.Vis.Collapsed)` (labels use
    `SelfHitTestInvisible` when shown).
  - `ui.setEnabled(w, on)`: `w:BP_SetIsInteractionEnabled(on)` [HERE].
  - `ui.focus(w)`: `w:SetFocus()`.
  - `ui.installClickHook()`: once, `U.hook(C.FN.CommonBtnClicked, {post = ui.onClicked}, "ui")` (Blueprint body
    exists [HERE]).
  - `ui.onClicked(ctx)`: `b = ctx:get()`; `e = St.ui.buttons[U.key(b)]`; if `e` → `sched.now("click", e.fn, e.widget)`.
    Every other `WBP_Common_Btn_C` in the game passes through untouched.
  - `ui.pollClicks()` (FAST, `"poll"` mode): for each registered button `if w:GetSelected() then w:SetIsSelected(false,
    false); e.fn(w) end` [UI§3.4].
  - `ui.forgetAll()`: clears `St.ui.buttons`, `St.ui.labels` and the lobby's `St.ui.rows/texts/shown/enabled` (called
    when a menu instance dies or is replaced, and by `menu_tab.dropMenu` when the front end is left).
  - `ui.onClicked` dispatches only while `phase.isFrontEnd()`: UE4SS validity is address-based, so a stale entry whose
    address a race widget reuses would pass `U.same`.
- **May call:** `U`, `St`, `sched`. **Game calls:** `WidgetBlueprintLibrary:Create(Object, Class, Object)`,
  `SetHeaderText(Text)`, `SetText(Text)`, `UpdateText(Text)`, `ButtonLabel` (FText property),
  `BP_SetIsFocusable(bool)`, `SetIsSelectable(bool)`, `SetIsToggleable(bool)`, `GetSelected()`, `SetIsSelected(bool,
  bool)`, `AddChildToVerticalBox(Object)`, `SetPadding(FMargin)`, `SetHorizontalAlignment(Byte)`,
  `SetVisibility(Byte)`, `BP_SetIsInteractionEnabled(bool)`, `SetFocus()` [UI§1-3, HERE].
- **State:** `St.ui.buttons`. **VERIFY:** V-LOB-02, V-LOB-03, V-LOB-04, V-CORE-07.

#### G3 · `menu_tab.lua`
- **Responsibility:** find each `WBP_FE_MainMenu_C` instance, add the SPLIT SCREEN tab, create our two pages, route
  tab selection, switch pages, and re-select our tab after a race/reload.
- **Public API:** `menu_tab.init()`, `menu_tab.ensure()`, `menu_tab.install(menu)`, `menu_tab.addTab(menu)`,
  `menu_tab.onTabSelected(menu, tabIdString)`, `menu_tab.selectOurTab()`, `menu_tab.showPage(which)` (`"lobby"` |
  `"builder"`), `menu_tab.hidePages()`, `menu_tab.menu() -> widget|nil`, `menu_tab.isOurTabActive() -> bool`,
  `menu_tab.pollTab()` (MAIN, while `menu_tab.pollWanted()`), `menu_tab.pollWanted() -> bool` (round 3),
  `menu_tab.onSyncSelection(menu, id)`, `menu_tab.dropMenu(why)` (round 2), field `menu_tab.hookSilent` (bool).
- **Algorithm:**
  - `init`: `NotifyOnNewObject(C.BP.MainMenu, function(obj) … end)`: skip `obj:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject)`;
    store `St.menu.pendingNew = obj`; register (once) `U.hook(C.FN.MenuRegisterTabs, {post = onRegisterTabs})` and
    `U.hook(C.FN.MenuCustomEvent, {post = onCustomEvent})`; call `U.retryPendingHooks()` [MT§6 A, API§5] (V-CORE-09).
    Also queue both hooks with `U.hook` at init (they will register once the class loads).
  - `onRegisterTabs(ctx)`: `menu_tab.install(ctx:get())` (the four game tabs already exist here [MT§6 A]). Round 3:
    RegisterTabs again on the installed instance while our tab was open (the dev screen's own Back, a tab-list
    rebuild), no launch pending → `St.ui.returnToTab = true` first, so the return chain reselects our tab and
    `join.open` restores the dormant guests and the join poll.
  - `ensure()` (SLOW, front end): if `St.menu.widget` is not `U.ok` or has no tab: `m = FindFirstOf("WBP_FE_MainMenu_C")`
    (≤ 1/s, front end only) and `install(m)` if valid. Covers hot reload, a missed hook and any hook not firing (V-TAB-01).
    Round 3: with `St.menu.devscreen` (set by `builder.open` in `"devscreen"` mode, cleared by `builder.close`), phase
    FRONTEND and no launch pending, `U.csmActive(CSM_QuickRaceSetup, true) == false` (the game's own Back left the dev
    screen) → `selectOurTab()` after 200 ms.
  - `install(menu)`: idempotent per instance. If `U.key(menu) ~= St.menu.key` (or the menu's world differs from the
    installed menu's, address reuse): if the previous, still-current instance had our tab open (CSM re-creating the
    menu inside one front-end world, V-TAB-11) → `St.ui.returnToTab = true` with `cfg.ReturnToSplitTab` (the return
    chain reopens the tab, `join.open` adopts the live guests), else `St.emit("tab", false)`; then
    `St.resetMenu()`, `ui.forgetAll()`, `St.menu.widget = menu`, `St.menu.key =
    U.key(menu)`, `St.menu.worldKey`, module flag `tabOpen = false`, cancel a pending return chain, remove stale pages
    (`WS_ScreenContent` children at index ≥ 5 that are `SettingList`/`Builder` instances of a previous mod instance,
    `RemoveChildAt(i)`; hot reload), `St.emit("menu", menu)`. Then, in this order,
    `lobby.build(menu)` (creates `St.menu.lobby` and adds it to `WS_ScreenContent`), `addTab(menu)`,
    `U.mod("builder").ensure(menu)`; if `St.ui.returnToTab` and `cfg.ReturnToSplitTab` → `St.ui.returnToTab = false`
    and a return chain: after 200 ms (then every 250 ms, ≤ 20 tries) `selectOurTab()` once the phase is FRONTEND (round 3:
    not LAUNCHING; a launch pending when an attempt runs ends the chain and sets `St.ui.returnToTab` again, and
    `install` during a launch still live in the front end (phase LAUNCHING, or pending in FRONTEND/LAUNCHING) starts no
    chain and keeps the flag for the post-race menu) and an installed menu
    is current (whatever instance is installed by then); a token cancels it when the user picks
    another tab; giving up closes the kept guests (`join.close`, unless pending/frozen).
  - Listener `"world"`: when the installed menu is stale (its world is gone) → `dropMenu` (FRONTEND→FRONTEND travel
    has no phase event). Round 4: if our tab was open (`tabOpen` or `St.menu.visible`), the old phase is FRONTEND and
    no launch is pending (a reload the mod may not have started): `cfg.ReturnToSplitTab` → `St.ui.returnToTab = true`
    (the new menu returns to our tab, `join.resync` keeps the set); else `"tab"(false)` first (`lobby.onHidden` closes
    the join session), so guests never outlive the lobby on the game's own pane (§1.1).
  - Listener `"phase"` (round 2): any race phase, LEAVING or OTHER → `dropMenu`: `tabOpen = false`, cancel the return
    chain, `St.resetMenu()` (keeps `St.ui.returnToTab`), `ui.forgetAll()`; the next front-end menu is always installed
    as a new instance. OTHER entered from FRONTEND/LAUNCHING (last phase other than TRANSIT) first closes any local
    guest (`closeStrayGuests`; no tab event leads there, and kept rematch guests have `St.join.active` false). LEAVING / OTHER
    keep an installed menu that belongs to the current world (`not isStaleMenu`): phase.tick can mark them late, on
    its first look at the new front-end world, after that world's RegisterTabs installed its menu and started the
    return chain.
  - `selectOurTab`'s 300 ms fallback (no CustomEvent after an accepted `SelectTabByID`) shows the lobby; it sets
    `menu_tab.hookSilent` only when an event was expected (our tab was not already active and `IgnoreTabSelection`
    was not true): main then runs `pollTab` whatever `cfg.TabDetectMode` says (V-TAB-10). `onCustomEvent` records
    our id's event time before the `"poll"`-mode return (not for sync events).
  - `addTab(menu)`: `tl = menu.WBP_Tab_List`; `id = U.fname(C.TAB_ID)`; if `U.ok(tl:GetTabButtonBaseByID(id))` → done.
    `btnCls = menu["Button Widget Type"]` (V-TAB-02); if not `U.ok(btnCls)` → `U.class(C.BP.TabBtn)`.
    `ok = tl:RegisterTab(id, btnCls, St.menu.lobby, tl:GetTabCount())` (`ContentWidget` = the lobby page; nil is also
    accepted by CommonUI [MT§3.4]). `btn = tl:GetTabButtonBaseByID(id)`; `btn:SetText(U.ftext(C.TAB_LABEL))`
    (V-TAB-03). `St.menu.tabAdded = ok` [MT§6 B, HERE signatures].
  - `onCustomEvent(ctx, tabIdParam)`: `menu = ctx:get()`; `id = U.str(tabIdParam:get())`; ignored while the menu has
    fewer than 4 tabs (CommonUI auto-selects the first tab inside the first `RegisterTab`, and the menu binds
    `CustomEvent` before `RegisterTabs`: installing there would give our tab TabIndex 1) (V-TAB-09); ignored with
    `cfg.TabDetectMode = "poll"`; if `menu.IgnoreTabSelection == true` → `onSyncSelection(menu, id)` (switcher→tab sync
    in progress [MT§3.3]); else install a menu we never saw, then `menu_tab.onTabSelected(menu, id)` (V-TAB-04).
  - `onTabSelected(menu, id)`: if `id == C.TAB_ID` → `menu_tab.showPage("lobby")`, `tabOpen = true`,
    `St.emit("tab", true)`; else cancel a pending return chain; if `St.menu.visible` or `tabOpen` → `hidePages()`,
    `St.emit("tab", false)`, and when `cfg.RestoreGamePaneOnTabLeave` (or our page is still the switcher's active widget)
    and `C.GAME_TABS[id]` → `menu.WS_ScreenContent:SetActiveWidgetIndex(C.GAME_TABS[id])` (V-TAB-05); then for a game tab
    id, `join.close()` whenever a local guest exists, no launch is pending and `join.isFrozen()` is false (§1.1
    invariant, independent of `tabOpen`). `St.menu.prevTabId = id`.
  - `onSyncSelection(menu, id)`: `St.menu.prevTabId = id`; with our page open: game id → leave (no switcher write);
    with nothing of ours open: game id and no pending return chain → close stray guests as above (V-TAB-08).
    Round 4: our id from the sync (switcher index 4 = `WBP_FE_Campaign` [MT§6 C]) with nothing of ours open (or after
    leaving our page) → `cfg.OurTabSyncFix = "clear"`: `sched.after(0)` → our tab button's
    `UCommonButtonBase:ClearSelection()`, `St.menu.ourSelCleared = true`, so a real click selects it again and
    broadcasts (V-TAB-13); `"off"`: nothing. `pollTab` recognises that click by `btn:GetSelected()` while
    `ourSelCleared`. `menu_tab.returnPending() -> bool` (round 4): the return chain is scheduled; main's OnUnload
    persists `ui.returnToTab = St.ui.returnToTab or menu_tab.returnPending()`.
  - `pollTab()` (V-TAB-10): `id = U.str(tl:GetActiveTab())`; first poll per menu = baseline; acts only when `id` changed
    since the previous poll and differs from `St.menu.prevTabId`; our id while the switcher shows index 4
    (`WBP_FE_Campaign`, the sync highlights our TabIndex 4 [MT§6 C]) is ignored; else `onTabSelected(menu, id)`.
  - `showPage(which)`: `w = (which == "lobby") and St.menu.lobby or St.menu.builder`; `sw = menu.WS_ScreenContent`;
    if `sw:GetChildIndex(w) < 0` → `sw:AddChild(w)`; `sw:SetActiveWidget(w)`; `w:ActivateWidget()`; deactivate the other
    page if `IsActivated()`; focus: lobby → `ui.focus(St.ui.rows.race)`, builder → `w:RequestRefreshFocus()` (V-TAB-07).
    With `cfg.DeactivateGamePaneOnShow` (default false, V-TAB-12): before `SetActiveWidget`, the switcher's active
    widget, if a game pane (index < 5) and `IsActivated()`, gets `DeactivateWidget()`; the leave path then calls
    `ActivateWidget()` on the active game pane if it is not activated.
    `St.menu.visible = which`. Going from the builder page to the lobby calls `builder.onLeavePage()` first.
  - `hidePages()`: `builder.onLeavePage()` when the builder was visible; `DeactivateWidget()` on both pages when
    `IsActivated()`; `St.menu.visible = nil`. The game's CSM selects its own pane [MT§4].
  - `selectOurTab()`: `menu.WBP_Tab_List:SelectTabByID(U.fname(C.TAB_ID), false)`; if it returns false or no
    `CustomEvent` follows within 300 ms, call `onTabSelected(menu, C.TAB_ID)` directly (V-TAB-06).
  - `isOurTabActive()`: `U.str(menu.WBP_Tab_List:GetActiveTab()) == C.TAB_ID`.
- **May call:** `ui`, `lobby` (`build`, `onShown`, `onHidden` via the `"tab"` event), `builder.ensure`, `U`, `St`, `sched`.
- **Game calls:** `PanelWidget:GetChildrenCount()/GetChildAt(Int)/RemoveChildAt(Int) -> Bool` [HERE reflect-func-all],
  `NotifyOnNewObject`, `HasAnyFlags(RF_ClassDefaultObject)`, `FindFirstOf("WBP_FE_MainMenu_C")`,
  `menu.WBP_Tab_List`, `menu["Button Widget Type"]`, `menu.WS_ScreenContent`, `menu.IgnoreTabSelection`,
  `CommonTabListWidgetBase:GetTabButtonBaseByID(Name)`, `RegisterTab(Name, Class, Object, Int) -> bool`,
  `GetTabCount()`, `SelectTabByID(Name, bool)`, `GetActiveTab() -> Name`, `WBP_Tab_Btn_C:SetText(const FText&)`,
  `PanelWidget:GetChildIndex(Object)`, `AddChild(Object)`, `WidgetSwitcher:SetActiveWidget(Object)`,
  `SetActiveWidgetIndex(Int)`, `CommonActivatableWidget:ActivateWidget()/DeactivateWidget()/IsActivated()/
  RequestRefreshFocus()` [MT§3.4, UI§1.2, HERE].
- **State:** `St.menu`. **VERIFY:** V-CORE-09, V-TAB-01..10.

#### G3 · `lobby.lua`
- **Responsibility:** build the Lobby page (§1.2), keep its labels current, run the row actions.
- **Public API:** `lobby.build(menu)`, `lobby.tick()`, `lobby.refresh()`, `lobby.setStatus(text)`, `lobby.onShown()`,
  `lobby.onHidden()`, and the row actions `lobby.onRace()`, `lobby.onLayout()`, `lobby.onGfx()`, `lobby.onTakedown()`,
  `lobby.onTags()`, `lobby.onKbP1()`, `lobby.onNet()`, `lobby.onNetAction()`, `lobby.onStart()`.
- **`build(menu)`** (idempotent per menu instance): `pc = menu:GetOwningPlayer()`; `page = ui.make("SettingList", pc)`;
  `root = page.WidgetTree.RootWidget` (V-LOB-01; `cfg.LobbyRootMode = "own"` replaces it as in §7); `root:ClearChildren()`; rows in §1.2 order through `ui.header`,
  `ui.label`, `ui.button` + `ui.addRow`; `St.ui.rows[id] = widget` for every row id; `page:SetDesiredFocusWidget(rows.race)`;
  `menu.WS_ScreenContent:AddChild(page)` (not activated); `St.menu.lobby = page`; `U.mod("builder").restoreFromSettings()`
  once per session; `St.ui.dirty = true`.
- **Listeners (registered in `build`, once per session):** `"tab"` → `onShown`/`onHidden`; `"status"` →
  `setStatus`; `"players"`, `"net"`, `"race_chosen"`, `"settings"`, `"phase"` → `St.ui.dirty = true`.
- **`onShown()`**: `join.open()` unless `join.isFrozen()`; `St.ui.dirty = true`. **`onHidden()`**: `join.close()` unless a
  launch is pending or `join.isFrozen()` (a connected client's set changes only through DISCONNECT, §2.3).
  Listener `"world"` → `St.ui.statusText = ""` (a status belongs to its world; cleared before the FRONTEND listeners
  write the new one, so "LOADING…" never greets the post-race lobby).
- **`tick()`** (MAIN, front end): `if St.ui.dirty and St.menu.visible then lobby.refresh(); St.ui.dirty = false end`.
- **`refresh()`** label rules:
  - `slot1..4` from `join.slotViews()` (array of 4 strings); `remote` shown when the NetMode setting is not `offline` and
    `net.statusText()` is non-empty (its texts cover the standalone states too: CONNECTING, RECONNECTING (TRY n/m),
    NOT HOSTING, STARTING HOST, STILL LISTENING, and the 30 s failure line that survives the `world` status clear); `race` = `"CHOOSE RACE >"` or `"RACE: " .. St.race.choice.label .. " >"`;
    `layout/gfx/takedown/tags/kbp1/net` from `settings.get` (texts of §1.2); `netact` hidden for `offline`, label from
    `net.netactLabel()`; `start`: offline → `START RACE` enabled iff a valid choice; host → enabled iff
    `net.isListening()` and a valid choice, else `START HOSTING FIRST` disabled; client → `WAITING FOR HOST` disabled;
    any pending launch → `LAUNCHING…` disabled; `status` = `St.ui.statusText`.
- **Row actions:** `onRace` → `builder.open()`; `onLayout` → `settings.cycle("Layout2P", {"top-bottom","side-by-side"})`,
  `split.applyLayoutSettings()`; `onGfx` → `settings.cycle("SplitGraphics", {"auto","performance","quality","off"})`;
  `onTakedown` → `settings.toggle("TakedownCams")`; `onTags` → `settings.toggle("NameTags")`; `onKbP1` → refused with
  status `DISCONNECT TO CHANGE PLAYERS` while `join.isFrozen()`, connected client or connecting (same guard in keys'
  `couch set KeyboardIsP1`), with `REMOVE GUESTS FIRST` while `#join.joinedList() > 0`, else `settings.toggle("KeyboardIsP1")`,
  `split.applyGamepadOffset()`, `join.rebuild()`; `onNet` → refused while `St.net.hosting` or connected, else
  `settings.cycle("NetMode", {"offline","host","join"})`; `onNetAction` → host: `net.toggleHosting()`, join:
  `net.toggleConnect()`; `onStart` → `launch.start()`. Every action ends with `St.ui.dirty = true`.
- **May call:** `ui`, `join`, `builder`, `split`, `net`, `launch`, `settings`, `U`, `St`.
- **Game calls:** `UserWidget:GetOwningPlayer()`, `page.WidgetTree.RootWidget` (properties [UI§1.3]),
  `PanelWidget:ClearChildren()`, `UserWidget:SetDesiredFocusWidget(Object) -> bool`, `PanelWidget:AddChild(Object)`
  [HERE], plus everything in `ui`.
- **State:** `St.ui.rows`, `St.ui.statusText`, `St.ui.dirty`. **VERIFY:** V-LOB-01, V-LOB-02, V-LOB-04.

#### G3 · `theme.lua`, `cards2.lua`, `backprompt.lua` (added 2026-10-10, 0.12.0)
Contracts in Revision 0.12.0 (§0): item 3 (theme), item 4 (cards2), item 5 (backprompt and its hook rule); the v2 pages
of lobby.lua, setup.lua and cmap.lua: items 6-8; the `UiStyle` switch: item 1. Hard rules 12 (the launch hold) and 13
(raw hooks) apply to all three.

#### G4 · `join.lua`
- **Responsibility:** dormant guests in the front end, pad edge polling, joined set, device events, guest bookkeeping
  across travel.
- **Public API:** `join.init()`, `join.open()`, `join.close()`, `join.commit()`, `join.rebuild()`, `join.resync()`,
  `join.poll()`, `join.keyboardJoin()`, `join.keyboardLeave()`, `join.joinedList() -> {{ctrlId, pnum, pc}, …}`
  (ascending ctrlId; `pnum = 1 + rank`), `join.pnumForPC(pc) -> int|nil` (P1 → 1), `join.localHumanCount() -> int`,
  `join.isFrozen() -> bool`, `join.slotViews() -> {string×4}`, `join.raceTick()` (MAIN, race, server),
  `join.pollDevices()` (SLOW), `join.onDeviceState(state, uid, dev, source)`, `join.persistShared(put)` /
  `join.restoreShared(get)` (hot reload: joined ControllerIds with flag letters L = leaving, D = pad disconnected,
  A = our Disconnect override is on its car; `keep`, `frozen`).
- **Behaviour:** exactly §1.3. Details:
  - `open()`: refuse (status) if `U.netMode() == "client"` (`St.join.frozen = true`), not `phase.isFrontEnd()`, or a
    launch is pending / phase LAUNCHING (`launch.start` already committed the set; new dormant guests would travel).
    `St.join.active = true`; `GS:SetForceDisableSplitscreen(world, true)`; for `id = 1 .. cfg.MaxLocalPlayers - 1`:
    `pc = GS:GetPlayerControllerFromID(world, id)`; if not ok → `pc = GS:CreatePlayer(world, id, true)` and
    `slot.createdMs = St.nowMs()`; keep an existing slot's `joined` flag (guests kept from the previous race).
    `cfg.JoinFocusTrick`: `"userfocus"` → `St.menu.lobby:SetUserFocus(pc)` per guest; `"viewport"` →
    `U.WBL():SetFocusToGameViewport()` then `ui.focus(St.ui.rows.race)` (V-JOIN-03). Emit `"players"`.
  - `poll()` (FAST): per slot with a valid PC: `a = pc:IsInputKeyDown(KEY_A) or (cfg.JoinWithStart and
    pc:IsInputKeyDown(KEY_START))` (Start only with `cfg.JoinButtons = "start"`, and always for ControllerId 1 when
    `KeyboardIsP1`: that pad is still Slate user 0, so its A is consumed by P1's focused row (V-JOIN-09); the lobby
    card then says `press START`), `b = pc:IsInputKeyDown(KEY_B)` (round 4: for that same KeyboardIsP1 ControllerId 1
    slot, B is P1's CommonUI Back, so `b` = Start held `cfg.LeaveHoldMs` (1000) from a press made while joined; the
    card says `HOLD START = leave`); rising edges as §1.3; store `prevA/prevB`; on a
    change emit `"players"` and `"status"` (`P2 JOINED`, `P2 LEFT`). Keys are module-level tables built once with
    `U.fname` (`{KeyName = FName(...)}` [API§3]).
  - `close()`: `St.join.active = false`; remove every guest PC with `GS:RemovePlayer(pc, true)` from the highest id
    down; reset slots; force-disable stays on in the front end. Emit `"players"`.
  - `commit()`: remove only non-joined guests (same call); `St.join.active = false`. Emit `"players"`.
  - `rebuild()`: `close()` then `open()` (only allowed with no joined slot, PC replicated or not, and not frozen).
  - `resync()` (listener: phase → FRONTEND): `wasFrozen = St.join.frozen` (read first), `St.join.frozen =
    (U.netMode() == "client") or St.net.wantConnected` (frozen also while an auto-rejoin is wanted, so the lobby's
    open/close and `closeStrayGuests` cannot add dormant guests or drop the guests the rejoin carries; net un-freezes
    once `wantConnected` turns false); for each slot: if `leaving` → `RemovePlayer(pc, true)`, `joined = false`; if `joined` but
    `GetPlayerControllerFromID(world, id)` is invalid → `joined = false` (a client keeps it while the LocalPlayer exists,
    V-JOIN-08); keep the set when frozen, `wasFrozen`, `St.net.wantConnected` (an unplanned drop must rejoin with the
    same guests), or `cfg.ReturnToSplitTab` with `St.ui.returnToTab`/`St.join.keep`/`St.join.active`; else `close()`.
  - `"race_enter"(new, from)` listener: from FRONTEND/LAUNCHING/OTHER (round 3: any non-race `from` except BOOT and
    LEAVING), not `St.race.launchedByUs`, not a client / not
    `wantConnected`, guests exist → in LOADING `close()` (a race the mod did not launch never gets split views, guest
    HUDs or takeovers). First seen later (PRERACE+, server): a guest that owns a vehicle or a racer entry
    (`FindRacerIndexByPlayer >= 0`) is NOT removed (its PlayerState is the racer entry [PS§7]): its car gets the
    Disconnect override (now, or from `raceTick` once it exists: `slot.abandonPending`), `slot.leaving = true`
    (removed by `resync`), and `St.race.singleView = true` (one view, no guest HUDs); other guests are removed.
  - `raceTick()` (MAIN, race, server): for every joined slot with `disconnected` and no override yet → the pad-loss
    override as soon as its car exists (a guest launched without its pad, or that lost it during LOADING).
    Round 4: per-car flags carry the race world they were applied in (`slot.carGen`, adopted on the first raceTick of
    that world; cleared by `resync`). A new race world reached without a front end (relisten, servertravel restart,
    game-native restart) resets `aiOverride`; `leaving`/`abandoned` slots get `abandonPending` (their new car goes to
    the AI), and a still-disconnected pad gets the Disconnect override again.
  - `pollDevices()` (`cfg.DeviceDetectMode` `"both"`/`"poll"`; with `"hook"` an edge-only watchdog: no baseline
    report, edges applied only without a device hook call in the last 3 s; V-JOIN-10): `lib = U.cdo("InputDeviceLibrary")`;
    `lib:GetAllConnectedInputDevices(out)` (array out-param filled in place); per device
    `lib:GetUserForInputDevice({InternalId = id}).InternalId`; the set of users is diffed against the previous poll
    (first poll: baseline, joined guests without a device reported once); every edge goes through `onDeviceState`,
    which ignores a state the slot already has (the hook and the poll may both report it). The default input device
    (`lib:GetDefaultInputDevice()`, keyboard/mouse of user 0) is left out, so with `KeyboardIsP1` the loss of pad 0
    (ControllerId 1, also user 0) is seen.
  - `keyboardJoin()`: front end → if not `St.join.active` then `menu_tab.selectOurTab()` else join the lowest
    non-joined slot; race → only with `cfg.AllowMidRaceJoin` and `U.isServer()`: `pc = GS:CreatePlayer(world, nextId,
    true)`, then `takeover.takeOver(pc, takeover.pickCar(U.gs()))`.
  - `keyboardLeave()`: front end → un-join the highest joined slot (refused with `DISCONNECT TO CHANGE PLAYERS` when
    frozen: the split-join guest stays on the host); race → `takeover.leaveMidRace(pc)` for that guest
    and mark `slot.leaving = true`. `keyboardJoin()` is refused while a launch is pending.
  - Device hook (`init`): `U.hook(C.FN.DeviceChanged, {post = onDevice})`; `onDevice(ctx, NewConnectionState,
    PlatformUserId, InputDeviceId)`: `st = NewConnectionState:get()`; `uid = PlatformUserId:get().InternalId`;
    `ctrlId = uid + (settings.get("KeyboardIsP1") and 1 or 0)` (V-JOIN-05). Lobby: set `slot.disconnected`. Race,
    server, `cfg.AIOnPadDisconnect`: `car = GS:GetPlayerControllerFromID(world, ctrlId).Pawn`; if vehicle →
    `car:StartInputSourceOverride_OnServer(C.E.Override.Disconnect)` on 2, `StopInputSourceOverride_OnServer(…)` on 3.
- **May call:** `menu_tab.selectOurTab`, `takeover.takeOver/pickCar/leaveMidRace`, `ui.focus`, `phase`, `settings`, `U`, `St`.
- **Game calls:** `GameplayStatics:SetForceDisableSplitscreen(World, bool)`, `GetPlayerControllerFromID(World, int)`,
  `CreatePlayer(World, int, bool) -> PC`, `RemovePlayer(PC, bool)`, `PlayerController:IsInputKeyDown(FKey) -> bool`,
  `Widget:SetUserFocus(PC)`, `WidgetBlueprintLibrary:SetFocusToGameViewport()`, `VehiclePawn:Start/StopInputSourceOverride_OnServer(enum)`
  [UI§4, PS§2, HERE].
- **Game calls (added):** `InputDeviceLibrary:GetAllConnectedInputDevices(out Array<FInputDeviceId>) -> Int`,
  `GetUserForInputDevice(FInputDeviceId) -> FPlatformUserId` [HERE reflect-func-all, UI§4].
- **State:** `St.join`. **VERIFY:** V-JOIN-01..10.

#### G4 · `split.lua`
- **Responsibility:** engine split-screen settings, single-view control, 2P layout switch.
- **Public API:** `split.init()`, `split.applyLayoutSettings()`, `split.applyGamepadOffset()`, `split.setSingleView(on)`,
  `split.enterRace()`, `split.enterFrontEnd()`, `split.relayout()`, `split.toggle2PLayout()`, `split.isSingleView() -> bool`.
- **Behaviour:** `applyLayoutSettings`: `g = U.GMS()`; `g.bUseSplitscreen = true`; `g.TwoPlayerSplitscreenLayout =
  (settings.get("Layout2P") == "side-by-side") and C.E.TwoP.Vertical or C.E.TwoP.Horizontal`;
  `g.ThreePlayerSplitscreenLayout = C.E.ThreeP.FavorTop`; `g.FourPlayerSplitscreenLayout = C.E.FourP.Grid`; in a race
  then `relayout()` (V-SPL-02). `applyGamepadOffset`: `g.bOffsetPlayerGamepadIds = settings.get("KeyboardIsP1")`
  (V-SPL-03). `setSingleView(on)`: `GS:SetForceDisableSplitscreen(world, on)`. `enterRace()` (listener: phase →
  LOADING): `setSingleView(false)`; `St.race.localViews = #U.localPlayers()` (V-SPL-01). `enterFrontEnd()` (listener:
  phase → FRONTEND): `setSingleView(true)`. Listener `"leaving"`: `setSingleView(true)` (the flag is on the viewport
  client, so the transition/front-end worlds draw one view); `"leaving_cancelled"`: `setSingleView(St.race.singleView)`.
  `relayout()`: `setSingleView(true)` then `setSingleView(false)`.
  `toggle2PLayout()`: `settings.cycle("Layout2P", …)`, `applyLayoutSettings()`, `St.emit("status", "2P LAYOUT: …")`.
  `isSingleView()`: `GS:IsSplitscreenForceDisabled(world)`.
- **May call:** `settings`, `phase`, `U`, `St`. **Game calls:** `GameMapsSettings` CDO properties (Bool, Byte, Byte,
  Enum, Bool [HERE]), `SetForceDisableSplitscreen(World, bool)`, `IsSplitscreenForceDisabled(World) -> bool` [API§9].
- **State:** none beyond `St.race.localViews`. **VERIFY:** V-SPL-01..03.

#### G4 · `builder.lua`
- **Responsibility:** embed the game's race-builder panel, capture the chosen race by value, persist and restore it.
- **Choice table (exact shape, stored in `St.race.choice`):**
  ```lua
  { archetype = UVehicleArchetype, gameMode = UGameModeVariantDef, planet = UPlanetDef|nil, track = UTrackDef,
    build = UVehicleBuildDef|nil, debugBuild = UDebugVehicleBuildDef|nil,
    condition = "TrackCondition.Sunset" | "",          -- TagName string ("" when None)
    label = "JAKKU / THE WAR FIELDS / RACE / LANDSPEEDER / SUNSET" }
  ```
- **Public API:** `builder.init()`, `builder.ensure(menu)`, `builder.open()`, `builder.close()`, `builder.onGo(ctx)`,
  `builder.handleGo(widget)`, `builder.onLeavePage()`,
  `builder.capture(widget) -> choice|nil`, `builder.isValid(choice) -> bool`, `builder.describe(choice) -> string`,
  `builder.persist(choice)`, `builder.restoreFromSettings() -> bool`.
- **Behaviour:**
  - `init`: `U.hook(C.FN.BuilderGo, {post = builder.onGo}, "builder")` (queued until the class is loaded; it is
    hard-imported by the front-end CSM chain so usually resident [MT§5, RB§1.1]).
  - `ensure(menu)`: once per menu instance: `cls = U.class(C.BP.Builder)` (LoadAsset fallback inside `U.class`);
    `owner = U.ok(pc) and pc or nil; ctx = owner or U.world()` (round 4: like `ui.make`; the UIManager creates the
    menu without an owner [UI§1.4]); `bw = U.WBL():Create(ctx, cls, owner)`; `menu.WS_ScreenContent:AddChild(bw)`; `St.menu.builder = bw`;
    `U.retryPendingHooks()`; if `cfg.BuilderBackButton`: `root = bw.WidgetTree.RootWidget`; if `U.isA(root,
    C.CLASS.GridPanel)` → `back = ui.button(pc, "builderBack", "< BACK TO LOBBY", builder.close)`;
    `root:AddChildToGrid(back, cfg.BuilderBackRow, cfg.BuilderBackCol)` (V-BLD-03) (V-BLD-01).
  - `open()` → `menu_tab.showPage("builder")` (`cfg.BuilderMode = "devscreen"`: the CSM call of §7 instead; the Go
    hook then accepts the dev screen's `Custom_EventSetup` instance). `close()` → `menu_tab.showPage("lobby")`
    (devscreen mode: `FrontEndGameMode:ReturnToMainMenu()` then `menu_tab.selectOurTab()`).
  - `onGo(ctx)` (post-hook; ignored with `cfg.GoMode = "click"` in embedded mode) → `handleGo(ctx:get())`.
    `handleGo(p)`: return unless `U.same(p, St.menu.builder)` (the dev screen's own instance is
    ignored); `c = builder.capture(p)`; if not `builder.isValid(c)` → status `PICK VEHICLE, MODE, TRACK AND BUILD`;
    else `St.race.choice = c`, `builder.persist(c)`, `St.emit("race_chosen", c)`, `builder.close()`, and if
    `cfg.LaunchOnGo` → `launch.start()` (V-BLD-02).
  - `cfg.GoMode = "click"` (V-BLD-06): `ensure` registers `bw.Btn_Go` (a `WBP_Common_Btn_C` [exports]) with
    `ui.registerButton(go, "builderGo", function() builder.handleGo(St.menu.builder) end)`, so the Go reaches us through
    the CommonBtn click hook or the `ClickMode` poll instead of the BndEvt hook.
  - `onLeavePage()` (called by `menu_tab` when the builder page is left): fallback for a Go never detected
    (V-CORE-07): as long as no Go reached `handleGo` in this session, a complete pick on the widget (`capture`, the
    `Chosen*` survive) that differs from `St.race.choice` is adopted and persisted. Once a Go was seen, leaving the
    page is a cancel.
  - `capture(p)`: read `p.ChosenArchetype`, `p.ChosenGameMode`, `p.ChosenPlanet`, `p.ChosenTrack`, `p.ChosenBuild`,
    `p.ChosenDebugBuild` (ObjectProperties [HERE bpprops]); `condition = U.str(p.ChosenCondition.TagName)`, `"None"` →
    `""` (struct property field read [API§8]); `label = builder.describe(c)`. Runs in the Go handler or `onLeavePage`.
    Validation: the condition must be offered by the track; the track must be in
    `GfnGameInstance.Events:GetQuickplayTracksForVehicleAndPlanet(archetype, planet)` when that list is non-empty.
    That UFunction RETURNS an array: UE4SS gives a Lua table of RemoteUnrealParams (get/set/type only, no IsValid
    [HERE LuaUObject.cpp push_arrayproperty / RemoteUnrealParam::setup_member_functions]), so it is unwrapped with
    `U.arrayToTable` before `U.same` (the list size is logged, V-BLD-02).
  - `isValid(c)`: `U.ok(archetype) and U.ok(gameMode) and U.ok(track) and (U.ok(build) or U.ok(debugBuild))` (the BP's
    own Go test [RB§1.3]).
  - `describe(c)`: `U.str(planet.PlayerFacingName)`, `U.str(track.PlayerFacingName)`, `U.str(gameMode.PlayerFacingName)`,
    `U.str(archetype.PlayerFacingName)` (FText properties [RB§5.2]), condition suffix = the part after
    `"TrackCondition."`; each piece in `U.try` with fallback `obj:GetFName():ToString()`; upper-cased, joined with `" / "`.
  - `persist(c)`: `settings.set("LastRaceArchetype", U.pathOf(c.archetype))` and likewise `GameMode`, `Planet`, `Track`,
    `Build`; `LastRaceCondition = c.condition`; `LastRaceDebugBuild = ""` (debug builds are runtime objects).
  - `restoreFromSettings()` (game thread): round 4: a path not matching `^/%w[^%s]*%.[^%s]+$` (hand-edited
    settings.txt) is warned about and cleared, never passed to StaticFindObject/LoadAsset; `U.obj(path)` for each non-empty path; each object must `IsA` its
    `LaunchCustomRace` class (`C.CLASS.VehicleArchetype/GameModeVariantDef/PlanetDef/TrackDef/VehicleBuildDef`; a class
    that does not resolve is not checked), else that field is dropped (logged); builds a choice when `isValid`; else
    leaves `St.race.choice = nil` and clears nothing (V-BLD-04).
- **May call:** `menu_tab.showPage`, `ui.button`, `launch.start`, `settings`, `U`, `St`.
- **Game calls:** `WidgetBlueprintLibrary:Create`, `PanelWidget:AddChild`, `WidgetTree.RootWidget`,
  `GridPanel:AddChildToGrid(Object, Int, Int)` [HERE], the `Chosen*` BP variables and `ChosenCondition.TagName`,
  `PlayerFacingName` FText properties of `UVehicleArchetype`, `UGameModeVariantDef`, `UTrackDef`, `UPlanetDef` [RB§5.2],
  `UObject:GetFullName()`, `StaticFindObject`/`LoadAsset` via `U.obj`.
- **State:** `St.menu.builder`, `St.race.choice`. **VERIFY:** V-BLD-01..06.

#### G4 · `launch.lua`
- **Responsibility:** start the chosen race with every local and remote human already present.
- **Public API:** `launch.init()` (phase → FRONTEND listener: `restoreGridPatch()` and `St.race.launchedByUs = false`),
  `launch.persistShared(put)` / `launch.restoreShared(get)` (hot reload: `pending`, `accepted`, `atMs`),
  `launch.canStart() -> bool, reasonText`, `launch.start() -> bool`, `launch.gridInfo(choice) -> slots|nil,
  humans`, `launch.conditionArg(choice) -> table`, `launch.restoreGridPatch()`, `launch.prepareExternal(choice)`.
- **`start()` (exact order):**
  1. `ok, why = launch.canStart()`: phase FRONTEND; `not St.launch.pending`; `builder.isValid(St.race.choice)` (else try
     `builder.restoreFromSettings()` once); `gm = U.gm()` valid and `U.isA(gm, "FrontEndGameMode")` (BP subclass
     `BP_FrontEndGameMode_C` [MT§8 #4]); `settings.NetMode`: `"join"` → refuse; `"host"` → require `net.isListening()`.
     On refusal: `St.emit("status", why)`, return false.
  2. `slots, humans = launch.gridInfo(choice)`: `entries = choice.gameMode.GridMakeup.Entries`; `slots = Σ
     entries[i].NumEntrants` (numeric loop; `nil` when 0 entries, e.g. `GMV_FullGridRace`); `humans =
     join.localHumanCount() + #roster.remoteHumans()` [RB§7.1, PS§1.4]. If `slots and humans > slots` → status warning
     `GRID HAS <slots> PLACES FOR <humans> PLAYERS` and, only with `cfg.GrowGridInMemory`, raise the `PlayerChoice` entry
     (`EntryType == 4`, else the last entry) by the deficit, remembering `St.launch.gridPatch = {entry=index, old=n,
     gmv=choice.gameMode}` (V-LCH-04).
  3. `net.beforeLaunch()` whenever `U.netMode() ~= "client"` (round 3: the only reset of `expectedRemote`).
     `prepareExternal` (dev screen) does the same and warns `HOST NOT LISTENING: RACE IS LOCAL` when
     `NetMode == "host"` but the world is not listening.
  4. `join.commit()` (dormant guests must not become racers); a joined guest marked `disconnected` gets the status
     `P<n> HAS NO CONTROLLER: AI DRIVES ITS CAR` (not a refusal; `join.raceTick` applies the override).
  5. If `cfg.SelectVehicleForGuests`: for each joined guest `pc.PlayerState.RaceEventComponent:Server_SelectVehicle(
     choice.archetype.Archetype)` (enum from `UVehicleArchetype.Archetype` [RB§5.2]; Server RPC called on the server
     runs locally) (V-LCH-05).
  6. `St.launch.pending = true`, `St.launch.atMs = St.nowMs()`, `St.race.launchedByUs = true`, `St.ui.returnToTab = true`.
  7. `gm:LaunchCustomRace(choice.archetype, choice.gameMode, choice.track, launch.conditionArg(choice),
     U.ok(choice.build) and choice.build or nil, U.ok(choice.debugBuild) and choice.debugBuild or nil)` — 6 args
     [RB§2, HERE] (V-LCH-01).
  8. Accepted iff `U.gi().PrimaryFlow == C.E.PrimaryFlow.QuickRace` immediately afterwards (the native body sets it before
     anything else and early-returns on bad input [RB§3.1]) (V-LCH-02). Else: `St.launch.pending = false`, status
     `LAUNCH REFUSED BY THE GAME`, return false.
  9. `diag.recipe()` (evidence for V-LCH-03), `St.emit("launched")`, status `LOADING…`, return true.
- **`conditionArg(choice)`:** `cfg.ConditionPassMode == "table"` → `{TagName = (choice.condition ~= "" and
  U.fname(choice.condition)) or NAME_None}`; `"trackdefault"` → first element of
  `choice.track.TrackConditionDataLayers` (`FTrackConditionConfig.Tag` [RB§5.2]) as `{TagName = e.Tag.TagName}`, or
  `{TagName = NAME_None}` when the array is empty.
- **`restoreGridPatch()`** (listener: phase → FRONTEND): writes back `St.launch.gridPatch.old` and clears it.
- **May call:** `builder.isValid/restoreFromSettings`, `join.commit/localHumanCount/joinedList`, `roster.remoteHumans`,
  `net.beforeLaunch/isListening`, `diag.recipe`, `settings`, `U`, `St`.
- **Game calls:** `AFrontEndGameMode:LaunchCustomRace(Object, Object, Object, Struct FGameplayTag, Object, Object)`,
  `UGfnGameInstance.PrimaryFlow`, `UGameModeVariantDef.GridMakeup.Entries[i].EntryType/NumEntrants`,
  `UVehicleArchetype.Archetype`, `UTrackDef.TrackConditionDataLayers`, `UPlayerRaceEventComponent:Server_SelectVehicle(enum)`
  [RB§2-§5, PS§1.3, HERE].
- **State:** `St.launch`, `St.race.launchedByUs`. **VERIFY:** V-LCH-01..05.

#### G5 · `hud.lua`
- **Responsibility:** P1 HUD placement, guest HUDs, guest-HUD patches (lap, collapsed global parts, optional
  boost icons), visibility following pause/results, cleanup.
- **Public API:** `hud.init()`, `hud.tick()`, `hud.findP1Hud() -> widget|nil`, `hud.placeP1()`,
  `hud.ensureGuest(pc, pnum) -> entry|nil`, `hud.patchGuest(entry)`, `hud.calibrateLap()`, `hud.updateVisibility()`,
  `hud.onLapCounterUpdated(ctx)`, `hud.removeGuest(pcKey)`, `hud.clearAll()`, `hud.allHuds() -> {{pc, widget, pnum}, …}`
  (P1's HUD first, for `nametags`), `hud.manageLocalResults()`, `hud.p1Rehosted() -> bool` (for `pause`).
- **`tick()`** (MAIN; phases PRERACE, RACING, POSTRACE; returns at once when `#U.localPlayers() < 2`):
  1. `p1hud = hud.findP1Hud()`: cached and re-validated; else for `k` in `{"HudRace", "HudMemory"}`:
     `w = U.giSubsystem("UIManager"):GetWidgetInLayer(U.class(C.BP[k]), C.E.UILayer.HUD)` (Class + EUILayer
     [HERE]); accept when valid and (`w:GetOwningPlayer() == U.p1()` or the owner is invalid). Fallback
     `cfg.HudSearchFallback`: every 2 s `FindAllOf("FuseHudWidget")`, owner P1, not one of ours (V-HUD-01).
  2. `hud.placeP1()`: `"rehost"` → `if U.ok(p1hud:GetParent()) then p1hud:RemoveFromParent(); p1hud:AddToPlayerScreen(0) end`
     every poll (the CSM may re-add or recreate it) [HUD§7.2]; `"clone"` → `p1hud:SetRenderOpacity(0)` and P1 gets an
     entry exactly like a guest (`ensureGuest(U.p1(), 1)`); `"leave"` → nothing (V-HUD-02).
  3. For each local player with `index >= 2`: `hud.ensureGuest(pc, join.pnumForPC(pc) or index)`; then `patchGuest`.
  4. `hud.calibrateLap()`; `hud.updateVisibility()`; `hud.manageLocalResults()`.
  0. Once per race, before the first guest HUD: orphan sweep — `FindAllOf("FuseHudWidget")`, every one owned by a local
     guest PC and not ours gets `UnregisterInputComponent()` + `RemoveFromParent()` (HUDs of a previous mod instance
     after a hot reload). Round 4, `cfg.P1HudMode = "clone"`: also every P1-owned `WBP_Hud_Race_C`/`WBP_Hud_Memory_C`
     that is neither ours nor the game's HUD (`UIManager:GetWidgetInLayer(cls, HUD)`); only once the game's HUD is
     resolvable (retried per tick), restricted to those classes (other P1 FuseHudWidgets are the game HUD's parts).
- **Local results** (`cfg.LocalResultsMode`, V-HUD-13): while `U.csmActive("CSM_LocalResults")` and a local guest's
  racer PS still answers `IsStillRacing()`, `WBP_PostRace_Info_C` (`C.BP.PostRaceInfo`, shown by
  `CSM_RF_LocalResults` on the whole viewport [HUD§3.3]) is found with `UIManager:GetWidgetInLayer(cls, layer)` for
  layers Menu, HUD, MenuOverlay (only when the class is loaded), fallback `FindAllOf("WBP_PostRace_Info_C")` ≤ 1 per 2 s.
  `"hide"` (default): `SetVisibility(Collapsed)` re-applied every poll, the saved visibility given back once no local
  guest races any more; `"rehost"`: once `RemoveFromParent()` + `AddToPlayerScreen(0)` into P1's view (owner set to P1
  if none; failure → `AddToViewport(0)`), removed when the state ends; `"leave"`: nothing. `clearAll` undoes either.
  `"hide_inactive"` (round 2): `"hide"` plus `DeactivateWidget()` while hidden and `ActivateWidget()` when given back
  (a collapsed panel is still an activated CommonUI widget whose bindings and input config act on P1's pad). The first
  sighting logs `IsActivated()`, `bIsModal` and `BP_GetDesiredInputConfig()` for V-HUD-13.
- **P1 pause after the re-host:** removing a UserWidget runs `NativeDestruct → StopListeningForAllInputActions`, which
  drops its InputComponent; the HUD's Enhanced-Input bindings are made once at initialisation, so P1's own pause
  binding may be gone after the re-host. `hud.p1Rehosted()` tells `pause` to poll P1 (`cfg.P1PausePoll`, V-PAU-03);
  `P1HudMode = "clone"` never removes the game's HUD.
- **`ensureGuest(pc, pnum)`** (once per PC per race, needs `p1hud`):
  ```
  w = U.WBL():Create(pc, p1hud:GetClass(), pc)          -- same class as P1 (Race or Memory HUD) [HUD§6 #1]
  w:AddToPlayerScreen(cfg.GuestHudZOrder)               -- ZOrder 10
  w:TransitionIn()                                      -- BlueprintEvent, no params [HERE]
  if cfg.GuestHudRegisterInput then w:RegisterInputComponent() end      -- V-PAU-01
  c = p1hud.EventInfo:GetContent(); if U.ok(c) then w.EventInfo:SetContent(U.WBL():Create(pc, c:GetClass(), pc)) end  -- V-HUD-07
  ri = w.WBP_HUD_RaceInfo
  for _, n in ipairs(cfg.GuestHudCollapse) do local x = ri[n]; if U.ok(x) then x:SetVisibility(C.E.Vis.Collapsed) end end
  if cfg.GuestHudNotifications == "remove" then RemoveFromParent() on w.Hud_Notification_CrashFeed, w.Hud_Notification_GameFeed,
     w.WBP_Hud_Notification_Container, w.WBP_Hud_Notification_Container_1 end                        -- V-HUD-08
  if cfg.GuestMarkers == "collapse" then w.WBP_VehicleMarkerContainer:SetVisibility(C.E.Vis.Collapsed) end  -- V-HUD-09
  lc = ri.WBP_Hud_EventLapCounter ; St.hud.lapCounters[U.key(lc)] = U.key(pc)
  St.hud.guests[U.key(pc)] = {pc=pc, widget=w, pnum=pnum, lapCounter=lc, lastLapText=nil}
  ```
  Member names: [HUD§1.1-1.2, §4, §7]. The Memory HUD is assumed to mirror them [HUD§4]; every member access is
  guarded with `U.ok` (missing → skipped, logged once).
- **Lap patch** (`cfg.LapPatch`, V-HUD-04): `vm = U.giSubsystem("ViewModelSubsystem"):GetRaceEventVM()` [HERE];
  `calibrateLap()`: once per race, on the first RACING poll where P1 is still racing: `St.race.lapOffset =
  vm.CurrentLapNumber - takeover.racerPSFor(U.p1()).RaceEventComponent.CurrentLapNumber` [HUD§2]. `patchGuest(e)`:
  `ps = takeover.racerPSFor(e.pc)` (the adopted or AI PlayerState when a takeover record exists, else with
  `cfg.RacerPSSource = "pawn"` the possessed vehicle's `PlayerState`, else `e.pc.PlayerState`); `lap = ps.RaceEventComponent.CurrentLapNumber + (St.race.lapOffset or 0)`, clamped to
  `[1, vm.NumLaps]` when `vm.NumLaps > 0`; write `e.lapCounter.Txt_CurrentLap:SetText(U.ftext(tostring(lap)))` every poll
  (the BP only rewrites when P1's global lap changes [HUD§4]). The Memory variant (`WBP_Hud_EventLapCounter_Memory_C`)
  rewrites its text every Tick, so only the `C.FN.LapUpdateMemory` post-hook can keep the guest's lap: while that hook is
  not registered, the guest's Memory lap counters are collapsed instead (logged once; `patchGuest` retries the pending
  hooks first, and gives the counters back as soon as the hook registers) (V-HUD-04b). Post-hooks `C.FN.LapUpdate` and `C.FN.LapUpdateMemory`
  call `hud.onLapCounterUpdated`, which re-patches the matching guest at once (BP hook, filtered by
  `St.hud.lapCounters`). Round 3: a hook counts as working only once it has fired for any counter of its class (P1's
  included); until then the MAIN poll compares with the widget text and guest Memory counters stay collapsed. In the
  hook, a Race-variant counter is rewritten only when its BP variable `"Current Lap Number"` changed in that call
  (fallback `RaceEventVM.CurrentLapNumber`, V-HUD-04d) or the guest's text changed; Memory counters are rewritten on
  every call (`cfg.MemoryLapMode = "collapse"` avoids that, V-HUD-04c). Whenever `ps` is not `e.pc.PlayerState` (takeover without adoption, or a client whose adopted
  `pc.PlayerState` did not replicate), also write `ri.WBP_Hud_EventCurrentPosition.Txt_CurrentPosition` from
  `ps.RaceEventComponent.EventPosition` [HUD§6 #6].
- **Optional boost icons** (`cfg.GuestBotEngineFix`, speculative, V-HUD-10): `bot = w.WBP_HUD_BotEngineInfo`,
  `vs = pc.Pawn.VehicleState`; in `U.try`: `bot:OnRamjetAvailabilityChanged(vs.RamjetAvailability)`,
  `bot:OnBoostToggleChanged(vs.BoostToggledOn)`, `bot:OnThrottleToggleChanged(vs.ThrottleToggledOn)` [HUD§7.5].
- **`updateVisibility()`** (`cfg.HudVisibilityMode = "csm"`, V-HUD-05/06): `paused = (U.csmPaused() == true)`;
  `post = (U.csmActive("CSM_PostRace") == true)`, or phase POSTRACE only when that query is `nil` (bIsRaceFinished's
  meaning is unverified, V-DIAG-01; all queries find-only, see `U.csmLoaded`); `inHud = U.csmActive("CSM_InProgressInHud") or
  U.csmActive("CSM_CountdownInHud")`; per guest `racing = takeover.racerPSFor(pc).RaceEventComponent:IsStillRacing()`;
  `show = not paused and not post and (inHud or racing)`; `w:SetVisibility(show and C.E.Vis.SelfHitTestInvisible or
  C.E.Vis.Collapsed)`. In `"rehost"` mode the same rule (without `racing`) is applied to P1's HUD, because the
  UIManager may no longer remove a widget we moved [UI§5 #2]. If `U.csmActive` returns `nil` for every asset the HUDs
  stay visible until POSTRACE (`"always"` behaves like that by design).
- **Cleanup:** listeners `"leaving"` and phase → FRONTEND/OTHER call `hud.clearAll()`: each guest
  `w:UnregisterInputComponent()`, `w:RemoveFromParent()`; in `"rehost"` mode `p1hud:RemoveFromParent()`; in `"clone"`
  mode `p1hud:SetRenderOpacity(1)`; reset `St.hud`. Phase → POSTRACE only relies on `updateVisibility()`.
- **May call:** `join.pnumForPC`, `takeover.racerPSFor`, `U`, `St`, `sched`.
- **Game calls:** `UIManager:GetWidgetInLayer(Class, EUILayer) -> UUserWidget`, `Widget:GetOwningPlayer()`,
  `GetParent()`, `RemoveFromParent()`, `UserWidget:AddToPlayerScreen(Int) -> bool`, `SetRenderOpacity(Float)`,
  `WidgetBlueprintLibrary:Create(Object, Class, Object)`, `FuseScreenWidget:TransitionIn()`,
  `UserWidget:RegisterInputComponent()/UnregisterInputComponent()`, `ContentWidget:GetContent()/SetContent(Object)`,
  `Widget:SetVisibility(ESlateVisibility)`, `TextBlock:SetText(FText)`, `ViewModelSubsystem:GetRaceEventVM()`,
  `URaceEventVM.CurrentLapNumber/NumLaps`, `UPlayerRaceEventComponent.CurrentLapNumber/EventPosition`,
  `IsStillRacing()`, `FindAllOf("FuseHudWidget")` (fallback, ≤ 1 per 2 s) [HUD§3-§7, HERE].
- **State:** `St.hud`, `St.race.lapOffset`. **VERIFY:** V-HUD-01..13 (incl. 02b, 02c, 04b), V-PAU-01, V-PAU-03.

#### G5 · `nametags.lua`
- **Responsibility:** colour and label the vehicle markers of human players in every HUD we host.
- **Public API:** `nametags.tick()`, `nametags.applyToHud(widget, humans)`, `nametags.clear()`.
- **Behaviour:** `tick()` (MAIN, PRERACE/RACING, only when `settings.get("NameTags")`, `nametags.modRace()` and
  `#hud.allHuds() > 0`; round 4: `modRace()` = not `St.race.singleView` and (`St.race.launchedByUs` or
  `St.race.localViews >= 2` or a connected client with `St.net.wantConnected`), so single-player Campaign/Arcade and
  official online races keep the game's markers; touched markers are restored when the gate turns false):
  `humans = roster.humanPlayerStates()` (map PS address → `{pnum = int|nil, colour = C.COLOURS[pnum] or
  C.COLOURS.Remote}`); for each `{widget}` of `hud.allHuds()`: `canvas = widget.WBP_VehicleMarkerContainer.Canvas`;
  `kids = U.arrayToTable(canvas:GetAllChildren())`; per marker `m` (in `U.try`): `ps = m.MarkerVM.PlayerState`; `h =
  humans[U.key(ps)]`; if `h`: `m.DesiredTagColour = h.colour` (applied by the BP on the next opacity update);
  if `h.pnum`: `m.PlayerTag.Txt_PlayerName:SetText(U.ftext("P" .. h.pnum))`. Re-applied every poll because the BP's
  name refresh overwrites it [HUD§5, §7.6]. Turning the setting off stops re-applying (the BP restores names itself).
- **May call:** `hud.allHuds`, `roster.humanPlayerStates`, `settings`, `U`.
- **Game calls:** `UVehicleMarkerContainer.Canvas`, `PanelWidget:GetAllChildren() -> TArray<UWidget>` (array return,
  V-CORE-08), `UVehicleMarkerWidget.MarkerVM`, `UVehicleMarkerVM.PlayerState`, `WBP_HUD_AbilityReticles_C.DesiredTagColour`
  (LinearColor, table `{R,G,B,A}`), `UVehicleMarkerWidget.PlayerTag` → `Txt_PlayerName:SetText(FText)` [HUD§5].
- **State:** `St.tags`. **VERIFY:** V-HUD-09, V-HUD-11.

#### G5 · `gfx.lua`
- **Responsibility:** the split-screen graphics preset and the takedown-camera setting, both saved and restored.
- **Public API:** `gfx.init()`, `gfx.presetFor(nViews) -> table|nil`, `gfx.applyForViews(nViews)`,
  `gfx.setTakedownCameras(on)`, `gfx.restore()`, `gfx.persistShared(put)` / `gfx.restoreShared(get)` (hot reload:
  saved values as strings).
- **Behaviour:** listeners: first race phase (LOADING, PRERACE, RACING or POSTRACE entered from a non-race phase, the
  same edge as `split`: the MAIN poll may skip LOADING) → `gfx.applyForViews(#U.localPlayers())`; phase → FRONTEND:
  `gfx.restore()`. Values already saved (also restored after a hot reload) are never overwritten.
  `cfg.GfxApplyMode = "console"` (default, as below) | `"usersettings"` (sg.* groups through the GameUserSettings
  `Set<G>Quality` + `ApplyNonResolutionSettings()`, r.* through the console; risk: a game-side `SaveSettings` during a
  split race would persist the preset into `GameUserSettings.ini`) (V-GFX-05). A console write has SetByConsole
  priority until the game restarts (V-GFX-04).
  `presetFor(n)`: `s = settings.get("SplitGraphics")`; `"off"` → nil; `"auto"` → `cfg.GfxPresets.quality` when
  `n <= cfg.GfxAutoQualityMaxViews` else `.performance`; otherwise `cfg.GfxPresets[s]`.
  `applyForViews(n)`: nothing if `n < 2`; first application saves each touched cvar
  (`St.gfx.saved[name] = U.cvarFloat(name)`); applies `U.console(name .. " " .. string.format("%g", value))`; when
  `settings.get("TakedownCams") == false` → `gfx.setTakedownCameras(false)`; `St.gfx.appliedViews = n`.
  `setTakedownCameras(on)`: `s = UEHelpers.GetEngine().GameUserSettings` (the `GfnUserSettingsPC` instance [API§15 #8]);
  first call saves `St.gfx.savedTakedown = s.TakedownCameras` (Bool [HERE]); then `s.TakedownCameras = on`.
  `restore()`: writes every saved cvar back with `%g`, restores `TakedownCameras`, clears `St.gfx`.
  The user's `GameUserSettings.ini` is never saved by the mod (no `ApplySettings`/`SaveSettings` call).
  Round 4: `restoreTakedown(why)` gives `TakedownCameras` back on `"leaving"` (cvars stay until FRONTEND; the next
  race re-applies; `"leaving_cancelled"` re-applies false); pre/post hooks on `C.FN.GUSSaveSettings` /
  `C.FN.GUSApplySettings` (`/Script/Engine.GameUserSettings:SaveSettings()` / `:ApplySettings(Bool)`, 0x4020402) write
  the user's value back for the duration of a game-side save and re-apply the split value after it (depth-counted)
  (V-GFX-06).
- **May call:** `settings`, `U`, `St`. **Game calls:** `KSL:GetConsoleVariableFloatValue(Str)`,
  `KSL:ExecuteConsoleCommand(World, Str, nil)` [API§9], `UEngine.GameUserSettings`, `UGfnUserSettings.TakedownCameras`.
- **State:** `St.gfx`. **VERIFY:** V-GFX-01..06.

#### G5 · `pause.lua` (0.7.0 contract; the pre-0.7.0 one follows, still valid for the polls)
- **Responsibility (0.7.0):** any local player's Start (or Back/View: the player menu) opens the game's own pause
  screen, full screen, OWNED and navigated by that player; no request can soft-lock the pause; pausing still works after
  P1's wreck. Revision 0.7.0 item 7, research `notes/research/pause-split.md` §6.
- **Public API (0.7.0):** `init()`, `poll()` (FAST, race phases), `openPauseMenu(pc, kind, viaPad)` (`kind` `"pause"` |
  `"player"`; `viaPad` for the KeyboardIsP1 owner shift), `isPaused() -> bool|nil` (`U.csmPaused()`), `status()` (table
  for diag F9: armed, hook, hookCalls, requests, noPause, pre, preAcquired, imcBoosted, hudInputsOff, ownCsm, pauser,
  zSeen, zAuto, dialogs).
- **Split-race layers** (PRERACE/RACING with ≥ 2 local PCs; each has its cfg switch, G1 config.lua "0.7.0"):
  - **A** `PauseHudInputGuard`: A1 the game's HUD owned by a guest that has its own HUD → `UnregisterInputComponent()`
    (every 100 ms; every FAST tick for 2 s after a resume, when the CSM re-creates that HUD); A2 every HUD hud.lua hosts
    loses its input from the pause request until the resume, every pause / player key up and `PauseInputsBackMs`
    (only the HUDs turned off here are turned on again; P1's clone never while hud.lua keeps it off).
  - **B** `PauseCsmHook`: ONE native pre-hook `/Script/Griffin.CosmeticStateMachine:ChangeStateTo` (raw `RegisterHook`,
    pre only; ids and the current handler in `_G.SWGRCouch_pause_hooks`, so a re-required module never registers a second
    one), registered from FAST while a split race runs, the armed flag checked before any param is read, unregistered at
    POSTRACE / `"leaving"` / any phase outside PRERACE/RACING. The pause CSM is recognised by `mCsmAsset` (hard pointer);
    `newState` is read (`PauseHookReadState`; else inferred from the CSM state and the keys); the pauser = our own call,
    else the PC holding a pause key (IA_Veh_Pause fires while held) or just releasing View (IA_Veh_Player is a Tap), else
    the FAST key edges.
  - **C** `PauseMenuPrecreate`, `PauseMenuOwner`, `PauseOwnerPadShift`, `PauseMenuZ`: inside the hook (before the CSM's
    transition) `WidgetBlueprintLibrary:Create(owner)` → `AddToViewport(z)` → `UIManager:AddExistingWidgetToLayer(Menu)`;
    the CSM's ShowWidget ACQUIRES it (refcount 2, OwningStateMachine set); the next FAST tick releases our reference
    (`RemoveWidget`) and calls `InputModeManager:OnControlMappingsRebuilt()`; not acquired within 500 ms → removed;
    leftovers removed 600 ms after the resume; a self-check switches to release-at-end if the acquire did not count.
  - **D** `PauseUiImcBoost`: guests' IMC_UI at `UIManagerSettings.UI_IMC_ActivePriority` (500, with
    `bIgnoreAllPressedKeysUntilRelease`) from the request / pause edge; restored on resume, `"leaving"`, FRONTEND and when
    arming; off while photo mode runs. P1 stays with the game's InputModeManager.
  - **E** `PauseMenuFocusOwner`: the owner's focus on the menu (`HasUserFocus` / `HasUserFocusedDescendants` of the
    MENU) is given back every 500 ms, at most 6 times per menu.
  - **F** `PauseLostMenu`: F1 [PauseMenu] without a sub-state for `PauseNoSubStateMs` → `ChangeStateTo(the
    BP_CsmPickPauseMenu choice)`, after 2 repairs resume; F2 a menu state without its screen for `PauseLostMenuMs` →
    resume (a screen is never re-added); F3 `PauseAnyStartResumes`. "Dialog up" = a persistent Dialog / SystemDialog /
    MenuOverlay container holding a message (the hidden, empty `WBP_Dialog_Container` no longer counts).
  - **G** `PauseRestartCsm`: with InProgress / Countdown known inactive and no pause CSM, a pause key runs
    `StartCosmeticStateMachine(CSM_PauseMenus_Root)` + `openPauseMenu`; `EndStateMachine()` at POSTRACE / `"leaving"`.
  - **Integration review:** a request (or pick) no pause followed is undone after 600 ms (screen removed, IMC_UI
    restored, HUD inputs back once the keys are up; `status().noPause`); `St.hud.p1hud` is validated with `U.ok()`
    before any member access.
  - Kept: `PauseMenuFix`, `PauseMenuSettle`, `PauseHideHudsAtOnce`, the probe lines (now with owner ctrlId, pre=ours |
    game, osm, imcUi, z); the rehost only with `PauseMenuRehost="always"` (A/B tests).
- **hud.lua contract (0.7.0):** pause reads `St.hud.p1hud` (the game's HUD) and `St.hud.guests[pcKey].widget`; hud.lua
  never calls `RegisterInputComponent` on a hosted HUD during a pause (`GuestHudRegisterInput=false`); if hud.lua ever
  adopts the game's HUD as a guest's own HUD it stays that guest's `St.hud.guests[...].widget` (A1 then keeps its input).
- **VERIFY (0.7.0):** V-PAU-09..18 (§6 Session I); V-PAU-04/05/07/08 superseded. Not done (phase 2): Settings /
  Logbook from a P1 pause are created for P2; confirm dialogs are P1-owned; results screens have the same owner problem
  (the hook already sees every CSM's `ChangeStateTo`, it acts on the pause CSM only).

**Pre-0.7.0 contract (the polls below are unchanged):**
- **Responsibility:** let any guest open the (global) pause menu.
- **Public API:** `pause.init()`, `pause.poll()`, `pause.openPauseMenu(pc)`, `pause.isPaused() -> bool|nil`.
- **Behaviour:** `cfg.GuestPauseMode = "hud"` (default): nothing to do here; the guest HUD's own `IA_Veh_Pause`
  binding opens the menu (V-PAU-01). `"poll"`: `poll()` (FAST, race) keeps a `prevStart` per guest PC and on a rising
  edge of `pc:IsInputKeyDown(KEY_START)` calls `openPauseMenu(pc)`. `openPauseMenu(pc)`: return if `isPaused()`;
  `mgr = U.giSubsystem("CosmeticStateMachineManager")`; `sm = mgr:GetStateMachineForRoot(U.obj(C.ASSET.CSM_PauseRoot))`;
  `sm:ChangeStateTo(U.obj(C.ASSET.CSM_PauseMenu), "SWGRCouch", nil)` (the HUD's own call chain [HUD§3.2], 3 params
  [HERE]); status/log `P<n> PAUSED`. `isPaused()`: `U.csmPaused()` (true/false/nil). `"off"`: nothing.
  `cfg.P1PausePoll` (default true, V-PAU-03): while `hud.p1Rehosted()`, `poll()` also watches P1 (`Start`, and
  `Escape` for the keyboard). A rising edge opens the menu only when the game was not paused at this poll nor at the
  previous one (the press that closes the pause menu must not reopen it). Round 3: P1's press is acted on only while
  the race HUD's own binding would exist: `hud.inHudState() ~= false` and not `U.csmActive("CSM_LocalResults", true)`
  (P1 finished: the game shows `WBP_PostRace_Info_C`, not the HUD, and P1 cannot pause the guests still racing).
- **May call:** `join.pnumForPC`, `hud.inHudState`, `U`, `St`. **Game calls:** `PlayerController:IsInputKeyDown(FKey)`,
  `CosmeticStateMachineManager:GetStateMachineForRoot(Object) -> Object`, `CosmeticStateMachine:ChangeStateTo(Object, Str,
  Object)`, `IsStateActiveByRef` via `U.csmActive`.
- **State:** private `prevStart` per PC key, `lastPaused`. **VERIFY:** V-PAU-01, V-PAU-02, V-PAU-03.

#### G5 · `wreck.lua` (added 2026-10-07)
- **Responsibility:** offline race-end rules for wrecks and finishes, the wrecked players' views, no-wreck mode, crash
  slow-mo while split. Design and static evidence: `notes/research/wreck-design.md` (merges `wreck-angle1/2.md`).
- **Public API:** `wreck.init()` (listeners only), `wreck.fastTick()` (FAST, race phases), `wreck.tick()` (MAIN, race
  phases, before `present.tick`/`hud.tick`), `wreck.guardTimeout()`, `wreck.restoreCvars(why)`, `wreck.clear(why)`,
  `wreck.dump()` (diag F9 section), `wreck.persistShared(put)` / `restoreShared(get)` (saved user cvar values),
  `wreck.mode()`. Shared state for other modules: `St.wreck.hideRemaining` (read by `hud.tick`), `St.wreck.p1Out`.
- **Behaviour:**
  - Timeout guard (FAST + MAIN backup; RACING; Standalone only; every `WreckMode` but `"game"`): if
    `gs.RaceTimeoutTime > 0`, not `bIsRaceFinished`, and a non-bot racer still `IsStillRacing()` (the `ShouldEndRace`
    filter): a real human finish with `FinishGraceSec = N > 0` sets `RaceTimeoutTime = GetServerWorldTimeSeconds() + N`
    once (native countdown); `0` leaves the game's 2 s; otherwise disarm: custom ByteProperty `SWGRCouchTimeoutArmed`
    (`RegisterCustomProperty`, `OffsetInternal = {Property="mRaceState", RelativeOffset=8}` else `0x4D0`, registered
    lazily on the game thread) is trusted only after it read 1 on a game-armed timeout; then byte = 0 FIRST, then
    `RaceTimeoutTime = 0`. Fallback (registration/verification/write failed): `RaceTimeoutTime = 1e9`,
    `St.wreck.hideRemaining = true` (hud collapses `WBP_Hud_EventTimes_List.Remaining`).
  - Wreck edge (`rec.bHasVehicleWrecked` rising, local humans, 2+ local players) while another local human races:
    a guard entry per PC: probe lines (edge, +0.5/+2/+6 s); `PlayerCinematicFlowComponent:Client_EndCurrentCinematic
    ("SWGRCouch", false)` when `CurrentCinematicChain` is valid (blind once at 1.5 s; `cfg.WreckCinematic`);
    `SpectatorComponent:Server_RequestPostRaceSpectate()` if not running after `WreckSpectateWaitMs`;
    `SelectPlayerToSpectate_OnClient(ps)` once for the preferred target (`WreckSpectateTarget`) and again only when
    the watched car is out; view guard (`WreckViewGuard`): unusable camera (no view target, NaN/origin,
    > `WreckCamMaxDistUU` from its car for `WreckCamBadMs`) -> `StopCameraFade`, end cinematic,
    `SetViewTargetWithBlend(racing car | own wreck, 0.3, Linear, 0, false)`; after a fallback the native target is no
    longer re-selected (`nativeBroken`). One blind `StopCameraFade` at `WreckFadeClearMs`.
  - `"noWreck"`: `NoWreckMethod="build"`: `RacerBuildState.VehicleBuilds[k].UseHealth = false` until
    `rec:ShouldUseHealth()` is false (20 FAST tries, then top-up only; MAIN re-check for a rebuilt build state);
    `"cvar"`: `Race.InfiniteHealth 1`; every method: `ShouldNextCrashWreckVehicle()` true ->
    `Server_ChangeVehicleHealthBy(Starting - Health)`.
  - Slow-mo (`WreckSlowMo`): `"off"`: `CrashCamera.SlowMoEnabled 0` while split (2+ local players, not
    `present.isSingleView()`, not `St.race.singleView`) and `WorldSettings.CinematicTimeDilation < 1` reset to 1.0
    (ApplySlowMo stops writing once the cvar is 0); `"last"`: the same only while 2+ local humans race; `"game"`.
  - Cvars: the user's value is saved once (`U.cvarInt`) and given back on `"leaving"`, FRONTEND/OTHER, or a mode change;
    persisted over a hot reload (`wreck.saved`).
- **May call:** `takeover.racerPSFor`, `join.displayNumForPC`, `present.isSingleView`, `present.stateActive` (diag),
  `U`, `St`, `C`. **Game calls:** as listed in the file header (all reflected except the 0x4D0 byte).
- **State:** `St.wreck` per world generation `{seen, guard, build, graceSet, disarms, lastDisarm, hideRemaining,
  topups, dilationResets, slowOff, infHealth, p1Out, standalone, saved}`; module-local registration record.
- **Limits:** a takeover guest on an adopted **bot** PS (`TakeoverClearBotFlag = false`) is not a human for
  `ShouldEndRace`: it does not keep the race alive. Hosted network races keep the game's rules (no wreck timeout,
  30 s after a human finish). `pause.lua` refuses P1-side pause while `CSM_LocalResults` (now reachable mid-race when
  P1 is out).
- **0.5.0 (run E):** wreck camera hold + `WreckView` "car"/"carAll"/"native", fade read/clear, emulated slow-mo, photo
  mode back-off, `photoMode()` / `viewInfo(pc)` exports: Revision 0.5.0 item 12 above and `wreck-design.md` §9.1.
  `cfg.WreckView`, `WreckCrashCamHoldMs`, `WreckSlowMoEmulate`, `WreckSlowMoWaitMs`, `WreckTargetStaticMs`,
  `WreckViewReapplyMs`, `WreckViewBlendSec`, `WreckFadeRead`.
- **VERIFY:** V-WD-01..08, V-WD-11, V-WD-12, V-WD-14 (§6 Session E); V-WD-15..18 (§6 Session F).
- **0.6.0 (run G, track B):** a watched car is shown through `chasecam.lua` (new module, required by wreck.lua, no
  main.lua entry): its own camera for a local human's car, else after a placement check (inside / not behind ->
  `w.badCam`) a chase rig (engine `CameraActor` attached behind the car, destroyed in `wreck.clear`); `cfg.WreckCarCam`
  "auto"/"rig"/"car", `WreckCarCamMinDistUU`, `WreckCarCamBehindUU`, `WreckRigBackUU/UpUU/Pitch/Fov`; `viewInfo` adds
  `viewActor`. crashcam.lua: `CrashCamGuest` defaults to "car". pause.lua: `WBP_PlayerMenu_Presentation_C` is a pause
  screen, owner focus on rehost (`PauseMenuFocusOwner`), lost-menu repair (`PauseLostMenu`, `PauseLostMenuMs`).
  VERIFY: V-PAU-07/08, V-WD-19/20, V-CC-07 (§6 Session H, track B).

#### G5 · `ignition.lua` + `ignpad.lua` (added 2026-10-07, 0.5.0)
- **Responsibility:** per-player pre-flight checks (own `WBP_IgnitionScreen_C` per view, own pad, pad prompts,
  completion modes). Revision 0.5.0 item 13; `notes/research/presentation.md` §3b.
- **Public API:** `ignition.mode()`, `ignition.tick(lps)` (MAIN, from `present.tick`, race phases, 2+ local players),
  `ignition.fastTick()` (FAST, from `present.fastTick`), `ignition.clear()`; `ignpad.begin/sync/fastTick/stop/broken/
  describe(out)` (driven by ignition only). State: `St.present.ign`, `St.ignpad`.
- **Config:** `IgnitionMode`, `IgnitionView`, `IgnitionSimple`, `IgnitionZOrder`, `IgnitionCopyInput`,
  `IgnitionPadAssist`, `IgnitionPadAssistWindowMs`, `IgnitionPadPrompts`, `IgnitionFixedKeys`.
- **VERIFY:** V-PRE-02, V-PRE-03, V-PRE-06..09.

#### G5 · `uxsplit.lua` (added 2026-10-07, 0.7.0)
- **Responsibility:** each player's half shows only its own player's race messages and danger visuals (Revision 0.7.0;
  `notes/research/ux-split-messages.md`, `ux-split-visuals.md`, `ux-split-inventory.md`). Armed only in a split race
  (PRERACE/RACING, 2+ local players, not `St.race.singleView`); native hooks registered on arming, removed on disarm.
- **Wiring:** `main.lua` `MODULES` (after `hud`), `INIT_ORDER` (before `hud`: its `"leaving"` / `"phase"` listeners run
  first); `uxsplit.fastTick()` in FAST race phases after `viewguard.fastTick`; `uxsplit.tick()` in MAIN right after
  `hud.tick`. `hud.ensureGuest` calls `uxsplit.hudCreating(w, pc, pnum)` before `AddToPlayerScreen` (arms if needed;
  the widget is "being created" for the index remap: Construct runs inside that call) and `uxsplit.hudCreated()` after
  `TransitionIn`; `hud.removeGuest` calls `uxsplit.hudRemoved(widget)` (integration review: the entry is dropped at once).
- **Public API:** `init()`, `ensureArmed(why)`, `disarm(why, quiet)`, `hudCreating(w, pc, pnum)`, `hudCreated()`,
  `hudRemoved(w)`, `fastTick()`, `tick()`, `status()` (one line), `dump(out)` (F9), `testPost(p, id)` / `testRemove(p,
  id)` (testcmd).
- **Integration review rules:** every wrapper kept between ticks (HUD widgets, PCs, panels, tagged copies) gets `U.ok()`
  before any member access; the class-kind cache is emptied per race; a quiet disarm keeps its leftovers (hidden
  copies, tints, our camera fades) with `St.worldGen` and gives them back on a re-arm in the same world.
  State: `St.uxsplit` (`armed`, `why`, `huds`, `n.<counter>`, `lastRoute`, `tint`, `fade`, `hooks`). Hook ids:
  `_G.SWGRCouch_uxsplit_hooks` (path -> {pre, post, owner}); flags of an earlier load in the same Lua state are switched
  off through `_G.SWGRCouch_uxsplit_flags`.
- **Reads from hud.lua:** `hud.notifEntries()` -> `{ {pc, pnum, widget, bot, conts = { {w, name = TargetName, panel =
  NotificationSubPanel, tree} }} }` (P1 first, `allHuds` order, containers read once per HUD instance);
  `hud.gameHudWidget()` -> the game's hidden race HUD in `"clone"` mode (its posts are shown nowhere, never remapped).
- **Hooks (all native; post-callback args are (ctx, ReturnValue, params...) when the function returns a value):**
  `SubsystemBlueprintLibrary:GetGameInstanceSubsystem` PRE ONLY (poster = ContextObject when Class =
  GfnMessagingSubsystem; registered without a post callback, so UE4SS makes no Lua post call at ~750 calls/s);
  `GfnMessagingSubsystem:AddMessage` / `AddMessageParams` pre+post (snapshot, diff, tag, hide), `RemoveMessage` /
  `FlushMessageContainer` pre+post (holders re-posted), `RemoveMessageByHandle` pre+post (waiting copies);
  `GameplayStatics:GetPlayerPawn` post (return override: the guest pawn for `WBP_HUD_BotEngineInfo(_Memory)_C` in our guest
  HUDs only); `KismetMaterialLibrary:SetVectorParameterValue` pre+post (`Collection := nil` for the three last-crash
  colours of `MPC_HUD_Parameters`, read back once per race, else the default is written back); `UserWidget:PlayAnimation`
  post (`StopAnimation` of Engage/DisengageRamjet, icons set); `GfnUserSettings:GetFullScreenEffectsEnabled` post (false
  while armed, not paused, no photo mode).
- **Config:** `UxSplitIndexRemap`, `UxSplitMessages`, `UxSplitMsgHide`, `UxSplitRepost`, `UxSplitDanger`,
  `UxSplitHudColours`, `UxSplitRamjetColour`, `UxSplitFullScreenFx`, `UxSplitFadeMax`, `UxSplitGameHud` (hud.lua),
  `UxSplitGuestHolo` (hud.lua), `UxSplitProbeMs`; `consts`: `C.MSG`, `C.MSG_CONTAINERS`, `C.UX`, `C.FN.GIS/Msg*/
  GetPlayerPawn/KmlSetVector/PlayAnimation/FullScreenFx`, `C.ASSET.MPC_HUD/MPC_VehicleVfx`, `C.CDO.KismetMaterialLibrary`.
- **VERIFY:** V-UX-00..13, V-HUD-04 (lap, hud.lua).

#### G5 · `restart.lua` (added 2026-10-10, 0.11.0)
RESTART RACE in the pause menu of an offline race SWGRCouch launched (`St.race.launchedByUs`, standalone, RACING).
- `M.decorate(w, how)`: called by `pause.lua` for every new `WBP_PauseRacing_C` (pre-create inside the ChangeStateTo
  hook; menuTick first sight). Idempotent per screen. Puts the game's detached `Btn_RetryRace` back right below RESUME
  (`place`: the rows below RESUME are removed and added again after it), labels it `MenuText.Pause_Button_Restart`,
  switches the moved rows on (`enableRows`, copies RESUME).
- `M.fastTick()`: the native pre-hook on `ArcadeSubsystem:RequestRestartEvent` (registered while an eligible race is
  RACING, unregistered at leaving / FRONTEND; registry `_G.SWGRCouch_restart_hooks`), the eligibility verdict, the
  row checks while paused (every tick for 1.5 s, then every 500 ms), and the confirmed request:
  `RacingGameMode:RequestResetRace()` (`PauseRestartSequence`), `[phase] leaving the race (restart)`, the watchdog.
- `M.status()` for diag. Config `PauseRestart*`. Evidence: Session T.

#### G6 · `roster.lua`
- **Responsibility:** answer "who is human, local or remote, and since when"; feed the lobby, launch, takeover and
  name tags. Everything is computed on demand from owners the engine prunes (`GameInstance.LocalPlayers`,
  `GameState.PlayerArray`); only arrival times are stored.
- **Public API:** `roster.init()`, `roster.tick()`, `roster.localPCs() -> {pc…}` (from `U.localPlayers()`),
  `roster.remoteHumans() -> {obj…}` (server: remote PlayerControllers incl. child connections; client: remote human
  PlayerStates), `roster.humanPCs() -> {pc…}` (server only: local PCs + remote PCs), `roster.humanPlayerStates() ->
  {[psKey] = {pnum, colour, isLocal}}`, `roster.firstSeenMs(pc) -> number|nil`, `roster.isMidGameJoiner(pc) -> bool`,
  `roster.noteArrival(pc)`.
- **Behaviour:**
  - `remoteHumans()` on a server: for `i = 1, gs.PlayerArray:GetArrayNum()`: `ps = gs.PlayerArray[i]`; `o = ps.Owner`
    (AActor.Owner [HERE]); keep `o` when `U.isPlayerController(o)` and `not o:IsLocalController()`; de-duplicate by PC
    address (an adopted racer PS is also owned by the human PC, §3.3). On a client: keep `ps` when
    `ps.bIsABot == false` and `ps` is not the `PlayerState` of any local PC [PS§1.3].
  - `humanPlayerStates()`: local players → `pc.PlayerState` and, if a takeover record exists, `rec.aiPS`
    (`takeover.racerPSFor(pc)`), with `pnum = join.pnumForPC(pc)` and `colour = C.COLOURS[pnum]`, `isLocal = true`;
    remote humans → their PlayerState (server: `pc.PlayerState`; client: the PS itself), `pnum = nil`,
    `colour = C.COLOURS.Remote`.
  - `tick()` (MAIN, race; also called by `net.tick()` in the front end while hosting): every human PC without an
    entry gets `St.roster.firstSeen[key] = St.nowMs()`. Listener `"world"` resets `firstSeen` and `midGame`; the next tick
    re-notes everyone present, i.e. before the race starts.
  - Hooks (`init`): post `C.FN.StartingNewPlayer` (`HandleStartingNewPlayer(NewPlayer)`, BlueprintNativeEvent, server)
    → `roster.noteArrival(NewPlayer:get())` + log (V-NET-10); post `C.FN.MidGameJoiner`
    (`Client_SetIsMidGameJoiner(bool)`, NetClient RPC; fires where it executes) → `St.roster.midGame[U.key(ctx:get():GetOwner())]
    = isMid:get()`.
  - `isMidGameJoiner(pc)`: `St.roster.midGame[key] == true` or `pc.SpectatorComponent.bIsMidGameJoiner == true`
    (`AGfnPlayerController.SpectatorComponent` [PS§1.6]) (V-TKO-09).
- **May call:** `join.pnumForPC`, `takeover.racerPSFor`, `U`, `St`.
- **Game calls:** `AGameStateBase.PlayerArray`, `AActor.Owner`, `AController:IsLocalController()`,
  `APlayerState.bIsABot`, `AController.PlayerState`, `ActorComponent:GetOwner()` [Inf stock UFunction],
  `UPlayerSpectatorComponent.bIsMidGameJoiner` [PS§1.6, HERE].
- **State:** `St.roster`. **VERIFY:** V-TKO-09, V-NET-10.

#### G6 · `takeover.lua`
- **Responsibility:** §3 exactly: gate, car pick, takeover with PlayerState adoption, verification, release, results
  unblocking, mid-race leave, optional single-pawn audio re-registration. Server only (every public function returns
  at once on a client, except `racerPSFor` and `recordFor`).
- **Public API:** `takeover.init()`, `takeover.tick()`, `takeover.forceAll()`, `takeover.pickCar(gs) -> car|nil`,
  `takeover.takeOver(pc, car) -> rec|nil`, `takeover.verify(rec)`, `takeover.release(rec)`, `takeover.releaseAll()`,
  `takeover.leaveMidRace(pc)`, `takeover.finishIdlePlayerStates()`, `takeover.racerPSFor(pc) -> PlayerState`
  (`rec.aiPS` when a record exists (server), else with `cfg.RacerPSSource = "pawn"` the possessed vehicle's
  `PlayerState` (replicated, set natively in PossessedBy; a client's adopted `pc.PlayerState` may not replicate,
  V-TKO-05), else `pc.PlayerState`), `takeover.recordFor(pc) -> rec|nil`,
  `takeover.reRegisterP1Pawn()`, `takeover.clear()`.
- **Behaviour:** §3.1 gate in `tick()` (at most one takeover per call; `sched.after("tko", 1000, verify)` after each);
  `forceAll()` = same loop without gate 2 (and without the mid-game filter), for every candidate; §3.2 `pickCar`;
  §3.3 `takeOver`; §3.4 `release`; §3.5 `finishIdlePlayerStates` (SLOW poll, and on phase → POSTRACE); §3.6
  `leaveMidRace`: record → `release(rec)` then `GS:RemovePlayer(pc, false)`; native slot →
  `pc.Pawn:StartInputSourceOverride_OnServer(C.E.Override.Disconnect)` and `join` removes the player in the front end.
  `reRegisterP1Pawn()` (`cfg.ReRegisterP1Pawn`, after every takeover and once on the RACING edge): for `k` in
  `{"PassbyWorldSubsystem","OvertakeWorldSubsystem","AudioNonPlayerProximityWorldSubsystem"}`:
  `U.worldSubsystem(k):RegisterLocalPlayerControlledPawn(U.p1().Pawn)` [PS§2] (V-TKO-10).
- **Hot reload:** `rec.keys` (addresses of pc, car, aiPS, aiCtrl, ownPS taken at takeover time) and the flags are
  written by `persistShared(put)` as strings with the world address; `restoreShared(get)` queues them and the first
  `tick()` of the same world re-finds the objects by address (human PCs + their PS, `gs.Vehicles` + PS,
  `gs.PlayerArray`, `FindAllOf("DrivingAIController")`), keeping a record only when `car.Controller == pc`. No UObject is
  stored in a shared variable (a raw pointer re-wrapped later may be freed).
- **Listeners/hooks (`init`):** `"leaving"` → `releaseAll(true)` (`release(rec, leaving)`: no
  `reRegisterP1Pawn` while leaving; `"leaving"` is emitted before `St.phase` becomes LEAVING); phase → POSTRACE → `finishIdlePlayerStates()`; phase →
  FRONTEND → `clear()`; pre-hook `C.FN.RaceCtrlDestroyed` (`OnPlayerControllerDestroyed(playerController)`, native
  0x20401 [HERE]) → `release(recordFor(param:get()))` when a record exists (V-TKO-06).
- **May call:** `roster.humanPCs/firstSeenMs/isMidGameJoiner`, `U`, `St`, `sched`.
- **Game calls (all server-side, BlueprintCallable natives unless noted):** `ARacingGameState.Vehicles/bIsRaceStarted`,
  `FindRacerIndexByPlayer(PlayerState) -> int`, `AVehiclePawn:WasSpawnedForCinematic()`, `IsUnderCinematicControl()`,
  `GetOriginalInputSource()`, `GetCurrentInputSource()`, `GetInputSourceOverrides() -> TArray<enum>` (array return),
  `StopInputSourceOverride_OnServer(enum)`, `StartInputSourceOverride_OnServer(enum)`, `SetInputSource_OnServer(enum)`,
  `APawn.Controller/PlayerState`, `AController.PlayerState` (raw property write), `AController:Possess(Pawn)`,
  `UnPossess()`, `AActor:SetOwner(Actor)`, `ForceNetUpdate()`, `K2_DestroyActor()`,
  `APlayerController:SetViewTargetWithBlend(Actor, Float, Byte, Float, Bool)`,
  `UPlayerRaceEventComponent.bHasFinishedEvent/EventPosition`, `Server_Cheat_FinishRace(bool)` (Server RPC),
  `URaceAIComponent:SetBehaviour(enum)`, `UVehicleResetComponent:Client_BindInputActions()` (Client RPC),
  `UPlayerInputComponent.RawInputSubsystem`, `AGfnPlayerController.RawInputSubsystem/SpectatorComponent`,
  `UPlayerSpectatorComponent.bIsSpectatorRunning`, `Client_OnSpectatorModeEnded()`,
  `GameplayStatics:RemovePlayer(PC, bool)`, `*WorldSubsystem:RegisterLocalPlayerControlledPawn(VehiclePawn)` [PS§1-§7, HERE].
- **State:** `St.takeovers`, `St.takeoversByCar`. **VERIFY:** V-TKO-01..11.

#### G7 · `net.lua`
- **Responsibility:** §2 host/join flows, listen checks, travel-question detection and fallbacks, auto-rejoin,
  network-failure reporting, lobby texts for the network rows.
- **Public API:** `net.init()`, `net.tick()`, `net.slowTick()`, `net.startHosting()`, `net.stopHosting()`,
  `net.toggleHosting()`, `net.connect()`, `net.disconnect()`, `net.toggleConnect()`, `net.isListening() -> bool`,
  `net.isConnectedClient() -> bool`, `net.beforeLaunch()`, `net.onFrontEnd()`, `net.onRaceMap()`,
  `net.checkTravel(stage)` (1 = early, 2 = timeout, 3 = re-armed missing-car check), `net.ensureListening()`, `net.checkDriverConfig()`,
  `net.checkClientMenu(attempt)` (round 3, V-NET-17),
  `net.onNetworkFailure(ctx, World, NetDriver, FailureType, ErrorString)`, `net.statusText() -> string`,
  `net.netactLabel() -> string`, `net.onUserLeaves()` (round 4).
- **Behaviour (exact):**
  - `isListening()`: `U.isServer() and not U.isStandalone() and U.ok(U.world().NetDriver)` (V-NET-15).
    `isConnectedClient()`: `U.netMode() == "client"`.
  - `startHosting()`: requires `settings.get("NetMode") == "host"`, phase FRONTEND, not already listening.
    `St.net.hosting = true`, `St.net.listenSinceMs = St.nowMs()`, `St.ui.returnToTab = true`,
    `netfix.applySafetyCvars()`, `U.console("open " .. C.MAP.FrontEnd .. "?listen")`, emit `"net"`. If
    `settings.get("Port") ~= 7777` → status `HOST MUST BE STARTED WITH -port=<n>` (V-NET-04).
  - `stopHosting()`: `St.net.hosting = false`; reload the front end WITHOUT the carried URL options (round 4): the
    console `open X` is TRAVEL_Partial and copies every `LastURL` option, `listen` included, so it would listen
    again. `cfg.StopHostingMethod = "openlevel_abs"` (default: `U.GS():OpenLevel(world, FName(C.MAP.FrontEnd), true,
    "")`, TRAVEL_Absolute) | `"disconnect"` (console `disconnect`: HandleDisconnect strips Listen/LAN, `?closed` loads
    GameDefaultMap = L_FrontEnd); `St.net.stopCheckGen = St.worldGen`; emit `"net"`. `tick()` checks the next
    front-end world: still listening → error log + status `STILL LISTENING ...` (V-NET-18). `toggleHosting()` and
    `netactLabel()` treat "listening without hosting" like hosting (STOP HOSTING stays available); `statusText()`
    shows `STILL LISTENING ON PORT <p> ... (STOP HOSTING AGAIN)` for it.
  - `connect()`: requires `NetMode == "join"`, phase FRONTEND, `U.netMode() == "standalone"`. `join.commit()`,
    `St.join.frozen = true`, `St.net.wantConnected = true`, `St.net.connecting = true`, `St.ui.returnToTab = true`;
    `addr = settings.get("JoinAddress") .. ":" .. settings.get("Port")` (round 4: a JoinAddress that already ends in
    `:<digits>` uses that port instead, never `host:7777:7777`); `cfg.JoinMethod`:
    `"openlevel_opts"` → `mm = U.giSubsystem("PlayfabOnlineMatchmaking")`; `opts = ""`; `U.try` →
    `opts = U.str(mm:GetClientTravelOptions())`; log `opts` length (not content); then
    `U.GS():OpenLevel(U.world(), U.fname(addr), true, opts)` (4 params [HERE]); `"openlevel"` → same with `""`;
    `"console"` → `U.console("open " .. addr)` (V-NET-05, V-NET-06).
  - `disconnect()`: `St.net.wantConnected = false`, `St.net.connecting = false`, `St.join.keep = true` when online,
    `U.console("disconnect")`.
  - A connect that cannot start (`connectRefused`) undoes `connect()`: `wantConnected/connecting/frozen = false`,
    `St.join.keep = false`, `St.ui.returnToTab = false`, `join.open()` when our page is shown, emit `"players"`.
  - Hook (`init`, round 4): pre `C.FN.UIReturnToMainMenu` (`/Script/Griffin.UIBlueprintFunctionLibrary:
    ReturnToMainMenu(Object WorldContextObject)`, static native 0x4022401; WBP_Pause's Quit/Abandon) →
    `onUserLeaves()`: unless `cfg.RejoinAfterQuitToMenu`, when `wantConnected` and (connected client or connecting):
    `wantConnected = connecting = false`, `connectSinceMs = nextRejoinMs = 0`, `St.join.keep = true`,
    `St.ui.returnToTab = true`, status `LEFT THE HOST` (no console command: the game travels itself) (V-NET-19).
  - Hook (`init`): post `C.FN.NetFailure` → `onNetworkFailure`: `ft = FailureType:get()`, `msg = U.str(ErrorString:get())`;
    `St.net.lastFailure = {name = C.E.NetworkFailure[ft] or tostring(ft), msg = msg, atMs = St.nowMs()}`; status
    `NETWORK ERROR: <name> <msg>`; if `St.net.wantConnected` → `St.join.keep = true`, `St.ui.returnToTab = true` (the
    joined guests survive the fall-back front end and the rejoin takes them along), and with `cfg.AutoRejoin`
    `St.net.nextRejoinMs = St.nowMs() + cfg.RejoinDelayMs` (V-NET-14).
  - Listeners: phase → FRONTEND → `net.onFrontEnd()` (once per `St.worldGen`): first time `checkDriverConfig()`; reset `relistenDone`,
    `serverTravelDone`, `lateJoinAllowed`, `relistenPending`; if `St.net.hosting` and not listening and
    `cfg.AutoRelistenInFrontEnd` → `sched.after("net", 1000, net.ensureListening)`; if client → status
    `CONNECTED TO <addr>` when `connecting` was set, then `St.net.connecting = false`, `St.net.rejoinTries = 0`, and
    (round 3, V-NET-17) `checkClientMenu(1)` 5 s later in the same world: logs whether a `WBP_FE_MainMenu_C` exists and
    the PrimaryModeSelect / QuickRaceSetup CSM states; none and `cfg.ClientMenuFallback == "csm"` →
    `CosmeticStateMachineManager:GetStateMachineForRoot(CSM_FrontEnd_Root):ChangeStateTo(CSM_FrontEnd_PrimaryModeSelect,
    "SWGRCouch", nil)` and `checkClientMenu(2)` 3 s later; still none → status
    `NO MENU ON THIS CLIENT: CTRL+F8 OR 'couch disconnect' TO LEAVE`.
    Phase → LOADING/PRERACE → `net.onRaceMap()` (once per `St.worldGen`; its timers are world-generation bound): on a client `St.ui.returnToTab = true` (the per-race setter
    `launch.start` runs on the host only); if host and not `relistenDone`:
    `sched.after("net", cfg.TravelCheckDelayMs, function() net.checkTravel(1) end)` and
    `sched.after("net", cfg.RemoteArriveTimeoutMs, function() net.checkTravel(2) end)`.
  - `checkTravel(1)`: if `not isListening()` → fallback (below). `checkTravel(2)`: if listening and
    `#roster.remoteHumans() < St.net.expectedRemote` → `"relisten"`: `St.net.relistenPending = true`,
    `St.net.waitUntilMs = now + cfg.RejoinWaitMs`; `"relisten_takeover"`: `St.net.lateJoinAllowed = true`; also, when
    `cfg.ServerTravelOnMissingCars` and every expected client is present but a human PC has no vehicle once the race
    started plus `cfg.TakeoverGraceMs` (`checkTravel(3)` re-checks every 2 s before that) →
    `U.console("servertravel " .. U.currentMapPath())` once (`serverTravelDone`) (V-NET-13). `checkTravel(2)` stores
    `St.net.remoteAtCheck = #remote` when it arms the relisten wait.
  - Fallback (from `checkTravel(1)`), by `cfg.HostTravelFallback`: `"none"` → log; else `St.net.relistenDone = true`,
    `St.net.lateJoinAllowed = (mode == "relisten_takeover")`, `St.net.relistenPending = (mode == "relisten")`,
    `St.net.waitUntilMs = now + cfg.RejoinWaitMs`, `St.net.remoteAtCheck = 0`, `St.net.listenSinceMs = now`,
    `U.console("open " .. U.currentMapPath() .. "?listen")` (V-NET-07). Not listening `cfg.ListenCheckMs` later (race
    phase) → status `RELISTEN FAILED`, `relistenPending = lateJoinAllowed = false`. Round 4: that `waitUntilMs` is
    provisional; `tick()` re-arms `waitUntilMs = now + cfg.RejoinWaitMs` when the race-map listen is confirmed (the
    blocking World Partition reload no longer eats the clients' window).
  - `tick()` (MAIN): front end + hosting → `roster.tick()` and emit `"net"` when `#roster.remoteHumans()` changed; listen
    timeout → if not listening `cfg.ListenCheckMs` after `listenSinceMs` → status `LISTEN FAILED`, `St.net.hosting = false`.
    Client connected → `St.net.connecting = false`, `rejoinTries = 0` (emit `"net"` once). Race + host +
    `relistenPending` + listening → when `#remoteHumans() >= expectedRemote`, or the wait is over and
    `#remoteHumans() > remoteAtCheck` (else the wait is dropped: nobody came back); round 4: "over" = `now >=
    waitUntilMs` and (no arrival for `cfg.RejoinSettleMs` or `now >= waitUntilMs + cfg.RejoinWaitMs`):
    `relistenPending = false`, `serverTravelDone = true`, `U.console("servertravel " .. U.currentMapPath())`, and on
    success `phase.markLeaving("servertravel")` (seamless travel runs no LoadMap and `OnSeamlessTravelStarted` may not
    fire: takeovers are released and HUDs cleared while every PC and PlayerState is alive), then a watchdog
    (`cfg.ServerTravelWatchdogMs`, same world generation): no world change → `phase.cancelLeaving`,
    `serverTravelDone = false`, status `RESTART FAILED` (V-NET-16).
  - `slowTick()`: a world in which this machine was a connected client (`St.net.clientWorldGen == St.worldGen`, recorded
    by tick/slowTick) that reads standalone is a hard ClientTravel in flight, not a drop: no arm and no rejoin there
    for `CONNECT_GIVEUP_MS` (would cancel the engine's pending travel). Backup drop paths (onFrontEnd standalone,
    slowTick) use `armDropped`: `St.join.keep = true`, `St.ui.returnToTab = true` like `onNetworkFailure`, and when
    this world's menu is already installed `menu_tab.selectOurTab()` 200 ms later (flag consumed).
    Rejoin: `wantConnected`, phase FRONTEND, `U.netMode() == "standalone"`, not in travel, `now >= nextRejoinMs`,
    `rejoinTries < cfg.RejoinMaxTries` → `rejoinTries += 1`, `connect()`. Hosting in the front end: every
    `cfg.LoginLogEveryMs` log `U.gm():IsAnyLoginPending()` (`AFrontEndGameMode`, `() -> bool` [HERE]) (V-NET-11).
  - `checkDriverConfig()`: `defs = UEHelpers.GetEngine().NetDriverDefinitions`; for `i = 1, defs:GetArrayNum()`:
    log `U.str(defs[i].DefName)`, `U.str(defs[i].DriverClassName)`; if the `GameNetDriver` entry does not contain
    `IpNetDriver` → status `ENGINE.INI NET OVERRIDE NOT ACTIVE` (V-NET-02).
  - `statusText()`: host listening → `HOSTING ON PORT <p>: <n> REMOTE PLAYERS`; host not listening → `NOT HOSTING`;
    connecting → `CONNECTING TO <addr>…`; client → `CONNECTED TO <addr>`; plus the last failure when newer than 30 s.
    `netactLabel()`: host → `STOP HOSTING` / `START HOSTING (PORT <p>)`; join → `DISCONNECT` / `CONNECT TO <addr>`.
- **May call:** `join.commit/open`, `roster.tick/remoteHumans/humanPCs`, `netfix.applySafetyCvars`, `phase.markLeaving`,
  `menu_tab.menu/selectOurTab` (round 2: client menu check, drop backup),
  `settings`, `U`, `St`, `sched`. **Hot reload:** `persistShared/restoreShared` keep `hosting`, `wantConnected`,
  `rejoinTries`.
- **Game calls:** `KSL:IsServer/IsStandalone(World)`, `UWorld.NetDriver`, `KSL:ExecuteConsoleCommand(World, Str, nil)` with
  `open …?listen`, `open <addr>`, `disconnect`, `servertravel <map>` (console tokens present in Shipping [NET§2]),
  `GameplayStatics:OpenLevel(World, Name, bool, Str)`, `PlayfabOnlineMatchmaking:GetClientTravelOptions() -> Str`,
  `GfnGameInstance:HandleNetworkFailure(World, NetDriver, Byte, Str)` (hooked), `AFrontEndGameMode:IsAnyLoginPending()`,
  `UEngine.NetDriverDefinitions` [NET§1-§6, RB§8, HERE].
- **State:** `St.net`. **VERIFY:** V-NET-02, 04, 05, 06, 07, 11, 13, 14, 15.

#### G7 · `netfix.lua`
- **Responsibility:** small network compatibility fixes kept apart from the flow logic.
- **Public API:** `netfix.init()`, `netfix.onAckRequested(ctx)`, `netfix.applyIris()`, `netfix.applySafetyCvars()`.
- **Behaviour:** `init`: post-hook `C.FN.AckRequest` → `onAckRequested`; listener `"world"` → first time only,
  `netfix.applyIris()` (a world exists, no net driver yet). `onAckRequested(ctx)`: `comp = ctx:get()`;
  `owner = comp:GetOwner()`; return unless `U.ok(owner)` and `owner:IsLocalController()`; `cfg.GuestAckMode`:
  `"off"` → return; `"guests"` → return when `U.same(owner, U.p1())`; then `sched.after("ack", 500, function() if
  U.ok(comp) then comp:Server_NotifyCoreObjectsArrived() end end)` and log (V-NET-09). `applyIris()`: if
  `cfg.IrisOff` → `U.console("net.Iris.UseIrisReplication 0")` and log the value read back with
  `U.cvarInt("net.Iris.UseIrisReplication")` (V-NET-03). `applySafetyCvars()`: `U.console(cmd)` for each entry of
  `cfg.NetSafetyCvars` (V-NET-12).
- **May call:** `U`, `St`, `sched`. **Game calls:** `UPvpFlowComponent:Client_RequestAckObjects()` (hooked, NetClient
  RPC), `Server_NotifyCoreObjectsArrived()` (NetServer RPC, not BlueprintCallable, callable from UE4SS [NET§6.2 H6]),
  `ActorComponent:GetOwner()`, `IsLocalController()`, console via `U.console`.
- **State:** private `irisApplied`. **VERIFY:** V-NET-03, V-NET-09, V-NET-12.

#### G7 · `mod/config/Engine.ini`
- Content exactly as §2.1 (sections `[/Script/Engine.GameEngine]`, `[/Script/OnlineSubsystemUtils.IpNetDriver]`,
  commented `[ConsoleVariables]` Iris line, commented `OnlineEngineInterfaceImpl` line, `[/Script/Sentry.SentrySettings]`),
  with a header: where to append it, that both machines need it, that official online play is broken while it is
  present, and that `-port=N` changes the host port. Replaces the old file (wrong `[/Script/Engine.Engine]` section,
  60 Hz tick) [NET§9]. **VERIFY:** V-NET-01.

---

## 5. Lifecycle / state machine

### 5.1 Phase graph (`phase.lua`; detection in brackets)
```
 BOOT ──(first world; GameState IsA FrontEndGameState)──▶ FRONTEND
 FRONTEND ──(launch.start accepted: St.launch.pending)──▶ LAUNCHING
 LAUNCHING ──(new world / GameState IsA RacingGameState, 0 vehicles)──▶ LOADING      [LoadMap post or MAIN poll]
 LAUNCHING ──(30 s, or 180 s once accepted (PrimaryFlow QuickRace); still the launch's FrontEndGameState)──▶ FRONTEND (launch failed; status shown)
 LOADING ──(RacingGameState.Vehicles > 0)──▶ PRERACE        (grid, intro, countdown)
 PRERACE ──(bIsRaceStarted false→true; St.race.startedAtMs)──▶ RACING
 RACING ──(bIsRaceFinished or CSM_RF_PostRacePhase active)──▶ POSTRACE   (results)
 LOADING|PRERACE|RACING|POSTRACE ──(LoadMap pre / OnSeamlessTravelStarted pre / RequestReturnToMenus pre)──▶ LEAVING
 LEAVING ──(new world)──▶ FRONTEND | LOADING (relisten / servertravel) | OTHER
 LEAVING ──(servertravel watchdog: same world generation + GameState, phase.cancelLeaving)──▶ race phase (no events)
 any ──(GameState missing: client before replication)──▶ TRANSIT ──▶ recomputed on the next MAIN poll
```
`"leaving"` is emitted synchronously inside the hook that detected it, i.e. before the old world is torn down.
Seamless travel does not run `LoadMap`; the MAIN poll's world/GameState address change is the authoritative detector,
hooks only make it earlier (V-DIAG-01).

### 5.2 Who does what at each step
| Step | Offline | Host (listen server) | Client |
|---|---|---|---|
| **Boot** | `main`: settings, hooks, loops; `split.init` writes GameMapsSettings | same | same |
| **Front end shown** (phase FRONTEND) | `split.enterFrontEnd` (single view); `gfx.restore`; `hud.clearAll`; `takeover.clear`; `join.resync`; `launch.restoreGridPatch`; `net.onFrontEnd` (driver check); `menu_tab` installs tab via NotifyOnNewObject → `RegisterTabs` post-hook, SLOW `ensure` fallback | + `net.ensureListening` if hosting but not listening | + connection status; join frozen |
| **Tab selected** (`CustomEvent` post-hook, our id) | `menu_tab.showPage("lobby")` → `"tab"(true)` → `lobby.onShown` → `join.open` (force single view, dormant guests); FAST: `join.poll` | same | join refused (frozen) once connected |
| **Join** | pads press A/Start → slot joined (`"players"`) | same; remote players listed via `roster.remoteHumans` (`HandleStartingNewPlayer` log) | before CONNECT only |
| **Choose race** | `race` row → `builder.open` → game pickers → Go post-hook → `builder.capture/persist` → back to lobby | same | not used (host chooses) |
| **Host / connect** | — | `START HOSTING` → `net.startHosting` → `open L_FrontEnd?listen` → new FRONTEND, `St.ui.returnToTab` reopens the tab, `isListening` | `CONNECT` → `join.commit` → `OpenLevel(addr, opts)` → host's front end (`HandleNetworkFailure` on error, auto-rejoin) |
| **Launch** | `START RACE` → `launch.start`: grid check, `join.commit`, `LaunchCustomRace`, `PrimaryFlow == 2` check, `diag.recipe` → LAUNCHING | + `net.beforeLaunch` (expected remote count) | follows the host's travel |
| **Loading** (LOADING) | `split.enterRace` (views on); `gfx.applyForViews`; `roster` reset by `"world"` | + `net.onRaceMap` schedules `checkTravel(1)` (2 s) and `(2)` (20 s) → fallbacks (relisten → servertravel, or takeover) | `netfix` acks for guests on `Client_RequestAckObjects` |
| **Countdown** (PRERACE) | `hud.tick`: find P1 HUD, place it, create guest HUDs, collapse global parts; `nametags.tick`; `roster.tick` notes everyone as present before start | + `roster` notes remote PCs | `hud`, `nametags` for its own guests |
| **Racing** (RACING) | `St.race.startedAtMs`; `hud.calibrateLap`, lap patches, visibility; `pause` (guest HUD binding or poll); `join` device hook → Disconnect override on pad loss; `takeover.tick` after grace for PCs without a car | + takeover for remote PCs without a car (not mid-game joiners unless allowed) | no takeover (server only) |
| **Results** (POSTRACE) | `hud.updateVisibility` hides guest HUDs; `takeover.finishIdlePlayerStates` | same | hides its guest HUDs |
| **Leaving** (`"leaving"`) | `takeover.releaseAll`; `hud.clearAll`; `nametags.clear`; `split.setSingleView(true)` | same; travel back may carry clients | same (no release) |
| **Back to menu** (FRONTEND) | as "Front end shown"; joined guests kept, tab reselected, last race preselected → rematch | + relisten if dropped (`AutoRelistenInFrontEnd`) | auto-rejoin if dropped (`AutoRejoin`) |
| **Leave the tab** (`CustomEvent`, other id) | `"tab"(false)` → `join.close` (all guests removed) | same (stays listening) | same; connection unchanged |

### 5.3 Hooks and polls that detect each transition (summary)
| Transition | Primary detector | Backup |
|---|---|---|
| main menu instance appears | `NotifyOnNewObject(C.BP.MainMenu)` + `RegisterTabs` post-hook | SLOW `menu_tab.ensure` (`FindFirstOf`, front end only) |
| tab changes | `WBP_FE_MainMenu_C:CustomEvent(TabId)` post-hook | F5 / `selectOurTab` fallback after 300 ms; `cfg.TabDetectMode = "both"`/`"poll"`: MAIN poll of `GetActiveTab()` (entering and leaving) |
| race chosen | builder `Btn_Go` BndEvt post-hook | `cfg.GoMode = "click"` (Btn_Go through the CommonBtn click hook / ClickMode poll); leaving the builder page adopts a complete pick while no Go was ever detected |
| button clicked | `WBP_Common_Btn_C:BP_OnClicked` post-hook | `cfg.ClickMode = "poll"` (`GetSelected` in FAST) |
| pad join/leave | FAST edge poll of `IsInputKeyDown` on guest PCs | F6/F7 |
| pad (dis)connect | `GfnGameInstance:OnUserInputDeviceChanged` post-hook | `cfg.DeviceDetectMode = "both"`/`"poll"`: SLOW `InputDeviceLibrary` poll; race: `join.raceTick` applies a missed pad-loss override once the car exists |
| world change | MAIN poll (world/GameState address) | `RegisterLoadMapPostHook`, `RegisterInitGameStatePostHook` |
| race start/finish | MAIN poll of `bIsRaceStarted`/`bIsRaceFinished` | `CSM_RF_PostRacePhase` via `IsStateActiveByRef` |
| leaving a race | `RegisterLoadMapPreHook`, `RacingGameState:OnSeamlessTravelStarted`, `RacingGameMode:RequestReturnToMenus` pre-hooks; `net` marks it itself right after its own `servertravel` | MAIN poll sees the new world (cleanup then runs on already-dead objects, all guarded) |
| race entered without our launch | `"race_enter"` (from FRONTEND/LAUNCHING, `St.race.launchedByUs` false, not a client) → before any `"phase"` listener: `join.close()` in LOADING; later, guests with a car / racer entry are handed to the AI (Disconnect override, `leaving`, `St.race.singleView`), the others removed | game-tab selections close stray guests (§1.1) |
| P1 finished, guests still race | `U.csmActive("CSM_LocalResults")` + guest `IsStillRacing()` (MAIN, `hud.manageLocalResults`) | `cfg.LocalResultsMode = "leave"` |
| hot reload (Ctrl+F11) | `ModRef.OnUnload` writes shared variables; boot reads them | stale pages / orphan HUDs removed by `menu_tab` / `hud` |
| remote arrival/departure | `GameModeBase:HandleStartingNewPlayer` post, `RacingGameMode:OnPlayerControllerDestroyed` pre | MAIN `roster` scan of `PlayerArray` |
| network failure | `GfnGameInstance:HandleNetworkFailure` post | SLOW: client unexpectedly standalone while `wantConnected` |
| pause | CSM `CSM_PauseMenus_Active` active (`U.csmPaused`; Idle-inactive fallback gated on `CSM_RF_InProgress`/`_Countdown` active) (MAIN) | none |

---

## 6. Runtime test checklist (later; one row per VERIFY id)

Run in this order; each session needs the previous one green. Keep `UE4SS.log` + Proton log per run under
`state/runs/<date-time>/`. "Fallback" names the `config.lua` switch to flip when the check fails.

### Session A0: no-intro boot (added 2026-10-07)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-FB-01 | title skipped | boot | `[fastboot] title: title skipped: AdvancePreLoadIfPossible() after N ms ready` within ~1-3 s of FRONTEND; no PRESS A, no ident after it; no `... unusable` warning | `FastBootStopIdentMovies=false`, `FastBootSkipTitle=false` |
| V-FB-02 | photosensitivity skipped | same boot | `photo: photosensitivity warning skipped: ...`, then `menu: main menu reached ...`; tab added | `FastBootPhotoBlind=true` |
| V-FB-03 | Epic login / overlay modal gone | first boot with the mod, then the next | `epic: profile bUseEosLinking true -> false`; no browser page, no modal; after a game save the save's flag reads 0x0/absent; next boot `was false at first look` | `FastBootEosDialog` fallback; ACCEPT once by hand |
| V-FB-04 | P1 input without PRESS A | main menu | pad 1 navigates; guests still join | `FastBootSkipTitle=false` |
| V-FB-05 | saves still work | change a setting / finish a race | `GriffinSave.6.sav`, `GameUserSettings.ini` rewritten | `FastBoot=false` |

### Session A: boot, core, front end (1 player)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-CORE-01 | game-thread method | boot banner | `EngineTickAvailable=true` (else GT=ProcessEvent works; FAST timings coarser) | `DefaultExecuteInGameThreadMethod=ProcessEvent` in UE4SS-settings.ini |
| V-CORE-02 | loop timing | log `St.nowMs()` deltas of FAST for 5 s | ~33 ms ±10 | raise `FastPollMs` to 16/50 |
| V-CORE-03 | settings file | first boot | `Mods/SWGRCouch/settings.txt` created, edits survive restart | hard-code path in `settings.modDir` |
| V-CORE-04 | world/GI access | F9 | GI class `BP_GfnGameInstance_C`, world = `L_FrontEnd`, 1 local player | `UEHelpers.GetWorld()` only |
| V-CORE-05 | `KSL:IsValid` | F9 logs one call | returns bool, no throw | `UseKslIsValid=false` |
| V-CORE-06 | subsystems | F9 logs UIManager, CSM manager, EventRecipe, PlayfabOnlineMatchmaking, ViewModel | all valid | `SubsystemLookup="findfirst"` |
| V-CORE-07 | BP hooks fire | tab click, button click, Go | **answered 2026-10-06: NO** (register, never fire); poll paths are the defaults (revision note at the top) | — |
| V-CORE-08 | TArray return marshalling | F9 in race (`GetInputSourceOverrides`, `GetAllChildren`) | `U.arrayToTable` gives the elements | adjust `U.arrayToTable` |
| V-CORE-09 | NotifyOnNewObject on `/Game` class | log on menu construction | fires once per menu, CDO skipped | SLOW `ensure` covers it |
| V-CORE-10 | seamless/return hooks | finish a race, return to menu | `"leaving"` logged with reason before the world changes | MAIN poll only |
| V-CORE-11 | hot reload | Ctrl+F11 in the lobby (2 joined), during the post-race return to our tab, then mid-race (2P, Split graphics on; once with `P1HudMode="clone"`) | lobby reopens once (no duplicate page, guests still joined, also after the post-race reload); mid-race no duplicate guest HUD and one P1 HUD, log "hot reload: ... restored"; cvars restored in the next front end | restart the game instead of Ctrl+F11 |
| V-CORE-12 | BP class load via LoadAsset | open the SPLIT SCREEN tab with `BuilderMode="embedded"` (builder widget class not preloaded) | log `LoadAsset(<Pkg>.<Pkg>): found=... loaded=...` once, then no `U.class: ... still unresolved` line; builder page shows | `U.class` retries `LoadAsset(<Pkg>.<Pkg>_C)`; else `BuilderMode="devscreen"` |
| V-DIAG-01 | phase sequence | log of a full offline race | BOOT→FRONTEND→LAUNCHING→LOADING→PRERACE→RACING→POSTRACE→LEAVING→FRONTEND; note whether LoadMap hooks fired (travel hard vs seamless) | adjust `phase` rules |
| V-TAB-01 | tab appears | main menu | `SPLIT SCREEN` right of Multiplayer, bumpers reach it | SLOW `ensure` |
| V-TAB-02 | `menu["Button Widget Type"]` | log class | `WBP_Tab_Btn_C` | `C.BP.TabBtn` |
| V-TAB-03 | label sticks | browse tabs 2 min | label stays | re-`SetText` in SLOW `ensure` |
| V-TAB-04 | `CustomEvent` param | log `TabId` | FName strings of all 5 tabs; `IgnoreTabSelection` false on clicks | — |
| V-TAB-05 | leaving our tab | select Arcade after ours | Arcade pane shows | `RestoreGamePaneOnTabLeave=true` |
| V-TAB-06 | programmatic select | F5 from another tab, and after a race | our tab highlighted + lobby shown | direct `onTabSelected` (built in) |
| V-TAB-07 | gamepad focus | open tab with pad | `race` row focused, up/down works | `RequestRefreshFocus`; `SetUserFocus(P1)` |
| V-TAB-08 | sync selection | race → menu with `ReturnToSplitTab`; show the Campaign pane | `CustomEvent ... from the switcher->tab sync` lines arrive with `IgnoreTabSelection` true; kept guests survive until our tab is reselected | — |
| V-TAB-09 | first-tab auto-select | debug log while a new menu is built | one `CustomEvent(...) during RegisterTabs (fewer than 4 tabs): ignored` line per menu; our tab gets TabIndex 4 (log of `RegisterTab(..., index 4)`) | — |
| V-TAB-10 | tab poll backup | `TabDetectMode="both"`, click tabs | no `tab poll: active tab is now ...` line while the hook works; with the hook broken (`"poll"`) our tab opens/leaves within 250 ms | `TabDetectMode="poll"` |
| V-TAB-11 | menu re-created in one front-end world | open our tab, wait, switch tabs / return from a sub-screen | at most one `main menu instance installed` per front-end world; if more, the `main menu replaced while our tab was open` line is followed by our tab reopening | `ReturnToSplitTab=false` closes the guests instead |
| V-TAB-13 | our tab after the Campaign pane | show the game's `WBP_FE_Campaign` pane (switcher index 4), then click SPLIT SCREEN once | log `our tab un-highlighted after the switcher->tab sync`; one click opens the lobby | `OurTabSyncFix="off"` (F5 / another tab first) |
| V-TAB-12 | covered game pane | open our tab from the Campaign tab (UE4SS console: `WBP_FE_Recommended_C` `IsActivated`, or watch the action bar) | `false` while our page shows, its action-bar prompts gone and its bindings dead; back on Campaign it is activated again (with the switch: `game pane 0 deactivated under our page` / `reactivated` debug lines) | `DeactivateGamePaneOnShow=true` |
| V-LOB-01 | lobby host | open tab | only our rows visible (old setting rows cleared) | build our own `FuseVerticalBox` via `StaticConstructObject` (see §7) |
| V-LOB-02 | widget look | visual | styled like the game, labels correct | — |
| V-LOB-03 | click by pad A and mouse | each row | action runs once per click | `ClickMode="poll"` |
| V-LOB-04 | non-focusable rows / collapse | navigate; switch NETWORK | cards skipped; `netact` hidden when OFFLINE | `SetVisibility(Hidden)` |
| V-LOB-07 | readable rows (2026-10-07) | open tab | every row dark-on-light (`IsInvert`), highlighted row inverted | `LobbyRowInvert=false` |
| V-LOB-08 | P1 pad navigation (2026-10-07) | d-pad/stick, left/right, A on the lobby | `P1 nav: first press of ...`; highlight moves, one action per A | `LobbyNavHighlight="focus"`/`"style"`; mouse/keyboard |
| V-TAB-14 | return after a covering screen (2026-10-07) | our tab → a screen that deactivates the main menu → back | `main menu active again after N ms while our tab was open: returning to it` | `TabReactivateMinMs`; `ReturnToSplitTab=false` |
| V-BLD-01 | builder page | `race` row | game's pickers work with pad, lists filled | `ChangeStateTo(CSM_FrontEnd_QuickRaceSetup)` [RB§6a] |
| V-BLD-02 | Go capture | pick + Go | log of captured choice incl. condition; lobby label | — |
| V-BLD-03 | back button | builder | `< BACK TO LOBBY` visible, works | change `BuilderBackRow/Col`; `BuilderBackButton=false` |
| V-BLD-04 | restore last race | restart game | `race` row shows last race | — |
| V-BLD-05 | devscreen bookkeeping | `BuilderMode="devscreen"`, Go | log `external launch` with `PrimaryFlow=2` (+ `beforeLaunch` on a host) | — |
| V-BLD-06 | Go detection | pick + Go; then `GoMode="click"` | `Go:` log line in both modes, exactly once per press | `GoMode="click"`; leaving the builder page adopts a complete pick |
| V-LCH-01 | `LaunchCustomRace` from Lua | START, 1 player | race loads with AI | `ConditionPassMode="trackdefault"` |
| V-LCH-02 | acceptance check | log | `PrimaryFlow=2` right after the call | — |
| V-LCH-06 | accepted launch duration | START, slow disk | `PrimaryFlow` stays 2 and LAUNCHING ends with a world change well inside `LaunchAcceptedTimeoutMs`; no `LAUNCH TIMED OUT` | raise `LaunchAcceptedTimeoutMs` |
| V-SPL-02 | CDO edits live | F8 in race (2P), also with EngineTick unavailable (relayout waits 50 ms) | layout flips | restart needed → document |
| V-GFX-01 | cvars settable | F9 shows values before/after | preset values applied and restored in menu | — |
| V-GFX-04 | console cvar priority | after a split race, change graphics in the game menu | note which cvars the game menu can no longer change until restart | drop r.* entries from `GfxPresets` |
| V-GFX-06 | takedown flag never saved | `TakedownCams` off, 2P race: change an option in the pause menu; also quit to the menu from the results | log `takedown guard: user value ... written back`; `TakedownCameras restored ... (leaving)`; `GameUserSettings.ini` keeps the user's value (diff) | leave `TakedownCams` on (no write at all) |
| V-GFX-05 | usersettings mode | `GfxApplyMode="usersettings"`, split race, open the game's graphics menu | levels applied/restored; `GameUserSettings.ini` unchanged after the race (diff) | keep `"console"` |

### Session B: offline 2 players (pad 2)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-JOIN-01 | dormant guests | open tab | 3 guest PCs exist, menu unaffected, no crash | create only on F6 |
| V-JOIN-02 | single view | open tab | one full view while dormant guests exist | — |
| V-JOIN-03 | guest pad input in UI mode | pad 2 presses A | slot P2 joins | `JoinFocusTrick="userfocus"`, then `"viewport"` |
| V-JOIN-04 | pad ↔ ControllerId | pads 2..4, then `KeyboardIsP1` | pad k → ctrlId k (k+1 with keyboard P1) | remap table in `join` |
| V-JOIN-05 | device events | unplug pad 2 | slot shows DISCONNECTED; `InternalId` logged | — |
| V-JOIN-06 | input isolation | P1 presses A in lobby | no guest joins | require Start for join (`JoinWithStart` only) |
| V-JOIN-07 | guests survive travel | after race | P2 still joined, new PC found | re-create in `resync` |
| V-JOIN-09 | keyboard P1, pad 1 joins | `KeyboardIsP1` on, pad 1 presses Start in the lobby, then holds Start 1 s | P2 joins; pad 1's A navigates P1's menu only (card says `press START`, then `HOLD START = leave`); the hold makes P2 leave and P1's page gets no Back | F6 / F7 |
| V-JOIN-10 | device poll | `DeviceDetectMode="both"`, unplug/replug pad 2 | one DISCONNECTED/RECONNECTED per change (hook or poll line), also for P2 with `KeyboardIsP1` (keyboard = default device, excluded) | `DeviceDetectMode="poll"`; with the default `"hook"`, no `device poll: ... without a device hook call` warning while the hook works |
| V-JOIN-11 | no re-entry crash (2026-10-07) | SPLIT SCREEN <-> game tabs 10x (slow, then fast), P2 joined once | no crash, no `RemovePlayer` line, `join session open: ... (0 created now ...)` on re-entry, one view on game tabs, P2 still joins | report log + dump (`GuestRemoval="always"` only to reproduce) |
| V-JOIN-12 | removal hazard, `GuestRemoval="launch"` only | dormant guest + START / Campaign race | `guest ctrlId k removed` warning; race loads, next front end OK | keep `"never"` |
| V-LCH-03 | **native slots** | 2P race, F9 at countdown | P2 in `Racers`, has a car, `FindRacerIndexByPlayer >= 0`, recipe dump lists 2 players | takeover (§3) |
| V-LCH-04 | grid math | `GMV_Race` (5) with 2 humans | count of AI = 3 (humans replace) or 4 (added) — record | `GrowGridInMemory=true` |
| V-LCH-05 | `Server_SelectVehicle` | `SelectVehicleForGuests=true` | no error; vehicle class as chosen | keep false |
| V-SPL-01 | views | race | 2 views TOP/BOTTOM; front end single after return | `relayout()` on PRERACE |
| V-SPL-03 | keyboard P1 | `KeyboardIsP1` on | keyboard drives P1, pad 1 drives P2 | restart required → document |
| V-HUD-01 | P1 HUD found | log | `GetWidgetInLayer` returns P1's HUD | `HudSearchFallback` |
| V-HUD-02 | P1 re-host | countdown → race → pause (by P2) → race → **P1 presses Start** | P1 HUD stays in P1's half, no duplicate; P1's Start opens the pause menu after the re-host | `P1HudMode="clone"`, then `"leave"` |
| V-HUD-02b | put back | force `AddToPlayerScreen` to fail (no owner) | HUD back in the UIManager layer | `"leave"` |
| V-HUD-02c | HUD owner | log of the first re-host | owner P1 (or none, then set to P1) | — |
| V-HUD-04b | Memory HUD lap | a Memory-HUD race (campaign memory / arcade event) with P2 | UpdateCurrentLap Memory hook registered; P2 sees its own lap (else: guest Memory lap counter collapsed, logged; shown again once the hook registers) | `LapPatch=false` |
| V-HUD-12 | member cache probe | race, debug log | no repeated `member cache ... stale` lines | drop the outer-chain probe |
| V-HUD-13 | local results | 3P race, P1 finishes first | P2/P3 views stay unobstructed; P1 gets the panel back (hide) / in its own view (rehost); P1 pressing A / Start while it is hidden does not stop P2/P3 steering (log line `local results panel input`) | `LocalResultsMode="hide_inactive"`, `"rehost"`, then `"leave"` |
| V-HUD-03 | guest HUD data | race | P2 position/energy/abilities/speed are P2's | — |
| V-HUD-04c | Memory lap write cost | Memory-HUD race with 2 guests, `MemoryLapMode="hook"`, 10 min | process memory growth acceptable (estimate ~10 MB for 3 guests) | `MemoryLapMode="collapse"` |
| V-HUD-04d | Race lap write only on change | Race-HUD race with a guest | `lc["Current Lap Number"]` reads as an integer (no per-frame SetText; guest lap still correct after P1's lap changes) | VM fallback is automatic; else every hook call writes |
| V-HUD-04 | lap patch | 3-lap race, P2 behind | P2's lap text = P2's lap | offset rule / `LapPatch=false` |
| V-HUD-05 | CSM queries | pause, results; 3P race where P1 finishes first | `U.csmActive` returns booleans; `U.csmPaused()` true only with a pause page up (`CSM_PauseMenus_Active`); P2/P3 HUDs stay visible after P1 finished | `HudVisibilityMode="always"` |
| V-HUD-06 | draw order | pause with guest HUD forced visible | confirms whether hiding is needed | — |
| V-HUD-07 | EventInfo slot | race | P2's event info panel filled | skip copy |
| V-HUD-08 | notifications | takedown, crash | messages appear once, in the right view | `GuestHudNotifications="remove"` |
| V-HUD-09 | markers in guest HUD | race | P2's markers project correctly | `GuestMarkers="collapse"` |
| V-HUD-10 | boost icons | `GuestBotEngineFix=true` | icons follow P2's car, no errors | keep false |
| V-HUD-11 | name tags | race | P2's car shows red `P2` in P1's view and vice versa | `NameTags` off |
| V-HUD-11b | car tags cvar | race log | `UI.UseScreenSpaceCarTags` value logged; tags visible | `ForceCarTags=true` |
| V-GFX-02 | takedown cams | takedown with setting OFF | no cut-away | — |
| V-GFX-03 | frame time | 2P per preset | record ms/frame (MangoHud) | tune `GfxPresets` |
| V-PAU-01 | guest pause | P2 presses Start/Menu | pause menu opens | `GuestHudRegisterInput=true`, then `GuestPauseMode="poll"` |
| V-PAU-02 | pause via CSM call | `GuestPauseMode="poll"` | menu opens; who navigates it is recorded | — |
| V-PAU-03 | P1 pause after re-host | 2P race, `P1HudMode="rehost"`: P1 presses Start (pad) / Escape (keyboard), then Start again in the menu | menu opens once, closes with the second press and does not reopen | `P1PausePoll=false` if the HUD's own binding still works and doubles; `P1HudMode="clone"` |

### Session C: takeover fallback (force it: `cfg.TakeoverWhen="started"`, Ctrl+F6, or a guest created mid-race with `AllowMidRaceJoin=true`)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-TKO-01 | car obeys the guest | Ctrl+F6 for a PC without car | per-step log; pad drives that car only | `TakeoverIdleAI`, `TakeoverBindInput`, `TakeoverForceRawInput` |
| V-TKO-02 | overrides on AI cars | F9 at countdown and race | list of reasons per AI car recorded | adjust the stop list |
| V-TKO-03 | AI controller ↔ PlayerState; raw PS write | log `rec.aiCtrlHadPS`; after step 2 read back `pc.PlayerState` | equals `aiPS` | `TakeoverAdoptPS=false` (smoke variant) |
| V-TKO-04 | HUD/position follow adoption | race | guest HUD position valid, `FindRacerIndexByPlayer >= 0` | position patch from `rec.aiPS` |
| V-TKO-05 | remote adoption replicates | network session, client F9 | client `PC.PlayerState == Pawn.PlayerState`; the client's guest HUD lap/position and name tags follow the racer PS | `ForceNetUpdate` timing; leave remote on own PS; `RacerPSSource="controller"` if the pawn's PS is wrong |
| V-TKO-06 | release on controller destroy | F7 on a taken-over guest; client quits mid-race | AI resumes, no crash, racer entry intact | release from `"leaving"` only |
| V-TKO-07 | results not blocked | race with a takeover, both `TakeoverAdoptPS=true` and `=false` | adopted: results appear with no `marked finished` line; non-adopted: `racer PS ... marked finished (AI racer entry of non-adopted takeover ...)` then results; check whether `gs.bHaveCheatsBeenUsed` flips | `FinishIdlePlayerStates=false` and watch R5; `FinishUncarriedRacers=true` if an uncarried Racers entry still blocks |
| V-TKO-08 | game's own disconnect path | F7 on a native-slot guest | log of `OnHumanSwitchedWithAI` / controller-destroyed hooks | — |
| V-TKO-09 | mid-game joiner detection | client joins after start | `isMidGameJoiner` true and no takeover (unless allowed) | firstSeen rule only |
| V-TKO-10 | P1 audio after guest possession | `ReRegisterP1Pawn=true` | passby/overtake audio on P1's car | keep false |
| V-TKO-12 | remote player drives a taken-over car | `HostTravelFallback="relisten_takeover"` with a client (and its guest) | log `remote: ResetComponent:Client_BindInputActions() sent`; the client's pad drives that car | `TakeoverBindInputRemote=false` if the RPC disturbs a car that already drove |
| V-TKO-11 | remote end-spectate | network takeover of a remote PC | `Client_OnSpectatorModeEnded sent` harmless on the client | `TakeoverEndSpectateRemote="off"` |

### Session D: network (two machines, then over WireGuard)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-NET-01 | user Engine.ini active | both machines | timeouts/IpNetDriver in effect (see V-NET-02) | find the real Saved folder |
| V-NET-02 | driver definitions | first front end log | GameNetDriver = IpNetDriver | fix Engine.ini section/path |
| V-NET-03 | Iris switch | `IrisOff=true` both; client with 1 guest | cvar reads 0; guest child connection works | `-UseIrisReplication=0` on the command line |
| V-NET-04 | listen reload | START HOSTING | front end reloads listening, tab reopens, guests kept, boot flow skipped | console `open L_FrontEnd?listen` by hand; document |
| V-NET-05 | `GetClientTravelOptions` | CONNECT (default method) | options logged (length), join succeeds | `JoinMethod="openlevel"` |
| V-NET-06 | console join | `JoinMethod="console"` | join succeeds | — |
| V-NET-07 | recipe survives relisten/servertravel | force `HostTravelFallback="relisten"` path | race restarts with same track and everyone | `"relisten_takeover"` |
| V-NET-08 | client guests split-join | client with 1 guest connects | host F9: 2 remote PCs (1 child) with PlayerStates; both get cars at launch | takeover for child PCs |
| V-JOIN-08 | client guest PC replication | client with 1 guest returns to the host's front end | guest slot stays joined; its PC appears within a few seconds | — |
| V-NET-09 | ack fix | client with guest, race loads | no stall in WaitForClientsToBeReady | `GuestAckMode="all"`, then `"off"` |
| V-NET-10 | login/identity | join logs | `HandleStartingNewPlayer` logged for each remote PC; no `incompatible_unique_net_id` | Engine.ini `CompatibleUniqueNetIdTypes` |
| V-NET-11 | front-end login gate | hosting log | `IsAnyLoginPending` false once clients are in | investigate native gate |
| V-NET-12 | PvP systems silent | 3 races | no AFK kick / player-data disconnects | `NetSafetyCvars` |
| V-NET-13 | **travel question** | host START with a connected client | client follows natively (no fallback logged) | `HostTravelFallback` modes |
| V-NET-14 | failure hook | stop the host mid-session | client logs failure type + string, auto-rejoins when host relistens | — |
| V-NET-15 | listening check | after START HOSTING | `isListening()` true (`NetDriver` valid) | drop the `NetDriver` term |
| V-NET-17 | client front end menu | client connects to the host's front end | log `client front end (V-NET-17, check 1): main menu present`; our tab reopens | `ClientMenuFallback="csm"` (default) then DISCONNECT |
| V-NET-18 | stop hosting really stops | START HOSTING, a client joins, STOP HOSTING | new front end standalone (`isListening()` false), client gets a network failure, no `STILL LISTENING` line | `StopHostingMethod="disconnect"` |
| V-NET-19 | client quits through the pause menu | client in a networked race: pause → Quit / Abandon | log `left the host through the game's menu`; no auto-rejoin, lobby shows NOT CONNECTED | `RejoinAfterQuitToMenu=true` (old behaviour) |
| V-NET-16 | servertravel accepted | relisten fallback ends in servertravel | the world changes within `ServerTravelWatchdogMs`; no `servertravel was not executed` line | raise `ServerTravelWatchdogMs`; `HostTravelFallback="relisten_takeover"` |
| M6 | WireGuard | repeat Session D between homes | ping, rubber-banding recorded | `NetServerMaxTickRate` tuning |

### Session E: 0.4.0 feedback fixes (2 pads, offline; added 2026-10-07)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-CORE-13 | real clock | boot | `[state] clock: real time source GetAccurateRealTime (os.clock runs at x1.xx ...)`; START-again windows last 5 real s | none (os.clock as before; WARN line names it) |
| V-SET-01 | setup page | CHOOSE RACE | `[setup] race setup page built (16 option rows, ...)`; header, media area, rows; lobby rows hidden | `SetupMode="builder"` (ADVANCED row always works) |
| V-SET-02 | planet video | PLANET step, move the focus | the planet movie plays in the media area; leaving restores the menu video | `SetupVideo=false` |
| V-SET-03 | value rows with the pad | MODE grid row / P1 vehicle rows: d-pad left/right | `cycler ... (pad)` once per press, focus stays on the middle | keyboard arrows, mouse arrows |
| V-SET-04 | guest column | VEHICLES: P2 d-pad up/down/left/right, A | P2's column changes, A toggles READY, B still leaves | `JoinFocusTrick` (V-JOIN-03) |
| V-SET-05/08/11 | per-player model | START RACE | `recipe: 12 racer(s): 2 local human(s) [P1=... P2=...]`, `in-race override (loading): P2 -> PRE_...`, `race recipe: ... Car/PRE_Car_...`; each player drives the picked model | `SetupInRaceOverride` on/off to see which path works |
| V-SET-06 | full grid | same | `grid: PlayerChoice x5 -> PlayerChoice x2 + Car x10`; 12 cars, all of the class | `SetupGridMode="playerchoice"`, then `"off"` |
| V-SET-10 | guest build | P2 picks another build | `build P2: ... applied to 1 VehicleBuilds entry` | `SetupPerPlayerBuild=false` |
| V-INP-05 | DLL loaded | 2 local players exist | `[inputfix] native filter loaded: installed=1 reason=ok` | kbsplit (automatic), `InputFixMode="kbsplit"` |
| V-INP-01 | cars bound | F9 at the countdown | `bound=own` for both cars; `binds` stays 1 per guest car | `InputFixMode="bind"` + report |
| V-INP-03/06 | isolation | race: P2's pad, then pad 1, then keyboard | only the owner's car reacts; native status `o ctrl=0 ... passed>0 dropped>0` | `InputFixMode="kbsplit"` (+ `KeyboardIsP1` on) |
| V-PRE-01 | full-screen intro | race start | track intro / grid intro full screen (`[present] view: ONE FULL-SCREEN VIEW (...)`), split at ignition/countdown | `PresentViewMode="split"` |
| V-PRE-02/03 | per-player ignition | ignition phase | each half shows its own checks; `P2 pre-flight checks underway: true`; P2's pad completes P2's list | `IgnitionMode="auto"`, `IgnitionSimple=true`, `IgnitionView="single"` |
| V-HUD-02/02c/02d | per-view HUD | race | each half has its own complete HUD; `game HUD ... owner=...` logged; P1's pause opens once | `P1HudMode="rehost"`, `P1CloneInput=true` |
| V-NAM-01/02 | guest names | lobby after joining, race, results | `P2 is now named 'Player 2'`; tags / position list / results show it | `GuestNameMethod` |
| V-GFX-07 | sharp full-screen intro | race start | intro at the user's resolution scale, split preset back at the countdown, no hitch | `GfxSingleViewCvars=false` |
| V-WD-01 | the 2 s rule | `WreckMode="game"`, P2 wrecks | F9 `timeout: T=... remaining=~2`; race over ~2 s later | — |
| V-WD-02 | race goes on | P2 wrecks, then P1 finishes | `race timeout disarmed (human wreck ...)`; race ends at P1's finish; P2 DNF | parked 1e9 + Remaining line hidden |
| V-WD-03 | timeout byte | first armed timeout; Ctrl+F11 mid-race | `timeout byte registered ... (mRaceState+8)`, `timeout byte verified`; no error after reload | `not trusted` -> parked-time fallback |
| V-WD-04 | wrecked camera | P2 wrecks; P1 wrecks | `probe P2 wreck/+0.5s/+2.0s/+6.0s: view=... cam=...` names the camera (H1 crash cam / H2 spectator cam / H3 cinematic) | report lines |
| V-WD-05 | never black | P2 wrecks while P1 races | P2's half shows a racing car within ~1 s | `WreckViewGuard="force"`, `WreckViewFallback="own"` |
| V-WD-06 | failed cinematic | P1 wrecks while P2 races | `failed-event cinematic ended`; nothing hidden in P2's half | `WreckCinematic="keep"` to compare |
| V-WD-07 | watch the other human | P2 wrecks | `P2 spectates Player 1 (...)`; no jitter in either half | `WreckSpectateTarget="ai"` |
| V-WD-08 | no wrecks | `WreckMode="noWreck"` | `P1: no wrecks (UseHealth false ...)`; tumble + reset only | `NoWreckMethod="cvar"`, `"topup"` |
| V-WD-11 | P1 out, guest racing | P1 wrecks | `spectate panel shown while guests race`, then `local results panel shown ...`; P2's half clear; present stays SPLIT | `SpectateWidgetMode="hide_inactive"` |
| V-WD-12 | online-style grace | `FinishGraceSec=30`, P1 finishes first | `the others get 30 s`; native countdown; ends at 30 s or P2's finish | `"all"` |
| V-WD-14 | no shared slow-mo | `WreckSlowMo="off"`, P2 wrecks | `CrashCamera.SlowMoEnabled 0 (...)`; P1's half never slows | — (0.5.0 default is `"game"`) |

### Session F: 0.5.0 run-E fixes (2 pads, offline, podrace; added 2026-10-07)
Full table with log texts: README §9 Session F.
| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-CORE-14 | Ctrl+F11 mid-race | `phase detected from the live world after (re)load: RACING`; no "phase still BOOT" | report |
| V-SET-12 | Tatooine track list | each layout once, display names, REVERSE marked | `SetupTrackDedupe=false` |
| V-SET-13 | VEHICLES art | a podracer render per column | report |
| V-INP-01 | bind check | `every local car reads its own raw input: native filter + contexts on`; no "write did not stick" | `InputFixMode="bind"` |
| V-PRE-06..09 | own-pad checks + prompts | P2's D-pad advances P2's list (`assist #n`); P1 not doubled; pad icons on both | `IgnitionMode="p1game_guestauto"` / `"complete"`; `IgnitionPadAssist="off"`; `IgnitionFixedKeys="off"` |
| V-WD-18 | P2 wreck camera | +2 s probe `phase=crash`, P2 sees its wreck | `WreckView="native"` |
| V-WD-05/07 | P2 view after 4 s | `phase=car car=<name>(moving)`, never P1's parked car | `WreckSpectateTarget="ai"` |
| V-WD-15 | fades | `camera fade fields registered`, probes `fade=off:<n>` | `WreckFadeRead=false` |
| V-WD-16 | slow-mo on P2's wreck | both halves ~2 s; `emulated wreck slow-mo done` or the game's own; dilation back to 1.0 | `WreckSlowMoEmulate=false` |
| V-HUD-14/15 | no HUD thrash | `P2 HUD hidden: out of the race (wrecked)` once; no repeated `HUD instance changed`; no lag | `HudOutPlayers="keep"` |
| V-PAU-04/05 | pause menu | SUPERSEDED by V-PAU-11/15 (0.7.0: no rehost unless `PauseMenuRehost="always"`; Session I) | — |
| V-PH-01, V-WD-17, V-HUD-16, V-INP-07 | photo mode after a wreck | `photo mode OPEN`, guard paused, HUD work paused, native filter off; each pad moves its own photo camera; clean resume after `photo mode CLOSED` | report |

### Session G: 0.5.1 run-F fixes (2 pads, offline, podrace; added 2026-10-07)
| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-CC-01 | P1 crash (reference) | `P1 crash (...; P1: game camera, probes only)`; probes `view=BP_CrashCameraActor_C(own crash cam)`, `initMode=<CMD_...>`, dilation < 1 at +0.5 s | `CrashCamModeCheck=false` if P1 shows `initMode=NONE` |
| V-CC-02 | P2 crash | `P2 crash camera -> own car view after N ms (<reason>)`; P2 sees its own pod, never a black half; 2nd crash `after 0 ms (learned: ...)` | `CrashCamGuest="car"` / `"keep"` |
| V-CC-04 | fades | no `StopCameraFade` line in normal crashes | `CrashCamFadeClearMs=0` |
| V-CC-05 | guest crash slow-mo | `P2 crash: crash slow-mo emulated` ... `emulated crash slow-mo done`, dilation back to 1.00 | `CrashSlowMoEmulate=false` |
| V-CC-06 | P2 wreck | `P2 crash over (wrecked ...)`, `P2 wreck camera skipped: ... (crashcam.lua)`, `P2 view -> <name>'s car`, no black half | `CrashCamWreckHold="never"`, `WreckCrashCamHoldMs=0` |
| V-PRE-06 | P2 own-pad checks | `[ignpad] P2 input probe ... verdict=inject` or `P2 check input: watching -> inject (1 silent check starts)`; `P2 IA_Veh_... -> PC event, inject #n`; P2's list advances, summary `errors=0` | `IgnitionPadAssist="off"`, `IgnitionMode="p1game_guestauto"` |
| V-PRE-09 | P1 checks with P1's pad | `P1 check input: watching -> game (its screen reacted ...)`; P1 summary `injected=0` | `IgnitionAssistP1=false` |
| V-PAU-06 | pause menu | `pause menu parts +2000ms`: every part 1.00, `bb_background=blur 10.0`; menu readable | `PauseMenuSettle=false`, `PauseMenuRehost="never"` |

### Session H, track B: 0.6.0 run-G view and pause fixes (2 pads, offline, podrace; added 2026-10-07)
Run G facts these rows test (logs `state/runs/20261007-1217-session-G/`): the screenshots g-pause*.png (10:42:12) show
a pause with NO pause screen at all (`paused, pause menu widget not found yet`, 10:42:09; the probed, re-added
`WBP_PauseRacing` owner=P2 was an earlier pause, 10:41:29); an AI pod as view target renders from inside its engine
(g-w-fix.png); the game's crash camera renders black for P2 even with a valid shot (10:34:07). Remove the test
override `WreckView = "native"` from the game copy's `Scripts/config_user.lua` before these checks.

| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-PAU-07 | guest navigates its pause | SUPERSEDED by V-PAU-15 (0.7.0: owner focus without a rehost; Session I) | — |
| V-PAU-08 | never a pause without a menu | SUPERSEDED by V-PAU-12 (0.7.0 safety net F: repair / resume, never a re-add; Session I) | `PauseLostMenu="probe"` |
| V-WD-19 | watched car camera | P2 wrecks while P1 races: `P2 view -> <AI>'s car ... via own camera, checking (cam active=.. stack=..)`, `watched car camera check n: inside/front`, `... no chase camera ...: view -> rig`; a local human's car: `via own camera (...)`, no check | `WreckCarCam="car"` |
| V-WD-20 | chase rig | `[chasecam] rig spawned for ...`; P2's half shows the watched pod from behind/above, following it smoothly; `rig moved` on the next car; no `chase rig unavailable` | `WreckCarCam="car"` + `WreckSpectateTarget="human"` |
| V-CC-07 | guest crash default | `[crashcam] init: CrashCamGuest=car (effective car)`; every P2 crash `crash camera -> own car view after 0 ms (CrashCamGuest car)` + emulated slow-mo; never a black half | `CrashCamGuest="auto"` |
| V-INP-08 | guest vehicle IMC (F1) | LOADING/PRERACE: `[inputfix] P2 (ControllerId 1) Enhanced Input: IMC_Vehicle_Default added (priority N, from P1 Enhanced Input)` then `P2 Enhanced Input verified: ~19 IA_Veh_* ...`; F9 `enhanced: IA_Veh_*=19 ... state=ok`; front end: `... removed (front end)` | `InputFixGuestEnhanced="off"` |
| V-PRE-06 (0.6.0) | guest checks via its own path | `P2 input probe: ... eiVehicleCtx=ok ... verdict=watching`, `P2 check input: watching -> game`; summary `injected=0 gamePath>0`; P2 ignition `SuccessfulIgnite`; no check flips to Failed right after a correct press | `IgnitionPadAssist="off"`; `InputFixGuestEnhanced="off"` |
| V-PRE-10 | no double pause / input | P2 Start once: exactly one `game paused by P2`; no open-then-close; P2 boost/camera work in the race | `GuestPauseFallback=false` |
| V-VG-01 | view guard | P2 wrecks while P1 races: at most one `[viewguard] P1 is still racing but its view was BP_PlayerFailedCam_C` per 3 s, P1's half back on its car | `ViewGuard=false` |
| V-INP-09 | DLL reload thread | `swgr_inputfilter.status`: `reload_thread=1`, `reloads` grows without input; bind check `all bound` right after the race start without touching a pad | old DLL (`.bak-trackC`) |

### Session I: 0.7.0 run-H UX split (2 pads, offline; a podrace for V-UX-08; added 2026-10-07)
Revision 0.7.0. README §9 "Run-H UX checks" has the same rows with the testcmd lines. All lines are `[uxsplit]` unless
marked `[hud]`. Test order = row order.

| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-UX-00 | idle outside races | boot: `init: messages=route ... hooks only while a split race runs (V-UX-00)`; no `hook on:` line in the menu | — |
| V-UX-01 | guest engine panel on its own car | countdown: `armed (HUD creation, 2 local players): ...; 10 hook(s)`; `remap GetPlayerPawn(self, 0) -> P2's car for WBP_HUD_BotEngineInfo_C (HUD being created) (V-UX-01)`; `[hud] P2 BotEngineInfo: Vehicle State = P2's car (index remap)`; no `[hud] P2 HUD: n binding(s) moved` | `UxSplitIndexRemap=false` |
| V-UX-10 | game's hidden HUD | `[hud] game HUD ... 3 member(s) collapsed [WBP_Hud_PositionMap,Img_1DMap_MidSection,WBP_Hud_Countdown]`; `[hud] game HUD (hidden): 5 binding(s) on P1's car removed`; no triple beep | `UxSplitGameHud=false` |
| V-UX-02 | routed messages | `msg WrongWay by BP_VehicleUIComponent_C (car) = P2 -> HUD_Notification_Container: 4 new copy(ies) (shown P2 x2; hidden P1 x2)`; `msg PerfectLanding ... = P1 -> Hud_Notification_GameFeed: 2 new copy(ies) (shown P1 x1; hidden P2 x1)`; `testPost(2, "PerfectLanding")` returns the same kind of line | `UxSplitMessages="all"` then `"off"` |
| V-UX-03 | full container | `... 0 new copy(ies) ...; 4 full container(s): it waits there; the WrongWay copy already on screen is shared with P1`; `msg <id> (Pn) shown after it waited (...)` | report |
| V-UX-04 | removal for everybody | `RemoveMessage WrongWay by P1: P2 still holds WrongWay -> re-posted for P2 (ok)`; `FlushMessageContainer Hud_Notification_CrashFeed by P1: P2 still holds ... -> re-posted for P2 (ok)` | `UxSplitRepost=false` |
| V-UX-05 | hidden copies expire | dbg `hidden copy of PerfectLanding (P1) left P2's HUD after 5.x s (row minimum 5.0 s)`; never `a stall?` | `UxSplitMsgHide="opacity"` |
| V-UX-06 | race-ending countdown | `unattributed <class> 'Race ending in ..' in Hud_Notification_GameFeed ...: global, kept in every HUD`; both halves show it | report |
| V-UX-07 | last-crash colours | `MPC AfterburnerColor <- last-crash colour by P2's HUD: blocked ...`; `MPC AfterburnerColor write dropped: value still the default` (or `WARN ... restore mode`); `P2 HUD tint: danger (last crash)`; probe `Afterburner=(0.99,0.40,0.07)` | `UxSplitHudColours=false`, `UxSplitDanger="neutral"` |
| V-UX-08 | ramjet colour | `EngageRamjet stopped on P1's BotEngineInfo: icons set, the global ramjet colour kept`; `P1 HUD tint: ramjet`; probe `FadeDir=1.00 FadeProg=-1.00` | `UxSplitRamjetColour=false` |
| V-UX-09 | full-screen effects | `GetFullScreenEffectsEnabled -> false while split ...`; `P2 last life: camera tint in its own view (up to 0.20)`; `P2 system malfunction: camera flash in its own view`; probe `VS_vfx FinalLife=0.00` | `UxSplitFadeMax=0.1`, `UxSplitFullScreenFx=false` |
| V-UX-11 | probe + F9 | `probe MPC ... (V-UX-11)` every 5 s; F9 `uxsplit: armed=true ...` with hook ids and each HUD's containers | — |
| V-UX-12 | radio portrait | `[hud] guest HUDs: radio-chatter portrait hidden ...`; portrait in P1's half only | `UxSplitGuestHolo="keep"` |
| V-HUD-04 | guest lap | `[hud] lap offset calibrated at P1's lap 1: VM 1 - P1 component 1 = 0`; P2 shows LAP 1/N on its first lap | `LapPatch=false` |
| V-UX-13 | hooks gone before travel | `disarmed (phase POSTRACE): 10 hook(s) off; ...` and `[pause] native pre-hook unregistered (phase POSTRACE)` before the results are left; no crash back to the menu; the next race arms again. A results screen that takes no input is the known phase-2 owner problem, not a failure: leave with testcmd `lua U.cdo("/Script/Griffin.Default__UIBlueprintFunctionLibrary"):ReturnToMainMenu(U.world())` | report log + dump |

Integration review, watched during the UX rows: `hook on: /Script/Engine.SubsystemBlueprintLibrary:GetGameInstanceSubsystem
(ids a/b, pre only)`; two racers out within 1.5 s give two `first copy of a per-HUD message: every half` lines; a takedown /
status message is never `shared with` the other player; `MPC ... reset to the default when arming` only on a re-arm with a
red HUD left. Never: `WARN remap: P2 has no car` in a normal race, `callback ... failed`.

**Pause (`pause.lua` 0.7.0, same session; all lines `[pause]`; README §9 "Run-H pause checks" has the How column):**

| Id | Check | Pass | Fallback |
|---|---|---|---|
| (boot) | init / arm | `init 0.7.0: ... PauseCsmHook=true (read state true, trace false) PauseMenuPrecreate=true PauseMenuOwner=pauser ... PauseMenuRehost=never (= never)`; PRERACE: `Menu-layer ZOrder = <z> (dialog layer - 1; ...)`, `split race (2 local players): A=true B=true C=true D=all E=true F=recover G=onpress; ... dialog containers 3; classes WBP_PauseRacing_C, WBP_PlayerMenu_Presentation_C`, `native pre-hook registered: ...ChangeStateTo (ids N/M, ...)`, `pause hook armed (split race, 2 local players)`. Bad: `dialog containers 0`, `RegisterHook(...) failed`, `(not loaded)` | report |
| V-PAU-09 | A1 | `game HUD input unregistered (WBP_Hud_Race_C_<n>, owner P2 (ctrlId 1) = UIManager owner, ...)` once per game-HUD instance | `PauseHudInputGuard=false` |
| V-PAU-11/10 | P2 Start once | `IMC_UI priority -> 500 for P2 (request)`; `request on the pause CSM: kind=pause target=PauseMenu by P2 (P2 Start down) -> HUD inputs off (P1,P2), WBP_PauseRacing_C pre-created for P2 (ctrlId 1) (z=<z>, pauser); IMC_UI -> 500 for P2`; `game paused by P2 (P2 Start down)`; `pre-created WBP_PauseRacing_C (owner P2 (ctrlId 1)) acquired by the CSM after <=33 ms (osm = pause CSM): extra ref released; input mode refresh ok`; probe `owner=P2 (ctrlId 1) pre=ours osm=ok ... focus=P2 imcUi=P1:500,P2:500 ... states=[PauseMenu Paused_Racing] menuLayer=1`; P2's pad navigates, A on RESUME / B / Start again resume; `IMC_UI restored (resume): P2 0`, `pause over (states [Idle]); IMC_UI P2 0`, `HUD inputs back on (P1,P2) ~150-200 ms after resume (pause keys up)`. Bad: `duplicate`, `lost menu`, `not used by the CSM within 500 ms`, `REMOVED`, `osm=nil`, `pre=game`, `focus=none`, `request ... without a pause` | `PauseMenuOwner="p1"`; crash: `PauseHookReadState=false`, then `PauseCsmHook=false` |
| V-PAU-15 | P1 Escape / pad Start | `request ... by P1 (P1 Escape down) -> ..., pre-created for P1 (ctrlId 0) (z=<z>, pauser)`; probe `owner=P1 (ctrlId 0) pre=ours osm=ok focus=P1`; P1 resumes with Enter / A | `PauseMenuOwner="p1"` |
| V-PAU-13 | F3 | P2's menu up > 0.5 s, P1 Escape: ~0.3 s later `P1 Escape while P2's menu is up: resumed from Lua (Idle ok)` | `PauseAnyStartResumes="off"` |
| V-PAU-18 | held Start | P2 holds Start 2 s: ONE `request on the pause CSM` line, no `duplicate` / `lost menu`; release + press resumes | report |
| V-PAU-17 | player menu | P2 Back/View: `request ...: kind=player target=PlayerMenu by P2 (P2 View released) -> ..., WBP_PlayerMenu_Presentation_C pre-created for P2 (ctrlId 1)`, then `acquired by the CSM`; B / View closes it: `pause over (states [Idle])` | report |
| V-PAU-12 | F1 repair (deliberate, `PauseHudInputGuard=false`) | `WARN duplicate ChangeStateTo(PauseMenu) while [PauseMenu Paused_Racing] ...; repair armed`, ~100 ms later `lost menu: [PauseMenu] without sub-state -> ChangeStateTo(CSM_PauseMenus_Paused_Racing) for P2 (repair 1: ok)`, `pause CSM enters Paused_Racing (repair): WBP_PauseRacing_C pre-created for P2 ...`; a usable menu follows | `PauseLostMenu="probe"` |
| V-PAU-14 | dialog | P1-owned pause, EXIT / ABANDON, 3 s, cancel: no `lost menu` while the dialog shows; no `+Dialog1`; `+dialog Dialog:1` only with a real dialog | report |
| V-PAU-16 | G | P1 wrecks while P2 races: `pause CSM gone (...); still racing: P2; PauseRestartCsm onpress`; P2 Start: `pause CSM restarted (P2 Start; still racing: P2): StartCosmeticStateMachine ok` → `request ... by P2 (our call (mod)) ... pre-created for P2` → menu → resume; race end `own pause CSM ended (phase POSTRACE): EndStateMachine ok` | `PauseRestartCsm="off"` |
| (leave) | leaving while paused | EXIT from a guest-opened pause (P1 answers the dialog): `IMC_UI restored (leaving): ...`, `native pre-hook unregistered (leaving (return))`; no crash; guests' pads normal in the front end | report |
| V-PAU-15 (KbP1) | optional | pad 0 (P2) Start: `pre-created for P1 (ctrlId 0) (z=..., KeyboardIsP1 pad shift ctrlId 1 -> 0)`; pad 0 and keyboard navigate | `PauseOwnerPadShift="off"` |

### Session S: 0.11.0 narrow-view HUD (added 2026-10-10)
User: "HUD is bad on screen where width is 1/2, fix that." Design `notes/research/hud-narrow-views.md`; hud.lua header
revision 0.11.0. README §9 "Session S" has the How column. All lines `[hud]`.

| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-HUD-17 | narrow layout (2P side by side, 3P bottom, 4P) | `P2 HUD: narrow view 1920x2160: interior 2000 (scale 0.96), top bar compact, engine row x0.79 (V-HUD-17)`; timer / LAP / POS ~1.8x the 0.10.0 size, no view edge touched, whole engine row visible | `HudNarrowViews="fit"` |
| V-HUD-18 | designer / narrow switch | F8, a guest leaving, one view: `P1 HUD: view 3840x1080, designer layout (V-HUD-18)` and back; no `layout ... failed` | `HudNarrowViews="fit"` |
| V-HUD-19 | `SzB_InteriorSize` keeps the override | `interior 2000 wide, 2000 planned; engine row 2417 wide, 2417 planned (V-HUD-19)`; never `V-HUD-19 FAILED` (narrow layout then off for the session) | `HudNarrowViews="fit"` |

- **Measured 2026-10-10** (2P side by side, the same race restarted once per mode, 1280x720): with `"readable"` the
  timer, LAP and POS are the same size as with `"fit"` (2x crops); only the top bar is pulled together and the engine
  row shrinks to x0.79. Kept off; proposed for removal (README screenshot 22).

### Session T: 0.11.0 RESTART RACE and the guest pause menu (added 2026-10-10, run 20261010-0710-restart-test)
User: "Also add restart race in the menu". Design `notes/research/restart-race.md`; `restart.lua` (G5, FAST after
`pause.poll` and `menubridge.fastTick`), `pause.lua` calls `restart.decorate` (pre-create, menuTick first sight),
`menubridge.lua` 0.11.0 rules. README §9 has the How column.

| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-RST-01 | offered | `RESTART RACE offered in this race (standalone, confirm dialog, sequence direct)`, again after every restart (**PASS**) | `PauseRestart=false` |
| V-RST-02 | the row | `... Btn_RetryRace at 4 of 10 under RESUME (5 row(s) moved below it) ...`, then `row(s) found off 0 ms into the pause, switched on: RetryRace, Stickerbook, Settings, Photomode, Exit, AbandonRun` (LOG, first paused tick); every row black, D-pad walks the list (**PASS**) | `PauseRestartPosition="end"` |
| V-RST-03 | confirm | `restart confirmed by P1 (RetryRace dialog Accept -> ArcadeSubsystem:RequestRestartEvent pre-hook)`; CANCEL silent (**PASS**) | `PauseRestartConfirm="twice"` |
| V-RST-04 | guest | `restart confirmed by P2` after the bridged row and dialog clicks (**PASS**) | — |
| V-RST-06/07 | restart, hook life | `restart #1: RequestResetRace sent from the pause, 36 ms after the confirm`; hook unregistered before LEAVING; same map; loadouts and pilots applied again (**PASS**, 5 restarts) | `PauseRestartSequence="resume"` |
| V-MB-10 | guest's own pause menu | `P2 A -> WBP_PauseRacing_C Btn_RetryRace (owner focus): clicked`; after a restart `P2's native A / B did nothing on its own pause menu (world #9) ...`, Settings A toggles once, `P2 B -> WBP_Settings_C: HandleBack()` (**PASS**) | `MenuBridgeGuestPauseMenu=false` |

Facts found in this run (not in the design):
- A WBP_Vertical_Btn removed from the pause box and added again rebuilds its Slate widget and comes back with
  `GetIsFocusable()` / `IsInteractionEnabled()` false; the game switches the moved rows off once more right after the
  pre-create placement. `restart.enableRows` copies RESUME's state (only ever ON) at placement, every FAST tick for
  1.5 s after the pause starts, and with the 500 ms re-check. Setters in this build: `BP_SetIsFocusable`,
  `BP_SetIsInteractionEnabled` (not `SetIsFocusable` / `SetIsInteractionEnabled`).
- P1 (UI-only input) works the pause menu natively, P1-owned dialog included; B does not close the RetryRace dialog
  (`ShouldGenerateInputActions` false).
- A guest's native menu input works in a race started from the front end and is dead after `RequestResetRace`'s
  seamless travel (A and B; the D-pad still moves its focus). The pause menu keeps RESUME `GetSelected()` while the
  owner's focus moves, so the bridge clicks the owner-focused row first.
- Test trap: Steam's "Steam Controller Welcome" window (a controller connecting) took focus from the SMALL-mode game
  window and every pad input was dropped silently; `niri msg action focus-window --id <game>` brought it back.

### Session U: 0.12.0 UI v2, back prompt, launch hold, opponents' tier (added 2026-10-10, runs 20261010-1209-ui-v2-A to 20261010-1556-rc-0.12)
User: the mod's screens should "look like they belong to the game". Design: the UI v2 design spec
(`notes/design/ui-v2/ui-redesign-final.md`, kept with the project notes): its §13 is the session plan and its §14 the
table of V-FIN-01..16 with their fallbacks; the code's VERIFY comments carry the log lines. Revision 0.12.0.

| Id | Check | Pass | Fallback |
|---|---|---|---|
| V-LCH-07 | launch hold | `[main] launch hold: the front-end pages stop until the race world (V-LCH-07)` once per launch; no crash between START RACE and the race world (**PASS**: five consecutive launches from RACE SETUP with returns to the menu; before the fix 4 of 5 crashed) | none: hard rule 12 |
| V-BP-01 | P1's pad B on a sub-page | OPTIONS: `QuitGame prompt over OPTIONS: answered No (1 click(s), N ms after the post), OPTIONS closed (V-BP-01)`, no prompt left, the tiles show with OPTIONS focused; RACE SETUP: `QuitGame prompt over RACE SETUP: answered No (...), one step back (V-BP-01)`; plain lobby: no `[backprompt]` line, the game's prompt stays (**PASS** on OPTIONS, 72-104 ms after the post, and on RACE SETUP, 102 ms) | `BackPromptAsBack=false` |
| V-RC-27 | opponents' tier | MODE > Opponents on TIER 4: `[perkapply] launch base VBD_035_4Corgi (opponents' tier; humans' empty ability slots are cleared) (V-RC-27)`, then `AI builds (8 AI, launch base VBD_035_4Corgi): PowerLevel min 18 / avg 18.0 / max 18, abilities 2.0, parts 0.0 per AI (V-RC-27)`; TIER 1: launch base `VBD_000_1Mastiff`, PowerLevel 0, no abilities, no parts; every human `in race: build ok, abilities 4/4, crash ok, parts 4/4 live` (**PASS**) | Opponents on TIER 1 |
| V-JOIN-20 | hot-plugged pad (0.12.0 rule) | a pad switched on next to a working P1 pad: `hot-plugged pad ctrlId 3: P1 keeps ctrlId 0, whose pad is still connected (ADD PLAYERS makes the new pad a guest) (V-JOIN-20)` (**PASS**); a pad switched on after P1's own pad disconnected: `hot-plugged pad ctrlId N takes P1 (was ctrlId M; ...): ok (V-JOIN-20)` (no live evidence yet) | `HotplugPadToP1="off"` |
| V-FIN-01..16 | the UI v2 pages | spec §14; the pages were checked at 1280x720, 1920x1080 and 3840x2160, in English, German and French (other game languages not checked yet) | spec §14 (the config.lua keys of Revision 0.12.0 item 11) |

---

## 7. Notes for implementers: superseded draft decisions and pre-agreed alternatives

- Superseded from the old draft (do not reintroduce): `QuickRaceSelected()` (empty in Shipping [RB§2]); unhiding the dev
  strip (gated by `IsNonShipping` [MT§4]); bare `ExecuteInGameThread(fn)` and `LoopAsync` [API§15 #3-4];
  `FindAllOf("PlayerController")` per tick and `PendingKill` checks [API§15 #4-5]; `LoadAsset("<…>_C")` [API§15 #6];
  `if gs.Racers then` on non-race GameStates [API§15 #7]; writing a Lua bool without knowing the type (now known: Bool)
  [API§15 #8]; class-name substring vehicle tests [API§15 #9]; `T.takeOver` without PlayerState adoption and with an
  assumed `SpawnAI` override [PS§8 #1-4]; `assignAll` every second from load [PS§8 #7, NET§9]; `open <map>?listen?port=` on
  the race map as the host path [NET§9, RB§9 #3]; `open <addr>` without travel options [NET§9]; `[/Script/Engine.Engine]`
  net override [NET§9]; F10 binding [API§15 #2]; `bUseSplitscreen` toggled on `ClientRestart` with guests in the front end
  [UI§5 #1]; a hard-coded `WBP_Hud_Race_C` HUD class [HUD§6 #1]; guest HUDs never hidden on pause/results [HUD§6 #3].
- Pre-agreed alternatives if a Session A/B check fails (implement only behind the named switch, never by default):
  - V-LOB-01 fails (the Setting_List root is not the box): build the page root ourselves:
    `box = StaticConstructObject(U.class("/Script/Griffin.FuseVerticalBox"), page.WidgetTree)`, then
    `page.WidgetTree.RootWidget = box` before the page is added (switch `cfg.LobbyRootMode = "own"`, default `"setting_list"`;
    `config.lua` gets this key with that default).
  - V-BLD-01 fails (builder does not work embedded): open the game's own dev screen instead with
    `menu.OwningStateMachine:ChangeStateTo(U.obj("/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_QuickRaceSetup.CSM_FrontEnd_QuickRaceSetup"),
    "SWGRCouch", nil)` and keep the same Go hook (it then fires for that screen's `Custom_EventSetup` instance; accept it
    when our builder is absent) [RB§6a] (switch `cfg.BuilderMode = "embedded"` | `"devscreen"`, default `"embedded"`;
    `config.lua` gets this key).
  - V-JOIN-03 fails with every `JoinFocusTrick`: guests are added with F6/`ADD PLAYER` (no pad detection) and the
    poll only confirms the pad afterwards [UI§4.3 fallback]; no extra switch (F6 already exists).
- Persisted settings never store UObjects, only paths and strings. Nothing in the mod writes the game's own save or
  `GameUserSettings.ini`.
- When the first runtime session answers a VERIFY, update this document (the row in §6 and the module line) before
  changing code, so the design stays the single source of truth.
- **Integration round 1 (static review of scenario traces), contract changes now part of §4.2:** new event
  `"race_enter"`; `St.join.keep`, `St.menu.worldKey`; new config keys (G1 `config.lua`) and the optional
  `config_user.lua`; new functions `ui.registerButton`, `menu_tab.pollTab/onSyncSelection`, `builder.handleGo/onLeavePage`,
  `join.raceTick/pollDevices/onDeviceState`, `hud.manageLocalResults/p1Rehosted`, `launch.init`, `persistShared` /
  `restoreShared` in `join`, `net`, `gfx`, `takeover`, `launch` (hot reload through UE4SS shared variables); `takeover.release(rec,
  leaving)`; `net` calls `phase.markLeaving("servertravel")`; `gfx` applies on the first race phase (not only LOADING) and
  defaults to `GfxApplyMode = "console"`; `builder` unwraps the array returned by `GetQuickplayTracksForVehicleAndPlanet`
  before comparing. New VERIFY ids: V-CORE-11, V-TAB-09, V-TAB-10, V-BLD-06, V-JOIN-09, V-JOIN-10, V-HUD-04b, V-HUD-13,
  V-PAU-03 (and §6 rows for ids that were only in code: V-BLD-05, V-GFX-04/05, V-HUD-02b/02c/11b/12, V-JOIN-08, V-TAB-08,
  V-TKO-11).
- **Integration round 2 (static review of scenario traces), contract changes now part of §4.2:** `St.worldGen` (world
  generation; every per-world "once" check and world-bound timer compares it, never the UWorld address: `net`
  `feWorldGen/raceWorldGen/afterSameWorld`, `util` world-subsystem cache), `St.launch.accepted`, `St.race.singleView`;
  `phase.cancelLeaving`, accepted launches get `cfg.LaunchAcceptedTimeoutMs` and a launch timeout clears
  `St.ui.returnToTab`; `menu_tab.dropMenu` on every race phase / LEAVING / OTHER and on a stale menu at a world change
  (whole menu + click registry + lobby rows forgotten), `ui.onClicked` only in the front end, a menu replaced while our
  tab is open returns to it, `menu_tab.hookSilent` escalates to the tab poll; `takeover.racerPSFor` pawn-first
  (`cfg.RacerPSSource`), `finishIdlePlayerStates` also finishes non-racer human PlayerStates
  (`cfg.FinishNonRacerPlayerStates`); `net` relisten wait needs a rejoin to end in servertravel, race-map relisten
  failure detection, missing-car servertravel only after start + grace, servertravel watchdog; `hud`
  `LocalResultsMode="hide_inactive"`, reversible Memory lap collapse, position patch whenever the racer PS is not the
  PC's; `join` race_enter guard hands cars to the AI past LOADING, hot-reload pad flags, device poll without the
  default device; `builder.restoreFromSettings` class-checks; `config_user.lua` merges `Defaults`; OnUnload no longer
  calls `U.unhookAll`. New VERIFY ids: V-TAB-11, V-LCH-06, V-NET-16.
- **Integration round 3 (static review of scenario traces), contract changes now part of §4.2:** every `cfg` key a
  module reads is defined in `config.lua` (`DeactivateGamePaneOnShow`, `MemoryLapMode`, `FinishUncarriedRacers`,
  `ClientMenuFallback`; `FinishNonRacerPlayerStates` removed) and `config_user.lua` overrides are type/value-checked;
  `TabDetectMode` defaults to `"both"` and `menu_tab.pollWanted()` also polls in `"hook"` mode while the hook is
  missing; `DeviceDetectMode="hook"` keeps an edge-only device-poll watchdog; `U.csmActive(key, findOnly)` (no LoadAsset
  from the polls; `phase` evaluates CSM_PostRace only after the start); `phase` treats a GameState replaced at the same
  UWorld address as a new world; `pause` acts on P1's press only in the race HUD states (not in LocalResults); `hud` lap
  hook trusted only once it fired, Race-variant hook writes only on a BP lap change; `menu_tab` keeps the return flag
  through a pending launch, returns to our tab after the dev screen's own Back, closes stray guests on OTHER entered
  from the menu; `join` race_enter guard also from OTHER, client F7 in a race refused, hot reload persists handed
  guests and `singleView`; `gfx` honours `singleView`; `takeover` resets its per-race state per world / race entry;
  `launch` calls `net.beforeLaunch` on every non-client launch; `net` retries a refused servertravel once then allows
  late takeovers, ends a stage-2 relisten wait without servertravel when late clients have cars, and checks a client's
  front end for a main menu. New VERIFY ids: V-HUD-04c, V-HUD-04d, V-NET-17.
- **Wreck integration (2026-10-07, `wreck.lua`), contract changes now part of §4.2:** new G5 module `wreck` (main.lua
  `MODULES`/`INIT_ORDER` after `present`, `wreck.fastTick` in FAST race phases, `wreck.tick` in MAIN before
  `present.tick`, `PERSIST_MODULES` += `wreck`); new config keys `WreckMode`, `FinishGraceSec` (string `"all"` or a
  number: `config.lua` MIXED override check), `NoWreckMethod`, `WreckSlowMo`, `WreckCinematic`, `WreckSpectateTarget`,
  `WreckSpectateWaitMs`, `WreckViewGuard`, `WreckViewFallback`, `WreckCamMaxDistUU`, `WreckCamBadMs`,
  `WreckFadeClearMs`, `WreckProbe`, `SpectateWidgetMode`; `consts`: `C.BP.PvpSpectate`, `C.ASSET.CSM_Spectating` /
  `CSM_SpectatingInProgress`, `C.E.FailReason`; `hud.manageSpectateWidget()` (P1's `WBP_PVP_Spectate_C` hidden while a
  guest races, next to `manageLocalResults`) and the Remaining-line collapse driven by `St.wreck.hideRemaining`;
  `present` VIEW_RULES list `CSM_RF_SpectatingInProgress` / `Spectating` / `LocalResults` as split; `diag.dump` gains
  a `wreck` section. Design decisions that differ from `wreck-design.md`: slow-mo default `"off"` (the design note
  proposed `"game"`; the task fixed "off while split, config to keep it"), spectate preference = the other local human
  (`WreckSpectateTarget="human"`; the note preferred AI cars for the camera fallback), `WreckMode` values `"spectate"
  | "noWreck" | "game"` (the note's `"reset"`/`"reset_all"` became `NoWreckMethod`), `FinishGraceSec = "all"` (the
  note's `HumanFinishGraceSec = 0`), `WreckedGuestHud` not implemented (guest HUD kept, the game's default). New
  VERIFY ids: V-WD-01..08, V-WD-11, V-WD-12, V-WD-14.
- **UX split integration (0.7.0, `uxsplit.lua`), contract changes now part of §4.2:** new G5 module `uxsplit`
  (`MODULES` after `hud`, `INIT_ORDER` before `hud`, FAST after `viewguard`, MAIN after `hud.tick`); `hud.ensureGuest`
  brackets `AddToPlayerScreen` with `uxsplit.hudCreating/hudCreated`; new `hud.notifEntries()` / `hud.gameHudWidget()`;
  `hud.calibrateLap` only after P1's first crossing, `patchGuest` writes the guest lap from the race start with offset 0
  until then; `rebindToGuestCar` strips (not moves) the game's hidden HUD's bindings; `sweepOrphanHuds` skips the
  UIManager's HUD; `diag.dump` gains a `uxsplit` section. Design decisions that differ from the research notes: one module
  instead of `msgroute.lua` + `uxvis.lua`; config keys `UxSplit*` instead of `MsgRoute*` / `Ux*`; the index remap uses
  the GetPlayerPawn POST-hook return override (no `idx:set()`: only Lua-call rewrites were verified in run H) and only
  GetPlayerPawn is hooked (BotEngineInfo is the only caller that benefits); the MPC block rewrites `Collection` to nil in
  the pre-hook (no re-entrant KML call unless the read-back shows the rewrite did not take); parameterised messages are
  never re-posted (a TMap<FString, FText> built from Lua would go through FText::SetString on zeroed memory); hooks are
  registered per race (not once at boot) because of the run-H crash rule; the camera-fade emulation backs off whenever
  another fade runs (read through wreck.lua's custom fade properties). New VERIFY ids: V-UX-00..13.
- **Pause integration (0.7.0, `pause.lua` layers A-G), contract changes now part of §4.2:** the G5 pause contract is
  replaced (the pre-0.7.0 polls are kept); config.lua declares every key pause.lua reads (the 0.7.0 draft read 12 keys
  config.lua did not define, so `config_user.lua` rejected every documented fallback as "unknown key"); `PauseMenuOwner`
  accepts `"p1"` / `"game"`; `PauseMenuRehost` defaults to `"never"`. Design decisions that differ from the research:
  B reads `newState` by default (run H's probe read Blueprint callers' params correctly thousands of times; research
  §6.2 said ctx only: `PauseHookReadState=false` is the fallback); the hook is a raw `RegisterHook` per split race (not
  `U.hook` at boot), like uxsplit's. Integration review additions: a request no pause followed is undone after 600 ms
  (`requestWatch`); `St.hud.p1hud` validated before any member access; diag F9 `pause` section. New VERIFY ids:
  V-PAU-09..18; V-PAU-04/05/07/08 superseded.
