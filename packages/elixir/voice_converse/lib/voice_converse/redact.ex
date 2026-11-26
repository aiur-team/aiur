defmodule VoiceConverse.Redact do
  @moduledoc "Default redactor: bearer tokens, provider-style API keys and URLs with embedded credentials."

  @mask "[redacted]"

  @patterns [
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/i,
    ~r/\b(?:sk|xi|ghp|gho|ghs)[-_][A-Za-z0-9_-]{8,}/,
    ~r/(?<=:\/\/)[^\s\/@:]+:[^\s\/@]+(?=@)/
  ]

  # Text ending in one of these could still grow into a @patterns match once the
  # next provider delta arrives, so the stream withholds it. A match already
  # complete at the end needs no hold: the stream re-redacts the whole turn.
  @partials [
    ~r/\bB(?:e(?:a(?:r(?:e(?:r(?:\s+[A-Za-z0-9._~+\/=-]{0,7})?)?)?)?)?)?\z/i,
    ~r/\b(?:s(?:k(?:[-_][A-Za-z0-9_-]{0,7})?)?|x(?:i(?:[-_][A-Za-z0-9_-]{0,7})?)?|g(?:h(?:[pos](?:[-_][A-Za-z0-9_-]{0,7})?)?)?)\z/,
    ~r/:(?:\/(?:\/(?:[^\s\/@:]+(?::[^\s\/@]*)?)?)?)?\z/
  ]

  # ponytail: a URL user:password longer than this cap is released before its "@" arrives.
  @max_holdback_graphemes 64

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, text, &Regex.replace(&1, &2, @mask))
  end

  @doc "Returns how many trailing graphemes could still become a redaction match, capped at `max_holdback_graphemes/0`."
  @spec holdback(String.t()) :: non_neg_integer()
  def holdback(text) when is_binary(text) do
    @partials
    |> Enum.flat_map(fn pattern ->
      case Regex.run(pattern, text, return: :index) do
        [{start, _}] -> [text |> binary_part(start, byte_size(text) - start) |> String.length()]
        nil -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> min(@max_holdback_graphemes)
  end

  @doc "Returns the maximum streaming holdback in graphemes."
  @spec max_holdback_graphemes() :: pos_integer()
  def max_holdback_graphemes, do: @max_holdback_graphemes

  @doc "Applies a string redactor recursively to nested parameter and result values."
  @spec redact_value(term(), (String.t() -> String.t())) :: term()
  def redact_value(value, redactor) when is_binary(value), do: redactor.(value)

  def redact_value(value, redactor) when is_list(value),
    do: Enum.map(value, &redact_value(&1, redactor))

  def redact_value(value, redactor) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact_value(item, redactor)} end)

  def redact_value(value, _redactor), do: value
end
