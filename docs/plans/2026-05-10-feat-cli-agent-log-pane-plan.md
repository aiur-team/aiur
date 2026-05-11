---
title: CLI agent log pane
type: feat
status: active
date: 2026-05-10
origin: docs/brainstorms/2026-05-10-cli-agent-log-pane-brainstorm.md
branch: symphony/agent-log-pane
---

# CLI agent log pane

## Overview

Pressing `space` or `enter` on the foreground `agents` CLI dashboard expands the currently-selected running agent into a log pane that fills the rest of the terminal. The pane reuses the same chat-style parser that powers the web dashboard's per-agent log modal. While the pane is open, the "Backoff queue" section is hidden and a single-line bordered input placeholder is reserved at the bottom for the eventual chat/interrupt feature (no input behavior is wired in this PR). `left` arrow and `esc` close the pane. `PgUp`/`PgDn` scroll the log; new events autoscroll into view unless the user has scrolled up. `j`/`k`/arrows still move the selection and the pane reloads to the newly-selected agent's log.

## Problem Statement

After PR #10, the operator can navigate between running agents with `j`/`k`/arrows but cannot drill into one without leaving the terminal for the web dashboard. The web dashboard's per-agent log modal solves this problem for browser users; CLI operators (SSH/Termius sessions, runbooks) currently have no in-terminal equivalent and must either `tail` `logs/agent.md` directly or open the LiveView in a browser. The CLI is the only operator surface for a chunk of users on this machine, and surface parity with the web view is the next blocker for trusting the CLI as the primary control plane.

The brainstorm (`docs/brainstorms/2026-05-10-cli-agent-log-pane-brainstorm.md`) settled the WHAT in detail. This plan is the HOW.

## Proposed Solution

