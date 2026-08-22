"""Text rendering of run summaries and build-order retrospective reports.

The build-report is the retrospective number-fetcher: it computes, from one
materialized build rollup (or the reduced stream), per-member merged/closed/open
status, wall-clock and active time across every boot that touched the member,
CI cycles, rework count, and CPU-seconds spend — the numbers an Executor needs
to write an hourly retrospective without hand-counting merges or eyeballing CI
logs.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

# Cost is expressed in CPU-seconds, matching the design ("Cost per ticket" means
# CPU-seconds). Dollar spend is cost-report's job.
SAMPLE_SECONDS = 5


# ---------------------------------------------------------------------------
# Per-actor / per-ticket aggregation
# ---------------------------------------------------------------------------


def cpu_seconds(actor: dict) -> float:
    """CPU-seconds for one actor ≈ mean fraction of a core × sampled span."""
    profile = actor.get("profile") or {}
    cpu = profile.get("cpu_percent") or {}
    count = cpu.get("count", 0) or 0
    mean = cpu.get("mean", 0.0) or 0.0
    return round(mean / 100 * count * SAMPLE_SECONDS, 1)


def ticket_status(ticket: dict) -> str:
    """Status from the ticket's lifecycle intervals: merged/rework/paused/active."""
    phases = {interval.get("phase") for interval in ticket.get("intervals", [])}
    if "pr_merged" in phases:
        return "merged"
    if "rework_start" in phases:
        return "rework"
    if "agent_pause" in phases:
        return "paused"
    return "active"


def ticket_wall_clock_ms(ticket: dict) -> int | None:
    """Wall-clock span from dispatch (or earliest start) through latest boundary."""
    dispatch_ms = _first_event_ms(ticket, "dispatch")
    starts = [interval["start_ms"] for interval in ticket.get("intervals", []) if interval.get("start_ms") is not None]
    ends = []
    for interval in ticket.get("intervals", []):
        if interval.get("end_ms") is not None:
            ends.append(interval["end_ms"])
        if interval.get("start_ms") is not None:
            ends.append(interval["start_ms"])
    start_ms = dispatch_ms or (min(starts) if starts else None)
    end_ms = max(ends) if ends else None
    if start_ms is not None and end_ms is not None:
        return max(end_ms - start_ms, 0)
    return None


def ticket_active_ms(ticket: dict) -> int:
    """Active time = sum of closed interval durations (idle gaps elided)."""
    return sum(
        interval["duration_ms"]
        for interval in ticket.get("intervals", [])
        if interval.get("status") == "closed" and isinstance(interval.get("duration_ms"), (int, float))
    )


def ci_cycles(ticket: dict) -> list[dict]:
    """CI cycles = closed build_test intervals, with outcomes."""
    cycles = []
    for interval in ticket.get("intervals", []):
        if interval.get("phase") == "build_test" and interval.get("status") == "closed":
            cycles.append(
                {
                    "attempt_id": interval.get("attempt_id"),
                    "operation_id": interval.get("operation_id"),
                    "command_class": interval.get("command_class"),
                    "outcome": interval.get("outcome"),
                    "start_at": interval.get("start_at"),
                    "end_at": interval.get("end_at"),
                    "duration_ms": interval.get("duration_ms"),
                }
            )
    return cycles


def rework_count(ticket: dict) -> int:
    return sum(1 for event in ticket.get("events", []) if event.get("event") == "rework_start")


def ticket_backends(ticket: dict) -> list[dict]:
    """Distinct (backend, worker_host) pairs observed across lifecycle events."""
    pairs: dict[tuple, dict] = {}
    for event in ticket.get("events", []):
        backend = event.get("backend")
        worker_host = event.get("worker_host")
        if not backend and not worker_host:
            continue
        key = (backend, worker_host)
        entry = pairs.setdefault(key, {"backend": backend, "worker_host": worker_host, "events": 0})
        entry["events"] += 1
    return sorted(pairs.values(), key=lambda entry: entry["events"], reverse=True)


def _first_event_ms(ticket: dict, event_name: str) -> int | None:
    for event in ticket.get("events", []):
        if event.get("event") == event_name and isinstance(event.get("timestamp_ms"), int):
            return event["timestamp_ms"]
    return None


# ---------------------------------------------------------------------------
# run-summary rendering
# ---------------------------------------------------------------------------


