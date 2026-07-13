defmodule Aiur.DecisionMetrics.Event.Fields do
  @moduledoc "Extracts bounded metric fields from compatible Decision event envelopes."

  @spec stringify(term()) :: term()
  def stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  end

  def stringify(value), do: value

  @spec value(map(), [String.t()]) :: term()
  def value(event, keys) do
    containers = [event, event["data"], event["decision"], event["answer"], event["delivery"], event["revision"]]

    Enum.reduce_while(containers, nil, fn
      container, _acc when is_map(container) -> find_in_container(container, keys)
      _other, acc -> {:cont, acc}
    end)
  end

  @spec identifier(map(), term()) :: String.t() | nil
  def identifier(event, topic) do
    ticket = stringify(event["ticket"])
    identifier = ticket["identifier"] || value(event, ["identifier", "source_ticket_id"])

    case identifier do
      identifier when is_binary(identifier) and identifier != "" -> identifier
      identifier when is_integer(identifier) -> Integer.to_string(identifier)
      _other -> ticket_from_topic(topic)
    end
  end

  @spec event_id(map()) :: String.t() | nil
  def event_id(event) do
    case event["id"] || event["event_id"] do
      identifier when is_binary(identifier) and identifier != "" -> identifier
      identifier when is_integer(identifier) -> Integer.to_string(identifier)
      _other -> nil
    end
  end

  @spec event_time(map(), atom(), DateTime.t()) :: DateTime.t()
  def event_time(event, stage, fallback) do
    keys = stage_time_keys(stage) ++ ["occurred_at", "at", "timestamp"]

    case value(event, keys) do
      %DateTime{} = timestamp -> timestamp
      timestamp when is_binary(timestamp) -> parse_iso8601(timestamp) || fallback
      timestamp when is_integer(timestamp) -> from_unix_millisecond(timestamp) || fallback
      _other -> fallback
    end
  end

  @spec actor(map()) :: String.t() | nil
  def actor(event) do
    case event |> value(["actor", "actor_type"]) |> stringify() do
      %{"type" => type} -> normalize_actor(type)
      %{"kind" => kind} -> normalize_actor(kind)
      actor -> normalize_actor(actor)
    end
  end

  defp find_in_container(container, keys) do
    container = stringify(container)

    case Enum.find(keys, &(Map.has_key?(container, &1) and not is_nil(container[&1]))) do
      nil -> {:cont, nil}
      key -> {:halt, container[key]}
    end
  end

  defp ticket_from_topic("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [identifier, _suffix] when identifier != "" -> identifier
      _other -> nil
    end
  end

  defp ticket_from_topic(_topic), do: nil

  defp stage_time_keys(:requested), do: ["requested_at", "created_at"]
  defp stage_time_keys(:decided), do: ["decided_at", "answered_at", "recorded_at"]
  defp stage_time_keys(:dispatched), do: ["dispatched_at", "queued_at"]
  defp stage_time_keys(:delivered), do: ["delivered_at", "handed_off_at"]
  defp stage_time_keys(:acknowledged), do: ["acknowledged_at", "acked_at"]
  defp stage_time_keys(:resolved), do: ["resolved_at"]
  defp stage_time_keys(:attention), do: ["reminded_at", "created_at"]
  defp stage_time_keys(:reminder), do: ["reminded_at"]
  defp stage_time_keys(:revised), do: ["revised_at"]

  defp normalize_actor(actor) when is_atom(actor), do: actor |> Atom.to_string() |> normalize_actor()

  defp normalize_actor(actor) when is_binary(actor) do
    case actor |> String.downcase() |> String.replace("-", "_") do
      kind when kind in ["human", "operator", "human_operator"] -> "human"
      kind when kind in ["supervisor", "supervising_agent", "supervisor_agent"] -> "supervisor"
      _other -> nil
    end
  end

  defp normalize_actor(_actor), do: nil

  defp parse_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp from_unix_millisecond(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end
end
