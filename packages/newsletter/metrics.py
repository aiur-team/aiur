"""Pure newsletter report: compute(today, yesterday_or_none) returns JSON-safe data.

See metrics-contract.md for evidence extensions and the value/sources report contract.
"""
from datetime import timedelta
from classification import classify

from metric_values import UNAVAILABLE, available, difference, metric, percent, unique, window
from metric_program import program
from metric_evidence import evidence, live_count, verified
from local_sources import parse_time
from metric_work import headline
from metric_intake import intake
from metric_supply import supply

MERGE_FIELDS = ("merges[].number", "merges[].merged_at", "window_start", "window_end")


def merge_window(snapshot, prior=False):
    if snapshot.get("merges") is None or not available(snapshot, "github_merges"):
        return None
    return [r for r in unique(snapshot["merges"]).values() if window(snapshot, r["merged_at"], prior)]


def merge_class(row):
    if row.get("issue_labels") is not None:
        return classify(row["issue_labels"], row.get("issue_title") or "")
    if row.get("closing_issue") is None:
        return classify([], row.get("title", ""))
    return None


def share(rows):
    if rows is None:
        return {k: UNAVAILABLE for k in ("feature", "percent", "mobile_watch_feature", "without_mobile_watch_percent")}
    kinds = [merge_class(row) for row in rows]
    classified = all(kind is not None for kind in kinds)
    mobile_known = all(r.get("mobile") is not None for r in rows)
    features = sum(kind == "feature" for kind in kinds)
    mobile = sum(kind == "feature" and r.get("mobile", False) for r, kind in zip(rows, kinds))
    nonmobile = [kind for r, kind in zip(rows, kinds) if not r.get("mobile")]
    return {"feature": features if classified else UNAVAILABLE,
            "percent": percent(features, len(rows)) if classified else UNAVAILABLE,
            "mobile_watch_feature": mobile if classified and mobile_known else UNAVAILABLE,
            "without_mobile_watch_percent": percent(sum(kind == "feature" for kind in nonmobile), len(nonmobile))
            if classified and mobile_known else UNAVAILABLE}


def merges(snapshot, yesterday):
    now, prior = merge_window(snapshot), merge_window(snapshot, True)
    total = len(now) if now is not None else UNAVAILABLE
    old_total = len(prior) if prior is not None else UNAVAILABLE
    current, previous = share(now), share(prior)
    share_fields = (*MERGE_FIELDS, "merges[].issue_labels", "merges[].issue_title",
                    "merges[].title", "merges[].closing_issue", "merges[].mobile")
    return {"merged": metric(total, *MERGE_FIELDS), "prior_merged": metric(old_total, *MERGE_FIELDS),
            "delta": metric(difference(total, old_total) if yesterday else UNAVAILABLE, *MERGE_FIELDS,
                            "yesterday.captured_at"),
            "live": metric(live_count(snapshot, now), *MERGE_FIELDS, "merges[].merge_sha",
                           "running_build.*.sha", "running_build.*.ancestor_shas"),
            "finished_verified": verified(snapshot),
            "feature_share": {**{k: metric(v, *share_fields) for k, v in current.items()},
                              "prior": {k: metric(v, *share_fields) for k, v in previous.items()},
                              "trend_pp": metric(difference(current["percent"], previous["percent"])
                                                 if yesterday else UNAVAILABLE, *share_fields, "yesterday.captured_at"),
                              "without_mobile_watch_trend_pp": metric(
                                  difference(current["without_mobile_watch_percent"], previous["without_mobile_watch_percent"])
                                  if yesterday else UNAVAILABLE, *share_fields, "yesterday.captured_at")}}


def allocation_values(snapshot):
    if snapshot is None or not available(snapshot, "allocation"):
        return None
    return snapshot.get("allocation", {}).get("units")


def instant_allocation(snapshot, yesterday):
    units, old = allocation_values(snapshot), allocation_values(yesterday)
    running = units.get("running") if units else None
    prior = old.get("running") if old else None
    total = sum(running.values()) if running is not None else UNAVAILABLE
    feature = running.get("feature", UNAVAILABLE) if running is not None else UNAVAILABLE
    ratio = percent(feature, total) if feature != UNAVAILABLE and total != UNAVAILABLE else UNAVAILABLE
    old_ratio = percent(prior["feature"], sum(prior.values())) if prior is not None and "feature" in prior else UNAVAILABLE
    fields = ("allocation.units.running", "sources.allocation")
    hours = snapshot.get("allocation", {}).get("agent_hours") if available(snapshot, "agent_hours") else None
    return {"running_agents": metric(total, *fields),
            "running_by_class": {k: metric(v, *fields) for k, v in running.items()} if running is not None else UNAVAILABLE, "running_feature_agents": metric(feature, *fields),
            "feature_percent": metric(ratio, *fields),
            "trend_pp": metric(difference(ratio, old_ratio), *fields, "yesterday.allocation.units.running"),
            "held_slots": {life: {kind: metric(value, f"allocation.units.{life}.{kind}") for kind, value in classes.items()}
                           for life, classes in units.items() if life != "running"} if units is not None else UNAVAILABLE,
            "agent_hours": {kind: metric(value, f"allocation.agent_hours.{kind}") for kind, value in hours.items()}
            if hours is not None else metric(UNAVAILABLE, "allocation.agent_hours", "sources.agent_hours")}


def allocation(snapshot, yesterday):
    return {"headline": headline(snapshot), "instant_context": instant_allocation(snapshot, yesterday),
            "non_feature_intake": intake(snapshot), "feature_supply": supply(snapshot)}


def compute(today, yesterday_or_none=None):
    """Compute without I/O or wall-clock reads; reject mismatched daily baselines."""
    yesterday = yesterday_or_none
    if yesterday is not None:
        if today["repo"].lower() != yesterday["repo"].lower():
            raise ValueError("snapshots must belong to the same repository")
        if parse_time(today["captured_at"]).date() - parse_time(yesterday["captured_at"]).date() != timedelta(days=1):
            raise ValueError("baseline must be yesterday's snapshot (previous UTC date)")
    return {"repo": today["repo"], "captured_at": today["captured_at"],
            "window_start": today["window_start"], "window_end": today["window_end"],
            "outcomes": merges(today, yesterday), "allocation": allocation(today, yesterday),
            "program": program(today, yesterday), **evidence(today)}
