defmodule Aiur.LiveConversation.Normalizer do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail.Sanitizer
  alias Aiur.LiveConversation.Source

  @body_limit 1_600
  @title_limit 120
  @fragment_join_byte_limit 256_000

  @type delivery :: :partial | :completed

  @spec normalize(term(), DateTime.t()) :: {:ok, map()} | {:drop, atom()}
  def normalize(%{kind: kind, id: id, body: body} = event, observed_at)
      when kind in [:assistant_delta, :assistant_completed] and is_binary(id) and
             is_binary(body) do
    normalized_message(
      :assistant,
      body,
      Map.merge(event, %{msg_id: id, delivery: delivery_for(kind)}),
      observed_at
    )
  end

  def normalize(%{role: :assistant, body: body} = event, observed_at) when is_binary(body) do
    normalized_message(:assistant, body, event, observed_at)
  end

  def normalize(%{role: :tool}, _observed_at), do: {:drop, :unsafe_tool}
  def normalize(%{role: :system}, _observed_at), do: {:drop, :unsafe_system}
  def normalize(%{role: :user}, _observed_at), do: {:drop, :untrusted_operator}

  def normalize(%{"role" => "assistant", "body" => body} = event, observed_at)
      when is_binary(body) do
    normalize(
      %{
        role: :assistant,
        body: body,
        msg_id: Map.get(event, "msg_id"),
        sequence: Map.get(event, "sequence"),
        timestamp: Map.get(event, "timestamp"),
        title: Map.get(event, "title"),
        delivery: string_delivery(Map.get(event, "delivery"))
      },
      observed_at
    )
  end

  def normalize(%{"role" => role}, _observed_at) when is_binary(role),
    do: {:drop, :unknown_kind}

  def normalize(_event, _observed_at), do: {:drop, :unknown_kind}

  @spec normalize_trusted(:tool | :user, term(), DateTime.t()) ::
          {:ok, map()} | {:drop, atom()}
  def normalize_trusted(role, %{body: body} = event, observed_at)
      when role in [:tool, :user] and is_binary(body) do
    normalized_message(role, body, event, observed_at)
  end

  def normalize_trusted(_role, _event, _observed_at), do: {:drop, :invalid_summary}

  @spec compact_fragments(map()) :: {String.t(), boolean()}
  def compact_fragments(fragments) when is_map(fragments) do
    joined =
      fragments
      |> Map.values()
      |> Enum.sort_by(& &1.order)
      |> Enum.map_join(& &1.body)

    case Sanitizer.sanitize_projection(joined, @body_limit,
           input_byte_limit: @fragment_join_byte_limit,
           redact_urls: true,
           redact_environment: true,
           trim: false
         ) do
      {:ok, body, truncated?} -> {body, truncated?}
      :error -> {"", true}
    end
  end

  @spec public_message(map()) :: map()
  def public_message(message) do
    Map.drop(message, [:delivery, :fragment, :fragments, :order, :truncated?])
  end

  defp normalized_message(role, body, event, observed_at) do
    with {:ok, delivery} <- message_delivery(event),
         {:ok, body, body_truncated?} <- sanitize_body(body, delivery),
         false <- body == "",
         {:ok, id} <- message_id(role, event, body),
         {:ok, title, title_truncated?} <- title_for(role, event) do
      occurred_at = date_time(event[:timestamp]) || observed_at
      fragment = fragment(event, body, delivery, occurred_at)

      {:ok,
       %{
         id: id,
         role: role_name(role),
         title: title,
         body: body,
         occurred_at: occurred_at,
         observed_at: observed_at,
         order: {DateTime.to_unix(occurred_at, :microsecond), id},
         delivery: delivery,
         fragment: fragment,
         fragments: fragment_map(fragment),
         truncated?: body_truncated? or title_truncated?
       }}
    else
      true -> {:drop, :empty}
      _ -> {:drop, :invalid_event}
    end
  end

  defp sanitize_body(body, delivery) do
    Sanitizer.sanitize_projection(body, @body_limit,
      redact_urls: true,
      redact_environment: true,
      trim: delivery == :completed
    )
  end

  defp message_delivery(event) do
    case Map.get(event, :delivery, :completed) do
      delivery when delivery in [:partial, :completed] -> {:ok, delivery}
      _delivery -> {:error, :invalid_delivery}
    end
  end

  defp string_delivery(nil), do: :completed
  defp string_delivery("partial"), do: :partial
  defp string_delivery("completed"), do: :completed
  defp string_delivery(_delivery), do: :invalid

  defp message_id(role, event, body) do
    case event[:msg_id] || event[:id] do
      nil -> {:ok, stable_id(role, event, body)}
      "" -> {:ok, stable_id(role, event, body)}
      id when is_binary(id) or is_integer(id) -> {:ok, Source.opaque_id("message:", id)}
      _id -> {:error, :invalid_id}
    end
  end

  defp title_for(role, event) do
    case event[:title] do
      nil -> {:ok, role_name(role), false}
      title when is_binary(title) -> sanitized_title(title, role)
      title when is_atom(title) -> sanitized_title(Atom.to_string(title), role)
      _title -> {:error, :invalid_title}
    end
  end

  defp sanitized_title(title, role) do
    case Sanitizer.sanitize_projection(title, @title_limit,
           redact_urls: true,
           redact_environment: true,
           trim: true
         ) do
      {:ok, "", truncated?} -> {:ok, role_name(role), truncated?}
      {:ok, safe, truncated?} -> {:ok, safe, truncated?}
      :error -> {:error, :invalid_title}
    end
  end

  defp fragment(_event, _body, :completed, _occurred_at), do: nil

  defp fragment(event, body, :partial, occurred_at) do
    id = fragment_id(event, body)

    %{
      id: id,
      body: body,
      order: fragment_order(event[:sequence], occurred_at, id)
    }
  end

  defp fragment_map(nil), do: %{}
  defp fragment_map(%{id: id} = fragment), do: %{id => fragment}

  defp fragment_order(sequence, _occurred_at, id)
       when is_integer(sequence) and sequence >= 0,
       do: {0, sequence, id}

  defp fragment_order(_sequence, occurred_at, id),
    do: {1, DateTime.to_unix(occurred_at, :microsecond), id}

  defp fragment_id(%{sequence: sequence}, _body)
       when is_integer(sequence) and sequence >= 0,
       do: Source.opaque_id("fragment:", sequence)

  defp fragment_id(event, body), do: stable_id(:fragment, event, body)

  defp stable_id(role, event, body) do
    source_id = event[:turn_id] || event[:timestamp] || event[:occurred_at] || ""
    Source.opaque_id("message:", {role, source_id, body})
  end

  defp role_name(:assistant), do: "agent"
  defp role_name(:user), do: "operator"
  defp role_name(:tool), do: "tool"

  defp delivery_for(:assistant_delta), do: :partial
  defp delivery_for(:assistant_completed), do: :completed

  defp date_time(%DateTime{} = value), do: value

  defp date_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _error -> nil
    end
  end

  defp date_time(_value), do: nil
end
