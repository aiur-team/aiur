#!/usr/bin/env python3
"""Check the three independently written P2/P3 triage partitions against findings."""

import collections
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REVIEW = ROOT / "review"


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def entries(part, data):
    if part == 1:
        return data["items"]
    if part == 2:
        return data
    return data["entries"]


def field(part, row, name):
    keys = {
        "id": ("finding_id", "id", "id"),
        "severity": ("reviewed_severity", "reviewed_severity", "severity"),
        "verdict": ("verdict", "assessment", "verdict"),
        "disposition": ("proposed_action", "proposed_disposition", "disposition"),
    }
    return row[keys[name][part - 1]]


def main():
    findings = read(REVIEW / "findings.json")["findings"]
    expected = sorted(
        (f for f in findings if f["reviewed_severity"] in {"P2", "P3"}),
        key=lambda f: f["id"],
    )
    assert len(expected) == 889, len(expected)
    observed = []
    counts = collections.Counter()

    for part, start, stop in ((1, 0, 297), (2, 297, 594), (3, 594, 889)):
        path = REVIEW / f"p2p3-triage-part-{part}.json"
        data = read(path)
        rows = entries(part, data)
        assert len(rows) == stop - start, (path, len(rows))
        for index, row in enumerate(rows, start=start):
            fid = field(part, row, "id")
            original = expected[index]
            assert row["index"] == index, (path, index, row["index"])
            assert fid == original["id"], (path, index, fid, original["id"])
            assert field(part, row, "severity") == original["reviewed_severity"]
            if "source_ids" in row:
                assert row["source_ids"] == original["source_ids"], (path, fid)
            verdict = field(part, row, "verdict")
            disposition = field(part, row, "disposition")
            assert verdict in {"source-supported", "unknown", "unsupported"}, (path, fid, verdict)
            assert disposition in {"fix", "defer"}, (path, fid, disposition)
            assert row.get("current_head_caveat"), (path, fid)
            counts[(part, verdict, disposition)] += 1
            observed.append(fid)

    assert len(observed) == len(set(observed)) == len(expected)
    for part in (1, 2, 3):
        verdicts = collections.Counter()
        dispositions = collections.Counter()
        for (p, verdict, disposition), count in counts.items():
            if p == part:
                verdicts[verdict] += count
                dispositions[disposition] += count
        print(f"part {part}: {sum(verdicts.values())} findings; {verdicts}; {dispositions}")
    print(f"exact canonical coverage: {len(observed)}/{len(expected)}")


if __name__ == "__main__":
    main()
