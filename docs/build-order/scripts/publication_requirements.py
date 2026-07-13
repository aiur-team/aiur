"""Validate the bounded dashboard requirement projection in the merged graph."""

from __future__ import annotations

from typing import Any

from publication_common import DASH_ID, REQ_ID, Report, safe_string_list


def validate_requirement_coverage(
    tickets: dict[str, dict[str, Any]], report: Report
) -> None:
    # The expected sets are derived from the manifest's DASH ticket count:
    # exactly one contiguous DASH-001..N ticket per contiguous DREQ-001..N
    # dashboard requirement inside the consolidated Build Order.
    dash = {
        ticket_id: ticket
        for ticket_id, ticket in tickets.items()
        if DASH_ID.fullmatch(ticket_id)
    }
    expected_tickets = {f"DASH-{number:03d}" for number in range(1, len(dash) + 1)}
    expected_requirements = {
        f"DREQ-{number:03d}" for number in range(1, len(dash) + 1)
    }
    ticket_ids = set(dash)
    if ticket_ids != expected_tickets:
        missing = sorted(expected_tickets - ticket_ids)
        extra = sorted(ticket_ids - expected_tickets)
        if missing:
            report.error("dashboard ticket set missing: " + ", ".join(missing))
        if extra:
            report.error("dashboard ticket set has unexpected IDs: " + ", ".join(extra))

    refs = [
        item
        for ticket in dash.values()
        for item in safe_string_list(ticket.get("requirement_refs"))
        if REQ_ID.fullmatch(item)
    ]
    valid_refs = set(refs)
    if valid_refs != expected_requirements:
        missing = sorted(expected_requirements - valid_refs)
        extra = sorted(valid_refs - expected_requirements)
        if missing:
            report.error("dashboard requirement coverage missing: " + ", ".join(missing))
        if extra:
            report.error("dashboard requirement coverage has unexpected IDs: " + ", ".join(extra))
    duplicates = sorted({item for item in valid_refs if refs.count(item) > 1})
    if duplicates:
        report.error("dashboard requirement references must be unique: " + ", ".join(duplicates))
