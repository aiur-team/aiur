"""Validate canonical body receipts and exact logical-marker query matches."""

from __future__ import annotations

from typing import Any

from publication_common import GITHUB_KEYS, Report, strict_object
from publication_rendering import BODY_SHA, EVIDENCE_KEYS


def validate_all_body_evidence(
    build: dict[str, Any], publication: dict[str, Any],
    mappings: dict[str, dict[str, Any] | None],
    expected: dict[str, dict[str, Any]] | None,
    materialized: bool, report: Report,
) -> None:
    if not materialized:
        return
    approved = publication.get("approved_planning_commit")
    plan_version = build.get("plan_version")
    core_receipt = _receipt(build, "Build Order", report)
    auxiliary_receipt = _receipt(publication, "publication", report)
    core_approved = core_receipt.get("approved_planning_commit")
    if core_approved != approved:
        report.error("Build Order receipt approved commit must match publication")
    core_ids, skill_ids = _partitions(build, publication)
    all_ids = core_ids | skill_ids
    if expected is None:
        report.error("materialized publication requires approved body expectations")
        expected = {}
    elif set(expected) != all_ids:
        report.error("approved body expectations must exactly cover all published issues")
    evidence: dict[str, str] = {}
    _merge_evidence(
        evidence, core_receipt.get("observed_body_evidence"), core_ids,
        core_approved, plan_version, expected, "Build Order receipt", report,
    )
    _merge_evidence(
        evidence, auxiliary_receipt.get("observed_body_evidence"), skill_ids,
        approved, plan_version, expected, "publication receipt", report,
    )
    root_id = build.get("build_order_id")
    core_mappings = {
        identity: mappings.get("github_root" if identity == root_id else identity)
        for identity in core_ids
    }
    _validate_query_matches(
        core_receipt.get("marker_query_matches"), core_mappings,
        "Build Order receipt", report,
    )
    auxiliary_mappings = auxiliary_receipt.get("issue_mappings")
    skill_mappings = {
        identity: auxiliary_mappings.get(identity)
        if isinstance(auxiliary_mappings, dict) else None
        for identity in skill_ids
    }
    _validate_query_matches(
        auxiliary_receipt.get("marker_query_matches"), skill_mappings,
        "publication receipt", report,
    )
    _validate_coverage(evidence, all_ids, report)


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


def _validate_coverage(
    evidence: dict[str, str], expected: set[str], report: Report,
) -> None:
    if set(evidence) != expected:
        report.error("combined body evidence must exactly cover root, ticket, and skill issues")
    owners: dict[str, str] = {}
    for identity, body_sha in evidence.items():
        if body_sha in owners:
            report.error(f"observed body SHA-256 for {identity} duplicates {owners[body_sha]}")
        else:
            owners[body_sha] = identity


def _receipt(data: dict[str, Any], label: str, report: Report) -> dict[str, Any]:
    value = data.get("github_reconciliation")
    if not isinstance(value, dict):
        report.error(f"materialized {label} data requires github_reconciliation")
        return {}
    return value


def _ticket_ids(data: dict[str, Any]) -> set[str]:
    tickets = data.get("tickets")
    if not isinstance(tickets, list):
        return set()
    return {
        item["id"] for item in tickets
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _merge_evidence(
    combined: dict[str, str], value: object, identities: set[str], approved: object,
    plan_version: object, expected: dict[str, dict[str, Any]], label: str,
    report: Report,
) -> None:
    if not isinstance(value, dict):
        report.error(f"{label}.observed_body_evidence must be an object")
        return
    if set(value) != identities:
        report.error(f"{label}.observed_body_evidence keys must match its owned issues")
    for identity in sorted(identities):
        item_label = f"{label}.observed_body_evidence.{identity}"
        evidence = strict_object(value.get(identity), item_label, EVIDENCE_KEYS, report)
        if evidence is None:
            continue
        _validate_claims(evidence, identity, approved, plan_version, item_label, report)
        expected_item = expected.get(identity)
        if isinstance(expected_item, dict):
            for key in sorted(EVIDENCE_KEYS):
                if evidence.get(key) != expected_item.get(key):
                    report.error(
                        f"{item_label}.{key} must match the independently rendered approved body"
                    )
        body_sha = evidence.get("body_sha256")
        if isinstance(body_sha, str) and BODY_SHA.fullmatch(body_sha):
            combined[identity] = body_sha


def _validate_claims(
    evidence: dict[str, Any], identity: str, approved: object,
    plan_version: object, label: str, report: Report,
) -> None:
    checks = (
        ("marker_count", 1),
        ("marker_schema_version", 2),
        ("marker_logical_id", identity),
        ("marker_plan_version", plan_version),
        ("approved_planning_commit", approved),
        ("approved_link_count", 1),
    )
    for key, expected in checks:
        if evidence.get(key) != expected:
            report.error(f"{label}.{key} must equal {expected}")
    body_sha = evidence.get("body_sha256")
    if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
        report.error(f"{label}.body_sha256 must be a lowercase SHA-256")


def _validate_query_matches(
    value: object, expected: dict[str, dict[str, Any] | None],
    label: str, report: Report,
) -> None:
    query_label = f"{label}.marker_query_matches"
    if not isinstance(value, dict):
        report.error(f"{query_label} must be an object")
        return
    if set(value) != set(expected):
        report.error(f"{query_label} keys must match its owned issues")
    for identity in sorted(expected):
        matches = value.get(identity)
        item_label = f"{query_label}.{identity}"
        if not isinstance(matches, list):
            report.error(f"{item_label} must be an array")
            continue
        if len(matches) != 1:
            report.error(f"{item_label} must contain exactly one issue match")
        for index, raw in enumerate(matches):
            match = strict_object(raw, f"{item_label}[{index}]", GITHUB_KEYS, report)
            if match is not None and match != expected.get(identity):
                report.error(f"{item_label}[{index}] must equal the returned GitHub mapping")
