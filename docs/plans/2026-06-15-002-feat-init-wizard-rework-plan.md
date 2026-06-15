---
title: "feat: aiur init wizard rework + launcher unification"
type: feat
status: active
date: 2026-06-15
origin: docs/brainstorms/2026-06-15-init-wizard-rework-requirements.md
---

# feat: aiur init Wizard Rework + Launcher Unification

## Overview

Rework the `aiur init` onboarding wizard so it feels like a real interactive
setup (arrow-key selectors, editable pre-filled inputs, short questions), make it
safely re-runnable around the GitHub-token/label gate, and collapse the divergent
`aiur` / `aiurdev` launchers into a single engine that differs only in which
release folder it runs.

Work is sequenced so the wizard UX lands and verifies first; the launcher
unification (largest, riskiest unit) is last.

---

## Problem Frame

The wizard makes the operator type option numbers, asks settings that should be
fixed or reworded, warns about a missing token before there's a reason to, and
can't resume a half-finished setup. It ends by telling users to run `aiur --bg`,
which the installed `aiur` binary doesn't implement — because the published
launcher (`packaging/npm/aiur-cli/libexec/aiur-launch.sh`) is a separate, thinner
reimplementation of `scripts/aiurdev` (2273 lines). See origin:
`docs/brainstorms/2026-06-15-init-wizard-rework-requirements.md`.

---

## Requirements Trace

- R1-R4. Interactive UI primitives (radio, multiselect, editable input, test seam).
- R5-R13. Reworded questions and flow (short wording, fixed `agent` prefix, agents
  multiselect with no RC hint, routing selector, permission radio, max-turns none,
  duration helper, pre-warm helper, specific polling question).
- R14-R15. App behavior: unbounded max-turns; `model:claude-remote` surfaced.
- R16-R24. Token-gated idempotent setup (no upfront warning, re-run skip + greyed
  summary, tag list/create, permission-fail `gh` fallback, missing-tag detection,
  final screen).
- R25-R28. Launcher unification: single engine; `aiur`/`aiurdev` differ only in
  release folder (+ dev build-if-stale); engine ships in npm package; release runs
  every command via `aiur`.

**Origin actors:** A1 (operator/end user), A2 (contributor/dev)
**Origin flows:** F1 (first-time onboarding, no token), F2 (re-run, create tags),
F3 (permission failure / missing tags)

---

## Scope Boundaries

- No new permission modes beyond `bypassPermissions` (others stay "coming soon").
- No full-screen TUI wizard — inline line-region prompts driven by raw-key reads.
- No change to how agents run/route/post PRs beyond labels, config, and launcher.
- No new Linear tag automation; Linear keeps its limited-support warning.
- Launcher unification ports the **existing** `aiurdev` command surface; it adds no
  new subcommands beyond making them reachable via `aiur`.

### Deferred to Follow-Up Work

