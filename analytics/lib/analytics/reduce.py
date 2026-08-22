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

import json
import math
from datetime import datetime, timezone
from typing import Any, Iterable

from . import sources

# run-summary schema version (distinct from the telemetry record schema version).
SUMMARY_SCHEMA_VERSION = 1

SUPPORTED_KINDS = ("restart", "lifecycle", "resource", "warning")
BOUNDARIES = ("start", "end", "point")

RESOURCE_METRICS = (
    "cpu_percent",
    "rss_bytes",
    "fd_count",
    "read_bytes",
    "write_bytes",
    "read_bytes_per_second",
    "write_bytes_per_second",
    "system_fd_used",
    "system_fd_limit",
    "system_fd_available",
    "system_fd_headroom_ratio",
    "fleet_agents_occupied",
    "fleet_agents_configured",
    "fleet_agents_max",
    "fleet_agents_effective",
    "build_gate_capacity",
    "build_gate_active",
    "build_gate_queued",
    "build_queue_oldest_wait_seconds",
)

RESOURCE_EVIDENCE = (
    "fleet_capacity_status",
    "fleet_capacity_age_ms",
    "fleet_capacity_observed_at_ms",
    "build_gate_enabled",
    "build_gate_status",
    "build_gate_observed_at_ms",
)

DEFAULT_SAMPLE_INTERVAL_MS = 5_000
DEFAULT_GAP_THRESHOLD_MULTIPLIER = 1.5
DEFAULT_REVIEW_RESUME_GRACE_SECONDS = 300

_RECORD_REQUIRED = ("kind", "timestamp", "boot_id", "sequence", "record_id", "attributes")


# ---------------------------------------------------------------------------
# Tolerant NDJSON parsing
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Reduction
# ---------------------------------------------------------------------------


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


def boot_summary(dataset: dict, boot_id: str, opts: dict | None = None) -> dict:
    """Narrow a reduced dataset to one boot and return a run-summary map."""
    opts = opts or {}
    records = [record for record in dataset["records"] if _in_boot(record, boot_id)]
    actors = _rescope_actors(dataset["actors"], boot_id)
    tickets, _findings = _rescope_tickets(dataset["tickets"], boot_id)
    findings = [finding for finding in dataset["findings"] if finding.get("ticket") in tickets]

    provenance = dict(dataset["provenance"])
    source_files = sorted({record["source_path"] for record in records})
    provenance.update(
        {
            "inputs": provenance.get("inputs", []),
            "files": source_files,
            "time_range": _time_range(records),
            "record_count": len(records),
            "enrich": bool(opts.get("github_events")) or provenance.get("enrich", False),
        }
    )

    source_bytes = dataset.get("_source_bytes", 0)

    return {
        "schema_version": SUMMARY_SCHEMA_VERSION,
        "boot_id": boot_id,
        "generated_at": _now_iso(opts),
        "source_files": source_files,
        "source_bytes": source_bytes,
        "records": records,
        "restarts": [record for record in dataset["restarts"] if _in_boot(record, boot_id)],
        "actors": actors,
        "tickets": tickets,
        "findings": findings,
        "warnings": _warnings_for_boot(dataset["warnings"], boot_id),
        "provenance": provenance,
    }


def _warnings_for_boot(warnings: list[dict], boot_id: str) -> list[dict]:
    """Keep the warnings that belong to one boot; file-level warnings (no boot
    id) are boot-agnostic and stay. A per-boot summary must not carry another
    boot's boot-scoped warnings (e.g. its sequence gaps)."""
    return [warning for warning in warnings if warning.get("boot_id") in (None, boot_id)]


def os_path_size(path: Any) -> int:
    import os

    return os.path.getsize(str(path))


