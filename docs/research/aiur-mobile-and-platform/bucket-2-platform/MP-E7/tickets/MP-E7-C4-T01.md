---
ticket_id: MP-E7-C4-T01
feature_id: MP-E7
chunk_id: MP-E7-C4
bucket: 2-platform
title: "Precondition (cross-repo): stop aiur-claude turn/steer from dropping text"
status: blocked
blocked_by: [DESIGN-E7, DESIGN-R7]
repo: claude-app-server (cross-repo; npm package aiur-claude)
wave: 4
prior_units: [U4]
prior_boundaries: [CLD (22), CA (20)]
prior_features: [MP-R7]
prior_findings: [MP-R7 plan F7, phase-b-reconciliation "Live bugs found during Phase B" (aiur-claude turn/steer)]
size_owner: n/a (sibling repository)
base_sha: 45a290e3
sibling_sha: b1ea979c3655b0dbec13d30de6a402da26007ebd
researched: 2026-10-06
---

# MP-E7-C4-T01 — Precondition: fix the `aiur-claude` `turn/steer` text drop

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 listener modes · C4 native steer primitives.
- **Repository:** `its-everdred/claude-app-server` (npm `aiur-claude`), **not** aiur.
  This is the cross-repo precondition named by the Phase B reconciliation
  ("Recorded as MP-R7 research and as a precondition of E7-C4").
- **User value:** a `turn/steer` call on the sibling no longer loses the
  operator's text. aiur does not call `turn/steer` today, so there is no live
  harm, but no MP-E7 ticket may route a message through that method while it
  silently discards it.
- **Deliverable:** one sibling PR that makes `turn/steer` carry its text into
  the next turn of the same thread (its documented behaviour), with tests; a
  minor version bump and npm publish.
- **Non-goals:** making headless Claude steer *inside* a running turn. That is
  not possible with the transport the sibling uses (see "Verified starting
  point", RQ-E7-4). aiur keeps headless Claude `steer` as `unsupported`
  natively (contract §9); the only steer offered there is `emulated_interrupt`
  if the owner accepts it (DESIGN-E7 decision E7-D2). No aiur code changes in
  this ticket.

## Dependencies and blockers

- **DESIGN-E7** (feature gate) and **DESIGN-R7 §2 decision 2** ("file now" or
  "leave for E7"). If DESIGN-R7 records "file now", MP-R7-C5-T02 files the
  defect as a sibling issue and this ticket links it. If it records "leave for
  E7", this ticket files the issue first, then fixes it.
- No aiur predecessor. Owner write access to the sibling repository and npm
  publish rights are required (Kevin).
- **May run concurrently with** every other MP-E7 ticket; nothing in aiur
  waits on it except a future headless-Claude use of `turn/steer` (none is
  planned in this pack).

## Verified starting point

Sibling checkout `/home/everdred/github/everdred/claude-app-server` at
`b1ea979c` (2026-09-18), `package.json` name `aiur-claude`, version `1.1.0`.
**npm registry shows only `1.0.0` published** (`npm view aiur-claude time`,
2026-10-06: `1.0.0` on 2026-06-16). aiur's install hint names no version
(`src/lib/aiur/coding_agent/providers/claude.ex:21` at `45a290e3`:
`"install it with: npm install -g aiur-claude"`). MP-R7-C5 pins the minimum
version aiur supports; this ticket must not raise it.

Defect, re-verified from source:

- `createTurn` returns a new turn with `steer_queue: []`
  (`src/server.ts:188-199`).
- `turnStart` creates that new turn (`:464`) and then checks
  `turn.steer_queue.length > 0` on it (`:466-469`) — always empty, so the
  prepend never runs. The comment says "Prepend any queued steer content from
  the last completed turn", which is the intended behaviour.
- `turnSteer` pushes onto the **active** turn's queue (`:505`) and answers
  `{ turn_id, note: "queued: will be prepended to the next user message" }`
  (`:506`). Nothing reads the old turn's queue, so the text is dropped.
- README documents `turn/steer` as `{ threadId, content }` → `{ turn_id }`
  (`README.md:126`).
- Each turn spawns `claude --print --output-format stream-json --verbose
  --include-partial-messages ...` (`src/server.ts:695-701`) and writes the user
  content to stdin, then closes stdin (`:606-611`). A running `--print` turn
  therefore has no input channel.

**RQ-E7-4 (can a `--print` turn accept mid-turn input?) — answered: no
documented mid-turn injection.** Claude Code CLI reference
(https://code.claude.com/docs/en/cli-reference, accessed 2026-10-06, page
covers Claude Code up to v2.1.29x; local `claude --version` = 2.1.291) lists
`--input-format` "Specify input format for print mode (options: text,
stream-json)" and, under `--max-turns`, "With `--input-format stream-json`, a
message still queued when the limit ends a turn stays queued and starts a new
turn". The Agent SDK streaming-input page
(https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode, accessed
2026-10-06) describes "Queued messages: send multiple messages that process
sequentially, with ability to interrupt". Both describe **sequential** turns,
i.e. `sync` semantics, not `steer`. The interactive REPL is different: it
folds queued text in after tool calls within the same turn (see MP-E7-C4-T04).
Conclusion: headless Claude has no non-cancelling mid-turn input; fixing the
sibling gives correct *next-turn* semantics only.

