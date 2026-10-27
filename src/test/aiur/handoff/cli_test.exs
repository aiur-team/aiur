defmodule Aiur.Handoff.CliTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Handoff.CLI

  test "agents JSON names its versioned contract" do
    snapshot = %{
      running: [
        %{
          identifier: "5698",
          issue_id: "I_5698",
          session_id: "session-5698",
          provider_pid: 12_345,
          codex_app_server_pid: nil,
          adopted_from: nil
        }
      ]
    }

    output = capture_io(fn -> CLI.agents(snapshot: snapshot) end)
    [json | _markers] = String.split(output, "\n", trim: true)

    assert %{
             "contract" => "aiur.agents",
             "contract_version" => 1,
             "running" => [%{"identifier" => "5698"}]
           } = Jason.decode!(json)
  end

  test "prepare reports a timed out preflight in plain language and suggests retry" do
    server_name = Aiur.Orchestrator
    pid = Process.whereis(server_name)
    :sys.suspend(pid)

    output =
      try do
        capture_io(fn -> CLI.prepare(snapshot_timeout_ms: 10) end)
      after
        :sys.resume(pid)
      end

    assert output =~ "running daemon did not answer the handoff query within 10ms (control RPC blocked)"
    assert output =~ "retry the restart"
    refute output =~ "timeout.running/0 is undefined"
  end
end
