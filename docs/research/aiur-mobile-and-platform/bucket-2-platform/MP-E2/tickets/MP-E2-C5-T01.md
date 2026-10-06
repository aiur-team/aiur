---
ticket_id: MP-E2-C5-T01
feature_id: MP-E2
chunk_id: MP-E2-C5
bucket: 2-platform
title: "aiur-claude: forward AskUserQuestion as item/tool/requestUserInput (sibling repo)"
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C5-T00, MP-E2-C4-T01]
prior_units: [U4]
prior_boundaries: [CLD #22 (sibling)]
prior_features: [MP-R7-C5 (sibling protocol fixture), MP-E7-C4 (also edits aiur-claude: turn/steer defect)]
prior_findings: [R-Q2, plan §1.4, harness-adapter §6 item 3 (stable question ids)]
size_owner: "n/a — external repo its-everdred/claude-app-server (src/server.ts 42 KB; add a new module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C5-T01 — `aiur-claude`: forward `AskUserQuestion` as `item/tool/requestUserInput`

## Identity and outcome

- Bucket 2, MP-E2, chunk C5. **Work happens in the sibling repo** (npm `aiur-claude`,
  `its-everdred/claude-app-server`, local checkout `@ b1ea979`).
- **User value:** a Claude worker's native question reaches aiur in the same protocol
  shape as Codex's, so aiur core handles both with one code path.
- **Deliverable:** opt-in (`thread/start` param `nativeQuestions: true`) support that:
  1. adds the permission host and the AskUserQuestion capture per the variant C5-T00
     chose (A: `PreToolUse` defer hook + resume; B: blocking `--permission-prompt-tool`);
  2. sends a server→client request `item/tool/requestUserInput` with params
     `{threadId, turnId, itemId, questions[{id, header, question, isOther: true,
     isSecret: false, options[{label, description}], multiSelect}]}` — `id` =
     first 16 hex of sha256(question text), stable across resumes;
  3. on the client's result `{answers: {id: {answers: [..]}}}` completes the tool
     (A: resume with `allow` + `updatedInput.answers` keyed by question **text**,
     multi-select joined with ", "; B: return the same from the host);
  4. on a client result whose single answer equals the release text prefix
     ("Your question is recorded as Command"), completes the tool with that text so the
     model ends its turn (release);
  5. a new release (`1.2.0`), README section, CHANGELOG.
- **Non-goals:** aiur-side handling (C5-T02); `turn/steer` defect (MP-E7-C4).

## Dependencies and blockers

- **DESIGN-E2**; **C5-T00** decides A vs B and the exact hook/host JSON; C4-T01 defines
  the normalized shape this mirrors.
- Coordination: MP-E7-C4 also changes `aiur-claude`; release numbers must not collide
  (whoever lands second rebases and bumps).

## Verified starting point (sibling @ `b1ea979`)

- `src/server.ts:280-290` method table (`thread/start`, `turn/start`, `turn/steer`,
  `turn/interrupt`, `approval/respond`, …); `:256` handles client answers to
  server-initiated requests; `:694-725` `buildClaudeArgs` (no host, no hooks);
  `:882-927` `result` handling (session id update, `permission_denials` forward).
- `src/dynamic-tools.ts:19` request shape for `item/tool/call`; `:104` pending map;
  `:50` `DEFAULT_ENGINE_TIMEOUT_MS = 120_000`; `:329-342` call path.
- `src/types.ts:14-19` `PermissionMode`; `:145` `permission_mode` on the thread.
- Tests: `test/*.test.mjs` (`npm test` = build + `node --test`), fixtures in `test/fixtures/`.

## Chosen design

- New module PROPOSED `src/native-questions.ts` (keeps `server.ts` from growing):
  `buildArgs(thread)` additions; `onDeferred(result)` (Variant A) or host handler
  (Variant B); `toRequestUserInput(toolInput)`; `toUpdatedInput(toolInput, answers)`.
- Variant A thread state: `pendingNative: {toolUseId, questionIds, sessionId}`; the turn
  stays `inProgress` (no `turn/completed`) until answered or released; on answer the
  server spawns `claude -p "" --resume <session>` with the same flags and continues the
  same turn id stream.
- Only `AskUserQuestion` is routed (D10); any other tool reaching the host returns
  `allow` with the input unchanged (if C5-T00 Q4 shows it can happen).
- Opt-in flag so older aiur builds (which do not send it) see no behaviour change.

## Implementation steps

1. `src/native-questions.ts`; wire into `buildClaudeArgs` and `processClaudeEvent`
   (`result` branch) behind `thread.nativeQuestions`.
2. `thread/start` param parsing (`types.ts`).
3. Tests in `test/native-questions.test.mjs` using C5-T00 fixtures.
4. README "Native questions" section; version bump; publish (operator action).

## Non-happy paths

- Client never answers: the turn stays open until aiur releases (C5-T03) or interrupts.
- `turn/interrupt` while pending: complete with the release text (A: resume once with
  `deny` + message; B: return deny) then interrupt.
- `aiur-claude` restart while deferred (A): the CLI session persists on disk but the
  in-memory thread map is lost (`providers/claude.ex:34-40`); aiur sees a session error
  and falls back to message delivery to a new worker (C5-T03).
- Multi-call turn (defer ignored): detect per C5-T00 Q5 and immediately send a release.

## Compatibility and rollout

- Opt-in param; default behaviour byte-identical. Min aiur version: the one shipping
  C5-T02. aiur's install hint gains a version (C5-T02).

## Verification

```bash
npm --prefix /home/everdred/github/everdred/claude-app-server test
```

| Test (PROPOSED, sibling) | Expected | Fails without |
| --- | --- | --- |
| "nativeQuestions off: args unchanged" | argv equals current | opt-in guard |
| "AskUserQuestion deferred result emits item/tool/requestUserInput with stable ids" | ids = sha256(text)[0..16] | `toRequestUserInput` |
| "answer resumes with allow + answers keyed by question text" | resume argv has `--resume <session>`; hook input file contains the answers | resume path |
| "release text completes the tool and the turn ends" | `turn/completed` after resume | release branch |
| "Bash never reaches the host" | host handler not called for Bash fixture | D10 routing |

Mutation check per row (sibling worktree). Manual: run `test-client.mjs` against a
local build with `nativeQuestions: true` and answer by hand.

## Completion and handoff

- [ ] Sibling release published with the opt-in.
- Docs: sibling README; aiur docs in C5-T02/C8-T01.
- Dependents: C5-T02, C5-T03.
