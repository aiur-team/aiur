Code.require_file("rate_limit_fallback/fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.MaxAgentsCapTest do
  # #4683: with the cap at N and N agents running, every start path is refused.
  use Aiur.TestSupport

  import Aiur.RateLimitFallbackFixture, only: [fallback_entry: 1, reconcile_opts: 1]

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, PauseResume, RateLimitFallback, Slots, State, TrackerTasks}
  alias Aiur.Orchestrator.PauseResume.{ControlRequest, QueuedDispatch, Resume}
  # Keep-agents adoption at the cap is covered in test/aiur/handoff/adopter_test.exs.

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  describe "a pending rework claim" do
    test "holds its slot until its worker starts, so no other path takes it" do
      first = issue("rework-a", "rework")
      second = issue("rework-b", "rework")
      Application.put_env(:aiur, :memory_tracker_issues, [first, second])
      parent = self()
      runner = fn dispatched, _recipient, _opts -> send(parent, {:runner_started, dispatched.id}) end
      opts = [blocked_by_hydrator: &{:ok, &1}, runner: runner]

      # Owner mode runs validation and the tracker write as async tasks, as the live daemon does.
      state = %State{snapshot_key: self(), max_concurrent_agents: 1, effective_concurrent_agents: 1}
      claimed = state |> Dispatcher.dispatch_issue(first, nil, nil, opts) |> settle()

      assert [%{key: {:rework_claim, "rework-a"}}] = Map.values(claimed.tracker_tasks)
      refute Map.has_key?(claimed.running, first.id)
      assert Slots.used_slots(claimed) == 1
      assert Slots.available_slots(claimed) == 0
      assert Slots.max_concurrent_agent_status(claimed).occupied == 1

      # Before #4683 the second claim saw a free slot and both workers started.
      after_second = claimed |> Dispatcher.dispatch_issue(second, nil, nil, opts) |> settle({:dispatch, "rework-b"})
      assert [%{key: {:rework_claim, "rework-a"}}] = Map.values(after_second.tracker_tasks)
      refute Dispatcher.retry_dispatch_ready?(issue("retry", "todo"), after_second, nil)
      assert DispatchPolicy.manual_resume_decision(issue("manual", "todo"), after_second) == {:skip, :fleet_capacity}

      started = settle(after_second)

      assert_receive {:runner_started, "rework-a"}, 1_000
      assert Map.has_key?(started.running, first.id)
      assert Slots.used_slots(started) == 1
      refute_received {:runner_started, "rework-b"}
    end

    test "refuses a manual queued start and a paused-agent resume control request" do
      paused = entry("paused", :paused)
      claim = %{make_ref() => %{key: {:rework_claim, "rework-a"}}}
      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1, running: %{"paused" => paused}, tracker_tasks: claim}

      assert QueuedDispatch.queued_issue_resumability(state, issue("queued", "todo")) == {:error, :max_concurrent_agents_reached}
      assert {{:error, :max_concurrent_agents_reached}, ^state} = ControlRequest.submit_resume_control_request(state, paused, :executor)
    end
  end

  describe "with the fleet full" do
    test "poll dispatch, retry and manual start are refused" do
      state = full_state()
      candidate = issue("todo-1", "todo")
      Application.put_env(:aiur, :memory_tracker_issues, [candidate])

      next = Dispatcher.choose_issues(state, [candidate], runner: fn _, _, _ -> flunk("dispatched past the cap") end)

      refute Map.has_key?(next.running, candidate.id)
      refute Dispatcher.retry_dispatch_ready?(candidate, state, nil)
      assert DispatchPolicy.manual_resume_decision(candidate, state) == {:skip, :fleet_capacity}
    end

    test "reactivation and paused-agent resume are refused" do
      deactivated = entry("deactivated", :deactivated)
      ci_wait = "ci-wait" |> entry(:paused) |> Map.put(:paused_reason, :ci_wait)
      state = full_state(%{"deactivated" => deactivated, "ci-wait" => ci_wait})

      assert {{:error, :max_concurrent_agents_reached}, ^state} = Resume.reactivate_issue(state, deactivated)
      assert {:error, :max_concurrent_agents_reached} = PauseResume.resume_paused_issue_preflight(state, ci_wait)
    end

    test "a backend redispatch of a usage-limited agent is refused" do
      limited = fallback_entry(%{worker_host: nil})
      state = full_state(%{"1" => limited})

      assert {:error, :no_available_slots, _state} = Dispatcher.admit_redispatch(state, limited.issue, nil)
      assert {:ok, _state} = Dispatcher.admit_redispatch(%{state | running: %{"1" => limited}}, limited.issue, nil)
    end

    test "an account handoff of a usage-limited agent is deferred before moving the session" do
      limited =
        fallback_entry(%{usage_limit_session: %{backend: "claude-repl", account_name: "default", session_id: "s-1", cwd: "/repo"}})

      state = full_state(%{"1" => limited})

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            account_config: %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"},
            account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
            account_usage_fetcher: fn "work" -> %{"seven_day" => 35, "five_hour" => 40} end,
            move_session_fun: fn _, _, _, _, _, _ -> flunk("moved a session past the cap") end,
            dispatch_fun: fn _, _, _, _, _ -> flunk("dispatched past the cap") end
          )
        )

      assert result.running["1"] == limited
    end
  end

  # Delivers one in-flight tracker task result (the one under `key`, or the only one).
  defp settle(state, key \\ nil) do
    {ref, _job} = Enum.find(state.tracker_tasks, fn {_ref, job} -> is_nil(key) or job.key == key end)
    assert_receive {^ref, result}, 1_000
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end

  defp full_state(extra \\ %{}) do
    running = Map.merge(%{"active-1" => entry("active-1", :working), "active-2" => entry("active-2", :working)}, extra)
    %State{max_concurrent_agents: 2, effective_concurrent_agents: 2, running: running}
  end

  defp entry(id, status) do
    %{pid: self(), identifier: id, issue: issue(id, "in-progress"), control: %{status: status}, worker_host: nil}
  end

  defp issue(id, state) do
    %Issue{id: id, identifier: id, title: id, state: state, state_labels: [state], selected_backend: "codex", labels: ["agent:#{state}"]}
  end
end
