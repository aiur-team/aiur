"""Validate a bounded receipt from a fresh GitHub graph requery."""

from __future__ import annotations

from typing import Any

from validation_common import (
    Report,
    checked_string_list,
    nonempty_string,
    safe_list,
    strict_object,
    valid_rfc3339_utc,
)
from validation_github_evidence import (
    validate_body_evidence,
    validate_marker_query_matches,
)
from validation_github_approved import ApprovedIssueExpectations


RECONCILIATION_KEYS = {
    "receipt_schema_version",
    "checked_at",
    "approved_planning_commit",
    "root_node_id",
    "member_ticket_ids",
    "dependency_edges",
    "projected_labels",
    "observed_labels",
    "expected_issue_titles",
    "observed_issue_titles",
    "observed_issue_states",
    "observed_body_evidence",
    "marker_query_matches",
}
DEPENDENCY_KEYS = {"ticket_id", "depends_on"}


def validate_reconciliation(
    data: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    root: dict[str, Any] | None,
    ticket_mappings: dict[str, dict[str, Any] | None],
    report: Report,
    approved_expectations: ApprovedIssueExpectations | None = None,
) -> None:
    value = data.get("github_reconciliation")
    any_mapping = root is not None or any(item is not None for item in ticket_mappings.values())
    if value is None:
        if any_mapping:
            report.error("materialized GitHub identities require github_reconciliation")
        return
    receipt = strict_object(value, "github_reconciliation", RECONCILIATION_KEYS, report)
    if receipt is None:
        return
    if receipt.get("receipt_schema_version") != 3:
        report.error("github_reconciliation.receipt_schema_version must be integer 3")
    if root is None:
        report.error("github_reconciliation requires github_root")
    missing = sorted(ticket_id for ticket_id, item in ticket_mappings.items() if item is None)
    if missing:
        report.error("github_reconciliation missing ticket mappings: " + ", ".join(missing))
    if not valid_rfc3339_utc(receipt.get("checked_at")):
        report.error("github_reconciliation.checked_at must be an RFC3339 UTC instant")
    root_node_id = receipt.get("root_node_id")
    if not nonempty_string(root_node_id):
        report.error("github_reconciliation.root_node_id must be a non-empty string")
    elif root is not None and root_node_id != root.get("node_id"):
        report.error("github_reconciliation.root_node_id does not match github_root")
    members = checked_string_list(
        receipt.get("member_ticket_ids"), "github_reconciliation.member_ticket_ids", report
    )
    if set(members) != set(by_id):
        report.error("github_reconciliation membership must exactly match tickets")
    actual_edges = _dependency_edges(receipt.get("dependency_edges"), report)
    expected_edges = {
        (ticket_id, dependency)
        for ticket_id, ticket in by_id.items()
        for dependency in safe_list(ticket, "depends_on")
        if isinstance(dependency, str)
    }
    if actual_edges != expected_edges:
        report.error("github_reconciliation dependencies must exactly match depends_on")
    identities = {str(data.get("build_order_id")), *by_id}
    validate_body_evidence(
        receipt.get("observed_body_evidence"), identities,
        receipt.get("approved_planning_commit"), data.get("plan_version"),
        approved_expectations.bodies if approved_expectations is not None else None,
        report,
    )
    _validate_issue_titles(
        receipt.get("expected_issue_titles"),
        receipt.get("observed_issue_titles"),
        identities,
        approved_expectations.titles if approved_expectations is not None else None,
        report,
    )
    _validate_issue_states(
        receipt.get("observed_issue_states"), identities, report,
    )
    root_id = str(data.get("build_order_id"))
    validate_marker_query_matches(
        receipt.get("marker_query_matches"),
        {root_id: root, **ticket_mappings},
        report,
    )
    _validate_label_sets(data, by_id, receipt.get("projected_labels"), "projected", report)
    _validate_label_sets(data, by_id, receipt.get("observed_labels"), "observed", report)


def _validate_issue_titles(
    expected_value: object,
    observed_value: object,
    identities: set[str],
    approved: dict[str, str] | None,
    report: Report,
) -> None:
    if approved is None:
        report.error(
            "materialized GitHub receipt requires independently rendered "
            "approved title expectations"
        )
    elif set(approved) != identities:
        report.error("approved title expectations keys must match root and tickets")
    maps = (
        ("expected_issue_titles", expected_value),
        ("observed_issue_titles", observed_value),
    )
    for field, value in maps:
        label = f"github_reconciliation.{field}"
        if not isinstance(value, dict):
            report.error(f"{label} must be an object")
            continue
        if set(value) != identities:
            report.error(f"{label} keys must match root and tickets")
        for identity in sorted(identities):
            title = value.get(identity)
            if not nonempty_string(title):
                report.error(f"{label}.{identity} must be a non-empty string")
            elif approved is not None and title != approved.get(identity):
                report.error(
                    f"{label}.{identity} must match the independently rendered approved title"
                )


