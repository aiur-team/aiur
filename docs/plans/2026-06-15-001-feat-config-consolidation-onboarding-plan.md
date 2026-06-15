---
title: "feat: Config consolidation, onboarding & global config"
type: feat
status: active
date: 2026-06-15
origin: docs/brainstorms/2026-06-15-config-consolidation-and-onboarding-requirements.md
---

# feat: Config Consolidation, Onboarding & Global Config

## Overview

Three coherent parts on one branch (`init-setup`): **(A)** consolidate every `.aiurconfig`
setting into one validated `Aiur.Config.Schema`, restructured shared-vs-provider-specific,
with dead/duplicate settings removed; **(B)** anchor onboarding on a committed
`.aiurconfig.example` the `aiur init` wizard fills, and route `aiurdev init` to it;
**(C)** add a global `~/.aiurconfig` with local→global resolution and git-remote repo
auto-detection. Breaking config changes are acceptable — only this repo uses aiur today.

---

## Problem Frame

Four sections (`github`, `claude`, `linear`, `prompt_file`) bypass the Ecto schema and are
read ad-hoc via `Aiur.Config.section/1`, duplicating config-reading and leaving `linear`
settings in two places (vestigial `tracker.*` + the real `linear:`). `claude.version` is
dead (zero consumers). `aiur init` (a real wizard) is unreachable via `aiurdev init`
("no command") and isn't backed by an example file. There's no global config fallback.
See origin: `docs/brainstorms/2026-06-15-config-consolidation-and-onboarding-requirements.md`.

---

## Requirements Trace

- R1. One validated config surface; `*.Config` getters keep their API but delegate to `Config.settings!()`.
- R2. `tracker` shared-vs-specific: `tracker.{kind,active_states,terminal_states}` + `tracker.github.*` + `tracker.linear.*`; flat `tracker.*` Linear fields removed.
- R3. `agent` shared-vs-specific: shared knobs + `turn_timeout_ms`/`stall_timeout_ms` (promoted from codex) on `agent`; `agent.claude.*` + `agent.codex.*` (incl. moved `thrash_*`).
- R4. Remove dead `claude.version` + vestigial flat `tracker.*` Linear fields.
- R5. `opencode` stays top-level; `prompt_file` becomes a top-level schema field.
- R6. Hard cutover, no shim; migrate this repo's `.aiurconfig`.
- R7. Committed `.aiurconfig.example` — full annotated reference, essential vs `# advanced`, placeholders.
- R8. `aiur init` fills the example via text substitution (comments preserved); still creates labels + `.env` + auth checks.
- R9. `aiurdev init` routes to `bin/aiur init`.
- R10. `init`'s first prompt: repo-local vs global; never overwrite existing.
- R11. Global config omits `tracker.github.repo` + `prompt_file`.
- R12. Resolution: local `./.aiurconfig` else global `~/.aiurconfig` + git-remote repo auto-detect.

**Origin actors:** A1 (dev onboarding a repo), A2 (dev running aiur with no local config), A3 (aiur runtime).
**Origin acceptance examples:** AE1 (R1), AE2 (R2/R4), AE3 (R3), AE4 (R7/R8), AE5 (R9), AE6 (R10/R11/R12).

---

## Scope Boundaries

