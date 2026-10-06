---
contract_id: MP-CT-identity-and-capabilities
owner_feature: MP-R1
status: draft
base_main_sha: 45a290e3
date: 2026-10-06
consumers: [MP-E1, MP-E2, MP-E3, MP-E4, MP-E5, MP-E6, MP-E7, MP-R2, MP-R5, MP-R6, MP-R7, MP-N1, MP-N2, MP-N3, MP-N4, MP-N5, MP-N6, MP-N7]
---

# Contract: identity and capabilities

Who and what a client is talking to, and what that thing can do right now. Every
other contract (events, Commands, conversations, notifications, pairing) refers to
the identifiers defined here instead of defining its own.

This is a draft for coordinator reconciliation. It reuses existing identifiers where
they are sound and adds only what is missing. Field names are proposals; nothing here
exists in code unless a `file:line` at `45a290e3` is cited.

## 1. Identity levels

```text
machine ─┬─ instance (1 repository, 1 Executor seat) ─┬─ executor (consumer, harness session)
         │                                             └─ worker (ticket) ─ session (one agent run)
         └─ instance ...
```

| Level | Identifier | Exists today? | Stability | Source of truth |
|---|---|---|---|---|
| Machine | `machine_id` | **No.** No machine identifier exists in `src/lib` or `packaging` (searched `machine_id`, `host_id`, `/etc/machine-id`) | Durable until the operator resets it | `identity` component |
| Instance | `instance_key` | **Yes**, launcher-side: first 10 hex chars of sha256(realpath(project root)) (`aiur-engine.sh:269-277`) | Changes if the project root path changes | launcher → daemon |
| Repository | `repository` | **Yes**: `TrackerIdentity{kind, owner, repository}` (`src/lib/aiur/tracker_identity.ex:1-60`) and the configured tracker repo | Stable while the remote is the same | config (`tracker.*`) |
| Executor | `executor_consumer_id` | **Yes**: `--as` > `AIUR_EXECUTOR_ID` > `<hostname>-<instance>` (`src/lib/aiur/executor/claims.ex:185-195`); lease via `Aiur.Executor.Principal`; states in `Aiur.Executor.Roster` | Per configured Executor | executor-attention |
| Executor harness session | `executor_session_ref` | **No** (baseline E3: no Executor harness type or transcript) | Per Executor session | MP-E3 defines; this contract reserves the field |
| Worker | `ticket` | **Yes**: `TrackerIdentity` with `status: :joinable` is the cross-surface join key (`tracker_identity.ex:1-8`) | Stable | tracker |
| Worker session | `session_ref` | **Partly**: `Decision.source{agent_id, session_id, event_id}` (`decision.ex:17`), `SessionHandle` (backend + thread, host-bound; `session_handle.ex:1-30`), `LiveConversation` generation handle (`live_conversation.ex:37`) | One agent run; resume may keep the harness thread | agent-runner |

### 1.1 Machine

- **Scope.** A machine is one OS user's aiur installation on one host: the same scope
  as `~/.aiur/` and `~/.config/aiur/`. Two OS users on one host are two machines.
  Reason: instances, the cookie and the instance records are already per user
  (node `aiur-$USER[-KEY]`, AGENTS.md), and pairing (D19) grants access to "every
  instance on the paired machine"; a per-host scope would grant one user's devices
  another user's instances.
- **Value.** `machine_id`: a random 128-bit value, encoded as 26 lowercase base32
  characters. Format and store are **adopted from MP-N2**
  (`contracts/pairing-and-instance-registry.md` §1, §5): `${XDG_CONFIG_HOME:-~/.config}/aiur/machine/identity.json`,
  directory 0700, file 0600, with `machine_label` (default: short hostname) and `created_at`.
  Difference to reconcile (RC-ID-1): MP-N2 creates it at `aiur mobile enable`; this
  contract needs it at first daemon boot, because the capability report and event
  envelopes (MP-R2) carry `machine_id` even when mobile is never enabled. Proposal:
  `identity` creates `identity.json` (id, label, created_at) on first boot; MP-N2 adds
  `machine_key` and the device files when mobile is enabled. It is **not**
  derived from `/etc/machine-id`, the hostname or a MAC address, so it does not leak a
  hardware identifier to paired devices or a push relay.
- **Reset.** `aiur mobile reset` (MP-N2 owns the verb) generates a new
  value. Every pairing becomes invalid (MP-N2 must re-pair). This is the "remote
  unpair-everything" fallback when the device list itself is lost.
- **Label vs identity.** Clients show `label`; they key everything on `machine_id`.
  Hostname changes rename, they do not re-identify.

### 1.2 Instance

