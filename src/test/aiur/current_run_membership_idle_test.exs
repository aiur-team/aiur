defmodule Aiur.CurrentRunMembership.IdleTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.CurrentRunMembership.{Reconciler, Store}
  alias Aiur.TrackerIdentity

  test "periodic reconciliation skips stored lifecycles but repairs missed changes and missing members" do
    dir = Aiur.TestSupport.tmp_root!("membership-idle")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({Store, name: nil, state_dir: dir, run_id: "idle-run"})
    identity = %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "42", identifier: "42", reason: nil}
    parent = self()
    snapshot = start_supervised!({Agent, fn -> %{running: [%{tracker_identity: identity}], idle: [], retrying: []} end})

    reconciler =
      start_supervised!(
        {Reconciler,
         name: nil,
         snapshot_fun: fn -> Agent.get(snapshot, & &1) end,
         stored_lifecycles_fun: fn -> Store.lifecycles(store) end,
         observe_fun: fn identity, lifecycle ->
           send(parent, {:observed, identity, lifecycle})
           Store.observe(identity, lifecycle, server: store)
         end,
         terminal_states_fun: &MapSet.new/0,
         subscribe_fun: fn -> :ok end,
         membership_subscribe_fun: fn -> :ok end,
         reconciliation_fun: fn status ->
           :ok = Store.mark_reconciled(status, store)
           send(parent, {:reconciled, status})
           :ok
         end,
         reconcile_interval_ms: :infinity}
      )

    receive_barrier({:reconciled, :fresh})
    assert_received {:observed, ^identity, :running}

    for _ <- 1..3 do
      send(reconciler, :reconcile_tick)
      receive_barrier({:reconciled, :fresh})
      refute_received {:observed, _, _}
    end

    assert Store.generation(store) == 1

    assert {:ok, _} = Store.observe(identity, :paused, server: store)
    send(reconciler, :reconcile_tick)
    receive_barrier({:reconciled, :fresh})
    assert_received {:observed, ^identity, :running}
    assert {:ok, %{lifecycle: :running}} = Store.lookup(identity, store)

    other = %{identity | provider_id: "43", identifier: "43"}
    Agent.update(snapshot, &%{&1 | idle: [%{tracker_identity: other}]})
    send(reconciler, :reconcile_tick)
    receive_barrier({:reconciled, :fresh})
    assert_received {:observed, ^other, :queued}
    refute_received {:observed, ^identity, _}
  end

  test "an unwritable store cannot report fresh just because its stored lifecycles match" do
    dir = Aiur.TestSupport.tmp_root!("membership-idle-unavailable")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {Store,
         name: nil,
         state_dir: dir,
         run_id: "unavailable-run",
         append_fun: fn path, event ->
           if event["lifecycle"] == "paused", do: {:error, :disk_full}, else: Aiur.Journal.append(path, event)
         end}
      )

    identity = %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "42", identifier: "42", reason: nil}
    assert {:ok, _} = Store.observe(identity, :running, server: store)
    assert {:error, _} = Store.observe(identity, :paused, server: store)
    parent = self()

    start_supervised!(
      {Reconciler,
       name: nil,
       snapshot_fun: fn -> %{running: [%{tracker_identity: identity}]} end,
       stored_lifecycles_fun: fn -> Store.lifecycles(store) end,
       observe_fun: fn _, _ -> flunk("must not observe an unwritable store") end,
       terminal_states_fun: &MapSet.new/0,
       subscribe_fun: fn -> :ok end,
       membership_subscribe_fun: fn -> :ok end,
       reconciliation_fun: fn status -> send(parent, {:reconciled, status}) end,
       reconcile_interval_ms: :infinity}
    )

    receive_barrier({:reconciled, status})
    assert status == :unavailable
  end
end
