---
ticket_id: MP-R2-C6-T05
feature_id: MP-R2
chunk_id: MP-R2-C6
bucket: 1 (Bucket-2-enabling, RC-09)
title: Exporter back-pressure alarm sized from a measured export-rate census (RQ-4), with a fixed sizing rule and fsync-batching trigger
status: ready
blocked_by: [DESIGN-R2 §2, MP-R2-C6-T02, MP-R2-C6-T03]
prior_units: [U8]
prior_boundaries: [BUS #10]
prior_features: [MP-N4, MP-N5]
prior_findings: [MP-R2 RQ-4]
size_owner: n/a (exporter file stays ≤ 300 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C6-T05 — Mailbox alarm and the RQ-4 census

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C6.** Off by default.
- **Why:** the Exchange is fire-and-forget (`send/2` in the publisher's
  process, `src/lib/aiur/events/exchange.ex:93-108`), so a slow exporter
  cannot slow producers; its mailbox grows instead. Unbounded growth would
  end in memory pressure with no signal (plan §7 "Back-pressure").
- **Deliverable:** (1) a measured census of the export rate on the dogfood
  instance (RQ-4) recorded in the PR body; (2) a periodic mailbox check in
  the exporter that raises one latched attention when the backlog crosses a
  threshold computed by a fixed rule from the census; (3) if the census
  crosses the batching trigger below, `Journal.append_many/2` with one fsync
  per batch.
- **Non-goals:** dropping events on purpose (the alarm reports; loss is
  only ever reported as `gap`), changing the Exchange.

## Dependencies and blockers

DESIGN-R2 §2; C6-T02 (exporter running, needed to measure); C6-T03.
The census requires the operator's dogfood instance with
`events.export.enabled: true` for ≥ 24 h; schedule it inside this ticket's
window (no owner decision needed — the rule below is fixed).

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Exchange delivery is a plain `send/2` per subscriber in the caller | `src/lib/aiur/events/exchange.ex:93-108` |
| `DecisionLog.append/2` opens, writes, fsyncs and closes per record | `src/lib/aiur/decision_log.ex:126-145` |
| No durable census source covers all exported topics today: GitHub/CI/PR events are `live` (not written, `issue_log.ex:573-581`); only alerts (ledger), agent emits (IssueLog) and `executor.*` (journal) are durable | contract §6 |
| AGENTS.md rule: rates are measured live, sampled twice, quoted with date and size ("A claimed saving must be measured"; memory "measure the rate, not the level") | `AGENTS.md` |

Therefore the census is taken **from the export journal itself** after
C6-T02, which is the only place that sees exactly the exported population.

## Chosen design

**Census procedure (exact):**

1. On the dogfood checkout, set `events.export.enabled: true` (back up
   `.aiur/config` first), `aiurdev restart`, run a normal fleet day.
2. After ≥ 24 h, from `<runtime_state_dir>/events/export/`:

   ```bash
   cat seg.*.ndjson | jq -c 'select(.type=="event") | {t: .topic, m: (.observed_at[0:16])}' > /tmp/census.jsonl
   jq -s 'length' /tmp/census.jsonl                                   # total events
   jq -r '.t | sub("^ticket\\.[0-9]+"; "ticket.*")' /tmp/census.jsonl | sort | uniq -c | sort -rn   # per topic
   jq -r '.m' /tmp/census.jsonl | sort | uniq -c | sort -rn | head -1  # peak events in one minute
   cat seg.*.ndjson | awk '{ n++; b += length($0)+1 } END { print b/n }'  # mean bytes per record
   ```

3. Repeat step 2 on a second 24 h window (sample twice; diff the rates).
4. Record both censuses in the PR body with dates, window lengths, totals,
   per-topic top 10, peak/minute, mean record bytes.

**Sizing rule (fixed):**
`threshold = max(1_000, 10 × peak_per_minute)` messages, using the larger
of the two censuses. Until the census runs, the default is `10_000` (tests
use an injected value). The constant lives in the exporter with the census
reference in a comment.

**Check:** every 5 s (`Process.send_after`), read
`Process.info(self(), :message_queue_len)`. Raise when above threshold on
**two consecutive** checks; clear when below `threshold / 2` on two
consecutive checks. Raise/clear call an injected
`on_backlog.(:raised | :cleared, %{len, threshold})`; `aiur.ex` maps them to
`Signal.alert("system.events.export_backlog", needs_attention: true, severity: "warning", reason: …)`
(the signal port, PR-07; C6 is wave 5, so `Aiur.Alerts.emit_system` is not called directly, X-48)
and `"system.events.export_backlog.resolved"` (in-grammar; add both to the
C5 catalog as ledgered, not exported). Latched: one raise per crossing.

**Batching trigger (fixed):** if either census shows a peak above
**1 200 events/minute** (20/s sustained for a minute), the per-record fsync
(≈ ms each) risks backlog; then implement `Aiur.Events.Journal.append_many/2`
(encode N lines, one `:file.write`, one `:file.sync`), and have the exporter
drain up to 100 queued `{:event, _}` messages per batch (`receive … after 0`).
If below the trigger, keep per-record append and say so in the PR body with
the measured peak. Either way `seq` density and "visible only after fsync"
(C6-T02 invariant) hold.

## Implementation steps

1. Run the census (above); write numbers into the PR body.
2. Add the check timer, latch, `on_backlog` injection and catalog entries.
3. If the trigger is crossed, add `append_many/2` and batch draining.

## Non-happy paths

- Threshold flapping: hysteresis (raise > T twice, clear < T/2 twice).
- Exporter `:unavailable`: it still drains its mailbox (drops and counts),
  so the alarm does not fire on top of the unavailable attention.
- Census impossible (no dogfood fleet): use the default 10 000 and state
  "census not run" in the PR body; the ticket is then not complete
  (acceptance requires the census).

## Compatibility and rollout

Off by default with the exporter. No config key (an operator does not tune
an internal alarm). Rollback: revert.

## Verification

`test/aiur/events/export/backlog_test.exs` (injected threshold 5, check
interval 10 ms, `:sys.suspend/1` to hold the exporter while sending 20
events, then resume):

1. `"raises once when the mailbox stays above threshold for two checks"`.
2. `"does not raise on a single spike"` — one check above, next below.
3. `"clears once below half the threshold for two checks"`.
4. If batching is implemented: `"append_many writes all lines with one sync and keeps seq dense"`
   (inject a sync counter fun) and `"a crash mid-batch leaves only whole fsynced lines"`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/export/backlog_test.exs test/aiur/events/export/
```

Mutation checks: remove the two-consecutive rule → test 2 fails; remove the
latch → test 1 sees two raises; restore → pass.

## Completion and handoff

- [ ] Two censuses recorded (dates, sizes, peak/minute, bytes/record).
- [ ] Threshold computed by the rule and committed with the census cited.
- [ ] Batching decision stated with the measured peak.
- [ ] Tests added and mutation-checked.
- [ ] Docs: none (no operator surface beyond the alert, which uses the
      existing alert feed).
- Dependents: C6-T01 (upper bound on `retention_max_events` can be re-checked
  against measured bytes/record), MP-N4.
