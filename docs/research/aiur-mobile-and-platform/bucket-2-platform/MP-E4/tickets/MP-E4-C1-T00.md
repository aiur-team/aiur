---
ticket_id: MP-E4-C1-T00
feature_id: MP-E4
chunk_id: MP-E4-C1
bucket: 2-platform
title: "RQ-E4-1: measure journal entries/hour and bytes/hour per agent on the live fleet"
status: ready
blocked_by: []
design_gate: "n/a — research spike"  # RC-32: read-only research or local experiment
prior_units: [U6]
prior_boundaries: [PRJ, RUN]
prior_features: []
prior_findings: [AGENTS.md "A claimed saving must be measured" item 5 (count the population)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C1-T00 — RQ-E4-1 journal size census (measurement only)

## Identity and outcome

- Bucket 2 · MP-E4 · chunk C1 · research ticket. **No production code.**
- **User value:** the durable journal keeps every transcript forever (contract
  §6, DESIGN-E4 decision 5). The operator must see the disk cost before it is
  built, as a measured number, not an estimate.
- **Deliverable:** a dated census table (entries/hour and bytes/hour per agent,
  p50/p90/max; bytes per ticket; count of records over each candidate body
  bound) appended to `bucket-2-platform/MP-E4/plan.md` §10 under RQ-E4-1, and
  a recommendation that MP-E4-C1-T01 adopts: the per-entry body bound (64 KiB,
  or lower) and the segment roll size.
- **Non-goals:** changing any log, pruning, a config key.

## Dependencies and blockers

- None. Read-only on the operator's machine. Not behind DESIGN-E4 because it
  changes nothing; its result feeds DESIGN-E4 decision 5 (retention).
- Must finish before MP-E4-C1-T01 fixes `@max_body_bytes` and the segment size.
- May run concurrently with every other ticket.

## Verified starting point

- There is no full-fidelity transcript store to measure (contract §1). Two
  proxies exist and bracket the journal:
  - **Lower bound:** IssueLog transcript files
    `<logs-root>/<launch>/log/<repo>.<id>.agent_events.jsonl`; bodies are cut
    at 1,000 chars and diffs at 2,000 (`src/lib/aiur/issue_log.ex:46-47`), and
    records over 16 KiB are reduced (`issue_log.ex:37`). The launch root is
    `~/.aiur/logs/<launch>` (`config/paths.ex:28-37`; the launcher makes one per
    daemon launch).
  - **Upper bound:** workspace `logs/agent.ndjson` (the raw backend message
    map, `agent_event_log.ex:23-48`) under `workspace.root`
    (`~/code/aiur-workspaces` in this repo's `.aiur/config`). It holds full
    command output and diffs, but also protocol noise, so only records the
    journal would store are counted (`item/completed`, `transcript`, `alert`)
    and each is capped at the candidate body bound.
- The journal skips `assistant_delta` (`agent_runner/message_handler.ex:131-134`).
  A preliminary census (below) shows deltas are 557,453 of 642,871 IssueLog
  records (174.2 MB of 213.3 MB), so excluding them is essential.

### Preliminary census (2026-10-06, this machine, read-only)

| Source | Population | entries/h/agent p50 / p90 / max | bytes/h/agent p50 / p90 / max | bytes/ticket p50 / p90 / max |
| --- | --- | --- | --- | --- |
| IssueLog, deltas excluded (lower bound) | 389 ticket-launches in 48 launches | 249 / 539 / 2,236 | 112 KB / 266 KB / 775 KB | 68 KB / 216 KB / 0.93 MB |
| Workspace ndjson, cap 64 KiB (upper bound) | 352 workspaces (mostly 2026-08) | 35 / 380 / 937 | 228 KB / 3.0 MB / 9.25 MB | 1.85 MB / 12.9 MB / 47.3 MB |
| Workspace ndjson, cap 16 KiB | same | same | 124 KB / 1.56 MB / 4.25 MB | 1.0 MB / 6.65 MB / 23.4 MB |

8,301 workspace records exceed 64 KiB; 25,741 exceed 16 KiB. The "per hour"
span is first-to-last record of a file, so idle time lowers the rate. This
ticket re-runs the census, adds the dated live-fleet window, and records the
decision.

## Chosen design

Two read-only Python scripts that print aggregates only (never a body, a
path inside a body, or a token). They are run with `python3 -I` from a
scratch directory, never from inside a workspace.

## Implementation steps

1. Create a scratch dir outside the repo and any workspace:
   `S="$(mktemp -d)"`.
2. Write `"$S/census_issue_log.py"`:

```python
#!/usr/bin/env python3
"""RQ-E4-1 lower bound: IssueLog transcripts, deltas excluded. Aggregates only."""
import glob, json, os, sys
from datetime import datetime, timezone
def ts(v):
    try: return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
argv = sys.argv[1:]; since = None
if "--since" in argv:
    i = argv.index("--since"); since = datetime.fromisoformat(argv[i + 1]).replace(tzinfo=timezone.utc)
    argv = argv[:i] + argv[i + 2:]
root = os.path.expanduser(argv[0] if argv else "~/.aiur/logs")
rows = []
for path in glob.glob(os.path.join(root, "*", "log", "*.agent_events.jsonl")):
    n = nbytes = 0; first = last = None
    with open(path, "rb") as fh:
        for raw in fh:
            try: rec = json.loads(raw)
            except Exception: continue
            if rec.get("kind") == "assistant_delta": continue
            t = ts(rec.get("timestamp"))
            if since and t and t < since: continue
            n += 1; nbytes += len(raw)
            if t:
                first = t if first is None or t < first else first
                last = t if last is None or t > last else last
    hours = (last - first).total_seconds() / 3600 if first and last else 0
    if n and hours >= 0.05: rows.append((n, nbytes, n / hours, nbytes / hours))
def q(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))]
if not rows: print("no files"); sys.exit(0)
c = [r[0] for r in rows]; b = [r[1] for r in rows]; eph = [r[2] for r in rows]; bph = [r[3] for r in rows]
print(f"source=issue_log ticket_launches={len(rows)} deltas_excluded since={since}")
print(f"entries/h/agent p50={q(eph,.5):.0f} p90={q(eph,.9):.0f} max={max(eph):.0f}")
print(f"bytes/h/agent p50={q(bph,.5)/1e3:.0f}KB p90={q(bph,.9)/1e3:.0f}KB max={max(bph)/1e3:.0f}KB")
print(f"bytes/ticket p50={q(b,.5)/1e3:.0f}KB p90={q(b,.9)/1e3:.0f}KB max={max(b)/1e6:.2f}MB total={sum(b)/1e6:.1f}MB")
```

3. Write `"$S/census_workspace_ndjson.py"`:

```python
#!/usr/bin/env python3
"""RQ-E4-1 upper bound: workspace agent.ndjson, journal-relevant records, capped. Aggregates only."""
import glob, json, os, sys
from datetime import datetime
CAP = int(os.environ.get("CAP_BYTES", "65536"))
def ts(v):
    try: return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
files = set()
for r in [os.path.expanduser(x) for x in (sys.argv[1:] or ["~/code/aiur-workspaces"])]:
    for depth in ("*", "*/*", "*/*/*"):
        files.update(glob.glob(os.path.join(r, depth, "logs", "agent.ndjson")))
rows = []; over = 0
for path in files:
    n = nbytes = 0; first = last = None
    with open(path, "rb") as fh:
        for raw in fh:
            try: rec = json.loads(raw)
            except Exception: continue
            p = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
            if not (p.get("method") == "item/completed" or rec.get("event") in ("transcript", "alert")): continue
            n += 1; over += len(raw) > CAP; nbytes += min(len(raw), CAP)
            t = ts(rec.get("timestamp"))
            if t:
                first = t if first is None or t < first else first
                last = t if last is None or t > last else last
    hours = (last - first).total_seconds() / 3600 if first and last else 0
    if n and hours >= 0.05: rows.append((n, nbytes, n / hours, nbytes / hours))
def q(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))]
if not rows: print("no files"); sys.exit(0)
b = [r[1] for r in rows]; eph = [r[2] for r in rows]; bph = [r[3] for r in rows]
print(f"source=workspace cap={CAP} workspaces={len(rows)} records_over_cap={over}")
print(f"entries/h/agent p50={q(eph,.5):.0f} p90={q(eph,.9):.0f} max={max(eph):.0f}")
print(f"bytes/h/agent p50={q(bph,.5)/1e3:.0f}KB p90={q(bph,.9)/1e6:.2f}MB max={max(bph)/1e6:.2f}MB")
print(f"bytes/workspace p50={q(b,.5)/1e3:.0f}KB p90={q(b,.9)/1e6:.2f}MB max={max(b)/1e6:.2f}MB total={sum(b)/1e6:.1f}MB")
```

4. Run (read-only; `nice` keeps the fleet responsive):

```bash
nice python3 -I "$S/census_issue_log.py" ~/.aiur/logs
nice python3 -I "$S/census_issue_log.py" ~/.aiur/logs --since "$(date -u -d '7 days ago' +%F)"
for cap in 65536 32768 16384; do CAP_BYTES=$cap nice python3 -I "$S/census_workspace_ndjson.py" ~/code/aiur-workspaces; done
find ~/.aiur/logs -maxdepth 1 -mindepth 1 -type d | wc -l            # launches in the population
find ~/code/aiur-workspaces -path '*/logs/agent.ndjson' -newermt "$(date -u -d '7 days ago' +%F)" | wc -l   # recent workspaces
df -h "$HOME"                                                       # free space the journal competes for
```

5. Compute the projection the operator decides on:
   `fleet bytes/day = bytes/h/agent (p50 and p90) × max_concurrent_agents × 24`
   (`agent.max_concurrent_agents` from `.aiur/config`; read the key, not the
   file's secrets). Do it for the lower bound and each cap.
6. Record the outputs, the date, the population sizes, and the projection in
   `MP-E4/plan.md` §10 RQ-E4-1, and state the recommendation:
   - keep 64 KiB if the p90 upper-bound projection at 64 KiB is under 1 GB/day
     for the configured fleet size; otherwise propose 16 KiB for `tool_result`
     and `command` bodies and 64 KiB for `message` and `diff`;
   - segment roll size stays 8 MiB unless p90 bytes/ticket at the chosen cap
     exceeds 64 MiB (then 32 MiB, to keep segment count per conversation low).
7. `rm -rf "$S"`.

## Non-happy paths

- **Secrets:** transcripts can hold secrets. The scripts print aggregates
  only; never `print(rec)`. Do not commit the scripts' input or any line of it.
- **Population too small or stale** (for example the workspace set is mostly
  from August): state it next to the number (AGENTS.md: quote a census with
  its date and size); add the `--since` run as the live-fleet figure.
- **A file is being written while read:** a torn last line fails `json.loads`
  and is skipped; the effect is at most one record.
- **Load:** do not run while `aiurdev agents` shows the load governor holding
  dispatch; `nice` is mandatory.

## Compatibility and rollout

n/a — no code, config or data changes.

## Verification

- The two scripts' outputs are pasted verbatim into the plan with the date.
- Cross-check: the IssueLog record-kind split must again show
  `assistant_delta` as the majority of records; if it does not, the delta
  exclusion is broken and the numbers are void.
- Mutation check: n/a (no test is added).

## Completion and handoff

- [ ] Census rows (lower bound, live 7-day window, three caps) recorded with
      date and population counts in `MP-E4/plan.md` §10.
- [ ] Fleet bytes/day projection recorded.
- [ ] Body bound and segment size recommendation recorded; MP-E4-C1-T01's
      constants updated to match before it starts.
- [ ] DESIGN-E4 decision 5 (retention) receives the bytes/day figure.
- Dependents: MP-E4-C1-T01 (constants), DESIGN-E4.
- Docs: none (research record only).
