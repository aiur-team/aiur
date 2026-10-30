"""Per-machine allocation from complete, observed implement-turn intervals."""
from datetime import timedelta

from classification import classify, main_fix
from local_sources import parse_time
from metric_values import UNAVAILABLE, metric, percent

MACHINES = ("pc", "nuc")
TARGET_PERCENT = 95
KINDS = ("feature", "test_ci", "tooling", "other", "main_fix", "unlabelled_product")


def coverage(snapshot, machine, section, days):
    end = parse_time(snapshot["window_end"])
    start = end - timedelta(days=days)
    block = snapshot.get("allocation_evidence", {}).get(machine, {}).get(section)
    if not block or block.get("state") != "available" or block.get("complete") is not True:
        return None, start, end
    if parse_time(block["window_start"]) > start or parse_time(block["window_end"]) < end:
        return None, start, end
    return block.get("records"), start, end


def distinct(records, key):
    result = {}
    for record in records:
        identity = record[key]
        if identity in result and result[identity] != record:
            raise ValueError(f"conflicting {key}: {identity}")
        result[identity] = record
    return list(result.values())


def overlap(start, end, lower, upper):
    if end <= start:
        raise ValueError("observed interval must end after it starts")
    return max(0, (min(end, upper) - max(start, lower)).total_seconds())


def bucket(record):
    kind = classify(record["labels"], record.get("title", ""))
    if kind == "feature":
        return kind
    if main_fix(record["labels"]) or record.get("incident_kind") in ("main-red", "merge-blocking"):
        return "main_fix"
    if record.get("product_directive"):
        return "unlabelled_product"
    return kind


def turn_totals(records, start, end):
    hours = dict.fromkeys(KINDS, 0.0)
    worked, feature_tickets, product_tickets = set(), set(), set()
    for row in distinct(records, "attempt_id"):
        if row["phase"] != "implement":
            continue
        seconds = overlap(parse_time(row["started_at"]), parse_time(row["ended_at"]), start, end)
        if not seconds:
            continue
        kind = bucket(row)
        hours[kind] += seconds / 3600
        worked.add(row["number"])
        if kind == "feature":
            feature_tickets.add(row["number"])
        if kind == "unlabelled_product":
            product_tickets.add(row["number"])
    return hours, worked, feature_tickets, product_tickets


def work_window(snapshot, machine, days):
    records, start, end = coverage(snapshot, machine, "turns", days)
    prefix = f"allocation_evidence.{machine}.turns"
    fields = (prefix + ".state", prefix + ".complete", prefix + ".window_start", prefix + ".window_end",
              prefix + ".records[].attempt_id", prefix + ".records[].number", prefix + ".records[].phase",
              prefix + ".records[].started_at", prefix + ".records[].ended_at", prefix + ".records[].labels",
              prefix + ".records[].title", prefix + ".records[].incident_kind", prefix + ".records[].product_directive")
    hours, worked, feature, product = turn_totals(records, start, end) if records is not None else (None, None, None, None)
    total = sum(hours.values()) if hours is not None else UNAVAILABLE
    feature_hours = hours["feature"] if hours is not None else UNAVAILABLE
    return {"window_start": start.isoformat(), "window_end": end.isoformat(),
            "target_percent": metric(TARGET_PERCENT, "policy.feature_allocation_target_percent"),
            "turn_hours": metric(total, *fields), "feature_turn_hours": metric(feature_hours, *fields),
            "feature_turn_hours_percent": metric(percent(feature_hours, total) if hours is not None else UNAVAILABLE, *fields),
            "tickets_worked": metric(len(worked) if worked is not None else UNAVAILABLE, *fields),
            "feature_tickets_worked": metric(len(feature) if feature is not None else UNAVAILABLE, *fields),
            "feature_tickets_percent": metric(percent(len(feature), len(worked)) if worked is not None else UNAVAILABLE, *fields),
            "main_fix_hours": metric(hours["main_fix"] if hours is not None else UNAVAILABLE, *fields),
            "unlabelled_product_hours": metric(hours["unlabelled_product"] if hours is not None else UNAVAILABLE, *fields),
            "unlabelled_product_tickets": metric(len(product) if product is not None else UNAVAILABLE, *fields),
            "hours_by_class": {kind: metric(hours[kind] if hours is not None else UNAVAILABLE, *fields) for kind in KINDS}}


def headline(snapshot):
    return {machine: {"rolling_7d": work_window(snapshot, machine, 7),
                      "window_24h": work_window(snapshot, machine, 1)} for machine in MACHINES}
