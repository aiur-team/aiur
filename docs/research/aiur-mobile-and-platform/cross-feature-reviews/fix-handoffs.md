
## ux

- **dependency-graph.json / dependency-map.md** (graph owner): MP-R5-C2-T02 `blocked_by` gained `MP-R1-C4-T05` (RQ4: config sections stay literal `embeds_one`; voice owns `elevenlabs` as manifest data). Add the edge MP-R1-C4-T05 → MP-R5-C2-T02. No cycle: C4-T05 depends only on DESIGN-R1 and MP-R1-C1-T01.

### platform → dependency-graph.json / dependency-map.md
- Security M1 (platform-R2R7): MP-R2-C7-T05 frontmatter now lists `MP-N2-C1-T03` (per-instance `Aiur.Machine.Store.Watcher`) in `blocked_by`. Add the edge MP-N2-C1-T03 → MP-R2-C7-T05 to the graph (both wave 5; no cycle: N2-C1-T03 depends only on DESIGN-N2 and MP-N2-C1-T02).

### platform → contracts/pairing-and-instance-registry.md §7 (summary aggregate)
- X-02 / RC-37: reorder the Executor summary aggregate to `active > idle > stalled > expired > absent > unknown` (identity §1.4 now states this order). Add one line: "Live = `active` or `idle` (RC-37); a `stalled` Executor is shown with its own label but routing treats it as not live (D9)."

### platform → MP-N1-C3-T04, MP-N7-C1-T01, MP-N7-C2-T02 (watch snapshot)
- X-03 / RC-38: MP-N7-C1-T01 is the only watch `snapshot` schema; set its size budget to 16 KiB (not 32 KiB) and add row state `starting`. MP-N7-C2-T02 renderer handles `starting`. MP-N1-C3-T04 deletes its own snapshot field list and 16 KiB budget text and references MP-N7-C1-T01 instead. client-capability-model §7 now defines no fields and points to MP-N7-C1-T01.

### platform → MP-N5 (plan.md, MP-N5-C1-T02, related C2 tickets)
- X-05 / RC-40: `Aiur.BuildProgress` belongs to the `build-orders` component. Gate build-order (root) progress options on capability `build_orders.progress` (provider build-orders), not `build_queue`; drop reason `build_queue_not_installed` for root progress; gate queue progress options on `build_queue`. D18 default progress notifications must work with the queue absent. See queue-readiness contract §4.0 and capability-matrix row `build_orders.progress`.

### platform → MP-N1 plan.md:209, MP-N1-C3-T01:56
- X-35: rename `min_client_version` to `min_client_versions` (map keyed `phone|watch|streamdeck`, identity §2.2). An ID newer than the server's `contract_version` renders `needs_update` with target `server` ("Update aiur on <machine>"); below `min_client_versions` renders `needs_update` with target `client` (client-capability-model §4 rule 4; identity §3 rule 3).

### platform → MP-E2 (DecisionStore human-needed producer tickets) and contracts/notification-destination-and-payload.md
- Security m3: the exported attrs of `ticket.<id>.agent.decision.human-needed` / `executor.decision.human-needed` are now `{requester_kind, blocking, urgency, cause}` (events contract §9). `short_label` is not a feed attr; it travels only inside the sealed push payload, and clients read it from the Decision API. Update the E2 producer ticket's attrs allowlist and the notification contract if it says the feed carries `short_label`. Phone renders `summary.title` with a "from agent" style.

### platform → value-and-sequencing.md / tickets READMEs of MP-R3, MP-R4, MP-R5, MP-R6 (U0 gate)
- X-58 (RC-19): add one line to each of MP-R3..R6 plan.md and tickets README: "Every MP-R<n> ticket waits for U0 review of the prior refactor plan (docs/plans/2026-09-29-001-refactor-production-readiness-plan.md:77); RC-19 keeps the U0 gate for refactor work. No `blocked_by` ID exists for U0; the Executor checks it before dispatch. MP-R1-C11-T02's recheck does not replace it." MP-R1, MP-R2 and MP-R7 already state this.

