defmodule Aiur.UsageAggregate.Query do
  @moduledoc false

  # Bounded exact query over the cached projection. Work is proportional to the
  # number of retained cells, never to ledger size or browser count, and never
  # scans raw files. Scope is an explicit set of repository-qualified typed
  # tickets and/or opaque run identifiers; a bare issue number can never be a
  # scope key. Group sums reconcile exactly to their matching total, and two
  # token-relationship revisions with otherwise identical dimensions stay in
  # separate groups because the revision is part of every cell's identity.

  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate.Key

  @group_dimensions %{
    by_provider: :provider,
    by_run: :run_id,
    by_ticket: :ticket,
    by_agent_family: :agent_family,
    by_backend: :backend,
    by_model: :resolved_model,
    by_auth_mode: :auth_mode,
    by_account_generation: :account_generation,
    by_relationship_revision: :relationship_revision,
    by_pricing_date: :pricing_date
  }

  @spec summary(map(), map()) :: map()
  def summary(state, scope) when is_map(scope) do
    normalized = normalize_scope(scope)
    selected = select(state.projection.cells, normalized)
    totals = totals(selected)
    groups = groups(selected)

    %{
      scope: public_scope(normalized),
      aggregate_generation: state.projection.generation,
      source_position: state.projection.source_position,
      source_generation: state.projection.source_generation,
      health: state.health,
      freshness: state.freshness,
      coverage: coverage(selected, state),
      totals: totals,
      groups: Map.put(groups, :by_currency, by_currency(selected)),
      reconciliation: reconciliation(totals, groups)
    }
  end

  # --- scope --------------------------------------------------------------

  defp normalize_scope(scope) do
    runs = scope |> Map.get(:runs, []) |> Enum.filter(&is_binary/1) |> MapSet.new()
    {tickets, rejected} = normalize_tickets(Map.get(scope, :tickets, []))
    %{runs: runs, tickets: tickets, rejected_tickets: rejected}
  end

  defp normalize_tickets(tickets) when is_list(tickets) do
    Enum.reduce(tickets, {MapSet.new(), 0}, fn ticket, {keys, rejected} ->
      case ticket_key(ticket) do
        {:ok, key} -> {MapSet.put(keys, key), rejected}
        :error -> {keys, rejected + 1}
      end
    end)
  end

  defp normalize_tickets(_tickets), do: {MapSet.new(), 0}

  defp ticket_key(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp ticket_key(_ticket), do: :error

  defp public_scope(normalized) do
    status = if MapSet.size(normalized.runs) == 0 and MapSet.size(normalized.tickets) == 0, do: :empty, else: :scoped

    %{
      runs: normalized.runs |> MapSet.to_list() |> Enum.sort(),
      tickets: normalized.tickets |> MapSet.to_list() |> Enum.sort(),
      rejected_tickets: normalized.rejected_tickets,
      status: status
    }
  end

  defp select(cells, %{runs: runs, tickets: tickets}) do
    Enum.filter(cells, fn {{dims, _measure}, _value} ->
      (MapSet.size(runs) > 0 and MapSet.member?(runs, dims.run_id)) or
        (MapSet.size(tickets) > 0 and MapSet.member?(tickets, dims.ticket))
    end)
  end

  # --- aggregation --------------------------------------------------------

  defp totals(selected) do
    Enum.reduce(selected, empty_measures(), fn {{_dims, measure}, value}, acc ->
      add_measure(acc, measure, value)
    end)
  end

  defp groups(selected) do
    Map.new(@group_dimensions, fn {label, dimension} -> {label, group_by(selected, dimension)} end)
  end

  defp group_by(selected, dimension) do
    Enum.reduce(selected, %{}, fn {{dims, measure}, value}, acc ->
      group = Key.group_value(dims, dimension)
      Map.update(acc, group, add_measure(empty_measures(), measure, value), &add_measure(&1, measure, value))
    end)
  end

  defp by_currency(selected) do
    selected
    |> Enum.filter(fn {{_dims, measure}, _value} -> match?({:money, _basis, _currency}, measure) end)
    |> Enum.reduce(%{}, fn {{_dims, {:money, _basis, currency} = measure}, value}, acc ->
      Map.update(acc, currency, add_measure(empty_measures(), measure, value), &add_measure(&1, measure, value))
    end)
  end

  defp empty_measures, do: %{tokens: %{}, money: %{}}

  defp add_measure(%{tokens: tokens} = measures, {:token, dimension}, value) do
    %{measures | tokens: Map.update(tokens, dimension, value, &(&1 + value))}
  end

  defp add_measure(%{money: money} = measures, {:money, basis, currency}, value) do
    %{measures | money: Map.update(money, {basis, currency}, value, &Decimal.add(&1, value))}
  end

  # --- reconciliation -----------------------------------------------------

  defp reconciliation(totals, groups) do
    by_dimension = Map.new(groups, fn {label, grouped} -> {label, recombine(grouped) == normalize_measures(totals)} end)
    %{reconciled?: Enum.all?(by_dimension, fn {_label, ok?} -> ok? end), by_dimension: by_dimension}
  end

  defp recombine(grouped) do
    grouped
    |> Enum.reduce(empty_measures(), fn {_group, measures}, acc -> merge_measures(acc, measures) end)
    |> normalize_measures()
  end

  defp merge_measures(left, right) do
    tokens = Map.merge(left.tokens, right.tokens, fn _dimension, a, b -> a + b end)
    money = Map.merge(left.money, right.money, fn _key, a, b -> Decimal.add(a, b) end)
    %{tokens: tokens, money: money}
  end

  # Money sums are compared by exact value, not Decimal struct representation,
  # so `1.0` and `1.00` reconcile while remaining exact.
  defp normalize_measures(measures) do
    %{tokens: measures.tokens, money: Map.new(measures.money, fn {key, amount} -> {key, Decimal.to_string(amount, :normal)} end)}
  end

  # --- coverage -----------------------------------------------------------

  defp coverage(selected, state) do
    %{
      selected_cells: length(selected),
      unknown_attribution: unknown_attribution(selected),
      projection: %{
        folded_records: state.projection.coverage.folded_records,
        partial_records: state.projection.coverage.partial_records,
        reasons: state.projection.coverage.reasons |> MapSet.to_list() |> Enum.sort()
      },
      source: state.source_coverage
    }
  end

  defp unknown_attribution(selected) do
    Enum.reduce(selected, %{run_id: 0, ticket: 0, account_generation: 0, resolved_model: 0, pricing_date: 0}, fn
      {{dims, _measure}, _value}, acc ->
        acc
        |> bump(:run_id, is_nil(dims.run_id))
        |> bump(:ticket, dims.ticket == :unknown)
        |> bump(:account_generation, is_nil(dims.account_generation))
        |> bump(:resolved_model, is_nil(dims.resolved_model))
        |> bump(:pricing_date, is_nil(dims.pricing_date))
    end)
  end

  defp bump(acc, key, true), do: Map.update!(acc, key, &(&1 + 1))
  defp bump(acc, _key, false), do: acc
end
