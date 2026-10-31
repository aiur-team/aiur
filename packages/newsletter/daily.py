#!/usr/bin/env python3
"""Automatic daily preprocess, compile and durable Executor wake. No delivery."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from zoneinfo import ZoneInfo

import newsletter
from collect import write_snapshot
from metrics import compute


class StageFailure(RuntimeError):
    def __init__(self, stage, reason):
        super().__init__(str(reason))
        self.stage = stage


def step(stage, function, *args):
    try:
        return function(*args)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise StageFailure(stage, error) from error


def day_key(args, now):
    return now.astimezone(ZoneInfo(args.timezone)).date().isoformat()


def preprocess(args, root, now):
    if not args.fixture:
        report_path = newsletter.preprocess(args.repo, root, now, args.instance, output_date=day_key(args, now), aiur=args.aiur)
        snapshot_path = root / 'newsletter/snapshots' / (now.date().isoformat() + '.json')
        return report_path, snapshot_path
    snapshot = json.loads(args.fixture.read_text())
    report = compute(snapshot)
    report['editorial'] = {}
    snapshot_path = write_snapshot(snapshot, root / 'newsletter/snapshots')
    report_path = root / 'newsletter' / day_key(args, now) / 'report.json'
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    return report_path, snapshot_path


def retain_outputs(report_path, snapshot_path, directory):
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / 'report.json'
    shutil.copyfile(snapshot_path, directory / 'snapshot.json')
    return target


def latest_outputs(root, report_path):
    latest = root / 'newsletter/latest'
    latest.mkdir(exist_ok=True)
    for name in ('report.json', 'newsletter.html', 'newsletter.pdf'):
        target = latest / name
        temporary = target.with_suffix(target.suffix + '.tmp')
        shutil.copyfile(report_path.with_name(name), temporary)
        temporary.replace(target)


def build(args, root, now):
    report_path, snapshot_path = step('preprocess', preprocess, args, root, now)
    directory = root / 'newsletter' / day_key(args, now)
    report_path = step('outputs', retain_outputs, report_path, snapshot_path, directory)
    report = json.loads(report_path.read_text())
    pdf = step('compile', newsletter.publish, report_path, report, args.timezone)
    step('outputs', latest_outputs, root, report_path)
    return report_path, pdf


def emit(args, topic, payload, log):
    subprocess.run([args.aiur, 'executor-emit', topic, '--payload', json.dumps(payload)],
                   check=True, stdout=log, stderr=log)


def run(args, root, now, log):
    directory = root / 'newsletter' / day_key(args, now)
    marker = directory / 'wake-sent.json'
    if marker.exists() and not args.dry_run:
        print('Already completed today', file=log)
        return
    report_path, pdf = build(args, root, now)
    payload = {'repo': args.repo, 'date': day_key(args, now),
               'report_path': str(report_path), 'pdf_path': str(pdf)}
    if args.dry_run:
        print('Dry run; no wake published: ' + json.dumps(payload), file=log)
    else:
        step('publish', emit, args, 'system.newsletter.ready', payload, log)
        marker.write_text(json.dumps(payload) + '\n')
    print('Ready: ' + str(pdf), file=log)
    print(pdf)


def failed(args, now, error, log):
    print('FAILED: ' + str(error), file=log)
    print('newsletter: ' + str(error), file=sys.stderr)
    if args.dry_run:
        return
    payload = {'repo': args.repo, 'date': day_key(args, now), 'stage': getattr(error, 'stage', 'run'),
               'reason': str(error), 'log_path': str(Path(log.name).resolve())}
    try:
        emit(args, 'executor.newsletter.failed', payload, log)
    except (OSError, subprocess.SubprocessError) as notification_error:
        print('Failure notification failed: ' + str(notification_error), file=log)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, help='owner/repo')
    parser.add_argument('--state-dir', type=Path, help='per-repository Aiur state root')
    parser.add_argument('--instance', action='append', default=[])
    parser.add_argument('--timezone', default='America/Los_Angeles')
    parser.add_argument('--aiur', default=os.environ.get('NEWSLETTER_AIUR') or 'aiur',
                        help='CLI executable targeting this repository daemon (or NEWSLETTER_AIUR)')
    parser.add_argument('--dry-run', action='store_true', help='build without publishing a wake')
    parser.add_argument('--fixture', type=Path, help='snapshot JSON (requires --dry-run and --state-dir)')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) or any(p in ('.', '..') for p in args.repo.split('/')):
        parser.error('repo must be owner/repo')
    if args.fixture and not (args.dry_run and args.state_dir):
        parser.error('--fixture requires --dry-run and --state-dir')
    return args


def main():
    args = parse_args()
    root = (args.state_dir or Path.home() / '.aiur/repo' / args.repo).resolve()
    now = datetime.now(timezone.utc)
    directory = root / 'newsletter' / day_key(args, now)
    directory.mkdir(parents=True, exist_ok=True)
    with (root / 'newsletter/run.lock').open('a') as lock, (directory / 'run.log').open('a', buffering=1) as log:
        try:
            step('lock', fcntl.flock, lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print(now.isoformat() + ' Starting daily newsletter', file=log)
            run(args, root, now, log)
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            failed(args, now, error, log)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
