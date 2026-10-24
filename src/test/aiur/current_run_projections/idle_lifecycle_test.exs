defmodule Aiur.CurrentRunProjections.IdleLifecycleTest do
  use ExUnit.Case, async: true

  import Aiur.CurrentRunProjectionsSupport

  alias Aiur.CurrentRunProjections
  alias Aiur.CurrentRunSummary

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

  test "idle membership refresh retains terminal complexity until dashboard subscription" do
    ticket = identity(72)

    {source, owner, _pubsub} =
      start_owner(
        fn sources ->
          sources
          |> put_in([:membership, :members], [member(ticket, :running, false)])
          |> put_in([:status, :running], [status_row(ticket)])
          |> put_in([:status_facts], [status_fact(ticket, "in-progress", 5)])
        end,
        idle_without_subscribers?: true
      )

    assert :sys.get_state(owner).active? == false
    assert Agent.get(source, &Map.get(&1, :membership_reads, 0)) == 0

    send(owner, {:current_run_membership_changed, :running})
    await_projection_idle(owner)
    assert [%{complexity: 5}] = Map.values(:sys.get_state(owner).weight_facts)

    Agent.update(source, fn sources ->
      sources
      |> put_in([:membership, :members], [member(ticket, :completed, true)])
      |> put_in([:status, :running], [])
      |> put_in([:status_facts], [])
    end)

    send(owner, {:current_run_membership_changed, :completed})
    await_projection_idle(owner)

    assert :sys.get_state(owner).active? == false
    assert [%{complexity: 5}] = Map.values(:sys.get_state(owner).weight_facts)

    assert :ok = CurrentRunProjections.subscribe(owner)
    await_projection_idle(owner)

    assert CurrentRunSummary.snapshot(server: owner).weights.successful_terminal == 5
  end
end