def _now_iso(opts: dict) -> str:
    now = opts.get("now")
    if now is None:
        now = datetime.now(timezone.utc)
    if isinstance(now, str):
        return now
    return now.isoformat().replace("+00:00", "Z")


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
    kind = event.get("topic", "").rsplit(".", 1)[-1]
    timestamp = event.get("timestamp")
    if kind in ("pr.opened", "pr.merged"):
        pr = event.get("pr") or {}
        timestamp = pr.get("merged_at") or pr.get("closed_at") or pr.get("created_at") or timestamp
    parsed = _parse_timestamp(timestamp)
    if parsed is None:
        return "warning"
    attributes = dict(event.get("attributes") or {})
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


# --- actors ----------------------------------------------------------------


def _reduce_actors(records: list[dict], opts: dict) -> dict:
    samples_by_actor: dict[str, list[dict]] = {}
    warnings: list[dict] = []
    for record in records:
        if record["kind"] != "resource":
            continue
        actor = record["attributes"].get("actor")
        if isinstance(actor, str) and actor:
            samples_by_actor.setdefault(actor, []).append(_resource_sample(record))
        else:
            warnings.append({"type": "resource_actor_missing", "record_id": record["record_id"]})

    actors: dict[str, dict] = {}
    for actor, samples in samples_by_actor.items():
        samples = _sort_samples(samples)
        first = samples[0]
        actors[actor] = {
            "actor": actor,
            "actor_type": first.get("actor_type"),
            "samples": samples,
            "profile": _resource_profile(samples),
            "gaps": _resource_gaps(samples, opts),
            "availability": _availability_counts(samples),
        }
    return actors


def _resource_sample(record: dict) -> dict:
    attributes = record["attributes"]
    sample = {metric: attributes.get(metric) for metric in RESOURCE_METRICS}
    sample.update({field: attributes.get(field) for field in RESOURCE_EVIDENCE})
    sample.update(
        {
            "actor": attributes.get("actor"),
            "actor_type": attributes.get("actor_type"),
            "ticket": attributes.get("ticket"),
            "availability": attributes.get("availability") or "unavailable",
            "unavailable_reason": attributes.get("unavailable_reason"),
            "process_count": attributes.get("process_count"),
            "partial_fields": attributes.get("partial_fields") or [],
            "timestamp": record["timestamp_iso"],
            "timestamp_ms": record["timestamp_ms"],
            "boot_id": record["boot_id"],
            "record_id": record["record_id"],
        }
    )
    return sample


def _resource_profile(samples: list[dict]) -> dict:
    profile: dict[str, dict] = {}
    for metric in RESOURCE_METRICS:
        values = [sample[metric] for sample in samples if isinstance(sample.get(metric), (int, float))]
        if values:
            profile[metric] = _statistics(values)
    return profile


def _statistics(values: list[float]) -> dict:
    sorted_values = sorted(values)
    count = len(sorted_values)
    midpoint = count // 2
    if count % 2 == 1:
        median = sorted_values[midpoint]
    else:
        median = (sorted_values[midpoint - 1] + sorted_values[midpoint]) / 2
    p95_index = max(math.ceil(0.95 * count) - 1, 0)
    return {
        "count": count,
        "min": sorted_values[0],
        "mean": sum(sorted_values) / count,
        "median": median,
        "p95": sorted_values[p95_index],
        "max": sorted_values[-1],
    }


def _resource_gaps(samples: list[dict], opts: dict) -> list[dict]:
    interval_ms = opts.get("sample_interval_ms", DEFAULT_SAMPLE_INTERVAL_MS)
    threshold_ms = opts.get(
        "sample_gap_threshold_ms", int(interval_ms * DEFAULT_GAP_THRESHOLD_MULTIPLIER)
    )
    gaps: list[dict] = []
    by_boot: dict[str, list[dict]] = {}
    for sample in samples:
        by_boot.setdefault(sample["boot_id"], []).append(sample)

    for boot_id, boot_samples in by_boot.items():
        ordered = sorted(boot_samples, key=lambda sample: sample["timestamp_ms"])
        for previous, current in zip(ordered, ordered[1:]):
            duration_ms = current["timestamp_ms"] - previous["timestamp_ms"]
            if duration_ms > threshold_ms:
                gaps.append(
                    {
                        "boot_id": boot_id,
                        "start_at": previous["timestamp"],
                        "end_at": current["timestamp"],
                        "duration_ms": duration_ms,
                        "expected_interval_ms": interval_ms,
                    }
                )
    gaps.sort(key=lambda gap: (gap.get("start_at", ""), gap.get("boot_id", "")))
    return gaps


