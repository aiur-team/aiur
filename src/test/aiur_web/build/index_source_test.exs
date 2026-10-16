defmodule AiurWeb.Build.IndexSourceTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    :ok
  end

  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index, as: Core
  alias AiurWeb.Build.{Index, IndexSource, Payload, Usage}

  defmodule FreshnessSpy do
    def read_daemon(opts) do
      send(opts[:test_pid], :daemon_read)
      %{state: "live", heartbeat_at: 1, observed_at: 2}
    end
  end

  defmodule UsageSpy do
    def read(:locked, _opts), do: Usage.read(:locked)

    def read({:ok, _context}, opts) do
      send(opts[:test_pid], :usage_loaded)
      %{state: "unavailable", observed_at: nil, reason: "test_meter"}
    end

    def subscribe(:locked), do: :ok
    def subscribe({:ok, _}), do: send(self(), :usage_subscribed) && :ok
  end

  test "snapshot uses the real index, carries generation and validates without protected usage" do
    Core.subscribe()
    parent = self()

    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> parts([row(7, %{title: "<img src=x onerror=alert(1)>"})]) end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         daemon_timer: fn pid, :daemon_tick, _ -> send(parent, {:daemon_held, pid}) && make_ref() end,
         clock: &now/0}
      )

    receive_barrier({:daemon_held, ^pid})
    :sys.get_state(pid)
    opts = [server: pid, financial: :locked, usage: UsageSpy, freshness: FreshnessSpy, test_pid: self()]
    assert :ok = IndexSource.subscribe(opts)
    assert {:ok, snapshot} = IndexSource.snapshot(opts)
    assert snapshot.index_generation > 0
    assert snapshot.usage["state"] == "locked"
    refute Map.has_key?(snapshot.usage, "providers")
    refute_received :usage_loaded
    refute_received :usage_subscribed
    refute_received :daemon_read
    assert snapshot.daemon == %{state: "live", heartbeat_at: 1, observed_at: 2}
    assert hd(snapshot.sections.hist).title == "<img src=x onerror=alert(1)>"
    assert Payload.validate(Payload.snapshot(snapshot, "epoch", 0)) == :ok
    assert {:ok, page} = IndexSource.earlier(now() + 1, "Etc/UTC", opts)
    assert Enum.map(page.rows, & &1.num) == [7]
    assert Payload.validate(Payload.earlier(page, "epoch", 0)) == :ok
    assert {:error, :invalid_params} = IndexSource.earlier(now(), "Etc/UTC", Keyword.put(opts, :days, 32))
    assert {:ok, ticket} = IndexSource.ticket("7", opts)
    assert ticket.num == 7
    assert {:error, :not_found} = IndexSource.ticket("8", opts)
    drain_private()
  end

  test "snapshot reads the daemon itself only while the index holds no block" do
    pid =
      start_supervised!(
        {Index, name: nil, subscribe: fn -> :ok end, read: fn _, _, _ -> parts() end, daemon_read: fn _ -> receive(do: (:never -> :ok)) end, daemon_timer: fn _, _, _ -> make_ref() end}
      )

    opts = [server: pid, usage: UsageSpy, freshness: FreshnessSpy, test_pid: self()]
    assert {:ok, snapshot} = IndexSource.snapshot(opts)
    assert_received :daemon_read
    assert snapshot.daemon == %{state: "live", heartbeat_at: 1, observed_at: 2}
    drain_private()
  end

  test "authorized usage is loaded and subscribed in the caller only" do
    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> parts() end,
         daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: nil} end,
         daemon_timer: fn _, _, _ -> make_ref() end}
      )

    opts = [server: pid, financial: {:ok, :context}, usage: UsageSpy, freshness: FreshnessSpy, test_pid: self()]
    assert :ok = IndexSource.subscribe(opts)
    assert {:ok, snapshot} = IndexSource.snapshot(opts)
    assert snapshot.usage.reason == "test_meter"
    assert_received :usage_loaded
    assert_received :usage_subscribed
    state = :sys.get_state(pid)
    assert {:ok, index} = state.index
    refute Map.has_key?(index, :usage)
    refute Map.has_key?(state.parts, :usage)
    drain_private()
  end

  test "missing and slow index reads become bounded source errors" do
    assert IndexSource.snapshot(server: __MODULE__.Missing) == {:error, :index_not_running}
    parent = self()

    pid =
      spawn_link(fn ->
        receive do
          {:"$gen_call", _from, _message} ->
            send(parent, :call_seen)
            receive(do: (:stop -> :ok))
        end
      end)

    assert IndexSource.snapshot(server: pid, timeout: 1) == {:error, :timeout}
    receive_barrier(:call_seen)
    send(pid, :stop)
  end

  test "a dead table reads as a stopped index but a fault in the cut propagates" do
    dead = :ets.new(:dead, [])
    :ets.delete(dead)
    assert IndexSource.snapshot(server: table_server(dead)) == {:error, :index_not_running}

    # An out-of-range end makes the caller-side cut raise ArgumentError, which must not read as a stopped index.
    table = :ets.new(:bad_row, [:public])
    :ets.insert(table, [{:generation, 1}, {:index, {:ok, %{hist: [%{end: 1_000_000_000_000_000_000}], history_meta: %{total: nil}, sections: %{}}}}])
    assert_raise ArgumentError, fn -> IndexSource.snapshot(server: table_server(table)) end
  end

  defp table_server(table) do
    spawn_link(fn ->
      receive do
        {:"$gen_call", from, :table} -> GenServer.reply(from, {:ok, table, now()})
      end
    end)
  end

  defp drain_private do
    receive do
      {:build_changes, changes} ->
        refute Map.has_key?(changes, :usage)
        refute Map.has_key?(Map.get(changes, :set, %{}), :usage)
        drain_private()
    after
      0 -> :ok
    end
  end
end
