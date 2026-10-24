-- Lifecycle integration: exercise the bridge through the same public calls as RLS's UI.
unpack = table.unpack
deepcopy = function(value)
  if type(value) ~= 'table' then return value end
  local copy = {}; for k,v in pairs(value) do copy[k]=deepcopy(v) end; return copy
end
local handlers, messages, requests, routes = {}, {}, {}, {}
local connected, level, ip = true, 'rls_west_coast', '127.0.0.1'
local active, profile, root, pending, savesDone = false, nil, 'offline/', nil, 0
local configured = {protocol=1, serverId=string.rep('a',32), profile='beammp_12345', level=level}
local configB = {protocol=1, serverId=string.rep('b',32), profile='beammp_12345', level=level}
local objects, deleted, map, dirs, names = {}, {}, {[1]={isLocal=true}, [2]={isLocal=false}}, {}, {}
for _, id in ipairs({1,2,3,4}) do
  objects[#objects+1]={getID=function() return id end, delete=function() deleted[id]=true end}
end
MPCoreNetwork={isMPSession=function() return connected end,
  getCurrentServer=function() return {ip=ip,port=30814} end}
MPVehicleGE={getVehicleByGameID=function(id) return map[id] end}
be={getObjectCount=function() return #objects end, getObject=function(_,index) return objects[index+1] end,
  getPlayerVehicleID=function() return -1 end}
core_vehicles={spawnNewVehicle=function() return objects[4] end, replaceVehicle=function() return objects[4] end}
FS={directoryList=function() return {} end, directoryExists=function(_,path) return dirs[path] == true end}
getCurrentLevelIdentifier=function() return level end
log=function() end
guihooks={trigger=function(...) messages[#messages+1]={...} end}
jsonDecode=function(raw) if raw=='A' then return deepcopy(configured) elseif raw=='B' then return deepcopy(configB) end end
jsonEncode=function(_) return 'HELLO' end
AddEventHandler=function(name,callback,_) handlers[name]=callback end
RemoveEventHandler=function(name,_) handlers[name]=nil end
TriggerServerEvent=function(name,raw) requests[#requests+1]={name,raw} end
extensions={ui_router={navigate=function(route) routes[#routes+1]=route; return {result=true} end}}
overhaul_career_saveSystem={
  setProfile=function(value)
    rlsmpTeamx.onOverhaulBeforeSetProfile()
    profile=value
    if value then rlsmpTeamx.onOverhaulSetProfile(root..value, value) end
    return true
  end,
  setRlsmpNamespace=function(id)
    assert(profile==nil)
    root=id and ('settings/rlsmpTeamx/saves/'..id..'/') or 'offline/'
    return true
  end,
  setRlsmpDisplayName=function(id,name) assert(profile==id); names[id]=name; return true end,
  getSaveRootDirectory=function() return root end,
  getCurrentProfile=function() return profile end,
  isSavePending=function() return false end,
  flushSaveForExit=function(callback) pending=callback end,
  saveCurrent=function(_,opts) assert(opts.manual); savesDone=savesDone+1 end,
}
local starts, lastSnapshot, lastOptions=0, nil, nil
local originalCreate=function(name,snapshot,options)
  if connected then assert(options.startingMap==level) end
  overhaul_career_saveSystem.setProfile(name)
  active=true; starts=starts+1; lastSnapshot=snapshot; lastOptions=options
  dirs[root..name]=true
  return true
end
overhaul_career_career={
  isActive=function() return active end, isStarting=function() return false end,
  createOrLoadCareerAndStart=originalCreate,
  deactivateCareer=function() active=false end,
  formatImportSourceCard=function(_,snapshot) return {image=snapshot..'/preview.jpg'} end,
  getImportSourceHighlights=function(_,snapshot,limit) return {snapshot=snapshot,limit=limit} end,
}
rlsmpTeamx=require('rlsmpTeamx')
local policy=require('rlsmpTeamx/policy')
assert(not policy.isAuthorized())
assert(policy.removeLocalVehicles()==false)
assert(policy.allowProfile(nil) and not policy.allowProfile('offline'))
rlsmpTeamx.onUpdate(1)
handlers.rlsmpTeamx_Config('A')
assert(policy.isAuthorized())
assert(policy.allowProfile('beammp_12345') and policy.allowProfile('beammp_12345_second'))
for _,name in ipairs({'beammp_67890','beammp_123456_other','beammp_12345_','beammp_12345_../other'}) do
  assert(not policy.allowProfile(name), name)
end
core_vehicles.spawnNewVehicle()
assert(policy.canManageVehicle(1) and policy.canManageVehicle(4))
assert(not policy.canManageVehicle(2) and not policy.canManageVehicle(3))
policy.removeLocalVehicles()
assert(deleted[1] and deleted[4] and not deleted[2] and not deleted[3])
map[4]={isLocal=false}; assert(not policy.canManageVehicle(4))
rlsmpTeamx.onUpdate(1); rlsmpTeamx.onUpdate(1)
assert(starts==0 and routes[#routes]=='overhaul.profiles') -- no automatic blank career
assert(rlsmpTeamx.getStatus().choosingCareer and rlsmpTeamx.getUiContext().active)
assert(root=='settings/rlsmpTeamx/saves/'..string.rep('a',32)..'/')
assert(overhaul_career_career.createOrLoadCareerAndStart('beammp_12345', 'autosave1', {}))
assert(starts==1 and lastSnapshot=='autosave1' and profile=='beammp_12345') -- existing 0.2 save
assert(not rlsmpTeamx.getTrafficStatus().enabled)
rlsmpTeamx.onOverhaulActivationReady()
assert(rlsmpTeamx.getTrafficStatus().enabled and rlsmpTeamx.getTrafficStatus().target==3)
assert(rlsmpTeamx.getStatus().started and not rlsmpTeamx.getStatus().choosingCareer)
for i=1,60 do rlsmpTeamx.onUpdate(1) end
assert(starts==1 and savesDone>=1)
assert(rlsmpTeamx.openProfiles())
assert(rlsmpTeamx.closeProfiles() and routes[#routes]=='pause')

ip='127.0.0.2'; rlsmpTeamx.onUpdate(1)
assert(rlsmpTeamx.getStatus().stopping and profile=='beammp_12345' and pending)
assert(not rlsmpTeamx.getTrafficStatus().enabled)
assert(root~='offline/' and not policy.isAuthorized())
pending(); pending=nil
assert(profile==nil and root=='offline/' and not active)
assert(overhaul_career_career.createOrLoadCareerAndStart==originalCreate)
rlsmpTeamx.onUpdate(1); handlers.rlsmpTeamx_Config('B')
rlsmpTeamx.onUpdate(1); rlsmpTeamx.onUpdate(1)
assert(starts==1 and rlsmpTeamx.getStatus().choosingCareer)
local choices={startingMap='italy',hardcoreMode=true,challengeId='test',cheatsMode=true,
  difficultyMode='hardcore',startingCash=75000,xpMultiplier=2,economyMultiplier=0.5,
  startingGarageMode='owned',startingGarageId='garage1',policeEnabled=false,
  experimentalMaintenanceEnabled=true,careerStartMode='freeroam',sandboxEconomyProfile={money=10},
  sandboxXpProfile={level=3},employmentApprenticeship=false}
assert(overhaul_career_career.createOrLoadCareerAndStart('Ma nouvelle carriere',nil,choices))
assert(profile=='beammp_12345_manouvellecarriere' and starts==2)
assert(rlsmpTeamx.getProfile()==profile and names[profile]=='Ma nouvelle carriere')
for key,value in pairs(choices) do
  if key~='startingMap' and type(value)~='table' then assert(lastOptions[key]==value,key) end
end
assert(lastOptions.sandboxEconomyProfile.money==10 and lastOptions.sandboxEconomyProfile~=choices.sandboxEconomyProfile)
assert(choices.startingMap=='italy') -- caller options are preserved
assert(rlsmpTeamx.allocateProfileName('Ma nouvelle carriere')=='beammp_12345_manouvellecarriere_1')
assert(not rlsmpTeamx.allocateProfileName('   '))
level='italy'; assert(not policy.isAuthorized())
connected=false; assert(policy.canManageVehicle(2))
rlsmpTeamx.onBeamMPServerLeave(); assert(pending); pending(); pending=nil

local solo=require('rlsmpTeamx/soloSaves')
solo.scan=function() return {
  {id='solo-id', compatible=true, name='Solo', source='RLS solo',snapshot='solo/autosave1'},
  {id='old-id', compatible=false, name='Old', source='BeamNG solo',snapshot='old/autosave1',reason='Migration requise'},
} end
solo.copy=function(id,serverId,name,mapName,options)
  assert(id=='solo-id' and name=='beammp_12345_solo' and mapName==level and options.isCurrent())
  return 'import_solo_test'
end
local jobs={}
core_jobsystem={create=function(callback) jobs[#jobs+1]=callback end}
connected=true; level='rls_west_coast'; ip='127.0.0.3'
rlsmpTeamx.onUpdate(1); handlers.rlsmpTeamx_Config('B')
rlsmpTeamx.onUpdate(1); rlsmpTeamx.onUpdate(1)
local cards=rlsmpTeamx.getSoloProfileCards()
assert(#cards==2 and cards[1].id=='rlsmp-solo:solo-id' and cards[1].importSource and cards[1].rlsmpSolo=='solo-id')
assert(cards[1].image=='solo/autosave1/preview.jpg' and cards[2].incompatibleVersion)
assert(rlsmpTeamx.getSoloProfileHighlights('solo-id',3).limit==3)
assert(not rlsmpTeamx.importSoloCareer('unlisted'))
assert(not rlsmpTeamx.importSoloCareer('old-id'))
assert(rlsmpTeamx.importSoloCareer('solo-id') and rlsmpTeamx.getStatus().importing)
assert(not rlsmpTeamx.importSoloCareer('solo-id'))
jobs[1]({yield=function() end})
assert(starts==3 and lastSnapshot=='import_solo_test' and profile=='beammp_12345_solo')
assert(not rlsmpTeamx.getStatus().importing and not rlsmpTeamx.importSoloCareer('solo-id'))

local mapRequests, mapJobs, proxyState, proxyFile = 0, {}, 'generating', false
local requestMap=function() mapRequests=mapRequests+1 end
MPCoreNetwork.requestMap=requestMap
FS.fileExists=function(_,path) return proxyFile and path=='/levels/rls_west_coast/info.json' end
overhaul_world_levelProxy={getStatus=function() return {state=proxyState} end}
core_jobsystem.create=function(callback) mapJobs[#mapJobs+1]=callback end
rlsmpTeamx.onExtensionLoaded(); MPCoreNetwork.requestMap()
assert(mapRequests==0 and #mapJobs==1)
MPCoreNetwork.requestMap(); assert(#mapJobs==1)
mapJobs[1]({sleep=function() proxyState='ready'; proxyFile=true end})
assert(mapRequests==1)
MPCoreNetwork.requestMap(); assert(mapRequests==2)
rlsmpTeamx.onExtensionUnloaded()
assert(MPCoreNetwork.requestMap==requestMap and handlers.rlsmpTeamx_Config==nil)
assert(overhaul_career_career.createOrLoadCareerAndStart==originalCreate)
rlsmpTeamx.onBeamMPServerLeave(); pending(); pending=nil
local startupCalls, messageCount = 0, #messages
overhaul_career_career.isStarting=function() startupCalls=startupCalls+1; error('simulated initialization fault') end
rlsmpTeamx.onUpdate(1); handlers.rlsmpTeamx_Config('B')
for i=1,20 do rlsmpTeamx.onUpdate(1) end
assert(rlsmpTeamx.getStatus().startupFailed and startupCalls==3)
assert(#messages==messageCount+2)
rlsmpTeamx.onExtensionUnloaded()
