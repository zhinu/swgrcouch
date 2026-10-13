/* swgr_inputfilter.dll - per-player filter for STAR WARS: Galactic Racer's raw vehicle input (SWGRCouch).
 *
 * Why (notes/research/input-isolation.md): every UGfnRawInputSubsystem (one per local player) registers its own
 * Slate input pre-processor ("GfnRawInput", vtable 0x14991a9c0 in both builds). Its key/analog/mouse handlers record
 * the event's FKey into a TMap<FKey, FInputActionValue> and IGNORE FInputEvent::UserIndex, so every subsystem sees
 * every keyboard, mouse and pad. Car steering/throttle/brake/boost are read from that map
 * (UGfnRawInputSubsystem::GetActionValue 0x143a07d1a, hotfix 0x143a0840a), so one device drives every human car.
 *
 * What: this DLL swaps 5 slots of that vtable (KeyDown, KeyUp, AnalogInput, MouseButtonDown, MouseButtonUp) for
 * wrappers. A wrapper drops the event (returns false = not handled, exactly what the original returns) when the
 * processor belongs to a local player whose ControllerId differs from the event's owner:
 *     owner = UserIndex (+1 for pad events when "offset=1", i.e. bOffsetPlayerGamepadIds / KeyboardIsP1).
 * Processors it does not know (no owner line in the cfg) always get the original call: no cfg = no change.
 *
 * Loaded from Lua with package.loadlib(path, "*") (inputfix.lua): DllMain does the work, no Lua API is used.
 * The module pins itself (never unloaded: the vtable points into it). Lua talks to it through two text files next
 * to the DLL: swgr_inputfilter.cfg (read when its write time or size changes) and swgr_inputfilter.status (written
 * after each cfg reload). Run G (2026-10-07): the cfg used to be checked only from the input path, so a 'wo' bind
 * waited for the next pad/key event (seconds). Now a small reload thread checks it every 250 ms (status
 * reload_thread=1); the input path checks it only when that thread could not be started (reload_thread=0).
 * The owner table is shared between that thread and the game's input thread: a spin lock guards it, the file I/O is
 * done outside the lock. A read that looks torn (empty, or no final newline: Lua truncates then writes) is retried
 * on the next check, up to 4 times, before it is applied as it is.
 * cfg lines:  enabled=0|1   offset=0|1   seq=<n>   p <ControllerId> <subsystem address, 0x hex or decimal>
 *             wo <tag> <dst> <obj>   w <tag> <dst> <src> <len>: one-shot writes, each tag applied once; the lines of
 *             one cfg text may come in any tag order (all tags above the last applied one are applied)
 *
 * Build: build.sh (clang --target=x86_64-pc-windows-msvc, no CRT, imports kernel32 only).
 *
 * GAME BUILDS (2026-10-09). SWGR-Win64-Shipping.exe has a fixed image base 0x140000000 (no DYNAMIC_BASE), so every
 * address is hard-coded, once per known build, in the BUILDS table below:
 *     CL381121  488,290,328 bytes  (input-isolation.md)
 *     CL382493  490,551,832 bytes  hotfix (notes/research/inputfilter-hotfix-port.md)
 * The hotfix moved only the 6 code pointers (GetDebugName and the 5 handlers). The vtables, the subsystem layout,
 * GUObjectArray and every struct offset are unchanged (static evidence in the port notes; the old DLL's 'wo' bind
 * already worked live on the hotfix, run N1). install() picks the set whose GetDebugName slot (vt[11], a different
 * function address in each build: the build fingerprint) matches AND whose 5 handler slots hold the expected originals
 * (or this module's wrappers: "ok (already patched)"). Status line build=<CL> names the identified build
 * (build=unknown when no set matches), builds= lists the sets this DLL knows. On a mismatch nothing is patched and
 * reason= starts with "mismatch: GetDebugName slot" or "mismatch: handler slot", followed by what each set expected,
 * e.g. "(381121: GetDebugName slot 0x... != 0x14300b61a; 382493: GetDebugName slot 0x... != 0x14300bd0a)".
 * The 'wo' weak write (the only car binding path once UE4SS refuses the Lua weak write) uses the identified build's
 * GUObjectArray; on an unknown build it tries each known set and only writes when the GUObjectArray item it finds
 * points back to the object, as before. New build: re-derive with scripts/input (input-isolation.md section 3, port
 * notes section 4) and append a set.
 */
typedef unsigned long long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef int BOOL;
typedef int i32;
typedef void *HANDLE;

