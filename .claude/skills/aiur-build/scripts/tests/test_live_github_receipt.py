"""Fresh live-GitHub verification for immutable publication receipts."""

from __future__ import annotations

import copy
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

from helpers import SCRIPT_DIR  # installs the scripts import path
from validate_build_order import _validate_receipt
from validation_common import Report
from validation_github_live import (
    GhApiReader,
    GitHubReader,
    LiveGitHubError,
    validate_live_github_receipt,
)
from validation_github_rendering import inspect_issue_body, render_ticket_body


REPOSITORY = "example/repo"
ROOT_ID = "example/repo:operator-dashboard"
APPROVED = "b" * 40


def mapping(number: int, node_id: str) -> dict[str, Any]:
    return {
        "repository": REPOSITORY,
        "number": number,
        "node_id": node_id,
        "url": f"https://github.com/{REPOSITORY}/issues/{number}",
    }


def raw_mapping(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "number": value["number"],
        "node_id": value["node_id"],
        "html_url": value["url"],
    }


def fixture() -> tuple[dict[str, Any], dict[str, Any]]:
    mappings = {
        ROOT_ID: mapping(100, "ROOT"),
        "BO-001": mapping(101, "ONE"),
        "BO-002": mapping(102, "TWO"),
    }
    labels = {
        ROOT_ID: ["build-order"],
        "BO-001": ["build-lane:platform", "complexity:3", "model:codex", "phase:1"],
        "BO-002": ["build-lane:integration", "complexity:2", "model:codex", "phase:2"],
    }
    bodies: dict[str, str] = {}
    evidence: dict[str, dict[str, Any]] = {}
    for logical_id in mappings:
        report = Report()
        body = render_ticket_body(
            f"# {logical_id}\n", REPOSITORY, logical_id, 1, APPROVED,
            report, f"fixture {logical_id}",
        )
        assert body is not None and not report.errors
        observed = inspect_issue_body(
            body, REPOSITORY, logical_id, 1, APPROVED,
            report, f"fixture {logical_id}",
        )
        assert observed is not None and not report.errors
        bodies[logical_id] = body
        evidence[logical_id] = observed
    issues = {
        logical_id: {
            **raw_mapping(issue_mapping),
            "id": 10_000 + issue_mapping["number"],
            "title": logical_id,
            "body": bodies[logical_id],
            "labels": [{"name": label} for label in labels[logical_id]],
            "state": "open",
            "locked": False,
        }
        for logical_id, issue_mapping in mappings.items()
    }
    data = {
        "repository": REPOSITORY,
        "plan_version": 1,
        "build_order_id": ROOT_ID,
        "github_root": mappings[ROOT_ID],
        "tickets": [
            {"id": "BO-001", "depends_on": [], "github": mappings["BO-001"]},
            {
                "id": "BO-002", "depends_on": ["BO-001"],
                "github": mappings["BO-002"],
            },
        ],
        "github_reconciliation": {
            "receipt_schema_version": 3,
            "approved_planning_commit": APPROVED,
            "member_ticket_ids": ["BO-001", "BO-002"],
            "dependency_edges": [
                {"ticket_id": "BO-002", "depends_on": "BO-001"}
            ],
            "observed_labels": copy.deepcopy(labels),
            "observed_issue_titles": {
                logical_id: logical_id for logical_id in mappings
            },
            "observed_issue_states": {
                logical_id: "OPEN" for logical_id in mappings
            },
            "observed_body_evidence": evidence,
            "marker_query_matches": {
                logical_id: [copy.deepcopy(value)]
                for logical_id, value in mappings.items()
            },
        },
    }
    snapshot = {
        "issues": issues,
        "members": [raw_mapping(mappings["BO-001"]), raw_mapping(mappings["BO-002"])],
        "nested": {ROOT_ID: [], "BO-001": [], "BO-002": []},
        "parents": {
            ROOT_ID: None,
            "BO-001": raw_mapping(mappings[ROOT_ID]),
            "BO-002": raw_mapping(mappings[ROOT_ID]),
        },
        "blockers": {
            ROOT_ID: [],
            "BO-001": [],
            "BO-002": [raw_mapping(mappings["BO-001"])],
        },
    }
    return data, snapshot


class FakeReader(GitHubReader):
    def __init__(self, *snapshots: dict[str, Any]) -> None:
        self.snapshots = snapshots
        self.round = -1
        self.active: dict[str, Any] | None = None
        self.repository_reads = 0

    def repository_issues(self, repository: str) -> list[dict[str, Any]]:
        if repository != REPOSITORY:
            raise AssertionError(repository)
        self.round += 1
        self.repository_reads += 1
        self.active = self.snapshots[min(self.round, len(self.snapshots) - 1)]
        return copy.deepcopy(list(self.active["issues"].values()))

    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]:
        assert self.active is not None
        logical_id = {100: ROOT_ID, 101: "BO-001", 102: "BO-002"}.get(number)
        if repository != REPOSITORY:
            raise AssertionError((repository, number))
        if logical_id is None:
            return []
        return copy.deepcopy(
            self.active["members"] if logical_id == ROOT_ID
            else self.active["nested"][logical_id]
        )

    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]:
        assert self.active is not None
        logical_id = {100: ROOT_ID, 101: "BO-001", 102: "BO-002"}.get(number)
        if repository != REPOSITORY:
            raise AssertionError((repository, number))
        if logical_id is None:
            return []
        return copy.deepcopy(self.active["blockers"][logical_id])

    def parent(self, repository: str, number: int) -> dict[str, Any] | None:
        assert self.active is not None
        logical_id = {100: ROOT_ID, 101: "BO-001", 102: "BO-002"}.get(number)
        if repository != REPOSITORY or logical_id is None:
            return None
        return copy.deepcopy(self.active["parents"][logical_id])


