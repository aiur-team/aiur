---
title: Agent chat-send from CLI log pane and web log modal
type: feat
status: active
date: 2026-05-11
origin: docs/brainstorms/2026-05-11-cli-and-web-chat-send-brainstorm.md
branch: symphony/agent-chat-send
---

# Agent chat-send from CLI log pane and web log modal

## Enhancement Summary

**Deepened on:** 2026-05-11 (post-initial-draft pass)
**Reviewers run:** spec-flow-analyzer, architecture-strategist, code-simplicity-reviewer, agent-native-reviewer, best-practices-researcher.

### Key changes from the original draft

1. **Phase 2 reframed.** Original draft said operator messages queue in the AgentRunner Task's `receive_loop` — that loop doesn't exist; the live receive that owns the port is inside the *adapter* (`coding_agent.ex:329-355`), and it only matches `{^port, ...}`. The fix: operator-message handling lives at the **AgentRunner level between `run_turn` calls**, not inside the adapter. Adapters stay coding-specific.
2. **Phase 1 adds a per-port id-router.** The plan was about to introduce a second fixed-id pattern alongside `@turn_start_id = 3`. Replaced with a `%{request_id => from}` table on the port wrapper, and migrate `start_turn` to it as part of this PR. Stops the third-fixed-id-constant problem before it starts.
3. **New Phase 0: bracketed-paste mode.** Pasting a multi-line block triggers an immediate submit on the first newline today. Bracketed paste (`\e[?2004h`) is industry-standard for TUI chats (Claude Code, aider, Codex CLI all rely on it). Adding it is small and unblocks safe multi-line paste before Phase 4 lands.
4. **HTTP send endpoint promoted from "future work" to v1 (new Phase 3b).** Symphony's whole purpose is orchestrating remote agents; a non-human caller currently can `GET` snapshot state but can't `POST` an operator message. That's a parity hole, not a future enhancement. The Plug is ~10 lines on top of the existing `Orchestrator.send_operator_message/2` call.
5. **Submit-token replaces the 5-second safety timer.** Each `:submit_message` mints a `make_ref()`; the canonical echo (or error reply) carries the token; stale replies are ignored. Removes a wall-clock race and a whole class of "indicator stuck" / "indicator cleared then echo arrives" bugs.
6. **Security section added.** Input length cap, per-identifier rate limit, audit log entry per operator message — new in the HTTP / cross-surface story.
7. **Several smaller gaps closed**: empty-submit `String.trim/1`, Up/Down arrows explicitly inert in typing mode, modal close during in-flight send, ESC-vs-CSI parser race spec, queue depth bound (8, drop-oldest), draft cleanup timing on agent finish.

### What stays unchanged from the original draft

- `i` to enter typing mode (industry trend is auto-focus, but the brainstorm explicitly chose `i`; trade-off is documented).
- Per-agent draft preservation on both surfaces (simplicity reviewer flagged as YAGNI; brainstorm chose it explicitly).
- `SymphonyElixir.AgentChat` shared facade (simplicity flagged as needless; agent-native reviewer required it; we side with agent-native since the HTTP endpoint and future non-coding adapters need the single seam).
- Cursor editing (left/right/home/end). Modest scope, real usability win in the CLI.
- "Future Considerations § Non-coding agents" section (explicit user request).
- Optimistic UI via composer `sending?` indicator + canonical echo via the agent's own `userMessage` event (no double-rendering risk).

---

# Agent chat-send from CLI log pane and web log modal

## Overview

