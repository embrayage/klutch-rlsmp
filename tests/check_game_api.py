"""Check traffic bridge APIs against the installed game, including their argument signatures."""
from pathlib import Path
import re
import os

GAME = Path(os.environ['BEAMNG_DIR'])


def check(root):
    source = (root / 'src/client/lua/ge/extensions/rlsmpTeamx/traffic.lua').read_text()
    targets = {
        'gameplay_traffic': 'lua/ge/extensions/gameplay/traffic.lua',
        'gameplay_traffic_trafficUtils': 'lua/ge/extensions/gameplay/traffic/trafficUtils.lua',
        'core_multiSpawn': 'lua/ge/extensions/core/multiSpawn.lua',
        'spawn': 'lua/ge/spawn.lua',
    }
    calls = 0
    for alias, member in targets.items():
        code = (GAME / member).read_text(encoding='utf-8-sig')
        exports = set(re.findall(r'\bM\.(\w+)\s*=', code))
        # Include references passed to pcall, which must also be public.
        for method in set(re.findall(r'\b' + alias + r'\.(\w+)\b', source)):
            assert method in exports, f'{alias}.{method} is not public in the installed game'
            calls += 1
    utilities = (GAME / 'lua/ge/ge_utils.lua').read_text(encoding='utf-8-sig')
    for name in ('canSpawnAnotherVehicle', 'sanitizeVehicleSpawnOptions'):
        assert re.search(r'function ' + name + r'\(', utilities), name
    traffic = (GAME / targets['gameplay_traffic']).read_text()
    assert 'local function insertTraffic(id, ignoreAi, ignoreVehPool)' in traffic
    assert 'local function setFocus(mode, data)' in traffic
    pool = (GAME / 'lua/ge/extensions/core/vehicleActivePooling.lua').read_text()
    assert 'function VehPool:setVeh(vehId, activate, forceInsert)' in pool
    assert 'if not self.allVehs[vehId] then return false end' in pool
    print(f'PASS: {calls} traffic calls/references checked against actual game exports, signatures and pooling behavior')
    router = (GAME / 'lua/ge/extensions/ui/router.lua').read_text(encoding='utf-8-sig')
    assert 'M.getState = function()' in router
    assert 'currentRoute = NavigationState.getCurrentEntry()' in router
    beammp = (root / 'reference/beammp/lua/ge/extensions/MPGameNetwork.lua').read_text(encoding='utf-8-sig')
    assert re.search(r'M\.launcherConnected\s*=\s*isLauncherConnected', beammp)
    extensions = (GAME / 'lua/common/extensions.lua').read_text(encoding='utf-8-sig')
    assert 'M.hookUpdate = hookUpdate' in extensions
    vehicle_source = (root / 'reference/beammp/lua/vehicle/extensions/BeamMP/positionVE.lua').read_text(encoding='utf-8-sig')
    for method in ('getPositionXYZ','getVelocityXYZ','getDirectionVectorXYZ','getDirectionVectorUpXYZ','getRollPitchYawAngularVelocity'):
        assert method in vehicle_source
