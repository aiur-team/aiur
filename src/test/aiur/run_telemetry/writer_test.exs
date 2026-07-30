defmodule Aiur.RunTelemetry.WriterTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Dataset, Retention, Writer}

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

  test "startup retention prunes only complete old boots before appending", %{path: path} do
    {:ok, first} = Writer.start_link(name: nil, path: path, boot_id: "boot-1")
    assert :ok = Writer.record(first, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    first_boot_size = File.stat!(path).size

    {:ok, second} = Writer.start_link(name: nil, path: path, boot_id: "boot-2")
    assert :ok = Writer.record(second, :resource, %{actor: "_daemon", rss_bytes: 2})
    assert :ok = Writer.flush(second)
    :ok = GenServer.stop(second)

    two_boot_size = File.stat!(path).size
    retention = [max_bytes: two_boot_size - first_boot_size]

    {:ok, third} = Writer.start_link(name: nil, path: path, boot_id: "boot-3", retention: retention)
    assert :ok = Writer.record(third, :resource, %{actor: "_daemon", rss_bytes: 3})
    assert :ok = Writer.flush(third)
    :ok = GenServer.stop(third)

    {:ok, fourth} = Writer.start_link(name: nil, path: path, boot_id: "boot-4", retention: retention)
    assert :ok = Writer.record(fourth, :resource, %{actor: "_daemon", rss_bytes: 4})
    assert :ok = Writer.flush(fourth)

    assert File.stat!(path).size <= two_boot_size
    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["boot-3", "boot-4"]
    assert dataset.warnings == []
  end

  test "startup retention drops boots outside the configured age window", %{path: path} do
    old_clock = fn -> ~U[2026-07-01 12:00:00Z] end
    current_clock = fn -> ~U[2026-07-11 12:00:00Z] end

    {:ok, old} = Writer.start_link(name: nil, path: path, boot_id: "old", clock: old_clock)
    assert :ok = Writer.record(old, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(old)
    :ok = GenServer.stop(old)

    {:ok, current} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "current",
        clock: current_clock,
        retention: [max_age_days: 1]
      )

    assert :ok = Writer.flush(current)
    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["current"]
  end

  test "startup retention never prunes the boot a restarted writer resumes", %{path: path} do
    {:ok, first} = Writer.start_link(name: nil, path: path, boot_id: "resumed")
    assert :ok = Writer.record(first, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    {:ok, second} = Writer.start_link(name: nil, path: path, boot_id: "resumed", retention: [max_bytes: 1])
    assert :ok = Writer.flush(second)

    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["resumed"]
    refute Enum.any?(dataset.warnings, &(&1.type == :sequence_gap))
  end

  test "startup retention keeps an oversized complete boot parseable", %{path: path} do
    {:ok, first} = Writer.start_link(name: nil, path: path, boot_id: "oversized")

    assert :ok =
             Writer.record(first, :resource, %{
               actor: "_daemon",
               rss_bytes: 1,
               detail: String.duplicate("x", 8_192)
             })

    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    {:ok, second} =
      Writer.start_link(name: nil, path: path, boot_id: "current", retention: [max_bytes: 1])

    assert :ok = Writer.flush(second)
    assert File.stat!(path).size > 1

    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["oversized", "current"]
    assert dataset.warnings == []
  end

  test "retention treats absent or invalid targets as no-ops", %{path: path} do
    assert :ok = Retention.prune(path)
    assert :ok = Retention.prune(:not_a_path, :not_options)
  end

  test "sanitizes subscribed GitHub anchors before appending", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "anchors")

    send(writer, {
      :event,
      %{
        id: 99,
        topic: "ticket.930.pr.opened",
        source: :github,
        pr: %{"number" => 77, "created_at" => "2026-07-11T13:00:00Z", "body" => "do not persist"}
      }
    })

    assert :ok = Writer.flush(writer)
    records = read_records(path)
    anchor = List.last(records)

    assert anchor["kind"] == "lifecycle"
    assert anchor["timestamp"] == "2026-07-11T13:00:00Z"
    assert anchor["attributes"]["event"] == "pr_opened"
    assert anchor["attributes"]["pr_number"] == 77
    refute inspect(anchor) =~ "do not persist"
  end

  defp read_records(path) do
    path
    |> File.stream!([], :line)
    |> Enum.map(&Jason.decode!/1)
  end
end
