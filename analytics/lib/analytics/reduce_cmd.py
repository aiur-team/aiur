"""``reduce`` — the materializer that run-summary, build-report, and the
dashboard read. Idempotent and cron/post-run safe: re-running regenerates the
same summaries (with fresh provenance) and never double-counts.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import cli, reduce as reducer, sources


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="reduce",
        description="Materialize run-summaries (and optional build rollups) from durable telemetry into the state node.",
    )
    cli.add_discovery_args(parser)
    parser.add_argument("--all", action="store_true", help="Materialize every boot (default; explicit for CLI parity with the daemon).")
    parser.add_argument("--boot", default=None, metavar="BOOT_ID", help="Materialize only this boot.")
    parser.add_argument("--build", default=None, metavar="SLUG", action="append",
                        help="Also materialize a build-summary rollup for this build-order slug (repeatable).")
    parser.add_argument("--all-builds", action="store_true", help="Materialize build-summaries for every discovered build order.")
    parser.add_argument("--github-events", default=None, metavar="FILE",
                        help="Optional JSON array of GitHub lifecycle events already fetched (keeps the reducer pure).")
    parser.add_argument("--enrich", action="store_true", help="Record enrichment in provenance (opt-in).")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable output.")
    parser.add_argument("--cap", type=int, default=10, help="Concurrency cap for wasted-capacity accounting.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    files = cli.discover(args)
    github_events = cli.read_github_events(args)
    opts = {"github_events": github_events, "enrich": args.enrich}

    dataset = reducer.reduce_files(files, opts)
    state_node = cli.resolve_state_node(args)

    if args.boot:
        boot_ids = [args.boot]
    else:
        boot_ids = cli.boot_ids_from(dataset)

    written_runs = reducer.write_all_run_summaries(state_node, dataset, boot_ids, opts)

    build_slugs: list[str] = []
    if args.build:
        build_slugs.extend(args.build)
    if args.all_builds:
        build_slugs.extend(slug for slug, _path in sources.discover_build_orders(state_node))

    written_builds = []
    for slug in sorted(set(build_slugs)):
        build_order_path = sources.find_build_order(state_node, slug)
        if build_order_path is None:
            print("analytics: no build order found for slug %r (state node: %s)" % (slug, state_node), file=sys.stderr)
            continue
        try:
            build_order = json.loads(build_order_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print("analytics: could not read build order %s: %s" % (build_order_path, error), file=sys.stderr)
            continue
        path = reducer.build_summary_for(state_node, dataset, slug, build_order, opts)
        if path:
            written_builds.append(path)

    result = {"written": written_runs, "build_summaries": written_builds, "state_node": str(state_node)}
    if args.json:
        cli.emit_json(result)
    else:
        for path in written_runs:
            print("wrote %s" % path)
        for path in written_builds:
            print("wrote %s" % path)
        if not written_runs and not written_builds:
            print("analytics: nothing to materialize (no boots in scope)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
