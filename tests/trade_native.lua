-- Execute the actual patched RLS checks, not replicas of the bridge's lock policy.
local vehicles={[1]={owned=true,rlsmpTradeLock='1000-1'},[2]={owned=true},[3]={owned=true,listedForAuction=true}}
local inputs={vehicles=vehicles}
local inventoryIdToVehId={}
local permissionTags={notOwned={}}
local AUCTION_LOCKED_TAGS
-- ACTUAL_LOCKED_TAGS
local M={canBuildLot=function() return true end}
-- ACTUAL_CONSIGNMENT
local helpers={}
local paid=0
overhaul_career_logistics_general={canRemoveLogisticsVehicle=function() return true end}
overhaul_career_economy_playerAttributes={addAttributes=function() paid=paid+1;error('locked sale paid out') end}
local messages=0
ui_message=function() messages=messages+1 end
-- ACTUAL_IS_LISTED
-- ACTUAL_SET_LISTED
-- ACTUAL_SELL
-- ACTUAL_RECOVERABLE
-- ACTUAL_PERMISSIONS
-- ACTUAL_VALIDATE_SPAWN
assert(M.saleBlockReason(1,vehicles[1])=='Reserved for player exchange')
assert(M.saleBlockReason(2,vehicles[2])==nil)
assert(isVehicleListedForAuction(1))
assert(not isVehicleListedForAuction(2))
assert(isVehicleListedForAuction(3))
assert(setVehicleListedForAuction(1,true)==false)
assert(setVehicleListedForAuction(1,false)==false)
assert(sellVehicle(1,500)==false and paid==0)
assert(not isRecoverablePersonalVehicle(1))
assert(not validateSpawnRecord(1) and messages==1)
for _,tag in ipairs({'vehicleSelling','partBuying','partSwapping','tuning','painting','vehicleRepair','junkVehicle'}) do
  local permissions={}
  onOverhaulCheckPermission({tag},permissions,{inventoryId=1})
  local forbidden=false
  for _,p in ipairs(permissions) do if p.permission=='forbidden' then forbidden=true end end
  assert(forbidden,tag)
end
vehicles[1].rlsmpTradeLock=nil
assert(not isVehicleListedForAuction(1))
assert(isRecoverablePersonalVehicle(1))
print('PASS: actual RLS guards block spawning, recovery, resale, auction listing, parts, tuning and repairs while a peer transaction holds the vehicle')
