defmodule Aiur.Handoff.CliTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  test "prepare reports a timed out preflight in plain language and suggests retry" do
    server_name = Aiur.Orchestrator
    pid = Process.whereis(server_name)
    :sys.suspend(pid)

    output = capture_io(fn -> Aiur.Handoff.CLI.prepare(snapshot_timeout_ms: 10) end)

    :sys.resume(pid)

    assert output =~ "running daemon did not answer the handoff query within 10ms (control RPC blocked)"
    assert output =~ "retry the restart"
    refute output =~ "timeout.running/0 is undefined"
  end
end
