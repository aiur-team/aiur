#!/usr/bin/env python3
"""Summarize parse-only definition census; matching bodies are candidates only."""
import collections
import json
import sys
from pathlib import Path


def summarize(data):
    names = collections.defaultdict(list)
    bodies = collections.defaultdict(list)
    for row in data['definitions']:
        names[row['name']].append(row)
        # Both physical definition span and canonical body must be nontrivial.
        # The physical span includes the head/end and may include blank lines.
        if row['has_body'] and row['end_line'] - row['line'] + 1 >= 5 and row['normalized_body_lines'] >= 5:
            bodies[row['body_sha256']].append(row)
    groups = []
    for digest, rows in bodies.items():
        if len({x['module'] for x in rows}) < 2:
            continue
        groups.append({'body_sha256': digest, 'sites': rows,
                       'candidate_source_lines': sum(x['end_line'] - x['line'] + 1 for x in rows)})
    groups.sort(key=lambda x: (-x['candidate_source_lines'], x['body_sha256']))
    name_counts = [{'name': name, 'modules': len({x['module'] for x in rows}), 'clauses': len(rows)}
                   for name, rows in names.items()]
    name_counts.sort(key=lambda x: (-x['modules'], x['name']))
    return {'scope': 'src/lib/**/*.ex at frozen snapshot 3339b887196d5e9aefb273117a14bf33391ee41f',
            'parsed_files': len(data['files']), 'definition_clauses': len(data['definitions']),
            'distinct_names': len(name_counts), 'name_counts': [x for x in name_counts if x['modules'] > 1],
            'body_candidate_clusters': len(groups),
            'body_candidate_sites': sum(len(x['sites']) for x in groups),
            'body_candidates': groups, 'source_sha256': data['files'],
            'limits': data['limits'] + ' Summary name_counts lists only names present in multiple modules. Summary retains bodies with physical definition span >=5 lines and canonical body >=5 lines. Source spans include heads/end/blank lines, not removable LOC. Body hashes exclude heads and guards; read surrounding clauses, aliases, imports and module attributes before deduplicating. Near-duplicates with renamed variables are not included in this exact-body pass.'}


if __name__ == '__main__':
    print(json.dumps(summarize(json.loads(Path(sys.argv[1]).read_text())), indent=2))
