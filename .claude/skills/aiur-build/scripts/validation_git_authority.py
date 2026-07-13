"""Prove publication commits descend from an explicit GitHub-owned branch."""

from __future__ import annotations

from pathlib import Path
from typing import Callable, Optional

from validation_common import SHA, Report
from validation_git_remote import _clean_clone_proves_ancestor, _github_clone_url
from validation_git_repository import (
    _exact_commit,
    _git,
    _github_origin_repository,
    _reject_legacy_grafts,
    _valid_branch_ref,
)
from validation_github_authority import (
    _github_compare_proves_ancestor,
    _load_github_branch_target,
)
from validation_publication_authority import (
    PublicationAuthority,
    exact_commit,
    load_frozen_publication_authority,
)


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
