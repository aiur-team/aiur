---
title: opencode pre-warm + SQLite history injection
date: 2026-05-20
status: ready-for-planning
supersedes:
  - The `scripts/aiur-pane-loading` placeholder pattern (commit `153a160`) — to be removed
  - `Aiur.Opencode.TranscriptRelay`'s POST-based history replay (commit `b0206e5`) — to be replaced
---

# opencode pre-warm + SQLite history injection

## Problem

Opening an agent's opencode pane today takes ~15 s of visible loading and the chat doesn't behave like a conversation log:

1. **Cold-start sequencing is bad.** A fake loading screen shows for ~7 s while `opencode serve` warms up; then it disappears prematurely and the user sees another ~8 s of `opencode attach` cold-start with nothing displayed.
2. **The placeholder doesn't match opencode's chrome**, so the swap is jarring even when it happens at the right moment.
3. **History renders as a single blue "user" bubble** instead of as the agent's own past output, because opencode's `POST /session/<id>/message` API only creates user-role messages and we POST history through it.
4. **The agent never says anything until the user types.** Codex is still running and emitting transcript events, but those events can't flow into opencode's TUI unless the user kicks off a chat-completion turn.

## Verified surface (Phase 1 research findings)

These were validated against the running opencode 1.15.6 + Aiur branch before writing:

| Fact | How verified |
|---|---|
| `opencode attach` floor cost is ~6.7 s with 1 empty session | Timed against fresh DB, 0/1/5/28 sessions: 6.7 / 6.7 / 6.7 / 16.9 s |
| Per-session overhead is ~0.4 s above 5 sessions | Same measurement; opencode iterates the session list at attach time (Ctrl+P index) |
| `POST /tui/select-session` switches a live attached TUI to *any* existing session | Created a placeholder + attached + created a second session post-attach + called the endpoint → response `true`, pane re-rendered with new session title and context panel |
| `POST /session` does **not** accept a `directory` field; sessions inherit serve cwd | OpenAPI schema dump + live POST |
| opencode's `message`/`part` tables store `data` as plain JSON; `role: "assistant"`, `role: "user"` both observed | `sqlite3` PRAGMA + sample rows |
| `POST /tui/publish` accepts `EventMessagePartDelta` and other internal events | OpenAPI schema dump |
| `opencode session delete <id>` and `DELETE /session/<id>` exist for cleanup | CLI + OpenAPI |

## Goals

- Pane perceived-paint goes from ~15 s to **sub-second** for the user's *first* agent open in an `aiur` run.
- Historical agent activity renders **as if the agent typed it in real time** — agent text styling, command/output formatting, time-ordered, scrollable, never a blue user bubble.
- Agent's *live* output (after the pane is open) appends to the chat automatically with no user input required.
- Opencode session count in `~/.local/share/opencode/opencode.db` stays bounded per-aiur-run; clean exits leave nothing behind.

### Non-goals (deferred)

