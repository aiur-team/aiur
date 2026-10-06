# Contract requests — Phase D resolution

Written by the Phase D coordinator on 2026-10-06 (pack base `45a290e3`). Every request in
the 22 `bucket-*/MP-*/tickets/CONTRACT-REQUESTS*.md` files has one row here. Decisions
follow D1–D20 ([context-and-decisions.md](../context-and-decisions.md)) and RC-01..RC-27
([phase-b-reconciliation.md](phase-b-reconciliation.md)); none of them is reopened.

- **Decision:** `accept` (applied as asked), `modify` (applied in a changed form; the reason
  is in the row), `reject` (not applied; reason given), `owner` (a product call, written as
  an explicit question in the named `DESIGN-*` task), `done` (the contract owner had
  already applied it; verified, no further edit), `noted` (information only).
- **Where:** the file(s) changed. `c/` = `contracts/`, `od/` = `owner-design-tasks/`,
  `R1/…` = `bucket-1-refactor/MP-R1/…`, `E1/…` = `bucket-2-platform/MP-E1/…`,
  `N2/…` = `bucket-3-mobile-watch/MP-N2/…`, and so on; `t/` = that feature's `tickets/`.

Counts: **accept 90 · modify 18 · reject 2 · owner 11 · done 37 · noted 3** (161 rows).

## Conflicts decided here

| Conflict | Decision and reason |
|---|---|
| CR-R1-2 (N2 adds `machine_key_public` to `identity.json`; gateway rewrites it) vs pairing §5 ("MP-N2 never writes it") | **Modify.** The gateway is the only rewriter, and only for `machine_label` and reset. The public key stays in `machine_key.pub`, so there is one copy. Both contracts now say the same. |
| CR-R1-5 (`conversation_id` derives from `instance_id`) vs conversations §3 Phase C (it does not) | **Modify.** `SessionRef` is canonical (accepted); the derivation part is rejected, because E4 owns it and removed the hash in Phase C (RC-02). Identity §1.5 now matches. |
| CR-R1-7 (R7 owns config → `Aiur.CodingAgent`) vs CR-R7-5 (R1-C4 owns config → harness references) | **Both accepted; they are different edges.** Private-namespace calls (`config.ex:1305,1340`) belong to MP-R1-C4-T03/T01. The facade/catalog edges (`config.ex:319,396,1405-1413`, schema validators) go to the new **MP-R7-C3-T06**. |
| E5 R-2 (`assigns.aiur_device_id`) vs CR-N5-1 / CR-N6-1 (`assigns.device_id`) | **`device_id`.** Two consumers and the gateway plug (MP-N2-C4-T03) already use it. |
| E6 R-1 (`opts[:origin]` = `:operator`/`:voice_assistant`) vs MP-E7-C3-T03 (`origin` = entry point `:agent_chat`/`:http`/`:tui`/`:internal`) | **One `origin` key.** `:voice_assistant` joins the entry-point set; the conversation entry shows `voice_assistant` or `operator`. Two keys with one name would collide. |
| E5 R-1 (`{:voice_error, %{code, message}}`) vs CR-R5-1 (reason stays a string) | **E5's form.** `message` keeps today's string, so nothing visible changes. The adapter already knows the class (`realtime.ex:402-409`), so mapping codes from text would be the brittle path. |
| B4 (`aiur.destination`) vs N7 item 3 (`aiur_dest`) vs MP-N4-C4-T03 (`aiur_destination`); category `aiur.command` vs `AIUR_COMMAND` | **`aiur.destination` (full §3.1 destination) and `aiur.command`.** N4 owns presentation, and its category scheme covers every kind. |
| N2 coordinator item 4 (`PushDeregistrar` returns `:ok`, `{:retry, _}`, `{:gone}`) vs MP-N4-C3-T05 (`:ok`, `{:pending, _}`) | **`Aiur.Machine.PushDeregistrar` (N2 behaviour) → `:ok` or `{:retry, reason}`**, implemented by `Aiur.Push.Deregister`. A relay `404` is `:ok`, so `{:gone}` is not needed. |
| N7 item 4 (Wear app posts Command notifications; bridging excluded) vs MP-N4-C6-T02 ("keep Command notifications bridged") | **N7's design.** The Wear app's own notification opens the Command card; a bridged one cannot. |
| N7 item 2 (watch card screens) vs MP-N6-C5-T01 (watch card ticket) | **Split.** N6-C5-T01 becomes rules and fixtures; MP-N7-C2-T03/C3-T03 build the screens and now depend on it. |

