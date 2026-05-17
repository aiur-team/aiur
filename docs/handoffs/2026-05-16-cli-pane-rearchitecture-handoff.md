# CLI Pane Rearchitecture Handoff

Created: 2026-05-16
Current branch: `feat/cli-pane-rearchitecture`
Base commit: `b6133c8` (`Add CLI rearchitecture plan`)
Latest commit at handoff: `bd00618` (`Drop opaque from subscription_ref`)

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

## What is NOT Done Yet

- The new agent-list pane does not render anything. The old `status_dashboard.ex`
  is still the CLI surface.
- No tmux integration code runs. The wrapper does not spawn a tmux session.
- No conversation pane process exists. `bin/symphony conversation <id>`
  exits immediately.
- `AgentRunner.codex_message_handler/4` does NOT yet broadcast transcript
  events. (Deferred — only useful when the conversation pane consumes them.)
- `AgentChat.send/2` does NOT yet broadcast a symmetric user-side
  `{:transcript_event, role: :user, ...}`. (Deferred — same reason.)
- `StatusDashboard` and `TerminalInput` are still in the supervision tree
  and still own the CLI surface. Cutover happens when the new agent-list
  pane is functional.
- CI image does not yet have tmux. Add as part of the integration-test
  task.

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

## Recommended Next Work (in suggested order)

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
