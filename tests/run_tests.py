"""Run Lua syntax and behavior checks using the server's existing Lua 5.3 DLL."""
from pathlib import Path
import ctypes as C
import os
import json
import re
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / 'build/build-manifest.json').read_text())
reference = json.loads((ROOT / 'reference/rls/.source.json').read_text())
assert reference['sha256'] == manifest['sourceSha256'], 'Native fixtures must match the built RLS source'
if not os.environ.get('BEAMNG_DIR') or not os.environ.get('BEAMMP_LUA_DLL'):
    raise SystemExit('Set BEAMNG_DIR and BEAMMP_LUA_DLL first; see docs/DEVELOPMENT.md')
GAME = Path(os.environ['BEAMNG_DIR']).resolve()
DLL = Path(os.environ['BEAMMP_LUA_DLL']).resolve()
lua = C.CDLL(str(DLL))
lua.luaL_newstate.restype = C.c_void_p
lua.luaL_openlibs.argtypes = [C.c_void_p]
lua.luaL_loadbufferx.argtypes = [C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_char_p]
lua.luaL_loadbufferx.restype = C.c_int
lua.lua_pcallk.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ssize_t, C.c_void_p]
lua.lua_pcallk.restype = C.c_int
lua.lua_tolstring.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_size_t)]
lua.lua_tolstring.restype = C.c_char_p
lua.lua_close.argtypes = [C.c_void_p]


def run(source, name, execute=True):
    state = lua.luaL_newstate()
    try:
        lua.luaL_openlibs(state)
        data = source.encode('utf-8')
        result = lua.luaL_loadbufferx(state, data, len(data), name.encode(), None)
        if result == 0 and execute:
            result = lua.lua_pcallk(state, 0, 0, 0, 0, None)
        if result:
            raise AssertionError(f'{name}: {lua.lua_tolstring(state, -1, None).decode("utf-8", "replace")}')
    finally:
        lua.lua_close(state)


def literal(path):
    return '"' + str(path).replace('\\', '/').replace('"', '\\"') + '"'


runpy.run_path(str(ROOT / 'tests/check_rls_api.py'))['check'](ROOT)
runpy.run_path(str(ROOT / 'tests/check_game_api.py'))['check'](ROOT)
syntax_files = sorted((ROOT / 'src').rglob('*.lua')) + sorted((ROOT / 'build/patched-lua').rglob('*.lua'))
assert len(syntax_files) == 25, len(syntax_files)
for file in syntax_files:
    run(file.read_text(encoding='utf-8-sig'), str(file.relative_to(ROOT)), execute=False)
print(f'PASS: Lua syntax ({len(syntax_files)} files)')

game_lua = GAME / 'lua'
run(f'package.path = {literal(ROOT / "src/client/lua/ge/extensions/?.lua")} .. ";" .. package.path\n' +
    f'GAME_LUA = {literal(game_lua)}\n' +
    (ROOT / 'tests/audio_recovery.lua').read_text(encoding='utf-8'), 'global audio after career load')

native_locks = (ROOT / 'tests/trade_native.lua').read_text(encoding='utf-8')
inventory_base = ROOT / 'build/patched-lua/lua/ge/extensions/overhaul/career/garage/inventory'
for marker, file, name in (
    ('ACTUAL_IS_LISTED', 'persistence.lua', 'isVehicleListedForAuction'),
    ('ACTUAL_SET_LISTED', 'persistence.lua', 'setVehicleListedForAuction'),
    ('ACTUAL_SELL', 'operations.lua', 'sellVehicle'),
    ('ACTUAL_RECOVERABLE', 'operations.lua', 'isRecoverablePersonalVehicle'),
    ('ACTUAL_PERMISSIONS', 'operations.lua', 'onOverhaulCheckPermission'),
    ('ACTUAL_VALIDATE_SPAWN', 'spawn.lua', 'validateSpawnRecord'),
):
    source = (inventory_base / file).read_text(encoding='utf-8')
    native_locks = native_locks.replace('-- ' + marker,
        re.search(r'  local function ' + name + r'\(.*?\n  end', source, re.S).group())
source = (inventory_base / 'operations.lua').read_text(encoding='utf-8')
native_locks = native_locks.replace('-- ACTUAL_LOCKED_TAGS',
    re.search(r'  local AUCTION_LOCKED_TAGS = \{.*?\n  \}', source, re.S).group().replace('local AUCTION_LOCKED_TAGS', 'AUCTION_LOCKED_TAGS'))
