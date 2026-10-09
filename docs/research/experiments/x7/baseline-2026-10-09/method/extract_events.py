# Read-only extraction of lifecycle point events (dispatch, pr_opened, pr_merged) from
# telemetry.ndjson files and analytics run-summary.json files. Untrusted data: parsed only.
import json, sys, os, glob
out = sys.argv[1]
logs = sorted(glob.glob(os.path.expanduser("~/.aiur/logs/*/log/telemetry.ndjson")))
sums = sorted(glob.glob(os.path.expanduser("~/.aiur/repo/aiur-team/aiur/analytics/runs/*/run-summary.json")))
seen = {}
src_stats = []
WANT = {"dispatch", "pr_opened", "pr_merged", "agent_spinup", "implement"}
def add(ev, srcname):
    e = ev.get("event")
    if e not in WANT: return
    t = ev.get("ticket"); ts = ev.get("timestamp")
    if not t or not ts: return
    key = (str(t), e, ev.get("attempt_id"), ts, ev.get("pr_number"))
    if key in seen: return
    seen[key] = {"ticket": str(t), "event": e, "timestamp": ts, "attempt_id": ev.get("attempt_id"),
                 "outcome": ev.get("outcome"), "complexity": ev.get("complexity"),
                 "pr_number": ev.get("pr_number"), "retry_attempt": ev.get("retry_attempt"),
                 "boundary": ev.get("boundary"), "source": srcname}
for f in logs:
    n = bad = 0
    with open(f, "rb") as fh:
        for line in fh:
            try: d = json.loads(line)
            except Exception: bad += 1; continue
            if not isinstance(d, dict) or d.get("kind") != "lifecycle": continue
            a = d.get("attributes") or {}
            if not isinstance(a, dict): continue
            ev = dict(a); ev.setdefault("timestamp", d.get("timestamp"))
            if a.get("event") in ("agent_spinup","implement") and a.get("boundary") not in ("start","point",None): continue
            add(ev, f); n += 1
    src_stats.append({"file": f, "lifecycle_records": n, "unparseable_lines": bad})
for f in sums:
    try:
        d = json.load(open(f))
    except Exception as ex:
        src_stats.append({"file": f, "error": "unparseable: %s" % type(ex).__name__}); continue
    tk = d.get("tickets") or {}
    items = tk.items() if isinstance(tk, dict) else [(x.get("ticket"), x) for x in tk]
    n = 0
    for _, rec in items:
        for ev in (rec.get("events") or []):
            if ev.get("event") in ("agent_spinup","implement") and ev.get("boundary") not in ("start","point",None): continue
            add(ev, f); n += 1
    src_stats.append({"file": f, "generated_at": d.get("generated_at"), "source_files": d.get("source_files"), "ticket_events": n})
json.dump({"events": list(seen.values()), "sources": src_stats}, open(out, "w"))
print(len(seen), "events")
