#!/bin/bash
# package.sh VERSION [UE4SS_DIR]: build the release zips from this repo.
#   dist/SWGRCouch-VERSION.zip             README.md, LICENSE, install.sh, config/, docs/REFERENCE.md, every image the
#                                          README references, SWGRCouch/ (enabled.txt, native/, Scripts/),
#                                          ue4ss_signatures/
#   dist/SWGRCouch-VERSION-with-UE4SS.zip  the same + ue4ss-build/ (dwmapi.dll + ue4ss/: UE4SS Galactic Racer Edition)
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
SHIP=(README.md LICENSE install.sh config ue4ss_signatures docs/REFERENCE.md SWGRCouch/enabled.txt SWGRCouch/native
      SWGRCouch/Scripts)
leak=$(git ls-files -z -- "${SHIP[@]}" | xargs -0 grep -IlE '/home/[a-z]+/|~/Games/project|7656119[0-9]{10}|ju\.l3s\.pw|forgejo-token|boite-noir' \
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
echo "files: $nt tracked (+ SWGRCouch/README.md = docs/REFERENCE.md)"
n=0
while IFS= read -r img; do
  [ -f "$img" ] || die "README references a missing image: $img"
  mkdir -p "$P/$(dirname "$img")"
  cp -p "$img" "$P/$img"
  n=$((n + 1))
done < <(grep -oE '\]\((docs/[^) ]+\.(jpg|jpeg|png|gif|webp))\)' README.md | sed -E 's/^\]\(//; s/\)$//' | sort -u)
echo "images: $n referenced by README.md"

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
mkdir -p "$DIST"
for z in "$NAME.zip" "$NAME-with-UE4SS.zip"; do
  [ -e "$DIST/$z" ] && mv "$DIST/$z" "$DIST/$z.$(date +%Y%m%d-%H%M%S)"
done
zipdir "$DIST/$NAME.zip" "$WORK/$NAME"
cp -rp "$P" "$WORK/$NAME-with-UE4SS"
cp -rp "$U" "$WORK/$NAME-with-UE4SS/ue4ss-build"
zipdir "$DIST/$NAME-with-UE4SS.zip" "$WORK/$NAME-with-UE4SS"
for z in "$NAME.zip" "$NAME-with-UE4SS.zip"; do
  printf '%s  %s files  %s bytes  sha256 %s\n' "dist/$z" "$(unzip -Z1 "$DIST/$z" | grep -vc '/$')" \
    "$(stat -c %s "$DIST/$z")" "$(sha256sum "$DIST/$z" | cut -c1-16)"
done
echo "work dir (kept): $WORK"
