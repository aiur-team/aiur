defmodule Aiur.Muse.Usage do
  @moduledoc "Pure readers for native Muse usage notifications."

  @max_tokens 1_000_000_000_000

  @spec token_notification(map()) :: {:ok, map()} | {:error, atom()}
  def token_notification(%{"method" => "session/tokenUsage", "params" => params} = message)
      when is_map(params) do
    with {:ok, session_id} <- identifier(params["sessionId"]),
         {:ok, turn_id} <- identifier(params["turnId"]),
         {:ok, stream} <- source_stream(params["sourceRange"]),
         {:ok, cumulative} <- cumulative(params["cumulative"]),
         {:ok, prompt_tokens} <- count(params["promptTokens"]),
         {:ok, total_tokens} <- count(params["totalTokens"]),
         {:ok, turn} <- turn_tokens(params["usage"]),
         true <- prompt_tokens == turn.input and total_tokens == turn.input + turn.output,
         {:ok, occurred_at} <- timestamp(message["emittedAtMs"]) do
      {:ok,
       %{
         session_id: session_id,
         turn_id: turn_id,
         stream: stream,
         cumulative: cumulative,
         turn: turn,
         occurred_at: occurred_at,
         view_cursor: params["viewCursor"]
       }}
    else
      _ -> {:error, :invalid_token_usage}
    end
  end

  def token_notification(_message), do: {:error, :unsupported_usage_event}

  @spec context_notification(map()) :: {:ok, map()} | {:error, atom()}
  def context_notification(%{"method" => "session/contextUsage", "params" => params})
      when is_map(params) do
    with {:ok, session_id} <- identifier(params["sessionId"]),
         {:ok, used} <- count(params["usedTokens"]),
         {:ok, capacity} <- optional_count(params["windowTokens"]),
         {:ok, pressure} <- pressure(params["pressure"]) do
      {:ok,
       %{
         session_id: session_id,
         used_tokens: used,
         window_tokens: capacity,
         used_percent: if(is_integer(capacity) and capacity > 0, do: used * 100 / capacity),
         pressure: pressure,
         view_cursor: params["viewCursor"]
       }}
    else
      _ -> {:error, :invalid_context_usage}
    end
  end

  def context_notification(_message), do: {:error, :unsupported_usage_event}

  defp source_stream(%{"stream" => %{"id" => id, "kind" => kind}, "last" => %{"id" => last_id, "sequence" => sequence}})
       when is_binary(kind) and is_integer(sequence) and sequence >= 0 do
    with {:ok, id} <- identifier(id), {:ok, last_id} <- identifier(last_id) do
      {:ok, %{id: id, kind: kind, last_id: last_id, sequence: sequence}}
    end
  end

  defp source_stream(_value), do: {:error, :invalid_source_range}

  defp cumulative(%{"promptTokens" => prompt, "outputTokens" => output, "totalTokens" => total}) do
    with {:ok, prompt} <- count(prompt),
         {:ok, output} <- count(output),
         {:ok, total} <- count(total),
         true <- total == prompt + output do
      {:ok, %{input: prompt, output: output, total: total}}
    else
      _ -> {:error, :invalid_cumulative_usage}
    end
  end

  defp cumulative(_value), do: {:error, :invalid_cumulative_usage}

  defp turn_tokens(%{"inputTokens" => input, "outputTokens" => output} = usage) do
    with {:ok, input} <- count(input),
         {:ok, output} <- count(output),
         {:ok, cached} <- optional_count(usage["cachedTokens"]),
         {:ok, cache_read} <- optional_count(usage["cacheReadTokens"]),
         {:ok, cache_write} <- optional_count(usage["cacheWriteTokens"]),
         {:ok, reasoning} <- optional_count(usage["reasoningTokens"]) do
      {:ok,
       %{
         input: input,
         output: output,
         cached_input: cache_read || cached,
         cache_creation_input: cache_write,
         reasoning_output: reasoning
       }}
    end
  end

  defp turn_tokens(_value), do: {:error, :invalid_turn_usage}

  defp count(value) when is_integer(value) and value >= 0 and value <= @max_tokens, do: {:ok, value}
  defp count(_value), do: {:error, :invalid_count}
  defp optional_count(nil), do: {:ok, nil}
  defp optional_count(value), do: count(value)

  defp pressure("normal"), do: {:ok, :normal}
  defp pressure("warning"), do: {:ok, :warning}
  defp pressure("blocked"), do: {:ok, :blocked}
  defp pressure(_value), do: {:error, :invalid_pressure}

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..256, do: {:ok, value}
  defp identifier(_value), do: {:error, :invalid_identifier}

  defp timestamp(value) when is_integer(value) and value >= 0 do
    DateTime.from_unix(value, :millisecond)
  end

  defp timestamp(_value), do: {:ok, nil}
end
