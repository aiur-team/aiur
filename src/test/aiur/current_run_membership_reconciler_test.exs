defmodule Aiur.CurrentRunMembership.ReconcilerTest do
  use ExUnit.Case, async: false

  alias Aiur.CurrentRunMembership.{Reconciler, Store}
  alias Aiur.TrackerIdentity

  test "reconciles qualified StatusReport rows without removing absent historical members" do
    parent = self()

    snapshot = %{
      running: [
        row("I-running", state: "in-progress"),
        row("I-paused", state: "in-progress", work_state: :paused),
        row("I-waiting", state: "in-progress", waiting_reason: :waiting_for_ci),
        row("I-awaiting-dispatch", state: "in-progress", waiting_reason: :awaiting_dispatch),
        row("I-unresponsive", state: "in-progress", waiting_reason: :unresponsive),
        row("I-replaced", state: "replaced")
      ],
      retrying: [row("I-retrying", state: "in-progress")],
      idle: [
        row("I-queued", state: "todo"),
        row("I-completed", state: "done"),
        row("I-cancelled", state: "cancelled"),
        %{tracker_identity: TrackerIdentity.unjoinable(:legacy), state: "todo"}
      ]
    }

    observations =
      Reconciler.reconcile_snapshot(
        snapshot,
        fn identity, lifecycle -> send(parent, {identity.provider_id, lifecycle}) end,
        MapSet.new(["done", "cancelled"])
      )

    assert length(observations) == 10

    assert_received {"I-running", :running}
    assert_received {"I-paused", :paused}
    assert_received {"I-waiting", :waiting}
    assert_received {"I-awaiting-dispatch", :waiting}
    assert_received {"I-unresponsive", :waiting}
    assert_received {"I-replaced", :replaced}
    assert_received {"I-retrying", :retrying}
    assert_received {"I-queued", :queued}
    assert_received {"I-completed", :completed}
    assert_received {"I-cancelled", :cancelled}
    refute_received {nil, _}
  end

  test "accepts explicit lifecycle facts from a compatibility StatusReport adapter" do
    parent = self()
    snapshot = %{running: [row("I-allocated", lifecycle: :allocated)], retrying: [], idle: []}

    assert [_] =
             Reconciler.reconcile_snapshot(
               snapshot,
               fn identity, lifecycle -> send(parent, {identity.provider_id, lifecycle}) end,
               MapSet.new()
             )

    assert_received {"I-allocated", :allocated}
  end

  test "a reconciliation snapshot never removes an absent terminal store member" do
    dir = Path.join(System.tmp_dir!(), "aiur-membership-reconciler-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, store} = Store.start_link(name: nil, state_dir: dir, run_id: "reconciler-membership-run")
    terminal = row("I-terminal", []).tracker_identity

    assert {:ok, %{generation: 1}} =
             Store.observe(terminal, :completed,
               server: store,
               observed_at: ~U[2026-07-14 12:00:00Z]
             )

    snapshot = %{running: [row("I-current", [])], retrying: [], idle: []}

    assert [_] =
             Reconciler.reconcile_snapshot(
               snapshot,
               fn identity, lifecycle ->
                 Store.observe(identity, lifecycle,
                   server: store,
                   observed_at: ~U[2026-07-14 12:00:01Z]
                 )
               end,
               MapSet.new(["done"])
             )

    assert {:ok, %{lifecycle: :completed, terminal?: true}} = Store.lookup(terminal, store)
    assert %{members: members} = Store.snapshot(server: store)
    assert Enum.map(members, & &1.identity.provider_id) == ["I-current", "I-terminal"]
  end

  test "a membership store restart schedules a fresh reconciliation" do
    parent = self()
    dir = Path.join(System.tmp_dir!(), "aiur-membership-store-restart-#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    reconciler_name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")
    snapshot = %{running: [], retrying: [], idle: [row("I-recovered", [])]}

    on_exit(fn ->
      if pid = Process.whereis(store_name), do: GenServer.stop(pid)
      if pid = Process.whereis(reconciler_name), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    {:ok, first_store} = Store.start_link(name: store_name, state_dir: dir, run_id: "reconciler-restart-run")

    {:ok, _reconciler} =
      Reconciler.start_link(
        name: reconciler_name,
        snapshot_fun: fn -> snapshot end,
        observe_fun: fn identity, lifecycle -> send(parent, {:reconciled, identity.provider_id, lifecycle}) end,
        terminal_states_fun: &MapSet.new/0,
        subscribe_fun: fn -> :ok end,
        reconciliation_fun: fn _status -> :ok end
      )

    assert_receive {:reconciled, "I-recovered", :queued}
    GenServer.stop(first_store)

    {:ok, _recovered_store} =
      Store.start_link(name: store_name, state_dir: dir, run_id: "reconciler-restart-run")

    assert_receive {:reconciled, "I-recovered", :queued}
  end

  test "an unavailable source marks reconciliation freshness unavailable" do
    parent = self()
    reconciler_name = Module.concat(__MODULE__, "Unavailable#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if pid = Process.whereis(reconciler_name), do: GenServer.stop(pid)
    end)

    {:ok, _reconciler} =
      Reconciler.start_link(
        name: reconciler_name,
        snapshot_fun: fn -> :unavailable end,
        terminal_states_fun: &MapSet.new/0,
        subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        reconciliation_fun: fn status -> send(parent, {:reconciliation, status}) end
      )

    assert_receive {:reconciliation, :unavailable}
  end

  test "a rejected current snapshot observation marks reconciliation freshness unavailable" do
    parent = self()
    reconciler_name = Module.concat(__MODULE__, "Rejected#{System.unique_integer([:positive])}")
    snapshot = %{running: [row("I-rejected", [])], retrying: [], idle: []}

    on_exit(fn ->
      if pid = Process.whereis(reconciler_name), do: GenServer.stop(pid)
    end)

    {:ok, _reconciler} =
      Reconciler.start_link(
        name: reconciler_name,
        snapshot_fun: fn -> snapshot end,
        observe_fun: fn _identity, _lifecycle -> {:error, :membership_unavailable} end,
        terminal_states_fun: &MapSet.new/0,
        subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        reconciliation_fun: fn status -> send(parent, {:reconciliation, status}) end
      )

    assert_receive {:reconciliation, :unavailable}
  end

  defp row(provider_id, overrides) do
    Map.merge(
      %{
        tracker_identity: %TrackerIdentity{
          version: 1,
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: provider_id,
          identifier: "42",
          reason: nil
        },
        state: "in-progress",
        work_state: :working,
        waiting_reason: :active,
        tracker_paused: false
      },
      Map.new(overrides)
    )
  end
end
