"""Requery and verify a materialized Build Order against live GitHub."""

from __future__ import annotations

from typing import Any

from validation_common import Report
from validation_github_live_models import LiveSnapshot, _merge
from validation_github_live_receipt import _compare_receipt
from validation_github_live_snapshot import _snapshot
from validation_github_reader import (
    GhApiReader,
    GitHubReader,
    LiveGitHubError,
    MAX_ITEMS,
    MAX_PAGES,
    PAGE_SIZE,
    QueryBudget,
)


def validate_live_github_receipt(
    data: dict[str, Any],
    report: Report,
    reader: GitHubReader,
) -> None:
    """Require two identical live snapshots that exactly match one valid receipt."""
    first_report = Report()
    first = _snapshot(data, reader, first_report)
    _merge(first_report, report)
    if first is None or first_report.errors:
        return
    second_report = Report()
    second = _snapshot(data, reader, second_report)
    _merge(second_report, report)
    if second is None or second_report.errors:
        return
    if first != second:
        report.error("live GitHub publication graph changed during bounded requery")
        return
    _compare_receipt(data, first, report)
