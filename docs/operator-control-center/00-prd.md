# Feature Scope: Aiur Dashboard

**Status:** Proposed · **Working title:** Dashboard
**Primary user:** A human Executor overseeing a supervising AI agent and multiple Aiur ticket agents

## Summary
Extend the existing Aiur dashboard into the Dashboard: a durable, context-rich inbox for decisions requiring human input; an at-a-glance snapshot of work in flight; a history of human- and supervising-agent decisions; recent merged outcomes; and a reliable path for sending a decision back to the appropriate ticket agent.

The problem is not the absence of alerts or agent messaging — those largely exist. The missing layer is a **structured, persistent representation of a decision** and a UX that lets an Executor understand and answer it without reconstructing context from logs. The implementation must **extend and compose** the current event, alert, persistence, messaging, dashboard, and control paths — not create a second message bus, a second agent-control path, or a disconnected source of truth.

## Terminology
- **Human Executor** — the person using the dashboard.
- **Supervising agent** — the top-level AI operating Aiur, monitoring ticket agents, potentially making delegated decisions.
- **Ticket agent** — an Aiur coding agent implementing one ticket.
- **Runtime orchestrator** — Aiur's internal orchestration/scheduler (distinct from the supervising AI agent).
- **Decision** — a fork requiring an explicit choice before work can safely continue.
- **Attention** — a broader "may need awareness" signal; not every attention is a structured decision.

## Problem statement
A run has many active ticket agents; any may hit an ambiguous requirement, architectural tradeoff, destructive op, missing credential, or product choice needing a decision. Today that question can be surfaced (agent messages, attentions, status updates, urgent escalation) but: it can be buried; the Executor may not be watching; a blocked agent idles for hours; the Executor returns without context; a supervising-agent decision may not be recorded; there's no unified history of what was decided, by whom, why; and no reliable view of whether an answer was submitted, delivered, acknowledged, or acted upon. The Executor needs an **asynchronous workflow**: open the dashboard anytime, understand the situation, make several decisions quickly, and trust each answer reaches the right agent.

## Goals
**Primary:** (1) make blocked decisions impossible to overlook (visible until resolved/superseded/dismissed); (2) minimize time-to-understanding (answerable from the detail view with little prior context); (3) minimize time-to-action (1–2 clicks, plus custom response); (4) accurate fleet snapshot (running/queued/paused/blocked/waiting-on-decision/CI/review/retrying/completed/merged); (5) preserve an audit trail (human + supervising-agent decisions, rationale, delivery state, revisions, ticket/PR context); (6) preserve ticket-agent focus (agents surface questions + keep working — no dashboard-page generation, persistence, or polling); (7) reuse existing mechanisms.

**Secondary:** supervising-agent enrichment of raw questions; delegated decisions when policy permits; artifact links (diagrams/screenshots/logs/diffs/code); measure decision wait time.

## Non-goals (initial)
Not replacing the issue tracker/PR provider, the conversation/log viewer, or the orchestrator; no general workflow builder; no second orchestration system; no multi-user/teams/RBAC in v1; no automatic code rollback on revision; no in-dashboard image generation; no long-term cross-run BI; no full state migration to SQLite; the dashboard must not be required for agent execution correctness.

## Design principles
1. **Extend, don't duplicate** — audit + reuse attentions, alerts, event topics, Executor-message queue, pause/resume, LiveView, persistence utils. A Decision is a richer object built on top, not a competing urgent-message path.
2. **The dashboard is a control surface, not the source of correctness** — decision records, dispatch, lifecycle live in the runtime/persistence layer; closing the browser or restarting the dashboard must not lose a decision or block delivery of an already-submitted answer.
3. **Persist before dispatch** — record the decision event, then dispatch; never report success for something neither recorded nor queued.
4. **Append-only audit** — originals remain; corrections create new revision events.
5. **Make uncertainty visible** — distinguish Answer recorded / Dispatch pending / Delivered / Acknowledged / Acted-or-resolved / Delivery failed / Superseded.
6. **Optimize for a low-context Executor** — a card explains the problem, not just "which approach should I take?"

