"""The ``build-order.v1`` document the published Build Order review reads.

The review the skill publishes used to describe waves, dependency state,
critical path and progress from facts recomputed inside the skill. It now reads
those facts from one ``build-order.v1`` document, the same document the
dashboard renders, so the GitHub review and the dashboard review cannot
describe different graphs.

Two document sources exist and the caller names the one it used:

``DOCUMENT_DAEMON``
    A daemon is running.  ``aiur build-orders --json --contract build-order.v1``
    returns the published document, including tracker and progress truth.

``DOCUMENT_PACK_WALK``
    No daemon is present — the planning-only path, including publication.  The
    skill walks the pack into a document and marks the tracker and progress
    sources ``unknown``, which the review renders as an explicit notice instead
    of an empty table or a 0% bar.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Callable

DOCUMENT_CONTRACT = "aiur.build_order"
DOCUMENT_CONTRACT_VERSION = 1
DOCUMENT_DAEMON = "daemon"
DOCUMENT_PACK_WALK = "pack-walk"
DAEMON_TIMEOUT_SECONDS = 120

SOURCE_NAMES = ("pack", "tracker", "progress")
SOURCE_STATUSES = {"known", "stale", "unknown"}
EDGE_KINDS = (
    "depends_on",
    "serializes_with",
    "suggested_after",
    "contains",
    "gates",
)
TICKET_KINDS = {
    "executable", "audit", "gate", "umbrella", "capstone", "unknown",
}
PROVENANCES = {"planned", "discovered", "unknown"}

REQUIRED_KEYS = (
    "contract",
    "contract_version",
    "build_order_id",
    "title",
    "repository",
    "root",
    "generated_at",
    "sources",
    "epics",
    "features",
    "lanes",
    "tickets",
    "edges",
    "gates",
    "waves",
    "critical_path",
    "progress",
)

PACK_WALK_TRACKER_REASON = (
    "pack walk: no tracker read, so blocking state is unknown"
)
PACK_WALK_PROGRESS_REASON = "pack walk: no runtime progress read"


class GraphDocumentError(ValueError):
    """A ``build-order.v1`` document is missing, unreadable or inconsistent."""


def document_source(document: dict[str, Any]) -> str:
    """Return the source path that produced this document."""
    value = document.get("document_source")
    return value if isinstance(value, str) and value else DOCUMENT_DAEMON


def load_document(value: object) -> dict[str, Any]:
    """Validate one in-memory ``build-order.v1`` document."""
    if not isinstance(value, dict):
        raise GraphDocumentError("build-order document must be a JSON object")
    if value.get("contract") != DOCUMENT_CONTRACT:
        raise GraphDocumentError(
            f"build-order document contract must be {DOCUMENT_CONTRACT!r}"
        )
    if value.get("contract_version") != DOCUMENT_CONTRACT_VERSION:
        raise GraphDocumentError(
            "build-order document contract_version must be "
            f"{DOCUMENT_CONTRACT_VERSION}"
        )
    missing = [key for key in REQUIRED_KEYS if key not in value]
    if missing:
        raise GraphDocumentError(
            "build-order document is missing " + ", ".join(missing)
        )
    sources = value["sources"]
    if not isinstance(sources, dict):
        raise GraphDocumentError("build-order sources must be an object")
    for name in SOURCE_NAMES:
        source = sources.get(name)
        if not isinstance(source, dict):
            raise GraphDocumentError(f"build-order sources.{name} must be an object")
        if source.get("status") not in SOURCE_STATUSES:
            raise GraphDocumentError(
                f"build-order sources.{name}.status must be one of "
                + ", ".join(sorted(SOURCE_STATUSES))
            )
    for key in (
        "epics", "features", "lanes", "tickets", "edges", "gates", "waves",
    ):
        if not isinstance(value[key], list):
            raise GraphDocumentError(f"build-order {key} must be an array")
    critical_path = value["critical_path"]
    if not isinstance(critical_path, dict) or not isinstance(
        critical_path.get("tickets"), list
    ):
        raise GraphDocumentError("build-order critical_path must carry tickets")
    progress = value["progress"]
    if not isinstance(progress, dict) or progress.get("status") not in SOURCE_STATUSES:
        raise GraphDocumentError("build-order progress.status is invalid")
    ticket_ids: set[str] = set()
    for ticket in value["tickets"]:
        if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
            raise GraphDocumentError("build-order tickets must carry an id")
        if ticket["id"] in ticket_ids:
            raise GraphDocumentError(
                f"build-order tickets repeat the id {ticket['id']}"
            )
        ticket_ids.add(ticket["id"])
    for edge in value["edges"]:
        if not isinstance(edge, dict) or edge.get("kind") not in EDGE_KINDS:
            raise GraphDocumentError("build-order edges must carry a typed kind")
        if not isinstance(edge.get("from"), str) or not isinstance(
            edge.get("to"), str
        ):
            raise GraphDocumentError("build-order edges must carry from and to")
    return value


def load_document_file(path: Path) -> dict[str, Any]:
    """Read and validate one ``build-order.v1`` document file."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise GraphDocumentError(f"cannot read build-order document: {exc}") from None
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise GraphDocumentError(
            f"build-order document is not valid JSON: {exc}"
        ) from None
    document = load_document(value)
    document.setdefault("document_source", DOCUMENT_DAEMON)
    return document


