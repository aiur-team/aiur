defmodule Aiur.Orchestrator.ControlLifecycleStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths
  alias Aiur.JsonStore
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

  test "stale writers preserve independent control transitions" do
    {:ok, _first, first} = ControlLifecycle.request(ControlLifecycle.new(now: @now), attrs(), now: @now)

    second_attrs =
      attrs()
      |> Map.put(:request_id, "pause-2")
      |> Map.put(:issue_id, "issue-2")
      |> Map.put(:tracker_identity, %{attrs().tracker_identity | provider_id: "I_kwDOissue2", identifier: "102"})

    {:ok, _second, second} =
      ControlLifecycle.request(ControlLifecycle.new(now: @now), second_attrs, now: DateTime.add(@now, 1, :second))

    assert :ok = ControlLifecycleStore.save(first)
    assert :ok = ControlLifecycleStore.save(second)

    recovered = ControlLifecycleStore.load()
    assert %{status: :requested} = ControlLifecycle.get(recovered, "pause-1")
    assert %{status: :requested} = ControlLifecycle.get(recovered, "pause-2")
  end

  test "a stale request cannot overwrite a later transition" do
    {:ok, _request, requested} = ControlLifecycle.request(ControlLifecycle.new(now: @now), attrs(), now: @now)
    {:ok, _accepted, accepted} = ControlLifecycle.accept(requested, "pause-1", 7, now: DateTime.add(@now, 1, :second))
    {:ok, _applied, applied} = ControlLifecycle.apply(accepted, "pause-1", 7, now: DateTime.add(@now, 2, :second))

    assert :ok = ControlLifecycleStore.save(applied)
    assert :ok = ControlLifecycleStore.save(requested)

    assert %{status: :applied} = ControlLifecycleStore.load() |> ControlLifecycle.get("pause-1")
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

  test "a legacy per-boot journal is imported into the durable state dir on first save" do
    state_dir = Path.join(System.tmp_dir!(), "aiur-control-lifecycle-legacy-#{System.unique_integer([:positive])}")
    legacy_root = Path.join(state_dir, "legacy-log")
    File.mkdir_p!(legacy_root)
    repo = Paths.repo_name()
    legacy_journal = Path.join(legacy_root, "#{repo}.control-lifecycle.json")

    previous_log_file = Application.get_env(:aiur, :log_file)
    previous_store_path = Application.get_env(:aiur, :control_lifecycle_store_path)
    previous_state_dir = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :log_file, Path.join(legacy_root, "aiur.log"))
    Application.delete_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :executor_state_dir, state_dir)

    on_exit(fn ->
      restore_env(:log_file, previous_log_file)
      restore_env(:control_lifecycle_store_path, previous_store_path)
      restore_env(:executor_state_dir, previous_state_dir)
      File.rm_rf!(state_dir)
    end)

    # A pre-PR daemon left its control-request audit journal under the boot log
    # root; an upgrade must import it rather than presenting a confident empty
    # journal (`daemon_lifecycle` reads emptiness as "not started normally").
    legacy_lifecycle =
      ControlLifecycle.new(now: @now)
      |> ControlLifecycle.record_daemon_event(:start, daemon_attrs("run-legacy", "4001"))

    :ok = JsonStore.write!(legacy_journal, ControlLifecycle.dump(legacy_lifecycle))

    # The first durable save goes through `StatePaths.ensure/0`, importing the
    # orphaned per-boot journal into the durable state dir.
    assert :ok = ControlLifecycleStore.save(ControlLifecycle.new(now: @now))

    assert Path.dirname(ControlLifecycleStore.path_for()) == state_dir
    assert [%{run_id: "run-legacy"}] = ControlLifecycleStore.load().daemon_events
    # The legacy file is copied, never moved — the boot log root stays readable
    # for forensics.
    assert File.exists?(legacy_journal)
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)

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
