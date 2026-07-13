# Claude design prompt — Aiur Executor Control Center (mock)

> Paste everything below the line into Claude. It produces a self-contained, clickable HTML
> mockup (an Artifact) of the new dashboard, populated with realistic example data. The mock's
> URL becomes the design reference the implementation ticket productionizes into LiveView.

---

You are the design lead building a **working HTML mockup** of a new dashboard called the **Aiur Executor Control Center**. Deliver it as a single self-contained, theme-aware, clickable HTML Artifact populated entirely with **realistic example data** — no backend, no real API. It is a high-fidelity prototype an engineer will later reproduce in Phoenix LiveView, so the layout, information hierarchy, states, and interactions must be complete and unambiguous.

## What Aiur is (context)
Aiur runs a fleet of AI coding agents: a **human Executor** oversees a **supervising agent** (a top-level AI that monitors the fleet) and many **ticket agents** (each implementing one GitHub ticket). The Executor is often away and returns asynchronously. The single most important job of this dashboard is: **let an Executor open it cold, instantly see what needs a decision, understand each decision without reading logs, answer it in one or two clicks, and trust the answer reached the right agent.**

## Starting point — evolve the existing dashboard, don't start blank
The current Aiur dashboard lives in `src/lib/aiur_web/live/dashboard_live.ex` (inline HEEx) with data shaped by `src/lib/aiur_web/presenter.ex`. Match and extend its visual language:
- A dark, engineering/terminal-adjacent aesthetic. Structure: a `dashboard-shell` wrapper, a `hero-card` header (eyebrow + hero copy + a `status-stack` of pill `status-badge`s: info / **live** (green dot) / offline), an `error-card`, a `metric-grid` of `metric-card`s (big number + small label), then agent rows.
- Per-agent data already available (use these field names in your example data): `issue_identifier`, `title`, `state`, `status`, `running`, `retrying`, `started_at`, `last_event`, `last_event_at`, `last_message`, `queue_depth`, `restart_count`, `current_retry_attempt`, `input_tokens`, `output_tokens`, `rate_limits`, `capabilities`, `recent_events`, `session_id`, `host`.
Keep that DNA; the Control Center is a superset, not a redesign from zero. Make both light and dark themes first-class.

## The final state — required information architecture
Build these surfaces. Layout may be tabs, sections, or routes, but every capability must be present and every decision must have a stable deep-link anchor.

**1. Overview (top of page).** Summary counts: *Decisions needing input* · *Agents blocked/waiting* · *Running* · *Queued/retrying* · *PRs merged this run*. **When one or more blocking decisions are unresolved, that count must visually dominate** every token/runtime metric (size, color, position). When zero, it recedes.

**2. Decision inbox (the hero feature).** A durable list of decisions requiring human input, **sorted blocking-first, then urgency, then age**. Filters: Open · Blocking · Answered-not-delivered · Decided-by-supervising-agent · Resolved · Superseded · All. Each item is a card.

**3. Decision card (collapsed).** Ticket id + title · the exact question · a 1–2 sentence context summary · blocking/non-blocking chip · request age · originating agent · supervising-agent recommendation (when present) · the available options · current lifecycle state.

**4. Decision detail (expanded).** Longer markdown context · *why this decision is needed* · *what happens if no one answers* (consequence of delay) · each option with **benefits / drawbacks / risk / downstream impact** · the recommended option + rationale · links (issue, PR, commit, files, logs) · an activity+decision timeline · delivery/acknowledgement status · revision history.

**5. Decision actions.** Select an option (1–2 clicks) · write a custom response instead · defer (without dismissing) · acknowledge a non-decision attention · open the ticket/PR/logs. **Destructive/irreversible choices require a confirm step.** Use the label "Revise decision" (never imply auto-rollback).

**6. Fleet state.** One consolidated table of ALL run work (not just running processes). Per row, when available: ticket id+title · workflow state · agent control state · current work phase · blocked? · **explicit waiting reason** · last meaningful update + its age · runtime + turn count · branch/PR ref · CI status · review status · open-decision count · a short progress summary · links to logs/issue. **Never collapse waiting into a generic "blocked"** — show the real reason: *waiting for human decision · waiting for supervising-agent decision · waiting for dependency · waiting for CI · waiting for review · paused by Executor · backing off before retry · agent unresponsive.*

**7. Decision history.** Decisions made by the **human Executor** and by the **supervising agent** (label each unambiguously, e.g. "Decided by supervising agent"). Per entry: actor · choice · rationale · timestamp · dispatch result · acknowledgement result · any later revision/superseding decision.

**8. Recent outcomes.** Merged PRs from this run: PR# + title · related ticket · merge time · responsible agent · final CI/review state · a short summary · link. If run-attribution is uncertain, title the panel "Recent repository merges," not "current-run merges."

**9. Link out to analytics.** A clear link/button to Aiur's **offline telemetry & analytics dashboard** (a separate, post-run resource-and-lifecycle report). Just a link — do not rebuild those charts here.

## The delivery lifecycle must be visible (a core idea)
A decision is not "done" the instant a button is clicked. Encode these states distinctly (chips/colors), and show a decision progressing through them in the mock: **Recorded → Dispatch pending → Delivered → Acknowledged → Resolved**, plus **Delivery failed** and **Superseded**. Answering must never jump straight from Open to Resolved.

## Modes and actors
- **Read-only vs writable:** design both. In read-only, all information (inbox, detail, history, fleet, outcomes) stays visible but every action control is hidden/disabled with a clear "dashboard controls are disabled" note.
- **Three actors**, visually distinct: human Executor, supervising agent, ticket agents.

## Example data to populate (make it feel real)
- **3–4 pending decisions** in varied states: one *blocking, human-required* with 2 options + a supervising-agent recommendation; one *answered-but-delivery-pending*; one *decided by the supervising agent* (with rationale + confidence); one *legacy attention* (just a question + custom-response, no invented options). Give them real-sounding aiur questions (e.g. "Should retries be restored after a daemon restart, or stay process-local?").
- **6–8 fleet rows** spanning running / waiting-for-CI / waiting-for-human-decision / paused / backing-off-before-retry / merged / agent-unresponsive — each with a plausible waiting reason, ages, PR/CI/review status.
- **A few history entries** (mix of human + supervising-agent decisions, one revised).
- **2–3 recent merged PRs** with tickets + summaries.

## Design + build constraints
- Single self-contained HTML file: inline all CSS/JS, embed any assets as data URIs, no external requests.
- Theme-aware: light and dark both first-class; the viewer's toggle must win.
- Interactive: clicking a decision opens its detail; selecting an option animates the lifecycle chips through Recorded→Dispatch pending→Delivered; a filter/tab switch works; a read-only toggle demonstrates the disabled state.
- Executor-scannable: summary before detail; state encoded in **form** (a pill, a severity stripe, a dot) as well as text, so what needs attention reads at a glance. Semantic color (needs-input / blocked / good) separate from the accent hue.
- Wide tables/timelines scroll inside their own container; the page body never scrolls sideways.
- Real copy, no lorem. Write from the Executor’s side of the screen (a control says exactly what happens; a failed delivery explains what to do).

Deliver the Artifact, then give me a two-paragraph note: (1) the key layout/hierarchy decisions and why, (2) anything you deliberately left for the engineer to resolve when wiring it to real data.
