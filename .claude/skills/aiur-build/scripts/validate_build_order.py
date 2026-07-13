#!/usr/bin/env python3
"""Validate an aiur-build canonical build-order.json planning baseline."""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

from validation_common import Report, repository_path_from_file
from validation_git_authority import validate_publication_commit_authority
from validation_git_snapshot import materialize_receipt_pack
from validation_github_approved import (
    ApprovedIssueExpectations,
    render_approved_build_order,
)
from validation_github import validate_all_github
from validation_github_live import GhApiReader, validate_live_github_receipt
from validation_graph import (
    dependency_closure,
    validate_boundary_refs,
    validate_edge_types,
    validate_hierarchy,
    validate_phases,
    validate_references,
)
from validation_header import (
    validate_boundary,
    validate_external_gates,
    validate_identity,
    validate_label_projection,
    validate_requirements,
    validate_workstreams,
)
from validation_outcome import (
    validate_epic_acceptance,
    validate_label_coverage,
    validate_surface_conflicts,
)
from validation_records import validate_decisions, validate_design_evidence, validate_record_refs
from validation_tickets import validate_tickets
from validation_publication_authority import PublicationAuthority


def validate_data(
    value: object, base_dir: Path,
    approved_expectations: ApprovedIssueExpectations | None = None,
    publication_authority: PublicationAuthority | None = None,
) -> Report:
    report = Report()
    if not isinstance(value, dict):
        report.error("top level must be a JSON object")
        return report
    data: dict[str, Any] = value
    validate_identity(data, report)
    workstreams = validate_workstreams(data, report)
    critical_path = validate_boundary(data, report)
    projection = validate_label_projection(data, report)
    gates = validate_external_gates(data, report)
    requirements = validate_requirements(data, report)
    design = validate_design_evidence(data, base_dir, report)
    decisions = validate_decisions(data, report)
    by_id = validate_tickets(data, base_dir, report)
    validate_record_refs(design, decisions, by_id, report)
    validate_references(requirements, by_id, workstreams, gates, report)
    validate_edge_types(by_id, report)
    closure = dependency_closure(by_id, report)
    validate_hierarchy(by_id, report)
    validate_phases(by_id, report)
    validate_boundary_refs(critical_path, by_id, report)
    validate_label_coverage(projection, workstreams, by_id, report)
    validate_surface_conflicts(by_id, closure, report)
    validate_epic_acceptance(data, by_id, closure, critical_path, report)
    validate_all_github(
        data, by_id, report, approved_expectations, publication_authority,
    )
    return report


def load(path: Path, report: Report) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"cannot read valid JSON: {exc}")
        return None


def _validate_path(
    path: Path,
    repository_root: Path | None,
    root_document: str | None,
    report: Report,
    publication_authority: PublicationAuthority | None = None,
) -> tuple[object | None, Report]:
    value = load(path, report)
    expectations = None
    if isinstance(value, dict) and repository_root is not None and root_document is not None:
        build_path = repository_path_from_file(
            path, repository_root, "build-order path", report,
        )
        receipt = value.get("github_reconciliation")
        approved = receipt.get("approved_planning_commit") if isinstance(receipt, dict) else None
        if build_path is not None:
            expectations = render_approved_build_order(
                repository_root, approved, build_path, root_document, value, report,
            )
    if value is None:
        return value, report
    validated = validate_data(
        value, path.parent, expectations, publication_authority,
    )
    validated.errors[:0] = report.errors
    validated.warnings[:0] = report.warnings
    return value, validated


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
    _, report = _validate_path(
        args.path, args.repository_root, args.root_document, Report(),
    )
    return _print_report(report)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
