#!/usr/bin/env python3
"""Preprocess snapshots and compile the daily newsletter (Python standard library)."""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess

from collect import collect, discover_repo, write_snapshot
from editorial import read_notes
from metrics import compute
from render import compile_report


def preprocess(repo, state_dir, now, instances=(), notes=None):
    directory = state_dir / "newsletter"
    snapshot = collect(repo, state_dir, now, instances=instances, telemetry_root=Path.home() / ".aiur/logs")
    baseline = directory / "snapshots" / ((now - timedelta(days=1)).date().isoformat() + ".json")
    yesterday = json.loads(baseline.read_text()) if baseline.exists() else None
    report = compute(snapshot, yesterday)
    report["editorial"] = notes or {}
    report["sources"] = [name + ": " + info["state"] for name, info in snapshot["sources"].items()]
    write_snapshot(snapshot, directory / "snapshots")
    target = directory / now.date().isoformat() / "report.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("preprocess", "build"):
        child = commands.add_parser(command)
        child.add_argument("--repo", help="owner/repo; defaults to current origin")
        child.add_argument("--state-dir", type=Path, help="Aiur per-repository state root")
        child.add_argument("--instance", action="append", default=[], help="additional configured daemon")
        child.add_argument("--notes", type=Path, help="editorial JSON or Markdown")
        child.add_argument("--timezone", help="IANA operator time zone (default: local)")
    child = commands.add_parser("compile")
    child.add_argument("report", type=Path)
    child.add_argument("--notes", type=Path)
    child.add_argument("--timezone", help="IANA operator time zone (default: local)")
    args = parser.parse_args()
    try:
        notes = read_notes(args.notes)
        if args.command == "compile":
            report_path = args.report
        else:
            repo = args.repo or discover_repo()
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or any(p in (".", "..") for p in repo.split('/')):
                raise ValueError("repo must be owner/repo")
            root = args.state_dir or Path.home() / ".aiur/repo" / repo
            report_path = preprocess(repo, root, datetime.now(timezone.utc), args.instance, notes)
        if args.command == "preprocess":
            print(report_path)
        else:
            report = json.loads(report_path.read_text())
            if notes:
                report["editorial"] = {**report.get("editorial", {}), **notes}
                report_path.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
            print(compile_report(report, report_path.with_name("newsletter.pdf"), args.timezone))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"newsletter: {error}\n")


if __name__ == "__main__":
    main()
