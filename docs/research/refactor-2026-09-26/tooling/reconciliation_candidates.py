#!/usr/bin/env python3
"""Index strong lexical/shared-path candidate pairs; never infer equivalence."""
from collections import Counter
import itertools
import json
import math
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
raw = {f["id"]: f for path in (root / "review/raw").glob("*.json")
       for f in json.loads(path.read_text())["findings"]}
owner = json.loads((root / "review/findings.json").read_text())["source_id_to_finding"]
stop = set("the and of in for from with to by a an is are has have across two three four five six same different multiple duplicate duplicated repeats repeated copy copied at on into or one module modules code file files aiur".split())


def words(value):
    return [x for x in re.findall(r"[a-z][a-z0-9_]+", value.lower()) if x not in stop and len(x) > 2]


terms = {key: Counter(words(f["title"] + " " + f["description"][:500])) for key, f in raw.items()}
frequency = Counter(term for row in terms.values() for term in row)
size = len(raw)
vectors = {key: {term: (1 + math.log(count)) * math.log((size + 1) / (frequency[term] + 1))
                 for term, count in row.items()} for key, row in terms.items()}
norms = {key: math.sqrt(sum(value * value for value in vector.values())) or 1
         for key, vector in vectors.items()}
paths = {key: {site["path"] for site in finding["locations"]} for key, finding in raw.items()}
groups = []
for left, right in itertools.combinations(sorted(raw), 2):
    common = paths[left] & paths[right]
    if not common:
        continue
    a, b = vectors[left], vectors[right]
    score = sum(value * b.get(term, 0) for term, value in a.items()) / (norms[left] * norms[right])
    if score >= 0.35:
        groups.append({"left": left, "right": right, "score": round(score, 4),
                       "shared_paths": sorted(common), "same_work_item": owner[left] == owner[right]})
groups.sort(key=lambda g: (-g["score"], g["left"], g["right"]))
print(json.dumps({"status": "navigation_only", "threshold": 0.35,
                  "method": "TF-IDF cosine over title plus first 500 description characters, requiring a shared cited path. Broad location ranges and terminology cause false matches; low score does not prove distinctness.",
                  "candidate_pairs": len(groups), "merged_pairs": sum(g["same_work_item"] for g in groups),
                  "unmerged_pairs": sum(not g["same_work_item"] for g in groups),
                  "pairs": groups}, separators=(",", ":")))
