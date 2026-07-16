"""Canonical models and mappings for live publication snapshots."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from validation_common import Report


@dataclass(frozen=True)
class LiveSnapshot:
    issues: tuple[tuple[str, str], ...]
    marker_matches: tuple[tuple[str, tuple[str, ...]], ...]
    root_members: tuple[str, ...]
    parents: tuple[tuple[str, str | None], ...]
    dependency_edges: tuple[tuple[str, str], ...]


def _expected_mappings(
    data: dict[str, Any], report: Report,
) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    root_id = data.get("build_order_id")
    root = data.get("github_root")
    if isinstance(root_id, str) and isinstance(root, dict):
        result[root_id] = root
    tickets = data.get("tickets")
    if isinstance(tickets, list):
        for ticket in tickets:
            if not isinstance(ticket, dict):
                continue
            logical_id, mapping = ticket.get("id"), ticket.get("github")
            if isinstance(logical_id, str) and isinstance(mapping, dict):
                result[logical_id] = mapping
    if not result:
        report.error("live GitHub validation found no materialized mappings")
    return result


def _mapping_key(mapping: dict[str, Any]) -> str:
    return (
        f"{mapping.get('repository')}#{mapping.get('number')}|"
        f"{mapping.get('node_id')}|{mapping.get('url')}"
    )


def _canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _merge(source: Report, destination: Report) -> None:
    destination.errors.extend(source.errors)
    destination.warnings.extend(source.warnings)
