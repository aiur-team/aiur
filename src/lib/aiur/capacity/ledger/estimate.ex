defmodule Aiur.Capacity.Ledger.Estimate do
  @moduledoc """
  Hold estimates and period spend for `Aiur.Capacity.Ledger`. Each returns
  `:unknown` rather than invent a figure it has no basis for.
  """

  @doc """
  `:window` estimate in percent: burn per agent-hour times expected hours.
  Burn is the learned rate, else the configured default, else unknown.
  Returns `{estimate, rate}`.
  """
  @spec window_estimate(number() | nil, number() | nil, number()) :: {number() | :unknown, number() | :unknown}
  def window_estimate(learned, default, expected_hours) do
    case learned || default do
      nil -> {:unknown, :unknown}
      rate -> {rate * expected_hours, rate}
    end
  end

  @doc """
  `:usd` estimate: median USD per turn for the backend and complexity, else the
  `max_output_tokens` cost bound, else unknown.
  """
  @spec usd_estimate([number()], number() | nil) :: number() | :unknown
  def usd_estimate([], nil), do: :unknown
  def usd_estimate([], bound), do: bound

  def usd_estimate(costs, _bound) do
    sorted = Enum.sort(costs)
    n = length(sorted)
    mid = div(n, 2)
    if rem(n, 2) == 1, do: Enum.at(sorted, mid), else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  @doc """
  Period spend in USD from a usage aggregate's API-equivalent estimate (the
  figure the spend cap uses). Partial or unknown pricing coverage is unknown;
  no records at all is zero, unless the aggregate itself is unavailable.
  """
  @spec period_spend(map()) :: float() | :unknown
  def period_spend(%{state: :unavailable}), do: :unknown

  def period_spend(%{api_equivalent_estimate: %{rollup: rollup, coverage: coverage}}) do
    case {Map.get(coverage, :status), Map.get(rollup, "USD")} do
      {:none, _usd} -> 0.0
      {:known, %Decimal{} = usd} -> Decimal.to_float(usd)
      _partial_or_unknown -> :unknown
    end
  end

  def period_spend(_usage), do: :unknown
end
