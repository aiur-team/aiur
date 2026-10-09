"""Backfill retained launch telemetry, with an explicit milestone census."""
import argparse
import glob
import json
from datetime import datetime
from pathlib import Path

from . import cli, ledger_store, sources


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    cli.add_discovery_args(parser)
    parser.add_argument('--since', required=True, type=lambda value: datetime.fromisoformat(value).isoformat())
    parser.add_argument('--telemetry-glob', action='append', default=[])
    args = parser.parse_args(argv)
    files = sources.discover_telemetry_files(args.telemetry or [])
    files = sorted(set(files) | {Path(p) for pattern in args.telemetry_glob for p in glob.glob(pattern, recursive=True)})
    state = cli.resolve_state_node(args)
    written = ledger_store.materialize(files, state, args.since, args.repo)
    records = [json.loads(path.read_text()) for path in (state / 'analytics/tickets').glob('*.json')]
    merged = [r for r in records if r['milestones']['merged']['at'] and r['milestones']['merged']['at'] >= args.since]
    complete = [r for r in merged if all(r['milestones'][key]['status'] == 'observed'
                                       for key in ('first_dispatch', 'pr_opened', 'merged'))]
    print(json.dumps({'written': len(written), 'merged': len(merged), 'complete': len(complete),
                      'observed_percent': 100 * len(complete) / len(merged) if merged else None}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
