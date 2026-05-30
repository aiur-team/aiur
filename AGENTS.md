# Operating Notes

Context for engineers and coding agents working in this repository. Setup
lives in [`elixir/README.md`](elixir/README.md); this file captures the
operational practices that aren't in the main README.

## Layout

- `elixir/WORKFLOW.md` — generic template. Customize it for the project you
  point Aiur at.
- `elixir/examples/workflows/` — portable example workflows (Linear+Codex,
  GitHub+Codex, GitHub+Claude). Copy one when starting fresh.
- `elixir/local-workflows/` — machine-local operational workflows that are
  checked in but are **not** portable defaults. Used by the built-in `aiur`
  profiles.
- `scripts/aiur` — thin wrapper around `bin/aiur`. Auto-detects OS
  (systemd on Linux, `nohup`+PID on macOS) and rebuilds the escript when
  sources are newer than the binary. See the README for the command surface.

## Running

`aiur` is the entry point for everything. Don't `mise exec -- mix …` by
hand unless something is broken.

```text
aiur                       # default profile, foreground, local-only bind
aiur <profile>             # named profile, foreground
aiur --bg [profile|all]    # background mode
aiur stop [profile|all]    # stop tracked services + foreground processes
aiur build                 # explicit rebuild of bin/aiur
aiur --host …              # opt out of the local-only --host injection
```

`aiur` injects `--host 127.0.0.1` unless you pass `--host` somewhere in
the args. Pass `--host` when you want to expose the dashboard over the
network (e.g. Tailscale, LAN).

## Per-issue workspaces

Each issue gets an isolated workspace at:

```text
<workspace.root>/<issue-id>/
```

where `workspace.root` is the value from the active workflow. Two log files
are written inside each workspace:

- `logs/agent.md` — human-readable chat-style log
- `logs/agent.ndjson` — newline-delimited JSON event stream

When resuming an issue that was already in progress, inspect both logs and
the workpad comment on the issue before changing code. Don't repeat work
the previous run already finished.

## Tracker label slugs

The GitHub tracker emits states as label slugs (`todo`, `in-progress`,
`human-review`, `rework`, `merging`, `done`), not their display names.
Configuring `active_states:` with display names (`"In Progress"`) makes
Aiur treat the issue as non-active and stop the worker. Always use the
slug form in workflow YAML.

## Workflow bootstrap and `.git-writable`

Workflow `after_create` and `before_run` hooks bootstrap the issue
workspace. Two practices that matter:

- **Guard `before_run`** so it reclones only when the workspace is not a
  valid git worktree. Without the guard, every retry wipes the workspace.
- **Prepare `.git-writable`** alongside `.git` so Codex's read-only `.git`
  mount has a writable copy of `FETCH_HEAD` etc. for `git fetch` /
  `git merge` to succeed. See the existing local workflows for the pattern.

Prefer HTTPS remotes over SSH for workflow git operations — SSH agent
forwarding is fragile under service-account contexts and `gh auth setup-git`
makes HTTPS Just Work.

## Auth

The dashboard reads `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`
from the environment. Set them empty (or unset) to disable basic auth
locally. Source these from a gitignored file — `.env`, `.env.local`, or
`~/.config/aiur-dashboard.env` are all loaded automatically by
`scripts/aiur` if present.

GitHub tracker auth uses `GITHUB_TOKEN` for polling and `gh auth setup-git`
for git pushes/PRs. Verify with `gh auth status` in the same shell that
will run the agent.

## Compound Engineering

Repo-local CE settings live at `.compound-engineering/config.local.yaml`
(gitignored). The committed example is `config.local.example.yaml`. Run
`/ce-setup` to install the supporting CLI tools and skills.

## Local notes

`AGENTS.local.md` is gitignored. Use it for per-machine runbook notes,
operational reminders, secrets-adjacent shorthand — anything that shouldn't
be in version control.

Do not commit:

- secrets, tokens, or basic-auth credentials
- per-machine paths, Tailscale IPs, or hostnames in this file
- credentials embedded in YAML or log output

## Manual testing — the only definition

When the user (or any doc) says "manually test", "run aiur and try it",
"verify end to end", "see if it works", or anything in that family, the
**only acceptable verification** is to drive the real CLI:

1. **Launch the actual CLI**: `scripts/aiur --test --force --allow-remote`
   (or whichever flags the scenario calls for). This must spawn the real
   release binary, the tmux session, opencode-serves, and opencode-attach
   TUI panes — not just the BEAM and not a one-off `mix run`.
