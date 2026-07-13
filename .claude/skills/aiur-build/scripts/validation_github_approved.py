"""Load canonical body sources from an immutable approved planning commit."""

from __future__ import annotations

import json
import subprocess
from copy import deepcopy
from pathlib import Path, PurePosixPath
from typing import Any

from validation_common import SHA, Report, git_no_replace_env
from validation_github_rendering import (
    inspect_issue_body,
    render_template_body,
    render_ticket_body,
)


def render_approved_build_order(
    repository_root: Path,
    approved: object,
    build_order_path: str,
    root_document_path: str,
    current: dict[str, Any],
    report: Report,
) -> dict[str, dict[str, Any]] | None:
    """Render approved bodies and enforce the current document freeze."""
    root = repository_root.resolve()
    if not _exact_commit(root, approved, report):
        return None
    build_path = _safe_path(build_order_path, "approved build-order path", report)
    root_path = _safe_path(root_document_path, "approved root document path", report)
    if build_path is None or root_path is None or not isinstance(approved, str):
        return None
    raw = _git_show(root, approved, build_path, "approved build-order", report)
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
    documents_frozen = True
    root_source = _git_show(root, approved, root_path, "approved root document", report)
    if root_source is not None:
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
        relative = _safe_path(document, f"approved {ticket_id}.document", report)
        if relative is None:
            continue
        source_path = str(pack_dir / PurePosixPath(relative))
        source = _git_show(root, approved, source_path, f"approved {ticket_id} document", report)
        if source is None:
            continue
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
    return expectations if documents_frozen else None


def repository_relative(path: Path, repository_root: Path, report: Report) -> str | None:
    try:
        return path.resolve().relative_to(repository_root.resolve()).as_posix()
    except ValueError:
        report.error("build-order path must resolve within the approved repository")
        return None


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


def _safe_path(value: object, label: str, report: Report) -> str | None:
    if not isinstance(value, str) or not value:
        report.error(f"{label} must be a non-empty repository-relative path")
        return None
    path = PurePosixPath(value)
    normalized = path.as_posix()
    if (
        path.is_absolute()
        or ".." in path.parts
        or normalized == "."
        or normalized != value
        or "\x00" in value
    ):
        report.error(f"{label} must be a safe repository-relative path")
        return None
    return normalized


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
    candidate = root
    for part in PurePosixPath(path).parts:
        candidate /= part
        if candidate.is_symlink():
            report.error(f"{label} must not be a symlink")
            return None
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
    except FileNotFoundError:
        report.error(f"{label} is absent from the current planning pack at {path}")
        return None
    except (OSError, ValueError) as exc:
        report.error(f"{label} must resolve within the current repository: {exc}")
        return None
    if not resolved.is_file():
        report.error(f"{label} must be a regular file at {path}")
        return None
    try:
        source = resolved.read_bytes()
        source.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        report.error(f"{label} must be readable UTF-8: {exc}")
        return None
    return source


def _exact_commit(root: Path, approved: object, report: Report) -> bool:
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("approved planning commit must be a 40-character Git SHA")
        return False
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{approved}^{{commit}}"],
        check=False, capture_output=True, text=True, env=git_no_replace_env(),
    )
    if result.returncode or result.stdout.strip().lower() != approved.lower():
        report.error("approved planning commit must resolve to an exact commit")
        return False
    return True


def _git_show(
    root: Path, approved: str, path: str, label: str, report: Report,
) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{approved}:{path}"],
        check=False, capture_output=True, env=git_no_replace_env(),
    )
    if result.returncode:
        report.error(f"{label} is absent from approved commit at {path}")
        return None
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        report.error(f"{label} must be UTF-8: {exc}")
        return None
