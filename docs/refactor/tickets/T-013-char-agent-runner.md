# T-013: Characterization: agent_runner drain/resume & digest

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_runner.ex` (2,215 lines) is decomposed in Phase 3 (T-034..T-036) and its residual backend branching migrates behind the backend behaviour in T-016. The hotspot map (`docs/refactor/research-history-hotspots.md`, characterization item 7) and the decomposition research (`docs/refactor/research-arch/giant-agent_runner.md` §4, "Missing characterization coverage") both name the same uncovered seams: queued-message drain outcomes (a queued operator message must never convert a successful turn into a failure — the #552 class), events-digest filtering (what reaches the agent vs what is suppressed), and the session-resume handle lifecycle (`Aiur.SessionHandle` save/load; terminal states CLEAR the handle — the #610 "shipped-but-inert fix" class; `CodingAgent.resumable?/1` gating per backend).

This ticket freezes that behavior into `src/test/aiur/regression/agent_runner_lifecycle_test.exs` BEFORE any decomposition wave moves the code. Everything is tested through already-public surface: `AgentRunner`'s `@doc false` test API (`claim_after_queue_update_for_test/3`, `render_events_digest_for_test/2`, `resume_thread_id/3`, `turn_handle_attrs/2`, `session_handle_to_save/2`, `persist_handle_best_effort/3`, `post_aiur_turn_markers/4`), `Aiur.Orchestrator`'s public queue API (`claim_next_queue_item/2`, `consume_delivered_queue_items/2`, `restore_delivered_queue_items/2`, `fail_delivered_queue_items/3`, `restore_queue_item_pending/2`), `Aiur.SessionHandle` (with injectable `:dir`/`:hostname`), and `Aiur.Events.DebugLog.subscribe/0`. No production code changes of any kind. The existing `post_aiur_turn_markers` tests in `src/test/aiur/agent_runner_test.exs:20-86` stay green and untouched; this ticket adds only a fan-out census on top of them.

## Scope (exact)

Authoring constraints (binding for every test in this file):

- **(a)** Never assert exact counts on shared singletons (the census in step 12 counts a locally built writers list, which is allowed).
- **(b)** Every `assert_receive` window is `2_000` ms or greater. Sub-2000 windows are forbidden.
- **(c)** No `Process.sleep` anywhere in the file. Synchronization is `assert_receive` / return values only.
- **(d)** The file touches `src/lib/aiur/events` (`DebugLog`), so the setup isolates `:log_file` to a per-test tmp dir using the exact pattern of `src/test/aiur/events/subscription_store_test.exs:8-37` (save original, `Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))`, restore-or-delete in `on_exit`, non-raising `File.rm_rf(tmp_dir)`).
- **(e)** This ticket runs no engine-path tests, so the `AIUR_RELEASE_NODE` rule does not apply — do not set it.
- **(f)** Resource fan-out gets a census-style count assertion (step 12).
- **(g)** Characterization means the current code is the specification. Every expected outcome below was read off the cited source lines. If a test fails when run exactly as written, first re-check you drove the API exactly as specified; if the observed behavior genuinely differs, assert the observed value, add a one-line `# characterized <observed>, ticket expected <stated>` comment above that assertion, and note the delta in the PR description. Never change production code to make a test pass.

Steps:

1. Create `src/test/aiur/regression/agent_runner_lifecycle_test.exs` with module `Aiur.Regression.AgentRunnerLifecycleTest`, `use ExUnit.Case, async: false` (the dominant pattern in the existing 19 regression tests), and these aliases only: `Aiur.AgentRunner`, `Aiur.CodingAgent`, `Aiur.Events.DebugLog`, `Aiur.Orchestrator`, `Aiur.SessionHandle`.

