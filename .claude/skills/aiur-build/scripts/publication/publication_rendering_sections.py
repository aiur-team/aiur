"""Section renderers and approved-source readers for Build Order issue bodies."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from copy import deepcopy
from pathlib import Path, PurePosixPath
from typing import Any

from publication_common import Report, SHA, strict_object, valid_issue_title
from publication_body_limits import MAX_ISSUE_BODY_CHARACTERS
from publication_paths import safe_repository_relative


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


AUTHORITY_GIT_TIMEOUT_SECONDS = 30


def run_authority_git(
    args: list[str], **kwargs: Any,
) -> subprocess.CompletedProcess[Any]:
    """Run an authority-bearing Git read without honoring replace refs."""
    configured = kwargs.pop("env", None)
    env = os.environ.copy() if configured is None else dict(configured)
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    kwargs.setdefault("timeout", AUTHORITY_GIT_TIMEOUT_SECONDS)
    try:
        return subprocess.run(args, env=env, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as exc:
        text = bool(kwargs.get("text"))
        empty = "" if text else b""
        detail = str(exc) if text else str(exc).encode()
        return subprocess.CompletedProcess(args, 124, empty, detail)


def reject_legacy_grafts(root: Path, report: Report) -> bool:
    """Reject graft files in both the worktree Git dir and common Git dir.

    ``GIT_NO_REPLACE_OBJECTS`` does not disable the legacy ``info/grafts``
    mechanism.  Presence is forbidden regardless of file type or contents;
    using ``lstat`` also makes symlinks, broken symlinks, directories, and
    other non-regular entries fail closed without opening them.
    """
    result = run_authority_git(
        [
            "git", "-C", str(root), "rev-parse", "--git-dir",
            "--git-common-dir",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    directories = result.stdout.splitlines() if result.returncode == 0 else []
    if len(directories) != 2 or not all(directories):
        report.error("cannot resolve Git worktree and common directories for graft audit")
        return False
    clean = True
    checked: set[Path] = set()
    for raw in directories:
        directory = Path(raw)
        if not directory.is_absolute():
            directory = Path(os.path.abspath(root / directory))
        graft = directory / "info" / "grafts"
        if graft in checked:
            continue
        checked.add(graft)
        try:
            graft.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            report.error(f"cannot establish absence of legacy Git graft file {graft}: {exc}")
            clean = False
        else:
            report.error(f"legacy Git graft authority is forbidden: {graft}")
            clean = False
    return clean


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
    if len(body) > MAX_ISSUE_BODY_CHARACTERS:
        report.warn(
            f"{logical_id} rendered issue body is {len(body):,} characters, "
            f"exceeding GitHub's {MAX_ISSUE_BODY_CHARACTERS:,}-character "
            f"issue body limit by {len(body) - MAX_ISSUE_BODY_CHARACTERS:,}"
        )
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


def _approved_content_titles(
    root: Path, approved: str, build_dir: PurePosixPath,
    publication_dir: PurePosixPath, build: dict[str, Any],
    publication: dict[str, Any], report: Report,
) -> dict[str, str]:
    titles: dict[str, str] = {}
    _approved_ticket_titles(
        titles, root, approved, build_dir, build, "ticket", report,
    )
    for key in ("root_issue", "skill_issue"):
        issue = publication.get(key)
        if not isinstance(issue, dict):
            report.error(f"approved publication {key} must be an object")
            continue
        _approved_document_title(
            titles, root, approved, publication_dir, issue.get("logical_id"),
            issue.get("document"), None, f"approved publication {key}", report,
        )
    return titles


def _approved_ticket_titles(
    output: dict[str, str], root: Path, approved: str, pack_dir: PurePosixPath,
    data: dict[str, Any], family: str, report: Report,
) -> None:
    tickets = data.get("tickets")
    if not isinstance(tickets, list):
        report.error(f"approved {family} tickets must be an array")
        return
    for index, ticket in enumerate(tickets):
        label = f"approved {family} tickets[{index}]"
        if not isinstance(ticket, dict):
            report.error(f"{label} must be an object")
            continue
        logical_id = ticket.get("id")
        manifest_title = ticket.get("title")
        expected = (
            f"BO: {logical_id} — {manifest_title}"
            if isinstance(logical_id, str) and valid_issue_title(manifest_title)
            else None
        )
        _approved_document_title(
            output, root, approved, pack_dir, logical_id,
            ticket.get("document"), expected, label, report,
        )


def _approved_document_title(
    output: dict[str, str], root: Path, approved: str, pack_dir: PurePosixPath,
    logical_id: object, document: object, expected: str | None, label: str,
    report: Report,
) -> None:
    if not isinstance(logical_id, str) or not logical_id:
        report.error(f"{label} logical ID must be a non-empty string")
        return
    if logical_id in output:
        report.error(f"approved title rendering duplicates logical ID {logical_id}")
        return
    safe_document = safe_repository_relative(
        document, f"{label}.document", report,
    )
    if safe_document is None:
        return
    source = _git_show(
        root, approved, str(pack_dir / PurePosixPath(safe_document)),
        f"{label} document", report,
    )
    if source is None:
        return
    lines = source.splitlines()
    title = lines[0].removeprefix("# ") if lines and lines[0].startswith("# ") else None
    if not valid_issue_title(title):
        report.error(
            f"{label} approved document H1 must be a valid GitHub issue title"
        )
        return
    if expected is not None and title != expected:
        report.error(
            f"{label} approved document H1 must equal '# {expected}'"
        )
        return
    assert isinstance(title, str)
    output[logical_id] = title


def repository_root(path: Path, report: Report) -> Path | None:
    result = run_authority_git(
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


def _frozen_planning_fields(
    data: dict[str, Any], family: str,
) -> dict[str, Any]:
    frozen = deepcopy(data)
    frozen.pop("github_reconciliation", None)
    if family == "build":
        frozen.pop("github_root", None)
        for ticket in frozen.get("tickets", []):
            if isinstance(ticket, dict):
                ticket.pop("github", None)
    if family == "publication":
        frozen.pop("approved_planning_commit", None)
    return frozen


def _tickets(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = data.get("tickets")
    if not isinstance(values, list):
        return {}
    return {
        item["id"]: item for item in values
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _current_document_bytes(
    base: Path, value: object, label: str, report: Report,
) -> bytes | None:
    relative = safe_repository_relative(value, label, report)
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
