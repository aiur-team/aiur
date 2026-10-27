defmodule Aiur.Events.Outbound.Event do
  @moduledoc "Selects canonical export records supported by the signed webhook contract."
  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog

  @doc "Returns whether an internal topic is part of the signed webhook contract."
  @spec exportable_topic?(String.t()) :: boolean()
  def exportable_topic?(topic) when is_binary(topic) do
    supported_topic?(topic) and Catalog.lookup(topic).export?
  end

  def exportable_topic?(_topic), do: false

  @doc "Returns the stable Standard Webhooks identifier for a canonical external envelope."
  @spec delivery_id(map()) :: {:ok, String.t()} | :error
  def delivery_id(%{"instance" => instance, "id" => id})
      when is_binary(instance) and instance != "" and is_integer(id) and id > 0,
      do: {:ok, "#{instance}/#{id}"}

  def delivery_id(_event), do: :error

  @doc "Removes the feed-only marker from one supported canonical event record."
  @spec webhook_event(map()) :: {:ok, map()} | :skip
  def webhook_event(%{"type" => "event", "topic" => topic} = record) do
    event = Map.delete(record, "type")

    if exportable_topic?(topic) and match?({:ok, _}, delivery_id(event)),
      do: {:ok, event},
      else: :skip
  end

  def webhook_event(_record), do: :skip

  defp supported_topic?(topic) do
    case String.split(topic, ".") do
      ["ticket", _identifier, "lifecycle", "changed"] -> true
      ["ticket", _identifier, "usage", "changed"] -> true
      ["ticket", _identifier, "usage", "spend_cap_reached"] -> true
      ["ticket", _identifier, "cancel", "result"] -> true
      ["ticket", _identifier, "agent", "progress"] -> true
      ["ticket", _identifier, "agent", "progress", suffix] when suffix in ["checkin", "phase"] -> true
      _other -> false
    end
  end
end
