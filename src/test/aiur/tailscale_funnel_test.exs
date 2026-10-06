defmodule Aiur.TailscaleFunnelTest do
  use ExUnit.Case, async: true

  alias Aiur.TailscaleFunnel

  @old_target "http://127.0.0.1:35015"
  @new_target "http://127.0.0.1:43969"
  @listener "orangekid.example.ts.net:443"

  defp status(target, allow_funnel \\ true) do
    %{
      "AllowFunnel" => %{@listener => allow_funnel},
      "Web" => %{
        @listener => %{
          "Handlers" => %{"/" => %{"Proxy" => target}}
        }
      }
    }
  end

  defp fake_command(initial_status, test_pid) do
    state = start_supervised!({Agent, fn -> %{status: initial_status, writes: []} end})

    runner = fn _executable, args, _timeout -> run_fake_command(args, state, test_pid) end

    {state, runner}
  end

  defp run_fake_command(["funnel", "status", "--json"], state, _test_pid) do
    {Agent.get(state, fn current -> Jason.encode!(current.status) end), 0}
  end

  defp run_fake_command(["funnel", "--bg", "--https=443", "--yes", target], state, test_pid) do
    send(test_pid, {:funnel_update, target})
    Agent.update(state, fn current -> %{current | status: status(target), writes: [target | current.writes]} end)
    {"updated", 0}
  end

  defp run_fake_command(args, _state, _test_pid) do
    raise "unexpected tailscale command: #{inspect(args)}"
  end

  test "reconciles a stale Funnel target to the dynamically bound dashboard port" do
    {state, runner} = fake_command(status(@old_target), self())

    assert :ok = TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))
    assert_receive {:funnel_update, @new_target}, 1_000
    assert Agent.get(state, & &1.writes) == [@new_target]
  end

  test "updates a target when Req reports a refused connection" do
    old_target = "http://127.0.0.1:35017"
    expected_target = "http://127.0.0.1:43971"
    {state, runner} = fake_command(status(old_target), self())
    probe = fn _url, _timeout -> {:error, %Req.TransportError{reason: :econnrefused}} end

    assert :ok = TailscaleFunnel.reconcile("127.0.0.1", 43_971, funnel_opts(runner, target_probe: probe))
    assert_receive {:funnel_update, ^expected_target}, 1_000
    assert Agent.get(state, & &1.writes) == [expected_target]
  end

  test "leaves an already-current Funnel target unchanged" do
    {state, runner} = fake_command(status(@new_target), self())

    assert :ok = TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))
    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "recognizes equivalent loopback URLs and root path spellings as this daemon" do
    equivalent_target = "http://localhost:43969/"
    {state, runner} = fake_command(status(equivalent_target), self())

    assert :ok = TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))
    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "recognizes IPv6 loopback as equivalent to the bound loopback target" do
    equivalent_target = "http://[::1]:43969"
    {state, runner} = fake_command(status(equivalent_target), self())

    assert :ok = TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))
    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "refuses to replace a target when probing fails for a reason other than connection refused" do
    {state, runner} = fake_command(status(@old_target), self())
    probe = fn _url, _timeout -> {:error, :timeout} end

    assert {:error, {:target_probe_unknown, :unknown}} =
             TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner, target_probe: probe))

    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "GenServer alerts on a live target mismatch and does not write a new target" do
    test_pid = self()
    {state, runner} = fake_command(status(@old_target), self())
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    start_supervised!(
      {TailscaleFunnel,
       name: name,
       host_fun: fn -> "127.0.0.1" end,
       port_fun: fn -> 43_969 end,
       interval_ms: 60_000,
       tailscale_executable: "/fake/tailscale",
       tailscale_runner: runner,
       target_probe: fn _url, _timeout -> {:ok, %Req.Response{status: 401}} end,
       alert: fn topic, opts -> send(test_pid, {:reconcile_alert, topic, opts}) end}
    )

    assert_receive {:reconcile_alert, "system.build_order_funnel.target_mismatch", alert_opts}, 1_000
    assert alert_opts[:needs_attention]
    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "does not create a Funnel when the operator has not enabled one" do
    {state, runner} = fake_command(status(@old_target, false), self())

    assert {:error, :funnel_443_not_enabled} =
             TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))

    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "reports malformed Funnel status without attempting a route change" do
    runner = fn _executable, ["funnel", "status", "--json"], _timeout -> {"not json", 0} end

    assert {:error, :invalid_status_json} = TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))
  end

  test "requires the updated Funnel target to be visible after the command succeeds" do
    runner = fn _executable, args, _timeout ->
      case args do
        ["funnel", "status", "--json"] -> {Jason.encode!(status(@old_target)), 0}
        ["funnel", "--bg", "--https=443", "--yes", @new_target] -> {"updated", 0}
      end
    end

    assert {:error, {:target_verification_failed, :target_mismatch}} =
             TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner))
  end

  test "does not take over a route serving another live daemon" do
    {state, runner} = fake_command(status(@old_target), self())

    probe = fn url, 2_000 ->
      assert url == "#{@old_target}/build-orders/1"
      {:ok, %Req.Response{status: 401}}
    end

    assert {:error, {:live_funnel_target_conflict}} =
             TailscaleFunnel.reconcile("127.0.0.1", 43_969, funnel_opts(runner, target_probe: probe))

    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "updates an unreachable old target and maps wildcard binds to loopback" do
    old_target = "http://127.0.0.1:35016"
    expected_target = "http://127.0.0.1:43970"
    {state, runner} = fake_command(status(old_target), self())

    probe = fn url, 2_000 ->
      assert url == "#{old_target}/build-orders/1"
      {:error, :econnrefused}
    end

    assert :ok =
             TailscaleFunnel.reconcile("0.0.0.0", 43_970, funnel_opts(runner, target_probe: probe))

    assert_receive {:funnel_update, ^expected_target}, 1_000
    assert Agent.get(state, & &1.writes) == [expected_target]
  end

  test "alerts on reconciliation failure after its first attempt with a cause-neutral unknown reason" do
    test_pid = self()
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    runner = fn _executable, ["funnel", "status", "--json"], _timeout ->
      {Jason.encode!(%{"AllowFunnel" => %{}}), 0}
    end

    start_supervised!(
      {TailscaleFunnel,
       name: name,
       host_fun: fn -> "127.0.0.1" end,
       port_fun: fn -> 43_969 end,
       interval_ms: 60_000,
       tailscale_executable: "/fake/tailscale",
       tailscale_runner: runner,
       alert: fn topic, opts -> send(test_pid, {:reconcile_alert, topic, opts}) end}
    )

    assert_receive {:reconcile_alert, "system.build_order_funnel.health_check_error", alert_opts}, 1_000
    assert alert_opts[:reason] =~ "cause: unknown"
  end

  test "ignores an inactive HTTPS 443 handler when identifying the configured route" do
    inactive_listener = "inactive.example.ts.net:443"
    current_status = status(@new_target)
    allow_funnel = Map.put(current_status["AllowFunnel"], inactive_listener, false)

    web =
      Map.put(current_status["Web"], inactive_listener, %{
        "Handlers" => %{"/" => %{"Proxy" => @old_target}}
      })

    assert {:ok, @new_target} =
             TailscaleFunnel.funnel_target(%{
               current_status
               | "AllowFunnel" => allow_funnel,
                 "Web" => web
             })
  end

  test "rejects multiple enabled HTTPS 443 routes instead of selecting one" do
    other_listener = "other.example.ts.net:443"
    current_status = status(@new_target)

    status_with_multiple = %{
      current_status
      | "AllowFunnel" => Map.put(current_status["AllowFunnel"], other_listener, true),
        "Web" =>
          Map.put(current_status["Web"], other_listener, %{
            "Handlers" => %{"/" => %{"Proxy" => @old_target}}
          })
    }

    assert {:error, :multiple_funnel_443_routes} = TailscaleFunnel.funnel_target(status_with_multiple)
  end

  test "closes the spawned Tailscale process when its command times out" do
    directory = Path.join(System.tmp_dir!(), "tailscale-timeout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    pid_file = Path.join(directory, "pid")
    executable = Path.join(directory, "tailscale")
    File.write!(executable, "#!/bin/sh\nprintf '%s' \"$$\" > #{pid_file}\nexec sleep 30\n")
    File.chmod!(executable, 0o755)

    assert {:error, :tailscale_timeout} =
             TailscaleFunnel.command(["funnel", "status", "--json"],
               tailscale_executable: executable,
               timeout_ms: 50
             )

    os_pid = File.read!(pid_file)

    assert Enum.any?(1..30, fn _attempt ->
             case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
               {_output, 0} ->
                 Process.sleep(10)
                 false

               {_output, _status} ->
                 true
             end
           end)
  end

  defp funnel_opts(runner, extra \\ []) do
    [
      tailscale_executable: "/fake/tailscale",
      tailscale_runner: runner,
      target_probe: fn _url, _timeout -> {:error, :econnrefused} end
    ]
    |> Keyword.merge(extra)
  end
end
