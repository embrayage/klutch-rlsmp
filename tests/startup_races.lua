-- Reproduce the real BeamMP final route change and delayed/reloaded startup dependencies.
unpack=table.unpack
local bridge
local connected,transport,route,root,pending,failOnce,routeBlocked
local handlers,messages,requests,navigations,logs
local function addEvent(name,callback) handlers[name]=callback end
local function ticks(n) for _=1,n do bridge.onUpdate(1) end end
local function fresh()
  if bridge then bridge.onExtensionUnloaded() end
  connected,transport,route,root,pending,failOnce,routeBlocked=true,true,'play','offline/',false,false,false
  handlers,messages,requests,navigations,logs={},{},{},{},{}
  MPCoreNetwork={isMPSession=function() return connected end,
    getCurrentServer=function() return {ip='127.0.0.1',port=30814} end}
  MPGameNetwork={launcherConnected=function() return transport end}
  MPVehicleGE={getVehicleByGameID=function() end}
  core_vehicles={spawnNewVehicle=function() end,replaceVehicle=function() end}
  getCurrentLevelIdentifier=function() return 'rls_west_coast' end
  AddEventHandler=addEvent
  RemoveEventHandler=function(name) handlers[name]=nil end
  TriggerServerEvent=function(name) requests[#requests+1]=name end
  log=function(_,tag,text) logs[#logs+1]=tag..':'..text end
  guihooks={trigger=function(name,data) if name=='toastrMsg' then messages[#messages+1]=data end end}
  jsonEncode=function() return 'HELLO' end
  jsonDecode=function() return {protocol=1,serverId=string.rep('a',32),profile='beammp_12345',level='rls_west_coast'} end
  FS={directoryList=function() return {} end}
  deepcopy=function(v) return v end
  extensions={ui_router={
    navigate=function(name)
      navigations[#navigations+1]=name
      if not routeBlocked then route=name end
      return {result=true}
    end,
    getState=function() return {currentRoute={request={name=route}}} end,
  }}
  overhaul_career_career={
    isActive=function() return false end,
    isStarting=function() if failOnce then failOnce=false; error('module still initializing') end; return false end,
    createOrLoadCareerAndStart=function() return false end,
  }
  overhaul_career_saveSystem={
    isSavePending=function() return pending end,
    setProfile=function() return true end,
    setRlsmpNamespace=function(id) root='settings/rlsmpTeamx/saves/'..id..'/';return true end,
    getCurrentProfile=function() return nil end,
    getSaveRootDirectory=function() return root end,
  }
  package.loaded.rlsmpTeamx=nil
  bridge=require('rlsmpTeamx'); rlsmpTeamx=bridge
  bridge.onExtensionLoaded()
  ticks(1)
end
local function authenticate()
  handlers.rlsmpTeamx_Config('CONFIG')
  assert(bridge.isAuthorized())
end
local beammpReady
-- ACTUAL_BEAMMP_WORLD_READY
fresh();authenticate();ticks(3)
assert(route=='overhaul.profiles')
-- The real MP final-loading hook overwrites the picker with gameplay.
beammpReady(2)
assert(route=='play')
bridge.onWorldReadyState(2);ticks(3)
assert(route=='overhaul.profiles')
-- Hook execution order may be reversed; the deferred reopen still wins.
bridge.onWorldReadyState(2);beammpReady(2);ticks(3)
assert(route=='overhaul.profiles')
-- A later UI reset/timeout is detected even without a world-ready event.
route='play';ticks(13)
assert(route=='overhaul.profiles' and bridge.getStatus().pickerRecoveries==1)
local opened=#navigations;ticks(30)
assert(#navigations==opened)
-- Explicitly closing the picker is respected, including subsequent ready hooks.
assert(bridge.closeProfiles()); bridge.onWorldReadyState(2);ticks(30)
assert(route=='play' and #navigations==opened+1 and bridge.getStatus().selectionDismissed)
assert(bridge.openProfiles());assert(route=='overhaul.profiles')
fresh();authenticate();failOnce=true;ticks(3)
assert(bridge.getStatus().startupPhase=='retryingInitialization')
ticks(6)
assert(route=='overhaul.profiles' and not bridge.getStatus().startupFailed)
assert(#messages==1 and bridge.getStatus().startupProblem:find('module still initializing',1,true))
-- Missing RLS modules wait safely and resume when they become available.
fresh();authenticate()
local career=overhaul_career_career;overhaul_career_career=nil;ticks(20)
assert(bridge.getStatus().startupPhase=='waitingForCareerModules' and #navigations==0)
overhaul_career_career=career;ticks(3);assert(route=='overhaul.profiles')
-- No protocol retry or timeout warning before the actual game transport is ready.
fresh();transport=false;ticks(45)
assert(#requests==0 and #messages==0 and bridge.getStatus().handshakeWait==0)
assert(bridge.getStatus().startupPhase=='waitingForBeamMPTransport')
transport=true;ticks(75)
assert(#requests>=20 and #messages==1 and not bridge.getStatus().authorized)
-- A reloaded MP event module has a new registry and AddEventHandler function.
handlers={}
AddEventHandler=function(name,callback) handlers[name]=callback end
ticks(1);assert(handlers.rlsmpTeamx_Config)
authenticate();ticks(3)
assert(route=='overhaul.profiles' and bridge.getStatus().handshakeWait==0)
-- Persistent route failures stop after bounded recoveries with an explicit error.
fresh();authenticate();routeBlocked=true;ticks(65)
assert(bridge.getStatus().startupFailed and bridge.getStatus().startupPhase=='profileRouteFailed')
local finalCount=#navigations;ticks(30);assert(#navigations==finalCount)
bridge.onExtensionUnloaded()
