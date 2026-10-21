SWGRCouch @VERSION@ - split-screen couch play for STAR WARS Galactic Racer (1-4 local players)
================================================================================================

This is the all-in-one "unzip into the game folder and play" download: the mod, its input filter DLL
and UE4SS Galactic Racer Edition (by GenerousMods), already laid out like the game folder.
(This text is SWGRCouch-INSTALL.txt in the game folder and README.txt in the mod's folder.)

INSTALL
  1. Find the game folder: the one that contains the Griffin folder.
     Steam: right-click the game > Manage > Browse local files
     (usually ...\steamapps\common\STAR WARS Galactic Racer\).
  2. Extract this zip INTO that folder and let it merge the folders (answer "replace" if asked).
     ALREADY USING UE4SS WITH OTHER MODS? Then answer "skip" for ue4ss\Mods\mods.txt,
     ue4ss\Mods\mods.json and ue4ss\UE4SS-settings.ini (see below), "replace" for the rest.
     Windows: right-click the zip > Extract All..., set the path to the game folder itself (not a
     new subfolder named after the zip).
     Steam Deck (Desktop Mode): open the zip with Ark > Extract, pick the game folder and untick
     "Extract into subfolder".
     You then have
         SWGRCouch-INSTALL.txt   (this text)
         Griffin\Binaries\Win64\dwmapi.dll
         Griffin\Binaries\Win64\ue4ss\UE4SS.dll
         Griffin\Binaries\Win64\ue4ss\Mods\SWGRCouch\Scripts\main.lua
         Griffin\Binaries\Win64\ue4ss\Mods\SWGRCouch\native\swgr_inputfilter.dll
     next to Griffin\Binaries\Win64\SWGR-Win64-Shipping.exe.
  3. Done on Windows: start the game. The main menu gets a FREE MODE tab.
     Steam Deck / Linux (Proton): also set the game's launch options in Steam
     (Properties > General > Launch options) to
         WINEDLLOVERRIDES="dwmapi=n,b" %command%
     Without it Proton ignores dwmapi.dll and nothing loads.

  Check: Griffin\Binaries\Win64\ue4ss\UE4SS.log shows "SWGRCouch @VERSION@ loading" and, at the latest once
  the COUCH CAMPAIGN page opens or a second pad joins, "native filter loaded: installed=1 reason=ok".

UPDATING
  Extract the new zip the same way over the old files. Your own files are never in this zip, so they
  stay: ue4ss\Mods\SWGRCouch\settings.txt, Scripts\config_user.lua, the run / GP save files in the
  SWGRCouch folder, and the game's saves (they are not in the game folder at all).
  Quit the game first: the input filter DLL is in use while the game runs.

ALREADY USING UE4SS FOR OTHER MODS?
  This zip carries its own ue4ss\Mods\mods.txt and mods.json (SWGRCouch and ConsoleEnablerMod on,
  SplitScreenMod and BPModLoaderMod off, the other mods of UE4SS Galactic Racer Edition as it ships
  them) and ue4ss\UE4SS-settings.ini. Replacing your mods.txt / mods.json switches off every mod they
  do not list. If you already have UE4SS with other mods, do NOT replace those three files (answer
  "skip" for them): SWGRCouch loads anyway through its own Mods\SWGRCouch\enabled.txt (UE4SS starts
  every mod folder that has one). Keep SplitScreenMod off yourself (another split screen). If your
  UE4SS is older than the
  Galactic Racer Edition, do replace dwmapi.dll and ue4ss\UE4SS.dll, and make sure
  UE4SS-settings.ini has  bForceGUObjectArrayForIteration = true  and  UseCache = 0.
  The UE4SS on its own page is kept up to date after every game update:
  https://www.nexusmods.com/starwarsgalacticracer/mods/2

PLAY OFFLINE
  The mod turns off the game's Epic account link. Play with Steam in Offline Mode and Steam Cloud off
  for the game, and keep a copy of your pre-mod Saved folder. Details in the full README
  (ue4ss\Mods\SWGRCouch\README.md, or the repository below).

UNINSTALL
  (the ue4ss\... paths below are under Griffin\Binaries\Win64\)
  - Turn it off: Windows: delete or rename Griffin\Binaries\Win64\dwmapi.dll.
    Steam Deck / Linux: remove WINEDLLOVERRIDES="dwmapi=n,b" from the launch options.
    UE4SS and the mod no longer load; the other files can stay.
  - Remove it completely: delete Griffin\Binaries\Win64\dwmapi.dll, the folder
    Griffin\Binaries\Win64\ue4ss\ and SWGRCouch-INSTALL.txt (this also removes other UE4SS mods you
    put there; to remove only SWGRCouch, delete just ue4ss\Mods\SWGRCouch\).
  - The Epic link setting in your game profile stays off after an uninstall: to play online again,
    put back the Saved folder you copied before the install (Steam Cloud still off for the game).

INPUT FILTER DLL (@DLLSTATE@)
  ue4ss\Mods\SWGRCouch\native\swgr_inputfilter.dll gives each player's pad its own car in split
  screen. It is built from the C source in the public repository (the unsigned build rebuilds
  byte-identical; a signed copy is that build plus the author's own self-signed signature, so
  Windows shows "unknown publisher" - certificate and hashes: docs/signing/ in the repository):
      sha256 @DLLSHA@
  It makes no network connections.
@DLLVERIFY@

CREDITS AND LICENCES
  - SWGRCouch by Jules, made with the help of Claude (Anthropic). MIT licence:
    ue4ss\Mods\SWGRCouch\LICENSE.
  - UE4SS Galactic Racer Edition by GenerousMods: the UE4SS build for this game, included here
    unchanged, with his OK: open beta of 2026-10-08, hotfix 2 (its log header says
    "UE4SS - v3.0.1 Beta #0 - Git SHA #e3ba1016"). Thanks to GenerousMods for maintaining it.
    https://www.nexusmods.com/starwarsgalacticracer/mods/2
    A UE4SS problem? First update UE4SS from that page (it gets fixes after every game update) and
    check there before reporting it to GenerousMods: the copy in this zip may be older.
  - Please do not re-upload this zip, the mod or UE4SS anywhere else: link to the pages instead.
  - UE4SS (RE-UE4SS, https://github.com/UE4SS-RE/RE-UE4SS): MIT licence, ue4ss\LICENSE.
  - ue4ss\UE4SS_Signatures\: SWGRCouch's signature files for the game's 2026-10-12 hotfix.

  Full README, source, the other downloads and the code signing policy:
    https://github.com/zhinu/swgrcouch
    https://git.jules.my/jules/swgrcouch

Fan-made and unofficial; not affiliated with Lucasfilm, Disney, Fuse Games or Secret Mode.
No game files are distributed. The game is not included: you need your own copy.
