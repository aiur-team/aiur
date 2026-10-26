defmodule Aiur.Events.Export.ExporterTest do
  use ExUnit.Case, async: false
  alias Aiur.Events.{Exchange, Export, Journal}
  alias Aiur.Events.Export.{Exporter, Layout}

  setup do
    root = Path.join(System.tmp_dir!(), "exporter-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, root)
    :persistent_term.erase({Export, :status})

    on_exit(fn ->
      Application.put_env(:aiur, :runtime_state_dir, previous)
      :persistent_term.erase({Export, :status})
      Aiur.TestCleanup.rm_rf!(root)
    end)

    exchange = start_supervised!({Exchange, []})
    owner = self()

    opts = [
      name: nil,
      identity: fn -> {:ok, "test/instance"} end,
      subscribe: fn pattern -> Exchange.subscribe(pattern, exchange) end,
      on_unavailable: fn reason -> send(owner, {:unavailable, reason}) end,
      on_appended: fn head, epoch -> send(owner, {:appended, head, epoch}) end
    ]

    {:ok, root: root, dir: Path.join(root, "events/export"), opts: opts, exchange: exchange}
  end

  test "start writes one gap then exported events with dense seq and notifications", ctx do
    pid = start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, epoch}, 2000
    assert Exchange.publish("ticket.42.pr.merged", event(101), ctx.exchange) == 1
    assert_receive {:appended, 2, ^epoch}, 2000
    Exchange.publish("ticket.42.pr.merged", event(102), ctx.exchange)
    assert_receive {:appended, 3, ^epoch}, 2000
    send(pid, {:event, event(103, "executor.private")})
    :sys.get_state(pid)
    assert {:ok, %{records: [gap, first, second], head_seq: 3}} = Export.read(0, 500, ["#"])
    assert gap["type"] == "gap"
    assert gap["from"] == nil
    assert gap["scope"] == "*"
    assert Enum.map([gap, first, second], & &1["seq"]) == [1, 2, 3]
    assert Enum.map([first, second], & &1["id"]) == [101, 102]
    refute Jason.encode!(first) =~ "private text"
    refute_receive {:appended, _, _}, 20
    assert Bitwise.band(File.stat!(ctx.dir).mode, 0o777) == 0o700

    for file <- Path.wildcard(Path.join(ctx.dir, "*")) do
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    end
  end

  test "restart writes one gap and recovers seq from segment rather than stale meta", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, epoch}, 2000
    Exchange.publish("ticket.42.pr.merged", event(101), ctx.exchange)
    assert_receive {:appended, 2, ^epoch}, 2000
    stop_supervised!(Exporter)
    meta_path = Path.join(ctx.dir, "export.meta.json")
    meta = Jason.decode!(File.read!(meta_path)) |> Map.put("head_seq", 0)
    File.write!(meta_path, Jason.encode!(meta))
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 3, ^epoch}, 2000
    assert {:ok, %{records: [gap]}} = Export.read(2, 500, ["#"])
    assert gap["seq"] == 3
    assert gap["reason"] == "exporter_start"
    assert gap["from"] == nil
  end

  test "no instance id means no subscription or file and one unavailable report", ctx do
    pid = start_supervised!({Exporter, Keyword.put(ctx.opts, :identity, fn -> {:error, :identity_unavailable} end)})
    assert_receive {:unavailable, :identity_unavailable}, 2000
    assert Exchange.bindings_for(pid, ctx.exchange) == []
    refute File.exists?(ctx.root)
    send(pid, {:event, event(1)})
    assert :sys.get_state(pid).dropped == 1
    assert Export.status().reason == :identity_unavailable
    assert Export.read(0, 10, ["#"]) == {:error, :events_unavailable}
    refute_receive {:unavailable, _}, 20
  end

  test "interior corruption is preserved and reported once per boot", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, _}, 2000
    stop_supervised!(Exporter)
    path = Layout.segment(ctx.dir, 1)
    bytes = File.read!(path) <> "broken\n" <> File.read!(path) <> "torn"
    File.write!(path, bytes)

    for _ <- 1..2 do
      pid = start_supervised!({Exporter, ctx.opts})
      assert_receive {:unavailable, :journal_corrupt}, 2000
      assert Export.status().reason == :journal_corrupt
      send(pid, {:event, event(1)})
      :sys.get_state(pid)
      assert File.read!(path) == bytes
      refute_receive {:unavailable, _}, 20
      stop_supervised!(Exporter)
    end
  end

  test "writer repairs only torn tail then appends restart gap", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, epoch}, 2000
    stop_supervised!(Exporter)
    path = Layout.segment(ctx.dir, 1)
    File.write!(path, "{half", [:append])
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 2, ^epoch}, 2000
    assert {:ok, [first, second]} = Layout.replay(path, false)
    assert first["seq"] == 1
    assert second["seq"] == 2
    assert second["from"] == first["to"]
  end

  test "append failure stays alive, counts dropped events and reports once", ctx do
    append = fn path, record ->
      if record["type"] == "gap", do: Journal.append(path, record), else: {:error, :enospc}
    end

    pid = start_supervised!({Exporter, Keyword.put(ctx.opts, :append, append)})
    assert_receive {:appended, 1, _}, 2000
    send(pid, {:event, event(1)})
    assert_receive {:unavailable, :append_failed}, 2000
    send(pid, {:event, event(2)})
    assert :sys.get_state(pid).dropped == 1
    assert Process.alive?(pid)
    assert Export.status().reason == :append_failed
    refute_receive {:unavailable, _}, 20
  end

  test "runtime directory failure has its own unavailable cause", ctx do
    start_supervised!({Exporter, Keyword.put(ctx.opts, :directory, fn -> {:error, :not_qualified} end)})
    assert_receive {:unavailable, :runtime_dir_unavailable}, 2000
    assert Export.status().reason == :runtime_dir_unavailable
    refute File.exists?(ctx.root)
  end

  test "status reads do not wait for suspended exporter", ctx do
    pid = start_supervised!({Exporter, Keyword.delete(ctx.opts, :name)})
    assert_receive {:appended, 1, epoch}, 2000
    :sys.suspend(pid)
    task = Task.async(fn -> Export.status() end)

    try do
      assert %{state: :available, head_seq: 1, epoch: ^epoch} = Task.await(task, 100)
    after
      :sys.resume(pid)
    end
  end

  test "overlapping catalog patterns deliver a system event once", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, epoch}, 2000
    topic = "system.build_gate.hold_timeout"
    assert Exchange.publish(topic, event(1, topic), ctx.exchange) == 1
    assert_receive {:appended, 2, ^epoch}, 2000
    refute_receive {:appended, _, _}, 20
    assert {:ok, %{records: [%{"seq" => 2, "topic" => ^topic}]}} = Export.read(1, 500, ["#"])
  end

  test "reader never truncates torn tail and hides records beyond durable head", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, _}, 2000
    path = Layout.segment(ctx.dir, 1)
    record = %{"type" => "event", "seq" => 2, "v" => 1, "id" => 4, "topic" => "ticket.42.pr.merged", "instance" => "test/instance"}
    File.write!(path, Jason.encode!(record) <> "\n{half", [:append])
    bytes = File.read!(path)
    assert {:ok, %{records: [%{"type" => "gap", "seq" => 1}]}} = Export.read(0, 10, ["#"])
    assert File.read!(path) == bytes
  end

  test "reader filters topics, limits results and resets bad cursors", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, epoch}, 2000
    Exchange.publish("ticket.42.pr.merged", event(1), ctx.exchange)
    assert_receive {:appended, 2, ^epoch}, 2000
    assert {:ok, %{records: [%{"seq" => 1}]}} = Export.read(0, 1, ["#"])
    assert {:ok, %{records: []}} = Export.read(1, 10, ["ticket.43.#"])
    assert {:reset, %{head_seq: 2, epoch: ^epoch}} = Export.read(3, 10, ["#"])
    assert {:reset, %{epoch: ^epoch}} = Export.read(0, 10, ["#"], epoch: "old")
  end

  test "full segment rolls before append and restart uses newest numeric segment", ctx do
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 1, epoch}, 2000
    path = Layout.segment(ctx.dir, 1)
    gap = File.read!(path) |> String.trim() |> Jason.decode!() |> Map.put("padding", "")
    padding_size = Layout.max_bytes() - byte_size(Jason.encode!(gap)) - 1
    File.write!(path, Jason.encode!(Map.put(gap, "padding", String.duplicate("x", padding_size))) <> "\n")
    Exchange.publish("ticket.42.pr.merged", event(1), ctx.exchange)
    assert_receive {:appended, 2, ^epoch}, 2000
    assert File.stat!(path).size == Layout.max_bytes()
    assert {:ok, [%{"seq" => 2, "id" => 1}]} = Layout.replay(Layout.segment(ctx.dir, 2), false)
    stop_supervised!(Exporter)
    start_supervised!({Exporter, ctx.opts})
    assert_receive {:appended, 3, ^epoch}, 2000
    assert {:ok, %{records: [%{"seq" => 2}, %{"seq" => 3}]}} = Export.read(1, 10, ["#"])
  end

  defp event(id, topic \\ "ticket.42.pr.merged"), do: %{id: id, topic: topic, body: "private text"}
end
