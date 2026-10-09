defmodule Aiur.Capabilities.GraphProjectionCapabilityTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.CapabilityProvider
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.{CapabilityReader, Policy}

  test "default capability read preserves projection state and timers despite changed authority" do
    parent = self()
    authority = start_supervised!({Agent, fn -> %{repository: {"test-owner", "read-only-catalog"}, generation: 1} end})
    tasks = start_supervised!({Task.Supervisor, []})

    projection =
      start_supervised!(
        {GraphProjection,
         [
           name: nil,
           task_supervisor: tasks,
           authority_snapshot: fn -> Agent.get(authority, & &1) end,
           configuration_subscriber: fn _ -> :ok end,
           reconciliation_fun: fn _ -> :ok end,
           catalog_reader: fn _ ->
             send(parent, {:catalog_reader_started, self()})

             receive do
               :finish -> {:error, :test_finished}
             end
           end,
           clock_ms: fn -> 0 end,
           after_broadcast: fn event -> send(parent, {:capability_projection_event, event}) end
         ]}
      )

    receive_barrier({:catalog_reader_started, reader})
    before = :sys.get_state(projection)
    assert CapabilityReader.catalog(projection) == Policy.snapshot(before.catalog, before.active_repository, before.authority_epoch, 0, 120_000)
    assert before.catalog.inflight != nil
    assert before.active_repository == {"test-owner", "read-only-catalog"}
    epoch = before.authority_epoch
    receive_barrier({:capability_projection_event, {:graph_projection_reset, ^epoch}})
    receive_barrier({:capability_projection_event, {:graph_projection_health, _snapshot}})
    Agent.update(authority, fn _ -> %{repository: {"test-owner", "changed-authority"}, generation: 2} end)
    context = %{settings: %{tracker: %{kind: "github"}}, run_shape: %{}}
    caps = CapabilityProvider.evaluate(context, lookup_fun: fn GraphProjection -> projection end)
    assert caps["build_orders"].state == :degraded
    assert :sys.get_state(projection) == before
    refute_received {:capability_projection_event, _event}
    Agent.update(authority, fn _ -> %{repository: {"test-owner", "read-only-catalog"}, generation: 1} end)
    send(reader, :finish)
    receive_barrier({:capability_projection_event, {:graph_projection_health, snapshot}})
    assert snapshot.health.failure != nil
    assert CapabilityReader.catalog(projection) == snapshot
  end
end
