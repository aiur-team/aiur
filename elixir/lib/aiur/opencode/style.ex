defmodule Aiur.Opencode.Style do
  @moduledoc """
  Chat-pane visual styling vocabulary.

  Centralizes the choice of dimming mechanism so flipping mechanisms
  only touches one site. Used by `Aiur.Opencode.EventRow` for
  cross-ticket event ticker rows (📥/📤/📄).

  ## Mechanism choice — Markdown blockquote

  Probed against a live opencode-attach pane (per U5 of the
  chat-pane follow-ups plan): ANSI dim escapes (`\\e[2m...\\e[22m`)
  rendered as **literal characters** in opencode-attach 1.15.x, not
  as visual dim. Falling back to a Markdown blockquote prefix
  (`> ...`) — opencode-attach renders blockquotes with a left-margin
  bar that visually subordinates the content from agent prose.

  Why not the originally-planned `▸ ` Unicode marker: blockquote
  framing is what opencode-attach already uses for the `:system` and
  `:alert` deltas (see `ChatCompletions.format_delta/2`), so event
  rows blend into the same visual vocabulary the operator already
  knows.

  Command, tool, and reasoning content render via their existing
  format_delta clauses (Markdown code-fences for command/tool;
  Markdown italics for reasoning) which already subordinate them
  vs default-weight prose. They do NOT need an extra `dim/1` wrap.
  """

  @doc """
  Wrap `text` so it renders visibly subdued vs default-weight prose.
  Currently a Markdown blockquote prefix per the U5 probe finding.
  """
  @spec dim(String.t()) :: String.t()
  def dim(text) when is_binary(text), do: "> " <> text
end