typedef struct {
    void *BaseAddress; void *AllocationBase; u32 AllocationProtect; u16 PartitionId;
    u64 RegionSize; u32 State; u32 Protect; u32 Type;
} MBI;
typedef struct { u32 attr; u32 c_lo, c_hi, a_lo, a_hi, w_lo, w_hi; u32 size_hi, size_lo; } FILEATTR;

__declspec(dllimport) BOOL __stdcall VirtualProtect(void *, u64, u32, u32 *);
__declspec(dllimport) u64 __stdcall VirtualQuery(const void *, MBI *, u64);
__declspec(dllimport) BOOL __stdcall GetModuleHandleExW(u32, const void *, void **);
__declspec(dllimport) u32 __stdcall GetModuleFileNameW(void *, u16 *, u32);
__declspec(dllimport) HANDLE __stdcall CreateFileW(const u16 *, u32, u32, void *, u32, u32, HANDLE);
__declspec(dllimport) BOOL __stdcall ReadFile(HANDLE, void *, u32, u32 *, void *);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE, const void *, u32, u32 *, void *);
__declspec(dllimport) BOOL __stdcall CloseHandle(HANDLE);
__declspec(dllimport) BOOL __stdcall GetFileAttributesExW(const u16 *, int, FILEATTR *);
__declspec(dllimport) u64 __stdcall GetTickCount64(void);
__declspec(dllimport) BOOL __stdcall DisableThreadLibraryCalls(void *);
__declspec(dllimport) HANDLE __stdcall CreateThread(void *, u64, u32 (__stdcall *)(void *), void *, u32, u32 *);
__declspec(dllimport) void __stdcall Sleep(u32);

#define INVALID_HANDLE ((HANDLE)(long long)-1)

/* ---- engine (UE 5.7.4) struct offsets, the same in both builds (input-isolation.md section 2.3, port notes) ---- */
#define EV_USERINDEX   0x0c            /* FInputEvent::UserIndex (KismetInputLibrary::GetUserIndex thunk)   */
#define KEV_CHARCODE   0x40            /* FKeyEvent::CharacterCode (Key at 0x28, 0x18 bytes)               */
#define KEV_KEYCODE    0x44            /* FKeyEvent::KeyCode; both 0 for gamepad buttons                   */
#define OBJ_INDEX      0x0c            /* UObjectBase::InternalIndex                                       */
#define ITEM_STRIDE    24              /* FUObjectItem: Object +8, SerialNumber +0x10                      */
#define DEBUGNAME_SLOT 11              /* IInputProcessor::GetDebugName, returns L"GfnRawInput"            */

enum { K_DOWN, K_UP, K_ANALOG, K_MDOWN, K_MUP, NSLOT };
static const int SLOT[NSLOT] = { 2, 3, 4, 6, 7 };

/* ---- per-build constants (scripts/input; input-isolation.md section 2, inputfilter-hotfix-port.md) ---- */
typedef struct {
    u32 cl;              /* changelist, status build=<cl>                                                 */
    u64 procVtable;      /* FGfnRawInputProcessor (IInputProcessor) vtable                                */
    u64 subsysVtable;    /* UGfnRawInputSubsystem instance vtable (old: jmap instance_vtable; hotfix: the
                          * InternalConstructor passed to its GetPrivateStaticClassBody stores it)        */
    u64 subsysProc;      /* UGfnRawInputSubsystem: TSharedPtr<processor>.Object                           */
    u64 debugNameFn;     /* vt[DEBUGNAME_SLOT]: lea rax, L"GfnRawInput"; ret (the build fingerprint)      */
    u64 expect[NSLOT];   /* vt[SLOT[i]] before the patch: KeyDown, KeyUp, AnalogInput, MouseButtonDown/Up  */
    u64 objChunks;       /* GUObjectArray.ObjObjects.Objects (chunk table pointer) = GUObjectArray + 0x10 */
    u64 objNum;          /* GUObjectArray.ObjObjects.NumElements                     = GUObjectArray + 0x24 */
    u64 serialCounter;   /* GUObjectArray.MasterSerialNumber                         = GUObjectArray + 0xb8 */
} Build;
static const Build BUILDS[] = {
    { 381121, 0x14991a9c0ULL, 0x149913950ULL, 0x48, 0x14300b61aULL,
      { 0x1470f0be6ULL, 0x1470f0d14ULL, 0x140d046c8ULL, 0x1470f0d84ULL, 0x1470f0df4ULL },
      0x14ac5e920ULL, 0x14ac5e934ULL, 0x14ac5e9c8ULL },
    /* hotfix: only debugNameFn and expect[] moved (GUObjectArray 0x14ac5e910 by the 0.9.3 UE4SS signature) */
    { 382493, 0x14991a9c0ULL, 0x149913950ULL, 0x48, 0x14300bd0aULL,
      { 0x1470f1180ULL, 0x1470f12aeULL, 0x140d04678ULL, 0x1470f131eULL, 0x1470f138eULL },
      0x14ac5e920ULL, 0x14ac5e934ULL, 0x14ac5e9c8ULL },
    /* 2026-10-12 hotfix (Steam build 25880680, "Auto-382801"): data block +0x1000 (GUObjectArray
     * 0x14ac5f910 by the fixed GMalloc-era signatures), proc vtable +0x70, code moved non-uniformly;
     * derived statically from the exe (work/perf/vtable-derive.py: GetDebugName string ref -> proc
     * vtable slots; ctor fingerprint -> subsys vtable) and cross-checked on CL382493 first. */
    { 382801, 0x14991aa30ULL, 0x1499139c0ULL, 0x48, 0x14300c26aULL,
      { 0x1470f134aULL, 0x1470f1478ULL, 0x140d04678ULL, 0x1470f14e8ULL, 0x1470f1558ULL },
      0x14ac5f920ULL, 0x14ac5f934ULL, 0x14ac5f9c8ULL },
};
#define NBUILD ((int)(sizeof BUILDS / sizeof BUILDS[0]))
static const Build *g_b;        /* the build install() identified (GetDebugName slot); 0 = unknown */

