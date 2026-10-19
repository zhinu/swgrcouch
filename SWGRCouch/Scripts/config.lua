-- SWGRCouch / config.lua  (G1 Core)
-- Developer constants, timings and fallback selectors.
-- Do not edit: put overrides in Scripts/config_user.lua (`return { P1HudMode = "clone" }`, loaded at the end of this
-- file; a syntax error there is logged and ignored), then restart the game (Ctrl+F11 / RestartCurrentMod only with cfg.AllowHotReload).
-- User choices (layout, graphics, network address, last race, ...) are NOT here: they live in
-- <ModDir>/settings.txt (settings.lua). `Defaults` below are only the values used when that file lacks a key.
-- Each fallback selector names the VERIFY id (ARCHITECTURE.md §6) whose failure it answers.

local cfg = {}

---------------------------------------------------------------------------------------------------- Core
cfg.Debug               = false     -- U.dbg output + debug-only hooks in diag. 0.12.0: off by default (review hyg-6);
                                    --   set Debug = true in config_user.lua for a bug report
cfg.SkipRaceIntro       = false     -- true: Race.SpeedyFlow.Intro/.Movies = 1 (race intro cinematics and movies skipped;
                                    --   the game's own dev shortcut, set once per boot by testcmd.lua)
cfg.ViewGuard           = true      -- viewguard.lua: a still-racing local player whose view is another player's DNF
                                    --   "failed" cinematic (BP_PlayerFailedCam_C) is put back on its own car (run G)
cfg.GuestFinishCinematic = "end"    -- couch-finish (live 2026-10-17 #9/#15/#16): a guest who finishes while another
                                    --   local human still races gets his finish cinematic chain ENDED at once (the
                                    --   game cuts the FIRST local player's camera to it: BP_PlayerFinishedCam_C on
                                    --   P1's view, P1 drove blind and crashed / went out of bounds). "keep" = native
cfg.ViewGuardForeignMs  = 30000     -- couch-finish: for this long after another local human finished / wrecked, a
                                    --   still-racing player's view on any camera actor that is not his car or his own
                                    --   crash camera goes back to his car at once (0 = off)
cfg.MenuBridge          = true      -- menubridge.lua (0.7.1): a guest-owned menu (pause, player menu, settings...) takes
                                    --   its owner's A/B, and a shared post-race screen anyone's A, by clicking the
                                    --   selected button when the game did not react (run I: P2's A was dropped)
cfg.MenuBridgeP1Pause   = true      -- couch-finish (#16): P1's own race pause in a couch race takes his A / B through
                                    --   the bridge when the game did not react (live: dead after a guest's finish)
cfg.MenuBridgeWaitMs    = 150      -- the game's own reaction window before the bridge clicks   VERIFY(V-MB-01)
cfg.CouchMapPauseBridge = true      -- couch-livefix r3: P1's START on the paddock run map (owned by a guest / dormant PC,
                                    --   whose router gets no START) opens the game's paddock pause (OnPauseAction)
-- 0.8.0 (pause phase 2, menubridge.lua): screens opened FROM a pause belong to the pause controller; each key turns its
-- part off alone (pause.lua side: PauseSubScreen* / PauseDialogGuestUi in the Pause section).
cfg.MenuBridgeGuestNative = "skip"  -- "skip": a guest's presses on its OWN screen are not bridged while pause.lua boosts
                                    --   its IMC_UI (run I: native input works then; bridging as well toggled a Settings
                                    --   row twice) | "bridge" (the 0.7.1 behaviour)                  VERIFY(V-MB-04)
cfg.UiMokiWidthScale      = 1.0     -- 0.12.0: the Moki (display font) width estimate x this (the table matched Slate at
                                    --   size 100; small text at 720p runs a few % wider: cards2 keeps a margin)
cfg.BackPromptHide        = true    -- 0.13.0: that QUIT GAME prompt is made invisible on its first frame and the page steps
                                    -- back at once (no flash of the quit dialog); false = visible until answered (0.12)
cfg.BackPromptAsBack      = true    -- 0.12.0: P1's pad B on OPTIONS / RACE SETUP (which before the first race only reaches the
                                    --   game: its "QUIT GAME?" prompt, ACCEPT focused) answers that prompt No and goes
                                    --   back instead (backprompt.lua) | false = the game's prompt stays     VERIFY(V-BP-01)
cfg.SubPageLock           = true    -- #21 (playtest 2026-10-17): a FREE MODE sub-page (RACE SETUP, GRAND PRIX, GALAXY RUN,
                                    --   COUCH CAMPAIGN, OPTIONS) owns the screen: the main-menu tab strip is hidden and
                                    --   LB / RB do nothing there; the footer's "Exit Game" reads SubPageBackLabel
                                    --   (menu_tab.lua) | false = LB / RB switch the game's tabs everywhere (0.16)
cfg.SubPageBackLabel      = "Back"  -- #21: the footer's B label on a sub-page (B goes back there: backprompt.lua)
cfg.UiPreload             = true    -- #23: the GRAND PRIX page's art (race thumbnails, preview / podium art) is loaded in
                                    --   the background, one texture per UiPreloadEveryMs, and held by hidden images for
                                    --   the page's life (no LoadAsset when a view opens or a track steps) | false = on use
cfg.UiPreloadEveryMs      = 150     -- #23: one background texture load per this many ms (each is one LoadAsset)
cfg.BackPromptKeepArmed   = true    -- #23: backprompt's two native hooks stay registered for the whole front-end visit once
                                    --   a sub-page armed them (no RegisterHook per sub-page open) | false = per visit
cfg.MenuBridgeGuestPauseMenu = true -- 0.11.0: a guest's A / B on its OWN pause menu, and its B on the screens opened from
                                    --   it (Settings, Logbook), are bridged even while its UI input counts as native
                                    --   (hotfix build: the guest's A / B never acted natively; each of those presses closes
                                    --   or covers the screen, so the re-check never acts twice); A clicks the row the
                                    --   owner has focused | false = the 0.10 behaviour                   VERIFY(V-MB-10)
cfg.MenuBridgeDialogs     = true    -- the pause controller answers the P1-owned confirm dialogs (EXIT TO MAIN MENU,
                                    --   ABANDON TOUR...): A = focused / default button (else Accept), B = the last
                                    --   button (Cancel), D-pad moves the dialog owner's focus; post-race any player  V-MB-05
cfg.MenuBridgeBack        = true    -- B on a bridged screen without RESUME: the screen's own back path (HandleBack, else
                                    --   OnCancelAction, else BackToPreviousState)                     VERIFY(V-MB-03)
cfg.MenuBridgeControllerFallback = true -- the pause controller's A/B (and Game+UI input) on a pause screen another player
                                    --   owns: a page the pre-create missed, the Logbook while PauseSubScreenHook is
                                    --   false                                                         VERIFY(V-MB-03)
cfg.MenuBridgeSharedFocus = true    -- 0.9.0: on a results screen another player owns, P1 (kept UI-only by the game) gets
                                    --   Slate focus on the screen's own target so its A clicks natively  VERIFY(V-MB-07)
cfg.MenuBridgeProfileOwner = true   -- front end after a split race: the main menu's profile card (top right, "Player 2")
                                    --   owned by a guest is re-owned by P1 (SetOwningPlayer + name / rank / platform
                                    --   refresh); the activatable main menu itself is never re-owned  VERIFY(V-MB-06)
-- 0.10.0 feowner.lua: the front-end main menu belongs to P1 also after a split race (notes/research/menu-owner.md)
cfg.FrontEndMenuOwner     = "p1"       -- "p1": pre-create the main menu for P1; "game": the UIManager picks (last guest)
cfg.FrontEndMenuPrecreate = true       -- c1: on BP_Csm_FrontEnd_PickPrimaryMode (arrival after a race)   V-FEO-01/02
cfg.FrontEndSubScreens    = true       -- c3: Settings (+ pages), Credits, Stickerbook, inspect screens and their returns
                                       --   are pre-created for P1 too                              V-FEO-11/13
                                       --   0.13.3: also the ARCADE / SCENARIOS inspect screens and the LOGBOOK
                                       --   (ChangeToState)                                          V-FEO-14
cfg.FrontEndStageMenu     = true       -- 0.13.3 c4: while the LOGBOOK shows, a hidden P1 main menu waits in the Menu
                                       --   layer for its native Back (else the return gives the menu to the guest) V-FEO-15
cfg.FrontEndRepairPages   = true       -- 0.13.3 c5: a Settings page (View Credits, EULA, ...) owned by a guest is left and
                                       --   re-entered for P1 (one short flash of Settings)                  V-FEO-16
cfg.FrontEndOwnerBracket  = true       -- 0.13.3 c6: the return from Settings empties the Menu layer and builds a new main
                                       --   menu in the same ChangeStateTo: the guests' LocalPlayer is hidden from the owner
                                       --   helper for that one call (else the menu goes to the guest)     V-FEO-17
cfg.FrontEndHideMultiplayer = true     -- g: hide + disable the Multiplayer tab while split-screen guests exist  V-FEO-07
cfg.FrontEndMenuZ         = 500        -- Menu layer z of the pre-created menu
cfg.MenuBridgeRawA        = false     -- 0.10.0: on a shared results screen a non-owner's A is also read from its raw
                                    -- vehicle input. Off: P1's raw input never shows the A there (V-MB-08 failed live)
cfg.MenuBridgeP1Catcher   = true      -- 0.10.1: on a shared screen another player owns, P1's A is read from an invisible
                                    -- plain Button added to that screen and focused for P1 (Slate still routes P1's A to
                                    -- its focus; live probe 2026-10-10)                              VERIFY(V-MB-09)
cfg.TestCommands        = false     -- testcmd.lua: run <ModDir>/test.cmd blocks (unattended live tests); off for players
cfg.CouchGarageNative     = true      -- a guest's GARAGE = a turn in the game's own full-screen garage (3D car, Choose Model /
                                     --   Edit Vehicle / Edit Livery driven by HIS pad; his model, livery and kit parts saved to
                                     --   his seat and class; P1's garage backed up and restored exactly around it;
                                     --   garagenative.lua). false = the compact panel (also the fallback when a turn fails)
cfg.CouchGarageExclusive  = true      -- during that turn P1's pad does nothing: the guest's PC is parked (P1's pad reaches no
                                     --   player) and P1's Slate focus sits on an invisible sink. false = the first version
                                     --   (P1's pad on the guest's PC)
cfg.CouchGarageNoPurchase = true      -- during that turn the options P1's profile does not own are shown LOCKED: the guest's
                                     --   A / hold cannot buy them with P1's profile ("LOCKED - P1'S PROFILE"); owned ones equip
cfg.CouchGarageHideRoot  = true      -- couch-livefix r3: after that turn the game's garage root (deactivated, still drawn over
                                     --   the paddock) is collapsed; its visibility comes back when the game activates it again
cfg.CouchRaceExitUnlock  = true      -- couch-livefix r2: the race pause's EXIT TO MAIN MENU, locked by the game in a campaign
                                     --   race outside the results, is unlocked while 2+ local players exist (the game's
                                     --   QuitToMenu confirm; CONTINUE resumes the run at its last save). false = the lock.
                                     --   couch-fix61 (AUTO-148): never in a field test (its confirm is dead there, as solo)
cfg.CouchRecapWaitUnlocks = true     -- couch-fix61 (AUTO-149): P1's A on the act-end recap waits until the game bound its
                                     --   own CONTINUE (after the NEW UNLOCK screens; 30 s at most). false = continue at once
                                     --   couch-fix62 (AUTO-151): readiness read from the recap's sections (8 s quiet
                                     --   fallback when unreadable)
cfg.CouchGarageUndoForeign = true     -- during that turn a tab change / screen back / garage close that comes without the
                                     --   guest's press (P1's pad through CommonUI) is put back
cfg.DebugAiKey          = false     -- DEBUG (off in releases; test copies: true): in races a local player's L3 (left stick click) toggles
                                     --   the game's AI on his own car ("P1: AI DRIVING" / "P1: YOU DRIVE"); debugai.lua
cfg.TestBots            = false     -- with TestCommands (test harness only): true / "all" = every local car driven by the game's
                                     --   AI as soon as RACING, re-applied after a respawn; "guests" = P2..P4 only (P1 = the human); "p1" = P1 only (the human plays P2); false / "off" = none
cfg.TestBotsCrit        = "resolve" -- couch-fix50/55 (AUTO-129, test harness only): what a TestBots car does in a CRITICAL
                                     --   MALFUNCTION. "resolve" = Server_ResolveCriticalMalfunction 4 s in (no fault is ever
                                     --   queued). The others drive the game's own check with a B press injected through
                                     --   Enhanced Input every frame (testcmd.lua, couch-fix55 decode): "timeout" = hold,
                                     --   release, no press -> TimedOut (ApplyFaulyOnTimeout: a fault); "pass" = one press in
                                     --   the success window (ApplyFaulyOnSuccess: a fault); "fail" = an early press (no
                                     --   fault: a control); "crash" = the component's crash handler (Vehicle.Crash.Tumble)
                                     --   in the check (ApplyFaulyOnCrashOut); "crashpre" = no press, the crash handler
                                     --   TestBotsCritCrashMs in (ApplyFaulyOnPreTestCrash). Not "resolve": still in the
                                     --   malfunction after TestBotsCritGiveUpMs -> the resolve (a bot never sits out the race)
