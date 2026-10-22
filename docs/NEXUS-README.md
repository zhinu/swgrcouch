# Nexus Mods page: how to use these files

`docs/NEXUS-DESCRIPTION.bbcode` is the mod description for Nexus Mods. Paste it whole into the description field. It
follows the README's chapters: every chapter opens with its banner image, then the text and the animations.

## Files to upload

| Nexus section | file (from the release, `tools/package.sh VERSION` -> `dist/`) | what it is |
|---|---|---|
| **Main files** (1st) | `SWGRCouch-1.0.2-gameroot.zip` | the game-folder download: the mod and `swgr_inputfilter.dll` (signed by the author), laid out like the game folder (`Griffin/Binaries/Win64/ue4ss/...`: `Mods/SWGRCouch/` with `README.txt` and `native/swgrcouch-cert.pem`, `UE4SS_Signatures/`) plus `SWGRCouch-INSTALL.txt` in the game folder. No `mods.txt` / `mods.json` (the mod starts through its `enabled.txt`: the player's other UE4SS mods are never switched off). **No UE4SS in it**: players install UE4SS Galactic Racer Edition from its own Nexus page first (set it as a requirement), then extract this zip into the game folder (the one that contains `Griffin`). |
| **Main files** (2nd) | `SWGRCouch-1.0.2-nexus.zip` | the lean file: the mod folder only, **no DLL and no executable**: `SWGRCouch/` (`enabled.txt`, `Scripts/*.lua`, an empty `native/` with a note), `LICENSE`, `README.txt` (install steps). Extract into `<game>\Griffin\Binaries\Win64\ue4ss\Mods\`. Requires UE4SS Galactic Racer Edition from its own Nexus page. |
| **Optional files** | `swgr_inputfilter.dll` | the input filter, ~50 KB, for the lean file. Needed for proper per-player pad routing in split screen: without it the pads mix (every pad steers player 1's car); solo play works without it. Goes into `ue4ss\Mods\SWGRCouch\native\`. Built from the public source, byte-identical rebuild; 1.0.1 carries the author's self-signed signature (not CA-trusted: Windows shows unknown publisher; certificate in `docs/signing/`). sha256 signed `41458d04...`, unsigned build `42e7b2a4...` (full hashes in `docs/INPUTFILTER.md`). |

Suggested file descriptions:
- game-folder zip: "SWGRCouch 1.0.2 - install UE4SS Galactic Racer Edition first, then unzip this into the game
  folder and play. Includes the input filter DLL. Steam Deck / Linux: UE4SS needs the launch option
  WINEDLLOVERRIDES="dwmapi=n,b" %command%."
- lean zip: "SWGRCouch 1.0.2 - the mod only (Lua scripts). Requires UE4SS Galactic Racer Edition. Add the optional
  input filter DLL for split screen."
- DLL: "Input filter DLL - needed for split screen with the lean file (separates the players' pads). Put it into
  ue4ss/Mods/SWGRCouch/native/."

The other zips (`-no-UE4SS`, `-with-UE4SS`, the mod-only zip with `install.sh`) stay on the GitHub and git.jules.my
release pages; the description links the repository rather than uploading them.

`tools/package.sh` also builds `SWGRCouch-1.0.2-gameroot-with-UE4SS.zip`, the same game-folder tree plus UE4SS Galactic
Racer Edition (`SWGRCouch-INSTALL.txt` from `tools/gameroot/README-with-UE4SS.txt`; its `mods.txt` / `mods.json` list the same mods). It goes on the git.jules.my release page only
(GenerousMods agreed, 2026-10-21; his concern: re-uploads with an outdated UE4SS), never on Nexus.

## The images in the description

Nexus BBCode `[img]` needs absolute URLs. Every `[img]` in the description points at the public repo:

    https://git.jules.my/jules/swgrcouch/raw/branch/main/docs/media/<file>

They resolve once this README's media are on the public `main` branch (the 1.0.1 publish adds the `banner-*.jpg`,
`still-gp-podium.jpg`, `mystery-deal.gif`, `guest-garage.gif` and `side-bets.gif`). Open one URL in a private window to
check it loads before pasting the description. The same files are also at
`https://raw.githubusercontent.com/zhinu/swgrcouch/main/docs/media/<file>`.

If you would rather not hotlink from git.jules.my (Cloudflare can rate-limit hotlinked GIFs), upload the files to an
image host or to Nexus and replace each URL. The file names stay the same.

## What to upload to Nexus' own image gallery

The gallery (Images tab and the mod's main thumbnail) takes uploaded files, not links. Upload in this order: the
first one becomes the thumbnail. Captions are ready to paste.

| order | file | caption |
|---|---|---|
| 1 | `docs/media/banner-hero.jpg` | SWGRCouch 1.0.1: split-screen couch play for STAR WARS Galactic Racer |
| 2 | `docs/media/still-hero-2p-race.jpg` | Two players race on Crait, each with their own car, view, HUD and pad |
| 3 | `docs/media/still-race-4p.jpg` | Four players, four views: takedowns are credited to the right player |
| 4 | `docs/media/still-vehicle-select-p2.jpg` | Couch Campaign: P2 picks their own vehicle in 3D |
| 5 | `docs/media/still-grand-prix.jpg` | Galactic Grand Prix: five tours, one points table for players and AI |
| 6 | `docs/media/still-gp-podium.jpg` | The Grand Prix ends on a podium |
| 7 | `docs/media/hero-2p-race.gif` | Two-player split race (animated) |
| 8 | `docs/media/race-4p.gif` | Four-player split race (animated) |
| 9 | `docs/media/vehicle-select-p2.gif` | Couch Campaign: P2's own vehicle select (animated) |
| 10 | `docs/media/hibis-shop.gif` | Couch Campaign: each player shops at Hibi's with their own credits (animated) |
| 11 | `docs/media/boss-race.gif` | Couch Campaign: every player races their own copy of the boss (animated) |
| 12 | `docs/media/mystery-deal.gif` | Couch Campaign: a mystery deal in P2's half (animated) |
| 13 | `docs/media/grand-prix-setup.gif` | Galactic Grand Prix: planning a tour (animated) |

Check the gallery's size limit when you upload: every GIF here is under 8 MB. A GIF that is too big can be replaced by
its `.mp4` twin on a video host (Nexus' Videos tab takes YouTube links, not files).

Every GIF in `docs/media/` has an `.mp4` (H.264) and a `.webm` (VP9) twin with the same name. They are silent loops,
10 to 20 times smaller, for sites that prefer video (Reddit, Discord, Steam guides).

## Rebuilding the media

`docs/dev/readme-media/make_media.py` cuts every loop, still and chapter banner from the session recordings and the
1.0 trailer footage (ffmpeg, gifsicle, Pillow and the Inter font; the recordings stay with the project notes). The
menu shots blur the account name in the top-right badge. `docs/dev/readme-media/render_preview.py` renders the README
to `docs/dev/readme-preview.html` for a local look.
