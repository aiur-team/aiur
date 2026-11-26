#!/usr/bin/env python3
"""Report merges/hour and merge-group runner wait over a window (#4814).

Usage: measure-merge-throughput.py [END_ISO8601] [HOURS]  (default: now, 6)
Runner wait is each merge-group job's started_at - created_at: time queued for a runner.
"""
import json
import statistics
import subprocess
import sys
from datetime import datetime, timedelta, timezone

REPO = 'aiur-team/aiur'


def api(path):
    out = subprocess.run(['gh', 'api', '--paginate', '--slurp', path], check=True, text=True, capture_output=True).stdout
    return json.loads(out)


def ts(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def window(argv):
    end = ts(argv[1]) if len(argv) > 1 else datetime.now(timezone.utc)
    return end - timedelta(hours=float(argv[2]) if len(argv) > 2 else 6), end


def summarize(merged_at, waits, start, end):
    hours = (end - start).total_seconds() / 3600
    merges = sum(start <= at < end for at in merged_at)
    waits = sorted(waits)
    p90 = waits[int(0.9 * (len(waits) - 1))] if waits else None
    return {
        'window': f'{start:%Y-%m-%dT%H:%MZ}..{end:%Y-%m-%dT%H:%MZ}', 'merges': merges,
        'merges_per_hour': round(merges / hours, 2), 'merge_group_jobs': len(waits),
        'runner_wait_median_s': statistics.median(waits) if waits else None, 'runner_wait_p90_s': p90,
    }


def main(argv):
    start, end = window(argv)
    created = f'{start:%Y-%m-%dT%H:%M:%SZ}..{end:%Y-%m-%dT%H:%M:%SZ}'
    query = f'search/issues?q=repo:{REPO}+is:pr+base:main+merged:{created}&per_page=100'
    merged_at = [ts(pr['pull_request']['merged_at']) for page in api(query) for pr in page['items']]
    runs = [run for page in api(f'repos/{REPO}/actions/runs?event=merge_group&created={created}&per_page=100')
            for run in page['workflow_runs'] if run['name'] == 'ci']
    waits = []
    for run in runs:
        for page in api(f'repos/{REPO}/actions/runs/{run["id"]}/jobs?per_page=100'):
            waits += [(ts(job['started_at']) - ts(job['created_at'])).total_seconds()
                      for job in page['jobs'] if job.get('started_at') and job['conclusion'] != 'skipped']
    print(json.dumps(summarize(merged_at, waits, start, end)))
    return 0


if __name__ == '__main__':
    if sys.argv[1:2] == ['--self-test']:
        t0 = datetime(2026, 10, 17, tzinfo=timezone.utc)
        got = summarize([t0 + timedelta(hours=h) for h in (-1, 0, 2, 5.9, 6)], [30, 10, 600, 20], t0, t0 + timedelta(hours=6))
        assert got['merges'] == 3 and got['merges_per_hour'] == 0.5, got
        assert got['runner_wait_median_s'] == 25 and got['runner_wait_p90_s'] == 30, got
        print('measure-merge-throughput self-test passed')
        raise SystemExit(0)
    raise SystemExit(main(sys.argv))
