"""Validate the materialized root and skill-delivery receipt."""

from __future__ import annotations

from typing import Any

from publication_common import (
    SHA,
    Report,
    github_mapping,
    nonempty_string,
    strict_object,
    string_list,
    valid_rfc3339_utc,
)
from publication_parenthood import validate_parent_map
from publication_comment import validate_pending_comment_matches
from publication_labels import routing_subset, validate_routing_labels


RECEIPT_KEYS = {
    "receipt_schema_version", "checked_at", "issue_mappings",
    "external_blocker_relations",
    "observed_labels", "observed_parent_issues",
    "observed_issue_states",
    "observed_body_evidence", "marker_query_matches",
    "expected_issue_titles", "observed_issue_titles",
    "root_reconciliation_comment_matches",
}
EDGE_KEYS = {"blocked_ticket_id", "blocker_issue_id"}


def validate_auxiliary_receipt(
    data: dict[str, Any],
    root_id: object,
    skill_id: object,
    expected_edges: set[tuple[str, str]],
    core: dict[str, Any],
    repository: str,
    companion_approved: object,
    companion_materialized: bool,
    read_only: set[tuple[str, int]],
    report: Report,
) -> None:
    value = data.get("github_reconciliation")
    materialized = companion_materialized or value is not None
    if not materialized:
        return
    if value is None:
        report.error("materialized publication requires publication.github_reconciliation")
        return
    receipt = strict_object(
        value, "publication.github_reconciliation", RECEIPT_KEYS, report
    )
    if receipt is None:
        return
    if receipt.get("receipt_schema_version") != 2:
        report.error(
            "publication.github_reconciliation.receipt_schema_version must be integer 2"
        )
    if not valid_rfc3339_utc(receipt.get("checked_at")):
        report.error(
            "publication.github_reconciliation.checked_at must be an RFC3339 UTC instant"
        )
    ids = [item for item in (root_id, skill_id) if isinstance(item, str)]
    mappings = _mappings(receipt.get("issue_mappings"), ids, repository, report)
    _core_contract(root_id, mappings, core, report)
    combined = {key: value for key, value in core.items() if key != "github_root"}
    combined.update(mappings)
    _unique_mappings(combined, report)
    _reject_read_only_mappings(combined, read_only, report)
    observed = parse_edges(
        receipt.get("external_blocker_relations"), "publication receipt edges", report
    )
    if observed != expected_edges:
        report.error("publication receipt relationships must exactly match the manifest")
    _observed_labels(data, receipt.get("observed_labels"), ids, report)
    validate_parent_map(
        receipt.get("observed_parent_issues"), set(ids),
        "publication.github_reconciliation.observed_parent_issues", report,
    )
    validate_pending_comment_matches(
        receipt.get("root_reconciliation_comment_matches"), root_id, mappings,
        data.get("plan_version"), data.get("approved_planning_commit"), report,
    )
    approved = data.get("approved_planning_commit")
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("publication receipt requires approved_planning_commit")
    if approved != companion_approved:
        report.error("publication receipt approved commit must match companions")


def parse_edges(
    value: object, label: str, report: Report
) -> set[tuple[str, str]]:
    if not isinstance(value, list):
        report.error(f"{label} must be an array")
        return set()
    found: set[tuple[str, str]] = set()
    for index, value in enumerate(value):
        edge = strict_object(value, f"{label}[{index}]", EDGE_KEYS, report)
        if edge is None:
            continue
        pair = (edge.get("blocked_ticket_id"), edge.get("blocker_issue_id"))
        if not all(nonempty_string(item) for item in pair):
            report.error(f"{label}[{index}] values must be non-empty strings")
        elif pair in found:
            report.error(f"{label} contains duplicate relationship {pair[0]}<-{pair[1]}")
        else:
            found.add(pair)
    return found


def _core_contract(
    root_id: object,
    mappings: dict[str, dict[str, Any]],
    core: dict[str, Any],
    report: Report,
) -> None:
    if isinstance(root_id, str) and root_id in mappings and core.get("github_root") != mappings[root_id]:
        report.error("publication root mapping must match build-order github_root")
    for ticket_id in ("BO-004", "BO-008"):
        if core.get(ticket_id) is None:
            report.error(
                f"publication relationship requires materialized {ticket_id} mapping"
            )


def _mappings(
    value: object, ids: list[str], repository: str, report: Report
) -> dict[str, dict[str, Any]]:
    if not isinstance(value, dict):
        report.error("publication receipt issue_mappings must be an object")
        return {}
    if set(value) != set(ids):
        report.error("publication receipt issue_mappings keys must match root and skill IDs")
    mappings: dict[str, dict[str, Any]] = {}
    for item in ids:
        mapping = github_mapping(
            value.get(item), f"publication mapping {item}", repository, report
        )
        if mapping is None:
            report.error(f"publication mapping {item} must be materialized")
        else:
            mappings[item] = mapping
    return mappings


def _unique_mappings(mappings: dict[str, Any], report: Report) -> None:
    identities: dict[tuple[object, object], str] = {}
    nodes: dict[object, str] = {}
    for label, mapping in mappings.items():
        if not isinstance(mapping, dict):
            continue
        identity = (mapping.get("repository"), mapping.get("number"))
        node = mapping.get("node_id")
        if identity in identities:
            report.error(f"publication mapping {label} duplicates {identities[identity]}")
        identities[identity] = label
        if node in nodes:
            report.error(f"publication mapping {label} duplicates node_id from {nodes[node]}")
        nodes[node] = label


def _reject_read_only_mappings(
    mappings: dict[str, Any], read_only: set[tuple[str, int]], report: Report,
) -> None:
    for logical_id, mapping in mappings.items():
        if not isinstance(mapping, dict):
            continue
        identity = (mapping.get("repository"), mapping.get("number"))
        if identity in read_only:
            report.error(
                f"publication mapping {logical_id} reuses protected read-only "
                f"issue {identity[0]}#{identity[1]}"
            )


def _observed_labels(
    data: dict[str, Any], value: object, ids: list[str], report: Report
) -> None:
    if not isinstance(value, dict) or set(value) != set(ids):
        report.error("publication receipt observed_labels keys must match root and skill IDs")
        return
    root, skill = data.get("root_issue"), data.get("skill_issue")
    if not isinstance(root, dict) or not isinstance(skill, dict):
        return
    issues = {root.get("logical_id"): root, skill.get("logical_id"): skill}
    for logical_id in ids:
        issue = issues.get(logical_id)
        if isinstance(issue, dict):
            _one_label_set(logical_id, value.get(logical_id), issue, report)


def _one_label_set(
    logical_id: str, value: object, issue: dict[str, Any], report: Report
) -> None:
    labels = set(string_list(value, f"observed_labels.{logical_id}", report))
    required = set(issue["required_labels"])
    missing = required - labels
    if missing:
        report.error(
            f"publication labels missing for {logical_id}: " + ", ".join(sorted(missing))
        )
    validate_routing_labels(
        labels, routing_subset(required), f"publication labels for {logical_id}", report
    )
