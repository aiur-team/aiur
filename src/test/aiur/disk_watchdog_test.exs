defmodule Aiur.DiskWatchdogTest do
  use Aiur.TestSupport

  alias Aiur.{DiskWatchdog, Workflow}
  alias Aiur.Config.Schema.Monitoring
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, State}

  @gib 1_073_741_824

  defp fs(used_percent, free_bytes \\ 40 * @gib),
    do: %{device: "/dev/nvme0n1p2", mount: "/srv", used_percent: used_percent, free_bytes: free_bytes}

  defp check(alerted, sample) do
    test_pid = self()

    DiskWatchdog.check(alerted,
      thresholds_fun: fn -> {90, 97} end,
      sample_fun: fn -> sample end,
      largest_fun: fn -> [{"aiur/7880", 3 * @gib}] end,
      alert_fun: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
    )
  end

  test "a 91% sample alerts once per episode, not every sample, and clears when usage drops" do
    {alerted, status} = check(:ok, [fs(91)])
    assert alerted == :warn
    assert status.level == :warn
    assert_received {:alert, "system.disk.pressure", opts}
    assert opts[:needs_attention]
    assert opts[:message] =~ "/srv (/dev/nvme0n1p2) is 91% used, 40.0 GiB free"
    assert opts[:reason] =~ "aiur/7880 3.0 GiB"

    {alerted, _status} = check(alerted, [fs(92)])
    {alerted, _status} = check(alerted, [fs(91)])
    refute_received {:alert, _topic, _opts}

    {alerted, _status} = check(alerted, [fs(50)])
    assert alerted == :ok
    assert_received {:alert, "system.disk.pressure.resolved", _opts}

    {_alerted, _status} = check(alerted, [fs(91)])
    assert_received {:alert, "system.disk.pressure", _opts}
  end

  test "escalating from warn to stop alerts again, critically" do
    {alerted, _status} = check(:ok, [fs(91)])
    assert_received {:alert, "system.disk.pressure", _opts}
    {:stop, _status} = check(alerted, [fs(98)])
    assert_received {:alert, "system.disk.pressure", opts}
    assert opts[:severity] == "critical"
    assert opts[:reason] =~ "New dispatch is stopped"
  end

  describe "at 98% used" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 20, max_cpu_pressure: 20.0, min_free_memory_mb: 4096)
      :ok
    end

    test "no new dispatch starts and the status line says why" do
      {:stop, status} = check(:ok, [fs(98, 12 * @gib), %{fs(40) | mount: "/home"}])

      assert {:hold, %{signal: :disk, measured: 98, threshold: 97}} = DispatchPolicy.admission_gate(probes(status))
      assert :dispatch = DispatchPolicy.admission_gate(probes(nil))

      sampled = dispatch(probes(status))
      assert sampled.running == %{}
      assert %{signal: :disk, measured: 98} = sampled.capacity_hold
      assert Enum.any?(sampled.dispatch_capacity_constraints, &(&1.kind == :disk and &1.detail =~ "mount=/srv"))

      assert DiskWatchdog.status_line(status) ==
               "DISK /srv 98% used, 12.0 GiB free (alert at 90%, dispatch stops at 97%); new dispatch stopped"

      assert dispatch(probes(nil)).running == %{"selected" => %{}}
    end
  end

  test "a failed sample renders unknown, never 0%, and neither alerts nor holds dispatch" do
    {alerted, status} = check(:warn, :unknown)
    assert status == :unknown
    assert alerted == :warn
    refute_received {:alert, _topic, _opts}
    assert DiskWatchdog.status_line(status) == "DISK unknown (free-space sample failed)"
    refute DiskWatchdog.status_line(status) =~ "0%"
    assert DiskWatchdog.dispatch_gate(status) == :dispatch

    assert {_alerted, :unknown} = check(:ok, [])
    assert DiskWatchdog.parse_df("df: /nope: No such file or directory\n") == :unknown
  end

  test "parse_df reads POSIX df rows and drops duplicate mounts" do
    output = """
    Filesystem     1024-blocks      Used Available Capacity Mounted on
    /dev/sda1        100000000  91000000   9000000      91% /srv/my disk
    /dev/sda1        100000000  91000000   9000000      91% /srv/my disk
    """

    assert DiskWatchdog.parse_df(output) == [%{device: "/dev/sda1", mount: "/srv/my disk", used_percent: 91, free_bytes: 9_000_000 * 1024}]
  end

  test "monitoring rejects a stop line below the alert line" do
    changeset = Monitoring.changeset(%Monitoring{}, %{disk_alert_percent: 95, disk_stop_dispatch_percent: 90})
    assert {"must be at least monitoring.disk_alert_percent", _} = changeset.errors[:disk_stop_dispatch_percent]
  end

  defp dispatch(probes) do
    Dispatcher.maybe_choose_under_load(
      %State{max_concurrent_agents: 20, effective_concurrent_agents: 20},
      [],
      fn current, _ -> %{current | running: %{"selected" => %{}}} end,
      now_ms: 60_000,
      admission_probes_fun: fn -> Map.merge(probes, %{sampled_at_ms: 60_000, sample_id: 60_000}) end
    )
  end

  defp probes(disk_status) do
    %{
      cpu_pressure: %{avg10: 1.0, avg60: 1.0},
      pressure_threshold: 20.0,
      pressure_target: 10.0,
      memory_mb: 8192,
      memory_threshold_mb: 4096,
      fd_sample: :unavailable,
      runnable: 1,
      run_queue_threshold: 1.0,
      schedulers: 16,
      load: 1.0,
      load_threshold: 1.5,
      target: nil,
      cpu_snapshot: :unavailable,
      cpu_headroom: :unavailable,
      build_status: %{enabled?: true, capacity: 4, active: 0, queued: 0},
      provider_backends: [],
      queued_demand?: true,
      disk_status: disk_status
    }
  end
end
