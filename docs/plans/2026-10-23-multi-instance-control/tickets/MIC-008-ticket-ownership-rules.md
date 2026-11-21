# MIC-008 — Ticket ownership rules in config: `instance.owns` reserves tickets for a live instance; the rest is a shared pool

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** #5947 (adds rule-based preference on top of its claim lease; its heartbeat record carries the rules). Supersedes `instance.ignore.label_prefixes` (#5803) for shared-prefix installs.
**Complexity:** 3 — dispatch eligibility across instances
**Risk:** medium (wrong rule evaluation strands or duplicates work; the lease prevents duplicates)
**Lane:** PC
**Phase hint:** 2
**Depends on:** #5947, MIC-007
**Requirements:** R14, R15, R16
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (KTD11, F4, AE6, U8) · [pack index](../README.md)

## Outcome

The operator writes `instance.owns: [{label: "build-lane:voice"}]` on the NUC (in YAML or with `aiur --instance nuc set instance.owns ...`). Voice tickets go only to the NUC while it is alive, everything else is shared, and when the NUC stops the voice tickets flow to the other instances with no relabeling.

## Context and evidence

- Today ownership is static: `tracker.github.label_prefix` per instance (`src/lib/aiur/config/schema/tracker.ex:30-32`), `instance.ignore.*` for the other instance's tickets (`src/lib/aiur/config/schema/instance.ex:1-29`, `src/lib/aiur/instance.ex`), and manual relabeling to move a ticket (#5947 Problem).
- #5947 adds a shared label prefix, instance id, heartbeats, and an atomic per-ticket claim lease. It does not say which instance should prefer which ticket.

## Scope

- Schema: `instance.owns` — list of `%{label: String.t()} | %{ticket: pos_integer()}`; `instance.pool` — boolean, default true. One entry each in `website/docs-app/reference/configuration.md`.
- Populate #5947's instance-level heartbeat metadata map (amendment A3: #5947 owns the record and its opaque, versioned `metadata` map; this ticket only fills it) with `owns`, `pool`, and `dispatching` (false while the instance is globally paused or its workflow is paused). Rules of a live instance bind only while its `dispatching` is true.
- `Aiur.Instance.eligible?(ticket, self, live_instances)` per KTD11, where `live_instances` comes from #5947's list-live-instances read; the dispatcher consults it before trying the claim lease. Unknown store state: no new dispatch at all, owned tickets included (fail closed, as #5947 AC6); one `instance.ownership_unknown` attention is raised and resolves when the store returns.
- Add `instance.owns` and `instance.pool` to MIC-007's settable keys.
- `aiur status`: one line listing this instance's rules and, when the store is reachable, other live instances' rules.

## Non-goals

- The lease, heartbeat and store themselves (#5947). Leader election (#5948). Removing `label_prefix` or `instance.ignore` (they keep working for static installs, #5947 AC7).

## Existing owner and reuse target

`Aiur.Instance` (`src/lib/aiur/instance.ex`) and its schema; the dispatcher's candidate filter used by #5947.

## Contract and invariants

KTD11 verbatim. A ticket is never dispatched by an instance that is not eligible; the lease still decides between eligible instances.

## Refreshable implementation notes

- Edit: `src/lib/aiur/config/schema/instance.ex`, `src/lib/aiur/instance.ex`, the #5947 heartbeat writer and dispatcher filter (refresh paths when #5947 merges), `src/lib/aiur/config/overrides.ex` allowlist.
- Tests: `src/test/aiur/instance_test.exs` (predicate), plus the #5947 two-orchestrator fixture extended with rules.

## Acceptance and verification

### Acceptance criteria

1. Two live instances, `nuc` owns `build-lane:voice`: only `nuc` attempts the lease for a voice `todo` ticket (AE6).
2. A ticket matching no rule: either instance may take it (the lease picks one).
3. `nuc`'s heartbeat expires: the next poll on `pc` treats the voice ticket as pool and takes it (F4).
4. `instance.pool: false` on `nuc`: `nuc` takes only its owned tickets.
5. Store unreachable on one instance: it starts no new workspace, owned tickets included; one `instance.ownership_unknown` attention is raised and resolves when the store returns. Partition test: the owner loses the store, its heartbeat expires, the peer takes the lease, and the owner never starts a workspace for that ticket.
6. An install with no lease store configured and no `instance.owns` behaves exactly as today (static `label_prefix` / `instance.ignore` split).
7. `aiur set instance.owns '[{"label":"build-lane:voice"}]'` validates and applies.
8. `nuc` owns `build-lane:voice` and is globally paused (heartbeat live, `dispatching: false`): `pc` takes the voice ticket.

### Test that fails without the change

Criterion 1 in the two-orchestrator fixture: with rules, only the owner attempts the lease. Without the change both attempt it (the lease lets one win, so assert on attempts, not on the winner).

### Human/manual evidence

MIC-010: one owned ticket stays on the owning instance; stopping it moves the ticket.

## Docs to update

- `website/docs-app/reference/configuration.md`: `instance.owns`, `instance.pool`.
- `website/docs-app/guide/quick-start.md` two-instance section: rules replace prefix splits for new installs.

## Files it touches

Listed above.

## Dependencies and conflicts

- depends_on: #5947 (instance heartbeat with metadata map, list-live-instances read, dispatcher filter; amendment A3), MIC-007 (settable-key allowlist module it edits).
- serializes_with: #5948 and #5949 on the #5947 store record shape (merge-time).

## First slice Kevin can try

Put `instance.owns` for one label on the NUC; watch `aiur --instance all agents` place that label's tickets only on the NUC.
