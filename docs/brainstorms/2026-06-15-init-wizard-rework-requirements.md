---
date: 2026-06-15
topic: init-wizard-rework
---

# aiur init Wizard Rework + Launcher Unification

## Problem Frame

The `aiur init` onboarding wizard (branch `init-setup`) works but is rough: it
makes the operator type numbers to choose options, asks settings that should be
fixed or reworded, warns about a missing token before there's any reason to, and
isn't idempotent across re-runs (it can't pick up where a half-finished setup
left off). It also ends by telling users to run `aiur --bg`, a command the
installed `aiur` binary does not implement.

That last point exposed a structural problem: the published `aiur` launcher
(`packaging/npm/aiur-cli/libexec/aiur-launch.sh`) is a *separate, thinner
reimplementation* of `scripts/aiurdev`. The two have diverging command surfaces
we'd have to keep in sync forever. The intended relationship is that they are the
same program differing only in which release folder they target.

This rework makes the wizard feel like a real interactive setup, makes it safely
re-runnable around the GitHub-token gate, and collapses `aiur`/`aiurdev` into a
single launcher engine.

---

## Actors

- A1. Operator (end user): runs `aiur init` in their repo to onboard, then runs
  `aiur` / `aiur --bg` to start agents. Uses the installed (npm) binary.
- A2. Contributor (dev): runs `aiurdev …` against the local build. Must get
  identical behavior to A1, differing only in which release folder runs.

---

## Key Flows

- F1. First-time onboarding (no token yet)
  - **Trigger:** Operator runs `aiur init` in a fresh repo.
  - **Actors:** A1
  - **Steps:** Answer reworded questions via arrow-key selectors and editable
    inputs (location, tracker, agents, routing, permission mode, workspace,
    limits, pre-warm, polling) → wizard writes `.aiurconfig` (+ starter prompt
    file for repo-local) → because no `GITHUB_TOKEN` is set, wizard prints a
    concise "set a token in `.env` and run `aiur init` again" message with
    minimum-scope token steps, then exits cleanly.
  - **Outcome:** A valid `.aiurconfig` exists; operator knows the single next
    action. No alarming warning.
  - **Covered by:** R1-R16, R17, R18

- F2. Re-run after setting the token (create tags)
  - **Trigger:** Operator sets `GITHUB_TOKEN` and runs `aiur init` again.
  - **Actors:** A1
  - **Steps:** Wizard detects an existing `.aiurconfig`, skips the intro
    questions, shows a greyed concise summary of saved selections → with a valid
    token it lists every tag it will create (state + model + complexity, incl.
    `model:claude-remote`) each with a short description, then creates them → on
    success advances to the final screen.
  - **Outcome:** Repo has all routing labels; operator reaches the "you're ready"
    screen.
  - **Covered by:** R18, R19, R20, R21, R24

- F3. Token lacks label permission / tags partially missing
  - **Trigger:** Re-run where the token can't create labels, or a later run finds
    some labels missing.
  - **Actors:** A1
  - **Steps:** Wizard detects which labels are missing → prints a copy-paste `gh`
    command that creates **only** the missing ones → tells the operator to re-run
    `aiur init` to confirm.
  - **Outcome:** Operator has an exact, minimal remediation command; re-running
    converges to "all tags present → final screen."
  - **Covered by:** R22, R23, R24

---

## Requirements

**Interactive UI primitives**
- R1. Single-select prompts are arrow-key radio selectors (↑/↓ to move, Enter to
  confirm), not numbered entry.
- R2. Multi-select prompts (e.g. agents) use ↑/↓ to move, Space to toggle, Enter
  to confirm.
- R3. Text inputs that have a detected/default value render that value
  pre-filled on the editable input line, so the operator can accept it with
  Enter or edit/delete it (used for the auto-detected repo).
- R4. The interactive components keep the existing injectable `io` seam so unit
  tests script answers without a real terminal; on a non-TTY they degrade
  gracefully (no crash).

**Question wording and flow**
- R5. Questions are short ("Where will you store aiur settings?" → repo / global;
  "Where should agents work?" for workspace root; etc.).
- R6. Remove the label-prefix question; the prefix is fixed to `agent` (state
  labels become `agent:todo`, `agent:in-progress`, …).
- R7. Agent selection is multi-select with no remote-control hint shown at
  selection time (RC is introduced only at tag creation).
- R8. The per-complexity routing walkthrough is an arrow-key selector and
  explains that the bare `claude` option means "whatever the current default
  Claude version is at run time"; options include forms like `claude:sonnet`.
- R9. Permission mode is an arrow-key radio; unsupported modes are shown greyed
  with "coming soon" and any interactive choice resolves to `bypassPermissions`.
- R10. Max-turns-per-issue defaults to "none" (unlimited).
- R11. The max-agent-duration prompt is labeled as a "fallback for stuck agents"
  and its disable semantics are reworded to be unambiguous.