2. Add the `setup` block per constraint (d), returning `%{tmp_dir: tmp_dir}`. Add one private helper:
   ```elixir
   defp start_orchestrator!(name) do
     {:ok, pid} = Orchestrator.start_link(name: name)
     on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
     name
   end
   ```
   and one private event builder `digest_event(identifier, id, message)` returning `%{id: id, topic: "ticket.#{identifier}.issue.commented", source: :github, author_trusted?: true, message: message, comment: %{"body" => message}}` (mirrors the proven shape in `src/test/aiur/agent_runner_test.exs:371-379`). Each test that needs an orchestrator starts its own uniquely named instance (`Module.concat(__MODULE__, :DrainOrch1)` etc. — a distinct atom per test) and uses a unique issue identifier (`"AR13-D1"` etc. — never reuse an identifier across tests). Enqueue digests with `assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})` exactly as `src/test/aiur/agent_runner_test.exs:381` does.

3. `describe "queued-message drain accounting (#552 class: success never becomes failure)"` — pins the exactly-once queue-item settlement seam of `src/lib/aiur/agent_runner.ex:1422-1464` and the deliver-now gate of `src/lib/aiur/agent_runner.ex:1331-1343`, via the orchestrator queue API (`src/lib/aiur/orchestrator.ex:5034-5131, 5467-5600`). Six tests:
   1. `test "deliver_now? false is ignored and leaves the item claimable"` — start orchestrator, enqueue one digest event for `"AR13-D1"`. Action/expect: `assert :ignored = AgentRunner.claim_after_queue_update_for_test(orch, "AR13-D1", false)`; then `assert {:ok, %{category: :coordination_event, event_type: :events_digest}} = AgentRunner.claim_after_queue_update_for_test(orch, "AR13-D1", true)` — the ignored wake consumed nothing.
   2. `test "a claimed digest is delivered: a second claim is empty"` — enqueue one digest for `"AR13-D2"`; `assert {:ok, _item} = Orchestrator.claim_next_queue_item(orch, "AR13-D2")`; `assert :empty = Orchestrator.claim_next_queue_item(orch, "AR13-D2")`.
   3. `test "restore_delivered_queue_items returns the in-flight item to the queue"` — enqueue one digest (event id `123`) for `"AR13-D3"`; claim it (`{:ok, _}`), second claim is `:empty`; `assert :ok = Orchestrator.restore_delivered_queue_items(orch, "AR13-D3")`; then `assert {:ok, %{body: %{events: [%{id: 123}]}}} = Orchestrator.claim_next_queue_item(orch, "AR13-D3")` — assert on event content, not item id (digest claims coalesce). This is the `{:paused, _}` branch contract of `src/lib/aiur/agent_runner.ex:1432-1443`: a pause restores, never loses or fails, the item.
   4. `test "consume_delivered_queue_items retires items permanently"` — enqueue, claim, `assert :ok = Orchestrator.consume_delivered_queue_items(orch, "AR13-D4")`; then claim is `:empty`; then `restore_delivered_queue_items` followed by another claim is still `:empty` (consumed items never return).
   5. `test "fail_delivered_queue_items terminally fails delivered items"` — enqueue, claim, `assert :ok = Orchestrator.fail_delivered_queue_items(orch, "AR13-D5", :boom)`; claim is `:empty`; `restore_delivered_queue_items` then claim is still `:empty` (failed items never restore).
   6. `test "restore_queue_item_pending re-queues one item by id (completion-race requeue)"` — enqueue one digest (event id `321`) for `"AR13-D6"`; `assert {:ok, item} = Orchestrator.claim_next_queue_item(orch, "AR13-D6")`; `assert :ok = Orchestrator.restore_queue_item_pending(orch, item.id)`; `assert {:ok, %{body: %{events: [%{id: 321}]}}} = Orchestrator.claim_next_queue_item(orch, "AR13-D6")`. This is the accounting seam behind both the `{:error, {:turn_start_failed, :response_timeout | :turn_timeout}}` requeue (`src/lib/aiur/agent_runner.ex:1445-1453`) and the `handle_checkpoint_delivery_failure` restore clauses (`src/lib/aiur/agent_runner.ex:1844-1855`).

