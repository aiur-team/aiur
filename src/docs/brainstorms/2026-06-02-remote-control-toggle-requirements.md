# Requirements: per-agent Remote Control toggle (Claude `/remote-control`)

Created: 2026-06-02
Branch: `kevin/remotecontrol`

## Problem

Aiur drives Claude agents autonomously through a headless turn loop:

```
aiur → aiur-claude → symphony-claude app-server → spawns `claude --print --output-format stream-json` (headless), one process per turn
```

The operator wants any running agent to be controllable from the **native Claude
app** (claude.ai/code + mobile) via Claude Code's Remote Control feature: watch,
message, and steer an agent from a phone, then hand it back to aiur's autonomous
driving.

These are two different execution models. Headless `claude --print` sessions are
**not** RC-visible (a known Claude Code gap). Remote Control is a persistent
`claude remote-control` server whose sessions are driven interactively from the
Claude app. You cannot make a single session both headless-driven by aiur **and**
RC-controlled at the same time.

## Goal / End State

A **per-agent runtime toggle**, with no config surface:

- In the agent-list TUI, pressing **`r`** on the selected agent toggles Remote
  Control on/off for that agent, at any time.
- When RC is on, a **📱 indicator** appears next to the agent's identifier in the
  list.
- Toggling **on** suspends aiur's autonomous driving of that agent and brings up a
  `claude remote-control` session in the agent's workspace, so the agent appears in
  the operator's Claude app and they drive it from there.
- Toggling **off** tears down the RC session and resumes aiur's autonomous driving,
  ideally continuing from where the RC session left the work.

Mental model: `r` is "**take the wheel from my phone**" / "**give the wheel back to
aiur**" for one agent. It is a sibling to the existing `Space` = pause/resume.

## Verified facts (spike, 2026-06-02)

- **RC works with the existing OAuth subscription login.** No `ANTHROPIC_API_KEY`
  set (RC requires OAuth, not an API key). `claude` v2.1.149.
- `claude remote-control --spawn session --name <n> --permission-mode bypassPermissions`
  registered with `api.anthropic.com`, got an `environmentId`, started an outbound
  poll loop, and produced a live session URL
  (`https://claude.ai/code/session_…`) — "Continue coding in the Claude mobile app".
  This is exactly the visible-in-app outcome.
- **`bypassPermissions` is an allowed RC `--permission-mode`** (contradicts a common
  web claim that permission-skipping is blocked under RC).
- **Workspace trust gates RC.** RC refuses to start in an untrusted dir
  (`hasTrustDialogAccepted` per-project in `~/.claude.json` — `false` even for
  existing aiur workspaces; the headless `--print` path bypasses the dialog, RC does
  not). The spike had to set `hasTrustDialogAccepted: true` for the workspace first.
- **`claude remote-control` has no `--resume`/`--continue`/`--session-id`.** It only
  takes `--name`, `--spawn`, `--permission-mode`, `--capacity`,
  `--[no-]create-session-in-dir`. `--spawn session` creates a **fresh** session.
- **Headless/interactive `claude` is session-rich:** `--session-id <uuid>`,
  `-r/--resume [id]`, `-c/--continue`, `--fork-session`. Sessions persist to
  `~/.claude/projects/<dir-slug>/<uuid>.jsonl`, **directory-scoped and shared** across
  headless and RC invocations in the same dir.

## Decisions

1. **No `.aiurconfig` surface.** RC is a pure per-agent runtime toggle. (Supersedes
   an earlier idea of an `.aiurconfig remote_control: true` flag.)
2. **Toggle key = `r`** in `Aiur.AgentList.Input` (`dispatch("r", …) → App.toggle_remote_control/1`),
   mirroring `Space → toggle_pause`. 📱 rendered in the agent row.
3. **On-toggle lifecycle:** toggle-on = cooperatively pause the autonomous agent at a
   safe checkpoint (reuse existing pause path), then launch a `claude remote-control`
   server scoped to that agent's workspace. Toggle-off = stop that RC server and
   resume the autonomous agent.
4. **Workspace trust must be pre-seeded** for the agent's workspace before launching
   RC (set `hasTrustDialogAccepted: true` for that project path). Do this through the
   narrowest mechanism that works; treat editing `~/.claude.json` as a fallback if no
   cleaner flag/env exists. (Planning-time investigation.)
