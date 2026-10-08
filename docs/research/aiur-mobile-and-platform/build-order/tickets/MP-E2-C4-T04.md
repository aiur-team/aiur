---
ticket_id: MP-E2-C4-T04
feature_id: MP-E2
chunk_id: MP-E2-C4
bucket: 2-platform
title: Release held native questions on timeout, pause, interrupt and exit
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T02, MP-E2-C2-T02]
prior_units: [U4, U6]
prior_boundaries: [RUN #18, CDX #21, DEC #27]
prior_features: [MP-R7 (release_native_question/3)]
prior_findings: [contract §7.3, invariant N1, harness-adapter §6 item 6]
size_owner: "AGENT_CORE (app_server/turn_loop.ex 152; app_server/interrupts.ex 76) — small guards; logic in commands/native_capture/release.ex"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C4-T04 — Release held native questions on timeout, pause, interrupt and exit

## Identity and outcome

- Bucket 2, MP-E2, chunk C4.
- **User value:** a held question never strands an agent and never disappears: if aiur
  must end the wait, the agent is told the question is recorded as Command X and the
  answer will come as a message — and the Command stays open for you.
- **Deliverable:** release on (a) receive-loop idle timeout, (b) `{:pause_agent, …}`,
  (c) operator-initiated interrupt, (d) port exit (record only); `native_released`
  fact via `record_command_fact/4`; `native.hold` projected to `:released`.
- **Non-goals:** Claude release (C5-T03).

## Dependencies and blockers

- **DESIGN-E2**; C4-T02 (hold); C2-T02 (`record_command_fact/4`). Add the
  `native_released` type to `Aiur.Commands.EventData` here (status-neutral; projection
  sets `native.hold = :released`).
- **Must merge before anyone enables `decisions.native_capture.codex`.**

## Verified starting point (`45a290e3`)

- `src/lib/aiur/app_server/turn_loop.ex:22-29` pause messages → `Interrupts.handle_pause_request/3`
  (`app_server/interrupts.ex:8-33`); `:48-50` `after state.timeout_ms -> {:error, :turn_timeout}`;
  `:131-151` port exit.
- `src/lib/aiur/codex/turn_loop.ex:35-70` `turn/failed` and `turn/cancelled` handling
  (fails pending operator requests).
- Pause reasons that self-pause for input: `orchestrator/pause_resume.ex:36`
  (`@input_pause_reasons [:agent_pause_request, :input_required]`).

## Chosen design

- PROPOSED `Aiur.Commands.NativeCapture.Release.release_all(state, reason, writer)`:
  for each held ref → write the release answer (every question answered with
  `NativeCapture.release_text(decision_id)`), emit `:native_question_resolved`
  (`reason`), and call `DecisionStore.record_command_fact(id, :native_released,
  %{native_ref, reason, at})` asynchronously (`Task.start/1`; the turn loop must not block
  on the store). Returns state with `held_native_questions: %{}`.
- Hooks:
  - (a) `after state.timeout_ms` with held questions: release, then **continue** the loop
    once more (`receive_loop(session, released_state)`) so the model can end its turn;
    a second idle timeout returns `{:error, :turn_timeout}` as today.
  - (b) pause: release before `Interrupts.handle_pause_request/3` proceeds.
  - (c) `turn/cancelled` / `turn/failed` / operator interrupt: release (if the port is
    alive) before failing pending operator requests.
  - (d) port exit: cannot write; record `native_released{reason: :session_gone}` only.
- Reason atoms: `:idle_timeout | :pause | :interrupt | :turn_ended | :session_gone`.
- Invariant N1: no release path changes `decision_status`; the Command stays open; later
  answers go by message (C4-T03 fallback).

## Implementation steps

1. `commands/native_capture/release.ex` (≈90 lines); `native_released` in `EventData` and
   `Projection`; slug `native-released`.
2. `app_server/turn_loop.ex`: `after` branch guard + one extra loop.
3. `app_server/interrupts.ex`: release in pause path.
4. `codex/turn_loop.ex`: release in cancelled/failed paths.
5. Port-exit path: record-only call in `app_server/turn_loop.ex:146-151`.

## Non-happy paths

- Store unavailable when recording `native_released`: logged; the Command keeps
  `hold: :in_band` in the projection, so C4-T03 tries in-band, finds no holder, and falls
  back to a message — still correct.
- Release write fails (port closed between check and write): treat as (d).
- Pause during an in-band reply race: whichever reaches the port first wins; the other
  sees the ref gone (`:not_pending`) and does nothing.

## Compatibility and rollout

- Only active with held questions (gate on). No config.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/native_capture/release_test.exs test/aiur/app_server/interrupts_test.exs \
  test/aiur/app_server/adapter_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "idle timeout with a held question writes release text and continues one more cycle" | release frame written; loop not returning `:turn_timeout` on the first expiry | step 2 |
| "pause releases before pausing" | release frame precedes the interrupt frame | step 3 |
| "port exit records native_released session_gone" | fact recorded with `reason: :session_gone`; no write attempted | step 5 |
| "release keeps the Command open" | `decision_status == :open`, `native.hold == :released` | projection clause |
| "answer after release is delivered as a message" (integration) | operator message queued, not an in-band frame | C4-T03 fallback with released hold |

Mutation check per row. Manual (wrapper-tmux): with the C4-T02 scratch config and
`agent.turn_timeout_ms: 120000`, let a held question idle; capture pane `0.1` and see the
release text as the tool result and the agent ending its turn; `/commands` still lists the
Command as open.

## Completion and handoff

- [ ] Four release hooks; Command never closed by a release.
- Docs: `concepts/commands.md` (C8-T01) describes release.
- Dependents: C4-T05 (enable only after this), C5-T03, C8-T04.
