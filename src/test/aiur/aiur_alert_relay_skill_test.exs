defmodule Aiur.AiurAlertRelaySkillTest do
  @moduledoc """
  Guards the aiur-monitor alert-relay tailer (`tail-alerts.sh`): the operator
  hears an alert sound with no context, so this script pulls `event:alert` lines
  out of each active agent's `logs/agent.ndjson` and emits one structured line per
  alert using Aiur's emitted `needs_attention` verdict.

  The script is plain bash, so we drive it as a subprocess against a fixture
  HOME, the same hermetic pattern as aiur_monitor_skill_test.exs.
  """
  use ExUnit.Case, async: true

  # test/aiur/ -> test/ -> src/ -> repo root
  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, ".claude/skills/aiur-monitor/scripts/tail-alerts.sh")

  setup do
    home = Path.join(System.tmp_dir!(), "aiur-alert-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  # An active namespaced workspace under ~/.aiur/workspaces with an agent.ndjson
  # carrying a mix of attention and informational alerts. `agent.ndjson` is
  # written fresh so its mtime is inside the default active window.
  defp build_fixture(home) do
    config = Path.join(home, "cfg")
    File.mkdir_p!(home)
    File.write!(config, "workspace:\n  root: ~/code/aiur-workspaces\n")
    File.mkdir_p!(Path.join(home, "code/aiur-workspaces"))

    ndjson = Path.join(home, ".aiur/workspaces/its-applekid/actions/38/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(ndjson))

    lines = [
      ~s({"event":"alert","message":"Agent paused","reason":"Operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"38","name":"ticket.38.agent.paused"}),
      ~s({"event":"alert","message":"Agent unpaused","reason":"Agent resumed","severity":"info","needs_attention":false,"source_ticket_id":"38","name":"ticket.38.agent.unpaused"}),
      ~s({"event":"alert","message":"planning the fix","reason":"plan phase started","severity":"info","needs_attention":false,"source_ticket_id":"38","name":"ticket.38.agent.phase.plan.start"}),
      # a non-alert event must be ignored entirely
      ~s({"event":"turn","name":"ticket.38.turn.started"})
    ]

    File.write!(ndjson, Enum.join(lines, "\n") <> "\n")
    config
  end

  defp run(config, home, opts \\ []) do
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    exit_code = if opts[:node_down?], do: 1, else: 0

    for name <- ~w(pgrep tmux) do
      stub = Path.join(bin, name)
      File.write!(stub, "#!/bin/sh\nexit #{exit_code}\n")
      File.chmod!(stub, 0o755)
    end

    env = [{"HOME", home}, {"PATH", bin <> ":" <> System.get_env("PATH", "")}]
    {out, status} = System.cmd("bash", [@script, config], env: env, stderr_to_stdout: true)
    assert status == 0, "script exited #{status}:\n#{out}"
    out
  end

  # Pull the emitted JSON object lines (skip the DAEMON header + blanks).
  defp alert_lines(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  test "emits one structured line per alert, ignoring non-alert events", %{home: home} do
    config = build_fixture(home)
    alerts = run(config, home) |> alert_lines()

    names = Enum.map(alerts, & &1["name"])
    assert "ticket.38.agent.paused" in names
    assert "ticket.38.agent.unpaused" in names
    assert "ticket.38.agent.phase.plan.start" in names
    # the turn/ event is not an alert and must never appear
    refute "ticket.38.turn.started" in names
    assert length(alerts) == 3
  end

  test "derives ticket/agent/reason from each alert", %{home: home} do
    config = build_fixture(home)
    paused = run(config, home) |> alert_lines() |> Enum.find(&(&1["name"] == "ticket.38.agent.paused"))

    # ticket parsed from the topic, agent from the workspace dir (same id here).
    assert paused["ticket"] == "38"
    assert paused["agent"] == "38"
    # reason prefers the explicit emitted context.
    assert paused["reason"] == "Operator paused the agent"
    assert paused["severity"] == "warning"
    assert paused["source_ticket_id"] == "38"
  end

  test "needs_attention uses emitted booleans rather than topic heuristics", %{home: home} do
    config = build_fixture(home)
    alerts = run(config, home) |> alert_lines()

    verdict = fn name -> Enum.find(alerts, &(&1["name"] == name))["needs_attention"] end

    assert verdict.("ticket.38.agent.paused") == true
    assert verdict.("ticket.38.agent.unpaused") == false
    # Informational phase alerts are never operator-actionable.
    assert verdict.("ticket.38.agent.phase.plan.start") == false
  end

  test "does not guess attention from legacy topic names when boolean is absent", %{home: home} do
    config = build_fixture(home)
    ndjson = Path.join(home, ".aiur/workspaces/its-applekid/actions/38/logs/agent.ndjson")

    File.write!(ndjson, ~s({"event":"alert","message":"legacy paused","name":"ticket.38.agent.paused"}\n))

    [alert] = run(config, home) |> alert_lines()
    assert alert["needs_attention"] == false
  end

  test "reports no active agents when nothing is recent", %{home: home} do
    config = build_fixture(home)
    # Backdate the ndjson well outside the default 15m window.
    ndjson = Path.join(home, ".aiur/workspaces/its-applekid/actions/38/logs/agent.ndjson")
    old = System.os_time(:second) - 3600
    File.touch!(ndjson, old)

    out = run(config, home)
    assert out =~ "no active agents"
  end
end
