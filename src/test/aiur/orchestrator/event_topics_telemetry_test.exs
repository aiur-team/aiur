defmodule Aiur.Orchestrator.EventTopicsTelemetryTest do
  use Aiur.TestSupport

  alias Aiur.{Orchestrator, RunTelemetry, Workflow}
  alias Aiur.Orchestrator.EventTopics
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @merged_at "2026-09-09T23:46:54Z"

  setup do
    test_root = Aiur.TestSupport.tmp_root!("aiur-event-topics-telemetry")
    File.mkdir_p!(test_root)

    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
    previous_recorder = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :memory_tracker_issues, [])
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    test_pid = self()

    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attributes, opts ->
      send(test_pid, {:lifecycle_recorded, kind, attributes, opts})
      :ok
    end)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      restore_app_env(:run_telemetry_lifecycle_recorder, previous_recorder)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root}
  end

  test "a PR merge consumed after boot is anchored in this boot's telemetry and counted by the run-scoped analytics",
       %{test_root: test_root} do
    boot_id = RunTelemetry.boot_id()

    # The stream this boot wrote before the merge arrived: the ticket was
    # dispatched and opened its PR in this session.
    path = Path.join(test_root, "telemetry.ndjson")

    records = [
      record(boot_id, 1, %{"event" => "restart"}, ~U[2026-09-09 22:34:00Z], "restart"),
      record(boot_id, 2, %{"event" => "dispatch", "boundary" => "point", "ticket" => "165"}, ~U[2026-09-09 22:40:00Z]),
      record(boot_id, 3, %{"event" => "pr_opened", "boundary" => "point", "ticket" => "165"}, ~U[2026-09-09 23:10:00Z])
    ]

    write_stream!(path, records)

    assert {:ok, before} = Presenter.load(telemetry_file: path, session: :current)
    assert before.kpis.merged == 0

    # The live merge event, exactly as the GitHub ingress publishes it and the
    # orchestrator consumes it.
    event = %{
      id: 900,
      topic: "ticket.165.pr.merged",
      source: :github,
      action: "closed",
      timestamp: "2026-09-09T23:46:55Z",
      pr: %{
        "number" => 177,
        "merged" => true,
        "merged_at" => @merged_at,
        "merged_by" => %{"login" => "operator"},
        "user" => %{"login" => "its-applekid"}
      }
    }

    _state = EventTopics.route(minimal_state(), event)

    assert_receive {:lifecycle_recorded, :lifecycle, attributes, opts}

    assert attributes.event == "pr_merged"
    assert attributes.boundary == "point"
    assert attributes.ticket == "165"
    assert attributes.pr_number == 177
    assert attributes.source == "github"
    assert Keyword.fetch!(opts, :timestamp) == @merged_at

    # The recorder hands the anchor to this boot's stream; append it the way
    # the writer would and the latest-run counters now see the merge.
    {:ok, merged_at, _offset} = DateTime.from_iso8601(@merged_at)
    write_stream!(path, records ++ [record(boot_id, 4, stringify(attributes), merged_at)])

    assert {:ok, after_merge} = Presenter.load(telemetry_file: path, session: :current)
    assert after_merge.kpis.merged == 1
    assert after_merge.kpis.done == 1
    assert after_merge.source_boot_id == boot_id
    assert [%{id: "165", status: :merged}] = after_merge.tickets
  end

  defp minimal_state do
    %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  defp record(boot_id, sequence, attributes, timestamp, kind \\ "lifecycle") do
    attributes = Map.put_new(attributes, "event_key", "#{boot_id}-#{sequence}")

    %{
      schema_version: 2,
      kind: kind,
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: boot_id,
      sequence: sequence,
      record_id: "#{boot_id}:#{sequence}",
      attributes: attributes
    }
  end

  defp stringify(attributes), do: Map.new(attributes, fn {key, value} -> {to_string(key), value} end)

  defp write_stream!(path, records), do: File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
