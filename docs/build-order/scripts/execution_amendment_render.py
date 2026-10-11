"""Render and parse the execution amendment comments."""

from __future__ import annotations

import json
import re
from typing import Any

import skill_publication_path  # noqa: F401
from publication_common import Report, strict_int, strict_object


AMENDMENT_MARKER = "aiur-execution-amendment"


# Array order is part of the authorized lane receipt, not just presentation.
EXPECTED_LANES = {
    "L1": [
        "BO-007", "BO-011", "BO-012", "BO-013", "BO-014", "BO-020",
        "DASH-023",
    ],
    "L2": [
        "BO-018", "DASH-003", "DASH-005", "DASH-015", "DASH-022",
        "DASH-027", "DASH-028", "DASH-031", "DASH-034",
    ],
    "L3": ["DASH-014", "DASH-032"],
    "L4": ["DASH-024", "DASH-025", "DASH-030"],
    "L5": ["DASH-033", "BO-015"],
}


LANE_ANCHORS = {
    "L1": {
        "logical_id": "BO-007",
        "issue_url": "https://github.com/aiur-team/aiur/issues/1095",
        "policy_line": 132,
        "one_writer_packet": (
            "one dedicated BuildOrderLive vertical plus its namespaced CSS and "
            "browser-harness surface"
        ),
    },
    "L2": {
        "logical_id": "BO-018",
        "issue_url": "https://github.com/aiur-team/aiur/issues/1105",
        "policy_line": 133,
        "one_writer_packet": (
            "one DashboardLive/OCC CSS/component owner plus the shared focus hook"
        ),
    },
    "L3": {
        "logical_id": "DASH-014",
        "issue_url": "https://github.com/aiur-team/aiur/issues/1120",
        "policy_line": 134,
        "one_writer_packet": "pure run-state projections plus one runtime child",
    },
    "L4": {
        "logical_id": "DASH-024",
        "issue_url": "https://github.com/aiur-team/aiur/issues/1128",
        "policy_line": 135,
        "one_writer_packet": "usage accounting modules plus one accounting child",
    },
    "L5": {
        "logical_id": "BO-015",
        "issue_url": "https://github.com/aiur-team/aiur/issues/1102",
        "policy_line": 136,
        "one_writer_packet": "the shipped-harness convergence and parity capstone",
    },
}


INDIVIDUAL_POLICY_LINES = {
    "BO-003": 98,
    "BO-005": 99,
    "BO-006": 100,
    "BO-016": 101,
    "BO-019": 102,
    "DASH-001": 103,
    "DASH-007": 104,
    "DASH-008": 105,
    "DASH-009": 106,
    "DASH-010": 107,
    "DASH-011": 108,
    "DASH-012": 109,
    "DASH-013": 110,
    "DASH-016": 111,
    "DASH-019": 112,
    "DASH-020": 113,
    "DASH-021": 114,
    "DASH-026": 115,
    "DASH-029": 116,
}


MARKER_KEYS = {
    "schema",
    "amendment_id",
    "build_order_id",
    "plan_version",
    "publication_receipt_commit",
    "policy_authority_commit",
    "policy_document_sha256",
    "logical_id",
    "decision_sha256",
    "lane_id",
    "state",
}


MARKER = re.compile(
    rf"<!-- {AMENDMENT_MARKER}[ \t]*\n(?P<payload>[^\n]*)\n-->",
    re.ASCII,
)


def render_authorization_comment(amendment: dict[str, Any]) -> str:
    policy = amendment.get("policy") if isinstance(amendment.get("policy"), dict) else {}
    root_id = amendment.get("build_order_id")
    policy_authority = (
        amendment.get("policy_authority")
        if isinstance(amendment.get("policy_authority"), dict) else {}
    )
    marker = _marker_payload(amendment, root_id, None)
    return (
        f"Execution amendment **{amendment.get('amendment_id')}** is authorized for "
        f"Build Order `{root_id}`.\n\n"
        f"Binding policy authority: [commit-pinned execution policy]"
        f"({_policy_link(amendment)}) at `{policy_authority.get('commit')}` / "
        f"`{policy_authority.get('document_sha256')}`.\n\n"
        f"Feature work targets `{policy.get('target_ref')}` and must be refreshed to "
        "the exact current target head before review, CI, and merge. The five-lane "
        "overlay changes ownership and repeated acceptance tails only; publication "
        "membership, native dependencies, mappings, and per-ticket agent gates remain "
        "unchanged.\n\n"
        f"<!-- {AMENDMENT_MARKER}\n{marker}\n-->\n"
    )


