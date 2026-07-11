defmodule Aiur.RunTelemetry.WriterTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Writer

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-telemetry-writer-#{System.unique_integer([:positive])}")
    path = Path.join(root, "log/telemetry.ndjson")
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: path, root: root}
  end

  test "appends sequenced envelope records without truncating a prior boot", %{path: path} do
    {:ok, first} = Writer.start_link(name: nil, path: path, boot_id: "boot-1")

    assert :ok =
             Writer.record(first, :lifecycle, %{ticket: "930", event: :dispatch}, timestamp: ~U[2026-07-11 12:00:00Z])

    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    {:ok, second} = Writer.start_link(name: nil, path: path, boot_id: "boot-2")
    assert :ok = Writer.record(second, "resource", %{actor: "_daemon", rss_bytes: 42})
    assert :ok = Writer.flush(second)

    records = read_records(path)

    assert Enum.map(records, & &1["kind"]) == ["restart", "lifecycle", "restart", "resource"]
    assert Enum.map(records, & &1["boot_id"]) == ["boot-1", "boot-1", "boot-2", "boot-2"]
    assert Enum.map(records, & &1["sequence"]) == [1, 2, 1, 2]
    assert Enum.map(records, & &1["record_id"]) == ["boot-1:1", "boot-1:2", "boot-2:1", "boot-2:2"]
    assert Enum.at(records, 1)["timestamp"] == "2026-07-11T12:00:00Z"
    assert Enum.at(records, 1)["attributes"] == %{"event" => "dispatch", "ticket" => "930"}
    assert Enum.at(records, 2)["attributes"]["existing_records"] == true
  end

  test "concurrent producers persist whole uniquely sequenced lines", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "concurrent")

    1..20
    |> Task.async_stream(
      fn index -> Writer.record(writer, :resource, %{actor: "ticket:#{index}", rss_bytes: index}) end,
      max_concurrency: 8,
      ordered: false
    )
    |> Stream.run()

    assert :ok = Writer.flush(writer)
    records = read_records(path)

    assert length(records) == 21
    assert Enum.map(records, & &1["sequence"]) == Enum.to_list(1..21)
    assert records |> Enum.map(& &1["record_id"]) |> Enum.uniq() |> length() == 21
  end

  test "record_batch/3 appends one contiguous sequence", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "batch")

    assert :ok =
             Writer.record_batch(
               writer,
               [resource: %{actor: "_daemon"}, warning: %{event: :resource_sample_skipped}],
               timestamp: ~U[2026-07-11 12:00:00Z]
             )

    assert :ok = Writer.flush(writer)
    records = read_records(path)

    assert Enum.map(records, & &1["kind"]) == ["restart", "resource", "warning"]
    assert Enum.map(records, & &1["sequence"]) == [1, 2, 3]

    assert Enum.map(Enum.drop(records, 1), & &1["timestamp"]) == [
             "2026-07-11T12:00:00Z",
             "2026-07-11T12:00:00Z"
           ]
  end

  test "an unwritable target never terminates the writer or caller", %{root: root} do
    parent_file = Path.join(root, "not-a-directory")
    File.mkdir_p!(root)
    File.write!(parent_file, "occupied")
    path = Path.join(parent_file, "telemetry.ndjson")

    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "broken")

    assert Process.alive?(writer)
    assert :ok = Writer.record(writer, :lifecycle, %{event: :dispatch})
    assert :ok = Writer.flush(writer)
    assert Process.alive?(writer)
    refute File.exists?(path)
  end

  test "writer restarts keep the daemon boot identity and sequence", %{path: path} do
    RunTelemetry.start_boot()

    {:ok, first} = Writer.start_link(name: nil, path: path)
    assert :ok = Writer.record(first, :lifecycle, %{event: :dispatch})
    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    {:ok, second} = Writer.start_link(name: nil, path: path)
    assert :ok = Writer.flush(second)

    records = read_records(path)

    assert records |> Enum.map(& &1["boot_id"]) |> Enum.uniq() |> length() == 1
    assert Enum.map(records, & &1["sequence"]) == [1, 2, 3]
    assert Enum.at(records, 0)["attributes"]["event"] == "daemon_restart"
    assert Enum.at(records, 2)["attributes"]["event"] == "telemetry_writer_restart"
  end

  defp read_records(path) do
    path
    |> File.stream!([], :line)
    |> Enum.map(&Jason.decode!/1)
  end
end
