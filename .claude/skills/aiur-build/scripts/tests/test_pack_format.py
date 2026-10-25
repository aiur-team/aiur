"""Canonical layout and CLI byte checks."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PUBLICATION = Path(__file__).resolve().parents[1] / 'publication'
sys.path.insert(0, str(PUBLICATION))
from pack_format import format_pack


class PackFormatTests(unittest.TestCase):
    def test_round_trip_preserves_order_unicode_and_one_record_per_line(self):
        value = {'schema_version': 1, 'tickets': [{'title': 'Café\n🌱', 'id': 'T1'}, {'id': 'T2'}], 'empty': [], 'receipt': {'hash': 'abc'}}
        expected = '{\n  "schema_version": 1,\n  "tickets": [\n    {"title": "Café\\n🌱", "id": "T1"},\n    {"id": "T2"}\n  ],\n  "empty": [],\n  "receipt": {"hash": "abc"}\n}\n'
        self.assertEqual(format_pack(value), expected)
        self.assertEqual(json.loads(format_pack(value)), value)

    def test_check_rejects_pretty_bytes_then_accepts_formatted_bytes(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / 'pack.json'
            path.write_text(json.dumps({'tickets': [{'id': 'T1'}]}, indent=2))
            command = [sys.executable, str(PUBLICATION / 'pack_format.py')]
            rejected = subprocess.run([*command, '--check', str(path)], capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 1)
            self.assertIn('noncanonical pack layout', rejected.stdout)
            original = path.read_bytes()
            self.assertEqual(subprocess.run([*command, str(path)], capture_output=True).returncode, 0)
            self.assertNotEqual(path.read_bytes(), original)
            self.assertEqual(path.read_text(), '{\n  "tickets": [\n    {"id": "T1"}\n  ]\n}\n')
            self.assertEqual(subprocess.run([*command, '--check', str(path)], capture_output=True).returncode, 0)
            path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
            self.assertEqual(subprocess.run([*command, '--check', str(path)], capture_output=True).returncode, 1)