def render_ticket_amendment_comment(
    amendment: dict[str, Any], logical_id: str,
) -> str:
    policy = amendment.get("policy") if isinstance(amendment.get("policy"), dict) else {}
    lane_id = lane_for_ticket(amendment, logical_id)
    ownership = (
        f"consolidated lane `{lane_id}`" if lane_id is not None else "individual ticket ownership"
    )
    marker = _marker_payload(amendment, logical_id, lane_id)
    ownership_packet = _ownership_packet(amendment, logical_id, lane_id)
    return (
        f"Execution amendment **{amendment.get('amendment_id')}** applies to "
        f"`{logical_id}` using {ownership}.\n\n"
        f"{ownership_packet}\n\n"
        f"Work targets `{policy.get('target_ref')}`. Before review, CI, or merge, the "
        "owning head must contain the exact current target head. Preserve this ticket's "
        "agent acceptance; lane ownership collapses only repeated at-merge/manual "
        "ceremony. After one bounded recovery attempt, the Executor may take direct "
        "ownership when delegation is not making material progress.\n\n"
        f"<!-- {AMENDMENT_MARKER}\n{marker}\n-->\n"
    )


def parse_execution_comment(
    body: object, label: str, report: Report,
) -> dict[str, Any] | None:
    if not isinstance(body, str):
        report.error(f"{label} body must be text")
        return None
    openings = body.count(f"<!-- {AMENDMENT_MARKER}")
    matches = list(MARKER.finditer(body))
    if openings != 1 or len(matches) != 1:
        report.error(f"{label} must contain exactly one {AMENDMENT_MARKER} marker")
        return None
    try:
        payload = json.loads(matches[0].group("payload"))
    except json.JSONDecodeError as exc:
        report.error(f"{label} marker must be one-line JSON: {exc}")
        return None
    marker = strict_object(payload, f"{label} marker", MARKER_KEYS, report)
    if marker is None:
        return None
    if marker.get("schema") != 1:
        report.error(f"{label} marker schema must equal integer 1")
    if marker.get("state") != "authorized":
        report.error(f"{label} marker state must equal authorized")
    lane = marker.get("lane_id")
    if lane is not None and lane not in EXPECTED_LANES:
        report.error(f"{label} marker lane_id is invalid")
    return marker


def lane_for_ticket(amendment: dict[str, Any], logical_id: str) -> str | None:
    lanes = amendment.get("lanes")
    if not isinstance(lanes, dict):
        return None
    found = [
        lane_id for lane_id, members in lanes.items()
        if isinstance(members, list) and logical_id in members
    ]
    return found[0] if len(found) == 1 else None


def _ownership_packet(
    amendment: dict[str, Any], logical_id: str, lane_id: str | None,
) -> str:
    if lane_id is None:
        line = INDIVIDUAL_POLICY_LINES.get(logical_id)
        link = _policy_link(amendment, line)
        return (
            f"Individual owner packet: follow the exact `{logical_id}` binding "
            f"correction in the [commit-pinned policy row]({link})."
        )
    anchor = LANE_ANCHORS[lane_id]
    members = ", ".join(f"`{item}`" for item in EXPECTED_LANES[lane_id])
    packet_link = _policy_link(amendment, anchor["policy_line"])
    owner_link = f"[{anchor['logical_id']}]({anchor['issue_url']})"
    if logical_id == anchor["logical_id"]:
        return (
            f"Lane owner: {owner_link} owns `{lane_id}`. Exact members: {members}. "
            f"One-writer packet: {anchor['one_writer_packet']}. See the "
            f"[commit-pinned lane packet]({packet_link})."
        )
    return (
        f"Lane follower: `{logical_id}` follows `{lane_id}` owner {owner_link} and "
        f"the [commit-pinned lane packet]({packet_link}). It closes individually "
        "only when its own acceptance evidence is recorded; implementation and "
        "review flow through the lane integration head."
    )


def _policy_link(amendment: dict[str, Any], line: object = None) -> str:
    policy = amendment.get("policy_authority")
    commit = policy.get("commit") if isinstance(policy, dict) else None
    document = policy.get("document") if isinstance(policy, dict) else None
    root_id = amendment.get("build_order_id")
    repository = root_id.rsplit(":", 1)[0] if isinstance(root_id, str) else ""
    url = (
        f"https://github.com/{repository}/blob/{commit}/docs/build-order/{document}"
    )
    return f"{url}#L{line}" if strict_int(line) and line > 0 else url


def _marker_payload(
    amendment: dict[str, Any], logical_id: object, lane_id: str | None,
) -> str:
    return json.dumps(
        {
            "schema": 1,
            "amendment_id": amendment.get("amendment_id"),
            "build_order_id": amendment.get("build_order_id"),
            "plan_version": amendment.get("plan_version"),
            "publication_receipt_commit": amendment.get("publication_receipt_commit"),
            "policy_authority_commit": (
                amendment.get("policy_authority", {}).get("commit")
                if isinstance(amendment.get("policy_authority"), dict) else None
            ),
            "policy_document_sha256": (
                amendment.get("policy_authority", {}).get("document_sha256")
                if isinstance(amendment.get("policy_authority"), dict) else None
            ),
            "logical_id": logical_id,
            "decision_sha256": amendment.get("decision_sha256"),
            "lane_id": lane_id,
            "state": "authorized",
        },
        separators=(",", ":"),
    )
