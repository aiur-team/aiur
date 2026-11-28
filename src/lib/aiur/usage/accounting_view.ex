defmodule Aiur.Usage.AccountingView do
  @moduledoc "Builds the per-user actual-usage view from accepted provider ledger records."

  alias Aiur.Usage.GasLedger
  alias Aiur.UsageAggregate

  @contract "aiur.usage.accounting"

  @doc "Returns provider-reported usage for one opaque host user id, grouped by provider and ticket/run."
  @spec build(String.t(), keyword()) :: map()
  def build(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    source = Keyword.get_lazy(opts, :usage_source, &UsageAggregate.cells_snapshot/0)
    cells = Map.get(source, :cells, %{})
    meter_views = Keyword.get_lazy(opts, :meter_views, &Aiur.ProviderMeterProjection.snapshot/0)

    selected = Enum.filter(cells, fn {{dims, _measure}, _value} -> dims.user_id == user_id end)
    metadata = Map.get(source, :metadata, %{})
    usage_available? = Map.get(metadata, :health) == :healthy

    %{
      contract: @contract,
      contract_version: 1,
      observed_at: DateTime.to_iso8601(DateTime.truncate(now, :second)),
      user_id: user_id,
      icons: provider_icons(),
      minerals: %{
        basis: "provider_reported",
        status: if(usage_available?, do: "actual", else: "unavailable"),
        providers: providers(selected),
        allocation_periods: allocation_periods(meter_views, now),
        coverage: safe_map_get(metadata, :source_coverage, %{})
      },
      gas: gas(user_id, opts),
      coverage: metadata
    }
  rescue
    _error -> unavailable(user_id, Keyword.get(opts, :now, DateTime.utc_now()))
  catch
    :exit, _reason -> unavailable(user_id, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  defp providers(selected) do
    selected
    |> Enum.group_by(fn {{dims, _measure}, _value} -> dims.provider end)
    |> Map.new(fn {provider, cells} -> {provider, provider_usage(cells)} end)
  end

  defp provider_icons do
    Aiur.CodingAgent.provider_descriptors()
    |> Map.new(fn descriptor ->
      {descriptor.provider, %{logo: descriptor.logo, token: descriptor.token_icon}}
    end)
  end

  defp gas(user_id, opts) do
    ledger_server = Keyword.get(opts, :gas_ledger_server, GasLedger)
    source = Keyword.get_lazy(opts, :gas_source, fn -> GasLedger.snapshot(user_id, ledger_server) end)
    budget = gas_budget()
    remaining = if is_struct(budget, Decimal), do: Decimal.max(Decimal.sub(budget, source.spent_usd), Decimal.new(0))

    %{
      budget_usd: decimal_string(budget),
      spent_usd: decimal_string(source.spent_usd),
      remaining_usd: decimal_string(remaining),
      records: source.records |> Enum.group_by(& &1.api) |> Map.new(fn {api, rows} -> {api, Enum.map(rows, &gas_record/1)} end),
      status: if(budget, do: "available", else: "budget_unconfigured")
    }
  rescue
    _error -> %{budget_usd: decimal_string(gas_budget()), spent_usd: nil, remaining_usd: nil, records: %{}, status: "unavailable"}
  catch
    :exit, _reason -> %{budget_usd: decimal_string(gas_budget()), spent_usd: nil, remaining_usd: nil, records: %{}, status: "unavailable"}
  end

  defp gas_budget do
    case System.get_env("AIUR_GAS_BUDGET_USD") do
      value when is_binary(value) ->
        case Decimal.parse(value) do
          {%Decimal{} = budget, ""} -> nonnegative_budget(budget)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp nonnegative_budget(budget), do: if(Decimal.negative?(budget), do: nil, else: budget)

  defp allocation_periods(meter_views, now) do
    Map.new(meter_views, fn {provider, view} ->
      windows = Map.get(view, :windows, %{})

      periods =
        Map.new(windows, fn {name, window} ->
          reset = Map.get(window, :resets_at) || Map.get(window, :reset_at)

          {to_string(name),
           %{
             used_percent: Map.get(window, :used_percent),
             resets_at: iso(reset),
             observed_at: iso(Map.get(view, :observed_at)),
             age_ms: age_ms(Map.get(view, :observed_at), now),
             freshness: to_string(Map.get(view, :freshness, :unknown))
           }}
        end)

      {provider, periods}
    end)
  end

  defp provider_usage(cells) do
    %{tokens: tokens, money: money, by_ticket: by_ticket, by_run: by_run} = totals(cells)
    %{tokens: tokens, money_estimate: money, by_ticket: by_ticket, by_run: by_run}
  end

  defp totals(cells) do
    Enum.reduce(cells, %{tokens: %{}, money: %{}, by_ticket: %{}, by_run: %{}}, fn {{dims, measure}, value}, acc ->
      acc = add(acc, measure, value)
      acc = add_group(acc, :by_ticket, dims.ticket, measure, value)
      add_group(acc, :by_run, dims.run_id, measure, value)
    end)
  end

  defp add(acc, {:token, dimension}, value), do: update_in(acc, [:tokens], &Map.update(&1, Atom.to_string(dimension), value, fn total -> total + value end))
  defp add(acc, {:money, basis, currency}, value), do: update_in(acc, [:money], &Map.update(&1, "#{basis}:#{currency}", value, fn total -> Decimal.add(total, value) end))

  defp add_group(acc, key, group, measure, value) do
    if is_nil(group) or group == :unknown do
      acc
    else
      update_in(acc, [key], fn groups ->
        Map.update(groups, group_key(group), group_measure(measure, value), &merge_measure(&1, measure, value))
      end)
    end
  end

  defp group_measure(measure, value), do: add(%{tokens: %{}, money: %{}}, measure, value)
  defp merge_measure(group, measure, value), do: add(group, measure, value)

  defp group_key({:github, owner, repository, identifier}), do: "github:#{owner}/#{repository}##{identifier}"
  defp group_key(group) when is_binary(group), do: group
  defp group_key(:unknown), do: "unknown"

  defp unavailable(user_id, now) do
    %{
      contract: @contract,
      contract_version: 1,
      observed_at: DateTime.to_iso8601(DateTime.truncate(now, :second)),
      user_id: user_id,
      minerals: %{basis: "provider_reported", status: "unavailable", providers: %{}},
      coverage: %{status: "unavailable"}
    }
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(DateTime.truncate(value, :second))
  defp iso(value) when is_binary(value), do: value
  defp iso(_value), do: nil

  defp age_ms(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :millisecond), 0)
  defp age_ms(_at, _now), do: nil

  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(_value), do: nil
  defp safe_map_get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp gas_record(record) do
    record
    |> Map.take([:amount_usd, :occurred_at, :basis, :ticket, :conversation_id])
    |> Map.update!(:amount_usd, &Decimal.to_string(&1, :normal))
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
  end
end
