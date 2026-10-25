"""Read-only, receipt-bound verification of the complete live GitHub graph."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from typing import Any

from publication_common import Report
from publication_receipt_authority import ReceiptAuthority
from publication_live_expected import (
    COMMENT_URL,
    _compare_snapshot,
    _expected_graph,
    ExpectedGraph,
    ISSUE_OR_PULL_URL,
    ISSUE_URL,
    LiveGraphError,
    _mapping_tuple,
)
from publication_live_expected import (  # noqa: F401
    _blockers,
    ExpectedIssue,
    _label_tuple,
    _labels,
    _mapping,
    _partitioned_field,
    _receipt,
    _string_tuple,
    _tickets,
)


API_VERSION = "2026-03-10"
MARKER_NAME = "aiur-planning-issue"
COMMENT_MARKER = "aiur-build-order-reconciliation"
MARKER = re.compile(
    r"<!-- aiur-planning-issue[ \t]*\n(?P<payload>[^\n]*)\n-->", re.ASCII,
)
MAX_PAGES = 100
PAGE_SIZE = 100
MAX_ITEMS = MAX_PAGES * PAGE_SIZE
MAX_TOTAL_REQUESTS = 2_500
MAX_TOTAL_ITEMS = 50_000
GITHUB_TIMEOUT_SECONDS = 30
# The expected issue and blockedBy-edge totals are not constants: they are
# derived from the validated receipt manifests (every consolidated Build Order
# ticket plus the root and skill issue; every depends_on edge plus the
# publication external blocker relations).


@dataclass
class QueryBudget:
    requests_remaining: int = MAX_TOTAL_REQUESTS
    items_remaining: int = MAX_TOTAL_ITEMS

    def consume_request(self) -> None:
        if self.requests_remaining <= 0:
            raise LiveGraphError("GitHub verification exceeds total request bound")
        self.requests_remaining -= 1

    def consume_items(self, count: int) -> None:
        if count > self.items_remaining:
            raise LiveGraphError("GitHub verification exceeds total item bound")
        self.items_remaining -= count


def verify_live_graph(
    authority: ReceiptAuthority,
    receipt_commit: str,
    expected_comment_bodies: dict[str, str],
    report: Report,
) -> bool:
    """Query GitHub twice and compare one stable graph to the immutable receipt."""
    try:
        expected = _expected_graph(authority)
        budget = QueryBudget()
        first = _capture_snapshot(authority, expected, budget)
        second = _capture_snapshot(authority, expected, budget)
    except LiveGraphError as exc:
        report.error(f"live GitHub publication graph query failed: {exc}")
        return False
    if first != second:
        report.error(
            "live GitHub publication graph changed between two complete bounded reads"
        )
        return False
    return _compare_snapshot(
        first, expected, expected_comment_bodies, receipt_commit, report
    )


def _capture_snapshot(
    authority: ReceiptAuthority,
    expected: ExpectedGraph,
    budget: QueryBudget | None = None,
) -> dict[str, Any]:
    budget = budget or QueryBudget()
    repository = authority.repository
    base = f"repos/{repository}"
    raw_issues = _github_pages(
        f"{base}/issues?state=all&per_page=100", budget=budget,
    )
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
        parent_raw = _github_json(
            f"{base}/issues/{number}/parent", allow_404=True, budget=budget,
        )
        parent = None if parent_raw is None else _relationship_ref(
            parent_raw, repository, mapped_numbers,
        )
        subissues = tuple(sorted(
            _relationship_ref(value, repository, mapped_numbers)
            for value in _github_pages(
                f"{base}/issues/{number}/sub_issues?per_page=100", budget=budget,
            )
        ))
        blocked_by = tuple(sorted(
            _relationship_ref(value, repository, mapped_numbers)
            for value in _github_pages(
                f"{base}/issues/{number}/dependencies/blocked_by?per_page=100",
                budget=budget,
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
    root_number = expected.issues[authority.root_id].mapping["number"]
    if (
        comment_match is None or comment_match.group("repository") != repository
        or int(comment_match.group("number")) != root_number
    ):
        raise LiveGraphError("receipt comment URL is not in the trusted repository")
    comment_id = comment_match.group("comment")
    comment = _github_json(
        f"{base}/issues/comments/{comment_id}", budget=budget,
    )
    if not isinstance(comment, dict):
        raise LiveGraphError("exact reconciliation comment query returned no object")
    comment_url, comment_body = comment.get("html_url"), comment.get("body")
    if not isinstance(comment_url, str) or not isinstance(comment_body, str):
        raise LiveGraphError("exact reconciliation comment returned invalid content")
    raw_comments = _github_pages(
        f"{base}/issues/{root_number}/comments?per_page=100", budget=budget,
    )
    reconciliation_comments: list[tuple[str, str, int]] = []
    for raw in raw_comments:
        if not isinstance(raw, dict):
            raise LiveGraphError("root comment scan returned a non-object")
        body, url = raw.get("body"), raw.get("html_url")
        if not isinstance(body, str) or not isinstance(url, str):
            raise LiveGraphError("root comment scan returned invalid content")
        count = body.count(f"<!-- {COMMENT_MARKER}")
        if count:
            match = COMMENT_URL.fullmatch(url)
            if (
                match is None or match.group("repository") != repository
                or int(match.group("number")) != root_number
            ):
                raise LiveGraphError(
                    "root reconciliation comment URL escaped the trusted root issue"
                )
            reconciliation_comments.append((url, body, count))
    return {
        "issues": issues,
        "marker_matches": {
            logical_id: tuple(sorted(matches))
            for logical_id, matches in sorted(marker_matches.items())
        },
        "comments": {
            "pending": {
                "url": comment_url,
                "body": comment_body,
                "body_sha256": hashlib.sha256(
                    comment_body.encode("utf-8")
                ).hexdigest(),
            },
            "reconciliation": tuple(sorted(reconciliation_comments)),
        },
    }


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


def _github_pages(
    endpoint: str, *, budget: QueryBudget | None = None,
) -> list[Any]:
    budget = budget or QueryBudget()
    separator = "&" if "?" in endpoint else "?"
    result: list[Any] = []
    for page in range(1, MAX_PAGES + 1):
        value = _github_json(
            f"{endpoint}{separator}page={page}", budget=budget,
        )
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
        budget.consume_items(len(value))
        result.extend(value)
        if len(value) < PAGE_SIZE:
            return result
    raise LiveGraphError(f"paginated GitHub response exceeded {MAX_PAGES} pages: {endpoint}")


def _github_json(
    endpoint: str, *, allow_404: bool = False,
    budget: QueryBudget | None = None,
) -> object | None:
    budget = budget or QueryBudget()
    budget.consume_request()
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
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise LiveGraphError(f"GitHub GET {endpoint} returned invalid JSON: {exc}") from exc
    if value is not None and not isinstance(value, list):
        budget.consume_items(1)
    return value
