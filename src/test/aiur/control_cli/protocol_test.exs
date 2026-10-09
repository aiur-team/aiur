defmodule Aiur.ControlCLI.ProtocolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.ControlCLI.Protocol

  test "regression guard: exit and error markers match the launcher's literals" do
    engine = File.read!(Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__))

    assert Protocol.exit_marker() == "__AIUR_CONTROL_EXIT__:"
    assert Protocol.error_marker() == "__AIUR_CONTROL_ERROR__:"
    assert engine =~ Protocol.exit_marker()
    assert engine =~ Protocol.error_marker()
  end

  test "guarded/2 turns a GenServer call timeout into exit 124 with one line" do
    orchestrator = Process.whereis(Aiur.Orchestrator)
    Process.unregister(Aiur.Orchestrator)

    output =
      try do
        capture_io(fn ->
          assert :ok = Protocol.guarded("x", fn -> exit({:timeout, {GenServer, :call, [:server, :request, 1500]}}) end)
        end)
      after
        Process.register(orchestrator, Aiur.Orchestrator)
      end

    assert output ==
             "__AIUR_CONTROL_ERROR__:aiur: x query timed out after 1500ms; outcome is unknown. " <>
               "The orchestrator process is not registered, so the daemon is down or still starting.\n" <>
               "__AIUR_CONTROL_EXIT__:124\n"
  end

  test "guarded/2 turns a raise into one error line and exit 1" do
    output = capture_io(fn -> assert :ok = Protocol.guarded("x", fn -> raise "boom" end) end)

    assert output == "__AIUR_CONTROL_ERROR__:aiur: x query failed (boom)\n__AIUR_CONTROL_EXIT__:1\n"
  end
end
