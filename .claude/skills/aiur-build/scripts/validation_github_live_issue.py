"""Normalize live GitHub issue records and planning markers."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from validation_common import SHA, Report, nonempty_string, strict_int
from validation_github_rendering import (
    MARKER,
    MARKER_KEYS,
    MARKER_NAME,
    inspect_issue_body,
)


ISSUE_URL = re.compile(
    r"^https://github\.com/([^/\s]+/[^/\s]+)/issues/([1-9][0-9]*)$",
    re.ASCII,
)


def _issue_record(
    raw: dict[str, Any], expected_mapping: dict[str, Any], repository: str,
    logical_id: str, plan_version: int, approved: str, report: Report,
) -> dict[str, Any]:
    mapping = _mapping(
        raw, expected_mapping["repository"], f"live issue {logical_id}", report
    )
    title, body = raw.get("title"), raw.get("body")
    if not isinstance(title, str):
        report.error(f"live GitHub issue {logical_id} title must be text")
    if not isinstance(body, str):
        report.error(f"live GitHub issue {logical_id} body must be text")
        body = ""
    labels = _labels(raw.get("labels"), logical_id, report)
    raw_state = raw.get("state")
    state = "OPEN" if raw_state == "open" else str(raw_state).upper()
    if state != "OPEN":
        report.error(f"live GitHub issue {logical_id} must be OPEN at publication")
    locked = raw.get("locked")
    if locked is not False:
        report.error(f"live GitHub issue {logical_id} must be unlocked at publication")
    body_evidence = inspect_issue_body(
        body, repository, logical_id, plan_version, approved, report,
        f"live GitHub issue {logical_id}",
    )
    return {
        "mapping": mapping,
        "title": title,
        "labels": labels,
        "state": state,
        "locked": locked,
        "body_evidence": body_evidence,
        "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    }


def _mapping(
    raw: dict[str, Any], repository: str | None, label: str, report: Report,
) -> dict[str, Any] | None:
    number, node_id, url = raw.get("number"), raw.get("node_id"), raw.get("html_url")
    match = ISSUE_URL.fullmatch(url) if isinstance(url, str) else None
    observed_repository = match.group(1) if match else None
    observed_number = int(match.group(2)) if match else None
    if repository is None:
        repository = observed_repository
    if (
        not isinstance(repository, str)
        or observed_repository != repository
        or not strict_int(number)
        or number < 1
        or observed_number != number
        or not nonempty_string(node_id)
    ):
        report.error(f"{label} returned an invalid GitHub issue mapping")
        return None
    return {
        "repository": repository,
        "number": number,
        "node_id": node_id,
        "url": url,
    }


def _markers(body: object, label: str, report: Report) -> list[dict[str, Any]]:
    if body is None:
        return []
    if not isinstance(body, str):
        report.error(f"{label} body must be text")
        return []
    openings = body.count(f"<!-- {MARKER_NAME}")
    matches = list(MARKER.finditer(body))
    if openings != len(matches) or openings > 1:
        report.error(f"{label} contains malformed or duplicate planning markers")
        return []
    result: list[dict[str, Any]] = []
    for match in matches:
        try:
            value = json.loads(match.group("payload"))
        except json.JSONDecodeError:
            report.error(f"{label} planning marker must contain valid JSON")
            continue
        if not isinstance(value, dict) or set(value) != MARKER_KEYS:
            report.error(f"{label} planning marker has an invalid schema")
            continue
        if (
            value.get("schema") != 2
            or not nonempty_string(value.get("logical_id"))
            or not strict_int(value.get("plan_version"))
            or value["plan_version"] < 1
            or not isinstance(value.get("approved_planning_commit"), str)
            or not SHA.fullmatch(value["approved_planning_commit"])
        ):
            report.error(f"{label} planning marker has invalid typed values")
            continue
        result.append(value)
    return result


def _labels(value: object, logical_id: str, report: Report) -> list[str]:
    if not isinstance(value, list):
        report.error(f"live GitHub issue {logical_id} labels must be an array")
        return []
    labels: list[str] = []
    for item in value:
        label = item.get("name") if isinstance(item, dict) else item
        if not nonempty_string(label):
            report.error(f"live GitHub issue {logical_id} has an invalid label")
            continue
        labels.append(label)
    if len(labels) != len(set(labels)):
        report.error(f"live GitHub issue {logical_id} has duplicate labels")
    return sorted(labels)

