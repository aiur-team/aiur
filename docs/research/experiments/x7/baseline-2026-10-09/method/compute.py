import json, sys, csv, re, statistics, collections
from datetime import datetime, timezone
I = {int(k): v for k, v in json.load(open(sys.argv[1])).items()}
E = json.load(open(sys.argv[2]))["events"]
outdir = sys.argv[3]
WIN = "2026-10-06T00:00:00Z"
CUT = sys.argv[4]  # data cut time
L = {int(k): v for k, v in json.load(open(sys.argv[5])).items()}
HUB = 10
def ts(s): return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
def hrs(a, b):
    if a is None or b is None: return None
    return round((b - a).total_seconds() / 3600.0, 3)
tel_dispatch = collections.defaultdict(list); tel_pr = collections.defaultdict(list)
for e in E:
    if e["event"] == "dispatch": tel_dispatch[e["ticket"]].append(ts(e["timestamp"]))
    elif e["event"] == "pr_opened" and e.get("pr_number"): tel_pr[e["ticket"]].append((ts(e["timestamp"]), e["pr_number"]))
def labels(n): return [l["name"] for l in n["labels"]["nodes"]]
def complexity(n):
    for l in labels(n):
        m = re.match(r"complexity:(\d)", l)
        if m: return int(m.group(1))
    return None
def program(n):
    return any(l.startswith("build-lane:") for l in labels(n)) or n["title"].startswith("MP-")
def lab_times(n, name, kind="LabeledEvent"):
    return sorted(ts(e["createdAt"]) for e in n["timelineItems"]["nodes"] if e["__typename"] == kind and e.get("label", {}).get("name") == name)
def first_start(n):
    t = lab_times(n, "agent:in-progress")
    return t[0] if t else None
def pr_of(n):
    prs = n["closedByPullRequestsReferences"]["nodes"]
    merged = [p for p in prs if p.get("mergedAt")]
    p = max(merged, key=lambda p: p["mergedAt"]) if merged else (max(prs, key=lambda p: p["createdAt"]) if prs else None)
    if not p: return None
    opened = ts(p["createdAt"])
    rfr = [ts(x["createdAt"]) for x in p["timelineItems"]["nodes"] if x["__typename"] == "ReadyForReviewEvent"]
    if rfr: ready, ready_src = min(rfr), "ready_for_review_event"
    elif not p["isDraft"]: ready, ready_src = opened, "created_non_draft"
    else: ready, ready_src = None, "still_draft"
    return {"number": p["number"], "opened": opened, "ready": ready, "ready_src": ready_src,
            "merged": ts(p.get("mergedAt")), "closed": ts(p.get("closedAt")), "n_prs": len(prs), "author": (p.get("author") or {}).get("login")}
def closed_completed(n):
    return ts(n["closedAt"]) if n.get("stateReason") == "COMPLETED" and n["state"] == "CLOSED" else None
