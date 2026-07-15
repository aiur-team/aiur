"""Validate graph scheduling metadata, conflicts, and feature acceptance."""

from __future__ import annotations

from typing import Any

from validation_common import (
    RUNNABLE_KINDS,
    Report,
    checked_string_list,
    nonempty_string,
    normalize_surfaces,
    safe_list,
    strict_object,
)


def validate_label_coverage(
    projection: dict[str, Any],
    workstreams: set[str],
    by_id: dict[str, dict[str, Any]],
    report: Report,
) -> None:
    expected = {
        "workstreams": workstreams,
        "phases": {str(ticket["phase_hint"]) for ticket in by_id.values() if type(ticket.get("phase_hint")) is int},
        "complexities": {
            str(ticket["complexity_points"])
            for ticket in by_id.values()
            if type(ticket.get("complexity_points")) is int
        },
    }
    all_labels: list[str] = []
    if nonempty_string(projection.get("build_order")):
        all_labels.append(projection["build_order"])
    all_labels.extend(
        label for label in safe_list(projection, "required_ticket_labels")
        if nonempty_string(label)
    )
    for key, expected_keys in expected.items():
        mapping = projection.get(key)
        if not isinstance(mapping, dict):
            continue
        actual_keys = {str(item) for item in mapping}
        for missing in sorted(expected_keys - actual_keys):
            report.error(f"label_projection.{key} missing key {missing}")
        for extra in sorted(actual_keys - expected_keys):
            report.error(f"label_projection.{key} has unused key {extra}")
        all_labels.extend(value for value in mapping.values() if nonempty_string(value))
    if len(all_labels) != len({label.casefold() for label in all_labels}):
        report.error("label_projection reuses a label for multiple meanings")


def _exception_map(
    by_id: dict[str, dict[str, Any]], report: Report
) -> dict[frozenset[str], set[str]]:
    result: dict[frozenset[str], set[str]] = {}
    for ticket_id, ticket in by_id.items():
        for value in safe_list(ticket, "conflict_exceptions"):
            if not isinstance(value, dict):
                continue
            target = value.get("ticket_id")
            if not isinstance(target, str) or target not in by_id:
                report.error(f"{ticket_id}: conflict exception references unknown ticket {target!r}")
                continue
            if target == ticket_id:
                report.error(f"{ticket_id}: conflict exception cannot reference itself")
                continue
            pair = frozenset((ticket_id, target))
            if pair in result:
                report.error(f"{ticket_id} and {target}: conflict exception must be declared once")
                continue
            surfaces = value.get("surfaces") if isinstance(value.get("surfaces"), list) else []
            result[pair] = {
                item.strip().casefold() for item in surfaces if nonempty_string(item)
            }
    return result


def validate_surface_conflicts(
    by_id: dict[str, dict[str, Any]], closure: dict[str, set[str]], report: Report
) -> None:
    exceptions = _exception_map(by_id, report)
    ids = [
        ticket_id
        for ticket_id, item in by_id.items()
        if isinstance(item.get("kind"), str) and item.get("kind") in RUNNABLE_KINDS
    ]
    for index, left_id in enumerate(ids):
        left = by_id[left_id]
        left_all = normalize_surfaces(left)
        left_safety = {
            item.strip().casefold() for item in safe_list(left, "safety_surfaces") if nonempty_string(item)
        }
        for right_id in ids[index + 1 :]:
            right = by_id[right_id]
            right_all = normalize_surfaces(right)
            overlap = set(left_all) & set(right_all)
            right_safety = {
                item.strip().casefold()
                for item in safe_list(right, "safety_surfaces")
                if nonempty_string(item)
            }
            safety_overlap = (left_safety & set(right_all)) | (right_safety & set(left_all))
            ordered = right_id in closure.get(left_id, set()) or left_id in closure.get(right_id, set())
            serialized = right_id in safe_list(left, "serializes_with")
            pair = frozenset((left_id, right_id))
            excepted = exceptions.get(pair, set())
            if excepted - overlap:
                invalid = ", ".join(sorted(excepted - overlap))
                report.error(f"{left_id} and {right_id}: exception names non-overlapping surfaces: {invalid}")
            if (ordered or serialized) and excepted:
                report.warn(f"{left_id} and {right_id}: conflict exception is unnecessary")
            if ordered or serialized:
                continue
            uncovered_safety = safety_overlap - excepted
            if uncovered_safety:
                report.error(
                    f"{left_id} and {right_id}: parallel safety-surface conflict: "
                    + ", ".join(sorted(uncovered_safety))
                )
            uncovered = overlap - excepted - safety_overlap
            if uncovered:
                report.warn(
                    f"{left_id} and {right_id}: overlapping parallel surfaces: "
                    + ", ".join(sorted(uncovered))
                )


def validate_epic_acceptance(
    data: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    closure: dict[str, set[str]],
    critical_path: list[str],
    report: Report,
) -> None:
    acceptance = strict_object(
        data.get("epic_acceptance"),
        "epic_acceptance",
        {"owner_ticket_id", "evidence"},
        report,
    )
    if acceptance is None:
        return
    owner = acceptance.get("owner_ticket_id")
    capstones = [ticket_id for ticket_id, ticket in by_id.items() if ticket.get("kind") == "capstone"]
    if len(capstones) != 1:
        report.error("the Build Order must contain exactly one capstone ticket")
    if not isinstance(owner, str) or owner not in by_id:
        report.error("epic_acceptance.owner_ticket_id must resolve to a ticket")
        return
    if by_id[owner].get("kind") != "capstone":
        report.error("epic acceptance owner must be the capstone ticket")
    if owner not in critical_path:
        report.error("feature_boundary critical path must include the capstone")
    evidence = checked_string_list(
        acceptance.get("evidence"), "epic_acceptance.evidence", report, require_items=True
    )
    human_evidence = by_id[owner].get("acceptance", {})
    human_evidence = human_evidence.get("human_or_e2e", []) if isinstance(human_evidence, dict) else []
    if evidence and not human_evidence:
        report.error("capstone acceptance must include human_or_e2e evidence")
    required = {
        ticket_id
        for ticket_id, ticket in by_id.items()
        if isinstance(ticket.get("kind"), str)
        and ticket.get("kind") in RUNNABLE_KINDS
        and ticket_id != owner
    }
    missing = required - closure.get(owner, set())
    if missing:
        report.error("capstone does not transitively cover: " + ", ".join(sorted(missing)))
