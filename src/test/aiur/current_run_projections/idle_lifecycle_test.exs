defmodule Aiur.CurrentRunProjections.IdleLifecycleTest do
  use ExUnit.Case, async: true

  import Aiur.CurrentRunProjectionsSupport

  alias Aiur.CurrentRunProjections

  test "production-style idle owner starts reading only after a dashboard subscriber arrives" do
    test_pid = self()

    {source, owner, _pubsub} =
      start_owner(
        fn sources -> Map.put(sources, :run, {:block, test_pid}) end,
        idle_without_subscribers?: true,
        subscribe_funs: [fn -> send(test_pid, :sources_subscribed) end]
      )

    assert :sys.get_state(owner).active? == false
    assert Agent.get(source, &Map.get(&1, :run_reads, 0)) == 0
    refute_receive :sources_subscribed, 50

    assert :ok = CurrentRunProjections.subscribe(owner)
    assert_receive :sources_subscribed, 1_000
    assert_receive {:projection_reader_blocked, :run, reader}, 1_000
    assert Process.alive?(reader)
    assert Agent.get(source, & &1.run_reads) == 1
  end
end
