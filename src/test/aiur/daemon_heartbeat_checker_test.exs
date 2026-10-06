defmodule Aiur.DaemonHeartbeatCheckerTest do
  use ExUnit.Case, async: true

  alias Aiur.DaemonHeartbeatChecker

  @threshold_ms 3_600_000

  test "a stale heartbeat with an unmatched lifecycle start emits an informational retrospective unknown gap" do
    heartbeat_at = DateTime.add(DateTime.utc_now(), -7_200, :second)
    path = heartbeat_file(heartbeat_at)
    parent = self()
    events = [%{kind: :start, run_id: "run-1", at: DateTime.add(heartbeat_at, -10, :second)}]
    emit = capture_alert(parent)

    assert :ok = check(path, events, emit)

    assert_receive {:alert, "system.daemon.gap", opts}
    assert opts[:reason] == "unknown"
    assert opts[:severity] == "info"
    assert opts[:needs_attention] == false
    assert opts[:message] =~ DateTime.to_iso8601(heartbeat_at)
    assert opts[:message] =~ "Retrospective"
    assert opts[:message] =~ "does not monitor a stopped daemon live"
  end

  test "a later clean shutdown is reported as a past clean-shutdown gap" do
    now = DateTime.utc_now()
    heartbeat_at = DateTime.add(now, -10_800, :second)
    stopped_at = DateTime.add(now, -7_200, :second)
    path = heartbeat_file(heartbeat_at)

    events = [
      %{kind: :start, run_id: "run-1", at: DateTime.add(heartbeat_at, -5, :second)},
      %{kind: :stop, run_id: "run-1", at: stopped_at}
    ]

    parent = self()
    assert :ok = check(path, events, capture_alert(parent))

    assert_receive {:alert, "system.daemon.gap", opts}
    assert opts[:reason] == "clean_shutdown"
    assert opts[:needs_attention] == false
    assert opts[:message] =~ DateTime.to_iso8601(stopped_at)
    refute opts[:message] =~ DateTime.to_iso8601(heartbeat_at)
  end

  test "an older unmatched start does not override a later clean shutdown" do
    now = DateTime.utc_now()
    heartbeat_at = DateTime.add(now, -14_400, :second)
    stopped_at = DateTime.add(now, -7_200, :second)
    path = heartbeat_file(heartbeat_at)

    events = [
      %{kind: :start, run_id: "crashed-run", at: DateTime.add(heartbeat_at, -5, :second)},
      %{kind: :start, run_id: "clean-run", at: DateTime.add(stopped_at, -3_600, :second)},
      %{kind: :stop, run_id: "clean-run", at: stopped_at}
    ]

    parent = self()
    assert :ok = check(path, events, capture_alert(parent))

    assert_receive {:alert, "system.daemon.gap", opts}
    assert opts[:reason] == "clean_shutdown"
    assert opts[:message] =~ DateTime.to_iso8601(stopped_at)
  end

  test "a stale heartbeat without lifecycle evidence does not call a first boot a daemon gap" do
    path = heartbeat_file(DateTime.add(DateTime.utc_now(), -7_200, :second))

    assert :ok = check(path, [], fn _topic, _opts -> flunk("must not emit without lifecycle evidence") end)
  end

  test "a missing heartbeat file is not treated as proof of a stopped daemon" do
    path = Path.join(System.tmp_dir!(), "missing-heartbeat-#{System.unique_integer()}")

    assert :ok =
             check(path, [%{kind: :start, run_id: "run-1", at: DateTime.utc_now()}], fn _topic, _opts ->
               flunk("must not infer downtime from a missing heartbeat")
             end)
  end

  test "a fresh heartbeat does not emit a past gap" do
    path = heartbeat_file(DateTime.add(DateTime.utc_now(), -10, :second))
    events = [%{kind: :start, run_id: "run-1", at: DateTime.utc_now()}]

    assert :ok = check(path, events, fn _topic, _opts -> flunk("must not emit for a fresh heartbeat") end)
  end

  test "invalid thresholds are ignored" do
    path = heartbeat_file(DateTime.add(DateTime.utc_now(), -7_200, :second))
    parent = self()

    assert :ok =
             DaemonHeartbeatChecker.check_and_alert!(
               fn -> {:ok, path} end,
               fn -> 0 end,
               fn -> [%{kind: :start, run_id: "run-1", at: DateTime.utc_now()}] end,
               fn topic, opts ->
                 send(parent, {:alert, topic, opts})
                 :ok
               end
             )

    refute_received {:alert, _, _}
  end

  defp check(path, events, emit_fun) do
    DaemonHeartbeatChecker.check_and_alert!(
      fn -> {:ok, path} end,
      fn -> @threshold_ms end,
      fn -> events end,
      emit_fun
    )
  end

  defp heartbeat_file(datetime) do
    path = Path.join(System.tmp_dir!(), "heartbeat-#{System.unique_integer()}")
    File.write!(path, DateTime.to_iso8601(datetime) <> "\n")
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  defp capture_alert(parent) do
    fn topic, opts ->
      send(parent, {:alert, topic, opts})
      :ok
    end
  end
end
