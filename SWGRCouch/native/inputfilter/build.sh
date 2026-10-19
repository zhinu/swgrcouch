#!/bin/sh
# Builds ../swgr_inputfilter.dll from inputfilter.c + version.rc with the system LLVM (clang, lld-link, llvm-rc,
# llvm-dlltool). No Windows SDK and no CRT: kernel32.lib is generated from kernel32.def. Static build only; nothing
# is run.
#
# Reproducible: the PE time stamp is fixed (/timestamp, SWGR_IF_TIMESTAMP below, one value per DLL version), so the
# same source + the same LLVM version give a byte-identical DLL on any machine (checked: system clang 23.1.1 on Arch
# and the official LLVM 23.1.1 Linux release that .github/workflows/build-inputfilter.yml uses). Expected hash of
# the current source: see docs/INPUTFILTER.md. Override the time stamp only to re-create an old DLL, e.g.
#     SWGR_IF_TIMESTAMP=1792167903 sh build.sh     (an older source tree, without version.rc)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build"
DLL="$HERE/../swgr_inputfilter.dll"
# 2026-10-19 00:00:00 UTC: the 1.0.0.0 DLL (version.rc). Change it together with the version in version.rc.
SWGR_IF_TIMESTAMP=${SWGR_IF_TIMESTAMP:-1792368000}
mkdir -p "$OUT"
llvm-dlltool -m i386:x86-64 -d "$HERE/kernel32.def" -l "$OUT/kernel32.lib"
llvm-rc -no-preprocess /nologo /fo "$OUT/version.res" "$HERE/version.rc"
clang --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector \
      -mno-stack-arg-probe -fno-asynchronous-unwind-tables -Wall -Wextra -Wno-unused-parameter \
      -c "$HERE/inputfilter.c" -o "$OUT/inputfilter.obj"
lld-link /nologo /dll /entry:DllMain /nodefaultlib /subsystem:windows /machine:x64 /opt:ref /implib:"$OUT/swgr_inputfilter.lib" \
         /timestamp:"$SWGR_IF_TIMESTAMP" "$OUT/inputfilter.obj" "$OUT/version.res" "$OUT/kernel32.lib" /out:"$DLL"
echo "built $DLL"
if command -v sha256sum > /dev/null; then sha256sum "$DLL"; fi
