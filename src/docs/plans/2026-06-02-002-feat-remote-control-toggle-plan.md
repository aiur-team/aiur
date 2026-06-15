---
title: "feat: Per-agent Remote Control toggle (Claude /remote-control)"
type: feat
status: active
date: 2026-06-02
deepened: 2026-06-02
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
at once.** So the toggle is a *handoff*, not an overlay.

**Pause is not enough — RC-on must fully stop the agent's session.** (Verified in
code, 2026-06-02.) aiur's existing pause does *not* free the workspace: the paused
`AgentRunner` blocks in `wait_for_operator_message/5` still holding its live
`app_session` (the symphony/`claude-app-server` connection) and the on-disk
workspace; `CodingAgent.stop_session/1` is only called on turn completion
(`agent_runner.ex:371`), never on the pause path. If we merely paused and then
launched `claude remote-control` in the same workspace, two live Claude processes
would share the same git tree and the same `~/.claude/projects/<slug>/` transcript
dir — exactly the conflict this design exists to avoid. Therefore:

- **on**: **stop** the agent's session (`CodingAgent.stop_session` + terminate the
  `AgentRunner`, freeing the `app_session` and workspace), then launch a per-agent
  `claude remote-control` server in the agent's workspace.
- **off**: stop that RC server, then **re-dispatch** the agent fresh — it resumes
  against the (possibly RC-advanced) git workspace state, seeded with a resume
  pre-prompt (symmetric to the handoff-in pre-prompt; see Context handoff strategy).

This means `r` (RC) and `Space` (pause) are mutually aware: an RC-on agent is, from
aiur's perspective, **stopped-and-handed-off** (not merely paused). Autonomous
control-status transitions must respect this — see U3.

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
- Parse the session URL from the RC output. **Hypothesized** TUI line (confirm exact
  format in the U2 spike — see Deferred to implementation): `Continue coding in the
  Claude mobile app or https://claude.ai/code/session_…`. Read it from stdout-via-pty or
  the `--debug-file` (`[bridge:init] Registered`), whichever proves stable. Expose
  `session_url` once known. Treat the URL as a **capability token** (see Risks): it
  grants `bypassPermissions` control to anyone who holds it — keep it out of shared logs;
  write `--debug-file` to an agent-private path (mode 0700, not inside the workspace) and
  delete it on teardown.
- `stop/1` terminates the port/process group; ensure no orphan (port `:exit_status`,
  monitor, kill process group on teardown — the agent runner already scrubs
  `ERL_AFLAGS` etc., follow that).
- **Trust pre-seed:** before launch, ensure the workspace project has
  `hasTrustDialogAccepted: true`. Investigate the narrowest mechanism (settings flag /
  env) first; fall back to an atomic, backup-guarded edit of `~/.claude.json` for that
  one project key. Isolate this in a small `ensure_workspace_trusted/1` function so the
  hack is contained and testable. **Concurrency:** the read-modify-write of
  `~/.claude.json` must run synchronously inside the Orchestrator GenServer's
  `handle_call` (which already serializes `set_remote_control`), so simultaneous toggles
  across agents can't clobber each other's keys. Do not move the edit to an async Task.
