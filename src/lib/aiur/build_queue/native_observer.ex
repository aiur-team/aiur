defmodule Aiur.BuildQueue.NativeObserver do
  @moduledoc "Lazily reads native prerequisites for list items about to be promoted. Edges remain transient."
  alias Aiur.BuildQueue.{Model.Edge, Observer, Planner}

  @spec observe(Planner.Input.t(), map(), map()) :: {Planner.Input.t(), map()}
  def observe(input, state, cache) do
    lists = for queue <- input.queues, queue.kind == :list, do: queue.id
    members = for item <- input.items, item.queue_id in lists, do: item.issue_id
    {_projections, actions} = Planner.plan(input)
    candidates = for {:promote, id} <- actions, id in members, do: id
    enrich(candidates, input, state, cache)
  end

  defp enrich([], input, _state, cache), do: {input, cache}

  defp enrich(candidates, input, state, cache) do
    input = Enum.reduce(candidates, input, &read(&1, &2, state.tracker))
    cache = Map.merge(Map.get(state, :closure_cache, %{}), cache)
    state = state |> Map.put(:document, %{state.document | edges: input.edges}) |> Map.put(:closure_cache, cache)
    at = input.observations |> Map.values() |> Enum.map(& &1.observed_at_ms) |> Enum.max(fn -> input.now_ms end)
    {observations, cache} = Observer.enrich(state, input.observations, at)
    {%{input | observations: observations}, cache}
  end

  defp read(id, input, tracker) do
    result = if Code.ensure_loaded?(tracker) and function_exported?(tracker, :blocked_by, 1), do: tracker.blocked_by(id), else: {:error, :unsupported}

    case result do
      {:ok, ids} ->
        edges = Enum.map(ids, &%Edge{prerequisite: &1, dependent: id, source: :native})
        %{input | edges: Enum.uniq(input.edges ++ edges)}

      {:error, reason} ->
        cause = if reason == :external_edge, do: :external_edge, else: :native_dependencies
        verdicts = input.opts |> Keyword.get(:native_verdicts, %{}) |> Map.put(id, {:unknown, cause})
        %{input | opts: Keyword.put(input.opts, :native_verdicts, verdicts)}
    end
  end
end