- R12. The pre-warm prompt ("How many opencode sessions would you like to
  pre-warm?") includes greyed helper text with an *accurate* per-session RAM
  figure (or omits the number rather than guess).
- R13. The polling-interval question text itself states specifically what polling
  does (how often aiur checks the tracker for new `agent:todo` work).

**App behavior changes**
- R14. The app supports unbounded max-turns: a "none" config value means the
  autonomous loop is never capped by turn count.
- R15. `model:claude-remote` remains the canonical RC-forcing label and is
  surfaced (with description "Forces the agent into remote-control mode at
  launch") in the tag list; it stacks with version labels like
  `model:claude-opus-4-8`.

**Token-gated, idempotent setup**
- R16. Repo-local init creates the starter prompt file the config references;
  global init omits `prompt_file` (repo auto-detected at runtime). (Already true;
  preserve through the rework.)
- R17. When no `GITHUB_TOKEN` is present, the wizard does **not** show a scary
  warning. It prints a concise "set a token in `.env` and run `aiur init` again
  to continue creating repo tags" message plus minimum-necessary-scope steps to
  generate the token, then exits success.
- R18. On any run where `.aiurconfig` already exists, the wizard skips the intro
  questions and prints a greyed, concise summary of the saved selections (e.g.
  `max_concurrent_agents: 10`) so the operator sees prior answers are persisted.
- R19. With a valid token, the wizard lists every label it will create — state
  (`agent:*`), model (`model:*`, incl. `model:claude-remote`), and
  `complexity:1-5` — each with a couple-word description, then creates them
  (existing labels left as-is).
- R20. The token's minimum required scope is documented in the token-setup steps
  (only what the agent and label creation actually need).
- R21. On successful label creation, the wizard advances to the final screen.
- R22. If the token cannot create labels, the wizard prints a copy-paste `gh`
  command the operator can run to create them, and tells them to re-run
  `aiur init` to confirm.
- R23. On later runs, the wizard detects which required labels are missing, warns,
  and prints a `gh` command that creates only the missing labels.
- R24. The final screen (config valid + all labels present) tells the operator
  they can now (1) add `agent:todo` labels to issues and (2) run `aiur`
  (foreground) or `aiur --bg` (background).

**Launcher unification (`aiur` ≡ `aiurdev`)**
- R25. There is a single launcher engine that implements the entire command
  surface (init, foreground run, `--bg`, `stop`, `list`, `status`, `pause`,
  `resume`, `run`, profiles, distribution/cookie, tmux). No command logic is
  duplicated between `aiur` and `aiurdev`.
- R26. `aiur` (installed) and `aiurdev` (local build) differ only in which
  release folder they resolve and exec the engine against; `aiurdev` additionally
  performs a dev-only build-if-stale step. No functional command differs between
  them.
- R27. The engine ships in the npm package so the installed `aiur` runs every
  command, and is re-used by `aiurdev` from the repo (single source of truth).
- R28. After this unit, a freshly cut release can run every documented command
  via `aiur` (verified for at least `init`, foreground run, `--bg`, `stop`).

---

## Success Criteria

- An operator can onboard end-to-end with arrow keys only (no typing option
  numbers), set a token, re-run, get all labels created, and reach a final
  screen whose commands actually work on the installed `aiur` binary.
- Re-running `aiur init` is always safe: it never clobbers a finished config,
  resumes the token/label flow, and converges to "ready."
- A contributor and an end user get identical command behavior; the only
  maintained difference is which folder runs. There is no second copy of the
  command surface to keep in sync.
- Downstream implementer (`/ce-plan`) can sequence units without inventing
  product behavior: each requirement is observable or marked structural.

---

## Scope Boundaries

- Not adding new permission modes beyond `bypassPermissions`; others stay
  "coming soon" placeholders.
- Not building a TUI-based wizard (full-screen forms); these are inline
  line-region prompts driven by raw-key reads.
- Not changing how agents actually run, route, or post PRs — only the labels,
  config, and launcher surface around them.
- Not adding non-GitHub tag automation; Linear stays the lightly-tested path with
  its existing limited-support warning.
- Launcher unification ports the **existing** `aiurdev` command surface; it does
  not add new subcommands beyond what already exists (plus making them reachable
  via `aiur`).

---

## Key Decisions

- Reuse `Aiur.Os.stty/1` + `IO.binread(:stdio, 1)` + CSI arrow parsing (the same
  mechanism `Aiur.AgentList.Input` already uses) for the wizard's interactive
  selectors, rather than adding a TUI dependency. Rationale: proven in-repo,
  works on the real controlling terminal, degrades on non-TTY.
- The wizard runs through the launcher's interactive `--eval` path (stdin
  connected, not `bin/aiur eval` which is `-noinput`), so raw-key reads work
  without launcher changes for the UI itself.
- `--bg`/`stop` are delivered via launcher unification (they already exist in
  `aiurdev`), not as a new bespoke Elixir CLI flag. Rationale: avoids a third
  implementation of background-run logic and fixes the divergence directly.
- Label prefix fixed to `agent` (operator decision), replacing the configurable
  default `aiur`.

---

## Dependencies / Assumptions

- `Aiur.CodingAgent.override_labels/1` already includes `model:claude-remote`
  via `alias_labels/0` (verified), so the tag list needs descriptions, not new
  label generation.
- The npm package already ships a distribution-free interactive `init` path in
  `aiur-launch.sh` (verified), so the installed `aiur init` can host the new
  wizard UI.
- Assumes a real controlling TTY for the interactive selectors in normal use;
  the tmux manual-driver provides one. Non-TTY paths rely on the injected `io`
  seam (tests) or graceful degradation.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R12][Needs research] Measure actual per-session opencode RAM to put a
  truthful number in the pre-warm helper, or decide to omit the number.
- [Affects R14][Technical] Exact "none"/unlimited representation for max-turns in
  the schema and `agent_runner` loop (sentinel value vs. nil vs. 0) and its
  validation.
- [Affects R25-R28][Technical] Where the shared engine physically lives and how
  `aiurdev` execs it (extract `aiur-launch.sh` into the engine and have
  `aiurdev` set release dir + build-if-stale, vs. another layout) — a planning/
  refactor-design question, sequenced as the final unit.

---

## Next Steps

-> /ce-plan for structured implementation planning.
