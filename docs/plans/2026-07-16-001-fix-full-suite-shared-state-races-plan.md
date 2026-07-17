---
title: "fix: Stabilize shared-state coverage tests"
type: fix
status: active
date: 2026-07-16
issue: 1222
---

# Stabilize Shared-State Coverage Tests

## Summary

Three test fixtures repeatedly fail on unrelated pull-request heads: BuildGate
descendants expire on wall-clock sleeps, the Observability PubSub test restarts
application-global state during teardown, and the provider-interrupt fixture
labels a checkpoint item as an interrupt only after enqueue. Replace the shared
timing assumptions with test-owned lifecycles and align the interrupt fixture
with production delivery policy.

The fixes apply unchanged to `main`, so delivery is main-first. After the exact
main fix lands, merge that exact main commit into `develop` and prove the main
fix commit is an ancestor of the resulting develop head. Do not carry changes
from PR #1213, PR #1036, or any other unrelated feature branch.

## Problem Frame

- PR #1213 run `29551309799` failed only the real-Mix BuildGate descendant
  case and the Observability PubSub unavailable case.
- PR #1036 failed-job rerun `29550586146` failed only the fake-Mix BuildGate
  descendant case and the identical Observability PubSub case.
- Both BuildGate tests give a detached child two seconds to remain alive. A
  contending command can therefore observe either a retained or released slot
  depending on shared-runner scheduling rather than the lease contract.
- The Observability unavailable test terminates `Aiur.PubSub` under
  `Aiur.Supervisor` and asserts that the same shared supervisor can restart it
  during cleanup. A concurrent application shutdown turns that cleanup into
  `GenServer.call(Aiur.Supervisor, {:restart_child, ...})` exiting `:shutdown`.
- The same files and dependencies exist on `main`; there is no develop-only
  exception for this recurring set.
- Exact-head CI on PR #1223 reproduced the cross-head provider-interrupt fixture
  failure previously seen on PR #1036. The fixture enqueued a checkpoint item
  before sending an artificial interrupt signal, so a delayed `turn/started`
  checkpoint could legally claim the item and bypass the intended interrupt
  path.
- A later exact-head run failed the repaired fake-Mix case after logging
  `lease_retained`, even though the release signal had not been sent. The holder
  checked parent liveness before reading the parent's durable acknowledgement;
  if the parent wrote the acknowledgement, logged, and exited first, the holder
  discarded that proof, killed the retained child, and released the slot.
- Concurrent local clean-VM repetitions also exposed a separate isolation
  hazard: `System.unique_integer/1` resets for every BEAM, so two VMs can reuse
  one `/tmp/aiur-build-gate-*` namespace. There is no evidence that this caused
  the isolated hosted-CI failure, but fixture roots must still be cross-VM safe.

## Requirements

- **R1.** BuildGate descendant-capacity assertions must be controlled by an
  explicit test release signal, not a fixed child lifetime or a longer sleep.
- **R2.** Both fake-Mix and real-Mix fixtures must prove that a detached child
  retains the slot until released, and that capacity becomes available after
  release.
- **R3.** Failure cleanup must release any held descendant so a failed assertion
  cannot strand a process or capacity lease.
- **R4.** Observability PubSub delivery and unavailable behavior must be tested
  without terminating or restarting the application-global PubSub child.
- **R5.** Production default behavior remains unchanged for existing callers.
- **R6.** The patch is authored against `main`, contains no PR-specific changes,
  and is later merged exactly into `develop` with ancestry evidence.
- **R7.** The same exact patch head must pass the affected tests repeatedly with
  `--max-cases 4` and complete at least two successful full-coverage CI
  executions without a commit change between them.
- **R8.** The provider-interrupt lifecycle regression must enqueue an
  interrupt-only item so a delayed safe checkpoint cannot consume it first.
- **R9.** BuildGate fixture roots must remain unique across separate BEAM VMs,
  including while a detached holder from an earlier VM is still exiting.
- **R10.** A persisted, token-matched holder status acknowledgement must win
  before parent-liveness or deadline failure; absent or mismatched
  acknowledgements must retain the existing fail-closed behavior.

## Assumptions

- A small optional PubSub-server seam on `AiurWeb.ObservabilityPubSub` is an
  acceptable production-neutral way for tests to own their dependency.
- A filesystem release marker is appropriate for detached OS children because
  the existing fixtures already use filesystem started/done markers across the
  BEAM-to-shell boundary.
- Historical provider-interrupt, completed-runner, event-digest, and other
  shared-state failures are diagnostic context, not part of this minimal patch
  unless the repaired exact head reproduces them again.

## Scope Boundaries

### In scope

- `src/test/aiur/build_gate_test.exs`
- `src/lib/aiur_web/observability_pubsub.ex`
- `src/test/aiur/observability_pubsub_test.exs`
- `src/test/aiur/agent_runner/provider_lifecycle_test.exs`
- Main-first publication followed by exact-main integration into `develop`

### Out of scope

