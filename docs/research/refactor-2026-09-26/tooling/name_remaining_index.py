#!/usr/bin/env python3
"""Index frozen definition spans for the unreviewed cross-module name queue.

This is a structural index. It deliberately does not assign semantic verdicts.
"""

import collections
import hashlib
import json
import sys
from pathlib import Path


def main(research: Path, snapshot: Path) -> dict:
    progress = research / "review/in-progress"
    queue = json.loads((progress / "duplication-name-remaining.json").read_text())
    census = json.loads((snapshot.parent / "function-census.json").read_text())
    sources = {item["path"]: item["sha256"] for item in census["files"]}
    for path, expected in sources.items():
        actual = hashlib.sha256((snapshot / path).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"source changed: {path}")

    names = {item["name"] for item in queue["families"]}
    grouped = collections.defaultdict(list)
    for definition in census["definitions"]:
        if definition["name"] in names:
            grouped[definition["name"]].append(definition)

    families = []
    for item in queue["families"]:
        name = item["name"]
        sites = grouped[name]
        modules = {site["module"] for site in sites}
        if len(sites) != item["clauses"] or len(modules) != item["modules"]:
            raise ValueError(f"queue/census mismatch: {name}")
        body_groups = collections.defaultdict(list)
        for site in sites:
            if site["has_body"]:
                body_groups[site["body_sha256"]].append(site)
        cross_module_body_groups = [
            body_hash for body_hash, entries in body_groups.items()
            if len({entry["module"] for entry in entries}) > 1
        ]
        families.append({
            "name": name,
            "clauses": len(sites),
            "modules": len(modules),
            "cross_module_exact_body_hashes": sorted(cross_module_body_groups),
            "structural_disposition": (
                "exact_body_match_requires_context_review"
                if cross_module_body_groups else "same_name_no_exact_body_match"
            ),
            "sites": sites,
        })
    return {
        "status": "structural-index-only",
        "snapshot": queue["snapshot"],
        "families": families,
        "counts": {
            "families": len(families),
            "literal_clauses": sum(len(item["sites"]) for item in families),
            "families_with_cross_module_exact_body": sum(
                bool(item["cross_module_exact_body_hashes"]) for item in families
            ),
        },
        "limits": "Every queued literal span is indexed and source hashes checked. Same name with different normalized bodies may still implement the same concept. Same body may have different heads, attributes or callees. This artifact is not a semantic assessment, reviewed-family count or extraction recommendation.",
    }


if __name__ == "__main__":
    print(json.dumps(main(Path(sys.argv[1]), Path(sys.argv[2])), indent=2))
