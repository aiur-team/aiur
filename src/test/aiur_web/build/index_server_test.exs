defmodule AiurWeb.Build.IndexServerTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index
  alias AiurWeb.Build.IndexReader

  defmodule BlockingOpenSource do
    def snapshot_for_index(server, timeout), do: GenServer.call(server, :snapshot, timeout)
  end

  defmodule BlockingOpenServer do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call(:snapshot, _from, parent) do
      send(parent, :open_read_blocked)
      receive(do: (:release -> {:reply, %Aiur.OpenTicketSource.Snapshot{}, parent}))
    end
  end

  defmodule DisabledQueue do
    def show, do: %{status: :disabled}
  end

  setup do
    topic = "build-home:test:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
    parent = self()

    opts = [
      name: nil,
      broadcast: fn changes -> Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:build_changes, changes}) end,
      subscribe: fn -> :ok end,
      read: fn dirty, _previous, _opts ->
        if dirty == :all or MapSet.member?(dirty, :history), do: Process.put(:aiur_build_index_read_part, :history)
        send(parent, {:read_started, self(), dirty})

        receive do
          {:return, parts} -> parts
          :crash -> exit(:killed_read)
        end
      end,
      timer: fn pid, message, ms ->
        send(parent, {:timer, pid, message, ms})
        make_ref()
      end,
      daemon_timer: fn _pid, _, _ -> make_ref() end,
      daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
      clock: &now/0
    ]

    pid = start_supervised!({Index, opts})
    receive_barrier({:read_started, worker, :all})
    :erlang.trace(pid, true, [:receive])
    send(worker, {:return, parts()})
    result_barrier(pid)
    drain_changes()
    %{pid: pid, topic: topic}
  end

  test "40 signals schedule one read and broadcast one diff to all subscribers", %{pid: pid, topic: topic} do
    subscribers = for _ <- 1..4, do: subscriber(topic)
    # Trace production calls rather than VM-global memory, which unrelated processes can change.
    :erlang.trace(pid, true, [:call, :set_on_spawn])
    :erlang.trace_pattern({:persistent_term, :put, 2}, true, [])
    on_exit(fn -> :erlang.trace_pattern({:persistent_term, :put, 2}, false, []) end)
    for _ <- 1..40, do: send(pid, {:running_changed, %{}})
    :sys.get_state(pid)
    assert_received {:timer, ^pid, :flush, 250}
    refute_received {:timer, ^pid, :flush, _}
    refute_received {:read_started, _, _}
    send(pid, :flush)
    receive_barrier({:read_started, worker, dirty})
    assert MapSet.member?(dirty, :now)
    send(worker, {:return, put_in(parts(), [:now, :rows], %{"12" => now_row(12)})})
    result_barrier(pid)
    assert_received {:build_changes, change}
    assert Enum.map(change.upsert, & &1.id) == ["12"]
    assert change.resync == false
    refute Map.has_key?(change, :sections)
    refute Map.has_key?(change.set, :usage)
    refute_received {:build_changes, _}

    for subscriber <- subscribers do
      assert {:message_queue_len, count} = Process.info(subscriber, :message_queue_len)
      assert count == 1
      send(subscriber, :stop)
    end

    refute_received {:trace, _, :call, {:persistent_term, :put, _}}
  end

  test "a mount cuts its window in the caller, not in the shared server", %{pid: pid} do
    mfa = {Aiur.BuildOrder.Index.Pages, :window, 3}
    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern(mfa, true, [:local])
    on_exit(fn -> :erlang.trace_pattern(mfa, false, [:local]) end)
    assert {:ok, _} = Index.window(pid, "Etc/UTC")
    ref = :erlang.trace_delivered(pid)
    receive_barrier({:trace_delivered, ^pid, ^ref})
    refute_received {:trace, ^pid, :call, {Aiur.BuildOrder.Index.Pages, :window, _}}
  end

  test "no-op reread emits nothing; a slow read leaves cached windows available", %{pid: pid} do
    send(pid, {:running_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:read_started, worker, _dirty})
    {micros, {:ok, snapshot}} = :timer.tc(fn -> Index.window(pid, "Etc/UTC") end)
    assert micros < 100_000
    assert snapshot.sections.now == []
    send(worker, {:return, parts()})
    result_barrier(pid)
    refute_received {:build_changes, _}
  end

  test "signals during a read survive as one following window; moves do not remove the same id", %{pid: pid} do
    send(pid, {:build_progress_changed, %{}})
    :sys.get_state(pid)
    assert_received {:timer, ^pid, :flush, 250}
    send(pid, :flush)
    receive_barrier({:read_started, worker, _})
    send(pid, {:running_changed, %{}})
    :sys.get_state(pid)
    first = put_in(parts(), [:planned, :rows], [plan_row(12), plan_row(41)])
    send(worker, {:return, first})
    result_barrier(pid)
    assert_received {:build_changes, _}
    assert_received {:timer, ^pid, :flush, 250}
    send(pid, :flush)
    receive_barrier({:read_started, worker, _})
    second = parts() |> put_in([:now, :rows], %{"12" => now_row(12)}) |> put_in([:planned, :rows], [plan_row(640)])
    send(worker, {:return, second})
    result_barrier(pid)
    assert_received {:build_changes, change}
    assert Enum.map(change.upsert, & &1.id) == ~w(12 640)
    assert change.remove == ["41"]
    refute_received {:build_changes, _}
  end

  test "an unlocated read task failure marks dirty sources unknown and keeps cached windows available", %{pid: pid} do
    send(pid, {:running_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:read_started, worker, _})
    send(worker, :crash)
    receive_barrier({:trace, ^pid, :receive, {:DOWN, _ref, :process, ^worker, :killed_read}})
    :sys.get_state(pid)
    assert Process.alive?(pid)
    assert_received {:build_changes, %{set: %{sources: sources}}}
    assert sources.agents == %{state: "stale", observed_at: now(), reason: "unknown"}
    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert Enum.map(snapshot.sections.hist, & &1.id) == []
  end

  test "repeated unlocated read failures back off until a read succeeds", %{pid: pid} do
    send(pid, {:running_changed, %{}})
    assert_receive {:timer, ^pid, :flush, 250}, 1_000

    for delay <- [500, 1_000] do
      send(pid, :flush)
      receive_barrier({:read_started, worker, _})
      send(worker, :crash)
      assert_receive {:timer, ^pid, :flush, ^delay}, 1_000
    end

    send(pid, :flush)
    receive_barrier({:read_started, worker, _})
    send(worker, {:return, parts()})
    result_barrier(pid)
    send(pid, {:running_changed, %{}})
    assert_receive {:timer, ^pid, :flush, 250}, 1_000
  end

  test "a timed-out history refresh logs its cause and keeps the last good history as stale", %{pid: pid} do
    flush_with(pid, parts([row(7)]))
    send(pid, {:build_order_history_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:read_started, worker, _})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, {:read_timeout, :sys.get_state(pid).task.ref})
        receive_barrier({:trace, ^pid, :receive, {:DOWN, _ref, :process, ^worker, :killed}})
        :sys.get_state(pid)
      end)

    assert log =~ "build_index read_timeout after_ms=3500"
    assert log =~ "part=history"
    assert log =~ ~r/read_task_failed=:killed failure=timeout parts=.*history/
    assert {:ok, %{rows: %{7 => _}, health: %{state: :stale, failure: :timeout}}} = :sys.get_state(pid).parts.history
  end

  test "an open part timeout preserves rows from the other parts and names the degraded source" do
    open_server = start_supervised!({BlockingOpenServer, self()})
    seed = parts([row(7)]) |> put_in([:now, :rows], %{"8" => now_row(8)})
    {:ok, settings} = seed.settings

    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn
           :all, _previous, _opts ->
             seed

           dirty, previous, _opts ->
             IndexReader.read(dirty, previous,
               open_source: BlockingOpenSource,
               open_server: open_server,
               open_timeout: 5_000,
               queue: DisabledQueue,
               settings_fun: fn -> settings end,
               repository_fun: fn -> {:ok, {"acme", "widgets"}} end
             )
         end,
         timer: fn _, _, _ -> make_ref() end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         clock: &now/0},
        id: :open_timeout_index
      )

    assert {:ok, _} = Index.window(pid, "Etc/UTC")
    send(pid, {:open_tickets_updated, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    assert_receive :open_read_blocked, 1_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.sleep(3_700)
        :sys.get_state(pid)
      end)

    assert log =~ "part=open"
    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert Enum.map(snapshot.sections.hist, & &1.id) == ["7"]
    assert Enum.map(snapshot.sections.now, & &1.id) == ["8"]
    assert snapshot.sources.open_tickets.reason == "open_tickets_timeout"
    send(open_server, :release)
  end

  test "a failed part marks cached dirty peers stale and retries the undelivered reads" do
    parent = self()
    seed = parts([row(7)]) |> put_in([:now, :rows], %{"8" => now_row(8)})

    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn
           :all, _previous, _opts ->
             seed

           dirty, _previous, _opts ->
             send(parent, {:stale_part_read_started, self(), dirty})
             if MapSet.member?(dirty, :planned), do: Process.put(:aiur_build_index_read_part, :planned)
             receive(do: ({:return, result} -> result))
         end,
         timer: fn _, _, _ -> make_ref() end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         read_timeout: 5_000,
         clock: &now/0},
        id: :stale_undelivered_parts_index
      )

    assert {:ok, _initial} = Index.window(pid, "Etc/UTC")
    old_agents = :sys.get_state(pid).index |> elem(1) |> then(& &1.sources.agents)
    send(pid, {:ticket_activity_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:stale_part_read_started, _worker, dirty})
    assert MapSet.member?(dirty, :now)
    ref = :sys.get_state(pid).task.ref
    send(pid, {:read_timeout, ref})
    assert await_read_finish(pid, 100)

    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert Enum.map(snapshot.sections.hist, & &1.id) == ["7"]
    assert Enum.map(snapshot.sections.now, & &1.id) == ["8"]
    assert snapshot.sources.agents.state == "stale"
    assert snapshot.sources.agents.reason == "timeout"
    assert snapshot.sources.agents.observed_at == old_agents.observed_at
    assert snapshot.sources.queue == %{state: "unavailable", reason: "timeout", observed_at: nil}
    assert snapshot.sources.queue.reason == "timeout"
    refute MapSet.member?(:sys.get_state(pid).dirty, :planned)
    assert MapSet.member?(:sys.get_state(pid).dirty, :now)

    send(pid, :flush)
    receive_barrier({:stale_part_read_started, retry_worker, retry_dirty})
    assert MapSet.member?(retry_dirty, :now)
    refute MapSet.member?(retry_dirty, :planned)
    send(retry_worker, {:return, :sys.get_state(pid).parts})
    assert await_read_finish(pid, 100)
    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert snapshot.sources.agents.state == "ok"
  end

  test "a failed history part read keeps the last good rows on the page, stale at the last read", %{pid: pid} do
    flush_with(pid, parts([row(7)]))
    flush_with(pid, %{parts() | history: {:error, :read_failed}, health: {:error, :read_failed}})
    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert Enum.map(snapshot.sections.hist, & &1.id) == ["7"]
    assert %{state: "stale", reason: "read_failed", observed_at: observed_at} = snapshot.sources.history
    assert observed_at == now()
  end

  test "first backfill page signals resync instead of flooding an unbounded empty window", %{pid: pid} do
    pending = %{health() | complete?: false, failure: :backfill_pending}
    p = %{parts() | health: pending, history: {:ok, %{rows: %{}, health: pending}}}
    flush_with(pid, p)
    drain_changes()
    rows = for n <- 1..100, into: %{}, do: {n, row(n, %{end: DateTime.add(~U[2026-10-07 12:00:00Z], -n * 86_400)})}
    flush_with(pid, %{p | history: {:ok, %{rows: rows, health: pending}}})
    assert_received {:build_changes, %{resync: true} = change}
    refute Map.has_key?(change, :upsert)
    refute Map.has_key?(change, :sections)
    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    assert length(snapshot.sections.hist) == 2
    assert snapshot.history.total == 100
  end

  test "default subscriptions dirty the actual source for every producer signal" do
    parent = self()

    pid =
      start_supervised!(
        {Index,
         name: nil,
         read: fn _, _, _ -> parts() end,
         timer: fn _, _, _ -> make_ref() end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end},
        id: :subscribed_index
      )

    assert {:ok, _} = Index.window(pid, "Etc/UTC")
    :erlang.trace(pid, true, [:receive])

    signals = [
      {"build-order-history:changed", :build_order_history_changed, :history},
      {"build-order-features:changed", :build_order_features_changed, :features},
      {"build-order-epic-overrides:changed", :epic_overrides_changed, :overrides},
      {"build_progress", :build_progress_changed, :planned},
      {"build_queue:changed", :build_queue_changed, :queue},
      {"open_tickets:changed", :open_tickets_updated, :open},
      {"ticket-activity:changed", :ticket_activity_changed, :now},
      {Aiur.AgentEvents.running_topic(), :running_changed, :now}
    ]

    for {topic, tag, part} <- signals do
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {tag, %{test: parent}})
      receive_barrier({:trace, ^pid, :receive, {^tag, _payload}})
      assert MapSet.member?(:sys.get_state(pid).dirty, part)
    end
  end

  defp flush_with(pid, parts) do
    send(pid, {:build_order_history_changed, %{}})
    :sys.get_state(pid)
    send(pid, :flush)
    receive_barrier({:read_started, worker, _})
    send(worker, {:return, parts})
    result_barrier(pid)
  end

  defp subscriber(topic) do
    parent = self()

    pid =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
        send(parent, {:subscribed, self()})
        receive do: (:stop -> :ok)
      end)

    receive_barrier({:subscribed, ^pid})
    pid
  end

  defp result_barrier(pid) do
    receive_barrier({:trace, ^pid, :receive, {_ref, %{settings: _settings}}})
    :sys.get_state(pid)
  end

  defp await_read_finish(_pid, 0), do: false

  defp await_read_finish(pid, attempts) do
    if is_nil(:sys.get_state(pid).task) do
      true
    else
      Process.sleep(10)
      await_read_finish(pid, attempts - 1)
    end
  end

  defp drain_changes do
    receive do
      {:build_changes, _} -> drain_changes()
    after
      0 -> :ok
    end
  end
end
