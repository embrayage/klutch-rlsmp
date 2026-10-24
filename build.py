"""Build a version-checked RLSMP prototype without touching original archives."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import uuid
import zipfile

ROOT = Path(__file__).resolve().parent
POLICY = 'require("rlsmpTeamx/policy")'
PATCHES = {}
PATCH_TARGETS = {
    'scripts/rls_career_overhaul/modScript.lua',
    *('lua/ge/extensions/overhaul/' + suffix for suffix in (
        'shell/extensionManager.lua', 'career/start/transitions.lua', 'career/start/startingModes.lua',
        'career/career.lua', 'career/saveSystem.lua', 'career/garage/inventory/bindings.lua',
        'career/police/playerDriving.lua', 'career/garage/inventory/setup.lua',
        'career/garage/inventory/persistence.lua', 'career/garage/inventory/operations.lua',
        'career/garage/inventory/spawn.lua', 'career/market/auction/consignment.lua')),
    *('ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/' + suffix for suffix in (
        'profiles/views/ProfileSelect.vue',
        'profiles/components/start/useStartMaps.js', 'utils/installLuaBridgeFallbacks.js',
        'utils/runtimeComponent.js')),
}


def edit(name, source, old, new):
    count = source.count(old)
    if count != 1:
        raise ValueError(f'{name}: expected one patch anchor, found {count}: {old[:90]!r}')
    return source.replace(old, new, 1)


def patched(name, raw):
    if name not in PATCH_TARGETS:
        return raw
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    original = text
    def change(old, new):
        nonlocal text
        text = edit(name, text, old, new)

    if name == 'scripts/rls_career_overhaul/modScript.lua':
        text = ('-- RLSMP TeamX 0.8.1-alpha\n'
                'setExtensionUnloadMode("rlsmpTeamx", "manual")\n'
                'extensions.load("rlsmpTeamx")\n\n') + text
    elif name.endswith('/shell/extensionManager.lua'):
        change('  if not isBeamMPActive() then return false end',
               f'  if {POLICY}.isAuthorized() then return false end\n'
               '  if not isBeamMPActive() then return false end')
        change('local function applyOverrideAI(vehId)\n',
               f'local function applyOverrideAI(vehId)\n  if not {POLICY}.canManageVehicle(vehId) then return end\n')
        change('local function applyCareerVehicleExtensions(veh)\n',
               f'local function applyCareerVehicleExtensions(veh)\n  if veh and not {POLICY}.canManageVehicle(veh:getID()) then return end\n')
        change('local function onVehicleSpawned(vehId, veh)\n',
               f'local function onVehicleSpawned(vehId, veh)\n  if not {POLICY}.canManageVehicle(vehId) then return end\n')
    elif name.endswith('/career/start/transitions.lua'):
        change('  local function activateCareer(removeVehicles, levelToLoad)\n',
               '  local function activateCareer(removeVehicles, levelToLoad)\n'
               f'    if {POLICY}.isMultiplayer() then\n'
               f'      if not {POLICY}.isAuthorized() then return false end\n'
               '      levelToLoad = getCurrentLevelIdentifier()\n    end\n')
        change('      if removeVehicles then\n        core_vehicles.removeAll()\n',
               f'      if {POLICY}.isMultiplayer() then\n'
               f'        {POLICY}.removeLocalVehicles()\n'
               '      elseif removeVehicles then\n        core_vehicles.removeAll()\n')
        change('  local function travelRefusal(nextLevel)\n',
               '  local function travelRefusal(nextLevel)\n'
               f'    if {POLICY}.isMultiplayer() then return "Map travel is controlled by the BeamMP server" end\n')
    elif name.endswith('/career/start/startingModes.lua'):
        change('  local requestedArgs = {name, specificAutosave, tutorial, hardcore, challengeId, cheats, startingMap, difficultyMode,',
               f'  if not {POLICY}.allowProfile(name) then return false end\n'
               '  local requestedArgs = {name, specificAutosave, tutorial, hardcore, challengeId, cheats, startingMap, difficultyMode,')
        change('  -- Freeroam+ is defined as cheats-enabled career;',
               f'  if {POLICY}.isMultiplayer() then\n'
               '    request.startingMap = getCurrentLevelIdentifier()\n'
               '  end\n\n  -- Freeroam+ is defined as cheats-enabled career;')
        change('    if not startingMap then return end\n',
               '    if not startingMap then return end\n'
               f'    if {POLICY}.isMultiplayer() and startingMap ~= getCurrentLevelIdentifier() then\n'
               '      abortCareerStart(career)\n'
               '      guihooks.trigger("toastrMsg", {type="error", title="RLSMP", msg="This career start requires a different map from the server."})\n'
               '      guihooks.trigger("RLSMPProfileError", {error="This career start requires a different map from the server."})\n'
               '      return\n    end\n')
    elif name.endswith('/career/career.lua'):
        change('local function removeNonTrafficVehicles()\n',
               f'local function removeNonTrafficVehicles()\n  if {POLICY}.isMultiplayer() then return {POLICY}.removeLocalVehicles() end\n')
        change('local function deactivateCareerAndReloadLevel(saveCareer)\n',
               'local function deactivateCareerAndReloadLevel(saveCareer)\n'
               f'  if {POLICY}.isMultiplayer() then return M.deactivateCareer(saveCareer) end\n')
    elif name.endswith('/career/saveSystem.lua'):
        change("local saveRoot = 'settings/cloud/overhaul/saves/'",
               "local singlePlayerSaveRoot = 'settings/cloud/overhaul/saves/'\n"
               'local saveRoot = singlePlayerSaveRoot\nlocal rlsmpNamespace')
        change('local function setProfile(profile, specificSaveFolder)\n',
               f'local function setProfile(profile, specificSaveFolder)\n  if not {POLICY}.allowProfile(profile) then return false end\n')
        change('  local sanitizedProfile = exactFolder and profile or getSanitizedProfileName(profile)\n',
               f'  local sanitizedProfile = ({POLICY}.isMultiplayer() or exactFolder) and profile or getSanitizedProfileName(profile)\n')
        change('M.getSaveRootDirectory = function() return saveRoot end',
               '''M.getSaveRootDirectory = function() return saveRoot end
-- Change roots only after the previous profile and its asynchronous writes are gone.
M.setRlsmpNamespace = function(serverId)
  if currentProfile ~= nil or M.isSavePending() then return false end
  if serverId ~= nil and (type(serverId) ~= "string" or #serverId ~= 32 or not serverId:match("^%x+$")) then return false end
  rlsmpNamespace = serverId
  saveRoot = serverId and ("settings/rlsmpTeamx/saves/" .. serverId .. "/") or singlePlayerSaveRoot
  return true
end
M.setRlsmpDisplayName = function(profile, displayName)
  if currentProfile ~= profile or type(displayName) ~= "string" or #displayName > 100 then return false end
  currentDisplayName = displayName
  return true
end''')
        block = re.search(r'local function getAllProfiles\(\).*?\nend', text, re.S).group()
        change(block, block.replace('    table.insert(res, filename)',
                                   f'    if {POLICY}.allowProfile(filename) then table.insert(res, filename) end'))
        for signature, profile_arg in [('removeProfile(profile)', 'profile'),
                                       ('removeSaveFolder(profile, saveFolderName)', 'profile'),
                                       ('updateProfileDisplayName(profile, displayName)', 'profile')]:
            change(f'local function {signature}\n',
                   f'local function {signature}\n  if not {POLICY}.allowProfile({profile_arg}) then return false end\n')
        for signature, profile_arg in [('renameProfile(profile, newName)', 'profile'),
                                       ('duplicateSaveSlot(slotName, newName, options)', 'slotName')]:
            change(f'local function {signature}\n',
                   f'local function {signature}\n  local rlsmpDisplayName\n'
                   f'  if {POLICY}.isMultiplayer() then\n'
                   f'    if not {POLICY}.allowProfile({profile_arg}) then return false end\n'
                   '    rlsmpDisplayName = newName\n'
                   '    newName = rlsmpTeamx.allocateProfileName(newName)\n'
                   '    if not newName then return false end\n  end\n')
        change('  return updateProfileDisplayName(newName, newName)',
               '  return updateProfileDisplayName(newName, rlsmpDisplayName or newName)')
        change('  if not updateProfileDisplayName(newName, newName) then',
               '  if not updateProfileDisplayName(newName, rlsmpDisplayName or newName) then')
        change('  data.currentProfile = currentProfile\n',
               '  data.currentProfile = currentProfile\n  data.rlsmpNamespace = rlsmpNamespace\n')
        change('local function onDeserialized(v)\n',
               'local function onDeserialized(v)\n'
               '  if type(v.rlsmpNamespace) == "string" and #v.rlsmpNamespace == 32 and v.rlsmpNamespace:match("^%x+$") then\n'
               '    rlsmpNamespace = v.rlsmpNamespace\n'
               '    saveRoot = "settings/rlsmpTeamx/saves/" .. rlsmpNamespace .. "/"\n'
               '  end\n')
    elif name.endswith('/career/garage/inventory/persistence.lua'):
        change('return vehicle and vehicle.listedForAuction == true',
               'return vehicle and (vehicle.listedForAuction == true or vehicle.rlsmpTradeLock ~= nil)')
        change('    if not vehicle or not vehicle.owned then return false end',
               '    if not vehicle or not vehicle.owned or vehicle.rlsmpTradeLock then return false end')
    elif name.endswith('/career/garage/inventory/operations.lua'):
        change('    if vehicle.listedForAuction then return false end',
               '    if vehicle.listedForAuction or vehicle.rlsmpTradeLock then return false end')
        change('    if vehicle.timeToAccess or vehicle.listedForAuction then return false end',
               '    if vehicle.timeToAccess or vehicle.listedForAuction or vehicle.rlsmpTradeLock then return false end')
        change('      if vehicle.listedForAuction and AUCTION_LOCKED_TAGS[tag] then',
               '      if (vehicle.listedForAuction or vehicle.rlsmpTradeLock) and AUCTION_LOCKED_TAGS[tag] then')
    elif name.endswith('/career/market/auction/consignment.lua'):
        change("  if vehicle.loanType then return 'Loaned car' end",
               "  if vehicle.rlsmpTradeLock then return 'Reserved for player exchange' end\n"
               "  if vehicle.loanType then return 'Loaned car' end")
    elif name.endswith('/career/garage/inventory/spawn.lua'):
        anchor = '    if vehicleRecord and vehicleRecord.listedForAuction then'
        if text.count(anchor) != 2:
            raise ValueError('Expected two RLS spawn/enter locks')
        text = text.replace(anchor, '    if vehicleRecord and (vehicleRecord.listedForAuction or vehicleRecord.rlsmpTradeLock) then')
    elif name.endswith('/career/garage/inventory/setup.lua'):
        change('      if parked and parked.level == currentLevel and vehicleMap.resolve(record) == currentLevel then',
               '      -- On this server, the saved live-fleet list takes precedence over stale parking records.\n'
               f'      local restoreParked = not {POLICY}.isMultiplayer() or inventoryData.spawnedPlayerVehicles == nil\n'
               '      if restoreParked and parked and parked.level == currentLevel and vehicleMap.resolve(record) == currentLevel then')
    elif name.endswith('/career/garage/inventory/bindings.lua'):
        for signature in ('assignInventoryIdToVehId(inventoryId, vehId)', 'addVehicle(vehId, inventoryId, options)'):
            change(f'  local function {signature}\n',
                   f'  local function {signature}\n'
                   f'    if not {POLICY}.canManageVehicle(vehId) then\n'
                   '      log("W", "rlsmpTeamx", "Refused remote or unknown vehicle inventory binding")\n'
                   '      return\n    end\n')
    elif name.endswith('/career/police/playerDriving.lua'):
        change('local function onTrafficStarted()\n',
               'local function onTrafficStarted()\n'
               f'  if {POLICY}.isMultiplayer() then M.ensureTraffic = false; return end\n')
        change('local function setupTraffic(forceSetup)\n',
               'local function setupTraffic(forceSetup)\n'
               f'  if {POLICY}.isMultiplayer() then\n'
               '    M.ensureTraffic = false\n'
               '    playerData.maxTrafficAmount, playerData.maxParkingAmount = 0, 0\n'
               '    playerData.trafficActive, playerData.desiredParkingAmount = 0, 0\n'
               '    setTrafficSetupInProgress(false)\n    return\n  end\n')
        change('local function onSettingsChanged()\n',
               f'local function onSettingsChanged()\n  if {POLICY}.isMultiplayer() then return end\n')
        change('local function onOverhaulActive(active)\n',
               'local function onOverhaulActive(active)\n'
               f'  if {POLICY}.isMultiplayer() then\n'
               '    setupTraffic()\n    releaseCareerVehiclesGate()\n    return\n  end\n')
        change('local function setPlayerData(newId, oldId)\n',
               f'local function setPlayerData(newId, oldId)\n  if not {POLICY}.canManageVehicle(newId) then return end\n')
        change('local function onVehicleSwitched(oldId, newId)\n',
               f'local function onVehicleSwitched(oldId, newId)\n  if not {POLICY}.canManageVehicle(newId) then return end\n')
    elif name.endswith('/career/utils/installLuaBridgeFallbacks.js'):
        change('const MOD_NAMESPACES = [', 'const MOD_NAMESPACES = [\n  "rlsmpTeamx",')
        change('const OVERHAUL_ARGUMENT_TYPES = {',
               'const OVERHAUL_ARGUMENT_TYPES = {\n'
               '  "rlsmpTeamx.tradeAction": ["String", "Number", "Number", "Number", "String"],\n'
               '  "rlsmpTeamx.getSoloProfileHighlights": ["String", "Number"],\n'
               '  "rlsmpTeamx.importSoloCareer": ["String"],')
    elif name.endswith('/profiles/views/ProfileSelect.vue'):
        change(':preheadings="[$ctx_t(\'ui.playmodes.career\')]">{{ $ctx_t("ui.career.savedProgress") }}',
               ':preheadings="[rlsmpContext?.active ? \'BeamMP - RLS West Coast\' : $ctx_t(\'ui.playmodes.career\')]">{{ rlsmpContext?.active ? "Server careers" : $ctx_t("ui.career.savedProgress") }}')
        change('const importSources = ref([])',
               'const rlsmpContext = ref(null)\nconst importSources = ref([])')
        change('    await ensureImporter()\n    cards = luaList(await fetchImportSourceCards())',
               '''    try { rlsmpContext.value = await lua.rlsmpTeamx.getUiContext() } catch (_) { rlsmpContext.value = null }
    if (rlsmpContext.value?.active) {
      cards = luaList(await lua.rlsmpTeamx.getSoloProfileCards())
    } else {
      await ensureImporter()
      cards = luaList(await fetchImportSourceCards())
    }''')
        change('  return isImportSource(expandedProfile.value)\n',
               '''  if (rlsmpContext.value?.active && expandedProfile.value?.rlsmpSolo) {
    return lua.rlsmpTeamx.getSoloProfileHighlights(expandedProfile.value.rlsmpSolo, 5)
  }
  return isImportSource(expandedProfile.value)
''')
        change('    const opener = document.activeElement\n',
               '''    const solo = profiles.value?.find(profile => profile.id === id)
    if (rlsmpContext.value?.active && solo?.rlsmpSolo) {
      if (!solo.rlsmpCompatible) { profilesError.value = solo.importBlockReason || "Incompatible save"; return }
      isLoading = true
      if ((await lua.rlsmpTeamx.importSoloCareer(solo.rlsmpSolo)) === false) isLoading = false
      return
    }
    const opener = document.activeElement
''')
        change('onMounted(() => {',
               '''function onRlsmpProfileError(reply) {
  isLoading = false
  profilesError.value = reply?.error || "Career action unavailable."
}

onMounted(() => {
  events.on("RLSMPProfileError", onRlsmpProfileError)''')
        change('onBeforeUnmount(() => {',
               'onBeforeUnmount(() => {\n  events.off("RLSMPProfileError", onRlsmpProfileError)')
        change('  if (isAnyModalOpen()) return\n  let active = !!activeProfileId.value',
               '''  if (isAnyModalOpen()) return
  if (rlsmpContext.value?.active) { await lua.rlsmpTeamx.closeProfiles(); return }
  let active = !!activeProfileId.value''')
    elif name.endswith('/career/utils/runtimeComponent.js'):
        change("shallowRef, h, onUnmounted } from 'vue'", "shallowRef, h, onUnmounted, nextTick } from 'vue'")
        change("import { reportUiFailure } from './safeLua'",
               "import { reportUiFailure } from './safeLua'\nimport { useRouteReady } from '@/services/routeReadiness'")
        change('function pendingScreen(file, firstLoad, { phone = true, preload = firstLoad } = {}) {',
               'function pendingScreen(file, firstLoad, { phone = true, preload = firstLoad, profile = false } = {}) {')
        change("    name: phone ? 'PhonePendingScreen' : 'RoutePendingScreen',",
               "    name: profile ? 'RLSMPProfilePendingScreen' : phone ? 'PhonePendingScreen' : 'RoutePendingScreen',")
        change('    setup(_, { attrs }) {\n      const component = shallowRef(loaded)',
               '    setup(_, { attrs }) {\n'
               '      // The profile route declares handlesOwnReady; its visible loader must acknowledge readiness too.\n'
               '      if (profile) useRouteReady({ waitUntilReady: () => nextTick() })\n'
               '      const component = shallowRef(loaded)')
        change("        if (!phone) return h('div')", "        if (!phone && !profile) return h('div')")
        change('    const prepare = async () => {',
               "    const profile = file.endsWith('/profiles/views/ProfileSelect.vue')\n    const prepare = async () => {")
        change('        return await boundedLoad(file)',
               """        const pending = boundedLoad(file)
        if (!profile) return await pending
        // BeamNG cancels routeCommit after 3 s; a cold profile graph can take much longer.
        let timer
        try {
          const outcome = await Promise.race([
            pending.then(component => ({ component }), () => ({})),
            new Promise(resolve => { timer = setTimeout(() => resolve({}), 300) }),
          ])
          return outcome.component || pendingScreen(file, pending, { phone, profile: true })
        } finally { clearTimeout(timer) }""")
        change('        return pendingScreen(file, null, { phone })',
               '        return pendingScreen(file, null, { phone, profile })')
    elif name.endswith('/profiles/components/start/useStartMaps.js'):
        change('  pending = request.then(reply => {\n    const validated = validateCatalog(reply)',
               '''  pending = request.then(async reply => {
    let rlsmp = null
    try { rlsmp = await lua.rlsmpTeamx.getUiContext() } catch (_) {}
    const validated = validateCatalog(reply).filter(map => !rlsmp?.active || map.id === rlsmp.level)''')
    if text != original:
        PATCHES[name] = {'originalSha256': hashlib.sha256(raw).hexdigest(),
                         'patchedSha256': hashlib.sha256(text.encode()).hexdigest()}
        return text.encode('utf-8')
    return raw


def build(source, output):
    with zipfile.ZipFile(source) as upstream:
        upstream_version = json.loads(upstream.read('gameplay/overhaul/version.json'))
    if upstream_version.get('version_string', '').strip() != '2.8.0':
        raise ValueError('This builder requires the RLS 2.8.0 final release')
    PATCHES.clear()
    output.mkdir(parents=True, exist_ok=True)
    # Native RLS now handles these routes and failed-load guards itself.
    for name in ('stores/profilesStore.js', 'utils/coreUiRoutes.js'):
        obsolete = output / 'patched-lua/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career' / name
        obsolete.unlink(missing_ok=True)
    server_dir = output / 'Resources/Server/rlsmpTeamx'
    server_dir.mkdir(parents=True, exist_ok=True)
    config_file = server_dir / 'config.json'
    config = json.loads(config_file.read_text()) if config_file.exists() else {
        'serverId': uuid.uuid4().hex, 'level': 'rls_west_coast', 'storage': 'local',
        'version': '0.8.1-alpha', 'automaticTraffic': False,
    }
    config['level'] = 'rls_west_coast'
    config['version'] = '0.8.1-alpha'
    config_file.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    for path in (ROOT / 'src/server').glob('*.lua'):
        (server_dir / path.name).write_bytes(path.read_bytes())
    (server_dir / 'tradeWire.lua').write_bytes((ROOT / 'src/client/lua/ge/extensions/rlsmpTeamx/tradeWire.lua').read_bytes())
    target = output / 'Resources/Client/rls_career_overhaul_rlsmp_teamx.zip'
    target.parent.mkdir(parents=True, exist_ok=True)
    patched_dir = output / 'patched-lua'
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as dst:
        if 'lua/ge/extensions/overhaul/shell/extensionManager.lua' not in src.namelist():
            raise ValueError('This builder requires the RLS 2.8 / BeamNG 0.40 layout')
        for entry in src.infolist():
            data = src.read(entry)
            if entry.filename.endswith(('.lua', '.js', '.vue')):
                data = patched(entry.filename, data)
            dst.writestr(entry, data)
            if entry.filename in PATCHES:
                path = patched_dir / entry.filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        for path in (ROOT / 'src/client').rglob('*'):
            if path.is_file():
                dst.write(path, path.relative_to(ROOT / 'src/client').as_posix())
    if set(PATCHES) != PATCH_TARGETS:
        raise ValueError(f'Expected 17 patched RLS files, got {len(PATCHES)}')
    manifest = {'version': '0.8.1-alpha', 'source': str(source),
                'upstreamVersion': upstream_version['version_string'].strip(),
                'upstreamSourceSha': upstream_version['source_sha'],
                'sourceSha256': hashlib.file_digest(source.open('rb'), 'sha256').hexdigest(),
                'zipSha256': hashlib.file_digest(target.open('rb'), 'sha256').hexdigest(),
                'serverId': config['serverId'], 'patchedFiles': PATCHES}
    manifest['serverFiles'] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in server_dir.glob('*.lua')}
    update = output / 'RLSMP-0.8.1-update.zip'
    with zipfile.ZipFile(update, 'w', compression=zipfile.ZIP_STORED) as bundle:
        bundle.write(target, target.relative_to(output).as_posix())
        for path in sorted(server_dir.glob('*.lua')):
            bundle.write(path, path.relative_to(output).as_posix())
        bundle.writestr('UPDATE.txt',
            'RLSMP 0.8.1 - Career Selector Cold-Load Recovery\n\n'
            'A visible profile loader now commits before the native route deadline and acknowledges mount readiness.\n'
            'Failed profile imports show a retry button. Other native routes keep their normal loading behavior.\n\n'
            'Stop the server and back up the existing RLSMP files and journals.\n'
            'Extract this update into the server root, replacing the client ZIP and all three server Lua files.\n'
            'KEEP your existing Resources/Server/rlsmpTeamx/config.json and trades.jsonl unchanged.\n'
            'They are not included here. Updating only the client ZIP is not sufficient.\n'
            'Restart the server. Fully close BeamNG on every PC, then reconnect.\n\n'
            'Player Exchange > Market: persistent public car listings, including offline sellers.\n'
            'Sell: publish or withdraw your stored car. Listings have no expiry.\n'
            'Transfer and Offers: wallet transfers between connected players.\n'
            'Stay stopped while saving. Sellers receive sale proceeds on their original career when they return.\n')
    manifest['updateBundle'] = update.name
    manifest['updateSha256'] = hashlib.file_digest(update.open('rb'), 'sha256').hexdigest()
    (output / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'zip': str(target), 'patchedFiles': len(PATCHES), 'serverId': config['serverId']}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'build')
    args = parser.parse_args()
    build(args.source, args.out)
