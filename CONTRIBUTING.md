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
- **Quarantine only while fixing.** Tag a confirmed flaky test with
  `@tag :quarantine`, open or link its repair issue, and leave a short reason
  beside the tag. Ordinary local and required CI runs exclude quarantined
  tests; the `quarantined tests (non-blocking)` CI job runs them separately so
  they remain visible. Remove the tag as part of the root-cause fix — it is not
  a permanent exemption.
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

## Repository renames

Before a global identifier rename, run the report-only [rename preflight](docs/rename-preflight.md):

```bash
make rename-preflight OLD=old-owner/old-name NEW=new-owner/new-name
```

It finds component and near-miss forms that a joined-literal search misses and
shows the owning coverage partition for test files. Review the output before
rewriting; it is intentionally not an automatic replacement.

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
- **PRs target the canonical `develop` branch.** A PR description starts with
  `Closes #<issue-number>` and follows
  `.github/pull_request_template.md` exactly (validate with
  `mix pr_body.check --file <path>` from `src/`).
