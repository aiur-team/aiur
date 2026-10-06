# Phase D cross-review — owner design gates and ticket depth

- **Reviewer:** independent Phase D cross-reviewer, read-only.
- **Date:** 2026-10-06. **Base:** `45a290e3`.
- **Scope:** brief §8 (owner UX gates) and brief §9 (ticket depth).
- **Inputs:** [brief.md](../brief.md) §3–§9, [context-and-decisions.md](../context-and-decisions.md),
  [feature-inventory.md](../feature-inventory.md), [phase-b-reconciliation.md](phase-b-reconciliation.md),
  all 21 [`owner-design-tasks/DESIGN-*.md`](../owner-design-tasks/), every plan's open-questions
  section, and 87 sampled tickets.
- **Not reviewed:** ticket ID renames and `blocked_by` edits, which another agent was making at
  the same time.

The consolidated owner-question list is in [owner-questions.md](owner-questions.md).

## 0. Verdict

| Area | Result |
|---|---|
| Brief §8 named design areas covered | **11 of 11.** Every area has a gate. |
| Gates with all §8 parts (what, surfaces, decisions, states, acceptance, "blocked until approved") | **19 of 21.** DESIGN-R4 and DESIGN-R5 have no acceptance-conditions section. |
| Owner questions answerable as "option + recommendation" | **About 112 of 152.** About 40 have no recommendation in the pack. |
| Owner items missing from their gate | **3.** OQ-N4-1 (publisher and relay operator) and OQ-N4-2 (response mailbox) are not in DESIGN-N4. R4-Q2 forwards to DESIGN-N4, which has no matching item. |
| Contradictions between shared gates | **2.** X8 (HTTP-degraded mode, N1 vs N2) and X9 (voice not installed, R5 vs E5). |
| Acceptance lists that drifted from their decision lists | **4.** E3, E6, E7 and N7, plus N1 for OWNER-AUTH-N1-PROTO. |
| Ticket depth, 87-ticket sample (≥ 4 per feature, largest and smallest included) | **PASS 40 · MINOR 40 · FAIL 7.** 92 % are usable after small fixes. |
| Tickets with all nine §9 headings | **522 of 523** (mechanical scan of every ticket). The exception is MP-R7-C3-T06. |
| `file:line` citations checked at `45a290e3` | **56 checked:** 54 accurate, 2 with a range off by 1–2 lines, **0 wrong.** |

The main blockers for readiness:

1. **DESIGN-N4 does not contain OQ-N4-1.** That is the "main mobile blocker" according to the
   reconciliation, and it holds the relay deployment and the device run.
2. **About 17 MP-N4–N7 tickets are design-blocked placeholders.** They have no test file and no
   command. 11 of them are in MP-N6.
3. **MP-N1-C4-T02 contradicts its own blocker MP-N2-C6-T02** on the session bootstrap shape.
4. **The isolated-HOME test command is broken in 41 files.** It exits 127.

## 1. Part 1 — owner design gates (brief §8)

### 1.1 Coverage of the brief's named design areas

| Brief §8 area | Gate(s) | Covered? | Note |
|---|---|---|---|
| Setup / pairing | DESIGN-N2 | Yes | Includes §transport (RQ-TRANSPORT). App first-run flow is shared with DESIGN-N1. |
| Meta-dashboard | DESIGN-N3 | Yes | No recommendation on any of the six questions (G-6). |
| Per-instance navigation | DESIGN-N3 §3, DESIGN-N1 §3.1–3.2 | Yes | N1 owns the frame and header; N3 owns the return path and the per-instance inbox link. |
| Executor conversation | DESIGN-E3 | Yes | Executor-specific. Rendering is delegated to E4. |
| Worker conversations | DESIGN-E4 | Yes | |
| Event navigation | DESIGN-E4 | Yes | R6-Q2 seeds the grouping rule. |
| Command requests and responses | DESIGN-E2 (normative), DESIGN-N6 (phone and watch layout) | Yes | Best example of linking: N6 §1 explicitly does not redefine E2 §4–§6. |
| Voice controls | DESIGN-E5 (owns the D16 choice for every client) | Yes | |
| Conversational mode | DESIGN-E6 | Yes | |
| Notification presentation | DESIGN-N4 | **Partly** | Presentation is covered. The publisher and relay-operator decision is missing (G-1). |
| Notification preferences | DESIGN-N5 | Yes | No item for the app badge that DESIGN-N3 hands off to it (G-5). |
| Build-queue surfaces | DESIGN-E1 | Yes | CLI, read-only dashboard view, GitHub marker, attention copy. |
| Watch interactions | DESIGN-N7 | Yes | Scope fence (no pause, resume or spawn) is restated, and an acceptance control inventory checks it. |
| Listener modes (added in brainstorm) | DESIGN-E7 | Yes | Not in the brief's list. Correctly gated because it changes send behaviour (D13). |
| Pure refactor (R1–R7) | DESIGN-R1…R7 | Yes | See §1.3. |