def run_summary_kpis(summary: dict, cap: int) -> dict:
    """Compute the run-summary headline numbers from one boot's dataset."""
    tickets = summary.get("tickets", {})
    merged = sum(1 for ticket in tickets.values() if ticket_status(ticket) == "merged")
    dispatched = sum(1 for ticket in tickets.values() if _first_event_ms(ticket, "dispatch") is not None)
    open_count = len(tickets) - merged

    agents = {key: actor for key, actor in summary.get("actors", {}).items() if _agent_key(key)}
    cpu_hours = round(sum(cpu_seconds(actor) for actor in agents.values()) / 3600, 1)

    pressure = fleet_pressure(summary, cap)
    peak_concurrency = pressure["peak_occupied"] or 0
    wasted_slot_hours = pressure["wasted_slot_hours"]

    top_cost = sorted(
        ((key, cpu_seconds(actor)) for key, actor in summary.get("actors", {}).items()),
        key=lambda pair: pair[1],
        reverse=True,
    )[:5]

    return {
        "boot_id": summary.get("boot_id"),
        "generated_at": summary.get("generated_at"),
        "records": len(summary.get("records", [])),
        "tickets": len(tickets),
        "dispatched": dispatched,
        "merged": merged,
        "open": open_count,
        "cpu_hours": cpu_hours,
        "peak_concurrency": peak_concurrency,
        "cap": cap,
        "wasted_slot_hours": round(wasted_slot_hours, 1),
        "fleet_pressure": pressure,
        "top_cost": top_cost,
        "provenance": summary.get("provenance", {}),
    }


def render_run_summary(summary: dict, cap: int = 10) -> str:
    kpis = run_summary_kpis(summary, cap)
    provenance = kpis["provenance"]

    lines = [
        "Run summary — boot %s" % kpis["boot_id"],
        "Generated: %s" % kpis["generated_at"],
        "",
        "Records:        %d" % kpis["records"],
        "Tickets:        %d (dispatched %d, merged %d, open %d)"
        % (kpis["tickets"], kpis["dispatched"], kpis["merged"], kpis["open"]),
        "CPU burned:     %.1f CPU-hours" % kpis["cpu_hours"],
        "Peak concurrency: %d of %d cap" % (kpis["peak_concurrency"], kpis["cap"]),
        "Wasted capacity: %.1f slot-hours" % kpis["wasted_slot_hours"],
        "",
        "Top cost (CPU-seconds):",
    ]
    if kpis["top_cost"]:
        for key, cost in kpis["top_cost"]:
            lines.append("  %-24s %.1f" % (_actor_label(key), cost))
    else:
        lines.append("  (no resource samples)")

    pressure = kpis["fleet_pressure"]
    lines.extend(["", "Fleet-wide build pressure:"])
    if pressure["legacy_fallback"]:
        lines.append("  Occupancy: CPU-derived legacy fallback (exact fleet samples unavailable)")
    else:
        lines.append(
            "  Peak occupied: %s; latest capacity: configured %s, max %s, effective %s"
            % (
                _display(pressure["peak_occupied"]),
                _display(pressure["latest_configured_capacity"]),
                _display(pressure["latest_max_capacity"]),
                _display(pressure["latest_effective_capacity"]),
            )
        )
    lines.append(
        "  Peak builds: active %s, queued %s; capacity %s; longest live wait: %s"
        % (
            _display(pressure["peak_active_builds"]),
            _display(pressure["peak_queued_builds"]),
            _display(pressure["latest_build_capacity"]),
            _duration_display(pressure["longest_wait_seconds"]),
        )
    )
    lines.append(
        "  Latest source observations: fleet %s; build %s"
        % (
            _timestamp_display(pressure["latest_fleet_observed_at_ms"]),
            _timestamp_display(pressure["latest_build_observed_at_ms"]),
        )
    )

    time_range = provenance.get("time_range")
    if time_range:
        lines.append("")
        lines.append("Time range: %s .. %s" % (time_range.get("start"), time_range.get("end")))
    source_files = provenance.get("files") or []
    if source_files:
        lines.append("Source files (%d): %s" % (len(source_files), ", ".join(source_files)))
    if provenance.get("enrich"):
        lines.append("Enriched: true (GitHub anchors applied)")
    return "\n".join(lines) + "\n"


