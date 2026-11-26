"""Both publisher writes and discovery copies retain canonical pack bytes."""

import json
from pathlib import Path
import tempfile
import unittest

from publication_operator_case import AuthorityFreePublisher, context, FakeClient
from pack_format import format_pack


class PublisherPackFormatTests(unittest.TestCase):
    def test_mapping_checkpoint_writes_canonical_pack(self):
        with tempfile.TemporaryDirectory() as name:
            ctx = context(Path(name))
            publisher = AuthorityFreePublisher(FakeClient({}), ctx)
            mapping = {'repository': ctx.repository, 'number': 1, 'node_id': 'NODE_1', 'url': f'https://github.com/{ctx.repository}/issues/1'}
            publisher._persist_mapping(ctx.root_id, mapping)
            text = ctx.build_path.read_text()
            self.assertEqual(json.loads(text)['github_root'], mapping)
            self.assertEqual(text, format_pack(ctx.build))
            self.assertLess(len(text.splitlines()), 100)

    def test_materialization_and_discovery_write_canonical_pack(self):
        with tempfile.TemporaryDirectory() as name:
            ctx = context(Path(name))
            publisher = AuthorityFreePublisher(FakeClient({}), ctx)
            issues, matches = {}, {}
            for number, (logical_id, spec) in enumerate(ctx.specs.items(), 1):
                mapping = {'repository': ctx.repository, 'number': number, 'node_id': f'NODE_{number}', 'url': f'https://github.com/{ctx.repository}/issues/{number}'}
                issues[logical_id] = {'mapping': mapping, 'labels': list(spec.labels), 'title': spec.title, 'state': 'OPEN'}
                matches[logical_id] = [mapping]
            publisher._write_materialized({'issues': issues, 'marker_matches': matches, 'comment': {'url': 'example'}})
            publisher._write_discovery_pack()
            text = ctx.build_path.read_text()
            self.assertEqual(json.loads(text)['github_reconciliation']['receipt_schema_version'], 3)
            self.assertEqual(text, format_pack(ctx.build))
            self.assertEqual(ctx.discovery_path.read_bytes(), ctx.build_path.read_bytes())
            self.assertLess(len(text.splitlines()), 100)
