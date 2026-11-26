#!/usr/bin/env python3
"""Exercise the goal contract through the production schema validator."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('checker', ROOT / 'scripts/check-components.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
from components.public_fixtures import fixture_component


class ComponentGoalsTest(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads((ROOT / 'components.schema.json').read_text())
        self.component = fixture_component('example', [])

    def validate(self):
        checker.validate(self.component, self.schema['$defs']['component'], self.schema)

    def test_goal_required_for_non_planned(self):
        del self.component['goal']
        with self.assertRaisesRegex(checker.InvalidManifest, '/goal: required property'):
            self.validate()

    def test_goal_enum(self):
        for goal in ['run-agents', 'steer', 'notify', 'voice', 'hardware']:
            self.component['goal'] = goal
            self.validate()
        self.component['goal'] = 'unknown'
        with self.assertRaisesRegex(checker.InvalidManifest, '/goal: expected one of'):
            self.validate()

    # Future regression guard: planned components may still omit a goal.
    def test_planned_goal_optional(self):
        del self.component['goal']
        self.component.update(status='planned', added_by='MP-N1')
        self.validate()


if __name__ == '__main__':
    unittest.main()
