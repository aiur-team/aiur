"""Shared CLI helpers for the analytics tools."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import sources


def add_discovery_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--telemetry", action="append", default=None, metavar="PATH",
                        help="Telemetry file or directory (repeatable). Default: ~/.aiur/logs")
    parser.add_argument("--state-node", default=None, metavar="PATH",
                        help="Per-repo state node root (~/.aiur/repo/<owner>/<name>). Auto-detected when omitted.")
    parser.add_argument("--repo", default=None, metavar="OWNER/NAME",
                        help="Repository slug used to derive the state node when --state-node is absent.")


def resolve_state_node(args: argparse.Namespace) -> Path:
    return sources.state_node_root(args.repo, args.state_node)


def discover(args: argparse.Namespace) -> list[Path]:
    files = sources.discover_telemetry_files(args.telemetry or [])
    if not files:
        print("analytics: no telemetry files found under %s" % (args.telemetry or sources.DEFAULT_LOGS_ROOT),
              file=sys.stderr)
        sys.exit(2)
    return files


def read_github_events(args: argparse.Namespace) -> list[dict]:
    """Read --github-events FILE (JSON array) if supplied; otherwise []."""
    path = getattr(args, "github_events", None)
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as error:
        print("analytics: could not read github events file %s: %s" % (path, error), file=sys.stderr)
        sys.exit(2)
    if not isinstance(payload, list):
        print("analytics: github events file must contain a JSON array", file=sys.stderr)
        sys.exit(2)
    return payload


def emit_json(payload: dict) -> None:
    print(json.dumps(payload, indent=2, default=str))


def boot_ids_from(dataset: dict) -> list[str]:
    return sorted(
        {record["boot_id"] for record in dataset.get("records", []) if record.get("boot_id") != "github"}
    )
