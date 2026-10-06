---
ticket_id: MP-E2-C5-T00
feature_id: MP-E2
chunk_id: MP-E2-C5
bucket: 2-platform
title: "Spike R-Q2: Claude AskUserQuestion capture under aiur-claude (defer vs blocking host)"
status: ready
blocked_by: []
design_gate: "n/a — research spike"  # RC-32: read-only research or local experiment
prior_units: [U4]
prior_boundaries: [CLD #22]
prior_features: [MP-R7 (MP-R7-C5 sibling protocol fixture)]
prior_findings: [R-Q2, plan §1.4 Claude, harness-adapter §6 items 3 and 5]
size_owner: n/a (no repository change)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C5-T00 — Spike R-Q2: Claude `AskUserQuestion` capture under `aiur-claude`

## Identity and outcome

- Bucket 2, MP-E2, chunk C5. **Research spike — free, local, no production change.**
  Status `ready`; **not executed**.
- **Questions (R-Q2):**
  1. In `claude -p` (stream-json, as `aiur-claude` runs it) with `bypassPermissions`, is
     `AskUserQuestion` offered when a permission host exists (`--permission-prompt-tool`),
     and not offered without one?
  2. **Variant A (defer):** does a `PreToolUse` hook matching `AskUserQuestion` that returns
     `"defer"` end the run with `stop_reason: "tool_deferred"` and a `deferred_tool_use`
     payload; does `claude -p --resume <session>` re-fire the hook; and does returning
     `permissionDecision: "allow"` + `updatedInput.answers` (keyed by question text) give
     the model the answers?
  3. **Variant B (blocking host):** does a `--permission-prompt-tool` MCP tool that blocks
     (here: sleeps, then returns allow + `updatedInput.answers`) hold the turn, and what
     timeout bounds it (MCP tool timeout; `aiur-claude`'s bridge default 120 000 ms,
     `src/dynamic-tools.ts:50`)?
  4. **D10:** under `bypassPermissions`, do Bash/Edit/Write calls ever reach the
     permission host (they must not)?
  5. Multi-tool-call turns: with two tool calls in one assistant message, is `defer`
     ignored (plan §1.4), and what does the stream show?
- **Deliverable:** `MP-E2-C5-T00-findings.md` with a PASS/FAIL table, the chosen variant,
  and fixtures (stream-json lines) for C5-T01/T02 tests.

## Dependencies and blockers

- None; uses the operator's Claude login (a few short turns). May run in parallel with
  C4-T00. Gates C5-T01..T03.

## Verified starting point

- Local: Claude Code 2.1.291; `aiur-claude` 1.1.0 = checkout
  `/home/everdred/github/everdred/claude-app-server` @ `b1ea979` (2026-09-18). Its
  `src/server.ts:694-725` builds `claude --print --output-format stream-json --verbose
  --include-partial-messages --permission-mode <mode> [--model] [--mcp-config …
  --allowedTools …] (--session-id|--resume …)`; no `--permission-prompt-tool`, no hooks;
  `:921-925` forwards `permission_denials` as `turn/permission_denied`. MCP bridge with
  server→client `item/tool/call` round-trip: `src/dynamic-tools.ts:19,104,176-199,329-342`.
  Note: `dist/` is dated 2026-07-28 while `src/` is 2026-09-18 — build from source
  (`npm run build`) before using it.
- aiur side: `Aiur.Claude.CodingAgent.handle_method/5` has no requestUserInput clause
  (`src/lib/aiur/claude/coding_agent.ex:302-399`); provider is `resumable: false`
  because `aiur-claude`'s thread map is in memory (`coding_agent/providers/claude.ex:34-40`).
- Docs (read 2026-10-06, docs reference Claude Code v2.1.2xx):
  https://code.claude.com/docs/en/hooks (PreToolUse `permissionDecision`
  `allow|deny|ask|defer`, `updatedInput`; `AskUserQuestion` answers keyed by question
  text), https://code.claude.com/docs/en/agent-sdk/user-input (AskUserQuestion needs a
  permission host in non-interactive runs; 1–4 questions, 2–4 options; unavailable in
  subagents). These are claims to confirm, not facts the spike may assume.

## Chosen design

Run `claude -p` directly (the same flags `aiur-claude` builds, `src/server.ts:694-725`) with
a throwaway MCP permission host and a throwaway hook script, so the two candidate
mechanisms (A: defer + resume; B: blocking permission host) are compared on the same
prompt before any sibling or aiur code is written. Nothing outside the scratch dir changes;
`~/.claude/settings.json` is never edited (`--settings` points at the scratch file).

## Implementation steps (exact spike steps)

```bash
SPK="$HOME/.aiur/tmp/e2-c5t00-$(date +%Y%m%d%H%M)"; mkdir -p "$SPK/ws" "$SPK/fixtures" "$SPK/bin"
git -C "$SPK/ws" init -q && echo hello > "$SPK/ws/README.md" && git -C "$SPK/ws" add . && git -C "$SPK/ws" commit -qm init
P='Use the AskUserQuestion tool to ask me one question: should README.md mention red or blue? Do not guess. Then append the answer to README.md.'
```

