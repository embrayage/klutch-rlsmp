-- RLS Career Overhaul 2.8 / BeamNG 0.40 / BeamMP compatibility prototype.
local M = {}
local policy = require('rlsmpTeamx/policy')
local nativeProfiles = require('rlsmpTeamx/nativeProfiles')
local ambientTraffic = require('rlsmpTeamx/traffic')
local networkGuard = require('rlsmpTeamx/networkGuard').new({multiplayer=policy.isMultiplayer})
local tradesModule = require('rlsmpTeamx/trades')
local audioRecoveryModule = require('rlsmpTeamx/audioRecovery')
local session, endpoint, failure
local helloElapsed, saveElapsed, startElapsed = 0, 0, 0
local started, stopping = false, false
local hooks = {}
-- Server mod scripts load before BeamMP's post-join replacement of this API.
-- Keep the engine implementation: BeamMP's replaceRequest discards otherVeh.
local nativeReplaceVehicle = core_vehicles and core_vehicles.replaceVehicle
local eventRegistered, registeredEventApi = false, nil
local VERSION = '0.8.0-alpha'
local selectedProfile
local nativePickerOpened = false
local mapHook, mapRequestPending
local startupFailed = false
local startupFailures, startupCooldown, startupProblem = 0, 0, nil
local startupPhase = 'bootstrap'
local handshakeElapsed, handshakeWarned = 0, false
local pickerElapsed, pickerRecoveries, pickerDismissed = 0, 0, false

local function phase(value)
  if startupPhase == value then return end
  startupPhase = value
  log('I', 'rlsmpTeamx.startup', value)
end

local function transportReady()
  return not MPGameNetwork or not MPGameNetwork.launcherConnected or MPGameNetwork.launcherConnected() == true
end

local function serverEndpoint()
  if not policy.isMultiplayer() then return nil end
  local server = MPCoreNetwork.getCurrentServer and MPCoreNetwork.getCurrentServer()
  if not server or not server.ip or not server.port then return nil end
  return tostring(server.ip) .. ':' .. tostring(server.port)
end

local function notice(kind, message)
  log(kind == 'error' and 'E' or 'I', 'rlsmpTeamx', message)
  guihooks.trigger('toastrMsg', {type = kind, title = 'RLSMP ' .. VERSION, msg = message})
end

local trades = tradesModule.new({
  active=function()
    return M.isAuthorized() and overhaul_career_career and overhaul_career_career.isActive()
      and not overhaul_career_career.isStarting() and overhaul_career_saveSystem
      and overhaul_career_saveSystem.getCurrentProfile()==M.getProfile()
  end,
  serverId=function() return M.getServerId() end,
  accountProfile=function() return session and session.profile end,
  notice=notice,
})

function M.isTradingAvailable() return M.isAuthorized() and overhaul_career_career and overhaul_career_career.isActive() or false end
function M.getTradeStatus() return trades.status() end
function M.tradeAction(op,target,amount,vehicleId,id) return trades.action(op,target,amount,vehicleId,id) end
function M.onOverhaulSaveCurrentProfile(path) trades.save(path) end
function M.onOverhaulSaveFinished() trades.saved() end
function M.onOverhaulSaveFailed() trades.saveFailed() end

local native = nativeProfiles.new({
  session = function() return session end,
  authorized = function() return M.isAuthorized() end,
  multiplayer = policy.isMultiplayer,
  selected = function(profile) selectedProfile = profile; started = true end,
  error = function(message)
    failure = message or 'Career action unavailable.'
    notice('error', failure)
    guihooks.trigger('RLSMPProfileError', {error = failure})
  end,
})

local traffic = ambientTraffic.new({
  canRun = function()
    return M.isAuthorized() and overhaul_career_career and overhaul_career_career.isActive()
      and not overhaul_career_career.isStarting()
      and overhaul_career_saveSystem.getCurrentProfile() == M.getProfile()
  end,
  error = function(message) notice('error', message) end,
})

