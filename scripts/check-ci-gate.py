#!/usr/bin/env python3
"""Require actual success from every job selected for this CI event."""
import json
import os
import sys


def required_jobs(event, full, dialyzer, browser_smoke):
    if event not in ('pull_request', 'merge_group', 'workflow_dispatch', 'push'):
        raise ValueError(f'unsupported CI event: {event}')
    if event != 'pull_request' and not full:
        raise ValueError(f'{event} must run full CI')
    jobs = ['changes', 'workflow-security', 'pre-handoff', 'lint']
    if event == 'pull_request':
        jobs.append('soak')  # soak.yml repeats the PR's changed tests; it succeeds when there are none.
    if full:
        selected = jobs + ['build', 'coverage-partition', 'test', 'dialyzer', 'home-css',
                           'layout-release', 'analytics', 'streamdeck']
        selected += ['browser'] if browser_smoke or event != 'pull_request' else []
        return selected + (['affected-tests'] if event == 'merge_group' else [])
    selected = jobs + ['affected-tests']
    if event == 'pull_request' and dialyzer:
        selected.append('dialyzer')
    if event == 'pull_request' and browser_smoke:
        selected.append('browser')
    return selected


def main():
    needs = json.loads(os.environ['NEEDS_JSON'])
    outputs = needs.get('changes', {}).get('outputs', {})
    full = outputs.get('full_ci')
    if full not in ('true', 'false'):
        print('CI gate failed: missing or invalid full_ci classification', file=sys.stderr)
        return 1
    dialyzer = outputs.get('dialyzer')
    if dialyzer not in ('true', 'false'):
        print('CI gate failed: missing or invalid dialyzer classification', file=sys.stderr)
        return 1
    browser_smoke = outputs.get('browser_smoke')
    if browser_smoke not in ('true', 'false'):
        print('CI gate failed: missing or invalid browser_smoke classification', file=sys.stderr)
        return 1
    event = os.environ['EVENT_NAME']
    required = required_jobs(event, full == 'true', dialyzer == 'true', browser_smoke == 'true')
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
