"""Validate the ledger's small JSON Schema vocabulary without dependencies."""
import json
from pathlib import Path

SCHEMA = json.loads((Path(__file__).resolve().parents[2] / 'schema/ticket-record.v1.json').read_text())


def validate(value, schema=None, path='$'):
    schema = SCHEMA if schema is None else schema
    if '$ref' in schema:
        schema = SCHEMA['$defs'][schema['$ref'].rsplit('/', 1)[-1]]
    types = {'object': lambda x: isinstance(x, dict), 'array': lambda x: isinstance(x, list),
             'string': lambda x: isinstance(x, str), 'integer': lambda x: type(x) is int,
             'number': lambda x: type(x) in (int, float), 'boolean': lambda x: type(x) is bool,
             'null': lambda x: x is None}
    expected = schema.get('type')
    if expected and not any(types[t](value) for t in (expected if isinstance(expected, list) else [expected])):
        raise ValueError(path + ': invalid type')
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError(path + ': invalid enum')
    if 'minimum' in schema and value is not None and value < schema['minimum']:
        raise ValueError(path + ': below minimum')
    if isinstance(value, dict):
        if set(schema.get('required', [])) - value.keys():
            raise ValueError(path + ': missing fields')
        properties = schema.get('properties', {})
        for key, item in value.items():
            rule = properties.get(key, schema.get('additionalProperties', {}))
            if rule is False:
                raise ValueError(path + ': unknown field ' + key)
            if isinstance(rule, dict):
                validate(item, rule, path + '.' + key)
    if isinstance(value, list) and 'items' in schema:
        for index, item in enumerate(value):
            validate(item, schema['items'], path + '[%d]' % index)
