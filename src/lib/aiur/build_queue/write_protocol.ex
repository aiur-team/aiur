defmodule Aiur.BuildQueue.WriteProtocol do
  @moduledoc false
  alias Aiur.BuildQueue.{Events, WriteEvidence}
  alias Aiur.BuildQueue.Model.Intent

  @spec attempt(map(), atom(), String.t(), map()) :: {map(), :ok | {:error, term()}}
  def attempt(context, action, id, runtime) do
    intent = %Intent{id: Ecto.UUID.generate(), issue_id: id, action: action, target_labels: targets(context, action, id), recorded_at_ms: context.clock.(), outcome: nil}
    document = %{context.document | intents: context.document.intents ++ [intent]}

    case context.store.save(document) do
      :ok -> write(%{context | document: document}, intent, runtime)
      {:error, reason} -> {%{context | status: :store_unavailable}, {:error, reason}}
    end
  end

  defp write(context, intent, runtime) do
    result = execute(context, intent, runtime)
    document = %{context.document | intents: Enum.map(context.document.intents, fn row -> if row.id == intent.id, do: %{row | outcome: result}, else: row end)}
    document = provenance(document, intent, result, context.clock.())

    case context.store.save(document) do
      :ok ->
        Events.saved(context.document, document)
        {%{context | document: document}, result}

      {:error, reason} ->
        {%{context | document: document, status: :store_unavailable}, {:error, reason}}
    end
  end

  defp execute(context, %{action: :promote, issue_id: id} = intent, runtime) do
    if WriteEvidence.fresh?(context, id), do: call(context.tracker, intent.action, id, context.marker, runtime), else: {:error, :stale_observation}
  end

  defp execute(context, intent, runtime), do: call(context.tracker, intent.action, intent.issue_id, context.marker, runtime)

  defp call(tracker, :promote, id, _marker, _runtime), do: tracker.update_issue_state(id, "todo", expected_state: :none)
  defp call(tracker, :mark, id, marker, %{ensured?: true}), do: tracker.add_label(id, marker)
  defp call(tracker, :unmark, id, marker, _runtime), do: tracker.remove_label(id, marker)

  defp provenance(document, %{action: :promote, issue_id: id}, :ok, now) do
    %{document | items: Enum.map(document.items, fn item -> if item.issue_id == id, do: %{item | promoted_at: DateTime.from_unix!(now, :millisecond)}, else: item end)}
  end

  defp provenance(document, _intent, _result, _now), do: document

  defp targets(context, action, id) do
    labels =
      case context.observations[id] do
        nil -> []
        observation -> observation.labels
      end

    case action do
      :promote -> Enum.uniq(labels ++ [context.todo])
      :mark -> Enum.uniq(labels ++ [context.marker])
      :unmark -> Enum.reject(labels, &(&1 == context.marker))
    end
  end

  @spec classify(:ok | {:error, term()}) :: :ok | :reobserve | :paused | :retry
  def classify(:ok), do: :ok
  def classify({:error, :stale_observation}), do: :reobserve
  def classify({:error, {:stale_issue_state, :none, _}}), do: :reobserve
  def classify({:error, {:no_state_label_written, _}}), do: :reobserve
  def classify({:error, {:github, kind, _}}) when kind in [:rate_limited, :local_hold], do: :paused
  def classify({:error, {:aiur, :locally_held, _}}), do: :paused
  def classify({:error, {:github_api_request, reason}}), do: classify({:error, reason})
  def classify(_), do: :retry
end
