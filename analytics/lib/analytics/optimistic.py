"""Optimistic lifecycle evidence and trigger rollups (head start is not time saved)."""


import re


def ticket_optimistic(events: list[dict], intervals: list[dict]) -> dict:
    starts = [event for event in events if event["event"] == "optimistic_start"]
    if not starts:
        return {}
    reports = [event for event in events if event["event"] == "blocker_integrate"]
    push_events = [event for event in events if event["event"] == "blocker_push"]
    pushes = len(push_events)
    outcomes = [event for event in events if event["event"] == "optimistic_outcome"]
    outcome = outcomes[-1] if outcomes else {}
    parks = [event for event in events if event["event"] == "optimistic_park"]
    status = outcome.get("outcome") or "open"
    reported = {_evidence_key(report, "integration") for report in reports} - {None}
    unknown = sum(_evidence_key(push, "push") not in reported for push in push_events)
    unknown += sum(report.get("outcome") not in ("clean", "conflict") for report in reports)
    return {"optimistic": {
        "start_trigger": starts[0].get("start_trigger") or "unknown",
        "blockers": starts[0].get("blockers") or [],
        "pushes_absorbed": pushes,
        "integrations": {"clean": sum(report.get("outcome") == "clean" for report in reports) if reports else None,
                         "conflict": sum(report.get("outcome") == "conflict" for report in reports) if reports else None,
                         "unknown": unknown if reports or pushes else None},
        "non_ff": sum(report.get("non_ff") is True for report in reports) if reports and not unknown and all(isinstance(report.get("non_ff"), bool) for report in reports) else None,
        "parks": len(parks),
        "resumes": sum(event["event"] == "optimistic_resume" for event in events),
        "outcome": status,
        "head_start_ms": _head_start(outcome) if status in ("merged", "merged_after_redo") else None,
        "waste_ms": _waste(intervals, starts, parks) if status == "discarded" else None,
    }}


def _evidence_key(event: dict, prefix: str):
    source = event.get("source_id")
    if not isinstance(source, str) or not source.startswith(prefix + ":"):
        return None
    blocker, separator, sha = source[len(prefix) + 1:].rpartition(":")
    if separator and blocker == str(event.get("blocker")) and re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        return event.get("attempt_id"), blocker, sha.lower()
    return None


def _head_start(outcome: dict):
    value = outcome.get("head_start_ms")
    return max(value, 0) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _waste(intervals: list[dict], starts: list[dict], parks: list[dict]):
    durations = []
    for interval in intervals:
        if interval["phase"] != "implement":
            continue
        start = next((event for event in starts if event.get("attempt_id") == interval.get("attempt_id")), None)
        if start is None:
            continue
        park = next((event for event in parks if event.get("attempt_id") == interval.get("attempt_id")
                     and event["timestamp_ms"] >= start["timestamp_ms"]), None)
        if park is None:
            continue
        begin = max(interval["start_ms"], start["timestamp_ms"])
        end = min(interval.get("end_ms") or park["timestamp_ms"], park["timestamp_ms"])
        if end >= begin:
            durations.append(end - begin)
    return sum(durations) if durations else None


def optimistic_rollup(summary: dict) -> dict:
    groups = {}
    for ticket in summary.get("tickets", {}).values():
        evidence = ticket.get("optimistic")
        if not evidence:
            continue
        group = groups.setdefault(evidence["start_trigger"], {
            "starts": 0, "merged": 0, "redone": 0, "discarded": 0, "unknown": 0,
            "head_start_ms": 0, "waste_ms": 0, "head_start_unknown": 0, "waste_unknown": 0,
            "integrations": {"clean": 0, "conflict": 0, "unknown": 0},
        })
        _add_evidence(group, evidence)
    for group in groups.values():
        terminal = group["merged"] + group["redone"] + group["discarded"]
        group["discard_rate"] = group["discarded"] / terminal if terminal else None
    return dict(sorted(groups.items()))


def _add_evidence(group: dict, evidence: dict) -> None:
    group["starts"] += 1
    outcome = evidence["outcome"]
    group[{"merged": "merged", "merged_after_redo": "redone", "discarded": "discarded"}.get(outcome, "unknown")] += 1
    for metric in ("head_start_ms", "waste_ms"):
        value = evidence.get(metric)
        if value is not None:
            group[metric] += value
        elif ((metric == "head_start_ms" and outcome in ("merged", "merged_after_redo"))
              or (metric == "waste_ms" and outcome == "discarded")):
            group[metric.removesuffix("_ms") + "_unknown"] += 1
    for kind in ("clean", "conflict", "unknown"):
        value = evidence["integrations"][kind]
        if kind == "unknown" and value is None:
            group["integrations"][kind] = None
        elif value is not None and group["integrations"][kind] is not None:
            group["integrations"][kind] += value


def optimistic_line(summary: dict) -> str | None:
    groups = optimistic_rollup(summary)
    if not groups:
        return None
    totals = {key: sum(group[key] for group in groups.values())
              for key in ("starts", "redone", "discarded", "head_start_ms", "head_start_unknown")}
    line = "Optimistic starts: %d (redone %d, discarded %d; head start %dms)" % (
        totals["starts"], totals["redone"], totals["discarded"], totals["head_start_ms"])
    if totals["head_start_unknown"]:
        line += "; unavailable head start %d" % totals["head_start_unknown"]
    return line


def optimistic_build_lines(summary: dict) -> list[str]:
    groups = optimistic_rollup(summary)
    if not groups:
        return []
    lines = ["", "Optimistic start:"]
    for trigger, group in groups.items():
        lines.append("  %s: starts %d, merged %d, redone %d, discarded %d, unknown %d; head start %dms, waste %dms"
                     % (trigger, group["starts"], group["merged"], group["redone"], group["discarded"],
                        group["unknown"], group["head_start_ms"], group["waste_ms"]))
        rate = group["discard_rate"]
        lines.append("    Discard rate: %s" % ("unavailable" if rate is None else "%.1f%%" % (rate * 100)))
        lines.append("    Integration reports: clean %s, conflict %s, unknown %s; unavailable head start %d, waste %d"
                     % (_count_display(group["integrations"]["clean"]), _count_display(group["integrations"]["conflict"]),
                        _count_display(group["integrations"]["unknown"]), group["head_start_unknown"], group["waste_unknown"]))
    return lines


def _count_display(value):
    return "unknown" if value is None else value
