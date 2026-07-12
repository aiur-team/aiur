defmodule Aiur.GitHub.RateBudgetTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.RateBudget

  test "parses rate headers case-insensitively and rejects incomplete observations" do
    assert {:ok, %{limit: 5_000, remaining: 500, reset_at: 2_000}} =
             RateBudget.parse_headers(%{
               "X-RateLimit-Limit" => ["5000"],
               "x-ratelimit-remaining" => ["500"],
               "X-Ratelimit-Reset" => ["2000"]
             })

    assert :error = RateBudget.parse_headers(%{"x-ratelimit-remaining" => "10"})
    assert :error = RateBudget.parse_headers(%{"x-ratelimit-limit" => "bad", "x-ratelimit-remaining" => "1", "x-ratelimit-reset" => "2"})
  end

  test "protects the larger of ten percent or one hundred requests" do
    assert RateBudget.calculate_delay_ms(%{limit: 5_000, remaining: 501, reset_at: 2_000}, 1_000) == 0
    assert RateBudget.calculate_delay_ms(%{limit: 5_000, remaining: 500, reset_at: 2_000}, 1_000) == 1_001_000
    assert RateBudget.calculate_delay_ms(%{limit: 500, remaining: 100, reset_at: 2_000}, 1_000) == 1_001_000
    assert RateBudget.calculate_delay_ms(%{limit: 500, remaining: 100, reset_at: 900}, 1_000) == 0
    assert RateBudget.calculate_delay_ms(%{limit: 5_000, remaining: 0, reset_at: 9_000}, 1_000) == :timer.hours(1)
  end

  test "retains the lowest remaining count in the newest reset window" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})

    observe(name, 5_000, 400, 2_000)
    observe(name, 5_000, 450, 2_000)
    assert RateBudget.delay_ms(server: name, now_seconds: 1_000) == 1_001_000

    observe(name, 5_000, 4_000, 3_000)
    observe(name, 5_000, 0, 2_000)
    assert RateBudget.delay_ms(server: name, now_seconds: 1_000) == 0
  end

  test "expired observations clear and a missing process degrades to zero" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    observe(name, 5_000, 0, 2_000)

    assert RateBudget.delay_ms(server: name, now_seconds: 2_001) == 0
    assert RateBudget.delay_ms(server: name, now_seconds: 1_000) == 0
    assert RateBudget.delay_ms(server: Module.concat(__MODULE__, Missing)) == 0
  end

  defp observe(name, limit, remaining, reset_at) do
    RateBudget.observe_response(
      %{headers: %{"x-ratelimit-limit" => Integer.to_string(limit), "x-ratelimit-remaining" => Integer.to_string(remaining), "x-ratelimit-reset" => Integer.to_string(reset_at)}},
      name
    )

    :sys.get_state(name)
  end
end
