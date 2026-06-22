---
title: "feat: Repo-agnostic eager prewarm for agent workspaces"
type: feat
status: active
date: 2026-06-22
origin: docs/brainstorms/2026-06-22-prewarm-design-research-and-questions.md
---

# feat: Repo-agnostic eager prewarm for agent workspaces

## Overview

Today every dispatched agent cold-boots its own workspace: the `after_create` shell hook runs a
full `git clone` + `mix deps.get` + `mix compile`. With N agents at once these self-contend — a
measured 16-agent run hit a **mean 249 s** per hook and crashed before any agent did useful work
(`docs/measurements/2026-06-22-prewarm-run-findings.md`).

This feature makes aiur maintain **one warm, pre-compiled base of the repo's latest main** and
materialize each per-issue workspace from it via copy-on-write — collapsing N redundant compiles to
**1**. Crucially, and unlike the unmerged #377 prototype, the user writes **no repo-specific build
shell**: aiur **detects the toolchain** at `aiur init` (Elixir/Node/Go/Rust/Python) to fill the
one-time base build command, and **aiur itself owns the per-workspace copy**. The base build runs
**eagerly before the first dispatch** with a loading bar in the agent list, and stays warm by
rebuilding on every `main` advance (preempting stale in-flight builds).

The PR also lands the cheapest audit-backed fork-reducers so a `--debug` run survives 16 tickets;
the structural `:emfile`/process-efficiency fixes are deferred to
[#409](https://github.com/its-everdred/aiur/issues/409).

---

## Problem Frame

Cold per-dispatch boot wastes wall-clock, tokens, and CPU and degrades with concurrency. The fix
must (a) keep a warm, main-tracking, pre-compiled base; (b) impose **no** language/toolchain
assumption or build shell on the user (aiur detects it); (c) remain progressive — unconfigured,
remote, or undetected repos still work via the existing cold-clone path; and (d) start the base
build **before** agents are dispatched, with operator-visible progress. See origin:
`docs/brainstorms/2026-06-22-prewarm-design-research-and-questions.md`.

---

## Requirements Trace

- R1. aiur maintains one warm base per repo at `~/.aiur/repo/<owner>/<name>`, kept at latest
  `origin/main`, deps installed + compiled.
- R2. The base is rebuilt on **every** `main` advance; a newer advance **preempts** an in-flight
  stale build (no debounce) so agents never spin off a stale base.
- R3. aiur **detects** the build command at `aiur init` for Elixir/Node/Go/Rust/Python via
  lockfile/manifest with a build-**root** walk; routes it through `mise exec --`; wraps `|| true`.
  Dockerfile/CI reuse is **not** attempted. Undetected/exotic → an agent-prompt fallback.
- R4. The detected build command is **shown for confirmation** (accept/edit/skip) before it is
  written to config or first executed.
- R5. Pre-warm is **opt-in** — a final `aiur init` prompt, or a `prewarm` config flag — and runs
  **eagerly before the first dispatch**, **without blocking** the orchestrator process.
- R6. aiur (in Elixir) **owns** per-workspace materialization, copying the built base via
  `cp --reflink=auto -a` (Linux) / `cp -c` (macOS), degrading to a full copy on ext4.
- R7. The agent list shows a **loading bar + rotating phase labels** before agents populate, driven
  by RepoBase phase events; a launch during an in-flight build **resumes at the live phase**; the
  bar clears on the first populated running list.
- R8. The cold-clone path is preserved **byte-for-byte** for unconfigured / remote / undetected /
  copy-failed repos.
- R9. `--debug` is safe at ~16 tickets: the in-scope fork-reducers cut steady-state tmux forks and
  decouple the per-pane `capture-pane` screen-grab loop from `--debug`; `ulimit -n` is raised in the
  launch shims.
- R10. aiur dogfoods the feature on itself; a throttled re-measurement (4–6 agents, raised `ulimit`)
  confirms the boot→first-message win.

**Origin actors:** A1 dev/operator (`aiur init`, `aiur`), A2 dev's coding agent (fallback hook
author only, when detection misses), A3 aiur warm-base maintainer (`RepoBase`), A4 per-issue agents.
**Origin flows:** F1 init opt-in + detect + consent, F2 eager warm-base refresh (+ preempt), F3
workspace materialization from base.

---

## Scope Boundaries

- No Dockerfile/CI parsing to derive the build (research verdict: dead end; the fallback agent may
  *read* them, aiur does not parse them).
- No forced container runtime or language assumption.
- No multi-host / remote warm-base sync (local-machine-first; remote dispatch uses the cold path).
- No change to the opencode chat-display architecture beyond the in-scope cheap fork-reducers.