## Required pre-implementation audit
Before new storage/runtime behavior, inspect current + recently-merged: `Aiur.DecisionAttention`, `AlertFeed`, `Alerts`, `AgentEventLog`, `Events.Exchange`, `Events.Publisher`, `Events.SubscriptionStore`, `AgentQueueStore`, `AgentChat`, `Orchestrator.OperatorMessages`, `Orchestrator.HumanReview`, pause/resume/wake/urgent-escalation paths, `AiurWeb.DashboardLive`, `AiurWeb.Presenter`, `AiurWeb.ObservabilityApiController`, dashboard writable-mode + request-security gates, GitHub/tracker PR-state+merge events, `Aiur.JsonStore` + NDJSON logs + existing SQLite usage. The implementation PR must document: which components were reused; which existing component owns each new responsibility; whether the urgent path and structured-decision path are the same or need an adapter; the persistence choice + why; the canonical meaning of a "run"/"session"; and how a submitted decision correlates to its queue item + agent acknowledgement.

## Core user flows
- **A — Ticket agent requests a human decision:** agent hits a fork → emits a structured decision request (existing event/urgent-attention path) → Aiur assigns/validates a stable decision ID + persists → supervising agent may enrich (summary, context, options, recommendation, artifact) → appears in the pending inbox → human selects/writes an answer → Aiur persists → dispatches via the Executor-message queue → target agent resumed/awakened where appropriate → dashboard shows delivery/ack/resolution.
- **B — Supervising agent makes a delegated decision:** agent emits request → supervising agent (within delegated authority) submits choice + rationale + confidence → Aiur persists + dispatches through the **same** lifecycle → history shows "Decided by supervising agent" → human may later inspect/revise (subject to reversal rules).
- **C — Executor returns after being away:** on open, immediately sees decisions needing attention, which are blocking, which agents are running/paused/blocked/retrying/waiting, age of last activity, PR/CI/review/merge status, what changed recently, and what the supervising agent decided while away — without reading raw transcripts for ordinary decisions.

## Dashboard information architecture
**1. Overview** — the control-center overview; summary indicators: decisions needing input, agents blocked/waiting, running, queued/retrying, PRs merged this run/window. The most-urgent count must visually dominate token/runtime metrics when blocking decisions are unresolved.
**2. Fleet state** — one consolidated view of all run work (not just running procs); per row when available: ticket id+title, workflow state, control state, work phase, blocked?, waiting-for, last update + age, runtime + turn count, branch/PR, CI, review, open-decision count, recent summary, links. Waiting reasons must be **explicit** (waiting-for-human/-supervising-agent/-dependency/-CI/-review, paused, backing-off, unresponsive) — never a generic "blocked."
**3. Decision inbox** — first-class; each decision has a stable deep link; ordered blocking→urgency→age→priority; filters (open/blocking/answered-not-delivered/decided-by-supervisor/resolved/superseded/all).
**4. Decision card** — collapsed: ticket, exact question, 1–2 sentence context, blocking chip, age, origin agent, supervisor recommendation, options, lifecycle state. Detail adds: long markdown context, why-needed, consequence-of-delay, options w/ benefits/drawbacks/risk/impact, recommended option + rationale, links, timeline, delivery/ack status, revision history.
**5. Decision actions** — select an option, optional rationale, custom response, defer (without dismiss), acknowledge a non-decision attention, open ticket/PR/logs/conversation; confirm for destructive/irreversible.
**6. Decision history** — human + supervising-agent (+ future system policy) decisions: actor, choice, rationale, timestamp, source version, dispatch result, ack result, later revision/supersede.
**7. Recent outcomes** — merged PRs for the run/window: PR#+title, ticket, merge time, agent, final CI/review, summary, link; label "recent repository merges" when attribution is uncertain.

