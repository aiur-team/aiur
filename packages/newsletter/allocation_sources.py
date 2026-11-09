"""Read local evidence sources for the newsletter's per-machine allocation.

Kept together above 200 lines: the three readers share source-coverage validation.
"""
from datetime import datetime, timedelta, timezone

from local_sources import iso
from telemetry_sources import read_records

MAX_SUPPLY_GAP = timedelta(minutes=10)


def _unavailable(reason):
    return {"state": "unavailable", "complete": False, "window_start": None,
            "window_end": None, "records": None, "reason": reason}


def unavailable_evidence(reason):
    return {machine: {section: _unavailable(reason) for section in ("turns", "intake", "feature_supply")}
            for machine in ("pc", "nuc")}


def _evidence_block(records, start, end, complete, reason=None):
    return {"state": "available" if complete else "unavailable", "complete": complete,
            "window_start": iso(start) if complete else None, "window_end": iso(end) if complete else None,
            "records": records if complete else None, **({"reason": reason} if reason else {})}


def _timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def telemetry_issue_numbers(rows, since):
    """Return ticket IDs with implement boundaries in the metric window."""
    numbers = set()
    for row in rows:
        attrs = row.get("attributes", {})
        if row.get("kind") != "lifecycle" or attrs.get("event") != "implement":
            continue
        if _timestamp(row["timestamp"]) >= since and str(attrs.get("ticket", "")).isdigit():
            numbers.add(int(attrs["ticket"]))
    return numbers


def collect_allocation_evidence(state_dir, now, current_issues, github, instances=(), telemetry_root=None):
    """Join telemetry ticket IDs to GitHub labels, then build the metric input."""
    rows = read_records(state_dir, telemetry_root, now)
    # Include the full summary lookback so open turns that began just outside
    # the metric window can still be clipped and labeled at its boundary.
    numbers = telemetry_issue_numbers(rows, now - timedelta(days=8))
    missing = numbers - set(current_issues)
    nodes = {**current_issues, **(github.issues(missing) if missing else {})}
    issues = {number: {"labels": [label["name"] for label in node["labels"]["nodes"]],
                       "title": node["title"]} for number, node in nodes.items()}
    return allocation_evidence(state_dir, now, issues, instances, telemetry_root, rows)


def _events(rows):
    events, supplies, run_boundaries, coverage_start, latest = [], [], [], None, None
    for row in rows:
        attrs = row.get("attributes", {})
        at = _timestamp(row["timestamp"])
        latest = at if latest is None else max(latest, at)
        if row.get("kind") in ("run_context", "restart"):
            coverage_start = at if coverage_start is None else min(coverage_start, at)
            run_boundaries.append((row.get("boot_id"), row["kind"], at))
        if row.get("kind") == "lifecycle" and attrs.get("event") == "implement":
            attrs = {**attrs, "_boot_id": row.get("boot_id") or "unknown"}
            events.append((attrs, at))
        if row.get("kind") == "feature_supply":
            supplies.append((attrs, at))
    events.sort(key=lambda item: item[1])
    supplies.sort(key=lambda item: item[1])
    deduplicated, seen_boundaries = [], {}
    for attrs, at in events:
        event_key = (attrs.get("_boot_id"), attrs.get("attempt_id"), attrs.get("operation_id"),
                    attrs.get("ticket"), attrs.get("boundary"))
        previous = seen_boundaries.get(event_key)
        if previous is not None and at - previous <= timedelta(milliseconds=1):
            continue
        seen_boundaries[event_key] = at
        deduplicated.append((attrs, at))
    return deduplicated, supplies, run_boundaries, coverage_start, latest


def _turn_records(events, run_boundaries, issues, window_start, now):
    starts, closed_operations, records, complete = {}, set(), [], True
    timeline = [(at, 0, boot_id, kind, None) for boot_id, kind, at in run_boundaries]
    timeline.extend((at, 1, None, "lifecycle", attrs) for attrs, at in events)
    timeline.sort(key=lambda row: (row[0], row[1]))

    def close(key, attrs, start, end):
        nonlocal complete
        if end <= start or end < window_start or start > now:
            return
        clipped_start = max(start, window_start)
        if end <= clipped_start:
            return
        number = int(attrs["ticket"])
        issue = issues.get(number)
        if issue is None:
            complete = False
            return
        record = _turn_record(key, number, clipped_start, end, issue)
        if record is not None:
            records.append(record)

    for at, _order, boot_id, kind, attrs in timeline:
        if attrs is None:
            for key, (opened, start) in list(starts.items()):
                opened_boot = key[0]
                closes_boot = kind == "restart"
                closes_previous_run = kind == "run_context" and opened_boot != boot_id
                if at > start and (closes_boot or closes_previous_run):
                    close(key, opened, start, at)
                    closed_operations.add((key[1], key[2], opened.get("ticket")))
                    starts.pop(key)
            continue
        in_window = at >= window_start
        key = (attrs.get("_boot_id"), attrs.get("attempt_id"), attrs.get("operation_id"))
        if not key[0] or not attrs.get("ticket"):
            complete = complete and not in_window
            continue
        if attrs.get("boundary") == "start":
            starts[key] = (attrs, at)
        elif attrs.get("boundary") == "end" and key in starts:
            began, start = starts.pop(key)
            complete = complete and (str(attrs.get("ticket")) == str(began.get("ticket")) or not in_window)
            close(key, began, start, at)
        elif attrs.get("boundary") == "end":
            operation = (attrs.get("attempt_id"), attrs.get("operation_id"), attrs.get("ticket"))
            complete = complete and (not in_window or operation in closed_operations)
    active = 0
    for key, (attrs, start) in starts.items():
        number_value = attrs.get("ticket")
        if not number_value or start > now:
            continue
        close(key, attrs, start, now)
        if now > start:
            active += 1
    return records, complete, active


