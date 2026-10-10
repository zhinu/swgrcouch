-- FUObjectHashTables::Get() for STAR WARS: Galactic Racer
-- (SWGR-Win64-Shipping.exe, UE 5.7.4, 488,290,328 bytes, image base 0x140000000, clang-cl build).
-- Install as: <Win64>/ue4ss/UE4SS_Signatures/GUObjectHashTables.lua
-- UE4SS (Signatures.cpp) passes the returned address to FUObjectHashTables::SetupGetAddress().
--
-- Get() exists out of line at 0x14456B86A (13 direct callers; elsewhere it is inlined):
--   sub rsp,28h; mov eax,[guard]; mov ecx,[_tls_index]; mov rdx,gs:[58h]; mov rcx,[rdx+rcx*8]
--   cmp eax,[rcx+0E8h]; jg init; lea rax,[Singleton 0x14AC5E6A0]; add rsp,28h; ret
--   init: _Init_thread_header / ctor(0x144B44290) / atexit / _Init_thread_footer
-- Singleton size 0x268 (guard sits right after it at 0x14AC5E908), matching the 5.7 layout.
--
-- Anchor: GetObjectExternalPackageInternal (UObjectHash.cpp), unique in the whole image:
--   push rsi; sub rsp,20h; mov rsi,rcx; call Get; lea rcx,[rax+218h] (ObjectToPackageMap); mov rdx,rsi; call TMap::Find
-- The CALL at +8 is decoded; Get()'s own prologue is then checked so a stale match fails safely.
-- Found/verified by the project's signature scripts (ht_img.py + ht_xref.py).
local CALL_OFFSET = 0x8
local GET_PROLOGUE_0  = 0x28EC8348 -- 48 83 EC 28            (sub rsp, 0x28)
local GET_PROLOGUE_10 = 0x148B4865 -- 65 48 8B 14 at Get+0x10 (mov rdx, gs:[0x58])

function Register()
    return "56 48 83 EC 20 48 89 CE E8 ?? ?? ?? ?? 48 8D 88 18 02 00 00 48 89 F2 E8"
end

function OnMatchFound(MatchAddress)
    local Call = MatchAddress + CALL_OFFSET
    local Rel = DerefToInt32(Call + 1)
    if Rel == nil then return nil end
    local Get = Call + 5 + Rel
    if DerefToInt32(Get) ~= GET_PROLOGUE_0 or DerefToInt32(Get + 0x10) ~= GET_PROLOGUE_10 then
        print("[GUObjectHashTables.lua] Get() prologue mismatch, signature needs updating\n")
        return nil
    end
    return Get
end
