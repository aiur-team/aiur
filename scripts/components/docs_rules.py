"""Pure-file validation of the component directory's public references."""
import html
import importlib.util
import json
import re
import unicodedata
from pathlib import Path


def slugify(heading):
    """VitePress/@mdit-vue/shared heading normalization (including underscores)."""
    value = unicodedata.normalize('NFKD', heading)
    value = re.sub(r'[\u0300-\u036f]', '', value)
    value = re.sub(r'[\u0000-\u001f]', '', value)
    value = re.sub(r"[\s~`!@#$%^&*()\-_+=[\]{}|\\;:\"'“”‘’<>,.?/]+", '-', value)
    value = re.sub(r'-+', '-', value).strip('-')
    return re.sub(r'^(\d)', r'_\1', value).lower()


def headings(source):
    """Ignore fenced examples when inspecting Markdown ATX headings."""
    fence, comment = None, False
    for line in source.splitlines():
        if fence is None:
            if comment:
                comment = '-->' not in line
                continue
            if '<!--' in line:
                comment = '-->' not in line.partition('<!--')[2]
                continue
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if marker:
            token = marker[1]
            if fence is None:
                if token[0] != "`" or "`" not in marker[2]:
                    fence = token
            elif token[0] == fence[0] and len(token) >= len(fence) and not marker[2].strip():
                fence = None
            continue
        if fence is None:
            match = re.match(r'^ {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$', line)
            if match:
                yield len(match[1]), match[2]


def heading_anchors(source):
    anchors, counts = set(), {}
    for _, heading in headings(source):
        custom = re.search(r'\s*\{#([^}]+)\}\s*$', heading)
        if custom:
            anchor = custom[1]
        else:
            # Markdown inline emphasis and code markers are not visible title text.
            title = re.sub(r'`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*', lambda m: next(g for g in m.groups() if g is not None), re.sub(r'\[([^]]+)\]\([^)]*\)', r'\1', heading))
            anchor = slugify(html.unescape(title))
        count = counts.get(anchor, 0)
        counts[anchor] = count + 1
        anchors.add(f'{anchor}-{count}' if count else anchor)
    return anchors


def docs_paths(root, entries):
    problems = []
    docs = (root / 'website/docs-app').resolve()
    for entry in entries:
        paths = entry.get('docs', []) + ([entry['install']['docs']] if entry.get('install', {}).get('type') == 'setup' else [])
        for reference in paths:
            path, _, anchor = reference.partition('#')
            target = (docs / path).resolve()
            if not target.is_relative_to(docs) or not target.is_file():
                problems.append(f'{entry["id"]}: docs path not found: {reference}')
            elif anchor:
                anchors = heading_anchors(target.read_text())
                if anchor not in anchors:
                    problems.append(f'{entry["id"]}: docs anchor not found: {reference}')
    return problems


def config_sections(root, entries):
    if not any(e.get('config') for e in entries):
        return []
    reference = root / 'website/docs-app/reference'
    # These are the three owning references enforced by check-config-docs.py.
    sections = set()
    for name in ('configuration.md', 'configuration-agent.md', 'configuration-build-order.md'):
        path = reference / name
        if path.exists():
            sections.update(text for level, text in headings(path.read_text()) if level == 2)
    return [f'{e["id"]}: config section {s} has no heading in reference/configuration*.md'
            for e in entries for s in e.get('config', []) if s not in sections]


def env_names(root, entries):
    if not any(e.get('env') for e in entries):
        return []
    # Use the canonical schema parser, including declarations with example:false.
    path = Path(__file__).resolve().parent.parent / 'check-env-example.py'
    spec = importlib.util.spec_from_file_location('env_example', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    names = module.parse_schema_entries((root / 'src/lib/aiur/env/schema.ex').read_text())
    if not names:
        raise ValueError('env schema matcher found zero declarations')
    problems = []
    for entry in entries:
        for name in entry.get('env', []):
            known = any(n.startswith(name[:-1]) for n in names) if name.endswith('*') else name in names
            if not known:
                problems.append(f'{entry["id"]}: env var {name} unknown')
    return problems


def capability_ids(root, entries):
    if not any(e.get('capabilities') for e in entries):
        return []
    source = (root / 'packages/aiur-contracts/src/index.ts').read_text()
    match = re.search(r'export const KNOWN_CAPABILITY_IDS = (\[.*?\]) as const;', source, re.DOTALL)
    if not match:
        raise ValueError('aiur-contracts capability enum missing')
    ids = json.loads(match[1])
    return [f'{e["id"]}: capability {c} not in aiur-contracts'
            for e in entries for c in e.get('capabilities', [])
            if c not in ids and not re.fullmatch(r'harness\.[a-z0-9_]+\.native_question', c)]


def sidebar(root, manifest):
    if not manifest['directory_published']:
        return []
    source = (root / 'website/docs-app/.vitepress/config.ts').read_text()
    return [] if re.search(r"(['\"])/reference/components\1", source) else [
        'sidebar link /reference/components missing from .vitepress/config.ts']


def check_docs(root, manifest):
    # D1 and D7 reuse load_manifest's schema and component-reference validation.
    entries = manifest['components'] + manifest['features']
    return sorted(docs_paths(root, entries) + config_sections(root, entries)
                  + env_names(root, entries) + capability_ids(root, entries) + sidebar(root, manifest))
