-- The server coordinates durable decisions; local RLS snapshots own wallet/inventory effects.
local M = {}
function M.new(ctx)
  local MP, root = ctx.mp, ctx.root
  local encode, decode = ctx.encode, ctx.decode
  local wire = ctx.wire.new(encode, decode, function(id, raw) MP.TriggerClientEvent(id, 'rlsmpTeamx_Trade', raw) end)
  local players, offers, transactions, locks, limits = {}, {}, {}, {}, {}
  local listings, reserved, sold = {}, {}, {}
  local counter, healthy = 0, false
  local api = {}
  local function send(id, data) wire.send(id, data) end
  local function errorTo(id, message) send(id, {op='error', message=message}) end
  local function copy(t) return decode(encode(t)) end
  local function identity(id)
    if type(id) ~= 'number' or not MP.IsPlayerConnected(id) or MP.IsPlayerGuest(id) then return end
    local account = tostring((MP.GetPlayerIdentifiers(id) or {}).beammp or '')
    if account:match('^%d+$') and #account <= 20 and not account:match('^0+$') then return account end
  end
  local function profileOK(account, profile)
    local prefix = 'beammp_' .. account
    return type(profile) == 'string' and #profile <= 100 and (profile == prefix or profile:sub(1,#prefix+1) == prefix..'_')
      and profile:match('^[%w_%-]+$')
  end
  local function persist(tx)
    local raw = encode(tx)
    local f = io.open(root .. 'trades.jsonl', 'ab')
    if not f then healthy=false; return false end
    local ok = f:write(raw .. '\n') and f:flush()
    local closed = f:close()
    if not ok or not closed then healthy=false; print('[RLSMP] Trade journal write failed; exchanges suspended.'); return false end
    if tx.type=='listing' then listings[tx.id]=tx else
      transactions[tx.id] = tx
      if tx.listingId then
        if tx.state=='commit' then sold[tx.listingId]=tx.id end
        if tx.done.from and tx.done.to then
          if reserved[tx.listingId]==tx.id then reserved[tx.listingId]=nil end
        else reserved[tx.listingId]=tx.id end
      end
    end
    return true
  end
  local function nextId() counter=counter+1;return tostring(os.time())..'-'..counter end
  local function centsOK(n) return type(n)=='number' and n%1==0 and n>=1 and n<=10000000000 end
  local function vehicleOK(v)
    return type(v)=='table' and type(v.record)=='table' and type(v.parts)=='table'
      and type(v.record.model)=='string' and #v.record.model<100 and type(v.record.config)=='table' and #encode(v)<=850000
  end
  local function participant(tx, account)
    if tx.from.account == account then return tx.from, 'from' end
    if tx.to.account == account then return tx.to, 'to' end
  end
  local function playerFor(party)
    for id, p in pairs(players) do
      if p.account == party.account and p.profile == party.profile and MP.IsPlayerConnected(id) then return id end
    end
  end
  local function deliver(tx)
    if not healthy then return end
    for _, role in ipairs({'from','to'}) do
      local party = tx[role]
      local id = playerFor(party)
      if id and not tx.done[role] and not (tx.listingId and role=='from' and tx.state=='prepare') then
        local payload=tx
        if tx.listingId and role=='from' then payload=copy(tx);payload.vehicle=nil end
        send(id, {op='transaction', tx=payload, role=role})
      end
    end
  end
  local function listingCommand(l)
    if not healthy then return end
    local id=playerFor(l.from)
    if id and (l.state=='publishing' or l.state=='withdrawing') then
      send(id,{op='listingCommand',listing={id=l.id,serverId=l.serverId,from=l.from,vehicleId=l.vehicleId,cents=l.cents,state=l.state}})
    end
  end
  local function unlock(tx)
    if tx.listingId and tx.state=='commit' and tx.done.to and locks[tx.to.account]==tx.id then locks[tx.to.account]=nil end
    if tx.done.from and tx.done.to then
      if locks[tx.from.account] == tx.id then locks[tx.from.account] = nil end
      if locks[tx.to.account] == tx.id then locks[tx.to.account] = nil end
    end
  end
  local function state(id)
    local self = players[id]; if not self then return end
    local data = {op='state', enabled=healthy, marketplace=true, players={}, incoming={}, outgoing={}, pending={},listings={},myListings={}}
    for otherId, p in pairs(players) do
      if otherId ~= id and MP.IsPlayerConnected(otherId) then data.players[#data.players+1]={id=otherId,name=p.name} end
    end
    for _, offer in pairs(offers) do
      if offer.from.account == self.account then data.outgoing[#data.outgoing+1]=offer end
      if offer.to.account == self.account then data.incoming[#data.incoming+1]=offer end
    end
    for key,l in pairs(listings) do
      if l.state~='withdrawn' and not sold[key] then
        local row={id=key,title=l.title,cents=l.cents,model=l.model,year=l.year,created=l.created,seller=l.from.name,
          profile=l.from.profile,own=l.from.account==self.account,online=playerFor(l.from)~=nil,state=reserved[key] and 'reserved' or l.state}
        if l.state=='active' then data.listings[#data.listings+1]=row end
        if row.own then data.myListings[#data.myListings+1]=row end
      end
    end
    local function newest(a,b) if a.created==b.created then return a.id>b.id end;return a.created>b.created end
    table.sort(data.listings,newest);table.sort(data.myListings,newest)
    for _, tx in pairs(transactions) do
      local party, role = participant(tx, self.account)
      if party and not (tx.done.from and tx.done.to) and not (tx.listingId and tx.state=='commit' and tx.done[role]) then
        data.pending[#data.pending+1]={id=tx.id,state=tx.state,profile=party.profile,waitingForOther=tx.done[role]==true}
      end
    end
    send(id,data)
  end
  local function broadcast() for id in pairs(players) do state(id) end end
  local function abort(tx, reason)
    if tx.state ~= 'prepare' then return end
    local nextTx=copy(tx); nextTx.state='abort'; nextTx.reason=reason
    if tx.listingId then nextTx.done.from=true end
    if persist(nextTx) then deliver(nextTx) end
  end
  function api.init()
    if healthy then return end
    local file = io.open(root .. 'trades.jsonl','rb')
    if file then
      local raw=file:read('*a'); file:close()
      if #raw > 0 and raw:sub(-1) ~= '\n' then print('[RLSMP] Incomplete trade journal; exchanges suspended for recovery.'); return end
      for line in raw:gmatch('[^\n]+') do
        local ok, tx=pcall(decode,line)
        local valid=ok and type(tx)=='table' and tx.serverId==ctx.serverId and type(tx.id)=='string' and type(tx.from)=='table'
        if valid and tx.type=='listing' then
          valid=tx.state=='publishing' or tx.state=='active' or tx.state=='withdrawing' or tx.state=='withdrawn'
        elseif valid then valid=type(tx.done)=='table' and type(tx.to)=='table' and (tx.state=='prepare' or tx.state=='commit' or tx.state=='abort') end
        if not valid then
          print('[RLSMP] Invalid trade journal; exchanges suspended for recovery.'); return
        end
        if tx.type=='listing' then listings[tx.id]=tx else
          transactions[tx.id]=tx
          if tx.listingId then
            if tx.state=='commit' then sold[tx.listingId]=tx.id end
            if tx.done.from and tx.done.to then
              if reserved[tx.listingId]==tx.id then reserved[tx.listingId]=nil end
            else reserved[tx.listingId]=tx.id end
          end
        end
        counter=math.max(counter,tonumber(tx.sequence) or 0)
      end
    end
    healthy=true
    for _, tx in pairs(transactions) do
      if not (tx.done.from and tx.done.to) then
        if not tx.listingId then locks[tx.from.account]=tx.id end
        if not (tx.listingId and tx.state=='commit' and tx.done.to) then locks[tx.to.account]=tx.id end
        -- A pre-commit server restart always rolls back; committed decisions never change.
        if tx.state=='prepare' then abort(tx,'Server restarted before confirmation.') end
      end
    end
  end
  local function handle(id, msg)
    local account=identity(id); if not account then return end
    if msg.op=='ready' then
      if not profileOK(account,msg.profile) then return end
      for otherId,p in pairs(players) do if otherId~=id and p.account==account then return errorTo(id,'This account is already connected to exchanges.') end end
      local old=players[id]
      if old and old.profile~=msg.profile then api.disconnect(id) end
      players[id]={account=account,profile=msg.profile,name=tostring(MP.GetPlayerName(id) or 'Player'):gsub('%c',''):sub(1,64),market=msg.market==1}
      if not old or old.profile~=msg.profile then broadcast() else state(id) end
      for _,tx in pairs(transactions) do local p=participant(tx,account); if p and p.profile==msg.profile then deliver(tx) end end
      for _,l in pairs(listings) do if l.from.account==account and l.from.profile==msg.profile then listingCommand(l) end end
      return
    end
    local self=players[id]; if not self or self.account~=account then return end
    if msg.op=='away' then api.disconnect(id); return end
    if msg.op=='refresh' then state(id); return end
    if not healthy then return errorTo(id,'The exchange journal is unavailable.') end
    if msg.op=='publish' then
      if not self.market then return errorTo(id,'Update the RLSMP client to use the marketplace.') end
      if locks[account] then return errorTo(id,'Finish your pending transaction first.') end
      if not centsOK(msg.cents) or type(msg.vehicleId)~='number' or msg.vehicleId%1~=0 or msg.vehicleId<1 then return errorTo(id,'Invalid listing price or vehicle.') end
      local own,total=0,0
      for key,l in pairs(listings) do
        if l.state~='withdrawn' and not sold[key] then
          total=total+1
          if l.from.account==account then
            own=own+1
            if l.from.profile==self.profile and l.vehicleId==msg.vehicleId then return errorTo(id,'This car is already listed.') end
          end
        end
      end
      if own>=10 or total>=200 then return errorTo(id,'The marketplace listing limit has been reached.') end
      local l={type='listing',id=nextId(),sequence=counter,serverId=ctx.serverId,from=copy(self),vehicleId=msg.vehicleId,
        cents=msg.cents,title='Vehicle',state='publishing',created=os.time()}
      if persist(l) then listingCommand(l);broadcast() else errorTo(id,'The listing could not be saved.') end
      return
    end
    if msg.op=='listed' or msg.op=='listingRejected' or msg.op=='withdraw' or msg.op=='listingWithdrawn' then
      local l=listings[msg.id]
      if not l or l.from.account~=account then return errorTo(id,'Listing not found or not owned by this account.') end
      if l.from.profile~=self.profile then return errorTo(id,'Load the career that owns this listing first.') end
      if (msg.op=='listed' or msg.op=='listingRejected') and l.state~='publishing' then return end
      if msg.op=='listingWithdrawn' and l.state~='withdrawing' then return end
      if reserved[l.id] or sold[l.id] then return errorTo(id,'This listing is being purchased or has already been sold.') end
      local nextListing=copy(l)
      if msg.op=='listed' then
        if l.state~='publishing' then return end
        if not vehicleOK(msg.vehicle) then return errorTo(id,'Vehicle data is invalid or too large.') end
        nextListing.vehicle=msg.vehicle
        local record=msg.vehicle.record
        nextListing.title=tostring(record.niceName or record.model):gsub('%c','')
        if #nextListing.title>100 then nextListing.title=record.model end
        nextListing.model=record.model;nextListing.year=tonumber(record.year);nextListing.state='active'
      elseif msg.op=='listingRejected' then
        if l.state~='publishing' then return end
        nextListing.state='withdrawn'
      elseif msg.op=='withdraw' then
        if l.state=='withdrawn' then return end
        if locks[account] then return errorTo(id,'Finish your pending transaction first.') end
        nextListing.state='withdrawing'
      else
        if l.state~='withdrawing' then return end
        nextListing.state='withdrawn';nextListing.vehicle=nil
      end
      if persist(nextListing) then listingCommand(nextListing);broadcast() end
      return
    end
    if msg.op=='buy' then
      if not self.market then return errorTo(id,'Update the RLSMP client to use the marketplace.') end
      local l=listings[msg.id]
      if not l or l.state~='active' or sold[msg.id] then return errorTo(id,'This listing is no longer available.') end
      if l.from.account==account then return errorTo(id,'You cannot buy your own car.') end
      if reserved[l.id] or locks[account] or locks[l.from.account] then return errorTo(id,'This car or account already has a pending transaction.') end
      local tx={id=nextId(),sequence=counter,serverId=ctx.serverId,kind='car',cents=l.cents,title=l.title,vehicleId=l.vehicleId,
        from=copy(l.from),to=copy(self),listingId=l.id,vehicle=l.vehicle,state='prepare',prepared={from=true},done={},started=os.time()}
      if not persist(tx) then return errorTo(id,'The purchase could not be saved.') end
      locks[account]=tx.id
      deliver(tx);broadcast();return
    end
    if msg.op=='offer' then
      local target=players[msg.target]
      if not target or target.account==account or not MP.IsPlayerConnected(msg.target) then return errorTo(id,'Player unavailable.') end
      if locks[account] or locks[target.account] then return errorTo(id,'A transaction is waiting for a save or recovery.') end
      if msg.kind~='money' and msg.kind~='car' then return end
      if type(msg.cents)~='number' or msg.cents%1~=0 or msg.cents<1 or msg.cents>10000000000 then return errorTo(id,'Invalid amount.') end
      if msg.kind=='car' and (type(msg.vehicleId)~='number' or msg.vehicleId%1~=0 or msg.vehicleId<1) then return end
      local n=0; for _,offer in pairs(offers) do if offer.from.account==account then n=n+1 end end
      if n>=5 then return errorTo(id,'You can have up to five direct offers at a time.') end
      counter=counter+1
      local offer={id=tostring(os.time())..'-'..counter,sequence=counter,kind=msg.kind,cents=msg.cents,vehicleId=msg.vehicleId,
        title=tostring(msg.title or 'Vehicle'):gsub('%c',''):sub(1,100),from=copy(self),to=copy(target),created=os.time()}
      offers[offer.id]=offer; broadcast(); return
    end
    if msg.op=='cancel' or msg.op=='accept' then
      local offer=offers[msg.id]; if not offer then return errorTo(id,'This offer has expired.') end
      if msg.op=='cancel' then
        if account==offer.from.account or account==offer.to.account then offers[offer.id]=nil; broadcast() end
        return
      end
      if offer.to.account~=account or offer.to.profile~=self.profile or not playerFor(offer.from) then return end
      if locks[account] or locks[offer.from.account] then return errorTo(id,'A transaction is already in progress.') end
      local tx=copy(offer); tx.serverId=ctx.serverId; tx.state='prepare'; tx.prepared={}; tx.done={}; tx.started=os.time()
      if not persist(tx) then return errorTo(id,'The transaction could not be saved.') end
      locks[tx.from.account]=tx.id; locks[tx.to.account]=tx.id
      -- Competing offers cannot survive a transaction involving their participants.
      for key,o in pairs(offers) do if locks[o.from.account] or locks[o.to.account] then offers[key]=nil end end
      deliver(tx); broadcast(); return
    end
    if msg.op=='prepared' or msg.op=='rejected' or msg.op=='done' then
      local tx=transactions[msg.id]; if not tx then return end
      local party,role=participant(tx,account)
      if not party or party.profile~=self.profile then return end
      if msg.op=='rejected' then abort(tx,'Local validation failed.'); broadcast(); return end
      if msg.op=='prepared' then
        if tx.state~='prepare' then deliver(tx); return end
        if tx.prepared[role] then return end
        local nextTx=copy(tx)
        if tx.kind=='car' and role=='from' then
          if type(msg.vehicle)~='table' or type(msg.vehicle.record)~='table' or type(msg.vehicle.parts)~='table'
            or type(msg.vehicle.record.model)~='string' or type(msg.vehicle.record.config)~='table'
            or #encode(msg.vehicle)>850000 then return abort(tx,'Vehicle data is invalid or too large.') end
          nextTx.vehicle=msg.vehicle
        end
        nextTx.prepared[role]=true
        if nextTx.prepared.from and nextTx.prepared.to then nextTx.state='commit' end
        if persist(nextTx) then deliver(nextTx); broadcast() end
        return
      end
      if tx.state=='prepare' then return end
      if tx.done[role] then return end
      local nextTx=copy(tx); nextTx.done[role]=true
      if persist(nextTx) then unlock(nextTx); broadcast() end
    end
  end
  function api.receive(id,raw)
    if not identity(id) then return end
    local now=os.time(); local rate=limits[id]
    if not rate or now-rate.at>=10 then rate={at=now,n=0}; limits[id]=rate end
    rate.n=rate.n+1; if rate.n>400 then return end
    local msg=wire.receive(id,raw)
    if msg then handle(id,msg) end
  end
  function api.disconnect(id)
    local p=players[id]; players[id]=nil; limits[id]=nil; wire.forget(id)
    if p then
      for key,o in pairs(offers) do if o.from.account==p.account or o.to.account==p.account then offers[key]=nil end end
      for _,tx in pairs(transactions) do
        if participant(tx,p.account) and not (tx.listingId and tx.from.account==p.account) then abort(tx,'Player disconnected before confirmation.') end
      end
      broadcast()
    end
  end
  function api.tick()
    wire.tick(5)
    if not healthy then return end
    local changed=false
    for id,o in pairs(offers) do if os.time()-o.created>180 then offers[id]=nil; changed=true end end
    for _,tx in pairs(transactions) do
      if not (tx.done.from and tx.done.to) then
        if tx.state=='prepare' and os.time()-tx.started>90 then abort(tx,'Confirmation timed out.') else deliver(tx) end
      end
    end
    for _,l in pairs(listings) do listingCommand(l) end
    if changed then broadcast() end
  end
  return api
end
return M
