-- UE4SS_Signatures/GMalloc.lua  (STAR WARS: Galactic Racer, UE 5.7.4, SWGR-Win64-Shipping.exe 488,290,328 bytes)
-- Target: GMalloc (FMalloc* global). Expected VA (image base 0x140000000, no relocs): 0x14AB747C8
--
-- Anchor: FMemory::MallocExternal(SIZE_T Count, uint32 Alignment) @ 0x144507A24
--   push rsi; push rdi; sub rsp,28h; mov esi,edx; mov rdi,rcx
--   mov rcx,[rip+GMalloc]        <- MatchAddress+0x0B (disp32 at +0x0E, next-ip = +0x12)
--   test rcx,rcx; jnz +0C; call FMemory::GCreateMalloc
--   mov rcx,[rip+GMalloc]; mov rax,[rcx]; mov rax,[rax+28h]  (FMalloc::Malloc vtable slot)
-- Cross-checked: GCreateMalloc_ThreadUnsafe (0x14000668F) stores BaseAllocator() into the same global,
-- and the inlined operator new / FMemory::Malloc fast path (0x143701794) loads it.
-- Pattern matches exactly once over all image sections (static scan of the exe).

function Register()
    return "56 57 48 83 EC 28 89 D6 48 89 CF 48 8B 0D ?? ?? ?? ?? 48 85 C9 75 0C E8 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? 48 8B 01 48 8B 40 28"
end

function OnMatchFound(MatchAddress)
    local MovInstr = MatchAddress + 0x0B
    local Offset = DerefToInt32(MovInstr + 0x3)
    if Offset == nil then
        return nil
    end
    local RIP = MovInstr + 0x7
    return RIP + Offset
end
