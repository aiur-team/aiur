---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-N5
bucket: 3 (mobile and watch)
base_main_sha: 45a290e3
date: 2026-10-06
depth: standard
owns_contracts: [] # co-authors NotificationIntent fields in contracts/notification-destination-and-payload.md §2, §6
consumes_contracts: [notification-destination-and-payload (MP-N4), command-request-and-resolution (MP-E2), queue-readiness-and-build-progress (MP-E1), events-and-replay (MP-R2), pairing-and-instance-registry (MP-N2), identity-and-capabilities (MP-R1)]
design_gate: DESIGN-N5
blockers: [DESIGN-N5, DESIGN-E2 §6.2 (which Commands count as "needs you"), MP-N4-C3, MP-N2 device registry]
---

# MP-N5 — Notification preferences and progress updates

Chunks: [chunks.md](chunks.md). Owner gate: [DESIGN-N5](../../owner-design-tasks/DESIGN-N5.md).
Delivery mechanics (sealing, relay, devices) are MP-N4; this feature decides **what**
becomes a notification, **for whom**, and **how often**.

---

## 1. Summary

A daemon-side policy engine turns durable events into `NotificationIntent`s. Defaults
follow D18: Commands that need the human are always on; build-order progress every 25 %
and completion are on; PR merges and other events are opt-in. Preferences are stored per
paired device per machine, with optional per-instance overrides, and the settings screen
shows only options the instance can actually deliver. A high-water progress tracker, a
dedup ledger, coalescing and outbox staleness rules prevent duplicates, repeated
milestones and stale bursts after a reconnect.

## 2. Requirements

- N5-R1. The primary alert is a Command that needs the human, from a worker or the
  Executor, as decided by the MP-E2 escalation policy (D9, D11, D12) — not every internal
  request.
- N5-R2. Defaults per D18. Changing a default is per device and per machine, optionally
  per instance.
- N5-R3. Progress notifications at configurable build-order thresholds (25 % default;
  10 % and 50 % selectable) plus completion; a jump across several thresholds yields one
  notification for the highest one crossed.
- N5-R4. Capability-aware settings: build-order options appear only when
  `build_orders.progress` is available; an unsupported event is shown as unavailable with
  a reason, never as a working toggle (capability-matrix rule 1).
- N5-R5. Duplicate suppression across restarts, re-asks, retries and multiple instances.
- N5-R6. No burst of outdated alerts after the phone, relay or machine reconnects.
- N5-R7. Noise limits for non-Command kinds.

## 3. Repository findings (extends baseline N5)

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Only sound preferences exist | `src/lib/aiur/config/schema/alerts.ex:13-25` (`enabled`, `use_os_default_sounds`, `sound_dir`, `alerts_file`) | new model; `alerts.*` stays for local sounds and is not reused for push |
| Command re-asks fire every 15 min | `src/lib/aiur/decision_attention.ex:17` | re-ask is not a notification trigger |
| Command lifecycle is durable and published | `src/lib/aiur/events/publisher.ex:57` (`decision.requested/acknowledged/resolved`), `decision.ex:39` statuses | source for `command.needs_you` and `command.resolved` once MP-E2 adds routing state |
| Authority values | `decision.ex:20,52` (`human_required`, `supervisor_allowed`, `supervisor_preferred`) | `human_required` and Executor-originated go straight to "needs you" (D9, D12) |
| Build-order progress is **pull-computed**, no change event | `src/lib/aiur/build_order/catalog_store.ex:33` `fetch/1` builds `RootSummary` from `ResourceStore`; `root_summary.ex:21-25` (`progress`, `progress_resolution`, `completed?`) | N5 consumes E1's milestone topics and progress facts (queue-readiness contract §4); debounced recompute is the fallback |
| Progress quality is explicit | `root_summary.ex:6` `:resolved \| :partial \| :unresolved \| :unknown` | milestone notifications only on `:resolved` |
| PR merge, CI, retry-exhausted, comments, pushes are existing topics | `executor_bindings.ex:24-29`; `Aiur.Events.UniversalSubscriptions` (baseline R2) | candidate opt-in sources |
| Event ids are durable and global | `src/lib/aiur/events/id_generator.ex:83,106` | policy cursor for restart |

