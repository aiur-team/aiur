defmodule Aiur.CurrentRunMembership.ReconcilerTest do
  use ExUnit.Case, async: true

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
      Reconciler.reconcile_snapshot(snapshot, fn identity, lifecycle -> send(parent, {identity.provider_id, lifecycle}) end, MapSet.new(["done", "cancelled"]))

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

    assert [_] = Reconciler.reconcile_snapshot(snapshot, fn identity, lifecycle -> send(parent, {identity.provider_id, lifecycle}) end, MapSet.new())
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
