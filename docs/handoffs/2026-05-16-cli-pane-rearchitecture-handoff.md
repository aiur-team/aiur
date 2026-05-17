# CLI Pane Rearchitecture Handoff

Created: 2026-05-16 (revised 2026-05-17 after end-to-end demo works)
Current branch: `feat/cli-pane-rearchitecture`
Base commit: `b6133c8` (`Add CLI rearchitecture plan`)
Latest commit at handoff revision: `30e67e2` (`Wire end-to-end pane spawning`)

## Session 3 Result: `./scripts/agents` Works End-to-End

After the cutover and tmux-spawning wiring, the demo works:

```
./scripts/agents
```

creates a tmux session, runs the new agent-list pane as the foreground process, dispatches agents, and lets the user press enter/space to open per-agent conversation panes. Typing in the composer renders locally as `you: <text>` and dispatches an `:rpc.cast` to the orchestrator's chat-send path.

Verified manually 2026-05-17:

- Agent-list pane renders `Symphony — Agents`, `▶ 25 [running]`, footer hints.
- Enter spawns a horizontal split with `bin/symphony conversation 25` inside.
- Conversation pane renders `Symphony — 25` header.
- Typing "hello world" + Enter renders `you: hello world` in the transcript.

The path between conversation composer and orchestrator's chat-send is wired via `:rpc.cast` and `Phoenix.PubSub`, with a unique `-sname pane-<id>` per spawned pane so multiple BEAM nodes don't collide on the same name.

## Why This Handoff Exists

A multi-week effort to fix typing latency and cursor offset bugs in
`status_dashboard.ex` failed because the architecture was structurally wrong
for an interactive composer. The previous session (2026-05-16) committed to
rebuilding the CLI around a tmux-orchestrated, two-pane-types model and
landed the foundation. The next agent picks up from there to implement the
real pane rendering, tmux integration, and cutover.

The full reasoning and decision trail is captured in the brainstorm and plan
documents below. **Read those first, in order.**

## Source Documents (Read in This Order)

1. `docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md`
   - Decides the shape: two pane types, tmux as layout manager, separate
     BEAM node per pane via Erlang distribution, hard cutover from
     `status_dashboard.ex`.
   - Key Decisions 1-10 are the contract for the next session. Do not
     re-litigate them without explicit user input. The "Reviewer Pushback"
     section captures the alternative (single-BEAM + Unix socket) and why
     it was rejected.

2. `docs/plans/2026-05-16-feat-cli-pane-rearchitecture-plan.md`
   - Enumerates 28 Phase 1 tasks, module-by-module breakdown, payload
     contracts, integration test scenarios, and the user's acceptance
     criteria (typing-feels-like-Claude-Code in Termius on iPad).
   - "Reviewer Pushback on KD 8" section is resolved (kept) but worth
     reading so you understand the trade-off.

3. This handoff document (you are here) — describes what shipped in the
   first session and what to do next.

## What Shipped in Session 1 (Foundation)

Commits on `feat/cli-pane-rearchitecture` after `Add CLI rearchitecture plan`:

| Commit | Description |
|---|---|
| `65c691f` | Add Owl dep |
| `4496e50` | Add AgentEvents payload types |
| `c705d10` | Add AgentPubSub wrapper |
| `9b05f8b` | Add Distribution module |
| `bfda730` | Broadcast running set on update |
| `7ec00dc` | Broadcast alerts on agent topic |
| `306ac24` | Add distribution setup to wrapper |
| `13787d3` | Scaffold pane RPC contract modules |
| `84fd703` | Scaffold tmux integration modules |
| `7516368` | Scaffold agent-list pane modules |
| `7456324` | Scaffold conversation pane modules |
| `6014803` | Wire Distribution into app startup |
| `f8a51e7` | Add conversation subcommand dispatch |
| `49f5b8f` | Exempt scaffolds from coverage |
| `bd00618` | Drop opaque from subscription_ref (dialyzer fix) |

### Real implementations landed (with tests)

- `SymphonyElixir.AgentEvents` — payload type contracts (`transcript_event`,
  `alert_event`, `agent_summary`, topic helpers). Single canonical
  wire-format reference.
- `SymphonyElixir.AgentPubSub` — thin wrapper modeled on
  `ObservabilityPubSub`. `subscribe_agent/1`, `subscribe_running/0`,
  `subscribe_status/0`, `broadcast_transcript/2`, `broadcast_alert/2`,
  `broadcast_running_change/1`, `broadcast_status_change/2`.
