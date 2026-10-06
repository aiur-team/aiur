# MP-E7 tickets — listener modes

Feature plan: [../plan.md](../plan.md). Chunks: [../chunks.md](../chunks.md).
Contract: [../../../contracts/listener-mode.md](../../../contracts/listener-mode.md).
Contract requests to the coordinator: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).

Researched at aiur `45a290e3` and Khala `origin/main` `99e72a43` on
2026-10-06. Every ticket is blocked on **DESIGN-E7**. Status meanings:

- `ready`: fully specified; waits only on the DESIGN-E7 gate and on tickets inside MP-E7.
- `blocked`: also waits on a named owner decision that changes the ticket
  (E7-D1, E7-D4, E7-D5, E7-D6, OWNER-NPM-FIRST-PUBLISH), another feature's
  ticket (MP-R7, MP-R2, MP-E3, DESIGN-R7/E3), or an open research question.

**RC-05.** C1–C3 are wave 3 and land before the MP-E3/MP-E4 write chunks
(E3-C5, E4-C6). C3 ships behind the internal app env
`config :aiur, :listener_send_routing` (`:legacy` default), which keeps
today's interrupting dashboard, Stream Deck and `aiur message` sends.
C7-T04 flips it only after DESIGN-E7 approves E7-D6 (the `sync` default).

**RC-36 (Phase D): router in core, spec as a build-time input.** The send
router (`Aiur.Listener.*`: `send/3`, mode store, scheduler; component
`listener-modes`) is a **required** part of core. `AgentChat.send/3` delegates
to it, and it delivers through `Aiur.Listener.DeliveryTarget`, which
orchestration implements (C3-T03). The shared spec package (component
`listener-spec`, MP-Q1/E7-D1) is vendored at build time into
`src/priv/listener_spec/` with `src/priv/listener_spec/CHECKSUM` (C1-T04) and
is never a runtime dependency. Spec absent → `:legacy` routing and
`listener_modes: unavailable/not_installed`; checksum or decode failure →
`:legacy` and `unavailable/spec_invalid`; flag `:legacy` with a good spec →
`unavailable/disabled` (C3-T02, C3-T06).

## Ticket table

