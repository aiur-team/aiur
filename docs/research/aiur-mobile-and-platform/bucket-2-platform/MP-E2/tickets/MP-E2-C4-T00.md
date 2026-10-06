---
ticket_id: MP-E2-C4-T00
feature_id: MP-E2
chunk_id: MP-E2-C4
bucket: 2-platform
title: "Spike R-Q1: Codex request_user_input through aiur's app-server frames"
status: ready
blocked_by: []
prior_units: [U4]
prior_boundaries: [CDX #21]
prior_features: [MP-R7 (harness-adapter §6)]
prior_findings: [R-Q1, plan §1.4 Codex, harness-adapter §6 item 2 RQ (Codex timeout)]
size_owner: n/a (no repository change)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C4-T00 — Spike R-Q1: Codex `request_user_input` through aiur's frames

## Identity and outcome

- Bucket 2, MP-E2, chunk C4. **Research spike — free, local, no production change.**
  Status `ready`; it has **not** been executed.
- **Question (R-Q1):** with `codex-cli 0.160.0` and the feature
  `default_mode_request_user_input` on, does a thread started with aiur's exact
  `initialize` / `thread/start` / `turn/start` frames offer `request_user_input` to the
  model, what exact `item/tool/requestUserInput` request arrives, what response shape
  completes it, and does the app-server wait with **no client timeout**?
- **Deliverable:** a findings note (`MP-E2-C4-T00-findings.md` next to this ticket),
  three fixtures for C4-T01/T02 tests, and a PASS/FAIL per question.
- **Non-goals:** any aiur code change; enabling the flag anywhere permanent (no
  `codex features enable`, which writes `~/.codex/config.toml`).

## Dependencies and blockers

- None. Needs a logged-in Codex CLI (uses a few model turns of the operator's plan; no
  extra paid service). May run at any time, in parallel with C5-T00.
- Its result gates C4-T01..T05 and the DESIGN-E2 owner decision "enable an
  `UnderDevelopment` Codex flag in production" (reconciliation owner items).

## Verified starting point

- Local `codex-cli 0.160.0`; `codex features list` reports
  `default_mode_request_user_input  under development  false` and
  `collaboration_modes  removed  true` (read 2026-10-06).
- `codex app-server --enable <FEATURE>` exists ("Equivalent to `-c features.<name>=true`",
  `codex app-server --help`, 0.160.0); `codex app-server generate-json-schema --out <DIR>`
  exists.
- Upstream (openai/codex `main` @ `551bd409`, read 2026-10-06, plan §1.4):
  `codex-rs/protocol/src/request_user_input.rs` (args `questions[{id, header, question,
  isOther, isSecret, options[{label, description}]}]`, `isBlocking`; response
  `{answers: {<id>: {answers: [String]}}}`);
  `codex-rs/core/src/tools/handlers/request_user_input_spec.rs` (1–3 questions, 2–3
  options); `codex-rs/tools/src/tool_config.rs:17-26` (Plan mode or the feature);
  `codex-rs/features/src/lib.rs` (stage UnderDevelopment, default false).
- aiur frames to copy exactly: `initialize` (`src/lib/aiur/app_server/messages.ex:81-95`,
  `capabilities.experimentalApi: true`), `thread/start` (`codex/frames.ex:43-54`:
  `approvalPolicy`, `sandbox`, `cwd`, `dynamicTools`), `turn/start` (`:72-91`). aiur's
  default `approvalPolicy` is `"untrusted"` and thread sandbox `"workspace-write"`
  (`codex/config.ex:17-18`).
- aiur handler today: `codex/approvals.ex:148-169,241-281` (would auto-answer).

## Chosen design

Drive `codex app-server` directly with a stdlib Python client that sends aiur's exact
frames, rather than through `aiurdev --test`: it isolates the Codex behaviour from aiur's
current auto-answer (`codex/approvals.ex:241-281`), costs nothing beyond a few turns, and
touches no pinned GitHub sandbox ticket. The flag is passed only on the command line
(`--enable`), never written to `~/.codex/config.toml`. The schema dump (step 1) settles the
wire shape without a model call; the live run settles offering and hold behaviour.

## Implementation steps (exact spike steps)

Use a scratch dir outside any repo and outside `/tmp` (memory: `/tmp` quota):

```bash
SPK="$HOME/.aiur/tmp/e2-c4t00-$(date +%Y%m%d%H%M)"; mkdir -p "$SPK/ws" "$SPK/fixtures"
git -C "$SPK/ws" init -q && echo hello > "$SPK/ws/README.md" && git -C "$SPK/ws" add . && git -C "$SPK/ws" commit -qm init
```

1. **Schema (no model call).**
   `codex app-server generate-json-schema --out "$SPK/schema"` then
   `grep -rl -i "requestUserInput\|request_user_input" "$SPK/schema"` and copy the request
   and response schema files into `$SPK/fixtures/`. Record field names exactly.
2. **Driver.** Write `$SPK/driver.py` (stdlib only; run with `python3 -I`): spawn
   `codex app-server --enable default_mode_request_user_input` with `cwd=$SPK/ws`; send,
   one JSON per line, the three aiur frames (copy shapes from the files above; use
   `dynamicTools: []`, `approvalPolicy: "untrusted"`, `sandbox: "workspace-write"`);
   prompt: *"Before doing anything else, use your request_user_input tool to ask me one
   question: which colour should README.md mention, red or blue? Do not guess. After I
   answer, append that colour to README.md."* Log every received line with a monotonic
   timestamp to `$SPK/frames.ndjson`.
3. **Capture.** When a frame with `"method": "item/tool/requestUserInput"` arrives, save it
   to `$SPK/fixtures/request_user_input.json`. Also save any approval-shaped request seen
   (`item/commandExecution/requestApproval` etc.) to `$SPK/fixtures/approval.json`.
4. **Hold test.** Do **not** reply for 20 minutes. Meanwhile log any frames (expect none
   or only keep-alives). Record whether the process exits, errors, or emits a timeout.
5. **Reply.** Send `{"id": <request id>, "result": {"answers": {"<question id>":
   {"answers": ["red"]}}}}`. Expect the turn to continue, `README.md` to contain "red",
   and `turn/completed`. Save the post-reply frames to
   `$SPK/fixtures/after_reply.ndjson`.
6. **Flag-off control.** Repeat steps 2–3 **without** `--enable`. Record whether the tool
   is called (expected: no; the model asks in prose or guesses).
7. **Secret / multi-question probe.** Prompt for two questions where one is a "token"
   — record whether `isSecret` is ever set by the model and what `isOther` defaults to.
8. **Long hold (optional, 70 min).** Repeat 4 with 70 minutes to confirm the app-server has
   no own timeout beyond aiur's `agent.turn_timeout_ms` (3 600 000).
9. Write the findings note: versions, commands, frame excerpts (redact nothing secret —
   there is none), PASS/FAIL table, and the diff from the plan's assumptions.

## Pass / fail criteria

| Q | PASS when | FAIL means |
| --- | --- | --- |
| Q1 offered | step 2 produces an `item/tool/requestUserInput` request | C4 cannot ship for Codex with this flag; re-plan (Plan-mode collaboration, or `native_question: :none`) |
| Q2 shape | request params match the upstream/schema field names; reply in step 5 completes the turn using "red" | C4-T01 mapping must follow the recorded shape; update contract §10 |
| Q3 no timeout | no timeout/error frame and process alive after 20 min (and 70 min if run) | C4-T02 must release before Codex's own timeout; record its value |
| Q4 control | flag off ⇒ no tool call | if the tool is offered without the flag, the owner flag decision is moot |
| Q5 approvals unaffected | approval requests still arrive as before | D10 risk; add a classification fixture |

## Non-happy paths

- Login/quota failure: record and stop; not a FAIL of the question.
- Model ignores the instruction: retry the prompt up to 3 times; then FAIL Q1 "not offered
  or not used" with the tool list from `thread/started` if present.

## Compatibility and rollout

n/a — no repository change; the flag is passed only on the spike's command line.

## Verification

The deliverable is verified by a reviewer re-running step 5 with the saved
`fixtures/request_user_input.json` against the C4-T01 parser (once written) — the fixture
must decode without edits.

## Completion and handoff

- [ ] Findings note with PASS/FAIL table and versions; fixtures copied into
  `src/test/fixtures/codex/request_user_input/` by C4-T01 (not by the spike).
- [ ] DESIGN-E2 owner item updated with the result (coordinator).
- Dependents: C4-T01..T05, C8-T04.
