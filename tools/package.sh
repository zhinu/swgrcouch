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
#   dist/SWGRCouch-VERSION-gameroot.zip    1.0.1, the main download for now: the game-root tree WITHOUT UE4SS, files at
#                                          the zip's top level, extracted into the folder that contains Griffin\ AFTER
#                                          UE4SS Galactic Racer Edition is installed from its own Nexus page:
#                                            SWGRCouch-INSTALL.txt                     (tools/gameroot/README.txt; a name
#                                              no other mod's README.txt overwrites; the same text is the mod folder's
#                                              README.txt)
#                                            Griffin/Binaries/Win64/ue4ss/Mods/SWGRCouch/ (as below, the DLL included)
#                                          1.0.3: of our UE4SS_Signatures/ ONLY the two UE4SS Galactic Racer Edition
#                                          V0.9.4 does not ship ($SIG_ADD: GNatives.lua, GUObjectHashTables.lua): his
#                                          four (FName_Constructor, FName_ToString, GUObjectArray identical to ours, his
#                                          GMalloc resolving to the same address) are never replaced - the build dies
#                                          if the UE4SS copy has a file of the same name. Without the two, V0.9.4 logs
#                                          "GNatives not found" / "Failed to find FUObjectHashTables::Get" and the game
#                                          crashed at every couch race load on CL386500 (live 2026-10-24, 3 of 3;
#                                          0 of 6 races with them).
#                                          NO mods.txt / mods.json (1.0.1 round 13: the zip's copies replaced the
#                                          player's and switched his other UE4SS mods off): UE4SS Galactic Racer Edition
#                                          (3.0.1 e3ba1016) starts every Mods/<name>/ folder that has an enabled.txt,
#                                          also when mods.txt does not list it or says 0 (live 2026-10-09: "Mod
#                                          'SWGRCouch' has enabled.txt, starting mod." with "SWGRCouch : 0" in mods.txt).
#                                          Checked: nothing outside ue4ss/Mods/SWGRCouch/ besides SWGRCouch-INSTALL.txt.
#                                          no dwmapi.dll, no UE4SS.dll, no UE4SS-settings.ini, no UE4SS LICENSE:
#                                          one binary (swgr_inputfilter.dll), checked
#   dist/SWGRCouch-VERSION-gameroot-with-UE4SS.zip
#                                          the all-in-one variant (only if the UE4SS author agrees to it being
#                                          bundled): the same tree + UE4SS, README.txt from
#                                          tools/gameroot/README-with-UE4SS.txt:
#                                            SWGRCouch-INSTALL.txt (+ the same text as Mods/SWGRCouch/README.txt)
#                                            Griffin/Binaries/Win64/dwmapi.dll         (UE4SS loader)
#                                            Griffin/Binaries/Win64/ue4ss/             (1.0.3: UE4SS Galactic Racer Edition
#                                              EXACTLY as its author ships it - LICENSE, UE4SS_Signatures/, settings,
#                                              mods - every file byte-identical to the UE4SS copy (checked), except
#                                              mods.txt / mods.json: his files with "SWGRCouch : 1" added first (and
#                                              SplitScreenMod forced to 0 if a copy ever ships it on), mods.json the
#                                              same entries in the same order (checked); UE4SS-settings.ini checked
#                                              for the two keys the mod needs: bForceGUObjectArrayForIteration = true,
#                                              UseCache = 0)
#                                            .../ue4ss/Mods/SWGRCouch/                 enabled.txt, LICENSE, README.md
#                                              (= docs/REFERENCE.md, checked: no relative link), README.txt (the install
#                                              text), Scripts/*.lua, native/swgr_inputfilter.dll (the DLL slot below)
#                                              + native/swgrcouch-cert.pem when the DLL is the signed one
#                                          Never in it (checked): config_user.lua, settings.txt, any run / GP / garage
#                                          save, log, test file, the DLL's runtime .cfg/.pads/.status, any .exe. The
#                                          player's own files therefore survive an extract over an older install.
# DLL SLOT: every zip that carries swgr_inputfilter.dll (no-UE4SS, with-UE4SS, gameroot, swgr_inputfilter-VERSION,
# the bare dist/swgr_inputfilter.dll) takes it from one place, $P/SWGRCouch/native/swgr_inputfilter.dll: the repo's
# unsigned build, or SWGR_SIGNED_DLL=<signed dll> (checked: a PE file whose sha256 is printed and written into the
# gameroot README.txt, "signed" in its DLL line). Re-running with SWGR_SIGNED_DLL rebuilds every zip with the signed copy.
# The README's banners and animations (docs/media/: JPGs, GIFs and their MP4/WebM twins) are for the repo page and
# never ship in a zip (checked on every zip): the README.md copy in the zips points its docs/media/ links at the
# public repo (https://git.jules.my/jules/swgrcouch/raw/branch/main/docs/media/...), and every README.md shipped is
# checked for a relative link to a file the zip does not carry.
# The DLL zip also carries docs/signing/swgrcouch-cert.pem (the PUBLIC certificate of the author's signature); with
# SWGR_SIGNED_DLL every zip with the DLL in SWGRCouch/native/ carries it next to the DLL (the install text's verify lines).
# UE4SS_DIR holds dwmapi.dll and ue4ss/, or is the UE4SS Galactic Racer Edition zip as its author ships it (dwmapi.dll
# and ue4ss/ at its top level), or a *-with-UE4SS.zip to take its ue4ss-build/ from; default: the
# ue4ss-build/ folder of the newest dist/*-with-UE4SS.zip (the build every release since 0.10.1 ships; a fresh
# worktree has no dist/: pass the previous release's zip, e.g. ../swgrcouch-rel10/dist/SWGRCouch-1.0.0-with-UE4SS.zip).
# Re-runnable: it reads only the checked-out tree, so after another fix branch is merged, run it again with the same
# arguments (older zips of the same name are moved aside with a timestamp). Checks: VERSION matches SWGRCouch/Scripts/consts.lua C.VERSION, every Lua file
# compiles (luac5.4 -p), no private path or account data in the shipped text files, no untracked file in the shipped
# folders. Only git-tracked files ship (review hyg-9: no *.bak*, build output or local config); docs/REFERENCE.md also
# goes in as SWGRCouch/README.md (install.sh copies it into the game's mod folder). Never deletes anything: an existing
# zip of the same name is moved aside with a timestamp.
set -euo pipefail
VER="${1:?usage: tools/package.sh VERSION [UE4SS_DIR]}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# UE4SS_DIR / SWGR_SIGNED_DLL may be relative to the caller's directory
U="${2:-}"
[ -z "$U" ] || U=$(realpath -- "$U")
[ -z "${SWGR_SIGNED_DLL:-}" ] || SWGR_SIGNED_DLL=$(realpath -- "$SWGR_SIGNED_DLL")
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
# docs/media/ never ships: the zips' README.md shows the banners / animations from the public repo
MEDIA_URL="https://git.jules.my/jules/swgrcouch/raw/branch/main/docs/media/"
sed -i -E "s#(\]\(|src=\")docs/media/#\1${MEDIA_URL}#g" "$P/README.md"
# relcheck FILE.md ROOT: every relative link / image of FILE.md must exist under ROOT (the zip tree it ships in)
relcheck() {
  python3 -I - "$1" "$2" <<'PY' || die "$1: relative link to a file the zip does not carry"
import os, re, sys
md, root = sys.argv[1], sys.argv[2]
bad = []
for m in re.finditer(r'(?:\]\(|src=")([^)"\s#]+)', open(md, encoding="utf-8").read()):
    t = m.group(1)
    if re.match(r'^[a-z]+:', t):
        continue
    if not os.path.exists(os.path.join(root, t)):
        bad.append(t)
if bad:
    print("relative links not in the zip:", sorted(set(bad)), file=sys.stderr)
    sys.exit(1)
PY
}
# SWGR_SIGNED_DLL=<path>: ship a signed DLL instead of the repo's unsigned build (the author's self-signed copy,
# certificate in docs/signing/; CODE-SIGNING-POLICY.md)
# DLL SLOT (see the header): the one copy every DLL-carrying zip below is built from
DLLSTATE="unsigned"
if [ -n "${SWGR_SIGNED_DLL:-}" ]; then
  [ -f "$SWGR_SIGNED_DLL" ] || die "SWGR_SIGNED_DLL: no such file: $SWGR_SIGNED_DLL"
  [ "$(head -c 2 "$SWGR_SIGNED_DLL")" = "MZ" ] || die "SWGR_SIGNED_DLL: not a PE file: $SWGR_SIGNED_DLL"
  cp "$SWGR_SIGNED_DLL" "$P/SWGRCouch/native/swgr_inputfilter.dll"
  DLLSTATE="signed by the author, self-signed certificate"
  echo "DLL: signed copy from $SWGR_SIGNED_DLL"
