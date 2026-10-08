-- GNatives for STAR WARS: Galactic Racer (SWGR-Win64-Shipping.exe, UE 5.7.4, image base 0x140000000).
-- UE4SS loads this as <working dir>/UE4SS_Signatures/GNatives.lua and stores the returned
-- address in Unreal::GNatives_Internal (FNativeFuncPtr GNatives[EX_Max]).
--
-- Anchor: ScriptCore.cpp static init, inlined GRegisterNative(EX_CallMath = 0x68, &UObject::execCallMathFunction):
--   48 8D 3D <d32>         lea  rdi, [rip+UObject::execUndefined]     ; 0x144FA8E68
--   48 39 3D <d32>         cmp  [rip+GNatives+0x68*8], rdi           ; GNatives[EX_CallMath] != &execUndefined ?
--   74 0A                  je   +0x0A
--   C7 05 <d32> 68000000   mov  dword [rip+GNativeDuplicate], 0x68
--   48 89 35 <d32>         mov  [rip+GNatives+0x68*8], rsi           ; GNatives[EX_CallMath] = Func
-- Exactly 1 match in the mapped image (scripts/sig/gnatives_check_lua.py). Pattern found at 0x14238719A.
-- Result: GNatives = 0x14AA40040 (.link), the same base that the ~1100 inlined FFrame::Step sites use
-- ("lea r9,[rip+GNatives]; call [r9+rax*8]").
function Register()
    return "48 8D 3D ?? ?? ?? ?? 48 39 3D ?? ?? ?? ?? 74 0A C7 05 ?? ?? ?? ?? 68 00 00 00 48 89 35"
end

function OnMatchFound(MatchAddress)
    -- cmp qword ptr [rip+disp32], rdi starts at +0x07: disp32 at +0x0A, next instruction at +0x0E
    local Disp = DerefToInt32(MatchAddress + 0x0A)
    if Disp == nil then
        return nil
    end
    local Slot = MatchAddress + 0x0E + Disp   -- &GNatives[0x68]
    return Slot - 0x68 * 8                    -- &GNatives[0]
end
