# Executor approvals: wave-1 refactor design gates (DESIGN-R1 to DESIGN-R7)

- **Date:** 2026-10-08
- **Approver:** the Executor (not Kevin).
- **Authority:** Kevin (the operator) said that hands-off operators "would prefer
  to defer to the executor on command requests" about implementation details, and
  that the Executor should have discretion. With that authority, the Executor
  adopts the option that each design doc itself recommends or that its plan
  suggests. The Executor does not adopt a user-visible visual design that the doc
  gives to Kevin without a recommendation. Those items are in "Still Kevin's" at
  the end of this file.
- **Kevin may revise any item at any time.** A revision from Kevin replaces the
  matching line here.

**For workers:** this file is the written approval for the items it lists. Do not
pause to ask for Kevin's written DESIGN-Rx approval on these items. If your ticket
needs an item from "Still Kevin's", do all other work and wait only for that
item.

## DESIGN-R1 (MP-R1: modular refactor, capabilities, component directory)

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| §1.1 | Confirmed: "No dashboard page, TUI view, Stream Deck key, CLI output line, alert text or agent tool changes in chunks C1, C4, C5, C7, C8, C9. A difference found in review is a bug." | The refactor is behaviour-preserving by design. |
| §1.2 | Confirmed: "`.aiur/config` keys keep their names and meaning. ... `aiur init` output is unchanged." | Only the owning module changes. |
| §1.3 | Confirmed: "No new required setup step." | Upgrades must not need operator action. |
| §1.4 | Confirmed (doc: "Recommended: confirm"): identity, the capabilities endpoint and the event export show "as capabilities of existing components, not as 'planned' feature entries". | They are shipped APIs, not features. |
| S1 | Plan default: `aiur capabilities [--json]` "Exists; read-only; same data as the API". Line format as in the doc (`voice.stt  unavailable  not_configured`). | Read-only view of data that already exists. |
| S2 | Plan default: `GET /api/v1/capabilities` "Exists; dashboard auth now, paired-device auth later (MP-N2)". | Mobile, Stream Deck and dashboard need it. |
| S3 | Decided by the Executor earlier today (#3260): machine identity file "Created at first boot; label shown only in `aiur capabilities`". | One stable identity; no new visible surface. |
| S4 | Plan default: "Internal only until a client needs it; `--no-dashboard` keeps its current meaning (no listener at all)". | No new operator flag without a consumer. |
| S5 | Plan default: Capabilities docs section "Ships with C3". The Executor reviews the wording in the PR. | Docs wording, not visual design. |
| Q1 | "Full ... env var **names** only, never values". | "What do I need for X" is the page's job. |
| Q2 | "Under 'Reference'". | Plan suggestion; fits the current sidebar. |
| Q3 | "By operator goal, with a filter for 'optional only'". | Plan suggestion; matches how operators look. |
| Q4 | "Name + one line + 'planned'; no IDs, no dates, no order". | No public commitments to dates or order. |
| Q5 | "Only those whose DESIGN task is approved". | Lists only work that has passed its gate. |
| Q6 | "One small diagram of minimum combinations, not the full graph". | Plan suggestion; Mermaid already loads. |
| Q7 | "Yes, as 'shared with Khala'". | Plan suggestion. |
| Q8 | "Link the package or docs page, not source paths (paths move)". | Source paths move during the refactor. |
| §3 states | The "States the design must cover" table is approved as written (static page, one-sentence empty sections, distinct experimental/deprecated badge, missing docs link omitted, stacked entries on narrow screens). | Behaviour rules, not visual taste. |

## DESIGN-R2 (MP-R2: event bus refactor and event export)

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| §1.1 | Confirmed: "No user-facing change is intended in C1–C4." Regressions are bugs. | Packaging only. |
| §1.2 | Confirmed: "The existing event names stay as they are." | Renames need a separate approval. |
| S1 / KQ-R2-1 | Recommended plan default: "7 days **or** 50,000 events, whichever is smaller; configurable". | Covers a phone off over a weekend; the cap bounds disk use. |
| S2 / KQ-R2-2 | Recommended: "ship it, read-only" (`aiur events tail`, JSON lines, no write verb). | Only way to inspect the feed without a client. |
| S3 | Plan default: "Print one line only when the export feed is enabled". | No noise when the feed is off. |
| S4 | Plan rule: "`reset` + snapshot; never replay stale events as fresh notifications". | Prevents stale notification bursts. |
| KQ-R2-3 | Plan proposal: external feed is "identifiers-only"; clients fetch text from the authenticated source API. | Same rule as Executor wake records today. |
| §3 states | The states table is approved as written (disabled, empty, offline, permission denied, stale cursor, journal corrupt, success). | Matches existing CLI patterns. |

## DESIGN-R3 (MP-R3: optional Tailscale)

Decided by the Executor earlier today for #3371; included as-is.

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| §1 | Confirmed: no user-facing change and no new config key. | Guard tests and docs only. |
| §2.1 | "Recommended: document a warning only" (HTTP warning only; no Bucket 2 TLS feature now). | Docs fix; no runtime change. |
| §2.2 | "Recommended: leave historical specs untouched". | Dated records; current docs carry the correction. |
| §3 | Both Tailscale and Transport paragraphs approved as written, subject to the 360-char prose guard. | Accurate and names no HTTPS method. |

## DESIGN-R4 (MP-R4: hooks.aiur.dev relay)

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| §1.1 | Confirmed: "No user-facing change is intended." | Webhook route, keys and texts stay. |
| §1.2 | Confirmed: "Your `hooks.aiur.dev` tunnel is unchanged." Path-scoped, catch-all 404. | Keeps the tunnel's blast radius small. |
| §1.3 | Confirmed: "Relay configuration UX: none added." The Bucket 2 guided-setup box is not ticked. | Ingress stays operator infrastructure. |
| §2.1 | "yes (recommended)": keep the tunnel purely for GitHub webhooks. | Doc recommendation. |
| §2.2 | "seen". The push-relay answer itself stays in DESIGN-N4 D-8 (not decided here). | The gate asks only for acknowledgement. |
| §3 | Cloudflare tunnel boundary copy approved as written. | Accurate per the cited Cloudflare docs. |

## DESIGN-R5 (MP-R5: voice package)

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| Port | Decided by the Executor earlier today (#3450): provider-neutral `Aiur.Voice` port; proceed. | Included as-is. |
| §1.1-§1.3 | Confirmed: no change for a configured key, no change for a missing key (copy word-for-word), key setup UX unchanged. | Package move only. |
| §2 copy | Proposed copy approved as written: dashboard "Voice input isn't installed in this Aiur. Typed messages work as usual."; deck "Voice isn't installed in this Aiur"; reply code `not_installed`; Units credits row hidden. | Clear, short, matches existing tone. |
| §2 hidden/disabled | "Recommendation: (b) disabled with reason" for every surface. | Matches the pack-wide rule (DESIGN-N1 §3 item 5, DESIGN-N5 §1); keeps MP-R5 independent of MP-E5. |
| §3.1 | "include (recommended)": default npm install includes the voice package; the key is the opt-in. | No extra install step. |
| §3.2 | "delete (recommended)": delete the unwired sidecar TTS file. | Unused; would need a key in the sidecar. |

## DESIGN-R6 (MP-R6: Stream Deck split)

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| §1 | Confirmed: no change on the physical deck, hold-to-dictate preserved, targeting preserved, no change in the `/streamdeck` emulator, setup unchanged. | Split is behaviour-preserving. |
| §2.1 | "Recommended: required, one manual pass" of hardware re-proof before C2 merges. | The deck is Kevin's daily surface; one pass is cheap. The pass itself needs the physical deck (see "Still Kevin's"). |
| §2.2 | "Recommended: yes, start there" (deck grouping rule as the initial view for DESIGN-E4). | Proven on the deck; DESIGN-E4 stays final. |

## DESIGN-R7 (MP-R7: harness-adapter extraction)

| Id | Adopted option (from the doc) | Reason |
|---|---|---|
| §1 | Confirmed: no change in message delivery paths, backend names/config, Remote Control, workspace skills, or packaging. | Extraction only; changes belong to MP-E7. |
| §2.1 | "Recommended: yes": a foreground manual run (one Codex, one Claude agent, a chat-pane message to each) is enough proof for C4. | Matches the AGENTS.md definition of manual testing. |
| §2.2 | "Recommended: file now": file the `aiur-claude` `turn/steer` text-drop issue on the sibling repo. | Precondition of MP-E7-C4. |

## Still Kevin's

These items are user-visible visual design or a physical action that the docs give
to Kevin without a recommendation. The Executor did not adopt them.

| Id | Item | Tickets that wait for it |
|---|---|---|
| DESIGN-R1 §3 layout | Component directory page layout at desktop and phone width. | MP-R1-C10-T03 (#3323) |
| DESIGN-R1 §3 entry | One component entry: field order and status badge design. | MP-R1-C10-T03 (#3323) |
| DESIGN-R1 §3 planned | How the "Planned" section describes planned features (presentation). | MP-R1-C10-T03 (#3323) |
| DESIGN-R1 §3 copy | Page title, intro paragraph, section headings, empty-section copy and badge meanings. | MP-R1-C10-T03 (#3323) |
| DESIGN-R1 §3 final | Kevin approves the first generated page before the sidebar entry ships. | MP-R1-C10-T05 (#3341) |
| DESIGN-R6 §2.1 pass | The one manual hardware re-proof pass on Kevin's physical deck before C2 merges (the requirement is adopted; the pass needs the deck). | MP-R6-C2-T01 (#3460) merge |
