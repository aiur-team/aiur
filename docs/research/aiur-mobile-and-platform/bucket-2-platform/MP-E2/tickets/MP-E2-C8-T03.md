---
ticket_id: MP-E2-C8-T03
feature_id: MP-E2
chunk_id: MP-E2-C8
bucket: 2-platform
title: aiur-agent skill guidance, option-count census, then flip require_suggested_responses
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T02, MP-E2-C4-T02]
prior_units: [U6]
prior_boundaries: [DOCS (skills), DEC #27]
prior_features: []
prior_findings: [AGENTS.md "A claimed saving must be measured" item 5 (count the population), contract §3]
size_owner: "DOCS (.claude/skills/aiur-agent/attention-and-resolve.md, emit-and-subscribe.md); DECISIONS (one default literal)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C8-T03 — aiur-agent skill guidance, option-count census, then flip the rule

## Identity and outcome

- Bucket 2, MP-E2, chunk C8.
- **User value:** agents write Commands with 2–3 suggested responses (recommended first),
  which are faster to answer from a phone or watch; native questions are used when the
  harness supports them.
- **Deliverable (two PRs, in order):**
  1. Skill guidance in `.claude/skills/aiur-agent/emit-and-subscribe.md` (Command
     authoring) and `attention-and-resolve.md` (when to use a native ask vs
     `decision.requested`), plus `src/prompts/shared-agent-instructions.md` if it states
     option guidance (grep at implementation).
  2. After ≥ 7 days of the C1-T02 warning in production: a census, then flip
     `decisions.require_suggested_responses` default to `true` **only if** the census
     supports it.
- **Non-goals:** changing native question option rules.

## Dependencies and blockers

- C1-T02 (warning + key), C4-T02 (native capture exists, for the "native vs emit" text).
- DESIGN-E2 §4.2 (the 2–3 rule and the native exception) approved.

## Verified starting point (`45a290e3`)

- `.claude/skills/aiur-agent/emit-and-subscribe.md:44-80` (operator direction via
  `decision.requested`; "question, relevant context, options, recommendation" `:65`).
- `.claude/skills/aiur-agent/attention-and-resolve.md:9-22` (`decision.requested` vs
  attention).
- Command log: `decisions.ndjson` under the decision state dir
  (`Aiur.Paths.decision_state_dir/0`, used at `executor_command_attention.ex:134`).

## Chosen design — census (read-only, on a copy)

Run on the operator's machine, never against the live file directly:

```bash
SRC="$(mise exec -- env -C src mix run --no-start -e 'IO.puts(elem(Aiur.Paths.decision_state_dir(), 1))' 2>/dev/null)/decisions.ndjson"
CEN="$HOME/.aiur/tmp/e2-census-$(date +%Y%m%d)"; mkdir -p "$CEN"; cp "$SRC" "$CEN/decisions.ndjson"
python3 -I - "$CEN/decisions.ndjson" <<'EOF'
import json, sys, collections
c = collections.Counter(); first = collections.Counter(); n = 0
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r.get("event_type") not in (None, "requested"): continue
    d = r.get("data", r)
    if d.get("legacy_attention"): continue          # attention projections are exempt
    k = len(d.get("options") or []); c[k] += 1; n += 1
    rec = (d.get("recommendation") or {}).get("option_id")
    opts = [o.get("id") for o in d.get("options") or []]
    first["rec_first" if rec and opts and opts[0] == rec else ("no_rec" if not rec else "rec_not_first")] += 1
print("requests", n); print("option_counts", dict(sorted(c.items()))); print("recommendation", dict(first))
EOF
```

(`mix run --no-start` must not boot the app — memory "mix test clobbers agent-token";
if the path helper needs the app, read the path from `aiur status --json` instead.)

Decision rule (recorded in the PR body with census date and size, AGENTS.md item 5):
flip to `true` only if ≥ 90 % of agent-authored requests in the last 7 days already have
2–3 options; otherwise keep `false`, record the counts, and revisit.

## Implementation steps

1. PR 1: skill text (≈25 lines across the two files).
2. PR 2: census; if the rule passes, change the default literal in
   `config/schema/decisions.ex` and the `configuration.md` default; else no code change,
   only a note in the PR/issue.

## Non-happy paths

- Census on a churned/rotated log: state the window actually covered.
- Rule fails: no flip; the warning stays.

## Compatibility and rollout

- The flip makes 1-option or 4+-option agent requests fail; agents get the validation
  error (`{:suggested_responses, reason}`) in their tool result and retry — announce in
  the skill first (PR 1 precedes PR 2).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/config/decisions_suggested_responses_test.exs
python3 scripts/check-config-docs.py
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "default require_suggested_responses" (PR 2 only) | `true` after the flip | default literal |

Census output pasted in the PR body (date, file size, counts).

## Completion and handoff

- [ ] Skill text merged; census recorded; flip decided by the rule.
- Docs: `reference/configuration.md` default (PR 2).
