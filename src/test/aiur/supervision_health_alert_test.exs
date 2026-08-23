defmodule Aiur.SupervisionHealthAlertTest do
  use ExUnit.Case, async: false

  alias Aiur.{AlertFeed, AlertLedger, SupervisionHealth}

  defmodule Worker do
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

  test "emits production degraded and recovered alerts" do
    root = Aiur.TestSupport.tmp_root!("aiur-supervision-alert")
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
               alert["message"] =~ "Aiur.SupervisionHealthAlertTest.Worker DOWN"
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
