---
ticket_id: MP-E2-C1-T02
feature_id: MP-E2
chunk_id: MP-E2-C1
bucket: 2-platform
title: Validate v2 questions, derive short_label, warn on suggested responses
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T01]
prior_units: [U6]
prior_boundaries: [DEC #27]
prior_features: []
prior_findings: [MP-E2 plan §1.1 (no 2–3 rule today), DESIGN-E2 §4.1–§4.2]
size_owner: "DECISIONS (decision_validation.ex 494 — must stay ≤ 500; new logic in commands/request_content.ex)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C1-T02 — Validate v2 questions, derive `short_label`, warn on suggested responses

## Identity and outcome

- Bucket 2, MP-E2, chunk C1.
- **User value:** every Command has a short title a phone can show, multi-question native
  Commands are well-formed, and agents are nudged toward 2–3 suggested responses without
  breaking any agent today.
- **Deliverable:** PROPOSED `Aiur.Commands.RequestContent` with
  `normalize_questions/1`, `short_label/2`, `suggested_response_check/2`; config key
  `decisions.require_suggested_responses` (default `false`); docs entry.
- **Non-goals:** rendering (C7); native mapping from harness payloads (C4-T01 calls
  `normalize_questions/1`); flipping the flag (C8-T03).

## Dependencies and blockers

- Blocked by **DESIGN-E2** (§4.1 `[decide]`: fallback when no short label; §4.2 `[decide]`
  4-option native exception). The mechanism below implements the proposals; if Kevin
  decides otherwise, only `short_label/2`'s fallback chain and the native option cap change.
- Predecessor: C1-T01 (fields + event).
- May run concurrently with C1-T03, C1-T04.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/decision_validation.ex:40-58` limits (`@options_max 20` `:50`,
  `@option_label_max 200` `:48`); `:73-160` `normalize/2`; `:262-301` `fetch_options`
  (no minimum); `:303-325` `fetch_recommendation`. File is 494 lines — it cannot absorb
  the new rules.
- `src/lib/aiur/config/schema/decisions.ex` (two keys, `embedded_schema` + `changeset`);
  `config/schema.ex:57,169`; reader `config.ex:1137-1144`.
- Alerts: `Aiur.Alerts.emit_custom/3` as used at `orchestrator/runtime_watchdog.ex:332-341`.
- `scripts/check-config-docs.py` fails `lint` when a key is missing from
  `website/docs-app/reference/configuration.md` (AGENTS.md "Docs ship with the change").

## Chosen design

- `normalize_questions(list)` → `{:ok, [q]} | {:error, {:questions, reason}}`:
  1–4 questions; each `question_id` (1–64 chars, unique), `header` (≤ 12 chars, optional),
  `question` (1–2000), `options` 2–4 of `{id (derived "q<i>-o<j>" if missing), label ≤ 200,
  description ≤ 2000}`, `multi_select` boolean (default false), `allow_other` boolean
  (default true), `secret` boolean (default false; secrets never reach the store — C4-T01
  releases them, so `secret: true` here is a validation error `:secret_not_storable`).
- Top-level fill for v1 readers (contract §3): when `questions` is non-empty and the payload
  has no `question`, the creator (C4-T01) sets `question` = first question, `options` =
  first question's options. `RequestContent` exposes `v1_projection/1` for that.
- `short_label(decision, questions)`: first non-empty of `context.short_summary`
  (trim, first 40 chars on a word boundary), first question `header`, `kind`, `"Command"`.
  Stored in `request_attributed.short_label` by the creator; for v1 Commands without the
  event, readers call `short_label/2` lazily.
- `suggested_response_check(decision, origin)`: only for `origin in [:emit_event]`:
  - `length(options) in 2..3` and (no recommendation or recommended option is first) → `:ok`
  - otherwise `{:warn, reason}` where reason ∈ `:too_few_options | :too_many_options |
    :recommended_not_first`.
  - With `decisions.require_suggested_responses: true` a `:warn` becomes
    `{:error, {:decision_invalid, {:suggested_responses, reason}}}` in `handle_request`.
  - With `false` (default): accept, emit one alert per `decision_id`
    `ticket.<id>.agent.decision.suggested-responses` (severity info, no question text,
    `needs_attention: false`) so C8-T03 can count. Native and attention origins skip it.
- Config: `field(:require_suggested_responses, :boolean, default: false)` in
  `Aiur.Config.Schema.Decisions`; `Config.decisions_require_suggested_responses?/0`.

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/request_content.ex` (≈150 lines) with the three
   functions and `v1_projection/1`.
2. `config/schema/decisions.ex`: add the field + cast; `config.ex`: accessor next to
   `:1137-1144`.
3. `decision_store.ex` `handle_request/3` (`:2161-2168`): after `DecisionValidation.normalize`,
   call `RequestContent.suggested_response_check/2` (one `with` step); emit the alert via
   an injectable `opts[:alert_fun]`.
4. Docs: `website/docs-app/reference/configuration.md` entry for
   `decisions.require_suggested_responses` (default, effect, rollout note); update
   `.aiur/examples/config.example` comment block if it lists `decisions:` keys.

## Non-happy paths

- Payload with 1 option today (valid at base): accepted with a warning (default) — no agent
  breaks. Rejected only when the operator opts in.
- Alert storm: one alert per `decision_id` (dedup by id in the alert key); re-files with the
  same id do not repeat.
- Unknown question keys: dropped. Non-list `questions`: `{:questions, :invalid_type}`.

## Compatibility and rollout

- New config key, default `false` ⇒ zero behaviour change except an info alert.
- Rollout: C8-T03 flips the default only after a census.
- Rollback: safe with the key still in `.aiur/config`. `Aiur.Config.Schema.Decisions`
  uses Ecto `cast/4` with an explicit field list (`config/schema/decisions.ex`, `changeset/2`),
  which ignores keys it does not know; only `polling` and `muse_backend` reject unknown keys
  (`config/schema/polling.ex:85`, `config/schema/muse_backend.ex:24`).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/request_content_test.exs test/aiur/decision_store_test.exs test/aiur/config/decisions_suggested_responses_test.exs
python3 scripts/check-config-docs.py
env -C src mix compile --warnings-as-errors && env -C src mix lint
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `request_content_test` "questions table" (0, 1, 4, 5 questions; 1/2/4/5 options; dup ids; header 13 chars; secret) | errors exactly as specified | `normalize_questions/1` |
| "short_label fallback chain" (summary 60 chars → 40 on word boundary; nil summary + header; neither → kind; nothing → "Command") | values as listed | `short_label/2` |
| `decision_store_test` "one-option request is accepted and alerts once" (flag false) | `{:ok, %{status: :accepted}}`; alert fun called once; second re-file not alerting | step 3 |
| "one-option request is rejected when require_suggested_responses is true" | `{:error, {:decision_invalid, {:suggested_responses, :too_few_options}}}` | step 3 flag branch |
| "recommended option not first warns" | `{:warn, :recommended_not_first}` | check logic |
| "native origin skips the rule" | no alert for `origin: :native_question` with 4 options | origin guard |

Mutation check per row (worktree, revert only the named hunk, test fails, restore).

## Completion and handoff

- [ ] Module + config key + docs entry; `check-config-docs.py` green.
- [ ] Default behaviour: accept + info alert.
- Docs: `reference/configuration.md` (this PR).
- Dependents: C4-T01 (uses `normalize_questions/1`), C7-T02, C8-T03.