## Structured decision contract
Agents surface a decision without composing dashboard output. Logical payload (topic naming follows existing conventions): `schema_version`, `event: decision.requested`, `decision_id`, `version`, `ticket{identifier,title,url}`, `source{agent_id,session_id,event_id}`, `kind`, `authority` (human_required / supervisor_allowed / supervisor_preferred), `urgency`, `blocking`, `reversibility`, `question`, `context{short_summary,long_context_markdown}`, `options[]{id,label,description,benefits,drawbacks,risk}`, `recommendation{option_id,reason}`, `consequence_of_delay`, `artifacts[]`, `created_at`. **Required minimum:** stable id (or source identity to derive one), ticket id, origin agent/session, exact question, blocking status, created_at. **Legacy attentions** must still appear via a minimal decision projection (ticket, slug, question, source alert, created_at, custom-response action) — no invented options; a later structured event enriches the same decision (no duplicate).

## Decision lifecycle (state ≠ delivery)
Open → Decided → Dispatching → Delivered → Acknowledged → Resolved; plus Superseded, Expired. Failure states: dispatch-failed, target-agent-gone, stale-version, answer-rejected (already resolved/superseded). A button click must not jump Open→Resolved.

## Decision delivery + correlation
Answers use the existing Executor-message + wake/resume path (unless the audit finds a better already-merged control path). Dispatched message includes decision id, selected option/custom response, human-readable answer, optional rationale, actor type, decision version, link to the question — understandable by an agent without dashboard access. The record retains the queue/request id to show queued-at / delivered-at / delivery-failure / acknowledged-at. Repeated submissions, LiveView reconnects, event redelivery, and API retries must not enqueue duplicate answers.

## Supervising-agent enrichment & autonomy
The dashboard itself must not make a new LLM call per decision; the supervising agent adds/updates context via an existing event/CLI/authenticated-API path. Authority levels as above. When the supervisor decides it must provide selected option/custom answer, rationale, confidence, authority/policy used, alternatives, reversibility belief. Safe defaults keep security-sensitive/destructive/contractual/product/credential/materially-irreversible decisions `human_required` unless explicitly configured.

## Revisions
Use "Revise decision" language (not implied auto-undo). A revision preserves the original, creates a revision event, records who/why, revalidates target activity, dispatches a follow-up when appropriate, and shows accepted/rejected/no-longer-applicable. Aiur must not claim code/commits/migrations/deploys were rolled back merely because a dashboard decision was revised; an un-appliable revision becomes a new blocking follow-up.

## Persistence (decide after the audit)
Prefer extending an existing canonical store. Don't add SQLite just because it's available; don't force complex history into unrelated files to avoid SQLite. **File-first MVP** (if no existing repo fits): append-only NDJSON decision-event log (audit) + atomic JSON projection (fast reads) + a single serializing GenServer + existing crash-safe write behavior + PubSub for refresh + alerts as a notification projection (not the canonical record). **SQLite** is reasonable when the audit shows a suitable shared repo/migration lifecycle, transactional multi-writer needs, immediate cross-run filtering/pagination, relational integrity across decision/delivery/revision/artifact, fragile projection rebuilds, or volume making file scans unsuitable (then include migrations, startup, backup, corruption handling, upgrade tests). **Durability regardless:** open decisions survive Aiur restart; history survives dashboard restart; a crash between persist and dispatch is recoverable; replays don't duplicate; partial writes aren't valid; one documented source of truth; bounded/configurable retention.

## Alerts, dashboard/API, concurrency, artifacts, security
- **Alerts** become a **notification projection** of decisions: opening a blocking decision emits/preserves `needs_attention`; answering/superseding resolves it; reminders update the same decision (no duplicate cards); delivery failure creates a new actionable attention; a supervisor-answered decision stops human reminders unless human review is still requested; the dashboard shows count+age of unresolved decisions even without a new reminder.
- **Live updates** via existing LiveView + PubSub (polling as fallback only). **Read-only mode** shows all info but hides/disables mutations with a clear notice. **Writable mode** honors the existing writable config + browser/API security (no unguarded write endpoint just because a decision is a button). **Machine-readable API** exposes list/get/enrich/decide/revise/inspect-delivery — sharing one application service with LiveView. **Concurrency:** mutations carry/infer the decision version; stale acts are rejected with a conflict + refresh.
- **Artifacts:** reserve an `artifacts` collection from v1 (type/title/description/safe-path-or-approved-URL/mime/actor/created_at); MVP renders markdown, links, approved static images/files only; image generation is a follow-up, never required to open/answer.
- **Security:** sanitize all agent-provided markdown/text; no arbitrary HTML/scripts from decision context; validate ids/versions/lengths/artifact paths; prevent directory traversal; preserve existing auth + same-origin/custom-header protections; don't expose secrets from logs/env; treat agent URLs as untrusted; record the actor for every mutation; fail closed when writable state is unknown; confirm destructive/irreversible.

