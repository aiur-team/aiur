defmodule Aiur.AgentControlCLI.CommandProbe do
  def run(opts) do
    IO.puts("probe options: #{inspect(opts)}")
    0
  end
end

defmodule Aiur.AgentControlCLI.RaiseProbe do
  def run(_opts), do: raise("probe exploded")
end

defmodule Aiur.AgentControlCLI.ExitProbe do
  def run(_opts), do: exit(:probe_exit)
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

  test "wraps a raising fragment command in the control error frame and exits 1" do
    output =
      capture_io(fn -> AgentControlCLI.run_command("probe", Aiur.AgentControlCLI.RaiseProbe, value: 42) end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: probe query failed (probe exploded)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "wraps an exiting fragment command in the control error frame and exits 1" do
    output =
      capture_io(fn -> AgentControlCLI.run_command("probe", Aiur.AgentControlCLI.ExitProbe, value: 42) end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: probe query failed (process exited: :probe_exit)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end
end
