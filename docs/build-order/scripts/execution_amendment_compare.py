"""Compare a captured live execution snapshot with the approved amendment."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from execution_amendment import (
    lane_for_ticket,
    parse_execution_comment,
    render_authorization_comment,
    render_ticket_amendment_comment,
)
from publication_common import Report
from publication_labels import routing_subset
from publication_live_graph import LiveGraphError, _mapping_tuple
from publication_receipt_authority import ReceiptAuthority


@dataclass(frozen=True)
class ExecutionSnapshot:
    issues: tuple[tuple[str, str], ...]
    auxiliary_issues: tuple[tuple[str, str], ...]
    marker_matches: tuple[tuple[str, tuple[tuple[tuple[str, Any], ...], ...]], ...]
    root_members: tuple[str, ...]
    parents: tuple[tuple[str, str | None], ...]
    nested_subissues: tuple[tuple[str, tuple[str, ...]], ...]
    internal_edges: tuple[tuple[str, str], ...]
    external_edges: tuple[tuple[str, str], ...]
    comments: tuple[tuple[str, str], ...]


def compare_execution_snapshot(
    snapshot: ExecutionSnapshot,
    authority: ReceiptAuthority,
    amendment: dict[str, Any],
    report: Report,
) -> bool:
    build = authority.receipt_manifests.get("build-order.json")
    publication = authority.receipt_manifests.get("publication.json")
    if not isinstance(build, dict) or not isinstance(publication, dict):
        report.error("execution snapshot requires immutable publication manifests")
        return False
    tickets = _tickets(build)
    root_id = authority.root_id
    expected_ids = {root_id, *tickets}
    issues = {logical_id: json.loads(value) for logical_id, value in snapshot.issues}
    if set(issues) != expected_ids:
        report.error("live execution issues must exactly cover root plus 54 members")
        return False

    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    publication_receipt = publication.get("github_reconciliation")
    auxiliary_mappings = (
        publication_receipt.get("issue_mappings")
        if isinstance(publication_receipt, dict) else None
    )
    wanted_skill_mapping = (
        auxiliary_mappings.get(skill_id)
        if isinstance(auxiliary_mappings, dict) and isinstance(skill_id, str) else None
    )
    auxiliary = {
        logical_id: json.loads(value)
        for logical_id, value in snapshot.auxiliary_issues
    }
    if not isinstance(skill_id, str) or set(auxiliary) != {skill_id}:
        report.error("live execution auxiliary snapshot must cover the skill blocker")
    else:
        skill_live = auxiliary[skill_id]
        if skill_live.get("mapping") != wanted_skill_mapping:
            report.error("live execution skill blocker mapping drifted")
        expected_skill_titles = (
            publication_receipt.get("observed_issue_titles")
            if isinstance(publication_receipt, dict) else None
        )
        expected_skill_bodies = (
            publication_receipt.get("observed_body_evidence")
            if isinstance(publication_receipt, dict) else None
        )
        expected_skill_labels = (
            publication_receipt.get("observed_labels")
            if isinstance(publication_receipt, dict) else None
        )
        expected_skill_title = (
            expected_skill_titles.get(skill_id)
            if isinstance(expected_skill_titles, dict) else None
        )
        expected_skill_body = (
            expected_skill_bodies.get(skill_id)
            if isinstance(expected_skill_bodies, dict) else None
        )
        expected_skill_body_sha = (
            expected_skill_body.get("body_sha256")
            if isinstance(expected_skill_body, dict) else None
        )
        expected_skill_routing = (
            expected_skill_labels.get(skill_id)
            if isinstance(expected_skill_labels, dict) else None
        )
        if skill_live.get("title") != expected_skill_title:
            report.error("live execution skill blocker title drifted")
        if skill_live.get("body_sha256") != expected_skill_body_sha:
            report.error("live execution skill blocker body drifted")
        if _static_routing(skill_live.get("labels")) != _static_routing(
            expected_skill_routing
        ):
            report.error("live execution skill blocker routing labels drifted")
        if not _valid_execution_state(
            skill_live.get("state"), skill_live.get("state_reason")
        ):
            report.error("live execution skill blocker has an invalid lifecycle state")
        if skill_live.get("locked") is not False:
            report.error("live execution skill blocker must remain unlocked")

    receipt = build.get("github_reconciliation")
    if not isinstance(receipt, dict):
        report.error("execution snapshot requires the immutable core receipt")
        return False
    expected_titles = receipt.get("observed_issue_titles")
    expected_bodies = receipt.get("observed_body_evidence")
    expected_labels = receipt.get("observed_labels")
    mappings = {root_id: build.get("github_root")}
    mappings.update({logical_id: ticket.get("github") for logical_id, ticket in tickets.items()})

    affected = set(amendment.get("affected_ticket_ids", []))
    completed_before = set(amendment.get("completed_before_amendment_ticket_ids", []))
    terminal_members: set[str] = set()
    for logical_id, live in sorted(issues.items()):
        if live.get("mapping") != mappings.get(logical_id):
            report.error(f"live execution mapping drifted for {logical_id}")
        title = expected_titles.get(logical_id) if isinstance(expected_titles, dict) else None
        if live.get("title") != title:
            report.error(f"live execution title drifted for {logical_id}")
        evidence = expected_bodies.get(logical_id) if isinstance(expected_bodies, dict) else None
        expected_body_sha = evidence.get("body_sha256") if isinstance(evidence, dict) else None
        if live.get("body_sha256") != expected_body_sha:
            report.error(f"live execution issue body drifted for {logical_id}")
        wanted_labels = expected_labels.get(logical_id) if isinstance(expected_labels, dict) else None
        wanted_static = _static_routing(wanted_labels)
        observed_static = _static_routing(live.get("labels"))
        if observed_static != wanted_static:
            report.error(f"live execution static routing labels drifted for {logical_id}")
        if live.get("locked") is not False:
            report.error(f"live execution issue {logical_id} must remain unlocked")
        state, reason = live.get("state"), live.get("state_reason")
        if logical_id == root_id:
            if not _valid_execution_state(state, reason):
                report.error("live execution root has an invalid terminal state")
            continue
        if logical_id in completed_before:
            if state != "CLOSED" or reason != "completed":
                report.error(
                    f"pre-amendment completed ticket {logical_id} must remain completed"
                )
        elif logical_id in affected:
            if not _valid_execution_state(state, reason):
                report.error(f"affected ticket {logical_id} has an invalid execution state")
        else:
            report.error(f"live execution ticket {logical_id} lacks an amendment partition")
        if state == "CLOSED" and reason == "completed":
            terminal_members.add(logical_id)

    root = issues[root_id]
    if root.get("state") == "CLOSED" and terminal_members != set(tickets):
        report.error("Build Order root may close only after all 54 members complete")
    live_open = {
        logical_id for logical_id, value in issues.items()
        if logical_id != root_id and value.get("state") == "OPEN"
    }
    if not live_open <= affected:
        report.error("every live-open ticket must be in affected_ticket_ids")

    if set(snapshot.root_members) != set(tickets) or len(snapshot.root_members) != 54:
        report.error("live execution root membership must remain exactly 54 tickets")
    parents = dict(snapshot.parents)
    if parents.get(root_id) is not None:
        report.error("live execution root must not have a parent")
    for logical_id in tickets:
        if parents.get(logical_id) != root_id:
            report.error(f"live execution parent drifted for {logical_id}")
    for logical_id, nested in snapshot.nested_subissues:
        if nested:
            report.error(f"live execution member {logical_id} must not have subissues")

    expected_internal = {
        (logical_id, dependency)
        for logical_id, ticket in tickets.items()
        for dependency in ticket.get("depends_on", [])
    }
    if set(snapshot.internal_edges) != expected_internal or len(snapshot.internal_edges) != 105:
        report.error("live execution internal dependency graph must remain exactly 105 edges")
    expected_external = {
        (item.get("blocked_ticket_id"), item.get("blocker_issue_id"))
        for item in publication.get("external_blocker_relations", [])
        if isinstance(item, dict)
    }
    if set(snapshot.external_edges) != expected_external:
        report.error("live execution external blocker relations drifted")

    expected_matches = {
        logical_id: (_mapping_tuple(mapping),)
        for logical_id, mapping in mappings.items() if isinstance(mapping, dict)
    }
    if dict(snapshot.marker_matches) != expected_matches:
        report.error("live execution planning-marker mappings drifted")
    _compare_comments(snapshot, amendment, report)
    return not report.errors


def _compare_comments(
    snapshot: ExecutionSnapshot, amendment: dict[str, Any], report: Report,
) -> None:
    expected: dict[str, Any] = {
        amendment.get("build_order_id"): amendment.get("authorization_comment")
    }
    ticket_comments = amendment.get("ticket_amendment_comments")
    if isinstance(ticket_comments, dict):
        expected.update(ticket_comments)
    observed = {logical_id: json.loads(value) for logical_id, value in snapshot.comments}
    if set(observed) != set(expected):
        report.error("live execution comments must exactly cover amendment evidence")
        return
    for logical_id, evidence in sorted(expected.items()):
        record = observed[logical_id]
        exact = record.get("exact")
        marked = record.get("marked")
        rendered = (
            render_authorization_comment(amendment)
            if logical_id == amendment.get("build_order_id")
            else render_ticket_amendment_comment(amendment, logical_id)
        )
        if not isinstance(exact, dict) or not isinstance(evidence, dict):
            report.error(f"live execution comment evidence is invalid for {logical_id}")
            continue
        wanted = {
            "url": evidence.get("url"),
            "body": rendered,
            "body_sha256": evidence.get("body_sha256"),
            "author_login": evidence.get("author_login"),
        }
        for field, value in wanted.items():
            if exact.get(field) != value:
                report.error(f"live execution comment {logical_id}.{field} drifted")
        if not isinstance(marked, list) or len(marked) != 1 or marked[0] != exact:
            report.error(
                f"live execution issue {logical_id} must contain exactly one amendment marker"
            )
        marker_report = Report()
        marker = parse_execution_comment(rendered, f"expected comment {logical_id}", marker_report)
        _merge(marker_report, report)
        if marker is None:
            continue
        if marker.get("logical_id") != logical_id:
            report.error(f"live execution comment marker logical_id drifted for {logical_id}")
        if marker.get("decision_sha256") != amendment.get("decision_sha256"):
            report.error(f"live execution comment decision hash drifted for {logical_id}")
        if marker.get("lane_id") != lane_for_ticket(amendment, logical_id):
            report.error(f"live execution comment lane drifted for {logical_id}")


def _valid_execution_state(state: object, reason: object) -> bool:
    return (
        (state == "OPEN" and reason in (None, "reopened"))
        or (state == "CLOSED" and reason == "completed")
    )


def _static_routing(value: object) -> set[str]:
    if not isinstance(value, (list, tuple)):
        return set()
    return {
        label for label in routing_subset({item for item in value if isinstance(item, str)})
        if not label.casefold().startswith("agent:")
    }


def _tickets(build: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = build.get("tickets")
    if not isinstance(values, list):
        raise LiveGraphError("immutable receipt tickets are unavailable")
    result = {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if len(result) != len(values):
        raise LiveGraphError("immutable receipt ticket identities are ambiguous")
    return result


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.warnings.extend(source.warnings)
