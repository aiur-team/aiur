#!/usr/bin/env python3
"""Independently audit lossless source-ID and severity coverage in findings.json."""
from collections import Counter
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = json.loads((root / "review/findings.json").read_text())
raw = {}
for path in (root / "review/raw").glob("*.json"):
    for claim in json.loads(path.read_text())["findings"]:
        assert claim["id"] not in raw, claim["id"]
        raw[claim["id"]] = claim
seen = []
canonical = set()
for item in out["findings"]:
    assert item["id"] not in canonical
    canonical.add(item["id"])
    assert item["id"] in item["source_ids"]
    assert [entry["claim"]["id"] for entry in item["source_claims"]] == item["source_ids"]
    assert item["primary_boundary"] in item["boundary_codes"]
    assert all(code in out["boundary_names"] for code in item["boundary_codes"])
    for entry in item["source_claims"]:
        claim = entry["claim"]
        assert claim == raw[claim["id"]], claim["id"]
        assert entry["source_file"].startswith("review/raw/")
        assert (root / entry["source_file"]).exists()
        seen.append(claim["id"])
assert len(seen) == len(set(seen)) == len(raw)
assert set(seen) == set(raw) == set(out["source_id_to_finding"])
assert set(out["source_id_to_finding"].values()) == canonical
assert all(out["source_id_to_finding"][key] == item["id"] for item in out["findings"] for key in item["source_ids"])
assert set(out["boundary_finding_ids"]).issubset(out["boundary_names"])
assert all(set(ids).issubset(canonical) for ids in out["boundary_finding_ids"].values())
assert all(set(item["related_finding_ids"]).issubset(canonical) for item in out["findings"])
assert Counter(item["reviewed_severity"] for item in out["findings"]) == out["counts"]["reviewed_severity"]
assert len(raw) == out["counts"]["raw_source_ids"]
assert len(canonical) == out["counts"]["canonical_findings"]
reviews = [entry["verification"] for item in out["findings"] for entry in item["source_claims"]]
assert Counter(v["status"] for v in reviews) == out["counts"]["source_verification"]
assert sum(v["status"] == "two_independent_static_reviews" for v in reviews) == sum(f["severity"] in ("P0", "P1") for f in raw.values())
print(json.dumps({"source_ids": len(raw), "canonical_findings": len(canonical),
                  "source_reviews": dict(Counter(v["status"] for v in reviews)),
                  "boundaries": len(out["boundary_finding_ids"])}))
