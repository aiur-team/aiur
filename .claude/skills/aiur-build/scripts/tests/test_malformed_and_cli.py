"""Broad malformed-type sweep and command-line behavior tests."""

from __future__ import annotations

import copy
import subprocess
import tempfile
from pathlib import Path

from helpers import EXAMPLE, REFERENCES, SCRIPT_DIR, ValidatorCase, example, report_for


BAD_VALUES = (None, True, 0, {}, [], "wrong")


class MalformedSweepTests(ValidatorCase):
    def test_every_top_and_ticket_field_handles_wrong_types(self) -> None:
        baseline = example()
        for key in baseline:
            for bad in BAD_VALUES:
                with self.subTest(level="top", key=key, bad=repr(bad)):
                    data = copy.deepcopy(baseline)
                    data[key] = bad
                    report_for(data)
        for key in baseline["tickets"][0]:
            for bad in BAD_VALUES:
                with self.subTest(level="ticket", key=key, bad=repr(bad)):
                    data = copy.deepcopy(baseline)
                    data["tickets"][0][key] = bad
                    report_for(data)

    def test_nested_objects_handle_wrong_types(self) -> None:
        baseline = example()
        paths = (
            ("requirement", baseline["requirements"][0]),
            ("boundary", baseline["feature_boundary"]),
            ("labels", baseline["label_projection"]),
            ("gate", baseline["external_gates"][0]),
            ("acceptance", baseline["tickets"][0]["acceptance"]),
        )
        for name, source in paths:
            for key in source:
                for bad in BAD_VALUES:
                    with self.subTest(level=name, key=key, bad=repr(bad)):
                        data = copy.deepcopy(baseline)
                        target = {
                            "requirement": data["requirements"][0],
                            "boundary": data["feature_boundary"],
                            "labels": data["label_projection"],
                            "gate": data["external_gates"][0],
                            "acceptance": data["tickets"][0]["acceptance"],
                        }[name]
                        target[key] = bad
                        report_for(data)


class CliTests(ValidatorCase):
    def run_cli(self, path: Path):
        return subprocess.run(
            ["python3", str(SCRIPT_DIR / "validate_build_order.py"), str(path)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_cli_accepts_example(self) -> None:
        result = self.run_cli(EXAMPLE)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("0 error(s), 0 warning(s)", result.stdout)

    def test_cli_reports_invalid_json_and_root_type(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            invalid = Path(directory) / "invalid.json"
            invalid.write_text("{", encoding="utf-8")
            result = self.run_cli(invalid)
            self.assertEqual(1, result.returncode)
            self.assertIn("cannot read valid JSON", result.stdout)
            invalid.write_text("[]", encoding="utf-8")
            result = self.run_cli(invalid)
            self.assertEqual(1, result.returncode)
            self.assertIn("top level must be", result.stdout)


if __name__ == "__main__":
    import unittest

    unittest.main()
