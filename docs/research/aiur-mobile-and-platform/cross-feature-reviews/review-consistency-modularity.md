# Phase D cross-review: consistency and modularity

Independent reviewer, 2026-10-06. Read-only review of the pack at code base `45a290e3`.

**Scope:** `brief.md`, `context-and-decisions.md` (D1–D20), `feature-inventory.md`,
`value-and-sequencing.md`, `phase-b-reconciliation.md` (RC-01..RC-35),
`contract-requests-resolution.md`, all `contracts/*.md`, MP-R1 (`component-map.md`,
`capability-matrix.md`, `component-directory.md`, `migration-plan.md`), every feature
`plan.md`, and sampled tickets. I also read the prior plan
`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`.

**Excluded:** ticket-ID spelling (T1 → T01, RC-34) and `blocked_by` graph edges. Another
agent is changing both.

**Paths:** relative to the pack root. `B1/` is `bucket-1-refactor/`, `B2/` is
`bucket-2-platform/`, `B3/` is `bucket-3-mobile-watch/`, `c/` is `contracts/`. Every
finding was confirmed with grep.

**Severity:**

- **blocker:** two documents define the same contract differently, or a modularity
  rule is broken in a way the dependency checker (MP-R1-C1) would reject or would have
  to allowlist.
- **major:** a binding decision was not applied, a non-canonical wire name is
  published, or a component is a hidden dependency.
- **minor:** stale or redundant text that misleads but does not change a contract.

**Counts:** 5 blockers, 26 major, 30 minor (61 findings: X-01..X-61).

---

## 1. Blockers

### X-01 `listener-modes` is a hidden required dependency of the core send path

- `B1/MP-R1/component-map.md:122` classifies `listener-modes` as optional, with Req
  `harness-adapters` only. At `:107` the required `agent-runner` has an optional edge
  to it.
- MP-E7-C3-T03 (`B2/MP-E7/tickets/MP-E7-C3-T03.md:28-41`) changes the default of
  `AgentChat.send/3` to `delivery_policy: :listener`. `AgentChat` is in
  `orchestration`, which is required. The TUI and HTTP send paths change the same way.
  `Aiur.Listener.send/3` becomes the only send API for E3, E4, E5, E6 and N6 (RC-05,
  CR-E4-8).
- So every `agents.message` path in a required component calls into a component the
  map calls optional. The R-optional rule (`component-map.md:63-66`;
  `MP-R1-C1-T03.md:53-58`) forbids this. `MP-R1-C1-T06` declares seams only for
  build-queue.
- The map also merges two different things into one row: the Khala-published spec
  package (data and goldens, `c/listener-mode.md` §11) and the aiur-side scheduler,
  mode store and `Aiur.Listener` facade.
- `c/client-capability-model.md:97` treats `listener_modes` as optional for "Send a
  message", and no ticket registers the capability (see X-11).

**Fix:**

1. Split the row into two components:
   - `listener-spec`: an external, vendored, non-runtime package. It is optional and
     owned by MP-E7/Khala.
   - `listener-modes`: an L3 component. It is **required** because it is the send
     router. Its Req are `harness-adapters` and `orchestration` (the agent queue).
2. Or keep `listener-modes` optional, declare an orchestration registration seam in
   C1-T06, and state the behaviour when it is absent: `:legacy` routing and capability
   `listener_modes: unavailable/not_installed`.

### X-02 Live Executor has three definitions

- `c/identity-and-capabilities.md:128-131` (§1.4): "a live Executor" is
  `executor.state == "active"`. It also says "MP-E2 routing reads the same roster
  call".
- `c/command-request-and-resolution.md:107-109` (§4): live means at least one roster
  entry in `:active` **or** `:idle`. `B2/MP-E2/tickets/MP-E2-C2-T01.md:50,111`
  implements that rule. Its table test treats `[idle, stalled]` as live.
- `c/pairing-and-instance-registry.md:384` (§7 summary aggregate): active, then
  **stalled**, then idle. When one consumer is idle and another is stalled, the phone
  shows "stalled" while MP-E2 routes the Command Executor-first.
- D9 routing and the MP-N3/N7 Executor state therefore disagree about the same roster.

**Fix:** settle it with one coordinator line.

- Recommended: live = `{active, idle}`, the routing rule already built and tested.
- Update identity §1.4 to that rule.
- Reorder the pairing §7 aggregate to `active > idle > stalled > expired > absent >
  unknown`.

### X-03 The watch `snapshot` message has two schemas

- `B3/MP-N1/tickets/MP-N1-C3-T04.md:31-40` defines:
  - `machines[]{reachability}`;
  - `instances[].state` (`live|starting|…`);
  - `facts.{agents_active, fleet_paused, commands_awaiting, …}`;
  - a size budget of ≤ 16 KiB.
