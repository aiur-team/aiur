# Fix log — security fixer (Phase D)

File set: contracts command-request-and-resolution, pairing-and-instance-registry (+ -reconciliation, new -security sibling), conversations-transcripts-anchors; MP-E2, MP-E3, MP-E4, MP-N2, MP-R3.

## Privacy and security review

- B1 / RC-42 → applied: pairing §2.1 + new `pairing-and-instance-registry-security.md` §S1 (threat model, Q8 options aligned with DESIGN-N2 Q8), §S4 (integrity check); MP-N2-C1-T02 (journal callback slot), C1-T04 (`auth_key_sha256`, rotation carry, wiring test), C1-T03 (`Store.integrity/0`, `:device_unverified`, alert from instance watchers), C3-T02 (threat statement at enable; acceptance flag only if Q8 asks), C3-T03 (needs-attention listing), C9-T01 (user-words section), plan §5. DESIGN-N2 Q8 text was already written by ux.
- B2 / RC-41 → applied: command contract §4, §6 rules 1, 3, 3a, 4, 4a, 4b, 7; MP-E2-C3-T01 (precedence on supersede and revise in `handle_revision/4`, beside #3006's guard; 3 must-fail tests), C6-T01 (rule 4b guard; 4th must-fail test), C3-T02 (facade direct operator only), plan, chunks (open research resolved), README. MP-N6-C1-T03 `replaceable` handed off.
- M1 → applied: pairing §4.4 (per-instance `Store.Watcher`, no cross-BEAM broadcast), sibling §S2 latency table + direct-file-write test rule; MP-N2-C1-T03 (watcher, tests 9-10), C7-T01/C7-T02 (CR-R2-5 corrected). MP-R2-C7-T05 done by platform.
- M2 → applied: MP-N2-C6-T02 (`live_socket_id`, revoker disconnect, `handle_event` guard, 2 must-fail tests); sibling §S2 LiveView row.
- M3 → applied: pairing §4.4 + §8 (`transport.cleartext_overlay_cidrs`), sibling §S3; MP-N2-C6-T01 (transport check, tests 8-10a), C10-T01 (`bound_address/1`), C3-T01 (new key, catch-all refused), MP-R3-C1-T01 (matrix case note), C9-T01.
- M4 → applied: command contract §4 sentence, §6 `actor_source` table, §9 column; MP-E2-C3-T01 (`:rpc` default + payload-ignored tests), C3-T02.
- M5 → applied: conversations §7 (`principal` required opt, device masking, `mask_for/2`), §12; MP-E4-C2-T01 (redaction test, journal bytes unchanged), C2-T02 (principal from conn), C5-T02, plan §7; call sites in E3-C2-T01, E4-C3-T02, E4-C7-T01. E6 call sites and N6 live push handed off; phone persistence done by mobile.
- M6 → applied: conversations §5 provenance rule, `provider_input` role; MP-E4-C1-T01 (mapping + 2 tests), C5-T02 (render); MP-E3-C2-T01 (executor_operator only for validated path).
- m3 → applied: command contract §8; MP-E2-C2-T02 (attr allowlist + test). Events contract done by platform.
- m5 → applied: MP-N2-C8-T02 (writable + loopback/HTTPS rules, 3 tests). DESIGN-N2 Q5 done by ux.
- m6 → applied: pairing §4.0, §5 `sign/2`; MP-N2-C1-T03, C4-T03, C5-T01, C5-T05. N4-C3-T03 and N1-C2-T03 handed off.
- m7 → applied (device-session code): MP-N2-C6-T02 (route `log: false`, Telemetry `log:` MFA, filter_parameters, test). Voice ticket part done by mobile.
- m8 → applied: command contract §6 single spelling `device:<id>`; MP-E2-C3-T02; MP-N2-C6-T01 (`auth_actor`, test 11). E7-C3-T03 done by platform.
- m10 → applied: MP-E3-C1-T02 (`TranscriptPath.validate/3`, 4 tests), C2-T01 (path gate, boot re-validation, 2 tests); MP-N2-C5-T06 (scanner-only, confirm, tests 6-8); sibling §S3 + MP-N2-C9-T01 (proxy note). MP-E7-C6-T01 note handed off.
- m1, m2, m4, m9 → not in this set (applied by mobile/ux).
- Tests-that-can't-fail table → applied for every row in this set (N2-C6-T02, N2-C6-T01, E2-C3-T01/C6-T01, E4-C1-T01, E4-C2-T01, E3-C2-T01); R2-C7-T05 and N4-C2-T02 by others.

## RC-37

- Pairing §7 Executor aggregate → applied (`active > idle > stalled > expired > absent > unknown`, `live` flag). MP-N3 plan/C1-T04 handed off.

## Ticket depth (review-ux-and-ticket-depth.md)

- T-3 → applied: broken `env NAME=… -u …` fixed in 33 MP-N2, 17 MP-E3 and 18 MP-E4 files (E3/E4 had the same bug as `env -C src HOME=… -u …`). New form `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" [XDG_CONFIG_HOME=…] mise exec -- mix test …`; verified: old form exits 127, new form ran `test/aiur/secret_redactor_test.exs` (5 tests, 0 failures) with tokens unset.
- T-2 (N2 side) → applied: MP-N2-C6-T02 states the `bootstrap_path` flow is authoritative. N1-C4-T02 already rewritten by mobile.
- T-6 → applied: docs lines in MP-E3-C4-T03 and MP-N2-C2-T02.
- T-8 → applied: MP-E4-C6-T02 (`card_slot/2`, DESIGN-E4 decision 8).
- T-11 → applied: MP-E3-C1-T02 and E3 plan pin Codex hooks to `openai/codex` `codex-rs/hooks/src/schema.rs` @ `a9abdeaf`; subagent field set confirmed from source.
- G-10 → already applied (spike frontmatter present).
- Other T-* rows → not in this set.

## Handoffs received and applied

- X-47, X-58 → applied (MP-R3 plan, tickets README).
- ux G-7 E7-D8 → applied (MP-E3 plan OQ-E3-3, C5-T01).
- platform RC-37 pairing §7, m3 E2 producer → applied (above).

## Consistency items in this set (not handed off by anyone, applied here)

- X-10, X-13 (contract key `option_id`), X-15, X-17, X-18 (E3 part), X-20, X-36, X-37, X-39, X-51, X-55, X-56 (N2 plan parts) → applied.
- Minor fix: MP-N2-C1-T03 token prefix `aiurdt1.` corrected to `aiurd_` (C5-T03 owns the format).
- Citation fix: `claude/config.ex` permission default is line 8, not 9.

## Graph

- New `blocked_by` edges: MP-N2-C1-T04 → C1-T03, MP-N2-C1-T03 → C3-T03, MP-N2-C10-T01 → C6-T01. Whole-pack check: 525 tickets, 0 cycles, 0 dangling. MP-N2 README waves updated (C1-T03 → 4, C4-T03 → 5). Graph JSON handed off.

## Rejected

- Review text "DESIGN-E4 decision 6" for masking → used decision 4 (the actual number in DESIGN-E4).
- Review fix "`human_actor?/1` stays for supersede" style boolean → replaced by rank, per RC-41.
