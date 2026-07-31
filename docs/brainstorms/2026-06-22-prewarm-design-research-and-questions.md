---
date: 2026-06-22
topic: repo-agnostic-eager-prewarm
status: phase-1 research (awaiting operator decisions)
branch: feat/prewarm-base
supersedes-as-source-of-truth: docs/brainstorms/2026-06-17-warm-main-base-requirements.md (reference only)
---

# Repo-Agnostic Eager Prewarm — Research, Options & Open Questions (Phase 1)

## How to use this doc

This is **Phase 1**: all upfront research, the design option space, and the decisions only you can
make. It is **not** a final requirements doc — it deliberately stops at the open questions.

- **You:** read §"Open Questions", accept the recommended defaults or note deltas.
- **Then:** paste the Phase 2 `/goal` (end of this doc). With your answers baked in, it drives the
  full end-to-end implementation (plan → build → test → lint → code review) without stopping.

Every recommendation below has a default, so if you accept all of them you can paste the `/goal`
verbatim. The old `feat/warm-main-base` implementation (#377) is **reference only** — its mechanism
is reused, but its central product decision is being reversed (see §"The core shift").

---

## TL;DR

- The measured pain is **16 agents each independently clone + `deps.get` + `compile` the same repo**
  (~249 s each under CPU contention; the run crashed before any real work). The fix is to build the
  repo **once** into a warm base and materialize each workspace from it cheaply.
- **#377 already built the reusable mechanism** (`RepoBase` GenServer: one warm checkout per repo,
  fetch+reset-if-main-moved, serialized). We keep that. Two things change:
  1. **Eager, not lazy** — refresh the base *before* the first dispatch (async, so it doesn't freeze
     the orchestrator), with a loading bar in the agent list.
  2. **Repo-agnostic, not dev-authored** — you said users must not write repo-specific build shell.
     So aiur **detects the toolchain** to build the base once, and **owns the per-workspace copy**
     itself. Exotic/undetected repos fall back to the opt-in agent-written hook.
- **Filesystem reality (verified on this box):** HOME is **ext4**, `/tmp` is **tmpfs** — no reflink.
  `cp --reflink=auto` silently degrades to a full byte copy here; APFS (macOS) gets true CoW. **Even a
  full `cp -a` of the base avoids the recompile** (it carries the warm `_build`), so the design must
  *exploit* CoW when present but not *depend* on it.
- The `:emfile` crash is a **separate defect** (opencode slot poll/attach fan-out) — out of scope,
  but prewarm incidentally removes the dominant FD holder. Cheapest standalone mitigation (`ulimit -n`
  in the launch shim) is a one-liner we may fold in for our own re-measurement.

---

## Verified architecture map

All paths repo-relative; line numbers verified on `feat/prewarm-base` (= latest `main`).

### 1. Workspace creation — aiur only `mkdir`s; the build is in a shell hook
- `Aiur.Workspace.create_for_issue/2` (`src/lib/aiur/workspace.ex:15`) → `ensure_workspace/2`
  (`:34-79`) → `create_workspace/1` (`:81-85`) = **`File.mkdir_p!` of an empty dir**. No clone, no
  copy, no worktree in Elixir.
- The repo only lands in the workspace because the operator's **`after_create` hook** runs
  `git clone "$THIS_REPOSITORY_URL" .` + the build (`.aiur/hooks`, run via `run_hook/5` `:294-338`).
  **This is where the 16× redundant clone+compile lives — in shell, not Elixir.**
- `hook_env/0` (`:362-369`) exports only `THIS_REPOSITORY_URL` (GitHub trackers only). Local dispatch
  only; the SSH/remote path does not thread it.
- Workspace root default: `<tmp>/aiur_workspaces/<safe_id>/` (`src/lib/aiur/config/schema.ex:161`).
- **CoW seam:** `create_workspace/1` (`:81-85`) is the single function that turns "no dir" into "a
  dir." Replacing the `File.mkdir_p!` there with a copy-from-base is the **in-Elixir materialization**
  option. `rm -rf` teardown (`remove/2` `:88-128`) is safe with copy/reflink/clone. Path-safety
  (`:405-431`) rejects symlink escapes → **copy, don't symlink** the base in.

### 2. `aiur init` — no toolchain detection; hooks are scaffolded verbatim
- **Confirmed: zero toolchain detection anywhere** (no `mix.exs`/`package.json`/`Cargo.toml`/`go.mod`
  sniffing in `src/lib`). The only "toolchain" reference is a freeform comment in the hooks template.
