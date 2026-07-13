"""Inspect local Git repository authority without replacement or grafts."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from validation_common import Report, git_no_replace_env


GITHUB_REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)


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

