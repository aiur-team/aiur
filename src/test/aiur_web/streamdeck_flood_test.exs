defmodule AiurWeb.StreamdeckFloodTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.AgentPubSub
  alias AiurWeb.{Endpoint, StreamdeckAuth, StreamdeckSocket}
  alias Phoenix.Socket.Message

  @endpoint Endpoint

  setup do
    previous = Application.get_env(:aiur, Endpoint, [])
    observer = self()
    snapshot = %{agents: [%{identifier: "3875", title: "initial"}], padding: List.duplicate(42, 150_000)}
    {:ok, source} = start_supervised({Agent, fn -> %{snapshot: snapshot, blocked?: false, reads: 0} end})

    reader = fn ->
      {snapshot, blocked?} = Agent.get_and_update(source, fn state -> {{state.snapshot, state.blocked?}, %{state | reads: state.reads + 1}} end)

      if blocked? do
        send(observer, {:snapshot_read, self()})
        receive do: (:resume_snapshot -> :ok)
      end

      snapshot
    end

    config = Keyword.merge(previous, server: false, streamdeck_snapshot_fun: reader, streamdeck_provider_meters_fun: fn -> %{} end, streamdeck_decisions_fun: fn -> %{count: 0} end)
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
    receive_barrier(%Message{event: "snapshot"})
    %{socket: socket, source: source}
  end

  test "broadcast flood stays bounded during a slow projection and refreshes from one snapshot per flush", %{socket: socket, source: source} do
    Agent.update(source, &%{&1 | blocked?: true})
    AgentPubSub.broadcast_status_change("3875", :pane_opened)
    channel = socket.channel_pid
    receive_barrier({:snapshot_read, ^channel})

    Agent.update(source, &put_in(&1, [:snapshot, :agents], [%{identifier: "3875", title: "latest"}]))

    for _ <- 1..1_000 do
      AgentPubSub.broadcast_running_change([%{identifier: "3875", title: "latest", padding: List.duplicate(42, 1_000)}])
      AgentPubSub.broadcast_status_change("3875", :pane_opened)
    end

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
    AgentPubSub.broadcast_status_change("3875", :pane_opened)
    channel = socket.channel_pid
    receive_barrier({:snapshot_read, ^channel})
    for _ <- 1..1_000, do: AgentPubSub.broadcast_running_change([])
    monitor = Process.monitor(channel)
    Process.unlink(channel)
    send(channel, :streamdeck_auth_expired)
    send(channel, :resume_snapshot)
    receive_barrier({:DOWN, ^monitor, :process, ^channel, :normal})
  end

  test "published snapshots notify the deck even without a running broadcast", %{source: source} do
    key = self()
    on_exit(fn -> Aiur.Orchestrator.SnapshotStore.discard(key) end)
    Agent.update(source, &put_in(&1, [:snapshot, :agents], [%{identifier: "3875", title: "published"}]))
    Aiur.Orchestrator.SnapshotStore.publish(key, %{running: [], retrying: [], idle: []})
    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"title" => "published"}]}})
    assert Agent.get(source, & &1.reads) == 2
  end

  test "running changes remain current when tracker failure prevents snapshot publication", %{source: source} do
    summary = %{identifier: "3875", title: "paused now", status: :running, work_state: :paused, model: "gpt-5.5"}
    AgentPubSub.broadcast_running_change([summary])
    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"title" => "paused now", "work_state" => "paused", "model" => "gpt-5.5"}]}})
    assert Agent.get(source, & &1.snapshot.agents) == [%{identifier: "3875", title: "initial"}]
    assert Agent.get(source, & &1.reads) == 2
  end
end
