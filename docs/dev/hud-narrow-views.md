# Race HUD in narrow views (2P side by side, 3P bottom, 4P): a readable top bar (static research)

Date: 2026-10-10 (research-hud, for 0.11.0-dev). Nothing was run in the game and no game install was touched.
User request: "HUD is bad on screen where width is 1/2, fix that."

Sources:
- CUE4Parse JSON of the HUD blueprints:
  - `work/decoded-bp/Griffin/Content/Griffin/UI/Screens/WBP_Hud_Race.json` and `WBP_Hud_Memory.json`.
  - `work/decoded-script/Griffin/Content/Griffin/UI/Widgets/HUD/*.json` (RaceInfo, BotEngineInfo, PositionMap,
    Afterburner, RamjetBar, Ability_List1, EnergySystem, CharacterHolo, Message, ...).
  - Trees were printed with slot data by a throw-away walker (scratch `tree.py`). The values needed are copied below.
- Reflection: `work/usmap/Griffin-5.7.4-381121.schema.json` (struct and enum layouts) and
  `work/runtime/*.jmap` (UFunction signatures).
- Screenshots:
  - 2P side by side: `state/runs/20261010-0512-hud-before/hud-2p-side-by-side*.png`.
  - 4P: `state/runs/20261010-0238-racers-v2b/rc-10-race-hud.png` and
    `state/runs/20261010-0213-racers-v2/rc-10-race-hud-022755.png`.
  - 3P, P1 full width over two quarters: `state/runs/20261007-2239-session-L3P/l3p-hudfit.png` and
    `state/runs/20261007-2309-session-M/m-race-hudfit.png`.

Tags: [V] read from the files, [M] measured on a screenshot, [L] likely, [S] needs a live test.
Units: UI design units. The game is designed for 3840 x 2160 at DPI scale 1. In a 1280 x 720 window, 1 unit is
0.333 px.

## 0. Summary

| | Now (0.8.2 `fitInterior`, still in 0.10.0) | Proposed (0.11.0) |
|---|---|---|
| What is scaled | `SzB_InteriorScale` (ScaleToFit) shrinks **the whole HUD interior**: top bar, centre messages, countdown **and the bottom engine row** (§1, §3) | the same scale box, but scaled by the view **width** alone (ScaleToFitX), with a **narrower interior** (`SzB_InteriorSize.WidthOverride` 3620 -> about 2000) |
| 16:9 narrow view (1920 wide) | everything at **0.53** | top bar, centre and countdown at **0.96** (layout scale: crisp text). The engine row is at **0.76**: it is wider than half a screen, so it is render-scaled down |
| Top bar | designer bar shrunk to 0.53 | **compact bar**: timer and LAP / POS moved 197 units inward, brackets and shadow 394 units shorter, P1's 1D map at 0.6. Same shape, shorter flat middle |
| Bottom row | complete at 0.53 | complete at 0.76, with the radio portrait hidden in narrow views (it alone is 350 + 32 units wide) |
| Full-width views (2P top / bottom, P1 in 3P) | designer | designer (unchanged) |

The two hard facts behind the design:
1. **Text must stay at layout scale.** Slate rasterises glyphs at the accumulated *layout* scale (scale boxes, DPI).
   A widget `RenderTransform` only stretches the glyph quads, so render-scaling text up makes it blurry. The proposal
   therefore raises the scale box's layout scale and render-scales only the engine row, and only **down**.
2. **The view size cannot be read** from Lua in this build. `ULocalPlayer.Origin/Size` are not UPROPERTYs. `FGeometry`
   has no reflected members, so `GetCachedGeometry` comes back as an empty table. The view is computed from the split
   layout and the viewport size / DPI (§6). The layout is built so that an error in that estimate changes the
   achieved scale but never cuts anything.

## 1. What the screenshots show [M]

- **2P side by side**, 1280 x 720: each view is 640 x 720 px, which is 1920 x 2160 units.
  - The top bar spans x = 130..510 px of 640. That is a half width of 190 px = 1075 units at 0.53 x 0.333 px/unit,
    which matches the timer's left edge at -1077 (§2.2).
  - The bottom-left cluster (energy pips, ability diamond, speed, boost bar) spans 3..238 px, i.e. **1328 units at
    0.53**. In the full-width P1 view of `l3p-hudfit.png` (960 x 540 window, 0.25 px/unit, scale 1) it spans
    32..365 px = **1332 units**.
  - So the bottom HUD is scaled by 0.53 like everything else. The note "the bottom HUD keeps its normal size" is
    wrong: it only looks normal because it is laid out edge to edge (`HudWings_Bind` holds the whole HUD, §2.1).
- **4P quarters** (1920 x 1080 units each) look identical to the side-by-side views, at 0.53. The tall side-by-side
  view only adds empty sky.
- **Full-width P1 view (3P)**: the right cluster spans 2328..3666 units. It is the ramjet bar (icon at 2328), then a
  32-unit spacer, then the portrait box at 3320..3660. The gap between the boost-bar swoosh (ends at 1460) and the
  ramjet icon is 868 units. These match the decoded sizes in §2.3 to within a few units.

## 2. Decoded widget trees [V]

### 2.1 `WBP_Hud_Race_C` (`/Game/Griffin/UI/Screens/WBP_Hud_Race`), path to the top bar

