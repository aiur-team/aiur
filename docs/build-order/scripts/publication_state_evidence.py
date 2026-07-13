"""Validate freshly observed OPEN issue state across every published issue."""

from __future__ import annotations

from typing import Any

from publication_common import Report


STATE_FIELD = "observed_issue_states"
OPEN = "OPEN"
CORE_RECEIPT_VERSION = 3
AUXILIARY_RECEIPT_VERSION = 2


def validate_all_issue_state_evidence(
    build: dict[str, Any], publication: dict[str, Any],
    materialized: bool, report: Report,
) -> None:
    """Require one exact, non-overlapping OPEN-state observation for every issue.

    The covered identity set is derived from the manifests: the root, the
    skill-delivery issue, and every consolidated Build Order ticket.
    """
    if not materialized:
        return
    core_ids, skill_ids = _partitions(build, publication)
    expected = core_ids | skill_ids
    observed: set[str] = set()
    for data, identities, label, version in (
        (build, core_ids, "Build Order receipt", CORE_RECEIPT_VERSION),
        (
            publication, skill_ids, "publication receipt",
            AUXILIARY_RECEIPT_VERSION,
        ),
    ):
        receipt = data.get("github_reconciliation")
        if not isinstance(receipt, dict):
            report.error(f"materialized {label} requires github_reconciliation")
            continue
        if receipt.get("receipt_schema_version") != version:
            report.error(
                f"{label}.receipt_schema_version must be integer {version}"
            )
        states = receipt.get(STATE_FIELD)
        field_label = f"{label}.{STATE_FIELD}"
        if not isinstance(states, dict):
            report.error(f"{field_label} must be an object")
            continue
        if set(states) != identities:
            report.error(f"{field_label} keys must match its owned issues")
        for identity in sorted(identities):
            state = states.get(identity)
            if state != OPEN:
                report.error(f"{field_label}.{identity} must equal {OPEN}")
            else:
                observed.add(identity)
    if observed != expected:
        report.error(
            "combined OPEN issue-state evidence must exactly cover root, "
            "ticket, and skill issues"
        )


def _partitions(
    build: dict[str, Any], publication: dict[str, Any],
) -> tuple[set[str], set[str]]:
    core_ids = _ticket_ids(build)
    root_id = build.get("build_order_id")
    if isinstance(root_id, str):
        core_ids.add(root_id)
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    skill_ids = {skill_id} if isinstance(skill_id, str) else set()
    return core_ids, skill_ids


def _ticket_ids(data: dict[str, Any]) -> set[str]:
    tickets = data.get("tickets")
    if not isinstance(tickets, list):
        return set()
    return {
        ticket["id"] for ticket in tickets
        if isinstance(ticket, dict) and isinstance(ticket.get("id"), str)
    }
