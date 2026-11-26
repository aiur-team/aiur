Code.require_file(Path.expand("../orchestrator/control_cli/fixture.exs", __DIR__))

defmodule Aiur.ControlCliEntryPointsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.GitHub.Quota

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  setup context do
    TestFixture.setup(context)
  end

  test "build-orders routes ordinary failures through the control marker" do
    output = capture_io(fn -> AgentControlCLI.build_orders(root: "") end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: build-orders accepts one non-empty Build Order root"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "github-cost routes meter failures through the control marker" do
    meter = Process.whereis(Quota)
    assert is_pid(meter)
    assert Process.unregister(Quota)

    output =
      try do
        capture_io(fn -> AgentControlCLI.github_cost() end)
      after
        assert Process.register(meter, Quota)
      end

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: github-cost the GitHub quota meter is not running"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end
end
