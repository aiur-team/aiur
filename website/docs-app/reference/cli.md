---
pageClass: cli-reference
---
# CLI

Choose a topic below. Use `aiur command` to list, inspect, or answer Commands; `aiur commands` and the explicit answer verbs remain supported for compatibility. Existing section links lead to the same reference content.

- [CLI launch and setup](./cli-launch)
- [CLI operations](./cli-operations)
- [CLI decisions and Executor events](./cli-decisions)
- [CLI development commands](./cli-development)
- [Global launch options](./cli-options)
- [Build history commands](./build-history-commands)

## What the CLI does

[Read this section](./cli-launch#what-the-cli-does).

## Start, initialize, and queue

[Read this section](./cli-launch#start-initialize-and-queue).

### Commands

[Read this section](./cli-launch#commands).

## Inspect and operate a running daemon

[Read this section](./cli-operations#inspect-and-operate-a-running-daemon).

### Restart semantics

[Read this section](./cli-operations#restart-semantics).

### Saved uncommitted work

[Read this section](./cli-operations#saved-uncommitted-work).

## Build history commands — [feature, epic and history export commands](/reference/build-history-commands)

[Read this section](./cli-operations#build-history-commands-—-feature-epic-and-history-export-commands).

## Dashboard page commands

[Read this section](./cli-operations#dashboard-page-commands).

### Output contract

[Read this section](./cli-operations#output-contract).

## Experiments

[Read this section](./cli-operations#experiments).

## Decisions, Executor events, and findings

[Read this section](./cli-decisions#decisions-executor-events-and-findings).

### `executor-wait` outcomes

[Read this section](./cli-decisions#executor-wait-outcomes).

### Wake ledger bound and lease TTL

[Read this section](./cli-decisions#wake-ledger-bound-and-lease-ttl).

### Executor roster states

[Read this section](./cli-decisions#executor-roster-states).

## Operational facts that change an incident response

[Read this section](./cli-operations#operational-facts-that-change-an-incident-response).

## `aiurdev`, for developing Aiur itself

[Read this section](./cli-development#aiurdev-for-developing-aiur-itself).

### Which checkout `aiurdev` targets

[Read this section](./cli-development#which-checkout-aiurdev-targets).

### aiur queue

[Read this section](./cli-operations#aiur-queue).

## `pr merge`

[Read this section](./cli-operations#pr-merge).

## Offline experiment statistics

[Read this section](./cli-operations#offline-experiment-statistics).

## Voice transcripts

| Command | Behavior | Example |
| --- | --- | --- |
| `aiur voice transcripts [<conversation_id>] [--target <ticket>\|executor] [--limit N] [--json]` | List voice sessions or show a complete transcript in file order. | `aiur voice transcripts --target executor --json` |

Requires a running daemon, including headless runs without a dashboard. Listing defaults
to 100 sessions (maximum 100); `--target` filters by ticket id or `executor`.
Rows show id, target, local start time, duration, end reason, user turns and draft counts
(sent/proposed/discarded/stale). Open sessions have unknown duration and end reason.
An empty list prints “No voice conversations recorded.” and exits successfully.

Pass a `vc_` conversation id to show all turns, context with observation age at recording,
tool calls, drafts and delivery outcomes in stored order. `--target` and `--limit` apply
only to listing. An unknown id exits 1 with “No such conversation”. A torn final record
is omitted and reported as “(last record incomplete)”; invalid interior records are reported
by line number. `--json` returns index records for a list and raw complete records for a
single conversation, without human-readable warnings. No summaries are generated.
