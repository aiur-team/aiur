"""Validate frozen expected and freshly observed exact GitHub issue titles."""

from __future__ import annotations

from typing import Any

from publication_common import Report, valid_issue_title


EXPECTED_FIELD = "expected_issue_titles"
OBSERVED_FIELD = "observed_issue_titles"


def validate_all_title_evidence(
    build: dict[str, Any], companions: dict[str, Any], publication: dict[str, Any],
    independently_rendered: dict[str, str] | None,
    materialized: bool, report: Report,
) -> None:
    if not materialized:
        return
    core_ids, dash_ids, skill_ids = _partitions(build, companions, publication)
    all_ids = core_ids | dash_ids | skill_ids
    if independently_rendered is None:
        report.error("materialized publication requires approved title expectations")
        independently_rendered = {}
    elif set(independently_rendered) != all_ids:
        report.error(
            "approved title expectations must exactly cover root, BO, DASH, and skill issues"
        )

    validated: set[str] = set()
    for data, identities, label in (
        (build, core_ids, "Build Order receipt"),
        (companions, dash_ids, "companion receipt"),
        (publication, skill_ids, "publication receipt"),
    ):
        receipt = data.get("github_reconciliation")
        if not isinstance(receipt, dict):
            report.error(f"materialized {label} requires github_reconciliation")
            continue
        expected = _title_map(
            receipt.get(EXPECTED_FIELD), identities, f"{label}.{EXPECTED_FIELD}",
            report,
        )
        observed = _title_map(
            receipt.get(OBSERVED_FIELD), identities, f"{label}.{OBSERVED_FIELD}",
            report,
        )
        for identity in sorted(identities):
            frozen = expected.get(identity)
            approved = independently_rendered.get(identity)
            live = observed.get(identity)
            if frozen != approved:
                report.error(
                    f"{label}.{EXPECTED_FIELD}.{identity} must match the "
                    "independently rendered approved title"
                )
            if live != approved:
                report.error(
                    f"{label}.{OBSERVED_FIELD}.{identity} must exactly match the "
                    "independently rendered approved title"
                )
            if frozen == approved == live and isinstance(live, str):
                validated.add(identity)
    if validated != all_ids:
        report.error(
            "combined exact title evidence must cover root, BO, DASH, and skill issues"
        )


def _title_map(
    value: object, identities: set[str], label: str, report: Report,
) -> dict[str, str]:
    if not isinstance(value, dict):
        report.error(f"{label} must be an object")
        return {}
    if set(value) != identities:
        report.error(f"{label} keys must match its owned issues")
    result: dict[str, str] = {}
    for identity in sorted(identities):
        title = value.get(identity)
        if not valid_issue_title(title):
            report.error(
                f"{label}.{identity} must be a trimmed single-line GitHub issue title"
            )
        else:
            assert isinstance(title, str)
            result[identity] = title
    return result


def _partitions(
    build: dict[str, Any], companions: dict[str, Any], publication: dict[str, Any],
) -> tuple[set[str], set[str], set[str]]:
    core_ids = _ticket_ids(build, "BO")
    root_id = build.get("build_order_id")
    if isinstance(root_id, str):
        core_ids.add(root_id)
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    skill_ids = {skill_id} if isinstance(skill_id, str) else set()
    return core_ids, _ticket_ids(companions, "DASH"), skill_ids


def _ticket_ids(data: dict[str, Any], prefix: str) -> set[str]:
    tickets = data.get("tickets")
    if not isinstance(tickets, list):
        return set()
    return {
        ticket["id"] for ticket in tickets
        if isinstance(ticket, dict) and isinstance(ticket.get("id"), str)
        and ticket["id"].startswith(f"{prefix}-")
    }
