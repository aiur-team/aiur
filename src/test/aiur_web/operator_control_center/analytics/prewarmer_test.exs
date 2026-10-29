defmodule AiurWeb.OperatorControlCenter.Analytics.PrewarmerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias AiurWeb.OperatorControlCenter.Analytics.Prewarmer

  test "missing endpoint identity is warned once and the prewarmer remains alive" do
    log =
      capture_log(fn ->
        previous = Application.get_env(:aiur, AiurWeb.Endpoint)
        Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(previous || [], :http, ip: {127, 0, 0, 1}, port: 0))
        {:ok, pid} = Prewarmer.start_link(name: nil, prewarm_on_start: false)
        send(pid, :check_identity)
        monitor = Process.monitor(pid)
        refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 100
        GenServer.stop(pid)
        if previous, do: Application.put_env(:aiur, AiurWeb.Endpoint, previous), else: Application.delete_env(:aiur, AiurWeb.Endpoint)
      end)

    assert length(Regex.scan(~r/Analytics prewarm skipped because the dashboard HTTP server is unavailable/, log)) == 1
  end
end