- `B3/MP-N7/tickets/MP-N7-C1-T01.md:77,93` defines:
  - `phone_reachable_to_machine`;
  - `instances[].{row_state, executor_state, active_agents, awaiting, awaiting_blocking, …}`;
  - `open_commands[]`;
  - a size budget of ≤ 32 KiB.
- A third form is in `c/client-capability-model.md` §7. The N7 renderer
  (`MP-N7-C2-T02.md:56`) has no `starting` row state.

**Fix:**

1. Make MP-N7-C1-T01, which owns the watch-link protocol, the only schema.
2. Rewrite the N1-C3-T04 output and client-capability-model §7 as references to it.
3. Add `starting`.
4. Choose one size budget.

### X-04 The component map breaks its own R-down rule

R-down (`component-map.md:59-62`) forbids upward edges. These rows have them:

- **Req `web-shell` (L4) on lower layers:**
  - `voice-stt` (L3, `:123`);
  - `pairing-discovery` (L3, `:125`);
  - `streamdeck-server` (L3, `:127`).
- **Opt `web-shell` on lower layers:**
  - `github-listeners` (L2, `:102`);
  - `build-orders` (`:117`);
  - `commands` (`:118`). This row also lists `AiurWeb.DecisionApiController` as its own
    interface.
- `identity` (L1, `:94`) lists `GET /api/v1/capabilities` as its interface.

The checker would fail on these edges or would have to allowlist them on day one. The
map itself says optional components attach "through registration (routes) at the
composition root" (`:64-66`), and C6-T01 composes the router.

**Fix:**

- Reverse the edges. Each component registers its route and socket modules, and
  `web-shell` composes them.
- Remove `web-shell` from the Req and Opt columns of every L1–L3 row.
- Move the HTTP interface names into a "registers routes" column.

### X-05 Build-order progress notifications depend on the optional build-queue

- D18 turns on build-order 25 % notifications by default. Their facts come from
  `Aiur.BuildProgress`. The component map's Phase D note (`component-map.md:173-176`)
  gives that module to **build-queue**, which is optional.
- `c/queue-readiness-and-build-progress.md` §4.0 says the module "does not depend on
  `build_queue.enabled`".
- MP-N5 gates progress options on the capability `build_queue` being available
  (`B3/MP-N5/tickets/MP-N5-C1-T02.md:46`, reason `build_queue_not_installed`).
- Result: an operator who uses Build Orders without the queue (allowed by D5 and
  capability-matrix §4) loses D18's default progress notifications. Nothing tells them
  why.
- `push-relay` (`component-map.md:126`) lists Opt `build-orders`. Its real dependency is
  build-queue.

**Fix:**

- Give `Aiur.BuildProgress` and the Build Order observer to `build-orders`, or to a
  neutral `build-progress` component.
- Have MP-N5 gate root progress on `build_orders.progress`, and queue progress on
  `build_queue`.
- Correct the `push-relay` Opt column.

---

## 2. Major

### Shared contracts: divergent names and shapes

