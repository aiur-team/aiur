"""Validate a bounded receipt from a fresh GitHub graph requery."""

from __future__ import annotations

from typing import Any

from validation_common import (
    Report,
    checked_string_list,
    nonempty_string,
    safe_list,
    strict_object,
)


RECONCILIATION_KEYS = {
    "checked_at",
    "root_node_id",
    "member_ticket_ids",
    "dependency_edges",
    "projected_labels",
}
DEPENDENCY_KEYS = {"ticket_id", "depends_on"}


def validate_reconciliation(
    data: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    root: dict[str, Any] | None,
    ticket_mappings: dict[str, dict[str, Any] | None],
    report: Report,
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
    if root is None:
        report.error("github_reconciliation requires github_root")
    missing = sorted(ticket_id for ticket_id, item in ticket_mappings.items() if item is None)
    if missing:
        report.error("github_reconciliation missing ticket mappings: " + ", ".join(missing))
    if not nonempty_string(receipt.get("checked_at")):
        report.error("github_reconciliation.checked_at must be a non-empty string")
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
    _validate_projected_labels(data, by_id, receipt.get("projected_labels"), report)


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


def _validate_projected_labels(
    data: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    value: object,
    report: Report,
) -> None:
    if not isinstance(value, dict):
        report.error("github_reconciliation.projected_labels must be an object")
        return
    projection = data.get("label_projection") if isinstance(data.get("label_projection"), dict) else {}
    root_label = projection.get("build_order")
    required = set(
        label
        for label in projection.get("required_ticket_labels", [])
        if nonempty_string(label)
    )
    forbidden = set(
        label for label in projection.get("forbidden_labels", []) if nonempty_string(label)
    )
    expected: dict[str, set[str]] = {
        "github_root": {root_label} if nonempty_string(root_label) else set()
    }
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
        report.error("github_reconciliation.projected_labels keys must match root and tickets")
    for identity, expected_labels in expected.items():
        labels = checked_string_list(
            value.get(identity), f"github_reconciliation.projected_labels.{identity}", report
        )
        actual = set(labels)
        missing = sorted(expected_labels - actual)
        if missing:
            report.error(
                f"github_reconciliation projected labels missing for {identity}: "
                + ", ".join(missing)
            )
        forbidden_hits = sorted(actual & forbidden)
        if forbidden_hits:
            report.error(
                f"github_reconciliation forbidden labels present for {identity}: "
                + ", ".join(forbidden_hits)
            )
        projected_family = {
            label
            for group in ("workstreams", "phases", "complexities")
            for label in (
                projection.get(group, {}).values()
                if isinstance(projection.get(group), dict)
                else []
            )
            if nonempty_string(label)
        }
        if nonempty_string(root_label):
            projected_family.add(root_label)
        projected_family.update(required)
        unexpected = sorted((actual & projected_family) - expected_labels)
        if unexpected:
            report.error(
                f"github_reconciliation unexpected projected labels for {identity}: "
                + ", ".join(unexpected)
            )
