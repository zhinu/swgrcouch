function Register()
    return "48 8D 0D ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? C6 05 ? ? ? ? 01"
end

function OnMatchFound(MatchAddress)
    local ImageBase = MatchAddress - 0x238D414
    return ImageBase + 0xAB747C8
end
