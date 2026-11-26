defmodule Aiur.Events.Outbound.ProducerWiringTest do
  use ExUnit.Case, async: false

  import Aiur.CurrentRunMembershipStoreSupport
  import Aiur.TestSupport.UsageLedger, only: [envelope: 1]

  alias Aiur.CurrentRunMembership.Store, as: MembershipStore
  alias Aiur.UsageLedger.Store, as: UsageStore

  setup do
    membership_root = Aiur.TestSupport.tmp_root!("aiur-outbound-membership")
    usage_root = Aiur.TestSupport.tmp_root!("aiur-outbound-usage")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(membership_root)
      Aiur.TestCleanup.rm_rf!(usage_root)
    end)

    %{membership_root: membership_root, usage_root: usage_root}
  end

  test "membership publishes only after durable acceptance", %{membership_root: root} do
    parent = self()

    accepted =
      start_store!(root, "run-5695-1", event_publish_fun: fn event, generation -> send(parent, {:membership_published, event, generation}) end)

    assert {:ok, %{status: :accepted, generation: 1}} =
             MembershipStore.observe(identity(), :running,
               server: accepted,
               observed_at: ~U[2026-10-25 00:00:00Z],
               source: :tracker
             )

    assert_receive {:membership_published, %{lifecycle: :running}, 1}, 1_000

    assert {:ok, %{status: :out_of_order, generation: 1}} =
             MembershipStore.observe(identity(), :queued,
               server: accepted,
               observed_at: ~U[2026-10-24 23:59:59Z],
               source: :tracker
             )

    refute_receive {:membership_published, _, _}, 100

    failed =
      start_store!(root <> "-failed", "run-5695-2",
        append_fun: fn _path, _record -> {:error, :enospc} end,
        event_publish_fun: fn event, generation -> send(parent, {:membership_published, event, generation}) end
      )

    assert {:error, {:membership_persistence_failed, _reason}} =
             MembershipStore.observe(identity(), :running,
               server: failed,
               observed_at: ~U[2026-10-25 00:00:00Z]
             )

    refute_receive {:membership_published, _, _}, 100
  end

  test "usage publishes accepted canonical deltas once and never publishes persistence failures", %{usage_root: root} do
    parent = self()
    name = String.to_atom("outbound_usage_#{System.unique_integer([:positive])}")

    {:ok, accepted} =
      UsageStore.start_link(
        name: name,
        state_dir: root,
        filesystem_sync_fun: fn -> :ok end,
        event_publish_fun: fn usage_envelope, acknowledgement ->
          send(parent, {:usage_published, usage_envelope, acknowledgement})
        end
      )

    measurement = envelope(%{})
    assert {:ok, acknowledgement} = UsageStore.append(name, measurement)
    assert_receive {:usage_published, ^measurement, ^acknowledgement}, 1_000
    assert {:duplicate, _duplicate} = UsageStore.append(name, measurement)
    refute_receive {:usage_published, _, _}, 100
    GenServer.stop(accepted)

    failed_name = String.to_atom("outbound_usage_failed_#{System.unique_integer([:positive])}")

    {:ok, failed} =
      UsageStore.start_link(
        name: failed_name,
        state_dir: root <> "-failed",
        filesystem_sync_fun: fn -> :ok end,
        append_fun: fn _path, _record -> {:error, :enospc} end,
        event_publish_fun: fn usage_envelope, acknowledgement ->
          send(parent, {:usage_published, usage_envelope, acknowledgement})
        end
      )

    assert {:error, :persistence_failed} = UsageStore.append(failed_name, envelope(%{}))
    refute_receive {:usage_published, _, _}, 100
    GenServer.stop(failed)
  end
end
