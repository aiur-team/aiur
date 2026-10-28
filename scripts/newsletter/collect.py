#!/usr/bin/env python3
"""Write daily repository snapshots. Run --help for source and output options."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone

from classification import classify
from github import GitHub, ISSUE, PR, closing_issue, command
from local_sources import envelope_source, iso, parse_time, read_actions, read_meta, source


FAILURES = (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


def ticket(node):
    labels = [label["name"] for label in node["labels"]["nodes"]]
    lane = next((label for label in labels if label.startswith(("build-lane:", "feature:"))), None)
    return {"number": node["number"], "title": node["title"], "state": node["state"].lower(),
            "state_reason": node.get("stateReason"), "labels": labels, "lane": lane,
            "class": classify(" ".join(labels) + " " + node["title"] if labels else node["title"]),
            "mobile": any(re.search(r"(?:^|[:-])(mobile|watch)(?:$|[:-])", label) for label in labels),
            "paused": any(label.split(":")[-1] in ("paused", "parked") for label in labels),
            "machine": "nuc" if any(label.startswith("nuc:") for label in labels) else "pc",
            "created_at": node["createdAt"], "closed_at": node.get("closedAt"), "lifecycle": None}


def collect(repo, state_dir, now, github=None, run=command, instances=()):
    gh = github or GitHub(repo, run)
    start = now - timedelta(hours=24)
    captured = iso(now)
    sources = {}

    def read(name, operation):
        try:
            value = operation()
            sources[name] = source("available", captured)
            return value
        except FAILURES as error:
            sources[name] = source("unavailable", reason=str(error))
            return None

    labels = read("github_phases", gh.phase_labels)
    numbers = None
    if labels is not None:
        # Comma-separated labels are an OR, including open and closed issues.
        expression = "is:issue label:" + ",".join('"' + label + '"' for label in labels)
        numbers = read("github_program", lambda: gh.search(expression, ISSUE, "Issue")) if labels else []
    if numbers is None:
        sources.setdefault("github_program", source("unavailable", reason="phase labels unavailable"))
    def program_nodes():
        if any(n["labels"]["pageInfo"]["hasNextPage"] for n in numbers):
            raise RuntimeError("program issue labels truncated")
        return {n["number"]: n for n in numbers}
    nodes = read("github_tickets", program_nodes) if numbers is not None else None
    tickets = [ticket(n) for n in nodes.values()] if nodes is not None else None
    merged = read("github_merges", lambda: gh.search(
        "is:pr is:merged merged:>=" + iso(now - timedelta(hours=48)), PR, "PullRequest"))
    merges = None
    if merged is not None:
        merged = {p["number"]: p for p in merged
                  if p.get("mergedAt") and now - timedelta(hours=48) <= parse_time(p["mergedAt"]) <= now}
        closing = read("github_merge_issues", lambda: gh.issues(
            [n for p in merged.values() if (n := closing_issue(p)) is not None]))
        merges = []
        for pr in merged.values():
            issue = closing_issue(pr)
            related = ticket(closing[issue]) if closing is not None and issue in closing else None
            # Match feature-share's title-only fallback for PRs without an issue.
            category = classify(" ".join(related["labels"]) + " " + pr["title"]
                                if related and related["labels"] else pr["title"])
            if related is None and issue is not None:
                category = None
            merges.append({"number": pr["number"], "merged_at": pr["mergedAt"],
                           "merge_sha": (pr.get("mergeCommit") or {}).get("oid"), "closing_issue": issue,
                           "class": category, "mobile": related["mobile"] if related else None,
                           "machine": related["machine"] if related else None})

    units = {}
    builds = {}
    for index, instance in enumerate([None, *instances]):
        key = "local" if instance is None else f"instance_{index}"
        args = ["aiur"] + (["--instance", instance] if instance else [])
        data = read("units_" + key, lambda: json.loads(run(args + ["units", "--scope", "all", "--json"])))
        if data is not None:
            try:
                sources["units_" + key] = envelope_source(data, "units_catalog", now)
                if sources["units_" + key]["state"] == "available":
                    for row in data["data"]["view"]["rows"]:
                        identity = row["identity"]
                        if "/".join((identity.get("owner", ""), identity.get("repository", ""))).lower() != repo.lower():
                            continue
                        number = int(identity["identifier"])
                        if row["lifecycle"] not in ("running", "allocated", "waiting", "queued", "retrying", "paused", "replaced", "completed", "cancelled"):
                            raise RuntimeError("unknown daemon ticket lifecycle")
                        if number in units and units[number] != row["lifecycle"]:
                            raise RuntimeError("daemons disagree on ticket lifecycle")
                        units[number] = row["lifecycle"]
            except FAILURES as error:
                sources["units_" + key] = source("unavailable", reason=str(error))
        build = (data or {}).get("auxiliary", {}).get("running_build", {})
        builds[key] = {"sha": build.get("sha"), "built_at": build.get("built_at")}
        try:
            complete = bool(re.fullmatch(r"[0-9a-fA-F]{40}", build.get("sha") or "")
                            and build.get("built_at") and parse_time(build["built_at"]) <= now)
        except (ValueError, TypeError):
            complete = False
        sources["running_build_" + key] = source("available", captured) if complete else source(
            "unavailable", captured if data else None, "daemon build stamp absent or incomplete")
    for row in tickets or []:
        row["lifecycle"] = units.get(row["number"])
    counts = None
    fresh = all(sources["units_" + ("local" if i == 0 else f"instance_{i}")]["state"] == "available"
                for i in range(len(instances) + 1))
    allocation_nodes = read("github_allocation", lambda: gh.issues(units)) if fresh else None
    if allocation_nodes is not None:
        counts = {life: {kind: 0 for kind in ("feature", "test_ci", "other")}
                  for life in ("running", "waiting", "paused")}
        for number, lifecycle in units.items():
            row = ticket(allocation_nodes[number])
            life = {"allocated": "running", "queued": "waiting", "retrying": "waiting"}.get(lifecycle, lifecycle)
            if life in counts:
                counts[life][row["class"]] += 1
    sources["allocation"] = source("available", captured) if counts is not None else source(
        "unavailable", reason="complete fresh daemon lifecycles and ticket classifications required")
    sources["agent_hours"] = source("unavailable", reason="daemon CLI does not provide per-ticket active intervals covering this window")
    meta = read("meta", lambda: read_meta(state_dir, start, now))
    actions = read("executor_actions", lambda: read_actions(state_dir, start, now))
    return {"schema_version": 1, "repo": repo, "captured_at": captured,
            "window_start": iso(start), "window_end": captured, "sources": sources,
            "program": {"definition": {"phase_labels": labels, "membership": "any phase:* label; open and closed"},
                        "tickets": sorted(tickets, key=lambda r: r["number"]) if tickets is not None else None},
            "merges": merges, "running_build": builds,
            "allocation": {"units": counts, "agent_hours": None, "agent_hours_reason": sources["agent_hours"]["reason"]},
            "meta": meta, "executor_actions": actions,
            "github_cost": {"graphql_points": gh.cost if gh.cost_complete else None,
                            "reported_points": gh.cost, "requests": gh.calls,
                            "reason": None if gh.cost_complete else "one or more request costs unavailable",
                            "request_ceiling": 24}}


def write_snapshot(snapshot, directory):
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / (snapshot["captured_at"][:10] + ".json")
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=directory, prefix=".snapshot-", delete=False) as stream:
            name = stream.name
            json.dump(snapshot, stream, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, target)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)
    return target


def discover_repo():
    remote = command(["git", "-C", str(Path.cwd()), "remote", "get-url", "origin"]).strip().rstrip("/")
    match = re.fullmatch(r"(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?", remote)
    if not match:
        raise RuntimeError("Cannot derive a GitHub repository from origin; specify --repo owner/repo")
    return match[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="owner/repo; defaults to the current repository")
    parser.add_argument("--state-dir", type=Path, help="per-repository Aiur state directory")
    parser.add_argument("--out", type=Path, help="snapshot directory (default: <state-dir>/newsletter/snapshots)")
    parser.add_argument("--instance", action="append", default=[], help="additional configured daemon instance; repeatable")
    args = parser.parse_args()
    repo = args.repo or discover_repo()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or any(part in (".", "..") for part in repo.split("/")):
        parser.error("repo must be owner/repo")
    state_dir = args.state_dir or Path.home() / ".aiur" / "repo" / repo
    snapshot = collect(repo, state_dir, datetime.now(timezone.utc), instances=args.instance)
    print(write_snapshot(snapshot, args.out or state_dir / "newsletter" / "snapshots"))


if __name__ == "__main__":
    main()
