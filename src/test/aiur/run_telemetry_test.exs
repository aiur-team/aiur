defmodule Aiur.RunTelemetryTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry

  setup do
    original_debug = System.get_env("AIUR_DEBUG")
    original_log_file = Application.get_env(:aiur, :log_file)

    root = Path.join(System.tmp_dir!(), "aiur-run-telemetry-#{System.unique_integer([:positive])}")
    log_file = Path.join(root, "log/aiur.log")
    Application.put_env(:aiur, :log_file, log_file)

    on_exit(fn ->
      File.rm_rf!(root)

      case original_debug do
        nil -> System.delete_env("AIUR_DEBUG")
        value -> System.put_env("AIUR_DEBUG", value)
      end

      case original_log_file do
        nil -> Application.delete_env(:aiur, :log_file)
        value -> Application.put_env(:aiur, :log_file, value)
      end
    end)

    %{root: root}
  end

  test "telemetry_file/0 lives beside the daemon log", %{root: root} do
    assert RunTelemetry.telemetry_file() == Path.join(root, "log/telemetry.ndjson")
  end

  test "record/2 is a no-op with no file when debug is disabled", %{root: root} do
    System.delete_env("AIUR_DEBUG")

    assert :ok = RunTelemetry.record(:lifecycle, %{event: :dispatch})
    refute File.exists?(Path.join(root, "log/telemetry.ndjson"))
  end

  test "record/2 remains fail-open when debug is enabled but the writer is absent" do
    System.put_env("AIUR_DEBUG", "1")

    assert :ok = RunTelemetry.record(:lifecycle, %{event: :dispatch})
  end

  test "debug-enabled facade writes through the supervised writer", %{root: root} do
    System.put_env("AIUR_DEBUG", "1")
    RunTelemetry.start_boot()

    start_supervised!({Aiur.RunTelemetry.Supervisor, name: __MODULE__.Supervisor, writer_opts: [name: __MODULE__.Writer, path: Path.join(root, "log/telemetry.ndjson")]})

    assert :ok =
             RunTelemetry.record(:lifecycle, %{ticket: "930", event: :dispatch}, writer: __MODULE__.Writer)

    assert :ok = Aiur.RunTelemetry.Writer.flush(__MODULE__.Writer)

    records =
      root
      |> Path.join("log/telemetry.ndjson")
      |> File.stream!([], :line)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(records, & &1["kind"]) == ["restart", "lifecycle"]
    assert Enum.at(records, 1)["attributes"]["ticket"] == "930"
  end
end
