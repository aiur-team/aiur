---
ticket_id: MP-E4-C5-T01
feature_id: MP-E4
chunk_id: MP-E4-C5
bucket: 2-platform
title: "ConversationLive: route, paging, view states and live tail"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C2-T01]
prior_units: [U8]
prior_boundaries: [WEB]
prior_features: []
prior_findings: [DESIGN-E4 §5 states; AGENTS.md "If a surface computes an age, it renders the age"]
size_owner: "U8 WEB owner (new LiveView; dashboard_live.ex 2,903 lines must not grow)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C5-T01 — Conversation view skeleton, states and live tail

## Identity and outcome

- Bucket 2 · MP-E4 · C5 · T01.
- **User value:** a full-page conversation for any worker that loads the latest
  entries fast, pages back to the start, follows new entries live, and states
  honestly when it is empty, partial, stale or unavailable.
- **Deliverable:** `AiurWeb.ConversationLive` at
  `/conversations/:conversation_id` (`?pos=N` reserved for C5-T03) with the
  DESIGN-E4 §5 states, "load older", "jump to start", and live append with a
  "new entries below" affordance. Entries render with a minimal placeholder
  component that C5-T02 replaces.
- **Non-goals:** rich entry rendering (T02), event rail (T03), composer (C6),
  Executor mode (MP-E3-C6 wraps this view).

## Dependencies and blockers

- **DESIGN-E4** (layout, copy, every state in §5, desktop and phone widths).
  Do not start before approval; do not improvise copy.
- MP-E4-C2-T01 (History). Concurrent with: C3, C4.

## Verified starting point

- Live routes live in `live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess`
  (`src/lib/aiur_web/router.ex:139-148`); the drawer route
  `/chat/:owner/:repository/:identifier` opens inside `DashboardLive`
  (`:141`, `dashboard_live.ex:209-234`).
- Drawer state vocabulary and copy: `ConversationDrawer.Presenter`
  (`operator_control_center/conversation_drawer/presenter.ex:188-213`):
  Live, Ended, No messages yet, Stale, Unavailable, Continuity unknown.
- Writable flag: `Endpoint.config(:dashboard_writable) == true`
  (`dashboard_live.ex:1129`).
- `dashboard_live.ex` is 2,903 lines at `45a290e3` (U8 owner): new view goes in
  a new module.

## Chosen design

PROPOSED files: `src/lib/aiur_web/live/conversation_live.ex`,
`src/lib/aiur_web/conversation/presenter.ex` (pure state derivation),
`src/lib/aiur_web/conversation/components.ex` (function components; T02 fills).
Route added inside the existing `live_session :dashboard`:
`live("/conversations/:conversation_id", ConversationLive, :show)`.

**Mount:** validate id (History regex); if `connected?`, `History.subscribe/1`
**then** load `tail` (limit 50) — subscribe-before-read, then drop broadcast
entries with `pos <= page.head_pos` (contract §7 reconnect rule). Entries are a
LiveView stream (`stream(:entries, …, limit: -500)`) so the DOM holds at most
500 entries; older pages are fetched on demand.

**State derivation** (`Presenter.state/2`, pure, from the page, sessions and
the writer's degraded flag):

| State | Rule | Shows |
| --- | --- | --- |
| `:loading` | not yet connected / first page pending | skeleton (no false "empty") |
| `:not_found` | `{:error, :not_found}` | DESIGN-E4 copy |
| `:unavailable` | `{:error, :unavailable}` | reason class, retry |
| `:known_empty` | `head_pos == 0` | "No messages yet" |
| `:live` | last session open, last entry within 10 min | live marker + **age** |
| `:idle` | last session open, last entry older than 10 min | **age** |
| `:ended` | last session ended `stopped`/`turn_limit`/`superseded` | end reason |
| `:restart_unknown` | last session ended `daemon_restart_unknown` with no later session | "Continuity unknown" |
| `:degraded` | journal writer reported degraded (PubSub flag from C1-T02's alert path) | last known content + stale marker + age |
| `:partial` (modifier) | `complete_from_start == false` | "Earlier history is not available" at the top |

- Every age shown is computed from `observed_at` and rendered (AGENTS.md rule):
  `observed_at`, `age_ms`, and a `freshness` atom in assigns, rendered as text.
- Unknown session end reasons map to `:unknown` (cause-neutral), never to a
  specific state (AGENTS.md "collapsed causes").

**Paging:** "Load older" → `before: first_pos`, prepended with
`stream_insert(at: 0)`, scroll position kept by a small hook
(`ConversationScroll`, PROPOSED, registered in `layouts.ex` Hooks object,
`components/layouts.ex:41-113`). "Jump to start" → `from_start`.

**Live tail:** `{:entries_appended, id, entries}` → if the client reports it is
at the bottom (hook event `at_bottom`), insert; else insert and increment
`new_below`, shown as a button that scrolls down.

## Implementation steps

1. Presenter with `state/2`, `age/2` (pure, fully unit-tested).
2. LiveView: mount, `handle_params`, `handle_event("load_older" | "jump_start" |
   "at_bottom")`, `handle_info({:entries_appended | :session_changed, …})`.
3. Placeholder entry component; session divider component (from `sessions`).
4. Route line.

## Non-happy paths

- Reconnect after a socket drop: LiveView remounts; subscribe-then-tail means no
  gap; duplicates are dropped by `pos`.
- Writer slow: the view reads files directly and is unaffected.
- Huge conversation: only pages are read; the stream limit caps DOM size.
- Not authenticated: standard dashboard auth (`:dashboard_auth` pipe).
- Read-only dashboard: no change here (no write controls in this ticket).

## Compatibility and rollout

- New route; nothing links to it until C5-T04. Rollback: remove the route.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/conversation/presenter_test.exs test/aiur_web/live/conversation_live_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| presenter "each §5 state from its fixture" (table test) | the state atom | each `state/2` clause |
| presenter "unknown end reason is :unknown, not :ended" | `:unknown` | cause-neutral fallback (mutation: map to `:ended` fails) |
| presenter "idle renders the age; age absent is not rendered as 0" | age text from `observed_at`; `nil` → "age unknown" | `age/2` (mutation: replace nil branch with `0` fails) |
| live "mount shows tail page in pos order" | last 50 entries | mount load |
| live "broadcast during mount is not duplicated" | each pos once | subscribe-then-read + drop rule |
| live "load older prepends and keeps the anchor entry in view" | prepended entries | `load_older` |
| live "new entries while scrolled up show the counter" | `new_below` text "3 new" | counter path |
| live "unknown id renders not_found, not empty" | not_found copy | not_found branch |
| live "partial history shows the banner" | banner present | `complete_from_start` check |

Browser (`src/browser`): add `tests/conversation-view.browser.spec.mjs`, npm
script `test:conversation-view`, run
`npm --prefix src/browser run fixture:preflight && env -C src/browser node scripts/run-browser-tests.mjs tests/conversation-view.browser.spec.mjs`;
fixture: a synthetic journal of 2,000 entries written by a new builder in
`src/test/support/browser_harness/fixtures.ex` into a temp
`:conversation_state_dir`. Checks: first paint shows the last entries; "Load
older" keeps scroll position; no horizontal scroll at 390 px width.

## Completion and handoff

- [ ] Every DESIGN-E4 §5 state reachable in a test.
- [ ] Browser spec added to the `test` npm script.
- Dependents: C5-T02, C5-T03, C5-T04, C6-T01, MP-E3-C6-T01.
- Docs: in C5-T04 (the page is linked there).
