defmodule Aiur.OpenAICompat.CreditLimit do
  @moduledoc false

  # Recognition of the provider *credit* refusal, which arrives as HTTP 402.
  #
  # OpenRouter answers a request whose output-token reservation exceeds the
  # key's remaining credit with
  #
  #   This request requires more credits, or fewer max_tokens. You requested
  #   up to 131072 tokens, but can only afford 65535. ...
  #
  # That is an account-balance condition, not an agent failure. `Transport`
  # answers it by retrying once with the smaller cap the message names (or half
  # when it names none); if that is refused too, the coding agent pauses the
  # route as credit-limited instead of failing the turn (#7514).

  alias Aiur.OpenAICompat.OutputTokens

  @markers [
    "requires more credits",
    "fewer max_tokens",
    "can only afford",
    "insufficient credit",
    "not enough credit"
  ]

  # OpenRouter's per-key spending limit refuses the prompt itself:
  #
  #   Prompt tokens limit exceeded: 13485 > 561. To increase, visit
  #   https://openrouter.ai/workspaces/.../keys/... and adjust the key's monthly limit
  #
  # No smaller output cap can fit, so it is credit-limited without a retry.
  @key_limit_markers ["tokens limit exceeded", "key's monthly limit", "key limit exceeded"]

  @affordable ~r/can only afford ([\d,]+)/i

  @doc "Whether a 402 detail is a credit or `max_tokens` refusal rather than an unrelated payment fault."
  @spec error?(term()) :: boolean()
  def error?(detail) when is_binary(detail) do
    haystack = String.downcase(detail)
    Enum.any?(@markers, &String.contains?(haystack, &1))
  end

  def error?(_detail), do: false

  @doc "Whether a 402 detail is the provider's per-key limit, which no smaller request can fit."
  @spec key_limit?(term()) :: boolean()
  def key_limit?(detail) when is_binary(detail) do
    haystack = String.downcase(detail)
    Enum.any?(@key_limit_markers, &String.contains?(haystack, &1))
  end

  def key_limit?(_detail), do: false

  @doc """
  The smaller cap for the one retry of a credit-refused request.

  The provider's own affordability figure wins when it printed one, because it
  is the largest cap that fits the remaining balance; otherwise the cap is
  halved. `:error` means no smaller cap can help and the route is credit
  limited.
  """
  @spec retry_cap(pos_integer(), term()) :: {:ok, pos_integer()} | :error
  def retry_cap(cap, detail) do
    case affordable(detail) do
      value when is_integer(value) and value > 0 and value < cap -> {:ok, value}
      _missing_or_not_smaller -> OutputTokens.reduce(cap)
    end
  end

  defp affordable(detail) when is_binary(detail) do
    case Regex.run(@affordable, detail) do
      [_match, value] -> value |> String.replace(",", "") |> String.to_integer()
      _missing -> nil
    end
  end

  defp affordable(_detail), do: nil
end
