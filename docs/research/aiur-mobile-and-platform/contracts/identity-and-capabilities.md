---
contract_id: MP-CT-identity-and-capabilities
owner_feature: MP-R1
status: reconciled (Phase D fix pass; applies RC-01, RC-02, RC-04, RC-11, RC-12, RC-36, RC-37, RC-39, RC-40; X-02, X-21, X-35)
contract_version: 1
base_main_sha: 45a290e3
date: 2026-10-06
consumers: [MP-E1, MP-E2, MP-E3, MP-E4, MP-E5, MP-E6, MP-E7, MP-R2, MP-R5, MP-R6, MP-R7, MP-N1, MP-N2, MP-N3, MP-N4, MP-N5, MP-N6, MP-N7]
implemented_by: [MP-R1-C2-T01, MP-R1-C2-T02, MP-R1-C3-T01, MP-R1-C3-T02, MP-R1-C3-T03, MP-R1-C3-T04, MP-R1-C3-T05, MP-R1-C3-T06, MP-R1-C3-T07]
---

# Contract: identity and capabilities

Who and what a client is talking to, and what that thing can do right now. Every
other contract (events, Commands, conversations, notifications, pairing) refers to
the identifiers defined here instead of defining its own.

Ownership (RC-04): **MP-R1 owns this contract.** It also carries MP-N1's additions:
a per-boot ID, minimum client versions, and a typed "capability unavailable" error.
Classification (RC-12): the identity store, the capability registry, the endpoint and
the CLI verb are **Bucket-2 enabling work inside MP-R1**. They add an API and change no
existing behaviour. DESIGN-R1 (S1-S3, S5) gates their operator surfaces.

Nothing below exists in code unless a `file:line` at `45a290e3` is cited. Module and
file names marked PROPOSED are the names the MP-R1 tickets create.

## 1. Identity levels

```text
machine ─┬─ instance (1 repository, 1 Executor seat) ─┬─ executor (consumer, harness session)
         │                                             └─ worker (ticket) ─ session (one agent run)
         └─ instance ...
```

| Level | Identifier | Exists today? | Stability | Source of truth |
|---|---|---|---|---|
| Machine | `machine_id` | **No.** No machine identifier in `src/lib` or `packaging` (searched `machine_id`, `host_id`, `/etc/machine-id`) | Durable until an explicit reset | `identity` component (MP-R1-C2-T01) |
| Instance | `instance_key` | **Yes**, launcher-side: first 10 hex chars of sha256(realpath(project root)) (`aiur-engine.sh:269-278`), exported to the daemon as `AIUR_INSTANCE_KEY` (`aiur-engine.sh:291-298`) and already read by the daemon (`config/paths.ex:331-335`, `executor/claims.ex:477-482`) | Changes if the project root path changes | launcher → daemon env |
| Instance | `instance_id` | No | As `instance_key` | `identity` (MP-R1-C2-T02) |
| Repository | `repository` | **Yes**: `Aiur.Tracker.project_identity/0` (`tracker.ex:152-159`; GitHub `owner/name` from `GitHub.Config.repo/0`, Linear `project_slug`, memory `"memory"`) and `tracker.kind` | Stable while the configured remote is the same | `tracker` component provider (MP-R1-C3-T02) |
| Executor | `executor_consumer_id` | **Yes**: `--as` > `AIUR_EXECUTOR_ID` > `<hostname>-<instance>` (`executor/claims.ex:185-195`); lease via `Aiur.Executor.Principal`; states in `Aiur.Executor.Roster` (`roster.ex:110-124`) | Per configured Executor | `executor-attention` provider (MP-R1-C3-T02) |
| Executor harness session | `executor_session_ref` | **No** (baseline E3) | Per Executor session | MP-E3 defines; reserved here |
| Worker | `ticket` | **Yes**: `TrackerIdentity` with `status: :joinable` (`tracker_identity.ex:1-8`) | Stable | tracker |
| Worker session | `SessionRef` | Partly (`Decision.source`, `SessionHandle`, `LiveConversation` generation handle) | One agent run | **MP-E4** (conversations contract §2), see §1.5 |