### 1.2 Per-gate checklist

Legend: **Y** present · **P** partly · **N** missing · **n/a** justified as not applicable.
"Recs" is the share of the gate's owner questions that carry a recommendation.

| Gate | What | Surfaces | Decisions | Recs | States | Accept. | Blocked line | Shared links | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| R1 | Y | Y (S1–S5 + directory page) | Y | 14/14 | Y (static page; n/a reasons given) | Y | Y | N3, N5, E1 | PASS |
| R2 | Y | Y (config and CLI only) | Y | 6/6 | Y (7 CLI/API states) | Y | Y | E4 | PASS (KQ-R2-1 text contradicts S1 default) |
| R3 | Y | Y (docs only) | Y | 3/4 | n/a (justified) | Y | Y | N2 §transport | PASS |
| R4 | Y | Y | Y | 4/4 | n/a (justified) | **N** | Y | N4 (dangling, G-1) | MINOR |
| R5 | Y | Y | Y | 5/5 | Y | **N** | Y | E5, E6 | MINOR (X9 conflict) |
| R6 | Y | Y | Y | 1/3 | n/a | Y | Y | E4 | PASS |
| R7 | Y | Y | Y | 1/3 | n/a | Y | Y | E7 | PASS |
| E1 | Y | Y (CLI, view, marker) | Y | 8/10 | Y (all 8 + item-level) | Y | Y | N3, N5 | PASS |
| E2 | Y | Y (8 surfaces) | Y | 10/12 | Y | Y | Y (backend-only carve-out asked as §6.9) | N6, E5, E4, N3, N4/N5, R6 | PASS |
| E3 | Y | Y | Y | **1/9** | Y (15 states) | P (acceptance says "Decisions 1–8"; 9 exist) | Y | E4, E7, E2, E5, N3 | MINOR |
| E4 | Y | Y | Y | 1/7 | Y (15 states) | Y | Y | E3, E2, E5, E7, N6 | MINOR |
| E5 | Y | Y (5 surfaces) | Y | 6/7 | Y | Y | Y (C1, C2 carve-out) | E6, E2, E3, N6, N7, R5 | MINOR (X9 conflict) |
| E6 | Y | Y | Y | 10/11 | P (no mic permission-denied state, no history-loading state) | P (acceptance says "OQ1..OQ9"; OQ10–11 exist) | Y | E5, E2, E3, E4, E7, N6/N7 | MINOR |
| E7 | Y | Y | Y | 3/8 | Y (13 states) | P (acceptance says "D1…D7"; OWNER-NPM-FIRST-PUBLISH omitted) | Y | E3, E4, E5, N6 | MINOR |
| N1 | Y | Y | Y | 9/10 | Y | P (acceptance says "D-N1-1..8"; OWNER-AUTH-N1-PROTO omitted) | Y | N2–N7, E5/E6 | MINOR (X8 conflict) |
| N2 | Y | Y | Y | 6/9 | Y | Y | Y | N1, N3, N4/N5, N7 | PASS |
| N3 | Y | Y | Y | **0/6** | Y (13 states, including per-field unavailable, disabled and zero) | Y | Y | N1, N2, E3, N5, N7 | MINOR |
| N4 | Y | Y | **P** (OQ-N4-1 and OQ-N4-2 absent) | 6/7 | Y | Y | Y | N5, N6, N7, N2, E2 | **FAIL** until G-1 is fixed |
| N5 | Y | Y | Y | 7/8 | Y (no "save failed" distinct from conflict) | Y | Y | N4, N3, E2, N7 | PASS |
| N6 | Y | Y | Y | 4/5 | Y (17 states; "delivery failed" inherited from E2 §4.4) | Y | Y (needs E2 and E5 too) | E2, E5, N7, N4, E4 | PASS |
| N7 | Y | Y | Y | 7/9 | Y | P (acceptance says "D-N7-1..D-N7-8"; D-N7-9 omitted) | Y | N6, E2, E5/E6, N3, N4 | MINOR |