typedef u8 (*HandlerFn)(void *self, void *app, const u8 *ev);
static HandlerFn g_orig[NSLOT];

typedef struct { u64 subsys; u64 proc; int ctrl; u64 passed, dropped; } Owner;
#define MAXOWN 8
static Owner g_own[MAXOWN];
static int g_nown, g_enabled, g_offset, g_installed;
static u64 g_seq, g_lastCheck, g_cfgTime, g_cfgSize, g_lastResolve, g_unknownPassed;
#define RELOAD_MS 250
static volatile int g_threadOn;                 /* 1 = the reload thread runs: the input path never reloads      */
static volatile i32 g_lock;                     /* guards g_own/g_nown/g_enabled/g_offset (thread vs input path) */
static volatile i32 g_reloading;                /* one reload at a time                                          */
static u64 g_reloads, g_tornRetries;
static int g_tornTries;
static const char *g_reason = "not loaded";
static u64 g_wTag, g_wOk, g_wFail;              /* 'w' command: last applied tag, counters */
static u16 g_cfgPath[600], g_statusPath[600];

/* ---- small helpers (no CRT) ---- */
static int readable(u64 a, u64 n) {
    MBI m;
    if (a < 0x10000 || !VirtualQuery((const void *)a, &m, sizeof m)) return 0;
    if (m.State != 0x1000 || (m.Protect & 0x101) || !(m.Protect & 0xEE)) return 0;   /* commit, no guard/noaccess */
    return a + n <= (u64)m.BaseAddress + m.RegionSize;
}
static u64 rd64(u64 a) { return *(volatile u64 *)a; }
static int writable(u64 a, u64 n) {
    MBI m;
    if (a < 0x10000 || !VirtualQuery((const void *)a, &m, sizeof m)) return 0;
    if (m.State != 0x1000 || (m.Protect & 0x101) || !(m.Protect & 0xCC)) return 0;   /* RW, WC, ERW, EWC only */
    return a + n <= (u64)m.BaseAddress + m.RegionSize;
}
static int prefix(const char *s, const char *pre) { while (*pre) if (*s++ != *pre++) return 0; return 1; }

/* Spin lock for the owner table. Held only for parsing/resolving (no file I/O) or one filter decision. */
static void lockOwners(void) {
    int spins = 0;
    while (__sync_lock_test_and_set(&g_lock, 1)) {
        while (g_lock) { __builtin_ia32_pause(); if (++spins > 4000) { Sleep(0); spins = 0; } }
    }
}
static void unlockOwners(void) { __sync_lock_release(&g_lock); }

/* The compiler may emit calls to these for struct copies even without a CRT. */
void *memcpy(void *d, const void *s, u64 n) { volatile u8 *a = d; const u8 *b = s; while (n--) *a++ = *b++; return d; }
void *memset(void *d, int c, u64 n) { volatile u8 *a = d; while (n--) *a++ = (u8)c; return d; }

static int sappend(char *b, int n, int cap, const char *s) { while (*s && n < cap - 1) b[n++] = *s++; b[n] = 0; return n; }
static int uappend(char *b, int n, int cap, u64 v, int hex) {
    char t[24]; int k = 0;
    if (hex) { n = sappend(b, n, cap, "0x"); do { t[k++] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v); }
    else { do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); }
    while (k && n < cap - 1) b[n++] = t[--k];
    b[n] = 0; return n;
}

