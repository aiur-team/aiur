"""Load and validate publication authority from an immutable receipt commit."""

from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from publication_common import SHA, Report
from publication_rendering import exact_commit, repository_root


PACK_ROOT = PurePosixPath("docs/build-order")
MANIFEST_NAMES = (
    "build-order.json",
    "dashboard-companions.json",
    "publication.json",
)
REGULAR_MODES = {b"100644", b"100755"}


@dataclass(frozen=True)
class ReceiptAuthority:
    repository: str
    root_id: str
    plan_version: int
    approved_commit: str
    root_issue_url: str


def load_receipt_authority(
    receipt_commit: str,
    repository_anchor: Path,
    report: Report,
) -> ReceiptAuthority | None:
    """Validate exact receipt bytes with current trusted validation code."""
    validation = Report()
    root = _source_root(repository_anchor, validation)
    if root is None or not exact_commit(
        root, receipt_commit, "receipt_commit", validation
    ):
        _merge(validation, report)
        return None

    snapshot = _snapshot_blobs(root, receipt_commit, validation)
    if snapshot is None:
        _merge(validation, report)
        return None
    manifests, blobs = snapshot
    _require_materialized_receipts(manifests, validation)
    if validation.errors:
        _merge(validation, report)
        return None

    with tempfile.TemporaryDirectory() as temp_name:
        clone = Path(temp_name) / "receipt"
        if not _clone_without_checkout(root, clone, validation):
            _merge(validation, report)
            return None
        _write_snapshot(clone, blobs, validation)
        if not validation.errors:
            _validate_with_trusted_code(clone, validation)

    authority = None
    if not validation.errors and not validation.warnings:
        authority = _derive_authority(manifests, root, validation)
    _merge(validation, report)
    return authority if not validation.errors and not validation.warnings else None


def _source_root(anchor: Path, report: Report) -> Path | None:
    probe = anchor / ".receipt-authority-anchor" if anchor.is_dir() else anchor
    return repository_root(probe, report)


def _snapshot_blobs(
    root: Path, receipt_commit: str, report: Report,
) -> tuple[dict[str, dict[str, Any]], dict[str, bytes]] | None:
    manifests: dict[str, dict[str, Any]] = {}
    blobs: dict[str, bytes] = {}
    for name in MANIFEST_NAMES:
        path = (PACK_ROOT / name).as_posix()
        raw = _commit_blob(root, receipt_commit, path, f"receipt {name}", report)
        if raw is None:
            continue
        blobs[path] = raw
        value = _json_object(raw, f"receipt {name}", report)
        if value is not None:
            manifests[name] = value
    if set(manifests) != set(MANIFEST_NAMES):
        return None

    reserved = {path.casefold(): path for path in blobs}
    for label, relative in _document_references(manifests):
        safe = _safe_relative_path(relative, label, report)
        if safe is None:
            continue
        path = (PACK_ROOT / PurePosixPath(safe)).as_posix()
        folded = path.casefold()
        if folded in reserved:
            report.error(
                f"{label} collides with reserved receipt path {reserved[folded]}"
            )
            continue
        raw = _commit_blob(root, receipt_commit, path, label, report)
        if raw is not None:
            blobs[path] = raw
            reserved[folded] = path
    return manifests, blobs


def _document_references(
    manifests: dict[str, dict[str, Any]],
) -> list[tuple[str, object]]:
    references: list[tuple[str, object]] = []
    for manifest_name in ("build-order.json", "dashboard-companions.json"):
        tickets = manifests[manifest_name].get("tickets")
        if not isinstance(tickets, list):
            continue
        for index, ticket in enumerate(tickets):
            if isinstance(ticket, dict):
                ticket_id = ticket.get("id", index)
                references.append(
                    (f"receipt document for {ticket_id}", ticket.get("document"))
                )
    publication = manifests["publication.json"]
    for key in ("root_issue", "skill_issue"):
        issue = publication.get(key)
        if isinstance(issue, dict):
            references.append(
                (f"receipt document for {key}", issue.get("document"))
            )
    return references


