# Config feature use

Frozen-source use observations and working decisions. `none-found` means no use in the sampled evidence, not no users. Follow the feature ID in [features.json](../features.json) for the full evidence, caveats, exact challenge text and module list.

| ID | Feature | Observed use | Raw → working decision | Skeptical status |
| --- | --- | --- | --- | --- |
| config-01 | Config loading, discovery, hot reload and accessor facade | heavy | simplify → simplify | not challenged |
| config-02 | TUI pane and opencode keys | regular | simplify → simplify | not challenged |
| config-03 | Log history cap (max_log_history_mb) | occasional | merge → simplify | overturned / narrowed |
| config-04 | Executor takeover advisory thresholds | none-found | simplify → simplify | not challenged |
| config-05 | Tracker core: kind, base branch, lifecycle states | heavy | keep → keep | not challenged |
| config-06 | GitHub repository and identity keys | heavy | simplify → simplify | not challenged |
| config-07 | GitHub request budget and per-actor hourly ceilings | rare | simplify → simplify | not challenged |
| config-08 | GitHub credential pooling (tracker.github.credentials) | none-found | cut → simplify | overturned / narrowed |
| config-09 | Build Order planning safeguards and provider tuning | none-found | simplify → simplify | not challenged |
| config-10 | Linear tracker keys | none-found | externalize → cut | holds |
| config-11 | Polling cadence (polling.*) | heavy | simplify → simplify | not challenged |
| config-12 | Webhook mode tuning (webhooks.*) | occasional | simplify → simplify | not challenged |
| config-13 | Workspace root and bootstrap image | heavy | simplify → simplify | not challenged |
| config-14 | SSH remote workers (worker.*) | none-found | cut → cut | holds |
| config-15 | Workspace lifecycle hooks (hooks.*, hooks_file) | heavy | keep → keep | not challenged |
| config-16 | Backend selection and rate-limit fallback keys | heavy | simplify → simplify | not challenged |
| config-17 | Complexity routing (agent.routing, max_turns_by_complexity, complexity_prompts) | regular | simplify → simplify | not challenged |
| config-18 | Backend-specific settings: agent.claude and agent.codex (incl. sandbox policy) | heavy | simplify → simplify | not challenged |
| config-19 | OpenAI-compatible backend overrides (backend_configs.<backend>.*) | none-found | cut → simplify | overturned / narrowed |
| config-20 | Agent turn and lifecycle limits | heavy | simplify → simplify | not challenged |
| config-21 | Fleet concurrency and host-load admission keys | heavy | simplify → simplify | not challenged |
| config-22 | Mix build gate keys | occasional | externalize → simplify | overturned / narrowed |
| config-23 | Budget-broker degraded-alert tuning | none-found | cut → cut | holds |
| config-24 | rtk output compression (agent.rtk.enabled) | none-found | cut → cut | holds |
| config-25 | Observability and telemetry retention keys | rare | simplify → simplify | not challenged |
| config-26 | Dashboard server bind (server.*) | regular | keep → keep | not challenged |
| config-27 | Supervisor decision policy (decisions.*) | none-found | cut → cut | holds |
| config-28 | Event digest tuning (events.*) | none-found | cut → cut | holds |
| config-29 | Warm-base prewarm keys (prewarm.*) | regular | keep → keep | not challenged |
| config-30 | Alert sounds (alerts.*) | occasional | externalize → simplify | overturned / narrowed |
| config-31 | PR-health scan (pr_health.*) | regular | keep → keep | not challenged |
| config-32 | Repo-wide PR comment watching (pr_watch.*) | none-found | cut → cut | holds |
| config-33 | ElevenLabs voice keys (elevenlabs.*) | rare | simplify → simplify | not challenged |
| config-34 | Upgrade notice opt-out (upgrade.check_enabled) | none-found | simplify → simplify | not challenged |
| config-35 | Top-level debug key | none-found | cut → cut | holds |
| config-36 | Environment variable schema and dotenv layering | heavy | keep → keep | not challenged |
| config-37 | Config reference docs, docs checker and annotated templates | heavy | simplify → simplify | not challenged |
| config-38 | Config.Paths state-directory registry | heavy | merge → keep | overturned / narrowed |
| config-39 | Memory tracker kind (tracker.kind: memory) | none-found | simplify → simplify | not challenged |
