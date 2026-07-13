from __future__ import annotations

import json
import tempfile
from pathlib import Path


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
    return {
        "plan_version": 1,
        "repository": REPOSITORY,
        "build_order_id": "example/repo:build-order-dashboard",
        "github_root": None,
        "tickets": [
            {"id": "BO-001", "depends_on": [], "github": None},
            {"id": "BO-002", "depends_on": ["BO-001"], "github": None},
        ],
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
        for number in range(3, 16)
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
            {"blocked_ticket_id": "BO-001", "blocker_issue_id": "SKILL-DELIVERY-001"}
        ],
        "read_only_issue_refs": ["example/repo#132", "example/repo#845"],
        "github_reconciliation": None,
    }


class Fixture:
    def __init__(
        self,
        companion: dict[str, object] | None = None,
        build: dict[str, object] | None = None,
        publication_data: dict[str, object] | None = None,
    ) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.companion_path = self.base / "dashboard-companions.json"
        self.build_path = self.base / "build-order.json"
        self.publication_path = self.base / "publication.json"
        self.write(
            companion or companions(), build or build_order(),
            publication_data or publication(),
        )

    def write(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object],
    ) -> None:
        (self.base / "tickets").mkdir(exist_ok=True)
        for ticket in companion.get("tickets", []):
            if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
                continue
            text = (
                f"# {ticket['id']} — Test\n\n"
                "**Kind:** executable\n\n"
                f"**Complexity:** {ticket.get('complexity_points')} — Test\n\n"
                "**Depends on:** "
                + ", ".join(
                    ticket.get("depends_on", []) + ticket.get("external_blockers", [])
                )
                + ("\n\n" if ticket.get("depends_on", []) + ticket.get("external_blockers", []) else "none\n\n")
                + (
                    "**External gates:** "
                    + ", ".join(ticket.get("external_gate_ids", []))
                    + "\n\n"
                    if ticket.get("external_gate_ids", [])
                    else ""
                )
                + f"**Requirements:** {ticket.get('requirement_ref')}\n\n"
                + "**Build Order membership:** none — standalone dashboard companion\n"
            )
            (self.base / str(ticket.get("document"))).write_text(text, encoding="utf-8")
        self.companion_path.write_text(json.dumps(companion), encoding="utf-8")
        self.build_path.write_text(json.dumps(build), encoding="utf-8")
        self.publication_path.write_text(json.dumps(publication_data), encoding="utf-8")
        for name, logical_id in (
            ("root-issue.md", "example/repo:build-order-dashboard"),
            ("skill-delivery.md", "SKILL-DELIVERY-001"),
        ):
            (self.base / name).write_text(f"# Test\n\n{logical_id}\n", encoding="utf-8")

    def close(self) -> None:
        self.temp.cleanup()