## mobile → owner-design (ux fixer): DESIGN-N6 §5 state keys
- Target: `owner-design-tasks/DESIGN-N6.md` §5. Change: prefix each state with the key from `MP-N6/plan.md` §5.5 (`S01` loading … `S17` `commands.answer` unavailable, in the current §5 order) and add `S18` "unlock to view" (pairing store locked before first unlock, MP-N6-C2-T02). MP-N6 tests are named by these keys.

## mobile → owner-design (ux fixer): DESIGN-N6 D-1 watch exception
- Target: `owner-design-tasks/DESIGN-N6.md` §4 D-1. Change: append "The watch `transferUserInfo` late answer (MP-N7 plan §4/§8) is the one deliberate exception: re-sent with its original idempotency key and expected_version, so a changed Command refuses it as stale (DV-W4b). Accepting D-1 = no keeps that exception unless you also reject it, in which case MP-N7 drops the fallback." (feasibility m6)

## mobile → owner-design (ux fixer): DESIGN-N6 §5 voice end states
- Target: `owner-design-tasks/DESIGN-N6.md` §5 (and DESIGN-E6 states). Change: add "voice ended — one state per voice-session §8.1 row (daily cap, provider quota, provider unavailable, connection lost, device unpaired, cause-neutral provider error/unknown); Retry only where §8.1 allows" and "draft stale (answered elsewhere, shows the winner)". Source: MP-N6-C4-T03 (feasibility M2/M7).

## mobile → mobile (parent, MP-E6): confirm-path attribution for device Converse
- Target: `bucket-2-platform/MP-E6/tickets/MP-E6-C5-T05.md` §Chosen design "Actor". Change: when the session's socket authority is `%{kind: :device, device_id}` (voice-session §3.5), record `client: {surface: "phone"|"watch", device_id}` and `actor_source: :device`, and `via: :voice_assistant`; add a test "confirm over the device socket records device_id". MP-N6-C4-T03 relies on the daemon (not the phone) recording the answer on `confirm_draft`.

## mobile → MP-N7 owner (mobile parent / N7 sub-fixer): open_on_phone schema row
- Target: `bucket-3-mobile-watch/MP-N7/tickets/MP-N7-C1-T01.md` schema list. Change: add message type `open_on_phone{v:1, destination, intent?: "answer"|"converse"}` (destination = notification contract §3.1 shape, no Command content), owned by MP-N6-C5-T03; fixtures `fixtures/watch-link/valid|invalid/open_on_phone*.json`.

### platform → bucket-1-refactor/MP-R3/plan.md
- X-47: line ~27 says "about four tickets"; MP-R3 has two (MP-R3-C1-T01, MP-R3-C2-T01). Change to "two tickets".

### platform → bucket-1-refactor/MP-R5/tickets/MP-R5-C3-T01.md
- X-60: the package move must list U7 in frontmatter `prior_units` (as a YAML list), because U7 owns the files it moves.

### platform → bucket-1-refactor/MP-R3/plan.md, MP-R4/plan.md, MP-R5/plan.md, MP-R6/plan.md (and each tickets README)
- X-58 (RC-19): add one line to each Goal capsule / blockers: "U0 gate: every MP-R<n> ticket waits for U0 review of the prior plan (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`), because RC-19 keeps that gate for refactor work. U0 has no ticket ID, so the gate is stated here and not in `blocked_by`; the MP-R1-C11-T02 recheck does not replace it." Same wording as MP-R1 plan.md and migration-plan.md S0.

## mobile → ux (owner-design)
- DESIGN-N5 §3 D-2 / OQ-N5-2 (feasibility M3): reword from a noise question to a delivery-reliability risk — "APNs/FCM accept a push and give no display receipt; a lost blocker push is otherwise noticed only when you open the app." Proposal: **one** reminder for a blocking Command still with you after 30 min (setting `commands_reminder_minutes` ∈ {off, 15, 30, 60}, default 30), replacing the first notification, never after resolution; plus the app icon badge = open blocking Commands. Add the reminder row to §2 "Phone: Notifications" and to the §5 acceptance list. If refused, MP-N4 AC-N4-1 records it. Implemented in MP-N5-C1-T01 / C2-T02.

## mobile → ux (owner-design)
- DESIGN-N5 §3 (G-5 receiver): add "D-9 App icon badge = number of open blocking Commands that need you, per app (all paired machines summed on device)"; proposal yes. DESIGN-N3 Q5 then links here. Payload field `summary.badge` (contract §3) and MP-N4-C4-T03 / C5-T03 implement it.

