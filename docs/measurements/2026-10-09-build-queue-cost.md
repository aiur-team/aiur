# Build queue cost and Build Order census

Ticket: #3083 / MP-E1-C9-T04. **No saving claimed.**

Executor decision: ship instrumentation, census tooling and this procedure now.
Executor collects the AC12 and ordinary-run windows after merge and deployment
during #3253, fills the table and posts numbers on #3083. Problems become new
tickets. Keep `max_writes_per_minute: 20` unchanged pending that measurement;
this is not a measured endorsement of the default. RQ-9 measurement remains
pending; the cited research pack's `chunks.md` is absent from this checkout.

## Census

Collected 2026-10-09 14:21:45–14:21:47 UTC by:

```sh
python3 scripts/build-order-census.py --repo aiur-team/aiur
```

The tool pages every issue currently labelled `build-order`, open and closed,
and checks the complete, unique root population. It reads live GitHub through
governed `gh api graphql`, selecting `subIssues.totalCount`; querying one child
does not truncate that count. The collection cost was 1 reported GraphQL point
on the agent credential, separate from daemon queue cost.

| Root | State | Current direct members |
| --- | --- | ---: |
| #3252 | open | 51 |
| #3251 | open | 94 |
| #3250 | open | 97 |
| #3108 | open | 72 |
| #3042 | open | 41 |
| #2822 | open | 2 |
| #2618 | open | 7 |
| #2573 | open | 15 |
| #1567 | closed | 27 |
| #1467 | closed | 0 |
| #1363 | closed | 0 |
| #1311 | closed | 11 |
| #1084 | closed | 54 |

Population: 13 roots created July 14–October 8, 2026; 471 membership links,
median 27, largest 97. Eight open roots contain 379 links; seven roots have
more than 20 members. These are current links, not deduplicated tickets or
historical sizes. Empty closed roots stay in the denominator. Neither root size
nor a successful-promotion count establishes the peak newly ready per reconcile.

## Executor collection

