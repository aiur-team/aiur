# OCC — brainstorm grounding + ticket decomposition

> Historical OCC planning artifact. The shipped product is now the **Executor
> Control Center**; legacy terminology below is preserved as historical context.

## Grounding (verified against origin/main)
OCC **extends existing plumbing** rather than inventing parallel systems. Confirmed present:
- `AiurWeb.DashboardLive` (`src/lib/aiur_web/live/dashboard_live.ex`) + `AiurWeb.Presenter` — the live dashboard + its data (running agents, retry, logs, writable chat/pause controls).
- `Aiur.DecisionAttention` — turns unanswered agent questions into durable, repeating alerts.
- `Aiur.AlertFeed` / `Aiur.Alerts` — reads/resolves persisted attention alerts.
- `Aiur.Orchestrator.OperatorMessages` — queues responses back to agents.
- `Aiur.Events.SubscriptionStore` — persists open-attention slugs across restarts.
- `Aiur.AgentQueueStore`, crash-safe JSON/NDJSON patterns, Ecto+Exqlite deps.
- `dashboard_writable` config gate (write controls are gated).

So the missing layer is **a structured, persistent Decision object + an operator UX to answer it** — built on the above, not beside it.

## Scoping decisions (operator, this session)
1. **Full scope is v1**, but delivered as **many parallelizable tickets**, not one mega-PR.
2. **Claude designs a mock** (HTML artifact w/ example data); the **UI ticket is blocked** on the operator supplying the mock URL, then productionizes it.
3. **Link** OCC to #930's offline telemetry/analytics dashboard — keep them as two separate surfaces.
4. Tickets route to **codex 5.6 sol / max**.

## Ticket decomposition (proposed — the ce-plan step turns each into a full `tickets/OCC-*.md`)

| Ticket | Scope | Depends on | Parallel with |
|---|---|---|---|
| **OCC-0** Audit + design note | Trace the existing attention/alert/message/dashboard/persistence/PR-attribution paths; pick persistence (file-first NDJSON vs SQLite — do not add SQLite reflexively); define the run/session boundary. Output: a design-decision doc. | — | — (must land first) |
| **OCC-1** Decision domain + persistence | The `decision.requested` contract + `Decision` object, persistence, current-state projection, dedup + versioning, owning GenServer, PubSub. | OCC-0 | — (blocks most) |
| **OCC-2** Attention→decision adapter | Project existing unstructured attentions into minimal decisions; enrich (not duplicate) when a structured event later arrives. | OCC-1 | 3,5,6,9 |
| **OCC-3** Answer dispatch + delivery correlation | Persist-before-dispatch; dispatch via `OperatorMessages`; correlate queued/delivered/acknowledged/failed; idempotency (no dup on retries/reconnects); stale-version conflict. | OCC-1 | 2,5,6,9 |
| **OCC-4** Decision inbox + card/detail UI ⛔ | LiveView inbox, cards, detail, actions (select / custom / defer / ack / confirm-destructive), deep links, read-only vs writable. **BLOCKED on the Claude-design mock URL.** | OCC-1, OCC-3, **mock URL** | 5,6 |
| **OCC-5** Fleet-state expansion | Expand the snapshot: explicit waiting reasons (not generic "blocked"), stale-activity ages, PR/CI/review status, open-decision count per row. | OCC-1 | 2,3,4,6 |
| **OCC-6** History + recent outcomes + analytics link | Decision history (human + supervising-agent actors, revisions), merged-PR outcomes panel (label attribution honestly), link out to #930 analytics. | OCC-1 | 2,3,4,5 |
| **OCC-7** Supervising-agent autonomy + decision API | Authority levels (human_required / supervisor_allowed / supervisor_preferred), machine-readable decision API (list/get/enrich/decide/revise), supervisor delegated decisions, safe human-required defaults for destructive/credential/product/irreversible. | OCC-1, OCC-3 | 5,6,8 |
| **OCC-8** Revisions | Revise-decision flow: preserve original, new revision event, revalidate target, follow-up dispatch, no false "rolled back" claims. | OCC-1, OCC-3 | 5,6,7 |
| **OCC-9** Decision latency metrics | request→decision, decision→dispatch, dispatch→delivery, delivery→ack, blocked-time, reminder count, actor, revised? | OCC-1 | 2,3,5,6 |

### Critical path & parallelism
`OCC-0` → `OCC-1` → `OCC-3` → { `OCC-4`(+mock), `OCC-7`, `OCC-8` }. Once **OCC-1** lands, `OCC-2/5/6/9` all run in parallel. **OCC-5** (fleet state) is the most independent (builds on Presenter) and can start right after OCC-1. The UI (**OCC-4**) is the only ticket gated on an external input (the mock URL).

### Notes for the ce-plan writers
- Every ticket doc must reuse-not-duplicate (name the existing module that owns each new responsibility) and honor persist-before-dispatch + append-only audit.
- Each is a **research-then-build** ticket for codex sol/max; OCC-0 is pure research (design note, no impl).
