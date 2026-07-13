"""Resolve planning-pack paths without following symlinks outside the pack."""

from __future__ import annotations

from pathlib import Path
from typing import Any


def resolved_document(
    base: Path, value: object, label: str, report: Any,
) -> Path | None:
    if not isinstance(value, str) or not value.strip():
        report.error(f"{label} must be a relative path")
        return None
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        report.error(f"{label} must stay within the planning pack")
        return None
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