fi
DLLSHA=$(sha256sum "$P/SWGRCouch/native/swgr_inputfilter.dll" | cut -d' ' -f1)
echo "DLL: $DLLSTATE, sha256 $DLLSHA"
# 1.0.1 round 13: the signed DLL's public certificate goes next to it (osslsigncode verify -CAfile needs it)
CERT="$P/SWGRCouch/native/swgrcouch-cert.pem"
CERTFP=""
if [ -n "${SWGR_SIGNED_DLL:-}" ]; then
  [ -f docs/signing/swgrcouch-cert.pem ] || die "docs/signing/swgrcouch-cert.pem missing"
  ! grep -q "PRIVATE KEY" docs/signing/swgrcouch-cert.pem || die "docs/signing/swgrcouch-cert.pem holds a private key"
  cp -p docs/signing/swgrcouch-cert.pem "$CERT"
  CERTFP=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')
  [ -n "$CERTFP" ] || die "swgrcouch-cert.pem: no SHA-256 fingerprint (openssl)"
  if command -v osslsigncode > /dev/null; then
    osslsigncode verify -CAfile "$CERT" -in "$P/SWGRCouch/native/swgr_inputfilter.dll" > "$WORK/verify.txt" 2>&1 \
      || die "the signed DLL does not verify against docs/signing/swgrcouch-cert.pem ($WORK/verify.txt)"
    echo "DLL: osslsigncode verify -CAfile swgrcouch-cert.pem: ok"
  fi
  echo "certificate: SHA-256 $CERTFP"
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
echo "images: $n referenced by README.md (docs/media/ left out: linked to the public repo)"
relcheck "$P/README.md" "$P"
relcheck "$P/SWGRCouch/README.md" "$P/SWGRCouch"