## mobile → ux (owner-design)
- DESIGN-N4 §3 (security m9): add "D-10 Lock-screen privacy" — options (a) hide body when locked (iOS `hiddenPreviewsBodyPlaceholder`; Android `VISIBILITY_PRIVATE` with the uniform fallback as the public version) — **proposal**; (b) follow the OS preview setting only. Note D-6's in-app tip becomes optional under (a). Add to §5 acceptance ("D-1…D-10"). Implemented by MP-N4-C4-T03 / C5-T03; device row V-LS1.

## mobile → ux (owner-design)
- DESIGN-N4 §4 states (feasibility M6): add "phone notifications broken (push keys lost on the device; re-pair)" — machine side (`aiur push status` / `aiur mobile status`, MP-N4-C3-T07 state `:keys_lost`) and phone side (fallback notification opens "Open aiur to re-pair"). Also §1: the clear fallback is pinned per app at the relay (security m1), so a relay cannot show other clear text through aiur's sends.

## mobile → owner-design (ux fixer): DESIGN-E6 E6-OQ6 cap default and E6-OQ1 wording
- Target: `owner-design-tasks/DESIGN-E6.md` E6-OQ6 and E6-OQ1. Change OQ6 recommendation to: "`voice.conversation.daily_minutes_cap` default **60 minutes per local day** (capped by default; explicit `null` = no cap; `0` disables converse). Sessions interrupted by a daemon restart count (last record time − start). Owner may pick another number." Change OQ1 to say speech may at most *focus* the Confirm button; a draft is confirmed only by the button on an authenticated client (voice-session V8). Sources: feasibility M8, security m4; MP-E6-C3-T01, MP-E6-C5-T02.

## mobile → owner-design (ux fixer): DESIGN-E5 STT daily cap question
- Target: `owner-design-tasks/DESIGN-E5.md` (new question after E5-OQ6). Add: "Does dictation (browser and the MP-E5-C8 device path, incl. watch D-relay) need a daily STT-minute cap? Today it has a 9,600,000-byte (~5 min) per-session cap and 2-per-device / 8-global concurrency caps; account quota surfaces as `provider_quota`. **Recommendation: no daily STT cap in v1**; revisit if provider cost reports show watch relay usage above 30 min/day." Source: feasibility M8 (last paragraph).

## mobile → owner-design (ux fixer): DESIGN-E6 states for typed voice errors
- Target: `owner-design-tasks/DESIGN-E6.md` states list. Add one ended/error state per `contracts/voice-session-client-errors.md` row the dashboard can show (daily cap reached, provider quota, provider unavailable, connection lost, cause-neutral provider error, unknown), with Retry only where that table allows; history views also show "ended by a daemon restart". Source: feasibility M7; MP-E6-C7-T02.

## mobile → contracts/consistency fixer: client-capability-model §7 (RC-38)
- Target: `contracts/client-capability-model.md` §7 (watch snapshot). Change: delete the inline snapshot field list and replace it with a reference: "The watch snapshot schema is owned by MP-N7-C1-T01 (`fixtures/watch-link/schema/snapshot.schema.json`), budget 16 KiB, closed `row_state` set `live|starting|stale|unreachable|gateway_offline|crashed|stopped|unsupported|removed` (RC-38, X-03). This section keeps only the affordance-resolution rules." Also X-06: `events.subscribe` → `events.export` at :122,126.

## mobile → ux fixer: DESIGN-N7 DV-W1 fallback owner choice (feasibility M5)
- Target: `owner-design-tasks/DESIGN-N7.md` §3 decisions (add a row, and add it to the acceptance list). Wording: "D-N7-10 If the Apple Watch shows only the uniform fallback for a forwarded notification: (a) accept it — the default action opens the watch app, which loads the Command card from the iPhone in one tap (`get_command {latest_notified}`); or (b) build direct watch push (N7-RQ4: its own key and a second MP-N2 pairing scope, a new conditional chunk). Recommendation: (a). DV-W1 passes on decrypted text or on the fallback with the card one tap away." Source: MP-N7 plan §7, MP-N7-C6-T01 DV-W1.

