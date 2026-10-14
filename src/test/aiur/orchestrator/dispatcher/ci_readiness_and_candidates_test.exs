defmodule Aiur.Orchestrator.Dispatcher.CiReadinessAndCandidatesTest do
  use Aiur.DispatcherTestSupport

  test "first dispatch warns about an unmergeable GitHub repository without blocking dispatch" do
    readiness = %{ready?: false, base_branch: "develop", issues: [:no_pr_workflow]}
    emit = fn name, opts -> send(self(), {:ci_readiness_alert, name, opts}) end

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:ok, readiness} end, emit)

    assert state.ci_readiness_checked
    assert_receive {:ci_readiness_alert, "system.ci_readiness.not_ready", opts}, 1000
    assert opts[:needs_attention]
    assert opts[:reason] =~ "no workflow triggers on pull_request"
  end

  test "initial readiness scan runs outside the dispatcher mailbox and caches its result" do
    parent = self()
    readiness = %{ready?: true, base_branch: "develop", issues: []}

    state =
      Dispatcher.start_initial_ci_readiness_check(%State{}, "github", "develop", fn _opts ->
        send(parent, :readiness_scan_started)
        {:ok, readiness}
      end)

    assert is_pid(state.ci_readiness_check_pid)
    assert_receive :readiness_scan_started, 1000
    assert_receive {:ci_readiness_result, token, {:ok, ^readiness}}, 1000

    state = Dispatcher.handle_ci_readiness_result(state, token, {:ok, readiness})

    assert state.ci_readiness_checked
    assert CiReadiness.cached_result(base_branch: "develop") == readiness
  end

  test "first dispatch retries an unavailable readiness check without duplicate alerts" do
    emit = fn name, _opts -> send(self(), {:ci_readiness_alert, name}) end
    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, :timeout} end, emit)

    refute state.ci_readiness_checked
    assert state.ci_readiness_unavailable_alerted
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable"}, 1000

    state = Dispatcher.check_initial_ci_readiness(state, "github", "develop", fn _ -> {:error, :timeout} end, emit)

    refute state.ci_readiness_checked
    refute_receive {:ci_readiness_alert, _}, 100
  end

  test "readiness alerts explain organization repository authorization failures" do
    emit = fn name, opts -> send(self(), {:ci_readiness_alert, name, opts}) end

    error =
      {:github_org_repository_not_accessible, %{organization: "acme", repo: "acme/private-repo", token_type: :classic_pat}}

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, error} end, emit)

    assert state.ci_readiness_checked
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable", opts}, 1000
    assert opts[:reason] =~ "Cannot read acme/private-repo"
    assert opts[:reason] =~ "classic PAT"
    assert opts[:reason] =~ "Configure SSO"
    refute opts[:reason] =~ "github_org_repository_not_accessible"
  end

  test "does not launch another readiness scan before the transient retry deadline" do
    scope = CiReadiness.readiness_scope()
    state = %State{ci_readiness_retry_at_ms: System.monotonic_time(:millisecond) + 60_000, ci_readiness_scope: scope}

    assert Dispatcher.maybe_warn_ci_readiness(state) == state
  end

  test "paces retryable GitHub readiness errors without caching them as permanent" do
    emit = fn name, _opts -> send(self(), {:ci_readiness_alert, name}) end
    error = {:github, :rate_limited, %{status: 429}}

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, error} end, emit)

    refute state.ci_readiness_checked
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert CiReadiness.cached_result() == :unavailable
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable"}, 1000
  end

  test "retries transient GitHub server errors without caching them as permanent" do
    emit = fn name, _opts -> send(self(), {:ci_readiness_alert, name}) end
    error = {:github, :http, %{status: 503}}

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, error} end, emit)

    refute state.ci_readiness_checked
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert CiReadiness.cached_result() == :unavailable
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable"}, 1000
  end

  test "caches an operator-token readiness gap as a completed assessment" do
    readiness = CiReadiness.unavailable("develop", :ci_readiness_operator_token_required)
    emit = fn name, opts -> send(self(), {:ci_readiness_alert, name, opts}) end

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:ok, readiness} end, emit)

    assert state.ci_readiness_checked
    assert CiReadiness.cached_result(base_branch: "develop") == readiness
    assert_receive {:ci_readiness_alert, "system.ci_readiness.not_ready", opts}, 1000
    assert opts[:needs_attention]
  end

  test "a completed readiness assessment is rescanned after its cache expires" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_base_branch: "develop"
    )

    parent = self()
    old_readiness = %{ready?: true, base_branch: "develop", issues: []}
    new_readiness = %{ready?: false, base_branch: "develop", issues: [:no_required_check]}
    assessed_at = DateTime.add(DateTime.utc_now(), -3_601, :second)
    opts = [base_branch: "develop", now: assessed_at]
    scope = CiReadiness.readiness_scope(opts)

    assert :ok = CiReadiness.persist_assessment(old_readiness, opts)

    Application.put_env(:aiur, :ci_readiness_check_fun, fn check_opts ->
      send(parent, {:readiness_rescan, check_opts})
      {:ok, new_readiness}
    end)

    state = %State{
      ci_readiness_checked: true,
      ci_readiness_scope: scope,
      ci_readiness_result: old_readiness
    }

    state = Dispatcher.maybe_warn_ci_readiness(state)

    refute state.ci_readiness_checked
    assert is_pid(state.ci_readiness_check_pid)
    assert_receive {:readiness_rescan, check_opts}, 1000
    assert check_opts[:base_branch] == "develop"
  end

  test "a newer operator assessment replaces the completed live result" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_base_branch: "develop"
    )

    now = DateTime.utc_now()
    old_readiness = CiReadiness.unavailable("develop", :ci_readiness_operator_token_required)
    new_readiness = %{ready?: true, base_branch: "develop", issues: []}
    opts = [base_branch: "develop", now: DateTime.add(now, -2, :second)]
    scope = CiReadiness.readiness_scope(opts)

    assert :ok = CiReadiness.cache_result(old_readiness, opts)
    assert :ok = CiReadiness.persist_assessment(new_readiness, Keyword.put(opts, :now, DateTime.add(now, -1, :second)))

    state = %State{
      ci_readiness_checked: true,
      ci_readiness_scope: scope,
      ci_readiness_result: old_readiness
    }

    assert %State{ci_readiness_checked: true, ci_readiness_result: ^new_readiness} =
             Dispatcher.maybe_warn_ci_readiness(state)
  end

  test "GitHub candidate state is fetched authoritatively every configured poll interval" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      poll_interval_seconds: 5
    )

    cached = %Issue{id: "42", identifier: "42", title: "Cached", state: "in-progress"}
    fresh = %{cached | state: "todo", labels: ["agent:todo"]}

    state = %State{
      poll_interval_ms: 5_000,
      candidate_snapshot_fresh?: false,
      poll_cycles_completed: 1,
      ci_lifecycle: %{
        approved_heads: %{},
        test_failure_heads: %{},
        base_repair_invalidations: %{},
        poll_cache: %{issue_list_cache: %{stale: cached}},
        rewakes: %{}
      }
    }

    {:ok, responses} = Agent.start_link(fn -> [{[cached], %{etag: "v1"}}, {[fresh], %{etag: "v2"}}] end)

    fetch_fun = fn cache ->
      Agent.get_and_update(responses, fn [{issues, updated_cache} | rest] ->
        assert cache == if(issues == [cached], do: %{}, else: %{etag: "v1"})
        {{:ok, issues, updated_cache}, rest}
      end)
    end

    assert {:ok, [^cached], state} = Dispatcher.fetch_candidate_issues(state, fetch_fun: fetch_fun)
    assert state.candidate_snapshot_fresh?
    assert state.ci_lifecycle.poll_cache.candidate_list_cache == %{etag: "v1"}

    assert {:ok, [^fresh], state} = Dispatcher.fetch_candidate_issues(state, fetch_fun: fetch_fun)
    assert state.ci_lifecycle.poll_cache.candidate_list_cache == %{etag: "v2"}

    # `repo: nil` pins out webhook interval widening, which resolves the repo
    # through the global `Aiur.GitHub.Config.repo/0` and its webhook-mode state.
    # Leaving it unpinned made this assertion depend on whichever sibling test
    # last touched that global — green alone, 10_000 in a full suite run.
    # Webhook widening is covered by `Aiur.Webhooks.IntervalPolicy`'s own tests;
    # what this test owns is the configured-interval pacing of revalidation.
    assert TrackerHealth.next_poll_delay_ms(state, repo: nil, idle_widen_factor: 1.0) == 5_000

    # ...which an idle fleet then widens by `polling.idle_widen_factor` (5.0).
    # Snapshot freshness is bounded by the effective interval, not the raw one.
    assert TrackerHealth.next_poll_delay_ms(state, repo: nil) == 25_000
  end

  test "the candidate poll wires the stranded-ticket reconciliation pass after dispatch" do
    parent = self()

    # A non-dispatchable ticket (no agent work in `merging`) that the poll
    # still hands to the reconciliation pass; the sweep normally re-queues a
    # released-claim ticket from here (#2361, #2420).
    stranded = %{issue("wired-strand") | state: "merging", state_labels: ["merging"]}

    next =
      Dispatcher.dispatch_candidate_poll(
        %State{released_claims: %{stranded.id => %{cause: :tracker_retry_exhausted}}},
        fetch_candidate_issues_fun: fn current_state ->
          Dispatcher.fetch_candidate_issues(current_state,
            fetch_fun: fn _cache -> {:ok, [stranded], %{}} end
          )
        end,
        stranded_reconciliation_fun: fn state, issues ->
          send(parent, {:stranded_reconciliation_called, Enum.map(issues, & &1.id)})
          state
        end
      )

    assert_receive {:stranded_reconciliation_called, ["wired-strand"]}, 1000
    assert next.released_claims == %{"wired-strand" => %{cause: :tracker_retry_exhausted}}
  end

  test "a global pause stops candidate authorization while monitoring continues" do
    parent = self()
    state = %State{globally_paused: true, candidate_snapshot_fresh?: true}

    fetch_fun = fn _cache ->
      send(parent, :dispatch_authorization_requested)
      {:ok, [], %{}}
    end

    monitor = fn current_state ->
      Dispatcher.monitor_without_candidates(current_state,
        refresh_running_fun: fn monitored_state ->
          send(parent, :running_states_refreshed)
          monitored_state
        end,
        scan_commands_fun: fn monitored_state ->
          send(parent, :commands_scanned)
          monitored_state
        end,
        stop_closed_pr_agents_fun: fn monitored_state ->
          send(parent, :closed_pr_agents_stopped)
          monitored_state
        end,
        notify_dashboard_fun: fn _monitored_state ->
          send(parent, :dashboard_notified)
          :ok
        end
      )
    end

    assert ^state =
             Dispatcher.dispatch_candidate_poll(state,
               fetch_candidate_issues_fun: fn current_state ->
                 Dispatcher.fetch_candidate_issues(current_state, fetch_fun: fetch_fun)
               end,
               monitor_without_candidates_fun: monitor
             )

    refute_received :dispatch_authorization_requested
    assert_received :running_states_refreshed
    assert_received :commands_scanned
    assert_received :closed_pr_agents_stopped
    assert_received :dashboard_notified
  end

  test "a failed GitHub candidate refresh hides stale idle labels but preserves recovery data" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"]
    )

    stale = %Issue{id: "42", identifier: "42", title: "Stale", state: "in-progress"}

    state = %State{
      last_polled_issues: %{stale.id => stale},
      snapshot_ready?: false,
      ci_lifecycle: %{
        %State{}.ci_lifecycle
        | poll_cache: %{candidate_list_cache: %{pages: %{1 => %{etag: "v1"}}}}
      }
    }

    reason = {:github, :timeout, %{reason: :timeout}}
    fetch_fun = fn %{pages: %{1 => %{etag: "v1"}}} -> {:error, reason} end

    assert {:error, ^reason, next} =
             Dispatcher.fetch_candidate_issues(state, fetch_fun: fetch_fun)

    assert next.last_polled_issues == state.last_polled_issues
    assert next.snapshot_ready?
    refute next.candidate_snapshot_fresh?
    assert next.ci_lifecycle.poll_cache == state.ci_lifecycle.poll_cache
    assert next.github_connectivity[:candidates] == {:timeout, 1}
    assert next.github_poll_delays[:candidates] == 1_000

    assert %{idle: [], polling: %{tracker_snapshot_fresh?: false}} =
             StatusReport.snapshot_payload(next)

    assert StatusReport.running_summaries(next) == []
  end
end