# 3. UE4SS for the with-UE4SS and gameroot zips
if [ -n "$U" ] && [ "${U%.zip}" != "$U" ] && unzip -Z1 "$U" 2>/dev/null | grep -qx 'ue4ss/UE4SS.dll'; then
  # 1.0.3: the author's own UE4SS Galactic Racer Edition zip (dwmapi.dll + ue4ss/ at the top), taken whole
  mkdir -p "$WORK/u/ue4ss-build"
  (cd "$WORK/u/ue4ss-build" && unzip -q "$U")
  echo "UE4SS from $(basename "$U") (the author's zip)"
  U="$WORK/u/ue4ss-build"
elif [ -z "$U" ] || [ "${U%.zip}" != "$U" ]; then
  last="$U"
  [ -n "$last" ] || last=$(ls -1t "$DIST"/*-with-UE4SS.zip 2>/dev/null | grep -v -- '-gameroot-with-UE4SS\.zip$' | head -1 || true)
  case "$last" in *-gameroot-with-UE4SS.zip) die "pass a *-with-UE4SS.zip with ue4ss-build/, not the gameroot one";; esac
  [ -n "$last" ] || die "no UE4SS_DIR given and no dist/*-with-UE4SS.zip to take ue4ss-build/ from"
  [ -f "$last" ] || die "no such zip: $last"
  mkdir -p "$WORK/u"
  (cd "$WORK/u" && unzip -q "$last" '*/ue4ss-build/*')
  U=$(find "$WORK/u" -maxdepth 2 -type d -name ue4ss-build | head -1)
  echo "UE4SS from $(basename "$last")"
fi
[ -f "$U/dwmapi.dll" ] && [ -d "$U/ue4ss" ] || die "no dwmapi.dll + ue4ss/ in $U"
UMD5=$(md5sum "$U/ue4ss/UE4SS.dll" | cut -d' ' -f1)
echo "UE4SS.dll md5 $UMD5"

# 4. zips (an existing one is kept under a dated name)
DLLNAME="swgr_inputfilter-$VER"
SIG_ADD="${SWGR_SIG_ADD:-GNatives.lua GUObjectHashTables.lua}"   # 1.0.3: the signatures UE4SS GR Edition V0.9.4 lacks
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
[ -f docs/signing/swgrcouch-cert.pem ] && [ -f docs/signing/README.md ] || die "docs/signing/swgrcouch-cert.pem + README.md missing"
! grep -q "PRIVATE KEY" docs/signing/* || die "docs/signing/ holds a private key"
cp -p docs/signing/swgrcouch-cert.pem "$WORK/$DLLNAME/"
cp -p docs/signing/README.md "$WORK/$DLLNAME/SIGNING-CERT.md"
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
# the gameroot zips (1.0.1): the game folder's own layout, extracted into the folder that contains Griffin\.
# GR = the tree both share (mod folder, signatures, mods.txt / mods.json with install.sh's edits); the main
# -gameroot.zip is GR alone (UE4SS from its author's page), -gameroot-with-UE4SS.zip is GR + the UE4SS copy.
GR="$WORK/$NAME-gameroot"
GW="$GR/Griffin/Binaries/Win64"
mkdir -p "$GW/ue4ss/Mods" "$GW/ue4ss/UE4SS_Signatures"
for sig in $SIG_ADD; do
  [ -f "$P/ue4ss_signatures/$sig" ] || die "ue4ss_signatures/$sig missing"
  [ ! -e "$U/ue4ss/UE4SS_Signatures/$sig" ] || die "the UE4SS copy ships UE4SS_Signatures/$sig: never replace it (drop it from SIG_ADD)"
  cp -p "$P/ue4ss_signatures/$sig" "$GW/ue4ss/UE4SS_Signatures/"
done
GM="$GW/ue4ss/Mods/SWGRCouch"
mkdir -p "$GM/Scripts" "$GM/native"
cp -p "$P"/SWGRCouch/Scripts/*.lua "$GM/Scripts/"
cp -p "$P/SWGRCouch/enabled.txt" "$P/SWGRCouch/README.md" "$GM/"
cp -p LICENSE "$GM/"
cp -p "$P/$DLL" "$GM/native/"                                    # the DLL SLOT copy (signed when SWGR_SIGNED_DLL)
[ ! -f "$CERT" ] || cp -p "$CERT" "$GM/native/"                  # its public certificate (signed only)
relcheck "$GM/README.md" "$GM"
# the with-UE4SS variant: GR + the UE4SS copy as its author ships it (only SWGRCouch added to mods.txt / mods.json)
GRU="$WORK/$NAME-gameroot-with-UE4SS"
GUW="$GRU/Griffin/Binaries/Win64"
mkdir -p "$GUW"
cp -p "$U/dwmapi.dll" "$GUW/"
cp -rp "$U/ue4ss" "$GUW/ue4ss"
[ -f "$GUW/ue4ss/LICENSE" ] || die "the UE4SS copy has no ue4ss/LICENSE (MIT: it must ship with the binaries)"
cp -rp "$GR/Griffin" "$GRU/"                                      # merges over the UE4SS copy
# mods.txt / mods.json (with-UE4SS only: GR ships neither, SWGRCouch starts through its enabled.txt): 1.0.3 = the
# author's files with "SWGRCouch : 1" first (SplitScreenMod forced off only if a copy ships it on), mods.json the same
# entries in the same order; UE4SS-settings.ini is only checked for the two keys the mod needs
python3 -I - "$GUW/ue4ss" "$U/ue4ss/UE4SS-settings.ini" <<'PY' || die "mods.txt / mods.json / UE4SS-settings.ini edit failed"
import json, os, re, sys
u = sys.argv[1]
mt = os.path.join(u, "Mods", "mods.txt")
raw = open(mt, "rb").read().decode("utf-8")
eol = "\r\n" if "\r\n" in raw else "\n"
lines = [l for l in raw.replace("\r\n", "\n").split("\n")]
if lines and lines[-1] == "":
    lines.pop()
def name(l): return l.split(":", 1)[0].strip() if ":" in l and not l.lstrip().startswith(";") else None
lines = [l for l in lines if name(l) != "SWGRCouch"]
for i, l in enumerate(lines):
    if name(l) == "SplitScreenMod":
        lines[i] = name(l) + " : 0"
lines = ["SWGRCouch : 1"] + lines
assert name(lines[-1]) == "Keybinds", "mods.txt: Keybinds must stay the last line"
open(mt, "wb").write((eol.join(lines) + eol).encode("utf-8"))
# mods.json: the same mods, switches and order as mods.txt (round 13: it had no SWGRCouch / ConsoleEnablerMod entry)
mj = os.path.join(u, "Mods", "mods.json")
old = {}
if os.path.exists(mj):
    for m in json.load(open(mj)):
        old[m.get("mod_name")] = m
d = []
for l in lines:
    n = name(l)
    if n is None:
        continue
    m = dict(old.get(n, {}))
    m["mod_name"], m["mod_enabled"] = n, l.split(":", 1)[1].strip() == "1"
    d.append(m)
open(mj, "w").write(json.dumps(d, indent=4))
txt = [(name(l), l.split(":", 1)[1].strip() == "1") for l in lines if name(l)]
js = [(m["mod_name"], m["mod_enabled"]) for m in json.load(open(mj))]
assert txt == js, "mods.json does not match mods.txt: %r vs %r" % (js, txt)
si = open(sys.argv[2], encoding="utf-8").read()
for k, v in (("bForceGUObjectArrayForIteration", "true"), ("UseCache", "0")):
    m = re.search(r"^%s\s*=\s*(\S+)" % k, si, re.M)
    assert m and m.group(1) == v, "UE4SS-settings.ini: %s is not %s in the UE4SS copy" % (k, v)
PY
# the install text (1.0.1 round 13: a README.txt in the game root is overwritten by the next mod's README.txt):
# SWGRCouch-INSTALL.txt in the game root (seen right after the extract) + the same text as the mod folder's README.txt,
# CRLF (Notepad). @DLLVERIFY@ = how to check the signature (signed DLL: the certificate is next to it), else a note.
readme() {   # readme SRC OUT
  python3 -I "$ROOT/tools/gameroot/fill-readme.py" "$1" "$2" "$VER" "$DLLSTATE" "$DLLSHA" "$CERTFP" \
    || die "install text $1: fill failed"
}
readme tools/gameroot/README.txt "$GR/SWGRCouch-INSTALL.txt"
readme tools/gameroot/README-with-UE4SS.txt "$GRU/SWGRCouch-INSTALL.txt"
cp -p "$GR/SWGRCouch-INSTALL.txt" "$GM/README.txt"
cp -p "$GRU/SWGRCouch-INSTALL.txt" "$GUW/ue4ss/Mods/SWGRCouch/README.txt"
! grep -l '@[A-Z]*@' "$GR/SWGRCouch-INSTALL.txt" "$GRU/SWGRCouch-INSTALL.txt" || die "gameroot install text: a placeholder is left"
# the no-UE4SS zip replaces nothing of the player's or of other mods: only SWGRCouch's own paths
for f in "$GW/ue4ss/Mods/mods.txt" "$GW/ue4ss/Mods/mods.json" "$GR/README.txt"; do
  [ ! -e "$f" ] || die "the gameroot zip would ship $f (it would replace the player's file)"
done
other=$(cd "$GR" && find . -type f ! -path './Griffin/Binaries/Win64/ue4ss/Mods/SWGRCouch/*' ! -name SWGRCouch-INSTALL.txt \
        ! -path './Griffin/Binaries/Win64/ue4ss/UE4SS_Signatures/*')
[ -z "$other" ] || die "the gameroot zip carries files outside the mod folder: $other"
sigs=$(cd "$GW/ue4ss/UE4SS_Signatures" && ls | sort | tr '\n' ' ')
[ "$sigs" = "$(echo $SIG_ADD | tr ' ' '\n' | sort | tr '\n' ' ')" ] || die "gameroot UE4SS_Signatures holds '$sigs', want only $SIG_ADD"
# 1.0.3: the with-UE4SS tree holds the author's UE4SS byte for byte (only mods.txt / mods.json carry SWGRCouch's line)
python3 -I - "$U" "$GUW" <<'PY' || die "the gameroot-with-UE4SS zip does not hold UE4SS exactly as shipped"
import hashlib, os, sys
src, dst = sys.argv[1], sys.argv[2]
def h(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
bad = []
for root, _, files in os.walk(src):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), src)
        if rel in (os.path.join("ue4ss", "Mods", "mods.txt"), os.path.join("ue4ss", "Mods", "mods.json")):
            continue
        d = os.path.join(dst, rel)
        if not os.path.isfile(d) or h(d) != h(os.path.join(root, f)):
            bad.append(rel)
if bad:
    print("changed / missing UE4SS files:", bad, file=sys.stderr); sys.exit(1)
PY
echo "gameroot-with-UE4SS: UE4SS identical to the source (mods.txt / mods.json + SWGRCouch only)"
[ ! -e "$GRU/README.txt" ] || die "the gameroot-with-UE4SS zip would put a README.txt into the game root"
# never a player's file: an extract over an existing install must keep them (and no program besides the DLLs)
for T in "$GR" "$GRU"; do
  bad=$(find "$T" -type f \( -iname 'config_user.lua' -o -iname 'settings.txt' -o -iname '*.log' -o -iname '*.dmp' \
        -o -iname '*.exe' -o -iname '*.bat' -o -iname '*.sh' -o -iname '*.ps1' -o -iname 'test.cmd' -o -iname 'test.out' \
        -o -iname 'imgui.ini' -o -iname 'swgr_inputfilter.cfg' -o -iname 'swgr_inputfilter.pads' \
        -o -iname 'swgr_inputfilter.status' -o -iname '*.bak*' -o -iname '*.swgrcouch-*' -o -iname 'UE4SS_ObjectDump.txt' \
        -o -iname '*.jmap' \) -print; \
        find "$T/Griffin/Binaries/Win64/ue4ss/Mods/SWGRCouch" -maxdepth 1 -type f ! -name enabled.txt ! -name LICENSE \
          ! -name README.md ! -name README.txt -print)
  [ -z "$bad" ] || die "the gameroot zip would ship (player / runtime files): $bad"
  [ "$(sha256sum "$T/Griffin/Binaries/Win64/ue4ss/Mods/SWGRCouch/native/swgr_inputfilter.dll" | cut -d' ' -f1)" = "$DLLSHA" ] \
    || die "gameroot: DLL is not the slot copy"
done
ndll=$(find "$GR" -type f \( -iname '*.dll' -o -iname '*.exe' \) | wc -l)
[ "$ndll" = 1 ] || die "the gameroot zip carries $ndll binaries, expected 1 (swgr_inputfilter.dll; UE4SS comes from its page)"
[ -z "$(find "$GR" -iname 'UE4SS-settings.ini' -o -iname 'UE4SS.dll' -o -iname dwmapi.dll)" ] \
  || die "the gameroot zip would carry UE4SS files"
ndll=$(find "$GRU" -type f \( -iname '*.dll' -o -iname '*.exe' \) | wc -l)
[ "$ndll" = 3 ] || die "the gameroot-with-UE4SS zip carries $ndll binaries, expected 3 (dwmapi.dll, UE4SS.dll, swgr_inputfilter.dll)"
# a zip with its files at the top level
zipflat() {
  python3 -I - "$1" "$2" <<'PY'
import os, sys, zipfile
out, src = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
}
for z in "$NAME-gameroot.zip" "$NAME-gameroot-with-UE4SS.zip"; do
  [ -e "$DIST/$z" ] && mv "$DIST/$z" "$DIST/$z.$(date +%Y%m%d-%H%M%S)"
done
zipflat "$DIST/$NAME-gameroot.zip" "$GR"
zipflat "$DIST/$NAME-gameroot-with-UE4SS.zip" "$GRU"
# the plain zip ships WITHOUT the compiled DLL (0.13.1: scanner-friendly; solo works, split screen needs the DLL)
rm "$P/$DLL"
rm -f "$CERT"                                                    # (its certificate goes with it)
cp -p docs/INPUTFILTER.md "$P/README-INPUTFILTER.md"
zipdir "$DIST/$NAME.zip" "$WORK/$NAME"
ALL=("$NAME.zip" "$NAME-no-UE4SS.zip" "$NAME-with-UE4SS.zip" "$DLLNAME.zip" "$NAME-nexus.zip" "$NAME-gameroot.zip"
     "$NAME-gameroot-with-UE4SS.zip")
# docs/media/ (and any animation) never ships, in any zip
for z in "${ALL[@]}"; do
  m=$(unzip -Z1 "$DIST/$z" | grep -iE '(^|/)docs/media/|\.(gif|mp4|webm)$|docs/(dev|steam-guide)/' || true)
  [ -z "$m" ] || die "$z ships repo-page media / dev docs: $m"
done
for z in "${ALL[@]}"; do
  printf '%s  %s files  %s bytes  sha256 %s\n' "dist/$z" "$(unzip -Z1 "$DIST/$z" | grep -vc '/$')" \
    "$(stat -c %s "$DIST/$z")" "$(sha256sum "$DIST/$z" | cut -c1-16)"
done
printf '%s  %s bytes  sha256 %s\n' dist/swgr_inputfilter.dll "$(stat -c %s "$DIST/swgr_inputfilter.dll")" \
  "$(sha256sum "$DIST/swgr_inputfilter.dll" | cut -d' ' -f1)"
echo "work dir (kept): $WORK"
