defmodule Aiur.Usage.GroupedScopes.Projection do
  @moduledoc "Token and money entries, totals and contributor buckets for `Aiur.Usage.GroupedScopes`."

  alias Aiur.Usage.GroupedScopes.PriceAdapter

  @dims_dimensions %{
    by_provider: :provider,
    by_run: :run_id,
    by_ticket: :ticket,
    by_agent_family: :agent_family,
    by_backend: :backend,
    by_upstream_provider: :upstream_provider,
    by_model: :resolved_model,
    by_auth_mode: :auth_mode,
    by_account_generation: :account_generation,
    by_relationship_revision: :relationship_revision,
    by_pricing_date: :pricing_date
  }

  @doc false
  @spec token_entries(list(), String.t(), map(), map()) :: [map()]
  # Pricing a subset parent on its remainder needs the sibling token counts of
  # its aggregate group, so the raw cell counts are grouped by identity
  # dimensions once and threaded into each entry's pricing. The `count` stays
  # the raw observed count everywhere except that remainder-aware pricing.
  def token_entries(selected, currency, price_table, relationships) do
    siblings = sibling_counts(selected)

    for {{dims, {:token, dimension}}, count} <- selected do
      priced = price(dims, dimension, Map.fetch!(siblings, dims), relationships, currency, price_table)
      %{dims: dims, dimension: dimension, count: count, priced: priced}
    end
  end

  defp sibling_counts(selected) do
    Enum.reduce(selected, %{}, fn
      {{dims, {:token, dimension}}, count}, acc ->
        Map.update(acc, dims, %{dimension => count}, &Map.put(&1, dimension, count))

      _money_cell, acc ->
        acc
    end)
  end

  defp price(dims, dimension, group, relationships, currency, price_table) do
    if PriceAdapter.priced_dimension?(dimension) do
      PriceAdapter.price(dims, dimension, group, relationships, currency, price_table)
    else
      :excluded
    end
  end

  @doc false
  @spec money_entries(list()) :: [map()]
  # DASH-024 folds only the provider-reported basis, so a money cell's basis is
  # constant and need not be carried per entry.
  def money_entries(selected) do
    for {{dims, {:money, _basis, currency}}, amount} <- selected do
      %{dims: dims, currency: currency, amount: amount}
    end
  end

  # --- totals & buckets ---------------------------------------------------

  defp empty_acc do
    %{tokens: %{}, provider_reported: %{}, api_amount: %{}, api_known: 0, api_unknown: 0, api_reasons: MapSet.new()}
  end

  @doc false
  @spec totals([map()], [map()]) :: map()
  def totals(token_entries, money_entries) do
    empty_acc()
    |> then(fn acc -> Enum.reduce(token_entries, acc, &add_token(&2, &1)) end)
    |> then(fn acc -> Enum.reduce(money_entries, acc, &add_money(&2, &1)) end)
    |> finalize()
  end

  defp add_token(acc, %{dimension: dimension, count: count, priced: priced}) do
    acc = update_in(acc.tokens, &Map.update(&1, dimension, count, fn v -> v + count end))
    apply_price(acc, priced)
  end

  defp apply_price(acc, {:ok, %{amount: amount, currency: currency}}) do
    acc
    |> update_in([:api_amount], &Map.update(&1, currency, amount, fn v -> Decimal.add(v, amount) end))
    |> Map.update!(:api_known, &(&1 + 1))
  end

  defp apply_price(acc, {:unknown, reason}) do
    acc
    |> Map.update!(:api_unknown, &(&1 + 1))
    |> Map.update!(:api_reasons, &MapSet.put(&1, reason))
  end

  defp apply_price(acc, :excluded), do: acc

  defp add_money(acc, %{currency: currency, amount: amount}) do
    update_in(acc.provider_reported, &Map.update(&1, currency, amount, fn v -> Decimal.add(v, amount) end))
  end

  defp finalize(acc) do
    %{
      tokens: acc.tokens,
      provider_reported: acc.provider_reported,
      api_amount: acc.api_amount,
      api_coverage: %{
        known: acc.api_known,
        unknown: acc.api_unknown,
        reasons: acc.api_reasons |> MapSet.to_list() |> Enum.sort(),
        status: coverage_status(acc.api_known, acc.api_unknown)
      }
    }
  end

  defp coverage_status(0, 0), do: :none
  defp coverage_status(_known, 0), do: :known
  defp coverage_status(0, _unknown), do: :unknown
  defp coverage_status(_known, _unknown), do: :partial

  # --- contributors -------------------------------------------------------

  @doc false
  @spec contributors([map()], [map()], map()) :: map()
  def contributors(token_entries, money_entries, totals) do
    dims_buckets =
      Map.new(@dims_dimensions, fn {label, dimension} ->
        {label, bucket(token_entries, money_entries, &Map.fetch!(&1.dims, dimension), &Map.fetch!(&1.dims, dimension))}
      end)

    dims_buckets
    |> Map.put(:by_provider_route, bucket(token_entries, money_entries, &provider_route/1, &provider_route/1))
    |> Map.put(:by_price_partition, bucket(token_entries, [], &price_partition/1, &skip/1))
    |> Map.put(:by_currency, by_currency(money_entries, totals.api_amount))
  end

  defp provider_route(%{dims: dims}) do
    %{provider: dims.provider, upstream_provider: dims.upstream_provider}
  end

  defp price_partition(%{priced: {:ok, %{price_revision: revision}}}), do: revision
  defp price_partition(%{priced: {:unknown, _reason}}), do: :unknown
  defp price_partition(%{priced: :excluded}), do: :skip

  defp skip(_entry), do: :skip

  # Monetary-only view: provider-reported money keyed by its own currency, plus
  # the known API-equivalent amounts keyed by their (requested) currency. Token
  # counts are not a per-currency measure and never enter this dimension.
  defp by_currency(money_entries, api_amount) do
    money_entries
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.update(acc, entry.currency, add_money(empty_acc(), entry), &add_money(&1, entry))
    end)
    |> then(&Enum.reduce(api_amount, &1, fn {currency, amount}, acc -> merge_api_amount(acc, currency, amount) end))
    |> Enum.map(fn {key, acc} -> present(key, finalize(acc)) end)
    |> Enum.sort_by(&sort_key(&1.key))
  end

  defp merge_api_amount(acc, currency, amount) do
    Map.update(acc, currency, %{empty_acc() | api_amount: %{currency => amount}}, fn bucket ->
      %{bucket | api_amount: Map.update(bucket.api_amount, currency, amount, &Decimal.add(&1, amount))}
    end)
  end

  defp bucket(token_entries, money_entries, token_key, money_key) do
    %{}
    |> then(fn acc -> Enum.reduce(token_entries, acc, &accumulate(&2, token_key.(&1), :token, &1)) end)
    |> then(fn acc -> Enum.reduce(money_entries, acc, &accumulate(&2, money_key.(&1), :money, &1)) end)
    |> Enum.map(fn {key, acc} -> present(key, finalize(acc)) end)
    |> Enum.sort_by(&sort_key(&1.key))
  end

  defp present(key, finalized) do
    %{
      key: key,
      tokens: finalized.tokens,
      provider_reported: finalized.provider_reported,
      api_equivalent: %{amount: finalized.api_amount, coverage: finalized.api_coverage}
    }
  end

  defp accumulate(acc, :skip, _kind, _entry), do: acc

  defp accumulate(acc, key, :token, entry) do
    Map.update(acc, key, add_token(empty_acc(), entry), &add_token(&1, entry))
  end

  defp accumulate(acc, key, :money, entry) do
    Map.update(acc, key, add_money(empty_acc(), entry), &add_money(&1, entry))
  end

  # Canonical, restart-stable ordering across the mixed key types a dimension
  # can carry (atoms, strings, tuples, dates, nil).
  defp sort_key(key), do: :erlang.term_to_binary(key)

  # --- tier join keys -----------------------------------------------------

  @doc false
  @spec tier_join_keys(list()) :: [map()]
  def tier_join_keys(selected) do
    selected
    |> Enum.map(fn {{dims, _measure}, _value} -> dims end)
    |> Enum.filter(&exact_tier_group?/1)
    |> Enum.map(&%{provider: &1.provider, backend: &1.backend, account_generation: &1.account_generation})
    |> Enum.uniq()
    |> Enum.sort_by(&sort_key({&1.provider, &1.backend, &1.account_generation}))
  end

  defp exact_tier_group?(%{backend: :unknown}), do: false
  defp exact_tier_group?(%{account_generation: nil}), do: false
  defp exact_tier_group?(_dims), do: true

  @doc false
  @spec empty_contributors() :: map()
  def empty_contributors do
    labels = Map.keys(@dims_dimensions) ++ [:by_provider_route, :by_price_partition, :by_currency]
    Map.new(labels, fn label -> {label, []} end)
  end
end
