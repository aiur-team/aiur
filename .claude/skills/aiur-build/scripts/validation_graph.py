"""Validate typed ticket edges, hierarchy, phases, and traceability."""

from __future__ import annotations

from typing import Any

from validation_common import EDGE_FIELDS, RUNNABLE_KINDS, TICKET_ID, Report, safe_list


def validate_references(
    requirements: dict[str, dict[str, Any]],
    by_id: dict[str, dict[str, Any]],
    workstreams: set[str],
    gates: set[str],
    report: Report,
) -> None:
    for ticket_id, ticket in by_id.items():
        workstream = ticket.get("workstream")
        if not isinstance(workstream, str) or workstream not in workstreams:
            report.error(f"{ticket_id}: unknown workstream {ticket.get('workstream')!r}")
        for field in EDGE_FIELDS + ("contains",):
            for target in safe_list(ticket, field):
                if not isinstance(target, str):
                    continue
                if target == ticket_id:
                    report.error(f"{ticket_id}: {field} contains a self-edge")
                elif target not in by_id:
                    report.error(f"{ticket_id}: {field} references unknown ticket {target}")
        for gate_id in safe_list(ticket, "external_gates"):
            if isinstance(gate_id, str) and gate_id not in gates:
                report.error(f"{ticket_id}: references unknown external gate {gate_id}")
        source = ticket.get("discovered_from")
        if isinstance(source, str) and TICKET_ID.fullmatch(source):
            if source == ticket_id:
                report.error(f"{ticket_id}: discovered_from cannot reference itself")
            elif source not in by_id:
                report.error(f"{ticket_id}: discovered_from references unknown ticket {source}")
        refs = safe_list(ticket, "requirement_refs")
        for req_id in refs:
            if not isinstance(req_id, str):
                continue
            requirement = requirements.get(req_id)
            if requirement is None:
                report.error(f"{ticket_id}: unknown requirement ref {req_id}")
            elif ticket_id not in safe_list(requirement, "ticket_ids"):
                report.error(f"{ticket_id}: requirement {req_id} does not trace back to this ticket")
    for req_id, requirement in requirements.items():
        for ticket_id in safe_list(requirement, "ticket_ids"):
            if not isinstance(ticket_id, str):
                continue
            ticket = by_id.get(ticket_id)
            if ticket is None:
                report.error(f"{req_id}: disposition references unknown ticket {ticket_id}")
            elif req_id not in safe_list(ticket, "requirement_refs"):
                report.error(f"{req_id}: ticket {ticket_id} does not trace back to this requirement")


def validate_edge_types(by_id: dict[str, dict[str, Any]], report: Report) -> None:
    pair_types: dict[frozenset[str], set[str]] = {}
    for ticket_id, ticket in by_id.items():
        for field in EDGE_FIELDS + ("contains",):
            for target in safe_list(ticket, field):
                if isinstance(target, str) and target in by_id and target != ticket_id:
                    pair_types.setdefault(frozenset((ticket_id, target)), set()).add(field)
        for target in safe_list(ticket, "serializes_with"):
            if isinstance(target, str) and target in by_id:
                reverse = safe_list(by_id[target], "serializes_with")
                if ticket_id not in reverse:
                    report.error(f"{ticket_id}: serializes_with {target} must be symmetric")
        for target in safe_list(ticket, "suggested_after"):
            if isinstance(target, str) and target in by_id:
                if ticket_id in safe_list(by_id[target], "suggested_after"):
                    report.error(f"{ticket_id} and {target}: suggested_after cannot point both ways")
    for pair, types in pair_types.items():
        if len(types) > 1:
            report.error(
                f"{', '.join(sorted(pair))}: contradictory edge types {', '.join(sorted(types))}"
            )


def dependency_closure(
    by_id: dict[str, dict[str, Any]], report: Report
) -> dict[str, set[str]]:
    state: dict[str, int] = {}
    closure: dict[str, set[str]] = {}
    stack: list[str] = []

    def visit(ticket_id: str) -> set[str]:
        if state.get(ticket_id) == 2:
            return closure.get(ticket_id, set())
        if state.get(ticket_id) == 1:
            start = stack.index(ticket_id) if ticket_id in stack else 0
            report.error(f"hard dependency cycle: {' -> '.join(stack[start:] + [ticket_id])}")
            return set()
        state[ticket_id] = 1
        stack.append(ticket_id)
        reached: set[str] = set()
        for dependency in safe_list(by_id[ticket_id], "depends_on"):
            if isinstance(dependency, str) and dependency in by_id:
                reached.add(dependency)
                reached.update(visit(dependency))
        stack.pop()
        state[ticket_id] = 2
        closure[ticket_id] = reached
        return reached

    for ticket_id in by_id:
        visit(ticket_id)
    return closure


def validate_hierarchy(by_id: dict[str, dict[str, Any]], report: Report) -> None:
    owners: dict[str, str] = {}
    hierarchy: dict[str, list[str]] = {}
    for ticket_id, ticket in by_id.items():
        children = [item for item in safe_list(ticket, "contains") if isinstance(item, str)]
        if ticket.get("kind") == "umbrella" and not children:
            report.error(f"{ticket_id}: umbrella must contain at least one ticket")
        if ticket.get("kind") != "umbrella" and children:
            report.error(f"{ticket_id}: only umbrella tickets may contain other tickets")
        hierarchy[ticket_id] = [child for child in children if child in by_id]
        for child in hierarchy[ticket_id]:
            if child in owners and owners[child] != ticket_id:
                report.error(f"{child}: contained by both {owners[child]} and {ticket_id}")
            else:
                owners[child] = ticket_id
    active: set[str] = set()
    done: set[str] = set()

    def visit(ticket_id: str, trail: list[str]) -> None:
        if ticket_id in active:
            report.error(f"hierarchy cycle: {' -> '.join(trail + [ticket_id])}")
            return
        if ticket_id in done:
            return
        active.add(ticket_id)
        for child in hierarchy.get(ticket_id, []):
            visit(child, trail + [ticket_id])
        active.remove(ticket_id)
        done.add(ticket_id)

    for ticket_id in by_id:
        visit(ticket_id, [])


def validate_phases(by_id: dict[str, dict[str, Any]], report: Report) -> None:
    for ticket_id, ticket in by_id.items():
        phase = ticket.get("phase_hint")
        if type(phase) is not int:
            continue
        for dependency in safe_list(ticket, "depends_on"):
            dep_phase = by_id.get(dependency, {}).get("phase_hint")
            if type(dep_phase) is int and phase < dep_phase:
                report.error(
                    f"{ticket_id}: phase {phase} is earlier than dependency "
                    f"{dependency} phase {dep_phase}"
                )


def validate_boundary_refs(
    critical_path: list[str], by_id: dict[str, dict[str, Any]], report: Report
) -> None:
    for ticket_id in critical_path:
        ticket = by_id.get(ticket_id)
        if ticket is None:
            report.error(f"feature_boundary: unknown critical-path ticket {ticket_id}")
        elif not isinstance(ticket.get("kind"), str) or ticket.get("kind") not in RUNNABLE_KINDS:
            report.error(f"feature_boundary: critical-path ticket {ticket_id} is not runnable")
