defmodule AiurWeb.Streamdeck.TicketSubscriptionTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.{Index, IndexSource}

  test "the shared index retains the channel owner after its subscription worker exits" do
    server =
      start_supervised!(
        {Index,
         name: nil,
         idle_without_subscribers?: true,
         subscribe: fn -> :ok end,
         read: fn _dirty, _previous, _opts -> parts() end,
         clock: &now/0,
         daemon_read: fn _opts -> %{state: "live", heartbeat_at: now(), observed_at: now()} end}
      )

    owner = self()

    task =
      Task.async(fn ->
        IndexSource.subscribe(server: server, subscriber: owner, index_subscribe: fn -> :ok end, financial: :locked)
      end)

    worker = task.pid
    assert Task.await(task) == :ok
    subscribers = :sys.get_state(server).subscribers
    assert Map.has_key?(subscribers, owner)
    refute Map.has_key?(subscribers, worker)
  end
end
