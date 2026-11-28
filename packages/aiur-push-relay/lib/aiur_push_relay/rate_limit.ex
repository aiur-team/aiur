defmodule AiurPushRelay.RateLimit do
  @moduledoc "Token bucket arithmetic using relay seconds and integer retry delays."

  def consume(nil, _updated_at, capacity, _per_hour, _now), do: {:ok, capacity - 1}

  def consume(tokens, updated_at, capacity, per_hour, now) do
    available = min(capacity, tokens + max(now - updated_at, 0) * per_hour / 3_600)

    if available >= 1 do
      {:ok, available - 1}
    else
      {:limited, max(1, ceil((1 - available) * 3_600 / per_hour))}
    end
  end
end
