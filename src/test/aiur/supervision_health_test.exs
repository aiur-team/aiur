defmodule Aiur.SupervisionHealthTest do
  use ExUnit.Case, async: false

  alias Aiur.SupervisionHealth

  defmodule Worker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, nil}
  end

  defmodule CrashWorker do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def crash, do: GenServer.cast(__MODULE__, :crash)

    def init(:ok), do: {:ok, nil}
    def handle_cast(:crash, state), do: {:stop, :boom, state}
  end

  defmodule CrashLoopSupervisor do
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    def init(_opts), do: Supervisor.init([CrashWorker], strategy: :one_for_one, max_restarts: 1)
  end

  defmodule NestedWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, nil}
  end

  defmodule RestartingWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, nil}
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

    assert_receive {:supervision_alert, %{expected: 1, healthy: 0, missing: [%{id: Worker, reason: :shutdown}]}}, 1_000
    assert {:ok, snapshot} = SupervisionHealth.status(health)
    assert SupervisionHealth.format(snapshot) == "SUPERVISION 0/1 — Aiur.SupervisionHealthTest.Worker DOWN (last termination: :shutdown)"

    assert {:ok, _worker} = Supervisor.restart_child(supervisor, Worker)
    send(health, :check)
    assert_receive {:supervision_alert, %{expected: 1, healthy: 1, missing: []}}, 1_000
  end

  test "reports a child supervisor that exits after restart intensity exhaustion" do
    specs = [%{id: CrashLoopSupervisor, start: {CrashLoopSupervisor, :start_link, [[]]}, restart: :temporary, type: :supervisor}]
    {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)
    test_pid = self()

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
    assert :ok = CrashWorker.crash()
    assert_eventually(fn -> Process.whereis(CrashWorker) not in [nil, first_pid] end)

    assert :ok = CrashWorker.crash()
    assert_eventually(fn -> Process.whereis(CrashLoopSupervisor) == nil end)

    assert {:ok, %{healthy: 0}} = SupervisionHealth.status(health)

    assert_receive {:supervision_alert, %{healthy: 0, missing: [%{id: CrashLoopSupervisor, reason: :shutdown} | _]}}, 1_000
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

  test "does not alert while a permanent child restarts normally" do
    test_pid = self()
    specs = [{RestartingWorker, name: RestartingWorker}]
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
    Process.exit(old_pid, :boom)

    assert_eventually(fn -> Process.whereis(RestartingWorker) != old_pid end)
    refute_receive {:supervision_alert, %{healthy: 0}}, 150
    assert {:ok, %{healthy: 1, missing: []}} = SupervisionHealth.status(health)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

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