def _availability_counts(samples: list[dict]) -> dict:
    measured = sum(1 for sample in samples if sample["availability"] == "measured")
    return {"measured": measured, "unavailable": len(samples) - measured}


def _sort_samples(samples: list[dict]) -> list[dict]:
    return sorted(
        samples,
        key=lambda sample: (
            sample["timestamp_ms"],
            sample["boot_id"],
            sample["record_id"],
        ),
    )


def _rescope_actors(actors: dict, boot_id: str) -> dict:
    scoped: dict[str, dict] = {}
    for key, actor in actors.items():
        samples = [sample for sample in actor["samples"] if sample["boot_id"] == boot_id]
        if not samples:
            continue
        scoped[key] = {
            "actor": actor["actor"],
            "actor_type": actor["actor_type"],
            "samples": samples,
            "profile": _resource_profile(samples),
            "gaps": _resource_gaps(samples, {}),
            "availability": _availability_counts(samples),
        }
    return scoped


# --- tickets ---------------------------------------------------------------


def _reduce_tickets(records: list[dict], opts: dict) -> tuple[dict, list[dict]]:
    events: list[dict] = []
    for record in records:
        if record["kind"] == "lifecycle":
            event = _lifecycle_event(record)
            if event is not None:
                events.append(event)
    events.sort(key=lambda event: (event["timestamp_ms"], event["boot_id"], event["sequence"]))

    events_by_ticket: dict[str, list[dict]] = {}
    for event in events:
        events_by_ticket.setdefault(event["ticket"], []).append(event)

    findings = _review_findings(events_by_ticket, opts)
    findings_by_ticket: dict[str, list[dict]] = {}
    for finding in findings:
        findings_by_ticket.setdefault(finding["ticket"], []).append(finding)

    tickets: dict[str, dict] = {}
    for ticket, ticket_events in events_by_ticket.items():
        tickets[ticket] = {
            "ticket": ticket,
            "complexity": _dispatch_complexity(ticket_events),
            "events": ticket_events,
            "intervals": _lifecycle_intervals(ticket_events),
            "findings": findings_by_ticket.get(ticket, []),
        }
    return tickets, findings


def _lifecycle_event(record: dict) -> dict | None:
    attributes = record["attributes"]
    ticket = attributes.get("ticket")
    event = attributes.get("event")
    boundary = attributes.get("boundary")
    if not (isinstance(ticket, str) and ticket and isinstance(event, str) and event and boundary in BOUNDARIES):
        return None
    return {
        "ticket": ticket,
        "event": event,
        "boundary": boundary,
        "attempt_id": attributes.get("attempt_id"),
        "operation_id": attributes.get("operation_id"),
        "outcome": attributes.get("outcome"),
        "command_class": attributes.get("command_class"),
        "cause": attributes.get("cause"),
        "complexity": _normalize_complexity(attributes.get("complexity")),
        "source": attributes.get("source"),
        "source_id": attributes.get("source_id"),
        "segment_continuation": attributes.get("segment_continuation"),
        # Backend / worker_host identify the model+provider a ticket ran on.
        # Lifecycle attributes carry them; surfacing them here lets the Executor
        # tools and the dashboard report model/provider per ticket.
        "backend": attributes.get("backend"),
        "worker_host": attributes.get("worker_host"),
        "timestamp": record["timestamp_iso"],
        "timestamp_ms": record["timestamp_ms"],
        "boot_id": record["boot_id"],
        "sequence": record["sequence"],
        "record_id": record["record_id"],
    }


