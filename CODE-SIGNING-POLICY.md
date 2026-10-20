# Code signing policy

SWGRCouch's input filter DLL is signed by the author himself, locally, with a **self-signed certificate**
(`CN=Jules (SWGRCouch)`). This is the project's chosen and final approach to code signing.

Be clear about what that means:

- It is **not a CA-trusted signature**. No certificate authority vouches for the certificate, so Windows shows
  *unknown publisher* and marks the certificate as *not trusted*, and SmartScreen may still warn.
- What it **does** prove: the DLL you have is the file the author signed, unchanged since. Anyone can check that
  against the public certificate and its fingerprint below.
- The second, independent proof is the **reproducible build**: the DLL rebuilds byte-identical from the public C
  source, so anyone can check that the signed file contains exactly that code (see [Verify a download](#verify-a-download)).

| 1.0.1 `swgr_inputfilter.dll` | sha256 |
|---|---|
| signed by the author (shipped in the 1.0.1 zips and as the bare download) | `41458d0492a29ae1a2fbd3c67f50b8c268a061d364c3d001be163e2ca26d0928` |
| unsigned reproducible build (`build.sh`, LLVM 23.1.1) | `42e7b2a4cef5e6d8b5ad6c89ae525df98fc921b74941e70b8f872e8b41f7e8b8` |

Public certificate: [`docs/signing/swgrcouch-cert.pem`](https://git.jules.my/jules/swgrcouch/src/branch/main/docs/signing/swgrcouch-cert.pem)
(details in [`docs/signing/README.md`](https://git.jules.my/jules/swgrcouch/src/branch/main/docs/signing/README.md)),
SHA-256 fingerprint
`05:FA:00:C4:E0:53:2B:0C:86:62:6A:2E:6B:1D:A6:C4:4C:62:55:97:5D:A7:2E:18:99:76:24:1A:C0:A8:1A:A7`.

## What is signed

Only one file: **`swgr_inputfilter.dll`**, SWGRCouch's native input filter (the small library that gives each
split-screen player's car its own pad). Nothing else in the release zips is signed by this project:

| file | signed? |
|---|---|
| `SWGRCouch/native/swgr_inputfilter.dll` | **yes**: with the author's self-signed certificate (`docs/signing/`), from 1.0.1 on |
| `SWGRCouch/Scripts/*.lua`, `install.sh`, `ue4ss_signatures/*.lua`, config files | no (text files) |
| `ue4ss-build/` in the with-UE4SS zip (UE4SS Galactic Racer Edition: `dwmapi.dll`, `UE4SS.dll`) | no: an upstream project's binaries, shipped as published by their authors and never signed with this project's certificate |

## Who signs, and how

- **The author (jules) signs, by hand, on his own machine.** The private key never leaves it: it is not in this
  repository, not in any CI system and not shared with anyone. Nothing is signed automatically.
- How a signed DLL is made:
  1. The source is `SWGRCouch/native/inputfilter/` in this repository (`inputfilter.c`, `version.rc`,
     `kernel32.def`, `build.sh`), MIT licensed.
  2. `build.sh` builds it with the official LLVM release (pinned version); the build is reproducible (fixed PE time
     stamp). The GitHub Actions workflow
     [`.github/workflows/build-inputfilter.yml`](.github/workflows/build-inputfilter.yml) builds the same commit on a
     GitHub-hosted runner and prints the unsigned DLL's sha256 in the run's summary, as a public cross-check.
  3. The author signs that unsigned build with `osslsigncode` (Authenticode, SHA-256, with an RFC 3161 time stamp
     from DigiCert's public time-stamp service) and publishes both hashes.
- Every release that changes the DLL gets a new build, a new signature and both new hashes in this file,
  `docs/signing/README.md` and `docs/INPUTFILTER.md`.

## Verify a download

- **Signature, Windows:** Explorer > the DLL's Properties > Digital Signatures shows *Jules (SWGRCouch)*. Windows
  marks the certificate as not trusted: expected, it is self-signed.
- **Signature, Linux:** `osslsigncode verify -in swgr_inputfilter.dll -CAfile swgrcouch-cert.pem` ends with
  `Signature verification: ok` and `Succeeded`. The game-folder zips carry the certificate next to the DLL
  (`native\swgrcouch-cert.pem`); check its fingerprint with
  `openssl x509 -in swgrcouch-cert.pem -noout -fingerprint -sha256` against the one above.
- **File hash:** `sha256sum swgr_inputfilter.dll` (Windows: `certutil -hashfile swgr_inputfilter.dll SHA256`) must
  give the signed hash in the table above.
- **Same code as the source:** `SWGRCouch/native/inputfilter/build.sh` with the same LLVM version gives a
  byte-identical *unsigned* DLL (the unsigned hash above). The signed DLL is that file plus an Authenticode
  signature: `osslsigncode remove-signature -in swgr_inputfilter.dll -out unsigned.dll` gives a file of the same
  size that differs from the reproducible build only in the PE header checksum (3 bytes), which the signer fills in.

## Privacy policy

This program will not transfer any information to other networked systems unless specifically requested by the user
or the person installing or operating it.

In detail, for the signed file: `swgr_inputfilter.dll` makes no network connections at all. It imports 13 functions
from `kernel32.dll` only (file I/O, `VirtualProtect`/`VirtualQuery`, `GetModuleHandleExW`/`GetModuleFileNameW`,
`CreateThread`/`Sleep`, `GetTickCount64`, `DisableThreadLibraryCalls`); no network, registry or process APIs. It
reads and writes three small text files next to itself (`swgr_inputfilter.cfg`, `.status`, `.pads`) to talk to the
mod's Lua scripts, and it only changes the game's input handling inside the running game process (which pad
steers which car). It collects no data.

SWGRCouch runs inside STAR WARS Galactic Racer through UE4SS; the game, Steam and UE4SS have their own privacy
policies.

## Report a problem

Found a bug, a hash or signature that does not match, or a file that seems to break this policy? **DM me** on the
site where you got the mod (Nexus Mods: a private message), or write to swgrcouch@ju.l3s.pw. See
[Found a bug?](README.md#found-a-bug) in the README for what to send.
