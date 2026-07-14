"""Exact single- and multi-prefix Build Order compatibility."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from helpers import REFERENCES, ValidatorCase, example
from validation_build_order import validate_data


class TicketPrefixValidationTests(ValidatorCase):
    def test_ticket_prefix_starts_with_a_letter(self) -> None:
        data = example()
        data["ticket_prefix"] = "123"
        self.assert_error(data, "uppercase letters and digits")

    def test_multi_prefix_pack_is_entirely_clean(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            references = Path(directory) / "references"
            shutil.copytree(REFERENCES, references)
            data = json.loads(json.dumps(example()).replace("BO-001", "DASH-001"))
            data["ticket_prefix"] = ["BO", "DASH"]
            original = references / "example-tickets/BO-001-project-graph.md"
            renamed = references / "example-tickets/DASH-001-project-graph.md"
            original.rename(renamed)
            renamed.write_text(
                renamed.read_text(encoding="utf-8").replace("BO-001", "DASH-001"),
                encoding="utf-8",
            )
            report = validate_data(data, references)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

    def test_ticket_prefix_list_rejects_invalid_items(self) -> None:
        data = example()
        data["ticket_prefix"] = ["BO", "1x"]
        self.assert_error(data, "uppercase letters and digits")

    def test_ticket_prefix_list_rejects_empty(self) -> None:
        data = example()
        data["ticket_prefix"] = []
        self.assert_error(data, "uppercase letters and digits")


if __name__ == "__main__":
    unittest.main()