```
FuseOverlay_0 (root)
├ DELETE-IMAGE (Collapsed)
├ RB_HUD  FuseRetainerBox (scanline material), Overlay Fill/Fill
│ └ InvalidationBox_0
│   └ HUD_Container  FuseCanvasPanel  (= the whole player view)
│     ├ WBP_VehicleMarkerContainer  anchors 0,0-1,1 (name tags; not scaled)
│     └ SzB_InteriorScale  FuseScaleBox  Stretch None, StretchDirection DownOnly
│        slot (CanvasPanelSlot): anchors (0.5,0)-(0.5,1), Offsets L -1820 T 48 R 3640 B 48   <- designer
│        (0.8.2 fitInterior: anchors 0,0-1,1, Offsets 0/48/0/48, Stretch ScaleToFit)
│       └ SzB_InteriorSize  FuseSizeBox  WidthOverride 3620 (bOverride), RemoveApplicationScaling true
│          (MinDesiredWidth 3400 / MaxDesiredWidth 2600 are present but their bOverride flags are off)
│          slot: ScaleBoxSlot VAlign Fill (HAlign default Center)
│         └ HudWings_Bind  FuseHudWingWidget (a canvas; UFuseHudWidget::NativeTick writes ITS RenderTransform every
│           tick for the HUD sway, MaxHudOffset 75 units in third person / 150 in first person [ux-split-visuals §2.4])
│           ├ WBP_HUD_RaceInfo        anchor (0.5,0), Offsets T 4, Alignment (0.5,0), AutoSize   <- THE TOP BAR
│           ├ C_Center                anchors 0,0-1,1, Offsets T 260 B 260 (countdown, messages, threat, feed, ...)
│           ├ C_Center_Onboarding     (Collapsed, disabled)
│           ├ C_BotLayout             anchors (0,1)-(1,1), Offsets T 12 B 340 (height), Alignment (0.5,1)
│           │ ├ WBP_Hud_StatusEffects   anchor (0.5,1), T -270, size 301 x 947, Alignment (0.5,1), AutoSize
│           │ ├ WBP_HUD_Crashes_Bot     anchor (0,1), L 714.63654 T -119.747795, Alignment (0,1), AutoSize
│           │ ├ WBP_HUD_BotEngineInfo   anchors (0,1)-(1,1), L 44 R 44 B 315.14304, Alignment (0.5,1), AutoSize
│           │ │                         <- THE BOTTOM ENGINE ROW (§2.3)
│           │ └ Txt_SystemsCritical     anchors (0,0)-(0.2357,0), L 392 T -88 R -60, AutoSize (wraps when narrow)
│           ├ EventInfo               FuseNamedSlot, L 176 T 352, AutoSize (game-mode widget from the CSM)
│           ├ WBP_Hud_RamjetMessage   anchor (0.5,1), L 994.622 T -340, size 306 x 157, Alignment (0.5,0.5)
│           ├ WBP_HUD_SplitTime       (Collapsed) L 175 T 300
│           └ WBP_Hud_RamjetOverheatWarning anchor (1,1), L -700 T -325, Alignment (0.5,1), AutoSize
├ HUD_Crashing  canvas, opacity 0 (crash feed, crash counter; moved by the BP's CheckShouldMoveCrashHUD)
├ WBP_RightPrompt / WBP_LeftPrompt  onboarding prompts (Collapsed; overlay padding R 740 / L 500, render scale 1.8)
└ WBP_HUD_CenterPoint  centre dot (optional setting)
```

Notes:
- `SzB_InteriorScale` is **not** only the top bar's box: it scales **everything** in `HudWings_Bind`.
- Children of `C_Center` (all inside the interior):

  | Child | Slot |
  |---|---|
  | `WBP_Hud_Countdown` | top, centre +160 |
  | `FuseVerticalBox_1` (notification container + critical malfunction) | centre, bottom-aligned at -150 |
  | `WBP_HUD_ThreatIndicatorLayout` | 750 wide, centred |
  | `Hud_Notification_GameFeed` | top-right, 100 units in |
  | `WBP_EnvironmentalDisturbance_L/R` | centre ±600 |
  | `WBPHudVulnerableLeft/Right` | 280 units from the edges |
  | `WBP_HUD_SelectedAbility` | centre -480 |
  | Eliminator widgets | centred |

  Everything there is centred or edge-anchored and narrower than 2000 units.
- BP code [V `exports/hud/WBP_Hud_Race.disasm.txt`]: the only runtime slot writes are `CheckShouldMoveCrashHUD`,
  which moves `Hud_Notification_CrashFeed` and `B_CrashesContentColour` in `HUD_Crashing`.
- Animations [V]: `FadeOut`, `CrashCountIn/Out`, `HudOffPreCrash` and `HudOnPostCrash` animate ColorAndOpacity or
  RenderOpacity only. `HudOnPostCrash` binds `HUD_Container`, `WBP_HUD_BotEngineInfo`, `WBP_HUD_Crashes_Bot`, `RB_HUD`,
  `WBP_HUD_RaceInfo` and `HUD_Crashing`. **No 2D-transform track** anywhere, so render transforms we set on RaceInfo
  children or on BotEngineInfo are never overwritten. BotEngineInfo's own animations are colour or MPC only as well.
- `WBP_HUD_RaceInfo` has **no functions and no variables** [V: JSON export list]. Nothing re-positions its children.

### 2.2 The top bar: `WBP_HUD_RaceInfo` > `C_TopLayout` (FuseCanvasPanel, HitTestInvisible) [V]

All children are anchored at (0.5, 0), i.e. the bar's top centre. X values are relative to that centre.

| Child | Slot (Offsets L,T / size R,B; Alignment) | Extent (x) | In guest HUDs |
|---|---|---|---|
| `HB_TopBar_Layout_Shadow` (2 box images 940x320, margin L .9 R .1) | L 0 T -60, size 2340 x 260, Align (0.5,0) | ±1170 | shown |
| `HB_Layout_BackerLine` = the bracket lines (2 box images 740x128 `MI_UI_HUD_Element_MapFrame`, margin L .9 R .1, pad 4) | L 0 T 0, size 2180 x 128, Align (0.5,0) | ±1090 | shown |
| `WBP_Hud_EventTotalTime` = **timer** (`SzB_SizeOverride` 344 x 94) | L -905 T 50, size 344 x 94, Align (0.5,0) | -1077..-733 | shown |
| `WBP_Hud_PositionMap` = **1D map** (`SzB_1DMapSize` 980 x 170, volatile material `MI_UI_HUD_1DMap`) | L 0 T 36, Align (0.5,0), AutoSize | ±490 | collapsed (`GuestHudCollapse`) |
| `Img_1DMap_MidSection` | L 0 T 101.17, size 60 x 34, Align (0.5,0.5) | ±30 | collapsed |
| `WBP_Hud_EventLapCounter` = **LAP** (`Txt_CurrentLap` Font_Numbers + "LAP" + "/n") | L 612 T 40 (nominal 200 x 80), Align (0,0), AutoSize | +612..~+812 | shown (lap patch) |
| `WBP_Hud_EventCurrentPosition` = **POS** | L 847.9174 T 40 (nominal 184 x 128), Align (0,0), AutoSize | +848..~+1032 | shown |
| `WBP_Hud_BestLapTime` | anchor (0,0) of C_TopLayout: L 80 T 134.4, size 400 x 99 | under the timer | collapsed |
| `WBP_Hud_EventTakedownCounter` / `EventRamjetCounter` / `EventBonusTime` | centred, T 180 / 180 / 192 | centre | collapsed |

