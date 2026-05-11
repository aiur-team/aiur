# Symphony Handoff — Chat-send WIP

This branch (`symphony/agent-chat-send`) is mid-implementation of the chat-send feature. Two foundational phases are shipped; seven more phases remain. The plan is the resumption point.

## Quick orientation

- **Plan:** [`docs/plans/2026-05-11-feat-agent-chat-send-plan.md`](docs/plans/2026-05-11-feat-agent-chat-send-plan.md) (688 lines, deepened with reviewer feedback)
- **Brainstorm:** [`docs/brainstorms/2026-05-11-cli-and-web-chat-send-brainstorm.md`](docs/brainstorms/2026-05-11-cli-and-web-chat-send-brainstorm.md)
- **Branch:** `symphony/agent-chat-send` (cut from `main` post-PR-#12)
- **Remote:** pushed; track with `git fetch origin symphony/agent-chat-send`

## Resume command

```bash
git checkout symphony/agent-chat-send
git pull origin symphony/agent-chat-send
```

Then in Claude Code:

```
/ce:work docs/plans/2026-05-11-feat-agent-chat-send-plan.md
```

The skill will pick up Phase 2 next (Phase 0 and Phase 1 are already complete — see commit log).

## What ships in `main` already (context)

- **PR #10** (commit `4ac6526` on main): interactive agent selection in the CLI dashboard. Established `--interactive` flag, `TerminalInput`, `selected_index` plumbing.
- **PR #12** (commit `3b3ebc4` on main): agent log pane in CLI dashboard. Established the `:list | {:log, log_view()}` view state machine, `SymphonyElixir.AgentLog` shared parser, and the placeholder input row this feature replaces.

## Phases status

| Phase | Status | Commit (if shipped) | Notes |
|---|---|---|---|
| 0 — Bracketed-paste mode in CLI | ✅ shipped | `00b62ab` | `\e[?2004h` enable on raw mode, `\e[?2004l` on restore; CSI parser detects `\e[200~ … \e[201~` framing and drops bytes between (since no `:typing` mode yet to consume them). Test verifies pasted `j`/`k` bytes do NOT dispatch as nav commands. |
| 1 — CodingAgent callback + Codex/Claude adapters | ✅ shipped | `896cc25` | New `@callback send_operator_message(session, %{kind: :text, body: String.t()}) :: {:ok, integer()} \| {:error, term()}` on `SymphonyElixir.CodingAgent`. Both adapters implement it via `Port.command` writing a `"turn/start"` frame with a fresh `:erlang.unique_integer` id. **Fire-and-forget**: returns `:ok` after the port write succeeds; does NOT call `await_response`. See "Plan deviation" below. |
| 2 — AgentRunner between-turns control channel | ⏳ pending | — | Refactor `agent_runner.ex` `run/3` from `with`-chain into `drive_session/3` with `receive` + `after 0`. Queue `{:operator_message, payload, from}` (cap 8, `{:error, :queue_full}` on overflow), drain between `run_turn` calls by calling `CodingAgent.send_operator_message/2`. Graceful drain on Task exit. **Medium-Large effort.** Plan: §Phase 2. |
| 3a — Orchestrator + AgentChat public API | ⏳ pending | — | `Orchestrator.send_operator_message(identifier, payload)` with `GenServer.call` (5s timeout, reverse lookup `identifier → issue_id`). New `SymphonyElixir.AgentChat.send/2` one-function facade. Input cap (8000 chars) + `String.trim/1`. Plan: §Phase 3a. |
| 3b — HTTP send endpoint | ⏳ pending | — | `POST /api/v1/:identifier/messages` in `observability_api_controller.ex`. Audit log with `source: :http`. Add `accepts_operator_message: boolean` to `GET /api/v1/:identifier` response. Plan: §Phase 3b. |
| 3c — Security | ⏳ pending | — | Doc + small code: input cap, optional rate limit, audit log entries from all three surfaces (CLI/web/HTTP). Plan: §Phase 3c. |
| 4 — CLI typing sub-mode in StatusDashboard | ⏳ pending | — | **Largest phase.** Add `:mode (:browsing \| :typing)`, `composer()` struct (`buffer`, `cursor`, `submit_token`, `pending_request_id`, `last_error`) to `log_view`. New casts: `enter_typing/exit_typing/append_text/backspace/cursor_move/submit_message/submit_failed/echo_received`. Per-agent drafts map. Composer renderer (multi-line, sticky to bottom of pane, sending/error indicator). 6 new snapshot fixtures: `composer_browsing`, `composer_typing_empty`, `composer_typing_multiline`, `composer_sending`, `composer_error`, `composer_finished_agent`. Plan: §Phase 4. |
| 5 — TerminalInput nav/text mode | ⏳ pending | — | Local `:nav \| :text` flag. `i` enters text (only if cached snapshot's `accepts_operator_message` for selected agent is true — avoid the `i`-in-list-view wart). Text-mode bindings: printable→`{:append_text, byte}`, backspace, `\e[D/C` cursor, `\e[H/F` home/end, `\e[A/B` swallowed, `\e\r` newline (Alt-Enter), `\r`/`\n`→`:submit_message`, bare `\e`→exit typing, bracketed paste→`:append_text`. Ctrl-C still exits Symphony. Plan: §Phase 5. |
| 6 — Web composer in LiveView modal | ⏳ pending | — | First `<form>` in the LiveView app. `phx-submit="send-operator-message"`, `<textarea>` with `phx-change` debounced 200ms + `phx-hook="ChatComposer"` for Enter/Shift+Enter + auto-grow. `enterkeyhint="send"` for mobile. Optimistic stream insert with `temp_id` per Phoenix's syncing-changes guide. Per-agent drafts in socket assigns. `phx-disable-with="Sending…"` on the Send button (do NOT disable the textarea — focus theft). New file `assets/js/hooks/chat_composer.js`. New CSS classes following the existing `.chat-log-panel` / `.modal-panel` convention. Plan: §Phase 6. |
| 7 — Echo & error feedback (cross-cutting) | ⏳ pending | — | Token-matched echo clearing (no 5s safety timer). Composer error rendering — CLI: gray/red line below; web: `<p class="agent-chat-error">` above. Disabled state for finished agents. Plan: §Phase 7. |
| 8 — Tests | ⏳ pending | — | Aggregated across phases — see plan §Phase 8 for the integration-test scenario list. |
| 9 — Manual smoke + open PR | ⏳ pending | — | Run `agents` in real Termius, exercise all key paths (open pane → `i` → type → Enter → see echo → switch agent → draft persists → web modal → HTTP curl). Open PR against main. Plan: §Phase 9. |

## Plan deviation in Phase 1

The plan as written (§Phase 1a) prescribed a per-port `%{request_id => from}` id-router refactor, migrating existing `initialize`/`thread_start`/`start_turn` callers to it as part of this PR. The architect reviewer pushed hard for this.

I shipped a simpler **fire-and-forget** path instead: the new `send_operator_message/2` allocates a fresh `:erlang.unique_integer([:positive])` id, writes the JSON-RPC frame, returns `{:ok, request_id}`, and never calls `await_response`. The canonical `userMessage` echo from the agent's event stream is the success signal; the composer's `submit_token` + `pending_request_id` correlation (plan §Phase 4) waits for that echo, not for the JSON-RPC `result` reply.

Why this is fine for v1:
- Doesn't add a new fixed-id constant. The architect's worry was a third one after `@initialize_id` and `@turn_start_id`.
- Doesn't expand the PR's blast radius into the existing send sites (which would otherwise need migration tests).
- The canonical-echo path already exists — we don't lose any UX affordance by not awaiting the JSON-RPC reply.

The id-router refactor remains a defensible cleanup. If/when a third caller arrives that needs synchronous reply correlation, it should be the trigger. Until then, the two existing fixed-id callers can stay as-is and the new operator-message path stays fire-and-forget.

Update the plan's §Phase 1 wording when resuming so the next implementer doesn't re-attempt the id-router refactor by accident.

## Pre-existing local setup notes

(unchanged from pre-chat-send sessions; for fresh-machine onboarding)

- Repo: `/home/applekid/github/its-applekid/symphony`
- Remote: `git@github.com:its-everdred/symphony.git`
- Upstream: `https://github.com/openai/symphony.git`
- Build: `cd elixir && /home/applekid/.local/bin/mise exec -- mix escript.build` (outputs `bin/symphony`)
- Tests: `cd elixir && /home/applekid/.local/bin/mise exec -- mix test --max-cases 4` (the `--max-cases 4` avoids OOM kills on this box)
- Lint: `cd elixir && /home/applekid/.local/bin/mise exec -- mix lint`
- Foreground CLI: `agents` (shell alias / symlink to `scripts/agents`)
- Web dashboard: `http://agents.amicooked.chat:4000` (Tailscale + Basic Auth, creds in `/home/applekid/.config/symphony-dashboard.env`)
- `symphony.service` systemd user unit runs Symphony in the background; stop with `agents stop default` before running interactive `agents` to avoid port 4000 conflict.

## Test commands worth knowing

```bash
# Focused test runs that don't OOM:
/home/applekid/.local/bin/mise exec -- mix test test/symphony_elixir/coding_agent_test.exs --max-cases 4
/home/applekid/.local/bin/mise exec -- mix test test/symphony_elixir/terminal_input_test.exs --max-cases 4

# Snapshot fixture regen:
UPDATE_SNAPSHOTS=1 /home/applekid/.local/bin/mise exec -- mix test test/symphony_elixir/status_dashboard_snapshot_test.exs --max-cases 4

# Full suite (slowest):
/home/applekid/.local/bin/mise exec -- mix test --max-cases 4
```

Current state at handoff time: **324 tests, 0 failures, 2 skipped. Lint clean.**