cfg.TestBotsCritGiveUpMs = 30000
cfg.TestBotsCritCrashMs  = 1500      -- "crashpre": the crash call this long into the malfunction
cfg.AllowHotReload      = false     -- 0.10.0: Ctrl+F11 / "couch reload" (RestartCurrentMod). Off: UE4SS's lua_close of a
                                    -- state other threads still use can crash the game (RE-UE4SS #1445); restart instead
cfg.TestCommandPollMs   = 300
cfg.Gauntlet            = false     -- with TestCommands (test harness only): couch-gauntlet starts at boot (or resumes
                                    --   <ModDir>/gauntlet.txt): every node pick of the couch run takes the next race type
                                    --   (gauntlet.lua, docs/dev/gauntlet.md)
cfg.GauntletToast       = true      -- #82: "GAUNTLET: next = <step>" toast to P1 when the run map shows the armed nodes
cfg.FastPollMs          = 33        -- FAST loop (join edge poll, click poll, pause poll)   VERIFY(V-CORE-02)
cfg.MainPollMs          = 250       -- MAIN loop (phase, lobby, roster, takeover, hud, nametags, net)
cfg.SlowPollMs          = 1000      -- SLOW loop (pending hooks, menu ensure, net slow tick, diag)
cfg.UseKslIsValid       = true      -- U.alive also asks KismetSystemLibrary:IsValid   VERIFY(V-CORE-05)
cfg.SubsystemLookup     = "sbl"     -- "sbl" (SubsystemBlueprintLibrary) | "findfirst"  VERIFY(V-CORE-06)
cfg.LoopErrorLogEveryMs = 5000      -- a failing loop logs at most one error line per this period
cfg.DiagPeriodicMs      = 0         -- > 0: diag.dump() at that interval
-- couch-racegc (gctune.lua): the mod's Lua garbage collector. Every UE4SS wrapper is a finalizable userdata and Lua 5.4's
-- incremental collector walks all of them in one indivisible atomic step: the 10-20 ms race stalls of 2026-10-15.
cfg.LuaGcMode           = "generational" -- "generational" (default: minor collections walk only the young garbage) |
                                    --   "incremental" (LuaGcPause / LuaGcStepMul / LuaGcStepSize) | "off" (Lua's defaults)
                                    --                                                                 VERIFY(V-GC-01)
cfg.LuaGcMinorMul       = 1         -- generational: a minor collection after the heap grew this % (smaller = shorter,
                                    --   more frequent minors; tools/gcbench.lua, 34 MB live: 1 -> 0.4 ms worst, 3 -> 1 ms)
cfg.LuaGcMajorMul       = 400       -- generational: a major (full) collection only after the old generation grew this %
                                    --   (outside races); the load-screen collects below reset that base
cfg.LuaGcRaceMajorMul   = 1000      -- the same in PRERACE / RACING / POSTRACE (Lua stores it /4 in a byte: 1020 max): no major
                                    --   collection inside a race unless the heap grew ~10x (gcbench: 400 s of heavy
                                    --   mid-lived garbage, no major at 1000; 75-140 ms majors at 400)
cfg.LuaGcPause          = 200       -- incremental only (Lua's default 200)
cfg.LuaGcStepMul        = 100       -- incremental only (Lua's default 100)
cfg.LuaGcStepSize       = 13        -- incremental only (log2 bytes, Lua's default 13 = 8 KB)
cfg.LuaGcFullCollectGrowth = 25     -- a full collect at the load screens (phase LOADING / FRONTEND / OTHER) when the heap
                                    --   grew this % since the last one; < 0 = never                  VERIFY(V-GC-02)

-- FIRST LIVE RUN (2026-10-06): Blueprint-function hooks REGISTER but NEVER FIRE in this build (WBP_FE_MainMenu_C
-- CustomEvent/RegisterTabs, WBP_Common_Btn_C:BP_OnClicked, the builder's Go BndEvt, the HUD lap counters'
-- UpdateCurrentLap). Every selector below that names a "hook" path therefore defaults to its poll path, and the
-- modules keep the BP hooks only as optional extras that the polls de-duplicate against. Native /Script/ hooks are
-- not affected.

---------------------------------------------------------------------------------------------------- Boot (fastboot.lua)
-- NO-INTRO mode: no hook, a game-thread loop calls the game's own native functions (README "No-intro mode").
-- Never skipped: EULA / privacy policy / save-version / save-corrupted / first-boot settings screens.
cfg.FastBoot                     = true     -- master switch                                 VERIFY(V-FB-01..05)
cfg.FastBootSkipTitle            = true     -- Fuse/brand idents + PRESS A: AdvancePreLoadIfPossible as soon as ready
cfg.FastBootSkipPhotosensitivity = true     -- epilepsy warning (only when HasExperiencedBootFlow() is true)
cfg.FastBootEpic                 = "off"    -- "off": profile bUseEosLinking + settings mirror forced false (no browser
                                            --   Epic login, no SOCIAL OVERLAY modal; persisted like the modal's ACCEPT)
                                            --   | "keep" (game behaviour)
cfg.FastBootEosDialog            = true     -- fallback at the main menu: DisableEpicLinking + RemoveMessage(
                                            --   EosRequirementsFail) during FastBootMenuGraceMs
cfg.FastBootStopIdentMovies      = true     -- Close() the title widget's two media players before advancing
cfg.FastBootPollMs               = 50       -- boot watcher period (stops itself at the main menu + grace)
cfg.FastBootWindowMs             = 180000   -- give up this long after arming
cfg.FastBootSettleMs             = 150      -- a boot screen must be up this long before it is skipped
cfg.FastBootEpicWaitMs           = 3000     -- title ready but no ProfileMetaData found: advance anyway after this
cfg.FastBootMenuGraceMs          = 20000    -- keep watching the main menu (EOS fallback) this long
cfg.FastBootPhotoBlind           = false    -- photosensitivity state active but widget not found: ReturnToMainMenu
                                            --   anyway                                          VERIFY(V-FB-02)

---------------------------------------------------------------------------------------------------- Tab / UI
cfg.ClickMode                 = "poll"          -- "poll" (default; selected-toggle trick, pad A via CommonUI + mouse) |
                                                --   "hook" (BP_OnClicked post-hook: does not fire in this build)  VERIFY(V-LOB-03)
cfg.LobbyPadNav               = true            -- poll-based P1 navigation on the lobby (d-pad/stick up/down, left/
                                                --   right on value rows, A = activate) with its own highlight; runs in
                                                --   every ClickMode (CommonUI focus never reached our rows)  VERIFY(V-LOB-08)
cfg.LobbyNavHighlight         = "both"          -- "both" (row style + CommonUI focus) | "style" (never touch focus) |
                                                --   "focus" (CommonUI focus only, the BP's own focus look)    VERIFY(V-LOB-08)
cfg.LobbyNavMarker            = ""              -- text prefix of the highlighted row ("" = "> " only when the row style
                                                --   cannot be applied)
cfg.LobbyNavKeyboard          = "always"        -- keyboard arrows/Enter also navigate: "always" | "kbp1" (only with
                                                --   KeyboardIsP1) | "never"
cfg.LobbyNavRepeatDelayMs     = 400             -- held up/down: first repeat after this
cfg.LobbyNavRepeatMs          = 140             -- held up/down: repeat period
cfg.LobbyNavArmMs             = 250             -- A is ignored this long after the lobby is shown (the press that
                                                --   opened the tab must not click a row)
cfg.LobbyNavDedupMs           = 350             -- one row action per press (pad-nav A + CommonUI/mouse click poll)
cfg.LobbyFocusKeepMs          = 3000            -- after a page is shown (or the main menu is active again): re-give
                                                --   P1's CommonUI focus to the lobby row / builder button every 200 ms
                                                --   for this long while nothing of the page holds it  VERIFY(V-TAB-07)
cfg.MenuSwitcherNoTransition  = true            -- WS_ScreenContent:SetDisableTransitionAnimation(true): page switches
                                                --   are immediate, so focus set right after SetActiveWidget lands
                                                --   (the animated switcher swaps its Slate child only at the end of the
                                                --   transition)                                     VERIFY(V-TAB-07)
cfg.LobbyRowInvert            = true            -- rows use the BPs' IsInvert style (dark text on the light page; the
                                                --   default beige-on-beige rows were unreadable)        VERIFY(V-LOB-07)
cfg.TabReactivateMinMs        = 1000            -- tab poll: the main menu inactive at least this long and active again
                                                --   while our tab was open = "came back from another screen" -> return
                                                --   to our tab (poll replacement of the RegisterTabs hook)  VERIFY(V-TAB-14)
cfg.ReturnToSplitTab          = true            -- reopen our tab after a race / relisten     VERIFY(V-TAB-06)
cfg.RestoreGamePaneOnTabLeave = false           -- force the game's pane back by index        VERIFY(V-TAB-05)
cfg.OurTabSyncFix             = "clear"         -- "clear" (ClearSelection on our tab button after the Campaign-pane
                                                --   sync highlighted it, so a click re-broadcasts) | "off"  VERIFY(V-TAB-13)
cfg.DeactivateGamePaneOnShow  = false           -- DeactivateWidget the game pane covered by our page (reactivated
                                                --   when our tab is left)                        VERIFY(V-TAB-12)
cfg.LaunchOnGo                = false           -- builder Go launches at once
cfg.BuilderBackButton         = true            -- add "< BACK TO LOBBY" to the builder grid  VERIFY(V-BLD-03)
cfg.BuilderBackRow            = 3
cfg.BuilderBackCol            = 0
cfg.LobbyRootMode             = "setting_list"  -- "setting_list" | "own" (own FuseVerticalBox, §7)  VERIFY(V-LOB-01)
cfg.BuilderMode               = "embedded"      -- "embedded" | "devscreen" (CSM_FrontEnd_QuickRaceSetup, §7)  VERIFY(V-BLD-01)
cfg.BuilderDevscreenExit      = "auto"          -- devscreen BACK: "auto" (ReturnToMainMenu, then cosmetic ChangeStateTo
                                                --   PrimaryModeSelect if the dev screen is still active) | "native" |
                                                --   "csm"                                                VERIFY(V-BLD-01)
cfg.GoMode                    = "hook"          -- OBSOLETE (kept so old config_user.lua files still load): Go is
                                                --   detected by builder.poll (BuilderGoPoll); the BndEvt hook is an
                                                --   optional extra in every mode
cfg.BuilderAdopt              = "live"          -- "live" (a complete, valid pick on the embedded builder becomes the
                                                --   race at once; Go/BACK only return) | "go" (only Go adopts; leaving
                                                --   adopts while no Go was ever detected)              VERIFY(V-BLD-06)
cfg.BuilderGoPoll             = true            -- Btn_Go made selectable+toggleable; builder.poll reads GetSelected()
                                                --   edges (pad A / mouse on Go)                        VERIFY(V-BLD-06)
cfg.TabDetectMode             = "both"          -- the MAIN GetActiveTab poll ALWAYS runs (the required detector; BP
                                                --   hooks do not fire). "both"/"hook": the CustomEvent hook stays an
                                                --   extra the poll de-duplicates against | "poll": hook ignored  VERIFY(V-TAB-10)

---------------------------------------------------------------------------------------------------- Join
cfg.MaxLocalPlayers = 4
cfg.JoinPollMs      = 33            -- documentation of the FAST period used by join.poll (§1.3); FAST runs it
cfg.JoinArmMs       = 300           -- ignore presses this soon after a dormant guest was created
cfg.JoinWithStart   = true          -- Start also joins (besides A)
cfg.GuestCreate     = "join"        -- couch-livefix: "join" = a pad gets its LocalPlayer only when it presses A (the
                                    --   DLL's pad watch; no dormant guest: their views / screens broke races and the
                                    --   skip prompt, join.lua LAZY JOIN), falls back to "connected" without the pad
                                    --   watch | "connected" = dormant guests for every plugged pad | "all" (always
                                    --   MaxLocalPlayers-1, the pre-2026-10-07 behaviour)    VERIFY(V-JOIN-11/13)
cfg.GuestRemoval    = "never"       -- EVERY RemovePlayer on a guest leaves a dangling input-mode listener, and the
                                    --   next control-mapping rebuild (any map load, any new PlayerController) calls
                                    --   into freed memory: the 2026-10-06 crash (join.lua GUEST LIFECYCLE). "never"
                                    --   (the only safe value: guests are created on ADD PLAYERS and kept until the
                                    --   game exits) | "launch" / "always": CRASH REPRODUCERS ONLY, honoured only
                                    --   together with GuestRemovalUnsafe = true (else logged as an ERROR and treated
                                    --   as "never")                                         VERIFY(V-JOIN-11/12)
cfg.GuestRemovalUnsafe = false      -- true = really call RemovePlayer for GuestRemoval "launch"/"always" (expect a crash)
cfg.GuestOptIn      = true          -- guests (LocalPlayers for pads 2-4) are created only after the lobby's ADD PLAYERS
                                    --   row (confirmed) or F6 (pressed twice): opening the SPLIT SCREEN tab alone
                                    --   never creates one. false = the pre-2026-10-07 behaviour (created on open)
cfg.LeaveHoldMs     = 1000          -- KeyboardIsP1: the pad-0 guest (ControllerId 1) leaves by holding Start this long
                                    --   (its B is P1's CommonUI Back)                       VERIFY(V-JOIN-09)
cfg.JoinFocusTrick  = "none"        -- "none" | "userfocus" | "viewport" (Slate focus) | "gameandui" (fallback for a
                                    --   viewport that ignores input in UI-only mode: SetInputMode_GameAndUIEx on P1
                                    --   while the lobby is up, UI-only restored on close/commit)   VERIFY(V-JOIN-03)
cfg.JoinInputModeReapplyMs = 0      -- "gameandui": also re-apply every N ms while the lobby shows (0 = only on open
                                    --   and each lobby (re)show); use if the game puts UI-only back   VERIFY(V-JOIN-03)
cfg.JoinButtons     = "a_or_start"  -- "a_or_start" (Start only with JoinWithStart) | "start" (A never joins)  VERIFY(V-JOIN-06)
                                    -- KeyboardIsP1: the guest on pad 1 (ctrlId 1) always joins with Start only  VERIFY(V-JOIN-09)
cfg.DeviceDetectMode = "hook"       -- "hook" (OnUserInputDeviceChanged; the SLOW InputDeviceLibrary poll only
                                    --   watches for edges the hook missed: no baseline report, an edge is applied
                                    --   only when no hook event came in the last 3 s) | "both" (hook + full poll,
                                    --   baseline included) | "poll" (poll only)            VERIFY(V-JOIN-10)
cfg.HotplugPadToP1  = "front"       -- 0.8.1: a pad that CONNECTS while the game runs and belongs to no local player
                                    --   becomes P1's controller (a Moonlight/Sunshine pad comes back with every client
                                    --   connection, often behind other pads). "front" (in the front end; a pad that
                                    --   connects mid-race takes P1 at the next front end) | "always" (at once, mid-race
                                    --   too) | "off". Never with couch pads enabled (ADD PLAYERS: it joins as a guest)
                                    --   0.12.0 (review hyg-3): a new pad takes P1 only while P1's own pad is gone (its
                                    --   disconnect was seen), never with KeyboardIsP1; a pad switched on next to a
                                    --   working P1 pad stays free for ADD PLAYERS
                                    --                                                       VERIFY(V-JOIN-20)

---------------------------------------------------------------------------------------------------- Launch
cfg.ConditionPassMode      = "table"   -- "table" ({TagName=FName}) | "trackdefault"      VERIFY(V-LCH-01)
cfg.SelectVehicleForGuests = false     -- Server_SelectVehicle for each guest before launch  VERIFY(V-LCH-05)
cfg.GrowGridInMemory       = false     -- raise the PlayerChoice grid entry by the deficit   VERIFY(V-LCH-04)
cfg.LaunchTimeoutMs        = 30000     -- LAUNCHING without leaving the front-end world -> "LAUNCH TIMED OUT"
cfg.LaunchAcceptedTimeoutMs = 180000   -- same, once the game accepted the launch (PrimaryFlow == QuickRace) VERIFY(V-LCH-06)

---------------------------------------------------------------------------------------------------- HUD
cfg.P1HudMode             = "clone"    -- "clone" (0.4.0 default: P1 gets its own P1-owned HUD in P1's view, the game's
                                       --   viewport-wide HUD stays alive at opacity 0) | "rehost" (the game's HUD moved
                                       --   into P1's view) | "leave"                           VERIFY(V-HUD-02/02c/02d)
cfg.P1CloneInput          = false      -- "clone": keep the P1 clone's own input bindings (default off: the game's
                                       --   hidden HUD keeps P1's pause; on = if P1's pause stops working)  VERIFY(V-HUD-02d)
cfg.GuestHudZOrder        = 10
cfg.HudFitInterior        = true       -- 0.8.2: the race HUD's interior (top bar, centre, engine row: 3620 units wide)
                                       --   scales down to fit the player's view instead of losing both ends of the top bar
                                       --   (0.11.0: by the view WIDTH, ScaleToFitX); false = no HUD layout work at all
                                       --                                                      VERIFY(V-HUD-15)
cfg.HudNarrowViews        = "fit"      -- 0.11.0 ("HUD is bad on screen where width is 1/2"; later "not sure it is needed": off
                                       --   by default). "readable": a view narrower than
                                       --   HudNarrowBelow (2P side by side, 3P bottom, 4P) gets a narrower interior (~2000
                                       --   instead of 3620) so timer / LAP / POS show at ~0.96 of their full-width size
                                       --   instead of 0.53, with a compact top bar and the engine row shrunk to fit |
                                       --   "fit" (0.8.2: the whole HUD scaled to the view, 0.53 in a half-width view)
                                       --                                                VERIFY(V-HUD-17/18/19)
cfg.HudNarrowBelow        = 3000       -- view width in UI units (a full 16:9 width is 3840) below which a view is narrow
cfg.HudNarrowScale        = 1.0        -- HUD size in a narrow view relative to a full-width view (values above 1 count as
                                       --   1); capped so the top bar keeps clear of the view edges: 0.96 in a 16:9 half
                                       --   or quarter. 0.85 = smaller HUD, engine row less shrunk           VERIFY(V-HUD-17)
cfg.HudNarrowTopBar       = "compact"  -- narrow views: "compact" (timer / LAP / POS 197 units further in, brackets and
                                       --   shadow 394 shorter, P1's 1D map at 0.6) | "native" (the designer bar: the HUD
                                       --   is then capped at view width / 2340, 0.82 in a 16:9 half)
cfg.HudNarrowHolo         = "hide"     -- the radio-chatter portrait in narrow views: "hide" (collapsed: engine row at 0.76
                                       --   in 16:9) | "keep" (engine row at 0.66). Guest HUDs follow UxSplitGuestHolo first
cfg.LapPatch              = true       --                                                   VERIFY(V-HUD-04)
cfg.MemoryLapMode         = "collapse" -- Memory HUD guest lap counters: "collapse" (default: always collapsed - what
                                       --   happens in this build anyway, BP hooks never fire; the Memory HUD only
                                       --   shows in campaign memories / bUseMemoryHud arcade events) | "hook" (opt-in:
                                       --   rewritten from the UpdateCurrentLap post-hook every frame once it fires,
                                       --   collapsed until then)                                    VERIFY(V-HUD-04c)
cfg.GuestHudCollapse      = { "WBP_Hud_PositionMap", "Img_1DMap_MidSection", "WBP_Hud_BestLapTime",
                              "WBP_Hud_EventTakedownCounter", "WBP_Hud_EventRamjetCounter", "WBP_Hud_EventBonusTime" }
                                       -- members of WBP_HUD_RaceInfo [HUD§1.2] that show P1's (RaceEventVM) values in a
                                       --   guest HUD; 0.7.0 adds the arcade ramjet-distance / bonus-time counters
                                       --   (ux-split-inventory §2)
cfg.GuestHudNotifications = "keep"     -- "keep" | "remove"                                 VERIFY(V-HUD-08)
cfg.GuestMarkers          = "keep"     -- "keep" | "collapse"                               VERIFY(V-HUD-09)
cfg.GuestBotEngineFix     = true       -- guest boost/ramjet/throttle icons pushed from the guest's car on change
                                       --   (turns itself off per HUD on the first failure; hud.lua also re-points the
                                       --   HUD's car delegates to the guest car)              VERIFY(V-HUD-10)
cfg.HudFallbackAfterMs    = 4000       -- game race HUD not found this long in a HUD state: guest HUDs are created from
                                       --   the loaded HUD class anyway (session B: P2 had no HUD)  VERIFY(V-HUD-02c)
cfg.HudFallbackP1Clone    = false      -- in that fallback also give P1 a clone (the game's unseen viewport-wide HUD
                                       --   cannot be hidden then: P1's data would show twice)
cfg.HudSearchFallback     = true       -- FindAllOf("FuseHudWidget") every 2 s if UIManager fails  VERIFY(V-HUD-01)
cfg.HudVisibilityMode     = "csm"      -- "csm" | "always"                                  VERIFY(V-HUD-05)
cfg.HudGuestTimer         = true       -- 0.13.0 (#35): once P1 is out of the race the game's event timer stops for everyone;
                                         -- the mod writes the race time into the HUD of each guest still racing
cfg.LocalResultsMode      = "hide"     -- P1 finished, guests still racing: WBP_PostRace_Info_C is "hide"-n until every
                                       --   local human finished | "hide_inactive" (hide + DeactivateWidget while hidden:
                                       --   its CommonUI bindings/input config stop acting on P1's pad) | "rehost"-ed into
                                       --   P1's view | "leave"                                        VERIFY(V-HUD-13)
cfg.ForceCarTags          = false      -- set UI.UseScreenSpaceCarTags 1 before the markers initialise  VERIFY(V-HUD-11b)
cfg.HudOutPlayers         = "hide"     -- a local player out of the race (wrecked / spectating) gets its HUD hidden (run E:
                                       --   P2's frozen HUD stayed over its spectate view) | "keep". A player who FINISHED
                                       --   keeps its HUD. Photo mode hides every HUD we host   VERIFY(V-HUD-14/15/16)
cfg.HudProgress           = true       -- #38 (progress.lua): every guest's HUD gets the race-progress strip at its top
                                       --   centre (the cars ahead / behind on the track, the lap / finish flag) from his
                                       --   own car; in a mission-instances race P1's too, each showing his own set only
                                       --                                                V-HUD-PR1/PR2/PR3
cfg.HudProgressMs         = 33         -- strip update period (ms; the FAST loop runs every 33)
cfg.HudProgressScale      = "p1"       -- "p1": the guests' strips use the scale of P1's own (native) strip, read from it
                                       --   | "fixed": HudProgressHalfLap of a lap each side of the middle
cfg.HudProgressHalfLap    = 0.12       -- the strip's half width in laps while P1's scale is unknown (or "fixed")
cfg.HudProgressSpan       = 0.9        -- share of the native map's 980-unit box the strip's window spans
cfg.HudProgressRound      = true       -- pills drawn as rounded boxes (false: plain rectangles)
cfg.HudProgressColour     = { R = 1.0, G = 0.55, B = 0.12, A = 1 }   -- AI cars' pills, the lap tick and flag
cfg.HudProgressHumanColour = { R = 1.0, G = 1.0, B = 1.0, A = 1 }    -- the other local players' pills
cfg.HudProgressFinishColour = { R = 1.0, G = 1.0, B = 1.0, A = 1 }   -- the flag when the line is the finish

---------------------------------------------------------------------------------------------------- UX split (uxsplit.lua, 0.7.0)
-- Run H: "System malfunction / perfect landing and other screen. Are shared between players. Each ux should be fully
-- autonomous". Every part only works while a SPLIT race runs (>= 2 local players, PRERACE/RACING); its native hooks are
-- registered then and removed at POSTRACE / leaving (never across a map change). Each key turns one part off alone.
-- notes/research/ux-split-messages.md, ux-split-visuals.md, ux-split-inventory.md.
cfg.UxSplitIndexRemap     = true       -- a guest HUD's WBP_HUD_BotEngineInfo gets the GUEST's car where it asks for
                                       --   GetPlayerPawn(self, 0) at Construct (ramjet / boost / throttle icons, critical-
                                       --   malfunction dimming, "Vehicle State"): GetPlayerPawn post-hook returning the
                                       --   guest pawn for our guest HUDs only (never P1's or the game's HUD)  VERIFY(V-UX-01)
cfg.UxSplitMessages       = "route"    -- race messages (SYSTEM MALFUNCTION, PERFECT LANDING, WRONG WAY, ...): "route" (each
                                       --   copy only in its own player's HUD; posters attributed through their
                                       --   GetGameInstanceSubsystem call) | "all" (attribution + log only: every HUD keeps
                                       --   every copy, the game's behaviour) | "off" (no messaging hook)  VERIFY(V-UX-02..06)
cfg.UxSplitMsgHide        = "collapse" -- how a copy in another player's HUD is hidden: "collapse" (the feed closes up) |
                                       --   "opacity" (if a collapsed copy ever stalls the queue)      VERIFY(V-UX-05)
cfg.UxSplitRepost         = true       -- RemoveMessage(id) / FlushMessageContainer remove EVERY player's copy: re-post a
                                       --   plain message (WrongWay, OutOfBounds, Vulnerable, crash feed) for the players
                                       --   that still hold it                                          VERIFY(V-UX-04)
cfg.UxSplitDanger         = "own"      -- danger visuals: "own" (the global last-crash colours / ramjet sweep / full-screen
                                       --   effects kept neutral; each player's danger shown on its OWN HUD (tint) and
                                       --   camera (fade)) | "neutral" (kept neutral, nothing per player) | "off" (game:
                                       --   one player's danger on every view)                       VERIFY(V-UX-07..09)
cfg.UxSplitHudColours     = true       -- part of UxSplitDanger: MPC_HUD_Parameters Afterburner/HighThreat/MalfunctionColor
                                       --   never written by a HUD's last crash; "own": that player's HUD tinted red  V-UX-07
cfg.UxSplitRamjetColour   = true       -- 0.13.0: pinned orange ALWAYS (no global blue; the bars fill via HudRamjetBarStyle
                                       --   "afterburner", immune to the pin). Part of UxSplitDanger: BotEngineInfo's Engage/DisengageRamjet animations (global
                                       --   FadeDirection sweep) stopped, icons set, MPC pinned; "own": HUD tinted blue  V-UX-08
cfg.UxSplitRamjetFiringBlue = false     -- 0.13.0: every HUD in the ramjet colours only while a local car fires its ramjet (the
                                       --   bar's fill needs it); R3 / charging keeps them orange. false = always orange V-UX-08
cfg.UxSplitFullScreenFx   = true       -- part of UxSplitDanger: the game's full-screen danger post-process (last life,
                                       --   malfunction flash, concussion / wreck blur, frost, heat, blind: one actor
                                       --   following one player, drawn over every view) off while split and not paused;
                                       --   "own": last life / system malfunction shown with that player's camera fade  V-UX-09
cfg.UxSplitFadeMax        = 0.2        -- "own": final-life camera tint strength (> 0; capped at 0.45: crashcam clears held
                                       --   fades >= 0.5)
cfg.UxSplitGameHud        = true       -- P1HudMode "clone": the game's own hidden race HUD (owned by the UIManager's
                                       --   player, P2) loses its 1D map / countdown (global map writes, a third countdown
                                       --   beep) and its BotEngineInfo bindings on P1's car are removed  VERIFY(V-UX-10)
cfg.UxSplitGuestHolo      = "hide"     -- the radio-chatter portrait (WBP_Hud_CharacterHolo: ONE dialogue line for
                                       --   everybody) in guest HUDs: "hide" | "keep"                 VERIFY(V-UX-12)
cfg.UxSplitProbeMs        = 0          -- > 0: one "[uxsplit] probe" line at this period while armed (0 = off)  V-UX-11
                                       --   0.12.0: off by default (research probe; 5000 for a test session)
                                       --   (0.8.0: also the period of the "[subsplit] probe" line, V-SUB-07)

---------------------------------------------------------------------------------------------------- UX split: subtitles (subsplit.lua, 0.8.0)
-- Run I: radio chatter for one player ("BIDDY BLAS: *laughs* Who taught you to race?") was drawn in P2's half: the game
-- has ONE subtitle widget (FuseDialogueManagerSubsystem.SubtitlesWidget, P1-owned, whole window). Same hook rules as
-- uxsplit: native hooks only while a split race runs (PRERACE/RACING, 2+ local players, not single view), removed at
-- POSTRACE / leaving. notes/research/subtitles-split.md. Audio and trigger cooldowns stay shared.
cfg.UxSplitSubtitles      = "route"    -- "route" (each line in its player's half; a line for everybody in every half) |
                                       --   "log" (attribution + log lines only, nothing moves) | "off" (no hook at all:
                                       --   the switch if the hooks cost frame time)                 VERIFY(V-SUB-01..06)
cfg.UxSplitSubDetect      = "hook"     -- how a new line is seen: "hook" (UIManager:GetCurrentSubtitleConfig post-hook, the
                                       --   frame it appears) | "poll" (FAST poll of the widget text, 1-2 frames late; the
                                       --   poll is always the fallback)                              VERIFY(V-SUB-03)
cfg.UxSplitSubBoth        = "clone"    -- a line for everybody: "clone" (the game's box in P1's half + one mod-made
                                       --   WBP_Subtitles per guest half) | "game" (left where the game puts it)  V-SUB-06
cfg.UxSplitSubUnmatched   = "both"     -- a line no request, rule or speaker car explains: "both" | "p1"
cfg.UxSplitSubPosterHook  = true       -- SubsystemBlueprintLibrary:GetWorldSubsystem pre-hook (engine-wide: EVERY Blueprint
                                       --   world-subsystem lookup) naming the pod that asked for a line. false: requests
                                       --   have no poster (lines go by the both-rules, ability hits, the speaker's car,
                                       --   UxSplitSubUnmatched; 6 hooks instead of 7). Turn it off first if the probe's
                                       --   "wss N/s" costs frame time                                VERIFY(V-SUB-07)
cfg.UxSplitSubAbilityHook = true       -- VehicleNarrativeComponent:OnPlayerHitTargetWithAbility hook: ability-hit lines go
                                       --   to the hitter / hit player (false: the poster rule)       VERIFY(V-SUB-08)
cfg.UxSplitSubPendingMs   = 8000       -- a dialogue request can match a line up to this long after its due time (> 0; the
                                       --   window waits while paused)
cfg.UxSplitSubAiRadiusUU  = 10000      -- an AI pod's line goes to the nearest local human car within this distance (> 0;
                                       --   the Blueprint's 100 m), else P1
cfg.UxSplitSubSideScale   = 0.75       -- box scale in half-width views (side by side, 3P bottom row, 4P grid) (> 0; above
                                       --   1 counts as 1)
cfg.UxSplitSubHalfFrac    = "auto"     -- height of the box bottom above its view's bottom, as a fraction 0..1 of the view
                                       --   height; "auto" = pad / window height = the single-view look (1080p top/bottom:
                                       --   225 su). Lower it if the box covers a half's bottom HUD  VERIFY(V-SUB-04)

---------------------------------------------------------------------------------------------------- Presentation (present.lua)
-- Feedback 2026-10-07 (session B): the track intro / cinematics showed in P1's (top) view only, the pre-flight checks
-- (ignition minigame) for P1 only. notes/research/presentation.md.
cfg.PresentOutroP1Hud     = true       -- 0.13.0: the post-race full-screen view shows P1's race HUD only (the guests'
                                       -- stacked on top showed the last player's "You came Nth")
cfg.WreckKeepRaceMix      = true       -- 0.13.0: P1 wrecked / finished while guests race: the game's post-race audio mix
                                       -- (CBM_PostEvent ducks every race sound) is put back to the race mix  V-WR-MIX
cfg.OutRacerAudioMute     = true       -- #80: a local player OUT of the race (eliminated / wrecked / finished) while another
                                       --   still races: his car's audio components are silenced (his own camera sits in it:
                                       --   engine / airflow / wind loops covered the whole mix). Back at the race end  V-WR-AUDIO
cfg.HudAfterburnerDrive   = true       -- 0.13.0: split races: each guest's boost (afterburner) bar shows its own car's
                                       -- energy (the game's gauge function reads player 0 only)              V-HUD-AB1
cfg.HudRamjetBarStyle     = "game"     -- 0.13.0: the game's two-box ramjet shader; its fill renders under the orange pin
                                       --   with FadeProgress pinned +1 (matrix test). "afterburner" = plain fill  V-HUD-RJ2
cfg.HudRamjetDiag         = false      -- DIAG (2026-10-15): one "RJDIAG" log line per player per second while the ramjet moves
cfg.HudRamjetDrive        = true       -- 0.13.0: split races: each player's ramjet bar shows its car's ramjet heat (the
                                       -- bar's own update shows nothing in the mod's HUDs)
cfg.HudGuestRamjetFix     = true       -- 0.13.0: a guest's ramjet bar / overheat widgets bound to the guest's car (they
                                       -- were never bound: the guest HUD exists before the car)
cfg.PresentPodiumDedupe   = true       -- 0.13.0: one podium hologram after a split race (the game spawns one per player)
cfg.PresentFromMain       = true       -- main.lua initialises and ticks present.lua (false: hud.lua drives it, the
                                       --   pre-integration wiring)
cfg.PresentViewMode       = "auto"     -- "auto": ONE full-screen view during loading, track intro, grid intro, side bets,
                                       --   intermission and results; split views from the ignition/countdown to the
                                       --   finish | "split": split from LOADING to the end (0.3 behaviour)  VERIFY(V-PRE-01)
cfg.SplitDormantViews     = true       -- couch-livefix r2: in a race only P1 and the JOINED guests hold a view; a dormant
                                       --   local player (a pad plugged in, never joined) gets none (no joined guest: ONE
                                       --   view; else its view rect is emptied, split.lua). false = every local player
cfg.SplitDormantClamp     = false      -- couch-livefix r3 EXPERIMENT: GameViewportClient.MaxSplitscreenPlayers = joined views.
                                       --   Live: set and restored fine, but the game's CommonGameViewportClient still drew
                                       --   4 quadrants - no effect on this build; kept off
cfg.IgnitionProbeHook     = false      -- UNUSED since 0.5.1 (ignpad has no hook; the TestPreflightCheckInput hook crashed run F)
cfg.IgnitionMode          = "auto"     -- pre-flight checks (ignition.lua + ignpad.lua; session E "the screens don't
                                       --   respond to gamepads", run F "ignition game still doesn't work"): "auto"
                                       --   (default again in 0.5.1: touches NO soft pointer in Lua - own screen per
                                       --   player in its own view, each player's OWN pad drives its checks: the game's
                                       --   path when it delivers (P1), else the mod calls that player's own PC action
                                       --   event InpActEvt_IA_Veh_* with the IA object; checks nobody does time out
                                       --   after ~5 s) | "perplayer" (alias) | "simple" ("auto" + the game's simple
                                       --   sequences for everybody) | "p1game_guestauto" (FALLBACK: the game's own
                                       --   screen for P1 with P1's pad; guests' checks time out) | "complete" (own
                                       --   screens, nobody assisted) | "off" (game behaviour: P1's screen only)
                                       --   VERIFY(V-PRE-02/03/06/07/08/09)
cfg.IgnitionSoftComplete  = false      -- "p1game_guestauto" / "complete": the mod completes the checks through the
                                       --   soft-keyed PreFlightChecksByAction map (SOFT POINTERS: two UE4SS crashes in
                                       --   run F; did not work in F3). Explicit opt-in only; false = they time out
cfg.IgnitionSilentPresses = 1          -- ignpad, guests: silent check starts (no screen reaction within
                                       --   IgnitionPadAssistWindowMs) before the mod replays that guest's presses
cfg.IgnitionSilentPressesP1 = 3        -- the same for P1 (its game path works: never doubled), on 2+ different actions;
                                       --   0.6.0: also a guest whose own Enhanced Input path is expected (F1)
cfg.IgnitionAssistP1      = true       -- false: P1's presses are never replayed (P1 = the game's path only)  V-PRE-09
cfg.IgnitionMapProbe      = true       -- read each PC's EnhancedActionMappings once per ignition (input probe line)
cfg.IgnitionFixPcComp     = true       -- before a replay, the PC's cached "Pre Flight Check Component" is made the
                                       --   player's own (SetupIgnitionBindings, else written)
cfg.IgnitionPadAssist     = "auto"     -- ignpad: "auto" (a check press the game's own path did not deliver within
                                       --   IgnitionPadAssistWindowMs is replayed with TestPreflightCheckInput; delivered
                                       --   presses are never doubled) | "always" | "off" (log only)   VERIFY(V-PRE-06/09)
cfg.ViewRearmP1          = true       -- 0.13.0: split race: ~1 s after the start P1's chase camera is re-armed (it stayed in its
                                       --   rest pose until P1's first crash: no speed pull-back / FOV)        V-VG-REARM
cfg.RaceCritAssist       = "p1"       -- 0.13.0: split race, B during a critical malfunction calls the player's own recover
                                       --   event: "p1" (P1's native path fails in split) | "all" | "off"     V-PRE-CRIT
cfg.IgnitionPadAssistWindowMs = 250    -- see IgnitionPadAssist
cfg.IgnitionPadPrompts    = "pads"     -- "pads": a pad player's CommonInput type is set to Gamepad while the checks run
                                       --   (P1 showed keyboard/mouse prompts) | "off"         VERIFY(V-PRE-07)
cfg.IgnitionFixedKeys     = "guests"   -- the ignition copies' input-action widgets get the player's pad key as fixed
                                       --   display key: "guests" | "all" | "off" (if the icons look wrong)  VERIFY(V-PRE-07)
cfg.IgnitionView          = "split"    -- "split" (each view shows its own checks) | "single" (one view during ignition)
cfg.IgnitionSimple        = false      -- true: simple pre-flight sequences for EVERY local player (the game's
                                       --   "Simple Pre-Race Checks" setting, applied to all alike)  VERIFY(V-PRE-05)
cfg.IgnitionZOrder        = 5          -- player-screen Z order of the per-player ignition screens
cfg.IgnitionCopyInput     = false      -- keep the copies' IA_Veh_Pause binding (a toggle: on = double pause risk)
cfg.IgnitionInjectDelayMs = 120        -- 0.6.0 (F1): a guest whose own Enhanced Input path is expected waits this long
                                       --   before a replay, so the game's own reaction is seen first (no double input)
cfg.IgnitionMapReprobeMs  = 1000       -- 0.6.0: EnhancedActionMappings re-probed this often until the checks start
cfg.GfxSingleViewCvars    = { "r.ScreenPercentage" }  -- cvars that get the user's value back while the race runs on
                                       --   one view (the split preset's 50 % would blur full-screen cinematics) and
                                       --   the preset value at the split; false = never touched   VERIFY(V-GFX-07)

---------------------------------------------------------------------------------------------------- Names (nametags.lua)
cfg.GuestNameMode         = "names"    -- "names": every guest PlayerState gets GuestNames[pnum-1] (feedback: "Name of
                                       --   the racer the same" - guests shared P1's Steam name) | "off"   VERIFY(V-NAM-01)
cfg.GuestNames            = { "Player 2", "Player 3", "Player 4" }   -- names of P2, P3, P4
cfg.GuestPilots           = { "DA_Racer_Protege", "DA_Racer_Nomad", "DA_Racer_Star", "DA_Racer_Rager",
                              "DA_Racer_Veteran", "DA_Racer_Mercenary", "DA_Racer_Thrall", "DA_Racer_ElegantProfessional",
                              "DA_Racer_QuietStrength", "DA_Racer_InnerHonour", "DA_Racer_Ghost", "DA_Racer_Mentor" }
                                       -- guests' pilots (RacerDef names or paths): each guest gets the first one no
                                       --   racer uses (P1 keeps its own); false = off       VERIFY(V-NAM-03)
cfg.GuestNameMethod       = "auto"     -- "auto" (rpc -> gamemode -> direct while the name does not stick) | "rpc" |
                                       --   "gamemode" | "direct"                               VERIFY(V-NAM-01)
cfg.GuestNameAdopted      = true       -- also rename an adopted AI PlayerState (takeover)
cfg.NameTagLabel          = "pnum"     -- name tags over local humans' cars: "pnum" ("P2", or the slot's custom name
                                       --   when OPTIONS > Player names / settings Name<n> sets one) | "name" ("Player 2")
                                       --   | "both" ("P2 Player 2")
-- Custom names per slot (FREE MODE > OPTIONS > PLAYER NAMES, settings.txt Name1..Name4, 'couch set Name2 Jules'):
-- empty = the default above (P1: its own profile name; P2-P4: GuestNames). They replace GuestNames for the guests'
-- PlayerStates and, for P1, its PlayerState name in this mod's races (restored in the front end).  VERIFY(V-NAM-04)
cfg.PlayerNameMaxChars    = 16         -- longest custom name (characters; longer settings.txt values are cut)
cfg.PlayerNameP1          = true       -- false: Name1 only labels P1's name tag, P1's PlayerState keeps the profile name

---------------------------------------------------------------------------------------------------- Input isolation (inputfix.lua)
-- Feedback 2026-10-07: "KbM controlled the two screens (possibly 1 gamepad controlled both)". Every human car read
-- P1's raw input subsystem, and every raw subsystem recorded every device. notes/research/input-isolation.md.
cfg.InputFixMode          = "auto"     -- "auto" (bind each car to its owner + native DLL filter; kbsplit when the DLL
cfg.InputFixP1VehicleOverUi = true    -- 0.9.0: while P1 races in a split race, P1's vehicle IMCs sit just above IMC_UI
                                       --   (the game keeps IMC_UI at 500 for P1: LB / R3 / d-pad did nothing); back
                                       --   at once on a pause, photo mode or race end                 VERIFY(V-INP-09)
                                       --   is not active) | "native" | "kbsplit" (Lua only: keyboard vs pads isolated,
                                       --   two pads still share) | "bind" | "off"              VERIFY(V-INP-01..06)
cfg.InputFixNativeScope   = "race"     -- "race": the DLL filter is enabled only LOADING..POSTRACE | "always"
cfg.InputFixGuestContexts = "fill"     -- "fill": a guest raw subsystem without a vehicle pad mapping gets one | "leave"
cfg.InputFixKbSplitP1     = "kbp1"     -- kbsplit removes P1's pad mappings: "kbp1" (only with KeyboardIsP1) | "always" |
                                       --   "never"
cfg.InputFixOwnLoopMs     = 250        -- inputfix's own poll period (0 = only main's MAIN-loop call)
cfg.InputFixDiagEveryMs   = 0          -- > 0: inputfix.dump() at that period while racing
cfg.InputFixGuestEnhanced = "add"     -- 0.6.0 (run G F1, ROOT CAUSE of dead guest actions): every guest's
                                       --   EnhancedInputLocalPlayerSubsystem gets P1's vehicle pad IMC (Default /
                                       --   Alternative, never Keyboard), verified by its IA_Veh_* count | "off" (0.5.1)
                                       --   VERIFY(V-INP-08)
cfg.InputFixGuestEnhancedPriority = 1  -- priority when P1's own priority cannot be read
cfg.InputFixGuestEnhancedRemove = true -- front end: the contexts the mod added are removed again

---------------------------------------------------------------------------------------------------- UI v2 (theme.lua, 0.12.0)
-- Workflow ui-v2 (2026-10-10, the user: screens that "look like they belong to the game"); binding spec
-- notes/design/ui-v2/ui-redesign-final.md (§12.3 keys, §14 V-FIN checks). The FREE MODE lobby, OPTIONS, RACE SETUP and
-- the RACERS cards drawn with the game's own parts (theme.lua tokens + builders, cards2.lua). The keys whose default
-- changed with v2 (CardW / CardGap / CardH / CardRowW, SetupCMapVideoW / Background / MapW / MapH) still read their
-- 0.11.0 values while UiStyle = "classic" (cfg.UiClassic, resolved at the end of this file).
cfg.UiStyle               = "v2"       -- "v2" | "classic" (the 0.11.0 lobby rows, setup header / crumb / footer and
                                       --   cards.lua); read at page build: a live switch shows when the page is re-opened
cfg.InputModeDebounceMs   = 500        -- P1's input type (pad | mouse + keyboard; KeyboardIsP1 = mouse) must be stable
                                       --   this long before the command row and P1's READY card switch (> 0)  V-FIN-11
cfg.StatusPillMs          = 5000       -- a transient status-pill message shows this long (> 0); the START gate, "all
                                       --   ready" and LAUNCHING are sticky until cleared                     VERIFY(V-FIN-12)
cfg.PreviewBackdrop       = "studio"   -- photo-bay backdrop inside the capture (vpreview.lua, §10): "studio" (STUDIO back
                                       --   plane + lit floor; SetupPreviewExposure forced "fixed") | "scenario"
                                       --   (T_UI_Scenario_Bg plane, inherited exposure) | "cutout" (no live render: the
                                       --   class cut-out on a STUDIO fill)                                   VERIFY(V-FIN-05)
cfg.UiPageOrigin          = nil        -- unset = measured. {x, y, w, h} (or {x = , y = , w = , h = }) in screen su:
                                       --   overrides theme.pageGeometry (measured from the main menu's layout, fallback
                                       --   128, 240, 3584, 1756)                                             VERIFY(V-FIN-01)
-- theme.lua fallback selectors: one per V-FIN check whose fallback is a different build (not §12.3 keys)
cfg.UiTitleWidget         = "game"     -- page title: "game" (WBP_Screen_Title) | "text" (Moki 103.5 + RUST slash + RUST
                                       --   tag box)                                                          VERIFY(V-FIN-03)
cfg.UiTitleBoxH           = 150        -- SizeBox height around WBP_Screen_Title (> 0; 256 when the title is clipped) V-FIN-03
cfg.UiHeroPill            = "backer"   -- command-row pills: "backer" (WBP_CommonButtonBacker_Pill) | "painted"
                                       --   (MI_UI_Pill_Generic + MI_UI_Pill_Btn_Hero(_Thick) images)         VERIFY(V-FIN-16)
cfg.StatusPillPlace       = "screen"   -- status pill: "screen" (the game's toast place: from the screen's left edge,
                                       --   centre y 2079) | "page" (inside the page at x 128, left of the command row)
                                       --                                                                     VERIFY(V-FIN-12)
cfg.UiFontMaterials       = true       -- SDF print materials on titles and pills (MI_UI_SDF_Font_*); false = plain fonts
                                       --                                                                   VERIFY(V-PARTS-02)
-- the other v2 modules' fallback selectors and knobs (integration 0.12.0: every key a v2 module reads is defined here)
cfg.UiTraitGlyph          = "decorator" -- CLASS info panel traits (setup.lua): "decorator" (WBP_VehicleTrait.RT_Desc draws
                                       --   the <action/> pad glyph itself) | "runs" (the mod's own "Use" + X glyph on an
                                       --   AMBER disc + text run in VB_DescLayout)                         VERIFY(V-FIN-08)
cfg.UiCondTint            = true       -- CONDITIONS posters after the first tinted by a MI_UI_Squircle_TextureMask MID
                                       --   (setup.lua); false = the untinted art (the title still names it) VERIFY(V-FIN-07)
cfg.CardFigureTint        = "mid"      -- pod pilots' body on the empty poster (cards2.lua): "mid" (MI_UI_Squircle_TextureMask
                                       --   MID) | "plain" (a plain image tint #C9B98A; also taken by itself when the MID
                                       --   fails)                                                          VERIFY(V-FIN-07)
cfg.CardStripe            = true       -- the rotated player stripe on the scenario art (cards2.lua); false = the straight
                                       --   6-su hue rule alone                                             VERIFY(V-FIN-06)
cfg.CardStripeAngle       = 34         -- the stripe's SetRenderTransformAngle in degrees (positive = clockwise: it leans
                                       --   like the poster's own stripes; -34 if it leans the other way)   VERIFY(V-FIN-06)
cfg.PreviewStudioGain     = 1          -- studio back plane = STUDIO x this (vpreview.lua): a number > 0 or {r, g, b}, each
                                       --   > 0; the calibration line suggests a value (vpreview.calibrate()) VERIFY(V-FIN-05)
cfg.PreviewCalibrate      = false      -- 0.12.0 (review hyg-8): true = each bay reads its backdrop corner once (up to
                                       --   two GPU readbacks) and logs "PASS" or a PreviewStudioGain value (V-FIN-05);
                                       --   a test session switch: vpreview.calibrate() re-arms the read, which runs
                                       --   only while this is true
cfg.PreviewStudioFloor    = true       -- studio rung: the lit floor plane under the model (contact shadow); false drops it
                                       --   (frame cost)                                                    VERIFY(V-FIN-14)

---------------------------------------------------------------------------------------------------- Race setup (setup.lua, vehicles.lua)
-- Feedback 2026-10-07: class first, planet list with video, per-player vehicle choice, max AI.
-- notes/research/race-setup.md.
cfg.SetupMode             = "setup"    -- CHOOSE RACE opens: "setup" (RACE SETUP flow) | "builder" (the dev race builder;
                                       --   always reachable through the lobby's ADVANCED row)  VERIFY(V-SET-01)
cfg.SetupGridMode         = "typed"    -- full grid: "typed" (PlayerChoice x<humans> + <class> x<rest>) | "playerchoice"
                                       --   (PlayerChoice x<max>, AI classes fixed in the recipe) | "off" (the mode
                                       --   asset's own grid: GMV_Race = 5 racers)               VERIFY(V-SET-06)
cfg.SetupMaxRacers        = 12         -- speeder grid limit, humans included (game max: PvpLiveDataConfig
                                       --   MaxRacersInAnEvent = 12; more is untested)
cfg.SetupMaxRacersPlane   = 8          -- podracer grid limit (MaxRacersInAPvpPlaneEvent = 8)
cfg.SetupPerPlayerBuild   = true       -- each guest races the build it picked (false: everybody races P1's)  VERIFY(V-SET-10)
cfg.SetupPerPlayerBuildArrays = false  -- also copy the build's slot ARRAYS (abilities, upgrades, affixes) into the
                                       --   guest's build state (validated element by element; default off until
                                       --   V-SET-10 is seen working with the scalars: VehicleBuildDef, PowerLevel...)
cfg.SetupInRaceOverride   = true       -- repeat each human's model with Client_SetOverrideVehicleRecipe in the race
                                       --   (LOADING, retried until applied)                  VERIFY(V-SET-11)
cfg.SetupInRaceOverridePrerace = false -- also call it on PRERACE for a human it never reached during LOADING (the
                                       --   car already exists: may respawn it)               VERIFY(V-SET-11)
cfg.SetupVideo            = true       -- planet arrival video in the setup's media area (false: still images)  V-SET-02
cfg.SetupVideoVolume      = -1         -- >= 0: SetVolume on the UI movie player while the setup plays a planet video
cfg.SetupVideoSettleMs    = 250        -- 0.10.0: a new planet video opens once the selection is still this long (0 = at once)
cfg.SetupTatooine         = true       -- Tatooine (podracers only) in the planet list
cfg.SetupAskCondition     = true       -- CONDITIONS step when a track has several (false: the track's first)
cfg.SetupTrackSet         = "arcade"   -- 0.10.0 which tracks the setup offers (notes/research/track-whitelist.md):
                                       --   "quickrace" = the game's Quick Race + Quick Podrace pools, "arcade" = + the
                                       --   Arcade's race tracks, "game" = + Multiplayer Tour + Podracing Tour, "all" =
                                       --   every TrackDef the dev filter returns (0.9.x: Prologue, debug and campaign
                                       --   copies included)                                          VERIFY(V-TRK-01..06)
cfg.SetupTrackArcadePods  = false      -- 0.10.0 also offer the Arcade's pod tracks (The Galactic League Championship,
                                       --   Sebulba's Challenge): the game races them with 1-2 pods; 8 pods on
                                       --   TRAK_WHP_PLANE_FWD crashed at PRERACE (V-TRK-08, 2026-10-09)
cfg.SetupTrackPoolConds   = true       -- 0.10.0 offer only the conditions the game's pool gives a track (no MEMORY
                                       --   conditions on pods, Scorching only on the _HARD Jakku tracks)
cfg.SetupTrackDedupe      = true       -- one row per track (run E: "MOS ESPA SPEEDWAY (BGL_PLANE_FWD)" several times):
                                       --   display names, reverse/variants marked; false = every TrackDef the game
                                       --   returns (duplicates marked with their key)              VERIFY(V-SET-12)
cfg.VehicleNameSource     = "load"     -- 0.12.0 the game's model names (vehicles.modelName = TH_<Model>.ItemName, read
                                       --   once per class): "load" (resident themes at once, the others LoadAsset one per
                                       --   250 ms) | "find" (resident themes only) | "table" (the decoded English names)
                                       --                                                                    VERIFY(V-FIN-10)
cfg.SetupDebugBuilds      = false      -- also list the DEBUG build tiers
cfg.SetupAllBuilds        = false      -- list every quick-race build (ability tests, trailer builds)
cfg.SetupListMax          = 16         -- option rows in the list (longer lists are paged with a MORE row)
cfg.SetupListMaxH         = 520        -- max height of the option list (it scrolls to the focused row); "classic" only
cfg.SetupMediaW           = 640        -- media area (planet video / art); unused in v2 (kept for "classic")
cfg.SetupMediaH           = 360
cfg.SetupInsetW           = 256        -- inset art (planet select image / track tile); unused in v2 (kept for "classic")
cfg.SetupInsetH           = 144
cfg.SetupCardPortraits    = true       -- vehicle cards show the livery owner's portrait for pilot-livery presets
cfg.SetupCardW            = 360        -- vehicle card image per player column (initial width; 0.8.0: the 2D art keeps its
                                       --   own aspect, a 3D card is 16:9)
cfg.SetupCardH            = 200        -- card height (0.8.0: lowered when n 16:9 cards would not fit SetupCardRowW)
cfg.SetupLeftWeight       = 0.45       -- width share of the media column; unused in v2 (kept for "classic")
-- 3D vehicle preview (vpreview.lua, 0.8.0; notes/research/vehicle-preview.md): each VEHICLES card shows a live render of
-- its pick, made by a "photo bay" per column (a BP_StaticVehicleBase model + SceneCapture2D + fill light) in the sky
-- above the front-end sets. Front end only; released when the step is left, the setup closes or a player leaves. A
-- structural failure turns it off for the session (2D cards, reason logged once); a model that fails keeps its 2D card.
cfg.SetupPreview3D        = true       -- live 3D render of each VEHICLES pick; false = the 0.7.1 2D cards (+ badge)  V-VP-09
cfg.SetupPreviewX         = 0          -- bay 1 origin X (uu); bay key i at X + (i-1) * SetupPreviewSpacing
cfg.SetupPreviewY         = 60000      -- bay origin Y (uu): empty sky on the far +Y side of the front-end sets
cfg.SetupPreviewZ         = 60000      -- bay origin Z (uu): ~44 deg above every main-menu camera       VERIFY(V-VP-05)
cfg.SetupPreviewSpacing   = 20000      -- uu between two bays (> 0). 0.10.0: was 5000; the fill light (radius 3 x camera
                                       --   distance) reached a pod's neighbour model up to ~16000 (vehicle-step-v2.md
                                       --   §0.3 #7)                                           VERIFY(V-VP-10, V-RC-17)
cfg.SetupPreviewW         = 960        -- render target width (px, > 0). 0.10.0: was 640 (one size for 1-4 cards; tests at
                                       --   720p may set 640 x 360 in config_user.lua)
cfg.SetupPreviewH         = 540        -- render target height (px, > 0); card aspect = W / H. 0.10.0: was 360
cfg.SetupPreviewRtFormat  = 6          -- ETextureRenderTargetFormat: 6 RGBA16f (linear, right gamma); try 3 RGBA8_SRGB,
                                       --   then 2 RGBA8, if washed out or too dark                    VERIFY(V-VP-03)
cfg.SetupPreviewCaptureSource = 2      -- ESceneCaptureSource: 2 FinalColorLDR; 7 BaseColor = unlit last resort
cfg.SetupPreviewFov       = 30         -- capture horizontal FOV (deg, > 0)
cfg.SetupPreviewCamYaw    = 210        -- camera azimuth around the model (deg), on the front-end sun's side
cfg.SetupPreviewCamPitch  = 12         -- camera elevation above the model (deg)
cfg.SetupPreviewYaw       = 245        -- model start yaw (deg): front three-quarter view toward the camera
cfg.SetupPreviewFrame     = 1.05       -- framing margin (camera distance multiplier, > 0; larger = smaller model)  V-VP-04
cfg.SetupPreviewSpinDps   = 15         -- turntable speed (deg/s, either sign); 0 = static (captures at ready, +0.5 s,
                                       --   +2 s, +5 s, then every 5 s)                                VERIFY(V-VP-06)
cfg.SetupPreviewCaptureMs = 66         -- min ms between two captures of a spinning bay (>= 0; 0 = every FAST tick; ~15/s
                                       --   at 33 ms ticks). 0.10.0: was 50                                     V-VP-06
cfg.SetupPreviewFillLux   = 60         -- fill PointLight above the camera: illuminance at the model in lux (intensity =
                                       --   lux * m^2 candelas); 0 = no fill light                     VERIFY(V-VP-04)
cfg.SetupPreviewExposure  = "inherit"  -- capture exposure: "inherit" (the front end's own post-process) | "fixed" (eye
                                       --   adaptation clamped to SetupPreviewEV)                      VERIFY(V-VP-04)
                                       --   0.12.0: vpreview forces "fixed" while PreviewBackdrop = "studio" (V-FIN-05)
cfg.SetupPreviewEV        = 8          -- EV100 of the "fixed" exposure
cfg.SetupPreviewShowOnly  = true       -- capture only the bay's model (false = every primitive in view)
cfg.SetupPreviewCaptureOnly = false    -- the bay model drawn by scene captures only, casting no shadow (use it if the model
                                       --   or its shadow shows in a main-menu camera)                 VERIFY(V-VP-05)
cfg.SetupPreviewBounds    = "all"      -- component bounds that frame the model: "all" | "colliding" (the other kind when
                                       --   degenerate or above SetupPreviewMaxRadius)                 VERIFY(V-VP-04)
cfg.SetupPreviewMaxRadius = 6000       -- bounds radius (uu, > 0) above which a bounds kind is ignored for framing
cfg.SetupPreviewRebuild   = "respawn"  -- a new pick: "respawn" (a fresh model actor: unit count 0 -> > 0 is unambiguous) |
                                       --   "update" (preset write + UpdateCustomisationMesh(), the game's garage path)  V-VP-02
cfg.SetupPreviewDebounceMs = 250       -- a column's pick is built once it has not changed for this long (> 0)
cfg.SetupPreviewTimeoutMs = 6000       -- a pick not built by then keeps its 2D card, logged once per model (> 0)
cfg.SetupPreviewBrush     = "material" -- column image: "material" (an MID of SetupPreviewMaterial) | "texture" (the render
                                       --   target itself; its FinalColorLDR alpha may be 0 = invisible)  VERIFY(V-VP-03)
cfg.SetupPreviewMaterial  = "/Game/Griffin/UI/Library/Materials/Diegetic/M_UI_RetainerBox_ScreenSpace.M_UI_RetainerBox_ScreenSpace"
                                       -- opaque UI material showing the render. NOT a pass-through (decoded: warp lines,
                                       --   radial mask, twinkle = the game's diegetic-screen look). A/B alternative: Epic's
                                       --   "/VirtualCamera/WidgetLibrary/VCamTakesBrowser/Widgets/mat/M_ThumbnailMask.M_ThumbnailMask"
                                       --   with SetupPreviewMaterialParam = "Target"                  VERIFY(V-VP-03)
cfg.SetupPreviewMaterialParam = "Texture" -- texture parameter of SetupPreviewMaterial
cfg.SetupCardBadges       = true       -- manufacturer badge top left of each vehicle card (2D and 3D)  VERIFY(V-VP-08)
cfg.SetupCardBadgeSize    = 44         -- badge size (px, > 0)
cfg.SetupCardInsetH       = 72         -- height (px, > 0) of the livery owner's portrait inset next to a 3D render
cfg.SetupCardRowW         = 1400       -- width budget (px, > 0) of the VEHICLES row: the 16:9 cards get lower when n
                                       --   columns would not fit (4 players: 187 px high, 332 wide)    VERIFY(V-VP-10)
-- 0.10.0 previews for the RACERS step (vpreview.lua; notes/design/vehicle-step-v2.md §5.8, RC-12): bays keyed by
-- ControllerId + 1, modes "spin" / "still", budgets over all bays together. The new defaults above (spacing, target
-- size, capture period) and the budgets apply to the classic columns too.
cfg.SetupPreviewCaptureBudget = 1      -- CaptureScene() calls per FAST tick over all bays, the due bay captured longest
                                       --   ago first (> 0; 1 = ~30 captures/s in total, 7.5/s each with 4 spinning)
                                       --                                                              VERIFY(V-RC-17)
cfg.SetupPreviewSpawnGapMs = 300       -- a new pick is built (spawn / in-place rebuild) at most once per this many ms over
                                       --   all bays, the oldest waiting pick first (> 0)                    V-RC-17
cfg.SetupPreviewStillBurst = 8         -- captures per still (at ready, after the late parts, on a page re-show): Lumen GI,
                                       --   TSR and eye adaptation settle over captures (RC-12; > 0)          V-RC-17
cfg.SetupPreviewSpinStage = "vehicle"  -- RACERS stages whose bay spins: "vehicle" | "all" | "none" (stills everywhere)
                                       --                                                                     V-RC-17
cfg.SetupPreviewPrebuildMs = 600       -- RACERS PILOT stage: the pilot's signature vehicle is built (still) once the pilot
                                       --   pick was unchanged this long (>= 0; 0 = no prebuild)               V-RC-10
-- 0.9.0 campaign views (cmap.lua, notes/research/campaign-map/): PLANET = the campaign's planet arc (WBP_PlanetSelector)
-- + a row of planet chips (the control); TRACK = a single-planet run map (circuit rows, variant nodes, detail card).
-- Any failure falls back to the 0.8.0 lists for that step. Sizes are Slate units (1 su = 1 px at 3840x2160).
cfg.SetupCampaignMap      = true       -- false: the 0.8.0 lists for PLANET and TRACK (no cmap widget is built)  V-CMAP-12
cfg.SetupCMapPlanetNav    = "chips"    -- "chips" (planet chips under the arc) | "list" (the 0.8.0 planet list)  V-CMAP-05
                                       --   0.12.0: on the UI v2 page "chips" is the planet disc pager (no name chips)
cfg.SetupCMapTrackView    = "map"      -- "map" (run map, d-pad between nodes) | "list" (the 0.8.0 track list)   V-CMAP-08
cfg.SetupCMapAreaW        = 3500       -- planet view area (su, > 0), clipped                                   V-CMAP-06
cfg.SetupCMapAreaH        = 1080
cfg.SetupCMapArcScale     = 0.85       -- render scale of the campaign's 7200-su arc (> 0; 1 = campaign size)   V-CMAP-06
cfg.SetupCMapArcAngle     = 35         -- ArcAngleDeg (campaign 35; used as max(value, 5.85 x planets), > 0)
cfg.SetupCMapArcPad       = 2          -- SelectionPadAngle around the selected planet (deg, >= 0)
cfg.SetupCMapPlanetY      = 330        -- selected planet centre below the area top (su)
cfg.SetupCMapInfoW        = 820        -- planet info block width (su, > 0)
cfg.SetupCMapVideoW       = 0          -- planet video frame width (su, 16:9, >= 0; 0 = no video in the planet view).
                                       --   0.12.0: was 768 (UI v2: no movie box by default; "classic" keeps 768)
cfg.SetupCMapBackground   = false      -- campaign map paper (T_UI_Map_Bg) behind the arc. 0.12.0: was true (UI v2: the
                                       --   full T_UI_Map_Bg is the page background, theme C1 "map"; "classic" keeps true)
cfg.SetupCMapManualTick   = "auto"     -- "auto" (UpdateButtonPos from the FAST loop only if the arc does not tick) |
                                       --   "always" | "off"                                                     V-CMAP-04
cfg.SetupCMapSounds       = true       -- the campaign map's UI sounds (open, planet accept)
cfg.SetupCMapMapW         = 3584       -- run map box (su, > 0); the 3840x1500 map scales to fit it             V-CMAP-08
cfg.SetupCMapMapH         = 1316       --   0.12.0: were 3500 x 1200 (UI v2: the virtual map = the 3584 x 1316 frame,
                                       --   scale 1.0, §7.3; "classic" keeps 3500 x 1200)
cfg.SetupCMapPlanetX      = 1180       -- big planet centre x in the 3840-wide map
cfg.SetupCMapPlanetScale  = 0.62       -- big planet render scale (> 0; disc 2336 su at 1)
cfg.SetupCMapPlanetName   = false      -- also show the big planet's own 84-pt name
cfg.SetupCMapCardW        = 980        -- detail card width (su, > 0)
cfg.SetupCMapNodeMax      = 40         -- most circuit variants on one map (> 0; more = the list)

---------------------------------------------------------------------------------------------------- Race setup: RACERS step
-- 0.10.0 (racers.lua, cards.lua, pilots.lua, perks.lua, perkapply.lua; binding spec notes/design/vehicle-step-v2.md
-- with its "Review corrections"). User request 2026-10-09: "A character should be chosen, a kart then. and then we
-- should be able to map out all the benefits and perks added to the kart (all unlocked just for this mod)". Step 5 of
-- RACE SETUP becomes RACERS: one card per local player, each on its own PILOT -> VEHICLE -> PERKS -> READY, the same
-- card for P1 and the guests; every perk unlocked (no save, no unlock tag touched). Cards, memory, preview bays and
-- the persisted picks are keyed by ControllerId. Sizes are Slate units (1 su = 1 px at 3840x2160). GuestPilots,
-- SetupPerPlayerBuild*, SetupCard* and SetupInRaceOverride* keep their meaning in the classic flow.
cfg.SetupPlayerFlow       = "cards"    -- "cards" (the RACERS cards) | "classic" (the 0.9.x VEHICLES columns, untouched;
                                       --   also used for one page when the cards cannot be built)   VERIFY(V-RC-01/28)
cfg.PilotStage            = true       -- PILOT stage shown (false: the pilot defaults are used)
cfg.PerkStage             = true       -- PERKS stage shown (false: the pilot's style kit is used)
-- input: guests are polled on their own PlayerController; P1's pad moves CommonUI focus on an invisible sink
cfg.CardP1Input           = "sink"     -- "sink" (5 invisible buttons as a plus, explicit navigation rules: a move onto a
                                       --   neighbour = one direction, focus back on the centre) | "geometric" (the plus
                                       --   without explicit rules) | "ring" (the 5 buttons wired as Z5: the index delta is
                                       --   the direction, no re-focus = one BP navigation tick per press, RC-6)
                                       --                                                         VERIFY(V-RC-02/30)
cfg.CardP1DirGuardMs      = 50         -- a P1 sink direction within this many ms of the same direction on a guest pad is
                                       --   dropped and logged (insurance against task #14, RC-10; >= 0, 0 = off)  V-RC-07
cfg.CardGuestClickGuardMs = 150        -- P1's sink accept is dropped while a guest's A is down or had an edge within this
                                       --   many ms (task #14: a guest's A clicking P1's focus; >= 0)          V-RC-07
cfg.RunRepairChance       = 0.15       -- GALAXY RUN: chance that a reward offer holds LEAGUE TOKEN +1 while a token is missing
cfg.RunDays               = 3          -- 0.14 GALAXY RUN v3: map columns (days) per planet (2..5; 5 = the campaign's real depth)
cfg.RunTokens             = "couch"    -- 0.14: starting League Tokens: "couch" (1 + 1 per extra player) | "real" (the
                                       --   campaign's 1 per act) | a number
cfg.RunPayoutScale        = 1.0        -- 0.14: multiplier on the campaign's credit payouts / skip bonuses (> 0)
cfg.RunPageDeco           = true       -- 0.14 GALAXY RUN page: the campaign-look scene (map bg, planet, node graph,
                                       --   token pips); false or any scene failure = plain rows   V-RP-02
cfg.RunPageSounds         = true       -- 0.14: the campaign's RunMap sounds on the page (open/close, node, accept)
cfg.RunPageInvertTabs     = true       -- 0.14: the top menu's tab labels go cream on the run page's starfield (restored on close)
cfg.GrandPrix             = true       -- 0.16 GALACTIC GRAND PRIX (gp.lua / gppage.lua): the FREE MODE poster formerly
                                       --   GALAXY RUN opens the Grand Prix page | false = the old GALAXY RUN page
cfg.GPPodTourTracks       = true       -- 0.16: the Podracer tour also offers the Podracing Tour's pods on speeder circuits
                                       --   (set "game", never raced live before 0.16)                  V-GP-03
cfg.GPPerPlayerClass      = true       -- 0.16: speeder tours: each player races his own class (pick.arch in the recipe) |
                                       --   false = everybody races P1's class                           V-GP-04
cfg.CardEasyBuilds        = true       -- 0.13.0: guests' Y = SURPRISE ME (random pilot/vehicle/kit, READY), X = COPY P1's build
cfg.CardBackTapMaxMs      = 600        -- a guest's B is "back" on release when held shorter (held 1 s = leave, join.lua;
                                       --   > 0)                                                               V-RC-04
cfg.ConfirmWindowMs       = 5000       -- couch-fix59 AUTO-145e: every press-twice confirmation (END GRAND PRIX, END THE RUN,
                                       --   START with un-joined pads / players not ready, ABANDON THE GALAXY RUN): the
                                       --   second A within this many ms (real clock; < 1000 -> 5000)
cfg.CardP1BackConfirmMs   = 3000       -- P1 at PILOT: a second back within this window goes to MODE (> 0)    V-RC-08
-- layout (vehicle-step-v2.md §3; 0.12.0 UI v2: ui-redesign-final.md §8 / §2.5, the row fills 3584 su). The v2 values
-- below; while UiStyle = "classic" these four keys read the 0.11.0 values (cfg.UiClassic: 3500 / 1320 /
-- { 1720, 1720, 1140, 845 } / { 0, 60, 40, 40 }), unless config_user.lua overrides them (then in both styles).
cfg.CardRowW              = 3584       -- card row width (su, > 0). 0.12.0: was 3500                          V-RC-15
cfg.CardH                 = 1300       -- card height (su, > 0); lower it if the page is shorter than measured (the row
                                       --   cannot shrink against the page, RC-15; v2 derives min(1300, cmdY - 580) from
                                       --   the measured page, §2.5). 0.12.0: was 1320                        V-RC-15
cfg.CardPad               = 32         -- inner padding of a card (su, > 0); "classic" (cards.lua) only
cfg.CardW                 = { 1762, 1762, 1162, 860 }   -- card width (su) for 1, 2, 3, 4 players (4 numbers >= 1).
                                                        --   0.12.0: was { 1720, 1720, 1140, 845 }
cfg.CardGap               = { 0, 60, 49, 48 }           -- gap between the cards (su) for 1, 2, 3, 4 players (>= 0).
                                                        --   0.12.0: was { 0, 60, 40, 40 }
-- look: every game widget has a plain fallback, the same for every card                           VERIFY(V-RC-06)
--   0.12.0: the keys marked "classic" only are read by cards.lua alone (UiStyle = "classic"); the v2 cards
--   (cards2.lua) put no game widget inside a card and paint those parts themselves
cfg.CardFrame             = "darkpanel" -- "darkpanel" (WBP_DarkPanel as the card's bottom layer) | "solid" (a FuseImage);
                                       --   "classic" (cards.lua) only
cfg.CardPanelColour       = { R = 0.012983, G = 0.036889, B = 0.048172, A = 0.90 }   -- #1E363E @0.9, the game's panel
                                       --   "classic" (cards.lua) only
cfg.CardHighlight         = "pill"     -- "pill" (WBP_ButtonBacker pills) | "solid" (solid images); "classic" only
cfg.CardDetail            = "game"     -- detail panel: "game" (WBP_Character_Ability: title + rich text, fed through its
                                       --   vars + Refresh()) | "plain" (two text blocks, markup stripped);
                                       --   "classic" (cards.lua) only
cfg.CardThumbMask         = "mid"      -- head shots: "mid" (squircle MID of M_UI_CharacterProfilePicture) | "plain" (the
                                       --   transparent head shot on a squircle backer)
cfg.CardDiamond           = "disc"     -- ability diamond: "disc" (our discs) | "hud" (MI_HUD_Abilities_BG behind it);
                                       --   "classic" (cards.lua) only
cfg.CardBackdrop          = true       -- racer-style art behind the pilots; "classic" (cards.lua) only
cfg.CardGlyphs            = "xbox"     -- hint glyphs: "xbox" (the game's Xbox pad images) | "text"     V-RC-01 (no tofu)
cfg.CardSounds            = "match"    -- "match" (guests' navigation ticks + everybody's accept sounds, the cmap pattern) |
                                       --   "accept" (accept sounds only) | "off"                      VERIFY(V-RC-30)
cfg.CardStartPulse        = true       -- everybody READY: P1's START RACE row pulses
-- per FAST tick budgets                                                                         VERIFY(V-RC-16)
cfg.CardBuildsPerTick     = 1          -- card shells / stage panels / pickers built per tick (> 0)
cfg.CardRendersPerTick    = 2          -- dirty cards rendered per tick (> 0)
cfg.CardLoadsPerTick      = 3          -- small textures loaded per tick (> 0)
cfg.CardLoadBigBytes      = 1048576    -- a texture of at least this many bytes is "big": one per tick (full bodies 2.7 MB,
                                       --   style backdrops 4.1 MB, no mips; RC-9; > 0)
-- pilots (pilots.lua)
cfg.PilotUnique           = true       -- a pilot is held by one human at a time (cycling skips the others')  V-RC-09
cfg.PilotShareShade       = false      -- with PilotUnique: several humans may still race SHADE
cfg.PilotP1Default        = "shade"    -- P1's first pilot: "shade" | "favourite" (PvpFlowComponent.DefaultPilot when
                                       --   valid)                                                     VERIFY(V-PIL-08)
cfg.PilotExtras           = { "DA_Racer_Mentor" }   -- extra pilots (SEBULBA in the Skimmer class); false = none   V-RC-09
cfg.PilotPodRivals        = false      -- podracers: also the 11 speeder rivals
cfg.PilotPodAged          = false      -- podracers: also the 5 Aged pilots
cfg.PilotSeatCheck        = "log"      -- in the race: "log" (ps.Pilot compared with the pick) | "refresh" (also written +
                                       --   SynchronousRefreshPilot) | "off"                           VERIFY(V-RC-23)
-- perks (perks.lua board; perkapply.lua launch writes, vehicle-step-v2.md §6)
cfg.PerkPartSlots         = 6          -- part slots on the board and in the launch build (1..10, clamped)    V-RC-19
cfg.PerkTraitSlots        = 3          -- trait slots (1..4, clamped)
cfg.PerkFlaws             = true       -- FLAWS category in the part pickers
cfg.PerkUniqueFamily      = true       -- an ability family in one slot only (a picker swap moves it)        V-RC-13
cfg.PerkApply             = "full"     -- "full" (zero base build, affix slots raised in memory for the call, every field
                                       --   written and read back, traits at PRERACE) | "passives" (parts + traits as
                                       --   passives at PRERACE only) | "off" (the classic build)    VERIFY(V-RC-19/21)
cfg.PerkTraits            = true       -- traits applied as passives at PRERACE (Server_ApplyPassive)          V-RC-22
cfg.PerkSetRacerStyle     = false      -- also write ps.RacerStyle (its traits might then apply twice)
cfg.PerkVerify            = true       -- PRERACE / RACING check of each human's build and abilities           V-RC-21
cfg.PerkLateFallback      = true       -- parts lost in the travel are re-applied as passives (flaws skipped)  V-PRK-06
cfg.PerkRamjet            = "keep"     -- speeders' ramjet: "keep" (the base build's) | "on" | "off"
cfg.PerkCritMalfunctions  = "keep"     -- critical malfunctions: "keep" | "on" | "off"
cfg.PerkPodRamjet         = false      -- podracers get the ramjet (RamjetInstalled = true); false = the game's own "Memory
                                       --   Pod [No Ramjet]", ramjet items hidden on pods (RC-2)       VERIFY(V-RC-32)
cfg.PerkHideInert         = true       -- items for a system the car lacks (ramjet / critical malfunctions) are hidden;
                                       --   false = shown dimmed, tagged NO RAMJET / NO CRITICAL MALFUNCTIONS    V-RC-32
cfg.PerkLaunchBase        = "zero"     -- launch build of a cards race: "zero" (VBD_000_1Mastiff / _Plane: no abilities,
                                       --   no parts, PL 0) | "pilot" (speeders launch on P1's style build VBD_PvP_IA_*,
                                       --   PL 26-31: the fallback before PerkApply "off" when the AI scale with the
                                       --   launch build, RC-14; pods keep the zero base)              VERIFY(V-RC-27)

---------------------------------------------------------------------------------------------------- COUCH CAMPAIGN
-- 0.15.0 (couch.lua, couchrun.lua, couchpanel.lua, couchprerun.lua, couchlayout.lua). The game's own campaign played by
-- 2-4 players on one PC: join the pads on the FREE MODE tab, then open the game's CAMPAIGN tab. P1's pad drives the
-- shared screens (paddock, cinematics, run map, dialogs); every player races his own car in split screen and picks his
-- own vehicle class, racer style, rewards and shop items on his part of the screen. The run is saved in P1's normal
-- campaign save (the game has ONE run per profile): back up the SaveGames folder first (README "Couch campaign").
-- Turning a key off only drops that part; with CouchCampaign = false the campaign is the game's single-player one again.
cfg.CouchCampaign         = true       -- the campaign keeps the joined guests (their own cars in every race, split screen).
                                       --   false = guests are closed when the campaign starts, as before 0.15.0
cfg.CouchSkipPrologue     = true       -- a NEW run starts without the game's vehicle-tryout prologue race (one shared
                                       --   car there; the guests would only watch). false = the game's prologue
cfg.CouchTimeTrials       = true       -- Field Tests / Podracer Tests: every player runs P1's test vehicle at the same
                                       --   time, the others shown as ghost cars. false = P1 races them alone
cfg.CouchMissionInstances = true       -- a mission raced alone (first: the planet's PODRACER TEST) gives EVERY player his
                                       --   own copy of it: same track, start setup and named opponents, his own race
                                       --   (the other sets hidden in his view, no collision, his own place / result;
                                       --   any player's win wins the mission). false = one shared field (others ghosted)
cfg.CouchInstancesMaxGrid = 12         -- most racers a race with instances may hold (the tracks' grids: 12); more = the
                                       --   shared field for that mission (logged "[instances] kickoff: no instances")
cfg.CouchSoloInstances    = true       -- a 1-car FIELD TEST (its grid = the players only) gives each player his own
                                       --   instance too (the others' cars hidden in his view, no collision). false = one
                                       --   shared track, the other players' cars ghosted (couch.ghostCars). A field test
                                       --   with its own opponents: cfg.CouchFieldTestInstances
cfg.CouchSoloTimeLimit    = true       -- a test raced by several players (FIELD TEST / PODRACER TEST / any TimeTrial or
                                       --   Takedowns event with a target time): another player's finish or wreck never
                                       --   ends your test, and nobody's finish takes your time limit away: the race ends
                                       --   at the test's own limit (race start + target) for whoever is still out.
                                       --   false = the old rule (the others race on with no limit)
cfg.CouchSoloLimitGraceSec = 0         -- seconds added to that limit (0 = exactly the target time)
cfg.CouchSoloTimeTrialCap = 2.0        -- #89: a TIME TRIAL / PODRACER TEST is never ended at its target: the game lets a
                                       --   solo player race to the line and books his (failed) time. Its limit is the
                                       --   target x this (only a safety end for a run that never reaches the line);
                                       --   0 = no limit at all. Takedowns keep the target (the game's own end there)
cfg.CouchInstancesCollision = "channels" -- #59: how the copies stop touching each other. "channels" (default): every
                                       --   guest's copy is its own collision object type (an unused game channel, the
                                       --   car's Vehicle responses moved onto it) and ignores the Vehicle channel and
                                       --   the later copies' channels = no physics contact between copies, contacts
                                       --   inside each copy as the game's (re-asserted after the game's own crash /
                                       --   no-battling profile switches). "sweeps" = the old cross-copy sweep ignore
                                       --   only (the copies' cars still bump: P1's bots take P2's down)
cfg.CouchFinishPlate      = true       -- #96: a player out of the race while another still races sees his own result in
                                       --   his view ("TEST PASSED - 10/10 - 00:32.33" / place + time) and "WAITING FOR
                                       --   P2" until the race ends, instead of a bare view of his car
cfg.CouchInstanceHazards = true        -- #84 / #85: mines, ability blasts / shockwaves and their visuals belong to the
                                       --   copy of the car that made them (seen and felt in that copy only); the
                                       --   track's own mines are copied for every guest's copy. false = shared hazards
cfg.CouchFieldTestInstances = true     -- #37 / #39: a FIELD TEST with its own opponents (TAKEDOWNS: P1 + 7 test bots)
                                       --   gives EVERY player his own copy of that field, picked at the node: his own
                                       --   bots (the other sets hidden in his view, no collision), his own count. false =
                                       --   one shared field, the other players' cars ghosted (logged WARN)
cfg.CouchFieldTestMaxGrid = 32         -- most racers such a field test may hold for all the copies. Q8 B (Jules
                                       --   2026-10-18): every player's copy is solo's whole field (P + 7 bots): 2P = 16,
                                       --   3P = 24, 4P = 32 racers (the game's own events stop at 12, live 2P ran 16;
                                       --   the takedown start is rolling). COST (sim takedown gc2 / gc4, Lua
                                       --   garbage of the whole mod in a steady race): 2P / 16 cars 644 KB/s, 4P / 32
                                       --   cars ~1110 KB/s (a plain 4P race is ~870: the 32-car part ~240 KB/s =
                                       --   the per-copy bot director + the copies' collision / view / hazard ticks).
                                       --   The game's side is NOT simulated: 32 AI cars of physics + AI every frame
                                       --   (each view draws only its own 8; shadows / audio of hidden cars may still
                                       --   cost) - check the frame time live at 4P before trusting 32
                                       --   More players than fit: each copy gets smaller (logged) and its takedown
                                       --   target scaled (below); the race builder clamping the grid gives smaller
                                       --   copies too (logged WARN, target scaled the same way)
cfg.CouchFieldTestScaleTarget = true   -- Q8: a takedown copy smaller than solo's field (the cap above, or the builder's
                                       --   clamp) scales the target to its bots: target x (set - 1) / 7, rounded up
                                       --   (12 with 5 bots = 9), the same for every player, said on the HUD for
                                       --   CouchFieldTestScaleNoticeMs. false = the event's target kept (WARN)
cfg.CouchFieldTestScaleNoticeMs = 6000 -- how long that HUD notice stays (ms)
cfg.CouchSoloScores       = true       -- #37: a TAKEDOWNS / RAMJET DISTANCE test raced by several players: every player
                                       --   his own count (takedowns BY his car of HIS copy's bots, ramjet distance of
                                       --   his car), his own HUD counter (the guests' counters fed from their own count),
                                       --   his own verdict. false = the game's single counter (one player's)
cfg.CouchSoloFinishAtTarget = true     -- TAKEDOWNS: a player who reaches the target count finishes his test at once
                                       --   (his finish time = that moment). false = the game's own rule (the test runs to
                                       --   its time limit, the reach time is the result)
cfg.CouchTakedownSetDirector = true    -- #70 TAKEDOWNS raced as separate copies: the game's bot director (bots that fall
                                       --   too far behind are put back ahead, a lost field lined up behind and sent past
                                       --   the player) serves ONE player (P1) for every copy's bots. true = the mod runs
                                       --   those same rules for each copy around its own player (the game's off for that
                                       --   race, put back after it). false = the game's (P2's bots follow P1)
cfg.CouchPrecisionGates   = true       -- #86 PRECISION DRIVING test raced by several players: the game checks the gates only
                                       --   with ONE PlayerState in the race (no bonus for anybody in a couch race). true =
                                       --   every player's own gates counted by the mod (the solo 1.5 s per gate on HIS
                                       --   clock, his own CHECKPOINT BONUS popup / timer). false = the game's (no bonus)
cfg.CouchSoloResults      = true       -- after such a test the result screens show P1's OWN time and verdict (the game
                                       --   reads them from the screen's owner = the last guest) and a results band gives
                                       --   every player his own card + the team line ("P2 PASSED: THE FIELD TEST COUNTS")
cfg.CouchPreRunSplit      = true       -- the new-run VEHICLE SELECT / LOADOUT screens split: each guest picks his own
                                       --   class and racer style (A = READY). false = guests copy P1's choice
cfg.CouchPreRunNative     = true       -- the guests' pre-run halves in the game's look: RACER STYLE shows each guest the
                                       --   game's own loadout screen (his styles, P1's unlocked favours, his START RUN =
                                       --   READY); VEHICLE SELECT shows the game's own screen (below) or, as its fallback,
                                       --   the 4-way garage area style with a real 3D car. false = the old compact panels
cfg.CouchPreRunNativeCopy = true       -- #100: each guest's VEHICLE SELECT = the game's own screen (class cards, stats panel,
                                       --   upgrade / unlock hints, locked look) with his own 3D car behind it; only P1
                                       --   unlocks. false (or a copy that cannot be built) = the area list
cfg.CouchPreRunWaitGuests = true       -- #104: P1's START RUN on the LOADOUT waits until every guest pressed his START RUN
                                       --   (READY): "WAITING FOR P2" by P1's button. false = P1 is never held
cfg.CouchPreRunWaitMs     = 180000     -- #104: safety: P1's START RUN is released after this long (0 = never)
cfg.CouchPreRunNavBoundary = true      -- AUTO-122: P1's pre-run screen is a navigation boundary while the split is open
                                       --   (his D-pad never runs into a guest's area). false = Slate's default
cfg.CouchPanel            = true       -- after a race and at shops every guest gets his own area of the screen for his
                                       --   reward / purchases. false = guests pick no rewards and buy nothing
cfg.CouchPanelNative      = true       -- the guest's reward area uses the game's own CHOOSE AN UPGRADE cards. false =
                                       --   a plain dark list (also used automatically when the cards cannot be built)
cfg.CouchRewardDoneClose  = true       -- #93: a guest done with his rewards: his area closes at once, the split is laid out
                                       --   again for the players still choosing (only P1 left = P1 full screen)
cfg.CouchRewardFlow       = true       -- couch-rewards2: each guest's OWN post-race reward flow from HIS result (couchrewards
                                       --   / couchflow: his hub, CREDITS BREAKDOWN, FAULTS, his own upgrade rounds - the
                                       --   native rules). false = the old offer that mirrors P1's round
cfg.CouchGuestRewardCards = 3          -- couch-rewards2: cards of a guest's round (the native 2 + 1 tune values; spike S6)
cfg.CouchGuestHighRiskRarity = 2       -- couch-rewards2: an eliminator's part round's minimum rarity (spike S6)
cfg.CouchGuestPartSlots = 4            -- #110: a guest's part slots before his Gadgeteer (the native UnlockedAffixSlots 4)
cfg.CouchFieldTestRunBuild = false     -- couch-fix29: a FIELD TEST races the event's own test build for P1 and every guest
                                       --   (the all-PC builder writes it); true = the old write of a guest's run build into
                                       --   the test class (his parts / levels in a test P1 races without his)
cfg.CouchHighRiskTop      = 3          -- couch-rewards2: a guest outside this place in an eliminator earns no round
cfg.CouchGuestFaults      = "native"   -- couch-rewards2: "native" = a guest's critical malfunction gives HIM a fault when the
                                       --   game's scheduler fires for it (taken off P1's run) | "off"
cfg.CouchFaultsPollMs     = 250        -- couch-fix27 #109: the poll of P1's fault queue count (the check's outcome runs in the
                                       --   game's tick: no hook sees it)
cfg.CouchFaultsStateMs    = 1000       -- couch-fix27 #109: every local car's critical-malfunction state (who owns new faults)
cfg.CouchFaultsGuestMs    = 100        -- couch-fix59 AUTO-143: each guest car's critical-malfunction state (a malfunction
                                       --   ended by a crash / the check with no fault of the game's for it -> his own)
cfg.CouchRewardFence      = true       -- couch-rewards2: no guest pad's focus inside P1's reward screens (couchfence)
cfg.CouchShopNative       = true       -- the guest's shop area is the game's own shop screen (part cards, build panel)
                                       --   with his stock and credits. false = the plain dark list (also the automatic
                                       --   fallback when the native shop cannot be built)
cfg.CouchShopGridMatchP1  = true       -- #105: the guest's shop copy lays its part cards out in P1's native column count
                                       --   (P1's TV_Parts EntryWidth in his SzB_PartsSize width: 3 wide); the copy's parts
                                       --   box no longer fills the spare width of its area (it showed 4 wide). false = 0.16
cfg.CouchMysteryGreyDelayed = true     -- #112: at a mystery encounter a guest's choice paid by a later bookend (mystdata
                                       --   bk: MYST_157 gamble, MYST_107 promises, MYST_108 payout, MYST_113 race deal)
                                       --   is greyed on his half, "NOT AVAILABLE FOR GUESTS YET" (bookends are not tracked
                                       --   per guest: he could pay and never be paid). P1 unaffected. false = selectable
cfg.CouchRewardWaitGuests = true       -- couch-fix32 (audit 12 #13): P1 on the run map with a guest still choosing his
                                       --   rewards: the map screens are disabled (P1's node pick waits) until every guest
                                       --   is done; P1 holds B cfg.CouchStopForceMs to leave anyway. false = 0.16 (his
                                       --   pick ended the post-race: the guest's open rounds became SKIP credits)
cfg.CouchMapInputHold     = true       -- couch-fix53 (AUTO-131): during that wait the screen owner leaves pad id 0 and
                                       --   P1's PC takes it back: P1's A reaches no CommonUI router that owns the map
                                       --   (the disabled screens / node buttons did not stop it live). false = fix51
cfg.CouchShopRarityTable  = true       -- couch-fix32 (audit 12 #14): a guest's Hibi's shelf rolls the shop's rarity table
                                       --   (rundata rarity.shop, one planet behind the race rewards) for the planet, never
                                       --   the race / eliminator table (richer shelves than P1's); Legendary parts 4,000.
                                       --   false = 0.16 (run.lua's reward offer drew the shelf)
cfg.CouchMysteryStrict    = true       -- couch-fix32 (audit 12 #7): a guest's mystery choice must mirror the solo outcome
                                       --   on HIS economy: a choice with any effect the mod cannot give him (a League token,
                                       --   a run favour such as a sabotage, a run unlock, a reward pool no part of his car
                                       --   fits) is greyed when it also pays / charges him; reward pools roll their own
                                       --   rarity + fault (mystdata POOLS / GROUPS: MYST_049 = 2 Rare FAULTY parts); P1's
                                       --   follow-up interactions (bookends of his deals) are never a guest's. false = 0.16
cfg.CouchGuestShop        = true       -- on the run map (no split) a guest's A opens HIS own shop ("(A) SHOP" hint)
cfg.CouchMapGuestShop     = false      -- couch-rewards #10 (Jules 2026-10-17: unequal - the solo campaign has no shop on the
                                       --   map): the guests' "(A) SHOP" hint on the run map. false = guests shop at the
                                       --   shops P1 visits (Hibi's / scrap, split). true = the old map hint
cfg.CouchMapGuestGarage   = false      -- couch-rewards #10/#11: the guests' "GARAGE" hint on the run map (the compact garage
                                       --   outside the paddock). false = a guest's garage is his native full-screen turn
                                       --   offered in the paddock after P1 leaves his own garage (CouchGarageOffer)
cfg.CouchGarageOffer      = true       -- couch-rewards #4: after P1 leaves his own paddock garage, each joined guest in turn
                                       --   gets "P2: PRESS A FOR YOUR GARAGE" (A = his native garage turn, B = no thanks)
cfg.CouchGarageOfferMs    = 15000      -- the offer is withdrawn after this long without an answer
cfg.CouchP1GarageGuard    = false      -- couch-rewards #6 / #26: P1's OWN paddock garage with guests joined: the model shown
                                       --   must be one of P1's two slots of the class THE GAME opened (never a class
                                       --   switch: the paddock has a garage per class), else ONE reload per visit; every
                                       --   guest's CstSubsystem / P1's other classes are put back if the visit changed
                                       --   them. OFF by default (#26: the first version fought the screen live)
cfg.CouchP1GarageRootA    = true       -- couch-p1garage #27: P1's A on his OWN garage root (ids swapped for it) enters the
                                       --   hero page his focus is on when the game did not act (menubridge)
cfg.CouchP1GaragePageA    = true       -- couch-p1garage #27: P1's A on his own garage page clicks the option he focuses
                                       --   (never a hold / locked one) when the game did not act; LB / RB always bridged
cfg.CouchShopRestock      = 250        -- his own shop's RESTOCK price (x (1 + restocks this planet))
cfg.CouchGarage           = true       -- his own GARAGE (garage.lua): on the run map his D-pad moves to the "GARAGE" hint
                                       --   beside "(A) SHOP", A opens it: model, livery template, colours, finish of his
                                       --   car (per seat and class, Mods/SWGRCouch/guest-garage.txt; never P1's garage)
cfg.CouchGarageApply      = "upload"   -- how his livery reaches his car in a race: "upload" = his PlayerState's
                                       --   VehicleCustomisationComponent:Server_UpdateVehicleRecipe(his recipe), the
                                       --   game's own per-player path | "tags" = the tags on his car's recipe actor +
                                       --   OnRep_VehicleRecipe() | "off" (only his MODEL, through his grid entry)
cfg.CouchGarageUnlocks    = "p1"       -- the options a guest may pick: "p1" = what P1 owns (the game's own unlock /
                                       --   purchase test on P1's account) | "all" = every option of the game
cfg.CouchGarageTries      = 3          -- uploads per guest and race at most (a car the game rebuilt gets it again)
-- 4-WAY GARAGE (garage4.lua / garage4ui.lua, docs/dev/guest-garage.md section 8): every player builds his car at the
-- same time in his own area of the screen (2 players top / bottom strips, 3-4 quadrants), his own 3D car, his own pad.
-- Both switches stay false until the in-game checks (section 8.6) passed.
cfg.Garage4Way            = false      -- FREE MODE / GALACTIC GRAND PRIX: A on a racer card's VEHICLE stage opens the
                                       --   4-way garage for every player (model = every PRE_* preset of his class, every
                                       --   livery template / colours / finish unlocked); his livery is uploaded onto his
                                       --   car in the race (P1's too: in memory for that race, his saves never touched)
cfg.CouchGarage4Way       = false      -- COUCH CAMPAIGN: the guests' GARAGE on the run map shows each guest's 3D car in
                                       --   his area (options = CouchGarageUnlocks, his store = guest-garage.txt)
cfg.Garage4Bays3D         = true       -- the 3D car per area (vpreview photo bays: 4 at most, still captures on change)
cfg.Garage4Spin           = false      -- the 3D cars turn (a capture every Garage4SpinCaptureMs per bay); false = stills
cfg.Garage4SpinCaptureMs  = 250        -- min ms between two captures of a turning bay (> 0; the budget over all bays is
                                       --   SetupPreviewCaptureBudget per FAST tick)
cfg.Garage4BayLivery      = "refresh"  -- how a bay's car shows a livery: "refresh" = the tags on its CustomisationComponent's
                                       --   ActiveRecipe + RefreshRecipe() | "ui" = UpdateUISelection(type, tag, -1) per
                                       --   tag (the game's garage path) | "off" (the preset's own livery)   VERIFY(G4-02)
cfg.Garage4ShowHidden     = false      -- also offer the catalog's hidden options (pre-order entitlements) in FREE MODE
cfg.Garage4Z              = 900        -- viewport z of the front-end 4-way garage (over the RACERS page)
cfg.CouchCampaignTile     = true       -- F01: COUCH CAMPAIGN tile on the Campaign tab (replaces the Deluxe upsell) + its players page
cfg.CouchActPosters       = true       -- F02: the COUCH CAMPAIGN page shows the campaign's acts (ACT I-III): an unlocked
                                       --   act starts a NEW run of it (a run in progress is abandoned after a confirm).
                                       --   false = the page's NEW CAMPAIGN poster (the game's own restart) as in F01
cfg.CouchDeleteProgress   = true       -- #98: FREE MODE > OPTIONS > ADVANCED > Delete all couch progress (only while the COUCH save
                                       --   profile of tools/swgr-save-profile.sh is live; refused otherwise)
cfg.CouchSaveAccountId    = ""         -- F02: the SaveGames/<account> folder whose .swgr-profile marker is checked;
                                       --   "" = every account in Steam's loginusers.vdf (Proton)
cfg.CouchShopBridge       = true       -- while a guest shares the paddock shop, P1's A buys the card HE has focused and
                                       --   his B leaves the shop (the game's own click / back; skipped when his native
                                       --   press already acted). false = P1's native A / B only
cfg.CouchStopWaitGuests   = true       -- #77: at a shared shop / Scrap Dealer stop P1's leave (his B) is held while a
                                       --   joined guest is still shopping (P1's area: "WAITING FOR P2"); the stop closes
                                       --   once every guest left (his LEAVE / B), false = P1's leave closes it at once
cfg.CouchStopWaitMs       = 0          -- ... at most this long after P1's leave (the guests still shopping are closed,
                                       --   their purchases kept); 0 = no time limit (Jules's Q9: hard wait, hold B to
                                       --   force)
cfg.CouchStopBackGuard    = true       -- couch-fix43: while a guest shops, P1's stop screen is no CommonUI back handler
                                       --   (his B is read from his pad -> WAITING FOR P2); false = only the back hooks
cfg.CouchStopForceMs      = 2000       -- ... or P1 holds B this long to leave at once (his A = back to shopping)
cfg.CouchPadWatchBridge   = true       -- on a guest-owned shared screen P1's A / B / VIEW are also read from his pad's
                                       --   raw presses (the input filter's pad watch: any pad type, Steam Input too);
                                       --   couch-fix48: a guest's B in his shop / dealer area too (parked pads).
                                       --   false = only what the game's input reports
cfg.CouchMysteryTeamSave  = true       -- couch-fix48: a guest's TEAM mystery favour is saved at once (the run's native
                                       --   save via CampaignRun:OnLeaveShop); false = the next checkpoint carries it
cfg.CouchGenericBridge    = true       -- any other guest-owned paddock screen: P1's A clicks the button he focuses and
                                       --   his B runs the screen's back, only when the game did not react (never a
                                       --   hold / locked button). false = such screens get P1's native input only
cfg.CouchGarageKeepSwap   = true       -- P1's own garage keeps P1's pad on its pages (Choose Model, Edit Vehicle,
                                       --   Edit Livery) while the garage is open. false = the screen scan decides
cfg.CouchOrphanScreens    = true       -- a screen without a readable owner that opens over a shared screen stays P1's
cfg.CouchBuildView        = true       -- P1's VIEW BUILD (player menu, build page): each guest sees his own build on the
                                       --   game's build page in his area. false = the build page stays P1's only
cfg.CouchBackerNative     = true       -- #78: on VIEW BUILD's BACKER INFO tab each guest's area is the game's own
                                       --   BACKER INFO page (the team's backer and contract, his favours). false =
                                       --   the plain text plate
cfg.CouchBackers         = true       -- couch-fix21 (#90, Jules 2026-10-18): every guest has his OWN backer contract
                                      --   (couchbacker.lua / couchbackerui.lua): his own pick on his half of CHOOSE A
                                      --   BACKER CONTRACT, his contract counted from his own car, his own check-in and
                                      --   reward, his BACKER INFO. false = the team's backer (P1's) as before
cfg.CouchShareMeta       = true       -- couch-fix35 (Jules's Q6): the guests' tuning / kit points and their tracked
                                      --   unlock counters (field tests, scrap dealer buys, style takedowns / wins /
                                      --   events, planets with a favour) are added to P1's account (couchmeta.lua);
                                      --   false = guests earn nothing for the account
cfg.CouchBackerShareUnlocks = true    -- couch-fix21: a backer favour a guest earns (a Satisfactory run with his backer)
                                      --   is unlocked on P1's account (SPUnlockSubsystem UnlockTag) = every player's
                                      --   pre-run favours; false = kept in couch-run.txt's shared store only
cfg.CouchPanelNativeHover = true       -- the focused reward card uses the game's own highlight. false = a simpler
                                       --   highlight drawn by the mod (try it if a guest's card looks wrong when focused)
cfg.CouchRootSplit        = true       -- during a split moment P1's WHOLE screen (every game screen, its background,
                                       --   header, dialogs, tooltips) moves into his area. false = only the one native
                                       --   screen is shrunk (0.15 first version: its frame stayed full screen)
cfg.CouchRootBacker       = true       -- 2 players: the game's paper on both sides of P1's half-size screen in his strip
cfg.CouchCreditsChip      = true       -- map / shop / rewards screens: each guest's credits in a chip beside P1's native
                                       --   credits (top right; hidden while a split shows the guests' own areas)
cfg.CouchSkipBridge       = true       -- couch: any player's A held on the (guest-owned) skip-cinematic screen skips it
cfg.CouchSkipHoldMs       = 800        --   hold time (ms; the game's own hold is 750 ms and goes first when it works)
cfg.CouchSkipChainMs      = 8000       --   after a skip, the next shots' skip screens within this time are skipped too
                                       --   (one skip = the whole presentation); 0 = every shot needs its own hold
cfg.CouchSkipReown        = true       --   couch-livefix: a guest- / dormant-owned skip screen shows its prompt and ring from
                                       --   the mod's hold and is re-owned to P1's PC (the one in the skippable cutscene)
                                       --   before its Clicked event (the game's skip reads the OWNER)  VERIFY(V-CC-SKIP2)
                                       --   couch-skip (#33): re-owned to EVERY local PC in a skippable cutscene in turn
                                       --   (each plays its own intro chain; the race waits for all), P1 last
cfg.CouchSkipSweep        = true       --   couch-skip (#33): inside the chain window (paddock / PRERACE), a local PC's
                                       --   skippable chain that started after the skip gets its SkipCinematicChain
                                       --   (no skip screen needed); never the ignition (not skippable)  VERIFY(V-CC-SKIP3)
cfg.CouchActionTags       = true       -- couch campaign menus: the footers' "[P1] / [P2]" prompt prefixes are removed (the
                                       --   engine numbers them from the swapped pad ids: P1's prompts read "[P2]").
                                       --   Each player's area is his own. false = the engine's tags
cfg.CouchOwnerUiImc       = true       -- while P1's pad drives a screen a guest owns, that guest's UI input context is
                                       --   raised (the map / NEXT PLANET take P1's A and D-pad). false = bridge only
cfg.CouchSwapPark         = true       -- while P1's pad drives a guest-owned screen AND a guest split is open (vehicle /
                                       --   loadout pick, rewards, shop), P1's own PlayerController waits on a spare pad id
                                       --   (6) instead of the screen owner's: that guest's pad then reaches no player
                                       --   of the game, only his own area (his A no longer confirms P1's screen, a
                                       --   short A press counts). The ids come back when the split closes.
                                       --   false = P1's PC carries the guest's pad id during the split (0.15 first version)
cfg.CouchSwapParkAlways   = true       -- (with CouchSwapPark) the spare id also while NO split is open (results, credits,
                                       --   run recap, strike popups, paddock pause, NEXT PLANET): the screen owner's pad
                                       --   then never reaches P1's player (his short A / B no longer act on P1's screen).
                                       --   false = parked only while a guest split is open
cfg.CouchSaveOwner        = true       -- couch-savepath: the campaign saves (run + meta) always go to P1's account folder
                                       --   (SaveGames/<steamid>/): while the pad ids are swapped they follow the local
                                       --   player that holds pad id 0. false = the old behaviour: saves written while a
                                       --   guest-owned screen is up land in the account-less SaveGames/ root slot
cfg.CouchSaveOwnerManager = true       --   (advanced, with CouchSaveOwner) also the save manager's own LocalPlayer (new save
                                       --   objects copy it). false = only the existing save objects
cfg.CouchSaveListener     = true       -- couch-savepath: the mod's own (invisible) save icon listens to the campaign save
                                       --   manager's save events (the friends' run checkpoints). false = the game's own
                                       --   icon (when it exists) and the run-clock fallback only
cfg.CouchDormantScreens   = true       -- couch-savepath: after every guest left (their pads dormant), the paddock /
                                       --   post-race screens the game gives to a dormant guest's player are driven by P1's
                                       --   pad (the same pad-id swap as with joined guests). false = off (soft lock)
cfg.CouchToastMs         = 4000      -- the "COUCH CAMPAIGN: P2 JOINS THE RUN" banner when the couch rules turn on, in
                                       --   ms (shown once per session and guest set). 0 = no banner
cfg.CouchPanelZ           = 1000       -- (advanced) screen layer of the guests' areas; must stay above the game's
                                       --   post-race screens (500)
cfg.CouchTeamResult       = "best"     -- 0.15 COUCH CAMPAIGN rules (couchrules.lua): whose finish the campaign books - "best"
                                       --   (eliminator top 3 / must-win met when the BEST human makes it) | "p1" (P1 only)
cfg.CouchIngestGate       = true       -- 0.15: the result gate (one booking per race; without it every human's finish is
                                       --   booked into P1's run natively: double credits, a guest's 4th = a token)
cfg.CouchWreckToken       = "all"      -- 0.15: "all" = a wreck costs a token only when every human wrecked (refunds) |
                                       --   "each" = every human's wreck costs one (native, extended to guests)
cfg.CouchWreckRefundRewards = false    -- couch-fix30 (audit 12 Q2, recommendation = solo rule): a REFUNDED wreck gives
                                       --   back the team's League Token only - P1's own wreck costs him his reward round
                                       --   like a wrecked guest's (false). true = the old rule: P1's refunded wreck also
                                       --   gets his reward round back. (Pending Jules's answer to Q2.)
cfg.CouchRiskBand         = 1          -- 0.15: "p1" rule, eliminations: a guest in the last N places closes the gate (>= 1)
cfg.CouchFinalWinSwap     = true       -- 0.15: "best": a guest winning the run's final event shows as P1's win
cfg.CouchChampionGrid     = true       -- 0.15: Championship (HeadToHead) grid +guests, so they race the boss too
cfg.CouchBossIntroSwap    = true       -- #97: a championship with guests plays the track's own intro instead of the boss
                                       --   story intro (its Player + Rival car bindings froze the game with 2 local chains)
cfg.CouchBossInstances    = true       -- couch-fix38 (Jules Q12 B): a championship / boss race with guests = one copy of
                                       --   the boss race per player (his own boss car, field and result; couchrules D8,
                                       --   instances.lua); the act is won if ANY player beats his own boss ("best"). false
                                       --   = the shared boss race (D7: every player races the one boss). Needs
                                       --   CouchMissionInstances and CouchChampionGrid.
cfg.CouchRivalRaces       = true       -- couch-fix58 (Jules: every player races every campaign race): a RIVAL CHALLENGE
                                       --   (the head-to-head vs a named rival) gets every guest a place (couchrules D5):
                                       --   the team's challenge is won if ANY player beats the rival. false = guests sit
                                       --   it out (the old rule, CouchSitOutShare below)
cfg.CouchRivalInstances   = true       -- couch-fix58: ... raced as one copy per player (each vs his own copy of the
                                       --   rival, like CouchBossInstances); false / no spare AI PlayerState = one shared
                                       --   race (every player vs the one rival). Needs CouchMissionInstances.
cfg.CouchSitOutShare      = 0.5        -- 0.15: a guest sitting out (rival challenge) gets this x the planet's skip bonus
cfg.CouchSaveCounter    = true       -- couch-livefix r2: the guests' checkpoints follow the run save objects' request counters
                                     --   (ULocalPlayerSaveGame.CurrentSaveRequest; the save hooks never fire live).
                                     --   false = the run clock alone
cfg.CouchGuestStartCredits = "p1"     -- couch-econ: a guest's run starts with P1's starting credits (couch-fix31: P1's
                                       --   RUN-START figure, noted per run id - a late joiner never gets P1's wallet
                                       --   now); a number = that many; false = 0 (the pre-econ behaviour)
cfg.CouchSeatPadMemory    = true       -- couch-fix31: a pad that joins sits down in the seat its ControllerId held last
                                       --   time (kept in couch-run.txt across a relaunch), not in join order; a seat
                                       --   remembered for another pad that is here is kept free for it. false = join order
cfg.CouchWreckCredits     = 0          -- couch-econ: a wrecked guest's credits (native: a wrecked racer is never paid)
cfg.CouchBets             = true       -- 0.15 (couchbets.lua): the pre-race /CHALLENGES (side bets) split: each guest gets
                                       --   the game's own challenges screen in his area, same racers and stakes, his own
                                       --   credits. false = the challenges stay P1's only
cfg.CouchBetsNative       = true       -- the guest's area shows the game's own challenges screen. false = a plain list
cfg.CouchBetRule          = "beat"     -- a guest's challenge is won when he finishes AHEAD of that racer ("beat") |
                                       --   when that racer finishes worse than his predicted place ("predicted")
cfg.CouchBetPayout        = 2          -- a won challenge pays stake x this into the guest's credits (2 = stake back + the
                                       --   same again); a lost one keeps the stake; a race left before its result refunds
cfg.CouchBetWaitGuests    = true       -- couch-rewards #8: P1's challenge / decline waits until every joined guest has
                                       --   challenged or declined (P1's area: "WAITING FOR P2"); then the game moves on
cfg.CouchBetWaitMs        = 20000      -- ... at most this long after P1's pick (a guest who has not chosen = declined);
cfg.CouchBetForceMs       = 2000       -- ... or P1 holds A this long once more to move on at once
cfg.CouchBetHoldMs = 750               -- /CHALLENGES: every row is a hold (decoded bRequiresHold); used when the row's own
                                       -- GetRequiredHoldTime is unreadable (CommonUI's default HoldTime 0.75 s)
cfg.CouchBetP1Bridge      = true       -- the challenges screen belongs to a guest's PlayerController: P1's focus is put on
                                       --   it and his A runs the button he focuses (HOLD A = DECLINE), unless the game
                                       --   already acted. false = P1's native input only

---------------------------------------------------------------------------------------------------- Pause (pause.lua)
-- 0.7.0 (run H: a guest's Start soft-locked the game in [PauseMenu] with no screen, no pause screen of a split race took
-- any input, nobody could pause after P1's wreck; notes/research/pause-split.md §6). In a split race the UIManager makes
-- every screen for the LAST local PC (P2 in 2P) and the InputModeManager gives UI input to the FIRST local player only.
-- Layers A-G below run only while a split race runs; each key turns its layer off alone. If the first live pause
-- crashes: PauseHookReadState = false, then PauseCsmHook = false (A, D, F and G keep running without the hook).
cfg.GuestPauseMode        = "hud"      -- "hud" | "poll" | "off"                            VERIFY(V-PAU-01)
cfg.GuestHudRegisterInput = false      -- guest HUD RegisterInputComponent(); keep false: pause.lua turns the inputs of
                                       --   every HUD we host off at a pause request and on after the resume  V-PAU-01
cfg.P1PausePoll           = true       -- FAST poll of P1's Start/Escape opens the pause menu while P1 has no race-HUD
                                       --   binding of its own: P1HudMode "rehost" (the re-add drops it), or no P1 clone
                                       --   and the game's HUD owned by a guest ("leave")             VERIFY(V-PAU-03)
cfg.GuestPauseFallback    = true       -- GuestPauseMode "hud": guests' Start is polled too (deferred fallback)  VERIFY(V-PAU-01)
cfg.PauseDeferMs          = 200        -- a polled pause press acts only if the game did not pause by itself within
                                       --   this time (no double ChangeStateTo when the HUD binding works)
-- A: HUD input guard
cfg.PauseHudInputGuard    = true       -- A1: the game's HUD owned by a guest that has its own HUD loses its input (two
                                       --   IA_Veh_Pause bindings on one player = the run-H soft lock); A2: every HUD we
                                       --   host loses its input from the pause request until the resume and every
                                       --   pause/player key up (held Start)                      VERIFY(V-PAU-09/18)
cfg.PauseInputsBackMs     = 150        -- A2: the HUD inputs come back this long after the resume, once every pause /
                                       --   player key is up (> 0)                                VERIFY(V-PAU-09)
-- B: request hook
cfg.PauseCsmHook          = true       -- B: native pre-hook on CosmeticStateMachine:ChangeStateTo, registered only while
                                       --   a split race runs (armed flag first; unregistered at POSTRACE / leaving).
                                       --   false = no request hook (no pre-create; A, D, F, G still run)  VERIFY(V-PAU-11)
cfg.PauseHookReadState    = true       -- B: read ChangeStateTo's newState (run H's probe read Blueprint callers' params
                                       --   correctly); false = the request is inferred from the pause CSM state and the
                                       --   keys (first fallback if the first live pause crashes)  VERIFY(V-PAU-11)
cfg.PauseHookTrace        = false      -- B: log every ChangeStateTo on the pause CSM (target, paused, active states)
-- C: the screen made for the controlling player
cfg.PauseMenuPrecreate    = true       -- C: the pause / player screen is created for the controlling player inside the
                                       --   hook and ACQUIRED by the CSM (UIManager acquire path; our extra reference is
                                       --   released). A request no pause followed is undone after 600 ms  VERIFY(V-PAU-11)
cfg.PauseMenuOwner        = "pauser"   -- C: its owner: "pauser" (the pad of the player who paused navigates it) | "p1"
                                       --   (the single-player setup: the safest first test) | "game" (alias "keep": the
                                       --   UIManager's own owner, the last local PC; no pre-create)  VERIFY(V-PAU-15)
cfg.PauseOwnerPadShift    = "auto"     -- C, KeyboardIsP1: a pad pauser with ControllerId c gets a screen owned by
                                       --   ControllerId c-1 (CommonUI routes by the pad's platform user) | "off"  V-PAU-15
cfg.PauseMenuZ            = "auto"     -- C: viewport ZOrder of that screen: "auto" (the UIManager's own Menu Z once seen,
                                       --   else the WBP_Dialog_Container Z - 1, else PauseMenuZOrder) | a number >= 0
-- D: UI input for the guests
cfg.PauseUiImcBoost       = "all"      -- D: guests' IMC_UI at UIManagerSettings.UI_IMC_ActivePriority (500) while paused,
                                       --   restored on resume / leaving / FRONTEND (P1 stays with the game's
                                       --   InputModeManager): "all" | "owner" (only a guest that owns the menu) | "off"
                                       --                                                         VERIFY(V-PAU-10)
-- E: focus
cfg.PauseMenuFocusOwner   = true       -- E: the menu owner's slate focus is put back on the menu's first button when
                                       --   lost (every 500 ms, at most 6 times per menu; no rehost needed)  V-PAU-15
-- F: safety net
cfg.PauseLostMenu         = "recover"  -- F: "recover" (F1: [PauseMenu] without a sub-state -> BP_CsmPickPauseMenu's
                                       --   choice, after 2 repairs resume; F2: a menu state without its screen for
                                       --   PauseLostMenuMs -> resume; a screen is never re-added) | "probe" (log only) |
                                       --   "off"                                                  VERIFY(V-PAU-12)
cfg.PauseNoSubStateMs     = 150        -- F1: [PauseMenu] without a Paused_* / PlayerMenu sub-state this long -> repair (> 0)
cfg.PauseLostMenuMs       = 1500       -- F2: a menu state without its screen this long -> resume
cfg.PauseAnyStartResumes  = "fallback" -- F3: a pause key of a player who does not own the menu ("always": anyone's)
                                       --   counts once the menu is up 400 ms; the game is resumed from Lua if the menu
                                       --   did not close within 300 ms | "off"                    VERIFY(V-PAU-13)
-- G: after a wreck
cfg.PauseRestartCsm       = "onpress"  -- G: after P1's wreck / finish (the pause CSM is gone) a pause key restarts
                                       --   CSM_PauseMenus_Root | "eager" (as soon as it is gone) | "off"; EndStateMachine
                                       --   at POSTRACE / leaving                                  VERIFY(V-PAU-16)
-- menu helpers kept from 0.5 / 0.6
cfg.PauseMenuFix          = true       -- run E: while paused, the active pause screen and its ancestors are forced
                                       --   visible/opaque                                         VERIFY(V-PAU-04)
cfg.PauseMenuRehost       = "never"    -- 0.7.0: "never" (default) | "always" (A/B tests only: the CSM's screen re-added
                                       --   once to the whole viewport; run H: a re-added screen took no input) | "auto"
                                       --   (the 0.6 default, now the same as "never")             VERIFY(V-PAU-04)
cfg.PauseMenuZOrder       = 50         -- viewport Z order of an A/B rehost, and the pre-create's last-resort Z (PauseMenuZ)
cfg.PauseMenuRehostDelayMs = 50        -- rehost "always": done this long after the menu is first seen  VERIFY(V-PAU-06)
cfg.PauseMenuSettle       = true       -- once per menu instance, PauseMenuSettleMs after first sight (or the re-add),
                                       --   every intro-animated part still below its end value (opacity 1, blur 10) is
                                       --   set to it                                              VERIFY(V-PAU-06)
cfg.PauseMenuSettleMs     = 1500       -- see PauseMenuSettle
cfg.PauseHideHudsAtOnce   = true       -- our per-player HUDs are hidden on the pause edge itself (FAST), not on the next
                                       --   250 ms MAIN tick (run F: SYSTEMS CRITICAL drawn over the menu)  VERIFY(V-PAU-06)
-- 0.8.0 phase 2: every screen opened FROM a split-race pause (Settings and its pages, the Logbook, the confirm dialogs)
-- belongs to the pause controller (the player the pause screen was made for). menubridge.lua side: MenuBridge* (Core).
cfg.PauseSubScreenPrecreate = true     -- C2: Settings, its pages and (only with PauseSubScreenHook) the Logbook are
                                       --   pre-created for the pause controller and acquired by the CSM  VERIFY(V-PAU-19)
cfg.PauseSubScreenHook    = false      -- B2: native pre-hook on CosmeticStateMachine:ChangeToState while a split race runs
                                       --   (the Logbook request; needs PauseCsmHook). OPT-IN: its first param is a
                                       --   by-value SOFT pointer (HARD RULE, ARCHITECTURE Revision 0.5.1 §1: run F crashed
                                       --   after hooking TestPreflightCheckInput, a soft param). The callback never reads
                                       --   it, but UE4SS wraps every param of every call. true ONLY for the dedicated
                                       --   V-PAU-20 run; false: the Logbook is made for the last local PC and menubridge's
                                       --   controller fallback drives it                            VERIFY(V-PAU-20)
cfg.PauseDialogGuestUi    = "lower"    -- D2: "lower": guests' IMC_UI back to default while a confirm dialog is up (the pause
                                       --   controller answers it through menubridge; its presses must not also hit its own
                                       --   pause screen under the dialog) | "keep"                    VERIFY(V-PAU-21)
-- 0.11.0 RESTART RACE (restart.lua, notes/research/restart-race.md): the game's own RETRY row of WBP_Pause, put back
-- right below RESUME in the pause menu of an offline custom race SWGRCouch launched (RACING only; never online, campaign,
-- arcade or on a network client), confirmed by the game's RetryRace dialog, then RacingGameMode:RequestResetRace (the
-- same map, seamless). Not PauseRestartCsm above (G: the pause state machine after P1's wreck).
cfg.PauseRestart          = true       -- the RESTART RACE entry; false = the pause menu stays the game's   VERIFY(V-RST-01)
cfg.PauseRestartConfirm   = "dialog"   -- "dialog": the game's Btn_RetryRace + its RetryRace confirm dialog; Accept is seen
                                       --   by a native pre-hook on ArcadeSubsystem:RequestRestartEvent (registered while
                                       --   such a race is RACING) | "twice": an own row, confirmed by a second press
                                       --   within PauseRestartConfirmMs (no hook, no dialog: if V-RST-03 fails)  V-RST-03/12
cfg.PauseRestartConfirmMs = 5000       -- "twice": the second press must come within this time (> 0)  VERIFY(V-RST-12)
cfg.FastBootSignIn        = "always"   -- 0.13.0 "always": the 10 s SIGN IN STATUS wait at every main menu visit is skipped
                                       -- (Steam offline never signs in; online the login goes on in the background);
                                       -- "off": the game's wait
cfg.PauseRestartHow       = "relaunch" -- 0.13.0 "relaunch": RESTART RACE goes to the menu and launches the same race again
                                       -- (the in-place reload never respawns the AI cars); "reset": the in-place reload
cfg.PauseRestartRelaunchMs = 1200      -- 0.13.0 delay between the FREE MODE page coming back and the relaunch
cfg.PauseRestartRelaunchWindowMs = 15000 -- 0.13.0 the FREE MODE page must show within this after the menu, else no relaunch
cfg.PauseRestartSequence  = "direct"   -- "direct": RequestResetRace in the FAST tick after the confirm, from the pause (the
                                       --   live-proven state: the 2026-10-10 restart test ran from P1's auto-pause) |
                                       --   "resume": RESUME first, the call PauseRestartAfterResumeMs after the pause ended
                                       --                                                          VERIFY(V-RST-06)
cfg.PauseRestartLabel     = "game"     -- "game": MenuText.Pause_Button_Restart ("Restart Race", localised) | "retry": the
                                       --   row's own label ("Retry") | any other text: that text     VERIFY(V-RST-02)
cfg.PauseRestartPosition  = "below_resume" -- "below_resume" (the rows under RESUME move down one) | "end" (appended
                                       --   under ABANDON TOUR, nothing moved)                          VERIFY(V-RST-02)
cfg.PauseRestartRemote    = false      -- also offered while remote humans are connected or expected (untested: the
                                       --   restart travels every client)                               VERIFY(V-RST-09)
cfg.PauseRestartArcadeGuard = true     -- "dialog": ArcadeSubsystem.LastPlayedArcadeEvent (set by an Arcade event played
                                       --   earlier) is cleared while the entry is offered, so the game's own
                                       --   RequestRestartEvent never travels to that event; restored at FRONTEND.
                                       --   false: the entry is not offered while it is set              VERIFY(V-RST-05)
cfg.PauseRestartAfterResumeMs = 250    -- "resume": RequestResetRace this long after the pause ended (>= 0)  V-RST-06
cfg.PauseRestartWatchdogMs = 5000      -- still the same world this long after RequestResetRace: LEAVING undone (> 0)
                                       --                                                          VERIFY(V-RST-08)

---------------------------------------------------------------------------------------------------- Race
cfg.AIOnPadDisconnect = true           -- Disconnect override on pad loss (server)
cfg.AllowMidRaceJoin  = false          -- debugging only: F6 in a race creates + takes over
cfg.ReRegisterP1Pawn  = false          -- re-register P1's pawn with audio world subsystems  VERIFY(V-TKO-10)

---------------------------------------------------------------------------------------------------- Wrecks (wreck.lua)
-- 2026-10-07 report: "a wreck (top or bottom player) ends the race for everyone; P2's wreck view is black, no slow-mo".
-- Offline the game ends the race 2 s after the first human finishes OR is wrecked. notes/research/wreck-design.md.
cfg.WreckMode             = "spectate" -- "spectate": a wrecked player watches the race in its own view and the race
                                       --   goes on until every local human finished or was wrecked | "noWreck": local
                                       --   humans never wreck (a crash only tumbles and resets; NoWreckMethod) | "game":
                                       --   vanilla (the race ends 2 s after the first human out)   VERIFY(V-WD-01/02/08)
cfg.FinishGraceSec        = "all"      -- after a human REALLY finishes: "all" = wait for every human | N (number) = the
                                       --   others get N s, with the game's own countdown (online uses 30) | 0 = the game's
                                       --   2 s. Wrecks never start a countdown (except WreckMode "game")  VERIFY(V-WD-12)
cfg.NoWreckMethod         = "build"    -- WreckMode "noWreck": "build" (UseHealth off on each local human's vehicle builds;
                                       --   AI still wreck) | "cvar" (Race.InfiniteHealth 1: nobody wrecks, AI included)
                                       --   | "topup" (health refilled just before a wrecking crash). Every method keeps
                                       --   the top-up as a safety net                                  VERIFY(V-WD-08)
cfg.WreckSlowMo           = "game"     -- crash-cam slow motion slows the WHOLE world (both views): "game" (default:
                                       --   world-wide slow-mo on ANY human wreck, P2's included; emulated on
                                       --   WorldSettings.CinematicTimeDilation 1 -> 0.1 -> 0.8 -> 1 over 2.4 s when the
                                       --   game's crash-cam slow-mo does not run, see WreckSlowMoEmulate) | "last" (off
                                       --   while 2+ local humans race and for 3 s after a wreck; the last human's wreck
                                       --   gets it) | "off" (no slow-mo while the race is split)  VERIFY(V-WD-14/16)
cfg.WreckSlowMoEmulate    = true       -- "game": emulate the slow-mo when no dilation < 1 shows up within
                                       --   WreckSlowMoWaitMs of a human wreck (false = the game's own only)  VERIFY(V-WD-16)
cfg.WreckSlowMoWaitMs     = 350        -- see WreckSlowMoEmulate
cfg.WreckView             = "native"   -- 0.7.2 (run J): default "native" = the game's own spectate (renders in a guest's half and
                                       --   follows AI racers). Older note: what a wrecked player sees after its wreck camera: "car" (default: guests watch
                                       --   a MOVING racing car through its own chase camera; the game's static spectate
                                       --   camera made P2's half black in run E) | "carAll" (P1 too) | "native" (the
                                       --   game's spectate camera)                                  VERIFY(V-WD-05/07/18)
cfg.WreckCrashCamHoldMs   = 4000       -- the wreck camera (the pawn's CrashCam) is put back as the view this long after a
                                       --   human wreck; 0 = no wreck-camera hold                     VERIFY(V-WD-18)
cfg.WreckTargetStaticMs   = 4000       -- WreckView "car": a watched car standing still this long is replaced
cfg.WreckViewReapplyMs    = 1500       -- WreckView "car": the view moved by something else is put back at most this often
cfg.WreckSpectateReasserts = 30        -- 0.13.0 (#15): native spectate re-selects allowed while the game's crash camera holds a
                                         -- wrecked player's view (every 2 s; 3 for any other view)
cfg.WreckViewBlendSec     = 0.0        -- WreckView "car": SetViewTargetWithBlend blend time
cfg.WreckCarCam           = "auto"     -- 0.7.2: "auto": a car without a camera (AI) through the chase rig (the rig's
                                       --   post-process letterbox is now off: it rendered BLACK in a guest's half);
                                       --   "own": a guest keeps its OWN wreck in view instead (0.7.1 behaviour);
                                       --   "override": its own pod camera follows that car (TargetActorOverride: renders,
                                       --   but the game then paused itself again and again, experiment only); "rig".
                                       -- 0.6.0 (run G F3: camera inside the AI pod's engine): how a watched car is
                                       --   shown: "auto" (a local player's car: its own chase camera; a car without a
                                       --   camera stack (AI) or a badly placed camera: the chase rig) | "rig" (always the
                                       --   rig) | "car" (always the car's own camera, 0.5.1)       VERIFY(V-WD-19/20)
cfg.WreckCarCamMinDistUU  = 300        -- "auto": the car's camera must be at least this far from the car ...
cfg.WreckCarCamBehindUU   = 150        -- ... and at least this far behind it, else the rig takes over
cfg.WreckRigBackUU        = 900        -- chase rig (a camera actor attached to the watched car): distance behind
cfg.WreckRigUpUU          = 260        -- chase rig height
cfg.WreckRigPitch         = 10         -- chase rig downward pitch (degrees)
cfg.WreckRigFov           = 85         -- chase rig field of view
cfg.WreckFadeRead         = true       -- read PlayerCameraManager FadeAmount/bEnableFading (custom properties from the
                                       --   SetManualCameraFade offsets); false = never register them, blind StopCameraFade
                                       --   only                                                       VERIFY(V-WD-15)
cfg.WreckCinematic        = "end"      -- wrecked while another human races: "end" its single-player failed-event
                                       --   cinematic | "keep"                                          VERIFY(V-WD-06)
cfg.WreckSpectateTarget   = "ai"    -- whom a wrecked player watches: "human" (another local human still racing,
                                       --   then the leader) | "leader" | "ai" (an AI car first)        VERIFY(V-WD-07)
cfg.WreckSpectateWaitMs   = 800        -- the game's spectate not running this long after the wreck: asked for again
cfg.WreckViewGuard        = "auto"     -- wrecked player's camera: "auto" (checked every 33 ms; unusable -> fallback view)
                                       --   | "force" (always our fallback view, never the game's spectate camera) | "off"
                                       --   VERIFY(V-WD-04/05)
cfg.WreckViewFallback     = "racer"    -- fallback view: "racer" (a car still racing: AI first, then a human) | "own"
                                       --   (the player's own wreck, normal chase camera; a racing car once it is gone)
cfg.WreckCamMaxDistUU     = 15000      -- "auto": a camera farther than this from the car it shows is unusable
cfg.WreckCamBadMs         = 400        -- "auto": unusable this long -> fallback view
cfg.WreckFadeClearMs      = 1500       -- a fade held this long on a wrecked view is cleared (StopCameraFade), checked
                                       --   every FAST tick; when the fade fields are unreadable, StopCameraFade is called
                                       --   blindly every 1 s from this time after the wreck. 0 = never   VERIFY(V-WD-15)
cfg.WreckProbe            = false      -- camera probe lines at the wreck and +0.5/+2/+4.5/+6/+10/+20/+40 s and after
                                       --   photo mode (view, camStill, fade, phase, watched car, photo)  VERIFY(V-WD-04)
                                       --   0.12.0: off by default (research probe)
cfg.SpectateWidgetMode    = "hide"     -- P1 wrecked, guests racing: the game's full-screen spectate panel
                                       --   (WBP_PVP_Spectate_C) is "hide"-n until no guest races | "hide_inactive" (+
                                       --   DeactivateWidget while hidden) | "leave"                    VERIFY(V-WD-11)

---------------------------------------------------------------------------------------------------- Crashes (crashcam.lua)
-- Run F report: "P2's view goes black when P2's pod crashes; P1's crash shows the crash camera with slow-mo". A crash
-- (tumble + reset, no wreck) of a local human; wreck.lua owns wrecks. Static findings: crashcam.lua header.
cfg.CrashCamGuest         = "auto"     -- 0.7.2: "auto" (default): the guest keeps the GAME's crash camera (its
                                       --   post-process letterbox is cleared: CrashCamLetterboxFix) unless it proves unusable. Older note: guest crash view: "car" (default since 0.6.0: run G showed the game's crash
                                       --   camera rendering BLACK for P2 even with a valid shot, 3405 uu, no fade) |
                                       --   "auto" (the game's crash camera while usable, else the guest's own car) |
                                       --   "keep" (probes only) | "off"
                                       --                                                            VERIFY(V-CC-02)
cfg.CrashCamLetterboxFix  = true       -- 0.7.2: clear the crash camera's post-process letterbox for guests (it rendered black)
cfg.CrashCamPlayers       = "guests"   -- "guests" | "all" (P1 too)
cfg.CrashCamLearn         = true       -- a crash camera proved unusable once -> that player's later crashes go to the
                                       --   car at once
cfg.CrashCamModeCheck     = true       -- null InitialCameraMode = no shot (trusted only after one valid read, e.g. P1's)
cfg.CrashCamBadMs         = 150        -- unusable this long -> own car view
cfg.CrashCamMaxDistUU     = 15000      -- a crash camera farther than this from its car is unusable
cfg.CrashCamStuckMs       = 9000       -- a crash camera still the view this long -> own car view
cfg.CrashCamFadeClearMs   = 1500       -- a fade >= 0.5 held this long around a crash is cleared (0 = never)  VERIFY(V-CC-04)
cfg.CrashCamBlindFade     = true       -- fade fields unreadable: one blind StopCameraFade after CrashCamFadeClearMs
cfg.CrashCamAfterMs       = 4000       -- the fade guard keeps watching this long after the crash
cfg.CrashCamProbe         = false      -- probe lines at the crash, +0.5 s, +2 s, the switch and the end   VERIFY(V-CC-01)
                                       --   0.12.0: off by default (research probe)
cfg.CrashCamWreckHold     = "proven"   -- wreck.lua's wreck-camera hold (WreckCrashCamHoldMs) for a GUEST: "proven" (only
                                       --   once that guest's crash camera was seen working in a crash; user after run
                                       --   F: "the wrecked is still black screen") | "never" | "always" (skip only a
                                       --   known-bad one)                                              VERIFY(V-CC-06)
cfg.CrashSlowMoEmulate    = true       -- WreckSlowMo "game"/"last": a guest crash whose camera was replaced gets the
                                       --   pod crash slow-mo emulated on CinematicTimeDilation      VERIFY(V-CC-05)
cfg.CrashSlowMoCurve      = { { 0, 1.0 }, { 200, 0.2 }, { 1200, 0.2 }, { 2200, 0.7 }, { 2500, 1.0 } }
                                       -- {real ms, dilation} (CVF_Slowmo_Crash_Plane), rising ms

---------------------------------------------------------------------------------------------------- Phase / photo mode (phase.lua)
cfg.PhaseBootWarnMs       = 3000       -- a live world still classified BOOT this long after a (hot) reload: one warning
                                       --   (phase.redetect runs on the first frame after load)      VERIFY(V-CORE-14)
cfg.PhotoModeCacheMs      = 200        -- phase.photoMode() cache: PhotoModeManager.bPhotoModeActive / a local PC on a
                                       --   *PhotoModePawn / CSM_PauseMenus_Photomode. hud, pause, inputfix and present
                                       --   back off while it is open; wreck.lua has its own 150 ms copy   VERIFY(V-PH-01)

---------------------------------------------------------------------------------------------------- Graphics
cfg.GfxPresets = {
    performance = {
        ["sg.GlobalIlluminationQuality"] = 0, ["sg.ReflectionQuality"] = 0, ["sg.ShadowQuality"] = 1,
        ["sg.EffectsQuality"] = 1, ["sg.ViewDistanceQuality"] = 1, ["r.Shadow.Virtual.Enable"] = 0,
        ["r.Lumen.DiffuseIndirect.Allow"] = 0, ["r.ScreenPercentage"] = 50,
    },
    -- 0.13.0 (measured live 2026-10-12 00:00, 2P Jakku, both cars still, 1280x720, RTX 5070 Ti, uncapped): user Epic
    -- 112 fps; the 0.12 "quality" (GI 1, refl 1, shadows 1, ScreenPercentage 62) 112.5 = no gain; Lumen GI + reflections
    -- off 143; + shadows 2 without virtual shadow maps 161 (= "performance" 164, at full resolution and full effects /
    -- view distance); ScreenPercentage 50 on top: 159 (no gain). So "quality" keeps the resolution and drops Lumen
    -- and the virtual shadow maps.
    quality = {
        ["sg.GlobalIlluminationQuality"] = 0, ["sg.ReflectionQuality"] = 0, ["sg.ShadowQuality"] = 2,
        ["r.Shadow.Virtual.Enable"] = 0, ["r.Lumen.DiffuseIndirect.Allow"] = 0, ["r.Streaming.PoolSize"] = 3000,
    },
}
-- Correctness values applied in EVERY split race, whatever SplitGraphics says (also "off"); saved and restored like the
-- preset. r.SSGI.Quality 0: screen-space GI breaks every view but the first one. Levels whose lighting actor
-- (BP_GlobalLighting_HDRI_Base's unbound PostProcess) forces DynamicGlobalIlluminationMethod 2 (ScreenSpace) with
-- IndirectLightingIntensity 2.25 (Husky; Jakku has 0) gave P2 a dark / brown / blown-out white-magenta picture while P1
-- was fine. Proven live 2026-10-14 on Jakku with both views on P1's car: method 2 -> P2 sand black (P1 normal), method
-- 0 or r.SSGI.Quality 0 -> both halves equal within 1 %. false = off.
cfg.GfxSplitFixes = { ["r.SSGI.Quality"] = 0 }
cfg.GfxAutoQualityMaxViews = 2         -- "auto": quality for <= 2 views, performance above
cfg.GfxApplyMode           = "console" -- "console" (every cvar via ExecuteConsoleCommand, ARCHITECTURE contract) |
                                       -- "usersettings" (sg.* through GameUserSettings setters + ApplyNonResolution-
                                       --   Settings; a game-side SaveSettings during a split race would persist the
                                       --   preset into GameUserSettings.ini)                      VERIFY(V-GFX-05)

---------------------------------------------------------------------------------------------------- Takeover
cfg.SlotMode               = "auto"      -- "auto" | "off"
cfg.TakeoverGraceMs        = 3000
cfg.TakeoverWhen           = "started"   -- "started" | "countdown"
cfg.TakeoverMidGameJoiners = false
cfg.TakeoverPick           = "last"      -- "last" | "first"
cfg.TakeoverAdoptPS        = true        --                                                 VERIFY(V-TKO-03)
cfg.TakeoverIdleAI         = false       --                                                 VERIFY(V-TKO-01)
cfg.TakeoverBindInput      = true        --                                                 VERIFY(V-TKO-01)
cfg.TakeoverBindInputRemote = true       -- remote takeovers: send the Client_BindInputActions RPC once (verify#1)
                                         --                                                 VERIFY(V-TKO-12)
cfg.TakeoverForceRawInput  = false       --                                                 VERIFY(V-TKO-01)
cfg.TakeoverClearBotFlag   = false
cfg.FinishIdlePlayerStates = true        --                                                 VERIFY(V-TKO-07)
cfg.FinishUncarriedRacers  = false       -- safety net: once every carried racer is done, finish Racers entries no car
                                         --   carries (e.g. a remote client that left mid-race)       VERIFY(V-TKO-07)
cfg.RacerPSSource          = "pawn"      -- "pawn" (pc.Pawn.PlayerState when no takeover record) | "controller"
                                         --   (pc.PlayerState) for HUD lap/position and name tags      VERIFY(V-TKO-05)
cfg.TakeoverAICarTest      = "original"  -- "original" (GetOriginalInputSource()==AI) | "override" (SpawnAI override
                                         --   + bot PS)                                          VERIFY(V-TKO-02)
cfg.TakeoverEndSpectateRemote = "joiner" -- "joiner" | "always" | "off": Client_OnSpectatorModeEnded for remote
                                         --   takeovers                                          VERIFY(V-TKO-11)

---------------------------------------------------------------------------------------------------- Network
cfg.JoinMethod                = "openlevel_opts"  -- "openlevel_opts" | "openlevel" | "console"  VERIFY(V-NET-05/06)
cfg.HostTravelFallback        = "relisten"        -- "relisten" | "relisten_takeover" | "none"  VERIFY(V-NET-13)
cfg.ServerTravelOnMissingCars = false
cfg.AutoRelistenInFrontEnd    = true
cfg.AutoRejoin                = true
cfg.RejoinAfterQuitToMenu     = false             -- true: a client's pause-menu Quit (UIBlueprintFunctionLibrary:
                                                  --   ReturnToMainMenu) still auto-rejoins the host  VERIFY(V-NET-19)
cfg.IrisOff                   = false             -- net.Iris.UseIrisReplication 0 at first world  VERIFY(V-NET-03)
cfg.NetSafetyCvars            = {}                -- console lines run on hosting start         VERIFY(V-NET-12)
cfg.ListenCheckMs             = 10000
cfg.TravelCheckDelayMs        = 2000
cfg.RemoteArriveTimeoutMs     = 20000
cfg.ServerTravelWatchdogMs    = 10000             -- servertravel still in the same world after this = refused  VERIFY(V-NET-16)
cfg.RejoinWaitMs              = 60000             -- relisten: counted from the confirmed race-map listen
cfg.RejoinSettleMs            = 10000             -- the rejoin wait ends only after no arrival for this long (at
                                                  --   most 2 x RejoinWaitMs in all)
cfg.StopHostingMethod         = "openlevel_abs"   -- "openlevel_abs" (OpenLevel bAbsolute: LastURL ?listen dropped) |
                                                  --   "disconnect" (console disconnect -> GameDefaultMap)  VERIFY(V-NET-18)
cfg.RejoinDelayMs             = 3000
cfg.RejoinMaxTries            = 20
cfg.GuestAckMode              = "guests"          -- "guests" | "all" | "off"                  VERIFY(V-NET-09)
cfg.ClientMenuFallback        = "csm"             -- connected client whose front end shows no WBP_FE_MainMenu 5 s
                                                  --   after FRONTEND: "csm" (cosmetic ChangeStateTo(CSM_FrontEnd_
                                                  --   PrimaryModeSelect) on the CSM_FrontEnd_Root machine) | "off"
                                                  --   (log + status only)                         VERIFY(V-NET-17)
cfg.LoginLogEveryMs           = 5000

---------------------------------------------------------------------------------------------------- Settings defaults
-- Defaults of the persisted user settings (settings.lua type-checks against these types).
cfg.Defaults = {
    Layout2P           = "top-bottom",   -- "top-bottom" | "side-by-side"
    SplitGraphics      = "performance",  -- "performance" | "auto" | "quality" | "off"
    TakedownCams       = false,
    NameTags           = true,
    KeyboardIsP1       = false,
    NetMode            = "offline",      -- "offline" | "host" | "join"
    JoinAddress        = "10.8.0.1",
    Port               = 7777,
    LastRaceArchetype  = "",             -- object paths "/Game/.../X.X"
    LastRaceGameMode   = "",
    LastRacePlanet     = "",
    LastRaceTrack      = "",
    LastRaceBuild      = "",
    LastRaceDebugBuild = "",
    LastRaceCondition  = "",             -- gameplay tag string
    LastRaceMaxRacers  = 0,              -- RACE SETUP grid size (0 = the class limit)
    LastRaceVehicles   = "",             -- RACE SETUP per-player picks "1=PRE_Car_Orca@<build path>;2=..."
    LastRaceRacers     = "",             -- 0.10.0 RACERS step per pad "<ControllerId>=<pilot>@<preset>@<loadout code>;..."
    OpponentTier       = 1,              -- 0.12.0 RACE SETUP > MODE "Opponents": the speeder build tier the race launches
                                         --   on, i.e. the AI's strength (1 = TIER 1 [0%] .. 6 = TIER 6 [58%]); pods: 1
    RunLength          = "off",          -- OPTIONS > Galaxy run: "off" | "qualifier" | "league" | "kestar" | "sprint"
                                         --   (0.14 v3: the armed League preset; run.lua; the run itself is in run.txt)
    OpponentMatch      = false,          -- 0.13.0 CUSTOM Opponents "MATCH THE PLAYERS" (perkapply.matchLoadout)
    PlayMode           = "quick",        -- 0.13.0 FREE MODE QUICK RACE / CUSTOM RACE posters: "quick" (QUICK RACE: every
                                         --   human on the Opponents tier kit, no PERKS stage, quick.lua) | "custom"
    Name1              = "",             -- FREE MODE OPTIONS > PLAYER NAMES: custom name of P1..P4 ("" = the default:
    Name2              = "",             --   P1's profile name, cfg.GuestNames for P2-P4; nametags.lua)
    Name3              = "",
    Name4              = "",
    RunPick            = "qualifier",    -- FREE MODE GALAXY RUN poster: the League preset its A starts ("qualifier" |
                                         --   "league" | "kestar" | "sprint"; RIGHT steps it, RunLength arms the run)
    CouchMysteryTeam   = "greyed",       -- couch-fix39 (audit Q10) OPTIONS > COUCH CAMPAIGN > Guests' team mystery choices:
                                         --   "greyed" (couch-fix32: a guest's choice with a TEAM effect - a League token, a
                                         --   sabotage / debuff / difficulty / shop favour - is greyed) | "allowed" (he may
                                         --   take it: its team effect goes onto the shared run, counted once per encounter
                                         --   when P1 or another guest took the same; his economy effects stay his own).
                                         --   Deals paid by a later bookend stay greyed for guests either way (couchrun)
    CouchEconomy       = "own",          -- couch-fix35 (Jules's Q1): COUCH CAMPAIGN rules > P1's rewards. "own" = P1's
                                         --   wallet / reward round follow HIS own place (the team's best result only for
                                         --   tokens, must-win events and the act) | "best" = the best result carries
                                         --   everyone (the old rule). couchrules.ownEconomy, read at each race end
}
-- couch-fix36 (Jules's audit decision Q4; OPTIONS > COUCH CAMPAIGN; couchpenalty.lua). couch-fix41: no backer token
-- rule any more (solo parity: an unhappy backer never costs a League Token; CouchBackerTokens is retired)
cfg.Defaults.CouchBrokerPenalty = "both"  -- a guest's Broker penalty: "both" (the shared run's events become Eliminators
                                          --   for everybody) | "owner" (his own eliminator payout rule only)

---------------------------------------------------------------------------------------------------- override checks
-- Allowed values of the string selectors (config_user.lua overrides outside these lists are ignored with a warning).
local ENUMS = {
    LuaGcMode = { "generational", "incremental", "off" },        -- couch-racegc (gctune.lua)
    SubsystemLookup = { "sbl", "findfirst" },
    ClickMode = { "hook", "poll" },
    FastBootEpic = { "off", "keep" },
    FastBootSignIn = { "always", "off" },
    LobbyNavHighlight = { "both", "style", "focus" },
    LobbyNavKeyboard = { "always", "kbp1", "never" },
    BuilderAdopt = { "live", "go" },
    GuestCreate = { "join", "connected", "all" },
    GuestRemoval = { "never", "launch", "always" },
    OurTabSyncFix = { "clear", "off" },
    LobbyRootMode = { "setting_list", "own" },
    BuilderMode = { "embedded", "devscreen" },
    BuilderDevscreenExit = { "auto", "native", "csm" },
    GoMode = { "hook", "click" },
    TabDetectMode = { "hook", "both", "poll" },
    JoinFocusTrick = { "none", "userfocus", "viewport", "gameandui" },
    JoinButtons = { "a_or_start", "start" },
    DeviceDetectMode = { "hook", "both", "poll" },
    HotplugPadToP1 = { "front", "always", "off" },
    SetupTrackSet = { "quickrace", "arcade", "game", "all" },
    FrontEndMenuOwner = { "p1", "game" },
    ConditionPassMode = { "table", "trackdefault" },
    P1HudMode = { "rehost", "clone", "leave" },
    MemoryLapMode = { "hook", "collapse" },
    GuestHudNotifications = { "keep", "remove" },
    GuestMarkers = { "keep", "collapse" },
    HudVisibilityMode = { "csm", "always" },
    LocalResultsMode = { "hide", "hide_inactive", "rehost", "leave" },
    GuestPauseMode = { "hud", "poll", "off" },
    GfxApplyMode = { "console", "usersettings" },
    SlotMode = { "auto", "off" },
    TakeoverWhen = { "started", "countdown" },
    TakeoverPick = { "last", "first" },
    RacerPSSource = { "pawn", "controller" },
    TakeoverAICarTest = { "original", "override" },
    TakeoverEndSpectateRemote = { "joiner", "always", "off" },
    JoinMethod = { "openlevel_opts", "openlevel", "console" },
    HostTravelFallback = { "relisten", "relisten_takeover", "none" },
    StopHostingMethod = { "openlevel_abs", "disconnect" },
    GuestAckMode = { "guests", "all", "off" },
    ClientMenuFallback = { "csm", "off" },
    PresentViewMode = { "auto", "split" },
    IgnitionMode = { "auto", "perplayer", "simple", "p1game_guestauto", "complete", "off" },
    IgnitionPadAssist = { "auto", "always", "off" },
    IgnitionPadPrompts = { "pads", "off" },
    IgnitionFixedKeys = { "guests", "all", "off" },
    HudOutPlayers = { "hide", "keep" },
    PauseMenuRehost = { "auto", "always", "never" },
    PauseMenuOwner = { "pauser", "p1", "game", "keep" },
    PauseOwnerPadShift = { "auto", "off" },
    PauseUiImcBoost = { "all", "owner", "off" },
    PauseAnyStartResumes = { "fallback", "always", "off" },
    PauseRestartCsm = { "onpress", "eager", "off" },
    -- 0.11.0 RESTART RACE
    PauseRestartConfirm = { "dialog", "twice" },
    PauseRestartSequence = { "direct", "resume" },
    PauseRestartHow      = { "relaunch", "reset" },
    PauseRestartPosition = { "below_resume", "end" },
    IgnitionView = { "split", "single" },
    GuestNameMode = { "names", "off" },
    GuestNameMethod = { "auto", "rpc", "gamemode", "direct" },
    NameTagLabel = { "pnum", "name", "both" },
    InputFixMode = { "auto", "native", "kbsplit", "bind", "off" },
    InputFixNativeScope = { "race", "always" },
    InputFixGuestContexts = { "fill", "leave" },
    InputFixKbSplitP1 = { "kbp1", "always", "never" },
    SetupMode = { "setup", "builder" },
    SetupGridMode = { "typed", "playerchoice", "off" },
    WreckMode = { "spectate", "noWreck", "game" },
    NoWreckMethod = { "build", "cvar", "topup" },
    WreckSlowMo = { "off", "last", "game" },
    WreckCinematic = { "end", "keep" },
    GuestFinishCinematic = { "end", "keep" },
    WreckSpectateTarget = { "human", "leader", "ai" },
    WreckViewGuard = { "auto", "force", "off" },
    WreckViewFallback = { "racer", "own" },
    WreckView = { "car", "carAll", "native" },
    WreckCarCam = { "auto", "own", "override", "rig", "car" },
    PauseLostMenu = { "recover", "probe", "off" },
    InputFixGuestEnhanced = { "add", "off" },
    CrashCamGuest = { "auto", "car", "keep", "off" },
    CrashCamPlayers = { "guests", "all" },
    CrashCamWreckHold = { "proven", "never", "always" },
    SpectateWidgetMode = { "hide", "hide_inactive", "leave" },
    UxSplitMessages = { "route", "all", "off" },
    UxSplitMsgHide = { "collapse", "opacity" },
    UxSplitDanger = { "own", "neutral", "off" },
    UxSplitGuestHolo = { "hide", "keep" },
    -- 0.8.0
    UxSplitSubtitles = { "route", "log", "off" },
    UxSplitSubDetect = { "hook", "poll" },
    UxSplitSubBoth = { "clone", "game" },
    UxSplitSubUnmatched = { "both", "p1" },
    SetupPreviewExposure = { "inherit", "fixed" },
    SetupPreviewBounds = { "all", "colliding" },
    SetupPreviewRebuild = { "respawn", "update" },
    SetupPreviewBrush = { "material", "texture" },
    -- 0.9.0
    SetupCMapPlanetNav = { "chips", "list" },
    SetupCMapTrackView = { "map", "list" },
    SetupCMapManualTick = { "auto", "always", "off" },
    PauseDialogGuestUi = { "lower", "keep" },
    MenuBridgeGuestNative = { "skip", "bridge" },
    -- 0.10.0 RACERS step
    SetupPlayerFlow = { "cards", "classic" },
    CardP1Input = { "sink", "geometric", "ring" },
    CardFrame = { "darkpanel", "solid" },
    CardHighlight = { "pill", "solid" },
    CardDetail = { "game", "plain" },
    CardThumbMask = { "mid", "plain" },
    CardDiamond = { "disc", "hud" },
    CardGlyphs = { "xbox", "text" },
    CardSounds = { "match", "accept", "off" },
    PilotP1Default = { "shade", "favourite" },
    PilotSeatCheck = { "log", "refresh", "off" },
    PerkApply = { "full", "passives", "off" },
    PerkRamjet = { "keep", "on", "off" },
    TestBotsCrit = { "resolve", "timeout", "pass", "fail", "crash", "crashpre" },     -- couch-fix50 AUTO-129 / fix55
    PerkCritMalfunctions = { "keep", "on", "off" },
    PerkLaunchBase = { "zero", "pilot" },
    SetupPreviewSpinStage = { "vehicle", "all", "none" },
    -- 0.11.0 narrow-view HUD
    HudNarrowViews = { "readable", "fit" },
    HudNarrowTopBar = { "compact", "native" },
    HudNarrowHolo = { "hide", "keep" },
    -- 0.12.0 UI v2
    UiStyle = { "v2", "classic" },
    PreviewBackdrop = { "studio", "scenario", "cutout" },
    UiTitleWidget = { "game", "text" },
    UiHeroPill = { "backer", "painted" },
    StatusPillPlace = { "screen", "page" },
    UiTraitGlyph = { "decorator", "runs" },
    CardFigureTint = { "mid", "plain" },
    VehicleNameSource = { "load", "find", "table" },
    -- 0.15 guest garage
    CouchGarageApply = { "upload", "tags", "off" },
    CouchGarageUnlocks = { "p1", "all" },
    -- 4-way garage
    Garage4BayLivery = { "refresh", "ui", "off" },
    -- #38 race-progress strip
    HudProgressScale = { "p1", "fixed" },
}
-- Keys whose value is a string selector OR a number (FinishGraceSec: "all" | seconds >= 0; PauseMenuZ: "auto" | Z >= 0;
-- UxSplitSubHalfFrac: "auto" | a fraction 0..1). max is optional.
local MIXED = { FinishGraceSec = { strings = { "all" }, min = 0 }, PauseMenuZ = { strings = { "auto" }, min = 0 },
                UxSplitSubHalfFrac = { strings = { "auto" }, min = 0, max = 1 } }
-- Table-valued keys that also accept false (= feature off).
-- booleans that also accept a few selector strings (H01 2026-10-15: TestBots "all"/"guests" were rejected)
local BOOL_OR_ENUM = { TestBots = { "all", "guests", "p1", "off" } }
local FALSEABLE = { GfxSingleViewCvars = true, GuestPilots = true, PilotExtras = true }
-- Table-valued keys with a fixed shape: n numbers >= min (one per player count), a colour { R, G, B, A }, or a rect
-- {x, y, w, h} (positional or named, w and h > 0).
local SHAPES = { CardW = { n = 4, min = 1 }, CardGap = { n = 4, min = 0 }, CardPanelColour = { colour = true },
                 HudProgressColour = { colour = true }, HudProgressHumanColour = { colour = true },
                 HudProgressFinishColour = { colour = true },
                 UiPageOrigin = { rect = true } }
-- 0.12.0: keys without a default (nil = unset) that config_user.lua may still set; value = the type they must have.
local NILABLE = { UiPageOrigin = "table" }
-- 0.12.0: keys that take a number > 0 or a per-channel table {r, g, b} (positional or named) of numbers > 0.
local NUM_OR_RGB = { PreviewStudioGain = true }
-- Numbers that must be > 0 (a 0 period would run a loop on every engine tick).
local POSITIVE = { CouchGarageTries = true, Garage4SpinCaptureMs = true, FastPollMs = true, MainPollMs = true, SlowPollMs = true, FastBootPollMs = true,
                   LobbyNavRepeatMs = true, LobbyFocusKeepMs = true, SetupMaxRacers = true, SetupMaxRacersPlane = true,
                   SetupListMax = true, WreckCamMaxDistUU = true, WreckCamBadMs = true, PhotoModeCacheMs = true,
                   IgnitionPadAssistWindowMs = true, WreckViewReapplyMs = true, CrashCamMaxDistUU = true,
                   IgnitionSilentPresses = true, IgnitionSilentPressesP1 = true, TestCommandPollMs = true,
                   TestBotsCritGiveUpMs = true, TestBotsCritCrashMs = true,
                   PauseLostMenuMs = true, IgnitionMapReprobeMs = true, WreckRigFov = true, UxSplitFadeMax = true,
                   PauseInputsBackMs = true, PauseNoSubStateMs = true,
                   -- 0.11.0 RESTART RACE
                   PauseRestartConfirmMs = true, PauseRestartWatchdogMs = true,
                   -- 0.8.0 (SetupPreviewFillLux accepts 0 and SetupPreviewSpinDps any sign: unchecked;
                   -- SetupPreviewCaptureMs accepts 0: NONNEG below)
                   UxSplitSubPendingMs = true, UxSplitSubAiRadiusUU = true, UxSplitSubSideScale = true,
                   SetupPreviewSpacing = true, SetupPreviewW = true, SetupPreviewH = true, SetupPreviewFov = true,
                   SetupPreviewFrame = true, SetupPreviewMaxRadius = true, SetupPreviewDebounceMs = true,
                   SetupPreviewTimeoutMs = true, SetupCardBadgeSize = true, SetupCardInsetH = true, SetupCardRowW = true,
                   -- 0.9.0
                   SetupCMapAreaW = true, SetupCMapAreaH = true, UiMokiWidthScale = true, SetupCMapArcScale = true, SetupCMapArcAngle = true,
                   SetupCMapInfoW = true, SetupCMapMapW = true, SetupCMapMapH = true, SetupCMapPlanetScale = true,
                   SetupCMapCardW = true, SetupCMapNodeMax = true,
                   -- 0.10.0 RACERS step (PerkPartSlots / PerkTraitSlots are also clamped: CLAMP)
                   CardBackTapMaxMs = true, CardP1BackConfirmMs = true, CardRowW = true, CardH = true, CardPad = true,
                   CardBuildsPerTick = true, CardRendersPerTick = true, CardLoadsPerTick = true, CardLoadBigBytes = true,
                   PerkPartSlots = true, PerkTraitSlots = true, SetupPreviewStillBurst = true,
                   SetupPreviewCaptureBudget = true, SetupPreviewSpawnGapMs = true,
                   -- 0.11.0 narrow-view HUD
                   HudNarrowBelow = true, HudNarrowScale = true,
                   -- 0.12.0 UI v2
                   InputModeDebounceMs = true, StatusPillMs = true, UiTitleBoxH = true,
                   -- couch-racegc (gctune.lua)
                   LuaGcMinorMul = true, LuaGcMajorMul = true, LuaGcRaceMajorMul = true, LuaGcPause = true,
                   LuaGcStepMul = true, LuaGcStepSize = true,
                   -- #38 race-progress strip
                   HudProgressMs = true, HudProgressHalfLap = true, HudProgressSpan = true }
-- 0.10.0: numbers that must be >= 0 (0 = off / at once).
local NONNEG = { CardP1DirGuardMs = true, CardGuestClickGuardMs = true, SetupPreviewPrebuildMs = true,
                 SetupPreviewCaptureMs = true,
                 -- 0.11.0 RESTART RACE
                 PauseRestartAfterResumeMs = true,
                 -- 0.12.0 UI v2 (0 = no planet video, the v2 default)
                 SetupCMapVideoW = true }
-- 0.10.0: integers clamped into [min, max] after the checks (an override outside is clamped, with a warning).
local CLAMP = { PerkPartSlots = { 1, 10 }, PerkTraitSlots = { 1, 4 } }

-- nil when v may replace cfg[k], else the reason it is ignored.
local function overrideProblem(k, v)
    if FALSEABLE[k] and v == false then return nil end
    local boe = BOOL_OR_ENUM[k]
    if boe then
        if type(v) == "boolean" then return nil end
        for _, a in ipairs(boe) do if v == a then return nil end end
        return "must be true, false, " .. table.concat(boe, ", ")
    end
    local mixed = MIXED[k]
    if mixed then
        if type(v) == "number" and v >= mixed.min and (mixed.max == nil or v <= mixed.max) then return nil end
        for _, a in ipairs(mixed.strings) do if v == a then return nil end end
        return "must be " .. table.concat(mixed.strings, ", ") .. " or a number >= " .. tostring(mixed.min)
            .. (mixed.max ~= nil and (" and <= " .. tostring(mixed.max)) or "")
    end
    if NUM_OR_RGB[k] then
        if type(v) == "number" and v > 0 and v < math.huge then return nil end
        if type(v) == "table" then
            local r, g, b = v[1] or v.r or v.R, v[2] or v.g or v.G, v[3] or v.b or v.B
            if type(r) == "number" and type(g) == "number" and type(b) == "number" and r > 0 and g > 0 and b > 0 then
                return nil
            end
        end
        return "must be a number > 0 or {r, g, b} (numbers > 0)"
    end
    local want = NILABLE[k] or type(cfg[k])
    if type(v) ~= want then return "must be a " .. want .. (FALSEABLE[k] and " or false" or "") end
    local allowed = ENUMS[k]
    if allowed then
        local hit = false
        for _, a in ipairs(allowed) do if a == v then hit = true; break end end
        if not hit then return "must be one of: " .. table.concat(allowed, ", ") end
    end
    if POSITIVE[k] and not (v > 0) then return "must be > 0" end
    if NONNEG[k] and not (v >= 0) then return "must be >= 0" end
    local shape = SHAPES[k]
    if shape and shape.colour then
        for _, c in ipairs({ "R", "G", "B", "A" }) do
            if type(v[c]) ~= "number" then return "must be a colour { R = <n>, G = <n>, B = <n>, A = <n> }" end
        end
    elseif shape and shape.rect then
        local x, y, w, h = v.x or v[1], v.y or v[2], v.w or v[3], v.h or v[4]
        if type(x) ~= "number" or type(y) ~= "number" or type(w) ~= "number" or type(h) ~= "number"
            or not (w > 0 and h > 0) then
            return "must be a rect { x, y, w, h } (numbers, w and h > 0)"
        end
    elseif shape then
        for i = 1, shape.n do
            if type(v[i]) ~= "number" or not (v[i] >= shape.min) then
                return "must be a list of " .. shape.n .. " numbers >= " .. shape.min
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------- user overrides
-- Optional Scripts/config_user.lua: `return { Key = value, ... }`. Top-level keys replace the values above (a table
-- value replaces the whole table; the type must match the default's, and a string selector must be one of its
-- values listed in ENUMS above, else the override is ignored with a warning), except `Defaults`, which is merged key by key (`Defaults = { Port = 7778 }` only
-- changes Port; settings.lua needs a default for every settings key, it gives each key its type). A missing file is normal; a broken one is logged and ignored, so a typo there
-- never stops the mod. Keep this file (config.lua) unedited: it holds every key the modules read.
-- The built-in Defaults are kept (cfg.DefaultsBuiltin, set after the merge so config_user.lua cannot override it):
-- settings.lua replaces a merged default outside its ALLOWED list with the built-in one (config cannot require settings).
local builtinDefaults = {}
for k, v in pairs(cfg.Defaults) do builtinDefaults[k] = v end
local userSet = {}                  -- 0.12.0: keys config_user.lua replaced (the UiStyle resolution below keeps them)
do
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    local dir = src:sub(1, 1) == "@" and src:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$") or nil
    if dir then
        local path = dir .. "/config_user.lua"
        local f = io.open(path, "r")
        if f then
            f:close()
            local chunk, loadErr = loadfile(path)
            local okRun, user = false, loadErr
            if type(chunk) == "function" then okRun, user = pcall(chunk) end
            if okRun and type(user) == "table" then
                local n = 0
                for k, v in pairs(user) do
                    if cfg[k] == nil and NILABLE[k] == nil then
                        print("[SWGRCouch][config] WARN config_user.lua: unknown key " .. tostring(k) .. " (ignored)\n")
                    elseif k == "Defaults" then
                        if type(v) == "table" then
                            for k2, v2 in pairs(v) do
                                if cfg.Defaults[k2] == nil then
                                    print("[SWGRCouch][config] WARN config_user.lua: unknown Defaults key " .. tostring(k2)
                                        .. " (ignored)\n")
                                elseif type(v2) ~= type(cfg.Defaults[k2]) then
                                    print("[SWGRCouch][config] WARN config_user.lua: Defaults." .. tostring(k2) .. " must be a "
                                        .. type(cfg.Defaults[k2]) .. " (ignored)\n")
                                else
                                    cfg.Defaults[k2] = v2
                                end
                            end
                            n = n + 1
                        else
                            print("[SWGRCouch][config] WARN config_user.lua: Defaults must be a table (ignored)\n")
                        end
                    else
                        local why = overrideProblem(k, v)
                        if why then
                            print("[SWGRCouch][config] WARN config_user.lua: " .. tostring(k) .. " " .. why
                                .. " (ignored)\n")
                        else
                            local r = CLAMP[k]
                            if r then
                                local c = math.max(r[1], math.min(r[2], math.floor(v)))
                                if c ~= v then
                                    print("[SWGRCouch][config] WARN config_user.lua: " .. tostring(k) .. " = "
                                        .. tostring(v) .. " clamped to " .. tostring(c) .. "\n")
                                end
                                v = c
                            end
                            cfg[k] = v
                            userSet[k] = true
                            n = n + 1
                        end
                    end
                end
                print("[SWGRCouch][config] config_user.lua: " .. n .. " override(s)\n")
            else
                print("[SWGRCouch][config] ERROR config_user.lua ignored: " ..
                    tostring(okRun and "it must return a table" or user) .. "\n")
            end
        end
    end
end

cfg.DefaultsBuiltin = builtinDefaults

---------------------------------------------------------------------------------------------------- UiStyle "classic" values
-- 0.12.0 UI v2 changed the defaults of these keys (ui-redesign-final.md §12.3). The classic code paths read the same keys
-- (cards.lua: CardW / CardGap / CardH; setup.lua's classic card row: CardRowW / CardH; cmap.lua's classic views:
-- SetupCMap*), so "classic must keep behaving exactly like 0.11.0": while UiStyle = "classic" (config_user.lua or a
-- live `require("config").UiStyle = "classic"`), cfg.<key> resolves to the value below; otherwise to the v2 default
-- above. A key config_user.lua replaced (or a live write cfg.<key> = v) is a plain value and applies in both styles.
-- cfg.UiClassic lists the classic values (read-only; set after the merge, so config_user.lua cannot replace it).
local CLASSIC = {
    CardW = { 1720, 1720, 1140, 845 }, CardGap = { 0, 60, 40, 40 }, CardH = 1320, CardRowW = 3500,
    SetupCMapVideoW = 768, SetupCMapBackground = true, SetupCMapMapW = 3500, SetupCMapMapH = 1200,
}
local styled = {}
for k, classic in pairs(CLASSIC) do
    if not userSet[k] then
        styled[k] = { v2 = rawget(cfg, k), classic = classic }
        rawset(cfg, k, nil)                                -- now resolved by __index (rawget(cfg, "UiStyle"))
    end
end
cfg.UiClassic = CLASSIC
setmetatable(cfg, { __index = function(t, k)
    local s = styled[k]
    if s == nil then return nil end
    if rawget(t, "UiStyle") == "classic" then return s.classic end
    return s.v2
end })

return cfg
