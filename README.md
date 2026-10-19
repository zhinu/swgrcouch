<div align="center">

# SWGRCouch

### Split-screen couch play for STAR WARS™ Galactic Racer

**One screen, up to four controllers.** Race with friends in Free Mode, run a Galactic Grand Prix, or play the game's own campaign together. Version 1.0, free, and fan-made.

![Two players racing in split screen on Crait](docs/media/hero-2p-race.gif)

*Two players race on Crait. Each one has their own car, view, HUD and pad.*

</div>

---

## What you get

| | Free Mode | Couch Campaign |
|---|---|---|
| **Players** | **1–4** on one screen (verified) | **2** verified · 3–4 *experimental* |
| **What you play** | Quick Race, Custom Race, Galactic Grand Prix | The game's real campaign: paddock, run map, acts, bosses |
| **Each player has** | their own pilot, vehicle, loadout, view and HUD | their own vehicle class, racer style, credits, shop, rewards, backer and garage |
| **Split** | top / bottom or side by side for 2, quarters for 3–4 | top / bottom for 2, quarters for 3–4 |

---

## Free Mode

A **FREE MODE** tab on the main menu, drawn in the game's own style. Pick a way to play, add pads, and go.

| | |
|---|---|
| ![The FREE MODE page](docs/media/free-mode-page.gif) | ![Adding players: press A](docs/media/join-press-a.gif) |
| **Three ways to play.** **Quick Race** gives everyone the same build. **Custom Race** uses your own builds against an AI tier you choose. **Galactic Grand Prix** is a multi-race tournament. | **Join with A.** Turn the pads on with ADD PLAYERS, then each friend presses **A** on their own pad. Their seat lights up at once. |
| ![Galactic Grand Prix: planning a planet tour](docs/media/grand-prix-setup.gif) | ![Four-player split race](docs/media/race-4p.gif) |
| **Galactic Grand Prix.** Choose Podracer Tour, Planet Tour, Planet Championship, Galactic Championship or Custom. Pick the planet, the races, the upgrades and each player's vehicle. Points go on one table for players and AI, and a podium ends the tour. | **Four players, four views.** Any track, any planet and any class, podracers included. Each player drives their own car with their own pad. Takedowns are credited to the right player. |

- **Every track the game offers** in Quick Race and the Arcade, with its conditions (time of day, weather) and modes (race, full grid, mixed class, eliminator).
- **Racer cards for everyone.** Each player picks a pilot, a vehicle (shown as a live 3D render) and a full loadout: abilities, parts, upgrade levels, racer style and traits. Everything is unlocked. Press **A, A, A** for a ready-made build. A guest's **Y** picks one at random.
- **AI you can tune.** Choose from six tiers, or *Match the players*, so a maxed group meets maxed opponents.
- **Per-player everything in the race:** HUD, boost and ramjet bars, subtitles, name tags and pause menu. **RESTART RACE** sits in the pause menu.

---

## Couch Campaign

The game's **own campaign**, now for a second player (and, experimentally, a third and fourth). Player 1 plays the real run: paddock, cinematics, run map and bosses. Every friend races their own car beside player 1 and builds their own vehicle as the run goes on, in their own part of the screen.