consignment = (inventory_base.parents[1] / 'market/auction/consignment.lua').read_text(encoding='utf-8')
native_locks = native_locks.replace('-- ACTUAL_CONSIGNMENT',
    re.search(r'function M.saleBlockReason\(.*?\nend', consignment, re.S).group())
run(native_locks, 'actual RLS vehicle trade locks')
run('BETA_BASE = ' + literal(inventory_base.parents[1]) + '\n' +
    (ROOT / 'tests/beta_auction.lua').read_text(), 'BETA asynchronous auction escrow')

run('''
local replies, events = {}, {}
local now = 100
os.time = function() return now end
local config = {serverId = string.rep('a',32), level = 'rls_west_coast'}
local payloads = {CONFIG=config, HELLO={protocol=1, profile='beammp_victim'}, WRONG={protocol=99}}
local originalOpen = io.open
io.open = function(path, mode)
  assert(path == 'Resources/Server/rlsmpTeamx/config.json' and mode == 'rb')
  return {read=function() return 'CONFIG' end, close=function() end}
end
Util = {JsonDecode=function(raw) return payloads[raw] end}
local accounts = {[1]='12345', [2]='67890', [3]='12345', [4]='', [5]='0', [6]='../victim'}
MP = {
  RegisterEvent=function(name, handler) events[name]=handler end,
  TriggerClientEventJson=function(id, name, data) replies[#replies+1]={id=id, name=name, data=data} end,
  IsPlayerConnected=function(id) return accounts[id] ~= nil end,
  IsPlayerGuest=function(id) return id == 3 end,
  GetPlayerIdentifiers=function(id) return {beammp=accounts[id]} end,
}
''' + f'dofile({literal(ROOT / "src/server/main.lua")})\n' + '''
_G[events.onInit]()
rlsmpTeamx_Hello(1, 'HELLO')
rlsmpTeamx_Hello(2, 'HELLO')
assert(replies[1].data.profile == 'beammp_12345')
assert(replies[2].data.profile == 'beammp_67890')
assert(replies[1].data.serverId == replies[2].data.serverId)
assert(replies[1].data.level == 'rls_west_coast')
assert(replies[1].data.version == '0.8.0-alpha')
assert(replies[1].id == 1 and replies[2].id == 2)
rlsmpTeamx_Hello(3, 'HELLO')
assert(replies[3].data.error and not replies[3].data.profile)
for _, id in ipairs({4,5,6}) do
  rlsmpTeamx_Hello(id, 'HELLO')
  assert(replies[#replies].data.error and not replies[#replies].data.profile)
end
local count = #replies
rlsmpTeamx_Hello(1, 'HELLO')
rlsmpTeamx_Hello(99, 'HELLO')
rlsmpTeamx_Hello('1', 'HELLO')
assert(#replies == count)
now = now + 3
rlsmpTeamx_Hello(1, 'WRONG')
assert(#replies == count)
rlsmpTeamx_Disconnect(1)
rlsmpTeamx_Hello(1, 'HELLO')
assert(replies[#replies].data.profile == 'beammp_12345')
io.open = originalOpen
''', 'server identity and validation')
print('PASS: server account isolation, reconnect, guest handling, spoofed identity and invalid payload rejection')

client_path = ROOT / 'src/client/lua/ge/extensions'
run(f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' +
    f'RLS_BASE = {literal(ROOT / "reference/rls/lua/ge/extensions/overhaul")}\n' +
    (ROOT / 'tests/release_capacity.lua').read_text(), 'release garage capacity and pending purchases')
run(f'package.path = {literal(client_path / "?.lua")} .. ";" .. {literal(game_lua / "common/?.lua")} .. ";" .. package.path\n' +
    f'SERVER_TRADE_PATH = {literal(ROOT / "src/server/trade.lua")}\n' +
    f'CLIENT_TRADE_PATH = {literal(client_path / "rlsmpTeamx/trades.lua")}\n' +
    (ROOT / 'tests/trades.lua').read_text(encoding='utf-8').replace('-- MARKETPLACE_CASES',
        (ROOT / 'tests/marketplace.lua').read_text(encoding='utf-8')), 'two-client durable player exchanges')
run(f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' +
    (ROOT / 'tests/native_client.lua').read_text(encoding='utf-8'), 'native RLS client lifecycle')
