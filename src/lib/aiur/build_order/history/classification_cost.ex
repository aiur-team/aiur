defmodule Aiur.BuildOrder.History.ClassificationCost do
  @moduledoc """
  Read-only pilot accounting and upper-bound history classification projections.

  Token dimensions overlap and must never be summed. Missing dimensions mean
  zero or unreported usage (`:none_recorded`); missing evidence is unknown.
  Pass `:baseline_partial_records` from the dispatch read to `read_sample/2`.
  Pass `:dispatched_at` to retain the dispatch time in hourly samples;
  `github_total/2` requires it on the first sample to detect an initial gap.
  Samples and timestamps are native Elixir terms, intended for local release RPC.
  """

  alias Aiur.GitHub.Budget
  alias Aiur.{TrackerIdentity, UsageAggregate, UsageEnvelope}

  @resources [:core, :graphql, :search]
  @tolerance_ms 300_000
  @type figure :: {:known, non_neg_integer()} | :none_recorded | {:unknown, [atom()]}

  @spec read_sample(map(), keyword()) :: map()
  def read_sample(pilot, opts \\ []) do
    query = Keyword.get(opts, :query_fun, &UsageAggregate.query/1)
    {tokens, partial, model} = tokens(pilot, query, opts)

    %{
      tokens: tokens,
      partial_records: partial,
      model: model,
      github: github(pilot.actor_label, opts),
      observed_at: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      dispatched_at: Keyword.get(opts, :dispatched_at)
    }
  end

  @spec github_total([map()], pos_integer()) :: map()
  def github_total(samples, window_ms) when is_integer(window_ms) and window_ms > 0 do
    ordered = Enum.sort_by(samples, &DateTime.to_unix(&1.observed_at, :millisecond))
    {intervals, reasons} = intervals(ordered)
    gap? = Enum.any?(intervals, &(&1 >= window_ms + @tolerance_ms or &1 < 0))
    reasons = if gap?, do: [:sampling_gap | reasons], else: reasons
    overlap? = intervals |> Enum.drop(1) |> Enum.any?(&(&1 < max(window_ms - @tolerance_ms, 0)))

    totals = Map.new(@resources, fn resource -> {resource, sum(Enum.map(ordered, &Map.fetch!(&1.github, resource)), reasons)} end)
    Map.put(totals, :bound, if(overlap?, do: :upper_bound, else: :window_sum))
  end

  @spec project(map(), map()) :: {:ok, map()} | {:unknown, [atom()]}
  def project(sample, %{population: population, sample_size: size, ceilings_per_hour: ceilings} = inputs)
      when is_integer(population) and population >= 0 and is_integer(size) and size > 0 do
    if Enum.all?(ceilings, &(is_integer(&1) and &1 > 0)) do
      project_valid(sample, inputs)
    else
      {:unknown, [:invalid_ceiling]}
    end
  end

  def project(_sample, _inputs), do: {:unknown, [:invalid_population_or_sample_size]}

  defp tokens(pilot, query, opts) do
    case TrackerIdentity.from_github(%{"node_id" => pilot.node_id, "number" => pilot.number}, pilot.repo, pilot.repo) do
      {:ok, identity} -> token_summary(query.(%{tickets: [identity]}), opts)
      {:error, _reason} -> {figures(UsageEnvelope.token_dimensions(), {:unknown, [:unjoinable_ticket]}), :unknown, nil}
    end
  end

  defp token_summary(summary, opts) do
    partial = get_in(summary, [:coverage, :projection, :partial_records])
    baseline = Keyword.get(opts, :baseline_partial_records)

    reasons =
      []
      |> reason(summary.health != :healthy, :aggregate_unhealthy)
      |> reason(summary.scope.rejected_tickets != 0, :ticket_rejected)
      |> reason(summary.coverage.selected_cells == 0 or summary.totals.tokens == %{}, :no_usage_recorded)
      |> reason(not is_integer(baseline), :no_partial_baseline)
      |> reason(is_integer(baseline) and partial != baseline, :partial_records_during_pilot)

    tokens =
      Map.new(UsageEnvelope.token_dimensions(), fn dimension ->
        figure =
          case {reasons, Map.fetch(summary.totals.tokens, dimension)} do
            {[], {:ok, value}} -> {:known, value}
            {[], :error} -> :none_recorded
            {reasons, _value} -> {:unknown, reasons}
          end

        {dimension, figure}
      end)

    model = summary.groups.by_model |> Map.keys() |> Enum.sort()

    model =
      case model do
        [] -> nil
        [single] -> single
        multiple -> multiple
      end

    {tokens, partial || :unknown, model}
  end

  defp github(label, opts) do
    enabled = Keyword.get(opts, :enabled_fun, &Budget.enabled?/0)
    usage = Keyword.get(opts, :usage_fun, &Budget.usage/0)

    if enabled.() do
      case usage.() do
        %{actors: []} -> figures(@resources, {:unknown, [:broker_unavailable]})
        %{actors: actors} -> actor_usage(Enum.filter(actors, &(actor_label(&1) == label)))
      end
    else
      figures(@resources, {:unknown, [:broker_disabled]})
    end
  end

  # Inventory is keyed by credential AND consumer; count every matching credential.
  defp actor_usage(actors) do
    Map.new(@resources, fn resource -> {resource, {:known, Enum.sum(Enum.map(actors, &get_in(&1, [resource, :used])))}} end)
  end

  defp actor_label(%{consumer_label: label}) when is_binary(label) and label != "", do: label
  defp actor_label(actor), do: Map.get(actor, :consumer_key)

  defp intervals([]), do: {[], [:no_samples]}

  defp intervals([first | _rest] = ordered) do
    case Map.get(first, :dispatched_at) do
      %DateTime{} = dispatch ->
        times = [dispatch | Enum.map(ordered, & &1.observed_at)]
        {Enum.zip_with(times, tl(times), &DateTime.diff(&2, &1, :millisecond)), []}

      _missing ->
        {[], [:no_dispatch_time]}
    end
  end

  defp project_valid(sample, inputs) do
    population = inputs.population
    size = inputs.sample_size
    tokens = Map.take(sample.tokens, UsageEnvelope.token_dimensions())
    github = Map.take(sample.github, @resources)
    writes = [inputs.feature_writes_in_sample, inputs.epic_writes_in_sample]
    reasons = unknown_reasons(Map.values(tokens) ++ Map.values(github) ++ writes)

    cond do
      population == 0 -> projection(sample, inputs, 0)
      map_size(tokens) != length(UsageEnvelope.token_dimensions()) or map_size(github) != length(@resources) -> {:unknown, [:missing_figures]}
      reasons != [] -> {:unknown, reasons}
      true -> projection(sample, inputs, ceil_div(population, size))
    end
  end

  defp projection(sample, inputs, runs) do
    population = inputs.population
    size = inputs.sample_size
    feature = scale(inputs.feature_writes_in_sample, population, size)
    epic = scale(inputs.epic_writes_in_sample, population, size)
    labels = sum([feature, epic], [])

    {:ok,
     %{
       runs: runs,
       bound: :upper_bound,
       tokens: Map.new(UsageEnvelope.token_dimensions(), &{&1, scale(Map.get(sample.tokens, &1), runs, 1)}),
       per_ticket: Map.new(UsageEnvelope.token_dimensions(), &{&1, scale(Map.get(sample.tokens, &1), if(population == 0, do: 0, else: 1), size)}),
       github: Map.new(@resources, &{&1, scale(Map.get(sample.github, &1), runs, 1)}),
       feature_writes: feature,
       epic_writes: epic,
       hours: Enum.map(inputs.ceilings_per_hour, &scale(feature, 1, &1)),
       hours_with_epic_labels: Enum.map(inputs.ceilings_per_hour, &scale(labels, 1, &1))
     }}
  end

  defp scale(_figure, 0, _denominator), do: {:known, 0}
  defp scale({:known, value}, multiplier, denominator), do: {:known, ceil_div(value * multiplier, denominator)}
  defp scale(:none_recorded, _multiplier, _denominator), do: :none_recorded
  defp scale({:unknown, reasons}, _multiplier, _denominator), do: {:unknown, reasons}

  defp sum(values, reasons) do
    case Enum.uniq(reasons ++ unknown_reasons(values)) do
      [] -> if :none_recorded in values, do: :none_recorded, else: {:known, Enum.sum(Enum.map(values, &elem(&1, 1)))}
      reasons -> {:unknown, reasons}
    end
  end

  defp unknown_reasons(values),
    do:
      Enum.flat_map(values, fn
        {:unknown, reasons} -> reasons
        _figure -> []
      end)
      |> Enum.uniq()

  defp figures(keys, value), do: Map.new(keys, &{&1, value})
  defp reason(reasons, true, reason), do: reasons ++ [reason]
  defp reason(reasons, false, _reason), do: reasons
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
