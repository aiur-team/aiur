# Operating Notes

Context for engineers and coding agents working in this repository. Setup
lives in [`src/README.md`](src/README.md); this file captures the
operational practices that aren't in the main README.

Engineering norms (code structure, testing, error handling, and the CI gate)
live in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Orientation

Aiur's intended operating modes are documented in
[`src/README.md § Who operates a run`](src/README.md#who-operates-a-run). In short: every
run has an **Executor** — the operator of the run — and that is either the human driving the
CLI directly, or the human's coding agent operating Aiur on their behalf while they stay in
conversation with it. Both are first-class.

The Executor skills live at [`.claude/skills/aiur-run`](.claude/skills/aiur-run/SKILL.md)
(operate a run end to end) and
[`.claude/skills/aiur-monitor`](.claude/skills/aiur-monitor/SKILL.md) (status and alert
feed). [`.claude/skills/aiur-intro`](.claude/skills/aiur-intro/SKILL.md) answers "what is
Aiur / how do I install it" and routes a new user to a mode.
[`.claude/skills/aiur-agent`](.claude/skills/aiur-agent/SKILL.md) is the manual for an
agent working a ticket *inside* a run — a different job from operating one.

If you are evaluating Aiur rather than working in it, read the operating modes before
forming a verdict; the feature list does not imply them.

## Docs ship with the change

User-facing documentation lives in `website/docs-app/`. A change carries its docs
**in the same pull request** when it:

- adds or changes a **config key** (`.aiur/config` or
  `Aiur.Config.Schema.*`) — including the annotated templates in
  `.aiur/examples/` and `src/examples/workflows/`
- adds or changes a **CLI command or flag** (`aiur`, `aiurdev`, or the shared
  launcher engine)
- adds or changes an **environment variable an operator would set** — the `Auth`
  section of this file, plus the page owning the surface it configures
- adds a **new user-facing surface** — a dashboard page, a TUI view, a Stream
  Deck mode, a new panel
- **changes documented behavior**, so a page that exists today is now wrong

Docs are **not** required for internal refactors, bug fixes that restore
already-documented behavior, test-only changes, or performance work with no
interface change. Do not pad a small change with prose.

**Prefer editing an existing page over adding a new one.** Concise and correct
beats comprehensive: a wrong doc is worse than a missing one, so fix every page
the change falsifies before writing anything new.

### Where each thing is documented

| Change | Page |
|--------|------|
| Config key | `website/docs-app/reference/configuration.md` (one entry per key, defaults included) |
| CLI command or flag | `website/docs-app/reference/cli.md` |
| Dashboard, TUI, Stream Deck, quick start | `website/docs-app/guide/` |
| Model or behavior explanation | `website/docs-app/concepts/` |
| Skills | `website/docs-app/skills.md` |

A genuinely new page must also be added to the sidebar in
`website/docs-app/.vitepress/config.ts`, or nobody can reach it.

Only one row above is machine-checked. `scripts/check-config-docs.py` resolves
every config key to its full dotted path and fails the required `lint` job when
one is missing from the configuration reference; `scripts/test-check-config-docs.sh`
guards that checker. **Every other row is enforced by review alone** — nothing
will stop a CLI flag or a dashboard page from merging undocumented, so a
reviewer treating a missing doc as a blocking finding is the only mechanism
there is.

## Layout

- `.aiur/` — the Aiur config folder: `.aiur/config` (pure YAML), `.aiur/hooks`, and
  `.aiur/prompt.md`. The `prompt_file:`/`hooks_file:` keys point at sibling files
  resolved relative to the config. Run `aiur init` to scaffold these three. This repo also tracks
  `.aiur/examples/*.example` — the annotated templates `aiur init` embeds at compile
  time (source-only; not copied into user repos).
  Discovery: `./.aiur/config` → `~/.aiur/config`. A legacy `.aiurconfig` without
  its canonical replacement is rejected with an actionable error.
- `src/examples/workflows/` — portable example configs (Linear+Codex,
  GitHub+Codex, GitHub+Claude), each a `.yaml` config plus a `.prompt.md`
  template. Copy a pair when starting fresh.
- `.aiur/config` + `.aiur/prompt.md` — the operational config this repo dogfoods.
  Checked in but **not** portable defaults. Used when you run `aiur` or `aiurdev`
  inside this repo.
- `scripts/aiurdev` — the dev shim. It rebuilds the local Elixir release when
  sources are newer than the binary before run/start paths. Pure control
  commands (`agents`, `status`, `set`, `pause`, `resume`, `message`, `stop`) use
  the existing release when it is complete, because they control the already
  running node and a rebuild would not update it. `restart` does the same for
  the opposite reason: it runs its own rebuild *between* its stop and its start
  (through `AIUR_RESTART_BUILD_CMD`), so rebuilding before dispatch would put
  that rewrite back underneath the still-live BEAM. The shim then execs the shared
  launcher engine (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`) with
  `AIUR_RELEASE_DIR` pointed at `src/_build/dev/rel/aiur`. The npm-installed
  product command `aiur` runs the *same* engine against the platform release —
  identical command surface, one source of truth. `aiurdev` and `aiur` share the
  same instance-keyed distribution identity (node
  `aiur-$USER[-KEY]@127.0.0.1`, tmux socket `aiur-$USER[-KEY]`), so there is no
  second command surface to maintain. Run `npm run setup` (or
  `mise run setup`) to install the toolchain and symlink `aiurdev` onto your
  `PATH`. That symlink resolves its target from the script's own path, so
  invoke `scripts/aiurdev` from the checkout you mean to act on. A command that
  would build or boot a *different* checkout than your working directory
  (`build`, `restart`, a bare run) is refused rather than run; a control or RPC
  command still runs but says which checkout it is speaking through and does not
  rebuild it. `AIUR_REPO_ROOT` names a target explicitly when you do want the
  other one. Each dev build stamps its release with the repo root and commit it
  came from (`AIUR_BUILD_STAMP`), and `restart` refuses to start on a release it
  cannot match to the rebuild it just ran.

## Running

`aiurdev` is the entry point for everything. Don't `mise exec -- mix …` by
hand unless something is broken.

```text
aiurdev                       # start foreground, or attach to this checkout's live session
aiurdev --bg                  # detached headless run (no panes; dashboard remains available)
aiurdev --bg --no-dashboard   # lean detached run with no panes or dashboard listener
aiurdev --no-dashboard        # foreground terminal UI without the dashboard listener
aiurdev --max-agents <n>      # override agent.max_concurrent_agents at launch
aiurdev stop                  # stop the session (BEAM + tmux)
aiurdev restart [--no-build]  # stop, rebuild if sources are newer, start again detached
aiurdev status                # report the running session
aiurdev agents                # one line per agent: state + current activity (headless dashboard equivalent)
aiurdev set max-agents <n>    # change the concurrent-agent cap at runtime (no config edit)
aiurdev pause | resume        # pause / resume the workflow
aiurdev --todo <ids...> [--only] # queue tickets; optionally dequeue all other pending tickets
aiurdev init                  # scaffold .aiur/
aiurdev build                 # force-rebuild the local release (shim-only)
aiurdev --host …              # explicitly override configured/default dashboard host
```

Every subcommand except `build` is handled by the shared engine, so the
npm-installed `aiur` accepts the exact same set. When config omits `server.host`,
the engine binds the dashboard on `127.0.0.1` (or the `AIUR_DEFAULT_DASHBOARD_HOST`
override) — there is no automatic Tailscale detection, so set `server.host`
explicitly to serve the dashboard beyond the machine. A configured value wins over
that default; explicit `--host` wins over both.

Claude Remote Control requires the dashboard server's lifecycle-hook endpoint.
Aiur therefore rejects `--no-dashboard` when `agent.remote_control` is enabled
or an `agent.routing` value carries `+remote`; remove `--no-dashboard` or
disable that Remote Control configuration. Runtime Remote Control activation
(including `model:remote` tickets and the live `r` promotion) is also refused
unless the HTTP listener is confirmed bound.

## Per-issue workspaces

Each issue gets an isolated workspace at:

```text
<workspace.root>/<repo>/<issue-id>/
```

where `workspace.root` is the value from the active workflow and `<repo>` is the
sanitized repo segment (GitHub repo name, or Linear `project_slug`) so multiple
repos sharing a root don't collide on issue number. Trackers without a repo
segment (e.g. memory) fall back to `<workspace.root>/<issue-id>/`. The leaf is
still the bare issue id, so `basename "$PWD"` resolves the issue number. Runtime
logs written inside each workspace include:

- `logs/agent.md` — human-readable chat-style transcript of every event
- `logs/agent.ndjson` — newline-delimited JSON event stream. The attentions feed
  (`Aiur.AlertFeed`) reads its `alert` events, and agent crash reasons must
  persist here (#708); don't stop writing it.

Call-correlated completion or failure evidence for asynchronously published
agent events is daemon-owned at `<run-log-root>/log/event-publications.ndjson`.
It must not live under an agent-writable workspace; the offline delivery
collector joins it to the transcript by ticket and tool-call identity.

When resuming an issue that was already in progress, inspect the transcript
logs, daemon publication outcomes, and workpad comment before changing code. Don't
repeat work the previous run already finished.

## Tracker label slugs

The GitHub tracker emits states as label slugs (`todo`, `in-progress`,
`human-review`, `rework`, `merging`, `done`), not their display names.
Configuring `active_states:` with display names (`"In Progress"`) makes
Aiur treat the issue as non-active and stop the worker. Always use the
slug form in workflow YAML.

`agent:paused` is not a tracker active state. It is a suppressing override
label that can coexist with `agent:todo`, `agent:in-progress`,
`agent:rework`, or `agent:merging` so the original state is preserved while
Aiur pauses or skips the ticket. Remove only `agent:paused` to let the
preserved state take effect again.

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
from the environment, and the GitHub tracker reads `GITHUB_TOKEN`. On a run,
credential precedence is: an already-exported environment value, then
`~/.aiur/.env`, then `./.env` in the current repository. Each dotenv file only
fills unset names. The Supervisor Decision API uses `AIUR_SUPERVISOR_TOKEN`;
generate one with `openssl rand -base64 32`. The value must be at least 32
bearer-safe bytes with no surrounding whitespace. An absent or empty value
disables the API, while a present non-empty unusable value aborts startup.
Provider keys use
`MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`,
`OPENROUTER_API_KEY`, and (for the credits meter) `OPENROUTER_MANAGEMENT_KEY`.
Keep the global per-user file outside Git trees and never commit either dotenv
file. `aiur init` also reads `.env` for the GitHub token during setup.

`ERL_CRASH_DUMP` and `ERL_CRASH_DUMP_SECONDS` optionally override the daemon's
durable BEAM dump path and bounded write time. They apply only to the Aiur
daemon: agent and build children have both variables removed from their
environment so they cannot overwrite daemon evidence or inherit its dump
policy.

GitHub tracker auth uses `GITHUB_TOKEN` for polling and `gh auth setup-git`
for git pushes/PRs. Verify with `gh auth status` in the same shell that
will run the agent.

Agent processes do **not** inherit `GITHUB_TOKEN`/`GH_TOKEN`: the daemon
scrubs them from every agent environment and the `gh` guard injects the
credential from a file only for the duration of a governed call (#2356). A
raw `curl` from an agent workspace is unauthenticated, so anything that
speaks HTTP directly is metered by GitHub's anonymous limit, not by Aiur's
guard — the ledger counts governed `gh`/`git` calls, and only those.

**Before changing anything that talks to GitHub — polling, budgets, the read
cache, webhooks, credentials — read
[`website/docs-app/apis/github.md`](website/docs-app/apis/github.md).** It is
the source of truth for how Aiur uses the GitHub API: what it polls and how
often, how the Core/GraphQL budgets are metered and attributed, how to read
`aiur github-cost` without misinterpreting it, which reads the cache refuses on
purpose, the webhook delivery states and how they widen polling, and the
Cloudflare tunnel boundary that keeps the dashboard off the public internet.

Keep that page current when you change the behaviour it describes, and link to
it rather than restating it — a second copy is a copy that goes stale. A run in
2026-08 spent a day planning around webhook ingress it believed was missing and
a reconciliation gap it read as a leak; that page already documented both.

## Compound Engineering

Repo-local CE settings live at `.compound-engineering/config.local.yaml`
(gitignored). The committed example is `config.local.example.yaml`. Aiur vendors
its pinned Compound Engineering skills into this repository and dispatched
workspaces; run `/ce-setup` to check project settings and optional supporting
CLI tools.

## Local notes

`AGENTS.local.md` is gitignored. Use it for per-machine runbook notes,
operational reminders, secrets-adjacent shorthand — anything that shouldn't
be in version control.

Do not commit:

- secrets, tokens, or basic-auth credentials
- per-machine paths, Tailscale IPs, or hostnames in this file
- credentials embedded in YAML or log output

## Tests must fail without the production change they guard

**A test that passes with your production change reverted is not coverage.**
It asserts behavior that was already true, so it passes against the trivially
wrong implementation and reports nothing. Before opening a PR, for each test
you added: undo the production hunk it is meant to guard, run that test, and
confirm it **fails**; restore the hunk and re-run — it must pass. If it still
passes with the change reverted, the test is asserting something the code
already did — fix it to assert the specific behavior the change adds, or
delete it. If you cannot revert cleanly, say so in the PR body rather than
skipping the check.

Name the result in the PR body: one line per new test ("`sweep_once` test
fails with the production hunk reverted") or an explicit statement of why the
check could not be run.

When you revert for this check, the tree must be dirty **only** in the
intended way: `git diff` shows the production hunk you meant to remove and
nothing else. Run it in a worktree, never the live checkout, and before the
run assert no *unintended* modifications are present (`git status --porcelain`
must show exactly the revert you made and no stray files) — a dirty tree from
another process is the wrong-checkout signature #2362 is about, and HEAD alone
does not catch it. Report the exact command you ran in the PR body so a
reviewer can see what actually executed.

Recurring shapes to avoid — each has shipped and cost a review round:

- `assert %{} = …` and other patterns that match anything. `%{}` matches any
  map, `_` matches anything, `is_binary(x)` proves nothing about a value whose
  *content* is the point, and `f(x) == f(x)` self-comparisons can never fail.
- Asserting a constant the change introduced (`assert {:cache, :issue_graph,
  3_600_000} = ...`) instead of the behavior that produces it — a cache hit,
  a reordered ranking, a persisted effect.
- Asserting a rendered string without asserting the value behind it.
- Fixtures built to avoid the failure mode. If the fixture cannot reach the
  bug, the test cannot either — a broker double that delegates every command
  but the one under test exercises a configuration that cannot exist.
- Reading real state. Any test that touches `~/.aiur`, the live ledger, or a
  shared global path must point at a temp path explicitly. Green in CI and red
  on a live host is worse than red everywhere.
- An unknown or unavailable rendering branch asserted only through its rendered
  string. Any rendering path for `nil`, `unknown`, `stale` or `unavailable`
  needs a test that fails when that path is replaced with a plausible default —
  write the test, then replace the unavailable branch with `0`, `"—"`, or the
  most recent known value, and confirm it fails. If it still passes, it is not
  constraining that branch: check the assertion *and* whether the fixture can
  reach it.

Keeping a test that already passes on `main` is fine when it is deliberately a
guard against a *future* regression — but say so in the test name or a
comment, and do not count it toward covering this change.

The reviewer-side check lives in the `aiur-run` skill ("Mutation-testing
discipline", `.claude/skills/aiur-run/SKILL.md`); this section is the
author-side rule so the check happens before review, not for the first time in
review.

## Computed ages and collapsed causes — author-side checks

Two more dashboard rules recur in review — an age computed but never rendered,
and distinct causes collapsed into one state. (The companion unknown-path
mutation guard is the last bullet in "Tests must fail without the production
change they guard" above.) Run them before opening a PR; the review guidance in
the `aiur-run` skill cross-links here rather than restating them.

1. **If a surface computes an age, it renders the age.** Plumbing a timestamp
   to a presenter and not displaying it is worse than not having it — it looks
   handled in review while the surface keeps claiming freshness. The CLI emits
   `observed_at`, `age_ms` and `freshness`; a web surface that computes the same
   fields must render them, or the two surfaces the docs call equivalent
   disagree about truth.
2. **A collapsed cause names the collapse at the source.** Collapse an unknown
   or heterogeneous cause to a cause-neutral atom at the point of collapse
   (`_ -> :unknown`) — never to a specific cause. `_ -> :upstream` is a
   confident lie when the failure is not upstream: the atom flows verbatim into
   the JSON envelope and the logs whether or not a renderer prints "unknown",
   so a render-side fixup protects none of the consumers. If a specific cause
   *is* known, preserve it separately — a `reasons` list, as `analytics_cli.ex`
   does — so it is carried without ever being mislabeled.

## A claimed saving must be measured

A PR claiming a quota, latency, or cost saving must state, in the PR body:

1. **A number, with units and a baseline** — `X → Y pts/hr`, not "reduces
   cost". A claim with no falsifiable figure cannot be reviewed, verified at
   merge, or re-measured later.
2. **How it was measured — against the running system or a census of real
   data, never derived from the code.** An estimate from the mechanism is a
   prediction, not a saving: the tests pass because they exercise the
   mechanism against a fixture, and the fixture may be a shape production
   never produces. `aiur github-cost` gives per-caller points, calls, and
   rate; the local ledger and the App-token `/rate_limit` give the
   credential-side view. Read
   [`website/docs-app/apis/github.md`](website/docs-app/apis/github.md)
   ("Reading these numbers without fooling yourself") before measuring.
3. **What must be true at merge for the saving to occur.** If the saving needs
   a config change, ship that change in the PR — or say plainly that the
   saving is opt-in and currently zero. A config that ships commented out
   measures zero at merge.
4. **A test asserting the claimed figure**, so the PR body and the test cannot
   diverge. When the figure is a steady-state rate no unit test can assert,
   say so in the PR body and give the measured number instead — but a claim
   with neither a test nor a measurement is not a saving.

The failure this guards is the *inert* PR, not the broken one: the mechanism
is usually correct, and still zero is saved because it never meets the
production data the claim assumed. Three token-cost PRs were reviewed as
significant savings and measured zero for exactly that reason:

- **#2360** claimed the saving from classification alone, which is
  observability — the 5,208 reads/hr were *classified*, not eliminated. It
  only saves reads now because a later revision gave three of the shapes a
  real TTL.
- **#2399** shipped four configs with every `polling.intervals` gate
  commented out, so no gate binds and the cadence never changes.
- **#2417** never fires its cache validator: zero of the 462 cached bodies
  have the shape it looks for.

For reviewers: **check the population, not the mechanism.** Before evaluating
whether a cache, classifier, or cadence change is correct, count what it will
actually see in production. That one question settled all three above without
deep analysis: how many reads does classification remove, how many shipped
configs have the gate uncommented, how many cached bodies have the validator's
shape. The reviewer-side check lives in the `aiur-run` skill
("Saving claims are measured, not estimated", `.claude/skills/aiur-run/SKILL.md`);
this section is the author-side rule so the check happens before review, not
for the first time in review.

## Manual testing — the only definition

When the user (or any doc) says "manually test", "run aiur and try it",
"verify end to end", "see if it works", or anything in that family, the
**only acceptable verification** is to drive the real CLI:

1. **Launch the actual CLI**: `scripts/aiurdev --test --force --allow-remote`
   (or whichever flags the scenario calls for). This must spawn the real
   release binary, the tmux session, opencode-serves, and opencode-attach
   TUI panes — not just the BEAM and not a one-off `mix run`.
2. **Drive the TUI like a user would.** Press keys, open chat panes
   (Enter on an agent row), type messages into the chat input, navigate
   between panes. From a non-TTY environment, use `tmux send-keys`
   on the actual socket/session printed by the launcher — that **is**
   how a user interacts; `setsid` is fine for spawning, but interaction
   must hit the running tmux session, not a separate shell.
3. **Observe what a user actually sees.** Read the rendered chat-pane
   content via `tmux capture-pane -p -t <pane>`. Look for the intended
   UX content: real agent prose, `$ command` lines, `→ tool_call`
   markers, `_reasoning_` text, incoming-event rows, outgoing
   aiur-tool-call rows, etc. — whatever the feature was supposed to
   render.
4. **End-to-end means end-to-end.** Send Executor messages through the
   TUI input box (the path a user takes), not via `curl POST
   /api/v1/<id>/messages`. The HTTP API exercises a small subset of the
   delivery path and routinely behaves differently than the TUI input
   path — verifying the API is verifying the API, not the UX.
5. **Inspecting logs and SSE bridge events is NOT manual testing.**
   Logs prove *that internal events fired*. Manual testing proves
   *that the Executor sees the right thing on screen*. Both are useful;
   only the second satisfies "manually tested".

**Do not report a feature as "working", "verified", or "shipped" until
you have run `aiurdev --test` end to end, opened a chat pane, and observed
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

## Sibling: `aiur-claude`

Claude support is provided by a sibling repository (a Node-based JSON-RPC
2.0 app server that adapts Claude Code to the Codex app-server protocol).
Auth is via the Claude CLI (`claude auth`), not an API key. See that repo's
README for setup details.
