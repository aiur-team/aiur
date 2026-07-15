#!/usr/bin/env python3
"""Validate a committed execution amendment without weakening receipt v3."""

from __future__ import annotations

import argparse
import tempfile
from pathlib import Path
from typing import Callable

from execution_amendment import (
    load_amendment_at_commit,
    validate_amendment_schema,
    validate_policy_authority_source,
)
from execution_amendment_live import (
    ExecutionReader,
    verify_live_execution_amendment,
)
from publication_common import Report
from publication_receipt_authority import (
    ReceiptAuthority,
    _clone_without_checkout,
    _github_repository_ref_contains,
    _require_local_receipt_order,
    load_receipt_authority,
)
from publication_rendering import reject_legacy_grafts, repository_root
from validate_publication import validate as validate_publication


RemoteRefChecker = Callable[[str, str, str, str], bool]


def validate(
    amendment_path: Path,
    amendment_commit: str,
    *,
    live: bool = True,
    reader: ExecutionReader | None = None,
    remote_ref_contains: RemoteRefChecker | None = None,
) -> Report:
    report = Report()
    amendment = load_amendment_at_commit(amendment_path, amendment_commit, report)
    if amendment is None:
        return report

    base = amendment_path.parent
    publication_report = validate_publication(
        base / "build-order.json", base / "publication.json",
    )
    report.errors.extend(
        f"immutable publication baseline: {item}"
        for item in publication_report.errors
    )
    report.warnings.extend(
        f"immutable publication baseline: {item}"
        for item in publication_report.warnings
    )
    if publication_report.errors or publication_report.warnings:
        return report

    receipt_commit = amendment.get("publication_receipt_commit")
    if not isinstance(receipt_commit, str):
        report.error("execution amendment publication receipt is unavailable")
        return report
    authority = load_receipt_authority(
        receipt_commit,
        amendment_path,
        report,
        remote_ref_contains,
    )
    if authority is None:
        return report
    validate_policy_authority_source(amendment_path, amendment, report)
    _validate_amendment_authority(
        amendment_path,
        authority,
        amendment,
        receipt_commit,
        amendment_commit,
        remote_ref_contains,
        report,
    )
    validate_amendment_schema(amendment, authority, report)
    if report.errors or report.warnings or not live:
        return report
    verify_live_execution_amendment(authority, amendment, report, reader)
    return report


def _validate_amendment_authority(
    amendment_path: Path,
    authority: ReceiptAuthority,
    amendment: dict[str, object],
    receipt_commit: str,
    amendment_commit: str,
    remote_ref_contains: RemoteRefChecker | None,
    report: Report,
) -> None:
    if receipt_commit == amendment_commit:
        report.error("amendment_commit must strictly descend from publication receipt")
        return
    # The exact policy commit/hash are schema-bound and independently read from
    # Git below; only the commit participates in ancestry authority.
    policy_value = amendment.get("policy_authority")
    policy_commit = (
        policy_value.get("commit") if isinstance(policy_value, dict) else None
    )
    if not isinstance(policy_commit, str) or policy_commit in (
        receipt_commit, amendment_commit,
    ):
        report.error(
            "policy authority must strictly follow the publication receipt and "
            "strictly precede the amendment commit"
        )
        return
    root = repository_root(amendment_path, report)
    if root is None or not reject_legacy_grafts(root, report):
        return
    local = Report()
    with tempfile.TemporaryDirectory() as name:
        clone = Path(name) / "execution-amendment-authority"
        if _clone_without_checkout(root, clone, local):
            if reject_legacy_grafts(clone, local):
                _require_local_receipt_order(
                    clone, receipt_commit, policy_commit, local,
                )
                _require_local_receipt_order(
                    clone, policy_commit, amendment_commit, local,
                )
    report.errors.extend(local.errors)
    report.errors.extend(
        f"execution amendment authority warning: {item}"
        for item in local.warnings
    )
    if local.errors or local.warnings:
        return
    checker = remote_ref_contains or _github_repository_ref_contains
    try:
        policy_contained = checker(
            authority.repository, authority.trusted_repository_ref,
            receipt_commit, policy_commit,
        )
        amendment_contained = checker(
            authority.repository, authority.trusted_repository_ref,
            policy_commit, amendment_commit,
        )
    except Exception:
        policy_contained = amendment_contained = False
    if policy_contained is not True or amendment_contained is not True:
        report.error(
            "publication receipt and amendment commits must remain strictly ordered "
            "ancestors of the immutable trusted repository ref"
        )
    # A graft introduced during either ancestry proof must still fail closed.
    reject_legacy_grafts(root, report)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--amendment",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "execution-amendment.json",
    )
    parser.add_argument("--amendment-commit", required=True)
    parser.add_argument(
        "--static",
        action="store_true",
        help="validate committed authority/schema but skip live GitHub reads",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    report = validate(
        args.amendment,
        args.amendment_commit,
        live=not args.static,
    )
    for message in sorted(report.errors):
        print(f"ERROR: {message}")
    for message in sorted(report.warnings):
        print(f"WARN: {message}")
    print(
        f"validation: {len(report.errors)} error(s), "
        f"{len(report.warnings)} warning(s)"
    )
    return 1 if report.errors or report.warnings else 0


if __name__ == "__main__":
    raise SystemExit(main())
