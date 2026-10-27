#!/usr/bin/env python3
"""Hermetic rollout and head-wiring checks for the PR-body gate."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pr_body', Path(__file__).with_name('check-pr-body.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def fenced_pr_examples(markdown):
    in_section = False
    block = []
    fence = None
    examples = []

    for line in markdown.splitlines():
        if not in_section:
            in_section = line == '## PR description shape'
            continue

        marker = re.match(r'^[ ]{0,3}(`{3,}|~{3,})', line)
        if fence is None:
            if line.startswith('## '):
                break
            if marker:
                delimiter = marker.group(1)
                fence = (delimiter[0], len(delimiter))
        elif marker:
            delimiter = marker.group(1)
            if (delimiter[0] == fence[0] and len(delimiter) >= fence[1]
                    and not line[len(delimiter):].strip()):
                example = '\n'.join(block)
                if re.match(r'(?:Closes|Fixes|Resolves|Refs) #', example):
                    examples.append(example)
                block = []
                fence = None
                continue
            block.append(line)
        else:
            block.append(line)

    return examples


class PrBodyGateTests(unittest.TestCase):
    def test_worker_skill_example_matches_repository_template(self):
        root = Path(__file__).resolve().parent.parent
        skill = (root / '.claude/skills/aiur-agent/dev-loop.md').read_text()
        template = (root / '.github/pull_request_template.md').read_text()
        self.assertIn('from `.github/pull_request_template.md`', skill)
        self.assertIn('`#### Complexity routing`', skill)
        self.assertIn('the strict `## Local tests` evidence block', skill)
        self.assertIn('`<ref> @ <40-character-sha>`', skill)
        self.assertIn('`` `command` -> result ``', skill)
        self.assertIn('update `Tested head:` to the new full head SHA', skill)
        self.assertIn('scripts/check-pr-body.py', skill)
        self.assertNotIn('Do not include complexity-routing explanations', skill)

        for example in fenced_pr_examples(skill):
            result = self.check_body(root, example, 'a' * 40)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        body = template.replace('Closes #<!-- issue number; use Fixes or Resolves if you prefer; list multiple as `Closes #43, #46` -->', 'Closes #4345')
        body = body.replace('<!-- Why is this change needed? Length <= 240 chars -->', 'Keep worker guidance aligned with CI.')
        body = body.replace('*<!-- A short description of what we are changing. Use simple language. Assume reader is not familiar with this code. Length <= 120 chars -->*', '*Align PR guidance with the required gate.*')
        body = body.replace('<!-- Details of the changes in bullet points -->', 'Update the worker PR body instructions.')
        body = body.replace('<!-- Keep them high level -->\n', '')
        body = body.replace('<!-- Each item <= 120 chars -->\n', '')
        body = body.replace('<!-- What alternatives have been considered? Why not? -->', 'Keep the repository template as the single source of truth.')
        body = body.replace('<!-- `complexity:N`, or `untagged -> treated as complexity:3` -->', 'complexity:3')
        body = body.replace('<!-- e.g. `ce-plan` -> `ce-work` -> `ce-code-review`; include model/provider path when relevant -->', 'ce-work')
        body = body.replace('<!-- Why this route fit this issue after inspection -->', 'The contained documentation and test change fits this route.')
        body = body.replace('<!-- Followed the recommendation, moved up/down, or explain why no adjustment was needed -->', 'Followed the recommendation.')
        body = body.replace('<!-- Keep one of the two lines below, delete the other, and delete every comment on the line you keep — `mix pr_body.check` rejects a body that still contains any `<!--`. Docs live in `website/docs-app/`: config keys in `reference/configuration.md`, commands and flags in `reference/cli.md`, user-facing surfaces in `guide/`, explanations in `concepts/`. Prefer editing an existing page over adding one — a wrong doc is worse than a missing one. -->\n\n', '')
        body = body.replace('- [ ] Docs updated in this PR — name the pages <!-- required for: a new or changed config key, a CLI command or flag, an operator-set env var, a new user-facing surface (dashboard page, TUI view, Stream Deck mode, panel), or a change that makes an existing page wrong -->\n- [ ] Docs not required <!-- internal refactor, bug fix restoring already-documented behavior, test-only change, or performance work with no interface change -->', '- [ ] Docs not required')
        body = body.replace('<!-- all / partial / none; at least the configured merge_policy.local_tests mode -->', 'partial')
        body = body.replace('<!-- full 40-character SHA pushed; update after every push -->', 'a' * 40)
        body = body.replace('<!-- base ref @ full SHA -->', 'main @ ' + 'b' * 40)
        body = body.replace('<!-- why this set covers changed tests, source mirrors, direct callers and deleted names; full suite for shared support/build/dependency/runtime config -->', 'The integration test exercises the skill guidance with the shared checker.')
        body = body.replace('<!-- exact command -->', 'python3 scripts/test-check-pr-body.py')
        body = body.replace('<!-- actual result, including failures or blockers -->', 'passed')

        with tempfile.TemporaryDirectory(prefix='pr-body-skill-') as scratch:
            body_path = Path(scratch) / 'body.md'
            body_path.write_text(body)
            result = self.check_body(root, body_path.read_text(), 'a' * 40, body_path)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PR body format OK', result.stdout)

    def test_section_scanner_ignores_headings_inside_fenced_examples(self):
        for fence in ('```markdown', '~~~markdown'):
            with self.subTest(fence=fence):
                self.assert_fenced_example_survives_section_scan(fence)

    def assert_fenced_example_survives_section_scan(self, fence):
        marker = fence[0] * len(fence.split('markdown', 1)[0])
        markdown = f'''## PR description shape
{fence}
Closes #4345
## Still inside this example
not a section boundary
{marker}
## Following section
outside the example
'''

        examples = fenced_pr_examples(markdown)

        self.assertEqual(len(examples), 1)
        self.assertIn('## Still inside this example', examples[0])
        self.assertNotIn('## Following section', examples[0])
        result = self.check_body(
            Path(__file__).resolve().parent.parent, examples[0], 'a' * 40
        )
        self.assertNotEqual(result.returncode, 0)

    def check_body(self, root, body, head, body_path=None):
        with tempfile.TemporaryDirectory(prefix='pr-body-example-') as scratch:
            path = body_path or Path(scratch) / 'body.md'
            path.write_text(body)
            return subprocess.run([
                'elixir', '-r', str(root / 'src/lib/aiur/local_test_evidence.ex'),
                '-r', str(root / 'src/lib/aiur/pr_body_lint.ex'),
                '-r', str(root / 'src/lib/mix/tasks/pr_body.check.ex'),
                '-e', 'Mix.start(); Mix.Tasks.PrBody.Check.run(System.argv())',
                '--', '--file', str(path), '--policy', 'partial', '--head', head,
            ], cwd=root, text=True, capture_output=True)

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

    def carry_pr(self, contribution_at_head):
        tested, head = 'c' * 40, 'a' * 40
        patch_at = lambda added: {'filename': 'src/lib/a.ex', 'sha': added, 'patch': f'@@ -1,1 +1,2 @@\n l1\n{added}'}
        main = {'status': 'ahead', 'files': [{'filename': 'src/lib/b.ex', 'sha': 'm', 'patch': '@@ -1,1 +1,1 @@\n-x\n+y'}]}
        comparisons = {
            ('main', tested): {'merge_base_commit': {'sha': 'b1'}, 'files': [patch_at('+feature')]},
            ('main', head): {'merge_base_commit': {'sha': 'b2'}, 'files': [patch_at(contribution_at_head)]},
            ('b1', 'b2'): main,
        }
        pr = {'body': f'## Local tests\nTested head: {tested}\n', 'head': {'sha': head},
              'base': {'sha': 'main'}}
        root = Path(__file__).resolve().parent.parent
        with patch.object(gate, 'is_ancestor', return_value=True), \
             patch.object(gate, 'only_merges_after', return_value=True), \
             patch.object(gate, 'compare', side_effect=lambda _root, base, ref: comparisons[(base, ref)]):
            return gate.evidence_head(pr, root)

    def test_merge_of_main_only_accepts_the_tested_ancestor(self):
        self.assertEqual(self.carry_pr('+feature'), ('c' * 40, f'tested at {"c" * 40}; later commits are main merges only'))

    def test_one_extra_contribution_line_requires_the_exact_head(self):
        self.assertEqual(self.carry_pr('+feature\n+extra'), ('a' * 40, 'exact head'))

    def test_non_ancestor_tested_head_requires_the_exact_head(self):
        pr = {'body': f'Tested head: {"c" * 40}\n', 'head': {'sha': 'a' * 40}}
        with patch.object(gate, 'is_ancestor', return_value=False), patch.object(gate, 'compare') as fetch:
            self.assertEqual(gate.evidence_head(pr, Path.cwd()), ('a' * 40, 'exact head'))
            fetch.assert_not_called()

    def test_non_merge_commit_after_tested_head_requires_exact_head(self):
        tested, head = 'c' * 40, 'a' * 40
        pr = {'body': f'Tested head: {tested}\n', 'head': {'sha': head}, 'base': {'sha': 'main'}}
        with patch.object(gate, 'is_ancestor', return_value=True), \
             patch.object(gate, 'only_merges_after', return_value=False), \
             patch.object(gate, 'compare') as compare:
            self.assertEqual(gate.evidence_head(pr, Path.cwd()), (head, 'exact head'))
            compare.assert_not_called()

    def test_merge_with_changed_contribution_requires_exact_head(self):
        self.assertEqual(self.carry_pr('+feature\n+extra'), ('a' * 40, 'exact head'))

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
