#!/usr/bin/env python3
"""Append measured per-file ExUnit timings and shard composition to a summary."""

import argparse
from pathlib import Path
import re


def read_timings(path):
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return []
    if not lines or lines[0] != "path\ttests\ttotal_us\tmax_us":
        return []

    rows = []
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 4 or not fields[0].startswith("test/"):
            continue
        try:
            count, total_us, max_us = map(int, fields[1:])
        except ValueError:
            continue
        if min(count, total_us, max_us) < 0:
            continue
        rows.append({"path": fields[0], "tests": count, "total_us": total_us, "max_us": max_us})
    return rows


def render_summary(partition, log_path, timings_path):
    log = log_path.read_text(errors="replace") if log_path.exists() else ""
    timing_rows = read_timings(timings_path)
    composition = re.findall(r"coverage-partition: shard \d+/\d+ -> \d+ test files|coverage-partition: shard \d+ holds \d+ files", log)
    suite_times = re.findall(r"Finished in ([\d.]+) seconds", log)
    completed = bool(suite_times)

    lines = [f"### coverage ({partition}/4) shard composition", "", "```", *(composition or ["(no shard header; see the partition log)"]), "```", ""]
    if completed:
        lines.extend([f"ExUnit suite runtime: {suite_times[-1]} seconds.", ""])
    else:
        lines.extend(["The ExUnit run ended without a completed suite summary; recorded file timings may be partial.", ""])
    lines.extend([
        "#### Slowest test files by summed ExUnit time",
        "",
        "Individual test times are summed by source file; async tests overlap, so this is work data rather than shard wall time.",
        "",
    ])

    if timing_rows:
        lines.extend([
            "| Test file | Tests | Sum (s) | Longest test (s) |",
            "| --- | ---: | ---: | ---: |",
        ])
        for row in sorted(timing_rows, key=lambda item: (-item["total_us"], item["path"]))[:10]:
            lines.append(
                f"| `{row['path']}` | {row['tests']} | {row['total_us'] / 1_000_000:.1f} | {row['max_us'] / 1_000_000:.1f} |"
            )
    else:
        lines.append("No completed test-file timings were recorded.")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("partition", type=int)
    parser.add_argument("log", type=Path)
    parser.add_argument("timings", type=Path)
    parser.add_argument("summary", type=Path)
    args = parser.parse_args()
    args.summary.write_text(args.summary.read_text() + render_summary(args.partition, args.log, args.timings)
                            if args.summary.exists()
                            else render_summary(args.partition, args.log, args.timings))


if __name__ == "__main__":
    main()
