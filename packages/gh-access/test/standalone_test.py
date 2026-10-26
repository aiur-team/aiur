"""Exercise built executables against a fake gh; no network or host state.

Core cases characterize existing behavior as future composition-regression
guards; standalone defaults, policy selection and token isolation cover the
new adapter. One shared stub keeps the build-to-command boundary under test.
"""
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import select
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('builder', ROOT / 'packages/gh-access/build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class StandaloneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='gh-access-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.build(self.bin)
        self.calls = self.root / 'calls'
        self.stub = self.root / 'real-gh'
        self.stub.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'args': args, 'token': os.environ.get('GH_TOKEN', '')}) + '\\n')
if args[:2] == ['auth', 'token']:
    print('keyring-token')
elif args[:2] == ['api', 'user']:
    print('test-user')
else:
    if os.environ.get('BLOCK_FIFO'):
        with open(os.environ['READY_FIFO'], 'w') as f: f.write('ready\\n')
        with open(os.environ['BLOCK_FIFO']) as f: f.read(1)
    if args[0] == 'api' and '--include' in args:
        print('HTTP/2.0 200 OK\\nETag: "one"\\n')
    print('{"title":"fixed answer"}')
''')
        self.stub.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('AIUR_', 'GH_', 'GITHUB_'))}
        self.env.update(HOME=str(self.root), AIUR_REAL_GH=str(self.stub), CALLS=str(self.calls),
                        AIUR_GITHUB_BUDGET_ROOT=str(self.root / 'state'),
                        AIUR_AGENT_QUOTA_STATE_PATH=str(self.root / 'quota'),
                        AIUR_GITHUB_BUDGET_KEY='test-credential',
                        AIUR_GITHUB_STATE_CACHE_TTL_MS='60000')

    def build(self, output, *flags):
        subprocess.run(['sh', str(ROOT / 'packages/gh-access/build.sh'), '--output', str(output), *flags], check=True)

    def run_gh(self, *args, binary=None, env=None):
        return subprocess.run([str(binary or self.bin / 'gh-access'), *args],
                              env=self.env | (env or {}), capture_output=True, text=True, timeout=20)

    def requests(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_aiur_hash_and_manifest_tags(self):
        expected = (builder.PARTS / 'aiur-gh.sha256').read_text().strip()
        self.assertEqual(hashlib.sha256(builder.compose('aiur').encode()).hexdigest(), expected)
        self.assertEqual(sorted(p.name for p in (builder.PARTS / 'gh').glob('*.sh')),
                         sorted(line.split()[1] for line in (builder.PARTS / 'parts.tsv').read_text().splitlines()))

    def test_cache_hit_is_byte_exact(self):
        first = self.run_gh('api', 'repos/o/r/issues/1')
        second = self.run_gh('api', 'repos/o/r/issues/1')
        self.assertEqual((first.returncode, second.returncode), (0, 0), first.stderr + second.stderr)
        self.assertEqual(first.stdout, '{"title":"fixed answer"}\n')
        self.assertEqual(second.stdout, first.stdout)
        self.assertEqual(len(self.requests()), 1)
        self.assertIn('\thit\t', (self.root / 'quota/agent-cache.tsv').read_text())

    def test_defaults_share_keyring_credential_state(self):
        env = dict(self.env)
        for key in ['AIUR_REAL_GH', 'AIUR_GITHUB_BUDGET_ROOT', 'AIUR_GITHUB_BUDGET_KEY']:
            env.pop(key)
        real_bin = self.root / 'real-bin'
        real_bin.mkdir()
        (real_bin / 'gh').symlink_to(self.stub)
        env['PATH'] = str(self.bin) + ':' + str(real_bin) + ':' + env['PATH']
        for _ in range(2):
            result = subprocess.run([str(self.bin / 'gh-access'), 'api', 'repos/o/r/issues/8'],
                                    env=env, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / '.aiur/github-budget/budget.sqlite3').exists())
        requests = self.requests()
        self.assertEqual(sum(row['args'][:2] == ['api', 'repos/o/r/issues/8'] for row in requests), 1)
        self.assertTrue(all(row['token'] == '' for row in requests))

    def test_write_invalidates_cached_answer(self):
        self.assertEqual(self.run_gh('api', 'repos/o/r/issues/1').returncode, 0)
        result = self.run_gh('issue', 'edit', '1', '--repo', 'o/r', '--title', 'changed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_gh('api', 'repos/o/r/issues/1').returncode, 0)
        self.assertEqual(len(self.requests()), 3)

    def test_verdicts_are_never_shared(self):
        for _ in range(2):
            result = self.run_gh('pr', 'view', '1', '--repo', 'o/r', '--json', 'statusCheckRollup')
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests()), 2)

    def test_concurrent_reads_coalesce(self):
        ready, release, waiting = [self.root / name for name in ['ready', 'release', 'waiting']]
        for fifo in [ready, release, waiting]:
            os.mkfifo(fifo)
        notify = os.open(waiting, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, notify)
        # Observe a real follower admission waiting on the leader's claim before
        # releasing its HTTP response. Without coalescing this signal never fires.
        broker = self.root / 'broker'
        broker.write_text(f'''#!/usr/bin/env python3
import os, subprocess, sys
result = subprocess.run([{str(self.bin / 'gh-access-broker')!r}, *sys.argv[1:]], capture_output=True)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
if result.stdout.startswith(b'wait '):
    with open({str(waiting)!r}, 'w') as f: f.write('wait\\n')
