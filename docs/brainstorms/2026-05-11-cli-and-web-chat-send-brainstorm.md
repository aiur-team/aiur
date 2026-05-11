---
date: 2026-05-11
topic: Chat-send from CLI log pane and LiveView log modal
branch: symphony/agent-chat-send
status: ready-for-planning
---

# Chat-send from CLI log pane and LiveView log modal

## What We're Building

The CLI agent log pane (PR #12) already reserves a placeholder input row reading `│ > [send disabled — coming soon]`. The web dashboard's per-agent log modal is read-only today. We're wiring a real composer in both surfaces so the operator can type a follow-up message to the currently-selected running agent and send it as user input to its Codex session — effectively an interrupt or follow-up turn.

Both surfaces share:
- **Targeting**: message goes to the currently-selected agent.
- **Optimistic local echo**: the operator's message immediately appears in the log pane as a `user`-role chat row (matching the existing `Issue prompt` style); the agent's session event stream replaces or replays it as the canonical record.
- **Per-agent draft preservation**: switching agents keeps each agent's in-progress draft so the operator can compose for multiple agents in parallel.
- **Multi-line composing**: Enter sends; Shift+Enter inserts a newline. Composer grows up to ~5 visible lines and then scrolls internally.

Out of scope here: the actual IPC plumbing into the Codex session (orchestrator → codex JSON-RPC). The plan will figure out what hooks exist.

## Why This Approach

**Two modes, not free-form typing.** The CLI pane already has two view states (`:list` and `{:log, _}`). We add a sub-mode for the log view: `:browsing` (j/k/PgUp/PgDn navigate) and `:typing` (keys belong to the composer). `i` enters typing mode; `esc` returns to browsing. This keeps every key unambiguous — `j` is never both "next agent" and "type the letter j" simultaneously.

**Single shared send pipeline.** Both CLI and web should funnel through the same orchestrator API for delivering a message to a session, so behavior (optimistic echo, error handling, agent-state preconditions) stays consistent. The plan will design that API.

**Optimistic local echo.** Waiting for the session's event stream to round-trip before showing the user's message produces noticeable lag. Echoing locally on send keeps the UI responsive, and the canonical event stream will overwrite the optimistic entry within a tick. On failure, a system row appears in the log explaining what went wrong.

**Web parity.** Operators using the browser dashboard get the same capability — sticky-bottom composer in the existing log modal, multi-line textarea with Send button (accessible) + Enter shortcut (chat-app convention). Drafts persist in the LiveView session so closing and reopening the modal restores in-progress messages.

## Key Decisions

### CLI (foreground `agents` log pane)

| Concern | Decision |
|---|---|
| Sub-modes | `:browsing` (default when pane opens) and `:typing` |
| Enter typing mode | `i` |
| Exit typing mode | `esc` (returns to browsing without sending; draft preserved for current agent) |
| Send | Enter |
| Newline within message | Shift+Enter (`\e\r` or `\e\n` depending on terminal) |
| Composer growth | Single line → grows up to ~5 visible lines as user adds `\n`; further lines scroll within the input box. Log pane height shrinks to make room. |
| Editing keys (in typing mode) | Backspace; Left/Right arrows for cursor within line; Home/End to start/end of line; Up/Down move cursor between composer lines |
| Nav keys (in typing mode) | Disabled. `j`, `k`, `q`, etc. become literal text. PgUp/PgDn inert (or do the same as Up/Down arrow inside composer — TBD in plan). |
| Selection switch | Only possible from browsing mode. Per-agent drafts preserved when switching back. |
| Empty message | Enter on empty input is a silent no-op |
| Cursor display | Show a block or underscore at the cursor position when in typing mode; static (no blink) for first cut |
| Visual mode indicator | Placeholder text changes from `> [send disabled — coming soon]` to `> ` followed by typed content; bottom border / color of the row may shift in typing mode (final styling TBD) |
| Failure | If send fails, append a `system: Send failed` row to the log pane with the error reason. The composer keeps the message for retry (don't clear on failure). |
| Quit while typing | `q` is a literal character in typing mode (not a quit). Ctrl-C still exits Symphony (byte 0x03, not affected by typing). |

### Web (LiveView log modal)

| Concern | Decision |
|---|---|
| Composer placement | Sticky bottom inside the existing `.chat-log-panel` modal |
| Composer shape | `<textarea>` that grows up to ~5 visible rows; explicit **Send** button to the right; disabled when input is empty |
| Submit | Enter sends; Shift+Enter inserts a newline; clicking Send also submits |
| Per-agent drafts | Yes — LiveView session holds a map of `issue_identifier → draft`. Switching modals or closing/reopening the modal restores the draft for that agent. Refreshing the page is fine to lose them (in-memory only). |
| Optimistic echo | Same as CLI: append the operator's message as a `user`-role chat row immediately on submit |
| Failure | A system message appears in the log with the error reason; the textarea keeps the message |
| Disabled state | Send button disabled if textarea is empty OR if the agent's state doesn't accept input (e.g., session ended — exact preconditions TBD in plan) |

### Shared (both surfaces)

| Concern | Decision |
|---|---|
| Underlying send pipeline | One module (likely something like `SymphonyElixir.AgentMessage` or a method on `Orchestrator`) that takes `(issue_identifier, message_body)` and returns `:ok` or `{:error, reason}`. Both surfaces call into it. |
| Echo timing | Caller (CLI / LiveView) renders the optimistic echo immediately; the send function is fire-and-forget from the caller's perspective. Real session-event echoes from Codex will overwrite the optimistic line via the existing snapshot/refresh pipeline. |
| Agent precondition | At minimum, the agent must be present in the running snapshot (still alive). Finer-grained preconditions (session state, in-flight turn, etc.) TBD in plan. |

## Open Questions (resolve in plan)

- Exact Codex / coding-agent IPC hook for injecting an operator message into an active session — the plan needs to read `orchestrator.ex` / `coding_agent.ex` / the codex adapter to find or create the right entry point.
- Failure-mode taxonomy: what errors are possible (no session, send timeout, agent rejected the message), and what reason text should the operator see?
- Disabled-when-finished UI: a finished agent (no longer in `running`) has no live session. The CLI pane already shows "(finished)" in its title; should the composer be visually disabled in that state too (greyed-out, "send disabled" text)? Web Send button disabled — same logic.
- Should the optimistic local row be tagged so we can replace it cleanly when the canonical event arrives, or do we accept a possible double render and trust compaction to merge?
- CLI cursor blink: static cursor is fine for v1, but blink might be wanted later — needs a separate input loop or terminal-level cursor control (`\e[?25h`). Defer.
- Up/Down arrows in the composer: do nothing? move cursor between composer lines? Decide in plan based on how the composer state is modeled.
- History recall (up-arrow to recall previous sent messages): NOT in this scope. Future iteration.

## Resolved Questions

(All directly-asked design questions during this brainstorm dialog were answered — see `Key Decisions` above. Open Questions listed above are items that surfaced *during* the brainstorm but need code-level investigation in the plan, not user UX choices.)

## Out of Scope

- Recording/replaying operator messages across `agents` restarts
- Multi-target broadcast (sending the same message to multiple agents)
- Cancelling an in-flight send
- Rich-text composing (markdown rendering, file attachments)
- Operator authentication / per-user message attribution (single-operator assumption)
- Web mobile-responsive composer layout
- A11y polish beyond visible Send button + textarea label (announced live region, keyboard-only navigation through draft list, etc.)
