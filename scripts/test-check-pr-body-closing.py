#!/usr/bin/env python3
"""Closing-keyword safeguards for non-closing PR bodies."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pr_body', Path(__file__).with_name('check-pr-body.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ClosingReferenceTests(unittest.TestCase):
    def test_part_of_rejects_negated_closing_prose_for_the_declared_issue(self):
        self.assertFalse(gate.check_closing_references('Part of #5162\n\nIt does not close #5162'))

    def test_part_of_without_closing_prose_passes(self):
        self.assertTrue(gate.check_closing_references('Part of #5162\n\nThis is a partial change.'))

    def test_closes_declaration_passes_without_another_closing_reference(self):
        self.assertTrue(gate.check_closing_references('Closes #5162\n\nThis completes the issue.'))

    def test_refs_rejects_repository_issue_url_for_the_declared_issue(self):
        body = 'Refs #5162\n\nThis resolves https://github.com/aiur-team/aiur/issues/5162'
        self.assertFalse(gate.check_closing_references(body))

    def test_closes_warns_about_an_accidental_second_closure(self):
        with patch('builtins.print') as warning:
            self.assertTrue(gate.check_closing_references('Closes #5162\n\nFixes #92'))
        warning.assert_called_once()
        self.assertIn('line 3', warning.call_args.args[0])

    def test_qualified_reference_is_case_insensitive_and_accepts_colon(self):
        self.assertFalse(gate.check_closing_references('Refs #5162\n\nRESOLVED: aiur-team/aiur#5162'))

    def test_other_repository_url_is_not_mistaken_for_this_repo(self):
        body = 'Refs #5162\n\nResolves https://github.com/other/repo/issues/5162'
        self.assertTrue(gate.check_closing_references(body))

    def test_keyword_without_issue_reference_does_not_match(self):
        self.assertTrue(gate.check_closing_references('Part of #5162\n\nThis does not close anything.'))

    def test_failure_reports_the_offending_line(self):
        with patch('builtins.print') as error:
            self.assertFalse(gate.check_closing_references('Part of #5162\n\n\nFixes #5162'))
        self.assertIn('line 4', error.call_args.args[0])


if __name__ == '__main__':
    unittest.main()

