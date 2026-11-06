"""Render the published Build Order review from one ``build-order.v1`` document.

Every section reads the document and nothing else: waves, typed edges, critical
path, progress, epics, features and lanes arrive already computed by the daemon
or by the pack walk. The renderer never recomputes a graph fact, so the review a
skill publishes and the review the dashboard draws describe one graph.

Sections whose producer is absent are omitted instead of left half-filled, and
an unknown source publishes an explicit notice — never an empty dependency
table and never a 0% bar.
"""

from __future__ import annotations

from typing import Any

from publication_graph_document import (
    DOCUMENT_DAEMON,
    DOCUMENT_PACK_WALK,
    document_source,
    edges_of,
    waves_by_ticket,
)


def render_review(document: dict[str, Any]) -> str:
    """Render the whole review body for one ``build-order.v1`` document."""
    title = document.get("title") or document.get("build_order_id") or "Build Order"
    blocks = [f"# Build Order review: {title}", _source_block(document)]
    waves = _waves_block(document)
    if waves:
        blocks.append(waves)
    dependencies = _dependencies_block(document)
    if dependencies:
        blocks.append(dependencies)
    critical = _critical_path_block(document)
    if critical:
        blocks.append(critical)
    blocks.append(_progress_block(document))
    gates = _gates_block(document)
    if gates:
        blocks.append(gates)
    features = _features_block(document)
    if features:
        blocks.append(features)
    lanes = _lanes_block(document)
    if lanes:
        blocks.append(lanes)
    return "\n\n".join(blocks).rstrip() + "\n"


def review_source_line(document: dict[str, Any]) -> str:
    """One line naming the path that produced the document under review."""
    if document_source(document) == DOCUMENT_PACK_WALK:
        return "Document source: pack walk (no daemon)."
    return "Document source: published daemon document."


def render_unknown_notice(
    reason: object, *, subject: str, status: object = "unknown",
) -> str:
    """Render an explicit notice for one fact set the document cannot state."""
    detail = reason if isinstance(reason, str) and reason.strip() else "no reason published"
    label = status if isinstance(status, str) and status else "unknown"
    return f"> {subject} is {label}: {detail}."


def _source_block(document: dict[str, Any]) -> str:
    sources = document.get("sources") or {}
    rows = ["| Source | Status | Detail |", "| --- | --- | --- |"]
    for name in ("pack", "tracker", "progress"):
        source = sources.get(name) if isinstance(sources, dict) else None
        status = "unknown"
        detail = ""
        if isinstance(source, dict):
            status = source.get("status") or "unknown"
            detail = source.get("reason") or source.get("observed_at") or ""
        rows.append(f"| {name} | {status} | {_cell(detail)} |")
    return "\n".join([review_source_line(document), "", "## Sources", "", *rows])


def _waves_block(document: dict[str, Any]) -> str:
    waves = [
        wave for wave in document.get("waves") or []
        if isinstance(wave, dict) and isinstance(wave.get("tickets"), list)
    ]
    if not waves:
        return ""
    tickets = waves_by_ticket(document)
    rows = ["| Wave | Tickets |", "| ---: | --- |"]
    for wave in waves:
        index = wave.get("index")
        rows.append(
            f"| {index} | {_cell(', '.join(str(item) for item in wave['tickets']) or 'none')} |"
        )
    lead = (
        f"{len(waves)} waves across {len(tickets)} tickets, ordered by the "
        "longest dependency path."
    )
    return "\n".join(["## Waves", "", lead, "", *rows])


def _dependencies_block(document: dict[str, Any]) -> str:
    sources = document.get("sources") or {}
    tracker = sources.get("tracker") if isinstance(sources, dict) else None
    status = tracker.get("status") if isinstance(tracker, dict) else "unknown"
    edges = edges_of(document, "depends_on")
    if status != "known":
        reason = tracker.get("reason") if isinstance(tracker, dict) else None
        return "\n".join([
            "## Dependencies",
            "",
            render_unknown_notice(reason, subject="Blocking state", status=status),
            "",
            "The published edges are not tracker truth; an unread tracker is never an unblocked graph.",
        ])
    if not edges:
        return "\n".join([
            "## Dependencies", "", "No hard dependencies are published for this Build Order.",
        ])
    rows = ["| Ticket | Depends on | State |", "| --- | --- | --- |"]
    for edge in sorted(
        edges, key=lambda item: (str(item.get("from")), str(item.get("to"))),
    ):
        rows.append(
            f"| {edge.get('from')} | {edge.get('to')} | {edge.get('state') or 'unknown'} |"
        )
    return "\n".join([
        "## Dependencies",
        "",
        f"{len(edges)} published hard dependencies.",
        "",
        *rows,
    ])


