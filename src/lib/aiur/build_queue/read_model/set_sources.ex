defmodule Aiur.BuildQueue.ReadModel.SetSources do
  @moduledoc "Per-set source evidence and owned-elsewhere members for the queue read model."
  alias Aiur.BuildQueue.{BuildOrderCommands, ReadModel, Settings}

  @doc "Whether a set's own source is too stale to trust its membership."
  @spec unavailable?(map(), map(), map()) :: boolean()
  def unavailable?(%{kind: :build_order, root: root}, build_orders, _state),
    do: build_orders[root].source.freshness != :current

  def unavailable?(%{kind: :feature, feature: slug}, _build_orders, state),
    do: Map.get(Map.get(state, :sources, %{}), "feature:#{slug}") != :current

  def unavailable?(_queue, _build_orders, _state), do: false

  # The registry is a local read, so a current sync is observed now; a failed sync keeps its reason.
  @spec feature(map(), map(), integer()) :: map()
  def feature(document, state, now) do
    max_age = if Map.has_key?(state, :settings), do: Settings.observation_max_age_ms(state.settings), else: 1
    sources = Map.get(state, :sources, %{})

    Map.new(
      document.queues |> Enum.filter(&(&1.kind == :feature)),
      fn queue ->
        key = "feature:#{queue.feature}"

        case Map.get(sources, key) do
          :current -> {key, ReadModel.source(now, now, max_age, [])}
          {:unavailable, reason} -> {key, ReadModel.source(nil, now, max_age, [reason])}
          _ -> {key, ReadModel.source(nil, now, max_age, [:not_reconciled])}
        end
      end
    )
  end

  @doc "Registry or root members another entry already owns, named by the entry that holds them."
  @spec elsewhere(map(), map()) :: list()
  def elsewhere(%{kind: kind} = queue, state) when kind in [:build_order, :feature],
    do: Map.get(Map.get(state, :sources, %{}), BuildOrderCommands.elsewhere_key(queue), [])

  def elsewhere(_queue, _state), do: []
end
