# RACE SETUP step 5 "RACERS": PILOT -> VEHICLE -> PERKS -> READY (final spec v2, binding for 0.11.0)

*2026-10-09, judge pass. Static only: nothing was launched and no mod file was edited. This document replaces the three
proposals in `notes/design/` (`vehicle-step-proposal-couch-fast.md` = **CF**, `-full-garage.md` = **FG**,
`-game-native.md` = **GN**) and is the implementation contract. Where it differs from a proposal, this document wins.*

**User request (2026-10-09, verbatim).** "improve the ui (kart are horrible p1 and p2 are not similar)"; "Kart can only
choose two when it shouldn't be the way to choose kart. A chracter should be chosen, a kart then. and then we should be
able to map out all the benefits and perks added to the kart (all unlocked just for this mod). It should look nice the
UI. Take screenshot".

**Sources.** CM = `notes/research/vehicle-step-code-map.md`, PS = `pilot-select.md`, PL = `perks-loadout.md`,
RS = `race-setup.md`, VP = `vehicle-preview.md`, UIT = `ui-toolkit.md`, MO = `menu-owner.md`, ARCH =
`notes/ARCHITECTURE.md` (binding revisions + §0 hard rules + §4.0 conventions). Code anchors are **current** file lines
(2026-10-09 ~21:00: `setup.lua` 1994 lines, `launch.lua` 890, `vpreview.lua` 703, `ui.lua` 422); the research notes
quote an older 1783-line `setup.lua` snapshot, so always locate code **by function name**.

Tags: **[V]** verified in code, decoded data or a live log; **[L]** likely; **[S]** needs the runtime check named
(VERIFY ids `V-RC-nn`, §8.1).

---------------------------------------------------------------------------------------------------------------------

## 0. Verdict

### 0.1 Scores (1-10)

| Criterion | CF couch-fast | FG full-garage | GN game-native |
|---|---|---|---|
| (a) looks nice and consistent, P1 = guests | 8: big hero art per stage and a clear board; identical by construction; but full-saturation title bars read "web app", 1060-su cards leave a third of the row empty at 1-2 players, the CUSTOMIZE rows are plain lists | 6.5: identical by construction and the neutral game panel with a player strip is right, but PERKS is a dense spreadsheet (48-su rows at 4P = 16 px at 1080p): little of the game's art shows | 9: decoded game panel colour, fonts and letter spacing, tile textures, HUD-like ability diamond, the game's own `WBP_Character_Ability` detail; three width classes fill the 3500-su row at every player count |
| (b) fulfils the request (pilot, then vehicle, then ALL perks, all unlocked) | 8: every slot editable in CUSTOMIZE, but the map is split between a read-only board and a tabbed editor; tiers fixed at top; 4 parts | 9.5: every field of `FVehicleBuildState` incl. tiers, slot count, systems, style + 4 traits, presets, tier ladders | 8: one board with every slot, all unlocked; but traits only through the style, no tiers, no systems |
| (c) couch usability, pad only, 1-4 players | 9: A,A,A to READY, few rows, good defaults and follow rules; "A = next group" in CUSTOMIZE is non-standard; guests' B on press fires "back" before a hold-to-leave | 6.5: accordion sheet + category grids = much d-pad travel for four people; good safety details (double back to MODE) | 8: short rows per stage, B on release (no clash with hold-B leave), one-tick-held attribution guard; 19-stop board walk, A on an UPGRADE row jumps to READY (surprising) |
| (d) technical feasibility and risk under the hard rules | 8: matches the research; few unverified game widgets; careful glyph rule; small slips (§0.3) | 7: working generator (sample passes `luac5.4 -p`), DarkPanel as an overlay layer (no named slot); but `GridPanel` cell moves [L], ~600 widgets/card, writes `ps.RacerStyle` by default | 7.5: most dependent on unverified game widgets (DarkPanel padding, SectionSubLabel, AffixRarity, `MI_HUD_Abilities_BG`, `WBP_Input_Action`), each with a fallback; bays keyed by pnum |
| (e) performance with 4 players | 8: stage-limited spin, 1 capture/tick, prebuild, poster still, lazy build, preload; RT re-created per player count | 6.5: ~2400 widgets for 4 cards + 40-tile pickers; previews budgeted | 8.5: lightest (~160 widgets/card), stage panels built lazily, 1 render/tick, budgeted captures |
| **Total (of 50)** | **41** | **36** | **41** |

**Base:** GN (the user's first complaint is the look; GN is the only proposal that looks first-party at every player
count). **Grafts:** CF's flow, defaults, validated kit data, ctrlId keying, prebuild/still captures and glyph rule;
FG's completeness (individual traits, part tiers, read-back + PRERACE verification), its generator, the DarkPanel
overlay trick, the P1 double-back confirm and the "navigation sounds for guests only" rule.

### 0.2 What changed against each proposal (decisions)

| Topic | Decision | From |
|---|---|---|
| Card | one card per player, ONE widget tree, ONE renderer, ONE state machine; nothing in a card is focusable | all |
| Look | game panel `#1E363E @0.9`, Font_Display + Font_Body (letter-spaced), player colour only on tag pill, divider, current tab, cursor, READY stamp | GN (+ FG "no tinted panel") |
| Card sizes | 1720 / 1720 / 1140 / 845 su wide, 1320 su high; every element placed on a **FuseCanvasPanel from a per-width-class layout table** (no GridPanel moves, no rebuild on a class change) | GN sizes, canvas pattern from `cmap.lua` |
| Stage names | PILOT · VEHICLE · PERKS · READY; step crumb `STEP 5/5  RACERS` | GN / FG |
| PILOT | full body on the style backdrop + style block + roster strip; one value row | GN + CF |
| VEHICLE | live 3D render + DRIVEN BY + SIGNATURE; rows MODEL and LIVERY | GN / FG |
| PERKS | one board, every slot a cursor stop (reading order): KIT, 4 abilities + crash, 6 parts, 6 upgrades, STYLE, 3 traits; L/R quick-change, A = picker (KIT: A = READY; upgrade: A = next row) | GN board + FG traits/tiers |
| Systems flags | NOT on the board: `PerkRamjet` / `PerkCritMalfunctions` config (default "keep") | judge (keeps the board short) |
| Tiers | picker lists one entry per family at the top tier; L/R on an equipped laddered part changes its tier I-IV | FG |
| Kits | pilot style kit (default), MAX POWER, TIER 1-6, every other style kit, pod kits; data = CF's validated table | CF + GN |
| P1 input | invisible 5-button sink in the footer, explicit rules in 4 directions + geometric plus-shape placement | all (placement FG/GN) |
| P1 back | strip L/Up route; at PILOT a second back within 3 s goes to MODE; adaptive hint | FG |
| Guests' B | fires on **release** if held < 600 ms; hold 1 s = leave (join.lua) | GN |
| Attribution guard | P1's accept held one FAST tick, dropped if any guest A is down or changed within 150 ms | GN + FG ordering |
| Keys | everything keyed by **ControllerId** (cards, memory, bays, persistence); pnum only for display/launch mapping | CF |
| Previews | spin only on VEHICLE, prebuild on PILOT, still on READY/PERKS; 1 capture per FAST tick; 1 spawn per 300 ms; one RT size 960x540; spacing 20000 | CF + FG + judge |
| Detail panel | `WBP_Character_Ability` fed through its vars + `Refresh()` (never `SetAbility`/`SetTrait`: blocking soft loads) | GN |
| Launch | zero base build + in-memory affix-slot patch, pilots before the AI loop, field-by-field writes with read-back, traits by `Server_ApplyPassive` at PRERACE, `ps.RacerStyle` untouched | all (FG's RacerStyle write rejected) |
| Persistence | one new settings key `LastRaceRacers` (ctrlId-keyed pilot + preset + loadout); `LastRaceVehicles` unchanged | judge |
| Join hints | status line (no join tiles: the row is full at 2 players) | judge |

### 0.3 Claims checked against code and research (corrections)

1. `join.dormantList()` **already exists** (join.lua:502, CF said "new"). No join.lua change is needed.
2. `keyq.lua` exists and `lobby.init` binds arrows/Enter/Space/Escape/Backspace through it (lobby.lua:1060-1081): the
   keyboard reaches `setup.onKey` on the game thread today [V]. CF's "if task #17 landed" is moot.
3. `ui.registerButton(w, id, fn)` has **no options** (ui.lua:130). The sink needs `opts.noClaim` (§5.11).
4. `ui.pollClicks` runs `lobby.pollNav -> setup.pollNav` **before** its click loop (ui.lua:368-411) [V]: guest edges
   of a tick are known when that tick's sink click is seen (FG's ordering claim holds).
5. Headless gamescope: `tools/gr-session.sh` notes (2026-10-09) that the hotfix build **does not boot** headless; tests
   use `SWGR_SMALL=1` at 1280x720 (§10). `-nosound` crashes every race at PRERACE: never use it.
6. vpad syntax is `dpad left|right|up|down [ms]` and `press A [ms]` (tools/vpad.py); CF's `press DPAD_UP` is wrong and
   `gr-session.sh` has no `pad` subcommand (it is an internal function).
