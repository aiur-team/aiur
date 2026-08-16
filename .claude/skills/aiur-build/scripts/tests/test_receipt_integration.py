"""Successful receipt-mode integration through the real canonical validator."""

from __future__ import annotations

import copy
import json
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from helpers import REFERENCES, example
from live_receipt_helpers import FakeReader, REPOSITORY, ROOT_ID, mapping, raw_mapping
from validate_build_order import _validate_receipt
from validation_common import Report
from validation_github_approved import render_approved_build_order
from validation_github_rendering import authority_preamble, inspect_issue_body


class ReceiptModeIntegrationTests(unittest.TestCase):
    def test_real_canonical_receipt_passes_between_authority_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = root / "pack"
            shutil.copytree(REFERENCES, pack)
            (pack / "build-order.json").write_text(
                json.dumps(example()), encoding="utf-8",
            )
            root_template = self.root_template()
            (pack / "root.md").write_text(root_template, encoding="utf-8")
            (pack / "publication.json").write_text(json.dumps({
                "trusted_repository_ref": "refs/heads/main",
                "root_document": "pack/root.md",
                "mutation_repositories": [REPOSITORY],
                "reference_only_issue_urls": [],
                "tracker_lifecycle_label_prefix": "agent",
            }) + "\n", encoding="utf-8")
            self.git(root, "init", "-q")
            self.git(root, "config", "user.email", "test@example.com")
            self.git(root, "config", "user.name", "Test")
            self.git(root, "remote", "add", "origin", f"git@github.com:{REPOSITORY}.git")
            self.git(root, "add", "pack")
            self.git(root, "commit", "-qm", "approved")
            approved = self.output(root, "rev-parse", "HEAD")
            (pack / "root.md").write_text(
                root_template.replace("<APPROVED_SHA>", approved), encoding="utf-8",
            )
            data, snapshot = self.materialized(root, pack, approved, root_template)
            (pack / "build-order.json").write_text(json.dumps(data), encoding="utf-8")
            self.git(root, "add", "pack")
            self.git(root, "commit", "-qm", "receipt")
            receipt = self.output(root, "rev-parse", "HEAD")
            self.git(root, "branch", "main", receipt)
            reader = FakeReader(snapshot, copy.deepcopy(snapshot))
            events: list[str] = []
            read_snapshot = reader.repository_issues

            def authority_target(*_args: object, **_kwargs: object) -> str:
                events.append("authority")
                return receipt

            def live_snapshot(repository: str) -> list[dict]:
                events.append("live")
                return read_snapshot(repository)

            with (
                patch(
                    "validation_git_authority._load_github_branch_target",
                    side_effect=authority_target,
                ),
                patch("validation_git_authority._github_compare_proves_ancestor", return_value=True),
                patch("validation_git_authority._clean_clone_proves_ancestor", return_value=True),
                patch("validate_build_order.GhApiReader", return_value=reader),
                patch.object(
                    reader, "repository_issues", side_effect=live_snapshot,
                ),
            ):
                report = _validate_receipt(
                    pack / "build-order.json", root, "pack/root.md", receipt,
                )
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)
        self.assertEqual(2, reader.repository_reads)
        self.assertEqual(
            [
                "authority", "authority", "live", "live",
                "authority", "authority",
            ],
            events,
        )

    def materialized(
        self, root: Path, pack: Path, approved: str, root_template: str,
    ) -> tuple[dict, dict]:
        data = example()
        mappings = {ROOT_ID: mapping(100, "ROOT"), "BO-001": mapping(101, "ONE"), "BO-002": mapping(102, "TWO")}
        data["github_root"] = mappings[ROOT_ID]
        for ticket in data["tickets"]:
            ticket["github"] = mappings[ticket["id"]]
        render_report = Report()
        expectations = render_approved_build_order(
            root, approved, "pack/build-order.json", "pack/root.md", data, render_report,
        )
        assert expectations is not None and not render_report.errors, render_report.errors
        labels = self.labels()
        bodies = {ROOT_ID: root_template.replace("<APPROVED_SHA>", approved)}
        for ticket in data["tickets"]:
            source = (pack / ticket["document"]).read_text(encoding="utf-8")
            bodies[ticket["id"]] = authority_preamble(
                REPOSITORY, ticket["id"], 1, approved,
            ) + source
        evidence = {}
        for logical_id, body in bodies.items():
            checked = Report()
            evidence[logical_id] = inspect_issue_body(
                body, REPOSITORY, logical_id, 1, approved, checked, logical_id,
            )
            assert evidence[logical_id] is not None and not checked.errors
        data["github_reconciliation"] = {
            "receipt_schema_version": 3,
            "checked_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "approved_planning_commit": approved,
            "root_node_id": "ROOT",
            "member_ticket_ids": ["BO-001", "BO-002"],
            "dependency_edges": [{"ticket_id": "BO-002", "depends_on": "BO-001"}],
            "projected_labels": copy.deepcopy(labels),
            "observed_labels": copy.deepcopy(labels),
            "expected_issue_titles": expectations.titles,
            "observed_issue_titles": expectations.titles,
            "observed_issue_states": {logical_id: "OPEN" for logical_id in mappings},
            "observed_body_evidence": evidence,
            "marker_query_matches": {logical_id: [value] for logical_id, value in mappings.items()},
        }
        issues = {
            logical_id: {
                **raw_mapping(issue), "id": 10_000 + issue["number"],
                "title": expectations.titles[logical_id], "body": bodies[logical_id],
                "labels": [{"name": label} for label in labels[logical_id]],
                "state": "open", "locked": False,
            }
            for logical_id, issue in mappings.items()
        }
        snapshot = {
            "issues": issues,
            "members": [raw_mapping(mappings["BO-001"]), raw_mapping(mappings["BO-002"])],
            "nested": {ROOT_ID: [], "BO-001": [], "BO-002": []},
            "parents": {ROOT_ID: None, "BO-001": raw_mapping(mappings[ROOT_ID]), "BO-002": raw_mapping(mappings[ROOT_ID])},
            "blockers": {ROOT_ID: [], "BO-001": [], "BO-002": [raw_mapping(mappings["BO-001"])]},
        }
        return data, snapshot

    @staticmethod
    def labels() -> dict[str, list[str]]:
        return {
            ROOT_ID: ["build-order"],
            "BO-001": ["agent:todo", "build-lane:platform", "complexity:3", "model:codex", "phase:1"],
            "BO-002": ["agent:todo", "build-lane:integration", "complexity:2", "model:codex", "phase:2"],
        }

    @staticmethod
    def root_template() -> str:
        return (
            "# Operator dashboard Build Order\n\n"
            "[`<APPROVED_SHA>`](https://github.com/example/repo/commit/<APPROVED_SHA>)\n\n"
            "<!-- aiur-planning-issue\n"
            '{"schema":2,"logical_id":"example/repo:operator-dashboard","plan_version":1,'
            '"approved_planning_commit":"<APPROVED_SHA>"}\n-->\n'
        )

    @staticmethod
    def git(root: Path, *arguments: str) -> None:
        subprocess.run(["git", "-C", str(root), *arguments], check=True, capture_output=True)

    @staticmethod
    def output(root: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(root), *arguments], check=True,
            capture_output=True, text=True,
        ).stdout.strip()
