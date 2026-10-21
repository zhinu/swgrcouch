SWGRCouch @VERSION@ - split-screen couch play for STAR WARS Galactic Racer (1-4 local players)
================================================================================================

This is the "game folder" download: the mod and its input filter DLL, laid out like the game
folder. It does NOT include UE4SS: install UE4SS Galactic Racer Edition first.
(This text is SWGRCouch-INSTALL.txt in the game folder and README.txt in the mod's folder.)

REQUIRED FIRST: UE4SS Galactic Racer Edition (by GenerousMods)
  Install UE4SS Galactic Racer Edition from its Nexus page first, as that page says:
      https://www.nexusmods.com/starwarsgalacticracer/mods/2
  It is kept up to date after every game update, and most UE4SS mods for this game use it.
  Steam Deck / Linux (Proton): it needs the Steam launch option (Properties > General >
  Launch options)
      WINEDLLOVERRIDES="dwmapi=n,b" %command%
  Without it Proton ignores dwmapi.dll and nothing loads.

INSTALL
  1. Install UE4SS Galactic Racer Edition (above). You then have
         Griffin\Binaries\Win64\dwmapi.dll
         Griffin\Binaries\Win64\ue4ss\UE4SS.dll
     next to Griffin\Binaries\Win64\SWGR-Win64-Shipping.exe.
  2. Find the game folder: the one that contains the Griffin folder.
     Steam: right-click the game > Manage > Browse local files
     (usually ...\steamapps\common\STAR WARS Galactic Racer\).
  3. Extract this zip INTO that folder and let it merge the folders. Answer "replace" if asked:
     the zip holds only SWGRCouch's own files (list below), never a file of UE4SS or of another mod.
     Windows: right-click the zip > Extract All..., set the path to the game folder itself (not a
     new subfolder named after the zip).
     Steam Deck (Desktop Mode): open the zip with Ark > Extract, pick the game folder and untick
     "Extract into subfolder".
     You then have
         SWGRCouch-INSTALL.txt   (this text)
         Griffin\Binaries\Win64\ue4ss\Mods\SWGRCouch\Scripts\main.lua
         Griffin\Binaries\Win64\ue4ss\Mods\SWGRCouch\native\swgr_inputfilter.dll
  4. Start the game. The main menu gets a FREE MODE tab.

  Check: Griffin\Binaries\Win64\ue4ss\UE4SS.log shows "SWGRCouch @VERSION@ loading" and, at the latest once
  the COUCH CAMPAIGN page opens or a second pad joins, "native filter loaded: installed=1 reason=ok".

WHAT THIS ZIP WRITES
  (the ue4ss\... paths below are under Griffin\Binaries\Win64\)
  - SWGRCouch-INSTALL.txt           this text, in the game folder
  - ue4ss\Mods\SWGRCouch\           the mod: enabled.txt, README.txt (this text), README.md (the full
                                    manual), LICENSE, Scripts\, native\swgr_inputfilter.dll and
                                    native\swgrcouch-cert.pem (the DLL's public certificate)
  - ue4ss\UE4SS_Signatures\*.lua    SWGRCouch's signature files for the game's 2026-10-12 hotfix
  Nothing else: no mods.txt, no mods.json, no UE4SS-settings.ini. Your UE4SS settings and your other
  UE4SS mods stay as they are. SWGRCouch starts through its own Mods\SWGRCouch\enabled.txt: UE4SS
  starts every mod folder that has an enabled.txt, listed in mods.txt or not.
  OTHER UE4SS MODS: keep SplitScreenMod off (it is another split screen; UE4SS Galactic Racer Edition
  ships it off). The mod's "couch" console command needs ConsoleEnablerMod (optional).
  The mod needs  bForceGUObjectArrayForIteration = true  and  UseCache = 0  in
  ue4ss\UE4SS-settings.ini: UE4SS Galactic Racer Edition already sets both.

UPDATING
  Extract the new zip the same way over the old files. Your own files are never in this zip, so they
  stay: ue4ss\Mods\SWGRCouch\settings.txt, Scripts\config_user.lua, the run / GP save files in the
  SWGRCouch folder, and the game's saves (they are not in the game folder at all).
  Quit the game first: the input filter DLL is in use while the game runs.

PLAY OFFLINE
  The mod turns off the game's Epic account link. Play with Steam in Offline Mode and Steam Cloud off
  for the game, and keep a copy of your pre-mod Saved folder. Details in the full README
  (ue4ss\Mods\SWGRCouch\README.md, or the repository below).

UNINSTALL
  (the ue4ss\... paths below are under Griffin\Binaries\Win64\)
  - Remove only SWGRCouch: delete ue4ss\Mods\SWGRCouch\ (and SWGRCouch-INSTALL.txt in the game
    folder).
  - Turn UE4SS off: Windows: delete or rename Griffin\Binaries\Win64\dwmapi.dll.
    Steam Deck / Linux: remove WINEDLLOVERRIDES="dwmapi=n,b" from the launch options.
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
  - Runs on UE4SS Galactic Racer Edition by GenerousMods (not included, get it from its page):
    https://www.nexusmods.com/starwarsgalacticracer/mods/2 . Thanks to GenerousMods for
    maintaining it. UE4SS itself: RE-UE4SS, https://github.com/UE4SS-RE/RE-UE4SS (MIT).

  Full README, source, the other downloads and the code signing policy:
    https://github.com/zhinu/swgrcouch
    https://git.jules.my/jules/swgrcouch

Fan-made and unofficial; not affiliated with Lucasfilm, Disney, Fuse Games or Secret Mode.
No game files are distributed. The game is not included: you need your own copy.
