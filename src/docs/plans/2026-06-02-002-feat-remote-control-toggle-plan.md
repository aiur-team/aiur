---
title: "feat: Per-agent Remote Control toggle (Claude /remote-control)"
type: feat
status: active
date: 2026-06-02
origin: src/docs/brainstorms/2026-06-02-remote-control-toggle-requirements.md
---

# feat: Per-agent Remote Control toggle (Claude `/remote-control`)

## Overview

Add a per-agent runtime toggle that hands a running Claude agent off to Claude
Code's Remote Control — so it appears in the operator's native Claude app
(claude.ai/code + mobile) and can be driven from there — then hands it back to
aiur's autonomous loop. Pressing `r` on the selected agent in the agent list
toggles it; a 📱 indicator marks RC-on agents. No `.aiurconfig` surface.

This is **Claude-only for v1**. Codex "remote connections" is deferred but the
data model and UI stay backend-aware so it can be added without reshaping the UI.

### The core architectural fact (drives the whole design)

Aiur drives Claude through a headless turn loop (`claude --print` via the
symphony app-server). Remote Control is a separate model: a persistent
`claude remote-control` server whose session is driven interactively from the
Claude app. **A single session cannot be both headless-driven and RC-controlled
at once.** So the toggle is a *handoff*, not an overlay:

- **on**: pause aiur's autonomous driving of the agent, launch a per-agent
  `claude remote-control` server in the agent's workspace.
- **off**: stop that RC server, resume autonomous driving.

This means `r` (RC) and `Space` (pause) are mutually aware: an RC-on agent is, from
aiur's perspective, paused-and-handed-off.

---

## Verified facts (spike 2026-06-02 — see requirements doc)

- RC works with the existing OAuth subscription login; **no API key** (RC requires
  OAuth). `claude` 2.1.149.
- `claude remote-control --spawn session --name <n> --permission-mode bypassPermissions`
  registers with `api.anthropic.com`, emits a live `https://claude.ai/code/session_…`
  URL, and runs an outbound poll loop. `bypassPermissions` is accepted.
- RC has **no** `--resume`/`--continue`/`--session-id`; `--spawn session` creates a
  fresh session that "exits when complete".
- Workspace **trust** gates RC: per-project `hasTrustDialogAccepted` in
  `~/.claude.json` must be `true` (the headless `--print` path bypasses it; RC does
  not).
- RC server, when stdout is piped, writes nothing useful; it renders a TUI. Use a
  pseudo-tty and/or `--debug-file <path>` for observability. The session URL appears
  in the TUI; bridge/registration detail appears in the debug log
  (`[bridge:init]`, `[bridge:api] >>>`, `Registered, server environmentId=…`).

---

## Existing code this builds on

- `src/lib/aiur/agent_list/input.ex` — raw-mode key dispatch. `Space → App.toggle_pause`,
  `Enter → App.activate`, etc. Add `r → App.toggle_remote_control`.
- `src/lib/aiur/agent_list/app.ex` — agent-list GenServer. Holds `summaries`,
  subscribes to `AgentPubSub` running/status topics. `toggle_pause/1` cast +
  `toggle_selected_agent_pause` → `Orchestrator.pause_agent/resume_agent`. New state
  fields **must** be threaded through `render/1`'s `Map.take/put` pipeline (known
  footgun — see memory `render_state_takes_explicit`).
- `src/lib/aiur/agent_list/renderer.ex` — renders agent rows; add 📱 next to the
  identifier when RC is on.
- `src/lib/aiur/orchestrator.ex` — owns `state.running` (`%{issue.id => entry}` with
  `:pid, :ref, :identifier, :session_id, :thread_id, :control{status}, …}`). Public
  API pattern: `pause_agent/2`, `resume_agent/2`, `control_capabilities/2` — all
  `whereis`-guarded `GenServer.call`. Add `toggle_remote_control/2` (or
  `set_remote_control/3`) in the same shape. Per-agent RC state lives on the running
  entry (e.g. `:remote_control => %{status, session_url, server_pid, ref}`).