def read_daemon_document(
    root: object = None, cli: str = "aiur",
    runner: Callable[..., Any] | None = None,
) -> dict[str, Any]:
    """Read the published document from a running daemon through the CLI."""
    command = [cli, "build-orders", "--json", "--contract", "build-order.v1"]
    if root is not None:
        command.append(str(root))
    run = runner or subprocess.run
    try:
        result = run(
            command, check=False, capture_output=True, text=True,
            timeout=DAEMON_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GraphDocumentError(f"cannot run the aiur CLI: {exc}") from None
    if result.returncode:
        detail = (result.stderr or "").strip() or f"exit {result.returncode}"
        raise GraphDocumentError(f"aiur build-orders failed: {detail}")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise GraphDocumentError(
            f"aiur build-orders returned invalid JSON: {exc}"
        ) from None
    document = load_document(value)
    document["document_source"] = DOCUMENT_DAEMON
    return document


def pack_tickets(build: object) -> dict[str, dict[str, Any]]:
    """Return the pack's ticket records keyed by logical id."""
    if not isinstance(build, dict):
        raise GraphDocumentError("build-order pack must be a JSON object")
    values = build.get("tickets")
    if not isinstance(values, list) or not values:
        raise GraphDocumentError("build-order pack must declare tickets")
    tickets: dict[str, dict[str, Any]] = {}
    for index, ticket in enumerate(values):
        if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
            raise GraphDocumentError(f"build-order pack tickets[{index}] has no id")
        if ticket["id"] in tickets:
            raise GraphDocumentError(
                f"build-order pack repeats the ticket {ticket['id']}"
            )
        tickets[ticket["id"]] = ticket
    return tickets


def pack_walk_document(
    build: object, *, generated_at: str = "",
) -> dict[str, Any]:
    """Derive a ``build-order.v1`` document from the pack alone.

    Every fact the review renders comes from the pack: typed edges, waves,
    critical path, epics, features, lanes and gates.  Tracker and progress
    truth are not available before a daemon reads them, so both sources are
    published as ``unknown`` with a reason rather than as an empty graph.
    """
    tickets = pack_tickets(build)
    assert isinstance(build, dict)
    root_id = build.get("build_order_id")
    if not isinstance(root_id, str) or not root_id:
        raise GraphDocumentError("build-order pack must declare build_order_id")
    repository = build.get("repository")
    if not isinstance(repository, str) or not repository:
        raise GraphDocumentError("build-order pack must declare repository")
    plan_version = build.get("plan_version")
    slug = root_id.rsplit(":", 1)[-1]
    title = _pack_title(build, slug)
    projection = build.get("label_projection")
    projection = projection if isinstance(projection, dict) else {}
    workstreams = _workstreams(build)
    features = _product_features(build)
    feature_of = {
        ticket_id: record["key"]
        for record in features for ticket_id in record["ticket_ids"]
    }
    epic_label = projection.get("build_order")
    root_mapping = build.get("github_root")
    root_mapping = root_mapping if isinstance(root_mapping, dict) else {}
    wave_of = _wave_assignment(tickets)
    critical = _critical_path(tickets, wave_of)
    lane_labels = projection.get("workstreams")
    lane_labels = lane_labels if isinstance(lane_labels, dict) else {}
    documents = {
        "pack": {
            "status": "known",
            "observed_at": _text(build.get("researched_at_commit")),
            "reason": None,
        },
        "tracker": {
            "status": "unknown", "observed_at": None,
            "reason": PACK_WALK_TRACKER_REASON,
        },
        "progress": {
            "status": "unknown", "observed_at": None,
            "reason": PACK_WALK_PROGRESS_REASON,
        },
    }
    unknown_progress = {
        "status": "unknown",
        "total": len(tickets),
        "done": None,
        "open": None,
        "failed": None,
        "percent": None,
        "by_status": None,
        "observed_at": None,
        "reason": PACK_WALK_PROGRESS_REASON,
    }
    document: dict[str, Any] = {
        "contract": DOCUMENT_CONTRACT,
        "contract_version": DOCUMENT_CONTRACT_VERSION,
        "document_source": DOCUMENT_PACK_WALK,
        "build_order_id": root_id,
        "title": title,
        "repository": repository,
        "root": {
            "id": root_id,
            "title": title,
            "number": _int(root_mapping.get("number")),
            "url": _text(root_mapping.get("url")),
            "epic": slug,
            "plan_version": plan_version if type(plan_version) is int else None,
            "researched_at_commit": _text(build.get("researched_at_commit")),
        },
        "generated_at": generated_at,
        "sources": documents,
        "epics": [{
            "key": slug,
            "title": title,
            "label": _text(epic_label),
            "url": _text(root_mapping.get("url")),
            "icon": None,
            "hue": None,
            "features": [record["key"] for record in features],
            "progress": dict(unknown_progress),
        }],
        "features": [{
            "key": record["key"],
            "title": record["title"],
            "label": record.get("label"),
            "epic": slug,
            "icon": record.get("icon"),
            "hue": None,
            "url": None,
            "progress": dict(unknown_progress),
        } for record in features],
        "lanes": [{
            "key": key,
            "title": record.get("title") or key,
            "label": _text(lane_labels.get(key)),
            "icon": record.get("icon"),
            "hue": None,
            "order": None,
            "progress": dict(unknown_progress),
        } for key, record in workstreams.items()],
        "tickets": _document_tickets(
            tickets, wave_of, slug, feature_of, unknown_progress,
        ),
        "edges": _document_edges(tickets, build),
        "gates": [{
            "key": gate.get("id"),
            "title": gate.get("title") or gate.get("id"),
            "owner": _text(gate.get("owner")),
            "resolution_criteria": _text(gate.get("resolution_criteria")),
            "status": "open",
        } for gate in _external_gates(build)],
        "waves": [
            {
                "index": index,
                "tickets": sorted(
                    ticket_id for ticket_id, value in wave_of.items()
                    if value == index
                ),
                "starts_at": None,
                "ends_at": None,
            }
            for index in range(1, max(wave_of.values(), default=0) + 1)
        ],
        "critical_path": {
            "status": "known",
            "tickets": critical,
            "hours": None,
            "reason": None,
        },
        "progress": dict(unknown_progress),
    }
    return load_document(document)


def waves_by_ticket(document: dict[str, Any]) -> dict[str, int]:
    """Map every ticket in the document to its published wave index."""
    result: dict[str, int] = {}
    for wave in document.get("waves") or []:
        if not isinstance(wave, dict) or type(wave.get("index")) is not int:
            continue
        for ticket_id in wave.get("tickets") or []:
            if isinstance(ticket_id, str):
                result[ticket_id] = wave["index"]
    return result


def edges_of(document: dict[str, Any], kind: str) -> list[dict[str, Any]]:
    """Return the document's typed edges of one kind, in published order."""
    return [
        edge for edge in document.get("edges") or []
        if isinstance(edge, dict) and edge.get("kind") == kind
    ]


def _pack_title(build: dict[str, Any], slug: str) -> str:
    title = build.get("title")
    if isinstance(title, str) and title.strip():
        return title.strip()
    words = [word for word in slug.replace(":", "-").split("-") if word]
    if not words:
        return slug
    return " ".join(words).capitalize()


def _workstreams(build: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = build.get("workstreams")
    result: dict[str, dict[str, Any]] = {}
    if not isinstance(values, list):
        return result
    for record in values:
        if not isinstance(record, dict) or not isinstance(record.get("id"), str):
            continue
        result[record["id"]] = record
    return result


def _product_features(build: dict[str, Any]) -> list[dict[str, Any]]:
    values = build.get("product_features")
    result: list[dict[str, Any]] = []
    if not isinstance(values, list):
        return result
    for record in values:
        if not isinstance(record, dict):
            continue
        key = record.get("slug") or record.get("id")
        if not isinstance(key, str) or not key:
            continue
        ticket_ids = [
            item for item in record.get("ticket_ids") or []
            if isinstance(item, str)
        ]
        result.append({
            "key": key,
            "title": record.get("label") or record.get("title") or key,
            "label": record.get("label") if isinstance(
                record.get("label"), str
            ) else None,
            "icon": record.get("icon") if isinstance(
                record.get("icon"), str
            ) else None,
            "ticket_ids": ticket_ids,
        })
    return result


def _external_gates(build: dict[str, Any]) -> list[dict[str, Any]]:
    values = build.get("external_gates")
    if not isinstance(values, list):
        return []
    return [
        gate for gate in values
        if isinstance(gate, dict) and isinstance(gate.get("id"), str)
    ]


def _document_tickets(
    tickets: dict[str, dict[str, Any]], wave_of: dict[str, int],
    slug: str, feature_of: dict[str, str],
    unknown_progress: dict[str, Any],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for ticket_id in sorted(tickets):
        ticket = tickets[ticket_id]
        kind = ticket.get("kind")
        provenance = ticket.get("provenance")
        mapping = ticket.get("github")
        mapping = mapping if isinstance(mapping, dict) else None
        lane = ticket.get("workstream")
        rows.append({
            "id": ticket_id,
            "number": _int(mapping.get("number")) if mapping else None,
            "title": ticket.get("title") if isinstance(
                ticket.get("title"), str
            ) else ticket_id,
            "url": _text(mapping.get("url")) if mapping else None,
            "kind": kind if kind in TICKET_KINDS else "unknown",
            "provenance": provenance if provenance in PROVENANCES else "unknown",
            "epic": slug,
            "feature": feature_of.get(ticket_id),
            "lane": lane if isinstance(lane, str) else None,
            "phase": _int(ticket.get("phase_hint")),
            "wave": wave_of.get(ticket_id),
            "complexity": _int(ticket.get("complexity_points")),
            "points": None,
            "estimate_hours": None,
            "status": "unknown" if mapping else "planned",
            "progress_percent": None,
            "started_at": None,
            "ended_at": None,
        })
    return rows


def _document_edges(
    tickets: dict[str, dict[str, Any]], build: dict[str, Any],
) -> list[dict[str, Any]]:
    gates = {gate.get("id") for gate in _external_gates(build)}
    edges: dict[tuple[str, str, str], dict[str, Any]] = {}

    def add(edge_from: str, edge_to: str, kind: str) -> None:
        if not isinstance(edge_from, str) or not isinstance(edge_to, str):
            return
        if edge_from == edge_to:
            return
        edges[(kind, edge_from, edge_to)] = {
            "from": edge_from,
            "to": edge_to,
            "kind": kind,
            "state": "unknown" if kind == "depends_on" else None,
            "source": "pack",
        }

    for ticket_id, ticket in tickets.items():
        for dependency in sorted(_strings(ticket.get("depends_on"))):
            if dependency in tickets:
                add(ticket_id, dependency, "depends_on")
        for partner in _strings(ticket.get("serializes_with")):
            if partner in tickets:
                first, second = sorted((ticket_id, partner))
                add(first, second, "serializes_with")
        for predecessor in sorted(_strings(ticket.get("suggested_after"))):
            if predecessor in tickets:
                add(ticket_id, predecessor, "suggested_after")
        for child in sorted(_strings(ticket.get("contains"))):
            if child in tickets:
                add(ticket_id, child, "contains")
        for gate in sorted(_strings(ticket.get("external_gates"))):
            if gate in gates:
                add(ticket_id, gate, "gates")
    return [
        edges[key] for key in sorted(edges, key=lambda item: (item[0], item[1], item[2]))
    ]


def _wave_assignment(tickets: dict[str, dict[str, Any]]) -> dict[str, int]:
    wave: dict[str, int] = {}
    state: dict[str, int] = {}

    def visit(ticket_id: str, trail: list[str]) -> int:
        if state.get(ticket_id) == 2:
            return wave[ticket_id]
        if state.get(ticket_id) == 1:
            raise GraphDocumentError(
                "dependency cycle: " + " -> ".join(trail + [ticket_id])
            )
        state[ticket_id] = 1
        blockers = [
            blocker for blocker in _strings(tickets[ticket_id].get("depends_on"))
            if blocker in tickets
        ]
        value = 1 + max(
            (visit(blocker, trail + [ticket_id]) for blocker in blockers),
            default=0,
        )
        wave[ticket_id] = value
        state[ticket_id] = 2
        return value

    for ticket_id in sorted(tickets):
        visit(ticket_id, [])
    return wave


def _critical_path(
    tickets: dict[str, dict[str, Any]], wave: dict[str, int],
) -> list[str]:
    if not tickets:
        return []
    current = sorted(tickets, key=lambda item: (-wave[item], item))[0]
    path = [current]
    while True:
        blockers = [
            blocker for blocker in _strings(tickets[current].get("depends_on"))
            if blocker in tickets
        ]
        if not blockers:
            break
        current = sorted(blockers, key=lambda item: (-wave[item], item))[0]
        path.append(current)
    # Ordered like every ``depends_on`` edge: each ticket before its blocker.
    return path


def _strings(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]


def _text(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def _int(value: object) -> int | None:
    return value if type(value) is int else None
