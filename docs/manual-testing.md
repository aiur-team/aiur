# Manual testing recipe

The rules live in [`AGENTS.md`](../AGENTS.md#manual-testing--the-only-definition); this page holds the step-by-step procedure.

### Driving the TUI from a non-TTY agent environment

When a non-TTY Executor environment needs to drive aiur manually, use a
wrapper tmux session as the "fake terminal," then `send-keys` and
`capture-pane` against aiur's own inner tmux socket. This pattern was
validated live and is the canonical recipe — do not substitute HTTP,
curl, mix scripts, or background-mode launches.

Agent issue workspaces are blocked from launching `scripts/aiurdev --test`
or `--test3` directly. Those flags reset pinned GitHub sandbox tickets and
can mutate the live dogfood backlog. If an agent sees the guard message
`manual --test runs are blocked inside agent workspaces`, it must stop that
verification path and report the blocker; it must not retry from `/tmp`, a
copied harness, a fresh clone, or an alternate wrapper-tmux name. Run this
recipe only from the Executor repo root, then use the socket/session printed
by that launched instance.

1. **Spawn aiur inside a wrapper tmux on a separate socket.** The
   wrapper supplies the pty `scripts/aiurdev` needs for its internal
   `tmux attach`. Unset `$TMUX` before launching or aiur refuses to
   nest:

   ```bash
   tmux -L claude-driver new-session -d -s aiur-driver -x 220 -y 60 \
     "bash -c 'unset TMUX; AIUR_DEBUG=1 exec mise exec -- ./scripts/aiurdev --test' 2>&1 \
        | tee /tmp/aiur-driver-startup.log; sleep 3600"
   ```

   The trailing `sleep 3600` keeps the wrapper pane alive after aiur
   exits so post-mortem captures still work.

2. **Read the launched instance identity, then wait for its inner tmux
   session to come up** (sandbox reset + build + boot take ~30-60s).
   The launcher prints a line like `aiur foreground tmux socket
   aiur-kevin-d686b464b0, session aiur-kevin-d686b464b0-default`:

   ```bash
   until grep -q "aiur foreground tmux socket" /tmp/aiur-driver-startup.log
   do sleep 1; done
   AIUR_SOCKET="$(awk '/aiur foreground tmux socket/ {gsub(/,/, "", $5); print $5; exit}' /tmp/aiur-driver-startup.log)"
   AIUR_SESSION="$(awk '/aiur foreground tmux socket/ {print $7; exit}' /tmp/aiur-driver-startup.log)"

   until tmux -L "$AIUR_SOCKET" has-session -t "$AIUR_SESSION" 2>/dev/null
   do sleep 3; done
   ```

3. **Navigate the AgentList.** It lives at inner pane `0.0`. Press
   `Enter` to open the selected agent's chat pane (it appears as
   pane `0.1`, active):

   ```bash
   tmux -L "$AIUR_SOCKET" send-keys -t "$AIUR_SESSION:0.0" Enter
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
   until tmux -L "$AIUR_SOCKET" capture-pane -t "$AIUR_SESSION:0.0" -p \
       | grep -vqE 'Warming up|Starting codex|Queueing agent'; do sleep 5; done
   tmux -L "$AIUR_SOCKET" capture-pane -t "$AIUR_SESSION:0.0" -p -S -40
   ```

   The AgentList **re-sorts live** (running agents bubble to the top),
   so capture `0.0` immediately before `Enter` — the `▶` row is the
   one that opens. Opening `0.1` also shrinks `0.0` (it splits the
   window), so don't be alarmed by the width change.

