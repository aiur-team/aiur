# MP-R7 contract requests (for the coordinator)

MP-R7 owns `contracts/harness-adapter.md` and has updated it in place. The
requests below concern documents MP-R7 does not own. Base `45a290e3`,
researched 2026-10-06.

| ID | Target | Request | Needed by |
| --- | --- | --- | --- |
| CR-R7-1 | MP-R1 component map and migration plan | State where an in-repo Elixir component package would live (path-dependency app, umbrella or other) and how `mix release` includes it. Without this, a "go" from MP-R7-C4-T02 cannot be executed. | MP-R7-C4-T03, C4-T05 |
| CR-R7-2 | MP-R1-C5-T02 (kernel process helpers) | Move the whole `Aiur.Claude.RemoteControl` process-helper set (`claude/remote_control.ex:224-360`), which 8 files outside the adapters call, not only part of it. | MP-R7-C3-T05 allowlist, C4-T03/T04 |
| CR-R7-3 | MP-R1 step S10 | Name an owner ticket for the accounting/usage files that read adapter internals; MP-R7-C3-T05 allowlists them with no owner today. | MP-R7-C3-T05 |
| CR-R7-4 | MP-R1-C1 component checker | Fail on stale allowlist rows, ignore comments and `@doc`, and expose `private_namespaces` as manifest data, so the harness rule is one data entry (and `Aiur.Gemini.` is one line if PR #2870 merges, RC-22). | MP-R7-C3-T05 |
| CR-R7-5 | MP-R1-C4 (config validators) | Own the `config.ex` validator references to adapter namespaces that C3-T05 allowlists. | MP-R7-C3-T05, C4-T02 |
| CR-R7-6 | MP-R1-C6-T01 | Own the `claude-hook` controller reference in `aiur_web`. | MP-R7-C3-T05 |
| CR-R7-7 | `contracts/listener-mode.md` (MP-E7, same owner as this session) | §9: `claude-repl` steer cell = "native per Claude Code docs; capture pending (MP-E7-C4)"; OpenAI-compat steer may be native (tool-result checkpoint). Applied by the MP-E7 owner. | MP-E7-C2 |

## Possible defect (not filed; for the coordinator)

- `agent_control_cli.ex:2808` humanizes activity for every backend with the
  Codex humanizer. A fix would change CLI text, so it is outside R7
  (behaviour-preserving). It stays allowlisted in MP-R7-C3-T05.
- Finding R7-C1-F1: running-entry delivery flags are not recomputed on
  fallback or RC promotion (`orchestrator/dispatcher.ex:2549`;
  `orchestrator/state.ex:441-461`). Fix owner: MP-E7-C2-T04.