- **Value.** `instance_id = "<machine_id>/<instance_key>"` (identical to MP-N2's `instance_ref`;
  one name, `instance_id`, is proposed for all contracts, RC-ID-2). `instance_key` keeps its
  current derivation so control commands, tmux sockets and node names do not change
  (behaviour-preserving).
- **Moved project root.** A new path gives a new `instance_key`, so the phone shows a
  new instance and the old one goes `stale` then is garbage-collected by MP-N2. This
  is accepted: one instance is one checkout (brief §3). The `repository` field lets a
  client show both under the same repository name.
- **Empty key.** `aiur_instance_key` can return empty for an unreadable cwd
  (`aiur-engine.sh:265-268`). Such an instance has no `instance_id` and is not
  discoverable or pairable; the capability report says `identity: degraded`.
- **Records.** The launcher record (`write_aiur_instance_record`, `aiur-engine.sh:1586`)
  does not hold the dashboard URL or port and is never garbage-collected (baseline N2).
  MP-N2 owns extending it; this contract only requires that the daemon can report its
  own `instance_id` without reading that file.

### 1.3 Repository

`repository = {kind, owner, name}` from the configured tracker (GitHub `owner/name`;
Linear `project_slug` with `owner: null`). Clients display `owner/name`. It is a
display and grouping key, never an authorization key.

### 1.4 Executor

- `executor_consumer_id` as today. The one-Executor-seat-per-instance model holds;
  the roster's "multiple executors" support (`Roster` moduledoc) remains a CLI fact,
  and clients show the **active claim holder** as "the Executor".
- `executor_state ∈ {active, idle, stalled, expired, absent, unknown}`: the roster
  states plus `absent` (no claim or principal ever). `unknown` = roster unreadable.
- `executor_harness` and `executor_session_ref`: reserved, filled by MP-E3. Absent
  means `executor.conversation` is `unavailable`.

### 1.5 Worker and session

- A worker is addressed by `ticket` (joinable `TrackerIdentity`); display identifier
  (`#123`) is a locator only.
- `session_ref` is opaque to clients: `"<instance_id>/<ticket>/<generation>"`, where
  `generation` is the agent-runner's run generation. Clients use it to tell "the agent
  restarted" from "same conversation". MP-E4 owns the conversation positions inside a
  session; MP-E2 owns which `session_ref` a Command answer goes to (today answers go to
  the ticket, not the session; baseline E2).

## 2. Capability report

### 2.1 Where

| Surface | Path | Auth | Notes |
|---|---|---|---|
| HTTP | `GET /api/v1/capabilities` | same pipeline as `GET /api/v1/state` (`:dashboard_auth`, `router.ex:186-189`); later also paired-device credentials (MP-N2) | Must be declared **before** `get("/api/v1/:issue_identifier", ...)` (`router.ex:193`) or the catch-all claims it |
| CLI | `aiur capabilities [--json]` | local control RPC | Works with `--no-dashboard` |
| Event | `system.capabilities.changed` on the bus | per MP-R2 external subscriber API | Carries only the new `revision`; clients refetch |

### 2.2 Shape (contract version 1)

```json
{
  "contract": "aiur.capabilities",
  "contract_version": 1,
  "revision": 7,
  "observed_at": "2026-10-06T16:00:00Z",
  "age_ms": 0,
  "freshness": "current",
  "machine": { "machine_id": "…26 chars…", "label": "workstation" },
  "instance": {
    "instance_id": "…/3f9a1c0b2e",
    "repository": { "kind": "github", "owner": "aiur-team", "name": "aiur" },
    "aiur_version": "0.0.8",
    "run_shape": { "dashboard": true, "headless": false, "interactive_cli": true, "executor_mode": true }
  },
  "executor": { "state": "active", "consumer_id": "host-3f9a1c0b2e", "harness": null },
  "capabilities": {
    "agents.run":          { "state": "available" },
    "commands.answer":     { "state": "available", "version": 1 },
    "build_orders":        { "state": "unavailable", "reason": "not_installed" },
    "voice.stt":           { "state": "unavailable", "reason": "not_configured" },
    "executor.conversation": { "state": "unavailable", "reason": "executor_not_managed" },
    "orchestration":       { "state": "degraded", "reason": "snapshot_stale", "observed_at": "…" }
  }
}
```

- `state ∈ {available, degraded, unavailable, unknown}`.
- `reason` (required unless `available`) ∈ `not_installed` (component absent from the
  build or not started in this run shape) · `not_configured` (missing key/config) ·
  `disabled` (operator turned it off, e.g. `observability.dashboard_writable: false`)
  · `not_running` (should be up, is not; e.g. orchestrator process down) ·
  `unsupported_tracker` · `executor_absent` · `executor_not_managed` ·
  `dependency_unavailable` (with `depends_on: [ids]`) · `unknown`.
  Collapsed or unclassified causes use `unknown`, never a specific cause (AGENTS.md
  "a collapsed cause names the collapse at the source").
