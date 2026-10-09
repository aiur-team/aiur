---
title: EXP-X6-5 - Authorize daemon-filed analysis tickets by local provenance - Plan
date: 2026-10-09
area: EXP-X6
ticket: EXP-X6-5
complexity: 2
brainstorm: docs/research/experiments/x6/brainstorm.md
gate: Open question 1 for Kevin (option a). If Kevin picks option b, cancel this ticket and switch EXP-X6-4 to file with human:todo.
---

# EXP-X6-5 - Dispatch trust for daemon-filed analysis tickets

## Problem

`Aiur.GitHub.DispatchAuthorization` authorizes a ticket only when a login in
`tracker.allowed_users` / CODEOWNERS applied its `agent:*` label
(`src/lib/aiur/github/dispatch_authorization.ex:497` `prefix_label_appliers`,
result set at line 147). The daemon's token login is normally not in that list,
so an analysis ticket it files (EXP-X6-4) is never dispatched. Automatic
analysis then needs a human, which breaks the headless and consumer-repo case.

## Decided design

Add one narrow provenance rule, evaluated only when the normal rule fails:

1. The issue carries the `experiment-analysis` label and a body marker
   `<!-- aiur-experiment-analysis request=<id> nonce=<hex> -->`.
2. The issue author login equals the login of the token the daemon used to
   create it (recorded on the request at creation time, not looked up later).
3. The local analysis request `<id>` exists, is `open`, names this issue
   number, and its nonce equals the marker nonce (constant-time compare).
4. Every `agent:*` label event on the issue was applied by that same login or by
   an allowed user (no third party relabelled it).

All four hold -> `dispatch_authorization: {:experiment_analysis, request_id}`.
Anything else -> the existing decision stands. The rule never authorizes an
issue that lacks a local request, so a GitHub user who copies the marker into
their own issue gains nothing.

The rule lives in the experiments component as a pure predicate
(`Aiur.Experiments.AnalysisProvenance.authorized?/2`); dispatch authorization
calls it through a registered hook so the GitHub adapter keeps no compile-time
dependency on experiments (MP-R1 layer rule: adapters do not depend on
features).

## Implementation units

### U1. Predicate and hook

- **Files:** `src/lib/aiur/experiments/analysis_provenance.ex`,
  `src/lib/aiur/github/dispatch_authorization.ex` (call registered
  provenance hooks after the label-applier check fails),
  `src/test/aiur/experiments/analysis_provenance_test.exs`,
  `src/test/aiur/github/dispatch_authorization_test.exs`.

## Test scenarios

- Daemon-authored issue, matching open request and nonce -> authorized.
- Same issue, nonce differs by one character -> not authorized.
- Marker copied into an issue authored by another login -> not authorized.
- Request `fulfilled` or `cancelled` -> not authorized (no re-dispatch after
  the report is stored).
- A third login (not allowed) applied `agent:todo` after creation -> not
  authorized.
- Allowed-user label path still authorizes exactly as before (regression).
- Hook absent (experiments component disabled) -> behaviour identical to today.

## Docs

`website/docs-app/concepts/experiments.md` "How analysis runs": one paragraph on
why daemon-filed analysis tickets dispatch and what they can do (no PR, store
writes only). Security note in the dispatch-authorization section of
`website/docs-app/reference/configuration.md` near `tracker.allowed_users`.

## Risks

- Security review required: this widens who can start an agent turn. The
  scope is one label, one marker, local nonce. The agent still runs with the
  normal guards; its only deliverable is a store write.
