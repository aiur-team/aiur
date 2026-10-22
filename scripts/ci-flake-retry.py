#!/usr/bin/env python3
"""Retry a coverage partition once when every failure has prior flake evidence."""

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess
import sys


FAILURE = re.compile(
    r"^.*?\b\d+\) test (.*) \(([A-Za-z0-9_.]+)\)\s*\n"
    r".*?((?:src/)?test/[^\s:]+\.exs):(\d+)", re.M
)
FAILURE_SUMMARY = re.compile(r"(\d+)\s+tests?,\s*(\d+)\s+failures?")


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


def recent_base_failures(repo, branch, now=None):
    """Read recent main CI failure logs; an API failure safely disables this source."""
    now = now or datetime.now(timezone.utc)
    try:
        runs = json.loads(subprocess.check_output([
            "gh", "run", "list", "--repo", repo, "--workflow", "ci.yml",
            "--branch", branch, "--event", "push", "--limit", "100",
            "--json", "databaseId,createdAt,conclusion",
        ], text=True, stderr=subprocess.DEVNULL))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return set()

    result = set()
    cutoff = now - timedelta(hours=24)
    for run in runs:
        try:
            created = datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if created < cutoff or created > now:
            continue
        if run.get("conclusion") != "failure":
            continue
        try:
            text = subprocess.check_output([
                "gh", "run", "view", str(run["databaseId"]), "--repo", repo,
                "--log-failed",
            ], text=True, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            continue
        result.update(item["test"] for item in failures(text))
    return result


def retry_plan(log_text, changed_paths, known_path, quarantine_path,
               base_failures, is_pull_request):
    found = failures(log_text)
    summaries = FAILURE_SUMMARY.findall(log_text)
    complete_summary = bool(summaries) and int(summaries[-1][1]) == len(found)
    if not is_pull_request or not found or not complete_summary:
        return []
    known = known_tests(known_path)
    eligible = []
    for item in found:
        if item["path"] in normalized_paths(changed_paths):
            return []
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
    args = parser.parse_args()

    base_failed = set()
    if args.base_failures:
        base_failed = {item["test"] for item in failures(args.base_failures.read_text(errors="replace"))}
    else:
        base_failed = recent_base_failures(args.repo, args.base_branch)

    plan = retry_plan(
        args.log.read_text(errors="replace"),
        set(args.changed_paths.read_text().splitlines()), args.known_list,
        args.quarantine_list, base_failed, args.pull_request,
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
