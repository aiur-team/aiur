# MP-E2-C4-T00 findings — Codex `request_user_input` through Aiur's frames

Spike for ticket [MP-E2-C4-T00](MP-E2-C4-T00.md) (GitHub #4450). Run 2026-10-26 by the
Executor on the host, outside the agent sandbox. The agent runs on 2026-10-14 and
2026-10-26 could not start `codex app-server` inside the sandbox
(`Read-only file system (os error 30)`); on the host it starts at once.

## Versions and setup

- `codex-cli 0.160.0`, logged in with the existing ChatGPT subscription (no API key).
- Model from the host's Codex config: `gpt-6-luna`, reasoning effort `low`.
- Aiur frames copied from `main` (`app_server/messages.ex` `initialize_frame/0`,
  `codex/frames.ex` `thread_init_frame/3` and `turn_start_frame/6`):
  `capabilities.experimentalApi: true`, `approvalPolicy: "untrusted"`,
  `sandbox: "workspace-write"`, `dynamicTools: []`, turn `sandboxPolicy`
  `workspaceWrite`. No collaboration mode was sent.
- Driver: the stdlib Python driver from the agent's 10-14 run, with only its paths changed
  and the `sqlite_home`/`log_dir` overrides removed. It ran with `python3 -I`.
- Flag: `codex app-server --enable default_mode_request_user_input` (command line only;
  `~/.codex/config.toml` was not changed). Control runs omit `--enable`.
- Each run used its own scratch git repo with `README.md` = `hello`.

## Results

| Q | Result | Evidence |
| --- | --- | --- |
| Q1 offered | **PASS** | Flag on: the single-question prompt produced `item/tool/requestUserInput` 5.1 s after `turn/start` (1 of 1). Two-question prompt: 1 of 2 attempts (attempt 1 the model said in prose that the tool was absent and called nothing). |
| Q2 shape | **PASS** | Request params match the schema field names. Reply `{"id":0,"result":{"answers":{"colour":{"answers":["red"]}}}}` completed the turn: `serverRequest/resolved`, then the README edit, then `turn/completed` with `status: "completed"`. `README.md` ends with `red`. |
| Q3 no timeout | **PASS (20 min)** | Answer withheld 1 200.4 monotonic seconds. The app-server sent **zero frames** during the hold (no keep-alive, timeout or error); the process was alive at reply time. The thread status during the hold was `active` with `activeFlags: ["waitingOnUserInput"]`. The 70-minute hold was not run. |
| Q4 flag-off control | **PASS** | Without `--enable`, no `item/tool/requestUserInput` reached the client. The model still tried the tool: Codex logged `request_user_input is unavailable in Default mode` (stderr, `codex_core::tools::router`), and the model asked in prose. A second control run failed with HTTP 429 (rate limit) and is not counted. |
| Q5 approvals unaffected | **PASS** | After the reply, two `item/commandExecution/requestApproval` requests arrived (ids 1 and 2: `cat README.md`, then the append). `{"decision":"accept"}` resolved each. Flag on does not change the approval path. |
| Secret / multi-question | **Recorded** | The model set `isSecret: false` even for a "dummy token (secret input)" question, and `isOther: true` on every question in every capture. |

PASS on Q3 shows only that Codex survives a 20-minute wait. It does not prove that
Codex has no timeout at all.

## Wire facts for C4-T01/T02

- **Server request id namespace.** The question arrived as server request `id: 0`; the
  following approvals were `id: 1` and `id: 2`. Server-to-client ids start at 0 and are
  separate from Aiur's client ids (1–5). The response must echo the request id.
- **Request params** (captured): `threadId`, `turnId`, `itemId` (the model's `call_…`
  id), `questions[]`, `isBlocking`, `autoResolutionMs`. Each question has `id`,
  `header`, `question`, `isOther`, `isSecret`, `options[{label, description}]`.
- **`isBlocking` was `false`** and `autoResolutionMs` was `null`, yet Codex waited the
  full 20 minutes. Do not read `isBlocking: false` as "Codex will auto-resolve".
- **Options are mandatory in practice.** Codex rejects a call that has a question with no
  options (`request_user_input requires non-empty options for every question`, stderr);
  the model then retried with a placeholder option ("Enter token") plus `isOther: true`.
  Free-text answers therefore come through the `isOther` path. C4-T01 should send the
  typed text as the answer string.
- **The model may label a recommendation** in an option label (`"Red (Recommended)"`).
  Aiur sent the plain answer `"red"` and the model accepted it, so the answer does not
  have to match an option label exactly.
- **No `item/started` for the tool call.** No item frame came before the request. After
  the reply Codex sent `serverRequest/resolved {"requestId": 0}`, and the thread flag
  cleared.
- **Unstable-feature warning.** With the flag on, every thread gets a `warning`
  notification ("Under-development features enabled: default_mode_request_user_input …").
  Aiur should not surface it as an agent error.
- **Model compliance is not guaranteed.** In 1 of 3 flag-on turns the model did not call
  the tool and claimed it was missing. Plan C4 for a fallback where the model asks in
  prose.

## Difference from the plan's assumptions

- Upstream spec says 2–3 options per question. The model sent a 1-option question
  ("Enter token"), and Codex accepted it. Only the empty-options case was rejected.
- `isSecret` is never set by the model, even when asked. Aiur cannot rely on it to mask
  a secret answer.
- Aiur today would auto-answer this request in `codex/approvals.ex`. This probe went
  around Aiur, so that path was not exercised.

## Fixtures

In [`MP-E2-C4-T00-fixtures/`](MP-E2-C4-T00-fixtures/). IDs, paths and home directories
are replaced with `<uuid>`, `<workspace>`, `call_<id>`, `msg_<id>` and `<codex-home>`;
account and rate-limit notifications are removed. In `after_reply.ndjson`, the
`item/agentMessage/delta` frames of each message are collapsed into one sanitized delta,
because a path could be split across deltas. Nothing else is changed.

- `request_user_input.json` — the captured single-question request (Q1/Q2).
- `request_user_input_two_questions.json` — the two-question request (secret probe).
- `approval.json` — the first `item/commandExecution/requestApproval` after the reply.
- `after_reply.ndjson` — Aiur's reply and every frame after it, up to `turn/completed`.
  Each line is `{"direction", "frame"}`.
- `ToolRequestUserInputParams.json`, `ToolRequestUserInputResponse.json` — generated by
  `codex app-server generate-json-schema` (0.160.0). They are the same as the 10-14
  agent copies.

C4-T01 copies these into `src/test/fixtures/codex/request_user_input/`; this spike does
not.

## Not done

- The 70-minute hold (optional step 8).
- A re-run of the flag-off control after the 429.
- The DESIGN-E2 owner decision (enable an `UnderDevelopment` Codex flag in production)
  stays with the coordinator. This note is its input.