- **Handoff builder:** `build_handoff/1` returns the handoff pre-prompt text — opening
  with the handoff explanation, then task/conversation context, then the aiur
  system/shared prompt (extracted from the transcript; fall back to aiur's known shared
  prompt only if absent). Keep it mechanism-independent from delivery (see Context
  handoff strategy + the pre-prompt-injection unknown in Deferred to implementation).
  - **Transcript resolution (must be explicit):** aiur's stored `session_id` is the
    synthetic `"#{thread_id}-#{turn_id}"` (`Aiur.Claude.CodingAgent`), which is **not**
    the UUID in the `.jsonl` filename. The project dir
    `~/.claude/projects/<workspace-slug>/` accumulates one `<uuid>.jsonl` per run. Select
    the right transcript by: most-recently-modified `.jsonl` whose `cwd` field matches the
    agent's workspace. Fallbacks: no `.jsonl` yet (fresh agent) → handoff with task
    context only; multiple stale matches → newest by mtime. Also verify the
    `<workspace-slug>` derivation rule against a real `~/.claude/projects/` dir during the
    U2 spike (don't guess the slug format).
  - **Untrusted content:** transcript text may contain issue-sourced prompt-injection.
    Reuse the existing sanitizer/CODEOWNERS trust model (`sanitizer.ex`,
    `issue_log.ex`); include untrusted content only as clearly-delimited data, never as
    instructions in the pre-prompt. Add a fixture test with an injection string.
- **Local-only gate (v1):** RC spawns a *local* `claude remote-control` and
  `build_handoff/1` reads a *local* `.jsonl`. Agents dispatched to a remote
  `worker_host` (over SSH) have neither locally. Gate RC capability on
  `worker_host == nil` for v1; remotely-dispatched agents ignore `r` (no-op + hint).
**Test scenarios:**
- start/stop lifecycle returns `{:ok, %{server_pid, …}}` / `:ok`; double-stop is a
  no-op.
- session URL is extracted from a captured sample line (test against a fixture string,
  not a live server).
- `ensure_workspace_trusted/1` sets the key when absent and is idempotent when present
  (test against a temp JSON file, not the real `~/.claude.json`).
- `build_handoff/1` against a fixture `.jsonl` surfaces the task context and the
  system/shared prompt, and leads with the handoff explanation.
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
  `pause_agent` shape; handle `{:set_remote_control, id, on?}` in the GenServer
  (synchronous `handle_call`, which serializes the trust-file edit — see U2).
- on→true: **stop** the agent's session (`CodingAgent.stop_session` + bring down the
  `AgentRunner`, freeing the `app_session` + workspace — *not* the pause path, which
  leaves the session alive; see "core architectural fact"), then
  `Aiur.Claude.RemoteControl.start/1` for that workspace; store
  `remote_control: %{status: :launching → :on | :failed, session_url, server_pid, ref}`
  on the running entry; broadcast a running-summary update so the list shows the
  launching/on indicator.
- on→false: `RemoteControl.stop/1`, clear RC state, **re-dispatch** the agent fresh
  against the current git workspace state (seeded with the resume pre-prompt),
  broadcast update.
- Guard: reject if backend `remote_control?/1` is false (`{:error, :unsupported}`),
  agent runs on a remote `worker_host` (`{:error, :remote_unsupported}` — v1 local-only),
  or agent not running (`{:error, :not_running}`).
- **Autonomous-transition guards (verified gap):** the orchestrator auto-flips control
  status from several paths — `maybe_resume_blockees_on_push`,
  `reconcile_pending_auto_resumes`, label-flip reactivation, and the stall watchdog.
  Each MUST short-circuit when `remote_control.status` is `:launching`/`:on`, or
  autonomous driving could resume/restart an agent out from under the operator
  mid-conversation (the dual-driver collision this design forbids).
- **Teardown coupling:** on agent/RC `:DOWN`, terminal issue state, or RC self-exit
  (operator closes the mobile session — the port `:exit_status`/monitor fires), stop the
  RC server and clear RC state; on self-exit, also decide whether to auto-resume
  autonomous driving or wait for explicit `r`-off (default: clear 📱, leave stopped,
  surface a hint). **Crash/restart cleanup:** the Orchestrator has **no `terminate/2`
  and does not trap exits**, so `terminate/2` will not fire on `Ctrl-C`/SIGKILL/crash.
  Supervise RC servers under a dedicated `DynamicSupervisor` (tree teardown handles clean
  shutdown) **and** add a startup reconciliation (mirror `run_terminal_workspace_cleanup`)
  that finds and kills stray `claude remote-control` processes by a known marker arg — so
  a crashed aiur leaves no orphan server or dangling api.anthropic.com session.
- Surface RC capability/status via the existing `control_capabilities/2` and the
  running snapshot that feeds `AgentPubSub`.
**Test scenarios:**
- set on for a local claude agent → entry gains `remote_control.status == :on`, agent
  session stopped, start invoked (RC module stubbed/mocked at the boundary).
