---
title: CLI pane post-cutover bug fixes
type: fix
status: active
date: 2026-05-17
origin: docs/brainstorms/2026-05-17-cli-pane-bug-fixes-brainstorm.md
branch: feat/cli-pane-rearchitecture
---

# CLI pane post-cutover bug fixes

## Overview

Six fixes / restorations found during manual testing of `./scripts/agents`
on `feat/cli-pane-rearchitecture` after the hard cutover to the two-pane
CLI architecture. Brainstorm at
[docs/brainstorms/2026-05-17-cli-pane-bug-fixes-brainstorm.md](../brainstorms/2026-05-17-cli-pane-bug-fixes-brainstorm.md)
captured the decisions; this plan sequences them with explicit unit
breakdowns, test seams, and manual-test gates.

Workflow gates per the user's standing instructions:
- One very small unit per cycle → implement → test → build → lint:fix
  → commit (3-7 word message) → push.
- One bash invocation per command (no `&&` chains).
- Not "done" until both unit tests pass AND the user manually exercises
  the CLI end-to-end against the scenarios called out per unit.
- Style north star: `github.com/ethereum-optimism/actions` CONTRIBUTING.md.

## Problem statement

The new pane CLI demo (committed 2026-05-16) works end-to-end on the
happy path: agent list renders, Enter spawns a conversation pane, typing
flows through the local optimistic echo. But manual testing surfaced
six gaps:

1. **Missing "SYMPHONY STATUS" header.** Agent-list pane lost the
   bordered title + project/refresh/dashboard metadata rows that lived
   on `main` in `status_dashboard.ex`.
2. **Missing agent metadata columns.** Agent rows render as
   `▶ <id> [status]` — no columned table.
3. **Composer chrome overflows.** The single-row dashed separator wraps
   to ~2 visible rows of dashes when the pane is narrower than the
   computed `inner_width`.
4. **Transcript never renders.** Agent codex messages broadcast on
   PubSub but never reach the pane.
5. **No Symphony-owned pane controls.** Users must already know tmux
   defaults to switch / close panes.
6. **Layout doesn't auto-split-right or auto-focus.** New panes appear
   wherever tmux's default `split-window` puts them.

## Proposed solution

Nine sequenced phases. Phase 1 (transcript) gates the rest because
phase 2 (re-evaluate flashing) only has signal when there's actual
transcript content drawing. Phases 3-5 cluster the tmux work
(conf file → wrapper integration → layout). Phases 6-8 are independent
renderer restorations / fixes. Phase 9 is the final E2E + handoff doc
refresh.

Key decisions carried from the brainstorm (see brainstorm: docs/brainstorms/2026-05-17-cli-pane-bug-fixes-brainstorm.md):

- **Tmux isolation** via `tmux -L symphony-$USER -f <conf>` on its own
  socket — never touches the user's normal tmux server.
- **Conf precedence (two tiers, post-deepen)**: `~/.config/symphony/tmux.conf`
  → `<repo>/scripts/symphony.tmux.conf`. The `$SYMPHONY_TMUX_CONF` env
  override was dropped during plan deepening (YAGNI — no V1 consumer).
- **Error out if `$TMUX` is set** — wrapper prints "Open a fresh terminal
  without tmux and try again." and exits 1.
- **Transcript fix**: subscribe locally on the pane BEAM via
  `AgentPubSub.subscribe_agent/1` — drop the broken `:rpc.call` path.
  Confirmed via deepen: Phoenix.PubSub 2.2.0 PG2 adapter on
  `:pg` does cross-node fan-out via a per-node `PG2Worker` GenServer
  registered as the `:name`, then dispatches via the local Registry.
  See `phoenix_pubsub/lib/phoenix/pubsub/pg2.ex` v2.2.0.
- **Known startup race** (deepen finding): `Node.connect/1 == true`
  does not guarantee `:pg` has synced. Broadcasts during the
  ~10–100ms sync window can silently drop. Acceptable for V1 because
  the brainstorm already flagged transcript-history backfill as a
  separate open question; the pane misses events only during pane
  cold-start, not during steady state.
- **Drop the optimistic echo** in `handle_submit`; rely on the
  symmetric `AgentChat.send` PubSub broadcast for user messages.
- **Ctrl+C closes the pane unconditionally**; agent-interrupt is a
  future, separate key (out of scope here). Confirmed via deepen:
  `bind-key -n C-c` is captured by tmux's root-table **before** the
  PTY forwards the key, so SIGINT never reaches the pane process.
  Exactly what we want.
- **Hard kill on shutdown is fine**: OTP's normal `Application.stop`
  handles flushes when tmux SIGHUPs the BEAM.

## Technical approach

### Architecture impact

Three files change behavior in their domain:

- `elixir/lib/symphony_pane/conversation.ex` — subscribe path swap + drop
  optimistic echo.
- `elixir/lib/symphony_elixir/agent_list/renderer.ex` — port header,
  metadata rows, and table from `main:status_dashboard.ex`.
- `elixir/lib/symphony_pane/viewport.ex` — replace dashed separator
  with tinted-bg 3-row composer block.

Two files change tmux orchestration:

- `scripts/agents` — `$TMUX` detection, conf-path resolution, isolated
  socket launch.
- `elixir/lib/symphony_elixir/tmux.ex` and
  `elixir/lib/symphony_elixir/pane_manager.ex` — split-right target and
  explicit `select-pane` follow-up.

One new file:

- `scripts/symphony.tmux.conf` — the tracked default tmux configuration
  (Tab / Shift+Tab / Ctrl+C bindings + `after-split-window` hook).

Now-dead surfaces:

- `SymphonyElixir.PaneRPC.attach_conversation/1` and
  `SymphonyElixir.Conversations.attach/1` become unused after the
  local-subscribe fix. Keep them (audit chokepoint per the security
  review) but document them as call-sites-pending in the moduledoc.

### Implementation phases

#### Phase 1: Make the transcript actually render (gates everything)

##### U1.1 — Subscribe locally on the pane BEAM

**File**: `elixir/lib/symphony_pane/conversation.ex`

Already staged but uncommitted: alias `AgentPubSub`, replace
`subscribe_remote/2` with a local
`AgentPubSub.subscribe_agent(identifier)` call from `init/2`, delete the
now-dead helper. The pane BEAM already runs `Phoenix.PubSub` under
`SymphonyElixir.PubSub` (started in `SymphonyPane.CLI.main/1` —
see `cli.ex:43-47`), so PG2's cluster-global `:pg` groups will deliver
remote broadcasts.

**Unit test** (`elixir/test/symphony_pane/conversation_test.exs`):

```elixir
test "renders agent broadcast received via local AgentPubSub" do
  identifier = "test-agent-#{System.unique_integer([:positive])}"
  parent = self()

  {:ok, pid} = Conversation.start_link(identifier,
    name: nil, skip_raw_mode: true,
    symphony_node: nil,
    write_fun: fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end)

  # Drain initial render
  assert_receive {:rendered, _}, 200

  AgentPubSub.broadcast_transcript(identifier,
    AgentEvents.transcript_event(:assistant, "hello from agent"))

  assert_receive {:rendered, frame}, 200
  assert frame =~ "agent: hello from agent"
end
```

