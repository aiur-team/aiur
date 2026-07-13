"""Read exact approved Git objects without replacement."""

from __future__ import annotations

import subprocess
from pathlib import Path

from validation_common import SHA, Report, git_no_replace_env


def exact_approved_commit(root: Path, approved: object, report: Report) -> bool:
    if not isinstance(approved, str) or not SHA.fullmatch(approved):
        report.error("approved planning commit must be a 40-character Git SHA")
        return False
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{approved}^{{commit}}"],
        check=False, capture_output=True, text=True, env=git_no_replace_env(),
    )
    if result.returncode or result.stdout.strip().lower() != approved.lower():
        report.error("approved planning commit must resolve to an exact commit")
        return False
    return True


def approved_text(
    root: Path, approved: str, path: str, label: str, report: Report,
) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{approved}:{path}"],
        check=False, capture_output=True, env=git_no_replace_env(),
    )
    if result.returncode:
        report.error(f"{label} is absent from approved commit at {path}")
        return None
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        report.error(f"{label} must be UTF-8: {exc}")
        return None