| ID | Title | Repo | Status | blocked_by (besides DESIGN-E7) | Wave |
| --- | --- | --- | --- | --- | --- |
| [C1-T01](MP-E7-C1-T01.md) | Extract `@khala/listener` reference package | khala (cross-repo) | blocked | E7-D1 | 3 |
| [C1-T02](MP-E7-C1-T02.md) | Generate schema, `scheduler.v1.json`, envelope-only goldens | khala (cross-repo) | blocked | E7-D1, C1-T01 | 3 |
| [C1-T05](MP-E7-C1-T05.md) | Add `backlog_on_leave_async` and `steer_carrier` to v1 before release | khala (cross-repo) | blocked | E7-D1, C1-T02 | 3 |
| [C1-T03](MP-E7-C1-T03.md) | Publish by `listener-v*` tag via `release-npm.yml` | khala (cross-repo) | blocked | E7-D1, C1-T05, OWNER-NPM-FIRST-PUBLISH | 3 |
| [C1-T04](MP-E7-C1-T04.md) | Vendor spec into `src/priv/listener_spec/v1` with sha256 gate | aiur | blocked | E7-D1, C1-T03 | 3 |
| [C2-T01](MP-E7-C2-T01.md) | `Aiur.Listener.ModeStore` (durable, CAS) | aiur | blocked | E7-D5 | 3 |
| [C2-T02](MP-E7-C2-T02.md) | `Aiur.Listener.Effective.compute/2` | aiur | blocked | MP-R7-C2-T01, MP-R7-C2-T03 | 3 |
| [C2-T03](MP-E7-C2-T03.md) | Internal listener control API (no HTTP/CLI/snapshot field) | aiur | ready | C2-T01, C2-T02 | 3 |
| [C2-T04](MP-E7-C2-T04.md) | Recompute effective mode and `:control` flags on transport change | aiur | ready | C2-T03 | 3 |
| [C2-T05](MP-E7-C2-T05.md) | Publish `ticket.<id>.agent.listen-mode.changed` on the bus | aiur | blocked | C2-T04, MP-R2-C5-T01, MP-R2-C5-T03 | 4 |
| [C3-T01](MP-E7-C3-T01.md) | Queue items: `listener_mode_at_claim`, async hold, re-stamp | aiur | blocked | MP-R7-C1-T02 | 3 |
| [C3-T02](MP-E7-C3-T02.md) | `Aiur.Listener.Scheduler` + `:listener` policy behind the flag | aiur | ready | C2-T03, C3-T01 | 3 |
| [C3-T03](MP-E7-C3-T03.md) | Route every send entry point through `:listener`; `Aiur.Listener.send/3` | aiur | blocked | C3-T02, MP-R7-C1-T02 | 3 |
| [C3-T04](MP-E7-C3-T04.md) | `Aiur.Listener.receipt/2` (contract §7) | aiur | ready | C3-T01 | 3 |
| [C3-T05](MP-E7-C3-T05.md) | Conformance against vendored `scheduler.v1.json` | aiur | ready | C1-T04, C2-T02, C3-T02 | 3 |
| [C3-T06](MP-E7-C3-T06.md) | Capability provider for `listener_modes` (X-21, RC-36) | aiur | blocked | C3-T03, MP-R1-C3-T01 | 3 |
| [C4-T01](MP-E7-C4-T01.md) | **Precondition:** fix `aiur-claude` `turn/steer` text drop | claude-app-server (cross-repo) | blocked | DESIGN-R7 (§2 decision 2) | 4 |
| [C4-T02](MP-E7-C4-T02.md) | Codex native steer via `turn/steer` | aiur | blocked | C3-T02, C3-T03, MP-R7-C2-T01, MP-R7-C2-T02 | 4 |
| [C4-T03](MP-E7-C4-T03.md) | Muse native steer via MSP `turn/steer` | aiur | blocked | C4-T02, MP-R7-C2-T02 | 4 |
| [C4-T04](MP-E7-C4-T04.md) | `claude-repl` native steer; sync held until `Stop` | aiur | ready | C4-T02, C3-T02 | 4 |
| [C5-T01](MP-E7-C5-T01.md) | Async pull tool `aiur_read_messages` with read cursor | aiur | blocked | C3-T01, C3-T02, C3-T04, MP-R7-C3-T01 | 4 |
| [C5-T02](MP-E7-C5-T02.md) | Unread count in control capabilities | aiur | ready | C5-T01, C2-T03 | 4 |
| [C5-T03](MP-E7-C5-T03.md) | Leaving async: backlog rule | aiur | blocked | E7-D4, C5-T01, C2-T01, C1-T05 | 4 |
| [C5-T04](MP-E7-C5-T04.md) | Prompt guidance when async is effective | aiur | ready | C5-T01, C2-T02 | 4 |
| [C6-T01](MP-E7-C6-T01.md) | Daemon endpoint: claim and render a batch for the attached Executor | aiur | blocked | DESIGN-E3, MP-E3-C1-T01, MP-E3-C1-T02, C3-T02, C6-T04 | 4 |
| [C6-T02](MP-E7-C6-T02.md) | Executor deliver hook command (`curl`, always exit 0) | aiur | blocked | C6-T01, MP-E3-C1-T02 | 4 |
| [C6-T03](MP-E7-C6-T03.md) | Install/uninstall deliver hooks without clobbering user hooks | aiur | blocked | DESIGN-E3, MP-E3-C1-T04, C6-T02 | 4 |
| [C6-T04](MP-E7-C6-T04.md) | Elixir hook-envelope renderer vs shared goldens | aiur | ready | C1-T02, C1-T04 | 4 |
| [C7-T01](MP-E7-C7-T01.md) | Dashboard selector, requested vs effective, receipts, unread | aiur | ready | C7-T03, C2-T03, C3-T04, C5-T02 | 4 |
| [C7-T02](MP-E7-C7-T02.md) | TUI indicator and optional key | aiur | ready | C7-T03, C2-T03, C5-T02 | 4 |
| [C7-T03](MP-E7-C7-T03.md) | CLI get/set and `POST /api/v1/:id/listen-mode` | aiur | ready | C2-T01, C2-T03 | 4 |
| [C7-T04](MP-E7-C7-T04.md) | Flip `:listener_send_routing` to `:listener`; delete legacy branch | aiur | blocked | E7-D6, C3-T03, C3-T05, C7-T01, C7-T03, C4-T02 | 4 |
| [C7-T05](MP-E7-C7-T05.md) | Docs: concept, CLI reference, config key only if E7-D7, skill note | aiur | ready | C7-T03, C5-T01 | 4 |

