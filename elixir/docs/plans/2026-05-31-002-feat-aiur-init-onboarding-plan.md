---
title: "feat: aiur init onboarding command"
type: feat
status: active
date: 2026-05-31
origin: elixir/docs/brainstorms/2026-05-31-aiur-init-onboarding-requirements.md
---

# feat: aiur init onboarding command

## Overview

Add `aiur init`: a guided, foreground wizard run inside a target repo that
writes a pure-YAML `.aiurconfig` and, for GitHub trackers, creates the labels
aiur depends on. It prompts only for the decisions that branch behavior
(tracker, agents, concurrency), runs background auth checks that surface only
failures, and teaches complexity→model routing truthfully. The runtime learns
to auto-detect `.aiurconfig` in the run folder, and the prompt template moves
out of the config file.

This is the second of three tracked tickets (npm distribution → **aiur init** →
website chat-pane). It branches off `feat/npm-distribution` (#237) so it can
also route the npm launcher/shim for `init` (see Risks & Dependencies).

---

## Problem Frame

Starting aiur today means hand-authoring `WORKFLOW.md`: writing YAML front
matter from scratch with the correct tracker/agent sections and pre-creating the
GitHub labels the polling state machine and routing depend on. Nothing tells a
newcomer which keys exist, which labels must exist, or whether their agent CLI
is even logged in — so first runs usually fail on a missing token or label.
`aiur init` collapses that into one guided pass (see origin:
elixir/docs/brainstorms/2026-05-31-aiur-init-onboarding-requirements.md).

---

## Requirements Trace

- R1. `aiur init` runs as a foreground, interactive, line-based wizard (not the
  tmux-backed TUI), and exits without starting the orchestrator.
- R2. It writes a pure-YAML `.aiurconfig` (no prompt-template body) to the run
  folder. (origin D1)
- R3. The runtime auto-detects `.aiurconfig` in the run folder; the prompt
  template is sourced outside the config file. (origin D1)
- R4. The wizard walks each prompted section in order with the schema default
  pre-filled. (origin D2)
- R5. Prompted sections are exactly: tracker + repo/keys; agent model(s) + auth;
  concurrency. All other sections are written from schema defaults and not
  asked. (origin D3)
- R6. Auth checks run per chosen agent and tracker, stay silent on success, and
  on failure show a specific fix hint with inline retry/skip — then write
  `.aiurconfig` regardless. (origin D4)
- R7. If `.aiurconfig` (or a legacy `WORKFLOW.md`) already exists, abort unless
  `--force` is passed. (origin D5)
- R8. For GitHub trackers, the wizard idempotently creates three label families
  — state (`<prefix>:<state>`), model (`model:<backend>[-<variant>]`), and
  complexity (`complexity:1`–`complexity:5`) — announcing concisely what it is
  doing and defining each family inline. No "used aiur before?" question.
  (origin D6)
- R9. The wizard writes a starter `agent.routing` table and teaches that
  `complexity:<n>` changes which model handles an issue — and only that; it must
  not claim complexity selects skills or prompts. (origin D7)

**Origin actors:** end user setting up aiur in their repo (only actor).
**Origin flows:** F1 init in a fresh repo → working `.aiurconfig`; F2 init with
GitHub tracker → labels created; F3 init over an existing config → error unless
`--force`.

---

## Scope Boundaries

- No per-complexity skill or prompt selection (no such config dimension exists;
  would be new routing work — its own ticket). (origin D7)
- No in-place merge/migration of an existing config; v1 is error-unless-`--force`.
  (origin D5)
- No interactive "tag an issue and watch an agent pick it up" walkthrough.
- No Linear label/tag auto-creation — Linear is configured but the label step is
  GitHub-only. (origin open question)
- Workspace, opencode, server, polling, events, hooks, observability sections are
  not prompted — written from schema defaults only.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/cli.ex` — `evaluate/1` parses argv with `OptionParser`
  (strict switches) and has **no subcommand concept**: a bare positional like
  `init` currently falls into the `{opts, [workflow_path], []}` branch and is
  treated as a workflow path. `main/1` always `wait_for_shutdown()`s after `:ok`;
  the `{:version, _}` branch is the model for a one-shot that prints and exits.
  `runtime_deps/0` is the dependency-injection seam to mirror for testability.
- `elixir/lib/aiur/workflow.ex` — `@workflow_file_name "WORKFLOW.md"`,
  `workflow_file_path/0` resolves `Application.get_env(:aiur, :workflow_file_path)`
  or `Path.join(File.cwd!(), @workflow_file_name)`. Front matter split + YAML
  parse live in `parse/1` / `split_front_matter/1`. This is where `.aiurconfig`
  auto-detection lands.
- `elixir/lib/aiur/config.ex` — `@default_prompt_template`, `Schema.parse/1`,
  tracker/agent kind inference (`inferred_tracker_kind/1`,
  `inferred_agent_kind/1`), and `format_config_error/1` (WORKFLOW.md-specific
  strings). Prompt template currently comes from the file body via
  `workflow_prompt/0`.
- `elixir/lib/aiur/config/schema.ex` — all section defaults (poll 30s,
  max_concurrent_agents 10, max_vertical_panes 3, pre_warmed_sessions 3, server
  127.0.0.1, etc.) and `normalize_agent_routing/1`/`validate_agent_routing/2`.
  Authoritative source for the values the wizard writes for unprompted sections.
- `elixir/lib/aiur/coding_agent.ex` — `backends/0` (claude models: opus, sonnet,
  opus-4-8, sonnet-4-6, haiku-4-5; codex: gpt-5.5), `known_backends/0`,
  `override_labels/0` (canonical `model:*` labels to create), routing precedence
  `model:` override → `complexity:` via `agent.routing` → `agent.kind`.
- `elixir/lib/aiur/github/config.ex` — `repo/0`, `token/0` (from `GITHUB_TOKEN`),
  `label_prefix/0` (default `aiur`; this repo uses `agent`), `validate!/0`.
- `elixir/lib/aiur/github/client.ex` — REST client using `GITHUB_TOKEN`; state
  labels are `"#{prefix}:#{normalize_state(state)}"` (lines 325, 399). Mirror its
  request shape for a label-create call.
- `elixir/lib/aiur/test_reset.ex` — enumerates the full live state-label set
  (`agent:todo, agent:in-progress, agent:human-review, agent:rework,
  agent:merging, agent:done, agent:error, agent:cancelled`); shells out to `gh`.
- `elixir/lib/aiur/{claude,codex,opencode}/config.ex` — `command/0` + `validate!/0`
  per backend (claude default `aiur-claude`, codex default `codex app-server`).
  Auth checks build on `command/0` resolution.
- `packaging/npm/aiur-cli/bin/aiur.js` — `main/0` runs `preflightTmux()` (fatal)
  and `preflightOpencode()` (warn) **unconditionally** before exec'ing the
  launcher. Must skip these for foreground subcommands (`init`, `--version`).
- `packaging/npm/aiur-cli/libexec/aiur-launch.sh` — has a `--version` one-shot
  foreground path (lines 103-112: `prepare_distribution`, `build_release_cmd`,
  exec, no tmux). `init` extends this path.

### Institutional Learnings

- Manual CLI verification convention (memory: manual-cli-verification): drive
  features end-to-end before declaring done. For a foreground, line-based wizard
  the direct path is `mix run -e` / a focused module test with injected IO — not
  the wrapper-tmux TUI recipe (which is for the full-screen UI).
- `gh pr edit` is buggy on this repo's classic-Projects setup; patch PR bodies
  via REST API instead (memory: gh-pr-edit-projects-bug).

### External References

None needed — this is convention-following Elixir CLI work with strong local
patterns (OptionParser dispatch, deps injection, existing REST client).

---

## Key Technical Decisions

- **Subcommand dispatch by leading positional.** Detect `init` as the first
  positional arg in `evaluate/1` before the workflow-path branch, returning a
  new `{:init, opts}` (with `--force`) that `main/1` handles by running the
  wizard synchronously and exiting 0/1 — never `wait_for_shutdown()`. Keeps the
  bare/`<path>`/`--version` branches intact.
- **`Aiur.Init` module with injected IO + deps.** Put wizard logic in a new
  `Aiur.Init` module taking an `io` (prompt/read/print) and a `deps` map
  (file_exists?, write_file, label-create fn, auth-check fns, repo-detect fn),
  mirroring `Aiur.CLI.deps`. This makes the whole wizard unit-testable with fake
  IO and no network/filesystem side effects.
- **`.aiurconfig` is pure YAML.** `aiur init` writes a YAML document (no `---`
  front-matter fences, no prompt body). Runtime detection reads it as a plain
  YAML map. The prompt template is sourced from `@default_prompt_template`
  (built-in) unless a separate prompt file is configured — exact mechanism in
  Open Questions.
- **Parse mode keys off filename, not fence presence.** When the resolved file
  is `.aiurconfig`, parse the **whole file as YAML config** (empty prompt →
  default template). When it is `WORKFLOW.md`, use today's `split_front_matter/1`
  behavior **unchanged**. This avoids a silent semantic flip: today a fence-less
  file is treated as all-prompt-body/empty-config (`workflow.ex:85-100`), so
  keying pure-YAML on "no `---`" would misparse any existing fence-less
  `WORKFLOW.md`. Filename is the safe discriminator.
- **Runtime auto-detection order.** `workflow_file_path/0` resolves, in order:
  explicit `Application.get_env(:aiur, :workflow_file_path)` → `.aiurconfig` in
  cwd → legacy `WORKFLOW.md` in cwd. The resolved filename selects the parse
  mode above.
- **YAML serialization: add a YAML encoder dep.** YamlElixir (`mix.exs:156`)
  exposes only `read_*` — it cannot serialize. Add a small pure-Elixir YAML
  encoder (`{:ymlr, "~> 5.0}` or equivalent) for writing `.aiurconfig`. Do
  **not** hand-roll a writer: nested sections, the `agent.routing` map, and
  string/int/bool typing make round-trip fidelity error-prone. The round-trip
  test (emit → `Workflow.load` → `Config.settings`) is the correctness guard.
- **GitHub access via `GITHUB_TOKEN` REST**, consistent with the runtime client
  — so init validates the *same* credential aiur will use at runtime. **No
  `gh auth token` fallback:** the runtime only reads `GITHUB_TOKEN`
  (`github/config.ex:26`), and `gh` is not a declared dependency of the npm
  distribution — a `gh`-minted token would validate a credential the
  orchestrator never sees (false-positive auth). If `GITHUB_TOKEN` is unset, the
  auth check simply warns with a fix hint. Label creation uses the same REST
  path (idempotent: treat HTTP 422 with error code `already_exists` as success;
  surface other 422s as real validation errors).
- **Label set is derived, not hardcoded.** State labels from chosen
  `label_prefix` × (active_states ++ terminal_states); model labels from
  `Aiur.CodingAgent.override_labels/0` filtered to chosen backends; complexity
  labels `complexity:1..5`.
- **Starter routing table.** Write `agent.routing` mapping low complexity →
  primary chosen agent, high → secondary (e.g. `1-2 → claude, 3-5 → codex`);
  when only one agent is chosen, route all levels to it.
- **npm shim foreground gating.** `bin/aiur.js` skips tmux/opencode preflight
  when the first non-flag arg is `init` (and for `--version`); `aiur-launch.sh`
  routes `init` through the existing one-shot foreground exec.

---

## Open Questions

### Resolved During Planning

- Where does `aiur init` dispatch live? → `Aiur.CLI.evaluate/1` leading-positional
  branch + `Aiur.Init` module.
- How is it verified without tmux? → `Aiur.Init` with injected IO/deps; direct
  `mix` test + `mix run -e` manual drive.
- Branch strategy? → single branch off `feat/npm-distribution` (user decision);
  one PR carries Elixir + shim routing.
- Which credential does the GitHub auth check validate? → `GITHUB_TOKEN` (runtime
  credential), with `gh auth token` fallback to populate it.

### Deferred to Implementation

- **Prompt-template relocation mechanism:** built-in `@default_prompt_template`
  only, vs. a `prompt_template_path` key pointing to a separate file, vs. writing
  a starter prompt file next to `.aiurconfig`. Pick during U2 once the YAML
  shape is concrete; default to built-in template if undecided.
- **Legacy `WORKFLOW.md` fallback longevity:** keep indefinitely vs. emit a
  deprecation notice. Decide in U2; no removal in this ticket.
- **Exact agent auth probe depth:** command-on-PATH check vs. a cheap
  `--version`/whoami probe per backend. Resolve in U4 against the real CLIs.
- **`label_prefix` default offered by the wizard:** code default `aiur` vs. this
  repo's `agent`. **Hard dependency for U6** (it derives state labels from the
  prefix) — must be resolved during U3 before U6 begins, not left open at the
  unit boundary. Offer one as the pre-filled default.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
aiur init [--force]
  │
  ▼
Aiur.CLI.evaluate(["init" | opts])  ──►  {:init, %{force: bool}}
  │                                         (no app start, no wait_for_shutdown)
  ▼
Aiur.Init.run(io, deps)
  1. preflight: .aiurconfig / WORKFLOW.md exists?  ──► error unless --force
  2. prompt: tracker kind ─► github→repo(detect)+label_prefix | linear→key+slug | memory
  3. prompt: agents (claude/codex) + model(s)         ─┐
       background auth check per chosen agent           │ warn+retry/skip
  4. tracker auth check (GITHUB_TOKEN / linear key)    ─┘ then continue
  5. prompt: concurrency (max_concurrent_agents, max_vertical_panes, pre_warmed_sessions)
  6. assemble config map: prompted answers + schema defaults + starter agent.routing
  7. write .aiurconfig (pure YAML)
  8. if github: create label families (state/model/complexity), explain each inline
  9. print next-steps summary (complexity→model routing taught truthfully)
```

---

## Implementation Units

- [ ] U0. **Phase 0 de-risk spike: interactive stdin through the release/launcher**

**Goal:** Prove that a synchronous `IO.gets`-based prompt actually receives
keystrokes when `aiur` runs as the relocated `mix release` exec'd from the npm
Node shim — *before* building the wizard on that assumption.

**Why:** The only proven foreground path in `aiur-launch.sh` is `--version`
(lines 103-112), which writes stdout and **never reads stdin**. The BEAM boots
via `elixir --eval "Aiur.CLI.main(...)"` with `--boot start_clean`; whether the
standard-io group leader delivers an interactive TTY to `IO.gets` under that
invocation is untested. The npm distribution backgrounds the BEAM in tmux
precisely because the orchestrator paints no usable foreground TTY. If `IO.gets`
returns `:eof` or hangs here, U3-U6 are wasted — every mocked test would pass
while production is dead on arrival.

**Approach:**
- Add a throwaway `{:init, _}` arm (or a temporary `--init-probe`) that does a
  single `IO.gets("probe> ")` and prints what it read, then exits.
- Build/relocate a prod release and run it through the actual launcher one-shot
  foreground path (and separately via `mix run -e`), typing a line at a real
  terminal. Confirm the typed line is echoed back.
- Record the result. If stdin does **not** arrive, stop and resolve the boot
  invocation (e.g. a different `--eval`/`-noshell`/`-noinput` posture, or a
  `bin/aiur start`-style foreground) before proceeding — this becomes the real
  U1/U7 design constraint.

**Verification:** a typed line is read by `IO.gets` through both the launcher
exec path and `mix run -e`. Gate U3-U6 on this passing.

**Note:** also confirms the favorable boot invariant — `--boot start_clean`
(`mix.exs:236`, `aiur-launch.sh:56`) loads but does not auto-start `:aiur`, so
skipping `ensure_all_started/0` for `init` means no pollers/supervisors run. The
wizard's safety depends on this; if the boot script ever changes to auto-start
apps, `init` would boot the full orchestrator. Document this invariant.

---

- [ ] U1. **CLI subcommand dispatch for `init`**

**Goal:** Route `aiur init [--force]` to a foreground wizard path that runs
synchronously and exits, without starting the orchestrator or waiting for
shutdown.

**Requirements:** R1, R7

**Dependencies:** None

**Files:**
- Modify: `elixir/lib/aiur/cli.ex`
- Test: `elixir/test/aiur/cli_test.exs` (or existing CLI test file if named
  differently — discover before writing)

**Approach:**
- Add a leading-positional check in `evaluate/1`: when the first positional arg
  is `"init"`, parse remaining args for `--force` and return `{:init, %{force:
  force?}}`. Keep the bare, `<path>`, and `--version` branches unchanged.
- Add `--force` to `@switches` (boolean), scoped so it only has meaning for
  `init` (other branches ignore it / reject as today).
- Handle `{:init, opts}` in `main/1` by calling the production entry
  `Aiur.Init.run/1` (takes `opts`, internally wires real IO + deps and delegates
  to `run/3` — see U3) and exiting 0 on `:ok`, 1 on `{:error, _}` — mirroring the
  `{:version, _}` and `{:error, _}` arms; never call `wait_for_shutdown/0` and
  never call `ensure_all_started/0` (keeps the app un-booted per U0).
- Update `usage_message/0` to mention `init`.

**Patterns to follow:** the `{:version, @version}` arm of `evaluate/1` and its
`main/1` handling; `runtime_deps/0` injection style.

**Test scenarios:**
- Happy path: `evaluate(["init"])` returns `{:init, %{force: false}}`.
- Happy path: `evaluate(["init", "--force"])` returns `{:init, %{force: true}}`.
- Edge: `evaluate([])` still routes to the WORKFLOW.md run branch (unchanged).
- Edge: `evaluate(["some/path"])` still treats it as a workflow path (init
  detection must not swallow arbitrary positionals).
- Covers F3 / R7: dispatch surfaces `--force` so the wizard can enforce the
  existing-file guard.

**Verification:** `aiur init` reaches the wizard; no orchestrator boot; exit code
reflects wizard result; existing CLI behaviors unchanged.

---

- [ ] U2. **`.aiurconfig` runtime auto-detection + pure-YAML parse**

**Goal:** Teach the runtime to find and parse `.aiurconfig` (pure YAML) in the
run folder, falling back to legacy `WORKFLOW.md`, and source the prompt template
outside the config file.

**Requirements:** R2, R3

**Dependencies:** None (independent of U1; U6 writes files this reads)

**Files:**
- Modify: `elixir/lib/aiur/workflow.ex`
- Modify: `elixir/lib/aiur/config.ex` (prompt-template sourcing + error strings)
- Test: `elixir/test/aiur/workflow_test.exs` (discover exact path/name first)

**Approach:**
- In `workflow_file_path/0`, resolve in order: `Application.get_env` override →
  `.aiurconfig` in `File.cwd!()` → `WORKFLOW.md` in `File.cwd!()`. Carry the
  resolved filename forward so `parse/1` can branch on it.
- Branch parse mode on **filename, not fence**: `.aiurconfig` → parse the whole
  file as YAML config (empty prompt); `WORKFLOW.md` → today's
  `split_front_matter/1` behavior **unchanged**. Do not change the fence-less
  handling of `WORKFLOW.md` — that path currently means all-prompt-body and must
  stay that way for back-compat.
- `Aiur.Config.workflow_prompt/0`: when the loaded prompt is empty (pure-YAML
  `.aiurconfig`), fall back to `@default_prompt_template` (already the empty-body
  behavior — confirm it still holds for the no-body case).
- Generalize `format_config_error/1` strings so they don't hardcode "WORKFLOW.md"
  when the active file is `.aiurconfig`.

**Execution note:** characterization-first — capture current `WORKFLOW.md`
load/parse behavior in tests before adding `.aiurconfig` so back-compat is
provably preserved.

**Patterns to follow:** existing `split_front_matter/1` and the YamlElixir parse
in `front_matter_yaml_to_map/1`.

**Test scenarios:**
- Happy path: a pure-YAML `.aiurconfig` (no `---`) loads as config map with
  empty prompt; `workflow_prompt/0` returns the default template.
- Happy path: a fenced legacy `WORKFLOW.md` still loads config + body prompt
  unchanged (characterization).
- Edge: both `.aiurconfig` and `WORKFLOW.md` present → `.aiurconfig` wins.
- Edge: explicit `Application.get_env` path overrides both.
- Error: malformed YAML in `.aiurconfig` → error mentions `.aiurconfig`, not
  `WORKFLOW.md`.
- Covers F1 / R3: `.aiurconfig` in the run folder is auto-detected.

**Verification:** runtime loads `.aiurconfig` with no explicit path; legacy
`WORKFLOW.md` repos keep working; error messages name the right file.

---

- [ ] U3. **Tracker + repo/keys prompts and config assembly**

**Goal:** Prompt the tracker section (github/linear/memory) with repo
auto-detection and key entry, and assemble the full config map (prompted answers
+ schema defaults + starter `agent.routing`).

**Requirements:** R2, R4, R5, R9

**Dependencies:** U1 (dispatch)

**Files:**
- Create: `elixir/lib/aiur/init.ex`
- Create: `elixir/test/aiur/init_test.exs`

**Approach:**
- Define `Aiur.Init.run/3` taking `opts` (the `%{force: bool}` from U1), `io`,
  and `deps`; the production `run/1` wires real IO + deps and delegates to
  `run/3`. `io` exposes prompt-with-default and print; `deps` exposes
  `detect_repo` (parse `git remote get-url origin`), `write_file`,
  `file_exists?`, label-create and auth-check fns (used by U4/U5). The injected
  IO+deps seam is a **deliberate** testability choice (mirrors
  `Aiur.CLI.runtime_deps/0`) so the whole wizard is unit-testable with fake IO
  and zero side effects — accepted over a thinner seam because the wizard's
  network/filesystem/prompt surface is wide enough to warrant full isolation.
- Enforce R7 first: if `.aiurconfig`/`WORKFLOW.md` exists and `--force` not set,
  return `{:error, :exists}` with a message instructing `--force`.
- Tracker prompt: github → repo (pre-filled from detected remote, confirm) +
  `label_prefix` (default per Open Questions); linear → API key + project slug;
  memory → nothing further.
- Assemble config: prompted sections + every unprompted section from
  `Schema` defaults + a starter `agent.routing` (U9 logic). Tracker/agent kind
  follow the existing inference (presence of section) — write the section so
  inference resolves correctly.
- Serialize to pure YAML using a YAML encoder dep (`ymlr` or equivalent) added
  in `mix.exs` — YamlElixir cannot write. Do not hand-roll a writer.

**Patterns to follow:** `Aiur.CLI.deps` injection; `Aiur.Config`
inference helpers; `Aiur.Config.Schema` default values.

**Test scenarios:**
- Happy path: github tracker with detected repo → config map has
  `tracker.kind=github`, `github.repo`, `github.label_prefix`, and all default
  sections present.
- Happy path: linear tracker → `linear.api_key` + `linear.project_slug` written,
  `tracker.kind` resolves to linear.
- Happy path: memory tracker → minimal config, `tracker.kind=memory`.
- Edge: no git remote → repo prompt has no pre-fill, user enters it manually.
- Edge: emitted YAML round-trips through `Aiur.Workflow.load/1` +
  `Aiur.Config.settings/0` to a valid `Schema` (integration with U2).
- Error/R7: existing config without `--force` → `{:error, :exists}`, nothing
  written.
- Covers F1: fresh repo → valid `.aiurconfig` map.

**Verification:** assembled config loads cleanly via the U2 path and validates
against `Schema`; existing-file guard works.

---

- [ ] U4. **Agent selection + background auth checks**

**Goal:** Prompt which agents (claude/codex) and model(s), run per-agent +
per-tracker auth checks that stay silent on success and warn with inline
retry/skip on failure, then continue regardless.

**Requirements:** R5, R6

**Dependencies:** U3 (Init module + deps)

**Files:**
- Modify: `elixir/lib/aiur/init.ex`
- Modify: `elixir/test/aiur/init_test.exs`

**Approach:**
- Agent prompt: multi-select claude/codex (≥1 required); per chosen agent, prompt
  model with a default from `Aiur.CodingAgent.backends/0` models.
- Auth checks via injected `deps` fns so tests never touch real CLIs/network:
  - claude/codex: resolve `command/0` on PATH (+ optional cheap probe — depth
    deferred per Open Questions).
  - github: `GITHUB_TOKEN` present and a REST identity call succeeds (reuse the
    client request shape). No `gh auth token` fallback — validate the exact
    credential the runtime reads.
  - linear: API key present and a cheap GraphQL identity call succeeds.
- On failure: print the specific error + fix hint (e.g. `run claude login`,
  `export GITHUB_TOKEN=…`), offer retry / skip; on skip or after retry, proceed
  to write the config anyway (R6).

**Patterns to follow:** `Aiur.{Claude,Codex,GitHub,Linear}.Config.validate!/0`
error message style; deps injection from U3.

**Test scenarios:**
- Happy path: all chosen auth checks pass → no auth output, wizard proceeds.
- Edge: claude chosen, codex not → only claude auth checked.
- Error path: github token missing → warn with fix hint; choosing "skip" still
  writes config (R6).
- Error path: auth check fails then retry succeeds → no residual warning.
- Edge: zero agents selected → wizard re-prompts (≥1 required).
- Covers R6: a failing auth check never blocks `.aiurconfig` from being written.

**Verification:** auth failures are visible and actionable but never fatal;
success is silent; config always written after this step.

---

- [ ] U5. **Concurrency prompts + write `.aiurconfig`**

**Goal:** Prompt the concurrency knobs and write the assembled config to
`.aiurconfig` in the run folder.

**Requirements:** R2, R4, R5

**Dependencies:** U3, U4

**Files:**
- Modify: `elixir/lib/aiur/init.ex`
- Modify: `elixir/test/aiur/init_test.exs`

**Approach:**
- Prompt `max_concurrent_agents`, `max_vertical_panes`, `pre_warmed_sessions`,
  each pre-filled with the `Schema` default and accept-on-enter.
- Validate numeric input (positive integer; `pre_warmed_sessions` allows 0);
  re-prompt on invalid.
- Write the final YAML to `.aiurconfig` via `deps.write_file` (plain
  `File.write/2`; report the written path). No atomic temp+rename — an
  interrupted one-shot wizard is recoverable by re-running `aiur init --force`,
  so write atomicity is unjustified complexity for v1.

**Patterns to follow:** schema defaults in `Aiur.Config.Schema`; existing numeric
parsing conventions in the codebase.

**Test scenarios:**
- Happy path: accept all defaults → `.aiurconfig` written with default
  concurrency values.
- Edge: custom values within range → reflected in output.
- Error: non-numeric / negative input → re-prompt, not written until valid.
- Edge: `pre_warmed_sessions = 0` accepted (valid disable).

**Verification:** `.aiurconfig` exists with correct concurrency keys and parses
via U2.

---

- [ ] U6. **GitHub label auto-creation with inline explanations**

**Goal:** For GitHub trackers, idempotently create the three label families and
explain each concisely as it goes; print a truthful complexity→model routing
summary at the end.

**Requirements:** R8, R9

**Dependencies:** U3, U5

**Files:**
- Create: `elixir/lib/aiur/github/labels.ex` (label-create REST helper)
- Modify: `elixir/lib/aiur/init.ex`
- Create: `elixir/test/aiur/github/labels_test.exs`
- Modify: `elixir/test/aiur/init_test.exs`

**Approach:**
- Derive the label set:
  - state: `label_prefix` × `normalize_state(state)` for active_states ++
    terminal_states (mirror `client.ex` formatting; full live set per
    `test_reset.ex`).
  - model: `Aiur.CodingAgent.override_labels/0` filtered to chosen backends.
  - complexity: `complexity:1`..`complexity:5`.
- `Aiur.GitHub.Labels.ensure/…`: POST each label via REST with `GITHUB_TOKEN`,
  mirroring `Client` headers (`Authorization: Bearer`, `Accept:
  application/vnd.github+json`); treat HTTP 422 with error code `already_exists`
  as success (idempotent), but surface other 422s (bad color/name) as real
  errors. Network calls behind an injected request fn for tests.
- In `Aiur.Init`: before creating, print a one-line "about to create labels in
  owner/repo and why" plus a one-line definition of each family; on missing
  token / no write scope, warn and skip (consistent with R6 posture).
- Final summary teaches: a `complexity:<n>` label routes an issue to the agent
  mapped at that level in `agent.routing`; explicitly do **not** claim it changes
  skills or prompts (R9).

**Patterns to follow:** `Aiur.GitHub.Client` request/header shape and
`normalize_state/1`; `Aiur.CodingAgent.override_labels/0`.

**Test scenarios:**
- Happy path: github tracker, claude+codex → label set = state(prefix×states) +
  model(claude/codex variants) + complexity:1..5; create called for each.
- Edge: label already exists (HTTP 422) → treated as success, no error.
- Edge: only claude chosen → no `model:codex*` labels created.
- Error path: missing `GITHUB_TOKEN`/write scope → warn + skip, wizard still
  completes (R6).
- Edge: non-github tracker → no label step runs at all.
- Covers R8/R9: families derived correctly; routing summary names models only.

**Verification:** running against a test repo creates exactly the derived labels
(idempotently); summary text is accurate to current routing behavior.

---

- [ ] U7. **npm shim/launcher foreground routing for `init`**

**Goal:** Make the npm-distributed `aiur init` run as a foreground wizard without
requiring tmux.

**Requirements:** R1

**Dependencies:** U1 (the `init` subcommand must exist to route to)

**Files:**
- Modify: `packaging/npm/aiur-cli/bin/aiur.js`
- Modify: `packaging/npm/aiur-cli/libexec/aiur-launch.sh`
- Modify: `packaging/npm/aiur-cli/test/launcher.test.mjs`

**Approach:**
- `bin/aiur.js`: when the first non-flag arg is `init` (and for `--version`),
  skip `preflightTmux()` and `preflightOpencode()` before exec'ing the launcher.
- `aiur-launch.sh`: extend the existing one-shot detection (currently
  `--version`, lines 103-112) so a leading `init` also takes the foreground
  `exec` path (stdin inherited for interactive prompts), bypassing the tmux
  session block. **`init` should boot distribution-free** — the named-node env
  contract (`RELEASE_NODE=aiur-${USER}@127.0.0.1`) collides with a running TUI
  session's node; `init` needs no opencode RPC, so route it through a
  no-distribution exec rather than reusing the `--version` named-node invocation
  verbatim. (Exact posture confirmed by U0.)

**Patterns to follow:** the existing `--version` one-shot block in
`aiur-launch.sh`; the preflight structure in `bin/aiur.js`.

**Test scenarios:**
- Happy path (bun shim test): `aiur init` execs the launcher with no tmux
  preflight failure even when tmux is absent from PATH.
- Edge: `aiur --version` likewise skips tmux preflight (regression-proof the
  shared foreground gate).
- Edge: a bare interactive run still requires tmux (preflight unchanged).
- Integration: launcher routes `init` to a foreground exec (no `new-session`),
  asserted via the existing fake-bash-launcher argv/env capture harness.

**Verification:** on a tmux-less machine the shim reaches the BEAM for `init`;
the interactive TUI path still hard-requires tmux.

---

## System-Wide Impact

- **Interaction graph:** `Aiur.CLI.main/1` gains an `init` arm that must not boot
  the OTP app or call `wait_for_shutdown/0`. `Aiur.Workflow.workflow_file_path/0`
  is read by `WorkflowStore` and `Aiur.Config` throughout — the detection-order
  change affects every config read; back-compat with `WORKFLOW.md` is the guard.
- **Error propagation:** auth-check and label-create failures are warn-and-continue
  (R6/R8), never raised; only the existing-file guard (R7) and unrecoverable IO
  errors yield a non-zero exit.
- **State lifecycle risks:** a half-written `.aiurconfig` from an interrupted
  wizard is recovered by re-running `aiur init --force`; no atomic-write
  machinery for v1.
- **Memory tracker has no github section:** a `memory`-tracker `.aiurconfig`
  writes no github keys; add a test that booting the runtime with such a config
  performs zero github access (no `validate!/0` on github, no token read), so the
  inference-by-section-presence contract is provably safe for the no-github case.
- **API surface parity:** `aiur init` must behave the same via the npm shim
  (U7), the dev `scripts/aiur` (not modified here — dev path uses `mix`), and
  direct `mix run -e`. The shared `Aiur.Init` module is the single source of
  truth.
- **Integration coverage:** U3+U2 round-trip (emitted YAML re-parses to a valid
  `Schema`) is the key cross-layer test mocks won't prove.
- **Unchanged invariants:** legacy `WORKFLOW.md` front-matter+body repos keep
  loading exactly as before; the schema, routing precedence, and label formats
  are consumed unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| **Interactive `IO.gets` may not receive stdin through the relocated release exec'd by the Node shim** (the `--version` foreground path only writes stdout) — would silently kill the feature while mocked tests pass | **U0 Phase 0 spike** proves a typed line reaches `IO.gets` through both the launcher exec and `mix run -e` before U3-U6 are built; if it fails, resolve the boot invocation first. |
| Branch depends on unmerged #237 (packaging files live there) | Ticket branches off `feat/npm-distribution`; PR targets main but is sequenced to merge after #237. Flag the ordering in the PR. |
| `.aiurconfig` detection breaks existing `WORKFLOW.md` repos | Characterization tests (U2) lock current behavior; `.aiurconfig` is additive with explicit fallback. |
| Interactive wizard is hard to test | `Aiur.Init` takes injected IO + deps; all prompts/network/file ops are faked in unit tests; manual drive via `mix run -e`. |
| YAML serialization fidelity (key order, types) | Round-trip test (emit → `Workflow.load` → `Config.settings`) asserts a valid `Schema`; prefer an existing YAML encoder dep over hand-rolling. |
| GitHub auth check validates a different credential than runtime uses | Check `GITHUB_TOKEN` (the *exact* runtime credential) via a real REST identity call. No `gh auth token` fallback — `gh` isn't a declared dep and a `gh`-minted token isn't what the runtime reads (`github/config.ex:26`), which would yield false-positive auth. |
| Label creation partial failure | Idempotent create (422 = success); warn-and-continue so a flaky label call never aborts the wizard. |

---

## Documentation / Operational Notes

- Update any in-repo references that instruct users to author `WORKFLOW.md` to
  mention `aiur init` / `.aiurconfig` (README / AGENTS.md if applicable —
  discover during implementation; do not invent docs).
- No migration required; legacy `WORKFLOW.md` continues to work.

---

## Sources & References

- **Origin document:** elixir/docs/brainstorms/2026-05-31-aiur-init-onboarding-requirements.md
- Related code: `elixir/lib/aiur/{cli,workflow,config,coding_agent}.ex`,
  `elixir/lib/aiur/github/{config,client}.ex`, `elixir/lib/aiur/config/schema.ex`,
  `packaging/npm/aiur-cli/bin/aiur.js`, `packaging/npm/aiur-cli/libexec/aiur-launch.sh`
- Related issues: #23 (this ticket), #28 / PR #237 (npm distribution, branch base)
