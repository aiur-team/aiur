"""Build-order retrospective report rendering (rows and text)."""

from __future__ import annotations

from .render import (
    _display,
    _duration_display,
    ci_cycles,
    cpu_seconds,
    rework_count,
    ticket_active_ms,
    ticket_backends,
    ticket_status,
    ticket_wall_clock_ms,
)


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
