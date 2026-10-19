# Nexus Mods page: how to use these files

`docs/NEXUS-DESCRIPTION.bbcode` is the mod description for Nexus Mods. Paste it whole into the description field.

## Files to upload

| Nexus section | file (from the release, `tools/package.sh VERSION` -> `dist/`) | what it is |
|---|---|---|
| **Main files** | `SWGRCouch-1.0.0-nexus.zip` | the mod folder only, **no DLL and no executable**: `SWGRCouch/` (`enabled.txt`, `Scripts/*.lua`, an empty `native/` with a note), `LICENSE`, `README.txt` (install steps). Extract into `<game>\Griffin\Binaries\Win64\ue4ss\Mods\`. Requires UE4SS Galactic Racer Edition from its own Nexus page. |
| **Optional files** | `swgr_inputfilter.dll` | the input filter, ~40 KB. Needed for proper per-player pad routing in split screen: without it the pads mix (every pad steers player 1's car); solo play works without it. Goes into `ue4ss\Mods\SWGRCouch\native\`. Built from the public source, byte-identical rebuild (sha256 in the release notes); not code-signed yet (SignPath application pending). |

Suggested file descriptions: main file "SWGRCouch 1.0.0 - the mod (Lua scripts only). Requires UE4SS Galactic Racer
Edition."; optional file "Input filter DLL - needed for split screen (separates the players' pads). Put it into
ue4ss/Mods/SWGRCouch/native/."

The bigger zips (`-no-UE4SS`, `-with-UE4SS`, the mod-only zip with `install.sh`) stay on the GitHub and git.jules.my
release pages; link them from the description rather than uploading them.

## The images

Nexus BBCode `[img]` needs absolute URLs. Every `[img]` in the description points at the public repo:

    https://git.jules.my/jules/swgrcouch/raw/branch/main/docs/media/<file>.gif

`docs/media/` is on the public `main` branch since 1.0.0. Open one URL in a private window to check it loads before
pasting the description. The same files are also at
`https://raw.githubusercontent.com/zhinu/swgrcouch/main/docs/media/<file>.gif`.

If you would rather not hotlink from git.jules.my (Cloudflare can rate-limit hotlinked GIFs), upload the GIFs to an
image host or to Nexus and replace each URL. The file names stay the same.

## What to upload to Nexus' own image gallery

The gallery (Images tab and the mod's main thumbnail) takes uploaded files, not links. Upload in this order. The
first one becomes the thumbnail.

| order | file | why |
|---|---|---|
| 1 | `docs/media/still-hero-2p-race.jpg` | thumbnail: 2P split race on Crait (a still works better than a GIF as a thumbnail) |
| 2 | `docs/media/still-race-4p.jpg` | 4P race, "TAKEN DOWN BY PLAYER 2" |
| 3 | `docs/media/still-grand-prix.jpg` | Galactic Grand Prix tour posters |
| 4 | `docs/media/still-vehicle-select-p2.jpg` | couch campaign: P2's own 3D vehicle select |
| 5 | `docs/media/hero-2p-race.gif` | animated, if the gallery accepts GIFs of this size |
| 6 | `docs/media/race-4p.gif` | animated |
| 7 | `docs/media/vehicle-select-p2.gif` | animated |

Check the gallery's size limit when you upload. A GIF that is too big can be replaced by its `.mp4` twin on a video
host (Nexus' Videos tab takes YouTube links, not files).

Every GIF in `docs/media/` has an `.mp4` (H.264) and a `.webm` (VP9) twin with the same name. They are silent loops,
10 to 20 times smaller, for sites that prefer video (Reddit, Discord, Steam guides).

## Rebuilding the media

The clips were cut from session recordings with ffmpeg and gifsicle (the cutting script and the recordings stay with
the project notes). The menu clips blur the account name in the top-right badge.
