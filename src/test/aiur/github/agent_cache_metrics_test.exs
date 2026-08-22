defmodule Aiur.GitHub.AgentCacheMetricsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.AgentCacheMetrics
  alias Aiur.Workspace.Layout

  @now ~U[2030-01-02 12:00:00Z]

  test "aggregates active and rotated files inside the rolling window" do
    root = tmp_dir!()
    active = Path.join(root, "agent-cache.tsv")
    rotated = active <> ".1700000000.10"
    earlier_rotation = active <> ".1699990000.9"

    write_rows(active, [
      row(-60, "ticket:2207", "hit", "issue", "2207"),
      row(-50, "ticket:2207", "miss", "issue", "2207", "absent"),
      row(-40, "ticket:2207", "store", "issue", "2207"),
      row(-30, "ticket:2207", "coalesced", "issue", "2207")
    ])

    write_rows(rotated, [
      row(-86_399, "ticket:2206", "hit", "pr", "2206"),
      row(-86_401, "ticket:2206", "miss", "pr", "2206", "expired")
    ])

    write_rows(earlier_rotation, [row(-120, "ticket:2205", "miss", "issue", "2205", "invalidated")])

    snapshot = AgentCacheMetrics.snapshot(paths: [active, rotated, earlier_rotation], clock: fn -> @now end)

    assert snapshot.available?
    assert snapshot.measured?
    refute snapshot.partial?
    assert snapshot.hits == 2
    assert snapshot.misses == 2
    assert snapshot.stores == 1
    assert snapshot.coalesced == 1
    assert snapshot.sample_size == 4
    assert snapshot.hit_ratio == 0.5
    assert snapshot.miss_reasons == %{absent: 1, invalidated: 1}
    assert snapshot.sources_read == 3
    assert snapshot.window_started_at == DateTime.add(@now, -86_400, :second)
    assert snapshot.window_ended_at == @now
  end

  test "old five-column rows remain readable and supported miss reasons are attributed" do
    path = Path.join(tmp_dir!(), "agent-cache.tsv")

    rows = [
      row(-70, "ticket:1", "miss", "issue", "1"),
      row(-60, "ticket:1", "miss", "issue", "1", "absent"),
      row(-50, "ticket:1", "miss", "issue", "1", "expired"),
      row(-40, "ticket:1", "miss", "issue", "1", "invalidated"),
      row(-30, "ticket:1", "miss", "issue", "1", "bypassed"),
      row(-20, "ticket:1", "miss", "issue", "1", "clock-skewed"),
      row(-10, "ticket:1", "miss", "issue", "1", "corrupt"),
      row(-5, "ticket:1", "miss", "issue", "1", "torn")
    ]

    write_rows(path, rows)
    snapshot = AgentCacheMetrics.snapshot(paths: [path], clock: fn -> @now end)

    assert snapshot.misses == 8

    assert snapshot.miss_reasons == %{
             :absent => 1,
             :bypassed => 1,
             :"clock-skewed" => 1,
             :corrupt => 1,
             :expired => 1,
             :invalidated => 1,
             :torn => 1,
             :unknown => 1
           }
  end

  test "malformed rows and unreadable sources fail open as partial coverage" do
    root = tmp_dir!()
    valid = Path.join(root, "agent-cache.tsv")
    unreadable = valid <> ".1"
    write_rows(valid, [row(-10, "ticket:1", "hit", "issue", "1"), "not\ta\tvalid\trow"])
    write_rows(unreadable, [row(-10, "ticket:2", "miss", "issue", "2")])

    read_fun = fn
      ^unreadable -> {:error, :eacces}
      path -> File.read(path)
    end

    snapshot = AgentCacheMetrics.snapshot(paths: [valid, unreadable], clock: fn -> @now end, read_fun: read_fun)

    assert snapshot.available?
    assert snapshot.measured?
    assert snapshot.partial?
    assert snapshot.malformed_rows == 1
    assert snapshot.skipped_sources == 1
    assert snapshot.sources_read == 1
    assert snapshot.hits == 1
  end

  test "absent sources and a valid zero-denominator source are distinct unmeasured snapshots" do
    missing = AgentCacheMetrics.snapshot(paths: [], clock: fn -> @now end)

    refute missing.available?
    refute missing.measured?
    assert missing.sample_size == 0

    path = Path.join(tmp_dir!(), "agent-cache.tsv")
    write_rows(path, [row(-10, "ticket:1", "store", "issue", "1")])
    zero_denominator = AgentCacheMetrics.snapshot(paths: [path], clock: fn -> @now end)

    assert zero_denominator.available?
    refute zero_denominator.measured?
    assert zero_denominator.stores == 1
    assert zero_denominator.sample_size == 0
    assert is_nil(zero_denominator.hit_ratio)
  end

  test "a source past the read budget is skipped as partial coverage instead of read in full" do
    root = tmp_dir!()
    valid = Path.join(root, "agent-cache.tsv")
    oversized = Path.join(root, "agent-cache.tsv.overflow")
    write_rows(valid, [row(-10, "ticket:1", "hit", "issue", "1")])
    write_rows(oversized, [row(-10, "ticket:1", "hit", "issue", "1")])

    # Archives are rotated at ~1 MiB each and retained for ~25 hours, so on a
    # host without GNU/BSD find the in-window pile can grow without a prune. The
    # 30-second read pass must not then read an unbounded amount of disk: once a
    # source would push the pass past its budget it is skipped and reported as
    # partial coverage, exactly like an unreadable file.
    stat_fun = fn
      ^oversized -> {:ok, %{mtime: DateTime.to_unix(@now), size: 10 * 1024 * 1024}}
      path -> File.stat(path, time: :posix)
    end

    reads = :counters.new(1, [])

    read_fun = fn source ->
      :counters.add(reads, 1, 1)
      File.read(source)
    end

    snapshot = AgentCacheMetrics.snapshot(paths: [valid, oversized], clock: fn -> @now end, stat_fun: stat_fun, read_fun: read_fun)

    assert snapshot.available?
    assert snapshot.partial?
    assert snapshot.skipped_sources == 1
    assert snapshot.sources_read == 1
    assert snapshot.hits == 1
    assert :counters.get(reads, 1) == 1
  end

  test "discovers counters below each workspace dot directory" do
    root = tmp_dir!()

    path =
      root
      |> Layout.issue_workspace_path("2207")
      |> Path.join(".aiur-runtime/github-quota/agent-cache.tsv")

    File.mkdir_p!(Path.dirname(path))
    write_rows(path, [row(-10, "ticket:2207", "hit", "issue", "2207")])

    snapshot = AgentCacheMetrics.snapshot(workspace_root: root, clock: fn -> @now end)

    assert snapshot.sources_read == 1
    assert snapshot.hits == 1
  end

  test "one sampler read serves every viewer until the next cadence" do
    path = Path.join(tmp_dir!(), "agent-cache.tsv")
    write_rows(path, [row(-10, "ticket:2207", "hit", "issue", "2207")])
    counter = :counters.new(1, [])

    read_fun = fn source ->
      :counters.add(counter, 1, 1)
      File.read(source)
    end

    sampler =
      start_supervised!({AgentCacheMetrics, name: nil, paths: [path], clock: fn -> @now end, read_fun: read_fun, interval_ms: 0})

    assert AgentCacheMetrics.cached_snapshot(sampler).hits == 1
    assert AgentCacheMetrics.cached_snapshot(sampler).hits == 1
    assert :counters.get(counter, 1) == 1

    assert :ok = AgentCacheMetrics.sample(sampler)
    assert AgentCacheMetrics.cached_snapshot(sampler).hits == 1
    assert :counters.get(counter, 1) == 2
  end

  test "cadence skips retained sources whose final write predates the window" do
    path = Path.join(tmp_dir!(), "agent-cache.tsv.older")
    write_rows(path, [row(-86_401, "ticket:1", "miss", "issue", "1", "expired")])
    File.touch!(path, DateTime.to_unix(@now) - 86_401)
    reads = :counters.new(1, [])

    read_fun = fn source ->
      :counters.add(reads, 1, 1)
      File.read(source)
    end

    sampler =
      start_supervised!({AgentCacheMetrics, name: nil, paths: [path], clock: fn -> @now end, read_fun: read_fun, interval_ms: 0})

    refute AgentCacheMetrics.cached_snapshot(sampler).measured?
    assert :ok = AgentCacheMetrics.sample(sampler)
    assert :counters.get(reads, 1) == 0
  end

  defp row(offset_seconds, consumer, event, kind, id, reason \\ nil) do
    columns = [Integer.to_string(DateTime.to_unix(DateTime.add(@now, offset_seconds, :second))), consumer, event, kind, id]
    columns = if reason, do: columns ++ [reason], else: columns
    Enum.join(columns, "\t")
  end

  defp write_rows(path, rows) do
    File.write!(path, Enum.join(rows, "\n") <> "\n")
    File.touch!(path, DateTime.to_unix(@now))
  end

  defp tmp_dir! do
    path = Aiur.TestSupport.tmp_root!("agent-cache-metrics")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
