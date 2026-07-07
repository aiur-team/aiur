# T-024: orchestrator wave 3: comment/PR/push routing

**Phase:** 3
**Depends-on:** T-023
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/orchestrator.ex` is the giant orchestrator GenServer being
decomposed into ~26 modules per the binding name map in
`docs/refactor/research-arch/giant-orchestrator.md` §2. This is wave 3 of 6
(T-022..T-027). T-022 extracted `Aiur.Orchestrator.State`, `EventTopics`,
`DispatchPolicy`, `Slots`; T-023 extracted `Dispatcher`, `RetryEngine`,
`Reconciler`. This ticket extracts the five comment/PR/push routing modules:
`Aiur.Orchestrator.CommentWake`, `Aiur.Orchestrator.PrAnchored`,
`Aiur.Orchestrator.PushRouting`, `Aiur.Orchestrator.CommentPolling`, and
`Aiur.Orchestrator.CommandScan`.

**This is the #1 regression hotspot in the entire project.**
`docs/refactor/research-history-hotspots.md` ranks the comment→wake/rework
pipeline #1 (~35 incidents, the longest fix-of-fix chains in the repo's
history: PR #621→#623→#629→#630→#632 on comment wake, PR
#634→#642→#677→#682→#683 on digest/TOCTOU, PR #668→#672→#675→#684 on polling
optimizations). Every polling optimization and every trust/dedup filter here
has shipped a regression on first attempt. Because of that, this wave is a
**verbatim code MOVE, not a rewrite**: every function body is copied
byte-for-byte (comments included), public signatures and observable behavior
are unchanged, and all moved code keeps executing as plain function calls
inside the orchestrator GenServer process — no new processes, and no
GenServer calls back into the orchestrator (that deadlocks; the
`issue_tracked?/1` comment in the file documents exactly this hazard for the
publish path).

The characterization tests landed in Phase 1 (T-007 orchestrator lifecycle,
**T-008 GitHub ingestion & wake/rework**) pin this exact area and **must pass
UNMODIFIED**. If any test under `src/test/aiur/regression/` fails, your change
is wrong — never edit those tests (see Executor rules).

## Scope (exact)

Line numbers below are from the current `main` snapshot of
`src/lib/aiur/orchestrator.ex` (7,617 lines). T-022 and T-023 will have
shifted them. Locate every function by its exact name/arity (each name/arity
is unique in the file); use the line numbers only as orientation.

1. **Precondition check.** Verify these files exist (created by T-022/T-023):
   `src/lib/aiur/orchestrator/state.ex`,
   `src/lib/aiur/orchestrator/dispatch_policy.ex`,
   `src/lib/aiur/orchestrator/slots.ex`,
   `src/lib/aiur/orchestrator/dispatcher.ex`. If any is missing, STOP:
   comment the blocker on the issue and end your turn. Do not start extraction.

2. **Create `src/lib/aiur/orchestrator/comment_wake.ex`** defining
   `defmodule Aiur.Orchestrator.CommentWake`. Move these functions VERBATIM
   out of `src/lib/aiur/orchestrator.ex` (census group C5, ~lines 609–631 and
   998–1326):

   Public (`def` + `@spec`; called by code remaining in the facade):
   - `maybe_reactivate_on_comment/5` (was ~609; KEEP the default arg
     `attempt \\ 1` on the moved head)
   - `mark_pr_merged_issue_done/2` (was ~1265)

   Private (`defp`, internal to CommentWake):
   - `reactivate_if_deactivated/5` (was ~1024)
   - `maybe_transition_idle_issue_to_rework/5` (was ~1060)
   - `schedule_comment_rework_retry/6` (was ~1077; it contains the
     `Process.send_after(self(), {:retry_comment_rework, ...})` site — move it
     UNCHANGED, `self()` intact)
   - `seed_idle_comment_wake_event/3` (was ~1105)
   - `dispatch_reworked_comment_issue/2` (both clauses, was ~1092 and ~1111)
   - `fetch_comment_dispatch_issue/1` (was ~1123)
   - `fetch_comment_dispatch_issue_from_candidates/1` (was ~1136)
   - `find_issue_by_identifier_or_id/2` (was ~1146; sole caller is
     `fetch_comment_dispatch_issue_from_candidates/1`. In T-023 this stayed in
     the facade because T-023 did not touch it; it moves NOW with its caller.)
   - `transition_and_revalidate_comment_reactivation/5` (was ~1179)
   - `transition_comment_issue_to_rework/3` (was ~1206)
   - `trusted_comment_event?/1` (was ~1219)
   - `benign_review_pass_comment?/1` (was ~1223)
   - `comment_body/1` (was ~1229)
   - `review_pass_comment?/1` (both clauses, was ~1237 and ~1244)
   - `comment_rework_retry_delay_ms/1` (was ~1246)
   - `comment_rework_retry_base_delay_ms/0` (was ~1251)
   - `comment_rework_max_attempts/0` (was ~1258)
   - `rework_issue_key/2` (both clauses, was ~1285 and ~1291)
   - `revalidate_comment_reactivation/4` (was ~1290)
   - `fetch_current_reactivation_issue/1` (both clauses, was ~1308 and ~1322)
   - `reactivate_current_issue/5` (was ~1324)
   - `comment_reactivation_context/2` (was ~1335)
   - `event_digest_summary/1` (was ~1340)

   Move these module attributes from `orchestrator.ex` into `comment_wake.ex`
   (delete from `orchestrator.ex`; they have no other consumers):
   `@comment_rework_retry_delay_ms 2_000`, `@comment_rework_max_attempts 5`.

3. **Create `src/lib/aiur/orchestrator/pr_anchored.ex`** defining
   `defmodule Aiur.Orchestrator.PrAnchored`. Move these functions VERBATIM
   (census group C6, ~lines 632–776 and 1678–1764):

   Public (`def` + `@spec`; called by code remaining in the facade or by
   `CommentWake`):
   - `maybe_route_pr_anchored_or_legacy/5` (was ~632; called by
     `CommentWake.maybe_reactivate_on_comment/5`)
   - `maybe_stop_closed_pr_anchored_agents/2` (was ~1678; KEEP the default arg
     `opts \\ []`)

   Private (`defp`):
   - `pr_anchored_routing_enabled?/0` (was ~647)
   - `resolve_pr_anchored_unit/2` (was ~655)
   - `pr_number_from_identifier/1` (was ~666)
   - `fetch_open_pull_request_for_routing/2` (was ~673)
   - `pr_head_ref/1` (both clauses, was ~688 and ~689)
   - `aiur_owned_head_ref?/2` (was ~694)
   - `build_pr_anchored_issue/3` (was ~703; contains the `@pr_anchored_state`
     use — see attribute move below)
   - `pr_anchored_running_key/1` (was ~719)
   - `pr_field/2` (was ~721)
   - `dispatch_pr_anchored_unit/4` (was ~737)
   - `pr_anchored_dispatch_fun/1` (was ~760)
   - `pr_anchored_running_entries/1` (was ~1839)
   - `pr_anchored_running_entry?/1` (both clauses, was ~1845 and ~1846;
     contains the `@pr_anchored_state` use)
   - `stop_closed_pr_anchored_entries/3` (was ~1848)
   - `pr_open_state_fetcher/1` (was ~1881)
   - `cleanup_pr_anchored_workspace/2` (both clauses, was ~1893 and ~1904)

   Move the module attribute `@pr_anchored_state "pr-watch"` from
   `orchestrator.ex` into `pr_anchored.ex` (delete from `orchestrator.ex`; its
   only two consumers — `build_pr_anchored_issue/3` and
   `pr_anchored_running_entry?/1` — both move here, so no re-export is needed).

4. **Create `src/lib/aiur/orchestrator/push_routing.ex`** defining
   `defmodule Aiur.Orchestrator.PushRouting`. Move these functions VERBATIM
   (census group C7, ~lines 777–997 and 3013–3075):

   Public (`def` + `@spec`; called by facade `handle_info`/`handle_cast`
   clauses, the poll cycle, and `*_for_test` seams):
   - `maybe_pause_on_request/2` (was ~777)
   - `maybe_notify_agents_on_default_branch_push/3` (both clauses, was ~806)
   - `maybe_mark_sleeping/2` (was ~853)
   - `maybe_resume_blockees_on_push/3` (was ~877)
   - `reconcile_pending_auto_resumes/1` (was ~3013). NOTE: T-023 already made
     this an `@doc false def` in the facade because `Reconciler` calls it as
     `Orchestrator.reconcile_pending_auto_resumes/1`. Moving it here means the
     facade must keep a delegating `@doc false def` wrapper (see step 7) so
     that `Reconciler` keeps compiling unchanged — do NOT edit `reconciler.ex`.

   Private (`defp`):
   - `default_branch_name/0` (was ~825)
   - `maybe_resume_for_topic/4` (was ~883)
   - `attempt_auto_resume/5` (was ~918)
   - `stamp_pending_auto_resume/4` (was ~943)
   - `subscribed_to_topic?/2` (was ~966)
   - `maybe_drain_pending_auto_resume/3` (was ~3025; contains the per-tick
     capacity-deferred drain — move UNCHANGED)
   - `clear_pending_auto_resume/2` (was ~3056)

5. **Create `src/lib/aiur/orchestrator/comment_polling.ex`** defining
   `defmodule Aiur.Orchestrator.CommentPolling`. Move these functions VERBATIM
   (census group C8, ~lines 1327–1432 and 1885–2183):

   Public (`def` + `@spec`; called by the facade poll cycle and `*_for_test`
   seams):
   - `poll_github_firehose/2` (was ~1327; KEEP the default arg `opts \\ []`)
   - `poll_github_comments/2` (was ~1352; KEEP the default arg `opts \\ []`)

   Private (`defp`): every other `defp` in the two ranges. Exact list:
   `do_poll_github_comments/2`, `poll_github_comment_targets/5` (both
   clauses), `comments_poll_classification/1` (both clauses),
   `merge_comment_cursors/2` (both clauses), `all_comment_targets_failed?/2`
   (both clauses), `github_comment_poll_targets/2`,
   `watch_comment_poll_targets/2`, `watch_pull_request_fetcher/1`,
   `build_watch_targets/2`, `watch_comment_target_for_pull_request/1` (both
   clauses), `pull_request_open?/1` (all clauses), `dedupe_watch_targets/1`,
   `watch_comment_target_limit/1`, `running_comment_poll_targets/1`,
   `human_review_comment_poll_targets/2`, `comment_target_for_issue/1` (all
   clauses), `human_review_comment_target_for_issue/1`,
   `with_human_review_pr_updated_at/2`, `human_review_pr_fetcher/1`,
   `dedupe_human_review_targets/1`, `unchanged_human_review_comment_target?/2`
   (both clauses), `human_review_comment_target_sort_key/2`,
   `comment_cursor_sort_key/2` (all clauses), `human_review_pr_probe_priority/3`
   (both clauses), `human_review_target_known_at_issue_updated_at?/2`,
   `human_review_comment_target_limit/1`, `put_open_pull_requests_by_target/2`,
   `issue_updated_at_key/1` (all clauses),
   `human_review_target_updated_at_key/2` (both clauses),
   `remember_polled_human_review_targets/3`, `normalize_comment_targets/1`.

   Move these module attributes from `orchestrator.ex` into
   `comment_polling.ex` (delete from `orchestrator.ex`; their only consumers —
   `watch_comment_target_limit/1` and `human_review_comment_target_limit/1` —
   move here): `@watch_comment_targets_per_poll 25`,
   `@human_review_comment_targets_per_poll 25`.

6. **Create `src/lib/aiur/orchestrator/command_scan.ex`** defining
   `defmodule Aiur.Orchestrator.CommandScan`. Move these functions VERBATIM
   (census group C10, ~lines 1533–1677 and 1766–1883):

   Public (`def` + `@spec`; called by the facade poll cycle and `*_for_test`
   seam):
   - `scan_pr_commands/2` (was ~1533; KEEP the default arg `opts \\ []`)

   Private (`defp`): every other `defp` in the two ranges. Exact list:
   `do_scan_pr_commands/2`, `command_scan_review_comments/1`,
   `command_scan_issue_comments/1`, `command_scan_annotate/1`,
   `publish_command_hits/3`, `group_command_hits_by_pr/1`,
   `cap_command_pr_hits/2`, `publish_command_reactivation/3`,
   `command_scan_comment_author/1`, `command_scan_comment_pr_number/1`,
   `derive_command_scan_pr_number/1` (all clauses),
   `command_scan_pr_html_url?/1` (both clauses), `parse_trailing_number/1`,
   `command_scan_repo/1`, `command_scan_since/2` (both clauses),
   `command_scan_limit/1`, `command_scan_newest_datetime/1`,
   `command_scan_comment_datetime/1`, `parse_command_scan_datetime/1` (both
   clauses), `max_command_scan_datetime/3` (all clauses),
   `advance_command_scan_since/2` (both clauses).

7. **Module heads (all five new modules).** Each gets: a `@moduledoc` (2–4
   lines: the one-sentence responsibility from the name map §2, plus the
   sentence "All functions execute inside the orchestrator GenServer
   process."); the aliases its moved code references, copied from
   `orchestrator.ex`'s head (e.g. `alias Aiur.Orchestrator.State`,
   `alias Aiur.Orchestrator`, `alias Aiur.Orchestrator.{Dispatcher, Slots}`,
   `Issue`, `Tracker`, `Config`, `Alerts`, `Workspace`, `SessionHandle`,
   `Aiur.GitHub.Client, as: GitHubClient`, `Aiur.Events.{...}`,
   `require Logger` — copy ONLY the ones each module's moved code uses;
   `mix compile --warnings-as-errors` flags unused ones); and `@spec` on every
   public `def` (`mix credo --strict` runs `specs.check`, which enforces this).

8. **Rewrite intra-move references (no logic changes).** Inside the moved
   bodies, qualify calls whose targets now live in another module:

   a. **Targets already extracted by T-022/T-023** — call at their real home:
      - `State.find_running_by_identifier/2`, `State.issue_context/1`, and any
        other `State`-home lookup the moved code calls.
      - `Slots.available_slots/1`.
      - `Dispatcher.do_dispatch_issue/4`, `Dispatcher.dispatch_issue/4`,
        `Dispatcher.revalidate_issue_for_dispatch/3`.
      If a helper's real home is unclear, grep for it:
      `grep -rn "def <name>" src/lib/aiur/orchestrator/`. If T-022/T-023 left a
      1-line `defp <name>` delegating wrapper in the facade (e.g. T-022 kept
      `defp available_slots(state), do: Slots.available_slots(state)`), your
      new module cannot call that private wrapper — call the real module
      (`Slots.available_slots/1`) directly.

   b. **Targets already flipped to `@doc false def` by T-023** — call them as
      `Orchestrator.<name>` (add `alias Aiur.Orchestrator`). These need NO new
      flip this wave: `Orchestrator.terminate_running_issue/3`,
      `Orchestrator.reactivate_issue/2`. (Verify with
      `grep -n "def terminate_running_issue\|def reactivate_issue" src/lib/aiur/orchestrator.ex`;
      if for any reason one is still a `defp`, apply the flip in bullet c.)

   c. **Targets still `defp` in the facade that your moved code calls** — flip
      each to `@doc false def` with a `@spec`, body untouched, and call it as
      `Orchestrator.<name>`. These are shared / later-wave helpers that must
      STAY in the facade this wave (do not move them). Exact list:
      - `transition_control_status/4` (was ~998) — shared by CommentWake,
        PushRouting, and later-wave code (RuntimeWatchdog, PauseResume,
        Interrupts). It stays in the facade; both CommentWake and PushRouting
        call `Orchestrator.transition_control_status/4`.
      - `resume_paused_issue/3` (was ~6214, keep default `operator? \\ true`)
        — called by PushRouting's `attempt_auto_resume/5` and
        `maybe_drain_pending_auto_resume/3`; multi-consumer, stays.
      - `clear_session_handle/1` (both clauses, was ~4176) — called by
        CommentWake's `mark_pr_merged_issue_done/2` and PrAnchored's
        `stop_closed_pr_anchored_entries/3`; multi-consumer, stays.
      - `enqueue_event_digest_item/4` (was ~5602) — called by CommentWake's
        `seed_idle_comment_wake_event/3`; multi-consumer, stays.

   d. **Cross-references between the five new modules stay module-qualified:**
      `CommentWake.maybe_reactivate_on_comment/5` calls
      `PrAnchored.maybe_route_pr_anchored_or_legacy/5`. No other cross-module
      call exists between the five.

   e. **Do NOT change** `self()`, `Process.send_after/3`,
      `Process.cancel_timer/1`, `make_ref()`, `Process.monitor/1`, or
      `SubscriptionStore` ETS reads in any moved body. The
      `{:retry_comment_rework, ...}` timer and the `pending_auto_resume`
      per-tick drain depend on the moved code running inside the orchestrator
      process. This is load-bearing (research doc §4 invariants 1, 2, 10, 12).

9. **In `src/lib/aiur/orchestrator.ex`:** delete every moved definition, then
   add a one-line wrapper — identical head (same name, arity, guards, default
   args) — ONLY for the moved functions that code remaining in the facade
   still calls (its `handle_info`/`handle_call`/`handle_cast` clauses, the
   `run_poll_cycle` body, and the `*_for_test` seams). Do NOT edit the bodies
   of those clauses or the seams — the wrappers keep every call site compiling
   unchanged. Exact wrapper list:
   - `defp` → `CommentWake`: `maybe_reactivate_on_comment/5` (keep
     `attempt \\ 1`), `mark_pr_merged_issue_done/2`
   - `defp` → `PrAnchored`: `maybe_stop_closed_pr_anchored_agents/2` (keep
     `opts \\ []`)
   - `defp` → `PushRouting`: `maybe_pause_on_request/2`,
     `maybe_notify_agents_on_default_branch_push/3`, `maybe_mark_sleeping/2`,
     `maybe_resume_blockees_on_push/3`
   - `@doc false def` → `PushRouting`: `reconcile_pending_auto_resumes/1`
     (this ONE is `@doc false def`, not `defp`, because `Reconciler` calls it
     as `Orchestrator.reconcile_pending_auto_resumes/1` — the delegating
     wrapper preserves that external call without editing `reconciler.ex`)
   - `defp` → `CommentPolling`: `poll_github_firehose/2` (keep `opts \\ []`),
     `poll_github_comments/2` (keep `opts \\ []`)
   - `defp` → `CommandScan`: `scan_pr_commands/2` (keep `opts \\ []`)

   Do NOT move or edit the bodies of the `handle_info` clauses (including the
   `{:retry_comment_rework, ...}` clause at ~464 and the `pr.merged` clause at
   ~484), `run_poll_cycle`, `init/1`, `terminate/2`, tick scheduling, or
   tracked-set sync (`issue_tracked?/1` stays in the facade — Publisher
   closure contract).

10. **Do not modify** `src/mix.exs` (the five new modules must NOT be added to
    `ignore_modules`), any existing test file, `src/lib/aiur/orchestrator/tracked_set.ex`,
    or the T-022/T-023 modules (`state.ex`, `event_topics.ex`,
    `dispatch_policy.ex`, `slots.ex`, `dispatcher.ex`, `retry_engine.ex`,
    `reconciler.ex`). After steps 2–9 the repo compiles warnings-free and the
    FULL suite passes (run the Agent gate below).

11. **Write the five test files** (new modules are NOT coverage-exempt; the
    85% threshold plus this ticket's review enforce real tests). Build
    `%Aiur.Orchestrator.State{}` structs directly (all fields default) and
    inject stub fetch/dispatch funs via the same `opts`/`event` seams the
    existing code already accepts. Test only through each module's public
    functions plus a small number of directly-callable pure `defp`s promoted
    for testability ONLY if already public — do not add new public API. No
    GenServer needs to start. Minimum coverage:
    - `src/test/aiur/orchestrator/comment_wake_test.exs`:
      `trusted_comment_event?/1` is false for an untrusted author and true for
      a trusted one; `benign_review_pass_comment?/1` recognizes the bot's own
      `[codex] review passed` body (THE self-trigger guard — #621 class);
      `review_pass_comment?/1` matches the review-pass body and rejects others;
      `comment_rework_retry_delay_ms/1` returns the 2_000-based backoff and
      `comment_rework_max_attempts/0` returns 5 (the #631/#632 bounded-retry
      invariant); `mark_pr_merged_issue_done/2` on a state with no matching
      running entry returns the state unchanged (idempotent).
    - `src/test/aiur/orchestrator/pr_anchored_test.exs`:
      `maybe_route_pr_anchored_or_legacy/5` with `pr_watch` disabled performs
      no PR fetch and returns the state unchanged (feature-off byte-identical
      path, FI-ORC-044); with an injected fetcher returning an OPEN PR whose
      head is NOT `aiur/<N>` it routes to the PR-anchored dispatch fun, and
      with `{:ok, nil}` (404/closed) it falls through to the legacy path
      (assert via the captured dispatch fun / no synthetic dispatch);
      `maybe_stop_closed_pr_anchored_agents/2` on a state with zero
      `pr-watch`-state running entries returns the state unchanged and makes
      no fetch (the zero-entries short-circuit, FI-ORC-045).
    - `src/test/aiur/orchestrator/push_routing_test.exs`:
      `maybe_pause_on_request/2` for an unknown identifier is a no-op;
      `maybe_notify_agents_on_default_branch_push/3` never terminates or
      restarts a running entry (the #720 notify-only invariant — assert the
      `running` map is structurally unchanged); `maybe_mark_sleeping/2` flips a
      `:working` entry to `:sleeping` but leaves `:paused`/`:deactivated`
      entries unchanged; `reconcile_pending_auto_resumes/1` with no
      `pending_auto_resume` hints returns the state unchanged.
    - `src/test/aiur/orchestrator/comment_polling_test.exs`:
      `poll_github_comments/2` with an empty target set (inject a state whose
      running set and human-review/watch targets are empty) makes no GitHub
      call and returns the state unchanged; `poll_github_firehose/2` with an
      injected `request_fun` returning `{:not_modified, etag, interval}`
      preserves the stored etag (FI-ORC-041 If-None-Match retry) — assert the
      etag field is unchanged; the human-review target cap is 25 (drive
      `human_review_comment_poll_targets/2` if exposed, else assert
      `@human_review_comment_targets_per_poll`-equivalent behavior through the
      public poll path with >25 idle human-review issues yields <=25 targets).
    - `src/test/aiur/orchestrator/command_scan_test.exs`:
      `scan_pr_commands/2` with `pr_watch` disabled returns the state
      unchanged and makes no fetch; with an injected fetcher returning an
      empty comment stream it advances the cursor to the input `since`
      unchanged (no comments → no advance); `advance_command_scan_since/2`
      returns the input `since` when the newest datetime is `nil` and returns
      `newest − 1s` when given a `%DateTime{}` (the −1s cursor overlap that
      keeps non-command comments from stalling the scan, FI-ORC-043).

## Files

- Create:
  - `src/lib/aiur/orchestrator/comment_wake.ex`
  - `src/lib/aiur/orchestrator/pr_anchored.ex`
  - `src/lib/aiur/orchestrator/push_routing.ex`
  - `src/lib/aiur/orchestrator/comment_polling.ex`
  - `src/lib/aiur/orchestrator/command_scan.ex`
  - `src/test/aiur/orchestrator/comment_wake_test.exs`
  - `src/test/aiur/orchestrator/pr_anchored_test.exs`
  - `src/test/aiur/orchestrator/push_routing_test.exs`
  - `src/test/aiur/orchestrator/comment_polling_test.exs`
  - `src/test/aiur/orchestrator/command_scan_test.exs`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: the five new test files above; the entire existing suite (including
  everything under `src/test/aiur/regression/`) must pass unmodified.

## Out of scope

- The other 14 planned orchestrator modules whose functions stay in
  `orchestrator.ex` this wave: `IssueSync`, `AutoSubscriptions`,
  `TrackerHealth`, `OperatorMessages`, `DigestCoalescer` (→ T-025);
  `PauseResume`, `Interrupts`, `RemoteControlMode`, `TokenAccounting`
  (→ T-026); `StatusReport`, `WorkspaceCleanup`, `HumanReview`,
  `AgentTeardown`, `RuntimeWatchdog` (→ T-027). The only permitted touch to
  their code is the `defp` → `@doc false def` visibility flips explicitly
  listed in Scope step 8c (`transition_control_status/4`,
  `resume_paused_issue/3`, `clear_session_handle/1`,
  `enqueue_event_digest_item/4`) — bodies untouched.
- The T-022/T-023 modules (`state.ex`, `event_topics.ex`,
  `dispatch_policy.ex`, `slots.ex`, `dispatcher.ex`, `retry_engine.ex`,
  `reconciler.ex`) — call them, never edit them. In particular do NOT edit
  `reconciler.ex`: the facade's delegating `@doc false def
  reconcile_pending_auto_resumes/1` wrapper (Scope step 9) keeps it compiling.
- `src/lib/aiur/orchestrator/tracked_set.ex`, `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/github/client.ex`, `src/lib/aiur/events/**`,
  `src/lib/aiur/tracker.ex` — untouched. The events/client layer is exercised
  by the moved code only through the injected `request_fun`/fetcher opts it
  already accepts.
- `src/mix.exs` — untouched (no new coverage exemptions, no dep changes).
- Every existing test file, including all `*_for_test` seam call sites and
  everything under `src/test/aiur/regression/` — test moves/renames are the
  later cleanup wave (research doc W29), not this ticket.
- Any behavior change: no renamed functions, no reordered clauses, no changed
  delays/limits/log strings/alert topics/dedup keys, no "improvements" to
  moved code.
- `handle_info`/`handle_call`/`handle_cast` clause bodies, `init/1`,
  `terminate/2`, `run_poll_cycle`, tick scheduling, tracked-set sync
  (`issue_tracked?/1` stays in the facade — Publisher closure contract).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` and
`docs/refactor/feature-inventory/gh.md` — this ticket's Files implement or
touch these entries; their behavior must be byte-for-byte preserved:

- **FI-ORC-034** — trusted-comment reactivation of `:deactivated` entries
  (untrusted-author skip; the bot's own `[codex] review passed` self-trigger
  guard; idle-path retry backoff up to 5 attempts). → `CommentWake`.
- **FI-ORC-035** — idle-ticket comment promotion to `rework` + immediate
  dispatch (universal-subscription attach, wake-digest enqueue, fetch-then-
  dispatch-or-schedule). → `CommentWake`.
- **FI-ORC-036** — `pr.merged` terminalization (→ `done`, clear
  `SessionHandle`, terminate running entry with workspace cleanup). →
  `CommentWake.mark_pr_merged_issue_done/2` (the `handle_info` clause stays in
  the facade and delegates).
- **FI-ORC-037** — agent-initiated pause (`agent.pause.request` flips to
  `:paused` AND queues the cooperative `{:pause_agent, req}`; no-ops for
  paused/deactivated/unknown; stamps `paused_at`). → `PushRouting`.
- **FI-ORC-038** — blocker `branch.push` auto-resume with `pending_auto_resume`
  hint + per-tick drain (push consumed once; hint is the only recovery path;
  cleared on non-paused/deactivated). → `PushRouting`.
- **FI-ORC-039** — default-branch push is notify-only (#720): never terminate
  or restart; delivery via each agent's universal subscription/digest;
  base branch from `tracker.base_branch`. → `PushRouting`.
- **FI-ORC-040** — sleeping state on stream idle-close (`:working` → `:sleeping`;
  keeps its slot; qualifies for queue wake). → `PushRouting.maybe_mark_sleeping/2`.
- **FI-ORC-041** — firehose polling with watermark + connectivity escalation
  (the firehose driver `poll_github_firehose/2` moves here; the connectivity
  streak/backoff helpers it calls remain facade-resident for T-025). →
  `CommentPolling` (partial).
- **FI-ORC-042** — comment-poll target assembly (running ∪ idle human-review/
  merging ∪ agent:watch PRs, deduped; composed updated_at freshness gate;
  unknown-first ordering; 25-cap with drop logged; per-target cursor merge). →
  `CommentPolling`.
- **FI-ORC-043** — one-off PR command scan (`/aiur`, `@bot`) with cursor
  advancing over EVERY comment seen (newest − 1s) so non-command comments
  can't stall it; 25 PRs/cycle; fetch failure yields `[]` without advancing. →
  `CommandScan`.
- **FI-ORC-044** / **FI-GH-071** — PR-anchored routing and dispatch (U4):
  trusted non-benign comment, no running entry, `pr_watch` on → `GET /pulls/N`;
  OPEN PR with non-`aiur/<N>` head → synthetic `Issue{id: "pr-<N>",
  state: "pr-watch"}` through `do_dispatch_issue`; everything else falls
  through byte-identical to the legacy rework path; follow-up comment on a
  running PR-anchored agent resumes the SAME session. → `PrAnchored` (routing)
  + `CommentWake` (the 609–631 hand-off).
- **FI-ORC-045** / **FI-GH-072** — PR-anchored mid-run teardown (U6): gated on
  `pr_watch`, short-circuited at zero `pr-watch` entries; `{:ok, nil}` closes +
  removes the `pr-<N>` workspace + clears the PR-keyed session handle (#613);
  `{:ok, pr}` and `{:error, _}` leave the agent running; mid-run untag does
  NOT abort. → `PrAnchored.maybe_stop_closed_pr_anchored_agents/2`.
- **FI-GH-062** — poll-cycle ordering of GitHub detectors (the ordering lives
  in `run_poll_cycle`, which STAYS in the facade; the drivers it calls in order
  — firehose, comments, command scan, PR-anchored teardown — move to
  `CommentPolling`/`CommandScan`/`PrAnchored` and are called via the step-9
  wrappers). Touched, ordering unchanged.
- **FI-GH-063** — comment-poll target selection (running + human-review/merging
  + agent:watch PRs; the freshness-gate unchanged-target skip; the label
  discovery path). → `CommentPolling`.
- **FI-GH-065** — repo-wide one-off `/aiur` command scan (U3): review-comment +
  conversation-comment streams; PR-number derivation; PrCommandScanner filter;
  25-cap; `bypass_contamination` + `pr_command` dedup key. → `CommandScan`.

## Characterization-tests

**All of `src/test/aiur/regression/` must pass UNMODIFIED** — this is the #1
regression hotspot, so the tripwire is strictest here. Specifically:

- **T-008's `src/test/aiur/regression/github_ingestion_test.exs`** (22 tests,
  comment dedup keys, boot-cutoff wake behavior, per-target poll isolation,
  connectivity backoff, strict `refs/heads/aiur/<digits>` routing,
  CODEOWNERS trust gating) — pins the ingestion boundary that
  `CommentPolling`/`CommandScan` drive. It must pass byte-for-byte
  unchanged. **Call this out per the ticket mandate.**
- **T-007's `src/test/aiur/regression/orchestrator_lifecycle_test.exs` and
  `orchestrator_dispatch_retry_test.exs`** — pin the orchestrator lifecycle
  and dispatch/retry semantics that the moved comment/PR/push paths interact
  with.

List the orchestrator-relevant regression files at execution time with
`ls src/test/aiur/regression/` (they merge in Phase 1, before this ticket
opens) and run the full `src/test/aiur/regression/` directory explicitly
before opening the PR.

These existing (non-regression-dir) pins must ALSO pass unmodified — they
exercise the moved code through the `*_for_test` seams and `handle_info`/
`handle_cast` sends, which is why the seams and wrappers must keep identical
signatures:
`src/test/aiur/orchestrator_deactivate_test.exs` (the heavy pin — comment
reactivation/rework, PR-anchored routing + teardown, pause.request,
blocker auto-resume, default-branch notify, sleeping, human-review deactivate),
`src/test/aiur/orchestrator_firehose_test.exs`,
`src/test/aiur/orchestrator_status_test.exs`,
`src/test/aiur/orchestrator_max_agents_test.exs`,
`src/test/aiur/core_test.exs`,
`src/test/aiur/events/pr_command_scanner_test.exs`.

## Acceptance criteria

All greps run from the repo root; all must hold:

- `grep -c "defmodule Aiur.Orchestrator.CommentWake do" src/lib/aiur/orchestrator/comment_wake.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.PrAnchored do" src/lib/aiur/orchestrator/pr_anchored.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.PushRouting do" src/lib/aiur/orchestrator/push_routing.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.CommentPolling do" src/lib/aiur/orchestrator/comment_polling.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.CommandScan do" src/lib/aiur/orchestrator/command_scan.ex` = 1
- `grep -c "@moduledoc" <file>` >= 1 for each of the five new modules.
- `wc -l < src/lib/aiur/orchestrator.ex` < 4700 (T-023 left it < 6100; this
  wave moves ~1,840 def-lines minus the ~15 one-line wrappers added back).
- New-file size caps (these carry the research doc §2 documented exception to
  the 200-line norm — CommentWake and CommentPolling land ~400 as single
  cohesive state machines; do not split further and do not exceed):
  `wc -l < src/lib/aiur/orchestrator/comment_wake.ex` <= 470,
  `wc -l < src/lib/aiur/orchestrator/pr_anchored.ex` <= 380,
  `wc -l < src/lib/aiur/orchestrator/push_routing.ex` <= 400,
  `wc -l < src/lib/aiur/orchestrator/comment_polling.ex` <= 520,
  `wc -l < src/lib/aiur/orchestrator/command_scan.ex` <= 380.
- Moved functions are moved, not rewritten: no NEW function body may exceed 20
  logic lines (wrappers are 1 line); moved bodies are byte-identical (verified
  at-merge via `--color-moved`).
- Module attributes left the facade — each grep = 0 in `orchestrator.ex` and
  exactly 1 in its new home:
  `grep -c "@comment_rework_retry_delay_ms\|@comment_rework_max_attempts" src/lib/aiur/orchestrator.ex` = 0
  (each appears once in `comment_wake.ex`);
  `grep -c "@pr_anchored_state" src/lib/aiur/orchestrator.ex` = 0
  (once in `pr_anchored.ex`);
  `grep -c "@watch_comment_targets_per_poll\|@human_review_comment_targets_per_poll" src/lib/aiur/orchestrator.ex` = 0
  (each once in `comment_polling.ex`).
- No comment-rework retry timer remains in the facade:
  `grep -c "Process.send_after(self(), {:retry_comment_rework" src/lib/aiur/orchestrator.ex` = 0
  and the same grep = 1 in `src/lib/aiur/orchestrator/comment_wake.ex`.
- No `pending_auto_resume` drain logic remains in the facade beyond the
  1-line wrapper: `grep -c "maybe_drain_pending_auto_resume\|stamp_pending_auto_resume\|clear_pending_auto_resume" src/lib/aiur/orchestrator.ex` = 0.
- No unwrapped moved definitions remain (wrapped names keep a 1-line `defp`/
  `@doc false def`; these internal names must be gone entirely):
  `grep -cE "^  defp (reactivate_if_deactivated|maybe_transition_idle_issue_to_rework|schedule_comment_rework_retry|dispatch_reworked_comment_issue|transition_and_revalidate_comment_reactivation|revalidate_comment_reactivation|trusted_comment_event\?|review_pass_comment\?|find_issue_by_identifier_or_id)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (resolve_pr_anchored_unit|build_pr_anchored_issue|dispatch_pr_anchored_unit|stop_closed_pr_anchored_entries|cleanup_pr_anchored_workspace|aiur_owned_head_ref\?|pr_anchored_routing_enabled\?)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (attempt_auto_resume|maybe_resume_for_topic|subscribed_to_topic\?|default_branch_name)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (do_poll_github_comments|poll_github_comment_targets|github_comment_poll_targets|human_review_comment_poll_targets|watch_comment_poll_targets|build_watch_targets|remember_polled_human_review_targets|human_review_pr_probe_priority)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (do_scan_pr_commands|command_scan_review_comments|command_scan_issue_comments|publish_command_hits|cap_command_pr_hits|publish_command_reactivation|advance_command_scan_since)\(" src/lib/aiur/orchestrator.ex` = 0.
- The step-9 wrapper names still resolve in the facade (each keeps a 1-line
  definition): `grep -cE "^  defp (maybe_reactivate_on_comment|mark_pr_merged_issue_done|maybe_stop_closed_pr_anchored_agents|maybe_pause_on_request|maybe_notify_agents_on_default_branch_push|maybe_mark_sleeping|maybe_resume_blockees_on_push|poll_github_firehose|poll_github_comments|scan_pr_commands)\(" src/lib/aiur/orchestrator.ex` >= 10;
  `grep -c "def reconcile_pending_auto_resumes" src/lib/aiur/orchestrator.ex` = 1.
- New modules are NOT coverage-exempt:
  `grep -cE "Orchestrator\.(CommentWake|PrAnchored|PushRouting|CommentPolling|CommandScan)" src/mix.exs` = 0.
- A test file exists per extracted module (all five must be present):
  `for f in comment_wake pr_anchored push_routing comment_polling command_scan; do test -f "src/test/aiur/orchestrator/${f}_test.exs" && echo "$f ok"; done`
  prints five `ok` lines.
- `git diff --name-only origin/v2...HEAD` lists exactly the 11 files in
  **Files** — in particular NOTHING under `src/test/aiur/regression/`, no
  edit to any `src/lib/aiur/orchestrator/{state,event_topics,dispatch_policy,slots,dispatcher,retry_engine,reconciler}.ex`,
  and no `src/mix.exs`.
- The full Agent gate below passes.

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

- Check (verbatim move): `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/orchestrator.ex src/lib/aiur/orchestrator/comment_wake.ex src/lib/aiur/orchestrator/pr_anchored.ex src/lib/aiur/orchestrator/push_routing.ex src/lib/aiur/orchestrator/comment_polling.ex src/lib/aiur/orchestrator/command_scan.ex`
  shows the moved bodies as moved (dimmed), not rewritten; the only in-body
  edits are the module-qualifications listed in Scope step 8.
- Check (FI-ORC-034 self-trigger guard intact): `comment_wake.ex` contains the
  bot `[codex] review passed` recognition in `benign_review_pass_comment?/1` /
  `review_pass_comment?/1`, byte-identical.
- Check (FI-ORC-038 pending-hint drain intact): `push_routing.ex` contains
  `stamp_pending_auto_resume/4`, `reconcile_pending_auto_resumes/1`, and
  `maybe_drain_pending_auto_resume/3`; the facade retains only the 1-line
  `@doc false def reconcile_pending_auto_resumes(state), do:
  PushRouting.reconcile_pending_auto_resumes(state)` delegator and
  `reconciler.ex` is unchanged (`git diff origin/v2...HEAD -- src/lib/aiur/orchestrator/reconciler.ex`
  is empty).
- Check (FI-ORC-039 notify-only #720): `push_routing.ex`'s
  `maybe_notify_agents_on_default_branch_push/3` contains no `terminate_`/
  `restart_` call — it only logs and returns state.
- Check (FI-ORC-045 zero-entry short-circuit): `pr_anchored.ex`'s
  `maybe_stop_closed_pr_anchored_agents/2` returns early (no PR fetch) when
  `pr_anchored_running_entries/1` is empty.
- Check (FI-ORC-043 cursor overlap): `command_scan.ex`'s
  `advance_command_scan_since/2` subtracts 1 second from the newest datetime,
  verbatim.
- Run the named pins:
  `mix test test/aiur/orchestrator_deactivate_test.exs test/aiur/orchestrator_firehose_test.exs test/aiur/orchestrator_status_test.exs test/aiur/orchestrator_max_agents_test.exs test/aiur/core_test.exs test/aiur/events/pr_command_scanner_test.exs test/aiur/regression`
  — all green with zero skips.
- Behavior spot-check on `v2` after merge: start `aiurdev` against the sandbox
  repo, post a trusted comment on a deactivated/idle ticket, and confirm the
  orchestrator reactivates/reworks it (unchanged log strings) exactly as
  before the extraction; confirm a main-branch push notifies (does not kill)
  running agents.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
