"""Validate approved issue bodies and exact logical-marker query results."""

from __future__ import annotations

from typing import Any

from validation_common import SHA, Report, strict_object
from validation_github_rendering import (
    BODY_SHA,
    EVIDENCE_KEYS,
    validate_expected_evidence,
)


GITHUB_KEYS = {"repository", "number", "node_id", "url"}


def validate_body_evidence(
    value: object,
    identities: set[str],
    approved: object,
    plan_version: object,
    expected: dict[str, dict[str, Any]] | None,
    report: Report,
) -> None:
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error(
            "github_reconciliation.approved_planning_commit must be a Git SHA"
        )
    if type(plan_version) is not int or plan_version < 1:
        report.error("plan_version must be available for body evidence validation")
    if expected is None:
        report.error(
            "materialized GitHub receipt requires independently rendered "
            "approved body expectations"
        )
    elif set(expected) != identities:
        report.error("approved body expectations keys must match root and tickets")
    if not isinstance(value, dict):
        report.error("github_reconciliation.observed_body_evidence must be an object")
        return
    if set(value) != identities:
        report.error(
            "github_reconciliation.observed_body_evidence keys must match root and tickets"
        )
    for identity in sorted(identities):
        label = f"github_reconciliation.observed_body_evidence.{identity}"
        evidence = validate_expected_evidence(value.get(identity), label, report)
        if evidence is None:
            continue
        if evidence.get("marker_count") != 1:
            report.error(f"{label}.marker_count must equal 1")
        if evidence.get("marker_schema_version") != 2:
            report.error(f"{label}.marker_schema_version must equal 2")
        if evidence.get("marker_logical_id") != identity:
            report.error(f"{label}.marker_logical_id must equal {identity}")
        if evidence.get("marker_plan_version") != plan_version:
            report.error(f"{label}.marker_plan_version must match plan_version")
        if evidence.get("approved_planning_commit") != approved:
            report.error(f"{label}.approved_planning_commit must match the receipt")
        if evidence.get("approved_link_count") != 1:
            report.error(f"{label}.approved_link_count must equal 1")
        body_sha = evidence.get("body_sha256")
        if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
            report.error(f"{label}.body_sha256 must be a lowercase SHA-256")
        expected_item = expected.get(identity) if expected is not None else None
        if isinstance(expected_item, dict):
            _compare_expected(evidence, expected_item, label, report)


def validate_marker_query_matches(
    value: object,
    expected_mappings: dict[str, dict[str, Any] | None],
    report: Report,
) -> None:
    label = "github_reconciliation.marker_query_matches"
    if not isinstance(value, dict):
        report.error(f"{label} must be an object")
        return
    if set(value) != set(expected_mappings):
        report.error(f"{label} keys must match root and tickets")
    for identity in sorted(expected_mappings):
        matches = value.get(identity)
        item_label = f"{label}.{identity}"
        if not isinstance(matches, list):
            report.error(f"{item_label} must be an array")
            continue
        if len(matches) != 1:
            report.error(f"{item_label} must contain exactly one issue match")
        for index, raw in enumerate(matches):
            match = strict_object(raw, f"{item_label}[{index}]", GITHUB_KEYS, report)
            if match is not None and match != expected_mappings.get(identity):
                report.error(f"{item_label}[{index}] must equal the returned GitHub mapping")


def _compare_expected(
    observed: dict[str, Any], expected: dict[str, Any], label: str, report: Report,
) -> None:
    expected_item = validate_expected_evidence(
        expected, f"approved body expectations.{observed.get('marker_logical_id')}", report
    )
    if expected_item is None:
        return
    for key in sorted(EVIDENCE_KEYS):
        if observed.get(key) != expected_item.get(key):
            report.error(f"{label}.{key} must match the independently rendered approved body")
