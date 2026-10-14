"""Read inline or split ownership manifests; keep unordered lists canonical."""
import json
import re
from pathlib import PurePosixPath


def read_manifest(root):
    manifest = json.loads((root / 'components.json').read_text())
    if not isinstance(manifest, dict):
        raise ValueError('manifest must be an object')
    if 'component_files' not in manifest:
        return manifest
    if 'components' in manifest:
        raise ValueError('use components or component_files, never both')
    files = manifest.pop('component_files')
    if not isinstance(files, list) or not files or any(not isinstance(p, str) for p in files):
        raise ValueError('component_files must be a nonempty string list')
    if len(files) != len(set(files)):
        raise ValueError('duplicate component file')
    components = []
    for name in files:
        path = PurePosixPath(name)
        if path.as_posix() != name or len(path.parts) != 2 or path.parts[0] != 'components' or path.suffix != '.json' or path.stem in ('', '.', '..') or '\\' in name:
            raise ValueError(f'unsafe component file: {name}')
        file = root / name
        if file.is_symlink() or (root / 'components').is_symlink():
            raise ValueError(f'symlinked component file: {name}')
        component = json.loads(file.read_text())
        if not isinstance(component, dict) or component.get('id') != path.stem:
            raise ValueError(f'component id must match filename: {name}')
        components.append(component)
    manifest['components'] = components
    return manifest


def canonical(value):
    if isinstance(value, dict):
        return {key: canonical(child) for key, child in value.items()}
    if isinstance(value, list):
        return sorted(value) if all(isinstance(child, str) for child in value) else [canonical(child) for child in value]
    return value


def format_json(value):
    value = canonical(value)
    text = json.dumps(value, ensure_ascii=False, indent=2)
    if isinstance(value, dict) and 'features' in value:
        expanded = json.dumps(value['features'], ensure_ascii=False, indent=2).replace('\n', '\n  ')
        compact = '[\n' + ',\n'.join('    ' + json.dumps(f, ensure_ascii=False) for f in value['features']) + '\n  ]'
        text = text.replace('  "features": ' + expanded, '  "features": ' + compact)
    return text + '\n'


def write_manifest(root, manifest):
    original = json.loads((root / 'components.json').read_text())
    if 'component_files' in original:
        for component in manifest['components']:
            if not isinstance(component.get('id'), str) or not re.fullmatch(r'[a-z][a-z0-9-]*', component['id']):
                raise ValueError('unsafe component id')
            target = root / 'components' / f'{component["id"]}.json'
            if target.is_symlink() or (root / 'components').is_symlink():
                raise ValueError('symlinked component output')
        for component in manifest['components']:
            (root / 'components' / f'{component["id"]}.json').write_text(format_json(component))
        original = {key: value for key, value in manifest.items() if key != 'components'}
        original['component_files'] = [f'components/{c["id"]}.json' for c in manifest['components']]
    else:
        original = dict(manifest, components=sorted(manifest['components'], key=lambda c: (c['layer'], c['id'])))
    (root / 'components.json').write_text(format_json(original))
