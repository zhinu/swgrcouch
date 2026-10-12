# 0.12.0 review notes

Internal notes: `docs/dev/` is not in the release zips. Up to 0.11.0-dev the top-level README carried a review install,
a review checklist and a "For reviewers (private repo)" section. The 0.12.0 README is the public one, so that material
lives here now, updated for 0.12.0. Player documentation: `README.md` and `docs/REFERENCE.md`.

## 1. Install a review build

The tree must say `C.VERSION = "0.12.0"` (`SWGRCouch/Scripts/consts.lua`).

**Release zips.** `tools/package.sh 0.12.0` writes `dist/SWGRCouch-0.12.0.zip` and
`dist/SWGRCouch-0.12.0-with-UE4SS.zip`. Without a second argument the UE4SS build is the `ue4ss-build/` folder of the
newest `dist/*-with-UE4SS.zip`. The script stops when:
- C.VERSION is not the version asked for;
- a Lua file does not compile (`luac5.4 -p`, when it is installed);
- a shipped text file holds private data (home paths, SteamIDs, the mail domain, the machine name);
- a shipped folder holds an untracked file;
- the README references an image that is missing (the `docs/screenshots/0.12/` set must be in place first).

Only git-tracked files ship, as they are in the working tree (uncommitted edits included), plus `SWGRCouch/README.md`
(a copy of `docs/REFERENCE.md`, which `install.sh` puts in the game's mod folder) and the images the README references.
An existing zip of the same name is moved aside with a timestamp.

Then install as a player does: unpack the with-UE4SS zip and run `./install.sh "<game root>"`. Add `--console` for the
UE4SS log console and GUI console (a first install now keeps them off).

**Straight from the repo.** `UE4SS_DIR=<folder with dwmapi.dll and ue4ss/> ./install.sh "<game root>"`, or no
`UE4SS_DIR` when the game already has the UE4SS Galactic Racer Edition. The repo has no `SWGRCouch/README.md`
(package.sh makes it), so the game's mod folder keeps the copy it had.

**Check:** `ue4ss/UE4SS.log` shows `SWGRCouch 0.12.0 loading` and `modules=46/46`.

**Review session settings** (`Scripts/config_user.lua`): `Debug = true`; 0.12.0 ships with `Debug = false`, so the
`U.dbg` lines are off. The research probes are off by default too: `UxSplitProbeMs = 5000`, `WreckProbe = true`,
`CrashCamProbe = true` and `PreviewCalibrate = true` bring them back for a test session.

## 2. Review checklist

Each step names the log line that proves it (the `[SWGRCouch][module]` prefix is left out).

1. **Boot:** `SWGRCouch 0.12.0 loading`, `modules=46/46`. FREE MODE shows four posters and the players strip.
2. **OPTIONS:** change every row (left / right, A). BACK, B and Backspace each close it:
   `OPTIONS closed (<why>): the tiles are back, focus on the OPTIONS tile (V-FIN-15)`. P1's pad B before the first
   race: `QuitGame prompt over OPTIONS: answered No (1 click(s), N ms after the post), OPTIONS closed (V-BP-01)`, and
   no prompt is left on screen.
3. **RACE SETUP:** B on PLANET:
   `QuitGame prompt over RACE SETUP: answered No (1 click(s), N ms after the post), one step back (V-BP-01)`, then CLASS
   shows. B on the plain posters: no `[backprompt]` line, and the game's QUIT GAME? stays up (expected, README *Known
   issues*): choose CANCEL.
4. **`BackPromptAsBack = false`:** B on OPTIONS / RACE SETUP leaves the game's QUIT GAME? up again (the 0.11 behaviour).
5. **Opponents** (speeders): step the row (`opponents: TIER 4 · CORGI (35%) (V-RC-27)`), then race on TIER 1 and on
   TIER 4.
   - TIER 1: `AI builds (N AI, launch base VBD_000_1Mastiff): PowerLevel min 0 / avg 0.0 / max 0, abilities 0.0, parts 0.0 per AI (V-RC-27)`.
   - TIER 4: `launch base VBD_035_4Corgi (opponents' tier; humans' empty ability slots are cleared) (V-RC-27)`, then
     `AI builds (N AI, launch base VBD_035_4Corgi): PowerLevel min 18 / avg 18.0 / max 18, abilities 2.0, parts 0.0 per AI (V-RC-27)`.
   - Every human, every race: `loadout: Pn in race: build ok, abilities 4/4, crash ok, parts 4/4 live (V-RC-21)`.
   - Pods: the row reads *Standard* and takes no focus.
6. **Launches in a row** from RACE SETUP, back to the menu after each: one
   `launch hold: the front-end pages stop until the race world (V-LCH-07)` per launch, no crash.
7. **RACERS** with 1 to 4 pads: pilot, vehicle, perks, pickers, the quick path A, A, A; START from P1's card. Move the
   mouse: `command row: SAVE AND RETURN, START RACE, BACK (P1 input mouse) (V-FIN-11: START RACE is never shown twice)`;
   back on the pad: `command row: BACK only (P1 input pad) (V-FIN-11: ...)`. No `text overflow card ... (V-FIN-09)`
   warning; try one game language besides English, German and French.
8. **Joining** with P1's cursor on START: a guest's join press must not start the race:
   `START tile click dropped: guest pad N pressed A M ms before it (task #14, V-RC-07)`. The other posters and the
   OPTIONS rows are not guarded yet (README *Known issues*).
