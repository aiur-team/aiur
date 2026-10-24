# Validation report (plan_version 1)

Reviewed commit: `6a7d6b445` (origin/main, 2026-10-23). Graph: `graph.json`.

## Mechanical checks

| Check | Result |
|-------|--------|
| Unique logical IDs (25: SD-101..105, SD-201..207, SD-301..304, SD-401..408, SD-901) | pass |
| Every ticket has Outcome, Scope, Non-goals, Reuse target, Contract, Implementation notes, Acceptance criteria, Failing test, Docs, First slice, Open points | pass |
| Every `depends_on` resolves to a pack ID | pass |
| Hard-dependency graph is acyclic | pass (7 waves) |
| Every cited existing file under `src/lib` and `packages/streamdeck/src` exists at `6a7d6b445` | pass: 53 paths cited, 16 are new files the tickets create |
| Named reuse targets exist (`AgentEvents.streamdeck_bucket`, `Aiur.BuildQueue.show/0` and `reorder/2`, `AiurWeb.Build.NowRows`, `AiurWeb.Build.Usage`, `ConversationSource`, `CommandAnswers.record_command_answer`, `StreamdeckFleet.grid/1`, `ProviderMeterWindows`) | pass |
| No secrets, tokens or machine paths in the pack | pass |
| External blockers are open issues | #5589, #5945, #5998, #5999, #4142, #4145, #5729 are open; #5968 is closed (no edge) |

## Wave profile

| Wave | Tickets |
|------|---------|
| 1 | SD-101, SD-207 |
| 2 | SD-102, SD-201, SD-301, SD-401, SD-403 |
| 3 | SD-103, SD-104, SD-202, SD-206, SD-303, SD-402, SD-404 |
| 4 | SD-203, SD-204, SD-205, SD-302, SD-304, SD-406 |
| 5 | SD-105, SD-405, SD-407 |
| 6 | SD-408 |
| 7 | SD-901 |

Critical path (complexity-weighted, 23 points): SD-101 → SD-102 → SD-103 → SD-406 → SD-407 →
SD-408 → SD-901. Top fan-out: SD-102 (11), SD-201 (11), SD-101 (8). Max width 7.

Phase labels follow the waves, with two moves: SD-401 and SD-403 go to phase 1 (the defect
fixes Kevin asked to see first) and SD-207 to phase 2 (its only blocker is external).

## Semantic review

- **Real prerequisites only.** Renderer-only feedback (SD-206 needs SD-102 to show its result)
  is `suggested_after`, not a hard edge. SD-207 is blocked by #5945, not by epic #5964 as a whole.
- **One owner per contract.** `Deck` shell: SD-101. Renderer: SD-102. Nav reducer: SD-201.
  `Deck.Meters`: SD-403 (SD-404/405 extend it). `Deck.Chat`: SD-303 (SD-304 extends it).
  Priority path: SD-206 (SD-302 calls it, not a second path).
- **Hot-file conflicts** are `serializes_with` edges: the shell section list (one line per
  section), `streamdeck_channel.ex`, `surface.ts`, `packages/streamdeck/src/main.ts`.
- **Deletion is last.** SD-105 runs after every replacement lands, so no surface loses data.
- **Acceptance capstone** SD-901 exists from plan version 1.
- **Unknown paths.** SD-202 renders an unknown NowRows state as unknown, not active; SD-403
  renders a missing reading as unknown with age, not 0.

## Warnings

- SD-102, SD-103, SD-406 and SD-407 are complexity 4. SD-102 and SD-103 are one contract each
  (renderer, consumer) and were not split further; SD-406 and SD-407 carry their reasons in the
  ticket.
- SD-203/SD-204 depend on server blocks that #5998/#5999 have not landed (Q2).
- Not run: `ce-doc-review` adversarial pass and the `aiur-build` publication scripts (no legacy
  pack is published; tickets are filed by hand from `tickets/<ID>.md`).
