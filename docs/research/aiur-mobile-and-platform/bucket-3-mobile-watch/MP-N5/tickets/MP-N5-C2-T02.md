---
ticket_id: MP-N5-C2-T02
feature_id: MP-N5
chunk_id: MP-N5-C2
bucket: 3-mobile-watch
title: Command rules — needs_you on human_needed, retraction on terminal states, no re-ask pushes
status: ready
blocked_by: [DESIGN-N5 (no-UI release), DESIGN-E2 §6.2, MP-N5-C2-T01, MP-N5-C1-T02, MP-E2-C1-T03, MP-E2-C2-T02]
prior_units: []
prior_boundaries: [DEC #27, new #41 candidate push-relay]
prior_features: [MP-E2]
prior_findings: [A-E2-1, A-E2-2, A-E2-3, D9, D11, D12, decision_attention.ex:17 re-ask]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C2-T02 — Command rules

## Identity and outcome

Bucket 3, MP-N5, chunk C2. Rule module `Aiur.Push.Policy.Rules.Commands` (PROPOSED):

- On `human_needed` (`ticket.<id>.agent.decision.human-needed` or
  `executor.decision.human-needed`; once per Command, command contract §8) → one
  `command.needs_you` intent per eligible device: `dedup_key = cmd:<decision_id>:needs_you`,
  `stream = cmd:<decision_id>`, `seq = 1`, `urgency = high` iff `blocking`, else `normal`
  (suppressed when `commands_non_blocking` is off), `expires_at = min(created + 24 h,
  Command expiry)`, summary title = `short_label` (≤ 40 chars; contract A-E2-3),
  subtitle = `<instance label> · #<ticket>` or `· Executor`, destination `target.kind:
  command` with `decision_id`, `ticket`, requester agent, `anchor_id` when E4 supplies it.
- On a terminal slug for a Command that was pushed to that device (`answered`, `expired`,
  `mooted`, `resolved`; slugs at `decision_store.ex:2633-2653`) → `command.resolved` with
  `retracts: [nid of the needs_you (and of the reminder, if sent)]`, `urgency: normal`,
  same stream, next `seq` (2, or 3 after a reminder).
- Never on `DecisionAttention` re-asks or routing epochs (`routed` with only
  `with_executor`).
- **One reminder (Phase D feasibility M3; owner choice DESIGN-N5 D-2 / OQ-N5-2).** For a
  `blocking` Command that was pushed to the device and is still `with_human` /
  `with_both` at `human_visible_at + commands_reminder_minutes` (C1-T01; proposed 30,
  `0` = off) → one `command.needs_you` with `attempt: 2`, same `stream` and
  `collapse_token`, `seq = 2` (the retraction then uses `seq = 3`), dedup key
  `cmd:<decision_id>:reminder`. The key is distinct from re-ask ticks (AC-N5-2 holds) and
  makes a second reminder impossible. Due times are recomputed from `human_visible_at`
  on boot (a restart neither skips nor doubles it). Not sent if the Command is terminal,
  non-blocking, or the first push was never queued for that device.
- **Badge.** Every `command.*` intent sets `summary.badge` at send time = count of open
  blocking Commands with the human on this instance (contract §3; computed by push-relay
  just before sealing, so a held intent carries the current count).
- Reconcile: open Commands with `human_visible_at` set (MP-E2-C1 field) → needs_you if the
  ledger lacks it; terminal Commands whose needs_you key exists and resolved key is absent
  → resolved.

## Dependencies and blockers

- MP-E2-C1-T03 (`human_needed` event type and topic), MP-E2-C2-T02 (routing engine that sets
  `human_visible_at`), C2-T01, C1-T02.
- **DESIGN-E2 §6.2** decides which Commands count as "needs you" (proposal: only when they
  become `with_human`/`with_both`). This ticket consumes E2's `human_needed` event, so the
  answer changes E2's emission, not this rule — listed as a gate, status stays ready.
- DESIGN-N5 D-2 (reminders; Phase D reworded as a delivery-reliability risk, proposal
  "one reminder after 30 min"): built here behind `commands_reminder_minutes`; if Kevin
  refuses, the default constant becomes `0` and MP-N4 AC-N4-1 records the decision.

## Verified starting point

- `Aiur.Decision` fields `authority`, `urgency (:low|:normal|:high|:critical)`, `blocking`,
  `context.short_summary` (`src/lib/aiur/decision.ex:18-42,120-136`).
- Durable decision topics require the durable path (`events/publisher.ex:57,188-193`).
- Lifecycle slugs: `lifecycle_slug/1` (`decision_store.ex:2633-2653`): `answered`,
  `expired`, `mooted`, `dismissed`, `deferred`, `resolved`, … . `dismissed`/`deferred`
  still accept answers (command contract §6 rule 6) → **not** retraction triggers.
- Re-ask interval 15 min (`decision_attention.ex:17`).

## Chosen design

- Eligible devices: registered (MP-N4), `commands_needs_you` effective `on` for that
  instance (C1-T02), audience `all_paired`.
- D11: a human answer that supersedes an undelivered Executor answer emits nothing new
  (the human is acting); retraction follows the eventual terminal slug.
- Executor-originated Commands (D12) arrive as `executor.decision.human-needed` and are
  treated identically.

## Implementation steps

`policy/rules/commands.ex` (PROPOSED) + table-driven tests using event fixtures shaped
like the E2 payload `{decision_id, version, short_label, requester, blocking, urgency,
cause}`.

## Non-happy paths

- `human_needed` without `short_label` → title from the DESIGN-E2 §4.1 fallback provided
  by E2 (`short_label` derivation is E2's: `short_summary → header → kind`).
- Command already terminal when the event is processed (late) → no needs_you; nothing.
- Unknown requester → subtitle without requester; never crash.

## Compatibility and rollout

New rule; no config.

## Verification

`src/test/aiur/push/policy/rules/commands_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"blocking human_required Command pushes high once"` (AC-N5-1) | 1 intent, urgency high | urgency from `Decision.urgency` |
| `"with_executor only produces nothing until escalated, then once"` (AC-N5-1) | 0 then 1 | subscribe to `routed` |
| `"re-ask ticks over one hour produce zero intents"` (AC-N5-2) | 0 | subscribe to `ticket.*.agent.attention.*` |
| `"answered emits resolved with retracts"` | `retracts == [nid]` | omit retracts |
| `"deferred does not retract"` | 0 | treat deferred as terminal |
| `"non-blocking suppressed when commands_non_blocking off"` | 0 | ignore preference |
| `"escalated twice pushes once"` | 1 (dedup key per Command) | key per routing epoch |
| `"unanswered blocking Command produces exactly one reminder and none after resolution"` (M3, AC-N5-2a) | clock past 30 min → 1 intent `attempt: 2`, same stream/collapse; past 60 / 90 min → 0; resolve → only `command.resolved` | remove the `:reminder` ledger key (second reminder appears) |
| `"reminder survives restart once"` | reminder due during downtime → 1 after boot, 0 on second boot | schedule from boot time instead of `human_visible_at` |
| `"non-blocking Command gets no reminder"` | 0 | ignore `blocking` |
| `"reminder_minutes 0 disables reminders"` | 0 | treat 0 as immediate |
| `"badge counts open blocking Commands at send time"` | 2 open + 1 resolved → `badge: 2` | count at intent time |

Commands: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/push/policy/rules/commands_test.exs`
(injected clock; no real sleeps).

## Completion and handoff

- [ ] AC-N5-1, AC-N5-2, AC-N5-2a covered. Device row V-R5 (MP-N4 matrix) run in MP-N4-C7.
- Docs: `website/docs-app/guide/` notifications page — the one-reminder rule and the badge
  (new documented behaviour).
- Dependents: C3-T01 (digest counts), MP-N6 (tap opens the Command).
