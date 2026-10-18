#!/usr/bin/env python3
"""Exercise the real merge-group classifier against a multi-commit candidate."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='home-ci-', dir=os.environ.get('TMPDIR')) as scratch:
    repo = Path(scratch)

    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

    git('init', '-q')
    git('config', 'user.email', 'ci@example.invalid')
    git('config', 'user.name', 'CI test')

    def commit(path):
        file = repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text('changed\n')
        git('add', '--', path)
        git('commit', '-qm', path)
        return git('rev-parse', 'HEAD')

    base = commit('unrelated.txt')
    home = commit('src/priv/static/build-home/band.js')
    head = commit('docs/after-home.md')
    event = repo / 'event.json'

    def classify(base_sha, head_sha):
        event.write_text(json.dumps({'merge_group': {'base_sha': base_sha, 'head_sha': head_sha}}))
        output, summary = repo / 'output', repo / 'summary'
        output.write_text('')
        run = subprocess.run(['bash', 'scripts/classify-ci-changes.sh'], cwd=ROOT,
                             env={**os.environ, 'EVENT_NAME': 'merge_group',
                                  'GITHUB_EVENT_PATH': str(event), 'GITHUB_WORKSPACE': str(repo),
                                  'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary)},
                             capture_output=True, text=True)
        return run.returncode, output.read_text()

    code, out = classify(base, head)
    assert code == 0 and 'home_changed=true\n' in out, (code, out)
    assert 'full_ci=true\n' in out
    code, out = classify(home, head)
    assert code == 0 and 'home_changed=false\n' in out, (code, out)
    for invalid in ['', 'HEAD^1', 'a' * 40]:
        code, out = classify(invalid, head)
        assert code != 0 and 'full_ci=true\n' not in out, (invalid, code, out)
    event.write_text('{}')
    missing = subprocess.run(['python3', str(ROOT / 'scripts/classify-home-ci.py'), str(event), str(repo)],
                             capture_output=True, text=True)
    assert missing.returncode != 0 and 'home_changed=' not in missing.stdout
    # Moves out of the home tree still count, rather than disappearing behind rename detection.
    git('mv', 'src/priv/static/build-home/band.js', 'moved.js')
    git('commit', '-qm', 'move home file out')
    code, out = classify(head, git('rev-parse', 'HEAD'))
    assert code == 0 and 'home_changed=true\n' in out

    import importlib.util
    spec = importlib.util.spec_from_file_location('home_ci', ROOT / 'scripts/classify-home-ci.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for path in ['src/lib/aiur_web/build/snapshot.ex', 'src/browser/tests/build-home-motion.browser.spec.mjs',
                 'src/browser/support/design-parity.mjs', 'src/browser/playwright.design-parity.config.mjs',
                 'src/test/browser/fixture_server.exs', 'src/browser/scripts/build-home-fixture-map.mjs',
                 'src/test/fixtures/build_home/live.json', 'src/test/support/build_home/fixture_source.ex',
                 'src/test/support/browser_harness/build_control.ex',
                 'src/browser/scripts/run-build-home-band-full.mjs', '.github/actions/setup-browser/action.yml',
                 '.github/workflows/home-parity.yml', 'src/browser/package.json']:
        assert module.touches_home(path), path
    for path in ['src/lib/aiur/core/agent_runner.ex', 'website/docs-app/guide/intro.md']:
        assert not module.touches_home(path), path
print('Home matrix candidate range, rename, shared harness and fail-closed tests passed')