Existing sibling tests: `test/server.test.mjs`, `test/protocol.test.mjs`,
`test/dynamic-tools.test.mjs`, `test/provider-refusal.test.mjs`,
`test/rate-limit-cost.test.mjs`; none covers `turn/steer` (`grep steer test/`
returns nothing). Test command: `npm test` (= `npm run build && node --test
test/*.test.mjs`, `package.json:37`).

## Chosen design

Keep the method and make it honest (option A). Rejected option B, "remove
`turn/steer`": it would change the advertised capability list
(`src/server.ts:312`, `turns: ["start", "steer", "interrupt"]`) for no gain,
since any client can already get next-turn delivery from `turn/start` after
`turn/completed`.

- Add a **thread-level** `pending_steer: string[]` to `Thread`
  (`src/types.ts`, PROPOSED field).
- `turnSteer`: when a turn is active, push `p.content` onto
  `thread.pending_steer` (not the turn). Validate `content` is a non-empty
  string, else `InvalidParams`. Response unchanged:
  `{ turn_id, note: "queued: will be prepended to the next user message" }`.
  Also accept the Codex-shaped `input: [{type:"text", text}]` the same way
  `turnStart` does (`:451-458`), so a client that speaks Codex's
  `turn/steer` shape does not get `InvalidParams`.
- `turnStart`: after `createTurn`, if `thread.pending_steer.length > 0`,
  prepend `pending_steer.join("\n\n") + "\n\n"` to `turn.user_content` and
  clear `thread.pending_steer`. Remove the dead per-turn `steer_queue` field.
- No active turn → unchanged `NoActiveTurn` error (`:509`).
- **Invariant:** steered text is delivered exactly once, in the next
  `turn/start` on the same thread, in arrival order, before that turn's own
  content.
- **Interrupt:** text queued before a `turn/interrupt` stays queued and goes
  into the next turn (it was accepted; dropping it would repeat the defect).

## Implementation steps

1. Sibling: file the issue (unless MP-R7-C5-T02 already did) citing
   `src/server.ts:188-199,466-469,505`.
2. `src/types.ts`: add `pending_steer: string[]` to `Thread`; drop
   `steer_queue` from `Turn`. `createThread` initialises `pending_steer: []`.
3. `src/server.ts`: rewrite `turnSteer` and the prepend block in `turnStart`
   as above.
4. `README.md:126`: document "queued for the next turn on this thread; not
   injected into the running turn" and the accepted `input` shape.
5. Tests in `test/server.test.mjs` (below).
6. Bump to the next minor (`1.2.0`, or `1.1.x` if 1.1.0 is never published),
   publish to npm. Record the published version in MP-R7-C5's minimum-version
   fixture.

## Non-happy paths

- **No active turn:** `NoActiveTurn` as today; aiur never sends steer to an
  idle headless thread (contract §3 rule 1: idle steer starts a turn).
- **Thread lost on restart:** the thread map is in-memory only (comment at
  `providers/claude.ex:34-40` in aiur). Queued steer text dies with the
  process; this is acceptable only because aiur does not use the method. Add
  a README note.
- **Turn fails** (`turn/failed`): pending steer stays on the thread for the
  next turn.
- **Privacy:** steer text is logged by the existing `this.log("stdin: …")`
  (`:608`) only when it becomes stdin, same as any prompt. No new logging.

## Compatibility and rollout

Additive behaviour fix in the sibling. Response shape unchanged. aiur at
`45a290e3` never sends `turn/steer`, so no aiur release is coupled to it.
Rollback: republish the previous version.

## Verification

Sibling tests (new, `test/server.test.mjs`), run with `npm test` in the
sibling checkout:

- `turn/steer during an active turn is prepended to the next turn/start` —
  start a thread, set `active_turn_id` via a `turn/start` with a fake claude
  path (pattern of the existing `initializedServer` helper), call
  `turn/steer` with `content: "A"`, complete the turn, call `turn/start`
  with `content: "B"`; assert the new turn's `user_content === "A\n\nB"`.
  **Mutation check:** restore the old per-turn `steer_queue` read at
  `turnStart` and the test must fail (the content is `"B"`).
- `turn/steer accepts Codex-shaped input arrays` — `input:[{type:"text",
  text:"A"}]` behaves like `content:"A"`. Fails if only `content` is read.
- `steered text is delivered once` — a second `turn/start` after the first
  has no prefix.
- `turn/steer with no active turn returns NoActiveTurn` — guard test (passes
  on `b1ea979c`, named as a regression guard).

Manual: none required in aiur (unused path). Sibling smoke: `node
test-client.mjs` against a real `claude` with a long turn, steer, then a
second turn; the second prompt shows the steered text.

## Completion and handoff

- [ ] Sibling issue filed and linked.
- [ ] PR merged in `claude-app-server`; tests above green.
- [ ] npm version published; version recorded for MP-R7-C5.
- [ ] contracts/listener-mode.md §9 row `claude` keeps `steer: unsupported
  natively` and cites the fixed version (parent edits the contract).
- Docs: aiur docs unchanged (no aiur surface). Sibling README updated.
- Dependents: none in this pack; a future headless-Claude use of
  `turn/steer` must cite this ticket.
