defmodule Aiur.TokenUsage do
  @moduledoc """
  Shared token usage normalization and display helpers.
  """

  alias Aiur.EventHumanizerHelpers

  @type canonical_usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @spec canonicalize(term()) :: canonical_usage() | nil
  def canonicalize(nil), do: nil

  def canonicalize(raw) when is_map(raw) do
    input =
      token_value(
        raw,
        ~w(input_tokens prompt_tokens inputTokens promptTokens)a ++
          ~w(input_tokens prompt_tokens inputTokens promptTokens)
      )

    output =
      token_value(
        raw,
        ~w(output_tokens completion_tokens outputTokens completionTokens)a ++
          ~w(output_tokens completion_tokens outputTokens completionTokens)
      )

    total = token_value(raw, ~w(total_tokens total totalTokens)a ++ ~w(total_tokens total totalTokens))

    if input || output || total do
      %{input_tokens: input || 0, output_tokens: output || 0, total_tokens: total || 0}
    end
  end

  def canonicalize(_), do: nil

  @spec token_field?(term()) :: boolean()
  def token_field?(map) when is_map(map) do
    token_keys =
      ~w(input_tokens output_tokens total_tokens prompt_tokens completion_tokens
                    inputTokens outputTokens totalTokens promptTokens completionTokens)a ++
        ~w(input_tokens output_tokens total_tokens prompt_tokens completion_tokens
                    inputTokens outputTokens totalTokens promptTokens completionTokens)

    Enum.any?(token_keys, fn key ->
      map |> Map.get(key) |> token_like_value?()
    end)
  end

  def token_field?(_), do: false

  @spec format_counts(term()) :: String.t() | nil
  def format_counts(usage) when is_map(usage) do
    input =
      EventHumanizerHelpers.parse_integer(
        EventHumanizerHelpers.map_value(usage, [
          "input_tokens",
          :input_tokens,
          "prompt_tokens",
          :prompt_tokens,
          "inputTokens",
          :inputTokens,
          "promptTokens",
          :promptTokens
        ])
      )

    output =
      EventHumanizerHelpers.parse_integer(
        EventHumanizerHelpers.map_value(usage, [
          "output_tokens",
          :output_tokens,
          "completion_tokens",
          :completion_tokens,
          "outputTokens",
          :outputTokens,
          "completionTokens",
          :completionTokens
        ])
      )

    total =
      EventHumanizerHelpers.parse_integer(
        EventHumanizerHelpers.map_value(usage, [
          "total_tokens",
          :total_tokens,
          "total",
          :total,
          "totalTokens",
          :totalTokens
        ])
      )

    parts =
      []
      |> append_usage_part("in", input)
      |> append_usage_part("out", output)
      |> append_usage_part("total", total)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, ", ")
    end
  end

  def format_counts(_usage), do: nil

  defp token_value(map, keys) do
    Enum.find_value(keys, fn key ->
      map |> Map.get(key) |> parse_token_value()
    end)
  end

  defp parse_token_value(v) when is_integer(v) and v >= 0, do: v

  defp parse_token_value(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_token_value(_), do: nil

  defp token_like_value?(v) when is_integer(v) and v >= 0, do: true

  defp token_like_value?(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} when n >= 0 -> true
      _ -> false
    end
  end

  defp token_like_value?(_), do: false

  defp append_usage_part(parts, _label, value) when not is_integer(value), do: parts

  defp append_usage_part(parts, label, value) do
    parts ++ ["#{label} #{EventHumanizerHelpers.format_count(value)}"]
  end
end