2. **Drive the TUI like a user would.** Press keys, open chat panes
   (Enter on an agent row), type messages into the chat input, navigate
   between panes. From a non-TTY agent environment, use `tmux send-keys`
   on the live `aiur-orangekid` socket — that **is** how a user
   interacts; `setsid` is fine for spawning, but interaction must hit
   the running tmux session, not a separate shell.
3. **Observe what a user actually sees.** Read the rendered chat-pane
   content via `tmux capture-pane -p -t <pane>`. Look for the intended
   UX content: real agent prose, `$ command` lines, `→ tool_call`
   markers, `_reasoning_` text, incoming-event rows, outgoing
   aiur-tool-call rows, etc. — whatever the feature was supposed to
   render.
4. **End-to-end means end-to-end.** Send operator messages through the
   TUI input box (the path a user takes), not via `curl POST
   /api/v1/<id>/messages`. The HTTP API exercises a small subset of the
   delivery path and routinely behaves differently than the TUI input
   path — verifying the API is verifying the API, not the UX.
5. **Inspecting logs and SSE bridge events is NOT manual testing.**
   Logs prove *that internal events fired*. Manual testing proves
   *that the operator sees the right thing on screen*. Both are useful;
   only the second satisfies "manually tested".

**Do not report a feature as "working", "verified", or "shipped" until
you have run `aiur --test` end to end, opened a chat pane, and observed
the rendered output you'd expect a user to see.** "Tests pass + logs
look right + tmux capture-pane shows a header" is necessary but not
sufficient. Substituting HTTP or log proxies is never acceptable.

> **Read this before you ever type "I can't verify the TUI in this
> non-TTY session."** You can. A coding agent with no real terminal
> drives the full aiur TUI via the wrapper-tmux recipe below — it is
> validated and canonical. "non-TTY" is the *name of the section that
> tells you how*, not a reason to stop. The only honest "I can't" is
> after you have actually run step 1 of that recipe and it failed —
> and then you report the specific failure, not the generic limitation.
> If a compacted summary tells you the TUI is unverifiable solo, that
> summary is wrong; trust this section over it.

### Driving the TUI from a non-TTY agent environment

When a coding agent (no real terminal) needs to drive aiur manually,
use a wrapper tmux session as the agent's "fake terminal," then
`send-keys` and `capture-pane` against aiur's own inner tmux socket.
This pattern was validated live and is the canonical recipe — do not
substitute HTTP, curl, mix scripts, or background-mode launches.

1. **Spawn aiur inside a wrapper tmux on a separate socket.** The
   wrapper supplies the pty `scripts/aiur` needs for its internal
   `tmux attach`. Unset `$TMUX` before launching or aiur refuses to
   nest:

   ```bash
   tmux -L claude-driver new-session -d -s aiur-driver -x 220 -y 60 \
     "bash -c 'unset TMUX; AIUR_DEBUG=1 exec mise exec -- ./scripts/aiur --test' 2>&1 \
        | tee /tmp/aiur-driver-startup.log; sleep 3600"
   ```

   The trailing `sleep 3600` keeps the wrapper pane alive after aiur
   exits so post-mortem captures still work.

2. **Wait for aiur's inner tmux session to come up** (sandbox reset
   + build + boot take ~30-60s):

   ```bash
   until tmux -L aiur-orangekid has-session -t aiur-orangekid-default 2>/dev/null
   do sleep 3; done
   ```

3. **Navigate the AgentList.** It lives at inner pane `0.0`. Press
   `Enter` to open the selected agent's chat pane (it appears as
   pane `0.1`, active):

   ```bash
   tmux -L aiur-orangekid send-keys -t aiur-orangekid-default:0.0 Enter
   ```

   **Precondition (validated 2026-05-29):** `Enter` only swaps in the
   `0.1` chat pane once the selected agent is actually *running*
   (opencode booted). While a row reads `Warming up…`,
   `Starting codex…`, or `Queueing agent…`, pressing `Enter` is a
   no-op — `list-panes -a` still shows only `0.0` and no `0.1`. This
   is the #1 reason an agent wrongly concludes "the TUI doesn't work"
   and bails. Do **not** bail — wait for a running row, then `Enter`.
   Poll for readiness before opening:

   ```bash
   # wait until at least one row has booted past the warm-up glyphs,
   # then capture 0.0 to see which row is selected (▶)
   until tmux -L aiur-orangekid capture-pane -t aiur-orangekid-default:0.0 -p \
       | grep -vqE 'Warming up|Starting codex|Queueing agent'; do sleep 5; done
   tmux -L aiur-orangekid capture-pane -t aiur-orangekid-default:0.0 -p -S -40
   ```

   The AgentList **re-sorts live** (running agents bubble to the top),
   so capture `0.0` immediately before `Enter` — the `▶` row is the
   one that opens. Opening `0.1` also shrinks `0.0` (it splits the
   window), so don't be alarmed by the width change.