- `.aiur/hooks` is scaffolded **byte-for-byte** from `.aiur/examples/hooks.example`
  (`write_aiurhooks/1` `src/lib/aiur/init.ex:979-988`) — **no placeholder substitution**, never
  clobbered if present. Contrast: `.aiur/config` and `.aiur/prompt.md` **are** templated
  (`fill_template/2` `:529-533`; `{{REPO}}` substitution).
- Init is fully interactive but **mockable** via an injected `io`/`deps` map (`:919-940`) — detection
  would be added as `deps.detect_toolchain` mirroring the existing `deps.detect_repo` (`:1307`).
- Hook keys today: `after_create`, `before_run`, `after_run`, `before_remove`, `timeout_ms`
  (`src/lib/aiur/config/schema.ex:357-364`). **No `base_setup` key** on this branch (that was #377).
- `hooks_file:` indirection works today (`Aiur.Workflow.resolve_hooks/2`
  `src/lib/aiur/workflow.ex:128-158`): an external YAML replaces the inline `hooks:` block.
- **Implication:** "user writes no build shell" requires either making `.aiur/hooks` a *templated*
  artifact (add a `{{BASE_SETUP}}` fill) **or** routing a detected build command through config and
  letting aiur own the build/copy.

### 3. #377 `RepoBase` — keep the mechanism, replace the timing + the hook-dependence
On `feat/warm-main-base` (`git show` only; not on this branch):
- **KEEP:** `Aiur.RepoBase` GenServer (`src/lib/aiur/repo_base.ex`): `ensure_fresh/1` (serialized
  `call`, 10-min timeout), `base_path/1` (pure, `~/.aiur/repo/<owner>/<name>`), `refresh/3`
  (`ensure_clone` → `fetch_and_reset` → `maybe_build`), `.aiur-base-built` marker, `repo_base_poll_seconds`
  background poll (default 0). Config fields + `hooks_file` plumbing. `THIS_REPO_BASE` env export.
- **REPLACE:** the **lazy call site** — `RepoBase.ensure_fresh` is only called from
  `workspace.ex:220` (`maybe_ensure_warm_base`, inside `maybe_run_after_create_hook`), i.e. *while the
  first agent is already spinning up*. The first dispatch eats the whole one-time build; everyone
  blocks behind it. → move to an **eager gate before first dispatch**.
- **GAP:** `RepoBase` emits **no PubSub phase events** — the loading UI needs these added.
- **GAP (the product reversal):** base build + spin-off are **entirely dev-authored hooks**; init only
  prints a paste-prompt. aiur never detects or generates anything.

### 4. Orchestrator dispatch — the eager gate must be async
- Boot: `init/1` (`src/lib/aiur/orchestrator.ex:102-131`) sets `initial_dispatch_cycle: true` and
  schedules the first tick immediately. Each cycle: `:run_poll_cycle` → **`maybe_dispatch/1`**
  (`:741-818`) → re-arm next poll.
- `maybe_dispatch/1`: fetch candidate issues (`:746-747`) → `if available_slots > 0 → choose_issues`
  (`:759-764`) → clears `initial_dispatch_cycle` (`:766`). `choose_issues/2` (`:1620-1648`) is a
  **synchronous loop that spawns one supervised Task per eligible issue at once** — each Task runs
  `after_create` (clone+compile) concurrently. **No throttle between Task-spawn and build.**
- `max_concurrent_agents` (default **10**) is the real throttle. `pre_warmed_sessions` (default **3**)
  only sets the opencode **display-slot** count (`min(pre_warmed, max_agents)`,
  `src/lib/aiur/opencode/slot_policy.ex:190-196`) — **confirmed display-only, not build throttling.**
  Compile storm and slots are two unrelated subsystems.
- **Gate insertion point:** in `maybe_dispatch/1` after `notify_dashboard` (`~:757`), before the
  `choose_issues` gate (`:759-764`), scoped by `initial_dispatch_cycle`.
- **CRITICAL:** `maybe_dispatch/1` runs *inside the orchestrator GenServer process*. A synchronous
  base build there **freezes the orchestrator mailbox** (no chat/pause/DOWN/dashboard) for the entire
  build. → **must be async:** kick off the base build as a supervised Task, skip `choose_issues` while
  `base_status != :ready`, and re-enter on the next poll tick or a completion message.

### 5. Agent-list loading UI — reusable spinner exists; phase events do not
- Modules: `src/lib/aiur/agent_list/app.ex` (GenServer/state/PubSub intake) + `renderer.ex` (pure
  `render/1`) + `input.ex`.
- **The fragile pipeline:** `render/1` (`app.ex:1417-1455`) builds `render_state` via a `Map.take`
  whitelist (`:1425` = `[:summaries, :selection_index, :selection_focus, :help_visible?,
  :max_agents_alert?]`) plus explicit `Map.put`s (`:1426-1451`). **A new `prewarm_*` field is invisible
  to the renderer unless added here** (the `render_state_takes_explicit` hazard), and `renderer.ex`
  re-reads via `Map.get` (second hop).
- Population is PubSub-driven (`{:running_changed, summaries}` `app.ex:604`); empty state is the static
  `(no agents running)` line (`renderer.ex:555-560`).
- **Reusable:** braille spinner (`renderer.ex:806`, `spinner_frame/1` `:808`), rotating
  `phase_placeholder/1` phrases (`:818-833`), a 10-cell progress bar (`ProgressTracker`). A 1 Hz
  `:refresh_tick` re-renders unconditionally → a spinner animates for free.
- **Missing:** no full-width pre-list loading bar, and **no clone→fetch→build→ready phase event** to
  subscribe to. Must add `{:prewarm_phase, ...}` broadcasts from `RepoBase` and a handler in `app.ex`
  (mirror the `:slot_ready` clause `:749-753`; add `subscribe_prewarm`/`broadcast_prewarm` to
  `src/lib/aiur/agent_pubsub.ex`).
- **Label-race guard:** also flip `prewarm_active? = false` in the `:running_changed` handler so a
  populated list authoritatively wins even if a phase broadcast is dropped.

### 6. `:emfile` crash — separate ticket, incidental relief from prewarm
- Mechanism verified: `Opencode.Slot` `:poll_session` (`slot.ex:675`) spawns a `tmux display-message`
  subprocess every poll (`:683`, default 500 ms) — but **per active slot, not per session** (~10
  forks/sec total, transient). `AttachPool` attaches **every agent into every slot**
  (`attach_pool.ex:563-584`) → up to 80 attach round-trips at 16×5.
- **Correction to the findings doc:** the per-poll tmux fork is real but *marginal*. The real FD
  holders were the **16 concurrent compile subprocess trees** (`workspace.ex:316`) + ~17 `beam.smp`
  instances. The poll/attach fan-out was the straw, not the load.
- `Aiur.Tmux` is a single GenServer, `System.cmd` per call, **no pooling/caching**; its `:emfile`
  crash cascaded through all slots.
- **No `ulimit -n` is set anywhere** in the launch path (`aiur-engine.sh`, `aiurdev`).
- **Assessment:** prewarm removes the dominant FD holder (16 compile trees) as a *side effect* → a
  warm-base run is far less likely to hit `:emfile`. But the slot poll/attach fan-out is an
  independent defect → **separate ticket.** Cheapest standalone mitigation: add `ulimit -n` to the
  launch shim (one line).

### 7. Filesystem / CoW reality (probed directly on this box)
| Environment | FS | Reflink CoW | `git clone --local` |
|---|---|---|---|
| This Linux dev box (HOME) | **ext4** | ❌ `cp --reflink=auto` → full copy | ✅ hardlinks `.git` objects |
| This Linux dev box (`/tmp`, default workspace root) | **tmpfs** | ❌ | ✅ |
| Measurement crash machine | **macOS / APFS** | ✅ `cp -c` / `clonefile` | ✅ |

A full `cp -a` of the base on ext4 still **avoids the recompile** (carries warm `_build`/deps), so it
captures the measured win even without true CoW. `git clone --local` is instant for tracked files but
does **not** carry `_build`/deps (would still need them seeded). → recommended copy is
`cp --reflink=auto -a` (Linux) / `cp -c` (macOS), platform-detected, degrading to a plain copy.

---

## The core shift (why #377 is reference-only)

#377's central **Key Decision** was: *"aiur does not author hooks or detect the toolchain itself —
delegated to the dev's coding agent."* Your new constraint **reverses** exactly that:

> Users must NOT write repo-specific build shell. Prefer a repo-agnostic prewarm that `aiur init` sets
> up itself; the opt-in agent-written hook is only the fallback.

So the new contribution = **remove the dev-authored-hook requirement**, via two seams that compose:
1. **Toolchain detection at init** → aiur auto-fills the *one-time base build* command (no user shell).
2. **aiur-owned copy-on-write spin-off** → aiur materializes each workspace from the built base itself
   (no per-workspace build shell at all).

Together: for a detected toolchain, the user writes **zero** shell. Undetected/exotic repos and remote
workers fall back to the existing cold-clone path (and the opt-in agent prompt for custom hooks).

---

## Design options & recommendations (decision axes)

### A. Automation strategy — how we kill the user-written build shell
- **A1 (recommended): Detect + aiur-owned copy.** Detect the toolchain at `init` to fill the base
  build command; aiur builds the base once (`RepoBase`) and copies it into each workspace in-Elixir.
  Zero user shell for detected repos.
- A2: Eager #377 — keep dev-authored `base_setup`/`after_create` hooks, just make them eager. Lowest
  churn, but **does not** satisfy "no user-written build shell" (it's your fallback, not the goal).
- A3: Copy-on-write only — skip detection, rely purely on copying a base. Fails: the base still has to
  be built once, which still needs a build command. CoW alone doesn't remove the build step.
→ **A1.** A2 becomes the explicit fallback for undetected/exotic repos.

### B. Materialization ownership — who does the per-workspace copy
- **B1 (recommended): aiur-Elixir owns it.** Replace `create_workspace/1`'s `mkdir` (`workspace.ex:81-85`)
  with a platform-aware copy from `RepoBase.base_path`. Copying a directory is genuinely
  repo-agnostic (no language knowledge needed), so this is the cleanest realization of the goal — and
  it lets the `after_create` hook shrink to nothing (or just branch creation, which aiur can also own).
- B2: Generated hook does it — aiur writes a `cp`/`clone` command into a templated `.aiur/hooks`.
  Keeps the hook seam, but reintroduces shell aiur has to generate+maintain per platform.
→ **B1**, with B2 as the fallback shape for repos that opt into custom hooks.

### C. Copy mechanism (platform-detected, used by B1)
- **C1 (recommended): `cp --reflink=auto -a` (Linux) / `cp -c` (macOS)** of the whole base dir. One
  command, true CoW where available, graceful full-copy fallback, carries `_build` → no recompile.
- C2: `git clone --local` + seed `_build`/deps. Instant tracked-file share, but extra logic to carry
  build artifacts; no net win over C1 on ext4.
- C3: `git worktree`. Shares objects but couples workspace lifecycle to the base repo (branch/prune/
  concurrent-refresh complexity).
→ **C1.**

### D. Eager-gate shape (from the orchestrator-process finding)
- **D1 (recommended): async gate** — base build runs as a supervised Task; `maybe_dispatch` skips
  `choose_issues` until `base_status == :ready`, re-enters on completion/next tick. Orchestrator stays
  responsive.
- D2: synchronous block in `maybe_dispatch` — freezes the orchestrator + UI for the whole first build.
  **Rejected.**
→ **D1.**

### E. Re-warm scope
- **E1 (recommended): startup-only eager block** + keep the cheap per-dispatch `ensure_fresh` as a
  freshness safety net (no mid-run re-block).
- E2: also re-block on every mid-run `main` advance. More complex; rare benefit.
→ **E1.**

### F. First-run UX (the one-time minutes-long build on a fresh machine)
- **F1 (recommended for v1): block with an informative loading bar.** First run is one-time; later
  runs are cheap fetches. Simplest, honest.
- F2: dispatch agents **cold** while the base builds in the background, then switch to warm once ready.
  Best UX, most complex (two code paths live at once).
- F3: show the bar but allow a keypress to proceed cold.
→ **F1** for v1; note F2 as a follow-up. (This is a genuine UX call — flag for you.)

### G. Loading-bar fidelity
- **G1 (recommended): event-driven phase labels** (`Cloning…` → `Fetching main…` → `Building…` →
  `Ready`) from `RepoBase` PubSub + spinner; **build sub-progress is a time-rotated generic phrase**
  ("Compiling…", "Almost ready…") since `base_setup` is one opaque command (no sub-step granularity
  available — verified).
→ **G1.**

### H. `:emfile` scope
- **H1 (recommended): exclude the structural fix** (slot poll/attach fan-out = separate ticket) **but
  fold in the one-line `ulimit -n` bump** to `aiur-engine.sh`/`aiurdev` so our own throttled
  re-measurement doesn't crash.
- H2: fully separate — don't touch anything FD-related here.
- H3: fix the fan-out too. Scope creep; different subsystem.
→ **H1.**

### I. Detection breadth for v1
- **I1 (recommended): mix + node (pnpm/npm/yarn) + cargo + go**, with a generic fallback (agent prompt)
  for anything unrecognized.
- I2: mix + node only (dogfood + most common), everything else → fallback.
→ **I1** (cheap to add the four; fallback covers the long tail). Confirm.

---

## Proposed implementation outline (if defaults accepted)

1. **Port `RepoBase` from #377** (reference `git show feat/warm-main-base:src/lib/aiur/repo_base.ex`),
   + config fields (`repo_base_poll_seconds`) + `hooks_file` plumbing already on main. Add **PubSub
   phase events** (`{:prewarm_phase, :cloning|:fetching|:building|:ready}`).
2. **Toolchain detection** at `init` (`deps.detect_toolchain`, mirror `detect_repo`): sniff
   `mix.exs`/`package.json`+lockfile/`Cargo.toml`/`go.mod` → a base build command, written into config
   (transparent + user-overridable). Undetected → fallback + the opt-in agent prompt.
3. **Eager async gate** in `orchestrator.ex maybe_dispatch/1` (scoped by `initial_dispatch_cycle`):
   start `RepoBase` refresh as a Task, hold `choose_issues` until `:ready`, re-enter on completion.
4. **aiur-owned materialization** in `workspace.ex create_workspace/1`: platform-aware
   `cp --reflink=auto -a` / `cp -c` from `RepoBase.base_path`; branch creation; cold-clone fallback
   when no base / remote worker / detection miss / build failure.
5. **Loading UI** in `agent_list/app.ex` + `renderer.ex`: add `prewarm_active?`/`prewarm_phase` state,
   thread through the `render/1` `Map.take`/`Map.put` pipeline, subscribe to the phase topic, draw a
   full-width bar + rotating labels reusing `spinner_frame/1`; clear on `:ready` **and** on first
   non-empty `:running_changed`.
6. **`ulimit -n` bump + cheap fork-reducers** (per the 2026-06-22 process-efficiency audit): raise
   `ulimit -n` in `packaging/npm/aiur-cli/libexec/aiur-engine.sh` + `scripts/aiurdev`; **batch the
   tmux liveness poll** (one `list-panes`/tick → ~32→2 forks/sec, `slot.ex:683`); **cache the tmux
   exe path** (`tmux.ex:767`/`:796`, one-line); **decouple `aiur_screen_grab` from `--debug`**
   (`pane_manager.ex:592-611` — its own flag, default off, so `--debug` gives logs without the
   per-pane `capture-pane` loop that scales with ticket count); delete the stale
   `attach_pool.ex:487-493` comment.
7. **Dogfood** aiur-self: detection fills aiur's own mix base build; `.aiur/hooks` simplifies.
8. **Tests** (TDD per unit: detection, RepoBase staleness, gate, materialization, render-pipeline)
   + full gate (`make -C src all`) + a **throttled manual re-measurement** (4–6 agents, raised
   `ulimit`) to confirm the boot→first-message win the crash hid.
9. **Deferred follow-up — issue [#409](https://github.com/aiur-team/aiur/issues/409)** (NOT in this
   PR; `enhancement`+`needs-triage`, no `agent:` label — schedule **after this PR merges**): the
   structural `:emfile`/process-efficiency reductions — pool `opencode-serve` to one shared serve, cap
   the AttachPool N×M fan-out (256→~M SessionWriters), event-driven pane-death (replaces the batched
   poll), and per-identifier SessionWriter subscription.

---

## Decisions — RESOLVED 2026-06-22

All settled; this is the design of record:

- **Automation (Q1):** detect toolchain → aiur auto-fills the one-time base build; **aiur (Elixir) owns the per-workspace copy**; agent-prompt fallback for undetected/exotic. Opt-in at end of `aiur init`.
- **Copy owner (Q2):** aiur-in-Elixir copy; cold-clone path kept as the opt-out fallback.
- **First run / freshness (Q3):** loading bar (opt-in at init OR a config pre-warm flag → first launch); **rebuild on every main advance, preempt in-flight stale builds, no debounce**; launch-during-build resumes the bar at the live phase.
- **`:emfile` (Q4):** `ulimit` bump + cheap fork-reducers **including decoupling `aiur_screen_grab` from `--debug`** in this PR; structural fixes → [#409](https://github.com/aiur-team/aiur/issues/409).
- **Detection breadth:** **Elixir + Node + Go + Rust + Python** (agent-prompt fallback otherwise).
- **Copy mechanism:** **`cp --reflink=auto -a` (Linux) / `cp -c` (macOS)**, platform-detected, degrading to full copy on ext4.
- **Consent:** **show the auto-detected build command for confirmation** before writing it into config / first run.
- **Dockerfile/CI reuse:** **SKIP** — lockfile/manifest detection via `mise exec`; the fallback agent may read a Dockerfile/CI when detection misses.
- **Confirmed defaults:** async eager gate · startup-eager + per-dispatch freshness net · event-driven loading phases · dogfood aiur-self.

_Original question menu retained below for the record._

**Must-decide (shape the architecture):**
- **Q1 — Automation strategy?** Recommend **A1** (detect toolchain + aiur-owned copy; dev-hooks become
  the fallback). Alternatives: A2 (eager #377, keeps dev hooks), A3 (CoW only — insufficient alone).
- **Q2 — Materialization ownership?** Recommend **B1** (aiur-Elixir owns the copy; `after_create`
  shrinks to ~nothing). Alternative: B2 (generated hook does the copy).
- **Q3 — First-run UX?** Recommend **F1** (block with bar in v1). Alternative: F2 (dispatch cold, swap
  to warm in background — better UX, more complexity).
- **Q4 — `:emfile` scope? RESOLVED** → `ulimit` bump **+ cheap fork-reducers in this PR** (audit-backed,
  outline step 6); structural fixes deferred to **#409** (after this PR merges, outline step 9). A
  process-efficiency audit confirmed the real waste is two O(N×M) patterns (attach fan-out, 500ms tmux
  poll), not "thousands of processes" everywhere.

**Confirm (recommended defaults assumed unless you say otherwise):**
- **Q5** — Eager gate is **async** (D1). Sync block is rejected (freezes the UI).
- **Q6** — **Startup-only** re-warm (E1); mid-run advances use the cheap per-dispatch path.
- **Q7** — Loading bar = **event-driven phases + time-rotated build sub-labels** (G1).
- **Q8** — Copy = **`cp --reflink=auto -a` / `cp -c`, platform-detected** (C1).
- **Q9** — Detection breadth = **mix + node + cargo + go**, generic fallback otherwise (I1).
- **Q10** — **Dogfood** on aiur-self as part of the PR.

---

## Phase 2 — the `/goal` to paste back

> Accept all recommended defaults → paste as-is. Want changes → add a "Deltas:" line at the top
> (e.g. "Deltas: Q3 = F2; Q9 = mix+node only") and I'll adjust before implementing.

```
/goal Implement the repo-agnostic eager prewarm for aiur, end-to-end, without stopping until the full
test+lint gate is green and a throttled manual run verifies the win.

Design of record: docs/brainstorms/2026-06-22-prewarm-design-research-and-questions.md — implement the
"Proposed implementation outline" using the recommended defaults (A1, B1, C1, D1, E1, F1, G1, H1, I1)
unless I noted Deltas above. Treat docs/brainstorms/2026-06-17-* and feat/warm-main-base as REFERENCE
ONLY (reuse RepoBase's mechanism via git show; do not merge that branch).

Run the full compound-engineering loop: /ce-plan → deepen → implement → /ce-code-review, on branch
feat/prewarm-base. Work in small commits (3–7 word messages), push as you go, never merge without my
explicit go-ahead. TDD each unit (detection, RepoBase staleness, async gate, in-Elixir materialization
+ cold-clone fallback, agent-list render-pipeline). Hold lint/credo until features work, then make
-C src all must pass (fmt-check + credo --strict + tests + dialyzer). Keep the cold-clone path
byte-for-byte unchanged for unconfigured/remote/exotic repos. Add the RepoBase PubSub phase events the
loading bar needs. Add the ulimit -n bump to the launch shims, and FILE (don't fix) a separate
:emfile/slot-poll-fan-out ticket. Finish with a throttled re-measurement (4–6 agents, raised ulimit)
proving boot→first-message dropped from minutes, and write the findings into docs/measurements/.
Surface blockers concisely and keep going; don't stop for confirmation on anything already decided here.
```
