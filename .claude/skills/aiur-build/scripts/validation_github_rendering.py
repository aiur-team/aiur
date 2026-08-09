"""Deterministically render and inspect approved GitHub issue bodies."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from validation_common import SHA, Report, strict_object
from publication_body_limits import MAX_ISSUE_BODY_CHARACTERS


MARKER_NAME = "aiur-planning-issue"
MARKER_KEYS = {
    "schema", "logical_id", "plan_version", "approved_planning_commit",
}
EVIDENCE_KEYS = {
    "marker_count",
    "marker_schema_version",
    "marker_logical_id",
    "marker_plan_version",
    "approved_planning_commit",
    "approved_link_count",
    "approved_link",
    "body_sha256",
}
BODY_SHA = re.compile(r"^[0-9a-f]{64}$", re.ASCII)
COMMIT_LINK = re.compile(
    r"https://github\.com/[^/\s)]+/[^/\s)]+/commit/[0-9a-fA-F]{40}",
    re.ASCII,
)
MARKER = re.compile(
    r"<!-- aiur-planning-issue[ \t]*\n(?P<payload>[^\n]*)\n-->",
    re.ASCII,
)


def approved_link(repository: str, approved: str) -> str:
    return f"https://github.com/{repository}/commit/{approved}"


def authority_preamble(
    repository: str, logical_id: str, plan_version: int, approved: str,
) -> str:
    marker = _marker(logical_id, plan_version, approved)
    link = approved_link(repository, approved)
    return (
        f"> Approved planning authority: [`{approved}`]({link})\n\n"
        f"<!-- {MARKER_NAME}\n{marker}\n-->\n\n"
    )


def render_ticket_body(
    source: str, repository: str, logical_id: str, plan_version: int,
    approved: str, report: Report, label: str,
) -> str | None:
    """Render an exact preamble followed by the approved source verbatim."""
    body = authority_preamble(repository, logical_id, plan_version, approved) + source
    return body if inspect_issue_body(
        body, repository, logical_id, plan_version, approved, report, label,
    ) is not None else None


def render_template_body(
    template: str, repository: str, logical_id: str, plan_version: int,
    approved: str, report: Report, label: str,
) -> str | None:
    """Render a full approved template by replacing its authority placeholder."""
    if "<APPROVED_SHA>" not in template:
        report.error(f"{label} must contain <APPROVED_SHA>")
        return None
    body = template.replace("<APPROVED_SHA>", approved)
    if "<APPROVED_SHA>" in body:
        report.error(f"{label} contains an unreplaced approval placeholder")
        return None
    return body if inspect_issue_body(
        body, repository, logical_id, plan_version, approved, report, label,
    ) is not None else None


def inspect_issue_body(
    body: object, repository: str, logical_id: str, plan_version: int,
    approved: str, report: Report, label: str,
) -> dict[str, Any] | None:
    """Return exact receipt evidence for one canonical rendered body."""
    if not isinstance(body, str):
        report.error(f"{label} must be UTF-8 text")
        return None
    if len(body) > MAX_ISSUE_BODY_CHARACTERS:
        report.warn(
            f"{logical_id} rendered issue body is {len(body):,} characters, "
            f"exceeding GitHub's {MAX_ISSUE_BODY_CHARACTERS:,}-character "
            f"issue body limit by {len(body) - MAX_ISSUE_BODY_CHARACTERS:,}"
        )
    marker_count = body.count(f"<!-- {MARKER_NAME}")
    matches = list(MARKER.finditer(body))
    if marker_count != 1 or len(matches) != 1:
        report.error(f"{label} must contain exactly one schema-2 {MARKER_NAME} marker")
        return None
    try:
        payload = json.loads(matches[0].group("payload"))
    except json.JSONDecodeError as exc:
        report.error(f"{label} marker must contain valid one-line JSON: {exc}")
        return None
    marker = strict_object(payload, f"{label} marker", MARKER_KEYS, report)
    if marker is None:
        return None
    valid = True
    expected_marker = {
        "schema": 2,
        "logical_id": logical_id,
        "plan_version": plan_version,
        "approved_planning_commit": approved,
    }
    for key, expected in expected_marker.items():
        if marker.get(key) != expected:
            report.error(f"{label} marker {key} must equal {expected}")
            valid = False
    links = COMMIT_LINK.findall(body)
    expected_link = approved_link(repository, approved)
    if len(links) != 1:
        report.error(f"{label} must contain exactly one approved commit link")
        valid = False
    elif links[0] != expected_link:
        report.error(f"{label} approved link must equal {expected_link}")
        valid = False
    if not valid:
        return None
    return {
        "marker_count": 1,
        "marker_schema_version": 2,
        "marker_logical_id": logical_id,
        "marker_plan_version": plan_version,
        "approved_planning_commit": approved,
        "approved_link_count": 1,
        "approved_link": expected_link,
        "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    }


def validate_expected_evidence(
    value: object, label: str, report: Report,
) -> dict[str, Any] | None:
    evidence = strict_object(value, label, EVIDENCE_KEYS, report)
    if evidence is None:
        return None
    body_sha = evidence.get("body_sha256")
    if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
        report.error(f"{label}.body_sha256 must be a lowercase SHA-256")
    return evidence


def _marker(logical_id: str, plan_version: int, approved: str) -> str:
    return json.dumps(
        {
            "schema": 2,
            "logical_id": logical_id,
            "plan_version": plan_version,
            "approved_planning_commit": approved,
        },
        separators=(",", ":"),
    )
