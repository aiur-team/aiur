# Short cross-module string source review (frozen `3339b887`)

The companion `short-string-source-screen.json` enumerates all **709** strings shorter than eight characters in the low-fanout inline literal ledger, with two frozen source anchors per value. The reproducer reads the frozen source lines and checks that each anchor still exists. Its categories describe what the value appears to be; they do **not** assert that every consumer shares a policy or that a common helper is safe.

| Source role | Groups | Review boundary |
|---|---:|---|
| Crosslinked to existing raw finding | 8 | Existing IDs, no additive count |
| Syntax or visual symbol | 117 | Equal punctuation/whitespace does not define a product policy |
| Display or log fragment | 79 | Text identity alone does not define a reusable behavior |
| External protocol or path token | 57 | Wire/OS syntax is owned by the external protocol; caller policy remains distinct |
| Field or vocabulary | 356 | Schema names and common words need owner/caller tracing |
| Identity or schema field | 12 | Typed validation and persistence boundaries need tracing |
| Status vocabulary | 23 | State machines must be compared, not merged by spelling |
| Topic fragment | 7 | Check event family, identifier domain and payload grammar |
| Mixed fragment | 50 | Check local formatting or transport contract |

The final counts are generated from the JSON; this table should be updated if its screening rules change. In particular, **448 groups remain open for semantic caller review** in the five latter rows. A source-role screen is useful to avoid false findings, but it is not full semantic clearance of those groups.

Direct source checks show why values alone cannot be treated as duplicated implementation:

- `"agent"` means an assistant display tag in `src/lib/aiur/agent_events.ex:107`, but one of three event-source values in `src/lib/aiur/agent_runner/events_digest.ex:74`.
- `"state"` is a freshness source field in `src/lib/aiur/analytics_cli.ex:263` and an embedded lock result field in `src/lib/aiur/build_gate.ex:293`.
- `"OPEN"` is an asks CLI display state in `src/lib/aiur/asks_cli.ex:60` and an input spelling normalized by BuildOrder lifecycle at `src/lib/aiur/build_order/lifecycle.ex:88`.
- `"\n"` is both a split delimiter (`src/lib/aiur/affected_tests.ex:123`) and a join delimiter (`src/lib/aiur/agent_command_installer.ex:69`). The literal is common syntax, not an extraction candidate.
- `"-c"` is a shell flag in `src/lib/aiur/agent_runner/turn_progress.ex:181` and `src/lib/aiur/app_server/adapter.ex:195`; sharing the flag would not share the process contracts.
- `"&amp;"` appears in HTML escaping pipelines in `src/lib/aiur/events/sanitizer.ex:387` and `src/lib/aiur/external_content.ex:88`. The body unit already source-reviewed this family as a possible low-level escape primitive while preserving the distinct sanitizer boundaries; it did not promote it as a standalone finding.

Some short strings point to a real shared contract, but the associated behavior has already been counted: `"ticket."` in AgentEventFeed and EventLine maps to `dup-by-body-46` and `dup-by-concept-02`; `"ticket:"` request attribution in GitHub Quota and RequestLog maps to `dup-by-body-42`; `"run_id"` maps to `dup-by-name-04`; the agent state labels map to `dup-by-concept-01`. `"0.0.0.0"` led to `dup-by-constant-05`: `HttpServer.display_host/1` (`src/lib/aiur/http_server.ex:264`) and `PaneManager.Anchor.control_url_host/0` (`src/lib/aiur/pane_manager/anchor.ex:61`) both advertise loopback for wildcard bind hosts. Their nonbinary input policies differ, so the candidate is a narrow advertised-host policy, not an interchangeable function.

The other open topic prefixes are not one grammar by spelling alone. `"phase:"` is BuildOrder metadata parsing versus planning-source emission (`src/lib/aiur/build_order/metadata.ex:37`, `src/lib/aiur_web/build_order/planning_source.ex:244`), so it warrants a roundtrip contract check. `"pr:"` names a GitHub event key in `src/lib/aiur/events/github_keys.ex:46` but a telemetry record ID in `src/lib/aiur/run_telemetry/github_enricher.ex:182`; those namespaces have different fields. `"agent:"` in `AgentEvents.agent_topic/1` and `Codex.DynamicTool.TicketState` is a topic versus label cleanup path; retain their owners. These remain explicit semantic follow-ups rather than additional findings.