local audioRecovery = audioRecoveryModule.new({
  authorized=function() return M.isAuthorized() end,
  profile=function() return M.getProfile() end,
  owned=policy.canManageVehicle,
  ready=function()
    return overhaul_career_career and overhaul_career_career.isActive()
      and not overhaul_career_career.isStarting()
      and overhaul_career_saveSystem.getCurrentProfile() == M.getProfile()
  end,
})

local function installMapHook()
  if not MPCoreNetwork or not MPCoreNetwork.requestMap or mapHook then return end
  local original = MPCoreNetwork.requestMap
  local wrapper = function(...)
    if not policy.isMultiplayer() then return original(...) end
    local function mapReady()
      local proxy = overhaul_world_levelProxy
      local status = proxy and proxy.getStatus and proxy.getStatus()
      return status and status.state == 'ready' and FS:fileExists('/levels/rls_west_coast/info.json')
    end
    if mapReady() then return original(...) end
    if mapRequestPending then return end
    local connection, arguments = serverEndpoint(), {...}
    local token = {}
    mapRequestPending = token
    core_jobsystem.create(function(job)
      for _ = 1, 3000 do
        if mapRequestPending ~= token or connection ~= serverEndpoint() then return end
        if mapReady() then
          mapRequestPending = nil
          return original(unpack(arguments))
        end
        local proxy = overhaul_world_levelProxy
        local status = proxy and proxy.getStatus and proxy.getStatus()
        if status and status.state == 'error' then
          mapRequestPending = nil
          notice('error', 'The RLS map could not be prepared. Check beamng.log, then reconnect.')
          return
        end
        job.sleep(0.1)
      end
      mapRequestPending = nil
      notice('error', 'RLS map preparation timed out. Reconnect after it finishes.')
    end)
  end
  mapHook = {original = original, wrapper = wrapper}
  MPCoreNetwork.requestMap = wrapper
end

function M.isAuthorized()
  return not stopping and session ~= nil and session.endpoint == serverEndpoint()
    and session.level == getCurrentLevelIdentifier()
end

function M.getProfile() return selectedProfile or session and session.profile end
function M.getServerId() return session and session.serverId end
function M.isOwnedProfile(profile) return native.isOwned(profile) end
function M.allocateProfileName(name) return native.allocate(name) end
function M.getSoloProfileCards() return native.cards() end
function M.getSoloProfileHighlights(id, limit) return native.highlights(id, limit) end
function M.importSoloCareer(id) return native.importSolo(id) end
function M.openProfiles()
  local opened = native.open()
  if opened then
    nativePickerOpened, pickerDismissed, pickerElapsed = true, false, 0
    phase('choosingCareer')
  end
  return opened
end
function M.isTrafficVehicle(id) return traffic.isTraffic(id) end
function M.getTrafficStatus() return traffic.status() end
function M.getUiContext()
  return {active = M.isAuthorized(), level = session and session.level, version = VERSION,
    importing = native.isImporting(), error = failure}
end
function M.closeProfiles()
  if not M.isAuthorized() then return false end
  pickerDismissed = not overhaul_career_career.isActive()
  if pickerDismissed then phase('selectionClosed') end
  extensions.ui_router.navigate(overhaul_career_career.isActive() and 'pause' or 'play')
  return true
end

local function installSpawnHooks()
  if not core_vehicles or not policy.isMultiplayer() then return end
  for _, name in ipairs({'spawnNewVehicle', 'replaceVehicle'}) do
    local record = hooks[name]
    if core_vehicles[name] and (not record or core_vehicles[name] ~= record.wrapper) then
      local original = core_vehicles[name]
      local wrapper = function(model, options, otherVeh, replaceWholeCollection)
        local vehicle, collection
        if name == 'replaceVehicle' and otherVeh and M.isAuthorized() then
          local id = otherVeh:getID()
          -- Never replace remote cars, traffic, or a stale object from an old session.
          if not policy.canManageVehicle(id) or getObjectByID(id) ~= otherVeh then
            notice('error', 'Modification refused: you do not own this vehicle.')
            return nil
          end
          if not nativeReplaceVehicle or MPVehicleGE and nativeReplaceVehicle == MPVehicleGE.replaceRequest then
            notice('error', 'Vehicle replacement unavailable. Restart BeamNG completely.')
            return nil
          end
          -- Reuse this exact physics object/ID, even while walking or viewing a garage.
          -- Its normal onVehicleSpawned hook publishes an edit through BeamMP.
          vehicle, collection = nativeReplaceVehicle(model, options, otherVeh, replaceWholeCollection)
        else
          vehicle, collection = original(model, options, otherVeh, replaceWholeCollection)
        end
        policy.markLocal(vehicle)
        return vehicle, collection
      end
      hooks[name] = {original = original, wrapper = wrapper}
      core_vehicles[name] = wrapper
    end
  end
