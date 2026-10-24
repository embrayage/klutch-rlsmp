-- Uses the two-client transactional harness above; listing commands travel over real chunking.
queue={};server=newServer();a=freshClient(1);b=freshClient(2);local c=freshClient(4);pump()
local function car(owner,id,name)
  owner.vehicles[id]={id=id,model='pickup',niceName=name or 'Marketplace truck',owned=true,location='garage',year=2002,
    config={parts={engine='v8'}},partConditions={engine={odometer=43210}},maintenanceState={wear=0.2}}
  owner.parts[id]={location=id,name='engine',partPath='/engine',containingSlot='/',partCondition={odometer=43210}}
end
local function publish(owner,id,price)
  assert(owner.api.action('publish',0,price,id,'').ok);pump()
  assert(owner.vehicles[id].rlsmpTradeLock)
  local key=owner.vehicles[id].rlsmpTradeLock
  settle();return key
end
car(a,10,'First truck');car(a,11,'Second truck')
assert(a.api.action('publish',0,1000,10,'').ok);pump()
assert(#b.api.status().listings==0,'listing cannot go public before the local escrow save')
assert(a.wantSave and a.vehicles[10].rlsmpTradeLock)
local first=a.vehicles[10].rlsmpTradeLock
settle();assert(#b.api.status().listings==1)
assert(a.wallet==10000 and b.wallet==10000)
assert(a.api.action('publish',0,1000,10,'').error,'a listed car is locked')
local second=publish(a,11,1200)
assert(#b.api.status().listings==2)
-- No three-minute expiry, and no removal on seller disconnect.
clock=clock+1000;server.tick();pump();b.api.action('refresh',0,0,0,'');pump()
assert(#b.api.status().listings==2)
a.connected=false;server.disconnect(1);pump()
assert(#b.api.status().listings==2 and not b.api.status().listings[1].online)
-- Both listings survive a server restart while their seller is offline.
queue={};server=newServer();b=freshClient(2);c=freshClient(4);pump()
assert(#b.api.status().listings==2)
-- Two simultaneous buyers: only the first reserves the listing; submitted prices are ignored.
assert(b.api.action('buy',0,0,0,first).ok)
assert(c.api.action('buy',0,0,0,first).ok);pump()
assert(b.wallet==9000 and c.wallet==10000)
settle()
assert(b.vehicles[1] and b.vehicles[1].niceName=='First truck')
assert(b.vehicles[1].partConditions.engine.odometer==43210 and b.parts[1].location==1)
assert(not next(c.vehicles) and #b.api.status().listings==1)
assert(#b.api.status().pending==0,'a completed buyer need not wait for an offline seller')
-- The same offline seller can sell another reserved car without blocking the first buyer.
assert(b.api.action('buy',0,0,0,second).ok);settle()
assert(b.wallet==7800 and b.vehicles[2] and #b.api.status().listings==0)
local sellerDisk=clone(a.disk)
queue={};server=newServer();b=freshClient(2,b.disk);c=freshClient(4,c.disk);pump()
assert(#b.api.status().listings==0 and b.wallet==7800)
a=freshClient(1,sellerDisk);settle()
assert(not a.vehicles[10] and not a.vehicles[11] and a.wallet==12200)
server.tick();settle();assert(a.wallet==12200 and b.wallet==7800)
-- Owner-only withdrawal, on the original profile, restores the actual car after saving.
car(c,20,'Withdraw me');local withdrawId=publish(c,20,500)
local attacker=wireModule.new(json.encode,json.decode,function(_,raw) server.receive(2,raw) end)
attacker.send(0,{op='withdraw',id=withdrawId});pump()
assert(c.vehicles[20].rlsmpTradeLock==withdrawId and #b.api.status().listings==1)
local ownWire=wireModule.new(json.encode,json.decode,function(_,raw) server.receive(4,raw) end)
ownWire.send(0,{op='ready',profile='beammp_400_other',market=1});pump()
ownWire.send(0,{op='withdraw',id=withdrawId});pump()
assert(c.vehicles[20].rlsmpTradeLock==withdrawId)
ownWire.send(0,{op='ready',profile='beammp_400',market=1});pump()
assert(c.api.action('withdraw',0,0,0,withdrawId).ok);settle()
assert(c.vehicles[20] and not c.vehicles[20].rlsmpTradeLock and #b.api.status().listings==0)
-- Failed buyer checks leave a persistent listing active, with no seller payout.
car(c,21,'Keep listed');local keep=publish(c,21,600)
b.wallet=0;assert(b.api.action('buy',0,0,0,keep).ok);settle()
assert(b.wallet==0 and c.wallet==10000 and #b.api.status().listings==1)
assert(b.api.status().listings[1].state=='active' and c.vehicles[21].rlsmpTradeLock==keep)
b.wallet=5000;b.capacity=2
assert(b.api.action('buy',0,0,0,keep).ok);settle()
assert(b.wallet==5000 and #b.api.status().listings==1)
b.capacity=3
-- A restart after escrow saved but before its publication acknowledgement replays once.
car(c,22,'Publish after restart')
assert(c.api.action('publish',0,700,22,'').ok);pump();local delayed=c.vehicles[22].rlsmpTradeLock
c.save();queue={};local pendingPublish=clone(c.disk)
server=newServer();a.connected=false;b.connected=false
c=freshClient(4,pendingPublish);settle()
assert(#c.api.status().myListings==2)
local seen=false;for _,l in ipairs(c.api.status().myListings) do if l.id==delayed and l.state=='active' then seen=true end end
assert(seen)
-- A withdrawal interrupted after its local save resumes without duplicating or losing the car.
assert(c.api.action('withdraw',0,0,0,delayed).ok);pump();c.save();queue={}
local pendingWithdraw=clone(c.disk);server=newServer();c=freshClient(4,pendingWithdraw);settle()
assert(c.vehicles[22] and not c.vehicles[22].rlsmpTradeLock and #c.api.status().myListings==1)
print('PASS: persistent public listings, save-before-publish, offline sales, two-buyer race, repeated purchases, restart recovery, seller payout once, ownership/profile checks, withdrawal and failed-purchase relisting')

-- BETA prepares an NPC auction asynchronously: no second marketplace may reserve it.
car(c,30,'Preparing auction')
c.auctionPending=30
assert(c.api.action('publish',0,700,30,'').error)
assert(not c.vehicles[30].rlsmpTradeLock)
c.auctionPending=nil
local betaListing=publish(c,30,700)
assert(c.vehicles[30].rlsmpTradeLock==betaListing)
assert(c.api.action('withdraw',0,0,0,betaListing).ok);settle()
