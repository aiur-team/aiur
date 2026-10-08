---
ticket_id: MP-E2-C5-T03
feature_id: MP-E2
chunk_id: MP-E2-C5
bucket: 2-platform
title: Release Claude native questions on multi-call turns and lost sessions
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C5-T02]
prior_units: [U4, U6]
prior_boundaries: [CLD #22, DEC #27]
prior_features: [MP-R7]
prior_findings: [R-Q2 Q5 (multi-call), plan §1.4 ("defer only works for a single tool call"), contract §7.3]
size_owner: "n/a — logic in commands/native_capture/claude.ex and the sibling module"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C5-T03 — Release Claude native questions on multi-call turns and lost sessions

## Identity and outcome

- Bucket 2, MP-E2, chunk C5.
- **User value:** no Claude question is ever silently lost — when the hold cannot work
  (several tool calls in one step, the sibling restarted, the CLI session vanished), the
  agent is told its question is Command X and the answer comes as a message.
- **Deliverable:**
  1. Sibling: detect the multi-call shape C5-T00 Q5 recorded and send
     `item/tool/requestUserInput` with `params.holdable: false`; aiur creates the Command
     and immediately releases (contract §7.3).
  2. aiur: `native_released{reason: :not_holdable | :session_gone}`; `native.hold` →
     `:released`; later answers by message.
  3. Boot/restart: Claude Commands with `hold: :deferred` whose session is not known to
     the current `aiur-claude` process are marked released at first contact
     (`reply` → `{:error, :session_gone}`).
- **Non-goals:** making headless Claude resumable across restarts (`resumable: false`,
  `providers/claude.ex:34-40`; out of scope).

## Dependencies and blockers

- **DESIGN-E2**; C5-T02. Uses C4-T04's release module.

## Verified starting point

- aiur `src/lib/aiur/coding_agent/providers/claude.ex:34-40` (thread map in memory; no
  disk resume through `thread/start`).
- aiur `src/lib/aiur/decision_store.ex:4562-4601` (`schedule_pending_answer_delivery`):
  answers that miss the old worker are redelivered as messages to the next worker (#2713).
- Sibling `src/server.ts:882-927` result handling (where a multi-call result arrives).

## Chosen design

- `holdable: false` → `NativeCapture.capture/2` still records the Command, then C4-T04's
  `Release.release_all/3` runs at once with `reason: :not_holdable` (the release text
  tells the agent to end its turn).
- `{:error, :session_gone}` from a Claude reply → `native_released{reason:
  :session_gone}` and the queue item proceeds as an ordinary message (C4-T03 fallback).
- Invariant N1: no path closes the Command.

## Implementation steps

1. Sibling: `holdable` flag in the request (C5-T01 module).
2. `commands/native_capture/claude.ex`: `holdable: false` branch.
3. Tests.

## Non-happy paths

- The sibling sends `holdable: false` but aiur's store is unavailable → today's
  non-interactive answer (C4-T01 error branch).
- Repeated deferred → resume → deferred loops: each re-fire carries the same question ids;
  `source_id` (`native:<ref>`) dedups to one Command.

## Compatibility and rollout

- Same gate as C5-T02.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/commands/native_capture/claude_test.exs
npm --prefix /home/everdred/github/everdred/claude-app-server test
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "holdable false creates the Command and releases immediately" | Command open; release frame written; `native.hold == :released` | step 2 |
| "session_gone reply records native_released and falls back to a message" | fact recorded; message queued | fallback |
| "re-fired deferred question maps to the same Command" | one Command, `:duplicate` | `source_id` |
| sibling "multi-call stream sets holdable false" | request params `holdable: false` | step 1 |

Mutation check per row.

## Completion and handoff

- [ ] Both lose-paths release; Command stays open.
- Docs: `concepts/commands.md` (C8-T01) lists when a question is released.
- Dependents: C8-T04.