4. **Type into the chat pane** (the user's input path). Send the
   message text as a single argument, then `Enter` separately:

   ```bash
   tmux -L aiur-orangekid send-keys -t aiur-orangekid-default:0.1 \
     "your operator message here"
   tmux -L aiur-orangekid send-keys -t aiur-orangekid-default:0.1 Enter
   ```

   Verify it landed by `capture-pane -p` on `0.1` — you should see
   the text followed by `QUEUED` (if the agent is mid-turn) or it
   immediately transitioning to delivered. **`QUEUED` is success, not
   a hang** (validated 2026-05-29): a message sent while the agent is
   mid-turn is held and delivered after the current turn finishes.
   Don't interpret it as a failure and retry.

5. **Capture what the user sees** at any time:

   ```bash
   tmux -L aiur-orangekid capture-pane -t aiur-orangekid-default:0.1 -p -S -200
   ```

6. **Inner pane layout reference** (from `list-panes -a`):
   - `0.0` — AgentList TUI (the user-facing window)
   - `0.1` — chat pane swapped in after Enter on an agent
   - `1.0` — agent list state (hidden background)
   - `1.1`, `1.2`, `1.3` — opencode chat slots (hidden until swapped
     into window 0)

7. **Cleanup**: `mise exec -- ./scripts/aiur stop` from a fresh shell
   (it kills both the inner BEAM and tmux session). Then
   `tmux -L claude-driver kill-server`.

Gotchas worth remembering:
- `--bg` mode does **not** start the workflow/agents (no chat panes,
  no live activity). Always use foreground `aiur --test` for manual
  testing.
- The wrapper-tmux socket name (e.g. `claude-driver`) is the agent's
  choice and must NOT collide with `aiur-orangekid` (aiur's own
  internal socket).
- `send-keys` accepts both literal strings and tmux key names
  (`Enter`, `Tab`, `Up`, etc.) — pass them as separate arguments.

### Recording a chat pane over time — `aiur record`

A single `capture-pane` is a snapshot. To watch how a pane evolves —
how the opencode chat renders commands, tool results, and **file-edit
diffs** as an agent works — use `aiur record <target>`. It is a "log"
for panes that have no logfile: it stitches successive real screen-grabs
into one growing, deduped transcript.

```bash
# follow issue #140's chat for 2 min; transcript printed on stdout
aiur record 140 --for 120
# reconstruct the FULL existing scrollback first, then follow live
aiur record 140 --backfill
# the AgentList event feed instead of a chat slot
aiur record agents --for 60
```

`<target>` is an issue number (resolves the `OC | <issue>` pane), the
word `agents` (AgentList at `0.0`), or an explicit `win.pane`. How it
works, and why it has to:

- **Captures keep ANSI (`capture-pane -e`).** Glamour *consumes* the
  ```` ```diff ```` fence when it renders, so the literal fence string
  **never appears** in pane output. A rendered file-edit diff shows up
  as `@@` hunk headers plus ANSI-colored `+`/`-` lines. **Grep the
  transcript for `@@` (or color codes), not for `` ```diff ``.**
- **It stitches, not dumps.** Each capture is the moving viewport over
  a scrolling log; consecutive captures overlap. `record` finds the
  largest overlap between the previous frame's tail and the new frame's
  head and appends only the freshly-revealed lines — so the output is a
  continuous transcript, not N redundant screenshots. Unchanged frames
  add nothing.
- **`--backfill` reads existing history.** opencode chat panes run on
  tmux's *alternate screen* (`list-panes` reports `history 0`), but the
  TUI keeps its own scrollback. `--backfill` sends `PageUp` to the top,
  then `PageDown`-walks back down stitching each revealed frame, so the
  transcript starts with what's already on screen before following live.
  It leaves the pane scrolled back to the live bottom when done.

Default transcript path is `/tmp/aiur-record/<target>-<timestamp>.ansi`
(override with `--out`); `cat` it (ANSI intact) or `sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'`
to read plain. This is the supported way to confirm diff/skill/tool
rendering parity between Claude and Codex agents from a non-TTY shell.

## Sibling: `aiur-claude`

Claude support is provided by a sibling repository (a Node-based JSON-RPC
2.0 app server that adapts Claude Code to the Codex app-server protocol).
Auth is via the Claude CLI (`claude auth`), not an API key. See that repo's
README for setup details.
