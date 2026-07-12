defmodule Aiur.DecisionMetrics.Event do
  @moduledoc """
  Normalizes current and forward-compatible Decision Exchange envelopes into
  the small, redacted fact shape consumed by `Aiur.DecisionMetrics`.
  """

  @stage_aliases %{
    "request" => :requested,
    "requested" => :requested,
    "decision_requested" => :requested,
    "answer_recorded" => :decided,
    "answered" => :decided,
    "decided" => :decided,
    "decision_recorded" => :decided,
    "dispatch_queued" => :dispatched,
    "dispatched" => :dispatched,
    "queued" => :dispatched,
    "delivered" => :delivered,
    "dispatch_delivered" => :delivered,
    "handed_off" => :delivered,
    "ack" => :acknowledged,
    "acknowledged" => :acknowledged,
    "resolved" => :resolved,
    "reminded" => :reminder,
    "reminder" => :reminder,
    "revised" => :revised,
    "revision_recorded" => :revised,
    "attention" => :attention
  }
  @implicit_stages %{"attention" => :attention, "requested" => :requested}

  @type fact :: %{
          stage: Aiur.DecisionMetrics.Sample.stage(),
          decision_id: String.t(),
          identifier: String.t(),
          event_id: String.t(),
          at: DateTime.t(),
          blocking: boolean() | nil,
          actor: String.t() | nil
        }

  @doc "Normalizes a Decision lifecycle event or ignores unrelated/uncorrelated events."
  @spec normalize(map(), DateTime.t()) :: {:ok, fact()} | :ignored
  def normalize(event, %DateTime{} = observed_at) when is_map(event) do
    event = stringify_keys(event)
    topic = event["topic"]

    with stage when is_atom(stage) and not is_nil(stage) <- stage_for(event, topic),
         decision_id when is_binary(decision_id) <- decision_id(event),
         identifier when is_binary(identifier) <- identifier(event, topic),
         event_id when is_binary(event_id) <- event_id(event) do
      {:ok,
       %{
         stage: stage,
         decision_id: decision_id,
         identifier: identifier,
         event_id: event_id,
         at: event_time(event, stage, observed_at),
         blocking: event_value(event, ["blocking"]),
         actor: actor(event)
       }}
    else
      _other -> :ignored
    end
  end

  defp stage_for(event, topic) do
    explicit = event["event_type"] || event["event"] || event["type"]
    stage_alias(explicit) || Map.get(@implicit_stages, topic_label(topic))
  end

  defp stage_alias(label), do: Map.get(@stage_aliases, normalize_label(label))

  defp topic_label(topic) when is_binary(topic) do
    cond do
      String.contains?(topic, ".decision.") -> topic |> String.split(".decision.", parts: 2) |> List.last()
      String.contains?(topic, ".attention.") and not String.ends_with?(topic, ".resolved") -> "attention"
      true -> nil
    end
  end

  defp topic_label(_topic), do: nil
  defp normalize_label(label) when is_atom(label), do: label |> Atom.to_string() |> normalize_label()

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.replace_prefix("decision_", "")
  end

  defp normalize_label(_label), do: nil

  defp decision_id(event), do: event_value(event, ["decision_id"])

  defp identifier(event, topic) do
    ticket = stringify_keys(event["ticket"])
    value = ticket["identifier"] || event_value(event, ["identifier", "source_ticket_id"])

    case value do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      _other -> ticket_from_topic(topic)
    end
  end

  defp ticket_from_topic("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [identifier, _suffix] when identifier != "" -> identifier
      _other -> nil
    end
  end

  defp ticket_from_topic(_topic), do: nil

  defp event_id(event) do
    case event["id"] || event["event_id"] do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      _other -> nil
    end
  end

  defp event_time(event, stage, fallback) do
    keys = stage_time_keys(stage) ++ ["occurred_at", "at", "timestamp"]

    case event_value(event, keys) do
      %DateTime{} = value -> value
      value when is_binary(value) -> parse_iso8601(value) || fallback
      value when is_integer(value) -> from_unix_millisecond(value) || fallback
      _other -> fallback
    end
  end

  defp stage_time_keys(:requested), do: ["requested_at", "created_at"]
  defp stage_time_keys(:decided), do: ["decided_at", "answered_at", "recorded_at"]
  defp stage_time_keys(:dispatched), do: ["dispatched_at", "queued_at"]
  defp stage_time_keys(:delivered), do: ["delivered_at", "handed_off_at"]
  defp stage_time_keys(:acknowledged), do: ["acknowledged_at", "acked_at"]
  defp stage_time_keys(:resolved), do: ["resolved_at"]
  defp stage_time_keys(:attention), do: ["reminded_at", "created_at"]
  defp stage_time_keys(:reminder), do: ["reminded_at"]
  defp stage_time_keys(:revised), do: ["revised_at"]

  defp event_value(event, keys) do
    containers = [event, event["data"], event["decision"], event["answer"], event["delivery"], event["revision"]]

    Enum.reduce_while(containers, nil, fn
      container, _acc when is_map(container) -> find_in_container(container, keys)
      _other, acc -> {:cont, acc}
    end)
  end

  defp find_in_container(container, keys) do
    container = stringify_keys(container)

    case Enum.find(keys, &(Map.has_key?(container, &1) and not is_nil(container[&1]))) do
      nil -> {:cont, nil}
      key -> {:halt, container[key]}
    end
  end

  defp actor(event) do
    case event |> event_value(["actor", "actor_type"]) |> stringify_keys() do
      %{"type" => type} -> normalize_actor(type)
      %{"kind" => kind} -> normalize_actor(kind)
      value -> normalize_actor(value)
    end
  end

  defp normalize_actor(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_actor()

  defp normalize_actor(value) when is_binary(value) do
    case value |> String.downcase() |> String.replace("-", "_") do
      actor when actor in ["human", "operator", "human_operator"] -> "human"
      actor when actor in ["supervisor", "supervising_agent", "supervisor_agent"] -> "supervisor"
      _other -> nil
    end
  end

  defp normalize_actor(_value), do: nil

  defp stringify_keys(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  defp stringify_keys(value), do: value

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
