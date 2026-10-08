---
ticket_id: MP-E3-C1-T02
feature_id: MP-E3
chunk_id: MP-E3-C1
bucket: 2-platform
title: "Executor hook ingest: token file, bearer plug, POST /api/v1/executor/hook, payload normalizer"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T01]
prior_units: [U4, U8]
prior_boundaries: [EXE, WEB, CLD, CDX]
prior_features: [MP-E7-C6 (reuses this token and normalizer for delivery), MP-R7 (attached-session profile)]
prior_findings: [MP-E3 plan §2.3 (hook fields), §7 (auth); listener-mode contract §8, §12; security m10 (M8 transcript_path), M6; review T-11]
size_owner: "U8 WEB owner (router.ex 361 lines; new controller and plug)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C1-T02 — Executor hook ingest endpoint

## Identity and outcome

- Bucket 2 · MP-E3 · C1 · T02.
- **User value:** once attached, the operator's own Executor session reports its
  lifecycle (session start/end, prompt, tool use, stop, subagents) to aiur over
  loopback, authenticated, without ever slowing or failing the session.
- **Deliverable:** `Aiur.Executor.HookToken` (token + curl header file),
  `AiurWeb.ExecutorHookAuth` (plug), `AiurWeb.ExecutorHookController`
  (`POST /api/v1/executor/hook?harness=claude|codex`, always 202),
  `Aiur.Executor.HookPayload.normalize/2` (Claude and Codex field sets), and
  `Aiur.Executor.SessionIngest` (async dispatch: binding update + PubSub).
- **Non-goals:** delivering messages into the session (MP-E7-C6-T01 has its own
  endpoint and reuses this token and normalizer); reading transcripts (C2).

## Dependencies and blockers

- DESIGN-E3; MP-E3-C1-T01.
- Consumed by MP-E7-C6-T01 ("must not define a second token or normalizer").
- Concurrent with: MP-E3-C1-T04 (it renders the hook command that calls this).

## Verified starting point

- The only hook sink today: `POST /api/v1/:issue_identifier/claude-hook` under
  `[:dashboard_auth, :api_write]`, outside `:require_writable`
  (`src/lib/aiur_web/router.ex:166-178`); the action dispatches and answers
  `{ok: true}` (`controllers/observability_api_controller.ex:134-141`).
- `Aiur.Claude.HookEvents.normalize/1` maps `session_id`, `cwd`, `prompt`,
  `last_assistant_message`, `tool_name`, `transcript_path`
  (`claude/hook_events.ex:83-115`) and notes Claude 2.1.177 flushes the
  transcript lazily (`:7`).
- Machine-credential precedent: `AiurWeb.SupervisorAuth` (bearer, fixed actor,
  JSON 401 bodies; `supervisor_auth.ex:1-40`); pipelines at `router.ex:9-26`.
- Body parsing happens in the endpoint before routing (`Plug.Parsers`,
  `endpoint.ex:67-72`, default length limit).
