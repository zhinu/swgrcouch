function Register()
    return "48 8D 0D ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? C6 05 ? ? ? ? 01"
end

function OnMatchFound(MatchAddress)
    -- lea rcx,[rip+disp32]: target = next instruction + disp32. The target is a data-section
    -- neighbour of GMalloc, 0xEA148 above it - verified identical in CL382493 and the 2026-10-12
    -- hotfix (build 25880680), where the whole data block moved +0x1000 and the delta held while a
    -- hardcoded RVA broke ("Fatal Error: Tried to call 'FMemory::Realloc' before the FMalloc
    -- instance was found"). Deriving from the instruction survives uniform data shifts.
    local Disp = DerefToInt32(MatchAddress + 0x3)
    if Disp == nil then return nil end
    local LeaTarget = MatchAddress + 0x7 + Disp
    return LeaTarget - 0xEA148
end