def fleet_pressure(summary: dict, cap: int = 10) -> dict:
    """Return exact whole-host pressure, falling back only for legacy streams."""
    daemon = (summary.get("actors") or {}).get("_daemon") or {}
    samples = sorted(daemon.get("samples") or [], key=lambda sample: sample.get("timestamp_ms") or 0)
    fleet = [sample for sample in samples if sample.get("fleet_capacity_status") == "current"]
    build = [sample for sample in samples if sample.get("build_gate_status") in ("measured", "disabled", "partial")]

    if fleet:
        latest = fleet[-1]
        peak = _maximum(fleet, "fleet_agents_occupied")
        legacy_fallback = False
        wasted = _sampled_waste(fleet, cap)
    else:
        agents = {key: actor for key, actor in (summary.get("actors") or {}).items() if _agent_key(key)}
        peak, wasted = _concurrency(summary, agents, cap)
        latest = {}
        legacy_fallback = True

    latest_build = build[-1] if build else {}

    return {
        "peak_occupied": peak,
        "latest_configured_capacity": _number(latest.get("fleet_agents_configured")),
        "latest_max_capacity": _number(latest.get("fleet_agents_max")),
        "latest_effective_capacity": _number(latest.get("fleet_agents_effective")),
        "latest_build_capacity": _number(latest_build.get("build_gate_capacity")),
        "latest_fleet_observed_at_ms": _number(latest.get("fleet_capacity_observed_at_ms")),
        "latest_build_observed_at_ms": _number(latest_build.get("build_gate_observed_at_ms")),
        "peak_active_builds": _maximum(build, "build_gate_active"),
        "peak_queued_builds": _maximum(build, "build_gate_queued"),
        "longest_wait_seconds": _maximum(build, "build_queue_oldest_wait_seconds"),
        "wasted_slot_hours": wasted,
        "legacy_fallback": legacy_fallback,
    }


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _maximum(samples: list[dict], key: str):
    values = [_number(sample.get(key)) for sample in samples]
    values = [value for value in values if value is not None]
    return max(values, default=None)


def _sampled_waste(samples: list[dict], fallback_cap: int) -> float:
    bucket_hours = SAMPLE_SECONDS / 3600
    total = 0.0
    for sample in samples:
        occupied = _number(sample.get("fleet_agents_occupied"))
        capacity = _number(sample.get("fleet_agents_effective"))
        if occupied is not None:
            total += max((fallback_cap if capacity is None else capacity) - occupied, 0) * bucket_hours
    return total


def _display(value) -> str:
    return "unavailable" if value is None else str(value)


def _duration_display(value) -> str:
    numeric = _number(value)
    return "unavailable" if numeric is None else "%ss" % numeric


