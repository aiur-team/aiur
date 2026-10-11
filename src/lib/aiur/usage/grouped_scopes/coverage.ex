defmodule Aiur.Usage.GroupedScopes.Coverage do
  @moduledoc "Reconciliation, coverage and snapshot state for `Aiur.Usage.GroupedScopes`."

  # --- reconciliation -----------------------------------------------------

  # Each dimension reconciles exactly the measures it structurally carries: the
  # identity dimensions carry all three, `by_price_partition` carries only the
  # API-equivalent money (it excludes provider-reported money and the
  # unpriced provider-reported-total token), and `by_currency` carries only the
  # monetary bases (token counts are not a per-currency measure).
  @reconciliation_measures %{
    by_price_partition: [:api],
    by_currency: [:provider_reported, :api]
  }

  @doc false
  @spec reconciliation(map(), map()) :: map()
  def reconciliation(totals, contributors) do
    by_dimension =
      Map.new(contributors, fn {label, entries} ->
        {label, reconciles?(totals, entries, Map.get(@reconciliation_measures, label, [:tokens, :provider_reported, :api]))}
      end)

    %{reconciled?: Enum.all?(by_dimension, fn {_label, ok?} -> ok? end), by_dimension: by_dimension}
  end

  defp reconciles?(totals, entries, measures) do
    summed = Enum.reduce(entries, %{tokens: %{}, provider_reported: %{}, api_amount: %{}}, &sum_entry/2)

    Enum.all?(measures, fn
      :tokens -> summed.tokens == totals.tokens
      :provider_reported -> normalize_money(summed.provider_reported) == normalize_money(totals.provider_reported)
      :api -> normalize_money(summed.api_amount) == normalize_money(totals.api_amount)
    end)
  end

  defp sum_entry(entry, summed) do
    %{
      tokens: Map.merge(summed.tokens, entry.tokens, fn _dimension, a, b -> a + b end),
      provider_reported: merge_money(summed.provider_reported, entry.provider_reported),
      api_amount: merge_money(summed.api_amount, entry.api_equivalent.amount)
    }
  end

  defp merge_money(left, right), do: Map.merge(left, right, fn _currency, a, b -> Decimal.add(a, b) end)

  defp normalize_money(money), do: Map.new(money, fn {key, amount} -> {key, Decimal.to_string(amount, :normal)} end)

  # --- coverage & state ---------------------------------------------------

  @doc false
  @spec coverage(list(), [map()], map(), map()) :: map()
  def coverage(selected, token_entries, metadata, totals) do
    %{
      selected_cells: length(selected),
      api_equivalent: totals.api_coverage,
      unknown_attribution: unknown_attribution(selected),
      unknown_pricing_tokens: unknown_pricing_tokens(token_entries),
      projection: projection_coverage(metadata),
      source: Map.get(metadata, :source_coverage, %{})
    }
  end

  defp unknown_attribution(selected) do
    Enum.reduce(selected, %{run_id: 0, ticket: 0, account_generation: 0, upstream_provider: 0, resolved_model: 0, pricing_date: 0}, fn
      {{dims, _measure}, _value}, acc ->
        acc
        |> bump(:run_id, is_nil(dims.run_id))
        |> bump(:ticket, dims.ticket == :unknown)
        |> bump(:account_generation, is_nil(dims.account_generation))
        |> bump(:upstream_provider, dims.provider == :openrouter and is_nil(dims.upstream_provider))
        |> bump(:resolved_model, is_nil(dims.resolved_model))
        |> bump(:pricing_date, is_nil(dims.pricing_date))
    end)
  end

  defp unknown_pricing_tokens(token_entries) do
    token_entries
    |> Enum.filter(&match?({:unknown, _reason}, &1.priced))
    |> Enum.reduce(%{}, fn %{priced: {:unknown, reason}, count: count}, acc ->
      Map.update(acc, reason, count, &(&1 + count))
    end)
  end

  defp projection_coverage(metadata) do
    coverage = Map.get(metadata, :coverage, %{})

    %{
      folded_records: Map.get(coverage, :folded_records, 0),
      partial_records: Map.get(coverage, :partial_records, 0),
      reasons: coverage |> Map.get(:reasons, []) |> normalize_reasons()
    }
  end

  defp normalize_reasons(%MapSet{} = reasons), do: reasons |> MapSet.to_list() |> Enum.sort()
  defp normalize_reasons(reasons) when is_list(reasons), do: Enum.sort(reasons)
  defp normalize_reasons(_reasons), do: []

  defp bump(acc, key, true), do: Map.update!(acc, key, &(&1 + 1))
  defp bump(acc, _key, false), do: acc

  @doc false
  @spec retained_interval(map()) :: map()
  def retained_interval(metadata) do
    case Map.get(metadata, :source_coverage) do
      %{lower: lower, upper: upper} = coverage ->
        %{earliest: lower, latest: upper, status: Map.get(coverage, :status, :unknown)}

      _missing ->
        %{earliest: nil, latest: nil, status: :missing}
    end
  end

  @doc false
  @spec state(map(), list(), map()) :: atom()
  def state(metadata, selected, coverage) do
    cond do
      match?({:unavailable, _reason}, Map.get(metadata, :health)) -> :unavailable
      Map.get(metadata, :freshness, %{})[:status] == :unavailable -> :unavailable
      match?({:degraded, _reason}, Map.get(metadata, :health)) -> :partial
      Map.get(metadata, :freshness, %{})[:status] == :stale -> :stale
      selected == [] -> :known_empty
      partial_coverage?(coverage) -> :partial
      true -> :ok
    end
  end

  defp partial_coverage?(coverage) do
    coverage.api_equivalent.status in [:partial, :unknown] or
      coverage.projection.partial_records > 0 or
      Enum.any?(Map.values(coverage.unknown_attribution), &(&1 > 0)) or
      Map.get(coverage.source, :status, :full) != :full
  end

  @doc false
  @spec empty_coverage() :: map()
  # Keep the same coverage shape across every state so a consumer can read the
  # sub-tree without first branching on `:state`.
  def empty_coverage do
    %{
      selected_cells: 0,
      api_equivalent: %{known: 0, unknown: 0, reasons: [], status: :none},
      unknown_attribution: %{run_id: 0, ticket: 0, account_generation: 0, upstream_provider: 0, resolved_model: 0, pricing_date: 0},
      unknown_pricing_tokens: %{},
      projection: %{folded_records: 0, partial_records: 0, reasons: []},
      source: %{}
    }
  end
end
