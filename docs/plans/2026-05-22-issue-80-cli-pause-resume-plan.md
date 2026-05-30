---
title: Issue 80 CLI pause/resume commands
status: completed
created: 2026-05-22
issue: 80
---

# Issue 80 CLI Pause/Resume Commands

## Problem Frame

Operators can pause and resume agents from the dashboard and agent-list UI, but not from a non-interactive shell. Issue #80 asks for `scripts/aiur` commands that target issue IDs, support multiple IDs and `--all`, report per-target outcomes, and fail cleanly when Aiur is not running.

## Scope Boundaries

- In scope: cooperative pause/resume over the existing `Aiur.AgentChat` and `Aiur.Orchestrator` control paths, plus concise `aiur status` output.
- In scope: stable release distribution settings for parent Aiur processes so release RPC can reach the node.
- Out of scope: hard process stop/kill, persisted paused state across restarts, dashboard changes, and a new HTTP API.

## Key Decisions

- Use the preferred release RPC path, but keep user-facing output and exit-code policy in `scripts/aiur`. A remote Elixir helper will print structured result lines and an internal exit marker that the shell wrapper filters.
- Resolve numeric issue targets against both plain identifiers and GitHub-style identifiers ending in `#<id>`, then call the existing control APIs with the canonical identifier.
- Store the distribution cookie under the existing Aiur state directory so foreground and background launches share a stable per-host cookie without relying on global shell state.

## Implementation Units

### U1: Release Distribution and Shell CLI

Files:

- `scripts/aiur`
- `elixir/test/scripts_aiur_test.exs`

Approach:

- Add `pause`, `resume`, and `status` subcommands before profile dispatch.
- Parse target lists from space-separated and comma-separated arguments; accept `--all`; reject non-integer IDs.
- Ensure the release is built, configure `RELEASE_DISTRIBUTION`, `RELEASE_NODE`, and `RELEASE_COOKIE`, invoke release `rpc`, filter the internal exit marker, and print a clear no-daemon error when RPC cannot connect.
- Apply the same distribution environment before foreground and fallback background starts.

Test Scenarios:

- `pause 44 45,46` produces a single RPC call with `["44", "45", "46"]`.
- `pause --all`, `resume --all`, and `status` call the expected remote helpers.
- Invalid IDs exit 64 and do not call RPC.
- RPC connection failure exits non-zero with a clear error.

### U2: Orchestrator Status and Control Helper

Files:

- `elixir/lib/aiur/agent_chat.ex`
- `elixir/lib/aiur/orchestrator.ex`
- `elixir/lib/aiur/agent_control_cli.ex`
- `elixir/test/aiur/agent_chat_test.exs`
- `elixir/test/aiur/orchestrator_status_test.exs`

Approach:

- Add `AgentChat.resume/1` for API symmetry.
- Add `Orchestrator.status/0` returning simple maps for running, paused, and idle known agents.
- Add a small remote-control helper that handles `:all`, idempotence, target resolution, per-ID summaries, and the "all targets failed" exit marker.

Test Scenarios:

- Status includes running, paused, and idle entries with stable identifiers and states.
- Pausing an already-paused agent reports a no-op.
- Pause then resume against a fake running entry sends the expected control messages and updates status when the worker reports state changes.

### U3: Documentation and Verification

Files:

- `elixir/README.md`

Approach:

- Document `aiur status`, `aiur pause`, `aiur resume`, multi-ID forms, `--all`, and the cooperative nature of pause.
- Manually run the CLI against a local Aiur process before opening a draft PR.

Verification:

- `mix test` for changed test files.
- `mix compile`.
- `mix lint` or the repo lint alias.
- Manual CLI pause/resume/status check before PR creation.

## Complexity Routing

- Signal: `complexity:3`
- Skills used: `ce-plan` -> `ce-work` -> `ce-code-review`
- Rationale: The change crosses shell release startup, Elixir orchestrator state, and tests, but stays inside one operator-control subsystem.
- Adjustment: Staying on the complexity:3 path; no brainstorm needed because issue #80 already defines the behavior and preferred IPC option.
