# Contract requests from MP-R1 chunks C1–C5

Written by the C1–C5 ticket researcher on 2026-10-06 (base `45a290e3`). MP-R1 owns
`contracts/identity-and-capabilities.md`, and this researcher updated it directly
(RC-01, RC-02, RC-04, RC-11, RC-12, plus CR-C6-1 from the C6–C11 researcher). The items
below are requests to the owners of **other** contracts. Nothing in those contracts was
edited.

## CR-R1-1 — Events catalog: `system.capabilities.changed` (owner MP-R2)

- **Contract:** `contracts/events-and-replay.md` (topic catalog, MP-R2-C5; RC-08 list).
- **Request:** register `system.capabilities.changed`, producer MP-R1-C3-T05, payload
  `{"revision": int, "boot_id": string}` only, published once per revision change. It
  must stay **unbound** from the Executor wake stream (no `system.#` binding exists today,
  `executor_bindings.ex:7-35`). Export it through the external API (MP-R2-C7) when
  `events.export` is on.
- **Also:** envelope `instance_id` comes from `Aiur.Identity.instance_id/0`
  (MP-R1-C2-T02), which is `nil` when identity is degraded — the envelope must allow null.
- **Answer to MP-R2 RQ-3:** the journal primitive lives in `kernel` as `Aiur.Journal`
  (MP-R1-C5-T01, a rename of `Aiur.DecisionLog` after U6). MP-R2-C3-T01 builds on it.

## CR-R1-2 — Pairing: `instance_id` and who creates `identity.json` (owner MP-N2)

- **Contract:** `contracts/pairing-and-instance-registry.md` §1, §5.
- **Request:**
  1. Replace `instance_ref` with `instance_id` everywhere (RC-02).
  2. §1 `machine_id` row: "made once **at first daemon boot** by MP-R1
     (`Aiur.Identity.Machine.ensure/1`); `aiur mobile enable` reads it and never creates a
     second identity" (RC-01).
  3. §5 store table: `identity.json` initial fields are
     `schema_version, machine_id, machine_label, created_at`; MP-N2 adds
     `machine_key_public`. The gateway is the only **rewriter**; MP-R1 only creates the
     file, with a no-clobber hard link (`File.ln/2` returns `:eexist` if present).
  4. Directory resolution: `$AIUR_BG_STATE_DIR/machine`, else
     `${XDG_CONFIG_HOME:-~/.config}/aiur/machine` (same precedence as
     `upgrade/state.ex:35-40`; the agent-IR sandbox sets its own `AIUR_BG_STATE_DIR`).
  5. Reset (`aiur mobile reset`) stays MP-N2's; a corrupt file is never regenerated
     silently (identity contract §4).

## CR-R1-3 — Client capability model: resolved assumptions (owner MP-N1)

- **Contract:** `contracts/client-capability-model.md` §1.
- **Request:** mark C-A5, C-A6, C-A7 resolved:
  - C-A5: `boot_id` = `Aiur.Boot.run_id/0`; `revision` is in memory and only increases
    within one `boot_id`; cache key `(machine_id, instance_id, boot_id, revision)`.
  - C-A6: top-level `min_client_versions` map with keys `phone`, `watch`, `streamdeck`;
    empty map = no minimum.
  - C-A7: error body as proposed plus `depends_on`, `revision`, `boot_id`; HTTP 409, or
    503 when the reason is `not_running`. Existing endpoints adopt it per feature.
  - Add `run_shape.http_listener` and `run_shape.dashboard_pages` (CR-C6-1); `dashboard`
    is a deprecated alias.
  - Add `identity` and `api.http` to the IDs a client may need (for example "the
    instance has no API": `api.http unavailable/not_installed`).

## CR-R1-4 — Commands: session identity and refusal shape (owner MP-E2)

- **Contract:** `contracts/command-request-and-resolution.md` (`requester` row, line 41).
- **Request:** `requester.session_ref` is MP-E4's `SessionRef`
  (`{conversation_id, session_seq}`); the identity contract no longer defines a session
  string (identity §1.5). When the answer endpoint refuses because a capability is off,
  use the `capability_unavailable` body (identity §2.5; encoder
  `AiurWeb.CapabilityError.render/2`, MP-R1-C3-T03). `commands.answer` is `degraded`
  (recorded, not delivered) when orchestration is down (MP-R1-C3-T02).

## CR-R1-5 — Conversations: `SessionRef` is canonical (owner MP-E4)

- **Contract:** `contracts/conversations-transcripts-anchors.md` §2.
- **Request:** state that `SessionRef` is the single session identity for all contracts
  (identity, Commands, notifications) and that `conversation_id` derives from
  `instance_id` as defined in identity §1.2.

## CR-R1-6 — Build queue: capability and attention through R1 seams (owner MP-E1)

- **Contract:** `contracts/queue-readiness-and-build-progress.md` (and MP-E1 plan X-1).
- **Request:** register `build_queue` / `build_queue.build_order_source` through an
  `Aiur.Capabilities.Provider` module once MP-R1-C3-T01 exists; the single attention
  function calls `Aiur.Signal.alert/2` once MP-R1-C5-T03 exists; keep the names
  `Aiur.BuildQueue.Hints` and `Aiur.BuildQueue.ClaimProbe` (MP-R1-C1-T06 writes them into
  manifest `seams`) or tell MP-R1 the merged names.

## CR-R1-7 — Harness adapters: config-layer backend-catalog edges (owner MP-R7)

- **Contract:** `contracts/harness-adapter.md`.
- **Request:** take ownership of the remaining config→harness edges that MP-R1-C4-T03
  deliberately leaves allowlisted: `Aiur.Config → Aiur.CodingAgent` (`config.ex:319,396,
  495,1405-1413`) and `Config.Schema.AgentValidation`/`Schema.Codex → Aiur.CodingAgent`
  (`agent_validation.ex:78,132`, `agent.ex:120`). Registered adapter data (the catalog
  in `CodingAgent.Registry.entries/0`) can feed config validation through the
  `Aiur.Config.SemanticCheck` registry from MP-R1-C4-T01. Per-harness capabilities
  surface as `harness.<id>` IDs through `Aiur.Capabilities.Provider`.