## Observability
Record request→decision, decision→dispatch, dispatch→delivery, delivery→ack durations, total blocked time, reminder count, human-vs-supervisor actor, whether revised. Existing logs/metrics conventions are fine; no new analytics interface required in the MVP.

## Acceptance criteria (abridged — full list drives the tickets)
Existing-system integration (audit in the PR; no second bus/queue; legacy attentions visible via projection; structured events enrich not duplicate). Decision creation/persistence (one stable decision per request; replays don't duplicate; open decisions survive restart; history survives dashboard restart; blocking decision visible ≤5s locally; stays visible until handled). Context/UX (ticket+question+age+blocking+origin; short/long context; options w/ descriptions+benefits+drawbacks+risk; supervisor recommendation; option-or-custom answer; blocking sorted first; stable deep links). Delivery (durable record before dispatch; ≤1 correlated message per action; recorded/queued/delivered/acknowledged/resolved/failed distinguished; safe wake/resume for paused agents; failed dispatch stays actionable; stale version rejected; retries/reconnects don't duplicate). Supervising-agent (machine-readable authorized decision; same lifecycle; clearly labeled actor + rationale/authority; human_required can't be silently auto-decided). Revisions (original preserved; new event/version; no false rollback claim; un-appliable → explicit follow-up). Fleet/outcomes (distinguish running/queued/paused/blocked/retrying/waiting-human/-supervisor/-CI/-review; per-row last-update+age; open decisions visible from the row; merged PRs w/ links+tickets; uncertain attribution labeled). Dashboard safety (read-only exposes info, no controls; writable honors config+security; correct with no browser; safe rendering; deterministic concurrent answers). Tests/docs (unit: validation/lifecycle/dedup/persistence/revisions/authz; integration: request→dashboard→answer→queue→delivery; restart recovery; LiveView open/answer/failure/read-only/stale; API auth/validation/conflict/idempotency; docs for contract/storage/config/lifecycle).

## Suggested implementation sequence
- **Phase 0 — Audit + design note:** trace the urgent-attention path + Executor-message delivery per backend; determine run/session boundary + PR-merge attribution; select persistence; document before building.
- **Phase 1 — Core decision domain:** contract, persistence + projection, attention adapter, dedup+versioning, answer dispatch via the queue, delivery correlation, PubSub.
- **Phase 2 — Dashboard + API:** overview counts, inbox + detail UI, option + custom actions, history, read-only/writable, machine-readable endpoints.
- **Phase 3 — Full control-center context:** expanded fleet snapshot + explicit waiting reasons + stale-activity, recent merges, latency metrics, revision controls.
- **Follow-ups (non-blocking):** generated diagrams, cross-run search, notification integrations, multi-user identity, decision templates, UI autonomy policies, rich analytics, automated impact analysis.

## Open implementation decisions (resolve in the audit)
Canonical run identifier; history scope (global/per-repo/per-run); does the urgent path already carry enough to be `decision.requested` or need an adapter; can queue consumption serve as acknowledgement or is a separate `decision.acknowledged` needed; what event marks fully-resolved vs delivered; can merges be attributed via existing tracker events or must a labeled window be used; is file-backed history sufficient for volume/filtering; is there a suitable existing SQLite repo or would it create a parallel subsystem; how does an external supervising agent authenticate to the API; which decision categories are eligible for supervisor autonomy by default.

## Definition of done
A ticket agent can raise a decision; the Executor can leave and return later, understand it from the dashboard, select an answer, and see that answer durably travel back to the correct agent — with no dependence on an open terminal, a periodic status message, or a continuously connected browser. The dashboard also shows supervising-agent decisions (rationale + history preserved) and an accurate-enough fleet snapshot to see what is moving, blocked, and recently completed.
