#!/usr/bin/env python3
"""Group syntactic candidates; semantic review remains explicit work."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument("census", type=Path)
a = p.parse_args()
d = json.loads(a.census.read_text())
numeric, expressions = defaultdict(list), defaultdict(list)
for row in d["attributes"]:
    if row["numeric_value"] is not None:
        numeric[row["numeric_value"]].append(row)
    else:
        expressions[row["expression_sha256"]].append(row)
def groups(items, key):
    result = []
    for value, sites in items.items():
        modules = len({x["module"] for x in sites})
        if modules > 1:
            result.append({key: value, "modules": modules, "site_count": len(sites), "sites": sites})
    return sorted(result, key=lambda x: (-x["modules"], -x["site_count"], str(x[key])))
print(json.dumps({
    "status": "in-progress",
    "source_files": len(d["files"]),
    "attribute_assignments": len(d["attributes"]),
    "numeric_assignments": sum(len(v) for v in numeric.values()),
    "numeric_cross_module_groups": groups(numeric, "numeric_value"),
    "symbolic_cross_module_groups": groups(expressions, "expression_sha256"),
    "inputs": d["files"],
    "limits": d["limits"] + " Equal numbers can have different units/owners. Equal expressions can resolve aliases or attributes differently. Candidate groups are not findings or savings. Numeric and symbolic assignments are disjoint; not all inline constants are captured."
}, indent=2))
