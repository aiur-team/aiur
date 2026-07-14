"""Validate publication records, documents, identities, and the merged graph."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from publication_common import (
    GATE_ID,
    TICKET_ID,
    Report,
    github_mapping,
    nonempty_string,
    safe_string_list,
    strict_int,
    string_list,
    valid_issue_title,
    validate_document,
)
from publication_conflicts import validate_surface_conflicts
from publication_requirements import validate_requirement_coverage


GATE_KEYS = {"id", "title", "owner", "resolution_criteria"}


def external_gates(data: dict[str, Any], report: Report) -> set[str]:
    values = data.get("external_gates")
    if not isinstance(values, list):
        report.error("external_gates must be an array")
        return set()
    found: set[str] = set()
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            report.error(f"external_gates[{index}] must be an object")
            continue
        gate = value
        for key in sorted(GATE_KEYS - set(gate)):
            report.error(f"external_gates[{index}]: missing required key {key}")
        gate_id = gate.get("id")
        if not isinstance(gate_id, str) or not GATE_ID.fullmatch(gate_id):
            report.error(f"external_gates[{index}].id must be a stable GATE identifier")
        elif gate_id in found:
            report.error(f"duplicate external gate {gate_id}")
        else:
            found.add(gate_id)
        for key in GATE_KEYS - {"id"}:
            if not nonempty_string(gate.get(key)):
                report.error(f"external_gates[{index}].{key} must be a non-empty string")
    return found


def manifest_tickets(
    data: dict[str, Any], base: Path, repository: str, gates: set[str], report: Report
) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list) or not values:
        report.error("tickets must be a non-empty array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            report.error(f"tickets[{index}] must be an object")
            continue
        ticket = value
        ticket_id = ticket.get("id")
        if not isinstance(ticket_id, str) or not TICKET_ID.fullmatch(ticket_id):
            report.error(f"tickets[{index}].id must be a full stable ticket ID")
            continue
        validated = dict(ticket)
        if ticket_id in found:
            report.error(f"duplicate logical ID {ticket_id}")
        else:
            found[ticket_id] = validated
        _ticket_fields(ticket_id, validated, base, gates, report)
        validated["_github"] = github_mapping(
            ticket.get("github"), f"{ticket_id}.github", repository, report
        )
    validate_requirement_coverage(found, report)
    return found


def _ticket_fields(
    ticket_id: str, ticket: dict[str, Any], base: Path, gates: set[str], report: Report
) -> None:
    if not valid_issue_title(ticket.get("title")):
        report.error(f"{ticket_id}.title must be a trimmed single-line GitHub issue title")
    points = ticket.get("complexity_points")
    if not strict_int(points) or not 1 <= points <= 5:
        report.error(f"{ticket_id}.complexity_points must be integer 1..5")
    string_list(ticket.get("depends_on"), f"{ticket_id}.depends_on", report)
    string_list(
        ticket.get("serializes_with"), f"{ticket_id}.serializes_with", report
    )
    for field in (
        "read_surfaces", "write_surfaces", "contract_surfaces", "safety_surfaces",
    ):
        string_list(ticket.get(field), f"{ticket_id}.{field}", report)
    exceptions = ticket.get("conflict_exceptions")
    if not isinstance(exceptions, list):
        report.error(f"{ticket_id}.conflict_exceptions must be an array")
    else:
        for index, exception in enumerate(exceptions):
            if not isinstance(exception, dict):
                report.error(
                    f"{ticket_id}.conflict_exceptions[{index}] must be an object"
                )
    gate_ids = string_list(
        ticket.get("external_gates"), f"{ticket_id}.external_gates", report
    )
    for gate_id in gate_ids:
        if gate_id not in gates:
            report.error(f"{ticket_id}.external_gates references unknown gate {gate_id}")
    validate_document(ticket, base, report)


def validate_graph(tickets: dict[str, dict[str, Any]], report: Report) -> None:
    dependencies: dict[str, set[str]] = {}
    for ticket_id, ticket in tickets.items():
        deps = set(safe_string_list(ticket.get("depends_on")))
        dependencies[ticket_id] = deps
        for dependency in sorted(deps):
            if dependency == ticket_id:
                report.error(f"{ticket_id} cannot depend on itself")
            elif dependency not in tickets:
                report.error(f"{ticket_id} depends on unknown ticket {dependency}")
    _check_cycle(set(tickets), dependencies, report)
    _validate_serialization(tickets, report)
    validate_surface_conflicts(tickets, dependencies, report)


def _validate_serialization(
    tickets: dict[str, dict[str, Any]], report: Report,
) -> None:
    for ticket_id, ticket in tickets.items():
        for target in safe_string_list(ticket.get("serializes_with")):
            if target == ticket_id:
                report.error(f"{ticket_id} cannot serialize with itself")
            elif target not in tickets:
                report.error(f"{ticket_id} serializes with unknown ticket {target}")
            else:
                reverse = set(safe_string_list(tickets[target].get("serializes_with")))
                if ticket_id not in reverse:
                    report.error(
                        f"{ticket_id}.serializes_with {target} must be symmetric"
                    )


def _check_cycle(all_ids: set[str], dependencies: dict[str, set[str]], report: Report) -> None:
    remaining, resolved = set(all_ids), set()
    while remaining:
        ready = {item for item in remaining if dependencies.get(item, set()) <= resolved}
        if not ready:
            report.error("hard dependency graph has a cycle: " + ", ".join(sorted(remaining)))
            return
        remaining -= ready
        resolved |= ready


def github_mappings(
    build_data: dict[str, Any], tickets: dict[str, dict[str, Any]],
    repository: str, report: Report,
) -> dict[str, dict[str, Any] | None]:
    mappings = {"github_root": github_mapping(
        build_data.get("github_root"), "github_root", repository, report
    )}
    mappings.update({
        ticket_id: ticket.get("_github") for ticket_id, ticket in tickets.items()
    })
    _unique_identities(mappings, report)
    return mappings


def _unique_identities(mappings: dict[str, dict[str, Any] | None], report: Report) -> None:
    identities: dict[tuple[str, int], str] = {}
    nodes: dict[str, str] = {}
    for label, mapping in mappings.items():
        if mapping is None:
            continue
        identity = (mapping.get("repository"), mapping.get("number"))
        if isinstance(identity[0], str) and strict_int(identity[1]):
            if identity in identities:
                report.error(f"{label}.github duplicates issue identity used by {identities[identity]}")
            identities[identity] = label
        node = mapping.get("node_id")
        if nonempty_string(node) and node in nodes:
            report.error(f"{label}.github duplicates node_id used by {nodes[node]}")
        elif nonempty_string(node):
            nodes[node] = label
