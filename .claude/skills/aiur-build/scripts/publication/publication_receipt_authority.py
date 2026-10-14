"""Load and validate publication authority from an immutable receipt commit."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from publication_common import SHA, Report, valid_trusted_branch_ref
from publication_paths import safe_repository_relative
from publication_rendering import (
    exact_commit,
    reject_legacy_grafts,
    repository_root,
    run_authority_git,
)
from publication_receipt_derivation import (
    _derive_authority,
    _document_references,
    _json_object,
    MANIFEST_NAMES,
    _merge,
    ReceiptAuthority,
    RemoteRefContainmentChecker,
    _require_materialized_receipts,
    _require_remote_ref_containment,
)


PACK_ROOT = PurePosixPath("docs/build-order")
REGULAR_MODES = {b"100644", b"100755"}
MAX_RECEIPT_FILES = 512
MAX_RECEIPT_FILE_BYTES = 2 * 1024 * 1024
MAX_RECEIPT_BYTES = 32 * 1024 * 1024
GITHUB_REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)
GITHUB_TIMEOUT_SECONDS = 30
@dataclass
class ReceiptBlobBudget:
    files_remaining: int = MAX_RECEIPT_FILES
    bytes_remaining: int = MAX_RECEIPT_BYTES

    def reserve_file(self, label: str, report: Report) -> bool:
        if self.files_remaining <= 0:
            report.error("receipt snapshot exceeds file-count bound")
            return False
        self.files_remaining -= 1
        return True

    def reserve_bytes(self, size: int, label: str, report: Report) -> bool:
        if size > MAX_RECEIPT_FILE_BYTES:
            report.error(f"{label} exceeds per-file byte bound")
            return False
        if size > self.bytes_remaining:
            report.error("receipt snapshot exceeds aggregate byte bound")
            return False
        self.bytes_remaining -= size
        return True


def load_receipt_authority(
    receipt_commit: str,
    repository_anchor: Path,
    report: Report,
    remote_ref_contains: RemoteRefContainmentChecker | None = None,
) -> ReceiptAuthority | None:
    """Validate exact receipt bytes with current trusted validation code."""
    validation = Report()
    root = _source_root(repository_anchor, validation)
    if root is None or not exact_commit(
        root, receipt_commit, "receipt_commit", validation
    ):
        _merge(validation, report)
        return None
    if not reject_legacy_grafts(root, validation):
        _merge(validation, report)
        return None
    trusted_repository = _github_origin_repository(root, validation)
    if trusted_repository is None:
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

    authority = None
    with tempfile.TemporaryDirectory() as temp_name:
        clone = Path(temp_name) / "receipt"
        if not _clone_without_checkout(root, clone, validation):
            _merge(validation, report)
            return None
        _write_snapshot(clone, blobs, validation)
        if not validation.errors:
            _validate_with_trusted_code(clone, validation)
        if not validation.errors and not validation.warnings:
            authority = _derive_authority(
                manifests, clone, trusted_repository, validation
            )
        if (
            authority is not None
            and not validation.errors
            and not validation.warnings
            and reject_legacy_grafts(clone, validation)
        ):
            # The shared no-checkout clone deliberately has no source
            # ``info/grafts`` file, so this local consistency check cannot be
            # rewritten by a legacy graft racing in the source repository.
            _require_local_receipt_order(
                clone, authority.approved_commit, receipt_commit, validation
            )
    if authority is not None and not validation.errors and not validation.warnings:
        _require_remote_ref_containment(
            authority, receipt_commit,
            remote_ref_contains or _github_repository_ref_contains,
            validation,
        )
    # Detect a graft introduced after the initial audit.  A file that races
    # only during validation still cannot authorize history: local ancestry is
    # checked in the clean clone and approval->receipt is proved by GitHub.
    reject_legacy_grafts(root, validation)
    _merge(validation, report)
    return authority if not validation.errors and not validation.warnings else None


def _source_root(anchor: Path, report: Report) -> Path | None:
    probe = anchor / ".receipt-authority-anchor" if anchor.is_dir() else anchor
    return repository_root(probe, report)


def _github_origin_repository(root: Path, report: Report) -> str | None:
    result = run_authority_git(
        ["git", "-C", str(root), "remote", "get-url", "origin"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        report.error("receipt authority requires a configured GitHub origin")
        return None
    url = result.stdout.strip().rstrip("/")
    if url.endswith(".git"):
        url = url[:-4]
    repository = None
    for prefix in (
        "https://github.com/",
        "git@github.com:",
        "ssh://git@github.com/",
    ):
        if url.startswith(prefix):
            repository = url[len(prefix):]
            break
    if repository is None or not GITHUB_REPOSITORY.fullmatch(repository):
        report.error("receipt authority origin must identify one GitHub repository")
        return None
    return repository


def _snapshot_blobs(
    root: Path, receipt_commit: str, report: Report,
) -> tuple[dict[str, dict[str, Any]], dict[str, bytes]] | None:
    manifests: dict[str, dict[str, Any]] = {}
    blobs: dict[str, bytes] = {}
    budget = ReceiptBlobBudget()
    for name in MANIFEST_NAMES:
        path = (PACK_ROOT / name).as_posix()
        raw = _commit_blob(
            root, receipt_commit, path, f"receipt {name}", budget, report,
        )
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
        safe = safe_repository_relative(relative, label, report)
        if safe is None:
            continue
        path = (PACK_ROOT / PurePosixPath(safe)).as_posix()
        folded = path.casefold()
        if folded in reserved:
            report.error(
                f"{label} collides with reserved receipt path {reserved[folded]}"
            )
            continue
        raw = _commit_blob(root, receipt_commit, path, label, budget, report)
        if raw is not None:
            blobs[path] = raw
            reserved[folded] = path
    return manifests, blobs


def _commit_blob(
    root: Path, commit: str, path: str, label: str,
    budget: ReceiptBlobBudget, report: Report,
) -> bytes | None:
    if not budget.reserve_file(label, report):
        return None
    entry = run_authority_git(
        ["git", "-C", str(root), "ls-tree", "-z", commit, "--", path],
        check=False,
        capture_output=True,
    )
    if entry.returncode or not _regular_tree_entry(entry.stdout, path):
        report.error(f"{label} must be a regular file at {path}")
        return None
    size = _commit_blob_size(root, commit, path, label, report)
    if size is None or not budget.reserve_bytes(size, label, report):
        return None
    result = run_authority_git(
        ["git", "-C", str(root), "show", f"{commit}:{path}"],
        check=False,
        capture_output=True,
    )
    if result.returncode:
        report.error(f"{label} is absent from receipt commit at {path}")
        return None
    if len(result.stdout) != size:
        report.error(f"{label} byte size changed during receipt read at {path}")
        return None
    return result.stdout


def _commit_blob_size(
    root: Path, commit: str, path: str, label: str, report: Report,
) -> int | None:
    result = run_authority_git(
        ["git", "-C", str(root), "cat-file", "-s", f"{commit}:{path}"],
        check=False, capture_output=True, text=True,
    )
    try:
        size = int(result.stdout.strip()) if result.returncode == 0 else -1
    except ValueError:
        size = -1
    if size < 0:
        report.error(f"{label} byte size is unreadable at {path}")
        return None
    return size


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


def _clone_without_checkout(root: Path, destination: Path, report: Report) -> bool:
    result = run_authority_git(
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
        pack / "build-order.json",
        pack / "publication.json",
    )
    for error in result.errors:
        report.error(f"receipt commit validation: {error}")
    for warning in result.warnings:
        report.error(f"receipt commit validation warning: {warning}")


def _require_local_receipt_order(
    root: Path, approved_commit: str, receipt_commit: str, report: Report,
) -> None:
    result = run_authority_git(
        [
            "git", "-C", str(root), "merge-base", "--is-ancestor",
            approved_commit, receipt_commit,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        report.error(
            "receipt_commit must descend from approved_planning_commit in the "
            "no-substitution repository graph"
        )


def _github_repository_ref_contains(
    repository: str, trusted_ref: str,
    approved_commit: str, receipt_commit: str,
) -> bool:
    if not valid_trusted_branch_ref(trusted_ref):
        return False
    target_sha = _github_branch_target(repository, trusted_ref)
    commits = (approved_commit, receipt_commit)
    if target_sha is None or approved_commit == receipt_commit or not all(
        isinstance(commit, str) and bool(SHA.fullmatch(commit)) for commit in commits
    ):
        return False
    ordered = _github_compare_proves_ancestor(
        repository, approved_commit.lower(), receipt_commit.lower()
    )
    contained = all(
        _github_compare_proves_ancestor(repository, commit.lower(), target_sha)
        for commit in commits
    )
    # A force-push between the ref and compare reads must not produce a
    # self-consistent-looking receipt from two different remote snapshots.
    unchanged = _github_branch_target(repository, trusted_ref) == target_sha
    return ordered and contained and unchanged


def _github_branch_target(repository: str, trusted_ref: str) -> str | None:
    ref_payload = _github_json(
        f"repos/{repository}/git/ref/{trusted_ref.removeprefix('refs/')}"
    )
    if not isinstance(ref_payload, dict) or ref_payload.get("ref") != trusted_ref:
        return None
    target = ref_payload.get("object")
    if (
        not isinstance(target, dict)
        or target.get("type") != "commit"
        or not isinstance(target.get("sha"), str)
        or not SHA.fullmatch(target["sha"])
    ):
        return None
    return target["sha"].lower()


def _github_compare_proves_ancestor(
    repository: str, commit: str, target: str,
) -> bool:
    comparison = _github_json(f"repos/{repository}/compare/{commit}...{target}")
    if not isinstance(comparison, dict):
        return False
    base = comparison.get("base_commit")
    merge_base = comparison.get("merge_base_commit")
    base_sha = base.get("sha") if isinstance(base, dict) else None
    merge_base_sha = (
        merge_base.get("sha") if isinstance(merge_base, dict) else None
    )
    behind_by = comparison.get("behind_by")
    ahead_by = comparison.get("ahead_by")
    if (
        not isinstance(base, dict)
        or not isinstance(merge_base, dict)
        or not isinstance(base_sha, str)
        or not isinstance(merge_base_sha, str)
        or base_sha.lower() != commit
        or merge_base_sha.lower() != commit
        or type(behind_by) is not int
        or behind_by != 0
    ):
        return False
    status = comparison.get("status")
    if status == "identical":
        return type(ahead_by) is int and target == commit and ahead_by == 0
    return (
        status == "ahead"
        and target != commit
        and type(ahead_by) is int
        and ahead_by > 0
    )


def _github_json(endpoint: str) -> object | None:
    try:
        result = subprocess.run(
            [
                "gh", "api", "--hostname", "github.com",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10",
                "--method", "GET",
                endpoint,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=GITHUB_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


