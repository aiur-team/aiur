# Code review synthesis

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`. This is a source-review research result, not a live-run validation or an implementation status report. The [lossless findings index](findings.json) is the detailed list; it preserves every raw source claim, citation, recommendation and reviewer disposition under its original ID.

## Coverage and reconciliation

All 32 planned raw units are present. Their 1,033 source IDs map exactly once to 1,012 canonical work items. Fourteen checked semantic merges combine 35 source IDs, reducing the work-item count by 21. The [merge decisions](findings.json) retain the reason and every original claim. A shared file, broad module finding, or textual resemblance was not enough to merge separate failure modes. Unmerged entries are separate for planning; their independence is not proven by this pass.

| Severity after source review | Canonical work items |
| --- | ---: |
| P0 | 3 |
| P1 | 94 |
| P2 | 697 |
| P3 | 218 |

Both independent skeptics reviewed every one of the 182 inherited P0/P1 source IDs. Their 25 severity disagreements have a source-cited reconciliation in `verdicts/severity-reconciliation-draft.json`. The other 851 P2/P3 source IDs remain provisional and have not received those independent checks. Final severity is a triage judgment on the frozen source, not an incident frequency or a claim that the bug survives later changes. Five originally high-priority citations required corrected line overlays; `location-audit.md` retains the correction trail.

## Highest-priority source findings

The three retained P0 items are concrete authorization, credential and instance-isolation paths. Each still needs a release-specific exposure check before a fix is scoped:

| Severity | Source ID | Finding |
| --- | --- | --- |
| P0 | [agent-backends-oc-01](raw/agent-backends-oc.json) | Opencode bridge dispatches Executor messages to agents without checking the bearer token |
| P0 | [agent-backends-oc-02](raw/agent-backends-oc.json) | OpenAI-compat exec_command sandbox copies GITHUB_TOKEN/GH_TOKEN into every agent command |
| P0 | [nonelixir-shell-01](raw/nonelixir-shell.json) | `aiur stop` kills live headless agents of every other running aiur instance |

The following P1 items directly touch the progress gaps, state truth, event delivery and operational boundaries measured elsewhere in this research. This is a navigation set, not an exhaustive P1 list; all 94 retained P1 items are in `findings.json`:

| Severity | Source ID | Finding |
| --- | --- | --- |
| P1 | [agent-runtime-01](raw/agent-runtime.json) | Queue-drain pause paths never confirm PauseContainment, so the codex process group is reaped 5s after a pause |
| P1 | [events-webhooks-executor-01](raw/events-webhooks-executor.json) | SubscriptionStore stall recovery reorders buffered events behind newer ones, then drops them as stale (silent event loss) |
| P1 | [events-webhooks-executor-02](raw/events-webhooks-executor.json) | Claims.renew revives an expired owner after a successor claimed, producing two live owners |
| P1 | [orch-a-01](raw/orch-a.json) | IssueSync terminal-verification wrapper lost the joinable guard: nil/unjoinable-identity terminal tickets are retained and re-fetched forever |
| P1 | [orch-b-02](raw/orch-b.json) | Parked rate-limit-fallback safety entry has no :started_at; teardown paths crash the Orchestrator with KeyError |
| P1 | [orch-b-08](raw/orch-b.json) | Rate-limit fallback: one ticket with a failing label write starves fallback and revert for every other ticket |
| P1 | [orch-b-14](raw/orch-b.json) | An unavailable decision count is fed to WaitingReason as 0, dropping waiting_for_human and emitting false `.resolved` alerts |
| P1 | [build-order-03](raw/build-order.json) | A failed or crashed catalog reconciliation is silently dropped and never retried on a repository without webhooks |
| P1 | [loose-1-02](raw/loose-1.json) | One failed follow-up append latches the DecisionStore read-only until restart, with no alert, and halts fleet dispatch |
| P1 | [loose-3-01](raw/loose-3.json) | RepoBase latches an {:error, _} prewarm phase forever under the default config (poll_seconds: 0); warm base is never rebuilt |
| P1 | [platform-misc-03](raw/platform-misc.json) | Workspace ownership guardian can latch a ticket forever (survives restarts) with no timer, alert or operator exit, while status calls the wait 'self-clearing' |
| P1 | [telemetry-usage-04](raw/telemetry-usage.json) | Usage aggregate stops refreshing forever if the ledger store restarts (subscription lost, no poll, freshness frozen) |
| P1 | [github-a-04](raw/github-a.json) | fetch_classified_issue_comments reads only page 1 (oldest 100): agents silently lose the newest PR conversation comments |
| P1 | [web-rest-02](raw/web-rest.json) | ControlCenterCache runs the whole dashboard loader inside its GenServer, under the daemon's top-level rest_for_one ahead of the Opencode supervisors |
| P1 | [nonelixir-shell-08](raw/nonelixir-shell.json) | Project-root and config discovery diverge between the engine (walks up from cwd) and Elixir (cwd, then HOME) |

## Shape of the backlog

| Category | Canonical work items |
| --- | ---: |
| duplication | 273 |
| performance | 89 |
| error-handling | 78 |
| silent-failure | 65 |
| coupling | 60 |
| dead-code | 48 |
| test-quality | 47 |
| anti-pattern | 45 |
| large-module | 39 |
| documentation | 38 |
| correctness | 33 |
| complexity | 32 |
| Other categories combined | 165 |

Duplication is the largest category, but the number of repeated literals, source spans or duplicated helper bodies is not a measured LOC saving. The topic grammar, core-to-web dependency, GitHub request classification and state-label families were merged only where the raw claims describe the same work item. Specific failures inside a large module remain independent because splitting the module does not itself repair those failures.

## Verification limits and next decision

The review uses frozen source, selective isolated probes and static skeptic checks. It did not boot the complete Aiur release, run the full suite, measure production incidence, or assess fixes after the snapshot. Raw P2/P3 claims can be false or overstated. The bounded name, concept and constant sweeps state their lexical and dynamic-code limits in their raw coverage notes. Before turning a finding into a rewrite ticket, confirm current-head reachability, source-specific failure conditions, boundary ownership, and a test that fails without the fix. The [boundary map](by-boundary.md) is a planning index with nonadditive cross-boundary membership.