**Manual test scenarios** (deepened — fallback rewritten to be
self-contained):

- *Steady-state path*: `./scripts/agents` → open conversation for any
  running agent → wait for that agent to emit a codex message →
  assert `agent: …` appears in the transcript region within 2 seconds.
- *Forced path if no agent is active*. Step-by-step:
  1. Start `./scripts/agents` in terminal A. Open a conversation for an
     agent.
  2. In terminal B, find the symphony BEAM's sname:
     `ps aux | grep '[b]eam.*symphony' | head -1` — the `-sname` arg
     after `--name` is the node name (e.g. `symphony-applekid`).
  3. Locate the cookie: it's in `~/.erlang.cookie` (set by the
     wrapper's `ensure_erlang_cookie` step; readable by current user
     only).
  4. Attach a probe:
     `iex --sname probe-$$ --cookie "$(cat ~/.erlang.cookie)" --remsh "symphony-$USER"`.
  5. Inside the iex prompt, broadcast:
     `SymphonyElixir.AgentPubSub.broadcast_transcript("<the-agent-id-you-opened>", SymphonyElixir.AgentEvents.transcript_event(:assistant, "manual probe"))`
  6. Switch back to terminal A → the conversation pane shows
     `agent: manual probe` within 200ms.

**Acceptance**:
- [ ] Unit test passes with `mix test test/symphony_pane/conversation_test.exs`.
- [ ] Existing tests in same file still pass.
- [ ] Steady-state OR forced manual scenario is verified visually
  (whichever is reachable in the moment).

**Commit**: `Fix pane transcript subscribe` (4 words)

##### U1.2 — Synchronous send with error feedback (was: drop optimistic echo)

**File**: `elixir/lib/symphony_pane/conversation.ex`

`handle_submit/1` currently appends a local `:user` transcript event
before the cast returns. With the subscribe fix, `AgentChat.send`'s
broadcast will arrive over PG2 → duplicate render. The naïve "drop
echo + rely on broadcast" approach (proposed in the original plan)
ships a **silent-error regression** flagged by the architecture
reviewer: if `AgentChat.send/3` returns `{:error, :body_too_long}` or
any orchestrator failure, **no broadcast fires** (`agent_chat.ex:21-32`
broadcasts only on `{:ok, _}`). User types → composer clears → text
vanishes with no echo, no error.