### 1.3 Pure-refactor gates

DESIGN-R2, R3, R4, R6 and R7 do what brief §8 asks. Each opens with a checkbox confirmation of "no
user-facing change". Each lists the exact surfaces that must stay identical. Each says "no new screens,
no new states" instead of inventing them. Their only decisions concern real operator-visible
configuration or docs copy.

DESIGN-R1 and DESIGN-R5 legitimately add surfaces:

- DESIGN-R1 adds the MP-REQ4 directory page and the capability CLI and API. RC-12 tags them as
  Bucket-2 enabling work.
- DESIGN-R5 adds a new "not installed" state.

Both keep these additions separate from the "no change" confirmation. **No invented screens were
found.**

### 1.4 Findings

**G-1 (blocking) — DESIGN-N4 lacks the publisher and relay-operator decision.**
- Reconciliation § Owner items says OQ-N4-1 is "listed in DESIGN-N4" and is "the main mobile
  blocker". It is not in DESIGN-N4.
- OQ-N4-2 (the encrypted response mailbox) is also absent.
- DESIGN-R4 Q2 says "Forwarded to DESIGN-N4 / MP-N4; answer there", but there is nothing in DESIGN-N4
  to answer.
- [dependency-map.md](../dependency-map.md) counts 7 tickets on OQ-N4-1 (MP-N4-C2-T06, C2-T07, C7-T02,
  and N1 distribution).
- **Fix:** add a §3 row "D-8 Publisher and default relay operator (OQ-N4-1)" with options:
  - aiur-team org accounts and a hosted relay;
  - self-built apps only;
  - Kevin's personal accounts.

  Add D-9 for OQ-N4-2, with the plan's "defer" as the recommendation. Add both to the acceptance
  list.

**G-2 (blocking for consistency) — two gates recommend opposite answers to one question.**
- **X8, HTTP-degraded mode.**
  - DESIGN-N1 D-N1-6 recommends "Allow, with a persistent warning and the WebView mic off".
  - DESIGN-N2 §transport recommends "T-A, with the overlay flag off by default" and asks whether to
    keep or remove the mode.
  - **Fix:** DESIGN-N2 owns RQ-TRANSPORT (RC-15). Make N1 D-N1-6 a link to N2 §transport with the
    same recommendation.
- **X9, voice package not installed.**
  - DESIGN-R5 §2 recommends "disabled with reason".
  - DESIGN-E5 E5-OQ4 recommends "hidden when the package is not installed".
  - The answer changes MP-R5-C1-T04's dependency on MP-E5-C2 (CR-R5-2).
  - **Fix:** ask the question once, in DESIGN-R5, because R5 ships first. E5-OQ4 keeps only the
    no-key half.

**G-3 — acceptance lists drifted after Phase D added decisions.** Phase D added questions to five
gates without extending their acceptance lists. A gate could therefore be "approved" with its newest
decision unanswered, and that decision is often the one that blocks a ticket by name.

| Gate | Acceptance list | Decision it omits |
|---|---|---|
| DESIGN-E3 | "Decisions 1–8" | Q9 hook install, which blocks MP-E3-C1-T04 |
| DESIGN-E6 | "OQ1..OQ9" | OQ10 and OQ11 |
| DESIGN-E7 | "E7-D1…D7" | OWNER-NPM-FIRST-PUBLISH, which blocks MP-E7-C1-T03 |
| DESIGN-N7 | "D-N7-1..8" | D-N7-9 |
| DESIGN-N1 | "D-N1-1..8" | OWNER-AUTH-N1-PROTO |

**Fix:** change each list to "every decision in §N".

**G-4 — DESIGN-R4 and DESIGN-R5 have no acceptance-conditions section.** Brief §8 requires one.
R3, R6 and R7 each have a one-line "complete when every box is ticked". **Fix:** add the same line.

**G-5 — two cross-gate handoffs have no receiver.**
- DESIGN-N3 Q5 (app-icon badge) says "decide with DESIGN-N5", but DESIGN-N5 has no badge item.
- DESIGN-N3's Commands count does not cite DESIGN-E2 §6.2, which defines which Commands count:
  "Needs you" or all open. That definition determines the meta-dashboard number.
