---
date: 2026-05-17
branch: feat/cli-pane-rearchitecture
status: draft
follows: 2026-05-16-cli-rearchitecture-brainstorm.md
---

# CLI pane bug fixes — post-cutover

## Context

`feat/cli-pane-rearchitecture` cut over to the new two-pane CLI on 2026-05-16.
Manual testing of `./scripts/agents` confirmed the happy path works
(agent-list renders, Enter spawns a conversation pane, typing flows through),
but surfaced six gaps that need to ship before the branch merges. This doc
captures the design decisions; `/ce:plan` will turn them into a sequenced
implementation plan.

## What we're building

Six fixes/restorations, in priority order:

1. **Restore the bordered "SYMPHONY STATUS" header** in the agent-list pane
   — outer border + metadata rows (project, dashboard URL, next refresh).
   Reference: `git show main:elixir/lib/symphony_elixir/status_dashboard.ex`
   around the `format_title_row`, `running_header_row`, and
   `right_project_lines` helpers.
2. **Restore the agent-list metadata table** — ID / TAG / STATE / ISSUE /
   AGE-or-TURN columns. Reference: the `running_table_header_row` and
   per-row format helpers in the same file.
3. **Fix the composer chrome** — replace the overflowing dashed separator
   with one blank row, an input row with a subtly-tinted background, one
   blank row. Use the input-bg ANSI from the old composer
   (`@ansi_input_dark_bg "\e[48;5;236m"` etc.).
4. **Make the agent transcript render** in the conversation pane. Root
   cause: `Conversation.subscribe_remote/2` calls
   `Phoenix.PubSub.subscribe(...)` via `:rpc.call`, which subscribes the
   temporary RPC worker on the symphony node instead of the pane
   GenServer. The worker dies on RPC return, so no events arrive.
5. **Add Symphony-owned pane controls** (Tab / Shift+Tab / Ctrl+C) without
   assuming the user knows tmux defaults — and without touching the
   user's existing tmux server or config.
6. **Force "split right" layout** for every new conversation pane with
   auto-rebalance and auto-focus on the new pane.

A seventh task — re-evaluating whether full-frame ANSI rendering actually
flashes — is **deferred until #4 lands**. The "flash" the user saw may be
the agent-list title redrawing in isolation because the transcript region
was empty. Re-test once transcripts render.

## Why this approach

### Tmux isolation (covers #5)

The wrapper must not interfere with whatever the user already runs in
tmux. Decision:

- Run on an **isolated tmux socket**: `tmux -L symphony-${USER} ...`.
  Independent server, can't see or be seen by `tmux -L default`.
- Use a **custom config file**: `tmux -f <path> ...`. `~/.tmux.conf` and
  other system configs are ignored on this socket.
- **Error out if `$TMUX` is set.** That env var is exported into every
  shell tmux owns, so its presence means "the user already attached to
  a tmux session." The wrapper prints
  `Open a fresh terminal without tmux and try again.` and exits 1.

### Conf shipping (covers #5)

Decision: **default in repo + override outside repo.**

- `scripts/symphony.tmux.conf` is the tracked default. Discoverable,
  readable, version-controlled.
- Wrapper preference order:
  1. `$SYMPHONY_TMUX_CONF` (explicit override)
  2. `${XDG_CONFIG_HOME:-$HOME/.config}/symphony/tmux.conf`
  3. `<repo>/scripts/symphony.tmux.conf`
- A user who wants custom keybinds copies the default to `~/.config/`
  and edits there. `git pull` never touches their copy.

Downside accepted: edits to the in-repo default will produce PR diff
churn whenever bindings change. Acceptable cost for discoverability.

### Pane control bindings (covers #5)

In `scripts/symphony.tmux.conf` (subject to refinement):

```
# Symphony-owned bindings on an isolated socket
set -g prefix none
set -g escape-time 0
set -g mouse on

bind-key -n Tab    select-pane -t :.+
bind-key -n BTab   select-pane -t :.-
bind-key -n C-c    if -F '#{==:#{pane_index},0}' \
                     'kill-session' 'kill-pane'

# Open new panes to the right of the rightmost pane; rebalance widths
set-hook -g after-split-window 'select-layout even-horizontal'
```

`Ctrl+C` is the only contentious one — it normally sends SIGINT. Inside
agent code that runs in pane 0+ we'd want SIGINT to interrupt agent
work, not close the pane. Symphony's BEAM panes don't shell out
interactively, so this conflict only matters for the optional debug
shell case. **Open question** below.

### Transcript subscribe (covers #4)

**Root cause** (confirmed via reading
`elixir/lib/symphony_pane/conversation.ex`,
`elixir/lib/symphony_elixir/conversations.ex`,
`elixir/lib/symphony_elixir/pane_rpc.ex`):

The pane GenServer's `init/2` calls
`subscribe_remote/2` → `:rpc.call(symphony_node, PaneRPC,
:attach_conversation, [identifier])`. On the symphony node, that runs
`Conversations.attach/1` → `Phoenix.PubSub.subscribe(@pubsub, topic)`,
which subscribes `self()`. But `self()` inside an `:rpc.call` is the
**temporary worker process** that the RPC bookkeeper spawns to run the
function. That worker returns the result and exits; PubSub auto-cleans
the subscription on `:DOWN`. The pane GenServer is never subscribed.

