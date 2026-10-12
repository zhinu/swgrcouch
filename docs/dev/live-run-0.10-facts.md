# Live facts, RACERS runs (2026-10-10 02:13-02:47 local), SWGRCouch 0.10.0, hotfix build CL382493

Setup: the hotfix game copy (`~/Games/StarWarsGalacticRacer-SWGRCouch-hotfix`, CL382493), UE4SS Galactic Racer Edition,
window 1280x720, 4 virtual pads (`tools/vpad.py`; ADD PLAYERS made a dormant guest for pads 2-4, pad 2 joined). The test
copy's `config_user.lua` had `TestCommands = true` and 640x360 preview targets (every bay logs `target 640x360`; the
960x540 default was not run live). Steps were driven through `test.cmd` (`setup.debugJump`, `racers.event`,
`racers.status`), vpad presses and screenshots. UE4SS.log timestamps are UTC (local = UTC+2). Spec:
`notes/design/vehicle-step-v2.md` (written for "0.11.0", shipped as 0.10.0). Three launches:

| Run dir (`state/runs/`) | Log | What |
|---|---|---|
| `20261010-0213-racers-v2` | `UE4SS-023449.log` | 2P stages and pickers, pads 3-4 joining and leaving (3P, 4P), START gate, race 1 (JAKKU / DEBRIS DUNES / SUNSET, landspeeders, 2 humans + pads 3-4 un-joined), results, front end after the race, Settings |
| `20261010-0238-racers-v2b` | `UE4SS-024426.log` | the run-1 layout fixes and the AI-pilot fix (below), pods (TATOOINE / MOS ESPA SPEEDWAY), race 2 (same track), results, RACERS again after the race |
| `20261010-0244-racers-v2c` | `UE4SS-024647.log` | a game restart: picks restored, final screenshots; no race |

## Boot (all three launches)
- `[main] SWGRCouch 0.10.0 loading: EngineTickAvailable=true ProcessEventAvailable=true GT=EngineTick UE=5.7 ...`, then
  `[main] started: loops fast=5 main=6 slow=7 (33/250/1000 ms), modules=42/42, phase=BOOT`.
- 0 `[SWGRCouch]` ERROR lines in the three logs; no crash dump.
- `[feowner] init 0.10.0: main menu owner P1 (pre-create on PickPrimaryMode + sub-screen returns), Multiplayer tab hidden
  with guests, z=500`.
- V-INP-10 (0.10.0 meaning: the DLL matched one of its two builds): `[inputfix] native filter loaded: installed=1
  reason=ok build=382493`. Race: the Lua write of `PlayerInputComponent.RawInputSubsystem` is refused
  (`[push_weakobjectproperty] Error:`, known since run N1), the native copy binds each guest car (`raw input bound by
  the native copy ... (verified by address)`), then `every local car reads its own raw input: native filter + contexts
  on (ctrl 0 own, ctrl 1 bound, ctrl 2 bound, ctrl 3 bound)`.

## RACERS step (front end)
- V-RC-01: `[cards] init: 4 card slots (frame darkpanel, pills pill, detail game, head shots mid, glyphs xbox, diamond
  disc) (V-RC-01)`, `[racers] built (4 card slots, P1 sink sink, 1.0 ms) (V-RC-01)`; crumb `STEP 5/5 RACERS`; no tofu.
- V-RC-02: `[racers] P1 sink wired: sink (V-RC-02)`; one `[racers] P1 sink right|down|up (V-RC-02)` per pad press;
  `racers.status()`: `P1 input sink (sink events 12, drops 0, leaks 0, B seen false)`: no drop, no leak in any status
  line of the three runs.
- V-RC-31: `[racers] enter <Car | Plane> (new visit, <n> player(s)); page owner BP_GfnPlayerController_C_<id> (P1)
  (V-RC-31)` on every entry (6 in the three logs), also right after race 2 (run 2: a new PlayerController after the
  travel, still P1).
- V-RC-15: `[cards] layout: 2 player(s), class W (was nil), cards 1720 su, gap 60`; `3 player(s), class M (was W), cards
  1140 su, gap 40`; `4 player(s), class N (was M), cards 845 su, gap 40`; back to M and W when pads left.
- V-RC-16 (`[cards] card n: <part> built (<class>): <w> widgets, <t> ms`): shell 65 widgets 1-6 ms; pilot panel 87
  widgets (88 after the section-rule fix) 1-3 ms; vehicle panel 39-40 widgets 1 ms; perks panel 232-235 widgets 4-16 ms;
  ready panel 57 widgets 0-2 ms; picker 130 widgets 2-3 ms. Each built in its own FAST tick.