end

local function restoreSpawnHooks()
  for name, record in pairs(hooks) do
    if core_vehicles and core_vehicles[name] == record.wrapper then
      core_vehicles[name] = record.original
    end
  end
  hooks = {}
  if mapHook and MPCoreNetwork and MPCoreNetwork.requestMap == mapHook.wrapper then
    MPCoreNetwork.requestMap = mapHook.original
  end
  mapHook, mapRequestPending = nil, nil
end

local function clearSession()
  audioRecovery.stop()
  trades.stop()
  traffic.stop()
  networkGuard.stop()
  session, endpoint, failure = nil, nil, nil
  started, stopping = false, false
  helloElapsed, saveElapsed, startElapsed = 0, 0, 0
  selectedProfile, nativePickerOpened = nil, false
  startupFailed, startupFailures, startupCooldown, startupProblem = false, 0, 0, nil
  handshakeElapsed, handshakeWarned = 0, false
  pickerElapsed, pickerRecoveries, pickerDismissed = 0, 0, false
  if eventRegistered and registeredEventApi == AddEventHandler and RemoveEventHandler then
    RemoveEventHandler('rlsmpTeamx_Config', 'rlsmpTeamxConfig')
  end
  eventRegistered, registeredEventApi = false, nil
  phase('disconnected')
  native.restore()
  policy.clear()
  restoreSpawnHooks()
end

local function stopCareer()
  if stopping then return end
  if not session then clearSession(); return end
  stopping = true
  phase('leaving')
  audioRecovery.stop()
  traffic.stop()
  local career, saves = overhaul_career_career, overhaul_career_saveSystem
  local function finish()
    if career and career.isActive() then career.deactivateCareer() end
    if saves then
      saves.setProfile(nil)
      if saves.setRlsmpNamespace then saves.setRlsmpNamespace(nil) end
    end
    clearSession()
  end
  -- Only one continuation: RLS stores a single pending exit callback.
  -- Keep its namespace until the asynchronous final save has completed.
  if career and career.isActive() and saves then
    saves.saveCurrent(nil, {manual = true, force = true})
  end
  if saves and saves.flushSaveForExit then saves.flushSaveForExit(finish) else finish() end
end

local function configurationReceived(raw)
  if stopping or not serverEndpoint() or type(raw) ~= 'string' or #raw > 4096 then return end
  local ok, config = pcall(jsonDecode, raw)
  if not ok or type(config) ~= 'table' or config.protocol ~= 1 then return end
  if config.error then
    if failure ~= config.error then notice('warning', tostring(config.error)); failure = config.error end
    return
  end
  if type(config.serverId) ~= 'string' or not config.serverId:match('^%x+$') or #config.serverId ~= 32
    or type(config.profile) ~= 'string' or not config.profile:match('^beammp_%d+$')
    or (config.level ~= 'west_coast_usa' and config.level ~= 'rls_west_coast') then
    notice('error', 'Invalid RLSMP configuration or unsupported map.')
    return
  end
  if session then
    if session.serverId ~= config.serverId or session.profile ~= config.profile then
      notice('error', 'Career identity changed during the session. Please reconnect.')
      stopCareer()
    end
    return
  end
  config.endpoint = serverEndpoint()
  session, failure = config, nil
  handshakeElapsed, handshakeWarned = 0, false
  phase('waitingForCareerModules')
  log('I', 'rlsmpTeamx', 'Session ready: ' .. config.profile .. ' / ' .. config.serverId)
end

