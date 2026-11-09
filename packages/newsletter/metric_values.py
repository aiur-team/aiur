"""Small report primitives. Every measured value carries snapshot field paths."""
from datetime import timedelta
from local_sources import parse_time

UNAVAILABLE = "unavailable"


def metric(value, *fields):
    return {"value": UNAVAILABLE if value is None else value, "sources": list(fields)}


def difference(current, previous):
    if current == UNAVAILABLE or previous == UNAVAILABLE:
        return UNAVAILABLE
    return current - previous


def percent(part, total):
    return part / total * 100 if total else UNAVAILABLE


def available(snapshot, source):
    status = snapshot.get("sources", {}).get(source, {}).get("state", "available")
    return status in ("available", "empty")


def unique(rows):
    if rows is None:
        return None
    result = {}
    for row in rows:
        key = row["number"]
        # Conflicting machine observations are not a reliable measurement.
        content = {k: v for k, v in row.items() if k != "machine"}
        if key in result and result[key] != content:
            raise ValueError(f"conflicting observations for number {key}")
        result[key] = content
    return result


def window(snapshot, timestamp, prior=False):
    end = parse_time(snapshot["window_end"])
    start = parse_time(snapshot["window_start"])
    if end - start != timedelta(hours=24):
        raise ValueError("newsletter window must be 24 hours")
    if prior:
        end, start = start, start - timedelta(hours=24)
    return start < parse_time(timestamp) <= end
