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
from validation_github_labels import _validate_label_sets
from validation_publication_authority import PublicationAuthority


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
    publication_authority: PublicationAuthority | None = None,
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
    # The lifecycle prefix decides which labels are required and which are
    # forbidden, so it must come from an authority outside the document under
    # test. Deriving it from this document's own `label_projection` let the
    # Build Order certify itself: a `workflow:todo` projection made
    # `agent:done` an unrecognized label rather than a wrong ticket state, and
    # the reconciliation reported clean over it. No authority means no
    # certification.
    if publication_authority is None:
        report.error(
            "github_reconciliation label certification requires an independent "
            "publication authority lifecycle prefix"
        )
        return
    lifecycle_prefix = publication_authority.tracker_lifecycle_label_prefix
    _validate_label_sets(
        data, by_id, receipt.get("projected_labels"), "projected",
        lifecycle_prefix, report,
    )
    _validate_label_sets(
        data, by_id, receipt.get("observed_labels"), "observed",
        lifecycle_prefix, report,
    )


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