- Pre-warming for **every** subsequent agent open in the same `aiur` run. v1 is "first open only" so we can prove the architecture; the second-and-onward pre-warm is a fast follow (see [v2: background session population for Ctrl+P navigation](#v2-background-session-population-for-ctrlp-navigation)).
- Replacing opencode entirely.
- Generalising the history-injection mechanism to non-opencode UIs.
- Migrating to a hypothetical opencode build with a public assistant-message API (none exists today).

### v2: background session population for Ctrl+P navigation

Once v1 is proven (single pre-warm makes the *first* agent open fast and SQLite injection makes history + live output behave correctly), v2 turns the pre-warmed opencode pane into the user's **universal chat surface**:

- As soon as the pre-warmed serve is up, Aiur creates an opencode session for **every** agent in the active list (not just the one the user is about to open). One `POST /session` per identifier, async; cheap because no Bun process is involved.
- The per-identifier SQLite writers from v1 §C/§D run for **all** sessions in parallel, so historical transcripts backfill and live agent output streams into each session continuously, even when the user isn't looking at that session.
- The user opens one pane (still via Aiur's agent-list `Enter`). From there, they use **opencode's native `Ctrl+P` session picker** to jump between agent conversations without returning to the agent list. The pane stays the same; only the active session changes (via `POST /tui/select-session`, which we already use in v1).
- New agents that appear later in the run get a session created in the background as soon as Aiur sees them.
- Closed/terminal agents have their sessions deleted by the existing cleanup path so the Ctrl+P picker doesn't fill with dead conversations.

Implications carried back into v1 design so v2 is a small follow-up rather than a rewrite:

- The SQLite writer must be **per-identifier**, not per-pane-open. A single `Aiur.Opencode.SessionWriter` GenServer per active agent, supervised by a dynamic supervisor, scales naturally from "one writer for the open agent" to "one writer per active agent".
- Session-creation logic should be a small standalone function (`Aiur.Opencode.SessionRegistry.ensure(identifier)`) so v2 can call it for every agent at boot without touching pane-open code.
- The pre-warm hidden pane should be reusable across multiple `select-session` switches without restart (v1 already needs this for cold/warm fallback, so we get it for free).

v2 is **not** in scope for this brainstorm or the upcoming plan — it ships only after v1 is confirmed working end-to-end. The note here just keeps v1's module boundaries from painting v2 into a corner.

## Approach

### A. Background pre-warm on `aiur` startup

- At `aiur` boot, spawn one shared `opencode serve` in a neutral cwd (e.g. `<state-dir>/opencode-warm/`) **in parallel with the agent-list initial poll**. Cwd is neutral, not a workspace, because (1) opencode tools are denied (`bash`/`edit`/`webfetch` per `Aiur.Opencode.Protocol.opencode_json/1`) so cwd is cosmetic, and (2) we want the warm serve to be usable for any agent the user picks first.
- Immediately after the serve binds, spawn one `opencode attach <warm-url> --session <placeholder>` in a **hidden tmux window** on the existing aiur tmux socket. Use a deliberately empty placeholder session created via `POST /session`.
- The placeholder session is created with `model: {providerID: "aiur", id: "placeholder"}` so the bridge can recognise and ignore any stray chat-completion calls.
- Pre-warm timing budget: the ~6.7 s should land inside aiur's existing tracker-poll + agent-list initial-paint window. If it isn't ready when the first user open arrives, fall back to cold-start (no regression).

### B. First-agent open: instant via session-switch + pane move

When the user opens their first agent of the run:

1. Aiur ensures an opencode session exists for that identifier (`POST /session` with `title: "<identifier>"`, `model: {providerID: "aiur", id: "issue-<identifier>"}`).
2. Aiur writes any **prior** transcript history for that identifier into the new session via SQLite (see §C).
3. `POST /tui/select-session <session-id>` switches the pre-warmed attached TUI to the agent's session.
4. `tmux join-pane -s <hidden-pane> -t <visible-window>` grafts the hidden pane into the visible layout, preserving the running process.

For *subsequent* agent opens in the same run, v1 falls back to today's cold-start path. The loading-placeholder shell script (`scripts/aiur-pane-loading`) is **removed**; cold panes show whatever opencode shows during attach.

### C. History as agent-typed: SQLite injection

- Replace `Aiur.Opencode.TranscriptRelay`'s POST-based history replay with a writer that INSERTs into opencode's `message` and `part` tables directly.
- Each historical transcript event becomes one `assistant`-role message + one or more parts (text, tool-call/tool-result for commands, etc.) following the JSON shapes opencode's TUI already renders.
- Writes happen **before** the TUI is switched to the session, so when `select-session` fires, opencode reads the full history on first render.
- History source is `Aiur.IssueLog.disk_history/2` (already present from commit `b0206e5`).

### D. Live output: continuous SQLite append + TUI nudge

- A long-lived per-identifier writer subscribes to `AgentPubSub` for that agent (replacing `Aiur.Opencode.TranscriptRelay`'s broken POST path).
- Every transcript event → SQLite INSERT + `POST /tui/publish` with an `EventMessagePartDelta` so the attached TUI re-renders without polling.
- The writer keeps running for the lifetime of the pane (i.e. for the lifetime of the agent run, since v1 keeps the pane open across re-opens).

### E. Session cleanup at shutdown

- `Aiur.Application.stop/1` (or a registered shutdown hook) walks `AgentPubSub`-known identifiers + the placeholder session and calls `DELETE /session/<id>` for each. Bounded best-effort timeout (~5 s).
- Belt-and-suspenders boot-time GC: enumerate sessions whose title looks like a tracker identifier no longer in the active set, and delete them. Skips the placeholder pattern so it doesn't fight the warm-up.

### F. opencode version pin

- `elixir/mise.toml` switches `opencode = "latest"` → `opencode = "1.15.6"`.
- Schema changes in a future opencode version are surfaced by a deliberate bump + re-verification, not by a silent break.

## Acceptance criteria

1. With a fresh DB and a fresh `aiur` start, the user's first agent open shows the opencode chat **within 500 ms** of pressing Enter, with the agent's prior transcript visible at the top.
2. While the pane sits open, every new agent message/command from `Aiur.AgentPubSub` appears in the chat within **~1 s** of the underlying transcript event, styled as agent output (not as a user bubble).
3. Killing aiur cleanly (Ctrl+C → SIGTERM, or `aiur stop`) leaves **zero opencode sessions** in `opencode.db` that aiur created in that run.
4. The second agent open in the same run cold-starts (acceptable for v1) but no longer shows a fake loading placeholder.
5. `mix test`, `mix format --check-formatted`, `mix specs.check` all green. opencode pinned to 1.15.6 in `mise.toml`.

## Dependencies / assumptions

- opencode 1.15.6 keeps `POST /tui/select-session`, `POST /tui/publish`, `POST /session`, `DELETE /session/<id>` and the `message`/`part` table shapes stable. Pinning the version protects against drift; a bump triggers re-verification.
- tmux 3.5+ (`join-pane` semantics we depend on are present in the existing `scripts/aiur.tmux.conf`).
- The bridge already identifies the agent from the `model` field (`Aiur.Opencode.ChatCompletions.identifier_from_model/1`); the per-session model trick reuses that path.

## Risks

- **Pre-warm consumes ~250 MB resident** for the hidden opencode procs. Acceptable for a single-user dev tool. Re-evaluate if multi-pre-warm lands.
- **opencode's `message.data` JSON shape is not a public API.** Pinning + a focused integration test reading back what we wrote mitigates this; if 1.16 changes the shape, the bump is gated on updating the writer.
- **First open after aiur boot but before pre-warm finishes** still cold-paths. Acceptable as a regression-free fallback.

## Open questions handed to planning

These were intentionally left for `/ce-plan` because they're design choices, not product choices:

- Exact module split (single `Aiur.Opencode.Prewarm` vs separate `WarmServer` / `WarmAttach` / `DbWriter` / `Cleanup`).
- Whether the SQLite writer goes through `Sqlitex`/`Exqlite` or shells out to the `sqlite3` CLI (the latter avoids a new dep).
- Whether `tmux join-pane` reliably preserves the running process when crossing windows on aiur's socket configuration (needs a quick spike at plan time).
- Exact tagging strategy for "sessions aiur owns" so cleanup is precise (title prefix vs a sentinel in `data`).
- How to surface the rare "pre-warm not yet ready when first agent opens" case to the user (likely a one-line system message, but planning decides).

## Out of scope for this brainstorm

- Brainstorming a different chat front-end (opencode is the chosen surface).
- Multi-user / multi-aiur-instance coordination over the same opencode DB.
- Pre-warming a *pool* of N panes (deferred to v2; v1 ships single pre-warm).
