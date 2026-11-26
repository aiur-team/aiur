defmodule AiurPushRelay.RateLimitTest do
  use ExUnit.Case, async: true
  alias AiurPushRelay.RateLimit

  test "burst is bounded and refills at the configured hourly rate" do
    assert {:ok, 0} = RateLimit.consume(nil, nil, 1, 60, 100)
    assert {:limited, 60} = RateLimit.consume(0, 100, 1, 60, 100)
    assert {:ok, 0} = RateLimit.consume(0, 100, 1, 60, 160)
  end

  test "a backwards clock does not refill the bucket" do
    assert {:limited, 60} = RateLimit.consume(0, 100, 10, 60, 50)
  end

  test "retention above seven days is refused" do
    env = fn
      "AIUR_RELAY_LOG_RETENTION_DAYS" -> "8"
      _ -> nil
    end

    assert {:error, :retention_too_long} = AiurPushRelay.Config.abuse_limits(env)
  end
end
