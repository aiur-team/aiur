defmodule AiurEngineHistoryTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  @stub ~s|run_control_rpc() { echo "RPC=$1"; }\n|

  test "history export routes checked flags to the control rpc" do
    {out, 0} = run_sourced_engine(@stub <> "cmd_history export --unsorted --json --after 40 --limit 100", [])
    assert out =~ "RPC=Aiur.HistoryCLI.rpc([json: true, unsorted: true, after: 40, limit: 100])"

    {out, 0} = run_sourced_engine(@stub <> "cmd_history export --limit=500 --after=007", [])
    assert out =~ "RPC=Aiur.HistoryCLI.rpc([json: false, unsorted: false, after: 7, limit: 500])"
  end

  test "the top-level dispatcher reaches cmd_history" do
    {out, 0} = run_sourced_engine(@stub <> "aiur_engine_main history export", [])
    assert out =~ "RPC=Aiur.HistoryCLI.rpc([json: false, unsorted: false, after: 0, limit: 200])"
  end

  # Values are interpolated into an Elixir expression, so anything but a
  # bounded integer must stop in the launcher with the usage exit 64. Without
  # the `[ "$#" -gt 1 ]` guard a value-less flag would exit 1 under `set -e`.
  test "history rejects malformed arguments before an rpc" do
    for argv <- [
          "export --limit 0",
          "export --limit 501",
          "export --limit 0500x",
          "export --limit 1000",
          "export --after -1",
          "export --after 1e3",
          "export --after 12345678901",
          ~s|export --after '1]); System.halt(0); (['|,
          "export --bogus",
          "export --limit",
          "export --after",
          "",
          "list"
        ] do
      {out, code} = run_sourced_engine(@stub <> "cmd_history #{argv}", [])
      assert code == 64, "cmd_history #{argv} exited #{code}: #{out}"
      assert out =~ "aiur: history"
      refute out =~ "RPC="
    end
  end
end
