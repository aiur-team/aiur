#!/usr/bin/env python3
"""List renamed-body candidate groups containing more than one exact body."""
import collections
import json
import sys
from pathlib import Path

def summarize(data):
    groups = collections.defaultdict(list)
    for row in data['definitions']:
        if row['has_body'] and row['end_line'] - row['line'] + 1 >= 5 and row['normalized_body_lines'] >= 5:
            groups[row['renamed_body_sha256']].append(row)
    candidates = [dict(renamed_body_sha256=h, sites=rows) for h, rows in groups.items()
                  if len({r['module'] for r in rows}) > 1 and len({r['body_sha256'] for r in rows}) > 1]
    candidates.sort(key=lambda g: (-len(g['sites']), g['renamed_body_sha256']))
    return dict(scope='Frozen 3339b887 src/lib/**/*.ex; same size thresholds as exact census',
                parsed_files=len(data['files']), definition_clauses=len(data['definitions']),
                candidate_clusters=len(candidates), candidate_sites=sum(len(g['sites']) for g in candidates),
                candidates=candidates,
                limits='Variable names canonicalized by first appearance in body AST, without lexical scope or binding analysis. Heads/guards excluded. Repeated variable spelling preserved; aliases, explicit call names, module-attribute expressions, literals and special compiler variables retained. Unexpanded bare identifiers may be variables or zero-argument calls; that ambiguity requires source review. Groups must cross modules and contain differing exact body hashes. Candidates are not semantic equivalence, exhaustive near-duplicates, or removable LOC. Exact-body and renamed-body populations overlap; do not add their site counts.')

if __name__ == '__main__':
    print(json.dumps(summarize(json.loads(Path(sys.argv[1]).read_text())), indent=2))
