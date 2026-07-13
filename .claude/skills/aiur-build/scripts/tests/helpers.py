"""Shared fixtures for Build Order validator tests."""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from validate_build_order import validate_data  # noqa: E402


REFERENCES = SCRIPT_DIR.parent / "references"
EXAMPLE = REFERENCES / "build-order.example.json"


def example() -> dict[str, Any]:
    return json.loads(EXAMPLE.read_text(encoding="utf-8"))


def report_for(
    data: object,
    approved_body_expectations: dict[str, dict[str, Any]] | None = None,
):
    return validate_data(data, REFERENCES, approved_body_expectations)


def umbrella(ticket_id: str, document: str, children: list[str]) -> dict[str, Any]:
    return {
        "id": ticket_id,
        "kind": "umbrella",
        "provenance": "planned",
        "introduced_in_plan_version": 1,
        "discovered_from": None,
        "title": "Group related tickets",
        "document": document,
        "outcome": "Related worker tickets have one non-runnable grouping.",
        "scope": ["Group the listed tickets"],
        "non_goals": ["Perform executable implementation work"],
        "phase_hint": 1,
        "complexity_points": None,
        "complexity_rationale": None,
        "risk": None,
        "capability_requirements": [],
        "workstream": "platform",
        "requirement_refs": [],
        "depends_on": [],
        "serializes_with": [],
        "suggested_after": [],
        "contains": children,
        "external_gates": [],
        "read_surfaces": [],
        "write_surfaces": [],
        "contract_surfaces": [],
        "safety_surfaces": [],
        "conflict_exceptions": [],
        "decision_refs": [],
        "design_evidence_refs": [],
        "acceptance": {"agent_gate": [], "at_merge_gate": [], "human_or_e2e": []},
        "github": None,
    }


def executable(ticket_id: str = "BO-003") -> dict[str, Any]:
    ticket = copy.deepcopy(example()["tickets"][0])
    ticket.update(
        {
            "id": ticket_id,
            "title": "Add a second graph projection",
            "document": "example-tickets/BO-003-example-executable.md",
            "outcome": "A second projection is available.",
            "depends_on": ["BO-001"],
            "safety_surfaces": [],
        }
    )
    return ticket


class ValidatorCase(unittest.TestCase):
    def assert_error(self, data: object, needle: str) -> None:
        report = report_for(data)
        self.assertTrue(
            any(needle in message for message in report.errors),
            f"missing {needle!r} in {report.errors}",
        )

    def assert_clean(self, data: object) -> None:
        report = report_for(data)
        self.assertEqual([], report.errors)
        self.assertEqual([], report.warnings)
