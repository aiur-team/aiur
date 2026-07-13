# DASH-002 — Recover canonical current-run membership

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 4 — Crash-safe current-run membership authority, journal recovery, and lifecycle reconciliation

**Risk:** high

**Depends on:** BO-017

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-009, DASH-012, DASH-018, DASH-019, DASH-024, DASH-025, DASH-026 — application supervision tree

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-002

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes one headless-safe, recoverable membership set containing every typed ticket identity observed in the current run, including terminal members retained until that run ends.

## Context and evidence

Current `Orchestrator.StatusReport` describes current runtime state but is not a durable all-state membership authority. Finished, replaced, retry-waiting, or temporarily absent tickets can therefore disappear from a dashboard denominator. BO-017 propagates trusted repository-qualified identity through tracker/runtime records; this ticket owns only current-run membership and recovery. DASH-016 separately composes rich Units rows and filter policy.

## Scope

- Define membership as every BO-017-qualified ticket identity observed in the active `run_id` as queued, retrying, allocated, running, paused, waiting, replaced, or terminal.
- Retain terminal membership through the end of the current run. A new `run_id` creates a new generation; prior-run members never enter the new set.
- Add one daemon-private, run-qualified append/checkpoint protocol for membership and terminal transitions. Persist an accepted transition before publishing the corresponding generation.
- Rebuild exact same-run membership after only the membership process crashes. Reconcile the rebuilt set against current Orchestrator/tracker observations without treating a temporarily absent row as historical proof that it never belonged.
- Validate checksums/schema/generation at startup. Quarantine a malformed tail or checkpoint, preserve the last validated state where possible, and report degraded or unavailable membership instead of a healthy truncated set.
- Clean obsolete generations only after the active `run_id` is established and the new generation cannot replay them.
- Expose bounded snapshot, lookup, generation, health, freshness, and PubSub change APIs. Publish typed membership/lifecycle-transition facts only; do not construct `UnitsRow` values or filter counts.

## Non-goals

- Join BO-005 activity, Decision counts, model/effort/progress facts, define Units filters, encode URL state, or render LiveView UI.
- Become a second Orchestrator lifecycle reducer, retain cross-run history, or infer membership from workspace directories, logs, PR text, or bare issue numbers.
- Store titles, issue bodies, prompts, transcripts, provider payloads, credentials, or account identity.

## Existing owner and reuse target

Build a supervised projection over BO-017 propagated identity, `Aiur.Boot.run_id/0`, canonical tracker `Issue` values, and `Aiur.Orchestrator.StatusReport` lifecycle observations. Reuse the daemon-private state root, atomic/checksummed file patterns, injected filesystem/clock hooks, and PubSub health conventions.

## Contract and invariants

- `run_id` plus repository-qualified ticket identity uniquely keys membership. Bare issue number is never sufficient.
- StatusReport/tracker facts remain lifecycle authority; this projection records observation and retention without overwriting their source values.
- A same-run projection restart reconstructs the same members and terminal retention before reporting healthy. A new run cannot inherit a prior generation.
- Persist-before-publish ordering, replay, and reconciliation are idempotent. Duplicate or out-of-order observations do not create duplicate members or regress a terminal observation silently.
- Empty healthy membership, stale last-known-good membership, corrupt recovery state, and unavailable membership are distinct.

## Refreshable implementation notes

- Refresh BO-017's final propagated identity fields and current StatusReport lifecycle values at pickup; add a compatibility adapter rather than duplicating its owner.
- Keep recovery records content-free and bounded. Prefer one owner process plus pure transition/replay modules so crash cases remain deterministic.
- Characterize daemon restart versus supervised projection restart: `run_id` changes on the former and remains stable on the latter.
- Reconcile the central application supervision tree with every declared
  serialization peer before either overlapping branch executes or merges.

## Acceptance and verification

### Agent gate

- Projection tests cover queue, allocation, retry, pause, wait, replacement, completion, cancellation, typed-identity collision, duplicate/out-of-order observation, terminal retention, and new-run isolation.
- Fault tests kill and restart only the membership process, then prove exact same-run recovery across append/checkpoint races, torn tail, corrupt checksum, write/rename failure, and current-snapshot reconciliation.
- Security tests prove owner-only path containment and absence of titles, bodies, logs, workspaces, provider payloads, credentials, and account facts.

### At-merge gate

- Rebase on BO-017 and the resolved configured integration target; run propagated identity, Orchestrator/StatusReport, run lifecycle, private-state/recovery, packaging, PubSub, and full CI suites.

### Human/manual evidence

- No separate visual evidence. Using a synthetic current run, restart only the projection and show that queued and terminal membership returns exactly; DASH-003 owns real-dashboard proof after DASH-016.

## Failure, security, migration, and accessibility cases

- Unreadable or corrupt recovery state is visibly degraded/unavailable and never reported as an empty healthy run.
- Recovery files are owner-only beneath the canonical daemon state root and contain only versioned run/ticket identity and bounded transition provenance.
- Version the journal/checkpoint schema and document rollback/rebuild behavior; no cross-run analytics migration is introduced.
- No direct UI. Health and unavailable reasons are stable human-readable values for downstream accessible presentation.

## Surfaces

- Reads: BO-017 propagated identity, current `run_id`, StatusReport/tracker lifecycle observations, same-run recovery state.
- Writes: membership journal/checkpoint, supervised membership projection, health/generation PubSub, tests.
- Contracts: current-run membership/terminal retention, recovery generation, snapshot/lookup/health APIs.
- Safety: run-generation isolation, owner-only recovery state, and the
  application supervision tree.

## Sibling boundaries and open gates

DASH-016 alone joins membership to BO-005 activity and owns `UnitsRow`,
predicates, counts, and URL policy. DASH-014 consumes DASH-016 rather than
redefining membership. The declared serialization peers share only the central
application supervision tree; none gains a data dependency or Build Order
membership from that merge-safety constraint.