Not resolvable in Phase D: the possible defect `agent_control_cli.ex:2808` and the Executor
items that require a GitHub write. Phase D may not write to GitHub, so they stay listed as
`noted`.

## Bucket 1 — refactor

| Source | ID | Decision | Where applied / owner question |
|---|---|---|---|
| R1 C1–C5 | CR-R1-1 (catalog `system.capabilities.changed`) | accept | c/events §9 row: live, exported (`revision`, `boot_id`), never bound to the Executor wake stream |
| R1 C1–C5 | CR-R1-1 (envelope `instance_id` may be null) | reject | The exporter refuses to start without an `instance_id`, and the internal envelope has no instance field, so no null exists (c/events §3) |
| R1 C1–C5 | CR-R1-1 (RQ-3: journal in kernel) | done | R2/t/MP-R2-C3-T01 already wraps the kernel journal and does not wait for R1-C5-T01 |
| R1 C1–C5 | CR-R1-2.1 (`instance_ref` → `instance_id`) | accept | Contracts were done; R2/t/MP-R2-C5-T04, C6-T02, C6-T03 renamed `InstanceRef` → `Aiur.Events.InstanceId` |
| R1 C1–C5 | CR-R1-2.2 (`machine_id` at first boot) | done | c/pairing §1 (RC-01) |
| R1 C1–C5 | CR-R1-2.3 (`identity.json` fields; gateway rewriter) | modify | c/identity §1.1 and §5; c/pairing §5 (see conflicts) |
| R1 C1–C5 | CR-R1-2.4 (directory resolution) | accept | c/pairing §5 |
| R1 C1–C5 | CR-R1-2.5 (reset stays N2's; no silent regeneration) | accept | c/pairing §5 `identity.json` row |
| R1 C1–C5 | CR-R1-3 (C-A5..C-A7 resolved; `run_shape`; `identity`, `api.http`) | accept | c/client-capability-model §1 (rows C-A5..C-A8) |
| R1 C1–C5 | CR-R1-4 (`session_ref` = `SessionRef`; `capability_unavailable`; `degraded`) | accept | c/command §2 `requester` row; §6 rule 9 |
| R1 C1–C5 | CR-R1-5 (`SessionRef` canonical; derivation) | modify | c/conversations §3; c/identity §1.5 (see conflicts) |
| R1 C1–C5 | CR-R1-6 (Provider, `Signal.alert/2`, seam names) | accept | c/queue-readiness §8; stale `Signal.emit/2` corrected to `Signal.alert/2` in R1 tickets C7-T03, C7-T05, C7-T06, C8-T09, C9-T05, the component map, the migration plan and E1 (plan, C5-T01) |
| R1 C1–C5 | CR-R1-7 (config → `Aiur.CodingAgent` edges to R7) | accept | **New** R7/t/MP-R7-C3-T06; R7/t/C3-T05 row 14; R7/t/README; R1/t/MP-R1-C4-T03 |
| R1 C6–C11 | CR-C6-1 (`run_shape.http_listener`, `dashboard_pages`) | done | c/identity §2.2 (applied by MP-R1 part A) |
| R1 C6–C11 | CR-C8-1 (writer layer; read-facade name) | modify | c/conversations §6 already layered it; facade renamed `Aiur.Conversation.History` in R1/t/MP-R1-C8-T06 (+ README-C6-C11, plan, component map) |
| R1 C6–C11 | CR-C8-2 (`ObservabilityPubSub` internal) | modify | c/events §2 R-6: internal invalidation, never exported; owner is the signal component (RC-24), not `event-bus` (R-5); #3009 fixed or deferred first |
| R1 C6–C11 | CR-C8-3 (synchronous delivery; `commands` required) | accept | c/command §7 intro; R1/component-map §3 notes; R1/plan.md contract row. RQ-C8-1 is closed: a required component has no "not installed" shape |
| R2 | CR-R2-1 (component assignments) | accept | R1/component-map §3 "Phase D assignments"; R1/t/MP-R1-C1-T01; R2/t/MP-R2-C2-T11 (gate removed) |
| R2 | CR-R2-2 (`TrackerIdentity` edge) | accept | Value types reassigned to `kernel`, so no upward edge remains (R1/component-map §3) |
| R2 | CR-R2-3 (alert-name topics) | accept | No rename; c/events §9 already records it. A rename needs its own owner approval |
| R2 | CR-R2-4 (`identity_degraded`, `journal_corrupt`) | modify | `journal_corrupt` added to c/identity §2.2. `identity_degraded` maps to `dependency_unavailable` + `depends_on: ["identity"]`; c/events §3; R2/t/MP-R2-C7-T03 |
| R2 | CR-R2-5 (`devices:revoked` broadcast) | accept | c/pairing §4.4; N2/t/MP-N2-C7-T01, C7-T02; R2/t/MP-R2-C7-T05 deps made ticket-level |
| R2 | CR-R2-6 (E-A3 producer is MP-E1) | accept | c/queue-readiness §4.3 and E-A3 (RC-26) |
| R3 | CR-R3-1 (§ Transport copy) | accept | od/DESIGN-R3 §3, with the same approval box |
| R3 | CR-R3-2 (`blocks:`) | accept | od/DESIGN-R3 frontmatter (all gates regenerated; see the end) |
| R4 | CR-R4-1 (bracket: "and body") | accept | od/DESIGN-R4 §3 (factual correction, evidence cited) |
| R4 | CR-R4-2 (`blocks:`) | accept | od/DESIGN-R4 frontmatter |
| R4 | CR-R4-3 (consumer-equivalence test survives the bus move) | done | R2/t/MP-R2-C2-T04 already runs it |
| R5 | CR-R5-1 (voice-session §4 names) | accept | c/voice-session §4 (`Synthesizer`, `{:voice_audio, …}`, `Aiur.Voice.Provider`); E5/t/MP-E5-C3-T03; header note |
| R5 | CR-R5-2 (`blocks:`; hidden vs disabled consequence) | accept | od/DESIGN-R5 §2 and frontmatter |
| R5 | CR-R5-3 (sidecar TTS "removed" note) | accept | c/voice-session §4 note (conditional on DESIGN-R5 §3.2) |
| R5 | CR-R5-4 (R1 reads `Voice.availability/0`; child specs; RQ-R5-PKG) | accept | R1/t/MP-R1-C3-T07; R1/migration-plan §5 "Physical form" answers RQ-R5-PKG; R5/t/MP-R5-C3-T01 gate removed |
| R6 | CR-R6-1 (E4-C3 depends on R6-C1-T01) | done | E4/t/MP-E4-C3-T01 already; E4/chunks C3 and C7 text updated |
| R6 | CR-R6-2 (module name `Aiur.Conversation.Anchors`) | accept | c/conversations §10 confirms; R1/t/MP-R1-C8-T06 reference fixed |
| R6 | CR-R6-3 (badge vocabulary) | noted | No contract change requested |
| R7 | CR-R7-1 (physical form of an Elixir component) | accept | R1/migration-plan §5: in-repo Mix path dependency under `packages/elixir/<app>/`, no umbrella; R7/t/C4-T03, C4-T05 gates removed |
| R7 | CR-R7-2 (whole `RemoteControl` helper set) | done | R1/t/MP-R1-C5-T02 already moves the whole block |
| R7 | CR-R7-3 (owner for accounting files) | modify | No accounting ticket exists; owner set to MP-R1-C11-T03, which must cut it before wave 2 (R7/t/C3-T05 row 10) |
| R7 | CR-R7-4 (stale rows, comments, `private_namespaces`) | accept | Stale rows (R1-C1-T05) and comments/`@doc` (R1-C1-T02) existed; `private_namespaces` added to R1/t/MP-R1-C1-T01 |
| R7 | CR-R7-5 (R1-C4 owns config validator references) | accept | R7/t/C3-T05 row 7 owners: MP-R1-C4-T03, C4-T01 |
| R7 | CR-R7-6 (R1-C6-T01 owns `claude-hook` reference) | accept | R1/t/MP-R1-C6-T01 |
| R7 | CR-R7-7 (listener §9 cells) | done | c/listener-mode §9 already says it |
| R7 | Possible defect: `agent_control_cli.ex:2808` humanizer | noted | Needs a GitHub issue; Phase D makes no GitHub writes. The allowlist row stays |
| R7 | Finding R7-C1-F1 (delivery flags) | done | E7/t/MP-E7-C2-T04 already owns it |

## Bucket 2 — platform

| Source | ID | Decision | Where applied / owner question |
|---|---|---|---|
| E1 | CR-1 (exact topics; producer MP-E1-C7) | accept | c/events §9 table (queue verbs, attention causes, progress milestones) |
| E1 | CR-2 (queue needs neither event) | modify | c/events §9 and §12: queue reads never depend on the events. RC-26 still makes E1-C4-T05 the producer of `pr.closed_unmerged`; `issue.closed` stays registered with no v1 producer |
| E1 | CR-3 (five tracker callbacks in the component map) | accept | R1/component-map §3 notes; c/queue-readiness §5 adds `ensure_labels/1` |
| E1 | CR-4 (`BuildProgress`, `ProgressObserver` placement) | accept | R1/component-map §3 notes |
| E1 | CR-5 (prior plan U2 wording) | reject | `docs/plans/…` is outside this pack; RC-20 already binds U2 ("a sanctioned caller of the writer seam") |
| E1 | RC-26 producer (task item) | accept | E1/t/MP-E1-C4-T05 (producer step, once-only test, docs line); E1/chunks X-2/X-3 resolved |
| E1 | plan.md over 500 lines (task item) | accept | §11 moved to E1/plan-phase-c-changes.md, linked from plan.md (454 lines) |
| E2 | CR-E2-1 (`:defer_resume` meaning) | accept | c/harness-adapter §6 item 5 |
| E2 | CR-E2-2 (`claude-repl` `:none`; RQ-E2-1) | accept | c/harness-adapter §6 item 5 |
| E2 | CR-E2-3 (register decision topics and slugs) | accept | c/events §9 rows (human-needed, slugs, `executor.decision.answered`) |
| E2 | CR-E2-4 a (cause list) | accept | od/DESIGN-E2 §4.3 |
| E2 | CR-E2-4 b (`decisions.escalation.*`) | accept | od/DESIGN-E2 §6.1 |
| E2 | CR-E2-4 c (`aiur executor-ack` row) | accept | od/DESIGN-E2 §3 |
| E2 | CR-E2-4 d (may backend tickets start before approval?) | owner | od/DESIGN-E2 §6 decision 9 |
| E2 | CR-E2-5 (`requester_kind`) | accept | c/notification §9 A-E2-1 |
| E2 | CR-E2-6 (`native_question.<harness>`, `executor_live`) | modify | Registered as `harness.<id>.native_question` with a `mode` attribute (per-harness IDs are `harness.<id>`, CR-R1-7). `executor_live` rejected as redundant: read `executor.state == active`. c/identity §1.4, §2.2, §2.3; R1/capability-matrix |
| E2 | CR-E2-7 (notice to prior U3 owner) | noted | Carried by E2/t/MP-E2-C6-T02; `docs/plans` is outside the pack |
| E2 | CR-E2-8 (`native_ref` items pass the listener router unchanged) | accept | c/listener-mode §2; E7/t/MP-E7-C3-T03 |
| E2 | CR-E2-9 (surfaces call `Commands.Answering`) | accept | N6/t/MP-N6-C1-T03 (design note, IDs); c/command §9 already says it |
| E2 | CR-E2-10 (free spikes C4-T00, C5-T00 run now) | accept | value-and-sequencing.md "Changes after Phase C"; od/DESIGN-E2 decision 10 (Codex flag) |
| E3 | CR-E3-1 (E3-C5 composer disabled until E7-C6) | done | RC-25; value-and-sequencing.md note |
| E3 | CR-E3-2 (hook generator takes extra entries) | done | E3/t/MP-E3-C1-T04 |
| E3 | CR-E3-3 (two-digit IDs) | done | E3 tickets |
| E3 | CR-E3-4 (hook token per instance, read through `HookToken`) | accept | c/listener-mode §8; E7/t/MP-E7-C6-T01; E3/chunks C1 |
| E3 | CR-E3-5 (daemon URL from the `hook-url` file at run time) | accept | c/listener-mode §8 |
| E3 | CR-E3-6 ("attached" profile definition) | accept | c/harness-adapter §6 item 8 |
| E3 | CR-E3-7 (`system.executor.transcript.drift`) | accept | c/events §9 row (ledgered) |
| E3 | CR-E3-8 (auto-install Claude hooks vs print-only) | owner | od/DESIGN-E3 §3 decision 9 |
| E4 | CR-E4-1 (`anchor` field shape) | accept | c/events §4.2 `{conversation_id, pos, placement, precision}`; c/conversations §14 |
| E4 | CR-E4-2 (`[aiur:delivery <id>]` in hook frames) | accept | c/listener-mode §8 "aiur specifics"; E7/t/MP-E7-C6-T04 |
| E4 | CR-E4-3 (`Aiur.Conversations` collision) | accept | R1/t/MP-R1-C8-T06 → `Aiur.Conversation.History`; R1 README-C6-C11, plan |
| E4 | CR-E4-4 (lift MP-E7-C3 from E4-C6-T02, E3-C6-T03) | accept | Consistent with listener-mode §2 (Command answers excluded) and command §7. E4/t/MP-E4-C6-T02 frontmatter and body; E4/t/README; E3/t/MP-E3-C6-T03 (its E7-C3 link was only through E4-C6-T02) |
| E4 | CR-E4-5 (`Anchors` name; C3-T01 recast) | done | c/conversations §10; E4/chunks updated |
| E4 | CR-E4-6 (identifier form of `Listener.send/3`) | done | E4/t/MP-E4-C6-T01 |
| E4 | CR-E4-7 (anchor backfill after R2-C6) | accept | c/events §12 MP-E4 row; c/conversations §14 |
| E4 | CR-E4-8 (no interim composer step) | accept | value-and-sequencing.md note; E4 plan and chunks were already updated |
| E4 | CR-E4-9 (retention disk figure) | accept | od/DESIGN-E4 decision 5 |
| E5 | R-1 (`voice_error` carries `%{code, message}`) | accept | c/voice-session §4; R5/t/MP-R5-C1-T01; E5/t/MP-E5-C2-T01 (see conflicts) |
| E5 | R-2 (`assigns.aiur_device_id`) | modify | `conn.assigns.device_id` (see conflicts); E5/t/MP-E5-C8-T01; N2/t/MP-N2-C6-T01 |
| E5 | R-3 (`Machine.Store.device_active?/1`) | accept | c/pairing §5; N2/t/MP-N2-C1-T03 |
| E5 | R-4 (capability IDs `voice.stt`, `voice.conversation`) | accept | Retired IDs replaced in E5/plan.md, E5/chunks.md, E6/plan.md |
| E5 | R-5 (four new strings) | owner | od/DESIGN-E5 §5 |
| E5 | R-6 (surface `command_revision`) | accept | c/voice-session §3.2 (the list did not contain it yet) |
| E6 | R-1 (`origin: :voice_assistant` on send) | modify | One `origin` key (see conflicts): c/listener-mode §7; c/conversations §5; E7/t/MP-E7-C3-T03; c/voice-session §11 |
| E6 | R-1/R-2 label for voice-originated entries | owner | od/DESIGN-E6 E6-OQ10 |
| E6 | R-2 (render with the approved label) | accept | c/conversations §5 `origin` field |
| E6 | R-3 (`actor.via: voice_assistant`) | accept | c/command §6; where it is shown is owner question od/DESIGN-E6 E6-OQ11 |
| E6 | R-4 (`voice.conversation` matrix row) | accept | R1/capability-matrix §2 |
| E6 | R-5 (voice-stt package starts E6 children) | modify | Rejected as asked: voice-conversation is its own optional component, so it declares its own `child_specs/0` (MP-R1-C8-T08 pattern). The fallback (application child list) is allowed until that exists. E6/t/MP-E6-C4-T01 |
| E7 | CR-E7-1 (`listen-mode.changed` attribution) | modify | Name kept (RC-08). The catalog gains `attribution: :payload_actor` (c/events §9); E7/t/MP-E7-C2-T05 |
| E7 | CR-E7-2 (E3-C5 wave) | done | RC-25 |
| E7 | CR-E7-3 (generator takes extra hooks) | done | Answered by CR-E3-2 |
| E7 | CR-E7-4 (E4 calls the identifier form) | done | Answered by CR-E4-6 |
| E7 | CR-E7-5 (two-digit E3 IDs) | done | Answered by CR-E3-3 |
| E7 | CR-E7-6 (queued messages are not durable) | accept | c/events §6 rule D-4 (c/listener-mode §5 already says it) |
| E7 | OWNER-NPM-FIRST-PUBLISH | owner | od/DESIGN-E7 §2 (E7/t/MP-E7-C1-T03 already gated on it) |
| E7 | E7-D5 blocks MP-E7-C2-T01 | owner | od/DESIGN-E7 E7-D5 now says so; the ticket's `blocked_by` already lists E7-D5 |

## Bucket 3 — mobile and watch

| Source | ID | Decision | Where applied / owner question |
|---|---|---|---|
| N1 | B1 (overlay endpoints by DNS name) | done | c/pairing §8.1 rule 2 |
| N1 | B2 (HTTP-degraded mode is Tailscale-specific on phones) | owner | od/DESIGN-N2 §transport (keep or remove the mode) |
| N1 | B3 (ticket ID for the device voice path) | accept | MP-E5-C8-T01/T02 exist. c/voice-session §3.5 item 6; placeholders replaced in N6/t/MP-N6-C4-T02, C4-T03 and N7/t/MP-N7-C4-T04, C4-T05 |
| N1 | B4 (token stays native; one destination key) | accept | c/notification §3.1 rules 5–6; N1/t/MP-N1-C6-T01 (JS gets an 8-character fingerprint only); N4/t/MP-N4-C4-T03 key renamed; N4/t/C4-T05 and C5-T05 deps canonical |
| N1 | B5 (N6-C2-T02 owns tap routing) | done | N1/t/MP-N1-C6-T01 non-goals already say so |
| N1 | B6 (OWNER-AUTH-N1-PROTO decision line) | owner | od/DESIGN-N1 §2 table row |
| N1 | B7 (`insecure_context`, `tls_websocket_untrusted`) | done | c/client-capability-model §5 |
| N1 | A1 (signed bytes) | done | c/pairing §4.0 |
| N1 | A2 (per-instance cookie) | done | c/pairing §4.4 |
| N1 | A3 (JSON Schemas for InstanceEntry, InstanceSummary, Commands) | accept | Owners publish under `packages/aiur-contracts/schemas/`: N2/t/MP-N2-C4-T04, N3/t/MP-N3-C1-T01, E2/t/MP-E2-C1-T04; N1/t/MP-N1-C2-T04 path fixed (`schemas/`) |
| N1 | A4 (`boot_id` in R1-C3-T05) | done | `boot_id` = `Aiur.Boot.run_id/0` in the report (R1-C3-T02) and the change event (R1-C3-T05); c/identity §2.2 |
| N2 | Coordinator 1 (DESIGN-N2 §transport, T-A vs T-B) | owner | od/DESIGN-N2 §transport (recommendation T-A, overlay off) |
| N2 | Coordinator 2 (R3 guards cover N2 routes and listener) | modify | R3 ships in wave 1, before N2 exists, so each N2 ticket extends the R3 census in its own PR: R3/t/MP-R3-C1-T01; N2/t/MP-N2-C6-T02, C10-T01 (C6-T01 already did). The § Transport link to the pairing guide is added by N2/t/MP-N2-C9-T01 |
| N2 | Coordinator 3 (QR hidden from device sessions) | owner | od/DESIGN-N2 Q5 |
| N2 | Coordinator 4 (`PushDeregistrar` implemented by N4) | modify | One interface (see conflicts): N2/t/MP-N2-C7-T03; N4/t/MP-N4-C3-T05 |
| N2 | Coordinator 5 (MP-N1 ID corrections) | done | Corrected by the parent in Phase C |
| N2 | Coordinator 6 (C5-T06, C7-T04 in chunks) | done | N2/chunks.md "Phase C final tickets" |
| N2 | CR-N2-2 (lockout journal entry) | done | c/pairing §4.1 |
| N2 | CR-N2-4 (WebView bootstrap) | done | c/pairing §4.4 |
| N2 | CR-N2-5 (nonce use) | done | c/pairing §4.2 |
| N2 | CR-N2-6 (relink body) | done | c/pairing §4.3 |
| N2 | CR-N2-7 (no floats) | done | c/pairing §4.1 |
| N2 | CR-N2-8 (bearer skips Origin check) | done | c/pairing §4.4 |
| N2 | C1–C4 (advert, store files, signed responses, port 0) | done | c/pairing §4.0, §5, §6.1, §8 |
| N2 | Open: AGENTS.md "only one row is machine-checked" | modify | The pack does not edit AGENTS.md; N2/t/MP-N2-C3-T05 updates the sentence in its own PR (docs ship with the change) |
| N2 | Open: plan F3 omits the `AIUR_RECORD_` prefix | accept | N2/plan.md F3 |
| N3 | Applied 1–4 (`absent`, no titles, "needs you", reason list) | done | c/pairing §6.3, §7 |
| N3 | 1 (Executor `route` in the capability entry) | accept | c/identity §2.2 registered attributes; R1/capability-matrix; E3/t/MP-E3-C6-T01; c/client-capability-model §5 |
| N3 | 2 ("needs you" public read) | accept | `DecisionProvider.counts/1` field `needs_you`, always computed: E2/t/MP-E2-C7-T01; N3/t/MP-N3-C1-T03 |
| N3 | 3 (background-roster capability and read) | accept | `executor.background_agents` + `Aiur.Executor.BackgroundAgents.snapshot/0`: c/identity §2.3; R1/capability-matrix; E3/t/MP-E3-C4-T02; N3/t/MP-N3-C1-T05; c/client-capability-model §5 |
| N3 | 4 (`boot_id` field name) | done | c/identity §2.2 |
| N4 | CR-N4-1 (X25519 push key per install per machine) | accept | c/pairing §2 |
| N4 | CR-N4-2 (`Machine.Store.sign/1`) | accept | c/pairing §5; N2/t/MP-N2-C1-T03; N4/t/MP-N4-C3-T03 deps |
| N4 | CR-N4-3 (`PUT /v1/devices/self/push`) | accept | c/pairing §4.5; N2/t/MP-N2-C7-T01; N4/t/C4-T05, C5-T05 deps |
| N4 | CR-N4-4 (`push` dependencies; every run shape) | accept | c/identity §2.3; R1/capability-matrix (`runtime.crypto` row) |
| N4 | CR-N4-5 (`push:` section in `~/.aiur/machine`) | accept | c/pairing §8 |
| N4 | CR-N4-6 (N1 native open, split, minimum OS) | modify | Decryption belongs to MP-N4 (N4-C4-T02, C5-T02), not to the N1 core (N1-C6-T01 non-goals), so (a) applies to N4's own tickets. The (b) split is already recorded. (c) iOS 17 and watchOS 10 are already set (N1-C1-T01, N7-C2-T01) |
| N4 | Note: RC-01 vs pairing §1 | done | c/pairing §1 says first daemon boot |
| N5 | CR-N5-1 (`:device_auth` pipeline; `assigns.device_id`) | accept | c/pairing §4.4; N2/t/MP-N2-C6-T01; N5/t/MP-N5-C1-T03 deps canonical |
| N5 | CR-N5-2 (preferences file; delete on revoke; gateway endpoints) | accept | c/pairing §4.5, §5; N2/t/MP-N2-C7-T01, C7-T02 |
| N5 | CR-N5-3 (`.agent.` spelling) | done | RC-08, c/command §8 and c/events §9 all use `ticket.<id>.agent.decision.human-needed`; no file in the pack spells it otherwise |
| N5 | CR-N5-4 (progress-changed signal) | modify | Signal kept as PubSub `build_progress` with the whole fact (no new payload shape). The fact gains `generation`; the signal fires on `generation` changes and on decreases: c/queue-readiness §4.0, §4.1 |
| N5 | CR-N5-5 (`build_queue` and `build_orders` both reported) | accept | c/identity §2.3 (mapping stays N5-side) |
| N6 | CR-N6-1 (pipeline; no `:api_write`; header + writable) | accept | c/pairing §4.4 (`:device_write`, owned by N2/t/MP-N2-C6-T03); N6/t/MP-N6-C1-T01 now uses it; E5/t/MP-E5-C8-T01 route |
| N6 | CR-N6-2 a (`client` from trusted opts) | accept | c/command §6 |
| N6 | CR-N6-2 b (`replaceable` in the conflict summary) | accept | c/command §6 rule 1 |
| N6 | CR-N6-2 c (store-level `supersede/3` for `:operator`) | accept | c/command §6 rule 3 |
| N6 | CR-N6-2 d (stale version → conflict) | accept | c/command §6 rule 8 |
| N6 | CR-N6-3 (4,000-character limit) | accept | c/command §3 |
| N6 | CR-N6-4 (anchor for a `decision_id`) | accept | c/conversations §7 `anchor_for_decision/1`; E4/t/MP-E4-C3-T02 decision index; N6/t/MP-N6-C1-T01 deps |
| N6 | CR-N6-5 (`command_response` on `/voice/device`; converse is a draft) | accept | c/voice-session §3.5 item 5 |
| N6 | CR-N6-6 (ticket the device voice path) | accept | Same as B3 |
| N7 | 1 (E5 ticket ID; `client.kind: "watch"`) | accept | c/voice-session §3.5 items 5–6; E5/t/MP-E5-C8-T01; N7/t/MP-N7-C4-T04, C4-T05 |
| N7 | 2 (watch card ownership) | accept | N6/t/MP-N6-C5-T01 (rules and fixtures); N7/t/MP-N7-C2-T03, C3-T03 depend on it |
| N7 | 3a (destination in `userInfo`; category) | modify | Key `aiur.destination`, category `aiur.command` (see conflicts): c/notification §3.1 rule 5; N7/t/MP-N7-C2-T04 |
| N7 | 3b (option labels and `version` for C2-T06) | owner | `command_version` added to the destination (harmless id). Option labels in the payload: od/DESIGN-N7 D-N7-9, od/DESIGN-N4 D-7 |
| N7 | 4 (Wear bridging tag and dismissal id) | accept | N4/t/MP-N4-C6-T02 (see conflicts) |
| N7 | 5 (device rows run once in N7-C6) | accept | N1/device-validation.md §3 note; N4/t/MP-N4-C7-T02 |
| N7 | 6 (`client.surface: "watch"` is attribution) | accept | c/command §6 |
| N7 | 7 (watch snapshot fields; `mic_dictate_system`) | done | c/client-capability-model §7 and N1/t/MP-N1-C3-T04 already list them |

## Gate `blocks:` lists

Every `owner-design-tasks/DESIGN-*.md` now lists the exact ticket IDs it blocks: the tickets
whose frontmatter `blocked_by` names that gate, read on 2026-10-06 after the edits above.
Entries marked "waived" (MP-E5 and MP-E6 backend tickets) are left out. The earlier wording
is kept in `blocks_note`. DESIGN-N2 and DESIGN-N3 have no frontmatter, so the list is a
**Blocks — final ticket IDs** bullet. A ticket whose `blocked_by` changes later must also
update the gate's list.

## Size limits

- `bucket-2-platform/MP-E1/plan.md` (504 lines): §11 moved to `plan-phase-c-changes.md`
  (454 + 67 lines).
- `contracts/pairing-and-instance-registry.md` reached 511 lines with the Phase D edits:
  §10 (history) moved to `pairing-and-instance-registry-reconciliation.md` (496 + 32).
- `cross-feature-reviews/contract-requests-resolution.md` (this file) is under 500 lines.
