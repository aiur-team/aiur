defmodule Aiur.Orchestrator.MembershipFactsCaptureTest do
  use ExUnit.Case, async: false

  alias Aiur.{CurrentRunMembership, Issue, TrackerIdentity}
  alias Aiur.CurrentRunMembership.Store
  alias Aiur.Orchestrator.MembershipLifecycle
  alias Aiur.RunTelemetry.FactsCapture

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    :ok = Aiur.TestSupport.ensure_pubsub_running()

    Enum.each([Store, FactsCapture], fn name ->
      if pid = Process.whereis(name) do
        Process.unregister(name)

        on_exit(fn ->
          if Process.alive?(pid) and is_nil(Process.whereis(name)), do: Process.register(pid, name)
        end)
      end
    end)

    root = Aiur.TestSupport.tmp_root!("membership-facts-capture")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "real terminal membership observation queues facts after durable acceptance", %{root: root} do
    parent = self()
    start_supervised!({Store, state_dir: Path.join(root, "membership"), run_id: "facts-integration"})

    capture =
      start_supervised!(
        {FactsCapture,
         path: Path.join(root, "facts.json"),
         enabled: fn -> true end,
         interval: 60_000,
         fetch: fn ticket ->
           send(parent, {:captured, ticket, CurrentRunMembership.lookup(identity())})
           {:ok, %{coverage: "available"}}
         end,
         record: fn _, _ -> :ok end}
      )

    assert :ok = MembershipLifecycle.record(%Issue{tracker_identity: identity()}, :completed)
    assert_receive {:captured, "42", {:ok, %{lifecycle: :completed}}}, 1_000
    FactsCapture.drain(capture)
  end

  test "failed membership observation does not capture and nil identity remains harmless", %{root: root} do
    parent = self()

    start_supervised!({Store, state_dir: Path.join(root, "membership"), run_id: "facts-integration", append_fun: fn _, _ -> {:error, :disk_full} end})

    capture =
      start_supervised!({FactsCapture, path: Path.join(root, "facts.json"), enabled: fn -> true end, fetch: fn ticket -> send(parent, {:unexpected, ticket}) end})

    assert {:error, :membership_observation_failed} = MembershipLifecycle.observe(identity(), :completed)
    unjoinable = TrackerIdentity.unjoinable(:missing_identifier, kind: :github)
    assert :ok = FactsCapture.terminal(unjoinable, :completed)
    assert :ok = MembershipLifecycle.record(%Issue{tracker_identity: nil}, :completed)
    FactsCapture.drain(capture)
    refute_receive {:unexpected, _}, 100
  end

  test "future regression: unavailable facts capture preserves accepted membership", %{root: root} do
    start_supervised!({Store, state_dir: Path.join(root, "membership"), run_id: "facts-integration"})
    assert :ok = MembershipLifecycle.observe(identity(), :completed)
    assert {:ok, %{lifecycle: :completed}} = CurrentRunMembership.lookup(identity())
    unjoinable = TrackerIdentity.unjoinable(:missing_identifier, kind: :github)
    assert {:error, :membership_observation_failed} = MembershipLifecycle.observe(unjoinable, :completed)
  end

  defp identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-facts-integration",
      identifier: "42",
      reason: nil
    }
  end
end
