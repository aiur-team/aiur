# CLI Rearchitecture Brainstorm

Date: 2026-05-16
Branch context: `bug-fixes`
Replaces: `2026-05-16-cli-terminal-typing-requirements.md`

## Why This Brainstorm Exists

Multiple rounds of trying to fix typing latency and cursor offset in
`status_dashboard.ex` have not landed. The current symptoms — cursor +2 rows /
+2 cols off in Termius, typing that lags behind keystrokes, the log pane
re-rendering on its own clock and fighting the composer — are not isolated
bugs. They are symptoms of a structural mismatch: a 2,300-LOC monolithic
full-screen renderer that was originally a read-only dashboard and had an
interactive composer bolted on top.

Rather than keep patching, this brainstorm decides the next shape of the CLI.

## What We Are Building

A two-pane-types model with tmux as the layout manager.

**Agent-list pane** (small, always-visible, Symphony-owned)
- Renders the list of agents Symphony is orchestrating, with status.
- Shows a visual indicator on agents whose conversation has a pending alert.
- Arrow keys + enter to select an agent and "open" its conversation.
- Mostly read-only.

**Per-agent conversation pane** (one per open conversation, Symphony-owned)
- Renders that single agent's transcript (tail of the agent's log).
- Bottom composer that writes into a per-agent chat-injection path. Today's
  composer may target a global path; scoping it per-agent is tracked as
  Open Question 1.
- One log + one composer per pane. ~10× smaller surface than today's fused
  dashboard frame.
- Spawned when the user opens an agent. Closed when the user closes the pane.
  The agent process itself is unaffected by either event and continues running
  in the background.

**tmux owns layout.** Symphony does not own the whole screen. Pane creation,
resize, focus, and close are tmux's job. This is the future direction the user
wants the CLI to grow into (Symphony scripting tmux to open conversations in
new horizontal/vertical panes, auto-rebalance widths, etc.). Starting with the
two-pane-types model lets us grow into that without a second rewrite.

## Why This Approach (Not the Alternatives)

Three other options were considered and ruled out.

**Fix `status_dashboard.ex` in place.** Audit showed the architecture is
structurally wrong for an interactive composer: timer-driven full-frame
render, every keystroke triggers a `GenServer.cast` that re-reads the log file
from disk and re-renders the entire frame synchronously, incremental-paint
fallback is fragile and silently degrades on SSH clients tests don't catch.
Surgical fixes are real but the residual bug surface is high; we'd be back
here in a month.

**Clean-room Elixir TUI rewrite (full-screen single window).** Possible in
~1 week with `Owl.LiveScreen` + a hand-rolled event loop. But the user's
long-term direction is tmux-orchestrated panes — building a full-screen TUI
now and then carving it into panes later means rewriting twice. Ratatouille
is dead (last commit Oct 2021, has the same bugs we have). Bubble Tea via
port is 2–3 weeks honest, not 1.

**Embed Claude Code as the conversation surface.** Initially attractive
because Claude Code's typing and cursor are already excellent. But Symphony's
agents are Symphony-orchestrated long-running processes (driven by Symphony's
event loop, with Symphony-injected tools), not raw Claude Code sessions.
Spawning a fresh `claude` per conversation would create a new agent rather
than view an existing one. This option does not match the "agents run in the
background, conversation pane is a view into them" constraint.

The two-pane-types model is the only shape that satisfies all four
constraints simultaneously: feels like Claude Code (small focused pane is
tractable to make snappy), agents run in the background independent of which
panes are open, alerts surface without polluting conversation context, and
the architecture grows naturally into the future tmux orchestration vision.

## Key Decisions

1. **Two pane types, both Symphony-rendered, both draw into a single tmux
   pane each.** Agent-list (small, read-mostly) and per-agent conversation
   (log + composer). Symphony never owns the whole screen — tmux does.
2. **Agents are background processes.** Their lifecycle is decoupled from
   which conversation panes are open. Opening a pane = attaching a view;
   closing = detaching. The agent does not stop.
3. **Alerts surface in the agent-list pane** as per-agent indicators. They
   do not need to appear inside conversation panes.
4. **The current monolithic `status_dashboard.ex` is retired.** Salvage:
   agent-list rendering, terminal input loop, log parsing. Discard: global
   multi-agent log pane, global composer, snapshot-fingerprint dedup,
   incremental-input-repaint logic, top-margin hacks.
5. **Phased rollout.**
   - **Phase 1 (this pass):** Ship the two pane types **and** Symphony-driven
     pane spawning. Pressing enter/space on an agent in the agent-list pane
     fires the relevant tmux command under the hood to open that agent's
     conversation pane and adjust layout. Larger scope than the minimum
     viable, accepted in exchange for building it right the first time.
   - **Phase 2 (later):** Auto-rebalance pane widths; keyboard shortcuts
     for split-horizontal / split-vertical / close; cross-pane focus
     management.
   - **Phase 3:** Alert-injection into specific panes, cross-pane
     communication. Anything beyond this is out of scope until proposed
     concretely.
6. **Hard cutover from `status_dashboard.ex`.** Delete the old monolith in
   the same PR/branch that introduces the new pane types. No feature flag,
   no parallel surfaces. Work happens on a fresh branch off `main` so the
   risk is contained until the new flow is proven in Termius, then merged.
