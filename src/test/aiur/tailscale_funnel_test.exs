defmodule Aiur.TailscaleFunnelTest do
  use ExUnit.Case, async: true

  alias Aiur.TailscaleFunnel

  @old_target "http://100.89.62.105:35015"
  @new_target "http://100.89.62.105:43969"
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

    assert :ok = TailscaleFunnel.reconcile("100.89.62.105", 43_969, funnel_opts(runner))
    assert_receive {:funnel_update, @new_target}, 1_000
    assert Agent.get(state, & &1.writes) == [@new_target]
  end

  test "leaves an already-current Funnel target unchanged" do
    {state, runner} = fake_command(status(@new_target), self())

    assert :ok = TailscaleFunnel.reconcile("100.89.62.105", 43_969, funnel_opts(runner))
    refute_receive {:funnel_update, _target}, 0
    assert Agent.get(state, & &1.writes) == []
  end

  test "does not create a Funnel when the operator has not enabled one" do
    {state, runner} = fake_command(status(@old_target, false), self())

    assert {:error, :funnel_443_not_enabled} =
             TailscaleFunnel.reconcile("100.89.62.105", 43_969, funnel_opts(runner))

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

    assert {:error, {:target_verification_failed, @old_target}} =
             TailscaleFunnel.reconcile("100.89.62.105", 43_969, funnel_opts(runner))
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

  defp funnel_opts(runner), do: [tailscale_executable: "/fake/tailscale", tailscale_runner: runner]
end