/* The processor of a subsystem under build b's layout (both vtables checked); 0 = none. */
static u64 procOf(const Build *b, u64 s) {
    if (!readable(s, b->subsysProc + 8) || rd64(s) != b->subsysVtable) return 0;
    u64 p = rd64(s + b->subsysProc);
    return (readable(p, 8) && rd64(p) == b->procVtable) ? p : 0;
}

/* Resolve each owner's processor from its subsystem address, with the identified build's layout (unknown build:
 * every known set is tried; that only feeds the status, no wrapper is installed then). */
static void resolve(void) {
    for (int i = 0; i < g_nown; i++) {
        Owner *o = &g_own[i];
        o->proc = 0;
        if (g_b) o->proc = procOf(g_b, o->subsys);
        else for (int k = 0; k < NBUILD && !o->proc; k++) o->proc = procOf(&BUILDS[k], o->subsys);
    }
}

/* The GUObjectArray item of obj (readable: the caller checks) under build b's addresses, refused unless the chunk
 * table is readable and the item points back to obj. Returns the item address (0 = not found), obj's InternalIndex
 * in *pidx. */
static u64 objItem(const Build *b, u64 obj, u32 *pidx) {
    if (!readable(b->objChunks, 8) || !readable(b->objNum, 4)) return 0;
    u32 idx = *(volatile u32 *)(obj + OBJ_INDEX);
    u32 num = *(volatile u32 *)b->objNum;
    u64 chunks = rd64(b->objChunks);
    if (idx >= num || !readable(chunks + (u64)(idx >> 16) * 8, 8)) return 0;
    u64 chunk = rd64(chunks + (u64)(idx >> 16) * 8);
    u64 item = chunk + (u64)(idx & 0xffff) * ITEM_STRIDE;
    if (!chunk || !readable(item, ITEM_STRIDE) || rd64(item + 8) != obj) return 0;
    *pidx = idx;
    return item;
}

static void writeStatus(void) {
    static char b[2048]; int n = 0, cap = sizeof b;
    HANDLE h = CreateFileW(g_statusPath, 0x40000000 /*GENERIC_WRITE*/, 1 | 2, 0, 2 /*CREATE_ALWAYS*/, 0x80, 0);
    if (h == INVALID_HANDLE) return;
    lockOwners();       /* snapshot of the owner table; the file write itself happens after the unlock */
    n = sappend(b, n, cap, "installed="); n = uappend(b, n, cap, (u64)g_installed, 0);
    n = sappend(b, n, cap, "\nreason="); n = sappend(b, n, cap, g_reason);
    n = sappend(b, n, cap, "\nbuild=");
    if (g_b) n = uappend(b, n, cap, g_b->cl, 0); else n = sappend(b, n, cap, "unknown");
    n = sappend(b, n, cap, "\nbuilds=");
    for (int k = 0; k < NBUILD; k++) { if (k) n = sappend(b, n, cap, ","); n = uappend(b, n, cap, BUILDS[k].cl, 0); }
    n = sappend(b, n, cap, "\nenabled="); n = uappend(b, n, cap, (u64)g_enabled, 0);
    n = sappend(b, n, cap, "\noffset="); n = uappend(b, n, cap, (u64)g_offset, 0);
    n = sappend(b, n, cap, "\nseq="); n = uappend(b, n, cap, g_seq, 0);
    n = sappend(b, n, cap, "\nunknown_passed="); n = uappend(b, n, cap, g_unknownPassed, 0);
    n = sappend(b, n, cap, "\nw_tag="); n = uappend(b, n, cap, g_wTag, 0);
    n = sappend(b, n, cap, "\nw_ok="); n = uappend(b, n, cap, g_wOk, 0);
    n = sappend(b, n, cap, "\nw_fail="); n = uappend(b, n, cap, g_wFail, 0);
    n = sappend(b, n, cap, "\nreload_thread="); n = uappend(b, n, cap, (u64)g_threadOn, 0);
    n = sappend(b, n, cap, "\nreload_ms="); n = uappend(b, n, cap, RELOAD_MS, 0);
    n = sappend(b, n, cap, "\nreloads="); n = uappend(b, n, cap, g_reloads, 0);
    n = sappend(b, n, cap, "\ntorn_retries="); n = uappend(b, n, cap, g_tornRetries, 0);
    for (int i = 0; i < g_nown; i++) {
        Owner *o = &g_own[i];
        n = sappend(b, n, cap, "\no ctrl="); n = uappend(b, n, cap, (u64)o->ctrl, 0);
        n = sappend(b, n, cap, " subsys="); n = uappend(b, n, cap, o->subsys, 1);
        n = sappend(b, n, cap, " proc="); n = uappend(b, n, cap, o->proc, 1);
        n = sappend(b, n, cap, " passed="); n = uappend(b, n, cap, o->passed, 0);
        n = sappend(b, n, cap, " dropped="); n = uappend(b, n, cap, o->dropped, 0);
    }
    n = sappend(b, n, cap, "\n");
    unlockOwners();
    u32 w = 0; WriteFile(h, b, (u32)n, &w, 0); CloseHandle(h);
}

