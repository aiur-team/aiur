Code.require_file(Path.expand("orchestrator/control_cli/fixture.exs", __DIR__))

defmodule Aiur.AgentControlCliTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  setup context do
    TestFixture.setup(context)
  end

  test "every mutating entrypoint reports an unavailable orchestrator", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      commands = [
        fn -> AgentControlCLI.set_max_agents(2) end,
        fn -> AgentControlCLI.pause(["44"]) end,
        fn -> AgentControlCLI.resume(["44"]) end,
        fn -> AgentControlCLI.reset_budget(["44"]) end,
        fn -> AgentControlCLI.pause_global() end,
        fn -> AgentControlCLI.resume_global() end
      ]

      for command <- commands do
        output = capture_io(command)
        assert output =~ "__AIUR_CONTROL_ERROR__:", output
        assert output =~ "__AIUR_CONTROL_EXIT__:1", output
      end
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "unavailable orchestrator returns clear errors", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      status_output = capture_io(fn -> AgentControlCLI.status() end)

      pause_stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert status_output =~ "__AIUR_CONTROL_ERROR__:aiur: status query failed because the orchestrator is not running"
      assert status_output =~ "__AIUR_CONTROL_EXIT__:1"
      assert pause_stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "status prints hosted preflight before the status report" do
    keys = [
      "AIUR_SECRETS_FROM_ENV",
      "AIUR_STATE_PERSISTENT",
      "LINEAR_API_KEY",
      "AIUR_SECRET_KEY_BASE",
      "AIUR_DASHBOARD_PASSWORD"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env("AIUR_SECRETS_FROM_ENV", "1")
    System.delete_env("AIUR_STATE_PERSISTENT")
    System.delete_env("LINEAR_API_KEY")
    System.delete_env("AIUR_SECRET_KEY_BASE")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "present-secret-must-not-be-printed")

    on_exit(fn -> Enum.each(previous, fn {key, value} -> Aiur.TestSupport.restore_env(key, value) end) end)

    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:error, :unavailable}) end)

    missing_secrets = "missing required secrets: LINEAR_API_KEY, AIUR_SECRET_KEY_BASE"
    status_report = "aiur: status query failed because the orchestrator is not running"

    assert output =~ missing_secrets
    assert output =~ status_report
    assert :binary.match(output, missing_secrets) < :binary.match(output, status_report)
    refute output =~ "present-secret-must-not-be-printed"
  end
end
