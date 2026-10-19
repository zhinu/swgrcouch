# Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io), certificate by
[SignPath Foundation](https://signpath.org).

> Status: the SignPath Foundation application is in preparation. Until a release says "signed", the DLL is
> unsigned; it is still reproducible from source (see below).

## What is signed

Only one file: **`swgr_inputfilter.dll`**, SWGRCouch's native input filter (the small library that gives each
split-screen player's car its own pad). Nothing else in the release zips is signed by this project:

| file | signed? |
|---|---|
| `SWGRCouch/native/swgr_inputfilter.dll` | **yes**, with the SignPath Foundation certificate |
| `SWGRCouch/Scripts/*.lua`, `install.sh`, `ue4ss_signatures/*.lua`, config files | no (text files) |
| `ue4ss-build/` in the with-UE4SS zip (UE4SS Galactic Racer Edition: `dwmapi.dll`, `UE4SS.dll`) | no: an upstream project's binaries, shipped as published by their authors and never signed with this project's certificate |

How a signed DLL is made:

1. The source is `SWGRCouch/native/inputfilter/` in this repository (`inputfilter.c`, `version.rc`, `kernel32.def`,
   `build.sh`), MIT licensed.
2. The GitHub Actions workflow [`.github/workflows/build-inputfilter.yml`](.github/workflows/build-inputfilter.yml)
   builds it on a GitHub-hosted runner with the official LLVM release (pinned version and sha256), and uploads the
   unsigned DLL as a workflow artifact.
3. The workflow submits that artifact to SignPath. SignPath checks that it comes from this repository's workflow
   (origin verification) and that its metadata is right (product name `SWGRCouch`, the release's product version).
4. An approver (below) reviews and approves the signing request by hand. Only then is the DLL signed; the workflow
   attaches the signed DLL to the GitHub release.

Every DLL release gets its own signing request; nothing is signed automatically.

### Verify a download

- **Signature:** Windows Explorer > Properties > Digital Signatures shows *SignPath Foundation*; or
  `osslsigncode verify -in swgr_inputfilter.dll` on Linux.
- **Same code as the source:** the build is reproducible. `SWGRCouch/native/inputfilter/build.sh` with the same LLVM
  version gives a byte-identical *unsigned* DLL (fixed PE time stamp); its sha256 is printed in the workflow run's
  summary next to the signed file's hash. The signed DLL is that unsigned file plus an Authenticode signature (the signer
  also fills in the PE header's checksum and certificate-table fields).

## Team roles

SWGRCouch is maintained by one person.

- Committers and reviewers: jules ([@zhinu](https://github.com/zhinu))
- Approvers: jules ([@zhinu](https://github.com/zhinu))

Changes from anyone else (pull requests) are reviewed by a committer before they are merged. Every team member uses
multi-factor authentication for the source repository (GitHub) and for SignPath.

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

## Contact and reports

- The project: swgrcouch@ju.l3s.pw
- A signed file that seems to break this policy: report it to SignPath at support@signpath.io (see
  [SignPath Foundation's terms](https://signpath.org/terms)).
