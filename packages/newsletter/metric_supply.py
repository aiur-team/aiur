"""Window-clipped PR #6936 feature-supply telemetry, kept per machine."""
from datetime import datetime, timezone
from pathlib import Path
import runpy

from metric_values import UNAVAILABLE, metric
from metric_work import MACHINES, coverage, distinct, overlap

METRICS = runpy.run_path(str(Path(__file__).resolve().parents[2] /
                            "analytics/lib/analytics/feature_supply.py"))["METRICS"]


def supply_window(snapshot, machine):
    records, start, end = coverage(snapshot, machine, "feature_supply", 1)
    prefix = f"allocation_evidence.{machine}.feature_supply"
    fields = (prefix + ".state", prefix + ".complete", prefix + ".window_start", prefix + ".window_end",
              prefix + ".records[].event_id", prefix + ".records[].kind",
              prefix + ".records[].attributes.event", prefix + ".records[].attributes.interval_start_ms",
              prefix + ".records[].attributes.interval_end_ms")
    totals = dict.fromkeys(METRICS, 0.0) if records is not None else None
    observed = False
    for row in distinct(records or [], "event_id"):
        attrs = row.get("attributes", {})
        if row.get("kind") != "feature_supply" or attrs.get("event") != "interval":
            continue
        lower = datetime.fromtimestamp(attrs["interval_start_ms"] / 1000, timezone.utc)
        upper = datetime.fromtimestamp(attrs["interval_end_ms"] / 1000, timezone.utc)
        fraction = overlap(lower, upper, start, end) / (upper - lower).total_seconds()
        if not fraction:
            continue
        observed = True
        for name in METRICS:
            if attrs.get(name) is None:
                totals[name] = UNAVAILABLE
            elif totals[name] != UNAVAILABLE:
                totals[name] += attrs[name] * fraction
    return {name: metric(totals[name] if totals is not None and observed else UNAVAILABLE,
                         *fields, prefix + ".records[].attributes." + name) for name in METRICS}


def supply(snapshot):
    return {machine: supply_window(snapshot, machine) for machine in MACHINES}