**Revised plan (deepened)**: swap `:rpc.cast` to `:rpc.call` with a
short timeout so the pane sees the success/error result. Drop the
optimistic echo for the success case (relying on broadcast for "you:
…"). Append a `:system` transcript event for the error case so the
user sees what went wrong.

```elixir
defp send_message(node, identifier, text) when is_atom(node) do
  case :rpc.call(node, SymphonyElixir.PaneRPC, :send_operator_message,
                 [identifier, text], 2_000) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
    {:badrpc, reason} -> {:error, {:rpc, reason}}
  end
end

defp handle_submit(state) do
  {new_composer, text} = Composer.submit(state.composer)

  if text != "" do
    case send_message(state.symphony_node, state.identifier, text) do
      :ok ->
        # Success: broadcast will arrive; no local append needed.
        new_state = %{state | composer: new_composer}
        render(new_state)
        {:noreply, new_state}

      {:error, reason} ->
        # Error: append a system message so the user sees why.
        system = AgentEvents.transcript_event(:system, "send failed: #{inspect(reason)}")
        new_state = %{state | composer: new_composer,
                              transcript: state.transcript ++ [system]}
        render(new_state)
        {:noreply, new_state}
    end
  else
    new_state = %{state | composer: new_composer}
    render(new_state)
    {:noreply, new_state}
  end
end
```

**Unit test** updates (two tests now, replacing the old "echoes
submitted message locally"):

```elixir
test "success path: composer clears, broadcast renders user echo" do
  # Stub PaneRPC.send_operator_message via a mock symphony node OR
  # a write_fun + same-node call. Concretely:
  send(pid, {:input, "p"}); send(pid, {:input, "i"}); send(pid, {:input, "\r"})

  # Optimistic echo is gone — composer cleared, no local append.
  state = :sys.get_state(pid)
  assert state.transcript == []
  assert state.composer.buffer == ""

  # PG2-delivered broadcast arrives (simulated):
  AgentPubSub.broadcast_transcript(identifier,
    AgentEvents.transcript_event(:user, "pi"))
  assert_receive {:rendered, frame}, 200
  assert frame =~ "you: pi"
end

test "error path: renders a system message when send fails" do
  # Boot Conversation with symphony_node: a node that returns
  # {:error, :body_too_long} from PaneRPC.send_operator_message.
  # Easiest: a mock RPC handler via a small intercepting agent.
  send(pid, {:input, "x"}); send(pid, {:input, "\r"})

  assert_receive {:rendered, frame}, 500
  assert frame =~ "send failed:"
end
```

**Manual test scenarios** (deepened — now covers the error path):

- *Success path*: `./scripts/agents` → open conversation → type `ping`
  + Enter → verify `you: ping` appears within 50ms (PG2 local
  round-trip).
- *Long message*: type a 300-char message + Enter → verify no
  double-render and no perceptible lag.
- *Error path (forced)*: paste a >65 KiB body (e.g.
  `python3 -c 'print("x" * 70000)'` piped into the pane via tmux
  `send-keys`) + Enter → verify a system row appears: `send failed:
  :body_too_long`. Composer is cleared.
- *RPC failure*: `kill -9 <symphony beam pid>` → in the pane, type a
  message + Enter → verify `send failed: {:rpc, ...}` system row.

**Acceptance**:
- [ ] Both unit tests pass.
- [ ] All four manual scenarios pass.
- [ ] No silent failure: every Enter either renders a `you: …` row
  (within 50ms) or a `send failed: …` system row (within 2s).

**Commit**: `Surface send errors in pane` (5 words)

#### Phase 2: Re-evaluate the "flashing" report

##### U2.1 — Manual eval, document outcome

No code. With transcripts now rendering, run a **recorded** flash
probe so the decision is reproducible.

**Probe protocol** (deepened — was previously subjective):

1. `./scripts/agents` → open one conversation pane.
2. Start a recording: `asciinema rec /tmp/symphony-flash.cast` in a
   second terminal that's attached to the same tmux session via
   `tmux -L symphony-$USER attach`. (Or use any terminal recorder that
   captures ANSI accurately, e.g. `script -t`.)
3. In a third terminal, drive a burst via the U1.1 probe protocol:
   broadcast 20 transcript events in 2 seconds:
   ```elixir
   for i <- 1..20 do
     SymphonyElixir.AgentPubSub.broadcast_transcript(
       "<agent-id>",
       SymphonyElixir.AgentEvents.transcript_event(:assistant, "burst #{i}"))
     :timer.sleep(100)
   end
   ```
4. Simultaneously, type 20 characters in the conversation pane at
   normal speed.
5. Stop the recording, replay with `asciinema play /tmp/symphony-flash.cast`.

**Classification rule**: a single frame where the agent-list or
conversation pane goes fully blank (entire body region empty for one
or more rendered frames) → "flashing." Anything subtler (cursor blink,
partial line replacement) → not flashing.

**Three outcomes**:

- **No flash classified** → close TaskList #16 as resolved, note in
  the handoff doc that the original "flash" report was the
  empty-transcript redraw artifact.
- **Flash classified on typing only** → land a follow-up that swaps
  `\e[2J\e[H` for `\e[H` + per-line `\e[K` (cheapest possible patch).
- **Flash classified on every PubSub event** → land alt-screen buffer
  (`\e[?1049h` on init, `\e[?1049l` on terminate, `\e[?25l`/`\e[?25h`
  cursor hide-during-switch) with the additional caveat that
  scrollback is hidden when the pane exits.

Document the outcome and the path to the .cast file in
`docs/handoffs/2026-05-17-cli-pane-bug-fixes-handoff.md` (created
fresh at end of this branch).

**Acceptance**:
- [ ] Asciinema (or equivalent) capture exists at a documented path.
- [ ] Classification recorded (one of the three outcomes).
- [ ] Handoff doc updated with classification and (if needed) follow-up
  scope.

**No commit** unless a follow-up patch is needed.

#### Phase 3: Ship the default tmux conf file

##### U3.1 — Create `scripts/symphony.tmux.conf`

**New file** (deepened — uses `if-shell -F` synchronous form, adds
color + history-limit + lifecycle defaults per the tmux research pass):

```tmux
# Symphony's isolated tmux configuration.
# Loaded by `scripts/agents` via `-L symphony-$USER -f <path>`.
# To customize, copy this file to ~/.config/symphony/tmux.conf and edit
# there — that path takes precedence and survives `git pull`.
# Note: changes to bindings here will appear in PR diffs; user
# overrides at ~/.config/symphony/ do not.

set -g prefix None
unbind-key -aT prefix
set -sg escape-time 0
set -g mouse on
set -g status off
set -g history-limit 50000
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"
set -g remain-on-exit off
set -g destroy-unattached off

# Pane navigation
bind-key -n Tab    select-pane -t :.+
bind-key -n BTab   select-pane -t :.-

# Close: pane 0 = whole session, others = just that pane.
# `-F` makes the test synchronous against the tmux format engine
# (safer than shell-mode if-shell, which has been buggy since 2.4 —
# tmux/tmux#882).
bind-key -n C-c if-shell -F '#{==:#{pane_index},0}' \
                 'kill-session' 'kill-pane'

# Rebalance widths on every horizontal split
set-hook -g after-split-window 'select-layout even-horizontal'
```

**Test**: parse-check via `tmux -L verify-symphony-conf -f scripts/symphony.tmux.conf source-file -` (the dash arg makes tmux exit after parsing; non-zero exit = syntax error). This can run in `elixir/test/scripts_agents_test.exs` style as a separate test or as a Makefile target.

**Manual test**:
- `tmux -L probe-$$ -f scripts/symphony.tmux.conf new-session -d 'sleep 60'` →
  attach in a separate terminal → press Tab (no panes to switch yet,
  but no crash) → split manually `:` `split-window -h` → press Tab to
  cycle → press Ctrl+C in pane 1 (should kill pane, not session) →
  press Ctrl+C in pane 0 (should kill session).

**Acceptance**:
- [ ] Conf file parses with tmux.
- [ ] Manual binding test confirms Tab / Shift+Tab / Ctrl+C behavior.

**Commit**: `Ship default symphony tmux conf` (5 words)

#### Phase 4: Wrapper-level isolation + conf discovery

##### U4.1 — `$TMUX` detection in `scripts/agents`

**File**: `scripts/agents`

Add an early guard near the top of `run_in_tmux` (or as a new
`check_not_in_tmux` helper):

```bash
check_not_in_tmux() {
  if [ -n "${TMUX:-}" ]; then
    echo "agents: already inside a tmux session" >&2
    echo "Open a fresh terminal without tmux and try again." >&2
    exit 1
  fi
}
```

**Unit test** (`elixir/test/scripts_agents_test.exs` extension):

```elixir
test "refuses to run inside an existing tmux session" do
  env = base_env() |> Map.put("TMUX", "/tmp/tmux-1000/default,12345,0")
  {output, status} = System.cmd("./scripts/agents", [], env: env, stderr_to_stdout: true)
  assert status == 1
  assert output =~ "already inside a tmux session"
end
```

**Manual test**:
- Open a normal tmux session (`tmux new-session`), inside it run
  `./scripts/agents` → expect error message + exit 1.
- Open a fresh terminal (no tmux), run `./scripts/agents` → no error
  from the guard.

**Acceptance**:
- [ ] Unit test passes.
- [ ] Both manual scenarios above pass.

**Commit**: `Guard agents against nested tmux` (5 words)

##### U4.2 — Conf path resolution in `scripts/agents`

**File**: `scripts/agents`

Add a `resolve_tmux_conf` helper that picks the conf path in priority
order (two tiers — the env-var third tier was dropped during deepen as
YAGNI): `${XDG_CONFIG_HOME:-$HOME/.config}/symphony/tmux.conf` →
`<script_dir>/symphony.tmux.conf`. The repo default always exists
(checked into git), so resolution can never fail — no error path
needed.

**Unit test** (`elixir/test/scripts_agents_test.exs`):

```elixir
test "uses user override at ~/.config/symphony/tmux.conf when present" do
  home = System.tmp_dir!() |> Path.join("override-home-#{System.unique_integer([:positive])}")
  File.mkdir_p!(Path.join(home, ".config/symphony"))
  conf = Path.join(home, ".config/symphony/tmux.conf")
  File.write!(conf, "# user override\n")

  env = base_env() |> Map.put("HOME", home)
  {output, 0} = System.cmd("./scripts/agents", [], env: env, stderr_to_stdout: true)
  assert output =~ "TMUX:-L symphony-#{System.fetch_env!("USER")} -f #{conf}"
end

test "falls back to repo default when no override is present" do
  home = System.tmp_dir!() |> Path.join("no-override-#{System.unique_integer([:positive])}")
  File.mkdir_p!(home)
  env = base_env() |> Map.put("HOME", home)
  {output, 0} = System.cmd("./scripts/agents", [], env: env, stderr_to_stdout: true)
  assert output =~ ~r{TMUX:-L symphony-.* -f .*scripts/symphony\.tmux\.conf}
end
```

(`base_env/0` is the stubbed env from existing tests; `AGENTS_TMUX_BIN`
stubs tmux to echo `TMUX:<args>` per `scripts_agents_test.exs:50`.)

**Manual test scenarios** (deepened — was previously ambiguous):
- *Scenario A — repo default.* `rm -f ~/.config/symphony/tmux.conf` →
  `./scripts/agents` → after attach, `tmux -L symphony-$USER show-options -g
  prefix` returns `prefix None` (only set by our conf) → confirms repo
  default loaded.
- *Scenario B — user override wins.* `mkdir -p ~/.config/symphony` →
  copy repo conf there and change `Tab` binding to `display-message "tab override"` →
  `./scripts/agents` → press Tab → see "tab override" message →
  confirms override loaded.
- *Cleanup after testing*: `rm -rf ~/.config/symphony` and verify
  Scenario A still passes.

**Acceptance**:
- [ ] Both unit tests pass.
- [ ] All three manual scenarios verified.

**Commit**: `Resolve symphony tmux conf path` (5 words)

##### U4.3 — Wire `-L symphony-$USER -f <conf>` into the tmux launch

**File**: `scripts/agents` — modify `run_in_tmux` so the `new-session`
and `attach` commands run on the symphony socket with the resolved
conf:

```bash
local socket="symphony-${USER}"
local conf
conf="$(resolve_tmux_conf)"
"$tmux_bin" -L "$socket" -f "$conf" new-session -d -s "$session" ...
exec "$tmux_bin" -L "$socket" -f "$conf" attach -t "$session"
```

**Unit test**: extend the resolution tests above to assert the
`new-session` and `attach` invocations both carry the same `-L` and
`-f` arguments.

**Manual test (FULL pane control verification)**:
- Fresh terminal → `./scripts/agents` → confirm agent-list pane.
- Press Enter on an agent → conversation pane opens (preserves split
  behavior from U6).
- Press Tab → focus moves to conversation pane.
- Press Shift+Tab → focus moves back to agent list.
- Press Ctrl+C in conversation pane → pane closes, focus returns to
  agent list.
- Press Ctrl+C in agent list → entire symphony session exits.
- Outside the session, `tmux ls` (no `-L`) shows the user's normal
  sessions untouched.

**Acceptance**:
- [ ] Unit tests pass.
- [ ] All six manual scenarios above pass.
- [ ] User's existing tmux server is untouched (verified by
  `tmux -L default ls` before and after).

**Commit**: `Launch tmux on symphony socket` (5 words)

#### Phase 5: Split-right layout + auto-focus

##### U5.1 — Target `:.{right}` and `select-pane` after split

**Files**:
- `elixir/lib/symphony_elixir/tmux.ex`
- `elixir/lib/symphony_elixir/pane_manager.ex` (if the change crosses
  module boundaries)

In `Tmux.handle_call({:spawn_pane, ...})`:

```elixir
target = "#{state.session}:.{right}"
args = ["split-window", "-t", target, "-h", "-P", "-F", "\#{pane_id}", command_to_run]

case run_args(state, args) do
  {:ok, [pane_id | _]} ->
    new_id = String.trim(pane_id)
    _ = run_args(state, ["select-pane", "-t", new_id])
    {:reply, {:ok, new_id}, state}
  # ...
end
```

The existing `select-pane -t :.0` preamble is replaced by the
`{right}` target on the split itself. The `after-split-window` hook
in the conf handles the rebalance automatically — no extra Elixir
call needed.

**Unit test** (`elixir/test/symphony_elixir/tmux_test.exs`):

```elixir
test "spawn_pane_for splits right and focuses new pane" do
  start_supervised!({Tmux, name: :tmux_split, transport: {:mock, self()}, session: "sym"})

  Task.async(fn ->
    Tmux.spawn_pane_for(:tmux_split, "agent-7", "echo hi")
  end)

  assert_receive {:tmux_mock_out, "split-window -t sym:.{right} -h -P -F \#{pane_id} echo hi"}
  send(GenServer.whereis(:tmux_split), {:tmux_mock_data, "%begin 1 2 3\n%42\n%end 1 2 3\n"})

  assert_receive {:tmux_mock_out, "select-pane -t %42"}
  send(GenServer.whereis(:tmux_split), {:tmux_mock_data, "%begin 1 2 3\n%end 1 2 3\n"})
end
```

**Manual test** (deepened — must run with **at least 3 agents** to
exercise the layout-hook interaction; the 1- and 2-agent cases hide
the most likely race):

- `./scripts/agents` → open agent 1 → conversation pane appears on the
  right of the agent list, equal width. Verify `tmux -L symphony-$USER
  list-panes -F '#{pane_index} #{pane_width}'` reports two panes of
  comparable width (within 1 column).
- Open agent 2 → second conversation pane appears to the right of the
  first, three widths balanced (all within 1 column).
- **Open agent 3 (this is the gate)** → third conversation pane appears
  to the right; focus is on the new pane (verify with
  `tmux -L symphony-$USER display-message -p '#{pane_index}'` ≥ 3).
  Confirm `select-layout even-horizontal` re-tiled all four panes
  evenly. The 3-pane case is the first that exercises the hook's
  re-numbering vs `select-pane -t %<id>` race.
- Reload (Ctrl+C in pane 0) → fresh `./scripts/agents` → repeat
  3-agent flow → confirm reproducibility.

**Acceptance**:
- [ ] Unit test passes.
- [ ] Existing `pane_manager_test.exs` tests still pass (may need
  `drain_select_pane/1` helper updates).
- [ ] All four manual scenarios above pass, **including the 3-agent
  case** (skipping this is the most likely "declared done early"
  failure mode for this plan).

**Commit**: `Split panes right, focus new` (5 words)

#### Phase 6: Restore "SYMPHONY STATUS" header

##### U6.1 — Port `format_title_row` + outer border to `Renderer`

**File**: `elixir/lib/symphony_elixir/agent_list/renderer.ex`

Port from `main:status_dashboard.ex:1181-1184` and `:2018`:

```elixir
@ansi_bold IO.ANSI.bright()
@ansi_reset IO.ANSI.reset()

defp format_title_row, do: colorize("╭─ SYMPHONY STATUS", @ansi_bold)
defp closing_border, do: "╰─"
defp colorize(string, attr), do: attr <> string <> @ansi_reset
```

`render/1` now emits: `format_title_row()` → `\r\n` → existing
title/divider → rows → footer → `closing_border()` → `\r\n`.

**Unit test** (`elixir/test/symphony_elixir/agent_list/renderer_test.exs`):

```elixir
test "renders bordered SYMPHONY STATUS header" do
  out = Renderer.render(empty_state(columns: 80, rows: 24)) |> IO.iodata_to_binary()
  plain = strip_ansi(out)
  assert plain =~ "╭─ SYMPHONY STATUS"
  assert plain =~ "╰─"
end
```

**Manual test**: `./scripts/agents` → agent-list pane has top-left
`╭─ SYMPHONY STATUS` (bold) and a bottom `╰─` border.

**Acceptance**:
- [ ] Unit test passes.
- [ ] Manual visual check confirms the bordered title.

**Commit**: `Restore SYMPHONY STATUS title row` (5 words)

##### U6.2 — Port project / refresh / dashboard URL metadata rows

**File**: `elixir/lib/symphony_elixir/agent_list/renderer.ex` and
`agent_list/app.ex`

Port `right_project_lines/0`, `right_refresh_line/1`, and the dashboard
URL helpers from `status_dashboard.ex:1219-1265`. Make them **pure**:
they take pre-resolved values from the state map, not from `Tracker`
or `Config`. `App` reads `Config.tracker_kind`, `Tracker.project_identity`,
`HttpServer.bound_port`, and any in-flight poll countdown, and passes
them into the renderer.

Renderer state keys added: `:project_label`, `:dashboard_url`,
`:refresh_label` (`"checking now…"` / `"15s"` / `"n/a"`).

**Unit test**:

```elixir
test "renders project, dashboard URL, and refresh countdown" do
  state = empty_state(
    project_label: "applekid/symphony",
    dashboard_url: "http://127.0.0.1:4040/",
    refresh_label: "15s"
  )
  out = state |> Renderer.render() |> IO.iodata_to_binary() |> strip_ansi()
  assert out =~ "Project: applekid/symphony"
  assert out =~ "Dashboard: http://127.0.0.1:4040/"
  assert out =~ "Next refresh: 15s"
end
```

**Manual test**: launch, verify the three rows appear under the header
with current values.

**Acceptance**:
- [ ] Unit test passes.
- [ ] Manual launch shows live project + URL + countdown.

**Commit**: `Show project refresh dashboard row` (5 words)

#### Phase 7: Restore agent-list metadata table

##### U7.1 — Port table header (ID / TAG / STATE / ISSUE / AGE)

**File**: `elixir/lib/symphony_elixir/agent_list/renderer.ex`

Port from `status_dashboard.ex:1592-1615`:

```elixir
@running_id_width 6
@running_tag_width 8
@running_state_width 10
@running_issue_width 22
@running_age_width 12

defp running_table_header_row do
  header = [
    format_cell("ID", @running_id_width),
    format_cell("TAG", @running_tag_width),
    format_cell("STATE", @running_state_width),
    format_cell("ISSUE", @running_issue_width),
    format_cell("AGE / TURN", @running_age_width)
  ] |> Enum.join(" ")
  "│   " <> colorize(header, @ansi_gray)
end

defp format_cell(value, width) do
  value |> to_string()
        |> String.replace("\n", " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> truncate_plain(width)
        |> String.pad_trailing(width)
end

defp truncate_plain(value, width) do
  if byte_size(value) <= width, do: value, else: String.slice(value, 0, width - 3) <> "..."
end
```

**Unit test**:

```elixir
test "renders the running-agent table header" do
  out = Renderer.render(state_with_one_agent()) |> IO.iodata_to_binary() |> strip_ansi()
  assert out =~ ~r/ID\s+TAG\s+STATE\s+ISSUE\s+AGE \/ TURN/
end
```

**Manual test**: launch with at least one agent running, verify column
header appears above the agent rows.

**Acceptance**:
- [ ] Unit test passes.
- [ ] Manual check shows aligned column header.

**Commit**: `Add agent table header row` (5 words)

##### U7.2 — Port per-row column formatting

**File**: `elixir/lib/symphony_elixir/agent_list/renderer.ex`

Replace `render_row/3`'s current `"▶ #{id}  [#{status}]"` with a
columned formatter using `format_cell/2`. Apply state-based colors
(`@ansi_green` for `:running`, `@ansi_red` for `:error`,
`@ansi_yellow` for `:paused`).

Required input fields on each summary (add to `App`'s enrichment if
missing): `:identifier`, `:tag`, `:state`, `:issue_title`, `:age_label`
(pre-formatted like `"42s / 3"`).

**Unit test**:

```elixir
test "renders agent rows with columned formatting" do
  state = state_with_agents([
    %{identifier: "25", tag: "frontend", state: :running, issue_title: "Tab nav bug", age_label: "42s / 3", alert_count: 0},
    %{identifier: "31", tag: "backend",  state: :paused,  issue_title: "Migrate to PG17", age_label: "5m / 1", alert_count: 2}
  ])
  out = state |> Renderer.render() |> IO.iodata_to_binary() |> strip_ansi()
  assert out =~ "25     frontend running"
  assert out =~ "31     backend  paused"
  assert out =~ "(2)"   # alert badge
end
```

**Manual test**: launch with multiple agents in different states →
verify columns align, statuses colorize, and alert badges appear when
present.

**Acceptance**:
- [ ] Unit test passes.
- [ ] Manual check with at least two agents in two states confirms
  alignment + color.

**Commit**: `Format agent rows as columns` (5 words)

#### Phase 8: Composer chrome — tinted background block

##### U8.1 — Replace dashed separator with 3-row tinted block

**File**: `elixir/lib/symphony_pane/viewport.ex`

Port `@ansi_input_dark_bg "\e[48;5;236m"` from
`status_dashboard.ex:42`. Replace the current

```elixir
pad_line(String.duplicate("─", inner_width), inner_width)
```

with a three-row composer block:

1. `pad_line("", inner_width)` (blank, default bg)
2. *tinted line*: `\e[48;5;236m` + `"> " + buffer` + spaces padding to
   `inner_width` + `\e[0m`. **Reset BEFORE `\r\n`**, never after —
   confirmed by ANSI deepen as the portable pattern that prevents
   color bleed onto the next row on Termius / iTerm2 / mosh.
3. `pad_line("", inner_width)` (blank, default bg)

Recompute `transcript_rows` to account for the new height
(`rows - 3` for the composer block + cursor row).

Single helper (deepened — the `\e[K` + `strip_ansi` math is dropped as
over-engineering; the composer buffer never contains ANSI today, and
plain space-padding is portable):

```elixir
defp tinted_line(content, inner_width, bg, reset) do
  visible_len = String.length(content)
  pad = String.duplicate(" ", max(inner_width - visible_len, 0))
  [bg, content, pad, reset]
end
```

256-color fallback is **not** implemented in this unit — see
"Dependencies & risks". If `tput colors < 256` is encountered, the
escape sequence still parses on every modern terminal and degrades
gracefully (no tint shown). A defensive 8-color fallback (`\e[100m`)
would be added in a follow-up only if a user reports a colorless
band.

**Unit test** (`elixir/test/symphony_pane/viewport_test.exs`):

```elixir
test "renders composer with tinted background and blank padding rows" do
  {frame, _cursor} = Viewport.render(state_with_buffer("hello"))
  raw = IO.iodata_to_binary(frame)

  assert raw =~ "\e[48;5;236m"             # tinted bg
  assert raw =~ "> hello"                  # prompt + buffer
  refute raw =~ String.duplicate("─", 10)  # no dashed separator

  # Critical (deepen finding): SGR reset must come BEFORE \r\n on the
  # tinted line, never after — otherwise Termius bleeds the bg color
  # onto the next row.
  refute raw =~ "\r\n\e[0m"                # no reset after the newline
  assert raw =~ "\e[0m\r\n"                # reset before the newline
end
```

**Manual test**:
- Open conversation → composer area has visible tinted background.
- Type "hi" → cursor visible, characters appear inside the tinted row.
- Backspace → buffer shortens, no visual glitches.
- Type a long message that approaches `inner_width` → tinted row stays
  exactly one line (no wrap).

**Acceptance**:
- [ ] Unit test passes.
- [ ] All four manual scenarios above pass.

**Commit**: `Tint composer background rows` (4 words)

#### Phase 9: Final end-to-end + handoff

##### U9.1 — Full happy-path manual test

Run through this scenario top to bottom with no other tmux sessions
present:

1. Fresh terminal → `./scripts/agents`.
2. Agent-list pane renders with: bordered SYMPHONY STATUS title,
   project label, dashboard URL, refresh countdown, columned agent
   table.
3. Arrow-down / j moves selection through agents.
4. Enter opens the selected agent's conversation in a new pane to the
   right; focus moves to the new pane.
5. Conversation pane shows the agent header + tinted-bg composer +
   blank padding rows.
6. Type a message → see `you: <text>` appear within ~50ms via PubSub
   broadcast.
7. Wait for the agent's response → see `agent: <text>` appear in the
   transcript.
8. Tab → focus returns to agent list.
9. Shift+Tab → focus back to conversation.
10. Open a second agent → second conversation pane appears to the
    right of the first, all panes rebalance.
11. Ctrl+C in the second conversation pane → only that pane closes;
    focus moves to the remaining pane.
12. Ctrl+C in the agent list pane → entire session exits.
13. Outside the wrapper, `tmux ls` (no `-L`) shows the user's normal
    tmux state untouched.
14. **Termius gate (deepen-promoted from footer to merge gate).** From
    an iPad / iOS Termius client, SSH into the dev box and run the
    same 13-step flow. The Termius lesson from the original
    `status_dashboard.ex` history (column widths tuned for SSH-on-iPad,
    final-column-reserved autowrap protection) was the original merge
    gate; ANSI changes in this plan (tinted bg, bordered title,
    columned table) must survive a Termius pass. Specifically verify:
    no background-color bleed onto the row below the composer; the
    bordered title doesn't break across two lines; columns align.

**Acceptance**:
- [ ] All 14 steps complete without surprise.
- [ ] No flashing observed during typing or PubSub bursts.
- [ ] Termius run completes without visual artifacts.

##### U9.2 — Refresh the handoff doc

**File**: `docs/handoffs/2026-05-17-cli-pane-bug-fixes-handoff.md`
(new). Capture:

- What landed (one line per commit).
- Flash re-evaluation outcome (from U2.1).
- **Known cliff (carry-forward from brainstorm open question #1)**:
  transcript-history backfill on attach is not implemented. Agents
  running for an hour show empty transcript history to a freshly-opened
  pane. PG2 startup race (deepen finding) also drops broadcasts during
  the first ~10-100ms after `Node.connect/1`. Both addressed in a
  future branch — possibly together via a "subscribe + replay last N
  events" handshake.
- Any deferred items (e.g. agent-interrupt key, future learnings doc
  in `docs/solutions/` for tmux isolation + PG2 subscribe patterns).

**Commit**: `Add bug fix handoff doc` (5 words)

##### U9.3 — Prune `ignore_modules` for the now-tested CLI surface

**File**: `elixir/mix.exs`

The deepen reviewer flagged a silent gap: this plan triples the size
of `agent_list/renderer.ex` by porting from `status_dashboard.ex`, but
the renderer (along with `symphony_pane/viewport.ex`,
`symphony_pane/conversation.ex`, `symphony_elixir/tmux.ex`) sits in the
`ignore_modules` list at `elixir/mix.exs:14-65`. Leaving it ignored
bakes in a precedent that "CLI code is forever exempt from the 100%
coverage gate." That's not the intent — the modules were ignored
during stub work and now have real tests landing throughout this plan.

Remove from `ignore_modules` the modules that have full test coverage
after U1-U8 land:
- `SymphonyElixir.AgentList.Renderer`
- `SymphonyElixir.AgentList.App` (if `:sys.get_state/1` coverage of its
  branches is complete; otherwise keep ignored and note in handoff)
- `SymphonyElixir.Tmux`
- `SymphonyElixir.PaneManager`
- `SymphonyPane.Conversation`
- `SymphonyPane.Viewport`
- `SymphonyPane.Composer`

Keep ignored:
- `SymphonyPane.CLI` (main entry, exits via `System.halt`; standard
  exemption for unreachable shutdown paths)
- `SymphonyElixir.AgentList.Input` (raw-mode stdin loop; PTY-coupled,
  tested via `skip_raw_mode` seam only)

**Verification**:

```bash
cd elixir
mix coveralls
```

Should report 100% coverage across all non-ignored modules. If any
module drops below 100%, either restore it to `ignore_modules` with a
one-line justification or add the missing test in this unit.

**Manual test**: none — the coverage report is the gate.

**Acceptance**:
- [ ] `mix coveralls` reports 100% coverage.
- [ ] `ignore_modules` list documents *why* each remaining entry is
  ignored (one comment line per entry).

**Commit**: `Cover CLI modules at threshold` (5 words)

##### U9.4 — Symmetric `Conversations.open/1` + `Conversations.close/1` for agent-native parity

**File**: `elixir/lib/symphony_elixir/conversations.ex` (+ thin
delegation hooks in `pane_manager.ex` if needed)

Agent-native reviewer flagged a real asymmetry: `Conversations.attach/1`
+ `detach/1` exist as the data-plane primitives, but `detach/1` only
unsubscribes — it leaves the tmux pane dangling. An MCP tool or
automation agent that calls `attach` + `detach` looks symmetric but
**leaks panes**. There is no end-to-end "open a conversation for agent
X" / "close it" facade callable from outside the CLI.

Add:

```elixir
@spec open(AgentEvents.agent_identifier(), keyword()) ::
        {:ok, %{identifier: String.t(), pid: pid(), pane_id: String.t()}} | {:error, term()}
def open(identifier, opts \\ []) when is_binary(identifier) do
  command = Keyword.get(opts, :command, default_command(identifier))
  pane_manager = Keyword.get(opts, :pane_manager, PaneManager)

  with {:ok, ref} <- attach(identifier),
       {:ok, pane_id} <- PaneManager.open_conversation(pane_manager, identifier, command) do
    {:ok, Map.put(ref, :pane_id, pane_id)}
  end
end

@spec close(map() | AgentEvents.agent_identifier()) :: :ok
def close(%{identifier: identifier} = ref) do
  _ = PaneManager.close_conversation(PaneManager, identifier)
  detach(ref)
end

def close(identifier) when is_binary(identifier) do
  close(%{identifier: identifier, pid: self()})
end
```

`AgentList.App.handle_cast(:activate, ...)` should call
`Conversations.open/2` instead of `PaneManager.open_conversation/3`
directly, so the CLI flow and any future MCP flow go through the same
chokepoint.

**Unit test** (`elixir/test/symphony_elixir/conversations_test.exs`):

```elixir
test "open/2 subscribes and opens a pane atomically" do
  identifier = "test-#{System.unique_integer([:positive])}"
  {:ok, ref} = Conversations.open(identifier, pane_manager: :mock_pane_mgr)
  assert ref.identifier == identifier
  assert is_binary(ref.pane_id)
end

test "close/1 closes the pane and unsubscribes" do
  # …
  :ok = Conversations.close(ref)
  refute_receive {:transcript_event, _}, 100  # broadcasts no longer reach us
end
```

**Manual test**: from a remote iex shell (per U1.1 forced-path
recipe), call `SymphonyElixir.Conversations.open("<id>")` → tmux pane
opens on the symphony socket (`tmux -L symphony-$USER list-panes`
confirms) AND the iex process receives subsequent `{:transcript_event,
…}` messages. Call `Conversations.close(ref)` → pane is gone from the
list AND further broadcasts do not arrive.

**Acceptance**:
- [ ] Unit tests pass.
- [ ] Manual scenario verifies symmetry (open creates pane +
  subscription, close removes both).
- [ ] `AgentList.App` uses `Conversations.open/2` (not
  `PaneManager.open_conversation/3` directly).

**Commit**: `Add Conversations open close API` (5 words)

## Reviewer-flagged refinements (apply during implementation)

These items came out of the technical-review pass. They're not large
enough to warrant their own units, but implementation should pick them
up where they touch the relevant phase. Listed by the unit they
naturally land in.

### During Phase 5 (U5.1 — Tmux split-right)

- **`Tmux.spawn_pane_for/3` should accept `focus: true` opt** (default
  true). Future warm-pool / background-pane workflows want
  spawn-without-focus. Architecture reviewer flagged: two lines, no
  behavior change in the default path.
- **Comment in `pane_manager.ex` cross-referencing the
  `pane_index == 0 → kill-session` policy** in
  `scripts/symphony.tmux.conf`. If `PaneManager` ever re-orders panes,
  the binding silently misfires. One comment line; protects the
  invariant.

### During Phase 6 / 7 (U6.1, U7.1, U7.2 — Renderer port)

- **Rename module attributes from `@running_*` to `@agent_table_*`** —
  the `running_` prefix is dashboard-era namespace pollution. Pattern
  reviewer caught this. Apply on the way in, not as a follow-up
  rename.
- **Standardize render-helper names on `_iolist`** for multi-line
  builders (matching `viewport.ex:47,64`). The dashboard's
  `_row` (singular) vs `_lines` (multi) split is internally
  inconsistent. Rename: `right_project_lines` → `metadata_iolist`,
  `format_title_row` → stays `title_iolist` (now multi-line aware).
- **Pre-Phase 6 extraction**: lift `pad_line/2`, `colorize/3`, and
  `strip_ansi/1` (currently inlined or test-file local) into a new
  `SymphonyElixir.RenderUtils` module **before** U6.1 starts. Saves
  3 commits of copy-paste across U6.1, U7.1, U8.1. Pattern reviewer
  recommendation. Add as a half-unit "U5.5 — Extract render utils" if
  desired.
- **Convert `AgentList.Renderer.state` to a `defstruct`** once the
  state map crosses 6 fields (it will, with `:project_label`,
  `:dashboard_url`, `:refresh_label` added in U6.2). Keep
  `Viewport.state` as a map (5 stable fields). Don't introduce a
  shared envelope across the two panes — the domains diverge.

### During Phase 8 (U8.1 — Composer chrome)

- **Reuse `visible/1` test helper** (currently defined locally in both
  `viewport_test.exs:17` and `conversation_test.exs:28`). Extract to a
  `SymphonyPane.RenderTestHelpers` module first, then call from U8.1's
  new test. Avoids triple duplication.

### During Phase 9 (U9.3 — Coverage)

- **Drop `AgentList.App` from the promotion list.** The plan's
  hand-wavy "if `:sys.get_state/1` coverage of its branches is
  complete; otherwise keep ignored" was caught by the architecture
  reviewer. Concretely: promote `Renderer`, `Tmux`, `PaneManager`,
  `Conversation`, `Viewport`, `Composer`. Keep ignored: `CLI`,
  `AgentList.Input`, `AgentList.App` — each with a one-line
  justification comment in `mix.exs`.

### Owl dependency

- **`{:owl, "~> 0.13"}` is in `mix.exs:101` but unused everywhere**
  (`grep Owl\.` returns zero hits in `lib/`). Don't introduce Owl
  mid-bugfix. After this branch merges, file a separate ticket: either
  adopt Owl across both renderers or remove the dep. Mixing one
  renderer with Owl and the other with raw escapes is the worst
  outcome.

## Acceptance criteria

### Functional
- [ ] U1.1 — transcript subscribes locally and renders agent broadcasts.
- [ ] U1.2 — optimistic echo removed; user messages render via broadcast.
- [ ] U3.1 — `scripts/symphony.tmux.conf` parses and binds Tab /
  Shift+Tab / Ctrl+C correctly.
- [ ] U4.1 — wrapper refuses to nest inside an existing tmux session.
- [ ] U4.2 — wrapper resolves conf path with the three-tier precedence.
- [ ] U4.3 — wrapper launches tmux on `symphony-$USER` socket with the
  resolved conf.
- [ ] U5.1 — new conversation panes split right and gain focus.
- [ ] U6.1 — agent list shows bordered "SYMPHONY STATUS" header.
- [ ] U6.2 — header shows project / dashboard / refresh countdown.
- [ ] U7.1 — agent table header (ID/TAG/STATE/ISSUE/AGE) renders.
- [ ] U7.2 — agent rows render with aligned columns, colors, and alert
  badges.
- [ ] U8.1 — composer chrome is a tinted-bg block with blank padding
  rows, no dashed separator.

### Quality gates per unit
- [ ] Unit test added or updated; `mix test` green for the modified
  files.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] `mix credo --strict` clean.
- [ ] `mix specs.check` clean.
- [ ] `mix format --check-formatted` clean.

### Coverage gate (U9.3)
- [ ] `mix coveralls` reports 100% across all non-ignored modules.
- [ ] `ignore_modules` shrunk to only `SymphonyPane.CLI` and
  `SymphonyElixir.AgentList.Input` (each with a one-line justification
  comment), with all other CLI modules promoted to gated coverage.

### End-to-end
- [ ] U9.1 — full 13-step manual scenario passes.
- [ ] User's normal tmux server is unaffected (verified via
  `tmux -L default ls`).