- `src/lib/aiur/coding_agent.ex` — backend registry (`backends/0`) with per-backend
  capabilities (`can_interrupt`, `safe_checkpoints`). Add `remote_control: true` for
  `"claude"`, `false` for `"codex"`, so the toggle is gated by backend capability.
- `src/lib/aiur/claude/config.ex` — Claude command + `permission_mode` resolution; the
  RC server should reuse the resolved permission mode.
- `src/lib/aiur/agent_environment.ex` — workspace env; reference for how a workspace is
  prepared (where trust pre-seed naturally belongs).

---

## Implementation Units

### U1 — Backend RC capability flag

**Goal:** Gate the toggle on backend support so Codex agents ignore `r`.
**Files:**
- Modify: `src/lib/aiur/coding_agent.ex` (add `remote_control: true/false` to
  `backends/0` entries; add a `remote_control?/1` helper).
- Test: `src/test/aiur/coding_agent_test.exs` (or nearest existing).
**Approach:** Single source of truth for "can this backend be remote-controlled".
**Test scenarios:**
- `remote_control?("claude") == true`, `remote_control?("codex") == false`,
  unknown backend → `false`.
**Verification:** unit test green.

### U2 — RC server process manager (`Aiur.Claude.RemoteControl`)

**Goal:** A module that, given an agent's workspace + name + permission mode, starts
a `claude remote-control --spawn session` server, captures its session URL, monitors
it, and stops it cleanly. One server per agent (single-session).
**Files:**
- Create: `src/lib/aiur/claude/remote_control.ex`
- Create: `src/test/aiur/claude/remote_control_test.exs`
**Approach:**
- Spawn via `Port`/`System` under a Task/Supervisor (mirror how
  `Aiur.Claude.CodingAgent` opens its port; reuse the `bash -lc` + env scrubbing
  pattern). Command:
  `claude remote-control --spawn session --name "<id>: <title>" --permission-mode <mode> --debug-file <path>`
  run in the agent workspace (`cd: workspace`).
- Parse stdout / the TUI line `Continue coding in the Claude mobile app or
  https://claude.ai/code/session_…` to extract the **session URL** (and the
  `--debug-file` for `[bridge:init] Registered`). Expose `session_url` once known.
- `stop/1` terminates the port/process group; ensure no orphan (port `:exit_status`,
  monitor, kill process group on teardown — the agent runner already scrubs
  `ERL_AFLAGS` etc., follow that).
- **Trust pre-seed:** before launch, ensure the workspace project has
  `hasTrustDialogAccepted: true`. Investigate the narrowest mechanism (settings flag /
  env) first; fall back to an atomic, backup-guarded edit of `~/.claude.json` for that
  one project key. Isolate this in a small `ensure_workspace_trusted/1` function so the
  hack is contained and testable.
**Test scenarios:**
- start/stop lifecycle returns `{:ok, %{server_pid, …}}` / `:ok`; double-stop is a
  no-op.
- session URL is extracted from a captured sample line (test against a fixture string,
  not a live server).
- `ensure_workspace_trusted/1` sets the key when absent and is idempotent when present
  (test against a temp JSON file, not the real `~/.claude.json`).
- teardown kills the process (no orphan) — assert monitor `:DOWN` / exit.
**Execution note:** characterization-first for the URL parser (capture a real sample,
assert the parse), since the TUI format is the contract.
**Verification:** unit tests green; manual: module starts a real RC server and prints
the session URL.

### U3 — Orchestrator: per-agent RC state + lifecycle

**Goal:** Own RC on/off per agent; coordinate with pause/resume and termination.
**Files:**
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: `src/test/aiur/orchestrator_*_test.exs` (nearest control/pause test)
**Approach:**
- Add public `set_remote_control/3` (`identifier, on?`) following the
  `pause_agent` shape; handle `{:set_remote_control, id, on?}` in the GenServer.
