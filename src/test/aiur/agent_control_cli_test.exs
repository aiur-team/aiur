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
end