def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%SZ") if d else ""
dep_rows, edge_rows, flow_rows = [], [], []
for num, n in sorted(I.items()):
    if not program(n): continue
    st = first_start(n)
    if not st or st < ts(WIN): continue
    pr = pr_of(n)
    tdis = sorted(d for d in tel_dispatch.get(str(num), []) if d >= ts(WIN))
    cx = complexity(n)
    base = {"ticket": num, "complexity": cx if cx is not None else "none", "title": n["title"][:90],
            "start_gh_in_progress": iso(st), "start_telemetry_first_dispatch": iso(tdis[0]) if tdis else "",
            "pr": pr["number"] if pr else "", "pr_opened": iso(pr["opened"]) if pr else "", "pr_ready": iso(pr["ready"]) if pr else "",
            "pr_merged": iso(pr["merged"]) if pr else "", "issue_closed_completed": iso(closed_completed(n)),
            "start_to_pr_open_h": hrs(st, pr["opened"]) if pr else None,
            "pr_open_to_merge_h": hrs(pr["opened"], pr["merged"]) if pr else None,
            "start_to_merge_h": hrs(st, pr["merged"]) if pr else None,
            "n_blockers": len(n["blockedBy"]["nodes"])}
    flow_rows.append(dict(base))
    if not n["blockedBy"]["nodes"]: continue
    bl_merge, bl_close, bl_open, bl_ready, missing = [], [], [], [], []
    for b in n["blockedBy"]["nodes"]:
        bn = I.get(b["number"])
        if not bn: missing.append(b["number"]); continue
        bpr = pr_of(bn)
        bm = bpr["merged"] if bpr and bpr["merged"] else None
        bc = closed_completed(bn)
        edge_rows.append({"dependent": num, "dependent_complexity": base["complexity"], "blocker": b["number"],
            "blocker_complexity": complexity(bn) if complexity(bn) is not None else "none",
            "blocker_pr": bpr["number"] if bpr else "", "blocker_pr_opened": iso(bpr["opened"]) if bpr else "",
            "blocker_pr_ready": iso(bpr["ready"]) if bpr else "", "blocker_pr_ready_source": bpr["ready_src"] if bpr else "",
            "blocker_pr_merged": iso(bm), "blocker_issue_closed_completed": iso(bc),
            "dependent_start": iso(st),
            "blocker_merge_to_dependent_start_h": hrs(bm, st), "blocker_close_to_dependent_start_h": hrs(bc, st),
            "blocker_pr_open_to_dependent_start_h": hrs(bpr["opened"], st) if bpr else None,
            "blocker_pr_open_to_merge_h": hrs(bpr["opened"], bm) if bpr else None})
        if bm: bl_merge.append(bm)
        if bc: bl_close.append(bc)
        if bpr: bl_open.append(bpr["opened"])
        if bpr and bpr["ready"]: bl_ready.append(bpr["ready"])
        if not bpr: missing.append(b["number"])
    nb = len(n["blockedBy"]["nodes"])
    cur = {b["number"] for b in n["blockedBy"]["nodes"]}
    adds = [ts(e["createdAt"]) for e in L.get(num, []) if e["__typename"] == "BlockedByAddedEvent" and e["blockingIssue"]["number"] in cur]
    last_link = max(adds) if adds else None
    late = bool(last_link and last_link > st)
    hub = any(len(I[b]["blocking"]["nodes"]) >= HUB for b in cur if b in I)
    last_merge = max(bl_merge) if len(bl_merge) == nb else None
    last_close = max(bl_close) if len(bl_close) == nb else None
    last_open = max(bl_open) if len(bl_open) == nb else None
    r = dict(base)
    r.update({"blockers": " ".join(str(b["number"]) for b in n["blockedBy"]["nodes"]),
              "last_blocker_pr_opened": iso(last_open), "last_blocker_pr_ready": iso(max(bl_ready)) if len(bl_ready) == nb else "",
              "last_blocker_pr_merged": iso(last_merge), "last_blocker_issue_closed": iso(last_close),
              "blocker_merge_to_dependent_start_h": hrs(last_merge, st),
              "blocker_close_to_dependent_start_h": hrs(last_close, st),
              "blocker_pr_open_to_dependent_start_h": hrs(last_open, st),
              "optimistic_headroom_h": hrs(last_open, last_merge),
              "start_before_last_blocker_merge": bool(last_merge and st < last_merge),
              "last_blocked_by_link_added": iso(last_link), "late_linked": late,
              "gated_by_hub_blocker": hub, "eligible_for_gap": (not late) and bool(last_merge) and st >= last_merge,
              "blocker_data_missing": " ".join(map(str, missing))})
    dep_rows.append(r)
def wcsv(path, rows):
    if not rows: return
    keys = list(rows[0].keys())
    for r in rows:
        for k in r:
            if k not in keys: keys.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys); w.writeheader(); [w.writerow(r) for r in rows]
wcsv(outdir + "/dependents.csv", dep_rows); wcsv(outdir + "/edges.csv", edge_rows); wcsv(outdir + "/program-tickets-flow.csv", flow_rows)
def stat(vals):
    v = sorted(x for x in vals if x is not None)
    if not v: return {"n": 0}
    q = statistics.quantiles(v, n=4, method="inclusive") if len(v) >= 2 else [v[0]] * 3
    return {"n": len(v), "median_h": round(statistics.median(v), 3), "p25_h": round(q[0], 3), "p75_h": round(q[2], 3),
            "iqr_h": round(q[2] - q[0], 3), "mean_h": round(statistics.fmean(v), 3), "min_h": v[0], "max_h": v[-1]}
