defmodule Aiur.ExternalContent do
  @moduledoc """
  The single `<external-content>` wrapper for text Aiur did not author.

  Call sites that render through it today: `Aiur.PromptBuilder` (issue title and
  body), `Aiur.AgentRunner.EventsDigest` (the `<aiur:events>` digest), and
  `Aiur.IssueContext` (the opencode pane intro) — the surfaces that carry
  outsider prose into an agent's own prompt or transcript. Other agent-visible
  surfaces still render untrusted text untagged and are tracked as follow-up
  work: provider session titles (`Aiur.Claude.CodingAgent`, `Aiur.Codex.Frames`),
  the opencode transcript writer (`Aiur.Opencode.EventRow`), `aiur status`
  output (`Aiur.AgentControlCLI`), and decision records
  (`Aiur.DecisionAttention`). Do not read this module as covering them.

  Aiur runs against public repositories with issues enabled, so an outsider can
  put arbitrary prose into an issue title, an issue body, or a comment. That
  prose reaches an agent that holds a GitHub credential and has network egress.
  The prompt therefore has to keep two kinds of text visibly apart:

    * **task metadata** Aiur itself computed (identifier, state label, base
      branch, URL) — instructions the agent must follow, and
    * **attacker-controllable prose** — data the agent may read and must never
      obey.

  `wrap/3` marks the second kind. It is deliberately two steps that must both
  happen at the same call site:

    1. `Aiur.Events.Sanitizer.clean_untrusted/2` strips hidden-instruction
       carriers, redacts secrets, truncates, and **HTML-escapes**; and
    2. the escaped text is placed inside
       `<external-content source="github" author="...">…</external-content>`.

  Step 1 is what makes step 2 hold: without the escape, a body containing a
  literal `</external-content>` closes the wrapper early and everything after it
  reads as trusted prompt again. Do not add a wrapper call that skips the clean,
  and do not "improve" readability by un-escaping inside the wrapper.

  `Aiur.AgentRunner.EventsDigest` and `Aiur.PromptBuilder` both render through
  here so the prompt cannot end up with two wrapper spellings the shared agent
  instructions only teach one of.
  """

  alias Aiur.Events.Sanitizer

  @type field :: :commit_subject | :comment_body | :pr_review_body | :issue_title | :issue_body

  @doc """
  Sanitize `text` as `field` and wrap it for the agent prompt.

  `nil` and `""` pass through unchanged so callers can wrap optional issue
  fields without inventing an empty wrapper the agent has to read past.
  """
  @spec wrap(String.t() | nil, field(), String.t() | nil) :: String.t() | nil
  def wrap(nil, _field, _author), do: nil
  def wrap("", _field, _author), do: ""

  def wrap(text, field, author) when is_binary(text) do
    text
    |> Sanitizer.clean_untrusted(field)
    |> wrap_sanitized(author)
  end

  @doc """
  Wrap text that has already been through `Sanitizer.clean_untrusted/2` (or the
  payload scrubbers, which run the same pipeline).

  Only call this when the text is provably sanitized; `wrap/3` is the safe
  default because it cannot be called with raw input by mistake.
  """
  @spec wrap_sanitized(String.t(), String.t() | nil) :: String.t()
  def wrap_sanitized(text, author) when is_binary(text) do
    "<external-content source=\"github\"#{author_attribute(author)}>#{text}</external-content>"
  end

  # The author login comes from GitHub. The standard charset is `[A-Za-z0-9-]`
  # with no `"` allowed, but an attacker who controls a login claim (or any
  # future code path that synthesizes the field) could embed quote / angle /
  # ampersand characters. Escape defensively so the attribute boundary — and
  # therefore the opening tag — always holds.
  defp author_attribute(author) when is_binary(author) and author != "" do
    " author=\"#{attribute_escape(author)}\""
  end

  defp author_attribute(_author), do: ""

  defp attribute_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
