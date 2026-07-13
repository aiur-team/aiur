"""Validate Build Order identity, boundary, labels, gates, and requirements."""

from __future__ import annotations

from typing import Any

from validation_common import (
    DISPOSITIONS,
    GATE_ID,
    REPOSITORY,
    REQ_ID,
    SHA,
    SLUG,
    Report,
    checked_string_list,
    nonempty_string,
    strict_int,
    strict_object,
)


TOP_KEYS = {
    "schema_version", "build_order_id", "ticket_prefix", "plan_version",
    "repository", "researched_at_commit", "workstreams", "github_root",
    "label_projection", "feature_boundary", "external_gates", "requirements",
    "design_evidence", "decisions", "tickets", "epic_acceptance",
    "github_reconciliation",
}
BOUNDARY_KEYS = {
    "acceptance_criteria", "critical_path_ticket_ids", "required_documentation",
    "required_cleanup", "end_to_end_proof", "completion_condition",
}
LABEL_KEYS = {"build_order", "workstreams", "phases", "complexities"}


def validate_identity(data: dict[str, Any], report: Report) -> None:
    strict_object(data, "top level", TOP_KEYS, report)
    if not strict_int(data.get("schema_version")) or data.get("schema_version") != 1:
        report.error("schema_version must be integer 1")
    build_order_id = data.get("build_order_id")
    if not nonempty_string(build_order_id):
        report.error("build_order_id must be a non-empty string")
    prefix = data.get("ticket_prefix")
    if (
        not isinstance(prefix, str)
        or not prefix.isalnum()
        or not prefix.isupper()
        or not prefix[0].isalpha()
    ):
        report.error("ticket_prefix must contain only uppercase letters and digits")
    version = data.get("plan_version")
    if not strict_int(version) or version < 1:
        report.error("plan_version must be a positive integer")
    if not isinstance(data.get("repository"), str) or not REPOSITORY.fullmatch(data["repository"]):
        report.error("repository must be owner/repo")
    elif isinstance(build_order_id, str):
        expected_prefix = f"{data['repository']}:"
        suffix = build_order_id.removeprefix(expected_prefix)
        if not build_order_id.startswith(expected_prefix) or not SLUG.fullmatch(suffix):
            report.error("build_order_id must be repository:feature-slug")
    sha = data.get("researched_at_commit")
    if not isinstance(sha, str) or not SHA.fullmatch(sha):
        report.error("researched_at_commit must be a 40-character Git SHA")


def validate_workstreams(data: dict[str, Any], report: Report) -> set[str]:
    records = data.get("workstreams")
    if not isinstance(records, list) or not records:
        report.error("workstreams must be a non-empty array")
        return set()
    found: set[str] = set()
    for index, value in enumerate(records):
        label = f"workstreams[{index}]"
        record = strict_object(value, label, {"id", "title"}, report)
        if record is None:
            continue
        workstream_id = record.get("id")
        if not isinstance(workstream_id, str) or not SLUG.fullmatch(workstream_id):
            report.error(f"{label}.id must be a lowercase slug")
        elif workstream_id in found:
            report.error(f"duplicate workstream id {workstream_id}")
        else:
            found.add(workstream_id)
        if not nonempty_string(record.get("title")):
            report.error(f"{label}.title must be a non-empty string")
    return found


def validate_boundary(data: dict[str, Any], report: Report) -> list[str]:
    boundary = strict_object(data.get("feature_boundary"), "feature_boundary", BOUNDARY_KEYS, report)
    if boundary is None:
        return []
    critical_path: list[str] = []
    for key in BOUNDARY_KEYS - {"completion_condition"}:
        required = key in {"acceptance_criteria", "critical_path_ticket_ids", "end_to_end_proof"}
        values = checked_string_list(
            boundary.get(key), f"feature_boundary.{key}", report, require_items=required
        )
        if key == "critical_path_ticket_ids":
            critical_path = values
    if not nonempty_string(boundary.get("completion_condition")):
        report.error("feature_boundary.completion_condition must be a non-empty string")
    return critical_path


def validate_label_projection(data: dict[str, Any], report: Report) -> dict[str, Any]:
    projection = strict_object(data.get("label_projection"), "label_projection", LABEL_KEYS, report)
    if projection is None:
        return {}
    if not nonempty_string(projection.get("build_order")):
        report.error("label_projection.build_order must be a non-empty string")
    for key in ("workstreams", "phases", "complexities"):
        mapping = projection.get(key)
        if not isinstance(mapping, dict):
            report.error(f"label_projection.{key} must be an object")
            continue
        for map_key, value in mapping.items():
            if not nonempty_string(map_key) or not nonempty_string(value):
                report.error(f"label_projection.{key} keys and values must be non-empty strings")
        labels = [value for value in mapping.values() if nonempty_string(value)]
        if len(labels) != len(set(labels)):
            report.error(f"label_projection.{key} contains duplicate labels")
    return projection


def validate_external_gates(data: dict[str, Any], report: Report) -> set[str]:
    records = data.get("external_gates")
    if not isinstance(records, list):
        report.error("external_gates must be an array")
        return set()
    found: set[str] = set()
    keys = {"id", "title", "owner", "resolution_criteria"}
    for index, value in enumerate(records):
        label = f"external_gates[{index}]"
        gate = strict_object(value, label, keys, report)
        if gate is None:
            continue
        gate_id = gate.get("id")
        if not isinstance(gate_id, str) or not GATE_ID.fullmatch(gate_id):
            report.error(f"{label}.id must look like GATE-001")
        elif gate_id in found:
            report.error(f"duplicate external gate id {gate_id}")
        else:
            found.add(gate_id)
        for key in keys - {"id"}:
            if not nonempty_string(gate.get(key)):
                report.error(f"{label}.{key} must be a non-empty string")
    return found


def validate_requirements(data: dict[str, Any], report: Report) -> dict[str, dict[str, Any]]:
    values = data.get("requirements")
    if not isinstance(values, list) or not values:
        report.error("requirements must be a non-empty array")
        return {}
    found: dict[str, dict[str, Any]] = {}
    keys = {"id", "summary", "disposition", "ticket_ids", "reason"}
    for index, value in enumerate(values):
        label = f"requirements[{index}]"
        requirement = strict_object(value, label, keys, report)
        if requirement is None:
            continue
        req_id = requirement.get("id")
        if not isinstance(req_id, str) or not REQ_ID.fullmatch(req_id):
            report.error(f"{label}.id must be a full stable requirement ID")
            continue
        if req_id in found:
            report.error(f"duplicate requirement id {req_id}")
        else:
            found[req_id] = requirement
        if not nonempty_string(requirement.get("summary")):
            report.error(f"{req_id}.summary must be a non-empty string")
        disposition = requirement.get("disposition")
        if not isinstance(disposition, str) or disposition not in DISPOSITIONS:
            report.error(f"{req_id}: invalid disposition {disposition!r}")
        ticket_ids = checked_string_list(requirement.get("ticket_ids"), f"{req_id}.ticket_ids", report)
        reason = requirement.get("reason")
        if disposition == "ticket":
            if not ticket_ids:
                report.error(f"{req_id}: ticket disposition requires ticket_ids")
            if reason is not None:
                report.error(f"{req_id}: ticket disposition requires null reason")
        elif isinstance(disposition, str) and disposition in {"deferred", "rejected", "satisfied"}:
            if ticket_ids:
                report.error(f"{req_id}: {disposition} disposition cannot have ticket_ids")
            if not nonempty_string(reason):
                report.error(f"{req_id}: {disposition} disposition requires reason")
    return found