| | |
|---|---|
| ![P2 picks their own vehicle in 3D](docs/media/vehicle-select-p2.gif) | ![Loadout: style, favours, START RUN](docs/media/loadout-split.gif) |
| **Your own vehicle.** P2 gets their own VEHICLE SELECT, with the car in 3D, in their half of the screen. | **Your own loadout.** P2 chooses a racer style and favours, then presses READY. START RUN waits until everyone is in. |
| ![Backer contracts, both halves](docs/media/backer-contracts.gif) | ![Hibi's shop, both halves](docs/media/hibis-shop.gif) |
| **Your own backer.** Each player signs their own backer contract and gets its signing bonus. | **Your own shop.** P2 gets Hibi's shop with stock for their own class, paid for with their own credits. P1 can't leave until P2 is done. |
| ![Field test: each half its own counter and timer](docs/media/field-test.gif) | ![Rewards in both halves](docs/media/rewards.gif) |
| **Field tests together.** Everyone runs the test at once, and each half has its own timer and counter. | **Your own rewards.** P1 picks the game's upgrade while P2 collects their own reward next to it. |
| ![Boss race: each player races their own boss copy](docs/media/boss-race.gif) | ![COUCH CAMPAIGN settings](docs/media/couch-campaign-settings.gif) |
| **Bosses, rivals and head-to-heads.** Each player races their own copy of the boss, so nobody is left as a spectator. | **House rules.** OPTIONS › Couch campaign sets how team mystery choices, P1's rewards and the Broker's penalty work for your couch. |

- **Your own run, wallet and car.** Each friend has their own credits (earned by finish position), side bets, mystery deals, faults after a wreck, and a **GARAGE** with their own model and livery.
- **Seats, not pads.** Progress belongs to P2's seat, P3's seat and so on. If a pad dies, another one can take its seat, and after a restart each controller returns to the seat it had.
- **Replay any act** from the COUCH CAMPAIGN page on the CAMPAIGN tab.

---

## Before you play: offline only

> **⚠ Play offline, and protect your save.**
> - Start Steam in **Offline Mode** (Steam menu › Go Offline) before you play with the mod, and do not use the mod for online play. To start straight at the main menu, the mod turns off the game's Epic account link in your game profile (as accepting the game's own "EOS linking will be disabled" prompt does), and online play may need that link.
> - **Turn off Steam Cloud for the game** while you use the mod (Steam: right-click the game › Properties › General). Otherwise Steam can upload the save you played with the mod, and later replace a copy you put back.
> - Keep a copy of the game's `Saved` folder from before the install (Proton: `steamapps/compatdata/4078430/pfx/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved`; Windows: `%LOCALAPPDATA%\StarWarsGalacticRacer\Saved`) and **put it back before you play online again**. The game may later upload race times set offline to its online leaderboards, so a save used with the mod should not go online. Putting it back also restores the link setting, and your progress as it was then.
> - **The couch campaign is player 1's real campaign run.** The game keeps one run per profile, so a new couch run replaces your solo run. Copy `SaveGames` first (see [Couch campaign](#couch-campaign-details)).

The game is not included. You need a legitimately bought copy (Steam). The mod contains no game code and no game files. Its pages are drawn with the art and fonts of your installed game, and the perk menus use names and descriptions from the game's data (`Scripts/perkdata.lua`).

## Requirements
- **STAR WARS Galactic Racer** on Steam, build CL 382801 (the 2026-10-12 hotfix) or CL 382493: both are supported.
  The native input filter also knows the launch build CL 381121, but it was not tested there.
