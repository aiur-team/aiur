"""Typed execution-amendment contract layered over publication receipt v3.

The publication manifests and issue bodies remain immutable.  This module
validates an additive execution decision and renders the comments that carry
that decision to the already-published GitHub issues.
"""

from __future__ import annotations

import hashlib
import json
import re
import stat
from pathlib import Path
from typing import Any

from publication_common import (
    SHA,
    Report,
    nonempty_string,
    strict_int,
    strict_object,
    string_list,
    valid_rfc3339_utc,
)
from publication_receipt_authority import (
    ReceiptAuthority,
    ReceiptBlobBudget,
    _commit_blob,
)
from publication_rendering import (
    BODY_SHA,
    exact_commit,
    repository_relative,
    repository_root,
)


AMENDMENT_MARKER = "aiur-execution-amendment"
AMENDMENT_ID = "DEC-015"
POLICY_AUTHORITY_COMMIT = "c6a8bafe3b777ba1781e8a786a71ae87ddf873d9"
POLICY_AUTHORITY_DOCUMENT = "11-execution-amendment.md"
POLICY_AUTHORITY_DOCUMENT_SHA256 = (
    "82c16972ae4c4777b2820780ddb006fb4c4b00c193875c44f8458342fb8d71c5"
)
EXPECTED_MEMBER_COUNT = 54
EXPECTED_EDGE_COUNT = 105
EXPECTED_MEMBER_IDS_SHA256 = (
    "f8ea55d2c600ece7a4f09b2d264a47b33b4bfd564ded089cf6c959b3deece9f6"
)
EXPECTED_DEPENDENCY_EDGES_SHA256 = (
    "07ac5dd8fa9fb28b2bfd89d7f0b363fd9f738d3a95425640bec7b08de87d0a3b"
)
EXPECTED_TICKET_MAPPINGS_SHA256 = (
    "d93ada2652581418e7299412c301e4db21e8350158ca5cdd8102668654eef974"
)
EXPECTED_LANE_MAPPING_SHA256 = (
    "5082c48efb2a41f5935f0b6c6ba20a05304c1c20edd3ed049c58b86704a6fdcd"
)

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
        "issue_url": "https://github.com/its-everdred/aiur/issues/1095",
        "policy_line": 132,
        "one_writer_packet": (
            "one dedicated BuildOrderLive vertical plus its namespaced CSS and "
            "browser-harness surface"
        ),
    },
    "L2": {
        "logical_id": "BO-018",
        "issue_url": "https://github.com/its-everdred/aiur/issues/1105",
        "policy_line": 133,
        "one_writer_packet": (
            "one DashboardLive/OCC CSS/component owner plus the shared focus hook"
        ),
    },
    "L3": {
        "logical_id": "DASH-014",
        "issue_url": "https://github.com/its-everdred/aiur/issues/1120",
        "policy_line": 134,
        "one_writer_packet": "pure run-state projections plus one runtime child",
    },
    "L4": {
        "logical_id": "DASH-024",
        "issue_url": "https://github.com/its-everdred/aiur/issues/1128",
        "policy_line": 135,
        "one_writer_packet": "usage accounting modules plus one accounting child",
    },
    "L5": {
        "logical_id": "BO-015",
        "issue_url": "https://github.com/its-everdred/aiur/issues/1102",
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
EXPECTED_AFFECTED_IDS = {
    *INDIVIDUAL_POLICY_LINES,
    *(item for members in EXPECTED_LANES.values() for item in members),
}

EXPECTED_POLICY = {
    "target_ref": "refs/heads/develop",
    "exact_current_target_head_required": True,
    "refresh_after_every_integration_merge": True,
    "sync_main_after_generic_merge": True,
    "review_unit": "lane-integration-head",
    "bounded_rework_attempts": 1,
    "executor_takeover_on_nonprogress": True,
    "preserve_agent_acceptance": True,
    "collapse_lane_merge_and_manual_gates": True,
    "close_members_individually_on_evidence": True,
}

AMENDMENT_KEYS = {
    "schema_version",
    "amendment_id",
    "build_order_id",
    "plan_version",
    "publication_receipt_commit",
    "recorded_at",
    "policy_authority",
    "baseline",
    "policy",
    "lanes",
    "lane_mapping_sha256",
    "affected_ticket_ids",
    "completed_before_amendment_ticket_ids",
    "authorized_comment_authors",
    "decision_sha256",
    "authorization_comment",
    "ticket_amendment_comments",
}
BASELINE_KEYS = {
    "member_count",
    "dependency_edge_count",
    "member_ids_sha256",
    "dependency_edges_sha256",
    "ticket_github_mappings_sha256",
}
POLICY_AUTHORITY_KEYS = {"commit", "document", "document_sha256"}
POLICY_KEYS = set(EXPECTED_POLICY)
COMMENT_EVIDENCE_KEYS = {"url", "body_sha256", "author_login"}
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
COMMENT_URL = re.compile(
    r"^https://github\.com/(?P<repository>[^/\s]+/[^/\s]+)/issues/"
    r"(?P<number>[1-9][0-9]*)#issuecomment-(?P<comment>[1-9][0-9]*)$",
    re.ASCII,
)
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", re.ASCII)
MARKER = re.compile(
    rf"<!-- {AMENDMENT_MARKER}[ \t]*\n(?P<payload>[^\n]*)\n-->",
    re.ASCII,
)


def canonical_sha256(value: object) -> str:
    """Hash a JSON value with the canonical representation used by receipts."""
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def baseline_fingerprints(
    build: dict[str, Any], report: Report,
) -> dict[str, object] | None:
    """Derive immutable graph fingerprints from a validated receipt manifest."""
    tickets = build.get("tickets")
    if not isinstance(tickets, list) or any(not isinstance(item, dict) for item in tickets):
        report.error("execution amendment baseline tickets must be an array of objects")
        return None
    by_id: dict[str, dict[str, Any]] = {}
    for index, ticket in enumerate(tickets):
        logical_id = ticket.get("id")
        if not nonempty_string(logical_id):
            report.error(f"execution amendment baseline ticket[{index}] lacks an ID")
            continue
        assert isinstance(logical_id, str)
        if logical_id in by_id:
            report.error(f"execution amendment baseline duplicates ticket {logical_id}")
        by_id[logical_id] = ticket
    if report.errors:
        return None

    member_ids = sorted(by_id)
    edges: list[dict[str, str]] = []
    mappings: dict[str, dict[str, Any]] = {}
    for logical_id, ticket in sorted(by_id.items()):
        dependencies = ticket.get("depends_on")
        if not isinstance(dependencies, list) or any(
            not nonempty_string(item) for item in dependencies
        ):
            report.error(f"execution amendment baseline {logical_id}.depends_on is invalid")
            continue
        if len(dependencies) != len(set(dependencies)):
            report.error(f"execution amendment baseline {logical_id}.depends_on has duplicates")
        edges.extend(
            {"ticket_id": logical_id, "depends_on": dependency}
            for dependency in sorted(dependencies)
        )
        mapping = ticket.get("github")
        if not isinstance(mapping, dict):
            report.error(f"execution amendment baseline {logical_id} lacks a GitHub mapping")
        else:
            mappings[logical_id] = mapping
    if report.errors:
        return None
    edges.sort(key=lambda item: (item["ticket_id"], item["depends_on"]))
    return {
        "member_count": len(member_ids),
        "dependency_edge_count": len(edges),
        "member_ids_sha256": canonical_sha256(member_ids),
        "dependency_edges_sha256": canonical_sha256(edges),
        "ticket_github_mappings_sha256": canonical_sha256(mappings),
    }


def validate_amendment_schema(
    amendment: dict[str, Any], authority: ReceiptAuthority, report: Report,
) -> bool:
    """Validate one additive amendment against immutable receipt authority."""
    if strict_object(amendment, "execution amendment", AMENDMENT_KEYS, report) is None:
        return False
    if amendment.get("schema_version") != 1:
        report.error("execution amendment schema_version must equal integer 1")
    if amendment.get("amendment_id") != AMENDMENT_ID:
        report.error(f"execution amendment amendment_id must equal {AMENDMENT_ID}")
    if amendment.get("build_order_id") != authority.root_id:
        report.error("execution amendment build_order_id must equal receipt authority")
    if amendment.get("plan_version") != authority.plan_version:
        report.error("execution amendment plan_version must equal receipt authority")
    receipt_commit = amendment.get("publication_receipt_commit")
    if not isinstance(receipt_commit, str) or not SHA.fullmatch(receipt_commit):
        report.error("execution amendment publication_receipt_commit must be a Git SHA")
    if not valid_rfc3339_utc(amendment.get("recorded_at")):
        report.error("execution amendment recorded_at must be an RFC3339 UTC instant")
    _validate_policy_authority(amendment.get("policy_authority"), report)

    build = authority.receipt_manifests.get("build-order.json")
    publication = authority.receipt_manifests.get("publication.json")
    if not isinstance(build, dict) or not isinstance(publication, dict):
        report.error("execution amendment requires immutable publication manifests")
        return False
    _validate_baseline(amendment.get("baseline"), build, report)
    _validate_policy(amendment.get("policy"), report)
    member_ids = _member_ids(build, report)
    _validate_lanes(amendment, member_ids, report)
    affected, completed = _validate_member_partitions(amendment, member_ids, report)
    authors = _validate_authors(amendment.get("authorized_comment_authors"), report)

    expected_decision_sha = decision_sha256(amendment)
    observed_decision_sha = amendment.get("decision_sha256")
    if observed_decision_sha != expected_decision_sha:
        report.error(
            "execution amendment decision_sha256 must match the canonical decision"
        )

    mappings = _receipt_mappings(build, report)
    root_mapping = build.get("github_root")
    if not isinstance(root_mapping, dict):
        report.error("execution amendment requires the immutable root mapping")
    else:
        _validate_comment_evidence(
            amendment.get("authorization_comment"), authority.root_id,
            root_mapping, authors, render_authorization_comment(amendment),
            "execution amendment authorization comment", report,
        )

    comments = amendment.get("ticket_amendment_comments")
    if not isinstance(comments, dict):
        report.error("execution amendment ticket_amendment_comments must be an object")
    else:
        if set(comments) != affected:
            report.error(
                "execution amendment ticket comments must exactly cover affected tickets"
            )
        seen_urls: set[str] = set()
        root_evidence = amendment.get("authorization_comment")
        if isinstance(root_evidence, dict) and isinstance(root_evidence.get("url"), str):
            seen_urls.add(root_evidence["url"])
        for logical_id in sorted(set(comments) | affected):
            evidence = comments.get(logical_id)
            mapping = mappings.get(logical_id)
            if mapping is None:
                report.error(f"execution amendment comment {logical_id} lacks a mapping")
                continue
            _validate_comment_evidence(
                evidence, logical_id, mapping, authors,
                render_ticket_amendment_comment(amendment, logical_id),
                f"execution amendment comment for {logical_id}", report,
            )
            if isinstance(evidence, dict) and isinstance(evidence.get("url"), str):
                if evidence["url"] in seen_urls:
                    report.error(
                        f"execution amendment comment URL is reused: {evidence['url']}"
                    )
                seen_urls.add(evidence["url"])

    # A late lane cannot silently be moved into the already-completed partition.
    lane_ids = {item for values in EXPECTED_LANES.values() for item in values}
    if not lane_ids <= affected:
        report.error("all five lane members must be affected execution tickets")
    if lane_ids & completed:
        report.error("lane members cannot be completed-before-amendment tickets")
    return not report.errors


def decision_sha256(amendment: dict[str, Any]) -> str:
    """Bind comment evidence to the complete execution decision."""
    value = {
        "baseline": amendment.get("baseline"),
        "policy_authority": amendment.get("policy_authority"),
        "policy": amendment.get("policy"),
        "lanes": amendment.get("lanes"),
        "affected_ticket_ids": amendment.get("affected_ticket_ids"),
        "completed_before_amendment_ticket_ids": amendment.get(
            "completed_before_amendment_ticket_ids"
        ),
    }
    return canonical_sha256(value)


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


def load_amendment_at_commit(
    amendment_path: Path, amendment_commit: str, report: Report,
) -> dict[str, Any] | None:
    """Load exact committed amendment bytes and reject mutable-source drift."""
    root = repository_root(amendment_path, report)
    if root is None:
        return None
    if not isinstance(amendment_commit, str) or not SHA.fullmatch(amendment_commit):
        report.error("amendment_commit must be a 40-character Git SHA")
        return None
    if not exact_commit(root, amendment_commit, "amendment_commit", report):
        return None
    relative = repository_relative(amendment_path, root, report)
    if relative is None:
        return None
    budget = ReceiptBlobBudget(files_remaining=1, bytes_remaining=2 * 1024 * 1024)
    committed = _commit_blob(
        root, amendment_commit, relative, "execution amendment", budget, report,
    )
    try:
        mode = amendment_path.lstat().st_mode
        current = amendment_path.read_bytes()
    except OSError as exc:
        report.error(f"cannot read current execution amendment: {exc}")
        return None
    if not stat.S_ISREG(mode) or amendment_path.is_symlink():
        report.error("current execution amendment must be a regular non-symlink file")
        return None
    if committed is None:
        return None
    if current != committed:
        report.error("current execution amendment must equal amendment_commit bytes")
        return None
    try:
        value = json.loads(committed.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        report.error(f"execution amendment must be valid UTF-8 JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error("execution amendment must be a JSON object")
        return None
    return value


def validate_policy_authority_source(
    amendment_path: Path, amendment: dict[str, Any], report: Report,
) -> None:
    """Prove the supplied policy commit contains the exact authorized document."""
    value = amendment.get("policy_authority")
    if not isinstance(value, dict):
        report.error("execution amendment policy_authority is unavailable")
        return
    commit, document = value.get("commit"), value.get("document")
    wanted_sha = value.get("document_sha256")
    root = repository_root(amendment_path, report)
    if root is None or not isinstance(commit, str):
        return
    if not exact_commit(root, commit, "policy_authority.commit", report):
        return
    policy_path = amendment_path.parent / str(document)
    relative = repository_relative(policy_path, root, report)
    if relative is None:
        return
    budget = ReceiptBlobBudget(files_remaining=1, bytes_remaining=2 * 1024 * 1024)
    committed = _commit_blob(
        root, commit, relative, "execution amendment policy document", budget, report,
    )
    if committed is None:
        return
    observed_sha = hashlib.sha256(committed).hexdigest()
    if observed_sha != wanted_sha:
        report.error("policy authority document hash does not match the supplied receipt")
    try:
        current = policy_path.read_bytes()
        mode = policy_path.lstat().st_mode
    except OSError as exc:
        report.error(f"cannot read current policy authority document: {exc}")
        return
    if not stat.S_ISREG(mode) or policy_path.is_symlink():
        report.error("current policy authority document must be regular and non-symlinked")
    elif current != committed:
        report.error("current policy authority document must equal policy commit bytes")


def _validate_baseline(
    value: object, build: dict[str, Any], report: Report,
) -> None:
    baseline = strict_object(value, "execution amendment baseline", BASELINE_KEYS, report)
    if baseline is None:
        return
    computed = baseline_fingerprints(build, report)
    if computed is None:
        return
    immutable = {
        "member_count": EXPECTED_MEMBER_COUNT,
        "dependency_edge_count": EXPECTED_EDGE_COUNT,
        "member_ids_sha256": EXPECTED_MEMBER_IDS_SHA256,
        "dependency_edges_sha256": EXPECTED_DEPENDENCY_EDGES_SHA256,
        "ticket_github_mappings_sha256": EXPECTED_TICKET_MAPPINGS_SHA256,
    }
    if computed != immutable:
        report.error("immutable publication receipt does not match the 54/105 baseline")
    if baseline != computed:
        report.error("execution amendment baseline must equal immutable receipt fingerprints")


def _validate_policy(value: object, report: Report) -> None:
    policy = strict_object(value, "execution amendment policy", POLICY_KEYS, report)
    if policy is not None and policy != EXPECTED_POLICY:
        report.error("execution amendment policy must equal the exact develop-head policy")


def _validate_policy_authority(value: object, report: Report) -> None:
    authority = strict_object(
        value, "execution amendment policy_authority", POLICY_AUTHORITY_KEYS, report,
    )
    expected = {
        "commit": POLICY_AUTHORITY_COMMIT,
        "document": POLICY_AUTHORITY_DOCUMENT,
        "document_sha256": POLICY_AUTHORITY_DOCUMENT_SHA256,
    }
    if authority is not None and authority != expected:
        report.error("execution amendment policy_authority must equal the supplied receipt")


def _validate_lanes(
    amendment: dict[str, Any], member_ids: set[str], report: Report,
) -> None:
    lanes = amendment.get("lanes")
    if not isinstance(lanes, dict):
        report.error("execution amendment lanes must be an object")
        return
    if lanes != EXPECTED_LANES:
        report.error("execution amendment lanes must equal the authorized five-lane map")
    values = [item for members in lanes.values() if isinstance(members, list) for item in members]
    if len(values) != 23 or len(set(values)) != 23:
        report.error("execution amendment lanes must uniquely partition exactly 23 tickets")
    if not set(values) <= member_ids:
        report.error("execution amendment lanes contain non-member tickets")
    observed_hash = amendment.get("lane_mapping_sha256")
    if observed_hash != canonical_sha256(lanes) or observed_hash != EXPECTED_LANE_MAPPING_SHA256:
        report.error("execution amendment lane_mapping_sha256 is invalid")


def _validate_member_partitions(
    amendment: dict[str, Any], member_ids: set[str], report: Report,
) -> tuple[set[str], set[str]]:
    affected_values = string_list(
        amendment.get("affected_ticket_ids"),
        "execution amendment affected_ticket_ids", report,
    )
    completed_values = string_list(
        amendment.get("completed_before_amendment_ticket_ids"),
        "execution amendment completed_before_amendment_ticket_ids", report,
    )
    if affected_values != sorted(affected_values):
        report.error("execution amendment affected_ticket_ids must be sorted")
    if completed_values != sorted(completed_values):
        report.error(
            "execution amendment completed_before_amendment_ticket_ids must be sorted"
        )
    affected, completed = set(affected_values), set(completed_values)
    if affected & completed:
        report.error("execution amendment affected/completed partitions overlap")
    if affected | completed != member_ids:
        report.error("execution amendment affected/completed partitions must cover 54 members")
    if affected != EXPECTED_AFFECTED_IDS:
        report.error(
            "execution amendment affected tickets must equal the authorized 19+23 set"
        )
    return affected, completed


def _validate_authors(value: object, report: Report) -> set[str]:
    authors = string_list(value, "execution amendment authorized_comment_authors", report)
    if not authors:
        report.error("execution amendment requires an authorized comment author")
    if authors != sorted(authors):
        report.error("execution amendment authorized_comment_authors must be sorted")
    for author in authors:
        if LOGIN.fullmatch(author) is None:
            report.error(f"execution amendment comment author is invalid: {author}")
    return set(authors)


def _validate_comment_evidence(
    value: object, logical_id: str, mapping: dict[str, Any], authors: set[str],
    rendered: str, label: str, report: Report,
) -> None:
    evidence = strict_object(value, label, COMMENT_EVIDENCE_KEYS, report)
    if evidence is None:
        return
    url = evidence.get("url")
    match = COMMENT_URL.fullmatch(url) if isinstance(url, str) else None
    if (
        match is None
        or match.group("repository") != mapping.get("repository")
        or int(match.group("number")) != mapping.get("number")
    ):
        report.error(f"{label} URL must belong to mapped issue {logical_id}")
    digest = evidence.get("body_sha256")
    if not isinstance(digest, str) or not BODY_SHA.fullmatch(digest):
        report.error(f"{label} body_sha256 must be a lowercase SHA-256")
    elif digest != hashlib.sha256(rendered.encode("utf-8")).hexdigest():
        report.error(f"{label} body_sha256 must match the canonical rendered comment")
    author = evidence.get("author_login")
    if author not in authors:
        report.error(f"{label} author_login is not authorized")


def _member_ids(build: dict[str, Any], report: Report) -> set[str]:
    tickets = build.get("tickets")
    if not isinstance(tickets, list):
        report.error("execution amendment receipt tickets are unavailable")
        return set()
    result = {
        ticket.get("id") for ticket in tickets
        if isinstance(ticket, dict) and isinstance(ticket.get("id"), str)
    }
    if len(result) != len(tickets):
        report.error("execution amendment receipt ticket IDs are ambiguous")
    return result


def _receipt_mappings(
    build: dict[str, Any], report: Report,
) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    tickets = build.get("tickets")
    if not isinstance(tickets, list):
        return result
    for ticket in tickets:
        if not isinstance(ticket, dict):
            continue
        logical_id, mapping = ticket.get("id"), ticket.get("github")
        if isinstance(logical_id, str) and isinstance(mapping, dict):
            result[logical_id] = mapping
        elif isinstance(logical_id, str):
            report.error(f"execution amendment receipt mapping missing for {logical_id}")
    return result


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
