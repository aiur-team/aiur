"""Validate worker-facing ticket records and their local documents."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from validation_common import (
    EDGE_FIELDS,
    KINDS,
    PROVENANCE,
    RUNNABLE_KINDS,
    SURFACE_FIELDS,
    TICKET_ID,
    Report,
    checked_string_list,
    nonempty_string,
    strict_int,
    strict_object,
)
from validation_documents import validate_document


TICKET_KEYS = {
    "id", "kind", "provenance", "introduced_in_plan_version", "discovered_from",
    "title", "document", "outcome", "scope", "non_goals", "phase_hint",
    "complexity_points", "complexity_rationale", "risk", "capability_requirements",
    "workstream", "requirement_refs", "depends_on", "serializes_with",
    "suggested_after", "contains", "external_gates", "read_surfaces",
    "write_surfaces", "contract_surfaces", "safety_surfaces",
    "conflict_exceptions", "acceptance", "decision_refs",
    "design_evidence_refs", "github",
}
ACCEPTANCE_KEYS = {"agent_gate", "at_merge_gate", "human_or_e2e"}
EXCEPTION_KEYS = {"ticket_id", "surfaces", "reason"}
POINTERS_DOCUMENT = "08-implementation-pointers.md"
POINTER_HEADING = re.compile(r"^### (?P<ticket>[A-Z][A-Z0-9]*-[0-9]{3,}[A-Z]?)\s*$", re.MULTILINE)


def validate_acceptance(ticket_id: str, value: object, runnable: bool, report: Report) -> None:
    acceptance = strict_object(value, f"{ticket_id}.acceptance", ACCEPTANCE_KEYS, report)
    if acceptance is None:
        return
    agent = checked_string_list(acceptance.get("agent_gate"), f"{ticket_id}.acceptance.agent_gate", report)
    at_merge = checked_string_list(
        acceptance.get("at_merge_gate"), f"{ticket_id}.acceptance.at_merge_gate", report
    )
    human = checked_string_list(
        acceptance.get("human_or_e2e"), f"{ticket_id}.acceptance.human_or_e2e", report
    )
    if runnable and not agent:
        report.error(f"{ticket_id}: runnable ticket needs an agent acceptance gate")
    if runnable and not at_merge:
        report.error(f"{ticket_id}: runnable ticket needs an at-merge acceptance gate")
    if not runnable and any((agent, at_merge, human)):
        report.error(f"{ticket_id}: umbrella acceptance lists must be empty")


def validate_exceptions(ticket_id: str, value: object, report: Report) -> None:
    if not isinstance(value, list):
        report.error(f"{ticket_id}.conflict_exceptions must be an array")
        return
    targets: set[str] = set()
    for index, item in enumerate(value):
        label = f"{ticket_id}.conflict_exceptions[{index}]"
        exception = strict_object(item, label, EXCEPTION_KEYS, report)
        if exception is None:
            continue
        target = exception.get("ticket_id")
        if not nonempty_string(target):
            report.error(f"{label}.ticket_id must be a non-empty string")
        elif target in targets:
            report.error(f"{ticket_id}: duplicate conflict exception for {target}")
        else:
            targets.add(target)
        checked_string_list(exception.get("surfaces"), f"{label}.surfaces", report, require_items=True)
        if not nonempty_string(exception.get("reason")):
            report.error(f"{label}.reason must be a non-empty string")


def validate_ticket_fields(
    ticket_id: str, ticket: dict[str, Any], data: dict[str, Any], base_dir: Path, report: Report
) -> None:
    kind = ticket.get("kind")
    if not isinstance(kind, str) or kind not in KINDS:
        report.error(f"{ticket_id}: invalid kind {kind!r}")
    runnable = isinstance(kind, str) and kind in RUNNABLE_KINDS
    provenance = ticket.get("provenance")
    if not isinstance(provenance, str) or provenance not in PROVENANCE:
        report.error(f"{ticket_id}: provenance must be planned or discovered")
    source = ticket.get("discovered_from")
    if provenance == "planned" and source is not None:
        report.error(f"{ticket_id}: planned ticket discovered_from must be null")
    if provenance == "discovered" and (
        not isinstance(source, str) or not TICKET_ID.fullmatch(source)
    ):
        report.error(f"{ticket_id}: discovered ticket requires a ticket ID in discovered_from")
    version = ticket.get("introduced_in_plan_version")
    plan_version = data.get("plan_version")
    if not strict_int(version) or not strict_int(plan_version) or not 1 <= version <= plan_version:
        report.error(f"{ticket_id}: introduced plan version must be within the current plan")
    for field in ("title", "outcome", "complexity_rationale", "risk"):
        value = ticket.get(field)
        if field in {"complexity_rationale", "risk"} and not runnable and value is None:
            continue
        if not nonempty_string(value):
            report.error(f"{ticket_id}.{field} must be a non-empty string")
    validate_document(ticket_id, ticket.get("document"), ticket, data, base_dir, report)
    phase = ticket.get("phase_hint")
    if not strict_int(phase) or phase < 1:
        report.error(f"{ticket_id}.phase_hint must be a positive integer")
    points = ticket.get("complexity_points")
    if runnable and (not strict_int(points) or not 1 <= points <= 5):
        report.error(f"{ticket_id}: runnable complexity_points must be integer 1..5")
    if not runnable and points is not None:
        report.error(f"{ticket_id}: umbrella complexity_points must be null")
    for field in (
        "scope", "non_goals", "capability_requirements", "requirement_refs",
        "decision_refs", "design_evidence_refs",
    ):
        required = field in {"scope", "non_goals"} or (runnable and field in {"capability_requirements", "requirement_refs"})
        checked_string_list(ticket.get(field), f"{ticket_id}.{field}", report, require_items=required)
    for field in EDGE_FIELDS + ("contains", "external_gates", "read_surfaces") + SURFACE_FIELDS:
        checked_string_list(ticket.get(field), f"{ticket_id}.{field}", report)
    if not nonempty_string(ticket.get("workstream")):
        report.error(f"{ticket_id}.workstream must be a non-empty string")
    validate_exceptions(ticket_id, ticket.get("conflict_exceptions"), report)
    validate_acceptance(ticket_id, ticket.get("acceptance"), runnable, report)


def validate_tickets(
    data: dict[str, Any], base_dir: Path, report: Report
) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list) or not values:
        report.error("tickets must be a non-empty array")
        return {}
    by_id: dict[str, dict[str, Any]] = {}
    prefix = data.get("ticket_prefix")
    prefixes = prefix if isinstance(prefix, list) else [prefix]
    expected = (
        re.compile(
            "^(?:" + "|".join(re.escape(item) for item in prefixes) + ")-[0-9]{3,}[A-Z]?$",
            re.ASCII,
        )
        if prefixes and all(isinstance(item, str) and item for item in prefixes)
        else None
    )
    for index, value in enumerate(values):
        label = f"tickets[{index}]"
        ticket = strict_object(value, label, TICKET_KEYS, report)
        if ticket is None:
            continue
        ticket_id = ticket.get("id")
        if not isinstance(ticket_id, str) or not TICKET_ID.fullmatch(ticket_id):
            report.error(f"{label}.id must be a full stable ticket ID")
            continue
        if expected is not None and not expected.fullmatch(ticket_id):
            report.error(f"{ticket_id}: id does not match ticket_prefix {prefix}")
        if ticket_id in by_id:
            report.error(f"duplicate ticket id {ticket_id}")
            continue
        by_id[ticket_id] = ticket
        validate_ticket_fields(ticket_id, ticket, data, base_dir, report)
    return by_id


def validate_implementation_pointers(
    by_id: dict[str, dict[str, Any]], base_dir: Path, report: Report,
) -> None:
    """Require exactly one implementation-pointer heading per manifest ticket."""
    path = base_dir / POINTERS_DOCUMENT
    required = any(
        _document_links_pointer_map(ticket, base_dir) for ticket in by_id.values()
    )
    if not required and not path.exists() and not path.is_symlink():
        return
    if path.is_symlink() or not path.exists():
        report.error(f"{POINTERS_DOCUMENT} must be a regular non-symlink file")
        return
    if not path.is_file():
        report.error(f"{POINTERS_DOCUMENT} must be a regular non-symlink file")
        return
    try:
        body = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        report.error(f"cannot read {POINTERS_DOCUMENT}: {exc}")
        return
    headings = [match.group("ticket") for match in POINTER_HEADING.finditer(body)]
    counts = {ticket_id: headings.count(ticket_id) for ticket_id in set(headings)}
    for ticket_id in sorted(by_id):
        count = counts.get(ticket_id, 0)
        if count != 1:
            report.error(
                f"{POINTERS_DOCUMENT} must contain exactly one ### {ticket_id} "
                f"section; found {count}"
            )
    for ticket_id in sorted(set(headings) - set(by_id)):
        report.error(
            f"{POINTERS_DOCUMENT} contains unknown ticket section {ticket_id}"
        )


def _document_links_pointer_map(ticket: dict[str, Any], base_dir: Path) -> bool:
    relative = ticket.get("document")
    if not isinstance(relative, str):
        return False
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        return False
    try:
        return POINTERS_DOCUMENT in (base_dir / path).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return False
