defmodule AiurWeb.Build.IndexLiveTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.{Index, IndexSource}

  defmodule UsageStub do
    def read(_, _), do: %{state: "unavailable", observed_at: nil, reason: "fixture"}
    def subscribe(_), do: :ok
  end

  defmodule DaemonStub do
    def read_daemon(_), do: %{state: "live", heartbeat_at: 1, observed_at: 2}
  end

  test "real source bounds connected LiveView mailboxes, drops stale diffs and resyncs on restart" do
    parent = self()
    topic = "build-home:live-test:#{System.unique_integer([:positive])}"
    initial = parts() |> put_in([:planned, :rows], [plan_row(12)])
    agent = start_supervised!({Agent, fn -> initial end})
    name = __MODULE__.Index

    start_supervised!(
      {Index,
       name: name,
       broadcast: fn changes -> Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:build_changes, changes}) end,
       subscribe: fn -> :ok end,
       read: fn dirty, _, _ ->
         send(parent, {:index_read, dirty})
         Agent.get(agent, & &1)
       end,
       timer: fn pid, message, ms ->
         send(parent, {:index_timer, pid, message, ms})
         make_ref()
       end,
       daemon_timer: fn _, _, _ ->
         send(parent, :daemon_ready)
         make_ref()
       end,
       daemon_read: &DaemonStub.read_daemon/1,
       clock: &now/0}
    )

    assert {:ok, _} = Index.window(name, "Etc/UTC")
    receive_barrier(:daemon_ready)
    Application.put_env(:aiur, :build_data_source, {IndexSource, [server: name, usage: UsageStub, freshness: DaemonStub, index_subscribe: fn -> Phoenix.PubSub.subscribe(Aiur.PubSub, topic) end]})

    views =
      for _ <- 1..4 do
        {:ok, view, _} = live(build_conn(), "/build")
        render_async(view)
        render_hook(view, "build-resync", %{})
        assert_reply(view, snapshot)
        assert Payload.validate(snapshot) == :ok
        view
      end

    cut = :sys.get_state(name).generation
    assert cut >= 2

    for view <- views do
      generation = :sys.get_state(view.pid).socket.assigns.build_generation
      send(view.pid, {:build_changes, %{index_generation: cut - 1, now: now(), upsert: [], remove: [], set: %{}}})
      render(view)
      assert :sys.get_state(view.pid).socket.assigns.build_generation == generation
    end

    assert_received {:index_read, :all}
    pid = Process.whereis(name)
    :erlang.trace(pid, true, [:receive])
    Agent.update(agent, fn p -> p |> put_in([:planned, :rows], []) |> put_in([:now, :rows], %{"12" => now_row(12)}) end)
    for _ <- 1..40, do: send(pid, {:running_changed, %{}})
    :sys.get_state(pid)
    assert_received {:index_timer, ^pid, :flush, 250}
    refute_received {:index_timer, ^pid, :flush, _}
    refute_received {:index_read, _}
    send(pid, :flush)
    receive_barrier({:trace, ^pid, :receive, {_ref, %{settings: _settings}}})
    state = :sys.get_state(pid)
    assert_received {:index_read, _}
    refute_received {:index_read, _}

    for view <- views do
      render(view)
      assert_push_event(view, "build-diff", diff)
      assert Enum.map(diff["upsert"], & &1["id"]) == ["12"]
      assert diff["remove"] == []
      assert Payload.validate(diff) == :ok
      assert {:message_queue_len, length} = Process.info(view.pid, :message_queue_len)
      assert length <= 2
      generation = :sys.get_state(view.pid).socket.assigns.build_generation
      send(view.pid, {:build_changes, %{index_generation: state.generation - 1, now: now(), upsert: [], remove: [], set: %{}}})
      render(view)
      assert :sys.get_state(view.pid).socket.assigns.build_generation == generation
    end

    previous = Enum.map(views, &:sys.get_state(&1.pid).socket.assigns.build_generation)
    Process.exit(pid, :kill)
    receive_barrier({:index_read, :all})
    assert {:ok, _} = Index.window(name, "Etc/UTC")

    for {view, generation} <- Enum.zip(views, previous) do
      render(view)
      assert_push_event(view, "build-diff", gap)
      assert gap["generation"] == generation + 2
      assert gap["upsert"] == [] and gap["remove"] == [] and gap["set"] == %{}
      # A gap carries no snapshot. The client requests it using the existing build-resync event.
      Phoenix.Config.put(AiurWeb.Endpoint, :build_resync_clock, fn _ -> System.monotonic_time(:millisecond) + 3_000 end)
      render_hook(view, "build-resync", %{})
      assert_reply(view, snapshot)
      assert snapshot["kind"] == "snapshot"
      assert hd(snapshot["sections"]["now"])["id"] == "12"
    end
  end
end
