defmodule Aiur.Orchestrator.DurationCapReleaseTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DurationCapRelease, DurationCapRetryStore, PauseResume, State}

  setup do
    previous = Application.get_env(:aiur, :duration_cap_release_opts)
    previous_store = Application.get_env(:aiur, :dispatch_budget_store_path)
    previous_retry_store = Application.get_env(:aiur, :duration_cap_retry_store_path)
    budget_path = Path.join(Aiur.TestSupport.tmp_root!("duration-cap-release"), "dispatch-budgets.json")
    File.mkdir_p!(Path.dirname(budget_path))
    Application.put_env(:aiur, :dispatch_budget_store_path, budget_path)
    retry_path = Path.join(Path.dirname(budget_path), "duration-cap-retries.json")
    Application.put_env(:aiur, :duration_cap_retry_store_path, retry_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :duration_cap_release_opts, previous),
        else: Application.delete_env(:aiur, :duration_cap_release_opts)

      if previous_store,
        do: Application.put_env(:aiur, :dispatch_budget_store_path, previous_store),
        else: Application.delete_env(:aiur, :dispatch_budget_store_path)

      if previous_retry_store,
        do: Application.put_env(:aiur, :duration_cap_retry_store_path, previous_retry_store),
        else: Application.delete_env(:aiur, :duration_cap_retry_store_path)

      Aiur.TestCleanup.rm_rf!(Path.dirname(budget_path))
    end)
  end

  test "a duration-capped run with progress redispatches without an Executor resume" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before")
    state = %State{running: %{entry.issue.id => entry}}

    dispatch = fn current, issue, attempt, _host, dispatch_opts ->
      send(self(), {:redispatch, issue.identifier, attempt})

      queued =
        current
        |> Map.put(:running, Map.put(current.running, issue.id, %{control: %{status: :working}}))

      dispatch_opts[:dispatch_result_fun].(queued)
    end

    opts = [
      workspace_probe: fn _path, _host -> {:ok, "after"} end,
      progress_release_target_fun: fn _ -> {:ok, "rework"} end,
      dispatch_fun: dispatch,
      emit_alert_fun: fn topic, _ -> send(self(), {:alert, topic}) end,
      max_retry_attempts: 3,
      duration_cap_retry_count_fun: fn _ -> 0 end,
      increment_duration_cap_retry_fun: fn id ->
        send(self(), {:retry_recorded, id})
        :ok
      end
    ]

    Application.put_env(:aiur, :duration_cap_release_opts, opts)
    released = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert Map.has_key?(released.running, entry.issue.id)
    assert_received {:redispatch, "4849", 1}
    assert_received {:retry_recorded, "issue-4849"}
    assert_received {:alert, "ticket.4849.agent.attention.paused-max_agent_duration.resolved"}
  end

  test "a sent startup digest detects a later workspace commit and redispatches" do
    root = Aiur.TestSupport.tmp_root!("duration-cap-startup-digest")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet"])
    File.write!(Path.join(workspace, "work.txt"), "before\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "before"])
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    entry = parked_entry()
    state = %State{running: %{entry.issue.id => entry}}
    assert :ok = MessageHandler.send_worker_runtime_info(self(), entry.issue, nil, workspace)
    assert_receive {:worker_runtime_info, "issue-4849", runtime_info}, 2_000
    {:noreply, state} = State.handle_worker_runtime_info(state, entry.issue.id, runtime_info)
    entry = state.running[entry.issue.id]
    assert is_binary(entry.duration_cap_progress_baseline)

    File.write!(Path.join(workspace, "work.txt"), "after\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "after"])

    dispatch = fn current, issue, _attempt, _host, dispatch_opts ->
      send(self(), {:redispatched, issue.identifier})
      started = %{current | running: Map.put(current.running, issue.id, %{control: %{status: :working}})}
      dispatch_opts[:dispatch_result_fun].(started)
    end

    opts = [
      progress_release_target_fun: fn _ -> {:ok, "rework"} end,
      dispatch_fun: dispatch,
      emit_alert_fun: fn topic, _ -> send(self(), {:alert, topic}) end
    ]

    released = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert released.running[entry.issue.id].control.status == :working
    assert_received {:redispatched, "4849"}
    assert_received {:alert, "ticket.4849.agent.attention.paused-max_agent_duration.resolved"}
  end

  test "a duration-capped run with an exhausted retry budget remains paused and escalates" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before") |> Map.put(:retry_attempt, 3)
    state = %State{running: %{entry.issue.id => entry}}
    opts = [workspace_probe: fn _, _ -> {:ok, "after"} end, max_retry_attempts: 3, duration_cap_retry_count_fun: fn _ -> 3 end, emit_alert_fun: fn _, a -> send(self(), {:reason, a[:reason]}) end]
    Application.put_env(:aiur, :duration_cap_release_opts, opts)

    paused = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert paused.running[entry.issue.id].control.status == :paused
    assert_received {:reason, "retry budget is spent"}
  end

  test "a duration-capped run stays parked when its retry counter cannot be written" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before")
    state = %State{running: %{entry.issue.id => entry}}

    opts = [
      workspace_probe: fn _, _ -> {:ok, "after"} end,
      progress_release_target_fun: fn _ -> {:ok, "rework"} end,
      increment_duration_cap_retry_fun: fn _ -> {:error, :disk} end,
      emit_alert_fun: fn _, alert ->
        send(self(), {:reason, alert[:reason]})
        :ok
      end
    ]

    returned = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert returned == state
    assert returned.running[entry.issue.id].control.status == :paused
    assert_received {:reason, "Could not record automatic redispatch retry (:disk); Executor action is required."}
  end

  test "an asynchronous rework claim resolves the pause alert before the runner starts" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before")
    state = %State{running: %{entry.issue.id => entry}}

    dispatch = fn current, _issue, _attempt, _host, dispatch_opts ->
      claimed = %{current | claimed: MapSet.put(current.claimed, entry.issue.id)}
      dispatch_opts[:dispatch_result_fun].(claimed)
    end

    opts = [
      workspace_probe: fn _, _ -> {:ok, "after"} end,
      progress_release_target_fun: fn _ -> {:ok, "rework"} end,
      duration_cap_retry_count_fun: fn _ -> 0 end,
      increment_duration_cap_retry_fun: fn _ -> :ok end,
      dispatch_fun: dispatch,
      emit_alert_fun: fn topic, _ -> send(self(), {:alert, topic}) end
    ]

    result = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert result.claimed == MapSet.new([entry.issue.id])
    assert_received {:alert, "ticket.4849.agent.attention.paused-max_agent_duration.resolved"}
    refute_received {:alert, "ticket.4849.agent.attention.paused-max_agent_duration"}
  end

  test "a ready PR with progress is released to human review through classification" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before")
    state = %State{running: %{entry.issue.id => entry}}

    opts = [
      workspace_probe: fn _, _ -> {:ok, "after"} end,
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
      pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "draft" => false, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
      unresolved_threads_fetcher: fn _ -> {:ok, []} end,
      update_issue_state_fun: fn identifier, target, expected ->
        send(self(), {:write, identifier, target, expected})
        :ok
      end,
      create_comment_fun: fn _, _ -> :ok end,
      emit_alert_fun: fn _, _ -> :ok end
    ]

    released = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert_received {:write, "4849", "human-review", "in-progress"}
    refute Map.has_key?(released.running, entry.issue.id)
  end

  test "the persisted retry counter exhausts across successive duration-capped runs" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before")

    opts = [
      workspace_probe: fn _, _ -> {:ok, "after"} end,
      max_retry_attempts: 2,
      progress_release_target_fun: fn _ -> {:ok, "rework"} end,
      dispatch_fun: fn current, issue, _attempt, _host, dispatch_opts ->
        started = %{current | running: Map.put(current.running, issue.id, %{control: %{status: :working}})}
        dispatch_opts[:dispatch_result_fun].(started)
      end,
      emit_alert_fun: fn _, alert ->
        send(self(), {:reason, alert[:reason]})
        :ok
      end
    ]

    first = DurationCapRelease.maybe_release(%State{running: %{entry.issue.id => entry}}, entry, :paused, opts)
    second = DurationCapRelease.maybe_release(%State{running: %{entry.issue.id => entry}}, entry, :paused, opts)
    third = DurationCapRelease.maybe_release(%State{running: %{entry.issue.id => entry}}, entry, :paused, opts)

    assert first.running[entry.issue.id].control.status == :working
    assert second.running[entry.issue.id].control.status == :working
    assert third.running[entry.issue.id].control.status == :paused
    assert {:ok, 2} = DurationCapRetryStore.count(entry.issue.id)
    assert_received {:reason, "retry budget is spent"}
  end

  test "an inactive ticket with progress remains paused and escalates" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "before")
    entry = %{entry | issue: %{entry.issue | state: "closed"}}
    state = %State{running: %{entry.issue.id => entry}}
    opts = [workspace_probe: fn _, _ -> {:ok, "after"} end, emit_alert_fun: fn _, a -> send(self(), {:reason, a[:reason]}) end]
    Application.put_env(:aiur, :duration_cap_release_opts, opts)

    paused = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert paused.running[entry.issue.id].control.status == :paused
    assert_received {:reason, "ticket state is inactive"}
  end

  test "a duration-capped run without progress remains paused and escalates" do
    entry = parked_entry() |> Map.put(:workspace_path, "/workspace") |> Map.put(:duration_cap_progress_baseline, "same")
    state = %State{running: %{entry.issue.id => entry}}

    opts = [
      workspace_probe: fn _path, _host -> {:ok, "same"} end,
      open_pr_fetcher: fn _ -> {:ok, nil} end,
      emit_alert_fun: fn topic, alert_opts -> send(self(), {:alert, topic, alert_opts[:reason]}) end
    ]

    Application.put_env(:aiur, :duration_cap_release_opts, opts)
    released = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert released.running[entry.issue.id].control.status == :paused
    assert Map.has_key?(released.running, entry.issue.id)
    assert_received {:alert, "ticket.4849.agent.attention.paused-max_agent_duration", reason}
    assert reason =~ "workpad-only changes do not count"
  end

  test "a release completing after an issue refresh still frees the runner" do
    parked = parked_entry()
    refreshed = %{parked | issue: %{parked.issue | state: "rework", labels: ["agent:rework"]}}
    state = %State{running: %{"issue-4849" => refreshed}, claimed: MapSet.new(["issue-4849"])}

    released = DurationCapRelease.apply_release(state, {:release, "rework", "reason"}, parked, emit_alert_fun: fn _, _ -> :ok end)

    refute Map.has_key?(released.running, "issue-4849")
    refute MapSet.member?(released.claimed, "issue-4849")
  end

  test "a release completing after an operator resume keeps the resumed runner" do
    parked = parked_entry()
    resumed = parked |> Map.delete(:paused_reason) |> Map.put(:control, %{status: :working})
    state = %State{running: %{"issue-4849" => resumed}}

    kept = DurationCapRelease.apply_release(state, {:release, "rework", "reason"}, parked, emit_alert_fun: fn _, _ -> :ok end)

    assert kept.running["issue-4849"] == resumed
  end

  test "a failed progress release remains paused and reports the failure" do
    entry = parked_entry()
    state = %State{running: %{entry.issue.id => entry}}
    result = DurationCapRelease.apply_release(state, {:error, :timeout}, entry, emit_alert_fun: fn _, opts -> send(self(), {:reason, opts[:reason]}) end)
    assert result.running[entry.issue.id].control.status == :paused
    assert_received {:reason, reason}
    assert reason =~ ":timeout"
  end

  # Guard, passes on main too: other pause causes keep their runner.
  test "an operator pause is not released" do
    Application.put_env(:aiur, :duration_cap_release_opts, [])
    state = %State{running: %{"issue-4849" => Map.put(entry(), :paused_reason, :operator_pause)}}

    {:noreply, paused} = PauseResume.handle_worker_control_state(state, "issue-4849", :paused, %{})

    assert paused.running["issue-4849"].control.status == :paused
    refute_received {:write, _target, _expected}
  end

  defp parked_entry, do: %{entry() | control: %{status: :paused}}

  defp git!(workspace, args) do
    {_output, 0} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
  end

  defp entry do
    %{
      pid: nil,
      ref: nil,
      identifier: "4849",
      issue: %Issue{id: "issue-4849", identifier: "4849", state: "in-progress"},
      started_at: DateTime.add(DateTime.utc_now(), -7200, :second),
      paused_reason: :max_agent_duration,
      control: %{status: :working},
      retry_attempt: 0,
      workspace_path: nil,
      worker_host: nil,
      session_id: "session-1"
    }
  end
end