static u64 parseNum(const char **pp) {
    const char *p = *pp; u64 v = 0;
    while (*p == ' ' || *p == '\t') p++;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        p += 2;
        for (;;) {
            char c = *p; int d;
            if (c >= '0' && c <= '9') d = c - '0'; else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10; else break;
            v = v * 16 + (u64)d; p++;
        }
    } else while (*p >= '0' && *p <= '9') v = v * 10 + (u64)(*p++ - '0');
    *pp = p; return v;
}

/* Reads the cfg into b (NUL-terminated). -1 = no file, else the byte count. No lock needed: only the reload path
 * (serialized by g_reloading) calls it. */
static int readCfg(char *b, u32 cap) {
    HANDLE h = CreateFileW(g_cfgPath, 0x80000000 /*GENERIC_READ*/, 1 | 2 | 4, 0, 3 /*OPEN_EXISTING*/, 0x80, 0);
    if (h == INVALID_HANDLE) { b[0] = 0; return -1; }
    u32 got = 0; ReadFile(h, b, cap - 1, &got, 0); CloseHandle(h); b[got] = 0;
    return (int)got;
}

/* Applies a cfg text (missing = no file: filter off, no owners) under the owner lock, then writes the status. */
static void applyCfg(const char *b, int missing) {
    lockOwners();
    g_reloads++;
    if (missing) { g_enabled = 0; g_nown = 0; unlockOwners(); writeStatus(); return; }
    Owner keep[MAXOWN]; int nkeep = g_nown;
    for (int i = 0; i < nkeep; i++) keep[i] = g_own[i];
    g_nown = 0; g_enabled = 0; g_offset = 0;
    /* 'w'/'wo' lines are applied once per tag. wSeen = the highest tag applied from an EARLIER cfg text: every line of
     * this text above it is applied, whatever the line order (verification 2026-10-09: inputfix.lua lists its pending
     * writes in pairs() order, so a 4-player race start can list tag 3 before tags 1 and 2; comparing each line with
     * the running maximum skipped tags 1 and 2 for good and left those cars unbound). g_wTag stays the maximum. */
    const u64 wSeen = g_wTag;
    for (const char *p = b; *p;) {
        const char *line = p;
        while (*p && *p != '\n') p++;
        if (*p) p++;
        if (line[0] == 'p' && line[1] == ' ' && g_nown < MAXOWN) {
            const char *q = line + 2; int ctrl = (int)parseNum(&q); u64 s = parseNum(&q);
            Owner *o = &g_own[g_nown++]; o->ctrl = ctrl; o->subsys = s; o->proc = 0; o->passed = o->dropped = 0;
            for (int i = 0; i < nkeep; i++)      /* keep counters of an unchanged owner */
                if (keep[i].subsys == s && keep[i].ctrl == ctrl) { o->passed = keep[i].passed; o->dropped = keep[i].dropped; }
        } else if (line[0] == 'w' && line[1] == 'o' && line[2] == ' ') {
            /* 'wo <tag> <dst> <obj>': build a TWeakObjectPtr {ObjectIndex, SerialNumber} for <obj> and store it at
             * <dst>. Index = UObjectBase::InternalIndex (+0x0c). Serial from GUObjectArray: chunk table pointer at
             * 0x14ac5e920 (both builds), 65536 items per chunk, item stride 24, Object at +8, SerialNumber at +0x10
             * (layout read from UPlayerInputComponent::GetActionValue 0x1401f4b00, the same address and code in both
             * builds). Refused unless the item points back to <obj> (objItem). The identified build's GUObjectArray
             * is used; on an unknown build each known set is tried (as the single fixed set was before). */
            const char *q = line + 3; u64 tag = parseNum(&q), dst = parseNum(&q), obj = parseNum(&q);
            if (tag > wSeen) {
                int done = 0;
                if (readable(obj, 0x10) && writable(dst, 8)) {
                    const Build *b = g_b; u32 idx = 0; u64 item = 0;
                    if (b) item = objItem(b, obj, &idx);
                    else for (int k = 0; k < NBUILD && !item; k++) { b = &BUILDS[k]; item = objItem(b, obj, &idx); }
                    if (item) {
                        u32 serial = *(volatile u32 *)(item + 0x10);
                        if (!serial && writable(b->serialCounter, 4)) {
                            /* FUObjectArray::AllocateSerialNumber, as inlined at 0x14013e805 (both builds):
                             * MasterSerialNumber (GUObjectArray+0xb8) += 1; the old value must be > 999
                             * (START_SERIAL_NUMBER); CAS item.SerialNumber 0 -> new, keep the winner if another
                             * thread was first. (Port: writable, was readable: this is an atomic add.) */
                            i32 old = __sync_fetch_and_add((volatile i32 *)b->serialCounter, 1);
                            if (old > 999) {
                                u32 want = (u32)old + 1;
                                u32 prev = __sync_val_compare_and_swap((volatile u32 *)(item + 0x10), 0u, want);
                                serial = prev ? prev : want;
                            }
                        }
                        if (serial) {
                            /* 0.6.0: this now runs on the reload thread, not the game's input thread: one
                             * aligned 8-byte store, so the game never reads a half-written {index, serial}. */
                            if ((dst & 7) == 0) *(volatile u64 *)dst = (u64)idx | ((u64)serial << 32);
                            else { *(volatile u32 *)dst = idx; *(volatile u32 *)(dst + 4) = serial; }
                            done = 1;
                        }
                    }
                }
                if (done) g_wOk++; else g_wFail++;
                if (tag > g_wTag) g_wTag = tag;
            }
        } else if (line[0] == 'w' && line[1] == ' ') {
            /* SWGRCouch: one-shot checked copy, e.g. a TWeakObjectPtr from GfnPlayerController+0x8d8 into
             * PlayerInputComponent+0xc0 (UE4SS cannot write that weak property from Lua). Applied once per tag. */
            const char *q = line + 2; u64 tag = parseNum(&q), dst = parseNum(&q), src = parseNum(&q), len = parseNum(&q);
            if (tag > wSeen && len >= 1 && len <= 16) {
                if (readable(src, len) && writable(dst, len)) {
                    volatile u8 *d = (volatile u8 *)dst; const volatile u8 *sp = (const volatile u8 *)src;
                    for (u64 i = 0; i < len; i++) d[i] = sp[i];
                    g_wOk++;
                } else g_wFail++;
                if (tag > g_wTag) g_wTag = tag;
            }
        } else if (prefix(line, "enabled=")) { const char *q = line + 8; g_enabled = (int)parseNum(&q); }
        else if (prefix(line, "offset=")) { const char *q = line + 7; g_offset = (int)parseNum(&q); }
        else if (prefix(line, "seq=")) { const char *q = line + 4; g_seq = parseNum(&q); }
    }
    resolve();
    g_lastResolve = GetTickCount64();
    unlockOwners();
    writeStatus();
}

