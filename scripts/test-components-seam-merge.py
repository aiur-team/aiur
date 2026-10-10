#!/usr/bin/env python3
"""Two branches that each add a seam merge without conflict and both seams load."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parent.parent
SEAMS = 'scripts/components/seams'
spec = importlib.util.spec_from_file_location('check_components', REPO / 'scripts/check-components.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

# Inline seams share one line, which is the conflict this layout removes.
assert 'seams' not in json.loads((REPO / 'components.json').read_text()), \
    f'components.json: declare seams as one file each under {SEAMS}/'

with tempfile.TemporaryDirectory(prefix='components-seam-merge-') as directory:
    root = Path(directory)

    def git(*args):
        return subprocess.run(['git', '-C', directory, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                               *args], check=True, capture_output=True, text=True).stdout.strip()

    for name in ('components.json', 'components.schema.json'):
        shutil.copyfile(REPO / name, root / name)
    shutil.copytree(REPO / SEAMS, root / SEAMS)
    git('init', '-q', '-b', 'base')
    git('add', '.')
    git('commit', '-q', '-m', 'base')
    before = len(checker.load_manifest(root)['seams'])
    for branch in ('left', 'right'):
        git('switch', '-q', '-c', branch, 'base')
        seam = {'from': 'orchestration', 'to_module': f'Aiur.Fixture.{branch.title()}', 'kind': 'reference',
                'reason': '#4010: fixture'}
        (root / SEAMS / f'orchestration--Aiur.Fixture.{branch.title()}--reference.json').write_text(
            json.dumps(seam, indent=2) + '\n')
        git('add', '.')
        git('commit', '-q', '-m', branch)
    # merge-tree exits non-zero on any conflict; check=True turns that into a failure.
    tree = git('merge-tree', '--write-tree', 'left', 'right').splitlines()[0]
    git('archive', '-o', 'merged.tar', tree)
    with tarfile.open(root / 'merged.tar') as archive:
        archive.extractall(root / 'merged', filter='data')
    seams = checker.load_manifest(root / 'merged')['seams']
    assert {'Aiur.Fixture.Left', 'Aiur.Fixture.Right'} <= {seam['to_module'] for seam in seams}, seams
    assert len(seams) == before + 2, (before, len(seams))

print('PASS: independent seam additions merge without conflict')
