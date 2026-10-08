---
ticket_id: MP-R2-C5-T04
feature_id: MP-R2
chunk_id: MP-R2-C5
bucket: 1 (Bucket-2-enabling, RC-09)
title: Instance identity provider for exported envelopes (instance_id from MP-R1 Identity; feed unavailable when identity is degraded)
status: blocked
blocked_by: [DESIGN-R2 §2, MP-R2-C5-T02, MP-R1-C2-T01 (machine identity.json), MP-R1-C2-T02 (instance_id composition)]
prior_units: [U8]
prior_boundaries: [BUS #10]
prior_features: [MP-R1 (owns identity contract, RC-04), MP-N2]
prior_findings: []
size_owner: n/a (new file ≤ 80 lines)
base_sha: 45a290e3
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

- **MP-R1-C2-T01/T02** (identity owner per RC-04): `identity.json` created at
  first daemon boot (RC-01) and the daemon composing `instance_id`. Until
  they land there is no stable id to stamp; status `blocked`.
- C5-T02 (envelope takes `instance:` from opts).
- Concurrent with C5-T03, C6-T01.

## Verified starting point

At `45a290e3` no instance id exists in the daemon (contract §3 "Implicit
(one daemon = one repository)"). Target interface (proposed by MP-R1):

| Fact | Source |
| --- | --- |
| `instance_id = "<machine_id>/<instance_key>"`; `instance_key` keeps its launcher derivation | `contracts/identity-and-capabilities.md` §1.2 (lines 63-79) |
| Empty or invalid `instance_key` → no `instance_id`, `identity: degraded` (`instance_key_missing|instance_key_invalid`) | same, §1.2 and line 102 |
| Unreadable `identity.json` → `instance.instance_id` is `null`, `identity: degraded/identity_unreadable`, no silent regeneration | same, failure table line 299 |
| `Aiur.Identity.Machine.ensure/1` at boot (PROPOSED by MP-R1) | same, line 57 |
| Moved project root → new `instance_key` → new instance | same, §1.2 |

PROPOSED: `src/lib/aiur/events/instance_id.ex`,
`src/test/aiur/events/instance_id_test.exs`.

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
  to the identity component; the function name `instance_id/0` follows
  whatever MP-R1-C2-T02 ships (adjust the one call if MP-R1 names it
  differently).
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

- [ ] MP-R1-C2-T01/T02 merged; provider call matches their API.
- [ ] Tests 1–2 added and mutation-checked.
- [ ] Docs: none (C7-T01 documents `instance` in the wire format).
- Dependents: C6-T02, C6-T03 (epoch on identity change), C7-T03
  (capability dependency), MP-N4/N6 (deep links resolve `instance`).