- BuildGate capacity policy changes beyond the durable status-acknowledgement
  ordering repair
- Provider-turn ledger production behavior, completed-runner replacement,
  event-digest semantics, and unrelated application-supervisor refactors
- PR #1213 or PR #1036 feature changes
- Local full-suite loops or agent-workspace manual `aiurdev --test` runs

## Key Technical Decisions

- **Release barriers replace sleep windows.** The detached fake and real Mix
  children publish readiness, wait for a test-owned release path, then publish
  completion. The test releases them only after it observes the contender time
  out, making the asserted lease interval deterministic under descheduling.
- **Cleanup owns release.** Each descendant test installs release cleanup before
  starting the fixture so assertion failures still let the child and holder
  exit.
- **Fixture roots are cross-VM unique.** Use random entropy rather than the
  VM-local unique-integer counter so detached holders and parallel test VMs
  cannot share release markers or lock paths.
- **Durable acknowledgement precedes liveness.** The exact token is proof that
  the parent completed the status handoff. Read it before rejecting an exited
  parent or elapsed polling deadline, while retaining cancellation as the first
  check.
- **PubSub is injected only at the facade boundary.** Keep the existing zero-arg
  facade calls as defaults while allowing tests to supply a uniquely named,
  test-supervised PubSub server. The unavailable case uses a missing test name;
  no application child is touched.
- **CI is the full-suite oracle.** Local verification repeats only the affected
  files within the mandated four-case cap; exact-head coverage repetition is
  proven by CI without mixing in unrelated branch changes.
- **Interrupt fixtures use interrupt items.** The lifecycle regression now
  constructs the queued operator message with `delivery_policy: :interrupt`,
  matching the production path and preventing safe-checkpoint preemption.

## Implementation Units

### U1. Make detached BuildGate fixtures event-driven

**Goal:** Prove retained capacity across BEAM/wrapper exit without depending on
runner speed.

**Requirements:** R1, R2, R3, R7, R9, R10

**Dependencies:** None

**Files:**

- Modify: `src/priv/build_gate_holder.py`
- Modify: `src/test/aiur/build_gate_test.exs`

**Approach:**

- Add a per-case release path to the BuildGate test context and environment.
- Generate the per-case gate root with random entropy that cannot repeat when a
  separate test VM resets its unique-integer counter.
- Accept an already-persisted exact status acknowledgement before testing
  whether its parent is still alive or the polling deadline elapsed.
- Make the fake-Mix detached child and real-Mix fixture wait for that path after
  writing their existing started marker.
- Install cleanup that touches the release path before removing the test root.
- In both descendant tests, assert contention while the release is absent,
  release the child explicitly, wait for completion, then assert capacity is
  reusable.
- Preserve long-running sleep fixtures used by cancellation/reaping tests; only
  the two retained-capacity cases switch to the release barrier.

**Patterns to follow:** Existing started/done marker helpers and the release
barriers in provider lifecycle tests.

**Test scenarios:**

- **Integration:** fake Mix wrapper exits, detached child remains held, contender
  times out, release arrives, child completes, and the next contender succeeds.
- **Integration:** real Mix/BEAM exits with the same held/released sequence.
- **Error path:** an assertion failure or teardown still releases the detached
  child through registered cleanup.
- **Regression:** an exact durable acknowledgement succeeds after its parent
  exits, while a mismatched token continues to fail closed.

**Verification:** Repeat both named tests in one VM and as a file with
`--max-cases 4`; no result depends on a two-second scheduling window.

### U2. Isolate Observability PubSub tests

**Goal:** Cover broadcast delivery and unavailable no-op behavior without
mutating `Aiur.Supervisor` or `Aiur.PubSub`.

**Requirements:** R4, R5, R7

**Dependencies:** None

**Files:**

- Modify: `src/lib/aiur_web/observability_pubsub.ex`
- Modify: `src/test/aiur/observability_pubsub_test.exs`

**Approach:**

- Preserve the current zero-argument subscribe and broadcast APIs with
  `Aiur.PubSub` as the default.
- Add a narrow server-name argument used by tests.
- Start a uniquely named PubSub under the ExUnit test supervisor for the
  delivery case.
- Exercise the no-op case with a unique, unregistered server name instead of
  terminating and restarting the global child.

**Patterns to follow:** Existing dependency injection in PubSub-facing modules
such as `Aiur.Opencode.SlotPolicy`, plus `start_supervised!` ownership.

**Test scenarios:**

- **Happy path:** a subscriber on the test-owned server receives exactly the
  dashboard update message.
- **Edge case:** broadcasting through an unregistered test server returns
  `:ok` and sends no message.
- **Compatibility:** zero-argument production call shape remains available.

**Verification:** Repeat `observability_pubsub_test.exs` with `--max-cases 4`
while the application-global PubSub child remains continuously registered.

### U2.5. Isolate the provider-interrupt fixture

**Goal:** Keep the lifecycle regression on the interrupt path under suite load.

