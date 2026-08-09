"""``build-report`` — the retrospective number-fetcher.

Prints, for one completed (or in-flight) build order, per-member merged/closed/
open status, wall-clock and active time across every boot that touched the
member, CI cycles, rework count, and CPU-seconds spend — the numbers an
Executor needs to write an hourly retrospective without hand-counting merges
or eyeballing CI logs. Reads the materialized build-summary when present,
otherwise reduces the raw stream on the fly.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import cli, reduce as reducer, render, sources


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="build-report",
        description="Print a cross-boot retrospective report for one build order.",
    )
    cli.add_discovery_args(parser)
    parser.add_argument("slug", metavar="SLUG", help="Build-order slug, e.g. analytics-optimizations.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    files = cli.discover(args)
    state_node = cli.resolve_state_node(args)

    build_order_path = sources.find_build_order(state_node, args.slug)
    if build_order_path is None:
        print(
            "analytics: no build order found for slug %r (searched state node %s and repo packs)"
            % (args.slug, state_node),
            file=sys.stderr,
        )
        return 2

    try:
        build_order = json.loads(build_order_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("analytics: could not read build order %s: %s" % (build_order_path, error), file=sys.stderr)
        return 2

    summary = _load_or_reduce(files, state_node, args.slug, build_order)
    if summary is None:
        print("analytics: no telemetry touches members of build order %r" % args.slug, file=sys.stderr)
        return 2

    if args.json:
        cli.emit_json({"slug": args.slug, "build_order": build_order, "report": render.build_report_rows(summary)})
    else:
        sys.stdout.write(render.render_build_report(summary, args.slug))
    return 0


def _load_or_reduce(files: list[Path], state_node: Path, slug: str, build_order: dict) -> dict | None:
    materialized = sources.build_summary_path(state_node, slug)
    if materialized.is_file():
        try:
            return json.loads(materialized.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass

    dataset = reducer.reduce_files(files, {})
    member_numbers = {str(t["ticket"]) for t in (build_order.get("tickets") or []) if t.get("ticket") is not None}
    touched = any(
        (record.get("attributes") or {}).get("ticket") in member_numbers for record in dataset.get("records", [])
    )
    if not touched:
        return None
    return reducer.build_summary_for(state_node, dataset, slug, build_order)


if __name__ == "__main__":
    sys.exit(main())