def validate(data: dict[str, Any], reader: GitHubReader) -> Report:
    report = Report()
    validate_live_github_receipt(data, report, reader)
    return report


class LiveReceiptTests(unittest.TestCase):
    def test_two_identical_bounded_snapshots_pass(self) -> None:
        data, snapshot = fixture()
        reader = FakeReader(snapshot, copy.deepcopy(snapshot))
        self.assertEqual([], validate(data, reader).errors)
        self.assertEqual(2, reader.repository_reads)

    def test_receipt_mode_automatically_runs_live_gate_between_authority_checks(self) -> None:
        data, snapshot = fixture()
        reader = FakeReader(snapshot, copy.deepcopy(snapshot))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = root / "pack"
            pack.mkdir()
            path = pack / "build-order.json"
            path.write_text("{}", encoding="utf-8")
            validated = Report()
            with (
                patch(
                    "validate_build_order.materialize_receipt_pack",
                    return_value=True,
                ),
                patch(
                    "validate_build_order._validate_path",
                    return_value=(data, validated),
                ),
                patch(
                    "validate_build_order.validate_publication_commit_authority"
                ) as authority,
                patch("validate_build_order.GhApiReader", return_value=reader),
            ):
                report = _validate_receipt(
                    path, root, "pack/root.md", "c" * 40,
                )
        self.assertEqual([], report.errors)
        self.assertEqual(2, reader.repository_reads)
        self.assertEqual(2, authority.call_count)

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

    def test_duplicate_marker_match_fails_even_when_closed(self) -> None:
        data, snapshot = fixture()
        duplicate = copy.deepcopy(snapshot["issues"]["BO-001"])
        duplicate.update(
            number=999,
            node_id="DUPLICATE",
            html_url=f"https://github.com/{REPOSITORY}/issues/999",
            state="closed",
        )
        snapshot["issues"]["duplicate"] = duplicate
        self.assertIn(
            "marker query for BO-001 must return exactly its mapped issue",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_pull_request_marker_collision_fails(self) -> None:
        data, snapshot = fixture()
        pull = copy.deepcopy(snapshot["issues"]["BO-001"])
        pull.update(
            number=999,
            node_id="PULL",
            html_url=f"https://github.com/{REPOSITORY}/pull/999",
            pull_request={"url": "https://api.github.com/pulls/999"},
        )
        snapshot["issues"]["pull"] = pull
        self.assertIn(
            "appears on a pull request",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_unhashable_marker_identity_fails_without_crashing(self) -> None:
        data, snapshot = fixture()
        malformed = copy.deepcopy(snapshot["issues"]["BO-001"])
        malformed.update(
            number=999,
            node_id="MALFORMED",
            html_url=f"https://github.com/{REPOSITORY}/issues/999",
            body=malformed["body"].replace('"logical_id":"BO-001"', '"logical_id":[]'),
        )
        snapshot["issues"]["malformed"] = malformed
        self.assertIn(
            "planning marker has invalid typed values",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_parent_and_nested_subissue_drift_fail(self) -> None:
        data, snapshot = fixture()
        snapshot["parents"][ROOT_ID] = raw_mapping(data["tickets"][0]["github"])
        self.assertIn(
            f"parent for {ROOT_ID} must equal none",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )
        data, snapshot = fixture()
        snapshot["nested"]["BO-001"] = [raw_mapping(data["tickets"][1]["github"])]
        self.assertIn(
            "member BO-001 must not have subissues",
            "\n".join(validate(data, FakeReader(snapshot, snapshot)).errors),
        )

    def test_mid_query_snapshot_drift_fails(self) -> None:
        data, first = fixture()
        second = copy.deepcopy(first)
        second["issues"]["BO-001"]["title"] = "changed between reads"
        report = validate(data, FakeReader(first, second))
        self.assertIn(
            "live GitHub publication graph changed during bounded requery",
            report.errors,
        )

    def test_ordering_only_differences_are_canonicalized(self) -> None:
        data, first = fixture()
        second = copy.deepcopy(first)
        second["issues"] = dict(reversed(list(second["issues"].items())))
        second["members"].reverse()
        for issue in second["issues"].values():
            issue["labels"].reverse()
        self.assertEqual([], validate(data, FakeReader(first, second)).errors)


class GhApiReaderTests(unittest.TestCase):
    def result(self, payload: str) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(["gh"], 0, payload, "")

    def test_paged_queries_reject_malformed_items_and_overflow(self) -> None:
        reader = GhApiReader(Path("."))
        with patch("validation_github_live.subprocess.run", return_value=self.result('[[1]]')):
            with self.assertRaisesRegex(LiveGitHubError, "malformed item"):
                reader.repository_issues(REPOSITORY)
        with (
            patch("validation_github_live.MAX_ITEMS", 1),
            patch(
                "validation_github_live.subprocess.run",
                return_value=self.result('[[{},{}]]'),
            ),
        ):
            with self.assertRaisesRegex(LiveGitHubError, "item verification bound"):
                reader.repository_issues(REPOSITORY)

    def test_queries_pin_current_api_version(self) -> None:
        reader = GhApiReader(Path("."))
        with patch(
            "validation_github_live.subprocess.run", return_value=self.result('[[]]')
        ) as run:
            reader.repository_issues(REPOSITORY)
        arguments = run.call_args.args[0]
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", arguments)
        self.assertEqual(
            ["--hostname", "github.com"],
            arguments[arguments.index("--hostname"):arguments.index("--hostname") + 2],
        )


if __name__ == "__main__":
    unittest.main()
