"""Check bridge calls against exports of the real RLS files, not test doubles."""
from pathlib import Path
import json
import re
import zipfile


def check(root: Path):
    manifest = json.loads((root / 'build/build-manifest.json').read_text(encoding='utf-8'))
    targets = {
        'career': 'overhaul/career/career.lua',
        'overhaul_career_career': 'overhaul/career/career.lua',
        'saves': 'overhaul/career/saveSystem.lua',
        'overhaul_career_saveSystem': 'overhaul/career/saveSystem.lua',
        'migration': 'overhaul/career/saveMigration.lua',
        'proxy': 'overhaul/world/levelProxy.lua',
        'inv()': 'overhaul/career/garage/inventory.lua',
        'parts()': 'overhaul/career/parts/partInventory.lua',
        'money()': 'overhaul/career/economy/playerAttributes.lua',
    }
    exports = {}
    with zipfile.ZipFile(manifest['source']) as archive:
        for alias, relative in targets.items():
            member = 'lua/ge/extensions/' + relative
            patched = root / 'build/patched-lua' / member
            source = patched.read_text(encoding='utf-8-sig') if patched.exists() else archive.read(member).decode('utf-8-sig')
            exports[alias] = set(re.findall(r'\bM\.(\w+)\s*=', source))
            exports[alias].update(re.findall(r'\bfunction\s+M\.(\w+)\s*\(', source))
    calls = 0
    for path in (root / 'src/client').rglob('*.lua'):
        source = path.read_text(encoding='utf-8')
        for alias, methods in exports.items():
            for method in re.findall(r'\b' + re.escape(alias) + r'\.(\w+)\s*\(', source):
                assert method in methods, f'{path.name}: {alias}.{method} is not exported by the actual RLS module'
                calls += 1
    print(f'PASS: {calls} bridge calls checked against actual RLS public exports')


if __name__ == '__main__':
    check(Path(__file__).resolve().parents[1])
