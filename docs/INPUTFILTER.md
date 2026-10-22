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
2. **Compile it yourself** - `SWGRCouch/native/inputfilter/build.sh` rebuilds the DLL from `inputfilter.c` and
   `version.rc` with the system LLVM (`clang`, `lld-link`, `llvm-rc`, `llvm-dlltool`); no Windows SDK needed.
3. **Use a zip that ships the DLL in place**: the game-folder zip (`SWGRCouch-<version>-gameroot.zip`), or the
   `-no-UE4SS` / `-with-UE4SS` zips.

A few heuristic antivirus engines flag the DLL itself; that is a false positive. The build is reproducible: the
DLL rebuilds **byte-identical** from the C source in this zip (fixed PE time stamp, `lld-link /timestamp` in
`build.sh`), which anyone can verify by comparing hashes after running `build.sh`.

The DLL version 1.0.2.0 (with its VERSIONINFO: product name SWGRCouch) built with LLVM 23.1.1 (Arch's clang 23.1.1
and the official LLVM 23.1.1 Linux release give the same file) has
`sha256 4363c77db01d49160c23e969653861209bb611439c1f98a6931cf68e39a1e300`. Another LLVM version may produce a
different (equally valid) file.

**Signed copy (1.0.2).** The DLL in the 1.0.2 zips and the bare `swgr_inputfilter.dll` download is that file plus an
Authenticode signature by the author: `sha256 ed491789b9f967b97d79553a610520f5b861a111b544c3e0d581e1cc8a0aef00`.
It is a **local signature by the author with a self-signed certificate** (`CN=Jules (SWGRCouch)`), not a CA-trusted
one: Windows still shows *unknown publisher*. The public certificate is `docs/signing/swgrcouch-cert.pem` in the
repository (also in the `swgr_inputfilter-<version>.zip`), SHA-256 fingerprint
`05:FA:00:C4:E0:53:2B:0C:86:62:6A:2E:6B:1D:A6:C4:4C:62:55:97:5D:A7:2E:18:99:76:24:1A:C0:A8:1A:A7`; check a download
with `osslsigncode verify -in swgr_inputfilter.dll -CAfile swgrcouch-cert.pem`. Removing the signature
(`osslsigncode remove-signature`) gives the reproducible build above except for the PE header checksum. This
self-signature is the project's chosen approach to signing (who signs, how, and the privacy statement:
`CODE-SIGNING-POLICY.md` at the top of the mod's repository and release).

Check it works: the first split race logs `native filter loaded: installed=1 reason=ok build=382493` in
`Griffin/Binaries/Win64/ue4ss/UE4SS.log`.
