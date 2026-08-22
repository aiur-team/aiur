defmodule Aiur.RunTelemetryTest do
  use ExUnit.Case, async: false

  alias Aiur.{Config, RunTelemetry, Workflow, WorkflowStore}
  alias Aiur.RunTelemetry.{Dashboard, Lifecycle, Writer}
  alias Aiur.Workflow

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-run-telemetry-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "telemetry_file/0 lives beside the daemon log", %{root: root} do
    with_log_file(Path.join(root, "log/aiur.log"), fn ->
      assert RunTelemetry.telemetry_file() == Path.join(root, "log/telemetry.ndjson")
    end)
  end

  test "telemetry_file/0 falls back to the default daemon log" do
    with_log_file(nil, fn ->
      assert RunTelemetry.telemetry_file() ==
               Path.join(Path.dirname(Aiur.LogFile.default_log_file()), "telemetry.ndjson")
    end)
  end

  test "boot state initializes lazily and invalid facade inputs remain no-ops" do
    boot_state_key = {RunTelemetry, :boot_state}
    :persistent_term.erase(boot_state_key)
    on_exit(&RunTelemetry.start_boot/0)

    assert is_binary(RunTelemetry.boot_id())
    assert %DateTime{} = RunTelemetry.boot_started_at()
    assert RunTelemetry.next_sequence() == 1
    assert :ok = RunTelemetry.record(123, :invalid, :invalid)
    assert :ok = RunTelemetry.record_batch(:invalid, :invalid)
  end

  test "boot_id/0 observes a simulated reboot immediately without a separate start_boot/0 call" do
    boot_start_key = {Aiur.Boot, :start_ms}
    boot_epoch_key = {Aiur.Boot, :start_epoch_seconds}
    boot_started_at_key = {Aiur.Boot, :started_at}
    boot_run_id_key = {Aiur.Boot, :run_id}
    original_start = :persistent_term.get(boot_start_key, :unset)
    original_epoch = :persistent_term.get(boot_epoch_key, :unset)
    original_started_at = :persistent_term.get(boot_started_at_key, :unset)
    original_run_id = :persistent_term.get(boot_run_id_key, :unset)

    on_exit(fn ->
      restore_persistent_term(boot_start_key, original_start)
      restore_persistent_term(boot_epoch_key, original_epoch)
      restore_persistent_term(boot_started_at_key, original_started_at)
      restore_persistent_term(boot_run_id_key, original_run_id)
    end)

    Aiur.Boot.mark()
    original_id = RunTelemetry.boot_id()
    sequence_before = RunTelemetry.next_sequence()

    assert :ok = Aiur.Boot.remark()

    refute RunTelemetry.boot_id() == original_id
    assert RunTelemetry.boot_id() == Aiur.Boot.run_id()

    competing_sequence = Task.async(&RunTelemetry.next_sequence/0) |> Task.await()
    sequence_after = RunTelemetry.next_sequence()

    assert competing_sequence > sequence_before
    assert sequence_after > competing_sequence
  end

  defp restore_persistent_term(key, :unset), do: :persistent_term.erase(key)
  defp restore_persistent_term(key, value), do: :persistent_term.put(key, value)

  defp with_log_file(log_file, fun) do
    original_log_file = Application.get_env(:aiur, :log_file)

    if is_nil(log_file) do
      Application.delete_env(:aiur, :log_file)
    else
      Application.put_env(:aiur, :log_file, log_file)
    end

    try do
      fun.()
    after
      if is_nil(original_log_file) do
        Application.delete_env(:aiur, :log_file)
      else
        Application.put_env(:aiur, :log_file, original_log_file)
      end
    end
  end

  test "record/2 is fail-open with no file when the writer is not started", %{root: root} do
    with_log_file(Path.join(root, "log/aiur.log"), fn ->
      assert :ok = RunTelemetry.record(:lifecycle, %{event: :dispatch})
      assert :ok = RunTelemetry.record_batch([{:resource, %{actor: "_daemon"}}])
      refute File.exists?(Path.join(root, "log/telemetry.ndjson"))
    end)
  end

  test "record/2 remains fail-open when the writer is absent" do
    assert :ok = RunTelemetry.record(:lifecycle, %{event: :dispatch})
  end

  test "telemetry_enabled: false disables recording via the real boot path", %{root: root} do
    enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
    original_pt = :persistent_term.get(enabled_key, :unset)

    disabled_config = Path.join(root, "disabledconfig.yaml")
    File.mkdir_p!(Path.dirname(disabled_config))

    File.write!(disabled_config, """
    tracker:
      kind: github
      github:
        repo: test-org/test-repo
        label_prefix: agent
    observability:
      telemetry_enabled: false
    """)

    on_exit(fn ->
      case original_pt do
        :unset -> :persistent_term.erase(enabled_key)
        value -> :persistent_term.put(enabled_key, value)
      end
    end)

    use_workflow_path!(disabled_config)
    assert Aiur.Config.telemetry_enabled?() == false

    RunTelemetry.start_boot()

    assert RunTelemetry.telemetry_enabled?() == false
    assert :ok = RunTelemetry.record(:lifecycle, %{ticket: "disabled-test"})
    assert :ok = RunTelemetry.record_batch([{:lifecycle, %{ticket: "disabled-test"}}])
    refute File.exists?(Path.join(root, "log/telemetry.ndjson"))
  end

  test "facade writes through the supervised writer without --debug", %{root: root} do
    original_debug = System.get_env("AIUR_DEBUG")
    System.delete_env("AIUR_DEBUG")

    on_exit(fn ->
      case original_debug do
        nil -> System.delete_env("AIUR_DEBUG")
        value -> System.put_env("AIUR_DEBUG", value)
      end
    end)

    RunTelemetry.start_boot()

    start_supervised!(
      {Aiur.RunTelemetry.Supervisor,
       name: __MODULE__.Supervisor, writer_opts: [name: __MODULE__.Writer, path: Path.join(root, "log/telemetry.ndjson")], sampler_opts: [name: __MODULE__.Sampler, start_immediately?: false]}
    )

    assert :ok =
             RunTelemetry.record(:lifecycle, %{ticket: "930", event: :dispatch}, writer: __MODULE__.Writer)

    assert :ok = Aiur.RunTelemetry.Writer.flush(__MODULE__.Writer)

    records =
      root
      |> Path.join("log/telemetry.ndjson")
      |> File.stream!(:line, [])
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(records, & &1["kind"]) == ["restart", "lifecycle"]
    assert Enum.at(records, 1)["attributes"]["ticket"] == "930"
  end

  test "supervised sampling and lifecycle evidence generate an offline dashboard", %{root: root} do
    RunTelemetry.start_boot()
    test_pid = self()
    telemetry_path = Path.join(root, "log/telemetry.ndjson")
    output = Path.join(root, "analytics.html")

    sample_fun = fn _previous ->
      %{
        records: [
          %{
            actor: "_daemon",
            actor_type: "daemon",
            ticket: nil,
            availability: "measured",
            unavailable_reason: nil,
            process_count: 1,
            rss_bytes: 1_024,
            fd_count: 12,
            read_bytes: 100,
            write_bytes: 200,
            cpu_percent: 3.5,
            read_bytes_per_second: nil,
            write_bytes_per_second: nil,
            partial_fields: []
          }
        ],
        warnings: [],
        previous: %{}
      }
    end

    recorder = fn records ->
      RunTelemetry.record_batch(records, writer: __MODULE__.PipelineWriter)
      Writer.flush(__MODULE__.PipelineWriter)
      send(test_pid, :resource_sample_recorded)
    end

    start_supervised!(
      {Aiur.RunTelemetry.Supervisor,
       name: __MODULE__.PipelineSupervisor,
       writer_opts: [name: __MODULE__.PipelineWriter, path: telemetry_path],
       sampler_opts: [
         name: __MODULE__.PipelineSampler,
         sample_fun: sample_fun,
         recorder: recorder,
         interval_ms: 60_000,
         start_immediately?: true
       ]}
    )

    assert_receive :resource_sample_recorded

    lifecycle_recorder = fn kind, attributes, opts ->
      RunTelemetry.record(kind, attributes, Keyword.put(opts, :writer, __MODULE__.PipelineWriter))
    end

    assert :ok =
             Lifecycle.record("930", "attempt-1", :dispatch, :point, %{},
               recorder: lifecycle_recorder,
               timestamp: ~U[2026-07-11 12:00:00Z]
             )

    assert :ok = Writer.flush(__MODULE__.PipelineWriter)

    assert {:ok, result} =
             Dashboard.generate(telemetry_path, output, generated_at: ~U[2026-07-11 12:01:00Z])

    assert result.dataset.actors["_daemon"].profile["rss_bytes"].max == 1_024
    assert Enum.any?(result.dataset.tickets["930"].events, &(&1.event == "dispatch"))
    assert File.read!(output) =~ "<!doctype html>"
  end

  test "Config.telemetry_enabled?/0 defaults to true when observability is omitted", %{root: root} do
    default_config = Path.join(root, "defaultconfig.yaml")
    File.mkdir_p!(root)

    File.write!(default_config, """
    tracker:
      kind: github
      github:
        repo: test-org/test-repo
        label_prefix: agent
    """)

    use_workflow_path!(default_config)
    assert Config.telemetry_enabled?() == true
  end

  test "Config.telemetry_enabled?/0 returns to the default when the config goes missing", %{root: root} do
    disabled_config = Path.join(root, "disabled-then-missingconfig.yaml")
    File.mkdir_p!(root)

    File.write!(disabled_config, """
    tracker:
      kind: github
      github:
        repo: test-org/test-repo
        label_prefix: agent
    observability:
      telemetry_enabled: false
    """)

    use_workflow_path!(disabled_config)
    assert Config.telemetry_enabled?() == false

    :ok = Workflow.set_workflow_file_path(Path.join(root, "missingconfig.yaml"))
    assert Config.telemetry_enabled?() == true
  end

  test "lifecycle records exclude prompt, command, and output text" do
    test_pid = self()

    recorder = fn kind, attributes, _opts ->
      send(test_pid, {:recorded, kind, attributes})
      :ok
    end

    Lifecycle.record("test-ticket", "attempt-1", :dispatch, :point, %{prompt: "secret prompt", command: "secret command", output: "secret output"}, recorder: recorder)

    assert_receive {:recorded, :lifecycle, attributes}
    json = Jason.encode!(attributes)
    refute json =~ "prompt"
    refute json =~ "command"
    refute json =~ "output"
  end

  defp use_workflow_path!(path) do
    original_path = Application.get_env(:aiur, :workflow_file_path)
    on_exit(fn -> restore_workflow_path!(original_path) end)

    :ok = Workflow.set_workflow_file_path(path)
    assert_workflow_store_path!(path)
  end

  defp restore_workflow_path!(nil) do
    :ok = Workflow.clear_workflow_file_path()
    assert_workflow_store_path!(Workflow.workflow_file_path())
  end

  defp restore_workflow_path!(path) do
    :ok = Workflow.set_workflow_file_path(path)
    assert_workflow_store_path!(path)
  end

  defp assert_workflow_store_path!(path) do
    assert :ok = WorkflowStore.force_reload()
    assert %{path: ^path} = :sys.get_state(WorkflowStore)
  end
end
