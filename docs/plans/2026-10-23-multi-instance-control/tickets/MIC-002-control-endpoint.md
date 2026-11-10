# MIC-002 — `POST /api/v1/control`: run allowlisted control calls for scoped bearer tokens, with an audit log

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** #5945 (consumes its token plug, token store and `read`/`write` scopes; adds the control route and the audit log that #5945 does not cover)
**Complexity:** 3 — new network write path with auth and audit
**Risk:** high
**Lane:** PC
**Phase hint:** 2
**Depends on:** MIC-001, #5945
**Requirements:** R4 (server side), R6, R7, R8, R9
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (KTD1, KTD5, KTD6, U2) · [pack index](../README.md)

## Outcome

A machine client with a bearer token can run any remote-capable control command on an instance over HTTPS and gets back the same text and exit code a local `aiur` run prints; every write and every refusal is recorded.

## Context and evidence

- No control verb except per-ticket pause/resume/message has an HTTP route today (`src/lib/aiur_web/routes/api.ex:9-36`); global pause, caps, park, take/release, todo, queue and every executor command are RPC-only (`src/lib/aiur/agent_control_cli.ex:13-60`).
- The only bearer plug is `AiurWeb.SupervisorAuth`, one token and one actor, on the decisions routes only (`src/lib/aiur_web/supervisor_auth.ex:18-82`, `src/lib/aiur_web/routes/decisions.ex:11-17`).
- Bearer writes on the decisions routes still pass `api_write` (Origin plus `X-Aiur-Request`, `src/lib/aiur_web/router.ex:55-58`), which a machine client can only satisfy by forging an Origin.
- No HTTP mutation records an actor (`src/lib/aiur_web/controllers/observability_api_controller.ex:60-87`).

## Scope

- Route `POST /api/v1/control` declared before the `/api/v1/:issue_identifier` catch-all (`src/lib/aiur_web/router.ex:77-102`), piped through #5945's bearer plug and `require_writable` for write scope, not `api_write`.
- Body limit: `Plug.Parsers` runs in the endpoint before the router (`src/lib/aiur_web/endpoint.ex:74`, default 8 MB), so a route-level check is too late. Give `/api/v1/control` its own body reader with `length: 65_536` in the endpoint parser (path-aware, as the GitHub webhook body reader does) that answers 413 `body_too_large` without decoding JSON.
- Controller: authenticate first (before `Code.string_to_quoted`), then decode the KTD1 request, `Aiur.ControlCall.parse(expression, remote: true, max_scope: <request max_scope>)`, compare scope with the token's scope (the #5945 plug admits read tokens on this POST; scope is enforced here, per call), `Aiur.ControlCall.run/3` with the capped timeout and actor `token:<name>`, respond with KTD1 result including `instance_id` (`Aiur.Identity.instance_id`, `src/lib/aiur/identity.ex:18-33`) and build version/commit.
- `Aiur.ControlCall.Audit.append/1` writes `<run-log-root>/log/control-audit.ndjson`, one line per write-scope call and per refused call:

  ```json
  {"at":"2026-10-23T18:04:11Z","token":"pc-executor","scope":"write","call":"Aiur.AgentControlCLI.set_max_agents/1","expression_sha256":"9f2c...","outcome":"ok","exit_code":0,"elapsed_ms":41,"remote_ip":"203.0.113.7"}
  ```

  `outcome` is one of `ok`, `error` (nonzero exit), `refused` (401/403/413/422), `timeout_unknown` (write call still running after 504).

- Refusals: every `ControlCall.parse` error maps to 422 `call_refused` with its reason (all six in KTD1) and the build; `scope_exceeds_max` and a token scope below the call's scope map to 403 `scope_denied`. `unknown_on_build` follows the single KTD2 rule (unknown atom in the call head or a keyword key).

- Docs state that a `write` token is close to full control of the instance (it can message agents, and an agent with a shell turns that into code execution) and should be kept in an environment variable outside agent workspaces; read tokens may be 0600 files.

## Non-goals

