defmodule Aiur.Opencode.ChatCompletions.InputIdentity do
  @moduledoc """
  Decode the slot plugin's transport envelope once, before routing markers.
  JSON clients cannot supply the atom-keyed identity used internally. Legacy
  callers remain unkeyed; their literal text is never interpreted as metadata.
  """

  alias Aiur.Opencode.ChatCompletions.Caller

  @prefix "__aiur_input_v1__:"

  @spec unwrap(map(), Plug.Conn.t()) :: {:ok, map()} | {:error, atom()}
  def unwrap(body, conn) do
    case Plug.Conn.get_req_header(conn, "x-aiur-input-version") do
      [] ->
        {:ok, body}

      ["1"] ->
        with {:ok, _conn} <- Caller.authorize(conn), do: unwrap_messages(body)

      _ ->
        {:error, :unsupported_input_version}
    end
  end

  defp unwrap_messages(%{"messages" => messages} = body) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, decoded} ->
      case unwrap_message(message) do
        {:ok, message} -> {:cont, {:ok, [message | decoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Map.put(body, "messages", Enum.reverse(decoded))}
      error -> error
    end
  end

  defp unwrap_messages(_), do: {:error, :missing_user_message}

  defp unwrap_message(%{"role" => "user", "content" => content} = message) do
    case first_text(content) do
      {@prefix <> json, extra} -> decode_envelope(message, json, extra)
      _ -> {:ok, message}
    end
  end

  defp unwrap_message(message), do: {:ok, message}

  defp decode_envelope(message, json, extra) do
    with {:ok, %{"session" => session, "message" => id, "text" => body}} <- Jason.decode(json),
         true <- valid_id?(session) and valid_id?(id) and is_binary(body) do
      {:ok, message |> Map.put("content", body <> text(extra)) |> Map.put(:aiur_message_id, "opencode:#{session}:#{id}")}
    else
      _ -> {:error, :invalid_input_identity}
    end
  end

  # Conversion can append synthetic text parts; compaction can also append a
  # whole synthetic user message after the hook. Neither creates a new user
  # action. Preserve the former alongside its source, and leave the latter
  # unkeyed instead of inventing provenance or refusing the whole request.
  defp first_text(content) when is_binary(content), do: {content, []}
  defp first_text([%{"type" => "text", "text" => first} | rest]), do: {first, rest}
  defp first_text(_), do: nil

  defp text(content) when is_binary(content), do: content

  defp text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp text(_), do: nil

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)
end
