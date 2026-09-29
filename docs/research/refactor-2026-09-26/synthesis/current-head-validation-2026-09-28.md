# Current-head source validation sample

Checked 2026-09-28 against fetched `origin/main` at
`3339b887196d5e9aefb273117a14bf33391ee41f`. The research source tree
has no differences from that commit under `src/lib`, the npm launcher, or the
tmux config. This is a targeted source check of selected items in
`review/findings.json`, not a complete re-review, runtime reproduction,
incidence estimate, or confirmation that pending pull requests are merged.

## Highest-impact findings sampled

| Finding | Current-head result | Direct source evidence and limit |
| --- | --- | --- |
| `agent-backends-oc-01` (P0) | Current | `src/lib/aiur/opencode/bridge.ex:8-20` has no authorization plug. The marker branch in `chat_completions.ex:62-70,131-149` forwards coalesced text through `OperatorDispatch.send_operator/3` and opens `TurnStream`; `Caller.authorize/1` appears only in `operator_dispatch.ex:17-26` for plain text. Request reachability and token behavior were not boot-tested. |
| `agent-backends-oc-02` (P0) | Current | `open_ai_compat/command_runner.ex:10,80-99` explicitly copies `GITHUB_TOKEN` and `GH_TOKEN` from the daemon process into the `--clearenv` sandbox. This bypasses `AgentEnvironment`'s deliberate credential scrub (`agent_environment.ex:45-56`). Exposure requires either name to be set in the daemon process; no credential value was inspected. |
| `nonelixir-shell-01` (P0) | Current | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:3520-3529` loops over every `${session_root}/aiur-*-agents` file, calls `reap_aiur_agents` and removes the file. Launch creates per-run `aiur-${$}-agents` files (`:855-859`). This source check did not stop any live process. |
| `events-webhooks-executor-01` (P1) | Current | `events/subscription_store.ex:375-393` buffers later events during a stall. `resolve_stall/2` at `:465-473` sends buffered events to its own mailbox after clearing the stall, so already queued new events can run first; stale-ID rejection at `:375-382` can then discard the buffered events. An interleaving test remains necessary. |
| `events-webhooks-executor-02` (P1) | Current | `executor/claims.ex:256-263` checks for a competing live owner on claim, but `do_renew/3` at `:265-270` unconditionally `touch`es any known consumer, including an expired former owner. That restores an owner role without the competing-owner check. A concurrent lease test remains necessary. |
| `github-a-04` (P1) | Current | `github/comments.ex:124-141` requests `/comments?per_page=100` through `Transport.fetch_json_list/4`, which makes one request (`transport.ex:676-691`). Unlike the adjacent conditional fetch, this path does not follow `rel=next`; `agent_runner/comment_context.ex:88-95` uses it for issue-comment context. Pagination behavior was source-checked, not queried against GitHub. |
| `telemetry-usage-04` (P1) | Current | `usage_aggregate/store.ex:156-178` subscribes to the ledger once in bootstrap, and `:67-82` refreshes only on `:usage_ledger_delta`. A restarted ledger loses its subscriber set, while the aggregate has no resubscribe or polling path. Restart behavior was not exercised. |
| `web-rest-02` (P1) | Current | `aiur_web/control_center_cache.ex:43-79` runs arbitrary `loader.()` inside `GenServer.handle_call` with callers waiting indefinitely. `operator_control_center/payload_loader.ex:91-151` calls it around dashboard loading; `aiur.ex:473-481` supervises it before the Opencode children. This confirms synchronous coupling, not a measured outage rate. |

All eight sampled items remain **current in merged source** because the
fetched main revision is the frozen source revision. The checks above verify
the cited mechanism, not that a user has encountered it. They should be
rechecked after the release PRs merge.

## Concrete complexity reductions

These candidates remove duplicated ownership or a redundant copy; treat LOC
savings as unmeasured until implementation. They are not instructions to add
new safety gates.

1. **One tmux config and one test target** (`nonelixir-shell-03`, P1):
   `packaging/npm/aiur-cli/share/aiur.tmux.conf:51-63` retains the broken
   shell-variable form for Ctrl+C, while `scripts/aiur.tmux.conf:60-86` has
   the corrected inline helper and a Ctrl+Q binding. The harness points to
   `scripts/aiur.tmux.conf` at `scripts/verify-ctrlc-binding.sh:1-24`.
   Consolidate the shipped and dev configs and test the shipped artifact.
   Keep the working behavior, then delete the duplicate file.
2. **One CODEOWNERS grammar** (`github-a-07`, P1):
   `github/code_owners.ex:399-453` and `codeowners.ex:340-375` parse the same
   file with different acceptance rules; the former also resolves team tokens
   at `github/code_owners.ex:462-486`. A single pure parser used by both
   consumers can replace the duplicate grammars. Confirm downstream
   classification and pagination before deleting either path.
3. **One durable usage-window projection** (`web-rest-03`, P1):
   `aiur_web/streamdeck_projection.ex:305-333` and
   `aiur_web/components/operator_control_center/run_summary_strip.ex:492-523`
   duplicate `durable_observation` and `durable_percent_entry`. Both use
   `Enum.map` with a guarded, non-total anonymous function, so a persisted
   incomplete window can raise instead of being ignored. Move the projection
   into one total domain helper and remove both UI copies.
4. **Reuse the existing workspace layout helper** (`loose-3-06`, P1):
   `test_reset.ex:582-612` reconstructs `<root>/<id>` for cleanup while
   `workspace/layout.ex:33-47` includes the repo segment. The existing
   `Aiur.Workspace.workspace_path_under/2` (`workspace.ex:234-235`) is the
   smaller single source for this path. This also repairs test reset rather
   than adding another cleanup mechanism.

The requested removal of the local PR deletion guard and GitHub cache
dashboard is already in separate PRs (#2840 and #2841). Neither is assumed
present on `main` in this validation; those removals should be included in
the release and then excluded from any refactor work estimate.
