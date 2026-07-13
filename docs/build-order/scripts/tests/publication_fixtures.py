from __future__ import annotations

from publication_fixture_io import FixtureBase


SHA = "a" * 40
REPOSITORY = "example/repo"


def github(number: int, node: str) -> dict[str, object]:
    return {
        "repository": REPOSITORY,
        "number": number,
        "node_id": node,
        "url": f"https://github.com/{REPOSITORY}/issues/{number}",
    }


def build_order() -> dict[str, object]:
    tickets = [
        {
            "id": f"BO-{number:03d}",
            "depends_on": ["BO-001"] if number == 2 else [],
            "workstream": "backend",
            "phase_hint": 1,
            "complexity_points": 3,
            "github": None,
        }
        for number in range(1, 17)
    ]
    return {
        "plan_version": 1,
        "repository": REPOSITORY,
        "build_order_id": "example/repo:build-order-dashboard",
        "github_root": None,
        "label_projection": {
            "build_order": "build-order",
            "required_ticket_labels": ["model:codex"],
            "forbidden_labels": [],
            "workstreams": {"backend": "build-lane:backend"},
            "phases": {"1": "phase:1"},
            "complexities": {"3": "complexity:3"},
        },
        "tickets": tickets,
    }


def companions() -> dict[str, object]:
    tickets = [
        {
            "id": "DASH-001",
            "title": "First companion",
            "document": "tickets/DASH-001.md",
            "requirement_ref": "DREQ-001",
            "complexity_points": 2,
            "depends_on": ["BO-001"],
            "external_blockers": ["outside/repo#93"],
            "external_gate_ids": [],
            "github": None,
        },
        {
            "id": "DASH-002",
            "title": "Second companion",
            "document": "tickets/DASH-002.md",
            "requirement_ref": "DREQ-002",
            "complexity_points": 4,
            "depends_on": ["DASH-001"],
            "external_blockers": [],
            "external_gate_ids": ["GATE-HUMAN-AUTHORITY"],
            "github": None,
        },
    ]
    tickets.extend(
        {
            "id": f"DASH-{number:03d}",
            "title": f"Companion {number}",
            "document": f"tickets/DASH-{number:03d}.md",
            "requirement_ref": f"DREQ-{number:03d}",
            "complexity_points": 2,
            "depends_on": [],
            "external_blockers": [],
            "external_gate_ids": [],
            "github": None,
        }
        for number in range(3, 23)
    )
    return {
        "schema_version": 1,
        "plan_version": 1,
        "repository": REPOSITORY,
        "researched_at_commit": SHA,
        "approved_planning_commit": None,
        "required_labels": ["model:codex"],
        "forbidden_labels": [
            "agent:todo",
            "agent:in-progress",
            "agent:human-review",
            "agent:rework",
            "agent:merging",
            "agent:paused",
            "agent:done",
            "agent:ci-wait",
            "agent:error",
            "agent:canceled",
            "agent:cancelled",
            "agent:watch",
        ],
        "external_gates": [
            {
                "id": "GATE-HUMAN-AUTHORITY",
                "owner": "operator",
                "resolution_criteria": "operator grants authority",
            }
        ],
        "tickets": tickets,
        "github_reconciliation": None,
    }


def publication() -> dict[str, object]:
    prefixes = ["agent:", "model:", "complexity:", "phase:", "build-lane:"]
    return {
        "schema_version": 1,
        "plan_version": 1,
        "repository": REPOSITORY,
        "approved_planning_commit": None,
        "root_issue": {
            "logical_id": "example/repo:build-order-dashboard",
            "document": "root-issue.md",
            "required_labels": ["build-order"],
            "forbidden_labels": [],
            "forbidden_label_prefixes": prefixes,
        },
        "skill_issue": {
            "logical_id": "SKILL-DELIVERY-001",
            "document": "skill-delivery.md",
            "required_labels": ["human:todo"],
            "forbidden_labels": ["build-order"],
            "forbidden_label_prefixes": prefixes,
        },
        "external_blocker_relations": [
            {
                "blocked_ticket_id": ticket_id,
                "blocker_issue_id": "SKILL-DELIVERY-001",
            }
            for ticket_id in ("BO-001", "BO-004", "BO-008")
        ],
        "read_only_issue_refs": [
            "example/repo#132",
            "example/repo#845",
            "example/repo#1033",
            "example/repo#1034",
            "example/repo#1067",
        ],
        "github_reconciliation": None,
    }


class Fixture(FixtureBase):
    def __init__(
        self,
        companion: dict[str, object] | None = None,
        build: dict[str, object] | None = None,
        publication_data: dict[str, object] | None = None,
    ) -> None:
        super().__init__(
            companion or companions(), build or build_order(),
            publication_data or publication(),
        )
