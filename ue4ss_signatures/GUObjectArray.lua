-- STAR WARS: Galactic Racer (UE 5.7.4, SWGR-Win64-Shipping.exe 488,290,328 bytes) - GUObjectArray
-- Install as: Griffin/Binaries/Win64/ue4ss/UE4SS_Signatures/GUObjectArray.lua
--
-- Anchor: InitUObject() (CoreUObject/Private/UObject/UObjectBase.cpp). It reads gc.MaxObjectsNotConsideredByGC,
-- gc.MaxObjectsInGame and gc.PreAllocateUObjectArray, then calls
--   GUObjectArray.AllocateObjectPool(MaxUObjects, MaxObjectsNotConsideredByGC, bPreAllocateUObjectArray)
-- which compiles to:
--   C6 05 xx xx xx xx 01        mov  byte ptr [rip+..], 1
--   44 8A 4C 24 2F              mov  r9b, [rsp+2F]        ; bPreAllocateUObjectArray
--   8B 54 24 30                 mov  edx, [rsp+30]        ; MaxUObjects
--   48 8D 0D xx xx xx xx        lea  rcx, [rip+GUObjectArray]   <- MatchAddress + 0x10
--   E8 xx xx xx xx              call FUObjectArray::AllocateObjectPool
-- Static check on the exe: exactly 1 match (VA 0x14238D404, .data1) -> GUObjectArray = 0x14AC5E910 (.link)

function Register()
    return "C6 05 ?? ?? ?? ?? 01 44 8A 4C 24 ?? 8B 54 24 ?? 48 8D 0D ?? ?? ?? ?? E8"
end

function OnMatchFound(MatchAddress)
    local LeaInstr = MatchAddress + 0x10
    local NextInstr = LeaInstr + 0x7
    local Disp = DerefToInt32(LeaInstr + 0x3)
    if Disp == nil then
        return nil
    end
    return NextInstr + Disp
end