- Hook payload fields (external, read 2026-10-06; Claude Code 2.1.291,
  codex-cli 0.160.0 locally): Claude — every hook has `session_id`,
  `transcript_path`, `cwd`, `hook_event_name`, `permission_mode`; `SessionStart`
  has `source` (`startup|resume|clear|compact|fork`); subagent hooks add
  `agent_id`, `agent_type`; `SubagentStop` adds `agent_transcript_path`,
  `last_assistant_message` (https://code.claude.com/docs/en/hooks). Codex —
  `session_id`, `transcript_path` (nullable), `cwd`, `hook_event_name`, `model`,
  `permission_mode`, `turn_id`. **Pinned source (Phase D, T-11):** `openai/codex`
  `codex-rs/hooks/src/schema.rs` at `a9abdeaff1773ec6e867253ae59b19128077676f`
  (`main`, read 2026-10-06), e.g. `PreToolUseCommandInput` (lines 278-292). The same
  file defines `SubagentStartCommandInput` (549-561: adds `agent_id`, `agent_type`) and
  `SubagentStopCommandInput` (606-621: adds `agent_transcript_path`,
  `stop_hook_active`, `last_assistant_message`), so RQ-E3-6 is answered from source; the
  local-binary capture in MP-E3-C4-T02 still confirms the installed version emits them.
  The earlier `learn.chatgpt.com/docs/hooks` link is not cited.

## Chosen design

**Token.** `HookToken.ensure/0` creates, if absent, 32 random bytes
(`:crypto.strong_rand_bytes/1`, base64url) at
`StatePaths.dir()/<repo>.<instance_key>.executor.hook-token` and a curl header
file `…executor.hook-headers` containing `Authorization: Bearer <token>`, both
0600, directory 0700. `rotate/0` replaces both atomically (`JsonStore`-style temp
+ rename). `path/0`, `headers_path/0`, `read/0` are public for T04 and MP-E7-C6.
The token never appears in argv: curl reads it with `-H @<headers file>` (curl
≥ 7.55.0, https://curl.se/docs/manpage.html#-H, read 2026-10-06; local curl
8.21.0).

**Plug `ExecutorHookAuth`.** Rejects unless `conn.remote_ip` is loopback
(`{127,0,0,1}` or `{0,0,0,0,0,0,0,1}`) and
`Plug.Crypto.secure_compare(bearer, HookToken.read())`. Failures: 401
`{"error":{"code":"executor_hook_unauthorized"}}`; no token file → 401
`executor_hook_unconfigured`. Never assigns an actor beyond
`%{kind: :executor_hook}`.

**Route** (new scope placed before the issue-identifier scopes, next to the
Decision scopes at `router.ex:81-109`):

```elixir
scope "/", AiurWeb do
  pipe_through(:executor_hook_auth)
  post("/api/v1/executor/hook", ExecutorHookController, :create)
  match(:*, "/api/v1/executor/hook", ExecutorHookController, :method_not_allowed)
end
```

Not behind `:dashboard_auth`, `:api_write` or `:require_writable`: it is a
machine-to-machine sink like the RC claude-hook (`router.ex:166-171`) and must
work in read-only dashboards.

**Controller.** `create/2` → `HookPayload.normalize(params, harness)` →
`SessionIngest.dispatch(event)` (a cast) → `202 {"ok":true}`. It never waits on
disk or on the binding process. A normalizer error returns 202 as well (the hook
must never fail the harness) and is counted.

**Normalizer** output (all strings bounded; unknown keys dropped):

```elixir
%{harness: "claude" | "codex", event: "SessionStart" | "UserPromptSubmit" | "PreToolUse"
  | "PostToolUse" | "Stop" | "StopFailure" | "SubagentStart" | "SubagentStop"
  | "Notification" | "SessionEnd" | "TaskCreated" | "TaskCompleted" | String.t(),
  session_id, transcript_path, cwd, source, turn_id, agent_id, agent_type,
  agent_transcript_path, last_assistant_message (≤ 4 KiB), notification_type,
  tool_name, stop_hook_active, observed_at}
```

`harness` comes from the `?harness=` query param written by T04, never guessed
from field shapes.

**`transcript_path` validation (Phase D, security m10/M8).** A holder of the hook token
could otherwise point `transcript_path` (or `agent_transcript_path`) at another
session's JSONL file, and the daemon would serve it to phones. `HookPayload` passes each
path through PROPOSED `Aiur.Executor.TranscriptPath.validate(path, harness, session_id)`
and keeps it only when **all** hold; otherwise it sets the field to `nil` and counts
`transcript_path_rejected` with the reason:

1. the path is absolute, has no `..` segment, and lies under the harness root:
   `~/.claude/projects/` (Claude) or `~/.codex/sessions/` (Codex), with `$HOME` from
   `System.user_home!/0`, not from the payload;
2. `File.lstat/1` says `type: :regular` (a symlink is refused, so is a directory);
3. the `File.Stat` `uid` from step 2 equals the uid that owns `System.user_home!/0`;
4. the basename matches the session: Claude `<session_id>.jsonl`; Codex
   `rollout-*-<session_id>.jsonl`.

A `nil` path means "no transcript bound"; C2-T01 never tails a path that did not pass
this check, and MP-E4 maps the Executor's `executor_operator` role only from a bound,
validated path (conversations contract §5, security M6).

**SessionIngest** (GenServer): applies `Session.bind_provider_session/2`,
`rebind_on_session_start/2` (`SessionStart` with `source` ≠ `startup`),
`touch/2`, `detach/2` on `SessionEnd` (`end_reason: "stopped"`); rate-limits
per binding to 50 events/s (excess dropped, counted); then broadcasts
`{:executor_hook, event}` on PubSub topic `"executor_hook"` for C2 (transcript
retarget) and C4 (state machine).

## Implementation steps

1. `HookToken`, `HookPayload`, `SessionIngest` modules + child.
2. Plug, pipeline `:executor_hook_auth` in `router.ex`, controller.
3. Fixtures: one JSON per Claude event above (from the documented fields) and
   per Codex event; a captured real payload from each local CLI (fields only,
   values replaced) added at implementation time.

## Non-happy paths

- **Missing/wrong token or non-loopback caller** → 401, no state change, no
  binding touched (plan acceptance 8).
- **Not attached** (no binding) → 202, counted `not_attached`; nothing stored.
- **Foreign session** → 202, counted, visible in `executor-session` (T03).
- **Flood** → rate limit; the session is never slowed (202 is returned before
  any work).
- **Payload huge** → parsed by the endpoint's default limit; normalizer keeps
  bounded fields only.
- **`--no-dashboard`** → no HTTP listener, so no hook can arrive; T03 refuses
  attach with the Remote Control message shape (AGENTS.md "Running").

## Compatibility and rollout

- New route, inert without a token file. No config key. Rollback: remove the
  scope; installed hooks then get 404 and still exit 0 (T04 command ends with
  `exit 0`).

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/executor/hook_payload_test.exs test/aiur/executor/hook_token_test.exs \
  test/aiur/executor/session_ingest_test.exs test/aiur_web/executor_hook_controller_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "no token → 401 and binding unchanged" | 401; `Session.current/0` same as before | plug |
| "wrong token → 401" | 401 | `secure_compare` |
| "non-loopback remote_ip → 401" | 401 | loopback check (mutation: drop it fails) |
| "valid hook → 202 within 50 ms while SessionIngest is blocked" | 202, elapsed < 50 ms | cast dispatch |
| "token files are 0600 and the token is not in the generated command" | modes; command contains `-H @` and not the token | `ensure/0`, T04 contract |
| "Claude fixtures normalize each documented field" | table | normalizer clauses |
| "Codex fixtures normalize turn_id and nullable transcript_path" | table | normalizer clauses |
| "SessionStart clear triggers rebind" | `rebind_on_session_start/2` called | ingest branch |
| "SessionEnd detaches with stopped" | binding `detached` | ingest branch |
| "read-only dashboard still accepts hooks" | 202 with `dashboard_writable: false` | route outside `:require_writable` |
| "transcript_path outside the harness root is dropped" (m10) | normalized `transcript_path == nil`, counter `transcript_path_rejected{reason: :outside_root}` | root check |
| "symlinked transcript_path under the root is dropped" | `nil`, reason `:not_regular` (fixture: symlink in a temp `HOME/.claude/projects/x/` to another file) | `lstat` type check (using `File.stat/1` instead makes it pass and the row fail) |
| "transcript_path whose basename does not match session_id is dropped" | `nil`, reason `:session_mismatch` | basename check |
| "valid Claude and Codex transcript paths are kept" | path unchanged | — (checks must not over-match) |

## Completion and handoff

- [ ] Token/normalizer API documented in moduledocs for MP-E7-C6-T01.
- Dependents: MP-E3-C1-T03, MP-E3-C1-T04, MP-E3-C2-T01, MP-E3-C4-T01/T02, MP-E7-C6-T01.
- Docs: MP-E3-C1-T03 (CLI page) and MP-E3-C7-T02.
