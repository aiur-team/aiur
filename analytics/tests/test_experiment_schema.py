"""Small structural JSON-schema validator; runtime remains dependency-free."""

import json
import re
from datetime import datetime
from copy import deepcopy
from pathlib import Path
import unittest

from analytics.stats import analyze
from tests.test_stats_analyze import fixture

SCHEMA = json.loads((Path(__file__).resolve().parents[1] / 'schema/experiment-result.v1.json').read_text())


def validate(value, schema):
    if '$ref' in schema:
        return validate(value, SCHEMA['$defs'][schema['$ref'].split('/')[-1]])
    if 'const' in schema and value != schema['const']:
        raise ValueError('const')
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError('enum')
    types = schema.get('type')
    if types:
        types = [types] if isinstance(types, str) else types
        valid = {'object': isinstance(value, dict), 'array': isinstance(value, list),
                 'string': isinstance(value, str), 'number': type(value) in (int, float),
                 'integer': type(value) is int, 'null': value is None}
        if not any(valid[t] for t in types):
            raise ValueError('type')
    if type(value) in (int, float):
        if 'minimum' in schema and value < schema['minimum']:
            raise ValueError('minimum')
        if 'maximum' in schema and value > schema['maximum']:
            raise ValueError('maximum')
    if isinstance(value, str):
        if 'pattern' in schema and re.search(schema['pattern'], value) is None:
            raise ValueError('pattern')
        if schema.get('format') == 'date-time':
            date = datetime.fromisoformat(value.replace('Z', '+00:00'))
            if date.tzinfo is None:
                raise ValueError('timezone')
    if isinstance(value, (dict, list)):
        prefix = 'Properties' if isinstance(value, dict) else 'Items'
        if 'min' + prefix in schema and len(value) < schema['min' + prefix]:
            raise ValueError('min' + prefix)
        if 'max' + prefix in schema and len(value) > schema['max' + prefix]:
            raise ValueError('max' + prefix)
    if isinstance(value, list) and schema.get('uniqueItems'):
        if len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            raise ValueError('uniqueItems')
    if isinstance(value, dict):
        if any(key not in value for key in schema.get('required', [])):
            raise ValueError('required')
        for key, item in value.items():
            properties = schema.get('properties', {})
            if key in properties:
                validate(item, properties[key])
            elif schema.get('additionalProperties') is False:
                raise ValueError('additionalProperties')
            elif isinstance(schema.get('additionalProperties'), dict):
                validate(item, schema['additionalProperties'])
    if isinstance(value, list) and 'items' in schema:
        for item in value:
            validate(item, schema['items'])
    for part in schema.get('allOf', []):
        try:
            validate(value, part['if'])
        except ValueError:
            validate(value, part.get('else', {}))
        else:
            validate(value, part.get('then', {}))
    if 'not' in schema:
        try:
            validate(value, schema['not'])
        except ValueError:
            pass
        else:
            raise ValueError('not')
    if 'anyOf' in schema:
        for part in schema['anyOf']:
            try:
                validate(value, part)
                break
            except ValueError:
                pass
        else:
            raise ValueError('anyOf')


class SchemaTest(unittest.TestCase):
    def test_result_schema_accepts_bodies_and_rejects_unknown_status(self):
        for name in ['shift', 'guard', 'equivalent', 'inconclusive']:
            snapshot, spec = fixture(name)
            envelope = {'generated_at': '2026-10-09T00:00:00Z', 'body': analyze(snapshot, spec)}
            validate(envelope, SCHEMA)
            envelope['body']['metrics']['latency']['status'] = 'probably_good'
            with self.assertRaises(ValueError):
                validate(envelope, SCHEMA)

    def test_guard_schema_rejects_test_result(self):
        snapshot, spec = fixture('guard')
        envelope = {'generated_at': '2026-10-09T00:00:00Z', 'body': analyze(snapshot, spec)}
        envelope['body']['metrics']['latency']['tests'] = {}
        with self.assertRaises(ValueError):
            validate(envelope, SCHEMA)

    def test_invalid_counts_groups_hashes_and_timestamp(self):
        snapshot, spec = fixture()
        good = {'generated_at': '2026-10-09T00:00:00Z', 'body': analyze(snapshot, spec)}
        mutations = [
            lambda e: e.update(generated_at='not-a-date'),
            lambda e: e['body'].update(group_order=['a']),
            lambda e: e['body'].update(group_order=['a','b','c']),
            lambda e: e['body'].update(group_order=['a','a']),
            lambda e: e['body']['inputs'].update(snapshot_sha256='invalid'),
            lambda e: e['body']['metrics']['latency']['groups']['a'].update(n=-1),
        ]
        for mutation in mutations:
            bad = deepcopy(good)
            mutation(bad)
            with self.assertRaises(ValueError):
                validate(bad, SCHEMA)
