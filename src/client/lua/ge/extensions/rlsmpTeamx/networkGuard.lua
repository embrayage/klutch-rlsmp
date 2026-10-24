-- Reject invalid network transforms before they reach physics or queued Lua.
local M = {}
local function finite(n, bound)
  return type(n) == 'number' and n == n and math.abs(n) < (bound or math.huge)
end
local function vector(value, count, bound)
  local kind = type(value)
  if kind ~= 'table' and kind ~= 'userdata' and kind ~= 'cdata' then return false end
  local keys = count == 4 and {'x','y','z','w'} or {'x','y','z'}
  local length = 0
  for i=1,count do
    local n = value[keys[i]]
    if n == nil then n = value[i] end
    if not finite(n, bound) then return false end
    if count == 4 then length = length + n*n end
  end
  return count ~= 4 or length > 1e-12
end
local function packet(data)
  return type(data) == 'table' and vector(data.pos,3,1e9) and vector(data.rot,4,2)
    and vector(data.vel,3,1e6) and vector(data.rvel,3,1e6)
    and finite(data.tim,1e12) and finite(data.ping,1e6)
end

function M.new(context)
  local api = {}
  local hooks, attached, warned = {}, {}, {}
  local module
  local function warn(kind)
    if warned[kind] then return end
    warned[kind] = true
    log('W', 'rlsmpTeamx.networkGuard', 'Rejected invalid ' .. kind)
  end
  local function attach(obj)
    if not obj or not obj.queueLuaCommand then return end
    local id = obj:getID()
    if attached[id] == obj then return end
    attached[id] = obj
    local speed = simTimeAuthority and simTimeAuthority.getReal and simTimeAuthority.getReal() or 1
    if simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() then speed = 0 end
    if not finite(speed) or speed < 0 then speed = 0 end
    obj:queueLuaCommand("extensions.load('rlsmpNetworkGuard'); if rlsmpNetworkGuard then rlsmpNetworkGuard.setSimulationState(" .. string.format('%.17g',speed) .. ") end")
  end
  local function wrap(name, make)
    if type(module[name]) ~= 'function' then return end
    local record = hooks[name]
    if record and module[name] == record.wrapper then return end
    local original = module[name]
    local wrapper = make(original)
    hooks[name] = {owner=module,original=original,wrapper=wrapper}
    module[name] = wrapper
  end
  function api.update()
    if not context.multiplayer() then api.stop(); return end
    if not positionGE then return end
    local changed = module ~= positionGE
    module = positionGE
    wrap('handle',function(original)
      return function(raw)
        if not context.multiplayer() then return original(raw) end
        if type(raw) ~= 'string' then warn('position packet'); return end
        local code, id, encoded = raw:match('^(%a)%:(%d+%-%d+)%:({.*})')
        if code ~= 'p' then return original(raw) end
        local ok, decoded = pcall(jsonDecode,encoded)
        if not ok or not packet(decoded) then warn('position packet'); return end
        return original(raw)
      end
    end)
    wrap('setPositionRotationVelocity',function(original)
      return function(id,data)
        if not context.multiplayer() then return original(id,data) end
        if type(data) ~= 'table' or not vector(data.pos,3,1e9) or not vector(data.rot,4,2)
          or not vector(data.vel,3,1e6) or not vector(data.rvel,3,1e6) or not vector(data.vehVel,3,1e6)
          or data.noCounter ~= nil and not finite(data.noCounter,1e6)
          or not getObjectByID(id) then warn('teleport transform'); return end
        return original(id,data)
      end
    end)
    if changed and be and be.getObjectCount then
      for i=0,be:getObjectCount()-1 do attach(be:getObject(i)) end
    end
  end
  function api.spawned(id)
    if context.multiplayer() then attach(getObjectByID(id)) end
  end
  function api.destroyed(id) attached[id] = nil end
  function api.stop()
    for name,record in pairs(hooks) do
      if record.owner[name] == record.wrapper then record.owner[name] = record.original end
    end
    for id,obj in pairs(attached) do
      if getObjectByID and getObjectByID(id) == obj then
        obj:queueLuaCommand("extensions.unload('rlsmpNetworkGuard')")
      end
    end
    hooks,attached,warned,module = {},{},{},nil
  end
  return api
end
return M
