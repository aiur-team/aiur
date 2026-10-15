defmodule Aiur.Orchestrator.ReworkDispatchClaimTest do
  # Keep claim, recovery, and prompt assertions together as one dispatch lifecycle.
  use Aiur.TestSupport

  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, StartupClaimReconciler, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    handler = "rework-dispatch-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:aiur, :ticket_transition], &__MODULE__.handle_transition/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def handle_transition(event, measurements, meta, pid), do: send(pid, {:ticket_transition, event, measurements, meta})

  test "claims a rework ticket once as in-progress while the runner receives rework" do
    issue = issue("rework-claim", "rework")
    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    parent = self()

    state =
      Dispatcher.dispatch_issue(dispatch_state(), issue, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:runner_issue, dispatched})
          :ok
        end
      )

    assert_receive {:memory_tracker_state_update, "rework-claim", "in-progress"}, 1_000
    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{}, %{issue_id: "rework-claim", expected: "rework", to: "in-progress", writer: :dispatcher, outcome: :ok}}, 1_000
    assert_receive {:runner_issue, %Issue{state: "rework"}}, 1_000
    assert Map.has_key?(state.running, issue.id)
    assert {:ok, [%Issue{state: "in-progress"}]} = Tracker.fetch_issue_states_by_ids([issue.id])
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "a failed guarded rework claim has a distinct decline and starts no worker" do
    candidate = issue("rework-write-failure", "rework")
    Application.put_env(:aiur, :memory_tracker_issues, [%{candidate | state: "todo"}])
    parent = self()

    state =
      Dispatcher.dispatch_issue(dispatch_state(), candidate, nil, nil,
        issue_fetcher: fn _ids -> {:ok, [candidate]} end,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn _dispatched, _recipient, _opts -> send(parent, :runner_started) end
      )

    assert state.dispatch_declines[candidate.id] == :rework_claim_failed

    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{},
                    %{issue_id: "rework-write-failure", expected: "rework", to: "in-progress", writer: :dispatcher, outcome: {:error, {:stale_issue_state, "rework", "todo"}}}},
                   1_000

    refute Map.has_key?(state.running, candidate.id)
    refute MapSet.member?(state.claimed, candidate.id)
    assert {:ok, [%Issue{state: "todo"}]} = Tracker.fetch_issue_states_by_ids([candidate.id])
    refute_received {:memory_tracker_state_update, _, _}
    refute_received :runner_started
  end

  test "a poll after the guarded claim does not re-enter rework or dispatch twice (#2422)" do
    issue = issue("rework-next-poll", "rework")
    issue_id = issue.id
    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    parent = self()

    state =
      Dispatcher.dispatch_issue(dispatch_state(), issue, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn dispatched, _recipient, _opts -> send(parent, {:runner_issue, dispatched}) end
      )

    assert_receive {:memory_tracker_state_update, "rework-next-poll", "in-progress"}, 1_000
    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{}, %{issue_id: "rework-next-poll", expected: "rework", to: "in-progress", writer: :dispatcher, outcome: :ok}}, 1_000
    assert_receive {:runner_issue, %Issue{state: "rework"}}, 1_000

    poll_issue = %{issue | state: "in-progress", state_labels: ["in-progress"], labels: ["agent:in-progress"]}

    next =
      Dispatcher.choose_issues(state, [poll_issue], runner: fn dispatched, _recipient, _opts -> send(parent, {:runner_issue, dispatched}) end)

    assert Map.has_key?(next.running, issue.id)
    assert MapSet.member?(next.claimed, issue.id)
    assert {:ok, [%Issue{state: "in-progress"}]} = Tracker.fetch_issue_states_by_ids([issue.id])
    refute_received {:memory_tracker_state_update, ^issue_id, _}
    refute_received {:ticket_transition, [:aiur, :ticket_transition], _, _}
    refute_received {:runner_issue, _}
  end

  test "captures the rework head only after claiming and preserves it on retry" do
    test_pid = self()
    issue = issue("rework-first", "rework")
    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    runner = fn dispatched_issue, recipient, opts ->
      send(test_pid, {:rework_runner_started, dispatched_issue, recipient, opts})
      :ok
    end

    fetcher = fn identifier ->
      send(test_pid, {:rework_head_lookup_started, identifier, self()})

      receive do
        :finish_lookup -> {:ok, %{"head" => %{"sha" => "captured-head"}}}
      end
    end

    next_state =
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        1,
        nil,
        runner: runner,
        rework_head_fetcher: fetcher
      )

    assert next_state.running[issue.id].rework_head_sha == :pending
    assert_receive {:rework_head_lookup_started, "rework-first", lookup_pid}, 1_000
    refute_receive {:rework_runner_started, _, _, _}, 20
    send(lookup_pid, :finish_lookup)
    assert_receive {:worker_runtime_info, issue_id, %{rework_head_sha: "captured-head"}}, 1_000
    assert issue_id == issue.id
    assert_receive {:rework_runner_started, ^issue, _recipient, runner_opts}, 1_000
    assert Keyword.fetch!(runner_opts, :rework_head_sha) == "captured-head"

    assert {:noreply, captured_state} =
             State.handle_worker_runtime_info(next_state, issue.id, %{rework_head_sha: "captured-head"})

    assert captured_state.running[issue.id].rework_head_sha == "captured-head"

    retry_issue = issue("rework-retry", "rework")
    Application.put_env(:aiur, :memory_tracker_issues, [retry_issue])

    retry_state =
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        retry_issue,
        2,
        nil,
        runner: fn dispatched_issue, recipient, opts ->
          send(test_pid, {:rework_retry_runner, dispatched_issue, recipient, opts})
          :ok
        end,
        rework_head_sha: "head-before-first-attempt"
      )

    assert_receive {:rework_retry_runner, ^retry_issue, _recipient, retry_opts}, 1_000
    assert Keyword.fetch!(retry_opts, :rework_head_sha) == "head-before-first-attempt"
    assert retry_state.running[retry_issue.id].rework_head_sha == "head-before-first-attempt"
  end

  test "an orphaned in-progress claim is released to rework and dispatched with rework context" do
    issue = issue("orphaned-rework", "in-progress")
    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    parent = self()
    now = System.monotonic_time(:millisecond)

    {state, [rework_issue]} =
      StartupClaimReconciler.reconcile(
        %State{
          startup_claim_reconciliation_complete?: true,
          orphaned_claim_since: %{issue.identifier => now - 1}
        },
        [issue],
        grace_ms: 0,
        now_ms: now,
        ownership_fun: fn _identifier -> :none end,
        open_pr_fetcher: fn _identifier -> {:ok, %{"number" => 4336}} end,
        pr_fetcher: fn _number ->
          {:ok, %{"number" => 4336, "mergeable" => true, "head" => %{"sha" => "abc123"}}}
        end,
        unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "review-thread"}]} end,
        queued_approval_fetcher: fn _pr -> {:ok, false} end,
        create_comment_fun: fn _identifier, _body -> :ok end,
        emit_alert_fun: fn _topic, _opts -> :ok end
      )

    assert rework_issue.state == "rework"
    assert_receive {:memory_tracker_state_update, "orphaned-rework", "rework"}, 1_000
    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{}, %{issue_id: "orphaned-rework", expected: "in-progress", to: "rework", writer: :startup_claim_reconciler, outcome: :ok}}, 1_000

    state =
      Dispatcher.dispatch_issue(%{state | max_concurrent_agents: 4, effective_concurrent_agents: 4}, rework_issue, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:runner_issue, dispatched})
          :ok
        end
      )

    assert_receive {:memory_tracker_state_update, "orphaned-rework", "in-progress"}, 1_000
    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{}, %{issue_id: "orphaned-rework", expected: "rework", to: "in-progress", writer: :dispatcher, outcome: :ok}}, 1_000
    assert_receive {:runner_issue, %Issue{state: "rework"}}, 1_000
    assert Map.has_key?(state.running, issue.id)
    assert {:ok, [%Issue{state: "in-progress"}]} = Tracker.fetch_issue_states_by_ids([issue.id])
  end

  # Existing lifecycle regression guard: paused is an independent marker, not
  # an active claim; orphan recovery must leave the marker and state untouched.
  test "regression guard: paused orphan recovery retains the pause marker and does not dispatch" do
    issue = %{issue("paused-rework", "in-progress") | paused: true, labels: ["agent:paused", "agent:in-progress"]}
    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    now = System.monotonic_time(:millisecond)

    {state, [retained]} =
      StartupClaimReconciler.reconcile(
        %State{
          startup_claim_reconciliation_complete?: true,
          orphaned_claim_since: %{issue.identifier => now - 1}
        },
        [issue],
        grace_ms: 0,
        now_ms: now,
        ownership_fun: fn _identifier -> :none end,
        update_issue_state_fun: fn _identifier, _target, _expected -> flunk("paused claim must not be rewritten") end,
        emit_alert_fun: fn _topic, _opts -> flunk("paused claim must not alert") end
      )

    assert retained == issue
    assert state.startup_claim_reconciliation_complete?

    result =
      Dispatcher.dispatch_issue(dispatch_state(), retained, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn _dispatched, _recipient, _opts -> flunk("paused ticket must not start a worker") end
      )

    assert result.dispatch_declines[issue.id] == {:stale_after_revalidation, :paused}

    assert {:ok, [%Issue{paused: true, state: "in-progress", labels: ["agent:paused", "agent:in-progress"]}]} =
             Tracker.fetch_issue_states_by_ids([issue.id])

    refute_received {:memory_tracker_state_update, _, _}
  end

  defp dispatch_state do
    %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
  end

  defp issue(id, state) do
    %Issue{
      id: id,
      identifier: id,
      title: id,
      state: state,
      state_labels: [state],
      selected_backend: "codex",
      labels: ["agent:#{state}"]
    }
  end
