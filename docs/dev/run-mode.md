# GALAXY RUN — a rogue-style career for 1–4 couch players (SWGRCouch 0.13 design)

Jules 2026-10-11: "Think about creating a career mode for 2 to 4 players. Rogue multiplayer would be awesome."

## Hard rules
- Mod-owned: the run lives in `Mods/SWGRCouch/run.txt` only. It never opens, continues or abandons the game's
  CAMPAIGN / tour and never writes the game's save (GriffinRun / GriffinSave are Jules's campaign).
- Built only on what FREE MODE already does: launch a custom race with per-player builds, read the result, come back
  to the FREE MODE tab. No new game screens.

## The loop (one run ≈ 6 races, ~30–40 min)
1. **New run** (FREE MODE tab): P1 picks the class (speeder / podracer / …) and the run length (SHORT 4 / STANDARD 6 /
   LONG 9). Every joined player is in the run. The run starts everyone on a **starter build** (the pilot's own
   vehicle, its kit's abilities only, every upgrade level 0, no traits) — the rogue part is growing it.
2. **Race**: the run picks the next event: planet → track → condition → mode, never the same track twice, AI tier
   rising with the race number (TIER 1 → 6). Sector modifiers make some events special (night/storm condition,
   eliminator, full grid, reverse variant).
3. **Result**: each human's place among all racers (DNF = wrecked). Points 25/18/15/12/10/8/6/4/2/1.
4. **Team goal (the "rogue" stake)**: the team shares **3 hull points**. Each race has a target (race 1–2: a human in
   the top 5; middle: top 3; final: 1st). Missing it costs a hull point. 0 hull = **RUN LOST** (the board shows how
   far the team got). Winning the final = **RUN WON**.
5. **Draft** (between races, on each player's racer card): 3 random reward cards per player; the player in last
   place among the humans gets 4 cards and picks first. Rewards come from the game's own perk data:
   +2 upgrade levels on a part slot, a new ability, a crash ability, a trait, a racer style, boost type, or
   "REPAIR: +1 team hull" (rare). Picks are kept for the whole run.
6. Back to 2. After the last race: final standings (points, MVP) and the run is archived in `run-history.txt`.

## Couch rules
- Players can join a run between races (they start on the starter build + one free pick).
- A player who leaves keeps their record; the run continues.
- Quit the game mid-run: the run is resumed from `run.txt` the next time (CONTINUE RUN on the FREE MODE tab).

## Integration points (to fill from the code map)
- launch: …
- results: …
- tab return / board: …
- racer cards draft step: …
