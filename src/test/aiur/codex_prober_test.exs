defmodule Aiur.CodexProberTest do
  use ExUnit.Case, async: true

  alias Aiur.CodexProber

  test "normalizes rate windows nested in the rateLimits response" do
    response = %{
      "rateLimits" => %{
        "primary" => %{"usedPercent" => 4, "windowDurationMins" => 10_080, "resetsAt" => 1_800_000_000},
        "secondary" => %{"usedPercent" => 12, "windowDurationMins" => 60, "resetsAt" => 1_800_000_100},
        "email" => "private@example.test"
      },
      "rateLimitReachedType" => nil
    }

    assert {:ok,
            %{
              "primary" => %{"usedPercent" => 4, "windowDurationMins" => 10_080, "resetsAt" => 1_800_000_000},
              "secondary" => %{"usedPercent" => 12, "windowDurationMins" => 60, "resetsAt" => 1_800_000_100}
            }} = CodexProber.normalize_codex_limits(response)
  end

  test "rejects a response without rate limit windows" do
    assert {:error, :no_usage_data} = CodexProber.normalize_codex_limits(%{"rateLimits" => %{}})
  end
end
