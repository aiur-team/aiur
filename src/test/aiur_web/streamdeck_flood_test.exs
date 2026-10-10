defmodule AiurWeb.StreamdeckFloodTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.AgentPubSub
  alias Aiur.AgentPubSub.FleetRefresh
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.{Endpoint, StreamdeckAuth, StreamdeckSocket}
  alias Phoenix.Socket.Message

  Code.require_file("../support/streamdeck_fleet_fixture.ex", __DIR__)
  alias Aiur.StreamdeckFleetFixture, as: FleetFixture

  @endpoint Endpoint

  setup context do
    previous = Application.get_env(:aiur, Endpoint, [])
    observer = self()
    snapshot = %{agents: [%{identifier: "3875", title: "initial"}], padding: List.duplicate(42, 150_000)}
    {:ok, source} = start_supervised({Agent, fn -> %{snapshot: snapshot, blocked?: false, reads: 0} end})

    reader = fn ->
      {snapshot, blocked?} = Agent.get_and_update(source, fn state -> {{state.snapshot, state.blocked? || (context[:publication] && state.reads > 0)}, %{state | reads: state.reads + 1}} end)

      if blocked? do
        send(observer, {:snapshot_read, self()})
        receive do: (:resume_snapshot -> :ok)
      end

      if context[:publication], do: Agent.get(source, & &1.snapshot), else: snapshot
    end

    subscriber = if context[:publication], do: nil, else: FleetFixture.subscription()

    config =
      Keyword.merge(previous,
        streamdeck_fleet_subscribe_fun: subscriber,
        server: false,
        streamdeck_snapshot_fun: reader,
        streamdeck_provider_meters_fun: fn -> %{} end,
        streamdeck_decisions_fun: fn -> %{count: 0} end
      )

    Application.put_env(:aiur, Endpoint, config)
    Aiur.TestSupport.start_owned_endpoint!()
    Endpoint.config_change([{Endpoint, config}], [])

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous)
      if Process.whereis(Endpoint), do: Endpoint.config_change([{Endpoint, previous}], [])
    end)

    {:ok, token} = StreamdeckAuth.issue_token()
    {:ok, socket} = StreamdeckSocket.connect(%{"token" => token}, socket(StreamdeckSocket, "flood", %{}), %{})
    {:ok, _, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    channel = socket.channel_pid
    on_exit(fn -> if Process.alive?(channel), do: Process.exit(channel, :kill) end)
    receive_barrier(%Message{event: "snapshot"})
    %{socket: socket, source: source}
  end

  test "broadcast flood stays bounded during a slow projection and refreshes from one snapshot per flush", %{socket: socket, source: source} do
    Agent.update(source, &%{&1 | blocked?: true})
    FleetFixture.broadcast_status_change("3875", :pane_opened)
    channel = socket.channel_pid
    receive_barrier({:snapshot_read, ^channel})

    Agent.update(source, &put_in(&1, [:snapshot, :agents], [%{identifier: "3875", title: "latest"}]))

    for _ <- 1..1_000 do
      FleetFixture.broadcast_running_change([%{identifier: "3875", title: "latest", padding: List.duplicate(42, 1_000)}])
      FleetFixture.broadcast_status_change("3875", :pane_opened)
    end

    foreign_key = self()
    on_exit(fn -> SnapshotStore.discard(foreign_key) end)

    for _ <- 1..100 do
      AgentPubSub.broadcast_running_change([%{identifier: "foreign", title: "foreign"}])
      AgentPubSub.broadcast_status_change("foreign", :pane_opened)
      SnapshotStore.publish(foreign_key, %{running: [], retrying: [], idle: []})
    end

    assert FleetRefresh.latest(channel) |> hd() |> Map.fetch!(:identifier) == "3875"
    assert Process.info(channel, :message_queue_len) == {:message_queue_len, 1}
    assert Agent.get(source, & &1.reads) == 2
    send(channel, :resume_snapshot)
    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"title" => "initial"}], "grid" => _}})
    receive_barrier({:snapshot_read, ^channel})
    assert Agent.get(source, & &1.reads) == 3
    send(channel, :resume_snapshot)
    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"title" => "latest"}], "grid" => _}})
    :sys.get_state(channel)
    assert Process.info(channel, :message_queue_len) == {:message_queue_len, 0}
  end

  test "auth expiry is delivered behind at most one invalidation during projection", %{socket: socket, source: source} do
    Agent.update(source, &%{&1 | blocked?: true})
    FleetFixture.broadcast_status_change("3875", :pane_opened)
    channel = socket.channel_pid
    receive_barrier({:snapshot_read, ^channel})
    for _ <- 1..1_000, do: FleetFixture.broadcast_running_change([])
    assert Process.info(channel, :message_queue_len) == {:message_queue_len, 1}
    monitor = Process.monitor(channel)
    Process.unlink(channel)
    send(channel, :streamdeck_auth_expired)
    send(channel, :resume_snapshot)
    receive_barrier({:DOWN, ^monitor, :process, ^channel, :normal})
  end

  @tag :publication
  test "published snapshots notify the deck even without a running broadcast", %{socket: socket, source: source} do
    key = self()
    on_exit(fn -> SnapshotStore.discard(key) end)
    Agent.update(source, &%{&1 | blocked?: true, snapshot: %{agents: [%{identifier: "3875", title: "published"}]}})
    SnapshotStore.publish(key, %{running: [], retrying: [], idle: []})
    channel = socket.channel_pid
    receive_barrier({:snapshot_read, ^channel})
    assert Agent.get(source, & &1.reads) == 2
    send(channel, :resume_snapshot)
    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"title" => "published"}]}})
  end

  test "running changes remain current when tracker failure prevents snapshot publication", %{source: source} do
    summary = %{identifier: "3875", title: "paused now", status: :running, work_state: :paused, model: "gpt-5.5"}
    Agent.update(source, &%{&1 | snapshot: {:stale, &1.snapshot, %{age_ms: 1}}})
    FleetFixture.broadcast_running_change([summary])
    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"title" => "paused now", "work_state" => "paused", "model" => "gpt-5.5"}]}})
    assert Agent.get(source, &elem(&1.snapshot, 1).agents) == [%{identifier: "3875", title: "initial"}]
    assert Agent.get(source, & &1.reads) == 2
  end
end
