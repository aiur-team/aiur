defmodule Aiur.RunTelemetry.WriterTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.{Exchange, GithubFirehose}
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Dataset, Retention, Writer}

  setup do
    root =
      Path.join(System.tmp_dir!(), "aiur-telemetry-writer-#{System.unique_integer([:positive])}")

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

    assert Enum.map(records, & &1["record_id"]) == [
             "boot-1:1",
             "boot-1:2",
             "boot-2:1",
             "boot-2:2"
           ]

    assert Enum.at(records, 1)["timestamp"] == "2026-07-11T12:00:00Z"
    assert Enum.at(records, 1)["attributes"] == %{"event" => "dispatch", "ticket" => "930"}
    assert Enum.at(records, 2)["attributes"]["existing_records"] == true
  end

  test "concurrent producers persist whole uniquely sequenced lines", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "concurrent")

    1..20
    |> Task.async_stream(
      fn index ->
        Writer.record(writer, :resource, %{actor: "ticket:#{index}", rss_bytes: index})
      end,
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

  test "writer tolerates malformed caller values while retaining valid batch entries", %{
    path: path
  } do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    {:ok, writer} = Writer.start_link(name: name, path: path, boot_id: "guarded")

    assert :ok = Writer.record(writer, :resource, :not_a_map, :not_options)

    assert :ok =
             Writer.record_batch(writer, [
               {:resource, %{actor: "_daemon", rss_bytes: 42}},
               :not_a_record
             ])

    assert :ok = Writer.flush(writer)
    assert :ok = Writer.flush(:writer_that_does_not_exist)

    records = read_records(path)
    assert Enum.map(records, & &1["kind"]) == ["restart", "resource"]
  end

  test "writer normalizes opaque batch values and ignores unrelated mailbox messages", %{
    path: path
  } do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "normalized")

    send(writer, {:event, %{}})
    send(writer, :unrelated)

    assert :ok =
             Writer.record_batch(writer, [{42, %{actor: "_daemon"}}], timestamp: :not_a_timestamp)

    assert :ok = Writer.flush(writer)

    records = read_records(path)
    assert Enum.map(records, & &1["kind"]) == ["restart", "42"]
    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(Enum.at(records, 1)["timestamp"])
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

    {:ok, writer} =
      Writer.start_link(name: nil, path: path, boot_id: "bounded", write_fun: write_fun)

    assert_receive {:write_started, 1, ^writer}, 2_000

    :atomics.put(blocked, 1, 1)
    assert :ok = Writer.record(writer, :resource, %{actor: "first"})
    assert_receive {:write_started, 2, ^writer}, 2_000

    1..5_000
    |> Task.async_stream(fn index -> Writer.record(writer, :resource, %{actor: index}) end,
      max_concurrency: 16
    )
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

    {:ok, writer} =
      Writer.start_link(name: nil, path: path, boot_id: "overflow", write_fun: write_fun)

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

    {:ok, writer} =
      Writer.start_link(name: nil, path: path, boot_id: "exception", write_fun: write_fun)

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

  test "startup retention prunes only complete old boots before appending", %{path: path} do
    {:ok, first} = Writer.start_link(name: nil, path: path, boot_id: "boot-1")
    assert :ok = Writer.record(first, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.record(first, :warning, %{reason: :admission_overflow, dropped_count: 7})
    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    first_boot_size = File.stat!(path).size

    {:ok, second} = Writer.start_link(name: nil, path: path, boot_id: "boot-2")
    assert :ok = Writer.record(second, :resource, %{actor: "_daemon", rss_bytes: 2})
    assert :ok = Writer.flush(second)
    :ok = GenServer.stop(second)

    two_boot_size = File.stat!(path).size
    retention = [max_bytes: two_boot_size - first_boot_size]

    {:ok, third} =
      Writer.start_link(name: nil, path: path, boot_id: "boot-3", retention: retention)

    assert :ok = Writer.record(third, :resource, %{actor: "_daemon", rss_bytes: 3})
    assert :ok = Writer.flush(third)
    :ok = GenServer.stop(third)

    {:ok, fourth} =
      Writer.start_link(name: nil, path: path, boot_id: "boot-4", retention: retention)

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

    {:ok, second} =
      Writer.start_link(name: nil, path: path, boot_id: "resumed", retention: [max_bytes: 1])

    assert :ok = Writer.flush(second)

    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["resumed"]
    refute Enum.any?(dataset.warnings, &(&1.type == :sequence_gap))
  end

  test "startup retention keeps an oversized complete boot parseable", %{path: path} do
    old_clock = fn -> ~U[2026-07-01 12:00:00Z] end
    current_clock = fn -> ~U[2026-07-01 12:01:00Z] end

    {:ok, first} =
      Writer.start_link(name: nil, path: path, boot_id: "oversized", clock: old_clock)

    assert :ok =
             Writer.record(
               first,
               :resource,
               %{
                 actor: "_daemon",
                 rss_bytes: 1,
                 detail: String.duplicate("x", 8_192)
               },
               timestamp: old_clock.()
             )

    assert :ok = Writer.flush(first)
    :ok = GenServer.stop(first)

    {:ok, second} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "current",
        clock: current_clock,
        retention: [max_bytes: 1]
      )

    assert :ok = Writer.flush(second)
    assert File.stat!(path).size > 1

    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["oversized", "current"]
    assert dataset.warnings == []
  end

  test "size retention keeps a contiguous newest suffix", %{path: path} do
    {:ok, old} = Writer.start_link(name: nil, path: path, boot_id: "old")
    assert :ok = Writer.record(old, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(old)
    :ok = GenServer.stop(old)

    old_size = File.stat!(path).size

    {:ok, middle} = Writer.start_link(name: nil, path: path, boot_id: "mid")

    assert :ok =
             Writer.record(middle, :resource, %{
               actor: "_daemon",
               detail: String.duplicate("x", 8_192),
               rss_bytes: 1
             })

    assert :ok = Writer.flush(middle)
    :ok = GenServer.stop(middle)

    middle_size = File.stat!(path).size - old_size

    {:ok, newest} = Writer.start_link(name: nil, path: path, boot_id: "new")
    assert :ok = Writer.record(newest, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(newest)
    :ok = GenServer.stop(newest)

    newest_size = File.stat!(path).size - old_size - middle_size
    assert :ok = Retention.prune(path, max_bytes: old_size + newest_size)

    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["new"]
    assert dataset.warnings == []
  end

  test "periodic retention prunes accumulated old boots during a running session", %{path: path} do
    {:ok, old} = Writer.start_link(name: nil, path: path, boot_id: "old-boot")
    assert :ok = Writer.record(old, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(old)
    :ok = GenServer.stop(old)

    old_size = File.stat!(path).size

    # max_bytes equals old_size so the old boot fits at startup, but the restart
    # marker appended during init pushes the total over the cap. With
    # prune_interval_bytes: 1 the threshold is crossed immediately, triggering a
    # segment roll + prune that removes the old boot.
    retention = [max_bytes: old_size, prune_interval_bytes: 1]

    {:ok, current} =
      Writer.start_link(name: nil, path: path, boot_id: "current", retention: retention)

    assert :ok = Writer.flush(current)

    assert {:ok, dataset} = Dataset.build(path)
    assert Dataset.boot_ids(dataset) == ["current"]
    assert dataset.warnings == []
  end

  test "periodic retention bounds a single boot that exceeds the cap three times over", %{
    path: path
  } do
    # Measure one restart + one resource record so we can set a deterministic cap.
    {:ok, probe} = Writer.start_link(name: nil, path: path, boot_id: "probe")
    assert :ok = Writer.record(probe, :resource, %{actor: "_daemon", rss_bytes: 1})
    assert :ok = Writer.flush(probe)
    :ok = GenServer.stop(probe)

    one_boot_size = File.stat!(path).size
    File.rm!(path)

    # Cap = one boot's worth; prune fires after every record.
    # Writing 6 records (3x cap) in a single boot must leave the file bounded.
    retention = [max_bytes: one_boot_size, prune_interval_bytes: 1]

    {:ok, writer} =
      Writer.start_link(name: nil, path: path, boot_id: "big-boot", retention: retention)

    for sample <- 1..6 do
      assert :ok =
               Writer.record(writer, :resource, %{actor: "_daemon", rss_bytes: 1, sample: sample})
    end

    assert :ok = Writer.flush(writer)

    # File stays bounded: at most one full boot + one segment boundary per prune cycle.
    assert File.stat!(path).size < one_boot_size * 3
    assert {:ok, dataset} = Dataset.build(path)
    assert dataset.warnings == []
    assert Dataset.boot_ids(dataset) == ["big-boot"]

    assert Enum.map(
             Enum.filter(dataset.records, &(&1.kind == "resource")),
             & &1.attributes["sample"]
           ) == [6]

    assert dataset.restarts == []

    assert {:ok, current_dataset} = Dataset.build(path, session: :current)

    assert Enum.map(
             Enum.filter(current_dataset.records, &(&1.kind == "resource")),
             & &1.attributes["sample"]
           ) == [6]
  end

  test "a failed segment boundary skips periodic pruning", %{path: path} do
    writes = :atomics.new(1, signed: false)

    write_fun = fn target, contents ->
      if :atomics.add_get(writes, 1, 1) == 2 do
        {:error, :eio}
      else
        File.write(target, contents, [:append])
      end
    end

    {:ok, writer} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "boundary-failure",
        retention: [max_bytes: 1, prune_interval_bytes: 1],
        write_fun: write_fun
      )

    assert Process.alive?(writer)
    assert {:ok, dataset} = Dataset.build(path)
    assert dataset.warnings == []
    assert Dataset.boot_ids(dataset) == ["boundary-failure"]
  end

  test "segment rolls preserve lifecycle interval pairing", %{path: path} do
    retention = [max_bytes: 1, prune_interval_bytes: 1]
    boundary_at = ~U[2026-07-11 12:00:01Z]

    {:ok, writer} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "lifecycle-roll",
        retention: retention,
        clock: fn -> boundary_at end
      )

    start = %{
      ticket: "1339",
      attempt_id: "attempt",
      event: "build_test",
      boundary: "start",
      operation_id: "build"
    }

    finish = %{
      ticket: "1339",
      attempt_id: "attempt",
      event: "build_test",
      boundary: "end",
      operation_id: "build"
    }

    assert :ok = Writer.record(writer, :lifecycle, start, timestamp: ~U[2026-07-11 12:00:00Z])
    assert :ok = Writer.record(writer, :lifecycle, finish, timestamp: ~U[2026-07-11 12:00:02Z])
    assert :ok = Writer.flush(writer)

    assert {:ok, dataset} = Dataset.build(path)
    assert [%{status: "closed"}] = dataset.tickets["1339"].intervals
    assert dataset.warnings == []
  end

  test "periodic retention failure does not crash or stall the writer", %{path: path, root: root} do
    import ExUnit.CaptureLog

    # The path reported to Retention.prune must be a directory so File.stream! raises
    # EISDIR. The write_fun redirects actual appends to a separate file so writes succeed.
    actual_file = Path.join(root, "actual.ndjson")
    dir_path = Path.join(root, "dir-as-path")
    File.mkdir_p!(dir_path)
    write_fun = fn _path, data -> File.write(actual_file, data, [:append]) end
    retention = [max_bytes: 1, prune_interval_bytes: 1]

    log =
      capture_log(fn ->
        {:ok, w} =
          Writer.start_link(
            name: nil,
            path: dir_path,
            boot_id: "err-boot",
            retention: retention,
            write_fun: write_fun
          )

        assert :ok = Writer.record(w, :resource, %{actor: "_daemon", rss_bytes: 1})
        assert :ok = Writer.flush(w)
        assert Process.alive?(w)
      end)

    assert log =~ "retention_failed"
  end

  test "retention treats absent or invalid targets as no-ops", %{path: path} do
    assert :ok = Retention.prune(path)
    assert :ok = Retention.prune(:not_a_path, :not_options)
  end

  test "backfills a pre-boot merged PR as a telemetry lifecycle anchor", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "anchors")
    :ok = Exchange.subscribe("ticket.930.pr.merged")

    firehose_event = %{
      "id" => "merged-100",
      "type" => "PullRequestEvent",
      "created_at" => "2026-07-11T13:01:00Z",
      "actor" => %{"login" => "merger"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 77,
          "merged" => true,
          "merged_at" => "2026-07-11T13:01:00Z",
          "head" => %{"ref" => "aiur/930-analytics", "sha" => "head-77"}
        }
      }
    }

    assert {:ok, %{count: 0}} =
             GithubFirehose.poll(
               request_fun: fn _request ->
                 {:ok, %{status: 200, headers: [{"ETag", ~s("writer-merge")}], body: [firehose_event]}}
               end,
               recent_merge_fun: fn _merge -> {:ok, :stored} end,
               boot_time: ~U[2026-07-11 13:03:00Z] |> DateTime.to_unix(),
               telemetry_writer: writer
             )

    assert :ok = Writer.flush(writer)
    refute_receive {:event, %{topic: "ticket.930.pr.merged"}}

    records = read_records(path)
    [merged] = Enum.take(records, -1)

    assert merged["kind"] == "lifecycle"
    assert merged["timestamp"] == "2026-07-11T13:01:00Z"
    assert merged["attributes"]["event"] == "pr_merged"
    assert merged["attributes"]["pr_number"] == 77
    assert merged["attributes"]["source"] == "github_reconciliation"

    # The anchor stays durable for full-log reconciliation, but a dashboard
    # scoped to this daemon boot must not call a historical merge "this run".
    assert {:ok, dataset} = Dataset.build(path, session: :current, boot_id: "anchors")
    current = Dataset.filter(dataset, boot_id: "anchors")
    refute Enum.any?(current.records, &(&1.attributes["event"] == "pr_merged"))
    assert current.tickets == %{}
  end

  test "persists a live merged PR received through the firehose exchange", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "live-anchors")

    firehose_event = %{
      "id" => "live-merged-100",
      "type" => "PullRequestEvent",
      "created_at" => "2026-07-11T13:01:00Z",
      "actor" => %{"login" => "merger"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 77,
          "merged" => true,
          "merged_at" => "2026-07-11T13:01:00Z",
          "head" => %{"ref" => "aiur/930-analytics", "sha" => "live-head-77"}
        }
      }
    }

    assert {:ok, %{count: 1}} =
             GithubFirehose.poll(
               request_fun: fn _request ->
                 {:ok, %{status: 200, headers: [{"ETag", ~s("live-writer-merge")}], body: [firehose_event]}}
               end,
               recent_merge_fun: fn _merge -> {:ok, :stored} end,
               boot_time: ~U[2026-07-11 13:00:00Z] |> DateTime.to_unix()
             )

    assert :ok = Writer.flush(writer)

    records = read_records(path)
    [merged] = Enum.take(records, -1)

    assert merged["kind"] == "lifecycle"
    assert merged["timestamp"] == "2026-07-11T13:01:00Z"
    assert merged["attributes"]["event"] == "pr_merged"
    assert merged["attributes"]["pr_number"] == 77
    assert merged["attributes"]["source"] == "github"

    assert {:ok, dataset} = Dataset.build(path, session: :current, boot_id: "live-anchors")
    current = Dataset.filter(dataset, boot_id: "live-anchors")
    assert Enum.any?(current.records, &(&1.attributes["event"] == "pr_merged"))
    assert Map.has_key?(current.tickets, "930")
  end

  defp read_records(path) do
    path
    |> File.stream!([], :line)
    |> Enum.map(&Jason.decode!/1)
  end
end