/* Re-reads the cfg when its write time or size changed (force = always). fromThread = called by the reload thread;
 * the input path (fromThread 0) only reloads when that thread is not running, at most every RELOAD_MS. */
static void maybeReload(int fromThread, int force) {
    static char b[4096];
    if (!fromThread && g_threadOn && !force) return;
    if (__sync_lock_test_and_set(&g_reloading, 1)) return;     /* another reload is running: it will see the change */
    u64 now = GetTickCount64();
    if (fromThread || force || now - g_lastCheck >= RELOAD_MS) {
        g_lastCheck = now;
        FILEATTR fa;
        int have = GetFileAttributesExW(g_cfgPath, 0, &fa) != 0;
        u64 t = have ? (((u64)fa.w_hi << 32) | fa.w_lo) : 0;
        u64 sz = have ? (((u64)fa.size_hi << 32) | fa.size_lo) : 0;
        if (force || t != g_cfgTime || sz != g_cfgSize) {
            int got = readCfg(b, sizeof b);
            /* Lua rewrites the cfg with truncate + write: an empty or unterminated text may be a torn read. Leave the
             * stored time/size alone so the next check reads again; apply it as it is after 4 tries. */
            int torn = got == 0 || (got > 0 && b[got - 1] != '\n');
            if (torn && !force && g_tornTries < 4) { g_tornTries++; g_tornRetries++; }
            else {
                g_tornTries = 0; g_cfgTime = t; g_cfgSize = sz;
                applyCfg(b, got < 0);
            }
        }
    }
    __sync_lock_release(&g_reloading);
}

/* Reload thread (run G, F4d): applies a cfg change (owner table, 'w'/'wo' binds) within RELOAD_MS even when no
 * input event arrives. Started from DllMain; it runs until the process exits (the module is pinned). */
static u32 __stdcall reloadThread(void *arg) {
    (void)arg;
    for (;;) { Sleep(RELOAD_MS); maybeReload(1, 0); }
    return 0;
}

