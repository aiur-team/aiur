#!/usr/bin/env python3
"""Render and read-only verify the root reconciliation comment."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

from publication_common import SHA, Report, strict_object
from publication_rendering import (
    BODY_SHA,
    approved_link,
)


COMMENT_MARKER = "aiur-build-order-reconciliation"
MARKER_KEYS = {
    "schema", "logical_id", "plan_version", "approved_planning_commit",
    "state", "receipt_commit", "receipt_url",
}
COMMENT_EVIDENCE_KEYS = {
    "marker_count", "marker", "marker_schema_version", "logical_id",
    "plan_version", "approved_planning_commit", "state", "receipt_commit",
    "receipt_url", "url", "body_sha256",
}
LIVE_COMMENT_KEYS = {"url", "body"}
MARKER = re.compile(
    r"<!-- aiur-build-order-reconciliation[ \t]*\n(?P<payload>[^\n]*)\n-->",
    re.ASCII,
)


def render_pending_comment(
    root_id: str, plan_version: int, approved: str, repository: str,
) -> str:
    return _render_comment(
        root_id, plan_version, approved, repository, "pending", None, None,
    )


def render_successful_comment(
    root_id: str, plan_version: int, approved: str, repository: str,
    receipt_commit: str, receipt_url: str,
) -> str:
    return _render_comment(
        root_id, plan_version, approved, repository, "successful",
        receipt_commit, receipt_url,
    )


def pending_comment_evidence(
    url: str, root_id: str, plan_version: int, approved: str, repository: str,
    report: Report,
) -> dict[str, Any] | None:
    body = render_pending_comment(root_id, plan_version, approved, repository)
    return inspect_comment(
        body, url, root_id, plan_version, approved, "pending", None, None,
        repository, "pending root reconciliation comment", report,
    )


def validate_pending_comment_matches(
    value: object, root_id: object, mappings: dict[str, dict[str, Any]],
    plan_version: object, approved: object, report: Report,
) -> None:
    label = "publication receipt root_reconciliation_comment_matches"
    if not isinstance(value, list):
        report.error(f"{label} must be an array")
        return
    if len(value) != 1:
        report.error(f"{label} must contain exactly one comment match")
    root = mappings.get(root_id) if isinstance(root_id, str) else None
    if (
        not isinstance(root_id, str) or type(plan_version) is not int
        or not isinstance(approved, str) or not SHA.fullmatch(approved)
        or not isinstance(root, dict) or not isinstance(root.get("url"), str)
        or not isinstance(root.get("repository"), str)
    ):
        report.error("pending comment validation requires materialized root authority")
        return
    for index, raw in enumerate(value):
        item_label = f"{label}[{index}]"
        observed = strict_object(raw, item_label, COMMENT_EVIDENCE_KEYS, report)
        if observed is None:
            continue
        body_sha = observed.get("body_sha256")
        if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
            report.error(f"{item_label}.body_sha256 must be a lowercase SHA-256")
        url = observed.get("url")
        if not isinstance(url, str) or not _comment_url(root["url"]).fullmatch(url):
            report.error(
                "publication receipt root reconciliation comment URL must point "
                "to the mapped root issue"
            )
            continue
        expected = pending_comment_evidence(
            url, root_id, plan_version, approved, root["repository"], report
        )
        if expected is None:
            continue
        for key in sorted(COMMENT_EVIDENCE_KEYS):
            if observed.get(key) != expected.get(key):
                report.error(f"{item_label}.{key} must match the canonical pending comment")


def validate_final_comment_matches(
    root_id: str, plan_version: int, approved: str, receipt_commit: str,
    receipt_url: str, root_issue_url: str,
    repository: str, report: Report, repository_anchor: Path | None = None,
    remote_ref_contains: Callable[[str, str, tuple[str, ...]], bool] | None = None,
    live_comment_query: Callable[[str, str], object] | None = None,
) -> None:
    """Verify the receipt-bound live comment without mutating GitHub."""
    label = "final reconciliation comment query"
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("approved planning commit must be a 40-character Git SHA")
    if type(plan_version) is not int or plan_version < 1:
        report.error("plan_version must be a positive integer")
    receipt_is_sha = isinstance(receipt_commit, str) and bool(
        SHA.fullmatch(receipt_commit)
    )
    if not receipt_is_sha:
        report.error("receipt_commit must be a 40-character Git SHA")
        return

    # Function-local import avoids the validator -> auxiliary receipt -> comment
    # import cycle while ensuring only the current trusted validator is loaded.
    from publication_receipt_authority import load_receipt_authority

    authority = load_receipt_authority(
        receipt_commit, repository_anchor or Path(__file__), report,
        remote_ref_contains,
    )
    if authority is None:
        return
    try:
        value = (live_comment_query or _github_live_comment)(
            authority.repository, authority.root_comment_url
        )
    except Exception:
        value = None
    if not isinstance(value, list):
        report.error(f"{label} must be a live GitHub result array")
        return
    if len(value) != 1:
        report.error(f"{label} must contain exactly one comment match")
    authority_values = (
        ("root_id", root_id, authority.root_id),
        ("plan_version", plan_version, authority.plan_version),
        ("approved planning commit", approved, authority.approved_commit),
        ("root_issue_url", root_issue_url, authority.root_issue_url),
        ("repository", repository, authority.repository),
    )
    for field, observed, expected in authority_values:
        if observed != expected:
            report.error(f"{field} must equal receipt authority value {expected}")

    expected_receipt_url = approved_link(authority.repository, receipt_commit)
    if receipt_url != expected_receipt_url:
        report.error(f"receipt_url must equal {expected_receipt_url}")
    expected_body = render_successful_comment(
        authority.root_id, authority.plan_version, authority.approved_commit,
        authority.repository, receipt_commit, expected_receipt_url,
    )
    for index, raw in enumerate(value):
        item = strict_object(raw, f"{label}[{index}]", LIVE_COMMENT_KEYS, report)
        if item is None:
            continue
        url, body = item.get("url"), item.get("body")
        if (
            not isinstance(url, str)
            or url != authority.root_comment_url
        ):
            report.error(
                "final reconciliation comment URL must equal the exact pending "
                "comment URL recorded in the immutable receipt"
            )
        if body != expected_body:
            report.error(
                "final reconciliation comment body must equal the canonical successful receipt"
            )
        inspect_comment(
            body, url, authority.root_id, authority.plan_version,
            authority.approved_commit, "successful", receipt_commit,
            expected_receipt_url, authority.repository,
            f"{label}[{index}]", report,
        )


def inspect_comment(
    body: object, url: object, root_id: str, plan_version: int, approved: str,
    state: str, receipt_commit: str | None, receipt_url: str | None,
    repository: str, label: str, report: Report,
) -> dict[str, Any] | None:
    if not isinstance(body, str):
        report.error(f"{label} body must be text")
        return None
    marker_count = body.count(f"<!-- {COMMENT_MARKER}")
    matches = list(MARKER.finditer(body))
    if marker_count != 1 or len(matches) != 1:
        report.error(f"{label} must contain exactly one {COMMENT_MARKER} marker")
        return None
    try:
        payload = json.loads(matches[0].group("payload"))
    except json.JSONDecodeError as exc:
        report.error(f"{label} marker must contain valid one-line JSON: {exc}")
        return None
    marker = strict_object(payload, f"{label} marker", MARKER_KEYS, report)
    if marker is None:
        return None
    expected = {
        "schema": 1,
        "logical_id": root_id,
        "plan_version": plan_version,
        "approved_planning_commit": approved,
        "state": state,
        "receipt_commit": receipt_commit,
        "receipt_url": receipt_url,
    }
    valid = True
    for key, expected_value in expected.items():
        if marker.get(key) != expected_value:
            report.error(f"{label} marker {key} must equal {expected_value}")
            valid = False
    if not valid:
        return None
    return {
        "marker_count": 1,
        "marker": COMMENT_MARKER,
        "marker_schema_version": 1,
        "logical_id": root_id,
        "plan_version": plan_version,
        "approved_planning_commit": approved,
        "state": state,
        "receipt_commit": receipt_commit,
        "receipt_url": receipt_url,
        "url": url,
        "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    }


def _render_comment(
    root_id: str, plan_version: int, approved: str, repository: str,
    state: str, receipt_commit: str | None, receipt_url: str | None,
) -> str:
    marker = json.dumps(
        {
            "schema": 1,
            "logical_id": root_id,
            "plan_version": plan_version,
            "approved_planning_commit": approved,
            "state": state,
            "receipt_commit": receipt_commit,
            "receipt_url": receipt_url,
        },
        separators=(",", ":"),
    )
    body = (
        f"Publication reconciliation: **{state}**.\n\n"
        f"Approved planning authority: [`{approved}`]"
        f"({approved_link(repository, approved)}).\n"
    )
    if state == "successful":
        body += f"\nImmutable publication receipt: [`{receipt_commit}`]({receipt_url}).\n"
    return f"{body}\n<!-- {COMMENT_MARKER}\n{marker}\n-->\n"


def _comment_url(root_url: str) -> re.Pattern[str]:
    return re.compile(re.escape(root_url) + r"#issuecomment-[1-9][0-9]*$")


def _github_live_comment(repository: str, expected_url: str) -> object | None:
    match = re.fullmatch(
        rf"https://github\.com/{re.escape(repository)}/issues/[1-9][0-9]*"
        r"#issuecomment-([1-9][0-9]*)",
        expected_url,
    )
    if match is None:
        return None
    try:
        result = subprocess.run(
            [
                "gh", "api",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10",
                f"repos/{repository}/issues/comments/{match.group(1)}",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode:
        return None
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if (
        not isinstance(payload, dict)
        or payload.get("html_url") != expected_url
        or not isinstance(payload.get("body"), str)
    ):
        return None
    return [{"url": payload["html_url"], "body": payload["body"]}]


def main(argv: list[str]) -> int:
    if len(argv) != 8:
        print(
            "usage: publication_comment.py ROOT_ID PLAN_VERSION "
            "APPROVED_SHA RECEIPT_SHA RECEIPT_URL ROOT_ISSUE_URL REPOSITORY",
            file=sys.stderr,
        )
        return 64
    try:
        plan_version = int(argv[2])
    except ValueError as exc:
        print(f"ERROR: invalid plan version: {exc}")
        return 1
    report = Report()
    validate_final_comment_matches(
        argv[1], plan_version, argv[3], argv[4], argv[5], argv[6], argv[7],
        report,
    )
    for message in sorted(report.errors):
        print(f"ERROR: {message}")
    print(f"validation: {len(report.errors)} error(s), 0 warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
