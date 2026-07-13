"""Construct a fully reconciled, non-adjacent publication fixture."""

from __future__ import annotations

import hashlib

from publication_core_receipt import PINNED_SKILL_COMMIT
from publication_fixtures import build_order, companions, github, publication


APPROVED = PINNED_SKILL_COMMIT
ROOT_ID = "example/repo:build-order-dashboard"
SKILL_ID = "SKILL-DELIVERY-001"


def body_evidence(ids: list[str]) -> dict[str, dict[str, str]]:
    return {
        logical_id: {
            "marker_logical_id": logical_id,
            "approved_planning_commit": APPROVED,
            "body_sha256": hashlib.sha256(logical_id.encode()).hexdigest(),
        }
        for logical_id in ids
    }


def materialized_pack() -> tuple[dict, dict, dict]:
    data, build, manifest = companions(), build_order(), publication()
    data["approved_planning_commit"] = APPROVED
    manifest["approved_planning_commit"] = APPROVED
    build["github_root"] = github(901, "ROOT_NODE")
    for index, ticket in enumerate(build["tickets"]):
        ticket["github"] = github(88_003 + index * 37, f"BO_NODE_{index}")
    for index, ticket in enumerate(data["tickets"]):
        ticket["github"] = github(701 + index * 19, f"DASH_NODE_{index}")
    bo_ids = [ticket["id"] for ticket in build["tickets"]]
    bo_labels = {
        ticket["id"]: [
            "model:codex", "build-lane:backend", "phase:1", "complexity:3",
        ]
        for ticket in build["tickets"]
    }
    build["github_reconciliation"] = {
        "receipt_schema_version": 2,
        "checked_at": "2026-07-13T00:00:00Z",
        "approved_planning_commit": APPROVED,
        "root_node_id": "ROOT_NODE",
        "member_ticket_ids": bo_ids,
        "dependency_edges": [
            {"ticket_id": ticket["id"], "depends_on": dependency}
            for ticket in build["tickets"] for dependency in ticket["depends_on"]
        ],
        "projected_labels": {"github_root": ["build-order"], **bo_labels},
        "observed_labels": {"github_root": ["build-order"], **bo_labels},
        "observed_body_evidence": body_evidence([ROOT_ID, *bo_ids]),
    }
    dash_ids = [ticket["id"] for ticket in data["tickets"]]
    data["github_reconciliation"] = {
        "checked_at": "2026-07-13T00:00:00Z",
        "dependency_edges": [
            {"ticket_id": ticket["id"], "depends_on": dependency}
            for ticket in data["tickets"]
            for dependency in ticket["depends_on"] + ticket["external_blockers"]
        ],
        "observed_labels": {
            ticket["id"]: ["model:codex", f"complexity:{ticket['complexity_points']}"]
            for ticket in data["tickets"]
        },
        "observed_parent_issues": {
            ticket["id"]: None for ticket in data["tickets"]
        },
        "observed_body_evidence": body_evidence(dash_ids),
    }
    manifest["github_reconciliation"] = {
        "checked_at": "2026-07-13T00:00:00Z",
        "issue_mappings": {
            ROOT_ID: github(901, "ROOT_NODE"),
            SKILL_ID: github(4, "SKILL_NODE"),
        },
        "external_blocker_relations": manifest["external_blocker_relations"],
        "observed_labels": {
            ROOT_ID: ["build-order"],
            SKILL_ID: ["human:todo"],
        },
        "observed_parent_issues": {ROOT_ID: None, SKILL_ID: None},
        "observed_body_evidence": body_evidence([SKILL_ID]),
        "root_reconciliation_comment": {
            "marker": "aiur-build-order-reconciliation",
            "state": "pending",
            "url": "https://github.com/example/repo/issues/901#issuecomment-987",
            "body_sha256": hashlib.sha256(b"pending comment").hexdigest(),
        },
    }
    return data, build, manifest
