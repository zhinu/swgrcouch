-- netfix.lua (G7 Network): small network compatibility fixes kept apart from the flow logic
-- (ARCHITECTURE.md §2.1 Iris, §2.5 core-object ack, §2.6 PvP safety cvars; §4.2 netfix).
--
--  * Core-object ack (risk R6): the race flow asks every PlayerController to confirm that the replicated core
--    objects arrived (UPvpFlowComponent::Client_RequestAckObjects -> Server_NotifyCoreObjectsArrived). The native
--    client handler may only answer for the first local player; split-screen guests would then hold the host
--    in WaitForClientsToBeReady. We answer for the guests (or every local PC) ourselves.
--  * Iris: optional `net.Iris.UseIrisReplication 0` before any net driver exists (both machines must agree).
--  * PvP safety cvars: optional list run when hosting starts.

local cfg = require("config")
local C = require("consts")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "netfix"

local IRIS_CVAR = "net.Iris.UseIrisReplication"
local ACK_DELAY_MS = 500     -- after the native handler ran (post-hook) [§2.5]
local ACK_DEDUP_MS = 250     -- one scheduled ack per component per burst of requests

local irisApplied = false
local lastAckMs = {}         -- component address -> St.nowMs() of the last scheduled ack

-- Post-hook of /Script/Griffin.PvpFlowComponent:Client_RequestAckObjects() (0 params; NetClient|NetReliable
-- RPC, flags 0x1020cc0 [reflect-func-all]). It fires where the RPC executes: on a client for its local PCs,
-- on a listen host for the host's own local PCs (a client RPC on a local controller runs locally).
function M.onAckRequested(ctx)
  local mode = cfg.GuestAckMode
  if mode == "off" then return end
  local comp = ctx:get()
  if not U.ok(comp) then return end
  -- ActorComponent:GetOwner() -> Object (0 params) [reflect-func-all]; the component lives on the PC.
  local owner = comp:GetOwner()
  if not U.ok(owner) or not U.isPlayerController(owner) then return end
  -- AController:IsLocalController() -> Bool (0 params) [reflect-func-all].
  if not owner:IsLocalController() then return end
  local isP1 = U.same(owner, U.p1())
  if mode == "guests" and isP1 then return end
  local key = U.key(comp)
  local now = St.nowMs()
  if lastAckMs[key] and now - lastAckMs[key] < ACK_DEDUP_MS then return end
  lastAckMs[key] = now
  U.log(TAG, "Client_RequestAckObjects for local PC %s (P1=%s, mode=%s): extra ack in %d ms",
    tostring(U.key(owner)), tostring(isP1), tostring(mode), ACK_DELAY_MS)
  sched.after(TAG, ACK_DELAY_MS, function()
    if not U.ok(comp) then
      U.dbg(TAG, "ack: component gone before the delayed ack")
      return
    end
    -- UPvpFlowComponent:Server_NotifyCoreObjectsArrived() (0 params; NetServer|NetReliable RPC, flags 0x220cc0,
    -- not BlueprintCallable: UE4SS calls it through ProcessEvent anyway [NET§6.2 H6]).
    -- VERIFY(V-NET-09): a duplicate ack is harmless and the host leaves WaitForClientsToBeReady;
    -- fallback cfg.GuestAckMode = "all", then "off".
    comp:Server_NotifyCoreObjectsArrived()
    U.log(TAG, "Server_NotifyCoreObjectsArrived sent for PC %s", tostring(U.key(owner)))
  end)
end

-- Run once, on the first "world" event: a world exists for ExecuteConsoleCommand and the standalone front end
-- has no net driver yet, so the replication system is chosen before the first listen/connect.
function M.applyIris()
  if cfg.IrisOff then
    -- VERIFY(V-NET-03): the cvar is writable at runtime and reads back 0; client guests (child connections)
    -- replicate. Fallback: -UseIrisReplication=0 on the command line of BOTH machines (Lutris arguments).
    U.console(IRIS_CVAR .. " 0")
    local v = U.cvarInt(IRIS_CVAR) -- nil when unreadable; never throws (util.lua)
    U.log(TAG, "IrisOff: %s 0 -> reads back %s", IRIS_CVAR, v ~= nil and tostring(v) or "?")
    if type(v) ~= "number" then
      U.warn(TAG, "%s could not be read back (V-NET-03 unverified)", IRIS_CVAR)
    elseif v ~= 0 then
      U.warn(TAG, "%s is still %d: use -UseIrisReplication=0 on both machines", IRIS_CVAR, v)
    end
  else
    local v = U.cvarInt(IRIS_CVAR)
    U.log(TAG, "Iris left as shipped: %s = %s (both machines must match)", IRIS_CVAR, v ~= nil and tostring(v) or "?")
  end
end

-- Run by net.startHosting(). Candidates (empty by default): "Pvp.FakeProgressionAuthKillswitch 1".
-- VERIFY(V-NET-12): no AFK kick / player-data disconnect in self-hosted races; else add cvars here via config.
function M.applySafetyCvars()
  local list = cfg.NetSafetyCvars
  if type(list) ~= "table" or #list == 0 then return end
  for i = 1, #list do
    local cmd = list[i]
    if type(cmd) == "string" and cmd ~= "" then
      U.try(TAG, function()
        U.console(cmd)
        U.log(TAG, "safety cvar: %s", cmd)
      end)
    end
  end
end

function M.init()
  U.hook(C.FN.AckRequest, { post = M.onAckRequested }, TAG)
  St.on("world", TAG, function(world)
    lastAckMs = {}
    if irisApplied then return end
    irisApplied = true
    M.applyIris()
  end)
end

return M