Wire the placeholder input row in the CLI agent log pane (PR #12) and add a matching composer to the LiveView per-agent log modal so the operator can type a follow-up message to a running agent. Pressing Enter (or clicking **Send** on the web) delivers the message to the agent's active Codex/Claude session as a new turn with the same thread ID. The agent then receives the operator's text as the next user-input turn and resumes execution.

This works for **both** Codex and Claude agents because the existing `SymphonyElixir.CodingAgent` behaviour (`elixir/lib/symphony_elixir/coding_agent.ex:8-11` — the same behaviour module that already adapts `Codex.CodingAgent` and `Claude.CodingAgent`) gives us a clean per-adapter swap: we add one new callback (`send_operator_message/2`) and implement it on both adapters. Both adapters use a JSON-RPC stdio port and the same `"turn/start"` protocol method (the Claude side proxies through `symphony-claude` which adapts Claude Code to the Codex protocol), so the implementation is structurally identical.

The public surface (`SymphonyElixir.AgentChat.send/2`) is intentionally agent-kind-agnostic so the same pipeline survives Symphony's eventual expansion to non-coding agents (Google Docs, Notion, GCal, …). See [Future Considerations § Non-coding agents](#non-coding-agents-google-docs-notion-gcal) for how the layering evolves.

## Problem Statement

After PR #12, the operator can watch an agent's chat-style log in real time but has no way to talk back. The only way to send a follow-up instruction today is to wait for the current turn to finish, then create a new GitHub/Linear comment, then wait for the orchestrator to pick it up — a multi-minute round trip for what is conceptually a one-liner correction or nudge ("actually try Y instead", "skip the test for now", "you missed file Z"). The placeholder input row at the bottom of the log pane and the read-only chat modal are visible reminders of the gap.

The brainstorm (see brainstorm: docs/brainstorms/2026-05-11-cli-and-web-chat-send-brainstorm.md) settled the UX. This plan is the HOW, including the question the brainstorm flagged as code-research: "Exact Codex / coding-agent IPC hook for injecting an operator message into an active session."

## Proposed Solution

**Three layers**:

1. **Coding-agent transport layer** (Codex + Claude adapters): expose `send_operator_message(session, text)` that writes a `"turn/start"` JSON-RPC frame onto the existing per-session stdio port. Both adapters already have the port (`elixir/lib/symphony_elixir/codex/coding_agent.ex:1207-1210`, `elixir/lib/symphony_elixir/claude/coding_agent.ex:33-48`); we just add the entry point.

2. **Orchestration layer** (Orchestrator + AgentRunner): expose `Orchestrator.send_operator_message(issue_id, text)` which forwards to the per-agent `AgentRunner` Task pid stored in `state.running[issue_id].pid` (`elixir/lib/symphony_elixir/orchestrator.ex:703-725`). The AgentRunner Task receives the operator message in its `receive_loop/6`, queues it, and dispatches it as a new `turn/start` **between** completed turns (the existing JSON-RPC correlation pattern uses fixed `@turn_start_id = 3`, so concurrent in-flight turn requests would collide — queueing is forced by the protocol).

3. **UX layer** (CLI pane + LiveView modal): a typing sub-mode in the CLI log pane (`i` enters, `esc` exits) and a sticky-bottom composer in the LiveView modal (textarea + Send button + Enter shortcut). Both surfaces hold per-agent draft buffers, dispatch through the shared orchestrator API, and let the agent's own session event stream (`item/started` with `userMessage` type — already parsed by `SymphonyElixir.AgentLog`) provide the canonical echo of the operator's message in the log.

**Why this beats optimistic local echo via writing to agent.md.** The brainstorm originally floated writing to `<workspace>/logs/agent.md` synchronously as optimistic echo so the user message appears immediately. Two reasons to skip that:

- Codex/Claude themselves emit an `item/started userMessage` event back through the JSON-RPC stream when they accept a `turn/start`. The existing `AgentLog.parse/1` already renders these as `"user"`-role rows (`elixir/lib/symphony_elixir/agent_log.ex:70-71`). If we write our own `userMessage` to `agent.md`, we get a duplicate when the agent's echo arrives, and `compact_log_messages/1` won't dedupe non-delta messages.
- `AgentRunner.write_agent_log/3` is a no-op for remote workers (`elixir/lib/symphony_elixir/agent_runner.ex:223`), so the optimistic write would silently skip remote sessions and feel inconsistent.

Instead: render a small **"sending…"** indicator inside the composer between submission and the canonical echo. The codex tick interval is ~1s; the round-trip is ~1 tick. The composer indicator goes away as soon as the user-message row appears in the pane log. If the send fails, the indicator turns into an error and the composer re-arms with the typed message so the operator can retry.

## Technical Approach

### Architecture

```
                  CLI                                          Web
              (TerminalInput)                          (DashboardLive)
                    │                                          │
                    │  byte stream                             │  phx-submit "send-operator-message"
                    ▼                                          ▼
            StatusDashboard                             Socket assigns
            (:view {:log, log_view{..., mode,            (drafts map, modal state)
             buffer, sending?}})                                │
                    │                                          │
                    ▼                                          ▼
            ┌─────────────────────────────────────────────────────┐
            │ SymphonyElixir.AgentChat                            │  ← new shared module
            │   send(issue_identifier, text) :: :ok|{:error,...}  │
            └─────────────────────────────────────────────────────┘
                                    │
                                    ▼
                  Orchestrator.send_operator_message/2
                  (looks up state.running[issue_id].pid)
                                    │
                                    ▼ (Erlang :send to AgentRunner Task pid)
                  AgentRunner — operator-message branch in receive_loop
                                    │
                                    ▼
            CodingAgent.send_operator_message(session, text)
                                    │
                ┌───────────────────┴──────────────────┐
                ▼                                      ▼
     Codex.CodingAgent                       Claude.CodingAgent
     (writes turn/start to port)             (writes turn/start to port)
                │                                      │
                ▼                                      ▼
          Codex stdio port                    Claude stdio port
                │                                      │
                ▼                                      ▼
            Agent emits item/started userMessage in event stream
                                    │
                                    ▼
            AgentLog.parse renders it as "user" chat row
                                    │
                                    ▼
            Both surfaces see it in their next refresh
```

### Implementation Phases

#### Phase 0 — Enable bracketed-paste mode in the CLI

Goal: pasted multi-line blocks must not submit on the first newline.

- Extend `enter_raw_mode/1` in `terminal_input.ex` to also write `\e[?2004h` to the TTY (enables bracketed paste). Restore in `terminate/2` with `\e[?2004l`.
- Update the byte-dispatch loop to recognise the framing sequences `\e[200~` (paste-start) and `\e[201~` (paste-end). Between them, bytes are buffered as a single "paste" event regardless of newlines, then dispatched to the dashboard as `{:paste, text}` (in `:text` mode) or ignored (in `:nav` mode).
- Add a unit test that drives the reader with `[\e, [, 2, 0, 0, ~, "hi", \n, "there", \e, [, 2, 0, 1, ~]` and asserts the dashboard receives a single `{:paste, "hi\nthere"}` cast, not a `:submit_message` cast.

**Deliverables:** updated TerminalInput + tests. No behaviour change in `:nav` mode for non-paste keystrokes.

**Effort:** Small.

**Success criteria:** the existing terminal_input tests still pass; new bracketed-paste test passes; pasting a multi-line block into a real Termius session is exercised in the Phase 9 smoke.

#### Phase 1 — Add `send_operator_message/2` to the CodingAgent behaviour and both adapters, with a per-port id-router

Goal: get one new public callback plumbed through both adapters AND replace the fixed-id-constant pattern before it spreads.

**1a. Introduce a per-port id-router.** Today `Codex.CodingAgent` and `Claude.CodingAgent` both have `@turn_start_id = 3` (and similar constants for `initialize`, `thread/start`, etc.), with `await_response/2` blocking on a specific id. This worked for one caller-per-id but breaks the moment a second caller can write to the port (which is what this PR introduces).

Replace it with a `%{request_id => from}` table per session, owned by whatever process holds the port (the adapter's `receive_loop`). On send: allocate `id = :erlang.unique_integer([:positive])`, register `Map.put(table, id, from)`, write the frame. On receive of an `id`/`result` JSON-RPC reply: pop the `from` and `GenServer.reply(from, result)`. The existing `initialize`/`thread/start`/`start_turn` send sites get migrated to this in the same PR — small but mechanical refactor.

This is a one-time cost that pays for itself the second new caller arrives. Architect review (see deepen-pass findings) flagged that punting this is the wrong move.

**1b. Add the behaviour callback.** Extend `SymphonyElixir.CodingAgent` (`elixir/lib/symphony_elixir/coding_agent.ex:8-11`):
```elixir
@callback send_operator_message(session :: map(), payload :: %{kind: atom(), body: term()}) ::
            {:ok, request_id :: integer()} | {:error, term()}
```

Why `%{kind: atom(), body: term()}` not `String.t()`: future non-coding agents (gcal/notion/gdoc — see *Future Considerations § Non-coding agents*) will not always be sending text. A `%{kind: :text, body: "hello"}` shape stays compatible. v1 only emits `:text`; later kinds add cases on the adapter side.

Returning `{:ok, request_id}` (not bare `:ok`) lets the orchestrator and HTTP layer correlate the canonical echo back to the submit; the CLI/web composer uses this with the submit-token (Phase 4) to clear the `sending?` indicator only when the matching echo arrives.

**1c. Implement on both adapters.** Both `Codex.CodingAgent` and `Claude.CodingAgent` write the same frame:

```elixir
%{
  "jsonrpc" => "2.0",
  "id" => request_id,
  "method" => "turn/start",
  "params" => %{
    "threadId" => session.thread_id,
    "input" => [%{"type" => "text", "text" => payload.body}]
  }
}
```

…via the existing `send_message/2` port write (`codex/coding_agent.ex:1207-1210`, `claude/coding_agent.ex` parallel). The id-router from 1a handles the response.

**1d. Tests.** Per-adapter test for: (1) successful frame write with a fresh id, (2) id-router records and resolves on reply, (3) `Port.command` failure surfaces as `{:error, :port_closed}`.

**Deliverables:** behaviour callback + two adapter implementations + id-router refactor + tests. No CLI/web changes.

**Effort:** Medium-Large. The id-router migration is the biggest piece — both adapters touch ~3 send sites each.

**Success criteria:** existing tests still pass after the id-router refactor; new tests cover the new callback; `mix specs.check` clean.

#### Phase 2 — Operator-message control channel at the AgentRunner level (between turns)

**Important correction from the original draft.** The original phrasing said "add a new clause to whichever process is holding the port (most likely the AgentRunner Task)". That's wrong: the port is held by the **adapter's** `receive_loop` (`codex/coding_agent.ex:329-355`), and that loop only matches `{^port, ...}` — it would be an abstraction violation to leak the operator-message concept into Codex/Claude adapters.

The correct shape: AgentRunner's `run/3` already alternates between calling `run_turn` (which blocks the Task while the adapter owns the port) and orchestration steps in between. We add the operator-message receive **between** those calls, NOT inside them.

**2a. Refactor `AgentRunner.run/3` (`elixir/lib/symphony_elixir/agent_runner.ex:84-153`) into an explicit between-turns loop.** Today it's a `with`-chain. After Phase 2 it becomes:

```elixir
def run(issue, workspace, opts) do
  with {:ok, session} <- CodingAgent.start_session(workspace, ...) do
    drive_session(session, issue, _state = %{queue: :queue.new(), reply_to: nil})
  end
end

defp drive_session(session, issue, state) do
  receive do
    {:operator_message, payload, from} ->
      cond do
        :queue.len(state.queue) >= @max_queue ->
          GenServer.reply(from, {:error, :queue_full})
          drive_session(session, issue, state)

        true ->
          new_state = %{state | queue: :queue.in({payload, from}, state.queue)}
          drive_session(session, issue, new_state)
      end
  after
    0 ->
      # No pending operator message; proceed with a normal turn.
      case CodingAgent.run_turn(session, next_prompt(issue, state), issue, []) do
        {:ok, _result} ->
          state = drain_queue_to_agent(session, state)
          continue_or_stop(session, issue, state)

        {:error, _reason} = err ->
          stop_with_error(session, err)
      end
  end
end
```

The receive-with-after-0 pattern checks for pending operator messages without blocking. The `drain_queue_to_agent/2` function calls `CodingAgent.send_operator_message/2` for each queued payload and replies `:ok` / `{:error, _}` to the original caller. Messages arriving DURING a `run_turn` (while the AgentRunner Task is blocked inside the adapter) accumulate in the Task's mailbox; they're picked up on the next iteration of `drive_session`.

**2b. Queue depth bound: `@max_queue 8`.** Drop-oldest is wrong because it implies silently losing operator intent — instead, reply `{:error, :queue_full}` to the *new* message so the operator sees a clear "queue full, current turn still running" error in the composer. The operator can wait for the current turn to drain.

**2c. Graceful shutdown.** When the AgentRunner Task exits (turn returned error, agent finished, or `agents stop`), drain any pending `{:operator_message, _, from}` messages from the mailbox and reply `{:error, :agent_finished}` to each. The orchestrator sees the Task exit through its monitor; the operator sees errors propagated through `AgentChat.send/2`.

**2d. Tests.** Unit tests for: (1) operator message between turns dispatches immediately; (2) operator message mid-turn queues and dispatches on next turn boundary; (3) 9th queued message returns `{:error, :queue_full}`; (4) Task crash drains pending messages with `{:error, :agent_finished}`.

**Deliverables:** AgentRunner between-turns loop + queue + control-message handler + graceful drain. No public API yet (that lands in Phase 3).

**Effort:** Medium-Large. The `run/3` refactor touches the main agent lifecycle path — needs careful preservation of existing turn-continuation, retry, and error-routing logic.

**Success criteria:** existing AgentRunner tests pass after the refactor; new tests cover the four scenarios above; manual smoke with a paused agent (long-running turn) shows the operator message queues, then dispatches when the turn completes.

#### Phase 3a — Orchestrator + AgentChat public API

- Add to `Orchestrator` a `GenServer.call` (with timeout):
  ```elixir
  @spec send_operator_message(issue_identifier :: String.t(), payload :: %{kind: atom(), body: String.t()}) ::
          {:ok, request_id :: integer()} | {:error, :no_running_agent | :queue_full | :agent_finished | :timeout | term()}
  def send_operator_message(identifier, payload) do
    GenServer.call(__MODULE__, {:send_operator_message, identifier, payload}, 5_000)
  end
  ```
- Handler looks up `state.running` by `identifier` (reverse lookup — same pattern as `find_running_entry/2` in `dashboard_live.ex:402`). On hit, sends `{:operator_message, payload, self()}` to the entry's `pid` and awaits reply.
- Input cap: payload body trimmed and length-checked (`<= @max_message_chars`, default 8_000). Over-length → `{:error, :message_too_long}`. Empty after `String.trim/1` → `{:error, :empty_message}`.
- Reject when identifier isn't in `state.running` → `{:error, :no_running_agent}`. Bubble up `:queue_full`, `:agent_finished` from AgentRunner.
- Add `SymphonyElixir.AgentChat` module — a one-function facade:
  ```elixir
  defmodule SymphonyElixir.AgentChat do
    @spec send(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
    def send(identifier, text), do: Orchestrator.send_operator_message(identifier, %{kind: :text, body: text})
  end
  ```
  Why a module instead of inlining: it's the single seam used by three callers (CLI, web, HTTP) and the future-non-coding-agents narrative depends on a kind-agnostic public name. Architect review concurred; simplicity review wanted it cut — we keep it.

**Deliverables:** Orchestrator API + AgentChat facade + caps + reverse lookup helper. `@spec` on both.

**Effort:** Small.

**Success criteria:** unit tests against a stubbed AgentRunner returning various replies; error paths covered (unknown identifier, dead Task, empty message, too-long message).

#### Phase 3b — HTTP send endpoint and capability hint

Promoted from "future work" to v1 because agent-native parity requires it: the existing `GET /api/v1/state` and `GET /api/v1/:issue_identifier` let non-human callers observe state but not act on it. A CI bot, sibling service, or remote-LLM operator can already poll but can't send.

- Add `POST /api/v1/:issue_identifier/messages` (in `observability_api_controller.ex` next to the existing GET handlers). Body: JSON `{"text": "..."}`. Response 202 + `{"request_id": 12345}` on success; 404 / 409 / 422 / 503 with `{"error": "..."}` mapped from the AgentChat `{:error, _}` return values.
- Calls into `SymphonyElixir.AgentChat.send/2` — same path as CLI/web.
- Audit log: every successful POST logs `Logger.info("operator message sent",  identifier: ..., request_id: ..., source: :http, length: ..., remote_ip: ...)`. Source field distinguishes `:http | :live_view | :cli`; CLI and LiveView callers pass their source too.
- Optional cheap rate limiter: per `issue_identifier`, e.g., `5 messages / 30s`. Built on a small ETS counter — or skip for v1 and rely on Basic Auth + a Tailscale-only ingress (good enough until misuse is observed).

**Capability hint in the existing detail endpoint.** Add to `GET /api/v1/:issue_identifier`'s response body an `accepts_operator_message: boolean` so a remote caller knows whether `POST .../messages` will succeed without a round-trip. Computed from `state.running` membership + `AgentRunner.queue_full?`. CLI and LiveView read the same field (sidesteps the `i`-in-`:list`-view UX wart from architect review #9 by giving TerminalInput a flag to consult before flipping local mode).

**Deliverables:** Plug handler + audit log + capability field + tests using existing controller test patterns.

**Effort:** Small (~10 LOC handler + tests).

**Success criteria:** `curl -u user:pass -X POST -d '{"text":"hi"}' http://host/api/v1/MT-1/messages` round-trips to a running agent. 4xx/5xx for the error matrix.

#### Phase 3c — Security considerations

- **AuthN/AuthZ:** inherits the existing dashboard Basic Auth + Tailscale envelope. The first state-mutating dashboard endpoint — worth a one-line note in the PR that anyone with dashboard creds can now inject text into agent turns.
- **Input cap:** 8000 char default (configurable later). Stops prompt-stuffing accidents.
- **Rate limit:** see Phase 3b. Defer to a follow-up if not required for v1, but make sure the audit log lands so misuse is forensically traceable.
- **Audit log retention:** existing dashboard log (`/home/applekid/.local/state/symphony/.../log/symphony.log`) captures these via `Logger.info`. The disk-log handler from PR #10 rotates them with the rest.
- **No injection via the path identifier:** Plug's `:issue_identifier` path segment is a string; the orchestrator looks it up in a map — no SQL, no shelling out. The text body becomes a turn-input JSON field; the JSON is encoded via `Jason.encode!` (escapes correctly).
- **Out of scope:** per-operator identity / per-token attribution. Single-operator assumption from the brainstorm.

#### Phase 4 — CLI: typing sub-mode in StatusDashboard

- Extend `log_view()` type (`elixir/lib/symphony_elixir/status_dashboard.ex:62-70`):
  ```elixir
  @type composer :: %{
          buffer: String.t(),                    # full message text, "\n" for newlines
          cursor: non_neg_integer(),              # byte offset within buffer
          submit_token: reference() | nil,        # current in-flight submit, if any
          pending_request_id: integer() | nil,    # JSON-RPC id from Phase 1 callback
          last_error: String.t() | nil
        }

  @type log_view :: %{
          ...existing fields...,
          mode: :browsing | :typing,
          composer: composer()
        }
  ```
- Add per-agent draft persistence: a new field on the dashboard struct (`drafts: %{issue_identifier => composer()}`) that survives selection changes. When `{:select_agent, _}` retargets the pane, the new log_view's `composer` is loaded from `drafts[new_identifier]` (or a fresh empty one).
- **Draft cleanup on agent finish.** Snapshot tick handler: when an identifier disappears from `state.running` AND the cached draft has `buffer == ""` AND `submit_token == nil`, drop that entry from `drafts`. Non-empty buffers are preserved (operator may want to retry on a re-run); the composer's submit precondition (Phase 7) catches the no-live-agent case at send time.
- New casts:
  - `:enter_typing` → flips `log_view.mode` to `:typing`. No-op if not in `{:log, _}`.
  - `:exit_typing` → flips to `:browsing`. Saves current composer back to `drafts[identifier]`.
  - `{:append_text, text}` → inserts `text` at `cursor`, advances cursor by `String.length(text)`. The same cast handles single chars from Phase 5 AND paste blocks from Phase 0 (the paste already comes through as a single `{:paste, text}` upstream and is converted to `{:append_text, text}` in the dashboard, preserving embedded newlines).
  - `:backspace` → deletes byte before cursor (handles grapheme boundaries via `String.length`/`String.split_at`).
  - `{:cursor_move, :left | :right | :home | :end}` → moves cursor within buffer. Up/Down arrows are **explicitly inert** in `:text` mode for v1 — TerminalInput swallows them; not sent as casts.
  - `:submit_message` → check `String.trim(buffer) == ""` (silent no-op if true). Else: mint `token = make_ref()`, call `SymphonyElixir.AgentChat.send(identifier, buffer)`, on `{:ok, request_id}` set `composer.submit_token = token`, `composer.pending_request_id = request_id`. Buffer is NOT cleared yet — see "echo clears" below.
  - `{:submit_failed, token, reason}` → if `token == composer.submit_token`, set `composer.last_error`, clear `submit_token` and `pending_request_id`. Buffer kept for retry. Stale tokens (from a previous submit) ignored.
  - `{:echo_received, request_id}` → if `request_id == composer.pending_request_id`, clear buffer, `submit_token`, `pending_request_id`, and `last_error`. The canonical `userMessage` row is now in the log via `AgentLog.parse/1` so the operator sees the success.
- **No 5-second safety timer.** Replaced by `submit_token + pending_request_id` correlation: stale replies are dropped by token mismatch; echo detection is driven by the snapshot/refresh path, not a wall-clock timer. If an echo never arrives (agent silently swallowed the turn — shouldn't happen, but) the indicator stays until the operator hits `i` again and types — they can manually retry. Less elegant than auto-clear but eliminates the timer/echo/error three-way race architect review #7 flagged.
- The render path: when `mode == :typing`, the existing `format_input_placeholder/1` (`status_dashboard.ex:700-705`) is replaced by a full composer renderer that draws up to 5 visible lines of the buffer, a cursor block at the cursor position, and below it: `last_error` (red, one line, persists until next keystroke) OR a "sending…" indicator when `submit_token != nil` OR empty.

**Deliverables:** state machine + casts + composer renderer + per-agent drafts map. Snapshot fixtures for: empty composer in typing mode; composer with multi-line text; composer in sending state; composer with error.

**Effort:** Large. Most of the v1 complexity lives here.

**Success criteria:** `mix test` covers all casts. Snapshot tests confirm the composer renders correctly at each state.

#### Phase 5 — CLI: TerminalInput dispatches based on dashboard mode

- TerminalInput holds a tiny local `input_mode :: :nav | :text`.
- New bindings in `:nav` mode (in addition to existing):
  - `i` → consult the last cached snapshot's `accepts_operator_message` field for the selected agent (set in Phase 3b). If true: `StatusDashboard.enter_typing(dashboard)` + flip local `input_mode` to `:text`. If false (or no selection / not in log view): no-op (don't flip local mode). Eliminates the "i in :list view silently flips local mode" wart from the original draft.
- New bindings in `:text` mode (existing keys + the bracketed-paste handling from Phase 0):
  - Printable bytes (0x20-0x7E) → `{:append_text, <<byte>>}` cast.
  - `\b` (0x08) or `\x7f` (DEL, often what backspace sends in raw mode) → `:backspace` cast.
  - `\r` or `\n` → `:submit_message` cast.
  - `\e` followed by `\r`/`\n` (Alt-Enter) → `{:append_text, "\n"}` cast. Shift-Enter is not distinguishable from plain Enter on most terminals (only newer keyboard protocols like Kitty's or fixterms report the modifier); we use Alt-Enter for CLI. Industry convention (Claude Code, aider, Codex CLI all use Alt-Enter or a similar escape). Document in `scripts/agents --help`.
  - `\e[D` / `\e[C` (left/right arrows) → `{:cursor_move, :left|:right}` cast.
  - `\e[H` / `\e[F` (home/end) → `{:cursor_move, :home|:end}` cast.
  - `\e[A` / `\e[B` (up/down arrows) → **explicitly swallowed**, no cast. (Brainstorm decision; up/down arrows in a TUI composer are an avoidable rabbit-hole — multi-line cursor walking is what backspace + retype handle for v1.)
  - `\e[5~` / `\e[6~` (PgUp/PgDn) → swallowed in `:text` mode.
  - Bare `\e` (Esc) → `StatusDashboard.exit_typing(dashboard)` + flip local `input_mode` to `:nav`. Implementation: the existing bare-ESC handler (`terminal_input.ex:81-96`) already dispatches the next byte normally; in `:text` mode the next byte is dispatched as the next typed key, which is fine — `esc` + `j` exits typing and the `j` is then a `:nav` keystroke (select_next). Test explicitly.
  - **ESC-vs-CSI race:** because we read the next byte immediately after `\e` in the same reader process, there's no async timer involved. `\e` arriving from a CSI sequence (e.g., `\e[D`) has its `[` arrive in microseconds; bare `\e` from operator typing has the next byte arrive only when the operator presses something. The existing pattern is robust; add a test that drives `[\e, [, D]` in rapid succession and asserts `{:cursor_move, :left}` (not `:exit_typing` + dispatch of `[`).
  - Ctrl-C (0x03) → `System.stop(0)` (unchanged, works in both modes).
  - `\e[200~` / `\e[201~` framing (bracketed paste from Phase 0) → `{:paste, text}` cast → dashboard converts to `{:append_text, text}` with embedded newlines preserved.
  - All other bytes — including `j`, `k`, `q`, and the un-bound nav keys above — swallowed in `:text` mode.

**`i` precondition.** Reading from the cached snapshot in TerminalInput avoids the original draft's "press `i` in `:list` view → local mode flips but nothing visible happens" wart. The dashboard already updates the snapshot cache on each tick, so TerminalInput's view of `accepts_operator_message` is at worst 1 tick stale. Acceptable.

**Deliverables:** updated `terminal_input.ex` with local mode + new key bindings. Tests in `terminal_input_test.exs` covering each binding.

**Effort:** Medium.

**Success criteria:** unit tests prove each byte sequence produces the correct dashboard cast.

#### Phase 6 — Web: composer in the LiveView modal

- Add to `dashboard_live.ex` socket assigns:
  - `:drafts` → `%{issue_identifier => String.t()}` (in-memory only; lost on page refresh, per brainstorm).
  - `:pending_sends` → `%{issue_identifier => %{token: reference(), request_id: integer()}}` (per-agent in-flight tracking; mirrors the CLI `submit_token` / `pending_request_id` approach so the `sending…` indicator clears on canonical-echo detection rather than wall-clock timer).
- Markup inside the modal panel (`dashboard_live.ex:280-313`), sticky bottom of `.chat-log-panel`:
  ```heex
  <form phx-submit="send-operator-message"
        phx-hook="ChatComposer"
        id="agent-chat-composer"
        class="agent-chat-composer"
        aria-label="Message composer">
    <textarea
      name="message"
      rows="1"
      placeholder="Message agent…"
      aria-label="Message body"
      enterkeyhint="send"
      phx-change="composer-change"
      phx-debounce="200"
    ><%= @drafts[@agent_log_modal.issue_identifier] || "" %></textarea>
    <button type="submit"
            class="agent-chat-send"
            phx-disable-with="Sending…"
            disabled={not can_send?(@drafts, @pending_sends, @agent_log_modal)}>
      Send
    </button>
  </form>
  ```
- Best-practice details folded in from the deepen pass research:
  - **Debounced `phx-change`** (200ms). Without debouncing, every keystroke ships the full textarea value to the server — known LiveView footgun (#680 in the LV repo).
  - **`phx-disable-with`** on the button does the in-flight visual swap; **do not disable the textarea** — it steals focus and breaks IME composition (well-documented LiveView gotcha).
  - **`enterkeyhint="send"`** changes mobile keyboards' return key to a Send affordance.
  - **JS hook `ChatComposer`** (new file `assets/js/hooks/chat_composer.js`) handles two things:
    - Auto-grow: on `input`, `el.style.height='auto'; el.style.height=el.scrollHeight+'px'` capped by CSS `max-height`. Reset to 1-row height in the hook's `updated()` callback after submit (LiveView issue #1011).
    - Enter handling: on `keydown` Enter without `shiftKey`, dispatch the form's submit event (mobile excepted — mobile users tap Send; the hook checks `'ontouchstart' in window` and skips). On Shift+Enter, let the textarea handle the newline naturally.
  - **Optimistic echo via LiveView streams.** Instead of waiting for the next snapshot tick, insert a `temp_id`-tagged user-role row into the chat stream in the same `handle_event("send-operator-message", ...)` handler. When the canonical `userMessage` row arrives in the next refresh, the temp is replaced via `stream_delete` + `stream_insert`. This is the pattern from Phoenix's own "Syncing changes and optimistic UIs" guide. Trade-off vs the CLI: web gets immediate visual confirmation in the log itself (matching chat-app convention); CLI gets the indicator-in-composer style. Both fine — different surfaces, different idioms.
  - **CSS**: locate the existing `.chat-log-panel` / `.modal-panel` CSS file during work (research said location unconfirmed). Match semantic class naming convention (`.agent-chat-composer`, `.agent-chat-textarea`, `.agent-chat-send`). Textarea grows from 1em up to `max-height: 7em` with `overflow-y: auto` (~5 lines).
- Event handlers:
  - `"composer-change"` → store the textarea value in `socket.assigns.drafts[identifier]` (debounced).
  - `"send-operator-message"` (`phx-submit`):
    1. `String.trim/1` the message; reject empty.
    2. Mint `token = make_ref()`.
    3. Insert temp user-row into stream with `id: "temp-#{token}"`.
    4. Call `SymphonyElixir.AgentChat.send(identifier, text)`.
    5. On `{:ok, request_id}` → put `pending_sends[identifier] = %{token: token, request_id: request_id}`, clear `drafts[identifier]`. Indicator stays "sending…" until echo detected (Phase 7).
    6. On `{:error, reason}` → `stream_delete` the temp row, surface error via a `<p class="agent-chat-error">` rendered above the composer; draft retained.
- **Modal close while sending.** Don't cancel the in-flight call (already dispatched to AgentRunner — it's not cancellable). On `close-agent-log`, just clear the modal assign. `pending_sends` entry can stay or be evicted; either way the echo still lands in `agent.md` and gets surfaced next time the modal opens for that agent.

**Deliverables:** form + textarea + Send button + JS hook + CSS. First form in the app — establishes conventions for future forms.

**Effort:** Medium. The JS hook for Enter vs Shift+Enter requires a small `assets/js/hooks/chat_composer.js` (or equivalent location — discover during work).

**Success criteria:** LiveView tests render the form with a draft, simulate submission, assert the AgentChat send was called. Manual smoke in browser: drafts persist when closing/reopening the modal for the same agent.

#### Phase 7 — Echo & error feedback

- The agent's own `item/started userMessage` event is the canonical echo. The existing `AgentLog.parse/1` (`elixir/lib/symphony_elixir/agent_log.ex:70-71`) already renders it as a `"user"` chat row, so **no rendering change is required** for the success-path echo on either CLI or web. The dashboard tick or LiveView's PubSub refresh picks it up within ~1s.
- **Echo detection by submit-token + request-id.** When the dashboard / LiveView re-parses the log on a snapshot tick, scan the message list for a `userMessage` whose body matches the most recent `pending_sends[identifier]` body (or, better, whose JSON-RPC id arrived via the Phase 1 id-router's reply path). On match, dispatch `{:echo_received, request_id}` to the composer. Composer's handler clears `submit_token`, `pending_request_id`, and the buffer.
- **No 5-second safety timer.** Stale `pending_request_id` lives in the composer until either (a) the operator types again (which is a no-op until they submit, at which point a fresh token replaces the old one — the old reply, if it ever arrives, is dropped by token mismatch), or (b) the operator closes/reopens the pane / modal (fresh composer). This is a slight UX regression vs the timer for the rare "agent silently swallowed my turn" case, but eliminates the timer/echo/error three-way race entirely.
- Send errors: `{:submit_failed, token, reason}` cast (CLI) / `:error_flash` assign (web) — both gated by token match so a late error from a previous submit can't clobber a current draft.
  - CLI: one-line gray (or red for hard errors) text below the composer; buffer retained for retry; cleared on next keystroke.
  - Web: `<p class="agent-chat-error">` above the composer; same retention rules; cleared on next textarea change event.
- Disabled state for finished agents: composer renders as inactive — input still accepts keystrokes (so the draft is preserved) but the submit precondition fails. CLI: `{:submit_failed, token, :no_running_agent}` immediately. Web: `disabled` on the Send button (and the JS hook checks the same precondition for Enter); a small "Agent has finished — message will not be sent" line above.
- **Empty-message handling** (consistent both surfaces): `String.trim(buffer) == ""` is a silent no-op. Pressing Enter on whitespace does nothing; no error message; no flicker.

**Deliverables:** sending-indicator state plumbing + error rendering + safety timer.

**Effort:** Small.

**Success criteria:** end-to-end test where Phase 1-3 succeed, Phase 4-6 render the composer, the agent's session echo arrives, and the indicator clears.

#### Phase 8 — Tests and snapshot fixtures

New tests across each phase. Aggregate snapshot fixtures for the dashboard:
- `composer_browsing.snapshot.txt` — log pane open, mode `:browsing`, no draft.
- `composer_typing_empty.snapshot.txt` — typing mode, empty composer.
- `composer_typing_multiline.snapshot.txt` — typing mode, 3-line draft.
- `composer_sending.snapshot.txt` — typing mode, `sending?: true`.
- `composer_error.snapshot.txt` — typing mode, last_error set.
- `composer_finished_agent.snapshot.txt` — typing mode but selected agent not running.

LiveView tests: form rendering, submit dispatch, draft persistence across modal close/reopen.

#### Phase 9 — Manual smoke

In a real Termius session:
- Open `agents`; open log pane on a running agent with `space`.
- `i` enters typing; type a message; Enter sends.
- See "sending…" briefly, then the message appears in the log as `user: Issue prompt` (or whatever role label codex emits).
- The agent picks up the new turn and responds.
- `Alt-Enter` inserts a newline; sending a multi-line message works.
- Paste a multi-line block (from clipboard) — verify it inserts as one chunk, no premature submit.
- `Esc` exits typing; `j`/`k` navigates again.
- Switch to a different agent (`j`); the previous draft persists; switch back; restored.
- Open the web modal for the same agent; verify the optimistic user-row appears immediately on submit and is replaced by the canonical row.
- `curl -u user:pass -X POST -d '{"text":"hi"}' http://host/api/v1/MT-1/messages` lands as well, with the audit log entry showing `source: :http`.

## Alternative Approaches Considered

| Approach | Why rejected |
|---|---|
| Write the operator's message to `<workspace>/logs/agent.md` synchronously as optimistic echo | Duplicates the canonical echo when the agent's `item/started userMessage` event arrives (no message-level dedup in `AgentLog.compact_log_messages/1`); silently no-ops for remote workers since `AgentRunner.write_agent_log/3` skips remote (`agent_runner.ex:223`). |
| Move the per-agent port to a named GenServer (registered process) so multiple senders can write to it | Bigger refactor of `coding_agent.ex` and `agent_runner.ex` with no v1 benefit. The AgentRunner Task is already the natural owner — adding a message branch is smaller and isolates the queueing logic where the turn-state already lives. |
| Send operator message mid-turn (true interrupt) | Neither Codex nor Claude expose a "cancel current turn" or "inject input mid-turn" method in the JSON-RPC protocol we use today (research found only `"turn/start"` outbound). Mid-turn injection would require either protocol extensions on the symphony-claude/codex sides or a different multiplexing scheme. Out of scope. |
| Add `SymphonyElixir.AgentChat` as a top-level facade module that wraps Orchestrator | Done — keeps callers (`StatusDashboard`, `DashboardLive`) from importing Orchestrator directly. One-line wrapper, but isolates the public API surface. |
| Make CLI shift+Enter actually work via bracketed paste mode | Would require enabling bracketed paste in `stty` and parsing the `\e[200~ … \e[201~` framing. Disproportionate effort for one keybinding. Alt-Enter is universally supported and well-understood. |

## System-Wide Impact

### Interaction Graph

1. **Operator presses Enter in composer** (CLI) or clicks **Send** (web) →
2. Surface calls `SymphonyElixir.AgentChat.send(identifier, text)` →
3. `Orchestrator.send_operator_message/2` looks up `state.running[issue_id].pid` →
4. `GenServer.call → AgentRunner Task: {:operator_message, text, from}` →
5. AgentRunner queues the message. If between turns, dispatches immediately:
6. `CodingAgent.send_operator_message(session, text)` →
7. Codex or Claude adapter writes a `"turn/start"` JSON-RPC frame to the per-session stdio port →
8. The agent's app-server emits `item/started userMessage` back through the event stream →
9. `AgentRunner.codex_message_handler` writes a new chunk to `<workspace>/logs/agent.md` (`agent_runner.ex:48-54`, `223-245`) →
10. Next dashboard tick or LiveView refresh re-reads `agent.md`, `AgentLog.parse` produces a `user`-role row, log pane updates.
11. The composer's `sending?` indicator clears (either via a "echo detected" probe or the 5s safety timer).

### Error & Failure Propagation

| Layer | Failure mode | Behavior |
|---|---|---|
| `AgentChat.send/2` | identifier not in `state.running` | Returns `{:error, :no_running_agent}`. Composer shows "Agent has finished — message not sent." |
| `Orchestrator.send_operator_message/2` | `GenServer.call` to AgentRunner Task times out (5s) | Returns `{:error, :timeout}`. Composer shows "Send timed out; try again." |
| AgentRunner Task | Task crashed between Orchestrator lookup and send | `GenServer.call` raises with `:noproc`-style exit; `AgentChat` rescues and returns `{:error, :agent_dead}`. |
| AgentRunner queue | Operator message arrives while agent is mid-turn | Queued; dispatched when current turn completes. Composer shows "queued — waiting for current turn" if we want fine-grained feedback (TBD; v1 may collapse this with `sending?`). |
| Codex/Claude adapter | `Port.command` fails (port closed mid-write) | `{:error, :port_closed}`. Composer shows error; draft retained. |
| JSON-RPC response correlation | Operator turn's `id` collides with `@turn_start_id` | Avoided by allocating fresh ids per operator message in Phase 1. Verified by test. |
| Echo never arrives | Agent acknowledges turn but never emits `item/started userMessage` (protocol regression) | `submit_token` stays set; indicator stays "sending…". Operator closes pane / modal or types another message — fresh token replaces the stale one. Late `userMessage` (if it ever shows) just appears as a normal row in the log. No corruption. |
| Operator-message queue full (8 messages pending while a long turn is in flight) | Most recent submit returns `{:error, :queue_full}` | Composer shows "queue full — current turn still running" until the queue drains. Operator can wait or retry. |
| Operator quits Symphony (Ctrl-C / q) AFTER `Port.command` returned `:ok` but BEFORE the agent processes the message | Bytes are in the OS pipe buffer; the agent will receive them post-quit, but Symphony won't be running to see the echo | Document: successful submit means "delivered to agent's stdin"; quitting before echo doesn't undeliver. The next `agents` start picks up the workspace and `agent.md` will already have the operator's row. |
| AgentRunner Task crashes with queued operator messages still in its mailbox | Queue is lost on Task death | Phase 2 explicitly drains pending messages with `{:error, :agent_finished}` to each `from`. Operators see the error and can retry. Persistence not in scope. |
| Late `{:submit_failed, _, _}` reply arrives after operator started a new submit | Stale token mismatches current `composer.submit_token` | Cast handler drops the stale reply silently. No state corruption. Covered by token-match test. |

### State Lifecycle Risks

- **Draft loss on supervisor restart**: Drafts live in `StatusDashboard` GenServer state and LiveView socket assigns. A dashboard process restart wipes CLI drafts; a LiveView socket reconnect wipes web drafts. Acceptable for v1; documented limit.
- **Composer state vs. selection switch**: covered by the `drafts: %{identifier => composer}` map. Switching agents saves the current composer to that map keyed by the old identifier and loads (or initializes) the composer for the new identifier.
- **Stale `sending?` flag**: the 5s safety timer guarantees the flag clears. If we ever hit a real-world case where 5s isn't enough, bump the timer or tie the clear to a snapshot-fingerprint check.
- **AgentRunner queue across reboot**: Operator messages in the AgentRunner's mailbox are lost if the Task crashes (or is killed during an `agents stop`). The operator sees a `{:error, :agent_dead}` and retries. Persistence not in scope.

### API Surface Parity

- The new `send_operator_message/2` callback is the new boundary between Symphony and any future coding-agent backend. Both Codex and Claude implement it; any third adapter (e.g., `LocalLLM.CodingAgent`) would have to as well, or have it default-error.
- The CLI and web surfaces both call into `SymphonyElixir.AgentChat.send/2`. There's no third surface (an HTTP API endpoint that lets a remote tool send operator messages to an agent) — out of scope for v1 but a natural extension if needed later.
- The agent-native-reviewer concern is satisfied: any UX a human can perform (typing a follow-up to an agent) is also reachable programmatically by any internal caller via `SymphonyElixir.AgentChat.send/2`.

### Integration Test Scenarios

1. **End-to-end via fake adapter**: stub a `FakeCodingAgent` that implements the behaviour; CLI dispatches "hello"; AgentRunner drains between turns; adapter records the JSON-RPC frame; assert the frame is a `turn/start` with `text: "hello"` and a non-3 id.
2. **Concurrent operator messages**: send two operator messages back-to-back before the first turn completes; assert both arrive in order, queued, the second is dispatched after the first turn completes, and the queue depth never exceeds 8.
3. **Selection switch during typing**: open pane on agent A, enter typing, type 3 chars, switch to agent B (via esc + j), type 2 chars there, switch back to A (k); assert agent A's composer has the original 3 chars.
4. **Send during finished agent**: open pane on a running agent, agent finishes before operator hits enter; assert submit returns `{:error, :no_running_agent}` and the composer shows the error with the buffer preserved.
5. **Web modal draft persistence**: open modal for agent A, type a draft, close modal, reopen for agent A; assert draft is there. Close, reopen for agent B; assert empty. Reopen for A; assert original draft.
6. **Bracketed paste of multi-line block (CLI)**: drive the reader with `\e[200~ … \e[201~` framing around `"line1\nline2\n"`; assert no submit fires, the dashboard receives one `{:append_text, "line1\nline2\n"}` cast, and the composer renders two lines.
7. **Token-matched echo clearing**: submit "hello" (token T1), assert `pending_request_id` set. Write a fake `userMessage` row to `agent.md`. Trigger tick. Assert composer clears (token T1 consumed). Submit "world" (token T2). Echo for T1 arrives late — assert dropped, no buffer corruption.
8. **HTTP send endpoint**: `POST /api/v1/MT-1/messages {"text":"hi"}` against a stubbed Orchestrator returning `{:ok, 42}`; assert 202 response with `request_id: 42`. Then test 404 (`:no_running_agent`), 409 (`:queue_full`), 422 (`:message_too_long`), 503 (`:timeout`).
9. **Audit log**: send via each of CLI / web / HTTP; assert log file has three entries with distinct `source` fields.
10. **id-router migration**: assert existing `start_turn`/`initialize`/`thread_start` paths still work after the router refactor (these are existing tests; they should pass without modification).

## Acceptance Criteria

### Functional Requirements

- [ ] `i` in the log pane's `:browsing` mode enters `:typing` mode; composer becomes focusable.
- [ ] Printable keys append to the composer at the cursor; backspace deletes; left/right arrows move the cursor.
- [ ] `Home`/`End` jump cursor to start/end of the current line within the composer buffer.
- [ ] `Enter` submits; `Alt-Enter` inserts a literal newline in the buffer (CLI).
- [ ] `Shift+Enter` inserts a newline in the web textarea; `Enter` submits.
- [ ] `Esc` (CLI) exits `:typing` to `:browsing` without sending; the draft is preserved.
- [ ] Submitting with an empty composer is a silent no-op.
- [ ] After submit, the composer shows a "sending…" indicator for up to 5s.
- [ ] On success, the indicator clears; the operator's message appears as a `user`-role chat row in the log pane.
- [ ] On failure, the indicator becomes an error line with a short reason; the typed message is preserved.
- [ ] Selecting a different agent (via `j`/`k`/arrows from `:browsing` mode) preserves the current agent's draft and shows the new agent's draft (empty if none).
- [ ] CLI composer grows from 1 line up to 5 visible lines; further lines scroll within the composer box.
- [ ] Web composer grows from 1 row up to ~5 rows; further content scrolls internally.
- [ ] Web modal drafts persist across modal close/reopen within a LiveView session.
- [ ] Operator can send to a Codex agent (`Codex.CodingAgent`) and a Claude agent (`Claude.CodingAgent`) with identical UX.
- [ ] When the selected agent has finished (no longer in `running`), submitting shows a "no live agent" error.
- [ ] Operator messages sent while a turn is in flight are queued and dispatched after the current turn completes; the operator sees "queued" or `sending…` (same indicator OK).
- [ ] Pasting a multi-line block into the CLI composer inserts it as one chunk; no premature submit on embedded newlines.
- [ ] CLI: pressing `i` in `:list` view (no log pane open) is a silent no-op — local input mode does NOT flip.
- [ ] Up/Down arrows in the CLI composer are inert (no movement, no submit).
- [ ] CLI and web composers reject empty-after-trim messages silently.
- [ ] CLI and web composers reject over-length messages (>8000 chars by default) with a clear error.
- [ ] Queue depth limit (8): 9th submitted message while a long turn is in flight returns `{:error, :queue_full}` to the composer.
- [ ] `POST /api/v1/:identifier/messages` accepts `{"text": "..."}`, returns 202 + `request_id` on success, mapped 4xx/5xx on errors; same path used by CLI and web.
- [ ] Every operator message is logged with `source` (`:cli` / `:live_view` / `:http`), `identifier`, `request_id`, `length`.
- [ ] Late error replies (from a previous submit) don't corrupt a current draft — token-match drops stale messages.

### Non-Functional Requirements

- [ ] No regressions in existing CLI / LiveView tests (314 → ≥314, plus new tests).
- [ ] `mix specs.check` passes — every new public function in `lib/` has an adjacent `@spec`.
- [ ] `mix lint` clean.
- [ ] CLI input handling preserves the PR #12 invariant that the reader process tolerates port-exit signals.
- [ ] Web composer keyboard interaction is keyboard-only navigable (Tab to textarea, Enter to send, Shift+Enter for newline). Send button is reachable via Tab.

### Quality Gates

- [ ] Unit test coverage for: `CodingAgent.send_operator_message/2` behaviour delegator, Codex adapter, Claude adapter.
- [ ] AgentRunner queue tests: between-turns dispatch, mid-turn queue, drain.
- [ ] Orchestrator API tests: success, unknown identifier, dead Task.
- [ ] StatusDashboard cast tests: each new cast (enter_typing, exit_typing, append_text, backspace, cursor_move, submit_message, submit_failed).
- [ ] TerminalInput tests: each new keybinding in `:nav` and `:text` modes, mode-flip on `i` / `esc`.
- [ ] LiveView tests: form rendering, submit handler, draft persistence.
- [ ] 6 new snapshot fixtures (Phase 8 list).

## Success Metrics

This is a developer/operator tool with no analytics. Success is:

- Operator no longer leaves the terminal (or browser) to follow up with an agent mid-run.
- Both Codex and Claude agents accept operator messages with the same UX.
- No reported regressions to the CLI log pane or LiveView modal after merge.

## Dependencies & Prerequisites

- Branch `symphony/agent-chat-send` already cut from main after PR #12 merged.
- The `symphony-claude` sibling repo's app-server must continue to faithfully proxy `"turn/start"` to Claude. If a Claude-specific operator-input quirk is discovered during work (e.g., the proxy strips a field), we adapt in the Claude adapter only.
- No new external dependencies (no new hex packages).

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| The Codex/Claude session rejects a second `turn/start` on an existing thread (protocol limit) | Medium | The feature can't work as designed; needs a different IPC method | Phase 1 starts with a smoke test against a real session to confirm `turn/start` works mid-thread. If not, fall back to thread-restart with the operator message as input — known to work, but loses the agent's in-flight reasoning context. |
| The fixed `@turn_start_id = 3` clobber causes silent response loss | Medium | Operator's send is dispatched but `await_response` blocks forever or returns wrong correlation | Phase 1 explicitly allocates fresh ids and routes responses through the existing id-keyed reply path; covered by a unit test. |
| The AgentRunner Task isn't actually in its `receive_loop` when we send (e.g., it's blocked elsewhere) | Low | `GenServer.call` from Orchestrator times out | 5s timeout in Orchestrator; clear error message. |
| Drafts grow unbounded in the dashboard's `drafts` map (one entry per agent over time, including finished agents) | Low | Memory creep on long-running symphony sessions | Drop the draft for an identifier when the agent finishes — easy check in the snapshot refresh path. |
| The web composer's first-form-in-the-app status means there's no styling precedent | Low | Visual inconsistency with the rest of the modal | Match existing semantic class names (`chat-log-panel`, `modal-panel`, `subtle-button`) and have the implementer eyeball the result before merge. |
| Alt-Enter for newline isn't intuitive | Medium | Operators don't discover it | Help text in `scripts/agents --help` mentions it; the composer's "→" prompt could hint `(Alt-Enter for newline)` when empty. |
| Operator messages sent during a finished/dead agent state leak credentials or sensitive text into logs | Low | A typed-but-unsent message stays in dashboard state until selection changes or process restarts. Not a leak per se, but worth noting. | Drafts are in-memory only; never written to disk; cleared on process restart. |

## Resource Requirements

- Single developer. Estimated 2–3 days of focused work for v1 (Phases 1–9).
- No infrastructure changes. No new ports / no new services.

## Future Considerations

Out of scope here, but natural follow-ups:

- **History recall** (up-arrow recall of previous sent messages, per agent or globally).
- **Multi-target broadcast** ("send to all running agents").
- **Cancel in-flight send** (only useful if the queue grows; today the dispatch is sub-second).
- **HTTP API** for programmatic operator messaging (`POST /api/v1/:identifier/messages`).
- **Persistent drafts** across `agents` restarts (write to disk on graceful shutdown).
- **Bracketed paste mode** so shift+Enter on CLI inserts a newline natively (instead of Alt-Enter).
- **Mid-turn interrupt** when/if the agent backends grow protocol support for it.

### Non-coding agents (Google Docs, Notion, GCal, …)

The longer-term vision is for Symphony to drive agents whose scope is broader than coding — writing/editing a Google Doc, updating a Notion page, scheduling something on GCal, etc. The chat-send pipeline as designed here is robust to that expansion because the **public surface** (`SymphonyElixir.AgentChat.send(identifier, text)`) is intentionally agent-kind-agnostic. The coding-specific part is one layer deeper: the `SymphonyElixir.CodingAgent` behaviour (which Codex and Claude implement today) handles the JSON-RPC `"turn/start"` semantics.

When non-coding agents arrive, the layering can grow without breaking this work:

1. **`SymphonyElixir.AgentChat.send/2`** stays the public entry point for all surfaces (CLI pane, web modal, future HTTP API, future operator-bot triggers). It already routes through `Orchestrator.send_operator_message/2` → AgentRunner Task → adapter callback — the only thing per-backend about it is the final adapter dispatch.

2. **The current `CodingAgent` boundary becomes one of several backend boundaries.** Future possibilities (any of these can be picked later):
   - **Generalize the existing behaviour**: rename `SymphonyElixir.CodingAgent` → `SymphonyElixir.Agent` (or `SymphonyElixir.Backend`), broaden `run_turn` semantics, keep coding-specific concerns where they belong (e.g., the workspace-clone hook only fires for coding agents).
   - **Sibling behaviours**: add `SymphonyElixir.WorkflowAgent` (or similar) for non-coding integrations; route by agent kind in the orchestrator. Each behaviour has its own callbacks (`send_operator_message/2` is one that everyone needs; `start_session`/`run_turn` may not apply uniformly to a calendar event update).
   - **Capability-based dispatch**: each agent declares the set of capabilities it supports (`[:run_turn, :receive_operator_message, :produce_diff]`), and `AgentChat` / `Orchestrator` route based on capability rather than backend name.

3. **The new `send_operator_message/2` callback is the right shape regardless.** It takes `(session, text)` and returns `:ok | {:error, _}` — the contract doesn't assume the backend is coding-related. A gcal agent's adapter implements it however it wants (perhaps the message becomes a calendar event comment; perhaps it triggers a new "reschedule" turn). The CLI/web composer doesn't change.

What the plan *does not* do now (and intentionally so):

- Doesn't rename `CodingAgent` → `Agent`. That's a cross-cutting refactor not justified by chat-send alone; it should happen when the second-kind-of-agent actually arrives and we can validate the new abstraction against a concrete case.
- Doesn't introduce a `WorkflowAgent` or capability layer. Premature.
- Doesn't generalize naming in the new `AgentChat` module — but the *name* `AgentChat` is already general (no "coding" in it), and so is the public function signature.

The result: when the gcal/notion/gdoc work starts, the touch points are bounded to (a) whatever you decide to do at the `CodingAgent`/`Agent` boundary, and (b) the new adapters. Everything from `AgentChat.send/2` upward (the entire chat-send UX, the orchestrator routing, the per-agent draft persistence, the CLI typing sub-mode, the web composer) is reusable as-is.

## Documentation Plan

- Update `scripts/agents` help text to mention `i` / `Esc` / `Enter` / `Alt-Enter`.
- Add a brief section to the README about chat-send (both CLI and web).
- After merge, capture lessons in `docs/solutions/2026-MM-DD-agent-chat-send.md` — establish the institutional-knowledge baseline (currently no `docs/solutions/` exists per research).

## Sources & References

### Origin

- **Brainstorm:** [docs/brainstorms/2026-05-11-cli-and-web-chat-send-brainstorm.md](../brainstorms/2026-05-11-cli-and-web-chat-send-brainstorm.md). Key decisions carried forward:
  - Two sub-modes in the CLI log pane (`:browsing` / `:typing`), `i` to enter, `esc` to exit.
  - Enter sends; Shift+Enter (web) / Alt-Enter (CLI) inserts a newline.
  - Multi-line composer growing up to 5 lines.
  - Per-agent draft preservation on both surfaces.
  - Optimistic UI affordance via `sending?` indicator (NOT via writing to `agent.md`).
  - Single shared send pipeline `SymphonyElixir.AgentChat` so CLI and web go through the same orchestrator API.
  - Web composer is sticky-bottom textarea with explicit Send button.

**Intentional refinement of the brainstorm:**

- The brainstorm proposed optimistic-local-echo via "render the operator's message immediately as a `user`-role chat row." After researching `AgentLog.parse/1` (`elixir/lib/symphony_elixir/agent_log.ex:70-71`) and the codex echo pattern (the agent itself emits `item/started userMessage` back through the event stream), the plan substitutes a `sending?` composer indicator. The visible "you typed this" feedback is preserved (composer indicator); the canonical user row arrives from the agent's own event stream ~1 tick later — no duplicate rendering, no double-write risk. The brainstorm's "Open Questions" section explicitly flagged this trade-off.

- The brainstorm assumed Shift+Enter would work on both surfaces. CLI research found terminals don't distinguish Shift+Enter from Enter without bracketed-paste mode; the plan substitutes Alt-Enter for CLI (web stays Shift+Enter as planned).

### Internal References (file:line)

- Codex JSON-RPC transport: `elixir/lib/symphony_elixir/codex/coding_agent.ex:193-218` (port spawn), `:1207-1210` (frame write), `:333-355` (receive loop), `:304-327` (`start_turn/7` pattern to reuse).
- Codex fixed turn-id constant: `elixir/lib/symphony_elixir/codex/coding_agent.ex:14-16` (`@turn_start_id = 3`).
- Claude adapter parallel structure: `elixir/lib/symphony_elixir/claude/coding_agent.ex:20-48` (session start), `:54-90` (`run_turn`).
- CodingAgent behaviour to extend: `elixir/lib/symphony_elixir/coding_agent.ex:8-11`.
- Orchestrator running map: `elixir/lib/symphony_elixir/orchestrator.ex:703-725` (entry init), `:1101-1157` (`snapshot/0`), `:1107-1130` (snapshot map shape including new `title` field landed in PR #12).
- AgentRunner Task / `run_turn`: `elixir/lib/symphony_elixir/agent_runner.ex:84-153`.
- AgentLog parser (canonical user-message handler already exists): `elixir/lib/symphony_elixir/agent_log.ex:70-71`.
- StatusDashboard view state: `elixir/lib/symphony_elixir/status_dashboard.ex:62-70` (`log_view()` type), `:230-280` (cast handlers), `:700-705` (placeholder to replace).
- TerminalInput stateless dispatch + bare-ESC pattern: `elixir/lib/symphony_elixir/terminal_input.ex:70-118`.
- LiveView modal markup to extend: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex:280-313`.
- AGENTS.md conventions: `@spec` mandatory on public `lib/` functions (line 37); `mix specs.check` enforces (line 46).

### Related Work

- PR #10 (`Interactive agent selection in CLI dashboard`) — established the `--interactive` flag, `TerminalInput`, and the `selected_index` plumbing this plan builds on.
- PR #12 (`Agent log pane in CLI dashboard`) — established the `:list | {:log, log_view()}` view state machine, the `AgentLog` shared parser, and the placeholder input row this plan replaces.

### External References (added in deepen-plan pass)

- **Bracketed paste mode (xterm)** — `\e[?2004h` / `\e[?2004l`, framing `\e[200~ … \e[201~`. Canonical industry handling for multi-line paste in TUI chat composers.
- **LiveView "Syncing changes and optimistic UIs"** — https://hexdocs.pm/phoenix_live_view/syncing-changes.html. Pattern for `temp_id`-tagged stream inserts + canonical replacement.
- **LiveView issue #1011** (textarea height reset after submit re-render) — https://github.com/phoenixframework/phoenix_live_view/issues/1011.
- **LiveView issue #680** (`phx-keyup` ships full value every keystroke; use `phx-debounce` on `phx-change` instead) — https://github.com/phoenixframework/phoenix_live_view/issues/680.
- **Phoenix.LiveView.JS** — https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html. For the `ChatComposer` hook's submit/disable choreography.
- **claude-code-better-enter / Issue #1259** — terminal Shift+Enter handling history. Confirms Alt-Enter is the universally-supported convention.
- **`enterkeyhint="send"`** — HTML attribute that changes the mobile keyboard's return key. https://html.spec.whatwg.org/multipage/interaction.html#input-modalities:-the-enterkeyhint-attribute.