local function showNativeProfiles()
  local career, saves = overhaul_career_career, overhaul_career_saveSystem
  if not M.isAuthorized() or not career or not saves or not saves.setRlsmpNamespace then
    phase('waitingForCareerModules')
    return
  end
  if career.isActive() or career.isStarting() then
    if native.isOwned(saves.getCurrentProfile())
      and saves.getSaveRootDirectory() == 'settings/rlsmpTeamx/saves/' .. session.serverId .. '/' then
      selectedProfile, started = saves.getCurrentProfile(), true
      native.install()
      return
    end
    notice('error', 'Another career is active. Leave it before joining this server.')
    started = true
    return
  end
  if saves.isSavePending() then phase('waitingForSave'); return end
  if M.openProfiles() then startElapsed = 0 else phase('waitingForProfileRoute'); startElapsed = 1.5 end
end

local function startupStep(callback)
  if startupFailed or startupCooldown > 0 then return end
  local ok, problem = xpcall(callback, debug.traceback)
  if ok then
    startupFailures = 0
    return
  end
  startupFailures = startupFailures + 1
  startupProblem = tostring(problem)
  log('E', 'rlsmpTeamx.startup', 'Attempt ' .. startupFailures .. ': ' .. startupProblem)
  if startupFailures >= 3 then
    startupFailed = true
    phase('initializationFailed')
    failure = 'RLSMP initialization stopped after three attempts. Check beamng.log.'
    notice('error', failure)
  else
    startupCooldown = 5
    phase('retryingInitialization')
    if startupFailures == 1 then notice('warning', 'Career initialization delayed. Retrying automatically.') end
  end
end

local function watchPicker(dt)
  if not nativePickerOpened or started or pickerDismissed or native.isImporting() then return end
  local career = overhaul_career_career
  if not career or career.isActive() or career.isStarting() then return end
  local router = extensions and extensions.ui_router or ui_router
  if not router or not router.getState then return end
  local state = router.getState()
  local route = state and state.currentRoute and state.currentRoute.request
  if route and route.name == 'overhaul.profiles' then pickerElapsed = 0; return end
  pickerElapsed = pickerElapsed + dt
  if pickerElapsed < 10 then return end
  pickerElapsed = 0
  pickerRecoveries = pickerRecoveries + 1
  log('W', 'rlsmpTeamx.startup', 'Profile screen replaced or not committed; recovery ' .. pickerRecoveries)
  if pickerRecoveries > 3 then
    startupFailed = true
    phase('profileRouteFailed')
    failure = 'The RLS career selector could not stay open. Check beamng.log, then reconnect.'
    notice('error', failure)
    return
  end
  nativePickerOpened, startElapsed = false, 0
  phase('reopeningProfiles')
end

function M.onUpdate(dtReal)
  networkGuard.update()
  installMapHook()
  local current = serverEndpoint()
  if endpoint and current ~= endpoint then stopCareer(); return end
  if stopping or not current then return end
  endpoint = current
  if AddEventHandler and (not eventRegistered or registeredEventApi ~= AddEventHandler) then
    AddEventHandler('rlsmpTeamx_Config', configurationReceived, 'rlsmpTeamxConfig')
    eventRegistered, registeredEventApi = true, AddEventHandler
    log('I', 'rlsmpTeamx.startup', 'Configuration handler registered')
  end
  installSpawnHooks()
  local dt = math.min(tonumber(dtReal) or 0, 1)
  trades.update(dt)
  traffic.update(dt)
  audioRecovery.update(dt)
  if not session then
    if not transportReady() then handshakeElapsed = 0; phase('waitingForBeamMPTransport'); return end
    phase('waitingForServerConfiguration')
    handshakeElapsed = handshakeElapsed + dt
    if handshakeElapsed >= 30 and not handshakeWarned and getCurrentLevelIdentifier() then
      handshakeWarned = true
      notice('warning', 'The career bridge has not replied yet. Connection attempts will continue.')
    end
    helloElapsed = helloElapsed + dt
    if helloElapsed >= 3 and TriggerServerEvent and getCurrentLevelIdentifier() then
      helloElapsed = 0
      log('I', 'rlsmpTeamx.startup', 'Requesting server configuration (' .. VERSION .. ')')
      TriggerServerEvent('rlsmpTeamx_Hello', jsonEncode({protocol = 1, version = VERSION}))
    end
    return
  end
  if not M.isAuthorized() then phase('waitingForServerMap'); return end
  if startupFailed then return end
  startupCooldown = math.max(0, startupCooldown - dt)
  if startupCooldown > 0 then return end
  if not nativePickerOpened and not started and not pickerDismissed then
    startElapsed = startElapsed + dt
    if startElapsed >= 2 then startupStep(showNativeProfiles) end
  else
    startupStep(function()
      if nativePickerOpened or started then native.install() end
      watchPicker(dt)
    end)
  end
  if started and overhaul_career_career and overhaul_career_career.isActive() then
    trades.activate()
    saveElapsed = saveElapsed + dt
    if saveElapsed >= 60 then
      saveElapsed = 0
      if not overhaul_career_saveSystem.isSavePending() then
        overhaul_career_saveSystem.saveCurrent(nil, {manual = true})
      end
    end
  end
