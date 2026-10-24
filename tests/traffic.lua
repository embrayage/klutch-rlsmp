-- Two virtual BeamMP clients, with cooperative jobs and isolated AI tables.
local activeClient = 1
local clients = {{ready=true,traffic={},errors={}}, {ready=true,traffic={},errors={}}}
local objects, owners, deleted, jobs = {}, {}, {}, {}
local nextId, spawns, safeRoad, memory, registration = 100, 0, true, true, true
local virtualTime, registrationDelay = 0, 0
local pendingMap = {}
map={objects={},surfaceNormal=function() return {} end,
  request=function(id)
    if registration then
      if registrationDelay==0 then map.objects[id]={objectCollisions={}}
      else pendingMap[id]=virtualTime+registrationDelay end
    end
  end}
local function object(id,model,client)
  local tags={}
  local obj={playerUsable=true}
  function obj:getID() return id end
  function obj:getJBeamFilename() return model end
  function obj:getDynDataFieldbyName(key) return tags[key] or '' end
  function obj:setDynDataFieldbyName(key,_,value) tags[key]=value end
  function obj:getPosition() return {x=client*1000} end
  function obj:getDirectionVector() return {} end
  function obj:queueLuaCommand(command) assert(command=='electrics.setIgnitionLevel(3)') end
  function obj:delete()
    deleted[id]=true;objects[id]=nil;map.objects[id]=nil
    pendingMap[id]=nil
    for _,c in ipairs(clients) do c.traffic[id]=nil end
  end
  objects[id],owners[id]=obj,client
  return obj
end
object(1,'pickup',1);object(2,'pickup',2);object(3,'covet',2)
getObjectByID=function(id) return objects[id] end
MPCoreNetwork={isMPSession=function() return true end}
MPVehicleGE={getVehicleByGameID=function(id)
  if owners[id] then return {isLocal=owners[id]==activeClient} end
end}
be={getPlayerVehicleID=function() return activeClient end}
vec3=function() return {rotated=function(self) return self end} end
quatFromDir=function() return {} end
canSpawnAnotherVehicle=function() return memory end
sanitizeVehicleSpawnOptions=function(_,opts) return opts end
log=function() end
extensions={load=function() end,hook=function() end}
-- Use the game's real scheduler. Its yield() can legitimately skip yielding within the CPU budget.
unpack=table.unpack
table.clear=function(t) for key in pairs(t) do t[key]=nil end end
hptimer=function()
  local start=virtualTime
  return {stop=function() return (virtualTime-start)*1000 end,reset=function() start=virtualTime end}
end
local engineJobs=dofile(ACTUAL_JOB_SYSTEM_PATH)
local threads={}
local originalResume=coroutine.resume
coroutine.resume=function(thread,...)
  if threads[thread] then activeClient=threads[thread] end
  return originalResume(thread,...)
