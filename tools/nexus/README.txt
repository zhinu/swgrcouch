SWGRCouch @VERSION@ - split-screen couch play for STAR WARS Galactic Racer (1-4 local players)
================================================================================================

This is the lean download: the mod's Lua scripts only. It contains no DLL and no program.

REQUIRED
  UE4SS Galactic Racer Edition by GenerousMods, installed first from its Nexus page:
  https://www.nexusmods.com/starwarsgalacticracer/mods/2

INSTALL
  1. Install UE4SS Galactic Racer Edition as its page says.
     (Linux / Steam Deck: the launch option WINEDLLOVERRIDES="dwmapi=n,b" %command% as that page explains.)
  2. Open <game>\Griffin\Binaries\Win64\ue4ss\Mods\
     (Steam: ...\steamapps\common\STAR WARS Galactic Racer\Griffin\Binaries\Win64\ue4ss\Mods\)
  3. Copy the SWGRCouch folder from this zip into it, so that you get
         ue4ss\Mods\SWGRCouch\Scripts\main.lua
         ue4ss\Mods\SWGRCouch\enabled.txt
     When updating, copy over the old folder (your settings.txt and config_user.lua are kept).
  4. Start the game. The main menu gets a FREE MODE tab. ue4ss\UE4SS.log shows "SWGRCouch @VERSION@ loading".

OPTIONAL FILE: swgr_inputfilter.dll (the input filter)  -  YOU WANT THIS FOR SPLIT SCREEN
  Without the DLL the mod loads and solo play works, but in split screen the pads are NOT separated:
  every pad steers player 1's car and the players' inputs mix. With the DLL each player's pad drives
  only their own car.
  Download swgr_inputfilter.dll from the "Optional files" section of the Nexus page (or the GitHub /
  git.jules.my release) and put it into
         ue4ss\Mods\SWGRCouch\native\swgr_inputfilter.dll
  It is built from the C source in the public repo and rebuilds byte-identical (sha256 in the release notes).
  UE4SS.log then shows "native filter loaded: installed=1 reason=ok".

PLAY OFFLINE
  The mod turns off the game's Epic account link. Play with Steam in Offline Mode and Steam Cloud off
  for the game, and keep a copy of your pre-mod Saved folder. Details in the full README.

MORE
  Full README, Linux install script, the other downloads, source and code signing policy:
    https://github.com/zhinu/swgrcouch
    https://git.jules.my/jules/swgrcouch
  If the game was updated and UE4SS stops booting, the repo's ue4ss_signatures/ folder may help
  (copy its .lua files into ue4ss\UE4SS_Signatures\), or update UE4SS Galactic Racer Edition.

Found a bug? DM me on Nexus.

SWGRCouch is MIT licensed (LICENSE). Fan-made and unofficial; not affiliated with Lucasfilm, Disney,
Fuse Games or Secret Mode. No game files are distributed.