Read [GitHub accounting guidance](../../website/docs-app/apis/github.md#reading-these-numbers-without-fooling-yourself)
first. Run from the Executor checkout, never an issue workspace. Use the
launched instance's identity for every control command. Preserve evidence
outside the logs that `--test3` clears, **before launching AC12**:

```sh
measurement_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-3083.XXXXXX")"
cp -a "$HOME/.aiur/logs" "$measurement_dir/logs-before-test3"
python3 scripts/build-order-census.py > "$measurement_dir/census.json"
tmux -L queue-cost-driver new-session -d -s queue-cost-driver -x 220 -y 60 \
  "bash -c 'unset TMUX; exec mise exec -- ./scripts/aiurdev --test3 --max-agents 1' 2>&1 | tee '$measurement_dir/startup.log'; sleep 3600"
```

Follow the canonical wrapper-tmux recipe in [AGENTS.md](../../AGENTS.md#driving-the-tui-from-a-non-tty-agent-environment):
read `aiur foreground tmux socket …, session …` from this startup log, wait for
a running row, open its chat pane, send input and capture rendered output.
Do not use HTTP/log inspection as proof of AC12. Back up the repository request
ledger too if the acceptance reset on this host clears it.

For each window use a separate directory (`ac12`, then `ordinary`). Record the
actual daemon PID and `run_log_root` printed/identified for that instance. The
default repository ledger is shown below; use its configured location if
overridden. Confirm no restart occurs within a window. Do not change credential
pooling or reset budgets while measuring.

```sh
window="$measurement_dir/ac12" # use ordinary for the second run
mkdir -p "$window"
request_log="$HOME/.aiur/repo/aiur-team/aiur/github-quota/daemon-requests.tsv"
# Set daemon_pid to the measured BEAM OS PID, run_log_root to its actual logs root.
printf '%s\n' "$daemon_pid" > "$window/daemon-pid"
env -u TMUX scripts/aiurdev status > "$window/status-start.txt"
env -u TMUX scripts/aiurdev github-cost --budget all --json > "$window/cost-start.json"
env -u TMUX scripts/aiurdev build-orders --json > "$window/build-orders.json"
env -u TMUX scripts/aiurdev queue show --json > "$window/queue-start.json"
date -u +%s > "$window/start-seconds"
```

For AC12, use the corrected #3082 sequence (separate adds avoid a self-edge):

```sh
env -u TMUX scripts/aiurdev pause
env -u TMUX scripts/aiurdev queue add 2897 --queue e2e
env -u TMUX scripts/aiurdev queue add 2898 --after 2897 --queue e2e
env -u TMUX scripts/aiurdev queue show --queue e2e --json > "$window/queue-added.json"
env -u TMUX scripts/aiurdev resume
```

T2 starts marker-only: queue reconciliation withdraws its pre-existing `agent:todo`
while T1 is still an unmet prerequisite. Confirm T2 becomes waiting after
reconciliation, then observe it start only after T1 completes.

Drive the actual TUI as #3082 describes and record T1 completion and T2 starting
without manual promotion. For the ordinary window, use a real Build Order root
already chosen by the Executor, record that root number and its start/end state,
and let it execute normally. If it needs adopting, `scripts/aiurdev queue add
--build-order "$root" --queue ordinary` is included inside that window.

At the end, before stopping/resetting anything:

```sh
date -u +%s > "$window/end-seconds"
env -u TMUX scripts/aiurdev github-cost --budget all --json > "$window/cost-end.json"
env -u TMUX scripts/aiurdev queue show --json > "$window/queue-end.json"
env -u TMUX scripts/aiurdev status > "$window/status-end.txt"
sleep 2 # allow the request ledger's one-second delayed-write buffer to flush
mkdir -p "$window/requests"
cp -a "$request_log"* "$window/requests/"
cp -a "$run_log_root/log/aiur.log" "$window/aiur.log"
```

If a rotation discards the window start, the evidence is incomplete: copy ledger
generations during longer runs, preserving each generation once without
double-counting copied rows. Do not turn missing evidence into a zero.

## Reading the measurements

`cost-*.json` exposes `snapshot.captured_at`, `data.callers[]` fields `caller`,
`resource`, `calls`, `reads`, `writes`, `points`, `points_per_hour`,
`elapsed_seconds`, `estimated?`, and `data.windows[resource].reset_at`.
Inspect `data.reconciliation` too. A multi-credential envelope also exposes
`data.credentials`; keep credential budgets separate. Within a stable window
and process, compute end minus start for `calls`/`points` per caller/resource;
divide by snapshot elapsed wall time and multiply by 3,600 for the observed
interval rate. Do not subtract the already-extrapolated `points_per_hour`.
Reject negative deltas or reset changes; after restart, do not compare attribution
with pre-restart credential spend. An absent row only means zero if both meters
are healthy and the complete ledger confirms no matching requests.

Queue-owned label requests use `build_queue_label_post` and
`build_queue_label_delete`. Promotion guard GETs use `build_queue_write_observe`.
Closure reads retain `build_queue_observe`; native dependency reads retain
`build_queue_blocked_by`. Cached reads produce no HTTP request/ledger row.
Shared open-list/catalog reads are shared cost, not exclusively queue cost.

The durable TSV has no header: columns 1–13 are `ts` (Unix seconds), `pid`,
`consumer`, `caller`, `method`, `host`, `path`, `status`, `resource`, `direction`,
`cost`, `cost_source`, `token_key`. Select the measured daemon PID and
`start-seconds <= ts < end-seconds`; group by caller/resource and sum column 11
for points, count rows for requests, preserving errors/304s separately. Divide
by `end-seconds - start-seconds` and multiply by 3,600. Ledger timestamps have
one-second resolution; live-snapshot deltas span slightly different boundaries.
Use the ledger interval as the reported window and snapshot deltas as a
cross-check, accounting for boundary requests explicitly.

Count the copied ledger with the exact window and PID (the output also exposes
status/source splits so errors are not reported as confirmed successful writes):

```sh
python3 - "$window" <<'PY'
import collections, csv, json, pathlib, sys
p = pathlib.Path(sys.argv[1])
start, end = [int((p / (name + "-seconds")).read_text()) for name in ["start", "end"]]
pid = (p / "daemon-pid").read_text().strip()
assert end > start and pid.isdigit()
groups = collections.defaultdict(lambda: {"requests": 0, "points": 0})
for file in (p / "requests").glob("daemon-requests.tsv*"):
    with file.open() as stream:
        for r in csv.reader(stream, delimiter="\t"):
            if len(r) != 13:
                raise ValueError("Incomplete ledger row")
            if r[1] != pid or not start <= int(r[0]) < end or not r[3].startswith("build_queue_"):
                continue
            key = (r[3], r[8], r[4], r[7], r[11])
            groups[key]["requests"] += 1
            groups[key]["points"] += int(r[10])
for key, counts in sorted(groups.items()):
    print(json.dumps(dict(zip(["caller", "resource", "method", "status", "cost_source"], key)) |
                     counts | {"requests_per_hour": counts["requests"] * 3600 / (end-start),
                               "points_per_hour": counts["points"] * 3600 / (end-start)}))
PY
```

An empty output is not evidence of zero until ledger coverage and meter health
are verified. Include all `build_queue_*` reads in total observation cost,
while also reporting `build_queue_observe` separately. One-time creation of
the repository's marker-label definition is a generic label-setup request,
outside the queue-owned per-issue POST/DELETE counters.

Each pre-write planner pass logs `build_queue_reconcile {JSON}` with
`captured_at_ms`, process-local `reconcile`, `phase`, `freshness`, `ready`, and
`newly_ready`. `newly_ready` counts IDs in planner state `ready` that were not
`ready` in the previous pass, including the initial ready population. `ready`
includes paced backlog; it is not successful writes. Select timestamps inside
the window and `phase == "ready"`, `freshness == "fresh"`; report the maximum
`newly_ready` and, separately, maximum `ready`. This exact extraction reads the
saved daemon log (an empty selection is **unknown**, never zero):

```sh
python3 - "$window" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
start = int((p / "start-seconds").read_text()) * 1000
end = int((p / "end-seconds").read_text()) * 1000
rows = [json.loads(line.split("build_queue_reconcile ", 1)[1])
        for line in (p / "aiur.log").read_text().splitlines()
        if "build_queue_reconcile " in line]
rows = [r for r in rows if start <= r["captured_at_ms"] < end
        and r["phase"] == "ready" and r["freshness"] == "fresh"]
print({"samples": len(rows),
       "peak_newly_ready": max((r["newly_ready"] for r in rows), default=None),
       "peak_ready_backlog": max((r["ready"] for r in rows), default=None)})
PY
```

## Results — pending Executor measurement

| Window / baseline | Duration (s) | Observation reads/h | Label POST/h | Label DELETE/h | Queue points/h by budget | Peak newly ready / ready backlog |
| --- | --- | --- | --- | --- | --- | --- |
| AC12 | pending Executor measurement | pending Executor measurement | pending Executor measurement | pending Executor measurement | pending Executor measurement | pending Executor measurement |
| Ordinary Build Order (record root) | pending Executor measurement | pending Executor measurement | pending Executor measurement | pending Executor measurement | pending Executor measurement | pending Executor measurement |

Attach raw artifacts, dates, root population and run identities when filling
this table. Compare the two observed intervals; neither is a before/after
saving claim. If peak newly ready exceeds 20, file a pacing-default follow-up
with these numbers; otherwise record the evidence for retaining 20. No default
change or limit/saving claim is justified by this census alone.
