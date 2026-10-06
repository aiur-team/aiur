---
ticket_id: MP-E4-C5-T03
feature_id: MP-E4
chunk_id: MP-E4-C5
bucket: 2-platform
title: "Event navigation: jump-point list with filters, jump to position, precision display, Command chips"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C5-T02, MP-E4-C4-T01, MP-E4-C3-T02]
prior_units: [U8]
prior_boundaries: [WEB, PRJ]
prior_features: [MP-N6 (phone "open in context" lands on the same ?pos= URL)]
prior_findings: [plan acceptance 4, 7; DESIGN-E4 decisions 1, 2, 7]
size_owner: "U8 WEB owner"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C5-T03 — Event navigation and jump

## Identity and outcome

- Bucket 2 · MP-E4 · C5 · T03.
- **User value:** pick "PR merged", "Pushed 3f9a1c0" or "Command requested" and
  land on that place in the conversation, highlighted, in one round trip
  (plan acceptance 7).
- **Deliverable:** the event navigation surface per DESIGN-E4 decision 1
  (rail, list or split), kind filters (defaults from `JumpPoints.entry/1`),
  `?pos=N` deep link handling, highlight, precision indicator per decision 7,
  unanchored events listed without a jump, Command chips linking to
  `/commands/:decision_id`.
- **Non-goals:** new jump-point kinds (C4-T01 owns the catalogue).

## Dependencies and blockers

- DESIGN-E4 decisions 1 (layout), 2 (default kinds), 7 (precision visibility).
- MP-E4-C5-T02, MP-E4-C4-T01, MP-E4-C3-T02.

## Verified starting point

- Anchors come from `History.list_anchors/2` (C2-T01) and live
  `{:anchor_added, …}` broadcasts (C3-T02).
- Precedent for event → transcript jumping: the Stream Deck logs mode keys and
  `select_event/2` (`src/lib/aiur_web/streamdeck_logs.ex`), which only work on a
  50-row window; this view uses positions instead.

## Chosen design

- **Data:** on mount, `list_anchors(ref)` (strongest per event), sorted by
  `event.observed_at`, then `event_id`. Live additions via `{:anchor_added}`
  replace a weaker anchor of the same event in place.
- **Jump:** selecting an anchor `push_patch`es to `?pos=<pos>`;
  `handle_params/3` with `pos` loads `around: pos` (limit 50), resets the stream,
  and assigns `highlight_pos`. A hook (`ConversationScroll`, from T01) scrolls
  the highlighted entry into view. `placement: "after"` renders a marker below
  the entry instead of highlighting it (contract §10).
- **Unanchored:** listed with its time and label, no link, and the DESIGN-E4
  copy ("Not linked to a position").
- **Precision:** if decision 7 says visible, observed anchors read "approximate";
  else no indicator. Exact/causal never say approximate.
- **Filters:** chips per kind; defaults from `JumpPoints.entry/1.default_visible`;
  the choice is per-viewer and stored in `localStorage` through the hook
  (convenience only; failure falls back to defaults).
- **Command chips:** `command_requested` anchors render a chip linking to
  `/commands/:decision_id`; `command_resolved` shows "answered".
- **Deep links:** `/conversations/:id?pos=N` is the URL MP-N6 and C4-T02 use.
  `pos` beyond head → "Position not found" notice + tail.

## Implementation steps

1. Components: `event_nav/1`, `event_item/1`, `filter_chips/1`, `entry_marker/1`.
2. `ConversationLive.handle_params/3` `pos` branch; `handle_info({:anchor_added…})`.
3. Hook additions: scroll-to-highlight, filter persistence with try/catch.

## Non-happy paths

- Anchor whose `pos` is beyond the current head (writer behind) → retry once after
  the next `entries_appended`, else show "Position not found".
- Hundreds of events: the list is virtualized by the stream (limit 1,000 items;
  older events load on scroll).
- Two events at one `pos` → both listed; both markers at that entry ordered by
  `event_id`.
- Read-only dashboard: navigation works fully.

## Compatibility and rollout

- Additive to the view. Rollback: revert the components.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/live/conversation_live_navigation_test.exs
npm --prefix src/browser run fixture:preflight
env -C src/browser node scripts/run-browser-tests.mjs tests/conversation-jump.browser.spec.mjs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "?pos=N loads around N and highlights it" | entry N has highlight class; N−25..N+24 present | `pos` branch |
| "observed anchor renders a marker after the entry, not a highlight" | marker element below N | placement handling |
| "unanchored event has no link" | no `href`/`phx-click` on the item | the unanchored branch (mutation: jump to nearest fails) |
| "stronger anchor arriving live replaces the weaker one" | one item, exact | replace-in-place |
| "pos beyond head shows Position not found" | notice + tail | bounds check |
| "default filters follow JumpPoints defaults" | hidden kinds absent | filter defaults |
| browser "jump to a merged-PR anchor highlights the entry" (plan acceptance 7) | highlighted entry visible in viewport after one click | end-to-end jump |
| browser "from a Command, Open in conversation lands on the request" | highlighted command tool entry | C4-T02 link + this handler |

Manual (AGENTS.md "Manual testing"): run `scripts/aiurdev --test` per the
non-TTY recipe, let a sandbox ticket emit progress and open a PR, open
`/conversations/<id>` in a browser, click "PR opened", confirm the highlight.

## Completion and handoff

- [ ] Plan acceptance 4 and 7 demonstrated (tests + manual note in PR).
- Dependents: MP-N6, MP-E3-C6 (Executor jump points).
- Docs: C5-T04.
