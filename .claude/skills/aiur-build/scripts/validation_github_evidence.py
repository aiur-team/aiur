"""Validate observed issue-body evidence in a GitHub publication receipt."""

from __future__ import annotations

import re

from validation_common import SHA, Report, nonempty_string, strict_object


MARKER_KEYS = {"marker_logical_id", "approved_planning_commit", "body_sha256"}
BODY_SHA = re.compile(r"^[0-9a-f]{64}$", re.ASCII)


def validate_body_evidence(
    value: object,
    identities: set[str],
    approved: object,
    report: Report,
) -> None:
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error(
            "github_reconciliation.approved_planning_commit must be a Git SHA"
        )
    if not isinstance(value, dict):
        report.error("github_reconciliation.observed_body_evidence must be an object")
        return
    if set(value) != identities:
        report.error(
            "github_reconciliation.observed_body_evidence keys must match root and tickets"
        )
    for identity in sorted(identities):
        label = f"github_reconciliation.observed_body_evidence.{identity}"
        marker = strict_object(value.get(identity), label, MARKER_KEYS, report)
        if marker is None:
            continue
        if marker.get("marker_logical_id") != identity:
            report.error(f"{label}.marker_logical_id must equal {identity}")
        marker_approval = marker.get("approved_planning_commit")
        if not nonempty_string(marker_approval) or marker_approval != approved:
            report.error(f"{label}.approved_planning_commit must match the receipt")
        body_sha = marker.get("body_sha256")
        if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
            report.error(f"{label}.body_sha256 must be a lowercase SHA-256")