- on→true: cooperatively pause the agent (reuse existing pause path / safe
  checkpoint), then `Aiur.Claude.RemoteControl.start/1` for that workspace; store
  `remote_control: %{status: :on, session_url, server_pid, ref}` on the running entry;
  broadcast a running-summary update so the list shows 📱.
- on→false: `RemoteControl.stop/1`, clear RC state, resume autonomous driving
  (existing resume path), broadcast update.
- Guard: reject if backend `remote_control?/1` is false (`{:error, :unsupported}`),
  or agent not running (`{:error, :not_running}`).
- **Teardown coupling:** on agent `:DOWN` / terminal issue state while RC on, stop the
  RC server (extend the existing `:DOWN`/cleanup handler). On aiur shutdown, stop all
  RC servers (terminate/2 or supervised process cleanup) — no zombie servers, no
  registered sessions left dangling.
- Surface RC capability/status via the existing `control_capabilities/2` and the
  running snapshot that feeds `AgentPubSub`.
**Test scenarios:**
- set on for a claude agent → entry gains `remote_control.status == :on`, agent
  paused, start invoked (RC module stubbed/mocked at the boundary).
- set on for a codex agent → `{:error, :unsupported}`, no state change.
- set off → RC stopped, agent resumed.
- agent `:DOWN` while RC on → RC stop invoked, entry removed.
- set on when not running → `{:error, :not_running}`.
**Execution note:** integration-style — exercise the real pause/resume + state
transitions; mock only the external `claude remote-control` spawn at the
`Aiur.Claude.RemoteControl` boundary.
**Verification:** tests green.

### U4 — Agent list: `r` toggle + state threading

**Goal:** Wire the key and per-agent RC state into the TUI app.
**Files:**
- Modify: `src/lib/aiur/agent_list/input.ex` (`dispatch("r", target, _) →
  App.toggle_remote_control(target)`).
