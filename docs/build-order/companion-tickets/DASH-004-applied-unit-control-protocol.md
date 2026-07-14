# BO: DASH-004 — Confirm applied unit controls

**Kind:** executable

**Provenance:** planned in plan v1 after control-plane adversarial review

**Complexity:** 4 — Correlated cross-process command lifecycle across worker backends and races

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-004

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-004

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-terra`, `phase:2`, `build-lane:runtime`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Every supported per-unit pause or resume request advances through a correlated requested, accepted, worker-applied or rejected/expired lifecycle, so consumers never mistake an optimistic Orchestrator state change for a worker-confirmed control.

## Context and evidence

Current `Aiur.AgentChat.pause/1` and `resume/1` route controls through the Orchestrator, but the pause path may update Orchestrator state after sending control without a correlated acknowledgement that the worker actually applied it. A subsequent snapshot therefore cannot by itself prove worker application. The refreshed prototype flips a client object immediately; production requires an end-to-end control contract before exposing that interaction as authoritative.
BO-004 supplies the repository-qualified ticket identity that this protocol
must carry; bare issue numbers cannot safely address units across repositories.

## Scope

- Define a versioned control request containing `request_id`, BO-004
  repository-qualified typed issue identity, action (`pause` or `resume`),
  worker/backend generation, expected authoritative state/version, requester
  class, and request time. Request IDs are unique per intent and stable across
  safe retry of that intent.
- Define lifecycle states and events: `requested` when admitted, `accepted` when the authoritative control plane routes it to the expected live worker, `applied` only after that worker reports the correlated state transition, `rejected` with a structured reason, and `expired` after a bounded timeout or generation loss.
- Extend supported worker/backend adapters to return a correlated application result. Capability discovery must distinguish applied-confirmation support, request-only support, and unsupported controls; request-only is never labelled applied.
- Make retries with the same request ID idempotent. A new conflicting intent supersedes an older pending request explicitly; late acknowledgement from an old worker generation cannot change current state.
- Publish normalized control lifecycle events and expose lookup/current-pending state for dashboard and audit consumers. On daemon restart, unresolved requests become expired/unknown rather than applied.
- Preserve pause owner/reason and waiting context independently of the command lifecycle. Successful resume clears only the pause state owned by the resumed control path.

## Non-goals

- Render dashboard controls, change max-agent capacity, pause all units, mutate tracker labels, reprioritize tickets, cancel work, or redesign scheduling.
- Claim support for a backend that cannot return application evidence. Such a backend exposes request-only or unsupported capability.
- Persist prompts, transcripts, raw worker responses, credentials, or capability URLs in audit events.

## Existing owner and reuse target

Extend `Aiur.AgentChat`, `Aiur.Orchestrator.PauseResume`, worker control messages, backend adapters, `Aiur.AgentPubSub`/observability events, and their existing capability checks. Preserve the Orchestrator as the sole lifecycle owner.

## Contract and invariants

- `accepted` means routed, not applied. Only a matching request ID plus worker/backend generation can produce `applied`.
- Duplicate requests and duplicate/out-of-order acknowledgements are idempotent. A stale generation can never apply control to a replacement worker.
- Tracker, worker, requester-owned pause, capacity-draining, and dependency-waiting states remain separate; one control result cannot erase an unrelated reason.
- Structured rejection includes a stable class such as `not_found`, `not_eligible`, `unsupported`, `stale_generation`, `worker_unavailable`, `already_in_state`, or `control_failed`, plus a redacted human explanation.
- Protocol failure leaves the authoritative worker state unchanged or unknown and produces observable health; it never forges success to keep UI moving.

## Refreshable implementation notes

- Characterize each active backend's real pause/resume acknowledgement path at pickup, including Codex, Claude headless, and Claude Remote Control. Record request-only capability where true.
- Characterize current main's `completed_provenance` transitions at pickup,
  including completed-to-working replacement, completed-to-deactivated, and
  completed-to-paused/replacement races; do not mistake the runner boundary
  for a terminal tracker outcome.
- Prefer extending existing control envelopes and PubSub topics over creating a parallel dashboard RPC.
- Keep pending-control state bounded per unit and expire it with injected clocks/timers so race tests are deterministic.

## Acceptance and verification

### Agent gate

- Protocol tests cover accepted→applied, structured rejection, timeout, worker crash, daemon restart, backend generation replacement, duplicate request/ack, out-of-order ack, superseding intent, concurrent completion, and unsupported/request-only backends.
- Orchestrator tests prove no state is presented as applied before correlated worker evidence and unrelated pause/waiting reasons survive.
- Security tests prove audit payloads contain no raw command transport, credential, workspace, account, or capability data.

### At-merge gate

- Rebase over current worker adapters and run AgentChat, PauseResume, Orchestrator, backend protocol, PubSub/audit, regression, and full CI suites.

### Human/manual evidence

- From the Executor repository root, drive a real supported worker through pause and resume using the canonical TUI/control surface and capture requested, accepted, and worker-applied states. Also exercise one rejected or expired request without substituting logs for the user-visible state proof.

## Failure, security, migration, and accessibility cases

- Loss of the target worker, acknowledgement, or control process resolves to rejected/expired/unknown with a retryable classification; it never leaves permanent pending state.
- Only existing authenticated/authorized control callers may submit requests. Audit data is redacted and bounded.
- Version the control envelope and accept legacy request-only adapters during migration with explicit reduced capability.
- No direct UI; lifecycle labels and reasons are concise, stable, and suitable for accessible consumers.

## Surfaces

- Reads: BO-004 repository-qualified tracker identity, current Orchestrator unit
  state, worker/backend generation, and capability.
- Writes: control request/ack envelopes, pending lifecycle projection, normalized audit/PubSub events, tests.
- Contracts: correlated unit-control lifecycle, capability levels, rejection taxonomy.

## Sibling boundaries and open gates

DASH-005 renders and invokes this contract. BO-004 owns repository-qualified
identity; this ticket only carries it through the control lifecycle. Capacity
changes remain on the existing slot API and do not share the pause/resume
acknowledgement protocol. Unsupported Remote Control application evidence
remains visible rather than silently weakening the contract.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-004`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