4. `describe "events-digest filtering (what reaches the agent vs is suppressed)"` — pins `render_events_digest/2` + `author_trusted_for_digest?/1` + debounce + external-content wrapping (`src/lib/aiur/agent_runner.ex:1503-1685`) via `AgentRunner.render_events_digest_for_test/2`. Eight tests (each uses a unique identifier and disjoint message strings — never let one message be a substring of another):
   1. `test "github event missing author_trusted? is suppressed but still audit-broadcast"` — `:ok = DebugLog.subscribe()`; render `[trusted, untrusted]` for `"AR13-G1"` where trusted = `%{id: 10, topic: "ticket.AR13-G1.issue.commented", source: :github, author_trusted?: true, message: "alpha directive"}` and untrusted = same shape with `id: 11`, `message: "bravo directive"`, and NO `author_trusted?` key. Expect: rendered `=~ "alpha directive"`, `refute rendered =~ "bravo directive"`, and `assert_receive {:event_debug, %{kind: :read, id: 11}}, 2_000` — the suppressed event still reaches the audit trail (the DebugLog broadcast at `src/lib/aiur/agent_runner.ex:1504-1510` fires for ALL events before filtering).
   2. `test "github event with author_trusted?: false is suppressed"` — render one event with `author_trusted?: false`, `message: "charlie directive"`; `refute rendered =~ "charlie directive"`; `assert rendered =~ "<aiur:events>"` (the envelope still renders).
   3. `test "trusted github content is wrapped with an escaped author attribute"` — one event with `author_trusted?: true`, `author: ~s(evil"name)`, `message: "delta directive"`. Expect `assert rendered =~ ~s(<external-content source="github" author="evil&quot;name">delta directive</external-content>)` (`src/lib/aiur/agent_runner.ex:1655-1685`).
   4. `test "non-github events pass through unfiltered and unwrapped"` — one event `%{id: 13, topic: "ticket.AR13-G4.agent.progress", message: "echo directive"}` (no `:source`, no trust flag). Expect `assert rendered =~ "echo directive"` and `refute rendered =~ "<external-content"`.
   5. `test "block/unblock within the debounce window collapses to the latest event"` — `t0 = DateTime.utc_now()`; events `%{id: 1, topic: "ticket.77.agent.blocked", message: "blocked msg", emitted_at: t0}` and `%{id: 2, topic: "ticket.77.agent.unblocked", message: "unblocked msg", emitted_at: DateTime.add(t0, 3, :second)}` (default window is 10s — `src/lib/aiur/agent_runner.ex:1624-1629`, schema default `src/lib/aiur/config/schema.ex:138`). Expect `assert rendered =~ "[id=2]"` and `refute rendered =~ "[id=1]"`.
   6. `test "block-state events without timestamps always collapse to the latest"` — same two topics/ids, NO `emitted_at` keys. Expect only `[id=2]` renders (`src/lib/aiur/agent_runner.ex:1609-1622` falls back to always-collapse).
   7. `test "block-state events outside the window both survive, ordered by id"` — same two topics/ids with `emitted_at` 30 seconds apart. Expect both `[id=1]` and `[id=2]` render, and `Enum.find_index(lines, &(&1 =~ "[id=1]")) < Enum.find_index(lines, &(&1 =~ "[id=2]"))` where `lines = String.split(rendered, "\n")` (`Enum.sort_by(..., :id)` at `src/lib/aiur/agent_runner.ex:1567`).
   8. `test "block-state events for different tickets do not collapse together"` — `%{id: 1, topic: "ticket.77.agent.blocked", message: "seventy-seven"}` and `%{id: 2, topic: "ticket.88.agent.blocked", message: "eighty-eight"}`, no timestamps. Expect both render (group key is the ticket id — `src/lib/aiur/agent_runner.ex:1570-1578`).

