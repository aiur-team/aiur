---
ticket_id: MP-R2-C5-T04
feature_id: MP-R2
chunk_id: MP-R2-C5
bucket: 1 (Bucket-2-enabling, RC-09)
title: Instance identity provider for exported envelopes (instance_id from MP-R1 Identity; feed unavailable when identity is degraded)
status: blocked
blocked_by: [MP-R2-C5-T02]
prior_units: [U8]
prior_boundaries: [BUS #10]
prior_features: [MP-R1 (owns identity contract, RC-04), MP-N2]
prior_findings: []
size_owner: n/a (new file ≤ 80 lines); re-checked against U8 assignments.csv at 761756f39 (no existing oversized edit)
base_sha: 761756f394e6783794c777668fc1a26a540e4059
researched: 2026-10-06
---

# MP-R2-C5-T04 — `instance` provider for the export envelope

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C5.** Inert until C6.
- **Deliverable:** `Aiur.Events.InstanceId` — one function
  `current() :: {:ok, instance_id} | {:error, reason}` that the exporter
  (C6-T02) calls once per boot and stamps into every envelope and into
  `export.meta.json`. It is an adapter over MP-R1's `Aiur.Identity`; the bus
  never computes identity.
- **Global event key:** `(instance_id, id)` (contract §3), where
  `instance_id = "<machine_id>/<instance_key>"` (RC-02, identity contract
  §1.2). `machine_id` is the prefix of `instance_id`, so the envelope carries
  only `instance`; no separate `machine` field (avoids two sources of truth).
- **Non-goals:** creating, repairing or resetting identity (MP-R1-C2, MP-N2).

## Dependencies and blockers

- **DESIGN-R2 §2 — satisfied.** Approval is recorded in
  `EXECUTOR-APPROVALS.md` at `9ce9fdc6`.
- **MP-R1-C2-T01/T02 — satisfied** (identity owner per RC-04): closed as
  #3260/#3261. The implemented `Aiur.Identity` facade provides machine
  identity and `instance_id/0`; its API is verified below.
- **C5-T02 — remaining blocker:** envelope takes `instance:` from opts.
- Concurrent with C5-T03, C6-T01.

## Verified starting point (761756f394e6783794c777668fc1a26a540e4059)

Refreshed 2026-10-25 from 45a290e3. Original `researched` date retained.
DESIGN-R2 approval is recorded in EXECUTOR-APPROVALS.md at 9ce9fdc6.
Size owners were checked against the U8 ledger; see [refresh audit](../../refresh/MP-R2-C4-T04.md).

| Fact | Evidence at the refreshed head |
| --- | --- |
| Read-only instance id now exists; missing machine/key returns nil | `src/lib/aiur/identity.ex:9-29` (`machine/0`, `instance_key/0`, `instance_id/0`) |
| Missing/invalid instance key remains degraded | `src/lib/aiur/identity.ex:52-60`; `src/lib/aiur/config/instance_key.ex` |
| Machine identity boot/store | `src/lib/aiur/identity/machine.ex`; `src/lib/aiur/identity/store.ex` |
| Run shape includes HTTP listener, headless and Executor flags | `src/lib/aiur/identity.ex:31-49` |

PROPOSED: `src/lib/aiur/events/instance_id.ex` adapter and tests. Delegate to the implemented Identity facade; do not regenerate identity or derive a second key. The original contract assumptions remain the intended adapter behavior.

## Chosen design

```elixir
defmodule Aiur.Events.InstanceId do
  @spec current() :: {:ok, String.t()} | {:error, :identity_unavailable}
  def current do
    case provider().instance_id() do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :identity_unavailable}
    end
  rescue
    _ -> {:error, :identity_unavailable}
  end
end
```

- `provider/0` = `Application.get_env(:aiur, __MODULE__, Aiur.Identity)`
  (default in `src/config/config.exs`), so the bus has no compile-time edge
  to the identity component; `instance_id/0` matches the implemented
  MP-R1-C2-T02 facade.
- **Identity unavailable ⇒ export unavailable.** The exporter (C6-T02) does
  not start writing: it reports `events_unavailable` with reason
  `identity_unavailable`, the capability `events.export` is
  `unavailable/dependency_unavailable` with `depends_on: ["identity"]`
  (C7-T03). Exporting without an instance id would let a client merge two
  instances' streams under one key — wrong data is worse than none
  (AGENTS.md "collapsed cause names the collapse": the reason stays
  `identity_unavailable`, never a generic error).
- **Identity changes between boots** (moved root, explicit reset): the
  exporter compares `current()` with `export.meta.json["instance"]`; a
  mismatch starts a **new epoch** (C6-T03), so clients get `reset`
  (contract §3 fallback rule).

## Implementation steps

1. Add `InstanceId` and the config default.
2. Document in its moduledoc the two consumer rules above (C6-T02 and
   C6-T03 implement them).
3. Add to the C1-T06 member list.

## Non-happy paths

| Case | Result |
| --- | --- |
| `identity.json` unreadable | `{:error, :identity_unavailable}`; feed unavailable; MP-R1 raises the single `system.identity.unreadable` attention — this ticket emits nothing extra |
| Empty instance key (unreadable cwd) | same |
| Provider raises | same (rescued) |
| Identity restored later in the same boot | not picked up until restart (the exporter reads once per boot); documented, matches MP-R1 "reset is explicit" |

## Compatibility and rollout

No config key. Rollback: delete; exporter cannot start without it, which is
the safe direction.

## Verification

`instance_id_test.exs` with a `FakeIdentity` provider in app env:

1. `"returns the provider's instance id"` → `{:ok, "m26chars/abc123"}`.
2. `"nil, empty or raising provider is identity_unavailable"` — three cases.
   **Fails** if the guard is relaxed to pass `nil`/`""` through (mutation).
3. C6-T02's test `"exporter refuses to write without an instance id"` is the
   integration guard (listed there).

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/events/instance_id_test.exs
```

Mutation check: change the guard to `id when is_binary(id)` → the empty
string case in test 2 fails; restore → pass.

## Completion and handoff

- [x] MP-R1-C2-T01/T02 closed (#3260/#3261); provider call matches the
      implemented `Aiur.Identity.instance_id/0` API.
- [ ] Tests 1–2 added and mutation-checked.
- [ ] Docs: none (C7-T01 documents `instance` in the wire format).
- Dependents: C6-T02, C6-T03 (epoch on identity change), C7-T03
  (capability dependency), MP-N4/N6 (deep links resolve `instance`).
