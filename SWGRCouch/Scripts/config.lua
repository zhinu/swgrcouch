-- SWGRCouch / config.lua  (G1 Core)
-- Developer constants, timings and fallback selectors.
-- Do not edit: put overrides in Scripts/config_user.lua (`return { P1HudMode = "clone" }`, loaded at the end of this
-- file; a syntax error there is logged and ignored), then restart the game or press Ctrl+F11 (RestartCurrentMod).
-- User choices (layout, graphics, network address, last race, ...) are NOT here: they live in
-- <ModDir>/settings.txt (settings.lua). `Defaults` below are only the values used when that file lacks a key.
-- Each fallback selector names the VERIFY id (ARCHITECTURE.md §6) whose failure it answers.

local cfg = {}

---------------------------------------------------------------------------------------------------- Core
cfg.Debug               = true      -- U.dbg output + debug-only hooks in diag
cfg.SkipRaceIntro       = false     -- true: Race.SpeedyFlow.Intro/.Movies = 1 (race intro cinematics and movies skipped;
                                    --   the game's own dev shortcut, set once per boot by testcmd.lua)
cfg.ViewGuard           = true      -- viewguard.lua: a still-racing local player whose view is another player's DNF
                                    --   "failed" cinematic (BP_PlayerFailedCam_C) is put back on its own car (run G)
cfg.MenuBridge          = true      -- menubridge.lua (0.7.1): a guest-owned menu (pause, player menu, settings...) takes
                                    --   its owner's A/B, and a shared post-race screen anyone's A, by clicking the
                                    --   selected button when the game did not react (run I: P2's A was dropped)
cfg.MenuBridgeWaitMs    = 150       -- the game's own reaction window before the bridge clicks   VERIFY(V-MB-01)
-- 0.8.0 (pause phase 2, menubridge.lua): screens opened FROM a pause belong to the pause controller; each key turns its
-- part off alone (pause.lua side: PauseSubScreen* / PauseDialogGuestUi in the Pause section).
cfg.MenuBridgeGuestNative = "skip"  -- "skip": a guest's presses on its OWN screen are not bridged while pause.lua boosts
                                    --   its IMC_UI (run I: native input works then; bridging as well toggled a Settings
                                    --   row twice) | "bridge" (the 0.7.1 behaviour)                  VERIFY(V-MB-04)
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
cfg.TestCommands        = false     -- testcmd.lua: run <ModDir>/test.cmd blocks (unattended live tests); off for players
cfg.TestCommandPollMs   = 300
cfg.FastPollMs          = 33        -- FAST loop (join edge poll, click poll, pause poll)   VERIFY(V-CORE-02)
cfg.MainPollMs          = 250       -- MAIN loop (phase, lobby, roster, takeover, hud, nametags, net)
cfg.SlowPollMs          = 1000      -- SLOW loop (pending hooks, menu ensure, net slow tick, diag)
cfg.UseKslIsValid       = true      -- U.alive also asks KismetSystemLibrary:IsValid   VERIFY(V-CORE-05)
cfg.SubsystemLookup     = "sbl"     -- "sbl" (SubsystemBlueprintLibrary) | "findfirst"  VERIFY(V-CORE-06)
cfg.LoopErrorLogEveryMs = 5000      -- a failing loop logs at most one error line per this period
cfg.DiagPeriodicMs      = 0         -- > 0: diag.dump() at that interval

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
cfg.GuestCreate     = "connected"   -- dormant guests only for pads that are plugged in ("connected") | "all" (always
                                    --   MaxLocalPlayers-1, the pre-2026-10-07 behaviour)          VERIFY(V-JOIN-11)
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
cfg.HudFitInterior        = true       -- 0.8.2: the race HUD's top bar (timer / lap / POS, 3620 px wide) scales down to
                                       --   fit a quarter view (3P bottom, 4P) instead of losing both ends  VERIFY(V-HUD-15)
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
cfg.LocalResultsMode      = "hide"     -- P1 finished, guests still racing: WBP_PostRace_Info_C is "hide"-n until every
                                       --   local human finished | "hide_inactive" (hide + DeactivateWidget while hidden:
                                       --   its CommonUI bindings/input config stop acting on P1's pad) | "rehost"-ed into
                                       --   P1's view | "leave"                                        VERIFY(V-HUD-13)
cfg.ForceCarTags          = false      -- set UI.UseScreenSpaceCarTags 1 before the markers initialise  VERIFY(V-HUD-11b)
cfg.HudOutPlayers         = "hide"     -- a local player out of the race (wrecked / spectating) gets its HUD hidden (run E:
                                       --   P2's frozen HUD stayed over its spectate view) | "keep". A player who FINISHED
                                       --   keeps its HUD. Photo mode hides every HUD we host   VERIFY(V-HUD-14/15/16)

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
cfg.UxSplitRamjetColour   = true       -- part of UxSplitDanger: BotEngineInfo's Engage/DisengageRamjet animations (global
                                       --   FadeDirection sweep) stopped, icons set, MPC pinned; "own": HUD tinted blue  V-UX-08
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
cfg.UxSplitProbeMs        = 5000       -- > 0: one "[uxsplit] probe" line at this period while armed (0 = off)  V-UX-11
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
cfg.PresentFromMain       = true       -- main.lua initialises and ticks present.lua (false: hud.lua drives it, the
                                       --   pre-integration wiring)
cfg.PresentViewMode       = "auto"     -- "auto": ONE full-screen view during loading, track intro, grid intro, side bets,
                                       --   intermission and results; split views from the ignition/countdown to the
                                       --   finish | "split": split from LOADING to the end (0.3 behaviour)  VERIFY(V-PRE-01)
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
cfg.NameTagLabel          = "pnum"     -- name tags over local humans' cars: "pnum" ("P2") | "name" ("Player 2") | "both"

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
cfg.SetupTatooine         = true       -- Tatooine (podracers only) in the planet list
cfg.SetupAskCondition     = true       -- CONDITIONS step when a track has several (false: the track's first)
cfg.SetupTrackDedupe      = true       -- one row per track (run E: "MOS ESPA SPEEDWAY (BGL_PLANE_FWD)" several times):
                                       --   display names, reverse/variants marked; false = every TrackDef the game
                                       --   returns (duplicates marked with their key)              VERIFY(V-SET-12)
cfg.SetupDebugBuilds      = false      -- also list the DEBUG build tiers
cfg.SetupAllBuilds        = false      -- list every quick-race build (ability tests, trailer builds)
cfg.SetupListMax          = 16         -- option rows in the list (longer lists are paged with a MORE row)
cfg.SetupListMaxH         = 520        -- max height of the option list (it scrolls to the focused row)
cfg.SetupMediaW           = 640        -- media area (planet video / art)
cfg.SetupMediaH           = 360
cfg.SetupInsetW           = 256        -- inset art (planet select image / track tile)
cfg.SetupInsetH           = 144
cfg.SetupCardPortraits    = true       -- vehicle cards show the livery owner's portrait for pilot-livery presets
cfg.SetupCardW            = 360        -- vehicle card image per player column (initial width; 0.8.0: the 2D art keeps its
                                       --   own aspect, a 3D card is 16:9)
cfg.SetupCardH            = 200        -- card height (0.8.0: lowered when n 16:9 cards would not fit SetupCardRowW)
cfg.SetupLeftWeight       = 0.45       -- width share of the media column
-- 3D vehicle preview (vpreview.lua, 0.8.0; notes/research/vehicle-preview.md): each VEHICLES card shows a live render of
-- its pick, made by a "photo bay" per column (a BP_StaticVehicleBase model + SceneCapture2D + fill light) in the sky
-- above the front-end sets. Front end only; released when the step is left, the setup closes or a player leaves. A
-- structural failure turns it off for the session (2D cards, reason logged once); a model that fails keeps its 2D card.
cfg.SetupPreview3D        = true       -- live 3D render of each VEHICLES pick; false = the 0.7.1 2D cards (+ badge)  V-VP-09
cfg.SetupPreviewX         = 0          -- bay 1 origin X (uu); bay i at X + (i-1) * SetupPreviewSpacing
cfg.SetupPreviewY         = 60000      -- bay origin Y (uu): empty sky on the far +Y side of the front-end sets
cfg.SetupPreviewZ         = 60000      -- bay origin Z (uu): ~44 deg above every main-menu camera       VERIFY(V-VP-05)
cfg.SetupPreviewSpacing   = 5000       -- uu between the bays of two columns (> 0)                      VERIFY(V-VP-10)
cfg.SetupPreviewW         = 640        -- render target width (px, > 0)
cfg.SetupPreviewH         = 360        -- render target height (px, > 0); card aspect = W / H
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
cfg.SetupPreviewCaptureMs = 50         -- min ms between two captures of a spinning bay (>= 0; 0 = every FAST tick)  V-VP-06
cfg.SetupPreviewFillLux   = 60         -- fill PointLight above the camera: illuminance at the model in lux (intensity =
                                       --   lux * m^2 candelas); 0 = no fill light                     VERIFY(V-VP-04)
cfg.SetupPreviewExposure  = "inherit"  -- capture exposure: "inherit" (the front end's own post-process) | "fixed" (eye
                                       --   adaptation clamped to SetupPreviewEV)                      VERIFY(V-VP-04)
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
-- 0.9.0 campaign views (cmap.lua, notes/research/campaign-map/): PLANET = the campaign's planet arc (WBP_PlanetSelector)
-- + a row of planet chips (the control); TRACK = a single-planet run map (circuit rows, variant nodes, detail card).
-- Any failure falls back to the 0.8.0 lists for that step. Sizes are Slate units (1 su = 1 px at 3840x2160).
cfg.SetupCampaignMap      = false      -- (public build: off until tested live) false: the 0.8.0 lists for PLANET and TRACK (no cmap widget is built)  V-CMAP-12
cfg.SetupCMapPlanetNav    = "chips"    -- "chips" (planet chips under the arc) | "list" (the 0.8.0 planet list)  V-CMAP-05
cfg.SetupCMapTrackView    = "map"      -- "map" (run map, d-pad between nodes) | "list" (the 0.8.0 track list)   V-CMAP-08
cfg.SetupCMapAreaW        = 3500       -- planet view area (su, > 0), clipped                                   V-CMAP-06
cfg.SetupCMapAreaH        = 1080
cfg.SetupCMapArcScale     = 0.85       -- render scale of the campaign's 7200-su arc (> 0; 1 = campaign size)   V-CMAP-06
cfg.SetupCMapArcAngle     = 35         -- ArcAngleDeg (campaign 35; used as max(value, 5.85 x planets), > 0)
cfg.SetupCMapArcPad       = 2          -- SelectionPadAngle around the selected planet (deg, >= 0)
cfg.SetupCMapPlanetY      = 330        -- selected planet centre below the area top (su)
cfg.SetupCMapInfoW        = 820        -- planet info block width (su, > 0)
cfg.SetupCMapVideoW       = 768        -- planet video frame width (su, 16:9; 0 = no video in the planet view)
cfg.SetupCMapBackground   = true       -- campaign map paper (T_UI_Map_Bg) behind the arc
cfg.SetupCMapManualTick   = "auto"     -- "auto" (UpdateButtonPos from the FAST loop only if the arc does not tick) |
                                       --   "always" | "off"                                                     V-CMAP-04
cfg.SetupCMapSounds       = true       -- the campaign map's UI sounds (open, planet accept)
cfg.SetupCMapMapW         = 3500       -- run map box (su, > 0); the 3840x1500 map scales to fit it             V-CMAP-08
cfg.SetupCMapMapH         = 1200
cfg.SetupCMapPlanetX      = 1180       -- big planet centre x in the 3840-wide map
cfg.SetupCMapPlanetScale  = 0.62       -- big planet render scale (> 0; disc 2336 su at 1)
cfg.SetupCMapPlanetName   = false      -- also show the big planet's own 84-pt name
cfg.SetupCMapCardW        = 980        -- detail card width (su, > 0)
cfg.SetupCMapNodeMax      = 40         -- most circuit variants on one map (> 0; more = the list)

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
cfg.WreckProbe            = true       -- camera probe lines at the wreck and +0.5/+2/+4.5/+6/+10/+20/+40 s and after
                                       --   photo mode (view, camStill, fade, phase, watched car, photo)  VERIFY(V-WD-04)
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
cfg.CrashCamProbe         = true       -- probe lines at the crash, +0.5 s, +2 s, the switch and the end   VERIFY(V-CC-01)
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
    quality = {
        ["sg.GlobalIlluminationQuality"] = 1, ["sg.ReflectionQuality"] = 1, ["sg.ShadowQuality"] = 1,
        ["r.ScreenPercentage"] = 62, ["r.Streaming.PoolSize"] = 3000,
    },
}
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
}

---------------------------------------------------------------------------------------------------- override checks
-- Allowed values of the string selectors (config_user.lua overrides outside these lists are ignored with a warning).
local ENUMS = {
    SubsystemLookup = { "sbl", "findfirst" },
    ClickMode = { "hook", "poll" },
    FastBootEpic = { "off", "keep" },
    LobbyNavHighlight = { "both", "style", "focus" },
    LobbyNavKeyboard = { "always", "kbp1", "never" },
    BuilderAdopt = { "live", "go" },
    GuestCreate = { "connected", "all" },
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
}
-- Keys whose value is a string selector OR a number (FinishGraceSec: "all" | seconds >= 0; PauseMenuZ: "auto" | Z >= 0;
-- UxSplitSubHalfFrac: "auto" | a fraction 0..1). max is optional.
local MIXED = { FinishGraceSec = { strings = { "all" }, min = 0 }, PauseMenuZ = { strings = { "auto" }, min = 0 },
                UxSplitSubHalfFrac = { strings = { "auto" }, min = 0, max = 1 } }
-- Table-valued keys that also accept false (= feature off).
local FALSEABLE = { GfxSingleViewCvars = true, GuestPilots = true }
-- Numbers that must be > 0 (a 0 period would run a loop on every engine tick).
local POSITIVE = { FastPollMs = true, MainPollMs = true, SlowPollMs = true, FastBootPollMs = true,
                   LobbyNavRepeatMs = true, LobbyFocusKeepMs = true, SetupMaxRacers = true, SetupMaxRacersPlane = true,
                   SetupListMax = true, WreckCamMaxDistUU = true, WreckCamBadMs = true, PhotoModeCacheMs = true,
                   IgnitionPadAssistWindowMs = true, WreckViewReapplyMs = true, CrashCamMaxDistUU = true,
                   IgnitionSilentPresses = true, IgnitionSilentPressesP1 = true, TestCommandPollMs = true,
                   PauseLostMenuMs = true, IgnitionMapReprobeMs = true, WreckRigFov = true, UxSplitFadeMax = true,
                   PauseInputsBackMs = true, PauseNoSubStateMs = true,
                   -- 0.8.0 (SetupPreviewCaptureMs / SetupPreviewFillLux accept 0 and SetupPreviewSpinDps any sign: unchecked)
                   UxSplitSubPendingMs = true, UxSplitSubAiRadiusUU = true, UxSplitSubSideScale = true,
                   SetupPreviewSpacing = true, SetupPreviewW = true, SetupPreviewH = true, SetupPreviewFov = true,
                   SetupPreviewFrame = true, SetupPreviewMaxRadius = true, SetupPreviewDebounceMs = true,
                   SetupPreviewTimeoutMs = true, SetupCardBadgeSize = true, SetupCardInsetH = true, SetupCardRowW = true,
                   -- 0.9.0
                   SetupCMapAreaW = true, SetupCMapAreaH = true, SetupCMapArcScale = true, SetupCMapArcAngle = true,
                   SetupCMapInfoW = true, SetupCMapMapW = true, SetupCMapMapH = true, SetupCMapPlanetScale = true,
                   SetupCMapCardW = true, SetupCMapNodeMax = true }

-- nil when v may replace cfg[k], else the reason it is ignored.
local function overrideProblem(k, v)
    if FALSEABLE[k] and v == false then return nil end
    local mixed = MIXED[k]
    if mixed then
        if type(v) == "number" and v >= mixed.min and (mixed.max == nil or v <= mixed.max) then return nil end
        for _, a in ipairs(mixed.strings) do if v == a then return nil end end
        return "must be " .. table.concat(mixed.strings, ", ") .. " or a number >= " .. tostring(mixed.min)
            .. (mixed.max ~= nil and (" and <= " .. tostring(mixed.max)) or "")
    end
    if type(v) ~= type(cfg[k]) then return "must be a " .. type(cfg[k]) .. (FALSEABLE[k] and " or false" or "") end
    local allowed = ENUMS[k]
    if allowed then
        local hit = false
        for _, a in ipairs(allowed) do if a == v then hit = true; break end end
        if not hit then return "must be one of: " .. table.concat(allowed, ", ") end
    end
    if POSITIVE[k] and not (v > 0) then return "must be > 0" end
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
                    if cfg[k] == nil then
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
                            cfg[k] = v
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

return cfg
