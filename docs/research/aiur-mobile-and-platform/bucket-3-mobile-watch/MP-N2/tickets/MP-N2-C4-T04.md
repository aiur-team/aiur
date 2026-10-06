---
ticket_id: MP-N2-C4-T04
feature_id: MP-N2
chunk_id: MP-N2-C4
bucket: 3-mobile-watch
title: GET /v1/instances registry endpoint and the instance RPC client (:erpc from the hidden gateway, 2 s per instance) — resolves RQ-N2-4
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C4-T03, MP-N2-C2-T04]
prior_units: []
prior_boundaries: [CLI, PRJ]
prior_features: [MP-N3]
prior_findings: [RQ-N2-4]
size_owner: n/a (new modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C4-T04 — Registry endpoint and instance RPC

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C4.
- **User value:** a paired phone lists every instance on the machine with a truthful state and a
  dashboard URL (or the reason there is none), in one request.
- **Deliverable:**
  - `GET /v1/instances` (token, signed): `{machine_id, observed_at, instances: [InstanceEntry], sig}`
    using `Aiur.Machine.Registry.snapshot/1` (MP-N2-C2-T04). `?include=summary` is accepted and returns
    `summary: {status: "unsupported", reason: "summary_not_implemented"}` until MP-N3-C2-T01 replaces it.
  - `Aiur.Machine.InstanceRpc.call(node, module, fun, args, timeout_ms \\ 2_000)` (PROPOSED):
    `{:ok, term} | {:error, :timeout | :noconnection | :undef | {:exception, kind}}` built on `:erpc.call/5`,
    with a 4-way concurrency cap per request (`Task.async_stream/3`, `max_concurrency: 4`). MP-N3-C2 uses it
    for `Aiur.InstanceSummary.v1/0`.
- **Non-goals:** the summary content (MP-N3), caching summaries (MP-N3-C2-T02).

## Dependencies and blockers

DESIGN-N2 gate; MP-N2-C4-T03 (plug, signing), MP-N2-C2-T04 (registry). Dependents: MP-N3-C2-*, MP-N1 meta list, MP-N2-C9.

## Verified starting point (base `45a290e3`)

- Existing control plane: the engine runs `"$release_bin" rpc <expr>` per command with a watchdog
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:2333-2387`, default 10 s, `:2273-2279`). Each call boots
  a fresh BEAM: the release `rpc` command uses the `start_clean` boot script "without your application
  or its dependencies" and then connects (<https://mix.hexdocs.pm/1.19.5/Mix.Tasks.Release.html>, Elixir
  1.19.5, accessed 2026-10-06). Whether that client node is hidden is not stated in the docs (UNVERIFIED;
  irrelevant to this design).
- All nodes of one user share the cookie file (`aiur-engine.sh:321-347`) and loopback epmd
  (`src/lib/aiur/distribution.ex:10-12`), so the gateway node can call instances directly.
- `:erpc.call(Node, Module, Function, Args, Timeout)` raises `{:erpc, :timeout}`, `{:erpc, :noconnection}`
  or re-raises the remote exception (`undef` for a missing function) — Erlang `erpc`
  (<https://www.erlang.org/doc/apps/kernel/erpc.html>, OTP 29 page, accessed 2026-10-06; module present since OTP 23).

## Chosen design (RQ-N2-4 resolution)

- **`:erpc` from the gateway node, not `release_bin rpc`.** The gateway is already a distributed (hidden)
  node with the right cookie (MP-N2-C4-T01). One `:erpc.call/5` costs a message round trip; one
  `release_bin rpc` costs a BEAM boot plus a connection per call, and the gateway would multiply it by
  every instance every poll. Shelling out also loses typed errors (it returns text).
- **Timeouts:** 2 s per instance call (the dashboard's own snapshot read allows 15 s,
  `src/lib/aiur/http_server.ex:67`, which is far too long for a list row; MP-N3 RQ-N3-1 measures the
  actual cost of the summary and may lower it). The whole `/v1/instances` request is bounded at 3 s:
  stragglers are reported per instance as `stale` with `state_reason: "rpc_timeout"` (contract §6.3
  "summary RPC timed out" → `stale`).
- Error mapping: `:timeout` → `stale/rpc_timeout`; `:noconnection` → re-check liveness (`crashed` or
  `unknown`); `:undef` → `summary: {status: "unsupported", reason: "instance release predates summary v1"}`
  (contract §7); anything else → `unknown` with `state_reason: "rpc_error"` (never a specific cause).
- The registry itself (without summaries) needs **no** RPC: records, adverts and epmd are local files and
  one `:erl_epmd.names/1` call. So `/v1/instances` without `include=summary` works even if every
  instance is wedged.

## Implementation steps

1. `src/lib/aiur/machine/instance_rpc.ex` (PROPOSED). 2. Router route + controller using `Registry.snapshot/1`
and `Signed.json/3`. 3. Tests. About 150 production lines.

## Non-happy paths

All in the mapping above. Zero instances → `instances: []` with 200 (not an error, acceptance from plan §5).

## Compatibility and rollout

New endpoint; instances are only read.

## Verification

`src/test/aiur/machine/registry_endpoint_test.exs` and `instance_rpc_test.exs`:

1. `"two live, one no-dashboard and one crashed record produce live, live with reachable false, crashed"` (plan acceptance 4; fixture files + fake epmd names).
2. `"zero instances returns an empty list"`.
3. `"response is signed"`.
4. `"rpc timeout maps to stale rpc_timeout"` — `call/5` against a local process that sleeps (use `node()` itself
   with a test module). *Fails without:* the mapping (mutation: map timeout to `live` → fails).
5. `"undef maps to unsupported"`; 6. `"unclassified error maps to unknown rpc_error"` (mutation: map to
   `crashed` → fails; AGENTS.md collapsed-cause rule).
7. `"concurrency never exceeds 4"` (counter in the fake).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/registry_endpoint_test.exs test/aiur/machine/instance_rpc_test.exs
```

Live check (Executor): two `aiurdev --bg` instances in two checkouts, one with `--no-dashboard`; kill -9 a
third; `curl -H "Authorization: Bearer <token from the C5 reference client>" http://127.0.0.1:4710/v1/instances`.

## Completion and handoff

- [ ] Tests pass; mutation for 4, 6 recorded.
- [ ] MP-N3-C2-T01 notified: `InstanceRpc.call/5` and the `include=summary` placeholder to replace.
- [ ] Docs: none user-facing beyond the pairing guide (MP-N2-C9-T01).