- Modify: `src/lib/aiur/agent_list/app.ex` (`toggle_remote_control/1` cast;
  `toggle_selected_agent_remote_control/1` resolving the selected running agent →
  `Orchestrator.set_remote_control`; ingest `remote_control` from summaries; **thread
  any new state field through `render/1`'s `Map.take`**).
- Test: `src/test/aiur/agent_list/app_test.exs`
**Approach:** Mirror `toggle_pause` exactly. Capability-gate: pressing `r` on a
non-claude or non-running agent is a no-op (optionally ring the bell like resume
failures do).
**Test scenarios:**
- `r` on selected running claude agent calls `Orchestrator.set_remote_control(id,
  true)`; pressing again calls it with `false` (toggle semantics off the summary's RC
  status).
- `r` on a codex agent / no selection → no call.
- summary carrying `remote_control.status == :on` is retained through a render cycle
  (guards the `Map.take` footgun).
**Verification:** tests green.

### U5 — Renderer: 📱 indicator

**Goal:** Show 📱 next to the identifier for RC-on agents.
**Files:**
- Modify: `src/lib/aiur/agent_list/renderer.ex`
- Test: `src/test/aiur/agent_list/renderer_test.exs`
**Approach:** In the agent-row build, prefix/suffix the identifier with 📱 when
`summary.remote_control.status == :on`. Keep alignment/width correct (emoji width).
**Test scenarios:**
- RC-on row includes 📱 adjacent to the id; RC-off row does not.
- column alignment unbroken with the emoji present (assert rendered width / no crash).
**Verification:** tests green; manual visual check in the TUI.

### U6 — Docs

**Goal:** Document the toggle.
**Files:**
- Modify: `src/README.md` (agent-list key list — `r` opens/closes Remote Control;
  the existing paragraph documents `Enter`/`Space`).
- Modify: `AGENTS.md` (root) if it documents agent-list controls.
**Approach:** One sentence on `r` + 📱 + the subscription/OAuth requirement and that
it's Claude-only.
**Verification:** docs read correctly; no stale claims.

---

## Cross-repo dependency (flag)

Clean **handoff back** (autonomous resume continuing the RC-advanced conversation)
likely needs the symphony **`claude-app-server`** (the operator's
`~/github/claude-app-server`, repo `its-everdred/claude-app-server`) to `--resume` the
session id. v1 does **not** depend on this: v1 hands off (pause → RC → resume), and on
resume the autonomous agent continues its own session against the (possibly
RC-advanced) **git workspace state**. Deep conversation-merge is deferred. If resume
continuity proves poor in manual testing, open a follow-up against the symphony repo.

## Context handoff strategy (decided)

RC can't be launched with `--resume`, so the fresh RC session starts without aiur's
in-flight conversation. Three layered options, cheapest-reliable first:

1. **Auto-generated handoff doc from the shared session logs (default, reliable).**
   The agent's own session transcript already lives in the shared workspace project
   dir: `~/.claude/projects/<workspace-slug>/<uuid>.jsonl`. On RC toggle-on, aiur reads
   that `.jsonl` and writes a `REMOTE_CONTROL_HANDOFF.md` (or similar) into the agent's
   workspace summarizing the task + conversation-so-far, so the operator picks up with
   full context even though the conversation forks. This directly leverages the
   same-workspace logs the operator flagged — no dependency on RC resume support.
2. **In-app `/resume` of the local session (seamless if it works).** Because RC runs in
   the same workspace dir, the operator *may* be able to `/resume` the agent's existing
   session from the Claude app (shared project dir). **Unverified** — test manually. If
   it works, it's strictly better than the handoff doc; keep the doc as fallback.
3. **Pin a known `--session-id` per agent** (planning-time investigation in symphony) so
   the session identity is stable and addressable for both resume paths above.

v1 ships option 1 and manually evaluates option 2. Build the handoff-doc generation as
a small function (`Aiur.Claude.RemoteControl.write_handoff/2`) reading the session
`.jsonl` from the project dir; test it against a fixture transcript.

## Deferred to implementation

- Exact session-URL parse: confirm the live TUI line format and whether to read it
  from stdout-via-pty or the `--debug-file` (`[bridge:work] … session`). Pick whichever
  is stable.
- Whether to surface the session URL in the TUI (e.g. a footer hint) or just 📱. Start
  with 📱; add URL display only if cheap.
- Trust pre-seed mechanism: prefer a non-`~/.claude.json` lever if one exists.

## Scope boundaries (non-goals)

- Codex remote connections.
- LiveView dashboard + JSON API parity (CLI-first; mirror later for agent-native
  parity).
- Conversation-level transcript merge between RC and autonomous sessions.
- Multi-agent shared RC server (`--spawn worktree --capacity N`).

## Risks / watch-list

- **Orphan RC servers / dangling registered sessions** if teardown misses a path
  (agent crash, aiur restart). Mitigate with monitors + terminate cleanup; assert in
  tests.
- **Trust pre-seed clobbering `~/.claude.json`** (66KB, concurrently written by a live
  claude). Use atomic write + backup, edit only the one project key, and prefer a
  cleaner lever if found.
- **Permission mode mismatch**: if RC runs with `bypassPermissions` the remote
  operator gets aiur's autonomy on their phone — intended, but document it.
- **Emoji width** breaking TUI column alignment.
- **Pause/RC race**: pressing `Space` and `r` in quick succession. Define precedence
  (RC-on implies paused; `Space` while RC-on is a no-op or surfaces a hint).

## Success criteria

- `r` on a running Claude agent → session appears in claude.ai/code + mobile, 📱 in
  the list; operator messages the agent and gets a response.
- `r` again → 📱 gone, RC session torn down, aiur resumes driving; no orphan server.
- Correct across termination / pause interaction / aiur restart.
- `mix format`, `mix compile --warnings-as-errors`, test suite green.
