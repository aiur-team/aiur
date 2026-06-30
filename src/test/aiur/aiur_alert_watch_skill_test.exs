defmodule Aiur.AiurAlertWatchSkillTest do
  @moduledoc """
  Guards the aiur-monitor real-time alert watcher (`watch-alerts.sh`): the
  immediacy half of the alert relay. Where `aiurdev watch` is a one-shot board
  pull relayed on the 5-minute status tick, this script is long-lived and
  streams one structured line per NEW alert as it lands, so the operator agent
  can post the "why" in chat in near real time.

  It reads the SAME #651/#662 per-agent `logs/agent.ndjson` feed as the alert
  board, and tracks per-file alert-line counts in memory so it only
  emits alerts that fire after watching began (history is skipped unless
  `AIUR_ALERT_RELAY_BACKLOG=1`).

  The script is plain bash, driven as a subprocess against a fixture HOME, the
  same hermetic pattern as aiur_alert_relay_skill_test.exs. `AIUR_ALERT_WATCH_ITERS`
  bounds the otherwise-infinite watch loop so each run terminates deterministically.
  """
  use ExUnit.Case, async: true

  # test/aiur/ -> test/ -> src/ -> repo root
  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, ".claude/skills/aiur-monitor/scripts/watch-alerts.sh")

  setup do
    home = Path.join(System.tmp_dir!(), "aiur-alert-watch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home, ndjson: ndjson_path(home)}
  end

  defp ndjson_path(home) do
    Path.join(home, ".aiur/workspaces/its-applekid/actions/38/logs/agent.ndjson")
  end

  # An active namespaced workspace with two pre-existing alerts (one
  # attention-worthy, one informational) plus a non-alert event.
  defp build_fixture(home) do
    config = Path.join(home, "cfg")
    File.mkdir_p!(home)
    File.write!(config, "workspace:\n  root: ~/code/aiur-workspaces\n")
    File.mkdir_p!(Path.join(home, "code/aiur-workspaces"))

    ndjson = ndjson_path(home)
    File.mkdir_p!(Path.dirname(ndjson))

    lines = [
      ~s({"event":"alert","timestamp":"2026-06-29T10:00:00Z","message":"Agent paused","reason":"Operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"38","name":"ticket.38.agent.paused"}),
      ~s({"event":"alert","timestamp":"2026-06-29T10:00:01Z","message":"planning the fix","reason":"plan phase started","severity":"info","needs_attention":false,"source_ticket_id":"38","name":"ticket.38.agent.phase.plan.start"}),
      # a non-alert event must be ignored entirely
      ~s({"event":"turn","name":"ticket.38.turn.started"})
    ]

    File.write!(ndjson, Enum.join(lines, "\n") <> "\n")
    config
  end

  # Run the watcher for `iters` scans (default 1) against the fixture HOME.
  defp run(config, home, opts \\ []) do
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)

    for name <- ~w(pgrep tmux) do
      stub = Path.join(bin, name)
      File.write!(stub, "#!/bin/sh\nexit 1\n")
      File.chmod!(stub, 0o755)
    end

    env =
      [
        {"HOME", home},
        {"PATH", bin <> ":" <> System.get_env("PATH", "")},
        {"AIUR_ALERT_WATCH_ITERS", to_string(Keyword.get(opts, :iters, 1))},
        {"AIUR_ALERT_POLL", to_string(Keyword.get(opts, :poll, 1))},
        {"AIUR_ALERT_RELAY_BACKLOG", if(opts[:backlog], do: "1", else: "0")},
        {"AIUR_ALERT_NEEDS_ATTENTION", if(opts[:needs_attention], do: "1", else: "0")}
      ]

    {out, status} = System.cmd("bash", [@script, config], env: env, stderr_to_stdout: true)
    assert status == 0, "script exited #{status}:\n#{out}"
    out
  end

  # Pull the emitted JSON object lines (the watcher emits only alert objects).
  defp alert_lines(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  test "cold start skips history — relays nothing already present", %{home: home} do
    config = build_fixture(home)
    assert run(config, home) |> alert_lines() == []
  end

  test "AIUR_ALERT_RELAY_BACKLOG=1 relays every pre-existing alert, ignoring non-alerts", %{home: home} do
    config = build_fixture(home)
    alerts = run(config, home, backlog: true) |> alert_lines()

    names = Enum.map(alerts, & &1["name"])
    # Phase 1 relays ALL alerts, not just needs_attention ones.
    assert "ticket.38.agent.paused" in names
    assert "ticket.38.agent.phase.plan.start" in names
    # the turn/ event is not an alert and must never appear
    refute "ticket.38.turn.started" in names
    assert length(alerts) == 2
  end

  test "derives ticket/agent/reason/timestamp/needs_attention from each alert", %{home: home} do
    config = build_fixture(home)

    paused =
      run(config, home, backlog: true)
      |> alert_lines()
      |> Enum.find(&(&1["name"] == "ticket.38.agent.paused"))

    assert paused["timestamp"] == "2026-06-29T10:00:00Z"
    assert paused["ticket"] == "38"
    assert paused["agent"] == "38"
    assert paused["reason"] == "Operator paused the agent"
    assert paused["severity"] == "warning"
    assert paused["source_ticket_id"] == "38"
    assert paused["needs_attention"] == true
  end

  test "AIUR_ALERT_NEEDS_ATTENTION=1 (Phase 2 switch) relays only attention-worthy alerts", %{home: home} do
    config = build_fixture(home)
    alerts = run(config, home, backlog: true, needs_attention: true) |> alert_lines()

    names = Enum.map(alerts, & &1["name"])
    assert names == ["ticket.38.agent.paused"]
    refute "ticket.38.agent.phase.plan.start" in names
  end

  test "streams a NEW alert appended during the watch exactly once, never history", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    fresh =
      ~s({"event":"alert","timestamp":"2026-06-29T10:05:00Z","reason":"fresh blocker","severity":"warning","needs_attention":true,"source_ticket_id":"38","name":"ticket.38.agent.blocked"})

    # Append the fresh alert mid-watch: the first scan baselines the file (history
    # skipped), the append lands during the poll, a later scan streams it once.
    appender =
      Task.async(fn ->
        Process.sleep(500)
        File.write!(ndjson, fresh <> "\n", [:append])
      end)

    out = run(config, home, iters: 3, poll: 1)
    Task.await(appender)

    alerts = alert_lines(out)
    names = Enum.map(alerts, & &1["name"])

    # History is never relayed.
    refute "ticket.38.agent.paused" in names
    refute "ticket.38.agent.phase.plan.start" in names
    # The fresh alert is streamed exactly once (no re-emit on the next scan).
    assert Enum.count(names, &(&1 == "ticket.38.agent.blocked")) == 1
  end

  test "defers a half-written alert until the line completes, then streams it once", %{
    home: home,
    ndjson: ndjson
  } do
    config = build_fixture(home)

    # A real append flushes `json <> "\n"` in one write, but a scan can still land
    # on a half-written prefix: bytes present, line not yet newline-terminated.
    # The watcher must NOT count, emit, or advance its cursor past such a line —
    # otherwise the completed alert is dropped forever (it never re-counts as
    # new). Simulate it: write a truncated, unparseable head (no newline), then a
    # poll later append the remainder + newline. The completed alert streams once.
    head = ~s({"event":"alert","timestamp":"2026-06-29T10:06:00Z","reason":"half-w)

    tail =
      ~s(ritten","severity":"warning","needs_attention":true,"source_ticket_id":"38","name":"ticket.38.agent.partial"}\n)

    appender =
      Task.async(fn ->
        Process.sleep(300)
        File.write!(ndjson, head, [:append])
        Process.sleep(1200)
        File.write!(ndjson, tail, [:append])
      end)

    out = run(config, home, iters: 4, poll: 1)
    Task.await(appender)

    names = out |> alert_lines() |> Enum.map(& &1["name"])
    # History is never relayed, and the half-written alert is neither dropped nor
    # double-streamed: exactly one emit once the line is whole.
    refute "ticket.38.agent.paused" in names
    assert Enum.count(names, &(&1 == "ticket.38.agent.partial")) == 1
  end

  test "escapes structured text fields as valid JSON", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    File.write!(
      ndjson,
      Jason.encode!(%{
        "event" => "alert",
        "timestamp" => "2026-06-29T10:00:00Z",
        "message" => "custom alert",
        "reason" => "line\twith control \"chars\"",
        "severity" => "warning",
        "needs_attention" => true,
        "source_ticket_id" => "38",
        "topic" => "ticket.38.agent.custom"
      }) <> "\n"
    )

    [alert] = run(config, home, backlog: true) |> alert_lines()
    assert alert["reason"] == "line\twith control \"chars\""
    assert alert["needs_attention"] == true
  end
end