end
core_jobsystem={create=function(fn)
  local client=activeClient
  local job=engineJobs.create(fn)
  threads[job.t]=client
  jobs[#jobs+1]=job
  return job
end}
core_multiSpawn={
  createGroup=function(amount,params)
    assert(amount>=1 and amount<=3 and params.filters.Type.proptraffic==1)
    assert(params.allMods==false and params.filters['Config Type'].police==0)
    local group={};for i=1,amount do group[i]={model='simple_traffic',config='bastion_base'} end;return group
  end,
  setVehicleSpawnData=function(group) return group end,
}
gameplay_traffic_trafficUtils={
  findSpawnPointOnRoute=function(origin,_,minDist,maxDist,target)
    assert(origin.x==activeClient*1000 and minDist==120 and maxDist==450 and target==200)
    return {pos={},dir={}},safeRoad
  end,
  finalizeSpawnPoint=function(pos,dir,_,_,options) assert(options.legalDirection); return pos,dir end,
  checkSpawnPoint=function(_,_,minDist,maxDist,gap) assert(minDist==80 and maxDist==800 and gap==30);return true end,
}
spawn={spawnVehicle=function(model,_,_,_,options)
  assert(model=='simple_traffic' and options.autoEnterVehicle==false and options.removeTraffic==false)
  nextId=nextId+1;spawns=spawns+1
  return object(nextId,model,activeClient)
end}
gameplay_traffic={
  insertTraffic=function(id,ignoreAi,ignorePool)
    assert(owners[id]==activeClient and objects[id]:getJBeamFilename()=='simple_traffic')
    assert(ignoreAi==false and ignorePool==true)
    clients[activeClient].traffic[id]={isAi=true,setRole=function(_,role) assert(role=='standard') end}
  end,
  getTrafficData=function() return clients[activeClient].traffic end,
  removeTraffic=function(id,stop)
    assert(owners[id]==activeClient and id>100 and stop)
    clients[activeClient].traffic[id]=nil
  end,
  setFocus=function(mode,options)
    if not mode then clients[activeClient].focus={mode='camera',auto=true};return end
    assert(mode=='vehicle' and options.vehId==activeClient and options.auto==false)
    clients[activeClient].focus={mode=mode,vehId=options.vehId,auto=options.auto}
  end,
  getFocus=function() return clients[activeClient].focus end,
  setTrafficVars=function(options) assert(options.enableRandomEvents==false) end,
}
local traffic=require('rlsmpTeamx/traffic')
for client,c in ipairs(clients) do
  c.controller=traffic.new({canRun=function() return c.ready end,error=function(message) c.errors[#c.errors+1]=message end})
end
local function status(client)
  activeClient=client;return clients[client].controller.status()
end
local function tick(client,amount)
  activeClient=client
  for i=1,amount do clients[client].controller.update(1) end
end
local function step(amount)
  for _=1,amount do
    virtualTime=virtualTime+0.05
    for id,deadline in pairs(pendingMap) do
      if virtualTime>=deadline then map.objects[id]={objectCollisions={}};pendingMap[id]=nil end
    end
    engineJobs.onUpdate(0.05,0.05,0.05)
  end
end
local a,b=clients[1].controller,clients[2].controller
tick(1,20); assert(spawns==0) -- selecting a career is not activation-ready
activeClient=1;a.enable();a.enable();tick(1,4);assert(spawns==0)
tick(1,1);a.enable();tick(1,15);assert(#jobs==1)
step(12);assert(status(1).count==3 and spawns==3)
local initialA={};for id in pairs(clients[1].traffic) do initialA[id]=true end
for id in pairs(initialA) do assert(objects[id].playerUsable==false) end
for id in pairs(initialA) do objects[id].playerUsable=true end -- the game's respawn refresh resets this flag
tick(1,1)
for id in pairs(initialA) do assert(objects[id].playerUsable==false) end
tick(1,30);step(12);assert(spawns==3)

activeClient=2;b.enable();tick(2,5);step(12)
assert(status(1).count==3 and status(2).count==3 and spawns==6)
for id in pairs(initialA) do assert(objects[id] and not deleted[id]) end
assert(objects[1] and objects[2] and objects[3])
activeClient=2;b.stop();assert(status(2).count==0)
assert(clients[2].focus.auto and clients[2].focus.mode=='camera')
for id in pairs(initialA) do assert(objects[id] and not deleted[id]) end
assert(objects[1] and objects[2] and objects[3])

-- The policy rejects traffic as a career/inventory vehicle, even though BeamMP owns it locally.
activeClient=1
rlsmpTeamx={isTrafficVehicle=a.isTraffic,isAuthorized=function() return true end}
local policy=require('rlsmpTeamx/policy')
for id in pairs(initialA) do assert(not policy.canManageVehicle(id)) end
assert(policy.canManageVehicle(1) and not policy.canManageVehicle(2))

-- Refill exactly one destroyed car; duplicate activation hooks still keep the target at three.
local lost=next(initialA)
objects[lost]:delete();a.destroyed(lost)
tick(1,10);step(12)
assert(status(1).count==3 and spawns==7)

-- Cancel between spawns, then start another career while the cancelled coroutine still exists.
activeClient=1;a.stop();a.enable();tick(1,5);step(1)
assert(status(1).count==1)
activeClient=1;a.stop();a.enable();tick(1,5)
local before=spawns
step(12);assert(status(1).count==3 and spawns==before+3)
assert(objects[1] and objects[2] and objects[3])

-- No safe road: retry later, with no forced spawn or fault spam.
activeClient=1;a.stop();safeRoad=false;a.enable();tick(1,5);step(1)
assert(status(1).count==0 and not status(1).failed)
safeRoad=true;tick(1,10);step(12);assert(status(1).count==3)

-- Regression: registration arrives in a later physics frame, while yield() skips CPU-fast iterations.
activeClient=1;a.stop();registrationDelay=0.4;a.enable();tick(1,5);step(1)
assert(status(1).count==1 and status(1).spawning and not status(1).failed)
step(2);assert(status(1).spawning and not status(1).failed)
step(55);assert(status(1).count==3 and not status(1).failed and #clients[1].errors==0)
registrationDelay=0

-- Disconnect while a new vehicle waits for physics/map registration.
activeClient=1;a.stop();registration=false;a.enable();tick(1,5);step(1)
assert(status(1).count==1)
clients[1].ready=false;tick(1,1);step(2)
assert(status(1).count==0 and not status(1).enabled)
registration=true;clients[1].ready=true

-- A recycled ID or changed network owner must never be deleted by this client's cleanup.
activeClient=1;a.enable();tick(1,5);step(12)
local reused=next(clients[1].traffic)
object(reused,'pickup',2)
local transferred
for id in pairs(clients[1].traffic) do if id~=reused then transferred=id;break end end
owners[transferred]=2
activeClient=1;a.stop()
assert(objects[reused] and objects[transferred])
assert(objects[1] and objects[2] and objects[3])

-- An engine failure is reported once; career selection and other players are untouched.
activeClient=1;memory=false;a.enable();tick(1,5);step(1)
assert(status(1).failed and #clients[1].errors==1)
tick(1,50);step(2);assert(#clients[1].errors==1)
memory=true;a.stop()
assert(objects[1] and objects[2] and objects[3])

-- A genuine missing registration still times out and cleans the incomplete spawn.
registration=false;a.enable();tick(1,5);step(400)
assert(status(1).failed and status(1).count==0 and #clients[1].errors==2)
