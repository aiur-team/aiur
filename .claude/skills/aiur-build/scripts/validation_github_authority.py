"""Query immutable GitHub branch and commit authority."""

from __future__ import annotations

from pathlib import Path

from validation_common import SHA, Report
from validation_git_repository import _git
from validation_github_api import GhApiClient, GitHubApiError


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