| ID | Location | Problem | Fix |
|---|---|---|---|
| X-06 | `c/client-capability-model.md:122,126` | Uses the capability `events.subscribe`. The matrix and `c/events-and-replay.md` §10 name it `events.export`. MP-N1 owns this file. | Replace with `events.export`. |
| X-07 | `c/events-and-replay.md:271-272` (§8) and `:378` (§10) | Says the `events.export` capability is "absent" when disabled. `B1/MP-R2/tickets/MP-R2-C7-T03.md:59` reports `unavailable/disabled`. Identity §3 rule 3 and client-model §8 read an absent ID as `unknown` or "update aiur". | Write `unavailable` with reason `disabled` in both places. |
| X-08 | `c/events-and-replay.md:388-391` (§11) | Still says C5 and C6 run before MP-N4/N5. That is RC-09 without RC-31's amendment (C5 at the start of wave 4). `B1/MP-R2/tickets/MP-R2-C5-T01.md:24` has the same stale text. | Apply RC-31 wording to both. |
| X-09 | `B1/MP-R2/tickets/MP-R2-C5-T03.md:52-53,81,127`; `B3/MP-N5/plan.md:121-122` | Register `system.queue.<id>.progress.milestone` and `system.build_order.<root>.progress.milestone`. The contracts and RC-08 say `….progress`. With the extra suffix, the catalog pattern never matches what MP-E1 publishes, so queue progress would never export. | Use the contract names, or `….progress.#`, including the test at `:127`. |
| X-10 | `c/pairing-and-instance-registry.md:40` (§1) | `repository = {tracker, owner, name}` and `{linear, project_slug}`. Identity §1.3 is `{kind, owner, name}`. `MP-N2-C2-T01.md:65` already uses `kind`. | Change the pairing contract to `kind`. |
| X-11 | `c/notification-destination-and-payload.md:116` (§3.1) | `target.agent.session_id` contradicts CR-R1-5: `SessionRef {conversation_id, session_seq}` is the one session identity for notifications. | Use `session_ref: {conversation_id, session_seq}` or drop the field. |
| X-12 | `B2/MP-N4/tickets/MP-N4-C3-T05.md:29` | The deregistrar returns `{:pending, reason}`. The behaviour on line 24 of the same ticket, the Phase D decision and `MP-N2-C7-T03.md:48` say `:ok \| {:retry, reason}`. | Use `{:retry, reason}`. |
| X-13 | `c/command-request-and-resolution.md:184` (§6 JSON) vs `B3/MP-N6/plan.md:66` and `MP-N6-C1-T03.md:23` | One answer field has two names: `selected_option_id` in the contract and N7, `option_id` in N6 and in today's code (`decision_answer.ex:58`). N6 plan also writes `custom_text`, not `custom_response`. | Fix one wire key in command §6 (recommended `option_id`, which matches the code and `DecisionStore.answer/5`). Update N7 to it and replace `custom_text` with `custom_response`. |
| X-14 | `B3/MP-N5/plan.md:122,143`; `MP-N5-C2-T03.md:24,42,60`; `C1-T04:38`; `C2-T01:37`; `C2-T00:32`; `chunks.md:53` | Call `Aiur.BuildQueue.progress/1`, which the contract does not define. The contract has `Aiur.BuildProgress.facts/1`, `subscribe/0` and PubSub `"build_progress"`. CR-N5-4 is still open in `MP-N5/tickets/CONTRACT-REQUESTS.md:12`. | Rename everywhere and close CR-N5-4. |

### Capability IDs, states and reasons

| ID | Location | Problem | Fix |
|---|---|---|---|
| X-15 | `B2/MP-E3/tickets/MP-E3-C3-T03.md:26-29,60`; `B2/MP-E3/chunks.md:113` | Registers a new ID, `executor.conversation_read` (chunks.md calls it `codex_executor_read`). Its states are `proven\|untested\|unsupported\|unknown`, and "no binding" maps to `unknown/not_attached`. Identity §1.4 requires `executor.conversation` with `unavailable/executor_not_managed`. No E3 ticket fills the reserved `executor.harness` and `executor.session_ref`. | Feed `executor.conversation`: proven → available, untested → degraded, unsupported → unavailable with a registered reason. Fill `executor.harness` and `session_ref`. |
| X-16 | `B3/MP-N3/plan.md:122,132-138` | Uses the IDs `executor_conversation`, `commands`, `executor_roster`, `background_agents` and `executor.conversation_available`. The N3 tickets are already correct. | Use `executor.conversation` (with `route`), `commands.read`, `executor.background_agents`, and the top-level `executor.state` and `executor.harness`. |
| X-17 | `B2/MP-E2/plan.md:306-307` | Publishes `native_question_capture` and `executor_live` as capability facts. CR-E2-6 renamed the first to `harness.<id>.native_question` (attribute `mode`) and rejected the second. | Rewrite the bullet with the canonical names. |
| X-18 | `B2/MP-E3/tickets/MP-E3-C4-T02.md:31-32,39` | Reasons `unsupported` and `fields_unverified` are not in the closed reason enum (identity §2.2), so clients read them as `unknown`. MP-N3-C1-T05:70 uses `capability_not_provided`. `MP-N4/plan.md:155,248` uses `degraded(relay_unreachable)`. `MP-N4/plan.md:151` maps `push.enabled: false` to `not_configured`; `MP-N4-C3-T04` correctly says `disabled`. | Map internal atoms to enum reasons at the provider, or register new reasons in identity §2.2 and the `aiur-contracts` enum. Align the N4 plan with its ticket. |
| X-19 | `B1/MP-R1/capability-matrix.md` §2 | Has no `orchestration` row. The contract example (`c/identity-and-capabilities.md:185,302`), `MP-R1-C3-T02.md:33,81` and R1 `plan.md:178` all emit it. The contract says §2 is normative, so the `aiur-contracts` enum would leave it out. | Add the row (provider: orchestration). |
| X-20 | `B3/MP-N2/plan.md:158,194` | Capability states are listed as `available\|disabled\|unavailable\|unsupported`. | Use `available\|degraded\|unavailable\|unknown`. `unsupported` is only the summary fan-out status from pairing §7. |
| X-21 | No ticket in MP-E1 or MP-E7 | Nothing registers `build_queue`, `build_queue.build_order_source` or `listener_modes`. The identity contract §2.3, the matrix and `component-map.md:199,236` all assume E1 and E7 do. Without a provider, every client renders these as `unknown`. | Add one provider ticket to each feature. Map E1's `status` (`disabled\|unsupported_tracker\|store_unavailable\|writes_paused`) to a state and reason. |

