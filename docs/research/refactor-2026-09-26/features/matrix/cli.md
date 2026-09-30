# Cli feature use

Frozen-source use observations and working decisions. `none-found` means no use in the sampled evidence, not no users. Follow the feature ID in [features.json](../features.json) for the full evidence, caveats, exact challenge text and module list.

| ID | Feature | Observed use | Raw → working decision | Skeptical status |
| --- | --- | --- | --- | --- |
| cli-01 | Subcommand dispatch, help and usage text | heavy | simplify → simplify | not challenged |
| cli-02 | Run / attach session lifecycle (bare `aiur`, `aiur run`, `--bg`) | heavy | simplify → simplify | not challenged |
| cli-03 | Run flags that are used: --executor, --max-agents, --debug, --host, --port, --pause | regular | keep → keep | not challenged |
| cli-04 | Unused run flags: --interactive, --headless, --no-dashboard, --logs-root, guardrails acknowledgement switch | none-found | cut → simplify | overturned / narrowed |
| cli-05 | Control-command RPC transport (distribution identity, `bin/aiur rpc`, exit/error markers, 10s watchdog) | heavy | simplify → simplify | not challenged |
| cli-06 | aiur status | heavy | simplify → simplify | not challenged |
| cli-07 | aiur agents | heavy | keep → keep | not challenged |
| cli-08 | aiur watch (--full \| --changes \| --once \| --interval) | occasional | merge → merge | holds |
| cli-09 | aiur alerts (--needs-attention) | heavy | keep → keep | not challenged |
| cli-10 | aiur usage (provider meter headroom) | rare | merge → merge | holds |
| cli-11 | aiur --todo <ids...> [--only] | regular | simplify → simplify | not challenged |
| cli-12 | aiur set max-agents <n> | occasional | keep → keep | not challenged |
| cli-13 | aiur pause \| resume (global switch and per-agent <ids\|--all>) | regular | simplify → simplify | not challenged |
| cli-14 | aiur reset-budget <ids> | rare | merge → merge | holds |
| cli-15 | aiur message <id> [--message-id ID] <text> | regular | keep → keep | not challenged |
| cli-16 | aiur stop (agent-tree reap, workspace-cwd sweep, tmux/tmp sweeps) | regular | simplify → simplify | not challenged |
| cli-17 | aiur restart [--no-build] [run flags] | occasional | simplify → simplify | not challenged |
| cli-18 | aiur cleanup-stale [--dry-run] and stale manual-smoke inventory | rare | cut → keep | overturned / narrowed |
| cli-19 | Launcher dotenv credential loading | heavy | merge → simplify | overturned / narrowed |
| cli-20 | Legacy `.aiurconfig` rejection | none-found | cut → keep | overturned / narrowed |
| cli-21 | aiur --version and dispatcher/release version-skew warning | occasional | simplify → simplify | not challenged |
| cli-22 | aiur upgrade [--force] | none-found | cut → simplify | overturned / narrowed |
| cli-23 | aiur init [--force] (CLI entry) | occasional | keep → keep | not challenged |
| cli-24 | aiur units (--scope, --condition, --format, --json) | occasional | merge → keep | overturned / narrowed |
| cli-25 | aiur commands [decision-id] (decision inbox) | heavy | keep → keep | not challenged |
| cli-26 | aiur executor-answer \| executor-escalate \| executor-moot | occasional | simplify → simplify | not challenged |
| cli-27 | aiur build-orders [root] [--json] | occasional | keep → keep | not challenged |
| cli-28 | aiur analytics (--range, --since, --until, --build-order, --json) | none-found | cut → keep | overturned / narrowed |
| cli-29 | aiur github-cost (--budget graphql\|core\|all, --format, --json) | regular | keep → keep | not challenged |
| cli-30 | aiur github-usage [--json] | occasional | merge → keep | overturned / narrowed |
| cli-31 | aiur executor-wait (--timeout, --json, --as) | regular | keep → keep | not challenged |
| cli-32 | aiur executor-fast-forward <wake-id> [--as] | none-found | cut → keep | overturned / narrowed |
| cli-33 | aiur executor-roster [--json] | rare | keep → keep | not challenged |
| cli-34 | aiur executor-claim \| executor-release \| executor-revoke | none-found | cut → keep | overturned / narrowed |
| cli-35 | aiur executor-listen \| executor-emit \| executor-subscribe \| executor-unsubscribe \| executor-subscriptions | none-found | cut → simplify | overturned / narrowed |
| cli-36 | aiur findings (CLI entry: read, --record, --digest) | occasional | externalize → externalize | holds |
| cli-37 | aiur ask \| aiur asks (CLI entry + blocking-ask lines in status/watch) | rare | merge → simplify | overturned / narrowed |
| cli-38 | aiur guard-pr-deletions [base-branch] | heavy | keep → keep | not challenged; 0.0.6 cut pending PR #2840 |
| cli-39 | Release rpc/eval escape hatch (`<release>/bin/aiur rpc` into internals) | heavy | keep → keep | not challenged |
| cli-40 | aiur __identity (internal) | regular | keep → keep | not challenged |
| cli-41 | npm distribution: aiur.js launcher, postinstall provisioning, platform packages, release packaging scripts | occasional | simplify → simplify | not challenged |
| cli-42 | aiurdev dev shim core (build-if-stale, build lock, build stamp, control release reuse + retry, `aiurdev build [--deps]`, setup) | heavy | simplify → simplify | not challenged |
| cli-43 | aiurdev checkout targeting (script-path vs cwd divergence refusal) | heavy | simplify → simplify | not challenged |
| cli-44 | aiurdev manual smoke harness: --test, --test3, --clear, --allow-remote, test3 timer and phases | rare | externalize → externalize | holds |
| cli-45 | aiurdev agent IR sandbox | regular | keep → keep | not challenged |
| cli-46 | Launcher tmux configuration (two diverged copies) and Ctrl+C bridge | regular | merge → merge | holds |
