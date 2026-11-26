#!/usr/bin/env python3
"""Ensure a body fix re-runs only a failed ci gate job."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name('rerun-failed-ci-gate.py')
SPEC = importlib.util.spec_from_file_location('rerun_ci_gate', MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RerunFailedCiGateTest(unittest.TestCase):
    def test_body_workflow_retries_only_after_validation_on_body_events(self):
        workflow = (Path(__file__).parents[1] / '.github/workflows/pr-body.yml').read_text()
        ci_workflow = (Path(__file__).parents[1] / '.github/workflows/ci.yml').read_text()
        self.assertIn('types: [opened, edited, synchronize, reopened]', workflow)
        ci_pull_request = re.search(
            r'pull_request:\s*\n\s+types:\s*\[([^\]]+)\]', ci_workflow,
        )
        self.assertIsNotNone(ci_pull_request)
        ci_events = {event.strip() for event in ci_pull_request.group(1).split(',')}
        self.assertNotIn('edited', ci_events)
        validation = workflow.index('name: Check PR body and local-test evidence')
        rerun = workflow.index('name: Re-run only a failed ci gate')
        self.assertLess(validation, rerun)
        self.assertRegex(workflow, r'actions:\s+write')
        self.assertIn('gate-rerun:', workflow)
        self.assertIn('needs: pr-body', workflow[workflow.index('gate-rerun:'):])
        self.assertIn("if: ${{ needs.pr-body.result == 'success' }}", workflow[rerun:])
        self.assertIn('scripts/rerun-failed-ci-gate.py', workflow[rerun:])
        self.assertIn('GH_TOKEN: ${{ github.token }}', workflow[rerun:])
        self.assertIn('Require latest PR-body check', ci_workflow)

    def test_failed_gate_uses_single_job_rerun_endpoint(self):
        job = {'id': 71, 'head_sha': 'head', 'status': 'completed', 'conclusion': 'failure'}
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'aiur-team/aiur'}):
            with patch.object(MODULE, 'api') as api:
                self.assertTrue(MODULE.rerun_if_failed(job))
        api.assert_called_once_with('repos/aiur-team/aiur/actions/jobs/71/rerun', 'POST')

    def test_current_head_run_and_gate_are_selected_before_rerun(self):
        runs_response = {
            'workflow_runs': [
                {'id': 1, 'name': 'ci', 'head_sha': 'old-head', 'run_number': 90},
                {'id': 2, 'name': 'ci', 'head_sha': 'current-head', 'run_number': 91},
                {'id': 3, 'name': 'pr body', 'head_sha': 'current-head', 'run_number': 92},
                {'id': 4, 'name': 'ci', 'head_sha': 'current-head', 'run_number': 90},
            ],
        }
        jobs_response = {
            'jobs': [
                {'id': 10, 'name': 'ci gate', 'head_sha': 'old-head',
                 'status': 'completed', 'conclusion': 'failure'},
                {'id': 20, 'name': 'ci gate', 'head_sha': 'current-head',
                 'status': 'completed', 'conclusion': 'failure'},
                {'id': 30, 'name': 'lint', 'head_sha': 'current-head',
                 'status': 'completed', 'conclusion': 'failure'},
                {'id': 21, 'name': 'ci gate', 'head_sha': 'current-head',
                 'status': 'completed', 'conclusion': 'failure'},
            ],
        }
        with patch.dict(os.environ, {
            'GITHUB_REPOSITORY': 'aiur-team/aiur', 'PR_HEAD': 'current-head',
        }):
            with patch.object(
                MODULE, 'api', side_effect=[runs_response, jobs_response, None],
            ) as api:
                selected_run = MODULE.current_ci_run()
                selected_job = MODULE.gate_job(selected_run)
                self.assertTrue(MODULE.rerun_if_failed(selected_job))

        self.assertEqual(selected_run['id'], 2)
        self.assertEqual(selected_job['id'], 21)
        self.assertEqual(api.call_args_list[0].args,
                         ('repos/aiur-team/aiur/actions/runs?head_sha=current-head&event=pull_request&per_page=100',))
        self.assertEqual(api.call_args_list[1].args,
                         ('repos/aiur-team/aiur/actions/runs/2/jobs?per_page=100',))
        self.assertEqual(api.call_args_list[2].args,
                         ('repos/aiur-team/aiur/actions/jobs/21/rerun', 'POST'))

    def test_main_without_ci_run_does_not_rerun(self):
        with patch.object(MODULE, 'current_ci_run', return_value=None):
            with patch.object(MODULE, 'api') as api:
                self.assertEqual(MODULE.main(), 0)
        api.assert_not_called()

    def test_main_waits_for_gate_then_reruns_only_failed_job(self):
        run = {'id': 45, 'head_sha': 'current-head'}
        pending = {'jobs': [{'id': 99, 'name': 'ci gate', 'head_sha': 'current-head',
                             'status': 'in_progress', 'conclusion': None}]}
        failed = {'jobs': [{'id': 99, 'name': 'ci gate', 'head_sha': 'current-head',
                            'status': 'completed', 'conclusion': 'failure'}]}
        with patch.object(MODULE, 'current_ci_run', return_value=run):
            with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'aiur-team/aiur'}):
                with patch.object(MODULE, 'api', side_effect=[pending, failed, None]) as api:
                    with patch.object(MODULE.time, 'sleep') as sleep:
                        self.assertEqual(MODULE.main(), 0)
        self.assertEqual(api.call_args_list, [
            unittest.mock.call('repos/aiur-team/aiur/actions/runs/45/jobs?per_page=100'),
            unittest.mock.call('repos/aiur-team/aiur/actions/runs/45/jobs?per_page=100'),
            unittest.mock.call('repos/aiur-team/aiur/actions/jobs/99/rerun', 'POST'),
        ])
        sleep.assert_called_once_with(10)

    def test_main_does_not_wait_for_a_gate_that_has_not_started(self):
        run = {'id': 47, 'head_sha': 'current-head'}
        for jobs in [[], [{'id': 101, 'name': 'ci gate', 'head_sha': 'current-head',
                           'status': 'queued', 'conclusion': None}]]:
            with patch.object(MODULE, 'current_ci_run', return_value=run):
                with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'aiur-team/aiur'}):
                    with patch.object(MODULE, 'api', return_value={'jobs': jobs}) as api:
                        with patch.object(MODULE.time, 'sleep') as sleep:
                            self.assertEqual(MODULE.main(), 0)
            api.assert_called_once_with('repos/aiur-team/aiur/actions/runs/47/jobs?per_page=100')
            sleep.assert_not_called()

    def test_gate_rerun_job_cannot_squat_a_runner(self):
        workflow = (Path(__file__).parents[1] / '.github/workflows/pr-body.yml').read_text()
        self.assertIn('timeout-minutes: 5', workflow[workflow.index('gate-rerun:'):])

    def test_main_does_not_rerun_green_gate(self):
        run = {'id': 46, 'head_sha': 'current-head'}
        green = {'jobs': [{'id': 100, 'name': 'ci gate', 'head_sha': 'current-head',
                           'status': 'completed', 'conclusion': 'success'}]}
        with patch.object(MODULE, 'current_ci_run', return_value=run):
            with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'aiur-team/aiur'}):
                with patch.object(MODULE, 'api', return_value=green) as api:
                    self.assertEqual(MODULE.main(), 0)
        api.assert_called_once_with('repos/aiur-team/aiur/actions/runs/46/jobs?per_page=100')

    def test_main_returns_failure_when_api_errors(self):
        error = subprocess.CalledProcessError(4, ['gh', 'api'])
        with patch.dict(os.environ, {
            'GITHUB_REPOSITORY': 'aiur-team/aiur', 'PR_HEAD': 'current-head',
        }):
            with patch.object(MODULE, 'api', side_effect=error):
                with patch('sys.stderr'):
                    self.assertEqual(MODULE.main(), 1)

    def test_successful_or_pending_gate_is_left_alone(self):
        for status, conclusion in [
            ('completed', 'success'), ('completed', 'cancelled'),
            ('in_progress', None), ('queued', None),
        ]:
            job = {'id': 72, 'head_sha': 'head', 'status': status, 'conclusion': conclusion}
            with patch.object(MODULE, 'api') as api:
                self.assertFalse(MODULE.rerun_if_failed(job))
            api.assert_not_called()


if __name__ == '__main__':
    unittest.main()
