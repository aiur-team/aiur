# BO: DASH-027 — Render accessible conversation drawer

**Kind:** executable

**Provenance:** planned in plan v1 after shipped-dashboard and refreshed-prototype interaction audit

**Complexity:** 3 — Responsive modal-drawer interaction with live updates, focus restoration, and truthful source states

**Risk:** medium

**Phase hint:** 7

**Depends on:** DASH-003, DASH-026

**Serializes with:** DASH-005, DASH-007, DASH-015, DASH-021, DASH-022, DASH-028, DASH-031, DASH-034 — shared Units actions, `DashboardLive`, and dashboard CSS/component composition

**Resolved predecessor baseline:** `origin/main@9849f32963c2a65367bce565b3f5ede3777c218f` — the shipped OCC predecessor is present; no external gate remains

**Requirements:** DREQ-027

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:7`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

An Executor can open a clearly read-only, responsive, keyboard-accessible conversation drawer from an eligible Units action and follow the exact DASH-026 snapshot without exposing paths, raw payloads, or confusing conversation with ticket context.

## Context and evidence

Current main makes a running Fleet row itself clickable and opens `AgentLogModal`, which displays a local log path and path-derived messages and may also contain message/pause controls. The prototype separates row ticket context from an explicit Read chat action and labels its conversation drawer a read-only mirror. DASH-003 owns Units row inspection through BO-018 ticket context; this ticket owns only the distinct Chat destination and must not turn ticket Logs/history into a transcript.

## Scope

- Add an explicit, named `Read conversation` action for a Units row whose DASH-026 capability is available. Row activation itself continues to open DASH-003/BO-018 ticket context; a non-focusable clickable `<tr>` is never the drawer trigger.
- Render DASH-026 title/typed ticket identity, normalized agent/model/session metadata when known, live/ended/source state, bounded messages, truncation, health, freshness, and last observation. Unknown optional facts remain labelled unknown.
- Render the conversation as a read-only mirror with semantic role labels, timestamps when known, safe text/tool summaries, non-color system transitions, and an explicit statement that the viewer is not participating.
- Implement a modal side drawer on wide screens and full-width dialog on narrow screens with labelled heading, initial heading/close focus, focus trap, Escape and close-button behavior, background inertness, scroll containment, and deterministic focus return to the exact originating action.
- Subscribe through the dashboard's existing coalesced update path and replace only the selected generation's snapshot. Preserve the reader's position while reviewing older content; auto-follow only when already at the end, with a named jump-to-latest control when new messages arrive.
- Close or transition truthfully when the row leaves scope, the worker generation changes, or the source becomes unavailable. Never silently display a replacement worker's conversation under the old heading.
- Preserve the current separately authorized operator-message/pause path until its owning control work explicitly migrates or removes it; this read-only drawer neither invokes nor embeds those actions.

## Non-goals

- Read workspace files, call `Aiur.AgentLog.read_workspace/1` during render, display a local path, or render unknown/raw event JSON.
- Send messages, pause/resume agents, change capacity, open unvalidated Remote Control URLs, or account Remote Control/provider usage.
- Render ticket description, progress, dependencies, blocker relationships, or the BO-019 activity/BO-018 Logs timeline.
- Add transcript search, export, unbounded history, or durable browser storage.

## Existing owner and reuse target

Extend DASH-003's explicit Units action seam and current `DashboardLive` modal/focus conventions. Consume DASH-026 snapshots only. Reuse the shell's authenticated/read-only presentation and trusted navigation policy, but do not reuse `AgentLogModal`'s path-bearing model as drawer input.

## Contract and invariants

- The drawer is always a read-only projection. No form, command, pause, message, or mutation handler exists in its component.
- Ticket context and conversation are separate destinations with separate named controls, headings, and focus lifecycles.
- Rendering consumes one normalized DASH-026 snapshot and performs no filesystem, log, process, GitHub, or agent-provider read.
- Generation identity is pinned while open. A replacement requires an explicit state/close and new invocation; it cannot silently swap content.
- DOM order equals visual/order announcement order. Live changes are bounded/coalesced and do not steal focus or scroll.
- Local paths, raw JSON/payloads, prompts, reasoning, credentials, account details, and capability URLs never appear in markup, attributes, client hooks, or errors.

## Refreshable implementation notes

- Refresh DASH-003's final action/component names, DASH-026 snapshot shape, current `AgentLogModal` focus behavior, and prototype drawer tokens at pickup.
- Prefer a pure presenter plus a small LiveComponent fed by cached snapshots. Client hooks may manage scroll/focus only; they do not fetch, parse, classify, or persist conversation data.
- Remove path/raw display from the new Chat route, but preserve unrelated current writable controls until their owning ticket establishes the replacement behavior.

## Acceptance and verification

### Agent gate

- Component/LiveView tests cover available, known-empty, live, ended, stale, unavailable, restart-unknown, truncated, generation-replaced, row-filtered, and source-recovered states.
- Browser/a11y tests cover explicit action naming, keyboard/touch open and close, focus entry/trap/Escape/return, background inertness, long-message wrapping, nested scroll, jump-to-latest behavior, reduced motion, forced colors, theme, 200% zoom, and 320/390/768/960/desktop layouts.
- Security tests prove rendering performs no workspace/log/provider read and no path, raw event JSON, prompt/reasoning, credential, account, or unsafe URL reaches the DOM.
- Regression tests prove ordinary row activation still opens ticket context and the drawer exposes no message/pause/capacity event handler.

### At-merge gate

- Rebase on DASH-003/026 and current main, sequence shared dashboard files with
  the declared UI peers, and pass Units, ticket-context, AgentLog compatibility,
  LiveView, browser accessibility, security, asset, and full CI gates.

### Human/manual evidence

- From the Executor repository root, run the real `scripts/aiurdev --test` UI, open the explicit conversation action by keyboard and touch at desktop and 390px, observe live and ended updates without focus/scroll theft, exercise stale/unavailable and generation replacement, and verify close returns focus to the originating row action.

## Failure, security, migration, and accessibility cases

- On source failure, retain only DASH-026's visibly stale same-generation snapshot or show its named unavailable state. Never fall back to path reads or a fabricated empty conversation.
- Escape all safe text and render no raw HTML. Preserve current Basic Auth/read-only boundaries and never leak server paths or capability material.
- Existing Fleet/AgentLog behavior can coexist during rollout; route/action migration must be explicit and reversible without deleting separately authorized controls.
- Semantic dialog structure, native controls, visible focus, non-color roles/states, touch targets, reduced motion, forced colors, and zoom support are required.

## Surfaces

- Reads: DASH-003 Units action/row identity, DASH-026 snapshots and change notifications, dashboard auth/read-only state.
- Writes: conversation drawer presenter/component, explicit Units Chat action, focus/scroll hook, responsive tokens, component/browser/security tests.
- Contracts: read-only Chat destination; drawer focus/live-update lifecycle; no-I/O render boundary.

## Sibling boundaries and open gates

DASH-003 and BO-018 own row ticket context; BO-019 owns ticket activity/history;
DASH-026 owns transcript normalization and retention. DASH-005 owns unit pause/
resume, DASH-028 owns capacity, and any operator-message or Remote Control action
requires its own authoritative capability contract. This drawer does not absorb
any of them.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-027`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
