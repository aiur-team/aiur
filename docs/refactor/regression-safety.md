# Regression Safety — the Testing Strategy

How "the repo is green after every ticket" stays true while less-capable
agents refactor 58.7k lines. Net goal: **less test code, higher-value
coverage, never a red suite.** Companion docs: `feature-inventory.md` (what
must survive), `research-history-hotspots.md` (where regressions actually
happen). All refactor work merges into the `v2` integration branch; "green"
below means green on `v2`.

---

## 1. What "green" means (the gate)

- **Agent gate, every ticket:** `make ci` from `src/` — build,
  `fmt-check` + `lint` (= `mix specs.check` + `credo --strict`), `coverage`
  (`mix test --cover`, 85% threshold), `regression`
  (`test/regression/aiur-agent-reap.sh`; SKIPs without tmux), `dialyzer`.
  Equivalent dev-loop form: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix test`, `mix credo --strict`,
  `mix dialyzer`. No smaller substitute.
- **Website tickets add:** `cd website && npm run typecheck && npm run build
  && npm run assert` (golden snapshot byte-identical). Repo CI does not cover
  `website/` today — a Phase-1 ticket adds a website CI job.
- **CI on `v2`:** the `pull_request` trigger has no branch filter, so PRs
  targeting `v2` run the full gate already; a Phase-1 ticket adds `v2` to the
  `push:` branches so post-merge `v2` state is re-verified.

---

## 2. The characterization tripwire (Phase 1 hard gate)

Behavior-pinning tests land **before any risky change ships**. Nothing in
later phases merges until this is in.

- **Location:** `src/test/aiur/regression/` — the existing 19
  characterization-style tests are the pattern home; ANSI snapshot support
  exists (`src/test/support/snapshot_support.exs`, `UPDATE_SNAPSHOTS=1`).
- **What gets pinned, in priority order:** the 12-item list in
  `research-history-hotspots.md` §"Densest characterization coverage
  recommended" — orchestrator transitions and gates first, then the GitHub
  ingestion pipeline, the engine/control-plane contract, workspace lifecycle,
  opencode slot lifecycle, agent_runner drain/resume, reap scoping, sandbox
  guards, renderer state threading, init/config resolution, alerts paths.
- **Self-hosting rule:** modules the aiur-loop itself depends on
  (orchestrator, agent_runner, github client/tracker, pane/tmux, engine
  scripts) get characterization coverage **before** any ticket touching them
  is scheduled — a runtime regression there degrades the fleet executing the
  refactor, which CI alone may not catch.
- **Plus one cheap global guard:** a test that greps for compile-time
  file-path embedding (`@external_resource`, `__DIR__`-relative reads) of
  files living under `.aiur/` or bundled paths — the single class that
  produced #393, #700/#702, and #726.

### Authoring rules (hard, from measured flake history)

1. Never assert exact counts on shared singletons (Exchange/Publisher
   subscriber counts inflate under concurrent async tests — the 2026-05-29
   finding).
2. `assert_receive` windows ≥ 2000 ms (500 ms flakes under `--cover` load).
3. Anything exercising engine launch/reap paths pins a unique
   `AIUR_RELEASE_NODE` (a test once SIGKILLed the operator's BEAM; PR #498).
4. Anything touching `src/lib/aiur/events/` isolates `:log_file` to a tmp dir
   (pattern in `subscription_store_test.exs`).
5. No `Process.sleep` synchronization — use `:sys.get_state`,
   `assert_receive`, or monitors (the SlotPolicyTest #506 class).
6. Resource-fan-out invariants get census-style assertions (count sessions /
   FDs / attaches), not just functional asserts — the `:emfile` regression
   mode is invisible to unit tests.

### Read-only mechanics (enforced, not aspirational)

- A CI check (part of the Phase-1 gate ticket) **fails any PR whose diff
  touches `src/test/aiur/regression/`** unless the PR carries an
  operator-applied override label (`regression-suite-change`). CODEOWNERS is
  advisory only here — the repo-wide wildcard rule makes it a no-op as an
  edit guard (its comment-authority role is separate and unchanged).
- Every risky ticket carries this language verbatim: *"A failing
  characterization test means your change is wrong. Never edit the test.
  Stop: comment on the issue describing the failing test, emit `emit_alert`
  with `needs_attention: true`, and end your turn without opening a PR."*

---

## 3. Phase-1 prerequisite tickets

Mandated before any risky change (all small, independent):

1. **Characterization suite + CI tripwire** (the gate itself, per §2).
2. **Tripwire path-guard CI check** (override-label mechanism).
3. **Global `:log_file` test isolation** in `test_helper` + purge of leaked
   `src/log/` state — the SubscriptionStore disk-leak flake is fixed for only
   one describe block (#687); ghost flakes would look like refactor
   regressions and stall the loop.
4. **Fix SlotPolicyTest #506** (sleeps → deterministic sync). The standing
   "admin-merge past it" habit is fatal when lesser agents can't distinguish
   a known flake from their own regression.
5. **`v2` base-branch support:** `RepoBase` respects `tracker.base_branch`
   (today `@default_branch "main"` is hardcoded for clone/fetch/reset —
   `src/lib/aiur/repo_base.ex:28`), plus CI `push:` branches += `v2`.
6. **Website CI job** (typecheck + build + golden-snapshot assert).

---

## 4. The coverage ratchet

- `src/mix.exs` exempts today's giants from the 85% threshold via
  `ignore_modules`. **New modules extracted from giants are not exempt** —
  every decomposition ticket must ship tests for what it extracts, or CI
  fails on coverage. This is the enforcement mechanism, not a convention.
- `ignore_modules` only shrinks. Its length is a tracked success metric of
  the refactor; no ticket may add to it.
- Bug fixes discovered mid-refactor add a regression test that fails without
  the fix (repo norm, carried into every fix ticket).

---

## 5. Test pruning rules (how "less test code" happens safely)

Tests are pruned **only** when:

- (a) the code they pinned is gone, or
- (b) they are replaced by higher-level coverage that exercises the same
  observable behavior — the replacing test must be named in the ticket.

**Never-prune whitelist while the pinned code lives** (each pins a recurring
regression): `src/test/aiur/test_reset_test.exs` label-args tests (label
remove+add race), `src/test/aiur/agent_runner_test.exs` marker fan-out tests
(30s/serve sync stall), the subscription-store isolation pattern, renderer
`render_state` threading tests (the `Map.take` pipeline class: #414/#473/#730),
ANSI snapshot goldens, and the whole `src/test/aiur/regression/` suite.

Consolidation shrinks tests legitimately: the ~12 per-facet orchestrator test
files merge along the new module boundaries; unit tests of consolidated
internals lift to integration tests at the new seams; tests of deleted
duplicate paths are deleted with them.

---

## 6. Merge protocol on `v2` (semantic-race prevention)

File-disjoint green PRs can still break `v2` together (A renames a function;
B, in different files, adds a call to the old name — both green alone). The
aiur-driving Opus agent therefore merges **one PR at a time per phase**, with
update-branch-from-`v2` + fresh CI immediately before each merge, and runs the
ticket's at-merge checks (named `Check:` probes from the feature inventory,
plus any manual TUI checks the ticket lists) after merging.

---

## 7. Halt-and-repair

- **Red `v2` or a characterization failure anywhere:** the Opus agent pauses
  the loop, stops opening/claiming issues, opens a top-priority fix issue
  referencing the offender, amends affected downstream ticket docs, then
  resumes.
- **Dialyzer errors outside a ticket's declared scope:** rebase `v2`, rerun;
  still failing → file a `needs-triage` finding and continue — never
  scope-creep into fixing a sibling's error.
- **Unforeseen bugs:** the Opus agent opens new issues and slots them into
  phases (same ticket conventions). **Backstop:** if aiur itself becomes
  unusable, the Opus agent implements any fix necessary directly to restore
  the fleet, then records it (issue + PR into `v2`).

---

## 8. Inventory → coverage mapping (two-pass)

- **Pass 1 (this document):** the priority list, authoring rules, and
  prerequisite tickets above.
- **Pass 2 (after ticket generation):** every FI entry in
  `feature-inventory.md` maps to exactly one of: a characterization test, a
  named existing test, an at-merge `Check:` probe, or an explicit rationale
  for no coverage. Risky tickets carry `Characterization-tests:` fields; the
  consistency script verifies every reference resolves to a real test file.
