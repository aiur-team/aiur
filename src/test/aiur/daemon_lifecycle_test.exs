defmodule Aiur.DaemonLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.{DaemonLifecycle, JsonStore, TrackerIdentity}
  alias Aiur.Orchestrator.{ControlLifecycle, ControlLifecycleStore}

  @now ~U[2026-08-17 17:40:38Z]

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-daemon-lifecycle-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :control_lifecycle_store_path)
      else
        Application.put_env(:aiur, :control_lifecycle_store_path, previous)
      end

      File.rm(path)
    end)

    :ok
  end

  describe "record_start/record_stop" do
    test "persists a start and a stop with the invoking process identity" do
      assert :ok = DaemonLifecycle.record_start(run_id: "run-a", os_pid: "111", ppid: "222", ppid_comm: "aiurdev", hostname: "host-a", at: @now)
      assert :ok = DaemonLifecycle.record_stop(run_id: "run-a", os_pid: "111", ppid: "222", ppid_comm: "aiurdev", hostname: "host-a", at: @now)

      events = DaemonLifecycle.daemon_events()
      assert [start, stop] = events

      assert start.kind == :start
      assert start.run_id == "run-a"
      assert start.os_pid == "111"
      assert start.ppid == "222"
      assert start.ppid_comm == "aiurdev"
      assert start.hostname == "host-a"
      assert start.at == @now

      assert stop.kind == :stop
      assert stop.run_id == "run-a"
    end

    test "simulated two instances both appear in the journal" do
      # Acceptance: "Simulate two instances and assert both appear." Two
      # daemons sharing a host each record their own start; a later review of
      # the journal must name both invoking processes.
      assert :ok = DaemonLifecycle.record_start(run_id: "run-first", os_pid: "4001", ppid: "4000", ppid_comm: "aiur", hostname: "host", at: @now)
      assert :ok = DaemonLifecycle.record_start(run_id: "run-second", os_pid: "5002", ppid: "5001", ppid_comm: "aiur", hostname: "host", at: @now)

      events = DaemonLifecycle.daemon_events()

      assert Enum.map(events, & &1.run_id) == ["run-first", "run-second"]
      assert Enum.any?(events, &(&1.run_id == "run-first" and &1.os_pid == "4001"))
      assert Enum.any?(events, &(&1.run_id == "run-second" and &1.os_pid == "5002"))
    end

    test "a stop for one instance preserves the other instance's record" do
      assert :ok = DaemonLifecycle.record_start(run_id: "run-first", os_pid: "4001", at: @now)
      assert :ok = DaemonLifecycle.record_start(run_id: "run-second", os_pid: "5002", at: @now)
      assert :ok = DaemonLifecycle.record_stop(run_id: "run-first", os_pid: "4001", at: @now)

      events = DaemonLifecycle.daemon_events()
      assert length(events) == 3
      assert Enum.any?(events, &(&1.run_id == "run-second" and &1.kind == :start))
      assert Enum.any?(events, &(&1.run_id == "run-first" and &1.kind == :stop))
    end

    test "a repeated stop for the same run is a no-op (idempotent shutdown paths)" do
      assert :ok = DaemonLifecycle.record_start(run_id: "run-a", at: @now)
      assert :ok = DaemonLifecycle.record_stop(run_id: "run-a", at: @now)
      # prep_stop and stop both call cleanup; the second stop must not duplicate.
      assert :ok = DaemonLifecycle.record_stop(run_id: "run-a", at: @now)

      events = DaemonLifecycle.daemon_events()
      assert length(events) == 2
      assert Enum.count(events, &(&1.kind == :stop)) == 1
    end

    test "process_identity/0 resolves the real invoking process fields" do
      identity = DaemonLifecycle.process_identity(run_id: "run-probe", os_pid: "1234")

      assert identity.run_id == "run-probe"
      assert identity.os_pid == "1234"
      assert is_binary(identity.ppid) or is_nil(identity.ppid)
    end
  end

  describe "coexistence with control requests" do
    test "dump/restore round-trips daemon events alongside control records" do
      lifecycle = ControlLifecycle.new(now: @now)
      lifecycle = ControlLifecycle.record_daemon_event(lifecycle, :start, daemon_attrs("run-a", "4001"))

      {:ok, _request, lifecycle} =
        ControlLifecycle.request(lifecycle, control_attrs(), now: @now)

      assert :ok = ControlLifecycleStore.save(lifecycle)

      recovered = ControlLifecycleStore.load()

      assert %{status: :requested} = ControlLifecycle.get(recovered, "pause-1")
      assert [start] = ControlLifecycle.daemon_events(recovered)
      assert start.kind == :start
      assert start.run_id == "run-a"
    end

    test "the persisted journal never leaks workspace paths" do
      lifecycle = ControlLifecycle.new(now: @now)
      lifecycle = ControlLifecycle.record_daemon_event(lifecycle, :start, daemon_attrs("run-a", "4001"))

      {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, control_attrs(), now: @now)

      assert :ok = ControlLifecycleStore.save(lifecycle)
      refute File.read!(ControlLifecycleStore.path_for()) =~ "workspace"
    end

    test "invalid persisted daemon events are skipped on restore" do
      lifecycle = ControlLifecycle.new(now: @now)
      lifecycle = ControlLifecycle.record_daemon_event(lifecycle, :start, daemon_attrs("run-a", "4001"))
      dumped = ControlLifecycle.dump(lifecycle)

      # A hostile/corrupt journal entry must not break restore.
      tampered = %{dumped | daemon_events: [%{kind: "explode", at: "not-a-date", run_id: ""}]}

      :ok = JsonStore.write!(ControlLifecycleStore.path_for(), tampered)

      recovered = ControlLifecycleStore.load()
      assert ControlLifecycle.daemon_events(recovered) == []
    end
  end

  defp daemon_attrs(run_id, os_pid) do
    %{run_id: run_id, os_pid: os_pid, ppid: "1", ppid_comm: "aiur", hostname: "host", at: @now}
  end

  defp control_attrs do
    %{
      request_id: "pause-1",
      issue_id: "issue-1",
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "I_kwDOissue1",
        identifier: "101",
        reason: nil
      },
      action: :pause,
      generation: 7,
      expected_status: :working,
      expected_version: 0,
      requester: :operator
    }
  end
end