1. **Baseline (no host).** `env -C "$SPK/ws" claude -p "$P" --output-format stream-json
   --verbose --permission-mode bypassPermissions > "$SPK/fixtures/baseline.ndjson"`.
   Record whether any `tool_use` with `name: "AskUserQuestion"` appears (Q1 control).
2. **Permission host.** Write `$SPK/bin/host.py` — a stdio MCP server (stdlib only, run
   with `python3 -I`) exposing tool `approve` that logs its input to `$SPK/host.log`, then
   (Variant B) sleeps `HOST_SLEEP` seconds and returns
   `{"behavior":"allow","updatedInput":{…input, "answers":{"<question text>":"red"}}}`.
   `$SPK/mcp.json` points `aiurhost` at it. Run step 1 again with
   `--mcp-config "$SPK/mcp.json" --permission-prompt-tool mcp__aiurhost__approve`.
   Q1 PASS if `AskUserQuestion` now appears and the host log shows it.
3. **Variant B hold.** `HOST_SLEEP=600` (10 min). Record wall time, any timeout error in
   the stream, and whether README.md ends with "red". Repeat with `HOST_SLEEP=200` to find
   whether 120 s / MCP timeouts apply (set `MCP_TOOL_TIMEOUT` only if the docs name it;
   record the value used).
4. **Variant A defer.** `$SPK/settings.json` with a `PreToolUse` hook (matcher
   `AskUserQuestion`) running `$SPK/bin/hook.py`, which reads stdin JSON, writes it to
   `$SPK/hook-<n>.json`, and: on first call prints
   `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"defer"}}`;
   if `$SPK/answer.json` exists prints `permissionDecision: "allow"` with
   `updatedInput` = original input plus `answers` from that file. Run
   `claude -p "$P" --settings "$SPK/settings.json" --mcp-config … --permission-prompt-tool …
   --output-format stream-json --verbose --permission-mode bypassPermissions --session-id <uuid>`;
   save to `$SPK/fixtures/defer_run1.ndjson`. Expect exit with a `result` carrying
   `stop_reason`/`terminal_reason` "tool_deferred" and `deferred_tool_use`.
   Wait 15 minutes. Write `answer.json`, then
   `claude -p "" --resume <uuid> --settings … (same flags)` → `$SPK/fixtures/defer_resume.ndjson`.
   PASS if the hook fires again (hook-2.json) and README.md ends with "red".
5. **D10 check.** In both variants add to the prompt "and run `ls` with Bash first".
   PASS if the host log and hook logs show **only** `AskUserQuestion`, never `Bash`.
6. **Multi-call.** Prompt that makes the model call `Read` and `AskUserQuestion` in one
   message (e.g. "In a single step, read README.md and ask me …"); record whether defer
   is honoured or ignored and what the stream shows.
7. **Through aiur-claude (optional, after 1–6).** `npm --prefix … run build`; run its
   `test-client.mjs` against a locally patched copy (in `$SPK`, not the checkout) that adds
   the flags, to confirm the stream-json reaches the server unchanged.
8. Findings note: versions, commands, PASS/FAIL, chosen variant, fixture list.

## Pass / fail criteria and what they change

| Q | PASS | Effect |
| --- | --- | --- |
| Q1 host needed | tool absent in step 1, present in step 2 | confirms C5-T01 must add a host |
| Q2 defer | steps 4 resume works after 15 min | **Variant A chosen** (survives aiur-claude restarts only if the thread map can find the session — see C5-T03) |
| Q3 blocking | step 3 holds ≥ 10 min without error | **Variant B** is a fallback (simpler; bounded by the measured timeout; dies with the process) |
| Q4 D10 | only AskUserQuestion reaches host/hook | FAIL ⇒ host must explicitly allow every non-AskUserQuestion tool unchanged; record the shape |
| Q5 multi-call | documented behaviour observed | C5-T03 detection rule uses the observed stream shape |

If both Q2 and Q3 FAIL, C5 is re-planned as `native_question: :none` for headless
Claude (report to DESIGN-E2; Claude workers keep using `decision.requested`).

## Non-happy paths

- Login/quota error: stop; not a FAIL.
- Hook schema differs from the docs: record the actual accepted JSON (this is exactly what
  the spike is for).

## Compatibility and rollout

n/a — nothing outside `$SPK` changes; never edit `~/.claude/settings.json`.

## Verification

Reviewer re-runs step 4's resume using the saved fixtures/ids and confirms the same
result; C5-T02 tests load the saved stream lines unmodified.

## Completion and handoff

- [ ] Findings note with the chosen variant; fixtures.
- [ ] Coordinator records the result in DESIGN-E2 / RQ list.
- Dependents: C5-T01, C5-T02, C5-T03.
