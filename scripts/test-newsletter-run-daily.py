#!/usr/bin/env python3
"""Daily runner integration, failures and systemd unit verification."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packages/newsletter'))
import daily
import render


def snapshot():
    now = datetime.now(timezone.utc)
    return {'repo': 'owner/repo', 'captured_at': now.isoformat(), 'window_end': now.isoformat(),
            'window_start': (now - timedelta(days=1)).isoformat(), 'sources': {},
            'program': {'tickets': []}, 'merges': [], 'running_build': {},
            'allocation': {'units': None, 'agent_hours': None}, 'meta': [], 'executor_actions': []}


class DailyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = self.root / 'snapshot.json'
        self.fixture.write_text(json.dumps(snapshot()))
        self.arguments = ['run-daily', '--repo', 'owner/repo', '--state-dir', str(self.root),
                          '--dry-run', '--fixture', str(self.fixture)]

    def outputs(self):
        return self.root / 'newsletter' / datetime.now(timezone.utc).date().isoformat()

    def test_dry_run_real_pdf_without_email_or_daemon(self):
        if not any(shutil.which(name) for name in ('chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable')):
            self.skipTest('Chromium not installed')
        result = subprocess.run([str(ROOT / 'scripts/newsletter/run-daily.sh'), *self.arguments[1:]],
                                capture_output=True, text=True, env={**os.environ, 'HOME': str(self.root)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(render.page_count(self.outputs() / 'newsletter.pdf'), 1)
        for name in ('report.json', 'newsletter.html', 'newsletter.pdf'):
            self.assertEqual((self.outputs() / name).read_bytes(),
                             (self.root / 'newsletter/latest' / name).read_bytes())
        self.assertEqual(json.loads((self.outputs() / 'snapshot.json').read_text()),
                         json.loads(self.fixture.read_text()))
        self.assertEqual(len(list((self.root / 'newsletter/snapshots').glob('*.json'))), 1)
        self.assertIn('Dry run; no wake published', (self.outputs() / 'run.log').read_text())
        self.assertFalse((self.outputs() / 'wake-sent.json').exists())

    def test_render_failure_is_nonzero_logged_and_does_not_wake(self):
        with patch.object(sys, 'argv', self.arguments), patch.object(daily.newsletter, 'publish', side_effect=RuntimeError('render failed')), patch.object(daily.subprocess, 'run') as emit:
            self.assertEqual(daily.main(), 1)
        self.assertIn('FAILED: render failed', (self.outputs() / 'run.log').read_text())
        self.assertFalse((self.outputs() / 'wake-sent.json').exists())
        emit.assert_not_called()

    def test_publish_retries_failure_then_skips_completed_day(self):
        report = self.outputs() / 'report.json'
        pdf = self.outputs() / 'newsletter.pdf'
        args = self.arguments[:5] + ['--aiur', 'test-aiur']
        with patch.object(sys, 'argv', args), patch.object(daily, 'build', return_value=(report, pdf)) as build, patch.object(daily.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'test-aiur')) as emit:
            self.assertEqual(daily.main(), 1)
            self.assertFalse((self.outputs() / 'wake-sent.json').exists())
            emit.side_effect = None
            self.assertEqual(daily.main(), 0)
            self.assertEqual(daily.main(), 0)
            self.assertEqual(build.call_count, 2)
            self.assertEqual(emit.call_count, 2)
            command = emit.call_args.args[0]
            self.assertEqual(command[:4], ['test-aiur', 'executor-emit', 'system.newsletter.ready', '--payload'])
            self.assertEqual(json.loads(command[4])['pdf_path'], str(pdf))
        self.assertIn('FAILED:', (self.outputs() / 'run.log').read_text())

    def test_systemd_units_verify(self):
        if not shutil.which('systemd-analyze'):
            self.skipTest('systemd not installed')
        units = ROOT / 'scripts/newsletter/systemd'
        result = subprocess.run(['systemd-analyze', '--user', 'verify',
                                 str(units / 'aiur-newsletter.service'), str(units / 'aiur-newsletter.timer')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        timer = (units / 'aiur-newsletter.timer').read_text()
        self.assertIn('OnCalendar=*-*-* 05:00 America/Los_Angeles', timer)
        self.assertIn('Persistent=true', timer)


if __name__ == '__main__':
    unittest.main(verbosity=2)
