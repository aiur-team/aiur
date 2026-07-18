defmodule Aiur.SecretRedactor do
  @moduledoc """
  Shared well-known credential and capability-URL redaction. Extracted
  from `Aiur.Events.Sanitizer` so every consumer that must not persist or
  hash a raw secret (GitHub event payload text, Decision request content,
  browser-facing projections) redacts through the same patterns rather
  than a copy that can drift.
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

  @url_pattern ~r"""
    (?<![A-Za-z0-9+.-])
    (?:https?|wss?)
    (?:
      :
      | %3[aA]
      | \\+u003[aA]
      | &\#(?:58|x3[aA]);
      | &colon;
    )
    (?:
      /
      | %2[fF]
      | \\+/
      | \\+u002[fF]
      | &\#(?:47|x2[fF]);
      | &sol;
    ){2}
    [^\s"'<>]+
  """iux

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

  @doc "Redact browser- and socket-capability URLs, including escaped and mixed-case forms."
  @spec redact_urls(String.t()) :: String.t()
  def redact_urls(text) when is_binary(text) do
    Regex.replace(@url_pattern, text, "[REDACTED:url]")
  end

  @doc "Inspect a runtime term, redact credentials, and cap the resulting text."
  @spec safe_inspect(term(), pos_integer()) :: String.t()
  def safe_inspect(value, max_chars) when is_integer(max_chars) and max_chars > 0 do
    value
    |> inspect(limit: 20, printable_limit: max_chars)
    |> redact()
    |> String.slice(0, max_chars)
  end
end
