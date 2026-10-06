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

    runner = fn args ->
      case args do
        ["funnel", "status", "--json"] ->
          {Agent.get(state, fn current -> Jason.encode!(current.status) end), 0}

        ["funnel", "--bg", "--https=443", "--yes", target] ->
          send(test_pid, {:funnel_update, target})
          Agent.update(state, fn current -> %{current | status: status(target), writes: [target | current.writes]} end)
          {"updated", 0}

        _other ->
          flunk("unexpected tailscale command: #{inspect(args)}")
      end
    end

    {state, runner}
  end

  test "reconciles a stale Funnel target to the dynamically bound dashboard port" do
    {state, command_fun} = fake_command(status(@old_target), self())

    assert :ok = TailscaleFunnel.reconcile("100.89.62.105", 43_969, command_fun: command_fun)
    assert_receive {:funnel_update, @new_target}
    assert Agent.get(state, & &1.writes) == [@new_target]
  end

  test "leaves an already-current Funnel target unchanged" do
    {state, command_fun} = fake_command(status(@new_target), self())

    assert :ok = TailscaleFunnel.reconcile("100.89.62.105", 43_969, command_fun: command_fun)
    refute_receive {:funnel_update, _target}
    assert Agent.get(state, & &1.writes) == []
  end

  test "does not create a Funnel when the operator has not enabled one" do
    {state, command_fun} = fake_command(status(@old_target, false), self())

    assert {:error, :funnel_443_not_enabled} =
             TailscaleFunnel.reconcile("100.89.62.105", 43_969, command_fun: command_fun)

    refute_receive {:funnel_update, _target}
    assert Agent.get(state, & &1.writes) == []
  end

  test "reports malformed Funnel status without attempting a route change" do
    command_fun = fn ["funnel", "status", "--json"] -> {"not json", 0} end

    assert {:error, :invalid_status_json} = TailscaleFunnel.reconcile("127.0.0.1", 43_969, command_fun: command_fun)
  end

  test "requires the updated Funnel target to be visible after the command succeeds" do
    command_fun = fn
      ["funnel", "status", "--json"] -> {Jason.encode!(status(@old_target)), 0}
      ["funnel", "--bg", "--https=443", "--yes", @new_target] -> {"updated", 0}
    end

    assert {:error, {:target_verification_failed, @old_target}} =
             TailscaleFunnel.reconcile("100.89.62.105", 43_969, command_fun: command_fun)
  end

  test "a timed-out Tailscale command returns an error without killing its caller" do
    executable = Path.join(System.tmp_dir!(), "tailscale-timeout-#{System.unique_integer([:positive])}")
    File.write!(executable, "#!/bin/sh\nexec sleep 2\n")
    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm(executable) end)

    caller = self()

    worker =
      spawn(fn ->
        result = TailscaleFunnel.run_tailscale([], executable: executable, timeout_ms: 20)
        send(caller, {:command_result, self(), result})
      end)

    assert_receive {:command_result, ^worker, {"tailscale command timed out", 124}}, 1_000
  end
end
