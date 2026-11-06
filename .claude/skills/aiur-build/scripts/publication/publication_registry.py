"""Register a published pack's epic, product features and lanes.

The pack's hierarchy is Epic > Feature > Lane. Publication registers one epic
for the whole planning pack, one feature per ``product_features`` group inside
that epic, and each feature's lanes with their icons. Every command is
deterministic and the build registry treats a matching repeat as unchanged, so
re-running publication writes nothing new.

The epic is read before it is created. ``aiur epic create`` compares label, icon,
hue and root, and an epic created without ``--hue`` derives its hue from the
features already registered — which publication itself creates later in the same
run. Re-issuing the create on a second run would therefore compare against a
freshly derived hue and be refused as a difference. Reading first keeps the
repeat a no-op. A pack title that changes after approval needs ``aiur epic
edit``: a differing label is refused rather than renaming an operator's epic
silently.
"""

from __future__ import annotations

import json
from typing import Any

from publication_client import PublicationError
from publication_context import (
    feature_lanes,
    planning_epic_slug,
    product_features,
    published_feature_slug,
)

BATCH = 200


def ensure_registry(
    publisher: Any, mappings: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Create the pack's epic, its product features and their lane membership."""
    epic = _epic(publisher, mappings)
    _ensure_epic(publisher, epic)
    build = publisher.context.build
    tickets = {item["id"]: item for item in build["tickets"]}
    workstreams = {item["id"]: item for item in build["workstreams"]}
    root_slug = publisher.context.root_id.removeprefix(
        f"{publisher.context.repository}:"
    )
    features = []
    for product in product_features(build):
        slug = published_feature_slug(root_slug, product["slug"])
        group = [tickets[ticket_id] for ticket_id in product["ticket_ids"]]
        lanes = feature_lanes({
            "build_order_id": f"{publisher.context.repository}:{slug}",
            "workstreams": [
                workstreams[lane]
                for lane in sorted({ticket["workstream"] for ticket in group})
            ],
            "tickets": group,
        })
        publisher._run_cli(
            _create_arguments(slug, product["label"], epic["slug"], lanes),
            "feature registration",
        )
        for lane in lanes:
            numbers = [
                str(mappings[ticket_id]["number"])
                for ticket_id in product["ticket_ids"]
                if tickets[ticket_id]["workstream"] == lane["lane"]
            ]
            for offset in range(0, len(numbers), BATCH):
                publisher._run_cli(
                    [
                        "feature", "add", slug,
                        *numbers[offset:offset + BATCH], "--lane", lane["key"],
                    ],
                    "feature membership",
                )
        features.append({"slug": slug, "lanes": [lane["key"] for lane in lanes]})
    return {"epic": epic["slug"], "features": features}


def _epic(publisher: Any, mappings: dict[str, dict[str, Any]]) -> dict[str, str]:
    """The pack's epic: the slug root import derives and the approved pack title."""
    root = mappings[publisher.context.root_id]
    return {
        "slug": planning_epic_slug(root["number"]),
        "label": publisher.context.specs[publisher.context.root_id].title,
    }


def _ensure_epic(publisher: Any, epic: dict[str, str]) -> None:
    """Create the pack's epic unless the registry already holds it."""
    existing = _registered_epics(publisher).get(epic["slug"])
    if existing is None:
        publisher._run_cli(
            ["epic", "create", epic["slug"], "--label", epic["label"]],
            "epic registration",
        )
        return
    if existing.get("label") != epic["label"]:
        raise PublicationError(
            f"epic {epic['slug']} is already registered as "
            f"{existing.get('label')!r}; run `aiur epic edit {epic['slug']} "
            f"--label {epic['label']!r}` before republishing"
        )


def _registered_epics(publisher: Any) -> dict[str, dict[str, Any]]:
    """Epic records already in the local registry, keyed by slug."""
    raw = publisher._read_cli(["epic", "list", "--json"], "epic inspection")
    try:
        payload = json.loads(raw) if raw and raw.strip() else {}
    except json.JSONDecodeError:
        raise PublicationError("epic inspection returned invalid JSON") from None
    epics = payload.get("epics") if isinstance(payload, dict) else None
    if not isinstance(epics, list):
        return {}
    return {
        epic["slug"]: epic for epic in epics
        if isinstance(epic, dict) and isinstance(epic.get("slug"), str)
    }


def _create_arguments(
    slug: str, label: str, epic: str, lanes: list[dict[str, str]],
) -> list[str]:
    """One `aiur feature create` inside the pack's epic, defining each lane."""
    arguments = ["feature", "create", slug, "--label", label, "--in", epic]
    for lane in lanes:
        arguments.extend(("--lane", f"{lane['key']}={lane['label']}"))
        arguments.extend(("--lane-icon", f"{lane['key']}={lane['icon']}"))
    return arguments
