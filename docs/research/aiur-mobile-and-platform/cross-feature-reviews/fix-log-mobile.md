# Fix log — mobile fixer (Phase D, 2026-10-06)

Paths relative to the pack root. "handed off" entries are in `fix-handoffs.md` under `## mobile`.

## Feasibility and failures (review-feasibility-failures.md)
- M1 → applied: contracts/voice-session.md §4.1, §6, §9, §10; MP-E6-C4-T01 (provider id before `listening`), MP-E6-C6-T02 (boot reconciliation, `daemon_restart`, enqueue), MP-E6-C2-T04 (boot caller, test), MP-E6 plan §8/§15.
- M2 → applied: MP-N6-C4-T03 rewritten to §9 depth (state table per §6/§8 code, stale draft, per-reason fixture tests); MP-N6-C5-T02/T03 scanned and fixed.
- M3 → applied: notification contract §3 (`attempt`, `summary.badge`), §6 reminder key; MP-N5 plan/C1-T01/C2-T02; MP-N4 plan §7.3, AC-N4-1, C4-T03/C5-T03, V-R5. Owner choice (30 min default) handed off (DESIGN-N5 D-2, D-9).
- M4 → applied: MP-N4/device-validation-plan.md canonical (DV-P1 split into V-I2/V-A2, V-I4, V-A2b, V-A4; V-NS1, V-M4); MP-N1/device-validation.md links; MP-N1-C10-T01; MP-N1 plan §8 row.
- M5 → applied: MP-N7 plan §7 option (a) default, (b) conditional chunk; MP-N7-C6-T01 DV-W1; MP-N7-C2-T04 fallback-open; MP-N7-C1-T01 `latest_notified`; MP-N4-C4-T02 `aiur.lastNotifiedDestination`. Owner choice handed off (DESIGN-N7 D-N7-10).
- M6 → applied: notification contract §5/§7 (`push_health`); MP-N4 plan §7.2, C4-T02, C4-T05, C5-T02, C5-T05, C3-T07; V-K1. DESIGN-N4 state handed off.
- M7 → applied: contracts/voice-session-client-errors.md (§8.1, new split file) + §8 `cost_cap` one spelling; fixture `fixtures/contract/voice/end-reasons.json`; MP-E6-C4-T01 `ClientErrors`, MP-E6-C7-T02; MP-N6-C4-T02/T03; MP-N7-C4-T04/T05; DV-W6b, V-N5. DESIGN-E6/N6 states handed off.
- M8 → applied: voice-session §9/§12; MP-E6-C3-T01 (proposed default 60 min/day, test), MP-E6-C6-T02 (crashed/open sessions count). Owner wording handed off (DESIGN-E6 OQ6); STT daily cap question handed off (DESIGN-E5).
- m1 → applied: MP-N4 platform-evidence E-F9 (RQ-N4-4 settled), plan, C5-T01, C5-T02.
- m2 → applied: MP-E6/provider-research.md §2, MP-E6-C1-T01 step 2 (RQ-E6-1 narrowed to header auth).
- m3 → applied: MP-N1 plan §5, C4-T02, C9-T01 (2018 thread non-authoritative; prototype P-x decides).
- m4 → applied: MP-N1/framework-evidence.md S16 (forum 747421, non-authoritative), plan F1 row.
- m5 → applied: voice-session §4.1; MP-E6-C2-T03 (adapter synthesizes `final`, fixture tests).
- m6 → applied: MP-N6 plan §6/OQ-N6-1, C3-T03, C5-T01; MP-N7 plan §8 (watch exception). DESIGN-N6 D-1 handed off.
- m7 → applied: MP-N1-C6-T01 (time-sensitive entitlement), MP-N4 V-I5.
- m8 → handed off (MP-E1 not in this set).
- m9 → handed off (DESIGN-N2).
- m10 → applied: MP-N4 platform-evidence E-F7, C5-T01, C5-T03, RQ-N4-9.

