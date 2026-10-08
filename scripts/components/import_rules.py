"""Client import and daemon resource boundaries."""
import json
from pathlib import Path
import re
import subprocess


def client_imports(root):
    walker = Path(__file__).with_name('ts-imports.mjs')
    result = subprocess.run(['node', str(walker), str(root)], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip())
    manifests = {}
    problems = []
    for row in result.stdout.splitlines():
        source, specifier, resolved = row.split('\t')
        package = root.joinpath(*Path(source).parts[:2])
        if package not in manifests:
            manifest = json.loads((package / 'package.json').read_text())
            manifests[package] = {name for key in ('dependencies', 'devDependencies', 'peerDependencies')
                                  for name in manifest.get(key, {})}
        reason = client_reason(root, package, manifests[package], specifier, resolved)
        if reason:
            problems.append((source, f'R-client: {specifier}: {reason}'))
    return problems


def client_reason(root, package, dependencies, specifier, resolved):
    if specifier == '<computed>':
        return 'unanalyzable import()/require()'
    if resolved == '<builtin>':
        return None
    bare = not specifier.startswith(('.', '/'))
    name = '/'.join(specifier.split('/')[:2]) if specifier.startswith('@') else specifier.split('/')[0]
    if bare and name not in dependencies:
        return f'undeclared npm dependency {name}'
    if resolved == '<npm>':
        return None
    target = Path(resolved).resolve()
    if target.is_relative_to(package.resolve()):
        return None
    contracts = root / 'packages/aiur-contracts'
    if contracts.exists() and target.is_relative_to(contracts.resolve()):
        manifest = json.loads((contracts / 'package.json').read_text())
        if manifest.get('name') in dependencies:
            return None
        return 'aiur-contracts must be declared as a dependency'
    if target.is_relative_to(root / 'packages') or target.is_relative_to(root / 'src') or target.is_relative_to(root / 'packaging'):
        return f'resolves outside own package: {target.relative_to(root)}'
    if bare and ('node_modules' in target.parts or not target.is_relative_to(root)):
        return None
    return f'resolves outside own package: {target}'


def reverse_resources(root, files):
    problems = []
    allowed = ('src/lib/aiur_web/streamdeck_key_face_contract.ex',
               'packages/streamdeck/src/key-face-contract.json')
    for source in files:
        if not source.startswith('src/lib/') or not source.endswith('.ex'):
            continue
        text = (root / source).read_text()
        attributes = dict(re.findall(r'^\s*@(\w+)\s+(.+)$', text, re.MULTILINE))
        for expression in re.findall(r'^\s*@external_resource\s+(.+)$', text, re.MULTILINE):
            if re.fullmatch(r'@\w+', expression):
                expression = attributes.get(expression[1:], '')
            literal = re.search(r'"([^"\n]+)"', expression)
            if not literal:
                continue
            target = (root / source).parent.joinpath(literal[1]).resolve()
            if not target.is_relative_to(root / 'packages'):
                continue
            relative = target.relative_to(root).as_posix()
            if (source, relative) == allowed:
                print(f'components: {source}: R-reverse-resource: allowlisted {relative} (MP-R6 owns)')
            else:
                problems.append((source, f'R-reverse-resource: {relative}'))
    return problems
