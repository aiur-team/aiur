defmodule Aiur.BuildQueue.Recovery do
  @moduledoc false
  alias Aiur.BuildQueue.{Model, Reconcile}

  @spec resolve(map(), map()) :: map()
  def resolve(%{phase: :awaiting_first_observation, freshness: :fresh} = state, observations) do
    intents = Enum.map(state.document.intents, &resolve_intent(&1, observations, state.settings.tracker.github.label_prefix))
    document = %{state.document | intents: intents}
    # Only intents resolved here gain provenance: a release may have cleared promoted_at after an older :ok intent.
    resolved = for {before, now} <- Enum.zip(state.document.intents, intents), before.outcome == nil, do: now
    document = Enum.reduce(resolved, document, &provenance/2)

    if document == state.document do
      %{state | phase: :ready}
    else
      case state.store.save(document) do
        :ok -> %{state | document: document, phase: :ready}
        {:error, _reason} -> %{state | status: :store_unavailable}
      end
    end
  end

  def resolve(state, _observations), do: state

  defp resolve_intent(%{outcome: nil} = intent, observations, prefix) do
    labels =
      case observations[intent.issue_id] do
        nil -> []
        observation -> observation.labels
      end

    applied =
      case intent.action do
        :promote -> "#{prefix}:todo" in labels
        :withdraw -> "#{prefix}:todo" not in labels
        :mark -> "#{prefix}:queued" in labels
        :unmark -> "#{prefix}:queued" not in labels
      end

    %{intent | outcome: if(applied, do: :ok, else: {:error, :not_applied})}
  end

  defp resolve_intent(intent, _observations, _prefix), do: intent

  defp provenance(%{action: :promote, outcome: :ok} = intent, document) do
    items =
      Enum.map(document.items, fn item ->
        if item.issue_id == intent.issue_id and item.promoted_at == nil, do: %{item | promoted_at: DateTime.from_unix!(intent.recorded_at_ms, :millisecond)}, else: item
      end)

    %{document | items: items}
  end

  defp provenance(_intent, document), do: document

  @spec rebuild(map()) :: {:ok, Model.t()} | {:error, term()}
  def rebuild(state) do
    case Reconcile.snapshot(state) do
      {:fresh, observations} ->
        document = recovered(observations, state.settings.tracker.github.label_prefix, state.clock.())
        with :ok <- state.store.rebuild(document), do: {:ok, document}

      {:unknown, _} ->
        {:error, :observation_unavailable}
    end
  end

  defp recovered(observations, prefix, now) do
    created = DateTime.from_unix!(now, :millisecond)
    queue = %Model.Queue{id: "q-" <> binary_part(Ecto.UUID.generate(), 0, 4), name: "recovered", kind: :list, root: nil, held: false, generation: 0, created_at: created}
    ids = for {id, observation} <- observations, "#{prefix}:queued" in observation.labels, do: id

    items =
      ids
      |> Enum.sort_by(&String.to_integer/1)
      |> Enum.with_index()
      |> Enum.map(fn {id, position} ->
        %Model.Item{issue_id: id, queue_id: queue.id, position: position, hold: :operator, override: nil, promoted_at: nil, added_at: created}
      end)

    %{queues: [queue], items: items, edges: [], intents: [], latches: []}
  end
end
