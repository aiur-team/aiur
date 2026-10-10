"""Tickets: lifecycle events, interval pairing and review-finding diagnostics."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from .parse import _in_boot, _parse_timestamp

BOUNDARIES = ("start", "end", "point")
DEFAULT_REVIEW_RESUME_GRACE_SECONDS = 300


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
