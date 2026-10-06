---
ticket_id: MP-E2-C1-T04
feature_id: MP-E2
chunk_id: MP-E2-C1
bucket: 2-platform
title: Expose v2 Command fields in the read API and aiur commands --json
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T01]
prior_units: [U6]
prior_boundaries: [DEC #27, CLI #31, WEB #34]
prior_features: [MP-N3, MP-N6 (readers of the API)]
prior_findings: [contract §8 replay, §9]
size_owner: "DECISIONS (decision_api/public_projection.ex 114) + WEB (decision_presenter.ex 168); both stay small"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C1-T04 — Expose v2 Command fields in the read API and `aiur commands --json`

## Identity and outcome

- Bucket 2, MP-E2, chunk C1.
- **User value:** remote clients (N3 counts, N6 answer flow) and the Executor can read who
  asked, how, and the short label without new endpoints.
- **Deliverable:** `requester`, `origin`, `native` (minus `native_ref`), `questions`,
  `short_label` in the JSON of `GET /api/v1/decisions[/:id]` and `aiur commands --json`;
  the routing fields (C2-T02) are appended by C2-T02 through the same serializer.
- **Non-goals:** human-readable CLI columns (C7-T04); dashboard rendering (C7).

## Dependencies and blockers

- Blocked by **DESIGN-E2**; predecessor C1-T01.
- May run concurrently with C1-T02, C1-T03.

## Verified starting point (`45a290e3`)

There are three serializers; each must carry the fields.

- `src/lib/aiur/decision_projection.ex:844-883` `to_json_safe/1` — the persisted shape
  (`decisions.json` via `serialize_current/1` `:910`). **Not changed** (keeps v1 bytes).
- `src/lib/aiur/decision_api/public_projection.ex:8-114` `encode/1` — the supervisor API
  shape for `GET /api/v1/decisions[/:id]` (`decision_api.ex:36-58`, `router.ex:91-95`).
- `src/lib/aiur_web/operator_control_center/decision_presenter.ex:22-95` `present/1` /
  `row/1` — the "safe dashboard row contract", used by the dashboard and by
  `aiur commands` (`commands_cli.ex:24-57` → `DecisionProvider.list/detail`,
  `decision_provider.ex:21-56`). 168 lines.
- Tests: `src/test/aiur/decision_api_test.exs`,
  `src/test/aiur_web/controllers/decision_api_controller_test.exs`,
  `src/test/aiur/commands_cli_test.exs`.

## Chosen design

- One source of truth: PROPOSED `Aiur.Commands.Projection.public_v2/1` returns
  `%{requester, origin, native, questions, short_label}` with string-safe values and an
  allowlist: `native` exposes only `harness`, `hold`, `question_ids` (never `native_ref`,
  `call_id`, `turn_id` — internal correlation).
- `PublicProjection.encode/1` merges it with string keys and adds `"payload_version" => 2`
  when any v2 field is non-default.
- `DecisionPresenter.row/1` merges it with atom keys (the CLI JSON is `JSONSafe.normalize`d
  from these rows, `commands_cli.ex:55`).
- `short_label` is always present in both outputs; for v1 Commands it is derived at render
  time by `RequestContent.short_label/2` (C1-T02). If C1-T02 has not landed, use
  `context.short_summary` only.
- `decision_projection.ex` `to_json_safe/1` is untouched, so `decisions.json` and the
  rollback story are unaffected.

## Implementation steps

1. `commands/projection.ex`: `public_v2/1`.
2. `decision_api/public_projection.ex`: merge (≈5 lines).
3. `aiur_web/operator_control_center/decision_presenter.ex` `row/1`: merge (≈3 lines).
4. Tests below.

## Non-happy paths

- `native_ref` leak: excluded by allowlist; test asserts absence in both outputs.
- Large `questions` payloads: bounded by C1-T02 (≤ 4 questions × 4 options).
- Partial data (no `request_attributed`): defaults rendered, `payload_version` absent.
- Presenter rescue (`present/1` returns `[]` on any exception, `decision_presenter.ex:22-28`):
  a bug in `public_v2/1` would silently drop rows — the test below asserts the row count.

## Compatibility and rollout

- Additive JSON fields; `decisions.json` unchanged. No config. Clients ignore unknown
  fields (events-and-replay §9).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/decision_projection_test.exs test/aiur/decision_api_test.exs \
  test/aiur_web/controllers/decision_api_controller_test.exs test/aiur/commands_cli_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `decision_api_test` "public projection of a v1 Command has no payload_version" | key absent; other keys unchanged from base fixture | merge guard in step 2 |
| `decision_api_test` "public projection carries requester/origin/questions/short_label" | values equal the `request_attributed` data | step 2 |
| `decision_api_test` + presenter test "native_ref is never serialized" | the ref string appears nowhere in `Jason.encode!` of either output | allowlist in step 1 |
| `decision_api_controller_test` "GET /api/v1/decisions/:id includes short_label for a v1 Command" | label = `context.short_summary` (≤ 40 chars) | step 2 |
| `commands_cli_test` "--json row includes requester kind executor and row count is unchanged" | `"executor"`; rows == decisions | step 3 |

Mutation check per row.

## Completion and handoff

- [ ] Fields served; `native_ref` never served; v1 bytes unchanged.
- Docs: `website/docs-app/reference/cli.md` (`aiur commands --json` fields) — short entry.
- Dependents: C2-T02 (appends routing keys), C7-T04, MP-N3, MP-N6.
