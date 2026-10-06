# Ponytail: opt-in agent support for aiur (research)

Status: research only. No code changes, no tickets filed.
Date: 2026-10-06. aiur baseline: `origin/main` at `f937f2da` (2026-10-06).
Ponytail baseline: `DietrichGebert/ponytail` at `552acd5e` (2026-10-05, tag v4.13.0).

## 1. Summary and recommendation

**What it is.** Ponytail is a prompt, not a tool. It is a system prompt that
makes a coding agent choose the smallest correct solution: a 7-rung "ladder"
(YAGNI, then reuse, stdlib, native platform, installed dependency, one line,
and only then the minimum code). The repo says so directly: "Ponytail is one
prompt: `skills/ponytail/SKILL.md` … Everything else in this repo loads that
prompt into different agents" (README.md:64). The rest of the repo is per-harness
packaging: Claude Code/Codex plugins with three small Node lifecycle hooks,
rule files for about 20 hosts, and five helper skills (`/ponytail-review`,
`-audit`, `-debt`, `-gain`, `-help`). It has no binary, no daemon, no MCP server,
and no network calls.

**Recommendation: spike first, then add opt-in prompt injection with an A/B
arm built in.** Do not use ponytail's plugins or hooks in aiur agents.

1. The only payload worth taking is the ruleset text (MIT). aiur already has a
   harness-neutral channel for text, the prompt prefix
   (`src/lib/aiur/prompt_builder.ex:34-35`). It also has a pinned-vendoring
   precedent for third-party agent content, Compound Engineering
   (`src/lib/aiur/agent_skills.ex:53-68`). Injection through these channels
   needs no Node, no hook trust, no sandbox change, and no secrets.
2. The plugin/hook path is wrong for unattended agents. The SessionStart hook
   writes shared state into `~/.claude` (`hooks/ponytail-runtime.js:59-66`). It
   also tells the model to "Proactively offer to set this up … on first
   interaction", which means editing `~/.claude/settings.json`
   (`hooks/ponytail-activate.js:137-142`). aiur agents inherit the operator's
   `HOME`, so a host-wide install already reaches every agent with no control
   (§3.4).
3. The published benefit has not been measured on aiur's population. The
   headline (−54% LOC, −20% cost) comes from **one model (Haiku 4.5), 12
   tasks, n=4** (benchmarks/results/2026-06-18-agentic.md:186-198). The author
   reports that on a terse reasoning model (GPT-5.5) "it can go the other way"
   (README.md:167). Codex is aiur's default backend
   (`coding_agent/providers/codex.ex:15`), so the most-used aiur arm is the
   case the author flags as possibly negative.
4. Ponytail's output and test rules conflict with aiur's own agent contract
   (§4.9). The spike must find out whether those conflicts cost more rework
   than the smaller diffs save.

**Key config shape (all off by default):**

```yaml
agent:
  ponytail:
    enabled: false          # master switch
    mode: full              # lite | full | ultra
    source: vendored        # vendored (pinned copy in the aiur release) | path
    path: null              # required when source: path; operator-owned file
    sha256: null            # required when source: path; injection refused on mismatch
    backends: []            # [] = every backend; else e.g. [claude, claude-repl]
    arm_fraction: 1.0       # share of eligible tickets that get it (0.5 = A/B)
    review_skill: false     # also install ponytail-review into workspace skills
```

## 2. What ponytail is (sourced)

