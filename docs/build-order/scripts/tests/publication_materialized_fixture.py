"""Construct a fully reconciled, non-adjacent publication fixture."""

from __future__ import annotations

import copy

from publication_fixture_io import (
    EXPECTED_BODY_SHA,
    EXPECTED_COMMENT_SHA,
    FIXTURE_APPROVED,
)
from publication_fixtures import build_order, companions, github, publication


APPROVED = FIXTURE_APPROVED
ROOT_ID = "example/repo:build-order-dashboard"
SKILL_ID = "SKILL-DELIVERY-001"
REPOSITORY = "example/repo"


def body_evidence(ids: list[str]) -> dict[str, dict[str, object]]:
    return {
        logical_id: {
            "marker_count": 1,
            "marker_schema_version": 2,
            "marker_logical_id": logical_id,
            "marker_plan_version": 1,
            "approved_planning_commit": APPROVED,
            "approved_link_count": 1,
            "approved_link": f"https://github.com/{REPOSITORY}/commit/{APPROVED}",
            "body_sha256": EXPECTED_BODY_SHA,
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
    core_mappings = {
        ROOT_ID: [copy.deepcopy(build["github_root"])],
        **{
            ticket["id"]: [copy.deepcopy(ticket["github"])]
            for ticket in build["tickets"]
        },
    }
    build["github_reconciliation"] = {
        "receipt_schema_version": 3,
        "checked_at": "2026-07-13T00:00:00Z",
        "approved_planning_commit": APPROVED,
        "root_node_id": "ROOT_NODE",
        "member_ticket_ids": bo_ids,
        "dependency_edges": [
            {"ticket_id": ticket["id"], "depends_on": dependency}
            for ticket in build["tickets"] for dependency in ticket["depends_on"]
        ],
        "projected_labels": {
            ROOT_ID: ["build-order"], **copy.deepcopy(bo_labels),
        },
        "observed_labels": {
            ROOT_ID: ["build-order"], **copy.deepcopy(bo_labels),
        },
        "observed_body_evidence": body_evidence([ROOT_ID, *bo_ids]),
        "expected_issue_titles": {
            ROOT_ID: "Test root",
            **{
                ticket["id"]: f"{ticket['id']} — {ticket['title']}"
                for ticket in build["tickets"]
            },
        },
        "observed_issue_titles": {
            ROOT_ID: "Test root",
            **{
                ticket["id"]: f"{ticket['id']} — {ticket['title']}"
                for ticket in build["tickets"]
            },
        },
        "observed_issue_states": {key: "OPEN" for key in [ROOT_ID, *bo_ids]},
        "marker_query_matches": core_mappings,
    }
    dash_ids = [ticket["id"] for ticket in data["tickets"]]
    data["github_reconciliation"] = {
        "receipt_schema_version": 2,
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
        "observed_parent_issues": {ticket["id"]: None for ticket in data["tickets"]},
        "observed_body_evidence": body_evidence(dash_ids),
        "expected_issue_titles": {
            ticket["id"]: f"{ticket['id']} — {ticket['title']}"
            for ticket in data["tickets"]
        },
        "observed_issue_titles": {
            ticket["id"]: f"{ticket['id']} — {ticket['title']}"
            for ticket in data["tickets"]
        },
        "observed_issue_states": {key: "OPEN" for key in dash_ids},
        "marker_query_matches": {
            ticket["id"]: [copy.deepcopy(ticket["github"])]
            for ticket in data["tickets"]
        },
    }
    root_comment_url = "https://github.com/example/repo/issues/901#issuecomment-987"
    manifest["github_reconciliation"] = {
        "receipt_schema_version": 2,
        "checked_at": "2026-07-13T00:00:00Z",
        "issue_mappings": {
            ROOT_ID: github(901, "ROOT_NODE"),
            SKILL_ID: github(4, "SKILL_NODE"),
        },
        "external_blocker_relations": manifest["external_blocker_relations"],
        "observed_labels": {ROOT_ID: ["build-order"], SKILL_ID: ["human:todo"]},
        "observed_parent_issues": {ROOT_ID: None, SKILL_ID: None},
        "observed_body_evidence": body_evidence([SKILL_ID]),
        "expected_issue_titles": {
            SKILL_ID: "Test skill",
        },
        "observed_issue_titles": {
            SKILL_ID: "Test skill",
        },
        "observed_issue_states": {SKILL_ID: "OPEN"},
        "marker_query_matches": {SKILL_ID: [github(4, "SKILL_NODE")]},
        "root_reconciliation_comment_matches": [{
            "marker_count": 1,
            "marker": "aiur-build-order-reconciliation",
            "marker_schema_version": 1,
            "logical_id": ROOT_ID,
            "plan_version": 1,
            "approved_planning_commit": APPROVED,
            "state": "pending",
            "receipt_commit": None,
            "receipt_url": None,
            "url": root_comment_url,
            "body_sha256": EXPECTED_COMMENT_SHA,
        }],
    }
    return data, build, manifest
