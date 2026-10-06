---
ticket_id: MP-E4-C5-T04
feature_id: MP-E4
chunk_id: MP-E4-C5
bucket: 2-platform
title: "Links into the conversation view (drawer, units table), phone-width proof, GUI guide"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C5-T03]
prior_units: [U8]
prior_boundaries: [WEB]
prior_features: [MP-N1 (the phone reuses this view in a WebView)]
prior_findings: [DESIGN-E4 decision 6 (drawer kept or replaced); §3 "Links in"]
size_owner: "U8 WEB owner (conversation_drawer.ex 276 lines; dashboard_live.ex must not grow beyond the link assign)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C5-T04 — Link-in, phone width and docs

## Identity and outcome

- Bucket 2 · MP-E4 · C5 · T04.
- **User value:** the full conversation is reachable from where the operator
  already looks (the conversation drawer and the units table), works at phone
  width, and is documented.
- **Deliverable:** per DESIGN-E4 decision 6 either (a) a "Full conversation"
  link in the drawer and a units-row action, or (b) the drawer route
  `/chat/:owner/:repository/:identifier` redirects to the full view; a
  phone-width browser proof; a "Conversations" section in
  `website/docs-app/guide/gui.md`.
- **Non-goals:** removing the drawer unless decision 6 says so; Stream Deck
  links (C7).

## Dependencies and blockers

- DESIGN-E4 decision 6 and the §3 "Links in" list (units table, Commands page
  — C4-T02 —, build-order ticket context, Stream Deck, phone notifications).
- MP-E4-C5-T03.

## Verified starting point

- Drawer component attrs (`components/operator_control_center/conversation_drawer.ex:19-27`)
  and its header area (`:55-95`); `DashboardLive` resolves the drawer from the
  units snapshot row (`dashboard_live.ex:209-234`) and has the row's
  `TrackerIdentity`.
- `Conversation.Ref.worker/1` + `Ref.conversation_id/1` (C1-T01) turn a row
  identity into the URL without I/O.
- Docs: `website/docs-app/guide/gui.md` has "The pages" and "Writable controls"
  sections (`:49-104`); sidebar `website/docs-app/.vitepress/config.ts:146-152`.

## Chosen design

- **(a) keep drawer:** drawer gets `attr(:full_conversation_href, :string,
  default: nil)` and renders a link in its header when set; `DashboardLive`
  computes it from the row identity (≤ 5 lines). Units table row gets the same
  link in its actions menu (component, not `dashboard_live.ex`).
- **(b) replace drawer:** the `/chat/...` route keeps working by
  `push_navigate` to `/conversations/:id` after resolving the row; the drawer
  component is left in place for one release, unused, then removed in a
  follow-up (ticket noted in the PR).
- Build-order ticket context link: same `href` from the ticket's identity
  (`build_order_ticket_context.ex`), only if DESIGN-E4 lists it.
- Docs (`guide/gui.md`, new "Conversations" section): how to open a full
  conversation, what jump points are, approximate positions, partial history,
  read-only behaviour, and the secrets warning. Link to the concepts page from
  C8-T02.

## Implementation steps

1. Implement option (a) or (b) per decision 6.
2. Browser spec `tests/conversation-phone.browser.spec.mjs` + npm script.
3. Docs section.

## Non-happy paths

- Unjoinable identity → no link (no conversation exists); the drawer keeps its
  current behaviour.
- Conversation not yet created (agent never produced a record) → the link still
  works and the view shows "No messages yet".

## Compatibility and rollout

- Option (b) changes a documented URL's behaviour → `guide/gui.md` must say so.
  Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/live/conversation_link_test.exs
env -C src/browser node scripts/run-browser-tests.mjs tests/conversation-phone.browser.spec.mjs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "drawer shows Full conversation link with the row's conversation id" (a) | href `/conversations/conv_…` | attr + computation |
| "/chat route navigates to the full view" (b) | redirect to `/conversations/…` | `push_navigate` |
| "unjoinable row has no link" | no href | identity guard |
| browser "390×844: no horizontal scroll; event navigation reachable; jump works" | `scrollWidth <= clientWidth`; jump highlights | layout per DESIGN-E4 phone spec |

Manual: open the dashboard on a phone-size browser window and follow a link
from the drawer to a jump; note it in the PR.

## Completion and handoff

- [ ] Links per decision 6; `guide/gui.md` section merged in the same PR.
- Dependents: MP-N1/N6 (WebView entry points).