- The visible bar spans about -1077..+1032 (the brackets ±1090). The HUD sway adds ±75, so it needs about **±1170**:
  the native bar fits a view at most `width / 2340` of full size (0.82 at 1920).
- The brackets' and shadow's box margins (L 0.9 / R 0.1) keep the outer "step" shapes fixed and stretch only the flat
  middle. Each half stays undistorted down to 740 + 4 (brackets) and 940 (shadow).

### 2.3 The bottom engine row: `WBP_HUD_BotEngineInfo` [V + M]

```
SzB_ContentHeight (MinDesiredHeight 342) > HB_Container (FuseHorizontalBox):
  HB_AbilitiesAndAfterburner (auto) = WBP_HUD_EnergySystem (~112, slot pad L -50)
                                    + O_Abilities (Ability_List1, BG 342)
                                    + O_Afterburner (frame 970; speedo, icon inside)          = 1374
  FuseSpacer_140 (Fill, Size 20)                                                              =   20 (min)
  HB_RamjetContent (auto) = O_RamjetBar (970; icon inside at its left) + Sp_RamjetHoloSpace 32
                          + WBP_Hud_CharacterHolo (CharComSize 350 x 140) + Sp_EndSpaceForSymmetry 20
                                                                                 = 1372 (1022 portrait collapsed)
```

- HB desired width: **2767** with the portrait, **2417** without it. With the slot's 44 + 44 margins, the interior
  must be at least **2855 / 2505** wide, or the right end (portrait, then the ramjet bar) is pushed past the edge.
- The afterburner and ramjet icons sit **inside** their 970-wide boxes. Their overlay slots are
  HAlign Right / pad L -100 and the default Left / pad R -100, so they do not overhang.
- The swoosh image has about 68 transparent units at its end. That is why the visual gap (868) is larger than the
  layout gap (786).
- The portrait shows each radio line for everybody (`UxSplitGuestHolo` already hides it in guest HUDs). Only P1's
  HUD keeps it today.

### 2.4 `WBP_Hud_Memory_C` (campaign racing memories only, hud.md §3.1: never in couch races so far) [V]

- The same root, `SzB_InteriorScale` (designer slot) > `SzB_InteriorSize` (3620, RemoveApplicationScaling) >
  `HudWings_Bind`. `fitInterior` and the width override apply unchanged.
- **Top row** is `FuseSizeBox_1`: WidthOverride 3620, slot anchor (0.5,0) T 116, Align (0.5,0), AutoSize. It holds
  `FuseHorizontalBox_0` = [Spacer 100][hidden 220][`WBP_Hud_EventLapCounter_memory`][hidden Fill]
  [`WBP_Hud_EventTotalTime_Memory`][hidden Fill][`WBP_Hud_EventCurrentPosition_Memory`][hidden 220][Spacer 100].
  So LAP is at the left, the timer in the middle and POS at the right of a full-width row.
- The line under it is `FuseSizeBox_0`: 3620, T 228, height 60, holding `FuseScaleBox_0` (default ScaleToFit) >
  `HB_DecorativeHolder` (2 x 1696 x 60). `Img_Gradient` is stretched with L/R -1024.
- The 1D map is `O_1D_Map` in `C_Center`, **vertical** (Angle -90), at the right edge (anchor (1,0.5), L -95, 1386
  long). `WBP_HUD_RaceInfo` sits collapsed in `C_HOLDER-DELETE`. `WBP_HUD_BotEngineInfo_Memory` has slot L 44 T -88
  R 44 B 525.5.
- With a narrower interior, `FuseSizeBox_1` and `FuseSizeBox_0` must follow, or LAP and POS stay 3620 apart and are
  cut. They are generic names at the `HudWings_Bind` level, reached by name among its direct children.

## 3. Why everything is 0.53 now

`fitInterior` (hud.lua ~143) stretches the scale box's slot over the view and sets ScaleToFit with DownOnly.
`SScaleBox` then scales `SzB_InteriorSize` (3620 x desired height). With VAlign Fill, it hands the content the height
`area / scale`. Results:
- 1920-wide view: 1920 / 3620 = 0.530 for the whole interior.
- 3840-wide view: min(1, 3840/3620, 984/desired height). That is 1.0 while the interior's desired height stays
  <= 984. It would shrink a full-width 2P view if a tall EventInfo panel pushed the desired height up [L]. ScaleToFitX
  (EStretch 3) removes that height term.

## 4. Constraints for a narrow layout

1. **Rows wider than half a screen**: the top bar (±1170 with sway; compactable, §5.2) and the engine row
   (2417 / 2767 + 88).
2. **Text crispness**: only layout scaling (scale box, size box, slots) keeps text sharp. Render transforms are fine
   for shrinking the engine row (a down-scale) and for the purely graphic 1D map.
3. **Never touch `HudWings_Bind`'s RenderTransform**: the game rewrites it every tick (sway).
4. **Vertical density**: a 1920 x 1080 quarter at interior scale e gets a canvas 984 / e tall. The 2P top/bottom
   views already run the whole HUD in a 984-tall canvas at scale 1. So any e <= 1 in a quarter is no denser than the
   existing 2P look, and a 2P side-by-side view has twice the height.
