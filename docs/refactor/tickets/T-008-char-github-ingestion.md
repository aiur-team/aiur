# T-008: Characterization: GitHub ingestion & wake/rework

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3` `model:claude`

## Problem / context

GitHub event ingestion and the comment→wake/rework pipeline is the repo's #1
regression hotspot: ~35 incidents and the longest fix-of-fix chains in the
project's history (PR #621→#623→#629→#630→#632 on comment wake; PR
#634→#642→#677→#682→#683 on digest/review-thread cutoffs; PR
#668→#672→#675→#684 on polling optimizations — see
`docs/refactor/research-history-hotspots.md`, hotspot row 1). Before the
Phase-2/3 refactors touch these seams (T-017 shared poller skeleton, T-024
orchestrator comment paths, T-028–T-030 github client), the current behavior
of `src/lib/aiur/events/github_comments_poller.ex`,
`src/lib/aiur/events/github_firehose.ex`,
`src/lib/aiur/events/ls_remote_ticker.ex`, and
`src/lib/aiur/events/publisher.ex` must be locked in as characterization
tests under the guarded `src/test/aiur/regression/` path.

This ticket writes ONE new test file and changes no lib code. The tests
document what the code does TODAY. If a test you wrote fails, your test is
wrong — fix the test, never the lib code.

## Scope (exact)

Create `src/test/aiur/regression/github_ingestion_test.exs`, module
`Aiur.Regression.GithubIngestionTest`. Write it exactly as specified below.

**Authoring constraints (mandatory, from the refactor test rules):**

1. Never assert exact counts on shared singletons. `Aiur.Events.Publisher`
   (its dedup ETS table) and `Aiur.Events.Exchange` are app-wide singletons
   that outlive tests. Make every dedup key unique per test by using a
   unique `repo` string (`"owner/repo-#{System.unique_integer([:positive])}"`)
   passed as the `:repo` opt, and unique numeric targets
   (`Integer.to_string(System.unique_integer([:positive]))`).
2. Every `assert_receive` window must be `>= 2000` ms. Use
   `refute_received` (mailbox check, zero wait) instead of `refute_receive`
   wherever a synchronization point (`:sys.get_state/1` or a completed
   function return) guarantees delivery already happened.
3. This file isolates `:log_file` to a tmp dir (it touches
   `src/lib/aiur/events`). Copy the exact pattern from
   `src/test/aiur/events/subscription_store_test.exs` lines 8–34 (save
   original `Application.get_env(:aiur, :log_file)`, put a tmp-dir path,
   restore-or-delete in `on_exit`, tolerant `File.rm_rf(tmp_dir)`).
4. No `Process.sleep` for synchronization. Synchronize on
   `:sys.get_state(pid)` (a GenServer call serializes behind an earlier
   `send(pid, :tick)`), `assert_receive`, or function returns.
5. Do not start, stop, or reconfigure the global `Publisher`, `Exchange`,
   or `IdGenerator` processes. Use them as-is via unique keys/topics.

**Step 1 — Module skeleton and setup.** Write:

```elixir
defmodule Aiur.Regression.GithubIngestionTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubFirehose, GithubKeys, LsRemoteTicker, Publisher}
  alias Aiur.GitHub.{CodeOwners, Connectivity}
