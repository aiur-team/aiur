# T-054: Adopt CONTRIBUTING.md engineering norms

**Phase:** 5
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:5` `complexity:2`

## Problem / context

The refactor's house style — size norms, reuse-before-invention, testing
discipline, error handling, and the enforcement gate — lives today only in
scattered research docs (`docs/refactor/target-architecture.md` "Principles"
and "Engineering norms adoption", `docs/refactor/regression-safety.md` §4).
There is no single contributor-facing document a human or coding agent can
read to learn the norms the refactor is codifying. The repo has no
`CONTRIBUTING.md` at all (`ls CONTRIBUTING.md` fails at ticket-writing time).

This ticket writes one root `CONTRIBUTING.md` that adapts the
ethereum-optimism/actions engineering norms onto aiur/Elixir, mapping every
norm onto aiur's already-existing gate — `make ci`, the `mix lint` alias
(`specs.check` then `credo --strict`), `mix dialyzer`, and the coverage
`ignore_modules` ratchet — so the document describes the tooling that is
already wired, not aspirational process. It also adds one pointer line to the
root `AGENTS.md` so agents starting a ticket find it. This is a docs-only
ticket: it creates one Markdown file and adds one line to another; it changes
no source code and no test.

## Scope (exact)

The executor makes ZERO wording decisions: copy the two blocks below verbatim.

1. **Create `CONTRIBUTING.md` at the repo root** with EXACTLY this content
   (copy verbatim, including the fenced code blocks):

```markdown
# Contributing to Aiur

