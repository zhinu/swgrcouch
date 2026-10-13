# The input filter DLL (read me if you play split screen)

This download ships **without** the compiled `swgr_inputfilter.dll` - the small native library (~30 KB, source
included under `SWGRCouch/native/inputfilter/`) that gives each player's car its own pad. Some download sites and
virus scanners flag any zip containing an unsigned DLL, so the DLL is distributed separately.

**Without the DLL:** the mod loads and solo play works normally, but in a split-screen race every pad steers
player 1's car. The installer prints a warning when the DLL is missing.

**To play split screen, do ONE of these:**

1. **Download it** - download `swgr_inputfilter.dll` (a bare file) from the same release page and put it
   into the game's `ue4ss/Mods/SWGRCouch/native/` folder (next to `inputfilter/`).
   If you have not installed the mod yet: drop it into this zip's `SWGRCouch/native/` first and `install.sh`
   copies it for you.
2. **Compile it yourself** - `SWGRCouch/native/inputfilter/build.sh` rebuilds the DLL from `inputfilter.c`
   with the system LLVM (`clang`, `lld-link`, `llvm-dlltool`); no Windows SDK needed.
3. **Use the with-UE4SS zip** (`SWGRCouch-<version>-with-UE4SS.zip`), which ships the DLL in place.

A few heuristic antivirus engines flag the DLL itself; that is a false positive. The build is reproducible: the
DLL rebuilds **byte-identical** from the C source in this zip (`lld-link /timestamp`), which anyone can verify
by comparing hashes after running `build.sh`.

Check it works: the first split race logs `native filter loaded: installed=1 reason=ok build=382493` in
`Griffin/Binaries/Win64/ue4ss/UE4SS.log`.