def _timestamp_display(value) -> str:
    numeric = _number(value)
    if numeric is None:
        return "unavailable"
    return datetime.fromtimestamp(numeric / 1000, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _concurrency(summary: dict, agents: dict, cap: int) -> tuple[int, float]:
    """Bucket agent samples on the 5s cadence; peak active agents + wasted slots."""
    buckets: dict[int, set[str]] = {}
    for key, actor in agents.items():
        for sample in actor.get("samples", []):
            if sample.get("availability") != "measured":
                continue
            cpu = sample.get("cpu_percent")
            if not (isinstance(cpu, (int, float)) and cpu > 0):
                continue
            bucket = sample["timestamp_ms"] // (SAMPLE_SECONDS * 1000)
            buckets.setdefault(bucket, set()).add(key)

    if not buckets:
        return 0, 0.0

    peak = max(len(active) for active in buckets.values())
    bucket_hours = SAMPLE_SECONDS / 3600
    wasted = sum(max(cap - len(active), 0) * bucket_hours for active in buckets.values())
    return peak, wasted


def _agent_key(key: str) -> bool:
    if key.startswith("ticket:"):
        return True
    return key not in ("_daemon", "_operator", "daemon", "operator", "executor")


def _actor_label(key: str) -> str:
    if key.startswith("ticket:"):
        return "#" + key[len("ticket:") :]
    return str(key)


# ---------------------------------------------------------------------------
# build-report rendering
# ---------------------------------------------------------------------------


def build_report_rows(build_summary: dict) -> list[dict]:
    """One row per build-order member, aggregated across every boot that touched it."""
    build_order = build_summary.get("build_order") or {}
    members = build_order.get("members") or []
    tickets = build_summary.get("tickets", {})

    rows = []
    for member in members:
        number = str(member.get("ticket"))
        ticket = tickets.get(number)
        if ticket is None:
            rows.append(
                {
                    "id": member.get("id"),
                    "ticket": number,
                    "title": member.get("title"),
                    "lane": member.get("lane"),
                    "phase": member.get("phase"),
                    "complexity": member.get("complexity"),
                    "status": "open",
                    "wall_clock_ms": None,
                    "active_ms": 0,
                    "ci_cycles": 0,
                    "ci_failed": 0,
                    "rework": 0,
                    "cpu_seconds": 0.0,
                    "backends": [],
                    "observed": False,
                }
            )
            continue

        cycles = ci_cycles(ticket)
        rows.append(
            {
                "id": member.get("id"),
                "ticket": number,
                "title": member.get("title"),
                "lane": member.get("lane"),
                "phase": member.get("phase"),
                "complexity": member.get("complexity"),
                "status": ticket_status(ticket),
                "wall_clock_ms": ticket_wall_clock_ms(ticket),
                "active_ms": ticket_active_ms(ticket),
                "ci_cycles": len(cycles),
                "ci_failed": sum(1 for cycle in cycles if cycle["outcome"] == "failed"),
                "rework": rework_count(ticket),
                "cpu_seconds": _ticket_cpu_seconds(build_summary, number),
                "backends": ticket_backends(ticket),
                "observed": True,
            }
        )

    rows.sort(key=lambda row: (row["wall_clock_ms"] is None, row["wall_clock_ms"] or 0))
    return rows


def _ticket_cpu_seconds(build_summary: dict, number: str) -> float:
    total = 0.0
    for key, actor in build_summary.get("actors", {}).items():
        if any((sample.get("ticket") or "") == number for sample in actor.get("samples", [])):
            total += cpu_seconds(actor)
    return round(total, 1)


def render_build_report(build_summary: dict, slug: str) -> str:
    build_order = build_summary.get("build_order") or {}
    rows = build_report_rows(build_summary)

    lines = [
        "Build report — %s (%s)" % (slug, build_order.get("title") or build_order.get("id") or "?"),
        "Generated: %s" % build_summary.get("generated_at"),
        "Members: %d" % len(rows),
        "",
    ]

    merged = sum(1 for row in rows if row["status"] == "merged")
    rework = sum(1 for row in rows if row["status"] == "rework")
    open_rows = [row for row in rows if row["status"] not in ("merged",)]
    total_cpu = round(sum(row["cpu_seconds"] for row in rows) / 3600, 1)
    total_ci = sum(row["ci_cycles"] for row in rows)
    total_rework = sum(row["rework"] for row in rows)

    lines.append("Merged: %d/%d   Rework: %d   Open: %d" % (merged, len(rows), rework, len(open_rows)))
    lines.append("CI cycles: %d total   Rework events: %d   CPU: %.1f CPU-hours" % (total_ci, total_rework, total_cpu))
    lines.append("")

    header = "%-8s %-28s %-9s %10s %10s %7s %7s %8s" % (
        "Ticket",
        "Title",
        "Status",
        "Wall-clock",
        "Active",
        "CI",
        "Rework",
        "CPU-sec",
    )
    lines.append(header)
    lines.append("-" * len(header))
    for row in rows:
        lines.append(
            "%-8s %-28s %-9s %10s %10s %7d %7d %8.1f"
            % (
                "#" + row["ticket"],
                (row["title"] or "")[:28],
                row["status"],
                _ms_hms(row["wall_clock_ms"]),
                _ms_hms(row["active_ms"]),
                row["ci_cycles"],
                row["rework"],
                row["cpu_seconds"],
            )
        )

    lines.append("")
    lines.append("Notes")
    lines.append("  - Wall-clock spans dispatch through the latest lifecycle boundary across every boot.")
    lines.append("  - Active time sums closed phase intervals (idle gaps elided).")
    lines.append("  - CI cycles are closed build_test intervals; failed counts red outcomes.")
    lines.append("  - CPU-seconds ≈ mean core fraction × sampled span. Dollar spend: analytics/cost-report.")
    return "\n".join(lines) + "\n"


def _ms_hms(ms: int | None) -> str:
    if ms is None:
        return "n/a"
    total_seconds = int(ms / 1000)
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return "%dh%02dm" % (hours, minutes)
    if minutes:
        return "%dm%02ds" % (minutes, seconds)
    return "%ds" % seconds