### 1.1 Machine

- **Scope.** One OS user's aiur installation on one host: the same scope as `~/.aiur/`
  and `~/.config/aiur/`. Two OS users on one host are two machines. Reason: node names,
  the cookie and instance records are already per user (`aiur-engine.sh:294`), and
  pairing (D19) grants a device every instance on the machine.
- **Value.** `machine_id`: 128 random bits (`:crypto.strong_rand_bytes(16)`), encoded
  `Base.encode32(bytes, case: :lower, padding: false)`, which is exactly 26 characters
  (verified locally, Elixir 1.19.5 / OTP 28, 2026-10-06). It is **not** derived from
  `/etc/machine-id`, the hostname or a MAC address, so no hardware identifier reaches a
  paired device or a push relay.
- **Created at first daemon boot (RC-01).** `Aiur.Identity.Machine.ensure/1` (PROPOSED)
  runs in `Aiur.Application.start/2` before the supervisor starts, next to the other
  best-effort boot writes (`aiur.ex:46-55`). MP-N2 reads this file and never creates a
  second identity.
- **Store.** Directory resolution, first match wins (same precedence as
  `Aiur.Upgrade.State.state_dir/0`, `upgrade/state.ex:35-40`):
  1. `Application.get_env(:aiur, :machine_state_dir)` (tests only);
  2. `$AIUR_BG_STATE_DIR/machine` (the launcher always exports it, default
     `${XDG_CONFIG_HOME:-$HOME/.config}/aiur`, `aiur-engine.sh:281-286`);
  3. `${XDG_CONFIG_HOME:-~/.config}/aiur/machine`.

  The default resolves to `~/.config/aiur/machine/identity.json` (RC-01). The agent-IR
  sandbox sets its own `AIUR_BG_STATE_DIR` (`scripts/aiurdev:583`), so `--test` runs get a
  sandbox machine identity and never touch the operator's.
- **File format** (`identity.json`, directory 0700, file 0600):

  ```json
  {"schema_version": 1, "machine_id": "…26 chars…", "machine_label": "workstation",
   "created_at": "2026-10-06T16:00:00Z"}
  ```

  MP-N2 keeps its own data in sibling files; the machine public key is
  `machine_key.pub` (pairing §5), never a copy inside `identity.json` (Phase D,
  CR-R1-2). Readers ignore unknown fields. MP-R1 code **only creates** the file; it never
  rewrites it. The only rewriter is MP-N2's gateway (single writer of the machine store),
  and only for `machine_label` (label editing) and the reset path; it preserves every
  field it does not own and never changes `machine_id` outside reset.
- **No-clobber creation.** Write a temp file with mode 0600 and fsync, then hard-link it
  to `identity.json` with `File.ln/2`, then remove the temp file. `link(2)` fails with
  `:eexist` when the target exists (verified locally: second `File.ln/2` returns
  `{:error, :eexist}`), so two daemons booting at once cannot produce two identities:
  the loser reads the winner's file.
- **Reset.** `aiur mobile reset` (MP-N2 owns the verb) writes a new value; every pairing
  becomes invalid. Deleting the file has the same effect at the next boot.
- **Label vs identity.** Clients show `machine_label`; they key everything on
  `machine_id`. Default label: the first DNS label of `:inet.gethostname/0`.

### 1.2 Instance

- **Value (RC-02).** `instance_id = "<machine_id>/<instance_key>"`. This is the only name
  used by every contract; `instance_ref` is retired. `instance_key` keeps its current
  derivation so node names, tmux sockets and control commands do not change.
- **Valid key.** The daemon reads `AIUR_INSTANCE_KEY` and accepts `^[A-Za-z0-9_-]{1,64}$`
  (the launcher already puts it in an Erlang node name, `aiur-engine.sh:294`).
- **Empty or invalid key.** `aiur_instance_key` can return empty for an unreadable cwd
  (`aiur-engine.sh:263-268`), and the variable can be overridden. Then `instance_id` is
  `null`, the instance is not discoverable or pairable, and capability `identity` is
  `degraded` with reason `instance_key_missing` or `instance_key_invalid`.