## mobile → MP-N2 owner fixer: MP-N2-C5-T06 pairing link safety (security m10)
- Target: `bucket-3-mobile-watch/MP-N2/tickets/MP-N2-C5-T06.md` Verification. Change: add tests "pairing starts only from the in-app scanner; `aiur-pair:` is not an OS URL scheme" and "scan result shows machine label and machine-key fingerprint and needs an explicit Pair tap (no auto-claim)". MP-N1-C4-T01 already rejects `aiur-pair` / `/pair` links and asserts no `aiur-pair` scheme registration.

## mobile → mobile parent / N4 sub-fixer: MP-N4-C4-T02 last decrypted destination (feasibility M5)
- Target: `bucket-3-mobile-watch/MP-N4/tickets/MP-N4-C4-T02.md` (iOS NSE). Change: after a successful decrypt of a `command.needs_you`, the NSE writes `{destination, at}` to the shared app-group defaults key `aiur.lastNotifiedDestination` (destination only, no summary text; overwritten each time; cleared on revoke). MP-N7-C2-T04's fallback-open path reads it through the phone broker (`get_command {latest_notified: true}`, ≤ 15 min old). Test: "successful decrypt writes lastNotifiedDestination; failed decrypt does not".

### platform → dependency-graph.json / dependency-map.md (graph owner): two new tickets (X-21)
- Add node **MP-E1-C3-T08** "Capability provider for build_queue and build_queue.build_order_source", feature MP-E1, wave 0 (merges after MP-R1-C3-T01), status blocked, `blocked_by: [DESIGN-E1, MP-E1-C3-T03, MP-R1-C3-T01]`. Dependents (soft, prose only): MP-N3 queue tile, MP-N5 queue progress options.
- Add node **MP-E7-C3-T06** "Capability provider for listener_modes", feature MP-E7, wave 3, status blocked, `blocked_by: [DESIGN-E7, MP-E7-C3-T03, MP-R1-C3-T01]`. Note: MP-R1-C3-T01 is wave 1, so no inversion.

### platform → bucket-3-mobile-watch/MP-N5 (MP-N5 owner): build-order progress gate (RC-40, X-05)
- `MP-N5-C1-T02.md:46` and every N5 reference that gates build-order progress options on capability `build_queue` (reason `build_queue_not_installed`): gate **Build Order root progress on `build_orders`** and only **queue progress on `build_queue`**. `Aiur.BuildProgress` belongs to the `build-orders` component (MP-E1-C7-T01 note), so D18's default 25 % notifications work with no queue. Also rename `Aiur.BuildQueue.progress/1` → `Aiur.BuildProgress.facts/1` / `subscribe/0` / PubSub `"build_progress"` (X-14).

## mobile → MP-E1 owner fixer: queue timer-only reconcile test (feasibility m8)
- Target: `bucket-2-platform/MP-E1/tickets/MP-E1-C3-T03.md` Verification. Add test "no event; prerequisite closed in the fake tracker; injected clock passes `build_queue.reconcile_interval_seconds`; dependent promoted exactly once". Must fail without: the fallback timer (remove it → test fails).

## mobile → owner-design (ux fixer): DESIGN-N2 lost phone (feasibility m9)
- Target: `owner-design-tasks/DESIGN-N2.md`. Add plainly: "A lost phone with no other paired device stays authorized: tokens expire but the device key mints new ones, and push keys keep decrypting. Recovery is `aiur mobile revoke` on the machine (over SSH if needed)." Recommend DESIGN-N6's optional "unlock before submit" as the default for writes.

## mobile → dependency-graph.json / dependency-map.md (graph owner): new edges from the mobile fix pass
- Add edges (all checked: no cycle, IDs exist): MP-E6-C2-T04 → MP-E6-C6-T02 (boot reconciliation enqueues cleanup, M1); MP-E6-C6-T02 → MP-E6-C4-T01 (`minutes_today/0`, M8); MP-N7-C1-T01 → MP-N1-C3-T04 (RC-38); MP-N6-C4-T02 → MP-N6-C4-T03 (shared device voice client). Non-ticket gates added: MP-N1-C2-T03 gains `RQ-TRANSPORT (RC-15)` (T-13); MP-N5-C1-T01 notes DESIGN-N5 D-2/D-4 for its default constants (T-10). MP-E5-C2-T02/C2-T03 waiver text no longer names C6 ticket IDs inside `blocked_by` (a regex parser read them as edges and found two false cycles).

