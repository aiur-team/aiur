#!/usr/bin/env python3
"""Contract tests for quarantine-list selection."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run-quarantined-tests.py")
SPEC = importlib.util.spec_from_file_location("quarantined_tests", SCRIPT)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

FIXTURE = '''defmodule Aiur.FixtureTest do
  use ExUnit.Case

  describe "outer" do
    test "inside" do
    end
  end

  test "outside" do
  end

  test "unique exact name" do
  end
end

defmodule Aiur.OtherFixtureTest do
  use ExUnit.Case

  test "outside" do
  end
end
'''


class QuarantinedTestSelectionTest(unittest.TestCase):
    def test_synthetic_entries_resolve_exact_described_and_module_wide_tests(self):
        selected = self.select(
            ("Aiur.FixtureTest", "unique exact name"),
            ("Aiur.FixtureTest", "outer inside"),
            ("Aiur.OtherFixtureTest", "*"),
        )

        self.assertEqual(
            selected,
            ["test/fixture_test.exs:12", "test/fixture_test.exs:19", "test/fixture_test.exs:5"],
        )

    def test_selector_locations_are_unique(self):
        selected = RUNNER.selectors()
        self.assertTrue(selected)
        self.assertEqual(len(selected), len(set(selected)))

    def select(self, *listed):
        with tempfile.TemporaryDirectory() as root:
            tests = Path(root) / "test"
            tests.mkdir()
            (tests / "fixture_test.exs").write_text(FIXTURE)
            quarantine = Path(root) / "quarantine.txt"
            quarantine.write_text("".join(f"{module}\t{name}\t#1\t2026-12-31\n" for module, name in listed))
            return RUNNER.selectors(tests, RUNNER.entries(quarantine))

    def test_describe_entry_uses_the_full_exunit_name(self):
        self.assertEqual(self.select(("Aiur.FixtureTest", "outer inside")), ["test/fixture_test.exs:5"])

    def test_bare_name_of_a_describe_test_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Aiur.FixtureTest :: inside matches 0"):
            self.select(("Aiur.FixtureTest", "inside"))

    def test_stale_entry_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "gone matches 0"):
            self.select(("Aiur.FixtureTest", "gone"))
        with self.assertRaisesRegex(ValueError, "matches no test"):
            self.select(("Aiur.MissingTest", "*"))

    def test_name_shared_by_another_module_is_rejected(self):
        # ExUnit excludes by name alone, so this entry would also exclude Aiur.OtherFixtureTest.
        with self.assertRaisesRegex(ValueError, "matches 1 test\\(s\\) in its module and 2 suite-wide"):
            self.select(("Aiur.FixtureTest", "outside"))

    def test_module_wildcard_selects_every_test(self):
        self.assertEqual(self.select(("Aiur.FixtureTest", "*")), ["test/fixture_test.exs:12", "test/fixture_test.exs:5", "test/fixture_test.exs:9"])


if __name__ == "__main__":
    unittest.main()
