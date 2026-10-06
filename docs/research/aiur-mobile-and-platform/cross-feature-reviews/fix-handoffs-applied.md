# Fix handoffs — final disposition (Phase D close-out, 2026-10-06)

One line per entry in [fix-handoffs.md](fix-handoffs.md), in file order. "already done" means
the target owner's fix log (or the file itself) shows the change; "applied" means it was
still open after all four fixers finished and was applied in this close-out pass.

1. ux → graph: edge MP-R1-C4-T05 → MP-R5-C2-T02 — already done (frontmatter carries it; graph regenerated from frontmatter).
2. platform → graph: edge MP-N2-C1-T03 → MP-R2-C7-T05 — already done (frontmatter; graph regenerated).
3. platform → pairing contract §7 aggregate order (RC-37) — already done (fix-log-security, RC-37).
4. platform → MP-N1-C3-T04 / MP-N7-C1-T01 / MP-N7-C2-T02 watch snapshot (RC-38) — already done (fix-log-mobile, RC-38).
5. platform → MP-N5 build-order progress gate (RC-40) — already done (fix-log-mobile, RC-40).
6. platform → MP-N1 `min_client_versions` (X-35) — already done (fix-log-mobile, X-35).
7. platform → MP-E2 producer attrs + notification contract `short_label` (security m3) — already done (fix-log-security m3; fix-log-mobile m3).
8. platform → U0 gate line in MP-R3..R6 (X-58) — already done (R3 by security; R4/R5/R6 by ux).
9. mobile → DESIGN-N6 §5 state keys S01–S18 — already done (fix-log-ux).
10. mobile → DESIGN-N6 D-1 watch exception — already done (fix-log-ux).
11. mobile → DESIGN-N6 voice end states + draft stale — already done (fix-log-ux).
12. mobile → MP-E6-C5-T05 device confirm attribution — already done (fix-log-mobile, handoffs received).
13. mobile → MP-N7-C1-T01 `open_on_phone` schema row — already done (fix-log-mobile).
14. platform → MP-R3 plan "two tickets" (X-47) — already done (MP-R3/plan.md:28 says two tickets).
15. platform → MP-R5-C3-T01 `prior_units` U7 (X-60) — already done (fix-log-ux, `[U7, U8]`).
16. platform → U0 gate line in R3..R6 plans and READMEs (X-58, duplicate of 8) — already done.
17. mobile → DESIGN-N5 D-2 reminder — already done (fix-log-ux).
18. mobile → DESIGN-N5 D-9 app badge — already done (fix-log-ux).
19. mobile → DESIGN-N4 D-10 lock-screen privacy — already done (fix-log-ux).
20. mobile → DESIGN-N4 keys-lost state + pinned fallback — already done (fix-log-ux).
21. mobile → DESIGN-E6 OQ6 cap default + OQ1 wording — already done (fix-log-ux).
22. mobile → DESIGN-E5 STT daily cap question — already done (fix-log-ux, E5-OQ7).
23. mobile → DESIGN-E6 typed voice error states — already done (fix-log-ux).
24. mobile → client-capability-model §7 reference + X-06 — already done (fix-log-platform RC-38, X-06; §7 defines no fields, no `events.subscribe` left).
25. mobile → DESIGN-N7 D-N7-10 — already done (fix-log-ux).
26. mobile → MP-N2-C5-T06 scanner-only pairing tests (security m10) — already done (fix-log-security m10, tests 6-8).
27. mobile → MP-N4-C4-T02 `aiur.lastNotifiedDestination` — already done (fix-log-mobile).
28. platform → graph nodes MP-E1-C3-T08, MP-E7-C3-T06 (X-21) — already done (ticket files exist; nodes appear on regeneration).
29. platform → MP-N5 RC-40 gate + X-14 rename `Aiur.BuildProgress` — already done (no `BuildQueue.progress` left outside review files).
30. mobile → MP-E1-C3-T03 timer-only reconcile test (feasibility m8) — already done (fix-log-platform).
31. mobile → DESIGN-N2 lost phone (feasibility m9) — already done (fix-log-ux).
32. mobile → graph edges (E6-C2-T04→C6-T02, C6-T02→C4-T01, N7-C1-T01→N1-C3-T04, N6-C4-T02→C4-T03; RQ-TRANSPORT on N1-C2-T03) — already done (frontmatter; graph regenerated).
33. ux → MP-E4-C6-T02 card placement (T-8) — already done (fix-log-security T-8).
34. ux → MP-E3 / MP-E7 cite DESIGN-E7 E7-D8 — already done (E3 plan OQ-E3-3 and C5-T01 by security; no MP-E7 line cites OQ-E3-3 or DESIGN-E3 decision 2, so nothing to change there).
35. ux → MP-N7-C2-T06 cites DESIGN-N4 D-7; MP-N6 watch Converse cites DESIGN-N7 D-N7-3/4 — applied (MP-N7-C2-T06 blocked_by + prose, MP-N7 tickets README; MP-N6-C5-T02 blocked_by + 3 prose lines, MP-N6 tickets README).
36. ux → MP-R1 migration-plan §5 promotion criterion "owned in the manifest (`owns.config`)" — applied (criterion 4 reworded with the RQ4 reading).
37. ux → spike frontmatter `design_gate: "n/a — research spike"` (G-10) — already done (all four tickets carry it).
38. security → MP-N6-C1-T03 `replaceable` by precedence + `actor_source` (B2, M4, RC-41) — applied (`ConflictSummary.for/2`, rank rule, `actor_source: :device`, 409 winner field, 2 tests; MP-N6-C1-T01 view `answer.actor_source` + test).
39. security → MP-E6 History `principal:` required (M5) — applied (MP-E6-C4-T02 predecessor, API row, worker design, new test; C4-T06; chunks.md; tickets README).
40. security → MP-N6 device entries through `mask_for/2` (M5) — applied (MP-N6-C2-T03 design paragraph + server-side test row; no other N6 ticket pushes entries).
41. security → MP-N4-C3-T03 / CR-N4-2 `sign(:push, bytes)` (m6) — applied (both files; also fixed residual `sign/1` in MP-N2-C1-T01, now private `raw_sign/1`, and in MP-R1 component-map).
42. security → MP-N1-C2-T03 native verifiers prepend domain tags (m6) — applied (design bullet + `registry_tagged_signature_rejected_as_qr` test).
43. security → MP-N3 Executor aggregate ranking (RC-37) — applied (MP-N3 plan §3 and MP-N3-C1-T04 rule order, `live` flag, table test `[idle, stalled] → idle`).
44. security → MP-E7-C6-T01 loopback is not a boundary (m10) — applied (design step 1 and the docs line).
45. security → graph edges MP-N2-C1-T04→C1-T03, C1-T03→C3-T03, C10-T01→C6-T01 — already done (frontmatter; graph regenerated).

Totals: 45 entries — 9 applied in this pass, 36 already done, 0 rejected.

Also closed in this pass (review findings that no fixer's set covered, not handoffs):
X-16 (MP-N3 plan capability IDs), X-33 (notification contract A-E4-1: `anchor_id` opaque,
defined by conversations §10), X-34 (MP-N4-C3-T04 and notification contract: no
unregistered `devices` / `since` capability keys), X-38 (voice-session §5.1 target
reference defined and mapped to `ConversationRef`), X-49 (MP-R5 `{:voice_error, %{code,
message}}` and `voice.stt`). Inconsistency found while applying entry 41: MP-N2-C1-T01 and
the MP-R1 component map still named a public `sign/1`; now private `raw_sign/1` and
`sign/2`. Graph: new inversion MP-E1-C3-T08 (wave 0) ← MP-R1-C3-T01 (wave 1) resolved by
`wave: 1` in the ticket (graph-check.md §4).
