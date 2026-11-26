"""Validate explicit product-feature groups used during publication."""

from __future__ import annotations

import re
from typing import Any

from validation_common import Report


def validate_product_features(
    data: dict[str, Any], tickets: dict[str, dict[str, Any]], report: Report,
) -> None:
    if "product_features" not in data:
        return
    groups = data["product_features"]
    if not isinstance(groups, list) or not groups:
        report.error("product_features must be a non-empty array")
        return
    slugs: set[str] = set()
    assigned: set[str] = set()
    for index, group in enumerate(groups):
        label = f"product_features[{index}]"
        if not isinstance(group, dict) or set(group) != {"slug", "label", "ticket_ids"}:
            report.error(f"{label} must contain slug, label, and ticket_ids")
            continue
        slug, name, ids = group["slug"], group["label"], group["ticket_ids"]
        if not isinstance(slug, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
            report.error(f"{label}.slug must be lowercase kebab-case")
        elif slug in slugs:
            report.error(f"duplicate product feature slug {slug}")
        else:
            slugs.add(slug)
        if not isinstance(name, str) or not name.strip():
            report.error(f"{label}.label must be non-empty")
        if not isinstance(ids, list) or not ids or any(not isinstance(item, str) for item in ids):
            report.error(f"{label}.ticket_ids must be a non-empty string array")
            continue
        if len(ids) != len(set(ids)):
            report.error(f"{label}.ticket_ids must be unique")
        unknown = set(ids) - set(tickets)
        if unknown:
            report.error(f"{label} has unknown ticket IDs: {', '.join(sorted(unknown))}")
        overlap = assigned.intersection(ids)
        if overlap:
            report.error("each ticket must belong to exactly one product feature")
        assigned.update(ids)
    missing = set(tickets) - assigned
    if missing:
        report.error("product_features must assign every ticket exactly once")
