-- STAR WARS: Galactic Racer (UE 5.7.4, SWGR-Win64-Shipping.exe, 488,290,328 bytes, build Auto-381121)
-- public: __cdecl FName::FName(wchar_t const *, enum EFindName)
--   rcx = this (FName*), rdx = const TCHAR* Name, r8d = EFindName; returns this in rax.
-- Resolves to 0x143C7DB26 (image base 0x140000000), in section .data1.
-- Body (UE 5.7 UnrealNames.cpp, FName(const WIDECHAR*, EFindName) -> MakeDetectNumber(MakeUnconvertedView)):
--   wcslen + pure-ANSI check (OR of chars, cmp 0x7F), ParseNumber @0x140101D7F ('_' + digits),
--   narrow copy into a 0x400 stack buffer, then FName store/find @0x143893284 with edx = FindType (from r8d),
--   writes (Number << 32 | ComparisonIndex) to *this.
-- NOT the FNAME_Add-only clone @0x143946AA8 (hard-codes edx = 1) and NOT FName(int32 Len, const WIDECHAR*, EFindName) @0x143C835A8.
-- Pattern matches exactly once in the mapped image (verified offline, scripts/sig/fname/verify_fname_ctor.py).

function Register()
    return "41 56 56 57 53 48 81 EC 48 04 00 00 44 89 C3 48 89 CE 48 8B 05 ?? ?? ?? ?? 48 31 E0 48 89 84 24 40 04 00 00 48 89 54 24 20 31 FF 48 85 D2 0F 84 ?? ?? ?? ?? 44 0F B7 02 31 C0 48 89 D1 66 45 85 C0 74"
end

function OnMatchFound(MatchAddress)
    -- The pattern starts at the first byte of the function (push r14).
    return MatchAddress
end
