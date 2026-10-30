#!/usr/bin/env python3
"""Automatic daily preprocess, compile and durable Executor wake. No delivery."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

import newsletter
from collect import write_snapshot
from metrics import compute


def build(args, root, now):
    if args.fixture:
        snapshot = json.loads(args.fixture.read_text())
        report = compute(snapshot)
        report['editorial'] = {}
        snapshot_path = write_snapshot(snapshot, root / 'newsletter/snapshots')
        report_path = root / 'newsletter' / now.date().isoformat() / 'report.json'
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    else:
        report_path = newsletter.preprocess(args.repo, root, now, args.instance)
        snapshot_path = root / 'newsletter/snapshots' / (now.date().isoformat() + '.json')
    shutil.copyfile(snapshot_path, report_path.with_name('snapshot.json'))
    report = json.loads(report_path.read_text())
    pdf = newsletter.publish(report_path, report, args.timezone)
    latest = root / 'newsletter/latest'
    latest.mkdir(exist_ok=True)
    for name in ('report.json', 'newsletter.html', 'newsletter.pdf'):
        target = latest / name
        temporary = target.with_suffix(target.suffix + '.tmp')
        shutil.copyfile(report_path.with_name(name), temporary)
        temporary.replace(target)
    return report_path, pdf


def run(args, root, now, log):
    directory = root / 'newsletter' / now.date().isoformat()
    marker = directory / 'wake-sent.json'
    if marker.exists() and not args.dry_run:
        print('Already completed today', file=log)
        return
    report_path, pdf = build(args, root, now)
    payload = {'repo': args.repo, 'date': now.date().isoformat(),
               'report_path': str(report_path), 'pdf_path': str(pdf)}
    if args.dry_run:
        print('Dry run; no wake published: ' + json.dumps(payload), file=log)
    else:
        subprocess.run([args.aiur, 'executor-emit', 'system.newsletter.ready',
                        '--payload', json.dumps(payload)], check=True, stdout=log, stderr=log)
        marker.write_text(json.dumps(payload) + '\n')
    print('Ready: ' + str(pdf), file=log)
    print(pdf)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, help='owner/repo')
    parser.add_argument('--state-dir', type=Path, help='per-repository Aiur state root')
    parser.add_argument('--instance', action='append', default=[])
    parser.add_argument('--timezone', default='America/Los_Angeles')
    parser.add_argument('--aiur', default='aiur', help='CLI executable targeting this repository daemon')
    parser.add_argument('--dry-run', action='store_true', help='build without publishing a wake')
    parser.add_argument('--fixture', type=Path, help='snapshot JSON (requires --dry-run and --state-dir)')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) or any(p in ('.', '..') for p in args.repo.split('/')):
        parser.error('repo must be owner/repo')
    if args.fixture and not (args.dry_run and args.state_dir):
        parser.error('--fixture requires --dry-run and --state-dir')
    root = (args.state_dir or Path.home() / '.aiur/repo' / args.repo).resolve()
    now = datetime.now(timezone.utc)
    directory = root / 'newsletter' / now.date().isoformat()
    directory.mkdir(parents=True, exist_ok=True)
    with (root / 'newsletter/run.lock').open('a') as lock, (directory / 'run.log').open('a', buffering=1) as log:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print(now.isoformat() + ' Starting daily newsletter', file=log)
            run(args, root, now, log)
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            print('FAILED: ' + str(error), file=log)
            print('newsletter: ' + str(error), file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
