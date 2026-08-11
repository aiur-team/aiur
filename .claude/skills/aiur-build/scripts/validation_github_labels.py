"""Validate projected and observed GitHub label sets."""

from __future__ import annotations

from typing import Any

from validation_common import (
    RUNNABLE_KINDS,
    Report,
    checked_string_list,
    nonempty_string,
)
from validation_header import LIFECYCLE_SLUGS


def _validate_label_sets(
    data: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    value: object,
    field: str,
    lifecycle_prefix: str,
    report: Report,
) -> None:
    if not isinstance(value, dict):
        report.error(f"github_reconciliation.{field}_labels must be an object")
        return
    projection = data.get("label_projection") if isinstance(data.get("label_projection"), dict) else {}
    root_id = data.get("build_order_id")
    root_label = projection.get("build_order")
    root_label_key = root_label.casefold() if nonempty_string(root_label) else None
    required = {
        label.casefold()
        for label in projection.get("required_ticket_labels", [])
        if nonempty_string(label)
    }
    forbidden = {
        label.casefold() for label in projection.get("forbidden_labels", [])
        if nonempty_string(label)
    }
    normalized_lifecycle_prefix = lifecycle_prefix.casefold()
    lifecycle_labels = {
        f"{normalized_lifecycle_prefix}:{slug}" for slug in LIFECYCLE_SLUGS
    }
    routing_prefixes = tuple(
        f"{prefix}:" for prefix in (
            normalized_lifecycle_prefix, "human", "model", "phase",
            "complexity", "build-lane",
        )
    )
    expected: dict[str, set[str]] = {}
    if nonempty_string(root_id):
        expected[str(root_id)] = (
            {root_label_key} if root_label_key is not None else set()
        )
    for ticket_id, ticket in by_id.items():
        labels: set[str] = set()
        if ticket.get("kind") in RUNNABLE_KINDS:
            labels.update(required)
            selectors = (
                ("workstreams", ticket.get("workstream")),
                ("phases", str(ticket.get("phase_hint"))),
                ("complexities", str(ticket.get("complexity_points"))),
            )
            for group, key in selectors:
                mapping = projection.get(group)
                if (
                    isinstance(mapping, dict)
                    and key in mapping
                    and nonempty_string(mapping[key])
                ):
                    labels.add(mapping[key].casefold())
        expected[ticket_id] = labels
    if set(value) != set(expected):
        report.error(f"github_reconciliation.{field}_labels keys must match root and tickets")
    for identity, expected_labels in expected.items():
        labels = checked_string_list(
            value.get(identity), f"github_reconciliation.{field}_labels.{identity}", report
        )
        normalized = [label.casefold() for label in labels]
        actual = set(normalized)
        if len(normalized) != len(actual):
            report.error(
                f"github_reconciliation.{field}_labels.{identity} "
                "contains case-insensitive duplicates"
            )
        missing = sorted(expected_labels - actual)
        if missing:
            report.error(
                f"github_reconciliation {field} labels missing for {identity}: "
                + ", ".join(missing)
            )
        forbidden_hits = sorted(actual & forbidden)
        forbidden_hits.extend(sorted(
            actual & (lifecycle_labels - {f"{normalized_lifecycle_prefix}:todo"})
        ))
        forbidden_hits = sorted(set(forbidden_hits))
        if forbidden_hits:
            report.error(
                f"github_reconciliation forbidden labels present for {identity}: "
                + ", ".join(forbidden_hits)
            )
        if identity != root_id and root_label_key is not None and root_label_key in actual:
            report.error(
                f"github_reconciliation root-only label present for {identity}: {root_label}"
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
