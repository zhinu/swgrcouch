# Developer notes (0.12.0)

These are the working documents behind SWGRCouch 0.12.0 (UI v2), kept here so the code can be reviewed with its
reasoning. They are internal notes, not player documentation, and they are not part of the release zip.

| File | What it is |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Module map, hard rules (threading, UObject safety, TArray rules; 0.12.0: the launch hold and the life of raw hooks), revision history with every live finding. Revision 0.12.0 is the binding summary of this release: `theme.lua`, `cards2.lua`, `backprompt.lua`, the v2 lobby / OPTIONS / RACE SETUP pages, cmap's v2 views, the player colours, the `UiStyle = "classic"` switch and the opponents' tier; §6 Session U has its live checks |
| [`review-0.12.md`](review-0.12.md) | The 0.12.0 review notes (until 0.11.0-dev they were in the top-level README, which is the public one now): how to install a review build, the review checklist with the log line of each step, the live results of 2026-10-10, the checks before publishing, and what changed after the review snapshot |
| [`racers-step-spec.md`](racers-step-spec.md) | The RACERS step design (pilot -> vehicle -> perks -> ready): UX, visual spec, data, modules, launch-time writes, the live test plan, and the review corrections RC-1..RC-15 (titled 0.11.0, shipped first as 0.10.0). In 0.12.0 its state machines, input model and view-model contract still hold; its visual spec is the classic look (`cards.lua`, `UiStyle = "classic"`), the v2 cards (`cards2.lua`) follow §9 of the UI v2 design spec |
| [`live-run-0.10-facts.md`](live-run-0.10-facts.md) | Evidence from the live test sessions of 2026-10-10: log lines per VERIFY id, the bugs found and fixed |
| [`settings-crash-2026-10-09.md`](settings-crash-2026-10-09.md) | Analysis of one crash dump (a test probe on a stale widget, confirmed), and the probe rule that came out of it |
| [`restart-race.md`](restart-race.md) | RESTART RACE: how the game's pause menu, its RETRY row, the RetryRace dialog and the restart calls work in this build, the design, and the live result (§8: what the design did not foresee) |
| [`hud-narrow-views.md`](hud-narrow-views.md) | The opt-in HUD layout for half-width views, its design, and the measurement that found it brings nothing (last section) |

Not in this repo: the UI v2 design spec (`ui-redesign-final.md`, kept with the project notes). It is the binding spec
of the 0.12.0 FREE MODE page, OPTIONS, RACE SETUP and the RACERS cards: tokens (§2), the `theme.lua` API and its
components (§3), the page layouts (§4-§9), the config keys (§12.3) and the live checks V-FIN-01..16 (§14). The code
cites it as `notes/design/ui-v2/ui-redesign-final.md` with its § numbers; where the spec and the code differ, the code
wins, and ARCHITECTURE.md Revision 0.12.0 records the result. Its mockups are not published either (they are drawn
with decoded game art and fonts). The other `notes/...` research files and `state/runs/...` run folders that
ARCHITECTURE.md and the code cite also stay with the project notes.

`tools/gen-perkdata.py` regenerates `Scripts/perkdata.lua`. It needs the decoded game data (not included: it is
extracted from the game's own files); see the header of the script. `tools/package.sh VERSION` builds the release zips
from the git-tracked files plus the images README.md references: it checks that `C.VERSION` matches, that every Lua
file compiles (`luac5.4 -p`, when it is installed), that no private path or account data is in the shipped text files
and that no untracked file sits in the shipped folders, and it also ships docs/REFERENCE.md as `SWGRCouch/README.md`.