```

`use Aiur.TestSupport` provides `write_workflow_file!/2` and
`restore_env/2` and runs `use ExUnit.Case` (async: false by default — keep
it that way; do not add `async: true`).

The `setup` block, in order:

1. The `:log_file` tmp-dir isolation from constraint 3 above.
2. `prev_token = System.get_env("GITHUB_TOKEN")` then
   `System.put_env("GITHUB_TOKEN", "test-gh-token")` (the injected-test token
   seam — `src/lib/aiur/github/client.ex:2410-2429`).
3. `write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "aiur")`
   — copy from `src/test/aiur/events/github_comments_poller_test.exs:12-16`.
4. `Publisher.set_tracked_fn(fn _ -> true end)`.
5. `on_exit` restores the token via `restore_env("GITHUB_TOKEN", prev_token)`,
   resets `Publisher.set_tracked_fn(fn _ -> true end)`, unsubscribes every
   `Exchange.bindings_for(self())` pattern, restores `:log_file`, and
   `File.rm_rf(tmp_dir)` — copy the combined pattern from
   `src/test/aiur/events/github_comments_poller_test.exs:20-27` plus the
   subscription-store `:log_file` teardown.

**Step 2 — Private helpers.** Copy these helper functions verbatim from
`src/test/aiur/events/github_comments_poller_test.exs` (bottom of the file):
`review_threads_response/1`, `empty_review_threads_response/0`,
`review_thread_comment/3`, and `ensure_codeowners!/1` (lines ~749–767).
Add two helpers of your own:

- `issue_comment(id, login, body, iso_ts)` returning
  `%{"id" => id, "body" => body, "user" => %{"login" => login}, "created_at" => iso_ts, "updated_at" => iso_ts}`.
- `start_ticker!(responses)` — starts an `Agent` holding the list
  `responses`; builds `ls_remote_fun = fn _remote, _refs -> Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [h]} end) end`
  (last response repeats); starts the ticker with
  `LsRemoteTicker.start_link(name: :"ticker_#{System.unique_integer([:positive])}", start_paused?: true, interval_ms: 60_000, repo: repo, ls_remote_fun: ls_remote_fun, publisher: fn topic, payload, opts -> send(test_pid, {:published, topic, payload, opts}); :ok end)`;
  registers `on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)`
  and `Agent.stop` likewise; returns `{pid, repo}`. Drive ticks with
  `send(pid, :tick)` immediately followed by `state = :sys.get_state(pid)`
  — never wait on wall-clock. Note `start_paused?: true` only skips the
  FIRST scheduled tick; each manually-sent `:tick` schedules a follow-up in
  `next_delay_ms` — that is why `interval_ms` is 60_000 and all assertions
  happen synchronously right after `:sys.get_state`.

**Step 3 — Test cases.** Write exactly these describe blocks and tests.
`request_fun` stubs follow the shapes already used in
`src/test/aiur/events/github_comments_poller_test.exs` (REST: match on
`String.contains?(url, ...)`, return `{:ok, %{status: 200, body: ...}}`;
GraphQL: `String.contains?(url, "/graphql")` →
`review_threads_response(...)`) and
`src/test/aiur/events/github_firehose_test.exs` (repo events: return
`{:ok, %{status: 200, headers: [{"ETag", ~s("e1")}], body: [event, ...]}}`).

`describe "comment dedup keys vs the 1h Publisher TTL"`:

- **T1 "second poll of the same issue comment id is deduped"** — unique
  `target`, unique `repo`; `request_fun` serves one `issue_comment(id, "alice", "hello", "2026-07-01T12:00:00Z")`
  for `"/issues/#{target}/comments?"` and `{:ok, %{status: 200, body: []}}`
  for `"/pulls?"`. `Exchange.subscribe("ticket.#{target}.issue.commented")`.
  Call `GithubCommentsPoller.poll([target], since: "2026-07-01T00:00:00Z", repo: repo, request_fun: request_fun)`
  twice with identical args. Expected: first returns `{:ok, %{count: 1}}`
  (pattern-match, ignore other keys); second returns `{:ok, %{count: 0}}`
  (Publisher returned `:deduped` on the same
  `GithubKeys.comment_dedup_key(repo, "issue_comment", parent, id)` triple
  inside the 1h TTL); `assert_receive {:event, %{topic: topic}}, 2000` with
  `topic == "ticket.#{target}.issue.commented"`, then `refute_received {:event, _}`.
- **T2 "review-thread wake dedups on the stable thread node id"** — unique
  `target`/`repo`; pass `open_pull_requests_by_target: %{target => %{"number" => 77}}`
  (skips the `/pulls?` fetch — `github_comments_poller.ex:179-191`);
  `request_fun` serves `{:ok, %{status: 200, body: []}}` for
  `"/issues/"`-containing URLs and
  `review_threads_response([...one thread with review_thread_comment(2102, "alice", "unresolved")...])`
  for `"/graphql"`. Poll twice. Expected: first `count: 1`, second
  `count: 0` — the dedup key is
  `GithubKeys.review_thread_dedup_key(repo, 77, thread_id)` (thread node
  id, NOT the comment id — `github_comments_poller.ex:289-292`).
- **T3 "malformed dedup_key never blocks publishing"** — call
  `Publisher.publish("ticket.#{target}.issue.commented", %{n: 1}, issue_number: target, dedup_key: {:bad, :key})`
  twice. Expected: BOTH calls return `{:ok, _, _}` (partial keys drop the
  dedup signal, never crash or dedup — `publisher.ex:209-211`).
- **T4 "dedup TTL is pinned at 1 hour"** — assert
  `:persistent_term.get({Aiur.Events.Publisher, :ttl_ms}) == 3_600_000`
  (no default argument — the key MUST exist because the app supervision
  tree starts the Publisher singleton before tests run).
  This pins the deliberate 1h window (`publisher.ex:45-51`); shrinking it
  re-introduces duplicate `pr.opened`/`issue.commented` storms
  (FI-EVT-011).

`describe "boot cutoff never hides pre-boot unresolved review threads (#642 class)"`:

- **T5 "pre-boot unresolved review thread still publishes a wake"** —
  `boot_time = 1_782_302_400`; thread comment `created_at`/`updated_at`
  `"2020-01-01T00:00:00Z"` (years pre-boot). Unique `target`/`repo`,
  `open_pull_requests_by_target: %{target => %{"number" => 88}}`,
  `request_fun`: empty body for `"/issues/"`, one-thread
  `review_threads_response` for `"/graphql"`.
  `Exchange.subscribe("ticket.#{target}.pr.review_comment")`. Call
  `GithubCommentsPoller.poll([target], boot_time: boot_time, repo: repo, request_fun: request_fun, open_pull_requests_by_target: ...)`.
  Expected: `{:ok, %{count: 1}}` and
  `assert_receive {:event, %{topic: "ticket." <> _}}, 2000` — the
  review-thread endpoint takes NO since cursor
  (`github_comments_poller.ex:234-249` passes no `:since`), so the boot
  cutoff cannot suppress it.
- **T6 "issue-comment polling defaults since to boot cutoff (boot − 60s)"**
  — `boot_time = 1_782_302_400`; `request_fun` captures every URL via
  `send(parent, {:url, url})`, returns empty bodies for both `"/issues/"`
  and `"/pulls?"` matches. Poll with `boot_time:` and NO `:since`.
  Expected: the captured issue-comments URL contains
  `"since=" <> URI.encode_www_form(GithubKeys.boot_cutoff_iso8601(boot_time: boot_time))`
  (the client builds the query with `URI.encode_query/1`;
  `github_keys.ex:78-91` subtracts the 60s buffer).
- **T7 "firehose drops pre-boot events and passes post-boot events"** —
  `boot_time = 1_782_302_400`. Build two `PushEvent` maps on
  `"refs/heads/main"` (copy the event shape from
  `src/test/aiur/events/github_firehose_test.exs:36-56`): one with
  `"created_at" => "2020-01-01T00:00:00Z"` (pre-boot), one with
  `"created_at" => DateTime.to_iso8601(DateTime.from_unix!(boot_time + 300))`
  (post-boot). `Exchange.subscribe("system.main.branch.push")`. Call
  `GithubFirehose.poll(request_fun: stub, boot_time: boot_time, repo: repo)`
  with a stub returning both events. Expected: `{:ok, %{count: 1}}` — only
  the post-boot event publishes (`github_firehose.ex:149-163`,
  `GithubKeys.pre_boot_event?/2`); `assert_receive {:event, %{topic: "system.main.branch.push"}}, 2000`
  then `refute_received {:event, _}`.

`describe "Agent Workpad comment filtering"`:

- **T8 "issue comments starting '## Agent Workpad' are not published"** —
  `request_fun` serves `[issue_comment(id, "alice", "  ## Agent Workpad\nstate", ts)]`
  (note leading whitespace — `CommentFilter.agent_workpad?/1` trims leading
  whitespace, `src/lib/aiur/events/comment_filter.ex:5-10`) for
  `"/issues/"`, empty for `"/pulls?"`. Expected: `{:ok, %{count: 0}}`.
- **T9 "PR-conversation workpad comments filtered; sibling real comment
  published"** — `open_pull_requests_by_target: %{target => %{"number" => 91}}`;
  `request_fun` serves, for `"/issues/91/comments?"`, a list of two
  comments: one workpad body, one `"please fix the retry loop"`; empty
  `review_threads_response([])` for `"/graphql"`; empty for
  `"/issues/#{target}/comments?"` (match the target URL FIRST, then the
  PR-number URL — both contain `"/issues/"`). Expected:
  `{:ok, %{count: 1}}` (`github_comments_poller.ex:216-231` applies
  `CommentFilter.agent_workpad?/1` to the PR conversation path too).

`describe "per-target poll isolation and since cursor"`:

- **T10 "one erroring target does not stall the others"** — two unique
  targets `a`, `b`. `request_fun` returns
  `{:error, %{reason: :econnrefused}}` for `"/issues/#{a}/comments?"`, one
  comment for `"/issues/#{b}/comments?"`, empty for `"/pulls?"`. Poll
  `[a, b]` with `since: "2026-07-01T00:00:00Z"`. Expected:
  `{:ok, %{count: 1, since: since_map, errors: errors}}` where
  `since_map[a] == "2026-07-01T00:00:00Z"` (unchanged — errors freeze the
  cursor, `github_comments_poller.ex:128-141`), `since_map[b] != "2026-07-01T00:00:00Z"`,
  and `[{^a, {:issue_comments, _}}] = errors`.
- **T11 "a hung target is killed at the task timeout; siblings publish"** —
  two targets `a`, `b`. `request_fun` for `"/issues/#{a}/comments?"` blocks
  forever with `receive do: (:never -> :ok)`; serves one comment for `b`;
  empty `"/pulls?"`. Poll with `timeout: 500`. Expected:
  `{:ok, %{count: 1, since: since_map, errors: [{^a, {:target, {:exit, :timeout}}}]}}`
  and `since_map[a]` equals the input since (per-target
  `async_stream` with `on_timeout: :kill_task`,
  `github_comments_poller.ex:69-97`; exit shape from
  `github_comments_poller.ex:43-51`).
- **T12 "since advances to newest updated_at minus 1s on a clean poll"** —
  one comment with `"updated_at" => "2026-07-01T12:00:00Z"`. Expected:
  `since_map[target] == "2026-07-01T11:59:59Z"` (the −1s overlap,
  `github_comments_poller.ex:354-360`).

`describe "connectivity backoff wiring (#655)"`:

Each test uses `start_ticker!/1` from Step 2. DNS failure response:
`{:error, {:git_ls_remote_failed, 128, "fatal: Could not resolve host: github.com"}}`;
auth failure response:
`{:error, {:git_ls_remote_failed, 128, "fatal: Authentication failed"}}`;
success response: `{:ok, %{}}` or a refs map.

- **T13 "dns failures actually back off exponentially"** — responses: two
  dns failures. Tick once → `:sys.get_state(pid).next_delay_ms == 1_000`;
  tick again → `next_delay_ms == 2_000` (`Connectivity.backoff_ms/3` base
  1s doubling, wired through `ls_remote_ticker.ex:147-168` — the #655
  class: the backoff must be exercised, not merely implemented).
- **T14 "auth failure escalates to the max backoff"** — responses: one auth
  failure. Tick once → `next_delay_ms == Connectivity.max_backoff_ms()`
  (`:escalate` → 60_000, `ls_remote_ticker.ex:178`).
- **T15 "success resets the delay and clears the streak"** — responses:
  `[dns_failure, {:ok, %{}}]`. Tick, assert `next_delay_ms == 1_000`; tick,
  assert `next_delay_ms == 60_000` (the configured `interval_ms`) and
  `:sys.get_state(pid).connectivity == %{}`
  (`ls_remote_ticker.ex:137-143`).
- **T16 "sustained dns streak alerts exactly once at threshold 3"** —
  `Exchange.subscribe("system.github.connectivity_lost")` BEFORE starting
  the ticker; responses: dns failure only. Tick + `:sys.get_state` twice,
  then `refute_received {:event, %{topic: "system.github.connectivity_lost"}}`
  (no alert below threshold). Tick a 3rd time →
  `assert_receive {:event, %{topic: "system.github.connectivity_lost"}}, 2000`.
  Tick a 4th time + `:sys.get_state`, then
  `refute_received {:event, %{topic: "system.github.connectivity_lost"}}`
  (past-threshold stays silent until a success re-arms —
  `Connectivity.note_failure/3` fires only at `count == 3`; the alert
  reaches the Exchange because every `Alerts` emit publishes
  unconditionally, FI-EVT-068).

`describe "strict refs/heads/aiur/<digits> routing"`:

- **T17 "ref_to_topic classification table"** — pure assertions on
  `GithubKeys.ref_to_topic/1`:
  `"refs/heads/aiur/123"` → `{:ticket, "123", "ticket.123.branch.push"}`;
  `"refs/heads/aiur/99-pr"` → `nil`; `"refs/heads/aiur/99/sub"` → `nil`;
  `"refs/heads/aiur/abc"` → `nil`; `"refs/heads/main"` →
  `{:system, "system.main.branch.push"}`; `nil` → `nil`; `123` → `nil`
  (`github_keys.ex:20-33`).
- **T18 "ticker publishes only canonical ticket refs after bootstrap"** —
  `start_ticker!` with responses:
  1. `{:ok, %{"refs/heads/aiur/77" => "sha1", "refs/heads/aiur/77-pr" => "shaX", "refs/heads/main" => "m1"}}`
  2. `{:ok, %{"refs/heads/aiur/77" => "sha2", "refs/heads/aiur/77-pr" => "shaY", "refs/heads/aiur/88" => "new1", "refs/heads/main" => "m1"}}`
  Tick 1 + `:sys.get_state`, then `refute_received {:published, _, _, _}`
  (bootstrap records without publishing). Tick 2 + `:sys.get_state`, then:
  `assert_receive {:published, "ticket.77.branch.push", payload_77, opts_77}, 2000`
  with `payload_77 == %{ref: "refs/heads/aiur/77", sha: "sha2", actor: nil, commits: [], repo: repo}`
  and `opts_77[:issue_number] == "77"`;
  `assert_receive {:published, "ticket.88.branch.push", _, _}, 2000` (a
  brand-new ref post-bootstrap IS a push); then
  `refute_received {:published, _, _, _}` — the changed non-canonical
  `aiur/77-pr` ref and the unchanged `main` ref publish nothing
  (`ls_remote_ticker.ex:185-243`, `github_keys.ex:20-33`).
- **T19 "error ticks never fake a bootstrap baseline"** — responses:
  `[dns_failure, {:ok, %{"refs/heads/aiur/55" => "s1"}}, {:ok, %{"refs/heads/aiur/55" => "s2"}}]`.
  Tick 1 + `:sys.get_state` → `bootstrapped? == false`; tick 2 +
  `:sys.get_state` → `bootstrapped? == true` and
  `refute_received {:published, _, _, _}` (first SUCCESS is the baseline,
  no phantom-push storm); tick 3 →
  `assert_receive {:published, "ticket.55.branch.push", %{sha: "s2"}, _}, 2000`
  (`ls_remote_ticker.ex:101-110,185-199`).

`describe "trusted-account gating (CODEOWNERS authority)"`:

- **T20 "comments stamp author_trusted?: false when no allowlist matches"**
  — do NOT call `ensure_codeowners!/1`. Subscribe to the target's
  `issue.commented` topic; poll one comment authored by `"stranger"`.
  Expected: `assert_receive {:event, event}, 2000` with
  `event.author_trusted? == false` (conservative default —
  `src/lib/aiur/events/sanitizer.ex:102-120`; the poller stamps trust
  before publish, `github_comments_poller.ex:298-312`).
- **T21 "comments from a CODEOWNERS-listed author stamp author_trusted?: true"**
  — call `ensure_codeowners!("* @its-everdred\n")` (the copied helper —
  it either starts `CodeOwners` on a tmp CODEOWNERS file or force-sets the
  running singleton's allowlist to `["its-everdred"]`); in `on_exit`, if
  `owned?` stop the pid and delete the tmp file, else restore
  `previous_allowlist` via `:sys.replace_state/2` — copy the cleanup the
  existing poller tests pair with this helper. Poll one comment authored by
  `"its-everdred"`. Expected: received event has
  `author_trusted? == true`.
- **T22 "comment publishes bypass the contamination filter (deactivated-ticket wake)"**
  — `Publisher.set_tracked_fn(fn _ -> false end)` (reset in `on_exit`
  already), subscribe, poll one comment. Expected: `{:ok, %{count: 1}}` and
  the event is received — the poller passes `bypass_contamination: true`
  (`github_comments_poller.ex:306-311`) so an inbound human comment can
  reactivate a ticket that is absent from the tracked set (FI-EVT-010).

**Step 4 — Verify.** Run the Agent gate (below) from `src/`. Then run the
new file alone 3 times to shake out ordering/timing flakes:
`mix test test/aiur/regression/github_ingestion_test.exs --seed 0 && mix test test/aiur/regression/github_ingestion_test.exs --seed 1 && mix test test/aiur/regression/github_ingestion_test.exs` — all green.

## Files

- Create: `src/test/aiur/regression/github_ingestion_test.exs`
- Modify: (none)
- Test: `src/test/aiur/regression/github_ingestion_test.exs`

## Out of scope

- Any change to `src/lib/**` — this ticket is test-only. If current behavior
  looks wrong, characterize it anyway and comment the observation on the
  issue.
- The other 19 files under `src/test/aiur/regression/` — do not edit or
  reformat them.
- `src/lib/aiur/github/client.ex` internals (error taxonomy, review-thread
  reply/resolve) — T-028–T-030 territory; here the client is exercised only
  through injected `request_fun` stubs.
- Orchestrator wake/rework state transitions (`src/lib/aiur/orchestrator.ex`)
  — covered by T-007; this ticket stops at the Publisher/Exchange boundary.
- `Aiur.Events.PrCommandScanner` (/aiur command scan) and
  `Aiur.GitHub.CodeOwners` refresh internals — only the stamped
  `author_trusted?` output is asserted here.
- Existing unit tests under `src/test/aiur/events/` — leave untouched.

## Inventory-IDs

- From `docs/refactor/feature-inventory/evt.md`: FI-EVT-010, FI-EVT-011,
  FI-EVT-012, FI-EVT-030, FI-EVT-031, FI-EVT-032, FI-EVT-033, FI-EVT-035,
  FI-EVT-036, FI-EVT-041, FI-EVT-042, FI-EVT-068 (exercised as the alert
  assertion channel in T16)
- From `docs/refactor/feature-inventory/gh.md`: FI-GH-038, FI-GH-039,
  FI-GH-043, FI-GH-046, FI-GH-047, FI-GH-048, FI-GH-049, FI-GH-051,
  FI-GH-052, FI-GH-053, FI-GH-055, FI-GH-057, FI-GH-058, FI-GH-059,
  FI-GH-060, FI-GH-061

## Characterization-tests

This ticket CREATES `src/test/aiur/regression/github_ingestion_test.exs`
(22 tests, T1–T22 above). It complements, and must not duplicate or modify,
the existing `src/test/aiur/regression/event_flow_e2e_test.exs` (publish →
store → enqueue wiring) and the unit suites
`src/test/aiur/events/github_comments_poller_test.exs`,
`github_firehose_test.exs`, `ls_remote_ticker_test.exs`,
`github_keys_test.exs`, `publisher_test.exs`.

## Acceptance criteria

- `src/test/aiur/regression/github_ingestion_test.exs` exists; module named
  `Aiur.Regression.GithubIngestionTest`; contains exactly 7 `describe`
  blocks and 22 `test` blocks as specified in Scope.
- `git diff --name-only $(git merge-base HEAD v2)..HEAD` outputs exactly one
  line: `src/test/aiur/regression/github_ingestion_test.exs` (no lib file,
  no other test file, changed).
- `grep -c "Process.sleep" src/test/aiur/regression/github_ingestion_test.exs`
  → 0.
- Every `assert_receive` in the file uses a timeout `>= 2000`
  (`grep -n "assert_receive" src/test/aiur/regression/github_ingestion_test.exs`
  shows `, 2000` on every match).
- `grep -n "log_file" src/test/aiur/regression/github_ingestion_test.exs`
  shows the put/restore pair (`:log_file` isolated to a tmp dir).
- `grep -n "async: true" src/test/aiur/regression/github_ingestion_test.exs`
  → no matches.
- Size norms: no lib files are created (the standard <=200-line lib-file
  norm has no subject here); the new test file is <= 800 lines; every
  private helper function in it is <= 20 logic lines.
- `mix test test/aiur/regression/github_ingestion_test.exs` (from `src/`)
  passes: 22 tests, 0 failures — on 3 consecutive runs with different
  seeds.
- The full Agent gate below is green.

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

- This PR touches the guarded regression path **by design** (it adds a file
  under `src/test/aiur/regression/`): apply the `regression-suite-change`
  override label to the PR before merging so the tripwire CI guard (T-005)
  passes.
- Check: PR diff contains exactly one added file,
  `src/test/aiur/regression/github_ingestion_test.exs`, and zero
  modifications elsewhere (`gh pr diff --name-only` → one line).
- Check: run `cd src && mix test test/aiur/regression/` twice back-to-back
  on the PR branch — all regression tests (existing 19 files + this one)
  pass both times.
- Check: `grep -c "describe \"" src/test/aiur/regression/github_ingestion_test.exs`
  → 7 and `grep -c "test \"" src/test/aiur/regression/github_ingestion_test.exs`
  → 22; spot-check that T5
  (pre-boot review thread), T16 (connectivity alert at streak 3), and T18
  (non-canonical ref ignored) assert the behaviors named in Scope.
- Check: confirm no test in the file starts/stops the global
  `Aiur.Events.Publisher` or `Aiur.Events.Exchange` processes
  (`grep -n "Publisher.start_link\|Exchange.start_link" ...` → no matches).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
