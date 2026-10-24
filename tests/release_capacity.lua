-- Use the complete release garage manager and its real vehicle-map resolver.
local nativeRequire=require
local state
local capacity=1
require=function(name)
  if name=='overhaul/lib/world/levelData' then return {loadMaps=function() return {rls_west_coast={}} end} end
  if name=='overhaul/lib/business/bundles' then return {} end
  if name=='overhaul/career/garage/inventory/vehicleMap' then return dofile(RLS_BASE..'/career/garage/inventory/vehicleMap.lua') end
  if name=='overhaul/career/garage/garageManager/ownership' then return {new=function(ctx)
    state=ctx.state;state.purchasedGarages.garage=true
    return {buildGarageSizes=function() state.garageSize.garage=capacity end,isGarageForSale=function() return false end}
  end} end
  if name:find('overhaul/career/garage/garageManager/',1,true)==1 then return {new=function() return {} end} end
  return nativeRequire(name)
end
getCurrentLevelIdentifier=function() return 'rls_west_coast' end
local cars={
  [1]={location='garage',lastKnownLevel='rls_west_coast'},
  [2]={location='garage',lastKnownLevel='rls_west_coast'},
}
overhaul_world_facilities={getFacility=function(_,id) return {id=id,name=id} end}
overhaul_career_garage_property_propertyRentals={getActiveRentals=function() return {} end}
overhaul_career_garage_inventory={getVehicles=function() return cars end}
local gm=dofile(RLS_BASE..'/career/garage/garageManager.lua')
overhaul_career_garage_garageManager=gm
local nativeSpace=gm.isGarageSpace
assert(nativeSpace('garage',1)[1] and nativeSpace('garage',1)[2]==0)
local profile='beammp_100'
overhaul_career_saveSystem={getCurrentProfile=function() return profile,'snapshot' end}
local receipts={}
jsonReadFile=function() return {profile=profile,serverId=string.rep('a',32),receipts=receipts} end
jsonEncode=function() return '{}' end;jsonDecode=function() return {} end
local active=true
local api=require('rlsmpTeamx/trades').new({active=function() return active end,
  serverId=function() return string.rep('a',32) end,notice=function() error('unexpected notice') end})
api.activate()
assert(gm.isGarageSpace~=nativeSpace)
-- No pending trade must preserve RLS's zero-free-space admission for existing cars.
assert(gm.isGarageSpace('garage',1)[1] and gm.isGarageSpace('garage',1)[2]==0)
cars[2]=nil;capacity=2
assert(gm.isGarageSpace('garage')[1] and gm.isGarageSpace('garage')[2]==1)
receipts['1000-1']={phase='prepared',kind='car',role='to',garage='garage'}
assert(not gm.isGarageSpace('garage')[1] and gm.isGarageSpace('garage')[2]==0)
capacity=1
assert(gm.isGarageSpace('garage',1)[1] and gm.isGarageSpace('garage',1)[2]==0)
cars[3]={takesNoInventorySpace=true,lastKnownLevel='rls_west_coast'}
assert(gm.isGarageSpace('garage',3)[1])
cars[4]={location='garage',lastKnownLevel='italy'}
assert(not gm.isGarageSpace('garage',4)[1])
receipts['1000-1']=nil
assert(gm.isGarageSpace('garage',1)[1])
api.stop()
assert(gm.isGarageSpace==nativeSpace)
print('PASS: real release garage capacity preserves confirmed returning cars and space exemptions, reserves pending purchases, rejects foreign-map assignments and restores hooks')
