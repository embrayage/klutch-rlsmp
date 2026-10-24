-- RLSMP TeamX: server identity and transaction coordinator. Careers remain local.
local ROOT = 'Resources/Server/rlsmpTeamx/'
local PROTOCOL = 1
local VERSION = '0.8.1-alpha'
local config
local helloAt = {}
local exchange

local function reply(playerId, data)
  data.protocol = PROTOCOL
  MP.TriggerClientEventJson(playerId, 'rlsmpTeamx_Config', data)
end

local function loadConfig()
  local file = io.open(ROOT .. 'config.json', 'rb')
  if not file then print('[RLSMP] Missing config.json; career activation disabled.'); return end
  local raw = file:read('*a'); file:close()
  local ok, value = pcall(Util.JsonDecode, raw)
  if not ok or type(value) ~= 'table' or type(value.serverId) ~= 'string'
    or #value.serverId ~= 32 or not value.serverId:match('^%x+$')
    or (value.level ~= 'west_coast_usa' and value.level ~= 'rls_west_coast') then
    print('[RLSMP] Invalid config.json; career activation disabled.')
    return
  end
  config = value
  config.version = VERSION
  print('[RLSMP] ' .. config.version .. ' ready; local careers, native RLS profiles, 3 AI per active player.')
end

function rlsmpTeamx_Hello(playerId, raw)
  if not config or type(playerId) ~= 'number' or not MP.IsPlayerConnected(playerId) then return end
  if type(raw) ~= 'string' or #raw > 1024 then return end
  local now = os.time()
  if helloAt[playerId] and now - helloAt[playerId] < 2 then return end
  helloAt[playerId] = now
  local ok, hello = pcall(Util.JsonDecode, raw)
  if not ok or type(hello) ~= 'table' or hello.protocol ~= PROTOCOL then return end
  if MP.IsPlayerGuest(playerId) then
    reply(playerId, {error = 'Sign in to a BeamMP account to use a persistent career.'})
    return
  end
  local identifiers = MP.GetPlayerIdentifiers(playerId) or {}
  local account = tostring(identifiers.beammp or '')
  if not account:match('^%d+$') or #account > 20 or account:match('^0+$') then
    reply(playerId, {error = 'Permanent BeamMP account ID unavailable. Please reconnect.'})
    return
  end
  -- Never accept an account or a save name supplied by the client.
  reply(playerId, {serverId = config.serverId, profile = 'beammp_' .. account,
    level = config.level, version = config.version, storage = 'local'})
end

function rlsmpTeamx_Disconnect(playerId)
  helloAt[playerId] = nil
  if exchange then exchange.disconnect(playerId) end
end
function rlsmpTeamx_Trade(playerId, raw) if exchange then exchange.receive(playerId,raw) end end
function rlsmpTeamx_TradeTick() if exchange then exchange.tick() end end
MP.RegisterEvent('onInit', 'rlsmpTeamx_Init')
MP.RegisterEvent('rlsmpTeamx_Hello', 'rlsmpTeamx_Hello')
MP.RegisterEvent('onPlayerDisconnect', 'rlsmpTeamx_Disconnect')
MP.RegisterEvent('rlsmpTeamx_Trade', 'rlsmpTeamx_Trade')
MP.RegisterEvent('rlsmpTeamx_TradeTick', 'rlsmpTeamx_TradeTick')
function rlsmpTeamx_Init()
  loadConfig()
  if not config or exchange or not MP.CreateEventTimer then return end
  exchange=dofile(ROOT..'trade.lua').new({mp=MP,root=ROOT,serverId=config.serverId,encode=Util.JsonEncode,decode=Util.JsonDecode,wire=dofile(ROOT..'tradeWire.lua')})
  exchange.init()
  if MP.CancelEventTimer then MP.CancelEventTimer('rlsmpTeamx_TradeTick') end
  MP.CreateEventTimer('rlsmpTeamx_TradeTick',5000)
end
