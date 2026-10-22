#!/usr/bin/env python3
"""Retry a coverage partition once when every failure has prior flake evidence."""

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time


FAILURE = re.compile(
    r"^.*?\b\d+\) test (.*) \(([A-Za-z0-9_.]+)\)\s*\n"
    r".*?((?:src/)?test/[^\s:]+\.exs):(\d+)", re.M
)
FAILURE_SUMMARY = re.compile(
    r"(\d+)\s+tests?,\s*(\d+)\s+failures?(?:,\s*(\d+)\s+invalid)?"
)
SETUP_FAILURE = re.compile(
    r"(?:ExUnit\.CallbackError|(?:failed|failure|crashed|error).*setup_all|"
    r"setup_all.*(?:failed|failure|crashed|error))",
    re.IGNORECASE,
)


def failures(text):
    return [
        {"test": f"{module} :: {name}", "module": module,
         "name": name, "path": path.removeprefix("src/"), "line": int(line)}
        for name, module, path, line in FAILURE.findall(re.sub(r"\x1b\[[0-9;]*m", "", text))
    ]


def known_tests(path):
    return {line.strip() for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")}


def normalized_paths(paths):
    return {path.removeprefix("src/") for path in paths}


def quarantined(test, path):
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        module, name = fields[:2]
        if module == test["module"] and (name == "*" or name == test["name"]):
            return True
    return False


def recent_base_failures(repo, branch, targets=None, now=None, timeout_seconds=20):
    """Read recent base failures, bounded by a total deadline and per-call timeout."""
    if targets is not None and not targets:
        return set()
    now = now or datetime.now(timezone.utc)
    deadline = time.monotonic() + timeout_seconds

    def gh_output(command):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, timeout_seconds)
        return subprocess.check_output(
            command, text=True, stderr=subprocess.DEVNULL,
            timeout=min(5, remaining),
        )

    try:
        runs = json.loads(gh_output([
            "gh", "run", "list", "--repo", repo, "--workflow", "ci.yml",
            "--branch", branch, "--event", "push", "--limit", "100",
            "--json", "databaseId,createdAt,conclusion",
        ]))
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return set()

    result = set()
    cutoff = now - timedelta(hours=24)
    for run in runs:
        if time.monotonic() >= deadline:
            break
        try:
            created = datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if created < cutoff or created > now:
            continue
        if run.get("conclusion") != "failure":
            continue
        try:
            text = gh_output([
                "gh", "run", "view", str(run["databaseId"]), "--repo", repo,
                "--log-failed",
            ])
        except (OSError, subprocess.SubprocessError):
            continue
        result.update(item["test"] for item in failures(text))
        if targets is not None and targets.issubset(result):
            break
    return result


def complete_test_failure(log_text, found, partition_status):
    """Accept only a completed ExUnit failure, excluding invalid/setup/infra errors."""
    if partition_status != 2 or not found or SETUP_FAILURE.search(log_text):
        return False
    summaries = FAILURE_SUMMARY.findall(log_text)
    if not summaries:
        return False
    tests, failure_count, invalid_count = summaries[-1]
    return (
        int(tests) >= len(found)
        and int(failure_count) > 0
        and int(failure_count) == len(found)
        and int(invalid_count or 0) == 0
    )


def retry_candidates(log_text, changed_paths, known_path, quarantine_path,
                     is_pull_request, partition_status=2):
    found = failures(log_text)
    if not is_pull_request or not complete_test_failure(log_text, found, partition_status):
        return []
    changed = normalized_paths(changed_paths)
    if any(item["path"] in changed for item in found):
        return []
    known = known_tests(known_path)
    return [item for item in found
            if item["test"] not in known and not quarantined(item, quarantine_path)]


def retry_plan(log_text, changed_paths, known_path, quarantine_path,
               base_failures, is_pull_request, partition_status=2):
    found = failures(log_text)
    if not complete_test_failure(log_text, found, partition_status):
        return []
    if not is_pull_request:
        return []
    changed = normalized_paths(changed_paths)
    if any(item["path"] in changed for item in found):
        return []
    known = known_tests(known_path)
    eligible = []
    for item in found:
        if (item["test"] not in known and not quarantined(item, quarantine_path)
                and item["test"] not in base_failures):
            return []
        eligible.append(item)
    return eligible


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("changed_paths", type=Path)
    parser.add_argument("known_list", type=Path)
    parser.add_argument("quarantine_list", type=Path)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base-branch", required=True)
    parser.add_argument("--pull-request", action="store_true")
    parser.add_argument("--partition", required=True)
    parser.add_argument("--base-failures", type=Path)
    parser.add_argument("--partition-status", type=int, required=True)
    args = parser.parse_args()

    log_text = args.log.read_text(errors="replace")
    changed_paths = set(args.changed_paths.read_text().splitlines())
    candidates = retry_candidates(
        log_text, changed_paths, args.known_list, args.quarantine_list,
        args.pull_request, args.partition_status,
    )
    known = known_tests(args.known_list)
    uncovered = {
        item["test"] for item in candidates
        if item["test"] not in known and not quarantined(item, args.quarantine_list)
    }
    base_failed = set()
    if args.base_failures:
        base_failed = {item["test"] for item in failures(args.base_failures.read_text(errors="replace"))}
    elif uncovered:
        base_failed = recent_base_failures(args.repo, args.base_branch, targets=uncovered)

    plan = retry_plan(
        log_text, changed_paths, args.known_list, args.quarantine_list,
        base_failed, args.pull_request, args.partition_status,
    )
    if not plan:
        print("coverage retry: not eligible; original partition failure remains")
        return 1

    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps({"partition": args.partition,
                                        "tests": plan}, indent=2) + "\n")
    with args.summary.open("a") as summary:
        summary.write("\n### Retried known flakes\n\n")
        summary.write("Retrying only these previously observed failing tests once:\n")
        summary.writelines(f"- `{item['test']}` (`{item['path']}:{item['line']}`)\n"
                           for item in plan)
    for item in plan:
        print(f"{item['path']}:{item['line']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
