"""Validate ownership of declared config, environment, and persisted state."""
import re

from components.config_ownership import nested_config_keys


def declaration_ownership(root, manifest, invalid_manifest):
    # Keep these literal matchers aligned with check-config-docs.py.
    config = (root / 'src/lib/aiur/config/schema.ex').read_text()
    sections = re.findall(r"^\s*embeds_(?:one|many)\(\s*:([a-zA-Z0-9_]+)\s*,\s*[A-Za-z0-9_.]+", config, re.MULTILINE)
    fields = re.findall(r"^\s*field\(\s*:([a-zA-Z0-9_]+)", config, re.MULTILINE)
    env = re.findall(r'^\s*\{"([A-Z][A-Z0-9_]+)",',
                     (root / 'src/lib/aiur/env/schema.ex').read_text(), re.MULTILINE)
    state_sources = [root / path for path in ('src/lib/aiur/config/paths.ex', 'src/lib/aiur/repo_base.ex')]
    state = [name for path in state_sources if path.exists()
             for name in re.findall(r'^\s*def\s+([a-z][a-z0-9_]*(?:_dir|_path))\b', path.read_text(), re.MULTILINE)]
    nested = {key for c in manifest['components'] for key in c['owns']['config'] if '.' in key}
    known_nested = nested_config_keys(root) if nested else set()
    inventories = {'config': sections + fields + sorted(nested & known_nested), 'env': env, 'state': state}
    for kind, names in inventories.items():
        if not names or (kind == 'config' and not sections):
            raise invalid_manifest(f'O-{kind}: matcher is broken, not the schema (zero matches)')

    problems = []
    for kind, names in inventories.items():
        if kind == 'state':
            state_files = {}
            for component in manifest['components']:
                for entry in component['owns']['state']:
                    if entry.startswith('file: '):
                        pattern = entry[6:]
                        accessor = pattern[1:pattern.index('>')]
                        if accessor not in names:
                            problems.append(('O-state', f"state file pattern '{pattern}' has stale directory accessor ({component['id']})"))
                        state_files.setdefault(pattern, []).append(component['id'])
            for pattern, owners in state_files.items():
                if len(owners) > 1:
                    problems.append(('O-state', f"state file pattern '{pattern}' owned twice: {', '.join(owners)}"))
        owners = {}
        for component in manifest['components']:
            entries = component['owns'][kind]
            if kind == 'state':
                entries = [entry for entry in entries if not entry.startswith('file: ')]
            for name in entries:
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
