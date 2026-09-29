# Config feature use

Usage and raw recommendations are frozen research observations; challenged recommendations are continuing-researcher decisions and remain provisional until final synthesis. See the matching `raw/` feature and `challenges/` record for evidence and limits.

| ID | Feature | Observed use | Raw recommendation | Challenge |
| --- | --- | --- | --- | --- |
| config-01 | Config loading, discovery, hot reload and accessor facade | heavy | simplify | pending |
| config-02 | TUI pane and opencode keys | regular | simplify | pending |
| config-03 | Log history cap (max_log_history_mb) | occasional | merge | overturned → simplify |
| config-04 | Executor takeover advisory thresholds | none-found | simplify | pending |
| config-05 | Tracker core: kind, base branch, lifecycle states | heavy | keep | pending |
| config-06 | GitHub repository and identity keys | heavy | simplify | pending |
| config-07 | GitHub request budget and per-actor hourly ceilings | rare | simplify | pending |
| config-08 | GitHub credential pooling (tracker.github.credentials) | none-found | cut | overturned → simplify |
| config-09 | Build Order planning safeguards and provider tuning | none-found | simplify | pending |
| config-10 | Linear tracker keys | none-found | externalize | holds |
| config-11 | Polling cadence (polling.*) | heavy | simplify | pending |
| config-12 | Webhook mode tuning (webhooks.*) | occasional | simplify | pending |
| config-13 | Workspace root and bootstrap image | heavy | simplify | pending |
| config-14 | SSH remote workers (worker.*) | none-found | cut | holds |
| config-15 | Workspace lifecycle hooks (hooks.*, hooks_file) | heavy | keep | pending |
| config-16 | Backend selection and rate-limit fallback keys | heavy | simplify | pending |
| config-17 | Complexity routing (agent.routing, max_turns_by_complexity, complexity_prompts) | regular | simplify | pending |
| config-18 | Backend-specific settings: agent.claude and agent.codex (incl. sandbox policy) | heavy | simplify | pending |
| config-19 | OpenAI-compatible backend overrides (backend_configs.<backend>.*) | none-found | cut | overturned → simplify |
| config-20 | Agent turn and lifecycle limits | heavy | simplify | pending |
| config-21 | Fleet concurrency and host-load admission keys | heavy | simplify | pending |
| config-22 | Mix build gate keys | occasional | externalize | overturned → simplify |
| config-23 | Budget-broker degraded-alert tuning | none-found | cut | holds |
| config-24 | rtk output compression (agent.rtk.enabled) | none-found | cut | holds |
| config-25 | Observability and telemetry retention keys | rare | simplify | pending |
| config-26 | Dashboard server bind (server.*) | regular | keep | pending |
| config-27 | Supervisor decision policy (decisions.*) | none-found | cut | holds |
| config-28 | Event digest tuning (events.*) | none-found | cut | holds |
| config-29 | Warm-base prewarm keys (prewarm.*) | regular | keep | pending |
| config-30 | Alert sounds (alerts.*) | occasional | externalize | overturned → simplify |
| config-31 | PR-health scan (pr_health.*) | regular | keep | pending |
| config-32 | Repo-wide PR comment watching (pr_watch.*) | none-found | cut | holds |
| config-33 | ElevenLabs voice keys (elevenlabs.*) | rare | simplify | pending |
| config-34 | Upgrade notice opt-out (upgrade.check_enabled) | none-found | simplify | pending |
| config-35 | Top-level debug key | none-found | cut | holds |
| config-36 | Environment variable schema and dotenv layering | heavy | keep | pending |
| config-37 | Config reference docs, docs checker and annotated templates | heavy | simplify | pending |
| config-38 | Config.Paths state-directory registry | heavy | merge | overturned → keep |
| config-39 | Memory tracker kind (tracker.kind: memory) | none-found | simplify | pending |
