defmodule Aiur.SupervisionHealthTest do
  use ExUnit.Case, async: false

  alias Aiur.{AlertFeed, AlertLedger, SupervisionHealth}

  defmodule Worker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, nil}
  end

  defmodule CrashWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def crash, do: GenServer.cast(__MODULE__, :crash)

    def init(opts) do
      send(opts[:notify], {:crash_worker_started, self()})
      {:ok, nil}
    end

    def handle_cast(:crash, state), do: {:stop, :boom, state}
  end

  defmodule CrashLoopSupervisor do
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    def init([notify]), do: Supervisor.init([{CrashWorker, notify: notify}], strategy: :one_for_one, max_restarts: 1)
  end

  defmodule NestedWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, nil}
  end

  defmodule RestartingWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)

    def init(opts) do
      send(opts[:notify], {:restarting_worker_started, self()})
      {:ok, nil}
    end
  end

  defmodule NestedSupervisor do
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    def init(_opts), do: Supervisor.init([{NestedWorker, name: NestedWorker, restart: :temporary}], strategy: :one_for_one)
  end

  test "derives expected processes from specs and records a missing child termination" do
    specs = [{Worker, name: Worker, restart: :temporary}]
    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

    on_exit(fn -> stop_supervisor(supervisor) end)

    assert %{expected: 1, healthy: 1, missing: []} = SupervisionHealth.check(supervisor, specs)

    test_pid = self()

    {:ok, health} =
      SupervisionHealth.start_link(
        name: nil,
        supervisor: supervisor,
        expected_children: specs,
        check_interval: 60_000,
        alert_fun: fn snapshot, _missing -> send(test_pid, {:supervision_alert, snapshot}) end
      )

    assert {:ok, %{healthy: 1}} = SupervisionHealth.status(health)
    assert :ok = Supervisor.terminate_child(supervisor, Worker)
    send(health, :check)

    assert_receive {:supervision_alert, %{expected: 1, healthy: 0, missing: [%{id: Worker, reason: :shutdown}]}}, 2_000
    assert {:ok, snapshot} = SupervisionHealth.status(health)
    assert SupervisionHealth.format(snapshot) == "SUPERVISION 0/1 — Aiur.SupervisionHealthTest.Worker DOWN (last termination: :shutdown)"

    assert {:ok, _worker} = Supervisor.restart_child(supervisor, Worker)
    send(health, :check)
    assert_receive {:supervision_alert, %{expected: 1, healthy: 1, missing: []}}, 2_000
  end

  test "reports a child supervisor that exits after restart intensity exhaustion" do
    test_pid = self()

    specs = [
      %{id: CrashLoopSupervisor, start: {CrashLoopSupervisor, :start_link, [[test_pid]]}, restart: :temporary, type: :supervisor}
    ]

    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

    on_exit(fn -> stop_supervisor(supervisor) end)

    {:ok, health} =
      SupervisionHealth.start_link(
        name: nil,
        supervisor: supervisor,
        expected_children: specs,
        check_interval: 60_000,
        alert_fun: fn snapshot, _missing -> send(test_pid, {:supervision_alert, snapshot}) end
      )

    assert {:ok, %{healthy: 2}} = SupervisionHealth.status(health)
    first_pid = Process.whereis(CrashWorker)
    assert_receive {:crash_worker_started, ^first_pid}, 2_000
    first_ref = Process.monitor(first_pid)
    assert :ok = CrashWorker.crash()
    assert_receive {:DOWN, ^first_ref, :process, ^first_pid, :boom}, 2_000
    assert_receive {:crash_worker_started, new_pid}, 2_000
    refute new_pid == first_pid

    parent_pid = Process.whereis(CrashLoopSupervisor)
    parent_ref = Process.monitor(parent_pid)
    assert :ok = CrashWorker.crash()
    assert_receive {:DOWN, ^parent_ref, :process, ^parent_pid, :shutdown}, 2_000

    assert {:ok, %{healthy: 0}} = SupervisionHealth.status(health)

    assert_receive {:supervision_alert, %{healthy: 0, missing: [%{id: CrashLoopSupervisor, reason: :shutdown} | _]}}, 2_000
    assert {:ok, snapshot} = SupervisionHealth.status(health)
    assert SupervisionHealth.format(snapshot) =~ "CrashLoopSupervisor DOWN (last termination: :shutdown)"
  end

  test "walks fixed children of nested supervisors" do
    specs = [{NestedSupervisor, restart: :temporary}]
    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

    on_exit(fn -> stop_supervisor(supervisor) end)

    assert %{expected: 2, healthy: 2, missing: []} = SupervisionHealth.check(supervisor, specs)
    assert :ok = Supervisor.terminate_child(NestedSupervisor, NestedWorker)

    assert %{expected: 2, healthy: 1, missing: [missing]} = SupervisionHealth.check(supervisor, specs)
    assert missing.path == [NestedSupervisor, NestedWorker]
    assert SupervisionHealth.format(%{expected: 2, healthy: 1, missing: [missing]}) =~ "NestedSupervisor/Aiur.SupervisionHealthTest.NestedWorker DOWN"
  end

  test "retains a degraded snapshot when alert delivery exits" do
    specs = [{Worker, name: nil, restart: :temporary}]
    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

    on_exit(fn -> stop_supervisor(supervisor) end)

    {:ok, health} =
      SupervisionHealth.start_link(
        name: nil,
        supervisor: supervisor,
        expected_children: specs,
        check_interval: 60_000,
        alert_fun: fn _snapshot, _missing -> exit(:id_generator_down) end
      )

    assert {:ok, %{healthy: 1}} = SupervisionHealth.status(health)
    assert :ok = Supervisor.terminate_child(supervisor, Worker)
    send(health, :check)
    assert {:ok, %{healthy: 0, missing: [%{id: Worker}]}} = SupervisionHealth.status(health)
  end

  test "emits production degraded and recovered alerts" do
    root = Path.join(System.tmp_dir!(), "aiur-supervision-alert-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    log_root = Path.join(root, "log")
    previous_log_file = Application.get_env(:aiur, :log_file)
    specs = [{Worker, name: Worker, restart: :temporary}]
    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      stop_supervisor(supervisor)

      if previous_log_file do
        Application.put_env(:aiur, :log_file, previous_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(root)
    end)

    {:ok, health} =
      SupervisionHealth.start_link(
        name: nil,
        supervisor: supervisor,
        expected_children: specs,
        check_interval: 60_000,
        alert_opts: [workspace: workspace]
      )

    assert :ok = Supervisor.terminate_child(supervisor, Worker)
    send(health, :check)
    assert {:ok, %{healthy: 0}} = SupervisionHealth.status(health)

    assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), fn alert ->
             alert["topic"] == "system.supervision.degraded" and
               alert["needs_attention"] == true and
               alert["message"] =~ "Aiur.SupervisionHealthTest.Worker DOWN"
           end)

    assert {:ok, _worker} = Supervisor.restart_child(supervisor, Worker)
    send(health, :check)
    assert {:ok, %{healthy: 1}} = SupervisionHealth.status(health)

    assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), fn alert ->
             alert["topic"] == "system.supervision.degraded.resolved" and
               alert["needs_attention"] == false
           end)
  end

  test "does not alert while a permanent child restarts normally" do
    test_pid = self()
    specs = [{RestartingWorker, name: RestartingWorker, notify: self()}]
    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

    on_exit(fn -> stop_supervisor(supervisor) end)

    {:ok, health} =
      SupervisionHealth.start_link(
        name: nil,
        supervisor: supervisor,
        expected_children: specs,
        check_interval: 60_000,
        alert_fun: fn snapshot, _missing -> send(test_pid, {:supervision_alert, snapshot}) end
      )

    assert {:ok, %{healthy: 1}} = SupervisionHealth.status(health)
    old_pid = Process.whereis(RestartingWorker)
    assert_receive {:restarting_worker_started, ^old_pid}, 2_000
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :boom)

    assert_receive {:DOWN, ^ref, :process, ^old_pid, :boom}, 2_000
    assert_receive {:restarting_worker_started, new_pid}, 2_000
    refute new_pid == old_pid
    refute_receive {:supervision_alert, %{healthy: 0}}, 2_000
    assert {:ok, %{healthy: 1, missing: []}} = SupervisionHealth.status(health)
  end

  defp stop_supervisor(supervisor) do
    if Process.alive?(supervisor) do
      try do
        Supervisor.stop(supervisor)
      catch
        :exit, _reason -> :ok
      end
    end
  end
end
