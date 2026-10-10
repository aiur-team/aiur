"""Materialization: per-boot run summaries and build-order rollups written to the state node."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import sources
from .parse import _in_boot, _now_iso, _time_range
from .reduce_actors import _rescope_actors
from .reduce_tickets import _rescope_tickets


# run-summary schema version (distinct from the telemetry record schema version).
SUMMARY_SCHEMA_VERSION = 1


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
