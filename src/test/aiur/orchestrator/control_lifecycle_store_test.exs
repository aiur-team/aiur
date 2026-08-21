defmodule Aiur.Orchestrator.ControlLifecycleStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.{ControlLifecycle, ControlLifecycleStore}
  alias Aiur.TrackerIdentity

  @now ~U[2026-07-13 12:00:00Z]

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-control-lifecycle-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :control_lifecycle_store_path)
      else
        Application.put_env(:aiur, :control_lifecycle_store_path, previous)
      end

      File.rm(path)
      File.rm(path <> ".lock")
    end)

    :ok
  end

  test "persists redacted records and expires unresolved controls during recovery" do
    lifecycle = ControlLifecycle.new(now: @now)

    {:ok, _request, lifecycle} =
      ControlLifecycle.request(lifecycle, attrs(), now: @now)

    {:ok, _accepted, lifecycle} = ControlLifecycle.accept(lifecycle, "pause-1", 7, now: @now)
    assert :ok = ControlLifecycleStore.save(lifecycle)

    recovered = ControlLifecycleStore.load()
    assert %{status: :accepted} = ControlLifecycle.get(recovered, "pause-1")

    recovered = ControlLifecycleStore.expire_unresolved_on_recovery(recovered, now: @now)

    assert %{status: :expired, expiry: %{reason: :daemon_restart}} = ControlLifecycle.get(recovered, "pause-1")
    assert :ok = ControlLifecycleStore.save(recovered)
    refute File.read!(ControlLifecycleStore.path_for()) =~ "workspace"
  end

  test "a stale control projection preserves another daemon's lifecycle event" do
    stale =
      ControlLifecycle.new(now: @now)
      |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-first", "4001"))

    current =
      ControlLifecycle.new(now: @now)
      |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-second", "5002", DateTime.add(@now, 1, :second)))

    assert :ok = ControlLifecycleStore.save(current)
    assert :ok = ControlLifecycleStore.save(stale)

    assert Enum.map(ControlLifecycleStore.load().daemon_events, & &1.run_id) == ["run-first", "run-second"]
  end

  test "a daemon update preserves the latest control projection" do
    lifecycle = ControlLifecycle.new(now: @now)
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs(), now: @now)
    assert :ok = ControlLifecycleStore.save(lifecycle)

    assert :ok =
             ControlLifecycleStore.update(&ControlLifecycle.record_daemon_event(&1, :start, daemon_attrs("run-first", "4001")))

    recovered = ControlLifecycleStore.load()
    assert %{status: :requested} = ControlLifecycle.get(recovered, "pause-1")
    assert [%{run_id: "run-first"}] = recovered.daemon_events
  end

  test "a second writer waits for the journal lock and preserves both events" do
    first = ControlLifecycle.new(now: @now) |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-first", "4001"))

    second =
      ControlLifecycle.new(now: @now)
      |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-second", "5002", DateTime.add(@now, 1, :second)))

    assert :ok = ControlLifecycleStore.save(first)

    lock = ControlLifecycleStore.path_for() <> ".lock"
    {:ok, device} = File.open(lock, [:write, :exclusive])
    task = Task.async(fn -> ControlLifecycleStore.save(second) end)

    refute Task.yield(task, 25)
    File.close(device)
    File.rm!(lock)

    assert {:ok, :ok} = Task.yield(task, 1_000)
    assert Enum.map(ControlLifecycleStore.load().daemon_events, & &1.run_id) == ["run-first", "run-second"]
  end

  test "an abandoned journal lock is reclaimed" do
    lock = ControlLifecycleStore.path_for() <> ".lock"
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, Jason.encode!(%{"hostname" => hostname(), "os_pid" => "999999999", "token" => "abandoned"}))
    File.touch!(lock, System.os_time(:second) - 31)

    lifecycle = ControlLifecycle.new(now: @now) |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-first", "4001"))

    assert :ok = ControlLifecycleStore.save(lifecycle)
    refute File.exists?(lock)
    assert [%{run_id: "run-first"}] = ControlLifecycleStore.load().daemon_events
  end

  test "an abandoned malformed journal lock is reclaimed" do
    lock = ControlLifecycleStore.path_for() <> ".lock"
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "{partial")
    File.touch!(lock, System.os_time(:second) - 31)

    lifecycle = ControlLifecycle.new(now: @now) |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-first", "4001"))

    assert :ok = ControlLifecycleStore.save(lifecycle)
    refute File.exists?(lock)
    assert [%{run_id: "run-first"}] = ControlLifecycleStore.load().daemon_events
  end

  test "a reused live pid does not preserve the previous owner's stale lock" do
    lock = ControlLifecycleStore.path_for() <> ".lock"
    File.mkdir_p!(Path.dirname(lock))

    File.write!(
      lock,
      Jason.encode!(%{
        "hostname" => hostname(),
        "os_pid" => System.pid(),
        "process_identity" => "previous-process",
        "token" => "abandoned"
      })
    )

    File.touch!(lock, System.os_time(:second) - 31)

    lifecycle = ControlLifecycle.new(now: @now) |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-first", "4001"))

    assert :ok = ControlLifecycleStore.save(lifecycle)
    refute File.exists?(lock)
    assert [%{run_id: "run-first"}] = ControlLifecycleStore.load().daemon_events
  end

  defp attrs do
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
      requester: :operator,
      metadata: %{workspace: "/private/workspace"}
    }
  end

  defp daemon_attrs(run_id, os_pid, at \\ @now) do
    %{run_id: run_id, os_pid: os_pid, ppid: "1", ppid_comm: "aiur", hostname: "host", at: at}
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end
end
