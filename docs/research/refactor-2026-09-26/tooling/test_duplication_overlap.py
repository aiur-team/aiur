#!/usr/bin/env python3
"""Constrain closed span matching and explicit unresolved locations."""
import json
from pathlib import Path
import tempfile
from duplication_overlap import build, ranges

assert ranges('3-5, 9, 12–14') == [(3, 5), (9, 9), (12, 14)]
assert ranges('(whole file)') is None
with tempfile.TemporaryDirectory(prefix='aiur-overlap-') as temp:
    root = Path(temp)
    (root / 'review/raw').mkdir(parents=True)
    (root / 'review/in-progress').mkdir()
    findings = [dict(id='f1', category='duplication', severity='P2', locations=[
        dict(path='a.ex', lines='3-5,9'), dict(path='a.ex', lines='(whole file)')])]
    (root / 'review/raw/one.json').write_text(json.dumps(dict(findings=findings)))
    sites = [dict(path='a.ex', line=5, end_line=7), dict(path='a.ex', line=6, end_line=8), dict(path='b.ex', line=3, end_line=5)]
    (root / 'review/in-progress/function-census-summary.json').write_text(json.dumps(dict(body_candidates=[dict(body_sha256='fixture', sites=sites)])))
    (root / 'review/in-progress/renamed-census-summary.json').write_text(json.dumps(dict(candidates=[])))
    data = build(root)
    assert data['groups'][0]['overlaps'][0]['sites'] == [sites[0]]
    assert data['unresolved_locations'] == [dict(finding_id='f1', location=dict(path='a.ex', lines='(whole file)'))]
    assert data['raw_findings'] == data['groups_with_overlap'] == 1
    (root / 'review/raw/two.json').write_text(json.dumps(dict(findings=findings)))
    try:
        build(root)
    except ValueError as error:
        assert str(error) == 'duplicate finding ID: f1'
    else:
        raise AssertionError('duplicate IDs silently accepted')
print('Overlap fixtures passed: endpoints, disjoint ranges, path isolation, unresolved ranges and duplicate IDs.')
