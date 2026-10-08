-- STAR WARS: Galactic Racer (UE 5.7.4, SWGR-Win64-Shipping.exe 488,290,328 bytes, image base 0x140000000)
-- Target: public: void __cdecl FName::ToString(class FString &) const   (the overload UE4SS documents)
-- Resolves to 0x14010237A (section .data1). Pattern matches exactly once in the whole mapped image.
--
-- Why the built-in scan failed: patternsleuth's prologue AOB
--   "56 57 48 83 EC 28 48 89 D6 48 89 CF 83 79 ?? 00 74"
-- hits two unrelated small helpers here (0x14578D562 / 0x14578F85E): they test a TArray Num at
-- [rcx+8], append a global and then process this+0x10 -- neither touches the FName pool, so
-- neither is FName::ToString.
--
-- Identification: UKismetStringLibrary::execConv_NameToString (0x1411187A2, from the native
-- table entry "Conv_NameToString") calls FString FName::ToString() const at 0x143752404; its
-- Number != 0 branch does "FString Out; ToString(Out);" -> call 0x14010237A, which is this
-- function: reads ComparisonIndex, lazy-inits FNamePool, entry = Blocks[Index>>16] + (Index&0xFFFF)*2,
-- len = header>>6, then tests Number ([this+4]) and Empty()s Out before appending.
-- Its near-twin 0x1402A44CC (same prologue, no Number test before append, no Empty) is
-- FName::AppendString(FString&) and is excluded by the "83 7F 04 00" tail.

function Register()
    return "41 57 41 56 41 55 41 54 56 57 55 53 48 81 EC ?? ?? ?? ?? 48 89 D6 48 89 CF 48 8B 05 ?? ?? ?? ?? 48 31 E0 48 89 84 24 ?? ?? ?? ?? 8B 19 80 3D ?? ?? ?? ?? 00 0F 84 ?? ?? ?? ?? 89 D8 C1 E8 10 48 8D 0D ?? ?? ?? ?? 48 8B 44 C1 10 0F B7 CB 48 8D 1C 48 0F B7 03 41 89 C0 41 C1 E8 06 83 7F 04 00"
end

function OnMatchFound(MatchAddress)
    -- The pattern starts at the first byte of the function.
    return MatchAddress
end
