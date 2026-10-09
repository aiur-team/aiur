defmodule Aiur.BuildQueue.AttentionActions do
  @moduledoc false
  require Logger
  alias Aiur.BuildQueue.{Attention, Ordering, Readiness}

  @spec execute(map(), tuple()) :: map()
  def execute(context, {:attention_resolve, key} = command) do
    if Enum.any?(context.document.latches, &(&1.key == key)), do: perform(context, command), else: context
  end

  def execute(context, command), do: perform(context, command)

  defp perform(context, {action, {cause, id}}) do
    result =
      case action do
        :attention_open -> Attention.open(cause, id, payload(cause, id, context), context.store)
        :attention_resolve -> Attention.resolve(cause, id, context.store)
      end

    subject = if id, do: "issue_id=#{id} issue_identifier=##{id}", else: "scope=system"
    if result != :ok, do: Logger.warning("Build queue attention failed #{subject} action=#{action}: #{inspect(result)}")

    case context.store.load() do
      {:ok, document} ->
        context = %{context | document: document}
        if match?({:error, {:store_unavailable, _}}, result), do: %{context | status: :store_unavailable}, else: context

      {:error, _reason} ->
        %{context | status: :store_unavailable}
    end
  end

  defp payload({:prerequisite_failed, reason}, id, context) do
    edges = Map.get(context, :planned_edges, context.document.edges)
    active = for item <- context.document.items, match?(%{open?: true}, context.observations[item.issue_id]) and context.marker in context.observations[item.issue_id].labels, do: item.issue_id
    blocked = Ordering.dependents(edges, id) |> Enum.filter(&(&1 in active))
    %{prerequisite: id, blocked: blocked, cause: reason}
  end

  defp payload(:dependency_changed_after_start, id, context) do
    edges = Map.get(context, :planned_edges, context.document.edges)
    opts = [label_prefix: String.replace_suffix(context.todo, ":todo", ""), now_ms: context.clock.(), max_age_ms: context.observation_max_age_ms]
    prerequisites = for edge <- edges, edge.dependent == id, Readiness.edge_verdict(context.observations[edge.prerequisite], opts) != :satisfied, do: edge.prerequisite

    case Enum.sort(prerequisites) do
      [prerequisite | _] -> %{ticket: id, prerequisite: prerequisite}
      [] -> %{ticket: id}
    end
  end

  defp payload(:inputs_unavailable, nil, _context), do: %{freshness: :unknown}
  defp payload(_cause, id, _context), do: %{ticket: id}
end
