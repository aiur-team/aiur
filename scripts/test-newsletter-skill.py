#!/usr/bin/env python3
"""Exercise the Executor skill's notes artifact through the real package contract."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/newsletter"))
from editorial import read_notes
from metrics import compute
from render import html

spec = importlib.util.spec_from_file_location("fixtures", ROOT / "scripts/test-newsletter-metrics.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
EXAMPLE = ROOT / ".claude/skills/aiur-newsletter/assets/notes.example.json"


class SkillNotesTest(unittest.TestCase):
    def test_skill_notes_add_context_without_replacing_metrics(self):
        notes = read_notes(EXAMPLE)
        report = compute(fixtures.snapshot())
        original = copy.deepcopy(report)
        page = html(report, notes=notes)
        self.assertEqual(report, original)
        self.assertEqual(notes["blockers"], [{"label": "Package publication", "action": "Enable trusted publishing"}])
        for field in ("label", "action"):
            self.assertIn(notes["blockers"][0][field], page)
        self.assertIn(notes["notes"][0], page)
        self.assertIn(notes["bottlenecks"][0]["result"], page)

    def test_confirmed_empty_and_unavailable_blockers_are_distinct(self):
        report = compute(fixtures.snapshot())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "notes.json"
            path.write_text(json.dumps({"blockers": []}))
            page = html(report, notes=read_notes(path))
        section = page.split('<section class="byou">')[1].split('</section>')[0]
        self.assertIn('class="count">0</span>', section)
        self.assertIn("Nothing blocked on you today", section)
        unknown = html(report).split('<section class="byou">')[1].split('</section>')[0]
        self.assertIn('class="count">?</span>', unknown)
        self.assertIn("unavailable", unknown)
        self.assertNotIn("Nothing blocked on you today", unknown)


if __name__ == "__main__":
    unittest.main(verbosity=2)
