defmodule Aiur.Events.DurableConsumer.ExportSourceTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Events.{DurableConsumer, Export}
  alias Aiur.Events.DurableConsumer.ExportSource
  alias Aiur.Events.Export.{Exporter, Layout}
  alias Aiur.JsonStore

  defmodule Handler do
    @behaviour Aiur.Events.DurableConsumer.Handler
    @impl true
    def handle_record(record, state) do
      send(state.owner, {:record, record})
      if state[:crash] && record["seq"] == 2 && Agent.get_and_update(state.crash, &{&1, false}), do: exit(:injected)
      {:ok, state}
    end

    @impl true
    def handle_reset(oldest, state) do
      send(state.owner, {:reset, oldest})
      {:ok, state}
    end

    @impl true
    def handle_unavailable(reason, state) do
      send(state.owner, {:unavailable, reason})
      {:ok, state}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "export-source-#{Base.encode16(:crypto.strong_rand_bytes(8))}")
    previous_root = Application.get_env(:aiur, :runtime_state_dir)
    previous_status = :persistent_term.get({Export, :status}, :missing)
    Application.put_env(:aiur, :runtime_state_dir, root)
    :persistent_term.erase({Export, :status})
    File.mkdir_p!(root)

    on_exit(fn ->
      Application.put_env(:aiur, :runtime_state_dir, previous_root)
      if previous_status == :missing, do: :persistent_term.erase({Export, :status}), else: :persistent_term.put({Export, :status}, previous_status)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    notifications = start_supervised!({Agent, fn -> true end})

    opts = [
      name: nil,
      identity: fn -> {:ok, "export-source-test"} end,
      subscribe: fn _ -> :ok end,
      on_appended: fn head, epoch ->
        if Agent.get(notifications, & &1), do: Phoenix.PubSub.broadcast(Aiur.PubSub, "events:export", {:export_appended, head, epoch})
      end
    ]

    %{root: root, path: Path.join(root, "cursor.json"), opts: opts, notifications: notifications}
  end

  test "replays from the persisted cursor then follows live appends", ctx do
    exporter = exporter(ctx)
    append(exporter, 2)
    append(exporter, 3)
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    assert_records([2, 3])
    append(exporter, 4)
    assert_records([4])
    sync(consumer)
    assert cursor(ctx) == 4
    refute_received {:reset, _}
  end

  test "restart resumes from persisted cursor without losing records", ctx do
    exporter = exporter(ctx)
    append(exporter, 2)
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    assert_records([2])
    sync(consumer)
    stop_supervised!(DurableConsumer)
    append(exporter, 3)
    append(exporter, 4)
    restarted = consumer(ctx)
    assert_records([3, 4])
    sync(restarted)
    assert cursor(ctx) == 4
    refute_received {:record, _}
  end

  test "crash after side effect redelivers exactly the uncommitted record", ctx do
    exporter = exporter(ctx)
    append(exporter, 2)
    append(exporter, 3)
    seed_cursor(ctx, 1)
    {:ok, crash} = Agent.start_link(fn -> true end)
    consumer(ctx, %{crash: crash})
    assert_records([2, 2, 3])
    refute_received {:record, _}
  end

  test "epoch change with overlapping sequences yields exactly one reset", ctx do
    exporter = exporter(ctx)
    append(exporter, 2)
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    assert_records([2])
    sync(consumer)
    old_epoch = Export.status().epoch
    stop_supervised!(Exporter)
    Agent.update(ctx.notifications, fn _ -> false end)
    exporter = exporter(%{ctx | opts: Keyword.put(ctx.opts, :identity, fn -> {:ok, "new-instance"} end)})
    append(exporter, 20)
    append(exporter, 30)
    send(consumer, :catch_up)
    receive_barrier({:reset, 1})
    assert_records([1, 2, 3])
    sync(consumer)
    assert cursor(ctx) == 3
    assert {:ok, %{"epoch" => epoch}} = JsonStore.read(ctx.path <> ".epoch")
    assert epoch == Export.status().epoch
    assert epoch != old_epoch
    send(consumer, :catch_up)
    sync(consumer)
    refute_received {:reset, _}
  end

  test "unavailable feed calls handle_unavailable once per entry and recovers", ctx do
    consumer = consumer(ctx)
    receive_barrier({:unavailable, :events_unavailable})
    send(consumer, :catch_up)
    sync(consumer)
    refute_received {:unavailable, _}
    exporter = exporter(ctx)
    assert_records([1])
    sync(consumer)
    File.rm!(:sys.get_state(exporter).path)
    append(exporter, 2)
    send(consumer, :catch_up)
    receive_barrier({:unavailable, :events_unavailable})
    send(consumer, :catch_up)
    sync(consumer)
    refute_received {:unavailable, _}
  end

  test "missed live notification is recovered on the next append in order", ctx do
    exporter = exporter(ctx)
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    sync(consumer)
    Agent.update(ctx.notifications, fn _ -> false end)
    append(exporter, 2)
    Agent.update(ctx.notifications, fn _ -> true end)
    append(exporter, 3)
    assert_records([2, 3])
    sync(consumer)
    assert cursor(ctx) == 3
  end

  test "retry recovers a missed final notification and relay stops with consumer", ctx do
    exporter = exporter(ctx)
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    relay = relay(consumer)
    Agent.update(ctx.notifications, fn _ -> false end)
    append(exporter, 2)
    send(relay, :retry)
    assert_records([2])
    sync(consumer)
    monitor = Process.monitor(relay)
    stop_supervised!(DurableConsumer)
    receive_barrier({:DOWN, ^monitor, :process, ^relay, reason})
    assert reason in [:normal, :shutdown]
    assert cursor(ctx) == 2
  end

  test "gap records reach the handler after exporter restart", ctx do
    exporter(ctx)
    consumer = consumer(ctx)
    receive_barrier({:record, %{"seq" => 1, "type" => "gap", "reason" => "exporter_start"}})
    sync(consumer)
    stop_supervised!(Exporter)
    exporter(ctx)
    receive_barrier({:record, %{"seq" => 2, "type" => "gap", "reason" => "exporter_start"}})
    sync(consumer)
    assert cursor(ctx) == 2
  end

  test "retention reset resumes at the retained floor exactly once", ctx do
    dir = Path.join(ctx.root, "events/export")
    File.mkdir_p!(dir)
    now = DateTime.utc_now()

    for {first, age} <- [{1, -10}, {3, 0}] do
      time = now |> DateTime.add(age, :day) |> DateTime.to_iso8601()
      records = for seq <- first..(first + 1), do: %{"type" => "gap", "seq" => seq, "scope" => "*", "reason" => "exporter_start", "from" => nil, "to" => time}
      File.write!(Layout.segment(dir, first), Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n")))
    end

    Layout.write_meta(dir, %{instance: "export-source-test", epoch: "retention-epoch", oldest_seq: 1, head_seq: 4})
    exporter(%{ctx | opts: Keyword.put(ctx.opts, :retention_days, 7)})
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    receive_barrier({:reset, 3})
    assert_records([3, 4, 5])
    sync(consumer)
    assert cursor(ctx) == 5
    send(consumer, :catch_up)
    sync(consumer)
    refute_received {:reset, _}
    refute_received {:record, _}
  end

  test "catch-up drains more than one bounded page", ctx do
    exporter = exporter(ctx)
    for id <- 2..6, do: append(exporter, id)
    seed_cursor(ctx, 1)
    consumer = consumer(ctx)
    assert_records(2..6)
    sync(consumer)
    assert cursor(ctx) == 6
  end

  defp exporter(ctx) do
    pid = start_supervised!({Exporter, ctx.opts})
    assert :sys.get_state(pid).state == :available
    pid
  end

  defp append(pid, id) do
    send(pid, {:event, %{id: id, topic: "ticket.42.pr.merged"}})
    :sys.get_state(pid)
  end

  defp seed_cursor(ctx, cursor) do
    JsonStore.write!(ctx.path, %{"cursor" => cursor})
    JsonStore.write!(ctx.path <> ".epoch", %{"epoch" => Export.status().epoch})
  end

  defp consumer(ctx, extra \\ %{}) do
    state = Map.merge(%{owner: self()}, extra)
    start_supervised!({DurableConsumer, name: nil, cursor_path: ctx.path, source: {ExportSource, [cursor_path: ctx.path, retry_ms: 60_000]}, handler: {Handler, state}, replay_batch: 2, retry_ms: 60_000})
  end

  defp assert_records(seqs) do
    for seq <- seqs, do: receive_barrier({:record, %{"seq" => ^seq}})
  end

  defp sync(consumer) do
    :sys.get_state(relay(consumer))
    :sys.get_state(consumer)
  end

  defp relay(consumer) do
    :sys.get_state(consumer)
    {:dictionary, dictionary} = Process.info(consumer, :dictionary)
    {{ExportSource, _}, relay} = Enum.find(dictionary, fn {key, _} -> match?({ExportSource, _}, key) end)
    relay
  end

  defp cursor(ctx) do
    {:ok, %{"cursor" => cursor}} = JsonStore.read(ctx.path)
    cursor
  end
end
