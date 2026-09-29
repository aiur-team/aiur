# Cli feature use

Usage and raw recommendations are frozen research observations; challenged recommendations are continuing-researcher decisions and remain provisional until final synthesis. See the matching `raw/` feature and `challenges/` record for evidence and limits.

| ID | Feature | Observed use | Raw recommendation | Challenge |
| --- | --- | --- | --- | --- |
| cli-01 | Subcommand dispatch, help and usage text | heavy | simplify | pending |
| cli-02 | Run / attach session lifecycle (bare `aiur`, `aiur run`, `--bg`) | heavy | simplify | pending |
| cli-03 | Run flags that are used: --executor, --max-agents, --debug, --host, --port, --pause | regular | keep | pending |
| cli-04 | Unused run flags: --interactive, --headless, --no-dashboard, --logs-root, guardrails acknowledgement switch | none-found | cut | overturned → simplify |
| cli-05 | Control-command RPC transport (distribution identity, `bin/aiur rpc`, exit/error markers, 10s watchdog) | heavy | simplify | pending |
| cli-06 | aiur status | heavy | simplify | pending |
| cli-07 | aiur agents | heavy | keep | pending |
| cli-08 | aiur watch (--full \| --changes \| --once \| --interval) | occasional | merge | pending |
| cli-09 | aiur alerts (--needs-attention) | heavy | keep | pending |
| cli-10 | aiur usage (provider meter headroom) | rare | merge | pending |
| cli-11 | aiur --todo <ids...> [--only] | regular | simplify | pending |
| cli-12 | aiur set max-agents <n> | occasional | keep | pending |
| cli-13 | aiur pause \| resume (global switch and per-agent <ids\|--all>) | regular | simplify | pending |
| cli-14 | aiur reset-budget <ids> | rare | merge | pending |
| cli-15 | aiur message <id> [--message-id ID] <text> | regular | keep | pending |
| cli-16 | aiur stop (agent-tree reap, workspace-cwd sweep, tmux/tmp sweeps) | regular | simplify | pending |
| cli-17 | aiur restart [--no-build] [run flags] | occasional | simplify | pending |
| cli-18 | aiur cleanup-stale [--dry-run] and stale manual-smoke inventory | rare | cut | pending |
| cli-19 | Launcher dotenv credential loading | heavy | merge | pending |
| cli-20 | Legacy `.aiurconfig` rejection | none-found | cut | overturned → keep |
| cli-21 | aiur --version and dispatcher/release version-skew warning | occasional | simplify | pending |
| cli-22 | aiur upgrade [--force] | none-found | cut | pending |
| cli-23 | aiur init [--force] (CLI entry) | occasional | keep | pending |
| cli-24 | aiur units (--scope, --condition, --format, --json) | occasional | merge | pending |
| cli-25 | aiur commands [decision-id] (decision inbox) | heavy | keep | pending |
| cli-26 | aiur executor-answer \| executor-escalate \| executor-moot | occasional | simplify | pending |
| cli-27 | aiur build-orders [root] [--json] | occasional | keep | pending |
| cli-28 | aiur analytics (--range, --since, --until, --build-order, --json) | none-found | cut | pending |
| cli-29 | aiur github-cost (--budget graphql\|core\|all, --format, --json) | regular | keep | pending |
| cli-30 | aiur github-usage [--json] | occasional | merge | pending |
| cli-31 | aiur executor-wait (--timeout, --json, --as) | regular | keep | pending |
| cli-32 | aiur executor-fast-forward <wake-id> [--as] | none-found | cut | overturned → keep |
| cli-33 | aiur executor-roster [--json] | rare | keep | pending |
| cli-34 | aiur executor-claim \| executor-release \| executor-revoke | none-found | cut | overturned → keep |
| cli-35 | aiur executor-listen \| executor-emit \| executor-subscribe \| executor-unsubscribe \| executor-subscriptions | none-found | cut | overturned → simplify |
| cli-36 | aiur findings (CLI entry: read, --record, --digest) | occasional | externalize | pending |
| cli-37 | aiur ask \| aiur asks (CLI entry + blocking-ask lines in status/watch) | rare | merge | pending |
| cli-38 | aiur guard-pr-deletions [base-branch] | heavy | keep | pending |
| cli-39 | Release rpc/eval escape hatch (`<release>/bin/aiur rpc` into internals) | heavy | keep | pending |
| cli-40 | aiur __identity (internal) | regular | keep | pending |
| cli-41 | npm distribution: aiur.js launcher, postinstall provisioning, platform packages, release packaging scripts | occasional | simplify | pending |
| cli-42 | aiurdev dev shim core (build-if-stale, build lock, build stamp, control release reuse + retry, `aiurdev build [--deps]`, setup) | heavy | simplify | pending |
| cli-43 | aiurdev checkout targeting (script-path vs cwd divergence refusal) | heavy | simplify | pending |
| cli-44 | aiurdev manual smoke harness: --test, --test3, --clear, --allow-remote, test3 timer and phases | rare | externalize | pending |
| cli-45 | aiurdev agent IR sandbox | regular | keep | pending |
| cli-46 | Launcher tmux configuration (two diverged copies) and Ctrl+C bridge | regular | merge | pending |
