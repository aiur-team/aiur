defmodule Aiur.Opencode.ChatCompletions.TurnRequest do
  @moduledoc """
  Pure request-body interpretation for `POST /v1/chat/completions`.

  Parses the OpenAI-format request body to extract user texts, detect
  synthetic markers, and validate content. No side effects.
  """

  @turn_marker_prefix "__aiur_turn__:"
  @stream_marker_prefix "__aiur_stream__:"

  @max_body_bytes 65_536

  @doc false
  @spec last_user_text(map()) :: {:ok, String.t()} | {:error, atom()}
  def last_user_text(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(&message_user_text/1)
    |> case do
      text when is_binary(text) -> {:ok, text}
      _ -> {:error, :missing_user_message}
    end
  end

  def last_user_text(_), do: {:error, :missing_user_message}

  @doc false
  # The consecutive run of user messages at the END of the request body —
  # i.e. everything opencode queued since the last assistant reply. Old
  # history is fenced off by assistant messages, so this never resurfaces
  # prior turns. Used by both coalescing defenses.
  @spec trailing_user_texts(map()) :: [String.t()]
  def trailing_user_texts(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(fn m -> is_map(m) and Map.get(m, "role") == "user" end)
    |> Enum.map(&message_user_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
  end

  def trailing_user_texts(_), do: []

  @doc false
  @spec synthetic_marker_text?(String.t()) :: boolean()
  def synthetic_marker_text?(text) do
    String.starts_with?(text, @turn_marker_prefix) or
      String.starts_with?(text, @stream_marker_prefix)
  end

  @doc false
  @spec validate_body(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_body(body) when byte_size(body) > @max_body_bytes, do: {:error, :body_too_large}

  def validate_body(body) do
    if String.valid?(body) do
      {:ok, String.replace(body, ~r/[\x00-\x08\x0B-\x1F]/, "")}
    else
      {:error, :invalid_utf8}
    end
  end

  defp message_user_text(%{"role" => "user", "content" => text}) when is_binary(text), do: text

  defp message_user_text(%{"role" => "user", "content" => parts}) when is_list(parts),
    do: text_from_parts(parts)

  defp message_user_text(_), do: nil

  defp text_from_parts(parts) do
    Enum.map_join(parts, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end
end
