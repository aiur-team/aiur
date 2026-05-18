defmodule Aiur.IssueSummaryLogTest do
  use Aiur.TestSupport

  alias Aiur.{AgentEvents, AgentPubSub, IssueSummaryLog}

  setup do
    log_root = Path.join(System.tmp_dir!(), "aiur-summary-log-test-#{System.unique_integer([:positive])}")
    log_file = Path.join(log_root, "log/aiur.log")
    previous_log_file = Application.get_env(:aiur, :log_file)

    Application.put_env(:aiur, :log_file, log_file)
    File.mkdir_p!(Path.dirname(log_file))

    on_exit(fn ->
      if previous_log_file do
        Application.put_env(:aiur, :log_file, previous_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf(log_root)
    end)

    {:ok, log_root: log_root}
  end

  test "writes dated summary bullets for phase alerts and commands" do
    identifier = unique_identifier()
    timestamp = ~U[2026-05-18 20:00:00Z]

    :ok = IssueSummaryLog.attach(identifier)

    :ok =
      AgentPubSub.broadcast_alert(
        identifier,
        AgentEvents.alert_event("phase.work.start", "Starting implementation", timestamp: timestamp)
      )

    :ok =
      AgentPubSub.broadcast_transcript(
        identifier,
        AgentEvents.transcript_event(:command, "$ mix test [exit=0]", timestamp: timestamp)
      )

    assert_eventually(fn ->
      contents = File.read!(IssueSummaryLog.summary_path(identifier))

      contents =~ "2026-05-18T20:00:00Z - Work started: Starting implementation" and
        contents =~ "2026-05-18T20:00:00Z - Command finished (exit 0): mix test"
    end)
  end

  test "deduplicates repeated equivalent bullets" do
    identifier = unique_identifier()

    :ok = IssueSummaryLog.attach(identifier)

    event = AgentEvents.alert_event("phase.plan.end", "Completed plan")
    :ok = AgentPubSub.broadcast_alert(identifier, event)
    :ok = AgentPubSub.broadcast_alert(identifier, event)

    assert_eventually(fn ->
      lines = summary_lines(identifier)
      Enum.count(lines, &String.contains?(&1, "Plan finished: Completed plan")) == 1
    end)
  end

  test "deduplicates against existing summary lines after restart" do
    identifier = unique_identifier()

    :ok = IssueSummaryLog.attach(identifier)

    event = AgentEvents.alert_event("phase.plan.end", "Completed plan")
    :ok = AgentPubSub.broadcast_alert(identifier, event)

    assert_eventually(fn ->
      summary_lines(identifier) != []
    end)

    stop_writer(identifier)

    :ok = IssueSummaryLog.attach(identifier)
    :ok = AgentPubSub.broadcast_alert(identifier, event)

    Process.sleep(50)

    lines = summary_lines(identifier)
    assert Enum.count(lines, &String.contains?(&1, "Plan finished: Completed plan")) == 1
  end

  test "summarizes running changes without repeating unchanged status" do
    identifier = unique_identifier()

    :ok = IssueSummaryLog.attach(identifier)

    running_summary = AgentEvents.agent_summary(identifier, :running, 0, %{title: "Do the work"})
    :ok = AgentPubSub.broadcast_running_change([running_summary])
    :ok = AgentPubSub.broadcast_running_change([running_summary])

    queued_summary = AgentEvents.agent_summary(identifier, :queued, 0, %{title: "Do the work"})
    :ok = AgentPubSub.broadcast_running_change([queued_summary])

    assert_eventually(fn ->
      lines = summary_lines(identifier)

      Enum.count(lines, &String.contains?(&1, "Agent running: Do the work")) == 1 and
        Enum.count(lines, &String.contains?(&1, "Agent queued: Do the work")) == 1
    end)
  end

  test "rotates the active summary file when it reaches the line cap" do
    identifier = unique_identifier()
    path = IssueSummaryLog.summary_path(identifier)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, Enum.map_join(1..200, "\n", &"old line #{&1}") <> "\n")

    :ok = IssueSummaryLog.attach(identifier)
    :ok = AgentPubSub.broadcast_transcript(identifier, AgentEvents.transcript_event(:assistant, "Ready for review"))

    assert_eventually(fn ->
      File.exists?(path <> ".1") and
        File.read!(path <> ".1") =~ "old line 200" and
        File.read!(path) =~ "Agent reported: Ready for review"
    end)
  end

  defp unique_identifier do
    "MT-SUMMARY-#{System.unique_integer([:positive])}"
  end

  defp summary_lines(identifier) do
    identifier
    |> IssueSummaryLog.summary_path()
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp stop_writer(identifier) do
    case Registry.lookup(Aiur.IssueSummaryLog.Registry, identifier) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0) do
    assert fun.()
  end
end
