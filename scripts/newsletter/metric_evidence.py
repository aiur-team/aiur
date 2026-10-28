"""Deployment, verification and action evidence; never infer causality from timing."""
from collections import Counter

from local_sources import parse_time
from metric_values import UNAVAILABLE, available, metric, unique, window
from metric_program import completed, tickets


def live(snapshot, merge):
    sha = merge.get("merge_sha")
    builds = [b for key, b in snapshot.get("running_build", {}).items()
              if b.get("sha") and available(snapshot, "running_build_" + key)]
    if not sha or not builds:
        return UNAVAILABLE
    if any(sha == b["sha"] or sha in b.get("ancestor_shas", []) for b in builds):
        return True
    # Complete ancestry is needed to prove a negative, not a chronological guess.
    return False if all("ancestor_shas" in b for b in builds) else UNAVAILABLE


def live_count(snapshot, rows):
    if rows is None:
        return UNAVAILABLE
    states = [live(snapshot, row) for row in rows]
    builds = snapshot.get("running_build", {})
    if not any(b.get("sha") and available(snapshot, "running_build_" + k) for k, b in builds.items()):
        return UNAVAILABLE
    return UNAVAILABLE if UNAVAILABLE in states else sum(states)


def verified(snapshot):
    fields = ("program.tickets", "features[].members", "merges[].closing_issue", "merges[].merge_sha",
              "running_build", "verification[].feature", "verification[].verified_at", "sources.verification")
    features, records, members = snapshot.get("features"), snapshot.get("verification"), tickets(snapshot)
    merges = unique(snapshot.get("merges"))
    if features is None or records is None or members is None or merges is None or not available(snapshot, "verification") or not available(snapshot, "github_merges"):
        return metric(UNAVAILABLE, *fields)
    verified_ids = {r["feature"] for r in records if r.get("executor") and r.get("verified_at")
                    and parse_time(r["verified_at"]) <= parse_time(snapshot["captured_at"])}
    states = []
    for feature in features:
        ids = set(feature["members"])
        if not ids or not all(n in members and completed(members[n]) for n in ids):
            continue
        # A 48-hour merge list alone cannot prove all historical member merges are live.
        if not feature.get("merges_complete", False):
            return metric(UNAVAILABLE, *fields, "features[].merges_complete")
        related = [r for r in merges.values() if r.get("closing_issue") in ids]
        if not ids <= {r.get("closing_issue") for r in related}:
            return metric(UNAVAILABLE, *fields)
        statuses = [live(snapshot, r) for r in related]
        if UNAVAILABLE in statuses:
            return metric(UNAVAILABLE, *fields)
        states.append(all(statuses) and feature["id"] in verified_ids)
    return metric(sum(states), *fields, "features[].merges_complete", "verification[].executor")


def action_result(action, measures, snapshot):
    linked = [m for m in measures if action.get("id") and m.get("action_id") == action["id"]
              and parse_time(action["at"]) < parse_time(m["at"]) <= parse_time(snapshot["window_end"])]
    return {"action": action, "result": linked or "impact not measured",
            "sources": ["executor_actions[]", "measures[]"]}


def evidence(snapshot):
    raw = snapshot.get("meta") if available(snapshot, "meta") else None
    logs = [r for r in raw if window(snapshot, r["timestamp"])] if raw is not None else None
    raw_actions = snapshot.get("executor_actions") if available(snapshot, "executor_actions") else None
    actions = [r for r in raw_actions if window(snapshot, r["at"]) and r.get("outcome") == "action"] if raw_actions is not None else None
    measures = snapshot.get("measures") or []
    themes = Counter((r.get("theme") or r.get("bottleneck")) for r in logs or [] if r.get("theme") or r.get("bottleneck"))
    newest = max((r["timestamp"] for r in raw or [] if parse_time(r["timestamp"]) <= parse_time(snapshot["window_end"])),
                 key=parse_time, default=snapshot.get("meta_latest_at", UNAVAILABLE))
    bottlenecks = []
    for row in logs or []:
        if not row.get("bottleneck"):
            continue
        linked = [a for a in actions or [] if row.get("id") and a.get("bottleneck_id") == row["id"]
                  and parse_time(a["at"]) >= parse_time(row["timestamp"])]
        bottlenecks.append({"bottleneck": row["bottleneck"], "timestamp": row["timestamp"],
                            "actions": UNAVAILABLE if actions is None else
                            [action_result(a, measures, snapshot) for a in linked] or "no action recorded"})
    return {"bottlenecks": bottlenecks if logs is not None else UNAVAILABLE,
            "actions": [action_result(a, measures, snapshot) for a in actions] if actions is not None else UNAVAILABLE,
            "meta_patterns": {"logs": metric(len(logs) if logs is not None else UNAVAILABLE, "meta[].timestamp", "sources.meta"),
                              "themes": {theme: metric(count, "meta[].theme", "meta[].bottleneck", "meta[].timestamp")
                                         for theme, count in themes.items()},
                              "status": "unavailable" if logs is None else "logs in window" if logs else "no logs in window",
                              "newest_log_at": newest}}
