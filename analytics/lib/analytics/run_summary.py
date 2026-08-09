"""``run-summary`` — one boot's headline numbers.

Reads the materialized ``run-summary.json`` when present (the cheap path the
dashboard and Executors are meant to use), otherwise reduces the raw stream on
the fly. ``--json`` for machines.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import cli, reduce as reducer, render, sources


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="run-summary",
        description="Print one daemon boot's run summary (records, dispatched/merged/open, CPU-hours, concurrency, top cost).",
    )
    cli.add_discovery_args(parser)
    parser.add_argument("boot_id", nargs="?", default=None, metavar="BOOT_ID",
                        help="Boot id to summarize. Default: --current.")
    parser.add_argument("--current", action="store_true", help="Summarize the newest boot in the stream.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    parser.add_argument("--cap", type=int, default=10, help="Concurrency cap for wasted-capacity accounting.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    files = cli.discover(args)
    state_node = cli.resolve_state_node(args)

    dataset = reducer.reduce_files(files, {})
    boot_ids = cli.boot_ids_from(dataset)
    if not boot_ids:
        print("analytics: no daemon boots found in telemetry", file=sys.stderr)
        return 2

    if args.boot_id:
        boot_id = args.boot_id
    else:
        # Newest boot by last timestamp.
        boot_id = max(boot_ids, key=lambda bid: _last_ms(dataset, bid))

    summary = _load_or_reduce(dataset, state_node, boot_id)

    if summary is None:
        print("analytics: boot %r not present in the telemetry stream" % boot_id, file=sys.stderr)
        return 2

    if args.json:
        cli.emit_json(render.run_summary_kpis(summary, args.cap))
    else:
        sys.stdout.write(render.render_run_summary(summary, args.cap))
    return 0


def _last_ms(dataset: dict, boot_id: str) -> int:
    stamps = [
        record["timestamp_ms"]
        for record in dataset.get("records", [])
        if record.get("boot_id") == boot_id and isinstance(record.get("timestamp_ms"), int)
    ]
    return max(stamps) if stamps else 0


def _load_or_reduce(dataset: dict, state_node: Path, boot_id: str) -> dict | None:
    materialized = sources.run_summary_path(state_node, boot_id)
    if materialized.is_file():
        try:
            return json.loads(materialized.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass  # stale/partial summary: fall back to a fresh reduction.
    boot_ids = cli.boot_ids_from(dataset)
    if boot_id not in boot_ids:
        return None
    return reducer.boot_summary(dataset, boot_id)


if __name__ == "__main__":
    sys.exit(main())
