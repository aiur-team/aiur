#!/usr/bin/env python3
"""Validate an aiur-build canonical build-order.json planning baseline."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from validation_common import Report
from validation_github_approved import render_approved_build_order, repository_relative
from validation_github import validate_all_github
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


def validate_data(
    value: object, base_dir: Path,
    approved_body_expectations: dict[str, dict[str, Any]] | None = None,
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
    validate_all_github(data, by_id, report, approved_body_expectations)
    return report


def load(path: Path, report: Report) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"cannot read valid JSON: {exc}")
        return None


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
    path = args.path
    load_report = Report()
    value = load(path, load_report)
    expectations = None
    if isinstance(value, dict) and args.repository_root is not None:
        build_path = repository_relative(path, args.repository_root, load_report)
        receipt = value.get("github_reconciliation")
        approved = receipt.get("approved_planning_commit") if isinstance(receipt, dict) else None
        if build_path is not None:
            expectations = render_approved_build_order(
                args.repository_root, approved, build_path, args.root_document,
                value, load_report,
            )
    if value is None:
        report = load_report
    else:
        report = validate_data(value, path.parent, expectations)
        report.errors[:0] = load_report.errors
        report.warnings[:0] = load_report.warnings
    for message in report.errors:
        print(f"ERROR: {message}")
    for message in report.warnings:
        print(f"WARN: {message}")
    print(f"validation: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
