#!/bin/bash
# package.sh VERSION [UE4SS_DIR]: build the release zips from this repo.
#   dist/SWGRCouch-VERSION.zip             README.md, LICENSE, install.sh, config/, docs/REFERENCE.md, every image the
#                                          README references, SWGRCouch/ (enabled.txt, native/ WITHOUT the compiled
#                                          DLL, Scripts/), ue4ss_signatures/, README-INPUTFILTER.md (0.13.1: the
#                                          plain zip ships no DLL - scanner-friendly; docs/INPUTFILTER.md explains)
#   dist/SWGRCouch-VERSION-no-UE4SS.zip    the full tree incl. the DLL, WITHOUT UE4SS: the recommended download;
#                                          players install UE4SS Galactic Racer Edition (GenerousMods) from its own
#                                          page (kept up to date after every game update; asked by its author)
#   dist/SWGRCouch-VERSION-with-UE4SS.zip  the full tree incl. the DLL + ue4ss-build/ (dwmapi.dll + ue4ss/: UE4SS
#                                          Galactic Racer Edition)
#   dist/swgr_inputfilter-VERSION.zip      the compiled DLL alone + README.md (= docs/INPUTFILTER.md) + sha256
#                                          + CODE-SIGNING-POLICY.md; SWGR_SIGNED_DLL=<signed dll> ships the signed DLL
#   dist/SWGRCouch-VERSION-nexus.zip       1.0: the lean Nexus Mods main file: NO DLL or executable at all (no UE4SS,
#                                          no input filter, no install.sh): SWGRCouch/ (enabled.txt, Scripts/,
#                                          native/ holding only a placeholder note) + LICENSE + README.txt, to drop
#                                          into <game>/Griffin/Binaries/Win64/ue4ss/Mods/
#   dist/swgr_inputfilter.dll              the bare DLL (release asset; Nexus optional file)
# The README's animations (docs/media/: GIFs and their MP4/WebM twins) are for the repo page and never ship in a zip.
# UE4SS_DIR holds dwmapi.dll and ue4ss/; default: the ue4ss-build/ folder of the newest dist/*-with-UE4SS.zip (the build
# every release since 0.10.1 ships). Checks: VERSION matches SWGRCouch/Scripts/consts.lua C.VERSION, every Lua file
# compiles (luac5.4 -p), no private path or account data in the shipped text files, no untracked file in the shipped
# folders. Only git-tracked files ship (review hyg-9: no *.bak*, build output or local config); docs/REFERENCE.md also
# goes in as SWGRCouch/README.md (install.sh copies it into the game's mod folder). Never deletes anything: an existing
# zip of the same name is moved aside with a timestamp.
set -euo pipefail
VER="${1:?usage: tools/package.sh VERSION [UE4SS_DIR]}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
DIST="$ROOT/dist"
NAME="SWGRCouch-$VER"
WORK=$(mktemp -d -p "${CLAUDE_JOB_DIR:-${TMPDIR:-/tmp}}" swgr-pkg.XXXXXX)

die() { echo "package.sh: $*" >&2; exit 1; }
# zipdir OUT.zip DIR: DIR (with its own name as the top folder) into OUT.zip, deflated, files in sorted order
zipdir() {
  python3 -I - "$1" "$2" <<'PY'
import os, sys, zipfile
out, src = sys.argv[1], sys.argv[2]
base = os.path.dirname(os.path.abspath(src))
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, base))
PY
}

