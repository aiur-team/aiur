"""Validate the bounded companion requirement projection."""

from __future__ import annotations

from typing import Any

from publication_common import Report


def validate_requirement_coverage(
    tickets: dict[str, dict[str, Any]], report: Report
) -> None:
    # The expected sets are derived from the manifest's ticket count: exactly
    # one contiguous DASH-001..N ticket per contiguous DREQ-001..N requirement.
    expected_tickets = {f"DASH-{number:03d}" for number in range(1, len(tickets) + 1)}
    expected_requirements = {
        f"DREQ-{number:03d}" for number in range(1, len(tickets) + 1)
    }
    ticket_ids = set(tickets)
    if ticket_ids != expected_tickets:
        missing = sorted(expected_tickets - ticket_ids)
        extra = sorted(ticket_ids - expected_tickets)
        if missing:
            report.error("companion ticket set missing: " + ", ".join(missing))
        if extra:
            report.error("companion ticket set has unexpected IDs: " + ", ".join(extra))

    refs = [ticket.get("requirement_ref") for ticket in tickets.values()]
    valid_refs = {item for item in refs if isinstance(item, str)}
    if valid_refs != expected_requirements:
        missing = sorted(expected_requirements - valid_refs)
        extra = sorted(valid_refs - expected_requirements)
        if missing:
            report.error("companion requirement coverage missing: " + ", ".join(missing))
        if extra:
            report.error("companion requirement coverage has unexpected IDs: " + ", ".join(extra))
    duplicates = sorted({item for item in valid_refs if refs.count(item) > 1})
    if duplicates:
        report.error("companion requirement references must be unique: " + ", ".join(duplicates))
