defmodule Aiur.Config.EventsExportConfigTest do
  use ExUnit.Case, async: false

  alias Aiur.Config
  alias Aiur.Config.Schema
  alias Aiur.Workflow

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("events-export-config")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, "tracker:\n  kind: memory\n")
    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      if is_nil(previous), do: Workflow.clear_workflow_file_path(), else: Workflow.set_workflow_file_path(previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{path: path}
  end

  test "old configs default to export disabled, 7 days and 50000 events" do
    for attrs <- [%{}, %{"events" => %{}}, %{"events" => %{"export" => %{}}}] do
      assert {:ok, settings} = Schema.parse(attrs)
      assert settings.events.export.enabled == false
      assert settings.events.export.retention_days == 7
      assert settings.events.export.retention_max_events == 50_000
    end

    assert Config.events_export_enabled?() == false
    assert Config.events_export_retention_days() == 7
    assert Config.events_export_retention_max_events() == 50_000
  end

  test "YAML overrides reach the public accessors", %{path: path} do
    File.write!(path, """
    tracker:
      kind: memory
    events:
      export:
        enabled: true
        webhook_url: https://consumer.example.com/webhooks/aiur
        retention_days: 30
        retention_max_events: 12000
    """)

    assert :ok = Aiur.WorkflowStore.force_reload()
    assert Config.events_export_enabled?() == true
    assert Config.events_export_retention_days() == 30
    assert Config.events_export_retention_max_events() == 12_000
  end

  test "both retention bounds reject out-of-range values and accept endpoints" do
    for {key, minimum, maximum} <- [{"retention_days", 1, 90}, {"retention_max_events", 1_000, 1_000_000}] do
      for value <- [-1, 0, minimum - 1, maximum + 1] do
        assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"events" => %{"export" => %{key => value}}})
        assert message =~ "events.export.#{key}"
      end

      for value <- [minimum, maximum] do
        assert {:ok, settings} = Schema.parse(%{"events" => %{"export" => %{key => value}}})
        assert Map.fetch!(settings.events.export, String.to_existing_atom(key)) == value
      end
    end
  end

  test "invalid types name the export key" do
    for key <- ["enabled", "retention_days", "retention_max_events"] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"events" => %{"export" => %{key => "invalid"}}})
      assert message =~ "events.export.#{key}"
    end
  end

  test "uncommented example events block parses with export defaults" do
    template = File.read!(Path.expand("../../../../.aiur/examples/config.example", __DIR__))
    [block] = Regex.run(~r/^# events:\n(?:#   .*\n)+/m, template)
    assert {:ok, events} = YamlElixir.read_from_string(String.replace(block, ~r/^# /m, ""))

    assert events["events"]["export"] == %{
             "enabled" => false,
             "max_pending_events" => 10_000,
             "request_timeout_ms" => 15_000,
             "retention_days" => 7,
             "retention_max_events" => 50_000,
             "retry_ms" => 5_000,
             "subject_id" => "5695",
             "webhook_url" => "https://consumer.example.com/webhooks/aiur"
           }

    assert {:ok, settings} = Schema.parse(events)
    assert settings.events.export.enabled == false
    assert settings.events.export.retention_days == 7
    assert settings.events.export.retention_max_events == 50_000
  end
end
