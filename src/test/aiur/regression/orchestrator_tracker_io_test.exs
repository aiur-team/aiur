Code.require_file("../../support/tracker_io_poll_barrier.exs", __DIR__)

defmodule Aiur.Regression.OrchestratorTrackerIoTest do
  use Aiur.TestSupport

  import Aiur.TrackerIoPollBarrier, only: [await_poll_finished: 1]

  alias Aiur.{AgentQueueStore, DispatchBudgetStore, Issue, Orchestrator}
  alias Aiur.GitHub.{Config, DispatchAuthorization, ReadCache, Transport}
  alias Aiur.Orchestrator.{Dispatcher, GlobalPause, OperatorMessages, PauseResume, PriorityControl, RetryEngine, SnapshotStore, StatusReport}

  # Handlers answer inside the production control budget. A short owner step
  # still fsyncs its durable stores, which took seconds on a loaded host, so a
  # tighter budget timed out without any tracker work in the owner. The tracker
  # barriers in these cases are held until released, so a handler that blocks
  # on the tracker still never answers.
  @control_budget_ms 5_000
  @answer_ms @control_budget_ms + 1_000

  # The live wedge held the owner in `fetch_timeline` under
  # `authorize_label_applier`, so the guard traces dispatch authorization
  # directly, not only through the tracker callbacks that reach it.
  @dispatch_authorization_patterns [
    {DispatchAuthorization, :authorize, :_},
    {DispatchAuthorization, :authorize_label_applier, :_},
    {DispatchAuthorization, :fetch_timeline, :_}
  ]

  defmodule SlowTracker do
    def fetch_candidate_issues do
      {owner, token} = Application.fetch_env!(:aiur, :tracker_io_test_barrier)
      send(owner, {:poll_started, token, self()})

      receive do
        {:release_poll, ^token} -> Application.get_env(:aiur, :tracker_io_test_result, {:error, :controlled_poll_failure})
      end
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

    # The GitHub client authorizes every revalidated issue with a timeline read
    # (`Aiur.GitHub.Issues` -> `DispatchAuthorization.authorize/5`). This stands
    # in for that read so a case can hold it and see which process runs it.
    defp maybe_authorize(issue, nil), do: issue

    defp maybe_authorize(issue, {owner, token}) do
      request_fun = fn _request ->
        send(owner, {:timeline_read_started, token, self()})
        receive do: ({:release_timeline, ^token} -> {:ok, %{status: 200, body: [], headers: []}})
      end

      _verdict = DispatchAuthorization.authorize(issue, "owner", "repo", "agent", request_fun: request_fun, token: "test-token")
      issue
    end

    def fetch_issues_by_states(_states, _opts), do: {:ok, []}

    def graphql(_query, variables) do
      {owner, _token} = Application.fetch_env!(:aiur, :tracker_io_test_barrier)
      if variables[:stateName], do: send(owner, {:handoff_state_lookup, variables.stateName})

      {:ok,
       %{
         "data" => %{
           "issue" => %{"state" => %{"name" => "In Progress"}, "team" => %{"states" => %{"nodes" => [%{"id" => "review-state"}]}}},
           "issueUpdate" => %{"success" => true}
         }
       }}
    end
  end

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "linear", max_concurrent_agents: 4)
    put_test_env(:linear_client_module, SlowTracker)
    put_test_env(:control_api_call_timeout_ms, @control_budget_ms)
    put_test_env(:operator_message_call_timeout_ms, @control_budget_ms)

    token = make_ref()
    put_test_env(:tracker_io_test_barrier, {self(), token})
    issue = %Issue{id: "tracker-io-3213", identifier: "IO-3213", title: "Tracker I/O regression", state: "In Progress"}
    put_test_env(:tracker_io_test_issue, issue)
    put_test_env(:dispatch_budget_store_path, Path.join(System.tmp_dir!(), "tracker-io-budget-#{System.unique_integer([:positive])}.json"))
    budget_path = DispatchBudgetStore.path_for()
    on_exit(fn -> File.rm(budget_path) end)
    :ok = DispatchBudgetStore.put_lifetime(issue.id, 3)

    server = start_supervised!({Orchestrator, initial_poll?: false})

    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    :sys.replace_state(server, fn state ->
      entry = %{
        issue: issue,
        identifier: issue.identifier,
        pid: worker,
        ref: make_ref(),
        started_at: DateTime.utc_now(),
        control: %{status: :working, generation: 1, version: 1, can_interrupt: true, safe_checkpoints: [:notification]}
      }

      %{state | running: %{issue.id => entry}, last_polled_issues: %{issue.id => issue}, claimed: MapSet.new([issue.id]), snapshot_ready?: true}
    end)

    on_exit(fn ->
      send(worker, :stop)

      if Process.alive?(server) do
        :sys.replace_state(server, fn state -> %{state | running: %{}} end)
      end
    end)

    {:ok, server: server, issue: issue, token: token}
  end

  test "candidate tracker work runs outside the orchestrator", %{server: server, token: token} do
    patterns =
      [
        {Aiur.Tracker, :fetch_candidate_issues, :_},
        {Aiur.Tracker, :fetch_issues_by_states, :_},
        {Aiur.Tracker, :fetch_issue_states_by_ids, :_},
        {Aiur.Tracker, :fetch_issue_states_by_ids_conditional, :_},
        {Aiur.Tracker, :update_issue_state, :_},
        {Aiur.Tracker, :add_label, :_},
        {Aiur.Tracker, :remove_label, :_},
        {Aiur.GitHub.Tracker, :fetch_candidate_issues_conditional, :_},
        {Aiur.GitHub.Tracker, :hydrate_blocked_by, :_},
        {Aiur.Events.GithubFirehose, :poll, :_},
        {Aiur.Events.GithubCIPoller, :poll, :_}
      ] ++ @dispatch_authorization_patterns

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    send(server, :run_poll_cycle)
    receive_barrier({:poll_started, ^token, tracker_pid})

    try do
      refute tracker_pid == server, "the tracker is executing in the orchestrator handler"
    after
      send(tracker_pid, {:release_poll, token})
      await_poll_finished(server)
      delivery = :erlang.trace_delivered(server)
      receive_barrier({:trace_delivered, ^server, ^delivery})
      :erlang.trace(server, false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))

      Enum.each(patterns, fn {module, function, _arity} ->
        refute_received {:trace, ^server, :call, {^module, ^function, _args}}, "an orchestrator handler performed remote work"
      end)
    end
  end

  test "exhausted rework reads stay outside the owner", %{server: server, issue: issue, token: token} do
    parent = self()

    scheduling =
      Task.async(fn ->
        :sys.replace_state(server, fn state ->
          RetryEngine.schedule_issue_retry(state, issue.id, Aiur.Config.max_retry_attempts() + 1, %{
            identifier: issue.identifier,
            error: "agent exited after pushing rework",
            rework_head_sha: "old-head",
            open_pr_fetcher: fn _ ->
              send(parent, {:handoff_started, token, self()})
              receive do: ({:release_handoff, ^token} -> {:ok, %{"head" => %{"sha" => "new-head"}}})
            end,
            commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end,
            delay_type: :failure
          })
        end)
      end)

    receive_barrier({:handoff_started, ^token, tracker_pid})

    try do
      refute tracker_pid == server
      assert {:ok, _snapshot, _freshness} = Orchestrator.fleet_view(server, @control_budget_ms, fleet_rows?: true)
    after
      send(tracker_pid, {:release_handoff, token})
      Task.await(scheduling)
      await_orchestrator_state(server, &(map_size(&1.tracker_tasks) == 0))
    end

    assert_received {:handoff_state_lookup, "human-review"}
  end

  test "public controls, enqueue and runner claim finish while the poll is held", %{server: server, issue: issue, token: token} do
    patterns = trace_handler_io(server)
    assert {:ok, seeded_id} = OperatorMessages.send_operator_message(server, issue.identifier, %{kind: :text, body: "seeded before poll"})
    state = :sys.get_state(server)
    :ok = SnapshotStore.publish(server, StatusReport.snapshot_payload(state), state)
    send(server, :run_poll_cycle)
    receive_barrier({:poll_started, ^token, tracker_pid})

    calls = [
      status: fn -> Orchestrator.fleet_view(server, @control_budget_ms, fleet_rows?: true) end,
      resume: fn -> PauseResume.resume_agent(server, issue.identifier) end,
      reset: fn -> PauseResume.reset_dispatch_budget(server, issue.identifier) end,
      message: fn -> OperatorMessages.send_operator_message(server, issue.identifier, %{kind: :text, body: "sent during poll", message_id: "during-poll-3213"}) end,
      claim: fn -> Orchestrator.claim_next_queue_item(server, issue.identifier) end
    ]

    tasks = Enum.map(calls, fn {name, fun} -> {name, Task.async(fun)} end)

    try do
      results =
        tasks
        |> Enum.map(&elem(&1, 1))
        |> Task.yield_many(@answer_ms)
        |> Enum.map(fn {task, result} -> {task.ref, result} end)
        |> Map.new()

      replies = Map.new(tasks, fn {name, task} -> {name, Map.fetch!(results, task.ref)} end)
      assert {:ok, {:ok, snapshot, _freshness}} = replies.status
      assert Enum.any?(snapshot.statuses, &(&1.identifier == issue.identifier))
      assert replies.resume == {:ok, {:ok, :already_running}}
      assert replies.reset == {:ok, {:ok, :reset}}
      assert {:ok, {:ok, sent_id}} = replies.message
      assert {:ok, {:ok, %{id: ^seeded_id, body: %{text: "seeded before poll"}}}} = replies.claim
      assert DispatchBudgetStore.lifetime(issue.id) == {:ok, 0}

      # Completion must not replace the queue with the state captured before these calls.
      send(tracker_pid, {:release_poll, token})
      state = await_poll_finished(server)
      assert AgentQueueStore.get(state.queue_store, seeded_id).status == :delivered
      assert %{body: %{text: "sent during poll"}, status: :pending} = AgentQueueStore.get(state.queue_store, sent_id)
    after
      Enum.each(tasks, fn {_name, task} -> Task.shutdown(task, :brutal_kill) end)
      send(tracker_pid, {:release_poll, token})
      assert_no_handler_io(server, patterns)
    end
  end

  test "every operator control handler answers without tracker I/O in the owner while the poll is held",
       %{server: server, issue: issue, token: token} do
    put_test_env(:tracker_io_test_fast_writes, true)
    patterns = trace_handler_io(server)
    send(server, :run_poll_cycle)
    receive_barrier({:poll_started, ^token, tracker_pid})
    id = issue.identifier

    controls = [
      set_max_agents: fn -> Orchestrator.set_max_concurrent_agents(server, 3) end,
      adjust_max_agents: fn -> Orchestrator.adjust_max_concurrent_agents(server, 1) end,
      max_agents: fn -> Orchestrator.max_concurrent_agents(server) end,
      global_pause_status: fn -> GlobalPause.global_pause_status(server, @control_budget_ms) end,
      global_pause: fn -> GlobalPause.set_global_pause(server, true, "tracker-io-test") end,
      global_resume: fn -> GlobalPause.set_global_pause(server, false, "tracker-io-test") end,
      pause: fn -> PauseResume.pause_agent(server, id) end,
      resume: fn -> PauseResume.resume_agent(server, id) end,
      resume_with_receipt: fn -> PauseResume.resume_agent_with_receipt(server, id) end,
      request_control: fn -> PauseResume.request_control(server, id, :pause, 1) end,
      control_lifecycle: fn -> PauseResume.control_lifecycle(server, id) end,
      control_capabilities: fn -> Orchestrator.control_capabilities(server, id) end,
      prioritize: fn -> PriorityControl.prioritize_agent(server, id) end,
      deprioritize: fn -> PriorityControl.deprioritize_agent(server, id) end,
      remote_control: fn -> Orchestrator.set_remote_control(server, id, false) end,
      reset_budget: fn -> PauseResume.reset_dispatch_budget(server, id) end,
      reset_unknown: fn -> PauseResume.reset_dispatch_budget(server, "UNPOLLED-3213") end,
      refresh: fn -> Orchestrator.request_refresh(server) end
    ]

    try do
      # Sequential calls: each control's own caller-side tracker step finishes before the next control starts.
      Enum.each(controls, fn {name, fun} ->
        task = Task.async(fun)
        reply = Task.yield(task, @answer_ms) || Task.shutdown(task, :brutal_kill)
        assert {:ok, result} = reply, "#{name} did not answer while the poll was held"
        refute result == {:error, :timeout}, "#{name} timed out while the poll was held"
      end)
    after
      send(tracker_pid, {:release_poll, token})
      assert_no_handler_io(server, patterns)
    end
  end

  test "a successful candidate poll applies after concurrent calls without a PubSub subscription", %{server: server, issue: issue, token: token} do
    put_test_env(:tracker_io_test_result, {:ok, [issue]})
    send(server, :run_poll_cycle)
    receive_barrier({:poll_started, ^token, tracker_pid})
    refute tracker_pid == server
    assert {:ok, :already_running} = PauseResume.resume_agent(server, issue.identifier)
    send(tracker_pid, {:release_poll, token})
    state = await_poll_finished(server)
    assert state.last_polled_issues[issue.id] == issue
    assert Map.has_key?(state.running, issue.id)
    assert await_poll_finished(server).poll_cycles_completed == 1
  end

  test "GitHub firehose and CI reads leave real handlers responsive", %{server: server, issue: issue, token: token} do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent", max_concurrent_agents: 4)
    put_test_env(:github_client_module, SlowTracker)
    put_test_env(:github_transport_test_options, plug: {Req.Test, __MODULE__})
    put_test_env(:github_budget_enabled?, false)
    put_test_env(:tracker_io_test_result, {:ok, [issue]})
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-tracker-io-token")
    cache_key = {Config, :resolved_token}
    previous_cache = :persistent_term.get(cache_key, :unset)
    :persistent_term.erase(cache_key)

    on_exit(fn ->
      if previous_token, do: System.put_env("GITHUB_TOKEN", previous_token), else: System.delete_env("GITHUB_TOKEN")
      if previous_cache == :unset, do: :persistent_term.erase(cache_key), else: :persistent_term.put(cache_key, previous_cache)
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

      hold? = Agent.get_and_update(seen, fn done -> {stage != :other and not MapSet.member?(done, stage), MapSet.put(done, stage)} end)

      if hold? do
        send(owner, {:github_stage_started, stage, self()})
        receive do: (:release -> :ok)
      end

      Req.Test.json(conn, [])
    end)

    Req.Test.allow(__MODULE__, self(), server)
    patterns = [{Aiur.Events.GithubFirehose, :poll, :_}, {Aiur.Events.GithubCIPoller, :poll, :_}, {Aiur.Tracker, :fetch_candidate_issues, :_}]
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)
    send(server, :run_poll_cycle)

    for stage <- [:firehose, :ci_targets] do
      receive_barrier({:github_stage_started, ^stage, worker})
      refute worker == server
      assert {:ok, _id} = OperatorMessages.send_operator_message(server, issue.identifier, %{kind: :text, body: "during #{stage}"})
      send(worker, :release)
    end

    receive_barrier({:poll_started, ^token, candidate_worker})
    refute candidate_worker == server
    send(candidate_worker, {:release_poll, token})
    state = await_poll_finished(server)
    assert state.last_polled_issues[issue.id] == issue
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})
    Enum.each(patterns, fn {module, function, _} -> refute_received {:trace, ^server, :call, {^module, ^function, _args}} end)
  end

  test "a converted control handler cannot call tracker writes in the owner", %{server: server, issue: issue, token: token} do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent")
    put_test_env(:github_client_module, SlowTracker)
    pattern = {Aiur.Tracker, :add_label, :_}
    :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern(pattern, false, [:local]) end)
    control = Task.async(fn -> PriorityControl.prioritize_agent(server, issue.identifier) end)
    receive_barrier({:label_write_started, ^token, writer})
    refute writer == server
    assert {:ok, _id} = OperatorMessages.send_operator_message(server, issue.identifier, %{kind: :text, body: "during label write"})
    send(writer, {:release_write, token})
    assert Task.await(control) == {:ok, :prioritized}
    assert :sys.get_state(server).running[issue.id].issue.priority == 1
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})
    refute_received {:trace, ^server, :call, {Aiur.Tracker, :add_label, _args}}
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
    patterns = [{Aiur.Tracker, :fetch_issue_states_by_ids, :_} | @dispatch_authorization_patterns]
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)

    :sys.replace_state(server, fn state ->
      Dispatcher.dispatch_issue(%{state | effective_concurrent_agents: 4}, candidate, nil, nil,
        dispatch_result_fun: fn current ->
          send(owner, :dispatch_complete)
          current
        end,
        runner: fn _dispatched, _, _ ->
          send(owner, {:auth_runner_started, self()})
          receive do: (:stop -> :ok)
        end,
        blocked_by_hydrator: fn value -> {:ok, value} end
      )
    end)

    receive_barrier({:timeline_read_started, ^token, reader})
    refute reader == server, "dispatch authorization read the timeline in the orchestrator"
    # The owner still answers a control while the timeline read is held.
    assert is_list(Orchestrator.status(server, @control_budget_ms))
    send(reader, {:release_timeline, token})
    receive_barrier(:dispatch_complete)
    receive_barrier({:auth_runner_started, runner})
    on_exit(fn -> send(runner, :stop) end)
    assert_no_handler_io(server, patterns)
  end

  test "orchestrator shutdown reaps a held tracker task", %{server: server, token: token} do
    send(server, :run_poll_cycle)
    receive_barrier({:poll_started, ^token, tracker})
    refute tracker == server
    monitor = Process.monitor(tracker)
    on_exit(fn -> if Process.alive?(tracker), do: Process.exit(tracker, :kill) end)
    assert GenServer.stop(server) == :ok
    receive_barrier({:DOWN, ^monitor, :process, ^tracker, :killed})
    refute Process.alive?(tracker)
  end

  defp trace_handler_io(server) do
    tracker_patterns =
      Enum.flat_map([{Aiur.Tracker.IssueTracker, Aiur.Tracker}, {Aiur.Tracker.CodeHost, Aiur.CodeHost}], fn {behaviour, facade} ->
        for {function, arity} <- behaviour.behaviour_info(:callbacks), function != :open_issue_labels, do: {facade, function, arity}
      end)

    patterns =
      tracker_patterns ++
        [
          {Transport, :default_request_fun, :_},
          {Aiur.GitHub.Tracker, :fetch_candidate_issues_conditional, :_},
          {Aiur.GitHub.Tracker, :hydrate_blocked_by, :_},
          {Aiur.Events.GithubFirehose, :poll, :_},
          {Aiur.Events.GithubCIPoller, :poll, :_}
        ] ++ @dispatch_authorization_patterns

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    patterns
  end

  defp assert_no_handler_io(server, patterns) do
    delivery = :erlang.trace_delivered(server)
    receive_barrier({:trace_delivered, ^server, ^delivery})
    :erlang.trace(server, false, [:call])
    Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))

    Enum.each(patterns, fn {module, function, _arity} ->
      refute_received {:trace, ^server, :call, {^module, ^function, _args}}, "an orchestrator handler performed remote work"
    end)
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
end