- `SymphonyElixir.Distribution` — node-name + epmd validation,
  `:net_kernel.monitor_nodes(true, node_type: :hidden)` setup. Called from
  `Application.start/2` (logs status but never fails app start).
- `SymphonyElixir.Conversations` — `attach/1` returns a `subscription_ref`,
  `detach/1` unsubscribes. Currently a thin shim over `AgentPubSub`; will
  grow when `Conversation` is real.
- `SymphonyElixir.AgentDirectory` — read-side primitives
  (`list_agents/0`, `get_transcript_tail/2`, `get_alerts/1`). Returns empty
  for now; future MCP bridge surfaces them verbatim.
- `SymphonyElixir.PaneRPC` — explicit cross-node call chokepoint with
  server-side input validation (64 KiB length cap, control-char filter).
- `scripts/agents` wrapper — tmux pre-flight check, `~/.erlang.cookie`
  create with `umask 0177` + atomic temp-write + UID/length validation,
  `ERL_AFLAGS="-sname symphony-${USER}"`, `ERL_EPMD_ADDRESS=127.0.0.1`,
  `SYMPHONY_NODE` exported, `~/.config/symphony/` mode 0700.

### Producer wiring (parallel to existing `StatusDashboard.notify_update`)

The new PubSub broadcasts fire **alongside** the old `notify_update` calls,
not in place of them. The old CLI continues to work; the new subscribers
get their events too.

- `Orchestrator.notify_dashboard/1` (was arity 0) — now takes `state`,
  builds `agent_summary` list from `state.running`, and broadcasts
  `{:running_changed, summaries}` on `"agents:running"` before delegating
  to `StatusDashboard.notify_update/0`. All 7 internal call sites updated.
- `Alerts.do_emit/3` — broadcasts `{:alert, alert_event}` on `"agent:<id>"`
  when an identifier is available from `opts[:issue]` or `opts[:identifier]`.

### Scaffolds (compile clean, return `{:error, :not_implemented}` or no-op)

These exist so the supervision tree, plan tasks, and dialyzer can reference
real module names. Real implementations are next session's work.

- `SymphonyElixir.Tmux` — `command/1`, `subscribe_events/0`,
  `spawn_pane_for/1`.
- `SymphonyElixir.PaneManager` — `open_conversation/1`,
  `close_conversation/1`, `list_open_panes/0`.
- `SymphonyElixir.PaneWarmPool` — `claim/0`, `warm_count/0`.
- `SymphonyElixir.AgentList.{Renderer, Input, App}` — three modules for
  the agent-list pane.
- `SymphonyPane.{CLI, Conversation, Viewport, Composer}` — four modules
  for the per-agent conversation pane.

### CLI argv dispatch

`SymphonyElixir.CLI.main(["conversation" | rest])` routes to
`SymphonyPane.CLI.main/1`. Today that just `System.halt(0)`s; future
sessions implement real boot logic.

`bin/symphony --version` and the existing workflow path forms are unchanged.

## Session 2 Addendum (same day)

After the initial handoff was written, the same agent continued implementing
the remaining Phase 1 modules. Additional commits on `feat/cli-pane-rearchitecture`:

| Commit | Description |
|---|---|
| `e922f5c` | Add pane rearchitecture handoff |
| `887dc16` | Add tmux control-mode protocol parser |
| `81b37b4` | Implement Tmux control-mode GenServer |
| `643e123` | Implement PaneManager |
| `c599e21` | Implement AgentList Renderer |
| `a546227` | Implement AgentList Input and App |
| `3a72b5c` | Implement Composer state machine |
| `deebe83` | Implement Viewport full-frame renderer |
| `95c0870` | Implement Conversation and CLI bootstrap |
| `d1ae3e1` | Wire agents-pane CLI subcommand |

**What this means:** every module the plan calls out as Phase 1 now has a real
implementation with tests, not just a scaffold. The new agent-list pane is
launchable today via `bin/symphony agents-pane`.

### What is real now

- `SymphonyElixir.Tmux.Protocol` — pure parser for the tmux control-mode wire
  format (`%begin`/`%end`/`%error`/`%pane-died`/`%window-pane-changed`/
  `%client-detached`/`%session-changed`/`%output`/`%exit`). 13 unit tests.
- `SymphonyElixir.Tmux` — GenServer owning the `tmux -CC attach` Port,
  routing commands and notifications. Pluggable transport (`:port` for
  production, `{:mock, pid}` for tests). Bounded reopen on Port exit (3
  attempts by default). 3 tests.
