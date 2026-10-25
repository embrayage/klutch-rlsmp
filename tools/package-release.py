"""Package verified public release assets without a production server identity."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def package(build, output, commit):
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Provide the full source commit SHA')
    m = json.loads((build / 'build-manifest.json').read_text())
    version = m['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+-alpha', version):
        raise ValueError('Unexpected version')
    number = version.removesuffix('-alpha')
    client = 'Resources/Client/rls_career_overhaul_rlsmp_teamx.zip'
    runtime = {client: (build / client).read_bytes()}
    if sha(runtime[client]) != m['zipSha256']:
        raise ValueError('Client archive hash mismatch')
    with zipfile.ZipFile(build / client) as z:
        for p in (ROOT / 'src/client').rglob('*'):
            if p.is_file() and z.read(p.relative_to(ROOT / 'src/client').as_posix()) != p.read_bytes():
                raise ValueError('Client build differs from source')
    for name in ('main.lua', 'trade.lua', 'tradeWire.lua'):
        member = 'Resources/Server/rlsmpTeamx/' + name
        data = (build / member).read_bytes()
        source = ROOT / ('src/client/lua/ge/extensions/rlsmpTeamx/tradeWire.lua' if name == 'tradeWire.lua' else 'src/server/' + name)
        if sha(data) != m['serverFiles'][name] or data != source.read_bytes():
            raise ValueError('Server build mismatch: ' + name)
        runtime[member] = data
    if f"local VERSION = '{version}'".encode() not in runtime['Resources/Server/rlsmpTeamx/main.lua']:
        raise ValueError('Server version mismatch')
    common = f'''Klutch RLSMP {version}
RLS Career Overhaul {m['upstreamVersion']} / BeamNG.drive 0.40 / BeamMP Server 3.9.3.

CAREER SELECTOR FIX
The profile screen now shows visible loading/retry UI within the native
navigation deadline and acknowledges native mount readiness. Automated checks
passed; validation on the affected third-party players' PCs is still pending.

UPDATING AN EXISTING SERVER
Stop and back up the server. Replace the client ZIP and all three server Lua
files in Resources. KEEP the installed config.json and trades.jsonl.
Never regenerate an established server identity.
Keep this patched ZIP as the only RLS provider in Resources/Client.
Restart the server. Fully close BeamNG on each PC, then reconnect.
'''
    setup = '''
FIRST INSTALLATION
1. Extract this archive into the stopped BeamMP server's root directory.
2. On Windows, run from the server root:
   powershell -NoProfile -ExecutionPolicy Bypass -File .\\Configure-RLSMP.ps1 -ServerRoot .
   This generates a unique ID for a new server and preserves existing config.
3. Linux/manual NEW installation: copy config.example.json to config.json and
   replace its serverId placeholder with a fresh 32-hex UUID. Generate one with:
   python3 -c "import uuid; print(uuid.uuid4().hex)"
   Each independent server needs a different ID. Keep it after first use.
4. In your existing ServerConfig.toml, set:
   Map = "/levels/rls_west_coast/info.json"
   Keep your authentication key/network settings. Allow room for player cars
   and three synchronized AI per active career player.
5. Start BeamMP from its root, reconnect with a signed-in BeamMP account and
   select or create a career.

No production configuration, journals, saves, credentials or server executables
are included. Original RLS notices are retained inside the patched client ZIP.
Source: https://github.com/embrayage/klutch-rlsmp
'''
    install = {**runtime,
        'Configure-RLSMP.ps1': (ROOT / 'tools/configure-server.ps1').read_bytes(),
        'CREDITS.md': (ROOT / 'THIRD_PARTY.md').read_bytes(),
        'INSTALL.txt': (common + setup).encode(),
        'Resources/Server/rlsmpTeamx/config.example.json': (json.dumps({
            'serverId': 'GENERATE_A_NEW_32_HEX_ID', 'level': 'rls_west_coast',
            'storage': 'local', 'version': version, 'automaticTraffic': False,
        }, indent=2) + '\n').encode()}
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for kind, contents in [('server-install', install), ('update', {**runtime, 'UPDATE.txt': common.encode()})]:
        metadata = {'version': version, 'packageKind': kind, 'sourceCommit': commit,
                    'upstreamVersion': m['upstreamVersion'], 'upstreamSha256': m['sourceSha256'],
                    'clientSha256': m['zipSha256'], 'files': {n: sha(b) for n, b in contents.items()}}
        encoded = (json.dumps(metadata, indent=2) + '\n').encode()
        if m['serverId'].encode() in encoded:
            raise ValueError('Production identity must not be packaged')
        contents = {**contents, 'PACKAGE-MANIFEST.json': encoded}
        target = output / f'RLSMP-{number}-{kind}.zip'
        with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_STORED) as z:
            for name, data in contents.items():
                if Path(name).name in ('config.json', 'trades.jsonl', 'ServerConfig.toml'):
                    raise ValueError('Private data must not be packaged')
                z.writestr(name, data)
        with zipfile.ZipFile(target) as z:
            if z.testzip() is not None or len(z.namelist()) != len(contents):
                raise ValueError('Invalid archive')
            for name, digest in metadata['files'].items():
                if sha(z.read(name)) != digest:
                    raise ValueError('Packaged hash mismatch: ' + name)
        with target.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        results.append({'name': target.name, 'sha256': digest, 'bytes': target.stat().st_size})
    (output / 'SHA256SUMS.txt').write_text(''.join(f"{r['sha256']}  {r['name']}\n" for r in results))
    (output / 'release-results.json').write_text(json.dumps({'version': version, 'sourceCommit': commit, 'assets': results}, indent=2) + '\n')
    print(json.dumps({'version': version, 'sourceCommit': commit, 'assets': results}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/release')
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    package(args.build_dir.resolve(), args.out.resolve(), args.commit)