- **Fix:** add the badge to DESIGN-N5 §3, or make N3 the sole owner. Link N3 §1 to E2 §6.2.

**G-6 — about 40 owner questions have no recommendation.** Brief §8 asks that every question be
answerable. The gaps cluster in four places:
- DESIGN-E3: 8 of 9 have none.
- DESIGN-E4: 6 of 7 have none. Q1 is legitimately "yours to design".
- DESIGN-N3: none of 6 has one.
- DESIGN-E7: D2, D3, D6, D7 and OWNER-NPM have none.

Plan text often holds the rationale (for example, E3 plan §10), but the gate does not state a pick.

Some recommendations are menus that still need a single pick:
- E6-OQ7 offers two LLMs.
- N7 D-N7-6 says "your devices decide".
- E5-OQ6 says "your call".

[owner-questions.md](owner-questions.md) supplies a labelled *reviewer default* for each gap. The gate
files should adopt or replace them.

**G-7 — the same question is asked in two gates.** Each pair links the gates but does not name a
single owner:

| Question | Asked in |
|---|---|
| Executor default listener mode | E3 Q2, E7 §1.7 |
| Stopped-instance retention | N2 Q6, N3 Q4 |
| Watch Converse | N6 D-3, N7 D-N7-3/4 |
| Multi-question layout | E2 §6.5, N6 D-4 |
| Payload option labels | N4 D-7, N7 D-N7-9 |

The risk is two different answers. **Fix:** keep the question in one gate and replace the other with
"see DESIGN-X §Y". owner-questions.md §1 names the proposed owner for each.

**G-8 — DESIGN-E6 states omit two cases.**
- "Microphone permission denied" is missing. It is distinct from "Unavailable", and E5 and N7 both
  have it.
- "History loading" is missing; only "Empty history" exists.

**G-9 — numbering crosswalk.** DESIGN-E3 numbers its questions 1–9, while MP-E3 plan §10 uses
OQ-E3-1…6 in a different order (OQ-E3-2 = Q4, OQ-E3-3 = Q2). Tickets cite "OQ-E3-6". It happens to
match Q6, but the mapping is fragile. **Fix:** put the plan ID beside each gate question, as
DESIGN-E7 does ("E7-Q<n> is recorded as E7-D<n>").

**G-10 (minor) — research spikes are not marked in their frontmatter.** RC-32 says spikes "carry
`design_gate: n/a — research spike`". The four spikes (MP-E2-C4-T00, MP-E2-C5-T00, MP-E3-C3-T01 and
MP-E4-C1-T00) say this only in their body. Their frontmatter has `blocked_by: []` and no
`design_gate` key. Every other sampled ticket names its DESIGN gate.

**Strengths worth keeping:**
- E2 §4 is a normative shared presentation that N6 and E5 defer to. E5 likewise owns the mic choice
  for every client.
- Every gate opens with "what already exists, do not redesign by accident", with citations. 17 of
  those citations were checked, and all 17 are accurate (§2.4).
- N3 and N7 make "unavailable / stale / unreachable ≠ 0" an acceptance condition.
- N2 forbids implying that network reachability grants access, and forbids implying that revocation
  erases data.

## 2. Part 2 — ticket depth (brief §9)

### 2.1 Method

- **Mechanical scan of all 523 ticket files.** Checks: the nine headings, `file:line` regex hits,
  mutation wording, `website/docs-app` mentions, generic "add appropriate tests" wording, and a
  DESIGN gate reference.
- **Deep read of 87 tickets.** The sample took the largest and smallest ticket per feature plus 2–3
  random ones, and every ticket for MP-R3, R4 and R6. Every feature has ≥ 4 sampled tickets except
  R3 (2 exist), R4 (1 exists) and R6 (3 exist). Cross-cutting tickets included: MP-R1-C10-T01,
  MP-R2-C6-T02, MP-E2-C1-T01, MP-E4-C1-T00, MP-E7-C4-T02, MP-N1-C4-T02, MP-N2-C10-T01 and
  MP-N4-C1-T01.
- **Each sampled ticket was graded** on the nine sections, real evidence, a single chosen design,
  concrete tests, a mutation statement, a docs page or a justified "none", and concrete non-happy
  paths.
- **Grades:** PASS meets §9. MINOR needs a one-to-three-line fix. FAIL means an implementer would
  have to invent something.

Scan results: no ticket contains generic "add appropriate tests" wording, and every ticket except
the four spikes in G-10 names a DESIGN gate. The scan's mutation heuristic under-reported
(see T-5).