def _validate_issue_states(
    value: object,
    identities: set[str],
    report: Report,
) -> None:
    label = "github_reconciliation.observed_issue_states"
    if not isinstance(value, dict):
        report.error(f"{label} must be an object")
        return
    if set(value) != identities:
        report.error(f"{label} keys must match root and tickets")
    for identity in sorted(identities):
        state = value.get(identity)
        if state != "OPEN":
            report.error(
                f"{label}.{identity} must equal OPEN at publication"
            )


def _dependency_edges(value: object, report: Report) -> set[tuple[str, str]]:
    found: set[tuple[str, str]] = set()
    if not isinstance(value, list):
        report.error("github_reconciliation.dependency_edges must be an array")
        return found
    for index, value in enumerate(value):
        label = f"github_reconciliation.dependency_edges[{index}]"
        edge = strict_object(value, label, DEPENDENCY_KEYS, report)
        if edge is None:
            continue
        ticket_id, dependency = edge.get("ticket_id"), edge.get("depends_on")
        if not nonempty_string(ticket_id) or not nonempty_string(dependency):
            report.error(f"{label} values must be strings")
            continue
        pair = (ticket_id, dependency)
        if pair in found:
            report.error(f"github_reconciliation contains duplicate dependency {ticket_id}->{dependency}")
        found.add(pair)
    return found


def _validate_label_sets(
    data: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    value: object,
    field: str,
    report: Report,
) -> None:
    if not isinstance(value, dict):
        report.error(f"github_reconciliation.{field}_labels must be an object")
        return
    projection = data.get("label_projection") if isinstance(data.get("label_projection"), dict) else {}
    root_id = data.get("build_order_id")
    root_label = projection.get("build_order")
    required = set(
        label
        for label in projection.get("required_ticket_labels", [])
        if nonempty_string(label)
    )
    forbidden = set(
        label for label in projection.get("forbidden_labels", []) if nonempty_string(label)
    )
    expected: dict[str, set[str]] = {}
    if nonempty_string(root_id):
        expected[str(root_id)] = (
            {root_label} if nonempty_string(root_label) else set()
        )
    for ticket_id, ticket in by_id.items():
        labels: set[str] = set(required)
        selectors = (
            ("workstreams", ticket.get("workstream")),
            ("phases", str(ticket.get("phase_hint"))),
            ("complexities", str(ticket.get("complexity_points"))),
        )
        for group, key in selectors:
            mapping = projection.get(group)
            if isinstance(mapping, dict) and key in mapping and nonempty_string(mapping[key]):
                labels.add(mapping[key])
        expected[ticket_id] = labels
    if set(value) != set(expected):
        report.error(f"github_reconciliation.{field}_labels keys must match root and tickets")
    for identity, expected_labels in expected.items():
        labels = checked_string_list(
            value.get(identity), f"github_reconciliation.{field}_labels.{identity}", report
        )
        actual = set(labels)
        missing = sorted(expected_labels - actual)
        if missing:
            report.error(
                f"github_reconciliation {field} labels missing for {identity}: "
                + ", ".join(missing)
            )
        forbidden_hits = sorted(actual & forbidden)
        if forbidden_hits:
            report.error(
                f"github_reconciliation forbidden labels present for {identity}: "
                + ", ".join(forbidden_hits)
            )
        if identity != root_id and nonempty_string(root_label) and root_label in actual:
            report.error(
                f"github_reconciliation root-only label present for {identity}: {root_label}"
            )
        routing_prefixes = (
            "agent:", "human:", "model:", "phase:", "complexity:",
            "build-lane:",
        )
        unexpected = {
            label for label in actual
            if label.startswith(routing_prefixes) and label not in expected_labels
        }
        if field == "projected":
            unexpected |= actual - expected_labels
        unexpected = sorted(unexpected)
        if unexpected:
            report.error(
                f"github_reconciliation unexpected {field} labels for {identity}: "
                + ", ".join(unexpected)
            )
