"""Validate partitioned and unique body evidence for all published issues."""

from __future__ import annotations

import re
from typing import Any

from publication_common import Report, strict_object


EVIDENCE_KEYS = {"marker_logical_id", "approved_planning_commit", "body_sha256"}
BODY_SHA = re.compile(r"^[0-9a-f]{64}$", re.ASCII)
EXPECTED_BODY_COUNT = 32


def validate_all_body_evidence(
    build: dict[str, Any], companions: dict[str, Any], publication: dict[str, Any],
    materialized: bool, report: Report,
) -> None:
    if not materialized:
        return
    approved = companions.get("approved_planning_commit")
    receipts = (
        _receipt(build, "Build Order", report),
        _receipt(companions, "companion", report),
        _receipt(publication, "publication", report),
    )
    core_receipt, dash_receipt, auxiliary_receipt = receipts
    core_approved = core_receipt.get("approved_planning_commit")
    if core_approved != approved:
        report.error("Build Order receipt approved commit must match companions")
    core_ids, dash_ids, skill_ids = _partitions(build, companions, publication)
    evidence: dict[str, str] = {}
    _merge_evidence(
        evidence, core_receipt.get("observed_body_evidence"), core_ids,
        core_approved, "Build Order receipt", report,
    )
    _merge_evidence(
        evidence, dash_receipt.get("observed_body_evidence"), dash_ids,
        approved, "companion receipt", report,
    )
    _merge_evidence(
        evidence, auxiliary_receipt.get("observed_body_evidence"), skill_ids,
        approved, "publication receipt", report,
    )
    _validate_coverage(evidence, core_ids | dash_ids | skill_ids, report)


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


def _validate_coverage(
    evidence: dict[str, str], expected: set[str], report: Report,
) -> None:
    if len(expected) != EXPECTED_BODY_COUNT:
        report.error(f"materialization must contain exactly {EXPECTED_BODY_COUNT} issue bodies")
    if set(evidence) != expected:
        report.error("combined body evidence must exactly cover root, BO, DASH, and skill issues")
    _unique_hashes(evidence, report)


def _receipt(data: dict[str, Any], label: str, report: Report) -> dict[str, Any]:
    value = data.get("github_reconciliation")
    if not isinstance(value, dict):
        report.error(f"materialized {label} data requires github_reconciliation")
        return {}
    return value


def _ticket_ids(data: dict[str, Any], prefix: str) -> set[str]:
    tickets = data.get("tickets")
    if not isinstance(tickets, list):
        return set()
    return {
        item["id"] for item in tickets
        if isinstance(item, dict) and isinstance(item.get("id"), str)
        and item["id"].startswith(f"{prefix}-")
    }


def _merge_evidence(
    combined: dict[str, str], value: object, identities: set[str], approved: object,
    label: str, report: Report,
) -> None:
    if not isinstance(value, dict):
        report.error(f"{label}.observed_body_evidence must be an object")
        return
    if set(value) != identities:
        report.error(f"{label}.observed_body_evidence keys must match its owned issues")
    for identity in sorted(identities):
        item_label = f"{label}.observed_body_evidence.{identity}"
        marker = strict_object(value.get(identity), item_label, EVIDENCE_KEYS, report)
        if marker is None:
            continue
        body_sha = _validate_marker(marker, identity, approved, item_label, report)
        if body_sha is not None:
            combined[identity] = body_sha


def _validate_marker(
    marker: dict[str, Any], identity: str, approved: object,
    label: str, report: Report,
) -> str | None:
    if marker.get("marker_logical_id") != identity:
        report.error(f"{label}.marker_logical_id must equal {identity}")
    if marker.get("approved_planning_commit") != approved:
        report.error(f"{label}.approved_planning_commit must match the receipt")
    body_sha = marker.get("body_sha256")
    if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
        report.error(f"{label}.body_sha256 must be a lowercase SHA-256")
        return None
    return body_sha


def _unique_hashes(evidence: dict[str, str], report: Report) -> None:
    owners: dict[str, str] = {}
    for identity, body_sha in evidence.items():
        if body_sha in owners:
            report.error(
                f"observed body SHA-256 for {identity} duplicates {owners[body_sha]}"
            )
        else:
            owners[body_sha] = identity
