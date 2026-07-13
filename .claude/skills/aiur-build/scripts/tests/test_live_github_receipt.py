"""Core stable-snapshot and receipt-mode GitHub tests."""

import copy
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any
from unittest.mock import patch

from live_receipt_helpers import (
    FakeReader,
    REPOSITORY,
    fixture,
    mapping,
    raw_mapping,
    validate,
)
from validate_build_order import _validate_receipt
from validation_common import Report


class LiveReceiptTests(__import__("unittest").TestCase):
    def test_two_identical_bounded_snapshots_pass(self) -> None:
        data, snapshot = fixture()
        reader = FakeReader(snapshot, copy.deepcopy(snapshot))
        self.assertEqual([], validate(data, reader).errors)
        self.assertEqual(2, reader.repository_reads)

    def test_receipt_mode_extracts_real_pack_before_ordered_live_gate(self) -> None:
        data, snapshot = fixture()
        reader = FakeReader(snapshot, copy.deepcopy(snapshot))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = root / "pack"
            pack.mkdir()
            path = pack / "build-order.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "test@example.com"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Test"], check=True,
            )
            subprocess.run(["git", "-C", str(root), "add", "pack"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "commit", "-qm", "receipt"], check=True,
            )
            receipt_commit = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"], check=True,
                capture_output=True, text=True,
            ).stdout.strip()
            validated = Report()
            events: list[str] = []

            def authority_check(*_args: object, **_kwargs: object) -> object:
                events.append("authority")
                from validation_publication_authority import PublicationAuthority
                return PublicationAuthority(
                    "refs/heads/main", "pack/root.md", (REPOSITORY,), (), "agent",
                )

            def validate_path(*_args: object, **_kwargs: object) -> object:
                events.append("pack")
                return data, validated

            class OrderedReader(FakeReader):
                def repository_issues(self, repository: str) -> list[dict[str, Any]]:
                    if self.repository_reads == 0:
                        events.append("live")
                    return super().repository_issues(repository)

            reader = OrderedReader(snapshot, copy.deepcopy(snapshot))
            with (
                patch(
                    "validate_build_order._validate_path",
                    side_effect=validate_path,
                ),
                patch(
                    "validate_build_order.validate_publication_commit_authority",
                    side_effect=authority_check,
                ),
                patch("validate_build_order.GhApiReader", return_value=reader),
            ):
                report = _validate_receipt(
                    path, root, "pack/root.md", receipt_commit,
                )
        self.assertEqual([], report.errors)
        self.assertEqual(2, reader.repository_reads)
        self.assertEqual(["authority", "pack", "live", "authority"], events)

    def test_forged_mapping_receipt_fails(self) -> None:
        data, snapshot = fixture()
        forged = mapping(999, "FORGED")
        data["tickets"][0]["github"] = forged
        data["github_reconciliation"]["marker_query_matches"]["BO-001"] = [forged]
        joined = "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors)
        self.assertIn("live GitHub issue is missing for BO-001", joined)

    def test_closed_issue_fails_without_reopening(self) -> None:
        data, snapshot = fixture()
        snapshot["issues"]["BO-001"]["state"] = "closed"
        joined = "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors)
        self.assertIn("BO-001 must be OPEN at publication", joined)

    def test_locked_issue_fails(self) -> None:
        data, snapshot = fixture()
        snapshot["issues"]["BO-001"]["locked"] = True
        joined = "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors)
        self.assertIn("BO-001 must be unlocked at publication", joined)

    def test_title_body_and_label_drift_fail(self) -> None:
        mutations = (
            ("title", lambda issue: issue.__setitem__("title", "renamed")),
            ("body", lambda issue: issue.__setitem__("body", issue["body"] + "drift")),
            ("labels", lambda issue: issue["labels"].append({"name": "extra"})),
        )
        for name, mutate in mutations:
            with self.subTest(name=name):
                data, snapshot = fixture()
                mutate(snapshot["issues"]["BO-001"])
                joined = "\n".join(
                    validate(data, FakeReader(snapshot, snapshot)).errors
                )
                self.assertIn(f"live GitHub {name} drifted for BO-001", joined)

    def test_missing_member_and_edge_fail(self) -> None:
        data, snapshot = fixture()
        snapshot["members"].pop()
        self.assertIn(
            "root membership must exactly match",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_relationships_require_exact_node_identity(self) -> None:
        data, snapshot = fixture()
        snapshot["members"][0]["node_id"] = "FORGED-NODE"
        self.assertIn(
            "subissues contains unexpected issue",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_reversed_dependency_direction_fails(self) -> None:
        data, snapshot = fixture()
        snapshot["blockers"]["BO-002"] = []
        snapshot["blockers"]["BO-001"] = [
            raw_mapping(data["tickets"][1]["github"])
        ]
        self.assertIn(
            "dependency edges drifted",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )
        data, snapshot = fixture()
        snapshot["blockers"]["BO-002"] = []
        self.assertIn(
            "dependency edges drifted",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )


if __name__ == "__main__":
    import unittest

    unittest.main()
