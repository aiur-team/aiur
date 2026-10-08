---
design_task: DESIGN-R1
feature_id: MP-R1
owner: Kevin
status: approved by the Executor 2026-10-08 per EXECUTOR-APPROVALS.md (Kevin may revise); §3 page layout, entry design, copy and first-page approval still Kevin's
blocks: [MP-R1-C1-T01, MP-R1-C1-T02, MP-R1-C1-T03, MP-R1-C1-T04, MP-R1-C1-T05, MP-R1-C1-T06, MP-R1-C2-T01, MP-R1-C2-T02, MP-R1-C3-T01, MP-R1-C3-T02, MP-R1-C3-T03, MP-R1-C3-T04, MP-R1-C3-T05, MP-R1-C3-T06, MP-R1-C3-T07, MP-R1-C4-T01, MP-R1-C4-T02, MP-R1-C4-T03, MP-R1-C4-T04, MP-R1-C4-T05, MP-R1-C5-T01, MP-R1-C5-T02, MP-R1-C5-T03, MP-R1-C5-T04, MP-R1-C5-T05, MP-R1-C5-T06, MP-R1-C6-T01, MP-R1-C6-T02, MP-R1-C6-T03, MP-R1-C6-T04, MP-R1-C7-T01, MP-R1-C7-T02, MP-R1-C7-T03, MP-R1-C7-T04, MP-R1-C7-T05, MP-R1-C7-T06, MP-R1-C7-T07, MP-R1-C7-T08, MP-R1-C8-T01, MP-R1-C8-T02, MP-R1-C8-T03, MP-R1-C8-T04, MP-R1-C8-T05, MP-R1-C8-T06, MP-R1-C8-T07, MP-R1-C8-T08, MP-R1-C8-T09, MP-R1-C9-T01, MP-R1-C9-T02, MP-R1-C9-T03, MP-R1-C9-T04, MP-R1-C9-T05, MP-R1-C9-T06, MP-R1-C9-T07, MP-R1-C9-T08, MP-R1-C9-T09, MP-R1-C9-T10, MP-R1-C9-T11, MP-R1-C9-T12, MP-R1-C9-T13, MP-R1-C9-T14, MP-R1-C10-T01, MP-R1-C10-T02, MP-R1-C10-T03, MP-R1-C10-T04, MP-R1-C10-T05, MP-R1-C11-T01, MP-R1-C11-T02, MP-R1-C11-T03]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-R1 (waived entries excluded). Earlier wording: every MP-R1 implementation ticket (MP-R1-C1..C11); MP-R1-C10-T04 (publish) additionally needs §3 approved"
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R1/plan.md
related_contract: ../contracts/identity-and-capabilities.md
---

Executor decisions recorded in [EXECUTOR-APPROVALS.md](EXECUTOR-APPROVALS.md) (2026-10-08).

# DESIGN-R1 — Kevin: confirm the modular refactor changes nothing you see, approve its few operator surfaces, and design the public component directory page

**Implementation of MP-R1 is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's explicit
approval in writing (a comment on the research PR or a line in
`context-and-decisions.md`).

## 1. Confirm: no runtime change you see

MP-R1 moves code behind facades, adds a component manifest and a CI check, and
moves config section ownership. Kevin confirms:

- [x] (Executor, 2026-10-08) **No dashboard page, TUI view, Stream Deck key, CLI output line, alert text or
  agent tool changes** in chunks C1, C4, C5, C7, C8, C9. A difference found in review
  is a bug.
- [x] (Executor, 2026-10-08) **`.aiur/config` keys keep their names and meaning.** Only the module that
  defines each key changes. `aiur init` output is unchanged.
- [x] (Executor, 2026-10-08) **No new required setup step.** Nothing in the refactor asks an existing user
  to do anything after upgrading.
- [x] (Executor, 2026-10-08) **Bucket-2 enabling work inside R1 and R2 (identity, the capabilities endpoint,
  the event export) appears in the component directory as capabilities of existing
  components, not as "planned" feature entries** (Phase D review, directory item 4).
  Recommended: confirm, because those are shipped APIs, not features.

## 2. Operator surfaces R1 adds (approve or reject each)