def strat(rows, metric, filt=lambda r: True):
    out = {"all": stat([r[metric] for r in rows if filt(r)])}
    for c in ("1", "2", "3", "4", "none"):
        out["complexity:" + c] = stat([r[metric] for r in rows if filt(r) and str(r["complexity"]) == c])
    out["hub_gated"] = stat([r[metric] for r in rows if filt(r) and r.get("gated_by_hub_blocker")])
    out["chain_gated"] = stat([r[metric] for r in rows if filt(r) and "gated_by_hub_blocker" in r and not r.get("gated_by_hub_blocker")])
    return out
nonneg = lambda r: r.get("eligible_for_gap")
elig = lambda r: not r.get("late_linked")
summary = {"cut": CUT, "window_start": WIN,
  "population": {"program_tickets_started_in_window": len(flow_rows), "dependents_started_in_window": len(dep_rows), "edges": len(edge_rows),
     "dependents_started_before_last_blocker_merge": sum(1 for r in dep_rows if r["start_before_last_blocker_merge"]),
     "dependents_with_telemetry_dispatch": sum(1 for r in dep_rows if r["start_telemetry_first_dispatch"]),
     "dependents_merged": sum(1 for r in dep_rows if r["pr_merged"]),
     "dependents_late_linked_excluded": sum(1 for r in dep_rows if r["late_linked"]),
     "dependents_eligible_for_gap": sum(1 for r in dep_rows if r["eligible_for_gap"]),
     "dependents_gated_by_hub_blocker": sum(1 for r in dep_rows if r["gated_by_hub_blocker"]),
     "hub_threshold_dependents": HUB},
  "primary": {
     "blocker_merge_to_dependent_start": strat(dep_rows, "blocker_merge_to_dependent_start_h", nonneg),
     "blocker_close_to_dependent_start": strat(dep_rows, "blocker_close_to_dependent_start_h", nonneg),
     "dependent_start_to_merge": strat(dep_rows, "start_to_merge_h", elig)},
  "secondary": {
     "dependent_start_to_pr_open": strat(dep_rows, "start_to_pr_open_h", elig),
     "dependent_pr_open_to_merge": strat(dep_rows, "pr_open_to_merge_h", elig),
     "last_blocker_pr_open_to_dependent_start": strat(dep_rows, "blocker_pr_open_to_dependent_start_h", nonneg),
     "optimistic_headroom_last_blocker_pr_open_to_merge": strat(dep_rows, "optimistic_headroom_h", nonneg)},
  "reference_all_program_tickets": {
     "start_to_pr_open": strat(flow_rows, "start_to_pr_open_h"),
     "pr_open_to_merge": strat(flow_rows, "pr_open_to_merge_h"),
     "start_to_merge": strat(flow_rows, "start_to_merge_h")},
  "edge_level": {"blocker_merge_to_dependent_start": stat([r["blocker_merge_to_dependent_start_h"] for r in edge_rows if r["blocker_merge_to_dependent_start_h"] is not None and r["blocker_merge_to_dependent_start_h"] >= 0]),
     "blocker_pr_open_to_merge_unique_blockers": stat(list({r["blocker"]: r["blocker_pr_open_to_merge_h"] for r in edge_rows}.values()))}}
# telemetry vs GitHub start agreement
diffs = [hrs(ts(r["start_gh_in_progress"]), ts(r["start_telemetry_first_dispatch"])) for r in dep_rows if r["start_telemetry_first_dispatch"]]
summary["population"]["telemetry_minus_github_start_h"] = stat(diffs)
json.dump(summary, open(outdir + "/baseline.json", "w"), indent=2)
print(json.dumps(summary["population"], indent=1))
for k, v in summary["primary"].items(): print(k, v["all"], {c: (v[c].get("n"), v[c].get("median_h")) for c in v if c != "all"})
for k, v in summary["secondary"].items(): print(k, v["all"])
for k, v in summary["reference_all_program_tickets"].items(): print("ref", k, v["all"])
