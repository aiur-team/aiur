# MP-E7-ACC — MP-E7 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E7-C2-T05, MP-E7-C3-T06, MP-E7-C4-T01, MP-E7-C4-T03, MP-E7-C4-T04, MP-E7-C5-T03, MP-E7-C5-T04, MP-E7-C6-T03, MP-E7-C7-T02, MP-E7-C7-T04, MP-E7-C7-T05

## Outcome

The Executor proves MP-E7 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E7/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (33)

- MP-E7-C1-T01 — Khala: extract the listener reference package (@khala/listener) without changing Khala behaviour
- MP-E7-C1-T02 — Khala: generate the language-neutral listener artifacts (schema, scheduler table, codec goldens)
- MP-E7-C1-T03 — Khala: publish the listener package by listener-v* tag through the existing release-npm.yml
- MP-E7-C1-T04 — aiur: vendor the published listener spec into src/priv/listener_spec with a checksum gate
- MP-E7-C1-T05 — Khala: add backlog_on_leave_async and the emulated_interrupt steer carrier to spec v1 before its first release
- MP-E7-C2-T01 — Aiur.Listener.ModeStore: durable per-ticket-run listener mode record with compare-and-set
- MP-E7-C2-T02 — Aiur.Listener.Effective.compute/2: requested to effective mode with a named reason
- MP-E7-C2-T03 — Internal listener control API (get/set mode through the Orchestrator); no HTTP, CLI or snapshot field
- MP-E7-C2-T04 — Recompute effective mode and control flags from the running backend on transport change; broadcast in-process
- MP-E7-C2-T05 — Publish ticket.<id>.agent.listen-mode.changed on the topic exchange once MP-R2 registers it
- MP-E7-C3-T01 — Queue items for listener sends: listener_mode_at_claim stamp, async hold that no claim path takes, pending re-stamp
- MP-E7-C3-T02 — Aiur.Listener.Scheduler and the :listener delivery policy behind config :aiur, :listener_send_routing (default :legacy)
- MP-E7-C3-T03 — Route every conversation send entry point through :listener (dashboard, Stream Deck, aiur message, HTTP, TUI)
- MP-E7-C3-T04 — Aiur.Listener.receipt/2: map queue state to the contract §7 receipts (Elixir API only)
- MP-E7-C3-T05 — Conformance: aiur's Effective and Scheduler agree with the vendored scheduler.v1.json and support vocabulary
- MP-E7-C3-T06 — Capability provider for listener_modes (spec state, routing flag, fallback reason)
- MP-E7-C4-T01 — Precondition (cross-repo): stop aiur-claude turn/steer from dropping text
- MP-E7-C4-T02 — Codex native steer: deliver steer-mode messages with turn/steer
- MP-E7-C4-T03 — Muse native steer: deliver steer-mode messages with MSP turn/steer
- MP-E7-C4-T04 — claude-repl: classify pane input as native steer; hold sync until Stop
- MP-E7-C5-T01 — Async pull tool aiur_read_messages with a per-agent read cursor
- MP-E7-C5-T02 — Unread (held-async) count in control capabilities with live updates
- MP-E7-C5-T03 — Leaving async: apply the owner-chosen backlog rule (notice | skip | batch)
- MP-E7-C5-T04 — Agent prompt guidance for aiur_read_messages when async is effective
- MP-E7-C6-T01 — Daemon endpoint: claim and render a listener batch for the attached Executor at a hook boundary
- MP-E7-C6-T02 — Executor deliver hook command: print the daemon-rendered envelope, always exit 0
- MP-E7-C6-T03 — Install and uninstall the deliver hook for Claude and Codex Executors without clobbering user hooks
- MP-E7-C6-T04 — Elixir hook envelope renderer, conformance-tested against the shared hook goldens
- MP-E7-C7-T01 — Dashboard: listener-mode selector, requested vs effective, receipts and unread count
- MP-E7-C7-T02 — TUI AgentList: listener-mode indicator and optional key (per DESIGN-E7 §1.6)
- MP-E7-C7-T03 — CLI get/set listener mode and POST /api/v1/:id/listen-mode (names from DESIGN-E7)
- MP-E7-C7-T04 — Flip :listener_send_routing default to :listener and delete the legacy send policies
- MP-E7-C7-T05 — Docs: listener modes concept, CLI reference, config key (only if E7-D7), aiur-agent skill note

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
