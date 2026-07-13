#!/usr/bin/env python3
"""Validate an aiur-build canonical build-order.json planning baseline."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


TICKET_ID = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{3,}[A-Z]?$", re.ASCII)
REQ_ID = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{3,}$", re.ASCII)
KINDS = {"executable", "audit", "gate", "umbrella", "capstone"}
RUNNABLE_KINDS = {"executable", "audit", "gate", "capstone"}
PROVENANCE = {"planned", "discovered"}
DISPOSITIONS = {"ticket", "covered", "deferred", "rejected", "satisfied"}
EDGE_FIELDS = ("depends_on", "serializes_with", "suggested_after")
SURFACE_FIELDS = ("write_surfaces", "contract_surfaces")


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def string_list(value: object) -> bool:
    return isinstance(value, list) and all(nonempty_string(item) for item in value)


def load(path: Path, report: Report) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"cannot read valid JSON: {exc}")
        return {}
    if not isinstance(value, dict):
        report.error("top level must be a JSON object")
        return {}
    return value


def validate_header(data: dict, report: Report) -> None:
    if data.get("schema_version") != 1:
        report.error("schema_version must be 1")
    if not nonempty_string(data.get("build_order_id")):
        report.error("build_order_id must be a non-empty string")
    if not isinstance(data.get("plan_version"), int) or data.get("plan_version", 0) < 1:
        report.error("plan_version must be a positive integer")
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", str(data.get("repository", ""))):
        report.error("repository must be owner/repo")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", str(data.get("researched_at_commit", ""))):
        report.error("researched_at_commit must be a 40-character Git SHA")


def validate_requirements(data: dict, report: Report) -> set[str]:
    requirements = data.get("requirements")
    if not isinstance(requirements, list) or not requirements:
        report.error("requirements must be a non-empty array")
        return set()
    ids: set[str] = set()
    for index, req in enumerate(requirements):
        label = f"requirements[{index}]"
        if not isinstance(req, dict):
            report.error(f"{label} must be an object")
            continue
        req_id = req.get("id")
        if not isinstance(req_id, str) or not REQ_ID.fullmatch(req_id):
            report.error(f"{label}.id must be a full stable requirement ID")
            continue
        if req_id in ids:
            report.error(f"duplicate requirement id {req_id}")
        ids.add(req_id)
        disposition = req.get("disposition")
        if disposition not in DISPOSITIONS:
            report.error(f"{req_id}: invalid disposition {disposition!r}")
        ticket_ids = req.get("ticket_ids", [])
        if not string_list(ticket_ids):
            report.error(f"{req_id}: ticket_ids must be an array of strings")
        if disposition in {"ticket", "covered"} and not ticket_ids:
            report.error(f"{req_id}: {disposition} disposition requires ticket_ids")
        if disposition in {"deferred", "rejected", "satisfied"} and not nonempty_string(req.get("reason")):
            report.error(f"{req_id}: {disposition} disposition requires reason")
    return ids


def validate_tickets(data: dict, requirement_ids: set[str], report: Report) -> dict[str, dict]:
    tickets = data.get("tickets")
    if not isinstance(tickets, list) or not tickets:
        report.error("tickets must be a non-empty array")
        return {}
    plan_version = data.get("plan_version", 0)
    by_id: dict[str, dict] = {}
    for index, ticket in enumerate(tickets):
        label = f"tickets[{index}]"
        if not isinstance(ticket, dict):
            report.error(f"{label} must be an object")
            continue
        ticket_id = ticket.get("id")
        if not isinstance(ticket_id, str) or not TICKET_ID.fullmatch(ticket_id):
            report.error(f"{label}.id must be a full stable ticket ID like BO-001")
            continue
        if ticket_id in by_id:
            report.error(f"duplicate ticket id {ticket_id}")
        by_id[ticket_id] = ticket
        kind = ticket.get("kind")
        if kind not in KINDS:
            report.error(f"{ticket_id}: invalid kind {kind!r}")
        if ticket.get("provenance") not in PROVENANCE:
            report.error(f"{ticket_id}: provenance must be planned or discovered")
        introduced = ticket.get("introduced_in_plan_version")
        if not isinstance(introduced, int) or introduced < 1 or introduced > plan_version:
            report.error(f"{ticket_id}: introduced plan version must be within 1..{plan_version}")
        if not nonempty_string(ticket.get("title")):
            report.error(f"{ticket_id}: title is required")
        phase = ticket.get("phase_hint")
        if not isinstance(phase, int) or phase < 0:
            report.error(f"{ticket_id}: phase_hint must be a non-negative integer")
        if kind in RUNNABLE_KINDS:
            points = ticket.get("complexity_points")
            if not isinstance(points, int) or not 1 <= points <= 5:
                report.error(f"{ticket_id}: runnable ticket complexity_points must be 1..5")
            if not nonempty_string(ticket.get("complexity_rationale")):
                report.error(f"{ticket_id}: runnable ticket needs complexity_rationale")
            if not nonempty_string(ticket.get("risk")):
                report.error(f"{ticket_id}: runnable ticket needs risk")
        refs = ticket.get("requirement_refs", [])
        if not string_list(refs):
            report.error(f"{ticket_id}: requirement_refs must be an array of strings")
            refs = []
        if kind in RUNNABLE_KINDS and not refs:
            report.warn(f"{ticket_id}: runnable ticket has no requirement_refs")
        for ref in refs:
            if ref not in requirement_ids:
                report.error(f"{ticket_id}: unknown requirement ref {ref}")
        for field in EDGE_FIELDS + ("read_surfaces",) + SURFACE_FIELDS:
            if not string_list(ticket.get(field, [])):
                report.error(f"{ticket_id}: {field} must be an array of strings")
    return by_id


def validate_references(data: dict, by_id: dict[str, dict], report: Report) -> None:
    for ticket_id, ticket in by_id.items():
        for field in EDGE_FIELDS:
            for target in ticket.get(field, []):
                if target == ticket_id:
                    report.error(f"{ticket_id}: {field} contains a self-edge")
                elif target not in by_id:
                    report.error(f"{ticket_id}: {field} references unknown ticket {target}")
        for other in ticket.get("serializes_with", []):
            if other in by_id and ticket_id not in by_id[other].get("serializes_with", []):
                report.warn(f"{ticket_id}: serializes_with {other} is not symmetric")
    for req in data.get("requirements", []):
        if not isinstance(req, dict):
            continue
        for ticket_id in req.get("ticket_ids", []):
            if ticket_id not in by_id:
                report.error(f"{req.get('id', '?')}: disposition references unknown ticket {ticket_id}")


def dependency_closure(by_id: dict[str, dict], report: Report) -> dict[str, set[str]]:
    state: dict[str, int] = {}
    closure: dict[str, set[str]] = {}
    stack: list[str] = []

    def visit(ticket_id: str) -> set[str]:
        if state.get(ticket_id) == 2:
            return closure[ticket_id]
        if state.get(ticket_id) == 1:
            cycle = " -> ".join(stack + [ticket_id])
            report.error(f"hard dependency cycle: {cycle}")
            return set()
        state[ticket_id] = 1
        stack.append(ticket_id)
        reached: set[str] = set()
        for dep in by_id[ticket_id].get("depends_on", []):
            if dep in by_id:
                reached.add(dep)
                reached.update(visit(dep))
        stack.pop()
        state[ticket_id] = 2
        closure[ticket_id] = reached
        return reached

    for ticket_id in by_id:
        visit(ticket_id)
    return closure


def validate_phases(by_id: dict[str, dict], report: Report) -> None:
    for ticket_id, ticket in by_id.items():
        phase = ticket.get("phase_hint")
        if not isinstance(phase, int):
            continue
        exceptions = set(ticket.get("phase_exceptions", []))
        for dep in ticket.get("depends_on", []):
            dep_phase = by_id.get(dep, {}).get("phase_hint")
            if isinstance(dep_phase, int) and phase <= dep_phase and dep not in exceptions:
                report.error(
                    f"{ticket_id}: phase {phase} must be later than dependency {dep} phase {dep_phase} "
                    "or list it in phase_exceptions"
                )


def validate_surface_conflicts(by_id: dict[str, dict], closure: dict[str, set[str]], report: Report) -> None:
    ids = [ticket_id for ticket_id, ticket in by_id.items() if ticket.get("kind") in RUNNABLE_KINDS]
    for index, left_id in enumerate(ids):
        left = by_id[left_id]
        left_surfaces = {str(item).strip().lower() for field in SURFACE_FIELDS for item in left.get(field, [])}
        if not left_surfaces:
            continue
        for right_id in ids[index + 1 :]:
            right = by_id[right_id]
            right_surfaces = {str(item).strip().lower() for field in SURFACE_FIELDS for item in right.get(field, [])}
            overlap = left_surfaces & right_surfaces
            ordered = right_id in closure.get(left_id, set()) or left_id in closure.get(right_id, set())
            serialized = right_id in left.get("serializes_with", []) or left_id in right.get("serializes_with", [])
            if overlap and not ordered and not serialized:
                report.warn(
                    f"{left_id} and {right_id}: overlapping parallel surfaces without ordering/serialization: "
                    + ", ".join(sorted(overlap))
                )


def validate_acceptance(data: dict, by_id: dict[str, dict], report: Report) -> None:
    acceptance = data.get("epic_acceptance")
    if not isinstance(acceptance, dict):
        report.error("epic_acceptance must be an object")
        return
    owner = acceptance.get("owner_ticket_id")
    if owner not in by_id:
        report.error("epic_acceptance.owner_ticket_id must resolve to a ticket")
    elif by_id[owner].get("kind") != "capstone":
        report.error("epic acceptance owner must be a capstone ticket")
    if not string_list(acceptance.get("evidence")) or not acceptance.get("evidence"):
        report.error("epic_acceptance.evidence must be a non-empty array")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate_build_order.py path/to/build-order.json", file=sys.stderr)
        return 64
    report = Report()
    data = load(Path(argv[1]), report)
    if data:
        validate_header(data, report)
        requirement_ids = validate_requirements(data, report)
        by_id = validate_tickets(data, requirement_ids, report)
        validate_references(data, by_id, report)
        closure = dependency_closure(by_id, report)
        validate_phases(by_id, report)
        validate_surface_conflicts(by_id, closure, report)
        validate_acceptance(data, by_id, report)
    for message in report.errors:
        print(f"ERROR: {message}")
    for message in report.warnings:
        print(f"WARN: {message}")
    print(f"validation: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
