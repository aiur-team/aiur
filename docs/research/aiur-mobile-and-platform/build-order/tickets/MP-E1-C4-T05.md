---
ticket_id: MP-E1-C4-T05
feature_id: MP-E1
chunk_id: MP-E1-C4
bucket: 2-platform
title: Closed-unmerged ticket PR as a failed prerequisite (webhook mode)
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T02, MP-E1-C3-T03]
prior_units: [U5]
prior_boundaries: [BO #30, BUS #10]
prior_features: [MP-R2]
prior_findings: [MP-E1 F7, RQ-1]
size_owner: "GH_TRUST (github/tracker.ex small addition; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C4-T05 — Detect "PR closed without merging"

> **Plan refresh (wave 0).** RC-08 registers `ticket.<id>.pr.closed_unmerged`
> in MP-R2's catalog. **RC-26 (Phase C/D):** this ticket is its producer. The
> queue's verdict never depends on the event (contract §6 E-A3).

## Identity and outcome

- Bucket 2, MP-E1, C4, T05. Resolves RQ-1.
- **User value:** when a prerequisite's PR is closed unmerged, its dependents
  stay waiting and one attention says so (D6), instead of waiting silently.
- **Deliverable:** optional `Aiur.Tracker` callback
  `ticket_pull_request(issue_id) :: {:ok, nil | %{state: :open | :closed, merged?: boolean()}} | {:error, term()}`
  reading the stored delivery; observer sets `Observation.pr`.

## Dependencies and blockers

- DESIGN-E1, C2-T02, C3-T03.

## Verified starting point (`45a290e3`)

- Webhook deposit stores every delivered PR under `:branch_pull_request`
  keyed by ticket (from the head branch) — `events/github_webhook/deposit.ex:29-35, 630-642`;
  ordered by version (`github/resource_store.ex:365-376`).
- Keys: `ResourceStore.key/4` (`resource_store.ex:447`), `fetch/1` (`:1033-1035`).
- The normalizer publishes nothing for a PR closed unmerged
  (`events/github_webhook/normalizer.ex:645-652`).
- Freshness rule for deliveries: `github/delivered_pull_request.ex:27-36`.

## Chosen design

- GitHub implementation: fetch `ResourceStore.key(:branch_pull_request, owner, repo, id)`;
  body `"state" == "closed"` and `"merged_at" == nil` (and `"merged" != true`)
  → `%{state: :closed, merged?: false}`; open → `:open`; merged →
  `merged?: true`; miss → `nil`. **No request.**
- Verdict (C2-T02): open prerequisite + `closed, merged?: false` → `{:failed, :pr_closed_unmerged}`.
  A newer open PR for the same ticket replaces the stored body (same key), so
  "no open PR" holds by construction.
- **Coverage:** webhook mode only. In poll-only mode the store has no closed
  PR body and the prerequisite stays `pending` — the safe direction (no
  promotion, no false alert). Stated in docs.

## Implementation steps

1. `tracker.ex` callback; GitHub (≈ 20 lines), memory, Linear.
2. Observer: call for open prerequisites with no `agent:error` (cheap; ETS).
3. **Producer (RC-26).** When the observer first sees a ticket's stored PR move
   to `closed, merged?: false`, publish `ticket.<id>.pr.closed_unmerged` through
   `Events.Publisher.publish/3` (class `live`; refs `ticket`, `pr_number`). Publish
   once per observed transition (remember the last published PR version in the
   queue's own state); never in poll-only mode, because nothing is observed there.
   The topic needs no catalog entry to publish (an uncatalogued topic is `live`,
   events contract §9), so this adds no dependency on MP-R2.

## Non-happy paths

Store miss → `nil` → pending. Malformed body → `nil`.

## Compatibility and rollout

Additive; zero requests.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/github/tracker_ticket_pull_request_test.exs` (PROPOSED) "a deposited closed unmerged PR reads closed, not merged" — deposit through `Deposit` with a `pull_request` `closed` payload | `%{state: :closed, merged?: false}`; request count 0 | the implementation |
| same, "a merged PR reads merged" | `merged?: true` | merged check |
| `src/test/aiur/build_queue/observer_test.exs` "closed-unmerged prerequisite fails its dependents" | `{:failed, [:pr_closed_unmerged]}` | observer wiring |
| same, "closed-unmerged publishes ticket.<id>.pr.closed_unmerged once" (subscribe to the Exchange; observe twice) | exactly one event | the producer and its once-only guard |
| same, "no deposit → pending" | `:waiting` | nil mapping |

Mutation check: ignore `merged_at` → test 2 reads unmerged.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/github/tracker_ticket_pull_request_test.exs test/aiur/build_queue/observer_test.exs
```

## Completion and handoff

- [ ] Callback + observer wiring; coverage limit documented.
- [ ] Producer publishes once per transition, webhook mode only; the docs say
      so (RC-26).
- Docs: `concepts/build-orders.md`/queue docs (C9-T02) state the webhook-only
  detection.
- Dependents: C5-T02.