- **Moved project root.** A new path gives a new `instance_key`, so a phone sees a new
  instance; the old one goes `stale` and MP-N2 garbage-collects it. One instance is one
  checkout (brief §3). `repository` lets a client group both.
- **Records.** The launcher record (`write_aiur_instance_record`, `aiur-engine.sh:1586`)
  is MP-N2's to extend. The daemon reports its own `instance_id` without reading it.

### 1.3 Repository

`repository = {kind, owner, name}` from the configured tracker: GitHub `owner/name`
split at the first `/`; Linear `{kind: "linear", owner: null, name: project_slug}`;
memory `{kind: "memory", owner: null, name: "memory"}`; unresolved → `null`. It is a
display and grouping key, never an authorization key, and never appears in a field a
push relay can read (MP-N4).

### 1.4 Executor

- `executor_consumer_id` as today. Clients show the **active claim holder** as "the
  Executor"; the roster's multiple-executor support stays a CLI fact.
- `executor.state ∈ {active, idle, stalled, expired, absent, unknown}`: the roster
  states plus `absent` (no claim entry at all). `unknown` covers an unreadable roster
  and roster `unknown`. The provider builds the roster with `record?: false`, because
  `Roster.build/1` records observations by default (`roster.ex:52-66`) and a read must
  not change what the next `aiur executor` read sees.
- `executor.harness` and `executor.session_ref`: reserved, filled by MP-E3. Absent means
  `executor.conversation` is `unavailable` with reason `executor_not_managed`.
- There is no separate `executor_live` fact (Phase D, CR-E2-6). **"A live Executor"
  means `executor.state ∈ {active, idle}`** (RC-37), built with `record?: false`.
  `stalled`, `expired`, `absent` and `unknown` are **not** live: D9's "no live Executor,
  go to the human" applies to them. MP-E2 routing (command contract §4, MP-E2-C2-T01)
  reads the same roster call with the same rule. Clients may show `stalled` with its
  own label, but routing treats it as not live. When several consumers are present,
  the instance's summary state is the highest of
  `active > idle > stalled > expired > absent > unknown` (pairing §7 uses this order).

### 1.5 Worker and session

- A worker is addressed by `ticket` (joinable `TrackerIdentity`); `#123` is a locator.
- **Session identity is owned by MP-E4** (CQ3 resolved): `SessionRef =
  {conversation_id, session_seq}`. `conversation_id` is unique within one instance and is
  **not** derived from `instance_id`; the global form is `GlobalEntryRef {instance_id,
  conversation_id, pos}` (`contracts/conversations-transcripts-anchors.md` §3). `SessionRef`
  is the single session identity for identity, Commands and notifications (CR-R1-5).
  Earlier drafts of this contract
  proposed `"<instance_id>/<ticket>/<generation>"`; that form is withdrawn. MP-E2's
  `requester.session_ref` uses MP-E4's `SessionRef`.

## 2. Capability report

### 2.1 Where

| Surface | Path | Auth | Notes |
|---|---|---|---|
| HTTP | `GET /api/v1/capabilities` | `:dashboard_auth` pipeline, same as `GET /api/v1/state` (`router.ex:186-189`); paired-device credentials later (MP-N2) | Declared above `get("/api/v1/:issue_identifier", …)` (`router.ex:193`), which would otherwise claim it. The route lives in the identity-owned `AiurWeb.Routes.Capabilities`, which `web-shell` composes through the registration seam (RC-39, MP-R1-C6-T01); identity does not depend on web-shell |
| CLI | `aiur capabilities [--json]` | local control RPC (`run_control_rpc`, `aiur-engine.sh:2419`) | Works with `--no-dashboard`; needs a running daemon |
| Event | `system.capabilities.changed` | internal bus now (`Events.Publisher.publish/3`, `publisher.ex:111-113`); remote via MP-R2's external API | Payload `{revision, boot_id}` only; clients refetch |