| Fact | Evidence |
| --- | --- |
| A single prompt; the rest is packaging | README.md:64 |
| Ruleset: 7-rung ladder, "never simplify away" list (validation, data-loss handling, security, accessibility) | skills/ponytail/SKILL.md:32-48, 90-95; AGENTS.md:5-30 |
| Size: SKILL.md 120 lines; compact AGENTS.md 32 lines; 5 helper skills 44-71 lines each | `wc -l` at `552acd5e` |
| Intensity levels `lite`/`full`/`ultra`/`off`; default `full` | SKILL.md:77-83; hooks/ponytail-config.js:16-18 |
| Output rule: "Code first. Then at most three short lines" | SKILL.md:66-75 |
| Test rule: "ONE runnable check … No frameworks, no fixtures, no per-function suites unless asked" | SKILL.md:107-112 |
| Asks the agent to mark shortcuts with `ponytail:` code comments | SKILL.md:64 |
| Install, Claude Code: `/plugin marketplace add` then `/plugin install ponytail@ponytail` | README.md:68-75; INSTALL.md:7-15 |
| Install, Codex: `codex plugin marketplace add …`, then trust two hooks in the interactive `/hooks` screen | README.md:77-84; INSTALL.md:28 |
| Other hosts: copy `AGENTS.md` / rule files, or `npx skills add` | README.md:86; INSTALL.md:198 |
| Runtime: Node on the non-interactive `PATH`, for the hooks only. Without Node, skills still work, but each hook prints `node: command not found` | INSTALL.md:5 |
| Hooks: `SessionStart` (inject the ruleset), `SubagentStart` (inject it into subagents), `UserPromptSubmit` (watch for `/ponytail …` mode commands) | hooks/claude-codex-hooks.json:1-40 |
| Config surface: env vars `PONYTAIL_DEFAULT_MODE`, `PONYTAIL_SUBAGENT_MATCHER`, `PONYTAIL_HIDE_STATUS`, `PONYTAIL_QUIET_STARTUP`; file `$XDG_CONFIG_HOME/ponytail/config.json` or `~/.config/ponytail/config.json` | hooks/ponytail-config.js:1-10, 76-135; INSTALL.md:189-191 |
| Writes: `$CLAUDE_CONFIG_DIR/.ponytail-active`, `…/ponytail-modes/<sha256(project dir)>`. For Codex, these go under `$PLUGIN_DATA`. Also a statusline script copy and a nudge flag in `~/.claude` | hooks/ponytail-runtime.js:35-66; hooks/ponytail-activate.js:96-123 |
| Concurrency caveat (author's own): "sessions in the SAME repo still share one mode … last write wins" | hooks/ponytail-runtime.js:49-50 |
| Network/telemetry: none found. A grep of `hooks/`, `.opencode/plugins`, `pi-extension/index.js` and `scripts/` for `http(s)://`, `fetch(`, `child_process`, `spawn`, `telemetry` finds only URLs in comments | grep at `552acd5e` |
| Credentials: none read | same grep; hooks/ponytail-config.js reads only its own config and `CLAUDE_CONFIG_DIR` |
| Supply-chain guidance: install only from `DietrichGebert/ponytail` or npm `@dietrichgebert/ponytail`; "never ships `.exe` or `.dll` files" | README.md:92 |
| License: MIT, © 2026 DietrichGebert | LICENSE:1-3; package.json:6 |
| Version: 4.13.0 (npm, Claude and Codex plugin manifests agree) | package.json:3; .claude-plugin/plugin.json; .codex-plugin/plugin.json |
| Maturity: created 2026-06-12; 156,769 stars, 8,418 forks, 11 open issues, last push 2026-10-05; about 311 commits; at least 100 contributors (API page cap); 5 releases in the last 4 days (v4.10.2 → v4.13.0) | `gh api repos/DietrichGebert/ponytail` and `/releases`, `/commits`, `/contributors`, read 2026-10-06 |
| Claimed effect: −54% LOC, −22% tokens, −20% cost, −27% time, 100% "safe", vs a no-skill baseline | README.md:33-34, 146-152 |
| Limits of that claim (author's own): Haiku 4.5 only; safety is "a floor" (6 deterministic tasks); n=4; noisy frontend LOC; 4 of 192 cells force-killed | benchmarks/results/2026-06-18-agentic.md:186-198 |
| Reversal on a reasoning model: on GPT-5.5, cost and latency "can go the other way" | README.md:167 |
| `/ponytail-gain` prints the published benchmark averages, "not a per-repo number" | skills/ponytail-gain/SKILL.md:1-20 |

Notes on maturity. The star count is unusually high for a 4-month-old repo, and
the release cadence is very fast. Treat the content as a moving target: pin a
SHA, and do not track `main`. The fast cadence also means the text a user
installs today is not the text that was benchmarked in June.

Security posture. The hooks are small, read-only toward the network, and
defensive about shell injection (`isShellSafe`, hooks/ponytail-config.js:45-52).
The real risk is not code execution. It is that **the hooks insert free text
into the model context**, including instructions to change the user's harness
settings (hooks/ponytail-activate.js:125-151). In aiur's model, that text is an
unreviewed instruction channel. The pure-prompt path has no executable surface
at all.

## 3. Fit with aiur today (precedents)

### 3.1 `agent.rtk`: the closest opt-in precedent, and what it does not do

- Schema: `Aiur.Config.Schema.Rtk` has one field, `enabled`, default `false`.
  Its comment justifies the default with measured, command-dependent numbers
  (`src/lib/aiur/config/schema/agent.ex:87-107`). It is embedded under `agent`
  at `agent.ex:274` and cast at `agent.ex:380`.
- Gate: `Aiur.Rtk.status/1` returns `:disabled | {:ok, version} |
  {:unavailable, :not_installed | :probe_failed} | {:refused,
  :gh_rewrite_not_excluded}`. Each cause stays distinct and is not collapsed to
  "off" (`src/lib/aiur/rtk.ex:84-123`). Discovery uses
  `System.find_executable("rtk")` (`rtk.ex:214`), and every probe has a time
  bound (`rtk.ex:217-240`).
- **It never installs rtk and never puts it on an agent's PATH**
  (`rtk.ex:34-38`). In practice `agent.rtk.enabled` is a gate plus
  observability: the only production caller of `status/1` is `savings/1`
  (`rtk.ex:163-171`), and the only caller of that is the analytics card
  (`aiur_web/live/analytics_live.ex:408-417`). Whether agents actually use
  rtk depends on the host-wide rtk hook. Ponytail support should not copy this
  half-wiring. If aiur offers the key, aiur should own the injection.
- Surface: the "Agent output compression" card has one message per state:
  "Output compression is off — set `agent.rtk.enabled: true`" (`:disabled`),
  not installed, held back, "No commands filtered yet" (it does not say 0%),
  and "The figure is unknown rather than zero" (`analytics_live.ex:396-450`).
  This is the model to follow for unknown states.
- Docs: one row per key in `website/docs-app/reference/configuration.md:233`.

### 3.2 Bundled skills: the right precedent for pinned third-party text

- `Aiur.AgentSkills` embeds skills **at compile time** into the release and
  writes them into each workspace (`src/lib/aiur/agent_skills.ex:1-31,
  119-131`). Installs are idempotent, best-effort ("a file error never fails
  workspace creation"), never overwrite a skill the target repo already ships,
  and add a git-ignore entry for the copy (`agent_skills.ex:27-30, 126`).
- Compound Engineering is vendored with a version file, a skills manifest and
  its upstream LICENSE (`agent_skills.ex:53-68`). A pinned ponytail copy would
  use the same three files.
- Per-backend install paths are declared in the provider registry, not in
  dispatch code: claude `.claude/skills`
  (`coding_agent/providers/claude.ex:16`), codex `.codex/skills` linked to
  `.claude/skills` (`providers/codex.ex:18`), muse `.agents/skills`
  (`providers/muse.ex:20`). The registry holds `codex`, `claude`,
  `claude-repl`, `muse` plus the OpenAI-compatible entries
  (`coding_agent/registry.ex:7-16`).

### 3.3 Prompt prefix: the harness-neutral injection point

`Aiur.PromptBuilder.build_prompt/2` returns `shared_prompt_prefix() <>
integration_branch_prompt(issue) <> rendered_prompt <> complexity_suffix(issue)`
(`src/lib/aiur/prompt_builder.ex:16-35`). The shared prefix is compiled in
(`prompt_builder.ex:11-13`). Every backend receives this string, so a ruleset
block placed here reaches codex, claude, claude-repl, muse and the
OpenAI-compatible backends with no change to any adapter. The issue-text
sanitizer invariant (`prompt_builder.ex:37-58`) does not apply: the ruleset is
operator-chosen content, not attacker-controlled content.

### 3.4 Agents inherit the operator's harness config, so "do nothing" is not neutral

- `AgentEnvironment.workspace_env/2` sets `HEX_HOME`, `MIX_HOME` and similar
  per workspace, but it does **not** override `HOME`
  (`src/lib/aiur/agent_environment.ex:244-357`). It scrubs credentials
  (`agent_environment.ex:56`, GitHub; `:30-31`, provider keys).
- Headless Claude: the `aiur-claude` app-server spawns `claude --print …` with
  `{...process.env}` and no `--settings`/`--setting-sources` restriction
  (claude-app-server `src/server.ts:587-590, 696-724` at `b1ea979c`).
  **Inference, to verify in the spike:** a host-wide `/plugin install
  ponytail` therefore loads in every headless Claude agent, and its
  SessionStart hook writes into the shared `~/.claude`.
- claude-repl: aiur *adds* a settings source with `--settings`, which
  "composes with the user's own settings/hooks rather than replacing them"
  (`src/lib/aiur/claude/hook_settings.ex:6-8`; `claude/repl/command.ex:35`).
  User plugins and hooks run there too.
- Codex: the plugin's hooks need interactive trust (INSTALL.md:28). Whether an
  untrusted or trusted hook runs under `codex app-server` is **unverified**.

### 3.5 Sandbox and credentials

- Codex writable roots come from the configured policy plus runtime roots
  (`src/lib/aiur/config/codex_sandbox_policy.ex:20-150`). Prompt injection
  adds no file writes. The hook path would need writes outside the workspace
  (`~/.claude`, `$PLUGIN_DATA`), which is a reason to reject it.
- `gh` guard and credential scrub (`agent_environment.ex:44-56`;
  `agent_github_guard.ex:79-136`): ponytail touches neither.

### 3.6 Harness-adapter contract (MP-R7)

The contract makes `Aiur.CodingAgent.Backend` explicit and adds a derived
`delivery_primitives` descriptor (`docs/research/aiur-mobile-and-platform/
contracts/harness-adapter.md:61-82`). Registry keys keep their meaning, and
"Adding an optional callback or a descriptor field is additive" (`:235-239`).
Two consequences:

- Prompt-prefix injection needs **no new capability**. It is harness-neutral
  by construction.
- If a later version wanted hook- or skill-based delivery per harness, declare
  it as registry data, not dispatch code, the same way as `skill_install`.
  For example, add an optional `instruction_channels: [:prompt_prefix |
  :skill | :session_start_hook]` key whose absence means `[:prompt_prefix]`.
  This document does not propose that key now.

## 4. Proposed opt-in design

### 4.1 Config keys (all under `agent.ponytail`)

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Master switch. With `false`, nothing is read, injected or installed. |
| `mode` | `lite\|full\|ultra` | `full` | Intensity. aiur filters the ruleset the same way upstream does (hooks/ponytail-instructions.js:11-40): keep only the table row and worked example for the chosen level. |
| `source` | `vendored\|path` | `vendored` | `vendored`: pinned copy compiled into the release. `path`: operator-owned file. |
| `path` | string | `null` | Required when `source: path`. Resolved relative to the config file, like `prompt_file:`. |
| `sha256` | string | `null` | Required when `source: path`. On a mismatch, injection is refused (§4.8). |
| `backends` | list of registry ids | `[]` | `[]` means every backend. Otherwise only the listed backends get the block. The check uses the **running** backend, after fallback and RC promotion (contract §3). Unknown ids fail config validation. |
| `arm_fraction` | float 0.0–1.0 | `1.0` | Share of eligible tickets that get the block. Assignment is a deterministic hash of the ticket id. `0.5` gives an A/B split. |
| `review_skill` | boolean | `false` | Also install the vendored `ponytail-review` skill through `AgentSkills`, so reviewers can call it. |

Rejected keys: `hooks`/`plugin` (§4.4), `auto_update` (aiur never fetches
agent content at runtime), and per-ticket labels. The labels are left as an
open question (Q4).

### 4.2 Per-harness applicability

| Backend | Channel | Notes |
| --- | --- | --- |
| codex | prompt prefix | The author flags a possible cost reversal on GPT-5.x reasoning models (README.md:167). Measure this backend on its own. |
| claude (headless) | prompt prefix | Matches the benchmarked harness, but on a different model. A host-wide plugin, if installed, would double-inject (§3.4). |
| claude-repl | prompt prefix | Same double-inject risk. |
| muse | prompt prefix | Untested by upstream. Same channel. |
| OpenAI-compatible (kimi, deepseek, openrouter) | prompt prefix | Untested by upstream. Small or local models are covered only by a single-shot run (benchmarks/results/2026-06-15-llama3.2-local.md). |

### 4.3 Install and discovery

- No executable means nothing to put on `PATH`, no minimum version and no
  probe. "Discovery" is: the vendored copy exists in the release (a
  compile-time fact), or the configured `path` exists and its hash matches.
- Vendoring: `priv/vendor/ponytail/{SKILL.md, ponytail-review/SKILL.md,
  LICENSE, VERSION}`, with `VERSION` = `4.13.0 552acd5e…`. It is embedded at
  compile time like CE (`agent_skills.ex:16-21`). Updates are deliberate PRs
  that show the text diff.
- aiur never runs `/plugin install`, `codex plugin add`, `npx skills add`,
  or any ponytail script.

### 4.4 Injection

- Insert a block between `shared_prompt_prefix()` and the operator template
  (`prompt_builder.ex:34`). The block has two parts:
  1. A **precedence preamble written by aiur**: "The following coding-style
     ruleset applies to the code you write. Where it conflicts with the Aiur
     agent instructions above, the repository's AGENTS.md/CONTRIBUTING, or the
     ticket, those win. In particular, keep the required workpad, PR body
     sections, and test discipline."
  2. The mode-filtered ruleset with its frontmatter removed (upstream does the
     same, hooks/ponytail-instructions.js:13).
- Skip Ponytail's own Claude/Codex hooks. They exist to re-inject the prompt
  on every session start and subagent start. aiur sends its prompt on every
  turn, so re-injection adds nothing. Subagent coverage is the one capability
  lost (hooks/ponytail-subagent.js). Accept that loss, and record it as Q5.
- `review_skill: true` adds `ponytail-review` to the list that
  `AgentSkills.install/1` writes. Each backend's declared path applies, and a
  skill the target repo already ships is not overwritten (`agent_skills.ex:27`).

### 4.5 Sandbox

No change. The block is part of the prompt string. Skills install into the
workspace, which is already writable and already git-ignored for generated
skills. No network egress, no new writable root, no Node.

### 4.6 Security and secrets

- No credentials are involved, and none need to be scrubbed or injected.
- Integrity: vendored text is reviewed in a PR. Path-sourced text is pinned by
  `sha256`. Keep the path file outside agent-writable trees: validation
  rejects a `path` inside `workspace.root`. Otherwise an agent could edit its
  own future instructions.
- Treat the ruleset as operator-trusted text. It must never be rendered through
  Solid with issue variables.

### 4.7 Observability

Follow the two rules from AGENTS.md ("Computed ages and collapsed causes"):

- **Status per state, no collapsed causes.** Add `Aiur.Ponytail.status/0`
  returning `:disabled | {:active, %{mode, source, version, sha}} |
  {:unavailable, :source_missing | :sha_mismatch | :path_in_workspace}`.
  Do not collapse an unknown reason to a specific cause. Use `_ -> :unknown`.
- **Per agent:** `aiurdev agents` and the dashboard agent row show `ponytail:
  full` only when the running backend actually received the block. The field
  is recorded at prompt-build time, not derived from config, so a backend
  outside `backends:` reads `off (backend excluded)`.
- **Per ticket:** write `{ponytail_arm: :on | :off | :ineligible, mode,
  sha}` into run telemetry and the `logs/agent.ndjson` session-start event, so
  every token, cost and PR figure joins to an arm.
- **Analytics card "Ponytail experiment".** States: `off` ("set
  `agent.ponytail.enabled: true`"), `collecting (n_on, n_off < threshold)` —
  never a percentage —, `ok` (per-backend medians with n and a confidence
  interval), and `unknown` (the source could not be read). Each figure shows
  `observed_at` and its age. It shows **aiur-measured** numbers only. It never
  shows upstream's benchmark figures (`/ponytail-gain`-style text is
  excluded).

### 4.8 Failure behaviour

| Failure | Behaviour |
| --- | --- |
| `path` missing, unreadable, or hash mismatch | Do not inject. Dispatch continues normally. Raise **one** alert per daemon boot per cause (deduped). Show the cause in status and on the card. |
| Vendored copy absent (build defect) | Same as above. The test suite also fails at compile time, because the file is an `@external_resource`. |
| Ruleset conflicts with aiur instructions | Handled by the precedence preamble. The spike measures the residual cost (§5). |
| Host-wide ponytail plugin also installed | Detect `~/.claude/plugins/**/ponytail` or `.ponytail-active` at boot and warn once: "ponytail is installed host-wide; agents get it twice / outside aiur's control". Never delete it. |

### 4.9 Conflicts to settle before turning it on

| Ponytail rule | aiur rule it can collide with |
| --- | --- |
| "Code first. Then at most three short lines" (SKILL.md:66-75) | Required workpad updates, PR body sections, and mutation-check lines (AGENTS.md "Tests must fail without the production change"). Mitigation: ponytail itself exempts "explanation the user explicitly asked for" (SKILL.md:71-73), and the preamble names these. |
| "ONE runnable check … no frameworks, no fixtures" (SKILL.md:107-112) | ExUnit tests that must fail with the hunk reverted. A `demo()` self-check is not coverage in aiur. |
| `ponytail:` comments in code (SKILL.md:64) | Comment noise in target repos. Decide whether to allow, or tell agents to put them in the PR body (Q3). |
| "Ship the lazy version and question it" (SKILL.md:62) | No human is in the loop mid-turn. aiur's decision API is the channel for real questions. |

### 4.10 Docs that must ship (same PR, per AGENTS.md)

- `website/docs-app/reference/configuration.md`: one row per `agent.ponytail.*`
  key with its default. `scripts/check-config-docs.py` enforces this.
- `.aiur/examples/config.example` and `src/examples/workflows/*.yaml`: a
  commented block showing the keys, documented as opt-in with the measured
  saving at zero at merge.
- `website/docs-app/guide/` (analytics page) for the new card, and
  `website/docs-app/skills.md` if `review_skill` ships.
- Third-party notice for the MIT text.
- `cli.md`: only if a flag is added. None is proposed. `aiurdev agents` output
  gains a field, and the page that documents that output must show it.

### 4.11 Test strategy

Each test must fail with its production hunk reverted (AGENTS.md):

1. Schema: defaults are off. `source: path` without `sha256` is rejected.
   `path` inside `workspace.root` is rejected. An unknown backend id is
   rejected.
2. Injection: with `enabled: true` the prompt contains the preamble and the
   `full` ladder text, and with `enabled: false` it does not. Revert the gate
   and confirm the test fails. Assert content, not `is_binary`.
3. Mode filter: `lite` contains the lite row and not the ultra row.
4. Backend filter: the block is omitted for an excluded **running** backend,
   including after a rate-limit fallback (the fixture must reach the fallback
   path).
5. Arm assignment: deterministic for a ticket id, and the fraction is within a
   tolerance over 10k ids.
6. Failure: a sha mismatch gives `{:unavailable, :sha_mismatch}`, one alert,
   no injection, and dispatch proceeds.
7. Card unknown path: replace the `unknown`/`collecting` branch with `0%` and
   confirm the test fails.
8. Manual: `aiurdev --test` with `enabled: true` through the wrapper-tmux
   recipe. Open a chat pane, confirm the block appears in the rendered
   transcript, and confirm `aiurdev agents` shows `ponytail: full`.

## 5. Measurement plan for any claimed benefit

AGENTS.md "A claimed saving must be measured" applies. The implementation PR
is **instrumentation plus an opt-in behaviour change and claims no saving**.
At merge, the saving is zero, because no shipped config enables it (item 3,
item 5: population = 0 configs).

The experiment, after merge, on the dogfood fleet:

- **Design:** `arm_fraction: 0.5`, stratified by backend and complexity label.
  Arms are assigned by ticket-id hash, so the operator cannot cherry-pick.
- **Primary metrics, per ticket:** tokens and cost (existing accounting,
  `src/lib/aiur/orchestrator/token_accounting.ex`); wall time to PR open; PR
  `additions`/`deletions`, read once per merged PR through the governed and
  cached GitHub path (read `website/docs-app/apis/github.md` first).
- **Guard metrics (quality must not drop):** CI pass on the first push; count
  of `agent:rework` cycles; review findings marked blocking; reverts or
  follow-up fix PRs within 14 days; tests added per PR.
- **Sample size:** report nothing below 30 merged tickets per arm per backend.
  Use medians with bootstrap 95% CIs. Upstream's own n=4 × 12 is not a basis
  for a figure.
- **Statement format for any later claim:** "codex, n=… /…, median cost $X →
  $Y per ticket (CI …), measured 2026-MM-DD on aiur's own tickets; rework
  rate A → B." Also state the population: how many tickets per hour reach the
  `on` arm.
- **Stop rule:** if any guard metric degrades beyond its CI, turn the
  experiment off for that backend.

## 6. Alternatives

| Option | Effort | Control | Measurable | Verdict |
| --- | --- | --- | --- | --- |
| A. Do nothing | 0 | none | no | A host-wide plugin install already leaks into agents (§3.4). Doing nothing leaves that unmanaged. |
| B. Operator pastes AGENTS.md (32 lines) into `.aiur/prompt.md` | 0 code | all-or-nothing, every backend | no arm, no telemetry | **Use this for the spike.** Zero code, but it cannot A/B or report. |
| C. Target repo ships ponytail `AGENTS.md` | 0 | per repo | no | Codex reads it natively. Out of aiur's hands. |
| D. Proposed `agent.ponytail` prompt injection | small (about 1 schema, 1 module, 1 card) | per backend, per fraction, pinned | yes | **Recommended after the spike.** |
| E. Install ponytail plugins/hooks into agent harnesses | medium | poor | partial | **Reject.** Shared `~/.claude` state, "offer to set up" prompts, Codex hook-trust UX, Node dependency. |
| F. Use the vendored CE `ce-simplify-code` / `ce-code-review` at review time | 0 | existing | partial | Complements A–D. It acts after the build, not during it. |

## 7. Risks

- **Quality regression hidden by smaller diffs:** missing tests, or guards cut
  outside upstream's 6 safety tasks. Mitigated by the guard metrics and the
  stop rule.
- **Cost reversal on reasoning models** (README.md:167). aiur's default
  backend is a reasoning model.
- **Instruction conflicts** (§4.9) can cause rework loops that cost more than
  they save.
- **Upstream churn:** 5 releases in 4 days. Pinning avoids silent drift, but
  the pinned text ages.
- **Double injection** when the operator also installs the host plugin.
- **Executor sessions:** a host-wide plugin also changes the Executor's own
  Claude Code session (review behaviour). This is outside this design.
- **Hype risk:** a very high star count and benchmark marketing invite a
  "default on" decision without measurement. The plan above prevents that.

## 8. Open questions for Kevin

1. **Spike or skip?** Options: (a) run a 1–2 day spike with option B on about
   10 tickets, then decide; (b) build D directly; (c) skip ponytail. *Recommend
   (a).* It finds the instruction conflicts for the cost of a config paste.
2. **Which backends first?** (a) all; (b) Claude only (closest to upstream's
   benchmark); (c) Codex only (the largest fleet share, and the case the
   author flags as possibly negative). *Recommend (b) plus (c) as separate
   arms.* Do not ship to OpenAI-compatible backends until measured.
3. **`ponytail:` code comments in target repos?** (a) allow; (b) forbid in the
   preamble and move them to the PR body; (c) allow only in aiur's own repo.
   *Recommend (b).*
4. **Per-ticket override?** (a) none (hash arm only); (b) a
   `ponytail:off`-style label for tickets where breadth is intended (refactors,
   docs). *Recommend (a) during the experiment.* Labels bias the arms.
5. **Subagent coverage:** accept that Claude subagents (Task tool) do not get
   the ruleset, or add a `SubagentStart` hook to aiur's own `--settings`
   later? *Recommend accept.* The hook path is what §4.4 avoids.
6. **Vendored vs path-only:** (a) vendor a pinned copy (license notice, PR
   review on update); (b) path + sha only (aiur ships no third-party prompt).
   *Recommend (a).* It matches the CE precedent and makes the arm reproducible.
7. **Host-wide install on this machine:** is ponytail already installed in
   Kevin's `~/.claude` or `~/.codex`? If yes, every agent and the Executor
   already run it, and the baseline arm is contaminated. A read-only check on
   2026-10-06 found no install: no `ponytail` match under `~/.claude/plugins`,
   `~/.claude/settings.json` or `~/.codex/config.toml`, and no
   `~/.claude/.ponytail-active` or `~/.config/ponytail`. *Check again before
   any measurement.*

## 9. Candidate tickets (not filed)

| # | Title | Outcome | Blockers |
| --- | --- | --- | --- |
| P1 | Spike: ponytail ruleset via `.aiur/prompt.md` on ~10 tickets | A written conflict audit (workpad, PR body, tests, comments), plus rough cost and LOC per ticket against recent baseline tickets | Q1, Q7 |
| P2 | Add `agent.ponytail` config schema, off by default | Keys of §4.1 validate, docs rows land, `check-config-docs` passes | P1 go decision |
| P3 | Vendor pinned ponytail ruleset with license and version | `priv/vendor/ponytail/*` embedded at compile time; update procedure documented | P2, Q6 |
| P4 | Inject the mode-filtered ruleset with a precedence preamble | Prompt contains the block only for enabled, eligible, running backends; tests §4.11 (2–4) | P2, P3 |
| P5 | Ticket-hash arm assignment and telemetry tagging | Every run records `ponytail_arm`, `mode` and `sha`; `aiurdev agents` shows it | P4 |
| P6 | Ponytail status, failure alerts and analytics card | Distinct unavailable causes; one alert per cause; the card never shows a % below threshold; unknown-path mutation test | P5 |
| P7 | Optional `ponytail-review` workspace skill | Installed through `AgentSkills` when `review_skill: true` | P3 |
| P8 | Measurement report after n ≥ 30 per arm per backend | Per-backend figures in §5 format; keep or turn off per backend | P5, P6, about 2–4 weeks of fleet time |

## 10. Sources

- Ponytail repo `https://github.com/DietrichGebert/ponytail`, shallow clone at
  `552acd5efd0aeae2583a12efe39373d2f076f25e` (committed 2026-10-05T22:46:39+02:00,
  "chore: move translations, CONTRIBUTING and .env.example out of the repo
  root (#1044)"). Files cited: README.md, INSTALL.md, AGENTS.md, LICENSE,
  package.json, .claude-plugin/plugin.json, .codex-plugin/plugin.json,
  skills/ponytail/SKILL.md, skills/ponytail-gain/SKILL.md,
  hooks/claude-codex-hooks.json, hooks/ponytail-{activate,config,runtime,
  instructions,subagent,mode-tracker}.js,
  benchmarks/results/2026-06-18-agentic.md. Only read; nothing executed. The
  clone was deleted after reading.
- GitHub API reads (2026-10-06): `repos/DietrichGebert/ponytail` (stars,
  forks, created, pushed, license), `/releases?per_page=5` (v4.13.0
  2026-10-05T18:54:43Z … v4.10.2 2026-10-03), `/commits` (Link header, about
  311 pages at per_page=1), `/contributors` (100 on the first page).
- aiur `origin/main` at `f937f2dac678aaedf28d05f7f20248adb5976680`
  (2026-10-06T14:15:05-07:00): files cited inline in §3–§4.
- MP-R7 harness-adapter contract:
  `docs/research/aiur-mobile-and-platform/contracts/harness-adapter.md` on
  branch `research/refactor-findings`, last commit `b43dab77` (2026-10-06).
  This file is not on `origin/main`.
- `aiur-claude` app-server (`~/github/everdred/claude-app-server`) at
  `b1ea979c` (2026-09-18): `src/server.ts:587-590, 696-724`.
