defmodule Aiur.BuildQueue.Reconcile do
  @moduledoc false

  alias Aiur.BuildQueue.{Hints, Model.Observation, Observer, Planner, Settings}

  @spec plan(map()) :: {[Planner.item_state()], [Planner.action()], map(), map()}
  def plan(state) do
    {freshness, observations} = snapshot(state)
    plan(Map.put(state, :freshness, freshness), observations)
  end

  @spec plan(map(), map()) :: {[Planner.item_state()], [Planner.action()], map(), map()}
  def plan(state, observations) do
    input = struct!(Planner.Input, Map.to_list(state.document) ++ [now_ms: state.clock.(), opts: []])
    intents = Enum.filter(input.intents, &(state.reconciles - Map.get(state.intent_reconciles, &1.id, 0) < 2))
    opts = [label_prefix: state.settings.tracker.github.label_prefix, observation_max_age_ms: Settings.observation_max_age_ms(state.settings), withdrawal_holds: state.holds]
    ids = Enum.map(input.items, & &1.issue_id)
    {observations, cache} = closures(state, observations)
    input = %{input | opts: opts, observations: observations, claims: state.claim_probe.status(ids), intents: intents}
    {projections, actions} = Planner.plan(input)
    {projections, actions, input.observations, cache}
  end

  @spec write_hints([Planner.item_state()], MapSet.t(String.t()), map()) :: true
  def write_hints(projections, holds, document) do
    held_queues = for queue <- document.queues, queue.held, do: queue.id
    persisted = for item <- document.items, item.hold != nil or item.queue_id in held_queues, do: item.issue_id
    holds = MapSet.union(holds, MapSet.new(persisted))

    rows =
      for p <- projections,
          p.state not in [:removed, :completed, :cancelled],
          do: {p.issue_id, hint(p.rank), MapSet.member?(holds, p.issue_id) or p.state == :held or (p.state == :unknown and Hints.held?(p.issue_id))}

    :ets.insert(Hints.table_name(), rows)
    retained = MapSet.new(rows, &elem(&1, 0))
    for {id, _, _} <- :ets.tab2list(Hints.table_name()), not MapSet.member?(retained, id), do: :ets.delete(Hints.table_name(), id)
    true
  end

  defp hint({downstream, _priority, position, _age, _id}), do: {downstream, position}

  # Prerequisite closure evidence extends a fresh open listing; an unknown listing yields none.
  defp closures(state, observations) do
    rows = Map.values(observations)

    cond do
      rows != [] -> Observer.enrich(state, observations, rows |> Enum.map(& &1.observed_at_ms) |> Enum.max())
      Map.get(state, :freshness) == :fresh -> Observer.enrich(state, observations, state.clock.())
      true -> {%{}, Map.get(state, :closure_cache, %{})}
    end
  end

  @spec observations(map()) :: %{String.t() => Observation.t()}
  def observations(state) do
    {_freshness, observations} = snapshot(state)
    observations
  end

  @spec snapshot(map()) :: {:fresh | :unknown, map()}
  def snapshot(state) do
    {freshness, observations, _observed_at_ms} = observed_snapshot(state)
    {freshness, observations}
  end

  @spec observed_snapshot(map()) :: {:fresh | :unknown, map(), integer() | nil}
  def observed_snapshot(state) do
    now = state.clock.()
    max_age = Settings.observation_max_age_ms(state.settings)
    pending = if state.document, do: Enum.filter(state.document.intents, &is_nil(&1.outcome)), else: []
    after_intent = pending |> Enum.map(& &1.recorded_at_ms) |> Enum.max(fn -> 0 end)

    case state.tracker.open_issue_labels(Settings.observation_max_age_ms(state.settings)) do
      {:ok, labels, observed_at_ms} when observed_at_ms >= after_intent and observed_at_ms <= now and now - observed_at_ms <= max_age ->
        observations =
          Map.new(labels, fn {id, row} ->
            {id, %Observation{issue_id: id, open?: true, labels: row.labels, state_reason: nil, pr: nil, observed_at_ms: observed_at_ms}}
          end)

        {:fresh, observations, observed_at_ms}

      _ ->
        {:unknown, %{}, nil}
    end
  end
end
