-- One global audio recovery after the selected career and its local player are ready.
local M = {}
function M.new(context)
  local api, pending, activatedProfile = {}, nil, nil
  local phase, problem = 'idle', nil
  local function stage(value)
    if phase == value then return end
    phase = value
    log('I', 'rlsmpTeamx.audio', 'Global audio reset: ' .. value)
  end
  local function player()
    if not be or not be.getPlayerVehicleID then return end
    local id = be:getPlayerVehicleID(0)
    local object = id and getObjectByID(id)
    if object and object.queueLuaCommand and context.owned(id) then return id, object end
  end
  local function worldReady()
    if not context.ready() or not getCurrentLevelIdentifier() then return false, 'waitingForCareer' end
    if not LoadingManager or not LoadingManager.isLoadingInProgress
      or LoadingManager:isLoadingInProgress() then return false, 'waitingForLoading' end
    if not core_gamestate or not core_gamestate.loading or core_gamestate.loading() then
      return false, 'waitingForLoading'
    end
    if not ui_fadeScreen or not ui_fadeScreen.isBlack or ui_fadeScreen.isBlack() then
      return false, 'waitingForFade'
    end
    if not simTimeAuthority or not simTimeAuthority.getPause or simTimeAuthority.getPause() then
      return false, 'waitingForPause'
    end
    local router = extensions and extensions.ui_router or ui_router
    local state = router and router.getState and router.getState()
    if not (state and state.currentRoute and state.currentRoute.request
      and state.currentRoute.request.name == 'play') then return false, 'waitingForPlay' end
    return true
  end
  local function clearPlayer(item)
    item.id, item.object, item.acknowledged, item.pingSent = nil, nil, false, false
    item.generation = item.generation + 1
    item.settled, item.pingAge, item.pingAttempts = 0, 0, 0
  end
  function api.activate()
    if not context.authorized() then return false end
    local profile = context.profile()
    if not profile or profile == activatedProfile then return false end
    activatedProfile = profile
    pending = {profile=profile, generation=0, settled=0, pingAge=0, pingAttempts=0}
    problem = nil
    stage('waitingForWorld')
    return true
  end
  function api.update(dt)
    if not pending then return end
    local item = pending
    if not context.authorized() or context.profile() ~= item.profile then
      pending = nil; stage('cancelled'); return
    end
    local eligible, reason = worldReady()
    if not eligible then item.settled = 0; stage(reason); return end
    local id, object = player()
    if not object then clearPlayer(item); stage('waitingForPlayer'); return end
    if object ~= item.object or id ~= item.id then
      clearPlayer(item)
      item.id, item.object = id, object
    end
    -- Retry lost VM replies; never accept one for an old player or attempt.
    local delta = math.max(0, math.min(tonumber(dt) or 0, 0.25))
    if not item.acknowledged then
      if not core_vehicleBridge or not core_vehicleBridge.requestValue then stage('waitingForVehicle'); return end
      item.pingAge = item.pingAge + delta
      if not item.pingSent or item.pingAge >= 5 then
        if item.pingAttempts >= 3 then
          pending, problem = nil, 'Local player did not acknowledge readiness'
          stage('failed'); log('W', 'rlsmpTeamx.audio', problem); return
        end
        item.pingSent, item.pingAge = true, 0
        item.pingAttempts = item.pingAttempts + 1
        item.generation = item.generation + 1
        local generation = item.generation
        local ok, err = pcall(core_vehicleBridge.requestValue, object, function(response)
          if pending == item and generation == item.generation and context.authorized()
            and context.profile() == item.profile and getObjectByID(id) == object
            and be:getPlayerVehicleID(0) == id and response and not response.failReason then
            item.acknowledged = true
          end
        end, 'ping')
        if not ok then log('W', 'rlsmpTeamx.audio', 'Player readiness request failed: ' .. tostring(err)) end
      end
      stage('waitingForVehicle'); return
    end
    item.settled = item.settled + delta
    if item.settled < 1 then stage('settling'); return end
    if not SFXSystem or not SFXSystem.setGlobalParameter or not core_audio or not core_audio.onPhysicsUnpaused
      or not core_sounds or not core_sounds.setAudioBlur then stage('waitingForAudio'); return end
    -- Native end-of-loading/unpause audio state. No vehicle or sound-bank reload.
    pending = nil
    local ok, err = pcall(function()
      SFXSystem.setGlobalParameter('g_FadeTimeMS', 1000)
      SFXSystem.setGlobalParameter('g_GameLoading', 0)
      core_audio.onPhysicsUnpaused()
      core_sounds.setAudioBlur(0)
    end)
    problem = not ok and tostring(err) or nil
    stage(ok and 'complete' or 'failed')
    log(ok and 'I' or 'E', 'rlsmpTeamx.audio', ok
      and ('Global audio reset completed after career load: ' .. item.profile .. ', player ' .. id)
      or ('Global audio reset failed: ' .. problem))
  end
  function api.destroyed(id)
    if pending and pending.id == id then clearPlayer(pending) end
  end
  function api.stop() pending, activatedProfile, problem, phase = nil, nil, nil, 'idle' end
  function api.status() return {phase=phase, profile=activatedProfile, pending=pending~=nil, error=problem} end
  return api
end
return M
