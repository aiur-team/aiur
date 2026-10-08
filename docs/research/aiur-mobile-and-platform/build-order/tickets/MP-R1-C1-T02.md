---
ticket_id: MP-R1-C1-T02
feature_id: MP-R1
chunk_id: MP-R1-C1
bucket: 1-refactor
title: Elixir module-reference walker with undeclared-dependency and private-module rules behind a ratchet allowlist
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T01]
prior_units: [U0]
prior_boundaries: ["all (SCC finding, feature-boundaries.md §3)"]
prior_features: []
prior_findings: []
size_owner: n/a (new files; each < 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C1-T02 — Elixir reference walker, two rules, ratchet allowlist

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C1. Step S0.
- **User value:** none at runtime. A new reference from one component into another
  component's private module, or into a component it has not declared, fails CI. Today
  nothing stops the SCC (35 of 36 boundaries) from growing.
- **Deliverable:**
  1. `scripts/components/module_references.exs` — the prior research walker ported to
     `main` (parse only, no compile).
  2. Rules in `scripts/check-components.py`: **R-declared** (source component references
     a module of a component that is neither itself nor in its `requires`/`optional`) and
     **R-private** (reference to a module that is not in the target's `facades`, unless the
     target has `facades: ["*"]`).
  3. Allowlist files `scripts/components/allowlist/<source-component>.tsv`, generated at
     the implementation head; a violation not in the allowlist fails.
- **Non-goals:** layer and optional rules (T03), TypeScript (T04), stale-entry enforcement
  and maintainer tooling (T05), any code move.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T01 (manifest, ownership, CI step).
- **Concurrent:** T04 (TS walker) may run in parallel; T03 needs this ticket.
- **Dependents:** T03, T05, T06; C4/C5 tickets use the allowlist to prove edges removed.

## Verified starting point (`45a290e3`)

- No reference checker on `main`. The prior walker is branch-only:
  `docs/research/refactor-2026-09-26/tooling/module_references.exs` (branch
  `research/refactor-findings`, commit `f09e6e5d0`, 81 lines). It parses
  `src/lib/**/*.ex` with `Code.string_to_quoted!/2`, resolves `alias` (including
  `alias A.{B, C}` and `as:`), excludes `@doc`/`@moduledoc`/`@typedoc`, and emits TSV
  rows `M path module` and `R path source target reference line`.
- **Measured at `45a290e3` (2026-10-06, Elixir 1.19.5 / OTP 28 local):** wall time
  2.9 s (4.3 s user) over `git archive 45a290e3 src/lib`; 1,111 modules; 1,077 primary
  files; 4,016 module edges after the prior primary-file collapse (`graph_summary.py`).
  With the prior 36-boundary map plus six Phase C placement rules: 2,140 cross-boundary
  module edges, 339 upward edges, one SCC containing all 36 boundaries, 105 mutually
  dependent boundary pairs, 1,174 distinct (source boundary, target module) pairs, at
  most 154 for one source boundary (`CLI`). These are on the prior taxonomy; the
  41-component baseline is recorded by this ticket.
- **`mix xref` rejected (RQ1).** `mix xref graph` "emits a file dependency graph" and
  compiles by default (mix.hexdocs.pm/Mix.Tasks.Xref.html, Elixir v1.20.4 docs, accessed
  2026-10-06). The walker gives module-level edges, needs no compile (the `lint` job
  compiles separately), and is already validated by the prior research.
- Lint job has Elixir after `./.github/actions/setup-elixir` (`ci.yml:247-249`), so the
  checker can shell out to `elixir`.

## Chosen design

- **Walker.** Port verbatim, then two changes: (a) keep walking only `src/lib/**/*.ex`
  (`src/config/*.exs` is the composition root, see below, and is not walked); (b) emit the
  primary module per file the same way `graph_summary.py` collapses (`primary` = first
  module in the file, `Aiur` → `Aiur.Application`).
- **Module → component.** A module belongs to the component owning its file (C1-T01
  ownership). References to modules not defined in `src/lib` (Elixir stdlib, deps,
  `Mix.*`) are ignored; unresolved `Aiur.*`/`AiurWeb.*` targets are reported as a
  warning count, not a failure (13 at base; dynamic or macro-generated names).
- **Composition root.** `src/lib/aiur.ex` (`Aiur.Application`) and `src/config/*.exs`
  may reference any component: they are `control-cli`, which `requires` every required
  component and lists every optional one (component-map §3, L4).
- **Rules.**
  - R-declared: `target_component ∉ {source} ∪ requires ∪ optional`.
  - R-private: `target_module ∉ target.facades` and `target.facades != ["*"]`, and
    `source != target`. A facade entry `Aiur.Foo` covers only that module; `Aiur.Foo.*`
    is not implied.
- **Allowlist format** (one file per source component, keeps each < 500 lines; the
  largest prior source boundary has 154 target modules):

  ```text
  # rule	target_module	reason
  R-private	Aiur.Orchestrator.State	baseline 45a290e3; C9 owns
  ```

  Key = (rule, source component, target module). Line numbers are not part of the key,
  so edits inside a file do not churn the allowlist. A new key fails; an existing key
  passes however many references it has.
- **Generation.** `python3 scripts/check-components.py --write-baseline` writes the
  files from the current violations with reason `baseline <sha>`. It is used once here
  and refuses to run when any allowlist file already exists (T05 adds the
  remove-only update mode).

## Implementation steps

1. Copy the walker to `scripts/components/module_references.exs`; add a header comment
   citing the origin commit; keep it parse-only.
2. In `check-components.py`: run `elixir scripts/components/module_references.exs <root>`,
   parse TSV, map modules to components, evaluate R-declared and R-private.
3. Allowlist read/compare; `--write-baseline` once; `--rules` flag so `ownership` can
   still run alone (workflow-security fixtures without Elixir).
4. Generate the baseline at the implementation head; commit the files; put the totals
   per rule and per component in the PR body (RQ1 answer).
5. Fixtures: `scripts/components/fixtures/<case>/` mini trees (two or three `.ex` files
   plus a `components.json`); new test cases in `test-check-components.sh` guarded by
   `command -v elixir` — they run in the `lint` job (add
   `bash scripts/test-check-components.sh --with-elixir` as a lint step), and are
   skipped with a printed notice in `workflow security`.

## Non-happy paths

- `elixir` missing locally → exit 2 with "install via mise" (never silently skip in CI:
  the lint step passes `--require-elixir`).
- A file fails to parse (syntax error mid-PR) → exit 2 naming the file; compile errors
  are the compiler's job.
- Alias resolution miss (macro-generated module names) → not a violation; counted in an
  "unresolved" summary line so a reviewer can see drift.
- Runtime budget: target < 10 s in CI; the step prints the measured time.

## Compatibility and rollout

- No runtime change. Rollback: revert. Ratchet means no existing PR fails unless it adds
  a new cross-component private or undeclared reference — the intended effect.

## Verification

| Test (in `test-check-components.sh --with-elixir`) | Fixture | Expected |
|---|---|---|
| `undeclared_dependency_fails` | `a` references `B.Facade`, `a.requires = []` | exit 1, `R-declared a -> B.Facade` |
| `declared_facade_passes` | same, `a.requires = ["b"]` | exit 0 |
| `private_module_fails` | `a` requires `b`, references `B.Internal`, `b.facades = ["B"]` | exit 1, `R-private` |
| `facade_star_allows_any` | `b.facades = ["*"]`, `facade_pending: "X"` | exit 0 |
| `alias_resolution_counts` | `alias B.{Internal}` then `Internal.f()` | exit 1 (alias resolved) |
| `doc_mentions_ignored` | `@moduledoc "see B.Internal"` | exit 0 |
| `allowlisted_violation_passes` | violation + matching allowlist line | exit 0 |
| `new_violation_beside_allowlist_fails` | allowlist has `B.Internal`, code adds `B.Other` | exit 1 |
| `composition_root_exempt` | `src/lib/aiur.ex` references `B.Internal` | exit 0 |

Mutation check: drop the allowlist comparison (treat all violations as allowed) →
`new_violation_beside_allowlist_fails` fails; drop the alias table → `alias_resolution_counts`
fails; drop the `@moduledoc` skip → `doc_mentions_ignored` fails.

Real tree: `python3 scripts/check-components.py` exits 0 at the head with the committed
baseline; then add `Aiur.Orchestrator.State` to any `kernel` file in a scratch worktree
and confirm exit 1.

## Completion and handoff

- [ ] Walker on `main`, parse-only, < 500 lines.
- [ ] Baseline allowlist committed; PR body states counts per rule and component and the
      measured runtime (closes RQ1 for the 41-component map).
- [ ] Lint step runs with Elixir; fixtures fail under the mutations above.
- [ ] No docs-site change (no operator surface).
- **Dependents:** C1-T03, C1-T05, C1-T06, C4-T01..T04, C5-T01..T05.
