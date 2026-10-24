-- Run the actual game replacement and BeamMP handlers around the bridge.
unpack = table.unpack
local connected, current, counter = true, 20, 100
local objects, network, handlers = {}, {}, {}
local created, edits, destroyed, replacements = 0, {}, 0, 0
local function object(id, model, localOwner)
  local v = {id=id, model=model, config={}}
  function v:getID() return self.id end
  function v:getJBeamFilename() return self.model end
  function v:getPosition() return self.id end
  function v:getRefNodeRotation() return {} end
  function v:getField() return '' end
  function v:setDynDataFieldbyName() end
  function v:queueLuaCommand() end
  function v:getInitialHeight() return 1 end
  function v:delete() destroyed=destroyed+1; objects[self.id]=nil end
  objects[id]=v
  if localOwner~=nil then network[id]={isLocal=localOwner, jbeam=model, serverVehicleID='0-'..id} end
  return v
end
local car=object(10, 'roamer', true)
local walking=object(20, 'unicycle', true)
local remote=object(30, 'roamer', false)
local traffic=object(40, 'simple_traffic', true)
getObjectByID=function(id) return objects[id] end
getPlayerVehicle=function() return objects[current] end
be={getPlayerVehicleID=function() return current or -1 end, enterVehicle=function(_,_,v) current=v.id end}
MPCoreNetwork={isMPSession=function() return connected end,
  getCurrentServer=function() return {ip='127.0.0.1',port=30814} end}
MPVehicleGE={getVehicleByGameID=function(id) return network[id] end}
getCurrentLevelIdentifier=function() return 'rls_west_coast' end
log=function() end
guihooks={trigger=function() end}
commands={setGameCamera=function() end}
AddEventHandler=function(name,fn) handlers[name]=fn end
RemoveEventHandler=function(name) handlers[name]=nil end
jsonDecode=function() return {protocol=1,serverId=string.rep('a',32),profile='beammp_12345',level='rls_west_coast'} end
extensions={hook=function() end}
local nextSpawnIsRemote=false
local vehiclesToSync, editSyncTimer={}, 0
local function getVehicleByGameID(id) return network[id] end
local function sendVehicleSpawn() created=created+1 end
local function sendVehicleEdit(id) edits[#edits+1]=id end
-- BEAMMP_SPAWN_HANDLER
-- BeamNG scene objects are userdata; expose that type to the real engine code.
local builtinType=type
local function type(v)
  if builtinType(v)=='table' and v.getID then return 'userdata' end
  return builtinType(v)
end
local engineM={vehIdToVehCollection={},vehCollections={},initVehCollections={}}
local M=engineM
local vehsSpawningFlag={}
local function prepareConfigData(_,opt) opt.config=opt.config or {}; return true end
local function initVehicleCollection() return {} end
local function resetVehicleCollection() end
local function splitVehicleCollection() end
local function removeVehicleFromCollection() end
local function buildInitVehCollectionCache() end
local function prepareMultiVehConfig() return false end
local function spawnMultipleVehicles() error('unexpected multi-vehicle configuration') end
local function _spawnNewVehicle(model,config)
  counter=counter+1
  local v=object(counter,model,true); v.config=config
  onVehicleSpawned(v.id)
  return v,{vehId=v.id}
end
local function replaceOtherVehicle(model,options,v)
  replacements=replacements+1
  v.model=model; v.config=options.config
  onVehicleSpawned(v.id)
  return v
end
sanitizeVehicleSpawnOptions=function(_,options) return options end
quat=function() return setmetatable({}, {__mul=function() return {} end}) end
deepcopy=function(v)
  if type(v)~='table' then return v end
  local r={}; for k,x in pairs(v) do r[k]=deepcopy(x) end; return r
end
-- ENGINE_PRIVATE_REPLACE
-- ENGINE_PUBLIC_REPLACE
core_vehicles={replaceVehicle=replaceVehicle,
  spawnNewVehicle=function(model,opt) return _spawnNewVehicle(model,opt and opt.config or {}) end}
-- Load the server extension before BeamMP's post-join API replacement, as the game does.
rlsmpTeamx=require('rlsmpTeamx')
rlsmpTeamx.onUpdate(0) -- a pre-join update may already wrap the engine functions
local nativeReplace=replaceVehicle
local original_spawnNewVehicle, original_replaceVehicle, original_spawnDefault, original_removeAllExceptCurrent
-- BEAMMP_REPLACE_REQUEST
local function spawnRequest(model,options) return original_spawnNewVehicle(model,options) end
MPVehicleGE.replaceRequest=replaceRequest
MPVehicleGE.spawnRequest=spawnRequest
do
  local M=MPVehicleGE
-- BEAMMP_POST_JOIN
end
MPVehicleGE.onBeamMPPostJoin()
-- First prove the failure with the real BeamMP handler: third argument is ignored.
local before=created
local wrong=core_vehicles.replaceVehicle('roamer',{config={part='wrong'}},car)
assert(wrong==walking and car.config.part==nil and created==before)
walking.model='unicycle'; network[walking.id].jbeam='unicycle'
-- Activate the bridge's installed wrappers and authenticated server scope.
rlsmpTeamx.onUpdate(0)
handlers.rlsmpTeamx_Config('CONFIG')
assert(rlsmpTeamx.isAuthorized())
local originalServerId=network[car.id].serverVehicleID
for _,focus in ipairs({20,30,-1,10}) do
  current=focus
  for i=1,3 do
    local v, collection=core_vehicles.replaceVehicle('roamer', {config={part=i},keepOtherVehRotation=true},car,false)
    assert(v==car and collection[1]==car and car.id==10 and car.config.part==i)
    assert(current==focus and objects[20]==walking and walking.model=='unicycle')
    assert(objects[30]==remote and remote.config.part==nil)
    assert(network[car.id].serverVehicleID==originalServerId)
  end
end
assert(created==before and destroyed==0)
assert(vehiclesToSync[car.id]) -- the real BeamMP handler queues same-model edits
local edited=core_vehicles.replaceVehicle('pickup',{config={part='changed model'}},car)
assert(edited==car and edits[#edits]==10 and created==before)
-- Foreign, ambient and stale explicit targets cannot be replaced or spawn copies.
local n=replacements
for _,v in ipairs({remote,traffic,object(50,'roamer')}) do
  assert(core_vehicles.replaceVehicle('roamer',{},v)==nil)
end
local stale=object(60,'roamer',true)
objects[60]=object(60,'pickup',true)
assert(core_vehicles.replaceVehicle('roamer',{},stale)==nil)
assert(replacements==n and created==before and destroyed==0)
-- Calls without a target retain the ordinary BeamMP behavior.
current=20
assert(core_vehicles.replaceVehicle('unicycle',{})==walking)
-- Leave/unload restores BeamMP's wrappers; offline calls retain full engine arguments.
rlsmpTeamx.onExtensionUnloaded()
assert(core_vehicles.replaceVehicle==replaceRequest)
connected=false
core_vehicles.replaceVehicle=nativeReplace
local solo=core_vehicles.replaceVehicle('roamer',{config={solo=true}},car)
assert(solo==car and car.config.solo and destroyed==0)
