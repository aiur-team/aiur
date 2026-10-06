---
design_task: DESIGN-R2
feature_id: MP-R2
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-R2 implementation ticket (MP-R2-C1..C7)
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R2/plan.md
related_contract: ../contracts/events-and-replay.md
---

# DESIGN-R2 — Kevin: confirm the event bus refactor changes nothing you see, and approve the two configuration/operator surfaces it adds

**Implementation of MP-R2 is blocked until this task is approved.** Research
and planning may continue. Do not mark this task complete without Kevin's
explicit approval in writing (a comment on the research PR or a line in
`context-and-decisions.md`).

## 1. What this gate confirms

MP-R2 is a Bucket 1 refactor. Its packaging chunks (C1–C4) move the existing
topic exchange, publish boundary, durable cursors and the Executor journal into
one component with the same behaviour. **No dashboard page, TUI view, Stream
Deck key, CLI output line, alert text, sound, or agent tool changes in those
chunks.**

Kevin confirms:

- [ ] **No user-facing change is intended in C1–C4.** Every existing surface
  (dashboard, `/commands`, `/streamdeck`, the Stream Deck sidecar, `aiur status`
  `WAKES CURSOR … PENDING …`, `executor-wait`/`executor-listen`/`executor-emit`,
  agent `aiur_subscribe`/`emit_event`) looks and behaves the same before and
  after. Regressions found in review are bugs, not design changes.
- [ ] **The existing event names stay as they are.** Topic strings
  (`ticket.<id>.<surface>.<verb>`, `system.…`, `executor.…`) do not change in
  this feature. Any rename is a later, separately approved change.

## 2. Surfaces this feature does add (approve or reject each)

C5–C7 are additive: they create the contract that later features (E1, E2, E4,
N3–N5) consume. They add no screens. They do add operator-visible
configuration and diagnostics, which need Kevin's decision:

| # | Surface | What Kevin decides | Default proposed by the plan |
| --- | --- | --- | --- |
| S1 | `events.export.retention` config key (how long/how many exported events the daemon keeps on disk for reconnecting clients) | The default retention, and whether it is user-configurable at all | 7 days **or** 50,000 events, whichever is smaller; configurable |
| S2 | `aiur events tail [--after <id>] [--topic <pattern>] [--json]` CLI (read-only view of the exported event feed) | Whether this command should exist for operators, or the feed stays API-only until a client needs it | Exists, read-only, JSON lines; no write verb |
| S3 | `aiur status` line for the export feed (e.g. `EVENTS HEAD <id> RETAINED <n> OLDEST <age>`) | Whether status prints it, and the wording | Print one line only when the export feed is enabled |
| S4 | Behaviour when a reconnecting client's cursor is older than retention | Accept the plan's rule: the client receives a `reset` and must re-read snapshots; no burst of stale events | `reset` + snapshot; never replay stale events as fresh notifications |

No dashboard UI is proposed for the event feed. If Kevin wants an event
browser, that belongs to MP-E4 (DESIGN-E4), not here.

## 3. States (configuration and CLI only)

| State | Required behaviour to approve |
| --- | --- |
| Feed disabled (default before a consumer exists) | `aiur events tail` prints `event export is disabled (events.export.enabled: false)` and exits non-zero; `aiur status` omits the line. |
| Empty | `tail` prints nothing and waits (or exits 0 with `--no-follow`). |
| Daemon offline | `tail` exits non-zero with the same "not running" wording the other control commands use. |
| Permission denied | API returns 401/403 with no event content; CLI reports the auth failure, never a partial feed. |
| Cursor older than retention (stale) | One `reset` record naming the oldest retained id, then live events. |
| Journal corrupt | `tail` and the API return `events_unavailable`; an `alert` with `needs_attention` fires once (same pattern as the Executor journal today). |
| Success | JSON lines with the envelope in `contracts/events-and-replay.md` §3. |

## 4. Decisions needing Kevin's input

- **KQ-R2-1.** Retention default (S1). Engineering cannot pick the right
  trade-off between disk use and how long a phone may be offline.
- **KQ-R2-2.** Whether the operator CLI `aiur events tail` (S2) ships with the
  feed, or the feed stays API-only.
- **KQ-R2-3.** Whether exporting events to an *external* client may include
  free-text fields at all (Command titles, comment excerpts), or whether the
  external feed is identifiers-only and clients fetch text from the
  authenticated source API. The plan proposes **identifiers-only** (same rule
  the Executor wake records follow today).

## 5. Acceptance conditions for this gate

1. Kevin ticks both boxes in §1.
2. Kevin approves, edits or rejects S1–S4, and answers KQ-R2-1..3.
3. The answers are copied into `context-and-decisions.md` as numbered
   decisions, and `contracts/events-and-replay.md` is updated to match.

Until then, C1–C4 tickets carry `Blocked-by: DESIGN-R2 §1` and C5–C7 tickets
carry `Blocked-by: DESIGN-R2 §2`.
