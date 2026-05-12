# Agent Chat Handoff

## Current Branch

- Branch: `symphony/agent-chat-ui`
- Latest commit before this handoff: `efb8308 Wire agent chat controls`
- Scope shipped in the draft PR: first-pass CLI/dashboard message composer and pause button plumbing.

## What Changed

- Added `SymphonyElixir.AgentChat` as a facade for sending text messages and pause requests to running agents.
- Added Orchestrator APIs to route operator text and pause requests to the running agent task by issue identifier.
- Added CLI conversation mode:
  - `space`, `enter`, or `i` opens the selected agent conversation.
  - `Enter` sends the typed message.
  - `Alt-Enter` inserts a newline.
  - `Esc` or `Ctrl-C` exits back to the agent list only.
  - `Ctrl-C` from the agent list exits the CLI process.
- Added dashboard modal controls:
  - textarea composer
  - Send button
  - Pause button
- Updated `scripts/agents stop` so it also targets foreground interactive Symphony processes.

## Important Limitation

The current implementation still queues messages at the runner boundary. It does not fully implement interactive chat while the active agent turn is running.

The next design should treat this as generic agent inbox/control-plane messaging, not as user-only chat:

- operator/user message is one source
- another agent can later be another source
- PubSub/event rules can later be another source
- message envelopes should carry source/kind/body/metadata, not UI-specific fields

## User Direction For Next Work

The user explicitly wants:

- Do not pause on `Ctrl-C`.
- `Esc` and `Ctrl-C` in an agent conversation should only return to agent selection.
- Pressing them again from agent selection should kill the CLI.
- Remove the separate state of viewing an agent log without being in insert/chat mode.
- Once an agent is selected/opened, the CLI should show the log and always let the user type/chat.
- Full interactive chat should not wait for a whole Symphony continuation turn.
- If a message arrives while the agent is running, the agent should receive it promptly, or finish the current atomic task and pause before its next thought/action.

## Suggested Brainstorm Direction

Use `ce-brainstorm` before implementing the full interactive model. The likely requirements artifact should clarify:

- What counts as an interruptible boundary: model token, app-server event, tool start/end, command approval, turn completion.
- Whether incoming messages should cancel/interrupt the current turn, start a concurrent turn, or mark "pause after current tool/event."
- How agent-to-agent and PubSub-originated messages should be represented.
- Whether "pause" remains a user-facing control, or becomes an internal queue/backpressure state.
- What delivery guarantees are expected: best-effort, at-least-once, or ordered per agent.
- What the UI should show while a message is pending delivery to a live turn.

## Validation Run

Passed:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix specs.check`
- `git diff --check`
- Targeted tests:
  - `test/symphony_elixir/terminal_input_test.exs`
  - `test/symphony_elixir/orchestrator_status_test.exs:901`
  - `test/symphony_elixir/extensions_test.exs`
  - `test/scripts_agents_test.exs`
  - `test/symphony_elixir/agent_chat_test.exs`
  - log-pane snapshot focused tests at lines 247, 255, 273

Full `make all` through mise reached lint/coverage but failed on broader snapshot baseline mismatches in `status_dashboard_snapshot_test.exs`. Coverage was restored to 100% after adding `agent_chat_test`.
