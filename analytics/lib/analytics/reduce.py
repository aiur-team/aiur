"""Pure, tolerant offline reducer for durable run-telemetry streams.

Parsing is line-isolated: malformed, unsupported, or partial records become
report warnings while adjacent valid records remain usable. The reducer owns
ordering, profile statistics, lifecycle interval pairing, and review wakeup
diagnostics, and produces the same consumable dataset shape as the Elixir
``Aiur.RunTelemetry.Dataset`` reducer so the Elixir dashboard Presenter can
read a materialized summary back into its model pipeline.

The reducer is pure: raw NDJSON -> summary map, no network. GitHub enrichment
(``--enrich``) is an explicit opt-in recorded in provenance.
"""

from __future__ import annotations

import os
from typing import Any, Iterable

from .github import anchor_fields

# Stage modules own the logic; the names below are re-exported so
# ``reducer.<name>`` callers keep working.
from .materialize import (  # noqa: F401
    SUMMARY_SCHEMA_VERSION,
    _rollup_build,
    boot_summary,
    build_summary_for,
    write_all_run_summaries,
    write_run_summary,
)
from .parse import _in_boot, _parse_timestamp, _time_range, parse_file, parse_line  # noqa: F401
from .reduce_actors import RESOURCE_EVIDENCE, RESOURCE_METRICS, _reduce_actors  # noqa: F401
from .reduce_tickets import _reduce_tickets


def reduce_files(files: list[str] | list[Any], opts: dict | None = None) -> dict:
    """Reduce a set of telemetry files into a full dataset map."""
    opts = opts or {}
    inputs = [str(path) for path in files]

    file_records: list[dict] = []
    warnings: list[dict] = []
    source_bytes = 0
    for path in files:
        records, file_warnings = parse_file(path)
        file_records.extend(records)
        warnings.extend(file_warnings)
        try:
            source_bytes += os_path_size(path)
        except OSError:
            pass

    records = sorted(file_records, key=_record_sort_key)
    records, dedupe_warnings = _dedupe_records(records)
    warnings.extend(dedupe_warnings)
    warnings.extend(_sequence_warnings(records))

    github_records, github_warnings = _github_records(opts.get("github_events", []))
    records.extend(github_records)
    warnings.extend(github_warnings)

    actors = _reduce_actors(records, opts)
    tickets, findings = _reduce_tickets(records, opts)
    restarts = [record for record in records if _daemon_restart(record)]

    provenance = {
        "inputs": inputs,
        "files": inputs,
        "schema_versions": sorted({record["schema_version"] for record in records}),
        "time_range": _time_range(records),
        "record_count": len(records),
        "enrich": bool(opts.get("github_events")),
        "generated_by": "analytics/reduce",
    }

    return {
        "records": records,
        "restarts": restarts,
        "actors": actors,
        "tickets": tickets,
        "findings": findings,
        "warnings": warnings,
        "provenance": provenance,
        "_source_bytes": source_bytes,
    }


def os_path_size(path: Any) -> int:
    import os

    return os.path.getsize(str(path))


# --- record helpers --------------------------------------------------------


def _record_sort_key(record: dict) -> tuple:
    return (
        record["timestamp_ms"],
        record["boot_id"],
        record["sequence"],
        record["record_id"],
        record["source_path"],
        record["source_line"],
    )


def _dedupe_records(records: list[dict]) -> tuple[list[dict], list[dict]]:
    kept: list[dict] = []
    record_ids: set[str] = set()
    event_keys: set[str] = set()
    warnings: list[dict] = []
    for record in records:
        event_key = _lifecycle_event_key(record)
        if record["record_id"] in record_ids:
            warnings.append({"type": "duplicate_record", "record_id": record["record_id"]})
        elif event_key and event_key in event_keys:
            warnings.append({"type": "duplicate_lifecycle_boundary", "event_key": event_key})
        else:
            kept.append(record)
            record_ids.add(record["record_id"])
            if event_key:
                event_keys.add(event_key)
    return kept, warnings


def _lifecycle_event_key(record: dict) -> str | None:
    if record["kind"] != "lifecycle":
        return None
    attributes = record["attributes"]
    if attributes.get("source_id") or attributes.get("operation_id"):
        return attributes.get("event_key")
    return None


def _sequence_warnings(records: list[dict]) -> list[dict]:
    warnings: list[dict] = []
    by_boot: dict[str, list[dict]] = {}
    for record in records:
        if record["boot_id"] == "github":
            continue
        by_boot.setdefault(record["boot_id"], []).append(record)

    for boot_id, boot_records in by_boot.items():
        ordered = sorted(boot_records, key=lambda record: record["sequence"])
        for previous, current in zip(ordered, ordered[1:]):
            if current["sequence"] > previous["sequence"] + 1:
                warnings.append(
                    {
                        "type": "sequence_gap",
                        "boot_id": boot_id,
                        "after_sequence": previous["sequence"],
                        "before_sequence": current["sequence"],
                        "missing_count": current["sequence"] - previous["sequence"] - 1,
                    }
                )
    warnings.sort(key=lambda warning: (warning.get("boot_id", ""), warning.get("after_sequence", 0)))
    return warnings


def _github_records(events: Iterable[dict]) -> tuple[list[dict], list[dict]]:
    records: list[dict] = []
    warnings: list[dict] = []
    for sequence, event in enumerate(events, start=1):
        parsed = _github_record(event, sequence)
        if isinstance(parsed, dict):
            records.append(parsed)
        elif parsed == "warning":
            warnings.append({"type": "invalid_github_timestamp", "source_index": sequence})
    return records, warnings


def _github_record(event: dict, sequence: int) -> dict | str:
    kind, timestamp, ticket = anchor_fields(event)
    parsed = _parse_timestamp(timestamp)
    if parsed is None:
        return "warning"
    attributes = dict(event.get("attributes") or {})
    attributes.setdefault("ticket", ticket)
    attributes["source"] = "github"
    attributes["source_id"] = event.get("id", "event:%d" % sequence)
    attributes["event"] = {"pr.opened": "pr_opened", "pr.merged": "pr_merged"}.get(kind, "comment_received")
    attributes["boundary"] = "point"
    source_id = attributes["source_id"]
    return {
        "schema_version": 2,
        "kind": "lifecycle",
        "timestamp": parsed.isoformat().replace("+00:00", "Z"),
        "timestamp_iso": parsed.isoformat().replace("+00:00", "Z"),
        "timestamp_ms": int(parsed.timestamp() * 1000),
        "recorded_at": None,
        "boot_id": "github",
        "sequence": sequence,
        "record_id": "github:%s" % source_id,
        "attributes": attributes,
        "source_path": "(github)",
        "source_line": sequence,
    }


def _daemon_restart(record: dict) -> bool:
    return record["kind"] == "restart" and record["attributes"].get("event") == "daemon_restart"
