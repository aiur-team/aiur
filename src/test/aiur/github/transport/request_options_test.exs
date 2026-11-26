defmodule Aiur.GitHub.Transport.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Transport.RequestOptions

  # Req starts a Finch pool per distinct pool name and never stops it; a name that varies
  # with the per-request deadline grew the daemon by a pool per request (#7796).
  test "requests with different deadlines share one Finch pool" do
    pools =
      for timeout_ms <- [235, 1_380, 4_211, 30_000] do
        [] |> RequestOptions.options(%{timeout_ms: timeout_ms}) |> Req.Finch.pool_options() |> Req.Finch.pool_name()
      end

    assert [_one] = Enum.uniq(pools)
  end

  test "future regression: the per-request deadline still bounds the read" do
    assert RequestOptions.options([], %{timeout_ms: 1_380})[:receive_timeout] == 1_380
  end
end
