---
ticket_id: MP-R2-C2-T02
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Aiur.Events.TrustClassifier behaviour that consumes U5's single KTD9 trust snapshot
status: blocked
blocked_by: [DESIGN-R2 §1, U5 (KTD9 single CODEOWNERS trust snapshot), MP-R2-C1-T06]
prior_units: [U5, U7, U8]
prior_boundaries: [BUS #10, GHD #8, ING #9]
prior_features: []
prior_findings: [KTD9]
size_owner: EVENTS (sanitizer.ex 393 lines, under 500; re-check at start per RC-23)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T02 — `TrustClassifier` over U5's trust snapshot

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.**
- **User value:** none visible. The event-payload sanitizer stops calling
  `Aiur.GitHub.CodeOwners` by name; trust has one authority (U5) and one
  narrow port on the event side.
- **Deliverable:** behaviour `Aiur.Events.TrustClassifier` with one callback
  `trusted?/1`; `Aiur.Events.Sanitizer.stamp_author_trust/2` calls the
  configured implementation; the default implementation is a one-line
  adapter onto the trust authority U5 delivers.
- **Non-goals (binding, RC-21):** this ticket **defines no trust rules**.
  It does not decide who is trusted, how degraded CODEOWNERS behaves, team
  resolution, or caching. All of that is KTD9 and belongs to U5. No change to
  the `author_trusted?` flag name or where it is read.

## Dependencies and blockers

- **U5 first** (coordinator decision RC-21,
  `cross-feature-reviews/phase-b-reconciliation.md`). KTD9 in the prior plan
  (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`, Key
  Technical Decisions) makes `Aiur.GitHub.CodeOwners` the single trust
  authority, failing closed for unknown people while preserving explicitly
  configured trusted/daemon accounts and the repository owner, and removes
  the second local fallback in `Aiur.Codeowners`. U5's files include
  `src/lib/aiur/github/code_owners.ex` and `src/lib/aiur/codeowners.ex`. If
  this ticket landed first, its adapter would wrap the pre-KTD9 behaviour and
  U5 would have to edit it again.
- **DESIGN-R2 §1**; **MP-R2-C1-T06** (boundary baseline, to prove the
  `Aiur.GitHub.CodeOwners` edge is gone from `sanitizer.ex`).
- **Concurrent with:** every other C2 ticket (no shared file).
- **Note on ownership:** `sanitizer.ex` is a payload utility used by
  producers, not by the bus core (decisions: no call from Publisher,
  Exchange or SubscriptionStore). Its manifest home is decided in
  MP-R2-C2-T11 / CONTRACT-REQUESTS; this ticket only removes the hard edge.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Sanitizer documents the trust flag from `CodeOwners.allowed?/1` | `src/lib/aiur/events/sanitizer.ex:28-31` |
| Hard edge: `alias Aiur.GitHub.CodeOwners`; `author_trusted?/1` calls it only when the process is registered, else `false`; exits → `false` | `sanitizer.ex:3,198-210` |
| `stamp_author_trust/2` puts `:author_trusted?` (author from payload `:author` or opt `:actor`) | `sanitizer.ex:191-196`; used by `github_payload` pipeline `:141` |
| Authority today: `Aiur.GitHub.CodeOwners.allowed?/2`, nil → false, case-insensitive GenServer call | `src/lib/aiur/github/code_owners.ex:73-80` |
| Readers of the flag (unchanged) | `agent_runner/events_digest.ex:54,72-73`; `events/pr_command_scanner.ex:20-21,122-123`; `build_order/ticket_history_normalizer.ex:246` |
| Second fallback U5 removes | `src/lib/aiur/codeowners.ex:277` comment refers to `Sanitizer.author_trusted?/1` |
| Tests | `src/test/aiur/events/sanitizer_test.exs` |

PROPOSED new files: `src/lib/aiur/events/trust_classifier.ex`,
`src/lib/aiur/github/event_trust.ex` (default adapter in the GitHub
component), `src/test/aiur/events/trust_classifier_test.exs`.

## Chosen design

```elixir
defmodule Aiur.Events.TrustClassifier do
  @callback trusted?(author :: String.t()) :: boolean()
end
```

- `Sanitizer.author_trusted?/1` keeps its guard clauses (`nil` → false,
  non-binary → false) and its fail-closed `catch :exit, _ -> false`. For a
  binary author it calls `classifier().trusted?(author)` where
  `classifier/0` reads `Application.get_env(:aiur, Aiur.Events.TrustClassifier,
  Aiur.GitHub.EventTrust)` (default set in `src/config/config.exs` so no
  `Aiur.GitHub.*` atom appears in `sanitizer.ex`).
- `Aiur.GitHub.EventTrust.trusted?/1` delegates to **the read function U5
  ships for its single trust snapshot**. If U5 keeps the public name
  `Aiur.GitHub.CodeOwners.allowed?/1` (KTD9 names `Aiur.GitHub.CodeOwners`
  as the single authority), the adapter is
  `if Process.whereis(CodeOwners), do: CodeOwners.allowed?(author), else: false`
  — the exact `Process.whereis` guard moves from `sanitizer.ex:201` into the
  adapter, so behaviour is identical. If U5 renames the read, the adapter
  calls the new name; nothing else changes.
- **Invariant:** for every `(author, CodeOwners state)` pair the stamped
  flag is identical before and after.

## Implementation steps

1. Rebase on main with U5 merged; re-read `sanitizer.ex` and U5's public
   trust read.
2. Add the behaviour and the `Aiur.GitHub.EventTrust` adapter.
3. Add the app-env default in `src/config/config.exs`.
4. Edit `sanitizer.ex`: drop `alias Aiur.GitHub.CodeOwners`; replace
   `:200-205` with the classifier call; update the moduledoc item 5 to name
   the port and U5's authority. Line count must not grow.
5. `sanitizer.ex` is not an event-bus member in the C1-T06 scan, so there
   is no ratchet row; instead add test 5's direct source assertion.

## Non-happy paths

- **CodeOwners not running** (test harness, early boot): adapter returns
  `false` — same as today.
- **Authority call exits** (timeout): `Sanitizer` still catches `:exit` →
  `false` (fail closed, KTD9).
- **Misconfigured module:** `UndefinedFunctionError` is an error, not an
  exit. Add `rescue _ -> false` next to the existing `catch` so a broken
  config fails closed; this cannot change behaviour today because the
  default module exists. Covered by test 3.
- **Privacy/security:** trust gates agent-digest inclusion and command
  authority (`pr_command_scanner.ex:122-123`). The port must never default
  to `true`; test 3 asserts that.

## Compatibility and rollout

- Config key `events.codeowners_refresh_seconds` is unchanged in name and
  meaning (`config.ex:570-572`, `configuration.md:616`); its owner is the
  GitHub component per MP-R1 component map, recorded in C2-T11. No
  migration. Rollback: revert.

## Verification

New tests (`trust_classifier_test.exs`):

1. `"stamp_author_trust uses the configured classifier"` — put
   `FakeTrust` (trusts `"alice"` only) in app env; assert
   `Sanitizer.stamp_author_trust(%{author: "alice"}).author_trusted? == true`
   and `"bob"` → false. **Fails without step 4** (today's code asks the
   real CodeOwners, which is not running in the test → `false` for alice).
2. `"default adapter is fail-closed when the authority is not running"` —
   no `Aiur.GitHub.CodeOwners` registered: `EventTrust.trusted?("alice") == false`.
3. `"a broken classifier fails closed"` — app env points to a module without
   `trusted?/1`; flag is `false`, no raise. **Fails without the `rescue`
   added in step 4** (raises `UndefinedFunctionError`).
4. Existing `sanitizer_test.exs`, `pr_command_scanner_test.exs`,
   `github_firehose_test.exs`, `agent_runner/events_digest` tests and U5's
   trust tests pass unchanged.
5. `"sanitizer has no CodeOwners reference"` — a source-scan assertion in
   `trust_classifier_test.exs` that `src/lib/aiur/events/sanitizer.ex`
   (docs and comments stripped, same helper as C1-T06) does not mention
   `Aiur.GitHub.CodeOwners`/`CodeOwners`. Fails if step 4 is reverted.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/trust_classifier_test.exs test/aiur/events/sanitizer_test.exs \
  test/aiur/events/pr_command_scanner_test.exs test/aiur/events/github_firehose_test.exs \
  test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check: revert only the `sanitizer.ex` hunk in a clean worktree
(`git status --porcelain` shows one file); tests 1 and 3 fail; restore; pass.

## Completion and handoff

- [ ] U5 merged first; adapter calls U5's authority; no trust rule defined here.
- [ ] No `Aiur.GitHub.CodeOwners` reference left in `sanitizer.ex`.
- [ ] Tests 1–3 added and mutation-checked.
- [ ] Docs: none (internal seam). If U5 changed `website/docs-app/apis/github.md`,
      do not restate it (AGENTS.md: link, don't copy).
- Dependents: MP-R2-C2-T11 (manifest), MP-R1-C7-T5 (GitHub component owns
  `Aiur.GitHub.EventTrust`).
