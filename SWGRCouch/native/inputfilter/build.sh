#!/bin/sh
# Builds ../swgr_inputfilter.dll from inputfilter.c with the system LLVM (clang, lld-link, llvm-dlltool).
# No Windows SDK and no CRT: kernel32.lib is generated from kernel32.def. Static build only; nothing is run.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build"
mkdir -p "$OUT"
llvm-dlltool -m i386:x86-64 -d "$HERE/kernel32.def" -l "$OUT/kernel32.lib"
clang --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector \
      -mno-stack-arg-probe -fno-asynchronous-unwind-tables -Wall -Wextra -Wno-unused-parameter \
      -c "$HERE/inputfilter.c" -o "$OUT/inputfilter.obj"
lld-link /nologo /dll /entry:DllMain /nodefaultlib /subsystem:windows /machine:x64 /opt:ref /implib:"$OUT/swgr_inputfilter.lib" \
         "$OUT/inputfilter.obj" "$OUT/kernel32.lib" /out:"$HERE/../swgr_inputfilter.dll"
echo "built $HERE/../swgr_inputfilter.dll"
