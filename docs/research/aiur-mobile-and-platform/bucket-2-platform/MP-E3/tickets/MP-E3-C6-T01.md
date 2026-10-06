---
ticket_id: MP-E3-C6-T01
feature_id: MP-E3
chunk_id: MP-E3-C6
bucket: 2-platform
title: "Executor view: /executor route, entry point, not-attached, read-only and conversation states"
status: blocked
blocked_by: [DESIGN-E3, DESIGN-E4, MP-E4-C5-T01, MP-E4-C5-T02, MP-E3-C2-T01]
prior_units: [U8]
prior_boundaries: [WEB, EXE]
prior_features: [MP-E4 (ConversationLive and components)]
prior_findings: [DESIGN-E3 §2 surfaces, §4 states; plan acceptance 10]
size_owner: "U8 WEB owner (new LiveView; dashboard_live.ex 2,903 lines must not grow beyond a nav link)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C6-T01 — Executor view shell

## Identity and outcome

- Bucket 2 · MP-E3 · C6 · T01.
- **User value:** the Executor's conversation in the dashboard, reachable from
  where DESIGN-E3 puts the entry point, visually distinct from workers.
- **Deliverable:** `AiurWeb.ExecutorLive` at `/executor` (and
  `/executor?pos=N` for jump points), wrapping MP-E4's conversation components in
  Executor mode for `Conversation.Ref.executor()`; the DESIGN-E3 entry point; the
  "not opted in", "attached, waiting for first hook", "loading history",
  "transcript unreadable", "ended/detached" and "read-only" states.
- **Non-goals:** status header (T02), blockers/background panels (T03),
  composer logic (C5-T01, rendered here).

## Dependencies and blockers

- DESIGN-E3 (layout, entry point, copy for every §4 state), DESIGN-E4 (shared
  rendering). MP-E4-C5-T01/T02, MP-E3-C2-T01.

## Verified starting point

- Live routes: `live_session :dashboard` (`src/lib/aiur_web/router.ex:139-148`).
- MP-E4's `ConversationLive` (`/conversations/:conversation_id`) and
  `AiurWeb.Conversation.Components` (PROPOSED in MP-E4-C5-T01/T02).
- Executor conversation id is fixed per instance (`Ref.executor()`, contract §3).

## Chosen design

- `ExecutorLive` mounts `Ref.executor()`, reuses `ConversationLive`'s mount,
  paging and live tail through a shared module function (extract
  `AiurWeb.Conversation.Session` helpers in MP-E4-C5-T01 if needed, so both
  LiveViews call one implementation).
- State derivation adds Executor-specific states in front of MP-E4's:

| Condition | State | Content |
| --- | --- | --- |
| no binding and journal empty | `:not_opted_in` | explanation + `aiur executor-attach --harness claude|codex` + docs link; never looks idle |
| binding `awaiting_first_hook` | `:awaiting_hook` | "Waiting for the Executor session" + `--check` hint |
| binding `detached`, journal has entries | `:ended` + history | final state, history readable |
| capability `:unsupported` (C3-T03) | banner over history | reason |
| `source_unreadable` gap at head | banner | reason, status may still work |
| otherwise | MP-E4 states | — |

- Visual distinction per DESIGN-E3 (header colour, label "Executor").
- Entry point per DESIGN-E3 (nav item or header chip) — the only change to
  `dashboard_live.ex` or the shell component is that link.

## Implementation steps

1. Route + LiveView + presenter clauses above.
2. Entry point component change.
3. Browser spec `tests/executor-view.browser.spec.mjs` + npm script.

## Non-happy paths

- Executor conversation exists but binding was removed by hand → history with
  `:ended`.
- Multiple Executors on the roster (claims allow observers) → still one
  conversation (one binding, plan §4.3); roster shown in T02.
- Not authenticated → standard dashboard auth.

## Compatibility and rollout

- New route + one link. Rollback: remove both.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/live/executor_live_test.exs
npm --prefix src/browser run fixture:preflight
env -C src/browser node scripts/run-browser-tests.mjs tests/executor-view.browser.spec.mjs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "no binding → not_opted_in copy, not idle" | copy present; no "idle" | state clause (mutation: map to `:idle` fails) |
| "awaiting first hook state" | copy + `--check` hint | clause |
| "detached shows history and ended" | entries + ended | clause |
| "read-only shows history and no composer" (plan acceptance 10) | no form | writable gate |
| "?pos=N highlights" (reuse) | highlight | shared handler |
| browser "390 px: no horizontal scroll; not-attached state readable" | pass | layout |

## Completion and handoff

- [ ] Every DESIGN-E3 §4 state reachable in a test.
- Dependents: MP-E3-C6-T02, MP-E3-C6-T03.
- Docs: `website/docs-app/guide/gui.md` gains "Executor" under "The pages"
  (same PR).
