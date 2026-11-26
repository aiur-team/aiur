"""Daily UTC totals from daemon-observed feature-supply intervals."""
from datetime import datetime, timezone


METRICS = ("feature_starved_slot_minutes", "non_feature_during_starvation_minutes", "observed_minutes")
DAY_MS = 86_400_000


def daily_supply(records: list[dict]) -> list[dict]:
    days = {}
    for record in records:
        if record.get("kind") != "feature_supply":
            continue
        attrs = record.get("attributes", {})
        start, end = attrs.get("interval_start_ms"), attrs.get("interval_end_ms")
        if attrs.get("event") != "interval" or not isinstance(start, (int, float)) or not isinstance(end, (int, float)) or end <= start:
            continue
        cursor = start
        while cursor < end:
            stop = min(end, (cursor // DAY_MS + 1) * DAY_MS)
            day = datetime.fromtimestamp(cursor / 1000, timezone.utc).date().isoformat()
            row = days.setdefault(day, {"date": day, **dict.fromkeys(METRICS, 0.0)})
            for metric in METRICS:
                value = attrs.get(metric)
                if isinstance(value, (int, float)) and value >= 0:
                    row[metric] += value * (stop - cursor) / (end - start)
            cursor = stop
    return [{key: round(value, 4) if isinstance(value, float) else value for key, value in days[day].items()}
            for day in sorted(days)]


def supply_lines(rows: list[dict]) -> list[str]:
    lines = ["", "Feature supply by UTC day (observed intervals):"]
    for row in rows:
        lines.append("  %s: %.2f feature-starved slot-minutes; %.2f non-feature-during-starvation minutes; %.2f observed minutes"
                     % (row["date"], *(row[metric] for metric in METRICS)))
    if not rows:
        lines.append("  unavailable (no feature-supply interval observations)")
    return lines
