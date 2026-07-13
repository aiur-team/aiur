"""Validate the immutable receipt for the pending root comment."""

from __future__ import annotations

import re
from typing import Any

from publication_body_evidence import BODY_SHA
from publication_common import Report, strict_object


COMMENT_KEYS = {"marker", "state", "url", "body_sha256"}
COMMENT_MARKER = "aiur-build-order-reconciliation"


def validate_pending_comment(
    value: object, root_id: object, mappings: dict[str, dict[str, Any]], report: Report,
) -> None:
    comment = strict_object(
        value, "publication receipt root_reconciliation_comment", COMMENT_KEYS, report
    )
    if comment is None:
        return
    if comment.get("marker") != COMMENT_MARKER:
        report.error(f"root reconciliation comment marker must equal {COMMENT_MARKER}")
    if comment.get("state") != "pending":
        report.error("root reconciliation comment receipt state must equal pending")
    body_sha = comment.get("body_sha256")
    if not isinstance(body_sha, str) or not BODY_SHA.fullmatch(body_sha):
        report.error("root reconciliation comment body_sha256 must be a lowercase SHA-256")
    root = mappings.get(root_id) if isinstance(root_id, str) else None
    if not isinstance(root, dict) or not isinstance(root.get("url"), str):
        return
    expected = re.compile(re.escape(root["url"]) + r"#issuecomment-[1-9][0-9]*$")
    url = comment.get("url")
    if not isinstance(url, str) or not expected.fullmatch(url):
        report.error(
            "publication receipt root reconciliation comment URL must point to the mapped root issue"
        )