- [ ] No regressions in pre-existing `feat/cli-pane-rearchitecture`
  tests (the 413 tests with 4 known pre-existing failures stays at
  exactly that count).

## System-wide impact

### Interaction graph
- `Conversation.init/2` → `AgentPubSub.subscribe_agent/1` →
  `Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, topic)` joins a
  local `Registry` entry; the per-node `PG2Worker` GenServer (also
  registered as `SymphonyElixir.PubSub`) is the cluster-wide member
  of the `:pg` group. Symphony's broadcast goes:
  `Phoenix.PubSub.broadcast/3` → `:pg.get_members(SymphonyElixir.PubSub,
  group)` → iterate pids, `send({:forward_to_local, topic, msg, ...})`
  to each non-local PG2Worker → that worker calls
  `Phoenix.PubSub.local_broadcast/4` → Registry dispatches to local
  subscribers (the pane GenServer). Confirmed in `phoenix_pubsub`
  v2.2.0 `lib/phoenix/pubsub/pg2.ex` lines 17-26 and 40-50.
- `Tmux.spawn_pane_for/2` → `split-window -t :.{right} ...` →
  `after-split-window` hook fires `select-layout even-horizontal` →
  `select-pane -t <new-id>` focuses the new pane.
- `scripts/agents` → `resolve_tmux_conf` → `tmux -L socket -f conf …` →
  user's normal tmux server (default socket) is never touched.