sys.exit(result.returncode)
''')
        broker.chmod(0o755)
        env = {'READY_FIFO': str(ready), 'BLOCK_FIFO': str(release), 'AIUR_GITHUB_BUDGET_BROKER': str(broker)}
        with concurrent.futures.ThreadPoolExecutor() as pool:
            leader = pool.submit(self.run_gh, 'api', 'repos/o/r/issues/2', env=env)
            with ready.open() as f:
                self.assertEqual(f.readline(), 'ready\n')
            follower = pool.submit(self.run_gh, 'api', 'repos/o/r/issues/2',
                                   env={'AIUR_GITHUB_BUDGET_BROKER': str(broker)})
            try:
                self.assertTrue(select.select([notify], [], [], 10)[0], 'follower never waited on the shared claim')
                self.assertEqual(os.read(notify, 100), b'wait\n')
            finally:
                with release.open('w') as f:
                    f.write('x')
            a, b = leader.result(), follower.result()
        self.assertEqual((a.returncode, b.returncode), (0, 0), a.stderr + b.stderr)
        self.assertEqual(a.stdout, b.stdout)
        self.assertEqual(len(self.requests()), 1)

    def test_standalone_policy_and_mandatory_aiur_gate(self):
        aiur = self.root / '.aiur-runtime/bin'
        denied = self.root / 'denied'
        self.build(aiur, '--adapter', 'aiur')
        self.build(denied, '--deny-merge')
        self.assertEqual(self.run_gh('api', 'repos/o/r/issues/9', binary=aiur / 'gh').returncode, 0)
        for args in [('pr', 'merge', '1'), ('pr', 'review', '1', '--approve')]:
            self.assertEqual(self.run_gh(*args).returncode, 0)
            self.assertEqual(self.run_gh(*args, binary=denied / 'gh-access').returncode, 77)
            for value in ['', '0', 'false']:
                result = self.run_gh(*args, binary=aiur / 'gh', env={
                    'AIUR_GITHUB_BUDGET_ENABLED': '0', 'AIUR_AGENT_WORKSPACE': '',
                    'AIUR_GH_ACCESS_DENY_MERGE': value})
                self.assertEqual(result.returncode, 77, result.stderr)
        for args in [('alias', 'set', 'merge-it', 'pr merge'), ('merge-it', '1')]:
            self.assertEqual(self.run_gh(*args).returncode, 0)
            self.assertEqual(self.run_gh(*args, binary=denied / 'gh-access').returncode, 77)
        self.assertEqual(self.run_gh('issue', 'create', '--title', 'x').returncode, 0)
        direct = ('api', 'repos/o/r/issues', '-X', 'POST', '-f', 'title=x')
        self.assertEqual(self.run_gh(*direct).returncode, 0)
        self.assertEqual(self.run_gh(*direct, binary=aiur / 'gh').returncode, 78)
        self.assertEqual(self.run_gh('issue', 'create', '--title', 'x', binary=aiur / 'gh').returncode, 78)
        validation = ('--validate-issue-command', 'issue', 'create', '--title', 'x')
        self.assertEqual(self.run_gh(*validation).returncode, 0)
        self.assertEqual(self.requests()[-1]['args'], list(validation))
        self.assertEqual(self.run_gh(*validation, binary=aiur / 'gh').returncode, 78)
        result = subprocess.run(['sh', str(ROOT / 'packages/gh-access/build.sh'), '--adapter', 'aiur',
                                 '--deny-merge', '--output', str(aiur)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_tokens_only_reach_real_gh_from_credential_file(self):
        # dirname is a sibling helper invoked before real gh, including by bootstrap.
        helpers = self.root / 'helpers'
        helpers.mkdir()
        dirname = helpers / 'dirname'
        dirname.write_text('#!/bin/sh\nenv > "$SIBLING_ENV"\nexec /usr/bin/dirname "$@"\n')
        dirname.chmod(0o755)
        shasum = helpers / 'shasum'
        shasum.write_text('#!/bin/sh\nenv >> "$SIBLING_ENV"\nexec /usr/bin/shasum "$@"\n')
        shasum.chmod(0o755)
        env = {'GH_TOKEN': 'caller-secret', 'GITHUB_TOKEN': 'other-secret',
               'guard_token': 'inherited', 'budget_token': 'inherited',
               'PATH': str(helpers) + ':' + self.env['PATH'], 'SIBLING_ENV': str(self.root / 'sibling')}
        result = self.run_gh('api', 'repos/o/r/issues/3', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests()[0]['token'], '')
        self.assertNotIn('secret', (self.root / 'sibling').read_text())
        credential = self.root / 'credential'
        credential.write_text('file-secret\n')
        result = self.run_gh('api', 'repos/o/r/issues/4', env=env | {'AIUR_GITHUB_CREDENTIAL_FILE': str(credential), 'AIUR_GITHUB_BUDGET_KEY': ''})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests()[-1]['token'], 'file-secret')
        self.assertNotIn('secret', (self.root / 'sibling').read_text())

    def test_budget_identity_and_disabled_budget(self):
        self.assertEqual(self.run_gh('api', 'repos/o/r/issues/5').returncode, 0)
        with sqlite3.connect(self.root / 'state/budget.sqlite3') as db:
            labels = db.execute('select distinct consumer_label from policies').fetchall()
        self.assertEqual(labels, [('gh-access',)])
        other = self.root / 'disabled'
        result = self.run_gh('api', 'repos/o/r/issues/6', env={
            'AIUR_GITHUB_BUDGET_ENABLED': '0', 'AIUR_GITHUB_BUDGET_ROOT': str(other)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((other / 'budget.sqlite3').exists())

    def test_missing_broker_fails_closed(self):
        result = self.run_gh('api', 'repos/o/r/issues/7', env={'AIUR_GITHUB_BUDGET_BROKER': '/missing'})
        self.assertEqual(result.returncode, 75)
        self.assertIn('refusing uncoordinated request', result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