5. **Permission mode** for RC sessions should match how aiur runs the agent
   (`bypassPermissions`) so the remote operator isn't blocked on approvals — unless we
   deliberately want approvals surfaced on the phone. Default: `bypassPermissions`.
6. **State lives on the agent.** RC on/off is per-agent state tracked by the
   Orchestrator (the owner of `state.running`), surfaced to the agent list the same
   way pause state is. New `App` state fields must thread through `render/1`'s
   `Map.take/put` pipeline (known footgun).

## Open questions (resolve in planning / spike, not blocking the shape)

- **Context handoff fidelity.** Can the fresh RC session continue aiur's in-flight
  conversation? Since RC can't be launched with `--resume`, options are:
  (a) the operator `/resume`s the agent's session from the phone (same shared
  workspace project dir) — needs verification that RC's interactive surface exposes
  resume; (b) **primer-file fallback**: aiur writes the issue/task context (and the
  agent's transcript-so-far summary) into the workspace so the operator picks up with
  full context even though the conversation forks. Plan must pick a default and keep
  the fallback.
- **Handoff back to autonomous.** After RC, the work tree and the Claude session have
  advanced. Resuming autonomous driving cleanly likely needs the symphony app-server
  to `--resume` the session id RC used (or to re-sync from the workspace git state).
  May require a change in the `claude-app-server` (symphony) repo, which the operator
  owns. **Cross-repo dependency — flag explicitly.**
- **One RC server per agent vs. one shared server.** `claude remote-control` is itself
  a multi-session server (`--spawn worktree --capacity N`). Per-agent single-session
  servers are simplest to reason about for an on/off toggle; a shared server is more
  efficient but couples agent lifecycles. Default: **per-agent single-session server**,
  revisit if process overhead bites.
- **Lifecycle coupling with pause/resume and termination.** What happens to the RC
  server if the agent finishes, errors, or the issue reaches terminal state while RC
  is on? Must tear down the RC server and its registered session. What does `Space`
  (pause) mean while RC is on? Likely: `r` and `Space` are mutually-aware — entering
  RC implies paused-from-aiur's-perspective.
- **Codex equivalent.** Codex has "remote connections" but it's API-key-gated and
  thinly documented. **Out of scope for v1** unless the Claude path generalizes
  cleanly; the toggle is Claude-only to start, and the list indicator/route should be
  backend-aware so Codex can be added later without reshaping the UI.

## Scope / Blast radius

In scope (v1, Claude only):
- `Aiur.AgentList.Input` — `r` key dispatch.
- `Aiur.AgentList.App` — `toggle_remote_control/1`, per-agent RC state, render
  threading for the 📱 indicator.
- `Aiur.AgentList.Renderer` — 📱 next to the identifier for RC-on agents.
- `Aiur.Orchestrator` — own per-agent RC state; start/stop the RC server; coordinate
  with pause/resume; tear down on terminal state.
- A new module owning the `claude remote-control` server process per agent
  (spawn via Port/`System`, monitor, stop) + workspace-trust pre-seed.
- Tests for the toggle, state threading, lifecycle teardown.
- Docs: `src/README.md` agent-list key table (`r` = remote control), `AGENTS.md`.

Out of scope / deferred:
- Codex remote connections.
- LiveView dashboard parity for the toggle (CLI-first; mirror later — but agent-native
  parity means the dashboard and JSON API should expose it eventually).
- Deep transcript-merge between RC and autonomous sessions (start with primer-file or
  shared-session-dir resume).

## Success criteria

- Pressing `r` on a running Claude agent brings it up in the operator's Claude app
  (a session appears in claude.ai/code + mobile) and shows 📱 in the agent list.
- The operator can send a message from the Claude app and get a response from that
  agent (the "positive response back from Claude" acceptance the operator named).
- Pressing `r` again removes 📱, tears down the RC session, and aiur resumes driving
  the agent without orphaning the RC server or the registered session.
- RC state is correct across agent termination, pause/resume interaction, and aiur
  restart (no zombie RC servers, no stuck 📱).
- Build is green: `mix format`, `mix compile --warnings-as-errors`, test suite.