5. `describe "session-resume handle lifecycle (#610 class: terminal states clear the handle)"` — pins `Aiur.SessionHandle` (`src/lib/aiur/session_handle.ex`) and the runner's resume gates (`src/lib/aiur/agent_runner.ex:827-959`). Every disk-touching test passes `dir: tmp_dir` (from setup) and an explicit `hostname:`; never touch the real state dir. Eight tests:
   1. `test "save/load round-trip on the same backend and host"` — `SessionHandle.save("AR13-R1", %{backend: "codex", thread_id: "t1"}, dir: tmp_dir, hostname: "h1")`; expect `assert {:ok, %{backend: "codex", thread_id: "t1", hostname: "h1"}} = SessionHandle.load("AR13-R1", "codex", dir: tmp_dir, hostname: "h1")`.
   2. `test "load gates: backend mismatch, host mismatch, forward schema, corrupt file all cold-start"` — after a save as in R1 (identifier `"AR13-R2"`): `assert :none = SessionHandle.load("AR13-R2", "claude", dir: tmp_dir, hostname: "h1")`; `assert :none = SessionHandle.load("AR13-R2", "codex", dir: tmp_dir, hostname: "h2")`; then `File.write!(SessionHandle.path_for("AR13-R2", dir: tmp_dir), Jason.encode!(%{"schema_version" => 2, "backend" => "codex", "thread_id" => "t1", "hostname" => "h1"}))` and expect `:none`; then `File.write!(SessionHandle.path_for("AR13-R2", dir: tmp_dir), "not json")` and expect `:none` (no raise — `src/lib/aiur/session_handle.ex:69-118`).
   3. `test "clear removes the handle and is idempotent"` — save for `"AR13-R3"`; `assert :ok = SessionHandle.clear("AR13-R3", dir: tmp_dir)`; `assert :none = SessionHandle.load("AR13-R3", "codex", dir: tmp_dir, hostname: "h1")`; `assert :ok = SessionHandle.clear("AR13-R3", dir: tmp_dir)` (second clear). This is the seam the orchestrator's terminal cleanup calls (`src/lib/aiur/orchestrator.ex:4169-4177`); the orchestrator-side wiring is characterized by T-007, not here.
   4. `test "resume_thread_id gates on backend resumability and local worker"` — `assert "t9" = AgentRunner.resume_thread_id("codex", nil, {:ok, %{thread_id: "t9"}})`; `assert nil == AgentRunner.resume_thread_id("claude", nil, {:ok, %{thread_id: "t9"}})`; `assert nil == AgentRunner.resume_thread_id("codex", "remote-host", {:ok, %{thread_id: "t9"}})`; `assert nil == AgentRunner.resume_thread_id("codex", nil, :none)` (`src/lib/aiur/agent_runner.ex:846-851`).
   5. `test "resumable?/1 per backend"` — `assert CodingAgent.resumable?("codex")`; `assert CodingAgent.resumable?("claude-repl")`; `refute CodingAgent.resumable?("claude")`; `refute CodingAgent.resumable?("no-such-backend")` (degrades to false, never raises — `src/lib/aiur/coding_agent.ex:391-397`).
   6. `test "turn handle persists only on thread-id drift"` — `assert {:ok, %{backend: "claude-repl", thread_id: "s2"}} = AgentRunner.turn_handle_attrs(%{backend: "claude-repl", thread_id: "s1"}, %{thread_id: "s2"})`; `assert :skip = AgentRunner.turn_handle_attrs(%{backend: "codex", thread_id: "s1"}, %{thread_id: "s1"})`; `assert :skip = AgentRunner.turn_handle_attrs(%{backend: "claude-repl", thread_id: "s1"}, %{})` (`src/lib/aiur/agent_runner.ex:906-914`).
   7. `test "session_handle_to_save skips non-resumable, remote, and id-less sessions"` — `assert {:ok, %{backend: "codex", thread_id: "t1"}} = AgentRunner.session_handle_to_save(%{backend: "codex", thread_id: "t1"}, nil)`; `assert :skip = AgentRunner.session_handle_to_save(%{backend: "claude", thread_id: "t1"}, nil)`; `assert :skip = AgentRunner.session_handle_to_save(%{backend: "codex", thread_id: "t1"}, "remote-host")`; `assert :skip = AgentRunner.session_handle_to_save(%{backend: "codex"}, nil)` (`src/lib/aiur/agent_runner.ex:949-959`).
   8. `test "persist_handle_best_effort swallows write failures"` — `blocked = Path.join(tmp_dir, "not-a-dir")`; `File.write!(blocked, "")` (a FILE where a dir is expected); expect `assert :ok = AgentRunner.persist_handle_best_effort("AR13-R8", %{backend: "codex", thread_id: "t1"}, dir: blocked)` — no raise (`src/lib/aiur/agent_runner.ex:934-941`: a sidecar write must never kill a live run).

