"""Read exact approved Git objects without replacement."""

from __future__ import annotations

from pathlib import Path

from validation_common import SHA, Report
from validation_git_bounded import (
    GIT_OUTPUT_LIMIT_RETURN_CODE,
    run_bounded_git,
)


GIT_APPROVED_SOURCE_TIMEOUT_SECONDS = 30
MAX_APPROVED_SOURCE_BYTES = 2 * 1024 * 1024
MAX_APPROVED_COMMIT_OUTPUT_BYTES = 64 * 1024


def exact_approved_commit(root: Path, approved: object, report: Report) -> bool:
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("approved planning commit must be a 40-character Git SHA")
        return False
    result = run_bounded_git(
        root, "rev-parse", "--verify", f"{approved}^{{commit}}",
        text=True, timeout_seconds=GIT_APPROVED_SOURCE_TIMEOUT_SECONDS,
        stdout_limit=MAX_APPROVED_COMMIT_OUTPUT_BYTES,
    )
    if result.returncode or result.stdout.strip().lower() != approved.lower():
        report.error("approved planning commit must resolve to an exact commit")
        return False
    return True


def approved_text(
    root: Path, approved: str, path: str, label: str, report: Report,
) -> str | None:
    result = run_bounded_git(
        root, "show", f"{approved}:{path}",
        timeout_seconds=GIT_APPROVED_SOURCE_TIMEOUT_SECONDS,
        stdout_limit=MAX_APPROVED_SOURCE_BYTES,
    )
    if result.returncode == GIT_OUTPUT_LIMIT_RETURN_CODE:
        report.error(f"{label} exceeds approved source byte bound at {path}")
        return None
    if result.returncode:
        report.error(f"{label} is absent from approved commit at {path}")
        return None
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        report.error(f"{label} must be UTF-8: {exc}")
        return None