def _safe_relative_path(value: object, label: str, report: Report) -> str | None:
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
        or any(part.casefold() == ".git" for part in path.parts)
    ):
        report.error(f"{label} must be a safe repository-relative path")
        return None
    return normalized


def _commit_blob(
    root: Path, commit: str, path: str, label: str, report: Report,
) -> bytes | None:
    entry = subprocess.run(
        ["git", "-C", str(root), "ls-tree", "-z", commit, "--", path],
        check=False,
        capture_output=True,
    )
    if entry.returncode or not _regular_tree_entry(entry.stdout, path):
        report.error(f"{label} must be a regular file at {path}")
        return None
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{commit}:{path}"],
        check=False,
        capture_output=True,
    )
    if result.returncode:
        report.error(f"{label} is absent from receipt commit at {path}")
        return None
    return result.stdout


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
        and fields[0] in REGULAR_MODES
        and fields[1] == b"blob"
        and decoded_name == path
    )


def _json_object(raw: bytes, label: str, report: Report) -> dict[str, Any] | None:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        report.error(f"{label} must be valid UTF-8 JSON: {exc}")
        return None
    if not isinstance(value, dict):
        report.error(f"{label} must be a JSON object")
        return None
    return value


def _require_materialized_receipts(
    manifests: dict[str, dict[str, Any]], report: Report,
) -> None:
    for name in MANIFEST_NAMES:
        if not isinstance(manifests[name].get("github_reconciliation"), dict):
            report.error(
                f"receipt commit {name} github_reconciliation must be materialized"
            )


def _clone_without_checkout(root: Path, destination: Path, report: Report) -> bool:
    result = subprocess.run(
        [
            "git", "clone", "--quiet", "--shared", "--no-checkout", "--",
            str(root), str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        report.error(f"cannot create no-checkout receipt snapshot: {detail}")
        return False
    return True


def _write_snapshot(root: Path, blobs: dict[str, bytes], report: Report) -> None:
    for path, raw in blobs.items():
        target = root.joinpath(*PurePosixPath(path).parts)
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        except OSError as exc:
            report.error(f"cannot materialize receipt snapshot {path}: {exc}")


def _validate_with_trusted_code(root: Path, report: Report) -> None:
    # Function-local import avoids publication_comment -> validator -> comment cycles.
    from validate_publication import validate

    pack = root.joinpath(*PACK_ROOT.parts)
    result = validate(
        pack / "dashboard-companions.json",
        pack / "build-order.json",
        pack / "publication.json",
    )
    for error in result.errors:
        report.error(f"receipt commit validation: {error}")
    for warning in result.warnings:
        report.error(f"receipt commit validation warning: {warning}")


def _derive_authority(
    manifests: dict[str, dict[str, Any]], root: Path, report: Report,
) -> ReceiptAuthority | None:
    build = manifests["build-order.json"]
    companions = manifests["dashboard-companions.json"]
    repository = companions.get("repository")
    root_id = build.get("build_order_id")
    plan_version = companions.get("plan_version")
    approved = companions.get("approved_planning_commit")
    github_root = build.get("github_root")
    root_url = github_root.get("url") if isinstance(github_root, dict) else None
    if not isinstance(repository, str):
        report.error("validated receipt repository is unavailable")
    if not isinstance(root_id, str):
        report.error("validated receipt root ID is unavailable")
    if type(plan_version) is not int:
        report.error("validated receipt plan version is unavailable")
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("validated receipt approval commit is unavailable")
    elif not exact_commit(root, approved, "approved_planning_commit", report):
        pass
    if not isinstance(root_url, str):
        report.error("validated receipt root issue URL is unavailable")
    if report.errors:
        return None
    assert isinstance(repository, str)
    assert isinstance(root_id, str)
    assert type(plan_version) is int
    assert isinstance(approved, str)
    assert isinstance(root_url, str)
    return ReceiptAuthority(
        repository=repository,
        root_id=root_id,
        plan_version=plan_version,
        approved_commit=approved,
        root_issue_url=root_url,
    )


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.errors.extend(
        f"receipt authority warning: {warning}" for warning in source.warnings
    )
