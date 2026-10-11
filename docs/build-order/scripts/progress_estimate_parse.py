"""Parse progress estimate samples and publication outcomes from transcript rows."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any, Iterable


ESTIMATE_KINDS = frozenset(("progress", "progress.checkin"))


PUBLICATION_EVENTS = {
    "event_publication_completed": "emitted",
    "event_publication_failed": "failed",
}


PERCENT = re.compile(r"^(?:100(?:\.0+)?|\d{1,2}(?:\.\d+)?)%?$")


def _mapping(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except (TypeError, ValueError):
            return None
        return decoded if isinstance(decoded, dict) else None
    return None


def _get(data: Any, *path: str) -> Any:
    for key in path:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


def _argument_candidates(row: dict[str, Any]) -> Iterable[dict[str, Any]]:
    paths = (
        ("payload", "params", "item", "arguments"),
        ("payload", "params", "arguments"),
        ("payload", "item", "arguments"),
        ("payload", "arguments"),
        ("item", "arguments"),
        ("arguments",),
    )
    seen: set[int] = set()
    for path in paths:
        candidate = _mapping(_get(row, *path))
        if candidate is not None and id(candidate) not in seen:
            seen.add(id(candidate))
            yield candidate

    # Some adapters persist the emitted event directly instead of the wrapping
    # emit_event tool call. It is safe to support only the two exact names.
    if row.get("event") in ESTIMATE_KINDS:
        payload = _mapping(row.get("payload")) or {}
        yield {
            "name": row["event"],
            "message": row.get("message", payload.get("message")),
            "payload": payload,
        }


def _percent(value: Any) -> int | float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str) and PERCENT.fullmatch(value.strip()):
        number = float(value.strip().removesuffix("%"))
    else:
        return None
    if not 0 <= number <= 100:
        return None
    return int(number) if number.is_integer() else number


def _text(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _timestamp(row: dict[str, Any]) -> str | None:
    value = row.get("timestamp")
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            parsed = None
        if parsed is not None and parsed.tzinfo is not None:
            return (
                parsed.astimezone(timezone.utc)
                .isoformat(timespec="microseconds")
                .replace("+00:00", "Z")
            )

    for path in (
        ("payload", "params", "startedAtMs"),
        ("payload", "params", "completedAtMs"),
        ("startedAtMs",),
        ("completedAtMs",),
    ):
        milliseconds = _get(row, *path)
        if isinstance(milliseconds, (int, float)) and not isinstance(milliseconds, bool):
            try:
                parsed = datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
            except (OverflowError, OSError, ValueError):
                continue
            return parsed.isoformat(timespec="microseconds").replace("+00:00", "Z")
    return None


def _call_id(row: dict[str, Any]) -> str | None:
    for path in (
        ("payload", "params", "callId"),
        ("payload", "params", "item", "id"),
        ("payload", "callId"),
        ("tool_call_id",),
        ("callId",),
        ("item", "id"),
    ):
        value = _get(row, *path)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return str(value)
    return None


def _event_id(row: dict[str, Any]) -> str | int | None:
    for path in (
        ("event_id",),
        ("payload", "event_id"),
        ("payload", "result", "id"),
        ("payload", "params", "result", "id"),
    ):
        value = _get(row, *path)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return value

    items = _get(row, "payload", "params", "item", "contentItems")
    if not isinstance(items, list):
        return None
    for item in items:
        if not isinstance(item, dict) or item.get("type") != "inputText":
            continue
        decoded = _mapping(item.get("text"))
        value = _get(decoded, "result", "id")
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return value
    return None


def _publication_outcome(row: dict[str, Any]) -> dict[str, Any] | None:
    status = PUBLICATION_EVENTS.get(row.get("event"))
    call_id = _call_id(row)
    timestamp = _timestamp(row)
    if status is None or call_id is None or timestamp is None:
        return None
    return {
        "delivery_status": status,
        "event_id": _event_id(row),
        "timestamp": timestamp,
        "tool_call_id": call_id,
    }


def _publication_ticket(row: dict[str, Any]) -> int | None:
    for key in ("issue_number", "issue_identifier"):
        value = row.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            return value
        if isinstance(value, str) and value.isdigit() and int(value) > 0:
            return int(value)
    return None


def _sample_id(
    ticket: int,
    source_log: str,
    call_id: str | None,
    timestamp: str,
    kind: str,
    percent: int | float,
    label: str | None,
    message: str | None,
) -> str:
    if call_id is not None:
        return _call_sample_id(ticket, call_id)
    identity = "\0".join(
        (
            "estimate",
            str(ticket),
            source_log,
            timestamp,
            kind,
            str(percent),
            label or "",
            message or "",
        )
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _call_sample_id(ticket: int, call_id: str) -> str:
    identity = f"call\0{ticket}\0{call_id}"
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()
