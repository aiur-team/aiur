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
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packages/newsletter'))
import daily
import render


def snapshot(now=None):
    now = now or datetime.now(timezone.utc)
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
        return self.root / 'newsletter' / datetime.now(ZoneInfo('America/Los_Angeles')).date().isoformat()

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
            self.assertEqual(emit.call_count, 3)
            command = emit.call_args.args[0]
            self.assertEqual(command[:4], ['test-aiur', 'executor-emit', 'system.newsletter.ready', '--payload'])
            self.assertEqual(json.loads(command[4])['pdf_path'], str(pdf))
        self.assertIn('FAILED:', (self.outputs() / 'run.log').read_text())

    def test_daily_runner_uses_configured_aiur_over_path(self):
        configured_dir = self.root / 'configured'
        path_dir = self.root / 'path-first'
        configured_dir.mkdir()
        path_dir.mkdir()
        configured_log = self.root / 'configured-calls.jsonl'
        path_log = self.root / 'path-calls.jsonl'
        for directory, log in ((configured_dir, configured_log), (path_dir, path_log)):
            executable = directory / 'aiur'
            executable.write_text(
                '#!/usr/bin/env python3\n'
                'import json, os, sys\n'
                'with open(os.environ["CALL_LOG"], "a") as stream:\n'
                ' stream.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                'if "units" in sys.argv: print(json.dumps({"data":{"view":{"rows":[]}},"auxiliary":{}}))\n'
            )
            executable.chmod(0o755)
        args = ['--repo', 'owner/repo', '--state-dir', str(self.root)]
        result = subprocess.run([str(ROOT / 'scripts/newsletter/run-daily.sh'), *args],
                                capture_output=True, text=True,
                                env={**os.environ, 'HOME': str(self.root),
                                     'PATH': str(path_dir) + os.pathsep + os.environ['PATH'],
                                     'NEWSLETTER_AIUR': str(configured_dir / 'aiur'),
                                     'CALL_LOG': str(configured_log)})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in configured_log.read_text().splitlines()]
        self.assertTrue(any('units' in call for call in calls), calls)
        self.assertTrue(any(call[:2] == ['executor-emit', 'system.newsletter.ready'] for call in calls), calls)
        self.assertFalse(path_log.exists())

    def test_render_failure_emits_failed_wake_and_limits_service_retries(self):
        args = self.arguments[:5] + ['--aiur', 'test-aiur']
        with patch.object(sys, 'argv', args), patch.object(daily.newsletter, 'collect', return_value=snapshot()), patch.object(daily.newsletter, 'publish', side_effect=RuntimeError('render failed')), patch.object(daily.subprocess, 'run') as emit:
            self.assertEqual(daily.main(), 1)
        emit.assert_called_once()
        command = emit.call_args.args[0]
        self.assertEqual(command[:4], ['test-aiur', 'executor-emit', 'executor.newsletter.failed', '--payload'])
        self.assertEqual(json.loads(command[4]), {
            'repo': 'owner/repo', 'date': self.outputs().name, 'stage': 'compile',
            'reason': 'render failed', 'log_path': str(self.outputs() / 'run.log')})
        self.assertFalse((self.outputs() / 'wake-sent.json').exists())
        service = (ROOT / 'scripts/newsletter/systemd/aiur-newsletter.service').read_text()
        unit = service.split('[Unit]', 1)[1].split('[Service]', 1)[0]
        self.assertIn('StartLimitIntervalSec=3h', unit.splitlines())
        self.assertIn('StartLimitBurst=6', unit.splitlines())

    def test_failed_notification_is_best_effort_and_keeps_original_error(self):
        args = self.arguments[:5] + ['--aiur', 'missing-aiur']
        with patch.object(sys, 'argv', args), patch.object(daily.newsletter, 'collect', side_effect=RuntimeError('collect failed')), patch.object(daily.subprocess, 'run', side_effect=FileNotFoundError('CLI unavailable')):
            self.assertEqual(daily.main(), 1)
        log = (self.outputs() / 'run.log').read_text()
        self.assertIn('FAILED: collect failed', log)
        self.assertIn('Failure notification failed: CLI unavailable', log)

    def test_catchup_does_not_suppress_next_local_morning(self):
        evening = datetime(2026, 10, 30, 1, tzinfo=timezone.utc)
        morning = datetime(2026, 10, 30, 12, tzinfo=timezone.utc)
        args = self.arguments[:5] + ['--aiur', 'test-aiur']

        def publish(report_path, report, timezone_name):
            report_path.with_name('newsletter.html').write_text('test page')
            pdf = report_path.with_name('newsletter.pdf')
            pdf.write_bytes(b'test PDF')
            return pdf

        with patch.object(sys, 'argv', args), patch.object(daily, 'datetime') as clock, patch.object(daily.newsletter, 'collect', side_effect=[snapshot(evening), snapshot(morning)]), patch.object(daily.newsletter, 'publish', side_effect=publish), patch.object(daily.subprocess, 'run') as emit:
            clock.now.side_effect = [evening, morning, morning]
            self.assertEqual(daily.main(), 0)
            self.assertTrue((self.root / 'newsletter/2026-10-29/wake-sent.json').exists())
            self.assertFalse((self.root / 'newsletter/2026-10-30/wake-sent.json').exists())
            self.assertEqual(daily.main(), 0)
            self.assertEqual(daily.main(), 0)
        self.assertEqual(emit.call_count, 2)
        payloads = [json.loads(call.args[0][4]) for call in emit.call_args_list]
        self.assertEqual([row['date'] for row in payloads], ['2026-10-29', '2026-10-30'])
        for row in payloads:
            directory = self.root / 'newsletter' / row['date']
            self.assertEqual(row['report_path'], str(directory / 'report.json'))
            self.assertEqual(row['pdf_path'], str(directory / 'newsletter.pdf'))
            self.assertTrue((directory / 'wake-sent.json').exists())
        self.assertEqual(datetime.fromisoformat(json.loads((self.root / 'newsletter/2026-10-29/report.json').read_text())['window_end']), evening)

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