6. `describe "sync-marker fan-out census"` — one test on top of the existing pins in `src/test/aiur/agent_runner_test.exs:20-86` (which stay untouched):
   1. `test "exactly one marker post per attached writer"` — build `writers = for n <- 1..5, do: %{session_id: "ses_#{n}", base_url: "http://w#{n}"}`; `parent = self()`; `post = fn base, sid, payload -> send(parent, {:posted, base, sid, payload}); {:ok, %{}} end`; `assert :ok = AgentRunner.post_aiur_turn_markers("AR13-MK", "tCENSUS", writers, post)`; then collect `sids = for _ <- 1..5 do; assert_receive {:posted, _base, sid, _payload}, 2_000; sid; end`; `assert Enum.sort(sids) == ["ses_1", "ses_2", "ses_3", "ses_4", "ses_5"]`; `refute_receive {:posted, _, _, _}, 500` — exactly 5 posts, one per writer, no duplicates (`src/lib/aiur/agent_runner.ex:1720-1733`).

7. Run the Agent gate (below), then a seed-stability loop from `src/`:
   ```
   for i in $(seq 1 10); do mix test test/aiur/regression/agent_runner_lifecycle_test.exs --seed $RANDOM || exit 1; done
   ```
   All 10 runs must pass (23 tests, 0 failures each). Paste the final run's summary line into the PR description.

`src/test/support/snapshot_support.exs` is available to regression tests but is NOT used by this ticket (it serves renderer snapshots, T-012).

## Files

- Create: src/test/aiur/regression/agent_runner_lifecycle_test.exs
- Modify: none
- Test: src/test/aiur/regression/agent_runner_lifecycle_test.exs

## Out of scope