### 2.2 Shape (contract version 1)

```json
{
  "contract": "aiur.capabilities",
  "contract_version": 1,
  "boot_id": "q2Xr…16 chars…",
  "revision": 7,
  "observed_at": "2026-10-06T16:00:00Z",
  "age_ms": 840,
  "freshness": "current",
  "min_client_versions": {},
  "machine": { "machine_id": "…26 chars…", "label": "workstation" },
  "instance": {
    "instance_id": "…26 chars…/3f9a1c0b2e",
    "aiur_version": "0.0.9",
    "run_shape": { "http_listener": true, "dashboard_pages": true, "dashboard": true,
                   "headless": false, "interactive_cli": true, "executor_mode": true }
  },
  "repository": { "kind": "github", "owner": "aiur-team", "name": "aiur" },
  "executor": { "state": "active", "consumer_id": "host-3f9a1c0b2e", "harness": null },
  "capabilities": {
    "identity":            { "state": "available" },
    "api.http":            { "state": "available" },
    "agents.run":          { "state": "available" },
    "commands.answer":     { "state": "available", "version": 1 },
    "build_orders":        { "state": "unavailable", "reason": "unsupported_tracker" },
    "voice.stt":           { "state": "unavailable", "reason": "not_configured" },
    "executor.conversation": { "state": "unavailable", "reason": "executor_not_managed" },
    "orchestration":       { "state": "degraded", "reason": "snapshot_stale", "observed_at": "…" }
  }
}
```

- `boot_id` (RC-04, C-A5): `Aiur.Boot.run_id/0` (`boot.ex:92-98`), minted once per BEAM.
  A restart gives a new `boot_id`.
- `revision`: a non-negative integer that only increases **within one `boot_id`**. It is
  in memory; it is not persisted. Clients cache by `(instance_id, boot_id, revision)`. A
  cache from another `boot_id` is shown as stale until refetched. This replaces the
  draft's "persisted counter or boot_id" choice.
