# OCC-2 legacy attention adapter

**Status:** Implemented in ticket #980

**Builds on:**
[`03-occ-1-decision-contract.md`](./03-occ-1-decision-contract.md)

This adapter keeps the pre-OCC attention protocol working while projecting its
operator questions into the canonical Decision audit. It extends existing
owners: `Aiur.DecisionAttention` coordinates live projection and reminders,
`Aiur.AlertFeed` supplies startup candidates, and `Aiur.DecisionStore` remains
the only canonical writer.

## Eligible legacy signals

| Agent event | Decision correlation | Behavior |
|---|---|---|
| `attention.<slug>` | Trusted ticket + bounded `<slug>` | Attempts a blocking Decision projection before the alert and original event fan out. |
| `blocked` or `pause.request` with `payload.reason` equal to `operator_decision` or `operator-decision` | Trusted ticket + fixed `operator-decision` slug | The payload question, or the event message when absent, is projected through the same path. |
| `attention.resolved` | Existing legacy slug from `payload.slug` | Retains legacy alert and `SubscriptionStore` resolution behavior; it does not create or canonically resolve a Decision in OCC-2. |

Ordinary blocked/pause signals, progress, custom events, and coordination
`decision.<slug>` events are not projected.

## Minimal Decision projection

The adapter derives `source_id` as `legacy_attention:<slug>` inside the trusted
ticket boundary. A minimal record contains the trusted ticket context, source
identity, exact question, `kind: "legacy_attention"`, `blocking: true`, and an
empty options list so the future inbox offers only a custom response. It also
stores validated `%{slug, topic}` legacy provenance; the topic must be exactly
`ticket.<ticket>.agent.attention.<slug>`. No options or recommendations are
invented.

The Decision ID is therefore stable for one ticket and slug. Reopening the same
question is a duplicate. A changed legacy question appends the next version
without erasing richer context, options, or recommendation already attached to
that Decision, up to the adapter's bounded legacy-refresh limit. Later versions
retain the earliest source-alert timestamp, while their canonical `created_at`
remains the time each version was accepted. Internally, replay and live writes
build history in constant time per record while the public history remains in
chronological audit order.

## Structured enrichment

A later `decision.requested` payload correlates by providing
`attention_slug`. `Aiur.AgentRunner.ToolExecutor` removes this adapter-only
field and all agent-provided Decision identity/provenance, reconstructs the
trusted ticket-and-slug correlation, and asks `DecisionStore` to append the
structured content to the existing history. The resulting version keeps the
same Decision ID. An unknown slug, invalid slug, mismatched ticket/topic, stale
explicit version, or unavailable store fails closed without creating a second
Decision.

Retries use the trusted backend, session, and protocol call identity as
source-event provenance. An exact retry returns the version produced by that
action even if a later version has since advanced; equivalent current content
from a different action is also a duplicate rather than a no-op audit append.

## Persistence and fanout order

For a live legacy signal whose Decision projection succeeds, ordering is:

1. Validate and append the complete Decision snapshot to `decisions.ndjson`.
2. Atomically replace `decisions.json` and emit the existing persisted
   DecisionStore notifications.
3. Update the legacy open-attention bookkeeping, emit its alert, and schedule
   the bounded reminder.
4. Publish the original generic agent event on its unchanged topic.

A DecisionStore validation, health, append, or projection failure skips the
alert/open-attention side effects and is logged, but it cannot suppress the
original generic event: that event still publishes on its unchanged topic so a
blocked agent remains visible to the operator. The tool reports success when
that compatibility event publishes, without claiming a Decision correlation.
If generic publication fails after durable acceptance, the Decision remains
canonical and recoverable; the caller still receives the existing publication
failure. Structured `decision.requested` calls remain durability-gated and fail
when their canonical write fails.

## Startup compatibility import

`DecisionAttention` loads candidates asynchronously so alert-log scans do not
block live calls. `AlertFeed` restricts workspace discovery to the configured
project, includes the instance-local central alert log, accepts only exact
active `ticket.<id>.agent.attention.<slug>` topics, and excludes resolved
alerts. Repeated reminders collapse to one ticket/slug candidate, retaining
the earliest valid alert timestamp as `source_created_at` provenance and the
latest question.

Each candidate passes through the same DecisionStore projection. Import is
bounded to 100 candidates per registry boot and does not emit an immediate
duplicate alert, but it restores the existing `SubscriptionStore` slug and
bounded reminder. A live open already processed during bootstrap wins over its
delayed import candidate. When a Decision already exists, the current durable
version also wins over the lossy alert-log candidate, so a stale pre-enrichment
question cannot mint a new version or replace richer current content. Because
legacy metadata is absent from old OCC-1 records and included in hashes only
when present, no storage migration or rewrite is required.

## Temporary lifecycle boundary

OCC-2 does not add answer, dispatch, acknowledgement, or canonical resolution
state. Until OCC-3 lands, `attention.resolved` still clears only the legacy
reminder/SubscriptionStore view, while the Decision audit remains an append-only
record of the request. OCC-3 owns the durable answer and delivery lifecycle.
