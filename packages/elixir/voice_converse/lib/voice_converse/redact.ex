defmodule VoiceConverse.Redact do
  @moduledoc "Default redactor: bearer tokens, provider-style API keys and URLs with embedded credentials."

  @mask "[redacted]"

  @patterns [
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/i,
    ~r/\b(?:sk|xi|ghp|gho|ghs)[-_][A-Za-z0-9_-]{8,}/,
    ~r/(?<=:\/\/)[^\s\/@:]+:[^\s\/@]+(?=@)/
  ]

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, text, &Regex.replace(&1, &2, @mask))
  end

  @doc "Applies a string redactor recursively to nested parameter and result values."
  @spec redact_value(term(), (String.t() -> String.t())) :: term()
  def redact_value(value, redactor) when is_binary(value), do: redactor.(value)
  def redact_value(value, redactor) when is_list(value), do: Enum.map(value, &redact_value(&1, redactor))

  def redact_value(value, redactor) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact_value(item, redactor)} end)

  def redact_value(value, _redactor), do: value
end