# 1. checks
have=$(sed -n 's/^C\.VERSION *= *"\([^"]*\)".*/\1/p' SWGRCouch/Scripts/consts.lua)
[ "$have" = "$VER" ] || die "consts.lua says C.VERSION = \"$have\", not \"$VER\""
command -v luac5.4 > /dev/null && { luac5.4 -p SWGRCouch/Scripts/*.lua || die "a Lua file does not compile"; }
SHIP=(README.md LICENSE CODE-SIGNING-POLICY.md install.sh config ue4ss_signatures docs/REFERENCE.md SWGRCouch/enabled.txt SWGRCouch/native
      SWGRCouch/Scripts)
leak=$(git ls-files -z -- "${SHIP[@]}" | xargs -0 grep -IlP '/home/[a-z]+/|~/Games/project|7656119[0-9]{10}|~/Games/|(?<!swgrcouch@)ju\.l3s\.pw|forgejo-token|boite-noir' \
       2>/dev/null || true)
[ -z "$leak" ] || die "private data in: $leak"
untracked=$(git ls-files --others --exclude-standard -- "${SHIP[@]}")
[ -z "$untracked" ] || die "untracked files would be left out of the zip (git add or move them): $untracked"

# 2. the plain tree: git-tracked files only
P="$WORK/$NAME"
mkdir -p "$P"
nt=0
while IFS= read -r -d '' f; do
  mkdir -p "$P/$(dirname "$f")"
  cp -p "$f" "$P/$f"
  nt=$((nt + 1))
done < <(git ls-files -z -- "${SHIP[@]}")
cp -p docs/REFERENCE.md "$P/SWGRCouch/README.md"
# SWGR_SIGNED_DLL=<path>: ship the SignPath-signed DLL (artifact swgr_inputfilter-signed of the GitHub workflow
# build-inputfilter.yml) instead of the repo's unsigned build
if [ -n "${SWGR_SIGNED_DLL:-}" ]; then
  [ -f "$SWGR_SIGNED_DLL" ] || die "SWGR_SIGNED_DLL: no such file: $SWGR_SIGNED_DLL"
  cp "$SWGR_SIGNED_DLL" "$P/SWGRCouch/native/swgr_inputfilter.dll"
  echo "DLL: signed copy from $SWGR_SIGNED_DLL"
fi
echo "files: $nt tracked (+ SWGRCouch/README.md = docs/REFERENCE.md)"
n=0
while IFS= read -r img; do
  [ -f "$img" ] || die "README references a missing image: $img"
  mkdir -p "$P/$(dirname "$img")"
  cp -p "$img" "$P/$img"
  n=$((n + 1))
done < <(grep -oE '\]\((docs/[^) ]+\.(jpg|jpeg|png|gif|webp))\)' README.md | sed -E 's/^\]\(//; s/\)$//' | grep -v '^docs/media/' \
         | sort -u)
echo "images: $n referenced by README.md (docs/media/ left out)"

# 3. UE4SS for the second zip
U="${2:-}"
if [ -z "$U" ]; then
  last=$(ls -1t "$DIST"/*-with-UE4SS.zip 2>/dev/null | head -1 || true)
  [ -n "$last" ] || die "no UE4SS_DIR given and no dist/*-with-UE4SS.zip to take ue4ss-build/ from"
  mkdir -p "$WORK/u"
  (cd "$WORK/u" && unzip -q "$last" '*/ue4ss-build/*')
  U=$(find "$WORK/u" -maxdepth 2 -type d -name ue4ss-build | head -1)
  echo "UE4SS from $(basename "$last")"
fi
[ -f "$U/dwmapi.dll" ] && [ -d "$U/ue4ss" ] || die "no dwmapi.dll + ue4ss/ in $U"

# 4. zips (an existing one is kept under a dated name)
DLLNAME="swgr_inputfilter-$VER"
mkdir -p "$DIST"
for z in "$NAME.zip" "$NAME-no-UE4SS.zip" "$NAME-with-UE4SS.zip" "$DLLNAME.zip" "$NAME-nexus.zip" swgr_inputfilter.dll; do
  [ -e "$DIST/$z" ] && mv "$DIST/$z" "$DIST/$z.$(date +%Y%m%d-%H%M%S)"
done
# no-UE4SS: the full tree, DLL included, UE4SS from its author's page
cp -rp "$P" "$WORK/$NAME-no-UE4SS"
zipdir "$DIST/$NAME-no-UE4SS.zip" "$WORK/$NAME-no-UE4SS"
# with-UE4SS: the same + the UE4SS copy
cp -rp "$P" "$WORK/$NAME-with-UE4SS"
cp -rp "$U" "$WORK/$NAME-with-UE4SS/ue4ss-build"
zipdir "$DIST/$NAME-with-UE4SS.zip" "$WORK/$NAME-with-UE4SS"
# the DLL alone (its README = docs/INPUTFILTER.md, plus the hash to verify a self-built copy against)
DLL="SWGRCouch/native/swgr_inputfilter.dll"
[ -f "$P/$DLL" ] || die "no $DLL in the tree"
mkdir -p "$WORK/$DLLNAME"
cp -p "$P/$DLL" "$WORK/$DLLNAME/"
cp -p docs/INPUTFILTER.md "$WORK/$DLLNAME/README.md"
cp -p CODE-SIGNING-POLICY.md "$WORK/$DLLNAME/"
sha256sum "$P/$DLL" | sed "s|$P/$DLL|swgr_inputfilter.dll|" > "$WORK/$DLLNAME/swgr_inputfilter.dll.sha256"
zipdir "$DIST/$DLLNAME.zip" "$WORK/$DLLNAME"
cp -p "$P/$DLL" "$DIST/swgr_inputfilter.dll"
# the Nexus main file: the mod folder alone, no DLL / exe / script (Nexus optional file: the bare DLL)
NX="$WORK/$NAME-nexus"
mkdir -p "$NX/SWGRCouch/native"
cp -p SWGRCouch/enabled.txt "$NX/SWGRCouch/"
cp -rp "$P/SWGRCouch/Scripts" "$NX/SWGRCouch/"
cp -p LICENSE "$NX/"
cp -p tools/nexus/README.txt "$NX/"
cp -p tools/nexus/native-README.txt "$NX/SWGRCouch/native/README.txt"
sed -i "s/@VERSION@/$VER/g" "$NX/README.txt"
bad=$(find "$NX" -type f \( -iname '*.dll' -o -iname '*.exe' -o -iname '*.sh' -o -iname '*.bat' -o -iname '*.ps1' \
      -o -iname 'config_user.lua' -o -iname '*.gif' -o -iname '*.mp4' -o -iname '*.webm' \) )
[ -z "$bad" ] || die "the nexus zip would ship: $bad"
# a zip with its files at the top level (SWGRCouch/, LICENSE, README.txt): extracted into Mods/ as is
python3 -I - "$DIST/$NAME-nexus.zip" "$NX" <<'PY'
import os, sys, zipfile
out, src = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
# the plain zip ships WITHOUT the compiled DLL (0.13.1: scanner-friendly; solo works, split screen needs the DLL)
rm "$P/$DLL"
cp -p docs/INPUTFILTER.md "$P/README-INPUTFILTER.md"
zipdir "$DIST/$NAME.zip" "$WORK/$NAME"
for z in "$NAME.zip" "$NAME-no-UE4SS.zip" "$NAME-with-UE4SS.zip" "$DLLNAME.zip" "$NAME-nexus.zip"; do
  printf '%s  %s files  %s bytes  sha256 %s\n' "dist/$z" "$(unzip -Z1 "$DIST/$z" | grep -vc '/$')" \
    "$(stat -c %s "$DIST/$z")" "$(sha256sum "$DIST/$z" | cut -c1-16)"
done
printf '%s  %s bytes  sha256 %s\n' dist/swgr_inputfilter.dll "$(stat -c %s "$DIST/swgr_inputfilter.dll")" \
  "$(sha256sum "$DIST/swgr_inputfilter.dll" | cut -d' ' -f1)"
echo "work dir (kept): $WORK"
