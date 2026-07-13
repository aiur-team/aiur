"""Read and normalize live GitHub issue relationships."""

from __future__ import annotations

from typing import Any

from validation_common import Report
from validation_github_live_issue import _mapping
from validation_github_live_models import _mapping_key
from validation_github_reader import GitHubReader, LiveGitHubError


def _relationships(
    reader: GitHubReader, kind: str, mapping: dict[str, Any],
    reverse: dict[str, str], report: Report,
) -> set[str]:
    try:
        values = (
            reader.subissues(mapping["repository"], mapping["number"])
            if kind == "subissues"
            else reader.blockers(mapping["repository"], mapping["number"])
        )
    except LiveGitHubError as exc:
        report.error(str(exc))
        return set()
    result: set[str] = set()
    seen: set[tuple[str, int]] = set()
    for raw in values:
        observed = _mapping(raw, None, f"live GitHub {kind}", report)
        if observed is None:
            continue
        identity = (observed["repository"], observed["number"])
        if identity in seen:
            report.error(f"live GitHub {kind} response contains a duplicate issue")
            continue
        seen.add(identity)
        logical_id = reverse.get(_mapping_key(observed))
        if logical_id is None:
            report.error(
                f"live GitHub {kind} contains unexpected issue "
                f"{identity[0]}#{identity[1]}"
            )
            continue
        result.add(logical_id)
    return result


def _parent(
    reader: GitHubReader, mapping: dict[str, Any],
    reverse: dict[str, str], report: Report,
) -> str | None:
    try:
        raw = reader.parent(mapping["repository"], mapping["number"])
    except LiveGitHubError as exc:
        report.error(str(exc))
        return None
    if raw is None:
        return None
    observed = _mapping(raw, None, "live GitHub parent", report)
    if observed is None:
        return None
    identity = (observed["repository"], observed["number"])
    logical_id = reverse.get(_mapping_key(observed))
    if logical_id is None:
        report.error(
            f"live GitHub parent contains unexpected issue "
            f"{identity[0]}#{identity[1]}"
        )
    return logical_id