### Error & failure propagation
- If `AgentPubSub.subscribe_agent/1` fails (no PubSub registry), the
  pane logs at `:warning` and renders without transcript — fail-open
  (current behavior; brainstorm preserved this).
- **PG2 startup race** (deepen finding): `Node.connect/1 == true` does
  not mean `:pg` membership has fully synced across nodes. Broadcasts
  from symphony during the ~10–100ms sync window after pane connect
  silently drop on the pane side (the pane's PG2Worker isn't yet in
  the `:pg` group from symphony's perspective). Mitigation if it
  becomes a visible problem:
  `Phoenix.PubSub.direct_broadcast(SymphonyElixir.PubSub, pane_node,
  topic, msg)` addresses the worker by node name and skips the
  `pg_members` lookup. Out of scope here because the existing
  transcript-history backfill cliff (brainstorm open question #1)
  already constrains this regime — the same future fix can address
  both.
- If the tmux conf file is missing at every path, `resolve_tmux_conf`
  exits 1 with a clear message; the wrapper does not try to fall back
  to the user's `~/.tmux.conf` (that would defeat isolation).
- If `Node.connect/1` to the symphony node fails, the pane continues to
  function as a local typing surface — typed messages go nowhere
  (`send_message/3` with `nil` node logs and drops), but at least the
  pane doesn't crash. Acceptable for Phase 1.

### State lifecycle risks
- Dropping the optimistic echo means a user message exists only in the
  symphony BEAM's broadcast pipeline until the round-trip lands. If the
  user closes the pane between Enter and the broadcast arriving
  (~5ms), the message is lost from the local view but still delivered
  to the agent. Acceptable: the message lands; the operator just
  doesn't see their own echo. Re-opening the pane backfills nothing
  (separate open question in brainstorm).
- Closing pane 0 with Ctrl+C kills the symphony tmux session via the
  conf's `kill-session` branch. The symphony BEAM gets SIGHUP; OTP
  `Application.stop` flushes `Tracker` and `WorkflowStore`. If the
  BEAM is mid-write, the OS may interrupt. Hard kill accepted per
  brainstorm key decision #7 — revisit if we see lost-write incidents.

### API surface parity
- `PaneRPC.attach_conversation/1` and `Conversations.attach/1` are now
  unused. Keep them (security review chokepoint) and update their
  moduledocs to note that the pane subscribes locally for now; these
  APIs are reserved for future external consumers (MCP bridge, etc.).
- No web/HTTP surface changes.

### Integration test scenarios
The five cross-layer scenarios that unit tests miss are captured as
the manual checks in U1.1, U4.3, U5.1, U8.1, and U9.1 above. Treat
those as the integration suite for this branch.

## Dependencies & risks

- **PG2 cross-node fan-out latency.** If a future change moves the
  symphony BEAM to a remote host (e.g. distributed Symphony), the
  ~50ms manual budget for user echo no longer holds and we'll need to
  reintroduce the optimistic echo with msg_id dedup. Out of scope here.
- **PG2 startup race (deepen).** Covered in "Error & failure
  propagation" above. Mitigation deferred to follow-up branch.
- **256-color downsampling (deepen).** `\e[48;5;236m` is the 256-color
  background sequence. Termius iOS, mosh ≥ 1.4, and every modern
  Terminal.app / WT report 256-color support. On a terminal that
  doesn't, the sequence is consumed silently and the tint just isn't
  visible — graceful degradation. No defensive fallback is added in
  this plan; revisit if a user reports a missing tint.
- **Termius / iPad SSH (deepen — now a U9.1 merge gate).** Brainstorm
  flagged this as the original merge gate. Phase 9 U9.1 step 14
  enforces it.
- **No `docs/solutions/`** — the learnings researcher flagged this. Add
  a single-paragraph solutions doc after merge for tmux isolation,
  the PG2 subscribe bug, and the SGR-reset-before-newline pattern, so
  the next session has institutional context.

## Success metrics

- `mix test` exits 0 with no new failures relative to pre-branch
  baseline.
- `mix credo --strict`, `mix specs.check`, `mix dialyzer` all green.
- Manual scenario U9.1 passes start-to-finish without surprise.
- `git log main..HEAD --oneline` has 12 small commits matching this
  plan (one per unit).

## Sources & references

### Origin
- **Brainstorm:** [docs/brainstorms/2026-05-17-cli-pane-bug-fixes-brainstorm.md](../brainstorms/2026-05-17-cli-pane-bug-fixes-brainstorm.md).
  Key decisions carried forward: isolated tmux socket, conf
  precedence, local PubSub subscribe, drop optimistic echo,
  unconditional Ctrl+C close, hard-kill shutdown.

### Internal references
- Pure-renderer test pattern: `elixir/test/symphony_elixir/agent_list/renderer_test.exs:6`.
- Conversation test seams: `elixir/test/symphony_pane/conversation_test.exs:11-19`.
- Mock tmux transport: `elixir/test/symphony_elixir/tmux_test.exs:6-15` and
  helpers in `elixir/test/symphony_elixir/pane_manager_test.exs:28-47`.
- Wrapper test pattern: `elixir/test/scripts_agents_test.exs:50` (`MISE:exec ...` assertion).
- Reference helpers to port: `git show main:elixir/lib/symphony_elixir/status_dashboard.ex` at
  lines 1181-1184, 1192-1235, 1592-1615, 1667-1676, and module attrs 18-22, 30-48.
- Coverage threshold + ignore list: `elixir/mix.exs:11-65`.

### Style north star
- `github.com/ethereum-optimism/actions` CONTRIBUTING.md (referenced in
  the user's standing workflow notes).

### Related work
- Prior branch handoff: [docs/handoffs/2026-05-16-cli-pane-rearchitecture-handoff.md](../handoffs/2026-05-16-cli-pane-rearchitecture-handoff.md).
- Original brainstorm for the pane rearchitecture: [docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md](../brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md).

## Out of scope (deferred follow-ups)

- Transcript history backfill on attach (brainstorm open question #1).
- PG2 startup-race mitigation (`direct_broadcast/5` or subscribe-ack
  handshake) — same future branch as backfill.
- Agent-interrupt key separate from Ctrl+C (brainstorm Ctrl+C decision).
- Alternate-screen-buffer rendering — only land if Phase 2's manual
  re-evaluation shows actual flashing.
- 256-color → 8-color downsampling fallback for the composer tint
  (deepen). Add only if a user reports the missing tint.
- Mosh / web-SSH client compatibility beyond Termius — deferred to a
  future "transport" doc, mirroring the brainstorm's out-of-scope list.
- `docs/solutions/` learnings doc — single-paragraph follow-up after
  merge covering tmux isolation, PG2 subscribe-from-rpc-worker bug,
  and SGR-reset-before-newline.
