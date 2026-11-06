#!/usr/bin/env python3
"""Render the published Build Order review from a ``build-order.v1`` document.

The review body is written from one document, so the GitHub review and the
dashboard review cannot disagree about waves, edges, critical path, progress,
epics, features or lanes. Which document is read depends on what is available:

``--from-daemon``
    A daemon is running. The published document is read through
    ``aiur build-orders --json --contract build-order.v1 [<root>]``, so the
    review carries live tracker and progress truth.

``--document``
    A caller already holds a document and passes the file.

neither flag (default)
    No daemon is present — the planning-only path. The skill walks the pack into
    a document with the tracker and progress sources marked ``unknown``, which
    the review renders as an explicit notice.

The pack's own graph facts are asserted against the document before anything is
written, so an inconsistent document fails here instead of publishing a review
that contradicts the plan.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "publication"))

from publication_common import Report  # noqa: E402
from publication_graph_document import (  # noqa: E402
    GraphDocumentError,
    document_source,
    load_document_file,
    pack_walk_document,
    read_daemon_document,
)
from publication_review import render_review  # noqa: E402
from publication_review_checks import check_document_against_pack  # noqa: E402


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--build", required=True, type=Path)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--document", type=Path)
    source.add_argument("--from-daemon", action="store_true")
    parser.add_argument("--root")
    parser.add_argument(
        "--cli",
        default=os.environ.get("AIUR_FEATURE_CLI") or "aiur",
        help="product CLI used for --from-daemon (default: $AIUR_FEATURE_CLI or aiur)",
    )
    parser.add_argument("--out", type=Path)
    parser.add_argument(
        "--check", type=Path,
        help="compare the rendered review with this file instead of writing it",
    )
    args = parser.parse_args(argv[1:])

    try:
        build = json.loads(args.build.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot read the build-order pack: {exc}", file=sys.stderr)
        return 1
    try:
        document = _document(build, args)
    except GraphDocumentError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    report = Report()
    clean = check_document_against_pack(build, document, report)
    if not clean:
        for message in report.errors:
            print(f"ERROR: {message}", file=sys.stderr)
        print(
            f"document source: {document_source(document)} "
            "(the review was not rendered)",
            file=sys.stderr,
        )
        return 1

    body = render_review(document)
    if args.check is not None:
        if _differs(args.check, body):
            print(
                f"ERROR: {args.check} does not match the review rendered from the "
                "build-order.v1 document",
                file=sys.stderr,
            )
            return 1
        print(f"review matches: {args.check}", file=sys.stderr)
        print(f"document source: {document_source(document)}", file=sys.stderr)
        return 0
    if args.out is not None:
        if _differs(args.out, body):
            args.out.write_text(body, encoding="utf-8")
        print(f"review written: {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(body)
    print(f"document source: {document_source(document)}", file=sys.stderr)
    return 0


def _document(build: object, args: argparse.Namespace) -> dict:
    if args.document is not None:
        return load_document_file(args.document)
    if args.from_daemon:
        return read_daemon_document(args.root, cli=args.cli)
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return pack_walk_document(build, generated_at=generated_at)


def _differs(path: Path, body: str) -> bool:
    try:
        return path.read_text(encoding="utf-8") != body
    except OSError:
        return True


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