### Deferred to Follow-Up Work

- **Structural `:emfile` / process-efficiency fixes → [#409](https://github.com/its-everdred/aiur/issues/409)** (after this PR merges):
  opencode-serve pooling, AttachPool N×M fan-out cap, event-driven pane-death, `capture-pane`→`pipe-pane`,
  per-identifier SessionWriter subscription. This PR ships only the *cheap* reducers (U8).

---

## Context & Research

> This plan is built on already-completed, verified research captured in the origin doc: 6 codebase
> research agents, a process-efficiency static audit, a log-grounded empirical spike, a
> detection-feasibility workflow, and a direct filesystem probe — all with file:line anchors.
> No additional research was dispatched; the grounding is current as of 2026-06-22 on `feat/prewarm-base`.

### Relevant Code and Patterns

- **Workspace materialization seam:** `src/lib/aiur/workspace.ex` — `create_for_issue/2` (:15) →
  `ensure_workspace/2` (:34-79) → `create_workspace/1` (:81-85) is today a bare `File.mkdir_p!`. This
  is where copy-from-base inserts. `hook_env/0` (:362-369) exports `THIS_REPOSITORY_URL`. `remove/2`
  (:88-128) `rm -rf` teardown is CoW-safe. Path safety (:405-431) rejects symlink escapes → copy, don't symlink.
- **#377 RepoBase (reference to port):** `git show feat/warm-main-base:src/lib/aiur/repo_base.ex` —
  `ensure_fresh/1` (serialized call), `base_path/1` (pure), `refresh/3` (ensure_clone→fetch_and_reset→maybe_build),
  `.aiur-base-built` marker. Lacks phase events + preemption (this plan adds them).
- **Orchestrator dispatch:** `src/lib/aiur/orchestrator.ex` — `init/1` sets `initial_dispatch_cycle: true`;
  `:run_poll_cycle`→`maybe_dispatch/1` (:741-818); `choose_issues/2` (:1620-1648) spawns one Task per
  issue. **`maybe_dispatch/1` runs inside the orchestrator GenServer → the gate must be async.**
- **`aiur init`:** `src/lib/aiur/init.ex` — injected `io`/`deps` map (:919-940, mirror `detect_repo`
  at :1307 for a `detect_toolchain`); config templated via `fill_template/2` (:529-533); `.aiur/hooks`
  scaffolded verbatim (:979-988); final screen (:789-793). No toolchain detection exists today (verified).
- **Config:** `src/lib/aiur/config/schema.ex` (Hooks embed :357-364; Settings :445) +
  `src/lib/aiur/config.ex` accessors. `hooks_file` resolution in `src/lib/aiur/workflow.ex` (:128-158).
- **Agent-list loading UI:** `src/lib/aiur/agent_list/app.ex` — state init (:164-273), the
  **fragile `render/1` `Map.take`/`Map.put` pipeline (:1417-1455, whitelist at :1425)**, subscriptions
  (:146-162). `src/lib/aiur/agent_list/renderer.ex` — `render/1` branch (:90-189), reusable
  `spinner_frame/1` (:806-812), empty-list line (:555-560). Broadcast pattern to mirror:
  `src/lib/aiur/opencode/slot.ex:413`, `src/lib/aiur/agent_pubsub.ex`.
- **Fork-reducers:** `src/lib/aiur/opencode/slot.ex:683`/`:1308` (poll), `src/lib/aiur/tmux.ex:767`/`:796`
  (exe path), `src/lib/aiur/pane_manager.ex:592-611` (`aiur_screen_grab`, `debug_mode?` at :665),
  `src/lib/aiur/opencode/attach_pool.ex:487-493` (stale comment); launch shims
  `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `scripts/aiurdev`.

### Institutional Learnings

- **`render_state_takes_explicit`** — any new agent-list state field must be added to `render/1`'s
  `Map.take`/`Map.put` pipeline (app.ex:1425+) or the renderer never sees it. Directly applies to U7.
- **`chat_text_latency_root_causes` / label races** — make "list populated" the authoritative override
  for clearing the prewarm bar (U7), not a separate racing signal.
- **Flaky TUI/tmux tests** — `pane_manager_live_test.exs`, `debug_events_ticker_test.exs` flake under
  load; re-run rather than treating a single red as real (U7, U8).
- **`mise exec --`** is aiur's existing cross-OS runtime layer (in `.aiur/hooks` today) — the detected
  command rides it; do not call bare `mix`/`node`/`go` (U3).

### External References

- Detection prior art (Nixpacks/Railpack/Paketo/Heroku): lockfile/manifest → package-manager → canonical
  install+build; Node PM chain `packageManager` > pnpm-lock > bun > yarn-berry > yarn.lock > npm.
  Dockerfile/CI host-extraction is a dead end (base-image-bound RUN steps; Earthly went maintenance-only).

---

## Key Technical Decisions

- **Detection writes to a dedicated `prewarm:` config block, not a `base_setup` hook.** The new design
  is detection-driven and toolchain-neutral; a `prewarm.base_build` string (plus `enabled`,
  `poll_seconds`) is cleaner and more transparent than overloading hooks. (#377 used `hooks.base_setup`;
  we re-home it.)
- **Build-ROOT walk, not repo root.** aiur's own `mix.exs` lives in `src/` behind a decoy root
  `package.json` with no lockfile. Detection picks the shallowest manifest per language and uses the
  **lockfile as a tiebreaker** — the single non-obvious correctness trap, given its own test.
- **`mise exec --` for every runtime call** + `|| true` degrade. mise is aiur's existing cross-OS
  pinning layer; assume it present, don't bootstrap it.
- **Eager gate is async.** `maybe_dispatch/1` runs in the orchestrator process, so the gate kicks off
  the base build as a Task and *skips* `choose_issues` until `:ready`, re-entering on the phase event /
  next tick — it must never `GenServer.call`-block the orchestrator.
- **Rebuild-on-every-advance with preemption, no debounce.** Freshness beats overhead; a newer `main`
  cancels the running build so agents never derive from a stale base.
- **aiur owns the copy in Elixir** (copying a directory is language-agnostic); the detected command is
  only the one-time base build. The cold-clone path stays the universal fallback.
- **Cheap fork-reducers only in this PR; structural fixes → #409.** Keeps the PR focused while making
  `--debug` safe for the re-measurement.

---

## Open Questions

### Resolved During Planning

- Detection breadth: Elixir+Node+Go+Rust+Python (fallback otherwise). *(user-decided)*
- Copy mechanism: `cp --reflink=auto -a` / `cp -c`, platform-detected. *(user-decided)*
- Consent: show the detected command before writing/running. *(user-decided)*
- Dockerfile/CI: skipped. *(user-decided)*
- Refresh cadence: every advance + preempt, no debounce. *(user-decided)*
- Screen-grab: gate behind its own flag, separate from `--debug`. *(user-decided)*

### Deferred to Implementation

- Exact preemption mechanism in RepoBase (kill the build `Port`/Task vs cooperative cancel) — settle
  against the ported code in U2.
- Whether the orchestrator subscribes to RepoBase phase events or polls a `base_status/1` for the gate
  (U5) — decide when wiring; both satisfy "non-blocking."
- `ulimit -n` target value and per-shim guard form (U8) — pick when editing the shims.
- Batched-poll parsing detail for `list-panes` vs the current per-pane `display-message` semantics (U8).

---

## High-Level Technical Design

> *Illustrates the intended approach; directional guidance for review, not implementation
> specification. The implementing agent should treat it as context, not code to reproduce.*

```
INIT (one-time, opt-in)            DETECT (U3)                CONFIG (U1)
  aiur init … final prompt ──► detect_toolchain():       ──► prewarm:
   "keep a warm base?" yes       build-root walk +              enabled: true
        │                        lockfile tiebreaker +          base_build: "<mise exec -- …>"
        ▼                        mise exec  ──► {:ok,cmd}        poll_seconds: 0
   show cmd → confirm/edit/skip ──┘   │ :none → print agent-prompt fallback (A2)

RUN (every aiur start)
  Orchestrator.maybe_dispatch/1 (U5, async, initial_dispatch_cycle)
    └─ prewarm enabled & base not ready?
          ├─ start RepoBase.ensure_fresh as Task ; base_status=:warming ; SKIP choose_issues ; re-tick
          └─ RepoBase (U2): clone│fetch+reset-if-moved│build(base_build) ──PubSub──► {:prewarm_phase, …}
                 main advanced mid-build → PREEMPT (cancel build) → restart
    └─ base_status=:ready ──► choose_issues dispatches agents

DISPATCH (per issue)
  Workspace.create_for_issue/2 → create_workspace/1 (U6)
     base ready & local?  ── cp --reflink=auto / cp -c  from ~/.aiur/repo/<owner>/<name>  → branch aiur/<id>
     else (unconfigured/remote/undetected/copy-fail) ── existing cold-clone after_create  (R8, unchanged)

UI (U7)   AgentList.App subscribes {:prewarm_phase} → bar + rotating label (resume at live phase) → clear on first running list
```

---

## Implementation Units

- [ ] U1. **Pre-warm config schema + accessors**

**Goal:** Add a `prewarm` config block (`enabled`, `base_build`, `poll_seconds`) and Config accessors,
nil-safe and back-compatible.

**Requirements:** R3, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` (a `Prewarm` embedded schema on Settings: `enabled` boolean
  default `false`, `base_build` string nil, `poll_seconds` integer default `0`, `validate_number(>= 0)`)
- Modify: `src/lib/aiur/config.ex` (accessors: `prewarm_enabled?/0`, `prewarm_base_build/0`, `prewarm_poll_seconds/0`)
- Modify: `.aiur/examples/config.example` (commented `prewarm:` block with `{{…}}` placeholders)
- Test: `src/test/aiur/core_test.exs` (or the existing config-load test)

**Approach:** Mirror the existing embedded-schema + accessor pattern. Opt-in default (`enabled: false`)
so existing configs and the cold path are untouched. `base_build` nil when undetected.

**Patterns to follow:** `Config.Schema.Hooks` embed + `Config` accessors; `pre_warmed_sessions`
field (schema.ex:447) as a top-level-field precedent.

**Test scenarios:**
- Happy path: config with `prewarm.enabled: true` + `base_build` round-trips through the accessors.
- Edge case (back-compat): no `prewarm` block → `prewarm_enabled?` false, `prewarm_base_build` nil.
- Edge case: `poll_seconds` absent → 0; negative → changeset error.

**Verification:** Accessors return the configured values; absent block behaves as today.

---

- [ ] U2. **`Aiur.RepoBase` warm-base maintainer (port + phase events + preempt)**

**Goal:** Maintain one warm base per repo at `~/.aiur/repo/<owner>/<name>`; clone-once,
fetch+reset-when-main-moved, run `prewarm.base_build`; emit PubSub phase events; preempt an in-flight
build when `main` advances.

**Requirements:** R1, R2

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/repo_base.ex` (port from `git show feat/warm-main-base:src/lib/aiur/repo_base.ex`;
  swap `hooks.base_setup` → `Config.prewarm_base_build/0`; add phase events + preemption)
- Modify: `src/lib/aiur.ex` (supervision registration after `Aiur.WorkflowStore`)
- Modify: `src/lib/aiur/agent_pubsub.ex` (a `prewarm` topic + `broadcast_prewarm`/`subscribe_prewarm`)
- Test: `src/test/aiur/repo_base_test.exs`

**Approach:** Reuse #377's serialized-GenServer mechanism (`ensure_fresh/1`, `base_path/1` pure,
`refresh/3` = ensure_clone → fetch_and_reset → maybe_build, `.aiur-base-built` marker, slug). Additions:
(a) broadcast `{:prewarm_phase, :cloning|:fetching|:building|:ready|{:error, _}}` at each stage;
(b) track the in-flight build task — a newer `ensure_fresh` whose `origin/main` HEAD moved cancels the
running build and restarts (preempt). Run the build via the existing scrubbed `sh -lc` shape with
base-scoped `HEX_HOME`/`MIX_HOME`. Expose `base_status/1` (`:idle|:warming|:ready`) for U5.

**Execution note:** Test-first for the staleness + preemption decision against a local temp git repo.

**Patterns to follow:** opencode GenServer + supervision registration; `Workspace.run_hook` scrub +
`System.cmd("sh", ["-lc", …])`; `AgentEnvironment.scrub_shell_command/1`.

**Test scenarios:**
- Happy path: fresh machine → clone + build + `:ready`, base HEAD == `origin/main`.
- Happy path: base already current → idempotent fast path, no rebuild.
- Edge case (R2): `origin/main` advanced → fetch+reset+rebuild before `:ready`.
- Edge case (R2, preempt): a second `ensure_fresh` with a newer HEAD during an in-flight build cancels
  the first build and rebuilds to the newer HEAD; only the newer base is marked built.
- Error path: `base_build` exits non-zero → `{:error, …}`, `.aiur-base-built` not written, callers fall back.
- Integration: phase events arrive in order `cloning→fetching→building→ready`; two concurrent
  `ensure_fresh` calls serialize without interleaved git state.

**Verification:** Repeated `ensure_fresh` is idempotent when main hasn't moved, rebuilds + preempts when
it has, emits ordered phase events, and never corrupts the base under concurrency.

---

- [ ] U3. **Toolchain detection**

**Goal:** From lockfile/manifest, resolve the build-root + canonical install/build command for
Elixir/Node/Go/Rust/Python, routed through `mise exec --` and wrapped `|| true`.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/prewarm/detect.ex` (`Aiur.Prewarm.Detect`, pure)
- Test: `src/test/aiur/prewarm/detect_test.exs`

**Approach:** Glob `{mix.exs, package.json, go.mod, Cargo.toml, pyproject.toml|requirements.txt}`; pick
the **shallowest** manifest per language; on multi-language, prefer the dir that **also has a lockfile**
(tiebreaker vs vanity root `package.json`). Build-root = the manifest's dir. Node PM from the chain
`packageManager` > `pnpm-lock.yaml` > `bun.lockb` > `.yarnrc.yml`(berry) > `yarn.lock` > npm
(+ `corepack enable` for pnpm/yarn). Synthesize `cd <root> && mise exec -- <install> && mise exec -- <build>`
(frozen installs; build step only when present, e.g. `package.json#scripts.build`). Return
`{:ok, %{language, build_root, command}}` or `:none`.

**Execution note:** Implement test-first — pure, deterministic, high branch density.

**Patterns to follow:** `init.ex` `detect_repo/0` shape (deps-injected discovery); buildpack heuristic table.

**Test scenarios:**
- **Covers the key trap:** the aiur repo layout (root `package.json` with no lock + `mix.exs` in `src/`)
  → `{language: :elixir, build_root: "src", command: <mix …>}`, NOT Node off the root manifest.
- Happy path: `pnpm-lock.yaml` → `corepack enable` + `pnpm i --frozen-lockfile` (+ build if `scripts.build`).
- Happy path: `package-lock.json` → `npm ci`; `go.mod` → `go mod download && go build ./...`;
  `Cargo.toml` → `cargo build`; `pyproject.toml`+`poetry.lock` → `poetry install`.
- Edge case: no supported manifest → `:none`.
- Edge case: two languages at comparable depth, neither with a disambiguating lockfile → `:none` (fallback).
- Edge case: `nx.json`/`turbo.json` present (monorepo orchestrator) → flagged → `:none` (fallback).

**Verification:** Detection returns the correct build-root + command for each supported toolchain and
`:none` for undetected/ambiguous, with the aiur-self trap covered.

---

- [ ] U4. **`aiur init`: opt-in prompt, detection, consent, write config**

**Goal:** End `aiur init` with a pre-warm opt-in; on yes, run detection, **show the command for
confirmation/edit/skip**, write the `prewarm` block; on `:none`, print the agent-prompt fallback.

**Requirements:** R3, R4, R5

**Dependencies:** U1, U3

**Files:**
- Modify: `src/lib/aiur/init.ex` (add `detect_toolchain` to the deps map; final-step opt-in prompt;
  consent prompt; write `prewarm.enabled`/`base_build`; print fallback prompt on `:none`)
- Modify: `.aiur/examples/config.example` (prewarm block, if not fully covered by U1)
- Test: `src/test/aiur/init_test.exs`

**Approach:** Inject `detect_toolchain` (mirror `detect_repo`) so the wizard stays mockable. Opt-in →
`detect` → `{:ok, cmd}`: render `cmd`, `accept | edit | skip`; accept/edit writes
`prewarm.enabled: true` + `base_build`; skip writes `enabled: false`. `:none` → print a self-contained
agent-prompt (what was tried, the conventions: `mise exec`, build-root, frozen installs, `|| true`,
no source mutation, no brew/apt/sudo) for A2 to author hooks. Init succeeds regardless (R8 holds).

**Execution note:** Use the existing injected-`io`/`deps` harness; assert on captured output, no real FS/network.

**Patterns to follow:** `init.ex` `final_screen`, `ensure_prompt_file`/`{{REPO}}` substitution, injected-io tests.

**Test scenarios:**
- Happy path (R4): opt-in + detection `{:ok, cmd}` + accept → config has `prewarm.enabled: true` + `base_build = cmd`.
- Consent: shows the command; `edit` writes the edited command; `skip` writes `enabled: false`.
- Edge case: detection `:none` → prints the fallback prompt; `enabled: false`; no crash.
- Edge case: user declines the opt-in → no `prewarm` block written.
- Edge case: global config location → handled like `prompt_file` for global.

**Verification:** A fresh `aiur init` with detection yields a confirmed `prewarm` config; misses print a
usable fallback prompt; declining is a clean no-op.

---

- [ ] U5. **Eager async pre-warm gate in the orchestrator**

**Goal:** On the first dispatch cycle, if pre-warm is enabled, ensure the base is fresh asynchronously
and hold `choose_issues` until `:ready`; re-enter on completion/next tick — never blocking the orchestrator process.

**Requirements:** R5

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex` (`State` gains `base_status`; `maybe_dispatch/1` gate after
  candidate fetch, scoped by `initial_dispatch_cycle` + `prewarm_enabled?`; subscribe/handle the
  `:prewarm_phase` `:ready`)
- Test: `src/test/aiur/orchestrator_*` (a focused dispatch-gating test; mock RepoBase)

**Approach:** On the first cycle with prewarm enabled and candidates present: if base not ready, kick
`RepoBase.ensure_fresh` as a `Task` (RepoBase already async-builds + emits phases), set
`base_status: :warming`, **skip `choose_issues`**, re-arm the tick. On `{:prewarm_phase, :ready}` (or a
`base_status/1` check), set `:ready` and let the next cycle dispatch. The per-dispatch freshness path
(workspace) remains the cheap net. No `GenServer.call` to RepoBase from inside `maybe_dispatch`.

**Execution note:** Add a failing test asserting "no dispatch while `:warming`, dispatch after `:ready`,
orchestrator stays responsive" before wiring.

**Patterns to follow:** existing `initial_dispatch_cycle` handling (orchestrator.ex:118/:766); the
`refresh_runtime_config` re-tick model.

**Test scenarios:**
- Happy path: prewarm enabled + base not ready → first cycle does NOT call `choose_issues`; on `:ready`
  the next cycle dispatches.
- Integration: while `:warming`, the orchestrator still processes other messages (no mailbox freeze).
- Edge case (R8): prewarm disabled → dispatch proceeds immediately, unchanged.
- Error path: base build errors → gate releases to the cold dispatch path, logged (no hang).

**Verification:** Agents are held until the base is ready when prewarm is on; behavior is unchanged when
off; the orchestrator never blocks.

---

- [ ] U6. **aiur-owned workspace materialization (copy-from-base + fallback)**

**Goal:** Replace the empty `mkdir` with a platform-detected copy from the warm base when one exists;
keep the cold-clone path byte-for-byte otherwise.

**Requirements:** R6, R8

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur/workspace.ex` (`create_workspace/1` / `ensure_workspace/2`: when prewarm base
  ready + local dispatch, `materialize_from_base` via `cp --reflink=auto -a` (Linux) / `cp -c` (macOS)
  from `RepoBase.base_path`, then create branch `aiur/<id>`; else existing cold path)
- Test: `src/test/aiur/workspace_*` (file-load/materialization test with a temp base)

**Approach:** Gate on prewarm enabled + base ready + `worker_host == nil` + base path exists. Copy the
whole base dir (incl. `.git`, `_build`, `deps`), platform-detecting the `cp` flag. Keep `created? = true`
so any residual branch-creation step runs. On copy failure → fall back to cold clone (logged). Don't
symlink (path-safety guard). `rm -rf` teardown already CoW-safe.

**Execution note:** Test-first — assert "base present → materialized + cold hook skipped" and "no base →
cold path unchanged" before wiring.

**Patterns to follow:** `ensure_workspace/2`/`create_workspace/1` structure; the remote-vs-local split;
`hook_env/0` for any base-path export.

**Test scenarios:**
- Happy path (R6): base ready + local → workspace populated from base (`_build`/`deps` present, branch
  created); the cold-clone `after_create` is NOT run.
- Edge case (R8): no base / prewarm disabled → cold path byte-for-byte unchanged.
- Edge case (R8): remote worker (`worker_host` set) → cold path (no base copy).
- Error path: copy fails → fall back to cold clone, logged, dispatch proceeds.
- Edge case: macOS vs Linux → correct `cp` flag selected.

**Verification:** Configured local dispatches materialize from the base and skip the cold compile;
everything else behaves exactly as today.

---

- [ ] U7. **Agent-list pre-warm loading UI**

**Goal:** Show a loading bar + rotating phase labels before agents populate, driven by RepoBase phase
events; resume at the live phase on launch-during-build; clear on the first populated running list.

**Requirements:** R7

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur/agent_list/app.ex` (state `prewarm_active?`/`prewarm_phase`; subscribe the
  prewarm topic; `handle_info({:prewarm_phase, …})`; **thread the new fields through `render/1`'s
  `Map.take`/`Map.put` at :1425+**; clear on `:running_changed` + on `:ready`)
- Modify: `src/lib/aiur/agent_list/renderer.ex` (a `render/1` branch drawing the bar + spinner + label)
- Test: `src/test/aiur/agent_list/*` (renderer + app)

**Approach:** Add the fields in `init/1`; thread through the fragile `Map.take` whitelist (the
`render_state_takes_explicit` hazard). Subscribe the prewarm topic; on a phase event set
`prewarm_phase` + render. Renderer: when `prewarm_active?`, draw a full-width bar + reused
`spinner_frame/1` + the rotating label per phase. Resume-at-phase comes from the latest event (RepoBase
can expose/replay its current phase). **Clear authoritatively** on the first non-empty
`:running_changed` (and on `:ready` as belt-and-suspenders) to avoid the label-race class.

**Execution note:** Add a renderer test that fails if the new field isn't threaded through `Map.take`
(guards the known regression).

**Patterns to follow:** `slot.ex:413` broadcast + the `:slot_ready` handler (app.ex:749-753);
`spinner_frame/1` + `:now_ms` plumbing; `agent_pubsub.ex` subscribe/broadcast helpers.

**Test scenarios:**
- Happy path: `prewarm_active?` true → renderer draws the bar + the label for `prewarm_phase`.
- Regression guard: a new prewarm field is visible to the renderer (fails if omitted from `Map.take`/`Map.put`).
- Happy path: a `{:prewarm_phase, p}` event updates the label.
- Edge case: clear on first populated `:running_changed`; clear on `:ready`.
- Edge case (resume): launching mid-build shows the live phase, not a restart from `cloning`.

**Verification:** The bar appears before agents, tracks phases, resumes correctly mid-build, and clears
once the list populates — with the new field provably threaded through the render pipeline.

---

- [ ] U8. **Fork-reducers + `--debug` FD safety + `ulimit`**

**Goal:** Cut steady-state tmux fork pressure, decouple the per-pane `capture-pane` screen-grab from
`--debug`, and raise the FD ceiling so a `--debug` run survives ~16 tickets.

**Requirements:** R9

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/opencode/slot.ex` (batch the liveness poll at :683/:1308 — one
  `tmux list-panes -F` per tick parsed in-process instead of per-pane `display-message`; keep the
  death-threshold debounce)
- Modify: `src/lib/aiur/tmux.ex` (cache `System.find_executable("tmux")` at GenServer init; :767/:796)
- Modify: `src/lib/aiur/pane_manager.ex` (gate the recurring `:screen_grab_tick` on a new
  `AIUR_SCREEN_GRAB` flag, default off, separate from `AIUR_DEBUG`; :592-611/:665)
- Modify: `src/lib/aiur/opencode/attach_pool.ex` (delete the stale comment at :487-493)
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `scripts/aiurdev` (raise `ulimit -n`, guarded)
- Test: `src/test/aiur/...` (mock-tmux fork-count assertions where feasible; a pane_manager flag test);
  `src/test/regression/aiur-shutdown.sh` neighborhood for the shim line

**Approach:** Batch poll = one `list-panes` query/tick across the hidden window, compare to expected
pane_ids. Cache the exe path once. `--debug` keeps structured logs; the per-pane `capture-pane` loop
only runs when `AIUR_SCREEN_GRAB` is set. Raise `ulimit -n` (only upward) in both shims.

**Execution note:** Touches the flaky tmux/TUI test area — run targeted tests, re-run on flake; don't
treat a single red as real.

**Patterns to follow:** `pane_manager.ex` `debug_mode?/0` (:665) as the model for a `screen_grab?/0`
flag; the existing shim structure.

**Test scenarios:**
- Happy path: a poll tick forks **one** tmux call (assert via mock-tmux call count), not one per pane.
- Happy path: tmux exe path resolved once at init (no `find_executable` per command).
- Edge case (R9): `AIUR_DEBUG` set + `AIUR_SCREEN_GRAB` unset → the screen-grab loop does NOT reschedule;
  set `AIUR_SCREEN_GRAB` → it does.
- Edge case: launch shims contain a `ulimit -n` raise (shim/regression check); never lowers an
  already-higher limit.

**Verification:** Steady-state tmux forks drop sharply; `--debug` alone no longer spawns the per-pane
capture loop; the FD ceiling is raised at launch.

---

- [ ] U9. **Dogfood aiur-self + docs**

**Goal:** Configure aiur's own repo for pre-warm (detected mix build) and document the feature.

**Requirements:** R10

**Dependencies:** U1, U2, U3, U4, U6

**Files:**
- Modify: `.aiur/config` (a `prewarm` block: `enabled: true`, the detected `mise exec -- … mix …` build,
  build-root `src/`)
- Modify: `.aiur/examples/config.example`, `src/README.md` (document `prewarm`, the opt-in, the fallback)
- Test: none — config/docs (exercised by U1/U4 load tests + the manual dogfood run)

**Approach:** Run U3's detector on aiur → the mix command rooted at `src/` → write the `prewarm` block.
Document opt-in, consent, fallback, and that aiur owns the copy.

**Test expectation:** none — config/doc change; behavior is covered by U1/U4 tests and the U10 run.

**Verification:** `aiur` runs against its own repo using the warm base; removing the `prewarm` block
cleanly reverts to the cold path.

---

- [ ] U10. **Throttled re-measurement**

**Goal:** Capture the boot→first-message pipeline the crash hid and quantify warm-vs-cold, on a box that
survives.

**Requirements:** R10

**Dependencies:** U1–U8

**Files:**
- Create: `docs/measurements/2026-06-22-prewarm-warm-vs-cold-findings.md`

**Approach:** Operator-run (per test-cost discipline). Config: 4–6 agents, raised `ulimit -n`, prewarm
enabled, `--debug` (now safe). Capture phase timings + first-message; compare to a cold run. Write findings.

**Test expectation:** none — empirical measurement written up as a doc.

**Verification:** A completed throttled run shows the warm path reaching first-message in seconds with no
`:emfile`, beating the cold path; findings documented.

---

## System-Wide Impact

- **Interaction graph:** new `Aiur.RepoBase` in the supervision tree (aiur.ex); dispatch path gains a
  gate (`Orchestrator.maybe_dispatch` → RepoBase) and a materialization branch
  (`Workspace.create_workspace` → copy-from-base); a new PubSub `prewarm` topic feeds `AgentList.App`;
  `aiur init` gains detection + consent.
- **Error propagation:** every RepoBase/detection/copy failure must degrade to the cold-clone path
  (R8), never hard-fail a dispatch; surfaced as logged warnings + an `{:error, …}` phase event.
- **State lifecycle risks:** the shared base under concurrent refresh/preempt/copy is the main hazard —
  serialize through the RepoBase GenServer; a failed/aborted build leaves the marker unwritten so
  callers fall back rather than use a half-built base.
- **API surface parity:** `prewarm` is local-dispatch only; remote/SSH dispatch deliberately keeps the
  cold path (no base path on the remote host).
- **Integration coverage:** U5's "held-then-released dispatch", U6's "materialized vs cold", and U2's
  "preempt on advance" are the cross-layer behaviors unit mocks won't fully prove — exercised in U10.
- **Unchanged invariants:** unconfigured / remote / undetected / copy-failed repos behave byte-for-byte
  as today; existing hook keys, `workspace_hooks/0`, and cold `after_create` remain valid.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Build-root mis-resolution (aiur's `mix.exs` in `src/` behind a decoy root `package.json`) | Shallowest-manifest + lockfile tiebreaker; the aiur-self case is an explicit U3 test |
| Eager gate blocks the orchestrator GenServer | Async-only gate (Task + skip `choose_issues` + re-tick); U5 test asserts responsiveness while `:warming` |
| Stale base if `main` advances mid-build | Rebuild-every-advance + **preempt** the in-flight build (U2); per-dispatch freshness net |
| `cp --reflink` unsupported on ext4 (this box) | `--reflink=auto` degrades to full copy; still skips the recompile (the measured win) |
| Native/compiler drift (NIF/node-gyp) not solved by mise | Documented user prerequisite (C toolchain); detection pins runtime, not the compiler |
| Monorepo/exotic repos mis-detected | Ambiguous/orchestrator (`nx`/`turbo`) → `:none` → agent-prompt fallback (the intended escape hatch) |
| `--debug` adds FD pressure at 16 tickets | Decouple `aiur_screen_grab` from `--debug` + batch poll + `ulimit` (U8) |
| Flaky TUI/tmux tests (U7/U8) | Re-run; don't treat a single red as real; characterization-aware |
| Wrong detected command executed silently | Consent: show for confirm/edit/skip before write+run (U4) |

---

## Documentation / Operational Notes

- Document the `prewarm` config block, the init opt-in + consent, and the agent-prompt fallback in
  `.aiur/examples/config.example` and `src/README.md` (U9).
- `--debug` remains the way to read logs; note the separate `AIUR_SCREEN_GRAB` flag for pane snapshots (U8).
- Commit/verify discipline: TDD per unit; `mix format` + `credo --strict`; `make -C src all` green;
  small commits, push as you go; never merge without operator go-ahead.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-22-prewarm-design-research-and-questions.md](docs/brainstorms/2026-06-22-prewarm-design-research-and-questions.md)
- Measurement: [docs/measurements/2026-06-22-prewarm-run-findings.md](docs/measurements/2026-06-22-prewarm-run-findings.md)
- Reference only (reuse RepoBase via `git show feat/warm-main-base:…`):
  [docs/plans/2026-06-17-001-feat-warm-main-base-plan.md](docs/plans/2026-06-17-001-feat-warm-main-base-plan.md)
- Deferred follow-up: [#409](https://github.com/its-everdred/aiur/issues/409)
- Key code anchors: `src/lib/aiur/{workspace,orchestrator,init,config,tmux,pane_manager}.ex`,
  `src/lib/aiur/opencode/{slot,attach_pool}.ex`, `src/lib/aiur/agent_list/{app,renderer}.ex`,
  `src/lib/aiur/config/schema.ex`
