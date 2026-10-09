defmodule Aiur.BuildQueue.Events do
  @moduledoc "Live transition hints emitted only after the queue document is saved."
  require Logger
  alias Aiur.Events.Publisher

  @doc "Publishes transitions between two saved documents; `removed_cause` names why members left."
  @spec saved(map(), map(), atom()) :: :ok
  def saved(before, after_save, removed_cause \\ :marker_removed) do
    old_intents = Map.new(before.intents, &{&1.id, &1.outcome})

    for intent <- after_save.intents,
        intent.outcome == :ok and Map.get(old_intents, intent.id) != :ok,
        intent.action in [:promote, :withdraw] do
      publish_intent(before, intent)
    end

    Enum.each(before.items, &membership(&1, before, after_save, removed_cause))
    :ok
  end

  defp publish_intent(document, intent) do
    item = Enum.find(document.items, &(&1.issue_id == intent.issue_id))
    if item, do: publish(if(intent.action == :promote, do: :promoted, else: :withdrawn), item, intent.action, intent.id)
  end

  defp membership(item, before, after_save, removed_cause) do
    case Enum.find(after_save.items, &(&1.issue_id == item.issue_id)) do
      nil -> publish(:removed, item, removed_cause, Ecto.UUID.generate())
      current -> changed(item, current, held?(item, before), held?(current, after_save))
    end
  end

  defp changed(item, current, was_held, held) do
    cond do
      current.override != item.override and current.override != nil -> publish(:overridden, current, current.override, Ecto.UUID.generate())
      held and not was_held -> publish(:held, current, current.hold || :queue_hold, Ecto.UUID.generate())
      released?(item, current, was_held, held) -> publish(:released, current, :operator, Ecto.UUID.generate())
      true -> :ok
    end
  end

  defp released?(item, current, was_held, held), do: (was_held and not held) or (item.override != nil and current.override == nil)

  defp held?(item, document), do: item.hold != nil or Enum.any?(document.queues, &(&1.id == item.queue_id and &1.held))

  @spec publish(atom(), map(), atom(), String.t()) :: :ok
  def publish(verb, item, cause, intent_id) when verb in [:promoted, :withdrawn, :held, :released, :overridden, :removed] do
    payload = %{"ticket" => item.issue_id, "queue_id" => item.queue_id, "cause" => Atom.to_string(cause)}

    case Publisher.publish("ticket.#{item.issue_id}.queue.#{verb}", payload, dedup_key: {"build_queue", "queue", intent_id}) do
      {:ok, _, _} -> :ok
      :deduped -> :ok
      result -> Logger.warning("Build queue event rejected: #{inspect(result)}")
    end

    :ok
  catch
    kind, reason ->
      Logger.warning("Build queue event unavailable: #{inspect({kind, reason})}")
      :ok
  end
end
