defmodule Aiur.AgentControlCLI.CommandProbe do
  def run(opts) do
    IO.puts("probe options: #{inspect(opts)}")
    0
  end
end

defmodule Aiur.AgentControlCLICommandTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI

  test "runs a fragment-owned command module and emits the control exit marker" do
    output = capture_io(fn -> AgentControlCLI.run_command("probe", Aiur.AgentControlCLI.CommandProbe, value: 42) end)

    assert output =~ "probe options: [value: 42]"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end
end
