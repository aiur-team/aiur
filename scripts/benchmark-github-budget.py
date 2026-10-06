#!/usr/bin/env python3
"""Compare one-shot and resident admissions with shared DB writers and bounded CPU load.

Run with --baseline pointing to github_budget.py from the pre-change commit.
All SQLite state is temporary; no live credential or ledger is used.
"""
import argparse
import concurrent.futures
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def call(process, broker, args, resident, request_id):
    if not resident:
        return subprocess.check_output([sys.executable, broker, *args], text=True).strip()
    process.stdin.write(json.dumps({"id": request_id, "args": args, "deadline_ms": int(time.time() * 1000) + 1500}) + "\n")
    process.stdin.flush()
    reply = json.loads(process.stdout.readline())
    if reply["id"] != request_id or reply["status"] != 0:
        raise RuntimeError(reply)
    return reply["output"].strip()


def writer(broker, db, resident, rounds, worker):
    process = subprocess.Popen([sys.executable, broker, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) if resident else None
    common = ["--db", db, "--token-key", "shared-benchmark-credential"]
    args = ["acquire", "--resource", "core", "--consumer-key", str(worker), "--endpoint-family", "rest",
            "--max-inflight", "100", "--max-inflight-per-endpoint", "100", "--requests-per-minute", "10000",
            "--stagger-ms", "0", "--lease-ttl-ms", "30000", *common]
    latencies = []
    try:
        for n in range(rounds + 2):
            start = time.perf_counter()
            result = call(process, broker, args, resident, n * 2)
            elapsed = (time.perf_counter() - start) * 1000
            if result.startswith("granted "):
                call(process, broker, ["release", "--lease-id", result.split()[1], *common], resident, n * 2 + 1)
            elif not result.startswith("wait "):
                raise RuntimeError(result)
            if n >= 2:
                latencies.append(elapsed)
    finally:
        if process:
            process.stdin.close()
            process.wait(timeout=10)
    return latencies


def measure(broker, resident, writers, rounds, root):
    db = str(Path(root) / ("resident" if resident else "oneshot") / "budget.sqlite3")
    # Initialize once so schema migration is not confused with steady admission.
    subprocess.check_output([sys.executable, broker, "usage", "--db", db])
    with concurrent.futures.ThreadPoolExecutor(max_workers=writers) as pool:
        futures = [pool.submit(writer, broker, db, resident, rounds, n) for n in range(writers)]
        samples = sorted(value for future in futures for value in future.result())
    return {"samples": len(samples), "p50_ms": round(samples[math.ceil(len(samples) * .50) - 1], 2),
            "p99_ms": round(samples[math.ceil(len(samples) * .99) - 1], 2), "max_ms": round(samples[-1], 2),
            "over_1500_ms": sum(value >= 1500 for value in samples)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--broker", default="src/priv/github_budget.py")
    parser.add_argument("--writers", type=int, default=3)
    parser.add_argument("--cpu-workers", type=int, default=1)
    parser.add_argument("--rounds", type=int, default=100)
    opts = parser.parse_args()
    if opts.writers < 2 or opts.cpu_workers < 1 or opts.rounds < 1:
        parser.error("use at least two writers, one CPU worker, and one round")
    available = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count()
    if opts.writers + opts.cpu_workers > max(1, available // 4):
        parser.error("combined writer and CPU workers must not exceed cores / 4")
    load = [subprocess.Popen([sys.executable, "-c", "while True: sum(i*i for i in range(10000))"]) for _ in range(opts.cpu_workers)]
    try:
        with tempfile.TemporaryDirectory(prefix="budget-benchmark-", dir=os.environ.get("TMPDIR")) as root:
            result = {"writers": opts.writers, "cpu_workers": opts.cpu_workers, "rounds": opts.rounds,
                      "admission_deadline_ms": 1500, "load_average": os.getloadavg(),
                      "baseline": measure(opts.baseline, False, opts.writers, opts.rounds, root),
                      "resident": measure(opts.broker, True, opts.writers, opts.rounds, root)}
            print(json.dumps(result, indent=2))
    finally:
        for process in load:
            process.terminate()
        for process in load:
            process.wait()


if __name__ == "__main__":
    main()
