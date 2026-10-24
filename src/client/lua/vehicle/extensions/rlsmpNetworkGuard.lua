-- Protect BeamMP's prediction state across career pauses. No clock or time-of-day changes.
local M = {}
local hooks = {}
local owner
local paused, lastSpeed, unhealthy = false, 1, false
local requestedSpeed = 1

local function finite(n, bound)
  return type(n) == 'number' and n == n and math.abs(n) < (bound or math.huge)
end

local function resetPrediction()
  if owner and owner.onReset then owner.onReset() end
end

local function validPhysics()
  local forward, up
  for _, name in ipairs({'getPositionXYZ', 'getVelocityXYZ', 'getDirectionVectorXYZ',
      'getDirectionVectorUpXYZ', 'getRollPitchYawAngularVelocity'}) do
    if not obj[name] then return false end
    local x, y, z = obj[name](obj)
    if not finite(x, 1e9) or not finite(y, 1e9) or not finite(z, 1e9) then return false end
    if name == 'getDirectionVectorXYZ' then forward = {x,y,z} end
    if name == 'getDirectionVectorUpXYZ' then up = {x,y,z} end
  end
  local x = forward[2]*up[3] - forward[3]*up[2]
  local y = forward[3]*up[1] - forward[1]*up[3]
  local z = forward[1]*up[2] - forward[2]*up[1]
  return x*x + y*y + z*z > 1e-12
end

local function healthy()
  if validPhysics() then unhealthy = false; return true end
  if not unhealthy then
    unhealthy = true
    resetPrediction()
    log('W', 'rlsmpNetworkGuard', 'Skipped non-finite physics state for vehicle ' .. tostring(obj:getID()))
  end
  return false
end

local function applySpeed(speed)
  requestedSpeed = speed
  local stopped = not finite(speed) or speed <= 0
  if paused ~= stopped then resetPrediction() end
  paused = stopped
  if not stopped then lastSpeed = math.max(speed, 0.001) end
  -- updateRemoteData divides by this value even on a paused graphics frame.
  hooks.setGameSpeed.original(lastSpeed)
end

local function install()
  if not positionVE or not positionVE.setGameSpeed then return false end
  if owner == positionVE and hooks.setGameSpeed and positionVE.setGameSpeed == hooks.setGameSpeed.wrapper then return true end
  owner, hooks = positionVE, {}
  local speedOriginal = owner.setGameSpeed
  hooks.setGameSpeed = {original = speedOriginal, wrapper = applySpeed}
  owner.setGameSpeed = applySpeed
  speedOriginal(lastSpeed)
  resetPrediction()
  for _, name in ipairs({'updateGFX', 'onPhysicsStep', 'getVehicleRotation'}) do
    if type(owner[name]) == 'function' then
      local original = owner[name]
      local wrapper = function(dt, ...)
        if paused then return end
        if name ~= 'getVehicleRotation' and (not finite(dt) or dt <= 0) then return end
        if not healthy() then return end
        return original(dt, ...)
      end
      hooks[name] = {original = original, wrapper = wrapper}
      owner[name] = wrapper
      if extensions.hookUpdate then extensions.hookUpdate(name) end
    end
  end
  applySpeed(requestedSpeed)
  return true
end

function M.setSimulationState(speed)
  requestedSpeed = speed
  if install() then applySpeed(speed) end
end
function M.updateGFX() install() end
function M.onExtensionLoaded() install() end
function M.onExtensionUnloaded()
  if not owner then return end
  for name, record in pairs(hooks) do
    if owner[name] == record.wrapper then owner[name] = record.original end
    if extensions.hookUpdate then extensions.hookUpdate(name) end
  end
  hooks, owner = {}, nil
end
return M
