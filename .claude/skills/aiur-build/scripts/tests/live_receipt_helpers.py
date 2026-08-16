"""Fresh live-GitHub verification for immutable publication receipts."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

from helpers import SCRIPT_DIR  # installs the scripts import path
from validate_build_order import _validate_receipt
from validation_common import Report
from validation_github_api import GITHUB_API_VERSION, GITHUB_TIMEOUT_SECONDS
from validation_github_live import (
    GhApiReader,
    GitHubReader,
    LiveGitHubError,
    validate_live_github_receipt,
)
from validation_github_reader import QueryBudget
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
        "BO-001": ["agent:todo", "build-lane:platform", "complexity:3", "model:codex", "phase:1"],
        "BO-002": ["agent:todo", "build-lane:integration", "complexity:2", "model:codex", "phase:2"],
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
