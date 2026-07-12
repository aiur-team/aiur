defmodule Aiur.SecretRedactor do
  @moduledoc """
  Shared well-known credential-pattern redaction. Extracted from
  `Aiur.Events.Sanitizer` so every consumer that must not persist or
  hash a raw secret (GitHub event payload text, Decision request
  content) redacts through the same pattern list rather than a copy
  that can drift.
  """

  @patterns [
    {~r/sk-[A-Za-z0-9_\-]{20,}/, "[REDACTED:sk]"},
    {~r/github_pat_[A-Za-z0-9_]{20,}/, "[REDACTED:github_pat]"},
    {~r/ghp_[A-Za-z0-9]{36,}/, "[REDACTED:ghp]"},
    {~r/gho_[A-Za-z0-9]{36,}/, "[REDACTED:gho]"},
    {~r/ghu_[A-Za-z0-9]{36,}/, "[REDACTED:ghu]"},
    {~r/ghs_[A-Za-z0-9]{36,}/, "[REDACTED:ghs]"},
    {~r/GHSAT0[A-Za-z0-9_-]{20,}/, "[REDACTED:ghsat]"},
    {~r/xoxb-[A-Za-z0-9-]+/, "[REDACTED:xoxb]"},
    {~r/AKIA[0-9A-Z]{16}/, "[REDACTED:aws]"},
    {~r/ASIA[0-9A-Z]{16}/, "[REDACTED:aws_session]"},
    {~r/AIza[0-9A-Za-z\-_]{35}/, "[REDACTED:google]"}
  ]

  @doc """
  Replace every known credential pattern in `text` with a
  `[REDACTED:<pattern>]` marker. Idempotent.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end
end
