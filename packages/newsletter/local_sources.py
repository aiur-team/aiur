"""Local evidence readers; absence and partial reads remain explicit."""
import json
import re
from datetime import datetime, timezone


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def source(state, observed_at=None, reason=None):
    return {"state": state, "observed_at": observed_at, "reason": reason}


def envelope_source(envelope, name, now):
    raw = envelope["sources"][name]
    observed = raw.get("observed_at")
    state = raw.get("state")
    reason = ", ".join(raw.get("reasons", [])) or raw.get("reason")
    if state == "empty":
        state = "available"
    if state == "partial" or raw.get("partial") or raw.get("freshness") == "stale":
        state, reason = "stale", reason or "partial or stale daemon projection"
    if state not in ("available", "stale", "unavailable"):
        state, reason = "unavailable", "unknown daemon source state"
    if state == "available" and (not observed or (now - parse_time(observed)).total_seconds() > 300):
        state, reason = "stale", "daemon observation missing or older than five minutes"
    return source(state, observed, reason)


def feature_share_lines(text):
    lines = []
    in_section = False
    for line in text.splitlines():
        match = re.search(r"feature[_ -](?:work[_ -])?share", line, re.I)
        if line.startswith("#"):
            in_section = bool(match)
        if line.strip() and (match or in_section):
            lines.append(line)
    return lines


def read_meta(root, start, end):
    directory = root / "meta"
    if not directory.is_dir():
        raise RuntimeError("meta log directory absent")
    rows = []
    for path in sorted(directory.glob("*.md")):
        match = re.match(r"(\d{4})-?(\d{2})-?(\d{2})[T_-](\d{2})[:-]?(\d{2})(?:[:-]?(\d{2}))?", path.name)
        if not match:
            raise RuntimeError("meta log has no parseable UTC filename timestamp")
        second = match[6] or "00"
        stamp = f"{match[1]}-{match[2]}-{match[3]}T{match[4]}:{match[5]}:{second}Z"
        if not start <= parse_time(stamp) <= end:
            continue
        text = path.read_text()
        bottleneck = re.search(r"(?im)^#{1,6}\s+(?:\d+[.)]\s*)?Bottleneck[^\n]*\n+(.*?)(?=\n\s*\n|\n#|\Z)", text, re.S)
        if not bottleneck:
            bottleneck = re.search(r"(?im)^.*\bBottleneck\b[^\n]*", text)
        rows.append({"timestamp": stamp,
                     "bottleneck": bottleneck[1].strip() if bottleneck and bottleneck.lastindex else
                     bottleneck[0].strip() if bottleneck else None,
                     "feature_share": feature_share_lines(text)})
    return rows


def read_actions(root, start, end):
    directory = root / "executor"
    paths = sorted(directory.glob("*/history.ndjson"))
    if not paths:
        raise RuntimeError("Executor retrospective histories absent")
    rows = []
    for path in paths:
        for line in path.read_text().splitlines():
            record = json.loads(line)
            if record.get("outcome") in ("action", "no-action") and start <= parse_time(record["at"]) <= end:
                rows.append({key: record.get(key) for key in ("at", "run_id", "outcome", "reason")})
    return rows
