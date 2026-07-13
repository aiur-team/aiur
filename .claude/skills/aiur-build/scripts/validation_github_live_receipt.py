"""Compare a stable live GitHub snapshot with its immutable receipt."""

from __future__ import annotations

import json
from typing import Any

from validation_common import Report
from validation_github_live_models import (
    LiveSnapshot,
    _expected_mappings,
    _mapping_key,
)


def _compare_receipt(
    data: dict[str, Any], snapshot: LiveSnapshot, report: Report,
) -> None:
    receipt = data.get("github_reconciliation")
    if not isinstance(receipt, dict):
        return
    live_issues = {key: json.loads(value) for key, value in snapshot.issues}
    titles = receipt.get("observed_issue_titles")
    states = receipt.get("observed_issue_states")
    labels = receipt.get("observed_labels")
    evidence = receipt.get("observed_body_evidence")
    matches = receipt.get("marker_query_matches")
    mappings = _expected_mappings(data, report)
    for logical_id, live in live_issues.items():
        expected_mapping = mappings.get(logical_id)
        if live.get("mapping") != expected_mapping:
            report.error(f"live GitHub mapping drifted for {logical_id}")
        if not isinstance(titles, dict) or live.get("title") != titles.get(logical_id):
            report.error(f"live GitHub title drifted for {logical_id}")
        if not isinstance(states, dict) or live.get("state") != states.get(logical_id):
            report.error(f"live GitHub state drifted for {logical_id}")
        if live.get("state") != "OPEN":
            report.error(f"live GitHub issue {logical_id} must be OPEN at publication")
        expected_labels = labels.get(logical_id) if isinstance(labels, dict) else None
        if not isinstance(expected_labels, list) or live.get("labels") != sorted(expected_labels):
            report.error(f"live GitHub labels drifted for {logical_id}")
        expected_evidence = evidence.get(logical_id) if isinstance(evidence, dict) else None
        if live.get("body_evidence") != expected_evidence:
            report.error(f"live GitHub body drifted for {logical_id}")

    live_matches = dict(snapshot.marker_matches)
    for logical_id, mapping in mappings.items():
        receipt_values = matches.get(logical_id) if isinstance(matches, dict) else None
        receipt_keys = (
            tuple(sorted(_mapping_key(item) for item in receipt_values))
            if isinstance(receipt_values, list)
            and all(isinstance(item, dict) for item in receipt_values)
            else ()
        )
        if live_matches.get(logical_id) != receipt_keys or receipt_keys != (
            _mapping_key(mapping),
        ):
            report.error(f"live GitHub marker receipt drifted for {logical_id}")

    root_id = data.get("build_order_id")
    expected_members = set(receipt.get("member_ticket_ids", []))
    if set(snapshot.root_members) != expected_members:
        report.error("live GitHub root membership drifted from the receipt")
    expected_edges = {
        (item.get("ticket_id"), item.get("depends_on"))
        for item in receipt.get("dependency_edges", [])
        if isinstance(item, dict)
    }
    if set(snapshot.dependency_edges) != expected_edges:
        report.error("live GitHub dependency edges drifted from the receipt")
    if isinstance(root_id, str) and any(
        blocked == root_id for blocked, _ in snapshot.dependency_edges
    ):
        report.error("live GitHub root must not have native blockers")

