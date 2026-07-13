"""Validate observed GitHub parenthood for standalone planning issues."""

from __future__ import annotations

from publication_common import EXTERNAL_BLOCKER, Report


def validate_parent_map(
    value: object, expected_ids: set[str], label: str, report: Report,
) -> None:
    if not isinstance(value, dict) or set(value) != expected_ids:
        report.error(f"{label} keys must match standalone issues")
        return
    for logical_id, parent in value.items():
        if parent is None:
            continue
        if not isinstance(parent, str) or not EXTERNAL_BLOCKER.fullmatch(parent):
            report.error(f"{label}.{logical_id} must be null or owner/repo#number")
        else:
            report.error(f"{logical_id} must remain standalone but has parent {parent}")
