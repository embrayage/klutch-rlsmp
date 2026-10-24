-- Two independent clients, real Lua JSON, chunked transport and transactional save snapshots.
unpack=table.unpack
local json=require('libs/lunajson/lunajson')
local function clone(v) if type(v)~='table' then return v end; local r={};for k,x in pairs(v) do r[k]=clone(x) end;return r end
local wireModule=require('rlsmpTeamx/tradeWire')
local serverModule=dofile(SERVER_TRADE_PATH)
local clients,queue={},{}
local journal,writeFail,clock='',false,1000
os.time=function() return clock end
local actualOpen=io.open
io.open=function(path,mode)
  assert(path=='test/trades.jsonl')
  if mode=='rb' then return #journal>0 and {read=function() return journal end,close=function() return true end} or nil end
  assert(mode=='ab'); if writeFail then return nil end
  return {write=function(_,s) journal=journal..s; return true end,flush=function() return true end,close=function() return true end}
end
local mp={
  IsPlayerConnected=function(id) return clients[id] and clients[id].connected end,
  IsPlayerGuest=function(id) return id==3 end,
  GetPlayerIdentifiers=function(id) return {beammp=tostring(id*100)} end,
  GetPlayerName=function(id) return 'Player '..id end,
  TriggerClientEvent=function(id,event,raw) queue[#queue+1]={to=id,event=event,raw=raw}; return true end,
}
local function newServer()
  local s=serverModule.new({mp=mp,root='test/',serverId=string.rep('a',32),encode=json.encode,decode=json.decode,wire=wireModule});s.init();return s
end
local server=newServer()
local function freshClient(id,disk)
  local c={id=id,connected=true,profile='beammp_'..id*100,disk=disk,requests=0,errors={}}
  c.wallet=disk and disk.wallet or 10000
  c.vehicles=disk and clone(disk.vehicles) or {}
  c.parts=disk and clone(disk.parts) or {}
  c.capacity=3; c.handlers={}; c.savedSnapshot=nil; c.saving=false
  local env=setmetatable({}, {__index=_G});env._G=env
  env.jsonEncode=json.encode;env.jsonDecode=json.decode;env.deepcopy=clone
  env.jsonReadFile=function() return c.disk and clone(c.disk.receipts) end
  env.getCurrentLevelIdentifier=function() return 'rls_west_coast' end
  env.guihooks={trigger=function() end}
  env.AddEventHandler=function(name,fn) c.handlers[name]=fn end
  env.RemoveEventHandler=function(name) c.handlers[name]=nil end
  env.TriggerServerEvent=function(event,raw) queue[#queue+1]={from=id,event=event,raw=raw} end
  env.overhaul_career_economy_playerAttributes={
    getAttributeValue=function() return c.wallet end,
    addAttributes=function(values,reason) assert(reason.testerForce and reason.tags[1]=='rlsmpTrade'); c.wallet=c.wallet+values.money end,
  }
  env.overhaul_career_economy_cheats={isCheatsMode=function() return c.cheats end}
  env.overhaul_career_logistics_general={canRemoveLogisticsVehicle=function() return not c.activity end}
  env.overhaul_career_repair_insurance={onOverhaulVehicleAddedToInventory=function(data) c.uninsured=data.inventoryId end}
  local gm={getFreeSlots=function() local n=0;for _ in pairs(c.vehicles) do n=n+1 end;return c.capacity-n end,
    isGarageSpace=function() local n=0;for _ in pairs(c.vehicles) do n=n+1 end;return {n<c.capacity,c.capacity-n} end}
  env.overhaul_career_garage_garageManager=gm
  env.overhaul_career_garage_inventory={
    getVehicles=function() return c.vehicles end,
    getVehicleIdFromInventoryId=function(v) return c.spawned==v and 999 or nil end,
    isTransientBuild=function() return false end,
    isAuctionListingPending=function(id) return c.auctionPending==id end,
    setVehicleDirty=function(v) assert(c.vehicles[v]) end,
    hasFreeSlot=function() return gm.getFreeSlots()>0 end,
    getClosestOwnedGarageWithSpace=function() return gm.isGarageSpace('garage')[1] and {id='garage'} end,
    removeVehicle=function(v)
      assert(not c.spawned);c.vehicles[v]=nil
      for partId,p in pairs(c.parts) do if tonumber(p.location)==v then c.parts[partId]=nil end end
    end,
  }
  env.overhaul_career_parts_partInventory={
    getInventory=function() return c.parts end,
    addPartToInventory=function(p) local n=1;while c.parts[n] do n=n+1 end;c.parts[n]=p end,
    onOverhaulPartShoppingTransactionComplete=function() c.mapsUpdated=true end,
  }
  env.overhaul_career_saveSystem={
    getCurrentProfile=function() return c.profile,'snapshot' end,
    isSavePending=function() return c.saving end,
    saveCurrent=function() c.requests=c.requests+1;c.wantSave=true;return true end,
    jsonWriteFileSafe=function(path,data) assert(path=='snapshot/career/rlsmpTrades.json');c.captureReceipt=clone(data);return true end,
  }
  env.core_vehicle_partmgmt={partsTreeToPartsMap=function(tree) return tree.flat end}
  c.api=assert(loadfile(CLIENT_TRADE_PATH,'t',env))().new({
    active=function() return c.connected end,serverId=function() return string.rep('a',32) end,
    accountProfile=function() return 'beammp_'..id*100 end,notice=function(kind,message) c.errors[#c.errors+1]=message end,
  })
  function c.capture()
    assert(c.wantSave and not c.saving)
    c.saving=true;c.wantSave=false;c.api.save('snapshot')
    c.savedSnapshot={wallet=c.wallet,vehicles=clone(c.vehicles),parts=clone(c.parts),receipts=clone(c.captureReceipt)}
  end
  function c.finish()
    assert(c.saving);c.disk=c.savedSnapshot;c.saving=false;c.savedSnapshot=nil;c.api.saved()
  end
  function c.save() c.capture();c.finish() end
  clients[id]=c;c.api.activate();c.api.update(0)
  return c
end
local function pump()
  local steps=0
  while #queue>0 do
    steps=steps+1;assert(steps<3000,'transport feedback loop')
    local packet=table.remove(queue,1)
    if packet.from then server.receive(packet.from,packet.raw)
    else local c=clients[packet.to];if c and c.connected and c.handlers[packet.event] then c.handlers[packet.event](packet.raw) end end
  end
end
local function settle()
  for _=1,12 do
    pump()
    local work=false
    for _,c in pairs(clients) do
      if c.connected then
        c.api.update(0)
        if c.wantSave and not c.saving then c.save();work=true end
      end
    end
    if not work and #queue==0 then return end
  end
  error('transaction did not settle')
end
local function offer(from,to,kind,amount,vehicleId)
  assert(clients[from].api.action(kind,to,amount,vehicleId or 0,'').ok);pump()
  local incoming=clients[to].api.status().incoming
  assert(#incoming==1)
  return incoming[1].id
end
local function accept(to,id) assert(clients[to].api.action('accept',0,0,0,id).ok);pump() end
local a,b=freshClient(1),freshClient(2);pump()
assert(#a.api.status().players==1)
assert(a.api.action('money',2,0,0,'').error)
assert(a.api.action('money',2,0/0,0,'').error)
assert(a.api.action('money',2,10.001,0,'').error)
assert(a.api.action('money',2,20000,0,'').error)
-- Both sides reserve, save, and only then commit; retries cannot duplicate effects.
local id=offer(1,2,'money',123.45);accept(2,id)
assert(a.wallet==9876.55 and b.wallet==10000)
assert(a.wantSave and b.wantSave)
server.tick();pump();assert(a.wallet==9876.55 and b.wallet==10000)
a.save();pump();assert(b.wallet==10000)
b.save();settle();assert(a.wallet==9876.55 and b.wallet==10123.45)
local diskA,diskB=clone(a.disk),clone(b.disk)
server.tick();settle();assert(a.wallet==9876.55 and b.wallet==10123.45)
-- Save failure: no acknowledgement, no payout; a later successful save resumes.
id=offer(1,2,'money',100);accept(2,id)
a.capture();a.saving=false;a.savedSnapshot=nil;a.api.saveFailed();b.save();pump()
assert(b.wallet==10123.45)
a.wantSave=true;a.save();settle();assert(b.wallet==10223.45)
-- Vehicle snapshot: native flat config, exact installed parts and conditions, distinct destination ID.
a.vehicles[4]={id=4,model='pickup',niceName='Truck',owned=true,location='garage',worldPosition={pos={1,2,3}},
  config={partsTree={flat={engine='v8'}},paints={{baseColor={1,0,0,1}}}},partConditions={engine={odometer=54321}},maintenanceState={wear=0.4}}
a.parts[7]={location=4,partName='engine',partPath='/engine',value=4500,partCondition={odometer=54321}}
a.parts[9]={location=0,partName='spare'}
a.spawned=4;assert(a.api.action('car',2,500,4,'').error);a.spawned=nil
id=offer(1,2,'car',500,4);accept(2,id)
assert(a.vehicles[4].rlsmpTradeLock==id and b.wallet==9723.45)
assert(b.api.status().vehicles and #b.api.status().vehicles==0)
settle()
assert(not a.vehicles[4] and not a.parts[7] and a.parts[9])
assert(b.vehicles[1].model=='pickup' and b.vehicles[1].worldPosition==nil)
assert(b.vehicles[1].config.parts.engine=='v8' and not b.vehicles[1].config.partsTree)
assert(b.vehicles[1].partConditions.engine.odometer==54321 and b.vehicles[1].maintenanceState.wear==0.4)
assert(b.parts[1].location==1 and b.parts[1].partCondition.odometer==54321 and b.mapsUpdated and b.uninsured==1)
local earned=a.wallet
server.tick();settle();assert(a.wallet==earned and #b.parts==1)
-- Capacity and changed funds are checked after accepting the offer.
b.capacity=1
a.vehicles[5]=clone(b.vehicles[1]);a.vehicles[5].id=5
id=offer(1,2,'car',50,5);accept(2,id);settle()
assert(a.vehicles[5] and not a.vehicles[5].rlsmpTradeLock and b.wallet==9723.45)
b.capacity=3
id=offer(1,2,'money',10);a.wallet=0;accept(2,id);settle();assert(b.wallet==9723.45)
a.wallet=5000
-- Disconnect after one durable preparation: rollback restores reservations on the same profile.
id=offer(1,2,'money',200);accept(2,id);a.save();pump();assert(a.wallet==4800)
a.connected=false;server.disconnect(1);pump();b.api.update(0);settle()
local interrupted=clone(a.disk)
a=freshClient(1,interrupted);settle();assert(a.wallet==5000)
-- Restart after durable commit, before either client receives the decision.
id=offer(1,2,'money',250);accept(2,id);a.save();b.save()
-- Process only the prepared acknowledgements; hold the resulting client packets.
local prepared=queue;queue={}
for _,p in ipairs(prepared) do if p.from then server.receive(p.from,p.raw) end end
assert(journal:find('"commit"',1,true))
queue={};a.connected=false;b.connected=false
local beforeA,beforeB=clone(a.disk),clone(b.disk)
server=newServer();a=freshClient(1,beforeA);b=freshClient(2,beforeB);settle()
assert(a.wallet==4750 and b.wallet==9973.45)
server.tick();settle();assert(a.wallet==4750 and b.wallet==9973.45)
-- Server restart before the decision rolls back both saved reservations.
id=offer(1,2,'money',50);accept(2,id);a.capture();a.finish();queue={}
beforeA,beforeB=clone(a.disk),clone(b.disk);a.connected=false;b.connected=false
server=newServer();a=freshClient(1,beforeA);b=freshClient(2,beforeB);settle()
assert(a.wallet==4750 and b.wallet==9973.45)
-- Expiration, self transfers, profile spoofing and journal failure are rejected.
id=offer(1,2,'money',1);clock=clock+181;server.tick();pump();assert(#b.api.status().incoming==0)
local old=a.api.status().incoming
a.api.action('money',1,1,0,'');pump();assert(#a.api.status().incoming==#old)
local attack=wireModule.new(json.encode,json.decode,function(_,raw) server.receive(1,raw) end)
attack.send(0,{op='ready',profile='beammp_200_profile1'});pump()
assert(a.api.status().profile=='beammp_100')
writeFail=true;id=offer(1,2,'money',1);accept(2,id);pump();assert(a.wallet==4750 and b.wallet==9973.45)
writeFail=false
-- MARKETPLACE_CASES
-- Actual large snapshots are fragmented, reconstructed once, and never accepted out of bounds.
local emitted={};local wire=wireModule.new(json.encode,json.decode,function(_,raw) emitted[#emitted+1]=raw end)
assert(wire.send(1,{blob=string.rep('x',120000)}));assert(#emitted>10)
local got
for i=#emitted,1,-1 do got=wire.receive(2,emitted[i]) or got end
assert(got and #got.blob==120000)
assert(not wire.receive(2,json.encode({id='1',part=0,total=1,data='{}'})))
assert(not wire.send(1,{blob=string.rep('x',1048576)}))
-- A final save still captures receipts after multiplayer is marked inactive during exit.
local exitClient=freshClient(8)
exitClient.connected=false
exitClient.api.save('snapshot')
assert(exitClient.captureReceipt.profile=='beammp_800')
-- Completed receipts can be copied, pending reservations must remain with the original profile.
local copyDisk={wallet=100,vehicles={},parts={},receipts={serverId=string.rep('a',32),profile='beammp_999',receipts={['1-1']={phase='committed'}}}}
local copied=freshClient(9,copyDisk);assert(copied.api.status().active)
copyDisk.receipts.receipts['1-1'].phase='prepared'
local blocked=freshClient(10,copyDisk);assert(not blocked.api.status().active)
local errors=#blocked.errors;blocked.api.activate();assert(#blocked.errors==errors)
io.open=actualOpen
print('PASS: two-client wallet and vehicle transactions, exact parts/condition transfer, durable receipts, duplicate messages, failed saves, capacity/funds checks, disconnect refunds, server/client restart replay, expiration, spoofing, journal failure and bounded chunk transport')
