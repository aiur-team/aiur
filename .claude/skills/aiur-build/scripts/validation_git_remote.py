"""Prove publication ancestry in a clean trusted-branch clone."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from validation_common import Report, git_no_replace_env
from validation_git_bounded import run_bounded_git
from validation_git_repository import _exact_commit, _git, _reject_legacy_grafts


GIT_AUTHORITY_TIMEOUT_SECONDS = 180
GIT_CLEAN_OUTPUT_BYTES = 64 * 1024


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
                root,
                "init", "--bare", "--quiet", "--template=", str(clone),
            )
            if initialized.returncode:
                _git_failure(
                    "cannot initialize clean publication authority clone",
                    initialized,
                    report,
                )
                return None
            fetched = _run_clean_git(
                clone, "fetch", "--quiet", "--no-tags", "--force",
                "--filter=blob:none", _github_clone_url(repository),
                f"{trusted_ref}:refs/heads/publication-authority",
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
    root: Path, *arguments: str,
) -> subprocess.CompletedProcess[str]:
    return run_bounded_git(
        root, *arguments, environment=_clean_git_env(), text=True,
        timeout_seconds=GIT_AUTHORITY_TIMEOUT_SECONDS,
        stdout_limit=GIT_CLEAN_OUTPUT_BYTES,
        stderr_limit=GIT_CLEAN_OUTPUT_BYTES,
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
