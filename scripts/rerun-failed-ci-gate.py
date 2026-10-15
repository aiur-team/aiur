#!/usr/bin/env python3
"""Re-run only the failed ci gate after PR-body validation succeeds."""
import json
import os
import subprocess
import sys
import time


def api(path, method='GET'):
    command = ['gh', 'api', path]
    if method != 'GET':
        command.extend(['-X', method])
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def current_ci_run():
    repo = os.environ['GITHUB_REPOSITORY']
    sha = os.environ['PR_HEAD']
    runs = api(f'repos/{repo}/actions/runs?head_sha={sha}&event=pull_request&per_page=100')
    matching = [run for run in runs['workflow_runs'] if run['name'] == 'ci' and run['head_sha'] == sha]
    return max(matching, key=lambda run: run['run_number'], default=None)


def gate_job(run):
    repo = os.environ['GITHUB_REPOSITORY']
    jobs = api(f'repos/{repo}/actions/runs/{run["id"]}/jobs?per_page=100')
    matching = [job for job in jobs['jobs'] if job['name'] == 'ci gate' and job['head_sha'] == run['head_sha']]
    return max(matching, key=lambda job: job['id'], default=None)


def rerun_if_failed(job):
    if job is None or job['status'] != 'completed' or job['conclusion'] != 'failure':
        return False
    api(f'repos/{os.environ["GITHUB_REPOSITORY"]}/actions/jobs/{job["id"]}/rerun', 'POST')
    print(f'Re-ran ci gate job {job["id"]} for {job["head_sha"]}')
    return True


def main():
    try:
        run = current_ci_run()
        if run is None:
            print('No ci run exists for this PR head; its gate will read the successful body check.')
            return 0
        for attempt in range(360):
            job = gate_job(run)
            if job is not None and job['status'] not in ('queued', 'in_progress'):
                rerun_if_failed(job)
                return 0
            time.sleep(10)
        print('ci gate did not finish within 60 minutes; no rerun was started.')
        return 0
    except (KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f'Unable to inspect or re-run ci gate: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