def _turn_record(key, number, start, end, issue):
    started_at, ended_at = iso(start), iso(end)
    if ended_at <= started_at:
        return None
    return {"attempt_id": ":".join(str(part) for part in (*key, started_at)), "number": number,
            "phase": "implement", "started_at": started_at, "ended_at": ended_at,
            "labels": issue["labels"], "title": issue["title"]}


def _supply_records(rows, now):
    result = []
    now_ms = int(now.timestamp() * 1000)
    for attrs, _at in rows:
        start, end = attrs.get("interval_start_ms", 0), attrs.get("interval_end_ms", 0)
        if attrs.get("event") != "interval" or start >= now_ms or end <= start:
            continue
        clipped = min(end, now_ms)
        values = dict(attrs)
        if clipped < end:
            ratio = (clipped - start) / (end - start)
            for name in ("feature_starved_slot_minutes", "non_feature_during_starvation_minutes", "observed_minutes"):
                if isinstance(values.get(name), (int, float)):
                    values[name] *= ratio
            values["interval_end_ms"] = clipped
        result.append({"event_id": attrs.get("event_key") or f"{start}:{end}",
                       "kind": "feature_supply", "attributes": values})
    return result


def _supply_observation(records, start, end):
    lower, upper = int(start.timestamp() * 1000), int(end.timestamp() * 1000)
    observed = 0.0
    for row in records:
        attrs = row["attributes"]
        interval_start, interval_end = attrs["interval_start_ms"], attrs["interval_end_ms"]
        duration = interval_end - interval_start
        overlap = max(0, min(interval_end, upper) - max(interval_start, lower))
        if overlap and duration > 0:
            observed += float(attrs.get("observed_minutes") or 0) * overlap / duration
    return observed, max(0.0, (upper - lower) / 60_000 - observed)


def _supply_max_gap(records, start, end):
    lower, upper = int(start.timestamp() * 1000), int(end.timestamp() * 1000)
    spans = sorted((max(lower, row["attributes"]["interval_start_ms"]),
                    min(upper, row["attributes"]["interval_end_ms"]))
                   for row in records if row["attributes"]["interval_end_ms"] > lower
                   and row["attributes"]["interval_start_ms"] < upper)
    cursor, largest = lower, 0
    for left, right in spans:
        if right <= left:
            continue
        largest = max(largest, left - cursor)
        cursor = max(cursor, right)
    return max(largest, upper - cursor)


def allocation_evidence(state_dir, now, issues, instances=(), telemetry_root=None, telemetry_rows=None):
    """Return strict metric-reader evidence; partial telemetry never becomes zero."""
    pc = {"turns": _unavailable("complete seven-day daemon telemetry unavailable"),
          "intake": _unavailable("first-dispatch intake evidence unavailable"),
          "feature_supply": _unavailable("complete feature-supply interval coverage unavailable")}
    try:
        rows = telemetry_rows if telemetry_rows is not None else read_records(state_dir, telemetry_root, now)
    except OSError as error:
        unavailable = _unavailable(str(error))
        return {"pc": {name: unavailable.copy() for name in pc},
                "nuc": {name: unavailable.copy() for name in pc}}
    events, supply_rows, run_boundaries, coverage_start, latest = _events(rows)
    start7, start1 = now - timedelta(days=7), now - timedelta(days=1)
    fresh = latest is not None and latest >= now - timedelta(minutes=5)
    if coverage_start is not None and fresh:
        for window_start in (start7, start1):
            turns, paired, active = _turn_records(events, run_boundaries, issues, window_start, now)
            relevant = {int(attrs["ticket"]) for attrs, at in events
                        if attrs.get("ticket") and at >= window_start}
            if paired and relevant <= set(issues):
                proven_start = coverage_start if window_start == start7 else max(coverage_start, window_start)
                pc["turns"] = _evidence_block(turns, proven_start, now, True)
                pc["turns"]["active_turns_clipped"] = active
                break
    supply = _supply_records(supply_rows, now)
    start_ms = int(start1.timestamp() * 1000)
    observed_minutes, unobserved_minutes = _supply_observation(supply, start1, now)
    max_gap_ms = _supply_max_gap(supply, start1, now)
    first_supply = min((row["attributes"]["interval_start_ms"] for row in supply), default=0)
    latest_supply = max((row["attributes"]["interval_end_ms"] for row in supply), default=0)
    if (first_supply <= start_ms + 1_000
            and latest_supply >= int((now - timedelta(minutes=5)).timestamp() * 1000)
            and observed_minutes > 0
            and max_gap_ms <= MAX_SUPPLY_GAP.total_seconds() * 1000):
        block_start = min(start1, datetime.fromtimestamp(first_supply / 1000, timezone.utc))
        pc["feature_supply"] = _evidence_block(supply, block_start, now, True)
        pc["feature_supply"]["observed_minutes"] = observed_minutes
        pc["feature_supply"]["unobserved_minutes"] = unobserved_minutes
        pc["feature_supply"]["max_gap_ms"] = max_gap_ms
    unavailable = {name: _unavailable("machine telemetry not reachable")
                   for name in ("turns", "intake", "feature_supply")}
    return {"pc": pc, "nuc": unavailable}
