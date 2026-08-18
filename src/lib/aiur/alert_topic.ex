defmodule Aiur.AlertTopic do
  @moduledoc false

  @resolution_suffix ".resolved"

  @spec attention_key(map()) :: tuple() | nil
  def attention_key(%{"topic" => "ticket." <> rest}) do
    case String.split(rest, ".agent.attention.", parts: 2) do
      [ticket, slug] -> {:ticket_attention, ticket, slug}
      _ -> {:ticket, rest}
    end
  end

  def attention_key(%{"topic" => "system." <> rest}), do: {:system, rest}
  def attention_key(_alert), do: nil

  @spec resolved_attention_key(map()) :: tuple() | nil
  def resolved_attention_key(%{"needs_attention" => false} = alert) do
    case attention_key(alert) do
      {:ticket_attention, ticket, slug_and_suffix} ->
        case String.trim_trailing(slug_and_suffix, @resolution_suffix) do
          ^slug_and_suffix -> nil
          slug -> {:ticket_attention, ticket, slug}
        end

      {:ticket, rest} ->
        resolved_key(rest, &{:ticket, &1})

      {:system, rest} ->
        resolved_key(rest, &{:system, &1})

      nil ->
        nil
    end
  end

  def resolved_attention_key(_alert), do: nil

  defp resolved_key(value, wrap) do
    case String.trim_trailing(value, @resolution_suffix) do
      ^value -> nil
      topic -> wrap.(topic)
    end
  end
end
