#!/usr/bin/env python3
"""Validate an aiur-build canonical build-order.json planning baseline."""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path, PurePosixPath

from validation_build_order import _validate_path, load, validate_data
from validation_common import Report, repository_path_from_file
from validation_git_authority import validate_publication_commit_authority
from validation_git_snapshot import materialize_receipt_pack
from validation_github_live import GhApiReader, validate_live_github_receipt
from validation_publication_authority import load_manifest_publication_authority


def _validate_receipt(
    path: Path,
    repository_root: Path,
    root_document: str,
    receipt_commit: str,
) -> Report:
    report = Report()
    build_path = repository_path_from_file(
        path, repository_root, "build-order path", report,
    )
    if build_path is None:
        return report
    pack_path = str(PurePosixPath(build_path).parent)
    with tempfile.TemporaryDirectory() as directory:
        snapshot = Path(directory) / "receipt"
        if not materialize_receipt_pack(
            repository_root, receipt_commit, pack_path, snapshot, report,
        ):
            return report
        receipt_path = snapshot.joinpath(*PurePosixPath(build_path).parts)
        preview = load(receipt_path, report)
        if not isinstance(preview, dict):
            return report
        receipt = preview.get("github_reconciliation")
        approved = (
            receipt.get("approved_planning_commit")
            if isinstance(receipt, dict) else None
        )
        publication_path = str(PurePosixPath(build_path).parent / "publication.json")
        authority = validate_publication_commit_authority(
            repository_root,
            preview.get("repository"),
            publication_path,
            approved,
            receipt_commit,
            report,
        )
        if authority is None or report.errors:
            return report
        if root_document != authority.root_document:
            report.error(
                "--root-document must equal immutable publication root_document"
            )
            return report
        value, validated = _validate_path(
            receipt_path, snapshot, authority.root_document, report, authority,
        )
        if isinstance(value, dict):
            receipt = value.get("github_reconciliation")
            approved = (
                receipt.get("approved_planning_commit")
                if isinstance(receipt, dict) else None
            )
            if not validated.errors:
                validate_live_github_receipt(
                    value, validated, GhApiReader(repository_root.resolve()),
                )
            if not validated.errors:
                # Re-prove branch authority after the bounded live read so a
                # concurrent ref revocation cannot hide behind the first check.
                validate_publication_commit_authority(
                    repository_root,
                    value.get("repository"),
                    publication_path,
                    approved,
                    receipt_commit,
                    validated,
                )
        return validated


def _print_report(report: Report) -> int:
    for message in report.errors:
        print(f"ERROR: {message}")
    for message in report.warnings:
        print(f"WARN: {message}")
    print(f"validation: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    return 1 if report.errors else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="validate_build_order.py",
        description="Validate an aiur-build canonical planning baseline.",
    )
    parser.add_argument("path", type=Path)
    parser.add_argument(
        "--repository-root", type=Path,
        help="Git repository containing the immutable approved planning commit",
    )
    parser.add_argument(
        "--root-document",
        help="repository-relative full-body root issue template at approval",
    )
    parser.add_argument(
        "--receipt-commit",
        help="exact post-publication receipt commit linked by the start gate",
    )
    parser.add_argument(
        "--publication-manifest", type=Path,
        help="publication manifest supplying the tracker lifecycle label prefix "
             "from outside the validated Build Order",
    )
    try:
        args = parser.parse_args(argv[1:])
    except SystemExit as exc:
        return int(exc.code)
    if (args.repository_root is None) != (args.root_document is None):
        print(
            "ERROR: --repository-root and --root-document must be supplied together"
        )
        print("validation: 1 error(s), 0 warning(s)")
        return 1
    if args.receipt_commit is not None and args.repository_root is None:
        print("ERROR: receipt validation requires --repository-root and --root-document")
        print("validation: 1 error(s), 0 warning(s)")
        return 1
    if args.receipt_commit is not None:
        assert args.repository_root is not None and args.root_document is not None
        return _print_report(_validate_receipt(
            args.path,
            args.repository_root,
            args.root_document,
            args.receipt_commit,
        ))
    report = Report()
    authority = None
    if args.publication_manifest is not None:
        authority = load_manifest_publication_authority(
            args.publication_manifest, report,
        )
        if authority is None:
            return _print_report(report)
    _, report = _validate_path(
        args.path, args.repository_root, args.root_document, report, authority,
    )
    return _print_report(report)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
