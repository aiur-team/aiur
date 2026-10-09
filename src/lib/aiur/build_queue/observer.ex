defmodule Aiur.BuildQueue.Observer do
  @moduledoc "Transient prerequisite closure evidence; open listings invalidate terminal entries."
  alias Aiur.BuildQueue.{Model.Observation, Settings}

  @spec observe(map()) :: {map(), map()}
  def observe(state) do
    age = Settings.observation_max_age_ms(state.settings)
    cache = Map.get(state, :closure_cache, %{})

    case state.tracker.open_issue_labels(age) do
      {:ok, labels, observed_at_ms} ->
        open = Map.new(labels, fn {id, row} -> {id, observation(id, true, nil, row.labels, observed_at_ms)} end)
        ids = state.document.edges |> Enum.map(& &1.prerequisite) |> Enum.uniq()
        cache = cache |> Map.take(ids) |> Map.drop(Map.keys(open))
        Enum.reduce(ids, {open, cache}, &observe_missing(&1, &2, state.tracker, observed_at_ms))

      _ ->
        {%{}, cache}
    end
  end

  defp observe_missing(id, {observations, cache}, tracker, observed_at_ms) do
    if Map.has_key?(observations, id) do
      {observations, cache}
    else
      closure = Map.get_lazy(cache, id, fn -> read(tracker, id) end)
      cache = if match?({:ok, %{open?: false}}, closure), do: Map.put(cache, id, closure), else: cache

      evidence =
        case closure do
          {:ok, %{open?: open?, state_reason: reason}} -> observation(id, open?, reason, [], observed_at_ms)
          {:error, _} -> %{observation(id, :unknown, nil, [], observed_at_ms) | unavailable_reason: :closed_reason}
        end

      {Map.put(observations, id, evidence), cache}
    end
  end

  defp read(tracker, id) do
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :issue_closure, 1), do: tracker.issue_closure(id), else: {:error, :unsupported}
  end

  defp observation(id, open?, reason, labels, at), do: %Observation{issue_id: id, open?: open?, labels: labels, state_reason: reason, pr: nil, observed_at_ms: at}
end