end

defmodule Aiur.Orchestrator.ReworkDispatchPausedLabelTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.Workflow

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    token_key = {Aiur.GitHub.Config, :resolved_token}
    previous_cached_token = :persistent_term.get(token_key, :unset)
    :persistent_term.erase(token_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(token_key)
        token -> :persistent_term.put(token_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    :ok
  end

  # Existing label-swap regression guard; this does not exercise the dispatcher
  # change, so the mutation check below counts only the dispatch tests above.
  test "regression guard: promoting rework preserves the independent agent:paused marker" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})

      case request.method do
        :get ->
          {:ok,
           %{
             status: 200,
             body: %{
               "state" => "open",
               "labels" => [%{"name" => "agent:rework"}, %{"name" => "agent:paused"}]
             }
           }}

        :post ->
          assert request.body == %{"labels" => ["agent:in-progress"]}
          {:ok, %{status: 200}}

        :delete ->
          refute String.ends_with?(request.url, "/agent:paused")
          {:ok, %{status: 200}}
      end
    end

    assert :ok =
             IssueState.update_issue_state("4336", "in-progress",
               expected_state: "rework",
               request_fun: request_fun
             )

    assert_received {:request, %{method: :post}}
    assert_received {:request, %{method: :delete, url: url}}
    assert String.ends_with?(url, "/agent:rework")
  end
end
