---
ticket_id: MP-E3-C3-T01
feature_id: MP-E3
chunk_id: MP-E3-C3
bucket: 2-platform
title: "Spike (no product code): Codex TUI rollout fixtures at 0.160.x and hook transcript_path check"
status: ready
blocked_by: []
design_gate: "n/a — research spike"  # RC-32: read-only research or local experiment
prior_units: [U4]
prior_boundaries: [CDX]
prior_features: []
prior_findings: [RQ-E3-1, RQ-E3-2, RQ-E3-6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C3-T01 — Codex Executor read spike

## Identity and outcome

- Bucket 2 · MP-E3 · C3 · T01 · research spike, **no product code**.
- **User value:** decides, with evidence, how aiur reads a Codex TUI Executor's
  conversation, so C3-T02 builds one reader, not two.
- **Deliverables:** (1) sanitized rollout fixtures from a Codex **TUI** session at
  0.160.x; (2) proof that the Codex hook payload's `transcript_path` is that
  rollout file; (3) the `SubagentStart/Stop` payload field set (RQ-E3-6);
  (4) a one-paragraph decision appended to `MP-E3/plan.md` §10.
- Not behind DESIGN-E3: it changes nothing in the product. It must not touch the
  operator's real `~/.codex`.

## Dependencies and blockers

- None. Runs any time. Blocks MP-E3-C3-T02.

## Verified starting point (2026-10-06, read-only census on this machine)

- Local `codex-cli 0.160.0`.
- 200 local rollouts (`~/.codex/sessions/**/rollout-*.jsonl`, types only):
  record kinds `event_msg` (`item_completed` 168,725; `token_count`;
  `task_started`/`task_complete`; `turn_aborted`; `thread_settings_applied`),
  `response_item` (`message`, `reasoning`, `function_call(_output)`,
  `custom_tool_call(_output)`, `agent_message`), `session_meta`, `turn_context`,
  `compacted`, `world_state`, `token_usage_record`.
- `event_msg/item_completed` payload keys: `thread_id`, `turn_id`, `item`,
  `started_at_ms`, `completed_at_ms`. Item types (PascalCase, snake_case
  fields): `CommandExecution{id, command, aggregated_output, exit_code, cwd, …}`,
  `AgentMessage{id, content, phase}`, `Reasoning{id, summary_text, raw_content}`,
  `FileChange{id, changes, status}`, `UserMessage{id, client_id, content}`,
  `DynamicToolCall`, `McpToolCall`, `SubAgentActivity`, `ContextCompaction`.
- Newest 40 rollouts: `session_meta.cli_version` 0.160.0 and 0.160.1, all
  `originator: aiur-orchestrator` (app-server workers). Older sample contains
  `originator: codex-tui` at 0.157–0.158. **No codex-tui rollout at 0.160.x was
  observed** — that is the gap this spike closes.
- This shape differs from the app-server v2 notifications aiur parses today
  (`item/completed` with camelCase `agentMessage`, `commandExecution`,
  `aggregatedOutput`; `src/lib/aiur/codex/transcript.ex:88-145`), so a separate
  extractor is needed (C3-T02).

## Chosen design (experiment)

All in a private `CODEX_HOME` so the operator's real Codex state is untouched:

```bash
S="$(mktemp -d)"; export CODEX_HOME="$S/codex"; mkdir -p "$CODEX_HOME"
codex login                       # log in inside the scratch home; never copy ~/.codex files
# 1) hooks: write "$CODEX_HOME/hooks.json" with a SessionStart/Stop/SubagentStart/SubagentStop
#    hook running:  cat > "$S/hook-$(date +%s%N).json"; exit 0
# 2) run the TUI in a scratch git repo:
mkdir -p "$S/repo" && git -C "$S/repo" init -q
env -C "$S/repo" codex            # trust the hooks in the review dialog; send two prompts,
                                  # one that runs a shell command and one that edits a file;
                                  # ask it to spawn a subagent if the build supports it; /quit
# 3) evidence (keys and types only):
python3 -I - "$CODEX_HOME"/sessions/*/*/*/rollout-*.jsonl <<'PY'
import sys, json, collections
c = collections.Counter()
for p in sys.argv[1:]:
    for raw in open(p, 'rb'):
        r = json.loads(raw); pl = r.get('payload') if isinstance(r.get('payload'), dict) else {}
        it = pl.get('item') or {}
        c[(r.get('type'), pl.get('type'), it.get('type'), tuple(sorted(it.keys()))[:8])] += 1
        if r.get('type') == 'session_meta': print('meta', pl.get('cli_version'), pl.get('originator'))
for k, v in c.most_common(40): print(v, k)
PY
for f in "$S"/hook-*.json; do python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("hook_event_name"), sorted(d.keys()))' "$f"; done
```

Checks to record:
1. `session_meta.originator == "codex-tui"` and `cli_version` 0.160.x.
2. Every hook's `transcript_path` equals the rollout path (or is `null` — then
   C3-T02 must locate the file from `session_id`; record which).
3. Item types and keys match the census list; any new type listed.
4. `SubagentStart/Stop` keys (RQ-E3-6).
5. Optional RQ-E3-2: with the TUI still open, run
   `codex app-server` in another terminal (same `CODEX_HOME`) and try
   `thread/read` / `thread/turns/list` for the TUI thread id; record whether it
   returns items without side effects (new rollout lines, lock errors). If it is
   inconclusive in 30 minutes, record "not pursued"; the rollout reader is the
   default.
6. Sanitize: replace every string value except `type`, ids and enum-like fields
   with `"<redacted>"`, keep structure; save as
   `src/test/fixtures/codex_rollouts/0.160/tui-*.jsonl` in C3-T02's PR.

## Implementation steps

As above; then `rm -rf "$S"`. Write the decision paragraph: "Codex Executor
reader = rollout tail of `transcript_path`, extractor keyed on
`event_msg/item_completed` item types at 0.157–0.160.x" or the alternative if
check 2 or 3 fails.

## Non-happy paths

- Hooks not offered for trust (feature off in this build) → record it; C3-T02 is
  then blocked and Codex is reported `unsupported` (plan acceptance 2).
- `transcript_path` null → C3-T02 maps `session_id` to the rollout file by name
  (`rollout-*-<session_id>.jsonl` pattern seen in the census) and records that
  rule.
- Never copy the operator's `config.toml`, sessions, or history into the
  scratch home; never print message bodies.

## Compatibility and rollout

n/a — research only.

## Verification

- The plan paragraph cites the CLI version, the date, and the counts printed by
  the script.
- Mutation check: n/a.

## Completion and handoff

- [ ] Checks 1–4 recorded (5 optional); fixtures prepared.
- [ ] RQ-E3-1 and RQ-E3-6 marked answered in `MP-E3/plan.md` §10; RQ-E3-2
      answered or "not pursued".
- Dependents: MP-E3-C3-T02, MP-E3-C4-T02 (Codex subagent fields).
