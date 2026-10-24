-- RLSMP TeamX: ownership decisions shared by the compatibility patches.
local M = {}
local localSpawns = {}

function M.isMultiplayer()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil
    and MPCoreNetwork.isMPSession() == true
end

function M.isAuthorized()
  return M.isMultiplayer() and rlsmpTeamx ~= nil and rlsmpTeamx.isAuthorized()
end

function M.markLocal(vehicle)
  if vehicle and vehicle.getID then localSpawns[vehicle:getID()] = true end
end

function M.forget(id) localSpawns[id] = nil end
function M.clear() localSpawns = {} end

function M.canManageVehicle(id)
  if not M.isMultiplayer() then return true end
  if rlsmpTeamx and rlsmpTeamx.isTrafficVehicle and rlsmpTeamx.isTrafficVehicle(id) then return false end
  if not MPVehicleGE or not MPVehicleGE.getVehicleByGameID then return false end
  local vehicle = MPVehicleGE.getVehicleByGameID(id)
  if vehicle then return vehicle.isLocal == true end
  -- A local spawn can be used by RLS before its server acknowledgement arrives.
  -- Remote BeamMP spawns use spawn.spawnVehicle, not core_vehicles.spawnNewVehicle.
  return localSpawns[id] == true
end

function M.removeLocalVehicles()
  if not M.isAuthorized() then return false end
  for i = be:getObjectCount() - 1, 0, -1 do
    local vehicle = be:getObject(i)
    if vehicle and M.canManageVehicle(vehicle:getID()) then vehicle:delete() end
  end
  return true
end

function M.allowProfile(profile)
  if profile == nil then return true end
  if not M.isMultiplayer() then return true end
  return M.isAuthorized() and rlsmpTeamx.isOwnedProfile(profile)
end

return M
