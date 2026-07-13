"""Prove publication commits descend from an explicit GitHub-owned branch."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path, PurePosixPath
from typing import Callable, Optional

from validation_common import SHA, Report, git_no_replace_env


GITHUB_REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)
BranchTargetLoader = Callable[[Path, str, Report], Optional[str]]


def validate_publication_commit_authority(
    repository_root: Path,
    expected_repository: object,
    publication_manifest_path: str,
    approved_commit: object,
    receipt_commit: object,
    report: Report,
    branch_target_loader: BranchTargetLoader | None = None,
) -> None:
    """Load the immutable trusted ref, then prove both publication commits."""
    root = repository_root.resolve()
    trusted_ref = _frozen_trusted_ref(
        root, publication_manifest_path, approved_commit, receipt_commit, report
    )
    if trusted_ref is None:
        return
    _validate_trusted_repository_commits(
        root,
        expected_repository,
        trusted_ref,
        approved_commit,
        receipt_commit,
        report,
        branch_target_loader,
    )


def _validate_trusted_repository_commits(
    repository_root: Path,
    expected_repository: object,
    trusted_repository_ref: object,
    approved_commit: object,
    receipt_commit: object,
    report: Report,
    branch_target_loader: BranchTargetLoader | None = None,
) -> None:
    """Require approval and receipt commits to be ancestors of one remote branch."""
    root = repository_root.resolve()
    repository = _github_origin_repository(root, report)
    if repository is None:
        return
    if expected_repository != repository:
        report.error(
            "materialized repository must equal configured GitHub origin "
            f"{repository}"
        )
        return
    if not _valid_branch_ref(root, trusted_repository_ref, report):
        return
    assert isinstance(trusted_repository_ref, str)
    loader = branch_target_loader or _load_github_branch_target
    target = loader(
        root, trusted_repository_ref, report
    )
    if not isinstance(target, str) or not SHA.fullmatch(target):
        if target is not None:
            report.error("trusted_repository_ref must resolve to one exact Git commit")
        return
    if not _exact_commit(root, target):
        report.error("trusted_repository_ref target must resolve to an exact local commit")
        return
    exact_commits: dict[str, str] = {}
    for label, commit in (
        ("approved_planning_commit", approved_commit),
        ("receipt_commit", receipt_commit),
    ):
        if not isinstance(commit, str) or not SHA.fullmatch(commit):
            report.error(f"{label} must be a 40-character Git SHA")
            continue
        if not _exact_commit(root, commit):
            report.error(f"{label} must resolve to an exact commit")
            continue
        exact_commits[label] = commit
        result = _git(
            root, "merge-base", "--is-ancestor", commit, target,
            capture_output=True,
        )
        if result.returncode == 1:
            report.error(
                f"{label} must be reachable from trusted_repository_ref "
                f"{trusted_repository_ref}"
            )
        elif result.returncode != 0:
            report.error(f"cannot prove {label} reachability from trusted_repository_ref")
    approved = exact_commits.get("approved_planning_commit")
    receipt = exact_commits.get("receipt_commit")
    if approved is not None and receipt is not None:
        result = _git(
            root, "merge-base", "--is-ancestor", approved, receipt,
            capture_output=True,
        )
        if result.returncode == 1:
            report.error(
                "approved_planning_commit must be an ancestor of receipt_commit"
            )
        elif result.returncode != 0:
            report.error("cannot prove approval ancestry of receipt_commit")
    rechecked_target = loader(root, trusted_repository_ref, report)
    if rechecked_target != target:
        report.error("trusted_repository_ref changed or disappeared during validation")


def _frozen_trusted_ref(
    root: Path,
    manifest_path: str,
    approved_commit: object,
    receipt_commit: object,
    report: Report,
) -> str | None:
    path = _safe_path(manifest_path, report)
    if path is None:
        return None
    refs: dict[str, object] = {}
    for label, commit in (
        ("approved_planning_commit", approved_commit),
        ("receipt_commit", receipt_commit),
    ):
        if not isinstance(commit, str) or not SHA.fullmatch(commit):
            report.error(f"{label} must be a 40-character Git SHA")
            continue
        if not _exact_commit(root, commit):
            report.error(f"{label} must resolve before publication authority is loaded")
            continue
        value = _manifest(root, commit, path, label, report)
        if value is not None:
            refs[label] = value.get("trusted_repository_ref")
    if set(refs) != {"approved_planning_commit", "receipt_commit"}:
        return None
    approved_ref = refs["approved_planning_commit"]
    receipt_ref = refs["receipt_commit"]
    if approved_ref != receipt_ref:
        report.error("receipt trusted_repository_ref must equal its approved value")
        return None
    if not isinstance(approved_ref, str):
        report.error("publication trusted_repository_ref must be a string")
        return None
    return approved_ref


def _safe_path(value: str, report: Report) -> str | None:
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or path.as_posix() != value
        or "\x00" in value
        or any(part.casefold() == ".git" for part in path.parts)
    ):
        report.error("publication manifest must be a safe repository-relative path")
        return None
    return value


def _manifest(
    root: Path, commit: str, path: str, label: str, report: Report,
) -> dict[str, object] | None:
    entry = _git(root, "ls-tree", "-z", commit, "--", path, capture_output=True)
    if entry.returncode or not _regular_blob(entry.stdout, path):
        report.error(f"{label} publication manifest must be a regular file at {path}")
        return None
    result = _git(root, "show", f"{commit}:{path}", capture_output=True)
    try:
        value = json.loads(result.stdout.decode("utf-8")) if result.returncode == 0 else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        value = None
    if not isinstance(value, dict):
        report.error(f"{label} publication manifest must be a UTF-8 JSON object")
        return None
    return value


def _regular_blob(raw: bytes, path: str) -> bool:
    entries = [entry for entry in raw.split(b"\0") if entry]
    if len(entries) != 1 or b"\t" not in entries[0]:
        return False
    metadata, name = entries[0].split(b"\t", 1)
    fields = metadata.split()
    return (
        len(fields) == 3
        and fields[0] in {b"100644", b"100755"}
        and fields[1] == b"blob"
        and name == path.encode("utf-8")
    )


def _valid_branch_ref(root: Path, value: object, report: Report) -> bool:
    if not isinstance(value, str) or not value.startswith("refs/heads/"):
        report.error("trusted_repository_ref must be an exact refs/heads/... ref")
        return False
    result = _git(root, "check-ref-format", value, capture_output=True)
    if result.returncode:
        report.error("trusted_repository_ref must be a valid refs/heads/... ref")
        return False
    return True


def _github_origin_repository(root: Path, report: Report) -> str | None:
    result = _git(
        root, "remote", "get-url", "origin", capture_output=True, text=True,
    )
    if result.returncode:
        report.error("trusted repository authority requires a configured GitHub origin")
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
        report.error("trusted repository origin must identify one GitHub repository")
        return None
    return repository


def _load_github_branch_target(
    root: Path, trusted_ref: str, report: Report,
) -> str | None:
    queried = _git(
        root, "ls-remote", "--refs", "origin", trusted_ref,
        capture_output=True, text=True,
    )
    if queried.returncode:
        report.error(f"cannot query trusted_repository_ref {trusted_ref} from GitHub")
        return None
    matches: list[str] = []
    for line in queried.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == trusted_ref and SHA.fullmatch(fields[0]):
            matches.append(fields[0])
    if len(matches) != 1:
        report.error(
            f"trusted_repository_ref {trusted_ref} must resolve to one GitHub branch target"
        )
        return None
    target = matches[0]
    fetched = _git(
        root, "fetch", "--quiet", "--no-tags", "--force", "origin", trusted_ref,
        capture_output=True, text=True,
    )
    if fetched.returncode:
        report.error(f"cannot fetch trusted_repository_ref {trusted_ref} from GitHub")
        return None
    resolved = _git(
        root, "rev-parse", "--verify", "FETCH_HEAD^{commit}",
        capture_output=True, text=True,
    )
    if resolved.returncode or resolved.stdout.strip().lower() != target.lower():
        report.error("trusted_repository_ref changed while its GitHub target was verified")
        return None
    return target


def _exact_commit(root: Path, commit: str) -> bool:
    result = _git(
        root, "rev-parse", "--verify", f"{commit}^{{commit}}",
        capture_output=True, text=True,
    )
    return result.returncode == 0 and result.stdout.strip().lower() == commit.lower()


def _git(root: Path, *arguments: str, **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=False,
        env=git_no_replace_env(),
        **kwargs,
    )
