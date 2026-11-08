defmodule Aiur.Events.Export.RetentionTest do
  use ExUnit.Case, async: false
  alias Aiur.Events.Export
  alias Aiur.Events.Export.{Exporter, Layout}

  setup do
    root = Path.join(System.tmp_dir!(), "retention-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, root)

    on_exit(fn ->
      Application.put_env(:aiur, :runtime_state_dir, previous)
      :persistent_term.erase({Export, :status})
      Aiur.TestCleanup.rm_rf!(root)
    end)

    dir = Path.join(root, "events/export")
    File.mkdir_p!(dir)
    now = DateTime.utc_now()
    opts = [name: nil, identity: fn -> {:ok, "instance"} end, subscribe: fn _ -> :ok end, now: fn -> now end]
    %{dir: dir, now: now, opts: opts}
  end

  test "trims whole closed segments by age and never the active one", ctx do
    segments = segments(ctx.now)
    assert {["one"], %{oldest_seq: 3}} = trim(segments, ctx.now, 100)
    assert {["one", "two"], %{oldest_seq: 5}} = trim(segments, DateTime.add(ctx.now, 20, :day), 100)
  end

  test "count trim still applies when clock moves backwards", ctx do
    assert {["one"], %{oldest_seq: 3}} = trim(segments(ctx.now), DateTime.add(ctx.now, -20, :day), 4)
    assert {[], %{oldest_seq: 1}} = trim(segments(ctx.now), DateTime.add(ctx.now, -20, :day), 5)
  end

  test "boot trim preserves retained bytes and publishes floor before failed unlink", ctx do
    seed(ctx)
    File.write!(Layout.segment(ctx.dir, 5), "")
    retained = File.read!(Layout.segment(ctx.dir, 3))
    owner = self()

    unlink = fn path ->
      meta = Jason.decode!(File.read!(Path.join(ctx.dir, "export.meta.json")))
      send(owner, {:unlink, path, meta["oldest_seq"], Export.read(1, 10, ["#"])})
      {:error, :eacces}
    end

    pid = start_supervised!({Exporter, Keyword.put(ctx.opts, :unlink, unlink)})
    state = :sys.get_state(pid)
    assert state.state == :available
    assert_received {:unlink, _, 3, {:reset, %{oldest_seq: 3, head_seq: 4, epoch: "epoch"}}}
    assert File.read!(Layout.segment(ctx.dir, 3)) == retained
    assert File.exists?(Layout.segment(ctx.dir, 1))
    assert {:reset, %{oldest_seq: 3, head_seq: 5, epoch: "epoch"}} = Export.read(1, 10, ["#"])
    assert {:reset, %{head_seq: 5}} = Export.read(6, 10, ["#"])
    assert {:ok, %{records: records}} = Export.read(2, 10, ["no.matches"])
    assert Enum.map(records, & &1["seq"]) == [3, 4, 5]
    stop_supervised!(Exporter)
    pid = start_supervised!({Exporter, ctx.opts})
    assert :sys.get_state(pid).oldest_seq == 3
    refute File.exists?(Layout.segment(ctx.dir, 1))
  end

  test "restart preserves epoch and identity change archives original bytes", ctx do
    seed(ctx)
    pid = start_supervised!({Exporter, ctx.opts})
    assert :sys.get_state(pid).epoch == "epoch"
    stop_supervised!(Exporter)
    pid = start_supervised!({Exporter, ctx.opts})
    assert :sys.get_state(pid).epoch == "epoch"
    stop_supervised!(Exporter)
    bytes = File.read!(Layout.segment(ctx.dir, 3))
    opts = Keyword.put(ctx.opts, :identity, fn -> {:ok, "new-instance"} end)
    pid = start_supervised!({Exporter, opts})
    state = :sys.get_state(pid)
    assert state.state == :available
    assert state.epoch != "epoch"
    assert state.head_seq == 1
    assert File.read!(Path.join(ctx.dir, "old-epoch/seg.3.ndjson")) == bytes
    assert {:reset, %{epoch: epoch}} = Export.read(0, 10, ["#"], epoch: "epoch")
    assert epoch == state.epoch
  end

  test "corrupt metadata rebuilds bounds without archiving readable segments", ctx do
    seed(ctx)
    File.write!(Path.join(ctx.dir, "export.meta.json"), "{broken")
    opts = Keyword.put(ctx.opts, :retention_days, 90)
    pid = start_supervised!({Exporter, opts})
    state = :sys.get_state(pid)
    assert state.state == :available
    assert state.epoch != "epoch"
    assert {state.oldest_seq, state.head_seq} == {1, 5}
    assert Path.wildcard(Path.join(ctx.dir, "old-*")) == []
    assert {:reset, %{oldest_seq: 1, head_seq: 5}} = Export.read(0, 10, ["#"], epoch: "epoch")
  end

  test "segment roll trims closed files without rewriting the retained segment", ctx do
    seed(ctx)
    path = Layout.segment(ctx.dir, 3)
    records = File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    [first, last] = records
    last = Map.put(last, "padding", "")
    padding = Layout.max_bytes() - byte_size(Jason.encode!(first)) - byte_size(Jason.encode!(last)) - 2
    File.write!(path, Jason.encode!(first) <> "\n" <> Jason.encode!(Map.put(last, "padding", String.duplicate("x", padding))) <> "\n")
    before = :crypto.hash(:sha256, File.read!(path))

    clock = fn ->
      case Process.put(:retention_clock_read, true) do
        nil -> DateTime.add(ctx.now, -20, :day)
        true -> ctx.now
      end
    end

    pid = start_supervised!({Exporter, Keyword.put(ctx.opts, :now, clock)})
    state = :sys.get_state(pid)
    assert {state.head_seq, state.oldest_seq} == {5, 3}
    refute File.exists?(Layout.segment(ctx.dir, 1))
    assert :crypto.hash(:sha256, File.read!(path)) == before
  end

  test "empty active segment after interrupted roll preserves the next sequence", ctx do
    Layout.write_meta(ctx.dir, %{instance: "instance", epoch: "epoch", oldest_seq: 5, head_seq: 4})
    File.write!(Layout.segment(ctx.dir, 5), "")
    pid = start_supervised!({Exporter, ctx.opts})
    state = :sys.get_state(pid)
    assert {state.state, state.oldest_seq, state.head_seq, state.epoch} == {:available, 5, 5, "epoch"}
    assert {:ok, %{records: [%{"seq" => 5}]}} = Export.read(4, 10, ["#"])
  end

  defp seed(ctx) do
    for {first, age} <- [{1, -10}, {3, 0}] do
      time = ctx.now |> DateTime.add(age, :day) |> DateTime.to_iso8601()
      records = for seq <- first..(first + 1), do: %{"type" => "gap", "seq" => seq, "scope" => "*", "reason" => "exporter_start", "from" => nil, "to" => time}
      File.write!(Layout.segment(ctx.dir, first), Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n")))
    end

    Layout.write_meta(ctx.dir, %{instance: "instance", epoch: "epoch", oldest_seq: 1, head_seq: 4})
  end

  defp segments(now) do
    for {first, path, age} <- [{1, "one", -10}, {3, "two", 0}, {5, "active", -20}],
        do: %{first: first, path: path, count: 2, newest_at: DateTime.add(now, age, :day)}
  end

  defp trim(segments, now, bound), do: Layout.trim!(segments, %{meta: %{oldest_seq: 1}, now: now, retention_days: 7, retention_max_events: bound})
end
