#!/usr/bin/env python3
"""Keep conflict-prone lists one item per line without changing their meaning."""
import argparse
import json
from pathlib import Path
import re
import sys
from components.manifest import format_json, read_manifest

CODE_LISTS = {
    'src/lib/aiur/run_telemetry/lifecycle.ex': ('events', 'boundaries', 'metadata_fields'),
    'src/test/aiur/application/children_test.exs': ('terminal_only', 'dashboard', 'always'),
    'src/test/aiur/application_child_order_test.exs': ('existing_children', 'flags'),
    'src/lib/aiur/run_telemetry/run_context.ex': ('volatile',),
    'src/lib/aiur/run_telemetry/dataset.ex': ('carried_point_events',),
    'src/lib/aiur/run_telemetry/writer/encoding.ex': ('carried_point_events',),
    'src/lib/aiur/run_telemetry/sampler/process_tree.ex': ('metric_fields',),
    'src/lib/aiur/run_telemetry/dataset/source.ex': ('supported_kinds',),
    'src/lib/aiur/run_telemetry/procfs.ex': ('vanished_reasons',),
    'src/lib/aiur/run_telemetry/sampler.ex': ('fleet_fields', 'fleet_admission_fields'),
}


def check(root):
    errors = []
    try:
        read_manifest(root)
        index = root / 'components.json'
        manifest = json.loads(index.read_text())
        paths = [index, *(root / name for name in manifest.get('component_files', []))]
        for path in paths:
            if path.read_text() != format_json(json.loads(path.read_text())):
                errors.append(f'{path.relative_to(root)}: run the hot-list formatter')
        for path in sorted((root / 'scripts/components/allowlist').glob('*.tsv')):
            rows = [row for row in path.read_text().splitlines() if row and not row.startswith('#')]
            if rows != sorted(set(rows)):
                errors.append(f'{path.relative_to(root)}: entries must be sorted and unique')
        for name, attributes in CODE_LISTS.items():
            text = (root / name).read_text()
            for attribute in attributes:
                match = re.search(r'@' + attribute + r'\s+(?:~w\((.*?)\)a?|\[(.*?)\])', text, re.S)
                if not match:
                    errors.append(f'{name}: missing @{attribute}')
                    continue
                body = next(group for group in match.groups() if group is not None)
                items = body.split() if match.group(1) is not None else [item.strip() for item in body.split(',') if item.strip()]
                lines = [line.strip().rstrip(',') for line in body.splitlines() if line.strip()]
                if lines != items:
                    errors.append(f'{name}: @{attribute} needs one item per line')
        path = root / 'src/test/support/state_writers_allowlist.exs'
        text = path.read_text()
        entries = re.findall(r'^  \{([^,]+),\s*(:[^,]+),', text, re.M)
        total = len(re.findall(r'\{\s*[A-Z][\w.]*\s*,', text))
        if len(entries) != total or entries != sorted(set(entries)):
            errors.append(f'{path.relative_to(root)}: writers need one tuple per line, with sorted unique keys')
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors.append(str(error))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = check(args.root)
    for error in errors:
        print(f'hot-list format: {error}', file=sys.stderr)
    if not errors:
        print('hot-list format: canonical JSON, sorted exemptions, and vertical code lists')
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