## 4. Proposed boundaries

| Component | Interface | Notes |
| --- | --- | --- |
| `notification-policy` (module set inside the MP-N4 `push-relay` package) | `Policy.handle_event(event) -> [NotificationIntent]`; `Policy.handle_progress(root_summary) -> [intent]` | pure functions + small persisted state (tracker, ledger) |
| `notification-preferences` store (machine-level, beside `devices.json` in the MP-N2 machine store) | `Prefs.get(device_id)`, `Prefs.put(device_id, patch, expected_version)`, `Prefs.effective(device_id, instance_key)` | the MP-N2 gateway is the single writer; every instance daemon reads (pairing contract §5) |
| Preferences API (device token) | gateway `GET/PATCH /v1/notification-settings` (machine defaults + overrides, `expected_version`); per-instance `GET /api/v1/device/notification-options` → each option's availability from that instance's capabilities | writes on the gateway, availability from the instance (A-N2-4) |
| Settings UI | phone app screen (MP-N1 boundary decides native vs WebView) | DESIGN-N5 |

Prior refs: Prior-boundaries `EXE` (#26), `DEC` (#27), `BO` (#30) as event sources;
Prior-units none (post-refactor feature).

### Preference model v1

```text
NotificationPreferences { v: 1, device_id, machine_id, version,
  defaults: {
    commands_needs_you:       "on"        # locked on (D18); see OQ-N5-1 for per-instance mute
    commands_non_blocking:    "on"        # proposal, OQ-N5-4
    progress_step_pct:        25          # one of off | 10 | 25 | 50
    progress_completion:      true
    pr_merged:                false
    optin: { agent_retry_exhausted: false, ci_failed: false }   # OQ-N5-3 for others
  },
  instance_overrides: { "<instance_key>": { …partial of defaults… } } }
```

Defaults apply on first pairing; there is no global (cross-device) preference. A watch
that only mirrors the phone has no preferences of its own; a direct-push watch (MP-N7)
gets its own record seeded from the phone's at pairing.

## 5. Policy rules

### 5.1 Commands (always the primary alert)

- Emit `command.needs_you` on the MP-E2 `human_needed` event
  ([command-request-and-resolution.md](../../contracts/command-request-and-resolution.md) §8),
  which fires **once per Command** when it first becomes `with_human` or `with_both`:
  `human_required`, Executor-originated (D12), no live Executor, or an escalation cause
  (`executor_escalated`, `executor_ack_timeout`, `executor_answer_timeout`,
  `executor_offline`, `executor_not_answerable`). A Command that is only `with_executor`
  produces no push (DESIGN-E2 §6.2 proposal; if Kevin chooses otherwise this rule follows).
  A Command deferred back to the Executor and escalated again does not push twice.
- `urgency: high` iff `blocking: true`; otherwise `normal` (and suppressed entirely if
  `commands_non_blocking` is off). Both values come on the `human_needed` payload.
- Emit `command.resolved` (retraction) on any terminal slug for a Command that was pushed
  to that device.
- D11: if a human answer supersedes another undelivered answer, no new push (the human is
  the one acting).
- Re-asks (`DecisionAttention`) never emit. Reminders: none in v1 (OQ-N5-2).
- Boot reconciliation: on start, read open Commands with `human_visible_at` set from the
  DecisionStore snapshot (journaled) and enqueue any that the ledger has not seen, subject
  to §5.6 staleness. This covers `human_needed` events lost while the daemon was down.

### 5.2 Build-order and queue progress

Source: the progress facts and milestone topics of
[queue-readiness-and-build-progress.md](../../contracts/queue-readiness-and-build-progress.md)
§4 (`system.build_order.<root>.progress.milestone`,
`system.queue.<queue_id>.progress.milestone`, `Aiur.BuildQueue.progress/1`). That contract
already guarantees: highest-crossed-only, no repeats per **generation**, no milestones
from `unresolved`/`unknown` data, and a new generation when a completed root reopens.
N5 adds per-device steps on top:

State per `(device_id, instance_key, scope, id, generation)`: `last_notified_pct`.

1. **Step 25 (default):** consume the milestone topic directly; 100 maps to
   `progress.complete`, the others to `progress.milestone`.
2. **Step 10 or 50:** on each progress observation (see request A-E1-1 in the
   notification contract §9) compute `crossed = floor(percent / step) * step`; if
   `crossed > last_notified_pct`, emit **one** notification for `crossed` (20 % → 70 % at
   step 10 emits 70 % only); 100 is `progress.complete`. Ignore `resolution` other than
   `resolved`, matching the E1 rule.
3. Decreases never emit and never lower `last_notified_pct`.
4. A new generation (reopened root, new queue) starts at `last_notified_pct = 0`, so a
   re-completion notifies again (OQ-N5-5 confirms).
5. **Baseline on enable:** when a device pairs, enables progress, or changes the step,
   set `last_notified_pct = floor(current / step) * step` silently. No retroactive
   milestones.
6. Until E1 ships its producer, the fallback is to read `RootSummary.progress` via
   `CatalogStore.fetch/1` debounced 60 s after `ticket.*.pr.merged` or issue-closed
   events, applying the same rules. Queue progress has no fallback (queues are E1-only).

### 5.3 Opt-in events

| Event | Source topic | Recommendation |
| --- | --- | --- |
| PR merged | `ticket.*.pr.merged` | offered, off (D18) |
| Agent gave up (retry exhausted) | `ticket.*.agent.retry_exhausted` | offered, off; it is often a blocker in all but name |
| CI failed on a ticket | `ticket.*.ci.failed` | offered, off |
| Commit pushed | `ticket.*.branch.push` | **not offered in v1**: high volume, low action value; the dashboard feed covers it (OQ-N5-3) |
| PR / issue comment | `ticket.*.issue.commented`, `ticket.*.pr.review_comment` | **not offered in v1**, same reason (OQ-N5-3) |

### 5.4 De-duplication

Ledger keyed by `(device_id, dedup_key)` (contract §6 keys) persisted with the outbox.
A key is recorded when the intent is **accepted into the outbox**, so a crash after
recording and before sending results in the outbox resend, never a second intent.
Ledger entries expire after 30 days (Command keys) or with the root (progress keys).
Event ids are unique but not a delivery order
([events-and-replay.md](../../contracts/events-and-replay.md) §5). The policy uses the
durable-consumer primitive proposed there (§7: subscribe, replay from export `seq`, live,
dedupe on id) and persists its `seq` cursor. Topics that are `live` only (GitHub-sourced
`ticket.*.pr.merged`) are not replayed; boot reconciliation covers Commands and progress
from their own stores; the ledger absorbs any overlap.

### 5.5 Noise limits

- **Coalescing:** per `(device, instance)`, the first intent sends immediately; further
  intents within 120 s are held and flushed at window end. Two or more held → one
  `digest` ("3 updates on aiur: 2 Commands need you, build 50 %"). A held
  `urgency: high` Command is never held longer than 120 s.
- **Cap:** at most 6 non-Command notifications per instance per device per hour; excess
  folds into the next digest.
- **OS controls first:** Focus and notification summary are respected; aiur adds no quiet
  hours in v1 (OQ-N5-6). Time Sensitive use is DESIGN-N4 D-3.

### 5.6 Staleness (no burst after reconnect)

Applied by push-relay at **send time**, not only at intent time:

- `command.needs_you` whose Command no longer needs the human → dropped.
- Older entry on a stream with a newer one queued → dropped.
- Entry older than `push.outbox.max_age_seconds` (24 h): progress and opt-ins dropped;
  still-open Commands folded into one digest per instance.
- Device-side `expires_at` and stream rules (contract §6) catch what the daemon could not
  (e.g. APNs held a notification while the phone was off).

## 6. Non-happy paths

- **Capability absent:** `build_orders.progress` unavailable → progress options returned
  as `unavailable(build_orders_not_installed | not_configured | unresolved_progress)`;
  stored values are kept but not applied. `commands.answer` unavailable → Command pushes
  still go out (awareness), MP-N6 shows "answer from the dashboard". Unknown option ids
  from a newer daemon are ignored by older apps.
- **Instance offline while editing settings:** the app shows last-fetched preferences as
  stale and disables save for that instance; machine-level defaults are saved through any
  reachable instance (shared machine store).
- **Concurrent edits from two devices:** each device edits only its own record;
  `expected_version` guards a device editing from two app instances.
- **Instance renamed/moved (new instance key):** overrides for the old key are orphaned;
  MP-N2 discovery reports the change, and the settings screen offers to carry them over.
- **Executor absent:** E2 routes Commands straight to the human (D9), so they push
  immediately; no N5 special case.
- **Clock skew:** expiry uses daemon time at seal; device treats `expires_at` with a
  5-minute tolerance.

## 7. Alternatives considered

| Alternative | Why not |
| --- | --- |
| Evaluate preferences on the device (send everything, filter locally) | Leaks volume/timing of every event to relay/providers and burns FCM high-priority budget on hidden messages (E-F4). |
| One global preference set per machine | Phone and watch users differ; brief asks for scope; per device is the smallest scope that works with multiple devices. |
| Notify every N percent including drops | Re-notifying a milestone after scope changes is the "stale burst" the brief forbids. |
| Reuse `alerts.*` config | Those are local sound settings in the per-instance config; push preferences are per device and machine-level. |

## 8. Acceptance criteria

1. AC-N5-1 Fresh pairing: a blocking `human_required` Command pushes; a "With Executor"
   Command does not until it escalates; then it pushes once (unit + integration).
2. AC-N5-2 `DecisionAttention` re-ask ticks over 1 h produce zero additional intents.
3. AC-N5-3 Progress 20 → 70 → 60 → 76 → 100 (completed) at step 25 yields exactly:
   50 %, 75 %, complete.
4. AC-N5-4 Changing the step from 25 to 10 at 63 % emits nothing; next notification at 70 %.
5. AC-N5-5 Daemon restart between "intent accepted" and "sent" yields exactly one send.
6. AC-N5-6 Five intents in 30 s → one immediate notification + one digest.
7. AC-N5-7 With build orders absent, the settings response marks progress options
   `unavailable` with a reason, and the UI shows them disabled (test fails if replaced by
   a plausible default such as `off`, per `AGENTS.md` unknown-path rule).
8. AC-N5-8 Relay outage of 3 h with 4 open Commands (2 resolved meanwhile) delivers one
   digest naming 2 Commands, no resolved ones.
9. AC-N5-9 PR merges produce nothing until opted in; after opt-in, one per PR even if the
   merge event is observed by both webhook and poller (existing dedup + ledger).

## 9. Open questions

**Owner (Kevin):**
- OQ-N5-1 "Always on" for blocker Commands: may a device mute one instance (e.g. an
  experimental repo)? Proposal: yes, per-instance mute with a visible "muted" badge.
- OQ-N5-2 Reminder for a blocking Command still unanswered after N minutes? Proposal: none
  in v1.
- OQ-N5-3 Offer commit-push and comment notifications at all? Proposal: not in v1.
- OQ-N5-4 Non-blocking Commands that need you: on by default (proposal) or opt-in?
- OQ-N5-5 Notify again when a reopened build order completes again? Proposal: yes.
- OQ-N5-6 aiur quiet hours, or rely on OS Focus only? Proposal: OS Focus only.

**Research:**
- RQ-N5-1 E1 accepts request A-E1-1 (a `progress.observed` signal or a read API) for non-25 % steps; otherwise v1 offers step 25 only and the 10/50 options are shown unavailable.
- RQ-N5-2 (resolved by the E2 contract) `human_needed` is once per Command; no epoch needed.
- OQ-N5-7 (owner) Executor-created queue milestones follow the same progress setting as
  build orders (proposal), or get their own toggle?

## 10. Plan refresh

Event topics and `CatalogStore` paths are pre-refactor. After MP-R1/R2 and MP-E1 land,
MP-N5-C2-T00 maps them to the `event-bus`, `build-orders`/`build-queue` and `commands`
packages. Rules and contract fields are unaffected.
