#!/usr/bin/env python3
"""Preserve shard failures and record those cleared by a same-run/SHA rerun."""

import argparse
import json
import os
from pathlib import Path
import re


def record(log, outcome, previous, output, summary):
    text = log.read_text() if log.exists() else ""
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    seeds = re.findall(r"(?:Running ExUnit with seed:|Randomized with seed)\s*(\d+)", text)
    current = {
        "run_id": os.environ["GITHUB_RUN_ID"],
        "sha": os.environ["GITHUB_SHA"],
        "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "shard": os.environ["MIX_TEST_PARTITION"],
        "seed": int(seeds[-1]) if seeds else None,
        "outcome": outcome,
        "completed_pass": outcome == "success" and bool(re.search(r"[1-9]\d* tests?, 0 failures", text)),
        "failures": sorted(set(re.findall(
            r"^\s*\d+\) test (.*) \(([A-Za-z0-9_.]+)\)\s*$", text, re.M
        ))),
    }
    rows = []
    # A green step without a completed ExUnit suite is not rerun-pass evidence.
    if current["completed_pass"]:
        attempts = [json.loads(path.read_text()) for path in sorted(previous.rglob("attempt.json"))]
        attempts = [prior for prior in attempts
                    if all(prior[key] == current[key] for key in ("run_id", "sha", "shard"))
                    and prior["attempt"] < current["attempt"]]
        for prior in attempts:
            already_cleared = any(item["completed_pass"] and item["attempt"] > prior["attempt"]
                                  for item in attempts)
            if prior["outcome"] == "failure" and not already_cleared:
                for name, module in prior["failures"]:
                    rows.append({
                        "test": f"{module} :: {name}",
                        **{key: prior[key] for key in ("run_id", "sha", "shard", "seed")},
                        "failed_attempt": prior["attempt"],
                        "passed_attempt": current["attempt"],
                        "passed_seed": current["seed"],
                    })
    output.mkdir(parents=True, exist_ok=True)
    (output / "attempt.json").write_text(json.dumps(current, indent=2) + "\n")
    (output / "flakes.ndjson").write_text("".join(json.dumps(row) + "\n" for row in rows))
    with summary.open("a") as handle:
        handle.write(f"\n### Coverage flake ledger (shard {current['shard']}/4)\n\n")
        handle.write(f"{len(rows)} failure → rerun-pass observations for this run and SHA. "
                     "See the shard-flake-evidence artifact for seeds and attempts.\n")
        for row in rows:
            handle.write(f"- {row['test']} (attempt {row['failed_attempt']} → {row['passed_attempt']})\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("outcome", choices=("success", "failure", "cancelled", "skipped"))
    parser.add_argument("previous", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("summary", type=Path)
    args = parser.parse_args()
    record(args.log, args.outcome, args.previous, args.output, args.summary)
