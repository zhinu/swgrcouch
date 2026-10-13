#!/bin/bash
# Install UE4SS + SWGRCouch into a STAR WARS: Galactic Racer install, and/or the user-ini overrides (network
# Engine.ini, NO-INTRO GameUserSettings.ini key) into a Wine prefix. Never deletes a file: the UE4SS core files
# (dwmapi.dll, UE4SS.dll, MemberVariableLayout.ini, UE4SS.json) are replaced, a different old one first saved as a dated
# copy; every other existing UE4SS file is kept (cp -n); edited files get a dated copy first.
# User config dir in the prefix (first live run 2026-10-06; NOT .../AppData/Local/Griffin/...):
#   <prefix>/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/
# See docs/REFERENCE.md section 2 (the release zip also ships it as SWGRCouch/README.md).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [<game root containing Griffin/>] [options]

  <game root>          install UE4SS (if missing) and SWGRCouch into <root>/Griffin/Binaries/Win64
Options:
  --prefix <dir>       Wine prefix (Steam: ~/.local/share/Steam/steamapps/compatdata/4078430/pfx). Alone: append
                       config/Engine.ini (network override) to the user Engine.ini once
  --net-off            with --prefix: comment the override block out (official online play works again)
  --net-on             with --prefix: re-enable a block commented out by --net-off
  --fastboot-ini       with --prefix: GameUserSettings.ini [/Script/Griffin.GfnUserSettingsPC]
                       bEnableEOSAccountLinking=False, changed in place (docs/REFERENCE.md 2.6 "No-intro mode";
                       optional: fastboot.lua already turns the profile flag off at runtime). Does not touch
                       Engine.ini unless --net is given
  --fastboot-ini-undo  with --prefix: the same key back to True (Epic account linking wanted again)
  --net                with --fastboot-ini(-undo): also append the network override (the --prefix default)
  --ue57               UE4SS-settings.ini: [EngineVersionOverride] MajorVersion=5 MinorVersion=7 (only if the
                       log shows a wrong engine version / failed scans)
  --gt-processevent    UE4SS-settings.ini: DefaultExecuteInGameThreadMethod = ProcessEvent (only if the boot
                       banner shows EngineTickAvailable=false; V-CORE-01)
  --console            UE4SS-settings.ini: the log console and the GUI console on (testers, bug reports)
  --quiet-console      UE4SS-settings.ini: both consoles off again
  -h, --help           this text
Lutris: environment WINEDLLOVERRIDES="dwmapi=n,b" on the entry that starts Steam.
EOF
}

GAME=""; PREFIX=""; NET_ACTION="add"; NET_EXPLICIT=0; FB_INI=""; UE57=0; GTPE=0; QUIET=0; CONSOLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --net-off) NET_ACTION="off"; NET_EXPLICIT=1; shift ;;
    --net-on) NET_ACTION="on"; NET_EXPLICIT=1; shift ;;
    --net) NET_ACTION="add"; NET_EXPLICIT=1; shift ;;
    --fastboot-ini) FB_INI="False"; shift ;;
    --fastboot-ini-undo) FB_INI="True"; shift ;;
    --ue57) UE57=1; shift ;;
    --gt-processevent) GTPE=1; shift ;;
    --quiet-console) QUIET=1; shift ;;
    --console) CONSOLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$GAME" ] || { echo "only one game root" >&2; exit 2; }; GAME="$1"; shift ;;
  esac
done
[ -n "$GAME" ] || [ -n "$PREFIX" ] || { usage >&2; exit 2; }
if [ "$NET_EXPLICIT" = 1 ] && [ -z "$PREFIX" ]; then echo "--net/--net-off/--net-on need --prefix" >&2; exit 2; fi
if [ -n "$FB_INI" ] && [ -z "$PREFIX" ]; then echo "--fastboot-ini(-undo) needs --prefix" >&2; exit 2; fi
# --prefix alone keeps its old meaning (network override); with only --fastboot-ini(-undo) the Engine.ini is untouched
DO_NET=1
if [ -n "$FB_INI" ] && [ "$NET_EXPLICIT" = 0 ]; then DO_NET=0; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# UE4SS Galactic Racer Edition, open beta 2026-10-08 (the build the mod is tested with; required since the game
# hotfix CL382493, UE4SS 3.0.1-1160 crashes on it): $UE4SS_DIR, else ./ue4ss-build next to this script
# (the release zip "with-UE4SS" ships it), else an UE4SS already installed in the game is used as it is.
UE4SS_SRC="${UE4SS_DIR:-$HERE/ue4ss-build}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARK_BEGIN='; >>> SWGRCouch network override >>>'
MARK_END='; <<< SWGRCouch network override <<<'
OFF_TAG=';SWGRCouch-off;'