- RC-9: `[cards] dbg loaded <texture> in <t> ms (big) (RC-9)`, one big texture per tick: 81 of the 90 big loads of the
  three logs took 3-8 ms; the slowest 16 ms (`T_UI_RacerStyle_Defence_Bg`) and 20 ms
  (`T_UI_VehicleSelect_Car_Fallback`).
- V-RC-17: bays keyed by ControllerId + 1 at X 0 / 20000 / 40000 / 60000 (spacing 20000); builds spaced by the gap
  (`bay 2: PRE_Car_Hammerhead_QuietStrength spawned ... (HAMMERHEAD, archetype 0, still, 306 ms after the previous
  build)`); `still burst of 8 capture(s) (ready)` and `(late parts)`; `bay n ready: ..., 403-451 ms, stable, still`;
  release summary `released (racers: start): 2 bay(s), 6 actor(s) destroyed; session 8 spawn(s), 0 rebuild(s), 8 ready,
  0 failed, 186 capture(s), 17 still burst(s), 5 build(s) spaced by the gap (V-VP-07, V-RC-17)`.
- V-RC-09 (screenshots only): a pilot another player holds is dimmed in the roster with the holder's tag (`P2` in P1's
  roster, `P1` in P2's: `rc-01-2p-pilot.png`, `rc-09-pods-pilot.png`).
- Pickers (V-RC-11/12/13): the parts picker shows the category pill with a counter (`ENERGY & ABILITIES 2 / 13`,
  `START & LANDING 4 / 7`), tier pips, the equipped tick and the detail card (+ large art in W). Equipping another part
  turns the kit row into `LOADOUT: CUSTOM · FROM <kit>` (`LOADOUT: CUSTOM · FROM RAMJET RIDER` in `rc-13-pods-perks.png`);
  ability and trait pickers equip too.
- V-RC-14: `[racers] P3 READY after 3 presses (pilot DA_Racer_Protege, PRE_Car_Orca_Protege, kit pilot) (V-RC-14)`; in
  run 3 all four pads reached READY with 3 presses each on their restored picks.
- V-RC-18: `[racers] all 4 players READY (P1: A TO START) (V-RC-18)`; status `ALL READY · P1: A TO START`, P1's row
  `START RACE · ALL READY` (`rc-07-4p-all-ready.png`).
- Joins / leaves (V-RC-04, V-VP-07): pads 3 and 4 joined mid-step with A (`[join] P3 JOINED`, `P4 JOINED`): layout M,
  then N, the new card at PILOT. A pad that held B 1.4 s left: `[racers] P3 (ControllerId 2) left: card removed, bay
  released, picks kept for the pad (V-RC-04)`, `[vpreview] bay 3 released (P3 left): 3 actor(s) destroyed (V-VP-07)`.