**Requirements:** R7, R8

**Dependencies:** None

**Files:**

- Modify: `src/test/aiur/agent_runner/provider_lifecycle_test.exs`

**Approach:** Construct the queued operator message with
`delivery_policy: :interrupt`. Existing checkpoint-claim coverage proves these
items are excluded until the direct interrupt signal routes them to queue drain.

**Verification:** Repeat the exact lifecycle case in clean VMs and require the
same exact PR head to pass full-coverage CI twice.

### U3. Publish main-first and prove develop ancestry

**Goal:** Land one generic writer change through the branch sequence required by
the Executor.

**Requirements:** R6, R7, R8

**Dependencies:** U1, U2, U2.5

**Files:**

- No additional source files

**Approach:**

- Re-cut the canonical ticket branch from the current `origin/main` without
  importing develop-only or PR-specific commits.
- Run formatter, warnings-as-errors compilation, affected-test selection, and
  repeated affected tests.
- Open the first draft PR against `main`, reference #1222 without closing it,
  and use the initial CI run plus a full-coverage rerun to prove the exact head
  twice without an intervening commit.
- After human merge, fetch the exact landed main head and merge that head into
  `develop` without recreating or cherry-picking the fix. Resolve only genuine
  base conflicts, prove the landed main fix commit is an ancestor of the
  develop integration head, and let only the develop integration PR close
  #1222.

**Test scenarios:**

- **Integration:** main PR diff contains only U1/U2/U2.5 and plan evidence.
- **Integration:** develop integration diff contains the exact main merge and no
  feature-branch changes from PR #1213 or PR #1036.
- **Workflow:** the main PR leaves #1222 open; the develop integration PR owns
  issue closure after ancestry and CI proof are recorded.

**Verification:** Record the main fix SHA, develop integration SHA, and a
successful ancestry check in the workpad/PR handoff.

## System-Wide Impact

- **Interaction graph:** BuildGate test shell -> detached child -> holder lease;
  Observability facade -> test-owned Phoenix PubSub; interrupt fixture -> direct
  queue drain; git main -> develop.
- **Error propagation:** Test cleanup releases descendants unconditionally;
  unavailable PubSub remains a documented `:ok` no-op.
- **State lifecycle risks:** Release files must be unique per test and installed
  before child launch; test PubSub names must be unique and test-supervised.
- **API surface parity:** Existing zero-argument Observability calls retain
  `Aiur.PubSub` behavior.
- **Integration coverage:** CI full coverage supplies shared-runner scheduling
  pressure that scoped local tests intentionally do not synthesize.
- **Unchanged invariants:** Production BuildGate scripts, lease semantics,
  dashboard topic/message, and unrelated PR code do not change.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| A failed test strands a barrier-held child | Register release cleanup before launch and keep bounded completion waits. |
| Separate test VMs reuse a gate namespace | Give every fixture root a random cross-VM identifier. |
| Parent exits after persisting the holder acknowledgement | Accept the exact durable token before liveness and deadline checks. |
| PubSub injection leaks into callers | Preserve default arguments and cover the existing zero-arg call shape. |
| A green local repetition masks suite pressure | Require exact-head full coverage CI repetition before acceptance. |
| Main/develop delivery absorbs unrelated work | Base the first diff on `origin/main`, merge the validated main SHA exactly, and prove ancestry. |

## Validation Plan

1. Run both BuildGate descendant tests repeatedly in the same VM with
   `--repeat-until-failure` and `--max-cases 4`.
2. Run concurrent clean-VM repetitions of the fake descendant case and verify
   their gate roots and release markers remain isolated.
3. Run `observability_pubsub_test.exs` repeatedly and assert `Aiur.PubSub`
   remains alive before and after the file.
4. Run the repository affected-test selector and every printed test command
   with `--max-cases 4`.
5. Repeat the provider-interrupt lifecycle case in clean VMs at the failing CI
   seeds and retain the strict release barrier and two-turn assertion.
6. Run `mix format` and `mix compile --warnings-as-errors`.
7. Self-review the exact main diff, then hand the draft PR to CI without a
   closing keyword for #1222.
8. Require two successful full-coverage executions on the same main PR SHA;
   after merge, prove exact-main ancestry in the develop integration head and
   close #1222 from that final PR only.

## Sources & References

- GitHub issue #1222 and Agent Workpad comment `4998485843`
- PR #1213 run `29551309799`
- PR #1036 failed-job rerun `29550586146`
- PR #1223 failed CI run `29554647286`
- PR #1223 failed CI run `29556414730`
- `src/test/aiur/build_gate_test.exs`
- `src/test/aiur/agent_runner/provider_lifecycle_test.exs`
- `src/priv/build_gate.bash`
- `src/priv/build_gate_holder.py`
- `src/lib/aiur_web/observability_pubsub.ex`
- `src/test/aiur/observability_pubsub_test.exs`
- `docs/plans/2026-07-14-001-fix-sandbox-safe-build-gate-plan.md`
