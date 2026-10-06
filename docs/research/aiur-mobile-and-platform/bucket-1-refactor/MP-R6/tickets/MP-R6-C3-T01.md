---
ticket_id: MP-R6-C3-T01
feature_id: MP-R6
chunk_id: MP-R6-C3
bucket: 1-refactor
title: Docs — shared projections vs Stream Deck presentation; the dashboard never needs the sidecar
status: blocked
blocked_by: [DESIGN-R6, MP-R6-C1-T01, MP-R6-C2-T01]
prior_units: [U8]
prior_boundaries: ["SD #35", "PRJ #28"]
prior_features: [ui-15, ui-16]
prior_findings: []
size_owner: n/a (docs/streamdeck-channel.md 175 lines; guide/stream-deck.md 286 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R6-C3-T01 — Docs: shared projections versus Stream Deck presentation

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R6 / C3.
- **User value:**
  - **Contributors:** a contributor adding a dashboard, phone or watch surface
    knows which daemon modules are shared and which are deck presentation, so
    the deck is not made a dependency by accident.
  - **Operators:** an operator learns that the dashboard and its `/streamdeck`
    emulator never need the physical sidecar.
- **Deliverable:**
  - a "Shared projections vs deck presentation" section in
    `docs/streamdeck-channel.md`;
  - one sentence in `website/docs-app/guide/stream-deck.md`.
- **Non-goals:**
  - renaming modules (plan § 3 rejects option A);
  - the voice delegation. That code lands in MP-R5-C1-T03, which also carries
    the hold-to-dictate re-proof. The plan's C3-T02 "re-verify" is that
    ticket's acceptance, not a separate PR.

## Dependencies and blockers

- **Blocked by:** DESIGN-R6, plus C1-T01 and C2-T01. The doc describes their
  end state: the anchor rule in `Aiur.Conversation.Anchors`, and the visual
  contract canonical in `src/priv/streamdeck/`.
- **May run concurrently with:** MP-R5 tickets. If MP-R5-C1-T03 has not landed
  yet, the voice row reads "`StreamdeckProjection.voice/0` (reads the voice
  port after MP-R5)". Do not describe unmerged code as current.

## Verified starting point (base `45a290e3`)

- **`docs/streamdeck-channel.md`** (175 lines) has these sections:
  - Authentication (`:7`), Events (`:23`), Focus and transcript rate (`:44`);
  - Commands and answering (`:66`);
  - Voice input (`:101`), with the `voice` snapshot entry (`:140-150`).

  There is no section on module classification.
- **`website/docs-app/guide/stream-deck.md`** (286 lines) has "Physical sidecar
  status" (`:78`). It does not say that the emulator works without the sidecar.
- **Classification facts** (plan § 1.2, re-verified):
  - Hardware-free projections with consumers outside the deck:
    - `StreamDeckGrid.payload/2` serves `GET /api/v1/streamdeck/grid`
      (`observability_api_controller.ex:23`, `router.ex:190`);
    - `StreamDeckGrid.project/1` is used by `StreamdeckProjection`
      (`:71-77`) and `StreamdeckLive` (`:1666`).
  - **Plan RQ3 answered:** `StreamDeckGrid.dependency_ready?/2` has no consumer
    outside its module. The only mention elsewhere is a comment at
    `orchestrator/status_report.ex:1452`. It stays in place.
  - Deck-only presentation: `StreamdeckStrip`, `StreamdeckKeyFaceContract`,
    and `StreamdeckLogs` (paging, LIVE, window, `line/1`, `wire/1`).
  - Transport for the deck: `StreamdeckAuth`, `StreamdeckSocket`,
    `StreamdeckChannel`.
  - `StreamdeckCommands.actor/0` returns `%{kind: :operator, id: "streamdeck"}`.
    The `"streamdeck"` attribution on dictated Command answers is kept
    (DESIGN-R6 §1, #2156).

## Chosen design

Add the following table to `docs/streamdeck-channel.md` as the new section,
after Authentication:

| Module | Role | Needs the sidecar? | Other consumers |
| --- | --- | --- | --- |
| `Aiur.Conversation.Anchors` | Event→transcript anchoring (shared) | no | MP-E4 conversations (planned) |
| `StreamdeckProjection` | Fleet, voice availability, decisions and transcript DTOs for the deck channel | no | `/streamdeck` emulator |
| `StreamdeckCommands` | Command history and answer DTOs; actor `streamdeck` | no | emulator |
| `StreamDeckGrid` | Key ranking for the grid | no | `GET /api/v1/streamdeck/grid` |
| `StreamdeckTranscriptRelay` | Throttled live transcript push | no | emulator |
| `StreamdeckLogs`, `StreamdeckStrip`, `StreamdeckKeyFaceContract` | Deck presentation | no (the emulator renders them) | — |
| `StreamdeckAuth`, `StreamdeckSocket`, `StreamdeckChannel` | Deck transport | only for a physical deck | — |

Below the table:

- the visual contract's canonical file is `src/priv/streamdeck/key-face-contract.json`,
  and the sidecar keeps a checked mirror (C2-T01);
- new non-deck surfaces should read `DecisionStore`, the orchestrator snapshot
  or `Aiur.Conversation.Anchors` directly, **not** the deck DTOs.

In `guide/stream-deck.md`, add one sentence under "Physical sidecar status":
"The dashboard's `/streamdeck` page emulates the deck without the sidecar;
nothing in the dashboard needs it installed."

## Implementation steps

1. Write the section and the guide sentence.
2. Re-check each row's claim at the implementation head (grep the callers).
3. Build the docs and run the docs spec.

## Non-happy paths

- **A module gained a non-deck consumer** after the base (for example MP-E2
  reading `StreamdeckCommands`). Record it in the table. Do not leave the row
  stale.

## Compatibility and rollout

n/a — docs only. Rollback means reverting the commit.

## Verification

```bash
env -C <worktree>/website/docs-app bun run build
env -C <worktree>/website npx playwright test --project=brand tests/gui-docs.spec.ts
```

Expected: both pass. `gui-docs.spec.ts:232` asserts the sidebar order that
includes "Stream Deck", which is unaffected. There is no mutation check (docs
only).

## Completion and handoff

- [ ] The classification table matches the code at the implementation head.
- [ ] The guide sentence is added.
- **Docs pages:**
  - `docs/streamdeck-channel.md` (developer protocol doc);
  - `website/docs-app/guide/stream-deck.md` (the "Dashboard, TUI, Stream Deck"
    row of AGENTS.md).
- **Dependents:** none. MP-R1-C10 (component directory) may link the table.
