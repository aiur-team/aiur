"""Backfill retained launch telemetry, with an explicit milestone census."""
import argparse
import glob
import json
from datetime import date
from pathlib import Path

from . import cli, ledger_enrich, ledger_store, sources


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    cli.add_discovery_args(parser)
    parser.add_argument('--since', required=True, type=lambda value: date.fromisoformat(value).isoformat())
    parser.add_argument('--no-facts', action='store_true', help='Offline replay only; make no GitHub fact reads.')
    parser.add_argument('--telemetry-glob', action='append', default=[])
    args = parser.parse_args(argv)
    if not args.no_facts and not args.repo:
        parser.error('--repo is required unless --no-facts is selected')
    files = sources.discover_telemetry_files(args.telemetry or [])
    files = sorted(set(files) | {Path(p) for pattern in args.telemetry_glob for p in glob.glob(pattern, recursive=True)})
    state = cli.resolve_state_node(args)
    retained_facts = state / 'analytics/backfill-facts.ndjson'
    if retained_facts.exists():
        files.append(retained_facts)
    written = ledger_store.materialize(files, state, args.since, args.repo)
    failures = 0
    if not args.no_facts:
        repo = args.repo
        facts_path, failures = ledger_enrich.enrich(state, args.since, repo)
        if facts_path.exists():
            written += ledger_store.materialize(files + [facts_path], state, args.since, repo)
    records = [json.loads(path.read_text()) for path in (state / 'analytics/tickets').glob('*.json')]
    merged = [r for r in records if r['milestones']['merged']['at'] and r['milestones']['merged']['at'] >= args.since]
    complete = [r for r in merged if all(r['milestones'][key]['status'] == 'observed'
                                       for key in ('first_dispatch', 'pr_opened', 'merged'))]
    print(json.dumps({'facts_failures': failures, 'written': len(written), 'merged': len(merged), 'complete': len(complete),
                      'observed_percent': 100 * len(complete) / len(merged) if merged else None}))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
