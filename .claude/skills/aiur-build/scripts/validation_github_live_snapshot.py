"""Collect one bounded canonical GitHub publication snapshot."""

from __future__ import annotations

from typing import Any

from validation_common import Report
from validation_github_live_issue import _issue_record, _mapping, _markers
from validation_github_live_models import (
    LiveSnapshot,
    _canonical,
    _expected_mappings,
    _mapping_key,
)
from validation_github_live_relationships import _parent, _relationships
from validation_github_reader import GitHubReader, LiveGitHubError


def _snapshot(
    data: dict[str, Any], reader: GitHubReader, report: Report,
) -> LiveSnapshot | None:
    expected = _expected_mappings(data, report)
    receipt = data.get("github_reconciliation")
    if not expected or not isinstance(receipt, dict):
        report.error("live GitHub validation requires a complete materialized receipt")
        return None
    root_id = data.get("build_order_id")
    repository = data.get("repository")
    plan_version = data.get("plan_version")
    approved = receipt.get("approved_planning_commit")
    if (
        not isinstance(root_id, str)
        or not isinstance(repository, str)
        or type(plan_version) is not int
        or not isinstance(approved, str)
    ):
        report.error("live GitHub validation requires canonical publication identity")
        return None

    raw_by_identity: dict[tuple[str, int], dict[str, Any]] = {}
    marker_matches: dict[str, list[dict[str, Any]]] = {
        logical_id: [] for logical_id in expected
    }
    for mapped_repository in sorted({item["repository"] for item in expected.values()}):
        try:
            raw_issues = reader.repository_issues(mapped_repository)
        except LiveGitHubError as exc:
            report.error(str(exc))
            return None
        seen_numbers: set[int] = set()
        for raw in raw_issues:
            marker_values = _markers(
                raw.get("body"),
                f"{mapped_repository} issue-or-pull #{raw.get('number')}",
                report,
            )
            if "pull_request" in raw:
                claimed = sorted(
                    marker.get("logical_id") for marker in marker_values
                    if marker.get("logical_id") in marker_matches
                )
                if claimed:
                    report.error(
                        "planning marker for " + ", ".join(claimed)
                        + " appears on a pull request"
                    )
                continue
            mapping = _mapping(raw, mapped_repository, "repository issue", report)
            if mapping is None:
                continue
            number = mapping["number"]
            if number in seen_numbers:
                report.error(
                    f"live GitHub issue scan duplicates {mapped_repository}#{number}"
                )
                continue
            seen_numbers.add(number)
            identity = (mapped_repository, number)
            raw_by_identity[identity] = raw
            for marker in marker_values:
                logical_id = marker.get("logical_id")
                if logical_id in marker_matches:
                    marker_matches[logical_id].append(mapping)

    issue_records: dict[str, dict[str, Any]] = {}
    reverse: dict[str, str] = {}
    for logical_id, mapping in expected.items():
        identity = (mapping["repository"], mapping["number"])
        reverse[_mapping_key(mapping)] = logical_id
        raw = raw_by_identity.get(identity)
        if raw is None:
            report.error(
                f"live GitHub issue is missing for {logical_id}: "
                f"{identity[0]}#{identity[1]}"
            )
            continue
        issue_records[logical_id] = _issue_record(
            raw, mapping, repository, logical_id, plan_version, approved, report,
        )

    normalized_matches: dict[str, tuple[str, ...]] = {}
    for logical_id, values in marker_matches.items():
        rendered = tuple(sorted(_mapping_key(value) for value in values))
        normalized_matches[logical_id] = rendered
        expected_key = _mapping_key(expected[logical_id])
        if rendered != (expected_key,):
            report.error(
                f"live GitHub marker query for {logical_id} must return exactly "
                "its mapped issue"
            )

    root = expected.get(root_id)
    if root is None:
        report.error("live GitHub validation requires the mapped root")
        return None
    members = _relationships(
        reader, "subissues", root, reverse, report,
    )
    expected_members = set(expected) - {root_id}
    if members != expected_members:
        report.error("live GitHub root membership must exactly match receipt members")

    parents: dict[str, str | None] = {}
    for logical_id, mapping in sorted(expected.items()):
        parent = _parent(reader, mapping, reverse, report)
        expected_parent = None if logical_id == root_id else root_id
        if parent != expected_parent:
            report.error(
                f"live GitHub parent for {logical_id} must equal "
                f"{expected_parent or 'none'}"
            )
        parents[logical_id] = parent
        if logical_id != root_id:
            nested = _relationships(reader, "subissues", mapping, reverse, report)
            if nested:
                report.error(f"live GitHub member {logical_id} must not have subissues")

    edges: set[tuple[str, str]] = set()
    for blocked_id, mapping in sorted(expected.items()):
        blockers = _relationships(reader, "blockers", mapping, reverse, report)
        edges.update((blocked_id, blocker_id) for blocker_id in blockers)

    if report.errors:
        return None
    return LiveSnapshot(
        issues=tuple(
            (logical_id, _canonical(record))
            for logical_id, record in sorted(issue_records.items())
        ),
        marker_matches=tuple(
            (logical_id, values)
            for logical_id, values in sorted(normalized_matches.items())
        ),
        root_members=tuple(sorted(members)),
        parents=tuple(sorted(parents.items())),
        dependency_edges=tuple(sorted(edges)),
    )
