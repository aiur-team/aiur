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

  test "named writers keep admission tied to the current process", %{path: path} do
    name = :"writer-#{System.unique_integer([:positive])}"
    {:ok, first} = Writer.start_link(name: name, path: path, boot_id: "named-1")

    assert :ok = Writer.record(name, :resource, %{actor: "first"})
    assert :ok = Writer.flush(name)
    assert :ok = GenServer.stop(first)

    {:ok, second} = Writer.start_link(name: name, path: path, boot_id: "named-2")

    for index <- 1..256 do
      assert :ok = Writer.record(name, :resource, %{actor: index})
    end

    assert :ok = Writer.flush(name)
    assert Process.alive?(second)
    assert length(read_records(path)) == 259
  end

  test "bounds the mailbox while a write is slow", %{path: path} do
    test_pid = self()
    writes = :atomics.new(1, signed: false)
    blocked = :atomics.new(1, signed: false)

    write_fun = fn path, contents ->
      count = :atomics.add_get(writes, 1, 1)
      send(test_pid, {:write_started, count, self()})

      if count == 2 and :atomics.get(blocked, 1) == 1 do
        receive do
          :release -> :ok
        end
      end

      File.write(path, contents, [:append])
    end

    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "bounded", write_fun: write_fun)
    assert_receive {:write_started, 1, ^writer}, 2_000

    :atomics.put(blocked, 1, 1)
    assert :ok = Writer.record(writer, :resource, %{actor: "first"})
    assert_receive {:write_started, 2, ^writer}, 2_000

    1..5_000
    |> Task.async_stream(fn index -> Writer.record(writer, :resource, %{actor: index}) end, max_concurrency: 16)
    |> Enum.to_list()

    assert {:message_queue_len, queue_len} = Process.info(writer, :message_queue_len)
    assert queue_len <= 256
    assert queue_len < 5_000

    :atomics.put(blocked, 1, 0)
    send(writer, :release)
    assert :ok = Writer.flush(writer)

    write_count = :atomics.get(writes, 1)
    assert write_count > 2
    # restart + admitted records + one admission_overflow marker on drain
    assert write_count <= 258
    assert length(read_records(path)) == write_count

    assert :ok = Writer.record(writer, :resource, %{actor: :after_drain})
    assert :ok = Writer.flush(writer)
    assert :atomics.get(writes, 1) == write_count + 1
  end

  test "overflow logs once on entry and drains into one marker record", %{path: path} do
    import ExUnit.CaptureLog

    writes = :atomics.new(1, signed: false)
    blocked = :atomics.new(1, signed: false)

    write_fun = fn path, contents ->
      :atomics.add(writes, 1, 1)

      if :atomics.get(blocked, 1) == 1 do
        receive do
          :release -> :ok
        end
      end

      File.write(path, contents, [:append])
    end

    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "overflow", write_fun: write_fun)

    overload = fn dropped ->
      :atomics.put(blocked, 1, 1)
      # One record occupies the writer inside the blocked write; 255 more fill
      # the pending window; every further record is refused at admission.
      capture_log(fn ->
        for index <- 1..(256 + dropped) do
          assert :ok = Writer.record(writer, :resource, %{actor: index})
        end
      end)
    end

    log = overload.(40)
    assert length(Regex.scan(~r/admission_overflow/, log)) == 1

    :atomics.put(blocked, 1, 0)
    send(writer, :release)
    assert :ok = Writer.flush(writer)

    markers =
      path
      |> read_records()
      |> Enum.filter(&(&1["kind"] == "warning" and &1["attributes"]["reason"] == "admission_overflow"))

    assert [%{"attributes" => %{"dropped_count" => 40}}] = markers

    # A later, distinct overload logs again and produces its own marker.
    second_log = overload.(3)
    assert length(Regex.scan(~r/admission_overflow/, second_log)) == 1

    :atomics.put(blocked, 1, 0)
    send(writer, :release)
    assert :ok = Writer.flush(writer)

    dropped_counts =
      path
      |> read_records()
      |> Enum.filter(&(&1["kind"] == "warning" and &1["attributes"]["reason"] == "admission_overflow"))
      |> Enum.map(& &1["attributes"]["dropped_count"])

    assert dropped_counts == [40, 3]
  end

  test "no overflow marker is written when nothing was dropped", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "quiet")

    assert :ok = Writer.record(writer, :resource, %{actor: "calm"})
    assert :ok = Writer.flush(writer)

    refute Enum.any?(read_records(path), &(&1["kind"] == "warning"))
  end

  test "malformed submissions and ignored messages remain fail-open", %{path: path} do
    assert :ok = Writer.record(self(), :resource, %{})
    assert :ok = Writer.record(:missing_writer, :resource, %{})
    assert :ok = Writer.record(:missing_writer, :resource, %{}, :invalid)
    assert :ok = Writer.record(:missing_writer, :resource, :invalid)
    assert :ok = Writer.flush(:missing_writer)

    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "defensive")

    assert :ok = Writer.record_batch(writer, [:invalid_record])
    assert :ok = Writer.record_batch(writer, [{123, %{event: :invalid_kind}}])
    assert :ok = Writer.record(writer, :resource, %{}, timestamp: :invalid_timestamp)
    send(writer, {:event, %{}})
    send(writer, :ignored_message)

    assert :ok = Writer.flush(writer)
    assert length(read_records(path)) == 3
  end

  test "writer catches failures from the append function", %{path: path} do
    write_fun = fn _path, _contents -> throw(:writer_exploded) end
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "exception", write_fun: write_fun)

    assert :ok = Writer.record(writer, :resource, %{actor: "test"})
    assert :ok = Writer.flush(writer)
    assert Process.alive?(writer)
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
