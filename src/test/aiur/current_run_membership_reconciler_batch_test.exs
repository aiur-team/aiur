defmodule Aiur.CurrentRunMembership.ReconcilerBatchTest do
  use Aiur.TestSupport

  alias Aiur.CurrentRunMembership.{Reconciler, Store}
  alias Aiur.{TestCleanup, TestSupport, TrackerIdentity}

  test "default reconciler writer persists three changed rows with one journal open and sync" do
    dir = TestSupport.tmp_root!("membership-default-batch")
    original_store = Process.whereis(Store)
    original_reconciler = Process.whereis(Reconciler)
    if original_reconciler, do: :sys.suspend(original_reconciler)
    if original_store, do: Process.unregister(Store)

    on_exit(fn ->
      if original_store && Process.alive?(original_store), do: Process.register(original_store, Store)
      if original_reconciler && Process.alive?(original_reconciler), do: :sys.resume(original_reconciler)
      TestCleanup.rm_rf!(dir)
    end)

    # The default callback resolves Store by its production name. Only its state
    # directory is isolated; neither the observer nor the journal writer is injected.
    store = start_supervised!({Store, state_dir: dir, run_id: "default-batch", event_publish_fun: fn _, _ -> :ok end})
    parent = self()
    rows = for id <- 1..3, do: %{tracker_identity: identity(id)}

    for pattern <- [{:file, :open, 2}, {:file, :sync, 1}] do
      assert :erlang.trace_pattern(pattern, true, []) > 0
      on_exit(fn -> :erlang.trace_pattern(pattern, false, []) end)
    end

    :erlang.trace(store, true, [:call])

    start_supervised!(
      {Reconciler,
       name: nil,
       snapshot_fun: fn -> %{running: rows} end,
       terminal_states_fun: &MapSet.new/0,
       subscribe_fun: fn -> :ok end,
       membership_subscribe_fun: fn -> :ok end,
       reconciliation_fun: fn status -> send(parent, {:reconciled, status}) end,
       reconcile_interval_ms: :infinity}
    )

    assert_receive {:reconciled, :fresh}, 5_000
    assert Store.generation(store) == 3

    for %{tracker_identity: identity} <- rows do
      assert {:ok, %{lifecycle: :running}} = Store.lookup(identity, store)
    end

    ref = :erlang.trace_delivered(store)
    receive_barrier({:trace_delivered, ^store, ^ref})
    assert count_calls(store, :open) == 1
    assert count_calls(store, :sync) == 1
  end

  defp identity(id) do
    %TrackerIdentity{status: :joinable, kind: :github, owner: "Owner", repository: "Repo", provider_id: to_string(id), identifier: to_string(id), reason: nil}
  end

  defp count_calls(store, function, count \\ 0) do
    receive do
      {:trace, ^store, :call, {:file, ^function, _args}} -> count_calls(store, function, count + 1)
    after
      0 -> count
    end
  end
end
