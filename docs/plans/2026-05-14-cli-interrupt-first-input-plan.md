---
title: CLI interrupt-first input and cached composer rendering
type: fix
status: completed
date: 2026-05-14
origin: docs/brainstorms/2026-05-14-cli-pending-input-and-operator-delivery-requirements.md
branch: symphony/agent-pubsub
---

# CLI interrupt-first input and cached composer rendering

## Summary

Rework the current CLI chat attempt around the May 14 handoff model: local typing must render immediately from cached dashboard state, submitted text must enter the visible queued-input buffer, and delivery should prefer interrupt-first semantics instead of passive checkpoint delivery. This plan preserves the existing `AgentChat`, `AgentQueue`, and adapter control plumbing where it is useful, but treats the current checkpoint-first user experience as the part to replace.

## Origin Requirements

Source: `docs/brainstorms/2026-05-14-cli-pending-input-and-operator-delivery-requirements.md`

- Typing in the CLI composer must not wait for snapshot refresh, log parsing, or normal dashboard render throttling.
- Enter must keep the main log body and top chrome visually stable during submission.
- Submitted text must immediately appear in the grey queued-input section, preserving FIFO ordering for rapid submissions.
- Operator delivery should be interrupt-first from the user's perspective, with backend queueing as fallback plumbing.
- Queued input should drain only when delivery is confirmed by the runtime or canonical log path.
- Pause and resume must stay compatible; pausing before typing must not be the only reliable path.
- PubSub and broader event architecture remain out of scope.

## Current Code Context

- `elixir/lib/symphony_elixir/status_dashboard.ex` owns the CLI log pane, composer state, queued-input rendering, and render throttling.
- `elixir/lib/symphony_elixir/terminal_input.ex` already sends key events into `StatusDashboard`, including bracketed paste and submit.
- `elixir/lib/symphony_elixir/agent_chat.ex` defaults to checkpoint delivery today; this conflicts with the revised interrupt-first model.
- `elixir/lib/symphony_elixir/orchestrator.ex`, `AgentQueue`, and `AgentQueueStore` already represent pending/delivered/consumed operator messages.
- `elixir/lib/symphony_elixir/agent_runner.ex` already has safe-checkpoint delivery, pause handling, and queued operator message draining.

## Assumptions

- A cached-frame immediate render path is sufficient for this branch's "separate composer rendering" goal because it avoids snapshot refresh and render throttling on local edits while preserving the existing terminal frame renderer.
- Full terminal overlay/compositor work is deferred unless cached rendering still visibly blocks in manual testing.
- Existing queue storage can remain in memory for this branch; durability beyond the active orchestrator process is not required by the May 14 requirements.

## Key Decisions

- Extend the current dashboard renderer rather than introduce a separate TUI process. Local composer edits should render from the last known snapshot and bypass normal throttle.
- Change `AgentChat.send/2` to request interrupt delivery by default with queue-next fallback.
- Keep the grey queued-input section backed by `AgentQueueStore.list_visible_operator_messages/2`, but make submitted text visible before the next polling tick.
- Replace paused-state pending clearing with canonical confirmation: a pending composer request clears only when the matching queue item is no longer visible or when an operator/user echo appears in the log.
- Keep web and HTTP behavior mechanically compatible with the shared facade, but do not redesign the web composer in this branch.

## Scope Boundaries

In scope:
- CLI composer render responsiveness.
- Interrupt-first send default and fallback behavior.
- Pending queued-input drain semantics.
- Regression tests for rapid submit, visual stability signals, and pending clearing.

Out of scope:
- PubSub or cross-agent coordination events.
- Rich retry controls or queue history UI.
- New persistence for queue state.
- A separate terminal rendering engine unless the smaller cached-frame path proves insufficient.

## Implementation Units

### U1: Cached Composer Render Path

Goal: Local typing, backspace, and submit render immediately without waiting for snapshot refresh or dashboard throttle.

Files:
- Modify `elixir/lib/symphony_elixir/status_dashboard.ex`
- Test `elixir/test/symphony_elixir/status_dashboard_view_test.exs`
- Test `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`

Approach:
- Store the latest successful snapshot payload on the dashboard state.
- Add an immediate render path for local composer updates that formats from cached snapshot data and bypasses `render_interval_ms`.
- Preserve the existing full render path for ticks, external refreshes, list navigation, and log-pane open/close.
- Ensure submit invalidates only the composer/queued area, not the selected log pane or top chrome.

Test scenarios:
- Appending several characters emits renders immediately even when `render_interval_ms` is high.
- Backspace uses the same immediate render path.
- Enter on a non-empty composer keeps log view state open and clears the composer buffer.
- Empty submit does not force a redraw.

Verification:
- `mix test test/symphony_elixir/status_dashboard_view_test.exs`
- `mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`

### U2: Interrupt-First Send Default

Goal: Ordinary operator send should request immediate interrupt-capable delivery when supported and queue-next fallback when not.

Files:
- Modify `elixir/lib/symphony_elixir/agent_chat.ex`
- Test `elixir/test/symphony_elixir/agent_chat_test.exs`
- Test `elixir/test/symphony_elixir/orchestrator_status_test.exs`

Approach:
- Change the default delivery policy in `AgentChat.send/3` from checkpoint to interrupt.
- Set the default fallback to `:queue_next`.
- Keep explicit caller options honored so tests and future callers can request checkpoint delivery deliberately.

Test scenarios:
- Default send accepts interrupt-capable running agents.
- Default send falls back to checkpoint queueing when interrupt is unavailable.
- Explicit checkpoint delivery still works.

Verification:
- `mix test test/symphony_elixir/agent_chat_test.exs test/symphony_elixir/orchestrator_status_test.exs`

### U3: Queue Drain Confirmation

Goal: The grey queued-input section disappears only after the queue item is consumed or a canonical operator/user log echo confirms acceptance.

Files:
- Modify `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify `elixir/lib/symphony_elixir/agent_queue_store.ex` only if status visibility rules need adjustment
- Test `elixir/test/symphony_elixir/status_dashboard_view_test.exs`
- Test `elixir/test/symphony_elixir/agent_queue_test.exs`

Approach:
- Track the submitted request id in composer state until the queue item is no longer visible or the log contains an accepted operator/user message.
- Remove the current paused-state shortcut that clears pending status without delivery/log confirmation.
- Keep delivered-but-not-consumed items visible as "sending" so the UI is honest during in-flight acceptance.

Test scenarios:
- Paused state alone does not clear pending composer status.
- Consumed queue item clears pending composer status.
- Delivered item remains visible as "sending".
- Rapid multiple queued messages render in FIFO order.

Verification:
- `mix test test/symphony_elixir/status_dashboard_view_test.exs test/symphony_elixir/agent_queue_test.exs`

### U4: Snapshot Fixtures And Smoke

Goal: Lock down the CLI frame shape after the render and queue behavior changes.

Files:
- Update `elixir/test/fixtures/status_dashboard_snapshots/*.snapshot.txt` only for intentional UI output changes
- Update matching `.evidence.md` files only if fixture evidence changes

Approach:
- Run the existing snapshot tests after U1-U3.
- Update fixtures only when the new output reflects the revised requirements.

Test scenarios:
- `log_pane_with_queued_input` still shows grey queued input.
- `log_pane_at_bottom` still preserves the log pane and composer.
- Tiny terminal fallback still degrades gracefully.

Verification:
- `mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`

## Deferred To Follow-Up Work

- A true terminal overlay/compositor for composer-only repainting.
- Durable queue persistence across orchestrator restarts.
- Web composer redesign around the revised interrupt-first UX.
- PubSub or cross-agent queue semantics.
