"""Expected Build Order graph from receipts, and its comparison with a live snapshot."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any

from publication_common import GITHUB_KEYS, Report
from publication_receipt_authority import ReceiptAuthority


ISSUE_URL = re.compile(
    r"^https://github\.com/(?P<repository>[^/\s]+/[^/\s]+)/issues/"
    r"(?P<number>[1-9][0-9]*)$",
    re.ASCII,
)


ISSUE_OR_PULL_URL = re.compile(
    r"^https://github\.com/(?P<repository>[^/\s]+/[^/\s]+)/"
    r"(?P<kind>issues|pull)/(?P<number>[1-9][0-9]*)$",
    re.ASCII,
)


COMMENT_URL = re.compile(
    r"^https://github\.com/(?P<repository>[^/\s]+/[^/\s]+)/issues/"
    r"(?P<number>[1-9][0-9]*)#issuecomment-(?P<comment>[1-9][0-9]*)$",
    re.ASCII,
)


class LiveGraphError(RuntimeError):
    """A bounded GitHub read returned incomplete, ambiguous, or invalid data."""


@dataclass(frozen=True)
class ExpectedIssue:
    mapping: dict[str, Any]
    title: str
    body_sha256: str
    labels: tuple[str, ...]
    state: str
    parent: str | None
    subissues: tuple[str, ...]
    blocked_by: tuple[str, ...]


@dataclass(frozen=True)
class ExpectedGraph:
    issues: dict[str, ExpectedIssue]
    marker_matches: dict[str, tuple[tuple[str, Any], ...]]
    comment_url: str


def _expected_graph(authority: ReceiptAuthority) -> ExpectedGraph:
    manifests = authority.receipt_manifests
    build = manifests.get("build-order.json")
    publication = manifests.get("publication.json")
    if not all(isinstance(item, dict) for item in (build, publication)):
        raise LiveGraphError("validated receipt manifests are unavailable")
    assert isinstance(build, dict)
    assert isinstance(publication, dict)
    root_id = authority.root_id
    tickets = _tickets(build)
    publication_receipt = _receipt(publication, "publication")
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    if not isinstance(skill_id, str):
        raise LiveGraphError("validated receipt skill identity is unavailable")
    if not tickets:
        raise LiveGraphError("validated receipt manifest contains no tickets")
    expected_issue_count = len(tickets) + 2

    core_receipt = _receipt(build, "Build Order")
    auxiliary_mappings = publication_receipt.get("issue_mappings")
    if not isinstance(auxiliary_mappings, dict):
        raise LiveGraphError("validated publication receipt mappings are unavailable")
    mappings: dict[str, dict[str, Any]] = {}
    mappings[root_id] = _mapping(build.get("github_root"), root_id)
    for logical_id, ticket in tickets.items():
        mappings[logical_id] = _mapping(ticket.get("github"), logical_id)
    mappings[skill_id] = _mapping(auxiliary_mappings.get(skill_id), skill_id)
    if auxiliary_mappings.get(root_id) != mappings[root_id]:
        raise LiveGraphError("publication and core root mappings disagree")
    if len(mappings) != expected_issue_count:
        raise LiveGraphError(
            f"validated receipt mappings do not cover exactly {expected_issue_count} issues"
        )
    numbers = [mapping["number"] for mapping in mappings.values()]
    nodes = [mapping["node_id"] for mapping in mappings.values()]
    if len(numbers) != len(set(numbers)) or len(nodes) != len(set(nodes)):
        raise LiveGraphError("validated receipt contains duplicate issue identities")

    titles = _partitioned_field(
        root_id, skill_id, tickets, core_receipt, publication_receipt,
        "observed_issue_titles",
    )
    states = _partitioned_field(
        root_id, skill_id, tickets, core_receipt, publication_receipt,
        "observed_issue_states",
    )
    body_evidence = _partitioned_field(
        root_id, skill_id, tickets, core_receipt, publication_receipt,
        "observed_body_evidence",
    )
    marker_matches = _partitioned_field(
        root_id, skill_id, tickets, core_receipt, publication_receipt,
        "marker_query_matches",
    )
    labels = _labels(
        root_id, skill_id, tickets, core_receipt, publication_receipt,
    )
    blockers = _blockers(root_id, skill_id, tickets, publication)

    issues: dict[str, ExpectedIssue] = {}
    for logical_id in sorted(mappings):
        title = titles.get(logical_id)
        state = states.get(logical_id)
        evidence = body_evidence.get(logical_id)
        if not isinstance(title, str):
            raise LiveGraphError(f"{logical_id} receipt title is unavailable")
        if state != "OPEN":
            raise LiveGraphError(f"{logical_id} receipt state must equal OPEN")
        body_sha = evidence.get("body_sha256") if isinstance(evidence, dict) else None
        if not isinstance(body_sha, str):
            raise LiveGraphError(f"{logical_id} receipt body evidence is unavailable")
        parent = root_id if logical_id in tickets else None
        subissues = tuple(sorted(tickets)) if logical_id == root_id else ()
        issues[logical_id] = ExpectedIssue(
            mapping=mappings[logical_id],
            title=title,
            body_sha256=body_sha,
            labels=labels[logical_id],
            state="OPEN",
            parent=parent,
            subissues=subissues,
            blocked_by=blockers[logical_id],
        )
    normalized_matches: dict[str, tuple[tuple[str, Any], ...]] = {}
    for logical_id, raw in marker_matches.items():
        if not isinstance(raw, list):
            raise LiveGraphError(f"{logical_id} receipt marker matches are unavailable")
        normalized_matches[logical_id] = tuple(
            _mapping_tuple(_mapping(item, logical_id)) for item in raw
        )
    return ExpectedGraph(issues, normalized_matches, authority.root_comment_url)


def _compare_snapshot(
    snapshot: dict[str, Any], expected: ExpectedGraph,
    expected_comment_bodies: dict[str, str], receipt_commit: str, report: Report,
) -> bool:
    clean = True
    live_issues = snapshot.get("issues")
    if not isinstance(live_issues, dict) or set(live_issues) != set(expected.issues):
        report.error(
            "live GitHub issue snapshot must exactly cover all "
            f"{len(expected.issues)} mappings"
        )
        return False
    expected_edge_count = sum(
        len(issue.blocked_by) for issue in expected.issues.values()
    )
    expected_root_members = max(
        len(issue.subissues) for issue in expected.issues.values()
    )
    edge_count = 0
    for logical_id, wanted in sorted(expected.issues.items()):
        live = live_issues.get(logical_id)
        if not isinstance(live, dict):
            report.error(f"live GitHub issue snapshot is missing {logical_id}")
            clean = False
            continue
        comparisons = {
            "mapping": _mapping_tuple(wanted.mapping),
            "title": wanted.title,
            "body_sha256": wanted.body_sha256,
            "labels": wanted.labels,
            "state": wanted.state,
            "locked": False,
            "parent": wanted.parent,
            "subissues": wanted.subissues,
            "blocked_by": wanted.blocked_by,
        }
        for field, wanted_value in comparisons.items():
            if live.get(field) != wanted_value:
                report.error(
                    f"live GitHub {logical_id}.{field} does not match the immutable receipt"
                )
                clean = False
        blocked = live.get("blocked_by")
        if isinstance(blocked, tuple):
            edge_count += len(blocked)
    root = live_issues.get(next(
        logical_id for logical_id, issue in expected.issues.items()
        if len(issue.subissues) == expected_root_members
    ))
    if not isinstance(root, dict) or len(root.get("subissues", ())) != expected_root_members:
        report.error(
            "live GitHub root must have exactly "
            f"{expected_root_members} direct BO subissues"
        )
        clean = False
    if edge_count != expected_edge_count:
        report.error(
            "live GitHub graph must have exactly "
            f"{expected_edge_count} native blockedBy edges"
        )
        clean = False
    live_matches = snapshot.get("marker_matches")
    if live_matches != expected.marker_matches:
        report.error(
            "live all-state marker scan must return exactly one immutable mapping "
            "for every logical ID"
        )
        clean = False
    if set(expected_comment_bodies) not in ({"pending"}, {"pending", "successful"}):
        report.error("expected reconciliation comment states are invalid")
        return False
    pending_body = expected_comment_bodies["pending"]
    comments = snapshot.get("comments")
    pending_comment = {
        "url": expected.comment_url,
        "body": pending_body,
        "body_sha256": hashlib.sha256(pending_body.encode("utf-8")).hexdigest(),
    }
    if not isinstance(comments, dict) or comments.get("pending") != pending_comment:
        report.error(
            "live GitHub reconciliation evidence must preserve the exact "
            f"receipt-bound pending comment for {receipt_commit}"
        )
        clean = False
    reconciliation = comments.get("reconciliation") if isinstance(comments, dict) else None
    if not isinstance(reconciliation, tuple):
        report.error("live GitHub reconciliation comment scan is unavailable")
        clean = False
    else:
        pending_entry = (expected.comment_url, pending_body, 1)
        if set(expected_comment_bodies) == {"pending"}:
            expected_entries = (pending_entry,)
            if reconciliation != expected_entries:
                report.error(
                    "live GitHub pending reconciliation must contain exactly one "
                    "canonical pending comment and no successful evidence"
                )
                clean = False
        else:
            successful_body = expected_comment_bodies["successful"]
            if len(reconciliation) != 2 or pending_entry not in reconciliation:
                report.error(
                    "live GitHub successful reconciliation must preserve one exact "
                    "pending comment and add one distinct successful comment"
                )
                clean = False
            else:
                successful_entries = [
                    entry for entry in reconciliation if entry != pending_entry
                ]
                successful = successful_entries[0] if len(successful_entries) == 1 else None
                match = (
                    COMMENT_URL.fullmatch(successful[0])
                    if successful is not None else None
                )
                pending_match = COMMENT_URL.fullmatch(expected.comment_url)
                assert pending_match is not None
                if (
                    successful is None or successful[1:] != (successful_body, 1)
                    or successful[0] == expected.comment_url or match is None
                    or match.group("repository")
                    != pending_match.group("repository")
                    or match.group("number") != pending_match.group("number")
                ):
                    report.error(
                        "live GitHub successful reconciliation must contain one "
                        "distinct exact canonical successful receipt comment"
                    )
                    clean = False
    return clean


def _partitioned_field(
    root_id: str, skill_id: str,
    tickets: dict[str, dict[str, Any]],
    core: dict[str, Any], auxiliary: dict[str, Any],
    field: str,
) -> dict[str, Any]:
    expected_total = len({root_id, skill_id}) + len(tickets)
    result: dict[str, Any] = {}
    for receipt, identities, label in (
        (core, {root_id, *tickets}, "Build Order"),
        (auxiliary, {skill_id}, "publication"),
    ):
        value = receipt.get(field)
        if not isinstance(value, dict) or set(value) != identities:
            raise LiveGraphError(f"validated {label} receipt {field} partition is invalid")
        result.update(value)
    if len(result) != expected_total:
        raise LiveGraphError(
            f"validated receipt {field} does not cover {expected_total} issues"
        )
    return result


def _labels(
    root_id: str, skill_id: str,
    tickets: dict[str, dict[str, Any]],
    core: dict[str, Any], auxiliary: dict[str, Any],
) -> dict[str, tuple[str, ...]]:
    core_labels = core.get("observed_labels")
    auxiliary_labels = auxiliary.get("observed_labels")
    if not all(isinstance(item, dict) for item in (
        core_labels, auxiliary_labels,
    )):
        raise LiveGraphError("validated receipt observed labels are unavailable")
    assert isinstance(core_labels, dict)
    assert isinstance(auxiliary_labels, dict)
    if auxiliary_labels.get(root_id) != core_labels.get(root_id):
        raise LiveGraphError("publication and core root full-label observations disagree")
    result = {root_id: _label_tuple(core_labels.get(root_id), root_id)}
    for logical_id in tickets:
        result[logical_id] = _label_tuple(core_labels.get(logical_id), logical_id)
    result[skill_id] = _label_tuple(auxiliary_labels.get(skill_id), skill_id)
    expected_total = len({root_id, skill_id}) + len(tickets)
    if len(result) != expected_total:
        raise LiveGraphError(
            f"validated receipt labels do not cover {expected_total} issues"
        )
    return result


def _blockers(
    root_id: str, skill_id: str,
    tickets: dict[str, dict[str, Any]], publication: dict[str, Any],
) -> dict[str, tuple[str, ...]]:
    result = {logical_id: () for logical_id in (root_id, skill_id, *tickets)}
    for logical_id, ticket in tickets.items():
        result[logical_id] = _string_tuple(ticket.get("depends_on"), logical_id)
    external = publication.get("external_blocker_relations")
    if not isinstance(external, list):
        raise LiveGraphError("validated publication external blockers are unavailable")
    mutable = {key: list(value) for key, value in result.items()}
    for edge in external:
        if not isinstance(edge, dict):
            raise LiveGraphError("validated publication blocker edge is invalid")
        blocked = edge.get("blocked_ticket_id")
        blocker = edge.get("blocker_issue_id")
        if blocked not in mutable or not isinstance(blocker, str):
            raise LiveGraphError("validated publication blocker identity is invalid")
        mutable[blocked].append(blocker)
    return {key: tuple(sorted(value)) for key, value in mutable.items()}


def _tickets(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list):
        raise LiveGraphError("validated manifest tickets are unavailable")
    result = {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if len(result) != len(values):
        raise LiveGraphError("validated manifest ticket identities are ambiguous")
    return result


def _receipt(data: dict[str, Any], label: str) -> dict[str, Any]:
    value = data.get("github_reconciliation")
    if not isinstance(value, dict):
        raise LiveGraphError(f"validated {label} receipt is unavailable")
    return value


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != GITHUB_KEYS:
        raise LiveGraphError(f"{label} receipt mapping is invalid")
    repository, number = value.get("repository"), value.get("number")
    node, url = value.get("node_id"), value.get("url")
    if (
        not isinstance(repository, str) or type(number) is not int or number < 1
        or not isinstance(node, str) or not node or not isinstance(url, str)
    ):
        raise LiveGraphError(f"{label} receipt mapping is invalid")
    return dict(value)


def _mapping_tuple(value: dict[str, Any]) -> tuple[tuple[str, Any], ...]:
    return tuple((key, value[key]) for key in sorted(GITHUB_KEYS))


def _label_tuple(value: object, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ) or len(value) != len(set(value)):
        raise LiveGraphError(f"{label} receipt labels are invalid")
    return tuple(sorted(value))


def _string_tuple(value: object, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ) or len(value) != len(set(value)):
        raise LiveGraphError(f"{label} receipt relationships are invalid")
    return tuple(sorted(value))