def _critical_path_block(document: dict[str, Any]) -> str:
    critical = document.get("critical_path")
    if not isinstance(critical, dict):
        return ""
    if critical.get("status") != "known":
        return "\n".join([
            "## Critical path",
            "",
            render_unknown_notice(
                critical.get("reason"),
                subject="The critical path",
                status=critical.get("status"),
            ),
        ])
    path = [item for item in critical.get("tickets") or [] if isinstance(item, str)]
    if not path:
        return "\n".join([
            "## Critical path", "", "No dependency chain is published for this Build Order.",
        ])
    detail = f" ({critical['hours']} hours)" if isinstance(
        critical.get("hours"), (int, float)
    ) else ""
    return "\n".join([
        "## Critical path",
        "",
        "`" + " → ".join(path) + f"`{detail}",
    ])


def _progress_block(document: dict[str, Any]) -> str:
    progress = document.get("progress") if isinstance(
        document.get("progress"), dict
    ) else {}
    if progress.get("status") != "known":
        return "\n".join([
            "## Progress",
            "",
            render_unknown_notice(
                progress.get("reason"),
                subject="Progress",
                status=progress.get("status"),
            ),
        ])
    total = progress.get("total")
    done = progress.get("done")
    percent = progress.get("percent")
    parts = []
    if type(done) is int and type(total) is int:
        parts.append(f"{done} of {total} complete")
    if type(percent) is int:
        parts.append(f"{percent}%")
    line = ", ".join(parts) or "Counts are published without a total."
    return "\n".join(["## Progress", "", line + "."])


def _gates_block(document: dict[str, Any]) -> str:
    gate_edges = edges_of(document, "gates")
    gates = [
        gate for gate in document.get("gates") or []
        if isinstance(gate, dict) and isinstance(gate.get("key"), str)
    ]
    if not gates:
        return ""
    blocked_by_gate: dict[str, list[str]] = {}
    for edge in gate_edges:
        blocked_by_gate.setdefault(str(edge.get("to")), []).append(str(edge.get("from")))
    rows = ["| Gate | Title | Status | Blocks |", "| --- | --- | --- | --- |"]
    for gate in gates:
        blocked = sorted(blocked_by_gate.get(gate["key"], []))
        rows.append(
            f"| {gate['key']} | {_cell(gate.get('title') or '')} | "
            f"{gate.get('status') or 'unknown'} | {_cell(', '.join(blocked) or 'none')} |"
        )
    return "\n".join([
        "## Gates", "", "Gates the pack records as external approvals.", "", *rows,
    ])


def _features_block(document: dict[str, Any]) -> str:
    features = [
        feature for feature in document.get("features") or []
        if isinstance(feature, dict) and isinstance(feature.get("key"), str)
    ]
    if not features:
        return ""
    rows = ["| Feature | Epic | Tickets |", "| --- | --- | ---: |"]
    for feature in features:
        count = sum(
            1 for ticket in document.get("tickets") or []
            if isinstance(ticket, dict) and ticket.get("feature") == feature["key"]
        )
        rows.append(
            f"| {_cell(feature.get('title') or feature['key'])} | "
            f"{feature.get('epic') or 'none'} | {count} |"
        )
    return "\n".join(["## Features", "", *rows])


def _lanes_block(document: dict[str, Any]) -> str:
    lanes = [
        lane for lane in document.get("lanes") or []
        if isinstance(lane, dict) and isinstance(lane.get("key"), str)
    ]
    if not lanes:
        return ""
    rows = ["| Lane | Label | Tickets |", "| --- | --- | ---: |"]
    for lane in lanes:
        count = sum(
            1 for ticket in document.get("tickets") or []
            if isinstance(ticket, dict) and ticket.get("lane") == lane["key"]
        )
        rows.append(
            f"| {_cell(lane.get('title') or lane['key'])} | "
            f"{lane.get('label') or 'none'} | {count} |"
        )
    return "\n".join(["## Lanes", "", *rows])


def _cell(value: object) -> str:
    text = value if isinstance(value, str) else ""
    return text.replace("|", "\\|").replace("\n", " ").strip()