- `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/session_handle.ex`, `src/lib/aiur/orchestrator.ex`, `src/lib/aiur/coding_agent.ex`, `src/lib/aiur/events/debug_log.ex` — zero production changes; this is a test-only ticket.
- `src/test/aiur/agent_runner_test.exs` — the existing unit pins (including the `post_aiur_turn_markers/4` describe block) stay byte-for-byte untouched; deliberate overlap between that file and this one is intended (this file lives on the guarded regression path, that one does not).
- All 19 existing files under `src/test/aiur/regression/` — read-only.
- Orchestrator-side characterization (pause/resume control messages to a live runner Task, wake decisions, terminal-transition wiring of `SessionHandle.clear`) — that is T-007.
- The private receive loops (`wait_for_operator_message/5`, `drain_operator_messages/5`) — not directly drivable without production changes; their queue-accounting contract is pinned here at the orchestrator seam, and their process-identity semantics are covered by `src/test/aiur/core_test.exs` end-to-end scenarios. Do not add test-only exports to reach them.
- Turn prompts, bootstrap digest replay, comment context, checkpoint handlers, tool executor, alerts — pinned elsewhere (`src/test/aiur/agent_runner_test.exs`, `src/test/aiur/issue_log_event_history_test.exs`) and decomposed by T-034..T-036.

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md`:

- FI-ORC-053 — event digest enqueue + `deliver_now?` wake decision (Scope 3.1).
- FI-ORC-067 — session resume across aiur restarts (#378/#613) (Scope 5.1-5.8).
- FI-ORC-071 — aiur turn markers / fire-and-forget fan-out (Scope 6.1).
- FI-ORC-072 — turn result → queue item settlement, incl. the `:turn_start_failed` restore (Scope 3.2-3.6).
- FI-ORC-073 — paused wait loop: explicit wake only, `deliver_now?` gating (Scope 3.1).
- FI-ORC-074 — events digest rendering: trust filter, debounce, external-content wrap (Scope 4.1-4.8).
- FI-ORC-075 — safe-checkpoint delivery restore-vs-fail accounting seam (Scope 3.6).
- FI-ORC-003 / FI-ORC-036 — terminal-state SessionHandle clearing (Scope 5.3 pins the `SessionHandle.clear` seam; the orchestrator wiring itself is T-007).

From `docs/refactor/feature-inventory/cdx.md`:

- FI-CDX-013 — resumability flags per backend + local-worker gate (Scope 5.4-5.5).
- FI-CDX-015 — session-handle sidecar artifact (Scope 5.1, 5.8).
- FI-CDX-016 — session-handle load safety gate (Scope 5.2).

## Characterization-tests

- **Created by this ticket:** `src/test/aiur/regression/agent_runner_lifecycle_test.exs` (23 tests, 4 describe blocks).
- Existing pins that stay green and untouched: `src/test/aiur/agent_runner_test.exs` (markers, session start/fallback, resume gates, wake claiming, digest trust rendering, prompt choice), `src/test/aiur/core_test.exs` (`AgentRunner.run/3` end-to-end scenarios), `src/test/aiur/regression/event_flow_e2e_test.exs` (digest render through the pipeline), `src/test/aiur/opencode/active_turns_test.exs` (marker/bridge race semantics).

## Acceptance criteria

- `test -f src/test/aiur/regression/agent_runner_lifecycle_test.exs` succeeds; `grep -c "defmodule Aiur.Regression.AgentRunnerLifecycleTest" src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `1`.
- `grep -c '    test "' src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `23`; `grep -c '  describe "' src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `4`.
- `grep -c "Process.sleep" src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `0`.
- `grep -cE "assert_receive.*, ([0-9]{1,3}|1_?[0-9]{3})$" src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `0` (every `assert_receive` window is >= `2_000`).
- `grep -c "async: false" src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `1`.
- `grep -c "dir: " src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints a value >= `8` (all SessionHandle disk I/O is tmp-dir-injected) and `grep -c "AIUR_RELEASE_NODE" src/test/aiur/regression/agent_runner_lifecycle_test.exs` prints `0`.
- `git diff --name-only origin/v2...HEAD` lists exactly one file: `src/test/aiur/regression/agent_runner_lifecycle_test.exs`.
- Size norms: no production files created (the <=200-line/<=20-logic-line module norms apply to none); the one new test file is <= 800 lines and every private test helper in it is <= 20 logic lines.
- `mix test test/aiur/regression/agent_runner_lifecycle_test.exs` (from `src/`): 23 tests, 0 failures; the 10-iteration seed loop in Scope step 7 passes on every run.
- `mix test test/aiur/agent_runner_test.exs` (from `src/`): green, file unmodified.

## Verification

### Agent gate (run all, from src/)

```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- **This PR touches the guarded regression path by design** (it adds a new file under `src/test/aiur/regression/`): apply the `regression-suite-change` override label to the PR before merging (T-005 tripwire mechanics; see `docs/refactor/regression-safety.md`).
- Confirm `git diff --name-only` for the PR shows exactly one added file and zero modified files; in particular `src/test/aiur/agent_runner_test.exs` and all 19 pre-existing regression files are untouched.
- Run the acceptance-criteria greps above verbatim; all must match.
- Run from `src/`: `mix test test/aiur/regression/agent_runner_lifecycle_test.exs --seed 0` and `--seed 1` — both 23 tests, 0 failures.
- Check: FI-ORC-073 — the test `"deliver_now? false is ignored and leaves the item claimable"` passes (the no-eager-claim invariant is now pinned on the guarded path).
- Check: FI-ORC-072 — the tests `"restore_delivered_queue_items returns the in-flight item to the queue"` and `"restore_queue_item_pending re-queues one item by id (completion-race requeue)"` pass (the #552 never-success-to-failure seam is pinned).
- Check: FI-ORC-074 — the test `"github event missing author_trusted? is suppressed but still audit-broadcast"` passes (default-untrusted CODEOWNERS gate + audit-trail split pinned).
- Check: FI-CDX-016 / FI-ORC-067 — the tests in the session-resume describe block pass with all disk I/O under the per-test tmp dir (no files created under the repo's real state dir during the run: `ls src/log/*.session.json 2>/dev/null` prints nothing new).
- Apply no other labels; close the issue via the PR's `Closes #<issue-number>` line.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