Treat the dashboard as a state machine with two view modes: `:list` (today's behavior) and `:log` (new). The keyboard reader stays stateless and dispatches all keys as casts; the dashboard ignores casts that don't apply to the current mode. The chat-style log parser currently embedded as private helpers in `SymphonyElixirWeb.DashboardLive` (see `repo research §1`) is extracted into a new shared module `SymphonyElixir.AgentLog` that both the LiveView modal and the CLI pane consume. The CLI pane renders the parsed messages as ANSI text (matching the dashboard's existing color palette), bounded to the available terminal height computed from `:io.rows()` with a `ROWS` env override (mirroring the existing `COLUMNS`/`terminal_columns_from_env/0` pattern in `status_dashboard.ex:836-847`).

The pane reads `<workspace_path>/logs/agent.md` on each dashboard tick — same source-of-truth as the LiveView modal — so the existing tick pipeline gives us live updates for free.

## Technical Approach

### Architecture

**View-mode state on the StatusDashboard struct.** A new `:view` field replaces the implicit "always list" assumption:

```elixir
@type log_view :: %{
        issue_identifier: String.t(),
        workspace_path: String.t() | nil,
        scroll: non_neg_integer(),
        last_total_lines: non_neg_integer()
      }

@type view :: :list | {:log, log_view()}

# %SymphonyElixir.StatusDashboard{
#   ...existing fields...,
#   selected_index: non_neg_integer() | nil,
#   view: view()
# }
```

`scroll` is the offset from the bottom of the rendered log, measured in **rendered lines** (not messages, since message bodies wrap). `scroll == 0` means "stuck to bottom — new events autoscroll into view." Any positive value pins the view at a specific historical position; the user resumes auto-scroll by paging back down to 0.

Rationale: scroll offset is naturally derived from line count, the render path already produces a list of lines, and a single integer field captures both "sticky" and "scrolled" without a separate flag (`scroll == 0` ↔ sticky). `last_total_lines` is updated by the renderer each frame and consulted by `{:scroll_log, _}` casts so they can clamp **without re-reading the log file** — avoiding O(keypresses) file I/O when the operator holds down PgUp.

If `last_total_lines ≤ pane_lines` (i.e., the entire log fits in the pane), `{:scroll_log, _}` clamps `scroll` to `0`. PgUp/PgDn become silent no-ops.

**Why store `workspace_path` in the view, not derive it per-tick from `selected_index`?** Because the brainstorm requires the pane to stay open and keep showing the selected agent's final log after the agent transitions out of `running`. At that point `selected_index` no longer points to that agent in `state.snapshot.running`, so we cache the workspace_path the moment the pane is opened (or the moment `j`/`k` switches the pane to a different agent).

**New StatusDashboard public API:**

```elixir
@spec open_log(GenServer.name()) :: :ok
@spec close_log(GenServer.name()) :: :ok
@spec scroll_log_up(GenServer.name()) :: :ok    # toward older entries
@spec scroll_log_down(GenServer.name()) :: :ok  # toward newer entries
```

Each is a `GenServer.cast` returning `:ok`. Casts are no-ops when in the wrong view mode; this keeps the keyboard reader stateless.

**Snapshot fingerprint extended.** Today's fingerprint at `status_dashboard.ex:235` is `{snapshot_data, state.selected_index}`. Extend to `{snapshot_data, state.selected_index, state.view}` so a view change triggers a re-render even when the underlying snapshot is unchanged.

**Extracted parser module.** New `SymphonyElixir.AgentLog` (under `elixir/lib/symphony_elixir/agent_log.ex`). Public API:

```elixir
@spec workspace_log_path(workspace_path :: String.t() | nil) :: String.t() | nil
@spec read(path :: String.t() | nil) :: String.t()
@spec parse(content :: String.t()) :: [log_message()]

@type log_message :: %{
        role: String.t(),    # "user" | "assistant" | "system" | "tool"
        title: String.t(),
        timestamp: String.t(),
        body: String.t()
      }
```

The bodies of `agent_log_path/1`, `read_agent_log/1`, `parse_agent_log/1`, `parse_log_entry/3`, `parse_json_log_entry/4`, `compact_log_messages/1`, `compact_log_message/2`, `merge_log_message/3`, `content_text/1`, `summarize_prompt/1`, `log_message/4`, `humanize_event/1`, `summarize_payload/1`, `command_title/1`, `command_summary/3`, `auth_failure_output?/1`, and `blank_to_placeholder/1` move verbatim from `dashboard_live.ex`. The LiveView keeps the orchestrator wrapper functions (`agent_log_modal/1`, `refresh_agent_log_modal/2`, `refresh_agent_log_modal_from_path/1`, `find_running_entry/2`) and the HTML template (`log_message_class/1` and the `:for` render block).

**Terminal-height awareness.** Mirror the existing column pattern:

```elixir
defp terminal_rows do
  terminal_rows_from_env() || fallback_terminal_rows()
end

defp terminal_rows_from_env do
  case System.get_env("ROWS") do
    nil -> nil
    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end
  end
end

defp fallback_terminal_rows do
  case :io.rows(:standard_io) do
    {:ok, n} when n > 0 -> n
    _ -> 40  # safe default
  end
end
```

Thread `terminal_rows` into `format_snapshot_content/4` as an additional parameter (alongside the existing `terminal_columns_override`). Tests pass an explicit value.

**Renderer branch.** `format_snapshot_content` gets a top-level `case state.view` (or its equivalent passed-through value):

- `:list`: status header → running list → backoff queue → closing border (current behavior).
- `{:log, log_view}`: status header → running list → log pane → input placeholder → closing border. No backoff queue.

The log pane's height is computed as:

```
log_pane_lines = terminal_rows
                 - header_lines
                 - running_list_lines
                 - log_pane_chrome_lines    # divider + "Agent log: <id>" header
                 - input_placeholder_lines  # 2 lines (header + bordered row)
                 - closing_border_lines
                 |> max(@min_log_pane_lines) # e.g., 3
```

If the agent has fewer rendered lines than the budget, render what we have (no padding). If more, render `[start..start + pane_lines - 1]` where `start = max(0, total_lines - pane_lines - scroll)`. Scroll is clamped to `[0, max(0, total_lines - pane_lines)]` inside `handle_cast({:scroll_log, dir}, …)` using `last_total_lines` from view state (no file re-read).

**Graceful degrade for tiny terminals.** If `terminal_rows` produces a computed `log_pane_lines < @min_log_pane_lines` (e.g., a 5-row window where header + list already consume most of the budget), the renderer falls back to `:list` mode for this frame. The state stays `{:log, _}` so resizing larger restores the pane on the next render. A snapshot fixture at `terminal_rows = 5` documents this.

**Cursor parking.** After each full-clear-and-redraw, the cursor is parked at row 1, col 1 (the existing `IO.ANSI.home()` already does this) so the placeholder input row does not appear "active." No need for `\e[?25l` (hide-cursor) — the dashboard never moves the cursor away from the home position anyway.

### Implementation Phases

#### Phase 1 — Extract chat parser to shared module

- Create `elixir/lib/symphony_elixir/agent_log.ex` with the helpers listed above. Add `@spec` to every public function (AGENTS.md L37 / `mix specs.check`).
- Update `dashboard_live.ex` to delegate to `SymphonyElixir.AgentLog` for parsing. Keep `agent_log_modal/1`, `refresh_agent_log_modal/2`, `refresh_agent_log_modal_from_path/1`, `find_running_entry/2`, `log_message_class/1` in the LiveView (they're view-layer concerns).
- Add `elixir/test/symphony_elixir/agent_log_test.exs` with unit coverage for each `parse_json_log_entry/4` branch: `item/started userMessage`, `item/agentMessage/delta` (with and without `itemId`), `item/completed agentMessage`, `warning`, `item/completed commandExecution` (success path returning nil; non-zero exit; auth failure), and the fallback `parse_json_log_entry/4` clause.
- Run existing LiveView tests; they must continue to pass without modification.

**Deliverables:** new module + tests; LiveView still green; no behavior change.

**Effort:** Medium.

**Success criteria:**
- `mix test` clean.
- `mix specs.check` clean.
- LiveView modal renders identically to pre-change.

#### Phase 2 — Thread `workspace_path` into the dashboard's view of running entries

- Confirm the dashboard already receives `workspace_path` in its snapshot. The presenter exposes it at `presenter.ex:69, 104, 127, 134`. Verify by reading the snapshot shape that reaches `format_running_summary/3`.
- If absent: add it to the snapshot map produced by the orchestrator / presenter pipeline. Otherwise no code change.

**Deliverables:** confirmation patch (or no-op).

**Effort:** Small.

**Success criteria:** `format_running_summary` has access to a running entry's `workspace_path`.

#### Phase 3 — Add view-mode state and cast API to StatusDashboard

- Add `:view` field to the struct, default `:list`. Update `defstruct` and `@type`.
- Update `init/1` to set `view: :list`.
- New public API: `open_log/1`, `close_log/1`, `scroll_log_up/1`, `scroll_log_down/1` (with `@spec`).
- Cast handlers:
  - `{:open_log}`: if `state.selected_index` points to a running entry, set `view: {:log, %{issue_identifier: id, workspace_path: path, scroll: 0, last_total_lines: 0}}`. **No-op** if there is no running entry (e.g., empty `running` list, or `selected_index == nil`). Trigger render.
  - `{:close_log}`: set `view: :list`. Trigger render. Reopening later builds a fresh `log_view` with `scroll: 0`, so close+reopen resets to bottom.
  - `{:scroll_log, :up | :down}`: only when `state.view` matches `{:log, _}`. Adjust `scroll` (up = +1, down = −1). Clamp to `[0, max(0, last_total_lines - pane_lines)]` using the renderer-supplied `last_total_lines` (no file re-read). If `last_total_lines == 0` (renderer hasn't run yet) treat as 0.
  - `{:select_agent, _}` already exists; extend it: if `state.view` is `{:log, _}`, **after** moving `selected_index`, replace the view's `issue_identifier` / `workspace_path` with the new selection's values and reset `scroll: 0`. The selection logic itself is unchanged — it follows whatever `move_selected_index/3` already does (today: clamped, no wrap). If selection is a no-op (at boundary), the pane is also a no-op — no reload, no scroll reset. If new selection's `workspace_path` is `nil` (remote-worker agent), the cached `workspace_path` becomes `nil` and the renderer shows the "No local workspace path is available" placeholder for that agent. If `running` is empty when `{:select_agent, _}` arrives, the cast is a no-op and the pane keeps rendering its cached agent's final log.
- Update fingerprint to include `state.view`.

**Deliverables:** state plumbing + cast API. No render changes yet — `format_snapshot_content` still ignores `:view`. Manual smoke: open the pane via `iex`-driven cast, observe no visual change but `state.view` updates.

**Effort:** Medium.

**Success criteria:**
- New casts have unit test coverage in `status_dashboard_test.exs`.
- Existing snapshot tests still green.

#### Phase 4 — Terminal-rows awareness

- Add `terminal_rows/0` / `terminal_rows_from_env/0` / `fallback_terminal_rows/0` in `status_dashboard.ex` mirroring the `terminal_columns` family at L826-847.
- Add `terminal_rows_override` argument to `format_snapshot_content/4` (now /5), with corresponding test alias.
- Existing snapshot fixtures: regenerate via `UPDATE_SNAPSHOTS=1 mix test` — they should NOT change unless we render fewer lines for `:list` mode (we don't; `:list` ignores rows).

**Deliverables:** rows plumbing.

**Effort:** Small.

#### Phase 5 — Render the log pane and input placeholder

- New private renderer `format_log_pane/4` taking `(log_view, terminal_columns, terminal_rows, header_and_list_height)` and returning iodata.
- Read agent log: `SymphonyElixir.AgentLog.read(SymphonyElixir.AgentLog.workspace_log_path(log_view.workspace_path)) |> SymphonyElixir.AgentLog.parse()`.
- Render each `log_message` as a chat-style row using existing ANSI helpers (`colorize/2`, the `@ansi_*` palette). Wrap long bodies to `terminal_columns - <left padding>`. Compute `total_lines` after wrapping; slice via `scroll`.
- New `format_input_placeholder/1` renders the bordered single-line `│ > [send disabled — coming soon]                                  │`.
- When `state.view` is `{:log, _}`: render pipeline omits `format_retry_rows`/backoff section; appends pane + placeholder before `closing_border/0`.
- Renderer updates `state.view.last_total_lines` after each render. Subsequent `{:scroll_log, _}` casts use this stashed value to clamp without re-reading the log file. (Earlier draft proposed re-reading on each scroll cast — rejected to avoid O(keypresses) I/O when the operator holds PgUp.)

**Snapshot fixtures (new):** add seven scenarios in `elixir/test/fixtures/status_dashboard_snapshots/`:
- `log_pane_at_bottom.snapshot.txt` / `.evidence.md` — pane open, scroll 0, ~20 messages.
- `log_pane_scrolled.snapshot.txt` / `.evidence.md` — pane open, scroll 5.
- `log_pane_empty_log.snapshot.txt` / `.evidence.md` — pane open, agent.md missing → placeholder text.
- `log_pane_finished_agent.snapshot.txt` / `.evidence.md` — pane open, agent no longer in `running`.
- `log_pane_remote_worker.snapshot.txt` / `.evidence.md` — pane open, selected agent's `workspace_path` is `nil` → "No local workspace path is available" placeholder.
- `log_pane_small_log.snapshot.txt` / `.evidence.md` — pane open, log fits entirely in pane (total_lines ≤ pane_lines), PgUp/PgDn are no-ops.
- `log_pane_tiny_terminal.snapshot.txt` / `.evidence.md` — `terminal_rows = 5`, pane is in `{:log, _}` state but renderer falls back to `:list` layout for this frame.

For each non-tiny scenario: verify backoff queue is absent and the input placeholder is present.

Drive each via `SymphonyElixir.TestSupport.Snapshot.assert_dashboard_snapshot!/2` with fixed `terminal_columns` and `terminal_rows` and a fixture agent.md file under `elixir/test/fixtures/agent_logs/` (or inline content via the existing snapshot helper).

**Deliverables:** rendered log pane in production; snapshot tests green.

**Effort:** Large.

**Success criteria:**
- Manual smoke in Termius shows the pane.
- Backoff queue toggles correctly between view modes.
- Snapshot tests cover all four scenarios.

#### Phase 6 — Wire keys in TerminalInput

Replace `read_escape_sequence/2` with a generic CSI parser:

```elixir
defp read_escape(dashboard, input_fun) do
  case input_fun.() do
    "[" -> read_csi(dashboard, input_fun, "")
    other -> handle_bare_escape(dashboard, other)
  end
end

defp read_csi(dashboard, input_fun, params) do
  case input_fun.() do
    <<c>> = byte when c in ?A..?Z or c in ?a..?z or c == ?~ ->
      dispatch_csi(dashboard, params, byte)
    byte ->
      read_csi(dashboard, input_fun, params <> byte)
  end
end

defp handle_bare_escape(dashboard, next_byte) do
  StatusDashboard.close_log(dashboard)
  dispatch_byte(dashboard, next_byte)   # treat the next byte as a normal keypress
end
```

Dispatch table for CSI sequences (collected `params` + final byte):

| Sequence | Action |
|---|---|
| `\e[A` (`""`, `"A"`) | `select_previous` (existing) |
| `\e[B` (`""`, `"B"`) | `select_next` (existing) |
| `\e[D` (`""`, `"D"`) | `close_log` (new — "left arrow") |
| `\e[5~` (`"5"`, `"~"`) | `scroll_log_up` (PgUp) |
| `\e[6~` (`"6"`, `"~"`) | `scroll_log_down` (PgDn) |
| any other | ignore |

Single-byte additions to `read_loop/3`:
- `" "` (0x20) → `open_log` (no-op when not in `:list` view or no agent selected)
- `"\r"` (0x0D), `"\n"` (0x0A) → `open_log` (same no-op rules)
- existing `j`/`k`/`q` unchanged

**Bare-ESC compound behavior.** Pressing `esc` followed quickly by another keystroke fires both: the `\e` triggers `close_log`, then the next byte is dispatched normally. So `esc` + `j` closes the pane AND advances selection in one step. This is intentional — it lets the user "close and keep navigating" without two distinct keypresses. A test in `terminal_input_test.exs` covers this exact sequence.

The bare-ESC handler works because pressing `esc` alone delivers `\e` and then the next byte the user types. Treating the `\e` as "close pane" and dispatching the next byte normally costs us nothing (the next byte is processed as a normal key). No 100ms timeout / non-blocking peek is needed — this is exactly the trick used by `vim`'s `:set noesckeys` interaction and is sufficient for this UI.

**Deliverables:** updated reader + dispatch.

**Effort:** Medium.

**Success criteria:** unit tests in `terminal_input_test.exs` cover every sequence above.

#### Phase 7 — Manual smoke in Termius

Run `agents` from a real Termius SSH session. Verify:

- Dashboard renders, no stair-stepping.
- `j`/`k`/arrows still move the `▶` marker.
- `space` opens the pane on the currently-selected agent. `enter` does the same.
- While the pane is open: backoff queue is hidden; input placeholder is visible.
- `j`/`k` switches the selection and reloads the pane to the new agent's log; scroll resets to bottom.
- `PgUp` / `PgDn` scroll the log; new events autoscroll in only when scrolled to bottom.
- `left` arrow closes the pane; backoff queue reappears.
- `esc` also closes the pane.
- Letting the selected agent transition out of `running` while the pane is open keeps showing its final log.
- `q` and Ctrl-C exit cleanly with the terminal restored.

If anything wedges: `stty sane` from any shell to recover.

**Deliverables:** demo notes / screenshots in PR description.

**Effort:** Small (assuming the implementation works first try).

## Alternative Approaches Considered

| Approach | Why rejected |
|---|---|
| Separate `AgentLogPane` GenServer composed into the dashboard | The pane has no independent lifecycle or persistent state worth isolating; it's a render mode of the dashboard. Over-engineered for this scope. (See brainstorm §Why This Approach.) |
| Duplicate the LiveView parser into a CLI-specific module | Faster to ship, but invites drift between web and CLI as the log format evolves. User explicitly chose the shared-module approach. (See brainstorm §Key Decisions: Code reuse.) |
| Inline a smaller CLI-only chat parser | Trades visual parity with the web modal for less code. User chose parity. (Same source.) |
| Parse `agent.ndjson` directly instead of `agent.md` | The existing parser is markdown-based (see repo research §1: regex on `## timestamp event\n\n\`\`\`text\nbody\n\`\`\``). `AgentRunner` writes both, but the parser is mature on `.md`. No reason to switch source format for this PR. |
| Use a 100ms timeout for bare ESC disambiguation | Erlang `IO` doesn't expose timeouts cleanly on `:stdio`; would require active-mode ports + buffering. The "treat ESC as close + dispatch next byte" pattern works without a timer. |
| Compute terminal rows from `tput lines` shell-out | We already shell out to `stty` once, but adding a per-tick shell-out is wasteful. `:io.rows()` is cheap. |
| Scroll by message instead of by line | Variable-height messages make this jarring (a 30-line tool output moves the pane 30 lines per keypress). Scrolling by line is the chat-app convention. |

## System-Wide Impact

### Interaction Graph

1. **Keystroke arrives** → `TerminalInput.read_loop/3` dispatches a `GenServer.cast` to `StatusDashboard` (existing pattern; new bindings added).
2. **`StatusDashboard.handle_cast({:open_log}, …)` / `{:close_log}` / `{:scroll_log, _}`** → updates `state.view`, invalidates fingerprint, calls `maybe_render/1`.
3. **`maybe_render/1`** → calls `format_snapshot_content/5` (new arity). If `state.view` is `:log`, the renderer calls `SymphonyElixir.AgentLog.read/1` + `parse/1` (file I/O on the orchestrator host's filesystem). Output written via existing `render_to_terminal/1` (full-clear + frame).
4. **Per-tick refresh** (`handle_info(:tick, …)` at L156-161) → same render path, picks up new agent.md content on each tick.
5. **`StatusDashboard.handle_cast({:select_agent, _}, …)`** (existing) → moves `selected_index`. NEW: when `state.view` is `{:log, _}`, also updates the view's `issue_identifier`/`workspace_path` and resets `scroll: 0`.

### Error & Failure Propagation

| Layer | Failure mode | Behavior |
|---|---|---|
| `File.read(agent_md_path)` returns `:enoent` (agent just started, file not yet flushed) | Existing `read_agent_log/1` returns the string `"Agent log has not been written yet."` (`dashboard_live.ex:457`). | `AgentLog.parse/1` produces the single placeholder message via the `messages == []` branch at L472. CLI pane shows the placeholder, no crash. |
| Workspace path is `nil` (remote worker; `AgentRunner` doesn't write the file) | `agent_log_path/1` returns `nil`; `read_agent_log/1` (nil clause at L461) returns `"No local workspace path is available for this session."` | Pane renders the placeholder. |
| Regex scan finds no matches (malformed log) | `Enum.reject(&is_nil/1)` removes them; if empty, placeholder message; otherwise the matches we did parse. | No crash. |
| `:io.rows(:standard_io)` errors (rare; e.g., stdin not a tty) | Falls back to `40` rows. | Pane sized to default; may look truncated on tall terminals but functional. |
| Reader process crashes during a CSI parse (e.g., garbage paste) | Already covered by the `restart: :temporary` failsafe added in PR #10 (`terminal_input.ex` post-cleanup). The TerminalInput GenServer logs and stops `:normal`. | Input dies, dashboard keeps running. |
| Cast for `{:scroll_log, _}` when view is `:list` | Cast handler matches only on `{:log, _}` view; otherwise it's a no-op fallback clause. | Silent ignore. |
| Selected agent finishes mid-render | `find_running_entry` returns nil; view state still holds the original `workspace_path`. File read continues to work as long as the workspace exists on disk. | Pane keeps rendering the final log. |
| `agent.md` is truncated or rotated between ticks | `last_total_lines` from previous render may exceed the new total; cast clamping uses the **previous** value briefly. | Next render computes a fresh `total_lines`, updates `last_total_lines`, and the next cast clamps correctly. One frame of slightly-off scroll position; acceptable. Covered by a regression test. |
| Tick fires while reader is mid-CSI parse | Reader and dashboard are separate processes; tick re-renders independently of the reader's blocking `IO.binread`. | No race. The cast that lands from the completed CSI parse triggers a follow-up render. |

### State Lifecycle Risks

- **Terminal raw mode** is already covered by `terminate/2` from PR #10 (`stty sane` via `/proc/self/fd/0` path). Pane open/close does not touch raw mode.
- **Selected agent disappears**: view holds onto `workspace_path` (caching its value at open / `select_agent` time), so we don't reach for a stale `state.snapshot.running` entry.
- **Scroll clamping**: a stale `scroll` value (e.g., scrolled 50 lines back, then log truncated) is bounded by the renderer's `max(0, total_lines - pane_lines)` floor. No crash; pane simply snaps to the new bottom.
- **No persistent state**: pane state lives in the GenServer only. Process restart returns to `:list` mode. Acceptable.

### API Surface Parity

The new functionality is consumed by:
- CLI: `TerminalInput` + `StatusDashboard` (this PR).
- Web: `SymphonyElixirWeb.DashboardLive`'s existing modal (no change in behavior; just calls into the extracted module).

There is no third surface (e.g., an `:agents` agent-callable API) that needs to be brought to parity. The web HTTP API already exposes the underlying snapshot via `GET /api/v1/state` and `GET /api/v1/:issue_identifier` — the "log content" is on-disk, not exposed via HTTP today. Out of scope here.

### Integration Test Scenarios

These are end-to-end scenarios that unit tests with mocks would miss:

1. **Open pane → agent emits new event → pane auto-scrolls.** Start a fake running agent with a small agent.md; cast `:open_log`; append a new `## … notification` block to the file; trigger a tick; assert the rendered output's last line reflects the new event.
2. **Open pane → scroll back → agent emits new event → pane does NOT jump.** Same setup; cast `{:scroll_log, :up}` 3 times; append; tick; assert the rendered output's last line still reflects the pre-append state.
3. **Open pane → j → pane reloads with new agent's log.** Two running agents with different agent.md content; cast `:open_log`; assert first agent's content rendered; cast `{:select_agent, 1}`; assert second agent's content rendered and scroll reset.
4. **Open pane → agent finishes (moves to completed) → tick → pane still shows final log.** Running agent with content; cast `:open_log`; remove it from `running` in the next snapshot; tick; assert content still rendered.
5. **Open pane → press `q` → terminal restored.** Drive the reader with a queued `" "` byte (open), then a `"q"` byte; verify `System.stop` is called and the `terminate` callback runs `stty sane`. (This is covered by PR #10's existing `terminate` path; this PR adds the pane-open precondition.)
6. **Log file truncated between ticks.** Open pane, scroll up 10 lines, then truncate the agent.md file to 5 lines. Trigger a tick. Assert no crash, pane renders the 5 lines, and `state.view.scroll` is clamped to 0 on the next `{:scroll_log, _}` cast.
7. **`esc` + `j` compound.** Open pane on agent A. Drive the reader with `"\e"` then `"j"`. Assert pane closes AND `select_next` is dispatched (selection moves to agent B).

## Acceptance Criteria

### Functional Requirements

- [ ] `space` opens the log pane on the selected running agent.
- [ ] `enter` opens the log pane on the selected running agent.
- [ ] `left` arrow closes the pane.
- [ ] `esc` closes the pane.
- [ ] `PgUp` scrolls older entries into view (one line per press).
- [ ] `PgDn` scrolls newer entries into view; reaching bottom resumes auto-scroll.
- [ ] `j` / `k` / arrow up / arrow down still move the selection in the agent list; while the pane is open, the pane reloads to the new selection's log and scroll resets to bottom.
- [ ] Pane content matches the web modal's chat-style messages (same parser).
- [ ] Pane updates on each dashboard tick (~1s) with new agent events.
- [ ] Backoff queue section is hidden while the pane is open.
- [ ] Single-line bordered input placeholder is visible below the log; no input behavior is wired.
- [ ] If the selected agent finishes while the pane is open, the pane keeps showing its final log.
- [ ] Pressing `space`/`enter` with no running agents (or no selection) is a no-op; no pane opens.
- [ ] Switching to a remote-worker agent (no local workspace) while the pane is open shows the "No local workspace path is available" placeholder.
- [ ] When `running` is empty while the pane is open, `j`/`k` are no-ops and the pane keeps rendering the cached final log.
- [ ] Closing the pane and reopening it resets scroll to the bottom.
- [ ] PgUp / PgDn are silent no-ops when the entire log fits in the pane.
- [ ] On a very small terminal (rows ≤ ~10) the renderer degrades to `:list` mode for that frame; resizing larger restores the pane.
- [ ] Pressing `esc` followed by `j` closes the pane AND advances selection in one step.
- [ ] `q` and Ctrl-C still exit cleanly with the terminal restored.

### Non-Functional Requirements

- [ ] Pane re-render does not block the dashboard's tick loop (file read is synchronous but bounded).
- [ ] No regressions to web dashboard's per-agent log modal rendering.
- [ ] `mix specs.check` passes (`@spec` on every new public function in `lib/`).
- [ ] Snapshot fixtures regenerate cleanly under `UPDATE_SNAPSHOTS=1 mix test`.

### Quality Gates

- [ ] `mix test`: 268+ tests, 0 failures.
- [ ] `mix lint` (specs.check + credo --strict) clean.
- [ ] `mix build` regenerates `bin/symphony`.
- [ ] At least one snapshot fixture per new view variant (4 new fixtures total).
- [ ] At least one unit test per `parse_json_log_entry/4` branch in the new `agent_log_test.exs`.
- [ ] At least one terminal_input test per new key sequence (space, enter, left, esc, PgUp, PgDn).
- [ ] Manual smoke in real Termius session documented in PR description.

## Success Metrics

This is a developer-tool feature with no analytics. Success is measured by:
- Operator no longer has to leave the terminal to read an agent's log during a run.
- Reuse: the LiveView modal continues to work identically (the shared parser is the proof point).
- No reported regressions to existing CLI behavior (selection, exit, raw mode).

## Dependencies & Prerequisites

- Branch `symphony/agent-log-pane` is already cut from `main` post-PR #10 merge.
- `AgentRunner` writes `logs/agent.md` for local workers only (`agent_runner.ex:223-245`). Remote-worker agents will show the "No local workspace path is available" placeholder; out of scope to fix here.
- `Jason` (already in deps) for JSON parsing in `parse_log_entry/3`.
- No new dependencies.

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Reading large `agent.md` files on every tick becomes slow | Medium (long agent runs accumulate MB of log) | Pane re-render lags the tick | Phase 1: ship as-is; instrument `AgentLog.read/parse` timing if it gets reported. Optimization options: (a) cache by file mtime + size, (b) tail-read last 64KB, (c) reduce tick frequency when in `:log` mode. None needed for first cut. |
| `:io.rows(:standard_io)` returns unexpected values under mise/escript launch | Low | Pane sized wrong | Fallback to `ROWS` env var (matches existing `COLUMNS` pattern); fallback to 40 rows constant; never crash. |
| Bare-ESC dispatch swallows a meaningful key | Low | One keystroke after `esc` is treated as close + that key | Acceptable. Tests cover the common pairs (esc, esc-j, esc-arrow). |
| LiveView parser extraction breaks the web modal | Medium (lots of moving private functions) | Web log view broken | Phase 1 is verbatim move + existing LiveView tests must pass before proceeding to phase 2. |
| Snapshot fixture noise (ANSI escapes hard to read in diffs) | Low | Reviewer fatigue | The existing fixtures already have this; paired `.evidence.md` stripped variants help. |
| Variable-width unicode in agent.md (emoji, etc.) breaks wrapping math | Low | Visual artifacts in pane | Use byte-length wrapping for first cut; revisit if reported. The existing dashboard renderer doesn't handle CJK widths either; consistency is fine. |

## Resource Requirements

- Single developer, focused. Estimated 1–2 days of implementation + testing.
- No infra changes. No new services. No new ports.

## Future Considerations

Out of scope here, listed for the reader's mental model:

- **Chat send / interrupt**: the input placeholder is reserved for this. When wired, it will need a typing buffer state, an HTTP/IPC pipe to the agent's codex session, and an editing keymap. Not in this PR.
- **macOS portability**: the raw-mode path uses `/proc/self/fd/0` which is Linux-only. macOS operators running `--interactive` will hit the `:ignore` fallback today. Pre-existing limitation; out of scope.
- **Log search / filter inside the pane**: future iteration.
- **Multi-agent split-pane view**: future iteration.
- **Reusing the pane structure for the backoff queue's drill-down**: future iteration.
- **Persistent scroll state across `agents` restarts**: not needed.

## Documentation Plan

- Update `scripts/agents` help text only if we add a new operating mode; no change expected.
- No README update needed (`agents` is internal tooling).
- Once shipped, capture lessons learned in `docs/solutions/2026-MM-DD-cli-log-pane.md` (institutional knowledge baseline — currently `docs/solutions/` doesn't exist).

## Sources & References

### Origin

- **Brainstorm:** [docs/brainstorms/2026-05-10-cli-agent-log-pane-brainstorm.md](../brainstorms/2026-05-10-cli-agent-log-pane-brainstorm.md). Key decisions carried forward:
  - Reuse LiveView chat parser via extraction to a shared module.
  - Pane fills remaining terminal height; backoff queue hidden while open.
  - Sticky-to-bottom scrolling with PgUp/PgDn override.
  - Single-line bordered input placeholder; no input behavior wired.

**Intentional deviations from the brainstorm:**

- **Log source: `agent.md`, not `agent.ndjson`.** Brainstorm §Key Decisions lists ndjson, but the existing parser (`dashboard_live.ex:463-477`) is regex-based on the markdown header format that `AgentRunner.write_agent_log/3` (`agent_runner.ex:247-262`) writes. Reusing the mature parser is the whole point of the shared-module extraction; switching source format for no behavior gain would multiply the work. The end-user-visible content is identical (both files describe the same events).
- **Module name: `SymphonyElixir.AgentLog`, not `SymphonyElixir.AgentLogView`.** Brainstorm proposed the `View` suffix; on inspection, this module owns parsing + reading (model concerns), not just view-layer rendering. The CLI pane and LiveView modal each own their own view-layer rendering. The `AgentLog` name better reflects the module's responsibility.

### Internal References

- LiveView log modal parser: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex:408-665` (helpers to extract).
- LiveView modal handlers: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex:17, 41, 45-52`.
- StatusDashboard render entry: `elixir/lib/symphony_elixir/status_dashboard.ex:365-430` (`format_snapshot_content/4`), `:509-516` (`render_to_terminal/1`), `:214-256` (`maybe_render/1`).
- StatusDashboard selection state: `elixir/lib/symphony_elixir/status_dashboard.ex:132, 135, 188-200` (existing `select_*` cast plumbing — pattern to mirror).
- StatusDashboard width handling: `elixir/lib/symphony_elixir/status_dashboard.ex:826-847` (`terminal_columns_from_env/0`, `COLUMNS` env var — pattern to mirror for `ROWS`).
- TerminalInput reader: `elixir/lib/symphony_elixir/terminal_input.ex` (post-PR #10 shape).
- AgentRunner log writer: `elixir/lib/symphony_elixir/agent_runner.ex:223-262` (writes `agent.md` only when `worker_host` is nil).
- Workspace path origin: `elixir/lib/symphony_elixir/agent_runner.ex:71`, propagated via `elixir/lib/symphony_elixir/orchestrator.ex` (multiple) and `elixir/lib/symphony_elixir_web/presenter.ex:69,104,127,134`.
- Snapshot test harness: `elixir/test/support/snapshot_support.exs:9-22, 49, 51, 65-70` (`assert_dashboard_snapshot!/2`, `UPDATE_SNAPSHOTS=1`).
- Existing fixtures: `elixir/test/fixtures/status_dashboard_snapshots/{backoff_queue,credits_unlimited,idle,idle_with_dashboard_url,super_busy}.{snapshot.txt,evidence.md}`.

### Conventions

- `elixir/AGENTS.md:7` — Elixir 1.19.x / OTP 28 via `mise`.
- `elixir/AGENTS.md:37-46` — `@spec` mandatory on every public `def` in `lib/`; verified by `mix specs.check`.
- `elixir/AGENTS.md:20` — config via `SymphonyElixir.Config` (n.b. `ROWS` env var is direct in the renderer, mirroring how `COLUMNS` is read; if we want it through `Config`, refactor `terminal_columns_from_env/0` too — out of scope here).
- `elixir/AGENTS.md:51, 55` — PR body template + `mix pr_body.check`.

### Related Work

- PR #10 (`Interactive agent selection in CLI dashboard`) — merged 2026-05-10. Established the keyboard-input pipeline and `selected_index` state this plan builds on.