/* ---- filter ---- */
static Owner *findOwner(u64 proc) {
    for (int i = 0; i < g_nown; i++) if (g_own[i].proc == proc) return &g_own[i];
    return 0;
}

/* 1 = let the original record this event for `self`, 0 = drop it. */
static int allow(void *self, const u8 *ev, int isPad) {
    maybeReload(0, 0);                          /* no-op while the reload thread runs */
    if (!g_enabled) return 1;                   /* unlocked fast path: a stale read only delays the change by 1 event */
    int res = 1;
    lockOwners();
    if (g_enabled && g_nown > 0) {
        Owner *o = findOwner((u64)self);
        if (!o) {
            u64 now = GetTickCount64();         /* a processor may have been (re)created: resolve again, rate-limited */
            if (now - g_lastResolve > 500) { g_lastResolve = now; resolve(); o = findOwner((u64)self); }
        }
        if (!o) g_unknownPassed++;
        else {
            int owner = (int)*(const u32 *)(ev + EV_USERINDEX) + ((g_offset && isPad) ? 1 : 0);
            if (owner == o->ctrl) o->passed++;
            else { o->dropped++; res = 0; }
        }
    }
    unlockOwners();
    return res;
}

static int keyIsPad(const u8 *ev) {
    return *(const u32 *)(ev + KEV_CHARCODE) == 0 && *(const u32 *)(ev + KEV_KEYCODE) == 0;
}

static u8 W_KeyDown(void *s, void *a, const u8 *e) { return allow(s, e, keyIsPad(e)) ? g_orig[K_DOWN](s, a, e) : 0; }
/* Releases of the KEYBOARD and MOUSE always pass: a key held while the filter switches on (cfg rewritten at a phase
 * change, owner table or offset changed) was recorded as down by every processor, and dropping its release would
 * leave it down for the non-owners for the rest of the race (a guest cannot send that keyboard key itself: stuck
 * throttle/boost). Passing it is harmless: a non-owner never got the matching press after enable. PAD releases stay
 * filtered: gamepad FKeys are the same for every pad, so pad 1's release of A would also release P2's held A
 * (a pad key stuck on a guest is cleared by the guest's own press/release of it). */
static u8 W_KeyUp(void *s, void *a, const u8 *e) {
    if (!keyIsPad(e)) { maybeReload(0, 0); return g_orig[K_UP](s, a, e); }
    return allow(s, e, 1) ? g_orig[K_UP](s, a, e) : 0;
}
static u8 W_Analog(void *s, void *a, const u8 *e)  { return allow(s, e, 1) ? g_orig[K_ANALOG](s, a, e) : 0; }
static u8 W_MDown(void *s, void *a, const u8 *e)   { return allow(s, e, 0) ? g_orig[K_MDOWN](s, a, e) : 0; }
static u8 W_MUp(void *s, void *a, const u8 *e)     { maybeReload(0, 0); return g_orig[K_MUP](s, a, e); }  /* see W_KeyUp */
static const HandlerFn WRAP[NSLOT] = { W_KeyDown, W_KeyUp, W_Analog, W_MDown, W_MUp };

/* ---- install ---- */
/* Build b against the live processor vtable: 0 = matches (unpatched), 1 = already patched by this module,
 * -1 = vtable not readable, -2 = GetDebugName slot differs, -3 = handler slot index *bad differs. */
static int checkBuild(const Build *b, int *bad) {
    const volatile u64 *vt = (const volatile u64 *)b->procVtable;
    if (!readable(b->procVtable, 8 * 16)) return -1;
    if (vt[DEBUGNAME_SLOT] != b->debugNameFn) return -2;
    int already = 1;
    for (int i = 0; i < NSLOT; i++) if (vt[SLOT[i]] != (u64)WRAP[i]) already = 0;
    if (already) return 1;
    for (int i = 0; i < NSLOT; i++) if (vt[SLOT[i]] != b->expect[i]) { *bad = i; return -3; }
    return 0;
}

