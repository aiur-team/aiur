Code.require_file("../../support/tracker_io_poll_barrier.exs", __DIR__)

defmodule Aiur.Regression.OrchestratorTrackerIoDispatchTest do
  use Aiur.TestSupport

  alias Aiur.TestSupport.Isolation

  import Aiur.TrackerIoPollBarrier, only: [await_owned_poll: 2]

  alias Aiur.{DispatchBudgetStore, Issue, Orchestrator}
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.Orchestrator.Dispatcher

  alias Aiur.Orchestrator.OperatorMessages

  @control_budget_ms 5_000
  @dispatch_authorization_patterns [
    {DispatchAuthorization, :authorize, :_},
    {DispatchAuthorization, :authorize_label_applier, :_},
    {DispatchAuthorization, :fetch_timeline, :_}
  ]

  # Production control budget tolerates local fsyncs under load; held tracker barriers still expose blocked handlers.

  # The live wedge held the owner in `fetch_timeline` under
  # `authorize_label_applier`, so the guard traces dispatch authorization
  # directly, not only through the tracker callbacks that reach it.

  defmodule SlowTracker do
    def fetch_candidate_issues do
      {owner, token} = Application.fetch_env!(:aiur, :tracker_io_test_barrier)
      send(owner, {:poll_started, token, self()})

      receive do: ({:release_poll, ^token} ->
                     Application.get_env(
                       :aiur,
                       :tracker_io_test_result,
                       {:error, :controlled_poll_failure}
                     ))
    end

    def add_label(_id, _label) do
      {owner, token} = Application.fetch_env!(:aiur, :tracker_io_test_barrier)

      if Application.get_env(:aiur, :tracker_io_test_fast_writes, false) do
        :ok
      else
        send(owner, {:label_write_started, token, self()})
        receive do: ({:release_write, ^token} -> :ok)
      end
    end

    def remove_label(_id, _label), do: :ok

    def update_issue_state(_id, _state), do: :ok

    def fetch_issue_states_by_ids(_ids) do
      case Application.get_env(:aiur, :tracker_io_test_validation_barrier) do
        {owner, token} ->
          send(owner, {:validation_started, token, self()})
          receive do: ({:release_validation, ^token} -> :ok)

        nil ->
          :ok
      end

      issue = Application.fetch_env!(:aiur, :tracker_io_test_issue)
      {:ok, [maybe_authorize(issue, Application.get_env(:aiur, :tracker_io_test_authorization))]}
    end

    # Stands in for the timeline read behind `DispatchAuthorization.authorize/5`; it verifies, since a denial emits a real alert from the reader (#4009).
    defp maybe_authorize(issue, nil), do: issue

    defp maybe_authorize(issue, {owner, token}) do
      event = %{
        "id" => 1,
        "event" => "labeled",
        "created_at" => "2026-01-01T00:00:00Z",
        "label" => %{"name" => "agent:todo"},
        "actor" => %{"login" => "operator"}
      }

      request_fun = fn _request ->
        send(owner, {:timeline_read_started, token, self()})

        receive do: ({:release_timeline, ^token} ->
                       {:ok, %{status: 200, body: [event], headers: []}})
      end

      DispatchAuthorization.authorize(issue, "owner", "repo", "agent",
        request_fun: request_fun,
        token: "test-token",
        allowed_users: ["operator"]
      )
    end

    def fetch_issues_by_states(_states, _opts), do: {:ok, []}

    def graphql(_query, variables) do
      {owner, _token} = Application.fetch_env!(:aiur, :tracker_io_test_barrier)
      if variables[:stateName], do: send(owner, {:handoff_state_lookup, variables.stateName})

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "state" => %{"name" => "In Progress"},
             "team" => %{"states" => %{"nodes" => [%{"id" => "review-state"}]}}
           },
           "issueUpdate" => %{"success" => true}
         }
       }}
    end
  end

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "linear",
      max_concurrent_agents: 4
    )

    put_test_env(:linear_client_module, SlowTracker)
    put_test_env(:control_api_call_timeout_ms, @control_budget_ms)
    put_test_env(:operator_message_call_timeout_ms, @control_budget_ms)

    token = make_ref()
    put_test_env(:tracker_io_test_barrier, {self(), token})

    issue = %Issue{
      id: "tracker-io-3213",
      identifier: "IO-3213",
      title: "Tracker I/O regression",
      state: "In Progress"
    }

    put_test_env(:tracker_io_test_issue, issue)

    put_test_env(
      :dispatch_budget_store_path,
      Path.join(System.tmp_dir!(), "tracker-io-budget-#{System.unique_integer([:positive])}.json")
    )

    budget_path = DispatchBudgetStore.path_for()
    on_exit(fn -> File.rm(budget_path) end)
    :ok = DispatchBudgetStore.put_lifetime(issue.id, 3)

    server = start_supervised!({Orchestrator, initial_poll?: false})

    worker = start_owned_task(fn -> receive do: (:stop -> :ok) end)

    :sys.replace_state(server, fn state ->
      entry = %{
        issue: issue,
        identifier: issue.identifier,
        pid: worker,
        ref: make_ref(),
        started_at: DateTime.utc_now(),
        control: %{
          status: :working,
          generation: 1,
          version: 1,
          can_interrupt: true,
          safe_checkpoints: [:notification]
        }
      }

      %{
        state
        | running: %{issue.id => entry},
          last_polled_issues: %{issue.id => issue},
          claimed: MapSet.new([issue.id]),
          snapshot_ready?: true
      }
    end)

    on_exit(fn ->
      send(worker, :stop)

      if Process.alive?(server) do
        :sys.replace_state(server, fn state -> %{state | running: %{}} end)
      end
    end)

    {:ok, server: server, issue: issue, token: token}
  end

  test "successful dispatch results apply through the real handler without tracker I/O", %{server: server, token: token} do
    candidate = %Issue{id: "new-3213", identifier: "NEW-3213", title: "new", state: "Todo"}
    put_test_env(:tracker_io_test_issue, candidate)
    put_test_env(:tracker_io_test_validation_barrier, {self(), token})
    owner = self()
    pattern = {Aiur.Tracker, :fetch_issue_states_by_ids, :_}
    :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern(pattern, false, [:local]) end)

    :sys.replace_state(server, fn state ->
      Dispatcher.dispatch_issue(%{state | effective_concurrent_agents: 4}, candidate, nil, nil,
        dispatch_result_fun: fn current ->
          send(owner, {:dispatch_complete, current.dispatch_declines})
          current
        end,
        runner: fn dispatched, _, _ ->
          send(owner, {:new_runner_started, dispatched.id, self()})
          receive do: (:stop -> :ok)
        end,
        blocked_by_hydrator: fn value -> {:ok, value} end
      )
    end)

    receive_barrier({:validation_started, ^token, validator})
    refute validator == server
    assert {:ok, _id} = OperatorMessages.send_operator_message(server, "IO-3213", %{kind: :text, body: "during successful validation"})
    send(validator, {:release_validation, token})
    receive_barrier({:dispatch_complete, declines})
    assert declines == %{}
    receive_barrier({:new_runner_started, "new-3213", runner})
    on_exit(fn -> send(runner, :stop) end)
    state = :sys.get_state(server)
    assert state.running[candidate.id].pid == runner
    assert MapSet.member?(state.claimed, candidate.id)
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})
    refute_received {:trace, ^server, :call, {Aiur.Tracker, :fetch_issue_states_by_ids, _args}}
  end

  test "dispatch-time authorization reads the timeline outside the owner", %{server: server, token: token} do
    candidate = %Issue{id: "auth-3213", identifier: "AUTH-3213", title: "authorize", state: "Todo", state_labels: ["agent:todo"]}
    put_test_env(:tracker_io_test_issue, candidate)
    put_test_env(:tracker_io_test_authorization, {self(), token})
    DispatchAuthorization.clear_cache()
    owner = self()
    {:ok, stray} = start_supervised({Task, fn -> SlowTracker.fetch_issue_states_by_ids([candidate.id]) end})
    send(self(), receive_barrier({:timeline_read_started, ^token, ^stray}))
    patterns = [{Aiur.Tracker, :fetch_issue_states_by_ids, :_} | @dispatch_authorization_patterns]
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)

    :sys.replace_state(server, fn state ->
      Dispatcher.dispatch_issue(%{state | effective_concurrent_agents: 4}, candidate, nil, nil,
        dispatch_result_fun: fn current ->
          send(owner, {:dispatch_complete, current.dispatch_declines})
          current
        end,
        runner: fn _dispatched, _, _ ->
          send(owner, {:auth_runner_started, self()})
          receive do: (:stop -> :ok)
        end,
        blocked_by_hydrator: fn value -> {:ok, value} end
      )
    end)

    reader = Aiur.TrackerIoPollBarrier.await_dispatch_timeline_read(server, candidate.id, token)
    # The owner still answers a control while the timeline read is held.
    assert is_list(Orchestrator.status(server, @control_budget_ms))
    send(reader, {:release_timeline, token})
    assert receive_barrier({:dispatch_complete, _declines}) == {:dispatch_complete, %{}}
    receive_barrier({:auth_runner_started, runner})
    on_exit(fn -> send(runner, :stop) end)
    assert_no_handler_io(server, patterns)
  end

  test "orchestrator shutdown reaps a held tracker task", %{server: server, token: token} do
    stray = start_owned_task(fn -> SlowTracker.fetch_candidate_issues() end)
    send(server, :run_poll_cycle)
    tracker = await_owned_poll(server, token)
    monitor = Process.monitor(tracker)
    on_exit(fn -> Enum.each([stray, tracker], &Process.exit(&1, :kill)) end)
    assert GenServer.stop(server) == :ok
    receive_barrier({:DOWN, ^monitor, :process, ^tracker, :killed})
    refute Process.alive?(tracker)
  end

  defp put_test_env(key, value) do
    previous = Application.fetch_env(:aiur, key)
    Application.put_env(:aiur, key, value)

    on_exit(fn ->
      case previous do
        {:ok, original} -> Application.put_env(:aiur, key, original)
        :error -> Application.delete_env(:aiur, key)
      end
    end)
  end

  defp assert_no_handler_io(server, patterns) do
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})
    :erlang.trace(server, false, [:call])
    Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))

    Enum.each(patterns, fn {module, function, _arity} ->
      refute_received {:trace, ^server, :call, {^module, ^function, _args}}, "an orchestrator handler performed remote work: #{inspect(module)}.#{function}"
    end)
  end

  defp start_owned_task(fun) do
    child = Supervisor.child_spec({Task, fun}, id: make_ref())
    Isolation.start_owned!(child)
  end
end
