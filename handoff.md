# opencode Pane Handoff

## Branch

- Current branch: `aiur/60-opencode-pane-chat`
- Latest pushed commits:
  - `a7ae352 Add opencode configuration`
  - `3b9c4b0 Add opencode bridge`
  - `6948907 Cut over panes`
  - `ec5385e Document opencode panes`
- Worktree was clean after these commits were pushed.

## What Is Finished

- Merged latest `origin/main` into this branch after the pane layout work landed.
- Added `opencode:` workflow config schema and `Aiur.Opencode.Config`.
- Added `Aiur.Opencode.Protocol` as the opencode-specific config/message-shape boundary.
- Added a `Req`-based opencode API client.
- Added the Aiur bridge HTTP surface:
  - `GET /v1/health`
  - `POST /v1/chat/completions`
  - bearer-token auth through `Aiur.Opencode.TokenRegistry`
  - OpenAI-compatible streaming chunk builder
- Added opencode pane orchestration modules:
  - `Aiur.Opencode.Server`
  - `Aiur.Opencode.WorkspaceSetup`
  - `Aiur.Opencode.PaneSession`
  - `Aiur.Opencode.PaneSupervisor`
  - `Aiur.Opencode.TranscriptRelay`
  - placeholder `Aiur.Opencode.EventConsumer`
- Wired opencode supervision into `Aiur.Application`.
- Threaded `turn_id` through operator message queueing and agent transcript/turn broadcasts so bridge streams can filter and close on the matching turn.
- Cut default pane opening over to opencode through the existing `Aiur.PaneManager` layout path.
- Removed the old in-process pane code:
  - `AiurPane.*`
  - `Aiur.PaneRPC`
  - `Aiur.PaneWarmPool`
  - old pane tests
- Updated docs:
  - root `README.md`
  - `SPEC.md`
  - `elixir/README.md`
  - `elixir/WORKFLOW.md`
  - `elixir/AGENTS.md`
  - `elixir/docs/opencode-pane-brainstorm.md`
  - plan status set to `completed`

## Validation Already Run

- `mise exec -- mix test`
  - last successful result: `541 tests, 0 failures, 2 skipped`
- `mise exec -- mix specs.check`
  - passed
- `mise exec -- mix compile --warnings-as-errors`
  - passed for each commit group during split
- `mise exec -- mix format --check-formatted`
  - passed
- `git diff --check`
  - passed

## Important Remaining Work

### 1. Real opencode dependency setup

Manual testing was paused because `opencode` is not installed on this machine. The user correctly pointed out that if opencode is now required for the CLI pane feature, setup should handle it.

Recommended next step:

- Add opencode to the project setup path, probably through `mise.toml` if supported.
- Make `scripts/aiur` verify/install or fail early with a clear install instruction before launching interactive mode.
- Keep `Aiur.Opencode.Config.validate!/0` as the app-level guard.

Do not use a fake opencode binary for final verification. The user explicitly asked to use the real thing until it works.

### 2. Manual end-to-end CLI verification

After real opencode is available, run the actual Aiur command path:

- Use `scripts/aiur` with a real or temporary workflow.
- Let it launch its own tmux session.
- Open an agent from the agent list with `Enter`.
- Confirm a pane is created.
- Confirm the pane runs `opencode attach ...`.
- Confirm no crash happens in `PaneManager`, `PaneSession`, or `Opencode.Server`.

The user reported: "at the moment, agent panes no longer open". Treat that as the top bug to reproduce.

### 3. Potential issue to inspect first

`PaneManager.command_for_pane/2` currently calls `Aiur.Opencode.PaneSession.start/2` synchronously before splitting/respawning the tmux pane. If `opencode serve` startup blocks/fails, pane opening fails before any visible placeholder appears.

The plan wanted a placeholder shell during cold start. That part is not fully implemented. If panes do not open, likely fix direction:

- Split/respawn immediately with a small loading shell.
- Start `PaneSession` asynchronously.
- When ready, send/exec the real `opencode attach` command.
- If startup fails, leave an operator-visible error in the pane.

### 4. Bridge/session hardening still likely needed

The first implementation is functional scaffolding, but some plan details are not fully done:

- queued-pane retry behavior in `ChatCompletions`
- real opencode SSE event consumer behavior
- orphan opencode process reap/identity validation
- full transcript dedup by `{timestamp, sequence}`
- bind-failure operator alert flow
- real opencode API endpoint shape validation against current opencode

## User Preferences Going Forward

The user wants this work cycle:

1. Implement a small task.
2. Add/update/run necessary tests.
3. Run.
4. Build or compile.
5. Run lint and fix issues.
6. Commit in very small concise commits.
7. Commit messages should be about three to seven words.
8. Push each task as it is completed.

The user also wants manual CLI verification before being told the feature is complete.
