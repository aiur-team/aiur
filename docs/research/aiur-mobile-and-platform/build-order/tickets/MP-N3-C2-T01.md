---
ticket_id: MP-N3-C2-T01
feature_id: MP-N3
chunk_id: MP-N3-C2
bucket: 3-mobile-watch
title: "Gateway summary fan-out: GET /v1/instances?include=summary with bounded concurrency, timeouts and unsupported mapping"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C1-T01, MP-N2-C4-T01, MP-N2-C4-T04]
prior_units: [U9]
prior_boundaries: [CLI, PRJ]
prior_features: [MP-N2]
prior_findings: []
size_owner: "n/a (new gateway module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C2-T01 — Summary fan-out in the machine gateway

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C2 "Gateway fan-out".
- **User value:** one request per machine returns every instance with its summary, even when some
  instances are slow, down, on an older release or running with `--no-dashboard`.
- **Deliverable:** `Aiur.Machine.SummaryFanout.collect/2` (PROPOSED) and its use by the registry
  endpoint when `include=summary` is present (contract §6.3).
- **Non-goals:** the registry state machine (MP-N2-C2-T04), caching (C2-T02), event streams.

## Dependencies and blockers

- DESIGN-N3; MP-N3-C1-T01 (`Aiur.InstanceSummary.v1/0` exists in instances).
- MP-N2-C4-T01 (gateway node), MP-N2-C4-T04 (registry endpoint and the per-instance RPC primitive;
  RQ-N2-4 — `:erpc` from the gateway node versus `release_bin rpc` — is resolved there; this
  ticket uses whatever `Aiur.Machine.InstanceRpc.call/4` that ticket defines).
- Concurrent with: MP-N3-C3, MP-N3-C5.

## Verified starting point (base `45a290e3`)

- Instances are distribution nodes `aiur-$USER[-KEY]@127.0.0.1` sharing `~/.config/aiur/cookie`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:280-294`); the launcher's control RPC has a
  watchdog timeout (`run_release_rpc_with_timeout`, `:2333-2387`).
- An RPC to a module the remote release lacks raises `undef` on the remote side; with `:erpc.call/5`
  it surfaces as `{:exception, :undef, _}` raised as an `ErlangError` in the caller (OTP `erpc`
  docs, <https://www.erlang.org/doc/apps/kernel/erpc.html>, accessed 2026-10-06, OTP 29 doc page;
  the pinned OTP 28 has the same API).
- Contract §6.3 `InstanceEntry.summary: InstanceSummary | {status: "unavailable"|"unsupported", reason}`.

## Chosen design

- Only instances whose registry state is `live` or `stale` are called. `crashed`, `stopped`,
  `starting`, `unknown` get `summary: {status: "unavailable", reason: <state>}` without an RPC.
- Concurrency: `Task.async_stream/3` with `max_concurrency: 4`, `timeout: 2_000`,
  `on_timeout: :kill_task`.
- Result mapping:

| RPC outcome | `summary` | registry effect |
|---|---|---|
| `{:ok, map}` with `version: 1` | the map | none |
| map with unknown major `version` | `{unsupported, "summary version N"}` | none |
| `undef` for `Aiur.InstanceSummary` | `{unsupported, "instance release predates summary v1"}` | none |
| timeout | `{unavailable, "summary_timeout"}` | state `live` → `stale` (contract §6.3) |
| `noconnection` / node down | `{unavailable, "node_unreachable"}` | left to MP-N2 liveness |
| anything else | `{unavailable, "unknown"}` | none |

- The gateway adds `observed_at` (its own clock) to each entry; the instance's own `observed_at`
  stays inside the summary. Both are rendered (contract Fact `age_ms`).

## Implementation steps

1. `src/lib/aiur/machine/summary_fanout.ex` (PROPOSED).
2. Registry controller: call it when `include=summary`. About 110 lines.

## Non-happy paths

Covered by the mapping. A slow instance never delays others beyond 2 s total (stream timeout);
the whole request is bounded by `ceil(n/4) × 2 s` — with C2-T02's cache, repeated requests do not
multiply RPCs.

## Compatibility and rollout

Older instances show `unsupported` with an update hint (MP-N3 plan §5). Version skew in the
other direction (newer instance) yields `unsupported` only when the major version changes.

## Verification

`src/test/aiur/machine/summary_fanout_test.exs`, with an injected `rpc_fun`:

1. `"live instance summary is attached"`.
2. `"undef maps to unsupported with the release reason"`. *Fails without:* the undef clause
   (mutation: map undef to `unavailable`).
3. `"timeout maps to unavailable summary_timeout and marks the entry stale"`.
4. `"crashed and stopped instances are not called"` (counting fake). *Fails without:* the state filter.
5. `"five slow instances finish within 4.5 s with max_concurrency 4"`.
6. `"unexpected error maps to unknown, not a specific cause"`.

One integration test starts a peer node with `:peer.start_link/1` (OTP `peer` module) running a
stub `Aiur.InstanceSummary` to exercise the real RPC path; it is tagged `:distributed` and is skipped
when distribution cannot start.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/summary_fanout_test.exs --include distributed
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded.
- [ ] Docs: the gateway API section of the pairing guide lists `include=summary` (MP-N2-C9-T01).
- [ ] Dependents: MP-N3-C2-T02, MP-N3-C4-T02.