- `version` per capability is that capability's own wire version (e.g. the Command
  answer payload version from MP-E2). Absent = 1.
- `revision` increments whenever any capability state changes; clients cache by it.
- `observed_at`, `age_ms`, `freshness ∈ {current, stale}` follow the CLI convention
  (AGENTS.md "If a surface computes an age, it renders the age").
- No secret, path, token, port or credential appears. `not_configured` reveals only
  that a key is missing, to an already-authorized client.

### 2.3 Capability IDs (v1)

The list in [capability-matrix.md §2](../bucket-1-refactor/MP-R1/capability-matrix.md)
is normative for v1. Features that add capabilities register new IDs in that table
through their plans. Naming: `<area>[.<sub>]`, lowercase, dot-separated; never reuse
a retired ID.

### 2.4 How the daemon computes it

- Each component registers a `capabilities/0` callback with the composition root
  (`control-cli`). The registry (`Aiur.Capabilities`, proposed) evaluates them from:
  the run-shape flags already passed to `child_specs/1` (`aiur.ex:244-251`), config
  presence, and liveness of the component's named process.
- Reads never block on the orchestrator mailbox: the registry reads `SnapshotStore`
  freshness the same way `Presenter.state_payload/3` does today
  (`presenter.ex:26-33,58`: `snapshot_unpublished`, `orchestrator_unavailable`, stale
  freshness).
- A component that is not compiled in has no callback, so it is `not_installed` only
  if its ID is in the daemon's known-ID table; otherwise it is simply absent.

## 3. Client rules

1. **Detect, do not infer.** Clients read the capability report. They must not infer
   availability from a missing JSON field, an HTTP 404 or a channel join error (the
   current practice, baseline R1). Those remain error paths, not detection.
2. **Unknown IDs are ignored.** Unknown `reason` values are treated as `unknown`.
3. **Absent ID handling.** If `contract_version` is lower than the version that
   introduced an ID, the client shows the capability as `unknown` ("update aiur"),
   not `unavailable`.
4. **Reachability is separate.** `unreachable` (no response), `stale` (`freshness:
   stale` or local cache older than the client's budget) and `unavailable` (answered,
   off) are three different presentations (brief N3).
5. **Refresh.** Refetch on `system.capabilities.changed`, on reconnect, and before
   any write action whose capability might have changed (answer, send, mic).
6. **Writes are re-checked server-side.** A capability report is advisory; every write
   endpoint still enforces its own gate (`:require_writable`, supervisor token,
   pairing scope) and returns a typed error that names the capability.

## 4. Non-happy paths

| Case | Behaviour |
|---|---|
| Daemon up, orchestrator crashed | `orchestration: unavailable/not_running`; `commands.answer: degraded/dependency_unavailable` (answers recorded, not delivered) |
| `machine/identity.json` unreadable or corrupt | Do not regenerate silently (that would orphan pairings). Report `identity: degraded/unknown`, keep serving local use, raise one attention; regeneration only by explicit reset |
| Two instances, same repository, different roots | Two `instance_id`s, same `repository`; clients group by repository and show both |
| Clock skew between machine and phone | `age_ms` is computed by the daemon; clients prefer it to their own clock |
| Restart | `revision` restarts from a persisted counter so a cached older revision is never mistaken for current (store in the instance runtime state dir, or reset with a new `boot_id` field; Phase C picks one) |
| Capability flaps | Clients debounce rendering; the report itself is not debounced |

## 5. Ownership and assumptions about other contracts

- **Reconciliation items:** RC-ID-1 (when `identity.json` is created, above);
  RC-ID-2 (`instance_id` vs `instance_ref` naming); RC-ID-3 MP-R2 advertises
  `events.export` (not `events.subscribe`) with `{v, retention}` — adopted.
- **MP-R2 (events) owns** event IDs, ordering, replay and the external subscription
  API. This contract assumes MP-R2 can carry `system.capabilities.changed` to remote
  subscribers and that event envelopes carry `instance_id`.
- **MP-N2 (pairing) owns** the machine store, `machine_key`, device identity, credentials, scopes, revocation and the
  extended instance record (URL, port). Assumed: a paired-device credential is
  accepted on `GET /api/v1/capabilities` with full-machine scope (D19).
- **MP-E2 owns** Command identity and which `session_ref` an answer targets.
- **MP-E3 owns** `executor_harness` and `executor_session_ref`.
- **MP-E4 owns** conversation positions and anchors inside a `session_ref`.
- **MP-N4 owns** what a push carries; it must use `machine_id`/`instance_id`, never
  hostnames or repository names, in any field a relay can read.
- **MP-R7 owns** per-harness capability callbacks; this contract only defines how
  they surface (`harness.<id>` IDs if needed).
