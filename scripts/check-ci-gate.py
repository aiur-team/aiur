#!/usr/bin/env python3
"""Require actual success from every job selected for this CI event."""
import json
import os
import sys


def required_jobs(event, full, dialyzer):
    if event not in ('pull_request', 'merge_group', 'workflow_dispatch', 'push'):
        raise ValueError(f'unsupported CI event: {event}')
    if event != 'pull_request' and not full:
        raise ValueError(f'{event} must run full CI')
    jobs = ['changes', 'workflow-security', 'lint']
    if full:
        return jobs + ['build', 'coverage-partition', 'test', 'dialyzer', 'browser', 'browser-2', 'browser-3', 'home-css',
                       'layout-release', 'analytics', 'streamdeck']
    selected = jobs + ['affected-tests']
    if event == 'pull_request' and dialyzer:
        selected.append('dialyzer')
    return selected


def main():
    needs = json.loads(os.environ['NEEDS_JSON'])
    outputs = needs.get('changes', {}).get('outputs', {})
    full = outputs.get('full_ci')
    if full not in ('true', 'false'):
        raise ValueError('missing full_ci classification')
    dialyzer = outputs.get('dialyzer')
    if dialyzer not in ('true', 'false'):
        raise ValueError('missing dialyzer classification')
    required = required_jobs(os.environ['EVENT_NAME'], full == 'true', dialyzer == 'true')
    failed = [job for job in required if needs.get(job, {}).get('result') != 'success']
    if failed:
        if 'affected-tests' in failed and needs['affected-tests'].get('result') == 'cancelled':
            print('CI gate failed: affected tests (cancelled; possible timeout)', file=sys.stderr)
            return 1
        print(f'CI gate failed: {", ".join(failed)}', file=sys.stderr)
        return 1
    print(f'CI gate passed: {", ".join(required)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
