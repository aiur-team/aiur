# MP-N5 path-refresh contract requests

Evidence SHA: `3b00b8f2cd0bfc9acdffe3b07ee5f1c6ca2ab56a` (2026-10-27).
These requests record integration gaps; this documentation refresh does not
implement or approve either change.

## CR-N5-PATH-1 — Command lookup result shape

Owner: commands / MP-E2. Consumer: MP-N5-C3-T03.
The old `Aiur.DecisionStore.get(id, server)` returns `{:ok, Decision.t()}`.
Store is private. Public `Aiur.Commands.get(id, opts)` delegates to
`Aiur.DecisionQuery.get/2` and returns
`{:ok, %{decision: decision, scope: scope, health: health}}`, or errors including
`:not_found`, `:store_unavailable`, `{:indeterminate, health}` and invalid ID.
The second argument is keyword options, not a GenServer name.

Request: confirm an adapter that unwraps `decision`, preserves health and treats
indeterminate/unavailable results as unknown under C3-T03's send-on-unavailable
rule, or supply an approved equivalent facade. Stop this integration point
until the owner confirms the shape; never treat unavailable as not found.
Reconciliation can already use public `Aiur.Commands.list_decisions/0,1,2`.

## CR-N5-PATH-2 — Progress facade

Owner: build-orders / MP-E1 and MP-R1 boundaries. Consumers: C2-T01/T03.
`Aiur.BuildProgress.facts/0,1,2` and `subscribe/0` exist, but
`components/build-orders.json` does not declare `Aiur.BuildProgress` as a facade.
The optional push-relay → build-orders edge alone does not allow this reference.

Request: export the facts and subscription contract through an approved facade
(or declare the existing module public). Preserve `{:build_progress_changed,
fact}` and unknown/stale facts; do not fall back to recomputing RootSummary or
25% topics. Stop these imports until that approval lands.

Runtime directory and journal approval remains owned by
[CR-N4-PATH-1](../MP-N4/CONTRACT-REQUESTS.md); do not duplicate that request.

## CR-N5-PATH-3 — DurableConsumer handler behaviour

Owner: event-bus / MP-R2. Consumer: C2-T01 ExportFeed handler.
`Aiur.Events.DurableConsumer` and `ExportSource` are public facades, but
`Aiur.Events.DurableConsumer.Handler` is not. Declaring that behaviour from
push-relay currently fails `R-private` even though its callbacks are the
Consumer's integration contract. `Source` is likewise private; N5 can reuse
ExportSource without implementing a custom bus Source.

Request: expose the handler behaviour or supply an approved handler integration
contract. Stop that behaviour import until approval; do not omit the declaration
merely to evade the boundary checker.
