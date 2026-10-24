"""Run source checks without requiring RLS, BeamNG or BeamMP assets."""
from pathlib import Path
import ast
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def check():
    python = [ROOT / 'build.py', *(ROOT / 'tools').glob('*.py'), *(ROOT / 'tests').glob('*.py')]
    for file in python:
        ast.parse(file.read_text(encoding='utf-8-sig'), filename=str(file.relative_to(ROOT)))
    manifests = list((ROOT / 'src').rglob('*.json'))
    for file in manifests:
        json.loads(file.read_text(encoding='utf-8-sig'))
    node = shutil.which('node')
    scripts = list((ROOT / 'tests').glob('*.cjs')) if node else []
    for file in scripts:
        subprocess.run([node, '--check', str(file)], check=True)
    print(f'PASS: {len(python)} Python sources, {len(manifests)} JSON manifests, {len(scripts)} Node scripts')
    if not node:
        print('Node syntax checks skipped: Node.js is not installed')


if __name__ == '__main__':
    check()
