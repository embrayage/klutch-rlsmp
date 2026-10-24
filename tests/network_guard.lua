-- Reject malformed packets before prediction, and reproduce BeamMP's real zero-speed division.
local connected=true
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local calls,queued,warnings=0,{},{}
local good={pos={1,2,3},rot={0,0,0,1},vel={6,0,0},rvel={0,0,1},tim=1,ping=0.01}
local payload=good
jsonDecode=function() return payload end
log=function(_,tag,message) warnings[#warnings+1]=tag..':'..message end
local vehicle={getID=function() return 1 end,queueLuaCommand=function(_,s) queued[#queued+1]=s end}
getObjectByID=function(id) return id==1 and vehicle or nil end
be={getObjectCount=function() return 1 end,getObject=function() return vehicle end}
simTimeAuthority={getReal=function() return 1 end,getPause=function() return false end}
local handle=function(raw) calls=calls+1;return raw end
local transform=function(_,data) calls=calls+1;return data end
positionGE={handle=handle,setPositionRotationVelocity=transform}
local ge=require('rlsmpTeamx/networkGuard').new({multiplayer=function() return connected end})
ge.update();assert(#queued==1 and queued[1]:find("extensions.load('rlsmpNetworkGuard')",1,true))
ge.update();assert(#queued==1)
assert(positionGE.handle('p:0-1:{}')=='p:0-1:{}' and calls==1)
for _,field in ipairs({'pos','rot','vel','rvel','tim','ping'}) do
  for _,invalid in ipairs({math.huge,-math.huge,0/0}) do
    payload=copy(good)
    if type(payload[field])=='table' then payload[field][1]=invalid else payload[field]=invalid end
    assert(positionGE.handle('p:0-1:{}')==nil)
  end
end
payload=copy(good);payload.pos=12;assert(positionGE.handle('p:0-1:{}')==nil)
payload=copy(good);payload.rot={0,0,0,0};assert(positionGE.handle('p:0-1:{}')==nil)
assert(calls==1 and #warnings==1)
local data={pos={x=1,y=2,z=3},rot={x=0,y=0,z=0,w=1},vel={0,0,0},rvel={0,0,0},vehVel={0,0,0}}
assert(positionGE.setPositionRotationVelocity(1,data)==data and calls==2)
data.noCounter=math.huge;assert(positionGE.setPositionRotationVelocity(1,data)==nil)
data.noCounter=0;assert(positionGE.setPositionRotationVelocity(2,data)==nil)
assert(calls==2)
connected=false;assert(positionGE.handle('ordinary solo call')=='ordinary solo call' and calls==3)
ge.stop();assert(positionGE.handle==handle and positionGE.setPositionRotationVelocity==transform)
assert(queued[#queued]:find("extensions.unload('rlsmpNetworkGuard')",1,true))

-- Minimal vectors for the actual private mailbox decoder, not a replacement for its math.
local function vector(x,y,z,w)
  local t={x=x or 0,y=y or 0,z=z or 0,w=w}
  function t:set(a,b,c,d)
    if type(a)=='table' then self.x,self.y,self.z,self.w=a.x,a.y,a.z,a.w
    else self.x,self.y,self.z,self.w=a,b,c,d end
  end
  function t:setSub(v) self.x=self.x-v.x;self.y=self.y-v.y;self.z=self.z-v.z end
  function t:setScaled(n) self.x=self.x*n;self.y=self.y*n;self.z=self.z*n end
  return t
end
-- The mailbox is already bound: current BeamMP intentionally skips a new mailbox's first packet.
local lastMailboxName='vehPosPckt0-1'
local simSpeedReal,lastMailboxVersion,timer,ownPing,lastDT=1,0,1,0,0
local maxAcc,maxRacc=100,50
local max,abs=math.max,math.abs
local vel,rvel=vector(),vector()
local remoteData={pos=vector(),rot=vector(),vel=vector(),rvel=vector(),acc=vector(),racc=vector(),timer=-1}
local version=1
obj={
 getID=function() return 1 end,
 getLastMailboxVersion=function() return version end,
 getLastMailbox=function() return 'PACKET' end,
 getPositionXYZ=function() return 1,2,3 end,
 getVelocityXYZ=function() return 0,0,0 end,
 getDirectionVectorXYZ=function() return 0,1,0 end,
 getDirectionVectorUpXYZ=function() return 0,0,1 end,
 getRollPitchYawAngularVelocity=function() return 0,0,0 end,
}
v={mpServerID='0-1'}
local resets,nativeFrames,physicsFrames,sendFrames=0,0,0,0
local cache={}
extensions={hookUpdate=function(name) cache[name]=true end}
local function limitVecLength() end
-- ACTUAL_SET_GAME_SPEED
-- ACTUAL_UPDATE_REMOTE_DATA
local function nativeGFX() nativeFrames=nativeFrames+1;updateRemoteData() end
local function nativePhysics() physicsFrames=physicsFrames+1 end
local function nativeSend() sendFrames=sendFrames+1 end
positionVE={setGameSpeed=setGameSpeed,updateGFX=nativeGFX,onPhysicsStep=nativePhysics,
  getVehicleRotation=nativeSend,onReset=function() resets=resets+1;remoteData.timer=-1 end}
payload=copy(good)
-- The actual BeamMP decoder turns a valid finite packet into infinity at pause speed 0.
setGameSpeed(0);nativeGFX()
assert(remoteData.vel.x==math.huge)
local fatalLine='positionGE.setPositionRotationVelocity(1,{rot=quat(-inf,-inf,-inf,-inf)})'
local crash=assert(load(fatalLine));assert(not pcall(crash))
-- A fresh protected session never feeds speed 0 into that decoder.
remoteData.vel=vector();remoteData.rvel=vector();remoteData.timer=-1
version=version+1
local guard=dofile(VEHICLE_GUARD_PATH)
guard.onExtensionLoaded()
assert(cache.updateGFX and cache.onPhysicsStep and cache.getVehicleRotation)
local n=nativeFrames
for _,speed in ipairs({0,-1,math.huge,0/0}) do
 positionVE.setGameSpeed(speed)
 positionVE.updateGFX(0.016);positionVE.onPhysicsStep(0.016);positionVE.getVehicleRotation()
 assert(nativeFrames==n and simSpeedReal>0 and simSpeedReal<math.huge)
end
positionVE.setGameSpeed(2);positionVE.updateGFX(0.016)
assert(nativeFrames==n+1 and remoteData.vel.x==3 and remoteData.vel.x<math.huge)
positionVE.updateGFX(0);positionVE.updateGFX(0/0);assert(nativeFrames==n+1)
positionVE.onPhysicsStep(0.01);positionVE.getVehicleRotation()
assert(physicsFrames==1 and sendFrames==1)
obj.getPositionXYZ=function() return math.huge,0,0 end
positionVE.updateGFX(0.01);assert(nativeFrames==n+1)
obj.getPositionXYZ=function() return 1,2,3 end
obj.getDirectionVectorXYZ=function() return 0,0,0 end
positionVE.updateGFX(0.01);assert(nativeFrames==n+1)
obj.getDirectionVectorXYZ=function() return 0,1,0 end
version=version+1;payload.tim=2;positionVE.updateGFX(0.01)
assert(nativeFrames==n+2 and remoteData.vel.x==3)
guard.onExtensionUnloaded()
assert(positionVE.setGameSpeed==setGameSpeed and positionVE.updateGFX==nativeGFX)
assert(positionVE.onPhysicsStep==nativePhysics and positionVE.getVehicleRotation==nativeSend)

-- An attachment command may arrive before BeamMP has finished loading its VE module.
local nativeModule=positionVE
positionVE=nil;guard.setSimulationState(0)
positionVE=nativeModule;guard.onExtensionLoaded()
local beforeLate=nativeFrames
positionVE.updateGFX(0.01);positionVE.getVehicleRotation()
assert(nativeFrames==beforeLate and simSpeedReal>0)
positionVE.setGameSpeed(1);version=version+1;payload.tim=3
positionVE.updateGFX(0.01);assert(nativeFrames==beforeLate+1)
guard.onExtensionUnloaded()
