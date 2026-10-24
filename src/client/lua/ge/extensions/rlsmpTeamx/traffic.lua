-- Three ambient cars per connected career. BeamMP publishes their normal local spawns.
-- Every operation keeps an explicit set of our own vehicles; no global traffic deletion.
local M = {}
local AMOUNT = 3
local serial = 0

function M.new(context)
  local api = {}
  local vehicles, generation = {}, 0
  local enabled, spawning, failed = false, nil, false
  local elapsed, retryDelay = 0, 5
  local problem
  local focusOwner

  local function follow(id)
    gameplay_traffic.setFocus('vehicle', {vehId = id, auto = false})
    focusOwner = id
  end

  local function ours(id, record)
    local obj = getObjectByID(id)
    if not obj or obj:getJBeamFilename() ~= 'simple_traffic'
      or obj:getDynDataFieldbyName('rlsmpTraffic', 0) ~= record.tag then return nil end
    local network = MPVehicleGE and MPVehicleGE.getVehicleByGameID(id)
    if network and network.isLocal ~= true then return nil end
    return obj
  end

  local function remove(id, record)
    local obj = ours(id, record)
    vehicles[id] = nil
    if not obj then return end
    if gameplay_traffic then
      local ok, err = pcall(gameplay_traffic.removeTraffic, id, true)
      if not ok then log('E', 'rlsmpTeamx.traffic', tostring(err)) end
    end
    -- Match RLS's collision-reference cleanup before removing a physics object.
    for _, other in pairs(map and map.objects or {}) do
      if other.objectCollisions and other.objectCollisions[id] ~= nil then other.objectCollisions[id] = nil end
    end
    obj:delete()
  end

  local function count()
    local total = 0
    for id, record in pairs(vehicles) do
      if ours(id, record) then total = total + 1 else vehicles[id] = nil end
    end
    return total
  end

  local function owner()
    local id = be:getPlayerVehicleID(0)
    local obj = id and id >= 0 and getObjectByID(id)
    local network = id and MPVehicleGE and MPVehicleGE.getVehicleByGameID(id)
    if not obj or network and network.isLocal ~= true then return nil end
    if obj:getJBeamFilename() == 'simple_traffic' then return nil end
    return obj, id
  end

  local function current(token)
    return enabled and token == generation and context.canRun()
  end

  function api.stop()
    enabled, failed, problem = false, false, nil
    generation = generation + 1 -- cancels a job before its next spawn or activation
    spawning, elapsed, retryDelay = nil, 0, 5
    local pending = {}; for id, record in pairs(vehicles) do pending[id] = record end
    for id, record in pairs(pending) do remove(id, record) end
    if focusOwner and gameplay_traffic then
      local ok, focus = pcall(gameplay_traffic.getFocus)
      if ok and type(focus) == 'table' and focus.mode == 'vehicle' and focus.vehId == focusOwner and focus.auto == false then
        pcall(gameplay_traffic.setFocus) -- restore the game's automatic focus for the next career/solo session
      end
    end
    focusOwner = nil
  end

  function api.enable()
    if enabled then return end -- duplicate activation hooks must not add another batch
    enabled, failed, problem, elapsed = true, false, nil, 0
  end

  local function spawnMissing(amount)
    local token = generation
    spawning = token
    core_jobsystem.create(function(job)
      local ok, err = xpcall(function()
        local group = core_multiSpawn.createGroup(amount, {
          allMods = false, allConfigs = true, minPop = 0, country = 'united states',
          modelPopPower = 0, configPopPower = 1,
          filters = {Type = {proptraffic = 1}, ['Config Type'] = {police = 0, other = 1}},
        })
        if type(group) ~= 'table' or #group ~= amount then error('Simplified traffic configurations unavailable') end
        for _, item in ipairs(group) do
          if item.model ~= 'simple_traffic' then error('Unexpected traffic model: ' .. tostring(item.model)) end
        end
        local data = core_multiSpawn.setVehicleSpawnData(group, amount)
        for _, item in ipairs(data) do
          if not current(token) or count() >= AMOUNT then break end
          local player, playerId = owner()
          if not player then break end
          if not canSpawnAnotherVehicle() then error('Not enough memory to spawn traffic') end
          local origin, direction = player:getPosition(), player:getDirectionVector()
          local point, valid = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(origin, direction, 120, 450, 200, {gap = 35})
          if not valid then break end -- no nearby safe road yet: retry later, without forcing an unsafe spawn
          local pos, dir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(point.pos, point.dir,
            point.n1, point.n2, {legalDirection = true})
          if not gameplay_traffic_trafficUtils.checkSpawnPoint(pos, origin, 80, 800, 30) then break end
          local normal = map.surfaceNormal(pos, 1)
          local rot = quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
          item.pos, item.rot = pos, rot
          local options = sanitizeVehicleSpawnOptions(item.model, item)
          options.autoEnterVehicle, options.removeTraffic, options.centeredPosition = false, false, true
          options.visibilityPoint = nil
          local obj = spawn.spawnVehicle(item.model, options.config, pos, rot, options)
          if not obj then error('Traffic vehicle failed to spawn') end
          serial = serial + 1
          local id, tag = obj:getID(), 'rlsmp_' .. tostring(serial)
          obj:setDynDataFieldbyName('rlsmpTraffic', 0, tag)
          obj:setDynDataFieldbyName('isTraffic', 0, 'true')
          vehicles[id] = {tag = tag, initialized = false}
          obj.playerUsable = false
          obj:queueLuaCommand('electrics.setIgnitionLevel(3)')
          if not current(token) then remove(id, vehicles[id]); break end
          map.request(id, -1)
          -- Wait for the real physics/map registration before constructing the traffic role.
          for _ = 1, 150 do
            if not current(token) or map.objects[id] then break end
            -- yield() may do nothing while the job's CPU budget is not exhausted.
            -- sleep() always hands control back to the engine so physics can register the car.
            job.sleep(0.1)
          end
          if not current(token) then
            if vehicles[id] then remove(id, vehicles[id]) end
            break
          end
          obj = ours(id, vehicles[id] or {})
          if not obj then break end
          if not map.objects[id] then remove(id, vehicles[id]); error('Traffic map registration timed out') end
          obj.aiMode = 'traffic'
          -- Keep these three cars out of the shared pool so career missions cannot pool them away.
          gameplay_traffic.insertTraffic(id, false, true)
          local entry = gameplay_traffic.getTrafficData()[id]
          if not entry or not entry.isAi then remove(id, vehicles[id]); error('Traffic AI activation failed') end
          entry.enableAutoPooling = false
          entry:setRole('standard')
          obj.playerUsable = false
          vehicles[id].initialized = true
          follow(playerId)
          job.sleep(0.05) -- force a frame between cars, independently of the CPU time budget
        end
      end, debug.traceback)
      if token ~= generation then return end
      spawning = nil
      if not ok then
        failed, problem = true, tostring(err)
        log('E', 'rlsmpTeamx.traffic', problem)
        -- A half-built batch must not leave an unregistered static car on the road.
        local pending = {}; for id, record in pairs(vehicles) do pending[id] = record end
        for id, record in pairs(pending) do if not record.initialized then remove(id, record) end end
        context.error('RLSMP traffic stopped. Check beamng.log, then reconnect.')
      end
    end)
  end

  local function update(dt)
    if not enabled then return end
    if not context.canRun() then api.stop(); return end
    if failed then return end
    for id, record in pairs(vehicles) do
      local obj = ours(id, record)
      if obj then obj.playerUsable = false end
    end
    elapsed = elapsed + math.min(tonumber(dt) or 0, 1)
    if elapsed < retryDelay or spawning ~= nil then return end
    elapsed, retryDelay = 0, 10
    local player, id = owner()
    if not player then return end
    if not gameplay_traffic or not core_multiSpawn or not gameplay_traffic_trafficUtils then
      extensions.load('gameplay_traffic')
      extensions.load('core_multiSpawn')
      return
    end
    follow(id)
    gameplay_traffic.setTrafficVars({enableRandomEvents = false})
    local missing = AMOUNT - count()
    if missing > 0 then spawnMissing(missing) end
  end

  function api.update(dt)
    local ok, err = xpcall(function() update(dt) end, debug.traceback)
    if not ok and not failed then
      failed, problem = true, tostring(err)
      log('E', 'rlsmpTeamx.traffic', problem)
      context.error('RLSMP traffic stopped. Check beamng.log, then reconnect.')
    end
  end

  function api.destroyed(id) vehicles[id] = nil end
  function api.isTraffic(id)
    local obj = getObjectByID and getObjectByID(id)
    return obj ~= nil and obj:getJBeamFilename() == 'simple_traffic'
  end
  function api.status()
    return {target = AMOUNT, count = count(), enabled = enabled,
      spawning = spawning ~= nil, failed = failed, error = problem}
  end
  return api
end

return M