print('PASS: native RLS picker, existing career, new profiles and options, account isolation, solo cards/import, hook cleanup and map readiness')
run(f'ACTUAL_JOB_SYSTEM_PATH = {literal(game_lua / "ge/extensions/core/jobsystem.lua")}\n' +
    f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' +
    (ROOT / 'tests/traffic.lua').read_text(encoding='utf-8'), 'three synchronized AI per player')
print('PASS: 3 AI per player, isolation, cancellation, refill, real game scheduler, delayed physics registration and genuine timeout cleanup')

# Exercise real engine/BeamMP replacement code, including walking and remote focus.
replacement = (ROOT / 'tests/vehicle_replacement.lua').read_text(encoding='utf-8')
engine = (game_lua / 'ge/extensions/core/vehicles.lua').read_text(encoding='utf-8-sig')
beammp = (ROOT / 'reference/beammp/lua/ge/extensions/MPVehicleGE.lua').read_text(encoding='utf-8-sig')
for marker, source, pattern in (
    ('ENGINE_PRIVATE_REPLACE', engine, r'local function _replaceVehicle\(.*?\nend'),
    ('ENGINE_PUBLIC_REPLACE', engine, r'local function replaceVehicle\(.*?\nend'),
    ('BEAMMP_SPAWN_HANDLER', beammp, r'local function onVehicleSpawned\(.*?\nend'),
    ('BEAMMP_REPLACE_REQUEST', beammp, r'local function replaceRequest\(.*?\nend'),
    ('BEAMMP_POST_JOIN', beammp, r'M.onBeamMPPostJoin = function\(.*?\nend'),
):
    replacement = replacement.replace('-- ' + marker, re.search(pattern, source, re.S).group())
run(f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' + replacement,
    'actual engine and BeamMP explicit vehicle replacement')
print('PASS: actual engine and BeamMP handlers reproduce wrong-target replacement; bridge preserves vehicle/network identity across repeated parts edits, walking, remote focus and free camera; foreign/traffic/stale targets refused')

garage_member = 'lua/ge/extensions/overhaul/career/garage/inventory/setup.lua'
run(f'ORIGINAL_SETUP_PATH = {literal(ROOT / "reference/rls" / garage_member)}\n' +
    f'PATCHED_SETUP_PATH = {literal(ROOT / "build/patched-lua" / garage_member)}\n' +
    f'VEHICLE_MAP_PATH = {literal(ROOT / "reference/rls/lua/ge/extensions/overhaul/career/garage/inventory/vehicleMap.lua")}\n' +
    f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' +
    (ROOT / 'tests/garage_restore.lua').read_text(encoding='utf-8'), 'actual RLS stored vehicle restoration')
print('PASS: actual RLS loader reproduces stale parking resurrection; MP restores saved live fleet, keeps stored cars and empty garages unspawned, preserves multiple live vehicles, legacy arrays/profiles and solo behavior')

startup = (ROOT / 'tests/startup_races.lua').read_text(encoding='utf-8')
mp_core = (ROOT / 'reference/beammp/lua/ge/extensions/MPCoreNetwork.lua').read_text(encoding='utf-8-sig')
world_ready = re.search(r'local function onWorldReadyState\(.*?\nend', mp_core, re.S).group()
startup = startup.replace('-- ACTUAL_BEAMMP_WORLD_READY',
    'do\nlocal isMpSession, isGoingMpSession = true, false\n' + world_ready + '\nbeammpReady=onWorldReadyState\nend')
run(f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' + startup,
    'startup loading and route races')
print('PASS: real BeamMP final route overwrite in both hook orders, UI recovery, explicit closing, temporary initialization errors, late RLS modules, transport wait, lost event registry, late configuration and bounded failures')

guard_test = (ROOT / 'tests/network_guard.lua').read_text(encoding='utf-8')
beammp_vehicle = (ROOT / 'reference/beammp/lua/vehicle/extensions/BeamMP/positionVE.lua').read_text(encoding='utf-8-sig')
for marker, name in [('ACTUAL_SET_GAME_SPEED','setGameSpeed'), ('ACTUAL_UPDATE_REMOTE_DATA','updateRemoteData')]:
    guard_test = guard_test.replace('-- ' + marker,
        re.search(r'local function ' + name + r'\(.*?\nend', beammp_vehicle, re.S).group())
run(f'VEHICLE_GUARD_PATH = {literal(ROOT / "src/client/lua/vehicle/extensions/rlsmpNetworkGuard.lua")}\n' +
    f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' + guard_test,
    'non-finite BeamMP position protection')
