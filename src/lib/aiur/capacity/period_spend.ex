defmodule Aiur.Capacity.PeriodSpend do
  @moduledoc """
  USD spent per UTC day, week and month, per source and over every metered and
  prepaid source together (#7958): the `:spend` input of `Aiur.Capacity.Policy`.

  Read from the usage aggregate's API-equivalent estimate, by provider family
  and pricing date. Partial pricing coverage, or an unavailable aggregate, is
  `:unknown` (`Aiur.Capacity.Ledger.Estimate.period_spend/1`), which holds a
  source with a limit. Weeks start on Monday.

  Only sources with a `limits` block are measured, plus `:global` when the
  machine-wide `limits` are set; with no limit anywhere `spend/2` reads nothing.
  """

  alias Aiur.Capacity.Ledger
  alias Aiur.CodingAgent
  alias Aiur.Usage.{GroupedScopes, PriceTable}
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.UsageAggregate

  @periods [:daily_usd, :weekly_usd, :monthly_usd]
  @billed ["metered", "prepaid"]

  @doc """
  `%{backend => %{daily_usd:, weekly_usd:, monthly_usd:}, global: ...}`.

  Options: `:usage_source` (an aggregate `%{cells:, metadata:}`, default
  `Aiur.UsageAggregate.cells_snapshot/0`) and `:today` (a UTC `Date`).
  """
  @spec spend(map(), keyword()) :: map()
  def spend(policy, opts \\ []) do
    sources = Map.get(policy, :sources) || %{}
    limited = for {backend, source} <- sources, limited?(Map.get(source || %{}, :limits)), do: backend
    global? = limited?(Map.get(policy, :limits))

    if limited == [] and not global? do
      %{}
    else
      today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
      read = reader(Keyword.get_lazy(opts, :usage_source, &usage_source/0), today)
      by_source = Map.new(limited, &{&1, read.([family(&1)])})
      billed = for {backend, source} <- sources, billed?(source), do: family(backend)
      if global?, do: Map.put(by_source, :global, read.(billed)), else: by_source
    end
  end

  @doc """
  Whether `backend` is past a hard USD limit, its own or (for a metered or
  prepaid source) the machine-wide one, so a running agent there starts no new
  turn. Unknown spend under a limit stops too.
  """
  @spec stop_new_turns?(String.t(), map(), map()) :: boolean()
  def stop_new_turns?(backend, policy, spend) do
    source = Map.get(Map.get(policy, :sources) || %{}, backend) || %{}
    checks = [{Map.get(source, :limits), Map.get(spend, backend)}]
    checks = if billed?(source), do: [{Map.get(policy, :limits), Map.get(spend, :global)} | checks], else: checks

    Enum.any?(checks, fn {limits, spent} ->
      Enum.any?(@periods, &Ledger.stop_new_turns?(figure(spent, &1), figure(limits, &1, nil)))
    end)
  end

  @doc """
  The ticket's API-equivalent USD so far, or `:unknown`. Options as `spend/2`.
  """
  @spec ticket_usd(Aiur.TrackerIdentity.t() | nil, keyword()) :: float() | :unknown
  def ticket_usd(%Aiur.TrackerIdentity{} = identity, opts) do
    {:ok, scope} = Scope.explicit_ticket_set([identity])
    opts |> Keyword.get_lazy(:usage_source, &usage_source/0) |> GroupedScopes.project(scope, currency: "USD") |> Ledger.period_spend()
  end

  def ticket_usd(_identity, _opts), do: :unknown

  @doc "Whether `backend` is a metered or prepaid source in `policy`."
  @spec billed?(map(), String.t()) :: boolean()
  def billed?(policy, backend), do: billed?(Map.get(Map.get(policy, :sources) || %{}, backend))

  defp billed?(source), do: is_map(source) and to_string(Map.get(source, :billing)) in @billed

  defp limited?(limits), do: is_map(limits) and Enum.any?(@periods, &is_number(Map.get(limits, &1)))

  defp figure(map, period, default \\ :unknown)

  defp figure(map, period, default) when is_map(map) do
    value = Map.get(map, period)
    if is_number(value), do: value, else: default
  end

  defp figure(_map, _period, default), do: default

  # One price table for every period: a projection rebuilds it otherwise.
  defp reader(source, today) do
    price_opts =
      case PriceTable.default() do
        {:ok, table} -> [price_table: table]
        _error -> []
      end

    starts = [daily_usd: today, weekly_usd: Date.beginning_of_week(today), monthly_usd: Date.beginning_of_month(today)]

    fn providers ->
      Map.new(starts, fn {period, since} ->
        {:ok, scope} = Scope.period(providers, since)
        {period, source |> GroupedScopes.project(scope, [currency: "USD"] ++ price_opts) |> Ledger.period_spend()}
      end)
    end
  end

  defp family(backend), do: CodingAgent.family_for(backend) || backend

  defp usage_source do
    UsageAggregate.cells_snapshot()
  catch
    :exit, _reason -> nil
  end
end