- No backward compatibility with the old config shape (R6).
- No behavior change to settings beyond promoting `turn_timeout_ms`/`stall_timeout_ms` to apply to all backends (R3) — and that's already true via the `agent_*` accessors.
- No new tracker providers or agent backends.
- No config-migration tool; this repo's `.aiurconfig` is migrated by hand in the PR.
- No wizard prompt-flow redesign beyond the new first question (R10) and template sourcing (R8).

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/config/schema.ex` — Ecto embedded schemas; main schema at the bottom (`embedded_schema do … embeds_one(...)`), `parse/1`, the per-section `changeset/2`. Add `Claude`/`Github`/`Linear` embeds; nest under `tracker`/`agent`; mirror existing embed + `cast`/`validate_number` style.
- `src/lib/aiur/config.ex` — accessors (`max_log_history_mb/0`, `agent_turn_timeout_ms/0` → `settings!().codex.turn_timeout_ms` at ~224, `agent_stall_timeout_ms/0` at ~234), and `section/1` (~67, the ad-hoc raw-YAML bridge to remove). `settings/0` → `Schema.parse()`.
- `src/lib/aiur/github/config.ex`, `src/lib/aiur/claude/config.ex`, `src/lib/aiur/linear/config.ex` — each reads `Aiur.Config.section("<name>")`; repoint to `settings!()`. Consumer scope is small (each getter has 0–2 external callers).
- `src/lib/aiur/workflow.ex` — `workflow_file_path/0` = env override `|| detect_run_folder_config/0` (= `Path.join(File.cwd!(), ".aiurconfig")`); `prompt_file` read at ~88 (`Map.get(config, "prompt_file")`).
- `src/lib/aiur/cli.ex` — `run(Aiur.Workflow.detect_run_folder_config(), deps)` at ~109; "Config file not found … Run `aiur init`" at ~141.
- `src/lib/aiur/init.ex` — wizard: `assemble_config/1` + `to_yaml/1` (replace with template-fill), `guard_existing_config/2` (existing guard for R10), `prompt_tracker`/`prompt_agents`/`prompt_concurrency`, `setup_labels`/`setup_env`/`run_auth_checks`, injected `io`/`deps`.
- `src/lib/aiur/claude/repl_agent.ex:490` + `src/lib/aiur/claude/coding_agent.ex:304` — already call `Config.agent_turn_timeout_ms()`, so the timeout promotion needs no caller change.
- `scripts/aiurdev` — case dispatch at ~2168 (no `init`), usage at ~341.

### Institutional Learnings

- Wizard is fully unit-testable via injected `io`/`deps` (no real FS/network) — use that for all init tests.
- `--test`/`--test3` reset flows write/clear `.aiurconfig` fixtures; the schema migration (U3) must keep `src/test/fixtures/*.aiurconfig` and `config/config.exs`'s test workflow path parseable.

### Current `aiur init` prompt flow (today — to preserve/extend in U5/U7)

Source: `src/lib/aiur/init.ex`. Defaults shown in `[brackets]`; pressing Enter accepts the default.

1. **Issue tracker** `(github/linear/memory)` `[github]`
   - if **github**: **GitHub repo (owner/name)** `[auto-detected from git remote]` → **Label prefix** `[aiur]`
   - if **linear**: **Linear API key** → **Linear project slug**
   - if **memory**: no follow-ups
2. **Coding agents** `(comma-separated: claude/codex)` `[claude]`
   - for each chosen agent: **`<agent>` model** `[backend's first registry model]`
3. **Max concurrent agents** `[10]` (min 1)
4. **Max vertical panes** `[3]` (min 1)
5. **Pre-warmed sessions** `[3]` (min 0)

Then, non-prompt actions after writing the config:
- writes `.aiurconfig` (currently assembled from the answers; U5 changes this to fill `.aiurconfig.example`)
- **github only:** creates `.env` + `.env.example` if absent; prints "Set `GITHUB_TOKEN` …" + the token URL
- runs auth checks per chosen agent + the tracker; on failure prompts **`[r]etry or [s]kip`** `[skip]` and proceeds either way
- **github only:** creates the labels aiur routes on; prints the complexity→agent routing summary

**U7 adds a new question #0 before all of these:** **Config location** `(repo-local/global)` `[repo-local]` → targets `./.aiurconfig` or `~/.aiurconfig`; the existing-config guard runs against the chosen target; the **GitHub repo** prompt (1a) is skipped for global (repo is auto-detected at run time).

---

## Key Technical Decisions

- Nest provider config under the shared parent (`tracker.{github,linear}`, `agent.{claude,codex}`); the parent holds anything shareable, sub-sections only truly provider-specific settings (user directive).
- Timeout promotion is a 2-line accessor repoint (`Config.agent_turn_timeout_ms/0`, `agent_stall_timeout_ms/0` → `settings!().agent.*`) — claude already honors them.
- `init` fills `.aiurconfig.example` by **text substitution on placeholder tokens** (preserves comments), not YAML re-serialization.
- Global config = `~/.aiurconfig`; local detection stays cwd-based (`./.aiurconfig`, which is the repo root in practice); on global fallback, repo identity is auto-detected from the cwd git remote (reuse `init.ex`'s existing `detect_repo/0` git-remote parser).
- Phase A lands as a coherent set (U1–U3 together) since changing the schema breaks every config fixture until migrated.

---

## Open Questions

### Resolved During Planning

- R3 timeout promotion: accessors `agent_turn_timeout_ms/0`/`agent_stall_timeout_ms/0` already abstract the read and claude-repl already calls them → move fields codex→agent, repoint two accessor lines, no caller changes.
- R1 consumer scope: small (0–2 callers per ad-hoc getter); the `*.Config` modules switch their private `section_value` from `Config.section/1` to `settings!()`.
- R12 detection boundary: keep cwd-based local detection (matches today's `detect_run_folder_config/0`); add `~/.aiurconfig` fallback + git-remote repo auto-detect.
- Sequencing: A (config) before B (onboarding) before C (global) so each targets the clean surface.

### Deferred to Implementation

- Exact placeholder token syntax in `.aiurconfig.example` (e.g. `__REPO__`) and how list/multi-line prompted values (routing map, agent list) substitute while keeping the file valid YAML.
- Whether `Aiur.Config.section/1` can be fully deleted or has stragglers outside the three `*.Config` modules (grep at implementation time; delete only if zero remaining callers).
- Precise error/UX when global fallback is used but no git remote is detectable (no repo identity).

---

## High-Level Technical Design

> *Directional guidance for review, not implementation specification.*

Target `.aiurconfig` shape (after restructure):

    tracker:                          agent:
      kind: github                      kind: codex
      active_states: [...]              remote_control: false
      terminal_states: [...]            routing: {1: claude, 3: codex}
      github:                           complexity_prompts: {}
        repo: <owner/name>              max_concurrent_agents: 10
        label_prefix: aiur              max_concurrent_agents_by_state: {}
        bot_account: ...                max_turns: 20
      linear:                           max_retry_attempts: 3
        api_key: ...                    max_retry_backoff_ms: 300000
        project_slug: ...               turn_timeout_ms: 3600000   # promoted
        endpoint: ...                   stall_timeout_ms: 300000   # promoted
        assignee: ...                   claude: {command, model, permission_mode}
                                        codex:  {command, approval_policy, thread_sandbox,
    prompt_file: AIUR.md                         turn_sandbox_policy, read_timeout_ms,
    opencode: {...}  (top-level)                 thrash_max_per_window, thrash_window_seconds}
    polling / max_vertical_panes / pre_warmed_sessions / max_log_history_mb
    worker / observability / server / events   (advanced, unchanged)

Config resolution (per command):

    workflow_file_path():
      explicit --config arg / env override   -> use it
      else ./.aiurconfig (cwd)               -> use it
      else ~/.aiurconfig (global)            -> use it + repo := git-remote(cwd)
      else                                   -> "Config not found; run aiurdev init"

---

## Implementation Units

### Phase A — Config consolidation (U1–U3 land together; suite stays green only once all three are in)

- [ ] U1. **Restructure & consolidate `Aiur.Config.Schema`**

**Goal:** One validated schema holding every setting, nested shared-vs-provider-specific, dead settings removed.

**Requirements:** R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema.ex`
- Test: `src/test/aiur/workspace_and_config_test.exs`

**Approach:**
- Add embeds `Github` (repo, label_prefix, bot_account), `Linear` (api_key, project_slug, endpoint, assignee), `Claude` (command, model, permission_mode).
- `Tracker` embed: keep `kind`, `active_states`, `terminal_states`; remove `endpoint`/`api_key`/`project_slug`/`assignee`; add `embeds_one(:github, Github)` + `embeds_one(:linear, Linear)`.
- `Agent` embed: keep shared knobs; add `turn_timeout_ms` (default 3_600_000) + `stall_timeout_ms` (default 300_000); add `embeds_one(:claude, Claude)` + `embeds_one(:codex, Codex)`; remove `codex_thrash_max_per_window`/`codex_thrash_window_seconds`.
- `Codex` embed: remove `turn_timeout_ms`/`stall_timeout_ms` (now on agent); add `thrash_max_per_window` (6) + `thrash_window_seconds` (60); keep `command`, `approval_policy`, `thread_sandbox`, `turn_sandbox_policy`, `read_timeout_ms`.
- Main schema: drop top-level `embeds_one(:codex, ...)` (now under agent); keep `opencode` top-level; add top-level `field(:prompt_file, :string)`.

**Patterns to follow:** existing embed + `changeset/2` (`cast` + `validate_number`) style in the same file; `max_log_history_mb` field added earlier.

**Test scenarios:**
- Covers AE2. Happy: a github config with `tracker.github.repo` + `tracker.github.label_prefix` parses; `settings.tracker.github.repo` resolves.
- Covers AE2. Edge: `tracker.api_key`/`tracker.endpoint` are no longer accepted fields (ignored/rejected); `agent.claude.version` absent.
- Covers AE3. Happy: `agent.turn_timeout_ms`/`agent.stall_timeout_ms` parse + default; `agent.codex.thrash_max_per_window` parses.
- Edge: omitted nested sections fall back to embed defaults (`defaults_to_struct: true`).
- Error: non-positive `agent.turn_timeout_ms` / `agent.codex.thrash_window_seconds` rejected.

**Verification:** `Schema.parse/1` round-trips the new nested shape; defaults apply for omitted sections; old flat keys are gone.

---

- [ ] U2. **Repoint accessors & `*.Config` readers to `settings!()`**

**Goal:** Remove the ad-hoc raw-YAML read path so every setting is read from the validated struct.

**Requirements:** R1, R3

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/config.ex` (accessors + remove `section/1` if unused), `src/lib/aiur/github/config.ex`, `src/lib/aiur/claude/config.ex`, `src/lib/aiur/linear/config.ex`
- Test: `src/test/aiur/github/config_test.exs`, `src/test/aiur/claude/config_test.exs`, `src/test/aiur/opencode/config_test.exs` (+ linear config test if present)

**Approach:**
- `Aiur.GitHub.Config`: `repo/0`/`label_prefix/0`/`bot_account/0` read `settings!().tracker.github.*`; `token/0` stays env-based.
- `Aiur.Claude.Config`: `command/0`/`model/0`/`permission_mode/0` read `settings!().agent.claude.*`; delete `version/0` (dead).
- `Aiur.Linear.Config`: `api_key/0`/`project_slug/0` read `settings!().tracker.linear.*` (or `LINEAR_API_KEY` env where applicable).
- `Aiur.Config`: `agent_turn_timeout_ms/0` → `settings!().agent.turn_timeout_ms`; `agent_stall_timeout_ms/0` → `settings!().agent.stall_timeout_ms`; delete `section/1` once no callers remain (grep first).

**Patterns to follow:** existing `settings!()`-based accessors in `config.ex` (e.g. `max_vertical_panes/0`).

**Test scenarios:**
- Covers AE1. Happy: each `*.Config` getter returns the value from a parsed config (no raw-YAML access).
- Edge: missing nested section → getter returns the embed default (e.g. `Claude.Config.command/0` → `aiur-claude`).
- Integration: a single `settings!()` parse feeds GitHub/Claude/Linear getters consistently (no second YAML read).
- Regression: `agent_turn_timeout_ms/0` returns the `agent.turn_timeout_ms` value and claude-repl/coding-agent still receive it.

**Verification:** grep finds no `Config.section(` / `section_value` raw reads outside the schema; all `*.Config` tests green.

---

- [ ] U3. **Migrate this repo's `.aiurconfig` + all config fixtures**

**Goal:** Bring every committed config to the new shape so the suite parses.

**Requirements:** R6

**Dependencies:** U1

**Files:**
- Modify: `.aiurconfig`, `src/test/fixtures/test.aiurconfig` (+ any other `*.aiurconfig` fixtures), and any inline config maps in tests that use old keys.

**Approach:** mechanically move `github:`→`tracker.github`, `claude:`→`agent.claude`, `linear:`→`tracker.linear`, codex timeouts→`agent`, `codex_thrash_*`→`agent.codex.thrash_*`; drop `claude.version` + flat `tracker.*` Linear fields; keep `opencode`/`prompt_file` top-level.

**Test scenarios:**
- Test expectation: none -- data migration; correctness proven by U1/U2 tests + the full suite parsing these fixtures.

**Verification:** full suite parses every committed config; `.aiurconfig` reflects the new nested shape and is smaller/dedup'd.

---

### Phase B — Onboarding

- [ ] U4. **Author `.aiurconfig.example` (annotated template)**

**Goal:** A committed, full, annotated reference of the cleaned-up settings with placeholders, grouped essential vs advanced.

**Requirements:** R7

**Dependencies:** U1

**Files:**
- Create: `.aiurconfig.example`

**Approach:** every section from the new schema, each with a one-line comment; an `# --- advanced ---` block for `worker`/`observability`/`server`/`events`/retry/thrash tuning; placeholder tokens (e.g. `__REPO__`, `__AGENT_KIND__`, `__ROUTING__`) for prompt-filled values.

**Test scenarios:**
- Happy: `Schema.parse/1` of `.aiurconfig.example` with placeholders replaced by valid sample values succeeds (a test asserts the shipped example is itself parseable once filled).

**Verification:** the filled example parses against the new schema; comments present; essential vs advanced grouping clear.

---

- [ ] U5. **Wizard fills the example template (text substitution)**

**Goal:** `aiur init` produces config by substituting prompted values into `.aiurconfig.example`, preserving comments — replacing `assemble_config`/`to_yaml`.

**Requirements:** R8

**Dependencies:** U4

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Test: `src/test/aiur/init_test.exs`

**Approach:** read the example (via injected `deps`), substitute placeholder tokens, write to the target path. Drive all prompts through injected `io` functions (`select`/`multiselect`/`confirm`/`input`) — runtime uses **Owl** (`Owl.IO.select/multiselect/confirm/input`, already a dep), tests inject scripted answers. Keep `setup_labels`/`setup_env`/`run_auth_checks`/`guard_existing_config`.

**LOCKED wizard spec (user, 2026-06-15):**
Prompts in order — (component, default):
1. Config location — select (repo-local / global) [repo-local]
2. Issue tracker — select (github / linear / memory) [github]
3. GitHub repo — input (git-remote prefill) *(linear → API key + project slug)*
4. Label prefix — input [aiur]
5. Which agents — multiselect (claude / codex) [claude]; **if claude chosen, print help: "aiur supports Claude remote-control mode"**
6. Customize model per complexity tag? — confirm [no] → if yes, per-tag (1→5) select from `codex` / `claude` / `claude:sonnet` … (backend or `backend:model`), default = primary agent; if no, all tags = primary agent
7. Permission mode — select; only `bypassPermissions` selectable, `default`/`acceptEdits` grayed "coming soon (needs approval UI)" [bypassPermissions]
8. Workspace root — input [~/code/aiur-workspaces]
9. Max concurrent agents — input num [10]
10. Max turns per issue — input num [20]
11. Pre-warmed sessions — input num [3]
12. Polling interval seconds — input num [30] (+ help: how often aiur re-checks the tracker for issues to pick up)
13. prompt_file — input [AIUR.md]

`max_vertical_panes` is NOT asked — hardcode default 3. Other settings (max_log_history_mb, timeouts, opencode/observability/server/worker/events, active/terminal states, hooks) use defaults.

Closing steps after the config is written:
- A. "Creating the labels aiur routes on…" → `create_labels` (existing)
- B. Walk through creating the GitHub **bot-account token** → set `GITHUB_TOKEN`
- C. *(linear only)* concise Linear API-key walkthrough + **prominent warning: Linear support is limited, please file issues if broken**

Routing values may be `backend` or `backend:model` (e.g. `claude:sonnet`) — requires extending `validate_agent_routing` to accept an optional `:model` suffix.

**Execution note:** Start from the existing `init_test.exs` injected-`io`/`deps` harness; assert on the written content rather than YAML round-trip.

**Test scenarios:**
- Covers AE4. Happy: github answers → written config contains the substituted `tracker.github.repo` and chosen agents, with the example's comments intact, and `create_labels` is invoked.
- Edge: accepting all defaults (empty input) yields the example's default values.
- Edge: list/map prompts (routing, agents) substitute into valid YAML.
- Error: a write failure surfaces `{:error, ...}` (existing path) without creating labels.

**Verification:** init writes a self-documenting config that parses (U1) and matches the prompted answers; labels still created.

---

- [ ] U6. **Route `aiurdev init` to the wizard**

**Goal:** `aiurdev init` ≡ `aiur init` (fix "no command").

**Requirements:** R9

**Dependencies:** None (wizard already exists; clean after U5 lands)

**Files:**
- Modify: `scripts/aiurdev` (case dispatch ~2168, usage ~341)
- Test: `src/test/scripts_aiurdev_test.exs`

**Approach:** add an `init)` case that execs `bin/aiur init` (forwarding `--force`/global flags), with the repo built/available; add an `init [--force]` line to usage.

**Test scenarios:**
- Covers AE5. Happy: `aiurdev init` invokes `./bin/aiur init` (assert via the test harness's command log) instead of "Unknown profile".
- Edge: `aiurdev init --force` forwards `--force`.

**Verification:** `aiurdev init` reaches the wizard; `--help` lists it.

---

### Phase C — Global config

- [ ] U7. **First prompt: repo-local vs global target**

**Goal:** `init` asks local vs global, writes `./.aiurconfig` or `~/.aiurconfig`, never overwrites, and the global omits repo-specific keys.

**Requirements:** R10, R11

**Dependencies:** U5

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Test: `src/test/aiur/init_test.exs`

**Approach:** add a first `prompt_choice` (repo-local/global); compute target path (`./.aiurconfig` vs `~/.aiurconfig`) via injected `deps`; run `guard_existing_config` against the chosen target; for global, omit the `tracker.github.repo` + `prompt_file` placeholders (leave them unset/commented).

**Test scenarios:**
- Covers AE6. Happy (global): writes `~/.aiurconfig` with no `tracker.github.repo`.
- Happy (local): writes `./.aiurconfig` (unchanged default behavior).
- Error: chosen target already exists + no `--force` → guard error, nothing written.

**Verification:** both targets supported; existing-file guard honored per target; global config has no repo.

---

- [ ] U8. **Local→global resolution + git-remote repo auto-detect**

**Goal:** Any aiur command uses local `./.aiurconfig`, else global `~/.aiurconfig` with the repo auto-detected from the cwd git remote.

**Requirements:** R12

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/workflow.ex` (resolution + global fallback), `src/lib/aiur/cli.ex` (run path / not-found message), and the repo-identity resolution (reuse `init.ex`'s `detect_repo/0` git parser — extract to a shared helper).
- Test: `src/test/aiur/workflow_test.exs` (or the config test), `src/test/aiur/cli_test.exs`

**Approach:** `workflow_file_path/0`: env override → `./.aiurconfig` → `~/.aiurconfig`. When the resolved config has no `tracker.github.repo`, fill it from the git remote of the cwd at load time. Update the "Config not found" message to mention `aiurdev init`.

**Test scenarios:**
- Covers AE6. Happy: no local config + a global `~/.aiurconfig` → global is used, repo filled from a stubbed git remote.
- Happy: local `./.aiurconfig` present → local wins (global ignored).
- Edge: neither present → clear "run aiurdev init" error.
- Edge: global used but no git remote detectable → defined behavior (error or unset repo, per Deferred question).

**Verification:** resolution order holds; global + auto-detected repo runs in a repo with no local config.

---

## System-Wide Impact

- **Interaction graph:** `Aiur.Config.Schema.parse/1` feeds `Config.settings!()` → every `*.Config` getter + `agent_*` accessors + `IssueLog`/`LogFile` paths; the schema restructure ripples to all config readers (intended; U2 covers it).
- **State lifecycle risks:** changing the schema breaks parsing of any unmigrated config — U3 must land with U1/U2; CI/test fixtures included.
- **API surface parity:** `aiur init` and `aiurdev init` must behave identically after U6; local and global write paths share the guard (U7).
- **Unchanged invariants:** setting *values*/runtime behavior are unchanged except the (already-effective) timeout promotion; `opencode`, `worker`, `observability`, `server`, `events`, `polling`, and the three top-level scalars keep their meaning.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Schema change breaks every config fixture mid-refactor | Land U1+U2+U3 together; run full suite before commit |
| `Config.section/1` has callers outside the three `*.Config` modules | Grep before deleting; keep if stragglers, file follow-up |
| Template substitution produces invalid YAML for list/map values | U5 tests cover routing/agents substitution; parse the result in-test |
| Global fallback with no git remote leaves repo unset | Define explicit behavior (Deferred question); test the edge |
| `aiurdev init` needs a built `bin/aiur` | Reuse the wrapper's existing build/ensure path before exec |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-15-config-consolidation-and-onboarding-requirements.md](docs/brainstorms/2026-06-15-config-consolidation-and-onboarding-requirements.md)
- Related code: `src/lib/aiur/config/schema.ex`, `src/lib/aiur/config.ex`, `src/lib/aiur/init.ex`, `src/lib/aiur/workflow.ex`, `src/lib/aiur/cli.ex`, `scripts/aiurdev`
