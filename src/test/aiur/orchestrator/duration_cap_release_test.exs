defmodule Aiur.Orchestrator.DurationCapReleaseTest do
  use ExUnit.Case, async: false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DurationCapRelease, PauseResume, State}

  setup do
    previous = Application.get_env(:aiur, :duration_cap_release_opts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :duration_cap_release_opts, previous),
        else: Application.delete_env(:aiur, :duration_cap_release_opts)
    end)
  end

  test "a duration-capped pause with no PR moves the ticket to rework and frees the runner" do
    released = pause_with(open_pr_fetcher: fn "4849" -> {:ok, nil} end)

    refute Map.has_key?(released.running, "issue-4849")
    assert_received {:write, "rework", "in-progress"}
    assert_received {:comment, body}
    assert body =~ "max_agent_duration_minutes"
    assert body =~ "rework"
  end

  test "a duration-capped pause with a draft PR moves the ticket to rework" do
    released =
      pause_with(
        open_pr_fetcher: fn "4849" -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "draft" => true, "mergeable" => true}} end
      )

    refute Map.has_key?(released.running, "issue-4849")
    assert_received {:write, "rework", "in-progress"}
  end

  test "a duration-capped pause with a ready PR moves the ticket to human-review" do
    released =
      pause_with(
        open_pr_fetcher: fn "4849" -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "draft" => false, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, []} end
      )

    refute Map.has_key?(released.running, "issue-4849")
    assert_received {:write, "human-review", "in-progress"}
  end

  test "a failed release leaves the agent paused" do
    released = pause_with(open_pr_fetcher: fn "4849" -> {:error, :timeout} end)

    assert released.running["issue-4849"].control.status == :paused
    refute_received {:write, _target, _expected}
  end

  # Owner mode applies the result later; a refresh may have swapped `:issue` after the write.
  test "a release completing after an issue refresh still frees the runner" do
    parked = parked_entry()
    refreshed = %{parked | issue: %{parked.issue | state: "rework", labels: ["agent:rework"]}}
    state = %State{running: %{"issue-4849" => refreshed}, claimed: MapSet.new(["issue-4849"])}

    released = DurationCapRelease.apply_release(state, {:ok, "rework"}, parked, emit_alert_fun: fn _, _ -> :ok end)

    refute Map.has_key?(released.running, "issue-4849")
    refute MapSet.member?(released.claimed, "issue-4849")
  end

  test "a release completing after an operator resume keeps the resumed runner" do
    parked = parked_entry()
    resumed = parked |> Map.delete(:paused_reason) |> Map.put(:control, %{status: :working})
    state = %State{running: %{"issue-4849" => resumed}}

    kept = DurationCapRelease.apply_release(state, {:ok, "rework"}, parked, emit_alert_fun: fn _, _ -> :ok end)

    assert kept.running["issue-4849"] == resumed
  end

  # Guard, passes on main too: other pause causes keep their runner.
  test "an operator pause is not released" do
    Application.put_env(:aiur, :duration_cap_release_opts, base_opts())
    state = %State{running: %{"issue-4849" => Map.put(entry(), :paused_reason, :operator_pause)}}

    {:noreply, paused} = PauseResume.handle_worker_control_state(state, "issue-4849", :paused, %{})

    assert paused.running["issue-4849"].control.status == :paused
    refute_received {:write, _target, _expected}
  end

  defp pause_with(opts) do
    Application.put_env(:aiur, :duration_cap_release_opts, Keyword.merge(base_opts(), opts))
    state = %State{running: %{"issue-4849" => entry()}}
    {:noreply, released} = PauseResume.handle_worker_control_state(state, "issue-4849", :paused, %{})
    released
  end

  defp base_opts do
    test = self()

    [
      active_states: ["todo", "in-progress", "rework", "human-review"],
      update_issue_state_fun: fn "4849", target, expected ->
        send(test, {:write, target, expected})
        :ok
      end,
      create_comment_fun: fn "4849", body ->
        send(test, {:comment, body})
        :ok
      end,
      emit_alert_fun: fn _topic, _opts -> :ok end
    ]
  end

  defp parked_entry, do: %{entry() | control: %{status: :paused}}

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
