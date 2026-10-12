# The "Settings crash" of 2026-10-09 21:20:41 (crash_2026_10_09_19_20_41.0352047.dmp) - explained

Status: CONFIRMED live 2026-10-10 02:3x: `FName("GetOwningPlayer"):GetComparisonIndex()` = 465218 = 0x71942, the exact name
the crashing `__index` looked up. Not a mod bug: a test probe.

## What the dump shows
- AV reading 0x20a at UE4SS.dll+0x405fc4 = `FField::GetClass()` (`mov rax,[rax]` on a field pointer of ~0x202).
- Caller chain (UE4SS GR Edition e3ba1016, identified by string references and code shape):
  - +0x228090 / +0x223a80: property iterator init (TArray access with the "Array index out of bounds" check).
  - +0x400330: `GetPropertyByNameInChain(UStruct*, FName)` with UE4SS's static (struct, name) cache. This was a cache miss, so it walked the struct's own chain.
  - +0x2aad40: the UObject `__index` handler (strings "MetaMethodContainer", "IsValid", "GetAddress", "[Lua][Error] The UObject instance is nullptr...").
    It only checks the object pointer for null. Built-in methods (IsValid, GetAddress, ...) return before any reflection lookup.
    A dead object reaches `obj->ClassPrivate` -> property chain = freed memory -> AV.
- Values recovered from the stack: object = 0x5e3e1fe0 (frame `[rbp+0x1b0]`); looked-up name = FName ComparisonIndex
  0x71942, Number 0 (saved rbx at 0xc9d8a0).
- Lua C functions between the Lua frames: +0xc7c470 = `luaB_xpcall` (errfunc 2), +0xc7c3d0 = `luaB_pcall` (errfunc 0).
  Chain from the EngineTick hook: loop callback -> **xpcall -> pcall -> pcall** -> `__index`.

## Why it is the test probe
- That nesting is exactly testcmd.lua: `sched.every` wrapper `xpcall(tick)` -> `pcall(f, a, line)` (command dispatch,
  line 168) -> `pcall(fn)` (the `lua` chunk, line 156). Every mod tick goes through main.lua `call()` -> `U.tryEvery`
  = a second xpcall, which this stack does not have.
- Timeline (transcript): 21:20:31 P1 X (Settings opens) -> 21:20:35 B (back) -> ~21:20:40 test command
  `lua local m=St.menu.widget; local o=m:GetOwningPlayer() ...` -> crash 21:20:41. The same probe at 21:20:03 (before
  Settings) worked. Settings replaces the main-menu widget, so `St.menu.widget` was a dead object.
  The probe called `m:GetOwningPlayer()` without `U.ok(m)`.
- The pre-race Settings repro (same session, no probe afterwards) did not crash. Neither did the later Settings return test (V-FEO-11).
- Confirmed on the next live run (2026-10-10, same build): `FName("GetOwningPlayer"):GetComparisonIndex()` -> 465218 (0x71942).

## Rule
Test probes are Lua that runs inside the game: guard every cached UObject with `U.ok(x)` before `x.Member` or `x:Fn()`.
UE4SS's `__index` does not validate the object. Mod code already does this (U.ok before every cached-widget use).