- V-RC-33: the detail tag's COST came from the native config CDOs (`[perkapply] energy cost Shield:
  Default__AbilityShieldConfig.EnergyCost = 1 (RC-4, V-RC-33)`, 7 abilities, all 1); no log line names a `BP_Ability_`
  class.
- V-TRK-01: `[setup] track pools 'arcade': 73 TrackDef(s) (game data) (V-TRK-01)` (setup.lua's VERIFY comment says 77:
  the 4 arcade-only pod tracks, left out while `SetupTrackArcadePods = false`); `tracks for Car on Mastiff: 17 listed,
  2 duplicate TrackDef(s) folded`.

## START gate, launch and race
- RC-1 / V-RC-35: with pads 3-4 connected but not joined, the first START logs `[setup] PADS 3, 4 ARE NOT JOINED: START
  AGAIN FOR AI CARS` and the page stays (`rc-09b-start-gate.png`, run 1). A second START 10.9 s later re-armed the gate
  (window 5 s, a second warning); two STARTs 1.2-1.3 s apart launched: `[launch] WARN launch with un-joined guest(s)
  accepted by the race setup's second START: PADS 3, 4 ARE NOT JOINED (V-RC-35)`, `[join] 2 PADS NOT JOINED: THEIR CARS
  ARE AI-DRIVEN`, `grid: PlayerChoice x5 -> PlayerChoice x4 + Car x8 (4 human(s), ...)`. The two pads raced as
  AI-driven players with their own views (four views, `rc-10-race-hud.png`).
- V-RC-19: `[perkapply] VBD_000_1Mastiff UnlockedAffixSlots 4 -> 6, MaximumAffixSlots 10 -> 10 (in memory for the
  LaunchCustomRace call; V-RC-19)`, then `VBD_000_1Mastiff UnlockedAffixSlots 4 -> 6 -> 4 (after call; V-RC-19)`.
- V-RC-20: `[perkapply] pilots: P1=DA_Racer_ElegantProfessional P2=DA_Racer_QuietStrength; AI re-assigned 1 (V-RC-20)`.
- V-RC-21, front end (plan): `loadout: P1 build[Car e0]: lv 10/2/0/6/5/8 PL31 abil Mine_Triple,Repair,Shockwave,
  Disruptor crash IonBlast_Overclocked parts 4/6 ramjet 1 malf 1 (plan) (V-RC-21)`, `apply (full, Car): P1 ok P2 ok`;
  in the race: `loadout: P1 in race: build ok, abilities 4/4, crash ok, parts 4/4 live (V-RC-21)` (P2 the same).
- V-RC-22: `loadout: P1 traits: 3 of 3 applied, PassiveList 4 -> 7 (V-RC-22)` for each human (+3, not +6: no double
  application).
- V-RC-23: `pilot: P1 PlayerState.Pilot = DA_Racer_ElegantProfessional, the pick (V-RC-23)` (P2 the same).
- The race recipe at PRERACE carried every human's pick (`race recipe: 12 racer(s): Car/PRE_Car_Beluga_Protagonist_C
  Car/PRE_Car_Hammerhead_QuietStrength_C ...`). The `WARN in-race override: P1 never overridden during LOADING (V-SET-11)`
  lines of runs 1-2 came from the classic in-race override; the final launch.lua (saved 02:44) skips it in the cards
  flow. Run 3 did not race, so that skip has no live run yet.
- V-INP-09 (0.9.0) unchanged: `P1 vehicle input over the UI context: IMC_Vehicle_Default 0 -> 1 (IMC_UI at 0)`, back on
  pause and at POSTRACE.
- The game's inactivity auto-pause (about 60 s without game input from any local player) paused a test race:
  `[pause] pause CSM enters Paused_Racing: WBP_PauseRacing_C pre-created for P1 (ctrlId 0) (z=900, pauser unknown -> P1)`,
  `game paused by none (unknown: the menu keeps its owner)`. A resume plus stick input continues (known:
  `live-run-I-facts.md`).

## Results and the front end after the race
- V-MB-01/02: `[menubridge] P2 A -> WBP_SimpleRaceResultsScreen_C WBP_Common_Btn_Continue (focused): clicked
  (V-MB-01/02)`, then POSTRACE -> LEAVING -> FRONTEND.
- **V-MB-08 FAILED: P1 still cannot continue the results screen.** `P1 input mode Game+UI on
  WBP_SimpleRaceResultsScreen_C ...: ok` and `P1 focus on WBP_SimpleRaceResultsScreen_C (WBP_Common_Btn_Continue): ok
  (V-MB-07)` are logged, no `A read from its raw vehicle input` line follows, and the screen stays
  (`rc-13-after-p1-a.png`, run 1). Probes while P1 held A: P1's `EnhancedPlayerInput.ActionInstanceData` had no
  `IA_Veh_Boost` entry, `IA_UI_Accept` TriggerEvent 0, `IsInputKeyDown(Gamepad_FaceButton_Bottom)` false. Likely cause:
  the results screen is owned by the last local PlayerController and P1's CommonUI router has no active screen. Task #10
  stays open; workaround: another player presses A.
- V-FEO-01/02/12: `[feowner] PickPrimaryMode: WBP_FE_MainMenu_C pre-created for P1 (pc <n>, 4 local PCs) z=500
  (V-FEO-01)`, `pre-created WBP_FE_MainMenu_C (PickPrimaryMode) acquired by the front-end CSM after 91-117 ms: extra ref
  released; input mode refresh ok (V-FEO-02); owner P1 (V-FEO-12)`.
- V-FEO-07: `[feowner] Multiplayer tab hidden while 4 local player(s) exist: enabled set, visibility set (V-FEO-07)`.
- V-FEO-13 / V-FEO-11: P1's X opened Settings made for P1 (`ChangeStateTo(CSM_FrontEnd_Settings): WBP_Settings_C
  pre-created for P1 ... (V-FEO-13)`, acquired after 44 ms); P1's B went back (`WBP_Settings_C Back: WBP_FE_MainMenu_C
  pre-created for P1 ... (V-FEO-11)`, acquired after 47 ms, owner P1).

## Persistence and pods
- V-RC-25: run 1 `[racers] LastRaceRacers saved for ControllerId 0, 1 (2 pad(s) on file) (V-RC-25)`. After the game
  restart (run 3): `picks of 2 pad(s) restored for archetype 0 (V-RC-25)`; P1's pick (KATJA MOX =
  DA_Racer_ElegantProfessional, BELUGA, `kit custom`) and P2's (NIK SKANDARO, HAMMERHEAD) came back.
- Pods (`setup.debugJump{class = "Plane", planet = "Beagle"}` -> TRAK_BGL_PLANE_FWD_PDay, MOS ESPA SPEEDWAY, AFTERNOON
  DRY): V-RC-32 `[perkapply] systems Plane: ramjet false, critmalf false (VBD_000_1Mastiff_Plane reads false / false;
  PerkRamjet keep, PerkCritMalfunctions keep, PerkPodRamjet false) (V-RC-32)` (speeders: `systems Car: ramjet true,
  critmalf true`). The roster holds 8 pod pilots (`1 / 8`); DUD BOLT's style VULPTEREEN 327 shows his head shot as the
  style icon (untinted after the fix); the PERKS sixth upgrade row is AIR BRAKE; P2's kit row `LOADOUT: VULPTEREEN 327
  KIT` (`rc-09-pods-pilot.png`, `rc-13-pods-perks.png`).

## Bug found in run 1, fixed before run 2: an AI kept a human's pilot name
- Run 1: the AI holding P1's pilot got another pilot in the recipe (`dbg AI DA_Racer_ElegantProfessional ->
  DA_Racer_InnerHonour (a human's pilot)`) and that pilot's signature car, but its front-end PlayerState kept the old
  `Pilot` and name, and the travel copies both: the results list "Katja Mox" (P1's pilot) as an AI
  (`rc-13-after-p1-a.png`: P1 is listed by account name, "12 Katja Mox" is the AI).
- Fix (perkapply.lua): `adoptPilot` writes the AI PlayerState's `Pilot` and `PlayerNamePrivate`
  (`URacerDef.CharacterName`) + `OnRep_PlayerName()` in the front end; a race-side net (`fixAiPilots`, once per world)
  adopts the recipe entry's pilot and name for any AI whose PlayerState still differs and rebuilds its seated pilot
  (`VehicleAnimationComponent:SynchronousRefreshPilot`).
- Run 2: `[perkapply] AI DA_Racer_QuietStrength -> DA_Racer_Star (a human's pilot; PlayerState.Pilot set, name 'Lyren
  Shok') (V-RC-20)`; the race player list had no duplicate pilot; the race-side net logged nothing (no AI left to fix);
  the results name the re-assigned AI "Lyren Shok" and no human's pilot appears among the AI (`rc-12-results.png`,
  run 2).

## Layout fixes after run 1 (cards.lua; confirmed in runs 2-3)
- Section rules: a texture-less FuseImage ignored `SetDesiredSizeOverride` and drew a 32-su bar beside `RACER STYLE`,
  `ABILITIES`, `PARTS`; the rule now sits inside a 2-su SizeBox (run 1 shots show the thick bars).
- W style title / subline spacing (the style name touched `PILOT'S OWN STYLE · 3 TRAITS`).
- READY: the `<pilot> · <vehicle>` line vs the style name (N: 32 pt in 520 su).
- PERKS: the `POWER n / 60` text inset from the card edge.
- VEHICLE: the info line (maker · class traits) centred.
- Pod style icons (head shots) no longer tinted amber.

## Not shown by these runs
- No log evidence for V-RC-03 (A, A, A fast / Enter / Backspace), V-RC-07 (attribution guards: no `dropped` line),
  V-RC-08 (P1 double back), V-RC-10 (prebuild), V-RC-24 (a pod race: both races were landspeeder races), V-RC-26
  (re-map by ControllerId), V-RC-27 (AI parity), V-RC-28 (`SetupPlayerFlow = "classic"` fallback), V-RC-29 (Ctrl+F11:
  hot reload is off by default in 0.10.0), V-RC-30 (sounds; game audio muted by the harness), V-RC-34 (multi-line
  wrap), and the 960x540 preview default.

## The "Settings crash" of 2026-10-09 21:20:41: a test probe, confirmed
- `FName("GetOwningPlayer"):GetComparisonIndex()` = 465218 = 0x71942, the name the crashing `__index` looked up
  (`crash_2026_10_09_19_20_41.0352047.dmp`; analysis `settings-crash-2026-10-09.md`). The probe called
  `St.menu.widget:GetOwningPlayer()` after Settings had replaced the main menu, without `U.ok`.
- Rule: test probes are Lua inside the game and guard every cached UObject with `U.ok(x)` before `x.Member` /
  `x:Fn()`; UE4SS's `__index` only checks the object pointer for null.

## Screenshots (the "new UI" set)
| Shot | Shows |
|---|---|
| `state/runs/20261010-0213-racers-v2/rc-01-2p-pilot.png` | 2 W cards on PILOT: SHADE (RAMJET RIDER), ARY QUILL (REDLINER); each roster dims the other's pilot with its tag |
| `state/runs/20261010-0213-racers-v2/rc-03-2p-picker-ready.png` | P1 PERKS parts picker (ENERGY & ABILITIES 2 / 13, pips, tick, detail + large art); P2 READY stamp + loadout strip |
| `state/runs/20261010-0213-racers-v2/rc-05-3p-mixed.png` | 3 M cards: P1 VEHICLE, P2 parts picker, P3 READY |
| `state/runs/20261010-0213-racers-v2/rc-06-4p-mixed.png` | 4 N cards, one per stage (PILOT, VEHICLE with SIGNATURE, PERKS, READY) |
| `state/runs/20261010-0238-racers-v2b/rc-02-2p-pilot-perks.png` | P1 PILOT (KATJA MOX, TECH EXPERT), P2 PERKS board (SURVIVOR kit, detail card + large art) |
| `state/runs/20261010-0238-racers-v2b/rc-09-pods-pilot.png` | pods on PILOT: SHADE, DUD BOLT (VULPTEREEN 327, head-shot style icon), `1 / 8` |
| `state/runs/20261010-0238-racers-v2b/rc-13-pods-perks.png` | pods on PERKS: `LOADOUT: CUSTOM · FROM RAMJET RIDER`, `LOADOUT: VULPTEREEN 327 KIT`, AIR BRAKE row |
| `state/runs/20261010-0238-racers-v2b/rc-10-race-hud.png` | race 2, four views, each HUD with its own ability cluster |
| `state/runs/20261010-0238-racers-v2b/rc-12-results.png` | race 2 results: no human's pilot among the AI |
| `state/runs/20261010-0244-racers-v2c/rc-07-4p-all-ready.png` | 4 READY cards, `START RACE · ALL READY`, status `ALL READY · P1: A TO START` |
| `state/runs/20261010-0244-racers-v2c/rc-03-2p-vehicle-perks.png` | P1 VEHICLE (3D render, badge, DRIVEN BY, MODEL / LIVERY rows), P2 PERKS board |

Other evidence shots (all in `state/runs/20261010-0213-racers-v2/`): `rc-09b-start-gate.png` (the START gate),
`rc-13-after-p1-a.png` (results still up after P1's A; "Katja Mox" as an AI), `rc-14-settings-p1.png` (Settings opened
by P1's X after the race), `rc-15-after-settings.png` (the main menu after P1's B: LB / RB glyphs, no Multiplayer tab).

## Follow-up 2026-10-10 05:00 (run dir state/runs/20261010-0437-ui-before)
- **P1 on the results screen (task #10): a way in.** On WBP_SimpleRaceResultsScreen_C (root FuseCanvasPanel, owned by the last
  local PC), a plain `/Script/UMG.Button` constructed with the screen's WidgetTree as outer, added to the root canvas and focused for
  P1 (`SetUserFocus(P1 PC)`, `HasUserFocus` true) read `IsPressed() = true` while P1 held A on its pad and `false` after the release.
  Slate still routes P1's Accept to P1's focused widget; CommonUI buttons ignore it because their click comes from the owning
  player's action router. 0.10.1 menubridge: an invisible "catcher" button per shared screen, P1's focus kept on it, polled like a
  key (cfg.MenuBridgeP1Catcher, VERIFY V-MB-09); MenuBridgeRawA now defaults to false (V-MB-08 never fired).
- **Keyboard (keyq crash fix): verified.** With the game window focused, ydotool arrow keys reached the mod's keybinds (racers
  p1.lastKbMs updated, P1's card moved); 160 rapid presses during the RACERS step: game alive, 0 ERROR lines, no crash dump.
- The game's Multiplayer > Quick Race > Character Select A starts ONLINE matchmaking (joined a public Multiplayer Tour race; left via
  pause > EXIT TO MAIN MENU). Never press A there in tests.
- CLASS step showed the archetype trait text raw ("USE <ACTION ID=...>"): vehicles.plainText now maps <action id="ImprovedSteering"/>
  to X and drops other tags.
