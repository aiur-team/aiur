"""Assert the reviewed graph facts against the pack before a review publishes.

``validation_graph.py`` owns the pack's typed edges, hierarchy, dependency
closure and phase leveling. The review no longer recomputes those facts, so the
document it renders has to be checked against them: a pack that produces a
document disagreeing with its own graph fails here instead of publishing a
review that contradicts the plan.
"""

from __future__ import annotations

from typing import Any

from publication_graph_document import (
    edges_of,
    pack_tickets,
    waves_by_ticket,
)


def check_document_against_pack(
    build: object, document: dict[str, Any], report: Any,
) -> bool:
    """Return whether the document states exactly the pack's graph facts."""
    before = len(report.errors)
    tickets = pack_tickets(build)
    assert isinstance(build, dict)
    _check_ticket_set(tickets, document, report)
    _check_dependency_edges(tickets, document, report)
    _check_waves(tickets, document, report)
    _check_critical_path(document, report)
    _check_hierarchy(tickets, document, report)
    _check_gates(build, tickets, document, report)
    _check_grouping(document, report)
    _check_unknown_sources(document, report)
    return len(report.errors) == before


def _check_ticket_set(
    tickets: dict[str, dict[str, Any]], document: dict[str, Any], report: Any,
) -> None:
    published = {
        ticket["id"] for ticket in document.get("tickets") or []
        if isinstance(ticket, dict) and isinstance(ticket.get("id"), str)
    }
    for ticket_id in sorted(set(tickets) - published):
        report.error(f"review document: ticket {ticket_id} is missing from the document")
    for ticket_id in sorted(published - set(tickets)):
        report.error(f"review document: ticket {ticket_id} is not in the pack")
    root_id = document.get("root")
    build_order_id = root_id.get("id") if isinstance(root_id, dict) else None
    if build_order_id != document.get("build_order_id"):
        report.error(
            "review document: root.id and build_order_id must name the same Build Order"
        )


def _check_dependency_edges(
    tickets: dict[str, dict[str, Any]], document: dict[str, Any], report: Any,
) -> None:
    expected = {
        (ticket_id, dependency)
        for ticket_id, ticket in tickets.items()
        for dependency in _strings(ticket.get("depends_on"))
        if dependency in tickets
    }
    published = {
        (edge.get("from"), edge.get("to"))
        for edge in edges_of(document, "depends_on")
        if edge.get("source") == "pack"
    }
    for edge_from, edge_to in sorted(expected - published):
        report.error(
            f"review document: dependency {edge_from} -> {edge_to} is missing from the document"
        )
    for edge_from, edge_to in sorted(published - expected):
        report.error(
            f"review document: dependency {edge_from} -> {edge_to} is not in the pack"
        )
        if (edge_to, edge_from) in expected:
            report.error(
                f"review document: dependency {edge_from} -> {edge_to} is reversed"
            )


def _check_waves(
    tickets: dict[str, dict[str, Any]], document: dict[str, Any], report: Any,
) -> None:
    wave_of = waves_by_ticket(document)
    for ticket_id in sorted(set(tickets) - set(wave_of)):
        report.error(
            f"review document: ticket {ticket_id} has no published wave"
        )
    for ticket in _objects(document.get("tickets")):
        published = ticket.get("wave")
        expected = wave_of.get(ticket.get("id"))
        if type(published) is int and expected is not None and published != expected:
            report.error(
                f"review document: ticket {ticket.get('id')} states wave "
                f"{published} but is published in wave {expected}"
            )
    for edge in edges_of(document, "depends_on"):
        dependent, blocker = edge.get("from"), edge.get("to")
        if dependent not in wave_of or blocker not in wave_of:
            continue
        if wave_of[dependent] <= wave_of[blocker]:
            report.error(
                f"review document: wave {wave_of[dependent]} for {dependent} is not "
                f"after wave {wave_of[blocker]} for its dependency {blocker}"
            )


