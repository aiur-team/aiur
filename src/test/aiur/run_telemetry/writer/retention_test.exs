defmodule Aiur.RunTelemetry.Writer.RetentionTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry.{Dataset, Retention, Writer}

  setup do
    root =
      Aiur.TestSupport.tmp_root!("aiur-telemetry-writer")

    path = Path.join(root, "log/telemetry.ndjson")
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: path, root: root}
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

  test "periodic retention failure does not crash or stall the writer", %{path: _path, root: root} do
    import ExUnit.CaptureLog

    # The path reported to Retention.prune must be a directory so File.stream! raises
    # EISDIR. The write_fun redirects actual appends to a separate file so writes succeed.
    actual_file = Path.join(root, "actual.ndjson")
    dir_path = Path.join(root, "dir-as-path")
    File.mkdir_p!(dir_path)
    write_fun = fn _path, data -> File.write(actual_file, data, [:append]) end
    # Empty directories can report zero bytes. Age pruning forces the scan
    # that exercises EISDIR instead of taking the under-size fast path.
    retention = [max_bytes: 1, max_age_days: 1, prune_interval_bytes: 1]

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
end
