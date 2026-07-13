"""Render every published issue body from the immutable approved commit."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from copy import deepcopy
from pathlib import Path, PurePosixPath
from typing import Any

from publication_common import SHA, Report, strict_object


MARKER_NAME = "aiur-planning-issue"
MARKER_KEYS = {
    "schema", "logical_id", "plan_version", "approved_planning_commit",
}
EVIDENCE_KEYS = {
    "marker_count",
    "marker_schema_version",
    "marker_logical_id",
    "marker_plan_version",
    "approved_planning_commit",
    "approved_link_count",
    "approved_link",
    "body_sha256",
}
BODY_SHA = re.compile(r"^[0-9a-f]{64}$", re.ASCII)
COMMIT_LINK = re.compile(
    r"https://github\.com/[^/\s)]+/[^/\s)]+/commit/[0-9a-fA-F]{40}",
    re.ASCII,
)
MARKER = re.compile(
    r"<!-- aiur-planning-issue[ \t]*\n(?P<payload>[^\n]*)\n-->",
    re.ASCII,
)


def run_authority_git(
    args: list[str], **kwargs: Any,
) -> subprocess.CompletedProcess[Any]:
    """Run an authority-bearing Git read without honoring replace refs."""
    configured = kwargs.pop("env", None)
    env = os.environ.copy() if configured is None else dict(configured)
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    return subprocess.run(args, env=env, **kwargs)


def approved_link(repository: str, approved: str) -> str:
    return f"https://github.com/{repository}/commit/{approved}"


def authority_preamble(
    repository: str, logical_id: str, plan_version: int, approved: str,
) -> str:
    marker = json.dumps(
        {
            "schema": 2,
            "logical_id": logical_id,
            "plan_version": plan_version,
            "approved_planning_commit": approved,
        },
        separators=(",", ":"),
    )
    return (
        f"> Approved planning authority: [`{approved}`]"
        f"({approved_link(repository, approved)})\n\n"
        f"<!-- {MARKER_NAME}\n{marker}\n-->\n\n"
    )


def inspect_issue_body(
    body: object, repository: str, logical_id: str, plan_version: int,
    approved: str, report: Report, label: str,
) -> dict[str, Any] | None:
    if not isinstance(body, str):
        report.error(f"{label} must be UTF-8 text")
        return None
    marker_count = body.count(f"<!-- {MARKER_NAME}")
    matches = list(MARKER.finditer(body))
    if marker_count != 1 or len(matches) != 1:
        report.error(f"{label} must contain exactly one schema-2 {MARKER_NAME} marker")
        return None
    try:
        payload = json.loads(matches[0].group("payload"))
    except json.JSONDecodeError as exc:
        report.error(f"{label} marker must contain valid one-line JSON: {exc}")
        return None
    marker = strict_object(payload, f"{label} marker", MARKER_KEYS, report)
    if marker is None:
        return None
    expected_marker = {
        "schema": 2,
        "logical_id": logical_id,
        "plan_version": plan_version,
        "approved_planning_commit": approved,
    }
    valid = True
    for key, expected in expected_marker.items():
        if marker.get(key) != expected:
            report.error(f"{label} marker {key} must equal {expected}")
            valid = False
    links = COMMIT_LINK.findall(body)
    expected_link = approved_link(repository, approved)
    if len(links) != 1:
        report.error(f"{label} must contain exactly one approved commit link")
        valid = False
    elif links[0] != expected_link:
        report.error(f"{label} approved link must equal {expected_link}")
        valid = False
    if not valid:
        return None
    return {
        "marker_count": 1,
        "marker_schema_version": 2,
        "marker_logical_id": logical_id,
        "marker_plan_version": plan_version,
        "approved_planning_commit": approved,
        "approved_link_count": 1,
        "approved_link": expected_link,
        "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    }


def render_approved_pack(
    build: dict[str, Any], companions: dict[str, Any], publication: dict[str, Any],
    build_path: Path, companion_path: Path, publication_path: Path,
    approved: object, report: Report,
) -> dict[str, dict[str, Any]] | None:
    """Use only ``git show <approval>:<path>`` to derive all published bodies."""
    root = repository_root(build_path, report)
    if root is None or not exact_commit(root, approved, "approved_planning_commit", report):
        return None
    if not isinstance(approved, str):
        return None
    current_paths = (build_path, companion_path, publication_path)
    relative_paths = [repository_relative(path, root, report) for path in current_paths]
    if any(path is None for path in relative_paths):
        return None
    approved_build = _approved_json(root, approved, relative_paths[0], "build-order", report)
    approved_companions = _approved_json(
        root, approved, relative_paths[1], "dashboard-companions", report
    )
    approved_publication = _approved_json(
        root, approved, relative_paths[2], "publication", report
    )
    if any(value is None for value in (
        approved_build, approved_companions, approved_publication,
    )):
        return None
    assert approved_build is not None
    assert approved_companions is not None
    assert approved_publication is not None
    frozen_packs = (
        ("build-order", approved_build, build, "build"),
        ("companion", approved_companions, companions, "companion"),
        ("publication", approved_publication, publication, "publication"),
    )
    for label, approved_pack, current_pack, family in frozen_packs:
        if _frozen_planning_fields(approved_pack, family) != _frozen_planning_fields(
            current_pack, family
        ):
            report.error(
                f"materialized {label} planning fields must equal the approved commit"
            )
            return None
    repository = companions.get("repository")
    plan_version = companions.get("plan_version")
    root_id = build.get("build_order_id")
    skill = publication.get("skill_issue")
    skill_id = skill.get("logical_id") if isinstance(skill, dict) else None
    if not isinstance(repository, str) or type(plan_version) is not int:
        report.error("materialized pack identity is unavailable for body rendering")
        return None
    if not isinstance(root_id, str) or not isinstance(skill_id, str):
        report.error("materialized root and skill identities are required for body rendering")
        return None
    _same_header(approved_build, build, ("repository", "plan_version", "build_order_id"), "build-order", report)
    _same_header(approved_companions, companions, ("repository", "plan_version"), "companions", report)
    _same_header(approved_publication, publication, ("repository", "plan_version"), "publication", report)
    current_bo, approved_bo = _tickets(build), _tickets(approved_build)
    current_dash, approved_dash = _tickets(companions), _tickets(approved_companions)
    if set(current_bo) != set(approved_bo):
        report.error("approved build-order ticket IDs must match the materialized pack")
    if set(current_dash) != set(approved_dash):
        report.error("approved companion ticket IDs must match the materialized pack")
    approved_root = approved_publication.get("root_issue")
    approved_skill = approved_publication.get("skill_issue")
    if not isinstance(approved_root, dict) or approved_root.get("logical_id") != root_id:
        report.error("approved publication root identity must match the materialized pack")
    if not isinstance(approved_skill, dict) or approved_skill.get("logical_id") != skill_id:
        report.error("approved publication skill identity must match the materialized pack")
    expectations: dict[str, dict[str, Any]] = {}
    _render_template(
        expectations, root, approved, PurePosixPath(relative_paths[2]).parent,
        approved_root, publication.get("root_issue"), publication_path.parent,
        root_id, repository, plan_version, "approved root", report,
    )
    _render_template(
        expectations, root, approved, PurePosixPath(relative_paths[2]).parent,
        approved_skill, publication.get("skill_issue"), publication_path.parent,
        skill_id, repository, plan_version, "approved skill", report,
    )
    _render_tickets(
        expectations, root, approved, PurePosixPath(relative_paths[0]).parent,
        approved_bo, current_bo, build_path.parent,
        repository, plan_version, "BO", report,
    )
    _render_tickets(
        expectations, root, approved, PurePosixPath(relative_paths[1]).parent,
        approved_dash, current_dash, companion_path.parent,
        repository, plan_version, "DASH", report,
    )
    expected_ids = {root_id, skill_id, *current_bo, *current_dash}
    if set(expectations) != expected_ids:
        report.error("approved body rendering must exactly cover root, BO, DASH, and skill issues")
        return None
    return expectations


def repository_root(path: Path, report: Report) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(path.resolve().parent), "rev-parse", "--show-toplevel"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode:
        report.error("publication pack must resolve within a Git repository")
        return None
    return Path(result.stdout.strip()).resolve()


def repository_relative(path: Path, root: Path, report: Report) -> str | None:
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        report.error(f"publication path must resolve within approved repository: {path}")
        return None


def exact_commit(root: Path, value: object, label: str, report: Report) -> bool:
    if not isinstance(value, str) or not SHA.fullmatch(value):
        return False
    result = run_authority_git(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{value}^{{commit}}"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode or result.stdout.strip().lower() != value.lower():
        report.error(f"{label} must resolve to an exact commit in this repository")
        return False
    return True


def _approved_json(
    root: Path, approved: str, path: str, label: str, report: Report,
) -> dict[str, Any] | None:
    text = _git_show(root, approved, path, f"approved {label}", report)
    if text is None:
        return None
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        report.error(f"approved {label} must be valid JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error(f"approved {label} must be a JSON object")
        return None
    return value


def _render_tickets(
    output: dict[str, dict[str, Any]], root: Path, approved: str,
    pack_dir: PurePosixPath, tickets: dict[str, dict[str, Any]],
    current_tickets: dict[str, dict[str, Any]], current_base: Path,
    repository: str, plan_version: int, family: str, report: Report,
) -> None:
    for logical_id in sorted(tickets):
        ticket = tickets[logical_id]
        document = _safe_path(ticket.get("document"), f"approved {logical_id}.document", report)
        if document is None:
            continue
        source = _git_show(
            root, approved, str(pack_dir / PurePosixPath(document)),
            f"approved {logical_id} document", report,
        )
        if source is None:
            continue
        current_ticket = current_tickets.get(logical_id)
        current_document = (
            current_ticket.get("document") if isinstance(current_ticket, dict) else None
        )
        current_source = _current_document_bytes(
            current_base, current_document, f"current {logical_id} document", report
        )
        if current_source is None:
            continue
        if current_source != source.encode("utf-8"):
            report.error(
                f"current {logical_id} document must equal the approved source byte-for-byte"
            )
            continue
        body = authority_preamble(repository, logical_id, plan_version, approved) + source
        evidence = inspect_issue_body(
            body, repository, logical_id, plan_version, approved,
            report, f"approved {family} body {logical_id}",
        )
        if evidence is not None:
            output[logical_id] = evidence


def _render_template(
    output: dict[str, dict[str, Any]], root: Path, approved: str,
    pack_dir: PurePosixPath, issue: object,
    current_issue: object, current_base: Path, logical_id: str,
    repository: str, plan_version: int, label: str, report: Report,
) -> None:
    if not isinstance(issue, dict):
        return
    document = _safe_path(issue.get("document"), f"{label}.document", report)
    if document is None:
        return
    template = _git_show(
        root, approved, str(pack_dir / PurePosixPath(document)),
        f"{label} document", report,
    )
    if template is None:
        return
    if "<APPROVED_SHA>" not in template:
        report.error(f"{label} document must contain <APPROVED_SHA>")
        return
    body = template.replace("<APPROVED_SHA>", approved)
    current_document = (
        current_issue.get("document") if isinstance(current_issue, dict) else None
    )
    current_source = _current_document_bytes(
        current_base, current_document, f"current {label} document", report
    )
    if current_source is None:
        return
    if current_source != body.encode("utf-8"):
        report.error(
            f"current {label} document must equal the approved template after approval substitution"
        )
        return
    evidence = inspect_issue_body(
        body, repository, logical_id, plan_version, approved,
        report, f"{label} body",
    )
    if evidence is not None:
        output[logical_id] = evidence


def _same_header(
    approved: dict[str, Any], current: dict[str, Any], keys: tuple[str, ...],
    label: str, report: Report,
) -> None:
    for key in keys:
        if approved.get(key) != current.get(key):
            report.error(f"approved {label} {key} must match the materialized pack")


def _frozen_planning_fields(
    data: dict[str, Any], family: str,
) -> dict[str, Any]:
    frozen = deepcopy(data)
    frozen.pop("github_reconciliation", None)
    if family == "build":
        frozen.pop("github_root", None)
    if family in {"companion", "publication"}:
        frozen.pop("approved_planning_commit", None)
    if family in {"build", "companion"}:
        for ticket in frozen.get("tickets", []):
            if isinstance(ticket, dict):
                ticket.pop("github", None)
    return frozen


def _tickets(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list):
        return {}
    return {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


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


def _current_document_bytes(
    base: Path, value: object, label: str, report: Report,
) -> bytes | None:
    relative = _safe_path(value, label, report)
    if relative is None:
        return None
    candidate = base.joinpath(*PurePosixPath(relative).parts)
    try:
        resolved_base = base.resolve(strict=True)
        cursor = base
        for part in PurePosixPath(relative).parts:
            cursor /= part
            if cursor.is_symlink():
                report.error(f"{label} must be a regular non-symlink file")
                return None
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        report.error(f"{label} does not resolve: {exc}")
        return None
    if not resolved.is_relative_to(resolved_base) or not resolved.is_file():
        report.error(f"{label} must resolve within its planning pack")
        return None
    try:
        return resolved.read_bytes()
    except OSError as exc:
        report.error(f"{label} cannot be read: {exc}")
        return None


def _git_show(
    root: Path, approved: str, path: str, label: str, report: Report,
) -> str | None:
    entry = run_authority_git(
        ["git", "-C", str(root), "ls-tree", "-z", approved, "--", path],
        check=False, capture_output=True,
    )
    if entry.returncode or not entry.stdout:
        report.error(f"{label} is absent from approved commit at {path}")
        return None
    if not _regular_tree_entry(entry.stdout, path):
        report.error(f"{label} must be a regular non-symlink file at {path}")
        return None
    result = run_authority_git(
        ["git", "-C", str(root), "show", f"{approved}:{path}"],
        check=False, capture_output=True,
    )
    if result.returncode:
        report.error(f"{label} is absent from approved commit at {path}")
        return None
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        report.error(f"{label} must be UTF-8: {exc}")
        return None


def _regular_tree_entry(raw: bytes, path: str) -> bool:
    entries = [item for item in raw.split(b"\0") if item]
    if len(entries) != 1 or b"\t" not in entries[0]:
        return False
    metadata, name = entries[0].split(b"\t", 1)
    fields = metadata.split()
    try:
        decoded_name = name.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return (
        len(fields) == 3
        and fields[0] in {b"100644", b"100755"}
        and fields[1] == b"blob"
        and decoded_name == path
    )
