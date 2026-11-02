defmodule Aiur.AgentControlCLIRedispatchTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentControlCLI.Redispatch

  test "redispatch output identifies each ticket and gives a queue command when it is not running" do
    assert Redispatch.format_result("repo#17", {:ok, :redispatched}) ==
             "aiur: redispatch started for ticket repo#17"

    assert Redispatch.format_result("repo#18", {:error, :not_running}) ==
             "aiur: ticket repo#18 is not running; use `aiur --todo repo#18` to queue it"

    assert Redispatch.format_result("repo#19", {:error, :workspace_unavailable}) ==
             "aiur: redispatch failed for ticket repo#19 (:workspace_unavailable)"
  end
end