**Fix**: subscribe **locally on the pane BEAM** via
`AgentPubSub.subscribe_agent(identifier)` from `Conversation.init/2`.
The pane node already runs `Phoenix.PubSub` under the same registry
name (`SymphonyElixir.PubSub`); PG2 distributes via cluster-global
`:pg` groups so a local subscribe receives remote broadcasts as long as
the two nodes are connected (which they are — `Node.connect/1` already
runs, and `:rpc.cast` on the same node already works for the operator
message path).

**Follow-up risk**: `AgentChat.send/3` broadcasts a `:user` transcript
event after the orchestrator accepts. The pane already appends an
optimistic-echo `:user` event before the cast returns. With the fix,
the pane will see **both** and double-render. Either drop the
optimistic echo (one BEAM round-trip of latency, ~5ms locally — likely
imperceptible) or add msg_id dedup. Decision: drop the optimistic
echo for simplicity; revisit only if it feels laggy under load.

### Header + table restoration (covers #1, #2)

Port the helpers from `main:status_dashboard.ex` into
`agent_list/renderer.ex` as pure functions. Keep the renderer pure
(state map in → iodata out) so we can unit-test it with snapshots.
Reuse the column widths (`@running_id_width = 6` etc.) and the
`format_cell/2` truncation logic verbatim — they were tuned for
Termius and rural-coffee-shop SSH.

### Composer chrome (covers #3)

Replace the `pad_line(String.duplicate("─", inner_width), ...)`
separator in `symphony_pane/viewport.ex` with a three-row sandwich:

- blank row (background tint or default)
- prompt + buffer + cursor (background tint, e.g. `\e[48;5;236m`)
- blank row

No box-drawing characters. Width math is a no-op because every row gets
padded to `inner_width` with `\e[K` (clear-to-end-of-line) after the
content, which works regardless of column count.

### Split-right layout (covers #6)

`PaneManager.open_conversation/3` already opens panes via
`Tmux.spawn_pane_for/2`, which today runs `split-window -h -t <session>:`
(splits the *currently focused* pane horizontally). Change two things:

1. Target the rightmost pane explicitly:
   `split-window -h -t ${SYMPHONY_TMUX_SESSION}:.{right}`
2. After the split, call `select-layout even-horizontal` to rebalance
   widths, and `select-pane -t <new-pane-id>` to focus the new pane.

The `set-hook -g after-split-window 'select-layout even-horizontal'`
line in the conf handles the rebalance automatically; the explicit
`select-pane` is still needed because `split-window -P` returns the new
pane id but doesn't focus it unless you ask.

## Key decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Run Symphony's tmux on isolated socket `symphony-$USER` | Doesn't touch user's normal tmux server |
| 2 | Load conf via `-f`, default in repo + override in `~/.config/symphony/` | Discoverable defaults, safe overrides |
| 3 | Error on `$TMUX` set (don't try to nest) | Sidesteps nesting edge cases; clear UX |
| 4 | Tab / Shift+Tab → select-pane in conf; Ctrl+C in pane 0 → kill-session, else kill-pane | All at tmux layer, zero BEAM round-trips |
| 5 | Subscribe to per-agent PubSub topic **locally** on pane BEAM, drop the `:rpc.call` path | Fixes the temporary-worker subscription bug |
| 6 | Drop optimistic local echo on submit; rely on AgentChat broadcast | Single source of truth, avoids dedup logic |
| 7 | Defer the "flashing" question until transcripts render | Empty-transcript redraw may be the only visible "flash" |

## Open questions

1. **Backfilling transcript history on attach.** Opening a conversation
   pane subscribes to *future* events. The agent might have been
   running for an hour with rich history. Out of scope for this branch,
   but worth a follow-up.

## Out of scope

- Mosh / web SSH client compatibility beyond Termius (deferred to a
  future "transport" doc).
- Multi-window tmux layouts (we're committed to single-window-many-panes).
- Agent-to-agent pub/sub on the conversation pane (future feature; not
  blocking this branch).

## Resolved questions

- Q: Should Symphony capture pane keys in raw mode or let tmux handle?
  A: Tmux handles via `bind-key -n` on the isolated socket.
- Q: Where does the conf live?
  A: Default in repo at `scripts/symphony.tmux.conf`; override in
  `~/.config/symphony/tmux.conf`; explicit override via
  `$SYMPHONY_TMUX_CONF`.
- Q: How do we avoid clobbering the user's existing tmux?
  A: Isolated socket + custom conf + error-out if `$TMUX` is set.
- Q: Ctrl+C semantics in a conversation pane — does closing the pane
  block the user from interrupting the agent?
  A: Pane closes unconditionally on Ctrl+C. Interrupting an in-flight
  agent operation is a separate, future key (likely `/cancel` slash
  command or a dedicated keybind).
- Q: Should the BEAM trap shutdown and flush state before tmux tears
  the socket down?
  A: Not for now. Tmux `kill-session` SIGHUPs the BEAM; OTP's normal
  shutdown handles tracker flushes via `Application.stop`. Revisit
  only if we see lost-write incidents.
