"""Named docs fixtures exercised through the real check-components CLI."""
import copy
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
from .public_fixtures import fixture_component


def run(repo, selected):
    ran = set()
    base = dict(manifest_version=1, directory_published=False,
                components=[fixture_component('a', ['src/lib/absent.ex'])], features=[])
    base['components'][0].update(docs=['guide/fixture.md#build-order'], config=['build_order'],
                                 env=['GITHUB_APP_*', 'AIUR_AMBIENT'], capabilities=['identity', 'harness.codex.native_question'])

    def check(name, change=lambda m: None, code=0, message='docs references valid', files=None, args=('--docs',), remove=None):
        if selected and name not in selected:
            return
        ran.add(name)
        manifest = copy.deepcopy(base)
        change(manifest)
        with tempfile.TemporaryDirectory(prefix='component-docs-') as directory:
            root = Path(directory)
            fixtures = {
                'components.json': json.dumps(manifest),
                'components.schema.json': (repo / 'components.schema.json').read_text(),
                'website/docs-app/guide/fixture.md': '# Fixture\n\n## build_order\n',
                'website/docs-app/reference/configuration.md': '## tracker\n',
                'website/docs-app/reference/configuration-build-order.md': '## build_order\n',
                'src/lib/aiur/env/schema.ex': '{"GITHUB_APP_ID", type: :string},\n{"AIUR_AMBIENT", example: false},\n',
                'packages/aiur-contracts/src/index.ts': (repo / 'packages/aiur-contracts/src/index.ts').read_text(),
                'website/docs-app/.vitepress/config.ts': 'export default {}\n'}
            fixtures.update(files or {})
            for name_, content in fixtures.items():
                path = root / name_
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            if remove:
                (root / remove).unlink()
            env = dict(os.environ, AIUR_COMPONENTS_ROOT=str(root), PATH='')
            command = [sys.executable, str(repo / 'scripts/check-components.py'), *args]
            if args == ('ci-step',):
                workflow = (repo / '.github/workflows/ci.yml').read_text()
                job = re.search(r'^  workflow-security:\n(.*?)(?=^  [\w-]+:|\Z)', workflow, re.MULTILINE | re.DOTALL)[1]
                assert 'docs_only' not in job, 'workflow security must run on docs-only PRs'
                step = re.search(r'run: (python3 scripts/check-components.py --docs[^\n]*)', job)
                assert step, 'workflow security must invoke --docs'
                command = ['bash', '-c', step[1]]
                env['PATH'] = os.environ['PATH']
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True)
            output = result.stdout + result.stderr
            assert result.returncode == code, f'{name}: expected {code}, got {result.returncode}: {output}'
            assert message in output, f'{name}: missing {message!r}: {output}'
            print(f'PASS: {name}')

    def field(key, value):
        return lambda m: m['components'][0].update({key: value})

    check('docs_tree_without_sources_passes')
    check('docs_schema_invalid_fails', lambda m: m.update(directory_published='false'), 1, '/directory_published')
    check('directory_published_required_fails', lambda m: m.pop('directory_published'), 1, '/directory_published: required')
    check('docs_path_missing_fails', field('docs', ['guide/nope.md']), 1, 'a: docs path not found: guide/nope.md')
    check('docs_anchor_missing_fails', field('docs', ['guide/fixture.md#absent']), 1, 'a: docs anchor not found')
    check('docs_anchor_slug_passes', field('docs', ['guide/fixture.md#_123-cafe-pr-health']),
          files={'website/docs-app/guide/fixture.md': '## 123 Café pr_health\n'})
    check('docs_fenced_anchor_fails', field('docs', ['guide/fixture.md#absent']), 1, 'a: docs anchor not found',
          files={'website/docs-app/guide/fixture.md': '```md\n## absent\n```\n'})
    check('docs_custom_and_duplicate_anchors_pass', field('docs', ['guide/fixture.md#custom', 'guide/fixture.md#title-1']),
          files={'website/docs-app/guide/fixture.md': '## Explicit {#custom}\n## **Title**\n## Title\n'})
    check('docs_invalid_fence_closer_fails', field('docs', ['guide/fixture.md#absent']), 1, 'a: docs anchor not found',
          files={'website/docs-app/guide/fixture.md': '```md\n```not-a-closing-fence\n## absent\n```\n'})
    check('docs_commented_anchor_fails', field('docs', ['guide/fixture.md#absent']), 1, 'a: docs anchor not found',
          files={'website/docs-app/guide/fixture.md': '<!--\n## absent\n-->\n'})
    check('docs_entity_anchor_passes', field('docs', ['guide/fixture.md#a-b']),
          files={'website/docs-app/guide/fixture.md': '## A &amp; B\n'})
    check('docs_raw_entity_anchor_fails', field('docs', ['guide/fixture.md#a-amp-b']), 1, 'a: docs anchor not found',
          files={'website/docs-app/guide/fixture.md': '## A &amp; B\n'})
    check('setup_docs_missing_fails' , field('install', dict(type='setup', docs='guide/nope.md')), 1, 'a: docs path not found')
    check('config_heading_missing_fails', field('config', ['no_such_section']), 1, 'a: config section no_such_section')
    check('config_heading_exact_match_fails', field('config', ['build_order']), 1, 'a: config section build_order',
          files={'website/docs-app/reference/configuration-build-order.md': '### build_order\n## build-order\n'})
    check('config_fenced_heading_fails', code=1, message='a: config section build_order',
          files={'website/docs-app/reference/configuration-build-order.md': '```md\n## build_order\n```\n'})
    check('env_unknown_fails' , field('env', ['NOT_A_VAR']), 1, 'a: env var NOT_A_VAR unknown')
    check('env_prefix_unknown_fails', field('env', ['NOT_A_*']), 1, 'a: env var NOT_A_* unknown')
    check('env_empty_schema_exits_2', code=2, message='env schema matcher found zero declarations',
          files={'src/lib/aiur/env/schema.ex': ''})
    check('capability_unknown_fails', field('capabilities', ['x.y']), 1, 'a: capability x.y not in aiur-contracts')
    check('capability_template_id_passes', field('capabilities', ['harness.codex.native_question']))
    for label, id_ in [('bare', 'harness.native_question'), ('nested', 'harness.foo.bar.native_question')]:
        check('capability_template_' + label + '_fails', field('capabilities', [id_]), 1,
              'a: capability ' + id_ + ' not in aiur-contracts')
    check('capability_template_uppercase_fails', field('capabilities', ['harness.Foo.native_question']), 1, '/capabilities/0: invalid string')
    check('capability_enum_missing_exits_2', code=2, message='aiur-contracts capability enum missing',
          files={'packages/aiur-contracts/src/index.ts': ''})
    check('sidebar_missing_when_published_fails', lambda m: m.update(directory_published=True), 1,
          'sidebar link /reference/components missing')
    check('sidebar_present_when_published_passes', lambda m: m.update(directory_published=True),
          files={'website/docs-app/.vitepress/config.ts': "link: '/reference/components'"})
    check('sidebar_not_required_when_unpublished')
    check('dangling_component_ref_fails', field('requires', ['ghost']), 1, 'unknown component ghost')
    check('dangling_optional_ref_fails', field('optional', ['ghost']), 1, 'unknown component ghost')
    feature = dict(id='MP-N2', name='Pairing', summary='Pairs a device.', extends=['ghost'], adds=[], public=False, shipped_in=None)
    check('dangling_feature_ref_fails', lambda m: m.update(features=[feature]), 1, 'MP-N2: unknown component ghost')
    check('missing_manifest_exits_2', code=2, message='components.json:', remove='components.json')
    check('docs_invalid_json_exits_2', code=2, message='components.json:', files={'components.json': '{bad'})
    check('full_checker_checks_docs', field('docs', ['guide/nope.md']), 1, 'a: docs path not found', args=())
    check('ci_docs_only_step_rejects_broken_link', field('docs', ['guide/nope.md']), 1,
          'a: docs path not found: guide/nope.md', args=('ci-step',))
    check('split_manifest_docs_passes', lambda m: (m.update(component_files=['components/a.json']), m.pop('components')),
          files={'components/a.json': json.dumps(base['components'][0])})
    return ran
