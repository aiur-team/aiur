#!/usr/bin/env python3
"""Hermetic rollout and head-wiring checks for the PR-body gate."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pr_body', Path(__file__).with_name('check-pr-body.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PrBodyGateTests(unittest.TestCase):
    def test_worker_skill_example_matches_repository_template(self):
        root = Path(__file__).resolve().parent.parent
        skill = (root / '.claude/skills/aiur-agent/dev-loop.md').read_text()
        template = (root / '.github/pull_request_template.md').read_text()
        example = skill.split('```markdown\n', 1)[1].split('\n```', 1)[0]

        for heading in [
            '#### Context', '#### TL;DR', '#### Summary', '#### Alternatives',
            '#### Complexity routing', '#### Docs', '## Local tests',
        ]:
            self.assertIn(heading, example)
            self.assertIn(heading, template)

        self.assertIn('update `Tested head:` to the new full head SHA', skill)
        self.assertIn('scripts/check-pr-body.py', skill)
        self.assertNotIn('Do not include complexity-routing explanations', skill)

        body = example.replace('Closes #<!-- issue number -->', 'Closes #4345')
        body = body.replace('<!-- Why is this change needed? -->', 'Keep worker guidance aligned with CI.')
        body = body.replace('*<!-- Short description of the change -->*', '*Align PR guidance with the required gate.*')
        body = body.replace('<!-- High-level change -->', 'Update the worker PR body instructions.')
        body = body.replace('<!-- Alternatives considered and why not -->', 'Keep the template as the single source of truth.')
        body = body.replace('<!-- complexity:N or untagged -> treated as complexity:3 -->', 'complexity:3')
        body = body.replace('<!-- Skills and model/provider path when relevant -->', 'ce-work')
        body = body.replace('<!-- Why this route fit -->', 'The contained documentation and test change fits this route.')
        body = body.replace('<!-- Whether the recommendation was followed or changed -->', 'Followed the recommendation.')
        body = body.replace('- [ ] Docs updated in this PR — name the pages\n- [ ] Docs not required', '- [ ] Docs not required')
        body = body.replace('<!-- all / partial / none; at least the configured mode -->', 'partial')
        body = body.replace('<!-- full 40-character pushed SHA; update after every push -->', 'a' * 40)
        body = body.replace('<!-- base ref @ full 40-character SHA -->', 'main @ ' + 'b' * 40)
        body = body.replace('<!-- why these tests cover the change -->', 'The integration test exercises this example with the shared checker.')
        body = body.replace('<!-- exact command -->', 'python3 scripts/test-check-pr-body.py')
        body = body.replace('<!-- actual result -->', 'passed')

        with tempfile.TemporaryDirectory(prefix='pr-body-skill-') as scratch:
            body_path = Path(scratch) / 'body.md'
            body_path.write_text(body)
            result = subprocess.run([
                'elixir', '-r', str(root / 'src/lib/aiur/local_test_evidence.ex'),
                '-r', str(root / 'src/lib/mix/tasks/pr_body.check.ex'),
                '-e', 'Mix.start(); Mix.Tasks.PrBody.Check.run(System.argv())',
                '--', '--file', str(body_path), '--policy', 'partial', '--head', 'a' * 40,
            ], cwd=root, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PR body format OK', result.stdout)

    def test_both_sides_of_rollout_and_initial_unlanded_gate(self):
        cutoff = gate.timestamp('2026-10-11T12:00:00Z')
        for created, expected in [
            ('2026-10-11T11:59:59Z', False),
            ('2026-10-11T12:00:00Z', False),
            ('2026-10-11T12:00:01Z', True),
        ]:
            with self.subTest(created=created):
                self.assertEqual(gate.needs_check({'created_at': created}, cutoff), expected)
                with tempfile.TemporaryDirectory(prefix='pr-body-main-') as scratch:
                    metadata = Path(scratch) / 'pr.json'
                    metadata.write_text(json.dumps({'created_at': created, 'body': ''}))
                    with patch.object(sys, 'argv', ['check-pr-body', '--pr-json', str(metadata), '--base', 'main']), \
                         patch.object(gate, 'activation_time', return_value=cutoff), \
                         patch.object(gate, 'check_evidence', return_value=7) as check, \
                         patch('builtins.print'):
                        self.assertEqual(gate.main(), 7 if expected else 0)
                        self.assertEqual(check.call_count, int(expected))
        self.assertFalse(gate.needs_check({'created_at': '2026-10-11T12:00:01Z'}, None))

    def test_cutoff_is_first_parent_landing_not_feature_authorship(self):
        with tempfile.TemporaryDirectory(prefix='pr-body-history-') as scratch:
            root = Path(scratch)
            self.git(root, 'init', '-b', 'main')
            self.git(root, 'config', 'gc.auto', '0')
            self.git(root, 'config', 'maintenance.auto', 'false')
            self.git(root, 'config', 'gc.autoDetach', 'false')
            self.git(root, 'config', 'user.name', 'Test')
            self.git(root, 'config', 'user.email', 'test@example.invalid')
            (root / 'README').write_text('before rollout')
            self.git(root, 'add', 'README')
            self.commit(root, 'initial', '2026-10-11T10:00:00Z')
            self.assertIsNone(gate.activation_time(root, 'main'))
            self.git(root, 'switch', '-c', 'feature')
            (root / 'scripts').mkdir()
            (root / 'scripts/check-pr-body.py').write_text('gate')
            self.git(root, 'add', 'scripts/check-pr-body.py')
            self.commit(root, 'feature', '2026-10-11T11:00:00Z')
            self.git(root, 'switch', 'main')
            self.git(root, 'merge', '--no-ff', 'feature', '-m', 'land',
                     env=dict(os.environ, GIT_COMMITTER_DATE='2026-10-11T12:00:00Z'))
            self.assertEqual(gate.activation_time(root, 'main'), gate.timestamp('2026-10-11T12:00:00Z'))

    def test_passes_live_head_and_body_to_shared_checker_and_preserves_failure(self):
        pr = {'body': 'live body', 'head': {'sha': 'a' * 40}}
        def run(command, **kwargs):
            self.assertEqual(command[-2:], ['--head', pr['head']['sha']])
            self.assertEqual(Path(command[command.index('--file') + 1]).read_text(), 'live body')
            return subprocess.CompletedProcess(command, 7)
        with patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertEqual(gate.check_evidence(pr, Path.cwd()), 7)

    def git(self, root, *args, **kwargs):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT, **kwargs)

    def commit(self, root, message, date):
        self.git(root, 'commit', '-m', message,
                 env=dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date))


if __name__ == '__main__':
    unittest.main()
