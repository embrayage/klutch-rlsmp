-- Exercise RLS's complete inventory loader, with the inconsistent saved fleet found in game.
local multiplayer=true
MPCoreNetwork={isMPSession=function() return multiplayer end}
package.preload['overhaul/lib/world/levelData']=function() return {loadMaps=function() return {rls_west_coast={}} end} end
package.preload['overhaul/career/garage/inventory/vehicleMap']=function() return dofile(VEHICLE_MAP_PATH) end
local function copy(v)
  if type(v)~='table' then return v end
  local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r
end
deepcopy=copy
vec3=function(v) return copy(v) end
quat=function(v) return copy(v) end
deserialize=function(v) return copy(v) end
tableSize=function(v) local n=0; for _ in pairs(v) do n=n+1 end; return n end
table.clear=function(v) for k in pairs(v) do v[k]=nil end end
getCurrentLevelIdentifier=function() return 'rls_west_coast' end
log=function() end
overhaul_career_career={isActive=function() return true end}
overhaul_career_saveSystem={getCurrentProfile=function() return 'beammp_100_profile1','save/autosave2' end}
overhaul_career_saveMigration={getPreparedMigration=function() return nil end}
local snapshot, records
FS={findFiles=function() return {'car1','car2','car3','car4'} end,fileExists=function() return true end}
jsonReadFile=function(path)
  if path=='save/autosave2/info.json' then return {version=64,date='saved'} end
  if path=='save/autosave2/career/general.json' then return {level='rls_west_coast',justSwitched=false} end
  if path=='save/autosave2/career/inventory.json' then return copy(snapshot) end
  local id=tonumber(path:match('^car(%d+)$')); return id and copy(records[id])
end
local function load(path, fleet)
  snapshot=copy(fleet)
  records={}
  for id=1,4 do
    records[id]={id=id,model='car'..id,location='servicestationGarage',lastKnownLevel='rls_west_coast',
      config={parts={engine='engine'..id}},partConditions={engine={wear=0.2}}}
    if id~=1 then records[id].worldPosition={level='rls_west_coast',pos={x=id,y=0,z=0},rot={w=1}} end
  end
  local inputs={vehicles={},state={},travel={},M={},vehIdToInventoryId={},inventoryIdToVehId={},minimumVersion=64,
    saveAnyVehiclePosDEBUG=true,dateUtils={},sanitizeMaintenancePartConditionsForVehicle=function(_,v) return v end}
  local api=dofile(path).new(inputs)
  api.bindInputs({bumpAllGenerations=function() end})
  api.onExtensionLoaded()
  -- Owned records, modifications, wear and garage assignments are retained even when unspawned.
  for id=1,4 do
    assert(inputs.vehicles[id].location=='servicestationGarage')
    assert(inputs.vehicles[id].config.parts.engine=='engine'..id)
    assert(inputs.vehicles[id].partConditions.engine.wear==0.2)
  end
  return inputs
end
local saved={currentVehicle=4,lastVehicle=4,favoriteVehicle=1,
  spawnedPlayerVehicles={['4']={pos={x=99},rot={w=1}}}}
local baseline=load(ORIGINAL_SETUP_PATH,saved)
assert(tableSize(baseline.state.loadedVehiclesLocations)==3) -- reproduces the reported restoration
local result=load(PATCHED_SETUP_PATH,saved)
local locations=result.state.loadedVehiclesLocations
assert(tableSize(locations)==1 and locations[4].pos.x==99 and result.state.vehicleToEnterId==4)
assert(not locations[2] and not locations[3])
local empty=load(PATCHED_SETUP_PATH,{spawnedPlayerVehicles={}})
assert(next(empty.state.loadedVehiclesLocations)==nil and empty.state.vehicleToEnterId==nil)
local multiple=load(PATCHED_SETUP_PATH,{currentVehicle=4,
  spawnedPlayerVehicles={['2']={pos={x=22}},['4']={pos={x=44}}}})
assert(tableSize(multiple.state.loadedVehiclesLocations)==2)
assert(multiple.state.loadedVehiclesLocations[2].pos.x==22 and multiple.state.loadedVehiclesLocations[4].pos.x==44)
local array=load(PATCHED_SETUP_PATH,{currentVehicle=4,spawnedPlayerVehicles={{pos={x=44}}}})
assert(tableSize(array.state.loadedVehiclesLocations)==1 and array.state.loadedVehiclesLocations[4].pos.x==44)
local legacy=load(PATCHED_SETUP_PATH,{lastVehicle=4})
assert(tableSize(legacy.state.loadedVehiclesLocations)==3)
multiplayer=false
local solo=load(PATCHED_SETUP_PATH,saved)
assert(tableSize(solo.state.loadedVehiclesLocations)==3 and solo.state.loadedVehiclesLocations[4].pos.x==4)