- **Launcher unification (U11-U13) — deferred to its own effort** (operator decision,
  2026-06-15). The wizard rework (U1-U10) lands on `init-setup` now; the
  `aiur ≡ aiurdev` unification is a focused follow-up where installed mode can be
  live-tested against a cut release. Findings from the planning-time read:
  - **Divergent distribution contracts** (the core blocker): `aiur-launch.sh` uses
    cookie `~/.config/aiur/cookie` + node `aiur-${USER}@127.0.0.1`; `scripts/aiurdev`
    uses `~/.local/state/aiurdev/cookie` + node `aiurdev-${USER}@127.0.0.1`. RPC
    subcommands (`status`/`pause`/`resume`) only reach a node with the matching
    cookie+name, so unification must first align this contract — which changes
    `aiurdev`'s node name and breaks running dev sessions and the tests asserting
    `RELEASE_NODE=aiurdev-`.
  - **Deep dev coupling**: every functional command (`run`/`--bg`/`stop`/`status`/
    `list`) is tied to profiles + `mise` + `_build` + repo paths; installed mode has
    none of these, so there is no small slice — profile resolution, build-gating,
    release-invocation, and the interactive-run boot all need a mode switch.
  - **Two interactive-run boots**: dev runs `src/bin/aiur` (an `elixir --eval` custom
    launcher via `mise`); installed runs `aiur-launch.sh`'s `elixir --eval` + tmux.
    These are similar but separate and must be collapsed behind one `run_release`
    abstraction.
  - **No installed-mode verification in this environment**: confirming the live
    `aiur --bg`/`stop`/`status` round-trip needs a relocated release + tmux + a
    running node; only the dev path and harness-mocked routing are testable here.
  - Recommended approach: make `scripts/aiurdev` the single mode-aware engine
    (`AIUR_RELEASE_DIR`-driven), align the cookie/node contract behind a shared
    state dir, ship the engine in the npm package, and point `bin/aiur.js` at it.
  - **Note:** the wizard's final screen references `aiur --bg`, which only works once
    this lands. Left as the operator's chosen wording (single-user tool; the launcher
    work is the immediate next effort).

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/os.ex` — `Aiur.Os.stty/1` sets termios flags on the **real
  controlling terminal** via `Port.open` with `:nouse_stdio`. Reuse for raw mode.
- `src/lib/aiur/agent_list/input.ex` — canonical raw-key reader: enters raw mode
  (`stty -icanon -echo -isig -ixon min 0 time 1`), reads bytes via
  `IO.binread(:stdio, 1)`, parses CSI arrows (`\e[A`=up, `\e[B`=down), restores via
  `stty sane`. Mirror its escape-parsing for the selector.
- `src/lib/aiur/init.ex` — current wizard; injectable `io`/`deps` seams to preserve.
- `src/lib/aiur/github/labels.ex` — `label_set/3` = state (`<prefix>:<suffix>`) +
  `model_labels(backends)` + `complexity:1-5`. State suffixes in `@state_suffixes`.
- `src/lib/aiur/coding_agent.ex` — `override_labels/1` already includes
  `model:claude-remote` via `alias_labels/0` (verified); `remote_control_alias_label/0`.
- `src/lib/aiur/agent_runner.ex` — max_turns sites: `:413` (resolve), `:627` +
  `:1321` (prompt "turn N of M"), `:699` + `:739` (`turn_number < max_turns` guards).
- `src/lib/aiur/config/schema.ex` — `Agent.max_turns` `:277` (default 20),
  validated `> 0` at `:317`.
- `src/lib/aiur/config.ex` — `agent_max_turns/0` `:207`.
- `scripts/aiurdev` — full command surface; main dispatch at `:2170` (list/status/
  pause/resume/build/--bg/run/stop/sweep/init/default/ad-hoc). `init` case `:2247`
  uses `bin/aiur eval` (-noinput).
- `packaging/npm/aiur-cli/libexec/aiur-launch.sh` — installed launcher; dispatches
  only `init` (interactive `elixir --eval`, `build_init_cmd`) and interactive run.
- `packaging/npm/aiur-cli/bin/aiur.js` — Node shim; resolves platform release dir.

### Institutional Learnings

- Manual TUI driver pattern (AGENTS.md): non-TTY agents drive the wizard via a
  separate tmux + send-keys, which can deliver arrow-key escape sequences — the
  manual-verification path for the interactive selectors.
- `feedback_defer_lint_until_working` / `feedback_implementation_loop`: keep
  compile+tests green per unit, defer credo until working, run credo before push,
  small 3-7 word commits, push as you go.

### External References

- None needed; raw-key input, label, and config patterns all exist in-repo.

---

## Key Technical Decisions

- **Reuse the in-repo raw-key stack** (`Os.stty` + `IO.binread` + CSI parsing) for
  selectors rather than adding a TUI dep. Proven on the controlling terminal,
  degrades on non-TTY.
- **Synchronous selector, not a GenServer.** `AgentList.Input` is a long-lived
  GenServer feeding an app. The wizard needs a blocking `select → value` call, so
  the new module reads keys inline (enter raw mode → loop reading bytes, redrawing
  the option list → restore on Enter), returning the chosen value.
- **Init must run via interactive `--eval`, not `bin/aiur eval`.** `bin/aiur eval`
  is `-noinput`; raw `IO.binread(:stdio,1)` needs stdin connected. The installed
  launcher already does this (`build_init_cmd`); `aiurdev init` must be switched to
  match (U2) before the selector can be verified through `aiurdev`.
- **max-turns "none" = `nil` in the schema** (no numeric default). `nil` means
  uncapped; a present value must still be `> 0`. Runner gains an `under_turn_cap?`
  helper; prompts say "turn N" (no "/M") when uncapped. This changes the default
  for configs that omit `max_turns` (was 20 → now uncapped) — intended per R10.
- **Fixed label prefix `agent`** replaces the configurable `aiur` default; remove
  the prefix question. State labels become `agent:todo`, etc.
- **Single launcher engine = the npm `aiur-launch.sh`, expanded.** It owns every
  subcommand, parameterized by `AIUR_RELEASE_DIR`. `scripts/aiurdev` becomes a thin
  resolver: resolve local `_build/dev/rel/aiur`, do dev-only build-if-stale, then
  `exec` the engine. One source of truth, shipped in the package and reused in dev.

---

## Open Questions

### Resolved During Planning

- max-turns "none" representation → `nil` sentinel (see Key Decisions).
- Engine physical layout → expand `packaging/npm/aiur-cli/libexec/aiur-launch.sh`;
  `aiurdev` execs it (see Key Decisions).
- Does the selector need a launcher change? → Yes, the interactive `--eval` form
  (U2), because `bin/aiur eval` is `-noinput`.

### Deferred to Implementation

- **Pre-warm RAM figure (R12):** measure resident size of one pre-warmed opencode
  session on the dev box if trivially available; otherwise phrase the helper
  qualitatively ("each pre-warmed session keeps an opencode process resident; set
  this to how many you expect open at once"). Do **not** ship a fabricated number.
- **Whether raw `IO.binread` actually delivers keystrokes under the installed
  `elixir --eval` boot** vs. needing additional `:io.setopts` — verify when wiring
  U1/U2; the `AgentList.Input` precedent strongly suggests it works under a normal
  foreground boot.
- **Profile/mise handling in the engine (U11):** which `aiurdev` machinery is truly
  dev-only (mise toolchain, build-if-stale, repo-root, multi-profile config) vs.
  shared (tmux, cookie, RPC control_command, --bg/stop/pause/resume). Separate the
  resolver concerns from the functional engine during extraction.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review,
> not implementation specification. The implementing agent should treat it as
> context, not code to reproduce.*

Selector control flow (synchronous, per prompt):

```
select(label, options, default):
  if not a tty (or io seam injected):  -> fall back to injected/answer or line read
  enter_raw_mode()                      # Os.stty(-icanon -echo ...)
  cursor = index_of(default)
  loop:
    render(label, options, cursor)      # redraw in place; highlight cursor row
    key = read_key()                    # IO.binread + CSI parse: :up/:down/:space/:enter/char
    case key:
      :up   -> cursor = max(0, cursor-1)
      :down -> cursor = min(last, cursor+1)
      :enter-> restore_terminal(); return options[cursor]   # multiselect: toggled set
      :space (multiselect) -> toggle(cursor)
```

Launcher unification target:

```
bin/aiur.js (npm) ─┐
                   ├─ AIUR_RELEASE_DIR=<dir> ─> aiur-launch.sh (THE ENGINE)
scripts/aiurdev ───┘        (resolve folder; dev: build-if-stale)   owns all subcommands
```

---

## Implementation Units

### Phase 1 — Interactive input foundation

- [ ] U1. **Raw-mode interactive prompt module**

**Goal:** A reusable synchronous prompt component: single-select radio (↑/↓+Enter),
multi-select (↑/↓+Space+Enter), and editable pre-filled text input.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/init/prompt.ex`
- Test: `src/test/aiur/init/prompt_test.exs`

**Approach:**
- Reuse `Aiur.Os.stty/1` for raw mode and `IO.binread(:stdio, 1)` for byte reads;
  mirror the CSI parsing in `src/lib/aiur/agent_list/input.ex` (`\e[A`/`\e[B`).
- Inject the byte reader and a `tty?`/raw-mode toggle so tests script keystrokes
  without a terminal (same seam style as `AgentList.Input`'s `:input_fun` /
  `:skip_raw_mode`). On non-TTY, degrade to reading a line / returning default.
- Editable input: pre-seed the buffer with the default, render it, handle
  printable chars + Backspace (`\d`/`\x7f`) + Enter; return the edited string.
- Always restore the terminal (`stty sane`, show cursor) even on error.

**Patterns to follow:**
- `src/lib/aiur/agent_list/input.ex` (raw mode enter/restore, CSI parse).

**Test scenarios:**
- Happy path: radio — scripted `↓ ↓ Enter` returns the third option.
- Happy path: multiselect — `Space ↓ Space Enter` returns the two toggled values.
- Happy path: editable input — default pre-filled, `Enter` returns the default;
  Backspace + typed chars returns the edited value.
- Edge case: cursor clamps at top/bottom (`↑` at index 0 stays 0; `↓` at last stays).
- Edge case: non-TTY / `skip_raw_mode` path returns default or injected answer
  without invoking stty.
- Error path: reader raises/`:eof` mid-prompt → terminal still restored (assert
  restore hook called).

**Verification:** Component returns correct values for scripted key sequences;
no crash and terminal restored on the non-TTY and error paths.

---

- [ ] U2. **Route init through interactive `--eval`**

**Goal:** Ensure `aiur init` (dev + installed) runs with stdin connected so raw
keystrokes reach the wizard.

**Requirements:** R4 (enables R1-R3 live)

**Dependencies:** None (precedes live verification of U3+)

**Files:**
- Modify: `scripts/aiurdev` (the `init)` case, ~`:2247`)
- Reference: `packaging/npm/aiur-cli/libexec/aiur-launch.sh` (`build_init_cmd`)

**Approach:**
- Switch `aiurdev init` from `bin/aiur eval "..."` (-noinput) to the interactive
  `elixir --eval` form the installed launcher already uses for init (distribution-
  free boot, stdin connected). Keep `AIUR_ARGV_FILE` plumbing.
- Confirm the installed path already uses the interactive form (no change expected).

**Patterns to follow:**
- `build_init_cmd` in `aiur-launch.sh`.

**Test scenarios:**
- `Test expectation: none` — shell launch-path change; covered by the existing
  `src/test/scripts_aiurdev_test.exs` init-routing test (keep green) and manual
  verification in U3. (No new unit test; bash invocation form isn't unit-testable
  without a release.)

**Verification:** `aiurdev init` reaches `Aiur.CLI.main` with a connected stdin
(manually: arrow keys move the U3 selector).

---

### Phase 2 — Wizard flow rework

- [ ] U3. **Reworded questions + selectors + agent prefix**

**Goal:** Replace numbered prompts with U1 components and reword the core flow.

**Requirements:** R5, R6, R7, R9

**Dependencies:** U1, U2

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/test/aiur/init_test.exs`
- Modify: `.aiurconfig.example` (drop label-prefix token; fix prefix `agent`)

**Approach:**
- Swap `io.select`/`io.multiselect`/`io.input` call sites to the U1-backed
  implementations (keep the injectable `io` map so tests stay scripted by label).
- Short wording: "Where will you store aiur settings?" (repo / global); "Where
  should agents work?" (workspace). Remove the label-prefix question; hardcode
  `agent` everywhere the prefix is used (template fill + `setup_labels`).
- Agents: multiselect; remove the remote-control hint at selection time.
- Permission mode: radio; unsupported modes shown greyed "coming soon"; any
  interactive selection resolves to `bypassPermissions`.

**Patterns to follow:**
- Existing label-keyed scripted `io` in `src/test/aiur/init_test.exs`.

**Test scenarios:**
- Happy path: github flow writes `tracker.kind=github`, no label-prefix key, state
  labels use `agent` prefix.
- Covers F1. Repo-local run still creates the starter prompt file (R16 preserved).
- Edge case: selecting an interactive permission mode → config gets
  `bypassPermissions` and a "coming soon" line is printed.
- Edge case: agent-selection screen prints **no** remote-control hint.
- Error/guard: existing `--force` / existing-config guard tests stay green.

**Verification:** Wizard runs end-to-end with arrow keys; written config uses the
`agent` prefix; permission mode resolves correctly.

---

- [ ] U4. **Routing walkthrough via selector**

**Goal:** Per-complexity routing uses an arrow-key selector and explains the
`claude` == current-default-version semantics.

**Requirements:** R8

**Dependencies:** U1, U3

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/test/aiur/init_test.exs`

**Approach:**
- Replace the numbered per-level `io.select` with the radio selector for each
  `complexity:1..5`. Options include `codex`, `claude`, `claude:sonnet`, etc.
  (built from selected agents + known variants).
- Print a one-line note that `claude` resolves to whatever the default Claude
  version is at run time.
- Keep writing `backend:model` routing values (existing `split_routing_value`).

**Test scenarios:**
- Happy path: scripted selections write `routing[1]=codex`, `routing[5]=claude:sonnet`.
- Edge case: "set models per complexity?" = false → all five default to the primary
  backend (existing behavior preserved).
- Happy path: the `claude == current default version` note is printed.

**Verification:** Routing map reflects per-level selector choices.

---

- [ ] U5. **Limits + helper-text rewording**

**Goal:** Reword max-turns (none), max-agent-duration, pre-warm, and polling prompts.

**Requirements:** R10, R11, R12, R13

**Dependencies:** U1, U3

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/test/aiur/init_test.exs`
- Modify: `.aiurconfig.example` (max_turns none/commented; helper comments)

**Approach:**
- Max turns: default "none" (writes no `max_turns` / explicit none → nil per U6).
- Max agent duration: label "fallback for stuck agents"; reword disable semantics
  to be unambiguous (state what an empty/none value means).
- Pre-warm: "How many opencode sessions would you like to pre-warm?" + greyed
  helper. Use a measured RAM figure if trivially available, else qualitative text
  (see Deferred to Implementation). No fabricated number.
- Polling: question text itself states what it does ("how often aiur checks the
  tracker for new `agent:todo` work").

**Test scenarios:**
- Happy path: choosing "none" for max-turns writes a config that loads with
  uncapped turns (assert the written value maps to nil/uncapped per U6).
- Happy path: polling prompt string contains the specific "checks the tracker"
  explanation (assert on emitted prompt text).
- Edge case: numeric max-agent-duration still writes `max_agent_duration_minutes`.

**Verification:** Prompts read clearly; written config round-trips through
`Workflow.load`.

---

### Phase 3 — App behavior

- [ ] U6. **Unbounded max-turns support**

**Goal:** A "none" max-turns config means the autonomous loop is never capped by
turn count.

**Requirements:** R14

**Dependencies:** None (consumed by U5's written value)

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` (`Agent.max_turns` nilable; validation)
- Modify: `src/lib/aiur/config.ex` (`agent_max_turns/0`)
- Modify: `src/lib/aiur/agent_runner.ex` (turn-cap guards + prompt text)
- Modify/Create: `src/test/aiur/agent_runner_*` or schema/config tests as fitting
- Modify: `src/test/aiur/workspace_and_config_test.exs`

**Approach:**
- Schema: `max_turns` becomes nilable with no numeric default; when present must be
  `> 0`. `nil` = uncapped. Decide YAML spelling ("none"/absent → nil) in cast.
- Runner: add `under_turn_cap?(turn_number, max_turns)` =
  `is_nil(max_turns) or turn_number < max_turns`; use it at `:699`/`:739`.
  `build_turn_prompt` emits "turn N" (omit "/M") when uncapped.
- Config accessor returns nil for uncapped.

**Execution note:** Add the failing schema/runner test for the nil/uncapped case
first, then implement.

**Test scenarios:**
- Happy path: `max_turns: none` (or omitted) → schema parses to nil; `under_turn_cap?`
  returns true for arbitrarily large `turn_number`.
- Edge case: `max_turns: 0` or negative → validation error (must be `> 0` when set).
- Happy path: explicit `max_turns: 3` still caps at 3 (`under_turn_cap?(3,3)=false`).
- Edge case: continuation prompt omits "/M" when uncapped, includes it when capped.

**Verification:** Capped and uncapped configs both validate and drive the loop
correctly; prompt text matches.

---

### Phase 4 — Token-gated idempotent setup

- [ ] U7. **Token-gate message (no upfront warning)**

**Goal:** With no `GITHUB_TOKEN`, print a calm "set token in `.env` and re-run"
message with minimum-scope steps; exit success.

**Requirements:** R17, R20

**Dependencies:** U3

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/test/aiur/init_test.exs`

**Approach:**
- Remove the scary up-front "GITHUB_TOKEN not set" warning. After writing config,
  if no token present, print the concise set-token-and-rerun guidance + the
  minimum scopes the agent/label creation actually need, then return `:ok`.
- Keep `.env` scaffolding.

**Test scenarios:**
- Happy path (Covers F1): no token → message includes "run `aiur init` again" and
  the token-scope steps; no alarming warning string; returns `:ok`.
- Edge case: token present → skips the guidance and proceeds to tag flow (U9).

**Verification:** First run with no token ends calmly with a clear single next step.

---

- [ ] U8. **Re-run skip-intro + greyed summary**

**Goal:** When `.aiurconfig` already exists, skip the intro questions and show a
greyed concise summary of saved selections.

**Requirements:** R18

**Dependencies:** U3

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/test/aiur/init_test.exs`

**Approach:**
- Detect existing config (the existing-config path already exists for the guard).
  Instead of only aborting on non-`--force`, when config is valid, branch into a
  "resume" mode: load it, print a greyed summary (`max_concurrent_agents: 10`,
  `tracker: github`, etc.), and continue to the token/tag flow rather than
  re-asking. Preserve the `--force` path to re-run the full intro.

**Test scenarios:**
- Happy path (Covers F2): existing valid config → intro questions are not asked
  (assert no intro prompts emitted), greyed summary lines printed, flow proceeds to
  tags.
- Edge case: `--force` with existing config → full intro runs (existing behavior).
- Edge case: malformed existing config → clear error, not a crash.

**Verification:** Re-running `aiur init` on a finished config resumes instead of
re-interrogating.

---

- [ ] U9. **Tag list/create + permission-fail fallback + final screen**

**Goal:** With a valid token, list every label (with descriptions) and create them;
on permission failure emit a copy-paste `gh` command; on success show the final
ready screen.

**Requirements:** R15, R19, R21, R22, R24

**Dependencies:** U7, U8

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/lib/aiur/github/labels.ex` (label → description mapping)
- Modify: `src/test/aiur/init_test.exs`

**Approach:**
- Build the full label set via `Labels.label_set("agent", backends)` (state +
  `model:*` incl. `model:claude-remote` + `complexity:1-5`); attach a couple-word
  description per label (incl. `model:claude-remote` → "Forces remote-control mode
  at launch"). Print the list, then create (existing left as-is).
- On a permission error from label creation, print a `gh label create …` command
  (one per label) the operator can paste, and tell them to re-run to confirm.
- On success, print the final screen: add `agent:todo` labels to issues; run
  `aiur` (foreground) or `aiur --bg` (background). (The `--bg` command is made real
  by Phase 5.)

**Test scenarios:**
- Happy path (Covers F2): valid token → label list printed with descriptions incl.
  `model:claude-remote`; `create_labels` invoked with the full set; final screen
  printed.
- Error path (Covers F3): `create_labels` returns permission error → a `gh label
  create` command is printed for the labels and a "re-run to confirm" line.
- Happy path: final screen names `agent:todo`, `aiur`, and `aiur --bg`.

**Verification:** Tags are listed and created; permission failure yields an exact
remediation command; success reaches the ready screen.

---

- [ ] U10. **Missing-tag detection on later runs**

**Goal:** On subsequent runs, detect which required labels are missing, warn, and
emit a `gh` command for only the missing ones.

**Requirements:** R23

**Dependencies:** U9

**Files:**
- Modify: `src/lib/aiur/init.ex`
- Modify: `src/lib/aiur/github/labels.ex` (diff existing vs required)
- Modify: `src/test/aiur/init_test.exs`

**Approach:**
- Fetch existing repo labels (via the deps/Labels seam), diff against the required
  set, and if any are missing, warn and print a `gh label create` command scoped to
  only the missing labels. If none missing, proceed to the final screen.

**Test scenarios:**
- Happy path (Covers F3): some labels missing → warning + `gh` command lists only
  the missing labels (assert the present ones are absent from the command).
- Happy path: all labels present → no warning, final screen shown.
- Edge case: label fetch fails → graceful message, no crash.

**Verification:** Re-running converges to "all present → final screen"; missing-tag
command is minimal.

---

### Phase 5 — Launcher unification

- [ ] U11. **Extract single launcher engine**

**Goal:** Expand `aiur-launch.sh` into the engine that owns the full command
surface, parameterized by `AIUR_RELEASE_DIR`.

**Requirements:** R25, R27

**Dependencies:** U2 (init invocation already interactive)

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-launch.sh`
- Reference: `scripts/aiurdev` (port `list`/`status`/`pause`/`resume`/`--bg`/`run`/
  `stop`/`sweep` + control_command RPC + tmux/cookie helpers)
- Modify/Create: `packaging/npm/aiur-cli/test/launcher.test.mjs` (dispatch coverage)

**Approach:**
- Port the functional subcommands and their helpers (cookie/distribution, tmux
  session mgmt, `control_command` RPC, bg pid/state-dir, stop/sweep) from `aiurdev`
  into the engine, reading the release dir from `AIUR_RELEASE_DIR`.
- Keep release-dir resolution and any dev-only steps OUT of the engine (those move
  to the resolvers in U12 / stay in `aiur.js`).
- Decide profile handling: keep multi-profile support but ensure a single default
  works for the installed path (see Deferred to Implementation).

**Test scenarios:**
- Happy path: engine dispatches each subcommand to the right code path given a fake
  `AIUR_RELEASE_DIR` (extend `launcher.test.mjs` to assert routing, mocking exec).
- Edge case: unknown subcommand → usage/error, non-zero exit.
- Edge case: missing `AIUR_RELEASE_DIR` → clear error (existing guard).

**Verification:** A single script handles every documented subcommand; no command
logic remains duplicated between engine and `aiurdev` after U12.

---

- [ ] U12. **Reduce `aiurdev` to a thin resolver**

**Goal:** `scripts/aiurdev` only resolves the local build folder (+ dev-only
build-if-stale) and execs the shared engine.

**Requirements:** R26

**Dependencies:** U11

**Files:**
- Modify: `scripts/aiurdev`
- Modify: `src/test/scripts_aiurdev_test.exs`

**Approach:**
- Replace the in-script command surface with: resolve `repo_root/src/_build/dev/rel/
  aiur`, run build-if-stale (existing `ensure_built`/`build_aiur`), set
  `AIUR_RELEASE_DIR`, then `exec` the engine with the original argv.
- Preserve dev affordances that are genuinely dev-only (`build`, `--fresh`, mise).

**Test scenarios:**
- Happy path: `aiurdev <cmd>` resolves the local release dir and execs the engine
  with that dir + argv (extend/keep `scripts_aiurdev_test.exs`).
- Happy path: `aiurdev init` still reaches the wizard (interactive `--eval`).
- Edge case: stale build triggers rebuild before exec.

**Verification:** `aiurdev` behavior is unchanged for the user, but its body no
longer contains command logic — only resolution + build + exec.

---

- [ ] U13. **Verify installed `aiur` command parity**

**Goal:** A freshly cut release runs every documented command via `aiur`.

**Requirements:** R28

**Dependencies:** U11, U12

**Files:**
- Modify: `packaging/npm/aiur-cli/bin/aiur.js` (pass through full argv to engine)
- Modify: `packaging/npm/aiur-cli/test/launcher.test.mjs`
- Modify: `packaging/npm/aiur-cli/README.md` (document the command surface)

**Approach:**
- Ensure `aiur.js` forwards all argv to the engine (not just init/run) with
  `AIUR_RELEASE_DIR` set to the platform package's `release/`.
- Add/extend launcher tests asserting `aiur <cmd>` routes through the engine for at
  least `init`, foreground run, `--bg`, `stop`.

**Test scenarios:**
- Happy path: `aiur --bg` / `aiur stop` / `aiur list` route through the engine
  (mocked exec) with the installed release dir.
- Edge case: unsupported platform / missing platform package → existing clear error.

**Verification:** Manual smoke (or mocked-exec tests) confirm the installed `aiur`
exposes the same commands as `aiurdev`; README lists them.

---

## System-Wide Impact

- **Interaction graph:** U6 touches the autonomous loop guards in `agent_runner.ex`
  — both the normal-completion (`:699`) and resume (`:739`) paths must use the same
  cap helper, plus the prompt builder. U9/U10 touch GitHub label creation/listing.
- **Error propagation:** Wizard auth/label failures must never crash the wizard —
  warn and continue / emit a remediation command (existing `run_auth_check`
  posture). Selector must restore the terminal on any error.
- **State lifecycle risks:** Re-run resume (U8) must not double-write or clobber a
  valid config; tag creation must be idempotent (existing labels left as-is).
- **API surface parity:** The launcher engine is the shared surface; after U11-U13
  there must be exactly one implementation of each subcommand.
- **Integration coverage:** The raw-TTY selector and the launcher dispatch are only
  fully proven on a real terminal/release — covered by manual verification, not
  unit tests alone.
- **Unchanged invariants:** Agent routing, PR posting, and orchestrator behavior are
  unchanged except for the uncapped-turns option and the fixed `agent` prefix.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Raw `IO.binread` doesn't deliver keys under the installed `--eval` boot | U2 aligns the invocation with the proven `build_init_cmd`; `AgentList.Input` precedent; verify early, before building Phase 2 on it. |
| Selector leaves the terminal in raw mode on crash | Always restore in an `after`/rescue; test the error path asserts restore. |
| Launcher unification (U11-U13) balloons / regresses dev workflow | Sequence last; keep `aiurdev` UX identical; lean on `launcher.test.mjs`; allow it to slice into its own PR if needed. |
| Default max-turns change (20 → uncapped) surprises existing configs | Documented intended change (R10); explicit test for capped vs uncapped; `.aiurconfig.example` documents it. |
| Non-TTY environments (CI, piped) break the wizard | Selector degrades to default/injected on non-TTY; tests use the injected seam. |

---

## Documentation / Operational Notes

- Update `.aiurconfig.example` for the fixed `agent` prefix, max-turns none, and
  helper comments.
- Update `packaging/npm/aiur-cli/README.md` with the unified command surface.
- AGENTS.md manual-driver recipe still applies for verifying the selectors.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-15-init-wizard-rework-requirements.md](docs/brainstorms/2026-06-15-init-wizard-rework-requirements.md)
- Related code: `src/lib/aiur/os.ex`, `src/lib/aiur/agent_list/input.ex`,
  `src/lib/aiur/init.ex`, `src/lib/aiur/github/labels.ex`,
  `src/lib/aiur/agent_runner.ex`, `scripts/aiurdev`,
  `packaging/npm/aiur-cli/libexec/aiur-launch.sh`
- Related branch: `init-setup`
