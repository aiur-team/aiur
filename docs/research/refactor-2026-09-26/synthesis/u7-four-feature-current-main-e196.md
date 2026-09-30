# U7: four provisional feature cuts at `main@e196b965`

Read-only source/config/docs/CI recheck of `integrations-03`,
`integrations-09`, `integrations-46`, and `cli-44` at
`e196b9658fcd3a6a010908ec0344579c8f51dd2b`. Historical usage counts in
the [earlier U7 note](u7-live-feature-cut-gates-2026-09-29.md) were not
recounted here. Reachable code is not proof of current operator use, and
absence from this host's old config sample is not proof of global nonuse.

| Feature | Current reachable contract | Decision and uncertainty |
| --- | --- | --- |
| `integrations-03` Linear | `src/lib/aiur/tracker.ex:161-167` selects the Linear adapter; `src/lib/aiur/config.ex:1315-1324` validates Linear settings; `src/examples/workflows/linear-codex.yaml:2,14` is a supported example. `src/lib/aiur/codex/dynamic_tool.ex:9-37` unconditionally registers `linear_graphql`; its specs reach Codex (`codex/frames.ex:52`), Claude (`claude/coding_agent.ex:234`) and OpenAI-compatible (`open_ai_compat/tool_spec.ex:109`) sessions. `.codex/skills/linear/SKILL.md` and `website/docs-app/reference/configuration.md:79,112-115` still describe it. | **Conditional cut only.** The old 68-config sample found no active tracker, but agent-tool calls in GitHub workspaces show the tool's availability and do not prove Linear tracker use. Recount current configured deployments and genuine tracker/tool workflows before choosing a replacement; cut adapter, tool, skill, init, examples, docs and tests as one contract. |
| `integrations-09` Claude REPL/Remote Control | `src/lib/aiur/coding_agent/registry.ex:8-12` registers `claude-repl`; `coding_agent/providers/claude.ex:25-30,81-95` names it as the headless backend's remote transport. Routes remain in `config/routing_value.ex:45-55`, `init/labels.ex:166-175`, TUI `agent_list/input.ex:108`, and `src/lib/aiur_web/router.ex:169-177`. `agent_runner/session_lifecycle.ex:646,658-682` and `process_reaper.ex:289` use shared RC process behavior. `AGENTS.md:146-149` and configuration docs `:208,253` advertise it. | **Conditional transport cut.** The old zero-remote telemetry sample is historical. Recount current labels/configs/dispatch and prove an accepted interaction replacement. Move shared process cleanup, fallback and pause behavior before removing the REPL transport or its hook. |
| `integrations-46` `aiur-build` | `.claude/skills/aiur-build/SKILL.md:1-12` is an Executor entry point; `.codex/skills/aiur-build` links to it; `website/docs-app/skills.md:52` and the Executor reference link it. `src/lib/aiur/agent_skills.ex:37-46` deliberately excludes it from issue-worker installs, while `src/test/aiur/aiur_agent_skill_test.exs:31,45` requires the Executor skill. The publication receipt extracts modules from pinned repository commit `6447f9c...` (`publication_core_receipt.py:16-35,163-183`). | **Defer externalization.** A separate distribution must preserve the versioned pack/schema, publication authority, historical Git receipt, and offline checkout/release behavior. Relocation alone saves zero net lines. |
| `cli-44` manual harness | `scripts/aiurdev:680-850` consumes `--test`, `--test3`, `--clear` and `--allow-remote`; it blocks agent workspaces at `:727-739`, validates `.aiur-test-tickets.json` before resetting at `:741-762`, scopes/reset/settles tickets at `:793-833`, and starts the test3 timer at `:835-849`. `AGENTS.md:432-594` requires a real foreground `--test` TUI; `website/docs-app/reference/cli.md:392-395` documents all four flags. `src/test/scripts_aiurdev_test.exs:866-1195` covers reset, guard, clear and forwarding behavior. | **Keep both `--test` and `--test3` now.** This session used a real foreground `scripts/aiurdev --test3 --force --allow-remote` run with tmux pane input for the v0.0.7 acceptance, superseding the earlier transcript sample's zero-`--test3` observation. Evaluate `--clear`, timer and phase scripts separately; extraction needs equivalent real-release/TUI acceptance and sandbox-ticket protection. |

The ordinary CI coverage partitions run the Elixir test suite via
`.github/workflows/ci.yml:300-355`, which includes the source tests above;
CI does not perform the live foreground GitHub sandbox/TUI run. The skill's
Python test tree is tracked under `.claude/skills/aiur-build/scripts/tests/`,
but no dedicated invocation was found in that CI workflow. No tests,
config population recount, daemon call, GitHub mutation, or publication
exercise was performed for this note.
