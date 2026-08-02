defmodule Aiur.Orchestrator.DispatcherTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, State}
  alias Aiur.RunTelemetry.Lifecycle, as: TelemetryLifecycle

  setup do
    previous_meminfo = Application.get_env(:aiur, :meminfo_source_override)
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    previous_fd_sample = Application.get_env(:aiur, :file_descriptor_sample_override)
    previous_proc_stat = Application.get_env(:aiur, :proc_stat_source_override)
    previous_lifecycle_recorder = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)

    on_exit(fn ->
      restore_app_env(:meminfo_source_override, previous_meminfo)
      restore_app_env(:loadavg_source_override, previous_loadavg)
      restore_app_env(:file_descriptor_sample_override, previous_fd_sample)
      restore_app_env(:proc_stat_source_override, previous_proc_stat)
      restore_app_env(:run_telemetry_lifecycle_recorder, previous_lifecycle_recorder)
    end)

    :ok
  end

  defp dispatch_recovery(codex_thrash_budget) do
    %{
      workspace_ownership: %{waits: %{}, ready: %{}},
      codex_thrash_budget: codex_thrash_budget
    }
  end

  defp thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  describe "prewarm dispatch halt" do
    test "emits once while prewarm keeps the fleet on hold and rearms after recovery" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      held = Dispatcher.emit_prewarm_blocked_alert(%State{}, :building)
      assert held.prewarm_blocked_alert_active
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"} = event}, 500
      assert event["reason"] =~ "Prewarm is building"

      assert Dispatcher.emit_prewarm_blocked_alert(held, :building) == held
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100
    end
  end

  describe "CPU headroom recovery integration" do
    test "a second CPU sample re-ramps and consumes restored slots in the same poll" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 8,
        target_load_average: 1.0,
        load_ramp_step: 1
      )

      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      {:ok, samples} =
        Agent.start_link(fn ->
          [
            "cpu 100 0 100 800 0 0 0 0 0 0\nprocs_running 1\n",
            "cpu 120 0 120 960 0 0 0 0 0 0\nprocs_running 1\n"
          ]
        end)

      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        Agent.get_and_update(samples, fn [sample | rest] -> {{:ok, sample}, rest} end)
      end)

      running = Map.new(1..4, fn index -> {"active-#{index}", running_entry("active-#{index}")} end)
      queued = Enum.map(1..4, &issue("queued-#{&1}"))

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 4,
        load_envelope_state: %{last_decrease_ms: 1_000, cpu_snapshot: nil},
        running: running
      }

      first = Dispatcher.maybe_choose_under_load(state, queued, &consume_available_slots/2)
      assert first.effective_concurrent_agents == 5
      assert map_size(first.running) == 5

      second = Dispatcher.maybe_choose_under_load(first, queued, &consume_available_slots/2)
      assert second.effective_concurrent_agents == 8
      assert map_size(second.running) == 8
      assert second.load_envelope_state.last_decrease_ms == nil
    end
  end

  describe "memory admission" do
    test "holds a normal dispatch cycle below the configured floor" do
      write_workflow_file!(Workflow.workflow_file_path(), min_free_memory_mb: 2_048)
      Application.put_env(:aiur, :meminfo_source_override, fn -> {:ok, "MemAvailable: 1048576 kB\n"} end)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      log =
        capture_log(fn ->
          assert %State{running: %{}} = Dispatcher.maybe_choose_under_load(state, [])
        end)

      assert log =~ "aiur_perf memory_hold surface=dispatch available_mb=1024 threshold_mb=2048"
    end
  end

  describe "file-descriptor admission" do
    test "holds below the reserve, logs the sample, and recovers on a later cycle" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      Application.put_env(:aiur, :file_descriptor_sample_override, fn ->
        %{pid: "123", used: 91, limit: 100, available: 9, headroom_ratio: 0.09}
      end)

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      hold_log =
        capture_log(fn ->
          assert %State{running: %{}} = Dispatcher.maybe_choose_under_load(state, [])
        end)

      assert hold_log =~
               "aiur_perf fd_hold surface=dispatch used=91 limit=100 available=9 threshold=10 threshold_pct=10"

      Application.put_env(:aiur, :file_descriptor_sample_override, fn ->
        %{pid: "123", used: 90, limit: 100, available: 10, headroom_ratio: 0.10}
      end)

      recovery_log =
        capture_log(fn ->
          assert %State{running: %{}} = Dispatcher.maybe_choose_under_load(state, [])
        end)

      refute recovery_log =~ "aiur_perf fd_hold"
    end

    test "holds when the sample itself reports descriptor exhaustion" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :exhausted end)

      log =
        capture_log(fn ->
          assert %State{running: %{}} =
                   Dispatcher.maybe_choose_under_load(
                     %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
                     []
                   )
        end)

      assert log =~
               "aiur_perf fd_hold surface=dispatch status=exhausted used=unknown limit=unknown available=0 threshold=unknown threshold_pct=10"
    end
  end

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

      assert_receive {:lifecycle_recorded, :lifecycle, attributes, _opts}
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

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
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

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
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

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
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

  describe "redispatch_ready?/4" do
    test "treats the current issue's worker slot as a transferable reservation" do
      write_workflow_file!(Workflow.workflow_file_path(),
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      state = %State{
        running: %{
          issue.id => %{
            issue: issue,
            worker_host: "worker-a",
            control: %{status: :working}
          }
        }
      }

      assert :ok = Dispatcher.redispatch_ready?(state, issue, "worker-a", now_ms: 1_000)
      assert thrash_budget(state) == %{}
    end

    test "rejects a swap before teardown when the next restart would trip thrash protection" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      state = %State{
        dispatch_recovery: dispatch_recovery(%{issue.id => %{window_start_ms: 0, count: 6}})
      }

      assert {:error, :thrash_circuit_open} =
               Dispatcher.redispatch_ready?(state, issue, nil, now_ms: 1_000)

      assert get_in(thrash_budget(state), [issue.id, :count]) == 6
    end

    test "does not silently migrate a remote workspace when its worker is unavailable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      assert {:error, :preferred_worker_unavailable} =
               Dispatcher.redispatch_ready?(%State{}, issue, "worker-b", now_ms: 1_000)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  defp consume_available_slots(state, issues) do
    Enum.reduce(issues, state, fn issue, acc ->
      if DispatchPolicy.should_dispatch_issue?(issue, acc) do
        %{acc | running: Map.put(acc.running, issue.id, running_entry(issue.id))}
      else
        acc
      end
    end)
  end

  defp issue(id), do: %Issue{id: id, identifier: "repo##{id}", title: id, state: "todo"}

  defp dispatch_decision!(issue) do
    test_pid = self()

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

    assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
    attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
    assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id

    {_session_backend, _remote_control?, session_opts} =
      SessionLifecycle.resolve_session_options(issue, runner_opts, nil)

    assert {:ok, session} =
             SessionLifecycle.start_agent_session(
               "/ws",
               session_opts,
               fn _workspace, _opts -> {:ok, %{model: "gpt-5.6-terra", thread_id: "thread-dispatch"}} end
             )

    executor = ToolExecutor.build(issue, nil, nil, session)

    assert executor.("emit_event", %{
             "name" => "decision.requested",
             "message" => "Keep the dispatch attempt?",
             "payload" => %{"blocking" => true}
           })["success"] == true

    [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == issue.id))
    {attempt_id, decision}
  end

  defp running_entry(id) do
    %{issue: issue(id), control: %{status: :working}, worker_host: nil}
  end

  describe "revalidate_issue_for_dispatch/3" do
    test "returns :ok when issue is found and passes the retry candidate check" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:ok, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, :missing} when the fetcher returns an empty list" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, []} end

      assert {:skip, :missing} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, issue} when the issue is in a terminal state" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "done"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:skip, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:error, reason} when the fetcher fails" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:error, :network_error} end

      assert {:error, :network_error} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "passes through non-Issue values unchanged" do
      assert {:ok, :not_an_issue} =
               Dispatcher.revalidate_issue_for_dispatch(:not_an_issue, nil, nil)
    end
  end
end
