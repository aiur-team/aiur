"""Stable live-GitHub verification for an execution amendment.

Unlike publication finalization, execution validation permits normal lifecycle
movement.  It still requires the immutable graph, mappings, issue bodies, and
authorized amendment comments to survive two identical bounded reads.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Protocol

from execution_amendment import AMENDMENT_MARKER, COMMENT_URL, parse_execution_comment
import skill_publication_path  # noqa: F401
from publication_common import Report
from publication_live_graph import (
    LiveGraphError,
    QueryBudget,
    _github_json,
    _github_pages,
    _marker_payloads,
    _mapping_tuple,
    _raw_labels,
    _raw_mapping,
    _raw_scan_mapping,
    _relationship_ref,
)
from publication_receipt_authority import ReceiptAuthority
from execution_amendment_compare import (
    compare_execution_snapshot,
    ExecutionSnapshot,
    _merge,
    _tickets,
)
from execution_amendment_compare import (  # noqa: F401
    _compare_comments,
    _static_routing,
    _valid_execution_state,
)


class ExecutionReader(Protocol):
    def repository_issues(self, repository: str) -> list[dict[str, Any]]: ...
    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]: ...
    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]: ...
    def parent(self, repository: str, number: int) -> dict[str, Any] | None: ...
    def issue_comments(self, repository: str, number: int) -> list[dict[str, Any]]: ...
    def issue_comment(self, repository: str, comment_id: int) -> dict[str, Any]: ...


class GhExecutionReader:
    """Use the publication verifier's API pinning and one shared finite budget."""

    def __init__(self, budget: QueryBudget | None = None) -> None:
        self.budget = budget or QueryBudget()

    def repository_issues(self, repository: str) -> list[dict[str, Any]]:
        return self._objects(
            _github_pages(
                f"repos/{repository}/issues?state=all&per_page=100",
                budget=self.budget,
            ),
            "repository issues",
        )

    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._objects(
            _github_pages(
                f"repos/{repository}/issues/{number}/sub_issues?per_page=100",
                budget=self.budget,
            ),
            "subissues",
        )

    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._objects(
            _github_pages(
                f"repos/{repository}/issues/{number}/dependencies/blocked_by?per_page=100",
                budget=self.budget,
            ),
            "blockers",
        )

    def parent(self, repository: str, number: int) -> dict[str, Any] | None:
        value = _github_json(
            f"repos/{repository}/issues/{number}/parent",
            allow_404=True,
            budget=self.budget,
        )
        if value is not None and not isinstance(value, dict):
            raise LiveGraphError("GitHub parent query returned a non-object")
        return value

    def issue_comments(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._objects(
            _github_pages(
                f"repos/{repository}/issues/{number}/comments?per_page=100",
                budget=self.budget,
            ),
            "issue comments",
        )

    def issue_comment(self, repository: str, comment_id: int) -> dict[str, Any]:
        value = _github_json(
            f"repos/{repository}/issues/comments/{comment_id}", budget=self.budget,
        )
        if not isinstance(value, dict):
            raise LiveGraphError("GitHub exact comment query returned a non-object")
        return value

    @staticmethod
    def _objects(values: list[Any], label: str) -> list[dict[str, Any]]:
        if any(not isinstance(item, dict) for item in values):
            raise LiveGraphError(f"GitHub {label} query returned a non-object entry")
        return values


def verify_live_execution_amendment(
    authority: ReceiptAuthority,
    amendment: dict[str, Any],
    report: Report,
    reader: ExecutionReader | None = None,
) -> bool:
    """Require two identical complete reads, then apply monotonic state policy."""
    reader = reader or GhExecutionReader(QueryBudget())
    first_report = Report()
    first = capture_execution_snapshot(authority, amendment, reader, first_report)
    _merge(first_report, report)
    if first is None or first_report.errors:
        return False
    second_report = Report()
    second = capture_execution_snapshot(authority, amendment, reader, second_report)
    _merge(second_report, report)
    if second is None or second_report.errors:
        return False
    if first != second:
        report.error("live execution graph changed during the two bounded reads")
        return False
    return compare_execution_snapshot(first, authority, amendment, report)


def capture_execution_snapshot(
    authority: ReceiptAuthority,
    amendment: dict[str, Any],
    reader: ExecutionReader,
    report: Report,
) -> ExecutionSnapshot | None:
    """Collect one complete normalized snapshot without imposing all-OPEN."""
    try:
        return _capture(authority, amendment, reader, report)
    except LiveGraphError as exc:
        report.error(f"live execution graph query failed: {exc}")
        return None


def _capture(
    authority: ReceiptAuthority,
    amendment: dict[str, Any],
    reader: ExecutionReader,
    report: Report,
) -> ExecutionSnapshot | None:
    build = authority.receipt_manifests.get("build-order.json")
    publication = authority.receipt_manifests.get("publication.json")
    if not isinstance(build, dict) or not isinstance(publication, dict):
        raise LiveGraphError("immutable receipt manifests are unavailable")
    tickets = _tickets(build)
    root_id = authority.root_id
    core_mappings: dict[str, dict[str, Any]] = {}
    root_mapping = build.get("github_root")
    if not isinstance(root_mapping, dict):
        raise LiveGraphError("immutable root mapping is unavailable")
    core_mappings[root_id] = root_mapping
    for logical_id, ticket in tickets.items():
        mapping = ticket.get("github")
        if not isinstance(mapping, dict):
            raise LiveGraphError(f"immutable mapping is unavailable for {logical_id}")
        core_mappings[logical_id] = mapping

    publication_receipt = publication.get("github_reconciliation")
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    auxiliary_mappings = (
        publication_receipt.get("issue_mappings")
        if isinstance(publication_receipt, dict) else None
    )
    skill_mapping = (
        auxiliary_mappings.get(skill_id)
        if isinstance(auxiliary_mappings, dict) and isinstance(skill_id, str) else None
    )
    if not isinstance(skill_id, str) or not isinstance(skill_mapping, dict):
        raise LiveGraphError("immutable skill blocker mapping is unavailable")
    all_mappings = {**core_mappings, skill_id: skill_mapping}
    mapped_numbers = {
        mapping["number"]: logical_id for logical_id, mapping in all_mappings.items()
    }

    raw_issues = reader.repository_issues(authority.repository)
    by_number: dict[int, dict[str, Any]] = {}
    marker_matches: dict[str, list[tuple[tuple[str, Any], ...]]] = {
        logical_id: [] for logical_id in core_mappings
    }
    seen_numbers: set[int] = set()
    seen_nodes: set[str] = set()
    for raw in raw_issues:
        number, node = raw.get("number"), raw.get("node_id")
        if type(number) is not int or number < 1 or not isinstance(node, str) or not node:
            raise LiveGraphError("all-state execution issue scan returned invalid identity")
        if number in seen_numbers or node in seen_nodes:
            raise LiveGraphError("all-state execution issue scan returned duplicate identity")
        seen_numbers.add(number)
        seen_nodes.add(node)
        is_pull = "pull_request" in raw
        scan_mapping = _raw_scan_mapping(raw, authority.repository, is_pull)
        for payload in _marker_payloads(raw.get("body"), number):
            logical_id = payload.get("logical_id")
            if logical_id in marker_matches:
                marker_matches[logical_id].append(_mapping_tuple(scan_mapping))
        if number in mapped_numbers and is_pull:
            raise LiveGraphError(f"mapped execution issue {mapped_numbers[number]} is a PR")
        if not is_pull:
            by_number[number] = raw

    issues: dict[str, str] = {}
    for logical_id, mapping in sorted(core_mappings.items()):
        raw = by_number.get(mapping["number"])
        if raw is None:
            raise LiveGraphError(f"mapped execution issue is missing for {logical_id}")
        issues[logical_id] = _canonical(_issue_record(raw, mapping, authority.repository))
    skill_raw = by_number.get(skill_mapping["number"])
    if skill_raw is None:
        raise LiveGraphError("mapped skill blocker issue is missing")
    auxiliary = {
        skill_id: _canonical(_issue_record(skill_raw, skill_mapping, authority.repository))
    }

    root_members = tuple(sorted(
        _relationship_ref(raw, authority.repository, mapped_numbers)
        for raw in reader.subissues(authority.repository, root_mapping["number"])
    ))
    parents: dict[str, str | None] = {}
    nested: dict[str, tuple[str, ...]] = {}
    for logical_id, mapping in sorted(core_mappings.items()):
        parent_raw = reader.parent(authority.repository, mapping["number"])
        parents[logical_id] = (
            None if parent_raw is None
            else _relationship_ref(parent_raw, authority.repository, mapped_numbers)
        )
        if logical_id != root_id:
            nested[logical_id] = tuple(sorted(
                _relationship_ref(raw, authority.repository, mapped_numbers)
                for raw in reader.subissues(authority.repository, mapping["number"])
            ))

    internal: set[tuple[str, str]] = set()
    external: set[tuple[str, str]] = set()
    for blocked_id, mapping in sorted(core_mappings.items()):
        for raw in reader.blockers(authority.repository, mapping["number"]):
            blocker = _relationship_ref(raw, authority.repository, mapped_numbers)
            edge = (blocked_id, blocker)
            if blocked_id in tickets and blocker in tickets:
                internal.add(edge)
            else:
                external.add(edge)

    comment_records = _capture_comments(
        authority, amendment, core_mappings, reader, report,
    )
    if report.errors:
        return None
    return ExecutionSnapshot(
        issues=tuple(sorted(issues.items())),
        auxiliary_issues=tuple(sorted(auxiliary.items())),
        marker_matches=tuple(
            (logical_id, tuple(sorted(values)))
            for logical_id, values in sorted(marker_matches.items())
        ),
        root_members=root_members,
        parents=tuple(sorted(parents.items())),
        nested_subissues=tuple(sorted(nested.items())),
        internal_edges=tuple(sorted(internal)),
        external_edges=tuple(sorted(external)),
        comments=tuple(sorted(comment_records.items())),
    )


def _capture_comments(
    authority: ReceiptAuthority,
    amendment: dict[str, Any],
    mappings: dict[str, dict[str, Any]],
    reader: ExecutionReader,
    report: Report,
) -> dict[str, str]:
    evidence: dict[str, Any] = {authority.root_id: amendment.get("authorization_comment")}
    ticket_comments = amendment.get("ticket_amendment_comments")
    if isinstance(ticket_comments, dict):
        evidence.update(ticket_comments)
    result: dict[str, str] = {}
    for logical_id, expected in sorted(evidence.items()):
        mapping = mappings.get(logical_id)
        url = expected.get("url") if isinstance(expected, dict) else None
        match = COMMENT_URL.fullmatch(url) if isinstance(url, str) else None
        if (
            mapping is None or match is None
            or match.group("repository") != authority.repository
            or int(match.group("number")) != mapping.get("number")
        ):
            report.error(f"execution comment URL is invalid for {logical_id}")
            continue
        comment_id = int(match.group("comment"))
        exact = _comment_record(
            reader.issue_comment(authority.repository, comment_id),
            logical_id, report,
        )
        all_comments = reader.issue_comments(authority.repository, mapping["number"])
        marked: list[dict[str, Any]] = []
        for raw in all_comments:
            body = raw.get("body")
            if isinstance(body, str) and f"<!-- {AMENDMENT_MARKER}" in body:
                record = _comment_record(raw, logical_id, report)
                parse_execution_comment(
                    body, f"live execution comment {raw.get('html_url')}", report,
                )
                marked.append(record)
        result[logical_id] = _canonical({"exact": exact, "marked": marked})
    return result


def _comment_record(
    raw: dict[str, Any], logical_id: str, report: Report,
) -> dict[str, Any]:
    url, body = raw.get("html_url"), raw.get("body")
    user = raw.get("user")
    author = user.get("login") if isinstance(user, dict) else None
    updated_at = raw.get("updated_at")
    association = raw.get("author_association")
    if not all(isinstance(item, str) and item for item in (url, body, author, updated_at)):
        report.error(f"live execution comment for {logical_id} is malformed")
    if association is not None and not isinstance(association, str):
        report.error(f"live execution comment association for {logical_id} is malformed")
    return {
        "url": url,
        "body": body,
        "body_sha256": (
            hashlib.sha256(body.encode("utf-8")).hexdigest()
            if isinstance(body, str) else None
        ),
        "author_login": author,
        "author_association": association,
        "updated_at": updated_at,
    }


def _issue_record(
    raw: dict[str, Any], expected_mapping: dict[str, Any], repository: str,
) -> dict[str, Any]:
    mapping = _raw_mapping(raw, repository)
    if mapping != expected_mapping:
        # Keep the observed record for a precise later mapping diagnostic.
        mapping = mapping
    title, body = raw.get("title"), raw.get("body")
    state = raw.get("state")
    locked, updated_at = raw.get("locked"), raw.get("updated_at")
    if not isinstance(title, str) or not isinstance(body, str):
        raise LiveGraphError("mapped execution issue returned non-text content")
    if not isinstance(state, str) or type(locked) is not bool:
        raise LiveGraphError("mapped execution issue returned invalid lifecycle data")
    if not isinstance(updated_at, str) or not updated_at:
        raise LiveGraphError("mapped execution issue lacks updated_at")
    return {
        "mapping": mapping,
        "title": title,
        "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
        "labels": _raw_labels(raw),
        "state": state.upper(),
        "state_reason": raw.get("state_reason"),
        "locked": locked,
        "updated_at": updated_at,
    }


def _canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