- `SymphonyElixir.PaneManager` — `identifier -> pane_id` mapping, consumes
  tmux notifications, broadcasts `:pane_opened` / `:pane_closed` on
  `"agents:status"`. 4 tests.
- `SymphonyElixir.AgentList.Renderer` — pure rendering function (transcript
  header, agent rows with selection marker and alert count, footer). 4 tests.
- `SymphonyElixir.AgentList.Input` — keystroke loop with CSI parser for
  arrow keys, dispatches to `AgentList.App` (select/activate/quit).
- `SymphonyElixir.AgentList.App` — GenServer subscribing to
  `"agents:running"` and `"agents:status"`, holds selection state, renders
  via `Renderer`. On activate, calls `PaneManager.open_conversation/3`. 4
  tests.
- `SymphonyPane.Composer` — buffer + cursor state machine. Length cap,
  control-char filter, history. 11 tests.
- `SymphonyPane.Viewport` — full-frame renderer with transcript region +
  composer prompt. Cursor positioning. Reserved final column. 5 tests.
- `SymphonyPane.Conversation` — GenServer threading viewport + composer +
  PubSub subscription + remote `:rpc.cast` to send messages. 4 tests.
- `SymphonyPane.CLI` — bootstrap: start `:phoenix_pubsub`, start the
  Conversation GenServer, monitor it for shutdown.

### CLI dispatch and supervision

- `bin/symphony agents-pane <workflow>` — sets `:pane_cli` env flag, then
  invokes the existing CLI entry; the application boots with Tmux,
  PaneManager, AgentList.App, AgentList.Input in supervision **instead of**
  `StatusDashboard` + `TerminalInput`.
- `bin/symphony --interactive <workflow>` — unchanged old CLI.
- `bin/symphony conversation <id>` — starts a conversation pane bootstrap
  (real now, not just `System.halt(0)`).
- `Application.stop/2` knows about both modes and only calls
  `StatusDashboard.render_offline_status/0` in the legacy path.

### What is still NOT done

- `scripts/agents` does NOT yet auto-create a tmux session and run
  `agents-pane` inside it. The user has to wire this manually for now (run
  `tmux new-session -s symphony && tmux send-keys './bin/symphony
  agents-pane ./local-workflows/WORKFLOW.symphony.local.md' Enter && tmux
  attach -t symphony`). The next session should update the wrapper.
- `AgentRunner.codex_message_handler/4` does NOT broadcast transcript
  events. The conversation pane will show alerts (because `Alerts.do_emit/3`
  broadcasts already) but NOT agent transcript turns until this is wired.
- `AgentChat.send/2` does NOT broadcast a symmetric user-side
  `{:transcript_event, role: :user, ...}`. The composer's local optimistic
  echo works, but other subscribers (e.g., a second pane on the same agent)
  won't see user-side turns.
- `StatusDashboard` and `TerminalInput` are still in the codebase (used by
  legacy `--interactive` mode). Hard cutover (delete the files) is a future
  task.
- Three Phase 1 integration tests (real tmux end-to-end, cross-node PubSub,
  pane-exits-on-Symphony-death) are not written.
- CI image does not yet have tmux installed.
- Termius-on-iPad verification has not happened. **This is still the merge
  gate.**

### Manual end-to-end smoke (works in any terminal)

```
# Terminal 1
cd elixir
mise exec -- mix escript.build
mise exec -- ./bin/symphony agents-pane --interactive \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./local-workflows/WORKFLOW.symphony.local.md
```

You will see the `Symphony — Agents` pane render. Pressing keys (j/k/↑/↓
to select, enter/space to activate) will work in a real TTY; in
non-interactive shells the raw-mode setup fails gracefully and rendering
still happens.

`SYMPHONY_NODE` env var (set by `scripts/agents`) makes `bin/symphony
conversation <id>` connect to the running Symphony BEAM via Erlang
distribution; without it the conversation pane shows transcript locally
but cannot send messages back.

### Test state at this revision

- 481 tests total (43 new this session).
- 4 pre-existing failures unchanged from `main` (alerts hardcoded
  `/Users/kevin/` path, three prompt-builder env-drift tests).
- `mix credo --strict`: zero issues.
- `mix specs.check`: clean.
- `mix compile --warnings-as-errors`: clean for all new code.

## Verification State at Handoff

