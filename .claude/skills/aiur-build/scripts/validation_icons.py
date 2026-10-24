"""Heroicon validation and feature/general-epic collision checks."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from validation_common import Report
from heroicon_names import OUTLINE_NAMES

ALIASES = {"bug": "bug-ant", "pen": "paint-brush", "server": "server-stack", "docs": "book-open"}
VALID_NAMES = OUTLINE_NAMES | ALIASES.keys()
DEFAULT_EPICS = [
    {"key": "bugs", "labels": ["bug"], "icon": "bug"},
    {"key": "design", "labels": ["design"], "icon": "pen"},
    {"key": "infra", "labels": ["refactor", "chore"], "icon": "server"},
    {"key": "docs", "labels": ["documentation"], "icon": "docs"},
]


def canonical_icon(value: object) -> str | None:
    return ALIASES.get(value, value) if isinstance(value, str) else None


def _scalar(text: str) -> str:
    return text.strip().strip("'\"")


def _list_value(text: str) -> list[str]:
    value = text.strip()
    if not (value.startswith("[") and value.endswith("]")):
        return []
    return [_scalar(item) for item in value[1:-1].split(",") if _scalar(item)]


def configured_epics(repository_root: Path) -> list[dict[str, Any]]:
    path = repository_root / ".aiur/config"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return DEFAULT_EPICS
    start = next((i for i, line in enumerate(lines) if re.match(r"^\s*general_epics\s*:", line)), None)
    if start is None:
        return DEFAULT_EPICS
    header = lines[start].split(":", 1)[1].strip()
    if header in {"[]", "null", "~"}:
        return []
    base_indent = len(lines[start]) - len(lines[start].lstrip())
    records: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in lines[start + 1 :]:
        content = line.split("#", 1)[0].rstrip()
        if not content.strip():
            continue
        indent = len(content) - len(content.lstrip())
        if indent <= base_indent:
            break
        item = content.strip()
        if item.startswith("-"):
            current = {}
            records.append(current)
            item = item[1:].strip()
        if current is None:
            continue
        inline = re.search(r"\b(key|icon|labels)\s*:\s*(\[[^]]*\]|[^,}]+)", item)
        if inline:
            for key, value in re.findall(r"\b(key|icon|labels)\s*:\s*(\[[^]]*\]|[^,}]+)", item):
                current[key] = _list_value(value) if key == "labels" else _scalar(value)
        elif ":" in item:
            key, value = (part.strip() for part in item.split(":", 1))
            if key in {"key", "icon"}:
                current[key] = _scalar(value)
            elif key == "labels":
                current[key] = _list_value(value)
    return [record for record in records if record.get("key") and record.get("icon")]


def validate_icon_collisions(
    data: dict[str, Any], tickets: dict[str, dict[str, Any]],
    general_epics: list[dict[str, Any]], report: Report,
) -> None:
    workstream_records = data.get("workstreams", [])
    if not isinstance(workstream_records, list):
        workstream_records = []
    workstreams = {
        record.get("id"): record
        for record in workstream_records
        if isinstance(record, dict) and isinstance(record.get("id"), str)
    }
    projection = data.get("label_projection", {})
    if not isinstance(projection, dict):
        projection = {}
    lane_labels = projection.get("workstreams", {})
    phase_labels = projection.get("phases", {}) if isinstance(projection, dict) else {}
    complexity_labels = projection.get("complexities", {}) if isinstance(projection, dict) else {}
    if not isinstance(lane_labels, dict):
        lane_labels = {}
    if not isinstance(phase_labels, dict):
        phase_labels = {}
    if not isinstance(complexity_labels, dict):
        complexity_labels = {}
    required = projection.get("required_ticket_labels", []) if isinstance(projection, dict) else []
    if not isinstance(required, list):
        required = []
    for ticket_id, ticket in tickets.items():
        if not isinstance(ticket, dict):
            continue
        feature_id = ticket.get("workstream")
        feature = workstreams.get(feature_id) if isinstance(feature_id, str) else None
        icon = canonical_icon(feature.get("icon")) if feature else None
        if icon is None:
            continue
        labels = {str(value).casefold() for value in required if isinstance(value, str)}
        labels.add(str(projection.get("build_order", "")).casefold())
        lane = lane_labels.get(feature_id)
        if isinstance(lane, str):
            labels.add(lane.casefold())
        phase = phase_labels.get(str(ticket.get("phase_hint")))
        complexity = complexity_labels.get(str(ticket.get("complexity_points")))
        labels.update(value.casefold() for value in (phase, complexity) if isinstance(value, str))
        for epic in general_epics:
            matchers = epic.get("labels", [])
            if not isinstance(matchers, list) or not labels.intersection(
                str(value).casefold() for value in matchers if isinstance(value, str)
            ):
                continue
            if icon == canonical_icon(epic.get("icon")):
                report.error(
                    f"{ticket_id}: feature {feature_id} icon collides with matching epic {epic.get('key')}"
                )


def repository_root(path: Path) -> Path:
    for candidate in (path, *path.parents):
        if (candidate / ".aiur/config").is_file() or (candidate / "src/deps/heroicons").exists():
            return candidate
    return path
