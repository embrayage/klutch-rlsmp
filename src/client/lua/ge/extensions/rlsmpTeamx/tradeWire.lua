-- Bounded application messages; large vehicle/part snapshots travel in small events.
local M = {}
function M.new(encode, decode, send)
  local incoming, sequence = {}, 0
  local wire = {}
  function wire.send(peer, message)
    local raw = encode(message)
    if type(raw) ~= 'string' or #raw > 1048576 then return false end
    sequence = sequence + 1
    local id = tostring(sequence)
    local total = math.max(1, math.ceil(#raw / 6000))
    for part = 1, total do
      send(peer, encode({id=id, part=part, total=total, data=raw:sub((part-1)*6000+1, part*6000)}))
    end
    return true
  end
  function wire.receive(peer, raw)
    if type(raw) ~= 'string' or #raw > 37000 then return end
    local ok, value = pcall(decode, raw)
    if not ok or type(value) ~= 'table' or type(value.id) ~= 'string' or not value.id:match('^%d+$') or #value.id > 20
      or type(value.total) ~= 'number' or value.total % 1 ~= 0 or value.total < 1 or value.total > 175
      or type(value.part) ~= 'number' or value.part % 1 ~= 0 or value.part < 1 or value.part > value.total
      or type(value.data) ~= 'string' or #value.data > 6000 then return end
    incoming[peer] = incoming[peer] or {}
    local messages = incoming[peer]
    local item = messages[value.id]
    if not item then
      local count = 0; for _ in pairs(messages) do count = count + 1 end
      if count >= 4 then return end
      item = {total=value.total, parts={}, count=0, age=0, bytes=0}; messages[value.id] = item
    end
    if item.total ~= value.total then messages[value.id] = nil; return end
    if not item.parts[value.part] then
      item.parts[value.part] = value.data; item.count = item.count + 1; item.bytes = item.bytes + #value.data
    end
    if item.bytes > 1048576 then messages[value.id] = nil; return end
    if item.count ~= item.total then return end
    messages[value.id] = nil
    local decoded, message = pcall(decode, table.concat(item.parts))
    if decoded and type(message) == 'table' then return message end
  end
  function wire.tick(dt)
    for peer, messages in pairs(incoming) do
      for id, item in pairs(messages) do item.age = item.age + dt; if item.age > 30 then messages[id] = nil end end
      if not next(messages) then incoming[peer] = nil end
    end
  end
  function wire.forget(peer) incoming[peer] = nil end
  return wire
end
return M
