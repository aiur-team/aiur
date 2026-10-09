# Contributing to Aiur

These are the engineering norms for this codebase, adapted from
[ethereum-optimism/actions](https://github.com/ethereum-optimism/actions)
onto aiur's Elixir stack. They are the house style the production-readiness
refactor codifies. Every norm below maps onto tooling that is already wired
(`make ci` and the `mix` gate); this document names the norm and the check
that enforces it. When a norm and a check disagree, the check wins — fix the
code, then fix this doc in the same change. The one deliberate exception is
[Documentation](#documentation), which is a review expectation with only a
narrow config-key check behind it; it says so in place.

## Executor issue intake

The GitHub accounts and orgs listed by numeric id in
`tracker.github.allowed_contributors`, or the fallback
[`.github/ALLOWED-CONTRIBUTORS`](.github/ALLOWED-CONTRIBUTORS), may submit issues
for the Aiur Executor to triage and queue when they fit the active run's
scope. Each new issue they open wakes the Executor with an
`issue.opened.allowed_contributor` event. The format, precedence, caching, and
revocation are in [`docs/allowed-contributors.md`](docs/allowed-contributors.md).

For every such issue, an authorized Executor applies `agent:todo` promptly and
pulls the issue into the active Aiur run. If no Aiur run is active, the label
persists and makes the issue available at the next run's startup. Then
perform normal ticket triage. If the issue needs clarification, is a
duplicate, or must wait, use the normal pause, closure, or disposition flow
and record the reason. Do not leave it silently unqueued.

The list gives an author eligibility for issue intake. It does not make them a
code owner, grant review or command authority, or authorize them to apply
dispatch labels. Aiur verifies the provenance of the `agent:todo` label
independently of who opened the issue, and the issue's content is treated as
untrusted input.

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

Aim for 200 lines and give a cohesion reason above that target. The required
`workflow security` job rejects new text paths over 500 lines and growth of
paths already over 500, comparing Git blobs against the event's base commit.
Existing oversized files may stay unchanged or shrink; renames and copies to
new paths must fit the limit. Text becoming binary is rejected. Binary files
are otherwise skipped, and symlinks are reported without following them.
Lines are LF bytes plus a non-empty unterminated final line (CRLF counts once).
Run `python3 scripts/check-file-size.py --base <commit>` locally; without
`--base`, it uses the merge base with `origin/main`.

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
- **Directory-targeted runs do not cover sibling test files.** `test/aiur/`
  contains both topic subdirectories and files directly. For example,
  `mix test test/aiur/github/` does not collect
  `test/aiur/github_client_test.exs`; a large green count from the directory is
  not evidence that the sibling file ran. For a function rename, option-key
  rename, or signature change, also search the complete test tree from the
  repository root with
  `mise exec -- rg -n --fixed-strings -- '<old-name>' src/test/` and account for
  every hit before pushing. `mix aiur.affected_tests` also mines deleted source
  references and adds every matching test file to its scoped command. The audit
  and selector are independent of the full suite.
- **A test encodes WHY behavior matters, not just what it does.** A test that
  cannot fail when the business logic changes is not pulling its weight.
- **A test that passes with its production change reverted is not coverage.**
  Before opening a PR, revert the hunk each new test guards, run the test, and
  confirm it fails; restore the hunk and confirm it passes again. Name the
  result in the PR body (one line per new test). A test that survives its own
  revert — a `%{} = actual` pattern matching any map, an assertion pinned to a
  constant the change never touches, `f(x) == f(x)` — asserts pre-existing
  behaviour and will pass on a trivially wrong implementation. (AGENTS.md
  "Tests must fail without the production change they guard" carries the same
  rule for agents; the `aiur-run` skill carries the reviewer-side check.)
- **Flaky tests are fixed or deleted — never retried, never ignored.** Wall-clock
  waits are not synchronization primitives: do not use finite `Process.sleep`
  calls or explicit timeouts on `assert_receive` / `refute_receive` to wait for
  concurrent work. Drive periodic work with explicit tick messages, then cross
  a causal barrier such as `:sys.get_state/1`, another synchronous call, or a
  process monitor. When the expected message is itself the rendezvous, use the
  unbounded `receive_barrier/1` test helper. After another barrier has proved the
  work complete, use `assert_receive` without an explicit timeout and use
  `refute_received` instead of `refute_receive`. Never assert exact counts on
  shared singletons. A test that flakes is a defect in the test.
- **Shared global state is the other flake mechanism, and barriers do not fix
  it.** A suite can be fully barrier-based and still be order-dependent. Pin and
  restore any VM-global cache a test reads through — a `:persistent_term` entry
  survives every test, so a test that reads one passes only until ordering
  changes or the cache flushes. Refute on the narrowest topic you actually mean:
  a namespace-wide `refute_receive`/`refute_received` on a shared bus asserts
  about the whole system, so any other test publishing into that namespace can
  fail it. And never call `self()` inside `on_exit` — the callback runs in a
  different process, so the binding, monitor, or subscription you meant to clean
  up leaks into later tests.
- **Quarantine only while fixing.** Tag a confirmed flaky test with
  `@tag :quarantine`, open or link its repair issue, and leave a short reason
  beside the tag. Ordinary local and required CI runs exclude quarantined
  tests; the `quarantined tests (non-blocking)` CI job runs them separately so
  they remain visible. Remove the tag as part of the root-cause fix — it is not
  a permanent exemption.
- **Coverage rerun evidence.** Each shard uploads an attempt-qualified
  `shard-flake-evidence-<shard>-<attempt>` artifact, including `attempt.json`
  and `flakes.ndjson`. On a successful rerun of the same workflow run and SHA,
  the ledger records each previously failing ExUnit test with its shard, run
  ID, failed/passed attempts, and seeds (null when the log has no seed).
  The job summary shows the count and test names. Download these artifacts to
  count recurrence; they use GitHub's repository artifact retention policy.
  Ledger and artifact errors are non-blocking so they cannot fail a passing shard.
  This records observations without relaxing the coverage gate or automatically
  quarantining tests. Runner loss before upload and failures without a parseable
  ExUnit test name cannot be recorded.
- **Extracted modules are not coverage-exempt.** The coverage
  `ignore_modules` list in `src/mix.exs` only shrinks: every module split out
  of a giant ships tests for what it extracts, or CI fails the coverage gate
  at its 85% threshold. No change may add a module to `ignore_modules`.

## CI gate

Draft pull requests run `changes`, `lint`, and `build`. The existing path
classifier only identifies docs-only changes; it does not select affected tests.
Mark completed work ready for review **before** entering `agent:ci-wait`.
`ready_for_review` starts the full suite, as do pushes to ready PRs, merge queue
candidates, integration-branch pushes, and manual workflow dispatches.

A draft's fast gate does not approve its head for human review. Aiur waits for
the current head's full required-check set, including the configured check
integrations; missing or skipped required checks remain pending. Ready docs-only
PRs retain the existing step shortcuts, which publish successful required checks.
The merge ruleset declaration and its drift guard remain unchanged.

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

## Documentation

- `components.json` supplies public component descriptions and the planned-features list for the generated directory.
- **Functionality ships with its documentation, in the same PR.** Docs are
  required when a change adds or changes a config key, a CLI command or flag,
  an environment variable an operator would set, a new user-facing surface (a
  dashboard page, a TUI view, a Stream Deck mode, a panel), or when it changes
  documented behavior so an existing page is now wrong. Docs are **not**
  required for internal refactors, bug fixes that restore already-documented
  behavior, test-only changes, or performance work with no interface change.
- **Prefer editing an existing page over adding a new one.** Concise and correct
  beats comprehensive — a wrong doc is worse than a missing one.
- Docs live in `website/docs-app/`: config keys in
  `reference/configuration.md`, commands and flags in `reference/cli.md`,
  user-facing surfaces in `guide/`, explanations in `concepts/`. A new page also
  needs a sidebar entry in `website/docs-app/.vitepress/config.ts`. The full map
  is [`AGENTS.md`](AGENTS.md#docs-ship-with-the-change).
- **This norm is mostly not tool-enforced, unlike the rest of this document.**
  `scripts/check-config-docs.py` covers config keys only — it resolves each key
  to its full dotted path and fails the required `lint` job when one has no
  entry in the reference. CLI flags, new surfaces, and falsified pages have no
  check behind them, so a reviewer treating a missing doc as a blocking finding
  is the whole enforcement.

## Releasing to npm

`src/mix.exs` `version:` is the single source of truth, and it always names the
**next unreleased** version. Every npm version is derived from it, and
`.github/workflows/release-npm.yml` publishes all four packages (`aiur-cli` plus
one per platform).

| Channel | Trigger | Version | dist-tag |
| --- | --- | --- | --- |
| stable | push a `v<mix.exs version>` tag, or `channel=stable` | `0.0.9` | `latest` |
| nightly | the 07:00 UTC schedule, or `channel=nightly` | `0.0.9-nightly.<short-sha>` | `nightly` |
| dry run | `workflow_dispatch` default | `0.0.9-dev.<run>` | none |

```bash
# Stable cut without pushing a tag.
gh workflow run release-npm.yml --ref main -f channel=stable

# Prove the pipeline without touching the registry.
gh workflow run release-npm.yml --ref main -f channel=dry-run
```

Bumping the version means editing `src/mix.exs` and running
`node packaging/scripts/stamp-versions.mjs <version>` so the checked-in
`package.json` files agree. The workflow refuses to release on drift, and also
refuses if `mix.exs` names a version already on the registry.

Nightlies sort below the release they lead to, so `npm install aiur-cli` never
picks one up. `nightly` is its own dist-tag: `next` already carries a different
meaning on this registry. The schedule is a no-op when nothing shipped has
changed: an existing version (the nightly version embeds the head sha) is
skipped, and so is a head whose diff from the last published nightly's commit
touches nothing under `src/` or `packaging/`. npm nightlies create no GitHub
release and no tag.

## Stream Deck nightly

The Stream Deck sidecar is a binary archive, not an npm package, so its nightly
is one rolling GitHub pre-release, `streamdeck-nightly`, cut by
`.github/workflows/streamdeck-package.yml` on the same 07:00 UTC schedule. Each
night that `packages/streamdeck` changed since the commit the tag points at,
the workflow moves the tag to the new commit and replaces the two fixed-name
assets (`aiur-streamdeck-nightly-linux-x64.tar.gz` and its `.json` manifest)
in place. Nothing else is created, so the Releases and Tags lists hold at most
one Stream Deck entry however many nights run, and an unchanged package skips
the night entirely.

```bash
# Request a build; the workflow skips it when the package is unchanged. Nothing
# is published unless publish=true.
gh workflow run streamdeck-package.yml --ref main

# Update the rolling pre-release now.
gh workflow run streamdeck-package.yml --ref main -f publish=true
```

### Authentication

Publishing uses [npm OIDC trusted publishing](https://docs.npmjs.com/trusted-publishers/),
not an npm token. Four constraints shape the workflow:

- **Each package needs its own trusted publisher** on npmjs.com, all pointing at
  this repo and the workflow filename `release-npm.yml`.
- **Publishing must be triggered on `release-npm.yml` itself.** npm validates the
  calling workflow, so a `workflow_call` indirection fails the match
  ([npm/documentation#1755](https://github.com/npm/documentation/issues/1755)).
  That is why the nightly schedule lives in this file rather than its own.
- **npm must be 11.5.1 or newer.** Node 22 tops out at npm 10.9.8, so the publish
  job runs Node 24 and still reinstalls npm and asserts the version.
- **`npm dist-tag add` cannot run under OIDC**
  ([npm/cli#8547](https://github.com/npm/cli/issues/8547)); the exchanged
  credential only authorizes `npm publish`. Packages are therefore published with
  their final dist-tag, launcher last, so `aiur-cli` only points at a version
  whose platform packages already exist.

`actions/setup-node` must not set `registry-url` in the publish job: it writes an
empty `_authToken` line that makes npm skip the OIDC exchange
([actions/setup-node#1551](https://github.com/actions/setup-node/issues/1551)).

## Repository renames

Before a global identifier rename, run the report-only [rename preflight](docs/rename-preflight.md):

```bash
make rename-preflight OLD=old-owner/old-name NEW=new-owner/new-name
```

It finds component and near-miss forms that a joined-literal search misses and
shows the owning coverage partition for test files. Review the output before
rewriting; it is intentionally not an automatic replacement.

## Component boundaries

The required lint job checks the four Elixir reference rules: `R-declared`
(declared dependency), `R-private` (provider facade), `R-down` (layer direction),
and `R-optional` (required code must not depend on optional code). Failures name
source component, target module and the reference location. Fix the boundary or
manifest first; an exemption is temporary debt, not permission to add more.

Allowlist TSVs in `scripts/components/allowlist/` match exact
`(rule, source component, target module)` keys. A removed violation leaves a
stale entry that fails lint: delete it in the same PR, or run
`python3 scripts/check-components.py --prune`. Pruning removes only stale rows
for the selected rules; it never adds exemptions and still fails on new violations.

On pull requests, additions (including replacements and new files) are compared
with the PR base SHA. Every added row needs a reason beginning with a ticket ID:
`MP-…`, `U…` or `#NNNN`, followed by an explanation the reviewer can verify.
Existing `baseline <sha>` rows are grandfathered, but new baseline rows cannot
bypass this guard. `--write-baseline` is bootstrap-only and cannot be combined
with `--prune`. Use `--growth-base <sha>` to reproduce the PR growth guard.
If the base cannot be fetched, the guard warns and skips; ordinary new-violation
and stale-entry checks still run. Push and merge-group runs skip only growth.
The CI step summary reports per-rule debt, largest SCC size and checker runtime;
cycles are informational, not failures.

## Enforcement

Every tracked file under `src/lib/`, `packages/` and `packaging/` must belong
to one component in `components.json`. Add new source paths and update moved
paths in the same PR. Before running `python3 scripts/check-components.py`, install its pinned TypeScript
toolchain with `npm ci --prefix scripts/components --ignore-scripts`. The required lint job runs both;
unowned files, equally specific competing owners and stale globs fail the check.
Use `python3 scripts/check-components.py --format` to keep the manifest deterministic.

Every root config section and scalar field, env schema name, and public
`Aiur.Config.Paths` function ending in `_dir` or `_path` must have exactly one
owner in `owns.config`, `owns.env` or `owns.state`. Add the owner in the same PR
as a new declaration; stale and duplicate ownership also fail lint.
`shared_with` records collaborating components without assigning another owner.

RQ4: root sections stay literal `embeds_one` declarations: Ecto composes the
struct at compile time and `check-config-docs.py` reads those lines. Ownership
is manifest data; it does not generate or move section modules.

The gate is `make ci` from `src/` (build, `fmt-check`, `lint`, `coverage`,
`regression`, `dialyzer`). The equivalent dev-loop commands are:

```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

- **`mix lint` runs both `specs.check` and `credo --strict`** — both are
  mandatory, and both run even when the other fails so one pass reports every
  lint failure. `specs.check` fails the build when any public `def` in `lib/`
  lacks an adjacent `@spec` (`@impl` callbacks are exempt). Running
  `mix credo --strict` alone misses half the gate.
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
- **PRs target the canonical `main` branch.** A PR description starts with
  `Closes #<issue-number>` and follows
  `.github/pull_request_template.md` exactly (validate with
  `mix pr_body.check --file <path>` from `src/`).
