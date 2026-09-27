#!/usr/bin/env python3
"""Index source-span overlaps, never infer semantic duplication or validity."""
import collections
import json
import re
import sys
from pathlib import Path

LINE_EXPR = re.compile(r'\s*\d+(?:\s*[-–]\s*\d+)?(?:\s*,\s*\d+(?:\s*[-–]\s*\d+)?)*\s*')

def ranges(value):
    if not LINE_EXPR.fullmatch(value):
        return None
    result = []
    for part in value.split(','):
        ends = re.split(r'[-–]', part.strip())
        low, high = int(ends[0]), int(ends[-1])
        if low > high:
            raise ValueError(value)
        result.append((low, high))
    return result

def build(root):
    by_path = collections.defaultdict(list)
    unresolved = []
    findings = {}
    for path in sorted((root / 'review/raw').glob('*.json')):
        for finding in json.loads(path.read_text()).get('findings', []):
            fid = finding['id']
            if fid in findings:
                raise ValueError('duplicate finding ID: ' + fid)
            findings[fid] = dict(source=str(path.relative_to(root)), category=finding['category'], severity=finding['severity'])
            for location in finding['locations']:
                spans = ranges(location['lines'])
                if spans is None:
                    unresolved.append(dict(finding_id=fid, location=location))
                else:
                    by_path[location['path']].append((fid, spans))
    result = []
    for mode, filename, key in [('exact', 'function-census-summary.json', 'body_sha256'),
                                ('renamed', 'renamed-census-summary.json', 'renamed_body_sha256')]:
        data = json.loads((root / 'review/in-progress' / filename).read_text())
        for group in data.get('body_candidates', data.get('candidates', [])):
            hits = collections.defaultdict(list)
            for site in group['sites']:
                for fid, spans in by_path[site['path']]:
                    if any(site['line'] <= high and site['end_line'] >= low for low, high in spans):
                        value = dict(path=site['path'], line=site['line'], end_line=site['end_line'])
                        if value not in hits[fid]:
                            hits[fid].append(value)
            result.append(dict(mode=mode, candidate_hash=group[key],
                               overlaps=[dict(finding_id=fid, **findings[fid], sites=hits[fid]) for fid in sorted(hits)]))
    return dict(status='index-only', raw_findings=len(findings), candidate_groups=len(result),
                groups_with_overlap=sum(bool(g['overlaps']) for g in result),
                groups=result, unresolved_locations=unresolved,
                limits='Closed line-range intersection is navigation evidence only. A broad finding range can overlap unrelated code; no overlap can mean an omitted location. Exact and renamed candidates overlap each other. Original finding IDs remain authoritative; this index neither deduplicates findings nor verifies their severity, behavioral claim, counts or recommendation. Nonstandard line expressions remain explicit for manual reconciliation.')

if __name__ == '__main__':
    print(json.dumps(build(Path(sys.argv[1])), indent=2))
