defmodule Aiur.IssueSummaryWorkerTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentEvents, AgentPubSub, IssueSummaryLog, IssueSummaryWorker}

  defmodule NoopReporter do
    @behaviour Aiur.AgentSetupScout.Reporter
    def report(_finding), do: :ok
  end

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    tmp = Path.join(System.tmp_dir!(), "aiur-summary-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "log"))
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    {:ok, worker} = IssueSummaryWorker.start_link(name: nil, reporter: NoopReporter, max_lines: 10)

    on_exit(fn ->
      if Process.alive?(worker), do: GenServer.stop(worker)
      restore_app_env(:log_file, original_log_file)
      File.rm_rf!(tmp)
    end)

    %{worker: worker}
  end

  test "running changes create summary bullets" do
    summary = AgentEvents.agent_summary("40", :running, 0, %{title: "Self analyzing aiur", backend: "codex"})

    assert :ok = AgentPubSub.broadcast_running_change([summary])

    assert_summary("40", "Agent 40 running (Self analyzing aiur / codex)")
  end

  test "status changes are deduplicated" do
    assert :ok = AgentPubSub.broadcast_status_change("40", :paused)
    assert :ok = AgentPubSub.broadcast_status_change("40", :paused)

    assert_summary("40", "Status changed: paused")
    assert count_lines("40", "Status changed: paused") == 1
  end

  test "global agent events preserve the source identifier" do
    assert :ok =
             AgentPubSub.broadcast_transcript(
               "40",
               AgentEvents.transcript_event(:command, "mix test", timestamp: ~U[2026-06-24 12:00:00Z])
             )

    assert :ok =
             AgentPubSub.broadcast_transcript(
               "41",
               AgentEvents.transcript_event(:tool, "apply_patch", timestamp: ~U[2026-06-24 12:00:01Z])
             )

    assert_summary("40", "Command: mix test")
    assert_summary("41", "Tool: apply_patch")
    refute File.read!(IssueSummaryLog.log_path("40")) =~ "apply_patch"
  end

  test "alerts and turn outcomes are summarized" do
    assert :ok =
             AgentPubSub.broadcast_alert(
               "40",
               AgentEvents.alert_event("phase.work.start", "implementing", timestamp: ~U[2026-06-24 12:00:00Z])
             )

    assert :ok = AgentPubSub.broadcast_turn_event("40", :turn_failed, %{reason: :timeout})

    assert_summary("40", "Alert phase.work.start: implementing")
    assert_summary("40", "Turn turn_failed: :timeout")
  end

  defp assert_summary(identifier, expected) do
    path = IssueSummaryLog.log_path(identifier)

    assert eventually(fn ->
             File.exists?(path) and File.read!(path) =~ expected
           end)
  end

  defp count_lines(identifier, expected) do
    IssueSummaryLog.log_path(identifier)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.count(&String.contains?(&1, expected))
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