/* g_reason when no set matched: the kind of the closest mismatch, then what each set expected. */
static char g_reasonBuf[512];
static void mismatchReason(const int *verdict, const int *bad) {
    char *b = g_reasonBuf; int n = 0, cap = sizeof g_reasonBuf, anyHandler = 0, anyName = 0;
    for (int k = 0; k < NBUILD; k++) { if (verdict[k] == -3) anyHandler = 1; if (verdict[k] == -2) anyName = 1; }
    n = sappend(b, n, cap, anyHandler ? "mismatch: handler slot (" : anyName ? "mismatch: GetDebugName slot ("
                                                                             : "vtable not readable (");
    for (int k = 0; k < NBUILD; k++) {
        const Build *s = &BUILDS[k];
        const volatile u64 *vt = (const volatile u64 *)s->procVtable;
        if (k) n = sappend(b, n, cap, "; ");
        n = uappend(b, n, cap, s->cl, 0);
        if (verdict[k] == -1) {
            n = sappend(b, n, cap, ": vtable "); n = uappend(b, n, cap, s->procVtable, 1);
            n = sappend(b, n, cap, " not readable");
        } else if (verdict[k] == -2) {
            n = sappend(b, n, cap, ": GetDebugName slot "); n = uappend(b, n, cap, vt[DEBUGNAME_SLOT], 1);
            n = sappend(b, n, cap, " != "); n = uappend(b, n, cap, s->debugNameFn, 1);
        } else {
            int i = bad[k];
            n = sappend(b, n, cap, ": handler slot "); n = uappend(b, n, cap, (u64)SLOT[i], 0);
            n = sappend(b, n, cap, " "); n = uappend(b, n, cap, vt[SLOT[i]], 1);
            n = sappend(b, n, cap, " != "); n = uappend(b, n, cap, s->expect[i], 1);
        }
    }
    n = sappend(b, n, cap, ")");
    g_reason = g_reasonBuf;
}

static void install(void) {
    int verdict[NBUILD], bad[NBUILD];
    const Build *pick = 0;
    int pv = 0;
    for (int k = 0; k < NBUILD; k++) {
        bad[k] = 0;
        verdict[k] = checkBuild(&BUILDS[k], &bad[k]);
        if (verdict[k] >= 0 && !pick) { pick = &BUILDS[k]; pv = verdict[k]; }
    }
    if (!pick) {
        /* nothing patched; a set whose GetDebugName matched still names the build (status, resolve, 'wo') */
        for (int k = 0; k < NBUILD && !g_b; k++) if (verdict[k] == -3) g_b = &BUILDS[k];
        mismatchReason(verdict, bad);
        return;
    }
    g_b = pick;
    volatile u64 *vt = (volatile u64 *)pick->procVtable;
    for (int i = 0; i < NSLOT; i++) g_orig[i] = (HandlerFn)pick->expect[i];
    if (pv == 1) { g_installed = 1; g_reason = "ok (already patched)"; return; }
    u32 old = 0, tmp = 0;
    void *page = (void *)(pick->procVtable + 8 * 2);
    if (!VirtualProtect(page, 8 * 6, 0x04 /*PAGE_READWRITE*/, &old)) { g_reason = "VirtualProtect failed"; return; }
    for (int i = 0; i < NSLOT; i++) vt[SLOT[i]] = (u64)WRAP[i];     /* aligned 8-byte stores: atomic */
    VirtualProtect(page, 8 * 6, old, &tmp);
    g_installed = 1;
    g_reason = "ok";
}

static void makePaths(void *self) {
    u32 n = GetModuleFileNameW(self, g_cfgPath, 500);
    while (n && g_cfgPath[n - 1] != '\\' && g_cfgPath[n - 1] != '/') n--;
    static const char cfgName[] = "swgr_inputfilter.cfg", stName[] = "swgr_inputfilter.status";
    for (u32 i = 0; i < n; i++) g_statusPath[i] = g_cfgPath[i];
    u32 k = 0;
    for (; cfgName[k]; k++) g_cfgPath[n + k] = (u16)cfgName[k];
    g_cfgPath[n + k] = 0;
    for (k = 0; stName[k]; k++) g_statusPath[n + k] = (u16)stName[k];
    g_statusPath[n + k] = 0;
}

BOOL __stdcall DllMain(void *self, u32 reason, void *reserved) {
    (void)reserved;
    if (reason != 1 /*DLL_PROCESS_ATTACH*/) return 1;
    static int done;
    if (done) return 1;
    done = 1;
    DisableThreadLibraryCalls(self);
    void *pinned = 0;   /* GET_MODULE_HANDLE_EX_FLAG_PIN | FROM_ADDRESS: never unloaded (the vtable points here) */
    GetModuleHandleExW(0x1 | 0x4, (const void *)&DllMain, &pinned);
    makePaths(self);
    install();
    /* Reload thread (F4d). Creating a thread in DllMain is allowed; it starts running after the loader lock is
     * released (DllMain never waits for it). On failure the input path keeps reloading as before (reload_thread=0). */
    u32 tid = 0;
    HANDLE th = CreateThread(0, 64 * 1024, reloadThread, 0, 0, &tid);
    if (th) { g_threadOn = 1; CloseHandle(th); }
    maybeReload(0, 1);  /* first read, forced: also writes the status file */
    return 1;
}