- `mise exec -- mix compile --warnings-as-errors`: clean.
- `mise exec -- mix credo --strict` over 118 files: zero issues.
- `mise exec -- mix specs.check`: all public defs covered.
- `mise exec -- mix test`: 438 tests, 4 failures (same 4 that fail on
  `main` today — hardcoded `/Users/kevin/alerts/` path + 3 prompt-builder
  env-drift tests). 29 new tests added in this session.
- `mise exec -- mix dialyzer`: one pre-existing warning in
  `status_dashboard.ex:1002` (not touched in this session). New code is
  dialyzer-clean.
- Manual launch via `./scripts/agents`: existing dashboard renders, agent
  dispatches, Phoenix UI on `:4000`. BEAM cmdline confirmed to include
  `-sname symphony-applekid` (distribution active).
- Subscriber smoke test via `iex --remsh symphony-applekid@$(hostname -s)`:
  `SymphonyElixir.AgentPubSub.subscribe_running()` followed by `flush()`
  delivers `{:running_changed, [...]}` messages. Alerts emitted via
  `Alerts.emit_custom("demo.x", "msg", identifier: "MT-1")` deliver
  `{:alert, ...}` on the matching agent topic.

## Recommended Next Work (REVISED for post-Session-2 state)

The remaining work after Session 2 is much smaller than the original list.
In suggested order:

1. **Update `scripts/agents` to launch the new pane CLI inside tmux.**
   - Detect tmux + create session if absent.
   - Run `bin/symphony agents-pane <workflow>` as foreground of pane 0.
   - `tmux attach -t <session>` if foreground mode requested.
   - Keep the existing `agents` subcommand working for legacy users until
     the user is happy with the new pane CLI.
2. **Wire `AgentRunner.codex_message_handler/4` to broadcast transcript
   events.** Map the loose codex event map to a `transcript_event` and
   call `AgentPubSub.broadcast_transcript/2`. Skip events that aren't
   transcript-shaped (token usage, rate limits).
3. **Wire `AgentChat.send/2` symmetric broadcast.** After
   `Orchestrator.send_operator_message/2` returns `{:ok, _}`, broadcast
   `{:transcript_event, %{role: :user, body: text, msg_id: ...}}` on
   `"agent:<id>"`.
4. **Termius verification on iPad.** The user runs the new flow and
   confirms typing feels like Claude Code. **This is the merge gate.**
5. **Hard cutover.** Delete `lib/symphony_elixir/status_dashboard.ex`,
   `lib/symphony_elixir/terminal_input.ex`, and their tests. Drop the
   `pane_cli`/`interactive_cli` env-flag branching in `application.ex`
   (always use the pane stack). Update `mix.exs` coverage `ignore_modules`
   to drop the deleted modules.
6. **Integration tests.** Three scenarios per the plan:
   - End-to-end pane spawn (tmux pane exists, hidden BEAM connected,
     `"agent:<id>"` subscribed).
   - Cross-node PubSub delivery.
   - Pane exits cleanly on Symphony death.
   Provision tmux >= 3.3 in the CI image.

---

## Original Recommended Next Work (kept for reference)

Each item is a small commit. User-facing conventions from
`docs/handoffs/2026-05-15-pubsub-next-handoff.md` and previously-saved
agent memory apply: implement, add test, run build, lint:fix, commit
(3-7 word message), push. Run each git/mix command as its own Bash call
so the permission prompt is reusable. Manually verify the CLI launches
cleanly before considering each unit done. The full session is not done
until you have also manually exercised the new behavior end to end —
not just passed unit tests.

1. **Implement `SymphonyElixir.Tmux` control-mode client.** This is the
   biggest single piece left and unblocks everything else. Open `tmux -CC`
   as a Port from a supervised GenServer. Parse the `%begin`/`%end`,
   `%output`, `%pane-died`, `%window-pane-changed`, `%client-detached`
   protocol. Expose `command/1` (synchronous, awaits `%end`),
   `subscribe_events/0`, `spawn_pane_for/1`. Test with an in-memory mock
   port (the API mentions `:input_fun` / `:render_fun` style seams to
   preserve from the old `TerminalInput`). External research on tmux
   control mode is captured in the plan's "Sources & References" section.

2. **Real `SymphonyElixir.PaneManager`.** GenServer state: `%{identifier
   => pane_id}`. Subscribes to `Tmux.subscribe_events/0` and to
   `:net_kernel.monitor_nodes` (already enabled by `Distribution`).
   Treats `:nodedown` as authoritative pane-closed signal per cited tmux
   issues #2483, #2882. Implement `open_conversation/1` and
   `close_conversation/1` using `Tmux.spawn_pane_for/1`.

