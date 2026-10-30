#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile

repo = Path(sys.argv[1])
checker = Path(os.environ.get('LISTENER_SPEC_CHECKER', repo / 'scripts/check-listener-spec.py'))
with tempfile.TemporaryDirectory(prefix='listener-spec-', dir=os.environ.get('TMPDIR')) as tmp:
    fixture = Path(tmp) / 'spec'

    def reset():
        if fixture.exists():
            shutil.rmtree(fixture)
        shutil.copytree(repo / 'src/priv/listener_spec', fixture)

    def check(label, expected):
        result = subprocess.run([sys.executable, str(checker), str(fixture)], capture_output=True)
        assert (result.returncode == 0) == expected, (label, result.stdout, result.stderr)
        print(label + ': pass')

    def repin():
        lines = (fixture / 'CHECKSUM').read_text().splitlines()[:2]
        for path in sorted((fixture / 'v1').rglob('*')):
            if path.is_file():
                lines.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.relative_to(fixture).as_posix())
        (fixture / 'CHECKSUM').write_text('\n'.join(lines) + '\n')

    reset()
    check('clean', True)
    scheduler = fixture / 'v1/scheduler.v1.json'
    scheduler.write_bytes(scheduler.read_bytes() + b' ')
    check('edited byte', False)
    repin()
    check('edited byte with CHECKSUM repinned (MANIFEST must reject)', False)
    reset()
    (fixture / 'v1/extra.json').write_text('{}')
    check('extra file', False)
    reset()
    (fixture / 'v1/CHECKSUM').write_text('hidden extra')
    check('nested CHECKSUM extra', False)
    reset()
    (fixture / 'v1/scheduler.v1.json').unlink()
    check('missing file', False)
    reset()
    manifest_path = fixture / 'v1/MANIFEST.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['files'].append(manifest['files'][0])
    manifest_path.write_text(json.dumps(manifest))
    repin()
    check('duplicate manifest entry', False)
    reset()
    (fixture / 'v1/linked').symlink_to('scheduler.v1.json')
    check('symlink', False)
    reset()
    checksum = fixture / 'CHECKSUM'
    checksum.write_text(checksum.read_text() + checksum.read_text().splitlines()[2] + '\n')
    check('duplicate CHECKSUM entry', False)

    # Exercise the real writer with a local archive and a failing network boundary.
    checkout = Path(tmp) / 'checkout'
    (checkout / 'scripts').mkdir(parents=True)
    (checkout / 'src/priv').mkdir(parents=True)
    for name in ['vendor-listener-spec', 'check-listener-spec.py']:
        shutil.copy(repo / 'scripts' / name, checkout / 'scripts' / name)
    archive = Path(tmp) / 'source.tar.gz'
    with tarfile.open(archive, 'w:gz') as output:
        entry = tarfile.TarInfo('khala-pin/')
        entry.type = tarfile.DIRTYPE
        output.addfile(entry)
        output.add(repo / 'src/priv/listener_spec/v1', arcname='khala-pin/packages/listener/spec/v1')
    fake_bin = Path(tmp) / 'bin'
    fake_bin.mkdir()
    gh = fake_bin / 'gh'
    gh.write_text('#!/bin/sh\n[ "$FAIL_DOWNLOAD" != 1 ] || exit 23\ncat "$ARCHIVE"\n')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=str(fake_bin) + ':' + os.environ['PATH'], ARCHIVE=str(archive), BASH_ENV='/dev/null')
    commit = (repo / 'src/priv/listener_spec/CHECKSUM').read_text().splitlines()[1].split()[-1]
    command = ['bash', str(checkout / 'scripts/vendor-listener-spec'), commit]
    subprocess.run(command, env=env, check=True, capture_output=True)
    destination = checkout / 'src/priv/listener_spec'
    before = {p.relative_to(destination): p.read_bytes() for p in destination.rglob('*') if p.is_file()}
    assert before == {p.relative_to(repo / 'src/priv/listener_spec'): p.read_bytes()
                      for p in (repo / 'src/priv/listener_spec').rglob('*') if p.is_file()}
    for failure in ['network', 'manifest']:
        env['FAIL_DOWNLOAD'] = '1' if failure == 'network' else '0'
        if failure == 'manifest':
            with tarfile.open(archive, 'w:gz') as output:
                entry = tarfile.TarInfo('khala-pin/')
                entry.type = tarfile.DIRTYPE
                output.addfile(entry)
                reset()
                (fixture / 'v1/scheduler.v1.json').write_text('[]')
                output.add(fixture / 'v1', arcname='khala-pin/packages/listener/spec/v1')
        assert subprocess.run(command, env=env, capture_output=True).returncode != 0
        assert before == {p.relative_to(destination): p.read_bytes() for p in destination.rglob('*') if p.is_file()}
        print('vendor ' + failure + ' failure preserves destination: pass')
    print('vendor exact upstream files: pass')
PY