These are the engineering norms for this codebase, adapted from
[ethereum-optimism/actions](https://github.com/ethereum-optimism/actions)
onto aiur's Elixir stack. They are the house style the production-readiness
refactor codifies. Every norm below maps onto tooling that is already wired
(`make ci` and the `mix` gate); this document names the norm and the check
that enforces it. When a norm and a check disagree, the check wins — fix the
code, then fix this doc in the same change.

## Code structure

- **Functions ≤ 20 logic lines.** Blank lines, `@spec`, `@doc`, and pattern
  headers do not count; branches and pipeline stages do. A longer function is
  a signal to extract a named helper.
- **Files ≤ 200 lines.** A larger module is decomposed along its
  responsibilities. Cohesive schema-style modules (the `config/schema.ex`
  family — a flat list of field definitions with no branching) are the one
  judgment-call exception and may run longer.
- **Nesting ≤ 2 levels.** Prefer `with`, guard-clause early returns, and
  pure policy functions over deep `case`/`if` pyramids.
- **One responsibility per module.** A behaviour or base owns cross-cutting
  work; concrete modules stay thin; dependencies point one direction
  (concrete → base, never back).

These are guiding targets, not a lint rule — they inform review, and CI does
not fail a build on line count alone.

## Reuse before invention

- **The extraction trigger is the second concrete usage — not the first, not
  the third.** When you write the same logic a second time, stop and lift it
  to one shared home (a module or helper) that both call sites use. Do not
  extract speculatively on the first use, and do not wait for a third copy to
  accumulate.
- Before adding a helper, search for an existing one. Security-critical or
  cross-subsystem primitives (shell escaping, identifier/path sanitization,
  atomic writes) must have exactly one implementation; a second copy is a bug.
- Prefer config access through `Aiur.Config` over ad-hoc environment reads.

## Testing

- **Mock at boundaries, never pure utilities.** Stub the external edges —
  GitHub, the shell, the filesystem, tmux, the coding-agent app-server — so a
  test exercises real internal logic. A pure function is tested with real
  inputs and real outputs; mocking it tests the mock.
- **Every bug fix ships a regression test that fails without the fix.**
  Reproduce the bug as a failing test first, then make it pass. A fix without
  a test that would have caught it is incomplete.
- **A test encodes WHY behavior matters, not just what it does.** A test that
  cannot fail when the business logic changes is not pulling its weight.
- **Flaky tests are fixed or deleted — never retried, never ignored.** No
  `Process.sleep` for synchronization (use `assert_receive`, monitors, or
  `:sys.get_state`); never assert exact counts on shared singletons; keep
  `assert_receive` windows ≥ 2000 ms. A test that flakes is a defect in the
  test.
- **Extracted modules are not coverage-exempt.** The coverage
  `ignore_modules` list in `src/mix.exs` only shrinks: every module split out
  of a giant ships tests for what it extracts, or CI fails the coverage gate
  at its 85% threshold. No change may add a module to `ignore_modules`.

## Error handling

- **Name your errors.** Return structured, matchable error values
  (`{:error, reason}` with a specific `reason`, or a typed struct) — not bare
  strings a caller cannot pattern-match.
- **Validate at boundaries.** Check inputs where untrusted data enters
  (CLI args, config, HTTP, tracker payloads); trust them thereafter so inner
  functions stay simple.
- **Wrap at the boundary.** Translate a lower layer's error into this layer's
  vocabulary as it crosses a module seam; do not leak an internal failure
  shape through a public API.
- **Never swallow an error.** Do not `rescue`/`catch` to discard a failure,
  and do not return `:ok` when something failed. Fail loud: surface the
  error, log it with issue/session context (`docs/logging.md`), or propagate
  it. "Completed" is wrong if anything was skipped silently.

## Enforcement

The gate is `make ci` from `src/` (build, `fmt-check`, `lint`, `coverage`,
`regression`, `dialyzer`). The equivalent dev-loop commands are:

```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

- **`mix lint` is `specs.check` then `credo --strict`** — both are
  mandatory. `specs.check` fails the build when any public `def` in `lib/`
  lacks an adjacent `@spec` (`@impl` callbacks are exempt); `credo --strict`
  runs after it. Running `mix credo --strict` alone misses half the gate.
- **Zero-new-warnings ratchet.** `mix compile --warnings-as-errors` is part
  of the gate: a change may not introduce a new compiler warning. The warning
  count only goes down.
- **The coverage `ignore_modules` list only shrinks.** Its length is a
  tracked success metric; no change may lengthen it. New modules are not
  exempt (see Testing).
- **`mix dialyzer` must pass.** A new dialyzer error inside your change's
  scope blocks the merge.

## Commits and pull requests

- **Commit messages are 3–7 word imperative phrases** ("Extract dispatch
  policy module"). Small, focused commits.
- **Never mention AI, models, or tools** in a commit message or a PR
  description.
- **During the refactor, PRs target the `v2` integration branch**, not
  `main`. A PR description starts with `Closes #<issue-number>` and follows
  `.github/pull_request_template.md` exactly (validate with
  `mix pr_body.check --file <path>` from `src/`).
```

2. **Add one pointer line to the root `AGENTS.md`.** In
   `/home/orangekid/github/aiur/AGENTS.md`, immediately after the intro
   paragraph that ends `operational practices that aren't in the main
   README.` (the line before `## Layout`), insert a blank line followed by
   EXACTLY this line:

```markdown
Engineering norms (code structure, testing, error handling, and the CI gate)
live in [`CONTRIBUTING.md`](CONTRIBUTING.md).
```

   Do NOT reorder, retitle, or otherwise restructure any section of
   `AGENTS.md`. The only change to `AGENTS.md` is these two added lines
   (one blank + one sentence).

3. Run the full Agent gate below from `src/`. (No source or test changed, so
   the gate should pass unchanged; run it to confirm nothing drifted.)

## Files

- Create: `CONTRIBUTING.md`
- Modify: `AGENTS.md`
- Test: none (docs-only ticket — see Characterization-tests)

## Out of scope

- Do NOT edit any file under `src/lib/`, `src/test/`, `packaging/`,
  `scripts/`, or `website/`. This ticket touches only `CONTRIBUTING.md` and
  `AGENTS.md`.
- Do NOT change the actual gate — no edits to `src/mix.exs`, `src/Makefile`,
  `.github/workflows/`, or `.credo.exs`. This ticket documents the existing
  gate; it does not modify it, tighten thresholds, or add lint rules.
- Do NOT restructure, retitle, or reorder existing `AGENTS.md` sections; add
  only the two lines specified.
- Do NOT create or edit `src/AGENTS.md`, `AGENTS.local.md`, or any README.
- Do NOT shrink or grow the coverage `ignore_modules` list (that is the job
  of the decomposition tickets, not this one).
- Do NOT add a CI check that enforces `CONTRIBUTING.md` (no new workflow).

## Inventory-IDs

This ticket implements no runtime feature — it is a documentation file plus a
one-line pointer, and changes no behavior. The norms it *describes* map onto
these existing enforcement features (read from
`docs/refactor/feature-inventory/eng.md`); the document must describe them
accurately, but this ticket does not modify their behavior:

- FI-ENG-073 — Makefile targets; `make ci` = setup+build+fmt-check+lint+
  coverage+dialyzer (the gate this doc names).
- FI-ENG-074 — `mix lint` alias = `["specs.check", "credo --strict"]` (both
  checks mandatory; the doc states this).
- FI-ENG-075 — `specs.check` mix task enforcing `@spec` on every public `def`
  in `lib/` (the doc's spec requirement).

## Characterization-tests

None. This ticket adds a prose Markdown file and one sentence to another
Markdown file; there is no code path to pin. The whole
`src/test/aiur/regression/` suite must still pass unmodified, since Phase-1
tripwire tests are already on `v2` — but this ticket exercises none of them
and edits none of them.

## Acceptance criteria

Run from the repo root unless noted; every bullet must hold:

- `CONTRIBUTING.md` exists at the repo root: `test -f CONTRIBUTING.md`
  succeeds.
- It is ≤ 200 lines: `wc -l < CONTRIBUTING.md` returns a value ≤ 200.
- It covers all six norm areas — each heading appears exactly once:
  `grep -c '^## Code structure$' CONTRIBUTING.md`,
  `grep -c '^## Reuse before invention$' CONTRIBUTING.md`,
  `grep -c '^## Testing$' CONTRIBUTING.md`,
  `grep -c '^## Error handling$' CONTRIBUTING.md`,
  `grep -c '^## Enforcement$' CONTRIBUTING.md`, and
  `grep -c '^## Commits and pull requests$' CONTRIBUTING.md` each return `1`.
- It names the real gate: `grep -c 'make ci' CONTRIBUTING.md` ≥ 1;
  `grep -c 'specs.check' CONTRIBUTING.md` ≥ 1;
  `grep -c 'credo --strict' CONTRIBUTING.md` ≥ 1;
  `grep -c 'dialyzer' CONTRIBUTING.md` ≥ 1;
  `grep -c 'ignore_modules' CONTRIBUTING.md` ≥ 1;
  `grep -c 'warnings-as-errors' CONTRIBUTING.md` ≥ 1.
- It states the key rules verbatim in substance:
  `grep -c 'second concrete usage' CONTRIBUTING.md` ≥ 1 (extraction trigger),
  `grep -c '20 logic lines' CONTRIBUTING.md` ≥ 1 (function size),
  `grep -c '200 lines' CONTRIBUTING.md` ≥ 1 (file size),
  `grep -c '3–7 word' CONTRIBUTING.md` ≥ 1 (commit convention),
  `grep -c 'v2' CONTRIBUTING.md` ≥ 1 (PR base during the refactor).
- `AGENTS.md` gained exactly the pointer: `grep -c 'CONTRIBUTING.md' AGENTS.md`
  returns `1`, and `git diff --stat AGENTS.md` shows exactly 2 insertions,
  0 deletions.
- Only the two intended files changed:
  `git diff --name-only <base>...HEAD` lists exactly `AGENTS.md` and
  `CONTRIBUTING.md` and nothing else.
- The gate is untouched: `git diff --name-only <base>...HEAD` contains none
  of `src/mix.exs`, `src/Makefile`, `.credo.exs`, or any path under
  `.github/workflows/`.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- Run every `grep`/`wc`/`git diff` bullet from Acceptance criteria on the
  merge commit; all must hold.
- Check: `git diff --name-only v2...HEAD` for the PR shows exactly
  `AGENTS.md` and `CONTRIBUTING.md` — no source, test, workflow, or Makefile
  touched.
- Check: accuracy against the live gate. Confirm `CONTRIBUTING.md`'s
  description of `mix lint` matches `src/mix.exs:171`
  (`lint: ["specs.check", "credo --strict"]`) and that the coverage threshold
  it cites (85%) matches `src/mix.exs` `test_coverage` `threshold: 85`. If
  either drifted on `v2` since this ticket was written, the doc must match the
  merged state.
- Visual: open `AGENTS.md` and confirm the pointer sits between the intro
  paragraph and `## Layout`, with the rest of the file byte-identical to its
  prior state (`git diff AGENTS.md` shows only the two added lines).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
