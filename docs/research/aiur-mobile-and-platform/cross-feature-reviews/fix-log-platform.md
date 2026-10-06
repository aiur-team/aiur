# Fix log — platform fixer (Phase D)

Scope: contracts/{identity-and-capabilities, events-and-replay, listener-mode, harness-adapter, queue-readiness-and-build-progress, client-capability-model}.md; bucket-1-refactor/MP-R1, MP-R2, MP-R7; bucket-2-platform/MP-E1, MP-E7. Canonical names used across all edits: scratchpad `platform-canon.md` (C1–C11), summarised in the RC lines below. Handoffs: `fix-handoffs.md` headings `### platform → …`.

## Coordinator decisions

- RC-36 (X-01) → applied (component-map listener-modes required + listener-spec row; listener-mode.md "Two parts" + §11; harness-adapter.md; client-capability-model §5; identity §2.3; capability-matrix; MP-E7 plan/chunks/README/C1-T04/C2-T03/C3-T02/C3-T03; MP-R7 plan)
- RC-37 (X-02) → applied (identity §1.4 live = active|idle + aggregate order; MP-R1-C3-T02); pairing §7 reorder handed off
- RC-38 (X-03) → applied (client-capability-model §7 now references MP-N7-C1-T01, 16 KiB); N1-C3-T04 / N7 handed off
- RC-39 (X-04) → applied (component-map: no L1–L3 row lists web-shell, new L1 `web-kit`, web-shell Opt = downward composition edges; identity §2.1; MP-R1-C6-T01 rule 6, C6-T02, C1-T06, C3-T03, migration S11)
- RC-40 (X-05) → applied (component-map build-orders owns Aiur.BuildProgress; queue-readiness §4.0; events §9; client-capability-model §5; capability-matrix; MP-E1-C7 tickets/chunks/plan); MP-N5 gating handed off
- RC-24 (X-22) → applied (MP-R1-C8-T04 item 1 dropped, blocked_by + MP-R1-C5-T03; C5-T03 "settled by RC-24"; READMEs)
- CR-C8-3 (X-23) → applied (component-map commands required, synchronous delivery port; migration S10; matrix minimum set)
- RC-31 (X-08) → applied (events §11; MP-R2 plan §4.4, MP-R2-C5-T01)
- X-58 (RC-19 U0 gate) → applied (MP-R1 plan + migration S0 + READMEs; MP-R2, MP-R7 plan + README; events §11); MP-R3–R6 handed off

## Consistency findings (X-*)

- X-06 → applied (client-capability-model §6 events.export)
- X-07 → applied (events §8, §10 unavailable/disabled; client-capability-model §6/§8; matrix; MP-R2-C7-T03 already consistent)
- X-09 → applied (events §9 no `.milestone`; queue §6; MP-R2-C5-T03 + test; MP-E1/E7 clean)
- X-10..X-18, X-20, X-26, X-32, X-33, X-36..X-39, X-49, X-51..X-53, X-55..X-57 → not in platform set (other fixers' files)
- X-18, X-34 → not applied: no new reason/attribute registered in identity §2.2 for them; reviewer's preferred fix (map at provider / remove) lands in E3/N3/N4 files
- X-19 → applied (capability-matrix orchestration row)
- X-21 → applied (new MP-E1-C3-T08, MP-E7-C3-T06 with full §9 bodies; identity §2.3 provider table + reasons store_unavailable, writes_paused, spec_invalid; matrix; queue §6/§8); graph nodes handed off
- X-24 → applied (component-map orchestration Opt names Hints and ClaimProbe seams, C1-T06)
- X-25 → applied (MP-E7 plan)
- X-27 → applied (capability-matrix; component-map pairing-discovery/push-relay drop web-shell)
- X-28 → applied (component-map + matrix voice-conversation Req listener-modes, Opt commands/conversations)
- X-29 → applied (component-map planned rows machine-gateway, notification-policy, relay-service, listener-spec; migration-plan planned table; plan.md acceptance 1 adds services/; component-directory §7)
- X-30 → applied (component-map binary kind in every row; MP-R1-C1-T01 note)
- X-31 → verified (no leftover markup in my contracts, MP-R7, MP-E7); DESIGN-E7 not in set
- X-35 → applied (identity §3 rule 3, client-capability-model §4 rule 4 needs_update with target); MP-N1 handed off
- X-40 → applied (listener-mode §5 target {instance_id, ticket})
- X-41 → applied (component-map `~/.aiur/machine` owners)
- X-42 → applied (component-map voice-stt `Aiur.Voice`, voice:dictate/converse; listener home; watch-apps RC-17; matrix executor.conversation provider)
- X-43 → applied (component-map dashboard-ui Opt streamdeck-server)
- X-44 → applied (component-directory §6)
- X-45 → applied (MP-R1-C10-T01 added_by + I4 exemption; component-map aiur-contracts/web-kit added_by MP-R1)
- X-46 → applied (MP-R1-C10-T01/T04 template IDs + fixtures; C3-T06 patterns)
- X-47 → applied MP-R1 part (CONTRACT-REQUESTS-C6-C11, plan CQ1); MP-R3 plan handed off
- X-48 → applied (MP-R2-C6-T02, C6-T05 Signal.alert/2)
- X-50 → applied (MP-E1 plan, chunks)
- X-54 → applied (MP-E7 plan, chunks)
- X-59 → applied (MP-R1-C11-T03)
- X-60 → applied (migration-plan §3 S7/U4, S5/S13/U2; MP-R1-C8-T08; MP-R2 plan prior_units list); MP-R5-C3-T01 handed off; N4/N5/N6 prior_units not in set
- X-61 → not in set (dependency-map, graph owner)

## Security, feasibility, ticket depth

- Security M1 → applied (MP-R2-C7-T05 per-instance watcher design, test 3 rewrites devices.json with no broadcast, blocked_by + MP-N2-C1-T03); graph edge handed off
- Security m3 → applied (events §9 human-needed attrs drop short_label; MP-R2-C5-T03, C7-T04); E2 producer + notification contract handed off
- Security m8 → applied (MP-E7-C3-T03 device_id attribution test)
- Feasibility m8 → applied (MP-E1-C3-T03 timer-only reconcile test + mutation)
- T-4 → applied (17 MP-R1 tickets `$TESTCMD`; MP-R7-C3-T01/T03; 51 MP-E1/E7 files; canonical `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME=… XDG_CONFIG_HOME=…`)
- T-5 → applied (MP-E1-C9-T02 "n/a — docs only")
- T-7 → applied (MP-R2-C5-T02 12 keys; MP-R2-C6-T02/T03/T04 + C7-T01 one `Export.read/4` signature; MP-R7-C3-T01 counts; MP-E1-C4-T01 self edge refused; MP-E7-C4-T02 wake_now?/2; MP-E7-C1-T01 steerOnly)
- T-9 → applied (MP-R7-C3-T06 rewritten to full §9 body)
- T-11 → applied (MP-E7-C4-T02 cite marked for re-verification at a pinned openai/codex SHA)
- R1 sample fixes → applied (MP-R1-C3-T02 "five" providers)
- RC-22 → verified (Gemini/ACP row in harness-adapter.md, MP-R7 plan, C4-T04)
- G-3 (OWNER-NPM in DESIGN-E7) → not in set (ux fixer)

Checks run: every file in the set < 500 lines; every `blocked_by` ID in MP-R1/R2/R7/E1/E7 exists and is two-digit; no cycle across all 525 tickets.
