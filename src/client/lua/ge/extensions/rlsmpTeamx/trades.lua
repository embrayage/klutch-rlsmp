local M = {}
local wireModule = require('rlsmpTeamx/tradeWire')
local RECEIPTS = '/career/rlsmpTrades.json'
function M.new(ctx)
  local api = {}
  local receipts, durable, captured, pending = {}, {}, nil, nil
  local profile, serverId, registered, elapsed = nil, nil, nil, 10
  local rejectedContext, announced
  local view = {enabled=false, players={}, incoming={}, outgoing={}, pending={}}
  local inbox, hooks = {}, {}
  local wire = wireModule.new(jsonEncode, jsonDecode, function(_, raw) TriggerServerEvent('rlsmpTeamx_Trade', raw) end)
  local function clone(v) return deepcopy(v) end
  local function send(data) if TriggerServerEvent and profile then wire.send(0,data) end end
  local function inv() return overhaul_career_garage_inventory end
  local function parts() return overhaul_career_parts_partInventory end
  local function saves() return overhaul_career_saveSystem end
  local function money() return overhaul_career_economy_playerAttributes end
  local function active() return ctx.active() and saves() and saves().getCurrentProfile()==profile end
  local function changed() guihooks.trigger('RLSMPTradeChanged',{}) end
  local function fail(message) ctx.notice('error',message); view.error=message; changed() end
  local function changeMoney(delta, label)
    if delta==0 then return end
    money().addAttributes({money=delta},{label=label,tags={'rlsmpTrade'},testerForce=true},true)
  end
  local function available()
    local c=overhaul_career_economy_cheats
    return active() and not (c and c.isCheatsMode and c.isCheatsMode())
  end
  local function vehicleProblem(id)
    local v=inv().getVehicles()[id]
    if not v or v.owned~=true or v.loanType or v.businessId or v.listedForAuction or v.rlsmpTradeLock
      or v.timeToAccess or v.pendingTravel or inv().isTransientBuild(id) then return 'This vehicle cannot be sold.' end
    if inv().isAuctionListingPending and inv().isAuctionListingPending(id) then return 'Auction preparation in progress.' end
    if inv().getVehicleIdFromInventoryId(id) then return 'Store the car in your garage before listing it.' end
    if not v.location then return 'The car must be assigned to a garage.' end
    if inv().isVehiclePendingTravel and inv().isVehiclePendingTravel(id) then return 'Map transfer in progress.' end
    local logistics=overhaul_career_logistics_general
    if logistics and not logistics.canRemoveLogisticsVehicle(id) then return 'This vehicle is being used by an activity.' end
    if type(v.config)~='table' or type(v.partConditions)~='table' then return 'Vehicle state is incomplete. Store it and save your career.' end
    local insurance=overhaul_career_repair_insurance
    if insurance and insurance.inventoryVehNeedsRepair and insurance.inventoryVehNeedsRepair(id) then
      return 'Repair the vehicle before listing it.'
    end
  end
  local function snapshotVehicle(id)
    local pack={record=clone(inv().getVehicles()[id]),parts={}}
    -- The config tree is runtime data; the saved parts map is the portable format RLS restores.
    if pack.record.config.partsTree then
      pack.record.config.parts=core_vehicle_partmgmt.partsTreeToPartsMap(pack.record.config.partsTree)
      pack.record.config.partsTree=nil
    end
    for _,p in pairs(parts().getInventory()) do
      if tonumber(p.location)==id then local cp=clone(p); cp.description=nil; pack.parts[#pack.parts+1]=cp end
    end
    return pack
  end
  local function reserveCount(garage)
    local n=0
    for _,r in pairs(receipts) do
      if r.phase=='prepared' and r.kind=='car' and r.role=='to' and (not garage or tostring(r.garage)==tostring(garage)) then n=n+1 end
    end
    return n
  end
  local function installCapacityHooks()
    local gm=overhaul_career_garage_garageManager
    if not gm then return end
    for _,name in ipairs({'isGarageSpace'}) do
      if gm[name] and (not hooks[name] or gm[name]~=hooks[name].wrapper) then
        local original=gm[name]
        local wrapper=function(garage,...)
          local result=original(garage,...)
          if not active() then return result end
          local reserved=reserveCount(garage)
          if reserved==0 then return result end
          local inventoryId=select(1,...)
          local incoming=inventoryId and inv().getVehicles()[inventoryId]
          -- Returning to a confirmed home adds no occupancy. Native RLS also
          -- admits space-exempt cars, including garages already over capacity.
          local retains=incoming and (incoming.takesNoInventorySpace or
            (gm.vehicleUsesGarageCapacity and gm.vehicleUsesGarageCapacity(incoming,garage)
              and require('overhaul/career/garage/inventory/vehicleMap').resolve(incoming)==getCurrentLevelIdentifier()))
          local free=math.max(0,result[2]-reserved)
          return {result[1] and (retains or free>0) or false, free}
        end
        hooks[name]={owner=gm,original=original,wrapper=wrapper}; gm[name]=wrapper
      end
    end
  end
  local function acknowledge(id)
    local r=receipts[id]
    if not r or not durable[id] or durable[id]~=r.phase then return end
    if r.phase=='listed' then if r.vehicle then send({op='listed',id=id,vehicle=r.vehicle}) end
    elseif r.phase=='withdrawn' then send({op='listingWithdrawn',id=id})
    elseif r.phase=='sold' then return
    elseif r.phase=='prepared' then send({op='prepared',id=id,vehicle=r.vehicle})
    else send({op='done',id=id}) end
  end
  local function requestSave()
    if saves().saveCurrent(nil,{manual=true,force=true})==false then fail('Transaction save refused. Recovery remains pending.') end
  end
  local function importVehicle(pack, id, garage, tx)
    local record=clone(pack.record)
    record.id=id; record.owned=true; record.location=garage
    record.worldPosition=nil; record.lastKnownLevel=getCurrentLevelIdentifier()
    record.rlsmpTradeLock=nil; record.listedForAuction=nil; record.dirtyDate=nil
    record.defaultThumbnail=true; record.plateIssued=nil
    record.finalBuyingPrice=tx.cents/100
    inv().getVehicles()[id]=record
    for _,p in ipairs(pack.parts) do local cp=clone(p); cp.location=id; parts().addPartToInventory(cp) end
    parts().onOverhaulPartShoppingTransactionComplete()
    -- No onVehicleAdded broadcast: it would regenerate a second copy of the transferred parts.
    local insurance=overhaul_career_repair_insurance
    if insurance and insurance.onOverhaulVehicleAddedToInventory then insurance.onOverhaulVehicleAddedToInventory({inventoryId=id,purchaseData={insuranceId=-1}}) end
    inv().setVehicleDirty(id)
    return id
  end
  local function prepare(tx, role)
    if not available() then return nil,'Exchanges are unavailable in this career.' end
    local r={phase='prepared',role=role,kind=tx.kind,cents=tx.cents}
    local payer=(tx.kind=='money' and role=='from') or (tx.kind=='car' and role=='to')
    if payer then
      local balance=money().getAttributeValue('money')
      if type(balance)~='number' or balance~=balance or balance==math.huge or balance<tx.cents/100 then return nil,'Insufficient wallet balance.' end
      r.debit=tx.cents/100
    end
    if tx.kind=='car' and role=='from' then
      local problem=vehicleProblem(tx.vehicleId); if problem then return nil,problem end
      r.vehicle=snapshotVehicle(tx.vehicleId); r.vehicleId=tx.vehicleId
      if #jsonEncode(r.vehicle)>850000 then return nil,'This car is too large to transfer.' end
    elseif tx.kind=='car' then
      if not inv().hasFreeSlot() then return nil,'No free garage space.' end
      local garage=inv().getClosestOwnedGarageWithSpace()
      if not garage then return nil,'No garage available.' end
      r.garage=garage.id
    end
    -- Every validation precedes mutation. The receipt and effects enter the same RLS snapshot.
    receipts[tx.id]=r
    if r.vehicleId then inv().getVehicles()[r.vehicleId].rlsmpTradeLock=tx.id; inv().setVehicleDirty(r.vehicleId) end
    if r.debit then changeMoney(-r.debit,'Player exchange reservation') end
    return r
  end
  local function process(msg)
    local tx,role=msg.tx,msg.role
    if type(tx)~='table' or tx.serverId~=serverId or type(tx.id)~='string' or not tx.id:match('^%d+%-%d+$')
      or (role~='from' and role~='to') or type(tx[role])~='table' or tx[role].profile~=profile
      or (tx.kind~='money' and tx.kind~='car') or type(tx.cents)~='number' or tx.cents%1~=0 or tx.cents<1 or tx.cents>10000000000 then return end
    local expected=ctx.accountProfile()
    if tx[role].account~=expected:match('^beammp_(%d+)$') then return end
    local r=receipts[tx.id]
    if not r and tx.listingId and role=='from' and tx.state=='commit' then
      local escrow=receipts[tx.listingId]
      if escrow and escrow.phase=='listed' and durable[tx.listingId]=='listed' then
        r=clone(escrow);r.phase='prepared';r.listingId=tx.listingId;r.vehicle=nil
        receipts[tx.id]=r;durable[tx.id]='prepared'
      end
    end
    if r and r.phase~='prepared' then acknowledge(tx.id); return end
    if r and tx.state=='prepare' then acknowledge(tx.id); return end
    if pending then inbox[tx.id]=msg; return end
    if saves().isSavePending() then inbox[tx.id]=msg; return end
    if tx.state=='prepare' then
      local result,problem=prepare(tx,role)
      if not result then send({op='rejected',id=tx.id}); fail(problem); return end
    elseif tx.state=='abort' then
      if r then
        if r.vehicleId then
          local v=inv().getVehicles()[r.vehicleId]
          if v and v.rlsmpTradeLock==tx.id then v.rlsmpTradeLock=nil; inv().setVehicleDirty(r.vehicleId) end
        end
        if r.debit then changeMoney(r.debit,'Player exchange refund') end
      else r={role=role,kind=tx.kind,cents=tx.cents}; receipts[tx.id]=r end
      r.phase='aborted'; r.vehicle=nil
    elseif tx.state=='commit' then
      if not r or not durable[tx.id] then fail('Local receipt missing. Transaction suspended for review.'); return end
      if tx.kind=='money' and role=='to' then changeMoney(tx.cents/100,'Money transfer from '..tx.from.name)
      elseif tx.kind=='car' and role=='from' then
        local v=inv().getVehicles()[r.vehicleId]
        if not v or v.rlsmpTradeLock~=(r.listingId or tx.id) then fail('Reserved car not found. Transaction suspended.'); return end
        inv().removeVehicle(r.vehicleId)
        changeMoney(tx.cents/100,'Car sale to '..tx.to.name)
        if tx.listingId and receipts[tx.listingId] then
          receipts[tx.listingId].phase='sold';receipts[tx.listingId].vehicle=nil
        end
      elseif tx.kind=='car' and role=='to' then
        if type(tx.vehicle)~='table' or type(tx.vehicle.record)~='table' then fail('Transaction vehicle data is missing.'); return end
        local id=1; while inv().getVehicles()[id] do id=id+1 end
        r.importedId=importVehicle(tx.vehicle,id,r.garage,tx)
      end
      r.phase='committed'; r.vehicle=nil
    else return end
    pending=tx.id
    requestSave(); changed()
  end
  local function processListing(msg)
    local l=msg.listing
    if type(l)~='table' or l.serverId~=serverId or type(l.id)~='string' or not l.id:match('^%d+%-%d+$')
      or type(l.from)~='table' or l.from.profile~=profile or l.from.account~=ctx.accountProfile():match('^beammp_(%d+)$') then return end
    local r=receipts[l.id]
    if r and (r.phase=='withdrawn' or r.phase=='sold') then acknowledge(l.id);return end
    if l.state=='publishing' and r and r.phase=='listed' then acknowledge(l.id);return end
    if pending or saves().isSavePending() then inbox[l.id]=msg;return end
    if l.state=='publishing' then
      local problem=not available() and 'Marketplace unavailable in this career.' or vehicleProblem(l.vehicleId)
      if problem then send({op='listingRejected',id=l.id});fail(problem);return end
      local pack=snapshotVehicle(l.vehicleId)
      if #jsonEncode(pack)>850000 then send({op='listingRejected',id=l.id});fail('This car is too large to list.');return end
      receipts[l.id]={phase='listed',role='from',kind='car',cents=l.cents,vehicleId=l.vehicleId,vehicle=pack}
      inv().getVehicles()[l.vehicleId].rlsmpTradeLock=l.id;inv().setVehicleDirty(l.vehicleId)
    elseif l.state=='withdrawing' then
      if r and r.phase~='listed' then fail('Local listing receipt conflict.');return end
      if r then
        local v=inv().getVehicles()[r.vehicleId]
        if not v or v.rlsmpTradeLock~=l.id then fail('The listed car could not be found. Recovery is pending.');return end
        v.rlsmpTradeLock=nil;inv().setVehicleDirty(r.vehicleId)
      else r={kind='car',role='from'};receipts[l.id]=r end
      r.phase='withdrawn';r.vehicle=nil
    else return end
    pending=l.id;requestSave();changed()
  end
  local function received(raw)
    if not profile or not active() then return end
    local msg=wire.receive(0,raw); if not msg then return end
    if msg.op=='state' then
      view=msg
      for _,l in pairs(msg.myListings or {}) do
        local r=receipts[l.id]
        if r and r.phase=='listed' and (l.state=='active' or l.state=='reserved') then r.vehicle=nil end
      end
      changed()
    elseif msg.op=='error' then fail(tostring(msg.message or 'Exchange refused.'))
    elseif msg.op=='transaction' then process(msg)
    elseif msg.op=='listingCommand' then processListing(msg) end
  end
  function api.activate()
    if not ctx.active() then return end
    local selected,path=saves().getCurrentProfile()
    local key=tostring(ctx.serverId())..':'..tostring(selected)
    if rejectedContext==key then return end
    if profile==selected and serverId==ctx.serverId() then return end
    api.stop()
    profile,serverId=selected,ctx.serverId()
    local data=path and jsonReadFile(path..RECEIPTS)
    if data~=nil and type(data)~='table' then
      fail('The local exchange journal is unreadable.'); rejectedContext=key; profile=nil; return
    end
    if data and (data.profile~=profile or data.serverId~=serverId or type(data.receipts)~='table') then
      local finished=type(data.receipts)=='table'
      if type(data.receipts)=='table' then
        for _,r in pairs(data.receipts) do
          if type(r)~='table' or (r.phase~='committed' and r.phase~='aborted' and r.phase~='sold' and r.phase~='withdrawn') then finished=false end
        end
      end
      if not finished then
        fail('An exchange is pending in the original career. Load that career to finish it.')
        rejectedContext=key; profile=nil; return
      end
      -- A completed receipt from a copied/imported career belongs to its original profile.
      data=nil
    end
    receipts=data and data.receipts or {}; durable={}
    for id,r in pairs(receipts) do
      if type(id)~='string' or not id:match('^%d+%-%d+$') or type(r)~='table'
        or (r.phase~='prepared' and r.phase~='committed' and r.phase~='aborted' and r.phase~='listed' and r.phase~='sold' and r.phase~='withdrawn') then
        fail('Invalid local receipt.'); rejectedContext=key; profile=nil; return
      end
      durable[id]=r.phase
    end
    elapsed=10; installCapacityHooks()
  end
  function api.update(dt)
    wire.tick(dt)
    if not profile then return end
    if not active() then api.pause(); return end
    if AddEventHandler and registered~=AddEventHandler then
      AddEventHandler('rlsmpTeamx_Trade',received,'rlsmpTeamxTrade'); registered=AddEventHandler; elapsed=10
    end
    elapsed=elapsed+dt
    if elapsed>=10 then elapsed=0; announced=true; send({op='ready',profile=profile,market=1}) end
    if not pending and not saves().isSavePending() then
      local id,msg=next(inbox)
      if id then inbox[id]=nil;if msg.op=='listingCommand' then processListing(msg) else process(msg) end end
    end
  end
  function api.save(path)
    -- The bridge marks itself as leaving BEFORE RLS's final save. Receipts must still join it.
    if not profile or not saves() or saves().getCurrentProfile()~=profile then return end
    captured={}
    for id,r in pairs(receipts) do captured[id]=r.phase end
    -- RLS queues this write within its transactional snapshot before validating info.json.
    saves().jsonWriteFileSafe(path..RECEIPTS,{serverId=serverId,profile=profile,receipts=clone(receipts)},true)
  end
  function api.saved()
    if not captured then return end
    durable=captured; captured=nil
    local id=pending; pending=nil
    if id then acknowledge(id); changed() end
  end
  function api.saveFailed()
    captured=nil
    if pending then fail('Transaction save failed. Retry saving before leaving.') end
  end
  function api.status()
    local data=clone(view); data.active=active(); data.profile=profile; data.wallet=money() and money().getAttributeValue('money') or 0
    data.vehicles={}; data.saving=pending~=nil
    if active() then
      for id,v in pairs(inv().getVehicles()) do
        if type(id)=='number' and not vehicleProblem(id) then data.vehicles[#data.vehicles+1]={id=id,name=v.niceName or v.model,model=v.model} end
      end
    end
    return data
  end
  function api.action(op,target,amount,vehicleId,id)
    if not available() then return {error='Load an RLS career without unlimited money.'} end
    if op=='refresh' then send({op='refresh'}); return {ok=true} end
    if pending then return {error='A transaction is waiting for its save.'} end
    if op=='accept' or op=='cancel' or op=='buy' or op=='withdraw' then send({op=op,id=id}); return {ok=true} end
    if op~='money' and op~='car' and op~='publish' then return {error='Unknown action.'} end
    if type(amount)~='number' or amount~=amount or amount<=0 or amount>100000000 or math.abs(amount*100-math.floor(amount*100+0.5))>0.00001 then return {error='Enter a positive amount with no more than two decimal places.'} end
    local title
    if op=='car' or op=='publish' then local problem=vehicleProblem(vehicleId); if problem then return {error=problem} end; title=inv().getVehicles()[vehicleId].niceName end
    if op=='money' and money().getAttributeValue('money')<amount then return {error='Insufficient wallet balance.'} end
    send({op=op=='publish' and 'publish' or 'offer',kind=op,target=target,cents=math.floor(amount*100+0.5),vehicleId=vehicleId,title=title})
    return {ok=true}
  end
  function api.stop()
    api.pause()
    if registered and registered==AddEventHandler and RemoveEventHandler then RemoveEventHandler('rlsmpTeamx_Trade','rlsmpTeamxTrade') end
    for name,h in pairs(hooks) do if h.owner[name]==h.wrapper then h.owner[name]=h.original end end
    receipts,durable,captured,pending,inbox,hooks={},{},nil,nil,{},{}
    profile,serverId,registered=nil,nil,nil
    rejectedContext,announced=nil,nil
    view={enabled=false,players={},incoming={},outgoing={},pending={}}
    wire.forget(0)
  end
  function api.pause()
    if announced then send({op='away'}); announced=false; elapsed=10 end
  end
  return api
end
return M
