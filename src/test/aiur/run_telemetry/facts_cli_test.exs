defmodule Aiur.RunTelemetry.FactsCLITest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.FactsCLI

  test "uses the canonical fetch boundary and reports disabled capture without requesting" do
    fetch = fn ticket, opts ->
      assert ticket == "42"
      assert opts == [repo: "owner/repo"]
      {:ok, %{pr_created_at: "2026-10-09T10:00:00Z"}}
    end

    assert %{facts: %{pr_created_at: "2026-10-09T10:00:00Z"}} = FactsCLI.fetch("42", repo: "owner/repo", enabled: fn -> true end, fetch: fetch)
    assert %{error: "disabled"} = FactsCLI.fetch("42", enabled: fn -> false end, fetch: fn _, _ -> flunk("disabled capture fetched") end)
    assert %{error: "facts_unavailable"} = FactsCLI.fetch("42", enabled: fn -> true end, fetch: fn _, _ -> {:error, {:budget_hold, "secret"}} end)
  end
end
