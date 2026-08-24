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
    home = Aiur.TestSupport.tmp_root!("aiur-alert-watch")
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
        {"AIUR_ALERT_NEEDS_ATTENTION", if(opts[:needs_attention], do: "1", else: "0")},
        {"AIUR_ALERT_DISABLE_JQ", if(opts[:no_jq], do: "1", else: "0")}
      ] ++ Keyword.get(opts, :extra_env, [])

    {out, status} = System.cmd("bash", [@script, config], env: env, stderr_to_stdout: true)
    assert status == 0, "script exited #{status}:\n#{out}"
    out
  end

  test "rejects an explicit legacy config path", %{home: home} do
    File.mkdir_p!(home)
    legacy = Path.join(home, ".aiurconfig")
    File.write!(legacy, "workspace:\n  root: ~/workspaces\n")

    {out, status} = System.cmd("bash", [@script, legacy], env: [{"HOME", home}], stderr_to_stdout: true)

    assert status == 1
    assert out =~ ".aiurconfig is no longer supported"
    assert out =~ Path.join([home, ".aiur", "config"])
    assert out =~ "relative prompt_file and hooks_file paths"
  end

  test "rejects a named legacy config with its YAML destination", %{home: home} do
    File.mkdir_p!(home)
    legacy = Path.join(home, "portable.aiurconfig")
    File.write!(legacy, "workspace:\n  root: ~/workspaces\n")

    {out, status} = System.cmd("bash", [@script, legacy], env: [{"HOME", home}], stderr_to_stdout: true)

    assert status == 1
    assert out =~ "portable.aiurconfig is no longer supported"
    assert out =~ Path.join(home, "portable.yaml")
  end

  # Pull the emitted JSON object lines (the watcher emits only alert objects).
  defp alert_lines(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  defp install_poll_barrier(home) do
    barrier = Path.join(home, "poll-barrier")
    sleep = Path.join(home, "bin/sleep")
    File.mkdir_p!(Path.dirname(sleep))

    File.write!(
      sleep,
      ~S"""
      #!/bin/sh
      count_file="$AIUR_ALERT_POLL_BARRIER/count"
      mkdir -p "$AIUR_ALERT_POLL_BARRIER"
      count=0
      [ ! -f "$count_file" ] || count=$(cat "$count_file")
      count=$((count + 1))
      printf '%s\n' "$count" > "$count_file.tmp"
      mv "$count_file.tmp" "$count_file"
      until [ -f "$AIUR_ALERT_POLL_BARRIER/release-$count" ]; do /bin/sleep 0.01; done
      exec /bin/sleep "$@"
      """
    )

    File.chmod!(sleep, 0o755)
    barrier
  end

  defp await_poll(barrier, count, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_poll_until(barrier, count, deadline)
  end

  defp await_poll_until(barrier, count, deadline) do
    count_file = Path.join(barrier, "count")
    polls = if File.exists?(count_file), do: count_file |> File.read!() |> String.trim() |> String.to_integer(), else: 0

    cond do
      polls >= count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("watcher did not reach poll #{count}")

      true ->
        Process.sleep(10)
        await_poll_until(barrier, count, deadline)
    end
  end

  defp release_poll(barrier, count) do
    File.touch!(Path.join(barrier, "release-#{count}"))
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
    assert paused["operator_decision"] == false
  end

  test "marks canonical operator-decision attention alerts for backend fan-out", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    File.write!(
      ndjson,
      ~s({"event":"alert","timestamp":"2026-07-10T10:00:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision"}) <>
        "\n"
    )

    [alert] = run(config, home, backlog: true) |> alert_lines()

    assert alert["ticket"] == "934"
    assert alert["needs_attention"] == true
    assert alert["operator_decision"] == true
    assert alert["decision_state"] == "open"
    assert alert["decision_key"] == "ticket.934.agent.attention.operator-decision"
    assert alert["reason"] == "Should wave five own the facade target?"
  end

  test "streams a keyed decision resolution even in needs-attention-only mode", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    File.write!(
      ndjson,
      [
        ~s({"event":"alert","timestamp":"2026-07-10T10:00:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision"}),
        ~s({"event":"alert","timestamp":"2026-07-10T10:01:00Z","reason":"Operator decision resolved.","severity":"info","needs_attention":false,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision.resolved"})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    )

    alerts = run(config, home, backlog: true, needs_attention: true) |> alert_lines()
    resolution = Enum.find(alerts, &(&1["decision_state"] == "resolved"))

    assert resolution["operator_decision"] == true
    assert resolution["decision_key"] == "ticket.934.agent.attention.operator-decision"
    assert resolution["reason"] == "Executor decision resolved."
    assert resolution["notification_results"] == "not-applicable"
  end

  test "replays an unresolved decision after a watcher restart but not a resolved one", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    open =
      ~s({"event":"alert","timestamp":"2026-07-10T10:00:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision"})

    resolved =
      ~s({"event":"alert","timestamp":"2026-07-10T10:01:00Z","reason":"Executor decision resolved.","severity":"info","needs_attention":false,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision.resolved"})

    File.write!(ndjson, open <> "\n", [:append])
    [replayed] = run(config, home) |> alert_lines()
    assert replayed["decision_state"] == "open"

    File.write!(ndjson, resolved <> "\n", [:append])
    assert run(config, home) |> alert_lines() == []
  end

  test "ignores malformed historical alert records during decision recovery", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    File.write!(
      ndjson,
      [
        ~s({"event":"alert","timestamp":"2026-07-10T10:00:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision"}),
        ~s({"event":"alert","topic":)
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    )

    [replayed] = run(config, home) |> alert_lines()
    assert replayed["decision_state"] == "open"
  end

  test "dispatches every configured active notification surface and reports failures", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)
    bin = Path.join(home, "bin")
    notification_log = Path.join(home, "notifications.ndjson")
    recorder = Path.join(bin, "record-notification")
    File.mkdir_p!(bin)
    File.write!(recorder, "#!/bin/sh\ncat >> \"$AIUR_NOTIFY_LOG\"\n")
    File.chmod!(recorder, 0o755)

    File.write!(
      ndjson,
      ~s({"event":"alert","timestamp":"2026-07-10T10:00:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","topic":"ticket.934.agent.attention.operator-decision"}) <>
        "\n"
    )

    [alert] =
      run(config, home,
        backlog: true,
        extra_env: [
          {"AIUR_NOTIFY_LOG", notification_log},
          {"AIUR_OPERATOR_SURFACES", "codex,remote-control"},
          {"AIUR_ALERT_NOTIFY_CODEX_COMMAND", "record-notification"},
          {"AIUR_ALERT_NOTIFY_RC_COMMAND", "false"}
        ]
      )
      |> alert_lines()

    assert alert["notification_results"] == "codex:sent,remote-control:failed"
    assert Jason.decode!(File.read!(notification_log))["topic"] == "ticket.934.agent.attention.operator-decision"
  end

  test "the portable jq-less path emits a valid decision record", %{home: home, ndjson: ndjson} do
    config = build_fixture(home)

    File.write!(
      ndjson,
      ~s({"event":"alert","timestamp":"2026-07-10T10:00:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","name":"ticket.934.agent.attention.operator-decision"}) <>
        "\n"
    )

    [alert] = run(config, home, backlog: true, no_jq: true) |> alert_lines()
    assert alert["operator_decision"] == true
    assert alert["decision_state"] == "open"
    assert alert["reason"] == "Should wave five own the facade target?"
  end

  test "AIUR_ALERT_NEEDS_ATTENTION=1 (Phase 2 switch) relays only attention-worthy alerts", %{home: home} do
    config = build_fixture(home)
    alerts = run(config, home, backlog: true, needs_attention: true) |> alert_lines()

    names = Enum.map(alerts, & &1["name"])
    assert names == ["ticket.38.agent.paused"]
    refute "ticket.38.agent.phase.plan.start" in names
  end

  test "wakes on a NEW decision in seconds and notifies the active surface once", %{
    home: home,
    ndjson: ndjson
  } do
    config = build_fixture(home)
    bin = Path.join(home, "bin")
    notification_log = Path.join(home, "wake-notifications.ndjson")
    recorder = Path.join(bin, "record-wake-notification")
    File.mkdir_p!(bin)
    File.write!(recorder, "#!/bin/sh\ncat >> \"$AIUR_NOTIFY_LOG\"\n")
    File.chmod!(recorder, 0o755)
    poll_barrier = install_poll_barrier(home)
    started_at = System.monotonic_time(:millisecond)

    fresh =
      ~s({"event":"alert","timestamp":"2026-06-29T10:05:00Z","reason":"Should wave five own the facade target?","severity":"warning","needs_attention":true,"source_ticket_id":"934","name":"ticket.934.agent.attention.operator-decision"})

    # Append the fresh alert mid-watch: the first scan baselines the file (history
    # skipped), the append lands during the poll, a later scan streams it once.
    appender =
      Task.async(fn ->
        await_poll(poll_barrier, 1)
        File.write!(ndjson, fresh <> "\n", [:append])
        release_poll(poll_barrier, 1)

        # Arrival at poll 2 proves scan 2 consumed the new alert. Release the
        # watcher so scan 3 can verify the alert is not emitted twice.
        await_poll(poll_barrier, 2)
        release_poll(poll_barrier, 2)
      end)

    out =
      run(config, home,
        iters: 3,
        poll: 1,
        extra_env: [
          {"AIUR_NOTIFY_LOG", notification_log},
          {"AIUR_ALERT_POLL_BARRIER", poll_barrier},
          {"AIUR_OPERATOR_SURFACES", "codex"},
          {"AIUR_ALERT_NOTIFY_CODEX_COMMAND", "record-wake-notification"}
        ]
      )

    Task.await(appender)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    alerts = alert_lines(out)
    names = Enum.map(alerts, & &1["name"])
    [wake] = Enum.filter(alerts, &(&1["name"] == "ticket.934.agent.attention.operator-decision"))

    # History is never relayed.
    refute "ticket.38.agent.paused" in names
    refute "ticket.38.agent.phase.plan.start" in names
    # The fresh decision is streamed and pushed exactly once (no re-emit on
    # the next scan), carrying the machine-readable wake classification.
    assert wake["operator_decision"] == true
    assert wake["notification_results"] == "codex:sent"
    assert Jason.decode!(File.read!(notification_log))["name"] == wake["name"]
    # The real-time path surfaces the alert in seconds, independently of the
    # multi-minute status cadence. Keep enough headroom for a loaded CI host.
    assert elapsed_ms < 10_000
  end

  test "defers a half-written alert until the line completes, then streams it once", %{
    home: home,
    ndjson: ndjson
  } do
    config = build_fixture(home)
    poll_barrier = install_poll_barrier(home)

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
        # Hold the watcher after its baseline until the partial head is present.
        await_poll(poll_barrier, 1)
        File.write!(ndjson, head, [:append])
        release_poll(poll_barrier, 1)

        # Poll 2 begins only after scan 2 observed the incomplete line. Keep the
        # watcher held until the tail is appended, then let scan 3 consume it.
        await_poll(poll_barrier, 2)
        File.write!(ndjson, tail, [:append])
        release_poll(poll_barrier, 2)

        await_poll(poll_barrier, 3)
        release_poll(poll_barrier, 3)
      end)

    out = run(config, home, iters: 4, poll: 1, extra_env: [{"AIUR_ALERT_POLL_BARRIER", poll_barrier}])
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

    for no_jq <- [false, true] do
      [alert] = run(config, home, backlog: true, no_jq: no_jq) |> alert_lines()
      assert alert["reason"] == "line\twith control \"chars\""
      assert alert["needs_attention"] == true
    end
  end
end