7. **Global composer retired entirely.** Composing only happens inside a
   per-agent conversation pane. The agent-list pane has no composer. No
   broadcast-to-all affordance.
8. **Per-agent conversation pane is a separate BEAM node.** A subcommand
   (e.g. `./scripts/agents conversation <agent-id>`) starts a hidden
   Erlang node, connects to Symphony's main BEAM via `Node.connect`, and
   subscribes to that agent's events through `Phoenix.PubSub`. Composer
   input is sent back via the same channel. Independent lifecycle from
   Symphony's supervision tree; survives Symphony restarts gracefully.
   This decision is driven by a future requirement: agents will
   eventually subscribe to events from other agents and from external
   sources (PRs, issues). `Phoenix.PubSub` already solves cross-process
   and cross-node fan-out, so the pane subcommand becomes one more
   subscriber with no protocol translation layer to maintain.
9. **tmux is a hard dependency.** Symphony's CLI does not run without
   tmux. The `agents` wrapper checks for tmux on startup and exits with
   a clear error if it is missing. Single supported configuration. If a
   real tmux-less use case surfaces later, a single-pane fallback can
   be added then.
10. **BEAM cold-start latency for pane spawn is accepted.** Spawning a
    new BEAM node per "open conversation" costs ~500–1000ms. The tmux
    split is happening simultaneously, which masks some of it. If it
    feels bad in practice, mitigations exist (escript / Burrito-bundled
    pane binary; warm pane-worker pool inside Symphony's main BEAM that
    streams over tmux pane stdio). Not in Phase 1 scope.

## Stated Assumptions

These are taken as given by this brainstorm. The plan should verify each
before relying on it.

1. **Symphony's main BEAM runs as a named distributed node.** The `agents`
   wrapper script starts it with `--name` (or `--sname`) and a stable
   cookie. Required for any pane subcommand to `Node.connect`.
2. **The pane subcommand discovers Symphony's node name and cookie at
   startup.** Mechanism (env vars set by the wrapper, a shared dotfile,
   or a discovery socket) is a plan-phase detail; the assumption is that
   something authoritative tells the pane where to connect.
3. **`Phoenix.PubSub` is configured with a cross-node adapter** (PG2 / PG)
   rather than the default single-node adapter. Required for the pane
   subcommand's subscriptions to receive events broadcast by the main
   BEAM.
4. **tmux runs on the host machine that runs Symphony.** Termius on iPad
   is just the SSH client; it does not run tmux itself. No tmux-on-iPad
   capability is required.
5. **Each agent emits its events on a distinct, predictable
   `Phoenix.PubSub` topic.** The conversation pane subscribes to one
   topic per agent. If today's events are broadcast on a global topic
   only, scoping them per-agent is part of the plan-phase work.

## Out of Scope

- Sound/audio alerts (user explicitly deferred).
- Phoenix LiveView replacement (considered, did not match tmux future).
- Embedding `claude`/`codex` as the agent driver itself (considered, breaks
  the background-agent constraint).
- Migrating audio assets out of the repo.
- Rewriting the orchestrator's agent lifecycle.

## Resolved Questions

All decisions are captured in **Key Decisions** above. This section exists
so future readers know these questions were posed and answered:

- Phase 1 entry UX → Key Decision 5 (Phase 1)
- Migration safety → Key Decision 6
- Global composer → Key Decision 7
- Pane process identity and connection mechanism → Key Decision 8
- tmux dependency → Key Decision 9

## Open Questions

1. **Per-agent chat injection path.** Does the existing chat-send path scope
   cleanly to one agent, or is it currently global? Plan-phase verification
   by reading `orchestrator.ex` and the chat-send call sites. If global,
   scoping it per-agent is part of Phase 1 work.
2. **tmux invocation mechanism: shell-out vs control mode.** Phase 1 says
   "Symphony scripts tmux," and the mechanism is load-bearing:
   - **Shell-out** (`System.cmd("tmux", ["split-window", …])`): simple,
     one-shot, no feedback channel. Pane-close detection has to come
     from tmux hooks (which run shell commands) or polling `tmux
     list-panes`.
   - **Control mode** (`tmux -CC`): bidirectional. Symphony attaches to
     tmux as a control client and receives a stream of `%output`,
     `%window-close`, `%pane-died`, etc. notifications. Cleaner fit for
     "keep the agent-list pane up-to-date as conversation panes open
     and close," but more setup.
   Decide in the plan phase. Likely control mode given the lifecycle
   requirements, but worth confirming.
3. **Claude Code Channels feasibility.** Not blocking. Phase 3
   alert-injection-into-conversation depends on whether external programs
   can write into a running `claude` session. Worth verifying before
   Phase 3 work starts, and only if we later decide to embed Claude Code
   as the in-pane agent driver (not currently planned).

## Success Criteria

- Typing latency in a conversation pane is indistinguishable from Claude Code
  when measured by the user in Termius on iPad over SSH.
- Cursor lands exactly where the user types, with no offset, in Termius and
  local PTY.
- Opening and closing a conversation pane does not interrupt the agent's
  background work.
- Alerts arriving while a conversation is closed are visible on the
  agent-list pane and persist until the user opens that conversation.
- `status_dashboard.ex` is deleted (not flagged off, deleted) by end of
  Phase 1.
