#!/usr/bin/env python3
"""Renderer and package contract, including a real Chromium one-page stress test.

Kept above 200 lines: one suite shares report fixtures and the real print boundary.
"""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
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
sys.path.insert(0, str(ROOT / "packages/newsletter"))
import newsletter
import render
from editorial import read_notes
from metrics import compute

spec = importlib.util.spec_from_file_location("fixtures", ROOT / "scripts/test-newsletter-metrics.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


def report():
    today, prior = fixtures.snapshot(), fixtures.snapshot(-24)
    today["merges"] = [fixtures.merge(1), fixtures.merge(2, **{"class": "other"})]
    today["program"]["tickets"] = [fixtures.ticket(1, "closed", "completed"), fixtures.ticket(2)]
    today["allocation"]["units"] = {"running": {"feature": 2, "test_ci": 1, "tooling": 0, "other": 0},
                                    "waiting": {"feature": 1, "test_ci": 0, "tooling": 0, "other": 0}}
    return compute(today, prior)


def chromium_available():
    try:
        return render.find_chromium()
    except RuntimeError:
        return None


class RendererTest(unittest.TestCase):
    def test_missing_baseline_marks_each_trend_and_scope_unavailable(self):
        today = fixtures.snapshot()
        today["merges"] = [fixtures.merge(1), fixtures.merge(2, **{"class": "other"})]
        today["allocation"]["units"] = {"running": {"feature": 1, "tooling": 1}}
        data = compute(today)
        page = render.html(data)
        for heading in ("Allocation trend", "Scope changes", "Feature share of merges"):
            self.assertIn(heading, page)
        self.assertIn('class="unav">unavailable</span></p>', page.split('Allocation trend')[1])
        self.assertIn('class="unav">unavailable</span>', page.split('class="facts"')[1].split('Feature focus')[0])
        scope = page.split('Scope changes')[1].split('Shipped today')[0]
        self.assertEqual(scope.count('class="unav">unavailable'), 5)
        self.assertIn('stroke-dasharray="50.0 100"', page)

    def test_unknown_feature_share_does_not_draw_zero_gauge(self):
        data = compute(fixtures.snapshot())
        page = render.html(data)
        gauge = page.split('class="gauge"')[1].split('class="facts"')[0]
        self.assertIn('unavailable', gauge)
        self.assertNotIn('stroke-dasharray=', gauge)
        self.assertNotIn('0<small>%', gauge)

    def test_real_metrics_drive_gauge_progress_classes_and_timezone(self):
        page = render.html(report(), "America/Los_Angeles")
        self.assertIn('stroke-dasharray="50.0 100"', page)
        self.assertIn('PC + NUC combined', page)
        self.assertIn('+1 today', page)
        self.assertIn('Feature 2', page)
        self.assertIn('Test & CI 1', page)
        self.assertIn('goal 95%', page)
        self.assertIn('data:font/woff2;base64,', page)
        local = fixtures.NOW.astimezone(render.ZoneInfo("America/Los_Angeles"))
        self.assertIn(local.strftime("%H:%M %Z"), page)
        self.assertNotIn('INLINE_BASE64', page)
        self.assertNotIn('overflow:hidden;padding', page)

    def test_notes_are_validated_escaped_and_do_not_override_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'notes.json'
            path.write_text(json.dumps({"outcomes": {"merged": 100}}))
            with self.assertRaisesRegex(ValueError, 'only blockers'):
                read_notes(path)
            path.write_text(json.dumps({"notes": ['<script>bad()</script>'],
                                        "blockers": [{"label": 'Publish package', "action": 'Set publisher'}] * 7}))
            page = render.html(report(), notes=read_notes(path))
            self.assertIn('&lt;script&gt;bad()&lt;/script&gt;', page)
            self.assertNotIn('<script>bad()', page)
            self.assertEqual(page.count('<b>Publish package</b>'), 5)
            self.assertIn('+2 more', page)
            path = Path(temporary) / 'notes.md'
            path.write_text('An executor observation.\n\nAnother paragraph.')
            self.assertEqual(read_notes(path)['notes'], ['An executor observation.', 'Another paragraph.'])

    def test_missing_chromium_cli_fails_clearly(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'report.json'
            path.write_text(json.dumps(report()))
            result = subprocess.run([sys.executable, str(ROOT / 'packages/newsletter/render.py'), str(path),
                                     str(Path(temporary) / 'out.pdf')], env={**os.environ, 'PATH': temporary},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Chromium is required', result.stderr)
            self.assertFalse((Path(temporary) / 'out.pdf').exists())

    def test_rejects_multi_page_chromium_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'out.pdf'
            def fake_run(args, **kwargs):
                if '--dump-dom' in args:
                    return subprocess.CompletedProcess(args, 0, '<body data-pages-fit="true">', '')
                target = Path(next(a.split('=', 1)[1] for a in args if a.startswith('--print-to-pdf=')))
                target.write_bytes(b'%PDF-1.4\n/Type /Page\n/Type /Page\n%%EOF')
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(render, 'find_chromium', return_value='chromium'), patch.object(render.subprocess, 'run', fake_run):
                with self.assertRaisesRegex(RuntimeError, 'produced 2'):
                    render.compile_report(report(), output)
            self.assertFalse(output.exists())

    def test_preprocess_retains_exact_yesterday_and_editorial(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            now = fixtures.NOW
            old = root / 'newsletter/snapshots' / (now - timedelta(days=1)).date().isoformat()
            old.parent.mkdir(parents=True)
            old.with_suffix('.json').write_text(json.dumps(fixtures.snapshot(-24)))
            with patch.object(newsletter, 'collect', return_value=fixtures.snapshot()) as collect:
                result = newsletter.preprocess('owner/repo', root, now, ['second'], {'notes': ['Observed result']})
            self.assertEqual(result, root / 'newsletter' / now.date().isoformat() / 'report.json')
            self.assertEqual(json.loads(result.read_text())['editorial']['notes'], ['Observed result'])
            self.assertEqual(json.loads(result.read_text())['program']['delta']['done']['value'], 0)
            self.assertTrue(old.with_suffix('.json').exists())
            self.assertEqual(collect.call_args.kwargs['instances'], ['second'])

    def test_compile_notes_are_retained_in_the_report_for_omitted_items(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, notes = root / 'report.json', root / 'notes.md'
            data = report()
            data['editorial'] = {'blockers': [{'label': 'Publish', 'action': 'Configure'}]}
            source.write_text(json.dumps(data))
            notes.write_text('An observation retained even when omitted from the PDF.')
            def fake_render(report, output, zone):
                output.write_bytes(b'PDF')
                output.with_suffix('.html').write_text('HTML')
                return output
            with patch.object(sys, 'argv', ['newsletter.py', 'compile', str(source), '--notes', str(notes)]), \
                    patch.object(newsletter, 'compile_report', side_effect=fake_render) as compile_report:
                newsletter.main()
            stored = json.loads(source.read_text())
            self.assertEqual(stored['editorial']['notes'], [notes.read_text()])
            self.assertEqual(stored['editorial']['blockers'], data['editorial']['blockers'])
            self.assertEqual(compile_report.call_args.args[0], stored)

    def test_linked_action_reason_and_measure_result_render_as_prose(self):
        today = fixtures.snapshot()
        today['meta'] = [{'id': 'b', 'timestamp': fixtures.stamp(-3), 'bottleneck': 'Review queue'}]
        today['executor_actions'] = [{'id': 'a', 'bottleneck_id': 'b', 'at': fixtures.stamp(-2),
                                      'outcome': 'action', 'reason': 'Reduced agent cap'}]
        today['measures'] = [{'action_id': 'a', 'at': fixtures.stamp(-1), 'result': 'Queue cleared'}]
        page = render.html(compute(today))
        card = page.split('class="bns"')[1].split('</section>')[0]
        self.assertIn('Reduced agent cap', card)
        self.assertIn('Queue cleared', card)
        self.assertNotIn('action_id', card)
        self.assertNotIn('unavailable', card)

    def test_failed_rebuild_preserves_previous_report_html_and_pdf(self):
        for command in ('build', 'compile'):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory = root / 'newsletter' / datetime.now(timezone.utc).date().isoformat()
                directory.mkdir(parents=True)
                source = directory / 'report.json'
                source.write_text(json.dumps(report()))
                (directory / 'newsletter.html').write_text('Previous HTML')
                (directory / 'newsletter.pdf').write_bytes(b'Previous PDF')
                before = {p.name: p.read_bytes() for p in directory.iterdir()}
                notes = root / 'notes.md'
                notes.write_text('New notes which must not replace published content on failure.')
                args = (['newsletter.py', 'build', '--repo', 'owner/repo', '--state-dir', str(root)]
                        if command == 'build' else ['newsletter.py', 'compile', str(source)])
                args += ['--notes', str(notes)]
                with patch.object(sys, 'argv', args), \
                        patch.object(newsletter, 'collect', return_value=fixtures.snapshot()), \
                        patch.object(newsletter, 'compile_report', side_effect=RuntimeError('render failed')):
                    with self.assertRaises(SystemExit) as exit:
                        newsletter.main()
                self.assertEqual(exit.exception.code, 1)
                self.assertEqual({p.name: p.read_bytes() for p in directory.iterdir()}, before)

    def test_program_states_and_daily_work_are_disjoint(self):
        today = fixtures.snapshot()
        today['program']['tickets'] = [fixtures.ticket(1, 'closed', 'completed'),
            fixtures.ticket(2, lifecycle='running'), fixtures.ticket(3), fixtures.ticket(4, paused=True),
            fixtures.ticket(5, paused=True, mobile=True), fixtures.ticket(6, 'closed', 'not_planned')]
        data = compute(today)
        self.assertEqual({k: v['value'] for k, v in data['program']['states'].items()},
                         dict.fromkeys(('done', 'active', 'todo', 'paused', 'shelved', 'removed'), 1))
        self.assertEqual(data['program']['done_in_window']['value'], 1)
        self.assertEqual(data['program']['total']['value'], 5)

    @unittest.skipUnless(chromium_available(), 'Chromium is not installed; build PDF acceptance skipped')
    def test_build_command_without_notes_writes_all_three_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = ['newsletter.py', 'build', '--repo', 'owner/repo', '--state-dir', temporary]
            with patch.object(sys, 'argv', args), patch.object(newsletter, 'collect', return_value=fixtures.snapshot()):
                newsletter.main()
            directory = Path(temporary) / 'newsletter' / datetime.now(timezone.utc).date().isoformat()
            self.assertTrue((directory / 'report.json').is_file())
            self.assertIn('The Aiur Daily', (directory / 'newsletter.html').read_text())
            self.assertEqual(render.page_count(directory / 'newsletter.pdf'), 1)
            if shutil.which('pdftotext'):
                printed = subprocess.check_output(['pdftotext', str(directory / 'newsletter.pdf'), '-'], text=True)
                self.assertIn('unavailable', printed)
                self.assertIn('Allocation trend', printed)

    @unittest.skipUnless(chromium_available(), 'Chromium is not installed; real PDF acceptance skipped')
    def test_real_pdf_long_values_and_notes_fit_one_letter_page(self):
        data = report()
        lane = data['program']['lanes']['feature:mail']
        data['program']['lanes'] = {('Long lane title ' * 5) + str(i): copy.deepcopy(lane) for i in range(40)}
        notes = {'notes': ['Operator observed the actual deployment.'],
                 'bottlenecks': [{'problem': 'Long bottleneck ' * 80, 'action': 'A full action sentence. ' * 30,
                                  'result': 'No impact measured. ' * 30}] * 3,
                 'blockers': [{'label': 'Publish package', 'action': 'Configure publisher'}],
                 'shipped': [{'icon': 'rocket', 'label': 'Deployment observed'}]}
        with tempfile.TemporaryDirectory() as temporary:
            path = render.compile_report(data, Path(temporary) / 'newsletter.pdf', notes=notes)
            self.assertEqual(render.page_count(path), 1)
            # Independent parser checks dimensions/page count and extracts actual printed notes.
            if shutil.which('pdfinfo'):
                info = subprocess.check_output(['pdfinfo', str(path)], text=True)
                self.assertRegex(info, r'Pages:\s+1\b')
                self.assertRegex(info, r'Page size:\s+612 x 792 pts')
            if shutil.which('pdftotext'):
                printed = subprocess.check_output(['pdftotext', str(path), '-'], text=True)
                self.assertIn('Operator observed the actual deployment.', printed)
                self.assertIn('lower priority items omitted', printed)
                self.assertNotIn('Long bottleneck', printed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
