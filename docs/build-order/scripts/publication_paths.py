"""Resolve planning-pack paths without following symlinks outside the pack."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Any


def safe_repository_relative(
    value: object, label: str, report: Any,
) -> str | None:
    """Return one normalized repository-relative POSIX path or fail closed."""
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


def resolved_document(
    base: Path, value: object, label: str, report: Any,
) -> Path | None:
    safe = safe_repository_relative(value, label, report)
    if safe is None:
        return None
    relative = Path(safe)
    try:
        root = base.resolve(strict=True)
        path = (root / relative).resolve(strict=True)
    except OSError as exc:
        report.error(f"{label} does not resolve: {exc}")
        return None
    if not path.is_relative_to(root) or not path.is_file():
        report.error(f"{label} does not resolve within the planning pack")
        return None
    return path
