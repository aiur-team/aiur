defmodule Aiur.OpenAICompat.MeterWindows do
  @moduledoc false

  @deepseek_concurrency_limit 2_500

  @spec deepseek_concurrency(non_neg_integer(), DateTime.t()) :: map()
  def deepseek_concurrency(in_flight, %DateTime{} = observed_at)
      when is_integer(in_flight) and in_flight >= 0 do
    %{
      limit_id: "local-concurrency",
      kind: :rate_limit,
      name: :concurrency,
      used_percent: in_flight / @deepseek_concurrency_limit * 100,
      used: in_flight,
      limit: @deepseek_concurrency_limit,
      remaining: max(@deepseek_concurrency_limit - in_flight, 0),
      source: :deepseek_api,
      observed_at: observed_at,
      expires_at: DateTime.add(observed_at, 60, :second),
      coverage: :supported
    }
  end
end
