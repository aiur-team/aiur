defmodule Aiur.Events.Envelope do
  @moduledoc """
  Builds the identifier-only external event envelope.

  The catalog is the sole authority for exported fields. This module performs
  no I/O and deliberately leaves feed sequencing to the exporter.
  """

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog

  @sha ~r/\A[0-9a-fA-F]{7,64}\z/
  @identifier ~r/\A[A-Za-z0-9_-]+\z/
  @max_identifier_list 100

  @type external_envelope :: %{required(String.t()) => term()}

  @spec to_external({:event, map()} | map(), keyword()) :: {:ok, external_envelope()} | :skip
  def to_external({:event, event}, opts) when is_map(event) and is_list(opts), do: to_external(event, opts)

  def to_external(event, opts) when is_map(event) and is_list(opts) do
    topic = value(event, :topic)
    catalog = Keyword.get(opts, :catalog, Catalog)

    with true <- is_binary(topic),
         %{export?: true} = entry <- lookup(catalog, topic),
         id when is_integer(id) and id > 0 <- value(event, :id) do
      {:ok,
       %{
         "v" => 1,
         "instance" => Keyword.get(opts, :instance),
         "id" => id,
         "topic" => topic,
         "class" => Atom.to_string(entry.class),
         "occurred_at" => timestamp(observation_value(event, :occurred_at)),
         "observed_at" => timestamp(observation_value(event, :observed_at)),
         "source" => source(event, topic),
         "refs" => refs(entry.refs, event, topic),
         "attrs" => attrs(entry.attrs, event),
         "payload_version" => entry.payload_version,
         "anchor" => nil
       }}
    else
      _ -> :skip
    end
  end

  def to_external(_event, _opts), do: :skip

  defp lookup(catalog, topic) when is_function(catalog, 1), do: catalog.(topic)
  defp lookup(catalog, topic), do: catalog.lookup(topic)

  defp refs(allowed, event, topic) do
    Enum.into(allowed, %{}, fn key -> {Atom.to_string(key), ref(key, event, topic)} end)
  end

  defp ref(:ticket, _event, topic), do: ticket_from_topic(topic)

  defp ref(:pr_number, event, _topic) do
    event |> pr() |> value(:number) |> fallback(value(event, :pr_number)) |> fallback(value(event, :pull_request_number)) |> positive_integer()
  end

  defp ref(:head_sha, event, _topic) do
    event |> pr() |> value(:head) |> value(:sha) |> fallback(value(event, :head_sha)) |> fallback(value(event, :sha)) |> sha()
  end

  defp ref(:decision_version, event, _topic), do: event |> value(:decision_version) |> positive_integer()
  defp ref(:decision_id, event, _topic), do: event |> value(:decision_id) |> identifier()
  defp ref(:queue_id, event, _topic), do: event |> value(:queue_id) |> identifier()
  defp ref(:prerequisite, event, _topic), do: event |> value(:prerequisite) |> identifier()
  defp ref(:blocked, event, _topic), do: event |> value(:blocked) |> identifiers()
  defp ref(:root, event, _topic), do: event |> value(:root) |> identifier()

  defp attrs(allowed, event) do
    Enum.into(allowed, %{}, fn {key, type} -> {Atom.to_string(key), attr(value(event, key), type)} end)
  end

  defp attr(value, {:enum, allowed}), do: enum(value, allowed)
  defp attr(value, :integer) when is_integer(value), do: value
  defp attr(value, :boolean) when is_boolean(value), do: value
  defp attr(value, :id), do: identifier(value)
  defp attr(value, :sha), do: sha(value)
  defp attr(value, {:list, :id}), do: identifiers(value)
  defp attr(_value, _type), do: nil

  defp source(event, topic) do
    case observation_value(event, :source) |> value(:kind) do
      kind when kind in [:agent_event, "agent_event"] -> "agent"
      kind when kind in [:agent_alert, "agent_alert"] -> "agent_alert"
      kind when kind in [:legacy, "legacy"] -> legacy_source(event, topic)
      _ -> "unknown"
    end
  end

  defp legacy_source(event, topic) do
    cond do
      value(event, :source) in [:alert, "alert"] -> "alert"
      String.starts_with?(topic, "executor.") -> "executor"
      true -> "legacy"
    end
  end

  defp observation_value(event, key), do: event |> value(:ticket_observation) |> value(key)
  defp pr(event), do: event |> value(:pr) |> typed_map()
  defp ticket_from_topic("ticket." <> rest), do: rest |> String.split(".", parts: 2) |> List.first()
  defp ticket_from_topic(_topic), do: nil
  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
  defp sha(value) when is_binary(value), do: if(Regex.match?(@sha, value), do: String.downcase(value), else: nil)
  defp sha(_value), do: nil

  defp identifier(value) when is_binary(value) and byte_size(value) <= 128,
    do: if(Regex.match?(@identifier, value), do: value, else: nil)

  defp identifier(_value), do: nil

  defp identifiers(values) when is_list(values) and length(values) <= @max_identifier_list do
    if Enum.all?(values, &(identifier(&1) != nil)), do: values, else: nil
  end

  defp identifiers(_values), do: nil
  defp enum(value, allowed) when is_atom(value), do: enum(Atom.to_string(value), allowed)
  defp enum(value, allowed) when is_binary(value), do: if(value in allowed, do: value, else: nil)
  defp enum(_value, _allowed), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value) when is_binary(value), do: if(match?({:ok, _, _}, DateTime.from_iso8601(value)), do: value, else: nil)
  defp timestamp(_value), do: nil
  defp typed_map(value) when is_map(value), do: value
  defp typed_map(_value), do: %{}

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