### 2.2 Results by feature (sampled)

| Feature | Sampled | PASS | MINOR | FAIL | Notes |
|---|---|---|---|---|---|
| MP-R1 | 5 | 3 | 2 | 0 | `$TESTCMD` placeholder; "six provider modules" vs 5 listed |
| MP-R2 | 5 | 3 | 2 | 0 | C5-T02 key count 13 vs 12; C6-T02/T03/T04 read-signature disagreement |
| MP-R3 | 2 | 2 | 0 | 0 | C1-T01 is a model ticket |
| MP-R4 | 1 | 1 | 0 | 0 | |
| MP-R5 | 4 | 3 | 1 | 0 | C2-T02 design conditional on MP-R1-C4-T01 |
| MP-R6 | 3 | 3 | 0 | 0 | |
| MP-R7 | 4 | 1 | 2 | 1 | **C3-T06 FAIL** (3 sections missing); test commands omit isolated HOME |
| MP-E1 | 5 | 2 | 3 | 0 | C4-T01 contradicts itself on a self edge; C9-T02 has no mutation statement |
| MP-E2 | 5 | 3 | 2 | 0 | C1-T01 is a model ticket (runnable revert steps) |
| MP-E3 | 4 | 2 | 2 | 0 | C4-T03 has no docs line |
| MP-E4 | 4 | 3 | 1 | 0 | C6-T02 decides card placement that DESIGN-E4/E2 own |
| MP-E5 | 4 | 2 | 2 | 0 | C2-T01 stale "if R-1 accepted" text |
| MP-E6 | 5 | 1 | 3 | 1 | **C8-T03 FAIL** (skeleton) |
| MP-E7 | 5 | 1 | 4 | 0 | C4-T02 names `deliver_now?/3` vs `wake_now?/2`; C7-T02 is still a menu |
| MP-N1 | 5 | 2 | 2 | 1 | **C4-T02 FAIL** (contradicts MP-N2-C6-T02) |
| MP-N2 | 5 | 0 | 5 | 0 | All five use the broken `env … -u` command |
| MP-N3 | 4 | 2 | 2 | 0 | |
| MP-N4 | 5 | 3 | 1 | 1 | **C5-T03 FAIL** (placeholder) |
| MP-N5 | 4 | 1 | 2 | 1 | **C4-T03 FAIL** (placeholder) |
| MP-N6 | 4 | 0 | 2 | 2 | **C5-T01, C5-T03 FAIL** (placeholders) |
| MP-N7 | 4 | 2 | 2 | 0 | C3-T05 Gradle command is invalid |
| **Total** | **87** | **40** | **40** | **7** | |

### 2.3 Findings

**T-1 (blocking) — design-blocked tickets written as placeholders.**
- MP-N4-C5-T03, MP-N5-C4-T03, MP-N6-C5-T01 and MP-N6-C5-T03 fail. MP-N6-C3-T01 nearly fails.
- Their implementation steps read "After unblocking" or "After approval", and their tests read
  "Robolectric tests per kind" or "Watch UI tests per state", with no file and no command.
- A pack-wide grep finds the same shape in **17 tickets**:
  - MP-N4: C3-T07, C4-T03, C5-T03
  - MP-N5: C4-T01, C4-T02, C4-T03
  - MP-N6: C2-T02, C3-T01, C3-T02, C4-T01, C4-T02, C4-T03, C4-T04, C5-T01, C5-T03, C6-T01
  - MP-N7: C2-T03

  That is 11 of MP-N6's 20 tickets, so **MP-N6 is not implementation-ready even after DESIGN-N6
  approval.**
- Being blocked on the gate is correct. Brief §9 still forbids "add tests" in place of tests.
- **Fix:** name the test file, a test name keyed to each DESIGN-x §state ID, the command, and the
  files to create now. Mark only copy and layout as design-pending. Use MP-N1-C2-T03,
  MP-N2-C10-T01, MP-N6-C1-T03 and MP-N7-C1-T01 as templates.

**T-2 (blocking) — MP-N1-C4-T02 contradicts its blocker MP-N2-C6-T02.**
- MP-N2-C6-T02 (line 26) returns `200 {bootstrap_path}`. The WebView opens the one-time path, and the
  server sets the cookie.
