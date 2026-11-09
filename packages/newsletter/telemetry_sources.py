"""Read current telemetry plus recent durable per-boot summaries."""
import json
from datetime import timedelta


_KINDS = {"feature_supply", "lifecycle", "restart", "run_context"}
_SUMMARY_LOOKBACK_DAYS = 8


def _raw_paths(state_dir, telemetry_root):
    roots = [telemetry_root, state_dir / "logs"]
    return sorted({path for root in roots if root.is_dir()
                   for path in root.glob("**/telemetry.ndjson*") if path.is_file()})


def _summary_paths(state_dir, now):
    cutoff = now.timestamp() - timedelta(days=_SUMMARY_LOOKBACK_DAYS).total_seconds()
    root = state_dir / "analytics" / "runs"
    if not root.is_dir():
        return []
    return sorted(path for path in root.glob("*/run-summary.json")
                  if path.is_file() and path.stat().st_mtime >= cutoff)


def _summary_records(path, lower, now):
    """Stream only evidence rows from the pretty-printed records array."""
    in_records, in_record, kind, lines = False, False, None, []
    with path.open("rb") as stream:
        for line in stream:
            if not in_records:
                if line.strip() == b'"records": [':
                    in_records = True
                continue
            if not in_record:
                if line.startswith(b"  ]"):
                    return
                if line.startswith(b"    {"):
                    in_record, kind, lines = True, None, [line]
                continue
            if kind is None or kind in _KINDS:
                lines.append(line)
            if kind is None and line.startswith(b'      "kind":'):
                kind = json.loads(line.split(b":", 1)[1].strip().rstrip(b","))
                if kind not in _KINDS:
                    lines = []
            if kind in _KINDS and line.startswith(b'      "timestamp":'):
                stamp = json.loads(line.split(b":", 1)[1].strip().rstrip(b","))
                at = _timestamp(stamp)
                if at < lower or at > now:
                    kind, lines = "ignore", []
            if line.startswith(b"    },") or line == b"    }\n":
                if kind in _KINDS:
                    payload = b"".join(lines).rstrip()
                    if payload.endswith(b","):
                        payload = payload[:-1]
                    yield json.loads(payload)
                in_record, kind, lines = False, None, []


def _raw_records(path):
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("kind") in _KINDS:
                yield row


def read_records(state_dir, telemetry_root, now):
    """Return deduplicated evidence rows up to `now`, or raise if unreadable."""
    raw = _raw_paths(state_dir, telemetry_root or state_dir / "logs")
    summaries = _summary_paths(state_dir, now)
    if not raw and not summaries:
        raise OSError("daemon telemetry and recent run summaries absent")

    rows, seen = [], set()
    lower = now - timedelta(days=_SUMMARY_LOOKBACK_DAYS)
    sources = [(_raw_records, path) for path in raw]
    sources.extend((lambda path, lower=lower: _summary_records(path, lower, now), path)
                   for path in summaries)
    for reader, path in sources:
        for row in reader(path):
            record_id = row.get("record_id")
            identity = record_id or json.dumps(row, sort_keys=True, separators=(",", ":"))
            if identity in seen:
                continue
            seen.add(identity)
            stamp = row.get("timestamp")
            if stamp:
                at = _timestamp(stamp)
                if lower <= at <= now:
                    rows.append(row)
    return rows


def _timestamp(value):
    from datetime import datetime, timezone

    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
