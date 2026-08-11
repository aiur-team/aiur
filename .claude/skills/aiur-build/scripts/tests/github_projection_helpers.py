"""Feature-boundary, label-projection, and GitHub identity tests."""

from __future__ import annotations

import copy

from helpers import ValidatorCase, example, report_for
from validation_common import Report
from validation_github_approved import ApprovedIssueExpectations
from validation_github_rendering import render_ticket_body, inspect_issue_body
from validation_publication_authority import PublicationAuthority


def github(repository: str, number: int, node_id: str):
    return {
        "repository": repository,
        "number": number,
        "node_id": node_id,
        "url": f"https://github.com/{repository}/issues/{number}",
    }


class GithubProjectionCase(ValidatorCase):
    def assert_error(self, data, needle):
        report = report_for(data, getattr(self, "approved_body_expectations", None))
        self.assertTrue(
            any(needle in message for message in report.errors),
            f"missing {needle!r} in {report.errors}",
        )

    def assert_clean(self, data):
        report = report_for(data, getattr(self, "approved_body_expectations", None))
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)

    def materialized(self):
        data = example()
        data["github_root"] = github("example/repo", 100, "ROOT")
        data["tickets"][0]["github"] = github("example/repo", 101, "ONE")
        data["tickets"][1]["github"] = github("example/other", 102, "TWO")
        data["github_reconciliation"] = {
            "receipt_schema_version": 3,
            "checked_at": "2026-01-01T00:00:00Z",
            "approved_planning_commit": "b" * 40,
            "root_node_id": "ROOT",
            "member_ticket_ids": ["BO-001", "BO-002"],
            "dependency_edges": [{"ticket_id": "BO-002", "depends_on": "BO-001"}],
            "observed_labels": {
                "example/repo:operator-dashboard": ["build-order"],
                "BO-001": ["agent:todo", "build-lane:platform", "phase:1", "complexity:3", "model:codex"],
                "BO-002": ["agent:todo", "build-lane:integration", "phase:2", "complexity:2", "model:codex"],
            },
            "projected_labels": {
                "example/repo:operator-dashboard": ["build-order"],
                "BO-001": ["agent:todo", "build-lane:platform", "phase:1", "complexity:3", "model:codex"],
                "BO-002": ["agent:todo", "build-lane:integration", "phase:2", "complexity:2", "model:codex"],
            },
            "expected_issue_titles": {
                "example/repo:operator-dashboard": "example/repo:operator-dashboard",
                "BO-001": "BO-001",
                "BO-002": "BO-002",
            },
            "observed_issue_titles": {
                "example/repo:operator-dashboard": "example/repo:operator-dashboard",
                "BO-001": "BO-001",
                "BO-002": "BO-002",
            },
            "observed_issue_states": {
                "example/repo:operator-dashboard": "OPEN",
                "BO-001": "OPEN",
                "BO-002": "OPEN",
            },
            "observed_body_evidence": {},
            "marker_query_matches": {
                "example/repo:operator-dashboard": [copy.deepcopy(data["github_root"])],
                "BO-001": [copy.deepcopy(data["tickets"][0]["github"])],
                "BO-002": [copy.deepcopy(data["tickets"][1]["github"])],
            },
        }
        rendered = {}
        for identity in ("example/repo:operator-dashboard", "BO-001", "BO-002"):
            report = Report()
            body = render_ticket_body(
                f"# {identity}\n", "example/repo", identity, 1, "b" * 40,
                report, f"test {identity}",
            )
            self.assertIsNotNone(body, report.errors)
            evidence = inspect_issue_body(
                body, "example/repo", identity, 1, "b" * 40,
                report, f"test {identity}",
            )
            self.assertIsNotNone(evidence, report.errors)
            rendered[identity] = evidence
        self.approved_body_expectations = ApprovedIssueExpectations(
            bodies=rendered,
            titles={identity: identity for identity in rendered},
        )
        data["github_reconciliation"]["observed_body_evidence"] = copy.deepcopy(rendered)
        return data
