"""Validate the all-or-nothing companion publication receipt."""

from __future__ import annotations

from typing import Any

from publication_common import (
    BO_ID,
    SHA,
    Report,
    nonempty_string,
    strict_object,
    string_list,
    valid_rfc3339_utc,
)
from publication_parenthood import validate_parent_map
from publication_labels import validate_routing_labels


RECEIPT_KEYS = {
    "checked_at", "dependency_edges", "observed_labels", "observed_parent_issues",
    "observed_body_evidence",
    "expected_issue_titles", "observed_issue_titles",
    "marker_query_matches",
}
EDGE_KEYS = {"ticket_id", "depends_on"}


def validate_receipt(
    data: dict[str, Any], dash: dict[str, dict[str, Any]],
    mappings: dict[str, Any], globally_materialized: bool, report: Report,
) -> None:
    value = data.get("github_reconciliation")
    materialized = (
        globally_materialized
        or value is not None
        or any(mappings.get(item) is not None for item in dash)
    )
    if not materialized:
        return
    _mapping_completeness(data, dash, mappings, report)
    receipt = strict_object(value, "github_reconciliation", RECEIPT_KEYS, report)
    if receipt is None:
        report.error("materialized companions require github_reconciliation")
        return
    if not valid_rfc3339_utc(receipt.get("checked_at")):
        report.error("github_reconciliation.checked_at must be an RFC3339 UTC instant")
    expected = _expected_edges(dash)
    actual = _receipt_edges(receipt.get("dependency_edges"), report)
    if actual != expected:
        report.error("github_reconciliation dependencies must exactly match companion blockers")
    _labels(data, dash, receipt.get("observed_labels"), report)
    validate_parent_map(
        receipt.get("observed_parent_issues"), set(dash),
        "github_reconciliation.observed_parent_issues", report,
    )


def _mapping_completeness(
    data: dict[str, Any], dash: dict[str, dict[str, Any]],
    mappings: dict[str, Any], report: Report,
) -> None:
    missing_dash = sorted(item for item in dash if mappings.get(item) is None)
    if missing_dash:
        report.error("materialized companions require all DASH mappings: " + ", ".join(missing_dash))
    referenced_bo = {
        dependency for ticket in dash.values() for dependency in ticket.get("depends_on", [])
        if isinstance(dependency, str) and BO_ID.fullmatch(dependency)
    }
    missing_bo = sorted(item for item in referenced_bo if mappings.get(item) is None)
    if missing_bo:
        report.error("materialized companions require referenced BO mappings: " + ", ".join(missing_bo))
    approved = data.get("approved_planning_commit")
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("materialized companions require approved_planning_commit")


def _expected_edges(dash: dict[str, dict[str, Any]]) -> set[tuple[str, str]]:
    return {
        (ticket_id, dependency)
        for ticket_id, ticket in dash.items()
        for dependency in ticket.get("depends_on", []) + ticket.get("external_blockers", [])
        if isinstance(dependency, str)
    }


def _receipt_edges(value: object, report: Report) -> set[tuple[str, str]]:
    if not isinstance(value, list):
        report.error("github_reconciliation.dependency_edges must be an array")
        return set()
    found: set[tuple[str, str]] = set()
    for index, value in enumerate(value):
        label = f"github_reconciliation.dependency_edges[{index}]"
        edge = strict_object(value, label, EDGE_KEYS, report)
        if edge is None:
            continue
        pair = (edge.get("ticket_id"), edge.get("depends_on"))
        if not all(nonempty_string(item) for item in pair):
            report.error(f"{label} values must be strings")
        elif pair in found:
            report.error(f"github_reconciliation contains duplicate dependency {pair[0]}->{pair[1]}")
        else:
            found.add(pair)
    return found


def _labels(
    data: dict[str, Any], dash: dict[str, dict[str, Any]],
    value: object, report: Report,
) -> None:
    if not isinstance(value, dict):
        report.error("github_reconciliation.observed_labels must be an object")
        return
    if set(value) != set(dash):
        report.error("github_reconciliation.observed_labels keys must match DASH tickets")
    required = set(data.get("required_labels", []))
    for ticket_id, ticket in dash.items():
        labels = set(string_list(
            value.get(ticket_id), f"github_reconciliation.observed_labels.{ticket_id}", report
        ))
        expected = required | {f"complexity:{ticket.get('complexity_points')}"}
        validate_routing_labels(
            labels, expected, f"github_reconciliation labels for {ticket_id}", report
        )
