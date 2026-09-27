#!/usr/bin/env python3
"""Index residual cross-module names; counts are coverage, not defect evidence."""
import argparse
import collections
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("research_root", type=Path)
root = parser.parse_args().research_root
census_path = root / "scratch/function-census.json"
triage_path = root / "review/in-progress/duplication-name-triage.json"
definitions = json.loads(census_path.read_text())["definitions"]
triage = json.loads(triage_path.read_text())
reviewed = {entry["name"] for entry in triage["reviewed_families"]}
groups = collections.defaultdict(list)
for definition in definitions:
    groups[definition["name"]].append(definition)
cross_module = {name: sites for name, sites in groups.items()
                if len({site["module"] for site in sites}) > 1}
remaining = {name: sites for name, sites in cross_module.items()
             if name not in reviewed}
families = [
    {"name": name, "clauses": len(sites),
     "modules": len({site["module"] for site in sites}),
     "summed_source_span_lines": sum(site["end_line"] - site["line"] + 1 for site in sites)}
    for name, sites in remaining.items()
]
families.sort(key=lambda item: (-item["modules"], item["name"]))
assert set(remaining).isdisjoint(reviewed)
assert set(remaining) | (reviewed & set(cross_module)) == set(cross_module)
output = {
    "snapshot": triage["snapshot"],
    "status": "in-progress",
    "method": "All literal definition names grouped across modules, excluding fully reviewed families; ordered by module count then name.",
    "input_sha256": {
        "function_census": hashlib.sha256(census_path.read_bytes()).hexdigest(),
        "name_triage": hashlib.sha256(triage_path.read_bytes()).hexdigest()
    },
    "counts": {
        "all_names": len(groups), "cross_module_names": len(cross_module),
        "single_module_names": len(groups) - len(cross_module),
        "reviewed_cross_module_names": len(reviewed & set(cross_module)),
        "remaining_cross_module_names": len(remaining),
        "remaining_literal_entries": sum(map(len, remaining.values()))
    },
    "families": families,
    "limits": "A reproducible queue, not semantic review or defect evidence. Single-module names can still duplicate concepts/bodies and are not certified here. Macro-generated definitions remain outside the literal census."
}
path = root / "review/in-progress/duplication-name-remaining.json"
path.write_text(json.dumps(output, indent=2) + "\n")
print(json.dumps(output["counts"], sort_keys=True))