# Dated copy of a file before the first edit of this run (never overwrites an earlier copy).
backup() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ -e "$f.swgrcouch-$STAMP" ] || cp -p "$f" "$f.swgrcouch-$STAMP"
}

# key = value in UE4SS-settings.ini (keys used here are unique in the shipped file).
set_ini() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}[[:space:]]*=" "$file"; then
    sed -i "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
  else
    echo "WARN: ${key} not found in $(basename "$file"); set it by hand" >&2
  fi
}

# ---------------------------------------------------------------------------------------------------- mod + UE4SS
install_mod() {
  local BIN="$GAME/Griffin/Binaries/Win64"
  [ -f "$BIN/SWGR-Win64-Shipping.exe" ] || { echo "no SWGR-Win64-Shipping.exe in $BIN" >&2; exit 1; }
  # a re-install keeps the console choice of an existing UE4SS-settings.ini (2026-10-10: every re-install switched the
  # windows back on); a first install keeps UE4SS's bundled values (both off) unless --console is given
  local HAD_SETTINGS=0
  [ -f "$BIN/ue4ss/UE4SS-settings.ini" ] && HAD_SETTINGS=1
  if [ -f "$UE4SS_SRC/dwmapi.dll" ]; then
    # 1. UE4SS (existing files, e.g. an edited UE4SS-settings.ini or mods.txt, are kept). The core files are
    #    always replaced (dated copy first): an older UE4SS left in place does not boot on the hotfixed game.
    mkdir -p "$BIN/ue4ss"
    local core
    for core in dwmapi.dll ue4ss/UE4SS.dll ue4ss/MemberVariableLayout.ini ue4ss/UE4SS_SDK_Backends/UE4SS.json; do
      [ -f "$UE4SS_SRC/$core" ] || continue
      if [ -f "$BIN/$core" ] && ! cmp -s "$UE4SS_SRC/$core" "$BIN/$core"; then backup "$BIN/$core"; fi
      mkdir -p "$(dirname "$BIN/$core")"; cp "$UE4SS_SRC/$core" "$BIN/$core"
    done
    cp -rn "$UE4SS_SRC/ue4ss/." "$BIN/ue4ss/"
  elif [ -f "$BIN/dwmapi.dll" ] && [ -d "$BIN/ue4ss" ]; then
    echo "UE4SS: already installed in $BIN (kept as it is)"
    # UE4SS 3.0.1-1160 (the 0.9.0 / 0.9.1 zips) does not boot on the hotfixed game (CL382493)
    if [ -f "$BIN/ue4ss/UE4SS.dll" ] && command -v md5sum > /dev/null \
       && [ "$(md5sum < "$BIN/ue4ss/UE4SS.dll" | cut -c1-32)" = "a7e144e53056aebdee36df778def2473" ]; then
      echo "WARNING: the installed UE4SS is 3.0.1-1160, which does not boot on the current game. Install from the" >&2
      echo "         release zip 'with-UE4SS' (it ships the UE4SS Galactic Racer Edition) or set UE4SS_DIR to it." >&2
    fi
  else
    echo "UE4SS not found: use the release zip 'with-UE4SS' (it ships the UE4SS Galactic Racer Edition), or set" >&2
    echo "UE4SS_DIR to an unpacked UE4SS Galactic Racer Edition (dwmapi.dll + ue4ss/)" >&2
    exit 1
  fi

  # 2. SWGRCouch: every script, enabled.txt, README. settings.txt / Scripts/config_user.lua are not shipped, so a
  #    re-install never touches them.
  local DST="$BIN/ue4ss/Mods/SWGRCouch"
  mkdir -p "$DST/Scripts"
  cp "$HERE"/SWGRCouch/Scripts/*.lua "$DST/Scripts/"
  cp "$HERE/SWGRCouch/enabled.txt" "$DST/"
  [ -f "$HERE/SWGRCouch/README.md" ] && cp "$HERE/SWGRCouch/README.md" "$DST/"
  echo "SWGRCouch: $(ls "$HERE"/SWGRCouch/Scripts/*.lua | wc -l) scripts -> $DST/Scripts"
  command -v luac5.4 >/dev/null && for f in "$DST"/Scripts/*.lua; do luac5.4 -p "$f" || echo "SYNTAX ERROR: $f" >&2; done

  # 2a. Native input filter (inputfix.lua, InputFixMode "auto"/"native"): native/swgr_inputfilter.dll. The DLL pins
  #     itself in the game process: overwriting it while the game runs would corrupt the mapped image, so a changed
  #     DLL is only copied while the game is closed. Without it the mod falls back to kbsplit (logged).
  local NSRC="$HERE/SWGRCouch/native/swgr_inputfilter.dll"
  if [ -f "$NSRC" ]; then
    mkdir -p "$DST/native"
    if [ -f "$DST/native/swgr_inputfilter.dll" ] && cmp -s "$NSRC" "$DST/native/swgr_inputfilter.dll"; then
      echo "SWGRCouch: native/swgr_inputfilter.dll up to date"
    elif pgrep -f 'SWGR-Win64-Shipping' >/dev/null 2>&1; then
      echo "WARN: the game is running: native/swgr_inputfilter.dll NOT copied (quit the game and re-run install.sh)" >&2
    else
      cp "$NSRC" "$DST/native/"
      echo "SWGRCouch: native/swgr_inputfilter.dll -> $DST/native"
    fi
  else
    echo "WARN: $NSRC missing: split-screen input isolation is OFF (solo play is fine)." >&2
    echo "      Download swgr_inputfilter-<version>.zip from the release and put the DLL in SWGRCouch/native/," >&2
    echo "      or build it with SWGRCouch/native/inputfilter/build.sh, then re-run install.sh." >&2
  fi

  # 2b. Custom AOB signatures for this build (mod/ue4ss_signatures, first live run 2026-10-06). A different existing
  #     file gets a dated copy before it is replaced.
  if [ -d "$HERE/ue4ss_signatures" ]; then
    mkdir -p "$BIN/ue4ss/UE4SS_Signatures"
    local sig dst
    for sig in "$HERE"/ue4ss_signatures/*.lua; do
      [ -f "$sig" ] || continue
      dst="$BIN/ue4ss/UE4SS_Signatures/$(basename "$sig")"
      if [ -f "$dst" ] && cmp -s "$sig" "$dst"; then continue; fi
      backup "$dst"
      cp "$sig" "$dst"
    done
    echo "UE4SS signatures: $(ls "$HERE"/ue4ss_signatures/*.lua | wc -l) file(s) -> $BIN/ue4ss/UE4SS_Signatures"
  fi

  # 3. mods.txt (CRLF file): SWGRCouch first (above "Keybinds : 1", which must stay last), SplitScreenMod off,
  #    ConsoleEnablerMod on (the `couch` console command needs it).
  local MT="$BIN/ue4ss/Mods/mods.txt"
  backup "$MT"
  if grep -q '^SWGRCouch' "$MT"; then
    sed -i 's/^SWGRCouch[[:space:]]*:[[:space:]]*0/SWGRCouch : 1/' "$MT"
  else
    sed -i '1i SWGRCouch : 1\r' "$MT"
  fi
  sed -i 's/^SplitScreenMod[[:space:]]*:[[:space:]]*1/SplitScreenMod : 0/' "$MT"
  # BPModLoaderMod's Insert keybind calls ExecuteInGameThread from UE4SS's event-loop thread while its BeginPlay hook
  # runs Lua on the game thread: the same cross-thread race as crash_2026_10_08_13_27_33. Off when no Blueprint mod
  # (.pak in Content/Paks/LogicMods) needs it; mods.json carries the same switch.
  if ! ls "$GAME/Griffin/Content/Paks/LogicMods/"*.pak >/dev/null 2>&1; then
    sed -i 's/^BPModLoaderMod[[:space:]]*:[[:space:]]*1/BPModLoaderMod : 0/' "$MT"
    local MJ="$BIN/ue4ss/Mods/mods.json"
    if [ -f "$MJ" ] && grep -q '"BPModLoaderMod"' "$MJ"; then
      backup "$MJ"
      python3 -I - "$MJ" <<'PYEOF' || echo "mods.json: BPModLoaderMod left as it is" >&2
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for m in d:
    if m.get("mod_name") == "BPModLoaderMod": m["mod_enabled"] = False
open(p, "w").write(json.dumps(d, indent=4))
PYEOF
    fi
  fi
  if grep -q '^ConsoleEnablerMod' "$MT"; then
    sed -i 's/^ConsoleEnablerMod[[:space:]]*:[[:space:]]*0/ConsoleEnablerMod : 1/' "$MT"
  else
    sed -i '1a ConsoleEnablerMod : 1\r' "$MT"
  fi

  # 4. UE4SS-settings.ini: consoles only on request; optional engine-version and game-thread fallbacks.
  local SI="$BIN/ue4ss/UE4SS-settings.ini"
  backup "$SI"
  if [ "$QUIET" = 1 ]; then
    # run I (2026-10-07): both windows off (the text console and the OpenGL debug GUI sat behind the fullscreen game;
    # the GUI's toggle key O is also the game's keyboard player-menu key); UE4SS.log keeps everything
    set_ini "$SI" ConsoleEnabled 0; set_ini "$SI" GuiConsoleEnabled 0; set_ini "$SI" GuiConsoleVisible 0
  elif [ "$CONSOLE" = 1 ]; then
    set_ini "$SI" ConsoleEnabled 1; set_ini "$SI" GuiConsoleEnabled 1; set_ini "$SI" GuiConsoleVisible 1
  else
    # 0.12.0 (review hyg-7): a first install keeps the bundled values (both off); UE4SS.log has everything
    [ "$HAD_SETTINGS" = 1 ] && echo "UE4SS: console windows left as they are (--console / --quiet-console change them)"
  fi
  # the Galactic Racer Edition needs these two on the hotfixed game (an older settings file is kept, so set them here)
  set_ini "$SI" bForceGUObjectArrayForIteration true; set_ini "$SI" UseCache 0
  if [ "$UE57" = 1 ]; then set_ini "$SI" MajorVersion 5; set_ini "$SI" MinorVersion 7; fi
  [ "$GTPE" = 1 ] && set_ini "$SI" DefaultExecuteInGameThreadMethod ProcessEvent
  echo "UE4SS: $BIN/ue4ss (mods.txt and UE4SS-settings.ini updated; copies *.swgrcouch-$STAMP)"
}

# ---------------------------------------------------------------------------------------------------- user ini dir
# The game's user config layer (verified in the Steam prefix: GameUserSettings.ini is written there).
cfg_dir() { echo "$PREFIX/drive_c/users/steamuser/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows"; }
OLD_DIR_REL="drive_c/users/steamuser/AppData/Local/Griffin/Saved/Config/Windows"

# ---------------------------------------------------------------------------------------------------- Engine.ini
net_ini() {
  local DIR; DIR="$(cfg_dir)"
  local EI="$DIR/Engine.ini"
  local SRC="$HERE/config/Engine.ini"
  [ -d "$PREFIX/drive_c" ] || { echo "not a Wine prefix: $PREFIX" >&2; exit 1; }
  # earlier versions of this script wrote to .../AppData/Local/Griffin/...: the game never reads that file
  if [ -f "$PREFIX/$OLD_DIR_REL/Engine.ini" ] && grep -qF "$MARK_BEGIN" "$PREFIX/$OLD_DIR_REL/Engine.ini"; then
    echo "NOTE: $PREFIX/$OLD_DIR_REL/Engine.ini holds an old SWGRCouch block in a folder the game does not read" \
      "(left untouched; it has no effect)" >&2
  fi
  case "$NET_ACTION" in
    add)
      mkdir -p "$DIR"; touch "$EI"
      if grep -q '^+NetDriverDefinitions=.*OnlineSubsystemUtils\.IpNetDriver' "$EI"; then
        echo "Engine.ini: override already active in $EI"
      elif grep -qF "$MARK_BEGIN" "$EI"; then
        echo "Engine.ini: override present but commented out; use --net-on"
      else
        backup "$EI"
        { printf '\n'; cat "$SRC"; } >> "$EI"
        echo "Engine.ini: override appended to $EI"
      fi ;;
    off|on)
      [ -f "$EI" ] && grep -qF "$MARK_BEGIN" "$EI" || {
        echo "Engine.ini: no SWGRCouch block (markers) in $EI; run --prefix without --net-off/--net-on first" >&2; exit 1; }
      backup "$EI"
      if [ "$NET_ACTION" = off ]; then
        # prefix every non-comment, non-empty line between the markers
        sed -i "\|^; >>> SWGRCouch|,\|^; <<< SWGRCouch|{/^[^;]/s|^|$OFF_TAG|}" "$EI"
        echo "Engine.ini: override commented out (official online play possible)"
      else
        sed -i "\|^; >>> SWGRCouch|,\|^; <<< SWGRCouch|s|^$OFF_TAG||" "$EI"
        echo "Engine.ini: override active again"
      fi ;;
  esac
}

# ---------------------------------------------------------------------------------------------------- GameUserSettings.ini
# NO-INTRO companion (cfg.FastBootEpic "off"): bEnableEOSAccountLinking in place, never a second copy of the section.
# The file is CRLF (written by the game); the value is replaced without touching the line ending.
fastboot_ini() {
  local DIR; DIR="$(cfg_dir)"
  local GU="$DIR/GameUserSettings.ini"
  local KEY="bEnableEOSAccountLinking" SEC='[/Script/Griffin.GfnUserSettingsPC]'
  [ -d "$PREFIX/drive_c" ] || { echo "not a Wine prefix: $PREFIX" >&2; exit 1; }
  if [ ! -f "$GU" ]; then
    echo "GameUserSettings.ini: $GU does not exist yet (start the game once, quit, re-run)" >&2
    return 0
  fi
  local eol=""
  if head -n 1 "$GU" | grep -q $'\r$'; then eol=$'\r'; fi
  if grep -q "^${KEY}=${FB_INI}"$'\r*$' "$GU"; then
    echo "GameUserSettings.ini: ${KEY}=${FB_INI} already set in $GU"
    return 0
  fi
  backup "$GU"
  if grep -q "^${KEY}=" "$GU"; then
    sed -i "s/^\(${KEY}=\)[A-Za-z0-9]*/\1${FB_INI}/" "$GU"
  elif grep -qF "$SEC" "$GU"; then
    sed -i "/^\[\/Script\/Griffin\.GfnUserSettingsPC\]/a ${KEY}=${FB_INI}${eol}" "$GU"
  else
    printf '%s%s\n%s=%s%s\n' "$SEC" "$eol" "$KEY" "$FB_INI" "$eol" >> "$GU"
  fi
  echo "GameUserSettings.ini: ${KEY}=${FB_INI} in $GU (copy *.swgrcouch-$STAMP)"
  [ "$FB_INI" = True ] && echo "  also set FastBootEpic = \"keep\" in Scripts/config_user.lua, else the mod turns it off again"
  return 0
}

[ -n "$GAME" ] && install_mod
if [ -n "$PREFIX" ]; then
  [ "$DO_NET" = 1 ] && net_ini
  [ -n "$FB_INI" ] && fastboot_ini
fi
echo "Lutris: WINEDLLOVERRIDES=\"dwmapi=n,b\" on the entry that starts Steam. Log: Griffin/Binaries/Win64/ue4ss/UE4SS.log"
[ -n "$PREFIX" ] || echo "Network races: re-run with --prefix <wine prefix> on every machine (docs/REFERENCE.md 2.4)."
echo "OFFLINE PLAY ONLY: with the mod, the game's online mode may stop working (the mod turns the game's Epic account"
echo "link off in your profile). Start Steam in Offline Mode to play; see the warning at the top of README.md."
exit 0
