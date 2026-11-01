#!/usr/bin/env python3
"""Preprocess snapshots and compile the daily newsletter (Python standard library)."""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess
import tempfile

from collect import collect, discover_repo, write_snapshot
from editorial import read_notes
from metrics import compute
from render import compile_report


def prepare(repo, state_dir, now, instances=(), notes=None, output_date=None, aiur="aiur"):
    directory = state_dir / "newsletter"
    snapshot = collect(repo, state_dir, now, instances=instances, telemetry_root=Path.home() / ".aiur/logs", aiur=aiur)
    baseline = directory / "snapshots" / ((now - timedelta(days=1)).date().isoformat() + ".json")
    yesterday = json.loads(baseline.read_text()) if baseline.exists() else None
    report = compute(snapshot, yesterday)
    report["editorial"] = notes or {}
    report["sources"] = [name + ": " + info["state"] for name, info in snapshot["sources"].items()]
    write_snapshot(snapshot, directory / "snapshots")
    target = directory / (output_date or now.date().isoformat()) / "report.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    return target, report


def preprocess(repo, state_dir, now, instances=(), notes=None, output_date=None, aiur="aiur"):
    target, report = prepare(repo, state_dir, now, instances, notes, output_date, aiur)
    target.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return target


def publish(report_path, report, timezone_name):
    report_path = report_path.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".newsletter-", dir=report_path.parent) as temporary:
        root = Path(temporary)
        (root / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        compile_report(report, root / 'newsletter.pdf', timezone_name)
        for name in ('newsletter.html', 'newsletter.pdf'):
            (root / name).replace(report_path.with_name(name))
        (root / 'report.json').replace(report_path)
    return report_path.with_name('newsletter.pdf')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("preprocess", "build"):
        child = commands.add_parser(command)
        child.add_argument("--repo", help="owner/repo; defaults to current origin")
        child.add_argument("--state-dir", type=Path, help="Aiur per-repository state root")
        child.add_argument("--instance", action="append", default=[], help="additional configured daemon")
        child.add_argument("--aiur", default="aiur", help="CLI executable targeting this repository daemon")
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
            report = json.loads(report_path.read_text())
        else:
            repo = args.repo or discover_repo()
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or any(p in (".", "..") for p in repo.split('/')):
                raise ValueError("repo must be owner/repo")
            root = args.state_dir or Path.home() / ".aiur/repo" / repo
            if args.command == "preprocess":
                print(preprocess(repo, root, datetime.now(timezone.utc), args.instance, notes))
                return
            report_path, report = prepare(repo, root, datetime.now(timezone.utc), args.instance, notes)
        if notes:
            report["editorial"] = {**report.get("editorial", {}), **notes}
        print(publish(report_path, report, args.timezone))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"newsletter: {error}\n")


if __name__ == "__main__":
    main()
