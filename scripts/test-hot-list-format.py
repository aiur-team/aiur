#!/usr/bin/env python3
"""Regression tests for the actual hot-list formatter and split manifest reader."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from components.manifest import format_json, read_manifest, write_manifest

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('hot_list_format', REPO / 'scripts/check-hot-list-format.py')
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class HotListFormatTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for name in [*CHECKER.CODE_LISTS, 'src/test/support/state_writers_allowlist.exs', 'components.json', 'components.schema.json']:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, target)
        for name in ('components', 'scripts/components/allowlist'):
            shutil.copytree(REPO / name, self.root / name, dirs_exist_ok=True)

    def test_shipped_layout_passes(self):
        self.assertEqual(CHECKER.check(self.root), [])

    def test_single_line_manifest_list_fails(self):
        path = self.root / 'components/kernel.json'
        source = path.read_text()
        start = source.index('  "paths": [')
        end = source.index('\n  ],', start) + len('\n  ]')
        paths = json.loads(source)['paths']
        path.write_text(source[:start] + '  "paths": ' + json.dumps(paths) + source[end:])
        self.assertIn('components/kernel.json: run the hot-list formatter', CHECKER.check(self.root))

    def test_single_line_metadata_list_fails(self):
        path = self.root / 'src/lib/aiur/run_telemetry/lifecycle.ex'
        text = path.read_text()
        start = text.index('  @metadata_fields ~w(')
        end = text.index(')a', start) + 2
        text = text[:start] + '  @metadata_fields ~w(model effort feature epic tags blockers start_mode)a' + text[end:]
        path.write_text(text)
        self.assertIn('src/lib/aiur/run_telemetry/lifecycle.ex: @metadata_fields needs one item per line', CHECKER.check(self.root))

    def test_shard_format_sorts_string_sets_and_is_idempotent(self):
        manifest = read_manifest(self.root)
        kernel = next(c for c in manifest['components'] if c['id'] == 'kernel')
        kernel['paths'].reverse()
        expected = sorted(kernel['paths'])
        write_manifest(self.root, manifest)
        path = self.root / 'components/kernel.json'
        first = path.read_bytes()
        self.assertEqual(json.loads(first)['paths'], expected)
        write_manifest(self.root, read_manifest(self.root))
        self.assertEqual(path.read_bytes(), first)
        self.assertEqual(CHECKER.check(self.root), [])

    def test_future_object_list_order_is_preserved(self):
        values = [{'from': 'z'}, {'from': 'a'}]
        self.assertEqual(json.loads(format_json({'seams': values}))['seams'], values)

    def test_duplicate_or_unsorted_exemptions_fail(self):
        path = self.root / 'scripts/components/allowlist/kernel.tsv'
        path.write_text('R-private\tZ.Module\t#1 existing\nR-declared\tA.Module\t#2 existing\n')
        self.assertIn('scripts/components/allowlist/kernel.tsv: entries must be sorted and unique', CHECKER.check(self.root))
        path.write_text('R-private\tZ.Module\t#1 existing\n' * 2)
        self.assertIn('scripts/components/allowlist/kernel.tsv: entries must be sorted and unique', CHECKER.check(self.root))

    def test_flattened_writer_allowlist_fails(self):
        path = self.root / 'src/test/support/state_writers_allowlist.exs'
        comment, body = path.read_text().split('\n', 1)
        path.write_text(comment + '\n' + ' '.join(body.splitlines()) + '\n')
        self.assertIn('src/test/support/state_writers_allowlist.exs: writers need one tuple per line, with sorted unique keys', CHECKER.check(self.root))

    def test_future_inline_manifest_compatibility(self):
        expected = read_manifest(self.root)
        (self.root / 'components.json').write_text(format_json(expected))
        self.assertEqual(read_manifest(self.root), expected)

    def test_split_reference_rejects_unsafe_missing_duplicate_or_mismatched_files(self):
        index = self.root / 'components.json'
        original = json.loads(index.read_text())
        for files, message in [
            (['../kernel.json'], 'unsafe component file'),
            (['/components/kernel.json'], 'unsafe component file'),
            (['components/missing.json'], 'No such file'),
            (['components/kernel.json'] * 2, 'duplicate component file'),
            ([], 'nonempty string list'),
        ]:
            with self.subTest(files=files):
                index.write_text(format_json(dict(original, component_files=files)))
                with self.assertRaisesRegex((ValueError, OSError), message):
                    read_manifest(self.root)
        index.write_text(format_json(original))
        path = self.root / 'components/kernel.json'
        component = json.loads(path.read_text())
        path.write_text(format_json(dict(component, id='different')))
        with self.assertRaisesRegex(ValueError, 'id must match filename'):
            read_manifest(self.root)

    def test_split_manifest_does_not_accept_an_inline_override(self):
        path = self.root / 'components.json'
        value = json.loads(path.read_text())
        value['components'] = []
        path.write_text(format_json(value))
        with self.assertRaisesRegex(ValueError, 'never both'):
            read_manifest(self.root)

    def test_symlinked_shard_is_rejected(self):
        path = self.root / 'components/kernel.json'
        path.unlink()
        path.symlink_to(self.root / 'components/config.json')
        with self.assertRaisesRegex(ValueError, 'symlinked component file'):
            read_manifest(self.root)

    def test_invalid_shard_ids_cannot_overwrite_outside_components(self):
        manifest = read_manifest(self.root)
        outside = self.root / 'components.schema.json'
        outside.write_text('preserve schema')
        manifest['components'].append(dict(manifest['components'][0], id='../components.schema'))
        before = (self.root / 'components/config.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'unsafe component id'):
            write_manifest(self.root, manifest)
        self.assertEqual(outside.read_text(), 'preserve schema')
        self.assertEqual((self.root / 'components/config.json').read_bytes(), before)

    def test_unindexed_symlink_cannot_redirect_a_new_component_write(self):
        manifest = read_manifest(self.root)
        outside = self.root / 'components.schema.json'
        outside.write_text('preserve schema')
        (self.root / 'components/new-component.json').symlink_to(outside)
        manifest['components'].append(dict(manifest['components'][0], id='new-component'))
        with self.assertRaisesRegex(ValueError, 'symlinked component output'):
            write_manifest(self.root, manifest)
        self.assertEqual(outside.read_text(), 'preserve schema')

    def test_carry_command_accepts_git_newline_and_writes_valid_additions(self):
        import copy
        spec = importlib.util.spec_from_file_location('carry_command', REPO / 'scripts/carry-component-additions.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        before = read_manifest(self.root)
        after = copy.deepcopy(before)
        next(c for c in after['components'] if c['id'] == 'kernel')['paths'].append('src/lib/aiur/pr_addition.ex')

        def git_output(root, *args):
            if args == ('rev-parse', '--show-toplevel'):
                return str(self.root) + '\n'
            if args[0] == 'status':
                return ''
            if args[0] == 'merge-base':
                return 'base\n'
            self.fail(f'unexpected Git call: {args}')

        with patch('sys.argv', ['carry', '--pr', '123', '--root', str(self.root)]), \
                patch.object(module, 'git', side_effect=git_output), \
                patch.object(module.subprocess, 'run') as fetch, \
                patch.object(module, 'at_ref', side_effect=[before, after]):
            module.main()
        fetch.assert_called_once_with(['git', '-C', str(self.root), 'fetch', 'origin',
                                      'pull/123/head:refs/aiur/carry/123'], check=True)
        paths = next(c['paths'] for c in read_manifest(self.root)['components'] if c['id'] == 'kernel')
        self.assertEqual(set(paths), set(next(c['paths'] for c in before['components'] if c['id'] == 'kernel')) |
                         {'src/lib/aiur/pr_addition.ex'})

    def test_carry_preserves_both_sides_by_component_and_key(self):
        import copy
        spec = importlib.util.spec_from_file_location('carry', REPO / 'scripts/carry-component-additions.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        before = read_manifest(self.root)
        current, after = copy.deepcopy(before), copy.deepcopy(before)
        current_kernel = next(c for c in current['components'] if c['id'] == 'kernel')
        other_kernel = next(c for c in after['components'] if c['id'] == 'kernel')
        current_kernel['paths'].append('src/lib/aiur/current_addition.ex')
        other_kernel['paths'].append('src/lib/aiur/pr_addition.ex')
        result = module.replay(current, before, after)
        paths = next(c['paths'] for c in result['components'] if c['id'] == 'kernel')
        self.assertEqual(set(paths), set(current_kernel['paths']) | {'src/lib/aiur/pr_addition.ex'})
        self.assertEqual(module.replay(result, before, after), result)
        other_kernel['name'] = 'scalar change'
        with self.assertRaisesRegex(ValueError, 'scalar edits'):
            module.replay(current, before, after)
        other_kernel['name'] = current_kernel['name']
        other_kernel['paths'].remove(other_kernel['paths'][0])
        with self.assertRaisesRegex(ValueError, 'removals'):
            module.replay(current, before, after)


if __name__ == '__main__':
    unittest.main(verbosity=2)