def _check_critical_path(document: dict[str, Any], report: Any) -> None:
    critical = document.get("critical_path")
    if not isinstance(critical, dict) or critical.get("status") != "known":
        return
    path = [item for item in critical.get("tickets") or [] if isinstance(item, str)]
    if not path:
        report.error("review document: a known critical path must name its tickets")
        return
    edges = {
        (edge.get("from"), edge.get("to"))
        for edge in edges_of(document, "depends_on")
    }
    for first, second in zip(path, path[1:]):
        if (first, second) not in edges:
            report.error(
                f"review document: critical path {first} -> {second} is not a "
                "published dependency"
            )


def _check_hierarchy(
    tickets: dict[str, dict[str, Any]], document: dict[str, Any], report: Any,
) -> None:
    expected = {
        (ticket_id, child)
        for ticket_id, ticket in tickets.items()
        for child in _strings(ticket.get("contains"))
        if child in tickets
    }
    published = {
        (edge.get("from"), edge.get("to"))
        for edge in edges_of(document, "contains")
    }
    for edge_from, edge_to in sorted(expected - published):
        report.error(
            f"review document: containment {edge_from} -> {edge_to} is missing "
            "from the document"
        )
    for edge_from, edge_to in sorted(published - expected):
        report.error(
            f"review document: containment {edge_from} -> {edge_to} is not in the pack"
        )


def _check_gates(
    build: dict[str, Any], tickets: dict[str, dict[str, Any]],
    document: dict[str, Any], report: Any,
) -> None:
    gates = build.get("external_gates")
    expected = {
        gate.get("id") for gate in gates or []
        if isinstance(gate, dict) and isinstance(gate.get("id"), str)
    }
    published = {
        gate.get("key") for gate in document.get("gates") or []
        if isinstance(gate, dict) and isinstance(gate.get("key"), str)
    }
    for gate_id in sorted(expected - published):
        report.error(f"review document: gate {gate_id} is missing from the document")
    for gate_id in sorted(published - expected):
        report.error(f"review document: gate {gate_id} is not in the pack")
    expected_edges = {
        (ticket_id, gate)
        for ticket_id, ticket in tickets.items()
        for gate in _strings(ticket.get("external_gates"))
        if gate in expected
    }
    published_edges = {
        (edge.get("from"), edge.get("to")) for edge in edges_of(document, "gates")
    }
    for edge_from, edge_to in sorted(expected_edges - published_edges):
        report.error(
            f"review document: gate edge {edge_from} -> {edge_to} is missing "
            "from the document"
        )
    for edge_from, edge_to in sorted(published_edges - expected_edges):
        report.error(
            f"review document: gate edge {edge_from} -> {edge_to} is not in the pack"
        )


def _check_grouping(document: dict[str, Any], report: Any) -> None:
    epics = {item.get("key") for item in _objects(document.get("epics"))}
    features = {item.get("key") for item in _objects(document.get("features"))}
    lanes = {item.get("key") for item in _objects(document.get("lanes"))}
    for feature in _objects(document.get("features")):
        if feature.get("epic") not in epics:
            report.error(
                f"review document: feature {feature.get('key')} names an epic "
                "the document does not publish"
            )
    for ticket in _objects(document.get("tickets")):
        lane = ticket.get("lane")
        if lane is not None and lane not in lanes:
            report.error(
                f"review document: ticket {ticket.get('id')} names a lane "
                "the document does not publish"
            )
        feature = ticket.get("feature")
        if feature is not None and feature not in features:
            report.error(
                f"review document: ticket {ticket.get('id')} names a feature "
                "the document does not publish"
            )


def _check_unknown_sources(document: dict[str, Any], report: Any) -> None:
    sources = document.get("sources")
    tracker = sources.get("tracker") if isinstance(sources, dict) else None
    if not isinstance(tracker, dict) or tracker.get("status") == "known":
        return
    for edge in edges_of(document, "depends_on"):
        if edge.get("state") != "unknown":
            report.error(
                f"review document: dependency {edge.get('from')} -> {edge.get('to')} "
                "claims a blocking state while the tracker source is unknown"
            )


def _objects(value: object) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def _strings(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]
