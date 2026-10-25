# MP-R2 C4-T04 refresh audit

Refreshed 2026-10-25 from research base `45a290e3053423100a73b534c620fdd12ebe11ad`
to merged head `761756f394e6783794c777668fc1a26a540e4059` (C4-T03, #6242 / #3367).
Source pack: `6732f5f9f448b1857a9643993849635f85321e19`.
DESIGN-R2 approval: EXECUTOR-APPROVALS.md at `9ce9fdc6`.
Path-map prerequisite: #3338 (MP-R1-C11-T01) merged.

## Scope and method

Main contains only earlier scoped research refreshes. This PR recovers fourteen
C5–C7 tickets, MP-R2 plan, owned events contract, and five named consumer plans/
chunks from the pinned research object. Original researched/date metadata stays
unchanged. Unavailable research links point at that immutable source. No
production file changes; no export feature, retention change or topic rename.

Current ranges in refreshed starting points were read with `git show` at the
target SHA and checked for existence and bounds. Old numeric source citations
outside those starting points were removed in favor of file/symbol pointers;
they are not line translations inferred by adding an offset. Plan §§2–10/12
are explicitly historical design context; §11 records the actual result.

The MP-R1 plan-refresh generator was run on the pinned full pack, from 45a290e3
to the target head, using the current U8 assignments.csv. Its drift report is
an input, not an automatic edit: moved symbols and proposed paths need manual
classification. Current event-bus ownership comes from components/event-bus.json,
not a physical Mix application. The original “no file moves” expectation does
not cover later U8 splits: subscription processing/persistence and boot wiring
now live in smaller modules.

## Implemented seam map

| Concern | Implemented provider | Consumer rule |
| --- | --- | --- |
| Publish/subscribe | Aiur.Events (src/lib/aiur/events.ex) | Use facade, not Publisher or Exchange internals |
| Per-ticket delivery | Aiur.Events.Delivery; Aiur.Orchestrator.EventDelivery | enqueue/3 and dead_letter/5; no direct Orchestrator call from bus |
| Trust | Aiur.Events.TrustClassifier; Aiur.GitHub.EventTrust | Consume existing trust authority |
| Source gates | Aiur.Events.SourcePolicy; Aiur.GitHub.EventSourcePolicy | Gate order remains Publisher-owned |
| History writes | Aiur.Events.HistoryStore; Aiur.IssueLog.EventHistorySink | record/3 only; reads remain IssueLog.event_history/2 |
| Trace | Aiur.Events.Trace; Aiur.Events.DebugLog (tui) | Optional sink, outside bus ownership |
| Floors | Aiur.IdFloorSources; application/children.ex | Inject floor_files / legacy_counter_files |
| Journal | Aiur.Events.Journal → Aiur.Journal | Bus replay returns records or tagged error, not kernel prefix triple |
| Persist then publish | Aiur.Events.JournaledPublish.publish/3 | Not Events.publish_journaled/3 |
| Durable cursor | DurableConsumer.Source.position/1 | Dense seq, never event id; ExportSource remains proposed |
| Boot | Aiur.Application.Children.child_specs/1 | Preserve IdGenerator → Exchange → Publisher order |
| Ownership | components/event-bus.json indexed by components.json | Logical L1 component; requires kernel/config |

## Ten citation spot checks

Deterministic random sample (seed 3368) of refreshed, bounded source citations.
Every range below was read from the target object and checked for the named
implementation. Reproduce each with
`git -C "$AIUR_AGENT_WORKSPACE" show 761756f394e6783794c777668fc1a26a540e4059:<path> | sed -n '<start>,<end>p'`
(split comma-separated ranges into separate sed commands).

| Path | Lines | Result |
| --- | --- | --- |
| `src/lib/aiur_web/routes/api.ex` | 51-58 | Resolved at target |
| `src/lib/aiur/events/durable_consumer.ex` | 34-123 | Resolved at target |
| `src/lib/aiur/events/journal.ex` | 9-18 | Resolved at target |
| `src/lib/aiur/events/journaled_publish.ex` | 28-35 | Resolved at target |
| `src/lib/aiur/issue_log.ex` | 387-410 | Resolved at target |
| `src/lib/aiur/executor_attention/cli.ex` | 440-453 | Resolved at target |
| `src/lib/aiur/identity.ex` | 23-60 | Resolved at target |
| `src/lib/aiur/events/journal.ex` | 16-32 | Resolved at target |
| `src/lib/aiur/journal.ex` | 119-155,229-275 | Resolved at target |
| `src/lib/aiur_web/streamdeck_auth.ex` | 8-40 | Resolved at target |

## Size-owner recheck (RC-23)

Ledger: `docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv`
from the target head. Release line counts are historical; current lines below
are counted from that Git object. An old U8 owner label identifies the original
split owner, not permission to grow an oversized file. None of the referenced
current files exceeds 500 lines. Future implementation must recheck at start.

| Ticket | Existing ledger paths (current lines; U8 package) | Outcome |
| --- | --- | --- |
| MP-R2-C5-T01 | src/lib/aiur/alerts.ex (377; EVENTS); src/lib/aiur/executor_events.ex (475; EVENTS) | Owner rechecked; no oversized growth authorized |
| MP-R2-C5-T02 | src/lib/aiur/events/publisher.ex (375; EVENTS); src/lib/aiur/executor_events.ex (475; EVENTS) | Owner rechecked; no oversized growth authorized |
| MP-R2-C5-T03 | New small files / existing paths outside release ledger | Owner rechecked; no oversized growth authorized |
| MP-R2-C5-T04 | New small files / existing paths outside release ledger | Owner rechecked; no oversized growth authorized |
| MP-R2-C6-T01 | src/lib/aiur/config.ex (440; CONFIG); website/docs-app/reference/configuration.md (498; DOCS) | Owner rechecked; no oversized growth authorized |
| MP-R2-C6-T02 | src/lib/aiur.ex (299; APP_BOOT); src/lib/aiur/executor_events.ex (475; EVENTS) | Owner rechecked; no oversized growth authorized |
| MP-R2-C6-T03 | New small files / existing paths outside release ledger | Owner rechecked; no oversized growth authorized |
| MP-R2-C6-T04 | New small files / existing paths outside release ledger | Owner rechecked; no oversized growth authorized |
| MP-R2-C6-T05 | src/lib/aiur/issue_log.ex (472; LIFECYCLE_STATUS) | Owner rechecked; no oversized growth authorized |
| MP-R2-C7-T01 | New small files / existing paths outside release ledger | Owner rechecked; no oversized growth authorized |
| MP-R2-C7-T02 | src/lib/aiur_web/streamdeck_channel.ex (414; DECK_WEB); src/test/aiur_web/streamdeck_channel_test.exs (466; DECK_WEB) | Owner rechecked; no oversized growth authorized |
| MP-R2-C7-T03 | New small files / existing paths outside release ledger | Owner rechecked; no oversized growth authorized |
| MP-R2-C7-T04 | packaging/npm/aiur-cli/libexec/aiur-engine.sh (441; CLI); packaging/npm/aiur-cli/test/launcher.test.mjs (264; CLI) | Blocked on RQ-REFRESH-CLI-1; old extraction no longer applies |
| MP-R2-C7-T05 | src/lib/aiur_web/streamdeck_channel.ex (414; DECK_WEB) | Owner rechecked; no oversized growth authorized |

The child list is now application/children.ex (374 lines); Config is 440 lines,
tracker_settings.ex 175; router.ex 304, endpoint.ex 98, engine 441 and the
agent_control_cli.ex facade 83. Router/endpoint are not rows in this release
ledger; their current dashboard-ui component ownership is not a fabricated U8
WEB assignment. C7-T02 also references DECK_WEB-owned channel fixtures.

## Consumer census and planning drift

CONTRACT-REQUESTS records six foreign-contract corrections and the full
58-artifact source-reference census (including U-unit and additional consumer
tickets). Research line numbers in that census identify immutable input docs.
Build-order ticket copies require the same per-ticket changes during the
coordinator's MP-R1-C11-T02 sweep; they are not restored as duplicate contracts.
The five explicitly named consumer plans/chunks are updated directly here.
Foreign in-flight tickets are not rewritten; their owner/coordinator has the
exact research artifact and correction to post on the active PR.

RQ-REFRESH-CLI-1 blocks MP-R2-C7-T04's old extraction design, not this refresh.
No event-bus regression was found. U3's old self-send stall reorder is already
fixed (processing.ex drains synchronously); the separate multi-publisher id
ordering limitation remains. No production fix is bundled into these docs.

No automated behavior test or mutation test applies to this docs-only change.
