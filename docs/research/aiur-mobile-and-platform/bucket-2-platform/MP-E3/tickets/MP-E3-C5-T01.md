---
ticket_id: MP-E3-C5-T01
feature_id: MP-E3
chunk_id: MP-E3-C5
bucket: 2-platform
title: "Executor send adapter over the listener-mode path, capability-gated composer, shared delivery overlay"
status: blocked
blocked_by: [DESIGN-E3, DESIGN-E7, MP-E7-C3-T03, MP-E7-C3-T04, MP-E4-C6-T01, MP-E3-C1-T01]
prior_units: [U8]
prior_boundaries: [EXE, WEB]
prior_features: [MP-E7 (C3 send path, RC-05; C6 Executor hook delivery)]
prior_findings: [RC-05; MP-E7 CR-E7-2 (wave decision); plan acceptance 7]
size_owner: n/a (new module; composer reuses MP-E4's)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C5-T01 — Executor send adapter

## Identity and outcome

- Bucket 2 · MP-E3 · C5 · T01 (the only ticket of C5).
- **User value:** the operator types a message to the Executor in the dashboard;
  it reaches the session at a proven hook boundary, or the composer says exactly
  why it cannot — never a tmux keystroke into a terminal aiur does not own.
- **Deliverable:** `Aiur.Executor.Send` — `capability/0` (`:available |
  {:unavailable, reason}`) and `send/2` (text, client_request_id) calling
  `Aiur.Listener.send/3` with the Executor target; the Executor view's composer
  (MP-E4's `Composer` + `DeliveryOverlay`, reused, not copied); the effective
  mode chip read-only (mode selection is DESIGN-E7's).
- **Wave decision (answers MP-E7 CR-E7-2):** this ticket ships in **wave 3**
  after MP-E7-C3 (RC-05). Until MP-E7-C6 (Executor hook delivery, wave 4) is
  present, `capability/0` returns `{:unavailable, :executor_delivery_not_installed}`
  and the composer is disabled with that reason. When E7-C6 lands, the same code
  lights up with no change here.
- **Non-goals:** delivery mechanics (E7-C6); interrupt/pause controls (D15).

## Dependencies and blockers

- RC-05: MP-E7-C3-T03 (`Aiur.Listener.send/3`) and MP-E7-C3-T04
  (`Aiur.Listener.receipt/2`).
- MP-E4-C6-T01 (composer + overlay modules).
- MP-E3-C1-T01 (binding: no attached session → unavailable).
- DESIGN-E3 (composer copy), DESIGN-E7 (mode indicator; Executor default mode is DESIGN-E7 E7-D8, which answers OQ-E3-3).

## Verified starting point

- Worker composer path today: `send-operator-message` → `AgentChat.send/3`
  (`src/lib/aiur_web/live/dashboard_live.ex:640-661,2655-2693`). There is no
  Executor send path at `45a290e3`.
- `Aiur.Claude.Repl.OperatorInject` types into panes aiur owns via
  `tmux send-keys` (`claude/repl/operator_inject.ex:14-108`); the Executor's pane
  is not aiur's, so this path is forbidden here (plan §2.2, acceptance 7).
- MP-E7-C3-T03: `Aiur.Listener.send(target, text, client_request_id)`; the
  `ConversationRef`/Executor overload arrives with MP-E7-C6 (CR-E7-4).

## Chosen design

- `capability/0`: `:none` binding → `{:unavailable, :not_attached}`; binding not
  live → `{:unavailable, :executor_unreachable}`; `Code.ensure_loaded?` of the
  E7-C6 delivery module false (or its feature check false) →
  `{:unavailable, :executor_delivery_not_installed}`; read-only dashboard →
  `{:unavailable, :read_only}`; else `:available`.
- `send/2` → `Aiur.Listener.send(Conversation.Ref.executor(), text, id)`; result
  and receipts feed `DeliveryOverlay` exactly as for workers; the journal's
  `operator_message` entry for the Executor carries `refs.delivery_id` when
  MP-E7-C6 echoes it in the frame (contract §14, CONTRACT-REQUESTS item 2).
- Effective mode chip: from E7's control capability for the Executor subject;
  absent → "mode unknown".

## Implementation steps

1. `Executor.Send` with `@spec`s.
2. Executor view (C6-T01) renders MP-E4's composer with `capability/0` as the
   enabled flag and the reason text.
3. Static test that no module under `lib/aiur/executor/` or the Executor
   LiveView calls `Aiur.Tmux` or `OperatorInject`.

## Non-happy paths

- Message accepted but Executor idle with no wake route → overlay "waiting until
  the Executor's next turn" (plan §6); never "delivered".
- Executor detached after send → receipt `failed` or `outcome_unknown`; overlay
  shows it.
- Daemon restart with a pending message → `unknown` (queue is in memory, MP-E7
  CR-E7-6).

## Compatibility and rollout

- Disabled composer until E7-C6. Rollback: revert; the view stays read-only.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/executor/send_test.exs test/aiur_web/live/executor_live_composer_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "without E7-C6 the composer is disabled with the reason" | disabled + reason text | capability check (plan acceptance 7) |
| "not attached → disabled with not_attached" | reason | binding branch |
| "send goes through Aiur.Listener.send/3 with the Executor ref" (stub) | stub called with `Ref.executor()` | adapter |
| "refusal keeps the message pending, never delivered" | overlay `failed`/`unknown` | overlay reuse |
| "no Aiur.Tmux or OperatorInject reference on the Executor path" (source scan) | none | — guard (fails if a future change adds one) |

## Completion and handoff

- [ ] CR-E7-2 answered in `MP-E3/chunks.md` (wave 3, disabled until E7-C6).
- Dependents: MP-E3-C6-T01, MP-E5 (mic on the Executor composer), MP-N6.
