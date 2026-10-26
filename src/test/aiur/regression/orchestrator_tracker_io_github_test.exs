Code.require_file("../../support/tracker_io_poll_barrier.exs", __DIR__)

defmodule Aiur.Regression.OrchestratorTrackerIoGithubTest do
  use Aiur.TestSupport

  alias Aiur.TestSupport.Isolation

  import Aiur.TrackerIoPollBarrier, only: [await_owned_poll: 2, await_poll_finished: 1]

  alias Aiur.{DispatchBudgetStore, Issue, Orchestrator}
  alias Aiur.GitHub.{DispatchAuthorization, ReadCache}

  alias Aiur.Orchestrator.{OperatorMessages, PriorityControl, TrackerTasks}

  @control_budget_ms 5_000

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

  test "GitHub firehose and CI reads leave real handlers responsive", %{
    server: server,
    issue: issue,
    token: token
  } do
    # Settle startup reads before changing the tracker behind them.
    await_orchestrator_state(server, &(not TrackerTasks.running?(&1, :startup_workspace_cleanup)))

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      max_concurrent_agents: 4
    )

    put_test_env(:github_client_module, SlowTracker)
    put_test_env(:github_transport_test_options, plug: {Req.Test, __MODULE__})
    put_test_env(:github_budget_enabled?, false)
    put_test_env(:tracker_io_test_result, {:ok, [issue]})
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-tracker-io-token")
    cache_key = {Aiur.GitHub.Access.Token, :resolved_token}
    previous_cache = :persistent_term.get(cache_key, :unset)
    :persistent_term.erase(cache_key)

    on_exit(fn ->
      if previous_token,
        do: System.put_env("GITHUB_TOKEN", previous_token),
        else: System.delete_env("GITHUB_TOKEN")

      if previous_cache == :unset,
        do: :persistent_term.erase(cache_key),
        else: :persistent_term.put(cache_key, previous_cache)
    end)

    ReadCache.reset()
    owner = self()
    seen = start_supervised!({Agent, fn -> MapSet.new() end})

    Req.Test.stub(__MODULE__, fn conn ->
      stage =
        cond do
          String.ends_with?(conn.request_path, "/events") -> :firehose
          String.ends_with?(conn.request_path, "/issues") -> :ci_targets
          true -> :other
        end

      hold? =
        Agent.get_and_update(seen, fn done ->
          {stage != :other and not MapSet.member?(done, stage), MapSet.put(done, stage)}
        end)

      if hold? do
        send(owner, {:github_stage_started, stage, self()})
        receive do: (:release -> :ok)
      end

      Req.Test.json(conn, [])
    end)

    for client <- [server, Process.whereis(Aiur.GitHub.Listeners.Firehose)],
        do: Req.Test.allow(__MODULE__, self(), client)

    patterns = [
      {Aiur.Events.GithubFirehose, :poll, :_},
      {Aiur.Events.GithubCIPoller, :poll, :_},
      {Aiur.Tracker, :fetch_candidate_issues, :_}
    ]

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)
    send(server, :run_poll_cycle)

    for stage <- [:firehose, :ci_targets] do
      receive_barrier({:github_stage_started, ^stage, worker})
      refute worker == server

      assert {:ok, _id} =
               OperatorMessages.send_operator_message(server, issue.identifier, %{
                 kind: :text,
                 body: "during #{stage}"
               })

      send(worker, :release)
    end

    candidate_worker = await_owned_poll(server, token)
    send(candidate_worker, {:release_poll, token})
    state = await_poll_finished(server)
    assert state.last_polled_issues[issue.id] == issue
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})

    Enum.each(patterns, fn {module, function, _} ->
      refute_received {:trace, ^server, :call, {^module, ^function, _args}}
    end)
  end

  test "a converted control handler cannot call tracker writes in the owner", %{
    server: server,
    issue: issue,
    token: token
  } do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    put_test_env(:github_client_module, SlowTracker)
    pattern = {Aiur.Tracker, :add_label, :_}
    :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern(pattern, false, [:local]) end)
    control = Task.async(fn -> PriorityControl.prioritize_agent(server, issue.identifier) end)
    receive_barrier({:label_write_started, ^token, writer})
    refute writer == server

    assert {:ok, _id} =
             OperatorMessages.send_operator_message(server, issue.identifier, %{
               kind: :text,
               body: "during label write"
             })

    send(writer, {:release_write, token})
    assert Task.await(control) == {:ok, :prioritized}
    assert :sys.get_state(server).running[issue.id].issue.priority == 1
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})
    refute_received {:trace, ^server, :call, {Aiur.Tracker, :add_label, _args}}
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

  defp start_owned_task(fun) do
    child = Supervisor.child_spec({Task, fun}, id: make_ref())
    Isolation.start_owned!(child)
  end
end
