# BO-006 — Migrate AgentList to shared activity

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Characterized consumer migration and duplicate-owner removal

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-005

**Serializes with:** none

**Requirements:** BOREQ-006

**Decisions:** DEC-006

**Design evidence:** DESIGN-002

**Researched at:** 1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d

**Suggested labels:** `complexity:3`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

The interactive AgentList renders progress, active stage, and latest
cross-ticket activity from BO-005's shared projection with no duplicate event
fold, while it continues consuming orchestrator status for lifecycle/waiting/
backend facts and preserves selection, live sorting, pane activation, and
existing TUI behavior.

## Context and evidence

Keeping the old AgentList reducer active after BO-005 would create two owners
that can disagree on ordering, restart, and retention. The migration is
separated from projection construction so its PR has one review boundary and
can use characterization tests to prove user-visible TUI parity.

## Scope

- Replace AgentList-owned progress/stage/latest-event accumulation with BO-005
  snapshot and PubSub consumption, keyed by trusted tracker identity.
- Preserve current selected-row identity through live resorting, running/warming
  behavior, pane activation, explicit waiting reasons, latest evidence,
  progress/stage rendering, and headless absence.
- Preserve current main's `⏹️` completed-runner marker and replacement-wait
  behavior: an active tracker ticket at `:completed/:awaiting_dispatch` remains
  visible, consumes no active capacity or AgentList worker slot, and must not
  render as tracker-terminal completion.
- Reconcile initial snapshot with updates without mount/subscribe races,
  duplicate application, or stale state overwriting a newer generation.
- Remove or narrow old AgentList activity state, subscriptions, reducers, and
  pruning only after equivalent behavior is proven through the shared owner.
- Keep presentation-only row state local; document which fields come from
  TicketActivity, which come from StatusReport/agent summaries, and which
  remain AgentList-owned.
- Preserve unknown/stale activity honestly instead of substituting prior UI
  defaults such as zero progress or generic idle.

## Non-goals

- Change AgentList visual design, key bindings, pane lifecycle, sorting policy,
  scheduler behavior, Build Order UI, or GitHub readiness.
- Add durable activity persistence or a compatibility fold that continues as a
  second source indefinitely.
- Change the BO-005 projection contract to fit uncharacterized UI shortcuts.

## Existing owner and reuse target

Update the current AgentList event-intake, state, summary, render-state, and
subscription seams to consume `TicketActivity`. Preserve pane/selection owners
and renderer contracts that do not own activity.

## Contract and invariants

- BO-005 is the sole owner of progress/stage/latest cross-ticket event state
  after cutover. StatusReport remains the lifecycle/waiting/backend owner;
  AgentList combines those typed snapshots only for presentation.
- Selection follows canonical row identity, not transient index, across live
  resorting and roster changes.
- Subscription-before-snapshot or equivalent generation-safe loading prevents
  lost updates during startup.
- TUI exit/restart cannot erase or reset the daemon-owned activity projection.
- Missing/stale shared data remains visible as unknown and never changes
  GitHub/tracker lifecycle.

## Refreshable implementation notes

- Refresh current AgentList module ownership and recent teardown/startup fixes
  on the configured integration branch before editing.
- Capture any behavior not already characterized before deleting the old fold;
  prefer pure row adapters over new process calls in render paths.
- Keep synchronous calls out of high-frequency render/update paths.

## Acceptance and verification

### Agent gate

- Characterization covers selected-row preservation, live resorting, warm-up to
  running transitions, pane open eligibility, existing StatusReport waiting
  reasons, progress/stage, latest evidence, retry, completion, unknown/stale,
  and projection restart.
- Characterization proves the `⏹️` completed-runner row keeps its
  replacement-wait reason, zero-active/zero-slot accounting, visibility, and
  transition to a replacement worker without becoming `Finished`.
- Tests prove only one activity update is applied, lost-subscription windows are
  closed, and AgentList restart does not reset shared state.
- Removed modules/subscriptions have no remaining call sites or duplicate event
  consumers.

### At-merge gate

- AgentList, renderer, pane, event, supervision, compile/lint/spec, and full CI
  pass on the current configured integration branch.
- Any active companion Units work consuming the same projection is rebased or
  serialized rather than introducing a second adapter contract.

### Human/manual evidence

- BO-015 owns the canonical real-CLI/TUI pass, including opening a running
  agent chat pane and observing activity rendered through the new owner.

## Failure, security, migration, and accessibility cases

- Do not expose new raw event/workspace content in TUI rows; retain current
  redaction and safe evidence summaries.
- This is an in-memory ownership migration with no persisted data rewrite;
  remove compatibility code only after current-base proof.
- Preserve non-color state text, selection markers, focus/key behavior, and
  readable unknown/stale states.

## Surfaces

- Reads: BO-005 snapshots/PubSub; current AgentList roster/selection state.
- Writes: AgentList consumer adapter, subscriptions, row derivation, deletion
  of duplicate activity ownership, and characterization tests.
- Contracts: sole event-activity owner plus existing StatusReport ownership;
  generation-safe AgentList consumption; preserved TUI behavior.

## Sibling boundaries and open gates

BO-005 owns projection defects; this ticket owns only the TUI cutover. Units or
other companion consumers reuse the same snapshot and may require merge
serialization, but cannot block this bounded migration.
