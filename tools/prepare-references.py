"""Extract ignored local source fixtures from developer-supplied RLS and BeamMP ZIPs."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TEXT = {'.lua', '.js', '.vue', '.json', '.md', '.txt'}


def prepare(source, name):
    destination = ROOT / 'reference' / name
    destination.mkdir(parents=True, exist_ok=True)
    members = set()
    with zipfile.ZipFile(source) as archive:
        version = (json.loads(archive.read('gameplay/overhaul/version.json'))['version_string'].strip()
                   if name == 'rls' else 'local-client')
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            if not path.parts or path.parts[0] not in ('lua', 'ui', 'gameplay') or path.suffix not in TEXT:
                continue
            if path.is_absolute() or '..' in path.parts or ':' in item.filename or chr(92) in item.filename:
                raise ValueError('Unsafe archive member: ' + item.filename)
            target = destination.joinpath(*path.parts)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError('Reference path escapes its destination')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(item))
            members.add(path.as_posix())
    # Only generated fixture files inside this named reference tree are retired.
    for target in destination.rglob('*'):
        if target.is_file() and target.name != '.source.json' and target.relative_to(destination).as_posix() not in members:
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError('Unexpected fixture path')
            target.unlink()
    with source.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    (destination / '.source.json').write_text(json.dumps({
        'sha256': digest, 'version': version, 'files': len(members),
    }, indent=2) + chr(10), encoding='utf-8')
    print(f'{name}: {len(members)} local reference files prepared')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rls', type=Path, required=True)
    parser.add_argument('--beammp', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.rls.resolve(), 'rls')
    prepare(args.beammp.resolve(), 'beammp')
