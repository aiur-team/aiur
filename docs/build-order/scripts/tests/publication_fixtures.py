from __future__ import annotations

from publication_fixture_io import FixtureBase


SHA = "a" * 40
REPOSITORY = "example/repo"
AGENT_LABELS = [
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
]


def github(number: int, node: str) -> dict[str, object]:
    return {
        "repository": REPOSITORY,
        "number": number,
        "node_id": node,
        "url": f"https://github.com/{REPOSITORY}/issues/{number}",
    }


def _ticket(
    ticket_id: str,
    title: str,
    *,
    complexity: int = 3,
    depends_on: list[str] | None = None,
    serializes_with: list[str] | None = None,
    external_gates: list[str] | None = None,
    requirement_refs: list[str] | None = None,
) -> dict[str, object]:
    return {
        "id": ticket_id,
        "title": title,
        "document": f"tickets/{ticket_id}.md",
        "workstream": "backend",
        "phase_hint": 1,
        "complexity_points": complexity,
        "requirement_refs": requirement_refs or [],
        "depends_on": depends_on or [],
        "serializes_with": serializes_with or [],
        "external_gates": external_gates or [],
        "read_surfaces": [],
        "write_surfaces": [],
        "contract_surfaces": [],
        "safety_surfaces": [],
        "conflict_exceptions": [],
        "github": None,
    }


def build_order() -> dict[str, object]:
    tickets = [
        _ticket(
            f"BO-{number:03d}",
            f"Build Order ticket {number}",
            depends_on=["BO-001"] if number == 2 else [],
        )
        for number in range(1, 20)
    ]
    tickets.append(_ticket(
        "DASH-001",
        "First companion",
        complexity=2,
        depends_on=["BO-001"],
        requirement_refs=["DREQ-001"],
    ))
    tickets.append(_ticket(
        "DASH-002",
        "Second companion",
        complexity=4,
        depends_on=["DASH-001"],
        external_gates=["GATE-HUMAN-AUTHORITY"],
        requirement_refs=["DREQ-002"],
    ))
    tickets.extend(
        _ticket(
            f"DASH-{number:03d}",
            f"Companion {number}",
            complexity=2,
            requirement_refs=[f"DREQ-{number:03d}"],
        )
        for number in range(3, 26)
    )
    return {
        "schema_version": 1,
        "plan_version": 1,
        "repository": REPOSITORY,
        "researched_at_commit": SHA,
        "build_order_id": "example/repo:build-order-dashboard",
        "github_root": None,
        "label_projection": {
            "build_order": "build-order",
            "required_ticket_labels": ["model:codex-gpt-5.6-terra"],
            "forbidden_labels": list(AGENT_LABELS),
            "workstreams": {"backend": "build-lane:backend"},
            "phases": {"1": "phase:1"},
            "complexities": {"2": "complexity:2", "3": "complexity:3", "4": "complexity:4"},
        },
        "external_gates": [
            {
                "id": "GATE-HUMAN-AUTHORITY",
                "title": "Grant human authority",
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
        "trusted_repository_ref": "refs/heads/build-order-research",
        "root_issue": {
            "logical_id": "example/repo:build-order-dashboard",
            "document": "root-issue.md",
            "required_labels": ["build-order"],
            "forbidden_labels": [],
            "forbidden_label_prefixes": [*prefixes, "human:"],
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
            for ticket_id in ("BO-004", "BO-008")
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
        build: dict[str, object] | None = None,
        publication_data: dict[str, object] | None = None,
        pack_prefix: str = ".",
    ) -> None:
        super().__init__(
            build or build_order(),
            publication_data or publication(), pack_prefix,
        )
