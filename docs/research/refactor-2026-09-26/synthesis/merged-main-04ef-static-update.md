# Current-main citation update after factual-Command guidance

This is a static source-citation recheck, not a behavior test or runtime-incidence
claim. The 986 canonical findings were compared from frozen source
`3339b887196d5e9aefb273117a14bf33391ee41f` against the published
`fc8270bb6` release head and merged `main` at
`04ef05c41bbb30ad2a349c6bd72142e492592335`. Both runs used
`tooling/current_head_static_triage.py` with the same `review/findings.json`
and no correction ledger. The old correction ledger cannot be carried forward
unchanged: its verified anchor for `web-rest-08` no longer has identical lines
at this head.

| Head | Identical cited lines | Stale citations | Unknown citations |
| --- | ---: | ---: | ---: |
| `fc8270bb6` | 722 | 37 | 227 |
| `04ef05c41` | 711 | 37 | 238 |

Exactly eleven findings moved from `current` to `unknown`; none moved to
`stale`. Source recheck is needed for these IDs before using their old line
anchors in implementation work:

| Changed source | Finding IDs |
| --- | --- |
| `src/lib/aiur/codex/dynamic_tool/emit_event.ex` | `agent-backends-cc-23`, `agent-backends-cc-31`, `agent-backends-cc-42` |
| `.claude/skills/aiur-run/SKILL.md` | `skills-prompts-cont-05`, `skills-prompts-cont-30`, `skills-prompts-cont-31`, `skills-prompts-cont-68`, `skills-prompts-cont-69` |
| `.claude/skills/aiur-agent/emit-and-subscribe.md` | `skills-prompts-cont-73` |
| `src/test/aiur/agent_runner/tool_executor_test.exs` | `tests-5-05`, `tests-5-24` |

The changed files include the merged factual-Command guidance in PR #2876.
Line changes in those files explain the citation-status movement; they do not
prove that any finding was fixed, regressed, or encountered in a live run.
The 37 stale and 238 unknown findings remain explicit review queues.

Reproduce from a checkout containing both Git commits:

```sh
python3 docs/research/refactor-2026-09-26/tooling/current_head_static_triage.py \
  --findings docs/research/refactor-2026-09-26/review/findings.json \
  --base 3339b887196d5e9aefb273117a14bf33391ee41f \
  --head 04ef05c41bbb30ad2a349c6bd72142e492592335 \
  --output /tmp/aiur-refactor-current-head-04ef05.json
```
