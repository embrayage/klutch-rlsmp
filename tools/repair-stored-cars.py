"""Repair explicitly identified accidental spawns in valid MP autosaves; dry-run by default."""
from pathlib import Path
import argparse
import copy
import datetime
import hashlib
import json
import os
import shutil
import subprocess


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def assert_game_closed():
    result = subprocess.run(['powershell', '-NoProfile', '-Command',
        "@(Get-Process -Name 'BeamNG*' -ErrorAction SilentlyContinue).Count"],
        capture_output=True, text=True, check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    if result.stdout.strip() != '0':
        raise RuntimeError('Quit BeamNG completely before repairing its career files.')


def prune_manifest(manifest, ids):
    def node_id(node):
        return str(node.get('inventoryId'))
    def retain_node(node):
        if node_id(node) in ids:
            if node.get('children'):
                raise ValueError('A stored target has attached children; manual review required.')
            return False
        if node.get('children'):
            node['children'] = [child for child in node['children'] if retain_node(child)]
        return True
    if not isinstance(manifest, dict):
        return
    for group in manifest.get('groups', []):
        if str(group.get('rootInventoryId')) in ids and group.get('tree', {}).get('children'):
            raise ValueError('Cannot remove a coupled root without reviewing its children.')
    if 'groups' in manifest:
        manifest['groups'] = [g for g in manifest['groups']
            if str(g.get('rootInventoryId')) not in ids and retain_node(g.get('tree', {}))]
    if 'brakeStates' in manifest:
        manifest['brakeStates'] = [n for n in manifest['brakeStates'] if retain_node(n)]
    if isinstance(manifest.get('savedLocations'), dict):
        for target in ids:
            manifest['savedLocations'].pop(target, None)
    for relation in manifest.get('carriedVehicles', []):
        if str(relation.get('parentInventoryId')) in ids and node_id(relation) not in ids:
            raise ValueError('Cannot strand a carried vehicle; manual review required.')
    if manifest.get('carriedVehicles'):
        manifest['carriedVehicles'] = [r for r in manifest['carriedVehicles'] if node_id(r) not in ids]
    if str(manifest.get('currentInventoryId')) in ids:
        raise ValueError('A target is current in this save; refusing to guess storage intent.')


def build_plan(profile, ids):
    changes = []
    for slot in sorted(profile.glob('autosave*')):
        if not slot.is_dir() or slot.resolve().parent != profile:
            raise ValueError('Unexpected autosave path.')
        info = read(slot / 'info.json')
        if info.get('corrupted') or info.get('date') == '0':
            continue  # Preserve incomplete snapshots, including their invalid marker.
        inventory_path = slot / 'career/inventory.json'
        old = read(inventory_path)
        new = copy.deepcopy(old)
        if str(new.get('currentVehicle')) in ids:
            raise ValueError('A target is current in this autosave; manual review required.')
        fleet = new.get('spawnedPlayerVehicles')
        if not isinstance(fleet, dict):
            raise ValueError('Expected explicit JSON vehicle IDs, not legacy arrays.')
        for target in ids:
            fleet.pop(target, None)
        for key in ('vehicleRelationships', 'mapTravel'):
            prune_manifest(new.get(key), ids)
        if old != new:
            changes.append((inventory_path, new))
        for target in sorted(ids):
            path = slot / 'career/vehicles' / (target + '.json')
            if not path.is_file():
                continue
            old = read(path)
            if str(old.get('id')) != target or not old.get('location'):
                raise ValueError('Target does not have the expected inventory/garage assignment.')
            parked = old.get('worldPosition')
            if parked is not None and parked.get('level') != 'rls_west_coast':
                raise ValueError('Target parking belongs to another map; manual review required.')
            new = copy.deepcopy(old)
            new.pop('worldPosition', None)
            if old != new:
                changes.append((path, new))
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--server-root', type=Path, required=True)
    parser.add_argument('--ids', nargs='+', type=int, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    profile = args.profile.resolve(strict=True)
    server = args.server_root.resolve(strict=True)
    allowed = (Path(os.environ['LOCALAPPDATA']) / 'BeamNG/BeamNG.drive/current/settings/rlsmpTeamx/saves').resolve()
    config = read(server / 'Resources/Server/rlsmpTeamx/config.json')
    if not profile.is_relative_to(allowed) or profile.parent.name != config['serverId']:
        raise ValueError('Expected an existing local career of this BeamMP server.')
    if not profile.name.startswith('beammp_') or not (server / 'BeamMP-Server.exe').is_file():
        raise ValueError('Unexpected profile/server root.')
    ids = {str(i) for i in args.ids if i > 0}
    if not ids or len(ids) != len(args.ids):
        raise ValueError('Specify distinct positive inventory IDs.')
    assert_game_closed()
    plan = []
    for path, value in build_plan(profile, ids):
        path = path.resolve(strict=True)
        if not path.is_relative_to(profile):
            raise ValueError('Repair file escaped the intended profile.')
        original = path.read_bytes()
        output = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        assert json.loads(output) == value
        plan.append((path, original, output))
    print(json.dumps({'profile': str(profile), 'storedIds': sorted(ids),
        'apply': args.apply, 'files': [str(p.relative_to(profile)) for p, _, _ in plan]}))
    if not args.apply or not plan:
        return
    backup = server / 'RLSMP-backups' / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '-stored-cars')
    backup.mkdir(parents=True, exist_ok=False)
    audit = []
    # Finish every backup before replacing any original.
    for path, original, output in plan:
        destination = backup / profile.name / path.relative_to(profile)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        if destination.read_bytes() != original:
            raise RuntimeError('Backup verification failed.')
        audit.append({'file': str(path), 'beforeSha256': digest(original), 'afterSha256': digest(output)})
    (backup / 'repair-manifest.json').write_text(json.dumps(audit, indent=2) + '\n', encoding='utf-8')
    assert_game_closed()
    for path, original, _ in plan:
        if path.read_bytes() != original:
            raise RuntimeError('Save changed since backup; no original has been replaced.')
    for path, _, output in plan:
        temporary = path.with_name(path.name + '.rlsmp-stored-new')
        if temporary.exists() or not temporary.resolve().is_relative_to(profile):
            raise RuntimeError('Unexpected repair temporary path.')
        temporary.write_bytes(output)
        os.replace(temporary, path)
        if path.read_bytes() != output:
            raise RuntimeError('Installed repair verification failed.')
    print('Repaired only saved world-presence data; backup: ' + str(backup))


if __name__ == '__main__':
    main()