7. Bay isolation: the fill light sits at `0.85·d` toward the previous bay (camera yaw 210°) with radius `3·d`
   (vpreview.lua:399-421). For a pod (`d` ≈ 4092 uu) at spacing 15000 the light reaches the neighbour model
   (≈ 11925 uu < 12276). CF and GN said 15000 isolates; FG also cut the radius to 1.3·d, which changes the look (with
   UE's windowed falloff the fill at the model drops to about a third and the far side gets none). Keep the radius,
   use spacing **20000** (≈ 16800 uu > 12276; §5.8).
8. `vpreview` creates the RT once per bay with `SetupPreviewW/H`; per-player-count RT sizes (CF, GN) mean re-creating
   targets and re-pointing MIDs on every count change. One size (960x540) instead.
9. CF: guests' B on the press edge also fires "back" at the start of every hold-to-leave. B fires on release (GN).
10. FG writes `ps.RacerStyle` by default; other code may then apply that style's traits a second time [S]. Off.
11. GN `mock-1p.png`: the detail text under RAMJET POWER IV is Overheat Loop III's ("Redlining adds +5%..."); mock data
    slip only. Ramjet Power IV = "Ramjet is 50% more powerful." (PL §2.3.1 #39).
12. `WBP_Character_Ability.SetAbility/SetTrait` call `LoadAsset_Blocking` on the soft `Icon` inside the BP
    (decoded @898, @1192); `Refresh()` only reads the vars `Icon`, `ItemName`, `ItemDescription` [V]. Feed the vars.
13. `WBP_DarkPanel` puts `NS_Content` in an overlay slot with a 64-su padding and has its own outer backer
    `#1E363E @0.9` [V decoded]. Used as the bottom layer of our overlay, no named slot is needed (FG).
14. `vehicles.presets(arch)` entries already carry `base`, `owner`, `name`, `badge` input (vehicles.lua:203-224):
    model/livery grouping is a small `vehicles.lua` addition.

---------------------------------------------------------------------------------------------------------------------

## 1. The design in short

1. Step 5 becomes **RACERS**: one card per local player (P1 + joined guests, view order), side by side in a
   3500 x 1320-su row. Every card is the same widget tree, rendered from a view model by one function. P1 and a guest
   differ only in hint texts and the READY rows (START RACE / SAVE AND RETURN vs READY · WAITING FOR P1).
2. Every player moves through **PILOT -> VEHICLE -> PERKS -> READY** on their own; the stage strip is row 0 of every
   stage. A = next / pick, B = back (guests), L/R = change, Up/Down = row. LB/RB, X, Y and Start are never used.
3. **PILOT:** the game's 1480x1800 full-body render over the racer-style art, the style block (icon, name, description,
   3 traits, signature vehicle), the name and a roster strip of squircle head shots; pilots held by others are
   dimmed, tagged and skipped.
4. **VEHICLE:** the live 3D render of the pick (spins only on this stage), manufacturer badge, DRIVEN BY pilot tile,
   SIGNATURE chip; rows MODEL and LIVERY. The pilot's signature livery is preselected.
5. **PERKS:** the whole kart on one board: LOADOUT kit, the 4 d-pad abilities laid out like the race HUD with the crash
   ability in the centre, 6 part tiles with rarity pips, 6 upgrade bars (0-10) with POWER / ENERGY, the racer style and
   3 traits, and a detail panel (the game's own ability card + large art). L/R quick-changes the slot under the cursor;
   A opens a categorised picker. Everything is unlocked; no save or unlock tag is touched (PL §3).
6. **READY:** pilot + still render + READY stamp in the player colour + the loadout as an icon strip. P1 starts.
7. **Quick path:** A, A, A from any fresh card = READY with the pilot's signature vehicle and the pilot's style kit
   (4 abilities + crash, 4 top-tier parts, 3 traits, the game's PvP stat spread). P1's 4th A on START RACE races.
8. **Input:** guests are polled on their own PlayerController; P1's CommonUI focus sits on an invisible sink whose four
   neighbours turn d-pad moves into the same events. All sources call one `racers.event(who, ev)`.
9. **Launch:** pilots for every human (AI never keeps a human's pilot), a zero base build with the affix-slot count
   raised in memory for the call, each human's loadout written field by field and read back, traits applied as
   passives at PRERACE and verified.
10. **Performance:** lazy cards and stage panels, diffed rendering (max 2 cards/tick), texture queue (3/tick), previews
    capped at 1 capture and 1 spawn per budget window. `SetupPlayerFlow = "classic"` restores the 0.10.0 columns.

---------------------------------------------------------------------------------------------------------------------

## 2. UX flow per player

### 2.1 Stages and rows

| Stage | Rows (row 0 = stage strip everywhere) | A | B (guest) |
|---|---|---|---|
| PILOT | 1 PILOT (the roster) | -> VEHICLE | hint toast `HOLD B TO LEAVE` |
| VEHICLE | 1 MODEL · 2 LIVERY | -> PERKS | -> PILOT |
| PERKS | 1 KIT · 2 ABILITY UP · 3 ABILITY LEFT · 4 CRASH · 5 ABILITY RIGHT · 6 ABILITY DOWN · 7-12 PART 1-6 · 13-18 UPGRADE 1-6 · 19 STYLE · 20-22 TRAIT 1-3 | KIT: -> READY; UPGRADE: next row; others: open the picker | -> VEHICLE |
| PERKS picker | 0 CATEGORY · 1..n items | equip + close | close (no change) |
| READY | P1: 1 START RACE · 2 SAVE AND RETURN; guest: 1 READY · WAITING FOR P1 | P1: start / save; guest: nothing | -> PERKS (un-ready) |

Ability slots follow the race's d-pad (PL §1.5): slot 1 = Up, 2 = Left, 3 = Down, 4 = Right
(`IA_Veh_TriggerAbilitySlot1..4`). The board's reading order visits them as Up, Left, CRASH (centre), Right, Down.
With `PerkTraitSlots` = n the trait rows are 20..19+n. `PilotStage = false` / `PerkStage = false` remove a stage
from the strip (its defaults are used).

### 2.2 Events (one table for every player)

`ev` = `up | down | left | right | accept | back`; `rep` = true for an auto-repeat of a held direction.

| Where | up | down | left / right | accept | back |
|---|---|---|---|---|---|
| strip (row 0) | - | row 1 | previous / next stage (fresh press only; at PILOT, left = back rule below) | row 1 | as left |
| PILOT row 1 | row 0 | - | previous / next free pilot (repeat ok) | VEHICLE | guests: toast; P1: back rule |
| VEHICLE rows | row - 1 (1 -> 0) | row + 1 (clamp) | MODEL: model ±1; LIVERY: livery ±1 (repeat ok) | PERKS (row 1) | PILOT |
| PERKS rows | row - 1 (1 -> 0) | row + 1 (last -> 1, wraps) | quick-change of the slot (§2.5) | §2.1 | VEHICLE |
| picker | item - 1; on row 0 a **fresh** up closes (cancel) | item + 1 (row 0 -> 1) | category ±1 (wraps; cursor on the equipped item or item 1) | row 0: item 1; item: equip + close | close |
| READY | row - 1 (1 -> 0) | row + 1 (clamp) | - | P1 row 1 `setup.finish(true)`, row 2 `setup.finish(false)`; guest: accept sound only | PERKS |

**Back rule at PILOT for P1** (strip left, Backspace, or a B seen by `pollP1Back`): the first back shows the toast
`BACK AGAIN: MODE STEP` for `CardP1BackConfirmMs` (3000); a second back inside the window calls `setup.back()` (MODE;
every card keeps its state, §2.7). Guests at PILOT: toast `HOLD B TO LEAVE` (leaving = B held 1 s, join.lua).

Repeat: horizontal and vertical after `LobbyNavRepeatDelayMs` (400) then every `LobbyNavRepeatMs` (140). P1's repeats
come from CommonUI's own navigation repeat (each repeat moves the focus again and is one event). Stage changes on the
strip never repeat.

Cursor memory: entering a stage forward with A puts the cursor on row 1 (PERKS: KIT, so A, A, A always reaches
READY); entering it through the strip or with back restores that stage's last row. A picker opens on the equipped
item's category and row.

### 2.3 P1-only routes

- **Pad:** the sink (§5.7.3). P1's B usually opens the game's "Exit Game?" prompt (CM §3.1); the strip, the toast rule
  and the footer BACK button are the guaranteed back routes. `pollP1Back` (setup.lua:1918) stays as an extra source
  (P1's PC sees pad keys after a race, CM §3.1).
- **Keyboard** (keyq -> `lobby.onKey` -> `setup.onKey` -> `racers.onKey`, game thread): arrows = directions, Enter/Space
  = accept, Backspace = back, Escape = the lobby back guard only (unchanged).
- **Mouse:** the footer buttons `< BACK` (MODE), `SAVE AND RETURN`, `START RACE` keep working (`setup.finish`). Cards
  are `HitTestInvisible`.
- **Hints** show `▲ STAGES` (the Dpad_Top glyph) instead of `B BACK` until `pollP1Back` has seen one B in this
  session, then the guests' B hints (FG).

### 2.4 Defaults, quick path, follow rules

At step entry and when a player joins, per ControllerId and class (first rule that applies):

| Pick | Default |
|---|---|
| Pilot | session memory (`mem.pilot[arch]`) if allowed and free -> `LastRaceRacers[ctrlId]` if allowed and free -> P1: SHADE (`PilotP1Default = "favourite"` uses `PvpFlowComponent.DefaultPilot` when valid, V-PIL-08) -> guest: first free class specialist (PS §6.2: Car Ary, Soren, Nik, Kestar; Bike Katja, Sen, Biddy, Malis; Skimmer Griff, Goli, Fola, Lyren; Plane the 6 pod pilots in list order) -> first free pilot of the class list |
| Vehicle | `mem.preset[arch]` -> persisted preset (same class) -> the pilot's signature preset `sig[arch]` -> the first base model no other player uses (`V.defaultPresetIndex(arch, pnum)`) |
| Loadout | `mem.lo` (validated for the class) -> persisted loadout (validated) -> the pilot's style kit (§4.4) |
| Stage | PILOT; going back to MODE and returning in the **same class** keeps every card's stage and READY |

**Follow rules** (CF/PS §6.4). On a pilot change:
- the vehicle becomes the new pilot's `sig[arch]` (when it has one) while `follow.vehicle` is true (the player has not
  changed MODEL/LIVERY in this setup) or the current preset is the old pilot's signature;
- the loadout becomes the new pilot's style kit while `follow.perks` is true (kit still `"pilot"`, nothing edited);
  otherwise toast `LOADOUT KEPT`.

**Quick path:** PILOT (A) -> VEHICLE (A) -> PERKS, cursor on KIT (A) -> READY: 3 presses. Log
`racers: P2 READY after 3 presses (pilot DA_Racer_Protege, PRE_Car_Orca_Protege, kit pilot)` (V-RC-14).

### 2.5 PERKS: quick-change (L/R) and pickers (A)

| Slot | L/R | A | Picker categories |
|---|---|---|---|
| KIT | previous / next kit (§4.4 order; applies at once; `CUSTOM` is shown after an edit and skipped when cycling) | READY | - |
| ABILITY 1-4 | previous / next entry of `[EMPTY, the family's variants in tree order]` (wraps) | picker | the 8 families (SHIELD, SURGE, VENT, AUTOPILOT, ION BOLT, CONCUSSION MINE, SHOCKWAVE, STATUS SCRUBBER); each list starts with EMPTY |
| CRASH | NONE, ION BLAST, COOLING BLAST, CHARGING BLAST, SHIELDING BLAST (wraps) | picker | one category |
| PART 1-6 | laddered part: tier -1 / +1 (I-IV, clamp); single part or empty: nothing (hint hides L/R) | picker | the 10 positive categories + FLAWS (`PerkFlaws`) + POD TRAITS (pods only), §4.3 |
| UPGRADE 1-6 | level -1 / +1 (0-10, clamp, repeat) | next row | - |
| STYLE | previous / next style (speeder classes: 15 speeder styles; pods: 6 pod styles first, then the speeder styles); sets the 3 trait slots to that style's traits (toast `TRAITS FROM <STYLE>`) | picker | one category |
| TRAIT 1-3 | previous / next rule trait not used in another slot, EMPTY included (wraps) | picker | the 10 trait groups (§4.3) |

Any change except a KIT change sets `lo.kit = "custom"` (label `LOADOUT: CUSTOM · FROM <KIT>`) and
`follow.perks = false`. A family already in another ability slot is **moved** by the picker (the other slot gets the
old content of this one; toast `SWAPPED WITH SLOT <n>`); L/R never enters a family used elsewhere
(`PerkUniqueFamily`). Parts: one per family; traits: no duplicates. A laddered part equipped from the picker comes at
its top tier.

The picker replaces the board between the KIT row and the detail panel; the detail panel follows the item under the
cursor. Each item row: icon (tile / disc / glyph), name, rarity pips (parts) or level pips (abilities), a tick on the
equipped item. Lists longer than the visible rows page with the cursor (`n / N` counter on the category row).

### 2.6 READY, START, SAVE

- READY = being on the READY stage. Leaving it (B, strip left, Up from row 1 to the strip then left) un-readies.
- START (P1's READY row 1 or the footer START RACE) calls `setup.finish(true)` (setup.lua:1725). Gate (kept from
  0.10.0): every joined guest READY -> start; otherwise status `P2, P3 NOT READY: START AGAIN TO RACE ANYWAY` and a
  second START within 5 s of real time starts with their current picks (always complete).
- All READY: status `ALL READY · P1: A TO START`; P1's START row pulses (render opacity 0.65 <-> 1.0, 1 s,
  `CardStartPulse`). No automatic start.
- SAVE AND RETURN (`setup.finish(false)`) stores the choice and closes the setup; the lobby's START RACE replays it.
- Dormant pads (connected, not joined): `join.dormantList()` -> status line `PAD 3: PRESS A TO JOIN`.
- (review) START checks `join.dormantText()` **before** `setup.finish` closes the page. Today `launch.start` refuses
  the first START with a dormant pad *after* the setup is closed, which would drop the players into the lobby. So:
  the first START with a dormant pad shows `PAD 3 IS NOT JOINED: START AGAIN FOR AN AI CAR` and arms the same 5 s
  window as the READY gate; the second START calls `launch.start({acceptDormant = true})`. That is a new optional
  argument, and it skips launch's own dormant refusal (launch.lua:733-744). RC-1.

### 2.7 Join, leave, re-open, class change

- A guest joins mid-step: a card appears at PILOT (defaults or its memory), the row re-lays out (§3.1); its join press
  is the input baseline (first poll primes, no edge).
- A guest leaves (B held 1 s): its card goes, its bay is released, its memory stays under its ControllerId.
- MODE and back in the same class: stages, rows and READY kept. A class change: every card restarts at PILOT; the pilot
  is kept when the new class allows it; presets and stages are per class.
- `setup.open()` (a new visit): cards start at PILOT with the remembered picks (A,A,A replays the last race); READY
  never survives a re-open.

### 2.8 Uniqueness

- Pilots are unique among humans (`PilotUnique`); SHADE may be shared with `PilotShareShade = true`. Cycling skips
  pilots another human holds (any stage); the roster still shows them darkened with a `P<n>` tag in the holder's colour.
- Class gating (PS §4.5): pod aliens and `DA_PlaneRacer_*` only for pods; SEBULBA (`DA_Racer_Mentor`) only for
  Skimmer; never TestPilot.
- Vehicles may be shared.

### 2.9 Hints, toasts, sounds, status line

- Hint line (pad glyph images + one word each; text only with `CardGlyphs = "text"`):

  | Context | Guest | P1 |
  |---|---|---|
  | strip | `LR STAGE` `Dn OPTIONS` | same |
  | PILOT | `LR PILOT` `A CONFIRM` `B(hold) LEAVE` | `LR PILOT` `A CONFIRM` `Up STAGES` |
  | VEHICLE | `LR CHANGE` `UpDn ROW` `A CONFIRM` `B BACK` | `... Up STAGES` |
  | PERKS (KIT) | `LR KIT` `A READY` `UpDn SLOT` `B BACK` | `... Up STAGES` |
  | PERKS (upgrade) | `LR LEVEL` `A NEXT` `UpDn SLOT` `B BACK` | same, `Up STAGES` |
  | PERKS (other) | `LR CHANGE` / `LR TIER` `A PICK` `UpDn SLOT` `B BACK` | same, `Up STAGES` |
  | picker | `UpDn CHOOSE` `LR GROUP` `A EQUIP` `B CANCEL` | `... A EQUIP` `Up(top) CANCEL` |
  | READY | `B CHANGE` `B(hold) LEAVE` | `A START` `UpDn ROW` `Up STAGES` |

  (`LR` = Dpad_Left + Dpad_Right glyphs, `UpDn` = Dpad_Top + Dpad_Bottom, `A`/`B` = FaceButton_Bottom/_Right.)
- A toast replaces the hint line for 2 s (amber text).
- Sounds (`CardSounds = "match"`): `UIAudioLibrary:Play2DAudioFromTable(<that player's PC>, DT_UI_Audio_ForceFeedback,
  row)` (cmap.lua `sound` pattern): `MainNavigation` on a guest's cursor/value move, `MainAccept` on every player's
  accept/equip/stage change; at most one sound per 80 ms overall. P1 gets no navigation sound from us: the sink's
  `WBP_Common_Btn` plays `MainNavigation` itself on each focus move (FG). `"accept"` = accept sounds only, `"off"`.
  (review) The BP plays `MainNavigation` on **every** focus received, programmatic ones included, and `MainAccept` on
  every click: `BP_OnFocusReceived` -> ubergraph @867 -> `Play2DAudioFromTable(..., 'MainNavigation')` @1024
  unconditionally, and `BP_OnClicked` -> @807 -> 'MainAccept' @10 (decoded `common_btn.kismet.txt`). So the
  return-to-centre `ui.focus(c)` adds a second tick per d-pad press. Also, racers.lua must **not** play `MainAccept`
  for an accept that came from a sink click (keyboard Enter included, since CommonUI clicks the sink); only the
  keyboard path without sink focus gets our accept sound. RC-6.
- Status line under the footer: `P1 PILOT · P2 PERKS · P3 READY` (plain text), replaced by gate warnings, join hints
  and errors.

---------------------------------------------------------------------------------------------------------------------

## 3. Visual spec

All sizes are slate units of the 3840x2160 design (1 su = 1 px at 4K, 0.5 px at 1080p, 0.333 px at 1280x720).
Reference renders (real exported art; fonts are stand-ins): GN `notes/design/game-native-mockups/mock-1p.png`,
`mock-2p.png`, `mock-2p-b.png`, `mock-3p.png`, `mock-4p.png` (+ `-720p`) are the look of this spec. Deltas: the PERKS
board adds three trait chips in the STYLE row (§3.5), the ability diamond uses our disc backdrop by default, the KIT
row has no separate CONTINUE row, the READY guest card has one row. CF `mock-2p-pilot.png` shows the roster strip
and the full-body hero at another size.

### 3.1 Page and row

| Element | Spec |
|---|---|
| Card row | `FuseSizeBox` 3500 x 1320 > `FuseScaleBox` (ScaleToFit, `SetStretchDirection(1)` DownOnly) > `FuseHorizontalBox` (centred); added to `W.panel` right after `W.vehRow` (classic columns, collapsed in cards flow) |
| Widths | 1 player: 1720 (centred) · 2: 1720 + 60 + 1720 · 3: 3 x 1140, gaps 40 · 4: 4 x 845, gaps 40 = 3500 |
| Width class | **W** (1-2 players, inner 1656) · **M** (3 players, inner 1076) · **N** (4 players, inner 781) |
| Footer | unchanged three buttons + `W.sinkHost` (96 x 96 `FuseSizeBox`, right end, holds the sink, §5.7.3) |
| Status line | unchanged label under the footer |

The real page has about 1640 su between the crumb (~400) and the game's action bar (~2040); after the footer and the
status line about 1400 su remain for the card row (GN measured on the 0.9.3 screenshots): card row 410-1730, footer
~1750-1836, status ~1870. The DownOnly ScaleBox shrinks the row if text or a taller game widget overflows (V-RC-15).
(review) It cannot shrink the row against the **page**. The setup panel lives in the cleared `WBP_Setting_List`
VerticalBox inside the menu's widget switcher (lobby.lua `pageRoot`), auto-height VerticalBox slots never constrain
their child, and the cards have fixed widths summing to 3500, so the HBox's desired size equals the SizeBox. If the
page is shorter than measured, the row overflows downward. The only remedy is `CardH` (V-RC-15 fallback); the
ScaleBox is harmless and may stay. RC-15.

### 3.2 Card shell (all classes)

`card` = `FuseSizeBox` (W x 1320) > `FuseOverlay` [ `frame` = `WBP_DarkPanel_C` (vars before add: `MainPanelColor` =
PANEL, `ShowShadow` true, `ShowTightPanel` false, `ShowGradientPanel` false; Fill/Fill; fallback a solid `FuseImage`
PANEL) ; `canvas` = `FuseCanvasPanel` (Fill/Fill, padding 32) ]. Everything below is placed on `canvas` (or on a stage
canvas) with `place(cv, w, {x, y, size = {w, h}})` (cmap.lua `place`). Every text sits in a fixed `FuseSizeBox` >
`FuseScaleBox` (ScaleToFit, DownOnly) > `FuseTextBlock`, so long names shrink instead of overflowing.
(review) That rule is for **single-line** text only. A ScaleBox lays its child out at its unconstrained desired
size, so `AutoWrapText` wraps at the one-line width and a "2 lines" text becomes one shrunken line. The game avoids
this the same way in `WBP_Character_Ability`: `RT_Desc` sits in a ScaleBox with a fixed `WrapTextAt` 700. So every
multi-line text below (the PILOT style description, the M/N style names and trait rows, the N info line, the M/N chip
names, the M tag lines) gets `t.WrapTextAt = <its box width>` and `AutoWrapText` false. `UTextLayoutWidget` has no
setter for it, so it is a property write right after construction, before the widget is added. The DownOnly
ScaleBox stays only as an overflow guard. RC-3.

| Part | y | h | Content |
|---|---|---|---|
| Header | 0 | 84 | tag pill 132 x 72 at (0, 6): `WBP_ButtonBacker_C` fill (IsOutline false, ContentColor = player colour) + `P2` Font_Display 44 INK, centred · view label at x 150, Font_Body "Semibold" 30, LetterSpacing 240, SAGE (`BOTTOM LEFT`) · READY tick `T_UI_Tick_Icn` 52 player colour after the label (READY only) · right: pilot name Font_Display 34 CREAM (W, M only, width 520 / 400) + pilot squircle 76 at x = inner W - 76 |
| Divider | 92 | 6 | `T_UI_Line_Divider_Hor_Cmn` tinted the player colour, full width |
| Stage strip | 110 | 80 | 4 tabs, each (inner W - 36) / 4 wide (W 405, M 260, N 186), gap 12. Current: fill backer in the player colour + Font_Display 28/24/22 INK. Visited: `T_UI_Tick_Icn` 24 + label BEIGE. Upcoming: label BEIGE @0.55. Cursor on the strip: `T_UI_Arrow_Icn` 52 at both ends (right one RenderScale X -1), player colour. (review) The 4 tabs + 3 gaps already fill the inner width (W 4 x 405 + 36 = 1656), so the arrows go **inside** the current tab's pill (36 su, beside the label), not at the strip ends. RC-15 |
| Stage area | 206 | 990 | one stage canvas per stage (only the current one visible); §3.3-3.6 positions are relative to it |
| Hint | 1208 | 48 | centred `FuseHorizontalBox`: [glyph 40][text Font_Body "Semibold" 24 LS 160 BEIGE] x up to 4, gap 28; or the toast (Font_Display 26 AMBER) |

### 3.3 PILOT

| Element | W (1656 x 990) | M (1076) | N (781) |
|---|---|---|---|
| Backdrop | (0, 0, 1656, 650): `T_UI_RacerStyle_<X>_Bg` in a ScaleBox ScaleToFill, clipped, colour 0.30 grey; pods: `setup.arcadeBg(planet, cls)`. (review) Path = `D.STYLES[key].bg`, never derived from the key: there is no `T_UI_RacerStyle_BattlingFlameVent_{Bg,Icn}` (SEBULBA's skimmer style key) and no `..._Slipstreaming_Bg`, and the PvP styles mostly have no `Background`. The generator maps BattlingFlameVent to Battling art and takes `bg` from `CAM_Style_<X>_Lv1`; `bg = nil` means the dark backdrop. RC-8 | (0, 0, 1076, 620) | (0, 0, 781, 600) |
| Figure window | (10, 0, 534, 650) | (0, 0, 510, 620) | (0, 0, 296, 600) |
| Figure crop | speeder pilots: whole frame (u 0-1) | whole frame | u 0.20-0.80 |
| Style block | x 574-1636: sublabel `RACER STYLE` y 34; style icon 150 (AMBER) at y 96; style name Font_Display 52 GOLD at (+176, 120); `PILOT'S OWN STYLE · 3 TRAITS` Font_Body Semibold 26 SAGE y 196; description Font_Body "Medium Italic" 30 BEIGE, 2 lines, y 270-350; 3 trait rows from y 380, pitch 80 (icon 58 + name Font_Body Semibold 28 CREAM + one-line description 22 BEIGE); signature line y 600 Font_Display 30 AMBER `SIGNATURE LANDSPEEDER · ORCA` or `ANY LANDSPEEDER` | x 528-1076: sublabel y 24; icon 120 at y 70 + name Font_Display 42 (2 lines) at x + 136; no description; trait rows (icon 46 + name 24) from y 246, pitch 64; signature y 560 (26) | x 314-781: sublabel y 24; icon 104 + name 36 (2 lines); trait rows (icon 46 + name 22, 2 lines) from y 230, pitch 74; signature y 556 (24) |
| Name plate | y 662-752: name Font_Display 70 CREAM left; `4 / 13` Font_Display 36 BEIGE right | y 632-720: 56 / 30 | y 612-696: 50 / 26 |
| Roster | y 772-952: 7 tiles (current 180, others 150, gap 16 = 1176 wide, centred); arrows 52 at both ends when the row has the cursor | y 732-892: (review) **6** tiles 160 / 132, gap 12 = 892 + arrows 2 x 40 (7 tiles + 52-su arrows = 1128 > 1076; RC-15) | y 704-854: 5 tiles 150 / 124, gap 10 = 686 + arrows (review) 2 x 40 (52-su arrows = 790 > 781; RC-15) |

**Figure window** (one code path for every pilot): a clipping `FuseSizeBox` (window w x h, `SetClipping(1)`) >
`FuseCanvasPanel` > the 1480x1800 image placed at scale `s = min(w / cw, h / ch)` where `cw = (u1 - u0) * 1480`,
`ch = (v1 - v0) * 1800`; size `1480 s x 1800 s`; x = `w / 2 - (u0 + u1) / 2 * 1480 s`; y = `h - v1 * 1800 s`
(bottom-aligned, centred). Speeder pilots use v 0-1 (common scale, the game's own versus-screen look); pod pilots use
their figure box from PS §5.3 (6 % padding) in every class, so Dud Bolt is not a small figure at the bottom.

**Roster tile:** `T_UI_FE_TileButton_300_Fill_Cmn` (TILE colour) + head shot through an MID of
`M_UI_CharacterProfilePicture` (param `Texture`, made and put on its image in the same tick; `CardThumbMask = "plain"`
= the transparent head shot on a `T_UI_Squircle_A_Fill_Cmn` TILE backer) + frame `..._Select_Cmn` in the player colour
(current) or `..._Unselect_Cmn` BEIGE @0.6. Taken: overlay `#131313 @0.85` + tag pill `P3` (holder's colour,
Font_Display 24 INK) at the bottom. The strip is centred on the current pilot and wraps.

### 3.4 VEHICLE

| Element | W | M | N |
|---|---|---|---|
| Render | (0, 0, 1156, 650) | (0, 0, 1076, 605) | (0, 0, 781, 439) |
| Fallback (no render yet / 3D off) | class art `V.classImage(cls, planet.art)` tinted 35 % player colour + badge | same | same |
| Badge | (1184, 10) 180: `vehicles.badge(p)`; pods without a badge: 3-letter model code Font_Display 60 on a TILE squircle | overlay (14, 14) 140 | overlay (14, 14) 124 |
| DRIVEN BY | sublabel at (1184, 230); pilot squircle tile 170 at y 280; pilot name Font_Display 34 at y 460 | tile 136 overlay bottom-left (14, 455) | below the render (y 455-595): tile 132, `DRIVEN BY` sublabel, name Font_Display 34 |
| SIGNATURE chip | (1184, 540) 300 x 60: TILE backer + `T_UI_Star_Icn` 40 + `SIGNATURE` Font_Display 28 AMBER (only when preset == pilot.sig[arch]) | overlay top-right of the render | 230 x 44 next to the tile |
| Name plate | y 662-752: model Font_Display 70 + `9 / 13` | 632-720 | 612-696 |
| MODEL row | pill y 772-852, x 70-1586 (`MODEL: ORCA`, Font_Display 30), arrows at x 10 / 1596 on the cursor row | 732-812 | 704-778 |
| LIVERY row | y 866-946 (`LIVERY: ARY QUILL` / `LIVERY: STANDARD` / pods `LIVERY: AGED`, `LIVERY: MYTH P2`) | 826-906 | 792-866 |
| Info line | y 950-990: maker (from the badge code: ACE, RAIDER, ENFORCER, ASSASSIN, ROBOTIC, VINTAGE) or pod name (`V.podName`) + class traits (`V.classInfo`), Font_Body Semibold 24 SAGE | 920-960 | 880-930 (2 lines, 22) |

All render boxes are 16:9 (the RT aspect). The render image takes the vpreview brush exactly as `setup.renderCard`
does today (SetBrushFromMaterial / SetBrushResourceObject, dimmed 0.5 while a new pick builds).

### 3.5 PERKS board

**W (1656 x 990)**

| Element | Box | Content |
|---|---|---|
| KIT row | (0, 0, 1000, 80) | pill `LOADOUT: REDLINER KIT` / `LOADOUT: CUSTOM · FROM REDLINER`, Font_Display 30 |
| Totals | (1040, 0, 616, 80) | `POWER 31 / 60` Font_Display 44 CREAM right-aligned (y 0-48); `ENERGY 3 + 9 = 12` Font_Body Semibold 24 SAGE (y 52-78) |
| Sublabels | y 100, h 36 | `ABILITIES` (x 0), `PARTS 4/6` (x 450), `UPGRADES` (x 930): Font_Display 28 AMBER + a 2-su AMBER @0.6 divider line to the column end |
| Ability diamond | origin (10, 146), 400 x 400 | cells 128: Up (136, 0), Left (0, 136), CRASH (136, 136), Right (272, 136), Down (136, 272). Cell = disc `T_UI_CircleBig_Fill_Cmn` TILE + ring `T_UI_CircleIconFrame_Cmn` BEIGE (crash: GOLD) + glyph `T_UI_Ability_<fam>_Icn` 64 % BEIGE + keyword sub-icon 35 % bottom-right + 1-3 level pips (BEIGE dots) at the bottom inside the ring; empty: disc only + `+` Font_Display 40 BEIGE @0.4. Optional backdrop `MI_HUD_Abilities_BG` behind the diamond (`CardDiamond = "hud"`, V-RC-06) |
| Part tiles | (450 + c*146, 146 + r*170), c 0-2, r 0-1 | tile 128: `T_UI_AFX_<x>_Icn` (finished tiles, no backer); 4 rarity pips `T_UI_MetallicRarityPip_Icn` 18 (gap 6, AMBER; count = rarity + 1) at y + 136; flaw: one RUST bar 90 x 8 instead of pips; empty: `T_UI_AffixFrame_NoRarity` BEIGE @0.5 + `+` |
| Upgrade rows | (930, 146 + k*66, 726, 60), k 0-5 | glyph `T_UI_BuildStats_<x>_Icn` 48 BEIGE · name Font_Body Semibold 26 LS 160 (`CORNERING`, `AFTERBURNER`, `RESILIENCE`, `RAMJET`, `BATTERY`, class move `DRIFT`/`KINETIC BURST`/`KNIFE EDGE`/`AIR BRAKE`) at x + 60 (w 300) · bar at x + 370 (280 x 28): `T_UI_StatProgressBar_Presentation_Cmn` tinted BAR_OFF, the same texture tinted BEIGE inside a left-aligned clipping `FuseSizeBox` of width level/10 · digit Font_Display 40 at x + 670 (w 56, right) |
| STYLE row | (0, 572, 520, 76) | pill: style icon 52 AMBER + `REDLINER` Font_Display 30 |
| Trait chips | (540 + t*372, 572, 362, 76), t 0-2 | TILE backer + trait icon 52 + name Font_Body Semibold 24 CREAM (ScaleBox); empty: `+ TRAIT` BEIGE @0.5 |
| Detail | (0, 668, 900, 262) + tag (0, 936, 900, 44) + art (1150, 668, 506, 262) | `WBP_Character_Ability_C` in a ScaleBox ScaleToFit (vars `Icon`, `ItemName`, `ItemDescription` (rich markup) then `Refresh()`; `BP_SetIsFocusable(false)`, HitTestInvisible); tag line Font_Body Semibold 22 AMBER (`LEGENDARY · TIER IV OF IV · RAMJET`, `D-PAD UP · LEVEL 2 · COST 2`, `LEVEL 8 OF 10 · 9 OF 13 STACKS · POWER 31`); large art 472x244-aspect image (`*_Lg_Icn`), hidden when missing. (review) The game card **never shows an icon**: `Img_Icon` sits in `O_HACK-HIDE`, which is Hidden at design time, and `Refresh()` collapses `SzB_IconSize` when the card is not locked (ubergraph @332-446). It is a SAGE title + rich text, about 748 su wide (`RT_Desc` WrapTextAt 700 + 2 x 24 padding; the 730 x 230 overrides of `SzB_AbilityDesc` are not enabled in the asset). So we draw the icon ourselves: icon (0, 668, 128, 128) (ability disc / affix tile / trait icon, the same image as the board cell) + card (148, 668, 752, 262). Do not write `Icon`. RC-5 |
| Picker (replaces y 100-648) | category row (60, 100, 1536, 70); rows (0, 186 + k*76, 1656, 70), k 0-5 | category pill `PARTS · RAMJET` with arrows + `3 / 14` right; row = icon 60 + name Font_Display 28 + pips / level dots + tick `T_UI_Tick_Icn` 40 in the player colour on the equipped item |

**M (1076 x 990):** KIT (0, 0, 1076, 72) · sublabels y 86 (24) · diamond origin (4, 126), cells 112, gap 8 (352 x 352) ·
parts at (380 + c*124, 126 + r*152), tiles 108 · totals (748, 126, 328, 124): `POWER 31 / 60` Font_Display 36 +
`ENERGY 12` Font_Body 22 · upgrades: label y 494; 2 columns x 0 / 548 (w 528), 3 rows pitch 60 from y 534: glyph 44,
name 22 (w 190), bar 200 x 26 at + 250, digit Font_Display 34 at + 470 · STYLE (0, 722, 360, 70) + chips
(372 + t*235, 722, 230, 70) icon 46 + name 20 (2 lines) · detail (0, 806, 620, 184) (ScaleBox: 0.70) + tag lines
(640, 806, 436, 184) Font_Body 22 AMBER, 3 lines; no large art · picker: category y 86-150, rows 164 + k*78 (8 rows).
(review) detail = icon (0, 806, 96, 96) + card (108, 806, 512, 184) (RC-5).

**N (781 x 990):** KIT (0, 0, 781, 72) · sublabels y 86 (22) · diamond origin (0, 122), cells 100 (316 x 316) · parts at
(340 + c*108, 122 + r*130), tiles 96 · totals (340, 380, 441, 50) `POWER 31/60 · EN 12` Font_Display 26 · upgrades:
label y 452; 2 columns x 0 / 396 (w 385), 3 rows pitch 56 from y 488: glyph 40, name 20 (w 150), bar 150 x 24 at
+ 195, digit 30 at + 350 · STYLE (0, 664, 260, 70) + chips (268 + t*171, 664, 166, 70) icon 44 + name 18 (2 lines) ·
detail (0, 748, 781, 200) (ScaleBox 0.76) + tag (0, 950, 781, 40) Font_Body 20 · picker: category y 86-150, rows
162 + k*76 (7 rows). (review) detail = icon (0, 748, 88, 88) + card (100, 748, 681, 200) (RC-5).

**Cursor looks** (every class): KIT / STYLE / picker category = fill backer in the player colour, INK text, arrows;
ability cell = ring tinted the player colour at render scale 1.08; part tile = `T_UI_FE_TileButton_300_Select_Cmn`
frame in the player colour around the tile; upgrade row and trait chip = solid backer player colour @0.30 + 8-su accent
bar in the player colour at the left; picker item = backer @0.31 + accent bar, name CREAM.

### 3.6 READY

| Element | W | M | N |
|---|---|---|---|
| Hero | figure window 330 x 560 at x 155 (style backdrop behind it) + still render 996 x 560 at x 505 | render (0, 0, 1076, 605) + pilot tile 150 overlay bottom-left | render (0, 0, 781, 439) + tile 134 overlay |
| Stamp | `READY` Font_Display 130 player colour, `SetRenderTransformAngle(-6)`, top-right of the render | 110 | 92 |
| Name line | y 572-632: `ARY QUILL · ORCA` Font_Display 50 CREAM + style name 30 AMBER right | y 617-667 (44) | y 451-495 (38) |
| Loadout strip | y 644-728, centred: 4 ability discs 84 (d-pad order Up, Left, Down, Right) + crash 67 (GOLD ring) + 6 part tiles 70 + style icon 70 + 3 trait icons 54 | y 673-737, one row (discs 64, crash 52, tiles 56, style 56, traits 44) | two rows: y 507-571 (4 discs 60 + crash 50 + style 56), y 583-641 (6 tiles 56 + 3 traits 40) |
| Totals | y 740-790 `POWER 31 / 60 · ENERGY 12` Font_Display 32 | y 760-800 (28) | y 760-796 (26) |
| Rows | y 826-902 and 914-990 (pills x 120-1536) | 840-910, 920-990 | 840-910, 920-990 |

P1 rows: `START RACE` (`START RACE · ALL READY` when everybody is READY, pulsing) and `SAVE AND RETURN`. Guest row:
`READY · WAITING FOR P1`.

### 3.7 Colours, fonts, highlight

| Token | Linear RGBA | sRGB | Source |
|---|---|---|---|
| PANEL | 0.012983, 0.036889, 0.048172, 0.90 | #1E363E | `WBP_DarkPanel` outer backer / character-select panel [V decoded] |
| TILE | 0.013702, 0.038204, 0.048172, 0.90 | #1F373E | `WBP_Tile_Btn.Img_Tile_Fill` (GN DEC) |
| BEIGE | 0.775822, 0.730461, 0.665387, 1 | #E4DED5 | run-map text (cmap INK_LIGHT) |
| CREAM | 1.0, 0.863157, 0.679543, 1 | #FFEFD7 | focused label (cmap INK_FOCUS) |
| SAGE | 0.361307, 0.456411, 0.376262, 1 | #A2B4A5 | `WBP_Character_Ability.Txt_Title` [V decoded] |
| AMBER | 0.745404, 0.412543, 0.08022, 1 | #E0AC50 | tooltip header / visited map line |
| GOLD | 0.623961, 0.351533, 0.076185, 1 | #CFA04E | character-select style name (GN DEC) |
| RUST | 0.4396, 0.0823, 0.0452, 1 | #B1513C | rich-text H1 accent (flaws, warnings) |
| BAR_OFF | 0.119538, 0.313989, 0.226966, 0.40 | #619883 @40 % | `WBP_MiniBuildStat_Entry` bar (GN DEC) |
| INK | 0.006995, 0.006995, 0.006995, 1 | #141414 | the BPs' near-black |
| Player colours | `C.COLOURS[1..4]` (consts.lua:281) | | tag pill, divider, current tab, cursor, stamp, taken tags |

Fonts: `/Game/Griffin/UI/Library/Fonts/Font_Display.Font_Display` typeface `Bold` (names, titles, digits, tabs, rows;
proven in cmap) and `Font_Body.Font_Body` typefaces `Semibold` / `Medium Italic` (labels, descriptions;
`WBP_Character_Ability` uses Font_Body Semibold 28.5 LS 240 [V decoded]). `FuseTextBlock:SetFont({FontObject,
TypefaceFontName = FName(...), Size, LetterSpacing})` (cmap `newText`). An unknown typeface falls back to the font's
default face [L], never an error.

Highlight rule: everything is drawn by Lua on non-focusable, `HitTestInvisible` widgets; every colour, visibility and
size is re-applied whenever its cached value differs, and **all render caches of a card are cleared on
`setup.onPageShown` and on a width-class change** (a Slate rebuild may reset BP-applied colours, V-RC-06).

### 3.8 Widget and asset inventory (static paths only; never a soft property)

| Element | Class / asset | Fed by | Status | Fallback (same for every card) |
|---|---|---|---|---|
| containers | `/Script/Griffin.Fuse{CanvasPanel,Overlay,SizeBox,ScaleBox,HorizontalBox,Image,TextBlock}` | `StaticConstructObject(cls, W.tree)` (setup `newW`) | [V live] | - |
| card frame | `/Game/Griffin/UI/Widgets/Decorative/WBP_DarkPanel.WBP_DarkPanel_C` (bottom overlay layer) | vars before add | [V decoded], [S] V-RC-06 | `CardFrame = "solid"`: `FuseImage` PANEL |
| pills | `/Game/Griffin/UI/Widgets/Global/WBP_ButtonBacker.WBP_ButtonBacker_C` x 2 per pill (outline: `IsOutline` true, ContentColor BEIGE @0.4; fill: `IsOutline` false, ContentColor = player colour, hidden unless active) | vars before add; later `B_Color:SetContentColorAndOpacity(c)` + `ContentColor = c` | [V decoded], [S] V-RC-06 | `CardHighlight = "solid"`: solid images |
| detail card | `/Game/Griffin/UI/Widgets/Character/WBP_Character_Ability.WBP_Character_Ability_C` | vars `Icon` (Texture2D by path), `ItemName`, `ItemDescription` (FText with the game's markup) then `Refresh()`. (review) Only `ItemName` + `ItemDescription`: the card's icon is never visible (`O_HACK-HIDE` Hidden; `SzB_IconSize` collapsed when unlocked), so our own image goes left of it (§3.5) | [V decoded], [S] V-RC-06 | `CardDetail = "plain"`: icon + 2 `FuseTextBlock`s, markup stripped |
| head shots | MID of `/Game/Griffin/UI/Library/Materials/Common/M_UI_CharacterProfilePicture.M_UI_CharacterProfilePicture`, param `Texture` | `KismetMaterialLibrary:CreateDynamicMaterialInstance` (as vpreview), same tick as the image | [V asset], [S] | `CardThumbMask = "plain"` |
| full bodies / thumbs | `/Game/Griffin/UI/Library/Textures/Content/Characters/<T_UI_*_Fallback / thumb>` | `SetBrushFromTexture` | [V live LoadAsset] | thumb |
| style art | `.../Textures/Icons/RacerStyles/T_UI_RacerStyle_<X>_Icn`, `.../Textures/Content/RacerStyles/T_UI_RacerStyle_<X>_Bg` | image. (review) Paths come from `D.STYLES[key].icon/.bg`. There are 15 `_Icn` and 14 `_Bg` (asset list); none is named BattlingFlameVent (it uses Battling's) and there is no Slipstreaming `_Bg`. The `_Bg` are 3840x2160 DXT1 NeverStream, about 4.1 MB each | [V exported] | none (dark backdrop) |
| perk art | `.../Icons/Abilities/T_UI_Ability_<x>_Icn` + `LargeAbilityIcons/*_Lg_Icn`, `.../Icons/Keywords/T_UI_Keyword_<x>_Icn`, `.../Icons/Affixes/T_UI_AFX_<x>_Icn` + `LargeAffixIcons/*_Lg_Icn`, `.../Icons/BuildStats/T_UI_BuildStats_<x>_Icn` + `LargeBuildStatIcons/T_UI_BuildStat_<x>_Lg_Icn` | image (paths from `perkdata.lua`, never derived from an asset name) | [V exported] | the family glyph / `T_UI_Ability_Empty_Icn` |
| commons | `.../Textures/Common/T_UI_CircleBig_Fill_Cmn`, `T_UI_CircleIconFrame_Cmn`, `T_UI_AffixFrame_NoRarity`, `T_UI_StatProgressBar_Presentation_Cmn`, `T_UI_Squircle_A_Fill_Cmn`, `T_UI_Line_Divider_Hor_Cmn`, `T_UI_FE_TileButton_300_{Fill,Select,Unselect}_Cmn`; `.../Icons/T_UI_MetallicRarityPip_Icn`, `T_UI_Tick_Icn`, `T_UI_Arrow_Icn`, `T_UI_Star_Icn` | image | [V exported] | solid quads |
| pad glyphs | `/Game/Griffin/UI/Library/Textures/Platform/Xbox/T_UI_Cntrl_XB_{Dpad_Left,Dpad_Right,Dpad_Top,Dpad_Bottom,FaceButton_Bottom,FaceButton_Right}_Icn` | image | [V exported] | `CardGlyphs = "text"` |
| diamond backdrop | `/Game/Griffin/UI/Library/Materials/HUD/MI_HUD_Abilities_BG.MI_HUD_Abilities_BG` | `SetBrushFromMaterial` | [S] (HUD MPC values in the front end) | default `CardDiamond = "disc"` |
| 3D render | vpreview MID (`M_UI_RetainerBox_ScreenSpace`) | `VP.brush(key)` | [V live] | class art |
| sounds | `/Game/Griffin/Audio/UI/DT_UI_Audio_ForceFeedback` + `/Script/Griffin.Default__UIAudioLibrary` | `Play2DAudioFromTable(pc, dt, FName(row))` | [V live in cmap] | `CardSounds = "off"` |

**Not used:** `WBP_Common_Btn` / `WBP_Vertical_Btn` inside cards (focus side effects); `WBP_Arrow_Btn` (prints
"Hello"); `WBP_Affix:SetInitialData`, `WBP_StyleTrait.Init`, `WBP_ItemAffixInfo`, `SetBrushFromSoftTexture` (soft
params, ARCH rev 0.5.1 §1); `WBP_Character_Ability:SetAbility/SetTrait` (blocking soft loads); `WBP_Input_Action`
(unverified); `WBP_Pip_List`, `WBP_AffixRarity` (our images are simpler); the game's character/vehicle select
screens (single-player CSM screens, PS §3.3).

### 3.9 Glyph rule

In-game strings use ASCII plus `·` only (`·` renders in the 0.9.x crumbs [V screenshot]). Arrows, ticks, stars, d-pad
and face-button symbols are images. `−` and `×` are written `-` and `x`. V-RC-01's screenshot check includes "no tofu".

### 3.10 ASCII mockups (`#x#` = player-colour fill; `(x)` = idle pill; `[t]` = tile; `(o)` = squircle; `<>` = arrows)

2 players, W: P1 on PILOT, P2 on PERKS (cursor on PART 1). GN `mock-2p.png` is this layout.
```
+------------------------------------------------------------+ +------------------------------------------------------------+
|#P1# TOP                                    SHADE (o)        | |#P2# BOTTOM                          ARY QUILL (o)          |
|================================ blue ======================| |================================= red ======================|
| <#PILOT#  VEHICLE   PERKS   READY>                          | |  PILOT   VEHICLE  #PERKS#   READY                          |
| +--------------------------------------------------------+ | |(LOADOUT: REDLINER KIT)                     POWER 31 / 60    |
| |  .--.    RACER STYLE ______________________________    | | |                                       ENERGY 3 + 0 = 3     |
| | (body)   [icon] RAMJET RIDER                            | | | ABILITIES ___    PARTS 4/6 ____   UPGRADES _____________  |
| |  |  |    PILOT'S OWN STYLE · 3 TRAITS                   | | |    ( ^ )        #[t]# [t] [t]    [i] CORNERING   ===== 5  |
| |  |  |    "A style for those who keep their cool..."     | | | ( < )(*)( > )    [t]  [+] [+]    [i] AFTERBURNER ==    2  |
| |  /  \    [i] OPTIMAL HEATSINKS  [i] CLEAN AIR  ...      | | |    ( v )                         [i] RESILIENCE ====== 8  |
| |          SIGNATURE LANDSPEEDER · BELUGA                 | | |                                  ... DRIFT       ===   6  |
| +--------------------------------------------------------+ | |(STYLE: REDLINER) [i]CRIT. RAMJET [i]EARLY WARN [i]EARLY II |
| SHADE                                              1 / 13  | | +-------------------------------+   +-----------------+    |
|  <  [o] [o] [o] #[O]# [o] [o] [o]  >                       | | |[t] RAMJET POWER IV            |   | large affix art |    |
|                                                            | | |    Ramjet is 50% more powerful|   |                 |    |
|   LR PILOT    A CONFIRM    Up STAGES                       | | +-------------------------------+   +-----------------+    |
+------------------------------------------------------------+ | LEGENDARY · TIER IV OF IV · RAMJET                         |
                                                               |   LR TIER    A PICK    UpDn SLOT    B BACK                 |
                                                               +------------------------------------------------------------+
```
4 players, N, one per stage (GN `mock-4p.png`):
```
+----------------+ +----------------+ +----------------+ +----------------+
|#P1# TOP L.  (o)| |#P2# TOP R.  (o)| |#P3# BOT L.  (o)| |#P4# BOT R. v(o)|
|==== blue ======| |===== red ======| |==== green =====| |==== yellow ====|
|#PIL# VEH PRK RD| |PIL #VEH# PRK RD| |PIL VEH #PRK# RD| |PIL VEH PRK #RD#|
||fig| RACER STY.| |[b] 3D render   | |(LOADOUT: SURV.)| | render  READY  |
||   | [i] RAMJET | |                | | ( ^ )  [t][t][t]| |[o]             |
||   |  RIDER     | |[o] DRIVEN BY   | |(<)(*)(>)[t][+]| | KESTAR · BOOL  |
||   | [i] OPT.   | |    ARY QUILL   | | ( v )  POWER 31| |(o)(o)(o)(o)(*) |
|SIGN. · BELUGA  | | [SIGNATURE]    | | [i]== 6 [i]== 5| |[t][t][t][t][ ] |
|SHADE     1 / 13| |ORCA     9 / 13 | |(STYLE)[i][i][i]| |POWER 26 · EN 12|
|< [o][P4][O][o]>| |<#MODEL: ORCA#> | |[detail card...]| |#READY · WAIT.# |
|LR PILOT A UpSTG| |(LIVERY: ARY Q.)| |LR CHG A PICK  B| | B CHANGE  HOLD |
+----------------+ +----------------+ +----------------+ +----------------+
```

---------------------------------------------------------------------------------------------------------------------

## 4. Data

### 4.1 Pilots (`pilots.lua`, static table from PS §2, §5.3, §6.7)

Texture folder `/Game/Griffin/UI/Library/Textures/Content/Characters/`; RacerDefs in
`/Game/Griffin/Narrative/CharacterDefs/Racers/`.

| id | name | classes | thumb / full | crop (pods: PS §5.3 box) | style key | sig (arch: preset) |
|---|---|---|---|---|---|---|
| DA_Racer_DarkEnigma | SHADE | 0, 1, 2, 3 | T_UI_PlayerChar_4 / _Fallback | full | Cooling | 0 Beluga_Protagonist, 1 MythP3, 2 Taipan_Protagonist, 3 Merlin_Protagonist |
| DA_Racer_ElegantProfessional | KATJA MOX | 0, 2, 3 | T_UI_PlayerChar_6 | full | Abilities | 2 Rattlesnake_ElegantProfessional |
| DA_Racer_Veteran | GRIFF HALLORAN | 0, 2, 3 | T_UI_PlayerChar_2 | full | Afterburner | 3 Saker_VeteranUpdated |
| DA_Racer_Protege | ARY QUILL | 0, 2, 3 | T_UI_RivalChar_Yara | full | Ramjet | 0 Orca_Protege |
| DA_Racer_InnerHonour | SOREN ZAKS | 0, 2, 3 | T_UI_PlayerChar_5 | full | Malfunction | 0 Snook_InnerHonour |
| DA_Racer_QuietStrength | NIK SKANDARO | 0, 2, 3 | T_UI_PlayerChar_1 | full | Defence | 0 Hammerhead_QuietStrength |
| DA_Racer_Ghost | GOLI & 02-R0 | 0, 2, 3 | T_UI_RivalChar_Ghost | full | Surging | 3 Pelican_Ghost (1 Hexing only with PodRivals) |
| DA_Racer_Nomad | FOLA KANJEN | 0, 2, 3 | T_UI_PlayerChar_3 | full | Struggling | 3 Condor_Nomad |
| DA_Racer_Thrall | SEN FIRA | 0, 2, 3 | T_UI_RivalChar_Sen | full | Drafting | 2 Boomslang_Thrall |
| DA_Racer_Rager | BIDDY BLAS | 0, 2, 3 | T_UI_RivalChar_Ziff | full | Burning | 2 Sidewinder_Rager |
| DA_Racer_Mercenary | MALIS VAZOSK | 0, 2, 3 | T_UI_RivalChar_Mercenary | full | Battling | 2 Boa_Mercenary |
| DA_Racer_Star | LYREN SHOK | 0, 2, 3 | T_UI_RivalChar_Lyren | full | Airborne | 3 Crow_StarUpdated |
| DA_Racer_Antagonist | KESTAR BOOL | 0, 1, 2, 3 | T_UI_Antagonist / T_UI_PlayerChar_Antagonist_Fallback | full | Antagonist | 0 Car_Antagonist, 1 Northropi |
| DA_Racer_Mentor | SEBULBA | 3 (`PilotExtras`) | T_UI_PlaneChar_Nesodon_Thumb / _Fallback | 0.228, 0.393, 0.806, 0.998 | BattlingFlameVent | 3 Rook_Mentor |
| DA_PlaneRacer_Cabbage | DUD BOLT | 1 | T_UI_PlaneChar_Cabbage_Thumb / _Fallback | 0.221, 0.458, 0.778, 0.993 | Pod_Cabbage | 1 Cretornis |
| DA_PlaneRacer_Celery | GASGANO | 1 | ..._Celery_... | 0.241, 0.292, 0.815, 0.994 | Pod_Celery | 1 Hexing |
| DA_PlaneRacer_Garlic | TEEMTO PAGALIES | 1 | ..._Garlic_... | 0.229, 0.229, 0.658, 0.995 | Pod_Garlic | 1 Sordes |
| DA_PlaneRacer_Nesodon | SEBULBA | 1 | ..._Nesodon_... | 0.228, 0.393, 0.806, 0.998 | Pod_Swede | 1 Nesodon |
| DA_PlaneRacer_Onion | BEN QUADINAROS | 1 | ..._Onion_... | 0.112, 0.041, 0.972, 1.000 | Pod_Onion | 1 Dearc |
| DA_PlaneRacer_Pepper | ODY MANDRELL | 1 | ..._Pepper_... | 0.203, 0.028, 0.688, 1.000 | Pod_Pepper | 1 Tarchia |

Class lists (display order): Car / Bike = the 13 `PvpPlayable` speeder pilots in table order; Skimmer = the 13 + SEBULBA
(`DA_Racer_Mentor`); Plane = DUD BOLT, GASGANO, TEEMTO PAGALIES, SEBULBA (`DA_PlaneRacer_Nesodon`), BEN QUADINAROS,
ODY MANDRELL, SHADE, KESTAR BOOL (+ the 11 speeder rivals with `PilotPodRivals`, the 5 Aged with `PilotPodAged`). A
speeder pilot's style key applies in every class it is offered for. `sig` presets are full `PRE_<Class>_<x>` ids
(vehicles.lua names); a pilot without `sig[arch]` shows `ANY <CLASS>` on the PILOT stage.

### 4.2 Vehicles (`vehicles.lua` additions)

- `V.models(arch)` -> `{ {base = "Orca", name = "ORCA", presets = {<preset entries>}, badge = path|nil,
  code = "ORC"|nil, podName = "VULPTEREEN 327"|nil}, ... }` grouping `V.presets(arch)` by `base` in first-appearance
  order; inside a model the standard preset comes first, then the owner liveries (pods: `AGED`, `MYTH P1/P2/P3`).
- `V.podName(base)`: Cretornis VULPTEREEN 327 · Hexing CUSTOM ORD PEDROVIA · Sordes IPG-X1131 LONGTAIL · Nesodon
  PLUG-F MAMMOTH · Dearc BT310 QUADRA · Tarchia EXELBROK XL 5115 (PS §2.2); Myth / Northropi: nil.
- Model counts: Car 13 (12 + ANTAGONIST), Bike 12, Skimmer 12, Plane 8. A model change keeps the pilot's signature
  livery if the new model has it, else its standard livery.

### 4.3 Perk catalog (`perkdata.lua`, generated by `tools/gen-perkdata.py`)

Counts (FG generator summary on the decoded hotfix paks): 6 upgrade parts x 11 levels; **45 player abilities** in 9
families (8 slot families + Ion Blast for the crash slot; the 4 `_AI` copies excluded); **316 player-facing affixes**
(52 tier ladders = 170 tiers, 81 single parts, 53 flaws, 12 pod traits; helpers `SAFX_*`, `AFX_AI_*` and the two
text-less customs excluded); **41 rule traits** (the 24 description-only `TRT_StartWith*` / `TRT_Plane_*` are never
offered or applied); 15 speeder styles + 6 pod styles.

| Picker category (parts) | Keyword glyph | Entries (one per ladder) | Rule (FG `gen_garagedata.py category()`) |
|---|---|---|---|
| AFTERBURNER | Afterburner | 21 | `Afterburner_*` |
| RAMJET | Ramjet | 17 | `Ramjet_*`, `MYST_Ramjet_*` (Ramming Jet) |
| COOLING & FROST | Cooled | 17 | `Cooled_*`, `Conditions_Cooled*`, `Frozen_*`, freeze |
| SURGE & OVERCHARGE | Surge | 16 | `Surge*`, `Surging_*`, `Overcharge*` |
| SHIELDS | Shielded | 4 | `Shielded_*`, `FirstPlace_*` |
| TAKEDOWNS | Takedown | 7 | `Takedown_*` |
| START & LANDING | PerfectLanding | 6 | `Ignition_*`, `PerfectStart_*`, `Landing_*` |
| ENERGY & ABILITIES | Battery | 12 | `Ability_*`, `Energy_*`, `AFXCustom_LotsOfBattery` |
| CRASH & SYSTEMS | Crash | 18 | `Crash*`, `CritMalf_*`, `SysMalf_*` |
| CONDITIONS & DRAFT | Corroded | 15 | other `Conditions_*`, `Burning_*`, `Choke_*`, `Concuss*`, `Corrode_*`, `Slipstream*` |
| FLAWS (`PerkFlaws`) | SystemMalfunction | 53 | `Faulty_*`, `MYST_FracturedTools`, `AFXCustom_Plane_PDay_Unstable` |
| POD TRAITS (pods only) | Ramjet | 12 | `PlaneTrait_*` |

Inside a category: rarity descending (LEGENDARY first), then name. Rarity shows as pips (COMMON 1 ... LEGENDARY 4);
FLAW = a rust bar; Plug-F Power Cell = `EXPERIMENTAL`. Descriptions have `{param}` filled at generation time; `rich`
keeps the game's `<widget id=.../>` / `<H1>` markup for `WBP_Character_Ability`, `desc` is plain.

Ability families (L/R order inside a family = tree order base, branch A, A II, branch B, B II): SHIELD (Shield, Impact
Shield, Impact Shield II, Surging Shield, Surging Shield II) · SURGE (Surge, Impact Surge, Impact Surge II, Overtaking
Surge, Overtaking Surge II) · VENT (Vent, Vent II, Auto-Vent, Supercooled Vent, Flame Vent, Corrosive Vent) · AUTOPILOT ·
ION BOLT · CONCUSSION MINE · SHOCKWAVE · STATUS SCRUBBER (each 5, PL §2.2) · crash slot: Ion Blast, Cooling Blast,
Charging Blast, Shielding Blast.

Trait groups (CF §3.4.3): AFTERBURNER, RAMJET, COOLING, SURGE, ENERGY, TAKEDOWNS, JUMPS, SLIPSTREAM, SURVIVAL, HEAT & ICE.
Dependent traits get a `NEEDS ...` tag line (Feel, Don't Think needs In the Zone; Potential Energy needs Repulsor Fuel
Link); not enforced. FPO trait icons are replaced by the group's keyword glyph.

(review) **System-dependent items.** The generator tags every part, trait and ability with
`needs = "ramjet" | "critmalf" | nil`:
- `ramjet`: the RAMJET category, `MYST_Ramjet_*`, and a **curated** list of items whose only effect is on the ramjet
  (e.g. `Cooled_PowerfulRamjet`, `Burning_PowerfulRamjet`, `Frozen_PowerfulRamjet`, `SysMalf_PowerfulRamjet`,
  `Takedown_ResetHeat`, `Surging_ResetRamjet`; `TRT_CriticalRamjetPower`, `TRT_RamjetExtendedAlarm*`,
  `TRT_RamjetReEngageAfterRelease`, `TRT_FrozenRamjetNoHeat`, `TRT_GainBurningWhenRamjet`);
- `critmalf`: `CritMalf_*`, `Faulty_CritMalf_*`.

The list is seeded by a keyword scan (Ramjet / Redlining / Critical Malfunction) that the generator summary prints
for a human check. Mixed effects stay offered with a `PARTLY RAMJET` tag line: Vent, `TRT_MalfunctionRepairOnRecovery`,
`TRT_StrongerAfterBurnerAndRamjetWhenBurning`, `TRT_RecoverFromSysMalfFaster`.

At step entry `perkapply` reads `RamjetInstalled` / `CriticalMalfunctions` once from the class's launch base. These
are plain bools on the loaded asset; an unset value reads the class default (V-PRK-09). The pod base
`VBD_000_1Mastiff_Plane` is the game's own "Memory Pod [No Ramjet]" (vehicles.lua STATIC_BUILDS) and decodes as
ramjet = false, critMalf = false. A system that is off removes its items from pickers and L/R cycling, and
`K.validate` drops them (toast `NO RAMJET ON PODS`). The RAMJET upgrade row stays, because its levels still count for
POWER (the power-rating TuneSet), but its detail tag reads `NO RAMJET: COUNTS FOR POWER ONLY`. `K.fromKit` refills
part slots emptied this way from the AFTERBURNER kit's parts, in order and skipping duplicates. Without that, SHADE,
P1's default in every class, would race a pod with 2 of the 4 RAMJET RIDER parts. Trait slots are refilled from the
AFTERBURNER kit's traits the same way. RC-2.

### 4.4 Kits (`perkdata.KITS`; style kits validated against the decoded data by CF `validate_presets.py`: ALL OK)

Style kits. Abilities in slot order Up / Left / Down / Right; parts = the top tier of each (slots 5-6 empty); traits
are `TRT_` names; tune = Cornering / Acceleration / Resilience / Boost / Battery / Advanced (PL).

| Key | Name | Abilities | Crash | Parts 1-4 | Traits | Tune (PL) |
|---|---|---|---|---|---|---|
| Cooling | RAMJET RIDER | Vent, Shield, Surge, Repair | IonBlast_Cooled | Conditions_Cooled_IncreasedPotency_v4, Cooled_PowerfulRamjet_v4, Conditions_CooledLastsLonger_v3, Ramjet_CoolsFaster_v4 | ImprovedCooling, GainCooledWhenInFirstPlace, GainCooledWhenInPodium | 6/10/2/0/8/0 (26) |
| Abilities | TECH EXPERT | Mine, Repair, Shockwave, Disruptor | IonBlast_Overclocked | Ability_FasterCooldown_v4, Ability_GainShielded_v2, Energy_GainSurging, Cooled_FastAbilityCooldown | NoEnergyGainOverchargeImproved, AbilitiesReduceAbilityCooldowns, EnergyForAbilityHits | 10/2/0/6/5/8 (31) |
| Afterburner | AFTERBURNER | Surge, Shield, Vent, Autopilot | IonBlast | Afterburner_IncreasedTopSpeed_v4, Afterburner_MoreDuration_v4, Afterburner_FasterRecharge_v4, Afterburner_FullFuelIncreasesPower_v4 | StrongerAfterburner, AfterburnerLastsLonger, RefillAfterburnerOnOvertake | 10/6/8/2/5/0 (31) |
| Ramjet | REDLINER | Surge, Vent, Shield, Autopilot | IonBlast_Cooled | Ramjet_MorePower_v4, Ramjet_ExtendedAlarm_v4, Ramjet_HeatReduction_v4, Ramjet_CriticalResetChance_v3 | CriticalRamjetPower, RamjetExtendedAlarm, RamjetExtendedAlarmUpgrade | 5/2/8/10/0/6 (31) |
| Malfunction | ENGINEER | Repair, Shield, Surge, Vent | IonBlast_Shielded | SysMalf_ShorterMalfunction_v2, Overcharged_RemoveSysMalf, SysMalf_PowerfulAfterburner, SysMalf_GainSurge | SurgeWhenSysMalfRecovery, RecoverFromSysMalfFaster, MalfunctionRepairOnRecovery | 0/8/5/2/6/10 (31) |
| Defence | SURVIVOR | Shield, Repair, Surge, Vent | IonBlast_Shielded | PerfectStart_GainShield_v3, Ability_GainShielded_v2, Crash_ReturnWithShield, Shielded_GainOnPerfectLanding_v3 | BetterTopSpeedWhenNoCrashes, GainSurgeOnShieldLoss, OneMoreCrash | 6/5/8/10/0/2 (31) |
| Surging | CLEAN RACER | Surge_Overtake, Shield, Vent, Autopilot | IonBlast | Condition_Surging_IncreasedPotency_v3, Surging_AfterburnerMoreDuration_v4, Surge_GainShielded, Surging_AfterburnerMorePowerful | EnergyForOvertakes, SurgeMoreTopspeed_Trigger, SurgeTopSpeedSnowball_Trigger | 0/8/2/6/10/5 (31) |
| Struggling | TENACIOUS | Autopilot, Shield, Surge, Repair | IonBlast | Crashes_CooledSurgingShieldedWhenOneCrashRemains, Crash_ReturnWithSurge, Crashes_IncreaseTopSpeed, CritMalf_PerfectRecoversCrash | CoolingAtBack, AfterCrashGainSurge, OneMoreCrash | 2/10/6/8/0/5 (31) |
| Drafting | SLIPSTREAMER | Surge, Shield, Vent, Shockwave | IonBlast | Slipstreaming_ImprovedBuffs, Slipstreaming_LastsUntilImpact, Slipstream_gainSurging_v3, PerfectStart_ImprovedSlipstreaming_v3 | BetterDrafting, LongerDrafting, BiggerDraftingZones | 10/5/6/8/2/0 (31) |
| Burning | FIREBUG | Vent_Flame, Shield, Surge, Mine | IonBlast | Burning_PowerfulRamjet, Burning_PowerfulAfterburner, Burning_GainOvercharged, Conditions_DecreaseBurningPotency_v3 | StrongerAfterBurnerAndRamjetWhenBurning, GainBurningWhenRamjet, BurningInfiniteRamjetAndAfterburner | 6/8/0/10/2/5 (31) |
| Battling | BRAWLER | Disruptor, Shockwave, Mine, Shield | IonBlast_Overclocked | Takedown_IncreaseSpeedStat_v4, Takedown_GainSurgeAndOvercharged_v3, Takedown_AbilityCooldown, Afterburner_MorePowerPerTakedown_v4 | EnergyForTakedowns, SurgeForTakedowns, SurgeForTakedownsUpgrade | 0/6/10/2/8/5 (31) |
| BattlingFlameVent | BRAWLER · FLAME VENT | Vent_Flame, Disruptor, Shockwave, Mine | IonBlast_Overclocked | as Battling | as Battling | as Battling |
| Airborne | STUNT RUNNER | Shockwave_Punch, Surge, Shield, Vent | IonBlast | Landing_PerfectBoost_v4, Afterburner_BetterWhileAirborne_v3, Surge_GainWhileAirborne, Landing_IncreaseSpeedStat_v3 | AfterburnerRefillOnPerfectLanding, AfterburnerPowerStacksWhenAirborne, AllLandingsArePerfect | 2/0/5/8/6/10 (31) |
| Antagonist | WEAPONIZED | Disruptor, Shockwave, Mine, Vent_Flame | IonBlast_Overclocked | Ability_FasterCooldown_v4, Takedown_AbilityCooldown, Energy_GainOnTakedown_v4, Energy_AddOnTakedown_v2 | EnergyForAbilityHits, EnergyForTakedowns, NoEnergyGainOverchargeImproved | 6/10/2/0/8/0 (26) |
| Frozen | ICE COLD | Vent_Freezing, Shield, Surge, Mine_Frozen | IonBlast_Cooled | Frozen_IncreaseSpeed, Frozen_PowerfulRamjet, Frozen_MoreCooling, Frozen_ReducedSteeringPenalty_v3 | FrozenRamjetNoHeat, OnFrozenGainShield, FrozenDoubleDuration | 6/8/5/8/2/2 (31) |

(Part ids above omit the `AFX_` prefix and trait ids the `TRT_` prefix; the data stores full asset names, e.g.
`AFX_Ramjet_MorePower_v4`, `TRT_CriticalRamjetPower`.) Pod kits = a base style kit with parts 1-2 replaced by the pod's trait pair
(`AFX_PlaneTrait_<VegPod>_1` Legendary bonus, `_2` Faulty drawback; PL §2.3.3) and parts 3-4 = the base kit's parts
1-2; style = the pod style (name and description of `Pvp_IA_Plane_<Veg>`, icon = the pilot's head shot), traits = the
base kit's:

| Key | Name | Base | Trait pair |
|---|---|---|---|
| Pod_Cabbage | VULPTEREEN 327 | Airborne | CabbageCretornis |
| Pod_Celery | CUSTOM ORD PEDROVIA | Defence | CeleryHexing |
| Pod_Garlic | IPG-X1131 LONGTAIL | Malfunction | GarlicSordes |
| Pod_Swede | PLUG-F MAMMOTH | BattlingFlameVent | SwedeNesodon |
| Pod_Onion | BT310 QUADRA | Afterburner | OnionDearc |
| Pod_Pepper | EXELBROK XL 5115 | (review) Drafting (was Ramjet: on a pod without ramjet its 2 ramjet parts and 3 ramjet traits would all be inert, RC-2) | PepperTarchia |

Other kits: `max` = the pilot's style kit with every level 10 (`MAX POWER · <STYLE>`, PL 60); `tier1`..`tier6` = the
game's quick-race builds (`TIER 1 · MASTIFF` ... `TIER 6 · WHIPPET`: levels 0..5, abilities and crash of
`VBD_000_1Mastiff` ... `VBD_058_6Whippet`, no parts; style and traits unchanged). KIT row order: `pilot`, `max`,
`tier1`..`tier6`, then the other style kits (`s_<Key>`, speeder classes: style table order without the pilot's; pods:
the other pod kits, then the speeder style kits).

### 4.5 Loadout model and encoding (`perks.lua`)

```lua
lo = { v = 1,
       kit = "pilot" | "max" | "tier1".."tier6" | "s_<StyleKey>" | "custom",
       from = "<kit key before it became custom>" | nil,
       style = "<StyleKey>",                                 -- STYLE row (perkdata.STYLES key)
       tune = { [0] = 5, 2, 8, 10, 0, 6 },                   -- EVehiclePartSlot 0..5, 0..10 each
       ab = { "Surge", "Vent", "Shield", "Autopilot" },      -- slots 1..4 (Up, Left, Down, Right); false = empty
       crash = "IonBlast_Cooled" | false,
       parts = { "AFX_Ramjet_MorePower_v4", ..., false, false },   -- #parts == cfg.PerkPartSlots
       traits = { "TRT_CriticalRamjetPower", ..., false } }        -- #traits == cfg.PerkTraitSlots
```
Ability ids are `BP_Ability_<id>_C` suffixes, part ids affix asset names, trait ids `TRT_*` names. **Code** (no `;`,
no `=`, no `@`): `v1,k:<kit>,f:<from|->,s:<style>,t:<6 levels joined by .>,a:<4 ids joined by .>,x:<crash>,
p:<parts joined by .>,r:<traits joined by .>` with `-` for empty. Example:
`v1,k:pilot,f:-,s:Ramjet,t:5.2.8.10.0.6,a:Surge.Vent.Shield.Autopilot,x:IonBlast_Cooled,p:AFX_Ramjet_MorePower_v4.AFX_Ramjet_ExtendedAlarm_v4.AFX_Ramjet_HeatReduction_v4.AFX_Ramjet_CriticalResetChance_v3.-.-,r:TRT_CriticalRamjetPower.TRT_RamjetExtendedAlarm.TRT_RamjetExtendedAlarmUpgrade`.

`K.validate(lo, arch)` (never throws): levels clamped 0..10; unknown ids dropped; crash ids only in the crash slot;
duplicate ability families / part families / traits dropped (later slots); plane-only parts dropped on speeders;
flaws dropped when `PerkFlaws = false` (pod trait pairs kept); arrays padded / truncated to the configured slot
counts; a pod style on a speeder class becomes the pilot's speeder style; unknown kit -> `custom`.

---------------------------------------------------------------------------------------------------------------------

## 5. Modules and interfaces

### 5.1 Module map

| File | Group | New / changed | Responsibility |
|---|---|---|---|
| `tools/gen-perkdata.py` | dev tool | new | generates `Scripts/perkdata.lua` from `work/decoded/perks/*.json` + the PNG export listing (based on FG `gen_garagedata.py`) |
| `Scripts/perkdata.lua` | G4 data | new (generated) | catalog tables, no functions, no game calls |
| `Scripts/pilots.lua` | G4 | new | pilot table + class lists, defaults, uniqueness, resolvers |
| `Scripts/perks.lua` | G4 | new | pure loadout logic: kits, cycling, pickers, detail data, validate, encode/decode, totals (no UObject access) |
| `Scripts/perkapply.lua` | G4 | new | game writes: base-build patch, pilots, field writes + read-back, race-world verify + traits, energy-cost cache, hot-reload record |
| `Scripts/cards.lua` | G3 | new | card widgets (lazy), per-class layout tables, diffed rendering of view models, texture queue (no input, no game state reads) |
| `Scripts/racers.lua` | G3 | new | the RACERS step: per-player state machines, input adapters (guests, P1 sink, keyboard), view models, previews, persistence glue, test helpers |
| `Scripts/setup.lua` | G3 | changed | builds the card row + sink host; delegates step "vehicles" to racers in cards flow; choice / persist / derive / finish |
| `Scripts/vpreview.lua` | G3 | changed | modes, global capture budget, spawn gap, stats; keys = ControllerId + 1; new defaults |
| `Scripts/launch.lua` | G4 | changed | plan carries flow / ctrlIds / pilots / loadouts; base-build call; `assignPilots` before the AI loop; perkapply calls; race tick |
| `Scripts/ui.lua` | G3 | changed | `registerButton(w, id, fn, opts)` with `opts.noClaim` |
| `Scripts/vehicles.lua` | G4 | changed | `models(arch)`, `podName(base)` |
| `Scripts/config.lua`, `settings.lua` | G1 | changed | keys §7.2, `Defaults.LastRaceRacers`, ENUMS / POSITIVE / FALSEABLE, ORDER / COMMENTS |
| `Scripts/main.lua` | G2 | changed | MODULES += `pilots`, `perkdata`, `perks`, `perkapply`, `cards`, `racers` (after `cmap`); PERSIST_MODULES += `perkapply` |
| `Scripts/diag.lua` | G2 | changed | F9 section `racers` (`racers.status()`, `perkapply.status()`, `vpreview.status()`) |
| `Scripts/consts.lua` | G1 | changed | `C.VERSION = "0.11.0"` |
| `notes/ARCHITECTURE.md`, `mod/SWGRCouch/README.md` | docs | changed | revision 0.11.0, §3.3 user text, §7 keys, §9 "0.11.0 checks" |

Require rules (ARCH §4.0): new modules `require` only G1 modules plus `vehicles` and `perkdata` (pure data) at the top;
everything else lazily through `U.mod(...)`. Every game call in `U.try`. TArrays only with `GetArrayNum`. Module state
in `St.racers` / `St.perks` so `diag` can dump it.

### 5.2 `pilots.lua`

```lua
P.ALL                                           -- {entry, ...} (§4.1); entry = {id, name, tag, classes = {[arch]=true},
                                                --   thumb, full (Texture2D paths), crop = {u0,v0,u1,v1} | nil,
                                                --   style = {[arch]=styleKey} | styleKey, sig = {[arch]=presetId},
                                                --   specialist = {[arch]=rank}}
P.list(arch) -> {entry, ...}                    -- display order (§4.1), gated by PilotExtras / PilotPodRivals / PilotPodAged
P.byId(id) -> entry | nil
P.allowed(entry, arch) -> bool
P.signature(entry, arch) -> presetId | nil      -- checked with vehicles.presetById
P.styleKey(entry, arch) -> styleKey
P.crop(entry, widthClass) -> {u0, v0, u1, v1}   -- pods: their box; speeders: full, or u 0.20-0.80 in "N"
P.defaultFor(arch, isP1, taken, remembered) -> entry   -- §2.4; taken = {[pilotId] = ctrlId}
P.step(arch, curId, dir, taken) -> entry | nil  -- next / previous allowed and free (wraps); nil = none free
P.def(entry) -> RacerDef UObject | nil          -- U.obj("/Game/Griffin/Narrative/CharacterDefs/Racers/<id>.<id>") (game thread)
P.favourite() -> pilotId | nil                  -- pc.PvpFlowComponent.DefaultPilot (only for PilotP1Default "favourite")
P.replacementOrder(arch) -> {id, ...}           -- AI de-duplication: CharacterList.Opponents order (static PS §1.2:
                                                --   Mercenary, ElegantProfessional, Star, InnerHonour, Thrall, Ghost, Rager,
                                                --   Nomad, Veteran, QuietStrength, Protege), then Antagonist, then Mentor
                                                --   (Skimmer / Plane), then the 6 pod pilots (Plane)
```

### 5.3 `perkdata.lua` and the generator

`tools/gen-perkdata.py <src dir> <png root> <out.lua> <summary.txt>` (`python3 -I`), based on FG
`~/.claude/jobs/5fb7892b/tmp/design/full-garage/gen_garagedata.py` (working; its sample compiles):
- inputs: `work/decoded/perks/{affixes.json, abilities.json, styles.json, vbds.json}` (copy them from
  `~/.claude/jobs/5fb7892b/tmp/perks-loadout/` first; that scratch is not kept) and
  `work/png/perks/Griffin/Content/Griffin/UI/Library/Textures/` (to keep only existing large icons);
- adds the kit table of §4.4 (CF `validate_presets.py` names) and fails loudly when any kit id is missing;
- output tables (stable names; paths stored as short names and expanded by `perks.lua` with `D.TEX`):

```lua
return {
  VERSION = "CL382493 2026-10-09", TEX = "/Game/Griffin/UI/Library/Textures/",
  STATS = { [0] = {key = "Cornering", vu = "RepulsorGrip", name = "CORNERING", part = "REPULSOR GRIP", icon, large, lv10}, ... [5] },
  ADVANCED = { [0] = "DRIFT", [1] = "AIR BRAKE", [2] = "KINETIC BURST", [3] = "KNIFE EDGE" },
  BATTERY = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13 }, STACKS = { [0] = 0, 0, 2, 3, 4, 5, 6, 7, 9, 11, 13 },
  FAMILIES = { {key = "Shield", name = "SHIELD", icon, large, order = {ids...}}, ... },   -- 8 slot families
  CRASH = { "IonBlast", "IonBlast_Cooled", "IonBlast_Overclocked", "IonBlast_Shielded" },
  ABILITIES = { [id] = {id, fam, lvl, name, desc, rich, icon, sub, large, cls, cfg, needs} },  -- cls = full class path;
                                       -- (review) cfg = native config class (abilities.json cfgType, e.g. "AbilitySurgeConfig"), RC-4
  PART_CATS = { {key, name, icon, podOnly = bool, flaws = bool}, ... },
  PARTS = { [id] = {id, name, rarity, cat, fam, tier, faulty, planeOnly, path, icon, large, desc, rich, needs} },  -- (review) needs §4.3
  PART_FAMILIES = { [fam] = {name, tiers = {id_I, id_II, id_III, id_IV}} },
  PART_LIST = { [catKey] = {id, ...} },                                                  -- picker order
  TRAIT_GROUPS = { {key, name, icon}, ... },
  TRAITS = { [id] = {id, name, group, desc, rich, icon, path, needs} }, TRAIT_ORDER = { id, ... },
                                       -- (review) traits already had `needs` (the NEEDS-trait link); rename that one
                                       -- `requires` and use `needs` for the system tag of §4.3, like PARTS / ABILITIES
  STYLES = { [key] = {key, name, desc, rich, path, icon, bg, traits = {3 ids}, pod = bool} },   -- (review) icon/bg real
                                       -- paths or nil (BattlingFlameVent -> Battling art; bg from CAM_Style_<X>_Lv1), RC-8
  STYLE_ORDER = { speeder = {...15}, pod = {...6} },
  KITS = { [key] = {key, label, style, tune = {[0]=...}, ab = {4}, crash, parts = {...}, traits = {...}} },
  TIERS = { "tier1", ..., "tier6" },
}
```
Self-check (summary file): counts of §4.3, every `path`/`cls` well formed, every icon present in the PNG export,
`luac5.4 -p` passes. Target size < 200 KB.

### 5.4 `perks.lua` (pure)

```lua
K.slots(arch) -> {"kit","ab1","ab2","crash","ab4","ab3","part1",...,"part6","tun0",...,"tun5","style","trait1",...}  -- board order
K.kits(arch, pilotStyle) -> {key, ...}               -- §4.4 order
K.kitLabel(key, pilotStyle) -> "REDLINER KIT" | "MAX POWER · REDLINER" | "TIER 3 · HUSKY" | ...
K.fromKit(key, arch, pilotStyle, prev) -> lo         -- prev keeps style + traits for tier kits
K.default(pilotStyle, arch) -> lo                    -- = fromKit("pilot", ...)
K.cycle(lo, slot, dir, arch, pilotStyle) -> lo, changed, toast     -- §2.5 L/R
K.picker(lo, slot, arch) -> {cats = {{key, name, icon}}, cat = i, items = {{id|false, name, icon, iconKind, rarity, lvl, faulty, equipped}}, sel = j}
K.pickerCat(lo, slot, arch, catIndex) -> items, sel
K.equip(lo, slot, id, arch) -> lo, toast             -- moves a family used elsewhere (swap)
K.detail(slot, lo, arch, itemId) -> {title, rich, plain, icon, large, tag}
K.power(lo) -> 0..60
K.energy(lo) -> base, bonus, total, note             -- 3 + BATTERY[tune[4]] (+ part notes: Volatile Battery, Dud Battery, Plug-F)
K.summary(lo, arch) -> {power, energy, nAb, nParts, nTraits, styleName, text}
K.validate(lo, arch) -> lo, notes
K.encode(lo) -> string ; K.decode(s, arch) -> lo | nil, why
```
`K` reads `cfg.PerkPartSlots`, `PerkTraitSlots`, `PerkFlaws`, `PerkUniqueFamily`. It requires **only** `config` and
`perkdata` (no `util`, no UE4SS global), so the offline unit test runs in plain Lua 5.4 (no game):
`decode(encode(lo)) == lo` for every kit x class; cycling never produces duplicates; validate is idempotent. The
ability energy cost (a game call) is added to the detail tag by `racers.lua` through `PA.abilityCost`.

### 5.5 `perkapply.lua` (game writes; exact calls in §6)

```lua
PA.launchBase(arch) -> UVehicleBuildDef | nil       -- VBD_000_1Mastiff (speeders) / VBD_000_1Mastiff_Plane (pods)
PA.prepareLaunch(plan) -> build | nil, why          -- in-memory patch, recorded in St.perks.patch
PA.restoreLaunch(why)                               -- idempotent; FRONTEND listener; after a hot reload by path
PA.assignPilots(racers, n, humans, plan) -> text    -- humans = {[psKey] = {ctrlId, pnum, ps}}
PA.applyAll(racers, n, humans, plan) -> report      -- per human: entry, field writes, read-back, log
PA.readBack(ps, arch) -> text
PA.raceTick()                                       -- MAIN race tick (any race phase): PRERACE/RACING verify + traits + fallback
PA.abilityCost(id) -> int | nil                     -- CDO GetEnergyCost(), cached (game thread)
                                                    -- (review) NOT on the ability CDO: that needs LoadAsset of the
                                                    -- BP_Ability_* actor class (VFX/SFX dependencies) on a cursor move.
                                                    -- Read U.cdo("/Script/Griffin.Default__" .. D.ABILITIES[id].cfg)
                                                    -- .EnergyCost (GfnAbilityConfig +0x38; native config CDOs are
                                                    -- resident; no DA_AbilityConfig_* stores EnergyCost except the 4
                                                    -- crash configs = 0). No ability class loads before the launch. RC-4
PA.systems(arch) -> {ramjet = bool, critmalf = bool} -- (review) flags of the class's launch base, read once (RC-2)
PA.persistShared(put) / PA.restoreShared(get)       -- the base-build patch record across a hot reload
PA.status() -> "patch none | last apply: P1 ok P2 ok | race: traits 3/3 3/3"
```

### 5.6 `cards.lua` (UI only) and the view-model contract

```lua
CD.init(ctx)            -- ctx = {tree, pc, newW, row (FuseHorizontalBox), realMs}; caches cleared
CD.layout(n) -> cls     -- n players: card widths / gaps, hides cards > n, returns "W" | "M" | "N";
                        --   re-places every built element from the class table (no rebuild), clears render caches
CD.ensure(i) -> bool    -- card shell i built (header, strip, hint, frame); at most cfg.CardBuildsPerTick per FAST tick
CD.render(i, vm)        -- builds the vm.stage panel on first use (one panel per tick), then diffs texts / images /
                        --   colours / visibility / sizes against per-widget caches
CD.tick()               -- texture queue: at most cfg.CardLoadsPerTick LoadAsset per FAST tick; marks waiting cards dirty
CD.tex(path) -> Texture2D | nil    -- cached or queued (nil until loaded: the element shows its backer); a cached object
                                   --   is re-checked with U.ok before use (a texture no brush holds yet may be collected)
                                   -- (review) U.ok is address-based (UE4SS IsValid = pointer in GUObjectArray and not
                                   --   unreachable, LuaUObject.hpp:761-764): a collected texture whose address a new object
                                   --   reuses passes it. A cache hit is used only when t:GetFName():ToString() equals the
                                   --   expected asset name (checked when an image changes, diffed render). RC-7
                                   -- (review) The queue budgets by size, not by count: at most one texture of >= 1 MB per
                                   --   FAST tick (full bodies 1480x1800 DXT5 2.7 MB, style _Bg 3840x2160 DXT1 4.1 MB, both
                                   --   NeverStream, no mips) and up to CardLoadsPerTick small ones. PILOT entry prefetches
                                   --   the class roster's full bodies one per tick. RC-9
CD.clearCaches()        -- page re-shown (Slate rebuild)
CD.forget()             -- page died: every reference dropped
CD.status() -> "cards 3 (M), widgets 512, panels 7, tex 41/44, mids 21"
```
View model (pure data, built by `racers.lua` immediately before `CD.render` in the same tick; `brush` objects come
from `VP.brush` in that tick, GC rule):
```lua
vm = { pnum = 2, colour = {R,G,B,A}, isP1 = false, view = "BOTTOM LEFT", ready = false,
  header = { pilotName = "ARY QUILL", thumb = path },
  strip = { stages = {"pilot","vehicle","perks","ready"}, current = 3, cursor = false },
  stage = "pilot" | "vehicle" | "perks" | "ready",
  pilot = { backdrop = path, full = path, crop = {u0,v0,u1,v1}, styleIcon = path, styleName = "REDLINER",
            styleLine = "PILOT'S OWN STYLE · 3 TRAITS", styleDesc = "...", traits = {{icon, name, desc} x3},
            signature = "SIGNATURE LANDSPEEDER · ORCA", name = "ARY QUILL", counter = "4 / 13",
            roster = {{thumb = path, current = bool, takenBy = pnum | nil}, ... 5 or 7}, cursor = bool },
  vehicle = { brush = UObject | nil, brushKind = "material" | "texture", dim = 1.0, fallback = path, badge = path | nil,
              code = "CRE" | nil, driver = {thumb = path, name = "ARY QUILL"}, signature = bool, model = "ORCA",
              counter = "9 / 13", modelRow = "MODEL: ORCA", liveryRow = "LIVERY: ARY QUILL", info = "...",
              cursor = 0 | 1 | 2 },
  perks = { kitRow = "LOADOUT: REDLINER KIT", power = "POWER 31 / 60", energy = "ENERGY 3 + 9 = 12",
            ab = { [1..4] = {glyph, sub, lvl, empty}, crash = {glyph, sub, empty} },
            parts = { [1..6] = {tile, pips, faulty, empty} }, partsLabel = "PARTS 4/6",
            tune = { [0..5] = {icon, name, level} }, style = {icon, name}, traits = { [1..3] = {icon, name, empty} },
            cursor = "kit" | "ab1" | ... | "trait3" | nil,      -- nil while the strip has the cursor
            detail = {icon, title, rich, plain, tag, large},
            picker = nil | {catName, catIcon, counter = "3 / 14",
                            rows = {{icon, iconKind = "tile"|"disc"|"glyph", name, pips, lvl, equipped, empty}}, cursor = 0..n} },
  readyPanel = { brush, brushKind, figure = {full, crop, backdrop}, line = "ARY QUILL · ORCA", styleName,
                 strip = {ab = {...}, crash = {...}, parts = {...}, style = path, traits = {...}},
                 totals = "POWER 31 / 60 · ENERGY 12", rows = {"START RACE", "SAVE AND RETURN"} | {"READY · WAITING FOR P1"},
                 cursor = 0..2, pulse = 1.0 },
  hint = { {glyphs = {"Dpad_Left", "Dpad_Right"}, text = "PILOT"}, ... } | nil, toast = nil | "LOADOUT KEPT" }
```

### 5.7 `racers.lua`

#### 5.7.1 API

```lua
R.build(ctx) -> ok             -- setup.buildWidgets: CD.init + the sink cluster in ctx.sinkHost; false = cards unusable
R.enter(cls, planet) -> sink   -- setup.showStep("vehicles") in cards flow: players, layout, previews; returns focus target
R.leave(why)                   -- other step / close / forget: previews released (VP.releaseAll), polling stops
R.poll(p1)                     -- FAST, from setup.pollNav (lobby not covered): order in 5.7.4
R.keepFocus()                  -- setup.keepFocus: re-focus the sink every 200 ms while Gamepad and focus is elsewhere
R.onKey(name)                  -- "up" | "down" | "left" | "right" | "accept" | "back2"
R.onP1Back()                   -- from setup's pollP1Back
R.onSinkClick(widget)          -- ui.pollClicks dispatch (noClaim) of any of the 5 sink buttons
R.onPlayers()                  -- join / leave
R.event(who, ev, rep) -> bool  -- who = pnum (1..4) | "c<ctrlId>"; the single mutator (pads, sink, keyboard, tests)
R.readyState() -> allReady, waiting   -- waiting = {"P2", ...} (joined guests not on READY)
R.choicePlayers() -> {[pnum] = {ctrlId, pilotId, presetId, buildPath, loadout = lo, code}}
R.persist(c)                   -- settings LastRaceRacers (+ LastRaceVehicles by setup)
R.restore(s)                   -- seeds memory from c.setup (St.race.choice) or settings (deriveSetup result)
R.status() -> text ; R.dump(who) -> text (view model) ; R.state() -> table   -- diag / test.cmd
R.forget()
```

#### 5.7.2 Per-player state (`St.racers`)

```lua
St.racers.players[ctrlId] = { ctrlId, pnum, pc, isP1, arch,
  stage = "pilot", row = { pilot = 1, vehicle = 1, perks = 1, ready = 1 },   -- 0 = strip
  picker = nil | { slot = "part1", cat = 2, sel = 7, top = 0 },
  pilotId, presetId, lo, follow = { vehicle = true, perks = true },
  nav = { primed, prev = {}, hdir, vdir, hNext, vNext, aDownMs, aUpMs, bDownMs },  -- guests
  presses = 0, toast = nil, toastUntil = 0, backArmUntil = 0, dirty = true, stillSince = 0 }
St.racers.memory[ctrlId] = { pilot = {[arch] = id}, preset = {[arch] = id}, lo = lo, stage = {[arch] = s}, row = {...} }
St.racers.p1 = { acceptAt = nil, lastKbMs = 0, sawB = false, sinkEvents = 0, leaks = 0 }
```
Invariants: one entry per joined local human; `stage` always valid; picks always complete (READY is possible from any
stage); READY <=> `stage == "ready"`.

#### 5.7.3 Input adapters

- **Guests** (`S.order[2..n]`): `readPad(pc)` on `IsInputKeyDown` for d-pad + left-stick directions, A, B (setup's
  PADK). First tick after (re)entry or join = baseline. A: event on the press edge; record `aDownMs` / `aUpMs` on both
  edges. B: `bDownMs` on press; on release `back` when held < `CardBackTapMaxMs` (600); a hold of 1 s leaves through
  join.lua (unchanged, `guestBHoldsToLeave` true for the whole step). Directions: edge + repeat (400 / 140) on both
  axes. (review) Every direction edge and repeat is time-stamped (`nav.dirMs[dir]`) for the P1 direction guard below.
  KeyboardIsP1: the guest on pad 1 (join.lua `startOnlyFor`, :284-292) is Slate user 0, so its B is also P1's CommonUI
  Back ("Exit Game?"). Its card ignores B, goes back through the strip, and its hint shows `▲ STAGES`. RC-11.
- **P1 sink:** five `WBP_Common_Btn` made with `ui.button(W.pc, "setup:sink:<k>", "", R.onSinkClick, {noClaim = true})`,
  render opacity 0, Visible, focusable, placed on a `FuseCanvasPanel` in `W.sinkHost` (96 x 96): `c` at (34, 34),
  `u` (34, 0), `d` (34, 68), `l` (0, 34), `r` (68, 34), each 28 x 28 su (the plus shape is the geometric fallback).
  Explicit rules: `c:SetNavigationRuleExplicit(2, u)`, `(3, d)`, `(0, l)`, `(1, r)`; every neighbour points back to `c`
  in all four directions (EUINavigation Left 0, Right 1, Up 2, Down 3). Focus detection each FAST tick: `holds(c, p1)`
  (one `HasUserFocusedDescendants`); else each neighbour; a neighbour holding focus = one direction event when
  `setup.p1Gamepad()` is true, `KeyboardIsP1` is off and no keyboard event came in the last 300 ms; then
  `ui.focus(c, p1)`. Focus elsewhere = a leak: counted; `R.keepFocus` returns it within 200 ms while Gamepad.
  (review) A neighbour event is **dropped** when a guest had the same direction edge or repeat within 50 ms
  (`nav.dirMs`), and logged `racers: P1 right dropped (P2 right 20 ms) (V-RC-07)`. This is insurance against a guest
  pad driving P1's CommonUI navigation (task #14's mechanism is unknown; `bFilterInputByPlatformUser=False`). The
  2026-10-07 session B log shows no such leak: the guest navigated for about 1.5 min and P1's cycler logged no step
  (`state/runs/20261007-1033-session-E/UE4SS-E1-podrace.log` 902-909). RC-10.
  (review) Optional `CardP1Input = "ring"` (A/B against "sink" in V-RC-02 and V-RC-30): the 5 buttons are wired as Z5
  (from button b: Up -> b+1, Down -> b-1, Left -> b+2, Right -> b-2, mod 5). The direction is the index delta of the
  newly focused button, and there is no programmatic re-focus except leak recovery. That gives exactly one BP
  `MainNavigation` per press (RC-6) and no lost press when CommonUI repeats before the poll. The risk: two moves
  between two polls (a hitch) read as one wrong direction (+1 +1 = Left).
- **P1 accept:** a sink click sets `p1.acceptAt = now` (any of the 5 buttons). The next `R.poll` dispatches it unless a
  guest's A is down or had an edge within `CardGuestClickGuardMs` (150) of `acceptAt`; a drop logs
  `racers: P1 accept dropped (P3 A 40 ms) (V-RC-07)`.
  (review) The sink buttons are Visible (Slate's geometric navigation needs hit-testable widgets), so the mouse can
  click the invisible 96 x 96 area. A sink click while CommonInput reports MouseAndKeyboard and no keyq `accept`
  arrived within 300 ms is a stray mouse click: it is ignored and logged. Enter still works, because its keybind
  stamps `lastKbMs`. RC-6.
- **Keyboard** (`R.onKey`): arrows -> P1 directions (stamp `lastKbMs`); `accept` -> P1 accept only when no sink button
  holds P1's focus (otherwise CommonUI clicks the sink itself); `back2` -> P1 back.
- **P1 B:** `R.onP1Back()` -> P1 back.

#### 5.7.4 `R.poll` order (one FAST tick)

1. guests' pads -> events (records A/B edges);
2. P1 sink focus -> direction events;
3. P1's queued accept (guard) -> event;
4. toasts / back-confirm / START pulse timers;
5. previews: per player `VP.want(key, preset, cls)` + `VP.setMode(key, mode)` (VEHICLE "spin"; PILOT "still" after
   the pilot was still `SetupPreviewPrebuildMs` (600), as a prebuild of the pick; PERKS / READY "still"), then
   `VP.tick()` (changed bays mark their cards dirty);
6. `CD.tick()` (texture queue, lazy panels);
7. render up to `CardRendersPerTick` (2) dirty cards, oldest first: build vm (calls `VP.brush`) -> `CD.render`;
8. status line text when it changed.

Every block in its own `U.try`; one bad player never stops the others.

### 5.8 `vpreview.lua` changes

| Change | Detail |
|---|---|
| Keys | callers pass `key = ctrlId + 1` (1..4); `origin(key)` unchanged in form; a key is never reused by another pad |
| Modes | `VP.setMode(key, mode)`, mode `"spin"` or `"still"`: spin = today's turntable and captures (`SetupPreviewCaptureMs`, default 66); still = turned to `SetupPreviewYaw` and captured at ready, +500 ms and +2 s (late parts), then never until the pick changes. (review) Three captures cannot converge: Lumen GI/reflections, TSR and auto exposure accumulate per capture (`bAlwaysPersistRenderingState`; DefaultEngine.ini Lumen + TSR, vehicle-preview.md §1.3). A still is therefore a **burst** of `SetupPreviewStillBurst` (8) captures on consecutive budget slots at ready, again after the late-part refresh (+2 s) and on page re-show. RC-12 |
| Budget | at most `SetupPreviewCaptureBudget` (1) `CaptureScene` per `VP.tick`, round robin over due bays (oldest `lastCap` first) |
| Spawn gap | a bay's `apply` (spawn) waits until `SetupPreviewSpawnGapMs` (300) passed since the last spawn of any bay |
| Defaults | `SetupPreviewSpacing` 20000 (was 5000; §0.3 #7), `SetupPreviewW/H` 960 x 540 (was 640 x 360), `SetupPreviewCaptureMs` 66 |
| Stats | `VP.stats()` -> {captures, capturesPerSec (10 s window), spawns, bays}; `status()` adds modes |
| Classic | classic flow keeps column keys 1..4 and mode "spin" (no change in behaviour). (review) The new defaults (spacing 20000, RT 960 x 540, capture 66 ms) apply to the classic columns too; that is harmless, but V-RC-28's regression shot must not expect 640 x 360 |

### 5.9 `setup.lua` changes (anchor by function)

| Function | Change |
|---|---|
| `buildWidgets` (421) | after `W.vehRow`: `W.cardBox` (SizeBox `CardRowW` x `CardH`) > ScaleBox DownOnly > `W.cardRow` (HBox, centred); footer: `W.sinkHost` (SizeBox 96 x 96, collapsed); `pcall(R.build, ctx)` with `ctx = {tree, pc, newW, row = W.cardRow, sinkHost = W.sinkHost, realMs = M.realMs}`; failure -> `W.cardsBroken` (classic for this page, logged once) |
| `STEP_TITLE` / `crumb` | `vehicles` = `STEP 5/5  RACERS` in cards flow |
| `showStep` (1488) | cards flow and step "vehicles": `show(W.cardBox, true)`, `show(W.vehRow, false)`, `show(W.sinkHost, true)`, `target = R.enter(S.cls, S.planet)`; any other step: `R.leave("step x")`, card box and sink host collapsed |
| `pollNav` (1930) | in step "vehicles" + cards: `R.poll(p1)` replaces `focusedWidget/onFocus`, `pollGuests` and `VP.tick`; `pollP1Back` stays and calls `R.onP1Back()` |
| `keepFocus` (1956), `onKey` (1967), `onPlayers` (1990), `onPageShown` (1985) | cards: `R.keepFocus()`, `R.onKey(name)`, `R.onPlayers()`, `CD.clearCaches()` + `M.focus(sink)` |
| `makeChoice` (1589) | cards: `c.build = PA.launchBase(arch)`; `c.setup.flow = "cards"`; `c.setup.players = R.choicePlayers()` (fields `presetId`, `buildPath` kept for `LastRaceVehicles` / `launch.plan`) |
| `persistExtras` (1614) | also `R.persist(c)` |
| `deriveSetup` (1629) | parse `LastRaceRacers` (§7.1) into `s.players[pnum]` for the ControllerIds present now (P1 = 0; guests from `join.joinedList()`); `s.flow = "cards"` when `SetupPlayerFlow == "cards"`, the key is non-empty and `c.build` is the class's base build |
| `preselect` (1654) | cards: `R.restore(s)` |
| `finish` (1725) | cards: the gate's `waiting` list from `R.readyState()` |
| `close` / `forget` | `R.leave(why)` / `R.forget()` |
| new `M.p1Gamepad()` | export of `gamepadInput()` (1794) |
| new `M.debugJump(spec)` | only with `cfg.TestCommands`: `M.open()`, set `S.cls` (`V.classByKey(spec.class)`), `S.planet` (key), `S.tracks` + `S.track` (first track of the planet, or `spec.track` key), `S.cond` (track default), `S.mode` (`spec.mode` or "race"), then `M.showStep(spec.step or "vehicles")`; returns a summary string |

### 5.10 `launch.lua` changes

| Where | Change |
|---|---|
| `M.plan` (204) | carries `flow = s.flow`, players with `ctrlId`, `pilotId`, `loadout` |
| `localHumanPS` (256) | unchanged (classic code keeps `{[psKey] = pnum}`); new `localHumans()` returns `{[psKey] = {pnum, ctrlId, ps}}` (P1 ctrlId 0; guests from `join.joinedList()`) for the cards path; picks are matched by **ctrlId** first, then pnum (log `pick of P3 re-mapped by ControllerId`) |
| `M.start` (723) step 7 | cards flow and `PerkApply ~= "off"`: `build = PA.prepareLaunch(plan)` (fallback `choice.build` on error); `PA.restoreLaunch("after call")` right after `LaunchCustomRace`, before the acceptance check; `undoPrelaunch` also restores |
| `applyRecipe` (439) | humans' presets (unchanged) -> **`PA.assignPilots`** (cards flow; classic keeps `assignGuestPilots` where it is) -> AI class loop (unchanged; `aiPreset` now sees the final pilots) -> cards: `PA.applyAll`; classic: per-guest `applyBuild` as today |
| `St.launch.vehPlan` | `{arch, players, flow}` |
| `M.raceTick` (565) | first line `U.try(TAG, PA.raceTick)` (every race phase), then the existing LOADING-only body |
| FRONTEND listener (`ensureListener`, 590) | also `PA.restoreLaunch("frontend")` |

### 5.11 Small changes

- `ui.lua` `registerButton(w, id, fn, opts)` (130): store `opts`; in `pollClicks` (368) an entry with `opts.noClaim`
  skips `ui.claimAction` and `lobby.consumedClick`. `ui.button(pc, id, text, fn, opts)` passes `opts` through.
- `vehicles.lua`: `M.models(arch)`, `M.podName(base)` (§4.2).
- `main.lua`: MODULES `..., "cmap", "pilots", "perkdata", "perks", "perkapply", "cards", "racers", ...`;
  PERSIST_MODULES += `"perkapply"`.
- `diag.lua`: `section("racers", ...)` after `vpreview`.
- `consts.lua`: `C.VERSION = "0.11.0"`.

### 5.12 Performance budget (4 players)

| Item | Budget |
|---|---|
| Widgets | card shell ~70; PILOT ~70 (7 roster tiles x 6); VEHICLE ~30; PERKS ~170 (diamond 5 x 5, parts 6 x 7, upgrades 6 x 6, chips, detail, picker built on first open ~60); READY ~45 -> ~450 per fully used card, built over many ticks |
| Build per tick | 1 card shell or 1 stage panel or 1 picker (`CardBuildsPerTick`), each logged with its ms (V-RC-16) |
| Render per tick | 2 dirty cards; a cursor move touches 2-6 widgets |
| Loads per tick | 3 textures; step entry queues the class's thumbs (<= 14), the shown pilots' full bodies (2.6 MB each), style icons; PERKS entry queues the 9 ability glyphs, 6 stat icons, current part tiles; a picker queues its category; large art on demand. (review) At most one >= 1 MB texture per tick (RC-9). No `BP_Ability_*` class is loaded in the front end: energy costs come from the native config CDOs (RC-4) |
| Previews | 1 capture per FAST tick in total (~30/s max), ~15/s per spinning bay; 1 spawn per 300 ms; stills cost 3 captures per pick. (review) ~15/s per bay holds for <= 2 spinning bays; with 4 players on VEHICLE it is 7.5/s each (a 2 deg turntable step: acceptable, or set `SetupPreviewSpinDps` 10). A still costs a `SetupPreviewStillBurst` (8) burst per pick (RC-12) |
| Polls | 4 pads x 6 keys `IsInputKeyDown`; 1-5 `HasUserFocusedDescendants` |
| UIManager | no layer query added; `R.leave("start")` stops all polling on START (CM R11) |

---------------------------------------------------------------------------------------------------------------------

## 6. Launch-time application (exact order; reflected calls only)

1. `launch.start` checks, dormant gate, `plan = M.plan(choice)`, `prepareGrid` (unchanged).
2. `net.beforeLaunch`, `join.commit`, bookkeeping (unchanged).
3. **Base build** (`PA.prepareLaunch`, only when `plan.flow == "cards"` and `PerkApply ~= "off"`):
   - `def = U.obj("/Game/Griffin/Vehicles/Common/Upgrades/BuildDefinitions/VBD_000_1Mastiff.VBD_000_1Mastiff")`
     (pods `VBD_000_1Mastiff_Plane`): no abilities, no crash ability, no affixes (PL §2.5);
   - read `u0 = def.UnlockedAffixSlots`, `m0 = def.MaximumAffixSlots` (Mastiff 4 / 10; `_Plane` class defaults, logged,
     V-PRK-09); write `UnlockedAffixSlots = cfg.PerkPartSlots` (6) and `MaximumAffixSlots = max(m0, 6)`;
   - record `St.perks.patch = {path, u0, m0}` (persisted by `PA.persistShared` for a hot reload).
4. `gm:LaunchCustomRace(archetype, gameMode, track, cond, def, nil)`; then at once `PA.restoreLaunch("after call")`
   (the conversion ran synchronously inside the call, PL §1.3 #1-2). Log
   `perkapply: VBD_000_1Mastiff UnlockedAffixSlots 4 -> 6 -> 4 (V-RC-19)`.
5. Accepted check (PrimaryFlow) unchanged; refused -> `undoPrelaunch` (restore is idempotent).
6. `applyRecipe`:
   1. humans: `VehicleType`, `VehicleCustomisation` = the pick (unchanged code);
   2. **`PA.assignPilots(racers, n, humans, plan)`** (PS §6.5): for every human with `pilotId`: `r.Pilot = P.def(e)`
      (`FRecipeRacerSetup.Pilot` +8) and `pcall(function() r.Player.Pilot = def end)` (`GfnPlayerState.Pilot` +0x3D0);
      then every AI whose `Pilot` FName equals a human's pick gets the next free pilot of `CharacterList.Opponents` order,
      then KESTAR, SEBULBA (Skimmer / Plane only), the pod pilots (Plane only); none free -> kept (duplicate). Log
      `pilots: P1=DA_Racer_DarkEnigma P2=DA_Racer_Protege; AI re-assigned 1 (V-RC-20)`;
   3. AI class loop (unchanged);
   4. **`PA.applyAll`**, per human (P1 included; `U.try` each):
      - `rbs = ps.RacerBuildState`; `idx = arch`, pods `idx = tonumber(rbs.ArchetypeToUseForPlane)` (also write entry
        `arch` and log both); error when `idx + 1 > rbs.VehicleBuilds:GetArrayNum()`; `e = rbs.VehicleBuilds[idx + 1]`;
        error when `e.UpgradeSlots:GetArrayNum() < 6` or `e.AbilitySlots:GetArrayNum() < 4`;
      - upgrades, s = 0..5: `d = U.obj(UP .. "VU_<vu>_<NN>")` (level 1 = `_001`, else `%02d`); `u = e.UpgradeSlots[s + 1]`;
        `u.UpgradeQuality = d.BaseQuality`, `u.UserFacingStatIncrease`, `u.TunesetToApply`, `u.IsStackingTuneset`,
        `u.StacksToApply`, `u.PowerLevel`, `u.CreditsValue` from `d`, `u.AuthoredUpgrade = d`; then
        `e.OverridenPowerLevel = 0` (PL §5.3);
      - abilities: `e.AbilitySlots[i] = U.class(cls)` for each non-empty slot i = 1..4 (empty slots stay empty from the
        base: a nil class write is a no-op, PL §5.4); `e.CrashAbility = U.class(cls)` when set;
      - parts, i = 1..`e.AffixSlots:GetArrayNum()`: `a = e.AffixSlots[i]`; `a.PrimaryAffix = cfg or nil`,
        `a.SecondaryAffix = nil`, `a.PlaneSpecific = false`,
        `a.Status = cfg and ((cfg.FaultyRules:GetArrayNum() > 0) and 2 or 1) or 0`; pod traits go in normal slots;
      - flags only when configured: `PerkRamjet` "on"/"off" -> `e.RamjetInstalled` (speeders only); `PerkCritMalfunctions`
        "on"/"off" -> `e.CriticalMalfunctions`; `UseHealth` never (wreck.lua owns it); never `PawnOverride`;
        (review) pods: `PerkPodRamjet` (default false, = the game's own "Memory Pod [No Ramjet]") true writes
        `e.RamjetInstalled = true` for arch 1. The game ships `VBD_000_1Mastiff_Plane_Ramjet` with ramjet left at the
        class default, so a ramjet pod exists in the data (V-RC-32). Whatever is written here is also what
        `PA.systems(arch)` reports to the board, so the pickers never offer items for a system the car will not have;
      - never assign a Lua table to a struct or an array, never resize, never index past `GetArrayNum()`;
      - read back every field: `loadout: P2 build[Car e0]: lv 5/2/8/10/0/6 PL31 abil Surge,Vent,Shield,Autopilot crash
        IonBlast_Cooled parts 4/6 (V-RC-21)`; a mismatch is a WARN and the report says `P2 LOADOUT PARTIAL`.
7. `St.launch.vehPlan = {arch, players, flow}`; `diag.recipe()`; `St.emit("launched")`.
8. **Race world** (`PA.raceTick` from `launch.raceTick`, MAIN, phases PRERACE and RACING, only when
   `St.race.launchedByUs` and the plan's flow is "cards"): for every local human (race-world PCs; ctrlId from
   `pc.Player.ControllerId`), once per `St.worldGen` when `pc.PlayerState` and the pawn are valid:
   - **verify** `VehicleBuilds[idx + 1]` against the plan and `ps.AbilityComponent.AbilitySlots` (4 classes) +
     `CrashAbilitySlot`: `loadout: P2 in race: build ok, abilities 4/4, crash ok, parts 4 (V-RC-21)`;
   - **traits** (`PerkTraits`): `n0 = ps.PassiveManagerComponent.PassiveList:GetArrayNum()`;
     `ps:Server_ApplyPassive(U.obj(TRT_path))` per non-empty trait (Server RPC on a local PlayerState: runs locally on
     the standalone / listen host, PL §5.2 #5); log the count delta (V-RC-22); `ps.RacerStyle` untouched unless
     `PerkSetRacerStyle`;
   - **late fallback** (`PerkLateFallback`): when the verify found the parts missing, `Server_ApplyPassive(affixCfg)` for
     each planned part; abilities and levels cannot be re-applied after spawn (PL §1.3 #7): WARN
     `P2 abilities/levels lost in travel (V-PRK-06)`. (review) FLAW parts are skipped here. A passive made by
     `Server_ApplyPassive` has no `FVehicleAffix.Status`, so the Faulty path (`Status = 2` -> `FaultyRules`) never runs
     and a flaw would apply its normal `PassiveRule[]` or nothing. They are logged `P2 flaw <id> not re-applied`. RC-13;
   - **pilot check** (`PilotSeatCheck`): `"log"` compares `ps.Pilot` with the pick; `"refresh"` also writes it and calls
     `VehicleAnimationComponent:SynchronousRefreshPilot()` (PS §6.6).
   No hook, no `FindAllOf`, no soft pointer, no UIManager query anywhere in this path.

---------------------------------------------------------------------------------------------------------------------

## 7. Persistence and config

### 7.1 Settings (`settings.txt`)

| Key | Format | Written / read |
|---|---|---|
| `LastRaceRacers` (new, default `""`) | `<ctrlId>=<pilotId>@<presetId>@<loadout code>;...`, e.g. `0=DA_Racer_DarkEnigma@PRE_Car_Beluga_Protagonist@v1,k:pilot,...;1=DA_Racer_Protege@PRE_Car_Orca_Protege@v1,...` | `R.persist` on SAVE / START; `deriveSetup` / `R.restore` (per ControllerId; class-checked; `K.validate`) |
| `LastRaceVehicles` (unchanged) | `<pnum>=<presetId>@<build path>;...` (parser setup.lua:1643 unchanged) | still written (base build path) for the classic flow |
| `LastRaceBuild` | the base build path in cards flow | builder.lua, unchanged |

settings.lua: ORDER += `LastRaceRacers`; COMMENTS `LastRaceRacers = "RACERS step per pad: <ControllerId>=<pilot>@<preset>@<loadout>;..."`.

### 7.2 Config keys (config.lua defaults; ENUMS / POSITIVE / FALSEABLE entries as noted)

| Key | Default | Values / meaning |
|---|---|---|
| `SetupPlayerFlow` | `"cards"` | ENUM `cards` / `classic` (the 0.10.0 columns, untouched code) |
| `PilotStage` / `PerkStage` | `true` / `true` | stage shown (off: its defaults are used) |
| `CardP1Input` | `"sink"` | ENUM `sink` / `geometric` (no explicit rules, plus-shape only) / (review) `ring` (Z5 wiring, no re-focus, §5.7.3) |
| `CardP1DirGuardMs` (review) | `50` | >= 0; a P1 sink direction coinciding with a guest's same direction within this many ms is dropped (0 = off, RC-10) |
| `CardGuestClickGuardMs` | `150` | >= 0 |
| `CardBackTapMaxMs` | `600` | POSITIVE; a guest B released after this is no "back" |
| `CardP1BackConfirmMs` | `3000` | POSITIVE |
| `CardRowW` / `CardH` / `CardPad` | `3500` / `1320` / `32` | POSITIVE (su) |
| `CardW` / `CardGap` | `{1720, 1720, 1140, 845}` / `{0, 60, 40, 40}` | tables (per player count) |
| `CardFrame` | `"darkpanel"` | ENUM `darkpanel` / `solid` |
| `CardPanelColour` | `{R = 0.012983, G = 0.036889, B = 0.048172, A = 0.90}` | table |
| `CardHighlight` | `"pill"` | ENUM `pill` (WBP_ButtonBacker) / `solid` |
| `CardDetail` | `"game"` | ENUM `game` (WBP_Character_Ability) / `plain` |
| `CardThumbMask` | `"mid"` | ENUM `mid` / `plain` |
| `CardDiamond` | `"disc"` | ENUM `disc` / `hud` (`MI_HUD_Abilities_BG`) |
| `CardBackdrop` | `true` | style art behind pilots |
| `CardGlyphs` | `"xbox"` | ENUM `xbox` / `text` |
| `CardSounds` | `"match"` | ENUM `match` / `accept` / `off` |
| `CardStartPulse` | `true` | |
| `CardBuildsPerTick` / `CardRendersPerTick` / `CardLoadsPerTick` | `1` / `2` / `3` | POSITIVE |
| `PilotUnique` / `PilotShareShade` | `true` / `false` | |
| `PilotP1Default` | `"shade"` | ENUM `shade` / `favourite` |
| `PilotExtras` | `{ "DA_Racer_Mentor" }` | FALSEABLE table |
| `PilotPodRivals` / `PilotPodAged` | `false` / `false` | |
| `PilotSeatCheck` | `"log"` | ENUM `log` / `refresh` / `off` |
| `PerkPartSlots` / `PerkTraitSlots` | `6` / `3` | POSITIVE; 1..10 / 1..4 (clamped) |
| `PerkFlaws` / `PerkUniqueFamily` | `true` / `true` | |
| `PerkApply` | `"full"` | ENUM `full` / `passives` (parts + traits as passives at PRERACE only) / `off` (classic build) |
| `PerkTraits` / `PerkSetRacerStyle` | `true` / `false` | |
| `PerkVerify` / `PerkLateFallback` | `true` / `true` | |
| `PerkRamjet` / `PerkCritMalfunctions` | `"keep"` / `"keep"` | ENUM `keep` / `on` / `off` |
| `PerkPodRamjet` (review) | `false` | pods get the ramjet (`RamjetInstalled = true`); off = the game's "Memory Pod [No Ramjet]", and ramjet items are hidden on pods (RC-2) |
| `PerkHideInert` (review) | `true` | hide items whose system (`needs`) is off on this class's car; false = show them dimmed with `NO RAMJET` / `NO CRITICAL MALFUNCTIONS` (RC-2) |
| `SetupPreviewStillBurst` (review) | `8` | POSITIVE; captures per still (RC-12) |
| `CardLoadBigBytes` (review) | `1048576` | POSITIVE; a texture of at least this size counts as "big": one per FAST tick (RC-9) |
| `SetupPreviewSpinStage` | `"vehicle"` | ENUM `vehicle` / `all` / `none` |
| `SetupPreviewCaptureBudget` | `1` | POSITIVE |
| `SetupPreviewSpawnGapMs` | `300` | POSITIVE |
| `SetupPreviewPrebuildMs` | `600` | >= 0 (0 = no prebuild on PILOT) |
| `SetupPreviewSpacing` | `20000` (was 5000) | POSITIVE |
| `SetupPreviewW` / `SetupPreviewH` | `960` / `540` (were 640 / 360) | POSITIVE |
| `SetupPreviewCaptureMs` | `66` (was 50) | >= 0 |
| `Defaults.LastRaceRacers` | `""` | §7.1 |

`GuestPilots`, `SetupPerPlayerBuild*`, `SetupCard*` and `SetupInRaceOverride*` keep their meaning in the classic flow.

---------------------------------------------------------------------------------------------------------------------

## 8. VERIFY, fallbacks, risks

### 8.1 VERIFY ids (V-RC; the research ids V-PIL-01..09, V-PRK-01..09, V-VP-01..10 stay valid)

| Id | Check (log line / screenshot) | Fallback |
|---|---|---|
| V-RC-01 | `racers: built (card shells n, widgets w, t ms)`; layouts of §3 for 1-4 players; no tofu | `SetupPlayerFlow = "classic"` |
| V-RC-02 | P1 d-pad: one `racers: P1 sink up/down/left/right` per press, focus back on the sink; held d-pad repeats | `CardP1Input = "geometric"`, then classic |
| V-RC-03 | P1 A,A,A fast = 3 accepts (noClaim); Enter = 1 accept; Backspace = back | lower dedup |
| V-RC-04 | guests drive only their card; B tap = back; B hold = leave without a back first; a joiner gets a PILOT card | raise `CardBackTapMaxMs` |
| V-RC-05 | P1 and P2 on the same stage: identical except texts and colour (side-by-side shot) | - |
| V-RC-06 | DarkPanel frame + shadow; pills tinted per player also after page re-show; `WBP_Character_Ability` title + rich text with keyword icons, readable on PANEL; `CardDiamond = "hud"` A/B shot | `CardFrame/Highlight = "solid"`, `CardDetail = "plain"`, keep "disc" |
| V-RC-07 | P2's A while P1 sits on the sink -> `P1 accept dropped`; P1's card does not move. (review) Also: P2's d-pad left/right/up/down x5 while P1 is idle on the sink -> P1's card never moves (no `P1 sink` line; a `P1 right dropped` line means the guard caught a leak: note it in task #14) | raise the guard |
| V-RC-08 | P1 back: strip left at PILOT twice -> MODE; after a race `pollP1Back` works and the hints switch to B | - |
| V-RC-09 | taken pilots skipped + tagged; follow rules; class gating (no pod alien in a car) | - |
| V-RC-10 | MODEL/LIVERY cycling; SIGNATURE chip; prebuild: `bay n ready` logged before the stage change to VEHICLE | `SetupPreviewPrebuildMs = 0` |
| V-RC-11 | PERKS: every slot reachable; L/R changes; A pickers; KIT A -> READY; POWER/ENERGY update | - |
| V-RC-12 | picker: categories wrap, paging, equip, cancel (B / top Up), tick, FLAWS, POD TRAITS only for pods | - |
| V-RC-13 | no duplicate family / part family / trait; swap toast | - |
| V-RC-14 | `P2 READY after 3 presses` with signature preset + style kit | - |
| V-RC-15 | 3P (M) and 4P (N): nothing clipped, long names shrink, row not scaled down unexpectedly | tune `CardW/H` |
| V-RC-16 | main's `FAST loop timing` with 4 cards idle and 4 pads moving; build ms per shell / panel | lower per-tick budgets |
| V-RC-17 | previews: only VEHICLE bays spin; `capturesPerSec` <= ~30; stills hold; spawn gap; a leaving pad's bay released, others kept; lighting unchanged when a bay appears (spacing). (review) The READY still has the same brightness and noise as the spinning VEHICLE view (a side-by-side shot after an 8-capture burst) | `SetupPreviewSpinStage = "none"`; raise `SetupPreviewStillBurst` |
| V-RC-18 | START gate: all READY -> start; one not ready -> warn, second START < 5 s -> start | - |
| V-RC-19 | base-build patch `4 -> 6 -> 4` in both launch branches, on FRONTEND and after a hot reload | `PerkApply = "passives"` |
| V-RC-20 | `pilots: P1=... P2=...; AI re-assigned n`; `race recipe` at PRERACE shows them (V-PIL-03) | picks ignored (classic pilots) |
| V-RC-21 | front-end read-back = plan for every human incl. P1 (V-PRK-01); PRERACE verify line `build ok, abilities 4/4, crash ok` (V-PRK-02, V-PRK-06) | `PerkApply = "passives"` |
| V-RC-22 | traits: PassiveList +3 per human; an effect visible (e.g. Afterburner Superiority) (V-PRK-05) | `PerkTraits = false` |
| V-RC-23 | race: each view's HUD shows its player's 4 ability icons; d-pad fires them; battery pips (V-PRK-03); seated pilot (V-PIL-04) and barks (V-PIL-05) | `PilotSeatCheck = "refresh"` |
| V-RC-24 | pods: pod pilots cropped; pod kits put the trait pair in parts 1-2; `ArchetypeToUseForPlane` logged; pod traits active (V-PRK-04) | - |
| V-RC-25 | SAVE + reopen: picks per pad restored; quit + relaunch: `LastRaceRacers` restored; lobby START RACE replays loadouts | - |
| V-RC-26 | a guest leaves between SAVE and START: picks follow the ControllerId (`re-mapped by ControllerId`) | - |
| V-RC-27 | AI PowerLevel at PRERACE equal in a cards race and a classic race (the base build touches humans only) | `PerkApply = "off"`; (review) better first: speeders launch on `VBD_PvP_IA_<P1 pilot>` instead of `VBD_000_1Mastiff`. Those builds have no abilities, no affixes, 4/10 affix slots and PL 26-31 (PL §2.5), so the humans' writes are unchanged and the launch build's power matches the kits (RC-14) |
| V-RC-28 | fallbacks: `SetupPlayerFlow = "classic"`, `CardDetail = "plain"`, `CardFrame = "solid"`, `CardHighlight = "solid"` render correctly | - |
| V-RC-29 | Ctrl+F11 during the step and during LAUNCHING: no orphan bays, patch restored | - |
| V-RC-30 | guests hear navigation ticks, P1's sink one tick per press; accept sounds for all; rumble on the right pad. (review) With `CardP1Input = "sink"` expect **two** ticks per P1 press (the BP plays `MainNavigation` on the return to centre too) and one accept (BP only, none from racers.lua); `ring` mode should give one tick. A stray mouse click on the sink area does nothing | `CardSounds = "accept"`; `CardP1Input = "ring"` |
| V-RC-32 (review) | Pods: `PA.systems(1)` logs `ramjet false, critmalf false` with `PerkPodRamjet = false`; the pod board offers no RAMJET category and no ramjet/critmalf-only part or trait; the RAMJET upgrade row says `COUNTS FOR POWER ONLY`; ODY MANDRELL's default kit is the Drafting-based pod kit. With `PerkPodRamjet = true`: R3 switches to ramjet in a pod race | `PerkHideInert = false` (shown dimmed) |
| V-RC-33 (review) | ABILITY rows and picker: the detail tag shows `COST n` while the log has **no** `LoadAsset(.../BP_Ability_...)` line before the launch; the costs equal `GetEnergyCost()` read on the race-world ability actors (debug dump at PRERACE) | drop COST from the tag |
| V-RC-34 (review) | 3 players (M) and 4 (N): the "2 lines" texts (style names, trait rows, chips, the N info line) wrap onto two lines at their box width, and the W style description wraps onto 2 lines; no single shrunken line | raise `WrapTextAt` / shorten the texts |
| V-RC-35 (review) | A dormant 3rd pad, P1 on READY: first START RACE on the card -> the card stays, status `PAD 3 IS NOT JOINED: START AGAIN FOR AN AI CAR`; a second START within 5 s launches | - |
| V-RC-31 | after a split race (menu owned by the last local PC, MO) P1's pad still drives P1's card; log the page owner at `R.enter` | depends on the `feowner` fix (task #18); keyboard + mouse meanwhile |

### 8.2 Failure fallbacks

| Failure | Behaviour |
|---|---|
| `R.build` fails | this page uses the classic columns (logged once) |
| a card / stage panel errors while building | that card shows a solid panel with `RACER CARD ERROR` and the classic text rows; logged once |
| a game widget class missing / throws | its fallback for every card (§3.8) |
| texture missing | backer / family glyph / thumb; logged once per path |
| sink gives no event after 5 P1 presses seen as leaks | log `racers: P1 sink inactive`; P1 keeps keyboard + footer; next open uses `CardP1Input = "geometric"` |
| 3D off / broken | class art + badge (classic 2D card) |
| `PA.prepareLaunch` fails | `choice.build` is used; loadouts still written (affix slots = the build's count) |
| `applyAll` fails for one player | that player races what was written (base build otherwise); others unaffected; status `P2 LOADOUT NOT APPLIED` |
| state lost in travel | late passives for parts and traits; abilities / levels reported lost |
| pilot write refused | that human keeps the game's pilot (SHADE); logged |
| `LastRaceRacers` does not decode | pilot defaults + style kit; logged once |

### 8.3 Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | explicit Up/Down sink rules do not hold | plus-shape geometric placement; `geometric` mode; V-RC-02 |
| R2 | a guest's A clicks P1's sink (task #14) | one-tick hold + 150 ms window; START needs P1's own START row |
| R3 | P1 focus lost (mouse, modal, re-activation) | keeper always on in Gamepad mode; footer for the mouse; leak counter |
| R4 | `KeyboardIsP1`: pad 1 is guest 1 and Slate user 0 | sink events ignored in Gamepad mode; guard drops its A clicks |
| R5 | post-race menu owned by a guest (MO, task #18) | page and sink are built for `menu:GetOwningPlayer()` as today; depends on `feowner`; V-RC-31 after session H |
| R6 | element writes into `VehicleBuilds[idx]` do not reach live memory (V-PRK-01 never seen live) | read-back + PRERACE verify; `PerkApply = "passives"` |
| R7 | the build does not survive the seamless travel | verify + late passives (parts, traits); report |
| R8 | traits via `Server_ApplyPassive` do nothing | count check; `PerkTraits = false` |
| R9 | balance vs AI (PL 31, 4 abilities, 4 legendary parts) | TIER kits for parity; V-RC-27; first races decide the default kit |
| R10 | widget count / hitches | lazy shells and panels, per-tick budgets, texture queue |
| R11 | readability at 4P (845 su = 282 px at 720p) | sizes chosen for 4K; ScaleBoxes; 720p tests check layout only |
| R12 | Slate rebuild resets BP-applied colours | caches cleared on page show and class change |
| R13 | shared asset patch (base build) left patched | restore right after the call, on refusal, FRONTEND, hot reload (persisted record) |
| R14 | soft pointers | static paths only; `WBP_Character_Ability` vars, never `SetAbility`/`SetTrait` |
| R15 | concurrent edits of `setup.lua` / `config.lua` | anchor by function name; setup changes are delegations |

---------------------------------------------------------------------------------------------------------------------

## 9. Work items (disjoint files; run in parallel where dependencies allow)

| Id | Files | Task | Depends on |
|---|---|---|---|
| W01 | `tools/gen-perkdata.py`, `work/decoded/perks/*.json` (copied), `Scripts/perkdata.lua` (generated), `work/decoded/perks/perkdata.summary.txt` | copy the extracts, port FG's generator, add the §4.4 kits and the §5.3 tables, generate, self-check, `luac5.4 -p` | - |
| W02 | `Scripts/pilots.lua` | §4.1 table + §5.2 API | - |
| W03 | `Scripts/perks.lua`, `work/tests/perks_test.lua` | §4.5 + §5.4 pure logic + offline Lua 5.4 tests | W01 (table shapes of §5.3) |
| W04 | `Scripts/perkapply.lua` | §5.5 + §6 (patch, pilots, writes, read-back, race tick, hot reload) | W02, W03 |
| W05 | `Scripts/cards.lua` | §3 + §5.6 (widgets, class layout tables, render, texture queue) | - (vm contract §5.6) |
| W06 | `Scripts/racers.lua` | §2 + §5.7 (state machine, adapters, vm builder, previews, persistence glue, test helpers) | W02, W03, W05, W07, W08, W09 |
| W07 | `Scripts/vpreview.lua` | §5.8 | - |
| W08 | `Scripts/ui.lua` | §5.11 `opts.noClaim` | - |
| W09 | `Scripts/vehicles.lua` | §4.2 `models`, `podName` | - |
| W10 | `Scripts/setup.lua` | §5.9 | W06 (API), W04 (`launchBase`) |
| W11 | `Scripts/launch.lua` | §5.10 | W02, W04 |
| W12 | `Scripts/config.lua`, `Scripts/settings.lua`, `Scripts/main.lua`, `Scripts/diag.lua`, `Scripts/consts.lua` | §7 keys + Defaults + ENUMS/POSITIVE/FALSEABLE, ORDER/COMMENTS, MODULES/PERSIST_MODULES, diag section, version | - |
| W13 | `notes/ARCHITECTURE.md`, `mod/SWGRCouch/README.md` | revision 0.11.0 (binding summary of this spec), §3.3 user text, §7 key table, §9 "0.11.0 checks" (V-RC ids, §10 sessions) | W01-W12 |
| W14 | (no source file) | integration: every Scripts file `luac5.4 -p`; grep for soft-pointer reads (`.Icon`, `.LargeIcon`, `.Traits`, `StandardAbilities`, `LargePreviewImage`, `MainIcon`) in the new modules: none; install to the test copy | W01-W12 |
| W15 | `state/runs/<date>-racers-v2-*` (screenshots, logs) | live sessions of §10 | W14 |

(review) Review corrections by work item (details in "Review corrections"):
- W01: emit `ABILITIES[].cfg`, the `needs` tags with the curated list and its summary printout, `STYLES[].icon/.bg`
  as real paths; Pod_Pepper is based on Drafting.
- W03: `K.validate` / cycling / pickers honour `needs` against `PA.systems(arch)`; the NEEDS-trait link is renamed
  `requires`.
- W04: `PA.systems`, `PA.abilityCost` from the config CDO, `PerkPodRamjet`, no flaws in the late fallback, the
  `VBD_PvP_IA_*` base as the V-RC-27 fallback.
- W05: own detail icon, `WrapTextAt` for multi-line texts, roster/strip arrow fits, size-aware texture queue, name
  check on cache hits.
- W06: direction guard, mouse-click filter, sound rules, the KeyboardIsP1 pad-1 guest's B, `ring` input mode.
- W07: still bursts.
- W10: dormant gate before `finish` closes the page.
- W11: `launch.start({acceptDormant})`.
- W12: the new config keys.
- W15: sessions I2 and K2 plus the vpad rule.

---------------------------------------------------------------------------------------------------------------------

## 10. Live test plan (1280 x 720, test.cmd-driven, screenshots kept)

**Setup** (the user's machine is shared: low resolution, game audio muted by the harness; never `-nosound`, never `rm`):
```sh
G=~/Games/project/galactic-racer; T=$G/tools/gr-session.sh
$T newrun racers-v2-A
# test copy config_user.lua: TestCommands = true, SetupPreviewW = 640, SetupPreviewH = 360 (layout sessions also
#   SetupPreviewSpinDps = 0); 4 virtual pads BEFORE launch (guests are created for connected pads only):
$T vpads; for k in 3 4; do setsid python3 $G/tools/vpad.py serve $G/state/vpad$k.fifo > $G/state/vpad$k.log 2>&1 < /dev/null & done
# (review) every created pad becomes a guest, and a guest that has not joined is DORMANT: launch.start refuses the
#   first START (launch.lua:733-744). Sessions that START (H, I, J) either join every created pad (press A on vpad3/4)
#   or test V-RC-35 on purpose (two STARTs). Simplest: create vpads 3-4 only for the run that does sessions F/G (RC-1).
SWGR_SMALL=1 SWGR_W=1280 SWGR_H=720 $T launch     # headless gamescope does not boot the hotfix build (gr-session.sh, 2026-10-09);
                                                 # use SWGR_HEADLESS=1 instead once a later note says it boots
$T pads; $T join2
VPAD_FIFO=$G/state/vpad3.fifo python3 $G/tools/vpad.py send "press A 200"     # P3 (P4: vpad4) when needed
$T cmd 'lua return require("setup").debugJump{class = "Car", planet = "Mastiff", step = "vehicles"}'
#   class keys are vehicles.CLASSES keys: "Car", "Bike", "Skimmer", "Plane"; planet keys setup.PLANETS ("Mastiff" = JAKKU,
#   "Beagle" = TATOOINE); mode keys "race" (default), "fullgrid", "mixed", "eliminator"
```
Drive cards with real pads (`VPAD_FIFO=$G/state/vpad2.fifo python3 $G/tools/vpad.py send "dpad right 120"`,
`"press A 150"`, `"press B 150"`, hold: `"press B 1200"`) or events
(`$T cmd 'lua return require("racers").event(2, "right")'`); inspect with
`$T cmd 'lua return require("racers").status()'` / `require("racers").dump(2)`; logs with `$T log 'racers|perkapply|vpreview'`.
At 720p 1 px = 3 su: layout, colours and highlights are checkable, small text is not. One optional 1920x1080 run
(`SWGR_W=1920 SWGR_H=1080`) for the final look, only if the user agrees.

**Sessions**

| Session | Steps | Evidence |
|---|---|---|
| A layout + identity (2P) | debugJump; both on PILOT; P2 `dpad right` x2; P1 vpad1 `dpad down/up/left/right` | `rc-01-2p-pilot`; V-RC-01/04/05/09; `P1 sink` lines (V-RC-02) |
| B P1 input + guard (2P) | P1 A,A,A fast; Enter; Backspace; P2 `press A` while P1 sits on the sink; P1 strip-left twice at PILOT | V-RC-03/07/08 log lines |
| C stages (2P) | P1 to VEHICLE (wait for the render), P2 to PERKS (cursor on PART 1) | `rc-02-2p-vehicle-perks`; V-RC-10/11 |
| D pickers + READY (2P) | P1 PERKS: open PARTS picker, page, change category, equip; ABILITY picker swap; TRAIT picker; P2 READY | `rc-03-2p-picker-ready`; V-RC-12/13 |
| E 1 player | P1 alone (P2 holds B 1.2 s): PERKS with the detail panel and large art | `rc-04-1p-perks`; V-RC-04 (leave) / V-RC-06 |
| F 3 and 4 players | P3 joins: P1 VEHICLE, P2 picker, P3 READY; P4 joins: one card per stage; then all READY | `rc-05-3p-mixed`, `rc-06-4p-mixed`, `rc-07-4p-all-ready`; V-RC-15/16/17/18 (`require("vpreview").stats()` before/after 30 s) |
| G taken pilot + quick path | P2 holds ARY; P1 cycles past it; fresh cards A,A,A | `rc-08-taken-pilot`; V-RC-09/14 |
| H launch + race (2P car) | START from P1's READY; PRERACE; fire `dpad up` on each pad; third-person view. (review) No dormant pad in this run, or two STARTs (V-RC-35) | logs V-RC-19/20/21/22/27; `rc-10-race-hud`, `rc-11-race-seated`; V-RC-23; (review) V-RC-33 (no `BP_Ability_` LoadAsset before the launch line) |
| I2 (review) pods + systems | `debugJump{class = "Plane", planet = "Beagle"}`: ODY MANDRELL's kit, RAMJET category absent, upgrade row tag; `PerkPodRamjet = true` in a second launch | `rc-13-pods-perks`; V-RC-32 |
| K2 (review) text + sounds | 3P and 4P on PILOT and PERKS (wrapped texts); P1 d-pad x5 with sound on (count ticks), mouse click on the sink area; P2 d-pad while P1 idles | `rc-14-3p-wrap`, `rc-15-4p-wrap`; V-RC-34, V-RC-30, V-RC-07 |
| I pods | `debugJump{class = "Plane", planet = "Beagle"}`: GASGANO + TEEMTO; race | `rc-09-pods-pilot`; V-RC-24 |
| J persistence | SAVE, reopen; quit + relaunch; lobby START RACE; a guest leaves between SAVE and START | V-RC-25/26 |
| K fallbacks + reload | `SetupPlayerFlow = "classic"` (regression shot), `CardDetail = "plain"`, `CardDiamond = "hud"` A/B; Ctrl+F11 in the step | `rc-12-classic-fallback`; V-RC-28/29; V-RC-06 A/B decides `CardDiamond` |

**Screenshots that prove the look** (named exactly, `$T shot <name>`):

| Shot | Pass criteria |
|---|---|
| `rc-01-2p-pilot` | two W cards side by side, identical structure; full bodies on style art; roster tiles; P1 SHADE, P2 ARY QUILL |
| `rc-02-2p-vehicle-perks` | P1 3D render + SIGNATURE chip; P2 board: diamond, 4 + 2 part tiles, 6 bars, style + 3 traits, detail card |
| `rc-03-2p-picker-ready` | picker with category row, ticks, pips; P2 READY stamp in red + loadout strip |
| `rc-04-1p-perks` | one centred W card, large art right of the detail card |
| `rc-05-3p-mixed` | three M cards, nothing clipped |
| `rc-06-4p-mixed` | four N cards, one per stage, readable structure |
| `rc-07-4p-all-ready` | four READY cards, P1's START row lit, status `ALL READY · P1: A TO START` |
| `rc-08-taken-pilot` | the taken pilot dimmed with a red `P2` tag in P1's roster |
| `rc-09-pods-pilot` | pod pilots cropped to fill the figure window; pod kit names |
| `rc-10-race-hud` | each view's ability cluster shows that player's icons |
| `rc-11-race-seated` | the chosen pilot seated in a car (third person) |
| `rc-12-classic-fallback` | the 0.10.0 columns unchanged |

Hand `rc-01`, `rc-02`, `rc-06` and `rc-10` to the user as "the new UI" screenshots.

---------------------------------------------------------------------------------------------------------------------

## Review corrections

*2026-10-09, adversarial feasibility review. Static only: nothing was launched and no mod file was edited. Every
claim was checked against the research notes and against the sources themselves:*
- *the current mod code: setup.lua, ui.lua, lobby.lua, join.lua, launch.lua, vpreview.lua, cmap.lua, util.lua,
  settings.lua, main.lua, vehicles.lua, config.lua;*
- *the old-build JMAP (`scripts/decode/jmapq.py`) and the asset list (`notes/asset-list.txt`);*
- *decoded BP bytecode and widget trees in `~/.claude/jobs/5fb7892b/tmp/` (`vehicle-step-code-map/`,
  `pilot-select/`, `perks-loadout/`);*
- *the UE4SS 3f4037d2 source;*
- *`objdump` of the old exe;*
- *the saved live logs.*

*Edits in the sections above are marked "(review)" and point here by RC id.*

**Verdict.** Feasible as specified, with no blocker. Three majors needed spec changes (RC-2, RC-3, RC-4) and twelve
minors were corrected (RC-1, RC-5 to RC-15). All of them are now written into the affected sections.

### Verified (no change needed)

| Area | Evidence |
|---|---|
| Game widgets are creatable and feedable from Lua | **`WBP_DarkPanel`**: PreConstruct sets the shadow/tight/gradient visibility and `Img_PanelBacker` = `MainPanelColor`. `NS_Content` has 64-su padding. `WBP_Pvp_BaseCharacterSelect` sets exactly `MainPanelColor #1E363E @0.9, ShowTightPanel false`, which is what §3.2 does. **`WBP_ButtonBacker`**: PreConstruct writes `B_Color` content colour = `ContentColor`; `IsOutline` picks `MI_UI_Pill_GenericOutline` or `MI_UI_Tab`. **`WBP_Character_Ability.Refresh()`**: a BP function that reads only `Icon`, `ItemName`, `ItemDescription`; `SetAbility`/`SetTrait` call `LoadAsset_Blocking` (@898/@1192). **Sink (`WBP_Common_Btn`)**: its `Anim_Hover`/`Anim_Select` tracks bind child widgets, never the root, so render opacity 0 on the button holds. |
| Every named asset exists | All §3.8 commons, the 6 Xbox glyphs, `MI_HUD_Abilities_BG`, `DT_UI_Audio_ForceFeedback`, `Font_Display`/`Font_Body`. `M_UI_CharacterProfilePicture` exists and its parameter is named `Texture`. All 21 pilot thumbs and full bodies. The family glyphs: Shield, Surge, Vent, Autopilot, IonBolt, Mines, Shockwave, StatusScrubber, IonBlast. 7 + 6 BuildStats icons, 66 `VU_*`, both base builds. All 21 kit rows of §4.4 resolve to existing `BP_Ability_*` / `AFX_*` / `TRT_*` assets (script check). Exceptions: RC-8. |
| Typefaces | The game's own widgets use Font_Body "Semibold", "Medium Italic" (108 uses) and Font_Display "Bold". |
| UMG / enums (JMAP) | `ScaleBox:SetStretch/SetStretchDirection`, `Widget:SetClipping/SetRenderOpacity/SetRenderTransformAngle/SetNavigationRuleExplicit`, `CanvasPanelSlot:SetAutoSize/SetPosition/SetSize/SetZOrder`; all `Fuse*` classes; EUINavigation Left 0 / Right 1 / Up 2 / Down 3. |
| Launch writes | Every field name and type in §6 matches the JMAP: `VehicleBuildState`, `VehicleUpgrade`, `VehicleAffix`, `RacerBuildState`, `VehicleBuildDef.UnlockedAffixSlots/MaximumAffixSlots`, `VehicleUpgradeDef` fields, `AffixPassiveConfig.FaultyRules`, `RecipeRacerSetup.Player/Pilot`, `GfnPlayerState.Pilot/RacerStyle/RacerBuildState/AbilityComponent/PassiveManagerComponent/Server_ApplyPassive`, `PlayerAbilityComponent.AbilitySlots/CrashAbilitySlot`, `PassiveManagerComponent.PassiveList`. UE4SS returns struct properties and TArray struct elements as live `UScriptStruct` userdata, and `arr[i] = v` is an element write (ue4ss-api.md §8). |
| Timing | `applyRecipe` runs in the same call as `LaunchCustomRace` (launch.lua:808-830). `launch.raceTick` runs in every race phase (main.lua:245-247), so `PA.raceTick` at PRERACE/RACING works. |
| No hidden travel carrier | LaunchCustomRace's "third pass" call `0x1470e321a` (at `0x142f910e6`) reads the ability slots, counts the maxed upgrade parts, and calls `0x140596848` with small ids: an achievement/stat check, not a copy of the build. |
| D-pad to slot | `IMC_Vehicle_Default`: Up = Slot1, Left = Slot2, Down = Slot3, Right = Slot4. `WBP_Hud_Ability_List1` is the same diamond (grid: 1 top, 2 left, 3 bottom, 4 right; the centre is empty, so the crash disc is our extension). |
| Input plumbing | `ui.pollClicks` runs `lobby.pollNav -> setup.pollNav` before its click loop. The FAST order is `keyq.drain -> join.poll -> ui.pollClicks`. keyq passes up/down/left/right/accept/back2 to `setup.onKey` on the game thread. `lobby.keepFocus` skips the setup keeper while the lobby is covered, so it never steals focus from "Exit Game?". join.lua's hold-B rule follows `guestBHoldsToLeave()`. |
| Anchors and data | setup.lua 1994 lines; every function anchor of §5.9 matches. Model counts Car 13 / Bike 12 / Skimmer 12 / Plane 8. The §0.3 #7 light math, re-computed from `vpreview.frame`: 11.9k uu at spacing 15000, 16.8k uu at 20000, radius 12.3k. The layout tables add up (3500; inner widths; 16:9 render boxes; nothing past 990), except RC-15. vpad/gr-session syntax checks out. `config.lua` loads in plain Lua 5.4, so the offline perks test is feasible. The FG generator sample passes `luac5.4 -p`. |
| User request | Pilot, then vehicle, then every perk, all unlocked, identical cards for P1 and guests, screenshots: all covered. The only "benefits" not on the board are the ramjet / critical-malfunction systems, which are config. RC-2 makes the board consistent with them. |

### Problems and fixes

| RC | Sev. | Problem | Evidence | Fix (edited in) |
|---|---|---|---|---|
| RC-2 | major | **Inert perks on pods.** The pod launch base `VBD_000_1Mastiff_Plane` has no ramjet and no critical malfunctions, and `PerkRamjet` writes speeders only. Yet the pod board offers the RAMJET part category (17 tiles), ramjet- and critmalf-only parts and traits, and a RAMJET upgrade row. ODY MANDRELL's default kit (Pod_Pepper) is built on the Ramjet kit: 2 ramjet parts and 3 ramjet traits, all inert. | Decoded `vbds.json`: `ramjet false, critMalf false`. The game's own label in vehicles.lua STATIC_BUILDS is "Memory Pod [No Ramjet]". `VBD_MP_*` builds are also False/False. `VBD_000_1Mastiff_Plane_Ramjet` leaves ramjet at the class default. | Generator `needs` tags: curated, seeded by a keyword scan. `PA.systems(arch)` reads the base flags. Inert items are hidden (`PerkHideInert`). The RAMJET row stays, tagged "counts for POWER only". Pod_Pepper is based on Drafting. Slots emptied in a kit are refilled from the AFTERBURNER kit; SHADE, P1's default, has a ramjet-heavy kit in pods too. `PerkPodRamjet` is an opt-in. V-RC-32, session I2. (§4.3, §4.4, §5.3, §5.5, §6, §7.2) |
| RC-3 | major | **Multi-line text inside the universal SizeBox > ScaleBox > TextBlock rule never wraps.** A ScaleBox lays its child out at the unconstrained size, so "2 lines" texts become one shrunken line: the W style description, the M/N style names and trait rows, the M/N chips, the N info line, the M tag lines. | Standard UMG behaviour. The game's `WBP_Character_Ability` puts `RT_Desc` in a ScaleBox with a fixed `WrapTextAt` 700 for this reason. `UTextLayoutWidget` has `WrapTextAt` as a property only (JMAP: no setter). | Every multi-line text gets `WrapTextAt` = box width, written before the widget is added. The ScaleBox stays as an overflow guard. V-RC-34, session K2. (§3.2) |
| RC-4 | major | **`PA.abilityCost` loads ability actor BPs in the front end.** `GetEnergyCost()` on an ability CDO needs `LoadAsset(BP_Ability_*)`, with its VFX/SFX dependencies, synchronously on a cursor move, for up to 45 classes. That means hitches for all four players. | `EnergyCost` is `GfnAbilityConfig` +0x38. The configs are native classes (`/Script/Griffin.Ability*Config`). No `DA_AbilityConfig_*` stores `EnergyCost` except the four crash configs (= 0). So the cost is the native CDO default of the config class, which is resident. `abilities.json` already has `cfgType`. | `ABILITIES[].cfg`; `PA.abilityCost` reads `U.cdo("/Script/Griffin.Default__"..cfg).EnergyCost`; no ability class is loaded before the launch. V-RC-33. (§5.3, §5.5, §5.12) |
| RC-1 | minor | **START from the card with a dormant pad.** `setup.finish` closes the page, then `launch.start` refuses the first START ("PRESS A ON IT, OR START AGAIN"), so the players land in the lobby. The §10 runs create 4 vpads but join 2, so session H's START would be refused. | launch.lua:733-744; setup.lua:1725-1750 | The dormant gate runs before the page closes; `launch.start({acceptDormant = true})`; vpad rule in §10. V-RC-35. (§2.6, §10) |
| RC-5 | minor | **The game's ability card has no icon.** `Img_Icon` sits in `O_HACK-HIDE` (Hidden at design time), and `Refresh()` collapses `SzB_IconSize` when the card is unlocked. The reference mocks show an icon there, and M/N have no large art, so they would show no icon at all. | Decoded `WBP_Character_Ability.json` + kismet @332-446 | Our own icon image left of the card in every class; drop the `Icon` write. (§3.5, §3.8) |
| RC-6 | minor | **Sink sounds and stray clicks.** The BP plays `MainNavigation` on every focus received, including our return to the centre (two ticks per press), and `MainAccept` on every click; racers.lua would add a second accept. The sink buttons are Visible, so a mouse click on the invisible area accepts for P1. | `common_btn.kismet.txt` @867-1024 and @807/@10 | No racers accept sound for sink-sourced accepts; mouse-click filter; V-RC-30 expects 2 ticks; optional `ring` mode with one tick. (§2.9, §5.7.3) |
| RC-7 | minor | **Texture cache identity.** `U.ok` is address-based: UE4SS `IsValid` = pointer in GUObjectArray and not unreachable. A collected texture whose address a new object reuses passes it, and a wrong object goes into `SetBrushFromTexture`. | UE4SS LuaUObject.hpp:761-764; util.lua `U.obj` cache | Name check on cache hits. (§5.6) |
| RC-8 | minor | **Style art cannot be derived from the style key.** There is no `T_UI_RacerStyle_BattlingFlameVent_*` and no `Slipstreaming_Bg`; the PvP styles mostly lack `Background`. | Asset list: 15 `_Icn`, 14 `_Bg`; pilot-select §2.3 | `STYLES[].icon/.bg` as real paths from the generator. (§3.3, §3.8, §5.3) |
| RC-9 | minor | **The texture budget counts textures, not bytes.** 3 loads per tick can be three 4.1 MB `_Bg` or 2.7 MB full bodies (NeverStream, no mips): synchronous multi-MB loads per tick. | Decoded texture JSON: 3840x2160 DXT1 / 1480x1800 DXT5, NeverStream | One big (>= 1 MB) load per tick; roster prefetch on PILOT entry; `CardLoadBigBytes`. (§5.6, §5.12) |
| RC-10 | minor | **The attribution guard covers A only.** task #14's mechanism is unknown (`bFilterInputByPlatformUser=False`); if guest d-pads ever reach P1's CommonUI, P1's card would move with them. | The session-B log shows no leak (no P1 cycler step while the guest navigated for about 1.5 min) | A 50 ms same-direction guard, logged; V-RC-07 extended; `CardP1DirGuardMs`. (§5.7.3) |
| RC-11 | minor | **KeyboardIsP1: the pad-1 guest's B is also P1's CommonUI Back,** so a B tap on that guest's card opens "Exit Game?". | join.lua:284-292 | That card ignores B and goes back through the strip. (§5.7.3) |
| RC-12 | minor | **Stills do not converge.** Three captures cannot settle Lumen GI/reflections, TSR and auto exposure, which accumulate per capture, so the READY still would look noisier or darker than the spin. | vpreview `bAlwaysPersistRenderingState`; vehicle-preview.md §1.3 | Stills are an 8-capture burst; V-RC-17 compares the looks. (§5.8, §5.12) |
| RC-13 | minor | **The late fallback re-applies flaws as plain passives.** Without `FVehicleAffix.Status = 2` the FaultyRules never run. | PL §1.2 (`Status` drives the Faulty path) | Skip flaws in the late fallback and log them. (§6) |
| RC-14 | minor | **The launch base is PL 0.** If the AI scale with the launch build, `VBD_000_1Mastiff` makes them weaker than with today's tier builds; the only fallback was `PerkApply = "off"`. | PL §2.5: `VBD_PvP_IA_*` have no abilities, no affixes, 4/10 slots, PL 26-31 | Fallback before "off": speeders launch on `VBD_PvP_IA_<P1 pilot>`. (V-RC-27) |
| RC-15 | minor | **Layout fits.** M roster 7 tiles + 52-su arrows = 1128 > 1076; N = 790 > 781. The strip has no room for end arrows. The DownOnly ScaleBox in the fixed 3500 x 1320 SizeBox cannot shrink against the page (the page is a VerticalBox with auto slots). | Arithmetic on §3.2/§3.3; lobby.lua `pageRoot` | M 6 tiles, arrows 40 in M/N, strip arrows inside the current tab, `CardH` stays the overflow remedy. (§3.1, §3.2, §3.3) |
