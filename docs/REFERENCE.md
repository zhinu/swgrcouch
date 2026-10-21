# SWGRCouch: FREE MODE (solo or couch split screen) and self-hosted races for STAR WARS: Galactic Racer

UE4SS Lua mod, version 1.0.1 (`consts.lua C.VERSION`). Target: the Steam build of STAR WARS: Galactic Racer (UE
5.7.4 shipping, Denuvo, project codename Griffin; hotfix build CL 382493), UE4SS Galactic Racer Edition (open beta,
2026-10-08). The main-menu tab was called SPLIT SCREEN until 0.10.0; it is now **FREE MODE** (the mod is for one
player too). This file ships twice: as `docs/REFERENCE.md` and as `SWGRCouch/README.md`, which `install.sh` copies into
the game's mod folder (`ue4ss/Mods/SWGRCouch/README.md`).

> **⚠ Offline play only.** With the mod installed, the game's online mode may stop working: by default the mod turns off
> the game's Epic account link in the game profile (`FastBootEpic = "off"`, §2.6), as accepting the game's own "EOS
> linking will be disabled" prompt does, and online play may need that link. On our test machine, starts with Steam
> online stopped at the main menu; starts with Steam in Offline Mode worked. Play with Steam in Offline Mode, with Steam
> Cloud turned off for the game (its saves are synced through Steam Cloud). Before installing, keep a copy of the game's
> `Saved` folder, and put it back before you play online again: the game may upload race times set offline to its
> online leaderboards later, so a save used with the mod should not go online. Putting it back also restores the link
> setting (removing the mod alone does not; see the README's *Uninstall*).

> **Status: first live runs done (2026-10-06, session A, Proton GE-Proton11-7, UE4SS v3.0.1-1160 (the UE4SS of that
> time; the hotfixed game needs the Galactic Racer Edition, §2.1) + the custom signatures in `ue4ss_signatures/`);
> first 2-player race done (2026-10-07, session B); 0.4.0 tested live (2026-10-07, run E).** All modules load, the
> FREE MODE tab and the lobby work, pad 2 joined P2, the race ran with two views. What the runs changed is in
> [§1.1](#11-first-live-run-findings-2026-10-06), [§1.2](#12-after-the-first-2-player-race-040-2026-10-07) and
> [§1.3](#13-after-run-e-050-2026-10-07); the 0.5.0 changes of §1.3 are **not tested in the game yet** (live-test order:
> §9, Session F). 0.7.0 (per-player messages and danger visuals after run H, [§1.6](#16-after-run-h-070-2026-10-07))
> was tested live in run I (§9 "Run-I results"). 0.8.0 (subtitles per player, 3D vehicle cards, pause phase 2,
> [§1.7](#17-080-2026-10-07-subtitles-per-player-3d-vehicle-cards-pause-phase-2)) is **not tested in the game yet**
> (checks: §9 "0.8.0 checks"). 0.10.0 (RACERS step, keybind crash fix, P1 menus after a race, game-only tracks,
> [§1.9](#19-0100-2026-10-10-racers-step-crash-fix-p1-menus-after-a-race-game-only-tracks)) **ran live on 2026-10-10**
> (three sessions on the hotfix build CL382493, §9 "Session R"). 0.11.0 (RESTART RACE, guests' pause menus,
> [§1.10](#110-0110-2026-10-10-restart-race-guests-pause-menus)) and 0.12.0 (UI v2: the FREE MODE page, OPTIONS, RACE
> SETUP and the RACERS cards in the game's own look; pad B goes back on OPTIONS / RACE SETUP; the opponents' tier; the
> launch crash fix, [§1.11](#111-0120-2026-10-10-ui-v2-back-prompt-opponents-tier)) **ran live on 2026-10-10** (hotfix
> build CL382493, UE4SS Galactic Racer Edition; §9 "RESTART RACE (0.11.0)" and "Session U"). The UI v2 pages were
> checked at 1280x720, 1920x1080, 3840x2160 and 1280x800 with the game started in English, German and French; Japanese,
> Chinese (Simplified), Korean, Polish, Turkish and Arabic were switched in a running game (scripts render; long
> localized track names not checked). The rest was written from static research (reflection tables, Blueprint listings, shipped
> configs, the UE4SS source). Each runtime assumption in the
> code carries a `-- VERIFY(V-<AREA>-<nn>)` comment. The [runtime test checklist](#9-runtime-test-checklist) at the end lists every id,
> how to check it, and which `config_user.lua` switch to try when it fails. The binding design is `ARCHITECTURE.md`
> in the development repository (`docs/dev/`, not in the release zip). Its §6 has the same ids and is the document to
> update when a check is answered.

## 1. What the mod does

- **FREE MODE tab.** A fifth tab appears in the main menu: *Campaign · Scenarios · Arcade · Multiplayer ·
  FREE MODE*. You can reach it with the bumpers or the mouse, or press F5.
- **Lobby page in that tab** (0.12.0 "UI v2": drawn in the game's own look). Four posters: the **RACE** card (the
  chosen race, or CHOOSE RACE), **START RACE**, **ADD PLAYERS** (local pads) and **OPTIONS**, over a players strip; a
  status pill shows the messages. Up to 4 local players join with their own pads (press A or Start). OPTIONS holds the
  split-screen options (2-player layout, split graphics preset, takedown cameras, name tags, keyboard-is-P1), the
  network mode (offline / host / join) and the game's developer race builder (§3.1). `UiStyle = "classic"` brings back
  the 0.11.0 page (one column of rows).
- **RACE SETUP flow (0.4.0).** The RACE card walks through **class → planet → track (+ conditions) → mode (+ grid size
  and the opponents' strength) → racers**. The planet step shows the planet's Arcade art for the class; the planet's
  arrival video only with `SetupCMapVideoW > 0` (768 in 0.11.0 and with `UiStyle = "classic"`). Since 0.10.0 every
  local player picks a pilot, a vehicle and the whole loadout (abilities, parts, upgrades, racer style, traits;
  everything unlocked) on an identical card with their own pad (§3.3); `SetupPlayerFlow = "classic"` gives the
  0.4.0-0.9.x vehicle columns back. The game's developer race builder (`WBP_FE_QuickRace_Custom_Widget`) stays
  available under OPTIONS > ADVANCED > **Race builder** (classic: the **ADVANCED** row). The last race is remembered.
- **Full grid.** Single-class races are filled to the class limit (12 speeders / 8 podracers, players included), all
  AI in the chosen class (the first race had 5 cars: 2 players + 3 AI, one of them a skimmer). 0.12.0: the AI's
  strength is chosen in MODE (**Opponents**: the game's six speeder build tiers, TIER 1 by default; §3.3).
- **Real grid slots.** Guests exist as player controllers *before* the mod calls the game's
  `FrontEndGameMode:LaunchCustomRace`, so the game's recipe builder should give each one a racer entry and a car
  (VERIFY V-LCH-03). If a human still has no car after the start, a fallback takes over an AI car *and* its racer
  PlayerState, so the HUD position, lap count and results follow the human.
- **In the race.** Loading, the track intro, the grid intro, side bets and the results run **full screen**; the
  views split at the pre-race checks / countdown. Each player gets their own view (2P top/bottom or side by side, 3P
  favour-top, 4P grid), **their own pre-race checks** and their own HUD (lap counter patched per player; global parts
  collapsed); P1's HUD is a P1-owned copy in P1's view. **Each car obeys only its own player** (pad 2 drives only P2;
  keyboard/mouse and pad 1 only P1). Guests are named **Player 2..4** instead of P1's Steam name. Cars show coloured
  `P1`..`P4` name tags in the game's planet tones (0.12.0: P1 apricot, P2 teal, P3 lime, P4 Crait red; blue, red,
  green and yellow before; remote humans white). Any player can pause. While two or more views are on screen, a
  lighter graphics preset is applied, and it is restored in the menu. A pad that disconnects mid-race hands its car to
  the AI and gets it back on reconnect.
- **After the race** you return to the FREE MODE tab with the same players joined and the same race selected, so
  START RACE again is a rematch. On any other tab the guests stay in memory but are ignored (one view, no joining);
  they are never removed (§1.1, `GuestRemoval`).
- **Restart the game before the game's own online Multiplayer** once pads were added (ADD PLAYERS): guest local
  players cannot be removed and would join online sessions as extra players. The lobby warns on the Multiplayer tab.
- **No-intro boot** (`FastBoot`, on by default): no idents / PRESS A, no photosensitivity warning, no Epic login page,
  no SOCIAL OVERLAY modal: straight to the main menu (§2.6).
- **Self-hosted network races.** One machine hosts a listen server in the front end; the others connect by IP
  (plain `IpNetDriver` UDP, typically over WireGuard). **Every machine can bring split-screen guests.** The engine
  sends them as split-join child connections, so "2 here + 3 there" are 5 racers. There is no PlayFab, EOS or Steam
  networking. A fallback chain (relisten, then servertravel, then AI takeover) covers the case where the game's
  launch travel does not carry the clients.

Not covered: the PvP Tour layer (sponsors, side bets, shop), XP and progression. Pilots are chosen in the RACERS step
(0.10.0, §3.3). Official online play does **not** work while the network override `Engine.ini` is installed (§2.4).

### 1.1 First live run findings (2026-10-06)
Logs: `state/runs/20261006-2329-session-A/UE4SS-run*.log` (run2 = crash), dump `crash_2026_10_06_22_02_41*.dmp`.
- **Blueprint-function hooks register but never fire** in this build: `WBP_FE_MainMenu_C:CustomEvent` /
  `RegisterTabs`, `WBP_Common_Btn_C:BP_OnClicked`, the builder's Go `BndEvt`, the HUD lap counters'
  `UpdateCurrentLap`. Native `/Script/` hooks register normally. Every feature now has a **poll path that is the
  default** and the only one required; the BP hooks stay as optional extras that the polls de-duplicate against:
  tab clicks = `GetActiveTab` poll (MAIN), row clicks = `ClickMode = "poll"` (selected-toggle trick, pad A and mouse),
  builder Go = `Btn_Go` `GetSelected` poll + live pick capture (`BuilderAdopt = "live"`), returning from another
  screen = main-menu `IsActivated` edges (`TabReactivateMinMs`), guest pause = deferred Start poll
  (`GuestPauseFallback`), guest laps = MAIN text poll (Memory-HUD guest lap counters stay collapsed).
- **Re-entry crash (fixed by design):** leaving the tab removed the 3 dormant guests (`RemovePlayer`); re-entering
  re-created them and the game crashed one tick later (AV read 0x20 at `SWGR-Win64-Shipping.exe+0x3800ac`). Static
  analysis of the dump (join.lua header, GUEST LIFECYCLE): every guest `RemovePlayer` frees the guest's CommonUI analog
  cursor but leaves its raw listener bound to the UIManager's `InputModeManager` delegate; the next control-mapping
  rebuild (here: the new guests') calls into freed memory. No delay makes a removal safe. Now guests are created
  **once** (only for plugged-in pads, `GuestCreate = "connected"`), **kept** across tab switches and races, and never
  removed (`GuestRemoval = "never"`); outside our tab their input is ignored and the front end keeps one view.
- **Lobby with a pad:** CommonUI focus never reached our rows and the row text was beige on the light page. Rows now use
  the game's dark-on-light button style (`LobbyRowInvert`). Review 2026-10-07: focus was given while the animated
  page switcher was still mid-transition, so it never landed, and P1's pad keys probably never reach P1's
  PlayerController in the menu (CommonUI blocks game input there), so the old pad poll could not replace it. Now the
  switcher transition is off (`MenuSwitcherNoTransition`) and a **focus keeper** gives P1's focus to the lobby row /
  the builder's first button after every page show (`LobbyFocusKeepMs`): the pad then navigates through CommonUI.
  The keyboard uses UE4SS keybinds (arrows, Enter/Space). The pad poll (`LobbyPadNav`) stays as an extra. Nothing
  acts while another screen covers the lobby, and the first A/Enter after a Back is ignored (it may confirm the
  game's "Exit game?" prompt).
- **Guests are opt-in (review 2026-10-07):** opening the tab no longer creates guest local players; the lobby's
  **ADD PLAYERS** row (pressed twice) does, for plugged-in pads, and they stay until the game exits.
- **Slow boot:** title idents + PRESS A, the photosensitivity warning on every boot, an Epic account page in the
  browser and a SOCIAL OVERLAY UNAVAILABLE modal. Answered by the no-intro mode (§2.6).
- **Paths:** the user config folder in the prefix is `AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/`, not
  `.../AppData/Local/Griffin/...` as earlier docs said (fixed below and in `install.sh`).

### 1.2 After the first 2-player race (0.4.0, 2026-10-07)
Logs: `state/runs/20261007-0846-session-B/`. What the user saw and what 0.4.0 does (research in
`notes/research/input-isolation.md`, `presentation.md`, `race-setup.md`):

| Seen in the race | Cause | 0.4.0 |
|---|---|---|
| keyboard/mouse (and one pad) drove both cars | every human car read P1's raw-input subsystem, and every subsystem recorded every device | `inputfix.lua`: each car bound to its own player's subsystem + native filter `native/swgr_inputfilter.dll` (Lua-only `kbsplit` fallback). `InputFix*` |
| top player's HUD covered the whole screen, bottom had none | the game's HUD was rejected by an owner filter, so it stayed viewport-wide | P1 gets its own HUD in P1's view (`P1HudMode = "clone"`), the game's is hidden |
| pre-race key sequence only for the top player | the game's ignition screen is viewport-wide and bound to P1's car | each player gets an ignition screen in their own view (`IgnitionMode`) |
| race intro video on the top view only | cinematics drive P1's view | intro / grid intro / results on ONE full-screen view (`PresentViewMode`) |
| both racers had the same name | guests share P1's online identity | guests renamed "Player 2..4" (`GuestNames`) |
| map choice: no video, not by planet; class not first | the dev builder's six pickers | RACE SETUP flow (§3.3) |
| one vehicle for everybody | one archetype + one build in `LaunchCustomRace` | per-player model + build written into the race recipe |
| only 3 AI | `GMV_Race` = 5 racers incl. the humans | grid rewritten to 12 / 8 in memory (`SetupGridMode`) |
| a 5 s "press again" window ended after ~3.5 s | `os.clock` runs ~1.5x fast under Wine | real clock (`GetAccurateRealTime`) for every timer |
| a wreck (top or bottom player) ended the race for everyone; P2's wreck view was black, no slow-mo | offline, the first human who finishes **or** is wrecked arms a 2 s race timeout (`RaceTimeoutTime`); crash-cam slow-mo is world-wide | `wreck.lua`: the race goes on until every local human finished or was wrecked (`FinishGraceSec`); a wrecked player watches the race in their own view (the other player's car first), with a camera guard so that view is never black (`WreckViewGuard`); slow-mo off while split (`WreckSlowMo`); `WreckMode = "noWreck"` = nobody (local) wrecks |

### 1.3 After run E (0.5.0, 2026-10-07)
Logs: `state/runs/20261007-1033-session-E/` (`UE4SS-E5-podrace-p2.log`: P2 wreck + ignition; `UE4SS-E6-lag-photomode.log`:
lag + photo mode). Per-view HUDs, per-player vehicles, the 8-racer grid, planet videos and independent driving input
(DLL `wo` bind) worked. What the user reported and what 0.5.0 does (research in `notes/research/wreck-design.md`,
`presentation.md` §3b, `input-isolation.md`, `race-setup.md`):

| Seen in run E | Cause | 0.5.0 |
|---|---|---|
| P2's wreck view black; no slow-mo for P2's wreck | the game's own spectate (blend 0) replaced P2's crash camera at once and parked it on P1's still car (virtual pad); `WreckSlowMo` was `"off"` | `wreck.lua`: the wreck camera is put back for `WreckCrashCamHoldMs` (4 s), then the guest's native spectate is ended and its view follows a MOVING racing car (`WreckView = "car"`); camera fades are read and cleared (`WreckFadeRead`); `WreckSlowMo = "game"` by default, emulated on `CinematicTimeDilation` when the game's slow-mo does not run (`WreckSlowMoEmulate`) |
| ignition screens ignored the pads; P1's showed keyboard/mouse prompts | only the PC's Enhanced Input action events feed `TestPreflightCheckInput`, and a guest's are dead; CommonInput flips P1 to keyboard/mouse | `ignition.lua` + `ignpad.lua`: each player's own pad keys are polled and replayed when the game path does not deliver (`IgnitionPadAssist`), pad prompts forced (`IgnitionPadPrompts`, `IgnitionFixedKeys`); `IgnitionMode = "auto"` also completes the checks of a player whose pad path cannot work |
| "it lagged after me being dead" | `hud.lua` saw the game's HUD as "changed" on every tick (two wrappers of one widget compared unequal): re-placed and logged 3-4x/s | every identity test compares addresses; change log rate-limited; a wrecked/spectating player's HUD is hidden (`HudOutPlayers`) |
| photo mode: modules fought it, the pad did nothing | photo mode possesses a `BP_PhotoModePawn_C` for every local PC; wreck.lua's view guard pulled P2's view back every 2 s | shared detector `phase.photoMode()`; wreck, hud, pause, inputfix and ignition back off while it is open. The photo pawn reads Enhanced Input routed per ControllerId, so each pad drives its own photo camera |
| Start paused, no pause menu visible | the pause screen sat in a hidden/transparent layer owned by the "first" PC | `pause.lua`: menu forced visible (`PauseMenuFix`), re-added full-screen owned by the pauser in split races (`PauseMenuRehost`, `PauseMenuOwner`) |
| inputfix: "write did not stick" although the DLL bind worked | the weak pointer was compared as a wrapper, not by address | addresses compared, LocalPlayer or PC subsystem accepted, grace for the DLL copy; the all-bound edge enables the filter + contexts |
| Ctrl+F11 mid-race left `phase=BOOT` | no re-detection on load | `phase.redetect` on the first frame after load (`PhaseBootWarnMs`) |
| setup: the same track listed several times with raw names | campaign/event copies of one layout | one row per layout, display names, REVERSE / variants marked (`SetupTrackDedupe`) |
| VEHICLES: empty preview | `T_UI_Vehicle_Plane` is a white line icon; `VA_Plane` has no select image | class renders (pods: the planet's Arcade pod art) |

### 1.4 After run F (0.5.1, 2026-10-07)
Logs: `state/runs/20261007-1139-session-F/`. User: "the wrecked is still black screen and on top of that ignition game
still doesn't work". **Not tested in the game yet** (ARCHITECTURE §6 Session G).

| Seen in run F | Cause (static analysis) | 0.5.1 |
|---|---|---|
| two UE4SS crashes (AV in memcpy) | soft-object values marshalled through Lua (ignition probe hook, soft-keyed map reads) | no soft pointer in Lua by default; the old completion only with `IgnitionSoftComplete = true` |
| P2's view black when P2 crashes; P1's crash camera + slow-mo fine | the crash camera actor is spawned at the world origin and only moves when a shot validates; for the second view none does (leading hypothesis, probes confirm) | `crashcam.lua`: an unusable guest crash camera is replaced by the guest's own car within ~150 ms (at once on later crashes), held fades cleared, the pod crash slow-mo emulated (`CrashCamGuest`, `CrashSlowMoEmulate`) |
| P2's wreck view black | the 4 s wreck-camera hold put the same broken crash camera back | the hold is skipped for a guest whose crash camera is not proven usable (`CrashCamWreckHold = "proven"`); P2 goes straight to a moving car |
| ignition: guests auto-completed (did not even work), no own-pad checks | a guest PC's Enhanced Input action events never fire | `IgnitionMode = "auto"` again: a guest's pad presses call that guest's own PC action event with the input action object (no soft pointer in Lua); P1's own game path is watched, never doubled |
| pause menu faint under white | screenshot taken during the menu's intro fade, restarted by our re-add; the bone-white backdrop is the game's design | earlier rehost, HUDs hidden on the pause edge, parts settled to their end values (`PauseMenuSettle`) |

### 1.5 After run G (0.6.0, 2026-10-07)
Logs: `state/runs/20261007-1217-session-G/`. Found and proven live, code **not tested in the game yet**
(ARCHITECTURE §6 Session H).

| Seen in run G | Cause | 0.6.0 |
|---|---|---|
| guests' pre-flight checks, pause, camera, ENGINE IGNITE dead | a guest's Enhanced Input had no vehicle mapping context (0 `IA_Veh_*`) | P1's vehicle pad IMC added to every guest's Enhanced Input, verified, removed in the menu (`InputFixGuestEnhanced`); the mod's check replays are only a fallback |
| paused with no pause menu, nobody could resume | the player menu (Back/View) was not looked for; a menu could leave the viewport | player menu counted, lost menus repaired (re-add, reopen, else resume: `PauseLostMenu`), the pauser's pad gets focus |
| wrecked P2 watched an AI pod from inside its engine | an AI car's camera runs no chase stack | chase rig behind the watched car (`WreckCarCam`) |
| P2's crash camera black | unknown (all checks pass) | `CrashCamGuest = "car"` default: P2 follows its own pod |
| P1 stuck on P2's DNF cinematic | the offline flow targets the first player | `viewguard.lua` (`ViewGuard`) |
| a DLL bind waited for the next pad event | cfg only re-read from the input path | reload thread, every 250 ms |

### 1.6 After run H (0.7.0, 2026-10-07)
Logs: `state/runs/20261007-1313-session-H/`. User: "System malfunction / perfect landing and other screen. Are shared
between players. Each ux should be fully autonomous" and "Even before wrecked the ux were sharing perfect landing and
danger (changing colors and trembling)". Research: `notes/research/ux-split-messages.md`, `ux-split-visuals.md`,
`ux-split-inventory.md`. Code **not tested in the game yet** (§9 "Run-H UX checks").

| Seen in run H | Cause | 0.7.0 (`uxsplit.lua` unless noted) |
|---|---|---|
| SYSTEM MALFUNCTION, PERFECT LANDING, WRONG WAY... in both halves | the game has ONE message system with no player parameter: every message is copied into every HUD | each message is attributed to its poster (the car's UI component, an ability, a HUD widget) and its copies in the other players' HUDs are hidden (`UxSplitMessages`); a removal the game makes for everybody is re-posted for the players that still hold the message (`UxSplitRepost`) |
| the whole HUD turns red when ONE player is on its last life | the last-crash colours are written into one world-wide colour set read by almost every HUD material | that write is blocked; that player's own HUD is tinted red instead (`UxSplitHudColours`) |
| full-screen desaturation / flash / blur ("trembling") over both halves | one level actor draws the danger effects of the FIRST local car it finds over every view | switched off while split; each player's last life / system malfunction shown with its own camera fade (`UxSplitFullScreenFx`, `UxSplitFadeMax`) |
| the ramjet turns both HUDs blue; P1's critical malfunction dims P2's engine panel | the engine panel binds player index 0's car and its ramjet animation moves the world colour set | guest HUDs bind their own car (`UxSplitIndexRemap`); the ramjet colour animation is stopped and the HUD of the player in ramjet is tinted blue (`UxSplitRamjetColour`) |
| P2's half showed LAP 2 on lap 1 | the lap offset was measured before P1 crossed the start line (`hud.lua`) | offset taken only after P1's first crossing, 0 before; display 1..laps |
| radio portrait, arcade counters, the game's hidden P2 HUD | one dialogue line / P1's view-model values / a third HUD that writes the map colours and beeps | portrait hidden for guests (`UxSplitGuestHolo`), counters collapsed (`GuestHudCollapse`), hidden HUD's map + countdown collapsed and its car bindings removed (`UxSplitGameHud`) |
| P2's Start froze the race (paused, no menu); no pause menu of a split race took any input; after P1's wreck nobody could pause | P2 had two pause bindings (its own HUD + the game's hidden HUD, owned by P2); the game makes every menu for the LAST local player and gives UI input to the FIRST one only; the pause state machine dies with P1's race state | `pause.lua` layers A-G: the extra binding removed and HUD inputs off while paused (`PauseHudInputGuard`); the menu made for the player who pressed Start and taken over by the game (`PauseCsmHook`, `PauseMenuPrecreate`, `PauseMenuOwner`); guests' UI input raised while paused (`PauseUiImcBoost`); focus kept (`PauseMenuFocusOwner`); a safety net (`PauseLostMenu`, `PauseAnyStartResumes`); the pause machine restarted after a wreck (`PauseRestartCsm`) |

Not changed (already per player, or not shared): camera shakes, HUD sway, the scanline / SYSTEMS CRITICAL / big malfunction
icons, position, lap times, speedometer, energy, threat indicators. Known limit: one message queue per container, so a
copy hidden in your half still takes its slot (a lower-priority message of yours can wait a few seconds).

Still shared or not done (phase 2): subtitles are drawn across the whole window (also over P2's half); the local results,
spectate and final results screens, and the Settings / Logbook / confirm dialogs (Exit, Abandon) opened from a pause are
the game's P2-owned screens (the results screen may ignore every pad: leave as in §9 V-UX-13); in Eliminator mode the
guests' danger-zone alert follows P1; weather particles follow P1's camera; the Concussed / Frozen / Heated / Blinded /
Corroded full-screen effects are off while the race is split (only last life and the malfunction flash are shown, per
player).

### 1.8 0.9.0 (2026-10-07): campaign-style planet and circuit choice; 3-player HUD fix
User request: "the planet selection should be similar to the one in campaign, with planets moving and then the circuit
for each one". Static research: `notes/research/campaign-map/` (01 the campaign planet arc, 02 the run map, 03 hosting
the game widgets from Lua). **Not tested in the game yet** (§9 "0.9.0 checks").

| Part | What it does |
|---|---|
| `cmap.lua` PLANET view | creates the campaign's `WBP_PlanetSelector` (one `WBP_Diegetic_MapOverview_Btn` per planet on the campaign's 7200-unit circle, ArcAngle 35°, all planets unlocked, no ship/trophy icon), render-scaled into the page; the overview's info block (Aurebesh line, Font_Display name, the planet's rich-text description) and the arrival video; planet chips as the control |
| `cmap.lua` TRACK view | a 3840x1500 run map scaled into the page: `T_UI_MapEvent_Bg`, the big turning planet (`WBP_RunMap_Planet`), circuit rows with olive path lines (amber on the focused row), variant nodes (`WBP_RunMap_Activity_Presentation_Btn` without a campaign node), labels and a `WBP_Tooltip_Holder` card |
| fallback | any failure (build, feeding the arc, a preview) puts that step back on the 0.8.0 list for the rest of the page, logged once |
| `hud.lua` (run L, 3 players) | the race HUD's top bar (timer / lap / POS, a fixed 3620-px box) was cut at both ends in the quarter views (3P bottom, 4P): it now scales down to fit (`HudFitInterior`, V-HUD-15) |

### 1.7 0.8.0 (2026-10-07): subtitles per player, 3D vehicle cards, pause phase 2
From run I (`state/runs/20261007-16*-session-I/`, `notes/research/live-run-I-facts.md`) and run J. Research:
`notes/research/subtitles-split.md`, `vehicle-preview.md`, `pause-split.md`. Code **not tested in the game yet** (§9
"0.8.0 checks"); every new part has its own switch. The module comments and a few log lines say 0.7.2: that is the
same work, released as 0.8.0. The run-J camera fixes (§9 "Run-I results", "0.7.2 (run J)") are part of 0.8.0 too.

| Seen | Cause | 0.8.0 |
|---|---|---|
| radio chatter / subtitles meant for one player drawn near the top of P2's half ("BIDDY BLAS: *laughs* Who taught you to race?", "ARY QUILL: *screams*") | the game has ONE subtitle box for the whole window (P1-owned), placed 450 units above the window bottom for every line | `subsplit.lua`: each line is attributed (the pod that asked for it, the dialogue rules, ability hits, the speaker's car) and moved into its player's half; a line for everybody shows in every half (the game's box in P1's half + a copy per guest) (`UxSplitSubtitles`, `UxSplitSub*`) |
| the VEHICLES step showed one class picture per column (tinted) or a pilot portrait | the game has no per-model pictures; the models exist only in 3D (garage / paddock) | `vpreview.lua`: a live, turning 3D render of each column's pick (one "photo bay" per column in the sky above the menu sets); the manufacturer badge top left; the livery owner's portrait as an inset; the 2D card stays the fallback (`SetupPreview*`, `SetupCard*`) |
| Settings / Logbook / the EXIT and ABANDON confirm dialogs opened from a split-race pause belonged to the wrong player (a guest's EXIT could not be answered by that guest); after a split race the front-end profile panel read "Player 2" | the game makes every screen for the LAST local player; the confirm dialogs live in a P1-owned container; the profile card reads its owner's name once | `pause.lua` C2: Settings and its pages pre-created for the pause controller (the player the pause screen belongs to); D2: guests' UI input lowered while a dialog is up; `menubridge.lua`: the pause controller answers the dialogs (A / B / D-pad), B runs a screen's own back path, the controller drives a screen another player owns, the profile card is re-owned by P1 (`PauseSubScreen*`, `PauseDialogGuestUi`, `MenuBridge*`) |

The Logbook pre-create (`PauseSubScreenHook`) hooks a function whose first parameter is a soft pointer. The soft-pointer
rule (run F crashed right after such a hook) keeps it **off by default**: the Logbook is then the game's (P2's) screen and
the pause controller drives it through the bridge. It is turned on only for the dedicated V-PAU-20 test (§9).

Known limits: one voice line plays for both players and the dialogue cooldowns stay shared (a bark for one player can
suppress the other's); lines from the game's native-only paths (overtakes, narrative moments, cinematic sections) have
no request: they go by the event's rule, then the speaker's car, then `UxSplitSubUnmatched`; a new instance of the same
event within 1.5 s inherits the previous line's player(s); the radio portrait still animates in P1's HUD for every line
and stays hidden in guest HUDs (per-player portrait not built, V-SUB-09); the default bay material
(`M_UI_RetainerBox_ScreenSpace`) adds the game's diegetic-screen look (warp lines, radial mask, twinkle): compare with
`M_ThumbnailMask` (V-VP-03); pause phase 2 is untested beyond 2 players.

### 1.9 0.10.0 (2026-10-10): RACERS step, crash fix, P1 menus after a race, game-only tracks
User request (2026-10-09): "A character should be chosen, a kart then. and then we should be able to map out all the
benefits and perks added to the kart (all unlocked just for this mod)", "kart are horrible p1 and p2 are not similar".
Design: `notes/design/vehicle-step-v2.md` (titled 0.11.0, shipped as 0.10.0). **Run live on 2026-10-10**: three
sessions on the hotfix build CL382493 (UE4SS Galactic Racer Edition, 1280x720, 4 pads), 0 error lines, no crash (§9
"Session R", `notes/research/live-run-racers-facts.md`).

| Part | What it does |
|---|---|
| RACERS (step 5 of RACE SETUP, §3.3) | replaces the VEHICLES columns. Every player (P1 and each guest) gets the same card and moves through **PILOT → VEHICLE → PERKS → READY** with their own pad. PILOT: the pilot's full body over the racer-style art, the style's 3 traits, the signature vehicle and a roster of head shots (a pilot another player holds is dimmed with that player's tag). VEHICLE: the live 3D render, MODEL and LIVERY rows, DRIVEN BY, a SIGNATURE chip. PERKS: the whole kart on one board, everything unlocked (no save, no unlock touched): loadout kit, 4 d-pad abilities + the crash ability, 6 part slots, 6 upgrade bars 0-10 with POWER and ENERGY, racer style and 3 traits, a detail card. READY: the pick, a READY stamp in the player's colour and the loadout as icons. The picks are saved per pad (`LastRaceRacers`) |
| in the race | each human races the chosen pilot, vehicle and loadout: upgrade levels, abilities, crash ability and parts are written into that player's build at the launch, the traits are applied at the race start, and everything is checked again in the race (`[perkapply]` lines). An AI that had a human's pilot gets another pilot, car and name |
| crash fix (keybinds) | 0.9.x could crash on a keyboard key (crash_2026_10_08_13_27_33): UE4SS runs keybinds on its own thread, and the key's action touched the game's Lua state from there. Keys are now queued (`keyq.lua`) and their actions run on the game thread; Ctrl+F11 / `couch reload` exist only with `AllowHotReload = true` (§5) |
| P1 menus after a race (`feowner.lua`) | after a split race the main menu, Settings and the other front-end screens belonged to the last guest: that guest drove them, P1's pad did nothing and the tabs showed keyboard glyphs. They are now made for P1. The Multiplayer tab is hidden while guests exist (`FrontEnd*`, §7.2) |
| game-only tracks | the setup lists only the tracks the game itself offers (`SetupTrackSet = "arcade"`: Quick Race, Quick Podrace and the Arcade's race tracks), no debug, prologue or campaign copies, and only the conditions the game gives each track (`SetupTrackPoolConds`) |
| also | the input filter DLL knows both game builds (CL381121 and the hotfix CL382493; the log says `build=`); a re-install keeps your UE4SS console setting (§2.2); 3D previews: one 960x540 target, bays 20000 units apart, one capture budget over all bays; the campaign planet arc and run map (§1.8) are on by default again (`SetupCampaignMap`; the public 0.9.3 had them off) |

Still limited:
- **P1's pad on the results screen of a split race: fixed after the first runs (0.10.1, V-MB-09).** The screen belongs
  to the last local player and P1's A reached none of P1's input objects (V-MB-08 failed); menubridge now puts an
  invisible plain Button with P1's focus on that screen, Slate delivers P1's A to it, and the bridge clicks CONTINUE
  (verified live 2026-10-10, `MenuBridgeP1Catcher`).
- Connected but un-joined pads: the first START warns (`PADS 3, 4 ARE NOT JOINED: START AGAIN FOR AI CARS`); a second
  START within 5 s races them as AI-driven players with their own views (a guest slot cannot be removed, §3.2).
- The game pauses itself after about 60 s without game input from any local player (the game's inactivity auto-pause,
  not the mod); resume and steer.
- Hot reload is off by default: restart the game after `install.sh` or a `config_user.lua` change (§2.5).
- Not run live yet: a podrace with loadouts (pods were checked on the cards only), the classic fallback
  (`SetupPlayerFlow = "classic"`), the 960x540 target (the tests ran 640 x 360 at 720p), the UI sounds, P1's double
  back to MODE, a guest leaving between SAVE and START (§9 "Session R").

### 1.10 0.11.0 (2026-10-10): RESTART RACE, guests' pause menus
A private review build (0.11.0-dev); its parts ship with 0.12.0. Run live on 2026-10-10 (§9 "RESTART RACE (0.11.0),
live 2026-10-10").

| Part | What it does |
|---|---|
| RESTART RACE (`restart.lua`, §3.4) | in an offline race SWGRCouch launched, the game's own Retry row is put back right under RESUME with the game's "Restart Race" text; ACCEPT in the game's dialog restarts the same race, and every player's pilot, vehicle and loadout are applied again (`PauseRestart*`, V-RST-*) |
| guests' pause menus (`menubridge.lua`) | on the current game build a guest's A / B did nothing in its own pause menu after a restart. The bridge now presses the row the menu's owner has focused, and bridges a guest's own pause menu and its B on the screens opened from it (`MenuBridgeGuestPauseMenu`, V-MB-10) |
| HUD in half-width views (`hud.lua`) | the opt-in `HudNarrowViews = "readable"` was measured against the default in the same race: the timer, LAP and POS are not bigger, so `"fit"` stays the default (§9 "Session S") |
| also | 43 modules (`restart` is new) |

### 1.11 0.12.0 (2026-10-10): UI v2, back prompt, opponents' tier
User request: screens that "look like they belong to the game". Design: `notes/design/ui-v2/ui-redesign-final.md`
(config keys §12.3, live checks V-FIN-01..16 §14). Run live on 2026-10-10 (§9 "Session U"): 1280x720, 1920x1080 and
3840x2160 (and 1280x800), 1 to 4 players, the game started in English, German and French; Japanese, Chinese
(Simplified), Korean, Polish, Turkish and Arabic switched in a running game (`SetCurrentCulture`, not saved): the game's
texts on the mod's pages render in those scripts, Arabic right to left, but the mod keeps the track names, the CLASS
detail panel and the RACERS data of the session's first build, so long localized names need a game start in that
language.
`UiStyle = "classic"` keeps the 0.11.0 look of every page (the player colours aside).

| Part | What it does |
|---|---|
| FREE MODE page (`lobby.lua`, `theme.lua`) | four posters (RACE card, START RACE, ADD PLAYERS, OPTIONS), the players strip and the status pill (§3.1) |
| OPTIONS (`lobby.lua`) | the option, network and race-builder rows on a sub-page in the game's settings look; the right column explains the focused row and shows a setting's default value (§3.1) |
| RACE SETUP (`setup.lua`, `cmap.lua`) | the `/RACE SETUP` title, a step row, the step's content, the status pill and a command row (BACK; on RACERS with mouse + keyboard also SAVE AND RETURN and START RACE). CLASS, CONDITIONS and MODE as posters; PLANET on the campaign map with planet discs and the planet's Arcade art for the class (no video by default: `SetupCMapVideoW = 0`); TRACK as one framed run map, 3584 x 1316 (§3.3) |
| Opponents (`setup.lua`, `perkapply.lua`) | MODE's second GRID row: the speeder build tier the race launches on, i.e. the AI's strength, from TIER 1 (0%) to TIER 6 (58%); the humans' own loadouts are written over it; pods: `Standard`. The 0.9 VEHICLES build column set this; it was lost in 0.10, when every launch used the zero base (§3.3, `OpponentTier`, V-RC-27) |
| RACERS cards (`cards2.lua`) | the game's Scenarios posters (1762 / 1162 / 860 su wide for 1-2 / 3 / 4 players, 1300 high); the game's model names in the game's language (`VehicleNameSource`) with CHOOSE MODEL tiles; a studio photo bay behind the 3D render (`PreviewBackdrop`); START RACE and SAVE AND RETURN shown once: on P1's card with a pad, in the command row with mouse + keyboard (`InputModeDebounceMs`) |
| player colours (`consts.lua`) | the game's planet tones: P1 apricot, P2 teal, P3 lime, P4 Crait red (also on the in-race name tags and with `classic`) |
| pad B (`backprompt.lua`) | before the first race P1's B reaches only the game, whose main menu answers it with its QUIT GAME? prompt (ACCEPT focused). On OPTIONS and RACE SETUP the mod answers that prompt No and the page steps back (`BackPromptAsBack`, V-BP-01); on the posters the prompt stays (the game's Exit Game, as on every tab) |
| launch crash fix (`state.lua`, `main.lua`, `theme.lua`) | the 0.12.0-dev build crashed in 4 of 5 launches from RACE SETUP (an access violation about 20 ms after `LOADING…`): the lobby repainted its posters after the game had freed the front end. From the accepted launch until the race world (the "launch hold", V-LCH-07) no front-end page, theme widget or main-menu object is touched. Live: five launches in a row, back to the menu after each, no crash |
| hot-plugged pad (`join.lua`) | a pad switched on while the game runs takes P1 only while P1's own pad is gone (`HotplugPadToP1`, V-JOIN-20); a second pad switched on next to a working P1 pad stays free for ADD PLAYERS |
| release defaults (`config.lua`) | `Debug = false` (set `true` for a bug report); the research probes off: `UxSplitProbeMs = 0`, `WreckProbe = false`, `CrashCamProbe = false`; new `PreviewCalibrate = false` (§7.2) |
| installer (`install.sh`) | a first install keeps UE4SS's own console settings (both windows off), `--console` turns them on; without UE4SS it names the UE4SS Galactic Racer Edition, and it warns about an installed UE4SS 3.0.1-1160 (§2.2) |
| live fixes | poster name line breaks, model-tile code size, style chip and detail tag margins, CLASS check badge, PLANET info block, the pill grows upward, a custom loadout keeps naming the kit it came from after a pilot change, the MODE posters' title band, START ignores a guest's join press (`CardGuestClickGuardMs`) |
| also | 46 modules (`theme`, `cards2` and `backprompt` are new); F9 ends with a `ui v2` section (§5) |

Still limited:
- **B on the FREE MODE posters is the game's Exit Game**, as on every main-menu tab: QUIT GAME? opens with ACCEPT
  focused; choose CANCEL. Only OPTIONS and RACE SETUP turn B into back. Their action bar still reads *(B) Exit
  Game*, and a mouse click on Exit Game there also goes back: return to the posters to quit the game.
- A guest's A press that joins can also click the poster P1's focus is on: START ignores it (`CardGuestClickGuardMs`,
  150 ms); 0.13.0: RACE, ADD PLAYERS and OPTIONS too.
- Not run live yet: a game start in the languages other than English, German and French (only switched in a running
  game, see above); a network race; a full podrace with loadouts.

### 1.12 0.13.0-dev (2026-10-11/12, private): GALAXY RUN, easy builds, P1 wrecked first
- **GALAXY RUN** (`run.lua`, OPTIONS > PLAYERS > *Galaxy run* = `RunLength`): a rogue-style career for 1–4 players.
  The next race launched from FREE MODE starts the run (everyone on a starter build: the pilot's kit with its first 2
  abilities, every level 0, no crash ability / parts / traits). `launch.start` -> `run.prelaunch` puts each player's
  run build (owned perks only, levels capped) and the race's AI tier (TIER 1 -> 6 over the run, speeders) into the
  launch plan. POSTRACE: every racer's place (`RacingGameState.Racers`, `RaceEventComponent.EventPosition` /
  `EventFinishTime`); FRONTEND: points 25/18/15/12/10/8/6/4/2/1, the team target (top 5 in the first third, top 3,
  1st in the final) or hull -1 (3 at the start; 0 = RUN LOST), level cap +1, a reward offer per player (ability or
  crash ability, part, trait or +1 cap; the last human picks out of 4). Between races START / RACE open RACE SETUP on
  the racer cards for the run's next race (`setup.openRun`, `setup.runCandidates`: no track twice, another planet
  than the last race, a full grid for the final, one eliminator in the middle). On the cards: the reward picker
  first, pickers list owned perks only (`perks.itemFilter`), L/R on perks and KIT locked, levels capped, SURPRISE /
  COPY off. A race left before its end, or restarted, does not count. The run never replaces a player's own build
  (session memory, `LastRaceRacers`). Files: `Mods/SWGRCouch/run.txt` (the run; `return nil` = none) and
  `run-history.txt` (one line per finished run). Live: solo run (2 races), 2P run to RUN LOST, eliminator race.
- **GALAXY RUN v2 (2026-10-12):** every event is a normal race scored by the mod per player (the game's own
  TimeTrial / Takedowns / RamjetDistance / Precision rules track ONE player and have no AI grid): `race`,
  `eliminator`, `final` (full grid, must-win: a miss costs hull and is raced again), `timetrial` (humans-only grid
  via plan.grid "max" + maxRacers = humans; race time; everybody must finish), `hotlap` (BestLapTime; a human lap
  in the field's top 3), `boost` (afterburner seconds = `VehicleState.AfterburnerEnergy` falling, ramjet
  `IsRamjetting()` x2; team 45 s per player; `EBoostState` is only the selected boost), `takedown` (full grid;
  uxsplit's per-player "Takedown" HUD message -> `St.emit("hudmsg")`; team 1 per player; solo: RaceEventVM).
  Points 25/18/15/12 by rank among the humans; credits 300/220/160/120 (x1.5 risky route) + 100 for beating the
  rival (the best AI of the last race, `bIsRival` / `RacingGameState.Rival`); 200 at the start. Route choice: two
  next events (A race, B challenge), A on the RACE card switches. Cards: free reward, then the shop (perks, level
  cap, repairs, reroll 50 +25, leave). A wreck breaks a random equipped part until repaired (120). Live HUD line
  next to the timer (`hud.fastChallenge`, Font_Diegetic Bold: Font_Numbers has digits only). Test bots:
  testcmd `bot <p|all> on|off`, `cfg.TestBots` (the Disconnect input override: the game's AI drives the human
  cars). Live: 3-player bot runs WON x3 with race, takedown, hot lap, boost, time trial, eliminator and finals.
- **Easy builds** (`CardEasyBuilds`): a guest's **Y** = SURPRISE ME (random free pilot, its vehicle, a random kit
  of the KIT row, READY), **X** = COPY P1 (P1's loadout on the guest's pilot, READY). P1's pad only reaches the
  cards through the 5-button sink, so these are the guests' shortcuts. Live.
- **P1 wrecked first** (task #35): the guests' race timer (the game's RaceEventVM stops at P1's wreck and the HUD
  rewrites its text every frame: `hud.fastTimer` puts a twin text in place of `Txt_Time`, `HudGuestTimer`); the
  UI-over-vehicle input guard for every player still racing; P1's view put straight on the spectated car while the
  game's crash camera holds it (`WreckSpectateReasserts`). Live. The full loss of control seen with real pads was not
  reproduced with the test pads.
- Split graphics **quality** = Lumen off + no virtual shadow maps at full resolution (measured: 112 -> 161 fps in a
  2P race; the old quality preset gave no gain). The guest-press guard now covers RACE, ADD PLAYERS and OPTIONS.

## 2. Install (Lutris, Proton, Steam in the prefix)

The short install is the README's *Install* section. This section is the full reference, written for the test setup:
the Windows Steam client inside a Lutris Wine prefix.

### 2.1 Prerequisites
- Test setup: the game is installed with the **Windows Steam client inside the Lutris Wine prefix** (GE-Proton + umu).
  Keep one prefix and one GE-Proton version for the whole test phase. Each PC needs its own Steam copy: Denuvo allows
  5 machine activations per 24 h.
- Pads: XInput pads in the order P1..P4. In the test setup Steam Input is **off** and the pads come through
  InputPlumber.
- UE4SS: the **UE4SS Galactic Racer Edition** (open beta, 2026-10-08), `dwmapi.dll` + `ue4ss/`. The release zip
  `SWGRCouch-<version>-with-UE4SS.zip` ships it in `ue4ss-build/`; with the mod-only zip, point `UE4SS_DIR` at an
  unpacked copy. UE4SS 3.0.1-1160 (the 0.9.0 / 0.9.1 zips) does not boot on the hotfix build CL382493: `install.sh`
  warns when it finds it in the game.
- The launch chain is Steam → `Launcher.exe -isSteam` → `SWGR.exe` → `Griffin/Binaries/Win64/SWGR-Win64-Shipping.exe`.
  UE4SS loads into the last one through the `dwmapi.dll` proxy next to it.

### 2.2 Run the installer
From the unpacked release folder (the one that holds `install.sh`):
```bash
./install.sh "<install root containing Griffin/>"                                  # mod + UE4SS
./install.sh "<install root>" --prefix "<wine prefix>"                             # + network Engine.ini
./install.sh --prefix "<wine prefix>" --fastboot-ini                               # optional, §2.6
UE4SS_DIR="<unpacked UE4SS Galactic Racer Edition>" ./install.sh "<install root>"  # UE4SS from another folder
```
Steam (Proton) prefix of this game: `~/.local/share/Steam/steamapps/compatdata/4078430/pfx`.
The install root is typically
`<prefix>/drive_c/Program Files (x86)/Steam/steamapps/common/STAR WARS Galactic Racer`. The script never deletes
anything; run `install.sh --help` for every option. It does the following:

1. UE4SS, from `$UE4SS_DIR` when it is set, else from `ue4ss-build/` next to `install.sh` (the with-UE4SS zip): the
   core files `dwmapi.dll`, `ue4ss/UE4SS.dll`, `ue4ss/MemberVariableLayout.ini` and
   `ue4ss/UE4SS_SDK_Backends/UE4SS.json` are always replaced, a different old file first saved as
   `<file>.swgrcouch-<date>` (an older UE4SS left in place does not boot on the hotfixed game). Every other UE4SS file
   is copied without overwriting (`cp -n`), so your edited `UE4SS-settings.ini` and `mods.txt` survive a re-install.
   Without either source, a UE4SS already in the game is kept as it is (with a WARNING when it is 3.0.1-1160); with no
   UE4SS at all the script stops and names the UE4SS Galactic Racer Edition.
2. Copies `SWGRCouch/` (`Scripts/*.lua`, `enabled.txt`, this README) to `ue4ss/Mods/SWGRCouch/`, overwriting the
   scripts, and the custom signatures `ue4ss_signatures/*.lua` to `ue4ss/UE4SS_Signatures/` (a different existing file
   gets a dated copy first). `settings.txt` and `Scripts/config_user.lua`, which the mod or you create there, are
   never shipped, so they are never overwritten. It also copies the input filter `native/swgr_inputfilter.dll` (0.4.0,
   §3.4) to `ue4ss/Mods/SWGRCouch/native/`, **only while the game is closed** (the DLL stays loaded in the game process; a
   running game gets a WARN line and keeps the old copy). Rebuild it after a game update with
   `SWGRCouch/native/inputfilter/build.sh` (system LLVM); a DLL that does not match the exe refuses to patch
   (`reason=mismatch` in the log) and the mod falls back to the Lua-only `kbsplit` isolation.
   Since run G the DLL rereads its cfg (`swgr_inputfilter.cfg`, written by `inputfix.lua`) in its own small thread
   every 250 ms, so a car bind (`wo` line) or an owner change applies within 0.25 s even when nobody touches a pad
   (before, it waited for the next pad/key event, seconds). `swgr_inputfilter.status` then shows `reload_thread=1`,
   `reload_ms=250`, `reloads=<n>` and `torn_retries=<n>` (a half-written cfg read and retried); `reload_thread=0`
   means the thread could not start and the old input-path reload is used. The new DLL needs a game restart (a running
   game keeps the old one loaded). Offline self-test (no game; a development tool, not in the release):
   `tools/dlltest/run.sh` (system Wine) prints
   `PASS: 'w' applied by the reload thread without any input event`.
3. `mods.txt`: adds `SWGRCouch : 1` at the top (it must stay above the `Keybinds : 1` line), forces
   `SplitScreenMod : 0` (it would call CreatePlayer/RemovePlayer behind our back), and makes sure
   `ConsoleEnablerMod : 1` is there (the `couch` console command needs it). When no Blueprint mod needs it (no `.pak`
   in `Griffin/Content/Paks/LogicMods/`) it sets `BPModLoaderMod : 0`, also in `mods.json`: its Insert keybind calls
   into the game thread from UE4SS's event-loop thread, the cross-thread race of crash_2026_10_08_13_27_33.
4. `UE4SS-settings.ini` (a copy is saved first as `UE4SS-settings.ini.swgrcouch-<date>`). The log windows
   (`ConsoleEnabled`, `GuiConsoleEnabled`, `GuiConsoleVisible`) only on request (0.12.0): `--console` turns them on
   (testers, bug reports), `--quiet-console` turns them off; otherwise a first install keeps UE4SS's own values (both
   off) and a re-install leaves them as they are (`UE4SS: console windows left as they are`). `UE4SS.log` has every
   line either way. It always sets `bForceGUObjectArrayForIteration = true` and `UseCache = 0` (the Galactic Racer
   Edition needs them on the hotfixed game, and an older ini is kept). With options it also sets the engine-version
   override and the game-thread method (§2.3).
5. With `--prefix`: appends `config/Engine.ini` to the prefix's user `Engine.ini` (§2.4), between marker lines,
   and only once. A dated copy of the old file is saved first. The user config folder is
   `<prefix>/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/`.
6. With `--prefix … --fastboot-ini`: sets `bEnableEOSAccountLinking=False` in that folder's `GameUserSettings.ini`, in
   place (dated copy first; `--fastboot-ini-undo` sets it back to `True`). With only this option the `Engine.ini` is
   not touched; add `--net` to do both.

### 2.3 Lutris and UE4SS settings
- **Lutris → game options → environment:** `WINEDLLOVERRIDES` = `dwmapi=n,b`. Set it on the Lutris entry that starts
  Steam: the game is started by Steam inside the prefix and inherits Steam's environment. The proof that it worked
  is `Griffin/Binaries/Win64/ue4ss/UE4SS.log` appearing.
- Optional: `PROTON_LOG=1` for a Proton log (umu writes `$HOME/steam-<GAMEID>.log`).
- Extra game arguments (`-port=N`, `-UseIrisReplication=0`) go in the game's **Steam launch options** inside the
  prefix's Steam client.
- `ue4ss/UE4SS-settings.ini` (path relative to `Griffin/Binaries/Win64/`):

| Section / key | Set to | When |
|---|---|---|
| `[Debug] ConsoleEnabled`, `GuiConsoleEnabled`, `GuiConsoleVisible` | `1` | tests and bug reports (`install.sh --console`; 0.12.0: off after a first install); `GraphicsAPI = dx11` if the GUI console window fails under Proton |
| `[EngineVersionOverride] MajorVersion` / `MinorVersion` | `5` / `7` | **only** if the log shows a wrong engine version or failed AOB scans (`install.sh --ue57`). Also try `DebugBuild = false` |
| `[General] DefaultExecuteInGameThreadMethod` | `ProcessEvent` | only if the boot banner shows `EngineTickAvailable=false` (`install.sh --gt-processevent`; V-CORE-01). `[Hooks] EngineTickResolveMethod = VTable` is the other thing to try first |
| `[General] DefaultFNameToStringMethod` | `Conv_NameToString` | only if the FName::ToString scan fails |
| `[General] bUseUObjectArrayCache` | keep `false` (shipped) | — |
| `[Hooks] HookProcessInternal`, `HookProcessLocalScriptFunction`, `HookEngineTick`, `HookLoadMap`, `HookInitGameState`, `HookProcessConsoleExec` | keep `1` (shipped) | Blueprint hooks, game-thread scheduling, LoadMap/InitGameState hooks and the console all need them |
| `[General] EnableHotReloadSystem` | keep `0` | the mod reloads itself with Ctrl+F11 (only with `AllowHotReload = true`, §2.5); `1` would add Ctrl+R (reloads **all** mods) |

- **If the AOB scans still fail** after the version override, add per-game signature files in `ue4ss/UE4SS_Signatures/`
  (see `notes/research/ue4ss-api.md` §14). Done for this build: `ue4ss_signatures/` (installed into
  `ue4ss/UE4SS_Signatures/`).

### 2.4 Network override (`config/Engine.ini`, every machine that plays online)
- The game routes `GameNetDriver` through PlayFab Party, which allows **one user per device**, so split-screen guests
  cannot travel over it. The override replaces the driver with plain `IpNetDriver` in the section the game itself uses
  (`[/Script/Engine.GameEngine]` with `ClearArray`; `[/Script/Engine.Engine]` would lose). It raises the IP timeouts
  (connect 120 s for cold World Partition loads), has a commented Iris switch and a commented unique-net-id fix, and
  turns Sentry crash uploads off.
- Target file: `<prefix>/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/Engine.ini`.
  It is the folder where `GameUserSettings.ini` appears (V-NET-01; verified in the Steam prefix 2026-10-06). Earlier
  versions of `install.sh` wrote to `.../AppData/Local/Griffin/...`, which the game never reads: re-run it. `install.sh --prefix` appends it; by hand, append the file
  as is.
- Check: in the first front end the log must show
  `[SWGRCouch][net] GameNetDriver = /Script/OnlineSubsystemUtils.IpNetDriver: Engine.ini override active`. Otherwise
  the lobby's network status (v2: the players strip's network line) says `ENGINE.INI NET OVERRIDE NOT ACTIVE`.
- **Official online play is broken while the override is active.** `install.sh --prefix <p> --net-off` comments the
  block out and `--net-on` restores it. Using a second Wine prefix for official play also works.
- If the game rewrites the user `Engine.ini` on exit and drops the marker comments, re-run `install.sh --prefix`: it
  checks for the driver line itself, not only the markers.

### 2.5 Hot reload and updating
- **Ctrl+F11** (or console `couch reload`) runs `RestartCurrentMod()` from the game thread. **0.10.0: off by default**
  (`AllowHotReload = false`): UE4SS closes the old Lua state while other threads may still use it, which can crash the
  game (RE-UE4SS #1445). `AllowHotReload = true` in `config_user.lua` turns the key and the command on. The mod re-reads
  every script and hands its state over through UE4SS shared variables: joined guests, hosting/connection state, gfx
  values to restore, takeover records, the pending return to the tab, the RACERS launch patch. It works in the lobby
  and mid-race (V-CORE-11).
- To deploy edited scripts, re-run `install.sh` (it overwrites `Scripts/`) and restart the game (Ctrl+F11 only with
  `AllowHotReload = true`).
- `config.lua` changes need a restart (or Ctrl+F11 with `AllowHotReload = true`); `settings.txt` is read at boot.

### 2.5b Turning the mod off
Rename `ue4ss/Mods/SWGRCouch/enabled.txt` (for example to `enabled.txt.off`) and restart the game; rename it back to
turn the mod on. `SWGRCouch : 0` in `mods.txt` is **not** enough: UE4SS still loads a mod folder that has an
`enabled.txt` (seen 2026-10-07). The native input filter is only loaded by the mod, so it is off too.

### 2.6 No-intro mode (`Scripts/fastboot.lua`, on by default)
Boots straight to the main menu. No hook is used: a game-thread loop (every `FastBootPollMs`, armed on every new
world) calls the game's own native functions, and stops itself 20 s after the main menu, 5 s into a non-front-end map,
or after 3 min.

| Skipped | How (static evidence in the `fastboot.lua` header) | Switch |
|---|---|---|
| Fuse / brand ident movies + `PRESS A TO CONTINUE` | as soon as `IsReadyToLeavePreLoad()` and the save manager's `IsInitialLoadComplete()` are true: `Close()` on the title widget's two media players, then `AdvancePreLoadIfPossible()` (exactly what pressing A does) | `FastBootSkipTitle`, `FastBootStopIdentMovies` |
| photosensitivity warning | only when `HasExperiencedBootFlow()` is true: the widget's own CONTINUE (`ContinueToNextState(None)` or `ReturnToMainMenu()`) | `FastBootSkipPhotosensitivity`, `FastBootPhotoBlind` |
| Epic login page in the browser, `SOCIAL OVERLAY UNAVAILABLE … EOS linking will be disabled` modal | the profile flag `bUseEosLinking` (in `GriffinSave.6.sav`) and its settings mirror `bEnableEOSAccountLinking` are set to false right before the title is left: the same end state as pressing ACCEPT on that modal, saved by the game on its next save. Fallback at the menu: `DisableEpicLinking()` + `RemoveMessage(EosRequirementsFail)` | `FastBootEpic`, `FastBootEosDialog` |
| Epic link-account screen (if it shows) | its CANCEL: `ContinueToNextState(None)` | `FastBootEpic` |
| `FastBootSignIn` | `"always"` | 0.13.0 the main menu's SIGN IN STATUS wait (`FrontEndGameMode.LoginTimeoutTime`, 10 s, waited out in full with Steam offline) is skipped at every front-end visit \| `"off"` | V-FB-SIGNIN |

**Never skipped:** EULA, privacy policy (online/offline), save-version and save-corrupted screens, first-boot
settings / brightness / gamma. A first boot (or a save problem) still shows them; the next boot is fast.

- `FastBootEpic = "off"` turns the game's **EOS account linking off persistently** (it is what the modal's ACCEPT
  does). To use Epic linking again: `FastBootEpic = "keep"` in `config_user.lua`, then turn the option on in the
  game's settings (or `install.sh --prefix <p> --fastboot-ini-undo`).
- Optional ini companion: `install.sh --prefix <p> --fastboot-ini` writes `bEnableEOSAccountLinking=False` in the
  user `GameUserSettings.ini` (only the settings mirror; the login gate reads the profile flag, so the Lua module is
  what actually stops the login).
- Optional Steam launch option `-nosplash`: hides the engine splash image (standard UE switch; whether `Launcher.exe`
  passes launch options on to the game exe is not verified).
- **Not recommended:** `-NoEOS` (disables EOS completely; untested, may break other features) and the cvar
  `BootFlow.BypassEpicLogin` (exists, but no code reading it was found).
- Log lines (`[SWGRCouch][fastboot]`): `title: title skipped: …`, `photo: photosensitivity warning skipped: …`,
  `epic: profile bUseEosLinking true -> false`, `menu: main menu reached X s after arming`, `stopped (…)`. F9 prints a
  `fastboot:` line with the same state.

## 3. Using the FREE MODE tab

### 3.1 The lobby page
Open the main menu and go right with the bumpers past Multiplayer, or press **F5**. 0.12.0 (`UiStyle = "v2"`, the
default) draws the page like the game's own tabs: four posters, a players strip and a status pill. **P1 moves between
the posters with the d-pad / left stick (or the keyboard arrows) and presses A (or Enter / Space); the mouse works
too.** Each poster is an invisible focus target ("ghost") under a painted look: the pad goes through the game's
CommonUI focus (the mod keeps P1's focus on the page after every page show), the keyboard through UE4SS keybinds.
Left / right move between RACE and the right column (right from RACE goes to the right-column poster focused last),
up / down along the right column (START RACE, ADD PLAYERS, OPTIONS); they never change a value here. The first focus
is START RACE when a race is chosen, else the RACE card. The small line above a poster's title (`2 players · 10 AI`,
`Join with pads 2 to 4`, the OPTIONS values, `Change race`) shows only while that poster is focused; `Launching…` and
a lock with its reason always show.

| Poster | Shows | A / click |
|---|---|---|
| RACE | the chosen race as an event card: the planet (in its tone), the class and mode (`LANDSPEEDER · RACE`), the track, then `REVERSE · SUNSET · 12 RACERS`; `Change race` while focused. No race yet: `CHOOSE RACE` (`Class, planet, track, mode`) | opens the RACE SETUP flow (§3.3) |
| START RACE | `2 players · 10 AI` (the local players, plus the remote ones while hosting, and the AI of the chosen grid); `Launching…` while a launch runs. Locked, with its reason: `Choose a race first`; `Start hosting in Options` (NETWORK HOST, not listening yet); `Waiting for the host` (NETWORK JOIN) | launch (§3.4); a locked START keeps the focus and posts its reason to the pill (`CHOOSE A RACE FIRST`, ...) |
| ADD PLAYERS | `Join with pads 2 to 4` (KEYBOARD IS P1: `pads 1 to 3`); once on: `PADS ON` / `Until the game restarts`; locked `Disconnect to change players` while connected to a host | press twice within 5 s (the badge `Press again to confirm` shows meanwhile): creates guest slots for the plugged-in pads (kept until the game exits; restart before online play) |
| OPTIONS | the current values, e.g. `Top / bottom · Performance · Offline` | the OPTIONS sub-page (below) |

**Players strip** (display only), one cell per player: the `P1`..`P4` tag in the player's colour, the head shot of the
pilot that pad raced last (else a player icon), the pad (`PAD 1`; `KEYBOARD` with KEYBOARD IS P1) and a state line
(`(A)`, `(B)`, `(Start)`: the pad's button glyph):

| Cell | State line |
|---|---|
| P1 | `Host · ready` |
| a joined guest | `(B) to leave` (KEYBOARD IS P1, pad 1: `(Start) Hold to leave`) · `Controller disconnected` · `Leaves after this race` |
| an open slot | `(A) to join` · `Connect pad 3` · `Add players first` (ADD PLAYERS not used yet) · `Available after the next race` · `Disconnect to change players` (connected to a host) · `Empty` |

While NETWORK is not OFFLINE the strip adds a network line: `NETWORK` and the remote status (e.g.
`HOSTING ON PORT 7777: 1 REMOTE PLAYERS`, `CONNECTED TO <address>:7777`, `NOT CONNECTED`, `NETWORK ERROR: …`); each
change of that status is also posted once to the pill.

**Status pill**: the page's messages, bottom left (`StatusPillPlace`), each for 5 s (`StatusPillMs`); refusals and
errors take the rust warn colour.

**B and Escape on the posters are the game's Exit Game**, as on every main-menu tab: the game's QUIT GAME? prompt
opens with ACCEPT focused; choose CANCEL. (The first A / Enter of the mod's own navigation after a Back is ignored
once; the game's prompt takes the pad's A itself.) A guest's A press that joins can also click the poster P1's focus
is on: START ignores a click within `CardGuestClickGuardMs` (150 ms) of a guest's A; RACE, ADD PLAYERS and OPTIONS do
not yet.

**OPTIONS** (`/OPTIONS`): one list in the game's settings look, in four groups. Up / down moves (the list does not
wrap; down from the last row reaches **BACK**); left / right on a value row steps the value (pad and keyboard arrows);
A (Enter / Space, a click) steps a value row forward or runs an action row. The right column shows the focused row's
name, a help text and, for a setting row, its `Default value: …` (from `config.Defaults`). **BACK**, P1's pad **B**
(the back prompt, §1.11; not with KEYBOARD IS P1), **Backspace** or a tab change (LB / RB) return to the posters with
the focus on OPTIONS.

| Group | Row | Values |
|---|---|---|
| SPLIT SCREEN | 2-player layout | TOP / BOTTOM, SIDE BY SIDE (F8 does the same, also mid-race) |
| | Split graphics | AUTO, PERFORMANCE, QUALITY, MY SETTINGS |
| | Takedown cameras | ON / OFF (OFF suppresses the cut-away while 2+ views are up) |
| | Name tags | ON / OFF |
| PLAYERS | Keyboard is player 1 | ON / OFF; refused while a guest is joined (`REMOVE GUESTS FIRST`) or while connected to a host (`DISCONNECT TO CHANGE PLAYERS`) |
| NETWORK | Network | OFFLINE, HOST, JOIN; refused while hosting (`STOP HOSTING FIRST`) or connected (`DISCONNECT FIRST`) |
| | `Host on port 7777` (HOST) / `Connect to <address>:7777` (JOIN); hidden while OFFLINE | START / STOP, CONNECT / DISCONNECT (§4) |
| ADVANCED | Race builder | OPEN: the game's developer race builder (the 0.3 way) |

Every option is saved at once in `ue4ss/Mods/SWGRCouch/settings.txt`.

**`UiStyle = "classic"`** (the 0.11.0 page; read when the page is built, a change shows when the page is shown
again): a column of the game's own buttons (dark text on the light page). **P1 navigates it with the d-pad / left
stick (or the keyboard arrows):** up/down moves the highlighted row, left/right changes a value row, **A** (or Enter)
activates; the mouse works too. The pad goes through the game's CommonUI focus (the mod keeps P1's focus on the
highlighted row after every page show); the keyboard arrows / Enter / Space are UE4SS keybinds. The first A / Enter
after a Back (B / Escape) is ignored once: it may be the one that answers the game's "Exit game?" prompt.

| Row | Shows | A / click |
|---|---|---|
| header | `FREE MODE` | — |
| P1..P4 cards | `P1  READY  (pad 1)` · `P2  READY  B = leave` · `--  press A to join (pad 3)` · `P3  CONTROLLER DISCONNECTED` · `--  ADD PLAYERS (BELOW) TO JOIN WITH PADS` | not focusable |
| add players | `ADD PLAYERS (PADS) >` · `PADS ON (UNTIL GAME RESTART)` | press twice within 5 s: creates guest slots for the plugged-in pads (kept until the game exits; restart before online play) |
| remote (online only) | the remote status: `HOSTING ON PORT 7777: 3 REMOTE PLAYERS` / `CONNECTED TO <address>:7777` | not focusable |
| race | `CHOOSE RACE >` or `RACE: <planet> / <track> / <mode> / <vehicle> / 12 RACERS >` | opens the RACE SETUP flow (§3.3) |
| advanced | `ADVANCED: DEV RACE BUILDER >` | opens the game's developer race builder (the 0.3 way) |
| 2P layout | `2P LAYOUT: TOP / BOTTOM` / `SIDE BY SIDE` | cycle (F8 does the same, also mid-race) |
| split graphics | `SPLIT GRAPHICS: PERFORMANCE` / `AUTO` / `QUALITY` / `MY SETTINGS` | cycle |
| takedown cameras | `TAKEDOWN CAMERAS: OFF` | toggle (OFF suppresses the cut-away while 2+ views are up) |
| name tags | `NAME TAGS: ON` | toggle |
| keyboard is P1 | `KEYBOARD IS P1: OFF` | toggle; refused while a guest is joined (`REMOVE GUESTS FIRST`) |
| network | `NETWORK: OFFLINE` / `HOST` / `JOIN` | cycle; refused while hosting or connected |
| network action (hidden offline) | `START HOSTING (PORT 7777)` · `STOP HOSTING` · `CONNECT TO <address>:7777` · `DISCONNECT` | §4 |
| start | `START RACE` · `START HOSTING FIRST` · client: `WAITING FOR HOST` | launch |
| status | last status or error line | — |

### 3.2 Joining with pads
- **P1** is pad 1 plus keyboard/mouse. While the tab is open, guest slots wait silently (the screen stays single-view).
- Opening the tab creates nothing. **ADD PLAYERS** (press it twice; v2: the poster shows `Press again to confirm`)
  creates a guest slot (a dormant local player) for every pad that is **plugged in** (`GuestCreate = "connected"`; a
  pad plugged in later gets its slot within a second while the tab is open; F6 pressed twice creates one without a
  pad). Slots are kept until the game exits: never removed, only ignored outside the tab (§1.1), and they would
  follow the game's own online Multiplayer, so restart the game before playing online.
- A slot that has not joined blocks **CONNECT** (`PAD 3 IS NOT JOINED: PRESS A ON IT BEFORE CONNECTING`). On START
  RACE it asks first (`PAD 3 IS NOT JOINED: PRESS A ON IT, OR START AGAIN FOR AN AI CAR IN ITS VIEW`): a second START
  within 5 s races it as an AI-driven car **with its own split-screen view** (it cannot be removed).
- **Pads 2..4:** press **A** (or **Start**) to join; **B** leaves. Joined players are numbered by pad order, which is
  also the order of their views and the colour of their name tags.
- **Which pad is pad 1, 2, 3 (run G):** under Wine/Proton the game sees the pads in the order of their Linux device
  numbers, `/dev/input/eventN`, lowest first, among the pads the launcher lets through (in the test setup the
  launcher script `tools/swgr-direct.sh`, not in the release: `SWGR_PADS`, the SDL whitelist; default `045e:02ea`
  virtual pads + Sunshine's `045e:0b20`). Not the order you plugged them in, not the order of the `jsN` numbers.
  Check it before a session (game closed or running):
  `grep -E '^N: Name|^H: Handlers' /proc/bus/input/devices | paste - - | grep js`
  (the pad with the lowest `eventN` that the whitelist accepts is pad 1 = P1 or, with KEYBOARD IS P1, P2). The kernel
  gives a new device the lowest free number, so unplugging and replugging a pad does not reliably move it to the end;
  to change the order, unplug every pad and plug them back one by one in the wanted order (or restart the virtual-pad
  source in that order), then restart the game so it enumerates them afresh (a pad hot-plugged into a running game
  may get another slot).
- **A pad switched on while the game runs** (`HotplugPadToP1`, default `"front"`): it becomes P1's controller only
  while P1's own pad is gone, i.e. its disconnect was seen (a Moonlight / Sunshine pad comes back with every client
  connection), never with KEYBOARD IS P1, never while ADD PLAYERS is on (then it joins as a guest). The pad takes P1 in
  the front end (status `NEW CONTROLLER IS PLAYER 1`); one that connects during a race is handled at the next front
  end (`"always"`: at once). A second pad switched on next to a working P1 pad stays free for ADD PLAYERS (0.12.0;
  before, it took P1). `"off"` turns this off.
- **KEYBOARD IS P1: ON** makes the keyboard P1 alone, so pad 1 becomes P2 and pads 2..4 become P3..P4. Pad 1 joins
  with **Start** only and leaves by **holding Start for 1 s**, because its A and B still drive P1's menu. Its strip
  cell shows `(Start) to join` / `(Start) Hold to leave` (classic: the card shows `press START` /
  `HOLD START = leave`).
- Keyboard test path: **F6** joins the next free guest, **F7** removes the last joined one.
- A pad that disconnects shows `Controller disconnected` in its strip cell (classic: `CONTROLLER DISCONNECTED` on its
  card).

### 3.3 Choosing a race (RACE SETUP)
A on the RACE card opens the RACE SETUP page in the same tab. 0.12.0 (`UiStyle = "v2"`): the `/RACE SETUP` title, a
step row (done steps ticked with their value, e.g. `✓LANDSPEEDER ✓JAKKU ✓DEBRIS DUNES · REV`, the current step in a
rust pill; CONDITIONS appears only when the chosen track has several), the step's content, the status pill (bottom
left) and the command row (bottom right: **BACK**; on RACERS with mouse + keyboard also **SAVE AND RETURN** and
**START RACE**). Every focus target is a ghost under a painted look, as on the lobby page. `UiStyle = "classic"`
keeps the 0.11.0 page (a header, a breadcrumb `STEP n/5`, a media area on the left, a list on the right, a footer).

1. **CLASS**: four Arcade posters (Landspeeder, Speeder Bike, Skim Speeder, Podracer) with `UP TO n RACERS` and the
   class traits, and the game's VEHICLE SELECT panel for the focused class (description and traits; the DRIFT trait
   shows the pad glyph, `UiTraitGlyph`).
2. **PLANET** (0.9.0, as in the campaign): the campaign's own **planet arc** on the campaign map. The planets sit on a
   big circle and slide so the selected one rests at the top, enlarged, with the game's scroll sound. Under it are the
   planet's name, description and `6 CIRCUITS · 17 TRACKS FOR THE LANDSPEEDER`, and beside it the planet's Arcade art
   for the class (its **arrival video** only with `SetupCMapVideoW > 0`; classic: the video). A row of **planet
   discs** under the arc is the control (classic: planet chips): left/right moves along them (the arc follows), A
   chooses. Only planets with tracks for that class are shown (Tatooine for podracers).
3. **TRACK** (0.9.0): a **run map of that planet**, as the campaign shows a planet's events (v2: one framed map, 3584 x
   1316). The big planet turns on the map background. There is **one row per circuit** (the track's name) and **one
   node per variant**, each with an icon and a label: race flag = standard, stopwatch = point to point, arrows =
   reverse, mines, skull = the scorching/hard variant, podracer = pods. The d-pad moves between nodes, and the card on
   the right shows the focused track: art, planet and class, laps, variant and conditions. A chooses; **CONDITIONS**
   follows when a track has several (v2: up to three posters, the condition as the title; the ones after the first
   tinted, `UiCondTint`). `SetupCampaignMap = false` (or `SetupCMapPlanetNav` / `SetupCMapTrackView = "list"`) gives
   the 0.8.0 lists (v2: in the settings look).
4. **MODE**: RACE (single class, **full grid**), FULL GRID RACE (the game's grid), MIXED CLASS RACE and ELIMINATOR
   (speeders only), as posters with a detail column (v2). Under the GRID rows: the grid's class icons (humans dark, AI
   light) and a sentence (`2 players and 10 AI, all in landspeeders.`). The GRID rows (left/right on the focused row;
   right from a poster reaches them, down from the last one reaches BACK):
   - **Racers** `12  (10 AI)`: the grid size, players included (RACE only; the other modes read `Set by the game`).
     Classic: the `GRID: 12 RACERS (10 AI)` row.
   - **Opponents** (0.12.0, v2 page): the AI's strength, i.e. the speeder build tier the race launches on, from the
     game's own list: `TIER 1 · MASTIFF (0%)`, `TIER 2 · DALMATIAN (11%)`, `TIER 3 · HUSKY (23%)`,
     `TIER 4 · CORGI (35%)`, `TIER 5 · SPANIEL (46%)`, `TIER 6 · WHIPPET (58%)`. TIER 1 (the default) is the zero
     base: the AI race with no abilities and no parts (PowerLevel 0); a higher tier gives the AI that tier's power and
     abilities (live: TIER 4 = PowerLevel 18 and 2 abilities per AI). Every human's own loadout from RACERS is written
     over it, empty ability and crash slots cleared. Pods have no tier: `Standard` (not focusable). Saved as
     `OpponentTier` in `settings.txt`; it applies to every RACERS launch, also the lobby's START RACE and
     `UiStyle = "classic"` (which has no Opponents row: `couch set OpponentTier 4`); the classic VEHICLES columns keep
     their own builds.
5. **RACERS** (0.10.0; v2: the step row's RACERS item; classic: crumb `STEP 5/5 RACERS`): one identical card per
   player, P1 and every joined guest, side by side, with the player's tag and the view the player will get
   (`TOP RIGHT`). 0.12.0 draws the cards as the game's Scenarios posters (`cards2.lua`; classic: `cards.lua`). Each
   player goes through **PILOT → VEHICLE → PERKS → READY** on their own, with their own pad:
   - **PILOT**: the pilot (full body), their racer style with its 3 traits and their signature vehicle
     (`SIGNATURE · <model>`); left/right moves through the class's roster of head shots. Pilots are unique per player:
     a pilot another player holds is dimmed with that player's tag and skipped.
   - **VEHICLE**: the live 3D render of the pick (v2: in a studio photo bay, `PreviewBackdrop`), the game's model name
     (in the game's language, `VehicleNameSource`) with the CHOOSE MODEL tiles (1-3 players; classic: the **MODEL**
     row), the **LIVERY** (the pilot's signature vehicle and livery preselected), DRIVEN BY and a SIGNATURE chip.
   - **PERKS**: the whole loadout on one board, **everything unlocked** for every player: the LOADOUT kit (the pilot's
     style kit, MAX POWER, TIER 1-6 and every other style kit: 27 kits; any edit makes it `CUSTOM · FROM <kit>`, and a
     custom loadout keeps naming its kit after a pilot change), 4 abilities on the d-pad slots (45 abilities in 8
     families) plus the crash ability, 6 part slots (316 parts in 12 categories, flaws and pod traits included), 6
     upgrade bars 0-10 with `POWER n / 60` and `ENERGY`, the racer style (21 styles) and 3 traits (41). Left/right
     changes the slot under the cursor (kit, ability variant, part tier, upgrade level, style, trait). A on the kit row
     goes to READY, A on an upgrade goes to the next row, A on any other slot opens a picker with categories
     (left/right = category, up/down = item, A = equip, B = cancel).
   - **READY**: the pick, a READY mark and the loadout as icons. With a pad, P1's card has **START RACE** and **SAVE
     AND RETURN**; with mouse + keyboard (v2) they move to the command row and P1's card shows a READY pill (P1's
     input type must be stable for `InputModeDebounceMs`, so START RACE is never shown twice). A guest's card reads
     `WAITING FOR P1` (classic: `READY · WAITING FOR P1`).

   Controls on every card: d-pad **up/down** = row, **left/right** = change (on the stage strip at the top: change the
   stage), **A** = next / pick, **B** = back. A guest's B: a tap = back, held 1 s or longer (`LeaveHoldMs`; about
   1.2 s in practice) = leave the game (un-join; the pad keeps its picks). **Quick path:** A, A, A from a fresh card =
   READY with the pilot's signature vehicle and style kit. **START RACE** needs every joined guest on READY (otherwise
   the first START names who is not ready, and a second START within 5 s races with their current picks). With pads
   that are connected but not joined, the first START warns (`PADS 3, 4 ARE NOT JOINED: START AGAIN FOR AI CARS`) and a
   second START within 5 s races: those pads race as AI-driven players with their own views. Picks are remembered per
   pad and per class, and the last race's picks are saved per pad in `settings.txt` (`LastRaceRacers`), so they come
   back after a restart. `SetupPlayerFlow = "classic"` brings back the 0.9.x vehicle columns: one column per player
   with a **model** and a **build** row (P1: `[<][MODEL][>]` / `[<][BUILD][>]`; guests on their own pad, **A = READY**).

Controls for P1: d-pad/stick up/down + A (CommonUI focus; the mouse works too); left/right on a value row changes the
value. **B steps back** (0.12.0, `BackPromptAsBack`): before the first race the game sends P1's pad B only to its own
QUIT GAME? prompt; the mod answers that prompt No and runs the back step instead, whatever opened it there (B, Escape,
a click on the action bar's *Exit Game*). After a race P1's own PlayerController sees B and the setup steps back by
itself. **BACK** in the command row (classic: the footer `< BACK`) and **Backspace** step back too. Back on CLASS
returns to the lobby page. Keyboard: arrows, Enter/Space, **Backspace = BACK**. With KEYBOARD IS P1, pad 1's B is a
guest's: the prompt is answered No and nothing steps back (P1 uses Backspace). On a RACERS card P1's pad works like a
guest's (an invisible focus target turns P1's d-pad and A into card moves): B goes to the card's previous stage, P1
can also step back with up (to the stage strip) and left, and at PILOT a second back within 3 s goes to MODE
(`CardP1BackConfirmMs`; BACK goes there at once). `BackPromptAsBack = false` restores 0.11.0: before the first race B
then only opens the game's prompt, and BACK / Backspace are the way back. Reopening the setup pre-selects the current
race and every pad's picks, so A through the steps replays it (RACERS: A, A, A on every card, then P1's A on START
RACE). After a race, START RACE in the lobby is a rematch with the same choices (also each player's pilot, vehicle and
loadout, and the Opponents tier).

Grid: humans count inside the grid. RACE fills it to `SetupMaxRacers` (12) / `SetupMaxRacersPlane` (8) with AI of
the chosen class (`SetupGridMode`); the mode asset is patched in memory only and restored in the menu.
The developer builder (OPTIONS > ADVANCED > **Race builder**; classic: the **ADVANCED** row; or
`SetupMode = "builder"` for the RACE card) still works as in 0.3: Vehicle, Game mode, Planet, Track, Conditions,
Build; a race picked there also gets the full grid and the per-player vehicles saved in `settings.txt`
(`LastRaceMaxRacers`, `LastRaceVehicles`).

### 3.4 Racing
**START RACE** (or Ctrl+F5) launches the chosen race with every joined player. While loading the status (v2: the
status pill; the START RACE poster reads `Launching…`) reads `LOADING…`; if the game refuses, it reads
`LAUNCH REFUSED BY THE GAME` or `LAUNCH TIMED OUT`. 0.12.0: from the accepted launch until the race world the mod
touches no front-end page (the "launch hold": the 0.12.0-dev pages crashed the game there, §1.11).
- Loading, the track intro, the grid intro and side bets are shown **full screen** (one view); the screen splits when
  the pre-race checks or the countdown start, and goes back to one view for intermission and results
  (`PresentViewMode`).
- **Pre-race checks** (the button sequence before the start): every player gets their own list in their own view and
  does it with their own pad, with pad button prompts (`IgnitionMode = "auto"`, 0.5.0). A player whose pad cannot
  reach the checks gets them completed by the mod, so nobody is stuck. `"p1game_guestauto"`: the game's own screen for
  P1, guests completed; `"complete"`: completed for everybody; `"simple"` or `IgnitionSimple = true`: the simple
  sequences for everybody.
- **Input:** each car obeys only its own player: P1 = keyboard/mouse + pad 1, P2 = pad 2, … (with KEYBOARD IS P1:
  keyboard/mouse = P1, pad 1 = P2, …). This needs the native filter (§2.2); without it only keyboard vs pads is
  separated (two pads would still share) and the log says so.
- Guests are called **Player 2..4** (tags, position list, results; `GuestNames`).
- Any player's **Start** (or **Back/View**: the player menu) opens the pause menu, full screen, owned and navigated by
  the player who pressed it: **A** on RESUME, **B** or that player's **Start** again resumes, and another player's
  Start resumes it if the menu does not react (0.7.0, `pause.lua` layers A-G, §7.2 Pause). After P1's wreck the
  players still racing can pause again (`PauseRestartCsm`). Known limit: Settings, Logbook and the confirm dialogs
  (Exit, Abandon) opened from a pause are still the game's P2-owned screens.
- **RESTART RACE** (0.11.0, `restart.lua`): in an offline race SWGRCouch launched, the pause menu gets RESTART RACE right
  under RESUME (the game's own Retry row with the game's own "Restart Race" text). A, then ACCEPT in the game's dialog
  ("Are you sure you want to retry the current race?"), and the race starts again on the same track: same grid, every
  player's pilot, vehicle and loadout applied again. Whoever paused can use it (a guest's presses go through the menu
  bridge, `MenuBridgeGuestPauseMenu`). Never offered online, in the campaign or arcade, or on a network client. B does
  not close that dialog for P1 (the game's dialog has no B shortcut): CANCEL is one D-pad press away.
- **Photo mode** (pause menu): the game puts every local player into photo mode, each pad drives its own photo camera
  in its own view; the mod's HUD, view guard and input helpers stay out of the way until it closes.
- When P1 finishes first, the results panel is held back until every local player has finished
  (`LocalResultsMode`).
- **Wrecks and finishes** (`wreck.lua`): a wrecked player is out (DNF) but the race goes on for the others. The wrecked
  player first sees their own wreck camera (4 s, `WreckCrashCamHoldMs`), then watches a moving racing car in their
  own view (`WreckView = "car"`, `WreckSpectateTarget`); a still or vanished car is replaced. 0.6.0: another local
  player's car is shown through its own chase camera, an AI car through a chase camera the mod attaches behind it
  (`WreckCarCam`; an AI pod's own camera sits inside its engine). A guest's crash (no wreck) follows the guest's own
  pod (`CrashCamGuest = "car"`: the game's crash camera can render black in the second view). The race ends when the
  last local player finishes or is wrecked; with `FinishGraceSec = 30` the others get 30 s after the first real finish,
  like online. Crash slow motion is world-wide: with `WreckSlowMo = "game"` (0.5.0 default) both views slow down for
  about 2 s on any local player's wreck; `"off"` keeps it off while the screen is split. `WreckMode = "noWreck"`: the local players never wreck (a crash only tumbles and resets);
  `"game"`: the game's own rule (race over 2 s after the first player out). Only offline races: a hosted network race
  keeps the game's network rules.
- **View guard** (`viewguard.lua`, run G): when a guest is wrecked, the game's single-player flow may point a player
  who is **still racing** (seen: P1) at the "player failed" cinematic camera (`BP_PlayerFailedCam_C`), so their half
  stops showing their own car. The mod puts that player's view back on their own car within ~0.5 s (log:
  `[viewguard] P1 is still racing but its view was BP_PlayerFailedCam_C ...`). Paused while photo mode is open.
  `ViewGuard = false` turns it off.
- **Each half is its own player's** (`uxsplit.lua`, 0.7.0): race messages (SYSTEM MALFUNCTION, PERFECT LANDING, WRONG
  WAY, OUT OF BOUNDS, takedowns, crash feed...) show only in the half of the player they are about; the race-ending
  countdown and the elimination / knock-out messages show once in every half. The last-life red, the ramjet blue and the full-screen danger effects follow each
  player in its own half (the game draws one player's over the whole screen). Every part has its own switch (§7.2
  "UX split"); they act only while a split race runs.
- After the results you are back on the FREE MODE tab: same players, same race. START RACE again = rematch. Known
  results screen of a split race: every player's A continues it; P1's A goes through menubridge's catcher button
  (V-MB-09, §1.9). The main menu and Settings after the race are P1's again (`feowner.lua`).

### 3.5 Couch campaign (0.15.0)
The game's own campaign (`CampaignSubsystem` / `CampaignRun`) played by 2-4 local players. Player guide: the README
section *Couch campaign*. The modules:
- `couch.lua`: the couch rules are **on** while the world is the campaign's (a `PaddockGameState`, or a race of an
  active run the mod did not launch) and at least one guest is joined, offline only (`CouchCampaign`). While on: guests
  are kept when the paddock opens (`menu_tab`), campaign races keep the guests' cars as players (no AI hand-off,
  split screen, every per-player system), `Campaign.SkipPrologueEvents 1` skips the tryout prologue
  (`CouchSkipPrologue`). Grid: a post-hook on `CampaignSubsystem:ChooseNextMapNode` points the last AI entries of
  `RecipeState.Racers` at the guests' PlayerStates (the campaign builds a one-human grid), after a pre-hook emptied the
  array (the stale post-race grid crashed race -> race travel). Time trials (Field / Podracer Tests) get 1 + guests
  entries and ghost cars (`CouchTimeTrials`). Shared screens: the game gives every screen to the LAST local player, so
  while a guest-owned screen is up the pad ids are swapped (`SetPlayerControllerID`) and the screen re-focused: P1's
  pad alone drives it. A banner (`CouchToastMs`) says when the rules turn on.
- `couchrun.lua`: each guest's mod-side run (`Mods/SWGRCouch/couch-run.txt`): class + racer style, a perks build from
  the starter kit, credits from the campaign payout table by finish position, a reward offer mirroring P1's native
  round, shop stock at P1's shops; written into the guest's PlayerState at every node pick (`perkapply`). The records
  belong to P1's run id (`runId`): the pre-run screens only put the old run's guests aside (`stash`), the first look
  at the run in play decides (same id = backed out, guests back; a new run = the screens' picks; another run = fresh,
  old text kept as `couch-run.bak-*.txt`). P1's run-start credits are noted per run id (`starts`): a guest starting
  the tour later gets that figure.
- `couchseat.lua`: the guests' SEATS (P2 = the first guest to join the couch run, P3, P4). Every saved guest record
  (`couch-run.txt`, its checkpoint journal, `guest-garage.txt`) is keyed by seat, never by the pad's ControllerId: a
  joining pad takes its old seat, the seat of a joined guest whose pad is disconnected (pad swap), or the lowest free
  one; leaving frees the seat and keeps its progress. PAD MEMORY (`padSeats` in `couch-run.txt`,
  `CouchSeatPadMemory`): after a relaunch a pad first takes the seat its ControllerId held last time, and a free seat
  remembered for another pad that is here is passed over (pads on other slots: join order). Files from before seats are merged once at load (one record per
  seat: the one changed in the newest checkpoint of the current run; the old files copied as `*.pre-seat-*.txt`).
- `couchpanel.lua` / `couchprerun.lua` / `couchlayout.lua`: the guests' own screen areas (2 players top / bottom, 3-4
  quadrants) at rewards and shops (`CouchPanel*`) and on the new-run VEHICLE SELECT / LOADOUT screens
  (`CouchPreRunSplit`). Guest input reaches invisible plain UMG buttons focused for the guest's user (Slate delivers it
  while the ids are swapped; PlayerInput key states do not update then).
- `garage.lua` (+ the generated catalog `custdata.lua`): each guest's car per seat and class
  (`Mods/SWGRCouch/guest-garage.txt`): his model goes on his grid entry (`couch.guestVehicle`), his livery onto his car
  in the race through `PlayerVehicleCustomisationComponent:Server_UpdateVehicleRecipe` (the game's own per-player
  recipe upload). The game's Customize screens are not reused for guests: they edit the one front-end customisation
  pawn and save into the FIRST local player's `CstSubsystem` (P1's garage). Research: `docs/dev/guest-garage.md`.
- Saves: the run is P1's real campaign save. The README tells players to copy `SaveGames` first.

## 4. Network races (listen server, direct IP, WireGuard)

### 4.1 Once per machine
1. Install the mod **and** the network `Engine.ini` (§2.4) on **every** machine: same game build, same mod version.
2. Use the same Iris setting everywhere: leave it alone at first; if client guests fail, set `IrisOff = true` in
   `config_user.lua` on **all** machines (or `-UseIrisReplication=0` in every Steam launch option).
3. WireGuard: the client must reach the host's tunnel address on **UDP 7777**. That works with a direct peer or
   through the VPS hub (`AllowedIPs` must route the peers' /32s through the hub). Allow UDP 7777 on the host's `wg`
   interface in its firewall. Test first with `ping <host wg ip>` from the client.
4. Client: put the host's tunnel address in `settings.txt` (`JoinAddress = <host address>`, `Port = 7777`) or type
   `couch connect <host address>:7777` in the console once; it is saved. (The default `JoinAddress` is a placeholder,
   §7.1.)
5. Another port: start the **host** with `-port=N` (Steam launch option) and set `Port = N` in `settings.txt` on every
   machine. The mod never appends `?port=`; the host's lobby reminds you with `HOST MUST BE STARTED WITH -port=N`.

### 4.2 Host
The steps name the 0.12.0 OPTIONS rows (§3.1); with `UiStyle = "classic"` the lobby's own rows do the same
(`NETWORK: HOST`, `START HOSTING`, the `remote` row).
1. FREE MODE tab → **OPTIONS** → Network: **HOST** → `Host on port 7777`: **START** (Ctrl+F7). The front end reloads as
   a listen server (`open L_FrontEnd?listen`). Joined guests stay and the tab reopens. The players strip's network
   line reads `HOSTING ON PORT 7777: 0 REMOTE PLAYERS`; `LISTEN FAILED` means the reload did not listen (check the
   log). Until the host listens, START RACE is locked (`Start hosting in Options`).
2. Local guests join with their pads as usual, before or after hosting starts.
3. Choose the race (the RACE card). Wait until the network line counts everyone, guests of clients included.
4. **START RACE.** The game's launch should carry every client (V-NET-13). If it does not, the mod relistens on the
   race map, waits for the clients to rejoin and restarts the race with `servertravel` so everyone gets a grid slot
   (`HostTravelFallback`). Late players without a car take AI cars.
5. After the race everyone comes back to the host's lobby; the host stays listening (`AutoRelistenInFrontEnd`).
6. **STOP** (OPTIONS > `Host on port 7777`) reloads a standalone front end; clients get a network error and fall back
   to their own menu.

### 4.3 Client
1. Join your local guests **first**: the guest set is frozen once connected (`DISCONNECT TO CHANGE PLAYERS`). Dormant
   slots are dropped on connect, so only joined players become racers.
2. **OPTIONS** → Network: **JOIN** → `Connect to <address>:7777`: **CONNECT** (Ctrl+F8). The mod joins with the
   game's own travel options (`JoinMethod`). The network line reads `CONNECTING TO …` → `CONNECTED TO …`; START RACE is
   locked (`Waiting for the host`; classic: `WAITING FOR HOST`).
3. The host starts the race; you follow. Your guests get their own views, HUDs and name tags as offline.
4. Errors show as `NETWORK ERROR: <type> <message>`. While you still want to be connected, the mod reconnects every
   3 s, up to 20 times (`AutoRejoin`). Quitting a race through the pause menu or **DISCONNECT** (OPTIONS) stops
   that.

### 4.4 Network limits to know
- The host simulates every car and renders its own views: host on the strongest PC and keep split graphics on
  PERFORMANCE.
- Server tick is the game's 30 Hz. A self-hosted race skips PlayFab entirely: no XP, progression or online profile.
- Results, HUD position and lap of a player who got a car through **takeover** follow the adopted AI racer entry.
  The name in the results may be the AI's.

## 5. Debug keys and console

UE4SS keybinds see the **keyboard only** and only while the game window has focus. UE4SS calls them on its own
event-loop thread; 0.9.x ran the key's action from there and could crash the game (crash_2026_10_08_13_27_33). Since
0.10.0 a key press is only queued (`keyq.lua`) and its action runs on the game thread at the next FAST tick (≤ 33 ms).
The lobby also binds the arrows, Enter, Space, Escape and Backspace (`LobbyNavKeyboard = "never"` turns that off;
Escape only arms the lobby's Back guard and stays the game's key; Backspace is BACK in RACE SETUP and closes OPTIONS);
while one of those keys is held (e.g. steering with the arrows), UE4SS drops the other keybinds of that moment.

| Key | Action |
|---|---|
| F5 | select the FREE MODE tab / show the lobby |
| F6 / F7 | join the next guest (with no free slot: press F6 twice within 2 s to create one without a pad, kept until the game exits) / un-join the last guest (in a race, F7 hands the guest's car to the AI; the local player is kept) |
| F8 | flip the 2P layout (saved; live in a race) |
| F9 | diagnostics dump to `UE4SS.log` (core, players, split, gfx, race, takeovers, HUD, clock, present, names, setup, input isolation incl. the native filter's counters ~0.7 s later, wreck: race timeout / timeout byte / every racer's wreck-finish-health state / each local view's camera / slow-mo / P1's spectate CSM states; 0.10.0 adds `racers`: each card's stage and picks, P1's sink counters, the perkapply status, the preview stats; 0.12.0 ends with `ui v2`: `UiStyle` and the UI v2 keys, theme's state (page geometry, input mode), the lobby page's state, the model-name read, the photo bays' backdrop) |
| Ctrl+F5 | launch the last race now (front end) |
| Ctrl+F6 | force takeover now for every PC without a car (host/offline, race only) |
| Ctrl+F7 | start / stop hosting |
| Ctrl+F8 | connect / disconnect |
| Ctrl+F9 | network dump (net mode, driver, flow, remote humans) |
| Ctrl+F11 | restart the mod (hot reload, §2.5). 0.10.0: registered only with `AllowHotReload = true` (default `false`: UE4SS's restart of a Lua state other threads still use can crash the game; restart the game instead) |

**Debug autopilot (L3, off by default):** with `DebugAiKey = true` in `Scripts/config_user.lua`, a local player's L3
(left stick click) in a race hands his own car to the game's AI and back ("P1: AI DRIVING" / "P1: YOU DRIVE"). It is
a test tool, not a player feature: releases ship with it off.

Keys used by the bundled mods are avoided: F10/Tilde open the console (ConsoleEnablerMod), plus INS, Ctrl+J/H/O/R/Y/U/I,
Ctrl+Num5-9 and F3.

Console (open with Tilde or F10; **it did not open in session B**: F9 covers every dump): `couch help` · `couch diag` ·
`couch recipe` (recipe racers with model and bot flag, which humans got a slot) · `couch input` (input isolation) ·
`couch net` · `couch tab` · `couch join` · `couch leave` · `couch layout` · `couch launch` · `couch takeover`
· `couch host` · `couch connect [addr[:port]]` · `couch disconnect` · `couch gfx <auto|performance|quality|off>` ·
`couch set <Key> <value>` (writes `settings.txt`; same guards as the lobby) · `couch reload` (only with
`AllowHotReload = true`; otherwise it answers `hot reload is off (cfg.AllowHotReload = false): restart the game`).

## 6. Logs to collect

Keep each run's files in a folder of its own (e.g. `runs/<YYYY-MM-DD-HHMM>/`) and keep them until the tests are
done. Per run:

| File | Where | Why |
|---|---|---|
| `UE4SS.log` | `Griffin/Binaries/Win64/ue4ss/UE4SS.log` | everything: boot banner, `[SWGRCouch][<module>]` lines, hook registration, Lua tracebacks |
| Proton log | `$HOME/steam-<GAMEID>.log` (`PROTON_LOG=1`) | crashes, Wine errors, input devices |
| UE4SS crash dump | `Griffin/Binaries/Win64/ue4ss/crash_*.dmp` (if any) | native crash inside a hook |
| game crash folder | `<prefix>/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/Crashes/` | engine crash context (Sentry upload is off) |
| `settings.txt`, `config_user.lua` | `ue4ss/Mods/SWGRCouch/` | the options the run used |
| user `Engine.ini`, `GameUserSettings.ini` | `…/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/` | net override active? graphics/takedown values never persisted (diff before/after) |
| frame times | MangoHud log | V-GFX-03 per preset and view count |

Useful grep: `grep -E '\[SWGRCouch\]\[(main|phase|net|launch|takeover)\]|ERROR|WARN' UE4SS.log`; split-race UX and
pause (0.7.0): `grep -E '\[SWGRCouch\]\[(uxsplit|pause|hud)\]' UE4SS.log`. Press **F9** at these points: menu,
countdown, mid-race, paused, results (0.12.0: the dump ends with the `uxsplit`, `pause`, `menubridge`, `restart`,
`subsplit`, `vpreview`, `racers` and `ui v2` sections). Run **`couch recipe`** right after a launch; launch also logs it by
itself. Press **Ctrl+F9** on both machines after every network step. RACERS step and its launch (0.10.0):
`grep -E '\[SWGRCouch\]\[(racers|cards|perkapply|vpreview|feowner)\]' UE4SS.log`. UI v2 pages, back prompt and
opponents' tier (0.12.0):
`grep -E '\[SWGRCouch\]\[(theme|lobby|setup|cmap|cards2|racers|backprompt|vehicles|vpreview|perkapply)\]|text overflow|RACER CARD ERROR' UE4SS.log`.
The boot banner is the first mod line:
`[SWGRCouch][main] SWGRCouch 0.12.0 loading: EngineTickAvailable=… ProcessEventAvailable=… GT=… UE=5.7 settings=…`, then
`[SWGRCouch][main] started: loops fast=… main=… slow=… (33/250/1000 ms), modules=46/46, phase=BOOT`. Module counts:
0.10.x 42, 0.11.0 43 (`restart`), 0.12.0 46 (`theme`, `cards2`, `backprompt`); a lower first number means a module
failed to load. 0.12.0 logs no `dbg` lines unless `Debug = true` (§7.2): set it for a bug report.

## 7. Configuration

There are two files, and neither should be edited in `Scripts/config.lua` itself:

- **`ue4ss/Mods/SWGRCouch/settings.txt`**: the user's choices. The lobby and `couch set` write it; it is created
  from the defaults on first boot. Edit it by hand only while the game is closed. Format: `Key = value`, `#` comment
  lines, unknown keys are kept.
- **`ue4ss/Mods/SWGRCouch/Scripts/config_user.lua`** (create it): developer switches and fallbacks.
  ```lua
  return { P1HudMode = "clone", ClickMode = "poll", Defaults = { Port = 7778 } }
  ```
  Top-level keys replace the defaults of `config.lua`. The type must match, and a selector must be one of its listed
  values; otherwise the key is ignored with a `WARN config_user.lua` line. `Defaults` is merged key by key. A broken
  file is logged and ignored. Apply with a restart (Ctrl+F11 only with `AllowHotReload = true`, §2.5).

### 7.1 `settings.txt` keys (defaults = `config.Defaults`)
| Key | Default | Values |
|---|---|---|
| `Layout2P` | `top-bottom` | `top-bottom` \| `side-by-side` |
| `SplitGraphics` | `performance` | `performance` \| `auto` (quality for ≤ 2 views, performance above) \| `quality` \| `off` (MY SETTINGS) |
| `TakedownCams` | `false` | takedown cut-away cameras while 2+ views |
| `NameTags` | `true` | coloured `P<n>` tags on human cars |
| `KeyboardIsP1` | `false` | keyboard alone is P1, pads shift by one |
| `NetMode` | `offline` | `offline` \| `host` \| `join` |
| `JoinAddress` | `10.8.0.1` | host address used by CONNECT (IPv4 or host name; the default is a placeholder: set your host's address) |
| `Port` | `7777` | host port; a non-7777 host must be started with `-port=<n>` |
| `LastRaceArchetype`, `LastRaceGameMode`, `LastRacePlanet`, `LastRaceTrack`, `LastRaceBuild`, `LastRaceDebugBuild`, `LastRaceCondition` | empty | written by RACE SETUP / the builder (object paths, condition tag); a path that no longer resolves clears the choice |
| `LastRaceMaxRacers` | `0` | RACE SETUP grid size, players included (`0` = the class limit) |
| `LastRaceVehicles` | empty | RACE SETUP picks: `1=PRE_Car_Orca@<build path>;2=PRE_Car_Mako@...` (classic columns; still written in the RACERS flow) |
| `LastRaceRacers` | empty | 0.10.0 RACERS picks per pad: `<ControllerId>=<pilot>@<preset>@<loadout code>;...`, e.g. `0=DA_Racer_DarkEnigma@PRE_Car_Beluga_Protagonist@v1,k:pilot,...`; written on SAVE AND RETURN / START RACE (a pad not in that race keeps its entry), restored per pad for the race's class; a loadout code that does not decode gives the pilot's style kit (logged once) |
| `OpponentTier` | `1` | 0.12.0 RACE SETUP > MODE **Opponents**: the speeder build tier a RACERS race launches on, i.e. the AI's strength: `1` = TIER 1 [0%] (the zero base, the weakest) .. `6` = TIER 6 [58%]; a value outside the game's list is clamped to it; pods ignore it |
| `PlayMode` | `quick` | 0.13.0 FREE MODE **QUICK RACE** (`quick`: every player on the difficulty's tier kit = `OpponentTier`, no traits, no PERKS step; AI pods get the same build) or **CUSTOM RACE** (`custom`: per-kart builds). The posters set it |
| `OpponentMatch` | `false` | 0.13.0 CUSTOM RACE > Opponents **MATCH THE PLAYERS** (after TIER 6): the AI get the players' average upgrade levels per slot, their most used abilities and crash ability (`perkapply.matchLoadout`) |
| `RunPick` | `4` | 0.13.0 the GALAXY RUN poster's run length (4 / 6 / 9; Right on the poster) |
| `RunLength` | `off` | 0.13.0 OPTIONS > *Galaxy run*: `off` \| `4` \| `6` \| `9`; with a number, the next FREE MODE race starts a GALAXY RUN of that many races (the run itself is in `run.txt`) |
| `CouchMysteryTeam` | `greyed` | couch-fix39 OPTIONS > PLAYERS > *Couch campaign* > **Guests' team mystery choices**: `greyed` (a guest's mystery choice with a TEAM effect - a League token, a sabotage / debuff / difficulty / Hibi's-prices favour - is greyed) \| `allowed` (he may take it: the team effect goes onto the shared run - CampaignRun.favours / the token path - counted once per encounter when P1 or another guest took the same; his credits / parts stay his). Bookend deals stay greyed for guests either way |
| `RunRepairChance` (config.lua) | `0.15` | GALAXY RUN: chance of a TEAM REPAIR reward while the hull is damaged |
| `TestBots` (config.lua) | `false` | with `TestCommands`: the game's AI drives every local car from 2.5 s after RACING (unattended tests) |
| `TestBotsCrit` (config.lua) | `resolve` | couch-fix50/55 (AUTO-129), with `TestBots`: a bot car's CRITICAL MALFUNCTION outcome. `resolve` = `Server_ResolveCriticalMalfunction` 4 s in (the game queues no fault). The other modes drive the game's own check with a B press injected per frame through Enhanced Input (`InjectInputVectorForAction(cfg.Action)`; the PC's BP event never reaches the check): `timeout` = hold, release, no press (TimedOut: a fault); `pass` = one press in the success window (Passed: a fault); `fail` = an early press (no fault, a control); `crash` = the crash handler during the check (a fault while the car carries the condition tag); `crashpre` = no press, the crash handler `TestBotsCritCrashMs` in (a fault, same tag rule). Not `resolve`: resolved anyway after `TestBotsCritGiveUpMs` (30 s). Run time: testcmd `botcrit <mode>`; `malf <p> [basic\|triggered\|both\|direct] [hits]` starts a critical malfunction on p's car (basic = BASIC `Vehicle.Condition.Malfunction` hits until the buildup fills, the game's path; direct = the component's client start, no condition tag); outcome + the component's config in test.out |
| `Gauntlet` (config.lua) | `false` | with `TestCommands`: couch-gauntlet starts at boot (test tool: each node pick of a couch run takes the next race type; `docs/dev/gauntlet.md`) |

### 7.2 `config.lua` keys
The VERIFY column names the check (§9) whose failure the switch answers.

**Boot (no-intro mode, §2.6)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `FastBoot` | `true` | master switch | V-FB-01..05 |
| `FastBootSkipTitle` | `true` | idents + PRESS A: `AdvancePreLoadIfPossible()` as soon as ready | V-FB-01 |
| `FastBootStopIdentMovies` | `true` | `Close()` the title widget's two media players first | V-FB-01 |
| `FastBootSkipPhotosensitivity` | `true` | epilepsy warning (only when `HasExperiencedBootFlow()`) | V-FB-02 |
| `FastBootPhotoBlind` | `false` | warning state up but widget not found: `ReturnToMainMenu()` anyway | V-FB-02 |
| `FastBootEpic` | `"off"` | `"off"` (profile `bUseEosLinking` + settings mirror forced false: no browser login, no SOCIAL OVERLAY modal; persisted) \| `"keep"` | V-FB-03 |
| `FastBootEosDialog` | `true` | fallback at the menu: `DisableEpicLinking()` + `RemoveMessage(EosRequirementsFail)` | V-FB-03 |
| `FastBootPollMs` / `FastBootSettleMs` | `50` / `150` | loop period (> 0) / a boot screen must be up this long | — |
| `FastBootEpicWaitMs` | `3000` | title ready but no profile object found: advance anyway after this | V-FB-03 |
| `FastBootMenuGraceMs` / `FastBootWindowMs` | `20000` / `180000` | keep watching the menu this long / give up after | — |

**Core**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `Debug` | `false` | `dbg` log lines, the debug-only hooks in `diag` (V-TKO-08) and the FAST loop timing line (V-CORE-02). 0.12.0: off by default (was `true`); set `true` in `config_user.lua` for a bug report or a test session | — |
| `SkipRaceIntro` | `false` | `true`: the race intro cinematics and movies are skipped through the game's own dev shortcut (`Race.SpeedyFlow.Intro` / `.Movies` = 1), set once per boot when the first world is up (`testcmd.lua`; logged as `SkipRaceIntro: …`) | — |
| `FastPollMs` / `MainPollMs` / `SlowPollMs` | `33` / `250` / `1000` | FAST (join, click poll, pause poll), MAIN (phase, lobby, roster, takeover, hud, nametags, net) and SLOW (pending hooks, menu ensure, net slow tick, diag) loop periods; must be > 0 | V-CORE-02 |
| `UseKslIsValid` | `true` | liveness also asks `KismetSystemLibrary:IsValid` | V-CORE-05 |
| `SubsystemLookup` | `"sbl"` | `"sbl"` (SubsystemBlueprintLibrary) \| `"findfirst"` | V-CORE-06 |
| `LoopErrorLogEveryMs` | `5000` | a failing loop logs at most one error line per period | — |
| `DiagPeriodicMs` | `0` | > 0: F9 dump at that interval | — |
| `AllowHotReload` | `false` | 0.10.0: Ctrl+F11 / `couch reload` (`RestartCurrentMod`). Off: UE4SS's `lua_close` of a Lua state other threads still use can crash the game (RE-UE4SS #1445); restart the game instead | V-CORE-11 |

**Tab / lobby / builder**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `ClickMode` | `"poll"` | `"poll"` (selectable buttons polled in FAST; pad A through CommonUI and mouse) \| `"hook"` (`WBP_Common_Btn_C:BP_OnClicked` post-hook: **does not fire in this build**) | V-CORE-07, V-LOB-03 |
| `LobbyPadNav` | `true` | poll-based P1 navigation of the lobby (d-pad/stick, left/right on value rows, A/Enter) with its own highlight; runs in every `ClickMode` | V-LOB-08 |
| `LobbyNavHighlight` | `"both"` | `"both"` (row style + CommonUI focus) \| `"style"` (never touch focus) \| `"focus"` (CommonUI focus only) | V-LOB-08 |
| `LobbyNavMarker` | `""` | classic rows: text prefix of the highlighted row (`""` = `"> "` only when the row style cannot be applied) | V-LOB-08 |
| `LobbyNavKeyboard` | `"always"` | arrows/Enter also navigate: `"always"` \| `"kbp1"` (only with KeyboardIsP1) \| `"never"` | — |
| `LobbyNavRepeatDelayMs` / `LobbyNavRepeatMs` | `400` / `140` | held up/down: first repeat / repeat period | — |
| `LobbyNavArmMs` | `250` | A ignored this long after the lobby shows | — |
| `LobbyNavDedupMs` | `350` | one row action per press (pad-nav A + click poll; the click of a row our own A/Enter already ran is dropped by press, not by time) | V-LOB-03 |
| `LobbyFocusKeepMs` | `3000` | after a page show / the menu active again: re-give P1's CommonUI focus every 200 ms for this long while nothing on the page holds it | V-TAB-07 |
| `MenuSwitcherNoTransition` | `true` | `WS_ScreenContent:SetDisableTransitionAnimation(true)`: immediate page switches, so focus lands at once | V-TAB-07 |
| `LobbyRowInvert` | `true` | classic rows use the BPs' `IsInvert` style (dark text on the light page) | V-LOB-07 |
| `TabReactivateMinMs` | `1000` | main menu inactive at least this long, then active again while our tab was open = back from another screen → return to our tab | V-TAB-14 |
| `ReturnToSplitTab` | `true` | reopen our tab after a race / relisten | V-TAB-06, V-TAB-11 |
| `RestoreGamePaneOnTabLeave` | `false` | force the game's pane back by index when leaving our tab | V-TAB-05 |
| `OurTabSyncFix` | `"clear"` | `"clear"` (un-highlight our tab after the Campaign-pane sync so one click opens it) \| `"off"` | V-TAB-13 |
| `DeactivateGamePaneOnShow` | `false` | deactivate the game pane hidden under our page (reactivated on leave) | V-TAB-12 |
| `TabDetectMode` | `"both"` | the `GetActiveTab` poll **always** runs (required: the CustomEvent hook does not fire). `"both"` / `"hook"`: the hook stays an extra the poll de-duplicates against \| `"poll"`: hook ignored | V-TAB-10 |
| `LobbyRootMode` | `"setting_list"` | `"setting_list"` (empty the `WBP_Setting_List_C` box) \| `"own"` (our own FuseVerticalBox root) | V-LOB-01 |
| `BuilderMode` | `"embedded"` | `"embedded"` (builder widget in our tab) \| `"devscreen"` (the game's dev screen `CSM_FrontEnd_QuickRaceSetup`) | V-BLD-01, V-CORE-12 |
| `BuilderDevscreenExit` | `"auto"` | dev-screen back: `"auto"` (ReturnToMainMenu, then cosmetic ChangeStateTo if needed) \| `"native"` \| `"csm"` | V-BLD-01 |
| `BuilderBackButton` | `true` | add `< BACK TO LOBBY` to the builder grid | V-BLD-03 |
| `BuilderBackRow` / `BuilderBackCol` | `3` / `0` | grid cell of that button | V-BLD-03 |
| `BuilderAdopt` | `"live"` | `"live"` (a complete valid pick becomes the race at once; Go/BACK return) \| `"go"` (only Go adopts; leaving adopts while no Go was ever detected) | V-BLD-06 |
| `BuilderGoPoll` | `true` | `Btn_Go` made selectable+toggleable; its `GetSelected` edges are polled (MAIN) | V-BLD-06 |
| `GoMode` | `"hook"` | **obsolete** (kept so old `config_user.lua` files load): Go is polled; the BndEvt hook is an optional extra | — |
| `LaunchOnGo` | `false` | Go launches at once instead of returning to the lobby | — |

**UI v2 (`theme.lua`, `lobby.lua`, `setup.lua`, `cmap.lua`, `cards2.lua`, `backprompt.lua`, `vpreview.lua`,
`vehicles.lua`, 0.12.0)**: the FREE MODE page, OPTIONS, RACE SETUP and the RACERS cards drawn with the game's own parts
(§1.11). As for every key, a `config_user.lua` change needs a game restart (§7). UI v2 changed the defaults of eight
older keys: `CardW`, `CardGap`, `CardH`, `CardRowW` (RACERS) and `SetupCMapVideoW`, `SetupCMapBackground`,
`SetupCMapMapW`, `SetupCMapMapH` (campaign views). While `UiStyle = "classic"` they read their 0.11.0 values, unless
`config_user.lua` sets them: a key set there applies in both styles.
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `UiStyle` | `"v2"` | `"v2"` \| `"classic"`: the 0.11.0 lobby rows, the setup's header / crumb / footer and the `cards.lua` cards (the player colours stay the planet tones). Read at page build: a change shows when the page is shown again | — |
| `BackPromptAsBack` | `true` | P1's pad B on OPTIONS / RACE SETUP: before the first race it reaches only the game, which opens its QUIT GAME? prompt (ACCEPT focused); `true` = the mod answers that prompt No and the page steps back (`backprompt.lua`; its two hooks exist only while one of those pages shows) \| `false` = the prompt stays (0.11.0). The posters keep the game's Exit Game either way | V-BP-01 |
| `BackPromptHide` | `true` | 0.13.0 that QUIT GAME? prompt is made invisible on its first frame and the page steps back at once (No is still clicked when the prompt is ready) \| `false` = visible until answered | V-BP-01 |
| `InputModeDebounceMs` | `500` | P1's input type (pad \| mouse + keyboard; KeyboardIsP1 counts as mouse + keyboard) must be stable this long before the command row and P1's READY card switch (> 0) | V-FIN-11 |
| `StatusPillMs` | `5000` | how long a status-pill message shows (> 0); the START gate, ALL READY and LAUNCHING stay until cleared | V-FIN-12 |
| `StatusPillPlace` | `"screen"` | `"screen"` (the game's toast place: from the screen's left edge, at the bottom) \| `"page"` (inside the page, left of the command row) | V-FIN-12 |
| `UiPageOrigin` | unset | `{x, y, w, h}` (or `{x = , y = , w = , h = }`, w and h > 0) in screen su: replaces the measured page rectangle (measured from the main menu's layout on every page show; fallback 128, 240, 3584, 1756) | V-FIN-01 |
| `UiTitleWidget` / `UiTitleBoxH` | `"game"` / `150` | page title: `"game"` (the game's `WBP_Screen_Title` in a box this high, > 0; 256 when the title is clipped) \| `"text"` (drawn by the mod) | V-FIN-03 |
| `UiHeroPill` | `"backer"` | command-row pills: `"backer"` (`WBP_CommonButtonBacker_Pill`) \| `"painted"` (the game's pill materials as images) | V-FIN-16 |
| `UiFontMaterials` | `true` | the game's print materials (`MI_UI_SDF_Font_*`) on titles and pills; `false` = plain fonts | V-PARTS-02 |
| `UiMokiWidthScale` | `1.0` | the width estimate of the display font (Moki) x this (> 0); the boxes and line breaks sized from that estimate follow it (live at 720p, small Moki text came out up to ~8% wider than the estimate) | — |
| `UiTraitGlyph` | `"decorator"` | CLASS traits: `"decorator"` (the game's trait widget draws the pad glyph) \| `"runs"` (the mod's own "Use" + X glyph on an amber disc) | V-FIN-08 |
| `UiCondTint` | `true` | the CONDITIONS posters after the first are tinted; `false` = the untinted art (the title still names the condition) | V-FIN-07 |
| `CardFigureTint` | `"mid"` | pod pilots' body on the empty poster: `"mid"` (a tint through a material instance) \| `"plain"` (an image tint #C9B98A; also taken by itself when the material fails) | V-FIN-07 |
| `CardStripe` / `CardStripeAngle` | `true` / `34` | the rotated player stripe on the poster art and its angle in degrees (positive = clockwise; `-34` if it leans the wrong way); `false` = the straight 6-su hue rule alone | V-FIN-06 |
| `PreviewBackdrop` | `"studio"` | the backdrop inside the VEHICLE photo bay's capture: `"studio"` (a back plane + a lit floor; `SetupPreviewExposure` forced to `"fixed"`) \| `"scenario"` (the `T_UI_Scenario_Bg` plane, the front end's own exposure) \| `"cutout"` (no live render: the class cut-out) | V-FIN-05 |
| `PreviewStudioGain` | `1` | the studio back plane's brightness: a number > 0 or `{r, g, b}` (each > 0) | V-FIN-05 |
| `PreviewStudioFloor` | `true` | the studio floor under the model (contact shadow); `false` drops it (frame cost) | V-FIN-14 |
| `PreviewCalibrate` | `false` | `true` = each bay reads its backdrop corner once (up to two GPU readbacks) and logs `PASS` or a `PreviewStudioGain` value to try; the test helper `vpreview.calibrate()` re-arms that read after a change (the read itself runs only with `true`). A test-session switch (0.12.0) | V-FIN-05 |
| `VehicleNameSource` | `"load"` | the game's model names (`TH_<Model>.ItemName`, in the game's language): `"load"` (resident themes at once, the others loaded one per 250 ms) \| `"find"` (resident themes only) \| `"table"` (the mod's decoded English names) | V-FIN-10 |

**Join**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `MaxLocalPlayers` | `4` | P1 + 3 guests | — |
| `JoinPollMs` | `33` | documentation of the FAST period used by the join poll | — |
| `JoinArmMs` | `300` | ignore presses this soon after a guest slot was created | — |
| `JoinWithStart` | `true` | Start also joins (besides A) | V-JOIN-06 |
| `GuestCreate` | `"join"` | couch-livefix: a pad gets its LocalPlayer only when it presses A / START (lazy join through `swgr_inputfilter.dll`'s pad watch: no dormant guest for pads that never join; falls back to `"connected"` without the pad watch) \| `"connected"` = dormant guest slots for every plugged-in pad \| `"all"` (always 3, the old behaviour) | V-JOIN-11, V-JOIN-13 |
| `GuestOptIn` | `true` | guests only after ADD PLAYERS / F6 (twice); `false` = created when the tab opens (old behaviour) | V-JOIN-01 |
| `GuestRemoval` | `"never"` | `"never"` (guests kept until the game exits). `"launch"` / `"always"` are **crash reproducers**: every RemovePlayer crashes at the next control-mapping rebuild; they are ignored (ERROR in the log) unless `GuestRemovalUnsafe = true` | V-JOIN-11, V-JOIN-12 |
| `GuestRemovalUnsafe` | `false` | `true` = really remove guests with `GuestRemoval = "launch"` / `"always"` (expect the crash) | V-JOIN-12 |
| `JoinButtons` | `"a_or_start"` | `"a_or_start"` \| `"start"` (A never joins: use when P1's A leaks to a guest) | V-JOIN-06 |
| `LeaveHoldMs` | `1000` | KeyboardIsP1: pad 1's guest leaves by holding Start. In RACE SETUP step 5 (RACERS, or the classic VEHICLES columns) every guest leaves by holding B this long (a shorter B is that guest's back / un-ready) | V-JOIN-09, V-RC-04 |
| `JoinFocusTrick` | `"none"` | `"none"` \| `"userfocus"` \| `"viewport"` \| `"gameandui"` (GameAndUI input mode on P1 while the lobby shows) when guest pads are not seen in the menu | V-JOIN-03 |
| `JoinInputModeReapplyMs` | `0` | `"gameandui"`: also re-apply every N ms | V-JOIN-03 |
| `DeviceDetectMode` | `"hook"` | `"hook"` (`OnUserInputDeviceChanged` + edge-only poll watchdog) \| `"both"` \| `"poll"` | V-JOIN-10 |
| `HotplugPadToP1` | `"front"` | a pad that connects while the game runs and belongs to no local player becomes P1's controller (Moonlight/Sunshine pads come back with every client connection). 0.12.0: **only while P1's own pad is gone** (its disconnect was seen), never with KeyboardIsP1; a second pad switched on next to a working P1 pad stays free for ADD PLAYERS. `"front"` (front end; a pad that connects mid-race is handled at the next front end) \| `"always"` (at once, mid-race too) \| `"off"`. Never with couch pads enabled (ADD PLAYERS: it joins as a guest) | V-JOIN-20 |

**Launch**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `ConditionPassMode` | `"table"` | condition as `{TagName=FName}` \| `"trackdefault"` | V-LCH-01 |
| `SelectVehicleForGuests` | `false` | `Server_SelectVehicle` for each guest before launch | V-LCH-05 |
| `GrowGridInMemory` | `false` | raise the PlayerChoice grid entry by the human deficit (restored in the menu) | V-LCH-04 |
| `LaunchTimeoutMs` | `30000` | LAUNCHING without a world change → `LAUNCH TIMED OUT` | — |
| `LaunchAcceptedTimeoutMs` | `180000` | same once the game accepted (`PrimaryFlow == QuickRace`) | V-LCH-06 |

**HUD**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `P1HudMode` | `"clone"` | P1's HUD: `"clone"` (0.4.0 default: P1 gets its own HUD in P1's view, the game's is hidden) \| `"rehost"` (the game's HUD moved into P1's view) \| `"leave"` (viewport-wide) | V-HUD-02, V-HUD-02c |
| `P1CloneInput` | `false` | `"clone"`: keep the P1 copy's own input bindings (if P1's pause stops working) | V-HUD-02d |
| `GuestHudZOrder` | `10` | `AddToPlayerScreen` z-order of guest HUDs | — |
| `HudFitInterior` | `true` | 0.9.0: the race HUD's interior (top bar, centre, engine row; 3620 units) scales down to fit the player's view instead of losing both ends of the top bar (0.11.0: by the view width, ScaleToFitX); `false` = no HUD layout work at all | V-HUD-15 |
| `HudNarrowViews` | `"fit"` | 0.11.0, **opt-in** (off by default after the review): `"readable"` = a view narrower than `HudNarrowBelow` (2P side by side, 3P bottom, 4P) gets a narrower HUD interior: a compact top bar and the engine row shrunk to fit. Measured 2026-10-10 (2P side by side, the same race restarted in each mode): the timer, LAP and POS come out the same size as with `"fit"`, so it brings nothing readable; kept as an opt-in, off by default \| `"fit"` (0.8.2: the whole HUD scaled to the view) | V-HUD-17/18/19 |
| `HudNarrowBelow` | `3000` | view width in UI units (a full 16:9 width is 3840) below which a view is narrow | V-HUD-17 |
| `HudNarrowScale` | `1.0` | HUD size in a narrow view relative to a full-width view (above 1 counts as 1), capped so the top bar keeps clear of the edges: 0.96 in a 16:9 half or quarter; 0.85 = smaller HUD, engine row less shrunk | V-HUD-17 |
| `HudNarrowTopBar` | `"compact"` | narrow views: `"compact"` (timer / LAP / POS 197 units further in, shorter brackets and shadow, P1's 1D map at 0.6) \| `"native"` (the designer bar; the HUD is then capped at view width / 2340, 0.82 in a 16:9 half) | V-HUD-17 |
| `HudNarrowHolo` | `"hide"` | the radio-chatter portrait in narrow views: `"hide"` (engine row at 0.76 in 16:9) \| `"keep"` (0.66); guest HUDs follow `UxSplitGuestHolo` first | V-HUD-17 |
| `LapPatch` | `true` | per-player lap counter in guest HUDs | V-HUD-04 |
| `MemoryLapMode` | `"collapse"` | Memory-HUD guest laps (campaign memories, `bUseMemoryHud` arcade events): `"collapse"` (default: what happens in this build anyway) \| `"hook"` (opt-in: rewritten every frame from the `UpdateCurrentLap` hook once it fires, collapsed until then) | V-HUD-04c |
| `GuestHudCollapse` | 6 widget names | members of `WBP_HUD_RaceInfo` collapsed in guest HUDs because they show P1's values (1D map, its mid section, best lap, takedown counter; 0.7.0: arcade ramjet-distance and bonus-time counters) | — |
| `GuestHudNotifications` | `"keep"` | `"keep"` \| `"remove"` duplicate notification containers | V-HUD-08 |
| `GuestMarkers` | `"keep"` | `"keep"` \| `"collapse"` markers in guest HUDs | V-HUD-09 |
| `GuestBotEngineFix` | `true` | guest boost/ramjet/throttle icons pushed from the guest's car on change (the guest HUD's car delegates are also re-pointed to the guest car) | V-HUD-10 |
| `HudFallbackAfterMs` | `4000` | game race HUD never found this long: guest HUDs made from the loaded HUD class | V-HUD-02c |
| `HudFallbackP1Clone` | `false` | in that fallback also give P1 a clone (P1's data may then show twice) | V-HUD-02c |
| `HudSearchFallback` | `true` | `FindAllOf("FuseHudWidget")` every 2 s if the UIManager lookup fails | V-HUD-01 |
| `HudVisibilityMode` | `"csm"` | guest HUDs follow pause/results CSM states \| `"always"` | V-HUD-05 |
| `LocalResultsMode` | `"hide"` | P1 finished, guests racing: `"hide"` \| `"hide_inactive"` (also deactivated) \| `"rehost"` (into P1's view) \| `"leave"` | V-HUD-13 |
| `ForceCarTags` | `false` | set `UI.UseScreenSpaceCarTags 1` before markers initialise | V-HUD-11b |
| `HudOutPlayers` | `"hide"` | a wrecked / spectating local player's HUD is hidden (a player who finished keeps it) \| `"keep"` | V-HUD-15 |

**UX split (`uxsplit.lua`, 0.7.0)**: each part acts only while a split race runs (2+ local players, PRERACE/RACING); its
native hooks exist only then and are removed at POSTRACE / when leaving the race. Every key turns one part off alone.
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `UxSplitIndexRemap` | `true` | a guest HUD's engine panel (`WBP_HUD_BotEngineInfo`) gets the GUEST's car where it asks for player 0's pawn at creation (ramjet / boost / throttle icons, critical-malfunction dimming) | V-UX-01 |
| `UxSplitMessages` | `"route"` | race messages: `"route"` (each copy only in its own player's half) \| `"all"` (attribution log only, every half keeps every copy: the game's behaviour) \| `"off"` (no messaging hook) | V-UX-02..06 |
| `UxSplitMsgHide` | `"collapse"` | how a copy in another player's half is hidden: `"collapse"` \| `"opacity"` (if a hidden copy ever stalls the queue) | V-UX-05 |
| `UxSplitRepost` | `true` | a removal the game makes for every player (`RemoveMessage` by id, crash-feed flush) is re-posted for the players that still hold the message | V-UX-04 |
| `UxSplitDanger` | `"own"` | danger visuals: `"own"` (the world-wide parts kept neutral, each player's danger in its own half) \| `"neutral"` (kept neutral, no per-player replacement) \| `"off"` (the game: one player's danger over both halves) | V-UX-07..09 |
| `UxSplitHudColours` | `true` | the last-crash colours never written world-wide; `"own"`: that player's HUD tinted red | V-UX-07 |
| `UxSplitRamjetColour` | `true` | the ramjet colour animation stopped (icons set, colour pinned); `"own"`: that player's HUD tinted blue during its ramjet | V-UX-08 |
| `UxSplitFullScreenFx` | `true` | the game's full-screen danger post-process off while split and not paused; `"own"`: last life (dark-red tint) and System Malfunction (short flash) through that player's own camera | V-UX-09 |
| `UxSplitFadeMax` | `0.2` | strength of the last-life camera tint (> 0, capped at 0.45) | V-UX-09 |
| `UxSplitGameHud` | `true` | `P1HudMode = "clone"`: the game's own hidden HUD loses its 1D map / countdown and its bindings on P1's car | V-UX-10 |
| `UxSplitGuestHolo` | `"hide"` | radio-chatter portrait (one dialogue line for everybody) in guest HUDs: `"hide"` \| `"keep"` | V-UX-12 |
| `UxSplitProbeMs` | `0` | > 0: one `[uxsplit] probe` line at this period while armed (0 = off); also the `[subsplit] probe` period. 0.12.0: off by default (was `5000`; 5000 for a test session) | V-UX-11, V-SUB-07 |

**UX split: subtitles (`subsplit.lua`, 0.8.0)**: same rules as above (hooks only while a split race runs, removed at
POSTRACE / leaving; one switch per part). The game has ONE subtitle box for the whole window; each line is moved into
the half of the player it is for.
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `UxSplitSubtitles` | `"route"` | `"route"` (each line in its player's half; a line for everybody in every half) \| `"log"` (attribution + log lines only, nothing moves) \| `"off"` (no hook at all; also the switch if the hooks cost frame time) | V-SUB-01..06 |
| `UxSplitSubDetect` | `"hook"` | how a new line is seen: `"hook"` (`UIManager:GetCurrentSubtitleConfig` post-hook, the frame it appears) \| `"poll"` (FAST poll of the box text, 1-2 frames late; the poll is always the fallback) | V-SUB-03 |
| `UxSplitSubBoth` | `"clone"` | a line for everybody: `"clone"` (the game's box in P1's half + one mod-made subtitle box per guest half) \| `"game"` (left where the game puts it) | V-SUB-06 |
| `UxSplitSubUnmatched` | `"both"` | a line no request, rule or speaker car explains: `"both"` \| `"p1"` | — |
| `UxSplitSubPosterHook` | `true` | the `GetWorldSubsystem` pre-hook (engine-wide: every Blueprint world-subsystem lookup) that names the pod asking for a line; `false`: requests have no poster (lines go by the rules, ability hits, the speaker's car, `UxSplitSubUnmatched`; 6 hooks instead of 7). Turn it off first if the probe's `wss N/s` costs frame time | V-SUB-07 |
| `UxSplitSubAbilityHook` | `true` | `VehicleNarrativeComponent:OnPlayerHitTargetWithAbility` hook: ability-hit lines go to the hitter / the hit player (`false`: the poster rule) | V-SUB-08 |
| `UxSplitSubPendingMs` | `8000` | a dialogue request can match a line up to this long after its due time (> 0; the window waits while paused) | — |
| `UxSplitSubAiRadiusUU` | `10000` | an AI pod's line goes to the nearest local human car within this distance (> 0; the Blueprint's 100 m), else P1 | — |
| `UxSplitSubSideScale` | `0.75` | box scale in half-width views (side by side, 3P bottom row, 4P grid) (> 0; above 1 counts as 1) | — |
| `UxSplitSubHalfFrac` | `"auto"` | height of the box bottom above its half's bottom, as a fraction 0..1 of the half's height; `"auto"` = the single-view look (1080p top/bottom: 225 units). Lower it if the box covers that half's bottom HUD | V-SUB-04 |

**Wrecks and race end (`wreck.lua`, 2026-10-07)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `WreckMode` | `"spectate"` | `"spectate"`: a wrecked player watches the race in their own view, the race goes on until every local human is out \| `"noWreck"`: local humans never wreck (`NoWreckMethod`) \| `"game"`: vanilla (race over 2 s after the first human finish or wreck) | V-WD-01/02/08 |
| `FinishGraceSec` | `"all"` | after a human really finishes: `"all"` = wait for every human \| a number N = the others get N s with the game's own countdown (online: 30) \| `0` = the game's 2 s. A wreck never starts a countdown | V-WD-12 |
| `NoWreckMethod` | `"build"` | `"noWreck"`: `"build"` (UseHealth off on the local humans' vehicle builds; AI still wreck) \| `"cvar"` (`Race.InfiniteHealth 1`: nobody wrecks) \| `"topup"` (health refilled before a wrecking crash; also the safety net of the others) | V-WD-08 |
| `WreckSlowMo` | `"game"` | crash slow-mo slows the whole world: `"game"` (0.5.0 default: on any local human's wreck, both views; emulated when the game's crash-cam slow-mo does not run) \| `"last"` (off while 2+ local humans race, and 3 s after a wreck) \| `"off"` while split (`CrashCamera.SlowMoEnabled 0`, a stale dilation reset to 1.0) | V-WD-14, V-WD-16 |
| `WreckSlowMoEmulate` / `WreckSlowMoWaitMs` | `true` / `350` | `"game"`: no dilation below 1 within this time of a human wreck -> `CinematicTimeDilation` 1 -> 0.1 -> 0.8 -> 1 over 2.4 s real time (stops when another writer appears, on race end, clear and photo mode); `false` = the game's own only | V-WD-16 |
| `WreckView` | `"native"` | 0.7.2 (run J): default `"native"` (the game's own spectate renders in a guest's half and follows AI racers). After the wreck camera: `"car"` (guests: the game's spectate is ended, the view follows a MOVING racing car's chase camera) \| `"carAll"` (P1 too) \| `"native"` (the game's spectate camera) | V-WD-05/07/18 |
| `WreckCarCam` | `"auto"` | 0.6.0 `chasecam.lua` (run G: an AI pod as view target put the camera inside its engine): `"auto"` (a local human's car through its own live chase camera; another car through its own camera only while the placement check reads "chase", else through a chase rig) \| `"rig"` (every watched car through the rig) \| `"car"` (0.5.1, unchecked) | V-WD-19/20 |
| `WreckCarCamMinDistUU` / `WreckCarCamBehindUU` | `300` / `150` | placement check: a camera closer than this to the watched car = "inside"; not at least this far behind it along its heading = "front" (2 bad samples of 4 -> rig) | V-WD-19 |
| `WreckRigBackUU` / `WreckRigUpUU` / `WreckRigPitch` / `WreckRigFov` | `900` / `260` / `10` / `85` | the chase rig: an engine `CameraActor` this far behind / above the watched car, looking down this many degrees, this FOV; attached to the car (moves with it every frame), re-used, destroyed when the race view is cleared | V-WD-20 |
| `WreckCrashCamHoldMs` | `4000` | the pawn's crash camera put back as the view this long after a human wreck (`0` = none; guests: see `CrashCamWreckHold`) | V-WD-18 |
| `CrashCamGuest` | `"auto"` | 0.5.1 `crashcam.lua`, a guest's crash (no wreck); 0.7.2 (run J): default `"auto"` again (the crash camera's letterbox is cleared, `CrashCamLetterboxFix`). `"car"` (0.6.0 default, run G: the guest's view follows its own pod through the tumble, emulated slow-mo; the game's crash camera rendered BLACK for P2 even with a valid shot, 3400 uu away, no fade) \| `"auto"` (the game's crash camera while it passes the checks, else the own car; cannot detect that black) \| `"keep"` (probes only) \| `"off"` | V-CC-02 |
| `CrashCamPlayers` | `"guests"` | `"guests"` \| `"all"` (P1 too) | V-CC-01 |
| `CrashCamLearn` / `CrashCamModeCheck` | `true` / `true` | a crash camera found unusable once sends that player's later crashes to the car at once / a null `InitialCameraMode` counts as "no shot" | V-CC-02 |
| `CrashCamBadMs` / `CrashCamMaxDistUU` / `CrashCamStuckMs` | `150` / `15000` / `9000` | unusable this long -> car / farther than this from the car = unusable / a crash camera still the view this long -> car | V-CC-02 |
| `CrashCamFadeClearMs` / `CrashCamBlindFade` / `CrashCamAfterMs` | `1500` / `true` / `4000` | fade guard around a crash | V-CC-04 |
| `CrashCamWreckHold` | `"proven"` | a guest's wreck-camera hold only once its crash camera was seen working (`"proven"`) \| `"never"` \| `"always"` (skip only a known-bad one) | V-CC-06 |
| `CrashSlowMoEmulate` / `CrashSlowMoCurve` | `true` / pod curve | emulated crash slow-mo when a guest's crash camera was replaced (follows `WreckSlowMo`) | V-CC-05 |
| `CrashCamProbe` | `false` | crash probe lines (+0/+0.5/+2 s, switch, end). 0.12.0: off by default (was `true`) | V-CC-01 |
| `WreckTargetStaticMs` / `WreckViewReapplyMs` / `WreckViewBlendSec` | `4000` / `1500` / `0.0` | `"car"`: still watched car replaced after / view put back at most every / blend time | V-WD-05 |
| `WreckFadeRead` | `true` | read `FadeAmount` / `bEnableFading` of the wrecked player's camera manager (custom properties); `false` = blind `StopCameraFade` only | V-WD-15 |
| `WreckCinematic` | `"end"` | wrecked while another human races: end its single-player failed-event cinematic \| `"keep"` | V-WD-06 |
| `WreckSpectateTarget` | `"ai"` | whom a wrecked player watches (0.7.1: default `"ai"`): `"human"` (the other local human, then the leader) \| `"leader"` \| `"ai"` (an AI car first) | V-WD-07 |
| `WreckSpectateWaitMs` | `800` | the game's spectate not running this long after the wreck: asked for again | V-WD-04 |
| `WreckViewGuard` | `"auto"` | `"auto"`: the wrecked view's camera is checked every 33 ms; unusable (no target, NaN/origin, too far from its car) for `WreckCamBadMs` -> fallback view \| `"force"`: always the fallback view \| `"off"` | V-WD-04/05 |
| `ViewGuard` | `true` | run G, `viewguard.lua`: a still-racing local player whose view is another player's DNF cinematic (`BP_PlayerFailedCam_C`) is put back on their own car (FAST loop, race phases, paused in photo mode) \| `false` = the game's behaviour | V-VG-01 |
| `WreckViewFallback` | `"racer"` | fallback view: `"racer"` (a racing car: AI first, then a human) \| `"own"` (the player's own wreck; a racing car once it is gone) | V-WD-05/07 |
| `WreckCamMaxDistUU` / `WreckCamBadMs` | `15000` / `400` | "too far" distance / how long unusable before the fallback (both > 0) | V-WD-05 |
| `WreckFadeClearMs` | `1500` | a fade held this long on a wrecked view is cleared (`StopCameraFade`); fade fields unreadable: blind `StopCameraFade` every 1 s from this time (`0` = never) | V-WD-15 |
| `WreckProbe` | `false` | camera probe lines at the wreck, +0.5/2/4.5/6/10/20/40 s and after photo mode (view, camStill, fade, phase, watched car, photo). 0.12.0: off by default (was `true`) | V-WD-04 |
| `SpectateWidgetMode` | `"hide"` | P1 wrecked, guests racing: the game's full-screen spectate panel `"hide"` \| `"hide_inactive"` (also deactivated) \| `"leave"` | V-WD-11 |

**Presentation (`present.lua`, 0.4.0)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `PresentFromMain` | `true` | main.lua initialises and ticks `present.lua` (`false`: hud.lua drives it) | — |
| `PresentPodiumDedupe` | `true` | 0.13.0 after a split race only one podium hologram shows (the game spawns one `BP_PodiumHolo_C` per local player at one spot) | V-PRE-POD |
| `PresentOutroP1Hud` | `true` | 0.13.0 in the post-race full-screen view only P1's race HUD shows (the guests' HUDs stacked on top showed the last player's "You came Nth") | V-PRE-OUT |
| `PresentViewMode` | `"auto"` | `"auto"`: one full-screen view for loading, intros, side bets, intermission, results; split from the pre-race checks / countdown \| `"split"`: split for the whole race (0.3) | V-PRE-01 |
| `IgnitionMode` | `"auto"` | pre-race checks (`ignition.lua`, `ignpad.lua`): `"auto"` (0.5.1: own screen + own pad per player; a guest's presses call its own PC action event, no soft pointer) \| `"perplayer"` (alias) \| `"simple"` (`"auto"` + simple sequences for all) \| `"p1game_guestauto"` (game screen for P1; guests time out) \| `"complete"` (own screens, nobody assisted) \| `"off"` (game: P1 only) | V-PRE-02/03/06/08 |
| `IgnitionSoftComplete` | `false` | `"p1game_guestauto"` / `"complete"` complete the checks through the soft-keyed map (crashed UE4SS in run F): explicit opt-in only | - |
| `IgnitionSilentPresses` / `IgnitionSilentPressesP1` | `1` / `3` | silent check starts (no screen reaction) before the mod replays a guest's / P1's presses | V-PRE-06/09 |
| `IgnitionInjectDelayMs` / `IgnitionMapReprobeMs` | `120` / `1000` | 0.6.0: a guest whose own Enhanced Input path is expected (F1) is watched like P1 (`IgnitionSilentPressesP1`), and a replay waits this long so the game's own reaction is seen first / mappings re-probed this often until the checks start | V-PRE-06 |
| `IgnitionAssistP1` / `IgnitionMapProbe` / `IgnitionFixPcComp` | `true` / `true` / `true` | P1 may be replayed after silent presses / EnhancedActionMappings probe / the PC's cached check component made the player's own before a replay | V-PRE-06/09 |
| `IgnitionPadAssist` / `IgnitionPadAssistWindowMs` | `"auto"` / `250` | a check press the game's own path did not deliver within the window is replayed (`TestPreflightCheckInput`) \| `"always"` \| `"off"` (log only) | V-PRE-06, V-PRE-09 |
| `IgnitionPadPrompts` | `"pads"` | a pad player's CommonInput type set to Gamepad during the checks \| `"off"` | V-PRE-07 |
| `IgnitionFixedKeys` | `"guests"` | the copies' prompt icons get the player's pad key: `"guests"` \| `"all"` \| `"off"` | V-PRE-07 |
| `IgnitionView` | `"split"` | `"split"` \| `"single"` (one view during the checks) | V-PRE-02 |
| `IgnitionSimple` | `false` | simple check sequences for every local player | V-PRE-05 |
| `IgnitionZOrder` / `IgnitionCopyInput` | `5` / `false` | Z order of the per-player screens / keep their pause binding (a toggle: double pause) | — |
| `GfxSingleViewCvars` | `{ "r.ScreenPercentage" }` | cvars set back to the user's value while one view shows (`false` = off) | V-GFX-07 |

**Names (`nametags.lua`, 0.4.0)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `GuestNameMode` | `"names"` | rename guests \| `"off"` | V-NAM-01 |
| `GuestNames` | `{ "Player 2", "Player 3", "Player 4" }` | names of P2..P4 | V-NAM-01 |
| `GuestPilots` | 12 RacerDef names | each guest gets the first pilot no racer uses (P1 keeps its own); `false` = off | V-NAM-03 |
| `GuestNameMethod` | `"auto"` | `"auto"` (rpc → gamemode → direct) \| `"rpc"` \| `"gamemode"` \| `"direct"` | V-NAM-01 |
| `GuestNameAdopted` | `true` | also rename an adopted AI PlayerState (takeover) | — |
| `NameTagLabel` | `"pnum"` | car tags: `"pnum"` (`P2`) \| `"name"` (`Player 2`) \| `"both"` | — |

**Input isolation (`inputfix.lua`, 0.4.0)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `InputFixMode` | `"auto"` | `"auto"` (bind + native filter, `kbsplit` when the DLL is not active) \| `"native"` \| `"kbsplit"` (Lua only: keyboard vs pads; two pads still share) \| `"bind"` \| `"off"` | V-INP-01..06 |
| `InputFixP1VehicleOverUi` | `true` | 0.9.0: while P1 races in a split race, P1's vehicle input contexts sit just above `IMC_UI` (which the game keeps at 500 for P1, so LB / R3 / d-pad were UI keys); back at once on a pause, photo mode or race end | V-INP-09 |
| `InputFixNativeScope` | `"race"` | filter enabled only in race phases \| `"always"` | V-INP-03 |
| `InputFixGuestContexts` | `"fill"` | a guest raw subsystem without a vehicle pad mapping gets one \| `"leave"` | V-INP-02 |
| `InputFixKbSplitP1` | `"kbp1"` | kbsplit removes P1's pad mappings: only with KeyboardIsP1 \| `"always"` \| `"never"` | V-INP-04 |
| `InputFixOwnLoopMs` / `InputFixDiagEveryMs` | `250` / `0` | own poll period / periodic input dump while racing | — |
| `InputFixGuestEnhanced` | `"add"` | 0.6.0 (run G F1): every guest's Enhanced Input gets P1's vehicle pad IMC (Default/Alternative, never Keyboard), re-added if the game clears it, verified by its `IA_Veh_*` count \| `"off"` (0.5.1) | V-INP-08 |
| `InputFixGuestEnhancedPriority` / `InputFixGuestEnhancedRemove` | `1` / `true` | priority when P1's cannot be read / remove the added contexts in the front end | V-INP-08 |

**Race setup (`setup.lua`, `vehicles.lua`, 0.4.0)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `SetupMode` | `"setup"` | the RACE card (classic: CHOOSE RACE) opens the RACE SETUP flow \| `"builder"` (the dev builder, as 0.3) | V-SET-01 |
| `SetupGridMode` | `"typed"` | full grid as `PlayerChoice x<humans> + <class> x<rest>` \| `"playerchoice"` \| `"off"` (asset grid: 5 racers in RACE) | V-SET-06 |
| `SetupMaxRacers` / `SetupMaxRacersPlane` | `12` / `8` | grid limits, players included (game maximum; more is untested) | V-SET-06 |
| `SetupPerPlayerBuild` | `true` | each guest races its own build: build def, power level and other scalars (`false`: P1's for all) | V-SET-10 |
| `SetupPerPlayerBuildArrays` | `false` | also copy the build's slot arrays (abilities, upgrades, affixes), validated element by element | V-SET-10 |
| `SetupInRaceOverride` | `true` | repeat each human's model in the race (`Client_SetOverrideVehicleRecipe`), during LOADING, retried until applied | V-SET-11 |
| `SetupInRaceOverridePrerace` | `false` | also on PRERACE for a human it never reached (the car exists already: may respawn it) | V-SET-11 |
| `SetupCardPortraits` | `true` | VEHICLES cards show the livery owner's portrait for pilot-livery presets | V-SET-07 |
| `SetupVideo` / `SetupVideoVolume` | `true` / `-1` | planet video (the classic media area; the campaign planet view only with `SetupCMapVideoW > 0`) / its volume (`-1` untouched) | V-SET-02 |
| `SetupVideoSettleMs` | `250` | 0.10.0: a new planet video opens once the selection is still this long (`0` = at once) | — |
| `SetupTatooine` / `SetupAskCondition` | `true` / `true` | Tatooine for podracers / ask the conditions when a track has several | — |
| `SetupTrackSet` | `"arcade"` | 0.10.0, which tracks the setup offers (the game's own lists, `notes/research/track-whitelist.md`): `"quickrace"` (Quick Race + Quick Podrace pools) \| `"arcade"` (+ the Arcade's race tracks) \| `"game"` (+ Multiplayer Tour + Podracing Tour) \| `"all"` (every TrackDef the dev filter returns: the 0.9.x lists, Prologue, debug and campaign copies included) | V-TRK-01..06 |
| `SetupTrackArcadePods` | `false` | 0.10.0: also offer the Arcade's pod tracks (The Galactic League Championship, Sebulba's Challenge); the game races them with 1-2 pods, and 8 pods on TRAK_WHP_PLANE_FWD crashed at PRERACE | V-TRK-08 |
| `SetupTrackPoolConds` | `true` | 0.10.0: offer only the conditions the game's pool gives a track (no MEMORY conditions on pods, Scorching only on the `_HARD` Jakku tracks) | — |
| `SetupTrackDedupe` | `true` | one row per track layout with display names, REVERSE / variants marked (`false`: every TrackDef, duplicates marked) | V-SET-12 |
| `SetupDebugBuilds` / `SetupAllBuilds` | `false` / `false` | also list the DEBUG tiers / every quick-race build | — |
| `SetupListMax` / `SetupListMaxH` | `16` / `520` | option rows (paged) / list height (`SetupListMaxH`: classic page only) | — |
| `SetupMediaW`/`H`, `SetupInsetW`/`H`, `SetupCardW`/`H`, `SetupLeftWeight` | `640`/`360`, `256`/`144`, `360`/`200`, `0.45` | layout sizes of the classic page (`SetupMedia*`, `SetupInset*`, `SetupLeftWeight`: unused by UI v2) and of the classic VEHICLES cards (0.8.0: a 3D card is 16:9 at `SetupCardH`, lowered to fit `SetupCardRowW`; a 2D card keeps its art's aspect) | — |

**3D vehicle cards (`vpreview.lua`, 0.8.0)**: front end only. Each VEHICLES column gets a "photo bay" in the sky above
the menu sets (a static model + a scene capture + a fill light), built after the pick settles and released when the
step is left, the setup closes or the player leaves. A failure that would hit every model turns it off for the session
(2D cards, reason logged once); a model that fails keeps its 2D card. 0.10.0: the RACERS cards use the same bays (one
per pad, keyed by ControllerId + 1; "spin" on VEHICLE, "still" bursts on the other stages) under one capture budget and
spawn gap for all bays; the new defaults below apply to the classic columns too.
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `SetupPreview3D` | `true` | live 3D render of each pick; `false` = the 0.7.1 2D cards (+ badge) | V-VP-09 |
| `SetupPreviewX` / `SetupPreviewY` / `SetupPreviewZ` | `0` / `60000` / `60000` | bay 1 origin (uu): empty sky on the far +Y side, ~44° above every main-menu camera | V-VP-05 |
| `SetupPreviewSpacing` | `20000` | uu between two bays (> 0). 0.10.0: was 5000; the fill light (radius 3 x the camera distance) reached a pod's neighbour model | V-VP-10, V-RC-17 |
| `SetupPreviewW` / `SetupPreviewH` | `960` / `540` | render target size (px, > 0); card aspect = W/H. 0.10.0: was 640 x 360; one size for 1-4 cards (tests at 720p may set 640 x 360 in `config_user.lua`) | V-VP-03 |
| `SetupPreviewRtFormat` | `6` | render target format: 6 RGBA16f (linear, right gamma); try 3 (RGBA8 sRGB), then 2 (RGBA8) if washed out or too dark | V-VP-03 |
| `SetupPreviewCaptureSource` | `2` | 2 FinalColorLDR; 7 BaseColor = unlit last resort | V-VP-03 |
| `SetupPreviewFov` | `30` | capture horizontal FOV (°, > 0) | V-VP-04 |
| `SetupPreviewCamYaw` / `SetupPreviewCamPitch` | `210` / `12` | camera azimuth (front-end sun side) / elevation (°) | V-VP-04 |
| `SetupPreviewYaw` | `245` | model start yaw (°): front three-quarter view | V-VP-04 |
| `SetupPreviewFrame` | `1.05` | framing margin (camera distance multiplier, > 0; larger = smaller model) | V-VP-04 |
| `SetupPreviewSpinDps` | `15` | turntable speed (°/s, either sign); 0 = static (captures at ready, +0.5 s, +2 s, +5 s, then every 5 s) | V-VP-06 |
| `SetupPreviewCaptureMs` | `66` | min ms between two captures of a spinning bay (>= 0; 0 = every FAST tick; ~15/s at 33-ms ticks). 0.10.0: was 50 | V-VP-06 |
| `SetupPreviewFillLux` | `60` | fill light above the camera: lux at the model (0 = none) | V-VP-04 |
| `SetupPreviewExposure` / `SetupPreviewEV` | `"inherit"` / `8` | `"inherit"` (the front end's own exposure) \| `"fixed"` (clamped to EV100 `SetupPreviewEV`). 0.12.0: forced `"fixed"` while `PreviewBackdrop = "studio"` (the default) | V-VP-04 |
| `SetupPreviewShowOnly` | `true` | capture only the bay's model (`false`: every primitive in view) | V-VP-01 |
| `SetupPreviewCaptureOnly` | `false` | the model drawn by scene captures only, no shadow (if it or its shadow shows in a menu camera) | V-VP-05 |
| `SetupPreviewBounds` / `SetupPreviewMaxRadius` | `"all"` / `6000` | bounds that frame the model: `"all"` \| `"colliding"` (the other kind when degenerate or above the radius, > 0) | V-VP-04 |
| `SetupPreviewRebuild` | `"respawn"` | a new pick: `"respawn"` (a fresh model actor) \| `"update"` (rewrite + rebuild in place, the game's garage path) | V-VP-02 |
| `SetupPreviewDebounceMs` / `SetupPreviewTimeoutMs` | `250` / `6000` | a pick is built once unchanged this long / a pick not built by then keeps its 2D card (> 0) | V-VP-01 |
| `SetupPreviewBrush` | `"material"` | column image: `"material"` (through `SetupPreviewMaterial`) \| `"texture"` (the render target itself: its alpha may be 0) | V-VP-03 |
| `SetupPreviewMaterial` / `SetupPreviewMaterialParam` | `M_UI_RetainerBox_ScreenSpace` / `"Texture"` | opaque UI material showing the render (full path in config.lua; it adds the game's diegetic-screen look). A/B: `"/VirtualCamera/WidgetLibrary/VCamTakesBrowser/Widgets/mat/M_ThumbnailMask.M_ThumbnailMask"` with `"Target"` | V-VP-03 |
| `SetupCardBadges` / `SetupCardBadgeSize` | `true` / `44` | manufacturer badge top left of every vehicle card (2D and 3D) / its size (px, > 0) | V-VP-08 |
| `SetupCardInsetH` | `72` | height (px, > 0) of the livery owner's portrait inset next to a 3D render | V-VP-08 |
| `SetupCardRowW` | `1400` | width budget (px, > 0) of the VEHICLES row: 16:9 cards get lower when n columns would not fit (4 players: 187 px) | V-VP-10 |
| `SetupPreviewCaptureBudget` | `1` | 0.10.0: `CaptureScene()` calls per FAST tick over all bays, the due bay captured longest ago first (> 0; 1 = ~30 captures/s in total, 7.5/s each with 4 spinning) | V-RC-17 |
| `SetupPreviewSpawnGapMs` | `300` | 0.10.0: a new pick is built (spawn / in-place rebuild) at most once per this many ms over all bays, the oldest waiting pick first (> 0) | V-RC-17 |
| `SetupPreviewStillBurst` | `8` | 0.10.0: captures per still (at ready, after the late parts, on a page re-show; > 0): Lumen GI, TSR and eye adaptation settle over captures | V-RC-17 |
| `SetupPreviewSpinStage` | `"vehicle"` | 0.10.0, RACERS stages whose bay spins: `"vehicle"` \| `"all"` \| `"none"` (stills everywhere) | V-RC-17 |
| `SetupPreviewPrebuildMs` | `600` | 0.10.0, RACERS PILOT stage: the pilot's signature vehicle is built (still) once the pilot pick was unchanged this long (>= 0; 0 = no prebuild) | V-RC-10 |
| `SetupCampaignMap` | `true` | 0.9.0 campaign views for PLANET and TRACK (`false`: the 0.8.0 lists; no campaign widget is built) | V-CMAP-12 |
| `SetupCMapPlanetNav` / `SetupCMapTrackView` | `"chips"` / `"map"` | `"list"` = that step's 0.8.0 list | V-CMAP-05 / 08 |
| `SetupCMapAreaW`/`H`, `SetupCMapArcScale`, `SetupCMapPlanetY` | `3500`/`1080`, `0.85`, `330` | planet view area (su, clipped), scale of the campaign's 7200-su arc, selected planet's centre below the area top | V-CMAP-06 |
| `SetupCMapArcAngle` / `SetupCMapArcPad` | `35` / `2` | the arc's spread (used as `max(value, 5.85 x planets)`) and the gap around the selected planet (deg) | V-CMAP-06 |
| `SetupCMapInfoW`, `SetupCMapVideoW`, `SetupCMapBackground` | `820`, `0`, `false` (0.12.0; classic and 0.11.0: `768`, `true`) | info block width; planet video frame width (>= 0, `0` = no video; v2 shows the planet's Arcade art for the class there and plays the video inside it when > 0); the campaign map paper behind the arc (v2: the whole map is the page background) | V-CMAP-06 / 09 |
| `SetupCMapManualTick` | `"auto"` | `"auto"`: the arc's own Tick, or our 33-ms `UpdateButtonPos` if it does not tick \| `"always"` \| `"off"` | V-CMAP-04 |
| `SetupCMapSounds` | `true` | the campaign map's UI sounds (open, planet accept) | — |
| `SetupCMapMapW`/`H`, `SetupCMapPlanetX`, `SetupCMapPlanetScale`, `SetupCMapPlanetName` | `3584`/`1316` (0.12.0; classic and 0.11.0: `3500`/`1200`), `1180`, `0.62`, `false` | run map box (the 3840x1500 map scales to fit; v2: the framed map, scale 1.0), big planet position and scale, its own 84-pt name | V-CMAP-08 |
| `SetupCMapCardW`, `SetupCMapNodeMax` | `980`, `40` | detail card width; most variants on one map (more: the list) | V-CMAP-08 |

**Race setup: RACERS step (`racers.lua`, `cards2.lua` (0.12.0 UI v2) / `cards.lua` (classic), `pilots.lua`, `perks.lua`,
`perkapply.lua`, 0.10.0)**: step 5 of RACE SETUP (§3.3), one card per pad; binding spec
`notes/design/vehicle-step-v2.md`. Sizes are Slate units (1 su = 1 px at 3840x2160). `GuestPilots`,
`SetupPerPlayerBuild*`, `SetupCard*` and `SetupInRaceOverride*` keep their meaning in the classic flow. The v2 cards
(`cards2.lua`, 0.12.0) draw their own frame and parts: `CardPad`, `CardFrame`, `CardPanelColour`, `CardHighlight`,
`CardDetail`, `CardDiamond` and `CardBackdrop` act on the classic cards only; the look keys of the v2 cards alone are
`CardFigureTint`, `CardStripe` and `CardStripeAngle` (UI v2 table above).
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `SetupPlayerFlow` | `"cards"` | `"cards"` (the RACERS cards) \| `"classic"` (the 0.9.x VEHICLES columns, unchanged; also used for one page when the cards cannot be built) | V-RC-01, V-RC-28 |
| `PilotStage` / `PerkStage` | `true` / `true` | PILOT / PERKS stage shown (`false`: the pilot defaults / the pilot's style kit are used) | — |
| `CardP1Input` | `"sink"` | P1's pad: `"sink"` (5 invisible buttons as a plus with explicit navigation rules: a move onto a neighbour = one direction, focus back on the centre) \| `"geometric"` (the plus without explicit rules) \| `"ring"` (the 5 buttons wired as a ring: the index change is the direction, no re-focus = one navigation tick per press) | V-RC-02, V-RC-30 |
| `CardP1DirGuardMs` | `50` | a P1 sink direction within this many ms of the same direction on a guest pad is dropped and logged (>= 0; 0 = off) | V-RC-07 |
| `CardGuestClickGuardMs` | `150` | P1's sink accept is dropped while a guest's A is down or had an edge within this many ms (>= 0). 0.12.0: the lobby's START RACE poster also ignores a click within this time of a guest's A | V-RC-07 |
| `CardBackTapMaxMs` | `600` | a guest's B is "back" on release when held shorter (> 0); held `LeaveHoldMs` (1 s) = leave (join.lua) | V-RC-04 |
| `CardP1BackConfirmMs` | `3000` | P1 at PILOT: a second back within this window goes to MODE (> 0) | V-RC-08 |
| `CardRowW` / `CardH` / `CardPad` | `3584` / `1300` / `32` (0.12.0; classic and 0.11.0: `3500` / `1320` / `32`) | card row width / card height / inner padding (su, > 0; `CardPad`: classic cards only). Lower `CardH` if the page is shorter than measured: the row cannot shrink against the page (v2 uses the smaller of `CardH` and the height the measured page leaves) | V-RC-15 |
| `CardW` / `CardGap` | `{ 1762, 1762, 1162, 860 }` / `{ 0, 60, 49, 48 }` (0.12.0; classic and 0.11.0: `{ 1720, 1720, 1140, 845 }` / `{ 0, 60, 40, 40 }`) | card width / gap between the cards (su) for 1, 2, 3, 4 players (4 numbers; widths >= 1, gaps >= 0) | V-RC-15 |
| `CardFrame` | `"darkpanel"` | classic cards only: `"darkpanel"` (`WBP_DarkPanel` as the card's bottom layer) \| `"solid"` (a plain image in `CardPanelColour`) | V-RC-06 |
| `CardPanelColour` | `{ R = 0.012983, G = 0.036889, B = 0.048172, A = 0.90 }` | classic cards only: panel colour (#1E363E at 0.9, the game's panel; a colour table) | V-RC-06 |
| `CardHighlight` | `"pill"` | classic cards only: `"pill"` (`WBP_ButtonBacker` pills) \| `"solid"` (solid images) | V-RC-06 |
| `CardDetail` | `"game"` | classic cards only: detail panel: `"game"` (`WBP_Character_Ability`: title + rich text) \| `"plain"` (two text blocks, markup stripped) | V-RC-06 |
| `CardThumbMask` | `"mid"` | head shots: `"mid"` (squircle material instance of `M_UI_CharacterProfilePicture`) \| `"plain"` (the transparent head shot on a squircle backer) | V-RC-06 |
| `CardDiamond` | `"disc"` | classic cards only: ability diamond: `"disc"` (the mod's discs) \| `"hud"` (`MI_HUD_Abilities_BG` behind it) | V-RC-06 |
| `CardBackdrop` | `true` | classic cards only: racer-style art behind the pilots | — |
| `CardGlyphs` | `"xbox"` | hint glyphs: `"xbox"` (the game's Xbox pad images) \| `"text"` | V-RC-01 |
| `CardSounds` | `"match"` | `"match"` (guests' navigation ticks + everybody's accept sounds) \| `"accept"` (accept sounds only) \| `"off"` | V-RC-30 |
| `CardStartPulse` | `true` | everybody READY: P1's START RACE row pulses | — |
| `CardBuildsPerTick` / `CardRendersPerTick` / `CardLoadsPerTick` | `1` / `2` / `3` | per FAST tick (> 0): card shells / stage panels / pickers built; dirty cards rendered; small textures loaded | V-RC-16 |
| `CardLoadBigBytes` | `1048576` | a texture of at least this many bytes is "big": one per FAST tick (full bodies 2.7 MB, style backdrops 4.1 MB, no mips; > 0) | V-RC-16 |
| `PilotUnique` / `PilotShareShade` | `true` / `false` | a pilot is held by one human at a time (cycling skips the others') / with `PilotUnique`, several humans may still race SHADE | V-RC-09 |
| `PilotP1Default` | `"shade"` | P1's first pilot: `"shade"` \| `"favourite"` (`PvpFlowComponent.DefaultPilot`, when valid) | V-PIL-08 |
| `PilotExtras` | `{ "DA_Racer_Mentor" }` | extra pilots (SEBULBA in the Skimmer class); `false` = none | V-RC-09 |
| `PilotPodRivals` / `PilotPodAged` | `false` / `false` | podracers: also the 11 speeder rivals / the 5 Aged pilots | — |
| `PilotSeatCheck` | `"log"` | in the race: `"log"` (`PlayerState.Pilot` compared with the pick) \| `"refresh"` (also written + `SynchronousRefreshPilot`) \| `"off"` | V-RC-23 |
| `PerkPartSlots` / `PerkTraitSlots` | `6` / `3` | part slots on the board and in the launch build (1..10) / trait slots (1..4); an override outside is clamped | V-RC-19 |
| `PerkFlaws` | `true` | FLAWS category in the part pickers | — |
| `PerkUniqueFamily` | `true` | an ability family in one slot only (a picker swap moves it) | V-RC-13 |
| `PerkApply` | `"full"` | `"full"` (the launch base build: the zero base, or since 0.12.0 the Opponents tier; affix slots raised in memory for the launch call, every field written and read back, traits at PRERACE) \| `"passives"` (parts + traits as passives at PRERACE only) \| `"off"` (the classic build) | V-RC-19, V-RC-21 |
| `PerkTraits` | `true` | traits applied as passives at PRERACE (`Server_ApplyPassive`) | V-RC-22 |
| `PerkSetRacerStyle` | `false` | also write `PlayerState.RacerStyle` (its traits might then apply twice) | — |
| `PerkVerify` | `true` | PRERACE / RACING check of each human's build and abilities | V-RC-21 |
| `PerkLateFallback` | `true` | parts lost in the travel are re-applied as passives (flaws skipped) | V-PRK-06 |
| `PerkRamjet` / `PerkCritMalfunctions` | `"keep"` / `"keep"` | speeders' ramjet / critical malfunctions: `"keep"` (the base build's) \| `"on"` \| `"off"` | — |
| `PerkPodRamjet` | `false` | podracers get the ramjet (`RamjetInstalled = true`); `false` = the game's own "Memory Pod [No Ramjet]", ramjet items hidden on pods | V-RC-32 |
| `PerkHideInert` | `true` | items for a system the car lacks (ramjet / critical malfunctions) are hidden; `false` = shown dimmed, tagged NO RAMJET / NO CRITICAL MALFUNCTIONS | V-RC-32 |
| `PerkLaunchBase` | `"zero"` | launch build of a cards race: `"zero"` (`VBD_000_1Mastiff` / `_Plane`: no abilities, no parts, PL 0) \| `"pilot"` (speeders launch on P1's style build `VBD_PvP_IA_*`, PL 26-31: the fallback before `PerkApply = "off"` when the AI scale with the launch build; pods keep the zero base). 0.12.0: an Opponents tier above TIER 1 (`OpponentTier`, §3.3) is the launch build of a speeder race instead of either | V-RC-27 |

**Pause (`pause.lua`, 0.7.0 layers A-G)**: in a split race the game makes every menu screen for the LAST local player
(P2 in 2P) and gives UI input to the FIRST one only. Layers A-G act only while a split race runs; each key turns its layer
off alone. If the first live pause crashes: `PauseHookReadState = false`, then `PauseCsmHook = false`.
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `GuestPauseMode` | `"hud"` | guest Start: `"hud"` (guest HUD's own binding) \| `"poll"` (Start polled → CSM pause) \| `"off"` | V-PAU-01, V-PAU-02 |
| `GuestHudRegisterInput` | `false` | `RegisterInputComponent()` on guest HUDs; keep `false` (A2 turns the hosted HUDs' input off and on around a pause) | V-PAU-01 |
| `P1PausePoll` | `true` | poll P1's Start/Escape while P1 has no race-HUD binding of its own (`"rehost"`, or `"leave"` with the game's HUD owned by a guest) | V-PAU-03 |
| `GuestPauseFallback` | `true` | with `"hud"`, guests' Start is polled too | V-PAU-01 |
| `PauseDeferMs` | `200` | a polled press acts only if the game did not pause by itself within this time (no double pause) | V-PAU-01, V-PAU-03 |
| `PauseHudInputGuard` | `true` | A1: the game's HUD owned by a guest who has its own HUD loses its input (two pause bindings on one player = the run-H freeze); A2: every HUD the mod hosts loses its input from the pause request until the resume and every pause key up (held Start) | V-PAU-09, V-PAU-18 |
| `PauseInputsBackMs` | `150` | A2: HUD inputs back this long after the resume, once every pause / player key is up (> 0) | V-PAU-09 |
| `PauseCsmHook` | `true` | B: one native pre-hook on `CosmeticStateMachine:ChangeStateTo`, registered only while a split race runs, removed at POSTRACE / leaving; `false`: no hook (no pre-create; A, D, F, G still run) | V-PAU-11 |
| `PauseHookReadState` | `true` | B: the hook reads the requested state; `false`: inferred from the pause state and the keys (first crash fallback) | V-PAU-11 |
| `PauseHookTrace` | `false` | B: log every `ChangeStateTo` on the pause state machine | — |
| `PauseMenuPrecreate` | `true` | C: the pause / player screen is created for the controlling player inside the hook and taken over by the game (its extra reference released); a request no pause followed is undone after 600 ms | V-PAU-11 |
| `PauseMenuOwner` | `"pauser"` | C: owner of that screen: `"pauser"` \| `"p1"` (single-player setup: the safest first test) \| `"game"` / `"keep"` (the game's own owner, no pre-create) | V-PAU-15 |
| `PauseOwnerPadShift` | `"auto"` | C, KEYBOARD IS P1: a pad pauser with ControllerId c gets a screen owned by ControllerId c-1 (CommonUI routes by the pad's own user) \| `"off"` | V-PAU-15 |
| `PauseMenuZ` | `"auto"` | C: viewport Z order of that screen: `"auto"` (the game's own menu Z once seen, else the dialog layer - 1, else `PauseMenuZOrder`) \| a number ≥ 0 | V-PAU-11 |
| `PauseUiImcBoost` | `"all"` | D: guests' UI input context raised to the game's active UI priority (500) while paused, restored on resume / leaving / front end (P1 stays with the game) \| `"owner"` (only a guest that owns the menu) \| `"off"` | V-PAU-10 |
| `PauseMenuFocusOwner` | `true` | E: the menu owner's focus put back on the menu's first button when lost (every 500 ms, at most 6 times per menu); `false`: plain `SetFocus()` | V-PAU-15 |
| `PauseLostMenu` | `"recover"` | F: `"recover"` (F1: pause state without a menu sub-state → the game's own pick, after 2 repairs resume; F2: a menu state without its screen for `PauseLostMenuMs` → resume; a screen is never re-added) \| `"probe"` (log only) \| `"off"` | V-PAU-12 |
| `PauseNoSubStateMs` / `PauseLostMenuMs` | `150` / `1500` | F1 / F2 delays above | V-PAU-12 |
| `PauseAnyStartResumes` | `"fallback"` | F3: a pause key of a player who does not own the menu (`"always"`: anyone's) counts once the menu is up 400 ms; resumed from Lua if the menu did not close 300 ms later \| `"off"` | V-PAU-13 |
| `PauseRestartCsm` | `"onpress"` | G: after P1's wreck / finish the pause state machine is gone: a pause key restarts it \| `"eager"` (as soon as it is gone) \| `"off"`; ended again at POSTRACE / leaving | V-PAU-16 |
| `PauseMenuFix` | `true` | while paused, the active pause screen and its ancestors are forced visible / opaque | V-PAU-04 |
| `PauseMenuRehost` | `"never"` | 0.7.0: `"never"` \| `"always"` (A/B tests only: the game's screen re-added once to the whole viewport; run H: a re-added screen took no input) \| `"auto"` (the 0.6 default, now = `"never"`) | V-PAU-04 |
| `PauseMenuZOrder` | `50` | Z order of an A/B rehost, and the pre-create's last-resort Z | — |
| `PauseMenuRehostDelayMs` | `50` | rehost `"always"`: done this long after the menu is first seen | V-PAU-06 |
| `PauseMenuSettle` / `PauseMenuSettleMs` | `true` / `1500` | menu parts still below their intro-animation end value (opacity 1, blur 10) this long after first sight are set to it | V-PAU-06 |
| `PauseHideHudsAtOnce` | `true` | our HUDs hidden on the pause edge itself, not on the next MAIN tick | V-PAU-06 |

**RESTART RACE (`restart.lua`, 0.11.0)**: the game's own RETRY row of the pause menu, put back right below RESUME in an
offline race SWGRCouch launched (RACING only), confirmed by the game's RetryRace dialog, then
`RacingGameMode:RequestResetRace` (the same map, seamless travel). Not `PauseRestartCsm` (G, above).
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `PauseRestart` | `true` | the RESTART RACE entry; `false` = the game's pause menu unchanged | V-RST-01 |
| `PauseRestartConfirm` | `"dialog"` | `"dialog"`: the game's Btn_RetryRace and its RetryRace dialog, ACCEPT seen by a native pre-hook on `ArcadeSubsystem:RequestRestartEvent` (registered while such a race is RACING) \| `"twice"`: an own row, confirmed by a second press within `PauseRestartConfirmMs` (no hook, no dialog) | V-RST-03/12 |
| `PauseRestartConfirmMs` | `3000` | `"twice"`: the second press must come within this time | V-RST-12 |
| `PauseRestartSequence` | `"direct"` | `"direct"`: `RequestResetRace` in the tick after the confirm, from the pause \| `"resume"`: RESUME first, the call `PauseRestartAfterResumeMs` after the pause ended | V-RST-06 |
| `PauseRestartHow` | `"relaunch"` | 0.13.0 `"relaunch"`: RESTART RACE goes to the menu (`UIBlueprintFunctionLibrary.ReturnToMainMenu`) and launches the same race again from FREE MODE (the in-place reload never respawned the AI cars) \| `"reset"`: the in-place `RequestResetRace` | V-RST-13 |
| `PauseRestartLabel` | `"game"` | `"game"`: MenuText `Pause_Button_Restart` ("Restart Race", localised) \| `"retry"`: the row's own "Retry" \| any other text: that text | V-RST-02 |
| `PauseRestartPosition` | `"below_resume"` | `"below_resume"`: the rows under RESUME move down one (a row added again comes back with focus and interaction off: the mod switches the moved rows back on, copying RESUME) \| `"end"`: appended under ABANDON TOUR | V-RST-02 |
| `PauseRestartRemote` | `false` | also offered while remote humans are connected or expected (untested: the restart travels every client) | V-RST-09 |
| `PauseRestartArcadeGuard` | `true` | `"dialog"`: an Arcade event played earlier (`ArcadeSubsystem.LastPlayedArcadeEvent`) is cleared while the entry is offered, so the game's restart never travels to that event; restored at FRONTEND. `false`: no entry while it is set | V-RST-05 |
| `PauseRestartAfterResumeMs` | `250` | `"resume"`: the call this long after the pause ended | V-RST-06 |
| `PauseRestartWatchdogMs` | `5000` | still the same world this long after `RequestResetRace`: LEAVING undone | V-RST-08 |

**Pause phase 2 and the menu bridge (`pause.lua` 0.8.0, `menubridge.lua` 0.7.1 / 0.8.0)**: every screen opened FROM a
split-race pause belongs to the pause controller (the player the pause screen was made for).
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `PauseSubScreenPrecreate` | `true` | C2: Settings, its pages and (only with `PauseSubScreenHook`) the Logbook are made for the pause controller and taken over by the game | V-PAU-19 |
| `PauseSubScreenHook` | `false` | B2: native pre-hook on `CosmeticStateMachine:ChangeToState` (the Logbook request; needs `PauseCsmHook`). **Opt-in**: its first parameter is a soft pointer (the soft-pointer rule, run F crash); `true` only for the dedicated V-PAU-20 test. `false`: the Logbook is the game's (P2's) screen and the controller drives it through the bridge | V-PAU-20 |
| `PauseDialogGuestUi` | `"lower"` | D2: guests' UI input back to default while a confirm dialog is up (the controller answers it through the bridge; its presses must not also hit its own pause screen under the dialog) \| `"keep"` | V-PAU-21 |
| `MenuBridge` / `MenuBridgeWaitMs` | `true` / `150` | 0.7.1: a guest-owned or shared post-race screen takes the player's A/B (the selected button is clicked when the game did not react within the wait) | V-MB-01/02 |
| `MenuBridgeGuestNative` | `"skip"` | a guest's presses on its OWN screen are not bridged while its UI input is raised (native input works then; bridging as well toggled a Settings row twice) \| `"bridge"` (0.7.1) (0.11.0: not on the pause menu, not for B: `MenuBridgeGuestPauseMenu`) | V-MB-04 |
| `MenuBridgeGuestPauseMenu` | `true` | 0.11.0: a guest's A / B on its OWN pause menu, and its B on the screens opened from it, are bridged even while its UI input counts as native: on the current game build a guest's native A / B stopped working after RESTART RACE (the seamless travel). A clicks the row the menu's owner has focused (the pause menu keeps RESUME selected). A guest whose press on its own pause menu needed the bridge gets its A bridged on Settings too, until the next world. `false` = 0.10 | V-MB-10 |
| `MenuBridgeDialogs` | `true` | the pause controller answers the confirm dialogs: A = focused / default button (else Accept), B = the last button (Cancel), D-pad moves the dialog's highlight; post-race any player | V-MB-05 |
| `MenuBridgeBack` | `true` | B on a bridged screen without RESUME runs the screen's own back path (`HandleBack`, else `OnCancelAction`, else `BackToPreviousState`) | V-MB-03 |
| `MenuBridgeControllerFallback` | `true` | the pause controller's A/B (+ Game+UI input) on a pause screen another player owns (a page the pre-create missed; the Logbook while `PauseSubScreenHook` is false) | V-MB-03 |
| `MenuBridgeProfileOwner` | `true` | front end after a split race: the main menu's profile card owned by a guest ("Player 2") is re-owned by P1 (name, rank, platform refreshed) | V-MB-06 |
| `MenuBridgeSharedFocus` | `true` | 0.9.0: on a results screen another player owns, P1 (kept in UI-only input by the game) gets Slate focus on the screen's own target, so P1's A clicks CONTINUE natively | V-MB-07 |
| `MenuBridgeRawA` | `false` | 0.10.0: on a shared results screen a non-owner's A is also read from its raw vehicle input. Off by default since 0.10.1: P1's raw input never shows the A there (V-MB-08 failed live 2026-10-10) | V-MB-08 |
| `MenuBridgeP1Catcher` | `true` | 0.10.1: on a shared screen another player owns (the split race's results), an invisible plain `/Script/UMG.Button` is added to that screen with P1's Slate focus; P1's A presses it (`IsPressed`) and the bridge clicks as for the other players | V-MB-09 |

**Front-end menu owner (`feowner.lua`, 0.10.0)**: after a split race the game builds the front-end screens for the last
local player (P2 drove the main menu, P1's pad did nothing); these keys make them P1's (`notes/research/menu-owner.md`).
The race results screens are not covered (menu bridge above).
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `FrontEndMenuOwner` | `"p1"` | `"p1"`: the main menu is pre-created for P1 \| `"game"` (the UIManager picks: the last guest; the kill switch) | V-FEO-01..12 |
| `FrontEndMenuPrecreate` | `true` | pre-create on `BP_Csm_FrontEnd_PickPrimaryMode` (every entry into the main menu, the arrival after a race included) | V-FEO-01/02 |
| `FrontEndSubScreens` | `true` | Settings (+ its pages), Credits, Stickerbook, the inspect screens and their returns are pre-created for P1 too | V-FEO-11/13 |
| `FrontEndHideMultiplayer` | `true` | hide and disable the Multiplayer tab while split-screen guests exist | V-FEO-07 |
| `FrontEndMenuZ` | `500` | Menu-layer z order of the pre-created menu | — |

**Phase / photo mode (`phase.lua`, 0.5.0)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `PhaseBootWarnMs` | `3000` | a live world still BOOT this long after a (hot) reload: one warning | V-CORE-14 |
| `PhotoModeCacheMs` | `200` | cache of the shared photo-mode detector `phase.photoMode()` | V-PH-01 |

**Race**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `AIOnPadDisconnect` | `true` | pad lost mid-race → the car gets the game's `Disconnect` AI override (server) | V-JOIN-05 |
| `AllowMidRaceJoin` | `false` | debugging only: F6 in a race creates a guest and takes over a car | V-TKO-09 |
| `ReRegisterP1Pawn` | `false` | re-register P1's pawn with the audio subsystems after a guest possession | V-TKO-10 |

**Graphics**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `GfxPresets` | `performance`, `quality` tables | cvar → value per preset (`sg.*`, `r.*`); a table override replaces the whole table | V-GFX-01, V-GFX-03, V-GFX-04 |
| `GfxAutoQualityMaxViews` | `2` | `auto`: quality up to this many views | — |
| `GfxApplyMode` | `"console"` | `"console"` (every cvar by console) \| `"usersettings"` (`sg.*` through GameUserSettings setters) | V-GFX-05 |

**Takeover (fallback racer assignment, server only)**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `SlotMode` | `"auto"` | `"auto"` (takeover for humans without a car after the start) \| `"off"` | V-LCH-03 |
| `TakeoverGraceMs` | `3000` | wait after the start before taking over | — |
| `TakeoverWhen` | `"started"` | `"started"` (after the race start + grace) \| `"countdown"` (earlier: once the vehicle count is stable; riskier) | — |
| `TakeoverMidGameJoiners` | `false` | also give cars to players flagged as mid-game joiners | V-TKO-09 |
| `TakeoverPick` | `"last"` | which free AI car: `"last"` (worst race position, least disruptive) \| `"first"` found | — |
| `TakeoverAdoptPS` | `true` | the human adopts the AI racer's PlayerState (HUD, laps, results follow) | V-TKO-03, V-TKO-07 |
| `TakeoverIdleAI` | `false` | escalation when the AI still steers: `RaceAIComponent:SetBehaviour(Idle)` | V-TKO-01 |
| `TakeoverBindInput` | `true` | escalation when the pad does not drive: `ResetComponent:Client_BindInputActions()` | V-TKO-01 |
| `TakeoverBindInputRemote` | `true` | remote takeovers: send `Client_BindInputActions` once | V-TKO-12 |
| `TakeoverForceRawInput` | `false` | last resort: raw write of `PlayerInputComponent.RawInputSubsystem` | V-TKO-01 |
| `TakeoverClearBotFlag` | `false` | clear `bIsABot` on the adopted PlayerState | — |
| `FinishIdlePlayerStates` | `true` | finish racer entries no car carries, so results are not blocked | V-TKO-07 |
| `FinishUncarriedRacers` | `false` | safety net once every carried racer is done (e.g. a client left mid-race) | V-TKO-07 |
| `RacerPSSource` | `"pawn"` | racer PlayerState for HUD/name tags: `"pawn"` \| `"controller"` | V-TKO-05 |
| `TakeoverAICarTest` | `"original"` | AI car test: `GetOriginalInputSource()==AI` \| `"override"` (SpawnAI override + bot PS) | V-TKO-02 |
| `TakeoverEndSpectateRemote` | `"joiner"` | `Client_OnSpectatorModeEnded` to remote takeovers: `"joiner"` \| `"always"` \| `"off"` | V-TKO-11 |

**Network**
| Key | Default | Meaning | VERIFY |
|---|---|---|---|
| `JoinMethod` | `"openlevel_opts"` | `OpenLevel(addr:port, opts = GetClientTravelOptions())` \| `"openlevel"` (no options) \| `"console"` (`open addr:port`) | V-NET-05, V-NET-06 |
| `HostTravelFallback` | `"relisten"` | launch travel did not carry the clients: `"relisten"` (race-map relisten, wait, `servertravel`) \| `"relisten_takeover"` (relisten, late players take AI cars) \| `"none"` | V-NET-07, V-NET-13, V-NET-16 |
| `ServerTravelOnMissingCars` | `false` | everyone present but a remote human has no car after start + grace → one `servertravel` | V-NET-13 |
| `AutoRelistenInFrontEnd` | `true` | host back in a standalone menu while hosting → listen again | V-NET-04 |
| `AutoRejoin` | `true` | client reconnects after a failure while it wants to be connected | V-NET-14 |
| `RejoinAfterQuitToMenu` | `false` | also rejoin after the client quit through the pause menu | V-NET-19 |
| `IrisOff` | `false` | `net.Iris.UseIrisReplication 0` at the first world (all machines alike) | V-NET-03 |
| `NetSafetyCvars` | `{}` | console lines run when hosting starts (candidate `Pvp.FakeProgressionAuthKillswitch 1`) | V-NET-12 |
| `ListenCheckMs` | `10000` | time for a reload to report listening | V-NET-15 |
| `TravelCheckDelayMs` / `RemoteArriveTimeoutMs` | `2000` / `20000` | the two host travel checks after LOADING | V-NET-13 |
| `ServerTravelWatchdogMs` | `10000` | servertravel with no world change after this = refused (retried once) | V-NET-16 |
| `RejoinWaitMs` / `RejoinSettleMs` | `60000` / `10000` | relisten: rejoin window, and the quiet time that ends it | V-NET-07 |
| `StopHostingMethod` | `"openlevel_abs"` | `OpenLevel` absolute (drops `?listen`) \| `"disconnect"` | V-NET-18 |
| `RejoinDelayMs` / `RejoinMaxTries` | `3000` / `20` | client auto-rejoin pacing | V-NET-14 |
| `GuestAckMode` | `"guests"` | answer `Client_RequestAckObjects` for local guests \| `"all"` \| `"off"` | V-NET-09 |
| `ClientMenuFallback` | `"csm"` | connected client without a main menu after 5 s: cosmetic `ChangeStateTo(PrimaryModeSelect)` \| `"off"` | V-NET-17 |
| `LoginLogEveryMs` | `5000` | host logs `IsAnyLoginPending` at this period | V-NET-11 |

**Couch campaign (`couch*.lua`, 0.15.0, §3.5)**
| Key | Default | Meaning |
|---|---|---|
| `CouchCampaign` | `true` | master switch: the campaign keeps the joined guests (own cars, split screen); `false` = the pre-0.15.0 behaviour (guests closed when the campaign starts) |
| `CouchSoloPrompt` | `true` | couch-fix70 (`solocamp.lua`): on the COUCH CAMPAIGN page, CONTINUE CAMPAIGN or an act (NEW RUN) with no joined guest opens a window instead of starting: *2 PLAYERS NEEDED*, **BACK TO MENU** (the page closes as P1's B closes it; a solo run = the game's own CAMPAIGN tab) or **ADD A SECOND PLAYER** (B too: the page stays, P2 presses A to join; a guest who joins while it is up closes it). Nothing is started from the window; `false` = the couch run starts with P1 alone (before 1.0.1) |
| `CouchSkipPrologue` | `true` | a new run skips the vehicle-tryout prologue race (`Campaign.SkipPrologueEvents 1`, set at the front end) |
| `CouchTimeTrials` | `true` | Field / Podracer Tests: 1 + guests entries, every human in P1's test vehicle, the others as ghosts; `false` = P1 alone |
| `CouchPreRunSplit` | `true` | new-run VEHICLE SELECT / LOADOUT split: each guest picks class + racer style; `false` = guests follow P1's class |
| `CouchPanel` | `true` | the guests' own reward / shop areas; `false` = guests pick no rewards and buy nothing |
| `CouchPanelNative` | `true` | reward areas built from the game's CHOOSE AN UPGRADE widgets; `false` (or any build failure) = the dark list panel |
| `CouchPanelNativeHover` | `true` | the focused guest card uses the card's own focus events; `false` = a hover look drawn by the mod |
| `CouchGarage` | `true` | each guest's GARAGE (`garage.lua`): his turn in the game's garage, offered in the paddock after P1 leaves his own (`CouchGarageOffer`); per seat and class in `Mods/SWGRCouch/guest-garage.txt` |
| `CouchMapGuestShop` | `false` | `true` = the old *(A) SHOP* hint on the run map: a guest's A opens his own shop at any time; `false` = guests shop at the shops the run visits (Hibi's shop, the scrap dealer), like P1 |
| `CouchMapGuestGarage` | `false` | `true` = the old *GARAGE* hint on the run map (the compact garage panel); `false` = the native garage turn offered in the paddock |
| `CouchGarageApply` | `"upload"` | how his livery reaches his car: `"upload"` = `Server_UpdateVehicleRecipe(his recipe)` on his PlayerState's customisation component (the game's own per-player path) \| `"tags"` = the tags on his car's recipe actor + `OnRep_VehicleRecipe()` \| `"off"` = his model only (grid entry) |
| `CouchGarageUnlocks` | `"p1"` | GARAGE options: what P1 owns (`IsOptionUnlockedAndPurchased` on P1's account) \| `"all"` |
| `CouchGarageNative` | `true` | a guest's GARAGE = a TURN in the game's own full-screen garage (3D car; Choose Model / Edit Vehicle / Edit Livery driven by his pad; model, livery and kit parts saved to his seat and class; P1's garage backed up and restored exactly); `false` = the compact panel (also the fallback when a turn cannot start) |
| `CouchGarageExclusive` | `true` | during that turn P1's pad does nothing (the guest's PC parked, P1's Slate focus on an invisible sink); `false` = P1's pad drives the guest's PC (first version) |
| `CouchGarageNoPurchase` | `true` | during that turn the options P1's profile does not own are shown locked (no purchase with P1's profile, toast *LOCKED - P1'S PROFILE*); owned options equip |
| `CouchGarageUndoForeign` | `true` | during that turn a tab change / screen back / garage close without the guest's press is put back |
| `CouchGarageHideRoot` | `true` | couch-livefix r3: after that turn the game's garage root (deactivated, still drawn over the paddock) is collapsed; its visibility comes back when the game activates it again |
| `CouchSkipReown` | `true` | couch-livefix r3: a guest- / dormant-owned skip-cinematic screen shows its prompt and ring from the mod's hold and is re-owned to P1's PC (the one in the skippable cutscene) before its own skip event; couch-skip (#33): re-owned to EVERY local PC in a skippable cutscene in turn (P1 last), so each player's own intro chain ends (the race intro is played per player and the race waits for all) |
| `CouchSkipSweep` | `true` | couch-skip (#33): within `CouchSkipChainMs` of a skip (bridged, or the game's own hold on a P1-owned screen), paddock / PRERACE only, a local PC's skippable cinematic chain not skipped yet (a guest's chain, the grid intro after the track intro) gets the game's own handler `PlayerCinematicFlowComponent:SkipCinematicChain` without waiting for a skip screen; stops at the ignition / rolling start / countdown (the ignition chain is not skippable) |
| `CouchMapPauseBridge` | `true` | couch-livefix r3: P1's START on the guest-owned paddock run map opens the game's paddock pause (the screen's own `OnPauseAction`) when the game did not |
| `CouchGarageTries` | `3` | livery uploads per guest and race at most (a car the game rebuilt gets it again) |
| `CouchToastMs` | `4000` | the *COUCH CAMPAIGN: P2 JOINS THE RUN* banner (ms; once per session and guest set, 2.5 s after the rules turn on); `0` = off |
| `CouchPanelZ` | `1000` | viewport Z of the guest areas (the banner uses +10); must stay above the post-race holder (500) |

`Defaults` holds the defaults of the `settings.txt` keys (§7.1).

## 8. Runtime test plan

The sessions run in order, and each one needs the previous one green. Keep the logs of every run (§6). When a check
fails, put the named switch in `config_user.lua`, restart the game (Ctrl+F11 only with `AllowHotReload = true`) and
repeat the check. When a check is answered, update its row in `ARCHITECTURE.md` §6 (development repository,
`docs/dev/`) before changing code.

- **Session A0**: the no-intro boot (two boots: the first with the Epic flag still on, then a normal one).
- **Session A**: one player, boot, front end, tab, builder, one offline race.
- **Session B**: two to four local players offline.
- **Session C**: the takeover fallback, forced on purpose.
- **Session D**: network: two machines on the LAN, then over WireGuard.
- **Session E** (0.4.0): the session-B feedback fixes: RACE SETUP, full grid, per-player vehicles, input isolation,
  full-screen intro, per-player pre-race checks and HUDs, guest names, wrecks and race end (V-WD-*). Run it right
  after Session B's join checks.
- **Session F** (0.5.0): the run-E fixes: P2 wreck view + slow-mo, per-player pad ignition, HUD lag after a wreck,
  photo mode, visible pause menu, inputfix bind check, hot reload mid-race, setup track list and vehicle art.
- **Run-H UX checks** (0.7.0): each half is its own player's: messages, last-life red, ramjet blue, full-screen danger
  effects, the guest engine panel and lap, the game's hidden HUD, and the hooks removed before leaving the race (§9).
- **Session R** (0.10.0, run live 2026-10-10): the RACERS step with 2-4 pads, the launch with pilots and loadouts, the
  results and the front end after a split race, persistence, pods (§9 "Session R").
- **Session U** (0.12.0, run live 2026-10-10): the UI v2 pages at 1280x720, 1920x1080 and 3840x2160 in English, German
  and French with 1-4 players, pad B on OPTIONS / RACE SETUP, the launch hold (launches in a row), the Opponents tier,
  the hot-plug rule (§9 "Session U").

UE4SS works on this Denuvo build (answered 2026-10-06). The copy is not refundable, so play time is no constraint.

## 9. Runtime test checklist

Every `VERIFY(V-…)` id in the code has a row. "Fallback" is what to set in `config_user.lua` (or elsewhere, when
stated) if the check fails. 0.10.0's new ids are listed in `notes/design/vehicle-step-v2.md` §8.1 (V-RC),
`notes/research/menu-owner.md` (V-FEO; V-FEO-13 in the `feowner.lua` header) and `notes/research/track-whitelist.md`
(V-TRK); "Session R" has the ones run live. Since 0.10.0 every row that presses Ctrl+F11 needs `AllowHotReload = true`
in `config_user.lua` (§5). 0.12.0's ids (V-FIN-01..16 from `notes/design/ui-v2/ui-redesign-final.md` §14, V-BP-01,
V-LCH-07, V-PARTS-02/08) are in "Session U"; the older rows that UI v2 changed name their 0.12.0 variant. Since
0.12.0 the `dbg` lines and the research probes are off by default: a row that reads a `dbg` line needs `Debug = true`
in `config_user.lua`, a probe row `UxSplitProbeMs = 5000` (V-UX-11, V-SUB-07), `WreckProbe = true` (V-WD-04 and the
wreck probes of Session F), `CrashCamProbe = true` (V-CC-01) or `PreviewCalibrate = true` (V-FIN-05).

### Session A0: no-intro boot (1 player)
Save `UE4SS.log` of each boot; `grep '\[fastboot\]' UE4SS.log`.
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-FB-01 | title skipped | boot | `title: title skipped: AdvancePreLoadIfPossible() after N ms ready` ~1-3 s after `BOOT -> FRONTEND`; no PRESS A screen, no brand ident video/audio after it (a short Fuse sound may play); no `IsReadyToLeavePreLoad() unusable` / `IsInitialLoadComplete() unusable` warning | `FastBootStopIdentMovies = false` if the advance misbehaves; `FastBootSkipTitle = false` |
| V-FB-02 | photosensitivity skipped | same boot | `photo: photosensitivity warning skipped: ReturnToMainMenu() (no next state)` (or `ContinueToNextState(None)`), then `menu: main menu reached X s after arming`; main menu works, FREE MODE tab added | `photo: state active but not skipped` = widget lookup failed: report it, then `FastBootPhotoBlind = true` |
| V-FB-03 | no Epic login / SOCIAL OVERLAY modal | first boot with the mod | `epic: profile bUseEosLinking true -> false (…)` and `epic: GfnUserSettings bEnableEOSAccountLinking true -> false`; no epicgames.com page; no modal. After the game saved (`GriffinSave.6.sav` mtime changes): `python3 -I -c "import sys;b=open(sys.argv[1],'rb').read();i=b.find(b'bUseEosLinking');print('absent' if i<0 else hex(b[i+40]))" <…/SaveGames/<SteamID>/GriffinSave.6.sav>` prints `0x0` or `absent` (0x10 = still on); the next boot logs `bUseEosLinking was false at first look` | modal still there: `eos: WantsEosLogin still true at the menu …` should remove it within 1 s; else ACCEPT by hand once (same end state) and report |
| V-FB-04 | P1 input without PRESS A | after the skipped title | pad 1 navigates the main menu; guests still join in the tab | `FastBootSkipTitle = false` |
| V-FB-05 | saves still work | change a setting / finish a race | `GriffinSave.6.sav` and `GameUserSettings.ini` rewritten | `FastBoot = false`, report |

### Session A: boot, core, front end (1 player)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-CORE-01 | game-thread method | boot banner | `EngineTickAvailable=true` (`GT=EngineTick`); `couch help` replies in the console, with no "not on the game thread" line | UE4SS-settings: `EngineTickResolveMethod = VTable`, then `DefaultExecuteInGameThreadMethod = ProcessEvent` (`install.sh --gt-processevent`) |
| V-CORE-02 | loop timing | `FAST loop timing over … ticks` line (5 s after boot, `Debug=true`) | avg ≈ 33 ms ± 10 | `FastPollMs = 16` or `50` |
| V-CORE-03 | settings file | first boot, change an option, restart | `Mods/SWGRCouch/settings.txt` created; edits survive; no `mod directory from relative fallback` warning | check `settings=` in the banner; `Defaults` overrides keep working without the file |
| V-CORE-04 | world / GameInstance access | F9 in the menu | GI class `BP_GfnGameInstance_C`, world `L_FrontEnd`, 1 local player | — (core: report) |
| V-CORE-05 | `KSL:IsValid` | F9 core section | boolean, no error | `UseKslIsValid = false` |
| V-CORE-06 | subsystems | F9 core section | UIManager, CSM manager, EventRecipe, PlayfabOnlineMatchmaking, ViewModel all valid | `SubsystemLookup = "findfirst"` |
| V-CORE-07 | Blueprint hooks fire | click the tab, a lobby button, builder Go | **ANSWERED 2026-10-06: NO** (they register, never fire). The poll paths are now the defaults; a `a main-menu BP hook fired` / `Go BP hook fired` line would mean they work after all (harmless) | — (poll defaults) |
| V-CORE-08 | TArray return marshalling | F9 in a race (`GetInputSourceOverrides`, `GetAllChildren`) | element lists printed | report (code: `U.arrayToTable`) |
| V-CORE-09 | NotifyOnNewObject on a `/Game` class | open the main menu | `main menu instance installed` once per menu, no CDO | SLOW `ensure` covers it (nothing to set) |
| V-CORE-10 | leave-race hooks | finish a race, return to the menu | `"leaving"` with a reason logged before the world change | MAIN poll covers it (report) |
| V-CORE-11 | hot reload | Ctrl+F11 in the lobby (2 joined), during the post-race return, mid-race (2P, split graphics on; once with `P1HudMode = "clone"`) | lobby reopens once, guests still joined, `hot reload: … restored`; mid-race one P1 HUD, no duplicate guest HUD; cvars restored in the next menu | restart the game instead of Ctrl+F11 |
| V-CORE-12 | Blueprint class load | open the tab (builder class not preloaded) | `LoadAsset(<Pkg>.<Pkg>): found=… loaded=…` once; no `U.class: … still unresolved` | automatic `_C` retry; then `BuilderMode = "devscreen"` |
| V-DIAG-01 | phase sequence | one offline race, grep `[phase]` | BOOT→FRONTEND→LAUNCHING→LOADING→PRERACE→RACING→POSTRACE→LEAVING→FRONTEND; note whether LoadMap hooks fired and whether `L_SeamlessTravel` appeared | report: `phase` rules |
| V-TAB-01 | tab appears | main menu | `FREE MODE` right of Multiplayer; the bumpers reach it | SLOW `ensure`, F5 |
| V-TAB-02 | tab button class | log | `Button Widget Type` = `WBP_Tab_Btn_C` | built-in fallback `WBP_Tab_Btn_C` |
| V-TAB-03 | label sticks | browse tabs for 2 min | label stays `FREE MODE` | re-applied by SLOW `ensure` (automatic) |
| V-TAB-04 | `CustomEvent(TabId)` | click each tab | the 5 FName ids logged; `IgnoreTabSelection` false on clicks | report |
| V-TAB-05 | leaving our tab | ours → Arcade | Arcade pane shows | `RestoreGamePaneOnTabLeave = true` |
| V-TAB-06 | programmatic select | F5 from another tab, and after a race | our tab highlighted, lobby shown | built-in direct fallback; `ReturnToSplitTab = false` |
| V-TAB-07 | pad focus | open the tab with the pad | first run: CommonUI focus did NOT reach the rows. Now: `race` row highlighted at once, up/down moves the highlight (V-LOB-08); builder: `Btn_SetVehicle` focused. 0.12.0 (v2): START RACE (a race chosen) or the RACE card holds the focus at once and the painted look follows it (V-FIN-04) | `LobbyNavHighlight = "style"`; report |
| V-TAB-08 | sync selection | race → menu, then the Campaign pane | `CustomEvent … from the switcher->tab sync` lines with `IgnoreTabSelection` true; kept guests survive until our tab is reselected | report |
| V-TAB-09 | first-tab auto-select | debug log while a menu is built | one `CustomEvent(…) during RegisterTabs (fewer than 4 tabs): ignored` per menu; `RegisterTab(…, index 4)` | report |
| V-TAB-10 | tab poll | click every tab, 10 times between FREE MODE and others | one `tab poll: active tab is now <id>` per click; lobby shows / hides accordingly | report (F5 path) |
| V-TAB-14 | return after another screen | open our tab, enter a sub-screen that covers the main menu (settings, or `BuilderMode = "devscreen"`), come back | `main menu active again after N ms while our tab was open: returning to it`, lobby shown again; a tab click never logs it | `TabReactivateMinMs` higher; `ReturnToSplitTab = false` |
| V-TAB-11 | menu rebuilt in one world | open our tab, switch tabs, enter and leave a sub-screen | at most one `main menu instance installed` per front-end world, else `main menu replaced while our tab was open` followed by the tab reopening | `ReturnToSplitTab = false` |
| V-TAB-12 | covered game pane | open our tab from Campaign; Live View: `WBP_FE_Recommended_C` `IsActivated` | `false` under our page, its action-bar prompts gone; reactivated on Campaign | `DeactivateGamePaneOnShow = true` |
| V-TAB-13 | our tab after the Campaign pane | show `WBP_FE_Campaign`, click FREE MODE once | `our tab un-highlighted after the switcher->tab sync`; one click opens the lobby | `OurTabSyncFix = "off"` (then F5) |
| V-LOB-01 | lobby root | open the tab | only our rows (the setting rows are cleared; v2: one canvas with the posters) | `LobbyRootMode = "own"` |
| V-LOB-02 | look | visual | game-styled buttons, labels stick | report |
| V-LOB-03 | clicks | each row with pad A and mouse | one action per click (`poll click '<id>'` or `nav: A on '<id>'` in the debug log, never both for one press) | `LobbyNavDedupMs` higher |
| V-LOB-07 | readable rows (classic page) | open the tab | every row dark text on the light page (not only the hovered one); highlighted row inverted (dark fill, white text) | `LobbyRowInvert = false`; report a screenshot |
| V-LOB-08 | pad navigation (classic page; v2: V-FIN-04, OPTIONS V-FIN-15) | open the tab, pad 1: d-pad up/down, left/right on LAYOUT/GFX, A on `race`, START with a race chosen; same in the builder; keyboard arrows + Enter | `focus keeper: row '…' holds P1's focus` and `focus detection: first match through …`; highlight moves, values change, A acts once (never `nav: A` + `poll click` for one press); the builder takes the pad; Escape then Enter on the lobby does not start anything | `MenuSwitcherNoTransition`, `LobbyFocusKeepMs` higher; `LobbyNavHighlight = "focus"`; report |
| V-LOB-04 | non-focusable / collapsed rows | navigate; switch NETWORK | cards skipped; network action hidden when OFFLINE (v2: the OPTIONS action row; the navigation skips it) | report (code fallback `SetVisibility(Hidden)`) |
| V-BLD-01 | embedded builder | OPTIONS > ADVANCED > Race builder (classic: the ADVANCED row; `SetupMode = "builder"`: the RACE card) | pickers filled and usable with the pad; `< BACK` and the dev screen's Back return to the lobby | `BuilderMode = "devscreen"`; its exit: `BuilderDevscreenExit = "native"` / `"csm"` |
| V-BLD-02 | choice capture | pick everything (live pick), then Go | `race adopted (live pick): …` as soon as the pick is complete, then `Go (poll): …` with the condition tag; `race` row relabelled; the track list matches the picker | `BuilderAdopt = "go"`; report |
| V-BLD-03 | back button | builder | `< BACK TO LOBBY` visible in a free cell, works | `BuilderBackRow` / `BuilderBackCol`; `BuilderBackButton = false` |
| V-BLD-04 | restore last race | restart the game | the RACE card (classic: the `race` row) shows the last race | report (clear `LastRace*` in settings.txt) |
| V-BLD-05 | dev-screen bookkeeping | `BuilderMode = "devscreen"`, Go | `external launch` with `PrimaryFlow=2` (+ `beforeLaunch` on a host) | report |
| V-BLD-06 | Go detection | pick + Go with pad A, then with the mouse | `Btn_Go armed for the Go poll` once per builder; exactly one `Go (poll):` line per press, back on the lobby | `BuilderGoPoll = false` (live pick + BACK still adopt) |
| V-LCH-01 | `LaunchCustomRace` from Lua | START RACE, 1 player | race loads with AI | `ConditionPassMode = "trackdefault"` |
| V-LCH-02 | launch accepted | log | `PrimaryFlow=2` right after the call | report |
| V-LCH-06 | accepted launch duration | START RACE (cold cache) | the world changes well inside `LaunchAcceptedTimeoutMs`; no `LAUNCH TIMED OUT` | raise `LaunchAcceptedTimeoutMs` |
| V-SPL-02 | live layout change | F8 in a 2P race (also with `GT=ProcessEvent`) | layout flips | report: restart needed |
| V-GFX-01 | cvars | F9 before/after a split race | preset values applied in the race, restored in the menu | report |
| V-GFX-04 | console cvar priority | after a split race, change graphics in the game's menu | note which settings the menu cannot change until restart | drop `r.*` entries from `GfxPresets` |
| V-GFX-05 | usersettings mode | `GfxApplyMode = "usersettings"`, split race, open the graphics menu | levels applied and restored; `GameUserSettings.ini` unchanged (diff) | keep `"console"` |
| V-GFX-06 | takedown flag never saved | `TakedownCams` off, 2P race, change an option in the pause menu; quit from the results | `takedown guard: user value … written back`; `TakedownCameras restored … (leaving)`; `GameUserSettings.ini` keeps the user value | set `TakedownCams = true` (no write at all) |

### Session B: offline, 2 to 4 local players
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-JOIN-01 | dormant guests | open the tab with pads 2..n plugged in (nothing created: `pads not enabled`), then ADD PLAYERS twice | `pads enabled (lobby ADD PLAYERS)`, one guest per plugged-in pad (`BP_GfnPlayerController_C`); menu unaffected; plugging a pad in later creates its guest within 1 s | `GuestCreate = "all"`; F6 twice |
| V-JOIN-02 | single view | open the tab, then other tabs | one full view while guests exist, on every tab | report |
| V-JOIN-11 | **no re-entry crash** | FREE MODE ↔ Arcade/Campaign tabs 10 times (~16 s apart, then fast), P2 joined once in between | no crash; `join session closed (…): k guest(s) kept` / `join session open: … (0 created now …)`; never a `RemovePlayer` line; P2 still joins; one view on the game tabs | report the log + dump; never set `GuestRemoval = "always"` except to reproduce |
| V-JOIN-13 | **lazy join** (couch-livefix) | pads 2..4 plugged, ADD PLAYERS (or the COUCH CAMPAIGN page), only pad 2 presses A | `lazy join: a pad gets its LocalPlayer only when it presses A / START`, `lazy join: pad 2 pressed A -> LocalPlayer created for ctrlId 1, joined`; no `dormant guest created`; the lobby shows *press A to join* for pads 3 / 4; a race = 2 views | `lazy join unavailable` in the log: the DLL is old / not loaded (`native filter loaded early`, status `padwatch=1`) |
| V-JOIN-12 | removal hazard (only `GuestRemoval = "launch"` + `GuestRemovalUnsafe = true`: crash reproducer) | a dormant guest, START RACE twice / start a Campaign race | expected: crash at the race load (dangling listener) | keep `"never"` |
| V-JOIN-03 | guest pad in the menu | pad 2 presses A | P2 joins | `JoinFocusTrick = "userfocus"`, `"viewport"`, then `"gameandui"` (+ `JoinInputModeReapplyMs = 500`); last resort F6 + pad confirm |
| V-JOIN-04 | pad ↔ ControllerId | pads 2..4, then `KeyboardIsP1` on | pad k → ControllerId k (k+1 with keyboard P1) | report (remap in `join`) |
| V-JOIN-05 | device events | unplug pad 2 (lobby and race) | strip cell `Controller disconnected` (classic: card `CONTROLLER DISCONNECTED`); `InternalId` logged; in a race the car goes AI and comes back | `DeviceDetectMode = "both"`; `AIOnPadDisconnect = false` |
| V-JOIN-06 | input isolation | P1 presses A in the lobby | no guest joins | `JoinButtons = "start"` |
| V-JOIN-07 | guests survive travel | after a race | P2 still joined, its new PC found | report |
| V-JOIN-09 | keyboard P1, pad 1 = P2 | `KeyboardIsP1` on: pad 1 presses Start, later holds Start 1 s | P2 joins; pad 1's A only navigates P1's menu; the hold removes P2 without a Back on P1's page | F6 / F7; `LeaveHoldMs` |
| V-JOIN-10 | device poll | `DeviceDetectMode = "both"`, unplug/replug pad 2 | one DISCONNECTED / RECONNECTED per change; with `"hook"` no `device poll: … without a device hook call` warning | `DeviceDetectMode = "poll"` |
| V-JOIN-20 | hot-plugged pad and P1 (0.8.1; 0.12.0 rule) | in the front end, switch on a second pad while P1's pad works; then disconnect P1's pad and connect a new one (e.g. a Moonlight client's DS4) | P1's pad still connected: `[join] hot-plugged pad ctrlId N: P1 keeps ctrlId M, whose pad is still connected (ADD PLAYERS makes the new pad a guest) (V-JOIN-20)` (**PASS** live 2026-10-10: ctrlId 3, P1 kept ctrlId 0); P1's pad gone: `[join] hot-plugged pad ctrlId N takes P1 (was ctrlId M; …): ok (V-JOIN-20)` and the status `NEW CONTROLLER IS PLAYER 1`; mid-race: `takes P1 at the next front end` | `HotplugPadToP1 = "off"` |
| V-LCH-03 | **native slots** | 2P race; F9 at countdown; `couch recipe` | P2 in `Racers` with a car, `FindRacerIndexByPlayer >= 0`, recipe lists 2 players | takeover runs by itself (`SlotMode = "auto"`): Session C |
| V-LCH-04 | grid math | `GMV_Race` (5) with 2 humans | count AI: 3 (humans replace) or 4 (added); record | `GrowGridInMemory = true` |
| V-LCH-05 | `Server_SelectVehicle` | `SelectVehicleForGuests = true` | no error, vehicle class as chosen | keep `false` |
| V-SPL-01 | views | 2P race | 2 views TOP/BOTTOM (or side by side); one view again in the menu | F8 / `couch layout` at countdown; report |
| V-SPL-03 | keyboard P1 routing | `KeyboardIsP1` on, race | keyboard drives P1, pad 1 drives P2 | report: needs a restart |
| V-HUD-01 | P1 HUD found | log | `GetWidgetInLayer` returns P1's HUD | `HudSearchFallback = true` (default) |
| V-HUD-02 | P1 HUD re-host | countdown → race → pause (by P2) → race → P1 presses Start | P1's HUD stays in P1's half, no duplicate; P1's Start opens the pause menu | `P1HudMode = "clone"`, then `"leave"` |
| V-HUD-02b | HUD put back | when `AddToPlayerScreen` fails (no owner) | HUD back in the UIManager layer | `P1HudMode = "leave"` |
| V-HUD-02c | HUD owner | first re-host log | owner P1 (or none, then set to P1) | report |
| V-HUD-03 | guest HUD data | race | P2's position/energy/abilities/speed are P2's | report |
| V-HUD-04 | lap patch | 3-lap race, P2 one lap behind | P2's lap text is P2's lap | `LapPatch = false` |
| V-HUD-04b | Memory HUD lap | a Memory-HUD race with P2 | the hook does not fire in this build: P2's Memory lap counter collapsed (`Memory-HUD race: guest Memory lap counters collapsed …`), never P1's lap | `LapPatch = false` |
| V-HUD-04c | Memory lap write cost | Memory-HUD race, 2 guests, 10 min | process memory growth acceptable (~10 MB for 3 guests) | `MemoryLapMode = "collapse"` |
| V-HUD-04d | Race lap write on change only | Race-HUD race with a guest | `Current Lap Number` read as integer; guest lap still right after P1's lap changes | automatic VM fallback (report) |
| V-HUD-05 | CSM queries | pause, results; 3P race where P1 finishes first | booleans; paused only with a pause page up; P2/P3 HUDs stay after P1 finished | `HudVisibilityMode = "always"` |
| V-HUD-06 | draw order | pause with a guest HUD forced visible | whether hiding is needed | report |
| V-HUD-07 | EventInfo slot | race | P2's event info panel filled | report (copy skipped on error) |
| V-HUD-08 | notifications | takedown, crash | messages once, in the right view | `GuestHudNotifications = "remove"` |
| V-HUD-09 | markers | race | P2's markers project from P2's camera | `GuestMarkers = "collapse"` |
| V-HUD-10 | boost icons | default | `P2 HUD: n binding(s) moved from P1's car`; icons follow P2's car, no errors | `GuestBotEngineFix = false` |
| V-HUD-11 | name tags | race | P2's car shows a teal `P2` in P1's view, and P1's an apricot `P1` in P2's view (0.12.0 planet tones; red `P2` before) | `NameTags = false` (settings) |
| V-HUD-11b | car-tags cvar | race log | `UI.UseScreenSpaceCarTags` value logged; tags visible | `ForceCarTags = true` |
| V-HUD-12 | member cache | race, debug log | no repeated `member cache … stale` lines | report |
| V-HUD-13 | local results | 3P race, P1 finishes first | P2/P3 views unobstructed; P1 gets the panel back (hide) or in its view (rehost); P1's A/Start does not disturb P2/P3 (`local results panel input`) | `LocalResultsMode = "hide_inactive"`, `"rehost"`, then `"leave"` |
| V-GFX-02 | takedown cameras | takedown with TAKEDOWN CAMERAS OFF | no cut-away | report |
| V-GFX-03 | frame time | 2P/3P/4P per preset (MangoHud) | record ms/frame | tune `GfxPresets` |
| V-PAU-01 | guest pause | P2 presses Start | pause menu opens once (from the HUD binding or, 200 ms later, `guest press not handled by the game within 200 ms: pausing from the poll`); a second Start closes it and it does not reopen | `GuestHudRegisterInput = true`, then `GuestPauseMode = "poll"`; `PauseDeferMs` |
| V-PAU-02 | pause by CSM call | `GuestPauseMode = "poll"` | menu opens; record who navigates it | report |
| V-PAU-03 | P1 pause after re-host | 2P, `"rehost"`: P1 Start (pad) / Escape (keyboard), then again in the menu | opens once, closes on the second press, does not reopen | `P1PausePoll = false` if it doubles; `P1HudMode = "clone"` |

### Session E: 0.4.0 feedback fixes (2 pads, offline)
| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-CORE-13 | real clock | boot | `[state] clock: real time source GetAccurateRealTime (os.clock runs at x1.xx ...)`; START-again windows last 5 real s | none (os.clock as before; WARN line names it) |
| V-SET-01 | setup page | the RACE card (classic: CHOOSE RACE) | `[setup] race setup page built (UI v2, ...)` (classic: `(classic, 16 option rows, ...)`); v2: `[setup] UI v2 frame: page 128,232 3584x1763 (layout), title on, step row on, command row, status pill on, card row on (V-FIN-01/02/03/12/16 in the theme log)`, the lobby canvas hidden; classic: header, media area, rows, the lobby rows hidden | `SetupMode="builder"` (the Race builder in OPTIONS always works) |
| V-SET-02 | planet video (classic page and lists; the campaign view: V-CMAP-09) | PLANET step, move the focus | the planet movie plays in the media area; leaving restores the menu video | `SetupVideo=false` |
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

**Wrecks (`wreck.lua`).** To force a wreck: the pause menu's "Wreck vehicle" does nothing in this build; drive into
walls until the health bar is empty (or lower `VehicleHealth` to 1 from the console). Press F9 right after each wreck.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-WD-01 | the cause | `WreckMode="game"`, P2 wrecks | F9 `timeout: T=... remaining=~2` and `byte=n/a`; race over ~2 s later | — |
| V-WD-02 | race goes on | default, P2 wrecks, then P1 finishes | `[wreck] race timeout disarmed (human wreck; 1 human(s) still racing ...)`; the race ends when P1 crosses the line; results: P2 DNF | `race timeout parked at 1e9` + no "Remaining" line on the HUDs |
| V-WD-03 | timeout byte | first wreck/finish of the session | `timeout byte registered as SWGRCouchTimeoutArmed (mRaceState+8)` then `timeout byte verified`; after Ctrl+F11 mid-race the same, no error | the log says `not trusted` and the parked-time fallback runs (still passes V-WD-02) |
| V-WD-04 | wrecked camera probe | `WreckProbe = true` (0.12.0: off by default); P2 wrecks (then P1 in another race) | `probe P2 wreck/+0.5s/+2.0s/+6.0s: view=... cam=(...) spectating=... target=...`; tells which camera P2 really had (crash cam, `BP_SpectatorCameraActor_C`, cinematic) | report the probe lines |
| V-WD-05 | wrecked view never black | P2 wrecks while P1 races | P2's half shows a racing car within ~1 s (native spectate, or `P2 view fallback (...) -> ...`) | `WreckViewGuard="force"`, `WreckViewFallback="own"` |
| V-WD-06 | failed cinematic | P1 wrecks while P2 races | `P1 failed-event cinematic ended`; nothing hidden / no camera cut in P2's half | `WreckCinematic="keep"` to compare |
| V-WD-07 | watching the other human | P2 wrecks | `P2 spectates Player 1 (preferred target, ok)`; no jitter in either half | `WreckSpectateTarget="ai"` |
| V-WD-08 | no wrecks | `WreckMode="noWreck"`, crash at low health | `P1: no wrecks (UseHealth false on ...)`; the car tumbles and resets, never wrecks | `NoWreckMethod="cvar"`, then `"topup"` |
| V-WD-11 | P1 out, guest racing | P1 wrecks while P2 races | `[hud] spectate panel shown while guests race: hide`; then `local results panel shown ...`; P2's half stays clear; `[present]` stays SPLIT | `SpectateWidgetMode="hide_inactive"`; `LocalResultsMode="rehost"` |
| V-WD-12 | online-style grace | `FinishGraceSec=30`, P1 finishes first | `a human finished: the others get 30 s`; the HUD countdown shows; race ends at 30 s or when P2 finishes | `FinishGraceSec="all"` |
| V-WD-14 | no shared slow-mo | `WreckSlowMo="off"` (0.5.0 default is `"game"`, V-WD-16), P2 wrecks | `CrashCamera.SlowMoEnabled 0 (slow-mo off while the race is split ...)`; P1's half never slows down | — |

### Session F: 0.5.0 run-E fixes (2 pads, offline, podrace)
Same setup as run E (P1 = virtual pad, P2 = DS4 via Sunshine). Keep `UE4SS.log` of the whole session; press F9 at the
countdown, right after P2's wreck, and in photo mode.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-CORE-14 | phase after hot reload | Ctrl+F11 mid-race | `[phase] phase detected from the live world after (re)load: RACING` within ~0.3 s; no "phase still BOOT" warning | report the warning line |
| V-SET-12 | track list | RACE SETUP, Tatooine | "MOS ESPA SPEEDWAY" and "MOS ESPA SPEEDWAY · REVERSE" once each, display names only | `SetupTrackDedupe=false` |
| V-SET-13 | vehicle art | VEHICLES step (podracer) | a podracer render in every column | report |
| V-INP-01 | bind check | countdown | `[inputfix] every local car reads its own raw input: native filter + contexts on`; no "write did not stick" / "not bound to its own raw input" | `InputFixMode="bind"` + report |
| V-PRE-08 | ignition probe | ignition phase | one `[ignition] P<n> probe: comp=.. pcBP=.. ctx={..}` line per player | — |
| V-PRE-06 | P2's pad does P2's checks | P2 presses its D-pad / A / B as the list asks | `[ignpad] P2 ... game path: not delivered` then `assist #1`; P2's list advances; F9 `assisted=n` | `IgnitionMode="p1game_guestauto"`, then `"complete"` |
| V-PRE-09 | no double input for P1 | P1 does its checks | `[ignpad] P1 IA_Veh_...: the game's own input path delivered it (no assist needed)`; each press advances once | `IgnitionPadAssist="off"` |
| V-PRE-07 | pad prompts | ignition phase | `[ignpad] P1 prompts: CommonInput type 0 -> Gamepad`; both lists show pad icons; `P2 prompts: n input icon(s) set to pad keys` | `IgnitionFixedKeys="off"` if the icons look wrong |
| V-WD-18 | P2 wreck camera | P2 wrecks while P1 races | `P2 wreck view: was BP_SpectatorCameraActor_C, the game's spectate ended; wreck camera ... for 4000 ms, then ...`; probe +2.0s `phase=crash view=BP_CrashCameraActor_C`; P2 sees its tumbling car | `WreckView="native"` |
| V-WD-05/07 | P2 view never black | same, after 4 s | `P2 view -> <name>'s car, ... moving`; probes from +4.5s `phase=car car=<name>(moving)`, camStill < 1 s; P2 never watches P1's parked car | `WreckSpectateTarget="ai"`; `WreckView="native"` |
| V-WD-15 | camera fades | same | `camera fade fields registered`; probes `fade=off:<n>` (not `n/a`/`untrusted`); a held fade gives `StopCameraFade -> off:...` + `camera fade fields verified` | `WreckFadeRead=false` (blind clear) |
| V-WD-16 | slow-mo on P2's wreck | same | both halves slow down ~2 s; `the game's own slow-mo runs` or `no slow-mo from the game ... emulated` then `emulated wreck slow-mo done`; +4.5s probe `dilation=1.0` | `WreckSlowMoEmulate=false`; `WreckSlowMo="off"` |
| V-HUD-14/15 | no HUD thrash after the wreck | same, watch the log | `P2 HUD hidden: out of the race (wrecked)` once; NO repeating `HUD instance changed` lines; no lag | `HudOutPlayers="keep"` + report the log tail |
| V-PAU-04/05 | SUPERSEDED by V-PAU-11/15 (0.7.0: no rehost unless `PauseMenuRehost="always"`) | P2 presses Start in the split race | 0.5/0.6 only: `pause menu re-added to the whole viewport: owner ... -> P2`. In 0.7.0 this line must NOT appear; see "Run-H pause checks" | — |
| V-PAU-07 | SUPERSEDED by V-PAU-15 (0.7.0 focus without a rehost) | P2 presses Start | 0.6 only: `pause menu re-added ... focus P2 -> <button>`; 0.7.0: probe `focus=P2` and `focus: P2 ... had no focus in the menu -> ...` at most | — |
| V-PAU-08 | SUPERSEDED by V-PAU-12 (0.7.0 safety net F: repair / resume, never a re-add) | P2 / P1 press Start, Back, Start again quickly | 0.6 only: `re-added ... (lost)` / `reopening the pause`; 0.7.0: `lost menu: ...` lines of V-PAU-12, never a frozen race with no menu | `PauseLostMenu="probe"` |
| V-WD-19 | wrecked guest watches a car | P2 wrecks while P1 races | `P2 view -> <name>'s car ... via own camera, checking (cam active=.. stack=..)`, then `watched car camera check n: inside/front ...` -> `... no chase camera ...: view -> rig` for an AI pod; a local human's car `via own camera (...)` | `WreckCarCam="car"` |
| V-WD-20 | chase rig | same | `[chasecam] rig spawned for ...`; P2's half shows the watched pod from behind/above and follows it smoothly; `rig moved` when the car changes; no `chase rig unavailable` | `WreckCarCam="car"`, `WreckSpectateTarget="human"` |
| V-PH-01 / V-WD-17 | photo mode | after P2's wreck: pause -> photo mode, move both pads, close | `[phase] photo mode OPEN (...)`; `P2 view guard paused: photo mode`; NO `spectate view restored` lines while open; then `photo mode CLOSED`, `photo mode closed: view guard resumes in 1500 ms`, `probe P2 after photo mode` | report |
| V-HUD-16 / V-INP-07 | others back off | same | `[hud] photo mode open ...: HUD work paused` once; `[inputfix] photo mode open: native filter off (...)`; each pad moves its own photo camera; after closing the cars are bound again | report which pad moved which camera |
| V-WD-* hot reload | slow-mo safety | Ctrl+F11 during the slow-mo | `hot reload during an emulated slow-mo: CinematicTimeDilation ... put back to 1.0` | — |

### Run-G checks: input filter reload, view guard, pad order
Install the rebuilt `native/swgr_inputfilter.dll` with the game closed (§2.2), then a 2-pad offline race.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-INP-08 | DLL reload thread | boot, then read `ue4ss/Mods/SWGRCouch/native/swgr_inputfilter.status` | `reload_thread=1`, `reload_ms=250`; `reloads` grows at each phase change | `reload_thread=0`: works as before (reload on input), report it |
| V-INP-09 | bind without input | countdown, nobody touches a pad | `[inputfix]` reports every car bound / filter on within ~0.5 s of the `wo` line, not at the first pad press; status `w_ok` grows, `w_fail` stays | report the status file + log tail |
| V-INP-10 | pad order | before the race: the `/proc/bus/input/devices` command of §3.2 | the joined players' order matches the lowest-`eventN`-first order of the whitelisted pads | replug all pads in the wanted order, restart the game |
| V-VG-01 | P1 not stuck on P2's DNF cinematic | P2 wrecks while P1 races | at most one `[viewguard] P1 is still racing but its view was BP_PlayerFailedCam_C ...` line per 3 s; P1's half back on its own chase view within ~0.5 s; F9 (if wired) `viewguard: on fixes={P1=n ...}`; on the next load `[viewguard] cleared (LOADING): n view fix(es)` | `ViewGuard=false` + report |

### Run-H UX checks: each half is its own player's (0.7.0, `uxsplit.lua`)
A 2-pad offline race, a podrace for V-UX-08; `grep '\[uxsplit\]\|\[hud\]' UE4SS.log`. With `TestCommands = true` the
`lua` lines below go into `test.cmd` (testcmd.lua). In order:

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-UX-00 | loaded, idle in the menu | boot | `[uxsplit] init: messages=route (hide collapse, re-post on), index remap on, danger=own ...; hooks only while a split race runs`; no `[uxsplit] hook on` line before the race | — |
| V-UX-01 | guest engine panel on its own car | start the race (countdown) | `[uxsplit] armed (HUD creation, 2 local players): ... 10 hook(s)` + 10 `hook on:` lines; `[uxsplit] remap GetPlayerPawn(self, 0) -> P2's car for WBP_HUD_BotEngineInfo_C (HUD being created)`; `[hud] P2 BotEngineInfo: Vehicle State = P2's car (index remap)`; no `[hud] P2 HUD: n binding(s) moved from P1's car` | `UxSplitIndexRemap=false` (0.6.0 rebind path) |
| V-UX-10 | the game's hidden HUD tamed | same | `[hud] game HUD ... (hidden, owner P2 ...): 3 member(s) collapsed [WBP_Hud_PositionMap,Img_1DMap_MidSection,WBP_Hud_Countdown]`; `[hud] game HUD (hidden): 5 binding(s) on P1's car removed`; 3-2-1 beeps once per player, not three times | `UxSplitGameHud=false` |
| V-UX-02 | messages in their own half | P2 drives backwards; P1 lands a pod jump; or `lua return require("uxsplit").testPost(2, "PerfectLanding")` | `[uxsplit] msg WrongWay by BP_VehicleUIComponent_C (car) = P2 -> HUD_Notification_Container: 4 new copy(ies) (shown P2 x2; hidden P1 x2)`; `msg PerfectLanding ... = P1 -> Hud_Notification_GameFeed: 2 new copy(ies) (shown P1 x1; hidden P2 x1)`; the other half shows nothing | `UxSplitMessages="all"` (log only) and report; `"off"` |
| V-UX-03 | a full container | P2 wrong way, then P1 wrong way | `msg WrongWay ... = P1 ...: 0 new copy(ies) ...; 4 full container(s): it waits there; the WrongWay copy already on screen is shared with P1`: both halves read WRONG WAY; later lines `msg <id> (Pn) shown after it waited` | report (Plan B' in lead_todo) |
| V-UX-04 | a removal for everybody | both wrong way, then P1 turns round; or `lua return require("uxsplit").testRemove(1, "WrongWay")` | `RemoveMessage WrongWay by P1: P2 still holds WrongWay -> re-posted for P2 (ok)`; P2 keeps WRONG WAY, P1's clears | `UxSplitRepost=false` |
| V-UX-05 | hidden copies never stall | after V-UX-02 | dbg `hidden copy of PerfectLanding (P1) left P2's HUD after 5.x s (row minimum 5.0 s)`; never `... a stall? try UxSplitMsgHide = "opacity"` | `UxSplitMsgHide="opacity"` |
| V-UX-06 | race-ending countdown everywhere | first finisher | the countdown shows in both halves; `unattributed <class> 'Race ending in ..' in Hud_Notification_GameFeed ...: global, kept in every HUD` | report |
| V-UX-07 | last-life red per player | `critical 2` (or `health 2 -1` until 1), then `critical 1` | `MPC AfterburnerColor <- last-crash colour by P2's HUD: blocked ...`, then `MPC AfterburnerColor write dropped: value still the default` (or the WARN switching to restore mode), `P2 HUD tint: danger (last crash)`; P2's HUD red with its scanline + SYSTEMS CRITICAL, P1's HUD orange; probe `Afterburner=(0.99,0.40,0.07)` | `UxSplitHudColours=false`; `UxSplitDanger="neutral"` |
| V-UX-08 | ramjet blue per player | podrace, P1 engages its ramjet | `EngageRamjet stopped on P1's BotEngineInfo: icons set, the global ramjet colour kept`, `P1 HUD tint: ramjet`; P2's HUD stays orange; probe `FadeDir=1.00 FadeProg=-1.00` | `UxSplitRamjetColour=false` |
| V-UX-09 | full-screen danger per player | race start; `critical 2`; an ability hit (System Malfunction) | once `GetFullScreenEffectsEnabled -> false while split ...`; `P2 last life: camera tint in its own view (up to 0.20)`; `P2 system malfunction: camera flash in its own view`; P1's half untouched; probe `VS_vfx FinalLife=0.00` | `UxSplitFadeMax=0.1`; `UxSplitFullScreenFx=false`; `UxSplitDanger="neutral"` |
| V-UX-11 | probe + F9 | `UxSplitProbeMs = 5000` (0.12.0: 0 by default); wait 5 s; F9 | `[uxsplit] probe MPC Afterburner=... \| tint P1=.. P2=.. \| fade ...`; F9 section `uxsplit: armed=true ...`, one `hook` line per hook with its ids, one line per HUD with its containers | — |
| V-UX-12 | radio portrait | a radio line during the race | portrait in P1's HUD only; `[hud] guest HUDs: radio-chatter portrait hidden` | `UxSplitGuestHolo="keep"` |
| V-HUD-04 | guest lap | P2 crosses the line first time | `[hud] lap offset calibrated at P1's lap 1: VM 1 - P1 component 1 = 0`; P2 reads LAP 1/N on its first lap, 2/N after its next crossing | `LapPatch=false` |
| V-UX-13 | hooks gone before the map changes | finish, results, then Enter / A to leave. If the results screen takes no input (run-H fact 6: the game's P2-owned screen, the known phase-2 problem, NOT a V-UX-13 failure), leave with testcmd `lua U.cdo("/Script/Griffin.Default__UIBlueprintFunctionLibrary"):ReturnToMainMenu(U.world())` | `[uxsplit] disarmed (phase POSTRACE): 10 hook(s) off; ...` and `[pause] native pre-hook unregistered (phase POSTRACE)` before the results screen is left; no crash back to the menu (the run-H probe crash); the next race arms again | report the log tail + crash dump; if the testcmd exit does nothing, report it |

Integration review (0.7.0), watched during the rows above: the `hook on:` line of
`SubsystemBlueprintLibrary:GetGameInstanceSubsystem` ends with `, pre only)`; an elimination of two racers within 1.5 s
gives two messages (`msg RacerEliminated ...; first copy of a per-HUD message: every half` twice); a takedown / status
message of one player is never `shared with` the other; `MPC ... reset to the default when arming` may appear once when a
race re-arms with a red HUD left; `armed again in the same world: given back ...` only after a phase blip. Never seen:
`WARN remap: P2 has no car` in a normal race, `callback ... failed`.

### Run-H pause checks: the menu is the pauser's (0.7.0, `pause.lua` layers A-G)
Same 2-pad race (P1HudMode `"clone"`, KEYBOARD IS P1 off); `grep '\[pause\]' UE4SS.log`. In order:

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| (boot) | loaded, armed per race | boot, then the race (PRERACE) | `[pause] init 0.7.0: ... PauseCsmHook=true (read state true, trace false) PauseMenuPrecreate=true PauseMenuOwner=pauser ... PauseMenuRehost=never (= never)`; then `Menu-layer ZOrder = <z> (dialog layer - 1; ...)`, `split race (2 local players): A=true B=true C=true D=all E=true F=recover G=onpress; ... dialog containers 3; classes WBP_PauseRacing_C, WBP_PlayerMenu_Presentation_C (V-PAU-09..16)`, `native pre-hook registered: /Script/Griffin.CosmeticStateMachine:ChangeStateTo (ids N/M, ...)`, `pause hook armed (split race, 2 local players)`. Bad: `dialog containers 0`, `RegisterHook(...) failed`, `(not loaded)` | report |
| V-PAU-09 | A1 game HUD input | race HUD up (`[hud] game HUD ... owner=P2 (guest, ctrlId 1)`) | `[pause] game HUD input unregistered (WBP_Hud_Race_C_<n>, owner P2 (ctrlId 1) = UIManager owner, ...)`: once per game-HUD instance (again after every resume) | `PauseHudInputGuard=false` (then expect the run-H freeze) |
| V-PAU-11/10/15 | P2 pauses | P2 Start once, both racing | `IMC_UI priority -> 500 for P2 (request)`; `request on the pause CSM: kind=pause target=PauseMenu by P2 (P2 Start down) -> HUD inputs off (P1,P2), WBP_PauseRacing_C pre-created for P2 (ctrlId 1) (z=<z>, pauser); IMC_UI -> 500 for P2`; `game paused by P2 (P2 Start down)`; `pre-created WBP_PauseRacing_C (owner P2 (ctrlId 1)) acquired by the CSM after <=33 ms (osm = pause CSM): extra ref released; input mode refresh ok`; probe `owner=P2 (ctrlId 1) pre=ours osm=ok ... activated=true ... focus=P2 imcUi=P1:500,P2:500 ... states=[PauseMenu Paused_Racing] menuLayer=1`. Live: PAUSED full screen, P2's D-pad moves, A on RESUME resumes; then `IMC_UI restored (resume): P2 0`, `pause over (states [Idle]); IMC_UI P2 0`, `HUD inputs back on (P1,P2) ~150-200 ms after resume (pause keys up)`. Repeat with P2's B, and with P2's Start pressed again. Bad: `duplicate`, `lost menu`, `not used by the CSM within 500 ms`, `REMOVED`, `osm=nil`, `pre=game`, `focus=none`, `P2:0` in imcUi while paused, `request ... without a pause` | `PauseMenuOwner="p1"`; crash: `PauseHookReadState=false`, then `PauseCsmHook=false` |
| V-PAU-15 | P1 pauses | P1 Escape, then P1's pad Start | `request ... by P1 (P1 Escape down) -> ..., WBP_PauseRacing_C pre-created for P1 (ctrlId 0) (z=<z>, pauser)`; probe `owner=P1 (ctrlId 0) pre=ours osm=ok focus=P1 imcUi=P1:500,P2:500`; Enter / pad A on RESUME resumes | `PauseMenuOwner="p1"` |
| V-PAU-13 | F3 another Start | P2's menu up > 0.5 s, then P1 Escape | ~0.3 s later `P1 Escape while P2's menu is up: resumed from Lua (Idle ok)`; the owner's own Start gives no V-PAU-13 line | `PauseAnyStartResumes="off"` |
| V-PAU-18 | held Start | P2 holds Start 2 s, releases, presses again | exactly ONE `request on the pause CSM` line; no `duplicate` / `lost menu`; the menu stays; the second press resumes | report |
| V-PAU-17 | player menu | P2 taps Back/View | `request ...: kind=player target=PlayerMenu by P2 (P2 View released) -> ..., WBP_PlayerMenu_Presentation_C pre-created for P2 (ctrlId 1) ...`, then `... acquired by the CSM ...`; P2's B (or View) closes it: `pause over (states [Idle])` | report |
| V-PAU-12 | F1 repair (deliberate) | `PauseHudInputGuard=false` in config_user.lua, P2 Start (two bindings again) | `WARN duplicate ChangeStateTo(PauseMenu) while [PauseMenu Paused_Racing] ...; repair armed`, within ~100 ms `lost menu: [PauseMenu] without sub-state -> ChangeStateTo(CSM_PauseMenus_Paused_Racing) for P2 (repair 1: ok)` and `pause CSM enters Paused_Racing (repair): WBP_PauseRacing_C pre-created for P2 ...`; a usable menu follows. Put `PauseHudInputGuard=true` back | `PauseLostMenu="probe"` |
| V-PAU-14 | dialogs | from a P1-owned pause: EXIT TO MAIN MENU / ABANDON, wait 3 s, cancel | no `lost menu` line while the dialog is up; the menu comes back; no `+Dialog1`; `+dialog Dialog:1` only while a dialog really shows. Known limit: confirm dialogs are P1-owned (a guest pauser cannot answer them) | report |
| V-PAU-16 | G after a wreck | P1 crashes 3x and wrecks while P2 races; P2 Start | `pause CSM gone (the race CSM left CSM_RF_InProgress: P1 wrecked or finished); still racing: P2; PauseRestartCsm onpress`; P2 Start → `pause CSM restarted (P2 Start; still racing: P2): StartCosmeticStateMachine ok` → `request ... by P2 (our call (mod)) ... pre-created for P2` → menu → resume; race end: `own pause CSM ended (phase POSTRACE): EndStateMachine ok` (or `(leaving (...))`). Bad: `pause CSM restart failed` | `PauseRestartCsm="off"` |
| (leave) | leaving while paused | EXIT TO MAIN MENU (or ABANDON) from a guest-opened pause; the confirm dialog is P1-owned (V-PAU-14): P1 answers it | before the travel `IMC_UI restored (leaving): ...` and `native pre-hook unregistered (leaving (return))`; no crash across the travel; the guests' pads work normally in the front end | report |
| V-PAU-15 (KbP1) | KEYBOARD IS P1 (optional) | pad 0 (P2) Start | `pre-created for P1 (ctrlId 0) (z=..., KeyboardIsP1 pad shift ctrlId 1 -> 0)`; pad 0 and the keyboard both navigate | `PauseOwnerPadShift="off"` |

F9 shows a `pause: armed=true hook=true hookCalls=... requests=... noPause=0 pre=... acquired=... imcBoosted=... hudInputsOff=...
ownCsm=... pauser=P2 z=<seen>/<auto> dialogs=3` line and a `cfg:` line; `noPause` > 0 means a `request ... without a pause`
was undone (report the log lines around it).

### Run-I results (0.7.0 live, 2026-10-07) and the 0.7.1 changes
Verified live: messages per player (`[uxsplit] msg Vulnerable ... = P1 -> ... (shown P1 x1; hidden P2 x1)`, also
WrongWay / Takedown / TakendownBy), danger per player (P2 last life: P2's whole HUD red + its own camera tint, P1's
half untouched), BotEngineInfo remap (`remap GetPlayerPawn(self, 0) -> P2's car`), hooks off at POSTRACE (no crash
leaving the race), both players pause and resume with their own A (pre-created screen for the pauser).

0.7.1 (`menubridge.lua`, `wreck.lua`, `chasecam.lua`):
- **Menu bridge** (`cfg.MenuBridge`, `MenuBridgeWaitMs` 150): a screen the game gave a guest, or a shared post-race
  screen, takes the player's A/B: when the game has not reacted within the wait, the selected button is clicked
  (`CommonButtonBase:HandleButtonClicked`, proven: RESUME resumed). The post-race "Race FINISHED" CONTINUE is P2-owned
  in split and took no input at all before (dead end): now P2's A continues
  (`[menubridge] P2 A -> WBP_SimpleRaceResultsScreen_C WBP_Common_Btn_Continue (...): clicked`, then FRONTEND).
  P1's pad is not seen by its controller on that screen (`IsInputKeyDown(A)` false): the bridge gives the non-owners
  Game+UI input there (`P1 input mode Game+UI on ...`), to be confirmed live (V-MB-02).
- **Wrecked guest's view**: a camera ACTOR (the 0.6.0 chase rig, the game's spectator and crash cameras) renders
  BLACK in a guest's lower view (P1 sees the same rig pillarboxed: the Fuse camera manager constrains non-vehicle
  cameras), and AI pods have no camera component. The wrecked player's own pod camera with `TargetActorOverride` =
  an AI pod renders (keep the wreck upright). (Run J: the "self-pauses" seen then were NOT caused by it: the game
  pauses itself after ~60 s without game input from any local player (idle test pads; a menu A does not reset it).) `WreckCarCam` "auto" (default) therefore
  keeps a guest whose pick is an AI pod on its OWN wreck (`P2: <name>'s car has no camera of its own ...: own wreck
  shown instead (V-WD-22)`); "override" and "rig" are experiments. `WreckSpectateTarget` default "ai" (a wrecked guest
  no longer copies P1's view, run-H feedback).
- **0.7.2 (run J)**: the post-process letterbox that blacked out camera actors in a guest's half is switched off on
  the chase rig (`SetConstrainAspectRatioUsingPostProcess(false)`, research `guest-camera-black.md`); the game's own
  spectate renders for a wrecked guest and follows AI racers, so `WreckView` defaults to "native". The guest's
  crash camera (BP_CrashCameraActor, re-applies the letterbox flag every frame during a crash) gets
  `PostProcessBlendWeight = 0` (`CrashCamLetterboxFix`): the game's own crash shots and slow-mo render in P2's half;
  `CrashCamGuest` defaults to "auto" again. The 60 s "self-pause" is the game's inactivity auto-pause (no game
  input from any local player); unattended tests run a keep-alive script (`tools/keepalive.sh`, a development tool).
- **UE4SS windows**: `install.sh --quiet-console` turns off both the text console and the OpenGL debug GUI (its
  toggle key O is also the game's keyboard player-menu key); `UE4SS.log` keeps everything.

### 0.8.0 checks: 3D vehicle cards, subtitles per player, pause phase 2 (§1.7)
Deploy `Scripts/*.lua` (new: `subsplit.lua`, `vpreview.lua`; changed: `config.lua`, `consts.lua`, `main.lua`, `diag.lua`,
`pause.lua`, `menubridge.lua`, `setup.lua`, `vehicles.lua`). Order: boot, the VEHICLES step (front end, P1 alone, then
with guests), a 1-player race, a 2-pad race (subtitles, then the pause rows, finish last), the front end after it, and
last the dedicated Logbook-hook run. `grep '\[subsplit\]\|\[vpreview\]\|\[pause\]\|\[menubridge\]' UE4SS.log`. The `lua`
lines go into `test.cmd` (`TestCommands = true`). Offline harnesses (no game): see the end of this section.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| (boot) | 0.8.0 loads, nothing armed | boot to the main menu | `[main] SWGRCouch 0.8.0 loading: ...`; `started: ... modules=33/33` (0.10.0: `modules=42/42`, Session R; 0.12.0: `modules=46/46`, Session U); `[subsplit] init: subtitles=route detect=hook both=clone unmatched=both ability-hook on; hooks only in split races (V-SUB-00)`; `[pause] init 0.7.2: phase 2 PauseSubScreenPrecreate=true PauseSubScreenHook=false PauseDialogGuestUi=lower (V-PAU-19..22)`; `[menubridge] init 0.7.2: MenuBridge=true wait 150 ms (...) dialogs true, back true, controller fallback true, profile owner true`; no `[subsplit] hook on` before a race; no `module ... failed to load`, no `config_user.lua: unknown key` | report |
| V-VP-01 | bay + model + ready | RACE SETUP > VEHICLES, P1 alone; wait ~2 s | `[vpreview] bay 1 at (0, 60000, 60000): target 640x360 format 6, source 2, fov 30, show-only list, fill on (V-VP-01)` (0.10.0 default: `target 960x540`), `bay 1: PRE_Car_Beluga spawned (GfnGameInstance.StaticVehicleClass) (BELUGA, archetype 0) (V-VP-01)`, within ~1-2 s `bay 1 ready: PRE_Car_Beluga, <n> unit(s), all bounds <W>x<D>x<H> (r <r>), camera <d> uu, <t> ms, stable (V-VP-01)`. Bad: `3D vehicle preview off for this session: <why>` (every card 2D) or `bay 1: <id> not shown in 3D (<why>)` (that column 2D); `the model falls (z .. < ..): physics off, put back` = report | `SetupPreview3D=false` |
| V-VP-03 | the card shows the model | same, screenshot | `column image = MID of /Game/Griffin/UI/Library/Materials/Diegetic/M_UI_RetainerBox_ScreenSpace.M_UI_RetainerBox_ScreenSpace, texture parameter Texture (V-VP-03)`; each card shows its own turning vehicle (not black / transparent); the 2D art until `ready`; a new pick keeps the previous model at 50 % until it is built | distorted / noisy: `SetupPreviewMaterial="/VirtualCamera/WidgetLibrary/VCamTakesBrowser/Widgets/mat/M_ThumbnailMask.M_ThumbnailMask"` + `SetupPreviewMaterialParam="Target"`, then `SetupPreviewBrush="texture"`; washed out: `SetupPreviewRtFormat=3`, then `2` |
| V-VP-08 | badges + inset | cycle the models | speeders show their manufacturer logo top left (Beluga = Ace A, Goblin = Assassin B, Hammerhead and the QUIET STRENGTH livery = Raider B); pods none except MYTH P1-P3; a pilot livery shows its owner's portrait bottom right next to the render; the 2D cards get the badge too | `SetupCardBadges=false` |
| V-VP-04 | look | screenshot of a speeder and a pod | exposure and colours close to the menu's; the speeder and the QuadEngine pod framed whole while turning (the `ready` line prints the bounds kind and the camera distance) | `SetupPreviewExposure="fixed"` + `SetupPreviewEV`; `SetupPreviewFillLux`; `SetupPreviewFrame`; `SetupPreviewBounds="colliding"` |
| V-VP-05 | main view unaffected | every main-menu tab and camera while the step was open and after | no floating vehicle or shadow anywhere; the front-end screens behave as before | `SetupPreviewCaptureOnly=true` |
| V-VP-07 | teardown | BACK; SAVE; START RACE; a guest leaves; change tab; Ctrl+F11 in the step | BACK: `[vpreview] released (step mode): 1 bay(s), 3 actor(s) destroyed; session N spawn(s), 0 rebuild(s), N ready, F failed, C capture(s) (V-VP-07)`; `released (save)` / `released (start)` / `released (tab left)`; a guest leaving: `bay 2 released (no player in column 2): 3 actor(s) destroyed (V-VP-07)`; Ctrl+F11: `hot reload (shared variable): preview actors of the previous Lua state to destroy: <3 paths>`, then `hot reload: 3 preview actor(s) of the previous Lua state destroyed, 0 already gone (V-VP-07)` | report |
| V-VP-06 | cost | `Debug = true`; 1, 2, then 4 spinning bays | the `[main] FAST loop timing` line and the frame time stay close to the menu without bays | `SetupPreviewCaptureMs=100`, then `SetupPreviewSpinDps=0` (static) |
| V-VP-10 | 2-4 players | guests join in the step | one `bay N at (X, 60000, 60000)` per column (X 0 / 5000 / 10000 / 15000; 0.10.0 default spacing: 0 / 20000 / 40000 / 60000); 4 players: cards 187 px high and 332 wide, no row overflow; columns re-render when guests join / leave | report |
| V-VP-02 | (optional) rebuild in place | `SetupPreviewRebuild="update"`, pick another model | `bay 1: PRE_Car_Bluefin rebuilt in place (BLUEFIN, archetype 0) (V-VP-02)`, then a `ready` line with other bounds and the new model on the card. Same bounds / old model: keep `"respawn"` | `"respawn"` (default) |
| V-VP-09 | 2D fallback | `SetupPreview3D=false` | no `[vpreview]` line at all; the 0.7.1 cards (2D art at its own width, 269 px for speeders) + the badge | — |
| F9 | diag | F9 in the step, in a race | new sections: `menubridge: on=true screens=... top=... owner=...`, `subsplit: armed=... widget=[...] hooks=7 ...` + `cfg:` / `flags:` / `hook` / `pending` lines, `vpreview: 3D on, bays {1=ready:PRE_Car_Beluga}, captures N; usable now=true`, and a `pause` `phase 2: ctsHook=false ctsCalls=... subRequests=... subScreen=... imcDialog=...` line | — |

Subtitles (`subsplit.lua`): a 1-player race, then a 2-pad race (podrace for ability hits). The translations below are
for a 1080-unit-high window (`viewport 1920x1080 su` in the widget line; dpi 1.33 on a 1440p screen, 1.00 on 1080p).

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-SUB-01 | single player untouched | a 1-player race | no `[subsplit] armed` line; subtitles where the game puts them | report |
| V-SUB-01/05 | armed in a split race | 2-pad race, PRERACE | `[subsplit] widget WBP_Subtitles_C_<n> owner P1 z <n>; viewport 1920x1080 su (dpi 1.33); config InEvent pad 450 Center/Bottom; layout top/bottom (V-SUB-05)`, 7 `[subsplit] hook on:` lines (GetWorldSubsystem and the four Request* `pre only`), then `armed (phase PRERACE, 2 local players): 7 hook(s), clone for P2; lines seen by the config hook (V-SUB-01)`. At PRERACE the config may be another one: `subtitle config InEvent pad 450 Center/Bottom (V-SUB-05)` when it changes. Report `z nil` (the clone then goes to z 0). `waiting for the subtitle widget` may repeat until the dialogue manager made it | `UxSplitSubtitles="off"` |
| V-SUB-06 | a line for everybody | race start | `-> both (rule Trigger.RaceStart); game P1 0,-315, clone P2 0,+225 (V-SUB-06)` (or `both (race intro (RequestEvent))`); the same text in both halves; pause during a line: both boxes fade, both come back on resume | `UxSplitSubBoth="game"` |
| V-SUB-02/03/04 | a line for one player | P2 crashes | `request Trigger.PlayerCrashes char=Character.<Nemesis> delay=3.0 by BP_FuseVehicleNarrativeComponent_C (car) = P2 (V-SUB-02)`; ~3 s later `line VO.ML.<Char>.Trigger.PlayerCrashes.Racer speaker=Character.<Char> "..." -> P2 (Trigger.PlayerCrashes by P2, 3.x s ago); P2 rect, translate 0,+225 (V-SUB-03/04)`. Screenshot: the taunt in the LOWER half, low middle, nothing at the old place (y 630). A P1 crash: `-> P1 (...); P1 rect, translate 0,-315` (upper half) | `UxSplitSubtitles="log"` (attribution only) and report |
| V-SUB-03 | same frame | during the rows above | the probe's `late` stays 0. `[FAST poll]` lines + `a line reached the FAST poll before the config hook` = the config hook does not fire (lines still move, 1-2 frames late) | `UxSplitSubDetect="poll"` |
| V-SUB-04 | HUD overlap | screenshot of each half with a line | the box (225 units above each half's bottom) does not cover that half's bottom HUD | `UxSplitSubHalfFrac` 0..1 (e.g. 0.3) |
| V-SUB-07 | probe | every 5 s while armed (`UxSplitProbeMs = 5000`; 0.12.0: 0 by default) | `[subsplit] probe: wss N/s (dialogue N) requests N (P1 a, P2 b, AI c, unknown d, pairs e) lines N (P1 x, P2 y, both z, unmatched u, late l) config calls N ahit N (V-SUB-07/08)`. Record `wss N/s` (cost of the engine-wide hook), `AI` (do AI pods' components post?) and `unknown` (requests with no Blueprint poster) | costly: `UxSplitSubPosterHook=false` (6 hooks), then `UxSplitSubtitles="off"` |
| V-SUB-08 | ability hits | vent / shockwave / disruptor hits | `ahit` > 0 and `request Trigger.(Vent\|Ability).PlayerHits ... by ability hit: the hitter, P<n>`; `pairs` > 0 = every pod posts the same request (broadcast) | `UxSplitSubAbilityHook=false` |
| (speaker) | a line nobody asked for | run I's ARY QUILL scream (an AI pod crashes) | `-> P1 (no request; speaker car AI, nearest P1 NN m)` or `speaker car P<n>`; `unmatched` lines go to both (`UxSplitSubUnmatched`) | `UxSplitSubUnmatched="p1"` |
| (testcmd) | forced lines | `lua return require("subsplit").testLine(2, "VO.ML.Rager.Trigger.PlayerCrashes.Racer")`, then `testLine(0, ...)`, `lua return require("subsplit").status()` | returns `requested ... for P2; the line log follows in ~0.1 s` and logs `-> P2 (forced); P2 rect, translate 0,+225`; `testLine(0, ...)`: `-> both (forced); game P1 0,-315, clone P2 0,+225`; status `armed=true (...) widget=[...] hooks=7 ...` | — |
| (layouts) | other layouts | side-by-side 2P; the intro / results on one view | `P2 rect, translate +480,0 x0.75`; `one full-screen view: the game's place`; `split views while a line shows: ...` when the view splits mid-line | `UxSplitSubSideScale` |
| V-SUB-01 | hooks gone | finish -> results -> front end; another race, EXIT TO MAIN MENU from the pause | `[subsplit] disarmed (phase POSTRACE): 7 hook(s) off; transform reset; 1 clone(s) removed; lines N (P1 a, P2 b, both c, unmatched d), requests N, 0 callback error(s) (V-SUB-01)`, no crash back to the menu. Leaving from the pause: `disarmed (leaving: ...): 7 hook(s) off; subtitle widgets left as they are (quiet)` | report the log tail + crash dump |

Pause phase 2 (`pause.lua`, `menubridge.lua`) in the same 2-pad race. The Logbook hook is OFF in these rows.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| (arming) | phase-2 layers armed | PRERACE | `[pause] split race (2 local players): A=true B=true C=true D=all E=true F=recover G=onpress; ...; 0.7.2 B2=false C2=true D2=lower, sub-screens WBP_Settings_C, WBP_Stickerbook_C (V-PAU-09..22)` (`(not in memory yet)` is fine); `native pre-hook registered: /Script/Griffin.CosmeticStateMachine:ChangeStateTo (ids N/M, ...) (V-PAU-11)`; `pause hook armed (split race, 2 local players; ChangeToState hook off) (V-PAU-11/20)`. Bad: `RegisterHook(...ChangeStateTo) failed` | report |
| V-PAU-19 | Settings belong to the pauser | P2 pauses, SETTINGS; then the same from P1 (Escape / pad) | `[pause] sub-screen request: Settings via ChangeStateTo -> WBP_Settings_C pre-created for P2 (ctrlId 1) (z=<z>, pauser) (V-PAU-19)`, `pre-created WBP_Settings_C (owner P2 (ctrlId 1)) acquired by the CSM after <=50 ms (osm = pause CSM): extra ref released; input mode refresh ok (V-PAU-19)`, `sub-screen probe +0ms: WBP_Settings_C owner=P2 (ctrlId 1) pre=ours osm=ok activated=true focus=P2 controller=P2 (ctrlId 1) imcUi=P1:500,P2:500 states=[Settings]`. P2's pad navigates and changes a setting; B goes back: `pause CSM enters Paused_Racing: WBP_PauseRacing_C pre-created for P2 ...` + `acquired`. From P1: owner=P1. Bad: `WARN sub-screen probe ... NOT the controller's screen`, `not used by the CSM within 500 ms`, `no pre-create: WBP_Settings_C not in memory` | `PauseSubScreenPrecreate=false` (the bridge then drives the game's screen) |
| V-MB-04 | native first | P2 pauses, SETTINGS, toggles one option with A | exactly one change and one `[menubridge] P2's own WBP_Settings_C takes P2's pad natively (IMC_UI boosted while paused): not bridged (V-MB-04)`. If P2's A/B do nothing natively on its own Settings, report | `MenuBridgeGuestNative="bridge"` |
| V-PAU-20 | Logbook (hook off) | P1 pauses, LOGBOOK; B; PHOTO MODE | `WARN sub-screen probe +0ms: WBP_Stickerbook_C owner=P2 (ctrlId 1) pre=game ... controller=P1 (ctrlId 0) ... - NOT the controller's screen (menubridge fallback)`, `[menubridge] WBP_Stickerbook_C is P2's but the pause controller is P1: the controller's A/B are bridged on it (V-MB-03)`, `P1 input mode Game+UI on WBP_Stickerbook_C (pause controller): ok`; P1's B: `[menubridge] P1 B -> WBP_Stickerbook_C: BackToPreviousState() (V-MB-03)` (or `HandleBack()` / `OnCancelAction()` if the Logbook has one) and P1's pause menu is back. No `sub-screen request: Stickerbook` line (that needs the hook) | report |
| V-PAU-21 / V-MB-05 | confirm dialogs | P2 pauses, EXIT TO MAIN MENU; P2 B; again, D-pad right, D-pad left, A | `[pause] IMC_UI restored (confirm dialog Dialog:1 up): P2 0 (V-PAU-10)`; B: `[menubridge] P2 B -> dialog WBP_Modal_C (Dialog:1) button 2/2 'Cancel' (last button = cancel): clicked (V-MB-05)`, then `IMC_UI priority -> 500 for P2 (confirm dialog closed)`, the race stays paused and P2's menu works; D-pad: `P2 D-pad -> dialog WBP_Modal_C button 2/2 'Cancel' (the dialog owner's focus follows)` and the highlight moves; A after D-pad left: `button 1/2 'Accept' (D-pad pick): clicked` -> main menu (`disarmed (leaving: ...)` lines). ABANDON TOUR behaves the same. Bad: the game resumed on B, a second dialog after A, `nothing clicked` | `MenuBridgeDialogs=false`; `PauseDialogGuestUi="keep"` |
| V-MB-03 | back paths + controller fallback (forced) | `PauseSubScreenPrecreate=false`; P1 pauses, SETTINGS, B | `WARN sub-screen probe +0ms: WBP_Settings_C owner=P2 ... controller=P1 ... NOT the controller's screen (menubridge fallback)`, `[menubridge] WBP_Settings_C is P2's but the pause controller is P1: the controller's A/B are bridged on it (V-MB-03)`, `P1 input mode Game+UI on WBP_Settings_C (pause controller): ok`; P1 B: `[menubridge] P1 B -> WBP_Settings_C: HandleBack() (V-MB-03)` and P1's pause menu is back. Put the key back | `MenuBridgeBack=false`; `MenuBridgeControllerFallback=false` |
| V-PAU-22 | inactivity auto-pause | every pad idle ~60 s | `game paused by none`, `pause CSM enters Paused_Racing: WBP_PauseRacing_C pre-created for P1 (ctrlId 0) (z=900, pauser unknown -> P1)`; P2's A resumes it (`[menubridge] P2 A -> WBP_PauseRacing_C ...: clicked`); SETTINGS from that pause is P1's (`owner=P1 controller=P1`) | report |
| (race end) | hooks gone | finish | `[pause] native pre-hook unregistered (phase POSTRACE): ChangeStateTo` before the results are left (with the Logbook hook on: `ChangeStateTo, ChangeToState`); no crash back to the menu | report |
| V-MB-06 | profile card | back in the front end after the split race | `[menubridge] front-end profile card WBP_MP_ProfileCard: owner P2 (UIManager owner = last local PC) -> P1: SetOwningPlayer ok; name 'Player 2' -> '<account name>' ok; rank ok, platform ok (try 1) (V-MB-06)`; the top right shows P1's name. Also check that P1's pad and keyboard still drive the main menu (it is the game's P2-owned menu). Bad: no line, or the name unchanged | `MenuBridgeProfileOwner=false` |

**Dedicated Logbook-hook run (V-PAU-20 with `PauseSubScreenHook = true`).** A separate 2-pad race with
`return { PauseSubScreenHook = true }` in `config_user.lua`: the hook sits on a function whose first parameter is a soft
pointer (never read by the mod; UE4SS wraps its address). Arming: `native pre-hook registered: ...:ChangeToState (...)
(V-PAU-20)` and `pause hook armed (...; ChangeToState hook on)`. P1 pauses, LOGBOOK: `[pause] sub-screen request:
Stickerbook via ChangeToState 'Open Stickerbook from Pause menu' -> WBP_Stickerbook_C pre-created for P1 (ctrlId 0) ...
(V-PAU-20)` + `acquired by the CSM`; B returns to P1's pause menu; the same from P2; PHOTO MODE logs once `ChangeToState
on the pause CSM, reason '': photo mode (WBP_Pause.OnPhotomodeButtonCalled): no CSM screen (V-PAU-20)`; race end:
`native pre-hook unregistered (phase POSTRACE): ChangeStateTo, ChangeToState`, back to the menu. A crash at any point:
remove the line (the default) and report the dump. Only after a clean run may the soft-pointer rule be amended
(ARCHITECTURE Revision 0.8.0) and the default changed. An unmapped reason (a Settings page entered through
`ChangeToState`) logs `ChangeToState on the pause CSM, reason '...': not mapped`: report the reason.

Facts to record in `notes/research/live-run-K-facts.md` (or the next run's file): the probe's `wss N/s`, whether AI pods
post (`AI`), `pairs` / `ahit` after ability hits, `late` = 0, the subtitle layer z, whether the box at 225 units covers a
half's bottom HUD, the bay `ready` times and the FAST loop timing with 1/2/4 bays, the material A/B verdict.

Offline harnesses (no game; /tmp is lost on reboot, copy them to `scripts/harness/` first):
`lua5.4 /tmp/subsplit-harness/run.lua <Scripts>` (64 checks) and `/tmp/integ080/sub/run.lua <Scripts>` (76, with the 0.8.0
fixes), `lua5.4 /tmp/vptest/scenario.lua <Scripts>` (`[TEST] PASS: 0 failure(s)`, 43 checks) +
`/tmp/vptest/variants.lua <Scripts> off|update|static|texture|fixed`, `lua5.4 /tmp/integ080/pp2/scen_p2_on.lua` (37,
Logbook hook on) and `/tmp/integ080/pp2/scen_p2_off.lua` (16, the default), `lua5.4 /tmp/integ080/smoke/main_boot.lua
<Scripts>` (boot + hot reload of main.lua, `modules=33/33` with the 0.8.0 Scripts; the 0.10.0 boot line says
`modules=42/42`, 0.12.0's `modules=46/46`).

Force it: `couch takeover` / Ctrl+F6 for a PC without a car, `SlotMode = "auto"` with a guest that did not get a
slot, or `AllowMidRaceJoin = true` + F6 in a race.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-TKO-01 | the car obeys the guest | Ctrl+F6 | per-step log; the pad drives that car only | `TakeoverIdleAI = true`, `TakeoverForceRawInput = true`; `TakeoverBindInput = false` if the rebind disturbs |
| V-TKO-02 | AI car test / overrides | F9 at countdown and race | override reasons per AI car recorded; a free AI car is found | `TakeoverAICarTest = "override"` |
| V-TKO-03 | PlayerState adoption | log `rec.aiCtrlHadPS`; read back `pc.PlayerState` | equals the AI racer PS | `TakeoverAdoptPS = false` |
| V-TKO-04 | HUD/position follow adoption | race | guest HUD position valid, `FindRacerIndexByPlayer >= 0` | report (position patch from the racer PS) |
| V-TKO-05 | remote adoption replicates | network takeover, client F9 | client `PC.PlayerState == Pawn.PlayerState`; client guest HUD lap/position and tags follow | `RacerPSSource = "controller"` |
| V-TKO-06 | release on controller destroy | F7 on a taken-over guest; a client quits mid-race | AI resumes, no crash, racer entry intact | report (release from `"leaving"` only) |
| V-TKO-07 | results not blocked | race with a takeover, `TakeoverAdoptPS` true and false | adopted: results, no `marked finished` line; non-adopted: `racer PS … marked finished` then results; note `bHaveCheatsBeenUsed` | `FinishIdlePlayerStates = false`; `FinishUncarriedRacers = true` |
| V-TKO-08 | game's own disconnect path | F7 on a native-slot guest (`Debug = true`) | `OnHumanSwitchedWithAI` / `ControllerAssigned` / `PossessedPawnChanged` lines | report |
| V-TKO-09 | mid-game joiner | a client joins after the start | `isMidGameJoiner` true, no takeover | `TakeoverMidGameJoiners = true` (if wanted) |
| V-TKO-10 | P1 audio | `ReRegisterP1Pawn = true` | passby/overtake audio on P1's car | keep `false` |
| V-TKO-11 | remote end-spectate | network takeover of a remote PC | `Client_OnSpectatorModeEnded sent`, harmless | `TakeoverEndSpectateRemote = "off"` |
| V-TKO-12 | remote player drives a taken car | `HostTravelFallback = "relisten_takeover"`, client + guest | `remote: ResetComponent:Client_BindInputActions() sent`; the client's pad drives | `TakeoverBindInputRemote = false` |

### 0.9.0 checks: campaign planet arc and run map (§1.8), 3-player HUD
Order: P1 alone, landspeeder (6 planets) -> podracer (7 planets, the arc spreads to ~41°) -> BACK / forward across steps
-> VEHICLES with a guest (3D cards) -> START -> reopen the setup after the race (menu replaced) -> Ctrl+F11 in the step.

| Id | Check | Pass (log / screen) | Fallback |
|---|---|---|---|
| V-CMAP-01 | build | `[cmap] built: planet view on (arc 7200 su x0.85, area 3500x1080, 8 chips), track map on (3500x1200)` (classic); 0.12.0: `[cmap] built (UI v2): planet view on (arc 7200 su x0.85, area 3500x1080, 8 discs), track map on (3584x1316) (V-CMAP-01)` | `SetupCampaignMap=false` |
| V-CMAP-02 | the arc is fed | `[cmap] planets: 6 (Mastiff,...), SetPlanetVms ok, 6 button(s), selected 1, arc 35.0 deg` | the in-place `PlanetVMs` path is logged instead |
| V-CMAP-03 | selection follows | dbg `select 3 -> selector index 2`; never `selector index N != M` twice | lists |
| V-CMAP-04 | the arc ticks | `selector ticks (target offset ...)` | WARN `does not tick: UpdateButtonPos from the FAST loop` = manual mode |
| V-CMAP-05 | chips with the pad (v2: the planet discs) | left/right moves along the chips and the arc slides with the scroll sound; A on a chip opens the run map | `SetupCMapPlanetNav="list"` |
| V-CMAP-06 | look | screenshot: the arc across the area, the selected planet enlarged at the top, all planets bright, no ship/trophy, name + description under it; beside it the video (classic) or the planet's Arcade art for the class (v2) | tune `SetupCMapArc*` / `Area*` |
| V-CMAP-07 | focus | P1's focus stays on the chips / nodes (no lost focus after the arc is built) | report |
| V-CMAP-08 | run map | `[cmap] run map built ...`, `map Mastiff: 8 circuit(s), 23 node(s) ...`; the planet turns; d-pad moves between nodes; the card follows; A on a node -> CONDITIONS / MODE | `SetupCMapTrackView="list"` |
| V-CMAP-09 | video (`SetupCMapVideoW > 0`: classic, or set in `config_user.lua`; the v2 default `0` shows no video) | the planet video plays beside the arc (v2: inside the art frame); `video restored ...` at the run map / VEHICLES / close; no audio from a hidden image | `SetupCMapVideoW=0` |
| V-CMAP-10 | teardown | tab left, START, the menu replaced after a race, Ctrl+F11 in the step: no error | report |
| V-CMAP-11 | VEHICLES unchanged | the 0.8.0 V-VP lines | — |
| V-CMAP-12 | off | `SetupCampaignMap=false`: `[cmap] campaign views off`, the 0.8.0 lists | — |
| V-HUD-15 | 3-player HUD (**PASS run M**, live: the slot stretch was needed too) | 3 players: P2's and P3's timer, lap and POS fully visible in their quarter views; P1's bar unchanged; `HUD top bar fits its view` per player | `HudFitInterior=false` |

Run L / run M (0.9.0: `InputFixP1VehicleOverUi`, `MenuBridgeSharedFocus`):

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-INP-09 | P1's buttons in a split race (run L; **PASS run M**: "It worked") | P1 presses LB (ability) and R3 (change boost) while racing; then pauses and navigates the pause menu | run M: `P1 racing: IMC_UI 0, vehicle IMC_Vehicle_Default 0, IMC_Vehicle_Keyboard 0` (a tie that IMC_UI won) and `P1 vehicle input over the UI context: IMC_Vehicle_Default 0 -> 1 (IMC_UI at 0)`; the ability fires, the boost type changes; on pause `P1 vehicle input back to its own priority (pause)` and the menu answers P1's pad | `InputFixP1VehicleOverUi=false` |
| V-MB-07 | results screen owned by a guest (3P: P3) | P1 presses A on the results | `P1 focus on WBP_SimpleRaceResultsScreen_C (...)`; P1's A leaves the results (no mouse) | `MenuBridgeSharedFocus=false` |

### Session R: 0.10.0 RACERS step (run live 2026-10-10)
Three launches on the hotfix build CL382493 (UE4SS Galactic Racer Edition), window 1280x720, 4 pads (pad 2 joined;
pads 3-4 joined for the 3P / 4P checks, else connected but not joined), a test copy with `TestCommands = true` (the
`test.cmd` helpers `setup.debugJump{class = "Car", planet = "Mastiff"}`, `racers.event`, `racers.status()`) and
640 x 360 previews. Logs and screenshots: `state/runs/20261010-0213-racers-v2/`, `20261010-0238-racers-v2b/`,
`20261010-0244-racers-v2c/`; facts: `notes/research/live-run-racers-facts.md`.
`grep -E '\[SWGRCouch\]\[(racers|cards|perkapply|vpreview|feowner|menubridge)\]' UE4SS.log`.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| (boot) | 0.10.0 loads (**PASS** in all three launches) | boot to the main menu | `[main] SWGRCouch 0.10.0 loading: ...`; `started: loops fast=5 main=6 slow=7 (33/250/1000 ms), modules=42/42, phase=BOOT`; `[feowner] init 0.10.0: main menu owner P1 ...`; no `[SWGRCouch]` ERROR line, no crash dump | report |
| V-INP-10 | the input filter DLL matched this build (**PASS**) | ADD PLAYERS; then a race | `[inputfix] native filter loaded: installed=1 reason=ok build=382493`; in the race `every local car reads its own raw input: native filter + contexts on (ctrl 0 own, ctrl 1 bound, ...)`. (The Run-G table uses V-INP-10 for the pad order.) | `reason=` names the mismatch: report (the Lua-only `kbsplit` isolation runs) |
| V-RC-01/02 | cards built, P1's pad on the sink (**PASS**) | CHOOSE RACE (v2: the RACE card) to RACERS (or `debugJump`); P1 d-pad right / down / up | `[racers] built (4 card slots, P1 sink sink, 1.0 ms) (V-RC-01)` (0.12.0: `... 1.0 ms; renderer cards2, UiStyle v2) (V-RC-01)`), crumb `STEP 5/5 RACERS` (v2: the step row's RACERS item is current), no tofu; one `[racers] P1 sink <dir> (V-RC-02)` per press; `racers.status()`: `sink events n, drops 0, leaks 0`. On the first setup open: `[setup] track pools 'arcade': 73 TrackDef(s) (game data) (V-TRK-01)` | `CardP1Input = "geometric"`, then `SetupPlayerFlow = "classic"` |
| V-RC-15/16 | layouts and build cost (**PASS**) | 2, 3, then 4 players | `[cards] layout: 2 player(s), class W ..., cards 1720 su, gap 60`, `3 player(s), class M ..., cards 1140 su, gap 40`, `4 player(s), class N ..., cards 845 su` (0.10.0 / classic; 0.12.0 v2: `[cards2] layout: 2 player(s), class W (was nil), cards 1762 su (design 1762 x 1300), gap 60 (V-RC-15)`, then class M 1162 su gap 49, class N 860 su gap 48); `card n: shell built (W): 65 widgets, <t> ms`, `pilot panel built (W): 87 widgets, <t> ms` (88 after the run-1 layout fixes; live 1-6 ms each); `dbg loaded <texture> in <t> ms (big) (RC-9)` one per tick (typically 4-8 ms); nothing clipped (`rc-05-3p-mixed.png`, `rc-06-4p-mixed.png`) | lower `CardH`; lower `CardBuildsPerTick` / `CardLoadsPerTick` |
| V-RC-31 | the page belongs to P1 (**PASS**, also right after a split race) | enter RACERS before and after a race | `[racers] enter Car (new visit, n player(s)); page owner BP_GfnPlayerController_C_<n> (P1) (V-RC-31)` | keyboard + mouse |
| V-RC-11/12/13 | pickers (**PASS**) | P1 on PERKS: A on a part slot, left/right = category, up/down, A = equip; the same on an ability and a trait | the category pill with `n / N`, tier pips, a tick on the equipped item, the detail card (+ large art on 1-2-player cards); another part makes the kit row `LOADOUT: CUSTOM · FROM <kit>`; ability and trait pickers equip (`rc-03-2p-picker-ready.png`) | — |
| V-RC-04 | joins and leaves mid-step (**PASS**) | pads 3, 4 press A; later a guest holds B 1.4 s | `[join] P3 JOINED`, the layout goes to M, then N, the new card starts at PILOT; leave: `[racers] P3 (ControllerId 2) left: card removed, bay released, picks kept for the pad (V-RC-04)`, `[vpreview] bay 3 released (P3 left): 3 actor(s) destroyed (V-VP-07)` | raise `CardBackTapMaxMs` |
| V-RC-14/18 | quick path, all READY (**PASS**) | A, A, A on each card | `[racers] P2 READY after 3 presses (pilot ..., kit pilot) (V-RC-14)`; `all 4 players READY (P1: A TO START) (V-RC-18)`; status `ALL READY · P1: A TO START`, P1's row `START RACE · ALL READY` (`rc-07-4p-all-ready.png`) | — |
| V-RC-35 | START with un-joined pads (**PASS**) | pads 3, 4 connected, not joined: START; START again 11 s later; then two STARTs 1.2 s apart | first START: `[setup] PADS 3, 4 ARE NOT JOINED: START AGAIN FOR AI CARS`, the page stays; 11 s later the gate warns again (window 5 s); two STARTs within 5 s: `[launch] WARN launch with un-joined guest(s) accepted by the race setup's second START: PADS 3, 4 ARE NOT JOINED (V-RC-35)`, `[join] 2 PADS NOT JOINED: THEIR CARS ARE AI-DRIVEN`; those pads race AI-driven in their own views | join the pads (A) before START |
| V-RC-19/20 | launch base, pilots (**PASS**) | START RACE | `[perkapply] VBD_000_1Mastiff UnlockedAffixSlots 4 -> 6, MaximumAffixSlots 10 -> 10 (in memory for the LaunchCustomRace call; V-RC-19)`, then `... 4 -> 6 -> 4 (after call; V-RC-19)`; `pilots: P1=<id> P2=<id>; AI re-assigned n (V-RC-20)` and per re-assigned AI `AI <old> -> <new> (a human's pilot; PlayerState.Pilot set, name '<name>') (V-RC-20)`; the results list no human's pilot among the AI (`rc-12-results.png`, run 2) | `PerkApply = "passives"` |
| V-RC-21/22/23 | loadouts, traits and pilots in the race (**PASS**) | same; PRERACE | front end `loadout: P1 build[Car e0]: lv 10/2/0/6/5/8 PL31 abil ... crash ... parts 4/6 ... (plan) (V-RC-21)`, `apply (full, Car): P1 ok P2 ok`; race `loadout: P1 in race: build ok, abilities 4/4, crash ok, parts 4/4 live (V-RC-21)`, `loadout: P1 traits: 3 of 3 applied, PassiveList 4 -> 7 (V-RC-22)` (+3 per human, not +6), `pilot: P1 PlayerState.Pilot = <id>, the pick (V-RC-23)`; each view's HUD shows its own ability cluster (`rc-10-race-hud.png`) | `PerkApply = "passives"`; `PerkTraits = false`; `PilotSeatCheck = "refresh"` |
| V-MB-01/02 | results: another player's A (**PASS**) | finish; P2 presses A | `[menubridge] P2 A -> WBP_SimpleRaceResultsScreen_C WBP_Common_Btn_Continue (focused): clicked (V-MB-01/02)`, then FRONTEND | `MenuBridge = false` |
| V-MB-08 | results: P1's A (**FAILED**, task #10 open) | P1 holds A on the results | expected `P1 A read from its raw vehicle input on WBP_SimpleRaceResultsScreen_C (V-MB-08)`: never logged; the screen stays (`rc-13-after-p1-a.png`). Probes: P1's `EnhancedPlayerInput.ActionInstanceData` has no `IA_Veh_Boost` entry, `IA_UI_Accept` TriggerEvent 0, `IsInputKeyDown(Gamepad_FaceButton_Bottom)` false | another player presses A |
| V-MB-09 | results: P1's A (0.10.1 catcher) | P1 presses A on the results | `P1 catcher button added to WBP_SimpleRaceResultsScreen_C (V-MB-09)`, `P1 A read from the catcher button on ... (V-MB-09)`, `P1 A -> WBP_SimpleRaceResultsScreen_C WBP_Common_Btn_Continue (focused): clicked`, then `POSTRACE -> LEAVING` (passed 2026-10-10, run catcher-test) | `MenuBridgeP1Catcher = false` |
| V-MB-10 | a guest's own pause menu (**PASS** 2026-10-10) | P2 pauses, D-pad to RESTART RACE, A; after a restart: SETTINGS, A on a row twice, B, B | `[menubridge] P2 A -> WBP_PauseRacing_C Btn_RetryRace (owner focus): clicked`; after a restart `P2's native A / B did nothing on its own pause menu (world #9): its presses on its own screens are bridged until the next world`, one toggle per A in Settings, `P2 B -> WBP_Settings_C: HandleBack() (V-MB-03)` | `MenuBridgeGuestPauseMenu = false` |
| V-FEO-01/02/07/12 | the main menu is P1's after the race (**PASS**) | back in the front end after the split race | `[feowner] PickPrimaryMode: WBP_FE_MainMenu_C pre-created for P1 (pc <n>, 4 local PCs) z=500 (V-FEO-01)`, `pre-created WBP_FE_MainMenu_C (PickPrimaryMode) acquired by the front-end CSM after <t> ms: extra ref released; input mode refresh ok (V-FEO-02); owner P1 (V-FEO-12)`; `Multiplayer tab hidden while 4 local player(s) exist: enabled set, visibility set (V-FEO-07)`; P1's pad drives the menu (LB / RB glyphs, `rc-15-after-settings.png`) | `FrontEndMenuOwner = "game"`; `FrontEndHideMultiplayer = false` |
| V-FEO-13/11 | Settings after the race (**PASS**) | P1's X, then P1's B | `ChangeStateTo(CSM_FrontEnd_Settings): WBP_Settings_C pre-created for P1 (...) z=500 (V-FEO-13)` + `acquired ...; owner P1 (V-FEO-12)`; B: `WBP_Settings_C Back: WBP_FE_MainMenu_C pre-created for P1 (...) (V-FEO-11)` and P1's main menu is back | `FrontEndSubScreens = false` |
| V-RC-25 | picks survive a restart (**PASS**) | START (or SAVE AND RETURN), quit, restart, open RACERS | `[racers] LastRaceRacers saved for ControllerId 0, 1 (2 pad(s) on file) (V-RC-25)`; after the restart `picks of 2 pad(s) restored for archetype 0 (V-RC-25)`: P1's KATJA MOX with the custom loadout and P2's pick come back | clear `LastRaceRacers` in `settings.txt` |
| V-RC-32 | pods on the cards (**PASS**; no pod race yet: V-RC-24) | RACERS on TATOOINE / MOS ESPA SPEEDWAY (`debugJump{class = "Plane", planet = "Beagle"}`) | `[perkapply] systems Plane: ramjet false, critmalf false (VBD_000_1Mastiff_Plane reads false / false; ...) (V-RC-32)`; 8 pod pilots in the roster (`1 / 8`); DUD BOLT's style VULPTEREEN 327 with his head shot as the icon (untinted); sixth upgrade row AIR BRAKE; `LOADOUT: VULPTEREEN 327 KIT` (`rc-09-pods-pilot.png`, `rc-13-pods-perks.png`) | `PerkHideInert = false` |
| (pause) | the game's inactivity auto-pause | nobody gives game input for ~60 s in the race | `game paused by none (unknown: the menu keeps its owner)`: the game's own pause, not a mod fault; resume + stick input continues | a keep-alive script for unattended runs (`tools/keepalive.sh`, a development tool) |

Layout fixes after run 1 (confirmed in runs 2-3): the section rules (a texture-less image drew a 32-su bar), the style
title / subline spacing, the READY `<pilot> · <vehicle>` line vs the style name, the PERKS POWER inset, the centred
VEHICLE info line, untinted pod style icons. Not run live yet: V-RC-03, V-RC-07, V-RC-08, V-RC-10, V-RC-24, V-RC-26 to
V-RC-30, V-RC-34 and the 960x540 preview default.

### Session S: 0.11.0 narrow-view HUD (measured live 2026-10-10: no bigger text, kept opt-in)
User: "HUD is bad on screen where width is 1/2, fix that." Design: `notes/research/hud-narrow-views.md`. A race with 2
players side by side (`Layout2P = side-by-side`), then F8 to top / bottom, then 3 and 4 players; window 1280x720.
`grep -E '\[SWGRCouch\]\[hud\].*(V-HUD-1[5-9]|narrow|designer layout|engine row)' UE4SS.log`.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-HUD-17 | narrow layout (opt-in) | `HudNarrowViews = "readable"` in config_user.lua; race, 2P side by side; screenshot | per HUD `P2 HUD: narrow view 1920x2160: interior 2000 (scale 0.96), top bar compact, engine row x0.79 (V-HUD-17)` (P1's clone adds `, portrait hidden`); expected timer, LAP and POS about 1.8x the 0.10.0 size (**measured 2026-10-10: the same size**), nothing touches a view edge, the whole engine row visible (energy pips to the ramjet end) | `HudNarrowViews="fit"` |
| V-HUD-18 | layout switches | F8 mid-race (top / bottom), F8 back; a guest leaves (F7); the results | `P1 HUD: view 3840x1080, designer layout (V-HUD-18)` and back to `narrow view`; at the results (one view) P1's HUD `view 3840x2160, designer layout`; no `layout ... failed` | `HudNarrowViews="fit"` |
| V-HUD-19 | interior width kept | one tick after V-HUD-17 | `P2 HUD: interior 2000 wide, 2000 planned; engine row 2417 wide, 2417 planned (V-HUD-19)` (an engine row a few units wider is re-planned once: `engine row measured <n> wide (estimate 2417): re-planned`; a narrower one keeps the estimate); never `V-HUD-19 FAILED` (that turns the layout off for the session) | `HudNarrowViews="fit"` |
| V-HUD-15 | fit | each HUD | `P2 HUD top bar fits its view (ScaleToFitX, DownOnly) (V-HUD-15)` | `HudFitInterior=false` |

### RESTART RACE (0.11.0), live 2026-10-10
2 players, hotfix build, 1280x720.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-RST-01 | offered (**PASS**) | FREE MODE race, RACING | `RESTART RACE offered in this race (standalone, confirm dialog, sequence direct) (V-RST-01)`, again after every restart | `PauseRestart = false` |
| V-RST-02 | the row (**PASS**) | P1 pauses (P2 too) | `RESTART RACE added to WBP_PauseRacing_C (owner P1, pre-create): Btn_RetryRace at 4 of 10 under RESUME (5 row(s) moved below it), label MenuText.Pause_Button_Restart 'Restart Race'`, then `row(s) found off 0 ms into the pause, switched on: RetryRace, Stickerbook, Settings, Photomode, Exit, AbandonRun`; every row black, the D-pad walks the whole list both ways | `PauseRestartPosition = "end"` |
| V-RST-03 | confirm (**PASS**) | A on RESTART RACE, then ACCEPT (CANCEL first: nothing) | `restart confirmed by P1 (RetryRace dialog Accept -> ArcadeSubsystem:RequestRestartEvent pre-hook) (V-RST-03)`; CANCEL: no `[restart]` line | `PauseRestartConfirm = "twice"` |
| V-RST-04 | a guest restarts (**PASS**) | P2 pauses, D-pad, A, A | `P2 A -> WBP_PauseRacing_C Btn_RetryRace (owner focus): clicked`, `P2 A -> dialog WBP_Modal_C (Dialog:1) button 1/2 'Accept' (focused): clicked (V-MB-05)`, `restart confirmed by P2` | — |
| V-RST-06 | the restart (**PASS**) | after V-RST-03 / 04 | `restart #1: RequestResetRace sent from the pause, 36 ms after the confirm (requested by P1)`; RACING -> LEAVING -> TRANSIT -> PRERACE (same map) -> RACING; `loadout: P1 in race: build ok, abilities 4/4, crash ok, parts 4/4 live`, both pilots the picks (V-RC-21/23) | `PauseRestartSequence = "resume"` |
| V-RST-07 | hook life (**PASS**) | same | `native pre-hook unregistered (leaving (restart))` before RACING -> LEAVING; registered again in the new race | — |
| V-RST-05 / 08 / 09 / 12 | arcade guard, watchdog, remote, `"twice"` | not run live | see `restart.lua` | — |

### Session U: 0.12.0 UI v2 (run live 2026-10-10)
The UI v2 pages at 1280x720, 1920x1080, 3840x2160 and 1280x800 with the game started in English, German and French
(Japanese, Chinese (Simplified), Korean, Polish, Turkish and Arabic only switched in a running game, see §1.11), 1 to 4
players, on the hotfix build CL382493 with the UE4SS Galactic Racer Edition.
`grep -E '\[SWGRCouch\]\[(theme|lobby|setup|cmap|cards2|racers|backprompt|vehicles|vpreview|perkapply)\]|text overflow|RACER CARD ERROR' UE4SS.log`.
The numbers in the lines below are the live ones. The fallbacks are the §7.2 UI v2 keys; `UiStyle = "classic"` is the
fallback of the whole page set. The older rows that UI v2 changed say what v2 logs: V-TAB-07, V-LOB-01/04/07/08,
V-BLD-01/04, V-SET-01/02, V-JOIN-05, V-JOIN-20, V-HUD-11, V-CMAP-01/05/06/09, V-RC-01, V-RC-15.

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| (boot) | 0.12.0 loads (**PASS**: `modules=46/46`, live 2026-10-10) | boot to the main menu | `[main] SWGRCouch 0.12.0 loading: ...`; `started: loops fast=… main=… slow=… (33/250/1000 ms), modules=46/46, phase=BOOT`; no `module … failed to load` | report |
| (release zip) | the release installs and runs (**PASS**, live 2026-10-10) | unzip `SWGRCouch-0.12.0-with-UE4SS.zip`, `./install.sh <game>`, boot with the release defaults (`Debug = false`), one race from RACE SETUP and back to the menu | `SWGRCouch 0.12.0 loading`, `modules=46/46`; one `launch hold` line; `AI builds (8 AI, launch base VBD_011_2Dal): PowerLevel min 6 / avg 6.0 / max 6, abilities 1.0, parts 0.0 per AI` (Opponents TIER 2); no ERROR line | report the log |
| (matrix) | every UI v2 page (**PASS** at 1280x720, 1920x1080 and 3840x2160; English, German, French) | the lobby with 4 players, OPTIONS, every RACE SETUP step, RACERS with 2 and 4 players on every stage | the pages line up with the game's own (tab bar, profile card, action bar), no clipped or overlapping text, no `RACER CARD ERROR` | `UiStyle = "classic"`; report a screenshot |
| V-FIN-01 | page geometry | open the FREE MODE tab, OPTIONS, RACE SETUP | `[theme] page geometry: x 128 y 232 w 3584 h 1764 (source layout; GetCachedGeometry returned no fields), screen 0..3840 x 2160, cmdY 1880, CardH 1300 (V-FIN-01)` | `UiPageOrigin = {x, y, w, h}` |
| V-FIN-02 | page background | RACE SETUP (`hub`; `map` on PLANET / TRACK), OPTIONS | `[theme] page background 'hub' on the page canvas at local -128,-232 (screen 0..3840), z -10 (V-FIN-02: ...)`; it reaches under the tab bar and the profile card | report (the background's z order / slot is a code change) |
| V-FIN-03 | page title | RACE SETUP, OPTIONS | `[theme] screen title 'RACE SETUP': WBP_Screen_Title in a 2700 x 150 box at screen (128, 249), cap top 285 expected (V-FIN-03)`; `/RACE SETUP` and `/OPTIONS` not clipped | `UiTitleBoxH = 256`, then `UiTitleWidget = "text"` |
| V-FIN-04 | ghosts keep the focus | pad, keyboard and mouse on the posters, the OPTIONS list, the setup posters | `[lobby] tile navigation: 8 of 8 explicit rule(s) of the §4.6 graph on the ghosts (V-FIN-04)`, `P1's CommonUI focus is on the 'start' ghost; the painted look follows it (V-FIN-04)`, `[theme] mouse hover seen on a ghost (IsHovered works, V-FIN-04)`, `[lobby] OPTIONS page built: 8 rows, detail column ok, BACK ok, focus traps ok (V-FIN-04)`, `OPTIONS: pad right on 'net' through the focus trap (V-FIN-04)` | report |
| V-FIN-05 | studio photo bay (**PASS** live: max delta 7) | `PreviewCalibrate = true`; RACERS > VEHICLE | `[vpreview] bay 1 backdrop studio: back plane STUDIO x 1.00 + lit floor #B9B4AB, exposure fixed at EV100 8.00 (V-FIN-05)`, then `bay 1 backdrop studio: RT corner (28, 21) #DCDBD8, target #E3DFD6 +-8, gain 1.00, exposure fixed at EV100 8.00, floor #8C8072: PASS (max delta 7) (V-FIN-05)` | a `FAIL` line names a `PreviewStudioGain` to try (`vpreview.calibrate()` reads again); `PreviewBackdrop = "scenario"`, then `"cutout"` |
| V-FIN-06 | player stripe | RACERS > PILOT | `[cards2] init: 4 card slots (v2 posters; head shots mid, glyphs xbox, pod figure mid, player stripe on at 34 deg, backdrop studio) (V-RC-01, V-FIN-06, V-FIN-07)`; the stripe in the player's hue leans like the poster's own stripes and stays inside the art window | `CardStripeAngle = -34`; `CardStripe = false` |
| V-FIN-07 | tints | CONDITIONS of a track with several conditions; a pod pilot's empty poster | `[setup] condition tint: MI_UI_Squircle_TextureMask MID on the CONDITIONS poster art (V-FIN-07: ...)`; `[cards2] pod figure on the empty poster: MI_UI_Squircle_TextureMask MID, TileColor #…; a black box or an untinted body = CardFigureTint "plain" (V-FIN-07)` | `UiCondTint = false`; `CardFigureTint = "plain"` |
| V-FIN-08 | trait glyph (**PASS**) | CLASS, Landspeeder | `[setup] CLASS info panel: WBP_DarkPanel, WBP_SectionSubLabel, 3 WBP_VehicleTrait, trait glyphs decorator (V-FIN-08: ...)`; DRIFT reads "Use (X) to drift sharply while maintaining speed." with the X on an amber disc | `UiTraitGlyph = "runs"` |
| V-FIN-09 | no text overflow (**PASS**: no line in the matrix logs) | every page and card stage at the three resolutions, 1-4 players | no `[cards2] WARN text overflow card …` line; F9's racers line reads `text overflow 0` | fix the text's table entry (texts are never shrunk) |
| V-FIN-10 | model names | RACERS > VEHICLE | `[vehicles] model names Car: 12/12 from TH_<Model>.ItemName (12 resident, 0 loaded; source load), 0 from the decoded English table; Beluga = ARZ 41 (V-FIN-10)`; in another game language the line lists the names that differ from the English table | `VehicleNameSource = "find"`, then `"table"` |
| V-FIN-11 | input mode | RACERS, every card READY: nudge the mouse during pad play; then use the mouse; then the pad again | a short nudge does not flip the command row; `[theme] input mode -> mouse (stable … ms) (V-FIN-11)`, `[setup] command row: SAVE AND RETURN, START RACE, BACK (P1 input mouse) (V-FIN-11: START RACE is never shown twice)`, `[racers] P1 input mode pad -> mouse: P1's card READY pill, START / SAVE in the command row (V-FIN-11)` and back | `InputModeDebounceMs` higher |
| V-FIN-12 | status pill | any message (e.g. A on a locked START RACE) | `[theme] status pill first shown from the screen's left edge, bottom y 2139 (1 line: centre 2079) (StatusPillPlace screen, V-FIN-12): <text>`; not clipped; a 2-line message grows upward | `StatusPillPlace = "page"` |
| V-FIN-13 | P4's colour | a 4-player race on a bright track; the menus | P4's Crait-red tag readable; not mistaken for the menus' rust accent | a code change in `consts.lua`: `C.COLOURS[4] = C.COLOUR_P4_SAND` and the INK colour for `C.COLOUR_INK[4]` |
| V-FIN-14 | frame cost | 4 cards and 4 photo bays with backdrops | frame rate close to 0.11.0; F9's racers line `cards2 4 (N), widgets …` within the design budget of about 1.6k (live: `widgets 1236` with the four cards on PILOT, VEHICLE, PERKS and READY) | `PreviewStudioFloor = false`; keep `CardBuildsPerTick = 1` |
| V-FIN-15 | OPTIONS back route (**PASS** for P1's B) | OPTIONS: P1's B, Backspace, BACK, LB / RB | `[lobby] OPTIONS closed (pad B (the game's Quit prompt)): the tiles are back, focus on the OPTIONS tile (V-FIN-15)`; `Backspace: OPTIONS closed (V-FIN-15)`; no game prompt left on screen | close through BACK only (pad: down to it) |
| V-FIN-16 | command-row pills | RACE SETUP, OPTIONS; leave the tab and come back | `[theme] command row: back, start, save at y … (WBP_CommonButtonBacker_Pill pills, V-FIN-16)`; the focus look follows the focus; the colours survive the page re-show | `UiHeroPill = "painted"` |
| V-PARTS-02 / 08 | font materials, brushes | any v2 page | no `SetFont with a font material failed` / `UImage:SetBrush with a table failed` WARN (each switches to plain fonts / Image draws by itself) | `UiFontMaterials = false` (02) |
| V-BP-01 | pad B on OPTIONS / RACE SETUP (**PASS**) | before the first race: OPTIONS, P1's B; RACE SETUP on PLANET, P1's B; on the posters, P1's B | `[backprompt] QuitGame watch armed: 2 native pre-hook(s) on GfnMessagingSubsystem while OPTIONS / RACE SETUP shows (...) (V-BP-01)`; `QuitGame prompt over OPTIONS: answered No (1 click(s), 101 ms after the post), OPTIONS closed (V-BP-01)`; `QuitGame prompt over RACE SETUP: answered No (1 click(s), 102 ms after the post), one step back (V-BP-01)` and CLASS shows; on the posters no `[backprompt]` line and the game's prompt stays (CANCEL) | `BackPromptAsBack = false` |
| V-LCH-07 | launch hold (**PASS**: five launches in a row from RACE SETUP, back to the menu after each, no crash) | START RACE from RACERS; quit the race to the menu; repeat | `[main] launch hold: the front-end pages stop until the race world (V-LCH-07)` once per launch; no `Fatal Error!` | report the log and the crash dump |
| V-RC-27 | Opponents tier (**PASS**) | MODE: Opponents to TIER 4, START RACE; then TIER 1 (live: the five launches of V-LCH-07, TIER 1, 4, 1, 4, 1, `OpponentTier` set through the test harness) | a step on the MODE row logs `[setup] opponents: TIER 4 · CORGI (35%) (V-RC-27)`; `[perkapply] launch base VBD_035_4Corgi (opponents' tier; humans' empty ability slots are cleared) (V-RC-27)`; in the race `AI builds (n AI, launch base VBD_035_4Corgi): PowerLevel min 18 / avg 18.0 / max 18, abilities 2.0, parts 0.0 per AI (V-RC-27)`; TIER 1: `AI builds (n AI, launch base VBD_000_1Mastiff): PowerLevel min 0 / avg 0.0 / max 0, abilities 0.0, parts 0.0 per AI (V-RC-27)`; TIER 2: PowerLevel 6, abilities 1.0; the humans keep their loadouts: `loadout: P1 in race: build ok, abilities 4/4, crash ok, parts 4/4 live (V-RC-21)` | `OpponentTier = 1` in `settings.txt` |
| V-JOIN-20 | hot-plugged pad (**PASS**: P1 kept its working pad) | Session B row | `[join] hot-plugged pad ctrlId 3: P1 keeps ctrlId 0, whose pad is still connected (ADD PLAYERS makes the new pad a guest) (V-JOIN-20)` | `HotplugPadToP1 = "off"` |

### Session D: network (two machines on the LAN, then over WireGuard)
0.12.0 (UI v2): START HOSTING / STOP HOSTING and CONNECT / DISCONNECT below are OPTIONS > NETWORK's action row
(`Host on port 7777`: START / STOP, `Connect to <address>:7777`: CONNECT / DISCONNECT) or Ctrl+F7 / Ctrl+F8, and the
lobby's remote status is the players strip's network line (§3.1, §4).

| Id | Check | How | Pass | Fallback |
|---|---|---|---|---|
| V-NET-01 | user Engine.ini layer | both machines, first front end | the folder holding `GameUserSettings.ini` is the one patched; V-NET-02 passes; the block is still there after quitting the game | find the real `Saved/Config/Windows` folder; re-run `install.sh --prefix` |
| V-NET-02 | driver definitions | first front-end log (`[net] NetDriverDefinitions[..]`) | `GameNetDriver = /Script/OnlineSubsystemUtils.IpNetDriver: Engine.ini override active` | fix the section/path of the user Engine.ini |
| V-NET-03 | Iris | `IrisOff = true` on both; client with 1 guest | the cvar reads back 0; the guest's child connection works | `-UseIrisReplication=0` in the Steam launch options of both, or the `[ConsoleVariables]` lines of `Engine.ini` |
| V-NET-04 | listen reload | START HOSTING | front end reloads listening; tab reopens; guests kept; no boot flow | console `open /Game/Griffin/Maps/L_FrontEnd/L_FrontEnd?listen` by hand; report |
| V-NET-05 | travel options | CONNECT (default method) | `client travel options: N chars`; the join succeeds | `JoinMethod = "openlevel"` |
| V-NET-06 | console join | `JoinMethod = "console"` | the join succeeds | — |
| V-NET-07 | recipe survives relisten / servertravel | force the `relisten` path | the race restarts with the same track and everyone | `HostTravelFallback = "relisten_takeover"` |
| V-NET-08 | client guests split-join | a client with 1 guest connects | host Ctrl+F9: 2 remote PCs (1 child) with PlayerStates; both get cars at launch | takeover covers child PCs (Session C) |
| V-JOIN-08 | client guest PC after return | client with 1 guest back in the host's front end | the guest stays joined; its PC appears within a few seconds | report |
| V-NET-09 | core-object ack | client with a guest, race loads | no stall before the countdown (WaitForClientsToBeReady) | `GuestAckMode = "all"`, then `"off"` |
| V-NET-10 | login / identity | host log at each join | `HandleStartingNewPlayer` per remote PC (child included); no `incompatible_unique_net_id` | uncomment `CompatibleUniqueNetIdTypes` in `Engine.ini` with the logged type |
| V-NET-11 | front-end login gate | host log while hosting | `IsAnyLoginPending=false` once the clients are in | report (native gate) |
| V-NET-12 | PvP systems silent | 3 races in a row | no AFK kick, no player-data disconnect | `NetSafetyCvars = { "Pvp.FakeProgressionAuthKillswitch 1", "Pvp.StopTrackingAFK 1" }` (names in the exe; value format unverified) |
| V-NET-13 | **launch travel carries clients** | host START RACE with a connected client | `checkTravel(1): native networked travel carried every client`; no fallback | `HostTravelFallback` (`"relisten"` default; `"relisten_takeover"`); `ServerTravelOnMissingCars = true` |
| V-NET-14 | failure hook / rejoin | stop the host mid-session | client logs the failure type and string, auto-rejoins when the host listens again | `AutoRejoin = false` to stop the loop |
| V-NET-15 | listening check | after START HOSTING | `listening: live NetDriver = …`; `isListening()` true | report (drop the NetDriver term) |
| V-NET-16 | servertravel accepted | relisten path ends in servertravel | the world changes within `ServerTravelWatchdogMs`; no `servertravel was not executed` | raise `ServerTravelWatchdogMs`; `HostTravelFallback = "relisten_takeover"` |
| V-NET-17 | client front-end menu | a client connects to the host's front end | `client front end (V-NET-17, check 1): main menu present`; our tab reopens | `ClientMenuFallback = "csm"` (default), then DISCONNECT (Ctrl+F8) |
| V-NET-18 | STOP HOSTING stops | host, one client joins, STOP HOSTING | the new front end is standalone; the client gets a network failure; no `STILL LISTENING` | `StopHostingMethod = "disconnect"` |
| V-NET-19 | client quits via the pause menu | client in a race: pause → Quit | `left the host through the game's menu`; no auto-rejoin; lobby says NOT CONNECTED | `RejoinAfterQuitToMenu = true` |
| M6 | WireGuard | repeat Session D between two homes | ping and rubber-banding recorded | `NetServerMaxTickRate` in `Engine.ini` (both), host on the stronger PC |