- Token issuance and scopes (#5945). Browser sign-in (#5611, #5942). Streaming `listen`. Remote stop/restart.

## Existing owner and reuse target

- Route-group macro pattern: `src/lib/aiur_web/routes/decisions.ex`.
- Error envelope `{error:{code,message}}`: `src/lib/aiur_web/controllers/observability_api_controller.ex:153-157`.
- Daemon-owned log root: the same root as `event-publications.ndjson` (AGENTS.md).

## Contract and invariants

Quote KTD1 verbatim from the plan. A write-scope call by a read token is 403 and is never run. A refused or failed call never returns partial output as success.

## Refreshable implementation notes

- New: `src/lib/aiur_web/routes/control.ex`, `src/lib/aiur_web/controllers/control_controller.ex`, `src/lib/aiur/control_call/audit.ex`.
- Edit: `src/lib/aiur_web/router.ex` (route order).
- Tests: `src/test/aiur_web/controllers/control_controller_test.exs`, using #5945's token fixture.

## Acceptance and verification

### Acceptance criteria

1. A read token runs `Aiur.AgentControlCLI.status()` and receives 200 with `output` ending in `__AIUR_CONTROL_EXIT__:0`.
2. A read token calling `Aiur.AgentControlCLI.set_max_agents(3)` gets 403 `scope_denied`; the cap does not change; one audit line with `outcome: "refused"` is written.
3. A write token runs it; the cap changes; one audit line with `outcome: "ok"` is written.
4. A revoked or missing token gets 401; no basic-auth fallback on this route.
5. A non-allowlisted, non-literal, `option_not_allowed`, or `denied_remote` (`operator_answer`) expression gets 422 with that reason and is audited.
6. `GET /api/v1/control` is 405 and `POST /api/v1/12345` still reaches the issue routes (route order).
7. A `:read` call exceeding its timeout returns 504 and its task is gone. A `:write` call exceeding its timeout returns 504, its task completes, and its audit line has `outcome: "timeout_unknown"`.
8. A write token sending `Aiur.AgentControlCLI.set_max_agents(3)` with `max_scope: "read"` gets 403 `scope_denied` and the cap does not change.
9. An unauthenticated 1 MB body gets 401 or 413, never 422, and no JSON is decoded (assert on a parser spy or on the error code).

### Test that fails without the change

Controller test: POST with a read token and `Aiur.AgentControlCLI.status()` expects 200 and the exit marker; today the path hits the API's `match :*` catch-all and returns 405 (`src/lib/aiur_web/routes/api.ex:55`).

### At-merge gate

CI green; security-lens review.

### Human/manual evidence

`curl` against a local daemon with a fresh token, recorded in the PR (MIC-010 repeats on a remote instance). Mutation check: removing the `max_scope` comparison fails criterion 8; removing the body reader fails criterion 9.

## Docs to update

- `website/docs-app/reference/cli.md` "Operational facts": one row naming the control endpoint, the audit file, and that remote output equals local output.
- `website/docs-app/apis/` is GitHub-only; no change there. The endpoint's wire contract (KTD1, all status codes) goes in one short subsection of `website/docs-app/reference/cli.md` "Remote instances" (shared with MIC-003) or, if that would pass 500 lines, in `website/docs-app/concepts/operating-aiur.md`.
- AGENTS.md "Per-issue workspaces" paragraph that lists daemon-owned logs: add `control-audit.ndjson`.

## Files it touches

`src/lib/aiur_web/router.ex`, `src/lib/aiur_web/routes/control.ex`, `src/lib/aiur_web/controllers/control_controller.ex`, `src/lib/aiur/control_call/audit.ex`, tests, the two docs above.

## Dependencies and conflicts

- depends_on: MIC-001 (imports `Aiur.ControlCall`), #5945 (imports the bearer plug).
- serializes_with: #5942 on `src/lib/aiur_web/router.ex` (merge-time only).

## First slice Kevin can try

With MIC-003 merged: `aiur --instance nuc status` from the PC.