def _normalize_complexity(value: Any) -> int | None:
    if isinstance(value, int) and value in range(1, 6):
        return value
    if isinstance(value, str):
        try:
            parsed = int(value)
            if parsed in range(1, 6):
                return parsed
        except ValueError:
            return None
    return None


def _dispatch_complexity(events: list[dict]) -> int | None:
    for event in events:
        if event["event"] == "dispatch" and isinstance(event["complexity"], int):
            return event["complexity"]
    return None


def _lifecycle_intervals(events: list[dict]) -> list[dict]:
    intervals: list[dict] = []
    open_intervals: dict[tuple, dict] = {}

    for event in events:
        key = _lifecycle_pair_key(event)
        if event["boundary"] == "start":
            if event.get("segment_continuation") == "open" and key in open_intervals:
                continue
            open_intervals[key] = event
        elif event["boundary"] == "end":
            if event.get("segment_continuation") == "close":
                continue
            started = open_intervals.pop(key, None)
            if started is None:
                intervals.append(_point_interval(event, "orphan_end"))
            else:
                intervals.append(_closed_interval(started, event))
        else:  # point
            intervals.append(_point_interval(event, "point"))

    for event in open_intervals.values():
        intervals.append(_open_interval(event))

    intervals.sort(key=lambda interval: (interval["start_ms"], interval.get("phase", ""), interval.get("operation_id") or ""))
    return intervals


def _lifecycle_pair_key(event: dict) -> tuple:
    return (event["attempt_id"], event["event"], event["operation_id"])


def _interval_base(event: dict) -> dict:
    return {
        "ticket": event["ticket"],
        "phase": event["event"],
        "attempt_id": event["attempt_id"],
        "operation_id": event["operation_id"],
        "command_class": event["command_class"],
        "complexity": event["complexity"],
        "cause": event["cause"],
        "source_id": event["source_id"],
        "start_at": event["timestamp"],
        "start_ms": event["timestamp_ms"],
    }


def _closed_interval(started: dict, finished: dict) -> dict:
    interval = _interval_base(started)
    interval.update(
        {
            "status": "closed",
            "end_at": finished["timestamp"],
            "end_ms": finished["timestamp_ms"],
            "duration_ms": max(finished["timestamp_ms"] - started["timestamp_ms"], 0),
            "outcome": finished.get("outcome") or started.get("outcome"),
        }
    )
    return interval


def _point_interval(event: dict, status: str) -> dict:
    interval = _interval_base(event)
    interval.update(
        {
            "status": status,
            "end_at": None,
            "end_ms": None,
            "duration_ms": None,
            "outcome": event.get("outcome"),
        }
    )
    return interval


def _open_interval(event: dict) -> dict:
    interval = _interval_base(event)
    interval.update(
        {
            "status": "open",
            "end_at": None,
            "end_ms": None,
            "duration_ms": None,
            "outcome": event.get("outcome"),
        }
    )
    return interval


def _review_findings(events_by_ticket: dict, opts: dict) -> list[dict]:
    grace_seconds = opts.get("review_resume_grace_seconds", DEFAULT_REVIEW_RESUME_GRACE_SECONDS)
    now = opts.get("now") or datetime.now(timezone.utc)
    if isinstance(now, str):
        now = _parse_timestamp(now) or datetime.now(timezone.utc)

    findings: list[dict] = []
    for ticket, events in events_by_ticket.items():
        for comment in events:
            if comment["event"] != "comment_received":
                continue
            finding = _review_finding(ticket, events, comment, now, grace_seconds)
            if finding is not None:
                findings.append(finding)
    findings.sort(key=lambda finding: (finding["comment_at"], finding["ticket"]))
    return findings


