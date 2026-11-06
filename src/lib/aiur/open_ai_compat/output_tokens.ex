defmodule Aiur.OpenAICompat.OutputTokens do
  @moduledoc false

  # Every OpenAI-compatible request carries a bounded output-token cap.
  #
  # OpenRouter reserves credit for the *whole* `max_tokens` of a request before
  # it runs, so a request that omits the field (and therefore reserves the
  # model's full output window — 131 072 tokens for DeepSeek V4.1 Flash) is
  # refused with HTTP 402 on any key with a modest balance, even though one
  # request really costs cents. Every worker then failed on the same request
  # and released its claim (#7514).
  #
  # The cap is `agent.backend_configs.<backend>.max_output_tokens` when the
  # operator sets one, and this default otherwise. It is raised for a single
  # request only when that request demonstrably needed more: a completion that
  # stopped on the cap (`finish_reason: "length"`) is retried once at
  # `escalate/1`. See `Aiur.OpenAICompat.Transport`.

  @default 16_000
  @minimum 1_024

  @doc "The default cap for an OpenAI-compatible backend."
  @spec default() :: pos_integer()
  def default, do: @default

  @doc """
  The cap to send: a configured value that is a usable token count, else `default/0`.

  A value below `#{@minimum}` is rejected rather than honored: it would truncate
  every reply, and an operator who wrote it almost certainly meant something
  else.
  """
  @spec resolve(term()) :: pos_integer()
  def resolve(value) when is_integer(value) and value >= @minimum, do: value
  def resolve(_value), do: @default

  @doc "The cap for the one retry of a completion that stopped on the cap."
  @spec escalate(pos_integer()) :: pos_integer()
  def escalate(cap), do: cap * 2

  @doc "A smaller cap for the one retry of a credit-refused request, or `:error` when nothing smaller is sensible."
  @spec reduce(pos_integer()) :: {:ok, pos_integer()} | :error
  def reduce(cap) when is_integer(cap) and cap > @minimum, do: {:ok, cap |> div(2) |> max(@minimum)}
  def reduce(_cap), do: :error
end
