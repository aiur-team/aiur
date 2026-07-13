"""Requery and verify a materialized Build Order against live GitHub."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

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
MAX_PAGES = 100
MAX_ITEMS = 10_000


class LiveGitHubError(RuntimeError):
    """A read-only GitHub query could not produce trustworthy JSON."""


class GitHubReader(Protocol):
    def repository_issues(self, repository: str) -> list[dict[str, Any]]: ...

    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]: ...

    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]: ...

    def parent(self, repository: str, number: int) -> dict[str, Any] | None: ...


class GhApiReader:
    """Read the bounded publication graph through the authenticated ``gh`` CLI."""

    def __init__(self, cwd: Path, executable: str = "gh") -> None:
        self.cwd = cwd
        self.executable = executable

    def repository_issues(self, repository: str) -> list[dict[str, Any]]:
        return self._paged(f"repos/{repository}/issues?state=all&per_page=100")

    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._paged(
            f"repos/{repository}/issues/{number}/sub_issues?per_page=100"
        )

    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._paged(
            f"repos/{repository}/issues/{number}/dependencies/blocked_by?per_page=100"
        )

    def parent(self, repository: str, number: int) -> dict[str, Any] | None:
        return self._one(
            f"repos/{repository}/issues/{number}/parent", allow_404=True,
        )

    def _paged(self, endpoint: str) -> list[dict[str, Any]]:
        try:
            result = subprocess.run(
                [
                    self.executable,
                    "api",
                    "--hostname", "github.com",
                    "-H", "Accept: application/vnd.github+json",
                    "-H", "X-GitHub-Api-Version: 2026-03-10",
                    "--paginate",
                    "--slurp",
                    endpoint,
                ],
                cwd=self.cwd,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise LiveGitHubError(f"GitHub query failed for {endpoint}: {exc}") from exc
        if result.returncode:
            detail = result.stderr.strip() or f"exit {result.returncode}"
            raise LiveGitHubError(f"GitHub query failed for {endpoint}: {detail}")
        try:
            pages = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise LiveGitHubError(
                f"GitHub query returned invalid JSON for {endpoint}: {exc}"
            ) from exc
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise LiveGitHubError(
                f"GitHub paginated query returned an invalid envelope for {endpoint}"
            )
        if len(pages) > MAX_PAGES:
            raise LiveGitHubError(
                f"GitHub query exceeds the {MAX_PAGES}-page verification bound: {endpoint}"
            )
        items = [item for page in pages for item in page]
        if len(items) > MAX_ITEMS:
            raise LiveGitHubError(
                f"GitHub query exceeds the {MAX_ITEMS}-item verification bound: {endpoint}"
            )
        if any(not isinstance(item, dict) for item in items):
            raise LiveGitHubError(
                f"GitHub paginated query contains a malformed item for {endpoint}"
            )
        return items

    def _one(self, endpoint: str, *, allow_404: bool = False) -> dict[str, Any] | None:
        try:
            result = subprocess.run(
                [
                    self.executable,
                    "api",
                    "--hostname", "github.com",
                    "-H", "Accept: application/vnd.github+json",
                    "-H", "X-GitHub-Api-Version: 2026-03-10",
                    endpoint,
                ],
                cwd=self.cwd,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise LiveGitHubError(f"GitHub query failed for {endpoint}: {exc}") from exc
        if result.returncode:
            if allow_404 and "HTTP 404" in result.stderr:
                return None
            detail = result.stderr.strip() or f"exit {result.returncode}"
            raise LiveGitHubError(f"GitHub query failed for {endpoint}: {detail}")
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise LiveGitHubError(
                f"GitHub query returned invalid JSON for {endpoint}: {exc}"
            ) from exc
        if not isinstance(value, dict):
            raise LiveGitHubError(f"GitHub query returned an invalid object for {endpoint}")
        return value


@dataclass(frozen=True)
class LiveSnapshot:
    issues: tuple[tuple[str, str], ...]
    marker_matches: tuple[tuple[str, tuple[str, ...]], ...]
    root_members: tuple[str, ...]
    parents: tuple[tuple[str, str | None], ...]
    dependency_edges: tuple[tuple[str, str], ...]


def validate_live_github_receipt(
    data: dict[str, Any],
    report: Report,
    reader: GitHubReader,
) -> None:
    """Require two identical live snapshots that exactly match one valid receipt."""
    first_report = Report()
    first = _snapshot(data, reader, first_report)
    _merge(first_report, report)
    if first is None or first_report.errors:
        return
    second_report = Report()
    second = _snapshot(data, reader, second_report)
    _merge(second_report, report)
    if second is None or second_report.errors:
        return
    if first != second:
        report.error("live GitHub publication graph changed during bounded requery")
        return
    _compare_receipt(data, first, report)


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


def _expected_mappings(
    data: dict[str, Any], report: Report,
) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    root_id = data.get("build_order_id")
    root = data.get("github_root")
    if isinstance(root_id, str) and isinstance(root, dict):
        result[root_id] = root
    tickets = data.get("tickets")
    if isinstance(tickets, list):
        for ticket in tickets:
            if not isinstance(ticket, dict):
                continue
            logical_id, mapping = ticket.get("id"), ticket.get("github")
            if isinstance(logical_id, str) and isinstance(mapping, dict):
                result[logical_id] = mapping
    if not result:
        report.error("live GitHub validation found no materialized mappings")
    return result


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


def _relationships(
    reader: GitHubReader, kind: str, mapping: dict[str, Any],
    reverse: dict[str, str], report: Report,
) -> set[str]:
    try:
        values = (
            reader.subissues(mapping["repository"], mapping["number"])
            if kind == "subissues"
            else reader.blockers(mapping["repository"], mapping["number"])
        )
    except LiveGitHubError as exc:
        report.error(str(exc))
        return set()
    result: set[str] = set()
    seen: set[tuple[str, int]] = set()
    for raw in values:
        observed = _mapping(raw, None, f"live GitHub {kind}", report)
        if observed is None:
            continue
        identity = (observed["repository"], observed["number"])
        if identity in seen:
            report.error(f"live GitHub {kind} response contains a duplicate issue")
            continue
        seen.add(identity)
        logical_id = reverse.get(_mapping_key(observed))
        if logical_id is None:
            report.error(
                f"live GitHub {kind} contains unexpected issue "
                f"{identity[0]}#{identity[1]}"
            )
            continue
        result.add(logical_id)
    return result


def _parent(
    reader: GitHubReader, mapping: dict[str, Any],
    reverse: dict[str, str], report: Report,
) -> str | None:
    try:
        raw = reader.parent(mapping["repository"], mapping["number"])
    except LiveGitHubError as exc:
        report.error(str(exc))
        return None
    if raw is None:
        return None
    observed = _mapping(raw, None, "live GitHub parent", report)
    if observed is None:
        return None
    identity = (observed["repository"], observed["number"])
    logical_id = reverse.get(_mapping_key(observed))
    if logical_id is None:
        report.error(
            f"live GitHub parent contains unexpected issue "
            f"{identity[0]}#{identity[1]}"
        )
    return logical_id


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


def _mapping_key(mapping: dict[str, Any]) -> str:
    return (
        f"{mapping.get('repository')}#{mapping.get('number')}|"
        f"{mapping.get('node_id')}|{mapping.get('url')}"
    )


def _canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.warnings.extend(source.warnings)