def _review_finding(ticket: str, events: list[dict], comment: dict, now: datetime, grace_seconds: int) -> dict | None:
    review_pause = _active_review_pause(events, comment)
    if review_pause is None:
        return None

    window, closing_event = _response_window(events, comment)
    rework_indexes = [index for index, event in enumerate(window) if event["event"] == "rework_start"]
    rework = bool(rework_indexes)
    resume_after_rework = bool(rework_indexes and any(
        event["event"] == "agent_resume" for event in window[rework_indexes[0] + 1 :]
    ))

    terminal = closing_event is not None and closing_event["event"] == "pr_merged"
    missing: list[str] = []
    if not rework:
        missing.append("rework_start")
    if not resume_after_rework:
        missing.append("agent_resume")

    from datetime import timedelta

    deadline = comment_datetime(comment) + timedelta(seconds=grace_seconds)
    if not missing:
        status = "resolved"
    elif terminal:
        status = "closed"
    elif now < deadline:
        status = "pending"
    else:
        status = "broken"

    return {
        "type": "review_pause_resume",
        "ticket": ticket,
        "status": status,
        "review_pause_at": review_pause["timestamp"],
        "comment_at": comment["timestamp"],
        "comment_source_id": comment["source_id"],
        "grace_deadline": deadline.isoformat().replace("+00:00", "Z"),
        "missing": missing,
    }


def comment_datetime(event: dict) -> datetime:
    parsed = _parse_timestamp(event["timestamp"])
    return parsed or datetime.now(timezone.utc)


def _active_review_pause(events: list[dict], comment: dict) -> dict | None:
    prior = [event for event in events if event["timestamp_ms"] < comment["timestamp_ms"]]
    prior.reverse()
    window: list[dict] = []
    for event in prior:
        if event["event"] in ("pr_merged", "agent_resume"):
            break
        window.append(event)
    for event in window:
        if event["event"] == "review_pause":
            return event
    return None


def _response_window(events: list[dict], comment: dict) -> tuple[list[dict], dict | None]:
    window: list[dict] = []
    closing_event: dict | None = None
    for event in events:
        if event["timestamp_ms"] <= comment["timestamp_ms"]:
            continue
        if event["event"] in ("review_pause", "pr_merged"):
            closing_event = event
            break
        window.append(event)
    return window, closing_event


def _rescope_tickets(tickets: dict, boot_id: str) -> tuple[dict, list[dict]]:
    scoped: dict[str, dict] = {}
    findings: list[dict] = []
    for ticket_id, ticket in tickets.items():
        events = [event for event in ticket["events"] if _in_boot(event, boot_id)]
        if not events:
            continue
        findings.extend(ticket.get("findings", []))
        scoped[ticket_id] = {
            "ticket": ticket["ticket"],
            "complexity": ticket["complexity"],
            "events": events,
            "intervals": _lifecycle_intervals(events),
            "findings": ticket.get("findings", []),
        }
    return scoped, findings


# ---------------------------------------------------------------------------
# Materialization
# ---------------------------------------------------------------------------


def write_run_summary(state_node: str | Any, dataset: dict, boot_id: str, opts: dict | None = None) -> str | None:
    """Materialize one boot's run-summary.json into the state node. Returns the path."""
    summary = boot_summary(dataset, boot_id, opts)
    from pathlib import Path

    target = sources.run_summary_path(Path(state_node), boot_id)
    target.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(target, json.dumps(summary, indent=2) + "\n")
    return str(target)


def write_all_run_summaries(state_node: str | Any, dataset: dict, boot_ids: list[str], opts: dict | None = None) -> list[str]:
    """Materialize run-summaries for every boot present in the dataset."""
    written: list[str] = []
    for boot_id in sorted(set(boot_ids)):
        path = write_run_summary(state_node, dataset, boot_id, opts)
        if path:
            written.append(path)
    return written