- MP-N1-C4-T02 (lines 28, 64, 105) has native code refuse the 302, harvest `Set-Cookie`, and inject
  it with `WKHTTPCookieStore` or `CookieManager`.
- **Fix:** rewrite N1-C4-T02 to "native POST → `bootstrap_path` → WebView navigation". Drop cookie
  injection and N1-RQ5. Keep the 401 re-bootstrap state machine.

**T-3 (blocking, mechanical) — the isolated-HOME test command fails.**
- The form `env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN …` is in
  **41 files** (33 MP-N2, 8 MP-N3).
- GNU `env` treats everything after the first `NAME=VALUE` as the command. Reproduced:
  `env HOME=/tmp/x -u GITHUB_TOKEN true` → `env: '-u': No such file or directory`, exit 127.
- **Fix:** `env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test …`,
  run from `src/` (or with `env -C src`).

**T-4 — test isolation is inconsistent elsewhere.**
- MP-R7-C3-T01 and C3-T03 say "isolated HOME, tokens unset", but their command blocks do neither.
- MP-E7-C4-T02 uses `GITHUB_TOKEN= GH_TOKEN=`, which sets the variables to empty instead of unsetting
  them.
- AGENTS.md "Reading real state" and the known `mix test` agent-token clobber make this a
  correctness issue, not style.
- **Fix:** add one canonical command to the pack README and have tickets reference it.

**T-5 — the mutation-check requirement is met in substance.**
- MP-N4–N7 record the mutation target in a per-test "Must fail without" column. Coverage by file:
  N4 29/36, N5 14/19, N6 15/22, N7 23/27.
- Real gaps in the sample: MP-N6-C5-T01, MP-N6-C5-T03 and MP-N3-C5-T01. MP-E1-C9-T02 (docs only)
  and MP-N3-C4-T06 (validation only) should say "n/a" explicitly.
- Only MP-E2-C1-T01 and the MP-E5 and MP-E7 tickets give the *runnable* revert-in-a-worktree steps
  that AGENTS.md describes, including `git status --porcelain`.
- **Fix:** put one pack-level rule in the README: "Each 'Must fail without' row is checked by
  reverting that hunk in a worktree; report the command in the PR". Tickets can then keep the
  column.

**T-6 — docs statements are missing on about 20 tickets.**
- None of these tickets names a page or says "none, because…".
- The clearest misses are new user-facing surfaces, which AGENTS.md "Docs ship with the change"
  requires to be documented:
  - MP-N6-C1-T03 (a new device HTTP route);
  - MP-N7-C3-T04 (a new Wear notification surface).
- Others: MP-E3-C4-T03, MP-E6-C4-T01, MP-E6-C8-T03, MP-N2-C2-T02, MP-N5-C2-T01 and MP-N5-C1-T04.
- Where a docs page is named, it follows the AGENTS.md table:
  - `reference/configuration.md` for keys;
  - `reference/cli.md` for verbs;
  - `guide/` for surfaces;
  - `concepts/` for models.

**T-7 — tickets contradict themselves.** Each needs a one-line fix:
- MP-R2-C5-T02 says "exactly 13 envelope keys", but `seq` is not emitted, so the output has 12. Its
  own test 7 would fail.
- MP-R2-C6-T04 and C6-T02/T03 disagree between `Export.read/3` and `Reader.read/4` on the epoch.
- MP-E1-C4-T01 says a self edge is both "accepted" and "refused".
- MP-E7-C4-T02 names `deliver_now?/3` in its design and `wake_now?/2` in its steps.
- MP-E7-C1-T01 lists a `steerOnly` output that the interface omits.
- MP-E5-C2-T01 says request R-1 is accepted, then later "if R-1 is accepted".
- MP-E6-C3-T03 has a mutation check that names a test missing from its table.
- MP-R7-C3-T01 has count drift: 11 vs 12 modules, 9 vs 8 callers.

**T-8 — a ticket improvises UX its gate owns.** MP-E4-C6-T02 fixes the inline Command card placement
("pinned at top, position unknown") and a fallback to `/commands/:id`. DESIGN-E4 §3 and DESIGN-E2 §4
own both. **Fix:** reference the gate section, or list them as gate questions. This is the only
improvisation found. Every other UI ticket in the sample correctly marks copy and placement as
gate-owned. MP-E7-C7-T02 is still an "(a) and/or (b)" menu, but it is honestly gated on DESIGN-E7 §1.6.