- set on for a codex agent → `{:error, :unsupported}`, no state change.
- set on for a remote-`worker_host` agent → `{:error, :remote_unsupported}`.
- set off → RC stopped, agent re-dispatched.
- agent/RC `:DOWN` while RC on → RC stop invoked, entry cleaned.
- auto-resume-on-push / stall-watchdog while RC on → no resume/restart (guard holds).
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
non-claude, remote-`worker_host`, or non-running agent is a no-op that **surfaces a
status-bar hint** (e.g. "Remote Control requires a local Claude agent") — pick the
hint, not a silent no-op or a bare bell, so the operator isn't left guessing.
**`Space` while RC-on** is likewise a no-op with a status-bar hint ("Agent is in
Remote Control — press `r` to return"), since RC-on already implies stopped-and-handed-off.
**Test scenarios:**
- `r` on selected running local claude agent calls `Orchestrator.set_remote_control(id,
  true)`; pressing again calls it with `false` (toggle semantics off the summary's RC
  status).
- `r` on a codex / remote / no-selection agent → no call, hint surfaced.
- `Space` on an RC-on agent → no pause call, hint surfaced.
- summary carrying `remote_control.status == :on` is retained through a render cycle
  (guards the `Map.take` footgun).
**Verification:** tests green.

### U5 — Renderer: 📱 indicator

**Goal:** Show the RC status next to the identifier, including the transient launch
state, and surface the session URL.
**Files:**
- Modify: `src/lib/aiur/agent_list/renderer.ex`
- Test: `src/test/aiur/agent_list/renderer_test.exs`
**Approach:** In the agent-row build, render by `summary.remote_control.status`:
`:launching` → a muted glyph (e.g. `[rc…]`) so `r` gives immediate feedback before the
URL is confirmed (RC registration is a network round-trip, ~seconds); `:on` → 📱
adjacent to the id; `:failed` → a transient error marker; `:off`/absent → nothing.
**Reserve a fixed indicator column** (constant width regardless of emoji presence) so
emoji cell-width variation across terminals can't shift alignment. **Session URL
display:** when an RC-on agent is selected, show its `session_url` on the footer/hint
line (cheapest affordance — one conditional line; the URL is the actionable output of
the feature). This URL is a capability token — it's shown to the local operator only,
never logged.
**Test scenarios:**
- `:on` row includes 📱 adjacent to the id; `:launching` shows the launch glyph;
  `:failed` shows the error marker; `:off` shows none.
- column alignment unbroken across all statuses (assert fixed indicator width / no crash).
- selecting an RC-on agent renders its session URL on the footer line.
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

**v1 is intentionally one-directional in conversation terms.** The strong experience
is "take the wheel from my phone." Handing the *conversation* back so aiur continues
exactly where the operator left off would need the symphony **`claude-app-server`**
(the operator's `~/github/claude-app-server`, repo `its-everdred/claude-app-server`) to
`--resume` the RC-advanced session id — deferred. v1 instead **re-dispatches** the
agent fresh against the (possibly RC-advanced) **git workspace state**. Because the
resumed agent's transcript has no record of what the operator did in the RC session, it
would otherwise be surprised by unexplained diffs; so on RC-off aiur seeds a **resume
pre-prompt** (symmetric to the handoff-in pre-prompt) summarizing that an operator
session edited the workspace, so the agent reconciles git state instead of being
confused by it. Deep conversation-merge remains a named follow-up against the symphony
repo, not an implicit "if it proves poor" afterthought.

## Context handoff strategy (decided)

RC can't be launched with `--resume`, so the fresh RC session starts without aiur's
in-flight conversation. The goal is that the operator does **not** have to manually
`/resume` — the handoff is generated automatically from the in-folder session logs.

**Gating reality check (resolve in the U2 spike before building the rest):** whether a
generated pre-prompt can be *delivered as a spoken first turn* is unverified — RC has no
`--prompt`/`--resume`/`--session-id` flag (see Deferred to implementation). The
`build_handoff/1` builder is worth writing regardless (it's delivery-independent), but
the **success criterion must match the confirmed delivery mechanism**: if the spike
finds an auto-seed path, v1 ships the fully-automatic spoken handoff; if not, v1 ships
the handoff as a primed workspace context file (e.g. `CLAUDE.md`) the RC session picks
up as context — still automatic to *produce*, but the operator's first message leans on
it rather than the agent speaking first. Decide which before finishing U2/U3; do not
let the "fully automatic spoken first turn" claim stay load-bearing if unconfirmed.

**Auto-generated handoff pre-prompt from the shared session logs.** The agent's own
session transcript lives in the workspace project dir:
`~/.claude/projects/<workspace-slug>/<uuid>.jsonl` (transcript-resolution rule and
slug-verification in U2). On RC toggle-on, aiur reads that `.jsonl` and synthesizes a
cohesive handoff delivered via the mechanism the spike confirms. The pre-prompt:

- Opens by explaining the handoff itself — that this session is taking over a task aiur
  was driving autonomously, and the operator is now at the wheel.
- Includes the task/issue context and a summary of the conversation-so-far reconstructed
  from the `.jsonl`.
- **Includes any aiur pre-prompts / shared system prompts** the autonomous agent was
  running under. Theoretically these already appear in the session `.jsonl` (system /
  first-turn messages), so prefer extracting them from the transcript; only fall back to
  re-injecting aiur's known shared prompt if the transcript doesn't carry it.

This leverages the same-workspace logs directly and has no dependency on RC resume
support. Build it as a small function (`Aiur.Claude.RemoteControl.build_handoff/1`)
that reads the session `.jsonl` from the project dir and returns the pre-prompt text;
the RC server is then launched seeded with that pre-prompt. Test the builder against a
fixture transcript (assert it surfaces task context + the system/shared prompt).

**Deferred:** pinning a known `--session-id` per agent for stable session identity is a
later symphony-side investigation, not needed for v1.

## Deferred to implementation

- **Pre-prompt injection mechanism (must verify early).** RC's CLI surface has no
  `--prompt`/`--resume`/`--session-id`, so there's no obvious flag to seed the opening
  message. Resolve during U2 by spiking, in priority order: (a) a workspace file the RC
  session reads on start (e.g. `CLAUDE.md` / a handoff note in the project dir the agent
  picks up as context); (b) an undocumented prompt/seed flag or stdin on
  `claude remote-control`; (c) writing the handoff into the session `.jsonl` the RC
  session attaches to. If none cleanly seeds a *spoken* first turn, fall back to writing
  the handoff as a workspace context file the operator's first message can lean on. The
  builder (`build_handoff/1`) is mechanism-independent; only the delivery binding changes.
- Exact session-URL parse: confirm the live TUI line format and whether to read it
  from stdout-via-pty or the `--debug-file` (`[bridge:work] … session`). Pick whichever
  is stable.
- Whether to surface the session URL in the TUI (e.g. a footer hint) or just 📱. Start
  with 📱; add URL display only if cheap.
- Trust pre-seed mechanism: prefer a non-`~/.claude.json` lever if one exists.

## Scope boundaries (non-goals)

- Codex remote connections.
- **Remote-`worker_host` agents** — RC is local-only in v1 (the RC server and session
  `.jsonl` are local; SSH-dispatched agents are gated out). Generalize later.
- **Conversation-level handback** — v1 hands the *wheel* off and re-dispatches against
  git state on return; it does not resume the RC-advanced conversation thread.
- LiveView dashboard + JSON API parity (CLI-first; mirror later for agent-native
  parity).
- Multi-agent shared RC server (`--spawn worktree --capacity N`).

## Risks / watch-list

- **Orphan RC servers / dangling registered sessions** if teardown misses a path
  (agent crash, aiur restart). `terminate/2` won't fire on SIGKILL/crash → use a
  `DynamicSupervisor` + startup reconciliation that kills stray `claude remote-control`
  processes (U3). Note: a registered api.anthropic.com session may outlive the local
  process — confirm its TTL/deregistration in the spike; treat the leftover session URL
  as a live credential until it expires.
- **Session URL is a capability token.** With `bypassPermissions`, whoever holds the
  `claude.ai/code/session_…` URL gets unrestricted code execution on the host. The URL
  is the only auth boundary → operator-local display only, never in logs or the
  `--debug-file` (agent-private path, deleted on teardown). Confirm `r`/the TUI isn't
  reachable by other tmux/SSH users who could grab the URL.
- **Permission mode**: `bypassPermissions` is the default to match aiur's headless
  autonomy, so the operator isn't blocked on approvals from their phone. This is a
  deliberate trust posture, not an inherited setting; revisit `acceptEdits` (phone-side
  approvals) if the "take the wheel to fix a problem" case wants a safety net.
- **Trust pre-seed clobbering `~/.claude.json`** (66KB, concurrently written by a live
  claude). Atomic write + backup, single-key edit, serialized in the GenServer
  `handle_call` (U2); prefer a cleaner non-`~/.claude.json` lever if the spike finds one
  — every claude release can reshape this private file, so the edit is a standing
  version coupling taken on knowingly.
- **Prompt-injection via transcript**: issue-sourced text in the `.jsonl` is re-injected
  into the handoff; sanitize / delimit as data (U2).
- **Emoji width** breaking TUI column alignment → fixed-width indicator column (U5).
- **RC self-exit**: operator closing the mobile session ends the RC server; teardown
  must clear 📱 and not leave the agent stuck (U3).

## Success criteria

- `r` on a running **local** Claude agent → its session is stopped, an RC session
  appears in claude.ai/code + mobile, the row shows launching→📱; operator messages the
  agent and gets a response.
- Handoff context reaches the RC session via the spike-confirmed mechanism (spoken
  first turn if available, else a primed workspace context file).
- `r` again → 📱 gone, RC session torn down, agent re-dispatched against current git
  state (seeded with the resume pre-prompt); no orphan server, no dangling session.
- Correct across termination, `Space`/`r` interaction, autonomous auto-resume/stall
  paths, RC self-exit, and aiur restart (startup reconciliation kills strays).
- `r` on codex / remote-`worker_host` / non-running agents → no-op with a hint.
- `mix format`, `mix compile --warnings-as-errors`, test suite green.