- `observed_at` is when the daemon last computed the capabilities; `age_ms` is computed by
  the daemon at response time; `freshness` is `current` while `age_ms ≤ 3 × tick`
  (tick 2,000 ms, so 6,000 ms), otherwise `stale` (AGENTS.md "if a surface computes an
  age, it renders the age"). Clients prefer `age_ms` to their own clock.
- `run_shape` (CR-C6-1 from MP-R1-C6-T03, applied): `http_listener` (the HTTP endpoint
  and JSON API are up) and `dashboard_pages` (LiveView pages are mounted) are separate,
  because MP-R1-C6-T03 adds an internal shape with the API on and the pages off.
  `dashboard` is a deprecated v1 alias of `http_listener`; clients must read the two new
  fields. Until C6-T03 merges, `dashboard_pages == http_listener`.
- `min_client_versions` (RC-04, C-A6): a map `client_kind → semver string`, kinds
  `phone`, `watch`, `streamdeck`. Empty map = no minimum. It is a code constant raised in
  a release, not operator config.
- `state ∈ {available, degraded, unavailable, unknown}`.
- `reason` (required unless `available`) ∈ `not_installed` (component absent from the build
  or not started in this run shape) · `not_configured` (missing key/config) · `disabled`
  (operator turned it off, e.g. `observability.dashboard_writable: false`) · `not_running`
  (should be up, is not) · `unsupported_tracker` · `executor_absent` ·
  `executor_not_managed` · `snapshot_stale` · `snapshot_unpublished` ·
  `instance_key_missing` · `instance_key_invalid` · `identity_unreadable` ·
  `journal_corrupt` (a component's durable journal has a corrupt tail and the feature
  stopped; first user `events.export`, CR-R2-4) · `store_unavailable` (a component's
  durable store cannot be read or written; first user `build_queue`, MP-E1-C3-T08) ·
  `writes_paused` (with `degraded`: reads work, writes are held, e.g. a GitHub budget
  hold; first user `build_queue`) · `spec_invalid` (a vendored build-time spec failed its
  checksum or schema; first user `listener_modes`, RC-36) ·
  `dependency_unavailable` (with `depends_on: [ids]`) · `unknown`. A disabled capability
  is always reported as `unavailable/disabled`, never left out (a missing ID reads as
  `unknown`, §3). A capability whose
  instance has no `instance_id` reports `dependency_unavailable` with
  `depends_on: ["identity"]`; there is no separate `identity_degraded` reason. A provider that cannot
  classify a cause, or exceeds its time budget, reports `unknown`, never a specific cause
  (AGENTS.md "a collapsed cause names the collapse at the source").
- `version` per capability is that capability's own wire version. Absent = 1.
- **Registered attributes** (Phase D). An entry may carry extra keys only when the
  capability matrix registers them: `route` (the dashboard path of the capability's page,
  e.g. `"executor.conversation": {"state": "available", "route": "/executor"}`, CR-N3-1, so
  clients never hard-code a route) and `mode` (for `harness.<id>.native_question`: one of
  `in_band_hold`, `defer_resume`, `none`, CR-E2-6). Clients ignore unregistered keys.
- `repository` and `executor` are top-level sections contributed by providers (§2.4).
  Each is `null` when its provider is absent or failed; a client renders `null` as
  unknown, never as empty.
- **Remote scope.** A capability describes what a remote client of this instance's API can
  do. Local CLI verbs keep their own gates. With `--no-dashboard`, `api.http` is
  `unavailable/not_installed` and every capability that needs it reports
  `dependency_unavailable` with `depends_on: ["api.http"]`.
- No secret, path, token, port, hostname (other than the operator-visible
  `machine_label`) or credential appears. `not_configured` reveals only that a key is
  missing, to an already-authorized client.

### 2.3 Capability IDs (v1)

[capability-matrix.md §2](../bucket-1-refactor/MP-R1/capability-matrix.md) is normative.
Phase C added `identity` and `api.http`. Features that add capabilities register new IDs
in that table through their plans (for example `build_queue` from MP-E1, `events.export`
from MP-R2, `pairing` from MP-N2). Naming: `<area>[.<sub>]`, lowercase, dot-separated;
never reuse a retired ID. `packages/aiur-contracts` (MP-R1-C3-T06) carries the ID enum.

Registered in Phase D from the contract requests (rows added to the matrix):
`harness.<id>.native_question` (MP-R7 provider, value in `mode`, read by MP-E2-C4-T05 and
C5-T02), `executor.background_agents` (MP-E3-C4-T02, read function
`Aiur.Executor.BackgroundAgents.snapshot/0`; consumed by MP-N3-C1-T05) and
`runtime.crypto` (MP-N4: OTP `:crypto` has the X25519/Ed25519/HPKE primitives). `push`
is reported in every run shape that has the event bus, including `--no-dashboard`, and
uses `dependency_unavailable` with `depends_on: ["pairing"]` or `["runtime.crypto"]`
(CR-N4-4). `build_queue` and `build_orders` are separate IDs; a client masks an option
with `not_installed` plus `depends_on`, and maps that to its own option-level reason
(CR-N5-5). Build-order progress (`build_orders.progress`, `Aiur.BuildProgress`) belongs
to the `build-orders` component, so it never depends on `build_queue` (RC-40).

Providers that Phase D added (X-21), each with its own ticket:

| ID | Provider (component) | Ticket | State mapping |
|---|---|---|---|
| `build_queue` | build-queue | MP-E1-C3-T08 | queue status `running` → `available`; `disabled` → `unavailable/disabled`; `unsupported_tracker` → `unavailable/unsupported_tracker`; `store_unavailable` → `unavailable/store_unavailable`; `writes_paused` → `degraded/writes_paused` |
| `build_queue.build_order_source` | build-queue | MP-E1-C3-T08 | `available` when the BuildOrder dependency source is selected; else `unavailable/dependency_unavailable` with `depends_on: ["build_orders"]`, or `["build_queue"]` when the queue itself is not available |
| `listener_modes` | listener-modes (required core, RC-36) | MP-E7-C3-T06 | spec valid and routing flag on → `available`; flag `:listener_send_routing` = `:legacy` → `unavailable/disabled`; vendored spec absent → `unavailable/not_installed`; checksum or schema failure → `unavailable/spec_invalid`. Sends work in every case (`:legacy` routing) |

### 2.4 How the daemon computes it

- **Providers.** A component contributes through a provider module implementing the
  PROPOSED behaviour `Aiur.Capabilities.Provider`:

  ```elixir
  @callback capability_ids() :: [String.t()]
  @callback capabilities(context :: map()) :: %{String.t() => entry()}
  @callback sections(context :: map()) :: %{optional(:repository | :executor) => map() | nil}
  @optional_callbacks sections: 1
  ```

  `context` carries the run-shape flags (`Application.get_env(:aiur, :no_dashboard |
  :headless | :interactive_cli | :executor_mode)`, read the same way `aiur.ex:67-82`
  reads them) and the loaded settings. Providers are listed in application config
  (`config :aiur, :capability_providers, [...]` in `src/config/config.exs`), the
  composition root. The registry module itself references no provider, so the
  `identity` component (L1) has no upward dependency.
- **Known IDs.** `capability_ids/0` of every configured provider, plus a static table of
  IDs whose component is not compiled in or not configured; an ID in that table with no
  provider reports `unavailable/not_installed`. An unknown ID is simply absent.
- **Computation.** A monitor process (PROPOSED `Aiur.Capabilities.Monitor`) recomputes
  every 2,000 ms and on demand. Each provider runs in a `Task` with a 500 ms budget; a
  timeout, raise or exit makes all of that provider's IDs `unknown/unknown` and its
  sections `null`. When the capability map's digest changes, `revision` is incremented
  and `system.capabilities.changed` is published.
- **Storage.** The latest report and the `revision` counter live in a public ETS table
  owned by a process that cannot crash (PROPOSED `Aiur.Capabilities.Table`, the
  `Aiur.Webhooks.ModeTable` pattern, `aiur.ex:276-296`), so a monitor restart never
  moves `revision` backwards. Readers (HTTP, CLI) read the table and never call a
  GenServer. If no report exists yet (first seconds of boot), the reader computes one
  synchronously with `revision: 0`.
- **No orchestrator mailbox.** The orchestration provider reads `Process.whereis/1` and
  `Orchestrator.SnapshotStore.read/3`, which reads `:persistent_term`
  (`snapshot_store.ex:213-232,351`), the same source `Presenter.state_payload/3` uses
  (`presenter.ex:24-33`).

### 2.5 Typed "capability unavailable" error (RC-04, C-A7)

Every write endpoint that refuses because a capability is not available returns HTTP 409
(503 when the cause is `not_running`) with:

```json
{"error": "capability_unavailable", "capability": "commands.answer",
 "state": "degraded", "reason": "dependency_unavailable", "depends_on": ["orchestration"],
 "revision": 7, "boot_id": "…"}
```

MP-R1-C3-T03 ships the encoder (PROPOSED `AiurWeb.CapabilityError.render/2`). Existing
endpoints keep their current responses until their owning feature adopts it (MP-E2,
MP-E4, MP-N2 and MP-N6 tickets); this contract does not change them retroactively.

## 3. Client rules

1. **Detect, do not infer.** Clients read the report. A missing JSON field, an HTTP 404
   or a channel join error is an error path, not detection (baseline R1).
2. **Unknown IDs are ignored.** Unknown `reason` values are treated as `unknown`.
3. **Absent ID.** If `contract_version` is lower than the version that introduced an ID,
   the client shows `needs_update` with target `server` ("Update aiur on <machine>"), not
   `unavailable` (client-capability-model §4 rule 4). An ID missing from a report whose
   `contract_version` is new enough is `unknown`.
4. **Reachability is separate.** `unreachable` (no response), `stale` (`freshness: stale`
   or a cache older than the client's budget) and `unavailable` (answered, off) are three
   presentations (brief N3; `client-capability-model.md` §3).
5. **Refresh.** Refetch on `system.capabilities.changed`, on reconnect, on a new
   `boot_id`, and before a write whose capability might have changed.
6. **Writes are re-checked server-side.** The report is advisory; every write endpoint
   enforces its own gate (`:require_writable`, supervisor token, pairing scope) and uses
   §2.5 when the refusal is a capability.
7. **Minimum versions.** A client below its `min_client_versions` entry shows
   `needs_update` and blocks writes.

## 4. Non-happy paths

| Case | Behaviour |
|---|---|
| Daemon up, orchestrator crashed | `orchestration: unavailable/not_running`; `agents.run`, `agents.message`: `dependency_unavailable`; `commands.answer: degraded/dependency_unavailable` (answers recorded, not delivered) |
| `identity.json` unreadable, invalid JSON, or invalid `machine_id` | No silent regeneration (it would orphan pairings). `machine` is `null`, `instance.instance_id` is `null`, `identity: degraded/identity_unreadable`; one attention `system.identity.unreadable` per boot; local use continues; reset is explicit |
| Identity directory not creatable (read-only home) | Same as unreadable; boot continues |
| Two daemons create the identity at once | `File.ln/2` no-clobber: one file wins; both report the same `machine_id` |
| Two instances, same repository, different roots | Two `instance_id`s, same `repository` |
| Clock skew between machine and phone | `age_ms` is daemon-computed |
| Daemon restart | New `boot_id`, `revision` restarts at 0 or 1; clients treat the old cache as stale |
| Monitor crash | Table keeps the last report and counter; `age_ms` grows; after 6 s `freshness: stale` |
| Provider hangs or raises | Its IDs `unknown/unknown`, sections `null`; other providers unaffected |
| Capability flaps | Each change bumps `revision`; clients debounce rendering; the report is not debounced |
| `--no-dashboard` | No HTTP; CLI report shows `api.http: unavailable/not_installed` |
| No daemon running | `aiur capabilities` fails with the engine's standard control-RPC diagnostic; there is no offline report |

## 5. Ownership and assumptions about other contracts

- **Reconciliation applied:** RC-01 (first boot, path), RC-02 (`instance_id`), RC-04
  (ownership and MP-N1 additions), RC-11 (build-queue registers `build_queue` once
  MP-R1-C3-T01 exists; until then E1 ships its own scan test), RC-12 (classification).
  RC-ID-3: MP-R2 advertises `events.export` with `{v, retention}` — adopted.
- **MP-R2 (events)** owns event IDs, ordering, replay, the topic catalog and the external
  subscription API. Requested: catalog entry `system.capabilities.changed` (producer
  MP-R1-C3-T05) and envelopes carrying `instance_id`.
- **MP-N2 (pairing)** owns `machine_key`, devices, credentials, scopes, revocation, the
  reset verb, label editing and the extended instance record. It reads `identity.json`
  as defined in §1.1 and is the only rewriter of it (label and reset only). Assumed: a paired-device credential
  is accepted on `GET /api/v1/capabilities` with full-machine scope (D19).
- **MP-N1** owns the client side (`client-capability-model.md`); C-A5, C-A6 and C-A7 are
  answered by §2.2 and §2.5.
- **MP-E2** owns Command identity and which `SessionRef` an answer targets.
- **MP-E3** owns `executor.harness` and `executor.session_ref`.
- **MP-E4** owns `SessionRef`, conversation positions and anchors.
- **MP-N4** owns what a push carries; relay-visible fields use `machine_id`/`instance_id`
  only.
- **MP-R7** owns per-harness capability callbacks; they surface as `harness.<id>` IDs
  through a provider.
- **MP-E1** registers `build_queue` and `build_queue.build_order_source` through a provider
  (MP-E1-C3-T08, §2.3 table).
- **MP-E7** registers `listener_modes` through a provider (MP-E7-C3-T06). The send router
  is required core; only the shared spec package is optional (RC-36).
- **MP-E2** uses the live-Executor rule of §1.4 (RC-37); the command contract §4 states the
  same rule.