5. **Unknown per-player view size** at runtime (§6). A wrong estimate must not cut the HUD.

## 5. Design

### 5.1 Per-view plan (computed in Lua each MAIN tick, applied only when it changes)

```
v.w            view width in units (computed, §6)
narrow         v.w < cfg.HudNarrowBelow (3000)
tgt            min(cfg.HudNarrowScale, 1)                     -- 1.0 = "same size as a full-width view"
top            "compact" if cfg.HudNarrowTopBar == "compact" and v.w / 2340 < tgt (Race HUD only), else "native"
e              min(tgt, v.w / (2 * TOP_HALF[top]))            -- TOP_HALF native 1170, compact 1000 (bar + sway)
Wn             ceil(v.w / e)                                  -- SzB_InteriorSize.WidthOverride; ScaleToFitX -> scale e
row            2417 (portrait hidden) | 2767 (cfg.HudNarrowHolo = "keep")
r              min(1, (Wn - 88) / row)                        -- engine row render scale
```

| View (window) | units | now | e (top bar, centre) | Wn | top bar | engine row r -> visual |
|---|---|---|---|---|---|---|
| 2P side by side, 16:9 | 1920 x 2160 | 0.53 | **0.96** | 2000 | compact | 0.791 -> **0.76** |
| 3P bottom / 4P, 16:9 | 1920 x 1080 | 0.53 | **0.96** | 2000 | compact | 0.791 -> **0.76** |
| 2P side by side, 21:9 | 2520 x 2160 | 0.70 | 1.0 | 2520 | native | 1 -> 1.0 |
| 2P side by side, 16:10 | 1728 x 2160 | 0.48 | 0.86 | 2000 | compact | 0.791 -> 0.68 |
| 2P top/bottom, 4:3 | 2880 x 1080 | 0.80 | 1.0 | 2880 | native | 1 -> 1.0 |
| full width, 16:9 | 3840 x 1080 | 1.0 | designer | 3620 | designer | designer |
| (`HudNarrowTopBar = "native"`, 16:9) | 1920 | | 0.82 | 2340 | native | 0.932 -> 0.76 |
| (`HudNarrowHolo = "keep"`, 16:9) | 1920 | | 0.96 | 2000 | compact | 0.691 -> 0.66 |

- In a 1920-wide view the top bar's half extent is 893 x 0.96 + sway 75 x 0.96 = 929 view units, out of 960.
- 0.96 / 0.53 = **1.8x** larger timer, LAP and POS, with the same proportions as a 2P top/bottom view.

### 5.2 Compact top bar (Race HUD, `WBP_HUD_RaceInfo > C_TopLayout`; slots are CanvasPanelSlot)

- The flat middle shortens by 2 x 197. The blocks keep their positions relative to the bracket steps: the timer stays
  185 units in from the outer end, LAP 478.
- `C_TopLayout` auto-sizes to the shadow (1946). `WBP_Hud_BestLapTime` (left-anchored, L 80) therefore follows to
  -893..-493, under the timer, by itself.

