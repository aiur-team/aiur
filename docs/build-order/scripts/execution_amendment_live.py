"""Stable live-GitHub verification for an execution amendment.

Unlike publication finalization, execution validation permits normal lifecycle
movement.  It still requires the immutable graph, mappings, issue bodies, and
authorized amendment comments to survive two identical bounded reads.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Protocol

from execution_amendment import (
    AMENDMENT_MARKER,
    COMMENT_URL,
    lane_for_ticket,
    parse_execution_comment,
    render_authorization_comment,
    render_ticket_amendment_comment,
)
from publication_common import Report
from publication_labels import routing_subset
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


@dataclass(frozen=True)
class ExecutionSnapshot:
    issues: tuple[tuple[str, str], ...]
    auxiliary_issues: tuple[tuple[str, str], ...]
    marker_matches: tuple[tuple[str, tuple[tuple[tuple[str, Any], ...], ...]], ...]
    root_members: tuple[str, ...]
    parents: tuple[tuple[str, str | None], ...]
    nested_subissues: tuple[tuple[str, tuple[str, ...]], ...]
    internal_edges: tuple[tuple[str, str], ...]
    external_edges: tuple[tuple[str, str], ...]
    comments: tuple[tuple[str, str], ...]


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


def compare_execution_snapshot(
    snapshot: ExecutionSnapshot,
    authority: ReceiptAuthority,
    amendment: dict[str, Any],
    report: Report,
) -> bool:
    build = authority.receipt_manifests.get("build-order.json")
    publication = authority.receipt_manifests.get("publication.json")
    if not isinstance(build, dict) or not isinstance(publication, dict):
        report.error("execution snapshot requires immutable publication manifests")
        return False
    tickets = _tickets(build)
    root_id = authority.root_id
    expected_ids = {root_id, *tickets}
    issues = {logical_id: json.loads(value) for logical_id, value in snapshot.issues}
    if set(issues) != expected_ids:
        report.error("live execution issues must exactly cover root plus 54 members")
        return False

    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    publication_receipt = publication.get("github_reconciliation")
    auxiliary_mappings = (
        publication_receipt.get("issue_mappings")
        if isinstance(publication_receipt, dict) else None
    )
    wanted_skill_mapping = (
        auxiliary_mappings.get(skill_id)
        if isinstance(auxiliary_mappings, dict) and isinstance(skill_id, str) else None
    )
    auxiliary = {
        logical_id: json.loads(value)
        for logical_id, value in snapshot.auxiliary_issues
    }
    if not isinstance(skill_id, str) or set(auxiliary) != {skill_id}:
        report.error("live execution auxiliary snapshot must cover the skill blocker")
    else:
        skill_live = auxiliary[skill_id]
        if skill_live.get("mapping") != wanted_skill_mapping:
            report.error("live execution skill blocker mapping drifted")
        expected_skill_titles = (
            publication_receipt.get("observed_issue_titles")
            if isinstance(publication_receipt, dict) else None
        )
        expected_skill_bodies = (
            publication_receipt.get("observed_body_evidence")
            if isinstance(publication_receipt, dict) else None
        )
        expected_skill_labels = (
            publication_receipt.get("observed_labels")
            if isinstance(publication_receipt, dict) else None
        )
        expected_skill_title = (
            expected_skill_titles.get(skill_id)
            if isinstance(expected_skill_titles, dict) else None
        )
        expected_skill_body = (
            expected_skill_bodies.get(skill_id)
            if isinstance(expected_skill_bodies, dict) else None
        )
        expected_skill_body_sha = (
            expected_skill_body.get("body_sha256")
            if isinstance(expected_skill_body, dict) else None
        )
        expected_skill_routing = (
            expected_skill_labels.get(skill_id)
            if isinstance(expected_skill_labels, dict) else None
        )
        if skill_live.get("title") != expected_skill_title:
            report.error("live execution skill blocker title drifted")
        if skill_live.get("body_sha256") != expected_skill_body_sha:
            report.error("live execution skill blocker body drifted")
        if _static_routing(skill_live.get("labels")) != _static_routing(
            expected_skill_routing
        ):
            report.error("live execution skill blocker routing labels drifted")
        if not _valid_execution_state(
            skill_live.get("state"), skill_live.get("state_reason")
        ):
            report.error("live execution skill blocker has an invalid lifecycle state")
        if skill_live.get("locked") is not False:
            report.error("live execution skill blocker must remain unlocked")

    receipt = build.get("github_reconciliation")
    if not isinstance(receipt, dict):
        report.error("execution snapshot requires the immutable core receipt")
        return False
    expected_titles = receipt.get("observed_issue_titles")
    expected_bodies = receipt.get("observed_body_evidence")
    expected_labels = receipt.get("observed_labels")
    mappings = {root_id: build.get("github_root")}
    mappings.update({logical_id: ticket.get("github") for logical_id, ticket in tickets.items()})

    affected = set(amendment.get("affected_ticket_ids", []))
    completed_before = set(amendment.get("completed_before_amendment_ticket_ids", []))
    terminal_members: set[str] = set()
    for logical_id, live in sorted(issues.items()):
        if live.get("mapping") != mappings.get(logical_id):
            report.error(f"live execution mapping drifted for {logical_id}")
        title = expected_titles.get(logical_id) if isinstance(expected_titles, dict) else None
        if live.get("title") != title:
            report.error(f"live execution title drifted for {logical_id}")
        evidence = expected_bodies.get(logical_id) if isinstance(expected_bodies, dict) else None
        expected_body_sha = evidence.get("body_sha256") if isinstance(evidence, dict) else None
        if live.get("body_sha256") != expected_body_sha:
            report.error(f"live execution issue body drifted for {logical_id}")
        wanted_labels = expected_labels.get(logical_id) if isinstance(expected_labels, dict) else None
        wanted_static = _static_routing(wanted_labels)
        observed_static = _static_routing(live.get("labels"))
        if observed_static != wanted_static:
            report.error(f"live execution static routing labels drifted for {logical_id}")
        if live.get("locked") is not False:
            report.error(f"live execution issue {logical_id} must remain unlocked")
        state, reason = live.get("state"), live.get("state_reason")
        if logical_id == root_id:
            if not _valid_execution_state(state, reason):
                report.error("live execution root has an invalid terminal state")
            continue
        if logical_id in completed_before:
            if state != "CLOSED" or reason != "completed":
                report.error(
                    f"pre-amendment completed ticket {logical_id} must remain completed"
                )
        elif logical_id in affected:
            if not _valid_execution_state(state, reason):
                report.error(f"affected ticket {logical_id} has an invalid execution state")
        else:
            report.error(f"live execution ticket {logical_id} lacks an amendment partition")
        if state == "CLOSED" and reason == "completed":
            terminal_members.add(logical_id)

    root = issues[root_id]
    if root.get("state") == "CLOSED" and terminal_members != set(tickets):
        report.error("Build Order root may close only after all 54 members complete")
    live_open = {
        logical_id for logical_id, value in issues.items()
        if logical_id != root_id and value.get("state") == "OPEN"
    }
    if not live_open <= affected:
        report.error("every live-open ticket must be in affected_ticket_ids")

    if set(snapshot.root_members) != set(tickets) or len(snapshot.root_members) != 54:
        report.error("live execution root membership must remain exactly 54 tickets")
    parents = dict(snapshot.parents)
    if parents.get(root_id) is not None:
        report.error("live execution root must not have a parent")
    for logical_id in tickets:
        if parents.get(logical_id) != root_id:
            report.error(f"live execution parent drifted for {logical_id}")
    for logical_id, nested in snapshot.nested_subissues:
        if nested:
            report.error(f"live execution member {logical_id} must not have subissues")

    expected_internal = {
        (logical_id, dependency)
        for logical_id, ticket in tickets.items()
        for dependency in ticket.get("depends_on", [])
    }
    if set(snapshot.internal_edges) != expected_internal or len(snapshot.internal_edges) != 105:
        report.error("live execution internal dependency graph must remain exactly 105 edges")
    expected_external = {
        (item.get("blocked_ticket_id"), item.get("blocker_issue_id"))
        for item in publication.get("external_blocker_relations", [])
        if isinstance(item, dict)
    }
    if set(snapshot.external_edges) != expected_external:
        report.error("live execution external blocker relations drifted")

    expected_matches = {
        logical_id: (_mapping_tuple(mapping),)
        for logical_id, mapping in mappings.items() if isinstance(mapping, dict)
    }
    if dict(snapshot.marker_matches) != expected_matches:
        report.error("live execution planning-marker mappings drifted")
    _compare_comments(snapshot, amendment, report)
    return not report.errors


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


def _compare_comments(
    snapshot: ExecutionSnapshot, amendment: dict[str, Any], report: Report,
) -> None:
    expected: dict[str, Any] = {
        amendment.get("build_order_id"): amendment.get("authorization_comment")
    }
    ticket_comments = amendment.get("ticket_amendment_comments")
    if isinstance(ticket_comments, dict):
        expected.update(ticket_comments)
    observed = {logical_id: json.loads(value) for logical_id, value in snapshot.comments}
    if set(observed) != set(expected):
        report.error("live execution comments must exactly cover amendment evidence")
        return
    for logical_id, evidence in sorted(expected.items()):
        record = observed[logical_id]
        exact = record.get("exact")
        marked = record.get("marked")
        rendered = (
            render_authorization_comment(amendment)
            if logical_id == amendment.get("build_order_id")
            else render_ticket_amendment_comment(amendment, logical_id)
        )
        if not isinstance(exact, dict) or not isinstance(evidence, dict):
            report.error(f"live execution comment evidence is invalid for {logical_id}")
            continue
        wanted = {
            "url": evidence.get("url"),
            "body": rendered,
            "body_sha256": evidence.get("body_sha256"),
            "author_login": evidence.get("author_login"),
        }
        for field, value in wanted.items():
            if exact.get(field) != value:
                report.error(f"live execution comment {logical_id}.{field} drifted")
        if not isinstance(marked, list) or len(marked) != 1 or marked[0] != exact:
            report.error(
                f"live execution issue {logical_id} must contain exactly one amendment marker"
            )
        marker_report = Report()
        marker = parse_execution_comment(rendered, f"expected comment {logical_id}", marker_report)
        _merge(marker_report, report)
        if marker is None:
            continue
        if marker.get("logical_id") != logical_id:
            report.error(f"live execution comment marker logical_id drifted for {logical_id}")
        if marker.get("decision_sha256") != amendment.get("decision_sha256"):
            report.error(f"live execution comment decision hash drifted for {logical_id}")
        if marker.get("lane_id") != lane_for_ticket(amendment, logical_id):
            report.error(f"live execution comment lane drifted for {logical_id}")


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


def _valid_execution_state(state: object, reason: object) -> bool:
    return (
        (state == "OPEN" and reason in (None, "reopened"))
        or (state == "CLOSED" and reason == "completed")
    )


def _static_routing(value: object) -> set[str]:
    if not isinstance(value, (list, tuple)):
        return set()
    return {
        label for label in routing_subset({item for item in value if isinstance(item, str)})
        if not label.casefold().startswith("agent:")
    }


def _tickets(build: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = build.get("tickets")
    if not isinstance(values, list):
        raise LiveGraphError("immutable receipt tickets are unavailable")
    result = {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if len(result) != len(values):
        raise LiveGraphError("immutable receipt ticket identities are ambiguous")
    return result


def _canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.warnings.extend(source.warnings)
