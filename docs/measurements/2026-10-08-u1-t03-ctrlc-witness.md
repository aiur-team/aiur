# U1-T03: queued-message Ctrl+C witness

Issue: [#3305](https://github.com/aiur-team/aiur/issues/3305).
Automated checks use source SHA `ea3076b4f02cee57a3b61105604d09372d3f1e9e`.
Integration base: `main`.

## Status and ownership

The live foreground witness is **pending Executor verification after merge**.
The Executor directed this check to run in a quiet batch with the other U1
witnesses because the wrapper-tmux `--test` harness cannot run beside the live
fleet. Agent workspaces must not launch that harness or bypass its guard.
U0-T01 (#3255) is closed with Executor sign-off.

This record changes no product behavior. Automated evidence below does not
establish queued-message delivery exactly once, and no loss or duplication
has been observed. No foreground release SHA/stamp or live captures are yet
available; the source SHA above is not a manually tested release identity.

## Automated evidence

- `bash scripts/verify-ctrlc-binding.sh`: passed all four assertions. The
  shipped tmux configuration routes Ctrl+C to a stub bridge helper and keeps
  the chat pane alive; Ctrl+Q selects hide and also preserves the pane.
  This harness uses isolated tmux servers and does not boot Aiur or deliver M1.
- `mise exec -- mix lint` from `src/`: specs check and strict Credo passed
  across 2,094 source files.
- `python3 scripts/check-bare-assert-receive.py`: passed across 940 test files.
- From `src/`, `mise exec -- mix test --max-cases 4
  test/aiur/orchestrator/interrupts_test.exs
  test/aiur/orchestrator_interrupt_test.exs test/aiur/agent_chat_test.exs`:
  27 tests, 0 failures (seed 528962). Existing tests are used; no new coverage
  is claimed. The run compiled the test application successfully.

Current source anchors: the binding is in
`packaging/npm/aiur-cli/share/aiur.tmux.conf`; the packaged helper is
`packaging/npm/aiur-cli/libexec/aiur-pane-ctrlc`; the controller delegates through
`src/lib/aiur/agent_chat.ex` to `src/lib/aiur/orchestrator/interrupts.ex`.
The helper forwards Escape for `send_interrupt`, keeps the pane for
`interrupted`, `pause_requested`, or `paused`, and otherwise requests hiding.
These source observations are not the foreground witness.

## Executor verification after merge

Use the AGENTS.md wrapper-tmux recipe from the Executor root outside agent
turns. Build and record the release's source SHA and matching build stamp; use
the inner socket/session printed by the foreground launcher.

1. Wait for a running selected agent row and open chat pane `0.1` with Enter.
2. During a turn, enter a unique M1 through the TUI input, then Enter separately.
   Capture M1 displayed as QUEUED before Ctrl+C.
3. Fire the actual bound Ctrl+C key through the attached client. Directly
   sending keys to an inner pane process can bypass tmux bindings; the existing
   binding regression harness demonstrates driving an attached wrapper client.
4. Capture the pane after interruption and after M1 completes. Confirm the
   active pane survives, M1 has exactly one delivered user row, and the agent
   answers M1 once. Preserve sufficient scrollback to detect duplicates.
5. With no turn running, repeat Ctrl+C and capture before/after. Record actual
   idle pane behavior separately from active-turn survival.
6. Save redacted captures, tested SHA/stamp, provider, and outcomes here. Clean
   up the test instance and wrapper. If loss, duplication, or a packaging
   defect appears, file the defect and repair it with a targeted regression test.

Until those captures exist, the live witness remains open. API requests and
logs cannot substitute for rendered TUI observations.