3. **`SymphonyPane.Viewport`.** Pure renderer with two regions: transcript
   (top, append-mostly) and composer (bottom, fixed-height). Line-by-line
   diff against last-rendered state. Reserve final column (the Termius
   autowrap lesson from the previous bug-fix attempts). Use
   `Owl.Data.tag/2` for ANSI composition and `Owl.IO.columns/0` for size
   detection. Add `:timer.tc/1` measurement in the hot path; target
   `<200μs` per keystroke per the plan's acceptance criteria.

4. **`SymphonyPane.Composer`.** Buffer + cursor state. CSI parser ported
   from the old `terminal_input.ex:256-305` (copy, don't re-export).
   On submit: generate a client-side `msg_id`, optimistically render
   locally, call `PaneRPC.send_operator_message/2` via `:rpc.cast`
   (async, never blocks enter), wait for the orchestrator's symmetric
   broadcast to confirm and replace the optimistic entry.

5. **`SymphonyPane.Conversation` GenServer.** Threads `Viewport` +
   `Composer` + a transcript-tail buffer. Subscribes to `"agent:<id>"`,
   monitors Symphony's node, coalesces `{:transcript_event, ...}` bursts
   into 16ms frames via `Process.send_after(self(), :flush_render, 16)`.
   Keystrokes bypass coalescing — render the composer immediately.
   De-duplicate user-side broadcast loopback by `msg_id`.

6. **`SymphonyPane.CLI.main/1` bootstrap.** Read `SYMPHONY_NODE` env var,
   start `:phoenix_pubsub` with matching `pool_size: 1`, `Node.connect/1`,
   `Node.monitor/2`, call `Conversations.attach/1`, hand off to
   `Conversation.start_link/1`. Exit cleanly on `{:nodedown, _}`.

7. **`AgentList.Renderer` (real).** Pure function rendering agent rows
   with status indicators and per-agent alert markers. Output is iodata
   for the pane's foreground process to write to stdout.

8. **`AgentList.Input` (real).** Keystroke loop owning stdio for the
   agent-list pane. Reuse the CSI parser from the old
   `terminal_input.ex`. On enter/space, call `Tmux.spawn_pane_for/1` so
   `PaneManager` spawns a tmux pane running `bin/symphony conversation
   <id>`.

9. **`AgentList.App`.** Subscribes to `"agents:running"`,
   `"agents:status"`, and (one subscription per visible agent) the
   `"agent:<id>"` topic so alert indicators can be rendered. Threads
   `Renderer` and `Input` together.

10. **`PaneWarmPool`.** Pre-spawn one `bin/symphony conversation --warm`
    process at app startup. On `claim/0`, return the warm pid, replace
    it with a fresh spawn. Phase 1 ships size 1; document that the second
    concurrent open is still cold-path.

11. **`AgentRunner` transcript broadcast.** Add a sibling
    `AgentPubSub.broadcast_transcript(identifier, event)` call in
    `codex_message_handler/4` next to `AgentEventLog.write/3`. Map the
    loose codex event map to a typed `transcript_event` (best-effort
    role/body extraction; skip if the event isn't transcript-shaped).

12. **`AgentChat.send/2` symmetric broadcast.** After
    `Orchestrator.send_operator_message/2` returns `{:ok, _}`, broadcast
    `{:transcript_event, %{role: :user, body: text, msg_id: ...}}` on
    `"agent:<id>"` so any subscriber (other pane, future external agent)
    sees user-side turns, not just agent-side. This pairs with the
    `msg_id`-based dedup in `Composer`.

13. **Cutover.** Remove `StatusDashboard` and `TerminalInput` from
    `application.ex` children. Fix `Application.stop/2` to drop the
    `StatusDashboard.render_offline_status/0` call. Delete
    `lib/symphony_elixir/status_dashboard.ex`,
    `lib/symphony_elixir/terminal_input.ex`, and their test files.
    Update `mix.exs` coverage `ignore_modules` to drop those entries.
    Verify LiveView's `ObservabilityPubSub.broadcast_update/0` still
    fires from somewhere — currently it is called from inside
    `StatusDashboard.notify_update/0`, which is going away; either move
    the call into `notify_dashboard/1` (orchestrator) or into the new
    `AgentPubSub.broadcast_running_change/1`.

14. **Integration tests.** Three scenarios per the plan:
    - End-to-end pane spawn (tmux pane exists, hidden BEAM connected,
      `"agent:<id>"` subscribed).
    - Cross-node PubSub delivery (two BEAM nodes, matching `pool_size`,
      message arrives within 100ms).
    - Pane exits cleanly on Symphony death.
    Provision tmux >= 3.3 in the CI image as part of this work.

15. **Termius verification on iPad.** **This is the merge gate.** Until
    the user has used the new CLI in Termius on iPad and confirmed
    typing feels like Claude Code with no cursor offset, the work is
    not done. Local PTY verification is not sufficient — that was the
    lesson of the previous fix-in-place attempts.

## Constraints Carried From the Previous Session

These are persisted in `~/.claude/projects/.../memory/` under feedback
memories and apply for the rest of this work:

- **One small unit per commit.** Implement → add test → run build →
  `lint:fix` → commit (message 3-7 words) → push. Do not bundle.
- **Manual CLI exercise before declaring any session done.** Launch
  `./scripts/agents` and verify the surface still works (and the new
  surface works as expected once it exists). Troubleshoot if it does
  not.
- **One Bash invocation per git/mix command.** Do not chain with `&&`
  — the user wants per-command permission prompts they can grant once
  and reuse.
- **Style reference:** `github.com/ethereum-optimism/actions`
  CONTRIBUTING.md (TypeScript/viem-flavored but the principles apply).
  Already mirrored to memory under `reference_style_guide.md`. Key
  bits: tests for every feature; mock at boundaries, never mock pure
  utilities; reuse before invention (grep first); single
  responsibility; functions <= 20 logical LOC; files <= 200 LOC; no
  em-dashes in code or docs; named concrete exception modules; preserve
  causes when re-raising.
- **`make all` is the merge gate** per `elixir/AGENTS.md:33`. Zero new
  lint or dialyzer warnings.
- **`@spec` is required** on every public `def` in `lib/` per
  `elixir/AGENTS.md:37-46`. Enforced by `mix specs.check`.
- **No PR until Termius verification.** The user gates on subjective
  feel in Termius on iPad, not on test results alone.

## Open Questions (Resolved or Documented)

From the brainstorm's open-questions list, current state:

- **Per-agent chat-injection path:** RESOLVED (it is already per-agent
  via `Orchestrator.send_operator_message/2`; no scoping work needed).
- **tmux invocation mechanism:** RESOLVED (control mode `tmux -CC
  attach`, not shell-out + hooks — see plan's external research).
- **Claude Code Channels feasibility:** still hypothetical and only
  matters if Phase 3 decides to embed Claude Code as the in-pane
  driver (not currently planned).
- **`AgentEvents` and `AgentDirectory` speculative debt:** flagged in
  the simplicity reviewer's pass; user decided to keep both because
  they are tiny and the pub/sub future requires the contract.

## Repo Layout Pointer

If you are picking this up fresh:

- Branch: `feat/cli-pane-rearchitecture` on
  `github.com/its-everdred/symphony`.
- Origin docs: `docs/brainstorms/2026-05-16-cli-rearchitecture-brainstorm.md`
  and `docs/plans/2026-05-16-feat-cli-pane-rearchitecture-plan.md`.
- Memory directory:
  `~/.claude/projects/-home-applekid-github-its-applekid-symphony/memory/`.
  Read `MEMORY.md` first; it indexes the feedback / project / reference
  memories.
- Wrapper script: `scripts/agents` (sources `~/.config/symphony-dashboard.env`,
  builds escript via `mise exec -- mix escript.build` if stale, launches
  `bin/symphony`).
- Build/test: `cd elixir && mise exec -- make all`.

Do not work on `bug-fixes`. That branch holds two abandoned typing-fix
attempts on top of `main`; the rearchitecture supersedes them.

## Boundaries

In scope next:

- Implementing the modules left as scaffolds (in the suggested order
  above).
- The hard cutover from `StatusDashboard` once the new agent-list pane
  is functional.
- Adding the three Phase 1 integration tests and CI tmux provisioning.

Out of scope unless redirected:

- Reversing brainstorm Key Decision 8 (separate BEAM per pane). User
  resolved this after reviewer pushback in the previous session.
- Phase 2 work (auto-rebalance, multiple keyboard shortcuts).
- Phase 3 work (cross-pane communication, alert injection into
  specific panes, Claude Code Channels evaluation).
- Touching the LiveView dashboard except to keep
  `ObservabilityPubSub.broadcast_update/0` firing after cutover.