## Security (review-privacy-security.md)
- m1 → applied: notification contract §1/§5/§8; MP-N4-C2-T01/T02 (pin, `422 fallback_mismatch`, tests).
- m2 → applied: notification contract §1 metadata table; MP-N4 plan §7.6; MP-N1-C8-T02.
- m3 → applied: notification contract §3 and A-E2-1/A-E2-3 (short_label read from DecisionStore, "from agent" style); MP-N6 plan §5.6, C3-T01; MP-N1 plan; MP-N7-C2-T03. Feed-attr part was done by platform (events contract).
- m4 → applied: voice-session V8, §5.3 ("via voice" tag); MP-E6-C5-T02 tests; MP-N6-C4-T02/T03; MP-N7-C4-T05.
- m7 → applied (voice ticket part): voice-session §3.5 single use + filtered param; MP-E5-C8-T01 tests. Device-session code logging is MP-N2 (not this set).
- m9 → applied: notification contract §5; MP-N4-C4-T03/C5-T03, V-LS1. DESIGN-N4 D-10 handed off.
- m10 → applied: voice-session §10 system dictation row; MP-N1-C4-T01 (`aiur-pair:` scanner only); MP-N1-C8-T02, MP-N7-C4-T02, MP-N6-C4-T04 copy from §10. MP-N2-C5-T06 handed off.
- M5 (phone part) → applied: MP-N6 plan §5.6, C2-T03, C3-T01, C4-T03; MP-N1-C4-T02 (no WebView disk cache, wipe on revoke).

## Consistency / reconciliation
- RC-38 / X-03 → applied: MP-N7-C1-T01 sole schema, 16 KiB, `starting`; MP-N7-C1-T05, C2-T02; MP-N1-C3-T04 references it. client-capability-model §7 handed off.
- RC-40 / X-05 → applied: MP-N5 plan, C1-T02 (build orders gate on `build_orders`, queue on `build_queue`, test), C2-T03; MP-N4-C5-T03.
- X-09, X-12, X-14 (CR-N5-4 closed), X-18, X-32 → applied in MP-N4/MP-N5 and the notification contract.
- X-11 → applied: notification contract §3.1 `session_ref`.
- X-13 → applied: MP-N6 plan, C3-T01; MP-N7-C1-T01, C2-T06, plan (`option_id`, `custom_response`).
- X-26 → applied: MP-E6-C5-T05 (through `Aiur.Commands.Answering`, `ConflictSummary`, `via`, device attribution).
- X-35 → applied: MP-N1 plan, chunks, C3-T01, C3-T03, C5-T01, C5-T03 (`min_client_versions`).
- X-52 → applied: MP-E5 plan, chunks (capability shape, `not_configured`, send returns `delivery_id`), MP-E5-C8-T01 (RC-30 dependent removed).
- X-53 → applied: MP-E6 plan (`opts[:origin]`, blockers at chunk level, namespace settled); MP-E5 plan blockers at chunk level.
- X-56 → applied: MP-N1 plan (closed reason enum, payload shape), MP-N4 plan (`instance_id`, channel vs category ids), MP-N5 plan (keys, single writer), MP-N6 plan (push optional, outcome names), MP-N7 plan (unavailable ≠ hidden, MP-E5-C8 refs).
- X-06 → handed off (client-capability-model, not this set).

## Ticket depth (review-ux-and-ticket-depth.md)
- T-1 (17 placeholders) → applied: MP-N4-C3-T07, C4-T03, C5-T03; MP-N5-C4-T01..T03; MP-N6-C2-T02, C3-T01, C3-T02, C4-T01..T04, C5-T01, C5-T03, C6-T01 (plus C2-T03, C3-T03); MP-N7-C2-T03.
- T-2 → applied: MP-N1-C4-T02 rewritten to `bootstrap_path` (MP-N2-C6-T02); N1-RQ5 retired.
- T-5 → applied: MP-N6-C5-T01/T03 "Must fail without" columns.
- T-6 → applied: MP-E6-C4-T01, MP-E6-C8-T03, MP-N6-C1-T03, MP-N7-C3-T04, MP-N5-C2-T01, MP-N5-C1-T04 (and others).
- T-7 → applied: MP-E5-C2-T01 (R-1 text), MP-E6-C3-T03 (missing test row).
- T-9 → applied: MP-E6-C8-T03 rewritten to full §9.
- T-10 → applied: MP-N5-C1-T01 gated default constants on DESIGN-N5 D-2/D-4.
- T-11 → applied: MP-N4-C5-T03 (dated developer.android.com page required before unblock).
- T-12 → applied: MP-N7-C3-T05 (Robolectric; instrumentation-arg form for emulator).
- T-13 → applied: MP-N1-C2-T03 `RQ-TRANSPORT (RC-15)`.
- T-3 → n/a in this set (no broken `env HOME=… -u` command in N4/N5/N6/N7/E5/E6 tickets; new commands use the isolated form).

## Handoffs received and applied
- N6 sub-fixer → MP-E6-C5-T05 device attribution: applied. N6 → MP-N7-C1-T01 `open_on_phone`: applied. N7 → MP-N4-C4-T02 `aiur.lastNotifiedDestination`: applied. Platform → MP-N1/N5/N7 (RC-38, RC-40, X-35) and notification contract (security m3): applied.
- New graph edges handed off to the graph owner.