def build_summary_for(state_node: str | Any, dataset: dict, slug: str, build_order: dict, opts: dict | None = None) -> str | None:
    """Materialize one build order's cross-boot rollup into the state node.

    The rollup aggregates every boot touching a member ticket into the same
    dataset shape, so both the dashboard and Executor tools can render one
    build order across sessions. This is the first real writer for the
    ``RepoBase.builds_path/1`` directory (``<state-node>/builds/<slug>/``).
    """
    member_numbers = _build_order_member_numbers(build_order)
    summary = _rollup_build(dataset, build_order, member_numbers, opts or {})
    from pathlib import Path

    target = sources.build_summary_path(Path(state_node), slug)
    target.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(target, json.dumps(summary, indent=2) + "\n")
    return str(target)


def _build_order_member_numbers(build_order: dict) -> set[str]:
    numbers: set[str] = set()
    for ticket in build_order.get("tickets", []) or []:
        number = ticket.get("ticket")
        if isinstance(number, int) or (isinstance(number, str) and number):
            numbers.add(str(number))
    return numbers


def _rollup_build(dataset: dict, build_order: dict, member_numbers: set[str], opts: dict | None = None) -> dict:
    """Aggregate the full dataset (every boot) scoped to build-order members."""
    opts = opts or {}
    records = [record for record in dataset["records"] if _record_is_member(record, member_numbers)]
    actor_keys = {
        key for key, actor in dataset["actors"].items() if any(
            (sample.get("ticket") or "") in member_numbers for sample in actor["samples"]
        )
    }
    actors = {key: dataset["actors"][key] for key in actor_keys}
    tickets = {
        ticket_id: ticket for ticket_id, ticket in dataset["tickets"].items() if ticket_id in member_numbers
    }
    findings = [finding for finding in dataset["findings"] if finding.get("ticket") in member_numbers]
    source_files = sorted({record["source_path"] for record in records})

    provenance = dict(dataset["provenance"])
    provenance.update(
        {
            "inputs": provenance.get("inputs", []),
            "files": source_files,
            "time_range": _time_range(records),
            "record_count": len(records),
            "enrich": bool(opts.get("github_events")) or provenance.get("enrich", False),
            "generated_by": "analytics/reduce --build",
        }
    )
    return {
        "schema_version": SUMMARY_SCHEMA_VERSION,
        "boot_id": "build:%s" % (build_order.get("build_order_id") or "unknown"),
        "generated_at": _now_iso(opts),
        "source_files": source_files,
        "source_bytes": dataset.get("_source_bytes", 0),
        "records": records,
        "restarts": [record for record in dataset["restarts"] if _record_is_member(record, member_numbers)],
        "actors": actors,
        "tickets": tickets,
        "findings": findings,
        "warnings": [warning for warning in dataset["warnings"]],
        "provenance": provenance,
        "build_order": {
            "id": build_order.get("build_order_id"),
            "title": build_order.get("title"),
            "root_number": build_order.get("root_number"),
            "member_count": len(member_numbers),
            "members": [
                {
                    "id": ticket.get("id"),
                    "title": ticket.get("title"),
                    "lane": ticket.get("lane"),
                    "phase": ticket.get("phase"),
                    "complexity": ticket.get("complexity"),
                    "ticket": ticket.get("ticket"),
                }
                for ticket in build_order.get("tickets", []) or []
            ],
        },
    }


def _record_is_member(record: dict, member_numbers: set[str]) -> bool:
    ticket = record["attributes"].get("ticket")
    return isinstance(ticket, str) and ticket in member_numbers


def _atomic_write(path: Any, contents: str) -> None:
    import os
    import tempfile

    from pathlib import Path

    target = Path(path)
    directory = target.parent
    fd, temporary = tempfile.mkstemp(prefix=".%s." % target.name, dir=str(directory))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(contents)
        os.replace(temporary, str(target))
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
