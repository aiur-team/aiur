---
ticket_id: MP-E6-C4-T06
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: Executor target — project-level conversations with the Executor read port
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T02, MP-E6-C4-T03, MP-E3-C2, MP-E3-C4, MP-E5-C5-T02]
prior_units: []
prior_boundaries: [VOX, EXE]
prior_features: []
prior_findings: []
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C4-T06 — Executor target

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C4.
- **User value:** "talk with the Executor about the overall project" (brief E6): the
  assistant gets the fleet picture and the Executor's recent conversation.
- **Deliverable:** `Aiur.VoiceConversation.Host.ExecutorRead` (PROPOSED) implementing
  `Ports.ExecutorRead` over MP-E3's Executor snapshot (MP-E3-C4: harness state, background
  agents, blockers) and the Executor conversation (MP-E4 `list_entries` on the Executor
  `ConversationRef`); session start accepts `%{kind: "executor", instance_id}` once
  `executor.conversation` is available (same validation as MP-E5-C5-T02).

## Dependencies and blockers

- **Predecessors:** MP-E3-C2 (Executor conversation journal), MP-E3-C4 (Executor status
  snapshot), MP-E5-C5-T02 (`VoiceTargets` executor rule), C4-T02/T03.

## Verified starting point (base `45a290e3`)

- No Executor read API exists at the base (baseline E3). Interfaces are those planned in
  `MP-E3/chunks.md` C2/C4 and the conversations contract §7.

## Chosen design

- `status(%{kind: :executor})` → MP-E3 snapshot (state with TTL → `unknown`, blockers by
  source with per-source availability); `recent_messages` → Executor conversation tail (20);
  `open_commands` → all open Commands: count + top 5 by age.
- Unknown Executor state passes through as "unknown" in the context (never "idle"; MP-E3's
  mutation guard rule).

## Implementation steps

1. Host module; 2. target validation in session start; 3. tests with stub E3/E4 APIs.

## Non-happy paths

- Executor absent → start refused `target_not_found`; Executor not managed →
  `target_not_writable` (instructions cannot be delivered; DESIGN-E6 may still allow a
  discussion-only session — recorded as owner note, default refuse).
- E4 absent → no Executor conversation block; gap stated.

## Compatibility and rollout

Additive. Rollback: revert (executor target refused again).

## Verification

| Test | Expected |
| --- | --- |
| "an executor session gets fleet status and the Executor conversation tail" | context blocks present |
| "an unknown Executor state is stated as unknown" | context contains "unknown", not "idle" |
| "executor_absent refuses with target_not_found" | start error |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/executor_read_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Map `:unknown` to `"idle"`: the unknown test fails.

## Completion and handoff

- [ ] Executor sessions start with project context.
- **Dependents:** C7-T02 (Executor panel), MP-N6 Executor chat.
