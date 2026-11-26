defmodule AiurWeb.OperatorControlCenter.Analytics.PrewarmerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias AiurWeb.OperatorControlCenter.Analytics.Prewarmer

  test "a bound HTTP endpoint allows the analytics prewarm to run" do
    assert is_integer(Aiur.HttpServer.bound_port())
    parent = self()
    prewarm = fn -> send(parent, :prewarm_ran) end
    {:ok, pid} = Prewarmer.start_link(name: nil, prewarm_on_start: false, prewarm_fun: prewarm)
    send(pid, :check_identity)

    assert_receive :prewarm_ran, 1_000
    GenServer.stop(pid)
  end

  test "an unavailable HTTP endpoint warns once across repeated checks and keeps running" do
    log =
      capture_log(fn ->
        {:ok, pid} =
          Prewarmer.start_link(
            name: nil,
            prewarm_on_start: false,
            bound_port_fun: fn -> nil end
          )

        send(pid, :check_identity)
        send(pid, :check_identity)
        _state = :sys.get_state(pid)
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)

    assert length(Regex.scan(~r/Analytics prewarm skipped because the dashboard HTTP server is unavailable/, log)) == 1
  end
end
