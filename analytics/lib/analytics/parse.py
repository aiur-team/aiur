"""Tolerant NDJSON parsing and small record helpers shared by the reducer stages."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from . import sources


SUPPORTED_KINDS = ("restart", "lifecycle", "resource", "warning")
_RECORD_REQUIRED = ("kind", "timestamp", "boot_id", "sequence", "record_id", "attributes")


def parse_file(path: str | Any) -> tuple[list[dict], list[dict]]:
    """Parse one NDJSON file into (records, warnings).

    Each line is validated independently; a bad line never discards its
    neighbours. ``schema_version`` 99 records (future schemas) and non-JSON
    lines are reported as warnings and skipped.
    """
    records: list[dict] = []
    warnings: list[dict] = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line_number, raw in enumerate(handle, start=1):
                record, warning = parse_line(raw, str(path), line_number)
                if record is not None:
                    records.append(record)
                if warning is not None:
                    warnings.append(warning)
    except OSError as error:
        warnings.append({"type": "file_read_error", "path": str(path), "reason": str(error)})
    return records, warnings


def parse_line(raw: str, path: str, line_number: int) -> tuple[dict | None, dict | None]:
    line = raw.strip()
    if not line:
        return None, None
    try:
        decoded = json.loads(line)
    except ValueError:
        return None, {"type": "malformed_line", "path": path, "line": line_number}

    if not isinstance(decoded, dict):
        return None, {"type": "invalid_record", "path": path, "line": line_number}

    schema_version = decoded.get("schema_version")
    if not isinstance(schema_version, int) or schema_version not in sources.SUPPORTED_TELEMETRY_SCHEMA_VERSIONS:
        return None, {
            "type": "unsupported_schema",
            "path": path,
            "line": line_number,
            "schema_version": schema_version,
        }

    missing = [field for field in _RECORD_REQUIRED if field not in decoded]
    if missing:
        return None, {"type": "missing_fields", "path": path, "line": line_number, "fields": missing}

    kind = decoded["kind"]
    if not isinstance(kind, str) or kind not in SUPPORTED_KINDS:
        return None, {"type": "unknown_kind", "path": path, "line": line_number, "kind": kind}

    attributes = decoded["attributes"]
    if not isinstance(attributes, dict):
        return None, {"type": "missing_fields", "path": path, "line": line_number, "fields": ["attributes"]}

    timestamp = _parse_timestamp(decoded.get("timestamp"))
    if timestamp is None:
        return None, {"type": "invalid_timestamp", "path": path, "line": line_number}

    timestamp_ms = int(timestamp.timestamp() * 1000)
    return (
        {
            "schema_version": schema_version,
            "kind": kind,
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "timestamp_iso": timestamp.isoformat().replace("+00:00", "Z"),
            "timestamp_ms": timestamp_ms,
            "recorded_at": decoded.get("recorded_at"),
            "boot_id": decoded["boot_id"],
            "sequence": decoded["sequence"],
            "record_id": decoded["record_id"],
            "attributes": attributes,
            "source_path": path,
            "source_line": line_number,
        },
        None,
    )


def _parse_timestamp(value: Any) -> datetime | None:
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed
        except ValueError:
            return None
    return None


def _now_iso(opts: dict) -> str:
    now = opts.get("now")
    if now is None:
        now = datetime.now(timezone.utc)
    if isinstance(now, str):
        return now
    return now.isoformat().replace("+00:00", "Z")


def _in_boot(record: dict, boot_id: str) -> bool:
    # Accepts both raw records (attributes dict) and lifecycle event dicts
    # (which carry `source` directly), matching the Elixir in_boot? clauses.
    if record.get("boot_id") == "github":
        return True
    attributes = record.get("attributes")
    source = attributes.get("source") if isinstance(attributes, dict) else record.get("source")
    if source == "github_reconciliation":
        return False
    return record.get("boot_id") == boot_id


def _time_range(records: list[dict]) -> dict | None:
    if not records:
        return None
    return {"start": records[0]["timestamp_iso"], "end": records[-1]["timestamp_iso"]}