## ux → MP-E4 owner: MP-E4-C6-T02 card placement (review T-8)
- Target: `bucket-2-platform/MP-E4/tickets/MP-E4-C6-T02.md` Chosen design (lines ~62-63, 77, 88). Change: replace the self-chosen "pinned at the top with 'position unknown'" / `/commands/:id` fallback wording with "placement per DESIGN-E4 decision 8 (recommended: at the anchor with a pinned 'Open Command' chip; no anchor → pinned 'position unknown'); card content per DESIGN-E2 §4". Keep the tests, but name them as implementing DESIGN-E4 decision 8.

## ux → MP-E3 owner and MP-E7 owner: Executor default mode now asked once (G-7, X1)
- Target: every MP-E3 / MP-E7 ticket or plan line that cites "OQ-E3-3" or "DESIGN-E3 decision 2" as the place the Executor default listener mode is answered. Change: cite **DESIGN-E7 E7-D8** (owner); DESIGN-E3 decision 2 is now a link. MP-E3 plan §10 OQ-E3-3: add "answered in DESIGN-E7 E7-D8".

## ux → MP-N7 owner (mobile): payload labels owned by DESIGN-N4 D-7 (G-7, X7)
- Target: `bucket-3-mobile-watch/MP-N7/tickets/MP-N7-C2-T06.md` and any MP-N7 line citing D-N7-9 as the deciding item. Change: blocked_by / prose cite **DESIGN-N4 D-7** (owner; recommended "no labels, the card opens", which means C2-T06 is not built); DESIGN-N7 D-N7-9 is now a link. Likewise MP-N6 lines citing DESIGN-N6 D-3 for watch Converse should cite DESIGN-N7 D-N7-3/4.

## ux → MP-R1 owner (platform): "registered config section" promotion criterion vs RQ4
- Target: `bucket-1-refactor/MP-R1/migration-plan.md` §5 promotion criteria ("a registered config section"). Change: after MP-R1-C4-T05 (RQ4: sections stay literal `embeds_one` in the root schema), reword the criterion to "its config section is owned in the manifest (`owns.config`)". MP-R5-C2-T02/C3-T01 now follow that reading: `Config.Schema.ElevenLabs` stays in the core `config` component and is not moved into the voice package.

## ux → MP-E2 / MP-E3 / MP-E4 owners: spike frontmatter (review G-10, RC-32)
- Target: frontmatter of MP-E2-C4-T00, MP-E2-C5-T00, MP-E3-C3-T01, MP-E4-C1-T00. Change: add `design_gate: "n/a — research spike"` (RC-32); `blocked_by` stays as is.

## security → mobile (MP-N6 owner): replaceable by precedence, actor_source shown (B2, M4, RC-41)
- Target: `bucket-3-mobile-watch/MP-N6/tickets/MP-N6-C1-T03.md` lines ~68, 74, 85. Change: `replaceable` comes from `ConflictSummary.for(decision, caller_actor)` (MP-E2-C3-T01, now arity 2) and is rank-based (`direct operator > operator_relayed > executor`, command contract §6 rule 3a), never "caller is human"; the 409 `winner` object gains `actor_source`. The controller passes `actor_source: :device` and `actor.id = "device:<id>"` to `Aiur.Commands.Answering` (a missing `actor_source` raises there). `MP-N6-C1-T01` Command view shows `actor_source` for the winning answer ("operator (unverified: no surface)" for `:rpc`, command contract §6). Add tests: "409 winner carries actor_source"; "device caller vs an undelivered relayed winner → replaceable true; vs a delivered winner → false" (must fail if `replaceable` is computed in the controller).

## security → mobile (MP-E6 owner): History principal is now a required option (M5)
- Target: `bucket-2-platform/MP-E6/tickets/MP-E6-C4-T02.md` (lines ~34, 56), `MP-E6-C4-T06.md` (~27), `MP-E6/chunks.md:159`, `MP-E6/tickets/README.md:81`. Change: every `History.list_entries(ref, opts)` call passes `principal:` (conversations contract §7; a call without it raises `ArgumentError`). Voice-assistant context reads use `principal: :internal` only when the text goes no further than the provider path that already runs `SecretRedactor` (MP-E6-C4-T03); anything rendered back to a device client uses `{:device, device_id}` (masked). Arity stays `list_entries/2`.