**T-9 — the other FAILs.**
- **MP-R7-C3-T06** has no Implementation steps, Non-happy paths or Compatibility section. Its
  Verification names no test or command.
- **MP-E6-C8-T03** is a skeleton. The starting point is "New" with no evidence, the steps are one
  line, one test expects "—", and there is no docs line.

**T-10 — status semantics.** Many R2, R7 and N5 tickets say `status: ready` while their `blocked_by`
lists open gates. For example, MP-N5-C1-T01 hard-codes provisional answers to DESIGN-N5 D-4 and D-8.
**Fix:** define "ready" in the pack README as "researched; waiting on blocked_by". For MP-N5-C1-T01,
add D-4 as a blocker of its defaults constant.

**T-11 — external sources.**
- MP-E3-C1-T02 and MP-E7-C4-T02 cite Codex docs at `learn.chatgpt.com/docs/…`. Re-verify these, or
  pin them to the `openai/codex` repo at a SHA, as MP-E2-C4-T00 does.
- MP-N4-C5-T03's force-stop behaviour rests on a "search summary" (E-F7). The ticket flags it as
  RQ-N4-9; it needs a dated developer.android.com page before it leaves blocked.
- Other platform claims in the sample (Apple, Android, Expo, MDN, Cloudflare) are dated
  2026-07-28 to 2026-10-06.

**T-12 — invalid command.** MP-N7-C3-T05 runs `connectedDebugAndroidTest --tests …`. Connected test
tasks do not accept `--tests`. **Fix:** use
`-Pandroid.testInstrumentationRunnerArguments.class=…` and name the emulator image, or run it as a
Robolectric unit test.

**T-13 — MP-N1-C2-T03 omits RQ-TRANSPORT from `blocked_by`,** although its T-B pin branch depends
on it.

### 2.4 Citation accuracy

All 56 citations were checked with `git -C <worktree> show 45a290e3:<path> | sed -n …`:

- **17 from DESIGN files.** All accurate:
  - `router.ex:142-143`
  - `decision_inbox.ex:42`
  - `overview.ex:65,168-169`
  - `decision_card.ex:127`
  - `decision_action.ex:117,166`
  - `history.ex:224,241,266`
  - `http_server.ex:64,147`
  - `workflow.ex:84-93`
  - `config/schema.ex:57`
  - `streamdeck_channel.ex:152`
  - `layouts.ex:20,23`
  - `conversation_drawer.ex:166-236` (labels at 188, 202, 216, 229)
  - `conversation-voice-controller.js:18-22`
- **39 from 34 sampled tickets.** 37 are accurate. Two have an imprecise range:
  - `session_lifecycle.ex:333-345`: the function is at 334-346 (off by 1).
  - `router.ex:230-241`: the function ends at 239.
- **No citation was wrong, and no invented symbol was found.** Test files cited as existing are
  present at base: `shutdown_test.exs`, `application_test.exs`, `turn_loop_test`,
  `executor_listener_test` and `conversation_drawer_test`. So are the commands
  `make -C src fmt-check lint ci` and `npm run test:units`.

## 3. Fixes before the readiness report

In priority order. None of these needs new research.

1. **DESIGN-N4:** add OQ-N4-1 (publisher and relay operator) and OQ-N4-2 as decisions, and add them
   to acceptance (G-1).
2. **Rewrite MP-N1-C4-T02** to the `bootstrap_path` contract (T-2).
3. **Fix the `env … -u` command** in 41 files, and add one canonical isolated test command to the
   pack README (T-3, T-4).
4. **Flesh out the 17 placeholder tickets** with test files, test names keyed to gate states,
   commands and file paths (T-1). Rewrite MP-R7-C3-T06 and MP-E6-C8-T03 (T-9).
5. **Reconcile X8 and X9** and de-duplicate the five shared questions to one owner each (G-2, G-7).
6. **Extend the acceptance lists** of E3, E6, E7, N1 and N7. Add acceptance sections to R4 and R5
   (G-3, G-4).
7. **Add a recommendation to every gate question.** The defaults in owner-questions.md can be
   adopted (G-6).
8. **Clean up the rest:**
   - one-line contradiction fixes (T-7);
   - docs lines (T-6);
   - E4-C6-T02 gate references (T-8);
   - spike frontmatter (G-10);
   - E6 states (G-8);
   - N3/N5 badge and the E2 §6.2 link (G-5);
   - the ID crosswalk (G-9);
   - the "ready" definition (T-10).
