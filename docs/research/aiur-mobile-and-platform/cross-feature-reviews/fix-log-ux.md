# Fix log — ux fixer (Phase D fix pass, 2026-10-06)

File set: `owner-design-tasks/*`, `cross-feature-reviews/owner-questions.md`,
`bucket-3-mobile-watch/MP-N3/`, `bucket-1-refactor/MP-R4/`, `MP-R5/`, `MP-R6/`.
Source review: [review-ux-and-ticket-depth.md](review-ux-and-ticket-depth.md) unless noted.

## Review findings

- G-1 → applied (DESIGN-N4 D-8 publisher and relay operator with options a/b/c and rec (a); D-9 mailbox, rec defer; both in acceptance; DESIGN-R4 Q2 points at N4 D-8).
- G-2 X8 → applied (DESIGN-N2 §transport owns it; options i/ii/iii; rec (ii) off by default, opt-in diagnostics, security M3 restrictions; DESIGN-N1 D-N1-6 now links). Recorded as a recommendation, not a decision.
- G-2 X9 → applied (DESIGN-R5 §2 owns it for every surface; rec disabled with reason, per the capability rule; DESIGN-E5 E5-OQ4 keeps only the no-key half and links). Recommendation, not a decision.
- G-3 → applied (acceptance lists in DESIGN-E3, E6, E7, N1, N7 now cover every decision; also E1, E4, E5, N2, N3, N4, N5, N6).
- G-4 → applied (DESIGN-R4 §5, DESIGN-R5 §5 acceptance sections).
- G-5 → applied (DESIGN-N5 D-9 app badge + surface row; DESIGN-N3 Q5 links; DESIGN-N3 §1 links DESIGN-E2 §6 item 2).
- G-6 → applied (every gate question now has options where needed and a recommendation with a one-line reason: E1 OQ-4 colour, E1-PLACE, E1-COPY draft table; E2 4.1a, 4.2b, 6.3–6.5, 6.9, 6.10; E3 1, 3–9; E4 1–8; E5 OQ1, OQ6, OQ7; E6 OQ7 single pick, OQ9; E7 D1–D8, OWNER-NPM, UI items; N1 D-N1-8, PROTO, FRAME; N2 Q2–Q8; N3 Q1–Q3, Q6; N5 D-7; N6 D-1–D-5; N7 D-N7-3, D-N7-6; R2 KQ-R2-1/2; R3 Q2; R6 Q1/Q2; R7 Q1/Q2).
- G-7 → applied (single owners: X1 → DESIGN-E7 E7-D8 (new), E3 decision 2 links; X3 → DESIGN-N2 Q6, N3 Q4 links; X5 → DESIGN-N7 D-N7-3/4, N6 D-3 links; X6 → DESIGN-E2 §6 item 5, N6 D-4 narrowed to the watch fallback; X7 → DESIGN-N4 D-7, N7 D-N7-9 links).
- G-8 → applied (DESIGN-E6 states: mic permission denied, history loading).
- G-9 → applied (DESIGN-E3 shows plan IDs OQ-E3-n beside each question).
- G-10 → handed off (spike frontmatter in MP-E2/E3/E4 tickets; fix-handoffs.md).
- New: DESIGN-N2 Q8 same-user self-pairing (security B1, RC-42) → applied; options (0)/(a)/(b)/(c), rec (c) + integrity alert by default, (a) documented.
- KQ-R2-1 text contradiction (§1.2 R2 note) → applied (DESIGN-R2).
- T-3 → applied (8 MP-N3 tickets now use `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test …`). Verified: old form exits 127; new form unsets both tokens, sets both dirs, and `mise exec -- mix --version` / `mix help test` run with exit 0 in the worktree. A full `mix test` was not run: the worktree has no `deps/` or `_build/`.
- T-5 → applied (MP-N3-C5-T01 per-test "must fail without" table and mutation line; MP-N3-C4-T06 says mutation n/a and docs none).
- T-8 → applied in gate (DESIGN-E4 decision 8 card placement); ticket change handed off (MP-E4-C6-T02).
- MP-R5-C2-T02 MINOR (design conditional on MP-R1-C4-T01) → applied: one chosen design per MP-R1-C4-T05 RQ4 (embed stays literal; voice owns `elevenlabs` in the manifest; `init` contribution registry); blocked_by + MP-R1-C4-T05; tests and completion grep updated; MP-R5-C3-T01, tickets README and plan aligned. Graph edge and R1 migration-plan wording handed off.
- T-1, T-2, T-4, T-6, T-7, T-9, T-10, T-11, T-12, T-13 → not in my set (tickets/README of other features); no change here.
- MP-R4, MP-R6 ticket depth → PASS in the review; no change needed.

## Handoffs received (fix-handoffs.md)

- platform X-58 (U0 gate line) → applied for MP-R4, MP-R5, MP-R6 plan.md and tickets README. MP-R3 is not in my set.
- platform X-60 → applied (MP-R5-C3-T01 `prior_units: [U7, U8]`).
- mobile DESIGN-N6 §5 state keys S01–S18 → applied.
- mobile DESIGN-N6 D-1 watch exception → applied.
- mobile DESIGN-N6 voice end states + draft stale → applied.
- mobile DESIGN-N5 D-2 reminder (feasibility M3) → applied (setting values, §2 row, acceptance).
- mobile DESIGN-N5 D-9 badge → applied (blocking "needs you" Commands, `summary.badge`).
- mobile DESIGN-N4 D-10 lock screen (security m9) → applied (options (a)/(b), V-LS1, D-6 optional under (a)).
- mobile DESIGN-N4 §4 keys-lost state and §1 pinned fallback (feasibility M6, security m1) → applied.
- mobile DESIGN-E6 OQ6 cap and OQ1 wording (feasibility M8, security m4) → applied.
- mobile DESIGN-E5 STT daily cap → applied (E5-OQ7, rec none in v1).
- mobile DESIGN-E6 typed voice error states (feasibility M7) → applied.
- mobile DESIGN-N7 D-N7-10 DV-W1 fallback (feasibility M5) → applied.
- mobile DESIGN-N2 lost phone (feasibility m9) → applied (Q4; N6 D-2 rec changed to unlock before submit).
- Also applied directly, as they land in gate files: security m5 (N2 Q5 hiding rules), security M5 (E4 decision 4 masking), feasibility m7 (N4 D-3 capability note), X-57 (N5 D-1 amends D18), directory item 4 (DESIGN-R1 §1 confirm box). X-31 (DESIGN-E7 trailing markup) was already fixed.

## owner-questions.md

Regenerated as one de-duplicated list: §0 top 9, §1 one owner per shared question (X1–X10,
both contradictions marked as recommendations), §2–§4 grouped by gate with each
recommendation. 164 questions, every one with a recommendation.
