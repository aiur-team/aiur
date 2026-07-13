#!/usr/bin/env python3
"""Validate an aiur-build canonical build-order.json planning baseline."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from validation_common import Report
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


def validate_data(value: object, base_dir: Path) -> Report:
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
    validate_all_github(data, by_id, report)
    return report


def load(path: Path, report: Report) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        report.error(f"cannot read valid JSON: {exc}")
        return None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate_build_order.py path/to/build-order.json", file=sys.stderr)
        return 64
    path = Path(argv[1])
    load_report = Report()
    value = load(path, load_report)
    report = load_report if value is None else validate_data(value, path.parent)
    for message in report.errors:
        print(f"ERROR: {message}")
    for message in report.warnings:
        print(f"WARN: {message}")
    print(f"validation: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
