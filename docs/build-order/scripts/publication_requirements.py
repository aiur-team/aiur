"""Validate the bounded companion requirement projection."""

from __future__ import annotations

from typing import Any

from publication_common import Report


EXPECTED_REQUIREMENTS = {f"DREQ-{number:03d}" for number in range(1, 16)}
EXPECTED_TICKETS = {f"DASH-{number:03d}" for number in range(1, 16)}


def validate_requirement_coverage(
    tickets: dict[str, dict[str, Any]], report: Report
) -> None:
    ticket_ids = set(tickets)
    if ticket_ids != EXPECTED_TICKETS:
        missing = sorted(EXPECTED_TICKETS - ticket_ids)
        extra = sorted(ticket_ids - EXPECTED_TICKETS)
        if missing:
            report.error("companion ticket set missing: " + ", ".join(missing))
        if extra:
            report.error("companion ticket set has unexpected IDs: " + ", ".join(extra))

    refs = [ticket.get("requirement_ref") for ticket in tickets.values()]
    valid_refs = {item for item in refs if isinstance(item, str)}
    if valid_refs != EXPECTED_REQUIREMENTS:
        missing = sorted(EXPECTED_REQUIREMENTS - valid_refs)
        extra = sorted(valid_refs - EXPECTED_REQUIREMENTS)
        if missing:
            report.error("companion requirement coverage missing: " + ", ".join(missing))
        if extra:
            report.error("companion requirement coverage has unexpected IDs: " + ", ".join(extra))
    duplicates = sorted({item for item in valid_refs if refs.count(item) > 1})
    if duplicates:
        report.error("companion requirement references must be unique: " + ", ".join(duplicates))