| # | Surface | Kevin decides | Plan default (adopted (Executor, 2026-10-08)) |
|---|---|---|---|
| S1 | `aiur capabilities [--json]`: one line per capability, e.g. `voice.stt  unavailable  not_configured` | Whether the verb exists for operators, and its wording | Exists; read-only; same data as the API |
| S2 | `GET /api/v1/capabilities` | That it exists (used by mobile, Stream Deck, dashboard) | Exists; dashboard auth now, paired-device auth later (MP-N2) |
| S3 | `~/.config/aiur/machine/identity.json` created on first daemon boot, holding a random machine id and a label (default: short hostname) | Whether creating it at first boot (not only at "enable mobile") is acceptable, and whether the label is shown anywhere before mobile exists | Created at first boot; label shown only in `aiur capabilities` |
| S4 | A run shape with the JSON API and sockets but **without** the dashboard pages (needed so a phone or Stream Deck works on a lean run) | Whether this is an operator flag (name it) or internal only | Internal only until a client needs it; `--no-dashboard` keeps its current meaning (no listener at all) |
| S5 | Docs: a "Capabilities" section in `concepts/` and the CLI reference entry | Approve wording when drafted | Ships with C3 |

## 3. The public component directory page (MP-REQ4)

Plan: [component-directory.md](../bucket-1-refactor/MP-R1/component-directory.md).
Goes live after the refactor (D20). Generated from `components.json`; Kevin designs
how it looks and decides what is public.

### Kevin designs

- The page layout at desktop and phone width (`aiur.team/docs`, VitePress, dark and
  light themes, existing brand: Bungee / Space Grotesk / JetBrains Mono).
- One component entry: which fields show, in what order, and the status badges
  (`core`, `optional`, `experimental`, `planned`, `deprecated`).
- The "Planned" section: how planned features are described.
- Page title, intro paragraph and empty-section copy.

### Decisions needing Kevin's input

| # | Question | Options | Plan suggestion (adopted (Executor, 2026-10-08)) |
|---|---|---|---|
| Q1 | What does each entry show? | Minimal (name, status, summary, docs link) · Full (also requires/optional deps, capabilities, config keys, env var names, install) | Full, because "what do I need for X" is the page's job; env var **names** only, never values |
| Q2 | Where in the sidebar? | Under "Reference" after "Optional Optimizations" · new top-level group "Components" · under "Introduction" | Under "Reference" |
| Q3 | Group entries how? | By layer (foundation … clients) · by what an operator wants (run agents, steer, notify, voice, hardware) · flat A–Z | By operator goal, with a filter for "optional only" |
| Q4 | How public are planned features? | Name + one line · plus `MP-` feature ID · plus wave/order · not listed until shipped | Name + one line + "planned"; no IDs, no dates, no order |
| Q5 | Which planned features to list? | All of MP-E*/MP-N* · only those past their DESIGN gate · a list Kevin curates | Only those whose DESIGN task is approved |
| Q6 | Show a dependency diagram? | Mermaid graph (the site already loads `vitepress-plugin-mermaid`) · none | One small diagram of minimum combinations, not the full graph |
| Q7 | Link Khala/Archon shared packages (listener modes)? | Yes, cross-product link · no | Yes, as "shared with Khala" |
| Q8 | Repository/package links for each component | Link source paths on GitHub · no source links | Link the package or docs page, not source paths (paths move) |

### States the design must cover

| State | Requirement |
|---|---|
| Loading | Static page; no runtime loading state (data is built in). |
| Empty section | e.g. no planned features approved: the section heading shows one approved sentence, not an empty table. |
| Experimental / deprecated | Distinct badge and one-line note on what that means for support. |
| Component without a docs page | Entry still renders; "docs" link omitted (the build check fails only on a **broken** link, not a missing one). |
| Narrow screen | Entries stack; no horizontal scroll. |
| Success | Every shipped component listed exactly once; matches `components.json`. |

Not applicable: offline, permission-denied, stale/resolved (public static docs).

### Acceptance conditions

- [ ] (still Kevin's, see EXECUTOR-APPROVALS.md) Layout and entry design approved (screens or a marked-up mock).
- [x] (Executor, 2026-10-08) Q1–Q8 answered: each takes the plan suggestion.
- [ ] (still Kevin's, see EXECUTOR-APPROVALS.md) Page copy (title, intro, section headings, badge meanings) approved.
- [ ] (still Kevin's, see EXECUTOR-APPROVALS.md) Kevin approves the first generated page from the post-refactor manifest before
  the sidebar entry ships (C10-T04).

## 4. Linked features

- Capability report wording is reused by the mobile meta-dashboard (DESIGN-N3) and
  notification settings (DESIGN-N5): unavailable vs stale vs unreachable must read the
  same everywhere. DESIGN-N3 owns the phone presentation; this task owns only the CLI
  line format (S1).
- Build-queue CLI output is DESIGN-E1, not here.
