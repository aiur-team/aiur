"""Adversarial tests for the receipt-bound production live graph verifier."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
SKILL_PUBLICATION = Path(__file__).resolve().parents[4] / ".claude/skills/aiur-build/scripts/publication"
sys.path.insert(0, str(SKILL_PUBLICATION))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from publication_comment import (  # noqa: E402
    render_pending_comment,
    render_successful_comment,
)
from publication_common import Report  # noqa: E402
from publication_live_graph import (  # noqa: E402
    LiveGraphError,
    QueryBudget,
    _capture_snapshot,
    _expected_graph,
    _github_json,
    _github_pages,
    verify_live_graph,
)
from publication_materialized_fixture import materialized_pack  # noqa: E402
from publication_receipt_authority import ReceiptAuthority  # noqa: E402


RECEIPT = "b" * 40


class LiveGraphVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        build, publication = materialized_pack()
        self.authority = ReceiptAuthority(
            repository="example/repo",
            root_id="example/repo:build-order-dashboard",
            plan_version=1,
            approved_commit=publication["approved_planning_commit"],
            root_issue_url=build["github_root"]["url"],
            root_comment_url=publication["github_reconciliation"][
                "root_reconciliation_comment_matches"
            ][0]["url"],
            trusted_repository_ref="refs/heads/build-order-research",
            receipt_manifests={
                "build-order.json": build,
                "publication.json": publication,
            },
        )
        self.expected = _expected_graph(self.authority)
        receipt_url = f"https://github.com/example/repo/commit/{RECEIPT}"
        self.pending_body = render_pending_comment(
            self.authority.root_id, 1, self.authority.approved_commit,
            self.authority.repository,
        )
        self.successful_body = render_successful_comment(
            self.authority.root_id, 1, self.authority.approved_commit,
            self.authority.repository, RECEIPT, receipt_url,
        )
        self.successful_url = self.expected.comment_url.rsplit("-", 1)[0] + "-100"
        self.expected_comment_bodies = {
            "pending": self.pending_body,
            "successful": self.successful_body,
        }
        self.snapshot = self._clean_snapshot()

    def _clean_snapshot(self):
        issues = {}
        for logical_id, item in self.expected.issues.items():
            issues[logical_id] = {
                "mapping": tuple(
                    (key, item.mapping[key]) for key in sorted(item.mapping)
                ),
                "title": item.title,
                "body_sha256": item.body_sha256,
                "labels": item.labels,
                "state": "OPEN",
                "locked": False,
                "updated_at": "2026-07-13T00:00:00Z",
                "parent": item.parent,
                "subissues": item.subissues,
                "blocked_by": item.blocked_by,
            }
        digest = hashlib.sha256(self.pending_body.encode("utf-8")).hexdigest()
        return {
            "issues": issues,
            "marker_matches": copy.deepcopy(self.expected.marker_matches),
            "comments": {
                "pending": {
                    "url": self.expected.comment_url,
                    "body": self.pending_body,
                    "body_sha256": digest,
                },
                "reconciliation": tuple(sorted((
                    (self.expected.comment_url, self.pending_body, 1),
                    (self.successful_url, self.successful_body, 1),
                ))),
            },
        }

    def verify(self, first=None, second=None) -> Report:
        first = self.snapshot if first is None else first
        second = first if second is None else second
        report = Report()
        with patch(
            "publication_live_graph._capture_snapshot",
            side_effect=[copy.deepcopy(first), copy.deepcopy(second)],
        ) as capture:
            verify_live_graph(
                self.authority, RECEIPT, self.expected_comment_bodies, report,
            )
        self.assertEqual(2, capture.call_count)
        self.assertIs(
            capture.call_args_list[0].args[2],
            capture.call_args_list[1].args[2],
        )
        return report

    def test_two_identical_complete_snapshots_are_clean(self) -> None:
        self.assertEqual([], self.verify().errors)

    def test_closed_or_locked_issue_fails(self) -> None:
        for field, value in (("state", "CLOSED"), ("locked", True)):
            with self.subTest(field=field):
                snapshot = copy.deepcopy(self.snapshot)
                snapshot["issues"]["SKILL-DELIVERY-001"][field] = value
                joined = "\n".join(self.verify(snapshot).errors)
                self.assertIn(f"SKILL-DELIVERY-001.{field}", joined)

    def test_title_body_and_full_label_drift_fail(self) -> None:
        mutations = (
            ("title", "stale title"),
            ("body_sha256", "0" * 64),
            ("labels", ("human:todo", "unexpected")),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                snapshot = copy.deepcopy(self.snapshot)
                snapshot["issues"]["SKILL-DELIVERY-001"][field] = value
                self.assertIn(
                    f"SKILL-DELIVERY-001.{field}",
                    "\n".join(self.verify(snapshot).errors),
                )

    def test_missing_or_extra_root_member_fails(self) -> None:
        root_id = self.authority.root_id
        for members in (
            self.snapshot["issues"][root_id]["subissues"][:-1],
            (*self.snapshot["issues"][root_id]["subissues"], "SKILL-DELIVERY-001"),
        ):
            with self.subTest(members=len(members)):
                snapshot = copy.deepcopy(self.snapshot)
                snapshot["issues"][root_id]["subissues"] = members
                self.assertIn(
                    f"{root_id}.subissues",
                    "\n".join(self.verify(snapshot).errors),
                )

    def test_parent_and_nested_subissue_drift_fail(self) -> None:
        root_id = self.authority.root_id
        root_parent = copy.deepcopy(self.snapshot)
        root_parent["issues"][root_id]["parent"] = "DASH-001"
        self.assertIn(f"{root_id}.parent", "\n".join(self.verify(root_parent).errors))

        nested = copy.deepcopy(self.snapshot)
        nested["issues"]["DASH-001"]["subissues"] = ("DASH-002",)
        self.assertIn(
            "DASH-001.subissues", "\n".join(self.verify(nested).errors)
        )

    def test_missing_reversed_or_extra_blocker_fails(self) -> None:
        source = next(
            logical_id for logical_id, item in self.expected.issues.items()
            if item.blocked_by
        )
        blocker = self.expected.issues[source].blocked_by[0]
        cases = []
        missing = copy.deepcopy(self.snapshot)
        missing["issues"][source]["blocked_by"] = missing["issues"][source][
            "blocked_by"
        ][1:]
        cases.append(missing)
        reversed_edge = copy.deepcopy(self.snapshot)
        reversed_edge["issues"][source]["blocked_by"] = tuple(
            value for value in reversed_edge["issues"][source]["blocked_by"]
            if value != blocker
        )
        reversed_edge["issues"][blocker]["blocked_by"] = tuple(sorted((
            *reversed_edge["issues"][blocker]["blocked_by"], source,
        )))
        cases.append(reversed_edge)
        extra = copy.deepcopy(self.snapshot)
        extra["issues"][source]["blocked_by"] = tuple(sorted((
            *extra["issues"][source]["blocked_by"], "DASH-025",
        )))
        cases.append(extra)
        for index, snapshot in enumerate(cases):
            with self.subTest(case=index):
                self.assertIn("blocked_by", "\n".join(self.verify(snapshot).errors))

    def test_duplicate_marker_match_including_closed_scan_fails(self) -> None:
        snapshot = copy.deepcopy(self.snapshot)
        identity = "DASH-001"
        snapshot["marker_matches"][identity] = (
            *snapshot["marker_matches"][identity],
            snapshot["marker_matches"][identity][0],
        )
        self.assertIn(
            "all-state marker scan", "\n".join(self.verify(snapshot).errors)
        )

    def test_forged_mapping_and_comment_fail(self) -> None:
        mapping = copy.deepcopy(self.snapshot)
        raw = dict(mapping["issues"]["DASH-001"]["mapping"])
        raw["node_id"] = "FORGED"
        mapping["issues"]["DASH-001"]["mapping"] = tuple(sorted(raw.items()))
        self.assertIn("DASH-001.mapping", "\n".join(self.verify(mapping).errors))

        comment = copy.deepcopy(self.snapshot)
        comment["comments"]["pending"]["body"] = "stale pending comment"
        self.assertIn(
            "reconciliation evidence", "\n".join(self.verify(comment).errors)
        )

    def test_malformed_duplicate_and_conflicting_success_evidence_fail(self) -> None:
        cases = []
        malformed = copy.deepcopy(self.snapshot)
        malformed["comments"]["reconciliation"] = (
            *malformed["comments"]["reconciliation"],
            (self.successful_url.rsplit("-", 1)[0] + "-101", "malformed", 1),
        )
        cases.append(malformed)
        duplicate = copy.deepcopy(self.snapshot)
        duplicate["comments"]["reconciliation"] = (
            *duplicate["comments"]["reconciliation"],
            (
                self.successful_url.rsplit("-", 1)[0] + "-101",
                self.successful_body,
                1,
            ),
        )
        cases.append(duplicate)
        conflicting = copy.deepcopy(self.snapshot)
        entries = list(conflicting["comments"]["reconciliation"])
        successful_index = next(
            index for index, entry in enumerate(entries)
            if entry[0] == self.successful_url
        )
        entry = entries[successful_index]
        entries[successful_index] = (
            entry[0], entry[1].replace(RECEIPT, "c" * 40), 1,
        )
        conflicting["comments"]["reconciliation"] = tuple(entries)
        cases.append(conflicting)
        for index, snapshot in enumerate(cases):
            with self.subTest(case=index):
                self.assertIn(
                    "successful reconciliation", "\n".join(self.verify(snapshot).errors)
                )

    def test_pending_verifier_requires_only_immutable_pending_comment(self) -> None:
        pending = copy.deepcopy(self.snapshot)
        pending["comments"]["reconciliation"] = (
            (self.expected.comment_url, self.pending_body, 1),
        )
        self.expected_comment_bodies = {"pending": self.pending_body}
        self.assertEqual([], self.verify(pending).errors)

    def test_mid_query_change_fails_even_when_each_snapshot_is_well_formed(self) -> None:
        second = copy.deepcopy(self.snapshot)
        second["issues"]["DASH-001"]["updated_at"] = "2026-07-13T00:00:01Z"
        self.assertIn(
            "changed between two complete bounded reads",
            "\n".join(self.verify(self.snapshot, second).errors),
        )

    def _raw_issue_rows(self) -> list[dict]:
        rows = []
        for logical_id, item in self.expected.issues.items():
            marker = json.dumps({"logical_id": logical_id}, separators=(",", ":"))
            rows.append({
                "number": item.mapping["number"],
                "node_id": item.mapping["node_id"],
                "html_url": item.mapping["url"],
                "title": item.title,
                "body": f"<!-- aiur-planning-issue\n{marker}\n-->",
                "labels": list(item.labels),
                "state": "open",
                "locked": False,
                "updated_at": "2026-07-13T00:00:00Z",
            })
        return rows

    def test_pr_shaped_marker_collision_is_retained(self) -> None:
        rows = self._raw_issue_rows()
        marker = json.dumps({"logical_id": "DASH-001"}, separators=(",", ":"))
        rows.append({
            "number": 999_999,
            "node_id": "PR_NODE",
            "html_url": "https://github.com/example/repo/pull/999999",
            "title": "collision",
            "body": f"<!-- aiur-planning-issue\n{marker}\n-->",
            "pull_request": {},
        })

        def pages(endpoint: str, *, budget=None):
            if "state=all" in endpoint:
                return rows
            if "/comments?" in endpoint:
                return [
                    {"html_url": self.expected.comment_url, "body": self.pending_body},
                    {"html_url": self.successful_url, "body": self.successful_body},
                ]
            return []

        def single(endpoint: str, *, allow_404: bool = False, budget=None):
            if endpoint.endswith("/parent"):
                return None
            if "/issues/comments/" in endpoint:
                return {"html_url": self.expected.comment_url, "body": self.pending_body}
            raise AssertionError(endpoint)

        with patch("publication_live_graph._github_pages", side_effect=pages), patch(
            "publication_live_graph._github_json", side_effect=single,
        ):
            snapshot = _capture_snapshot(
                self.authority, self.expected,
            )
        self.assertEqual(2, len(snapshot["marker_matches"]["DASH-001"]))
        self.assertIn(
            ("url", "https://github.com/example/repo/pull/999999"),
            snapshot["marker_matches"]["DASH-001"][1],
        )

    def test_mapped_pull_request_is_rejected(self) -> None:
        rows = self._raw_issue_rows()
        mapped_number = self.expected.issues["DASH-001"].mapping["number"]
        row = next(item for item in rows if item["number"] == mapped_number)
        row["html_url"] = f"https://github.com/example/repo/pull/{mapped_number}"
        row["pull_request"] = {}
        with patch("publication_live_graph._github_pages", return_value=rows):
            with self.assertRaisesRegex(LiveGraphError, "resolves to a pull request"):
                _capture_snapshot(self.authority, self.expected)

    def test_malformed_issue_page_entries_are_not_filtered(self) -> None:
        with patch("publication_live_graph._github_pages", return_value=[None]):
            with self.assertRaisesRegex(LiveGraphError, "non-object entry"):
                _capture_snapshot(self.authority, self.expected)

    def test_paginated_reads_enforce_page_and_total_bounds(self) -> None:
        with patch("publication_live_graph._github_json", return_value=[{}] * 101):
            with self.assertRaisesRegex(LiveGraphError, "100 items per page"):
                _github_pages("repos/example/repo/issues?per_page=100")

        item_budget = QueryBudget(requests_remaining=10, items_remaining=1)
        with patch("publication_live_graph._github_json", return_value=[{}]):
            self.assertEqual([{}], _github_pages("first", budget=item_budget))
            with self.assertRaisesRegex(LiveGraphError, "total item bound"):
                _github_pages("second", budget=item_budget)
        with patch("publication_live_graph._github_json", return_value=[{}] * 100):
            with self.assertRaisesRegex(LiveGraphError, "exceeded 100 pages"):
                _github_pages("repos/example/repo/issues?per_page=100")

    def test_github_reads_pin_host_and_timeout(self) -> None:
        completed = subprocess.CompletedProcess([], 0, "{}", "")
        with patch("publication_live_graph.subprocess.run", return_value=completed) as run:
            self.assertEqual({}, _github_json("repos/example/repo/issues/1"))
        argv = run.call_args.args[0]
        self.assertEqual("github.com", argv[argv.index("--hostname") + 1])
        self.assertEqual(30, run.call_args.kwargs["timeout"])

        request_budget = QueryBudget(requests_remaining=1, items_remaining=10)
        with patch("publication_live_graph.subprocess.run", return_value=completed):
            self.assertEqual({}, _github_json("first", budget=request_budget))
            with self.assertRaisesRegex(LiveGraphError, "total request bound"):
                _github_json("second", budget=request_budget)

        with patch(
            "publication_live_graph.subprocess.run",
            side_effect=subprocess.TimeoutExpired(["gh", "api"], 30),
        ):
            with self.assertRaisesRegex(LiveGraphError, "exceeded 30 seconds"):
                _github_json("repos/example/repo/issues/1")


if __name__ == "__main__":
    unittest.main()
