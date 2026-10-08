#!/usr/bin/env python3
"""Validate the component manifest and ownership of tracked source files."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOTS = ('src/lib', 'packages', 'packaging')
EXCLUDED = {'node_modules', '_build', 'deps', 'dist'}


class InvalidManifest(ValueError):
    pass


def validate(value, schema, document, pointer=''):
    """Interpret only the JSON Schema keywords used by components.schema.json."""
    def reject(reason):
        raise InvalidManifest(f'{pointer or "/"}: {reason}')

    if '$ref' in schema:
        target = document
        for part in schema['$ref'].removeprefix('#/').split('/'):
            target = target[part]
        validate(value, target, document, pointer)
        return
    types = {'object': dict, 'array': list, 'string': str, 'integer': int,
             'boolean': bool, 'null': type(None)}
    if 'type' in schema:
        allowed = schema['type']
        allowed = allowed if isinstance(allowed, list) else [allowed]
        if not any(type(value) is types[t] for t in allowed):
            reject(f'expected {allowed}')
    if 'const' in schema and (type(value) is not type(schema['const']) or value != schema['const']):
        reject(f'expected {schema["const"]!r}')
    if 'enum' in schema and value not in schema['enum']:
        reject(f'expected one of {schema["enum"]}')
    if isinstance(value, dict):
        properties = schema.get('properties', {})
        for key in schema.get('required', []):
            if key not in value:
                raise InvalidManifest(f'{pointer}/{key}: required property')
        for key, child in value.items():
            escaped = key.replace('~', '~0').replace('/', '~1')
            if key in properties:
                validate(child, properties[key], document, f'{pointer}/{escaped}')
            elif schema.get('additionalProperties') is False:
                raise InvalidManifest(f'{pointer}/{escaped}: unknown property')
    if isinstance(value, list):
        if len(value) < schema.get('minItems', 0):
            reject('too few items')
        if schema.get('uniqueItems') and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            reject('duplicate items')
        for index, child in enumerate(value):
            validate(child, schema.get('items', {}), document, f'{pointer}/{index}')
        if 'contains' in schema:
            found = False
            for child in value:
                try:
                    validate(child, schema['contains'], document, pointer)
                    found = True
                except InvalidManifest:
                    pass
            if not found:
                reject('no matching item')
    if isinstance(value, str):
        if len(value) < schema.get('minLength', 0):
            reject('empty string')
        if 'pattern' in schema and not re.search(schema['pattern'], value):
            reject('invalid string')
    if type(value) is int:
        if value < schema.get('minimum', value) or value > schema.get('maximum', value):
            reject('out of range')
    if 'if' in schema:
        try:
            validate(value, schema['if'], document, pointer)
        except InvalidManifest:
            return
        validate(value, schema['then'], document, pointer)


def load_manifest(root):
    document = json.loads((root / 'components.schema.json').read_text())
    manifest = json.loads((root / 'components.json').read_text())
    validate(manifest, document, document)
    ids = [c['id'] for c in manifest['components']]
    if len(ids) != len(set(ids)):
        raise InvalidManifest('/components: duplicate component id')
    for index, component in enumerate(manifest['components']):
        for edge in ('requires', 'optional', 'shared_with'):
            for target in component.get(edge, []):
                if target not in ids:
                    raise InvalidManifest(f'/components/{index}/{edge}: unknown component {target}')
        for pattern in component['paths']:
            if pattern.startswith('/') or any(p in ('', '.', '..') for p in pattern.split('/')) or '\\' in pattern:
                raise InvalidManifest(f'/components/{index}/paths: expected repository-relative glob')
    return manifest


def source_files(root):
    try:
        probe = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                               capture_output=True, text=True)
    except FileNotFoundError:
        probe = None
    if probe is not None and probe.returncode == 0 and Path(probe.stdout.strip()).resolve() == root:
        result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'],
                                capture_output=True, check=True)
        return sorted(os.fsdecode(p) for p in result.stdout.split(b'\0') if p)
    files = []
    for directory, children, names in os.walk(root):
        children[:] = sorted(c for c in children if c not in EXCLUDED | {'.git'})
        files.extend((Path(directory) / n).relative_to(root).as_posix() for n in names)
    return sorted(files)


def glob_regex(pattern):
    """A star stays within a segment; a double star spans any depth."""
    expression = ''
    index = 0
    while index < len(pattern):
        if pattern[index:index + 3] == '**/':
            expression += '(?:.*/)?'
            index += 3
        elif pattern[index:index + 2] == '**':
            expression += '.*'
            index += 2
        elif pattern[index] == '*':
            expression += '[^/]*'
            index += 1
        else:
            expression += re.escape(pattern[index])
            index += 1
    return re.compile(expression + r'\Z')


def ownership(manifest, files):
    patterns = [(c['id'], p, glob_regex(p), len(p.split('*', 1)[0]))
                for c in manifest['components'] for p in c['paths']]
    matched = set()
    counts = {c['id']: 0 for c in manifest['components']}
    problems = []
    file_owners = {}
    for path in files:
        candidates = [(owner, pattern, specificity) for owner, pattern, regex, specificity in patterns
                      if regex.fullmatch(path)]
        matched.update((owner, pattern) for owner, pattern, _ in candidates)
        if not any(path.startswith(prefix + '/') for prefix in ROOTS):
            continue
        if not candidates:
            nearest = max(patterns, key=lambda row: len(os.path.commonprefix([path, row[1]])), default=None)
            hint = f'; nearest glob {nearest[0]}: {nearest[1]}' if nearest else ''
            problems.append((path, f'unowned file{hint}'))
            continue
        specificity = max(row[2] for row in candidates)
        owners = sorted({owner for owner, _, score in candidates if score == specificity})
        if len(owners) > 1:
            problems.append((path, f'ambiguous ownership: {", ".join(owners)}'))
        else:
            counts[owners[0]] += 1
            file_owners[path] = owners[0]
    for owner, pattern, _, _ in patterns:
        if (owner, pattern) not in matched:
            problems.append((pattern, f'stale path ({owner})'))
    return problems, counts, file_owners


def module_violations(root, manifest, file_owners):
    walker = Path(__file__).parent / 'components/module_references.exs'
    files = sorted(path for path in file_owners if path.startswith('src/lib/') and path.endswith('.ex'))
    started = time.monotonic()
    try:
        result = subprocess.run(['elixir', str(walker), str(root), '--files', *files], capture_output=True, text=True)
    except FileNotFoundError as error:
        raise ValueError('Elixir missing; install via mise') from error
    if result.returncode:
        raise ValueError(f'module walker failed: {result.stderr.strip()}')
    modules, references = {}, []
    for row in result.stdout.splitlines():
        fields = row.split('\t')
        if len(fields) == 3 and fields[0] == 'M':
            _, path, module = fields
            if path in file_owners:
                modules[module] = file_owners[path]
        elif len(fields) == 6 and fields[0] == 'R':
            references.append(fields)
        else:
            raise ValueError(f'invalid walker row: {row!r}')
    components = {c['id']: c for c in manifest['components']}
    violations, unresolved = {}, set()
    for _, path, source_module, target, _, line in references:
        # Match ownership's tracked-file boundary, including in dirty worktrees.
        if path not in file_owners or path == 'src/lib/aiur.ex':
            continue
        if target not in modules:
            if target.startswith(('Aiur.', 'AiurWeb.')):
                unresolved.add(target)
            continue
        source, destination = file_owners[path], modules[target]
        if source == destination:
            continue
        component, provider = components[source], components[destination]
        rules = []
        if destination not in component['requires'] + component['optional']:
            rules.append('R-declared')
        if provider['facades'] != ['*'] and target not in provider['facades']:
            rules.append('R-private')
        for rule in rules:
            violations.setdefault((rule, source, target), f'{path}:{line} ({source_module})')
    print(f'components: Elixir: {len(modules)} modules, {len(references)} references; '
          f'{len(unresolved)} unresolved internal targets; {time.monotonic() - started:.3f} s')
    return violations


def read_allowlist(root, manifest):
    allowed = set()
    ids = {c['id'] for c in manifest['components']}
    for path in sorted((root / 'scripts/components/allowlist').glob('*.tsv')):
        if path.stem not in ids:
            raise ValueError(f'{path}: unknown source component')
        for number, row in enumerate(path.read_text().splitlines(), 1):
            if not row.strip() or row.startswith('#'):
                continue
            fields = row.split('\t')
            if len(fields) != 3 or fields[0] not in ('R-declared', 'R-private') or not all(fields):
                raise ValueError(f'{path}:{number}: expected rule, target_module, reason TSV')
            allowed.add((fields[0], path.stem, fields[1]))
    return allowed


def write_baseline(root, manifest, violations):
    directory = root / 'scripts/components/allowlist'
    if any(directory.glob('*.tsv')):
        raise ValueError('baseline already exists; refusing to overwrite allowlist')
    sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    directory.mkdir(parents=True, exist_ok=True)
    for component in manifest['components']:
        source = component['id']
        rows = ['# rule\ttarget_module\treason']
        rows.extend(f'{rule}\t{target}\tbaseline {sha}'
                    for rule, owner, target in sorted(violations) if owner == source)
        with (directory / f'{source}.tsv').open('x') as stream:
            stream.write('\n'.join(rows) + '\n')


def check_references(root, manifest, file_owners, baseline):
    violations = module_violations(root, manifest, file_owners)
    if baseline:
        write_baseline(root, manifest, violations)
    allowed = read_allowlist(root, manifest)
    for (rule, source, target), location in sorted(violations.items()):
        if (rule, source, target) not in allowed:
            print(f'components: {rule} {source} -> {target}: {location}')
    for rule in ('R-declared', 'R-private'):
        print(f'components: {rule}: {sum(key[0] == rule for key in violations)} baseline keys')
    return bool(violations.keys() - allowed)


def declaration_ownership(root, manifest):
    # Keep these literal matchers aligned with check-config-docs.py.
    config = (root / 'src/lib/aiur/config/schema.ex').read_text()
    sections = re.findall(r"^\s*embeds_(?:one|many)\(\s*:([a-zA-Z0-9_]+)\s*,\s*[A-Za-z0-9_.]+", config, re.MULTILINE)
    fields = re.findall(r"^\s*field\(\s*:([a-zA-Z0-9_]+)", config, re.MULTILINE)
    env = re.findall(r'^\s*\{"([A-Z][A-Z0-9_]+)",',
                     (root / 'src/lib/aiur/env/schema.ex').read_text(), re.MULTILINE)
    state = re.findall(r'^\s*def\s+([a-z][a-z0-9_]*(?:_dir|_path))\b',
                       (root / 'src/lib/aiur/config/paths.ex').read_text(), re.MULTILINE)
    inventories = {'config': sections + fields, 'env': env, 'state': state}
    for kind, names in inventories.items():
        if not names or (kind == 'config' and not sections):
            raise InvalidManifest(f'O-{kind}: matcher is broken, not the schema (zero matches)')
    problems = []
    for kind, names in inventories.items():
        owners = {}
        for component in manifest['components']:
            for name in component['owns'][kind]:
                owners.setdefault(name, []).append(component['id'])
        noun = {'config': 'section/field', 'env': 'env var', 'state': 'state path'}[kind]
        for name in sorted(set(names) | owners.keys()):
            assigned = owners.get(name, [])
            if name not in names:
                problems.append((f'O-{kind}', f"{noun} '{name}' is stale ({', '.join(assigned)})"))
            elif not assigned:
                problems.append((f'O-{kind}', f"{noun} '{name}' has no owner"))
            elif len(assigned) > 1:
                problems.append((f'O-{kind}', f"{noun} '{name}' owned twice: {', '.join(assigned)}"))
    return problems, {'sections': len(sections), 'fields': len(fields),
                      'env vars': len(env), 'state paths': len(state)}


def format_manifest(manifest):
    """One component block with inline arrays, keeping the manifest reviewable."""
    ordered = dict(manifest)
    ordered['components'] = sorted(manifest['components'], key=lambda c: (c['layer'], c['id']))
    lines = ['{']
    for key, value in ordered.items():
        if key != 'components':
            lines.append(f'  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)},')
            continue
        lines.append('  "components": [')
        for component in value:
            lines.append('    {')
            groups = [('id', 'name', 'layer', 'kind'), ('paths',),
                      ('facades', 'facade_pending'), ('requires', 'optional'),
                      ('owns',), ('prior',)]
            used = {field for group in groups for field in group}
            groups.extend((field,) for field in component if field not in used)
            for group in groups:
                entries = [f'{json.dumps(field)}: {json.dumps(component[field], ensure_ascii=False)}'
                           for field in group if field in component]
                lines.append('      ' + ', '.join(entries) + ',')
            lines[-1] = lines[-1].removesuffix(',')
            lines.append('    },')
        lines[-1] = lines[-1].removesuffix(',')
        lines.append('  ],')
    lines[-1] = lines[-1].removesuffix(',')
    return '\n'.join(lines + ['}', ''])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rules', choices=['ownership', 'elixir', 'all'], default='all')
    parser.add_argument('--require-elixir', action='store_true', help='require Elixir reference checks')
    parser.add_argument('--write-baseline', action='store_true')
    parser.add_argument('--format', action='store_true')
    args = parser.parse_args()
    if args.rules == 'ownership' and (args.require_elixir or args.write_baseline):
        parser.error('--require-elixir/--write-baseline cannot be used with ownership alone')
    root = Path(os.environ.get('AIUR_COMPONENTS_ROOT', Path(__file__).resolve().parent.parent)).resolve()
    try:
        manifest = load_manifest(root)
        files = source_files(root)
        if args.format:
            (root / 'components.json').write_text(format_manifest(manifest))
        problems, counts, file_owners = ownership(manifest, files)
        declaration_counts = {}
        if args.rules != 'elixir':
            declaration_problems, declaration_counts = declaration_ownership(root, manifest)
            problems.extend(declaration_problems)
        for path, reason in problems:
            print(f'components: {path}: {reason}')
        if problems:
            return 1
        if args.rules != 'ownership' and check_references(root, manifest, file_owners, args.write_baseline):
            return 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'components: components.json: {error}', file=sys.stderr)
        return 2
    print(f'components: all {sum(counts.values())} source files owned')
    if declaration_counts:
        print('components: ' + ', '.join(f'{count} {kind}' for kind, count in declaration_counts.items()) + ' owned once')
    for owner, count in counts.items():
        print(f'components: {owner}: {count} files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
