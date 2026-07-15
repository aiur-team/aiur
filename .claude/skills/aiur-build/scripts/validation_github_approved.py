"""Load canonical body sources from an immutable approved planning commit."""

from __future__ import annotations

import json
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from validation_common import (
    Report,
    repository_relative_path,
    resolve_regular_file,
)
from validation_github_rendering import (
    inspect_issue_body,
    render_template_body,
    render_ticket_body,
)
from validation_git_approved_source import approved_text, exact_approved_commit


@dataclass(frozen=True)
class ApprovedIssueExpectations:
    bodies: dict[str, dict[str, Any]]
    titles: dict[str, str]


def render_approved_build_order(
    repository_root: Path,
    approved: object,
    build_order_path: str,
    root_document_path: str,
    current: dict[str, Any],
    report: Report,
) -> ApprovedIssueExpectations | None:
    """Render approved bodies and enforce the current document freeze."""
    root = repository_root.resolve()
    if not exact_approved_commit(root, approved, report):
        return None
    build_path = repository_relative_path(
        build_order_path, "approved build-order path", report,
    )
    root_path = repository_relative_path(
        root_document_path, "approved root document path", report,
    )
    if build_path is None or root_path is None or not isinstance(approved, str):
        return None
    raw = approved_text(root, approved, build_path, "approved build-order", report)
    if raw is None:
        return None
    try:
        approved_data = json.loads(raw)
    except json.JSONDecodeError as exc:
        report.error(f"approved build-order must be valid JSON: {exc}")
        return None
    if not isinstance(approved_data, dict):
        report.error("approved build-order must be a JSON object")
        return None
    if _frozen_planning_fields(approved_data) != _frozen_planning_fields(current):
        report.error(
            "materialized build-order planning fields must equal the approved commit"
        )
    for key in ("repository", "plan_version", "build_order_id"):
        if approved_data.get(key) != current.get(key):
            report.error(f"approved build-order {key} must match the materialized pack")
    repository = current.get("repository")
    plan_version = current.get("plan_version")
    root_id = current.get("build_order_id")
    if not isinstance(repository, str) or type(plan_version) is not int or not isinstance(root_id, str):
        report.error("materialized pack identity is unavailable for approved body rendering")
        return None
    current_tickets = _tickets(current)
    approved_tickets = _tickets(approved_data)
    if set(approved_tickets) != set(current_tickets):
        report.error("approved build-order ticket IDs must match the materialized pack")
        return None
    expectations: dict[str, dict[str, Any]] = {}
    titles: dict[str, str] = {}
    documents_frozen = True
    root_source = approved_text(root, approved, root_path, "approved root document", report)
    if root_source is not None:
        title = _document_title(root_source, "approved root document", report)
        if title is not None:
            titles[root_id] = title
        body = render_template_body(
            root_source, repository, root_id, plan_version, approved, report,
            "approved root document",
        )
        if body is not None:
            documents_frozen &= _current_matches(
                root, root_path, body, "current root document", report,
            )
            evidence = inspect_issue_body(
                body, repository, root_id, plan_version, approved, report,
                "approved root body",
            )
            if evidence is not None:
                expectations[root_id] = evidence
    pack_dir = PurePosixPath(build_path).parent
    for ticket_id in sorted(approved_tickets):
        ticket = approved_tickets[ticket_id]
        document = ticket.get("document")
        relative = repository_relative_path(
            document, f"approved {ticket_id}.document", report,
        )
        if relative is None:
            continue
        source_path = str(pack_dir / PurePosixPath(relative))
        source = approved_text(
            root, approved, source_path, f"approved {ticket_id} document", report,
        )
        if source is None:
            continue
        title = _document_title(source, f"approved {ticket_id} document", report)
        if title is not None:
            titles[ticket_id] = title
        documents_frozen &= _current_matches(
            root, source_path, source, f"current {ticket_id} document", report,
        )
        body = render_ticket_body(
            source, repository, ticket_id, plan_version, approved, report,
            f"approved {ticket_id} body",
        )
        if body is None:
            continue
        evidence = inspect_issue_body(
            body, repository, ticket_id, plan_version, approved, report,
            f"approved {ticket_id} body",
        )
        if evidence is not None:
            expectations[ticket_id] = evidence
    expected_ids = {root_id, *current_tickets}
    if set(expectations) != expected_ids:
        report.error("approved body rendering must exactly cover root and tickets")
        return None
    if set(titles) != expected_ids:
        report.error("approved title rendering must exactly cover root and tickets")
        return None
    return ApprovedIssueExpectations(expectations, titles) if documents_frozen else None


def _tickets(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list):
        return {}
    return {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _frozen_planning_fields(data: dict[str, Any]) -> dict[str, Any]:
    frozen = deepcopy(data)
    frozen.pop("github_root", None)
    frozen.pop("github_reconciliation", None)
    for ticket in frozen.get("tickets", []):
        if isinstance(ticket, dict):
            ticket.pop("github", None)
    return frozen


def _document_title(source: str, label: str, report: Report) -> str | None:
    lines = source.splitlines()
    first_line = lines[0] if lines else ""
    if not first_line.startswith("# ") or not first_line[2:].strip():
        report.error(f"{label} must start with one non-empty H1 issue title")
        return None
    return first_line[2:].strip()


def _current_matches(
    root: Path, path: str, expected: str, label: str, report: Report,
) -> bool:
    source = _read_current(root, path, label, report)
    if source is None:
        return False
    if source != expected.encode("utf-8"):
        report.error(f"{label} must exactly match its approved source")
        return False
    return True


def _read_current(root: Path, path: str, label: str, report: Report) -> bytes | None:
    candidate = root.joinpath(*PurePosixPath(path).parts)
    if not candidate.exists():
        report.error(f"{label} is absent")
        return None
    resolved = resolve_regular_file(root, path, label, report)
    if resolved is None:
        return None
    try:
        source = resolved.read_bytes()
        source.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        report.error(f"{label} must be readable UTF-8: {exc}")
        return None
    return source
