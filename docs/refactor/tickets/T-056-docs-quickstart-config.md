# T-056: Docs: quick-start + configuration reference

**Phase:** 5
**Depends-on:** T-055
**Labels:** `agent:todo` `refactor` `phase:5` `complexity:2`

## Problem / context

T-055 installs the VitePress docs package (per
`docs/refactor/research-docs-framework.md`: a separate package building into
`website/dist/docs`, served at `aiur.team/docs`). That ticket stands up the
package skeleton and its `.vitepress/` config but ships no content pages.
This ticket authors the two foundational content pages: a **quick-start**
(install → `aiur init` → first run → core subcommands) and a complete
**configuration reference** (every `.aiur/config` option).

Both pages are pure documentation. The quick-start's source of truth is the
repo `README.md`, `src/README.md`, and the `FI-CLI` inventory
(`docs/refactor/feature-inventory/cli.md`). The configuration reference's
source of truth is `docs/refactor/feature-inventory/cfg.md` and
`src/lib/aiur/config/schema.ex`. **Accuracy rule (binding): document only
options/commands the inventory + `schema.ex` confirm. Invent nothing** — no
options, defaults, flags, tap names, or install commands that are not present
in those files.

Two facts you MUST honor (verified in-repo, they override any looser wording
in the scope you were handed):

1. The published npm package is **`aiur-cli`**
   (`packaging/npm/aiur-cli/package.json:2`), which provides the `aiur`
   binary (`package.json:11-13`). The install command is therefore
   `npm install -g aiur-cli`, NOT `npm i -g aiur`.
2. Homebrew distribution is **disabled — releases are npm-only**
   (`.claude/skills/release/SKILL.md:10,72-73`: the tap
   `its-everdred/homebrew-aiur` and `HOMEBREW_TAP_TOKEN` are not set up). Do
   NOT document a `brew install` path. It does not work today.

## Scope (exact)

The executor makes ZERO design decisions. Follow these steps verbatim.