IDs above drop the `MP-E7-` prefix. Totals: 33 tickets (15 wave 3, 18
wave 4): 13 ready, 20 blocked. Repos: 4 Khala, 1 claude-app-server, 28 aiur.
Phase D added C3-T06.

## Dependency order

```text
Wave 3
  Khala:  C1-T01 ─► C1-T02 ─► C1-T05 ─► C1-T03 ─► (aiur) C1-T04 ─┐
  aiur:   C2-T01 ─┐                                              │
          C2-T02 ─┴► C2-T03 ─► C2-T04                            │
          C3-T01 ─┬► C3-T02 (needs C2-T03) ─► C3-T03             │
                  └► C3-T04                                      │
          C1-T04 + C2-T02 + C3-T02 ─► C3-T05 ◄───────────────────┘
          C3-T03 + MP-R1-C3-T01 ─► C3-T06 (capability provider)
          ── consumers: MP-E3-C5-T01, MP-E4-C6-T03 call Listener.send/3 and receipt/2
Wave 4
  C4-T01 (sibling precondition; headless Claude steer text)
  C3-T02/T03 ─► C4-T02 ─┬► C4-T03
                        └► C4-T04
  C3-T01..T04 + MP-R7-C3-T01 ─► C5-T01 ─┬► C5-T02 ─┐
                                        ├► C5-T03  │
                                        └► C5-T04  │
  C1-T02/T04 ─► C6-T04 ─► C6-T01 (MP-E3-C1) ─► C6-T02 ─► C6-T03
  C2-T03 ─► C7-T03 ─┬► C7-T01 ◄── C5-T02
                    └► C7-T02
  C2-T04 + MP-R2-C5 ─► C2-T05
  C3-T03 + C3-T05 + C7-T01 + C7-T03 + C4-T02 + E7-D6 ─► C7-T04 ─► (default is sync)
  C7-T03 + C5-T01 ─► C7-T05
```

## What may run concurrently

- The Khala chain (C1-T01..T03) runs in parallel with all of C2 and C3. Only
  C3-T05 (and wave-4 C6-T04) waits for the vendored spec.
- C2-T01, C2-T02 and C3-T01 have no MP-E7 predecessors and can start together
  once their outside blockers clear.
- C3-T04 runs in parallel with C3-T02.
- Wave 4: C4, C5 and C6 are independent chains. C4-T01 is in another repo and
  can start as soon as DESIGN-E7 and DESIGN-R7 allow. C7-T03 can start right
  after C2-T03.

## Research questions

- RQ-E7-1 (Codex steer): answered. codex-cli 0.160.0 schema `TurnSteerParams{threadId, input, expectedTurnId}`; open sub-point (is a `userMessage` item emitted?) settled by the C4-T02 manual test. aiur pins no Codex version.
- RQ-E7-2 (Muse): answered. Muse 1.4.3 `IfBusy = queue | steer | replace`; `turn/steer` exists.
- RQ-E7-3 (= RQ-R7-1, `claude-repl`): answered from Claude Code docs; foreground capture in C4-T04.
- RQ-E7-4 (headless Claude mid-turn input): no documented way; headless steer stays `unsupported`.
- RQ-E7-5 (Node floor): moot; C6 renders hooks in Elixir.
- RQ-E7-6 (hook install without clobbering): answered for Codex (port Khala's merge rules); Claude uses `--settings` composition.
- RQ-E7-C6-1 (new, open): waking an idle Executor (Khala rates its watcher `experimental`).
- RQ-E7-C6-2 (new, open): how Claude and Codex combine two `Stop` hooks that both return `decision: block`.
- New fact: npm has only `aiur-claude` 1.0.0; the local checkout is 1.1.0.
