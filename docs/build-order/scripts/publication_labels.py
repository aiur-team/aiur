"""Apply exact routing-family label policy to observed GitHub labels."""

from __future__ import annotations

from typing import Any


ROUTING_PREFIXES = ("agent:", "model:", "phase:", "complexity:", "build-lane:")
ROUTING_LABELS = {"build-order"}


def routing_subset(labels: set[str]) -> set[str]:
    return {
        item for item in labels
        if item in ROUTING_LABELS or item.startswith(ROUTING_PREFIXES)
    }


def validate_routing_labels(
    labels: set[str], expected: set[str], label: str, report: Any,
) -> None:
    observed = routing_subset(labels)
    missing, unexpected = sorted(expected - observed), sorted(observed - expected)
    if missing:
        report.error(f"{label} routing labels missing: " + ", ".join(missing))
    if unexpected:
        report.error(f"{label} unexpected routing labels: " + ", ".join(unexpected))
