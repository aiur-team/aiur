defmodule Aiur.Orchestrator.Dispatcher.DependencyGateTest do
  use Aiur.DispatcherTestSupport

  describe "dispatch_issue blocked_by dependency gate" do
    test "skips dispatch when revalidation hydration reveals a non-terminal blocker" do
      test_pid = self()

      issue = %Issue{
        id: "blocked-ticket",
        identifier: "repo#blocked-ticket",
        title: "blocked ticket",
        state: "todo"
      }

      hydrated = %{issue | blocked_by: [%{id: "5", identifier: "5", state: "in-progress"}]}

      runner = fn dispatched, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched, recipient, opts})
        :ok
      end

      log =
        capture_log(fn ->
          next_state =
            Dispatcher.dispatch_issue(%State{effective_concurrent_agents: 4}, issue, nil, nil,
              issue_fetcher: fn [id] -> {:ok, [%{issue | id: id}]} end,
              blocked_by_hydrator: fn _issue -> {:ok, hydrated} end,
              runner: runner
            )

          refute Map.has_key?(next_state.running, issue.id)
          refute MapSet.member?(next_state.claimed, issue.id)
        end)

      refute_receive {:agent_runner_run, _, _, _}, 100
      assert log =~ "blocked by open dependency #5 (in-progress)"
    end

    test "the hold log names only the open blocker when the list leads with closed ones" do
      issue = %Issue{
        id: "blocked-ticket",
        identifier: "repo#blocked-ticket",
        title: "blocked ticket",
        state: "todo"
      }

      hydrated = %{
        issue
        | blocked_by: [
            %{id: "28", identifier: "28", state: "Closed"},
            %{id: "41", identifier: "41", state: "rework"},
            %{id: "42", identifier: "42", state: "Closed"}
          ]
      }

      log =
        capture_log(fn ->
          Dispatcher.dispatch_issue(%State{effective_concurrent_agents: 4}, issue, nil, nil,
            issue_fetcher: fn [id] -> {:ok, [%{issue | id: id}]} end,
            blocked_by_hydrator: fn _issue -> {:ok, hydrated} end
          )
        end)

      assert log =~ "blocked by open dependency #41 (rework); 2 terminal dependencies ignored"
      refute log =~ "#28"
      refute log =~ "#42"
    end

    test "records a non-attention dependency decline instead of skipping silently" do
      candidate = issue("dependency-held")
      :ok = AgentPubSub.subscribe_agent(candidate.identifier)

      hydrated = %{candidate | blocked_by: [%{id: "5", identifier: "5", state: "in-progress"}]}

      declined =
        Dispatcher.dispatch_issue(%State{effective_concurrent_agents: 4}, candidate, nil, nil,
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn _issue -> {:ok, hydrated} end
        )

      assert declined.dispatch_declines[candidate.id] == :dependency
      refute Map.has_key?(declined.running, candidate.id)

      assert_receive {:alert,
                      %{
                        name: "dispatch.candidate_declined",
                        reason: reason,
                        needs_attention: false,
                        severity: "info"
                      }},
                     2_000

      assert reason =~ "dependency"
    end

    test "a GitHub-closed blocker no longer holds dispatch" do
      # The shipped default terminal set carries no "closed" entry — that is the
      # whole defect. Pin it here so the test cannot pass on a fixture that
      # happens to list "Closed".
      restore_workflow_file_after_test()

      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        max_concurrent_agents: 4,
        tracker_terminal_states: ["Done", "Cancelled", "Canceled"]
      )

      test_pid = self()

      candidate = %Issue{
        id: "closed-blocker-ticket",
        identifier: "repo#closed-blocker-ticket",
        title: "ticket whose blockers are closed",
        state: "todo",
        selected_backend: "codex"
      }

      # Exactly the live shape `Aiur.GitHub.Client.hydrate_blocked_by/1` returns
      # for blockers closed on GitHub.
      hydrated = %{
        candidate
        | blocked_by: [%{id: "3", identifier: "3", state: "Closed"}, %{id: "7", identifier: "7", state: "Closed"}]
      }

      runner = fn dispatched, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched, recipient, opts})
        :ok
      end

      next_state =
        Dispatcher.dispatch_issue(
          %State{max_concurrent_agents: 4, effective_concurrent_agents: 4},
          candidate,
          nil,
          nil,
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn _issue -> {:ok, hydrated} end,
          runner: runner
        )

      assert_receive {:agent_runner_run, dispatched, _recipient, _opts}, 1000
      assert dispatched.id == candidate.id
      assert Map.has_key?(next_state.running, candidate.id)
      refute Map.has_key?(next_state.dispatch_declines, candidate.id)
    end

    test "holds dispatch (fail-closed) with an attention decline when hydration fails" do
      candidate = issue("hydration-failed")
      :ok = AgentPubSub.subscribe_agent(candidate.identifier)

      declined =
        Dispatcher.dispatch_issue(%State{effective_concurrent_agents: 4}, candidate, nil, nil,
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn _issue -> {:error, :dependencies_unavailable} end
        )

      assert declined.dispatch_declines[candidate.id] == :dependency_hydration_failed

      attention_name = "ticket.#{candidate.id}.agent.attention.dispatch-declined"

      assert_receive {:alert,
                      %{
                        name: ^attention_name,
                        reason: reason,
                        needs_attention: true
                      }},
                     2_000

      assert reason =~ "dependency_hydration_failed"
      refute Map.has_key?(declined.running, candidate.id)
    end

    test "holds dispatch when hydration returns an unexpected shape (fail-closed, no crash)" do
      candidate = issue("hydration-odd-result")
      :ok = AgentPubSub.subscribe_agent(candidate.identifier)

      declined =
        Dispatcher.dispatch_issue(%State{effective_concurrent_agents: 4}, candidate, nil, nil,
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn _issue -> :bogus end
        )

      assert declined.dispatch_declines[candidate.id] == :dependency_hydration_failed

      attention_name = "ticket.#{candidate.id}.agent.attention.dispatch-declined"

      assert_receive {:alert, %{name: ^attention_name, needs_attention: true}}, 2_000
      refute Map.has_key?(declined.running, candidate.id)
    end

    test "dispatches normally when hydration finds no blockers" do
      test_pid = self()

      issue = %Issue{
        id: "unblocked-ticket",
        identifier: "repo#unblocked-ticket",
        title: "unblocked ticket",
        state: "todo",
        selected_backend: "codex"
      }

      runner = fn dispatched, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched, recipient, opts})
        :ok
      end

      next_state =
        Dispatcher.dispatch_issue(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, issue, nil, nil,
          issue_fetcher: fn [id] -> {:ok, [%{issue | id: id}]} end,
          blocked_by_hydrator: fn refreshed -> {:ok, refreshed} end,
          runner: runner
        )

      assert_receive {:agent_runner_run, dispatched, _recipient, _opts}, 1000
      assert dispatched.id == issue.id
      assert Map.has_key?(next_state.running, issue.id)
    end
  end
end
