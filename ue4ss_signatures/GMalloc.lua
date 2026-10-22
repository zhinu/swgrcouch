-- GMalloc for STAR WARS: Galactic Racer (SWGR-Win64-Shipping.exe, UE 5.7.4, image base 0x140000000).
-- 1.0.2 (game update 2026-10-22, Steam build 26133805, "Auto-386500"): the old anchor (the GUObjectArray lea, GMalloc
-- a constant 0xEA148 below its target) broke: that data gap grew to 0xEA178, so the old file pointed 0x30 past
-- GMalloc. Now the anchor is a direct GMalloc user, a virtual call through the FMalloc instance:
--   48 8B 0D <d32>     mov  rcx, [rip+GMalloc]
--   48 8B 01           mov  rax, [rcx]
--   48 89 FA           mov  rdx, rdi
--   FF 50 48           call [rax+48h]
--   E9 <rel32>         jmp  ...
--   8B 46 F8           mov  eax, [rsi-8]
-- Exactly 1 match in each of CL381121, CL382493, CL382801 and CL386500, resolving to that build's GMalloc
-- (0x14AB747C8, 0x14AB747C8, 0x14AB757C8, 0x14AB827D8: the global with ~740 FMemory call sites in each build).
-- GMalloc comes straight from the instruction's own disp32, so no data-layout delta is assumed any more.
function Register()
    return "48 8B 0D ? ? ? ? 48 8B 01 48 89 FA FF 50 48 E9 ? ? ? ? 8B 46 F8"
end

function OnMatchFound(MatchAddress)
    -- mov rcx,[rip+disp32]: disp32 at +3, next instruction at +7
    local Disp = DerefToInt32(MatchAddress + 0x3)
    if Disp == nil then return nil end
    return MatchAddress + 0x7 + Disp
end
