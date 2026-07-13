"""Read-only, receipt-bound verification of the complete live GitHub graph."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from typing import Any

from publication_common import GITHUB_KEYS, Report
from publication_receipt_authority import ReceiptAuthority


API_VERSION = "2026-03-10"
MARKER_NAME = "aiur-planning-issue"
COMMENT_MARKER = "aiur-build-order-reconciliation"
MARKER = re.compile(
    r"<!-- aiur-planning-issue[ \t]*\n(?P<payload>[^\n]*)\n-->", re.ASCII,
)
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
MAX_PAGES = 100
PAGE_SIZE = 100
MAX_ITEMS = MAX_PAGES * PAGE_SIZE
GITHUB_TIMEOUT_SECONDS = 30
EXPECTED_ISSUES = 46
EXPECTED_ROOT_MEMBERS = 19
EXPECTED_BLOCKED_BY_EDGES = 73


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


def verify_live_graph(
    authority: ReceiptAuthority,
    receipt_commit: str,
    expected_comment_body: str,
    report: Report,
) -> bool:
    """Query GitHub twice and compare one stable graph to the immutable receipt."""
    try:
        expected = _expected_graph(authority)
        first = _capture_snapshot(authority, expected, expected_comment_body)
        second = _capture_snapshot(authority, expected, expected_comment_body)
    except LiveGraphError as exc:
        report.error(f"live GitHub publication graph query failed: {exc}")
        return False
    if first != second:
        report.error(
            "live GitHub publication graph changed between two complete bounded reads"
        )
        return False
    return _compare_snapshot(
        first, expected, expected_comment_body, receipt_commit, report
    )


def _expected_graph(authority: ReceiptAuthority) -> ExpectedGraph:
    manifests = authority.receipt_manifests
    build = manifests.get("build-order.json")
    companions = manifests.get("dashboard-companions.json")
    publication = manifests.get("publication.json")
    if not all(isinstance(item, dict) for item in (build, companions, publication)):
        raise LiveGraphError("validated receipt manifests are unavailable")
    assert isinstance(build, dict)
    assert isinstance(companions, dict)
    assert isinstance(publication, dict)
    root_id = authority.root_id
    build_tickets = _tickets(build, "BO")
    dash_tickets = _tickets(companions, "DASH")
    publication_receipt = _receipt(publication, "publication")
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    if not isinstance(skill_id, str):
        raise LiveGraphError("validated receipt skill identity is unavailable")
    if len(build_tickets) != EXPECTED_ROOT_MEMBERS or len(dash_tickets) != 25:
        raise LiveGraphError("validated receipt does not contain the bounded 19/25 graph")

    core_receipt = _receipt(build, "Build Order")
    dash_receipt = _receipt(companions, "companion")
    auxiliary_mappings = publication_receipt.get("issue_mappings")
    if not isinstance(auxiliary_mappings, dict):
        raise LiveGraphError("validated publication receipt mappings are unavailable")
    mappings: dict[str, dict[str, Any]] = {}
    mappings[root_id] = _mapping(build.get("github_root"), root_id)
    for logical_id, ticket in build_tickets.items():
        mappings[logical_id] = _mapping(ticket.get("github"), logical_id)
    for logical_id, ticket in dash_tickets.items():
        mappings[logical_id] = _mapping(ticket.get("github"), logical_id)
    mappings[skill_id] = _mapping(auxiliary_mappings.get(skill_id), skill_id)
    if auxiliary_mappings.get(root_id) != mappings[root_id]:
        raise LiveGraphError("publication and core root mappings disagree")
    if len(mappings) != EXPECTED_ISSUES:
        raise LiveGraphError("validated receipt mappings do not cover exactly 46 issues")
    numbers = [mapping["number"] for mapping in mappings.values()]
    nodes = [mapping["node_id"] for mapping in mappings.values()]
    if len(numbers) != len(set(numbers)) or len(nodes) != len(set(nodes)):
        raise LiveGraphError("validated receipt contains duplicate issue identities")

    titles = _partitioned_field(
        root_id, skill_id, build_tickets, dash_tickets,
        core_receipt, dash_receipt, publication_receipt,
        "observed_issue_titles",
    )
    states = _partitioned_field(
        root_id, skill_id, build_tickets, dash_tickets,
        core_receipt, dash_receipt, publication_receipt,
        "observed_issue_states",
    )
    body_evidence = _partitioned_field(
        root_id, skill_id, build_tickets, dash_tickets,
        core_receipt, dash_receipt, publication_receipt,
        "observed_body_evidence",
    )
    marker_matches = _partitioned_field(
        root_id, skill_id, build_tickets, dash_tickets,
        core_receipt, dash_receipt, publication_receipt,
        "marker_query_matches",
    )
    labels = _labels(
        root_id, skill_id, build_tickets, dash_tickets,
        core_receipt, dash_receipt, publication_receipt,
    )
    blockers = _blockers(
        root_id, skill_id, build_tickets, dash_tickets, publication
    )
    edge_count = sum(len(items) for items in blockers.values())
    if edge_count != EXPECTED_BLOCKED_BY_EDGES:
        raise LiveGraphError(
            f"validated receipt graph has {edge_count} blockedBy edges, expected 73"
        )

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
        parent = root_id if logical_id in build_tickets else None
        subissues = tuple(sorted(build_tickets)) if logical_id == root_id else ()
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


def _capture_snapshot(
    authority: ReceiptAuthority,
    expected: ExpectedGraph,
    expected_comment_body: str,
) -> dict[str, Any]:
    repository = authority.repository
    base = f"repos/{repository}"
    raw_issues = _github_pages(f"{base}/issues?state=all&per_page=100")
    by_number: dict[int, dict[str, Any]] = {}
    all_numbers: set[int] = set()
    all_nodes: set[str] = set()
    marker_matches: dict[str, list[tuple[tuple[str, Any], ...]]] = {
        logical_id: [] for logical_id in expected.issues
    }
    mapped_numbers = {
        item.mapping["number"]: logical_id
        for logical_id, item in expected.issues.items()
    }
    for raw in raw_issues:
        if not isinstance(raw, dict):
            raise LiveGraphError("all-state issue scan returned a non-object entry")
        number = raw.get("number")
        node = raw.get("node_id")
        if type(number) is not int or number < 1 or not isinstance(node, str) or not node:
            raise LiveGraphError("all-state issue scan returned an invalid identity")
        if number in all_numbers or node in all_nodes:
            raise LiveGraphError("all-state issue scan returned duplicate identities")
        all_numbers.add(number)
        all_nodes.add(node)
        is_pull_request = "pull_request" in raw
        if is_pull_request and not isinstance(raw.get("pull_request"), dict):
            raise LiveGraphError("all-state issue scan returned an invalid pull request entry")
        marker_mapping = _raw_scan_mapping(raw, repository, is_pull_request)
        for payload in _marker_payloads(raw.get("body"), number):
            logical_id = payload.get("logical_id")
            if logical_id in marker_matches:
                marker_matches[logical_id].append(
                    _mapping_tuple(marker_mapping)
                )
        if number in mapped_numbers and is_pull_request:
            raise LiveGraphError(
                f"mapped logical issue {mapped_numbers[number]} resolves to a pull request"
            )
        if not is_pull_request:
            by_number[number] = raw
    issues: dict[str, Any] = {}
    for logical_id, item in sorted(expected.issues.items()):
        raw = by_number.get(item.mapping["number"])
        if raw is None:
            raise LiveGraphError(f"mapped issue {logical_id} is absent from all-state scan")
        mapping = _raw_mapping(raw, repository)
        title, body = raw.get("title"), raw.get("body")
        labels = _raw_labels(raw)
        state = raw.get("state")
        locked = raw.get("locked")
        updated_at = raw.get("updated_at")
        if not isinstance(title, str) or not isinstance(body, str):
            raise LiveGraphError(f"mapped issue {logical_id} returned non-text content")
        if not isinstance(state, str) or type(locked) is not bool:
            raise LiveGraphError(f"mapped issue {logical_id} returned invalid state")
        if not isinstance(updated_at, str) or not updated_at:
            raise LiveGraphError(f"mapped issue {logical_id} lacks updated_at")
        number = item.mapping["number"]
        parent_raw = _github_json(f"{base}/issues/{number}/parent", allow_404=True)
        parent = None if parent_raw is None else _relationship_ref(
            parent_raw, repository, mapped_numbers,
        )
        subissues = tuple(sorted(
            _relationship_ref(value, repository, mapped_numbers)
            for value in _github_pages(
                f"{base}/issues/{number}/sub_issues?per_page=100"
            )
        ))
        blocked_by = tuple(sorted(
            _relationship_ref(value, repository, mapped_numbers)
            for value in _github_pages(
                f"{base}/issues/{number}/dependencies/blocked_by?per_page=100"
            )
        ))
        issues[logical_id] = {
            "mapping": _mapping_tuple(mapping),
            "title": title,
            "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
            "labels": labels,
            "state": state.upper(),
            "locked": locked,
            "updated_at": updated_at,
            "parent": parent,
            "subissues": subissues,
            "blocked_by": blocked_by,
        }

    comment_match = COMMENT_URL.fullmatch(expected.comment_url)
    if comment_match is None or comment_match.group("repository") != repository:
        raise LiveGraphError("receipt comment URL is not in the trusted repository")
    comment_id = comment_match.group("comment")
    comment = _github_json(f"{base}/issues/comments/{comment_id}")
    if not isinstance(comment, dict):
        raise LiveGraphError("exact reconciliation comment query returned no object")
    comment_url, comment_body = comment.get("html_url"), comment.get("body")
    if not isinstance(comment_url, str) or not isinstance(comment_body, str):
        raise LiveGraphError("exact reconciliation comment returned invalid content")
    root_number = expected.issues[authority.root_id].mapping["number"]
    raw_comments = _github_pages(
        f"{base}/issues/{root_number}/comments?per_page=100"
    )
    marker_comment_urls: list[str] = []
    for raw in raw_comments:
        if not isinstance(raw, dict):
            raise LiveGraphError("root comment scan returned a non-object")
        body, url = raw.get("body"), raw.get("html_url")
        if not isinstance(body, str) or not isinstance(url, str):
            raise LiveGraphError("root comment scan returned invalid content")
        count = body.count(f"<!-- {COMMENT_MARKER}")
        marker_comment_urls.extend([url] * count)
    return {
        "issues": issues,
        "marker_matches": {
            logical_id: tuple(sorted(matches))
            for logical_id, matches in sorted(marker_matches.items())
        },
        "comment": {
            "url": comment_url,
            "body": comment_body,
            "body_sha256": hashlib.sha256(comment_body.encode("utf-8")).hexdigest(),
            "marker_comment_urls": tuple(sorted(marker_comment_urls)),
            "expected_body_sha256": hashlib.sha256(
                expected_comment_body.encode("utf-8")
            ).hexdigest(),
        },
    }


def _compare_snapshot(
    snapshot: dict[str, Any], expected: ExpectedGraph,
    expected_comment_body: str, receipt_commit: str, report: Report,
) -> bool:
    clean = True
    live_issues = snapshot.get("issues")
    if not isinstance(live_issues, dict) or set(live_issues) != set(expected.issues):
        report.error("live GitHub issue snapshot must exactly cover all 46 mappings")
        return False
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
        if len(issue.subissues) == EXPECTED_ROOT_MEMBERS
    ))
    if not isinstance(root, dict) or len(root.get("subissues", ())) != EXPECTED_ROOT_MEMBERS:
        report.error("live GitHub root must have exactly 19 direct BO subissues")
        clean = False
    if edge_count != EXPECTED_BLOCKED_BY_EDGES:
        report.error("live GitHub graph must have exactly 73 native blockedBy edges")
        clean = False
    live_matches = snapshot.get("marker_matches")
    if live_matches != expected.marker_matches:
        report.error(
            "live all-state marker scan must return exactly one immutable mapping "
            "for every logical ID"
        )
        clean = False
    comment = snapshot.get("comment")
    expected_comment = {
        "url": expected.comment_url,
        "body": expected_comment_body,
        "body_sha256": hashlib.sha256(expected_comment_body.encode("utf-8")).hexdigest(),
        "marker_comment_urls": (expected.comment_url,),
        "expected_body_sha256": hashlib.sha256(
            expected_comment_body.encode("utf-8")
        ).hexdigest(),
    }
    if comment != expected_comment:
        report.error(
            "live GitHub reconciliation comment must be the exact unique "
            f"receipt-bound comment for {receipt_commit}"
        )
        clean = False
    return clean


def _partitioned_field(
    root_id: str, skill_id: str,
    build_tickets: dict[str, dict[str, Any]],
    dash_tickets: dict[str, dict[str, Any]],
    core: dict[str, Any], dash: dict[str, Any], auxiliary: dict[str, Any],
    field: str,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for receipt, identities, label in (
        (core, {root_id, *build_tickets}, "Build Order"),
        (dash, set(dash_tickets), "companion"),
        (auxiliary, {skill_id}, "publication"),
    ):
        value = receipt.get(field)
        if not isinstance(value, dict) or set(value) != identities:
            raise LiveGraphError(f"validated {label} receipt {field} partition is invalid")
        result.update(value)
    if len(result) != EXPECTED_ISSUES:
        raise LiveGraphError(f"validated receipt {field} does not cover 46 issues")
    return result


def _labels(
    root_id: str, skill_id: str,
    build_tickets: dict[str, dict[str, Any]],
    dash_tickets: dict[str, dict[str, Any]],
    core: dict[str, Any], dash: dict[str, Any], auxiliary: dict[str, Any],
) -> dict[str, tuple[str, ...]]:
    core_labels = core.get("observed_labels")
    dash_labels = dash.get("observed_labels")
    auxiliary_labels = auxiliary.get("observed_labels")
    if not all(isinstance(item, dict) for item in (
        core_labels, dash_labels, auxiliary_labels,
    )):
        raise LiveGraphError("validated receipt observed labels are unavailable")
    assert isinstance(core_labels, dict)
    assert isinstance(dash_labels, dict)
    assert isinstance(auxiliary_labels, dict)
    if auxiliary_labels.get(root_id) != core_labels.get(root_id):
        raise LiveGraphError("publication and core root full-label observations disagree")
    result = {root_id: _label_tuple(core_labels.get(root_id), root_id)}
    for logical_id in build_tickets:
        result[logical_id] = _label_tuple(core_labels.get(logical_id), logical_id)
    for logical_id in dash_tickets:
        result[logical_id] = _label_tuple(dash_labels.get(logical_id), logical_id)
    result[skill_id] = _label_tuple(auxiliary_labels.get(skill_id), skill_id)
    if len(result) != EXPECTED_ISSUES:
        raise LiveGraphError("validated receipt labels do not cover 46 issues")
    return result


def _blockers(
    root_id: str, skill_id: str,
    build_tickets: dict[str, dict[str, Any]],
    dash_tickets: dict[str, dict[str, Any]], publication: dict[str, Any],
) -> dict[str, tuple[str, ...]]:
    result = {logical_id: () for logical_id in (
        root_id, skill_id, *build_tickets, *dash_tickets,
    )}
    for logical_id, ticket in build_tickets.items():
        result[logical_id] = _string_tuple(ticket.get("depends_on"), logical_id)
    for logical_id, ticket in dash_tickets.items():
        result[logical_id] = tuple(sorted((
            *_string_tuple(ticket.get("depends_on"), logical_id),
            *_string_tuple(ticket.get("external_blockers"), logical_id),
        )))
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


def _tickets(data: dict[str, Any], prefix: str) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list):
        raise LiveGraphError(f"validated {prefix} tickets are unavailable")
    result = {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
        and item["id"].startswith(f"{prefix}-")
    }
    if len(result) != len(values):
        raise LiveGraphError(f"validated {prefix} ticket identities are ambiguous")
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


def _raw_mapping(raw: dict[str, Any], repository: str) -> dict[str, Any]:
    number, node, url = raw.get("number"), raw.get("node_id"), raw.get("html_url")
    if type(number) is not int or number < 1 or not isinstance(node, str) or not node:
        raise LiveGraphError("GitHub issue returned an invalid mapping")
    expected_url = f"https://github.com/{repository}/issues/{number}"
    if url != expected_url:
        raise LiveGraphError("GitHub issue URL escaped the trusted repository")
    return {"repository": repository, "number": number, "node_id": node, "url": url}


def _raw_scan_mapping(
    raw: dict[str, Any], repository: str, is_pull_request: bool,
) -> dict[str, Any]:
    """Return a trusted scan identity without hiding PR marker collisions."""
    number, node, url = raw.get("number"), raw.get("node_id"), raw.get("html_url")
    if type(number) is not int or number < 1 or not isinstance(node, str) or not node:
        raise LiveGraphError("all-state issue scan returned an invalid mapping")
    if not isinstance(url, str):
        raise LiveGraphError("all-state issue scan returned an invalid URL")
    match = ISSUE_OR_PULL_URL.fullmatch(url)
    wanted_kind = "pull" if is_pull_request else "issues"
    if (
        match is None or match.group("repository") != repository
        or match.group("kind") != wanted_kind
        or int(match.group("number")) != number
    ):
        raise LiveGraphError("all-state issue scan escaped the trusted repository")
    return {"repository": repository, "number": number, "node_id": node, "url": url}


def _raw_labels(raw: dict[str, Any]) -> tuple[str, ...]:
    values = raw.get("labels")
    if not isinstance(values, list):
        raise LiveGraphError("GitHub issue labels are not an array")
    result: list[str] = []
    for item in values:
        name = item.get("name") if isinstance(item, dict) else item
        if not isinstance(name, str) or not name:
            raise LiveGraphError("GitHub issue returned an invalid label")
        result.append(name)
    if len(result) != len(set(result)):
        raise LiveGraphError("GitHub issue returned duplicate labels")
    return tuple(sorted(result))


def _marker_payloads(body: object, number: int) -> list[dict[str, Any]]:
    if body is None:
        return []
    if not isinstance(body, str):
        raise LiveGraphError(f"issue #{number} body is not text")
    openings = body.count(f"<!-- {MARKER_NAME}")
    matches = list(MARKER.finditer(body))
    if openings != len(matches):
        raise LiveGraphError(f"issue #{number} contains a malformed planning marker")
    payloads: list[dict[str, Any]] = []
    for match in matches:
        try:
            payload = json.loads(match.group("payload"))
        except json.JSONDecodeError as exc:
            raise LiveGraphError(
                f"issue #{number} planning marker is invalid JSON: {exc}"
            ) from exc
        if not isinstance(payload, dict):
            raise LiveGraphError(f"issue #{number} planning marker is not an object")
        payloads.append(payload)
    return payloads


def _relationship_ref(
    raw: object, repository: str, mapped_numbers: dict[int, str],
) -> str:
    if not isinstance(raw, dict):
        raise LiveGraphError("GitHub relationship returned a non-object")
    if "pull_request" in raw:
        raise LiveGraphError("GitHub relationship returned a pull request")
    number = raw.get("number")
    if type(number) is not int or number < 1:
        raise LiveGraphError("GitHub relationship lacks an issue number")
    url = raw.get("html_url")
    if not isinstance(url, str):
        raise LiveGraphError("GitHub relationship lacks an issue URL")
    match = ISSUE_URL.fullmatch(url)
    if match is None or int(match.group("number")) != number:
        raise LiveGraphError("GitHub relationship returned an invalid issue URL")
    relationship_repository = match.group("repository")
    if relationship_repository == repository and number in mapped_numbers:
        return mapped_numbers[number]
    return f"{relationship_repository}#{number}"


def _github_pages(endpoint: str) -> list[Any]:
    separator = "&" if "?" in endpoint else "?"
    result: list[Any] = []
    for page in range(1, MAX_PAGES + 1):
        value = _github_json(f"{endpoint}{separator}page={page}")
        if not isinstance(value, list):
            raise LiveGraphError(f"paginated GitHub response is not an array: {endpoint}")
        if len(value) > PAGE_SIZE:
            raise LiveGraphError(
                f"paginated GitHub response exceeded {PAGE_SIZE} items per page: "
                f"{endpoint}"
            )
        if len(result) + len(value) > MAX_ITEMS:
            raise LiveGraphError(
                f"paginated GitHub response exceeded {MAX_ITEMS} items: {endpoint}"
            )
        result.extend(value)
        if len(value) < PAGE_SIZE:
            return result
    raise LiveGraphError(f"paginated GitHub response exceeded {MAX_PAGES} pages: {endpoint}")


def _github_json(endpoint: str, *, allow_404: bool = False) -> object | None:
    try:
        result = subprocess.run(
            [
                "gh", "api", "--hostname", "github.com",
                "-H", "Accept: application/vnd.github.raw+json",
                "-H", f"X-GitHub-Api-Version: {API_VERSION}",
                "--method", "GET", endpoint,
            ],
            check=False, capture_output=True, text=True,
            timeout=GITHUB_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise LiveGraphError(
            f"GitHub GET {endpoint} exceeded {GITHUB_TIMEOUT_SECONDS} seconds"
        ) from exc
    except OSError as exc:
        raise LiveGraphError(f"cannot execute GitHub CLI: {exc}") from exc
    if result.returncode:
        if allow_404 and "HTTP 404" in result.stderr:
            return None
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise LiveGraphError(f"GitHub GET {endpoint} failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise LiveGraphError(f"GitHub GET {endpoint} returned invalid JSON: {exc}") from exc
