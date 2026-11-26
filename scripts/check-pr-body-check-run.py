#!/usr/bin/env python3
"""Require the latest PR-body workflow check for the current PR head."""
import json
import os
import subprocess
import sys


def latest_check():
    result = subprocess.run([
        'gh', 'api',
        f'repos/{os.environ["GITHUB_REPOSITORY"]}/commits/{os.environ["PR_HEAD"]}/check-runs?per_page=100',
    ], check=True, text=True, capture_output=True)
    checks = json.loads(result.stdout)['check_runs']
    matching = [check for check in checks if check['name'] == 'pr body']
    return max(matching, key=lambda check: check['id'], default=None)


def main():
    try:
        check = latest_check()
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f'ci gate could not read PR-body check: {error}', file=sys.stderr)
        return 1
    if not check:
        print('ci gate failed: PR-body check has not reported yet', file=sys.stderr)
        return 1
    if check['status'] != 'completed' or check['conclusion'] != 'success':
        print(
            f'ci gate failed: latest PR-body check is {check["status"]}/'
            f'{check["conclusion"] or "pending"}', file=sys.stderr,
        )
        return 1
    print(f'ci gate accepted PR-body check run {check["id"]} for {check["head_sha"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
