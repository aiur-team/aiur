"""Validate combined Build Order/dashboard parallel-write surfaces."""

from __future__ import annotations

from typing import Any

from publication_common import (
    Report,
    nonempty_string,
    safe_string_list,
    strict_object,
    string_list,
)


EXCEPTION_KEYS = {"ticket_id", "surfaces", "reason"}
SURFACE_FIELDS = ("write_surfaces", "contract_surfaces", "safety_surfaces")


def validate_surface_conflicts(
    build: dict[str, dict[str, Any]],
    dash: dict[str, dict[str, Any]],
    dependencies: dict[str, set[str]],
    report: Report,
) -> None:
    tickets = {**build, **dash}
    closure = _dependency_closure(set(tickets), dependencies)
    exceptions = _conflict_exceptions(tickets, report)
    ids = sorted(tickets)
    for index, left_id in enumerate(ids):
        _compare_ticket(left_id, ids[index + 1 :], tickets, closure, exceptions, report)


def _compare_ticket(
    left_id: str,
    right_ids: list[str],
    tickets: dict[str, dict[str, Any]],
    closure: dict[str, set[str]],
    exceptions: dict[frozenset[str], set[str]],
    report: Report,
) -> None:
    left = tickets[left_id]
    left_all = _normalized_surfaces(left)
    left_safety = _normalized_field(left, "safety_surfaces")
    for right_id in right_ids:
        _compare_pair(
            left_id, right_id, left_all, left_safety, tickets,
            closure, exceptions, report,
        )


def _compare_pair(
    left_id: str,
    right_id: str,
    left_all: set[str],
    left_safety: set[str],
    tickets: dict[str, dict[str, Any]],
    closure: dict[str, set[str]],
    exceptions: dict[frozenset[str], set[str]],
    report: Report,
) -> None:
    right = tickets[right_id]
    right_all = _normalized_surfaces(right)
    overlap = left_all & right_all
    safety_overlap = (
        (left_safety & right_all)
        | (_normalized_field(right, "safety_surfaces") & left_all)
    )
    ordered = (
        right_id in closure.get(left_id, set())
        or left_id in closure.get(right_id, set())
    )
    serialized = (
        right_id in safe_string_list(tickets[left_id].get("serializes_with"))
        or left_id in safe_string_list(right.get("serializes_with"))
    )
    excepted = exceptions.get(frozenset((left_id, right_id)), set())
    _report_pair(
        left_id, right_id, overlap, safety_overlap, excepted,
        ordered, serialized, report,
    )


def _report_pair(
    left_id: str,
    right_id: str,
    overlap: set[str],
    safety_overlap: set[str],
    excepted: set[str],
    ordered: bool,
    serialized: bool,
    report: Report,
) -> None:
    invalid = excepted - overlap
    if invalid:
        report.error(
            f"{left_id} and {right_id}: exception names non-overlapping "
            f"surfaces: {', '.join(sorted(invalid))}"
        )
    if (ordered or serialized) and excepted:
        report.warn(f"{left_id} and {right_id}: conflict exception is unnecessary")
    if ordered or serialized:
        return
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


def _dependency_closure(
    all_ids: set[str], dependencies: dict[str, set[str]]
) -> dict[str, set[str]]:
    closure: dict[str, set[str]] = {}

    def visit(ticket_id: str, active: set[str]) -> set[str]:
        if ticket_id in closure:
            return closure[ticket_id]
        if ticket_id in active:
            return set()
        reached: set[str] = set()
        for dependency in dependencies.get(ticket_id, set()):
            if dependency not in all_ids:
                continue
            reached.add(dependency)
            reached.update(visit(dependency, active | {ticket_id}))
        closure[ticket_id] = reached
        return reached

    for ticket_id in all_ids:
        visit(ticket_id, set())
    return closure


def _conflict_exceptions(
    tickets: dict[str, dict[str, Any]], report: Report
) -> dict[frozenset[str], set[str]]:
    exceptions: dict[frozenset[str], set[str]] = {}
    for ticket_id, ticket in tickets.items():
        for index, value in enumerate(ticket.get("conflict_exceptions", [])):
            label = f"{ticket_id}.conflict_exceptions[{index}]"
            exception = strict_object(value, label, EXCEPTION_KEYS, report)
            if exception is None:
                continue
            target = exception.get("ticket_id")
            if not isinstance(target, str) or target not in tickets:
                report.error(f"{label}.ticket_id references unknown ticket {target!r}")
                continue
            if target == ticket_id:
                report.error(f"{label}.ticket_id cannot reference itself")
                continue
            surfaces = string_list(exception.get("surfaces"), f"{label}.surfaces", report)
            if not surfaces:
                report.error(f"{label}.surfaces must not be empty")
            if not nonempty_string(exception.get("reason")):
                report.error(f"{label}.reason must be a non-empty string")
            pair = frozenset((ticket_id, target))
            if pair in exceptions:
                report.error(f"{ticket_id} and {target}: conflict exception must be declared once")
                continue
            exceptions[pair] = {surface.strip().casefold() for surface in surfaces}
    return exceptions


def _normalized_surfaces(ticket: dict[str, Any]) -> set[str]:
    return {
        surface.strip().casefold()
        for field in SURFACE_FIELDS
        for surface in safe_string_list(ticket.get(field))
        if surface.strip()
    }


def _normalized_field(ticket: dict[str, Any], field: str) -> set[str]:
    return {
        surface.strip().casefold()
        for surface in safe_string_list(ticket.get(field))
        if surface.strip()
    }
