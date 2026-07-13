"""Validate publication records, documents, identities, and the combined graph."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from publication_common import (
    BO_ID,
    DASH_ID,
    EXTERNAL_BLOCKER,
    GATE_ID,
    REQ_ID,
    Report,
    github_mapping,
    nonempty_string,
    safe_string_list,
    strict_int,
    strict_object,
    string_list,
    valid_issue_title,
    validate_document,
)
from publication_conflicts import validate_surface_conflicts
from publication_requirements import validate_requirement_coverage


TICKET_KEYS = {
    "id", "title", "document", "requirement_ref", "complexity_points",
    "depends_on", "serializes_with", "external_blockers", "external_gate_ids",
    "read_surfaces", "write_surfaces", "contract_surfaces", "safety_surfaces",
    "conflict_exceptions", "github",
}
GATE_KEYS = {"id", "owner", "resolution_criteria"}


def build_tickets(
    data: dict[str, Any], repository: str, report: Report
) -> dict[str, dict[str, Any]]:
    if data.get("repository") != repository:
        report.error("build-order repository must match dashboard companions")
    values = data.get("tickets")
    if not isinstance(values, list):
        report.error("build-order tickets must be an array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    for index, ticket in enumerate(values):
        if not isinstance(ticket, dict):
            report.error(f"build-order tickets[{index}] must be an object")
            continue
        ticket_id = ticket.get("id")
        if not isinstance(ticket_id, str) or not BO_ID.fullmatch(ticket_id):
            report.error(f"build-order tickets[{index}].id must look like BO-001")
            continue
        if ticket_id in found:
            report.error(f"duplicate logical ID {ticket_id}")
        else:
            found[ticket_id] = ticket
        if not valid_issue_title(ticket.get("title")):
            report.error(f"{ticket_id}.title must be a trimmed single-line GitHub issue title")
        string_list(ticket.get("depends_on"), f"{ticket_id}.depends_on", report)
    return found


def external_gates(data: dict[str, Any], report: Report) -> set[str]:
    values = data.get("external_gates")
    if not isinstance(values, list):
        report.error("external_gates must be an array")
        return set()
    found: set[str] = set()
    for index, value in enumerate(values):
        gate = strict_object(value, f"external_gates[{index}]", GATE_KEYS, report)
        if gate is None:
            continue
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


def dash_tickets(
    data: dict[str, Any], base: Path, repository: str, gates: set[str], report: Report
) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list) or not values:
        report.error("tickets must be a non-empty array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(values):
        ticket = strict_object(value, f"tickets[{index}]", TICKET_KEYS, report)
        if ticket is None:
            continue
        ticket_id = ticket.get("id")
        if not isinstance(ticket_id, str) or not DASH_ID.fullmatch(ticket_id):
            report.error(f"tickets[{index}].id must look like DASH-001")
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
    requirement = ticket.get("requirement_ref")
    if not isinstance(requirement, str) or not REQ_ID.fullmatch(requirement):
        report.error(f"{ticket_id}.requirement_ref must look like DREQ-001")
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
    blockers = string_list(
        ticket.get("external_blockers"), f"{ticket_id}.external_blockers", report
    )
    for blocker in blockers:
        if not EXTERNAL_BLOCKER.fullmatch(blocker):
            report.error(f"{ticket_id}.external_blockers has invalid identity {blocker}")
    gate_ids = string_list(
        ticket.get("external_gate_ids"), f"{ticket_id}.external_gate_ids", report
    )
    for gate_id in gate_ids:
        if gate_id not in gates:
            report.error(f"{ticket_id}.external_gate_ids references unknown gate {gate_id}")
    validate_document(ticket, base, report)


def validate_graph(
    build: dict[str, dict[str, Any]], dash: dict[str, dict[str, Any]], report: Report
) -> None:
    all_ids = set(build) | set(dash)
    for ticket_id in sorted(set(build) & set(dash)):
        report.error(f"duplicate logical ID across BO and DASH graphs: {ticket_id}")
    dependencies: dict[str, set[str]] = {}
    for ticket_id, ticket in {**build, **dash}.items():
        deps = set(safe_string_list(ticket.get("depends_on")))
        dependencies[ticket_id] = deps
        for dependency in sorted(deps):
            if dependency == ticket_id:
                report.error(f"{ticket_id} cannot depend on itself")
            elif dependency not in all_ids:
                report.error(f"{ticket_id} depends on unknown ticket {dependency}")
    _check_cycle(all_ids, dependencies, report)
    _validate_serialization(build, dash, report)
    validate_surface_conflicts(build, dash, dependencies, report)


def _validate_serialization(
    build: dict[str, dict[str, Any]], dash: dict[str, dict[str, Any]], report: Report,
) -> None:
    combined = {**build, **dash}
    for ticket_id, ticket in combined.items():
        for target in safe_string_list(ticket.get("serializes_with")):
            if target == ticket_id:
                report.error(f"{ticket_id} cannot serialize with itself")
            elif target not in combined:
                report.error(f"{ticket_id} serializes with unknown ticket {target}")
            elif ticket_id in build and target in dash:
                report.error(
                    f"cross-pack serialization {ticket_id}<->{target} must be "
                    "declared by the companion ticket"
                )
            elif (ticket_id in build) == (target in build):
                reverse = set(safe_string_list(combined[target].get("serializes_with")))
                if ticket_id not in reverse:
                    report.error(
                        f"{ticket_id}.serializes_with {target} must be symmetric"
                    )


def _check_cycle(all_ids: set[str], dependencies: dict[str, set[str]], report: Report) -> None:
    remaining, resolved = set(all_ids), set()
    while remaining:
        ready = {item for item in remaining if dependencies.get(item, set()) <= resolved}
        if not ready:
            report.error("combined hard dependency graph has a cycle: " + ", ".join(sorted(remaining)))
            return
        remaining -= ready
        resolved |= ready


def github_mappings(
    build_data: dict[str, Any], build: dict[str, dict[str, Any]],
    dash: dict[str, dict[str, Any]], repository: str, report: Report,
) -> dict[str, dict[str, Any] | None]:
    mappings = {"github_root": github_mapping(
        build_data.get("github_root"), "github_root", repository, report
    )}
    for ticket_id, ticket in build.items():
        mappings[ticket_id] = github_mapping(
            ticket.get("github"), f"{ticket_id}.github", repository, report
        )
    mappings.update({ticket_id: ticket.get("_github") for ticket_id, ticket in dash.items()})
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
