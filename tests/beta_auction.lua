-- Exercise BETA's full asynchronous listing module against the patched consignment rule.
local nativeRequire=require
local consignment
require=function(name)
  if name=='overhaul/lib/vehicles/buildConfig' then return {canBuild=function() return true end} end
  if name=='overhaul/lib/platform/capabilities' then return {} end
  if name=='overhaul/career/market/auction/constants' then return {MAX_CONSIGNMENT_LISTINGS=3} end
  if name=='overhaul/career/market/auction/consignment' then return consignment end
  return nativeRequire(name)
end
consignment=dofile(BETA_BASE..'/market/auction/consignment.lua')
local persistence=dofile(BETA_BASE..'/garage/inventory/persistence.lua')
local vehicle={owned=true,model='pickup',config={parts={}}}
local conditions,damage,completed,removed,jobs=nil,nil,0,0,{}
local inputs={vehicles={[1]=vehicle},inventoryIdToVehId={[1]=99},dirtiedVehicles={},M={
  updatePartConditions=function(_,id,cb) assert(id==1);conditions=cb end,
  removeVehicleObject=function(id,force) assert(id==1 and force);removed=removed+1 end,
}}
overhaul_career_logistics_general={canRemoveLogisticsVehicle=function() return true end}
overhaul_career_repair_insurance={inventoryVehNeedsRepair=function() return false end}
overhaul_career_repair_damageManager={captureDamageState=function(id,cb) assert(id==1);damage=cb;return true end}
ui_message=function() end
core_jobsystem={create=function(fn) jobs[#jobs+1]=fn end}
local api=persistence.new(inputs)
local function begin()
  assert(not api.setVehicleListedForAuction(1,true,function() completed=completed+1 end))
  assert(api.isAuctionListingPending(1))
end
begin()
vehicle.rlsmpTradeLock='player-market'
conditions()
assert(not api.isAuctionListingPending(1) and not damage and removed==0 and completed==0)
vehicle.rlsmpTradeLock=nil
begin();conditions();assert(damage)
vehicle.rlsmpTradeLock='player-market'
damage(true)
assert(not api.isAuctionListingPending(1) and not vehicle.listedForAuction and removed==0 and completed==0)
assert(api.auctionListingBlockReason(1)=='Reserved for player exchange')
vehicle.rlsmpTradeLock=nil
begin();conditions();damage(true)
assert(vehicle.listedForAuction and not api.isAuctionListingPending(1) and removed==1 and completed==1)
print('PASS: BETA async auction rechecks peer escrow after conditions and damage capture; refused cars stay in the world, normal auctions still complete')