### Binding decisions not applied

| ID | Location | Decision | Fix |
|---|---|---|---|
| X-22 | `B1/MP-R1/tickets/MP-R1-C8-T04.md:27-31` and its frontmatter; `MP-R1-C5-T03.md:57-62` | RC-24 says C5-T03 owns the `ObservabilityPubSub` move and C8-T04 drops its item 1. C8-T04 still does the move and names `event-bus` as owner, which contradicts events §2 R-6 (signal component). C5-T03 still calls this a "proposed resolution". | Delete C8-T04 item 1 and its checklist line. Add a dependency on C5-T03. Mark C5-T03 "settled by RC-24". |
| X-23 | `component-map.md:118`; `migration-plan.md:34` (S10); `capability-matrix.md:107-108` | CR-C8-3 says `commands` is **required** and delivery is a synchronous call through the orchestration port. The row still says "optional in principle" and "answer delivery by event". S10 says the event replaces the direct call. The headless minimum set leaves out `commands`. Only the Phase D note corrects this. | Edit the row, S10 and the minimum set. |
| X-24 | `component-map.md:115` | RC-11 defines two narrow edges: `Hints` read by `DispatchPolicy`, and `ClaimProbe` implemented by orchestration. The row says "build-queue (readiness labels only, through tracker)". | Name the two seams and cite C1-T06. |
| X-25 | `B2/MP-E7/plan.md:212-215` | Says E7 starts after MP-R2's registry, and that if E4 ships first it calls `AgentChat.send/3`. This contradicts RC-05 (E7-C1..C3 are in wave 3), RC-31 and CR-E4-8 (no interim AgentChat step). | Only C2-T05 needs R2-C5. Delete the AgentChat sentence. |
| X-26 | `B2/MP-E6/tickets/MP-E6-C5-T05.md:28-30,54-55,59` | The voice confirm path calls `DecisionStore.answer/5` directly and bypasses `Aiur.Commands.Answering` (CR-E2-9: surfaces call `Answering`). That skips the D11 supersede and actor rules. It also hedges on `actor.via`, which is canonical (E6 R-3). | Call `Answering` and set `via: :voice_assistant`. Use `ConflictSummary.for/1` for the `stale` draft state. |

### Modularity

