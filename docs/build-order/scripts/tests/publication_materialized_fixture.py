"""Construct a fully reconciled, non-adjacent publication fixture."""

from __future__ import annotations

from publication_fixtures import build_order, companions, github, publication


APPROVED = "b" * 40
ROOT_ID = "example/repo:build-order-dashboard"
SKILL_ID = "SKILL-DELIVERY-001"


def materialized_pack() -> tuple[dict, dict, dict]:
    data, build, manifest = companions(), build_order(), publication()
    data["approved_planning_commit"] = APPROVED
    manifest["approved_planning_commit"] = APPROVED
    build["github_root"] = github(901, "ROOT_NODE")
    for index, ticket in enumerate(build["tickets"]):
        ticket["github"] = github(88_003 + index * 37, f"BO_NODE_{index}")
    for index, ticket in enumerate(data["tickets"]):
        ticket["github"] = github(701 + index * 19, f"DASH_NODE_{index}")
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
        "root_reconciliation_comment_url": (
            "https://github.com/example/repo/issues/901#issuecomment-987"
        ),
    }
    return data, build, manifest
