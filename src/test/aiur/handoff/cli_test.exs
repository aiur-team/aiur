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

  test "prepare names the blocking backends and offers drain or plain restart when nothing can be adopted" do
    output =
      capture_io(fn ->
        CLI.prepare(snapshot: fn -> %{running: [running("1", "muse"), running("2", "muse"), running("3", "muse")]} end)
      end)

    assert output =~ "no running agent supports handoff"
    assert output =~ "muse (3 agents)"
    assert output =~ "aiur pause --all"
    assert output =~ "restart plainly without keep-agents: aiur restart"
    refute output =~ "__AIUR_HANDOFF__"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "prepare counts blocking backends per backend for a mixed unsupported fleet" do
    output =
      capture_io(fn ->
        CLI.prepare(snapshot: fn -> %{running: [running("1", "muse"), running("2", nil)]} end)
      end)

    assert output =~ "muse (1 agent)"
    assert output =~ "unknown (1 agent)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "prepare proceeds for a fleet of in-daemon OpenAI-compatible agents" do
    output =
      capture_io(fn ->
        CLI.prepare(
          snapshot: fn -> %{running: [running("1", "openrouter"), running("2", "kimi")]} end,
          handoff: fn -> {:ok, %{handoff_id: "handoff-in-daemon", agents: [], skipped: []}} end
        )
      end)

    assert output =~ "__AIUR_HANDOFF__:handoff-in-daemon"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute output =~ "no running agent supports handoff"
  end

  test "prepare warns which agents resume from the workspace when only some backends are compatible" do
    output =
      capture_io(fn ->
        CLI.prepare(
          snapshot: fn -> %{running: [running("1", "codex"), running("2", "muse")]} end,
          handoff: fn -> {:ok, %{handoff_id: "handoff-mixed", agents: [], skipped: []}} end
        )
      end)

    assert output =~ "Handoff will not adopt 1 agent"
    assert output =~ "muse (1 agent)"
    assert output =~ "they resume from their workspace after the restart"
    assert output =~ "__AIUR_HANDOFF__:handoff-mixed"
  end

  defp running(identifier, backend), do: %{identifier: identifier, issue_id: "I_#{identifier}", backend: backend}
end