1. **Confirm the T-055 package exists.** Verify `website/docs-app/` exists
   with a VitePress config file under `website/docs-app/.vitepress/` (T-055
   created it; the exact extension is `config.mts`, `config.ts`, or
   `config.js` — use whichever T-055 committed). If `website/docs-app/` or
   its `.vitepress/` config is absent, STOP: T-055 has not merged — comment
   the blocker on the issue and end your turn (do not scaffold the package
   yourself; that is T-055's job).

2. **Create the quick-start page** at
   `website/docs-app/guide/quick-start.md`. Use `aiur` (the installed
   product command) throughout — NOT `aiurdev` (that is the local dev shim;
   `src/README.md` uses it only because it documents a repo clone). Write
   these sections, in this order, one short paragraph or code block each:

   1. **Install** — a single fenced `bash` block:
      `npm install -g aiur-cli`. State it requires Node (the marketing
      quickstart pins Node 20; `website/netlify.toml` `NODE_VERSION=20`). Do
      NOT add a Homebrew line (see Problem / context fact 2).
   2. **Initialize** — `aiur init` scaffolds `.aiur/config` (plus
      `.aiur/hooks`, `.aiur/prompt.md`) and writes `./.env` for tokens
      (`FI-CLI-003`); `aiur init --force` overwrites an existing scaffold
      (`FI-CLI-004`). Summarize the wizard's steps from `src/README.md:83-108`
      (tracker, agents & routing, limits, GitHub token, labels) in at most a
      short bullet list. Close with: add `agent:todo` to the issues you want
      worked.
   3. **First run** — bare `aiur` starts a foreground run and discovers
      `.aiur/config` automatically (`FI-CLI-015`, `FI-CLI-005`); `aiur run`
      is the explicit-verb equivalent (`FI-CLI-016`). Do NOT mention or show
      the `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
      flag — the launcher auto-injects it on run paths (`FI-CLI-001`), so
      bare `aiur` is the correct user-facing command.
   4. **Core subcommands** — a markdown table `Command | What it does` with
      EXACTLY these rows, one line each, wording drawn from the cited FI-CLI
      entry:
      - `aiur --bg` — start a headless detached background run
        (`FI-CLI-017`).
      - `aiur status` — table of active agents and their
        running/paused/idle state (`FI-CLI-031`).
      - `aiur agents` — per-agent activity summary with runtime and current
        activity (`FI-CLI-039`).
      - `aiur watch` — live board of tickets, state, and what each agent is
        doing (`FI-CLI-041`).
      - `aiur pause <ids…>` / `aiur pause --all` — cooperatively pause
        agents by issue id (`FI-CLI-035`).
      - `aiur resume <ids…>` / `aiur resume --all` — resume paused agents by
        issue id (`FI-CLI-036`).
      - `aiur stop` — stop this instance's session (BEAM + tmux)
        (`FI-CLI-051`).
      - `aiur --max-agents <n>` — launch-time override of the concurrent-agent
        cap (`FI-CLI-012`).

3. **Create the configuration reference page** at
   `website/docs-app/reference/configuration.md`. Open with one short
   paragraph: config lives in `.aiur/config` (YAML; legacy `.aiurconfig`
   also accepted), `prompt_file:`/`hooks_file:` point at sibling files, path
   values support `~` and `$VAR` — sourced from `src/README.md:110-135,220-241`.
   Then document **every** option below, grouped under the section headings
   listed, as **one markdown table per section** with columns
   `Key | Type | Default | Controls` — one row per key, one line each. Take
   `Type`, `Default`, and the `Controls` phrase from the cited `FI-CFG`
   entry and the `schema.ex` field default (both files are cited in Problem /
   context). Document ONLY these keys (this is the exhaustive, closed list —
   79 keys — do not add or drop any):

   - `## Top-level` — `max_vertical_panes` (FI-CFG-009), `pre_warmed_sessions`
     (FI-CFG-010), `max_log_history_mb` (FI-CFG-011), `prompt_file`
     (FI-CFG-012), `debug` (FI-CFG-014), `hooks_file` (FI-CFG-007, a
     file-pointer key resolved by `Aiur.Workflow`, not in the Ecto schema).
   - `## tracker` — `tracker.kind` (FI-CFG-015), `tracker.base_branch`
     (FI-CFG-018), `tracker.active_states` (FI-CFG-019),
     `tracker.terminal_states` (FI-CFG-020),
     `tracker.github.repo` (FI-CFG-021), `tracker.github.label_prefix`
     (FI-CFG-022), `tracker.github.bot_account` (FI-CFG-023),
     `tracker.github.trusted_accounts` (FI-CFG-024), `tracker.linear.api_key`
     (FI-CFG-025), `tracker.linear.project_slug` (FI-CFG-026),
     `tracker.linear.endpoint` (FI-CFG-027), `tracker.linear.assignee`
     (FI-CFG-028).
   - `## polling` — `polling.interval_seconds` (FI-CFG-030).
   - `## workspace` — `workspace.root` (FI-CFG-035),
     `workspace.bootstrap_image` (FI-CFG-036),
     `workspace.bootstrap_image_pull` (FI-CFG-037).
   - `## worker` — `worker.ssh_hosts` (FI-CFG-038),
     `worker.max_concurrent_agents_per_host` (FI-CFG-039).
   - `## agent` — `agent.kind` (FI-CFG-040), `agent.remote_control`
     (FI-CFG-041), `agent.max_concurrent_agents` (FI-CFG-042),
     `agent.max_concurrent_agents_by_state` (FI-CFG-043), `agent.routing`
     (FI-CFG-045), `agent.complexity_prompts` (FI-CFG-047), `agent.max_turns`
     (FI-CFG-048), `agent.max_retry_attempts` (FI-CFG-049),
     `agent.max_retry_backoff_ms` (FI-CFG-050), `agent.turn_timeout_ms`
     (FI-CFG-051), `agent.stall_timeout_ms` (FI-CFG-052),
     `agent.max_agent_duration_minutes` (FI-CFG-053), `agent.max_load_average`
     (FI-CFG-054), `agent.synthetic_load_process_cap` (FI-CFG-055).
   - `## agent.claude` — `agent.claude.command` (FI-CFG-056),
     `agent.claude.model` (FI-CFG-057), `agent.claude.permission_mode`
     (FI-CFG-058).
   - `## agent.codex` — `agent.codex.command` (FI-CFG-059),
     `agent.codex.approval_policy` (FI-CFG-060), `agent.codex.thread_sandbox`
     (FI-CFG-061), `agent.codex.turn_sandbox_policy` (FI-CFG-062),
     `agent.codex.read_timeout_ms` (FI-CFG-067),
     `agent.codex.thrash_max_per_window` (FI-CFG-068),
     `agent.codex.thrash_window_seconds` (FI-CFG-069).
   - `## hooks` — `hooks.after_create` (FI-CFG-070), `hooks.before_run`
     (FI-CFG-071), `hooks.after_run` (FI-CFG-072), `hooks.before_remove`
     (FI-CFG-073), `hooks.timeout_ms` (FI-CFG-074).
   - `## prewarm` — `prewarm.enabled` (FI-CFG-075), `prewarm.base_build`
     (FI-CFG-076), `prewarm.base_build_file` (FI-CFG-077),
     `prewarm.poll_seconds` (FI-CFG-078).
   - `## pr_watch` — `pr_watch.enabled` (FI-CFG-079), `pr_watch.watch_label`
     (FI-CFG-080), `pr_watch.command_prefix` (FI-CFG-081).
   - `## events` — `events.block_state_debounce_seconds` (FI-CFG-032),
     `events.custom_events_per_turn_max` (FI-CFG-033),
     `events.codeowners_refresh_seconds` (FI-CFG-034).
   - `## alerts` — `alerts.enabled` (FI-CFG-082),
     `alerts.use_os_default_sounds` (FI-CFG-083), `alerts.sound_dir`
     (FI-CFG-084), `alerts.alerts_file` (FI-CFG-085).
   - `## observability` — `observability.dashboard_enabled` (FI-CFG-086),
     `observability.dashboard_writable` (FI-CFG-087), `observability.refresh_ms`
     (FI-CFG-088), `observability.render_interval_ms` (FI-CFG-089).
   - `## server` — `server.port` (FI-CFG-090), `server.host` (FI-CFG-091).
   - `## opencode` — `opencode.command` (FI-CFG-092), `opencode.bridge_port`
     (FI-CFG-093), `opencode.bridge_host` (FI-CFG-094), `opencode.serve_args`
     (FI-CFG-095), `opencode.model_prefix` (FI-CFG-096),
     `opencode.prewarm_disabled` (FI-CFG-097).

4. **Add a final `## Resolution & validation notes` subsection** to the
   configuration page — a short bullet list (one line each) covering the
   behaviors that are NOT standalone keys, sourced from these FI-CFG entries:
   - `prompt_file` unset (or a blank/erroring template) falls back to a
     built-in default prompt (FI-CFG-013).
   - A legacy top-level `linear:` section is merged into `tracker.linear`
     (FI-CFG-017).
   - Only `$VAR` env references resolve; legacy `env:NAME` values are kept
     literal (FI-CFG-029).
   - `polling.interval_ms` is rejected — the loader raises; use
     `interval_seconds` (FI-CFG-031).

5. **Register both pages in the VitePress config** T-055 created under
   `website/docs-app/.vitepress/`. Add a sidebar/nav entry for the
   quick-start (label "Quick start", link `/guide/quick-start`) and the
   configuration reference (label "Configuration", link
   `/reference/configuration`). Match the existing sidebar array shape T-055
   established — do not restructure it, only append these two entries.

6. Run the Agent gate and the docs/website build (Verification section).

## Files

- Create: `website/docs-app/guide/quick-start.md`
- Create: `website/docs-app/reference/configuration.md`
- Modify: the VitePress config file under `website/docs-app/.vitepress/`
  (`config.mts` / `config.ts` / `config.js`, whichever T-055 committed) —
  sidebar/nav entries only.
- Test: None (docs-only; no Elixir modules created — see
  Characterization-tests).

## Out of scope

- Do NOT create or edit any Elixir source under `src/` — this is a
  docs-only ticket. The configuration reference DESCRIBES `schema.ex`; it
  does not change it.
- Do NOT touch the marketing site sources: `website/index.html`,
  `website/src/**` (`dashboard.ts`, `simData.ts`, `terminal.ts`,
  `styles.css`), `website/scripts/**`, `website/public/**`,
  `website/vite.config.ts`, `website/tsconfig.json`, `website/package.json`,
  `website/netlify.toml`. The golden snapshot (`npm run assert`) must stay
  byte-identical.
- Do NOT scaffold, restructure, or re-theme the VitePress package itself
  (its `package.json`, lockfile, theme, or `.vitepress/config` structure) —
  that is T-055. You only add two content pages and append two sidebar
  entries.
- Do NOT document a `brew install` path (npm-only today), do NOT invent a
  `brew tap`/formula name, and do NOT write the guardrails ack flag as a
  user-facing command.
- Do NOT author the concept pages (T-057) or the skills page (T-058) — this
  ticket is only the quick-start and configuration reference.
- Do NOT document config KEYS not in the closed list in Scope step 3, and do
  NOT invent defaults — copy them from the cited `FI-CFG` entry / `schema.ex`
  field.

## Inventory-IDs

Quick-start page (FI-CLI): FI-CLI-001 (guardrails auto-injected — reason the
flag is NOT shown), FI-CLI-003, FI-CLI-004 (`init` / `--force`), FI-CLI-005,
FI-CLI-015, FI-CLI-016 (config discovery / bare run / `run`), FI-CLI-017
(`--bg`), FI-CLI-012 (`--max-agents`), FI-CLI-031 (`status`), FI-CLI-035
(`pause`), FI-CLI-036 (`resume`), FI-CLI-039 (`agents`), FI-CLI-041
(`watch`), FI-CLI-051 (`stop`).

Configuration page (FI-CFG): FI-CFG-007, FI-CFG-009, FI-CFG-010, FI-CFG-011,
FI-CFG-012, FI-CFG-013, FI-CFG-014, FI-CFG-015, FI-CFG-017, FI-CFG-018,
FI-CFG-019, FI-CFG-020, FI-CFG-021, FI-CFG-022, FI-CFG-023, FI-CFG-024,
FI-CFG-025, FI-CFG-026, FI-CFG-027, FI-CFG-028, FI-CFG-029, FI-CFG-030,
FI-CFG-031, FI-CFG-032, FI-CFG-033, FI-CFG-034, FI-CFG-035, FI-CFG-036,
FI-CFG-037, FI-CFG-038, FI-CFG-039, FI-CFG-040, FI-CFG-041, FI-CFG-042,
FI-CFG-043, FI-CFG-045, FI-CFG-047, FI-CFG-048, FI-CFG-049, FI-CFG-050,
FI-CFG-051, FI-CFG-052, FI-CFG-053, FI-CFG-054, FI-CFG-055, FI-CFG-056,
FI-CFG-057, FI-CFG-058, FI-CFG-059, FI-CFG-060, FI-CFG-061, FI-CFG-062,
FI-CFG-067, FI-CFG-068, FI-CFG-069, FI-CFG-070, FI-CFG-071, FI-CFG-072,
FI-CFG-073, FI-CFG-074, FI-CFG-075, FI-CFG-076, FI-CFG-077, FI-CFG-078,
FI-CFG-079, FI-CFG-080, FI-CFG-081, FI-CFG-082, FI-CFG-083, FI-CFG-084,
FI-CFG-085, FI-CFG-086, FI-CFG-087, FI-CFG-088, FI-CFG-089, FI-CFG-090,
FI-CFG-091, FI-CFG-092, FI-CFG-093, FI-CFG-094, FI-CFG-095, FI-CFG-096,
FI-CFG-097.

## Characterization-tests

None. This ticket creates no Elixir modules and changes no runtime behavior
— it authors two Markdown docs pages and appends two VitePress sidebar
entries. The regression suite under `src/test/aiur/regression/` and the
website golden-snapshot suite (`website/scripts/assert-sim.ts`) protect
behavior this ticket does not touch; the guard here is that the docs package
builds cleanly (Verification below). The "tests for every extracted module"
norm is N/A: no modules are extracted.

## Acceptance criteria

- Both pages exist: `website/docs-app/guide/quick-start.md` and
  `website/docs-app/reference/configuration.md`.
- Each new page is <= 200 lines
  (`wc -l website/docs-app/guide/quick-start.md website/docs-app/reference/configuration.md`
  — each count <= 200).
- Quick-start contains the exact install command:
  `grep -F 'npm install -g aiur-cli' website/docs-app/guide/quick-start.md`
  matches.
- Quick-start references each core subcommand:
  `grep -F 'aiur init'`, `grep -F 'aiur run'`, `grep -F 'aiur --bg'`,
  `grep -F 'aiur status'`, `grep -F 'aiur agents'`, `grep -F 'aiur watch'`,
  `grep -F 'aiur pause'`, `grep -F 'aiur resume'`, `grep -F 'aiur stop'`, and
  `grep -F 'aiur --max-agents'` each match in
  `website/docs-app/guide/quick-start.md`.
- Quick-start does NOT show the guardrails flag:
  `grep -c 'i-understand-that-this-will-be-running' website/docs-app/guide/quick-start.md`
  returns 0.
- Neither page documents Homebrew:
  `grep -ic 'brew' website/docs-app/guide/quick-start.md website/docs-app/reference/configuration.md`
  returns 0.
- The configuration page contains every one of the 79 keys from Scope step 3.
  Mechanical check — each of these dotted key strings appears at least once:
  `max_vertical_panes`, `pre_warmed_sessions`, `max_log_history_mb`,
  `prompt_file`, `debug`, `hooks_file`, `tracker.kind`, `tracker.base_branch`,
  `tracker.active_states`, `tracker.terminal_states`, `tracker.github.repo`,
  `tracker.github.label_prefix`, `tracker.github.bot_account`,
  `tracker.github.trusted_accounts`, `tracker.linear.api_key`,
  `tracker.linear.project_slug`, `tracker.linear.endpoint`,
  `tracker.linear.assignee`, `polling.interval_seconds`, `workspace.root`,
  `workspace.bootstrap_image`, `workspace.bootstrap_image_pull`,
  `worker.ssh_hosts`, `worker.max_concurrent_agents_per_host`, `agent.kind`,
  `agent.remote_control`, `agent.max_concurrent_agents`,
  `agent.max_concurrent_agents_by_state`, `agent.routing`,
  `agent.complexity_prompts`, `agent.max_turns`, `agent.max_retry_attempts`,
  `agent.max_retry_backoff_ms`, `agent.turn_timeout_ms`,
  `agent.stall_timeout_ms`, `agent.max_agent_duration_minutes`,
  `agent.max_load_average`, `agent.synthetic_load_process_cap`,
  `agent.claude.command`, `agent.claude.model`, `agent.claude.permission_mode`,
  `agent.codex.command`, `agent.codex.approval_policy`,
  `agent.codex.thread_sandbox`, `agent.codex.turn_sandbox_policy`,
  `agent.codex.read_timeout_ms`, `agent.codex.thrash_max_per_window`,
  `agent.codex.thrash_window_seconds`, `hooks.after_create`,
  `hooks.before_run`, `hooks.after_run`, `hooks.before_remove`,
  `hooks.timeout_ms`, `prewarm.enabled`, `prewarm.base_build`,
  `prewarm.base_build_file`, `prewarm.poll_seconds`, `pr_watch.enabled`,
  `pr_watch.watch_label`, `pr_watch.command_prefix`,
  `events.block_state_debounce_seconds`, `events.custom_events_per_turn_max`,
  `events.codeowners_refresh_seconds`, `alerts.enabled`,
  `alerts.use_os_default_sounds`, `alerts.sound_dir`, `alerts.alerts_file`,
  `observability.dashboard_enabled`, `observability.dashboard_writable`,
  `observability.refresh_ms`, `observability.render_interval_ms`,
  `server.port`, `server.host`, `opencode.command`, `opencode.bridge_port`,
  `opencode.bridge_host`, `opencode.serve_args`, `opencode.model_prefix`,
  `opencode.prewarm_disabled`.
- The configuration page has all 14 section headings:
  `grep -E '^## (Top-level|tracker|polling|workspace|worker|agent|agent\.claude|agent\.codex|hooks|prewarm|pr_watch|events|alerts|observability|server|opencode)' website/docs-app/reference/configuration.md`
  covers each group (note `agent`, `agent.claude`, `agent.codex` are three
  distinct headings).
- The configuration page has the notes subsection:
  `grep -F 'Resolution & validation notes' website/docs-app/reference/configuration.md`
  matches, and `grep -F 'interval_ms' website/docs-app/reference/configuration.md`
  matches (FI-CFG-031 note).
- Both pages are linked from the VitePress config:
  `grep -F '/guide/quick-start'` and `grep -F '/reference/configuration'`
  each match in the `website/docs-app/.vitepress/` config file.
- `git diff --name-only v2...HEAD` lists only the two new pages and the one
  VitePress config file — no other path (in particular nothing under `src/`,
  `website/src/`, `website/scripts/`, or `website/public/`).

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
Website + docs gate (this ticket touches the docs package; run from repo
root). The marketing guards must stay green AND the docs package must build:
```
cd website && npm run typecheck && npm run build && npm run assert
cd website/docs-app && <the docs build command T-055 defined, e.g. npm run docs:build>
```
Use the exact docs build script T-055 wired into `website/docs-app/package.json`;
if `website/docs-app` has no build script, that is a T-055 blocker — comment
on the issue.

### At-merge (reviewer)
- Check: the docs build emits both pages into `website/dist/docs` and they
  render — spot-check that the quick-start shows `npm install -g aiur-cli`
  and the configuration page renders all 14 section tables with no empty
  cells.
- Check: `grep -ic brew website/docs-app/guide/quick-start.md website/docs-app/reference/configuration.md`
  returns 0 (no Homebrew path documented — accuracy gate).
- Check: spot-verify five configuration rows against `src/lib/aiur/config/schema.ex`
  defaults — e.g. `agent.max_concurrent_agents` default `10`
  (schema.ex:277), `polling.interval_seconds` default `30` (schema.ex:114),
  `alerts.enabled` default `true` (schema.ex:457), `server.port` default `0`
  (schema.ex:514), `opencode.bridge_port` default `4097` (schema.ex:534) —
  each must match the documented Default.
- Confirm no marketing-site drift:
  `git diff --name-only v2...<branch> -- website/src/ website/scripts/ website/public/ website/index.html`
  is empty, and `cd website && npm run assert` prints all-OK.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
