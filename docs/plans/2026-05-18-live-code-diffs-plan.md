# Live Code Diffs Plan

Created: 2026-05-18
Origin: docs/brainstorms/2026-05-18-live-code-diffs-requirements.md

## Summary

Extend the existing agent-event-to-transcript path with a diff transcript role, parse Codex `turn/diff/updated` unified diffs into compact per-file blocks, and teach the conversation viewport to render those blocks with terminal coloring and truncation.

## Requirements Trace

- R1, R2, R5: add a transcript event for file diffs and render each changed file as a block.
- R3: apply subtle terminal background colors to added and removed rows.
- R4: cap rendered diff body rows with an omitted-line indicator.
- R6: keep raw event logging unchanged and derive the pane view from broadcast transcript events.

## Assumptions

- `turn/diff/updated` is the right Codex live-edit signal for this first implementation.
- Inline truncation satisfies the issue's expand-on-keystroke requirement for the first pass because the full event remains in logs and full expansion is explicitly deferred.

## Implementation Units

### U1: Transcript Diff Event Contract

Goal: Add a first-class transcript role for diff entries and broadcast Codex diff updates.

Files:

- Modify: `elixir/lib/aiur/agent_events.ex`
- Modify: `elixir/lib/aiur/agent_runner.ex`
- Test: `elixir/test/aiur/agent_events_test.exs`
- Test: add or extend an `AgentRunner`-focused test module if needed

Approach:

- Add a `:diff` transcript role with a stable tag name.
- In `Aiur.AgentRunner`, detect `turn/diff/updated` notifications with a non-empty diff payload.
- Emit `AgentEvents.transcript_event(:diff, diff, timestamp: ...)`.
- Preserve the existing assistant and command event behavior.

Test Scenarios:

- A Codex `turn/diff/updated` notification with a diff returns a `:diff` transcript event.
- An empty diff is skipped.
- Command and assistant transcript extraction still works.

### U2: Diff Renderer

Goal: Render unified diff text into compact, per-file transcript rows.

Files:

- Modify: `elixir/lib/aiur_pane/viewport.ex`
- Test: `elixir/test/aiur_pane/viewport_test.exs`

Approach:

- Add a `:diff` branch in `render_event_rows/3`.
- Parse unified diff file headers, hunk headers, context lines, additions, and deletions.
- Convert file status into `Update(path)`, `Create(path)`, or `Delete(path)`.
- Count added and removed lines per file.
- Cap rendered diff body rows and append an omitted-line indicator when needed.
- Apply green background styling to additions and red background styling to deletions.

Test Scenarios:

- Update diff renders path header, added/removed summary, line numbers, context, deletion, and addition rows.
- New file diff renders a create header and added-line summary.
- Deleted file diff renders a delete header and removed-line summary.
- Long diff truncates with an omitted-line row.
- Rendered visible rows stay within the pane width.

### U3: Pane Integration Safety

Goal: Keep the live pane readable and compatible with existing transcript behavior.

Files:

- Modify: `elixir/lib/aiur_pane/viewport.ex`
- Test: `elixir/test/aiur_pane/viewport_test.exs`

Approach:

- Make diff rows command-like sub-events in the transcript so they do not reset assistant tag coalescing.
- Ensure padding and ANSI reset behavior prevents background bleed into later rows.
- Confirm narrow terminal wrapping/truncation behavior remains bounded.

Test Scenarios:

- Diff events do not force repeated assistant tags.
- Addition/deletion background styling is reset before row padding ends.
- Existing viewport tests for users, assistants, commands, alerts, and composer still pass.

## Scope Boundaries

- Do not add side-pane, popup, or interactive expansion controls.
- Do not implement filesystem watching or polling.
- Do not parse shell command output as a diff source.
- Do not alter raw event log persistence.

## Verification

- `mix test test/aiur/agent_events_test.exs test/aiur_pane/viewport_test.exs`
- `mix test`
- `mix specs.check`
- `make all`
- Manual CLI verification: run the conversation pane with synthetic or locally generated diff transcript input and confirm the rendered pane shows the compact diff block.
