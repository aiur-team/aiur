"""Prove publication commits descend from an explicit GitHub-owned branch."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Optional

from validation_common import SHA, Report, git_no_replace_env
from validation_github_api import (
    GhApiClient,
    GitHubApiError,
)
from validation_publication_authority import (
    PublicationAuthority,
    exact_commit,
    load_frozen_publication_authority,
)


GITHUB_REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)
GIT_AUTHORITY_TIMEOUT_SECONDS = 180
BranchTargetLoader = Callable[[Path, str, Report], Optional[str]]
GitHubAncestryChecker = Callable[
    [Path, str, str, str, Report], Optional[bool]
]
CleanAncestryChecker = Callable[
    [Path, str, str, str, str, Report], Optional[bool]
]


def validate_publication_commit_authority(
    repository_root: Path,
    expected_repository: object,
    publication_manifest_path: str,
    approved_commit: object,
    receipt_commit: object,
    report: Report,
    branch_target_loader: BranchTargetLoader | None = None,
    github_ancestry_checker: GitHubAncestryChecker | None = None,
    clean_ancestry_checker: CleanAncestryChecker | None = None,
) -> PublicationAuthority | None:
    """Load the immutable trusted ref, then prove both publication commits."""
    root = repository_root.resolve()
    authority = load_frozen_publication_authority(
        root, publication_manifest_path, approved_commit, receipt_commit, report
    )
    if authority is None:
        return None
    _validate_trusted_repository_commits(
        root,
        expected_repository,
        authority.trusted_repository_ref,
        approved_commit,
        receipt_commit,
        report,
        branch_target_loader,
        github_ancestry_checker,
        clean_ancestry_checker,
    )
    return authority


def _validate_trusted_repository_commits(
    repository_root: Path,
    expected_repository: object,
    trusted_repository_ref: object,
    approved_commit: object,
    receipt_commit: object,
    report: Report,
    branch_target_loader: BranchTargetLoader | None = None,
    github_ancestry_checker: GitHubAncestryChecker | None = None,
    clean_ancestry_checker: CleanAncestryChecker | None = None,
) -> None:
    """Require ordered commits on one unchanged authoritative remote branch."""
    root = repository_root.resolve()
    if not _reject_legacy_grafts(root, report):
        return
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
        if not exact_commit(root, commit):
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
        if approved == receipt:
            report.error(
                "approved_planning_commit must strictly precede receipt_commit"
            )
        clean_checker = clean_ancestry_checker or _clean_clone_proves_ancestor
        clean_order = clean_checker(
            root, repository, trusted_repository_ref, approved, receipt, report,
        )
        if clean_order is False:
            report.error(
                "a clean GitHub clone must prove approved_planning_commit strictly "
                "precedes receipt_commit"
            )
        checker = github_ancestry_checker or _github_compare_proves_ancestor
        github_order = checker(root, repository, approved, receipt, report)
        if github_order is False:
            report.error(
                "GitHub must prove approved_planning_commit strictly precedes "
                "receipt_commit"
            )
    _reject_legacy_grafts(root, report)
    rechecked_target = loader(root, trusted_repository_ref, report)
    if rechecked_target != target:
        report.error("trusted_repository_ref changed or disappeared during validation")


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


def _reject_legacy_grafts(
    root: Path,
    report: Report,
    git_environment: dict[str, str] | None = None,
) -> bool:
    """Reject graft files in either the worktree Git dir or shared common dir."""
    directories: list[Path] = []
    for option, label in (
        ("--absolute-git-dir", "Git directory"),
        ("--git-common-dir", "Git common directory"),
    ):
        result = _git(
            root, "rev-parse", option, capture_output=True, text=True,
            git_environment=git_environment,
        )
        raw = result.stdout.strip() if result.returncode == 0 else ""
        if not raw:
            report.error(f"cannot resolve {label} for publication authority")
            return False
        directory = Path(raw)
        if not directory.is_absolute():
            directory = root / directory
        directories.append(directory.resolve())

    clean = True
    for directory in dict.fromkeys(directories):
        grafts = directory / "info/grafts"
        try:
            os.lstat(grafts)
        except FileNotFoundError:
            continue
        except OSError as exc:
            report.error(
                "cannot inspect legacy Git graft entry for publication authority: "
                f"{grafts}: {exc}"
            )
            clean = False
        else:
            report.error(
                "legacy Git graft entry is forbidden for publication authority: "
                f"{grafts}"
            )
            clean = False
    return clean


def _clean_clone_proves_ancestor(
    root: Path,
    repository: str,
    trusted_ref: str,
    approved: str,
    receipt: str,
    report: Report,
) -> bool | None:
    """Fetch the trusted branch into a fresh object database and prove ordering."""
    if approved == receipt:
        return False
    try:
        with tempfile.TemporaryDirectory(prefix="aiur-publication-authority-") as raw:
            clone = Path(raw) / "authority.git"
            clean_environment = _clean_git_env()
            initialized = _run_clean_git(
                [
                    "git", "init", "--bare", "--quiet", "--template=",
                    str(clone),
                ],
                root,
            )
            if initialized.returncode:
                _git_failure(
                    "cannot initialize clean publication authority clone",
                    initialized,
                    report,
                )
                return None
            fetched = _run_clean_git(
                [
                    "git", "-C", str(clone), "fetch", "--quiet", "--no-tags",
                    "--force", "--filter=blob:none", _github_clone_url(repository),
                    f"{trusted_ref}:refs/heads/publication-authority",
                ],
                root,
            )
            if fetched.returncode:
                _git_failure(
                    "cannot fetch trusted branch into clean publication authority clone",
                    fetched,
                    report,
                )
                return None
            if not _reject_legacy_grafts(clone, report, clean_environment):
                return None
            for label, commit in (
                ("approved_planning_commit", approved),
                ("receipt_commit", receipt),
            ):
                if not _exact_commit(clone, commit, clean_environment):
                    report.error(
                        f"{label} must exist in the clean trusted-branch clone"
                    )
                    return None
            result = _git(
                clone, "merge-base", "--is-ancestor", approved, receipt,
                capture_output=True,
                git_environment=clean_environment,
            )
            if not _reject_legacy_grafts(clone, report, clean_environment):
                return None
            if result.returncode == 1:
                return False
            if result.returncode:
                report.error(
                    "cannot prove approval ancestry in the clean trusted-branch clone"
                )
                return None
            return True
    except (OSError, subprocess.TimeoutExpired) as exc:
        report.error(f"clean publication authority clone failed: {exc}")
        return None


def _github_clone_url(repository: str) -> str:
    return f"https://github.com/{repository}.git"


def _run_clean_git(
    arguments: list[str], cwd: Path,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        env=_clean_git_env(),
        timeout=GIT_AUTHORITY_TIMEOUT_SECONDS,
    )


def _clean_git_env() -> dict[str, str]:
    environment = git_no_replace_env()
    for name in (
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_REPLACE_REF_BASE",
        "GIT_SHALLOW_FILE",
        "GIT_TEMPLATE_DIR",
        "GIT_WORK_TREE",
    ):
        environment.pop(name, None)
    return environment


def _git_failure(
    message: str, result: subprocess.CompletedProcess[str], report: Report,
) -> None:
    detail = result.stderr.strip() or f"exit {result.returncode}"
    report.error(f"{message}: {detail}")


def _github_compare_proves_ancestor(
    root: Path, repository: str, approved: str, receipt: str, report: Report,
) -> bool | None:
    """Prove the strict approval-to-receipt edge through GitHub's compare API."""
    endpoint = f"repos/{repository}/compare/{approved}...{receipt}"
    value = _github_json(root, endpoint, report)
    if value is None:
        return None
    if not isinstance(value, dict):
        report.error("GitHub authority comparison returned an invalid object")
        return None
    base = value.get("base_commit")
    merge_base = value.get("merge_base_commit")
    base_sha = base.get("sha") if isinstance(base, dict) else None
    merge_base_sha = merge_base.get("sha") if isinstance(merge_base, dict) else None
    ahead_by = value.get("ahead_by")
    behind_by = value.get("behind_by")
    return (
        value.get("status") == "ahead"
        and isinstance(base_sha, str)
        and base_sha.lower() == approved.lower()
        and isinstance(merge_base_sha, str)
        and merge_base_sha.lower() == approved.lower()
        and type(ahead_by) is int
        and ahead_by > 0
        and type(behind_by) is int
        and behind_by == 0
    )


def _github_json(root: Path, endpoint: str, report: Report) -> object | None:
    try:
        return GhApiClient(root).get(endpoint)
    except GitHubApiError as exc:
        report.error(f"GitHub authority query failed: {exc}")
        return None


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


def _exact_commit(
    root: Path, commit: str, git_environment: dict[str, str] | None = None,
) -> bool:
    result = _git(
        root, "rev-parse", "--verify", f"{commit}^{{commit}}",
        capture_output=True, text=True,
        git_environment=git_environment,
    )
    return result.returncode == 0 and result.stdout.strip().lower() == commit.lower()


def _git(
    root: Path,
    *arguments: str,
    git_environment: dict[str, str] | None = None,
    **kwargs: object,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=False,
        env=git_environment or git_no_replace_env(),
        **kwargs,
    )
