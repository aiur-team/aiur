#!/usr/bin/env python3
"""Restore lost lens labels by exact equality with a local workflow journal.

Only metadata is copied from the journal; existing public verdict prose is
preserved. Fails before writing unless every verdict has one unique match.
Run before editing verdict prose. The journal remains machine-local.
"""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("verdicts", type=Path)
    parser.add_argument("journal", type=Path)
    args = parser.parse_args()
    journal_bytes = args.journal.read_bytes()
    records = [json.loads(line) for line in journal_bytes.splitlines() if line]
    starts = {r["key"]: r for r in records if r["type"] == "started"}
    results = [r for r in records if r["type"] == "result"]
    verdicts = json.loads(args.verdicts.read_text())
    annotated = []
    for verdict in verdicts:
        original = {k: v for k, v in verdict.items() if k not in ("lens", "provenance")}
        matches = [r for r in results if r["result"] == original
                   and starts[r["key"]]["label"].startswith("verify:")]
        if len(matches) != 1:
            raise SystemExit(f"{verdict['id']}: expected 1 exact match, got {len(matches)}")
        result = matches[0]
        label = starts[result["key"]]["label"]
        prefix, claim_id, lens = label.split(":")
        if prefix != "verify" or claim_id != verdict["id"] or lens not in ("reproduce", "interpret"):
            raise SystemExit(f"invalid label for {verdict['id']}")
        annotated.append({**original, "lens": lens, "provenance": {
            "workflow": args.journal.parent.name,
            "journal_sha256": hashlib.sha256(journal_bytes).hexdigest(),
            "result_key": result["key"],
            "label": label,
            "match": "exact JSON object equality before annotation",
        }})
    pairs = [(v["id"], v["lens"]) for v in annotated]
    if len(set(pairs)) != len(pairs):
        raise SystemExit("duplicate claim/lens pair")
    args.verdicts.write_text(json.dumps(annotated, indent=1) + "\n")
    print(f"Restored {len(annotated)} unique claim/lens pairs; all exact journal matches.")


if __name__ == "__main__":
    main()
