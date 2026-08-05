"""``flake-report`` — BLOCKED, not shipped.

There is no durable flake database today: ``CIApprovalStore`` keeps only
current-session head-SHA sets and ``GithubCiPoller`` persists no history. Per
ticket #1459 this tool must not ship as a script over an empty file. The schema
contract (``schema/flake-report.v1.json``) is provided; this entry point exists
only so an Executor who tries the tool gets an explicit, actionable "blocked"
answer instead of a silent empty report.
"""

from __future__ import annotations

import argparse
import sys

BLOCKED_MESSAGE = (
    "flake-report is not shipped: there is no durable CI-outcome flake database yet.\n"
    "It is blocked on recording CI outcomes durably (CIApprovalStore keeps only "
    "current-session head-SHA sets; GithubCiPoller persists no history).\n"
    "The schema contract is available at analytics/schema/flake-report.v1.json.\n"
    "Do not ship a script over an empty file — land durable CI-outcome recording "
    "first, then implement this tool against it."
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="flake-report",
        description="Tests ranked by failure count with pass-after-retry ratio. Not yet shipped (see README).",
    )
    parser.add_argument("--since", default="7d", metavar="WINDOW", help="Look-back window (accepted for CLI parity).")
    parser.add_argument("--json", action="store_true", help="Unused; the tool is blocked.")
    return parser


def main(argv: list[str] | None = None) -> int:
    build_parser().parse_args(argv)
    sys.stderr.write(BLOCKED_MESSAGE + "\n")
    return 3


if __name__ == "__main__":
    sys.exit(main())
