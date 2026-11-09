"""New non-feature issues filed straight to todo, from first-dispatch evidence."""
from classification import classify
from local_sources import parse_time
from metric_values import UNAVAILABLE, metric, percent
from metric_work import MACHINES, coverage, distinct

SOURCES = ("flake_recorder", "agent", "executor", "unknown")


def intake_window(snapshot, machine):
    records, start, end = coverage(snapshot, machine, "intake", 1)
    prefix = f"allocation_evidence.{machine}.intake"
    fields = (prefix + ".state", prefix + ".complete", prefix + ".window_start", prefix + ".window_end",
              prefix + ".records[].number", prefix + ".records[].created_at",
              prefix + ".records[].first_dispatch_state", prefix + ".records[].labels",
              prefix + ".records[].title", prefix + ".records[].source")
    counts, total = None, UNAVAILABLE
    if records is not None:
        rows = [r for r in distinct(records, "number") if start < parse_time(r["created_at"]) <= end
                and r["first_dispatch_state"] == "todo"]
        counts = dict.fromkeys(SOURCES, 0)
        total = len(rows)
        for row in rows:
            if classify(row["labels"], row.get("title", "")) != "feature":
                counts[row.get("source") if row.get("source") in SOURCES else "unknown"] += 1
    count = sum(counts.values()) if counts is not None else UNAVAILABLE
    return {"non_feature": metric(count, *fields), "all_direct_to_todo": metric(total, *fields),
            "non_feature_percent": metric(percent(count, total) if counts is not None else UNAVAILABLE, *fields),
            "by_source": {source: metric(counts[source] if counts is not None else UNAVAILABLE, *fields)
                          for source in SOURCES}}


def intake(snapshot):
    return {machine: intake_window(snapshot, machine) for machine in MACHINES}
