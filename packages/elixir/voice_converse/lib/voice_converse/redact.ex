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
end
