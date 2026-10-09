import json, sys, csv, collections, re
I = {int(k): v for k, v in json.load(open(sys.argv[1])).items()}
runs = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.strip()]
out = sys.argv[3]
flow = {int(r["ticket"]) for r in csv.DictReader(open(sys.argv[4]))}
deps = {int(r["ticket"]): r for r in csv.DictReader(open(sys.argv[5]))}
def labeled(n, name): return [e for e in n["timelineItems"]["nodes"] if e["__typename"] == "LabeledEvent" and e["label"]["name"] == name]
rows = []
for t in sorted(flow):
    n = I[t]; prs = n["closedByPullRequestsReferences"]["nodes"]
    rows.append({"ticket": t, "dependent": t in deps, "rework_cycles": len(labeled(n, "agent:rework")),
                 "error_events": len(labeled(n, "agent:error")),
                 "prs_closed_unmerged": sum(1 for p in prs if p["state"] == "CLOSED" and not p.get("mergedAt")),
                 "state": n["state"], "state_reason": n.get("stateReason")})
def rate(rs, f): return {"n": len(rs), "count": sum(1 for r in rs if f(r)), "rate": round(sum(1 for r in rs if f(r)) / len(rs), 3) if rs else None}
ci = [r for r in runs if r[1] == "ci" and r[3] in ("success", "failure")]
byday = collections.defaultdict(lambda: [0, 0])
for r in ci:
    byday[r[2][:10]][0] += r[3] == "failure"; byday[r[2][:10]][1] += 1
g = {"rework": {"all_program_tickets": rate(rows, lambda r: r["rework_cycles"] > 0),
                "dependents": rate([r for r in rows if r["dependent"]], lambda r: r["rework_cycles"] > 0)},
     "discard_pr_closed_unmerged": {"all_program_tickets": rate(rows, lambda r: r["prs_closed_unmerged"] > 0),
                "dependents": rate([r for r in rows if r["dependent"]], lambda r: r["prs_closed_unmerged"] > 0)},
     "agent_error": rate(rows, lambda r: r["error_events"] > 0),
     "main_red_ci_push_runs": {"completed_non_cancelled": len(ci), "failures": sum(1 for r in ci if r[3] == "failure"),
                "failure_rate": round(sum(1 for r in ci if r[3] == "failure") / len(ci), 3) if ci else None,
                "by_day_utc": {d: {"failures": v[0], "runs": v[1]} for d, v in sorted(byday.items())},
                "cancelled_excluded": sum(1 for r in runs if r[1] == "ci" and r[3] == "cancelled")}}
json.dump(g, open(out + "/guardrails.json", "w"), indent=2)
with open(out + "/guardrails-per-ticket.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); [w.writerow(r) for r in rows]
print(json.dumps(g, indent=1))