print('PASS: real BeamMP zero-speed decoder reproduces infinity and fatal Lua expression; guards cover pause/resume, invalid packets and transforms, NaN, zero dt, invalid physics/orientation, cache invalidation and cleanup')

save_source = (ROOT / 'build/patched-lua/lua/ge/extensions/overhaul/career/saveSystem.lua').read_text()
management = (ROOT / 'tests/profile_management.lua').read_text(encoding='utf-8')
functions = '\n'.join(re.search(r'local function ' + name + r'\(.*?\nend', save_source, re.S).group()
                      for name in ('updateProfileDisplayName', 'getAllProfiles', 'renameProfile',
                                   'duplicateSaveSlot', 'removeProfile', 'removeSaveFolder'))
run(management.replace('-- ACTUAL_FUNCTIONS', functions), 'native profile management')
print('PASS: actual native profile listing, rename, backup and deletion preserve account ownership and visible names')
setter = re.search(r'M.setRlsmpNamespace = function\(serverId\).*?\nend', save_source, re.S).group()
run('''
local currentProfile, rlsmpNamespace
local singlePlayerSaveRoot='offline/'
local saveRoot=singlePlayerSaveRoot
local saving=false
local M={isSavePending=function() return saving end}
''' + setter + '''
assert(not M.setRlsmpNamespace('../escape'))
assert(saveRoot=='offline/')
local id=string.rep('a',32)
assert(M.setRlsmpNamespace(id))
assert(saveRoot=='settings/rlsmpTeamx/saves/'..id..'/')
currentProfile='beammp_12345'
assert(not M.setRlsmpNamespace(nil))
currentProfile=nil; saving=true
assert(not M.setRlsmpNamespace(nil))
saving=false
assert(M.setRlsmpNamespace(nil) and saveRoot=='offline/')
''', 'save namespace gates')
print('PASS: actual patched namespace setter refuses traversal and root changes during pending saves')
run(f'package.path = {literal(client_path / "?.lua")} .. ";" .. package.path\n' +
    (ROOT / 'tests/solo_import.lua').read_text(encoding='utf-8'), 'solo import filesystem behavior')
print('PASS: solo discovery, version/map checks, source preservation, thumbnails, metadata commit, existing saves, I/O failures and disconnect cancellation')

profile_setter = re.search(r'local function setProfile\(profile, specificSaveFolder\).*?\nend', save_source, re.S).group()
run('''
local multiplayer=true
local selected
local M={isSavePending=function() return false end}
local currentDisplayName,creationDateOfCurrentProfile
local pathComponent=dofile(''' + literal(ROOT / 'reference/rls/lua/ge/extensions/overhaul/lib/save/pathComponent.lua') + ''')
local isLegalDirectoryName=pathComponent.valid
local saveRoot='root/'
local folders={}
FS={directoryList=function() return folders end}
path={split=function(p) return p:match('^(.*)/([^/]+)$') end}
require=function(name) if name=='overhaul/lib/save/pathComponent' then return pathComponent end return {
  allowProfile=function(name) return not multiplayer or name=='beammp_12345' end,
  isMultiplayer=function() return multiplayer end,
} end
local function newerSchemaRefusal() return nil end
local function beginProfileSwitch() end
local function resolveSavePath(name) return 'root/'..name end
local function getSanitizedProfileName(name) return name:gsub('[^a-z0-9]','') end
local function activateProfile(name) selected=name; return true end
jsonReadFile=function() return nil end
overhaul_career_saveMigration={getLegacySavePreflight=function() return {requiresMigration=false} end}
''' + profile_setter + '''
assert(setProfile('beammp_12345') and selected=='beammp_12345')
assert(not setProfile('beammp_67890') and selected=='beammp_12345')
multiplayer=false
assert(setProfile('offline_name') and selected=='offlinename')
folders={'root/offline_name'}
assert(setProfile('offline_name') and selected=='offline_name')
assert(not setProfile('../escape','autosave1'))
assert(not setProfile('offline_name','../escape'))
''', 'stable server profile name')
print('PASS: actual setProfile preserves the permanent MP profile name and retains solo name normalization')
subprocess.run(['node', str(ROOT / 'tests/check_native_ui.cjs')], check=True)
subprocess.run(['node', str(ROOT / 'tests/check_profile_route.cjs')], check=True)
subprocess.run(['node', str(ROOT / 'tests/check_trade_ui.cjs')], check=True)
print('All automated checks passed. Two-player in-game validation is still required.')
