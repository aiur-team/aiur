defmodule Aiur.Orchestrator.Dispatcher.ThrashAndProvenanceTest do
  use Aiur.DispatcherTestSupport

  describe "check_thrash_budget/3" do
    test "counts dispatches within window and trips over the threshold" do
      state = %State{}
      issue_id = "issue-1"
      now_ms = 0
      # Default threshold is 6; 7 calls should trip
      {state, result} =
        Enum.reduce(1..7, {state, nil}, fn _i, {acc_state, _} ->
          case Dispatcher.check_thrash_budget(acc_state, issue_id, now_ms) do
            {:ok, next} -> {next, :ok}
            {:trip, next} -> {next, :trip}
          end
        end)

      assert result == :trip
      assert get_in(thrash_budget(state), [issue_id, :count]) == 6
      assert get_in(thrash_budget(state), [issue_id, :tripped]) == :window
    end

    test "resets the window when enough time has lapsed" do
      state = %State{
        dispatch_recovery: dispatch_recovery(%{"issue-1" => %{window_start_ms: 0, count: 10}})
      }

      # 61_000ms > default 60-second window
      assert {:ok, next_state} =
               Dispatcher.check_thrash_budget(state, "issue-1", 61_000)

      assert get_in(thrash_budget(next_state), ["issue-1", :count]) == 1
      assert get_in(thrash_budget(next_state), ["issue-1", :window_start_ms]) == 61_000
    end

    test "accumulates count within the same window" do
      state = %State{
        dispatch_recovery: dispatch_recovery(%{"issue-1" => %{window_start_ms: 0, count: 2}})
      }

      assert {:ok, next_state} = Dispatcher.check_thrash_budget(state, "issue-1", 1_000)
      assert get_in(thrash_budget(next_state), ["issue-1", :count]) == 3
    end
  end

  describe "reset_thrash_budget/2" do
    test "removes the entry for the given issue_id" do
      state = %State{
        dispatch_recovery:
          dispatch_recovery(%{
            "issue-1" => %{window_start_ms: 0, count: 5},
            "issue-2" => %{window_start_ms: 0, count: 1}
          })
      }

      result = Dispatcher.reset_thrash_budget(state, "issue-1")

      refute Map.has_key?(thrash_budget(result), "issue-1")
      assert Map.has_key?(thrash_budget(result), "issue-2")
    end
  end

  describe "dispatch attempt provenance" do
    test "captures a first rework head asynchronously before starting the runner" do
      test_pid = self()
      issue = %Issue{id: "rework-first", identifier: "repo#rework-first", state: "rework"}

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
      assert_receive {:rework_head_lookup_started, "repo#rework-first", lookup_pid}, 1000
      refute_receive {:rework_runner_started, _, _, _}, 20
      send(lookup_pid, :finish_lookup)

      assert_receive {:worker_runtime_info, issue_id, %{rework_head_sha: "captured-head"}}, 1000
      assert issue_id == issue.id

      assert_receive {:rework_runner_started, ^issue, _recipient, runner_opts}, 1000
      assert Keyword.fetch!(runner_opts, :rework_head_sha) == "captured-head"

      assert {:noreply, captured_state} =
               State.handle_worker_runtime_info(
                 next_state,
                 issue.id,
                 %{rework_head_sha: "captured-head"}
               )

      assert captured_state.running[issue.id].rework_head_sha == "captured-head"
    end

    test "preserves the original rework head on retry dispatch" do
      test_pid = self()
      issue = %Issue{id: "rework-retry", identifier: "repo#rework-retry", state: "rework"}

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:rework_retry_runner, dispatched_issue, recipient, opts})
        :ok
      end

      next_state =
        Dispatcher.do_dispatch_issue(
          %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
          issue,
          2,
          nil,
          runner: runner,
          rework_head_sha: "head-before-first-attempt"
        )

      assert_receive {:rework_retry_runner, ^issue, _recipient, runner_opts}, 1000
      assert Keyword.fetch!(runner_opts, :rework_head_sha) == "head-before-first-attempt"
      assert next_state.running[issue.id].rework_head_sha == "head-before-first-attempt"
    end

    test "captures a baseline PR head for a first active-state run" do
      test_pid = self()
      issue = %Issue{id: "active-first", identifier: "repo#active-first", state: "in-progress"}

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:active_first_runner, dispatched_issue, recipient, opts})
        :ok
      end

      next_state =
        Dispatcher.do_dispatch_issue(
          %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
          issue,
          1,
          nil,
          runner: runner,
          rework_head_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "existing-head"}}} end
        )

      assert_receive {:active_first_runner, ^issue, _recipient, runner_opts}, 1000
      assert Keyword.fetch!(runner_opts, :rework_head_sha) == "existing-head"
      assert next_state.running[issue.id].rework_head_sha in [:pending, "existing-head"]
    end

    test "carries the current fallback fence rather than a stale redispatch snapshot" do
      issue = %Issue{id: "fallback-retry", identifier: "repo#fallback-retry", state: "todo", selected_backend: "claude"}

      current_fence = %{
        generation: 9,
        authoritative_state: "rework",
        pending_item_ids: MapSet.new([872, 874, 887, 891, 999]),
        opened_at: DateTime.utc_now()
      }

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        running: %{
          issue.id => %{
            issue: issue,
            identifier: issue.identifier,
            control: %{status: :completed},
            lifecycle_fence: current_fence,
            redispatch_safety: %{workspace_path: "/workspaces/fallback"},
            rate_limit_fallback_replacement: true
          }
        }
      }

      next_state = Dispatcher.do_dispatch_issue(state, issue, 1, nil, runner: fn _, _, _ -> :ok end)

      assert next_state.running[issue.id].lifecycle_fence == current_fence
      assert next_state.running[issue.id].workspace_path == "/workspaces/fallback"
    end

    test "keeps local-only provider transports off configured SSH workers" do
      test_pid = self()
      write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-a"])

      issue = %Issue{
        id: "local-provider",
        identifier: "repo#local-provider",
        state: "todo",
        selected_backend: "kimi"
      }

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      next_state =
        Dispatcher.do_dispatch_issue(
          %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
          issue,
          nil,
          nil,
          runner: runner
        )

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}, 1000
      assert Keyword.fetch!(runner_opts, :worker_host) == nil
      assert get_in(next_state.running, [issue.id, :worker_host]) == nil
    end

    test "records the dispatch-time complexity estimate" do
      test_pid = self()

      Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attributes, opts ->
        send(test_pid, {:lifecycle_recorded, kind, attributes, opts})
        :ok
      end)

      issue = %Issue{
        id: "complexity-dispatch",
        identifier: "repo#complexity-dispatch",
        state: "todo",
        labels: ["complexity:4"],
        selected_backend: "codex"
      }

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        runner: runner
      )

      assert_receive {:lifecycle_recorded, :lifecycle, attributes, _opts}, 1000
      assert attributes.event == "dispatch"
      assert attributes.complexity == 4
    end

    test "consumes the ownership wakeup envelope when redispatching" do
      issue = %Issue{id: "ownership-envelope", identifier: "repo#ownership-envelope", state: "todo", selected_backend: "codex"}
      test_pid = self()
      write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-a"])

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        dispatch_recovery: %{
          workspace_ownership: %{
            waits: %{},
            ready: %{
              issue.id => %{
                issue_id: issue.id,
                worker_host: "worker-a",
                retry_attempt: 3,
                prior_work: true,
                tracker_identity: "repo#ownership-envelope"
              }
            }
          },
          codex_thrash_budget: %{}
        }
      }

      next_state = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: runner)

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}, 1000
      assert Keyword.fetch!(runner_opts, :worker_host) == "worker-a"
      assert Keyword.fetch!(runner_opts, :attempt) == 3
      assert Keyword.fetch!(runner_opts, :prior_work) == true
      assert next_state.dispatch_recovery.workspace_ownership.ready == %{}
    end

    test "telemetry-disabled dispatch options reach accepted Decision provenance" do
      identifier = "dispatcher-decision-#{System.unique_integer([:positive])}"
      issue = %Issue{id: identifier, identifier: identifier, state: "todo", selected_backend: "codex"}
      test_pid = self()

      enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
      original_pt = :persistent_term.get(enabled_key, :unset)

      on_exit(fn ->
        case original_pt do
          :unset -> :persistent_term.erase(enabled_key)
          value -> :persistent_term.put(enabled_key, value)
        end
      end)

      :persistent_term.put(enabled_key, false)
      refute TelemetryLifecycle.enabled?()

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      next_state = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: runner)

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}, 1000
      assert attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
      assert is_binary(attempt_id)
      assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id

      start_fun = fn _workspace, _opts -> {:ok, %{model: "gpt-5.6-terra", thread_id: "thread-dispatch"}} end

      {_session_backend, _remote_control?, session_opts} =
        SessionLifecycle.resolve_session_options(issue, runner_opts, nil)

      assert Keyword.fetch!(session_opts, :attempt_id) == attempt_id

      assert {:ok, session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 session_opts,
                 start_fun
               )

      executor = ToolExecutor.build(issue, nil, nil, session)

      assert executor.("emit_event", %{
               "name" => "decision.requested",
               "message" => "Keep the dispatch attempt?",
               "payload" => %{"blocking" => true}
             })["success"] == true

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance.attempt_id == attempt_id
    end

    test "identifier-less dispatch hashes the stable issue ID for its attempt identity" do
      issue_id = "memory-dispatch-#{System.unique_integer([:positive])}"
      issue = %Issue{id: issue_id, identifier: nil, state: "todo", selected_backend: "codex"}
      test_pid = self()

      enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
      original_pt = :persistent_term.get(enabled_key, :unset)

      on_exit(fn ->
        case original_pt do
          :unset -> :persistent_term.erase(enabled_key)
          value -> :persistent_term.put(enabled_key, value)
        end
      end)

      :persistent_term.put(enabled_key, false)
      refute TelemetryLifecycle.enabled?()

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      next_state = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: runner)

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}, 1000
      assert attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
      expected_ticket = "ticket-" <> (:crypto.hash(:sha256, issue_id) |> Base.encode16(case: :lower))

      assert String.starts_with?(attempt_id, "#{expected_ticket}:")
      refute String.contains?(attempt_id, issue_id)
      assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id
    end

    test "unsafe, empty, and overlong tracker identifiers reach durable Decision provenance" do
      cases = [
        {"unsafe", "repo#1 ticket/123"},
        {"empty", ""},
        {"overlong", String.duplicate("tracker-identifier-", 20)}
      ]

      attempt_tickets =
        Enum.map(cases, fn {label, identifier} ->
          issue_id = "memory-#{label}-#{System.unique_integer([:positive])}"
          issue = %Issue{id: issue_id, identifier: identifier, state: "todo", selected_backend: "codex"}

          {attempt_id, decision} = dispatch_decision!(issue)
          dispatch_identity = if identifier == "", do: issue_id, else: identifier
          expected_ticket = "ticket-" <> (:crypto.hash(:sha256, dispatch_identity) |> Base.encode16(case: :lower))

          assert decision.provenance.attempt_id == attempt_id
          assert byte_size(attempt_id) <= 256
          assert [^expected_ticket, suffix] = String.split(attempt_id, ":", parts: 2)
          assert suffix =~ ~r/\A[A-Za-z0-9_-]+\z/

          if identifier != "", do: refute(String.contains?(attempt_id, identifier))

          expected_ticket
        end)

      assert length(Enum.uniq(attempt_tickets)) == length(attempt_tickets)
    end
  end
end
