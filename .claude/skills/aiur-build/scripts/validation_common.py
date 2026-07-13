"""Shared types and defensive helpers for Build Order validation."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any


TICKET_ID = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{3,}[A-Z]?$", re.ASCII)
REQ_ID = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{3,}$", re.ASCII)
DECISION_ID = re.compile(r"^DEC-[0-9]{3,}$", re.ASCII)
DESIGN_ID = re.compile(r"^DESIGN-[0-9]{3,}$", re.ASCII)
GATE_ID = re.compile(r"^GATE-[0-9]{3,}$", re.ASCII)
SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$", re.ASCII)
REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$", re.ASCII)
SHA = re.compile(r"^[0-9a-fA-F]{40}$", re.ASCII)
KINDS = {"executable", "audit", "gate", "umbrella", "capstone"}
RUNNABLE_KINDS = {"executable", "audit", "gate", "capstone"}
PROVENANCE = {"planned", "discovered"}
DISPOSITIONS = {"ticket", "deferred", "rejected", "satisfied"}
EDGE_FIELDS = ("depends_on", "serializes_with", "suggested_after")
SURFACE_FIELDS = ("write_surfaces", "contract_surfaces", "safety_surfaces")


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def strict_int(value: object) -> bool:
    return type(value) is int


def strict_object(
    value: object, label: str, required: set[str], report: Report
) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        report.error(f"{label} must be an object")
        return None
    keys = set(value)
    for key in sorted(required - keys):
        report.error(f"{label}: missing required key {key}")
    for key in sorted(keys - required):
        report.error(f"{label}: unknown key {key}")
    return value


def checked_string_list(
    value: object,
    label: str,
    report: Report,
    *,
    require_items: bool = False,
) -> list[str]:
    if not isinstance(value, list):
        report.error(f"{label} must be an array of strings")
        return []
    result: list[str] = []
    for index, item in enumerate(value):
        if nonempty_string(item):
            result.append(item)
        else:
            report.error(f"{label}[{index}] must be a non-empty string")
    if require_items and not result:
        report.error(f"{label} must not be empty")
    seen: set[str] = set()
    for item in result:
        if item in seen:
            report.error(f"{label} contains duplicate value {item}")
        seen.add(item)
    return result


def normalize_surfaces(record: dict[str, Any]) -> dict[str, str]:
    surfaces: dict[str, str] = {}
    for field_name in SURFACE_FIELDS:
        values = record.get(field_name)
        if not isinstance(values, list):
            continue
        for value in values:
            if nonempty_string(value):
                surfaces[value.strip().casefold()] = value.strip()
    return surfaces


def safe_list(record: dict[str, Any], field_name: str) -> list[Any]:
    value = record.get(field_name)
    return value if isinstance(value, list) else []
