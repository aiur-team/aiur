defmodule VoiceConverse.Redact do
  @moduledoc "Default redactor: bearer tokens, provider-style API keys and URLs with embedded credentials."

  @mask "[redacted]"

  @patterns [
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/i,
    ~r/\b(?:sk|xi|ghp|gho|ghs)[-_][A-Za-z0-9_-]{8,}/,
    ~r/(?<=:\/\/)[^\s\/@:]+:[^\s\/@]+(?=@)/
  ]

  # A partial prefix may become a match when the next provider delta arrives.
  # Keep that suffix private until it is complete or the turn ends.
  @broadcast_tail_graphemes 7

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, text, &Regex.replace(&1, &2, @mask))
  end

  @doc "Returns the suffix that could complete a redaction prefix, capped at seven graphemes. It releases on the next text chunk or turn flush."
  @spec holdback(String.t()) :: non_neg_integer()
  def holdback(text) when is_binary(text) do
    graphemes = String.graphemes(text)

    case length(graphemes) do
      0 ->
        0

      count ->
        1..min(count, @broadcast_tail_graphemes)
        |> Enum.reduce(0, fn length, longest ->
          suffix = graphemes |> Enum.take(-length) |> Enum.join()
          if partial_prefix?(suffix), do: max(longest, length), else: longest
        end)
    end
  end

  @doc "Returns the conservative maximum streaming holdback in graphemes."
  @spec broadcast_holdback_graphemes() :: pos_integer()
  def broadcast_holdback_graphemes, do: @broadcast_tail_graphemes

  defp partial_prefix?(suffix) do
    prefixes = ["Bearer ", "sk-", "sk_", "xi-", "xi_", "ghp-", "ghp_", "gho-", "gho_", "ghs-", "ghs_"]
    candidate = String.downcase(suffix)

    Enum.any?(prefixes, &String.starts_with?(String.downcase(&1), candidate)) or
      (String.ends_with?(suffix, "://") and String.length(suffix) <= 8)
  end

  @doc "Applies a string redactor recursively to nested parameter and result values."
  @spec redact_value(term(), (String.t() -> String.t())) :: term()
  def redact_value(value, redactor) when is_binary(value), do: redactor.(value)
  def redact_value(value, redactor) when is_list(value), do: Enum.map(value, &redact_value(&1, redactor))

  def redact_value(value, redactor) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact_value(item, redactor)} end)

  def redact_value(value, _redactor), do: value
end