| Widget | call (compact) | designer (restore) |
|---|---|---|
| `WBP_Hud_EventTotalTime` | `Slot:SetPosition({X=-708, Y=50})` | `{X=-905, Y=50}` |
| `WBP_Hud_EventLapCounter` | `Slot:SetPosition({X=415, Y=40})` | `{X=612, Y=40}` |
| `WBP_Hud_EventCurrentPosition` | `Slot:SetPosition({X=650.9174, Y=40})` | `{X=847.9174, Y=40}` |
| `HB_Layout_BackerLine` | `Slot:SetSize({X=1786, Y=128})` | `{X=2180, Y=128}` |
| `HB_TopBar_Layout_Shadow` | `Slot:SetSize({X=1946, Y=260})` | `{X=2340, Y=260}` |
| `WBP_Hud_PositionMap` (P1 only; collapsed in guests) | `SetRenderTransformPivot({X=0.5,Y=0.5})`, `SetRenderScale({X=0.6,Y=0.6})` (588 wide: the designer's 243 / 122 gaps kept) | `SetRenderScale({X=1,Y=1})` |

- `Img_1DMap_MidSection` stays: it is the map's centre mark.
- `CanvasPanelSlot:SetPosition(Vector2D)` writes Offsets Left/Top and `SetSize(Vector2D)` writes Right/Bottom; the
  anchors stay at (0.5, 0).
- The map gets a render scale, not a size-box width, because `MI_UI_HUD_1DMap` is drawn in UV space: a narrower box
  would squash its racer icons.

### 5.3 The rest of the interior in a narrow view

| Widget | narrow | designer |
|---|---|---|
| `SzB_InteriorScale` (`HudWings_Bind:GetParent():GetParent()`) | slot anchors 0,0-1,1, Offsets L 0 T 48 R 0 B 48 (as 0.8.2); **`SetStretch(3)` ScaleToFitX**, DownOnly kept | the same (ScaleToFitX gives exactly 1.0 at >= 3620 wide) |
| `SzB_InteriorSize` (`HudWings_Bind:GetParent()`) | `SetWidthOverride(Wn)` | `SetWidthOverride(3620)` |
| Memory: `FuseSizeBox_1`, `FuseSizeBox_0` (direct children of `HudWings_Bind`) | `SetWidthOverride(Wn)` | `3620` |
| `WBP_HUD_BotEngineInfo` (`membersOf(w).bot`, both variants) | slot `SetOffsets({Left=s, Top=<kept>, Right=s, Bottom=<kept>})` with s = (Wn - row) / 2 when r < 1 (-208.5 at Wn 2000), so its layout box equals its content; `SetRenderTransformPivot({X=0.5,Y=1})`, `SetRenderScale({X=r,Y=r})` | Left/Right 44, scale 1 |
| `WBP_Hud_RamjetMessage` (Race variable) | when 994.622 + 153 > Wn/2 - 44: `Slot:SetPosition({X=(1879 - row/2) * r, Y=-340})` = over the ramjet bar's visual centre (530 at Wn 2000) | `{X=994.622, Y=-340}` |
| `WBP_HUD_Crashes_Bot` (Race variable) | `Slot:SetPosition({X=44 + (714.63654 - 44) * r, Y=-119.747795})` (keeps its place over the shrunk row) | `{X=714.63654, Y=-119.747795}` |
| `WBP_Hud_CharacterHolo` (`bot.WBP_Hud_CharacterHolo`) | collapsed while narrow (P1's clone, re-hosted game HUD, guests with `UxSplitGuestHolo = "keep"`) unless `HudNarrowHolo = "keep"`; re-collapsed every tick (the BP shows it per radio line) | previous visibility given back |

Read the BotEngineInfo Top/Bottom with `Slot:GetOffsets()` (a Margin table), which also covers the Memory slot (T -88,
B 525.5).

Left as they are:
- `WBP_Hud_RamjetOverheatWarning`: 700 in from the right edge, over the ramjet bar.
- `Txt_SystemsCritical`: wraps to two lines above the boost bar.
- `EventInfo` and `WBP_HUD_SplitTime`: left-anchored.
- Every `C_Center` child.
- `HUD_Crashing`: view units, centred.
- The onboarding prompts: view units. They are shown in the prologue only and may overlap in 1920 if both show.

### 5.4 Why this is robust to a wrong view estimate

- Every row is sized to fit **the interior** (`Wn`), never the view: the compact bar needs ±1000 and Wn >= 2000; the
  engine row's visual width is `Wn - 88`.
- ScaleToFitX then fits the interior into the **real** view area.
- So a wrong `v.w` only changes the achieved scale. If the real view is narrower than computed, everything is smaller
  than intended, never cut.
- The same holds for the game's UI-scale setting (`GfnUserSettingsSaveData.ApplicationScale`, multiplied into Slate
  but not into `GetViewportScale`).
- Exception: `FuseSizeBox.RemoveApplicationScaling` might divide our override by that application scale (§9 Q1).

## 6. View size per player at runtime

Not readable:
- `ULocalPlayer` reflects only ViewportClient, AspectRatioAxisConstraint, PendingLevelPlayerControllerClass,
  bSentSplitJoin and ControllerId. Origin and Size are not reflected [V usmap].
- `/Script/SlateCore.Geometry` has **no props** [V usmap]. `GetCachedGeometry`, `GetPlayerScreenWidgetGeometry` and
  `SlateBlueprintLibrary.GetLocalSize(Geometry)` are therefore useless from Lua: UE4SS turns struct returns into
  tables of reflected fields [ue4ss-api §9], so the geometry comes back as an empty table, and passing it back gives a
  zeroed FGeometry.

Computed instead (all inputs exist):
- **View fractions**: the engine's default `UGameViewportClient::SplitscreenInfo` for the layout split.lua writes. The
  screenshots match the default layouts.
  - 2P: `GameMapsSettings.TwoPlayerSplitscreenLayout` (CDO, `U.GMS()`). Horizontal 0 = 1 x 0.5 each, Vertical 1 =
    0.5 x 1.
  - 3P FavorTop: P1 is 1 x 0.5; P2 and P3 are 0.5 x 0.5.
  - 4P Grid: 0.5 x 0.5.
  - Single view (`present.isSingleView()` or `St.race.singleView`): 1 x 1.
  - The index is `lp.index` from `U.localPlayers()`, which is the `GameInstance.LocalPlayers` order the viewport lays
    out. The view count is `#U.localPlayers()`.
- **Full size in units**: `WidgetLayoutLibrary:GetViewportSize(world)` returns a Vector2D table in pixels, and
  `WidgetLayoutLibrary:GetViewportScale(world)` returns the UMG DPI scale as a float [V jmap]. Full width =
  px.X / dpi: 3840 at 16:9 at any resolution, 5040 at 21:9. Fallback when either call fails: 3840 x 2160.
- One evaluation per MAIN tick is 2 UFunction calls plus a CDO property read.

## 7. When to apply, re-apply and restore

- **At creation**: `ensureGuest` (guests and P1's clone), right after `AddToPlayerScreen` and `fitInterior`, once the
  entry exists. Without this the HUD would pop from 0.53 to 0.96 up to 250 ms after it appears.
- **Every MAIN tick** (`M.tick`, after the guest loop): compute every HUD's plan key. Apply on a change. These cover:
  - a new HUD instance (the entry is new);
  - the 2P layout flip (F8, lobby row);
  - a guest leaving (3P becomes 2P);
  - single view and split (intro, results);
  - a window resize.
- **While narrow**: re-collapse the portrait every tick (cheap: `GetVisibility` on a validated widget).
- **The re-hosted game HUD** (`P1HudMode = "rehost"`, P1's view): the same per tick, with its state in `h.gameLayout`.
  Reset it in `releaseP1` and `clearAll`.
- The game's HUD in "leave" mode spans the whole viewport, and in "clone" mode it is hidden: it keeps the 0.8.2 fit
  only.
- **Restore** = apply the plan "W": the designer values of every row in §5.2 and §5.3. Both directions set every value,
  so an apply is idempotent and repairs a half-applied state.
  - Guest HUDs and the clone are removed in `clearAll`.
  - The game's HUD dies with the race world.
  - Nothing persists past a race.
- **Hot reload**: the new Lua state's first apply sets every value explicitly. The orphan sweep removes the old guest
  HUDs, as today.
- In **single view**, guest HUDs keep their last layout (they are hidden). P1's HUD follows (designer, full screen).
- **Photo mode**: `M.tick` returns before the layout pass, as for all HUD work.
- **Failures**: `pcall`, then `U.logEvery`. After 3 failures for the same plan key, stop retrying that key
  (`st.layoutFailKey`).

## 8. Implementation steps (hud.lua; consts.lua, config.lua)

Paths already proven live:
- `HudWings_Bind:GetParent():GetParent()` with its slot and `SetStretch`: the log line "HUD top bar fits its view"
  appears in 25 run logs, and "fit unavailable" in none.
- `bot.WBP_Hud_CharacterHolo` + `SetVisibility`: "radio-chatter portrait hidden" appears in 14 run logs.

The sketches below pass `luac5.4 -p` with stubs. `narrowPlan` reproduces the §5.1 table in plain Lua.

1. `consts.lua`: `C.CDO.WidgetLayoutLibrary = "/Script/UMG.Default__WidgetLayoutLibrary"`. Optional:
   `C.E.Stretch = { ScaleToFit = 2, ScaleToFitX = 3 }` (usmap EStretch).
2. `config.lua`, HUD section:
   - New keys: `HudNarrowViews = "readable"` (`"readable"` | `"fit"`), `HudNarrowBelow = 3000`,
     `HudNarrowScale = 1.0`, `HudNarrowTopBar = "compact"` (`"compact"` | `"native"`), `HudNarrowHolo = "hide"`
     (`"hide"` | `"keep"`).
   - Validation: `ENUMS` += the three selectors; `POSITIVE` += `HudNarrowBelow` and `HudNarrowScale`.
   - Update the `HudFitInterior` comment (ScaleToFitX).
3. `hud.lua`:
   1. Header revision paragraph for 0.11.0 (user quote, this file).
   2. Constants: `STRETCH_FIT_X`, `INTERIOR_W`, `FULL_VIEW_W`, `BOT_MARGIN`, `BOT_ROW_W`, `TOP_HALF`, `TOP_SHIFT`,
      `TOP_SLOTS`, `MAP_COMPACT`, `RAMJET_MSG`, `CRASHES_BOT`. Values are in §5.
   3. `fitInterior`: `sc:SetStretch(STRETCH_FIT_X)` instead of 2, plus its log text.
   4. New `viewSizes(lps)` (§6), `narrowPlan(v, isRace)` (§5.1), `applyLayout(w, who, plan, st, guestHoloHidden)`
      (§5.2 and §5.3) and `layoutHud(w, who, v, st, guestHoloHidden)` (key compare, apply, log, portrait
      re-collapse). Code sketch below.
   5. `M.updateLayouts(lps)`: guests, P1's clone and the re-hosted game HUD. Call it from `M.tick` after the guest
      loop: `U.try(TAG, M.updateLayouts, lps)`.
   6. `ensureGuest`: after `h.guests[key] = e`, call `U.try(TAG, layoutHud, w, "P" .. pnum, <view of pc>, e, ...)`.
   7. `releaseP1` and `clearAll`: `h.gameLayout = nil`.
   8. Optional: `M.layoutStatus()` for diag F9 (per HUD: key, e, Wn, r, top).
4. `luac5.4 -p` on hud.lua, config.lua and consts.lua.
5. Docs: add V-HUD-17/18/19 to ARCHITECTURE §6, and the keys to README §7 (config).

```lua
-- C_TopLayout's direct children by name (WBP_HUD_RaceInfo has no BP variables and no functions)
local function topBarParts(ri)
    local out = {}
    local tree = ri.WidgetTree
    local root = U.ok(tree) and tree.RootWidget or nil
    if not U.ok(root) then return out end
    for i = 0, (root:GetChildrenCount() or 0) - 1 do
        local ch = root:GetChildAt(i)
        if U.ok(ch) then out[ch:GetFName():ToString()] = ch end
    end
    return out
end

local function slotOf(x)
    if not U.ok(x) then return nil end
    local s = x.Slot                                    -- UWidget.Slot (CanvasPanelSlot here)
    return U.ok(s) and s or nil
end

-- plan.key == "W": designer layout. Sets EVERY value in both directions (idempotent, repairs a half-applied state).
local function applyLayout(w, who, plan, st, guestHoloHidden)
    local narrow = plan.key ~= "W"
    local wing = w.HudWings_Bind
    if not U.ok(wing) then error("no HudWings_Bind") end
    local size = wing:GetParent()
    if not (U.ok(size) and U.pathOf(size):find("SzB_InteriorSize", 1, true)) then error("no SzB_InteriorSize") end
    size:SetWidthOverride(narrow and plan.wn or INTERIOR_W)          -- SizeBox:SetWidthOverride(Float)
    local isRace = U.pathOf(w:GetClass()) == C.BP.HudRace
    local r = narrow and plan.r or 1
    if isRace then
        local ri = w.WBP_HUD_RaceInfo
        if U.ok(ri) then
            local parts, compact = topBarParts(ri), narrow and plan.top == "compact"
            for name, d in pairs(TOP_SLOTS) do
                local slot = slotOf(parts[name])
                if slot and d.pos then
                    slot:SetPosition({ X = d.pos.X + (compact and d.dx or 0), Y = d.pos.Y }) -- CanvasPanelSlot:SetPosition
                elseif slot then
                    slot:SetSize({ X = compact and d.cw or d.size.X, Y = d.size.Y })         -- CanvasPanelSlot:SetSize
                end
            end
            local map = parts.WBP_Hud_PositionMap
            if U.ok(map) then
                local m = compact and MAP_COMPACT or 1
                map:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                map:SetRenderScale({ X = m, Y = m })
            end
        end
        local msg = slotOf(w.WBP_Hud_RamjetMessage)
        if msg then
            local x = RAMJET_MSG.X
            if narrow and RAMJET_MSG.X + 153 > plan.wn / 2 - BOT_MARGIN then x = (1879 - plan.row / 2) * r end
            msg:SetPosition({ X = x, Y = RAMJET_MSG.Y })
        end
        local cb = slotOf(w.WBP_HUD_Crashes_Bot)
        if cb then cb:SetPosition({ X = BOT_MARGIN + (CRASHES_BOT.X - BOT_MARGIN) * r, Y = CRASHES_BOT.Y }) end
    else
        for i = 0, (wing:GetChildrenCount() or 0) - 1 do       -- Memory: top row + line under it follow the interior
            local ch = wing:GetChildAt(i)
            local n = U.ok(ch) and fnameLower(ch) or ""
            if n == "fusesizebox_0" or n == "fusesizebox_1" then ch:SetWidthOverride(narrow and plan.wn or INTERIOR_W) end
        end
    end
    local bot = membersOf(w).bot
    local bslot = slotOf(bot)
    if bslot then
        local off = bslot:GetOffsets()                         -- CanvasPanelSlot:GetOffsets() -> Margin table
        local side = (r < 1) and (plan.wn - plan.row) / 2 or BOT_MARGIN
        bslot:SetOffsets({ Left = side, Top = off.Top, Right = side, Bottom = off.Bottom })
        bot:SetRenderTransformPivot({ X = 0.5, Y = 1 })
        bot:SetRenderScale({ X = r, Y = r })
        local holo
        for _, n in ipairs({ "WBP_Hud_CharacterHolo", "WBP_Hud_CharacterHolo_Memory" }) do
            local ok, x = pcall(function() return bot[n] end)
            if ok and U.ok(x) then holo = x; break end
        end
        if holo and narrow and cfg.HudNarrowHolo ~= "keep" and not guestHoloHidden then
            if st.holoVis == nil then st.holoVis = holo:GetVisibility() end
            holo:SetVisibility(VIS_HIDE)
            st.holo = holo                                     -- re-collapsed every tick by layoutHud
        elseif holo and st.holoVis ~= nil then
            holo:SetVisibility(st.holoVis)
            st.holo, st.holoVis = nil, nil
        end
    end
end
```

```lua
-- Every local player's view in UI units by lp.index (§6), plus "one view" (present.lua / join's single-view race).
local function viewSizes(lps)
    local single = St.race.singleView == true
    local present = lazy("present")
    if not single and present and present.isSingleView then
        local ok, s = pcall(present.isSingleView)
        single = ok and s == true
    end
    local fullW, fullH = FULL_VIEW_W, 2160
    pcall(function()
        local wll, world = U.cdo("WidgetLayoutLibrary"), U.world()
        if not (U.ok(wll) and U.ok(world)) then return end
        local px = wll:GetViewportSize(world)           -- WidgetLayoutLibrary:GetViewportSize(Object) -> Vector2D (px)
        local dpi = wll:GetViewportScale(world)         -- WidgetLayoutLibrary:GetViewportScale(Object) -> Float (DPI)
        if type(px) == "table" and type(px.X) == "number" and px.X > 0 and type(dpi) == "number" and dpi > 0 then
            fullW, fullH = px.X / dpi, px.Y / dpi
        end
    end)
    local twoP = C.E.TwoP.Horizontal
    pcall(function()
        local g = U.GMS()
        if U.ok(g) then twoP = g.TwoPlayerSplitscreenLayout end   -- Byte written by split.applyLayoutSettings
    end)
    local n, out = #lps, {}
    for _, lp in ipairs(lps) do
        local fw, fh = 1, 1                             -- engine default SplitscreenInfo
        if not single and n == 2 then
            if twoP == C.E.TwoP.Vertical then fw = 0.5 else fh = 0.5 end
        elseif not single and n == 3 then
            fh = 0.5
            if lp.index > 1 then fw = 0.5 end           -- FavorTop: P1 across the top
        elseif not single and n >= 4 then
            fw, fh = 0.5, 0.5                           -- Grid
        end
        out[lp.index] = { w = fw * fullW, h = fh * fullH }
    end
    return out, single
end

local function narrowPlan(v, isRace)
    if cfg.HudNarrowViews ~= "readable" or v.w >= (tonumber(cfg.HudNarrowBelow) or 3000) then return { key = "W" } end
    local tgt = math.min(tonumber(cfg.HudNarrowScale) or 1, 1)
    local top, e = "row", tgt                           -- Memory HUD: its top row follows the interior, no cap
    if isRace then
        top = (cfg.HudNarrowTopBar ~= "native" and v.w / (2 * TOP_HALF.native) < tgt) and "compact" or "native"
        e = math.min(tgt, v.w / (2 * TOP_HALF[top]))
    end
    local wn = math.ceil(v.w / e)                       -- ScaleToFitX: interior scale = view width / wn
    local row = BOT_ROW_W[cfg.HudNarrowHolo == "keep" and "keep" or "hide"]
    local r = math.min(1, (wn - 2 * BOT_MARGIN) / row)
    return { key = string.format("N%d:%s:%.3f", wn, top, r), wn = wn, e = e, top = top, row = row, r = r }
end

-- Plan compare + apply (on change only) + portrait re-collapse (every tick while narrow). Callers wrap it in U.try.
local function layoutHud(w, who, v, st, guestHoloHidden)
    if cfg.HudFitInterior == false or not (U.ok(w) and v) then return end
    local plan = narrowPlan(v, U.pathOf(w:GetClass()) == C.BP.HudRace)
    if st.layoutKey ~= plan.key and st.layoutFailKey ~= plan.key then
        if st.layoutTryKey ~= plan.key then st.layoutTryKey, st.layoutFails = plan.key, 0 end
        local ok, err = pcall(applyLayout, w, who, plan, st, guestHoloHidden)
        if ok then
            st.layoutKey = plan.key
            if plan.key == "W" then
                U.log(TAG, "%s HUD: view %.0fx%.0f, designer layout (V-HUD-18)", who, v.w, v.h)
            else
                U.log(TAG, "%s HUD: narrow view %.0fx%.0f: interior %d (scale %.2f), top bar %s, engine row x%.2f%s "
                    .. "(V-HUD-17)", who, v.w, v.h, plan.wn, plan.e, plan.top, plan.r,
                    st.holo ~= nil and ", portrait hidden" or "")
            end
        else
            st.layoutFails = (st.layoutFails or 0) + 1
            if st.layoutFails >= 3 then st.layoutFailKey = plan.key end
            U.logEvery("hud.layoutfail", 5000, TAG, "%s HUD layout %s failed (%d): %s", who, plan.key,
                st.layoutFails, tostring(err))
        end
    end
    if st.holo ~= nil then
        if U.ok(st.holo) then
            if st.holo:GetVisibility() ~= VIS_HIDE then st.holo:SetVisibility(VIS_HIDE) end
        else
            st.holo, st.holoVis = nil, nil
        end
    end
end

-- MAIN tick (M.tick, after the guest loop): every HUD we host on a player screen.
function M.updateLayouts(lps)
    if cfg.HudFitInterior == false then return end
    local h = H()
    local views, single = viewSizes(lps)
    local idxOf = {}
    for _, lp in ipairs(lps) do if U.ok(lp.pc) then idxOf[U.key(lp.pc)] = lp.index end end
    for k, e in pairs(h.guests) do
        local v = views[idxOf[k] or 0]
        -- one view: guests are hidden (updateVisibility) and keep their layout; P1's HUD follows the full screen
        if v and U.ok(e.widget) and (not single or e.pnum == 1) then
            U.try(TAG, layoutHud, e.widget, "P" .. tostring(e.pnum), v, e,
                e.pnum ~= 1 and cfg.UxSplitGuestHolo ~= "keep")
        end
    end
    if p1Mode() == "rehost" and h.p1Placed and U.ok(h.p1hud) and views[1] then
        h.gameLayout = h.gameLayout or {}               -- reset in releaseP1 / clearAll
        U.try(TAG, layoutHud, h.p1hud, "game", views[1], h.gameLayout, false)
    end
end

-- ensureGuest, right after `local mem = membersOf(w)` (before collapseGlobalParts): no 0.53 -> 0.96 pop on screen.
--   U.try(TAG, function()
--       local lps = U.localPlayers()
--       local views, single = viewSizes(lps)
--       for _, lp in ipairs(lps) do
--           if sameObj(lp.pc, pc) and (not single or pnum == 1) then
--               layoutHud(w, "P" .. tostring(pnum), views[lp.index], e, pnum ~= 1 and cfg.UxSplitGuestHolo ~= "keep")
--           end
--       end
--   end)
```

Placement in hud.lua:
- `topBarParts`, `slotOf`, `applyLayout`, `viewSizes`, `narrowPlan` and `layoutHud` go after `membersOf` and before
  `ensureGuest` (applyLayout calls `membersOf`; `fnameLower`, `lazy` and `VIS_HIDE` exist above).
- `M.updateLayouts` goes after `p1Mode`, e.g. just before `M.tick`.

## 9. Config keys and VERIFY ids

| Key | Default | Values / meaning |
|---|---|---|
| `cfg.HudNarrowViews` | `"readable"` | `"readable"` (this design) \| `"fit"` (0.8.2: whole HUD to the view, 0.53). `HudFitInterior = false` still turns all of it off |
| `cfg.HudNarrowBelow` | `3000` | view width in units below which a view is narrow (a full 16:9 width is 3840) |
| `cfg.HudNarrowScale` | `1.0` | HUD size in narrow views relative to a full-width view; capped so the top bar keeps clear of the view edges (0.96 at 16:9) |
| `cfg.HudNarrowTopBar` | `"compact"` | `"compact"` (§5.2) \| `"native"` (designer bar; the scale is then capped at width / 2340, i.e. 0.82) |
| `cfg.HudNarrowHolo` | `"hide"` | `"hide"` (radio portrait collapsed in narrow views) \| `"keep"` (engine row 0.66 instead of 0.76) |

- **V-HUD-17**: one log line per HUD at layout time. Example:
  `P2 HUD: narrow view 1920x2160: interior 2000 (scale 0.96), top bar compact, engine row x0.79 (V-HUD-17)`.
  The screenshot shows timer, LAP and POS at 0.96 of the 2P top/bottom size; nothing touches a view edge; the whole
  engine row is visible.
- **V-HUD-18**: a layout change mid-race (F8 2P flip, a guest leaving, single view) logs
  `P1 HUD: view 3840x1080, designer layout (V-HUD-18)` and switches back without errors.
- **V-HUD-19**: `SzB_InteriorSize:GetDesiredSize().X` equals Wn (±1) one tick after the apply. Otherwise the Fuse size
  box (RemoveApplicationScaling) rescales or re-applies its width (Q1).

Fallback if V-HUD-17 or V-HUD-19 fails: `cfg.HudNarrowViews = "fit"`.

## 10. Questions and risks [S]

- **Q1** Does the `FuseSizeBox` keep our `SetWidthOverride` at runtime? `USizeBox::SetWidthOverride` pushes the raw
  value into the SBox. The Fuse class may divide by the application scale in its own sync, or re-apply its width.
  This is harmless at the default UI scale; the V-HUD-19 probe settles it.
- **Q2** The engine row width (2417) comes from decoded sizes plus the 3P screenshot. Check it once with
  `WBP_HUD_BotEngineInfo:GetDesiredSize().X` while P1's portrait is collapsed. Energy pips depend on the vehicle;
  the estimate is ±20.
- **Q3** The engine row is render-scaled down (0.79). Check that the speed number and ability icons look clean.
  Minification has no blur, possibly slight aliasing.
- **Q4** HUD sway (interface shake): the outer ends of the engine row can clip by a few units at extreme camera swing,
  as in 0.10.0. Check in a hard drift. The top bar keeps 31 view units at full sway.
- **Q5** Taste: 0.96 everywhere matches the 2P top/bottom proportions. If quarters feel crowded on the TV, lower
  `HudNarrowScale` (0.85: Wn 2259, engine row r 0.898 -> 0.76).
- **Q6** Memory HUD (campaign memories only): untested. Its vertical 1D map (1386 long, rotated) already overflows a
  984-tall canvas in 2P top/bottom; same in quarters.
- **Q7** The onboarding prompts (view units, render scale 1.8, prologue only) may overlap in a 1920-wide view.

## Measured (2026-10-10)

2P side by side, 1280x720, the same race restarted once with `HudNarrowViews = "fit"` and once with `"readable"`
(README screenshot 22): the timer, LAP and POS come out the same size in both (2x crops of P1's top bar); `"readable"`
only pulls the top bar together and shrinks the engine row to x0.79. The expected ~1.8x text did not happen. The
option stays off by default and is proposed for removal unless the user sees a benefit on a TV.