## security → mobile (MP-N6 owner): live entries to devices go through mask_for/2 (M5)
- Target: MP-N6 tickets that push conversation entries over a device socket or channel (C2-T03/C3-T01 per fix-log-mobile M5). Change: page reads use `History.list_entries(ref, principal: {:device, device_id}, …)`; live `{:entries_appended, …}` messages are passed through `Aiur.Conversation.History.mask_for(entries, {:device, device_id})` before push (MP-E4-C2-T01). Test: "live entry pushed to a device has the fixture token masked and redacted: true".

## security → mobile (MP-N4 owner): push signing uses sign(:push, bytes) (m6)
- Target: `bucket-3-mobile-watch/MP-N4/tickets/MP-N4-C3-T03.md` (~34-37, 76) and `MP-N4/tickets/CONTRACT-REQUESTS.md` CR-N4-2. Change: the store library exposes `Aiur.Machine.Store.sign(purpose, bytes)` with `purpose ∈ :qr | :registry | :push`; there is no `sign/1`. Push-relay calls `sign(:push, bytes)`; the `:push` tag is the push signature's existing domain tag (notification contract §4), so push vectors do not change. `:push_signer` default = `&Aiur.Machine.Store.sign(:push, &1)`.

## security → mobile (MP-N1 owner): native verifiers prepend the domain tag (m6)
- Target: `bucket-3-mobile-watch/MP-N1/tickets/MP-N1-C2-T03.md` (native-core signature verification). Change: QR signatures verify over `"aiur-qr-v1\0" <> query string without sig` and registry responses over `"aiur-registry-v1\0" <> JCS body without sig` (pairing contract §4.0/§5). The authoritative byte vectors are MP-N2-C5-T05 (`qr_uri.json`, `canonical_response.json` now record the tagged bytes; negative vectors include a registry-tagged signature presented as a QR signature). Add test "registry-tagged signature is rejected as a QR signature".

## security → mobile (MP-N3 owner): Executor aggregate ranking (RC-37)
- Target: `bucket-3-mobile-watch/MP-N3/plan.md:111-114` and `MP-N3/tickets/MP-N3-C1-T04.md:43,52-53`. Change: order is `active > idle > stalled > expired > absent > unknown` (pairing contract §7 now says so); value carries `live: true` for `active|idle` only. The "rejected: most recent consumer wins" note stays; replace "stalled if any is stalled (the case that matters)" with "a stalled consumer is shown in the per-consumer list and labelled, but one idle consumer keeps the Executor live (D9 routing, command contract §4)". Test row in C1-T04: roster `[idle, stalled]` → `idle`, `live: true`; must fail when the order puts `stalled` before `idle`.

## security → platform (MP-E7 owner): loopback is not a boundary behind a tunnel (m10)
- Target: `bucket-2-platform/MP-E7/tickets/MP-E7-C6-T01.md` (~77, 115) and its docs line. Change: add one sentence to the design and to the docs it names: "The loopback `remote_ip` check is defence in depth, not the boundary: a local tunnel or reverse proxy that forwards remote traffic to `127.0.0.1` passes it. The hook token is the boundary." Same wording as pairing contract security sibling §S3 and MP-E3-C1-T02.

## security → graph owner (dependency-graph.json / dependency-map.md): new MP-N2 edges
- Add edges (frontmatter already changed; IDs exist; whole-pack `blocked_by` cycle check run after the change: 525 tickets, 0 cycles, 0 dangling): MP-N2-C1-T04 → MP-N2-C1-T03 (RC-42 integrity check reads `paired` journal entries); MP-N2-C1-T03 → MP-N2-C3-T03 (`aiur mobile status` lists `Store.integrity/0`); MP-N2-C10-T01 → MP-N2-C6-T01 (M3 transport check reads `conn.scheme` and `HttpServer.bound_address/1`). All are wave 5 within MP-N2, so no inversion.