4. **Type into the chat pane** (the user's input path). Send the
   message text as a single argument, then `Enter` separately:

   ```bash
   tmux -L "$AIUR_SOCKET" send-keys -t "$AIUR_SESSION:0.1" \
     "your Executor message here"
   tmux -L "$AIUR_SOCKET" send-keys -t "$AIUR_SESSION:0.1" Enter
   ```

   Verify it landed by `capture-pane -p` on `0.1` — you should see
   the text followed by `QUEUED` (if the agent is mid-turn) or it
   immediately transitioning to delivered. **`QUEUED` is success, not
   a hang** (validated 2026-05-29): a message sent while the agent is
   mid-turn is held and delivered after the current turn finishes.
   Don't interpret it as a failure and retry.

5. **Capture what the user sees** at any time:

   ```bash
   tmux -L "$AIUR_SOCKET" capture-pane -t "$AIUR_SESSION:0.1" -p -S -200
   ```

6. **Inner pane layout reference** (from `list-panes -a`):
   - `0.0` — AgentList TUI (the user-facing window)
   - `0.1` — chat pane swapped in after Enter on an agent
   - `1.0` — agent list state (hidden background)
   - `1.1`, `1.2`, `1.3` — opencode chat slots (hidden until swapped
     into window 0)

7. **Cleanup**: `mise exec -- ./scripts/aiurdev stop` from a fresh shell
   (it kills both the inner BEAM and tmux session). Then
   `tmux -L claude-driver kill-server`.

Gotchas worth remembering:
- `--bg` mode runs the workflow/agents **headlessly** inside the BEAM: it
  skips the terminal UI tree (no agent-list pane, chat panes, or prewarm
  panes) while keeping the dashboard enabled. Add `--no-dashboard` for the
  lean no-listener background shape; the same flag suppresses only the
  dashboard in foreground mode. The launcher still
  creates one detached tmux session as the BEAM lifetime holder and crash
  cleanup anchor. Observe it with `aiurdev agents` / `aiurdev status` over
  the control RPC. If that tmux session already exists, `--bg` treats a live
  control plane as "already running" and cleans up stale tmux state before a
  restart. For manual testing that needs the interactive TUI (chat panes),
  use foreground `aiurdev --test` instead.
- The wrapper-tmux socket name (e.g. `claude-driver`) is the Executor’s
  choice and must NOT collide with the `AIUR_SOCKET` printed by the
  launched instance.
- `send-keys` accepts both literal strings and tmux key names
  (`Enter`, `Tab`, `Up`, etc.) — pass them as separate arguments.

### Recording chat panes over time — folded into `--debug`

A single `capture-pane` is a snapshot. To watch how a pane evolves —
how the opencode chat renders commands, tool results, and **file-edit
diffs** as an agent works — run `aiurdev --debug`. A debug session
automatically records each `OC | <issue>` chat pane into its own
stitched transcript under the log dir: `log/record/chat.<issue>.ansi`.
The chat panes have no logfile of their own, so this is the only durable
record of how each agent's chat rendered.

How it works, and why it has to:

- **Captures keep ANSI (`capture-pane -e`).** Glamour *consumes* the
  ```` ```diff ```` fence when it renders, so the literal fence string
  **never appears** in pane output. A rendered file-edit diff shows up
  as `@@` hunk headers plus ANSI-colored `+`/`-` lines. **Grep the
  transcript for `@@` (or color codes), not for `` ```diff ``.**
- **It stitches, not dumps.** Each capture is the moving viewport over
  a scrolling log; consecutive captures overlap. The recorder finds the
  largest overlap between the previous frame's tail and the new frame's
  head and appends only the freshly-revealed lines — so the output is a
  continuous transcript, not N redundant screenshots. Unchanged frames
  add nothing.
- **It is read-only and non-intrusive.** Unlike a manual scrollback
  walk, the recorder never sends keys to the panes — it only reads the
  visible viewport — so the Executor’s live session is untouched. It
  starts when the session attaches and is killed the moment the Executor
  detaches.

`cat` a transcript (ANSI intact) or `sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'`
to read plain. This is the supported way to confirm diff/skill/tool
rendering parity between Claude and Codex agents from a non-TTY shell.