end

function M.onOverhaulActivationReady()
  if not M.isAuthorized() then return end
  local profile = overhaul_career_saveSystem.getCurrentProfile()
  if profile ~= M.getProfile() or not native.isOwned(profile) then
    notice('error', 'Unexpected career profile detected. Please reconnect.')
    return
  end
  phase('careerActive')
  audioRecovery.activate()
  trades.activate()
  notice('success', 'Personal career loaded. Progress is saved locally for this server.')
  overhaul_career_saveSystem.saveCurrent(nil, {manual = true})
  traffic.enable()
end

function M.onVehicleSpawned(id) networkGuard.spawned(id) end
function M.onVehicleDestroyed(id) audioRecovery.destroyed(id); traffic.destroyed(id); policy.forget(id); networkGuard.destroyed(id) end
function M.onOverhaulBeforeSetProfile() audioRecovery.stop(); traffic.stop() end
function M.onOverhaulBeforeCareerActivate() audioRecovery.stop(); traffic.stop() end
function M.onOverhaulActive(active) if not active then audioRecovery.stop(); traffic.stop() end end
function M.onOverhaulSetProfile(savePath, profile) native.profileSelected(savePath, profile) end
function M.onExtensionLoaded()
  log('I', 'rlsmpTeamx.startup', 'Bridge loaded (' .. VERSION .. ')')
  installMapHook()
end
function M.onWorldReadyState(readyState)
  -- BeamMP navigates to play on this same hook. Reopen on a later update, in either hook order.
  if readyState == 2 and policy.isMultiplayer() and not stopping and not started and not pickerDismissed then
    nativePickerOpened, startElapsed, pickerElapsed = false, 0, 0
    phase('worldReadyWaitingForProfiles')
  end
end
function M.onBeamMPServerLeave() stopCareer() end
function M.onClientEndMission() if session then stopCareer() end end

function M.onExtensionUnloaded()
  audioRecovery.stop()
  trades.stop()
  traffic.stop()
  networkGuard.stop()
  -- RLS flushes its own saves during mod teardown; never change roots mid-write.
  restoreSpawnHooks()
  native.restore()
  if eventRegistered and RemoveEventHandler then
    RemoveEventHandler('rlsmpTeamx_Config', 'rlsmpTeamxConfig')
  end
  eventRegistered, registeredEventApi = false, nil
end

function M.getStatus()
  return {version = VERSION, authorized = M.isAuthorized(), profile = M.getProfile(),
    serverId = M.getServerId(), started = started, stopping = stopping, error = failure,
    choosingCareer = nativePickerOpened and not started, importing = native.isImporting(),
    startupFailed = startupFailed, startupPhase = startupPhase, startupProblem = startupProblem,
    startupFailures = startupFailures, pickerRecoveries = pickerRecoveries,
    selectionDismissed = pickerDismissed, handshakeWait = handshakeElapsed,
    transportReady = transportReady(), currentLevel = getCurrentLevelIdentifier(),
    expectedLevel = session and session.level, traffic = traffic.status(), audio = audioRecovery.status()}
end

return M
