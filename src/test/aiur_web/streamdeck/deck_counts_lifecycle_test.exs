defmodule AiurWeb.Streamdeck.DeckCountsLifecycleTest do
  use AiurWeb.StreamdeckChannelCase
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Build.Index
  alias AiurWeb.Streamdeck.Deck.Counts

  test "deck reads keep the index active after another subscriber disconnects" do
    EndpointStubs.put(streamdeck_build_window_fun: nil)
    name = __MODULE__.Index

    index =
      start_supervised!(
        {Index,
         name: name,
         idle_without_subscribers?: true,
         subscribe: fn -> :ok end,
         clock: &now/0,
         read: fn _, _, _ -> parts() end,
         daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: now()} end}
      )

    parent = self()

    other =
      start_supervised!(
        {Task,
         fn ->
           :ok = Index.subscribe(name)
           send(parent, :subscribed)

           receive do
             :stop -> :ok
           end
         end}
      )

    monitor = Process.monitor(other)
    receive_barrier(:subscribed)
    assert {:ok, %{sources: %{agents: %{state: "ok"}}}} = Index.window(name, "Etc/UTC")
    assert Counts.read(index: name).agents == 0
    send(other, :stop)
    receive_barrier({:DOWN, ^monitor, :process, ^other, :normal})
    # A synchronous call after the monitored exit drains the index's DOWN before inspection.
    assert {:ok, _} = Index.window(name, "Etc/UTC")
    state = :sys.get_state(index)
    assert state.active?
    assert Map.has_key?(state.subscribers, self())
  end
end
