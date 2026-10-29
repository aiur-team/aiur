"""Read local evidence sources for the newsletter's per-machine allocation."""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from local_sources import iso


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


def _read_ndjson(path):
    rows = []
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def _timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _telemetry(state_dir, telemetry_root):
    candidates = [telemetry_root, state_dir / "logs"]
    paths = sorted({path for root in candidates if root.is_dir()
                    for path in root.glob("**/telemetry.ndjson*") if path.is_file()})
    if not paths:
        raise OSError("daemon telemetry files absent")
    return paths


def telemetry_issue_numbers(state_dir, telemetry_root, since):
    """Return distinct issue numbers with implement boundaries in the metric window."""
    numbers = set()
    for path in _telemetry(state_dir, telemetry_root or state_dir / "logs"):
        for row in _read_ndjson(path):
            attrs = row.get("attributes", {})
            if row.get("kind") != "lifecycle" or attrs.get("event") != "implement":
                continue
            if _timestamp(row["timestamp"]) >= since and str(attrs.get("ticket", "")).isdigit():
                numbers.add(int(attrs["ticket"]))
    return numbers


def hydrate_telemetry_issues(state_dir, telemetry_root, since, current_issues, github):
    """Add labels/titles for telemetry tickets outside the normal program query."""
    numbers = telemetry_issue_numbers(state_dir, telemetry_root, since)
    missing = numbers - set(current_issues)
    return {**current_issues, **(github.issues(missing) if missing else {})}


def collect_allocation_evidence(state_dir, now, current_issues, github, instances=(), telemetry_root=None):
    """Join telemetry ticket IDs to GitHub labels, then build the metric input."""
    nodes = hydrate_telemetry_issues(state_dir, telemetry_root, now - timedelta(days=7), current_issues, github)
    issues = {number: {"labels": [label["name"] for label in node["labels"]["nodes"]],
                       "title": node["title"]} for number, node in nodes.items()}
    return allocation_evidence(state_dir, now, issues, instances, telemetry_root)


def _events(paths):
    events, supplies, earliest, latest, first_lifecycle, last_lifecycle = [], [], None, None, None, None
    for path in paths:
        for row in _read_ndjson(path):
            attrs = row.get("attributes", {})
            stamp = row.get("timestamp")
            if not stamp:
                continue
            at = _timestamp(stamp)
            earliest = at if earliest is None else min(earliest, at)
            latest = at if latest is None else max(latest, at)
            if row.get("kind") == "lifecycle" and attrs.get("event") == "implement":
                events.append((attrs, at))
            if row.get("kind") == "lifecycle":
                first_lifecycle = at if first_lifecycle is None else min(first_lifecycle, at)
                last_lifecycle = at if last_lifecycle is None else max(last_lifecycle, at)
            if row.get("kind") == "feature_supply":
                supplies.append((attrs, at))
    return events, supplies, earliest, latest, first_lifecycle, last_lifecycle


def _turn_records(events, issues, window_start):
    starts, records, complete = {}, [], True
    for attrs, at in events:
        in_window = at >= window_start
        key = (attrs.get("attempt_id"), attrs.get("operation_id"))
        if not key[0] or not attrs.get("ticket"):
            complete = complete and not in_window
            continue
        if attrs.get("boundary") == "start":
            complete = complete and (key not in starts or not in_window)
            starts[key] = (attrs, at)
        elif attrs.get("boundary") == "end" and key in starts:
            began, start = starts.pop(key)
            number = int(attrs.get("ticket"))
            complete = complete and (str(number) == str(began.get("ticket")) or not in_window)
            if at < window_start:
                continue
            issue = issues.get(number)
            if issue is None:
                complete = complete and not in_window
                continue
            records.append({"attempt_id": key[0] + ":" + str(key[1]), "number": number,
                            "phase": "implement", "started_at": iso(start), "ended_at": iso(at),
                            "labels": issue["labels"], "title": issue["title"]})
        elif attrs.get("boundary") == "end":
            complete = complete and not in_window
    return records, complete and not any(start >= window_start for _, start in starts.values())


def _supply_records(rows):
    result = []
    for attrs, _at in rows:
        if attrs.get("event") != "interval" or attrs.get("interval_end_ms", 0) <= attrs.get("interval_start_ms", 0):
            continue
        result.append({"event_id": attrs.get("event_key") or f"{attrs['interval_start_ms']}:{attrs['interval_end_ms']}",
                       "kind": "feature_supply", "attributes": attrs})
    return result


def _supply_covers(records, start, end):
    lower, upper = int(start.timestamp() * 1000), int(end.timestamp() * 1000)
    spans = sorted((max(lower, row["attributes"]["interval_start_ms"]),
                    min(upper, row["attributes"]["interval_end_ms"])) for row in records)
    cursor = lower
    for left, right in spans:
        if right <= left:
            continue
        if left > cursor:
            return False
        cursor = max(cursor, right)
    return cursor >= upper


def allocation_evidence(state_dir, now, issues, instances=(), telemetry_root=None):
    """Return strict metric-reader evidence; partial telemetry never becomes zero."""
    pc = {"turns": _unavailable("complete seven-day daemon telemetry unavailable"),
          "intake": _unavailable("first-dispatch intake evidence unavailable"),
          "feature_supply": _unavailable("complete feature-supply interval coverage unavailable")}
    try:
        paths = _telemetry(state_dir, telemetry_root or state_dir / "logs")
    except OSError as error:
        unavailable = _unavailable(str(error))
        return {"pc": {name: unavailable.copy() for name in pc},
                "nuc": {name: unavailable.copy() for name in pc}}
    events, supply_rows, earliest, latest, first_lifecycle, last_lifecycle = _events(paths)
    start7, start1 = now - timedelta(days=7), now - timedelta(days=1)
    relevant = {int(attrs["ticket"]) for attrs, at in events if attrs.get("ticket") and at > start7}
    turns, paired = _turn_records(events, issues, start7)
    complete_turns = (first_lifecycle is not None and first_lifecycle <= start7
                      and last_lifecycle is not None and last_lifecycle >= now - timedelta(minutes=5)
                      and bool(turns))
    if complete_turns and paired and relevant <= set(issues):
        pc["turns"] = _evidence_block(turns, start7, now, True)
    supply = _supply_records(supply_rows)
    if earliest is not None and earliest <= start1 and latest is not None and latest >= now - timedelta(minutes=5) and _supply_covers(supply, start1, now):
        pc["feature_supply"] = _evidence_block(supply, start1, now, True)
    unavailable = {name: _unavailable("machine telemetry not reachable")
                   for name in ("turns", "intake", "feature_supply")}
    return {"pc": pc, "nuc": unavailable}
