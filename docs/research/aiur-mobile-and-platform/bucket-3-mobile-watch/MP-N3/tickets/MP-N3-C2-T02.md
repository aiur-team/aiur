---
ticket_id: MP-N3-C2-T02
feature_id: MP-N3
chunk_id: MP-N3-C2
bucket: 3-mobile-watch
title: "Gateway summary cache (5 s) shared across devices, with observed_at and age on every entry"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C2-T01]
prior_units: []
prior_boundaries: [PRJ]
prior_features: [MP-N2]
prior_findings: []
size_owner: "n/a (new gateway module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C2-T02 — Summary cache

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C2.
- **User value:** several phones (and their watches, through the phone) polling every 15 s do not
  multiply RPCs into busy instances, and every cached value says how old it is.
- **Deliverable:** an ETS-backed cache keyed by `instance_id`, TTL 5 s, single-flight per key,
  used by `SummaryFanout.collect/2`.
- **Non-goals:** push invalidation (later, from MP-R2 events).

## Dependencies and blockers

DESIGN-N3; MP-N3-C2-T01. Concurrent with C3/C5.

## Verified starting point (base `45a290e3`)

No gateway exists. Precedent for a read-through ETS cache with honest misses:
`Aiur.GitHub.ReadCache` started before polling (`src/lib/aiur.ex:340-345`).

## Chosen design

- Entry `{instance_id, boot_id, summary, fetched_at_monotonic, fetched_at_utc}`. A hit within
  5 000 ms returns the cached summary with `cache_age_ms` added to the entry.
- Single-flight: concurrent misses for one key wait on one RPC (a `:global`-free local
  `Registry`/GenServer per key, or a GenServer holding waiters).
- A changed `boot_id` from the registry (instance restarted) invalidates the entry (RC-04 boot_id).
- Failures are **not** cached longer than 1 s, so a recovered instance shows up quickly.

## Implementation steps

1. `src/lib/aiur/machine/summary_cache.ex` (PROPOSED), started in the gateway supervision tree.
2. `SummaryFanout` consults it. About 90 lines.

## Non-happy paths

Cache process restart → empty cache (cold misses only). Clock: TTL uses monotonic time; ages
reported to clients use the gateway's UTC clock and are recomputed per response.

## Compatibility and rollout

Internal. TTL is a module attribute, not a config key (no operator need identified).

## Verification

`src/test/aiur/machine/summary_cache_test.exs` (injected clock and RPC counter):

1. `"two reads within 5 s make one rpc"`. *Fails without:* the cache lookup.
2. `"ten concurrent misses make one rpc"`. *Fails without:* single-flight.
3. `"boot_id change invalidates"`. 4. `"failures expire after 1 s"`.
5. `"cache_age_ms is present and grows"` (AGENTS.md: a computed age is rendered — the field must
   exist in the response; MP-N3-C3 renders it).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/summary_cache_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks. Docs: none. Dependents: MP-N3-C4-T04 (poll cadence assumes it).