| ID | Location | Problem | Fix |
|---|---|---|---|
| X-27 | `capability-matrix.md:68,92,117`; `component-map.md:125` | Gives `pairing` and `push` a dependency on `web-shell`: pairing-only needs web-shell, and `push` is **no** without web-shell. But the MP-N2 gateway is its own process and works with `--no-dashboard` (`B3/MP-N2/plan.md:118-131`; pairing §7). Identity §2.3 (CR-N4-4) says `push` is reported in every run shape that has the bus. The matrix makes an optional surface a hidden dependency of pairing and push. | Drop `web-shell` from these rows. Keep it only for "open instance dashboard". |
| X-28 | `component-map.md:124`; `capability-matrix.md:64` | `voice-conversation` lists `conversations` and `commands` as Req. `B2/MP-E6/plan.md:57-66` makes E2, E3 and E4 optional ports, each with a fallback. The map also leaves out the real send dependency on `listener-modes` (voice V7). | Make `commands` and `conversations` Opt. Add `listener-modes` as Req, or Opt per X-01. |
| X-29 | `component-map.md` §3 and `migration-plan.md` | Components that later features add have no row and no migration step: the MP-N2 machine gateway and the `aiur_machine` store library; the MP-N4 relay service (`services/push-relay-service`, which is also outside MP-R1 acceptance 1's ownership scope, `plan.md:170`); MP-N5 `notification-policy` and its preferences store; the shared listener spec (X-01). | Add rows with `status: planned`, so C10's `features[].adds` can name them, and add `services/` to acceptance 1. Without this, the directory page (D20) cannot list them, and C10-T01 rule I4 cannot be met. |
| X-30 | `component-map.md:119-121,133` | `kind` values such as "required by surfaces", "optional (on with recording)" and "optional (required by every remote client)" are not in the checker's binary enum (`MP-R1-C1-T01.md:108`). If `conversations` becomes required, its Opt `executor-attention` breaks R-optional without a seam. | Give every row a binary `kind` and check the Opt edges again. |

---

## 3. Minor

### Contracts

- **X-31** Leftover tool markup (`</content>` and `</invoke>`) at the end of seven files:
  `c/listener-mode.md`, `c/harness-adapter.md`, `B1/MP-R7/plan.md`,
  `B1/MP-R7/chunks.md`, `B2/MP-E7/plan.md:248-249`, `B2/MP-E7/chunks.md:213-214` and
  `owner-design-tasks/DESIGN-E7.md`. It breaks Markdown rendering. **Fix:** delete
  those lines.
- **X-32** `c/notification-destination-and-payload.md:71,113` and
  `c/voice-session.md:244` give `decision_id` examples as `dec_…`. The real form is 16
  hex characters with no prefix (command §2). The notification example was copied into
  `MP-N4-C1-T04.md:63` and `MP-N4-C3-T06.md:45`. **Fix:** use hex examples.
- **X-33** Two `anchor_id` hash inputs:
  - `c/notification-destination-and-payload.md:327` (A-E4-1):
    `anc_<sha256(event_ref, conversation_id)>`;
  - `c/conversations-transcripts-anchors.md` §10:
    `sha256(event_id, event_kind, conversation_id, precision)`.

  **Fix:** A-E4-1 should cite §10 and treat the value as opaque.
- **X-34** `c/notification-destination-and-payload.md:328` (A-R1-1) says `push`
  `degraded` carries `since`. `MP-N4-C3-T04.md:31` adds a `devices` attribute. Neither
  is a registered attribute (identity §2.2 allows only `route` and `mode`). **Fix:**
  register them or remove them.
- **X-35** Client-model §4 rule 4 (`min_client_version`, singular) and
  `B3/MP-N1/plan.md:209` / `MP-N1-C3-T01.md:56` should be `min_client_versions`.
  - Identity §3 rule 3 renders an ID from a newer contract version as `unknown`
    ("update aiur").
  - Client-model §4 renders it as `needs_update`.

  **Fix:** choose `needs_update`, which shows the update action, and edit identity §3.
- **X-36** One transport fact has three spellings:
  - advert `transport: https|http_overlay|none` (pairing §6.1);
  - client-model I2 `https|http_degraded`;
  - setting `transport.allow_cleartext_overlay` (pairing §8).

  **Fix:** add one sentence to pairing §8.1 that maps `http_overlay` to client
  `http_degraded`.
- **X-37** Pairing §7 Fact status `disabled` is used for "the instance has no
  build-order capability" (`:385`). Identity defines `disabled` as "the operator turned
  it off", and the right reason here is `unsupported_tracker` or `not_installed`.
  **Fix:** a Fact `unavailable` that carries the capability's own reason.
- **X-38** `c/voice-session.md` §5.1 says the target reference is "consumed from the
  identity contract", but identity defines none. It uses `ticket: "owner/repo#123"` and
  `session_id`, while the listener API takes `conversation_ref` (conversations §3).
  **Fix:** define the target as `ConversationRef` or a Command ref, and state where the
  mapping from ticket string to `TrackerIdentity` happens.
- **X-39** `c/conversations-transcripts-anchors.md` §4 `harness` enum includes
  `opencode`, which is not a `harness_id` (`c/harness-adapter.md` §1). It also omits
  `kimi`, `deepseek`, `openrouter` and conditional `gemini`. **Fix:** reference the
  harness-adapter list. In the same file, §14 lists five receipts; listener §7 has
  eight. **Fix:** cite listener §7 instead of listing them.
- **X-40** `c/listener-mode.md` §5 `agent_ref: "<instance>/<ticket identifier>"`. The
  field name is `instance`, not `instance_id`, and the address differs from the
  `conversation_ref` that the send API uses. **Fix:** `{instance_id, ticket}` or a
  `ConversationRef`.

### MP-R1 companion docs

- **X-41** `component-map.md:255` says `~/.aiur/config` is global machine config. RC-03
  says machine settings live in `~/.aiur/machine`. **Fix:** reword, and give
  `~/.aiur/machine` its owners (pairing-discovery for `mobile`, `gateway`, `pairing`
  and `transport`; push-relay for `push`).
- **X-42** Stale cells in `component-map.md`:
  - `voice-stt` facade `ElevenLabs.Realtime…` and `voice:dictation`. Now `Aiur.Voice`,
    `voice:dictate` and `voice:converse` (RC-14).
  - `listener-modes` "home is MP-Q1". MP-Q1 is answered (E7-D1).
  - `watch-apps` "decided by MP-N1". RC-17 put them in `packages/aiur-mobile`.
  - `capability-matrix.md:57`: `executor.conversation` provider "conversations +
    harness-adapters", but `MP-R1-C3-T02.md:36` registers it in executor-attention.
- **X-43** `component-map.md:134`: `dashboard-ui` owns `streamdeck_live.ex`, which uses
  `StreamdeckLogs` and `StreamdeckProjection` (owned by streamdeck-server). But
  `streamdeck-server` is not in dashboard-ui's Opt list. **Fix:** add it as Opt, or move
  `StreamdeckLive` into `streamdeck-server`.
- **X-44** `B1/MP-R1/component-directory.md:120-125` (§6) says C10-T04 is "sidebar
  entry and publish". In the tickets, T04 is the checks and T05 is the publish step.
  §6's "T01 to T03 behind `noindex`" also leaves out T04. **Fix:** renumber §6 to match
  the tickets.
- **X-45** `MP-R1-C10-T01` rule I4 requires every `planned` component to appear in a
  `features[].adds`. But `features[].id` accepts only `^MP-(E|N)…`. `aiur-contracts`
  is `planned` "until C3-T06" and is added by MP-R1, so if C10-T01 merges before C3-T06
  the checker cannot pass. **Fix:** exempt Bucket-1-added components from I4, or block
  C10-T01 on MP-R1-C3-T06.
- **X-46** `MP-R1-C10-T01` and `C10-T04` check capability IDs against the enum. That
  enum has the template `harness.<id>.native_question`. **Fix:** the checker must
  accept template IDs. Add a fixture.
- **X-47** `B1/MP-R1/tickets/CONTRACT-REQUESTS-C6-C11.md:25,31` still asks for
  `Aiur.Conversations`. `B1/MP-R1/plan.md:29` still lists CQ1 (classification) as open,
  although RC-12 settled it. `B1/MP-R3/plan.md:27` says "about four tickets"; there are
  two. **Fix:** mark them superseded or correct them.
- **X-48** `B1/MP-R2/tickets/MP-R2-C6-T02.md:157` and `MP-R2-C6-T05.md:86` call
  `Aiur.Alerts.emit_system` directly in wave 5, after the signal port exists (PR-07).
  **Fix:** use `Signal.alert/2`.
- **X-49** `B1/MP-R5/plan.md:177`, `MP-R5/tickets/README.md:6` and
  `MP-R5/tickets/CONTRACT-REQUESTS.md:10` give `{:voice_error, reason}`. The contract
  form is `{:voice_error, %{code, message}}`. `CONTRACT-REQUESTS.md:24` uses the
  retired `voice.dictate.status`. **Fix:** use the map form and `voice.stt`.

### Feature plans behind their tickets

Each item below is plan text that its own Phase C/D tickets have already corrected.
**Fix for each:** rewrite the stale lines; do not just annotate them.

- **X-50** MP-E1:
  - `plan.md:251,322`: topics `system.queue.{inputs,store}_unavailable` should be
    `system.queue.attention.<cause>`;
  - `chunks.md:158`: binding `queue.attention.*` should use `#` to match `.resolved`;
  - `chunks.md:192-193`: still waits for the coordinator to name the producer, which
    RC-08 already did.
- **X-51** MP-E4 `plan.md:94-95,129,207` and `chunks.md:160-169` still describe an
  `AgentChat` composer step and "E7 is wave 4". This contradicts RC-05 and CR-E4-8.
- **X-52** MP-E5:
  - `plan.md:56`, `chunks.md:35,46-47`: `Voice.capabilities/0`, with state and reasons
    mixed together;
  - `plan.md:95`: wire reason `unconfigured`;
  - `plan.md:84-85`: send returns `{message_id, status}`;
  - `MP-E5-C8-T01.md:178` lists MP-E6-C7-T01 as a dependent, an edge RC-30 removed.
- **X-53** MP-E6:
  - `plan.md:89-90,122,179`: `source: voice_assistant` should be
    `opts[:origin] = :voice_assistant`;
  - `plan.md:88`: `message_id` should be `client_request_id`;
  - `plan.md:214-215`: config namespace "proposed", although RC-13 settled it;
  - `plan.md:8` blocks the whole feature on E2, E3 and E4, which §2 calls optional
    ports. **Fix:** move these blockers to chunk level. The same applies to
    `MP-E5/plan.md:8` (E3 and E7).
- **X-54** MP-E7:
  - `plan.md:196`, `chunks.md:158,168,202`: `read_messages` should be
    `aiur_read_messages`;
  - `plan.md:139`, `chunks.md:175-187`: a Node `aiur hook deliver`, which `chunks.md:49-51`
    replaced;
  - AC1 (`plan.md:191-193`) describes the delivery default after the flag flip.
    **Fix:** qualify it with "after C7-T04 (E7-D6)".
- **X-55** MP-E3:
  - `plan.md:200` says MP-E2 captures the Executor's native questions as
    Executor-originated Commands. No E2 chunk does that; E2-C4/C5 cover daemon-run
    workers only. `MP-E3-C4-T01.md:86` relies on the claim. **Fix:** delete the claim,
    or add an E2 ticket for hook-based capture.
  - `plan.md:263` (OQ-E3-3) asks D13's default again. **Fix:** say `sync` is the
    default and an owner override remains open (RC owner item).
- **X-56** MP-N plans:
  - `N1/plan.md:175,178`: reason `not_supported_by_server`; payload shape from before
    ProtectedPayload v1;
  - `N2/plan.md:203`: `PUT /v1/devices/<id>/push` and `deregister(device_id)`;
  - `N2/plan.md:302`: `identity_unavailable`, which is a CLI code. State that it is not
    the capability reason `identity_unreadable`;
  - `N4/plan.md:75`: `destination.instance_key`;
  - `N5/plan.md:68,87,127`: preferences keyed by `instance_key` (RC-02);
  - `N5/plan.md:129` contradicts `:142-145`;
  - `N5/plan.md:201-202` contradicts the gateway's single-writer rule;
  - `N6/plan.md:60,94,195,198`: outcome names `stale_version`, `already_resolved`,
    `revoked` should be 409 `decision_conflict` with a reason, and `device_revoked`;
  - `N6/plan.md:44-45`: `push` as a required capability of the Command screen, which
    can also be opened without a notification. **Fix:** make it optional;
  - `N7/plan.md:131` hides the awaiting count when unavailable. The ticket renders
    "—", which is correct;
  - `N7/plan.md:99,112` cites N1 "A5" instead of the MP-E5-C8 device voice path;
  - `MP-N4-C5-T03.md:47`: Android channel `aiur.commands` vs category `aiur.command`.
- **X-57** D18 tension: `B3/MP-N5/plan.md:242-243` (OQ-N5-1) proposes a per-instance
  mute for blocker Commands, which D18 says are "always on". This is acceptable as an
  owner question. **Fix:** DESIGN-N5 must say that accepting it amends D18.

### Prior U0–U9 plan

- **X-58 (major).** RC-19 limits the prior plan's "U0 review before code work"
  (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md:77`) to **refactor**
  work. That is exactly what MP-R1..R7 are, yet no Bucket-1 file says whether they wait
  for U0:
  - `migration-plan.md:24` gives S0 "Depends on: none";
  - no Bucket-1 ticket lists U0 in `blocked_by`;
  - the prior plan's table says "None against U0" (`:110`).

  **Fix:** add an RC that either blocks MP-R1-C1/S0 on U0 review or states that the
  MP-R1-C11-T02 implementation-head recheck replaces it.
- **X-59** The prior plan's MP cross-references are stale:
  - `:118-123` lists four "open coordination points". RC-19 to RC-22 closed them.
  - `:214` says "MP-R1-C9-T5 splits `AgentControlCLI`". The split is C9-T10 to T14.
  - `:214` mentions a "`decision.answered` event", which contradicts CR-C8-3.

  CR-E1-5 rejected editing `docs/plans` from the pack, so **fix** it in the plan-refresh
  ticket MP-R1-C11-T03.
- **X-60** `migration-plan.md:49-58` (§3 interlocks) lacks two rows:
  - S7 (MP-R7) against U4: the prior plan says R7-C3 rebases onto U4;
  - S5/S13 against U2: C7-T07 and T08 touch the Dispatcher.

  `MP-R1-C8-T08.md:8` cites a "U2 graph contract" that U2 does not define. The label
  comes from the U8 ledger; Build Order membership is U5. `MP-R5-C3-T01` (package move)
  should list U7. Several `prior_units` values are prose, not lists:
  `MP-N4-C3-T00.md:9`, `MP-N5-C2-T00.md:9`, `MP-N6-C1-T00.md:9` and
  `B1/MP-R2/plan.md:10`.
- **X-61** `dependency-map.md:36-44` "Wave notes" still present the R2-C5 wave, the
  E5-C8 wave, the E6 → E5-C8 edge and the E5/E6 cycle as open. RC-28 to RC-31 decided
  all four. **Fix:** add "resolved by RC-28..RC-31" next to each note, or leave it to
  the graph-editing agent.

> Count note: blockers X-01..X-05; major X-06..X-30 plus X-58; minor X-31..X-57 and
> X-59..X-61. Some minor items (X-35, X-36, X-56, X-60) bundle related nits.

---

## 4. The component directory page (MP-R1-C10)

**Drift resistance is good:**

- One manifest (`components.json`) drives both the dependency checker and the page.
- The page is built by a build-time loader that copies only public fields.
- `check-components.py` covers orphan paths, docs links, config sections, capability IDs
  and the sidebar link.
- The docs rules run in the required `workflow security` job, so docs-only PRs cannot
  break the page (C10-T04).
- Planned features come from the `features[]` array.
- Publishing is gated on S16, C11-T03 and explicit owner approval (D20, C10-T05).

**Gaps:**

1. It cannot list every component, because the map has no rows for the gateway, the
   relay service, notification policy or the listener spec (X-29). C10-T01 rule I4 then
   cannot be met for `aiur-contracts` (X-45).
2. Template capability IDs need checker support (X-46).
3. `component-directory.md` §6 has the wrong ticket numbers (X-44).
4. The "Planned" list is the 14 MP-E/N features only. That is by design, but the
   Bucket-2-enabling work inside R1 and R2 (identity, capabilities endpoint, event
   export) adds capabilities and is not a feature entry. This is acceptable if
   DESIGN-R1 confirms that those appear as component capabilities, not as planned
   features.

---

## 5. Verified consistent

- **Identity:** `instance_id = <machine_id>/<instance_key>` everywhere; `instance_ref`
  only in retirement notes. `machine_id` created by MP-R1 at first boot in
  `~/.config/aiur/machine/identity.json` (RC-01); N2 never creates it; only the gateway
  rewrites it (label, reset). `SessionRef` belongs to E4, not derived from `instance_id`.
- **Machine settings:** `~/.aiur/machine` (RC-03) in every N2, N4 and N5 reference; no
  plan writes `~/.aiur/config` (map wording aside, X-41).
- **Topics:** `ticket.<id>.agent.decision.human-needed` (one spelling, CR-N5-3),
  `ticket.<id>.agent.listen-mode.changed`, `ticket.<id>.pr.closed_unmerged` (producer
  MP-E1-C4-T05, webhook mode only) and `system.capabilities.changed` agree across
  contracts and tickets. The only topic drift is `.milestone` (X-09).
- **Voice:** `Aiur.Voice` with `Transcriber`/`Synthesizer`; IDs `voice.stt`, `voice.tts`,
  `voice.conversation` (retired IDs only in retirement notes); `:unconfigured` →
  `not_configured` mapped in one place (MP-E5-C2-T03); namespaces `elevenlabs.*` and
  `voice.conversation.*` (RC-13); device path `/api/v1/device/voice-ticket` +
  `/voice/device` (MP-E5-C8, wave 5, RC-29) with `conn.assigns.device_id`.
- **Notifications and pairing:** `aiur.destination`, `aiur.command|progress|other`,
  `PushDeregistrar` (contract and N2), `devices:revoked`,
  `Machine.Store.device_active?/1` and `sign/1`, `:device_auth`/`:device_write`.
- **Decisions:** D3–D8 (E1); D9–D12 (E2: `route_state`, closed cause list,
  `decisions.escalation.*`, reserved ticket `"executor"`, `Aiur.Commands.Answering`);
  D13 (`sync` default behind `:listener_send_routing` = `:legacy`); D15 (E4 write scope;
  Command answers excluded from listener mode: listener §2, command §7, CR-E4-4); D16,
  D17; D19 (full-machine scope, per-device revoke, unpair-all); D20 (C10-T05 gated on S16
  and C11-T03); brief scope (no combined inbox in N3/DESIGN-N1/DESIGN-N3; no watch
  pause/resume/spawn, N7 AC6).
- **Modularity:** Tailscale optional (MP-R3 never calls `tailscale`; T-A accepts any CA).
  Cloudflare/`hooks.aiur.dev` optional (R4 polling fallback; Workers is an optional relay
  adapter, N4-C2-T07; `relay_url` per device, self-hostable). Voice absence leaves text
  intact (R5 acceptance 3(d); V6). Dashboard has no Stream Deck package dependency (R6).
  Build-queue absent leaves dispatch unchanged (E1 AC8; `Hints` default `{0,0}`).
  Build-order source optional (D5). Mobile and watch depend only on
  `packages/aiur-contracts` plus HTTP APIs (`N1/plan.md:92-96`, R-client); `src/`
  references in client tickets are evidence citations, except the intended
  dashboard-side bridge N1-C4-T04.
- **Absence rendered explicitly:** identity §2.2 rules; client-model §3/§4 precedence;
  N3 and N7 render unavailable as "—", never 0 (except `N7/plan.md:131`, X-56); E3 AC5
  and AC6; pairing §7 Facts.
- **Harness:** `native_question` modes `in_band_hold|defer_resume|none` identical in the
  harness contract, command §10 and the identity `mode` attribute; Gemini/ACP row
  conditional on #2870 (RC-22).
- **Prior plan:** `baseline/existing-refactor-research.md` §2.1 matches U0–U9; ~35
  sampled tickets cite only U0–U9; RC-19..RC-23 are reflected in E1 (C1 hooks,
  sanctioned label-writer caller), R2 (U5 trust snapshot first), R7 (Gemini row) and
  size-owner notes.
