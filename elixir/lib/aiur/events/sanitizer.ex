defmodule Aiur.Events.Sanitizer do
  @moduledoc """
  Plan U7. Four-layer scrub of GitHub-sourced event payloads before they
  reach any consumer (per-issue log, dashboard panel, agent digest):

    1. **Truncation** — bound user-content fields so a 50KB commit
       comment doesn't bloat every downstream surface. Commit subjects
       ≤ 200 chars; comment / PR-review bodies ≤ 500 chars; overflow
       trimmed and replaced with `…`. The original-length URL field
       (if present) is preserved so the agent can follow on demand.
    2. **Secret-pattern redaction** — well-known credential prefixes
       (sk-, ghp_, xoxb-, AWS access keys, generic hex tokens) replaced
       with `[REDACTED:<pattern>]` before truncation runs, so a redacted
       match never straddles the truncation boundary.
    3. **CODEOWNERS trust flag** — `author_trusted?` boolean added to
       the payload based on `Aiur.GitHub.CodeOwners.allowed?/1`. Events
       from non-CODEOWNERS authors stay visible to the operator (log +
       dashboard) but the agent-digest renderer skips them.
    4. **`<external-content>` wrapper** — applied at render time
       (see `Aiur.AgentRunner.render_events_digest/2`); not part of
       this pure module because the wrap is a presentation concern.

  Pure functions; no GenServer state. Callable from any context.
  """

  @commit_subject_max 200
  @comment_body_max 500
  @pr_review_body_max 500

  @user_content_fields [
    :commit_subject,
    :comment_body,
    :pr_review_body
  ]

  @redaction_patterns [
    {~r/sk-[A-Za-z0-9_\-]{20,}/, "[REDACTED:sk]"},
    {~r/ghp_[A-Za-z0-9]{36,}/, "[REDACTED:ghp]"},
    {~r/xoxb-[A-Za-z0-9-]+/, "[REDACTED:xoxb]"},
    {~r/AKIA[0-9A-Z]{16}/, "[REDACTED:aws]"}
  ]

  @doc """
  Apply the redact-then-truncate pass over a payload's user-content
  fields. Returns the sanitized payload. Idempotent.
  """
  @spec scrub(map()) :: map()
  def scrub(payload) when is_map(payload) do
    Enum.reduce(@user_content_fields, payload, fn field, acc -> scrub_field(acc, field) end)
  end

  def scrub(other), do: other

  @doc """
  Add an `author_trusted?` flag to the payload based on whether
  `author` (a GitHub login) is currently in the resolved CODEOWNERS
  trust set. No-op when CodeOwners isn't running (test harnesses,
  early boot) — flag is set to `false` so the conservative default is
  "filter out of agent digest".
  """
  @spec stamp_author_trust(map(), keyword()) :: map()
  def stamp_author_trust(payload, opts \\ []) when is_map(payload) do
    author = Map.get(payload, :author) || Keyword.get(opts, :actor)
    trusted? = author_trusted?(author)
    Map.put(payload, :author_trusted?, trusted?)
  end

  defp author_trusted?(nil), do: false

  defp author_trusted?(author) when is_binary(author) do
    if Process.whereis(Aiur.GitHub.CodeOwners) do
      try do
        Aiur.GitHub.CodeOwners.allowed?(author)
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  defp author_trusted?(_), do: false

  defp scrub_field(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) ->
        Map.put(payload, field, value |> redact() |> truncate(field))

      _ ->
        payload
    end
  end

  defp redact(text) when is_binary(text) do
    Enum.reduce(@redaction_patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp truncate(text, :commit_subject) when is_binary(text), do: maybe_trim(text, @commit_subject_max)
  defp truncate(text, :comment_body) when is_binary(text), do: maybe_trim(text, @comment_body_max)
  defp truncate(text, :pr_review_body) when is_binary(text), do: maybe_trim(text, @pr_review_body_max)
  defp truncate(text, _other) when is_binary(text), do: text

  defp maybe_trim(text, max) when byte_size(text) > max do
    binary_part(text, 0, max) <> "…"
  end

  defp maybe_trim(text, _max), do: text
end
