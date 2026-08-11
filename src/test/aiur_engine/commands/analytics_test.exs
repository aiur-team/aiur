defmodule Aiur.EngineCommand.AnalyticsTest do
  use ExUnit.Case, async: true
  import Aiur.EngineCommandTestSupport

  test "routes an explicit window through the generic control RPC" do
    {out, 0} =
      run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\naiur_engine_main analytics --range full --since 2026-08-09T10:00:00Z --until 2026-08-09T11:00:00Z --build-order 1595 --json|)

    assert out =~ "RPC:Aiur.AgentControlCLI.run_command(\"analytics\", Aiur.AnalyticsCLI, [range: :full, json: true"
    assert out =~ "since: Base.decode64!"
    assert out =~ "build_order: Base.decode64!"
  end

  test "rejects malformed launcher arguments before an RPC" do
    for {argv, message} <- [
          {~s|--range week|, "analytics --range accepts run or full"},
          {~s|--build-order not-a-ticket|, "analytics --build-order expects a numeric ticket ID"},
          {~s|--build-order ''|, "analytics --build-order expects a numeric ticket ID"},
          {~s|--since|, "analytics --since requires a value"},
          {~s|--unknown|, "analytics received an unknown option"}
        ] do
      {out, 64} = run_sourced_engine("cmd_analytics #{argv}")
      assert out =~ message
    end
  end
end