9. **Hot-plug:** switch a second pad on at the menu next to a working P1 pad:
   `hot-plugged pad ctrlId N: P1 keeps ctrlId 0, whose pad is still connected (ADD PLAYERS makes the new pad a guest) (V-JOIN-20)`.
   Switch P1's own pad off and on again: `hot-plugged pad ctrlId N takes P1 (was ctrlId M; <source>): ok (V-JOIN-20)`
   (not run live yet).
10. **In the race:** your own abilities in your own HUD; every pad drives only its own car; pause from P1 and from a
    guest; RESTART RACE from both.
11. **Results:** P1 presses A; back in the menu, P1's pad drives the menu and Settings.
12. **Keyboard:** arrows, Enter and Backspace on the posters, OPTIONS, RACE SETUP and RACERS.
13. **`UiStyle = "classic"`** and a restart: the 0.11 rows, setup frame and cards. Races still use the `OpponentTier`
    saved in `settings.txt`.

Attach `UE4SS.log` and any `crash_*.dmp` to a report. The full list of checks is `docs/REFERENCE.md` §9; the V-FIN ids
are the checks of the UI v2 design spec (§14).

## 3. Live results, 2026-10-10

- UI v2 pages at 1280x720, 1920x1080 and 3840x2160 (2 and 4 players), in English, German and French; 1 and 3 players
  at 1280x720. Other game languages: not checked yet.
- Back prompt: OPTIONS answered No with 1 player (several times) and with 2 players (after five races); RACE SETUP one
  step back with 1 player.
- `UiStyle = "classic"`: lobby rows and RACERS card with 1 player.
- Launches: 5 in a row from RACE SETUP, back to the menu after each, no crash. 2 players, 2 more pads connected but not
  joined (`commit: 2 dormant guest(s) travel with us (GuestRemoval=never): AI drives their cars`). Opponents tiers 1,
  4, 1, 4, 1: TIER 1 gave the AI PowerLevel 0, no abilities, no parts; TIER 4 PowerLevel 18 and 2 abilities each;
  both humans `build ok, abilities 4/4, crash ok, parts 4/4 live` in every race.
- Hot-plug: `hot-plugged pad ctrlId 3: P1 keeps ctrlId 0, whose pad is still connected ...` with 1 player.
- The 0.12.0-dev launch crash (4 of 5 launches from RACE SETUP before the launch hold) did not come back. It never
  shipped, so the README does not list it as a fix.

## 4. Before publishing

The 0.11 "For reviewers" items, updated:
- **Diff against the public release:** `git diff a755b81 -- SWGRCouch/Scripts install.sh` (a755b81 = public 0.10.1).
  There is no pull request; compare with git.
- **`Scripts/perkdata.lua`** holds the names and descriptions of abilities, parts, traits and styles from the game's
  data (the RACERS step needs them). Public 0.10.1 already shipped it, and its README said so; the 0.12.0 README keeps
  that sentence.
- **`docs/screenshots/0.11/reference/`:** captures of the game's own menus, the redesign target. The 0.12.0 README no
  longer shows them, so `tools/package.sh` leaves them out of the zips. Keep the folder out of the public tree (public
  0.10.1 did not have it).
- **`docs/dev/`:** internal notes; not in the zips and not in the public 0.10.1 tree.
- **`HudNarrowViews = "readable"`:** the README now says the opt-in stays. Removing the `HudNarrow*` keys is the
  maintainer's call; the README's HUD caption and `docs/REFERENCE.md` §7.2 would change with it.
- **Unused screenshots:** the README no longer references the 0.11 menu shots (`docs/screenshots/0.11/01-17`) or the
  PNGs at the top of `docs/screenshots/`; the 0.11 race shots 20-26 are still used.
- **Code comments that name a person:** one in `join.lua` (next to the `HotplugPadToP1` rule; new in 0.12.0), one in
  `nametags.lua` (a player's persona name, next to the persona-name sources; public 0.10.1 already shipped it). The
  `Scripts/` folder ships, and package.sh's leak check does not look for names.

## 5. Changed after the review snapshot

- **Launch hold** (`state.lua` `St.launchHold()`): from the first callback after an accepted launch until the race
  world, no front-end page, theme widget or main-menu object is touched; theme's setters check the widget first.
- **Back prompt:** its two hooks exist only while OPTIONS or RACE SETUP shows and no launch is pending; with
  `KeyboardIsP1` the prompt is answered No without a back step; the prompt search runs at most every 250 ms.
- **Hot-plug:** a new pad takes P1 only while P1's own pad is gone, never with `KeyboardIsP1`; `join.padPresent()`.
- **Release defaults:** `Debug`, `UxSplitProbeMs`, `WreckProbe`, `CrashCamProbe` off; new `PreviewCalibrate = false`.
- **Installer and packaging:** consoles kept off on a first install (`--console` / `--quiet-console`); the "UE4SS not
  found" message names the Galactic Racer Edition; a warning for UE4SS 3.0.1-1160; `tools/package.sh` ships
  git-tracked files only. In the docs pass, install.sh's header, its `install_mod` console comment and its doc pointers
  (`--help`, the closing hint) were brought in line with the code; they now name `docs/REFERENCE.md`.
- **Opponents:** RACE SETUP > MODE > Opponents (`OpponentTier` 1-6, default 1); the race launches on that tier's build.
- **UI:** the MODE posters' title band meets the art without a seam; a pilot change keeps a custom loadout tied to the
  kit it came from.
- `C.VERSION = "0.12.0"`.