- **[UE4SS Galactic Racer Edition](https://www.nexusmods.com/starwarsgalacticracer/mods/2) by GenerousMods**. Get it from its page: it is kept up to date after every game update, and
  most UE4SS mods for this game use it, so one UE4SS serves them all. The with-UE4SS zip also carries a copy (open
  beta, 2026-10-08) for players who want a single download. UE4SS 3.0.1-1160 (the 0.9.0 and 0.9.1 zips) does not
  boot on the current game.
- One pad per player (Xbox layout tested; DualShock through Steam Input or Moonlight works).
- Windows, or Linux / Steam Deck with Proton (tested: GE-Proton 11-7 + Steam Linux Runtime 4).

## Install

Downloads are on **Nexus Mods** (page coming soon). No files are attached to the releases here.
- **Main file** — the mod folder only (Lua scripts, no DLL, no executable): extract it into
  `<game>\Griffin\Binaries\Win64\ue4ss\Mods\`. Requires
  [UE4SS Galactic Racer Edition](https://www.nexusmods.com/starwarsgalacticracer/mods/2) by GenerousMods.
- **Optional file** — `swgr_inputfilter.dll`, into `ue4ss/Mods/SWGRCouch/native/`: gives each player's car its own
  pad. Solo play works without it; in split screen the pads mix without it (see [The input filter DLL](#the-input-filter-dll)).

You can also install straight from this repository (below): `install.sh` works from a checkout, and the DLL can be
rebuilt from its source with `SWGRCouch/native/inputfilter/build.sh`.

### Linux / Steam Deck (Steam + Proton)
```sh
git clone https://git.jules.my/jules/swgrcouch.git && cd swgrcouch
./install.sh "$HOME/.local/share/Steam/steamapps/common/STAR WARS Galactic Racer"
```
Then set the launch options in Steam (Properties > Launch options): `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
`install.sh` never deletes anything (edited files get a dated copy first) and keeps your `config_user.lua`,
`settings.txt` and UE4SS console setting. A first install leaves UE4SS's console windows off: add `--console` to turn
the log console and the GUI console on (for a bug report), `--quiet-console` to turn them off again.
`./install.sh --help` lists the other options.

With the no-UE4SS zip or the mod-only zip, `install.sh` uses the UE4SS already in the game (install UE4SS
Galactic Racer Edition from its page first). With the with-UE4SS zip, `install.sh` replaces the UE4SS core files such as `dwmapi.dll` and `UE4SS.dll` (a dated copy
first) and keeps your other UE4SS files; `mods.txt` and `UE4SS-settings.ini` get the changes the mod needs. With the
other zips and no UE4SS in the game it stops and names UE4SS Galactic Racer Edition. If it warns that the installed
UE4SS is 3.0.1-1160, update UE4SS Galactic Racer Edition from its page.

### Windows
1. Open `<game>\Griffin\Binaries\Win64\` (the folder with `SWGR-Win64-Shipping.exe`).
2. Install [UE4SS Galactic Racer Edition](https://www.nexusmods.com/starwarsgalacticracer/mods/2) by GenerousMods as its page says (its files go into that folder), or, with the
   with-UE4SS zip, copy `ue4ss-build\dwmapi.dll` and the `ue4ss-build\ue4ss\` folder there.
3. Copy `SWGRCouch\` into `ue4ss\Mods\` (so you get `ue4ss\Mods\SWGRCouch\Scripts\main.lua`), replacing old files.
4. Copy the `ue4ss_signatures\*.lua` files into `ue4ss\UE4SS_Signatures\`.
5. `ue4ss\Mods\mods.txt` must contain the line `SWGRCouch : 1` (above the last line, `Keybinds : 1`).

**Updating from an older version:** install over it the same way. If your `config_user.lua` sets `CardW`, `CardGap`,
`CardH`, `CardRowW`, `SetupCMapVideoW`, `SetupCMapBackground`, `SetupCMapMapW` or `SetupCMapMapH`, remove those lines:
a value set there also replaces the new layout's own value.

### Check it works
Start the game. `Griffin/Binaries/Win64/ue4ss/UE4SS.log` shows `SWGRCouch 1.0.0 loading` and `modules=85/85`, and the
main menu has a **FREE MODE** tab with the QUICK RACE, CUSTOM RACE and GALACTIC GRAND PRIX posters. Once a second pad
joins, the log shows `native filter loaded: installed=1 reason=ok build=382801` (the number is your game build).

## Uninstall
- **Linux / Steam Deck:** remove `WINEDLLOVERRIDES="dwmapi=n,b"` from the launch options: UE4SS and the mod no longer
  load (the files can stay).
- **Windows:** delete or rename `dwmapi.dll` in `<game>\Griffin\Binaries\Win64\`.
- Every file `install.sh` changed has a dated copy next to it (`*.swgrcouch-<date>`). If you ran it with `--prefix`:
  `install.sh --prefix <wine prefix> --net-off` removes the network override, and `--fastboot-ini-undo` turns the
  Epic link setting in `GameUserSettings.ini` back on.
- The Epic link setting in your game profile stays off after an uninstall. To play online again, put back the `Saved`
  folder you copied before the install, with Steam Cloud still off for the game so Steam does not replace it (see
  *Before you play*).

## Play
1. Main menu › **FREE MODE** (LB / RB).
2. With friends: A on **ADD PLAYERS**, then A again to confirm (the poster then reads *PADS ON*; the pads stay on
   until the game restarts). Each friend presses **A** on their own pad, and the players strip shows who joined. A
   guest leaves with **B** (on the racer cards: hold B).
3. Pick a way to play:
   - **QUICK RACE**: one difficulty for the whole race (Rookie to Legend), and the players and the AI get the same
     build. Each player only picks a pilot and a vehicle.
   - **CUSTOM RACE**: choose the class, planet, track, conditions and mode, then everyone builds their own kart on the
     racer cards (pilot › vehicle › perks › ready). *Opponents* sets the AI tier, or *Match the players*.
   - **GALACTIC GRAND PRIX**: pick a tour, set it up, and race it to the podium. Between races the page shows the
     standings and NEXT RACE.
4. P1 starts when everybody is READY. In RACE SETUP, **B** goes back one step.
5. In the race, Start pauses (the pause menu belongs to whoever pressed it; RESTART RACE is right under RESUME). On the
   results, any player's A continues.
6. **OPTIONS** holds the 2-player layout, split graphics, takedown cameras, name tags, keyboard as player 1, player
   names, the couch campaign rules, network and the game's race builder. **B**, Backspace or **BACK** returns to the
   posters. On the posters themselves, B is the game's Exit Game (see *Known issues*).

## Couch campaign details
**Before the first couch run: protect your save.** The game keeps **one campaign run per profile**, and the couch
campaign *is* player 1's run: starting a new run in couch replaces the run you play alone. Quit the game, then copy
the `SaveGames` folder (in the `Saved` folder named in *Before you play*) somewhere safe; put it back when you want
your solo run again (game closed, Steam offline, Steam Cloud off for the game).

**Start a couch run**
1. Main menu > **FREE MODE** > **ADD PLAYERS** (A, then A again to confirm). Each friend presses **A** on their own pad
   until the players strip shows them.
2. Go to the game's **CAMPAIGN** tab (LB / RB) and pick the **COUCH CAMPAIGN** tile: start a new run, CONTINUE, or
   replay an act. The friends stay in. A banner says *COUCH CAMPAIGN: P2 JOINS THE RUN* once the couch rules are on.
3. A new run skips the game's vehicle-tryout prologue race (one car only) and opens VEHICLE SELECT: the screen splits
   and each friend picks a **vehicle class** and **racer style** on their own part (D-pad, **A** = READY). A friend
   who picks nothing gets player 1's class.

**Who controls what**
| Moment | Player 1 | Friends (P2-P4) |
|---|---|---|
| Paddock, cinematics, run map, mysteries, dialogs, results | P1's pad drives everything (P1 walks the paddock) | watch; their buttons do nothing there |
| Races | own car, own split view, own HUD, own pause | the same: own car, view, HUD and pause |
| Boss, rival and head-to-head races | races their own copy of the opponent | each friend races their own copy too |
| Field Tests / Podracer Tests (time trials) | P1's test vehicle | the same test vehicle, all at once, each with their own timer and counter |
| Backer contract | the game's own CHOOSE A BACKER CONTRACT | the same choice in their own area, with its signing bonus on their own credits |
| Rewards after an event | the game's own CHOOSE AN UPGRADE | their own reward area beside P1's: the same kind of reward as P1's round, or SKIP for credits |
| Shops | the game's shop | the game's shop screen in their own area with the same kind of stock as player 1's: parts for their own class, the **UPGRADE PACK** and **ABILITY PACK** (pick one of the pack's choices) and **RESTOCK**, at the game's prices, paid with their own credits (earned by finish position); **LEAVE THE SHOP** or **B** leaves (an unopened pack waits for the next visit); on the run map, a friend's **A** opens their own shop at any time |
| Their car | the game's own garage (Customize) | their own **GARAGE**: on the run map a friend's D-pad moves to the *GARAGE* hint beside *(A) SHOP*, **A** opens it: model, livery template, colours and finish of their car (D-pad up / down a row, left / right change it, DONE or B closes). It is their car in every race; player 1's garage is never touched |
| Pre-race CHALLENGES (side bets) | the game's own screen | the same screen in their own area: same racers and stakes, their own credits; A challenges, HOLD A declines |
| Mystery encounters | the game's choices | the same choices in their own area; the deal applies to their own run (run-wide choices stay P1's) |

**Replay an act / start over** (the COUCH CAMPAIGN page, reached from the CAMPAIGN tab's COUCH CAMPAIGN tile): the
campaign's acts are posters next to CONTINUE CAMPAIGN. Any act you unlocked can be played again as a **new run** (A on
its poster), a finished one shows COMPLETED. A run in progress is lost when you start another act: the page asks
first (YES / NO, B = no). OPTIONS > **DELETE ALL COUCH PROGRESS** resets the friends' progress and runs the game's
own campaign reset (acts locked again, a fresh ACT I; vehicle upgrades and logbook unlocks stay). It only works on a
separate couch save profile: a file `.swgr-profile` reading `couch` in the `SaveGames/<account>` folder (written by a
save-profile switcher). On your normal save it is refused, so it can never reset your solo campaign.

**House rules** (OPTIONS > PLAYERS > *Couch campaign*): *Guests' team mystery choices* (GREYED: only P1 takes a
choice with a team effect; ALLOWED: a guest may take it too), *P1's rewards* (OWN PLACE, or BEST CARRIES EVERYONE:
the best human result pays P1 too) and *Broker penalty: Eliminators* (BOTH PLAYERS or OWNER ONLY). The right column
explains each row and its default.

The screen splits **top / bottom** with 2 players and in **quarters** with 3-4, like the races. A friend's build
(abilities, parts, traits, upgrade levels) goes onto their car at every next event. The friends' progress is kept by
the mod in `ue4ss/Mods/SWGRCouch/couch-run.txt`, not in the game's save: a new campaign run starts every friend on a
starter build again. Progress belongs to the friend's **seat**, not to his controller: the first friend to join is P2,
the next P3, then P4, whatever pad or USB slot they use. After a restart each controller goes back to the seat it
had last time, whatever order the friends join in (if the controllers come back on other slots, joining in the same
order as before does it); a friend who leaves (hold B) keeps his seat's progress for a rejoin, and a friend whose pad
dies can take over his seat with another pad. A friend's car (their GARAGE) is kept per player seat and vehicle class in
`ue4ss/Mods/SWGRCouch/guest-garage.txt`, across runs. The GARAGE is the game's own full-screen garage, in turns: the
friend's pad drives it (Choose Model, Edit Vehicle, Edit Livery) while player 1's pad does nothing, and player 1's own
garage comes back exactly as it was (`CouchGarageNative = false`: a compact garage panel instead, which offers what
player 1 owns; `CouchGarageUnlocks = "all"` offers everything).

**Settings** (`config_user.lua`, see *Configuration*): `CouchCampaign = false` turns the whole feature off (the
campaign closes the friends); `CouchSkipPrologue`, `CouchTimeTrials`, `CouchPreRunSplit` and `CouchPanel` turn single
parts off; `CouchGarage = false` hides the friends' GARAGE, `CouchGarageApply = "off"` keeps their chosen model but
not their livery; `CouchToastMs = 0` hides the banner. Every key is explained in `Scripts/config.lua` (section COUCH
CAMPAIGN).

**Limits**
- **Verified with 2 players.** 3 and 4 players run the same code and were tested less: treat them as *experimental*.
- Join the friends on FREE MODE **before** you open CAMPAIGN; nobody can join from the paddock.
- Offline only, like the rest of the mod: no couch campaign in network sessions.
- The friends have no paddock character, and the run's story choices, the run map and the save are player 1's.
- A friend's reward choice follows the kind of reward player 1's round offers (upgrade, ability, part or trait); the
  friends do not unlock anything in the game's own profile.
- Quitting the game or a crash in the middle of an event can lose the run's unsaved progress (the game saves the run
  at its own checkpoints): CONTINUE may then start a new run.
- If a friend's reward cards look wrong, `CouchPanelNative = false` switches them to a plain list.

## Configuration
Never edit `config.lua`. Create `ue4ss/Mods/SWGRCouch/Scripts/config_user.lua` instead, then restart the game:
```lua
return {
    UiStyle          = "v2",     -- "classic" brings back the 0.11 pages (FREE MODE rows, RACE SETUP frame, cards)
    BackPromptAsBack = true,     -- false: pad B on OPTIONS / RACE SETUP opens the game's QUIT GAME? prompt again
    SetupPlayerFlow  = "cards",  -- "classic" brings back the 0.9 vehicle columns instead of RACERS
    HotplugPadToP1   = "off",    -- a pad switched on later never takes P1 ("front" | "always" | "off")
    SkipRaceIntro    = true,     -- skip the race intro cinematics
}
```
- `UiStyle = "classic"` is the way back to the 0.11 pages if the new ones give you trouble; the player colours stay.
- `BackPromptAsBack = false` leaves the game's QUIT GAME? prompt on OPTIONS and RACE SETUP (the 0.11 behaviour).
- `GrandPrix = false` puts the older GALAXY RUN page back on the third poster instead of GALACTIC GRAND PRIX.
- **Opponents** is not a `config_user.lua` key: it is `OpponentTier` (1 to 6, default 1) in
  `ue4ss/Mods/SWGRCouch/settings.txt`, with your other choices (2-player layout, network...). RACE SETUP > MODE >
  Opponents changes it.
- `Debug = true` adds the log lines a bug report needs.

A layout key you set here (`CardW`, `CardH`, `SetupCMapVideoW`...) applies to both looks. Every key is explained in
`Scripts/config.lua`, and most of them in [docs/REFERENCE.md](docs/REFERENCE.md) §7.2; the `settings.txt` keys are in
§7.1.

## Known issues
- **B on the FREE MODE posters is the game's Exit Game.** As on every main-menu tab, P1's B there opens the game's
  QUIT GAME? prompt with ACCEPT focused: choose CANCEL. Only OPTIONS, RACE SETUP and the mod's own pages turn B into
  back (`BackPromptAsBack`).
- **The action bar at the bottom is the game's.** On OPTIONS and RACE SETUP it still reads *(B) Exit Game*, and
  clicking Exit Game with the mouse there also goes back: to quit the game, return to the posters first. On TRACK it
  shows *(A) Select* twice.
- **Joining**: a guest's A press that joins can also click the poster P1's cursor is on. Most posters ignore it
  (`CardGuestClickGuardMs`, 150 ms); some OPTIONS rows and the `UiStyle = "classic"` rows do not yet.
- With two wrecked guests, both may follow the same AI car.
- Pads that are connected but not joined race as AI-driven players with their own view.
- The game pauses itself after about a minute without any game input from any player (the game's own inactivity
  pause).
- Languages other than English, German and French are only partly checked. A RACERS card text that does not fit its
  box is logged as `text overflow` in `UE4SS.log`: please report those lines with the game's language.
- After changing the game's language while it runs, restart the game: until then the RACE SETUP track names and the
  CLASS description can keep the previous language.

## Found a bug?
**DM me** on the site where you got the mod. Set `Debug = true` in `config_user.lua` first, play until it happens
again, and send **`Griffin/Binaries/Win64/ue4ss/UE4SS.log`** (every mod line starts with `[SWGRCouch]`) plus any
`crash_*.dmp` next to it. Say how many players you were and what was on screen. The full list of checks with their log
lines is in [docs/REFERENCE.md](docs/REFERENCE.md) §9.

## How it works (short)
- **Players**: guests are extra UE local players, created after ADD PLAYERS and kept until the game exits.
- **Race launch**: the game's own custom-race path, with the grid rewritten in memory. Each human's pilot and loadout
  are written over the AI tier's build and checked again in the race.
- **Couch campaign**: the campaign's grid gets the guests' cars as players; screens the game makes for one player are
  copied into each guest's own area, and boss / rival / head-to-head races run one copy per player.
- **UI**: the pages are built from the game's own textures, fonts and widgets; every focus target is an invisible game
  button under the painted look.
- **Input**: a small native DLL (`SWGRCouch/native`, source included) gives each player's car its own pad.
- **Per-player UI**: menus and messages the game makes for one player are re-routed to the right player; P1 gets the
  menus after a race.

Details in [docs/REFERENCE.md](docs/REFERENCE.md).

## The input filter DLL
`swgr_inputfilter.dll` (a small native library, ~30 KB, [source included](SWGRCouch/native/inputfilter/)) is what
gives each player's car its own pad in split screen. Without it the mod still loads and **solo play works**, but in
a split race every pad steers player 1's car.

The mod-only zip (`SWGRCouch-<version>.zip`) ships **without the compiled DLL**, because some download sites and
virus scanners flag any zip with an unsigned DLL inside (a handful of heuristic engines flag this one too - a false
positive: the DLL rebuilds **byte-identical** from the C source in this repo with `lld-link /timestamp`, which anyone
can verify). To play split screen, pick one:

1. **Download it**: download `swgr_inputfilter.dll` (a bare file) from the release and put it into
   `ue4ss/Mods/SWGRCouch/native/` (next to `inputfilter/`); or
2. **Compile it yourself**: `SWGRCouch/native/inputfilter/build.sh` rebuilds the DLL from `inputfilter.c` and
   `version.rc` with the system LLVM (`clang`, `lld-link`, `llvm-rc`, `llvm-dlltool`); no Windows SDK is needed; or
3. **Use the with-UE4SS zip**, which ships the DLL in place.

The log line `native filter loaded: installed=1 reason=ok build=382801` (the number is your game build) confirms it
is active.

## Code signing policy
The input filter DLL is the only file this project signs. Free code signing provided by
[SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org) (application in
preparation: until a release says "signed", the DLL is unsigned). The DLL is built from this repository's source on
GitHub Actions and every signing request is approved by hand. Team roles, what is signed, how to verify a download
and the privacy statement (the DLL makes no network connections): [CODE-SIGNING-POLICY.md](CODE-SIGNING-POLICY.md).

## Credits and licences
- **SWGRCouch** by Jules, **made with the help of Claude** (Anthropic). MIT licence (see `LICENSE`).
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): MIT.
- [UE4SS Galactic Racer Edition](https://www.nexusmods.com/starwarsgalacticracer/mods/2) by GenerousMods: the UE4SS build for this game that the mod runs on, and the
  copy in the with-UE4SS zip. Thanks to GenerousMods for maintaining it.
- `ue4ss_signatures/`: written for SWGRCouch (the 2026-10-12 hotfix moved the engine's allocator); they overlap with
  the signatures UE4SS Galactic Racer Edition maintains.
- The animations on this page are short captures of the game running with the mod.

**Fan-made and unofficial.** SWGRCouch is not affiliated with, endorsed by or sponsored by Lucasfilm, Disney, Fuse
Games or Secret Mode. STAR WARS and STAR WARS Galactic Racer are trademarks of their respective owners. No game files
are distributed.
