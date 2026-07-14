"""Validate Build Order requirement dispositions."""

from __future__ import annotations

from typing import Any

from validation_common import (
    DISPOSITIONS,
    REQ_ID,
    Report,
    checked_string_list,
    nonempty_string,
    strict_object,
)


def validate_requirements(
    data: dict[str, Any], report: Report,
) -> dict[str, dict[str, Any]]:
    values = data.get("requirements")
    if not isinstance(values, list) or not values:
        report.error("requirements must be a non-empty array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    keys = {"id", "summary", "disposition", "ticket_ids", "reason"}
    for index, value in enumerate(values):
        label = f"requirements[{index}]"
        requirement = strict_object(value, label, keys, report)
        if requirement is None:
            continue
        req_id = requirement.get("id")
        if not isinstance(req_id, str) or not REQ_ID.fullmatch(req_id):
            report.error(f"{label}.id must be a full stable requirement ID")
            continue
        if req_id in found:
            report.error(f"duplicate requirement id {req_id}")
        else:
            found[req_id] = requirement
        if not nonempty_string(requirement.get("summary")):
            report.error(f"{req_id}.summary must be a non-empty string")
        disposition = requirement.get("disposition")
        if not isinstance(disposition, str) or disposition not in DISPOSITIONS:
            report.error(f"{req_id}: invalid disposition {disposition!r}")
        ticket_ids = checked_string_list(
            requirement.get("ticket_ids"), f"{req_id}.ticket_ids", report,
        )
        reason = requirement.get("reason")
        if disposition == "ticket":
            if not ticket_ids:
                report.error(f"{req_id}: ticket disposition requires ticket_ids")
            if reason is not None:
                report.error(f"{req_id}: ticket disposition requires null reason")
        elif isinstance(disposition, str) and disposition in {
            "deferred", "rejected", "satisfied",
        }:
            if ticket_ids:
                report.error(f"{req_id}: {disposition} disposition cannot have ticket_ids")
            if not nonempty_string(reason):
                report.error(f"{req_id}: {disposition} disposition requires reason")
    return found
