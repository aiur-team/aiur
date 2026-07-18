defmodule Aiur.Usage.Headless.Codex.Tokens do
  @moduledoc false

  # Shared, content-free reader for the Codex `TokenUsage` shape used by both the
  # cumulative thread stream (`total_token_usage`) and the per-turn delta stream
  # (`last_token_usage` / `turn/completed` usage). Sub-counts arrive as integers
  # or numeric strings, under string or atom keys. Cache and reasoning
  # sub-dimensions are preserved when present and stay `nil`, never zero, when
  # the installed protocol omits them.

  alias Aiur.Usage.Headless.Adapter

  @total_token_usage_paths [
    ["params", "msg", "payload", "info", "total_token_usage"],
    [:params, :msg, :payload, :info, :total_token_usage],
    ["params", "msg", "info", "total_token_usage"],
    [:params, :msg, :info, :total_token_usage],
    ["params", "tokenUsage", "total"],
    [:params, :tokenUsage, :total],
    ["tokenUsage", "total"],
    [:tokenUsage, :total]
  ]

  @last_token_usage_paths [
    ["params", "msg", "payload", "info", "last_token_usage"],
    [:params, :msg, :payload, :info, :last_token_usage],
    ["params", "msg", "info", "last_token_usage"],
    [:params, :msg, :info, :last_token_usage],
    ["params", "tokenUsage", "last"],
    [:params, :tokenUsage, :last],
    ["tokenUsage", "last"],
    [:tokenUsage, :last]
  ]

  @turn_completed_usage_paths [
    ["usage"],
    [:usage],
    ["params", "usage"],
    [:params, :usage]
  ]

  @spec cumulative(map()) :: map() | nil
  def cumulative(payload), do: token_map_at(payload, @total_token_usage_paths)

  @spec last(map()) :: map() | nil
  def last(payload), do: token_map_at(payload, @last_token_usage_paths)

  @spec turn_completed(map()) :: map() | nil
  def turn_completed(payload) do
    if turn_completed?(payload), do: token_map_at(payload, @turn_completed_usage_paths)
  end

  @spec dimensions(map()) :: %{optional(atom()) => non_neg_integer() | nil}
  def dimensions(usage) when is_map(usage) do
    %{
      input: Adapter.token(usage, ["input_tokens", :input_tokens, "prompt_tokens", :prompt_tokens, "inputTokens", :inputTokens, "promptTokens", :promptTokens]),
      cached_input: Adapter.token(usage, ["cached_input_tokens", :cached_input_tokens, "cache_read_input_tokens", :cache_read_input_tokens, "cachedInputTokens", :cachedInputTokens]),
      cache_creation_input: Adapter.token(usage, ["cache_creation_input_tokens", :cache_creation_input_tokens, "cacheCreationInputTokens", :cacheCreationInputTokens]),
      output: Adapter.token(usage, ["output_tokens", :output_tokens, "completion_tokens", :completion_tokens, "outputTokens", :outputTokens, "completionTokens", :completionTokens]),
      reasoning_output: Adapter.token(usage, ["reasoning_output_tokens", :reasoning_output_tokens, "reasoningOutputTokens", :reasoningOutputTokens]),
      provider_reported_total: Adapter.token(usage, ["total_tokens", :total_tokens, "total", :total, "totalTokens", :totalTokens])
    }
  end

  @spec measurement?(map()) :: boolean()
  def measurement?(dimensions) do
    Enum.any?(dimensions, fn {_dimension, value} -> is_integer(value) end)
  end

  defp turn_completed?(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)
    method in ["turn/completed", :turn_completed]
  end

  defp token_map_at(payload, paths) when is_map(payload) do
    Enum.find_value(paths, fn path -> token_map_or_nil(dig(payload, path)) end)
  end

  defp token_map_at(_payload, _paths), do: nil

  defp token_map_or_nil(value) when is_map(value), do: if(token_map?(value), do: value)
  defp token_map_or_nil(_value), do: nil

  defp token_map?(value) do
    value |> dimensions() |> measurement?()
  end

  defp dig(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key), do: {:cont, Map.get(acc, key)}, else: {:halt, nil}
    end)
  end
end
